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

# FW-INPUT:对信任 IP 放行所有流量(全协议全端口),按地址族归类
fw_build_trust_input() {  # $1=ipt $2=chain
  local ipt="$1" c="$2" ip fam
  for ip in $(fw_trust_ips); do
    fam="$(fw_addr_family "$ip")"
    case "$ipt:$fam" in iptables:6) continue ;; ip6tables:4) continue ;; esac
    "$ipt" -A "$c" -s "$ip" -j ACCEPT -m comment --comment "fw-managed:trust"
  done
}
