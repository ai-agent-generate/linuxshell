#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file_exists() { [[ -f "$1" ]] || fail "expected file: $1"; }
assert_function_exists() { declare -F "$1" >/dev/null || fail "expected function: $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_not_contains() { if grep -Fq -- "$2" "$1"; then fail "did not expect '$2' in $1"; fi; }
assert_str_contains() { case "$1" in *"$2"*) :;; *) fail "expected substring '$2' in: $1";; esac; }
assert_str_missing() { case "$1" in *"$2"*) fail "did not expect substring '$2' in: $1";; *) :;; esac; }
assert_equals() { [[ "$1" == "$2" ]] || fail "expected '$1' but got '$2'"; }
assert_mode() {
  local m; m="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null)"
  [[ "$m" == "$2" ]] || fail "expected mode $2 on $1 but got $m"
}

load_db_tenant() {
  # shellcheck disable=SC1090,SC1091
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/db-tenant/config.sh"
  source "${ROOT_DIR}/lib/db-tenant/common.sh"
  source "${ROOT_DIR}/lib/db-tenant/pg.sh"
  source "${ROOT_DIR}/lib/db-tenant/mysql.sh"
  source "${ROOT_DIR}/lib/db-tenant/main.sh"
}

run_skeleton_tests() {
  local entry="${ROOT_DIR}/db-tenant.sh"
  assert_file_exists "$entry"
  [[ -x "$entry" ]] || fail "expected db-tenant.sh executable"
  [[ -x "${ROOT_DIR}/tests/test_db_tenant.sh" ]] || fail "expected tests/test_db_tenant.sh executable"
  bash -n "$entry" || fail "db-tenant.sh syntax error"
  assert_contains "$entry" "lib/common.sh"
  assert_contains "$entry" "lib/db-tenant/config.sh"
  assert_contains "$entry" "lib/db-tenant/common.sh"
  assert_contains "$entry" "lib/db-tenant/pg.sh"
  assert_contains "$entry" "lib/db-tenant/mysql.sh"
  assert_contains "$entry" "lib/db-tenant/main.sh"
  assert_not_contains "$entry" "lib/config.sh"
  local m
  while IFS= read -r m; do bash -n "$m" || fail "syntax error: $m"; done \
    < <(find "${ROOT_DIR}/lib/db-tenant" -name '*.sh' -type f | sort)
  load_db_tenant
}

run_config_tests() {
  ( unset DATA_ROOT DB_TENANT_BACKUP_DIR DB_TENANT_PG_CONN_LIMIT DB_TENANT_PG_IDLE_TX_TIMEOUT
    source "${ROOT_DIR}/lib/db-tenant/config.sh"
    assert_equals "postgres" "${DB_TENANT_PG_CONTAINER}"
    assert_equals "mysql" "${DB_TENANT_MYSQL_CONTAINER}"
    assert_equals "/var/backups/db-tenant" "${DB_TENANT_BACKUP_DIR}"
    assert_equals "20" "${DB_TENANT_PG_CONN_LIMIT}"
    assert_equals "30s" "${DB_TENANT_PG_STATEMENT_TIMEOUT}"
    assert_equals "300s" "${DB_TENANT_PG_IDLE_TX_TIMEOUT}"
    assert_equals "20" "${DB_TENANT_MYSQL_MAX_USER_CONN}"
    assert_equals "0" "${DB_TENANT_MYSQL_MAX_QUERIES_PER_HOUR}"
    assert_equals "%" "${DB_TENANT_MYSQL_DEFAULT_HOST}"
    assert_str_contains "${DB_TENANT_MYSQL_SYSTEM_DATABASES}" "replication_manager_schema" )
  ( export DB_TENANT_BACKUP_DIR="/opt/bk" DB_TENANT_PG_CONN_LIMIT="99"
    source "${ROOT_DIR}/lib/db-tenant/config.sh"
    assert_equals "/opt/bk" "${DB_TENANT_BACKUP_DIR}"
    assert_equals "99" "${DB_TENANT_PG_CONN_LIMIT}" )
}

