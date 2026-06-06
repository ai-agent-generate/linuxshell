#!/usr/bin/env bash
write_orchestrator_config() {
  local node_ip="$1"
  mkdir -p "$(dirname "${MYSQL_HA_ORCH_CONF}")"
  cat >"${MYSQL_HA_ORCH_CONF}" <<EOF
{
  "Debug": false,
  "ListenAddress": "${node_ip}:${MYSQL_HA_ORCH_PORT}",
  "MySQLTopologyUser": "orchestrator",
  "MySQLTopologyPassword": "${MYSQL_HA_ORCH_PASSWORD}",
  "MySQLConnectTimeoutSeconds": 1,
  "MySQLTopologyUseMutualTLS": false,
  "AuthenticationMethod": "basic",
  "HTTPAuthUser": "admin",
  "HTTPAuthPassword": "${MYSQL_HA_ORCH_HTTP_PASSWORD}",
  "BackendDB": "sqlite",
  "SQLite3DataFile": "${MYSQL_HA_ORCH_DATADIR}/orchestrator.sqlite3",
  "RaftEnabled": true,
  "RaftDataDir": "${MYSQL_HA_ORCH_DATADIR}",
  "RaftBind": "${node_ip}",
  "DefaultRaftPort": ${MYSQL_HA_ORCH_RAFT_PORT},
  "RaftNodes": ["${MYSQL_HA_NODE1_IP}", "${MYSQL_HA_NODE2_IP}", "${MYSQL_HA_NODE3_IP}"],
  "InstancePollSeconds": ${MYSQL_HA_INSTANCE_POLL_SECONDS},
  "RecoveryPeriodBlockSeconds": ${MYSQL_HA_RECOVERY_BLOCK_SECONDS},
  "RecoverMasterClusterFilters": ["*"],
  "ApplyMySQLPromotionAfterMasterFailover": true,
  "FailMasterPromotionIfSQLThreadNotUpToDate": true,
  "ReasonableReplicationLagSeconds": ${MYSQL_HA_PROMOTION_LAG_SECONDS},
  "PostFailoverProcesses": [
    "mysql --defaults-extra-file=${MYSQL_HA_ORCH_CLIENT_CNF} -h {failedHost} -P {failedPort} -e 'SET GLOBAL super_read_only=1' || true"
  ]
}
EOF
  chmod 600 "${MYSQL_HA_ORCH_CONF}"
}

# orchestrator 账号客户端凭据(供 PostFailover 钩子远程连旧主;不进 argv,无 TLS 取公钥)
write_orchestrator_client_cnf() {
  mkdir -p "$(dirname "${MYSQL_HA_ORCH_CLIENT_CNF}")"
  cat >"${MYSQL_HA_ORCH_CLIENT_CNF}" <<EOF
[client]
user=orchestrator
password=${MYSQL_HA_ORCH_PASSWORD}
get-server-public-key
EOF
  chmod 600 "${MYSQL_HA_ORCH_CLIENT_CNF}"
}

write_orchestrator_unit() {
  mkdir -p "$(dirname "${MYSQL_HA_ORCH_UNIT}")"
  cat >"${MYSQL_HA_ORCH_UNIT}" <<EOF
[Unit]
Description=orchestrator MySQL HA
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/orchestrator/orchestrator --config ${MYSQL_HA_ORCH_CONF} http
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

install_orchestrator() {
  print_step "Installing Orchestrator"
  if command_exists orchestrator || [[ -x /usr/local/orchestrator/orchestrator ]]; then
    echo "orchestrator already installed."
  else
    export DEBIAN_FRONTEND=noninteractive
    # 版本锁定 + 资产文件名形态实现期核对(spec Open Item #1)
    local ver="v3.2.6" arch tmp
    arch="$(dpkg --print-architecture)"
    tmp="$(mktemp -d)"
    if curl -fsSL "https://github.com/openark/orchestrator/releases/download/${ver}/orchestrator_${ver#v}_${arch}.deb" -o "${tmp}/orchestrator.deb" \
       && apt-get install -y "${tmp}/orchestrator.deb"; then
      echo "orchestrator installed from .deb (${ver})."
    else
      echo "deb unavailable; installing official binary ${ver}." >&2
      curl -fsSL "https://github.com/openark/orchestrator/releases/download/${ver}/orchestrator-${ver#v}-linux-${arch}.tar.gz" -o "${tmp}/orch.tar.gz"
      mkdir -p /usr/local/orchestrator
      tar -xzf "${tmp}/orch.tar.gz" -C /usr/local/orchestrator
      write_orchestrator_unit
    fi
    rm -rf "${tmp}"
  fi
  mkdir -p "${MYSQL_HA_ORCH_DATADIR}"
}

start_orchestrator() {
  systemctl daemon-reload
  systemctl enable orchestrator
  systemctl restart orchestrator
}

# raft 模式 discover/forget 等写命令需经 raft leader;client 默认走 API leader
# 具体调用形态(orchestrator-client 的 API/auth 传入)实现期核对(spec Open Item #1)
orchestrator_discover() {
  print_step "Discovering cluster topology via orchestrator"
  ORCHESTRATOR_API="http://127.0.0.1:${MYSQL_HA_ORCH_PORT}/api" \
    orchestrator-client -c discover -i "${MYSQL_HA_NODE1_IP}:${MYSQL_HA_MYSQL_PORT}" || true
}
