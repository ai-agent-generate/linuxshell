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
