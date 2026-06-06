#!/usr/bin/env bash
write_my_cnf() {
  local server_id="$1"
  local role="$2"   # primary | replica
  local semisync_block=""

  if [[ "$(to_lower "${MYSQL_HA_SEMISYNC}")" == "on" ]]; then
    if [[ "$role" == "primary" ]]; then
      semisync_block="plugin_load_add=semisync_source.so
rpl_semi_sync_source_enabled=1
rpl_semi_sync_source_timeout=${MYSQL_HA_SEMISYNC_TIMEOUT}
rpl_semi_sync_source_wait_for_replica_count=1"
    else
      semisync_block="plugin_load_add=semisync_replica.so
rpl_semi_sync_replica_enabled=1"
    fi
  fi

  mkdir -p "$(dirname "${MYSQL_HA_MYCNF}")"
  cat >"${MYSQL_HA_MYCNF}" <<EOF
[mysqld]
server_id=${server_id}
bind-address=${MYSQL_HA_NODE_IP}
port=${MYSQL_HA_MYSQL_PORT}
datadir=${MYSQL_HA_DATADIR}

gtid_mode=ON
enforce_gtid_consistency=ON
log_bin=mysql-bin
binlog_format=ROW
log_replica_updates=ON
relay_log=relay-bin
relay_log_recovery=ON
binlog_expire_logs_seconds=${MYSQL_HA_BINLOG_EXPIRE_SECONDS}

# boot 安全默认:重启即只读,由 mysql-ha-watcher 依 Orchestrator 拓扑收敛回可写
super_read_only=ON
${semisync_block}
EOF
  # my.cnf 不含任何密码,644 合理(MySQL 期望该文件可读)
  chmod 644 "${MYSQL_HA_MYCNF}"
}
