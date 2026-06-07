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

load_status_common() {
  # shellcheck disable=SC1090,SC1091
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/status-common.sh"
}

# 按依赖顺序加载 MySQL-HA 模块(测试前先 export MYSQL_HA_* 覆盖路径)
load_mysql_ha() {
  # shellcheck disable=SC1090,SC1091
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/status-common.sh"
  source "${ROOT_DIR}/lib/mysql-ha/config.sh"
  source "${ROOT_DIR}/lib/mysql-ha/common.sh"
  source "${ROOT_DIR}/lib/mysql-ha/mysql.sh"
  source "${ROOT_DIR}/lib/mysql-ha/repman.sh"
  source "${ROOT_DIR}/lib/mysql-ha/mysqlchk.sh"
  source "${ROOT_DIR}/lib/mysql-ha/haproxy.sh"
  source "${ROOT_DIR}/lib/mysql-ha/main.sh"
  source "${ROOT_DIR}/lib/mysql-ha/status.sh"
}

run_mysql_status_tests() {
  local tdir; tdir="$(mktemp -d)"; trap "rm -rf '$tdir'" RETURN
  load_mysql_ha

  # 拓扑:arbiter 从 config.toml db-servers-hosts 解析数据节点 IP
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    export MYSQL_HA_REPMAN_CONF="${tdir}/config.toml"
    printf 'db-servers-hosts = "10.0.0.1:3306,10.0.0.2:3306"\n' >"${MYSQL_HA_REPMAN_CONF}"
    mysql_ha_status_load_topology
    assert_equals "10.0.0.1" "${MYSQL_HA_NODE1_IP}"
    assert_equals "10.0.0.2" "${MYSQL_HA_NODE2_IP}" )

  # 角色:有 zz-mysql-ha.cnf + read_only=0 -> primary
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    export MYSQL_HA_MYCNF="${tdir}/zz.cnf"; : >"${MYSQL_HA_MYCNF}"
    mysql_ha_status_local_sql() { echo "0"; }
    mysql_ha_status_detect_role; assert_equals "primary" "${MYSQL_HA_DETECTED_ROLE}" )
  # read_only=1 -> replica
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    export MYSQL_HA_MYCNF="${tdir}/zz.cnf"; : >"${MYSQL_HA_MYCNF}"
    mysql_ha_status_local_sql() { echo "1"; }
    mysql_ha_status_detect_role; assert_equals "replica" "${MYSQL_HA_DETECTED_ROLE}" )
  # 无 cnf、有 config.toml -> arbiter
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    export MYSQL_HA_MYCNF="${tdir}/none.cnf" MYSQL_HA_REPMAN_CONF="${tdir}/config.toml"
    mysql_ha_status_detect_role; assert_equals "arbiter" "${MYSQL_HA_DETECTED_ROLE}" )

  # 服务:failed -> CRIT
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    status_reset; systemctl() { return 1; }
    mysql_ha_status_service_one mysql
    assert_equals "1" "${STATUS_CRIT_COUNT}" )

  assert_function_exists mysql_ha_status_identity
  assert_function_exists mysql_ha_status_services

  # 复制:从库 IO 线程断 -> CRIT
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    MYSQL_HA_DETECTED_ROLE=replica
    mysql_ha_status_local_sql() { printf 'Replica_IO_Running: No\nReplica_SQL_Running: Yes\nSeconds_Behind_Source: 0\n'; }
    status_reset; mysql_ha_status_replication
    assert_equals "1" "${STATUS_CRIT_COUNT}" )
  # 复制:延迟超 WARN 线 -> WARN
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    MYSQL_HA_DETECTED_ROLE=replica
    mysql_ha_status_local_sql() { printf 'Replica_IO_Running: Yes\nReplica_SQL_Running: Yes\nSeconds_Behind_Source: 60\n'; }
    status_reset; mysql_ha_status_replication
    assert_equals "1" "${STATUS_WARN_COUNT}"; assert_equals "0" "${STATUS_CRIT_COUNT}" )

  # 静默退化:半同步 OFF -> WARN
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    export MYSQL_HA_SEMISYNC=on; MYSQL_HA_DETECTED_ROLE=primary
    mysql_ha_status_local_sql() { case "$1" in *source_status*) echo "Rpl_semi_sync_source_status	OFF" ;; *source_clients*) echo "Rpl_semi_sync_source_clients	0" ;; *) echo "" ;; esac; }
    status_reset; mysql_ha_status_degradation
    assert_equals "1" "${STATUS_WARN_COUNT}" )
  # 静默退化:从库 read_only=0(僵尸主) -> CRIT
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    MYSQL_HA_DETECTED_ROLE=replica
    mysql_ha_status_local_sql() { case "$1" in *REPLICA\ STATUS*) printf 'Replica_IO_Running: Yes\nReplica_SQL_Running: Yes\n' ;; *read_only*) echo 0 ;; esac; }
    status_reset; mysql_ha_status_degradation
    assert_equals "1" "${STATUS_CRIT_COUNT}" )

  # 防脑裂:两节点 mysqlchk 都 200 -> 多主 CRIT
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    MYSQL_HA_DETECTED_ROLE=primary
    export MYSQL_HA_NODE1_IP=10.0.0.1 MYSQL_HA_NODE2_IP=10.0.0.2
    curl() { echo 200; }
    status_reset; mysql_ha_status_splitbrain
    assert_equals "1" "${STATUS_CRIT_COUNT}" )
  # 防脑裂:arbiter 上 repman 未运行 -> CRIT
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    MYSQL_HA_DETECTED_ROLE=arbiter
    systemctl() { return 1; }
    status_reset; mysql_ha_status_splitbrain
    assert_equals "1" "${STATUS_CRIT_COUNT}" )

  assert_function_exists mysql_ha_status_topology
  assert_function_exists mysql_ha_status_ingress

  # 磁盘:超 CRIT 线 -> CRIT
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    MYSQL_HA_DETECTED_ROLE=primary; export MYSQL_HA_DATADIR="${tdir}"
    df() { printf 'F 1K Used Avail Use%% M\n/dev/x 100 95 5 95%% /\n'; }
    status_reset; mysql_ha_status_disk
    assert_equals "1" "${STATUS_CRIT_COUNT}" )

  # 连接数:超 WARN 线 -> WARN
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    MYSQL_HA_DETECTED_ROLE=primary
    mysql_ha_status_local_sql() { case "$1" in *Threads_connected*) echo "Threads_connected	85" ;; *max_connections*) echo "max_connections	100" ;; esac; }
    status_reset; mysql_ha_status_load
    assert_equals "1" "${STATUS_WARN_COUNT}" )

  # 编排:注入 CRIT -> 退出码 2
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/mysql-ha/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/status.sh"
    mysql_ha_status_load_topology() { :; }
    mysql_ha_status_detect_role() { MYSQL_HA_DETECTED_ROLE=primary; }
    mysql_ha_status_identity() { :; }; mysql_ha_status_services() { :; }; mysql_ha_status_topology() { :; }
    mysql_ha_status_replication() { :; }; mysql_ha_status_degradation() { :; }; mysql_ha_status_ingress() { :; }
    mysql_ha_status_splitbrain() { status_crit "injected"; }
    mysql_ha_status_disk() { :; }; mysql_ha_status_clock() { :; }; mysql_ha_status_logs() { :; }
    mysql_ha_status_config_audit() { :; }; mysql_ha_status_load() { :; }
    local rc=0; mysql_ha_status_main >/dev/null || rc=$?
    assert_equals "2" "$rc" )

  assert_function_exists mysql_ha_status_clock
  assert_function_exists mysql_ha_status_config_audit
}

