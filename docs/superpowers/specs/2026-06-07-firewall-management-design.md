# 防火墙管理脚本设计

为同时运行 Docker 和 k3s 的 Ubuntu / Debian 服务器提供一个交互式防火墙管理工具，支持快捷地添加、查看、删除规则。底层用 iptables 自管理，与 Docker / k3s 自身的 iptables 规则共存而不冲突。

> **修订说明**：本版本已采纳子代理安全/技术/一致性审查的发现，关键变更：apply 引擎改为 build-then-swap 原子替换（杜绝自锁窗口）、Docker 端口改 deny-by-default、k3s 改逐端口放行、临时禁用带超时恢复、敏感文件权限收紧为 600、`set -e` 命令容错约定、SSH 端口探测增强。

## 背景与核心矛盾

服务器会装 Docker 与 k3s，两者都会大量改写 iptables：

- **Docker** 发布端口（`-p`）时在 `nat` 表 `PREROUTING` 做 DNAT，流量经 `FORWARD` → `DOCKER-USER` → `DOCKER` 转发到容器，**完全绕过 `INPUT` 链**。因此传统 `ufw deny <port>` 对 Docker 发布端口**无效**——这是著名陷阱。Docker 官方为此提供 `DOCKER-USER` 链作为用户钩子。**本项目 `deploy.sh` 部署的 redis/mysql/pg/rabbitmq 容器默认绑 `0.0.0.0`，若不在 `DOCKER-USER` 收紧，即使 `INPUT=DROP`，这些数据库端口仍全网可达**——这正是本设计必须用 deny-by-default 堵住的核心安全漏洞。
- **k3s** 的 kube-proxy（iptables 模式）+ flannel 在 `nat`/`filter` 表插入大量 `KUBE-*` 链，并周期性 reconcile（可能重排 `INPUT`）。k3s 官方不建议在节点上跑 firewalld/ufw，推荐放行节点间端口或精确配置。

所以本工具**不用 ufw/firewalld**，直接管理 iptables：主机入站走自建链，容器端口走 `DOCKER-USER` 下的自建子链，k3s 节点间逐端口放行。所有自己写的规则带 `fw-managed` 注释，apply 时只动自己的链、绝不碰 Docker/k3s 的链。

## 决策汇总

| 维度 | 决定 |
|------|------|
| 管理范围 | 主机入站 + Docker 端口访问控制 + k3s 多节点放行 |
| 底层技术 | iptables 自管理（`FW-INPUT`/`FW-DOCKER` 自建链 + 源 IP/端口白名单） |
| 主机默认策略 | `INPUT` 默认 DROP（白名单），强制 SSH 放行防自锁 |
| **Docker 端口策略** | **deny-by-default**：`DOCKER-USER` 下所有 DNAT 入站默认 DROP，只放行 `docker allow` 白名单 |
| **k3s 节点放行** | **逐端口**放行节点 IP（非整机白名单）；检测 `rp_filter` 告警源 IP 伪造风险 |
| apply 模型 | 声明式配置 + **build-then-swap 原子替换** + systemd 重应用 |
| **临时禁用** | **带时长自动恢复**（`systemd-run --on-active`）+ 禁用态高亮告警 |
| IPv6 | 一并管理（ip6tables 镜像，ICMPv6 仅放行 NDP/echo/错误类、排除 redirect 137） |
| 操作方式 | 交互菜单，装 `fw` 命令无参进菜单 |
| 命令名 | `fw` |
| 敏感文件权限 | rules.conf/备份 `600`、目录 `700`、模块 `root:root`（对齐 mysql-ha 惯例） |

## 目标与非目标

**目标**

- 交互菜单完成：查看 / 添加主机入站规则 / 添加 Docker 端口控制 / 管理 k3s 节点 / 删除 / 重新应用 / 启停（带超时）/ 备份恢复。
- 声明式规则文件 `/etc/linuxshell-fw/rules.conf`（`600`）为单一事实源，菜单增删改写它，apply 幂等重建。
- `INPUT` 默认 DROP，自动放行 loopback / established / SSH / ICMP，k3s 节点逐端口放行 + CNI 流量。
- **Docker 发布端口 deny-by-default**：默认拒绝外部访问所有容器发布端口，只放行 `docker allow` 登记的来源（用 `conntrack --ctstate DNAT --ctorigdstport` 匹配发布端口）。
- IPv4 / IPv6 同时管理，apply 原子替换无自锁窗口。
- systemd 服务在 `docker.service` / k3s 之后 boot 重应用；`fw apply` 随时幂等重建。
- 装 `fw` 命令（`/usr/local/bin/fw`），无参进菜单，另带 `apply`/`status`/`list`/`enable`/`disable` 直达子命令。
- 本地与 `curl | bash` 远程两种运行方式（入口 `install-firewall.sh`）。

**非目标**

