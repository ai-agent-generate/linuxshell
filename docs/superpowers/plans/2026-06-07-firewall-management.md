# 防火墙管理脚本 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为同时运行 Docker 和 k3s 的 Ubuntu/Debian 服务器实现一个交互式 iptables 防火墙管理工具,支持添加/查看/删除规则,与 Docker/k3s 共存不冲突。

**Architecture:** 模块化 Bash(入口 `install-firewall.sh` + `lib/firewall/*.sh`)。声明式规则文件 `/etc/linuxshell-fw/rules.conf` 为单一事实源;`fw_apply` 用 **build-then-swap 原子替换**(临时链灌满规则后 `iptables -E` 重命名上线,无自锁窗口)重建自建链 `FW-INPUT`/`FW-DOCKER`;主机入站 `INPUT` 默认 DROP 白名单,Docker 端口经 `DOCKER-USER` 子链 `--ctstate DNAT` deny-by-default,k3s 节点逐端口放行。装 `fw` 命令无参进交互菜单,systemd 服务 boot 重应用。IPv4/IPv6 同管。

**Tech Stack:** Bash(`set -euo pipefail`)、iptables/ip6tables、conntrack、systemd、现有 `tests/test_*.sh` 风格(`assert_*` + mock 命令)。

**Spec:** `docs/superpowers/specs/2026-06-07-firewall-management-design.md`

**Commit-style note:** 仓库用中文 conventional-commit 前缀(`feat:`/`fix:`/`docs:`),见 `git log --oneline -5`。对话/提交用中文。

---

## 与 spec 的细微调整(实现期确认)

- 测试 harness 复用 `tests/test_mysql_ha.sh` 的 `assert_*` helper,新增 `assert_order`(对 action log 按行号断言先后)。
- 所有模块只定义函数、不在顶层执行,保证 `source` 安全(入口脚本才调 `firewall_main`)。
- mock 策略:测试中把 `iptables`/`ip6tables`/`systemctl`/`systemd-run`/`docker`/`sshd`/`ss`/`modprobe` 覆盖为记录到 action log 的函数,不触达内核/系统。

## 文件结构

| 文件 | 职责 | 关键函数 |
|------|------|---------|
| `install-firewall.sh` | 入口:加载模块 + 调 `firewall_main` | `load_linuxshell_modules` |
| `lib/firewall/config.sh` | 默认配置(可环境变量覆盖) | (纯变量) |
| `lib/firewall/common.sh` | 校验/配置读写/原子链替换/预检/SSH 探测 | `fw_validate_*`、`fw_rules_read`、`fw_chain_swap`、`fw_reassert_top`、`fw_preflight`、`fw_have_xt`、`fw_detect_ssh_ports`、`fw_die`、`fw_addr_family` |
| `lib/firewall/rules.sh` | 主机入站 + apply 编排 | `fw_build_input`、`fw_build_input6`、`fw_build_host_rules`、`fw_apply` |
| `lib/firewall/docker.sh` | DOCKER-USER 子链 deny-by-default | `fw_build_docker`、`fw_build_docker6`、`fw_docker_allow_rules`、`fw_docker_in_ip6`、`fw_docker_scan` |
| `lib/firewall/k3s.sh` | k3s 逐端口 + CNI + rp_filter | `fw_build_k3s_input`、`fw_k3s_node_ips`、`fw_check_rp_filter` |
| `lib/firewall/service.sh` | systemd unit + fw 命令 + 模块安装 + 权限 | `fw_write_service`、`fw_write_command`、`fw_install_modules` |
| `lib/firewall/menu.sh` | 交互菜单 + 禁用带时长 + 禁用态告警 | `firewall_menu`、`fw_menu_*`、`fw_disable`、`fw_enable`、`fw_status` |
| `lib/firewall/main.sh` | 编排与主入口 | `firewall_main`、`fw_cli` |
| `tests/test_firewall.sh` | 全套测试 | `run_*_tests`、`assert_order` |

加载顺序:`lib/common.sh(根) → config → common → rules → docker → k3s → service → menu → main`

---

## Task 1: 测试框架骨架 + config.sh(config 套件)

**Why:** 先立测试 harness 和配置模块,后续每个模块都挂在这套 harness 上 TDD。

**Files:**
- Create: `tests/test_firewall.sh`
- Create: `lib/firewall/config.sh`

- [ ] **Step 1: 创建测试骨架(含 config 套件,先失败)**

创建 `tests/test_firewall.sh`,内容:

```bash
#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file_exists() { [[ -f "$1" ]] || fail "expected file to exist: $1"; }
assert_function_exists() { declare -F "$1" >/dev/null || fail "expected function: $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_not_contains() { if grep -Fq -- "$2" "$1"; then fail "did not expect '$2' in $1"; fi; }
assert_equals() { [[ "$1" == "$2" ]] || fail "expected '$1' but got '$2'"; }
assert_mode() {
  local m; m="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null)"
  [[ "$m" == "$2" ]] || fail "expected mode $2 on $1 but got $m"
}
# 断言 log 文件中 $2 首次出现行号 < $3 首次出现行号
assert_order() {
  local file="$1" first="$2" second="$3" l1 l2
  l1="$(grep -n -- "$first" "$file" | head -1 | cut -d: -f1)"
  l2="$(grep -n -- "$second" "$file" | head -1 | cut -d: -f1)"
  [[ -n "$l1" ]] || fail "assert_order: '$first' not found in $file"
  [[ -n "$l2" ]] || fail "assert_order: '$second' not found in $file"
  [[ "$l1" -lt "$l2" ]] || fail "assert_order: expected '$first'(line $l1) before '$second'(line $l2)"
}

# 按依赖顺序加载防火墙模块(测试前可 export FW_* 覆盖路径)
load_firewall() {
  # shellcheck disable=SC1090,SC1091
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/firewall/config.sh"
  source "${ROOT_DIR}/lib/firewall/common.sh"
  source "${ROOT_DIR}/lib/firewall/rules.sh"
  source "${ROOT_DIR}/lib/firewall/docker.sh"
  source "${ROOT_DIR}/lib/firewall/k3s.sh"
  source "${ROOT_DIR}/lib/firewall/service.sh"
  source "${ROOT_DIR}/lib/firewall/menu.sh"
  source "${ROOT_DIR}/lib/firewall/main.sh"
}

run_config_tests() {
  ( unset FW_RULES_FILE FW_LIB_DIR FW_K3S_TCP_PORTS FW_K3S_UDP_PORTS FW_K3S_POD_CIDR
    source "${ROOT_DIR}/lib/firewall/config.sh"
    assert_equals "/etc/linuxshell-fw/rules.conf" "${FW_RULES_FILE}"
    assert_equals "/usr/local/lib/linuxshell-fw" "${FW_LIB_DIR}"
    assert_equals "/usr/local/bin/fw" "${FW_BIN}"
    assert_equals "22" "${FW_SSH_PORT}"
    assert_equals "6443,10250,2379,2380" "${FW_K3S_TCP_PORTS}"
    assert_equals "8472" "${FW_K3S_UDP_PORTS}"
    assert_equals "10.42.0.0/16" "${FW_K3S_POD_CIDR}"
    assert_equals "cni0 flannel.1" "${FW_K3S_CNI_IFACES}"
    assert_equals "FW-INPUT" "${FW_INPUT_CHAIN}"
    assert_equals "FW-DOCKER" "${FW_DOCKER_CHAIN}"
  )
  ( export FW_RULES_FILE="/tmp/x.conf" FW_K3S_UDP_PORTS="8472,51820,51821"
    source "${ROOT_DIR}/lib/firewall/config.sh"
    assert_equals "/tmp/x.conf" "${FW_RULES_FILE}"
    assert_equals "8472,51820,51821" "${FW_K3S_UDP_PORTS}"
  )
}

main() {
  local suite="${1:-all}"
  case "$suite" in
    config) run_config_tests ;;
    all) run_config_tests ;;
    *) fail "unknown suite: $suite" ;;
  esac
  echo "PASS: ${suite}"
}

main "$@"
```

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_firewall.sh config 2>&1 | tail -3`
Expected: 因 `lib/firewall/config.sh` 不存在而失败,如 `No such file or directory`。

- [ ] **Step 3: 创建 config.sh**

创建 `lib/firewall/config.sh`:

```bash
# linuxshell 防火墙默认配置;所有值可经环境变量覆盖。

# 配置文件与安装路径
FW_RULES_FILE="${FW_RULES_FILE:-/etc/linuxshell-fw/rules.conf}"
FW_RULES_DIR="${FW_RULES_DIR:-/etc/linuxshell-fw}"
FW_LIB_DIR="${FW_LIB_DIR:-/usr/local/lib/linuxshell-fw}"
FW_BIN="${FW_BIN:-/usr/local/bin/fw}"
FW_SERVICE_FILE="${FW_SERVICE_FILE:-/etc/systemd/system/linuxshell-fw.service}"

# SSH 兜底端口(探测不到时用)
FW_SSH_PORT="${FW_SSH_PORT:-22}"

