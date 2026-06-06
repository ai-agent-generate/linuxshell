#!/usr/bin/env bash
# lib/pg-ha/haproxy.sh — HAProxy 配置与安装函数

write_haproxy_config() {
  mkdir -p "$(dirname "${PG_HA_HAPROXY_CFG}")"
  cat >"${PG_HA_HAPROXY_CFG}" <<EOF
global
    maxconn 1000
    log /dev/log local0

defaults
    log global
    mode tcp
    retries 2
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 5s

frontend pg_write
    bind *:${PG_HA_PROXY_PORT}
    default_backend pg_primary

backend pg_primary
    option httpchk
    http-check send meth GET uri /primary
    http-check expect status 200
    default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions
    server node1 ${PG_HA_NODE1_IP}:${PG_HA_PG_PORT} check port ${PG_HA_PATRONI_REST_PORT}
    server node2 ${PG_HA_NODE2_IP}:${PG_HA_PG_PORT} check port ${PG_HA_PATRONI_REST_PORT}

listen stats
    bind *:${PG_HA_PROXY_STATS_PORT}
    mode http
    stats enable
    stats uri /
    stats auth admin:${PG_HA_STATS_PASSWORD}
EOF
}

install_haproxy() {
  print_step "Installing HAProxy"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y haproxy
}

start_haproxy() {
  write_haproxy_config
  systemctl enable haproxy
  systemctl restart haproxy
}
