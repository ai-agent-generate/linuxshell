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
