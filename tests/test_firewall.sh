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