# IPv6:auto 由预检根据内核探测设定 FW_HAVE_IPV6
FW_IPV6="${FW_IPV6:-auto}"

# k3s 端口组与网络(k3s+flannel 默认值)
FW_K3S_TCP_PORTS="${FW_K3S_TCP_PORTS:-6443,10250,2379,2380}"
FW_K3S_UDP_PORTS="${FW_K3S_UDP_PORTS:-8472}"
FW_K3S_POD_CIDR="${FW_K3S_POD_CIDR:-10.42.0.0/16}"
FW_K3S_CNI_IFACES="${FW_K3S_CNI_IFACES:-cni0 flannel.1}"

# 自建链名
FW_INPUT_CHAIN="${FW_INPUT_CHAIN:-FW-INPUT}"
FW_DOCKER_CHAIN="${FW_DOCKER_CHAIN:-FW-DOCKER}"
```

- [ ] **Step 4: 运行,确认通过**

Run: `bash tests/test_firewall.sh config`
Expected: `PASS: config`

- [ ] **Step 5: 可执行位 + 提交**

```bash
chmod +x tests/test_firewall.sh
git add tests/test_firewall.sh lib/firewall/config.sh
git commit -m "feat(firewall): 测试骨架 + config 默认配置"
```

---

## Task 2: 入口 install-firewall.sh + skeleton 测试

**Why:** 立起入口脚本与模块加载契约,skeleton 套件保证所有模块存在、可语法解析、加载顺序与入口下载列表一致。这一步先建**空壳模块**(只放占位函数),让 skeleton 绿;后续 Task 逐个填实。

**Files:**
- Create: `install-firewall.sh`
- Create: `lib/firewall/common.sh`、`rules.sh`、`docker.sh`、`k3s.sh`、`service.sh`、`menu.sh`、`main.sh`(空壳)
- Modify: `tests/test_firewall.sh`(加 `run_skeleton_tests`)

- [ ] **Step 1: 写 skeleton 测试(先失败)**

在 `tests/test_firewall.sh` 的 `run_config_tests` 之后插入:

```bash
run_skeleton_tests() {
  local entry="${ROOT_DIR}/install-firewall.sh"
  assert_file_exists "$entry"
  [[ -x "$entry" ]] || fail "expected install-firewall.sh to be executable"
  bash -n "$entry" || fail "install-firewall.sh has syntax errors"
  assert_contains "$entry" "lib/common.sh"
  assert_contains "$entry" "lib/firewall/main.sh"

  local m
  for m in config common rules docker k3s service menu main; do
    assert_file_exists "${ROOT_DIR}/lib/firewall/${m}.sh"
    bash -n "${ROOT_DIR}/lib/firewall/${m}.sh" || fail "syntax error: lib/firewall/${m}.sh"
    assert_contains "$entry" "lib/firewall/${m}.sh"
  done

  load_firewall
  local fn
  for fn in fw_validate_port fw_validate_source fw_validate_proto \
            fw_rules_read fw_chain_swap fw_reassert_top fw_preflight fw_have_xt \
            fw_detect_ssh_ports fw_addr_family \
            fw_build_input fw_build_input6 fw_build_host_rules fw_apply \
            fw_build_docker fw_build_docker6 fw_docker_allow_rules fw_docker_in_ip6 fw_docker_scan \
            fw_build_k3s_input fw_k3s_node_ips fw_check_rp_filter \
            fw_write_service fw_write_command fw_install_modules \
            firewall_menu fw_disable fw_enable fw_status \
            firewall_main fw_cli; do
    assert_function_exists "$fn"
  done
}
```

并在 `main()` 的 `case` 中加入(`config)` 之后、`all)` 之前):

```bash
    skeleton) run_skeleton_tests ;;
```

并把 `all)` 行改为:

```bash
    all) run_skeleton_tests; run_config_tests ;;
```

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_firewall.sh skeleton 2>&1 | tail -3`
Expected: `FAIL: expected file to exist: .../install-firewall.sh`

- [ ] **Step 3: 创建入口 install-firewall.sh**

创建 `install-firewall.sh`(复用 mysql-ha 入口模式,本地探测 `lib/firewall/config.sh`):

```bash
#!/usr/bin/env bash

set -euo pipefail

LINUXSHELL_RAW_BASE_URL="${LINUXSHELL_RAW_BASE_URL:-https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main}"
LINUXSHELL_MODULE_ROOT=""
LINUXSHELL_MODULE_SOURCE=""

load_linuxshell_modules() {
  local script_dir module_root module
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || pwd)"
  module_root="$script_dir"

  if [[ -f "${module_root}/lib/firewall/config.sh" ]]; then
    LINUXSHELL_MODULE_SOURCE="local"
  else
    module_root="$(mktemp -d)"
    LINUXSHELL_MODULE_SOURCE="remote"
    for module in "$@"; do
      mkdir -p "${module_root}/$(dirname "$module")"
      if ! curl -fsSL "${LINUXSHELL_RAW_BASE_URL}/${module}" -o "${module_root}/${module}"; then
        echo "Failed to download module: ${LINUXSHELL_RAW_BASE_URL}/${module}" >&2
        return 1
      fi
    done
  fi

  LINUXSHELL_MODULE_ROOT="$module_root"
  for module in "$@"; do
    # shellcheck disable=SC1090
    source "${module_root}/${module}"
  done
}

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

- [ ] **Step 4: 创建 7 个空壳模块**

每个文件先放占位函数(后续 Task 替换为真实实现)。创建以下文件:

`lib/firewall/common.sh`:
```bash
fw_die() { echo "$*" >&2; exit 1; }
fw_validate_port() { :; }
fw_validate_source() { :; }
fw_validate_proto() { :; }
fw_addr_family() { :; }
fw_rules_read() { :; }
fw_chain_swap() { :; }
fw_reassert_top() { :; }
fw_preflight() { :; }
fw_have_xt() { :; }
fw_detect_ssh_ports() { :; }
```

`lib/firewall/rules.sh`:
```bash
fw_build_input() { :; }
fw_build_input6() { :; }
fw_build_host_rules() { :; }
fw_apply() { :; }
```

`lib/firewall/docker.sh`:
```bash
fw_build_docker() { :; }
fw_build_docker6() { :; }
fw_docker_allow_rules() { :; }
fw_docker_in_ip6() { :; }
fw_docker_scan() { :; }
```

`lib/firewall/k3s.sh`:
```bash
fw_build_k3s_input() { :; }
fw_k3s_node_ips() { :; }
fw_check_rp_filter() { :; }
```

`lib/firewall/service.sh`:
```bash
fw_write_service() { :; }
fw_write_command() { :; }
fw_install_modules() { :; }
```

`lib/firewall/menu.sh`:
```bash
firewall_menu() { :; }
fw_disable() { :; }
fw_enable() { :; }
fw_status() { :; }
```

`lib/firewall/main.sh`:
```bash
firewall_main() { :; }
fw_cli() { :; }
```

- [ ] **Step 5: 运行 skeleton,确认通过**

Run: `bash tests/test_firewall.sh skeleton`
Expected: `PASS: skeleton`

- [ ] **Step 6: 可执行位 + 提交**

```bash
chmod +x install-firewall.sh
git add install-firewall.sh lib/firewall/ tests/test_firewall.sh
git commit -m "feat(firewall): 入口脚本 + 模块空壳 + skeleton 测试"
```

---

## Task 3: common.sh — 参数校验 + 配置文件读写(validate / rulesfile 套件)

**Why:** 这些是纯函数(不碰 iptables),先实现并测试,为后续 build 函数和菜单提供校验与持久化基础。

**Files:**
- Modify: `lib/firewall/common.sh`(替换占位 + 追加)
- Modify: `tests/test_firewall.sh`(加 `run_validate_tests`/`run_rulesfile_tests`)

- [ ] **Step 1: 写 validate / rulesfile 测试(先失败)**

在 `tests/test_firewall.sh` 的 `run_skeleton_tests` 之后插入:

```bash
run_validate_tests() {
  load_firewall
  fw_validate_proto tcp || fail "tcp should pass"
  fw_validate_proto udp || fail "udp should pass"
  if fw_validate_proto icmp 2>/dev/null; then fail "icmp should fail"; fi

  fw_validate_port 22 || fail "22 should pass"
  fw_validate_port 80,443 || fail "80,443 should pass"
  fw_validate_port 30000:32767 || fail "range should pass"
  if fw_validate_port 0 2>/dev/null; then fail "0 should fail"; fi
  if fw_validate_port 70000 2>/dev/null; then fail "70000 should fail"; fi
  if fw_validate_port 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16 2>/dev/null; then fail ">15 should fail"; fi

  fw_validate_source any || fail "any should pass"
  fw_validate_source 10.0.0.1 || fail "ipv4 should pass"
  fw_validate_source 10.0.0.0/24 || fail "ipv4 cidr should pass"
  fw_validate_source "2001:db8::1" || fail "ipv6 should pass"
  if fw_validate_source "garbage" 2>/dev/null; then fail "garbage should fail"; fi

  assert_equals "4" "$(fw_addr_family 10.0.0.1)"
  assert_equals "6" "$(fw_addr_family 2001:db8::1)"
  assert_equals "any" "$(fw_addr_family any)"
}

