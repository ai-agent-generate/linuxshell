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
