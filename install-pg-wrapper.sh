#!/usr/bin/env bash
set -euo pipefail

BIN_PATH="${PG_WRAPPER_BIN:-/usr/local/bin/pg}"
DEFAULT_USER="${DEFAULT_PG_USER:-postgres}"
DEFAULT_CONTAINER="${DEFAULT_PG_CONTAINER:-postgres}"

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is not installed or not on PATH." >&2
    exit 1
  fi
}

prompt_with_default() {
  local prompt_text="$1" default_value="$2" answer
  printf "%s [%s]: " "$prompt_text" "$default_value" >&2
  IFS= read -r answer
  printf "%s" "${answer:-$default_value}"
}

main() {
  require_root
  require_docker

  local container user
  container="$(prompt_with_default "PostgreSQL container name" "$DEFAULT_CONTAINER")"
  user="$(prompt_with_default "PostgreSQL username to bake into 'pg'" "$DEFAULT_USER")"

  if ! docker inspect "$container" >/dev/null 2>&1; then
    echo "Warning: container '${container}' not found. Wrapper will still be installed." >&2
  fi

  cat >"$BIN_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null)" != "true" ]]; then
  echo "PostgreSQL container '${container}' is not running." >&2
  exit 1
fi

if [ -t 0 ]; then
  exec docker exec -it "${container}" psql -U "${user}" "\$@"
else
  exec docker exec -i "${container}" psql -U "${user}" "\$@"
fi
EOF
  chmod +x "$BIN_PATH"
  echo "Installed pg shortcut at ${BIN_PATH} (container: ${container}, user: ${user})"
}

main "$@"
