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

run_etcd_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export PG_HA_NODE1_IP="10.0.0.1" PG_HA_NODE2_IP="10.0.0.2" PG_HA_NODE3_IP="10.0.0.3"
  export PG_HA_ETCD_DATA="${temp_root}/etcd"
  export PG_HA_ETCD_CONFIG_FILE="${temp_root}/etcd.conf.yml"
  export PG_HA_ETCD_UNIT_DROPIN="${temp_root}/dropin/override.conf"
  load_pg_ha

  write_etcd_config "node1" "10.0.0.1"
  assert_file_exists "${temp_root}/etcd.conf.yml"
  assert_contains "${temp_root}/etcd.conf.yml" "name: node1"
  assert_contains "${temp_root}/etcd.conf.yml" "initial-cluster: node1=http://10.0.0.1:2380,node2=http://10.0.0.2:2380,node3=http://10.0.0.3:2380"
  assert_contains "${temp_root}/etcd.conf.yml" "initial-cluster-state: new"
  assert_contains "${temp_root}/etcd.conf.yml" "initial-cluster-token: pg-ha"
  assert_contains "${temp_root}/etcd.conf.yml" "listen-client-urls: http://10.0.0.1:2379,http://127.0.0.1:2379"

  write_etcd_unit_dropin
  assert_file_exists "${temp_root}/dropin/override.conf"
  assert_contains "${temp_root}/dropin/override.conf" "ExecStart="
  assert_contains "${temp_root}/dropin/override.conf" "--config-file=${temp_root}/etcd.conf.yml"

  assert_function_exists install_etcd
  assert_function_exists start_etcd
  assert_function_exists enable_etcd_rbac
  assert_function_exists etcd_health_check
}

