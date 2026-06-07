#!/usr/bin/env bash
# lib/mysql-ha/common.sh — MySQL-HA 专用公共函数

mysql_ha_parse_role() {
  local input
  input="$(to_lower "$1")"
  case "$input" in
    1|primary|master|source) MYSQL_HA_ROLE="primary" ;;
    2|replica|standby|slave) MYSQL_HA_ROLE="replica" ;;
    3|arbiter|quorum|witness) MYSQL_HA_ROLE="arbiter" ;;
    *) echo "Unknown role: $1 (use 1/primary, 2/replica, 3/arbiter)" >&2; return 1 ;;
  esac
}

mysql_ha_validate_node_ips() {
  local ip
  for ip in "${MYSQL_HA_NODE1_IP}" "${MYSQL_HA_NODE2_IP}" "${MYSQL_HA_NODE3_IP}"; do
    if [[ -z "$ip" ]]; then
      echo "All three node IPs must be set (MYSQL_HA_NODE1_IP/2/3)." >&2
      return 1
    fi
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Invalid IP address: $ip" >&2
      return 1
    fi
  done
}

mysql_ha_validate_mysql_version() {
  case "${MYSQL_HA_VERSION}" in
    8.4)
      return 0
      ;;
    *)
      echo "MYSQL_HA_VERSION=${MYSQL_HA_VERSION} is not supported in this HA mode. Use MYSQL_HA_VERSION=8.4." >&2
      echo "This path is designed for MySQL 8.4 classic GTID replication managed by Replication Manager." >&2
      return 1
      ;;
  esac
}

# 仅字母数字:避免 / + = 破坏 JSON(orchestrator.conf.json)/SQL/cnf 的转义
mysql_ha_generate_password() {
  openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-25
}

mysql_ha_require_passwords() {
  local var vars="MYSQL_HA_REPMAN_PASSWORD MYSQL_HA_REPMAN_API_PASSWORD MYSQL_HA_REPL_PASSWORD"
  if [[ "${MYSQL_HA_ROLE}" != "arbiter" ]]; then
    vars="$vars MYSQL_HA_ROOT_PASSWORD MYSQL_HA_MYSQLCHK_PASSWORD MYSQL_HA_APP_PASSWORD MYSQL_HA_STATS_PASSWORD"
  fi
  for var in $vars; do
    if [[ -z "${!var}" ]]; then
      echo "${var} must be set (identical across nodes as documented)." >&2
      return 1
    fi
  done
}