run_common_tests() {
  load_db_tenant
  assert_function_exists db_tenant_validate_identifier
  assert_function_exists db_tenant_is_system_name
  assert_function_exists db_tenant_generate_password
  assert_function_exists db_tenant_sql_escape_literal

  db_tenant_validate_identifier "acme" || fail "acme should be valid"
  db_tenant_validate_identifier "acme_1" || fail "acme_1 should be valid"
  if db_tenant_validate_identifier "1abc" 2>/dev/null; then fail "1abc must be rejected"; fi
  if db_tenant_validate_identifier "a-b" 2>/dev/null; then fail "a-b must be rejected"; fi
  if db_tenant_validate_identifier "a;b" 2>/dev/null; then fail "a;b must be rejected"; fi
  if db_tenant_validate_identifier "a'b" 2>/dev/null; then fail "quote must be rejected"; fi
  if db_tenant_validate_identifier "" 2>/dev/null; then fail "empty must be rejected"; fi

  db_tenant_is_system_name "postgres" "${DB_TENANT_PG_SYSTEM_NAMES}" || fail "postgres is system"
  db_tenant_is_system_name "mysql.session" "${DB_TENANT_MYSQL_SYSTEM_USERS}" || fail "mysql.session is system"
  db_tenant_is_system_name "debian-sys-maint" "${DB_TENANT_MYSQL_SYSTEM_USERS}" || fail "debian-sys-maint is system"
  db_tenant_is_system_name "repman" "${DB_TENANT_MYSQL_SYSTEM_USERS}" || fail "repman is system"
  db_tenant_is_system_name "replication_manager_schema" "${DB_TENANT_MYSQL_SYSTEM_DATABASES}" || fail "rms is system db"
  if db_tenant_is_system_name "acme" "${DB_TENANT_PG_SYSTEM_NAMES}"; then fail "acme is not system"; fi

  local pw; pw="$(db_tenant_generate_password)"
  [[ "$pw" =~ ^[A-Za-z0-9]+$ ]] || fail "password must be alphanumeric: $pw"
  assert_equals "25" "${#pw}"

  assert_equals "a''b" "$(db_tenant_sql_escape_literal pg "a'b")"
  assert_equals "a\\\\''b" "$(db_tenant_sql_escape_literal mysql "a\\'b")"
}

run_backup_helper_tests() {
  load_db_tenant
  assert_function_exists db_tenant_prepare_backup_dir
  assert_function_exists db_tenant_backup_path
  assert_function_exists db_tenant_verify_backup
  assert_function_exists db_tenant_with_lock

  local tmp; tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" RETURN

  ( export DB_TENANT_BACKUP_DIR="${tmp}/bk" DB_TENANT_BACKUP_MIN_FREE_MB="1"
    source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/db-tenant/common.sh"
    db_tenant_prepare_backup_dir || fail "prepare should succeed"
    assert_mode "${tmp}/bk" "700"
    local p; p="$(db_tenant_backup_path pg acme dump)"
    assert_str_contains "$p" "${tmp}/bk/pg-acme-"
    assert_str_contains "$p" ".dump" )

  ( export DB_TENANT_BACKUP_DIR="${tmp}/bk2" DB_TENANT_BACKUP_MIN_FREE_MB="999999999"
    source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/db-tenant/common.sh"
    if db_tenant_prepare_backup_dir 2>/dev/null; then fail "should fail on insufficient space"; fi )

  : >"${tmp}/empty.dump"
  if db_tenant_verify_backup pg "${tmp}/empty.dump" 2>/dev/null; then fail "empty file must fail verify"; fi

  printf 'not gzip' >"${tmp}/bad.sql.gz"
  if db_tenant_verify_backup mysql "${tmp}/bad.sql.gz" 2>/dev/null; then fail "bad gzip must fail"; fi
  printf '%s\n' "-- dummy" "-- Dump completed on 2026-06-07" | gzip >"${tmp}/ok.sql.gz"
  db_tenant_verify_backup mysql "${tmp}/ok.sql.gz" || fail "valid mysql backup must pass"

  ( source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/db-tenant/common.sh"
    printf 'x' >"${tmp}/a.dump"
    pg_restore() { return 0; }
    db_tenant_verify_backup pg "${tmp}/a.dump" || fail "pg verify should pass when pg_restore ok"
    pg_restore() { return 1; }
    if db_tenant_verify_backup pg "${tmp}/a.dump" 2>/dev/null; then fail "pg verify should fail when pg_restore fails"; fi )

  # flock 持锁路径(桩 flock 视为存在):退出码透传 + 抢锁失败则不执行命令
  ( export DB_TENANT_BACKUP_DIR="${tmp}/lk"
    source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/db-tenant/common.sh"
    command_exists() { return 0; }            # 视为 flock 存在
    flock() { return 0; }                     # 抢锁成功
    db_tenant_with_lock true || fail "lock: success cmd should return 0"
    if db_tenant_with_lock false; then fail "lock: exit code must propagate (false)"; fi
    ran="${tmp}/ran.flag"; : >"$ran"
    flock() { return 1; }                     # 抢锁失败
    spy() { echo ran >>"$ran"; }
    if db_tenant_with_lock spy 2>/dev/null; then fail "lock: must return non-zero when flock fails"; fi
    [[ ! -s "$ran" ]] || fail "lock: command must NOT run when lock not acquired" )
}

main() {
  local suite="${1:-all}"
  case "$suite" in
    skeleton) run_skeleton_tests ;;
    config) run_config_tests ;;
    common) run_common_tests ;;
    backup_helper) run_backup_helper_tests ;;
    all) run_skeleton_tests; run_config_tests; run_common_tests; run_backup_helper_tests ;;
    *) fail "unknown suite: $suite" ;;
  esac
  echo "PASS: ${suite}"
}

main "$@"
