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

# 单独加载共享巡检库(依赖 lib/common.sh)
load_status_common() {
  # shellcheck disable=SC1090,SC1091
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/status-common.sh"
}

# 按依赖顺序加载 PG-HA 全部模块(Task 2+ 占位模块就绪后由各 suite 调用)。
# 注意:lib/common.sh 是全局公共库,lib/pg-ha/common.sh 是 PG-HA 专用函数。
load_pg_ha() {
  # shellcheck disable=SC1090,SC1091
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/status-common.sh"
  source "${ROOT_DIR}/lib/pg-ha/config.sh"
  source "${ROOT_DIR}/lib/pg-ha/common.sh"
  source "${ROOT_DIR}/lib/pg-ha/etcd.sh"
  source "${ROOT_DIR}/lib/pg-ha/patroni.sh"
  source "${ROOT_DIR}/lib/pg-ha/haproxy.sh"
  source "${ROOT_DIR}/lib/pg-ha/main.sh"
  source "${ROOT_DIR}/lib/pg-ha/status.sh"
}

run_status_common_tests() {
  load_status_common

  # 退出码: 全 OK -> 0
  ( status_reset
    status_ok "svc a" "active"
    local rc=0; status_final_code || rc=$?
    assert_equals "0" "$rc" )

  # WARN -> 1
  ( status_reset
    status_warn "disk" "85%"
    local rc=0; status_final_code || rc=$?
    assert_equals "1" "$rc" )

  # CRIT 优先于 WARN -> 2
  ( status_reset
    status_warn "disk" "85%"; status_crit "replica down"
    local rc=0; status_final_code || rc=$?
    assert_equals "2" "$rc"
    assert_equals "1" "${STATUS_WARN_COUNT}"
    assert_equals "1" "${STATUS_CRIT_COUNT}" )

  # INFO 不计入
  ( status_reset
    status_info "etcd-quorum 节点跳过 PG 检查"
    local rc=0; status_final_code || rc=$?
    assert_equals "0" "$rc" )

  # NO_COLOR / 非 tty 下输出无 ANSI 转义
  ( export NO_COLOR=1
    source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    local out; out="$(status_ok "x" "y")"
    case "$out" in *$'\033'*) fail "expected no ANSI escape when NO_COLOR set" ;; esac )

  # 默认阈值
  ( unset STATUS_RECHECK_DELAY STATUS_DISK_WARN_PCT STATUS_DISK_CRIT_PCT STATUS_PG_LAG_CRIT_MB STATUS_MYSQL_LAG_WARN_SEC STATUS_LOG_LINES
    source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    assert_equals "3" "${STATUS_RECHECK_DELAY}"
    assert_equals "80" "${STATUS_DISK_WARN_PCT}"
    assert_equals "90" "${STATUS_DISK_CRIT_PCT}"
    assert_equals "512" "${STATUS_PG_LAG_CRIT_MB}"
    assert_equals "30" "${STATUS_MYSQL_LAG_WARN_SEC}"
    assert_equals "20" "${STATUS_LOG_LINES}" )

  # 阈值可覆盖
  ( export STATUS_DISK_WARN_PCT=70 STATUS_LOG_LINES=50
    source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    assert_equals "70" "${STATUS_DISK_WARN_PCT}"
    assert_equals "50" "${STATUS_LOG_LINES}" )

  assert_function_exists status_section
  assert_function_exists status_kv
  assert_function_exists status_summary

  # status_summary 输出包含整体级别与问题列表
  ( status_reset; status_crit "node1 down"; status_warn "disk 90%"
    local out; out="$(status_summary 2>&1)"
    case "$out" in *CRITICAL*) ;; *) fail "expected CRITICAL in summary" ;; esac
    case "$out" in *"node1 down"*) ;; *) fail "expected issue listed in summary" ;; esac )
  # cover 计数
  ( status_reset
    status_cover_seen; status_cover_seen; status_cover_unreachable
    assert_equals "2" "${STATUS_COVER_SEEN}"
    assert_equals "1" "${STATUS_COVER_UNREACH}" )

  local tdir; tdir="$(mktemp -d)"; trap "rm -rf '$tdir'" RETURN

  # status_extract_kv: 从 haproxy.cfg 取 stats 密码(只回显捕获组)
  printf 'listen stats\n    stats auth admin:s3cretPW\n' >"${tdir}/haproxy.cfg"
  local v; v="$(status_extract_kv "${tdir}/haproxy.cfg" 's/.*stats auth admin:\(.*\)/\1/p')"
  assert_equals "s3cretPW" "$v"

  # repman api-credentials 提取必须保留 user
  printf 'api-credentials = "admin:apiPW"\n' >"${tdir}/config.toml"
  local cred; cred="$(status_extract_kv "${tdir}/config.toml" 's/.*api-credentials = "\([^"]*\)".*/\1/p')"
  assert_equals "admin:apiPW" "$cred"

  # status_redact: 密码模式被打码
  local red; red="$(printf 'password=topsecret\n' | status_redact)"
  case "$red" in *topsecret*) fail "status_redact must hide password value" ;; esac

  # status_curl_cred: 凭据写临时文件(-K)，不出现在 curl 命令行参数
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    local seen; seen="$(curl() { printf '%s\n' "$*"; }; status_curl_cred admin apiPW -s http://127.0.0.1:7000/)"
    case "$seen" in *apiPW*) fail "credential leaked into curl args" ;; esac
    case "$seen" in *-K*) : ;; *) fail "expected curl -K config-file usage" ;; esac )

  # status_local_ip: 在 hostname -I 集合中匹配 NODE*_IP
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    hostname() { echo "10.0.0.2 172.17.0.1"; }
    assert_equals "10.0.0.2" "$(status_local_ip 10.0.0.1 10.0.0.2 10.0.0.3)" )

  # ha_status_detect_stack: 用路径变量覆盖伪造存在性(不碰真实 /etc)
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    export PG_HA_PATRONI_YAML="${tdir}/patroni.yml" PG_HA_ETCD_CONFIG_FILE="${tdir}/none-etcd"
    export MYSQL_HA_REPMAN_CONF="${tdir}/none-repman" MYSQL_HA_MYCNF="${tdir}/none-cnf"
    : >"${tdir}/patroni.yml"
    assert_equals "pg" "$(ha_status_detect_stack)" )
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    export PG_HA_PATRONI_YAML="${tdir}/none1" PG_HA_ETCD_CONFIG_FILE="${tdir}/none2"
    export MYSQL_HA_REPMAN_CONF="${tdir}/config.toml" MYSQL_HA_MYCNF="${tdir}/none-cnf"
    assert_equals "mysql" "$(ha_status_detect_stack)" )  # config.toml 已在 Step1 建
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    export PG_HA_PATRONI_YAML="${tdir}/patroni.yml" PG_HA_ETCD_CONFIG_FILE="${tdir}/none2"
    export MYSQL_HA_REPMAN_CONF="${tdir}/config.toml" MYSQL_HA_MYCNF="${tdir}/none-cnf"
    assert_equals "both" "$(ha_status_detect_stack)" )
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    export PG_HA_PATRONI_YAML="${tdir}/none1" PG_HA_ETCD_CONFIG_FILE="${tdir}/none2"
    export MYSQL_HA_REPMAN_CONF="${tdir}/none3" MYSQL_HA_MYCNF="${tdir}/none4"
    assert_equals "none" "$(ha_status_detect_stack)" )

  # status_recheck: 首次正常 -> 0
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    export STATUS_RECHECK_DELAY=0
    probe_ok() { return 0; }
    local rc=0; status_recheck probe_ok || rc=$?
    assert_equals "0" "$rc" )
  # 首次异常、复采恢复 -> 10(瞬态)
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    export STATUS_RECHECK_DELAY=0
    STATE="${tdir}/probe.state"; : >"$STATE"
    probe_flap() { if [[ -s "$STATE" ]]; then return 0; fi; echo x >"$STATE"; return 1; }
    local rc=0; status_recheck probe_flap || rc=$?
    assert_equals "10" "$rc" )
  # 持续异常 -> 1
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    export STATUS_RECHECK_DELAY=0
    probe_bad() { return 1; }
    local rc=0; status_recheck probe_bad || rc=$?
    assert_equals "1" "$rc" )
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
    assert_equals "auto" "${PG_HA_SERVER_TYPE}"
    assert_equals "auto" "${PG_HA_WATCHDOG}"
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

  assert_function_exists pg_ha_setup_watchdog
  assert_function_exists pg_ha_preflight_connectivity
  assert_function_exists pg_ha_resolve_watchdog

  ( export PG_HA_WATCHDOG="auto" PG_HA_SERVER_TYPE="cloud"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    assert_equals "cloud" "$(pg_ha_detect_server_type)"
    assert_equals "off" "$(pg_ha_resolve_watchdog)" )
  ( export PG_HA_WATCHDOG="auto" PG_HA_SERVER_TYPE="dedicated"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    assert_equals "dedicated" "$(pg_ha_detect_server_type)"
    assert_equals "on" "$(pg_ha_resolve_watchdog)" )
  ( export PG_HA_WATCHDOG="off" PG_HA_SERVER_TYPE="dedicated"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    assert_equals "off" "$(pg_ha_resolve_watchdog)" )
  ( export PG_HA_WATCHDOG="on" PG_HA_SERVER_TYPE="cloud"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    assert_equals "on" "$(pg_ha_resolve_watchdog)" )
}