- 不管理 `OUTPUT`（出站默认放行）。
- 不做 NAT / 端口转发配置（只做访问控制）。
- 不做带宽限速、连接数限制、IDS。
- 不替代 k3s NetworkPolicy。
- 不做 apply 倒计时回滚（已与用户确认；靠原子替换 + SSH 强制放行防锁）。
- 不自动发现 k3s 节点（节点 IP 由用户录入）。
- **不进 `deploy.sh` 组件菜单**：防火墙是全局基础设施而非"部署一个 Docker 服务"，与 deploy.sh 的 Docker 化部署语义不同；与 pg-ha/mysql-ha 一致仅提供独立入口（见取舍记录）。

## 总体架构与数据流

```
菜单/命令 ── 改写 ──> /etc/linuxshell-fw/rules.conf (声明式, 单一事实源, 600)
                              │
                          fw apply (幂等引擎, 原子替换)
                              │
        ┌─────────────────────┼──────────────────────────┐
        ▼                     ▼                           ▼
   FW-INPUT 链           FW-DOCKER 链                 FW-INPUT6 链 (ip6tables)
   (主机入站 v4)         (DOCKER-USER 下, 容器端口)    (主机入站 v6)
   INPUT -j FW-INPUT     DOCKER-USER -j FW-DOCKER     INPUT6 -j FW-INPUT6
   INPUT policy DROP     DNAT 入站 deny-by-default    INPUT6 policy DROP

   每条自建链都用 build-then-swap：建 *-NEW → 灌规则 → 挂跳转 → 删旧 → iptables -E 重命名
   boot 时: linuxshell-fw.service (After=docker.service k3s*.service) 调 fw apply
```

**关键不变量**：所有自建链用 `<链名>-NEW` 临时构建、灌满规则后才用 `iptables -E` 原子重命名上线，**全过程父链始终指向一条有效放行链，无空窗**。自建链整链可 `-F`（内容全是我们的）；父链（`INPUT`/`DOCKER-USER`）上只用 `-C`/`-D` 管理我们那一条跳转，绝不碰他人规则。

## 模块划分

沿用项目 `lib/<子系统>/` 约定。

| 文件 | 职责 |
|------|------|
| `install-firewall.sh`（仓库根） | 入口：`load_linuxshell_modules` 加载本地/远程模块 → 依赖预检 → 安装 → 调 `firewall_main` |
| `lib/firewall/config.sh` | 默认配置：路径、命令名、k3s 端口组与 CIDR、CNI 接口名；全部可环境变量覆盖 |
| `lib/firewall/common.sh` | iptables/ip6tables 底层封装、build-then-swap 原语、`fw-managed` 注释、参数校验、配置文件原子读写、依赖预检；依赖根 `lib/common.sh` |
| `lib/firewall/rules.sh` | 主机入站规则 CRUD + `FW-INPUT` apply（含 SSH guard） |
| `lib/firewall/docker.sh` | `FW-DOCKER` 子链 deny-by-default 容器端口控制 |
| `lib/firewall/k3s.sh` | k3s 节点逐端口放行 + CNI 放行 + `rp_filter` 检测 |
| `lib/firewall/service.sh` | systemd unit 生成 + 模块安装布局 + `fw` 命令生成 + 权限设置 |
| `lib/firewall/menu.sh` | 交互菜单（含禁用态告警） |
| `lib/firewall/main.sh` | 编排与主入口 `firewall_main` |

加载顺序：`lib/common.sh(根) → config → common → rules → docker → k3s → trust → service → menu → main`（`trust` 见 `2026-06-07-firewall-trust-ip-design.md`）

> `lib/firewall/common.sh` 与根 `lib/common.sh` 同名不同路径，bash 按完整路径 source 各自定义函数、不冲突。安装到 `/usr/local/lib/linuxshell-fw/` 时根 common 改名为 `linuxshell-common.sh` 以消歧（见 fw 命令布局）。

## 配置文件格式

`/etc/linuxshell-fw/rules.conf`（路径可由 `FW_RULES_FILE` 覆盖），权限 **`600`**（含内网拓扑/节点 IP，属敏感配置，对齐 mysql-ha 600 惯例），目录 `/etc/linuxshell-fw/` 权限 `700`：

```
# type    action  proto  port      source          comment
host      allow   tcp    22        any             SSH
host      allow   tcp    80,443    any             Caddy
host      allow   tcp    5432      10.0.0.0/24     PG内网
docker    allow   tcp    6379      10.0.0.5        仅应用机访问Redis
docker    allow   tcp    3306      10.0.0.0/24     MySQL内网
node      -       -      -         10.0.0.1        k3s-master
node      -       -      -         10.0.0.2        k3s-agent1
```

