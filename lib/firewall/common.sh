fw_die() { echo "$*" >&2; exit 1; }
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

# 来源:any / IPv4[/mask] / IPv6[/mask];校验八位组 ≤255、掩码范围
fw_validate_source() {
  local s="$1" mask o
  [[ "$s" == "any" ]] && return 0
  if [[ "$s" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]{1,2}))?$ ]]; then
    for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
      [[ "$o" -le 255 ]] || return 1
    done
    mask="${BASH_REMATCH[6]:-}"
    [[ -n "$mask" ]] && { [[ "$mask" -le 32 ]] || return 1; }
    return 0
  fi
  if [[ "$s" == *:* && "$s" =~ ^([0-9a-fA-F:.]+)(/([0-9]{1,3}))?$ ]]; then
    mask="${BASH_REMATCH[3]:-}"
    [[ -n "$mask" ]] && { [[ "$mask" -le 128 ]] || return 1; }
    return 0
  fi
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
  } | grep -E '^[0-9]+$' | sort -u || true
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
