#!/usr/bin/env bash

set -euo pipefail

DATA_ROOT="${DATA_ROOT:-/data}"
DOCKER_DIR="${DOCKER_DIR:-${DATA_ROOT}/docker}"
CADDY_ETC_DIR="${CADDY_ETC_DIR:-/etc/caddy}"
CADDY_MAIN_FILE="${CADDY_MAIN_FILE:-${CADDY_ETC_DIR}/Caddyfile}"
CADDY_CONF_DIR="${CADDY_CONF_DIR:-${CADDY_ETC_DIR}/conf}"
ROOT_HOME="${ROOT_HOME:-/root}"

POSTGRES_DIR="${POSTGRES_DIR:-${DATA_ROOT}/postgres}"
MYSQL_DIR="${MYSQL_DIR:-${DATA_ROOT}/mysql}"
RABBITMQ_DIR="${RABBITMQ_DIR:-${DATA_ROOT}/rabbitmq}"
REDIS_DIR="${REDIS_DIR:-${DATA_ROOT}/redis}"

POSTGRES_COMPOSE_FILE="${POSTGRES_COMPOSE_FILE:-${DOCKER_DIR}/docker-postgres.yml}"
MYSQL_COMPOSE_FILE="${MYSQL_COMPOSE_FILE:-${DOCKER_DIR}/docker-mysql.yml}"
RABBITMQ_COMPOSE_FILE="${RABBITMQ_COMPOSE_FILE:-${DOCKER_DIR}/docker-rabbitmq.yml}"
REDIS_COMPOSE_FILE="${REDIS_COMPOSE_FILE:-${DOCKER_DIR}/docker-redis.yml}"
MYSQL_CONFIG_FILE="${MYSQL_CONFIG_FILE:-${MYSQL_DIR}/conf/my.cnf}"
MYSQL_INIT_DIR="${MYSQL_INIT_DIR:-${MYSQL_DIR}/init}"
MYSQL_INIT_FILE="${MYSQL_INIT_FILE:-${MYSQL_INIT_DIR}/01-app-user.sql}"
RABBITMQ_CONF_DIR="${RABBITMQ_CONF_DIR:-${RABBITMQ_DIR}/conf}"
RABBITMQ_CONFIG_FILE="${RABBITMQ_CONFIG_FILE:-${RABBITMQ_CONF_DIR}/rabbitmq.conf}"
RABBITMQ_ENABLED_PLUGINS_FILE="${RABBITMQ_ENABLED_PLUGINS_FILE:-${RABBITMQ_CONF_DIR}/enabled_plugins}"

POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18.3}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.4.8}"
RABBITMQ_IMAGE="${RABBITMQ_IMAGE:-rabbitmq:management}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:8.6.1}"

DEFAULT_POSTGRES_PORT="${DEFAULT_POSTGRES_PORT:-5432}"
DEFAULT_POSTGRES_DB="${DEFAULT_POSTGRES_DB:-appdb}"
DEFAULT_POSTGRES_USER="${DEFAULT_POSTGRES_USER:-postgres}"
DEFAULT_POSTGRES_PASSWORD="${DEFAULT_POSTGRES_PASSWORD:-postgres123}"

DEFAULT_MYSQL_PORT="${DEFAULT_MYSQL_PORT:-3306}"
DEFAULT_MYSQL_DB="${DEFAULT_MYSQL_DB:-appdb}"
DEFAULT_MYSQL_USER="${DEFAULT_MYSQL_USER:-app}"
DEFAULT_MYSQL_PASSWORD="${DEFAULT_MYSQL_PASSWORD:-app123}"
DEFAULT_MYSQL_ROOT_PASSWORD="${DEFAULT_MYSQL_ROOT_PASSWORD:-root123}"

DEFAULT_RABBITMQ_PORT="${DEFAULT_RABBITMQ_PORT:-5672}"
DEFAULT_RABBITMQ_MANAGEMENT_PORT="${DEFAULT_RABBITMQ_MANAGEMENT_PORT:-15672}"
DEFAULT_RABBITMQ_WEB_STOMP_PORT="${DEFAULT_RABBITMQ_WEB_STOMP_PORT:-15674}"
DEFAULT_RABBITMQ_USER="${DEFAULT_RABBITMQ_USER:-admin}"
DEFAULT_RABBITMQ_PASSWORD="${DEFAULT_RABBITMQ_PASSWORD:-admin123}"

