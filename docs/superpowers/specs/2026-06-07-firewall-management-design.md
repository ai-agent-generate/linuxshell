# 防火墙管理脚本设计

为同时运行 Docker 和 k3s 的 Ubuntu / Debian 服务器提供一个交互式防火墙管理工具，支持快捷地添加、查看、删除规则。底层用 iptables 自管理，与 Docker / k3s 自身的 iptables 规则共存而不冲突。

## 背景与核心矛盾

服务器会装 Docker 与 k3s，两者都会大量改写 iptables：

- **Docker** 发布端口（`-p`）时在 `nat` 表 `PREROUTING` 做 DNAT，流量经 `FORWARD` → `DOCKER-USER` → `DOCKER` 转发到容器，**完全绕过 `INPUT` 链**。因此传统 `ufw deny <port>` 对 Docker 发布端口**无效**——这是著名陷阱。Docker 官方为此提供 `DOCKER-USER` 链作为用户钩子。
- **k3s** 的 kube-proxy（iptables 模式）+ flannel 在 `nat`/`filter` 表插入大量 `KUBE-*` 链，并周期性 reconcile（可能重排 `INPUT`）。k3s 官方不建议在节点上跑 firewalld/ufw，推荐放行节点间端口或精确配置。

所以本工具**不用 ufw/firewalld**，直接管理 iptables：主机入站走自建链，容器端口走 `DOCKER-USER`，k3s 节点间按源 IP 放行。所有自己写的规则带 `fw-managed` 注释，apply 时只动自己的规则、绝不碰 Docker/k3s 的链。

## 决策汇总

| 维度 | 决定 |
|------|------|
| 管理范围 | 主机入站 + Docker 端口访问控制 + k3s 多节点放行 |
| 底层技术 | iptables 自管理（`FW-INPUT` 自建链 + `DOCKER-USER` 钩子 + 源 IP 白名单） |
| 默认策略 | `INPUT` 默认 DROP（白名单），强制 SSH 放行防自锁 |
| 操作方式 | 交互菜单，装 `fw` 命令无参进菜单 |
| 存储模型 | 声明式配置文件 + 幂等重建 + systemd 重应用 |
| IPv6 | 一并管理（ip6tables 镜像规则，强制放行 ICMPv6/NDP） |
| 倒计时回滚 | 不做（靠强制 SSH 放行 + established 防锁） |
| 命令名 | `fw` |

## 目标与非目标

**目标**

- 交互菜单完成：查看 / 添加主机入站规则 / 添加 Docker 端口控制 / 管理 k3s 节点白名单 / 删除 / 重新应用 / 启停 / 备份恢复。
- 声明式规则文件 `/etc/linuxshell-fw/rules.conf` 为单一事实源，菜单增删改写它，apply 幂等重建。
- `INPUT` 默认 DROP，自动放行 loopback / established / SSH / ICMP，k3s 节点白名单与 CNI 流量。
- Docker 发布端口可按来源 IP 限制（用 `conntrack --ctorigdstport` 匹配发布端口）。
- IPv4 / IPv6 同时管理。
- systemd 服务在 `docker.service` / k3s 之后 boot 重应用；`fw apply` 随时幂等重建。
- 装 `fw` 命令（`/usr/local/bin/fw`），无参进菜单，另带 `apply`/`status`/`list`/`enable`/`disable` 直达子命令。
- 本地与 `curl | bash` 远程两种运行方式（入口 `install-firewall.sh`）。

**非目标**

- 不管理 `OUTPUT`（出站默认放行）。
- 不做 NAT / 端口转发 / 端口映射配置（只做访问控制）。
- 不做带宽限速、连接数限制、DPI、入侵检测。
- 不替代 k3s NetworkPolicy（pod 间策略仍由 CNI/控制器负责）。
- 不做倒计时回滚（已与用户确认）。
- 不自动发现 k3s 节点（节点 IP 由用户在菜单录入；自动发现列为未来扩展）。

## 总体架构与数据流