run_status_skeleton_tests() {
  local entry="${ROOT_DIR}/status-mysql-ha.sh"
  assert_file_exists "$entry"
  [[ -x "$entry" ]] || fail "expected status-mysql-ha.sh to be executable"
  bash -n "$entry" || fail "status-mysql-ha.sh has syntax errors"
  assert_contains "$entry" "lib/common.sh"
  assert_contains "$entry" "lib/status-common.sh"
  assert_contains "$entry" "lib/mysql-ha/status.sh"
  assert_contains "$entry" "mysql_ha_status_main"
  assert_contains "$entry" "require_root"
  bash -n "${ROOT_DIR}/lib/status-common.sh" || fail "status-common.sh syntax error"
  bash -n "${ROOT_DIR}/lib/mysql-ha/status.sh" || fail "mysql-ha/status.sh syntax error"
}

run_status_readonly_tests() {
  local f files="${ROOT_DIR}/lib/status-common.sh ${ROOT_DIR}/lib/mysql-ha/status.sh ${ROOT_DIR}/status-mysql-ha.sh"
  _no() { if grep -nE "$2" "$1" >/dev/null 2>&1; then grep -nE "$2" "$1" >&2; fail "$3 in $1"; fi; }
  for f in $files; do
    [[ -e "$f" ]] || continue
    _no "$f" 'systemctl[[:space:]]+(start|stop|restart|reload|enable|disable|mask|kill)' "service-control write"
    _no "$f" 'etcdctl[^|]*(put|del|txn|user |role |auth |move-leader|snapshot|defrag)' "etcdctl write subcommand"
    _no "$f" '(INSERT |UPDATE |DELETE |DROP |ALTER |CREATE |GRANT |REVOKE |TRUNCATE |SET +GLOBAL|FLUSH |RESET |STOP +REPLICA|START +REPLICA|CHANGE +REPLICATION)' "SQL write"
    _no "$f" 'curl[^|]*(-X +(POST|PUT|DELETE|PATCH)|--request)' "HTTP write"
    _no "$f" 'curl[^|]*(-u |--user )' "plaintext curl credential"
    _no "$f" 'mysql[^|]*[[:space:]]-p[^[:space:]]' "plaintext mysql password"
    _no "$f" '>[[:space:]]*/(etc|data|var|usr|run)/' "write to system path"
  done
  assert_contains "${ROOT_DIR}/lib/status-common.sh" "curl -K"
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
    assert_equals "10005" "${MYSQL_HA_REPMAN_API_PORT}"
    assert_equals "v3.1.28" "${MYSQL_HA_REPMAN_VERSION}"
    assert_equals "/usr/bin/replication-manager-osc" "${MYSQL_HA_REPMAN_BIN}"
    assert_equals "on" "${MYSQL_HA_SEMISYNC}"
    assert_equals "" "${MYSQL_HA_APP_ALLOWED_CIDR}"
    assert_equals "/data/mysql-ha/data" "${MYSQL_HA_DATADIR}"
  )
  ( unset MYSQL_HA_DATADIR MYSQL_HA_REPMAN_DATADIR
    export DATA_ROOT="/opt/x" MYSQL_HA_PROXY_PORT="7000"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"
    assert_equals "/opt/x" "${DATA_ROOT}"
    assert_equals "7000" "${MYSQL_HA_PROXY_PORT}"
    assert_equals "/opt/x/mysql-ha/data" "${MYSQL_HA_DATADIR}"
    assert_equals "/opt/x/mysql-ha/replication-manager" "${MYSQL_HA_REPMAN_DATADIR}"
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
  assert_contains "$entry" "lib/mysql-ha/repman.sh"
  assert_not_contains "$entry" "lib/mysql-ha/orchestrator.sh"
  assert_not_contains "$entry" "lib/mysql-ha/watcher.sh"
  [[ ! -e "${ROOT_DIR}/lib/mysql-ha/orchestrator.sh" ]] || fail "orchestrator module should not exist in Replication Manager mode"
  [[ ! -e "${ROOT_DIR}/lib/mysql-ha/watcher.sh" ]] || fail "watcher module should not exist in Replication Manager mode"

  local module
  while IFS= read -r module; do
    bash -n "$module" || fail "module has syntax errors: $module"
  done < <(find "${ROOT_DIR}/lib/mysql-ha" -name '*.sh' -type f | sort)

  load_mysql_ha
  local fn
  for fn in mysql_ha_parse_role mysql_ha_validate_node_ips write_my_cnf \
            write_repman_config write_mysqlchk_script \
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

  ( export MYSQL_HA_NODE_IP="10.0.0.3" MYSQL_HA_REPMAN_API_PORT="10006"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/common.sh"
    assert_function_exists mysql_ha_repman_api_url
    assert_equals "http://10.0.0.3:10006" "$(mysql_ha_repman_api_url)" )

  assert_function_exists mysql_ha_validate_mysql_version
  mysql_ha_validate_mysql_version || fail "expected default MySQL version to be supported"
  ( export MYSQL_HA_VERSION="8.0"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/common.sh"
    if mysql_ha_validate_mysql_version 2>/dev/null; then fail "expected MySQL 8.0 to be rejected for this 8.4 HA mode"; fi )
}

