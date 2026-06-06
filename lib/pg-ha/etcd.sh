#!/usr/bin/env bash
# lib/pg-ha/etcd.sh — etcd 配置与安装函数

write_etcd_config() {
  local node_name="$1"
  local node_ip="$2"
  mkdir -p "$(dirname "${PG_HA_ETCD_CONFIG_FILE}")"
  cat >"${PG_HA_ETCD_CONFIG_FILE}" <<EOF
name: ${node_name}
data-dir: ${PG_HA_ETCD_DATA}
listen-peer-urls: http://${node_ip}:${PG_HA_ETCD_PEER_PORT}
listen-client-urls: http://${node_ip}:${PG_HA_ETCD_CLIENT_PORT},http://127.0.0.1:${PG_HA_ETCD_CLIENT_PORT}
initial-advertise-peer-urls: http://${node_ip}:${PG_HA_ETCD_PEER_PORT}
advertise-client-urls: http://${node_ip}:${PG_HA_ETCD_CLIENT_PORT}
initial-cluster: node1=http://${PG_HA_NODE1_IP}:${PG_HA_ETCD_PEER_PORT},node2=http://${PG_HA_NODE2_IP}:${PG_HA_ETCD_PEER_PORT},node3=http://${PG_HA_NODE3_IP}:${PG_HA_ETCD_PEER_PORT}
initial-cluster-state: new
initial-cluster-token: ${PG_HA_CLUSTER_NAME}
EOF
  chmod 600 "${PG_HA_ETCD_CONFIG_FILE}"
}

write_etcd_unit_dropin() {
  mkdir -p "$(dirname "${PG_HA_ETCD_UNIT_DROPIN}")"
  cat >"${PG_HA_ETCD_UNIT_DROPIN}" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/etcd --config-file=${PG_HA_ETCD_CONFIG_FILE}
EOF
}

install_etcd() {
  print_step "Installing etcd"
  if command_exists etcd; then
    echo "etcd already installed."
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  if apt-get install -y etcd-server etcd-client 2>/dev/null; then
    echo "etcd installed from distribution packages."
  else
    echo "Distribution etcd unavailable; installing official binary v3.5.16." >&2
    local ver="v3.5.16" arch tmp
    arch="$(dpkg --print-architecture)"
    tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ver}/etcd-${ver}-linux-${arch}.tar.gz" \
      -o "${tmp}/etcd.tar.gz"
    tar -xzf "${tmp}/etcd.tar.gz" -C "${tmp}" --strip-components=1
    install -m 0755 "${tmp}/etcd" "${tmp}/etcdctl" /usr/bin/
    rm -rf "${tmp}"
    cat >/etc/systemd/system/etcd.service <<'UNIT'
[Unit]
Description=etcd
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/etcd
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
  fi
  mkdir -p "${PG_HA_ETCD_DATA}"
}

start_etcd() {
  write_etcd_unit_dropin
  systemctl daemon-reload
  systemctl enable etcd
  systemctl restart etcd
}

etcd_health_check() {
  local endpoint="${PG_HA_NODE_IP}:${PG_HA_ETCD_CLIENT_PORT}"
  ETCDCTL_API=3 etcdctl --endpoints="$endpoint" endpoint health
}

# 仅在 primary 执行一次:创建 RBAC 用户并启用认证(集群级生效)
enable_etcd_rbac() {
  local ep="${PG_HA_NODE1_IP}:${PG_HA_ETCD_CLIENT_PORT}"
  if ETCDCTL_API=3 etcdctl --endpoints="$ep" auth status 2>/dev/null | grep -q "Authentication Status: true"; then
    echo "etcd auth already enabled."
    return 0
  fi
  ETCDCTL_API=3 etcdctl --endpoints="$ep" user add root:"${PG_HA_ETCD_PASSWORD}"
  ETCDCTL_API=3 etcdctl --endpoints="$ep" user grant-role root root
  ETCDCTL_API=3 etcdctl --endpoints="$ep" user add patroni:"${PG_HA_ETCD_PASSWORD}"
  ETCDCTL_API=3 etcdctl --endpoints="$ep" role add patroni-role
  ETCDCTL_API=3 etcdctl --endpoints="$ep" role grant-permission patroni-role --prefix=true readwrite "/service/${PG_HA_CLUSTER_NAME}/"
  ETCDCTL_API=3 etcdctl --endpoints="$ep" user grant-role patroni patroni-role
  ETCDCTL_API=3 etcdctl --endpoints="$ep" auth enable
}
