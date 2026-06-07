# 防火墙信任 IP（全端口放行）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为防火墙工具新增 `trust` 规则类型，把单个可信 IP 列入白名单、对其放行全部端口（主机所有端口 + 所有 Docker 容器发布端口 + 全协议）。

**Architecture:** 新增 `lib/firewall/trust.sh`（与 `k3s.sh` 同构），提供读取 / 校验 / 构建函数；在 `FW-INPUT` 链写 `-s <ip> -j ACCEPT`、在 `FW-DOCKER` 链写 `-s <ip> --ctstate DNAT -j RETURN`，由 `rules.sh` / `docker.sh` 现有 build 函数在 `fw_apply` 运行时调用；菜单新增添加项并强制二次确认；同步模块加载链（入口 / fw 命令 / 模块安装 / 测试）。

**Tech Stack:** Bash（`set -euo pipefail`）、iptables / ip6tables、项目自有测试框架（`assert_*` + mock 函数 + `assert_order`）。

**Spec:** `docs/superpowers/specs/2026-06-07-firewall-trust-ip-design.md`

---

## File Structure

| 文件 | 动作 | 职责 |
|------|------|------|
| `lib/firewall/trust.sh` | **新建** | `fw_trust_ips` / `fw_validate_trust_ip` / `fw_build_trust_input` / `fw_build_trust_docker` |
| `lib/firewall/rules.sh` | 改 | `fw_build_input`、`fw_build_input6` 插入 `fw_build_trust_input` 调用 |
| `lib/firewall/docker.sh` | 改 | `fw_build_docker` 插入 `fw_build_trust_docker` 调用 |
| `lib/firewall/k3s.sh` | 改 | `fw_check_rp_filter` 告警文案补“信任 IP” |
| `lib/firewall/menu.sh` | 改 | `fw_menu_add_trust` + 菜单第 5 项 + case 顺延 + `fw_status` 信任 IP 计数 |
| `lib/firewall/service.sh` | 改 | `fw_write_command` 与 `fw_install_modules` 两处 `for m` 列表加 `trust` |
| `install-firewall.sh` | 改 | `load_linuxshell_modules` 列表加 `lib/firewall/trust.sh` |
| `tests/test_firewall.sh` | 改 | `load_firewall` + skeleton + 4 个新套件 + main 注册 |
| `README.md` | 改 | 新增“信任 IP（全端口放行）”小节 |
| `docs/superpowers/specs/2026-06-07-firewall-management-design.md` | 改 | 类型说明与加载顺序补注 `trust` |

**加载顺序（新）：** `lib/common.sh(根) → config → common → rules → docker → k3s → trust → service → menu → main`

> 运行期正确性不依赖加载顺序：`fw_build_trust_input` 被 `rules.sh` 调用、`fw_build_trust_docker` 被 `docker.sh` 调用，均在 `fw_apply` 运行时调用，届时所有模块已 source 完毕（与现有 `fw_build_k3s_input` 跨模块调用同理）。

---

## Task 1: 新建 trust.sh —— 读取与校验

**Files:**
- Create: `lib/firewall/trust.sh`
- Modify: `tests/test_firewall.sh`（`load_firewall` 加一行 source；新增 `run_trust_validate_tests`；main 注册）

- [ ] **Step 1: 写失败测试**

在 `tests/test_firewall.sh` 中，于 `run_lockout_tests()` 函数之后、`main()` 之前插入新函数：

