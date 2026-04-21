#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SCRIPT="${ROOT_DIR}/deploy.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || fail "expected file to exist: $path"
}

assert_function_exists() {
  local fn_name="$1"
  declare -F "$fn_name" >/dev/null || fail "expected function to exist: $fn_name"
}

assert_contains() {
  local path="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$path" || fail "expected '$expected' in $path"
}

assert_not_contains() {
  local path="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$path"; then
    fail "did not expect '$unexpected' in $path"
  fi
}

assert_output_contains() {
  local output="$1"
  local expected="$2"
  [[ "$output" == *"$expected"* ]] || fail "expected output to contain '$expected'"
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  [[ "$expected" == "$actual" ]] || fail "expected '$expected' but got '$actual'"
}

load_script() {
  local preserved_data_root="${DATA_ROOT-__UNSET__}"
  local preserved_caddy_etc_dir="${CADDY_ETC_DIR-__UNSET__}"
  local preserved_caddy_main_file="${CADDY_MAIN_FILE-__UNSET__}"
  local preserved_caddy_conf_dir="${CADDY_CONF_DIR-__UNSET__}"
  local preserved_root_home="${ROOT_HOME-__UNSET__}"
  local preserved_rabbitmq_conf_dir="${RABBITMQ_CONF_DIR-__UNSET__}"
  local preserved_rabbitmq_config_file="${RABBITMQ_CONFIG_FILE-__UNSET__}"
  local preserved_rabbitmq_plugins_file="${RABBITMQ_ENABLED_PLUGINS_FILE-__UNSET__}"
  unset \
    DOCKER_DIR \
    CADDY_ETC_DIR CADDY_MAIN_FILE CADDY_CONF_DIR ROOT_HOME \
    POSTGRES_DIR MYSQL_DIR RABBITMQ_DIR REDIS_DIR \
    POSTGRES_COMPOSE_FILE MYSQL_COMPOSE_FILE RABBITMQ_COMPOSE_FILE REDIS_COMPOSE_FILE \
    MYSQL_CONFIG_FILE MYSQL_INIT_DIR MYSQL_INIT_FILE RABBITMQ_CONF_DIR RABBITMQ_CONFIG_FILE RABBITMQ_ENABLED_PLUGINS_FILE \
    POSTGRES_IMAGE MYSQL_IMAGE RABBITMQ_IMAGE REDIS_IMAGE \
    DEFAULT_POSTGRES_PORT DEFAULT_POSTGRES_DB DEFAULT_POSTGRES_USER DEFAULT_POSTGRES_PASSWORD \
    DEFAULT_MYSQL_PORT DEFAULT_MYSQL_DB DEFAULT_MYSQL_USER DEFAULT_MYSQL_PASSWORD DEFAULT_MYSQL_ROOT_PASSWORD \
    DEFAULT_RABBITMQ_PORT DEFAULT_RABBITMQ_MANAGEMENT_PORT DEFAULT_RABBITMQ_WEB_STOMP_PORT DEFAULT_RABBITMQ_USER DEFAULT_RABBITMQ_PASSWORD \
    DEFAULT_REDIS_PORT DEFAULT_REDIS_PASSWORD \
    SHARED_NETWORK_NAME \
    SELECT_CADDY SELECT_POSTGRES SELECT_MYSQL SELECT_RABBITMQ SELECT_REDIS \
    POSTGRES_PORT POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD \
    MYSQL_PORT MYSQL_DB MYSQL_USER MYSQL_PASSWORD MYSQL_ROOT_PASSWORD \
    RABBITMQ_PORT RABBITMQ_MANAGEMENT_PORT RABBITMQ_WEB_STOMP_PORT RABBITMQ_USER RABBITMQ_PASSWORD \
    REDIS_PORT REDIS_PASSWORD \
    SELECT_PG_WRAPPER INSTALLED_PG_WRAPPER_USER 2>/dev/null || true

  if [[ "$preserved_data_root" == "__UNSET__" ]]; then
    unset DATA_ROOT 2>/dev/null || true
  else
    export DATA_ROOT="$preserved_data_root"
  fi

  if [[ "$preserved_caddy_etc_dir" == "__UNSET__" ]]; then
    unset CADDY_ETC_DIR 2>/dev/null || true
  else
    export CADDY_ETC_DIR="$preserved_caddy_etc_dir"
  fi

  if [[ "$preserved_caddy_main_file" == "__UNSET__" ]]; then
    unset CADDY_MAIN_FILE 2>/dev/null || true
  else
    export CADDY_MAIN_FILE="$preserved_caddy_main_file"
  fi

  if [[ "$preserved_caddy_conf_dir" == "__UNSET__" ]]; then
    unset CADDY_CONF_DIR 2>/dev/null || true
  else
    export CADDY_CONF_DIR="$preserved_caddy_conf_dir"
  fi

  if [[ "$preserved_root_home" == "__UNSET__" ]]; then
    unset ROOT_HOME 2>/dev/null || true
  else
    export ROOT_HOME="$preserved_root_home"
  fi

  if [[ "$preserved_rabbitmq_conf_dir" == "__UNSET__" ]]; then
    unset RABBITMQ_CONF_DIR 2>/dev/null || true
  else
    export RABBITMQ_CONF_DIR="$preserved_rabbitmq_conf_dir"
  fi

  if [[ "$preserved_rabbitmq_config_file" == "__UNSET__" ]]; then
    unset RABBITMQ_CONFIG_FILE 2>/dev/null || true
  else
    export RABBITMQ_CONFIG_FILE="$preserved_rabbitmq_config_file"
  fi

  if [[ "$preserved_rabbitmq_plugins_file" == "__UNSET__" ]]; then
    unset RABBITMQ_ENABLED_PLUGINS_FILE 2>/dev/null || true
  else
    export RABBITMQ_ENABLED_PLUGINS_FILE="$preserved_rabbitmq_plugins_file"
  fi

  # shellcheck disable=SC1090
  source "$DEPLOY_SCRIPT"
}