run_precheck_tests() {
  load_pg_ha

  # watchdog: off 时直接通过
  ( export PG_HA_WATCHDOG="off"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    pg_ha_check_watchdog || fail "expected watchdog off to pass" )

  # quorum 等待:mock curl 返回健康 JSON(wait_etcd_quorum 用 etcd /health 端点)
  ( source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    export PG_HA_NODE_IP=10.0.0.1
    curl() { echo '{"health":"true","reason":""}'; }
    pg_ha_wait_etcd_quorum || fail "expected quorum wait to succeed when etcd /health is true" )

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

  local perm
  perm="$(stat -c '%a' "${temp_root}/etcd.conf.yml" 2>/dev/null || stat -f '%Lp' "${temp_root}/etcd.conf.yml")"
  assert_equals "644" "$perm"

  write_etcd_unit_dropin
  assert_file_exists "${temp_root}/dropin/override.conf"
  assert_contains "${temp_root}/dropin/override.conf" "ExecStart="
  assert_contains "${temp_root}/dropin/override.conf" "--config-file=${temp_root}/etcd.conf.yml"

  assert_function_exists install_etcd
  assert_function_exists start_etcd
  assert_function_exists enable_etcd_rbac
  assert_function_exists etcd_health_check

  local rbac_log="${temp_root}/rbac.log"
  (
    export PG_HA_NODE1_IP="10.0.0.1" PG_HA_ETCD_PASSWORD="secret"
    load_pg_ha
    etcdctl() {
      printf "%s\n" "$*" >>"${rbac_log}"
      if [[ "$*" == *"auth status"* ]]; then
        if [[ "$*" == *"--user=root:secret"* ]]; then
          echo "Authentication Status: true"
          return 0
        fi
        echo "Error: etcdserver: user name is empty" >&2
        return 1
      fi
      return 0
    }
    enable_etcd_rbac
  )
  assert_contains "${rbac_log}" "--user=root:secret"
  assert_not_contains "${rbac_log}" "user add root:secret"
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

  # watchdog auto:cloud 分支默认关闭
  ( export PG_HA_WATCHDOG="auto" PG_HA_SERVER_TYPE="cloud" PG_HA_PATRONI_YAML="${temp_root}/patroni-auto-cloud.yml"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"
    source "${ROOT_DIR}/lib/pg-ha/common.sh"; source "${ROOT_DIR}/lib/pg-ha/patroni.sh"
    export PG_HA_NODE1_IP=10.0.0.1 PG_HA_NODE2_IP=10.0.0.2 PG_HA_NODE3_IP=10.0.0.3
    export PG_HA_ETCD_PASSWORD=x PG_HA_REST_PASSWORD=x PG_HA_SUPERUSER_PASSWORD=x
    export PG_HA_REPLICATION_PASSWORD=x PG_HA_REWIND_PASSWORD=x PG_HA_APP_ALLOWED_CIDR=10.0.0.0/24
    write_patroni_yaml "node1" "10.0.0.1"
    assert_contains "${temp_root}/patroni-auto-cloud.yml" 'mode: "off"'
    assert_not_contains "${temp_root}/patroni-auto-cloud.yml" "device: /dev/watchdog" )

  # watchdog auto:dedicated 分支默认启用
  ( export PG_HA_WATCHDOG="auto" PG_HA_SERVER_TYPE="dedicated" PG_HA_PATRONI_YAML="${temp_root}/patroni-auto-dedicated.yml"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"
    source "${ROOT_DIR}/lib/pg-ha/common.sh"; source "${ROOT_DIR}/lib/pg-ha/patroni.sh"
    export PG_HA_NODE1_IP=10.0.0.1 PG_HA_NODE2_IP=10.0.0.2 PG_HA_NODE3_IP=10.0.0.3
    export PG_HA_ETCD_PASSWORD=x PG_HA_REST_PASSWORD=x PG_HA_SUPERUSER_PASSWORD=x
    export PG_HA_REPLICATION_PASSWORD=x PG_HA_REWIND_PASSWORD=x PG_HA_APP_ALLOWED_CIDR=10.0.0.0/24
    write_patroni_yaml "node1" "10.0.0.1"
    assert_contains "${temp_root}/patroni-auto-dedicated.yml" "mode: required"
    assert_contains "${temp_root}/patroni-auto-dedicated.yml" "device: /dev/watchdog" )

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
  local perm
  perm="$(stat -c '%a' "${temp_root}/haproxy.cfg" 2>/dev/null || stat -f '%Lp' "${temp_root}/haproxy.cfg")"
  assert_equals "600" "$perm"
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
  pg_ha_setup_watchdog() { echo pg_ha_setup_watchdog >>"$action_log"; }
  pg_ha_preflight_connectivity() { echo pg_ha_preflight_connectivity >>"$action_log"; }
  pg_ha_require_passwords() { :; }

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
  assert_contains "$action_log" "pg_ha_setup_watchdog"
  assert_contains "$action_log" "pg_ha_preflight_connectivity"

  # replica 角色:etcd + patroni(start,非 bootstrap) + haproxy
  : >"$action_log"
  pg_ha_collect_config() { PG_HA_ROLE=replica; PG_HA_NODE_NAME=node2; PG_HA_NODE_IP=10.0.0.2; }
  pg_ha_main
  assert_contains "$action_log" "install_postgres_patroni"
  assert_contains "$action_log" "start_patroni"
  assert_not_contains "$action_log" "bootstrap_patroni"
  assert_contains "$action_log" "install_haproxy"
  assert_contains "$action_log" "pg_ha_setup_watchdog"
  assert_contains "$action_log" "pg_ha_preflight_connectivity"
}