run_rulesfile_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  export FW_RULES_DIR="${temp_root}/etc"
  export FW_RULES_FILE="${temp_root}/etc/rules.conf"
  load_firewall

  fw_rules_add "host allow tcp 22 any SSH"
  fw_rules_add "host allow tcp 80,443 any Caddy 反代"
  assert_file_exists "$FW_RULES_FILE"
  assert_mode "$FW_RULES_FILE" "600"
  assert_equals "2" "$(fw_rules_read | wc -l | tr -d ' ')"
  fw_rules_read | grep -Fq "Caddy 反代" || fail "comment with space lost"

  fw_rules_delete 1
  assert_equals "1" "$(fw_rules_read | wc -l | tr -d ' ')"
  fw_rules_read | grep -Fq "80,443" || fail "wrong line deleted"
}
```

在 `main()` 的 `case` 中 `skeleton)` 之后加:

```bash
    validate) run_validate_tests ;;
    rulesfile) run_rulesfile_tests ;;
```

并把 `all)` 行更新为:

```bash
    all) run_skeleton_tests; run_config_tests; run_validate_tests; run_rulesfile_tests ;;
```

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_firewall.sh validate 2>&1 | tail -3`
Expected: `FAIL: tcp should pass`(占位 `fw_validate_proto` 永远成功,`icmp should fail` 反而触发,或前置断言失败)。至少非 `PASS`。

- [ ] **Step 3: 替换占位 + 追加配置读写函数**

在 `lib/firewall/common.sh` 中,把占位 `fw_validate_proto`/`fw_validate_port`/`fw_validate_source`/`fw_addr_family`/`fw_rules_read` 替换为下列真实实现,并在文件末尾**追加** `fw_rules_add`/`fw_rules_delete`:

```bash
fw_validate_proto() {
  case "$1" in tcp|udp) return 0 ;; *) return 1 ;; esac
}

# 端口:单值 / 逗号列表 / a:b 范围;multiport 单条最多 15 个端口槽(范围算 2)
fw_validate_port() {
  local spec="$1" p lo hi count=0
  [[ -n "$spec" ]] || return 1
  local IFS=','
  for p in $spec; do
    if [[ "$p" =~ ^[0-9]+:[0-9]+$ ]]; then
      lo="${p%:*}"; hi="${p#*:}"
      [[ "$lo" -ge 1 && "$hi" -le 65535 && "$lo" -le "$hi" ]] || return 1
      count=$((count + 2))
    elif [[ "$p" =~ ^[0-9]+$ ]]; then
      [[ "$p" -ge 1 && "$p" -le 65535 ]] || return 1
      count=$((count + 1))
    else
      return 1
    fi
  done
  [[ "$count" -le 15 ]]
}

# 来源:any / IPv4 / IPv4-CIDR / IPv6 / IPv6-CIDR / IPv4-mapped
fw_validate_source() {
  local s="$1"
  [[ "$s" == "any" ]] && return 0
  [[ "$s" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] && return 0
  [[ "$s" == *:* && "$s" =~ ^[0-9a-fA-F:.]+(/[0-9]+)?$ ]] && return 0
  return 1
}

# 地址族:any / 4 / 6(含 ':' 归 6,IPv4-mapped 无害归 6)
fw_addr_family() {
  case "$1" in
    any) echo "any" ;;
    *:*) echo "6" ;;
    *)   echo "4" ;;
  esac
}

# 读规则文件:剔除注释/空行,逐行输出
fw_rules_read() {
  [[ -f "$FW_RULES_FILE" ]] || return 0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    printf '%s\n' "$line"
  done < "$FW_RULES_FILE"
}

# 追加一条规则(原子写,目录 700 / 文件 600)
fw_rules_add() {
  local tmp
  mkdir -p "$FW_RULES_DIR"; chmod 700 "$FW_RULES_DIR"
  tmp="$(mktemp)"
  [[ -f "$FW_RULES_FILE" ]] && cat "$FW_RULES_FILE" >"$tmp"
  printf '%s\n' "$1" >>"$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$FW_RULES_FILE"
}

# 按编号删除一条非注释规则(编号从 1 起,仅计非注释行)
fw_rules_delete() {
  local target="$1" n=0 line tmp
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line//[[:space:]]/}" ]]; then
      printf '%s\n' "$line" >>"$tmp"; continue
    fi
    n=$((n + 1))
    [[ "$n" == "$target" ]] && continue
    printf '%s\n' "$line" >>"$tmp"
  done < "$FW_RULES_FILE"
  chmod 600 "$tmp"; mv "$tmp" "$FW_RULES_FILE"
}
```

- [ ] **Step 4: 运行,确认通过**

Run: `bash tests/test_firewall.sh validate && bash tests/test_firewall.sh rulesfile`
Expected: `PASS: validate` 然后 `PASS: rulesfile`

- [ ] **Step 5: 提交**

```bash
git add lib/firewall/common.sh tests/test_firewall.sh
git commit -m "feat(firewall): common 参数校验与规则文件读写"
```

---

## Task 4: common.sh — 依赖预检 + SSH 探测 + build-then-swap 原语(swap / lockout 套件)

**Why:** apply 的安全基石。`fw_chain_swap` 必须保证"新链先上线、旧跳转后删"无空窗;SSH 探测必须取 sshd 实际端口避免锁死。这些用 mock iptables/sshd 测试。

**Files:**
- Modify: `lib/firewall/common.sh`(替换剩余占位)
- Modify: `tests/test_firewall.sh`(加 `run_swap_tests`/`run_lockout_tests`)

- [ ] **Step 1: 写 swap / lockout 测试(先失败)**

在 `tests/test_firewall.sh` 的 `run_rulesfile_tests` 之后插入:

```bash
run_swap_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  local log="${temp_root}/ipt.log"
  load_firewall
  iptables() {
    echo "iptables $*" >>"$log"
    case "$1" in -nL) return 1 ;; -C) return 1 ;; esac
    return 0
  }
  : >"$log"
  demo_build() { local ipt="$1" c="$2"; "$ipt" -A "$c" -i lo -j ACCEPT; }
  fw_chain_swap iptables INPUT FW-INPUT demo_build
  assert_order "$log" "-N FW-INPUT-NEW" "-A FW-INPUT-NEW"
  assert_order "$log" "-A FW-INPUT-NEW" "-I INPUT 1 -j FW-INPUT-NEW"
  assert_order "$log" "-I INPUT 1 -j FW-INPUT-NEW" "-E FW-INPUT-NEW FW-INPUT"
  assert_contains "$log" "-E FW-INPUT-NEW FW-INPUT"
}

run_lockout_tests() {
  load_firewall
  ( export SSH_CONNECTION="1.2.3.4 51000 5.6.7.8 22022"
    command_exists() { case "$1" in sshd) return 0 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    sshd() { [[ "$1" == "-T" ]] && echo "port 2222"; }
    local ports; ports="$(fw_detect_ssh_ports)"
    grep -qx 2222 <<<"$ports" || fail "expected sshd port 2222"
    grep -qx 22022 <<<"$ports" || fail "expected SSH_CONNECTION port 22022"
  )
  ( unset SSH_CONNECTION
    command_exists() { case "$1" in sshd) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
    export FW_SSH_PORT=22
    local ports; ports="$(fw_detect_ssh_ports)"
    grep -qx 22 <<<"$ports" || fail "expected fallback port 22"
  )
}
```

在 `main()` 的 `case` 中 `rulesfile)` 之后加:

```bash
    swap) run_swap_tests ;;
    lockout) run_lockout_tests ;;
```

并把 `all)` 行更新为:

```bash
    all) run_skeleton_tests; run_config_tests; run_validate_tests; run_rulesfile_tests; run_swap_tests; run_lockout_tests ;;
```

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_firewall.sh swap 2>&1 | tail -3`
Expected: `FAIL: assert_order: '-N FW-INPUT-NEW' not found`(占位 `fw_chain_swap` 什么都不做)。

- [ ] **Step 3: 替换剩余占位为真实实现**

在 `lib/firewall/common.sh` 中,把占位 `fw_have_xt`/`fw_preflight`/`fw_detect_ssh_ports`/`fw_chain_swap`/`fw_reassert_top` 替换为:

```bash
fw_have_xt() { iptables -m "$1" -h >/dev/null 2>&1; }

fw_preflight() {
  require_root
  detect_os
  command_exists iptables || fw_die "缺少 iptables,请先 apt-get install -y iptables"
  modprobe nf_conntrack 2>/dev/null || true
  fw_have_xt conntrack || fw_die "缺少 xt_conntrack,无法按状态过滤"
  fw_have_xt comment   || fw_die "缺少 xt_comment,fw-managed 标记依赖它"
  fw_have_xt multiport || fw_die "缺少 xt_multiport"
  if [[ -e /proc/net/if_inet6 ]] && command_exists ip6tables; then
    FW_HAVE_IPV6=1
  else
    FW_HAVE_IPV6=0
  fi
}

