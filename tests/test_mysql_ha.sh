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
  ( unset DATA_ROOT MYSQL_HA_DATADIR MYSQL_HA_ORCH_DATADIR
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
  ( unset MYSQL_HA_DATADIR MYSQL_HA_ORCH_DATADIR
    export DATA_ROOT="/opt/x" MYSQL_HA_PROXY_PORT="7000"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"
    assert_equals "/opt/x" "${DATA_ROOT}"
    assert_equals "7000" "${MYSQL_HA_PROXY_PORT}"
    assert_equals "/opt/x/mysql-ha/data" "${MYSQL_HA_DATADIR}"
    assert_equals "/opt/x/mysql-ha/orchestrator" "${MYSQL_HA_ORCH_DATADIR}"
  )
}

run_skeleton_tests() {
  local entry="${ROOT_DIR}/install-mysql-ha.sh"
  assert_file_exists "$entry"
  [[ -x "$entry" ]] || fail "expected install-mysql-ha.sh to be executable"
  bash -n "$entry" || fail "install-mysql-ha.sh has syntax errors"
  assert_contains "$entry" "lib/mysql-ha/main.sh"
  assert_contains "$entry" "lib/common.sh"
  assert_not_contains "$entry" "lib/config.sh"

  local module
  while IFS= read -r module; do
    bash -n "$module" || fail "module has syntax errors: $module"
  done < <(find "${ROOT_DIR}/lib/mysql-ha" -name '*.sh' -type f | sort)

  load_mysql_ha
  local fn
  for fn in mysql_ha_parse_role mysql_ha_validate_node_ips write_my_cnf \
            write_orchestrator_config write_mysqlchk_script write_watcher_script \
            write_haproxy_config mysql_ha_main; do
    assert_function_exists "$fn"
  done
}