run_precheck_tests() {
  load_mysql_ha
  assert_function_exists mysql_ha_check_connectivity
  assert_function_exists mysql_ha_check_time_sync
  assert_function_exists mysql_ha_preflight_connectivity
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
  assert_contains "${MYSQL_HA_MYCNF}" "report_host=10.0.0.1"
  assert_contains "${MYSQL_HA_MYCNF}" "report_port=3306"
  assert_contains "${MYSQL_HA_MYCNF}" "skip_name_resolve=ON"
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
    assert_contains "${temp_root}/semi-src.cnf" "plugin_load_add=semisync_replica.so"
    assert_contains "${temp_root}/semi-src.cnf" "rpl_semi_sync_source_enabled=1"
    assert_contains "${temp_root}/semi-src.cnf" "rpl_semi_sync_replica_enabled=1"
    assert_contains "${temp_root}/semi-src.cnf" "rpl_semi_sync_source_wait_for_replica_count=1" )

  # 半同步 on + replica
  ( export MYSQL_HA_SEMISYNC="on" MYSQL_HA_MYCNF="${temp_root}/semi-rep.cnf" MYSQL_HA_NODE_IP=10.0.0.2
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/mysql.sh"
    write_my_cnf "2" "replica"
    assert_contains "${temp_root}/semi-rep.cnf" "plugin_load_add=semisync_source.so"
    assert_contains "${temp_root}/semi-rep.cnf" "plugin_load_add=semisync_replica.so"
    assert_contains "${temp_root}/semi-rep.cnf" "rpl_semi_sync_source_enabled=1"
    assert_contains "${temp_root}/semi-rep.cnf" "rpl_semi_sync_replica_enabled=1" )

  assert_function_exists add_mysql_repo
  assert_contains "${ROOT_DIR}/lib/mysql-ha/mysql.sh" "RPM-GPG-KEY-mysql-2025"
  assert_function_exists mysql_ha_mysql_repo_component
  assert_equals "mysql-8.4-lts" "$(mysql_ha_mysql_repo_component)"
  assert_function_exists mysql_ha_mysql_installed_matches_target
  ( export MYSQL_HA_VERSION="8.4"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/mysql.sh"
    mysqld() { echo "/usr/sbin/mysqld  Ver 8.4.9 for Linux on x86_64"; }
    mysql_ha_mysql_installed_matches_target || fail "expected installed MySQL 8.4 to match target" )
  ( export MYSQL_HA_VERSION="8.4"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/mysql.sh"
    mysqld() { echo "/usr/sbin/mysqld  Ver 8.0.46 for Linux on x86_64"; }
    if mysql_ha_mysql_installed_matches_target; then fail "expected installed MySQL 8.0 to mismatch target 8.4"; fi )
  assert_function_exists install_mysql
  assert_function_exists apply_apparmor_datadir
  assert_function_exists relocate_datadir
  ( export MYSQL_HA_DATADIR="${temp_root}/existing-datadir"
    local action_log="${temp_root}/relocate-existing.log"
    mkdir -p "${MYSQL_HA_DATADIR}"
    touch "${MYSQL_HA_DATADIR}/auto.cnf"
    : >"${action_log}"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/mysql.sh"
    systemctl() { echo "systemctl $*" >>"${action_log}"; }
    rsync() { echo "rsync $*" >>"${action_log}"; }
    chown() { echo "chown $*" >>"${action_log}"; }
    chmod() { echo "chmod $*" >>"${action_log}"; }
    apply_apparmor_datadir() { echo "apparmor" >>"${action_log}"; }
    relocate_datadir
    assert_not_contains "${action_log}" "rsync"
    assert_not_contains "${action_log}" "systemctl stop mysql"
    assert_contains "${action_log}" "apparmor" )
  ( export MYSQL_HA_DATADIR="${temp_root}/non-empty-not-mysql"
    local action_log="${temp_root}/relocate-non-empty.log"
    mkdir -p "${MYSQL_HA_DATADIR}"
    touch "${MYSQL_HA_DATADIR}/stray-file"
    : >"${action_log}"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/mysql.sh"
    systemctl() { echo "systemctl $*" >>"${action_log}"; }
    rsync() { echo "rsync $*" >>"${action_log}"; }
    if relocate_datadir 2>/dev/null; then fail "expected relocate_datadir to reject non-empty non-MySQL datadir"; fi
    assert_not_contains "${action_log}" "rsync"
    assert_not_contains "${action_log}" "systemctl stop mysql" )
  assert_function_exists start_mysql
  assert_function_exists bootstrap_mysql_accounts
  assert_contains "${ROOT_DIR}/lib/mysql-ha/mysql.sh" "SUPER, REPLICATION CLIENT"
  assert_contains "${ROOT_DIR}/lib/mysql-ha/mysql.sh" "SOURCE_SSL=1"
  assert_function_exists setup_replication
}

