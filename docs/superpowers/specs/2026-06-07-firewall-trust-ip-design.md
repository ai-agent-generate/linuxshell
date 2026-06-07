# 防火墙信任 IP（全端口放行）设计

为 `install-firewall.sh` 防火墙工具新增一种规则类型：把单个可信 IP 列入白名单，对它放行**全部端口**——主机自身所有监听端口 + 所有 Docker 容器发布端口 + 全协议（ICMP/ESP 等）。即典型的"信任源 IP"。

本设计是 `2026-06-07-firewall-management-design.md` 的增量扩展，沿用其全部约定（iptables 自管理、build-then-swap 原子替换、deny-by-default、`set -e` 容错、敏感文件 600）。

## 背景与现状

现有防火墙工具用声明式 `rules.conf`（`type action proto port source comment`）作单一事实源，已支持三种 `type`：

- `host`：主机入站白名单，**按端口**放行（`host allow tcp 80,443 any`），走 `FW-INPUT` 链。
- `docker`：容器发布端口的放行例外（Docker deny-by-default），走 `FW-DOCKER` 链。
- `node`：k3s 节点，逐端口放行其 k3s 端口组。

主机端口（`FW-INPUT`）与容器发布端口（`FW-DOCKER`，挂在 `DOCKER-USER` 下）**是两条独立链**。现在没有"对某 IP 全端口敞开"的干净表达：勉强写 `host allow tcp 1:65535` + `udp 1:65535` 需两条、漏掉非 TCP/UDP 协议、且只覆盖主机不覆盖 Docker、还会触发"全端口"sanity 拦截。

## 需求与约束（已与用户确认）

| 维度 | 决定 |
|------|------|
| 放行范围 | **主机 + Docker，全协议**：FW-INPUT 放行该 IP 所有流量，FW-DOCKER 放行其对所有容器发布端口的访问 |
| 信任对象约束 | **只允许单个 IP**（IPv4 /32 或单个 IPv6）；拒绝 CIDR 网段、拒绝 `any`，最小化暴露面 |
| 地址族 | IPv4 只写 `iptables`，IPv6 只写 `ip6tables`（复用 `fw_addr_family`） |
| 高危确认 | 菜单添加时强制二次确认（默认 `n`），并显式提示"将放行全部端口" |
| 配置表达 | 新增第四种 `type = trust`，与现有三类型对称 |

## 方案选择

| 方案 | 做法 | 评价 |
|------|------|------|
| **A. 新增 `trust` 类型（采纳）** | 配置行 `trust - - - <ip> <备注>`，与 `node` 行对称；新建 `lib/firewall/trust.sh`（与 `k3s.sh` 同构），FW-INPUT 写 `-s ip -j ACCEPT`、FW-DOCKER 写 `-s ip --ctstate DNAT -j RETURN` | 语义独立清晰，查看/删除/状态天然区分；与 host/docker/node 四类型对称；apply 逻辑最简单；复用 k3s.sh 已验证的"独立模块 + 被 fw_build_input 调用 + 按地址族归类"模式 |
| B. 复用 `host` + 端口值 `all` | `host allow all all <ip>`，host 构建里特判 `all` | `host` 本不碰 Docker，要再特判穿透 FW-DOCKER，语义污染、多处特判、校验复杂 |
| C. 不加功能，用户手写两条 | `host allow tcp 1:65535` + `udp 1:65535` | 需两条且漏 ICMP/ESP；触发"全端口"sanity 拦截；违背"一个动作信任一个 IP"意图 |

**采纳 A。**

## 配置格式

`rules.conf` 新增第四种 `type`：

```
# type   action  proto  port  source            comment
trust    -       -      -     203.0.113.10      办公室固定IP
trust    -       -      -     2001:db8::1       管理跳板机v6
```

- `action/proto/port` 占位 `-`（全协议全端口），与 `node` 行风格一致。
- `source` 必须是**单个 IP**（IPv4 或 IPv6），不接受 `any`、不接受 `/掩码` 网段。
- 仍由统一的 `read -r type action proto port src comment` 解析，与现有行同构，编号/删除/备份逻辑无需特殊处理。