run_common_tests() {
  load_mysql_ha

  mysql_ha_parse_role "1"; assert_equals "primary" "${MYSQL_HA_ROLE}"
  mysql_ha_parse_role "primary"; assert_equals "primary" "${MYSQL_HA_ROLE}"
  mysql_ha_parse_role "2"; assert_equals "replica" "${MYSQL_HA_ROLE}"
  mysql_ha_parse_role "replica"; assert_equals "replica" "${MYSQL_HA_ROLE}"
  mysql_ha_parse_role "3"; assert_equals "arbiter" "${MYSQL_HA_ROLE}"
  mysql_ha_parse_role "arbiter"; assert_equals "arbiter" "${MYSQL_HA_ROLE}"
  if mysql_ha_parse_role "bogus" 2>/dev/null; then fail "expected bogus role to fail"; fi

  ( export MYSQL_HA_NODE1_IP="10.0.0.1" MYSQL_HA_NODE2_IP="10.0.0.2" MYSQL_HA_NODE3_IP="10.0.0.3"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/common.sh"
    mysql_ha_validate_node_ips || fail "expected valid IPs to pass" )
  ( export MYSQL_HA_NODE1_IP="10.0.0.1" MYSQL_HA_NODE2_IP="" MYSQL_HA_NODE3_IP="10.0.0.3"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/common.sh"
    if mysql_ha_validate_node_ips 2>/dev/null; then fail "expected empty IP to fail"; fi )
  ( export MYSQL_HA_NODE1_IP="not-an-ip" MYSQL_HA_NODE2_IP="10.0.0.2" MYSQL_HA_NODE3_IP="10.0.0.3"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/common.sh"
    if mysql_ha_validate_node_ips 2>/dev/null; then fail "expected invalid IP to fail"; fi )

  local pw
  pw="$(mysql_ha_generate_password)"
  [[ ${#pw} -ge 16 ]] || fail "expected generated password length >= 16"
  # 密码仅字母数字(避免 JSON/SQL/cnf 转义)
  [[ "$pw" =~ ^[A-Za-z0-9]+$ ]] || fail "generated password must be alphanumeric only: $pw"
}

run_precheck_tests() {
  load_mysql_ha
  assert_function_exists mysql_ha_check_connectivity
  assert_function_exists mysql_ha_check_time_sync
  assert_function_exists mysql_ha_preflight_connectivity
  assert_function_exists mysql_ha_wait_raft_quorum

  # raft quorum 等待:mock curl 返回 healthy 立即成功
  ( source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/common.sh"
    export MYSQL_HA_ORCH_HTTP_PASSWORD=x MYSQL_HA_ORCH_PORT=3000
    curl() { echo '{"Healthy":true}'; }
    mysql_ha_wait_raft_quorum || fail "expected raft quorum wait to succeed when healthy" )
}

run_mysql_cnf_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export MYSQL_HA_NODE_IP="10.0.0.1"
  export MYSQL_HA_DATADIR="${temp_root}/data"
  export MYSQL_HA_MYCNF="${temp_root}/zz-mysql-ha.cnf"
  export MYSQL_HA_SEMISYNC="off"
  load_mysql_ha

  # primary, 异步
  write_my_cnf "1" "primary"
  assert_file_exists "${MYSQL_HA_MYCNF}"
  assert_contains "${MYSQL_HA_MYCNF}" "server_id=1"
  assert_contains "${MYSQL_HA_MYCNF}" "gtid_mode=ON"
  assert_contains "${MYSQL_HA_MYCNF}" "enforce_gtid_consistency=ON"
  assert_contains "${MYSQL_HA_MYCNF}" "log_replica_updates=ON"
  assert_contains "${MYSQL_HA_MYCNF}" "super_read_only=ON"
  assert_contains "${MYSQL_HA_MYCNF}" "binlog_expire_logs_seconds=604800"
  assert_contains "${MYSQL_HA_MYCNF}" "datadir=${temp_root}/data"
  assert_contains "${MYSQL_HA_MYCNF}" "bind-address=10.0.0.1"
  assert_not_contains "${MYSQL_HA_MYCNF}" "rpl_semi_sync"
  assert_mode "${MYSQL_HA_MYCNF}" "644"

  # replica server_id=2
  write_my_cnf "2" "replica"
  assert_contains "${MYSQL_HA_MYCNF}" "server_id=2"

  # 半同步 on + primary
  ( export MYSQL_HA_SEMISYNC="on" MYSQL_HA_MYCNF="${temp_root}/semi-src.cnf" MYSQL_HA_NODE_IP=10.0.0.1
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/mysql.sh"
    write_my_cnf "1" "primary"
    assert_contains "${temp_root}/semi-src.cnf" "plugin_load_add=semisync_source.so"
    assert_contains "${temp_root}/semi-src.cnf" "rpl_semi_sync_source_enabled=1"
    assert_contains "${temp_root}/semi-src.cnf" "rpl_semi_sync_source_wait_for_replica_count=1" )

  # 半同步 on + replica
  ( export MYSQL_HA_SEMISYNC="on" MYSQL_HA_MYCNF="${temp_root}/semi-rep.cnf" MYSQL_HA_NODE_IP=10.0.0.2
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/mysql.sh"
    write_my_cnf "2" "replica"
    assert_contains "${temp_root}/semi-rep.cnf" "plugin_load_add=semisync_replica.so"
    assert_contains "${temp_root}/semi-rep.cnf" "rpl_semi_sync_replica_enabled=1" )

  assert_function_exists add_mysql_repo
  assert_function_exists install_mysql
  assert_function_exists apply_apparmor_datadir
  assert_function_exists relocate_datadir
  assert_function_exists start_mysql
  assert_function_exists bootstrap_mysql_accounts
  assert_function_exists setup_replication
}

run_orchestrator_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export MYSQL_HA_NODE1_IP="10.0.0.1" MYSQL_HA_NODE2_IP="10.0.0.2" MYSQL_HA_NODE3_IP="10.0.0.3"
  export MYSQL_HA_ORCH_CONF="${temp_root}/orchestrator.conf.json"
  export MYSQL_HA_ORCH_DATADIR="${temp_root}/orch"
  export MYSQL_HA_ORCH_PASSWORD="orchpw" MYSQL_HA_ORCH_HTTP_PASSWORD="httppw"
  load_mysql_ha

  write_orchestrator_config "10.0.0.1"
  assert_file_exists "${MYSQL_HA_ORCH_CONF}"
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"BackendDB\": \"sqlite\""
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"RaftEnabled\": true"
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"RaftBind\": \"10.0.0.1\""
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"ListenAddress\": \"10.0.0.1:3000\""
  assert_contains "${MYSQL_HA_ORCH_CONF}" "10.0.0.3"
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"AuthenticationMethod\": \"basic\""
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"HTTPAuthPassword\": \"httppw\""
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"ApplyMySQLPromotionAfterMasterFailover\": true"
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"FailMasterPromotionIfSQLThreadNotUpToDate\": true"
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"ReasonableReplicationLagSeconds\": 60"
  assert_mode "${MYSQL_HA_ORCH_CONF}" "600"
  # JSON 合法性(无 python3 则跳过)
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "${MYSQL_HA_ORCH_CONF}" >/dev/null || fail "orchestrator.conf.json is not valid JSON"
  fi

  assert_function_exists write_orchestrator_client_cnf
  assert_function_exists write_orchestrator_unit
  assert_function_exists install_orchestrator
  assert_function_exists start_orchestrator
  assert_function_exists orchestrator_discover
}

run_mysqlchk_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export MYSQL_HA_NODE_IP="10.0.0.1"
  export MYSQL_HA_MYSQLCHK_SCRIPT="${temp_root}/mysqlchk"
  export MYSQL_HA_MYSQLCHK_SOCKET="${temp_root}/mysqlchk.socket"
  export MYSQL_HA_MYSQLCHK_SERVICE="${temp_root}/mysqlchk@.service"
  export MYSQL_HA_MYSQLCHK_CNF="${temp_root}/mysqlchk.cnf"
  export MYSQL_HA_MYSQLCHK_PASSWORD="chkpw"
  load_mysql_ha

  write_mysqlchk_script
  assert_file_exists "${MYSQL_HA_MYSQLCHK_SCRIPT}"
  assert_contains "${MYSQL_HA_MYSQLCHK_SCRIPT}" "@@global.read_only"
  assert_contains "${MYSQL_HA_MYSQLCHK_SCRIPT}" "HTTP/1.1 200 OK"
  assert_contains "${MYSQL_HA_MYSQLCHK_SCRIPT}" "HTTP/1.1 503 Service Unavailable"
  assert_contains "${MYSQL_HA_MYSQLCHK_SCRIPT}" "Content-Length"
  # 必须用 printf 输出 CRLF,不用 echo
  assert_contains "${MYSQL_HA_MYSQLCHK_SCRIPT}" 'printf'
  grep -q $'\\\\r\\\\n' "${MYSQL_HA_MYSQLCHK_SCRIPT}" || fail "mysqlchk must emit CRLF (\\r\\n)"

  write_mysqlchk_cnf
  assert_contains "${MYSQL_HA_MYSQLCHK_CNF}" "user=mysqlchk"
  assert_contains "${MYSQL_HA_MYSQLCHK_CNF}" "password=chkpw"
  assert_mode "${MYSQL_HA_MYSQLCHK_CNF}" "600"

  write_mysqlchk_socket_unit
  assert_contains "${MYSQL_HA_MYSQLCHK_SOCKET}" "ListenStream=10.0.0.1:9200"
  assert_contains "${MYSQL_HA_MYSQLCHK_SOCKET}" "Accept=yes"

  write_mysqlchk_service_unit
  assert_contains "${MYSQL_HA_MYSQLCHK_SERVICE}" "StandardInput=socket"
  assert_contains "${MYSQL_HA_MYSQLCHK_SERVICE}" "StandardOutput=socket"
  assert_contains "${MYSQL_HA_MYSQLCHK_SERVICE}" "ExecStart=${temp_root}/mysqlchk"

  assert_function_exists setup_mysqlchk
  assert_function_exists start_mysqlchk
}

