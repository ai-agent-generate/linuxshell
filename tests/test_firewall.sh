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
  if fw_validate_source "999.999.999.999" 2>/dev/null; then fail "oct>255 should fail"; fi
  if fw_validate_source "10.0.0.1/99" 2>/dev/null; then fail "v4 mask>32 should fail"; fi
  if fw_validate_source "2001:db8::1/129" 2>/dev/null; then fail "v6 mask>128 should fail"; fi
  fw_validate_source "2001:db8::/32" || fail "valid v6 cidr should pass"

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

run_swap_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  local log="${temp_root}/ipt.log"
  load_firewall
  local cc=0
  iptables() {
    echo "iptables $*" >>"$log"
    case "$1" in
      -nL) return 1 ;;
      -C) cc=$((cc + 1)); [[ "$cc" == 1 ]] && return 0 || return 1 ;;
    esac
    return 0
  }
  : >"$log"
  demo_build() { local ipt="$1" c="$2"; "$ipt" -A "$c" -i lo -j ACCEPT; }
  fw_chain_swap iptables INPUT FW-INPUT demo_build
  assert_order "$log" "-N FW-INPUT-NEW" "-A FW-INPUT-NEW"
  assert_order "$log" "-A FW-INPUT-NEW" "-I INPUT 1 -j FW-INPUT-NEW"
  # 关键防锁断言:新跳转上线在删旧跳转之前(二次 apply 无空窗)
  assert_order "$log" "-I INPUT 1 -j FW-INPUT-NEW" "-D INPUT -j FW-INPUT"
  assert_order "$log" "-I INPUT 1 -j FW-INPUT-NEW" "-E FW-INPUT-NEW FW-INPUT"
  assert_contains "$log" "-E FW-INPUT-NEW FW-INPUT"
}

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

run_failopen_tests() {
  local temp_root; temp_root="$(mktemp -d)"; trap "rm -rf '$temp_root'" RETURN
  local log="${temp_root}/ipt.log"
  export FW_RULES_DIR="${temp_root}/etc" FW_RULES_FILE="${temp_root}/etc/rules.conf"
  mkdir -p "$FW_RULES_DIR"; : >"$FW_RULES_FILE"
  load_firewall
  iptables() { echo "iptables $*" >>"$log"; case "$1" in -nL|-C) return 1 ;; esac; return 0; }
  fw_preflight() { :; }
  fw_chain_swap() { :; }
  fw_reassert_top() { :; }
  fw_check_rp_filter() { :; }
  fw_detect_ssh_ports() { :; }   # 返回空 → 触发 fail-open
  : >"$log"
  local out; out="$(fw_apply 2>&1)"
  if grep -Fq -- "-P INPUT DROP" "$log"; then fail "expected NO policy DROP when ssh ports empty"; fi
  grep -Fq "跳过 INPUT DROP" <<<"$out" || fail "expected fail-open warning when ssh ports empty"
}

run_docs_tests() {
  local readme="${ROOT_DIR}/README.md"
  assert_contains "$readme" "install-firewall.sh"
  assert_contains "$readme" "/usr/local/bin/fw"
  assert_contains "$readme" "fw apply"
  assert_contains "$readme" "DOCKER-USER"
  assert_contains "$readme" "deny-by-default"
  assert_contains "$readme" "10.42.0.0/16"
}

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

main() {
  local suite="${1:-all}"
  case "$suite" in
    config) run_config_tests ;;
    skeleton) run_skeleton_tests ;;
    validate) run_validate_tests ;;
    rulesfile) run_rulesfile_tests ;;
    swap) run_swap_tests ;;
    lockout) run_lockout_tests ;;
    apply) run_apply_tests ;;
    docker) run_docker_tests ;;
    k3s) run_k3s_tests ;;
    ipv6) run_ipv6_tests ;;
    service) run_service_tests ;;
    disable) run_disable_tests ;;
    orchestration) run_orchestration_tests ;;
    failopen) run_failopen_tests ;;
    docs) run_docs_tests ;;
    all) run_skeleton_tests; run_config_tests; run_validate_tests; run_rulesfile_tests; run_swap_tests; run_lockout_tests; run_apply_tests; run_docker_tests; run_k3s_tests; run_ipv6_tests; run_service_tests; run_disable_tests; run_orchestration_tests; run_failopen_tests; run_docs_tests ;;
    *) fail "unknown suite: $suite" ;;
  esac
  echo "PASS: ${suite}"
}

main "$@"