# 取并集:当前 SSH 连接端口 + sshd 实际监听端口 + 兜底,保证不锁死
fw_detect_ssh_ports() {
  {
    [[ -n "${SSH_CONNECTION:-}" ]] && awk '{print $4}' <<<"$SSH_CONNECTION"
    if command_exists sshd; then sshd -T 2>/dev/null | awk '/^port /{print $2}'; fi
    echo "$FW_SSH_PORT"
  } | grep -E '^[0-9]+$' | sort -u
}

# build-then-swap:新链灌满规则后才上线、再删旧跳转、最后原子重命名,全程父链有有效跳转
# 用法:fw_chain_swap <iptables-bin> <parent> <chain> <build-fn>;build-fn 收到 (ipt, 链名)
fw_chain_swap() {
  local ipt="$1" parent="$2" chain="$3" build="$4" tmp="${3}-NEW"
  if "$ipt" -nL "$tmp" >/dev/null 2>&1; then "$ipt" -F "$tmp"; else "$ipt" -N "$tmp"; fi
  "$build" "$ipt" "$tmp"
  "$ipt" -I "$parent" 1 -j "$tmp"
  while "$ipt" -C "$parent" -j "$chain" 2>/dev/null; do "$ipt" -D "$parent" -j "$chain"; done
  if "$ipt" -nL "$chain" >/dev/null 2>&1; then "$ipt" -F "$chain"; "$ipt" -X "$chain"; fi
  "$ipt" -E "$tmp" "$chain"
}

# 把跳转强制重排到父链第 1 条(应对 kube-proxy reconcile 后下沉)
fw_reassert_top() {
  local parent="$1" chain="$2" ipt="$3"
  while "$ipt" -C "$parent" -j "$chain" 2>/dev/null; do "$ipt" -D "$parent" -j "$chain"; done
  "$ipt" -I "$parent" 1 -j "$chain"
}
```

- [ ] **Step 4: 运行,确认通过**

Run: `bash tests/test_firewall.sh swap && bash tests/test_firewall.sh lockout`
Expected: `PASS: swap` 然后 `PASS: lockout`

- [ ] **Step 5: 全套回归 + 提交**

Run: `bash tests/test_firewall.sh all`
Expected: `PASS: all`

```bash
git add lib/firewall/common.sh tests/test_firewall.sh
git commit -m "feat(firewall): 依赖预检/SSH探测/build-then-swap 原子替换"
```

---

## Task 5: rules.sh — fw_build_input / host 规则 / fw_apply 编排(apply 套件)

**Why:** 主机入站链构建与总编排。这里只全量测 `fw_build_input` 的规则顺序(不真跑 `fw_apply` 以免 mock 不全);`fw_apply` 的编排正确性靠 swap 套件 + 后续集成验证。

**Files:**
- Modify: `lib/firewall/rules.sh`(整文件实现)
- Modify: `tests/test_firewall.sh`(加 `run_apply_tests`)

- [ ] **Step 1: 写 apply 测试(先失败)**

在 `run_lockout_tests` 之后插入:

```bash
run_apply_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  local log="${temp_root}/ipt.log"
  export FW_RULES_DIR="${temp_root}/etc" FW_RULES_FILE="${temp_root}/etc/rules.conf"
  export FW_SSH_PORT=22
  load_firewall
  iptables() { echo "iptables $*" >>"$log"; case "$1" in -nL|-C) return 1 ;; esac; return 0; }
  command_exists() { case "$1" in sshd) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  fw_rules_add "host allow tcp 8080 10.0.0.0/24 app"
  : >"$log"
  ( unset SSH_CONNECTION; fw_build_input iptables FW-INPUT )
  assert_order "$log" "-i lo -j ACCEPT" "ESTABLISHED,RELATED"
  assert_order "$log" "ESTABLISHED,RELATED" "fw-managed:ssh-guard"
  assert_order "$log" "fw-managed:ssh-guard" "fw-managed:host"
  assert_contains "$log" "--dports 8080"
}
```

`case` 加 `apply) run_apply_tests ;;`;`all)` 行追加 `run_apply_tests`。

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_firewall.sh apply 2>&1 | tail -3`
Expected: `FAIL: assert_order: '-i lo -j ACCEPT' not found`(占位 `fw_build_input` 不写规则)。

- [ ] **Step 3: 实现 rules.sh(整文件替换)**

用以下完整内容替换 `lib/firewall/rules.sh`:

```bash
# 主机入站规则构建与 apply 编排

# host allow 规则(按地址族过滤:iptables 跳过 v6 源,ip6tables 跳过 v4 源)
fw_build_host_rules() {  # $1=ipt $2=chain
  local ipt="$1" c="$2" type action proto port src comment fam srcopt
  while read -r type action proto port src comment; do
    [[ "$type" == "host" && "$action" == "allow" ]] || continue
    fam="$(fw_addr_family "$src")"
    case "$ipt:$fam" in iptables:6) continue ;; ip6tables:4) continue ;; esac
    srcopt=""; [[ "$src" != "any" ]] && srcopt="-s $src"
    "$ipt" -A "$c" -p "$proto" -m multiport --dports "$port" $srcopt -j ACCEPT \
      -m comment --comment "fw-managed:host"
  done < <(fw_rules_read)
}

# IPv4 主机入站链
fw_build_input() {  # $1=iptables $2=chain
  local ipt="$1" c="$2" p
  "$ipt" -A "$c" -i lo -j ACCEPT
  "$ipt" -A "$c" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  "$ipt" -A "$c" -p icmp --icmp-type echo-request -j ACCEPT
  for p in $(fw_detect_ssh_ports); do
    "$ipt" -A "$c" -p tcp --dport "$p" -j ACCEPT -m comment --comment "fw-managed:ssh-guard"
  done
  fw_build_k3s_input "$ipt" "$c"
  fw_build_host_rules "$ipt" "$c"
}

# IPv6 主机入站链(ICMPv6 仅放行 NDP/echo/错误类,排除 redirect 137)
fw_build_input6() {  # $1=ip6tables $2=chain
  local ipt="$1" c="$2" p t
  "$ipt" -A "$c" -i lo -j ACCEPT
  "$ipt" -A "$c" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  for t in 1 2 3 4 128 129 130 131 132 133 134 135 136; do
    "$ipt" -A "$c" -p ipv6-icmp --icmpv6-type "$t" -j ACCEPT
  done
  for p in $(fw_detect_ssh_ports); do
    "$ipt" -A "$c" -p tcp --dport "$p" -j ACCEPT -m comment --comment "fw-managed:ssh-guard"
  done
  fw_build_k3s_input "$ipt" "$c"
  fw_build_host_rules "$ipt" "$c"
}

# 总编排:每条自建链 build-then-swap,放行就位后才 policy DROP
fw_apply() {
  fw_preflight
  fw_chain_swap iptables INPUT "$FW_INPUT_CHAIN" fw_build_input
  if command_exists docker && iptables -nL DOCKER-USER >/dev/null 2>&1; then
    fw_chain_swap iptables DOCKER-USER "$FW_DOCKER_CHAIN" fw_build_docker
  fi
  if [[ "${FW_HAVE_IPV6:-0}" == 1 ]]; then
    fw_chain_swap ip6tables INPUT "${FW_INPUT_CHAIN}6" fw_build_input6
    if fw_docker_in_ip6; then
      fw_chain_swap ip6tables DOCKER-USER "${FW_DOCKER_CHAIN}6" fw_build_docker6
    fi
  fi
  fw_reassert_top INPUT "$FW_INPUT_CHAIN" iptables
  [[ "${FW_HAVE_IPV6:-0}" == 1 ]] && fw_reassert_top INPUT "${FW_INPUT_CHAIN}6" ip6tables
  iptables -P INPUT DROP
  [[ "${FW_HAVE_IPV6:-0}" == 1 ]] && ip6tables -P INPUT DROP
  fw_check_rp_filter
}
```

- [ ] **Step 4: 运行,确认通过**

Run: `bash tests/test_firewall.sh apply`
Expected: `PASS: apply`

- [ ] **Step 5: 提交**

```bash
git add lib/firewall/rules.sh tests/test_firewall.sh
git commit -m "feat(firewall): 主机入站链构建与 apply 编排"
```

---

## Task 6: docker.sh — FW-DOCKER deny-by-default(docker 套件)

**Why:** 堵住"容器发布端口绕过 INPUT 全网可达"的核心漏洞。`--ctstate DNAT` 只作用于桥接发布流量,established 放行回包,链尾默认 DROP。

**Files:**
- Modify: `lib/firewall/docker.sh`(整文件实现)
- Modify: `tests/test_firewall.sh`(加 `run_docker_tests`)

- [ ] **Step 1: 写 docker 测试(先失败)**

在 `run_apply_tests` 之后插入:

```bash
run_docker_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  local log="${temp_root}/ipt.log"
  export FW_RULES_DIR="${temp_root}/etc" FW_RULES_FILE="${temp_root}/etc/rules.conf"
  load_firewall
  iptables() { echo "iptables $*" >>"$log"; return 0; }
  fw_rules_add "docker allow tcp 6379 10.0.0.5 redis"
  : >"$log"
  fw_build_docker iptables FW-DOCKER-NEW
  assert_order "$log" "ESTABLISHED,RELATED -j RETURN" "fw-managed:docker"
  assert_order "$log" "--ctorigdstport 6379 -s 10.0.0.5 -j RETURN" "ctstate DNAT -j DROP"
  assert_contains "$log" "fw-managed:docker-default"
  assert_contains "$log" "ctstate DNAT -j DROP"
}
```

`case` 加 `docker) run_docker_tests ;;`;`all)` 行追加 `run_docker_tests`。

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_firewall.sh docker 2>&1 | tail -3`
Expected: `FAIL: assert_order: 'ESTABLISHED,RELATED -j RETURN' not found`。

- [ ] **Step 3: 实现 docker.sh(整文件替换)**

用以下完整内容替换 `lib/firewall/docker.sh`:

```bash
# DOCKER-USER 下的容器发布端口控制(deny-by-default)

# 从配置文件读 docker allow 行,输出 "proto port src"
fw_docker_allow_rules() {
  local type action proto port src comment
  while read -r type action proto port src comment; do
    [[ "$type" == "docker" && "$action" == "allow" ]] || continue
    printf '%s %s %s\n' "$proto" "$port" "$src"
  done < <(fw_rules_read)
}

# 构建 FW-DOCKER 链:established 放行 → 白名单 RETURN → 其余 DNAT 入站 DROP
# v4/v6 共用,按地址族过滤来源
fw_build_docker() {  # $1=ipt $2=chain
  local ipt="$1" c="$2" proto port src fam srcopt pp
  "$ipt" -A "$c" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  while read -r proto port src; do
    fam="$(fw_addr_family "$src")"
    case "$ipt:$fam" in iptables:6) continue ;; ip6tables:4) continue ;; esac
    srcopt=""; [[ "$src" != "any" ]] && srcopt="-s $src"
    IFS=',' read -ra _ports <<<"$port"
    for pp in "${_ports[@]}"; do
      "$ipt" -A "$c" -p "$proto" -m conntrack --ctstate DNAT --ctorigdstport "$pp" $srcopt \
        -j RETURN -m comment --comment "fw-managed:docker"
    done
  done < <(fw_docker_allow_rules)
  "$ipt" -A "$c" -m conntrack --ctstate DNAT -j DROP -m comment --comment "fw-managed:docker-default"
}

fw_build_docker6() { fw_build_docker "$@"; }

fw_docker_in_ip6() { ip6tables -nL DOCKER-USER >/dev/null 2>&1; }

# 扫描发布到 0.0.0.0 / :: 的容器端口,提示将被 deny-by-default 拒绝
fw_docker_scan() {
  command_exists docker || return 0
  local lines
  lines="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E '0\.0\.0\.0:|:::' || true)"
  [[ -z "$lines" ]] && return 0
  echo "提示:以下容器端口当前对外开放,deny-by-default 下将被拒绝(需 docker allow 登记放行):" >&2
  printf '%s\n' "$lines" >&2
}
```

- [ ] **Step 4: 运行,确认通过**

Run: `bash tests/test_firewall.sh docker`
Expected: `PASS: docker`

- [ ] **Step 5: 提交**

```bash
git add lib/firewall/docker.sh tests/test_firewall.sh
git commit -m "feat(firewall): DOCKER-USER 子链 deny-by-default 容器端口控制"
```

---

## Task 7: k3s.sh — 逐端口放行 + CNI + rp_filter(k3s 套件)

**Why:** k3s 节点间逐端口放行(非整机白名单),CNI pod/接口放行,rp_filter 检测告警源 IP 伪造。

**Files:**
- Modify: `lib/firewall/k3s.sh`(整文件实现)
- Modify: `tests/test_firewall.sh`(加 `run_k3s_tests`)

- [ ] **Step 1: 写 k3s 测试(先失败)**

在 `run_docker_tests` 之后插入:

```bash
run_k3s_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  local log="${temp_root}/ipt.log"
  export FW_RULES_DIR="${temp_root}/etc" FW_RULES_FILE="${temp_root}/etc/rules.conf"
  load_firewall
  iptables() { echo "iptables $*" >>"$log"; return 0; }
  fw_rules_add "node - - - 10.0.0.1 master"
  fw_rules_add "node - - - 10.0.0.2 agent"
  : >"$log"
  fw_build_k3s_input iptables FW-INPUT
  assert_contains "$log" "-s 10.0.0.1 -p tcp -m multiport --dports 6443,10250,2379,2380 -j ACCEPT"
  assert_contains "$log" "-s 10.0.0.2 -p udp -m multiport --dports 8472 -j ACCEPT"
  assert_contains "$log" "-s 10.42.0.0/16 -j ACCEPT"
  assert_contains "$log" "-i cni0 -j ACCEPT"
  assert_contains "$log" "fw-managed:k3s"

  ( export FW_RP_FILTER_PATH="${temp_root}/rpf"; echo 0 >"$FW_RP_FILTER_PATH"
    grep -Fq "rp_filter=0" <<<"$(fw_check_rp_filter 2>&1)" || fail "expected rp_filter warning" )
  ( export FW_RP_FILTER_PATH="${temp_root}/rpf2"; echo 1 >"$FW_RP_FILTER_PATH"
    [[ -z "$(fw_check_rp_filter 2>&1)" ]] || fail "expected no warning when rp_filter=1" )
}
```

`case` 加 `k3s) run_k3s_tests ;;`;`all)` 行追加 `run_k3s_tests`。

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_firewall.sh k3s 2>&1 | tail -3`
Expected: `FAIL: expected '-s 10.0.0.1 ...' in ...`(占位 `fw_build_k3s_input` 不写规则)。

- [ ] **Step 3: 实现 k3s.sh(整文件替换)**

用以下完整内容替换 `lib/firewall/k3s.sh`:

```bash
# k3s 节点逐端口放行 + CNI 流量 + rp_filter 检测

# 读配置 node 行,输出节点 IP
fw_k3s_node_ips() {
  local type action proto port src comment
  while read -r type action proto port src comment; do
    [[ "$type" == "node" ]] || continue
    printf '%s\n' "$src"
  done < <(fw_rules_read)
}

# 逐端口放行节点 IP 的 k3s 端口组 + CNI pod CIDR/接口
fw_build_k3s_input() {  # $1=ipt $2=chain
  local ipt="$1" c="$2" ip fam iface
  for ip in $(fw_k3s_node_ips); do
    fam="$(fw_addr_family "$ip")"
    case "$ipt:$fam" in iptables:6) continue ;; ip6tables:4) continue ;; esac
    "$ipt" -A "$c" -s "$ip" -p tcp -m multiport --dports "$FW_K3S_TCP_PORTS" -j ACCEPT \
      -m comment --comment "fw-managed:k3s"
    "$ipt" -A "$c" -s "$ip" -p udp -m multiport --dports "$FW_K3S_UDP_PORTS" -j ACCEPT \
      -m comment --comment "fw-managed:k3s"
  done
  # pod CIDR 默认 IPv4,仅在 iptables 下放行
  if [[ "$ipt" == "iptables" ]]; then
    "$ipt" -A "$c" -s "$FW_K3S_POD_CIDR" -j ACCEPT -m comment --comment "fw-managed:cni-pod"
  fi
  # CNI 接口放行(接口无地址族,v4/v6 同样)
  for iface in $FW_K3S_CNI_IFACES; do
    "$ipt" -A "$c" -i "$iface" -j ACCEPT -m comment --comment "fw-managed:cni-iface"
  done
}

# rp_filter=0 时告警源 IP 伪造风险(路径可经 FW_RP_FILTER_PATH 覆盖,便于测试)
fw_check_rp_filter() {
  local path="${FW_RP_FILTER_PATH:-/proc/sys/net/ipv4/conf/all/rp_filter}" v
  v="$(cat "$path" 2>/dev/null || echo 0)"
  if [[ "$v" == "0" ]]; then
    echo "警告:rp_filter=0,源 IP 伪造防护未启用;k3s 节点放行依赖网络隔离。" >&2
  fi
}
```

- [ ] **Step 4: 运行,确认通过**

Run: `bash tests/test_firewall.sh k3s`
Expected: `PASS: k3s`

- [ ] **Step 5: 提交**

```bash
git add lib/firewall/k3s.sh tests/test_firewall.sh
git commit -m "feat(firewall): k3s 逐端口放行 + CNI + rp_filter 检测"
```

---

## Task 8: IPv6 专项测试 + 地址族过滤验证(ipv6 套件)

**Why:** `fw_build_input6`/`fw_build_docker6` 的实现已随 Task 5/6 落地(v4/v6 共用 + 按族过滤)。本 Task 补 IPv6 专项断言:ICMPv6 排除 redirect(137)、v4 源不进 v6 链、v6 源不进 v4 链。无新实现代码。

