# 主入口与 fw 命令路由

firewall_main() {
  fw_preflight
  fw_install_modules
  fw_write_command
  fw_write_service
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable linuxshell-fw.service >/dev/null 2>&1 || true
  if [[ ! -f "$FW_RULES_FILE" ]]; then
    mkdir -p "$FW_RULES_DIR"; chmod 700 "$FW_RULES_DIR"
    printf '%s\n' "host allow tcp ${FW_SSH_PORT} any SSH" >"$FW_RULES_FILE"
    chmod 600 "$FW_RULES_FILE"
  fi
  fw_docker_scan
  fw_apply
  firewall_menu
}

# fw 命令:无参进菜单;apply/status/list/enable/disable 直达
fw_cli() {
  local cmd="${1:-menu}"
  case "$cmd" in
    menu|"") firewall_menu ;;
    apply)   shift || true; fw_preflight; fw_apply ;;
    status)  fw_status ;;
    list)    fw_menu_list ;;
    enable)  fw_preflight; fw_enable ;;
    disable) shift || true; fw_disable "${1:-}" ;;
    *) echo "用法: fw [menu|apply|status|list|enable|disable [时长]]" >&2; return 1 ;;
  esac
}
