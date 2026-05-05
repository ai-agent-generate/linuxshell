#!/usr/bin/env bash

set -euo pipefail

LINUXSHELL_RAW_BASE_URL="${LINUXSHELL_RAW_BASE_URL:-https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main}"
LINUXSHELL_MODULE_ROOT=""
LINUXSHELL_MODULE_SOURCE=""

load_linuxshell_modules() {
  local script_dir
  local module_root
  local module

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || pwd)"
  module_root="$script_dir"

  if [[ -f "${module_root}/lib/config.sh" ]]; then
    LINUXSHELL_MODULE_SOURCE="local"
  else
    module_root="$(mktemp -d)"
    LINUXSHELL_MODULE_SOURCE="remote"
    for module in "$@"; do
      mkdir -p "${module_root}/$(dirname "$module")"
      if ! curl -fsSL "${LINUXSHELL_RAW_BASE_URL}/${module}" -o "${module_root}/${module}"; then
        echo "Failed to download module: ${LINUXSHELL_RAW_BASE_URL}/${module}" >&2
        return 1
      fi
    done
  fi

  LINUXSHELL_MODULE_ROOT="$module_root"
  for module in "$@"; do
    # shellcheck disable=SC1090
    source "${module_root}/${module}"
  done
}

load_linuxshell_modules \
  lib/config.sh \
  lib/common.sh \
  lib/docker.sh \
  lib/caddy.sh \
  lib/compose.sh \
  lib/pg-wrapper.sh \
  lib/services/postgres.sh \
  lib/services/mysql.sh \
  lib/services/rabbitmq.sh \
  lib/services/redis.sh

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
SELECT_PG_WRAPPER=0
SELECT_DOCKER=0

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
PG_WRAPPER_BIN="${PG_WRAPPER_BIN:-/usr/local/bin/pg}"
INSTALLED_PG_WRAPPER_USER=""

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
  SELECT_PG_WRAPPER=0
  SELECT_DOCKER=0

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
      6|pg|pg-shortcut)
        SELECT_PG_WRAPPER=1
        ;;
      7|docker)
        SELECT_DOCKER=1
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
  6) Install pg shortcut (PostgreSQL already running)
  7) Docker only
EOF

  while true; do
    printf "Selection: "
    IFS= read -r selection
    parse_service_selection "$selection"

    if (( SELECT_CADDY || SELECT_POSTGRES || SELECT_MYSQL || SELECT_RABBITMQ || SELECT_REDIS || SELECT_PG_WRAPPER || SELECT_DOCKER )); then
      return 0
    fi

    echo "Please choose at least one component." >&2
  done
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

show_summary() {
  print_step "Deployment summary"

  if (( SELECT_CADDY )); then
    echo "Caddy installed via apt."
  fi
  if (( SELECT_DOCKER )); then
    echo "Docker and Docker Compose plugin installed."
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
  if [[ -n "$INSTALLED_PG_WRAPPER_USER" ]]; then
    echo "pg shortcut: ${PG_WRAPPER_BIN} (user: ${INSTALLED_PG_WRAPPER_USER})"
  fi
}

main() {
  require_root
  detect_os
  ensure_data_root_writable
  ensure_directories
  collect_service_selection

  if (( SELECT_DOCKER || SELECT_CADDY || SELECT_POSTGRES || SELECT_MYSQL || SELECT_RABBITMQ || SELECT_REDIS )); then
    install_docker
  fi

  if (( SELECT_CADDY )); then
    install_caddy
  fi

  if (( SELECT_POSTGRES )); then
    configure_postgres
    prepare_postgres
    install_pg_wrapper "$POSTGRES_USER"
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

  if (( SELECT_PG_WRAPPER && ! SELECT_POSTGRES )); then
    local wrapper_user
    wrapper_user="$(prompt_with_default "PostgreSQL username to bake into 'pg'" "postgres")"
    install_pg_wrapper "$wrapper_user"
  fi

  show_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
