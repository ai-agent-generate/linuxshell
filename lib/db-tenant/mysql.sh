#!/usr/bin/env bash
# lib/db-tenant/mysql.sh — MySQL 后端

# 建租户。1=user 2=host 3=db 4=pw(已转义) 5=muc 6=mcph 7=mqph 8=muph 9=user_exists(0/1)
mysql_build_create_tenant_sql() {
  local user="$1" host="$2" db="$3" pw="$4" muc="$5" mcph="$6" mqph="$7" muph="$8" exists="$9"
  printf 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4;\n' "$db"
  if [[ "$exists" == "1" ]]; then
    printf "ALTER USER '%s'@'%s' WITH MAX_USER_CONNECTIONS %s MAX_CONNECTIONS_PER_HOUR %s MAX_QUERIES_PER_HOUR %s MAX_UPDATES_PER_HOUR %s;\n" \
      "$user" "$host" "$muc" "$mcph" "$mqph" "$muph"
  else
    printf "CREATE USER '%s'@'%s' IDENTIFIED BY '%s' WITH MAX_USER_CONNECTIONS %s MAX_CONNECTIONS_PER_HOUR %s MAX_QUERIES_PER_HOUR %s MAX_UPDATES_PER_HOUR %s;\n" \
      "$user" "$host" "$pw" "$muc" "$mcph" "$mqph" "$muph"
  fi
  printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%s';\n" "$db" "$user" "$host"
}

