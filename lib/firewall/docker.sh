# DOCKER-USER 下的容器发布端口控制(deny-by-default)

# 从配置文件读 docker allow 行,输出 "proto port src"
fw_docker_allow_rules() {
  local type action proto port src comment
  while read -r type action proto port src comment; do
    [[ "$type" == "docker" && "$action" == "allow" ]] || continue
    printf '%s %s %s\n' "$proto" "$port" "$src"
  done < <(fw_rules_read)
}

# 构建 FW-DOCKER 链:established 放行 → 信任 IP RETURN → 白名单 RETURN → 其余 DNAT 入站 DROP
# v4/v6 共用,按地址族过滤来源
fw_build_docker() {  # $1=ipt $2=chain
  local ipt="$1" c="$2" proto port src fam srcopt pp _ports
  "$ipt" -A "$c" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  fw_build_trust_docker "$ipt" "$c"
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
