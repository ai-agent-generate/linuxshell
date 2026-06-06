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
