#!/usr/bin/env bash

mysql_ha_repman_arch() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$arch" in
    amd64|x86_64) printf "amd64" ;;
    arm64|aarch64) printf "arm64" ;;
    *) echo "Unsupported Replication Manager architecture: $arch" >&2; return 1 ;;
  esac
}

write_repman_config() {
  mkdir -p "$(dirname "${MYSQL_HA_REPMAN_CONF}")" "${MYSQL_HA_REPMAN_DATADIR}"
  local failover_at_sync="false"
  if [[ "$(to_lower "${MYSQL_HA_SEMISYNC}")" == "on" ]]; then
    failover_at_sync="true"
  fi
  cat >"${MYSQL_HA_REPMAN_CONF}" <<EOF
[Default]
monitoring-save-config = true
monitoring-datadir = "${MYSQL_HA_REPMAN_DATADIR}"
monitoring-ticker = ${MYSQL_HA_INSTANCE_POLL_SECONDS}
api-port = "${MYSQL_HA_REPMAN_API_PORT}"
api-credentials = "${MYSQL_HA_REPMAN_API_USER}:${MYSQL_HA_REPMAN_API_PASSWORD}"
http-server = true
http-bind-address = "0.0.0.0"
http-port = "${MYSQL_HA_REPMAN_HTTP_PORT}"
log-level = 2
opensvc = false

[${MYSQL_HA_CLUSTER_NAME}]
title = "${MYSQL_HA_CLUSTER_NAME}"
prov-orchestrator = "onpremise"
db-servers-hosts = "${MYSQL_HA_NODE1_IP}:${MYSQL_HA_MYSQL_PORT},${MYSQL_HA_NODE2_IP}:${MYSQL_HA_MYSQL_PORT}"
db-servers-prefered-master = "${MYSQL_HA_NODE1_IP}:${MYSQL_HA_MYSQL_PORT}"
db-servers-credential = "${MYSQL_HA_REPMAN_USER}:${MYSQL_HA_REPMAN_PASSWORD}"
replication-credential = "repl:${MYSQL_HA_REPL_PASSWORD}"
replication-use-ssl = true
failover-mode = "automatic"
failover-readonly-state = true
failover-superreadonly-state = true
failover-at-sync = ${failover_at_sync}
failover-max-slave-delay = ${MYSQL_HA_PROMOTION_LAG_SECONDS}
failover-time-limit = ${MYSQL_HA_RECOVERY_BLOCK_SECONDS}
EOF
  chmod 600 "${MYSQL_HA_REPMAN_CONF}"
}

install_repman() {
  print_step "Installing Replication Manager ${MYSQL_HA_REPMAN_VERSION}"
  if [[ -x "${MYSQL_HA_REPMAN_BIN}" ]]; then
    echo "replication-manager-osc already installed."
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y ca-certificates gnupg lsb-release

  local codename keyring version
  codename="$(lsb_release -cs 2>/dev/null || echo noble)"
  keyring="/usr/share/keyrings/signal18.gpg"
  version="${MYSQL_HA_REPMAN_VERSION#v}-1"

  if [[ ! -s "$keyring" ]]; then
    gpg --batch --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys FAE20E50
    gpg --batch --export FAE20E50 >"$keyring"
  fi
  cat >/etc/apt/sources.list.d/signal18.list <<EOF
deb [signed-by=${keyring}] http://repo.signal18.io/deb ${codename} 3.1
EOF
  apt-get update
  apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    "replication-manager-osc=${version}"
}

write_repman_unit() {
  mkdir -p "$(dirname "${MYSQL_HA_REPMAN_UNIT}")"
  cat >"${MYSQL_HA_REPMAN_UNIT}" <<EOF
[Unit]
Description=Replication Manager MySQL HA monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MYSQL_HA_REPMAN_BIN} --config ${MYSQL_HA_REPMAN_CONF} monitor
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

start_repman() {
  write_repman_config
  write_repman_unit
  systemctl daemon-reload
  systemctl enable replication-manager
  systemctl restart replication-manager
}
