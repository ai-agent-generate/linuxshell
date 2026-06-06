#!/usr/bin/env bash
write_haproxy_config() {
  mkdir -p "$(dirname "${MYSQL_HA_HAPROXY_CFG}")"
  cat >"${MYSQL_HA_HAPROXY_CFG}" <<EOF
global
    maxconn 2000
    log /dev/log local0

defaults
    log global
    mode tcp
    retries 2
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 5s

frontend mysql_write
    bind *:${MYSQL_HA_PROXY_PORT}
    mode tcp
    default_backend mysql_primary

backend mysql_primary
    mode tcp
    option httpchk
    http-check send meth GET uri /
    http-check expect status 200
    default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions
    server node1 ${MYSQL_HA_NODE1_IP}:${MYSQL_HA_MYSQL_PORT} check port ${MYSQL_HA_MYSQLCHK_PORT}
    server node2 ${MYSQL_HA_NODE2_IP}:${MYSQL_HA_MYSQL_PORT} check port ${MYSQL_HA_MYSQLCHK_PORT}

listen stats
    bind *:${MYSQL_HA_PROXY_STATS_PORT}
    mode http
    stats enable
    stats uri /
    stats auth admin:${MYSQL_HA_STATS_PASSWORD}
EOF
  chmod 600 "${MYSQL_HA_HAPROXY_CFG}"
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
