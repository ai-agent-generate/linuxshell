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

configure_rabbitmq() {
  RABBITMQ_PORT="$(prompt_with_default "RabbitMQ AMQP port" "$DEFAULT_RABBITMQ_PORT")"
  RABBITMQ_MANAGEMENT_PORT="$(prompt_with_default "RabbitMQ management port" "$DEFAULT_RABBITMQ_MANAGEMENT_PORT")"
  RABBITMQ_WEB_STOMP_PORT="$(prompt_with_default "RabbitMQ Web STOMP port" "$DEFAULT_RABBITMQ_WEB_STOMP_PORT")"
  RABBITMQ_USER="$(prompt_with_default "RabbitMQ username" "$DEFAULT_RABBITMQ_USER")"
  RABBITMQ_PASSWORD="$(prompt_with_default "RabbitMQ password" "$DEFAULT_RABBITMQ_PASSWORD")"
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
