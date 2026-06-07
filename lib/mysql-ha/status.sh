#!/usr/bin/env bash
# lib/mysql-ha/status.sh — MySQL HA 只读巡检
# 依赖:lib/common.sh + lib/status-common.sh + lib/mysql-ha/config.sh + lib/mysql-ha/common.sh

MYSQL_HA_DETECTED_ROLE=""
MYSQL_HA_LOCAL_IP=""

# 本机只读 SQL:mysqlchk.cnf(socket，仅本机)。读 @@global.read_only 等任何账号可读。
mysql_ha_status_local_sql() {
  mysql --defaults-extra-file="${MYSQL_HA_MYSQLCHK_CNF}" -N -B -e "$1" 2>/dev/null || true
}

# 拓扑:arbiter 从 config.toml；data 从 haproxy.cfg。node3(arbiter) 在 data 节点上无法得知。
mysql_ha_status_load_topology() {
  local hosts
  if [[ -e "${MYSQL_HA_REPMAN_CONF}" ]]; then
    hosts="$(status_extract_kv "${MYSQL_HA_REPMAN_CONF}" 's/.*db-servers-hosts = "\([^"]*\)".*/\1/p')"
    if [[ -n "$hosts" ]]; then
      MYSQL_HA_NODE1_IP="$(printf '%s' "$hosts" | sed -n 's/^\([0-9.]\{7,\}\):.*/\1/p')"
      MYSQL_HA_NODE2_IP="$(printf '%s' "$hosts" | sed -n 's/.*,\([0-9.]\{7,\}\):.*/\1/p')"
    fi
  elif [[ -e "${MYSQL_HA_HAPROXY_CFG}" ]]; then
    MYSQL_HA_NODE1_IP="$(status_extract_kv "${MYSQL_HA_HAPROXY_CFG}" 's/.*server node1 \([0-9.]\{7,\}\):.*/\1/p')"
    MYSQL_HA_NODE2_IP="$(status_extract_kv "${MYSQL_HA_HAPROXY_CFG}" 's/.*server node2 \([0-9.]\{7,\}\):.*/\1/p')"
  fi
  return 0
}

mysql_ha_status_detect_role() {
  if [[ -e "${MYSQL_HA_MYCNF}" ]]; then
    local ro; ro="$(mysql_ha_status_local_sql 'SELECT @@global.read_only')"
    case "$ro" in
      0) MYSQL_HA_DETECTED_ROLE="primary" ;;
      1) MYSQL_HA_DETECTED_ROLE="replica" ;;
      *) MYSQL_HA_DETECTED_ROLE="unknown" ;;
    esac
  elif [[ -e "${MYSQL_HA_REPMAN_CONF}" ]]; then
    MYSQL_HA_DETECTED_ROLE="arbiter"
  else
    MYSQL_HA_DETECTED_ROLE="unknown"
  fi
  printf '%s' "${MYSQL_HA_DETECTED_ROLE}"
  return 0
}

mysql_ha_status_identity() {
  status_section "本机身份"
  status_kv "集群名" "${MYSQL_HA_CLUSTER_NAME}"
  status_kv "主机名" "$(hostname 2>/dev/null || echo unknown)"
  local lip node="unknown"
  if lip="$(status_local_ip "${MYSQL_HA_NODE1_IP}" "${MYSQL_HA_NODE2_IP}" "${MYSQL_HA_NODE3_IP}" 2>/dev/null)"; then
    [[ "$lip" == "${MYSQL_HA_NODE1_IP}" ]] && node="node1"
    [[ "$lip" == "${MYSQL_HA_NODE2_IP}" ]] && node="node2"
    [[ "$lip" == "${MYSQL_HA_NODE3_IP}" ]] && node="node3"
    MYSQL_HA_LOCAL_IP="$lip"
  else lip="(未匹配 NODE*_IP)"; fi
  status_kv "本机 IP / 编号" "${lip} / ${node}"
  if [[ "${MYSQL_HA_DETECTED_ROLE}" == "primary" || "${MYSQL_HA_DETECTED_ROLE}" == "replica" ]]; then
    status_kv "server_id" "$(mysql_ha_status_local_sql 'SELECT @@server_id')"
  fi
  case "${MYSQL_HA_DETECTED_ROLE}" in
    primary) status_ok   "本机角色" "primary (MySQL 主库, read_only=0)" ;;
    replica) status_ok   "本机角色" "replica (MySQL 从库, read_only=1)" ;;
    arbiter) status_ok   "本机角色" "arbiter (仅 Replication Manager 仲裁，不跑 MySQL)" ;;
    *)       status_warn "本机角色" "无法确定(zz-mysql-ha.cnf/config.toml 缺失或本机 MySQL 不可连)" ;;
  esac
  return 0
}

mysql_ha_status_service_one() {
  local svc="$1" since
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    since="$(systemctl show -p ActiveEnterTimestamp --value "$svc" 2>/dev/null || true)"
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      status_ok "服务 $svc" "active, enabled${since:+, since $since}"
    else
      status_warn "服务 $svc" "active 但未设置开机自启${since:+, since $since}"
    fi
  else
    status_crit "服务 $svc" "未运行(inactive/failed)"
  fi
  return 0
}

mysql_ha_status_services() {
  status_section "服务健康"
  local p ports
  if [[ "${MYSQL_HA_DETECTED_ROLE}" == "arbiter" ]]; then
    mysql_ha_status_service_one replication-manager
    ports="${MYSQL_HA_REPMAN_API_PORT} ${MYSQL_HA_REPMAN_HTTP_PORT}"
  else
    mysql_ha_status_service_one mysql
    mysql_ha_status_service_one haproxy
    mysql_ha_status_service_one mysqlchk.socket
    status_info "replication-manager" "数据节点不运行 repman(在 arbiter 节点)"
    ports="${MYSQL_HA_MYSQL_PORT} ${MYSQL_HA_PROXY_PORT} ${MYSQL_HA_PROXY_STATS_PORT} ${MYSQL_HA_MYSQLCHK_PORT}"
  fi
  for p in $ports; do
    if port_in_use "$p"; then status_ok "端口 $p" "监听中"; else status_warn "端口 $p" "未监听"; fi
  done
  return 0
}
