#!/usr/bin/env bash

set -euo pipefail

LINUXSHELL_RAW_BASE_URL="${LINUXSHELL_RAW_BASE_URL:-https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main}"
LINUXSHELL_MODULE_ROOT=""
LINUXSHELL_MODULE_SOURCE=""

load_linuxshell_modules() {
  local script_dir module_root module
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || pwd)"
  module_root="$script_dir"

  if [[ -f "${module_root}/lib/mysql-ha/config.sh" ]]; then
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
  lib/common.sh \
  lib/mysql-ha/config.sh \
  lib/mysql-ha/common.sh \
  lib/mysql-ha/mysql.sh \
  lib/mysql-ha/orchestrator.sh \
  lib/mysql-ha/mysqlchk.sh \
  lib/mysql-ha/watcher.sh \
  lib/mysql-ha/haproxy.sh \
  lib/mysql-ha/main.sh

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  mysql_ha_main "$@"
fi
