#!/usr/bin/env bash
# lib/db-tenant/pg.sh — PostgreSQL 后端

# 建租户 SQL。参数:
# 1=role 2=db 3=pw(已转义) 4=role_conn 5=db_conn 6=stmt_to 7=idle_to 8=work_mem
# 9=role_exists(0/1) 10=db_exists(0/1) 11=db_newly_created(0/1)
pg_build_create_tenant_sql() {
  local role="$1" db="$2" pw="$3" rconn="$4" dconn="$5" stmt="$6" idle="$7" wmem="$8"
  local role_exists="$9" db_exists="${10}" db_new="${11}"
  if [[ "$role_exists" == "1" ]]; then
    printf 'ALTER ROLE "%s" CONNECTION LIMIT %s;\n' "$role" "$rconn"
  else
    printf 'CREATE ROLE "%s" LOGIN PASSWORD '\''%s'\'' CONNECTION LIMIT %s;\n' "$role" "$pw" "$rconn"
  fi
  if [[ "$db_exists" == "1" ]]; then
    printf 'ALTER DATABASE "%s" OWNER TO "%s";\n' "$db" "$role"
    printf 'ALTER DATABASE "%s" CONNECTION LIMIT %s;\n' "$db" "$dconn"
  else
    printf 'CREATE DATABASE "%s" OWNER "%s" CONNECTION LIMIT %s;\n' "$db" "$role" "$dconn"
  fi
  if [[ "$db_new" == "1" ]]; then
    printf 'REVOKE CONNECT ON DATABASE "%s" FROM PUBLIC;\n' "$db"
    printf 'GRANT CONNECT ON DATABASE "%s" TO "%s";\n' "$db" "$role"
  fi
  printf 'ALTER ROLE "%s" IN DATABASE "%s" SET statement_timeout = '\''%s'\'';\n' "$role" "$db" "$stmt"
  printf 'ALTER ROLE "%s" IN DATABASE "%s" SET idle_in_transaction_session_timeout = '\''%s'\'';\n' "$role" "$db" "$idle"
  printf 'ALTER ROLE "%s" IN DATABASE "%s" SET work_mem = '\''%s'\'';\n' "$role" "$db" "$wmem"
}

# 改限额。1=role 2=db 3=rconn 4=dconn 5=stmt 6=idle 7=wmem
pg_build_set_limit_sql() {
  printf 'ALTER ROLE "%s" CONNECTION LIMIT %s;\n' "$1" "$3"
  printf 'ALTER DATABASE "%s" CONNECTION LIMIT %s;\n' "$2" "$4"
  printf 'ALTER ROLE "%s" IN DATABASE "%s" SET statement_timeout = '\''%s'\'';\n' "$1" "$2" "$5"
  printf 'ALTER ROLE "%s" IN DATABASE "%s" SET idle_in_transaction_session_timeout = '\''%s'\'';\n' "$1" "$2" "$6"
  printf 'ALTER ROLE "%s" IN DATABASE "%s" SET work_mem = '\''%s'\'';\n' "$1" "$2" "$7"
}

# 改密码。1=role 2=pw(已转义)
pg_build_set_password_sql() {
  printf 'ALTER ROLE "%s" PASSWORD '\''%s'\'';\n' "$1" "$2"
}

# 删除。1=role 2=db 3=force(0/1) 4=role_exists 5=db_exists
pg_build_drop_sql() {
  local role="$1" db="$2" force="$3" role_exists="$4" db_exists="$5"
  if [[ "$db_exists" == "1" ]]; then
    printf 'SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '\''%s'\'' AND pid <> pg_backend_pid();\n' "$db"
    if [[ "$force" == "1" ]]; then
      printf 'DROP DATABASE IF EXISTS "%s" WITH (FORCE);\n' "$db"
    else
      printf 'DROP DATABASE IF EXISTS "%s";\n' "$db"
    fi
  fi
  if [[ "$role_exists" == "1" ]]; then
    printf 'DROP OWNED BY "%s";\n' "$role"
    printf 'DROP ROLE IF EXISTS "%s";\n' "$role"
  fi
}

