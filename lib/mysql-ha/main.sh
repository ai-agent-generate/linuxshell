#!/usr/bin/env bash
# lib/mysql-ha/main.sh — MySQL-HA 主编排入口

mysql_ha_show_summary() {
  print_step "MySQL HA deployment summary"
  echo "Role: ${MYSQL_HA_ROLE} (${MYSQL_HA_NODE_NAME} @ ${MYSQL_HA_NODE_IP})"
  echo "Cluster: ${MYSQL_HA_CLUSTER_NAME} | data nodes: ${MYSQL_HA_NODE1_IP},${MYSQL_HA_NODE2_IP} | arbiter: ${MYSQL_HA_NODE3_IP}"
  if [[ "${MYSQL_HA_ROLE}" != "arbiter" ]]; then
    echo "App connects to HAProxy :${MYSQL_HA_PROXY_PORT} (read+write, always current primary)"
    echo "Configure your app with BOTH HAProxy addresses (${MYSQL_HA_NODE1_IP}:${MYSQL_HA_PROXY_PORT}, ${MYSQL_HA_NODE2_IP}:${MYSQL_HA_PROXY_PORT}) and connection-retry."
    echo "Writability is maintained by Replication Manager on the arbiter and HAProxy mysqlchk health checks."
    if [[ "$(to_lower "${MYSQL_HA_SEMISYNC}")" == "on" ]]; then
      echo "Semi-sync: ON (near-zero RPO)."
    else
      echo "Semi-sync: OFF (async, RPO>0). Set MYSQL_HA_SEMISYNC=on for payment/strong-consistency workloads."
    fi
    echo "After a failover, a returning old primary must be checked/rejoined by Replication Manager before serving traffic."
  else
    echo "Replication Manager API: $(mysql_ha_repman_api_url)"
  fi
  echo "Passwords must be identical across nodes where documented. Store them securely."
}

mysql_ha_main() {
  require_root
  detect_os
  mysql_ha_collect_config
  mysql_ha_validate_node_ips
  mysql_ha_validate_mysql_version
  mysql_ha_check_time_sync
  mysql_ha_require_passwords
  if [[ "${MYSQL_HA_ROLE}" != "arbiter" && -z "${MYSQL_HA_APP_ALLOWED_CIDR}" ]]; then
    echo "MYSQL_HA_APP_ALLOWED_CIDR must be set for data nodes (e.g. 10.0.0.0/24)." >&2
    return 1
  fi

  case "${MYSQL_HA_ROLE}" in
    arbiter)
      install_repman
      write_repman_config
      write_repman_unit
      start_repman
      ;;
    primary)
      install_mysql
      relocate_datadir
      write_my_cnf "1" "primary"
      start_mysql
      bootstrap_mysql_accounts
      setup_mysqlchk
      start_mysqlchk
      install_haproxy
      start_haproxy
      ;;
    replica)
      install_mysql
      relocate_datadir
      write_my_cnf "2" "replica"
      start_mysql
      setup_replication
      setup_mysqlchk
      start_mysqlchk
      install_haproxy
      start_haproxy
      ;;
  esac

  mysql_ha_show_summary
}
