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

# 仅字母数字:避免 / + = 破坏 JSON(orchestrator.conf.json)/SQL/cnf 的转义
mysql_ha_generate_password() {
  openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-25
}

mysql_ha_require_passwords() {
  local var vars="MYSQL_HA_ORCH_PASSWORD MYSQL_HA_ORCH_HTTP_PASSWORD"
  if [[ "${MYSQL_HA_ROLE}" != "arbiter" ]]; then
    vars="$vars MYSQL_HA_ROOT_PASSWORD MYSQL_HA_REPL_PASSWORD MYSQL_HA_MYSQLCHK_PASSWORD MYSQL_HA_WATCHER_PASSWORD MYSQL_HA_APP_PASSWORD"
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
  for node_ip in "${MYSQL_HA_NODE1_IP}" "${MYSQL_HA_NODE2_IP}" "${MYSQL_HA_NODE3_IP}"; do
    if ! mysql_ha_check_connectivity "$node_ip" "${MYSQL_HA_ORCH_PORT}"; then
      echo "Note: orchestrator ${MYSQL_HA_ORCH_PORT} on ${node_ip} not reachable yet (node may not be started)." >&2
      unreachable=1
    fi
  done
  if [[ "$unreachable" -eq 1 ]]; then
    echo "If this persists after all nodes are deployed, open ${MYSQL_HA_ORCH_PORT}/${MYSQL_HA_ORCH_RAFT_PORT}/3306/9200 between nodes." >&2
  fi
  return 0
}

mysql_ha_check_time_sync() {
  if command_exists timedatectl; then
    if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q '^yes$'; then
      echo "Warning: system clock not NTP-synchronized; raft elections are time-sensitive." >&2
      echo "Consider: apt-get install -y chrony" >&2
    fi
  fi
}

# 阻塞等待本机 Orchestrator raft 健康(对标 PG 版 etcd quorum 握手)
# 注:/api/raft-health 返回结构以实现期实测为准(spec Open Item #2)
mysql_ha_wait_raft_quorum() {
  local attempt out
  for attempt in $(seq 1 30); do
    out="$(curl -fsS --netrc-file <(printf 'machine 127.0.0.1 login admin password %s\n' "${MYSQL_HA_ORCH_HTTP_PASSWORD}") \
            "http://127.0.0.1:${MYSQL_HA_ORCH_PORT}/api/raft-health" 2>/dev/null || true)"
    if printf '%s' "$out" | grep -qi 'healthy'; then
      return 0
    fi
    sleep 2
  done
  echo "Orchestrator raft not healthy. Ensure all three orchestrator nodes are up and ${MYSQL_HA_ORCH_PORT}/${MYSQL_HA_ORCH_RAFT_PORT} are reachable between nodes." >&2
  return 1
}