# 列出租户(库 owner 为非超级用户)。LEFT JOIN 暴露孤儿
pg_build_list_sql() {
  cat <<'SQL'
SELECT d.datname AS db, COALESCE(r.rolname,'<no-owner>') AS role,
       COALESCE(r.rolconnlimit::text,'-') AS role_conn_limit,
       d.datconnlimit AS db_conn_limit
FROM pg_database d
LEFT JOIN pg_roles r ON d.datdba = r.oid
WHERE d.datname NOT IN ('postgres','template0','template1')
  AND (r.rolsuper IS DISTINCT FROM true)
ORDER BY d.datname;
SQL
}

# 探测目标,设置 PG_TARGET_MODE=docker|local
pg_detect_target() {
  if [[ "${DB_TENANT_FORCE_TARGET:-}" == "docker" ]]; then PG_TARGET_MODE=docker; return 0; fi
  if [[ "${DB_TENANT_FORCE_TARGET:-}" == "local" ]]; then PG_TARGET_MODE=local; return 0; fi
  if command_exists docker && \
     [[ "$(docker inspect -f '{{.State.Running}}' "${DB_TENANT_PG_CONTAINER}" 2>/dev/null)" == "true" ]]; then
    PG_TARGET_MODE=docker
  else
    PG_TARGET_MODE=local
  fi
}

# 执行 SQL(从 stdin)。$1=dbname(默认 postgres)
pg_exec_sql() {
  local dbname="${1:-postgres}"
  if [[ "${PG_TARGET_MODE:-local}" == "docker" ]]; then
    docker exec -i "${DB_TENANT_PG_CONTAINER}" psql -v ON_ERROR_STOP=1 -U postgres -d "$dbname"
  else
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$dbname"
  fi
}

# 标量查询。$1=dbname $2=sql -> 去空白的单值
pg_query() {
  local dbname="${1:-postgres}" sql="$2" out
  if [[ "${PG_TARGET_MODE:-local}" == "docker" ]]; then
    out="$(printf '%s\n' "$sql" | docker exec -i "${DB_TENANT_PG_CONTAINER}" psql -tAX -U postgres -d "$dbname" 2>/dev/null)"
  else
    out="$(printf '%s\n' "$sql" | sudo -u postgres psql -tAX -d "$dbname" 2>/dev/null)"
  fi
  printf '%s' "$out" | tr -d '[:space:]'
}

# 探测当前 PG 角色:primary|standby|role_unknown
pg_detect_role() {
  local r
  r="$(pg_query postgres 'SELECT pg_is_in_recovery();' 2>/dev/null || true)"
  case "$r" in
    f|false) printf 'primary' ;;
    t|true)  printf 'standby' ;;
    *)       printf 'role_unknown'; return 1 ;;
  esac
}

# 只读检测
pg_assert_writable() {
  local r; r="$(pg_query postgres 'SELECT pg_is_in_recovery();')"
  if [[ -z "$r" ]]; then echo "无法确认主从状态(连接异常?),已中止。" >&2; return 1; fi
  if [[ "$r" == "t" ]]; then echo "当前为 standby,请在 leader 上运行写操作。" >&2; return 1; fi
  return 0
}

# 是否支持 DROP DATABASE WITH (FORCE)(PG13+)
pg_supports_force() {
  local v; v="$(pg_query postgres 'SHOW server_version_num;')"
  [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 130000 ))
}

