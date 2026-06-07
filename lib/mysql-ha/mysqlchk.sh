#!/usr/bin/env bash
write_mysqlchk_script() {
  mkdir -p "$(dirname "${MYSQL_HA_MYSQLCHK_SCRIPT}")"
  # 首段含可变路径(展开);第二段固定逻辑(单引号 heredoc 不展开)
  cat >"${MYSQL_HA_MYSQLCHK_SCRIPT}" <<EOF
#!/usr/bin/env bash
# mysqlchk:当前可写主库(read_only=0)返回 200,否则 503。供 HAProxy option httpchk 探测。
DEFAULTS_FILE="${MYSQL_HA_MYSQLCHK_CNF}"
EOF
  cat >>"${MYSQL_HA_MYSQLCHK_SCRIPT}" <<'EOF'
while IFS= read -r -t 0.2 line; do
  [[ "$line" == $'\r' || -z "$line" ]] && break
done

RO="$(mysql --defaults-extra-file="$DEFAULTS_FILE" -N -B -e 'SELECT @@global.read_only' 2>/dev/null)"
if [[ "$RO" == "0" ]]; then
  BODY="MySQL writable primary"
  STATUS="HTTP/1.1 200 OK"
else
  BODY="MySQL not writable"
  STATUS="HTTP/1.1 503 Service Unavailable"
fi
printf '%s\r\n' "$STATUS"
printf 'Content-Type: text/plain\r\n'
printf 'Connection: close\r\n'
printf 'Content-Length: %s\r\n' "${#BODY}"
printf '\r\n'
printf '%s' "$BODY"
EOF
  chmod 755 "${MYSQL_HA_MYSQLCHK_SCRIPT}"
}

write_mysqlchk_cnf() {
  mkdir -p "$(dirname "${MYSQL_HA_MYSQLCHK_CNF}")"
  cat >"${MYSQL_HA_MYSQLCHK_CNF}" <<EOF
[client]
user=mysqlchk
password=${MYSQL_HA_MYSQLCHK_PASSWORD}
socket=${MYSQL_HA_MYSQL_SOCKET}
EOF
  chmod 600 "${MYSQL_HA_MYSQLCHK_CNF}"
  chown "${MYSQL_HA_SERVICE_USER}:${MYSQL_HA_SERVICE_USER}" "${MYSQL_HA_MYSQLCHK_CNF}" 2>/dev/null || true
}

write_mysqlchk_socket_unit() {
  mkdir -p "$(dirname "${MYSQL_HA_MYSQLCHK_SOCKET}")"
  cat >"${MYSQL_HA_MYSQLCHK_SOCKET}" <<EOF
[Unit]
Description=mysqlchk health check socket

[Socket]
ListenStream=${MYSQL_HA_NODE_IP}:${MYSQL_HA_MYSQLCHK_PORT}
Accept=yes

[Install]
WantedBy=sockets.target
EOF
}

write_mysqlchk_service_unit() {
  mkdir -p "$(dirname "${MYSQL_HA_MYSQLCHK_SERVICE}")"
  cat >"${MYSQL_HA_MYSQLCHK_SERVICE}" <<EOF
[Unit]
Description=mysqlchk health check responder

[Service]
ExecStart=${MYSQL_HA_MYSQLCHK_SCRIPT}
StandardInput=socket
StandardOutput=socket
User=${MYSQL_HA_SERVICE_USER}
EOF
}

setup_mysqlchk() {
  write_mysqlchk_script
  write_mysqlchk_cnf
  write_mysqlchk_socket_unit
  write_mysqlchk_service_unit
}

start_mysqlchk() {
  systemctl daemon-reload
  systemctl enable --now mysqlchk.socket
}