- 字段空格/制表分隔，前 5 字段固定，第 6 字段起为 `comment`（可含空格）。
- `#` 开头与空行忽略。
- `type`：`host`（主机入站白名单）/ `docker`（容器发布端口的**放行例外**，因为 docker 已 deny-by-default）/ `node`（k3s 节点，放行其源 IP 的 k3s 端口组）；`trust`（信任 IP，对单个可信 IP 放行全部端口，详见 `2026-06-07-firewall-trust-ip-design.md`）
- `proto`/`port`：`tcp`/`udp`；端口支持单值、逗号列表（`multiport` ≤15 个）、范围 `a:b`。`node` 行为 `-`（端口组由 config 定义）。
- `source`：`any` / CIDR / 单 IP（IPv4 或 IPv6）。
- **sanity 校验**：拒绝等价于"关闭防火墙"的危险组合（如 `host allow tcp 0:65535 any`），或要求二次确认。
- 解析用 `read -r type action proto port source comment`，逐字段校验后才接受。

**编号**：菜单"查看"按非注释行序给稳定编号（1 起），"删除"输入编号 → 重写文件（写临时文件再 `mv`，原子）。

## 依赖预检（`firewall_main` 启动时）

apply 依赖若干内核扩展，**必须在动 policy 前预检**，缺失即拒绝执行（避免走到一半 `set -e` 崩在中间留下半套规则）：

```bash
fw_preflight() {
  require_root; detect_os
  command_exists iptables || fw_install_pkg iptables
  modprobe nf_conntrack 2>/dev/null || true
  # 校验 xt 扩展可用（用一条临时规则探测，失败即报错退出）
  fw_have_xt conntrack || fw_die "缺少 xt_conntrack，无法按状态过滤"
  fw_have_xt comment    || fw_die "缺少 xt_comment，fw-managed 标记模型依赖它"
  fw_have_xt multiport  || fw_die "缺少 xt_multiport"
  # IPv6 可选
  [[ -e /proc/net/if_inet6 ]] && command_exists ip6tables && FW_HAVE_IPV6=1 || FW_HAVE_IPV6=0
}
```

`fw_have_xt` 用 `iptables -m <mod> -h >/dev/null 2>&1` 之类探测。预检通过才进入 apply。

## `set -e` 命令容错约定

项目强制 `set -euo pipefail`。**所有探测型 / 可能空匹配的命令必须落在 `if`/`while`/`||` 结构里，或显式 `|| true`**，否则 `set -e` 会中止脚本。具体约束：

- `cond && action`（如 `iptables -C ... && iptables -D ...`）是安全 idiom：`cond` 失败被 `set -e` 短路豁免、`action` 失败才退出（符合预期）；纯存在性探测放进 `if`/`while` 条件最清晰。
- 管道里的 `grep` 空匹配才是真正的中止源：`pipefail` 下退出码经管道传播、作为独立语句不被豁免，必须 `... | grep ... || true`。
- 本设计用 build-then-swap 替代 `iptables-save | grep | sed` 清理，从根上回避这类管道脆弱性。

## build-then-swap 原语（核心，`lib/firewall/common.sh`）

所有自建链统一用此模式上线，**全程父链有有效跳转、无自锁窗口**：

```bash
# fw_chain_swap <iptables-bin> <parent> <chain> <build-fn>   （父链均在 filter 表）
# 例：fw_chain_swap iptables INPUT FW-INPUT fw_build_input
fw_chain_swap() {
  local ipt="$1" parent="$2" chain="$3" build="$4" tmp="${3}-NEW"
  # 1) 干净的临时链
  if "$ipt" -nL "$tmp" >/dev/null 2>&1; then "$ipt" -F "$tmp"; else "$ipt" -N "$tmp"; fi
  # 2) 灌规则（build-fn 往 $tmp 里 -A）
  "$build" "$tmp"
  # 3) 新链上线到父链第 1 条（此刻新旧并存，无空窗）
  "$ipt" -I "$parent" 1 -j "$tmp"
  # 4) 删除所有旧跳转
  while "$ipt" -C "$parent" -j "$chain" 2>/dev/null; do "$ipt" -D "$parent" -j "$chain"; done
  # 5) 删旧链、把新链原子重命名为正式名（-E 自动更新父链引用）
  if "$ipt" -nL "$chain" >/dev/null 2>&1; then "$ipt" -F "$chain"; "$ipt" -X "$chain"; fi
  "$ipt" -E "$tmp" "$chain"
}
```

`iptables -E`（rename-chain）会把父链里 `-j FW-INPUT-NEW` 自动改为 `-j FW-INPUT`，引用跟随，无空窗。即使 `INPUT policy` 一直是 DROP（二次 apply），步骤 3 已让新链先上线，**当前 SSH 与新连接始终被新链放行**。

## apply 引擎（`lib/firewall/rules.sh`）

`fw_apply` 总编排（每个 swap 独立、无空窗）：