DEFAULT_REDIS_PORT="${DEFAULT_REDIS_PORT:-6379}"
DEFAULT_REDIS_PASSWORD="${DEFAULT_REDIS_PASSWORD:-}"

SELECT_CADDY=0
SELECT_POSTGRES=0
SELECT_MYSQL=0
SELECT_RABBITMQ=0
SELECT_REDIS=0

POSTGRES_PORT="$DEFAULT_POSTGRES_PORT"
POSTGRES_DB="$DEFAULT_POSTGRES_DB"
POSTGRES_USER="$DEFAULT_POSTGRES_USER"
POSTGRES_PASSWORD="$DEFAULT_POSTGRES_PASSWORD"

MYSQL_PORT="$DEFAULT_MYSQL_PORT"
MYSQL_DB="$DEFAULT_MYSQL_DB"
MYSQL_USER="$DEFAULT_MYSQL_USER"
MYSQL_PASSWORD="$DEFAULT_MYSQL_PASSWORD"
MYSQL_ROOT_PASSWORD="$DEFAULT_MYSQL_ROOT_PASSWORD"

RABBITMQ_PORT="$DEFAULT_RABBITMQ_PORT"
RABBITMQ_MANAGEMENT_PORT="$DEFAULT_RABBITMQ_MANAGEMENT_PORT"
RABBITMQ_WEB_STOMP_PORT="$DEFAULT_RABBITMQ_WEB_STOMP_PORT"
RABBITMQ_USER="$DEFAULT_RABBITMQ_USER"
RABBITMQ_PASSWORD="$DEFAULT_RABBITMQ_PASSWORD"

REDIS_PORT="$DEFAULT_REDIS_PORT"
REDIS_PASSWORD="$DEFAULT_REDIS_PASSWORD"

POSTGRES_PROJECT_NAME="${POSTGRES_PROJECT_NAME:-postgres}"
MYSQL_PROJECT_NAME="${MYSQL_PROJECT_NAME:-mysql}"
RABBITMQ_PROJECT_NAME="${RABBITMQ_PROJECT_NAME:-rabbitmq}"
REDIS_PROJECT_NAME="${REDIS_PROJECT_NAME:-redis}"
SHARED_NETWORK_NAME="${SHARED_NETWORK_NAME:-my_network}"

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    return 1
  fi
}

detect_os() {
  if [[ ! -r /etc/os-release ]]; then
    echo "Cannot detect operating system." >&2
    return 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian)
      return 0
      ;;
    *)
      echo "Only Ubuntu/Debian systems are supported." >&2
      return 1
      ;;
  esac
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

to_lower() {
  printf "%s" "$1" | tr '[:upper:]' '[:lower:]'
}

print_step() {
  echo
  echo "==> $*"
}

ensure_data_root_writable() {
  mkdir -p "$DATA_ROOT"
  if [[ ! -w "$DATA_ROOT" ]]; then
    echo "Data root is not writable: $DATA_ROOT" >&2
    return 1
  fi
}

ensure_directories() {
  mkdir -p "$DOCKER_DIR"
  mkdir -p "${POSTGRES_DIR}"
  mkdir -p "${MYSQL_DIR}/data" "${MYSQL_DIR}/conf" "${MYSQL_DIR}/env" "${MYSQL_INIT_DIR}"
  mkdir -p "${RABBITMQ_DIR}/data" "${RABBITMQ_CONF_DIR}"
  mkdir -p "${REDIS_DIR}/data"
}

configure_caddy_layout() {
  mkdir -p "$CADDY_CONF_DIR"
  printf "import %s/*\n" "$CADDY_CONF_DIR" >"$CADDY_MAIN_FILE"
  ln -sfn "$CADDY_CONF_DIR" "$ROOT_HOME"
}

prompt_with_default() {
  local prompt_text="$1"
  local default_value="$2"
  local answer

  if [[ -n "$default_value" ]]; then
    printf "%s [%s]: " "$prompt_text" "$default_value" >&2
  else
    printf "%s: " "$prompt_text" >&2
  fi

  IFS= read -r answer
  if [[ -z "$answer" ]]; then
    printf "%s" "$default_value"
  else
    printf "%s" "$answer"
  fi
}

