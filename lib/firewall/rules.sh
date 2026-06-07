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
  fw_build_trust_input "$ipt" "$c"
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
  fw_build_trust_input "$ipt" "$c"
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
  local ssh_ports; ssh_ports="$(fw_detect_ssh_ports)"
  if [[ -n "$ssh_ports" ]]; then
    iptables -P INPUT DROP
    [[ "${FW_HAVE_IPV6:-0}" == 1 ]] && ip6tables -P INPUT DROP
  else
    echo "警告: 探测不到 SSH 端口,为防锁死跳过 INPUT DROP(防火墙保持放行)。请设置 FW_SSH_PORT 后重新 fw apply。" >&2
  fi
  fw_check_rp_filter
}
