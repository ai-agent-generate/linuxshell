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
}

write_etcd_unit_dropin() {
  mkdir -p "$(dirname "${PG_HA_ETCD_UNIT_DROPIN}")"
  cat >"${PG_HA_ETCD_UNIT_DROPIN}" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/etcd --config-file=${PG_HA_ETCD_CONFIG_FILE}
EOF
}