prompt_yes_no() {
  local prompt_text="$1"
  local default_answer="${2:-y}"
  local answer
  local normalized

  while true; do
    if [[ "$default_answer" == "y" ]]; then
      printf "%s [Y/n]: " "$prompt_text"
    else
      printf "%s [y/N]: " "$prompt_text"
    fi

    IFS= read -r answer
    answer="${answer:-$default_answer}"
    normalized="$(to_lower "$answer")"

    case "$normalized" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

parse_service_selection() {
  local selection="${1//,/ }"
  local token
  local normalized

  SELECT_CADDY=0
  SELECT_POSTGRES=0
  SELECT_MYSQL=0
  SELECT_RABBITMQ=0
  SELECT_REDIS=0

  for token in $selection; do
    normalized="$(to_lower "$token")"
    case "$normalized" in
      1|caddy)
        SELECT_CADDY=1
        ;;
      2|postgres|postgresql)
        SELECT_POSTGRES=1
        ;;
      3|mysql)
        SELECT_MYSQL=1
        ;;
      4|rabbitmq)
        SELECT_RABBITMQ=1
        ;;
      5|redis)
        SELECT_REDIS=1
        ;;
      *)
        echo "Ignoring unknown selection: $token" >&2
        ;;
    esac
  done
}

collect_service_selection() {
  local selection

  cat <<'EOF'
Select one or more components to install/deploy (space-separated or comma-separated):
  1) Caddy
  2) PostgreSQL
  3) MySQL
  4) RabbitMQ
  5) Redis
EOF

  while true; do
    printf "Selection: "
    IFS= read -r selection
    parse_service_selection "$selection"

    if (( SELECT_CADDY || SELECT_POSTGRES || SELECT_MYSQL || SELECT_RABBITMQ || SELECT_REDIS )); then
      return 0
    fi

    echo "Please choose at least one component." >&2
  done
}

has_mysql_client() {
  command_exists mysql
}

port_in_use() {
  local port="$1"
  if command_exists ss; then
    ss -ltn "( sport = :${port} )" | grep -q ":${port} "
  elif command_exists netstat; then
    netstat -ltn 2>/dev/null | grep -q "[\.:]${port} "
  else
    return 1
  fi
}

assert_port_available() {
  local port="$1"
  local label="$2"

  if port_in_use "$port"; then
    echo "Port ${port} is already in use for ${label}." >&2
    return 1
  fi
}

confirm_overwrite() {
  local target="$1"
  local answer
  local normalized

  if [[ ! -f "$target" ]]; then
    return 0
  fi

  echo "File already exists: $target"
  while true; do
    printf "Choose action: [s]kip, [o]verwrite, [u]se existing, [r]einstall: "
    IFS= read -r answer
    normalized="$(to_lower "$answer")"
    case "$normalized" in
      s|skip)
        return 1
        ;;
      o|overwrite|"")
        return 0
        ;;
      u|use)
        return 2
        ;;
      r|reinstall)
        return 3
        ;;
      *)
        echo "Please enter s, o, u, or r." >&2
        ;;
    esac
  done
}

