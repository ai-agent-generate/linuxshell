#!/usr/bin/env bash
# lib/pg-ha/patroni.sh — Patroni 配置与安装函数(占位,由 Task 7/8/9 填充)

write_patroni_yaml() {
  local node_name="$1"
  local node_ip="$2"
  local sync_mode="false" sync_strict="false" watchdog_block

  [[ "$(to_lower "${PG_HA_SYNC_MODE}")" == "on" ]] && sync_mode="true"
  [[ "$(to_lower "${PG_HA_SYNC_STRICT}")" == "on" ]] && sync_strict="true"

  if [[ "$(to_lower "${PG_HA_WATCHDOG}")" == "on" ]]; then
    watchdog_block="watchdog:
  mode: required
  device: /dev/watchdog
  safety_margin: 5"
  else
    watchdog_block="watchdog:
  mode: \"off\""
  fi

  mkdir -p "$(dirname "${PG_HA_PATRONI_YAML}")"
  cat >"${PG_HA_PATRONI_YAML}" <<EOF
scope: ${PG_HA_CLUSTER_NAME}
name: ${node_name}

restapi:
  listen: ${node_ip}:${PG_HA_PATRONI_REST_PORT}
  connect_address: ${node_ip}:${PG_HA_PATRONI_REST_PORT}
  authentication:
    username: patroni
    password: ${PG_HA_REST_PASSWORD}

etcd3:
  hosts:
    - ${PG_HA_NODE1_IP}:${PG_HA_ETCD_CLIENT_PORT}
    - ${PG_HA_NODE2_IP}:${PG_HA_ETCD_CLIENT_PORT}
    - ${PG_HA_NODE3_IP}:${PG_HA_ETCD_CLIENT_PORT}
  username: patroni
  password: ${PG_HA_ETCD_PASSWORD}
  protocol: http

bootstrap:
  dcs:
    ttl: ${PG_HA_TTL}
    loop_wait: ${PG_HA_LOOP_WAIT}
    retry_timeout: ${PG_HA_RETRY_TIMEOUT}
    maximum_lag_on_failover: ${PG_HA_MAX_LAG_ON_FAILOVER}
    synchronous_mode: ${sync_mode}
    synchronous_mode_strict: ${sync_strict}
    postgresql:
      use_slots: true
      use_pg_rewind: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        max_slot_wal_keep_size: ${PG_HA_MAX_SLOT_WAL_KEEP_SIZE}
        wal_log_hints: "on"
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - local all all trust
    - host replication replicator ${PG_HA_NODE1_IP}/32 md5
    - host replication replicator ${PG_HA_NODE2_IP}/32 md5
    - host all all ${PG_HA_APP_ALLOWED_CIDR} md5
    - host all all 127.0.0.1/32 md5

postgresql:
  listen: ${node_ip}:${PG_HA_PG_PORT}
  connect_address: ${node_ip}:${PG_HA_PG_PORT}
  data_dir: ${PG_HA_PGDATA}
  bin_dir: /usr/lib/postgresql/${PG_HA_MAJOR_VERSION}/bin
  authentication:
    superuser:
      username: postgres
      password: ${PG_HA_SUPERUSER_PASSWORD}
    replication:
      username: replicator
      password: ${PG_HA_REPLICATION_PASSWORD}
    rewind:
      username: rewind_user
      password: ${PG_HA_REWIND_PASSWORD}

${watchdog_block}

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF
  chmod 600 "${PG_HA_PATRONI_YAML}"
}