## 新模块 `lib/firewall/trust.sh`

与 `k3s.sh` 对称，集中"信任 IP"关注点：

```bash
# 读配置 trust 行,输出信任 IP(类似 fw_k3s_node_ips)
fw_trust_ips() {
  local type action proto port src comment
  while read -r type action proto port src comment; do
    [[ "$type" == "trust" ]] || continue
    printf '%s\n' "$src"
  done < <(fw_rules_read)
}

# 只接受单个 IPv4/IPv6:拒绝 any、拒绝带掩码的网段
fw_validate_trust_ip() {
  local s="$1"
  [[ "$s" == "any" ]] && return 1
  [[ "$s" == */* ]] && return 1          # 拒绝 CIDR
  fw_validate_source "$s"                 # 复用格式校验(此时必无掩码)
}

# FW-INPUT:对信任 IP 放行所有流量(全协议全端口),按地址族归类
fw_build_trust_input() {  # $1=ipt $2=chain
  local ipt="$1" c="$2" ip fam
  for ip in $(fw_trust_ips); do
    fam="$(fw_addr_family "$ip")"
    case "$ipt:$fam" in iptables:6) continue ;; ip6tables:4) continue ;; esac
    "$ipt" -A "$c" -s "$ip" -j ACCEPT -m comment --comment "fw-managed:trust"
  done
}

# FW-DOCKER:放行信任 IP 对所有容器发布端口的访问,精确抵消 deny-by-default
# 用 --ctstate DNAT 限定只作用于桥接发布流量,与现有 docker 白名单/默认 DROP 对称
fw_build_trust_docker() {  # $1=ipt $2=chain
  local ipt="$1" c="$2" ip fam
  for ip in $(fw_trust_ips); do
    fam="$(fw_addr_family "$ip")"
    case "$ipt:$fam" in iptables:6) continue ;; ip6tables:4) continue ;; esac
    "$ipt" -A "$c" -s "$ip" -m conntrack --ctstate DNAT -j RETURN \
      -m comment --comment "fw-managed:trust-docker"
  done
}
```

## apply 集成（改 2 个现有函数）

调用时序用 `assert_order` 锁定（沿用 `test_firewall.sh` 既有 helper）。

**`lib/firewall/rules.sh` 的 `fw_build_input` / `fw_build_input6`**——在 ssh-guard 之后、k3s 之前插入信任放行：

```
lo → established → icmp(v6:ICMPv6 组) → ssh-guard → 【trust】 → k3s → host
```

即在 `for p in $(fw_detect_ssh_ports); do ... done` 之后、`fw_build_k3s_input "$ipt" "$c"` 之前加：

```bash
  fw_build_trust_input "$ipt" "$c"
```

信任 IP 全放行，位置不影响正确性（都是 ACCEPT）；放 ssh-guard 后、业务放行前，语义清晰且让信任流量尽早匹配。

**`lib/firewall/docker.sh` 的 `fw_build_docker`**——在 established RETURN 之后、docker 白名单之前插入：

```
established RETURN → 【trust RETURN】 → docker allow 白名单 → DNAT DROP(deny-by-default)
```

即在首行 `"$ipt" -A "$c" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN` 之后、`while read ... fw_docker_allow_rules` 之前加：

```bash
  fw_build_trust_docker "$ipt" "$c"
```

`fw_build_docker6` 已是 `fw_build_docker "$@"` 的别名，v6 自动覆盖；地址族过滤保证 v4 信任 IP 不进 v6 链。

## 菜单与状态（`lib/firewall/menu.sh`）

新增 `fw_menu_add_trust`，**强制二次确认**（默认 `n`）：

