#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || fail "expected file to exist: $path"
}
assert_function_exists() {
  local fn_name="$1"
  declare -F "$fn_name" >/dev/null || fail "expected function to exist: $fn_name"
}
assert_contains() {
  local path="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$path" || fail "expected '$expected' in $path"
}
assert_not_contains() {
  local path="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$path"; then fail "did not expect '$unexpected' in $path"; fi
}
assert_equals() {
  local expected="$1"
  local actual="$2"
  [[ "$expected" == "$actual" ]] || fail "expected '$expected' but got '$actual'"
}

# 按依赖顺序加载 PG-HA 全部模块(Task 2+ 占位模块就绪后由各 suite 调用)。
# 注意:lib/common.sh 是全局公共库,lib/pg-ha/common.sh 是 PG-HA 专用函数。
load_pg_ha() {
  # shellcheck disable=SC1090,SC1091
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/pg-ha/config.sh"
  source "${ROOT_DIR}/lib/pg-ha/common.sh"
  source "${ROOT_DIR}/lib/pg-ha/etcd.sh"
  source "${ROOT_DIR}/lib/pg-ha/patroni.sh"
  source "${ROOT_DIR}/lib/pg-ha/haproxy.sh"
  source "${ROOT_DIR}/lib/pg-ha/main.sh"
}

run_config_tests() {
  ( unset DATA_ROOT
    source "${ROOT_DIR}/lib/pg-ha/config.sh"
    assert_equals "/data" "${DATA_ROOT}"
    assert_equals "18" "${PG_HA_MAJOR_VERSION}"
    assert_equals "pg-ha" "${PG_HA_CLUSTER_NAME}"
    assert_equals "5000" "${PG_HA_PROXY_PORT}"
    assert_equals "30" "${PG_HA_TTL}"
    assert_equals "10" "${PG_HA_LOOP_WAIT}"
    assert_equals "10" "${PG_HA_RETRY_TIMEOUT}"
    # DCS 时序硬约束:loop_wait + 2*retry_timeout <= ttl
    [[ $(( PG_HA_LOOP_WAIT + 2 * PG_HA_RETRY_TIMEOUT )) -le "${PG_HA_TTL}" ]] \
      || fail "DCS timing constraint violated"
    assert_equals "" "${PG_HA_SUPERUSER_PASSWORD}"
    assert_equals "" "${PG_HA_ETCD_PASSWORD}"
    assert_equals "" "${PG_HA_APP_ALLOWED_CIDR}"
  )
  ( export DATA_ROOT="/opt/x" PG_HA_MAJOR_VERSION="17" PG_HA_PROXY_PORT="6000"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"
    assert_equals "/opt/x" "${DATA_ROOT}"
    assert_equals "17" "${PG_HA_MAJOR_VERSION}"
    assert_equals "6000" "${PG_HA_PROXY_PORT}"
    assert_equals "/opt/x/patroni/pgdata" "${PG_HA_PGDATA}"
  )
}

main() {
  local suite="${1:-all}"
  case "$suite" in
    config) run_config_tests ;;
    all) run_config_tests ;;
    *) fail "unknown suite: $suite" ;;
  esac
  echo "PASS: ${suite}"
}

main "$@"