run_skeleton_tests() {
  assert_file_exists "$DEPLOY_SCRIPT"
  load_script
  assert_function_exists "require_root"
  assert_function_exists "detect_os"
  assert_function_exists "ensure_directories"
  assert_function_exists "main"
}

run_generation_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export DATA_ROOT="$temp_root"
  export RABBITMQ_CONF_DIR="${temp_root}/rabbitmq/conf"
  export RABBITMQ_CONFIG_FILE="${RABBITMQ_CONF_DIR}/rabbitmq.conf"
  export RABBITMQ_ENABLED_PLUGINS_FILE="${RABBITMQ_CONF_DIR}/enabled_plugins"
  export PG_WRAPPER_BIN="${temp_root}/usr/local/bin/pg"
  mkdir -p "$(dirname "$PG_WRAPPER_BIN")"

  load_script

  assert_function_exists "write_postgres_compose"
  assert_function_exists "write_mysql_config"
  assert_function_exists "write_mysql_compose"
  assert_function_exists "write_rabbitmq_compose"
  assert_function_exists "write_redis_compose"

  ensure_directories

  write_postgres_compose 5432 appdb postgres postgres123
  write_mysql_config
  write_mysql_compose 3306 appdb app app123 root123
  write_rabbitmq_compose 5672 15672 15674 admin admin123
  write_redis_compose 6379 redis123

  assert_file_exists "${temp_root}/docker/docker-postgres.yml"
  assert_file_exists "${temp_root}/docker/docker-mysql.yml"
  assert_file_exists "${temp_root}/docker/docker-rabbitmq.yml"
  assert_file_exists "${temp_root}/docker/docker-redis.yml"
  assert_file_exists "${temp_root}/mysql/conf/my.cnf"

  assert_contains "${temp_root}/mysql/conf/my.cnf" "bind-address=0.0.0.0"
  assert_contains "${temp_root}/mysql/conf/my.cnf" "binlog_expire_logs_seconds=86400"
  assert_not_contains "${temp_root}/mysql/conf/my.cnf" "default-authentication-plugin=mysql_native_password"
  assert_contains "${temp_root}/docker/docker-postgres.yml" "${temp_root}/postgres:/var/lib/postgresql"
  assert_contains "${temp_root}/docker/docker-postgres.yml" "name: my_network"
  assert_contains "${temp_root}/docker/docker-postgres.yml" "- postgres"
  assert_contains "${temp_root}/docker/docker-mysql.yml" "${temp_root}/mysql/conf/my.cnf:/etc/mysql/conf.d/99-custom.cnf:ro"
  assert_contains "${temp_root}/docker/docker-mysql.yml" "name: my_network"
  assert_contains "${temp_root}/docker/docker-mysql.yml" "- mysql"
  assert_contains "${temp_root}/docker/docker-rabbitmq.yml" "name: my_network"
  assert_contains "${temp_root}/docker/docker-rabbitmq.yml" "- rabbitmq"
  assert_contains "${temp_root}/docker/docker-redis.yml" "--requirepass redis123"
  assert_contains "${temp_root}/docker/docker-redis.yml" "name: my_network"
  assert_contains "${temp_root}/docker/docker-redis.yml" "- redis"

  assert_function_exists "install_pg_wrapper"
  install_pg_wrapper "alice"

  assert_file_exists "$PG_WRAPPER_BIN"
  [[ -x "$PG_WRAPPER_BIN" ]] || fail "expected pg wrapper to be executable"
  assert_contains "$PG_WRAPPER_BIN" "docker exec -it postgres psql -U \"alice\""
  assert_contains "$PG_WRAPPER_BIN" "docker exec -i postgres psql -U \"alice\""
  assert_contains "$PG_WRAPPER_BIN" "container 'postgres' is not running"

  local summary_output
  summary_output="$(show_summary 2>&1)"
  [[ "$summary_output" == *"pg shortcut: ${PG_WRAPPER_BIN} (user: alice)"* ]] \
    || fail "expected show_summary to include pg shortcut line"
}

