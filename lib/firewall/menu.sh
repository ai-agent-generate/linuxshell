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