write_postgres_compose() {
  local port="$1"
  local database="$2"
  local username="$3"
  local password="$4"

  cat >"$POSTGRES_COMPOSE_FILE" <<EOF
name: ${POSTGRES_PROJECT_NAME}

services:
  postgres:
    container_name: postgres
    image: ${POSTGRES_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${database}
      POSTGRES_USER: ${username}
      POSTGRES_PASSWORD: ${password}
    ports:
      - "${port}:5432"
    volumes:
      - ${POSTGRES_DIR}:/var/lib/postgresql
    networks:
      default:
        aliases:
          - postgres

networks:
  default:
    external: true
    name: ${SHARED_NETWORK_NAME}
EOF
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

write_rabbitmq_compose() {
  local amqp_port="$1"
  local management_port="$2"
  local web_stomp_port="$3"
  local username="$4"
  local password="$5"

  write_rabbitmq_config "$username" "$password"
  write_rabbitmq_enabled_plugins

  cat >"$RABBITMQ_COMPOSE_FILE" <<EOF
name: ${RABBITMQ_PROJECT_NAME}

services:
  rabbitmq:
    container_name: rabbitmq
    image: ${RABBITMQ_IMAGE}
    restart: unless-stopped
    ports:
      - "${amqp_port}:5672"
      - "${management_port}:15672"
      - "${web_stomp_port}:15674"
    volumes:
      - ${RABBITMQ_DIR}/data:/var/lib/rabbitmq
      - ${RABBITMQ_CONFIG_FILE}:/etc/rabbitmq/rabbitmq.conf:ro
      - ${RABBITMQ_ENABLED_PLUGINS_FILE}:/etc/rabbitmq/enabled_plugins:ro
    networks:
      default:
        aliases:
          - rabbitmq

networks:
  default:
    external: true
    name: ${SHARED_NETWORK_NAME}
EOF
}

write_rabbitmq_config() {
  local username="$1"
  local password="$2"

  cat >"$RABBITMQ_CONFIG_FILE" <<EOF
default_user = ${username}
default_pass = ${password}
EOF
}

write_rabbitmq_enabled_plugins() {
  cat >"$RABBITMQ_ENABLED_PLUGINS_FILE" <<'EOF'
[rabbitmq_management,rabbitmq_prometheus,rabbitmq_top,rabbitmq_tracing,rabbitmq_stomp,rabbitmq_web_stomp].
EOF
}

write_redis_compose() {
  local port="$1"
  local password="${2:-}"
  local command="redis-server --appendonly yes"

  if [[ -n "$password" ]]; then
    command="${command} --requirepass ${password}"
  fi

  cat >"$REDIS_COMPOSE_FILE" <<EOF
name: ${REDIS_PROJECT_NAME}

services:
  redis:
    container_name: redis
    image: ${REDIS_IMAGE}
    restart: unless-stopped
    command: ${command}
    ports:
      - "${port}:6379"
    volumes:
      - ${REDIS_DIR}/data:/data
    networks:
      default:
        aliases:
          - redis

networks:
  default:
    external: true
    name: ${SHARED_NETWORK_NAME}
EOF
}

get_postgres_major_version() {
  local tag="${POSTGRES_IMAGE##*:}"
  printf "%s" "${tag%%.*}"
}

configure_postgres() {
  POSTGRES_PORT="$(prompt_with_default "PostgreSQL host port" "$DEFAULT_POSTGRES_PORT")"
  POSTGRES_DB="$(prompt_with_default "PostgreSQL database name" "$DEFAULT_POSTGRES_DB")"
  POSTGRES_USER="$(prompt_with_default "PostgreSQL username" "$DEFAULT_POSTGRES_USER")"
  POSTGRES_PASSWORD="$(prompt_with_default "PostgreSQL password" "$DEFAULT_POSTGRES_PASSWORD")"
}

configure_mysql() {
  MYSQL_PORT="$(prompt_with_default "MySQL host port" "$DEFAULT_MYSQL_PORT")"
  MYSQL_DB="$(prompt_with_default "MySQL database name" "$DEFAULT_MYSQL_DB")"
  MYSQL_USER="$(prompt_with_default "MySQL application username" "$DEFAULT_MYSQL_USER")"
  MYSQL_PASSWORD="$(prompt_with_default "MySQL application password" "$DEFAULT_MYSQL_PASSWORD")"
  MYSQL_ROOT_PASSWORD="$(prompt_with_default "MySQL root password" "$DEFAULT_MYSQL_ROOT_PASSWORD")"
}

configure_rabbitmq() {
  RABBITMQ_PORT="$(prompt_with_default "RabbitMQ AMQP port" "$DEFAULT_RABBITMQ_PORT")"
  RABBITMQ_MANAGEMENT_PORT="$(prompt_with_default "RabbitMQ management port" "$DEFAULT_RABBITMQ_MANAGEMENT_PORT")"
  RABBITMQ_WEB_STOMP_PORT="$(prompt_with_default "RabbitMQ Web STOMP port" "$DEFAULT_RABBITMQ_WEB_STOMP_PORT")"
  RABBITMQ_USER="$(prompt_with_default "RabbitMQ username" "$DEFAULT_RABBITMQ_USER")"
  RABBITMQ_PASSWORD="$(prompt_with_default "RabbitMQ password" "$DEFAULT_RABBITMQ_PASSWORD")"
}

configure_redis() {
  REDIS_PORT="$(prompt_with_default "Redis host port" "$DEFAULT_REDIS_PORT")"
  REDIS_PASSWORD="$(prompt_with_default "Redis password (leave blank for no password)" "$DEFAULT_REDIS_PASSWORD")"
}

install_apt_dependencies() {
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release
}

install_docker() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    print_step "Docker and Docker Compose plugin already installed"
    return 0
  fi

  print_step "Installing Docker"
  install_apt_dependencies
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/"$(. /etc/os-release && echo "$ID")"/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  . /etc/os-release
  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable
EOF

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_caddy() {
  if command_exists caddy; then
    print_step "Caddy already installed"
  else
    print_step "Installing Caddy"
    install_apt_dependencies
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
  fi

  configure_caddy_layout
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

ensure_shared_network() {
  if ! docker network inspect "$SHARED_NETWORK_NAME" >/dev/null 2>&1; then
    docker network create "$SHARED_NETWORK_NAME" >/dev/null
  fi
}

start_compose_file() {
  local compose_file="$1"
  local project_name="$2"
  ensure_shared_network
  docker compose -p "$project_name" -f "$compose_file" up -d
}

stop_compose_file() {
  local compose_file="$1"
  local project_name="$2"
  docker compose -p "$project_name" -f "$compose_file" down --remove-orphans
}

reinstall_postgres() {
  local port="$1"
  local database="$2"
  local username="$3"
  local password="$4"
  local action
  local pg_major

  echo "PostgreSQL reinstall options:"
  echo "  [c]lean   - Delete all existing data and start fresh"
  echo "  [m]igrate - Move existing data to PG 18+ directory structure (preserves data)"

  while true; do
    printf "Choose: [c]lean or [m]igrate: "
    IFS= read -r action
    case "$(to_lower "$action")" in
      c|clean)
        if [[ -f "$POSTGRES_COMPOSE_FILE" ]]; then
          stop_compose_file "$POSTGRES_COMPOSE_FILE" "$POSTGRES_PROJECT_NAME"
        fi
        rm -rf "${POSTGRES_DIR}"
        mkdir -p "${POSTGRES_DIR}"
        write_postgres_compose "$port" "$database" "$username" "$password"
        start_compose_file "$POSTGRES_COMPOSE_FILE" "$POSTGRES_PROJECT_NAME"
        return 0
        ;;
      m|migrate)
        if [[ ! -d "${POSTGRES_DIR}/data" ]]; then
          echo "No data directory found at ${POSTGRES_DIR}/data, nothing to migrate." >&2
          return 1
        fi
        pg_major="$(get_postgres_major_version)"
        if [[ -f "$POSTGRES_COMPOSE_FILE" ]]; then
          stop_compose_file "$POSTGRES_COMPOSE_FILE" "$POSTGRES_PROJECT_NAME"
        fi
        mkdir -p "${POSTGRES_DIR}/${pg_major}"
        mv "${POSTGRES_DIR}/data" "${POSTGRES_DIR}/${pg_major}/main"
        echo "Migrated: ${POSTGRES_DIR}/data -> ${POSTGRES_DIR}/${pg_major}/main"
        write_postgres_compose "$port" "$database" "$username" "$password"
        start_compose_file "$POSTGRES_COMPOSE_FILE" "$POSTGRES_PROJECT_NAME"
        return 0
        ;;
      *)
        echo "Please enter c or m." >&2
        ;;
    esac
  done
}