```bash
fw_apply() {
  fw_preflight
  fw_chain_swap iptables  INPUT       FW-INPUT   fw_build_input
  fw_chain_swap iptables  DOCKER-USER FW-DOCKER  fw_build_docker   # 仅当 docker 在
  if [[ "$FW_HAVE_IPV6" == 1 ]]; then
    fw_chain_swap ip6tables INPUT       FW-INPUT6  fw_build_input6
    fw_docker_in_ip6 && fw_chain_swap ip6tables DOCKER-USER FW-DOCKER6 fw_build_docker6
  fi
  # 强制把 INPUT 跳转重排到第 1 条（防 kube-proxy reconcile 后下沉）
  fw_reassert_top INPUT  FW-INPUT  iptables
  [[ "$FW_HAVE_IPV6" == 1 ]] && fw_reassert_top INPUT FW-INPUT6 ip6tables
  iptables  -P INPUT DROP
  [[ "$FW_HAVE_IPV6" == 1 ]] && ip6tables -P INPUT DROP
}
```

`fw_build_input` 往传入的临时链 `-A` 写入（顺序即优先级）：

```bash
fw_build_input() {  # $1=链名（FW-INPUT-NEW）
  local c="$1"
  iptables -A "$c" -i lo -j ACCEPT
  iptables -A "$c" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A "$c" -p icmp --icmp-type echo-request -j ACCEPT
  # 强制 SSH 放行（探测所有 sshd 监听端口 + 当前连接端口 + 配置兜底）
  local p
  for p in $(fw_detect_ssh_ports); do
    iptables -A "$c" -p tcp --dport "$p" -j ACCEPT -m comment --comment "fw-managed:ssh-guard"
  done
  fw_build_k3s_input "$c"        # k3s 逐端口 + CNI
  fw_build_host_rules "$c"       # 配置文件 host allow
  # 链尾隐式 RETURN：未匹配回 INPUT 继续 KUBE-* 链，最终 policy DROP 兜底
}
```

`fw_reassert_top`：删掉 `INPUT` 上所有 `-j FW-INPUT` 再 `-I INPUT 1 -j FW-INPUT`，保证跳转始终在第 1 条（应对 kube-proxy reconcile 把它挤下沉，`-C` 只查存在不查位置）。

## Docker 端口控制（deny-by-default，`lib/firewall/docker.sh`）

容器发布端口经 DNAT，到 `DOCKER-USER` 时 dst 已是容器 IP/端口。用 `conntrack` 匹配**原始发布端口**，并用 `--ctstate DNAT` 限定**只作用于被 DNAT 的桥接发布流量**（host 网络容器不经 DNAT，天然不受影响，避免误伤）：

```bash
fw_build_docker() {  # $1=FW-DOCKER-NEW
  local c="$1" proto port src
  # 1) 放行已建立连接（含 reply / 容器出站回包），避免误杀
  iptables -A "$c" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  # 2) 白名单：放行登记的来源访问指定发布端口（仅新建 DNAT 入站）
  while read -r proto port src; do   # 来自配置文件 docker allow 行
    iptables -A "$c" -p "$proto" -m conntrack --ctstate DNAT --ctorigdstport "$port" \
      -s "$src" -j RETURN -m comment --comment "fw-managed:docker"
  done < <(fw_docker_allow_rules)
  # 3) deny-by-default：其余所有 DNAT 新建入站（= 未登记的发布端口）一律 DROP
  iptables -A "$c" -m conntrack --ctstate DNAT -j DROP -m comment --comment "fw-managed:docker-default"
  # 非 DNAT 流量（容器间/出站）不匹配 → 链尾 RETURN → DOCKER-USER 继续正常转发
}
```

- 挂载：`DOCKER-USER -j FW-DOCKER`（build-then-swap，整链可 `-F`，不再用 `iptables-save|grep|sed`）。
- `docker`/`DOCKER-USER` 不存在（未装 Docker）→ `fw_apply` 跳过该 swap，提示但不报错。
- **安全效果**：未登记的容器发布端口（含 deploy.sh 的 redis/mysql/pg）默认对外 DROP，与 `INPUT=DROP` 的白名单语义一致；对外服务（如 Caddy 80/443）需显式 `docker allow`。
- 安装时扫描 `docker ps` 发布到 `0.0.0.0` 的端口并列出，提示用户哪些将被默认拒绝、按需 `docker allow`。

## k3s 集成（逐端口，`lib/firewall/k3s.sh`）

逐端口放行节点 IP 的 k3s 必需端口（非整机白名单），即便源 IP 被伪造，暴露面也仅限 k3s 端口：

```bash
fw_build_k3s_input() {  # $1=链名
  local c="$1" ip
  for ip in $(fw_k3s_node_ips); do          # 来自配置文件 node 行
    iptables -A "$c" -s "$ip" -p tcp -m multiport --dports "$FW_K3S_TCP_PORTS" -j ACCEPT \
      -m comment --comment "fw-managed:k3s"
    iptables -A "$c" -s "$ip" -p udp -m multiport --dports "$FW_K3S_UDP_PORTS" -j ACCEPT \
      -m comment --comment "fw-managed:k3s"
  done
  # CNI 内部流量（pod 到主机、flannel 接口）
  iptables -A "$c" -s "$FW_K3S_POD_CIDR" -j ACCEPT -m comment --comment "fw-managed:cni-pod"
  local iface
  for iface in $FW_K3S_CNI_IFACES; do
    iptables -A "$c" -i "$iface" -j ACCEPT -m comment --comment "fw-managed:cni-iface"
  done
}
```