# 守卫:拒绝系统/超级/复制角色
pg_guard_not_system_role() {
  local role="$1"
  if db_tenant_is_system_name "$role" "${DB_TENANT_PG_SYSTEM_NAMES}"; then
    echo "拒绝删除系统角色: $role" >&2; return 1
  fi
  if [[ "$(pg_query postgres "SELECT 1 FROM pg_roles WHERE rolname = '${role}' AND (rolsuper OR rolreplication OR rolbypassrls);")" == "1" ]]; then
    echo "拒绝删除超级/复制角色: $role" >&2; return 1
  fi
  return 0
}

# 角色/库是否存在(返回 0/1 字符串)
pg_role_exists() { [[ "$(pg_query postgres "SELECT 1 FROM pg_roles WHERE rolname='${1}';")" == "1" ]] && echo 1 || echo 0; }
pg_db_exists()   { [[ "$(pg_query postgres "SELECT 1 FROM pg_database WHERE datname='${1}';")" == "1" ]] && echo 1 || echo 0; }

# 备份(仅库)。$1=db;成功设置 PG_BACKUP_FILE 并返回 0
pg_backup_tenant() {
  local db="$1" file
  db_tenant_prepare_backup_dir || return 1
  file="$(db_tenant_backup_path pg "$db" dump)"
  if [[ "${PG_TARGET_MODE:-local}" == "docker" ]]; then
    ( umask 077; docker exec -i "${DB_TENANT_PG_CONTAINER}" pg_dump -U postgres -Fc -d "$db" >"$file" ) || { rm -f "$file"; return 1; }
  else
    ( umask 077; sudo -u postgres pg_dump -Fc -d "$db" >"$file" ) || { rm -f "$file"; return 1; }
  fi
  if ! db_tenant_verify_backup pg "$file"; then rm -f "$file"; return 1; fi
  chmod 600 "$file"
  PG_BACKUP_FILE="$file"
  echo "已备份: $file ($(du -h "$file" 2>/dev/null | awk '{print $1}'))"
  return 0
}

# 删除编排:校验->只读->守卫->备份+校验->二次确认->执行
pg_drop_tenant() {
  local role="$1" db="$2"
  db_tenant_validate_identifier "$role" || return 1
  db_tenant_validate_identifier "$db" || return 1
  if db_tenant_is_system_name "$db" "${DB_TENANT_PG_SYSTEM_NAMES}"; then echo "拒绝删除系统库: $db" >&2; return 1; fi
  pg_assert_writable || return 1
  pg_guard_not_system_role "$role" || return 1
  if ! pg_backup_tenant "$db"; then echo "备份失败,已中止删除。" >&2; return 1; fi
  echo "将删除: 数据库 \"$db\" + 角色 \"$role\""
  local typed; typed="$(prompt_with_default "确认删除请重新输入租户名" "")"
  if [[ "$typed" != "$role" ]]; then echo "名称不匹配,已取消。" >&2; return 1; fi
  local force; if pg_supports_force; then force=1; else force=0; fi
  if pg_build_drop_sql "$role" "$db" "$force" "$(pg_role_exists "$role")" "$(pg_db_exists "$db")" | pg_exec_sql postgres; then
    echo "已删除租户: $role / $db (备份: ${PG_BACKUP_FILE:-N/A})"
  else
    echo "DROP 执行失败(备份已生成: ${PG_BACKUP_FILE:-N/A});请检查后重试。" >&2
    return 1
  fi
}

# 读现有角色连接上限(不存在回显默认)
pg_current_role_conn() {
  local v; v="$(pg_query postgres "SELECT rolconnlimit FROM pg_roles WHERE rolname='${1}';")"
  [[ -n "$v" && "$v" != "-1" ]] && echo "$v" || echo "${DB_TENANT_PG_CONN_LIMIT}"
}

