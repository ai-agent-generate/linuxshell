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