```bash
run_trust_validate_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  export FW_RULES_DIR="${temp_root}/etc" FW_RULES_FILE="${temp_root}/etc/rules.conf"
  load_firewall

  # 单个 IPv4/IPv6 通过
  fw_validate_trust_ip 203.0.113.10 || fail "single ipv4 should pass"
  fw_validate_trust_ip "2001:db8::1" || fail "single ipv6 should pass"
  # any / 网段 / 畸形 一律拒绝
  if fw_validate_trust_ip any 2>/dev/null; then fail "any should fail"; fi
  if fw_validate_trust_ip 10.0.0.0/24 2>/dev/null; then fail "ipv4 cidr should fail"; fi
  if fw_validate_trust_ip "2001:db8::/32" 2>/dev/null; then fail "ipv6 cidr should fail"; fi
  if fw_validate_trust_ip garbage 2>/dev/null; then fail "garbage should fail"; fi

  # fw_trust_ips 只读 trust 行
  fw_rules_add "host allow tcp 22 any SSH"
  fw_rules_add "trust - - - 203.0.113.10 office"
  fw_rules_add "trust - - - 2001:db8::1 jump"
  assert_equals "203.0.113.10" "$(fw_trust_ips | head -1)"
  assert_equals "2" "$(fw_trust_ips | wc -l | tr -d ' ')"
}
```

在 `main()` 的 `case` 中，于 `lockout)` 行之后加：

```bash
    trust_validate) run_trust_validate_tests ;;
```

在 `all)` 这一行的末尾（`run_docker_tests;` 之后）插入：

```bash
run_trust_validate_tests;
```

使该处变为 `... run_docker_tests; run_trust_validate_tests; run_k3s_tests; ...`

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash tests/test_firewall.sh trust_validate`
Expected: FAIL —— `fw_validate_trust_ip: command not found`（函数尚未定义）

- [ ] **Step 3: 创建 trust.sh**

新建 `lib/firewall/trust.sh`，内容：

```bash
# 信任 IP:对单个可信 IP 放行全部端口(主机 + 所有 Docker 容器端口 + 全协议)

