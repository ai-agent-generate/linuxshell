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

run_common_tests() {
  load_pg_ha

  pg_ha_parse_role "1"; assert_equals "primary" "${PG_HA_ROLE}"
  pg_ha_parse_role "primary"; assert_equals "primary" "${PG_HA_ROLE}"
  pg_ha_parse_role "2"; assert_equals "replica" "${PG_HA_ROLE}"
  pg_ha_parse_role "replica"; assert_equals "replica" "${PG_HA_ROLE}"
  pg_ha_parse_role "3"; assert_equals "quorum" "${PG_HA_ROLE}"
  pg_ha_parse_role "quorum"; assert_equals "quorum" "${PG_HA_ROLE}"
  if pg_ha_parse_role "bogus" 2>/dev/null; then fail "expected bogus role to fail"; fi

  ( export PG_HA_NODE1_IP="10.0.0.1" PG_HA_NODE2_IP="10.0.0.2" PG_HA_NODE3_IP="10.0.0.3"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    pg_ha_validate_node_ips || fail "expected valid IPs to pass" )
  ( export PG_HA_NODE1_IP="10.0.0.1" PG_HA_NODE2_IP="" PG_HA_NODE3_IP="10.0.0.3"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    if pg_ha_validate_node_ips 2>/dev/null; then fail "expected empty IP to fail"; fi )
  ( export PG_HA_NODE1_IP="not-an-ip" PG_HA_NODE2_IP="10.0.0.2" PG_HA_NODE3_IP="10.0.0.3"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    if pg_ha_validate_node_ips 2>/dev/null; then fail "expected invalid IP to fail"; fi )

  local pw
  pw="$(pg_ha_generate_password)"
  [[ ${#pw} -ge 16 ]] || fail "expected generated password length >= 16"
}

run_precheck_tests() {
  load_pg_ha

  # watchdog: off 时直接通过
  ( export PG_HA_WATCHDOG="off"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    pg_ha_check_watchdog || fail "expected watchdog off to pass" )

  # quorum 等待:mock etcdctl 成功立即返回 0
  ( source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    export PG_HA_NODE1_IP=10.0.0.1 PG_HA_NODE2_IP=10.0.0.2 PG_HA_NODE3_IP=10.0.0.3
    etcdctl() { return 0; }
    pg_ha_wait_etcd_quorum || fail "expected quorum wait to succeed when etcdctl healthy" )

  assert_function_exists pg_ha_check_connectivity
  assert_function_exists pg_ha_check_time_sync
}

run_skeleton_tests() {
  local entry="${ROOT_DIR}/install-pg-ha.sh"
  assert_file_exists "$entry"
  [[ -x "$entry" ]] || fail "expected install-pg-ha.sh to be executable"
  bash -n "$entry" || fail "install-pg-ha.sh has syntax errors"
  assert_contains "$entry" "lib/pg-ha/main.sh"
  assert_contains "$entry" "lib/common.sh"
  assert_not_contains "$entry" "lib/config.sh"

  local module
  while IFS= read -r module; do
    bash -n "$module" || fail "module has syntax errors: $module"
  done < <(find "${ROOT_DIR}/lib/pg-ha" -name '*.sh' -type f | sort)

  # 在子 shell 中加载模块并检查函数,避免污染上层 shell 的 PG_HA_* 变量
  (
    load_pg_ha
    for fn in pg_ha_parse_role pg_ha_validate_node_ips write_etcd_config \
              write_patroni_yaml write_haproxy_config pg_ha_main; do
      assert_function_exists "$fn"
    done
  )
}

main() {
  local suite="${1:-all}"
  case "$suite" in
    config) run_config_tests ;;
    skeleton) run_skeleton_tests ;;
    common) run_common_tests ;;
    precheck) run_precheck_tests ;;
    all) run_skeleton_tests; run_config_tests; run_common_tests; run_precheck_tests ;;
    *) fail "unknown suite: $suite" ;;
  esac
  echo "PASS: ${suite}"
}

main "$@"