config.sh 默认值（k3s 官方默认，可环境变量覆盖）：

| 变量 | 默认 | 说明 |
|------|------|------|
| `FW_K3S_TCP_PORTS` | `6443,10250,2379,2380` | API server / kubelet / 嵌入式 etcd（HA） |
| `FW_K3S_UDP_PORTS` | `8472` | flannel VXLAN（wireguard backend 另加 `51820,51821`） |
| `FW_K3S_POD_CIDR` | `10.42.0.0/16` | k3s 默认 pod CIDR |
| `FW_K3S_CNI_IFACES` | `cni0 flannel.1` | CNI 接口（wireguard backend 为 `flannel-wg`） |

> `multiport` ≤15 端口，上述远未超限。spegel 镜像仓库（较新版本）需把 `5001` 加入 TCP。
> **`rp_filter` 检测**：逐端口仍基于源 IP，apply 时检测 `net.ipv4.conf.all.rp_filter`，为 `0`（k3s/flannel 常为转发关闭它）时**告警源 IP 伪造风险**——不阻断，提示用户依赖网络隔离。

## IPv6（ip6tables 镜像）

镜像 IPv4 结构，链名 `FW-INPUT6`/`FW-DOCKER6`，同样 build-then-swap 原子替换。关键差异：

```bash
fw_build_input6() {  # $1=FW-INPUT6-NEW
  local c="$1"
  ip6tables -A "$c" -i lo -j ACCEPT
  ip6tables -A "$c" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  # ICMPv6：放行 NDP(133-136)/echo(128-129)/错误类(1-4)/PMTU(2)/MLD(130-132)，排除 redirect(137)
  local t
  for t in 1 2 3 4 128 129 130 131 132 133 134 135 136; do
    ip6tables -A "$c" -p ipv6-icmp --icmpv6-type "$t" -j ACCEPT
  done
  # SSH guard / k3s / host 同 v4（source 按地址族归类）
  ...
}
```

- `host`/`node` 规则按地址族归类：`source=any` 时 v4/v6 都建；含 `:` 走 ip6tables、含 `.` 走 iptables、CIDR 同理（IPv4-mapped 写法 `::ffff:..` 归 v6，无害）。`fw_validate_source` 拒绝畸形混合写法。
- **Docker IPv6 同样 deny-by-default**：仅当 `ip6tables` 存在 `DOCKER-USER`（Docker 启用 ip6tables）时建 `FW-DOCKER6`，逻辑与 v4 一致，**不留 v6 静默放行缺口**。
- flush 按地址族独立（v4/v6 各自 swap），不再用 `iptables-save`(v4) 误删/漏删 v6。
- 无 IPv6（`/proc/net/if_inet6` 不存在）时整体跳过 v6。

## 持久化与重启恢复（`lib/firewall/service.sh`）

`/etc/systemd/system/linuxshell-fw.service`（`644`）：

```ini
[Unit]
Description=linuxshell firewall apply
After=network-online.target docker.service k3s.service k3s-agent.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/fw apply --quiet
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
```

- `After` 同列 k3s server/agent unit；不存在的被 systemd 忽略，一份 unit 通用。
- **已知局限（诚实记录）**：
  - Docker daemon **单独重启**重置 `DOCKER-USER`，此 oneshot 不自动触发，需 `fw apply`（菜单 6 / 命令）重建。
  - **kube-proxy 周期 reconcile** 可能重排 `INPUT` 把 `FW-INPUT` 跳转下沉；`fw apply` 时 `fw_reassert_top` 会重新置顶，但 apply 之间存在漂移窗口。高频环境可加低频 timer 重 apply（未来扩展，当前不引入以避免过度设计）。
  - **apply 失败态**：`fw_preflight` 在动 policy 前拦截缺扩展等问题；若 swap 中途异常，因新链先上线、policy 最后才设，最坏停在"放行规则已就位但 policy 仍 ACCEPT"（fail-open，优于锁死）。systemd oneshot apply 失败时 boot 后 `INPUT` 维持上次持久状态——文档明示运维需检查 `fw status`。

## `fw` 命令与模块安装布局

防火墙逻辑模块化，`fw` 命令 source 已安装模块（不内嵌）：

- `service.sh` 安装时从 **`${LINUXSHELL_MODULE_ROOT}`**（入口设的变量，本地=仓库、远程=`mktemp` 目录）复制：
  - `${LINUXSHELL_MODULE_ROOT}/lib/firewall/*.sh` → `${FW_LIB_DIR}/`（默认 `/usr/local/lib/linuxshell-fw/`）
  - `${LINUXSHELL_MODULE_ROOT}/lib/common.sh` → `${FW_LIB_DIR}/linuxshell-common.sh`