run_repman_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export MYSQL_HA_NODE1_IP="10.0.0.1" MYSQL_HA_NODE2_IP="10.0.0.2" MYSQL_HA_NODE3_IP="10.0.0.3"
  export MYSQL_HA_REPMAN_CONF="${temp_root}/config.toml"
  export MYSQL_HA_REPMAN_UNIT="${temp_root}/replication-manager.service"
  export MYSQL_HA_REPMAN_DATADIR="${temp_root}/repman"
  export MYSQL_HA_REPMAN_USER="repman" MYSQL_HA_REPMAN_PASSWORD="repmanpw"
  export MYSQL_HA_REPMAN_API_USER="admin" MYSQL_HA_REPMAN_API_PASSWORD="apipw"
  export MYSQL_HA_REPL_PASSWORD="replpw"
  export MYSQL_HA_SEMISYNC="on"
  load_mysql_ha

  write_repman_config
  assert_file_exists "${MYSQL_HA_REPMAN_CONF}"
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "[Default]"
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "monitoring-datadir = \"${temp_root}/repman\""
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "api-port = \"10005\""
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "api-credentials = \"admin:apipw\""
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "opensvc = false"
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "[mysql-ha]"
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "db-servers-hosts = \"10.0.0.1:3306,10.0.0.2:3306\""
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "db-servers-prefered-master = \"10.0.0.1:3306\""
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "db-servers-credential = \"repman:repmanpw\""
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "replication-credential = \"repl:replpw\""
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "replication-use-ssl = true"
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "failover-mode = \"automatic\""
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "failover-readonly-state = true"
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "failover-superreadonly-state = true"
  assert_contains "${MYSQL_HA_REPMAN_CONF}" "failover-at-sync = true"
  assert_mode "${MYSQL_HA_REPMAN_CONF}" "600"

  assert_function_exists write_repman_unit
  assert_function_exists install_repman
  assert_contains "${ROOT_DIR}/lib/mysql-ha/repman.sh" "repo.signal18.io/deb"
  assert_contains "${ROOT_DIR}/lib/mysql-ha/repman.sh" "replication-manager-osc="
  assert_contains "${ROOT_DIR}/lib/mysql-ha/repman.sh" "--force-confold"
  assert_function_exists start_repman

  local fake_bin="${temp_root}/bin"
  mkdir -p "$fake_bin"
  printf '#!/usr/bin/env sh\nexit 0\n' >"${fake_bin}/replication-manager"
  chmod 755 "${fake_bin}/replication-manager"
  MYSQL_HA_REPMAN_BIN="${fake_bin}/replication-manager" PATH="${fake_bin}:$PATH" write_repman_unit
  assert_file_exists "${temp_root}/replication-manager.service"
  assert_contains "${temp_root}/replication-manager.service" "ExecStart=${fake_bin}/replication-manager --config ${temp_root}/config.toml monitor"
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
  assert_contains "${MYSQL_HA_MYSQLCHK_SCRIPT}" "read -r -t"
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