run_pg_status_tests() {
  local tdir; tdir="$(mktemp -d)"; trap "rm -rf '$tdir'" RETURN
  load_pg_ha

  # 拓扑解析:从 etcd.conf.yml 的 initial-cluster 还原节点 IP
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    export PG_HA_ETCD_CONFIG_FILE="${tdir}/etcd.conf.yml"
    printf 'initial-cluster: node1=http://10.0.0.1:2380,node2=http://10.0.0.2:2380,node3=http://10.0.0.3:2380\n' >"${PG_HA_ETCD_CONFIG_FILE}"
    pg_ha_status_load_topology
    assert_equals "10.0.0.1" "${PG_HA_NODE1_IP}"
    assert_equals "10.0.0.2" "${PG_HA_NODE2_IP}"
    assert_equals "10.0.0.3" "${PG_HA_NODE3_IP}" )

  # 角色发现:有 patroni.yml + pg_is_in_recovery()=f -> primary
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    export PG_HA_PATRONI_YAML="${tdir}/patroni.yml"; : >"${PG_HA_PATRONI_YAML}"
    pg_ha_status_local_psql() { echo "f"; }
    pg_ha_status_detect_role; assert_equals "primary" "${PG_HA_DETECTED_ROLE}" )
  # =t -> replica
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    export PG_HA_PATRONI_YAML="${tdir}/patroni.yml"; : >"${PG_HA_PATRONI_YAML}"
    pg_ha_status_local_psql() { echo "t"; }
    pg_ha_status_detect_role; assert_equals "replica" "${PG_HA_DETECTED_ROLE}" )
  # 无 patroni.yml、有 etcd 配置 -> quorum
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    export PG_HA_PATRONI_YAML="${tdir}/none.yml" PG_HA_ETCD_CONFIG_FILE="${tdir}/etcd.conf.yml"
    pg_ha_status_detect_role; assert_equals "quorum" "${PG_HA_DETECTED_ROLE}" )

  # 服务检查:active+enabled -> OK；failed -> CRIT
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    status_reset
    systemctl() { case "$*" in *"is-active"*) return 0 ;; *"is-enabled"*) return 0 ;; *) echo "" ;; esac; }
    pg_ha_status_service_one etcd
    assert_equals "0" "${STATUS_CRIT_COUNT}"; assert_equals "0" "${STATUS_WARN_COUNT}" )
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    status_reset
    systemctl() { return 1; }
    pg_ha_status_service_one patroni
    assert_equals "1" "${STATUS_CRIT_COUNT}" )

  assert_function_exists pg_ha_status_identity
  assert_function_exists pg_ha_status_services

  # 拓扑:patronictl 输出含 Leader -> OK
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    export PG_HA_PATRONI_YAML="${tdir}/patroni.yml"; : >"${PG_HA_PATRONI_YAML}"
    PG_HA_DETECTED_ROLE=primary
    command_exists() { [[ "$1" == patronictl ]] && return 0; return 0; }
    patronictl() { printf '+ Cluster: pg-ha +\n| Member | Host | Role | State | TL | Lag |\n| node1 | 10.0.0.1 | Leader | running | 5 | |\n'; }
    status_reset; pg_ha_status_topology
    assert_equals "0" "${STATUS_CRIT_COUNT}" )
  # 拓扑:无 Leader + 持续无 -> CRIT
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    export PG_HA_PATRONI_YAML="${tdir}/patroni.yml" STATUS_RECHECK_DELAY=0; : >"${PG_HA_PATRONI_YAML}"
    PG_HA_DETECTED_ROLE=primary
    command_exists() { return 0; }
    patronictl() { printf '| node1 | 10.0.0.1 | Replica | running | 5 | 0 |\n'; }
    status_reset; pg_ha_status_topology
    assert_equals "1" "${STATUS_CRIT_COUNT}" )

  # 复制:主库 standby 滞后超 failover 阈值 -> WARN(不具备候选资格)
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    PG_HA_DETECTED_ROLE=primary
    pg_ha_status_local_psql() { echo "10.0.0.2 streaming async 5"; }   # 5MB > 1MB failover 阈值
    status_reset; pg_ha_status_replication
    assert_equals "1" "${STATUS_WARN_COUNT}"; assert_equals "0" "${STATUS_CRIT_COUNT}" )
  # 复制:standby 非 streaming -> CRIT
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    PG_HA_DETECTED_ROLE=primary
    pg_ha_status_local_psql() { echo "10.0.0.2 startup async ?"; }
    status_reset; pg_ha_status_replication
    assert_equals "1" "${STATUS_CRIT_COUNT}" )

  # 静默退化:inactive 复制槽 -> WARN
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    export PG_HA_PATRONI_YAML="${tdir}/patroni.yml"; : >"${PG_HA_PATRONI_YAML}"
    PG_HA_DETECTED_ROLE=primary
    command_exists() { return 1; }   # 跳过 patronictl 分支，只测复制槽
    pg_ha_status_local_psql() { echo "dead_slot"; }
    status_reset; pg_ha_status_degradation
    assert_equals "1" "${STATUS_WARN_COUNT}" )

  # 防脑裂:两节点 /primary 都 200 -> 多主 CRIT
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    PG_HA_DETECTED_ROLE=primary
    export PG_HA_NODE1_IP=10.0.0.1 PG_HA_NODE2_IP=10.0.0.2
    curl() { case "$*" in *"/health"*) echo '{"health":"true"}' ;; *"/primary"*) echo 200 ;; esac; }
    status_reset; pg_ha_status_splitbrain
    assert_equals "1" "${STATUS_CRIT_COUNT}" )

  assert_function_exists pg_ha_status_ingress

  # 磁盘:使用率超 CRIT 线 -> CRIT（quorum 节点，无 inactive 槽联动）
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    PG_HA_DETECTED_ROLE=quorum
    export PG_HA_ETCD_DATA="${tdir}"   # 存在的目录
    df() { printf 'Filesystem 1K-blocks Used Avail Use%% Mounted\n/dev/x 100 95 5 95%% /\n'; }
    pg_ha_status_local_psql() { echo "0"; }   # quorum 不走复制槽分支，但防止误调时产生额外计数
    status_reset; pg_ha_status_disk
    assert_equals "1" "${STATUS_CRIT_COUNT}"
    assert_equals "0" "${STATUS_WARN_COUNT}" )

  # 磁盘:primary + 磁盘使用率超 WARN + inactive 槽 > 0 -> 联动 CRIT
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    PG_HA_DETECTED_ROLE=primary
    export PG_HA_PGDATA="${tdir}" PG_HA_ETCD_DATA="${tdir}"
    export STATUS_DISK_WARN_PCT=80 STATUS_DISK_CRIT_PCT=90
    df() { printf 'Filesystem 1K-blocks Used Avail Use%% Mounted\n/dev/x 100 85 15 85%% /\n'; }
    pg_ha_status_local_psql() { echo "2"; }   # 2 个 inactive 槽
    status_reset; pg_ha_status_disk
    # 85% >= WARN -> 磁盘 WARN(2 个分区所以2次) + 联动 CRIT 1
    assert_equals "1" "${STATUS_CRIT_COUNT}"
    [[ "${STATUS_WARN_COUNT}" -ge 1 ]] || fail "expected at least 1 WARN for disk usage" )

  # 磁盘:primary + 磁盘使用率低于 WARN + inactive 槽 > 0 -> disk 不报 WARN/CRIT（由 degradation 负责）
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    PG_HA_DETECTED_ROLE=primary
    export PG_HA_PGDATA="${tdir}" PG_HA_ETCD_DATA="${tdir}"
    export STATUS_DISK_WARN_PCT=80 STATUS_DISK_CRIT_PCT=90
    df() { printf 'Filesystem 1K-blocks Used Avail Use%% Mounted\n/dev/x 100 60 40 60%% /\n'; }
    pg_ha_status_local_psql() { echo "3"; }   # 3 个 inactive 槽，但磁盘正常
    status_reset; pg_ha_status_disk
    assert_equals "0" "${STATUS_CRIT_COUNT}"
    assert_equals "0" "${STATUS_WARN_COUNT}" )

  # 连接数:超 WARN 线 -> WARN
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    PG_HA_DETECTED_ROLE=primary
    pg_ha_status_local_psql() { case "$1" in *count*) echo 85 ;; *max_connections*) echo 100 ;; esac; }
    status_reset; pg_ha_status_load
    assert_equals "1" "${STATUS_WARN_COUNT}" )

  # 编排:注入 CRIT -> 退出码 2
  ( source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/status-common.sh"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"; source "${ROOT_DIR}/lib/pg-ha/status.sh"
    pg_ha_status_load_topology() { :; }
    pg_ha_status_detect_role() { PG_HA_DETECTED_ROLE=primary; }
    pg_ha_status_identity() { :; }; pg_ha_status_services() { :; }; pg_ha_status_topology() { :; }
    pg_ha_status_replication() { :; }; pg_ha_status_degradation() { :; }; pg_ha_status_ingress() { :; }
    pg_ha_status_splitbrain() { status_crit "injected"; }
    pg_ha_status_disk() { :; }; pg_ha_status_clock() { :; }; pg_ha_status_logs() { :; }
    pg_ha_status_config_audit() { :; }; pg_ha_status_load() { :; }
    local rc=0; pg_ha_status_main >/dev/null || rc=$?
    assert_equals "2" "$rc" )

  assert_function_exists pg_ha_status_clock
  assert_function_exists pg_ha_status_logs
  assert_function_exists pg_ha_status_config_audit
}