- 生成 `/usr/local/bin/fw`（`755`）：

```bash
#!/usr/bin/env bash
set -euo pipefail
FW_LIB_DIR="${FW_LIB_DIR:-/usr/local/lib/linuxshell-fw}"
source "${FW_LIB_DIR}/linuxshell-common.sh"
for m in config common rules docker k3s service menu main; do
  source "${FW_LIB_DIR}/${m}.sh"
done
fw_cli "$@"   # 无参→菜单；apply [--quiet]/status/list/enable/disable [时长]→直达
```

- `fw_cli` 解析子命令，`apply` 分支消费 `--quiet`（boot 时 systemd 用）。
- **权限矩阵**（防 source-外部-脚本 提权，root:root 且仅 root 可写）：

| 路径 | 权限 |
|------|------|
| `/etc/linuxshell-fw/` | `700` |
| `/etc/linuxshell-fw/rules.conf`、`rules.conf.bak.*` | `600` |
| `/usr/local/lib/linuxshell-fw/`（目录） | `755` |
| `/usr/local/lib/linuxshell-fw/*.sh` | `644` |
| `/usr/local/bin/fw` | `755` |
| `/etc/systemd/system/linuxshell-fw.service` | `644` |

## 交互菜单（`lib/firewall/menu.sh`）

```
==== linuxshell 防火墙管理 ====
状态: INPUT=DROP | 规则 N 条 | docker=deny-by-default(M 端口已放行) | k3s=2节点 | IPv6=on
⚠️ [仅当检测到禁用态] 防火墙当前已禁用，全端口暴露！请尽快 fw apply
 1) 查看所有规则（配置 vs 实时 iptables 对照）
 2) 添加主机入站规则        5) 删除规则（按编号）
 3) 添加 Docker 端口放行     6) 重新应用规则（apply）
 4) 管理 k3s 节点            7) 启用 / 临时禁用（可带时长）防火墙
 0) 退出                     8) 备份/恢复配置
```

- 添加类操作用根 `lib/common.sh` 的 `prompt_with_default` 分步收集，`fw_validate_*` 校验，写配置文件 → `fw_apply`。
- "查看"：左列读配置（带编号），右列 `iptables -nL FW-INPUT`/`FW-DOCKER` 实时对照。
- "添加 Docker 端口放行"：强调 docker 已 deny-by-default，这里是**加白名单例外**。
- **"启用/临时禁用"**：
  - `禁用 [时长]`（如 `30m`）= `iptables -P INPUT ACCEPT` + 删跳转；**有时长则 `systemd-run --on-active=<时长> --unit=linuxshell-fw-reenable /usr/local/bin/fw apply --quiet` 到点自动恢复**；无时长则醒目告警"无自动恢复，记得手动恢复"。
  - 每次进菜单 / `fw status` 检测到 `INPUT policy=ACCEPT` 或跳转缺失 → 顶部高亮告警（见上）。
- "备份/恢复"：备份 = `cp rules.conf rules.conf.bak.<时间戳由调用方传入>`（`600`）；恢复 = 选备份覆盖 + apply。

## 防自锁与错误处理

- **原子替换**（build-then-swap）：apply 全程 `INPUT` 始终有有效放行跳转，二次 apply（policy 已 DROP）也无空窗。这是防自锁的根基。
- **SSH 强制放行**：`fw_detect_ssh_ports` 取并集——`$SSH_CONNECTION` 端口 + `sshd -T` / `ss -tlnp` 探测的所有实际监听端口 + `FW_SSH_PORT`（默认 22）兜底；全部放行。
- **非交互无法确定 SSH 端口时拒绝设 DROP**：若 `--quiet` 且探测不到任何 sshd 端口，保持 `INPUT ACCEPT` 并告警（fail-open 优于锁死，首次远程安装尤其）。
- **依赖预检**前置（见上），动 policy 前拦截缺扩展。
- **校验**：`fw_validate_port`（1-65535、逗号 ≤15、`a:b`）、`fw_validate_source`（any/IPv4/IPv6/CIDR）、`fw_validate_proto`；危险组合（全端口 + any）拒绝或二次确认。
- **原子写**配置文件（`mktemp` + `mv`，`600`）。
- **`set -e` 容错约定**全程遵守（见上）。

## 安全加固小结

- 敏感文件 `600`、目录 `700`、模块 `root:root`（权限矩阵见上）——防本地信息泄露与提权。
- Docker / k3s / IPv6 三处全部 deny-by-default 或逐端口，消除"INPUT=DROP 但端口仍开放"的虚假安全感。
- `rp_filter` 检测告警源 IP 伪造。
- rules.conf sanity 校验拒绝自杀式规则。
- 临时禁用带超时自动恢复 + 禁用态高亮，杜绝静默 fail-open。
- README 提示远程 `curl|bash` 用户核对脚本来源（防火墙比数据库脚本更敏感；签名校验列为项目级未来工作）。