```
菜单/命令 ── 改写 ──> /etc/linuxshell-fw/rules.conf (声明式, 单一事实源)
                              │
                          fw apply (幂等引擎)
                              │
        ┌─────────────────────┼─────────────────────────┐
        ▼                     ▼                          ▼
   FW-INPUT 链           DOCKER-USER 链              FW-INPUT6 链 (ip6tables)
   (主机入站 v4)         (容器端口控制)              (主机入站 v6)
        │                     │                          │
   INPUT -j FW-INPUT     带 fw-managed 注释          INPUT6 -j FW-INPUT6
   INPUT policy DROP     只删/重建自己的段           INPUT6 policy DROP

   boot 时: linuxshell-fw.service (After=docker.service k3s*.service) 调 fw apply
```

**关键不变量**：所有自管理规则带 `-m comment --comment "fw-managed:<类别>"`。apply = 先按注释删除全部 `fw-managed` 规则（清理自己的旧规则，不碰他人）→ 按配置文件重新插入。幂等、可重入。

## 模块划分

沿用项目 `lib/<子系统>/` 约定。

| 文件 | 职责 |
|------|------|
| `install-firewall.sh`（仓库根） | 入口：`load_linuxshell_modules` 加载本地/远程模块 → 调 `firewall_main` |
| `lib/firewall/config.sh` | 默认配置：路径、命令名、k3s 端口组与 CIDR、CNI 接口名；全部可环境变量覆盖 |
| `lib/firewall/common.sh` | iptables/ip6tables 底层封装、`fw-managed` 注释增删、参数校验、配置文件原子读写、`require_root`/`detect_os` 依赖（复用 `lib/common.sh`） |
| `lib/firewall/rules.sh` | 主机入站规则 CRUD + `FW-INPUT` 幂等 apply 引擎 |
| `lib/firewall/docker.sh` | `DOCKER-USER` 容器端口访问控制 |
| `lib/firewall/k3s.sh` | k3s 节点白名单 + CNI（VXLAN/pod/service CIDR/接口）放行 |
| `lib/firewall/service.sh` | systemd 重应用 unit 生成 + 模块安装布局 + `fw` 命令生成 |
| `lib/firewall/menu.sh` | 交互菜单 |
| `lib/firewall/main.sh` | 编排与主入口 `firewall_main` |

加载顺序：`common(项目级) → config → common(firewall) → rules → docker → k3s → service → menu → main`

> 注意：项目根 `lib/common.sh` 与 `lib/firewall/common.sh` 同名不同路径。入口脚本与测试都先 source 根 `lib/common.sh`（提供 `require_root`/`detect_os`/`prompt_*`），再 source firewall 专属 common。

## 配置文件格式

`/etc/linuxshell-fw/rules.conf`（路径可由 `FW_RULES_FILE` 覆盖，便于测试），权限 `644`（不含密钥，可读）：

```
# type    action  proto  port      source          comment
host      allow   tcp    22        any             SSH
host      allow   tcp    80,443    any             Caddy
host      allow   tcp    5432      10.0.0.0/24     PG内网
host      allow   udp    51820     10.0.0.0/24     wireguard
docker    allow   tcp    6379      10.0.0.5        仅应用机访问Redis
docker    allow   tcp    3306      10.0.0.0/24     MySQL内网
node      -       -      -         10.0.0.1        k3s-master
node      -       -      -         10.0.0.2        k3s-agent1
```

- 字段空格/制表分隔，前 5 字段固定，第 6 字段起为 `comment`（可含空格）。
- `#` 开头与空行忽略。
- `type`：`host`（主机入站）/ `docker`（容器发布端口控制）/ `node`（k3s 节点白名单，整机放行）。
- `action`：`allow`（`node` 行恒为 `-`）。删除 = 从文件移除该行。
- `proto`：`tcp`/`udp`（`node` 为 `-`）。
- `port`：单端口 `22`、逗号多端口 `80,443`、范围 `30000:32767`（`node` 为 `-`）。
- `source`：`any` / CIDR / 单 IP。
- 解析用 `read -r type action proto port source comment`，校验后才接受。