pg_create_tenant() {
  local role="${1:-}"
  if [[ -z "$role" ]]; then role="$(prompt_with_default "租户名(=角色名)" "")"; fi
  db_tenant_validate_identifier "$role" || return 1
  local db; db="$(prompt_with_default "数据库名" "$role")"
  db_tenant_validate_identifier "$db" || return 1
  pg_assert_writable || return 1

  local rexist dexist; rexist="$(pg_role_exists "$role")"; dexist="$(pg_db_exists "$db")"
  local def_conn="${DB_TENANT_PG_CONN_LIMIT}"
  if [[ "$rexist" == "1" ]]; then
    def_conn="$(pg_current_role_conn "$role")"
    echo "该租户/角色已存在,以下为现值回填(回车保持不变)。"
  fi
  local rconn dconn stmt idle wmem pw escpw
  rconn="$(prompt_with_default "角色并发连接上限" "$def_conn")"
  dconn="$(prompt_with_default "库级并发连接上限" "${DB_TENANT_PG_DB_CONN_LIMIT}")"
  stmt="$(prompt_with_default "单语句超时" "${DB_TENANT_PG_STATEMENT_TIMEOUT}")"
  idle="$(prompt_with_default "空闲事务超时" "${DB_TENANT_PG_IDLE_TX_TIMEOUT}")"
  wmem="$(prompt_with_default "单会话排序内存" "${DB_TENANT_PG_WORK_MEM}")"
  if [[ "$rexist" == "1" ]]; then
    pw=""; escpw=""
  else
    pw="$(db_tenant_generate_password)"; escpw="$(db_tenant_sql_escape_literal pg "$pw")"
  fi
  local db_new=0; [[ "$dexist" == "0" ]] && db_new=1

  if pg_build_create_tenant_sql "$role" "$db" "$escpw" "$rconn" "$dconn" "$stmt" "$idle" "$wmem" \
       "$rexist" "$dexist" "$db_new" | pg_exec_sql postgres; then
    echo "== 租户就绪(PostgreSQL) =="
    echo "库: $db  角色: $role"
    [[ -n "$pw" ]] && echo "密码(仅显示一次): $pw"
    echo "连接示例: psql -h <host> -U $role -d $db"
  else
    echo "创建失败,请检查上面的错误。" >&2
    return 1
  fi
}

pg_list_tenants() { pg_build_list_sql | pg_exec_sql postgres; }

pg_set_limit() {
  local role; role="$(prompt_with_default "租户名(角色)" "")"; db_tenant_validate_identifier "$role" || return 1
  local db; db="$(prompt_with_default "数据库名" "$role")"; db_tenant_validate_identifier "$db" || return 1
  pg_assert_writable || return 1
  local cur; cur="$(pg_current_role_conn "$role")"
  local rconn dconn stmt idle wmem
  rconn="$(prompt_with_default "角色并发连接上限" "$cur")"
  dconn="$(prompt_with_default "库级并发连接上限" "${DB_TENANT_PG_DB_CONN_LIMIT}")"
  stmt="$(prompt_with_default "单语句超时" "${DB_TENANT_PG_STATEMENT_TIMEOUT}")"
  idle="$(prompt_with_default "空闲事务超时" "${DB_TENANT_PG_IDLE_TX_TIMEOUT}")"
  wmem="$(prompt_with_default "单会话排序内存" "${DB_TENANT_PG_WORK_MEM}")"
  if pg_build_set_limit_sql "$role" "$db" "$rconn" "$dconn" "$stmt" "$idle" "$wmem" | pg_exec_sql postgres; then
    echo "已更新限额: $role"
  else
    echo "更新限额失败。" >&2; return 1
  fi
}

pg_set_password() {
  local role; role="$(prompt_with_default "租户名(角色)" "")"; db_tenant_validate_identifier "$role" || return 1
  pg_assert_writable || return 1
  local pw escpw; pw="$(db_tenant_generate_password)"; escpw="$(db_tenant_sql_escape_literal pg "$pw")"
  if pg_build_set_password_sql "$role" "$escpw" | pg_exec_sql postgres; then
    echo "新密码(仅显示一次): $pw"
  else
    echo "改密码失败。" >&2; return 1
  fi
}
