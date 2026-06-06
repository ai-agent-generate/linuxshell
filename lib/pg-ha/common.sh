#!/usr/bin/env bash
# lib/pg-ha/common.sh — PG-HA 专用公共函数

pg_ha_parse_role() {
  local input
  input="$(to_lower "$1")"
  case "$input" in
    1|primary|master) PG_HA_ROLE="primary" ;;
    2|replica|standby|slave) PG_HA_ROLE="replica" ;;
    3|quorum|etcd|witness) PG_HA_ROLE="quorum" ;;
    *) echo "Unknown role: $1 (use 1/primary, 2/replica, 3/quorum)" >&2; return 1 ;;
  esac
}

pg_ha_validate_node_ips() {
  local ip
  for ip in "${PG_HA_NODE1_IP}" "${PG_HA_NODE2_IP}" "${PG_HA_NODE3_IP}"; do
    if [[ -z "$ip" ]]; then
      echo "All three node IPs must be set (PG_HA_NODE1_IP/2/3)." >&2
      return 1
    fi
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Invalid IP address: $ip" >&2
      return 1
    fi
  done
}

pg_ha_generate_password() {
  openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-25
}

pg_ha_require_passwords() {
  local var
  for var in PG_HA_ETCD_PASSWORD PG_HA_REST_PASSWORD PG_HA_SUPERUSER_PASSWORD \
             PG_HA_REPLICATION_PASSWORD PG_HA_REWIND_PASSWORD; do
    if [[ -z "${!var}" ]]; then
      echo "${var} must be set (identical on primary and replica nodes)." >&2
      return 1
    fi
  done
}

pg_ha_check_watchdog() {
  [[ "$(to_lower "${PG_HA_WATCHDOG}")" == "on" ]] || return 0
  if [[ ! -e /dev/watchdog ]]; then
    echo "PG_HA_WATCHDOG=on but /dev/watchdog is unavailable on this host." >&2
    echo "Set PG_HA_WATCHDOG=off for this environment, or enable a watchdog device." >&2
    return 1
  fi
}

pg_ha_wait_etcd_quorum() {
  local endpoints attempt
  endpoints="${PG_HA_NODE1_IP}:${PG_HA_ETCD_CLIENT_PORT},${PG_HA_NODE2_IP}:${PG_HA_ETCD_CLIENT_PORT},${PG_HA_NODE3_IP}:${PG_HA_ETCD_CLIENT_PORT}"
  for attempt in $(seq 1 30); do
    if ETCDCTL_API=3 etcdctl --endpoints="$endpoints" endpoint health --cluster >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "etcd cluster not healthy. Ensure all three etcd nodes are up and ${PG_HA_ETCD_CLIENT_PORT}/${PG_HA_ETCD_PEER_PORT} are reachable between nodes." >&2
  return 1
}

pg_ha_check_connectivity() {
  local host="$1" port="$2"
  if command_exists nc; then
    nc -z -w 3 "$host" "$port" >/dev/null 2>&1
  else
    timeout 3 bash -c ">/dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

pg_ha_setup_watchdog() {
  [[ "$(to_lower "${PG_HA_WATCHDOG}")" == "on" ]] || return 0
  echo "softdog" >/etc/modules-load.d/softdog.conf
  modprobe softdog 2>/dev/null || true
  cat >/etc/udev/rules.d/99-watchdog.rules <<'RULES'
KERNEL=="watchdog", OWNER="postgres", GROUP="postgres", MODE="0600"
RULES
  udevadm control --reload 2>/dev/null || true
  udevadm trigger 2>/dev/null || true
  if [[ -e /dev/watchdog ]]; then
    chown postgres:postgres /dev/watchdog 2>/dev/null || true
  fi
}

pg_ha_preflight_connectivity() {
  local node_ip
  for node_ip in "${PG_HA_NODE1_IP}" "${PG_HA_NODE2_IP}" "${PG_HA_NODE3_IP}"; do
    if ! pg_ha_check_connectivity "$node_ip" "${PG_HA_ETCD_CLIENT_PORT}"; then
      echo "Cannot reach etcd client port ${PG_HA_ETCD_CLIENT_PORT} on ${node_ip}." >&2
      echo "Ensure etcd is up there and ${PG_HA_ETCD_CLIENT_PORT}/${PG_HA_ETCD_PEER_PORT} are open between nodes." >&2
      return 1
    fi
  done
}

pg_ha_check_time_sync() {
  if command_exists timedatectl; then
    if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q '^yes$'; then
      echo "Warning: system clock not NTP-synchronized; etcd/Patroni leases are time-sensitive." >&2
      echo "Consider: apt-get install -y chrony" >&2
    fi
  fi
}

pg_ha_collect_config() {
  local role_input
  role_input="$(prompt_with_default "Node role (1=primary, 2=replica, 3=etcd-quorum)" "1")"
  pg_ha_parse_role "$role_input"

  PG_HA_NODE1_IP="$(prompt_with_default "Node1 (primary) IP" "${PG_HA_NODE1_IP}")"
  PG_HA_NODE2_IP="$(prompt_with_default "Node2 (replica) IP" "${PG_HA_NODE2_IP}")"
  PG_HA_NODE3_IP="$(prompt_with_default "Node3 (etcd quorum) IP" "${PG_HA_NODE3_IP}")"

  case "${PG_HA_ROLE}" in
    primary) PG_HA_NODE_NAME="node1"; PG_HA_NODE_IP="${PG_HA_NODE1_IP}" ;;
    replica) PG_HA_NODE_NAME="node2"; PG_HA_NODE_IP="${PG_HA_NODE2_IP}" ;;
    quorum)  PG_HA_NODE_NAME="node3"; PG_HA_NODE_IP="${PG_HA_NODE3_IP}" ;;
  esac

  # etcd RBAC 密码三台一致(node3 仅 etcd 也需 root 密码用于 auth)
  PG_HA_ETCD_PASSWORD="$(prompt_with_default "etcd password (MUST be identical on all nodes)" "${PG_HA_ETCD_PASSWORD}")"

  if [[ "${PG_HA_ROLE}" != "quorum" ]]; then
    PG_HA_APP_ALLOWED_CIDR="$(prompt_with_default "Application allowed CIDR (e.g. 10.0.0.0/24)" "${PG_HA_APP_ALLOWED_CIDR}")"
    PG_HA_REST_PASSWORD="$(prompt_with_default "Patroni REST password (identical on PG nodes)" "${PG_HA_REST_PASSWORD}")"
    PG_HA_SUPERUSER_PASSWORD="$(prompt_with_default "postgres superuser password (identical on PG nodes)" "${PG_HA_SUPERUSER_PASSWORD}")"
    PG_HA_REPLICATION_PASSWORD="$(prompt_with_default "replication password (identical on PG nodes)" "${PG_HA_REPLICATION_PASSWORD}")"
    PG_HA_REWIND_PASSWORD="$(prompt_with_default "rewind password (identical on PG nodes)" "${PG_HA_REWIND_PASSWORD}")"
    PG_HA_STATS_PASSWORD="$(prompt_with_default "HAProxy stats password" "${PG_HA_STATS_PASSWORD:-$(pg_ha_generate_password)}")"
  fi
}
