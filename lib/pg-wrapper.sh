install_pg_wrapper() {
  local user="$1"

  cat >"$PG_WRAPPER_BIN" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\$(docker inspect -f '{{.State.Running}}' postgres 2>/dev/null)" != "true" ]]; then
  echo "PostgreSQL container 'postgres' is not running." >&2
  exit 1
fi

if [ -t 0 ]; then
  exec docker exec -it postgres psql -U "${user}" "\$@"
else
  exec docker exec -i postgres psql -U "${user}" "\$@"
fi
EOF
  chmod +x "$PG_WRAPPER_BIN"
  INSTALLED_PG_WRAPPER_USER="$user"
  echo "Installed pg shortcut at ${PG_WRAPPER_BIN} (user: ${user})"
}
