#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file_exists() { [[ -f "$1" ]] || fail "expected file to exist: $1"; }
assert_function_exists() { declare -F "$1" >/dev/null || fail "expected function: $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_not_contains() { if grep -Fq -- "$2" "$1"; then fail "did not expect '$2' in $1"; fi; }
assert_equals() { [[ "$1" == "$2" ]] || fail "expected '$1' but got '$2'"; }
assert_mode() { # $1=file $2=expected octal(e.g. 600)
  local m; m="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null)"
  [[ "$m" == "$2" ]] || fail "expected mode $2 on $1 but got $m"
}

# 按依赖顺序加载 MySQL-HA 模块(测试前先 export MYSQL_HA_* 覆盖路径)
load_mysql_ha() {
  # shellcheck disable=SC1090,SC1091
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/mysql-ha/config.sh"
  source "${ROOT_DIR}/lib/mysql-ha/common.sh"
  source "${ROOT_DIR}/lib/mysql-ha/mysql.sh"
  source "${ROOT_DIR}/lib/mysql-ha/orchestrator.sh"
  source "${ROOT_DIR}/lib/mysql-ha/mysqlchk.sh"
  source "${ROOT_DIR}/lib/mysql-ha/watcher.sh"
  source "${ROOT_DIR}/lib/mysql-ha/haproxy.sh"
  source "${ROOT_DIR}/lib/mysql-ha/main.sh"
}

run_config_tests() {
  ( unset DATA_ROOT
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"
    assert_equals "/data" "${DATA_ROOT}"
    assert_equals "8.4" "${MYSQL_HA_VERSION}"
    assert_equals "mysql-ha" "${MYSQL_HA_CLUSTER_NAME}"
    assert_equals "3306" "${MYSQL_HA_MYSQL_PORT}"
    assert_equals "6446" "${MYSQL_HA_PROXY_PORT}"
    assert_equals "9200" "${MYSQL_HA_MYSQLCHK_PORT}"
    assert_equals "3000" "${MYSQL_HA_ORCH_PORT}"
    assert_equals "10008" "${MYSQL_HA_ORCH_RAFT_PORT}"
    assert_equals "off" "${MYSQL_HA_SEMISYNC}"
    assert_equals "" "${MYSQL_HA_APP_ALLOWED_CIDR}"
    assert_equals "/data/mysql-ha/data" "${MYSQL_HA_DATADIR}"
  )
  ( export DATA_ROOT="/opt/x" MYSQL_HA_VERSION="8.4" MYSQL_HA_PROXY_PORT="7000"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"
    assert_equals "/opt/x" "${DATA_ROOT}"
    assert_equals "7000" "${MYSQL_HA_PROXY_PORT}"
    assert_equals "/opt/x/mysql-ha/data" "${MYSQL_HA_DATADIR}"
    assert_equals "/opt/x/mysql-ha/orchestrator" "${MYSQL_HA_ORCH_DATADIR}"
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
