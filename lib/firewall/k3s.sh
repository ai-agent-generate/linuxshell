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