```bash
fw_menu_add_trust() {
  echo "⚠️ 信任 IP 将对该地址放行全部端口(主机 + 所有 Docker 容器端口 + 全协议)。"
  local ip comment
  ip="$(prompt_with_default "信任的单个 IP(IPv4 或 IPv6,不支持网段)" "")"
  fw_validate_trust_ip "$ip" || { echo "IP 非法(需单个 IP,不支持 any / 网段)"; return; }
  prompt_yes_no "确认对 ${ip} 开放全部端口?" "n" || { echo "已取消。"; return; }
  comment="$(prompt_with_default "备注" "")"
  fw_rules_add "trust - - - ${ip} ${comment}"
  fw_apply; echo "已添加并应用。"
}
```

`firewall_menu` 新增第 5 项，原 5–8 顺延为 6–9：

```
==== linuxshell 防火墙管理 ====
 1) 查看所有规则           6) 删除规则(按编号)
 2) 添加主机入站规则       7) 重新应用规则(apply)
 3) 添加 Docker 端口放行   8) 启用/临时禁用防火墙
 4) 管理 k3s 节点          9) 备份/恢复配置
 5) 添加信任 IP(全端口)   0) 退出
```

`case` 分支：`1)`list `2)`add_host `3)`add_docker `4)`add_node `5)`add_trust `6)`delete `7)`apply `8)`toggle `9)`backup `0)`exit。

`fw_status` 状态行追加信任 IP 计数：

```bash
local tcount; tcount="$(fw_trust_ips | wc -l | tr -d ' ')"
echo "INPUT policy: ... | FW-INPUT 跳转: ... | 规则: N 条 | 信任IP: ${tcount} 个"
```

删除、查看、备份/恢复均复用现有逻辑（`trust` 行在 `rules.conf` 中参与统一编号），无需改动。

## 加载链同步（4 处）

新增模块按项目规定同步加载顺序，放在 `k3s` 之后、`service` 之前：

新顺序：`lib/common.sh(根) → config → common → rules → docker → k3s → trust → service → menu → main`

1. `install-firewall.sh`：`load_linuxshell_modules` 列表加 `lib/firewall/trust.sh`（k3s 与 service 之间）。
2. `lib/firewall/service.sh` 生成的 `fw` 命令：`for m in config common rules docker k3s service menu main` → `... k3s trust service ...`。
3. 本设计与 `2026-06-07-firewall-management-design.md` 的加载顺序描述同步。
4. `tests/test_firewall.sh` 的 skeleton 套件：模块存在性断言与入口远程下载列表断言加 `trust`。

> 运行期正确性不依赖加载顺序：`fw_build_trust_input` 被 `rules.sh` 调用、`fw_build_trust_docker` 被 `docker.sh` 调用，均在 `fw_apply` 运行时调用，届时所有模块已 source 完毕（与现有 `fw_build_k3s_input` 跨模块调用同理）。

## 安全

- **硬约束**：`fw_validate_trust_ip` 在校验层拒绝 `any` 与任何 `/掩码` 网段，杜绝"信任 IP 退化成关防火墙"。
- **源 IP 伪造**：信任 IP 基于源地址匹配，`fw_apply` 末尾已有的 `fw_check_rp_filter` 同样覆盖此风险；将其告警文案由"k3s 节点放行依赖网络隔离"补为"k3s 节点 / 信任 IP 放行依赖网络隔离"。不阻断，提示用户依赖网络隔离。
- **二次确认**：菜单添加默认 `n`，避免误配把全端口敞开给错误地址。
- 配置文件权限沿用现有 `600`，信任 IP 同属内网拓扑敏感信息。

## 测试计划（扩展 `tests/test_firewall.sh`）

不触碰真实 iptables，沿用 mock 与 `assert_order`。新增/扩展套件：