run_helper_tests() {
  local output
  local selection_output
  local temp_file
  local action_status

  load_script

  assert_function_exists "prompt_with_default"
  assert_function_exists "parse_service_selection"
  assert_function_exists "has_mysql_client"

  output="$(printf '\n' | prompt_with_default "Port" "3306")"
  assert_equals "3306" "$output"

  output="$(printf '6543\n' | prompt_with_default "Port" "3306")"
  assert_equals "6543" "$output"

  parse_service_selection "1 3 4"
  [[ "${SELECT_CADDY:-0}" -eq 1 ]] || fail "expected caddy selection"
  [[ "${SELECT_MYSQL:-0}" -eq 1 ]] || fail "expected mysql selection"
  [[ "${SELECT_RABBITMQ:-0}" -eq 1 ]] || fail "expected rabbitmq selection"
  [[ "${SELECT_POSTGRES:-0}" -eq 0 ]] || fail "did not expect postgres selection"
  [[ "${SELECT_REDIS:-0}" -eq 0 ]] || fail "did not expect redis selection"

  parse_service_selection "2,5"
  [[ "${SELECT_POSTGRES:-0}" -eq 1 ]] || fail "expected postgres selection from comma-separated input"
  [[ "${SELECT_REDIS:-0}" -eq 1 ]] || fail "expected redis selection from comma-separated input"

  parse_service_selection "6"
  [[ "${SELECT_PG_WRAPPER:-0}" -eq 1 ]] || fail "expected pg wrapper selection from '6'"
  [[ "${SELECT_CADDY:-0}" -eq 0 ]] || fail "did not expect caddy selection from '6'"

  parse_service_selection "pg"
  [[ "${SELECT_PG_WRAPPER:-0}" -eq 1 ]] || fail "expected pg wrapper selection from 'pg'"

  parse_service_selection "pg-shortcut"
  [[ "${SELECT_PG_WRAPPER:-0}" -eq 1 ]] || fail "expected pg wrapper selection from 'pg-shortcut'"

  parse_service_selection "1"
  [[ "${SELECT_PG_WRAPPER:-0}" -eq 0 ]] || fail "did not expect pg wrapper selection from '1'"

  selection_output="$(printf '\n1 3\n' | collect_service_selection 2>&1 || true)"
  assert_output_contains "$selection_output" "Select one or more components to install/deploy"
  assert_output_contains "$selection_output" "space-separated or comma-separated"
  assert_output_contains "$selection_output" "6) Install pg shortcut"

  temp_file="$(mktemp)"
  if printf 'r\n' | confirm_overwrite "$temp_file"; then
    action_status=0
  else
    action_status=$?
  fi
  rm -f "$temp_file"
  assert_equals "3" "$action_status"

  if PATH="/nonexistent" has_mysql_client; then
    fail "expected mysql client detection to fail"
  fi
}

