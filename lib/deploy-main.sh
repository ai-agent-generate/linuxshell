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