# 改限额。1=user 2=host 3=muc 4=mcph 5=mqph 6=muph
mysql_build_set_limit_sql() {
  printf "ALTER USER '%s'@'%s' WITH MAX_USER_CONNECTIONS %s MAX_CONNECTIONS_PER_HOUR %s MAX_QUERIES_PER_HOUR %s MAX_UPDATES_PER_HOUR %s;\n" \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

# 改密码。1=user 2=host 3=pw(已转义)
mysql_build_set_password_sql() {
  printf "ALTER USER '%s'@'%s' IDENTIFIED BY '%s';\n" "$1" "$2" "$3"
}

# 删除。1=user 2=host 3=db 4=db_exists(0/1) 5=user_exists(0/1)
mysql_build_drop_sql() {
  [[ "$4" == "1" ]] && printf 'DROP DATABASE IF EXISTS `%s`;\n' "$3"
  [[ "$5" == "1" ]] && printf "DROP USER IF EXISTS '%s'@'%s';\n" "$1" "$2"
  return 0
}

# 列出账号及其限额。$1=空格分隔的系统用户 denylist(可空,空则不加过滤)
mysql_build_list_sql() {
  local list="${1:-}" notin="" u
  for u in $list; do notin="${notin:+$notin,}'${u}'"; done
  if [[ -n "$notin" ]]; then
    printf 'SELECT user, host, max_user_connections, max_connections, max_questions, max_updates FROM mysql.user WHERE user NOT IN (%s) ORDER BY user, host;\n' "$notin"
  else
    printf 'SELECT user, host, max_user_connections, max_connections, max_questions, max_updates FROM mysql.user ORDER BY user, host;\n'
  fi
}

# 探测目标,设置 MYSQL_TARGET_MODE=docker|local
mysql_detect_target() {
  if [[ "${DB_TENANT_FORCE_TARGET:-}" == "docker" ]]; then MYSQL_TARGET_MODE=docker; return 0; fi
  if [[ "${DB_TENANT_FORCE_TARGET:-}" == "local" ]]; then MYSQL_TARGET_MODE=local; return 0; fi
  if command_exists docker && \
     [[ "$(docker inspect -f '{{.State.Running}}' "${DB_TENANT_MYSQL_CONTAINER}" 2>/dev/null)" == "true" ]]; then
    MYSQL_TARGET_MODE=docker
  else
    MYSQL_TARGET_MODE=local
  fi
}

# 解析管理员密码:DB_TENANT_MYSQL_ADMIN_PASSWORD -> MYSQL_HA_ROOT_PASSWORD -> MYSQL_ROOT_PASSWORD -> 交互
mysql_resolve_admin_password() {
  if [[ -z "${DB_TENANT_MYSQL_ADMIN_PASSWORD}" ]]; then
    DB_TENANT_MYSQL_ADMIN_PASSWORD="${MYSQL_HA_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
  fi
  if [[ -z "${DB_TENANT_MYSQL_ADMIN_PASSWORD}" ]]; then
    printf "MySQL %s 密码: " "${DB_TENANT_MYSQL_ADMIN_USER}" >&2
    IFS= read -rs DB_TENANT_MYSQL_ADMIN_PASSWORD; echo >&2
  fi
}

# 写临时 600 admin cnf 到 $1
mysql_write_admin_cnf() {
  ( umask 077; cat >"$1" <<EOF
[client]
user=${DB_TENANT_MYSQL_ADMIN_USER}
password=${DB_TENANT_MYSQL_ADMIN_PASSWORD}
EOF
  )
}

# 执行 SQL(从 stdin)。凭据经临时 cnf,docker 用 docker cp 进容器用完即删
mysql_exec_sql() {
  local cnf rc=0; cnf="$(mktemp)"; mysql_write_admin_cnf "$cnf"
  if [[ "${MYSQL_TARGET_MODE:-local}" == "docker" ]]; then
    local incnf="/tmp/.db-tenant-$$.cnf"
    docker cp "$cnf" "${DB_TENANT_MYSQL_CONTAINER}:${incnf}" >/dev/null
    docker exec -i "${DB_TENANT_MYSQL_CONTAINER}" mysql --defaults-extra-file="${incnf}" || rc=$?
    docker exec "${DB_TENANT_MYSQL_CONTAINER}" rm -f "${incnf}" >/dev/null 2>&1 || true
  else
    mysql --defaults-extra-file="$cnf" --socket="${DB_TENANT_MYSQL_SOCKET}" || rc=$?
  fi
  rm -f "$cnf"
  return $rc
}

# 标量查询(-N -B 去表头),$1=sql
mysql_query() {
  local sql="$1" cnf out rc=0; cnf="$(mktemp)"; mysql_write_admin_cnf "$cnf"
  if [[ "${MYSQL_TARGET_MODE:-local}" == "docker" ]]; then
    local incnf="/tmp/.db-tenant-q-$$.cnf"
    docker cp "$cnf" "${DB_TENANT_MYSQL_CONTAINER}:${incnf}" >/dev/null
    out="$(printf '%s\n' "$sql" | docker exec -i "${DB_TENANT_MYSQL_CONTAINER}" mysql --defaults-extra-file="${incnf}" -N -B 2>/dev/null)" || rc=$?
    docker exec "${DB_TENANT_MYSQL_CONTAINER}" rm -f "${incnf}" >/dev/null 2>&1 || true
  else
    out="$(printf '%s\n' "$sql" | mysql --defaults-extra-file="$cnf" --socket="${DB_TENANT_MYSQL_SOCKET}" -N -B 2>/dev/null)" || rc=$?
  fi
  rm -f "$cnf"
  printf '%s' "$out" | tr -d '[:space:]'
  return 0
}

# 探测当前 MySQL 角色:primary|replica|role_unknown
mysql_detect_role() {
  local r
  r="$(mysql_query 'SELECT @@global.super_read_only + @@global.read_only;' 2>/dev/null || true)"
  case "$r" in
    0) printf 'primary' ;;
    ''|*[!0-9]*) printf 'role_unknown'; return 1 ;;
    *) printf 'replica' ;;
  esac
}

# 只读检测
mysql_assert_writable() {
  local r; r="$(mysql_query 'SELECT @@global.super_read_only + @@global.read_only;')"
  if [[ -z "$r" ]]; then echo "无法确认主从状态(连接异常?),已中止。" >&2; return 1; fi
  if [[ "$r" != "0" ]]; then echo "当前为只读(replica),请在 primary 上运行写操作。" >&2; return 1; fi
  return 0
}

# 守卫:拒绝系统用户/系统库
mysql_guard_not_system() {
  local user="$1" db="$2"
  if db_tenant_is_system_name "$user" "${DB_TENANT_MYSQL_SYSTEM_USERS}"; then
    echo "拒绝删除系统账号: $user" >&2; return 1
  fi
  if db_tenant_is_system_name "$db" "${DB_TENANT_MYSQL_SYSTEM_DATABASES}"; then
    echo "拒绝删除系统库: $db" >&2; return 1
  fi
  return 0
}

