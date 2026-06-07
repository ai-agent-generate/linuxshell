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
fw_chain_swap() { :; }
fw_reassert_top() { :; }
fw_preflight() { :; }
fw_have_xt() { :; }
fw_detect_ssh_ports() { :; }

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
