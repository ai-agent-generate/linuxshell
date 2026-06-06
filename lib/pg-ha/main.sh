#!/usr/bin/env bash
# lib/pg-ha/main.sh — PG-HA 主编排入口

pg_ha_show_summary() {
  print_step "PostgreSQL HA deployment summary"
  echo "Role: ${PG_HA_ROLE} (${PG_HA_NODE_NAME} @ ${PG_HA_NODE_IP})"
  echo "Cluster: ${PG_HA_CLUSTER_NAME} | etcd: ${PG_HA_NODE1_IP},${PG_HA_NODE2_IP},${PG_HA_NODE3_IP}"
  if [[ "${PG_HA_ROLE}" != "quorum" ]]; then
    echo "App connects to HAProxy :${PG_HA_PROXY_PORT} (read+write, always current primary)"
    echo "Configure your app with BOTH HAProxy addresses (${PG_HA_NODE1_IP}:${PG_HA_PROXY_PORT}, ${PG_HA_NODE2_IP}:${PG_HA_PROXY_PORT}) and connection-retry."
    echo "Verify: patronictl -c ${PG_HA_PATRONI_YAML} list"
  fi
  if [[ "$(to_lower "${PG_HA_WATCHDOG}")" == "off" ]]; then
    echo "WARNING: watchdog disabled — split-brain protection is OFF (double-write risk on Patroni failure)."
  fi
  echo "Passwords must be identical across primary/replica. Store them securely."
}

pg_ha_main() {
  require_root
  detect_os
  pg_ha_collect_config
  pg_ha_validate_node_ips
  pg_ha_check_time_sync

  case "${PG_HA_ROLE}" in
    quorum)
      install_etcd
      write_etcd_config "${PG_HA_NODE_NAME}" "${PG_HA_NODE_IP}"
      start_etcd
      ;;
    primary)
      pg_ha_check_watchdog
      install_etcd
      write_etcd_config "${PG_HA_NODE_NAME}" "${PG_HA_NODE_IP}"
      start_etcd
      install_postgres_patroni
      disable_default_cluster
      write_patroni_yaml "${PG_HA_NODE_NAME}" "${PG_HA_NODE_IP}"
      bootstrap_patroni
      install_haproxy
      start_haproxy
      ;;
    replica)
      pg_ha_check_watchdog
      install_etcd
      write_etcd_config "${PG_HA_NODE_NAME}" "${PG_HA_NODE_IP}"
      start_etcd
      install_postgres_patroni
      disable_default_cluster
      write_patroni_yaml "${PG_HA_NODE_NAME}" "${PG_HA_NODE_IP}"
      pg_ha_wait_etcd_quorum
      start_patroni
      install_haproxy
      start_haproxy
      ;;
  esac

  pg_ha_show_summary
}
