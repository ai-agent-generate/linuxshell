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

# 准备备份目录(700)并做磁盘可用空间预检
db_tenant_prepare_backup_dir() {
  local dir="${DB_TENANT_BACKUP_DIR}" min_mb="${DB_TENANT_BACKUP_MIN_FREE_MB}"
  mkdir -p "$dir" || { echo "无法创建备份目录: $dir" >&2; return 1; }
  chmod 700 "$dir"
  local free_mb
  free_mb="$(df -Pm "$dir" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -n "$free_mb" ]] && (( free_mb < min_mb )); then
    echo "备份目录可用空间不足: ${free_mb}MB < ${min_mb}MB ($dir)" >&2
    return 1
  fi
  return 0
}

# 备份文件路径(时间戳+PID,防同秒覆盖)。$1=engine $2=db $3=ext
# 注意:$2(db) 须由调用方先经 db_tenant_validate_identifier 校验。
db_tenant_backup_path() {
  printf '%s/%s-%s-%s-%s.%s' \
    "${DB_TENANT_BACKUP_DIR}" "$1" "$2" "$(date +%Y%m%d-%H%M%S)" "$$" "$3"
}

# 备份完整性校验。$1=pg|mysql $2=file -> 0 完整
db_tenant_verify_backup() {
  local engine="$1" file="$2"
  if [[ ! -s "$file" ]]; then echo "备份文件为空: $file" >&2; return 1; fi
  if [[ "$engine" == "pg" ]]; then
    pg_restore -l "$file" >/dev/null 2>&1 || { echo "pg_restore 校验失败: $file" >&2; return 1; }
  else
    gzip -t "$file" >/dev/null 2>&1 || { echo "gzip 校验失败: $file" >&2; return 1; }
    if ! gzip -dc "$file" 2>/dev/null | tail -n 5 | grep -q 'Dump completed'; then
      echo "未发现 mysqldump 完成标记: $file" >&2; return 1
    fi
  fi
  return 0
}

# 写操作串行化锁(flock 不可用时降级直跑)。用法: db_tenant_with_lock <cmd...>
# 锁与备份目录同处;子shell 退出时自动释放锁并关闭 fd 9。
db_tenant_with_lock() {
  if ! command_exists flock; then "$@"; return $?; fi
  mkdir -p "${DB_TENANT_BACKUP_DIR}"
  chmod 700 "${DB_TENANT_BACKUP_DIR}" 2>/dev/null || true
  local lock="${DB_TENANT_BACKUP_DIR}/.db-tenant.lock"
  (
    flock -n 9 || { echo "另一个 db-tenant 操作正在进行,请稍后重试。" >&2; exit 1; }
    "$@"
  ) 9>"$lock"
}