**编号**：菜单"查看"按非注释行序给稳定编号（1 起），"删除"输入编号 → 重写文件（写临时文件再 `mv`，原子）。

## apply 引擎（IPv4，`lib/firewall/rules.sh`）

`fw_apply` 是核心。顺序与防自锁是重点。

### fw_apply 总编排

```bash
fw_apply() {
  fw_flush_managed          # 1) 清理所有 fw-managed 旧规则（v4+v6+DOCKER-USER）
  fw_apply_input            # 2) FW-INPUT：SSH guard → k3s → host，挂 INPUT 并 policy DROP
  [[ "$FW_IPV6" == on ]] && fw_have_ipv6 && fw_apply_input6   # 3) IPv6 镜像
  fw_docker_apply           # 4) DOCKER-USER：遍历 docker 规则
}
```

flush 在最前保证幂等；主机入站放行就位后各模块独立追加，互不依赖。

### FW-INPUT 链重建

```bash
fw_apply_input() {
  # 1) 确保自建链存在并清空（只清自己的链）
  iptables -nL FW-INPUT >/dev/null 2>&1 || iptables -N FW-INPUT
  iptables -F FW-INPUT

  # 2) 基础放行（防自锁优先）
  iptables -A FW-INPUT -i lo -j ACCEPT
  iptables -A FW-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A FW-INPUT -p icmp --icmp-type echo-request -j ACCEPT

  # 3) 强制放行 SSH（探测当前连接端口 + 配置端口，即使用户漏配也不锁死）
  local ssh_port
  ssh_port="$(fw_detect_ssh_port)"   # 见“防自锁”
  iptables -A FW-INPUT -p tcp --dport "$ssh_port" -j ACCEPT \
    -m comment --comment "fw-managed:ssh-guard"

  # 4) k3s 节点白名单 + CNI（见 k3s 模块）
  fw_apply_k3s_input

  # 5) host allow 规则（按配置文件）
  #    端口列表用 multiport；范围用 --dport a:b
  #    iptables -A FW-INPUT -p $proto -m multiport --dports $ports [-s $src] -j ACCEPT \
  #      -m comment --comment "fw-managed:host"

  # 6) 幂等挂到 INPUT 第一条 + policy DROP（放行就位后才设）
  iptables -C INPUT -j FW-INPUT 2>/dev/null || iptables -I INPUT 1 -j FW-INPUT
  iptables -P INPUT DROP
}
```

**FW-INPUT 链尾不 DROP，隐式 RETURN**：未匹配的流量回到 `INPUT` 继续被 `KUBE-*` 链处理（保留 k3s NodePort/ingress 的处理路径），最终撞 `INPUT policy DROP` 兜底。这样我们的白名单与 k3s 规则共存。

**插入位置**：`-j FW-INPUT` 插到 `INPUT` 第 1 条，保证 SSH/established 放行**优先于** kube-proxy 可能插入的规则——防自锁最可靠。

### 幂等清理

apply 开头先清理旧的自管理规则，避免重复堆积：

```bash
fw_flush_managed() {
  # 删除 INPUT 上指向 FW-INPUT 的跳转（稍后重建）
  while iptables -C INPUT -j FW-INPUT 2>/dev/null; do iptables -D INPUT -j FW-INPUT; done
  iptables -nL FW-INPUT >/dev/null 2>&1 && iptables -F FW-INPUT
  # IPv6 同理（若启用）
  while ip6tables -C INPUT -j FW-INPUT6 2>/dev/null; do ip6tables -D INPUT -j FW-INPUT6; done
  ip6tables -nL FW-INPUT6 >/dev/null 2>&1 && ip6tables -F FW-INPUT6
  # DOCKER-USER 上按注释删自己的（v4/v6，见 docker 模块）
  fw_docker_flush_managed
}
```

> `FW-INPUT` 内全部规则都是我们的，可整链 `-F`。`DOCKER-USER`/`INPUT` 是共享链，**只能按 `fw-managed` 注释逐条删**。

## Docker 端口控制（`lib/firewall/docker.sh`）