run_status_skeleton_tests() {
  local entry="${ROOT_DIR}/status-pg-ha.sh"
  assert_file_exists "$entry"
  [[ -x "$entry" ]] || fail "expected status-pg-ha.sh to be executable"
  bash -n "$entry" || fail "status-pg-ha.sh has syntax errors"
  # 远程下载列表必须含新模块
  assert_contains "$entry" "lib/common.sh"
  assert_contains "$entry" "lib/status-common.sh"
  assert_contains "$entry" "lib/pg-ha/status.sh"
  assert_contains "$entry" "pg_ha_status_main"
  assert_contains "$entry" "require_root"
  # status 模块语法
  bash -n "${ROOT_DIR}/lib/status-common.sh" || fail "status-common.sh syntax error"
  bash -n "${ROOT_DIR}/lib/pg-ha/status.sh" || fail "pg-ha/status.sh syntax error"
}

run_docs_tests() {
  local readme="${ROOT_DIR}/README.md"
  assert_contains "$readme" "install-pg-ha.sh"
  assert_contains "$readme" "Patroni"
  assert_contains "$readme" "PG_HA_NODE1_IP"
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
    status_common) run_status_common_tests ;;
    config) run_config_tests ;;
    skeleton) run_skeleton_tests ;;
    status_skeleton) run_status_skeleton_tests ;;
    common) run_common_tests ;;
    precheck) run_precheck_tests ;;
    etcd) run_etcd_tests ;;
    patroni) run_patroni_tests ;;
    haproxy) run_haproxy_tests ;;
    orchestration) run_orchestration_tests ;;
    pg_status) run_pg_status_tests ;;
    docs) run_docs_tests ;;
    all) run_status_common_tests; run_skeleton_tests; run_status_skeleton_tests; run_config_tests; run_pg_status_tests; run_common_tests; run_precheck_tests; run_etcd_tests; run_patroni_tests; run_haproxy_tests; run_orchestration_tests; run_docs_tests ;;
    *) fail "unknown suite: $suite" ;;
  esac
  echo "PASS: ${suite}"
}

main "$@"
