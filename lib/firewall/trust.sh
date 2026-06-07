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