run_smoke_tests() {
  local temp_root
  local docker_log
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export DATA_ROOT="$temp_root"
  export CADDY_ETC_DIR="${temp_root}/etc/caddy"
  export CADDY_MAIN_FILE="${CADDY_ETC_DIR}/Caddyfile"
  export CADDY_CONF_DIR="${CADDY_ETC_DIR}/conf"
  export ROOT_HOME="${temp_root}/root"
  export RABBITMQ_CONF_DIR="${temp_root}/rabbitmq/conf"
  export RABBITMQ_CONFIG_FILE="${RABBITMQ_CONF_DIR}/rabbitmq.conf"
  export RABBITMQ_ENABLED_PLUGINS_FILE="${RABBITMQ_CONF_DIR}/enabled_plugins"
  docker_log="${temp_root}/docker.log"

  load_script

  docker() {
    printf '%s\n' "$*" >>"$docker_log"
    if [[ "$*" == "network inspect my_network" ]]; then
      return 1
    fi
  }

  ensure_directories
  mkdir -p "$ROOT_HOME"
  configure_caddy_layout
  write_mysql_config
  write_mysql_init_sql appdb app app123
  write_mysql_compose 3306 appdb app app123 root123
  write_rabbitmq_compose 5672 15672 15674 admin admin123
  write_redis_compose 6379 ""
  start_compose_file "${MYSQL_COMPOSE_FILE}" "mysql"
  start_compose_file "${RABBITMQ_COMPOSE_FILE}" "rabbitmq"
  stop_compose_file "${MYSQL_COMPOSE_FILE}" "mysql"

  assert_file_exists "${CADDY_MAIN_FILE}"
  assert_file_exists "${temp_root}/mysql/init/01-app-user.sql"
  assert_file_exists "${RABBITMQ_CONFIG_FILE}"
  assert_file_exists "${RABBITMQ_ENABLED_PLUGINS_FILE}"
  assert_contains "${CADDY_MAIN_FILE}" "import ${CADDY_CONF_DIR}/*"
  assert_contains "${temp_root}/mysql/init/01-app-user.sql" "CREATE USER IF NOT EXISTS 'app'@'%'"
  assert_contains "${temp_root}/mysql/init/01-app-user.sql" "GRANT ALL PRIVILEGES ON \`appdb\`.* TO 'app'@'%'"
  assert_contains "${temp_root}/docker/docker-mysql.yml" "${temp_root}/mysql/init/01-app-user.sql:/docker-entrypoint-initdb.d/01-app-user.sql:ro"
  assert_contains "${temp_root}/docker/docker-mysql.yml" "\"3306:3306\""
  assert_contains "${temp_root}/docker/docker-mysql.yml" "name: my_network"
  assert_contains "${temp_root}/docker/docker-mysql.yml" "- mysql"
  assert_contains "${temp_root}/docker/docker-rabbitmq.yml" "image: rabbitmq:management"
  assert_contains "${temp_root}/docker/docker-rabbitmq.yml" "\"15674:15674\""
  assert_contains "${temp_root}/docker/docker-rabbitmq.yml" "${RABBITMQ_CONFIG_FILE}:/etc/rabbitmq/rabbitmq.conf:ro"
  assert_contains "${temp_root}/docker/docker-rabbitmq.yml" "${RABBITMQ_ENABLED_PLUGINS_FILE}:/etc/rabbitmq/enabled_plugins:ro"
  assert_contains "${temp_root}/docker/docker-rabbitmq.yml" "name: my_network"
  assert_contains "${temp_root}/docker/docker-rabbitmq.yml" "- rabbitmq"
  assert_contains "${RABBITMQ_CONFIG_FILE}" "default_user = admin"
  assert_contains "${RABBITMQ_CONFIG_FILE}" "default_pass = admin123"
  assert_contains "${RABBITMQ_ENABLED_PLUGINS_FILE}" "rabbitmq_management"
  assert_contains "${RABBITMQ_ENABLED_PLUGINS_FILE}" "rabbitmq_prometheus"
  assert_contains "${RABBITMQ_ENABLED_PLUGINS_FILE}" "rabbitmq_top"
  assert_contains "${RABBITMQ_ENABLED_PLUGINS_FILE}" "rabbitmq_tracing"
  assert_contains "${RABBITMQ_ENABLED_PLUGINS_FILE}" "rabbitmq_stomp"
  assert_contains "${RABBITMQ_ENABLED_PLUGINS_FILE}" "rabbitmq_web_stomp"
  assert_contains "$docker_log" "compose -p mysql -f ${temp_root}/docker/docker-mysql.yml up -d"
  assert_contains "$docker_log" "compose -p rabbitmq -f ${temp_root}/docker/docker-rabbitmq.yml up -d"
  assert_contains "$docker_log" "compose -p mysql -f ${temp_root}/docker/docker-mysql.yml down --remove-orphans"
  assert_contains "$docker_log" "network inspect my_network"
  assert_contains "$docker_log" "network create my_network"
  assert_contains "${temp_root}/docker/docker-redis.yml" "command: redis-server --appendonly yes"
  [[ -d "${CADDY_CONF_DIR}" ]] || fail "expected caddy conf directory"
  [[ -L "${ROOT_HOME}/conf" ]] || fail "expected root conf symlink"
  assert_equals "${CADDY_CONF_DIR}" "$(readlink "${ROOT_HOME}/conf")"

  if grep -Fq -- "--requirepass" "${temp_root}/docker/docker-redis.yml"; then
    fail "did not expect redis requirepass when password is blank"
  fi
  assert_contains "${temp_root}/docker/docker-redis.yml" "name: my_network"
  assert_contains "${temp_root}/docker/docker-redis.yml" "- redis"

  echo "stale" >"${temp_root}/rabbitmq/data/old-state"
  reinstall_rabbitmq 5672 15672 15674 admin admin123
  [[ ! -e "${temp_root}/rabbitmq/data/old-state" ]] || fail "expected rabbitmq reinstall to clear data directory"
  assert_contains "$docker_log" "compose -p rabbitmq -f ${temp_root}/docker/docker-rabbitmq.yml down --remove-orphans"
  assert_contains "$docker_log" "compose -p rabbitmq -f ${temp_root}/docker/docker-rabbitmq.yml up -d"

  echo "stale" >"${temp_root}/mysql/data/old-state"
  reinstall_mysql 3306 appdb app app123 root123
  [[ ! -e "${temp_root}/mysql/data/old-state" ]] || fail "expected mysql reinstall to clear data directory"
  assert_contains "${temp_root}/mysql/conf/my.cnf" "bind-address=0.0.0.0"
  assert_not_contains "${temp_root}/mysql/conf/my.cnf" "default-authentication-plugin=mysql_native_password"
  assert_contains "$docker_log" "compose -p mysql -f ${temp_root}/docker/docker-mysql.yml down --remove-orphans"
  assert_contains "$docker_log" "compose -p mysql -f ${temp_root}/docker/docker-mysql.yml up -d"
}

main() {
  local suite="${1:-all}"

  case "$suite" in
    skeleton)
      run_skeleton_tests
      ;;
    generation)
      run_generation_tests
      ;;
    helpers)
      run_helper_tests
      ;;
    smoke)
      run_smoke_tests
      ;;
    all)
      run_skeleton_tests
      run_generation_tests
      run_helper_tests
      run_smoke_tests
      ;;
    *)
      fail "unknown suite: $suite"
      ;;
  esac

  echo "PASS: ${suite}"
}

main "$@"