容器发布端口的流量到 `DOCKER-USER` 时已 DNAT（dst=容器 IP、dport=容器端口）。要按**发布端口 + 外部源**限制，用 `conntrack --ctorigdstport`（原始目标端口=发布端口）：

```bash
# 对每条 docker allow 规则：放行白名单源、拒绝其余（带 fw-managed 注释）
# 顺序要求（DOCKER-USER 自上而下）：白名单 RETURN 在前，DROP 在后，docker 默认 RETURN 在最后。
# 用 -I 插到链顶，注意 LIFO：先插 DROP 再插白名单，使白名单最终在 DROP 之前。
fw_docker_apply_rule() {  # $1=proto $2=port $3=source
  iptables -I DOCKER-USER -p "$1" -m conntrack --ctorigdstport "$2" -j DROP \
    -m comment --comment "fw-managed:docker"
  iptables -I DOCKER-USER -p "$1" -m conntrack --ctorigdstport "$2" -s "$3" -j RETURN \
    -m comment --comment "fw-managed:docker"
}

fw_docker_flush_managed() {
  # 按注释逐条删除（反复删到没有为止）
  iptables-save -t filter | grep -- 'fw-managed:docker' | sed 's/^-A/-D/' | while read -r rule; do
    iptables -t filter $rule 2>/dev/null || true
  done
}
```

- 用 `RETURN`（非 `ACCEPT`）放行：让 Docker 自己的 `DOCKER` 链继续正常转发。
- 多个白名单源 → 多条 RETURN（同一端口共用一条末尾 DROP，apply 时按端口聚合）。
- `DOCKER-USER` 不存在（未装 Docker）时跳过并提示，不报错。
- 容器**未**用 `docker allow` 显式管控的端口维持 Docker 默认放行（不主动收紧，避免误伤正常容器服务）。

## k3s 集成（`lib/firewall/k3s.sh`）

策略：**节点间整机互信 + 放行 CNI 流量**，避免逐端口漏放。

```bash
fw_apply_k3s_input() {
  # 节点白名单：对每个 node IP 全放行（节点间互信，内网集群常见做法）
  #   iptables -A FW-INPUT -s <nodeIP> -j ACCEPT -m comment --comment "fw-managed:node"

  # CNI 流量（flannel + kube）
  iptables -A FW-INPUT -p udp --dport "$FW_K3S_VXLAN_PORT" -j ACCEPT \
    -m comment --comment "fw-managed:cni-vxlan"          # flannel VXLAN 8472
  iptables -A FW-INPUT -s "$FW_K3S_POD_CIDR" -j ACCEPT \
    -m comment --comment "fw-managed:cni-pod"            # 10.42.0.0/16
  iptables -A FW-INPUT -s "$FW_K3S_SVC_CIDR" -j ACCEPT \
    -m comment --comment "fw-managed:cni-svc"            # 10.43.0.0/16
  local iface
  for iface in $FW_K3S_CNI_IFACES; do                    # cni0 flannel.1
    iptables -A FW-INPUT -i "$iface" -j ACCEPT -m comment --comment "fw-managed:cni-iface"
  done
}
```

config.sh 默认值（k3s 官方默认）：

| 变量 | 默认 | 说明 |
|------|------|------|
| `FW_K3S_VXLAN_PORT` | `8472` | flannel VXLAN（UDP） |
| `FW_K3S_POD_CIDR` | `10.42.0.0/16` | k3s 默认 pod CIDR |
| `FW_K3S_SVC_CIDR` | `10.43.0.0/16` | k3s 默认 service CIDR |
| `FW_K3S_CNI_IFACES` | `cni0 flannel.1` | CNI 接口（VXLAN backend） |

> 节点整机放行安全性略低于逐端口，但对内网集群可接受且最不易漏（6443/10250/2379-2380/NodePort 等无需逐一记忆）。需要逐端口细粒度时仍可用 `host allow` 行补充。文档提醒：wireguard backend 用 `flannel-wg` 接口与 51820/51821 UDP，可经环境变量覆盖。

