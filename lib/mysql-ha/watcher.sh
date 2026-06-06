#!/usr/bin/env bash
write_watcher_script() {
  mkdir -p "$(dirname "${MYSQL_HA_WATCHER_SCRIPT}")"
  cat >"${MYSQL_HA_WATCHER_SCRIPT}" <<EOF
#!/usr/bin/env bash
# mysql-ha-watcher:补足 Orchestrator 稳态可写性 + 失 raft 多数票自我隔离。
# 凭据从 600 的 cnf 读取(脚本不含密码)。
CNF="${MYSQL_HA_WATCHER_CNF}"
ORCH="http://127.0.0.1:${MYSQL_HA_ORCH_PORT}"
CLUSTER="${MYSQL_HA_CLUSTER_NAME}"
SELF_IP="${MYSQL_HA_NODE_IP}"
INTERVAL="${MYSQL_HA_WATCHER_INTERVAL}"
EOF
  cat >>"${MYSQL_HA_WATCHER_SCRIPT}" <<'EOF'

http_pass="$(awk -F'=' '/^\[orchestrator\]/{f=1} f&&/http_password/{gsub(/[ \t]/,"",$2);print $2;exit}' "$CNF")"
ORCH_USER="admin"

orch_get() { # $1=api path
  curl -fsS --netrc-file <(printf 'machine 127.0.0.1 login %s password %s\n' "$ORCH_USER" "$http_pass") \
    "${ORCH}/$1" 2>/dev/null
}
make_writable() { mysql --defaults-extra-file="$CNF" -e "SET GLOBAL read_only=OFF" 2>/dev/null || true; }
self_fence()   { mysql --defaults-extra-file="$CNF" -e "SET GLOBAL super_read_only=ON" 2>/dev/null || true; }

while true; do
  raft="$(orch_get 'api/raft-health')"
  if [[ -z "$raft" ]] || ! printf '%s' "$raft" | grep -qi 'healthy'; then
    # 本机失去 raft 多数视角(分区/orchestrator 不可达)→ 自我隔离
    self_fence
    sleep "$INTERVAL"; continue
  fi
  master_json="$(orch_get "api/master/${CLUSTER}")"
  master_host="$(printf '%s' "$master_json" | grep -oE '"Hostname"[^,]*' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"
  if [[ "$master_host" == "$SELF_IP" ]]; then
    make_writable      # 本机是当前主 → 收敛为可写
  else
    self_fence         # 别人是主/未知 → 保守置只读
  fi
  sleep "$INTERVAL"
done
EOF
  chmod 755 "${MYSQL_HA_WATCHER_SCRIPT}"
}

write_watcher_cnf() {
  mkdir -p "$(dirname "${MYSQL_HA_WATCHER_CNF}")"
  cat >"${MYSQL_HA_WATCHER_CNF}" <<EOF
[client]
user=watcher
password=${MYSQL_HA_WATCHER_PASSWORD}
socket=${MYSQL_HA_MYSQL_SOCKET}

[orchestrator]
http_user = admin
http_password = ${MYSQL_HA_ORCH_HTTP_PASSWORD}
EOF
  chmod 600 "${MYSQL_HA_WATCHER_CNF}"
  chown "${MYSQL_HA_SERVICE_USER}:${MYSQL_HA_SERVICE_USER}" "${MYSQL_HA_WATCHER_CNF}" 2>/dev/null || true
}

write_watcher_unit() {
  mkdir -p "$(dirname "${MYSQL_HA_WATCHER_UNIT}")"
  cat >"${MYSQL_HA_WATCHER_UNIT}" <<EOF
[Unit]
Description=mysql-ha-watcher (writability convergence + self-fence)
After=network-online.target mysql.service orchestrator.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MYSQL_HA_WATCHER_SCRIPT}
Restart=always
RestartSec=2
User=${MYSQL_HA_SERVICE_USER}

[Install]
WantedBy=multi-user.target
EOF
}

setup_watcher() {
  write_watcher_script
  write_watcher_cnf
  write_watcher_unit
}

start_watcher() {
  systemctl daemon-reload
  systemctl enable --now mysql-ha-watcher.service
}