**Files:**
- Modify: `tests/test_firewall.sh`(加 `run_ipv6_tests`)

- [ ] **Step 1: 写 ipv6 测试**

在 `run_k3s_tests` 之后插入:

```bash
run_ipv6_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  local log="${temp_root}/ipt.log"
  export FW_RULES_DIR="${temp_root}/etc" FW_RULES_FILE="${temp_root}/etc/rules.conf"
  export FW_SSH_PORT=22
  load_firewall
  ip6tables() { echo "ip6tables $*" >>"$log"; return 0; }
  iptables() { echo "iptables $*" >>"$log"; return 0; }
  command_exists() { case "$1" in sshd) return 1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
  fw_rules_add "host allow tcp 22 any SSH"
  fw_rules_add "host allow tcp 9090 10.0.0.0/24 v4only"
  fw_rules_add "host allow tcp 8443 2001:db8::/32 v6only"

  # IPv6 入站链:ICMPv6 排除 137,v4 源被过滤
  : >"$log"
  ( unset SSH_CONNECTION; fw_build_input6 ip6tables FW-INPUT6 )
  assert_contains "$log" "--icmpv6-type 133"
  assert_contains "$log" "--icmpv6-type 136"
  assert_not_contains "$log" "--icmpv6-type 137"
  assert_contains "$log" "--dports 22"
  assert_contains "$log" "-s 2001:db8::/32"
  assert_not_contains "$log" "10.0.0.0/24"

  # IPv4 入站链:v6 源被过滤
  : >"$log"
  ( unset SSH_CONNECTION; fw_build_host_rules iptables FW-INPUT )
  assert_contains "$log" "-s 10.0.0.0/24"
  assert_not_contains "$log" "2001:db8::/32"
}
```

`case` 加 `ipv6) run_ipv6_tests ;;`;`all)` 行追加 `run_ipv6_tests`。

- [ ] **Step 2: 运行,确认通过(实现已就绪)**

Run: `bash tests/test_firewall.sh ipv6`
Expected: `PASS: ipv6`

> 若失败,检查 Task 5 的 `fw_build_input6`(ICMPv6 类型列表不含 137)与 `fw_build_host_rules`(地址族过滤 `case "$ipt:$fam"`)。

- [ ] **Step 3: 全套回归 + 提交**

Run: `bash tests/test_firewall.sh all`
Expected: `PASS: all`

```bash
git add tests/test_firewall.sh
git commit -m "test(firewall): IPv6 专项与地址族过滤验证"
```

---

## Task 9: service.sh — systemd unit + fw 命令 + 模块安装 + 权限(service 套件)

**Why:** 持久化与命令安装。unit 在 docker/k3s 之后 boot 重应用;fw 命令 source 已安装模块;权限矩阵防提权与信息泄露。

**Files:**
- Modify: `lib/firewall/service.sh`(整文件实现)
- Modify: `tests/test_firewall.sh`(加 `run_service_tests`)

- [ ] **Step 1: 写 service 测试(先失败)**

在 `run_ipv6_tests` 之后插入:

```bash
run_service_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  export FW_BIN="${temp_root}/bin/fw"
  export FW_LIB_DIR="${temp_root}/lib/linuxshell-fw"
  export FW_SERVICE_FILE="${temp_root}/linuxshell-fw.service"
  mkdir -p "$(dirname "$FW_BIN")"
  load_firewall

  fw_write_service
  assert_file_exists "$FW_SERVICE_FILE"
  assert_contains "$FW_SERVICE_FILE" "After=network-online.target docker.service k3s.service k3s-agent.service"
  assert_contains "$FW_SERVICE_FILE" "ExecStart=${FW_BIN} apply --quiet"
  assert_contains "$FW_SERVICE_FILE" "Type=oneshot"
  assert_mode "$FW_SERVICE_FILE" "644"

  fw_write_command
  assert_file_exists "$FW_BIN"
  assert_mode "$FW_BIN" "755"
  assert_contains "$FW_BIN" "linuxshell-common.sh"
  assert_contains "$FW_BIN" 'fw_cli "$@"'
  bash -n "$FW_BIN" || fail "generated fw has syntax errors"

  export LINUXSHELL_MODULE_ROOT="$ROOT_DIR"
  fw_install_modules
  assert_file_exists "${FW_LIB_DIR}/common.sh"
  assert_file_exists "${FW_LIB_DIR}/linuxshell-common.sh"
  assert_mode "${FW_LIB_DIR}/common.sh" "644"
}
```

`case` 加 `service) run_service_tests ;;`;`all)` 行追加 `run_service_tests`。

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_firewall.sh service 2>&1 | tail -3`
Expected: `FAIL: expected file to exist: .../linuxshell-fw.service`。

- [ ] **Step 3: 实现 service.sh(整文件替换)**

用以下完整内容替换 `lib/firewall/service.sh`:

```bash
# systemd 重应用 unit + fw 命令生成 + 模块安装(权限矩阵)

fw_write_service() {
  cat >"$FW_SERVICE_FILE" <<EOF
[Unit]
Description=linuxshell firewall apply
After=network-online.target docker.service k3s.service k3s-agent.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${FW_BIN} apply --quiet
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$FW_SERVICE_FILE"
}

fw_write_command() {
  cat >"$FW_BIN" <<EOF
#!/usr/bin/env bash
set -euo pipefail
FW_LIB_DIR="\${FW_LIB_DIR:-${FW_LIB_DIR}}"
source "\${FW_LIB_DIR}/linuxshell-common.sh"
for m in config common rules docker k3s service menu main; do
  source "\${FW_LIB_DIR}/\${m}.sh"
done
fw_cli "\$@"
EOF
  chmod 755 "$FW_BIN"
}

# 把模块从 LINUXSHELL_MODULE_ROOT(本地=仓库/远程=临时目录)安装到 FW_LIB_DIR
fw_install_modules() {
  local root m
  root="${LINUXSHELL_MODULE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  mkdir -p "$FW_LIB_DIR"; chmod 755 "$FW_LIB_DIR"
  for m in config common rules docker k3s service menu main; do
    install -m 644 "${root}/lib/firewall/${m}.sh" "${FW_LIB_DIR}/${m}.sh"
  done
  install -m 644 "${root}/lib/common.sh" "${FW_LIB_DIR}/linuxshell-common.sh"
}
```

- [ ] **Step 4: 运行,确认通过**

Run: `bash tests/test_firewall.sh service`
Expected: `PASS: service`

- [ ] **Step 5: 提交**

```bash
git add lib/firewall/service.sh tests/test_firewall.sh
git commit -m "feat(firewall): systemd unit + fw 命令 + 模块安装与权限"
```

---

## Task 10: menu.sh — 交互菜单 + 禁用带时长 + 禁用态告警(disable 套件)

**Why:** 用户界面。可测部分:`fw_disable`(带时长调 systemd-run)、`fw_status`(禁用态告警);交互菜单本身靠 `bash -n` + 函数存在性(skeleton 已覆盖)。

**Files:**
- Modify: `lib/firewall/menu.sh`(整文件实现)
- Modify: `tests/test_firewall.sh`(加 `run_disable_tests`)

- [ ] **Step 1: 写 disable 测试(先失败)**

在 `run_service_tests` 之后插入:

```bash
run_disable_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  local log="${temp_root}/sys.log"
  export FW_BIN="${temp_root}/fw"
  load_firewall
  iptables() { case "$1" in -C) return 1 ;; esac; return 0; }
  mock_sdr() { echo "systemd-run $*" >>"$log"; }
  export FW_SYSTEMD_RUN=mock_sdr
  : >"$log"
  fw_disable 30m
  assert_contains "$log" "--on-active=30m"
  assert_contains "$log" "apply --quiet"

  export FW_RULES_DIR="${temp_root}/etc" FW_RULES_FILE="${temp_root}/etc/rules.conf"
  mkdir -p "$FW_RULES_DIR"; : >"$FW_RULES_FILE"
  iptables() { case "$1" in -nL) echo "Chain INPUT (policy ACCEPT)" ;; -C) return 1 ;; esac; return 0; }
  grep -Fq "已禁用" <<<"$(fw_status 2>&1)" || fail "expected disabled warning when policy ACCEPT"
}
```

`case` 加 `disable) run_disable_tests ;;`;`all)` 行追加 `run_disable_tests`。

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_firewall.sh disable 2>&1 | tail -3`
Expected: `FAIL: expected '--on-active=30m' in ...`(占位 `fw_disable` 不调 systemd-run)。

- [ ] **Step 3: 实现 menu.sh(整文件替换)**

用以下完整内容替换 `lib/firewall/menu.sh`:

```bash
# 交互菜单 + 启停 + 状态

fw_enable() { fw_apply; }

# 临时禁用:policy ACCEPT + 删跳转;带时长则到点自动 fw apply 恢复
fw_disable() {  # $1=可选时长(如 30m)
  local dur="${1:-}"
  iptables -P INPUT ACCEPT
  while iptables -C INPUT -j "$FW_INPUT_CHAIN" 2>/dev/null; do iptables -D INPUT -j "$FW_INPUT_CHAIN"; done
  if [[ "${FW_HAVE_IPV6:-0}" == 1 ]]; then
    ip6tables -P INPUT ACCEPT
    while ip6tables -C INPUT -j "${FW_INPUT_CHAIN}6" 2>/dev/null; do ip6tables -D INPUT -j "${FW_INPUT_CHAIN}6"; done
  fi
  if [[ -n "$dur" ]]; then
    "${FW_SYSTEMD_RUN:-systemd-run}" --on-active="$dur" --unit=linuxshell-fw-reenable "$FW_BIN" apply --quiet
    echo "防火墙已临时禁用,将在 ${dur} 后自动恢复。" >&2
  else
    echo "警告:防火墙已禁用且无自动恢复,请尽快 'fw apply' 或重启恢复。" >&2
  fi
}

fw_status() {
  local policy jump="no" count
  policy="$(iptables -nL INPUT 2>/dev/null | awk 'NR==1{print $4}' | tr -d '()')"
  iptables -C INPUT -j "$FW_INPUT_CHAIN" 2>/dev/null && jump="yes"
  count="$(fw_rules_read | wc -l | tr -d ' ')"
  echo "INPUT policy: ${policy:-unknown} | FW-INPUT 跳转: ${jump} | 规则: ${count} 条"
  if [[ "$policy" == "ACCEPT" || "$jump" == "no" ]]; then
    echo "⚠️ 防火墙当前已禁用,全端口暴露!请尽快 'fw apply'。" >&2
  fi
}

fw_menu_list() {
  echo "--- 当前规则(编号 类型 动作 协议 端口 来源 备注) ---"
  local n=0 line
  while IFS= read -r line; do n=$((n + 1)); printf '%3d  %s\n' "$n" "$line"; done < <(fw_rules_read)
  [[ "$n" == 0 ]] && echo "(无)"
}

fw_menu_add_host() {
  local proto port src comment
  proto="$(prompt_with_default "协议(tcp/udp)" "tcp")"
  fw_validate_proto "$proto" || { echo "协议非法"; return; }
  port="$(prompt_with_default "端口(如 22 / 80,443 / 30000:32767)" "")"
  fw_validate_port "$port" || { echo "端口非法"; return; }
  src="$(prompt_with_default "来源(any / IP / CIDR)" "any")"
  fw_validate_source "$src" || { echo "来源非法"; return; }
  comment="$(prompt_with_default "备注" "")"
  fw_rules_add "host allow ${proto} ${port} ${src} ${comment}"
  fw_apply; echo "已添加并应用。"
}

fw_menu_add_docker() {
  echo "Docker 端口默认拒绝,此处登记放行例外。"
  local proto port src comment
  proto="$(prompt_with_default "协议(tcp/udp)" "tcp")"
  fw_validate_proto "$proto" || { echo "协议非法"; return; }
  port="$(prompt_with_default "容器发布端口(单值或范围 a:b)" "")"
  fw_validate_port "$port" || { echo "端口非法"; return; }
  src="$(prompt_with_default "允许来源(any / IP / CIDR)" "")"
  fw_validate_source "$src" || { echo "来源非法"; return; }
  comment="$(prompt_with_default "备注" "")"
  fw_rules_add "docker allow ${proto} ${port} ${src} ${comment}"
  fw_apply; echo "已添加并应用。"
}

fw_menu_add_node() {
  local ip comment
  ip="$(prompt_with_default "k3s 节点 IP" "")"
  fw_validate_source "$ip" || { echo "IP 非法"; return; }
  comment="$(prompt_with_default "备注(如 master/agent)" "")"
  fw_rules_add "node - - - ${ip} ${comment}"
  fw_apply; echo "已添加并应用。"
}

fw_menu_delete() {
  fw_menu_list
  local num
  num="$(prompt_with_default "要删除的编号" "")"
  [[ "$num" =~ ^[0-9]+$ ]] || { echo "编号非法"; return; }
  fw_rules_delete "$num"
  fw_apply; echo "已删除并应用。"
}

fw_menu_toggle() {
  local dur
  if prompt_yes_no "启用防火墙?(否=临时禁用)" "y"; then
    fw_enable; echo "已启用。"
  else
    dur="$(prompt_with_default "临时禁用时长(如 30m,留空=无自动恢复)" "30m")"
    fw_disable "$dur"
  fi
}

fw_menu_backup() {
  local c bak="${FW_RULES_FILE}.bak"
  echo "1) 备份  2) 恢复"
  c="$(prompt_with_default "选择" "1")"
  case "$c" in
    1) cp "$FW_RULES_FILE" "$bak"; chmod 600 "$bak"; echo "已备份到 ${bak}" ;;
    2) if [[ -f "$bak" ]]; then cp "$bak" "$FW_RULES_FILE"; chmod 600 "$FW_RULES_FILE"; fw_apply; echo "已恢复并应用。"; else echo "无备份。"; fi ;;
    *) echo "无效选择。" ;;
  esac
}

firewall_menu() {
  local choice
  while true; do
    fw_status
    cat <<'EOF'

==== linuxshell 防火墙管理 ====
 1) 查看所有规则         5) 删除规则(按编号)
 2) 添加主机入站规则     6) 重新应用规则(apply)
 3) 添加 Docker 端口放行  7) 启用/临时禁用防火墙
 4) 管理 k3s 节点         8) 备份/恢复配置
 0) 退出
EOF
    read -r -p "选择: " choice
    case "$choice" in
      1) fw_menu_list ;;
      2) fw_menu_add_host ;;
      3) fw_menu_add_docker ;;
      4) fw_menu_add_node ;;
      5) fw_menu_delete ;;
      6) fw_apply; echo "已重新应用。" ;;
      7) fw_menu_toggle ;;
      8) fw_menu_backup ;;
      0) return 0 ;;
      *) echo "无效选择。" ;;
    esac
  done
}
```

- [ ] **Step 4: 运行,确认通过**

Run: `bash tests/test_firewall.sh disable`
Expected: `PASS: disable`

- [ ] **Step 5: 提交**

```bash
git add lib/firewall/menu.sh tests/test_firewall.sh
git commit -m "feat(firewall): 交互菜单 + 禁用带时长恢复 + 禁用态告警"
```

---

## Task 11: main.sh — firewall_main 编排 + fw_cli(orchestration 套件)

**Why:** 串起安装→初始化→apply→菜单的主流程,以及 `fw` 命令的子命令路由。

**Files:**
- Modify: `lib/firewall/main.sh`(整文件实现)
- Modify: `tests/test_firewall.sh`(加 `run_orchestration_tests`)

- [ ] **Step 1: 写 orchestration 测试(先失败)**

在 `run_disable_tests` 之后插入:

```bash
run_orchestration_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  local log="${temp_root}/act.log"
  export FW_RULES_DIR="${temp_root}/etc" FW_RULES_FILE="${temp_root}/etc/rules.conf"
  export FW_SSH_PORT=2222
  load_firewall
  fw_preflight() { echo preflight >>"$log"; }
  fw_install_modules() { echo install >>"$log"; }
  fw_write_command() { echo write_command >>"$log"; }
  fw_write_service() { echo write_service >>"$log"; }
  systemctl() { echo "systemctl $*" >>"$log"; }
  fw_docker_scan() { echo scan >>"$log"; }
  fw_apply() { echo apply >>"$log"; }
  firewall_menu() { echo menu >>"$log"; }

  : >"$log"
  firewall_main
  assert_contains "$log" "install"
  assert_contains "$log" "write_command"
  assert_contains "$log" "apply"
  assert_contains "$log" "menu"
  assert_order "$log" "apply" "menu"
  assert_file_exists "$FW_RULES_FILE"
  assert_mode "$FW_RULES_FILE" "600"
  fw_rules_read | grep -Fq "tcp 2222 any SSH" || fail "expected default SSH rule honoring FW_SSH_PORT"

  # fw_cli 路由
  : >"$log"
  fw_status() { echo status >>"$log"; }
  fw_cli status
  assert_contains "$log" "status"
}
```

`case` 加 `orchestration) run_orchestration_tests ;;`;`all)` 行追加 `run_orchestration_tests`。

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_firewall.sh orchestration 2>&1 | tail -3`
Expected: `FAIL: expected 'install' in ...`(占位 `firewall_main` 不调任何子函数)。

- [ ] **Step 3: 实现 main.sh(整文件替换)**

用以下完整内容替换 `lib/firewall/main.sh`:

```bash
# 主入口与 fw 命令路由

firewall_main() {
  fw_preflight
  fw_install_modules
  fw_write_command
  fw_write_service
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable linuxshell-fw.service >/dev/null 2>&1 || true
  if [[ ! -f "$FW_RULES_FILE" ]]; then
    mkdir -p "$FW_RULES_DIR"; chmod 700 "$FW_RULES_DIR"
    printf '%s\n' "host allow tcp ${FW_SSH_PORT} any SSH" >"$FW_RULES_FILE"
    chmod 600 "$FW_RULES_FILE"
  fi
  fw_docker_scan
  fw_apply
  firewall_menu
}