run_patroni_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export PG_HA_NODE1_IP="10.0.0.1" PG_HA_NODE2_IP="10.0.0.2" PG_HA_NODE3_IP="10.0.0.3"
  export PG_HA_PGDATA="${temp_root}/pgdata"
  export PG_HA_PATRONI_YAML="${temp_root}/patroni.yml"
  export PG_HA_ETCD_PASSWORD="etcdpw" PG_HA_REST_PASSWORD="restpw"
  export PG_HA_SUPERUSER_PASSWORD="superpw" PG_HA_REPLICATION_PASSWORD="reppw" PG_HA_REWIND_PASSWORD="rewpw"
  export PG_HA_APP_ALLOWED_CIDR="10.0.0.0/24"
  export PG_HA_WATCHDOG="on" PG_HA_SYNC_MODE="off"
  load_pg_ha

  write_patroni_yaml "node1" "10.0.0.1"
  assert_file_exists "${temp_root}/patroni.yml"
  assert_contains "${temp_root}/patroni.yml" "scope: pg-ha"
  assert_contains "${temp_root}/patroni.yml" "name: node1"
  assert_contains "${temp_root}/patroni.yml" "listen: 10.0.0.1:8008"
  assert_contains "${temp_root}/patroni.yml" "etcd3:"
  assert_contains "${temp_root}/patroni.yml" "- 10.0.0.1:2379"
  assert_contains "${temp_root}/patroni.yml" "username: patroni"
  assert_contains "${temp_root}/patroni.yml" "password: etcdpw"
  assert_contains "${temp_root}/patroni.yml" "ttl: 30"
  assert_contains "${temp_root}/patroni.yml" "loop_wait: 10"
  assert_contains "${temp_root}/patroni.yml" "retry_timeout: 10"
  assert_contains "${temp_root}/patroni.yml" "maximum_lag_on_failover: 1048576"
  assert_contains "${temp_root}/patroni.yml" "synchronous_mode: false"
  assert_contains "${temp_root}/patroni.yml" "use_slots: true"
  assert_contains "${temp_root}/patroni.yml" "use_pg_rewind: true"
  assert_contains "${temp_root}/patroni.yml" "max_slot_wal_keep_size: 10GB"
  assert_contains "${temp_root}/patroni.yml" "wal_log_hints:"
  assert_contains "${temp_root}/patroni.yml" "data_dir: ${temp_root}/pgdata"
  assert_contains "${temp_root}/patroni.yml" "bin_dir: /usr/lib/postgresql/18/bin"
  assert_contains "${temp_root}/patroni.yml" "data-checksums"
  assert_contains "${temp_root}/patroni.yml" "host all all 10.0.0.0/24 md5"
  assert_contains "${temp_root}/patroni.yml" "mode: required"
  assert_contains "${temp_root}/patroni.yml" "device: /dev/watchdog"
  assert_contains "${temp_root}/patroni.yml" "username: postgres"
  assert_contains "${temp_root}/patroni.yml" "username: replicator"
  assert_contains "${temp_root}/patroni.yml" "username: rewind_user"
  # DCS 时序硬约束断言(从生成文件解析)
  local ttl lw rt
  ttl="$(grep -E '^\s*ttl:' "${temp_root}/patroni.yml" | head -1 | grep -oE '[0-9]+')"
  lw="$(grep -E '^\s*loop_wait:' "${temp_root}/patroni.yml" | head -1 | grep -oE '[0-9]+')"
  rt="$(grep -E '^\s*retry_timeout:' "${temp_root}/patroni.yml" | head -1 | grep -oE '[0-9]+')"
  [[ $(( lw + 2 * rt )) -le "$ttl" ]] || fail "generated yaml violates loop_wait+2*retry_timeout<=ttl"

  # watchdog off 分支
  ( export PG_HA_WATCHDOG="off" PG_HA_PATRONI_YAML="${temp_root}/patroni-off.yml"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"
    source "${ROOT_DIR}/lib/pg-ha/common.sh"; source "${ROOT_DIR}/lib/pg-ha/patroni.sh"
    export PG_HA_NODE1_IP=10.0.0.1 PG_HA_NODE2_IP=10.0.0.2 PG_HA_NODE3_IP=10.0.0.3
    export PG_HA_ETCD_PASSWORD=x PG_HA_REST_PASSWORD=x PG_HA_SUPERUSER_PASSWORD=x
    export PG_HA_REPLICATION_PASSWORD=x PG_HA_REWIND_PASSWORD=x PG_HA_APP_ALLOWED_CIDR=10.0.0.0/24
    write_patroni_yaml "node1" "10.0.0.1"
    assert_contains "${temp_root}/patroni-off.yml" 'mode: "off"'
    assert_not_contains "${temp_root}/patroni-off.yml" "device: /dev/watchdog" )

  # sync on 分支
  ( export PG_HA_SYNC_MODE="on" PG_HA_PATRONI_YAML="${temp_root}/patroni-sync.yml"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"
    source "${ROOT_DIR}/lib/pg-ha/common.sh"; source "${ROOT_DIR}/lib/pg-ha/patroni.sh"
    export PG_HA_NODE1_IP=10.0.0.1 PG_HA_NODE2_IP=10.0.0.2 PG_HA_NODE3_IP=10.0.0.3
    export PG_HA_ETCD_PASSWORD=x PG_HA_REST_PASSWORD=x PG_HA_SUPERUSER_PASSWORD=x
    export PG_HA_REPLICATION_PASSWORD=x PG_HA_REWIND_PASSWORD=x PG_HA_APP_ALLOWED_CIDR=10.0.0.0/24
    write_patroni_yaml "node1" "10.0.0.1"
    assert_contains "${temp_root}/patroni-sync.yml" "synchronous_mode: true" )

  export PG_HA_PATRONI_UNIT="${temp_root}/patroni.service"
  write_patroni_unit
  assert_file_exists "${temp_root}/patroni.service"
  assert_contains "${temp_root}/patroni.service" "After=network-online.target etcd.service"
  assert_contains "${temp_root}/patroni.service" "User=postgres"
  assert_contains "${temp_root}/patroni.service" "ExecStart=/usr/bin/patroni ${temp_root}/patroni.yml"
  assert_contains "${temp_root}/patroni.service" "KillMode=process"
  assert_contains "${temp_root}/patroni.service" "Restart=no"

  assert_function_exists add_pgdg_repo
  assert_function_exists install_postgres_patroni
  assert_function_exists disable_default_cluster
  assert_function_exists start_patroni
  assert_function_exists bootstrap_patroni
}

run_haproxy_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export PG_HA_NODE1_IP="10.0.0.1" PG_HA_NODE2_IP="10.0.0.2"
  export PG_HA_HAPROXY_CFG="${temp_root}/haproxy.cfg"
  export PG_HA_STATS_PASSWORD="statspw"
  load_pg_ha

  write_haproxy_config
  assert_file_exists "${temp_root}/haproxy.cfg"
  assert_contains "${temp_root}/haproxy.cfg" "bind *:5000"
  assert_contains "${temp_root}/haproxy.cfg" "option httpchk"
  assert_contains "${temp_root}/haproxy.cfg" "http-check send meth GET uri /primary"
  assert_contains "${temp_root}/haproxy.cfg" "http-check expect status 200"
  assert_contains "${temp_root}/haproxy.cfg" "on-marked-down shutdown-sessions"
  assert_contains "${temp_root}/haproxy.cfg" "server node1 10.0.0.1:5432 check port 8008"
  assert_contains "${temp_root}/haproxy.cfg" "server node2 10.0.0.2:5432 check port 8008"
  assert_contains "${temp_root}/haproxy.cfg" "stats auth admin:statspw"
  # 不应出现已弃用的老语法
  assert_not_contains "${temp_root}/haproxy.cfg" "option httpchk GET /primary"

  assert_function_exists install_haproxy
  assert_function_exists start_haproxy
}

