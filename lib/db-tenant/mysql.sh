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

# 列出非系统账号及其限额(库映射在编排层用 mysql.db 关联)
mysql_build_list_sql() {
  cat <<'SQL'
SELECT user, host, max_user_connections, max_connections, max_questions, max_updates
FROM mysql.user
ORDER BY user, host;
SQL
}