# fw 命令:无参进菜单;apply/status/list/enable/disable 直达
fw_cli() {
  local cmd="${1:-menu}"
  case "$cmd" in
    menu|"") firewall_menu ;;
    apply)   shift || true; fw_preflight; fw_apply ;;
    status)  fw_status ;;
    list)    fw_menu_list ;;
    enable)  fw_preflight; fw_enable ;;
    disable) shift || true; fw_disable "${1:-}" ;;
    *) echo "用法: fw [menu|apply|status|list|enable|disable [时长]]" >&2; return 1 ;;
  esac
}
```

- [ ] **Step 4: 运行,确认通过**

Run: `bash tests/test_firewall.sh orchestration`
Expected: `PASS: orchestration`

- [ ] **Step 5: 提交**

```bash
git add lib/firewall/main.sh tests/test_firewall.sh
git commit -m "feat(firewall): firewall_main 编排 + fw 命令路由"
```

---

## Task 12: README 防火墙管理章节(docs 套件)

**Why:** 文档化安装、用法、共存说明、deny-by-default、局限。

**Files:**
- Modify: `README.md`
- Modify: `tests/test_firewall.sh`(加 `run_docs_tests`)

- [ ] **Step 1: 写 docs 测试(先失败)**

在 `run_orchestration_tests` 之后插入:

```bash
run_docs_tests() {
  local readme="${ROOT_DIR}/README.md"
  assert_contains "$readme" "install-firewall.sh"
  assert_contains "$readme" "/usr/local/bin/fw"
  assert_contains "$readme" "fw apply"
  assert_contains "$readme" "DOCKER-USER"
  assert_contains "$readme" "deny-by-default"
  assert_contains "$readme" "10.42.0.0/16"
}
```

`case` 加 `docs) run_docs_tests ;;`;`all)` 行追加 `run_docs_tests`。

- [ ] **Step 2: 运行,确认失败**

Run: `bash tests/test_firewall.sh docs 2>&1 | tail -3`
Expected: `FAIL: expected 'install-firewall.sh' in .../README.md`。

- [ ] **Step 3: 追加 README 章节**

在 `README.md` **文件末尾**追加:

````markdown

## 防火墙管理(iptables,与 Docker/k3s 共存)

在同时跑 Docker 和 k3s 的服务器上交互式管理防火墙规则。底层用 iptables 自管理,不依赖 ufw/firewalld;主机入站 `INPUT` 默认 DROP 白名单,Docker 发布端口 deny-by-default,k3s 节点逐端口放行。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-firewall.sh)
```

安装后用 `fw` 命令(无参进交互菜单):

```bash
fw                # 交互菜单:查看/添加/删除/启停
fw status         # 当前状态(policy/跳转/规则数)
fw list           # 列出规则
fw apply          # 重新应用(docker daemon 重启后需手动跑)
fw disable 30m    # 临时禁用,30 分钟后自动恢复
```

**Docker 端口 deny-by-default**:容器发布端口(经 `DOCKER-USER`)默认拒绝外部访问,即使 `INPUT=DROP` 也不让 redis/mysql 等绕过暴露。对外服务(如 Caddy 80/443)需在菜单"添加 Docker 端口放行"登记来源。

**k3s 节点**:菜单录入各节点 IP,脚本逐端口放行 k3s 必需端口(`6443/10250/2379-2380` TCP、`8472` UDP VXLAN)及 CNI(pod `10.42.0.0/16`、`cni0`/`flannel.1`)。改了 k3s 默认 CIDR/端口用环境变量覆盖。

**IPv6**:自动同管(ip6tables 镜像,放行 NDP/echo 必需 ICMPv6,排除 redirect)。

**关键环境变量**:`FW_RULES_FILE`(默认 `/etc/linuxshell-fw/rules.conf`)、`FW_SSH_PORT`、`FW_K3S_TCP_PORTS`/`FW_K3S_UDP_PORTS`/`FW_K3S_POD_CIDR`、`FW_LIB_DIR`。

**已知局限**:Docker daemon 单独重启会重置 `DOCKER-USER`,需 `fw apply` 重建(boot 时 systemd 自动重建);kube-proxy 周期 reconcile 可能短暂重排 INPUT,`fw apply` 会重新置顶。apply 失败时查 `fw status`。

> 防火墙是安全关键组件,远程 `curl|bash` 前请核对脚本来源。
````

- [ ] **Step 4: 运行,确认通过**

Run: `bash tests/test_firewall.sh docs`
Expected: `PASS: docs`

- [ ] **Step 5: 提交**

```bash
git add README.md tests/test_firewall.sh
git commit -m "docs: README 增加防火墙管理章节"
```

---

## Task 13: 全套验证 + 现有测试回归

**Why:** 确认整体绿、未破坏既有路径、提交历史完整。

- [ ] **Step 1: 防火墙全套测试**

Run: `bash tests/test_firewall.sh all`
Expected: `PASS: all`

- [ ] **Step 2: 全仓库语法检查**

Run: `find . -name '*.sh' -type f -not -path './.git/*' -print0 | xargs -0 -n1 bash -n && echo OK`
Expected: `OK`

- [ ] **Step 3: 现有测试回归(未触碰,应保持绿)**

Run: `bash tests/test_deploy.sh && bash tests/test_pg_ha.sh && bash tests/test_mysql_ha.sh`
Expected: 三个 `PASS: all`

- [ ] **Step 4: 可执行位确认**

Run: `test -x install-firewall.sh && test -x tests/test_firewall.sh && echo OK`
Expected: `OK`

- [ ] **Step 5: 冒烟检查生成的 fw 命令内容**

```bash
tmp="$(mktemp -d)"
FW_BIN="${tmp}/fw" FW_LIB_DIR="${tmp}/lib" bash -c '
  source lib/common.sh; source lib/firewall/config.sh; source lib/firewall/service.sh
  fw_write_command; cat "$FW_BIN"
'
```
Expected: 输出含 `source "${FW_LIB_DIR}/linuxshell-common.sh"` 和 `fw_cli "$@"` 的脚本。

- [ ] **Step 6: 检查提交历史**

Run: `git log --oneline -14`
Expected: 12 个 `feat(firewall)/test(firewall)/docs` 提交(Task 1-12),在两个设计稿提交之上。

- [ ] **Step 7: Push(仅在用户明确要求时)**

不要在未经用户确认时 push。

---

## Self-Review(计划完成后自查)

**1. Spec 覆盖对照:**

| Spec 章节 | 实现 Task |
|----------|----------|
| 配置文件格式 + 权限 600 | Task 3(rulesfile)、Task 11(初始化) |
| 依赖预检 | Task 4(`fw_preflight`) |
| `set -e` 容错约定 | 贯穿(管道 `\|\| true`、`cond && action`、`while read < <(...)`) |
| build-then-swap 原语 | Task 4(`fw_chain_swap`/`fw_reassert_top`) |
| apply 引擎(IPv4) | Task 5 |
| Docker deny-by-default | Task 6 |
| k3s 逐端口 + rp_filter | Task 7 |
| IPv6 镜像 + ICMPv6 收窄 | Task 5(`fw_build_input6`)+ Task 8(测试) |
| 持久化 systemd | Task 9 |
| fw 命令 + 安装布局 + 权限矩阵 | Task 9 |
| 交互菜单 + 禁用带时长 + 禁用态告警 | Task 10 |
| 防自锁 + SSH 探测 | Task 4 + Task 5 |
| 安全加固(扫描/权限/rp_filter) | Task 6/7/9 |
| 入口脚本 | Task 2 |
| 测试计划全套 | 各 Task 套件 + Task 13 |
| README | Task 12 |

**2. Placeholder 扫描:** 无 TBD/TODO;每个代码步骤含完整可运行 bash。

**3. 类型/签名一致性:** `fw_chain_swap <ipt> <parent> <chain> <build-fn>` 与 build-fn 签名 `<ipt> <chain>` 在 Task 4/5/6/7 一致;链名 `FW_INPUT_CHAIN`/`FW_DOCKER_CHAIN` 加 `6` 后缀贯穿;`fw_rules_read/add/delete`、`fw_cli` 路由的被调函数均已定义。

**4. 已知简化(诚实记录):**
- **规则 sanity 校验**:`fw_validate_port` 已拒绝端口 0(故 `0:65535` 被拒);对"宽范围 + any"(如 `1:65535 any`)视为用户在白名单工具中的显式选择,不强制拒绝(避免误伤 NodePort 段等合法宽放行)。spec 给的是"拒绝或二次确认",本期取菜单层不阻断;如需可在 `fw_menu_add_host` 加 `prompt_yes_no` 确认。
- **备份**:菜单用单一 `.bak` 覆盖式备份(非时间戳多份),满足"备份/恢复"基本需求。
- **apply 失败回滚**:依赖"新链先上线、policy 最后设"使最坏停在 fail-open(优于锁死)+ `fw_preflight` 前置拦截;未实现完整事务回滚(spec 已将其作为可接受取舍)。