run_orchestration_tests() {
  local temp_root action_log
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN
  action_log="${temp_root}/actions.log"

  export PG_HA_NODE1_IP="10.0.0.1" PG_HA_NODE2_IP="10.0.0.2" PG_HA_NODE3_IP="10.0.0.3"
  export PG_HA_ETCD_PASSWORD=x PG_HA_REST_PASSWORD=x PG_HA_SUPERUSER_PASSWORD=x
  export PG_HA_REPLICATION_PASSWORD=x PG_HA_REWIND_PASSWORD=x PG_HA_STATS_PASSWORD=x
  export PG_HA_APP_ALLOWED_CIDR="10.0.0.0/24"
  load_pg_ha

  # mock 所有副作用函数
  require_root() { :; }
  detect_os() { :; }
  install_etcd() { echo install_etcd >>"$action_log"; }
  write_etcd_config() { echo write_etcd_config >>"$action_log"; }
  start_etcd() { echo start_etcd >>"$action_log"; }
  enable_etcd_rbac() { echo enable_etcd_rbac >>"$action_log"; }
  install_postgres_patroni() { echo install_postgres_patroni >>"$action_log"; }
  disable_default_cluster() { echo disable_default_cluster >>"$action_log"; }
  write_patroni_yaml() { echo write_patroni_yaml >>"$action_log"; }
  start_patroni() { echo start_patroni >>"$action_log"; }
  bootstrap_patroni() { echo bootstrap_patroni >>"$action_log"; }
  install_haproxy() { echo install_haproxy >>"$action_log"; }
  start_haproxy() { echo start_haproxy >>"$action_log"; }
  pg_ha_wait_etcd_quorum() { :; }
  pg_ha_check_watchdog() { :; }
  pg_ha_check_time_sync() { :; }
  pg_ha_show_summary() { echo summary >>"$action_log"; }

  # quorum 角色:只装 etcd,不碰 patroni/haproxy
  : >"$action_log"
  pg_ha_collect_config() { PG_HA_ROLE=quorum; PG_HA_NODE_NAME=node3; PG_HA_NODE_IP=10.0.0.3; }
  pg_ha_main
  assert_contains "$action_log" "install_etcd"
  assert_not_contains "$action_log" "install_postgres_patroni"
  assert_not_contains "$action_log" "install_haproxy"

  # primary 角色:etcd + patroni + haproxy + bootstrap
  : >"$action_log"
  pg_ha_collect_config() { PG_HA_ROLE=primary; PG_HA_NODE_NAME=node1; PG_HA_NODE_IP=10.0.0.1; }
  pg_ha_main
  assert_contains "$action_log" "install_etcd"
  assert_contains "$action_log" "install_postgres_patroni"
  assert_contains "$action_log" "bootstrap_patroni"
  assert_contains "$action_log" "install_haproxy"

  # replica 角色:etcd + patroni(start,非 bootstrap) + haproxy
  : >"$action_log"
  pg_ha_collect_config() { PG_HA_ROLE=replica; PG_HA_NODE_NAME=node2; PG_HA_NODE_IP=10.0.0.2; }
  pg_ha_main
  assert_contains "$action_log" "install_postgres_patroni"
  assert_contains "$action_log" "start_patroni"
  assert_not_contains "$action_log" "bootstrap_patroni"
  assert_contains "$action_log" "install_haproxy"
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
    etcd) run_etcd_tests ;;
    patroni) run_patroni_tests ;;
    haproxy) run_haproxy_tests ;;
    orchestration) run_orchestration_tests ;;
    all) run_skeleton_tests; run_config_tests; run_common_tests; run_precheck_tests; run_etcd_tests; run_patroni_tests; run_haproxy_tests; run_orchestration_tests ;;
    *) fail "unknown suite: $suite" ;;
  esac
  echo "PASS: ${suite}"
}

main "$@"