run_watcher_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export MYSQL_HA_NODE_IP="10.0.0.1" MYSQL_HA_CLUSTER_NAME="mysql-ha"
  export MYSQL_HA_WATCHER_SCRIPT="${temp_root}/mysql-ha-watcher"
  export MYSQL_HA_WATCHER_UNIT="${temp_root}/mysql-ha-watcher.service"
  export MYSQL_HA_WATCHER_CNF="${temp_root}/watcher.cnf"
  export MYSQL_HA_WATCHER_PASSWORD="watchpw" MYSQL_HA_ORCH_HTTP_PASSWORD="httppw"
  load_mysql_ha

  write_watcher_script
  assert_file_exists "${MYSQL_HA_WATCHER_SCRIPT}"
  # 三分支:失多数票自我隔离 / 本机是主→可写 / 别人是主→只读
  assert_contains "${MYSQL_HA_WATCHER_SCRIPT}" "super_read_only=ON"
  assert_contains "${MYSQL_HA_WATCHER_SCRIPT}" "read_only=OFF"
  assert_contains "${MYSQL_HA_WATCHER_SCRIPT}" "raft-health"
  assert_contains "${MYSQL_HA_WATCHER_SCRIPT}" "api/master"

  write_watcher_cnf
  assert_contains "${MYSQL_HA_WATCHER_CNF}" "user=watcher"
  assert_contains "${MYSQL_HA_WATCHER_CNF}" "password=watchpw"
  assert_contains "${MYSQL_HA_WATCHER_CNF}" "http_password = httppw"
  assert_mode "${MYSQL_HA_WATCHER_CNF}" "600"

  write_watcher_unit
  assert_contains "${MYSQL_HA_WATCHER_UNIT}" "Restart=always"
  assert_contains "${MYSQL_HA_WATCHER_UNIT}" "ExecStart=${temp_root}/mysql-ha-watcher"

  assert_function_exists setup_watcher
  assert_function_exists start_watcher
}

main() {
  local suite="${1:-all}"
  case "$suite" in
    config) run_config_tests ;;
    skeleton) run_skeleton_tests ;;
    common) run_common_tests ;;
    precheck) run_precheck_tests ;;
    mysqlcnf) run_mysql_cnf_tests ;;
    orchestrator) run_orchestrator_tests ;;
    mysqlchk) run_mysqlchk_tests ;;
    watcher) run_watcher_tests ;;
    all) run_skeleton_tests; run_config_tests; run_common_tests; run_precheck_tests; run_mysql_cnf_tests; run_orchestrator_tests; run_mysqlchk_tests; run_watcher_tests ;;
    *) fail "unknown suite: $suite" ;;
  esac
  echo "PASS: ${suite}"
}

main "$@"