prepare_postgres() {
  local action_status=0

  confirm_overwrite "$POSTGRES_COMPOSE_FILE" || action_status=$?
  if [[ "$action_status" -eq 1 ]]; then
    echo "Skipping PostgreSQL compose generation."
    return 0
  fi
  if [[ "$action_status" -eq 2 ]]; then
    start_compose_file "$POSTGRES_COMPOSE_FILE" "$POSTGRES_PROJECT_NAME"
    return 0
  fi
  if [[ "$action_status" -eq 3 ]]; then
    reinstall_postgres "$POSTGRES_PORT" "$POSTGRES_DB" "$POSTGRES_USER" "$POSTGRES_PASSWORD"
    return 0
  fi

  assert_port_available "$POSTGRES_PORT" "PostgreSQL"
  write_postgres_compose "$POSTGRES_PORT" "$POSTGRES_DB" "$POSTGRES_USER" "$POSTGRES_PASSWORD"
  start_compose_file "$POSTGRES_COMPOSE_FILE" "$POSTGRES_PROJECT_NAME"
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

prepare_rabbitmq() {
  local action_status=0

  confirm_overwrite "$RABBITMQ_COMPOSE_FILE" || action_status=$?
  if [[ "$action_status" -eq 1 ]]; then
    echo "Skipping RabbitMQ compose generation."
    return 0
  fi
  if [[ "$action_status" -eq 2 ]]; then
    start_compose_file "$RABBITMQ_COMPOSE_FILE" "$RABBITMQ_PROJECT_NAME"
    return 0
  fi
  if [[ "$action_status" -eq 3 ]]; then
    reinstall_rabbitmq "$RABBITMQ_PORT" "$RABBITMQ_MANAGEMENT_PORT" "$RABBITMQ_WEB_STOMP_PORT" "$RABBITMQ_USER" "$RABBITMQ_PASSWORD"
    return 0
  fi

  assert_port_available "$RABBITMQ_PORT" "RabbitMQ"
  assert_port_available "$RABBITMQ_MANAGEMENT_PORT" "RabbitMQ management"
  assert_port_available "$RABBITMQ_WEB_STOMP_PORT" "RabbitMQ Web STOMP"
  write_rabbitmq_compose "$RABBITMQ_PORT" "$RABBITMQ_MANAGEMENT_PORT" "$RABBITMQ_WEB_STOMP_PORT" "$RABBITMQ_USER" "$RABBITMQ_PASSWORD"
  start_compose_file "$RABBITMQ_COMPOSE_FILE" "$RABBITMQ_PROJECT_NAME"
}

reinstall_rabbitmq() {
  local amqp_port="$1"
  local management_port="$2"
  local web_stomp_port="$3"
  local username="$4"
  local password="$5"

  if [[ -f "$RABBITMQ_COMPOSE_FILE" ]]; then
    stop_compose_file "$RABBITMQ_COMPOSE_FILE" "$RABBITMQ_PROJECT_NAME"
  fi

  rm -rf "${RABBITMQ_DIR}/data"
  mkdir -p "${RABBITMQ_DIR}/data" "${RABBITMQ_CONF_DIR}"
  write_rabbitmq_compose "$amqp_port" "$management_port" "$web_stomp_port" "$username" "$password"
  start_compose_file "$RABBITMQ_COMPOSE_FILE" "$RABBITMQ_PROJECT_NAME"
}

prepare_redis() {
  local action_status=0

  confirm_overwrite "$REDIS_COMPOSE_FILE" || action_status=$?
  if [[ "$action_status" -eq 1 ]]; then
    echo "Skipping Redis compose generation."
    return 0
  fi
  if [[ "$action_status" -eq 2 ]]; then
    start_compose_file "$REDIS_COMPOSE_FILE" "$REDIS_PROJECT_NAME"
    return 0
  fi

  assert_port_available "$REDIS_PORT" "Redis"
  write_redis_compose "$REDIS_PORT" "$REDIS_PASSWORD"
  start_compose_file "$REDIS_COMPOSE_FILE" "$REDIS_PROJECT_NAME"
}

show_summary() {
  print_step "Deployment summary"

  if (( SELECT_CADDY )); then
    echo "Caddy installed via apt."
  fi
  if (( SELECT_POSTGRES )); then
    echo "PostgreSQL: ${POSTGRES_COMPOSE_FILE} | data ${POSTGRES_DIR} | port ${POSTGRES_PORT} | user ${POSTGRES_USER} | network ${SHARED_NETWORK_NAME}"
  fi
  if (( SELECT_MYSQL )); then
    echo "MySQL: ${MYSQL_COMPOSE_FILE} | data ${MYSQL_DIR}/data | config ${MYSQL_CONFIG_FILE} | port ${MYSQL_PORT} | user ${MYSQL_USER} | network ${SHARED_NETWORK_NAME}"
  fi
  if (( SELECT_RABBITMQ )); then
    echo "RabbitMQ: ${RABBITMQ_COMPOSE_FILE} | data ${RABBITMQ_DIR}/data | amqp ${RABBITMQ_PORT} | ui ${RABBITMQ_MANAGEMENT_PORT} | web-stomp ${RABBITMQ_WEB_STOMP_PORT} | network ${SHARED_NETWORK_NAME}"
  fi
  if (( SELECT_REDIS )); then
    echo "Redis: ${REDIS_COMPOSE_FILE} | data ${REDIS_DIR}/data | port ${REDIS_PORT} | network ${SHARED_NETWORK_NAME}"
  fi
}

main() {
  require_root
  detect_os
  ensure_data_root_writable
  ensure_directories
  collect_service_selection

  if (( SELECT_CADDY || SELECT_POSTGRES || SELECT_MYSQL || SELECT_RABBITMQ || SELECT_REDIS )); then
    install_docker
  fi

  if (( SELECT_CADDY )); then
    install_caddy
  fi

  if (( SELECT_POSTGRES )); then
    configure_postgres
    prepare_postgres
  fi

  if (( SELECT_MYSQL )); then
    configure_mysql
    prepare_mysql
    if ! has_mysql_client && prompt_yes_no "Install MySQL client on the host?" "y"; then
      install_mysql_client
    fi
  fi

  if (( SELECT_RABBITMQ )); then
    configure_rabbitmq
    prepare_rabbitmq
  fi

  if (( SELECT_REDIS )); then
    configure_redis
    prepare_redis
  fi

  show_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