mysql_ha_check_connectivity() {
  local host="$1" port="$2"
  if command_exists nc; then
    nc -z -w 3 "$host" "$port" >/dev/null 2>&1
  else
    timeout 3 bash -c ">/dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

# 非阻塞:仅探测节点间关键端口并提示(部署顺序下后部署节点未启属正常)
mysql_ha_preflight_connectivity() {
  local node_ip unreachable=0
  for node_ip in "${MYSQL_HA_NODE1_IP}" "${MYSQL_HA_NODE2_IP}"; do
    if ! mysql_ha_check_connectivity "$node_ip" "${MYSQL_HA_MYSQL_PORT}"; then
      echo "Note: MySQL ${MYSQL_HA_MYSQL_PORT} on ${node_ip} not reachable yet (node may not be started)." >&2
      unreachable=1
    fi
  done
  if [[ "$unreachable" -eq 1 ]]; then
    echo "If this persists after all nodes are deployed, open 3306/9200/6446 between data nodes and ${MYSQL_HA_REPMAN_API_PORT} to the arbiter." >&2
  fi
  return 0
}

mysql_ha_check_time_sync() {
  if command_exists timedatectl; then
    if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q '^yes$'; then
      echo "Warning: system clock not NTP-synchronized; failover decisions are time-sensitive." >&2
      echo "Consider: apt-get install -y chrony" >&2
    fi
  fi
}

mysql_ha_repman_api_url() {
  local host="${MYSQL_HA_NODE3_IP:-${MYSQL_HA_NODE_IP:-127.0.0.1}}"
  printf "http://%s:%s" "$host" "${MYSQL_HA_REPMAN_API_PORT}"
}

mysql_ha_collect_config() {
  cat >&2 <<'GUIDE'

=== MySQL 高可用部署 ===
本脚本需在【每台机器各运行一次】,每次选择"本机"的角色(这是正常流程,不是重复)。
推荐顺序: (1) 先 arbiter(仲裁) -> (2) 再 primary(主库) -> (3) 最后 replica(从库)
三个节点 IP 与各项密码,必须在所有数据节点上填写【完全一致】。

GUIDE
  local role_input
  role_input="$(prompt_with_default "Node role (1=primary, 2=replica, 3=arbiter)" "1")"
  mysql_ha_parse_role "$role_input"

  MYSQL_HA_NODE1_IP="$(prompt_with_default "Node1 (primary) IP" "${MYSQL_HA_NODE1_IP}")"
  MYSQL_HA_NODE2_IP="$(prompt_with_default "Node2 (replica) IP" "${MYSQL_HA_NODE2_IP}")"
  MYSQL_HA_NODE3_IP="$(prompt_with_default "Node3 (arbiter) IP" "${MYSQL_HA_NODE3_IP}")"

  case "${MYSQL_HA_ROLE}" in
    primary) MYSQL_HA_NODE_NAME="node1"; MYSQL_HA_NODE_IP="${MYSQL_HA_NODE1_IP}"; MYSQL_HA_SERVER_ID=1 ;;
    replica) MYSQL_HA_NODE_NAME="node2"; MYSQL_HA_NODE_IP="${MYSQL_HA_NODE2_IP}"; MYSQL_HA_SERVER_ID=2 ;;
    arbiter) MYSQL_HA_NODE_NAME="node3"; MYSQL_HA_NODE_IP="${MYSQL_HA_NODE3_IP}"; MYSQL_HA_SERVER_ID=0 ;;
  esac

  MYSQL_HA_REPMAN_PASSWORD="$(prompt_with_default "Replication Manager MySQL password (identical on ALL nodes)" "${MYSQL_HA_REPMAN_PASSWORD}")"
  MYSQL_HA_REPMAN_API_PASSWORD="$(prompt_with_default "Replication Manager API password (arbiter)" "${MYSQL_HA_REPMAN_API_PASSWORD:-$(mysql_ha_generate_password)}")"
  MYSQL_HA_REPL_PASSWORD="$(prompt_with_default "replication password (identical on data nodes and arbiter config)" "${MYSQL_HA_REPL_PASSWORD}")"

  if [[ "${MYSQL_HA_ROLE}" != "arbiter" ]]; then
    MYSQL_HA_APP_ALLOWED_CIDR="$(prompt_with_default "Application allowed CIDR (e.g. 10.0.0.0/24)" "${MYSQL_HA_APP_ALLOWED_CIDR}")"
    MYSQL_HA_ROOT_PASSWORD="$(prompt_with_default "MySQL root password (identical on data nodes)" "${MYSQL_HA_ROOT_PASSWORD}")"
    MYSQL_HA_MYSQLCHK_PASSWORD="$(prompt_with_default "mysqlchk password (identical on data nodes)" "${MYSQL_HA_MYSQLCHK_PASSWORD:-$(mysql_ha_generate_password)}")"
    MYSQL_HA_APP_PASSWORD="$(prompt_with_default "application '${MYSQL_HA_APP_USER}' password (identical on data nodes)" "${MYSQL_HA_APP_PASSWORD}")"
    MYSQL_HA_STATS_PASSWORD="$(prompt_with_default "HAProxy stats password" "${MYSQL_HA_STATS_PASSWORD:-$(mysql_ha_generate_password)}")"
  fi
}
