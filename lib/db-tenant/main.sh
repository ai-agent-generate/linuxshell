#!/usr/bin/env bash
# lib/db-tenant/main.sh — 引擎选择与动作菜单

# 删除动作:交互选出租户身份后调用对应引擎删除
db_tenant_drop_action() {
  local engine="$1"
  if [[ "$engine" == "pg" ]]; then
    local role db
    role="$(prompt_with_default "要删除的租户名(角色)" "")"
    db="$(prompt_with_default "数据库名" "$role")"
    pg_drop_tenant "$role" "$db"
  else
    local user host db
    user="$(prompt_with_default "要删除的租户名(用户)" "")"
    host="$(prompt_with_default "host" "${DB_TENANT_MYSQL_DEFAULT_HOST}")"
    db="$(prompt_with_default "数据库名" "$user")"
    mysql_drop_tenant "$user" "$host" "$db"
  fi
}

# 备份动作:仅备份(不删除),不要求可写
db_tenant_backup_action() {
  local engine="$1" db
  db="$(prompt_with_default "要备份的数据库名" "")"
  db_tenant_validate_identifier "$db" || return 1
  if [[ "$engine" == "pg" ]]; then
    pg_backup_tenant "$db"
  else
    mysql_backup_tenant "$db"
  fi
}

# 按引擎+动作号分发。$1=pg|mysql $2=action(1..6)
db_tenant_dispatch() {
  local engine="$1" action="$2"
  case "$action" in
    1) db_tenant_with_lock ${engine}_create_tenant ;;
    2) ${engine}_list_tenants ;;
    3) db_tenant_with_lock ${engine}_set_limit ;;
    4) db_tenant_with_lock ${engine}_set_password ;;
    5) db_tenant_backup_action "$engine" ;;
    6) db_tenant_with_lock db_tenant_drop_action "$engine" ;;
    *) echo "未知动作: $action" >&2; return 1 ;;
  esac
}

db_tenant_action_menu() {
  local engine="$1" choice
  while true; do
    cat >&2 <<'MENU'

=== 动作菜单 ===
 1) 创建租户
 2) 列出租户
 3) 修改限额
 4) 修改密码
 5) 备份租户
 6) 删除租户
 0) 退出
MENU
    choice="$(prompt_with_default "请选择" "0")"
    case "$choice" in
      0) return 0 ;;
      1|2|3|4|5|6) db_tenant_dispatch "$engine" "$choice" || true ;;
      *) echo "无效选择" >&2 ;;
    esac
  done
}

db_tenant_main() {
  require_root || return 1
  local engine_choice engine
  cat >&2 <<'MENU'

=== 数据库多租户管理 ===
 1) PostgreSQL
 2) MySQL
MENU
  engine_choice="$(prompt_with_default "选择引擎" "1")"
  case "$engine_choice" in
    1) engine=pg; pg_detect_target ;;
    2) engine=mysql; mysql_detect_target; mysql_resolve_admin_password ;;
    *) echo "无效引擎" >&2; return 1 ;;
  esac
  local mode
  if [[ "$engine" == "pg" ]]; then mode="${PG_TARGET_MODE:-?}"; else mode="${MYSQL_TARGET_MODE:-?}"; fi
  echo "目标形态: ${engine} / ${mode}" >&2
  if ! prompt_yes_no "确认对该目标操作?" "y"; then echo "已取消。" >&2; return 0; fi
  db_tenant_action_menu "$engine"
}