mysql_user_exists() {
  [[ "$(mysql_query "SELECT 1 FROM mysql.user WHERE user='${1}' AND host='${2}';")" == "1" ]] && echo 1 || echo 0
}
mysql_db_exists() {
  [[ "$(mysql_query "SELECT 1 FROM information_schema.schemata WHERE schema_name='${1}';")" == "1" ]] && echo 1 || echo 0
}

# 备份(仅库)。$1=db;成功设置 MYSQL_BACKUP_FILE 返回 0
mysql_backup_tenant() {
  local db="$1" file tmpsql rc=0
  db_tenant_prepare_backup_dir || return 1
  file="$(db_tenant_backup_path mysql "$db" sql.gz)"
  tmpsql="$(mktemp)"
  local cnf; cnf="$(mktemp)"; mysql_write_admin_cnf "$cnf"
  if [[ "${MYSQL_TARGET_MODE:-local}" == "docker" ]]; then
    local incnf="/tmp/.db-tenant-dump-$$.cnf"
    docker cp "$cnf" "${DB_TENANT_MYSQL_CONTAINER}:${incnf}" >/dev/null
    docker exec "${DB_TENANT_MYSQL_CONTAINER}" mysqldump --defaults-extra-file="${incnf}" \
      --single-transaction --routines --triggers --events --databases "$db" >"$tmpsql" || rc=$?
    docker exec "${DB_TENANT_MYSQL_CONTAINER}" rm -f "${incnf}" >/dev/null 2>&1 || true
  else
    mysqldump --defaults-extra-file="$cnf" --socket="${DB_TENANT_MYSQL_SOCKET}" \
      --single-transaction --routines --triggers --events --databases "$db" >"$tmpsql" || rc=$?
  fi
  rm -f "$cnf"
  if (( rc != 0 )); then rm -f "$tmpsql"; return 1; fi
  ( umask 077; gzip -c "$tmpsql" >"$file" ) || { rm -f "$tmpsql" "$file"; return 1; }
  rm -f "$tmpsql"
  if ! db_tenant_verify_backup mysql "$file"; then rm -f "$file"; return 1; fi
  chmod 600 "$file"
  MYSQL_BACKUP_FILE="$file"
  echo "已备份: $file ($(du -h "$file" 2>/dev/null | awk '{print $1}'))"
  return 0
}

# 删除编排(精确 user@host)
mysql_drop_tenant() {
  local user="$1" host="$2" db="$3"
  db_tenant_validate_identifier "$user" 32 || return 1
  db_tenant_validate_host "$host" || return 1
  db_tenant_validate_identifier "$db" || return 1
  mysql_assert_writable || return 1
  mysql_guard_not_system "$user" "$db" || return 1
  if ! mysql_backup_tenant "$db"; then echo "备份失败,已中止删除。" >&2; return 1; fi
  echo "将删除: 数据库 \`$db\` + 账号 '$user'@'$host'"
  local typed; typed="$(prompt_with_default "确认删除请重新输入租户名" "")"
  if [[ "$typed" != "$user" ]]; then echo "名称不匹配,已取消。" >&2; return 1; fi
  if mysql_build_drop_sql "$user" "$host" "$db" "$(mysql_db_exists "$db")" "$(mysql_user_exists "$user" "$host")" | mysql_exec_sql; then
    echo "已删除租户: $user@$host / $db (备份: ${MYSQL_BACKUP_FILE:-N/A})"
  else
    echo "DROP 执行失败(备份已生成: ${MYSQL_BACKUP_FILE:-N/A});请检查后重试。" >&2
    return 1
  fi
}

mysql_current_user_muc() {
  local v; v="$(mysql_query "SELECT max_user_connections FROM mysql.user WHERE user='${1}' AND host='${2}';")"
  [[ -n "$v" ]] && echo "$v" || echo "${DB_TENANT_MYSQL_MAX_USER_CONN}"
}