run_haproxy_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export MYSQL_HA_NODE1_IP="10.0.0.1" MYSQL_HA_NODE2_IP="10.0.0.2"
  export MYSQL_HA_HAPROXY_CFG="${temp_root}/haproxy.cfg"
  export MYSQL_HA_STATS_PASSWORD="statspw"
  load_mysql_ha

  write_haproxy_config
  assert_file_exists "${MYSQL_HA_HAPROXY_CFG}"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "bind *:6446"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "mode tcp"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "option httpchk"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "http-check send meth GET uri /"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "http-check expect status 200"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "on-marked-down shutdown-sessions"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "server node1 10.0.0.1:3306 check port 9200"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "server node2 10.0.0.2:3306 check port 9200"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "stats auth admin:statspw"
  assert_mode "${MYSQL_HA_HAPROXY_CFG}" "600"

  assert_function_exists install_haproxy
  assert_function_exists start_haproxy
}

run_docs_tests() {
  local readme="${ROOT_DIR}/README.md"
  assert_contains "$readme" "install-mysql-ha.sh"
  assert_contains "$readme" "Replication Manager"
  assert_contains "$readme" "MYSQL_HA_NODE1_IP"
  assert_contains "$readme" "MYSQL_HA_REPMAN_PASSWORD"
  assert_contains "$readme" "status-mysql-ha.sh"
  assert_contains "$readme" "ha-status.sh"
}

