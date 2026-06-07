#!/usr/bin/env bash
# lib/db-tenant/common.sh — 跨引擎公共函数

# 标识符白名单:小写字母开头,仅 [a-z0-9_],长度 1..max(默认63)
db_tenant_validate_identifier() {
  local name="$1" max="${2:-63}"
  if [[ -z "$name" ]]; then echo "标识符不能为空" >&2; return 1; fi
  if (( ${#name} > max )); then echo "标识符过长(>${max}): $name" >&2; return 1; fi
  if [[ ! "$name" =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "非法标识符(只允许小写字母开头、[a-z0-9_]): $name" >&2; return 1
  fi
  return 0
}

# $1=name $2=空格分隔名单 -> 命中返回0
db_tenant_is_system_name() {
  local name="$1" list="$2" item
  for item in $list; do
    [[ "$name" == "$item" ]] && return 0
  done
  return 1
}

# 25 位纯字母数字密码(规避一切 SQL/cnf 转义),与 mysql_ha_generate_password 同源
db_tenant_generate_password() {
  openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 25
}

# 按引擎转义 SQL 单引号字符串字面量。$1=pg|mysql $2=raw
db_tenant_sql_escape_literal() {
  local engine="$1" raw="$2" sq="'"
  if [[ "$engine" == "mysql" ]]; then
    raw="${raw//\\/\\\\}"
  fi
  raw="${raw//$sq/$sq$sq}"
  printf '%s' "$raw"
}
