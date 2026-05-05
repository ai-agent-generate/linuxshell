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

configure_redis() {
  REDIS_PORT="$(prompt_with_default "Redis host port" "$DEFAULT_REDIS_PORT")"
  REDIS_PASSWORD="$(prompt_with_default "Redis password (leave blank for no password)" "$DEFAULT_REDIS_PASSWORD")"
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