mysql_create_tenant() {
  local user="${1:-}"
  if [[ -z "$user" ]]; then user="$(prompt_with_default "租户名(=用户名)" "")"; fi
  db_tenant_validate_identifier "$user" 32 || return 1
  local db; db="$(prompt_with_default "数据库名" "$user")"; db_tenant_validate_identifier "$db" || return 1
  local host; host="$(prompt_with_default "允许来源 host" "${DB_TENANT_MYSQL_DEFAULT_HOST}")"
  db_tenant_validate_host "$host" || return 1
  mysql_assert_writable || return 1

  local uexist; uexist="$(mysql_user_exists "$user" "$host")"
  local def_muc="${DB_TENANT_MYSQL_MAX_USER_CONN}"
  if [[ "$uexist" == "1" ]]; then def_muc="$(mysql_current_user_muc "$user" "$host")"; echo "该账号已存在,现值回填(回车保持不变)。"; fi
  local muc mcph mqph muph pw escpw
  muc="$(prompt_with_default "并发连接上限" "$def_muc")"
  mcph="$(prompt_with_default "每小时新建连接(0=不限)" "${DB_TENANT_MYSQL_MAX_CONN_PER_HOUR}")"
  mqph="$(prompt_with_default "每小时查询数(0=不限)" "${DB_TENANT_MYSQL_MAX_QUERIES_PER_HOUR}")"
  muph="$(prompt_with_default "每小时更新数(0=不限)" "${DB_TENANT_MYSQL_MAX_UPDATES_PER_HOUR}")"
  if [[ "$uexist" == "1" ]]; then pw=""; escpw=""; else pw="$(db_tenant_generate_password)"; escpw="$(db_tenant_sql_escape_literal mysql "$pw")"; fi

  if mysql_build_create_tenant_sql "$user" "$host" "$db" "$escpw" "$muc" "$mcph" "$mqph" "$muph" "$uexist" | mysql_exec_sql; then
    echo "== 租户就绪(MySQL) =="
    echo "库: $db  账号: '$user'@'$host'"
    [[ -n "$pw" ]] && echo "密码(仅显示一次): $pw"
    echo "连接示例: mysql -h <host> -u $user -p $db"
  else
    echo "创建失败,请检查上面的错误。" >&2
    return 1
  fi
}

# 列出非系统账号及其限额(仅账号+限额;不展示绑定库)
mysql_list_tenants() { mysql_build_list_sql "${DB_TENANT_MYSQL_SYSTEM_USERS}" | mysql_exec_sql; }

mysql_set_limit() {
  local user; user="$(prompt_with_default "租户名(用户)" "")"; db_tenant_validate_identifier "$user" 32 || return 1
  local host; host="$(prompt_with_default "host" "${DB_TENANT_MYSQL_DEFAULT_HOST}")"; db_tenant_validate_host "$host" || return 1
  mysql_assert_writable || return 1
  local cur; cur="$(mysql_current_user_muc "$user" "$host")"
  local muc mcph mqph muph
  muc="$(prompt_with_default "并发连接上限" "$cur")"
  mcph="$(prompt_with_default "每小时新建连接" "${DB_TENANT_MYSQL_MAX_CONN_PER_HOUR}")"
  mqph="$(prompt_with_default "每小时查询数" "${DB_TENANT_MYSQL_MAX_QUERIES_PER_HOUR}")"
  muph="$(prompt_with_default "每小时更新数" "${DB_TENANT_MYSQL_MAX_UPDATES_PER_HOUR}")"
  if mysql_build_set_limit_sql "$user" "$host" "$muc" "$mcph" "$mqph" "$muph" | mysql_exec_sql; then
    echo "已更新限额: '$user'@'$host'"
  else
    echo "更新限额失败。" >&2; return 1
  fi
}

mysql_set_password() {
  local user; user="$(prompt_with_default "租户名(用户)" "")"; db_tenant_validate_identifier "$user" 32 || return 1
  local host; host="$(prompt_with_default "host" "${DB_TENANT_MYSQL_DEFAULT_HOST}")"; db_tenant_validate_host "$host" || return 1
  mysql_assert_writable || return 1
  local pw escpw; pw="$(db_tenant_generate_password)"; escpw="$(db_tenant_sql_escape_literal mysql "$pw")"
  if mysql_build_set_password_sql "$user" "$host" "$escpw" | mysql_exec_sql; then
    echo "新密码(仅显示一次): $pw"
  else
    echo "改密码失败。" >&2; return 1
  fi
}