## IPv6（ip6tables 镜像）

镜像 IPv4 结构，链名 `FW-INPUT6`，关键差异：

```bash
fw_apply_input6() {
  ip6tables -nL FW-INPUT6 >/dev/null 2>&1 || ip6tables -N FW-INPUT6
  ip6tables -F FW-INPUT6
  ip6tables -A FW-INPUT6 -i lo -j ACCEPT
  ip6tables -A FW-INPUT6 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  # 必须放行全部 ICMPv6：NDP（邻居发现 133-136）依赖它，否则 IPv6 网络瘫痪
  ip6tables -A FW-INPUT6 -p ipv6-icmp -j ACCEPT
  # SSH guard / host / node 同 v4（source 为 IPv6 地址或 any）
  ...
  ip6tables -C INPUT -j FW-INPUT6 2>/dev/null || ip6tables -I INPUT 1 -j FW-INPUT6
  ip6tables -P INPUT DROP
}
```

- `host`/`node` 规则中 `source=any` 时 v4/v6 都建；`source` 为具体地址时按地址族归类（含 `:` 走 ip6tables，含 `.` 走 iptables，CIDR 同理）。
- Docker IPv6：仅当 `ip6tables` 存在 `DOCKER-USER` 链（Docker 启用了 ip6tables）时镜像，否则跳过。
- 若内核无 IPv6（`/proc/net/if_inet6` 不存在），整体跳过 v6 并提示。

## 持久化与重启恢复（`lib/firewall/service.sh`）

声明式配置文件是事实源；systemd 在系统/Docker/k3s 启动后重建运行态规则。

`/etc/systemd/system/linuxshell-fw.service`：

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

- `After` 同列 `k3s.service`（server）与 `k3s-agent.service`（agent）；不存在的 unit 被 systemd 忽略，一份 unit 通用。
- **已知局限（诚实记录）**：Docker daemon **单独重启**会重置 `DOCKER-USER`，此 oneshot 不会自动触发。届时跑 `fw apply`（菜单项 6 或命令）一键重建。systemd path/timer 周期 reconcile 列为未来扩展，避免当前过度设计。

## `fw` 命令与模块安装布局

防火墙逻辑模块化、较大，`fw` 命令不内嵌全部逻辑，而是 source 已安装模块：

- 安装时把 `lib/firewall/*.sh` 复制到 `/usr/local/lib/linuxshell-fw/`（`FW_LIB_DIR` 可覆盖）。
- 生成 `/usr/local/bin/fw`：

```bash
#!/usr/bin/env bash
set -euo pipefail
FW_LIB_DIR="${FW_LIB_DIR:-/usr/local/lib/linuxshell-fw}"
# 根 lib/common.sh 安装副本（提供 require_root/prompt_* 等）
source "${FW_LIB_DIR}/linuxshell-common.sh"
for m in config common rules docker k3s service menu main; do
  source "${FW_LIB_DIR}/${m}.sh"
done
fw_cli "$@"   # 无参→菜单；apply/status/list/enable/disable→直达
```

- 根 `lib/common.sh` 复制为 `${FW_LIB_DIR}/linuxshell-common.sh` 供 fw 命令复用 `require_root` 等。
- `fw_cli` 调度：无参调 `firewall_menu`；`apply`/`status`/`list`/`enable`/`disable` 走各自函数。

## 交互菜单（`lib/firewall/menu.sh`）

```
==== linuxshell 防火墙管理 ====
状态: INPUT=DROP | 规则 N 条 | docker=已集成 | k3s=2节点 | IPv6=on
 1) 查看所有规则（配置 vs 实时 iptables 对照）
 2) 添加主机入站规则        5) 删除规则（按编号）
 3) 添加 Docker 端口控制     6) 重新应用规则（apply）
 4) 管理 k3s 节点白名单      7) 启用/临时禁用防火墙
 0) 退出                     8) 备份/恢复配置
```