## 入口脚本 `install-firewall.sh`

复用 `install-mysql-ha.sh` 的 `load_linuxshell_modules` 模式（本地探测 `lib/firewall/config.sh` 决定本地/远程）：

```bash
load_linuxshell_modules \
  lib/common.sh \
  lib/firewall/config.sh lib/firewall/common.sh lib/firewall/rules.sh \
  lib/firewall/docker.sh lib/firewall/k3s.sh lib/firewall/service.sh \
  lib/firewall/menu.sh lib/firewall/main.sh

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  firewall_main "$@"
fi
```

`firewall_main`：`fw_preflight`（root/OS/依赖）→ 安装模块到 `${FW_LIB_DIR}`（源 `${LINUXSHELL_MODULE_ROOT}`）→ 生成 `fw` 命令 + 设权限 → 写 systemd unit 并 `enable` → 初始化 rules.conf（不存在则写默认 SSH 放行，`600`）→ 扫描 `docker ps` 暴露端口提示 → 首次 `fw_apply` → 进菜单。

## 测试计划 `tests/test_firewall.sh`（`755`）

不触碰真实 iptables / 系统服务。沿用项目 `assert_*` 风格，mock `iptables`/`ip6tables`/`systemctl`/`systemd-run`/`docker`/`sshd`/`ss` 为记录调用到日志的函数（与 `test_mysql_ha.sh` mock `systemctl`/`rsync` 同构，已验证 `set -e` 下可行）。新增 `assert_order` helper（对 action log 用 `grep -n` 比较两 pattern 行号）。

| 套件 | 覆盖 |
|------|------|
| `skeleton` | 入口可执行、`bash -n` 全模块、**逐模块 `assert_file_exists lib/firewall/<m>.sh`**、入口远程下载列表含每模块 + `lib/common.sh`、关键函数存在性（`fw_apply`/`fw_chain_swap`/`fw_build_input`/`fw_build_docker`/`fw_build_k3s_input`/`fw_detect_ssh_ports`/`firewall_menu`/`firewall_main`/`fw_preflight`） |
| `config` | 默认值：`FW_K3S_TCP_PORTS=6443,10250,2379,2380`、`FW_K3S_UDP_PORTS=8472`、`FW_K3S_POD_CIDR=10.42.0.0/16`、`FW_RULES_FILE`/`FW_LIB_DIR` 默认与覆盖（**不挂 `DATA_ROOT`**，rules.conf 在 `/etc`） |
| `validate` | 端口/来源/协议校验；multiport >15 拒绝；危险组合（全端口+any）拒绝 |
| `rulesfile` | 解析（注释/空行/多端口/含空格备注）、按编号删除重写、原子写、**权限 600** |
| `swap` | `fw_chain_swap` 调用序列：建 `-NEW` → 灌规则 → `-I parent 1 -j *-NEW` → 删旧跳转 → `-X` 旧链 → **`-E *-NEW <chain>`**；断言**全程父链有跳转**（`-I` 在 `-D` 旧跳转之前）—— 用 `assert_order` 验证无空窗 |
| `apply` | `fw_build_input` 顺序（`assert_order`）：lo→established→icmp→ssh-guard→k3s→cni→host；`fw_reassert_top` 重排；policy DROP 最后 |
| `docker` | `FW-DOCKER` deny-by-default：established RETURN 在前、白名单 `--ctstate DNAT --ctorigdstport` RETURN、链尾 `--ctstate DNAT -j DROP`；无 docker 时跳过；mock `docker ps` 扫描提示 |
| `k3s` | 逐端口 `multiport --dports $FW_K3S_TCP_PORTS`、节点 IP 来源、CNI 放行；`rp_filter=0` 触发告警 |
| `ipv6` | `FW-INPUT6` 放行 NDP/echo/错误类 ICMPv6、**不含 type 137**；地址族归类；Docker v6 deny-by-default；无 IPv6 跳过 |
| `service` | unit 含 `After=...docker.service k3s.service k3s-agent.service`、`ExecStart=/usr/local/bin/fw apply --quiet`、`Type=oneshot`；`fw` 命令生成、source `linuxshell-common.sh` + 模块、`fw_cli "$@"`；**权限矩阵**（rules.conf 600、模块 644、fw 755）；安装源用 `${LINUXSHELL_MODULE_ROOT}` |
| `lockout` | `fw_detect_ssh_ports` 取 `$SSH_CONNECTION` + `sshd -T`/`ss` 探测并集 + 兜底；非交互探测不到时**不设 DROP** |
| `disable` | 带时长禁用调 `systemd-run --on-active`；禁用态检测触发告警 |
| `docs` | README 含 `/usr/local/bin/fw`、`fw apply`、`DOCKER-USER`、`deny-by-default`、`10.42.0.0/16`、防自锁/局限说明（断言用具体字面串，避免脆弱的 `fw` 子串匹配） |