| 套件 | 覆盖 |
|------|------|
| `skeleton`（扩展） | `assert_file_exists lib/firewall/trust.sh`；关键函数存在性 `fw_trust_ips`/`fw_validate_trust_ip`/`fw_build_trust_input`/`fw_build_trust_docker`；入口远程下载列表与 `fw` 命令 `for m` 列表含 `trust` |
| `trust_validate` | `fw_validate_trust_ip` 接受单 IPv4（`203.0.113.10`）与单 IPv6（`2001:db8::1`）；**拒绝** `any`、`10.0.0.0/24`、`::/0`、畸形串 |
| `trust_input` | `fw_build_input` 含 `-s <ip> -j ACCEPT ... fw-managed:trust`；顺序 ssh-guard → trust → k3s（`assert_order`）；地址族归类：v4 信任 IP 不出现在 `ip6tables` 调用、v6 反之 |
| `trust_docker` | `fw_build_docker` 含 `-s <ip> -m conntrack --ctstate DNAT -j RETURN ... fw-managed:trust-docker`，且在链尾 `--ctstate DNAT -j DROP` 之前（`assert_order`） |
| `docs`（扩展） | README 与本 spec 含 `trust`、"信任 IP"、"全端口" 等字面串 |

`load_*` 的 `FW_*` unset 列表无需新增变量（trust 不引入新配置项）。

## 文档更新

- README 防火墙章节：新增"信任 IP（全端口放行）"小节——配置行格式、菜单第 5 项、只允许单 IP 的约束、与 host/docker 的区别、源 IP 伪造提示。
- `2026-06-07-firewall-management-design.md`：在类型说明与加载顺序处补注 `trust`，并链接本 spec。

## 暂不做（YAGNI）

- `fw trust <ip>` / `fw untrust <ip>` CLI 直达子命令：菜单 + `rules.conf` 已足够；保持 `fw_cli` 最小。如后续有批量脚本化需求再加。
- 信任网段（CIDR）：已按用户约束明确排除。

## 实现清单（按顺序，每步可独立验证）

1. `lib/firewall/trust.sh`（新建）：`fw_trust_ips` / `fw_validate_trust_ip` / `fw_build_trust_input` / `fw_build_trust_docker`。
2. `lib/firewall/rules.sh`：`fw_build_input`、`fw_build_input6` 插入 `fw_build_trust_input` 调用（ssh-guard 后、k3s 前）。
3. `lib/firewall/docker.sh`：`fw_build_docker` 插入 `fw_build_trust_docker` 调用（established RETURN 后、白名单前）。
4. `lib/firewall/k3s.sh`：`fw_check_rp_filter` 告警文案补"信任 IP"。
5. `lib/firewall/menu.sh`：`fw_menu_add_trust` + 菜单第 5 项 + case 分支顺延 + `fw_status` 信任 IP 计数。
6. `lib/firewall/service.sh`：`fw` 命令 `for m` 列表加 `trust`。
7. `install-firewall.sh`：`load_linuxshell_modules` 列表加 `lib/firewall/trust.sh`。
8. `tests/test_firewall.sh`：上表套件，`bash tests/test_firewall.sh` 全绿。
9. README + `2026-06-07-firewall-management-design.md` 同步。
10. 全量语法检查（`bash -n`）+ `bash tests/test_firewall.sh` 回归。
11. 提交。

## 取舍记录

- **新增 `trust` 类型而非复用 `host`**：信任 IP 横跨 FW-INPUT 与 FW-DOCKER 两条链且全协议，`host` 类型本只管主机按端口放行；独立类型语义干净、与 host/docker/node 对称、查看删除天然区分。
- **独立模块 `trust.sh` 而非散入现有模块**：与 `k3s.sh` 先例一致（独立关注点、被 `fw_build_input` 跨模块调用），代价是同步 4 处加载链（项目标准动作）。
- **只允许单个 IP（用户确认）**：信任 = 全端口敞开，网段会成倍放大伪造/误配的暴露面；逐个 IP 最小化风险。需要更多主机时逐条添加。
- **FW-DOCKER 用 `--ctstate DNAT -j RETURN`**：与现有 docker 白名单、链尾 `--ctstate DNAT -j DROP` 对称，只放行被 DNAT 的桥接发布流量，host 网络容器不受影响，精确抵消 deny-by-default。
- **菜单强制二次确认（默认 n）**：高危操作防误配，与其他添加项（默认接受）区别对待。
- **不加 CLI 直达子命令**：YAGNI，菜单 + 配置文件已覆盖交互场景。
