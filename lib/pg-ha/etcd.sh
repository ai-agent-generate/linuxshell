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
  # Ubuntu etcd 包以 etcd 用户(非 root)运行,配置文件需 etcd 可读;
  # 文件不含真实凭据(RBAC 密码由 etcdctl 设置),644 即可。
  chmod 644 "${PG_HA_ETCD_CONFIG_FILE}"
  if id etcd >/dev/null 2>&1; then
    chown etcd:etcd "${PG_HA_ETCD_CONFIG_FILE}"
  fi
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
  export DEBIAN_FRONTEND=noninteractive
  # 安装发行版包以获得 etcd 用户与 systemd unit(ExecStart 由 dropin 覆盖);幂等。
  apt-get install -y etcd-server etcd-client 2>/dev/null || true

  # Patroni 4.x 的 etcd3 客户端要求 v3 gRPC gateway 暴露在 /v3/(etcd 3.5+)。
  # Ubuntu 24.04 的 apt etcd 是 3.4(gateway 在 /v3beta/),与 Patroni 4.x 不兼容,
  # 会报 "Failed to get list of machines from .../v3" → 必须确保 etcd >= 3.5。
  local cur ver arch tmp
  cur="$(etcd --version 2>/dev/null | awk '/etcd Version/{print $3}')"
  if [[ -z "$cur" || "$(printf '3.5.0\n%s\n' "$cur" | sort -V | tail -1)" != "$cur" ]]; then
    ver="v3.5.16"; arch="$(dpkg --print-architecture)"; tmp="$(mktemp -d)"
    echo "Installing etcd ${ver} binary (current '${cur:-none}' < 3.5, incompatible with Patroni 4.x)." >&2
    curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ver}/etcd-${ver}-linux-${arch}.tar.gz" \
      -o "${tmp}/etcd.tar.gz"
    tar -xzf "${tmp}/etcd.tar.gz" -C "${tmp}" --strip-components=1
    install -m 0755 "${tmp}/etcd" "${tmp}/etcdctl" /usr/bin/
    rm -rf "${tmp}"
    # 若发行版包未提供 unit(纯二进制场景),自写一个
    if [[ ! -f /lib/systemd/system/etcd.service && ! -f /usr/lib/systemd/system/etcd.service ]]; then
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
  fi
  mkdir -p "${PG_HA_ETCD_DATA}"
}

start_etcd() {
  write_etcd_unit_dropin
  # 确保 data-dir 存在且 etcd 用户可写(install_etcd 在已装时会提前 return,
  # 故 data-dir 准备放在这里才可靠;二进制 fallback 无 etcd 用户时由 root 运行)。
  mkdir -p "${PG_HA_ETCD_DATA}"
  if id etcd >/dev/null 2>&1; then
    chown -R etcd:etcd "${PG_HA_ETCD_DATA}"
  fi
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