- 添加类操作用根 `lib/common.sh` 的 `prompt_with_default` 分步收集（协议/端口/来源/备注），`fw_validate_*` 校验，写配置文件 → `fw_apply`。
- "查看"：左列读配置文件（带编号），右列 `iptables -nL FW-INPUT` 实时对照，便于发现配置与运行态偏差。
- "启用/禁用"：禁用 = `INPUT policy ACCEPT` + 删 `-j FW-INPUT`（临时放开，配置文件保留）；启用 = `fw_apply`。
- "备份/恢复"：备份 = `cp rules.conf rules.conf.bak.<可读时间戳由调用方传入>`；恢复 = 选备份覆盖 + apply。

## 入口脚本 `install-firewall.sh`

复用 `install-mysql-ha.sh` 的 `load_linuxshell_modules` 模式（本地存在则用本地，否则从 `LINUXSHELL_RAW_BASE_URL` 下载）：

```bash
load_linuxshell_modules \
  lib/common.sh \
  lib/firewall/config.sh \
  lib/firewall/common.sh \
  lib/firewall/rules.sh \
  lib/firewall/docker.sh \
  lib/firewall/k3s.sh \
  lib/firewall/service.sh \
  lib/firewall/menu.sh \
  lib/firewall/main.sh

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  firewall_main "$@"
fi
```

`firewall_main`：`require_root` → `detect_os` → 确保 `iptables`/`conntrack` 模块可用（必要时 `apt-get install -y iptables`）→ 安装模块到 `/usr/local/lib/` → 生成 `fw` 命令 → 写 systemd unit 并 `enable` → 初始化配置文件（若不存在，写入默认 SSH 放行）→ 首次 `fw_apply` → 进菜单。

## 错误处理与防自锁

- **SSH 强制放行**：`fw_detect_ssh_port` 优先取 `$SSH_CONNECTION` 第 4 字段（当前 sshd 端口），回退 `FW_SSH_PORT`（默认 22）。无论配置文件是否含 SSH 行，apply 始终注入 `fw-managed:ssh-guard` 放行 + established 放行，确保不断连。
- **顺序保证**：先建好 FW-INPUT 全部 ACCEPT 规则并挂到 INPUT，**最后**才 `iptables -P INPUT DROP`。
- **校验**：`fw_validate_port`（1-65535、逗号列表、`a:b` 范围）、`fw_validate_source`（`any`/IPv4/IPv6/CIDR）、`fw_validate_proto`（tcp/udp）。非法输入拒绝并提示，不写文件。
- **原子写**：配置文件改动写 `mktemp` 临时文件再 `mv`。
- **幂等**：所有 apply 可反复执行，结果一致（先删 `fw-managed` 再重建）。
- **依赖检查**：`iptables`/`ip6tables`/`conntrack`（`xt_conntrack`）缺失时明确报错或自动装。

## 测试计划 `tests/test_firewall.sh`

不触碰真实 iptables / 系统服务。沿用项目 `assert_*` 风格，mock `iptables`/`ip6tables`/`iptables-save`/`systemctl` 为记录调用到日志的函数。