run_orchestration_tests() {
  local temp_root action_log
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN
  action_log="${temp_root}/actions.log"

  export MYSQL_HA_NODE1_IP="10.0.0.1" MYSQL_HA_NODE2_IP="10.0.0.2" MYSQL_HA_NODE3_IP="10.0.0.3"
  export MYSQL_HA_REPMAN_PASSWORD=x MYSQL_HA_REPMAN_API_PASSWORD=x
  export MYSQL_HA_ROOT_PASSWORD=x MYSQL_HA_REPL_PASSWORD=x MYSQL_HA_MYSQLCHK_PASSWORD=x
  export MYSQL_HA_APP_PASSWORD=x MYSQL_HA_STATS_PASSWORD=x
  export MYSQL_HA_APP_ALLOWED_CIDR="10.0.0.0/24"
  load_mysql_ha

  # mock 所有副作用函数
  require_root() { :; }
  detect_os() { :; }
  mysql_ha_check_time_sync() { :; }
  mysql_ha_preflight_connectivity() { :; }
  install_mysql() { echo install_mysql >>"$action_log"; }
  relocate_datadir() { echo relocate_datadir >>"$action_log"; }
  write_my_cnf() { echo "write_my_cnf $1 $2" >>"$action_log"; }
  start_mysql() { echo start_mysql >>"$action_log"; }
  bootstrap_mysql_accounts() { echo bootstrap_mysql_accounts >>"$action_log"; }
  setup_replication() { echo setup_replication >>"$action_log"; }
  install_repman() { echo install_repman >>"$action_log"; }
  write_repman_config() { echo write_repman_config >>"$action_log"; }
  write_repman_unit() { echo write_repman_unit >>"$action_log"; }
  start_repman() { echo start_repman >>"$action_log"; }
  setup_mysqlchk() { echo setup_mysqlchk >>"$action_log"; }
  start_mysqlchk() { echo start_mysqlchk >>"$action_log"; }
  install_haproxy() { echo install_haproxy >>"$action_log"; }
  start_haproxy() { echo start_haproxy >>"$action_log"; }
  mysql_ha_show_summary() { echo summary >>"$action_log"; }

  # arbiter:仅 Replication Manager
  : >"$action_log"
  mysql_ha_collect_config() { MYSQL_HA_ROLE=arbiter; MYSQL_HA_NODE_NAME=node3; MYSQL_HA_NODE_IP=10.0.0.3; MYSQL_HA_SERVER_ID=0; }
  mysql_ha_main
  assert_contains "$action_log" "install_repman"
  assert_contains "$action_log" "write_repman_config"
  assert_contains "$action_log" "start_repman"
  assert_not_contains "$action_log" "install_mysql"
  assert_not_contains "$action_log" "install_haproxy"

  # primary:mysql + 建账号 + mysqlchk + haproxy;不配复制
  : >"$action_log"
  mysql_ha_collect_config() { MYSQL_HA_ROLE=primary; MYSQL_HA_NODE_NAME=node1; MYSQL_HA_NODE_IP=10.0.0.1; MYSQL_HA_SERVER_ID=1; }
  mysql_ha_main
  assert_contains "$action_log" "install_mysql"
  assert_contains "$action_log" "write_my_cnf 1 primary"
  assert_contains "$action_log" "bootstrap_mysql_accounts"
  assert_contains "$action_log" "setup_mysqlchk"
  assert_contains "$action_log" "start_haproxy"
  assert_not_contains "$action_log" "install_repman"
  assert_not_contains "$action_log" "setup_replication"

  # replica:mysql + 配复制 + mysqlchk + haproxy;不建账号
  : >"$action_log"
  mysql_ha_collect_config() { MYSQL_HA_ROLE=replica; MYSQL_HA_NODE_NAME=node2; MYSQL_HA_NODE_IP=10.0.0.2; MYSQL_HA_SERVER_ID=2; }
  mysql_ha_main
  assert_contains "$action_log" "write_my_cnf 2 replica"
  assert_contains "$action_log" "setup_replication"
  assert_contains "$action_log" "setup_mysqlchk"
  assert_contains "$action_log" "start_haproxy"
  assert_not_contains "$action_log" "install_repman"
  assert_not_contains "$action_log" "bootstrap_mysql_accounts"
}

main() {
  local suite="${1:-all}"
  case "$suite" in
    mysql_status) run_mysql_status_tests ;;
    status_skeleton) run_status_skeleton_tests ;;
    status_readonly) run_status_readonly_tests ;;
    config) run_config_tests ;;
    skeleton) run_skeleton_tests ;;
    common) run_common_tests ;;
    precheck) run_precheck_tests ;;
    mysqlcnf) run_mysql_cnf_tests ;;
    repman) run_repman_tests ;;
    mysqlchk) run_mysqlchk_tests ;;
    haproxy) run_haproxy_tests ;;
    orchestration) run_orchestration_tests ;;
    docs) run_docs_tests ;;
    all) run_mysql_status_tests; run_skeleton_tests; run_status_skeleton_tests; run_status_readonly_tests; run_config_tests; run_common_tests; run_precheck_tests; run_mysql_cnf_tests; run_repman_tests; run_mysqlchk_tests; run_haproxy_tests; run_orchestration_tests; run_docs_tests ;;
    *) fail "unknown suite: $suite" ;;
  esac
  echo "PASS: ${suite}"
}

main "$@"
