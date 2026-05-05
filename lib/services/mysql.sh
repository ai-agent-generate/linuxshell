has_mysql_client() {
  command_exists mysql
}

write_mysql_config() {
  cat >"$MYSQL_CONFIG_FILE" <<'EOF'
[mysqld]
bind-address=0.0.0.0
server-id=1
log-bin=mysql-bin
binlog_expire_logs_seconds=86400
EOF
}

write_mysql_init_sql() {
  local database="$1"
  local app_user="$2"
  local app_password="$3"

  cat >"$MYSQL_INIT_FILE" <<EOF
CREATE DATABASE IF NOT EXISTS \`${database}\`;
CREATE USER IF NOT EXISTS '${app_user}'@'%' IDENTIFIED BY '${app_password}';
ALTER USER '${app_user}'@'%' IDENTIFIED BY '${app_password}';
GRANT ALL PRIVILEGES ON \`${database}\`.* TO '${app_user}'@'%';
FLUSH PRIVILEGES;
EOF
}

write_mysql_compose() {
  local port="$1"
  local database="$2"
  local app_user="$3"
  local app_password="$4"
  local root_password="$5"

  cat >"$MYSQL_COMPOSE_FILE" <<EOF
name: ${MYSQL_PROJECT_NAME}

services:
  mysql:
    container_name: mysql
    image: ${MYSQL_IMAGE}
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: ${database}
      MYSQL_USER: ${app_user}
      MYSQL_PASSWORD: ${app_password}
      MYSQL_ROOT_PASSWORD: ${root_password}
    ports:
      - "${port}:3306"
    volumes:
      - ${MYSQL_DIR}/data:/var/lib/mysql
      - ${MYSQL_CONFIG_FILE}:/etc/mysql/conf.d/99-custom.cnf:ro
      - ${MYSQL_INIT_FILE}:/docker-entrypoint-initdb.d/01-app-user.sql:ro
    networks:
      default:
        aliases:
          - mysql

networks:
  default:
    external: true
    name: ${SHARED_NETWORK_NAME}
EOF
}

configure_mysql() {
  MYSQL_PORT="$(prompt_with_default "MySQL host port" "$DEFAULT_MYSQL_PORT")"
  MYSQL_DB="$(prompt_with_default "MySQL database name" "$DEFAULT_MYSQL_DB")"
  MYSQL_USER="$(prompt_with_default "MySQL application username" "$DEFAULT_MYSQL_USER")"
  MYSQL_PASSWORD="$(prompt_with_default "MySQL application password" "$DEFAULT_MYSQL_PASSWORD")"
  MYSQL_ROOT_PASSWORD="$(prompt_with_default "MySQL root password" "$DEFAULT_MYSQL_ROOT_PASSWORD")"
}

install_mysql_client() {
  if has_mysql_client; then
    print_step "MySQL client already installed"
    return 0
  fi

  print_step "Installing MySQL client"
  apt-get update
  apt-get install -y default-mysql-client
}

prepare_mysql() {
  local action_status=0

  confirm_overwrite "$MYSQL_COMPOSE_FILE" || action_status=$?
  if [[ "$action_status" -eq 1 ]]; then
    echo "Skipping MySQL compose generation."
    return 0
  fi
  if [[ "$action_status" -eq 2 ]]; then
    start_compose_file "$MYSQL_COMPOSE_FILE" "$MYSQL_PROJECT_NAME"
    return 0
  fi
  if [[ "$action_status" -eq 3 ]]; then
    reinstall_mysql "$MYSQL_PORT" "$MYSQL_DB" "$MYSQL_USER" "$MYSQL_PASSWORD" "$MYSQL_ROOT_PASSWORD"
    return 0
  fi

  assert_port_available "$MYSQL_PORT" "MySQL"
  write_mysql_config
  write_mysql_init_sql "$MYSQL_DB" "$MYSQL_USER" "$MYSQL_PASSWORD"
  write_mysql_compose "$MYSQL_PORT" "$MYSQL_DB" "$MYSQL_USER" "$MYSQL_PASSWORD" "$MYSQL_ROOT_PASSWORD"
  start_compose_file "$MYSQL_COMPOSE_FILE" "$MYSQL_PROJECT_NAME"
}

reinstall_mysql() {
  local port="$1"
  local database="$2"
  local app_user="$3"
  local app_password="$4"
  local root_password="$5"

  if [[ -f "$MYSQL_COMPOSE_FILE" ]]; then
    stop_compose_file "$MYSQL_COMPOSE_FILE" "$MYSQL_PROJECT_NAME"
  fi

  rm -rf "${MYSQL_DIR}/data"
  mkdir -p "${MYSQL_DIR}/data" "${MYSQL_DIR}/conf" "${MYSQL_INIT_DIR}"
  write_mysql_config
  write_mysql_init_sql "$database" "$app_user" "$app_password"
  write_mysql_compose "$port" "$database" "$app_user" "$app_password" "$root_password"
  start_compose_file "$MYSQL_COMPOSE_FILE" "$MYSQL_PROJECT_NAME"
}