# 读配置 trust 行,输出信任 IP
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
  [[ "$s" == */* ]] && return 1
  fw_validate_source "$s"
}
```

- [ ] **Step 4: 把 trust.sh 接入测试加载器**

在 `tests/test_firewall.sh` 的 `load_firewall()` 中，于 `source "${ROOT_DIR}/lib/firewall/k3s.sh"` 之后插入一行：

```bash
  source "${ROOT_DIR}/lib/firewall/trust.sh"
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `bash tests/test_firewall.sh trust_validate`
Expected: `PASS: trust_validate`

- [ ] **Step 6: 提交**

```bash
git add lib/firewall/trust.sh tests/test_firewall.sh
git commit -m "feat(firewall): 新增 trust 模块的信任 IP 读取与校验"
```

---

## Task 2: FW-INPUT 接入 —— 信任 IP 主机放行

**Files:**
- Modify: `lib/firewall/trust.sh`（追加 `fw_build_trust_input`）
- Modify: `lib/firewall/rules.sh`（`fw_build_input`、`fw_build_input6` 插入调用）
- Modify: `tests/test_firewall.sh`（新增 `run_trust_input_tests`；main 注册）

- [ ] **Step 1: 写失败测试**

在 `tests/test_firewall.sh` 中 `run_trust_validate_tests()` 之后插入：

```bash
run_trust_input_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  local log="${temp_root}/ipt.log"
  export FW_RULES_DIR="${temp_root}/etc" FW_RULES_FILE="${temp_root}/etc/rules.conf"
  export FW_SSH_PORT=22
  load_firewall
  iptables() { echo "iptables $*" >>"$log"; return 0; }
  ip6tables() { echo "ip6tables $*" >>"$log"; return 0; }
  command_exists() { case "$1" in sshd) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  fw_rules_add "trust - - - 203.0.113.10 office"
  fw_rules_add "trust - - - 2001:db8::1 jump"
  fw_rules_add "node - - - 10.0.0.1 master"

  # IPv4 入站链:含 v4 信任 IP,排除 v6 信任 IP;顺序 ssh-guard → trust → k3s
  : >"$log"
  ( unset SSH_CONNECTION; fw_build_input iptables FW-INPUT )
  assert_contains "$log" "-s 203.0.113.10 -j ACCEPT"
  assert_contains "$log" "fw-managed:trust"
  assert_not_contains "$log" "2001:db8::1"
  assert_order "$log" "fw-managed:ssh-guard" "fw-managed:trust"
  assert_order "$log" "fw-managed:trust" "fw-managed:k3s"

  # IPv6 入站链:含 v6 信任 IP,排除 v4 信任 IP
  : >"$log"
  ( unset SSH_CONNECTION; fw_build_input6 ip6tables FW-INPUT6 )
  assert_contains "$log" "-s 2001:db8::1 -j ACCEPT"
  assert_not_contains "$log" "203.0.113.10"
}
```

在 `main()` 的 `case` 中 `trust_validate)` 行之后加：

```bash
    trust_input) run_trust_input_tests ;;
```

在 `all)` 行中 `run_trust_validate_tests;` 之后插入 `run_trust_input_tests;`

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash tests/test_firewall.sh trust_input`
Expected: FAIL —— `fw_build_trust_input: command not found`

- [ ] **Step 3: 在 trust.sh 追加 fw_build_trust_input**

在 `lib/firewall/trust.sh` 末尾追加：

```bash
# FW-INPUT:对信任 IP 放行所有流量(全协议全端口),按地址族归类
fw_build_trust_input() {  # $1=ipt $2=chain
  local ipt="$1" c="$2" ip fam
  for ip in $(fw_trust_ips); do
    fam="$(fw_addr_family "$ip")"
    case "$ipt:$fam" in iptables:6) continue ;; ip6tables:4) continue ;; esac
    "$ipt" -A "$c" -s "$ip" -j ACCEPT -m comment --comment "fw-managed:trust"
  done
}
```

- [ ] **Step 4: 在 rules.sh 插入调用**

在 `lib/firewall/rules.sh` 的 `fw_build_input` 中，把 ssh-guard 的 `for ... done` 与 `fw_build_k3s_input` 之间改为（插入一行 `fw_build_trust_input`）：

```bash
  for p in $(fw_detect_ssh_ports); do
    "$ipt" -A "$c" -p tcp --dport "$p" -j ACCEPT -m comment --comment "fw-managed:ssh-guard"
  done
  fw_build_trust_input "$ipt" "$c"
  fw_build_k3s_input "$ipt" "$c"
  fw_build_host_rules "$ipt" "$c"
```

在同文件 `fw_build_input6` 中做同样插入（ssh-guard `for ... done` 之后、`fw_build_k3s_input` 之前）：

```bash
  for p in $(fw_detect_ssh_ports); do
    "$ipt" -A "$c" -p tcp --dport "$p" -j ACCEPT -m comment --comment "fw-managed:ssh-guard"
  done
  fw_build_trust_input "$ipt" "$c"
  fw_build_k3s_input "$ipt" "$c"
  fw_build_host_rules "$ipt" "$c"
```

- [ ] **Step 5: 运行测试（含回归），确认通过**

Run: `bash tests/test_firewall.sh trust_input && bash tests/test_firewall.sh apply && bash tests/test_firewall.sh ipv6`
Expected: 三行 `PASS`（`trust_input` / `apply` / `ipv6`，确认未破坏原入站链顺序）

- [ ] **Step 6: 提交**

```bash
git add lib/firewall/trust.sh lib/firewall/rules.sh tests/test_firewall.sh
git commit -m "feat(firewall): 信任 IP 接入 FW-INPUT 主机放行(v4/v6 按族归类)"
```

---

## Task 3: FW-DOCKER 接入 —— 信任 IP 容器端口放行

**Files:**
- Modify: `lib/firewall/trust.sh`（追加 `fw_build_trust_docker`）
- Modify: `lib/firewall/docker.sh`（`fw_build_docker` 插入调用）
- Modify: `tests/test_firewall.sh`（新增 `run_trust_docker_tests`；main 注册）

- [ ] **Step 1: 写失败测试**

在 `tests/test_firewall.sh` 中 `run_trust_input_tests()` 之后插入：

```bash
run_trust_docker_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  local log="${temp_root}/ipt.log"
  export FW_RULES_DIR="${temp_root}/etc" FW_RULES_FILE="${temp_root}/etc/rules.conf"
  load_firewall
  iptables() { echo "iptables $*" >>"$log"; return 0; }
  fw_rules_add "trust - - - 203.0.113.10 office"
  fw_rules_add "docker allow tcp 6379 10.0.0.5 redis"
  : >"$log"
  fw_build_docker iptables FW-DOCKER-NEW
  # 信任 IP 的 DNAT RETURN 在 established 之后、deny-by-default DROP 之前
  assert_contains "$log" "-s 203.0.113.10 -m conntrack --ctstate DNAT -j RETURN"
  assert_contains "$log" "fw-managed:trust-docker"
  assert_order "$log" "ESTABLISHED,RELATED -j RETURN" "fw-managed:trust-docker"
  assert_order "$log" "fw-managed:trust-docker" "ctstate DNAT -j DROP"
}
```

在 `main()` 的 `case` 中 `trust_input)` 行之后加：

```bash
    trust_docker) run_trust_docker_tests ;;
```

在 `all)` 行中 `run_trust_input_tests;` 之后插入 `run_trust_docker_tests;`

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash tests/test_firewall.sh trust_docker`
Expected: FAIL —— 日志中无 `fw-managed:trust-docker`（`assert_contains` 失败）

- [ ] **Step 3: 在 trust.sh 追加 fw_build_trust_docker**

在 `lib/firewall/trust.sh` 末尾追加：

```bash
# FW-DOCKER:放行信任 IP 对所有容器发布端口的访问
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

- [ ] **Step 4: 在 docker.sh 插入调用**

在 `lib/firewall/docker.sh` 的 `fw_build_docker` 中，把首行 established RETURN 与 `while read` 之间插入 `fw_build_trust_docker` 调用：

```bash
fw_build_docker() {  # $1=ipt $2=chain
  local ipt="$1" c="$2" proto port src fam srcopt pp _ports
  "$ipt" -A "$c" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  fw_build_trust_docker "$ipt" "$c"
  while read -r proto port src; do
```

（其余行不变。）

- [ ] **Step 5: 运行测试（含回归），确认通过**

Run: `bash tests/test_firewall.sh trust_docker && bash tests/test_firewall.sh docker`
Expected: 两行 `PASS`（`trust_docker` / `docker`，确认未破坏 deny-by-default 顺序）

- [ ] **Step 6: 提交**

```bash
git add lib/firewall/trust.sh lib/firewall/docker.sh tests/test_firewall.sh
git commit -m "feat(firewall): 信任 IP 接入 FW-DOCKER 容器端口放行"
```

---

## Task 4: 菜单与状态 —— 添加项 + 二次确认 + 计数

**Files:**
- Modify: `lib/firewall/menu.sh`（`fw_status` 计数、`fw_menu_add_trust`、菜单文本、`case` 顺延）
- Modify: `tests/test_firewall.sh`（新增 `run_trust_status_tests`；main 注册）

- [ ] **Step 1: 写失败测试**

在 `tests/test_firewall.sh` 中 `run_trust_docker_tests()` 之后插入：

```bash
run_trust_status_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  export FW_RULES_DIR="${temp_root}/etc" FW_RULES_FILE="${temp_root}/etc/rules.conf"
  load_firewall
  iptables() { case "$1" in -nL) echo "Chain INPUT (policy DROP)" ;; -C) return 0 ;; esac; return 0; }
  fw_rules_add "trust - - - 203.0.113.10 office"
  fw_rules_add "trust - - - 198.51.100.7 vpn"
  grep -Fq "信任IP: 2" <<<"$(fw_status 2>&1)" || fail "expected trust ip count in status"
}
```

在 `main()` 的 `case` 中 `trust_docker)` 行之后加：

```bash
    trust_status) run_trust_status_tests ;;
```

在 `all)` 行中 `run_trust_docker_tests;` 之后插入 `run_trust_status_tests;`

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash tests/test_firewall.sh trust_status`
Expected: FAIL —— `expected trust ip count in status`（状态行尚无“信任IP:”）

- [ ] **Step 3: fw_status 增加信任 IP 计数**

在 `lib/firewall/menu.sh` 的 `fw_status` 中，把局部变量声明与 echo 改为（新增 `tcount`）：

```bash
fw_status() {
  local policy jump="no" count tcount
  policy="$(iptables -nL INPUT 2>/dev/null | awk 'NR==1{print $4}' | tr -d '()')"
  iptables -C INPUT -j "$FW_INPUT_CHAIN" 2>/dev/null && jump="yes"
  count="$(fw_rules_read | wc -l | tr -d ' ')"
  tcount="$(fw_trust_ips | wc -l | tr -d ' ')"
  echo "INPUT policy: ${policy:-unknown} | FW-INPUT 跳转: ${jump} | 规则: ${count} 条 | 信任IP: ${tcount} 个"
  if [[ "$policy" == "ACCEPT" || "$jump" == "no" ]]; then
    echo "⚠️ 防火墙当前已禁用,全端口暴露!请尽快 'fw apply'。" >&2
  fi
}
```

- [ ] **Step 4: 新增 fw_menu_add_trust**

在 `lib/firewall/menu.sh` 的 `fw_menu_add_node()` 函数之后插入：

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

- [ ] **Step 5: 菜单文本与 case 顺延**

在 `lib/firewall/menu.sh` 的 `firewall_menu` 中，把菜单 here-doc 改为（新增第 5 项，原 5–8 顺延为 6–9）：

```bash
==== linuxshell 防火墙管理 ====
 1) 查看所有规则           6) 删除规则(按编号)
 2) 添加主机入站规则       7) 重新应用规则(apply)
 3) 添加 Docker 端口放行   8) 启用/临时禁用防火墙
 4) 管理 k3s 节点          9) 备份/恢复配置
 5) 添加信任 IP(全端口)   0) 退出
EOF
```

并把 `case "$choice" in ... esac` 改为：

```bash
    case "$choice" in
      1) fw_menu_list ;;
      2) fw_menu_add_host ;;
      3) fw_menu_add_docker ;;
      4) fw_menu_add_node ;;
      5) fw_menu_add_trust ;;
      6) fw_menu_delete ;;
      7) fw_apply; echo "已重新应用。" ;;
      8) fw_menu_toggle ;;
      9) fw_menu_backup ;;
      0) return 0 ;;
      *) echo "无效选择。" ;;
    esac
```

- [ ] **Step 6: 运行测试（含回归），确认通过**

Run: `bash tests/test_firewall.sh trust_status && bash tests/test_firewall.sh disable && bash tests/test_firewall.sh orchestration`
Expected: 三行 `PASS`（`trust_status` / `disable` 回归 fw_status / `orchestration` 回归菜单路由）

- [ ] **Step 7: 提交**

```bash
git add lib/firewall/menu.sh tests/test_firewall.sh
git commit -m "feat(firewall): 菜单新增信任 IP 添加项(二次确认)与状态计数"
```

---

## Task 5: 同步加载链 + skeleton 断言

**Files:**
- Modify: `tests/test_firewall.sh`（skeleton 的 `for m` 列表、函数清单；`run_service_tests` 加 trust.sh 断言）
- Modify: `install-firewall.sh`（加载列表加 `lib/firewall/trust.sh`）
- Modify: `lib/firewall/service.sh`（`fw_write_command` 与 `fw_install_modules` 两处 `for m`）

- [ ] **Step 1: 更新 skeleton 与 service 测试断言（失败）**

在 `tests/test_firewall.sh` 的 `run_skeleton_tests` 中，把模块循环列表加上 `trust`：

```bash
  for m in config common rules docker k3s trust service menu main; do
```

并在函数存在性循环（`for fn in ...`）中，于 `fw_build_k3s_input fw_k3s_node_ips fw_check_rp_filter \` 之后加一行：

```bash
            fw_trust_ips fw_validate_trust_ip fw_build_trust_input fw_build_trust_docker fw_menu_add_trust \
```

在 `run_service_tests` 中，于 `fw_install_modules` 调用后的断言区（`assert_file_exists "${FW_LIB_DIR}/common.sh"` 附近）加一行，验证 trust.sh 被复制：

```bash
  assert_file_exists "${FW_LIB_DIR}/trust.sh"
```

并在 `fw_write_command` 之后的断言区（`assert_contains "$FW_BIN" 'fw_cli "$@"'` 附近）加一行，验证 fw 命令 source 列表含 trust：

```bash
  assert_contains "$FW_BIN" "k3s trust service"
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash tests/test_firewall.sh skeleton`
Expected: FAIL —— `expected 'lib/firewall/trust.sh' in .../install-firewall.sh`（入口尚未列出 trust 模块）

- [ ] **Step 3: install-firewall.sh 加载列表加 trust**

在 `install-firewall.sh` 的 `load_linuxshell_modules \` 调用中，于 `lib/firewall/k3s.sh \` 之后插入一行：

```bash
  lib/firewall/trust.sh \
```

使其位于 `lib/firewall/k3s.sh \` 与 `lib/firewall/service.sh \` 之间。

- [ ] **Step 4: service.sh 两处 for 列表加 trust**

在 `lib/firewall/service.sh` 的 `fw_write_command` 中，把生成的 fw 命令 source 循环改为：

```bash
for m in config common rules docker k3s trust service menu main; do
```

在同文件 `fw_install_modules` 中，把安装循环改为：

```bash
  for m in config common rules docker k3s trust service menu main; do
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `bash tests/test_firewall.sh skeleton && bash tests/test_firewall.sh service`
Expected: 两行 `PASS`（`skeleton` / `service`）

- [ ] **Step 6: 提交**

```bash
git add install-firewall.sh lib/firewall/service.sh tests/test_firewall.sh
git commit -m "feat(firewall): 同步 trust 模块加载链(入口/fw命令/安装/测试)"
```

---

## Task 6: rp_filter 文案 + 文档

**Files:**
- Modify: `tests/test_firewall.sh`（`run_docs_tests` 加“信任 IP”断言）
- Modify: `README.md`（新增信任 IP 小节）
- Modify: `lib/firewall/k3s.sh`（`fw_check_rp_filter` 文案）
- Modify: `docs/superpowers/specs/2026-06-07-firewall-management-design.md`（补注 trust）

- [ ] **Step 1: docs 测试加断言（失败）**

在 `tests/test_firewall.sh` 的 `run_docs_tests` 末尾（`assert_contains "$readme" "10.42.0.0/16"` 之后）加一行：

```bash
  assert_contains "$readme" "信任 IP"
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash tests/test_firewall.sh docs`
Expected: FAIL —— `expected '信任 IP' in .../README.md`

- [ ] **Step 3: README 新增信任 IP 小节**

在 `README.md` 的“**Docker 端口 deny-by-default**”段落（以 `**Docker 端口 deny-by-default**` 开头那一行）之后插入一个空行和如下段落：

```markdown
**信任 IP（全端口放行）**：菜单“添加信任 IP（全端口）”录入**单个**可信 IP（IPv4 或 IPv6，不支持网段 / `any`），对其放行全部端口——主机所有监听端口 + 所有 Docker 容器发布端口 + 全协议，相当于完全信任该地址。属高危操作，添加时需二次确认；基于源 IP 匹配，防伪造依赖网络隔离（`rp_filter`）。配置行形如 `trust - - - 203.0.113.10 备注`。
```

- [ ] **Step 4: k3s.sh 告警文案补“信任 IP”**

在 `lib/firewall/k3s.sh` 的 `fw_check_rp_filter` 中，把告警 echo 改为：

```bash
    echo "警告:rp_filter=0,源 IP 伪造防护未启用;k3s 节点 / 信任 IP 放行依赖网络隔离。" >&2
```

- [ ] **Step 5: 原设计文档补注 trust**

在 `docs/superpowers/specs/2026-06-07-firewall-management-design.md` 中做两处补注：

其一，在“配置文件格式”小节里 `type` 取值说明那一段（含 `host`（主机入站白名单）/ `docker`（…）/ `node`（…）的句子）末尾，追加：

```markdown
；`trust`（信任 IP，对单个可信 IP 放行全部端口，详见 `2026-06-07-firewall-trust-ip-design.md`）
```

其二，在“模块划分”小节的加载顺序行，把：

```
加载顺序：`lib/common.sh(根) → config → common → rules → docker → k3s → service → menu → main`
```

改为：

```
加载顺序：`lib/common.sh(根) → config → common → rules → docker → k3s → trust → service → menu → main`（`trust` 见 `2026-06-07-firewall-trust-ip-design.md`）
```

- [ ] **Step 6: 运行测试（含回归），确认通过**

Run: `bash tests/test_firewall.sh docs && bash tests/test_firewall.sh k3s`
Expected: 两行 `PASS`（`docs` / `k3s` 回归 rp_filter 告警）

- [ ] **Step 7: 提交**

```bash
git add tests/test_firewall.sh README.md lib/firewall/k3s.sh docs/superpowers/specs/2026-06-07-firewall-management-design.md
git commit -m "docs(firewall): README/设计文档补注信任 IP,rp_filter 告警含信任 IP"
```

---

## Task 7: 全量回归与收尾

**Files:** 无新增改动，仅验证。

- [ ] **Step 1: 全量语法检查**

Run: `find . -name '*.sh' -type f -not -path './.git/*' -print0 | xargs -0 -n1 bash -n`
Expected: 无输出（全部通过）

- [ ] **Step 2: 防火墙测试全绿**

Run: `bash tests/test_firewall.sh`
Expected: 末行 `PASS: all`

- [ ] **Step 3: 其他套件回归（确认未误伤公共入口）**

Run: `bash tests/test_deploy.sh && bash tests/test_pg_ha.sh && bash tests/test_mysql_ha.sh`
Expected: 三套各自 `PASS`（本次未改其路径，应全绿）

- [ ] **Step 4: 确认工作区干净**

Run: `git status --short`
Expected: 无输出（前面各 Task 已分别提交）

---

## Self-Review（计划编写后自检）

**Spec 覆盖核对：**

| Spec 要求 | 落点 |
|-----------|------|
| 配置格式 `trust - - - <ip>` | Task 1（`fw_trust_ips` 读取）+ Task 2/3（构建消费） |
| `fw_validate_trust_ip` 拒 any/CIDR | Task 1 |
| `fw_trust_ips` 只读 trust 行 | Task 1 |
| FW-INPUT `-s ip -j ACCEPT` + 时序 | Task 2 |
| FW-INPUT6 同步 | Task 2 |
| FW-DOCKER `-s ip --ctstate DNAT -j RETURN` + 时序 | Task 3 |
| 地址族归类（v4 不进 v6，反之） | Task 2/3 测试 |
| 菜单第 5 项 + 二次确认 | Task 4 |
| `fw_status` 信任 IP 计数 | Task 4 |
| 加载链：入口 / fw 命令 / 模块安装 / 测试 | Task 1（load_firewall）+ Task 5（install + service×2 + skeleton） |
| 设计文档加载顺序补注 | Task 6 |
| rp_filter 文案补“信任 IP” | Task 6 |
| README 信任 IP 小节 | Task 6 |
| 测试套件 | Task 1/2/3/4 各专项 + Task 5 skeleton + Task 6 docs |

**补充修正（计划比 spec 更细处）：** spec 仅提“fw 命令 for 列表”，实际 `service.sh` 有 `fw_write_command` 与 `fw_install_modules` **两处** `for m`，Task 5 Step 4 两处都改——否则 fw 命令会 source 一个未被复制到 `FW_LIB_DIR` 的 `trust.sh`。

**占位符扫描：** 无 TBD/TODO；每个代码步骤均含完整代码。

**类型/命名一致性：** `fw_trust_ips` / `fw_validate_trust_ip` / `fw_build_trust_input` / `fw_build_trust_docker` / `fw_menu_add_trust` 全程一致；注释标记 `fw-managed:trust` 与 `fw-managed:trust-docker` 前后一致。