| 套件 | 覆盖 |
|------|------|
| `skeleton` | 入口可执行、`bash -n` 全模块、加载顺序断言（含 `lib/common.sh`、各 firewall 模块）、关键函数存在性（`fw_apply`、`fw_docker_apply_rule`、`fw_apply_k3s_input`、`firewall_menu`、`firewall_main`、`fw_detect_ssh_port`） |
| `config` | 默认值：路径、命令名、`FW_K3S_VXLAN_PORT=8472`、`FW_K3S_POD_CIDR=10.42.0.0/16`、`FW_K3S_SVC_CIDR=10.43.0.0/16`；`DATA_ROOT`/`FW_RULES_FILE` 覆盖生效 |
| `validate` | 端口/来源/协议校验：合法通过、非法（端口 0/越界、坏 IP、坏协议）被拒 |
| `rulesfile` | 解析（跳注释/空行、多端口、备注含空格）、增删（按编号删除后重写正确）、原子写 |
| `apply` | mock iptables，断言 `fw_apply` 调用**序列与顺序**：lo→established→icmp→ssh-guard→node→cni→host→`-I INPUT 1 -j FW-INPUT`→`-P INPUT DROP`；`fw-managed` 注释存在；FW-INPUT 链尾无显式 DROP |
| `docker` | `DOCKER-USER` 规则用 `conntrack --ctorigdstport`、白名单 RETURN 在 DROP 之前、带 `fw-managed:docker` 注释、flush 按注释删除；无 `DOCKER-USER` 时跳过不报错 |
| `ipv6` | `FW-INPUT6` 含 `ipv6-icmp` ACCEPT；source 含 `:` 走 ip6tables、含 `.` 走 iptables；无 IPv6 时跳过 |
| `service` | systemd unit 含 `After=...docker.service k3s.service k3s-agent.service`、`ExecStart=/usr/local/bin/fw apply --quiet`、`Type=oneshot`；`fw` 命令脚本生成且可执行、source 模块目录、`fw_cli "$@"` |
| `lockout` | `fw_detect_ssh_port` 解析 `SSH_CONNECTION`、回退默认；apply 始终注入 `ssh-guard` 即使配置无 SSH 行 |
| `docs` | README 含 `install-firewall.sh`、`fw`、`DOCKER-USER`、`10.42.0.0/16`、防自锁说明 |

`load_*` 的 unset 列表包含全部 `FW_*` 变量，保证套件独立。

## README 更新

新增"防火墙管理"章节：一键安装命令、菜单截图（文本）、与 Docker/k3s 共存说明、`fw` 命令用法、k3s 节点白名单与 CNI CIDR 说明、IPv6 说明、关键环境变量表（`FW_RULES_FILE`/`FW_SSH_PORT`/`FW_K3S_*`/`FW_LIB_DIR`）、**已知局限**（Docker daemon 单独重启后需 `fw apply`）。

## 实现清单

按顺序（每步可独立验证）：

1. `lib/firewall/config.sh`：默认配置 + 环境变量覆盖。
2. `lib/firewall/common.sh`：iptables 封装、注释增删、校验、配置文件原子读写。
3. `lib/firewall/rules.sh`：CRUD + `fw_apply`/`fw_apply_input`/`fw_flush_managed`。
4. `lib/firewall/docker.sh`：`DOCKER-USER` 控制。
5. `lib/firewall/k3s.sh`：节点白名单 + CNI。
6. `lib/firewall/service.sh`：systemd unit + 模块安装 + `fw` 命令生成。
7. `lib/firewall/menu.sh` + `main.sh`：菜单与编排。
8. `install-firewall.sh`（`chmod +x`）+ 远程下载列表。
9. `tests/test_firewall.sh`：上表全部套件，`bash tests/test_firewall.sh` 全绿。
10. README 章节。
11. 全量语法检查 + 三套既有测试回归（确认未破坏）。
12. 提交。

## 取舍记录

- **iptables 自管理而非 ufw/firewalld**：ufw 对 Docker 发布端口失效、与 k3s kube-proxy 易冲突；自管理用 `DOCKER-USER` 官方钩子 + 自建链 + 注释标记，冲突最小、精确可控。
- **声明式配置 + 幂等重建而非 `iptables-save/restore`**：后者会连 Docker/k3s 动态规则一起存，重启 restore 与它们自建规则打架；声明式只重建自己带注释的规则，对动态环境稳健。
- **节点整机白名单而非逐端口**：内网集群互信，避免漏放 k3s 众多端口；需要细粒度时用 `host allow` 补充。
- **FW-INPUT 链尾 RETURN 不 DROP**：保留 k3s `KUBE-*` 对 NodePort/ingress 的处理路径，policy DROP 兜底。
- **不做倒计时回滚**：已与用户确认；靠 SSH 强制放行 + established 放行防锁，降低实现复杂度。
- **`fw` 命令 source 已安装模块而非自包含**：防火墙逻辑远比 `pg` wrapper 复杂，模块化便于维护与升级。
- **Docker daemon 单独重启需手动 `fw apply`**：诚实接受此局限，不引入 path/timer 周期 reconcile（YAGNI）。