`load_*` 的 unset 列表含全部 `FW_*` 变量，保证套件独立。`-m conntrack`/`--ctorigdstport` 只是被 mock 函数记录的字符串，不触达内核，无需真实 conntrack。

## README 更新

新增"防火墙管理"章节：一键安装命令、菜单（文本）、与 Docker/k3s 共存说明、**Docker 端口 deny-by-default 与如何 `docker allow` 对外服务**、`fw` 命令用法、k3s 逐端口与节点录入、IPv6 说明、关键环境变量表（`FW_RULES_FILE`/`FW_SSH_PORT`/`FW_K3S_*`/`FW_LIB_DIR`）、**已知局限**（Docker daemon 重启 / kube-proxy 漂移需 `fw apply`；apply 失败态查 `fw status`）、远程来源核对提示。

## 实现清单

按顺序（每步可独立验证）：

1. `lib/firewall/config.sh`：默认配置 + 环境变量覆盖。
2. `lib/firewall/common.sh`：iptables 封装、`fw_chain_swap`/`fw_reassert_top` 原语、注释/校验、配置文件原子读写（600）、`fw_preflight`/`fw_have_xt`、`fw_detect_ssh_ports`。
3. `lib/firewall/rules.sh`：CRUD + `fw_apply`/`fw_build_input`/`fw_build_host_rules`。
4. `lib/firewall/docker.sh`：`FW-DOCKER` deny-by-default + `docker ps` 扫描。
5. `lib/firewall/k3s.sh`：逐端口放行 + CNI + `rp_filter` 检测。
6. `lib/firewall/service.sh`：systemd unit + 模块安装（源 `${LINUXSHELL_MODULE_ROOT}`，含复制根 `lib/common.sh`→`linuxshell-common.sh`）+ `fw` 命令 + **权限矩阵**。
7. `lib/firewall/menu.sh` + `main.sh`：菜单（禁用带时长 + 禁用态告警）与编排。
8. `install-firewall.sh`（`chmod +x`）+ 远程下载列表。
9. `tests/test_firewall.sh`（`chmod +x`）：上表全部套件 + `assert_order` helper，`bash tests/test_firewall.sh` 全绿。
10. README 章节。
11. 全量语法检查 + 三套既有测试回归。
12. 提交。

## 取舍记录

- **iptables 自管理而非 ufw/firewalld**：ufw 对 Docker 发布端口失效、与 k3s kube-proxy 易冲突；自管理用 `DOCKER-USER` 钩子 + 自建链 + 注释标记，冲突最小、精确可控。
- **build-then-swap 原子替换而非"先 flush 再重建"**：后者在二次 apply（policy 已 DROP）时，flush 掉 established/ssh-guard 后到重建前有自锁窗口，会锁死远程；原子替换全程父链有有效跳转，无空窗。一并替代 `iptables-save|grep|sed` 清理（回避 `set -e` 空匹配中止与 save/restore 往返不稳健）。
- **Docker 端口 deny-by-default**（用户确认）：与 `INPUT=DROP` 白名单语义一致，消除"数据库端口绕过 INPUT 全网可达却显示 INPUT=DROP"的虚假安全感；对外服务显式 `docker allow`。用 `--ctstate DNAT` 限定只作用于桥接发布流量，host 网络容器不误伤。
- **k3s 逐端口而非整机白名单**（用户确认）：整机 `-s ACCEPT` 在源 IP 可伪造（rp_filter 关闭）时绕过全部入站管控；逐端口即便被伪造，暴露面也仅限 k3s 端口。代价是 k3s 改配置/版本时可能要更新端口组（环境变量可覆盖）。
- **临时禁用带超时自动恢复**（用户确认）：避免"禁用后忘记恢复 = 长期 fail-open 全端口暴露"的经典事故；用 `systemd-run --on-active` 到点自动 `fw apply`。
- **敏感文件 600 / 目录 700 / 模块 root:root**：rules.conf 含内网拓扑属敏感配置，对齐 mysql-ha 600 惯例；防本地信息泄露与 source-外部-脚本 提权。
- **ICMPv6 仅放行必需类型、排除 redirect(137)**：满足 NDP/PMTU/echo，同时不引入 redirect 可被用于路由劫持的风险（RFC 4890 加固）。
- **`fw` 命令 source 已安装模块而非自包含**：防火墙逻辑远比 `pg` wrapper 复杂，模块化便于维护；安装源用 `${LINUXSHELL_MODULE_ROOT}` 兼容本地与远程运行。
- **不进 deploy.sh 组件菜单**：防火墙是全局基础设施而非"部署一个 Docker 服务"，与 deploy.sh 的 Docker 化部署语义不同；与 pg-ha/mysql-ha 先例一致，仅提供独立入口。
- **kube-proxy 漂移不引入周期 timer**：apply 时 `fw_reassert_top` 重新置顶已覆盖大多数情况，周期 reconcile 列为未来扩展，避免当前过度设计；诚实记录漂移窗口局限。
