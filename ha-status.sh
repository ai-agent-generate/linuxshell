#!/usr/bin/env bash

set -euo pipefail

LINUXSHELL_RAW_BASE_URL="${LINUXSHELL_RAW_BASE_URL:-https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main}"
LINUXSHELL_MODULE_ROOT=""
LINUXSHELL_MODULE_SOURCE=""

load_linuxshell_modules() {
  local script_dir module_root module
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || pwd)"
  module_root="$script_dir"

  if [[ -f "${module_root}/lib/status-common.sh" ]]; then
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

# 探测得到 pg/mysql 后，本进程内追加加载对应栈并调 main(不 exec 子入口)
ha_status_dispatch() {
  local choice="${1:-}"
  [[ -n "$choice" ]] || choice="$(ha_status_detect_stack)"
  case "$choice" in
    pg)
      load_linuxshell_modules lib/pg-ha/common.sh lib/pg-ha/status.sh
      pg_ha_status_main ;;
    mysql)
      load_linuxshell_modules lib/mysql-ha/common.sh lib/mysql-ha/status.sh
      mysql_ha_status_main ;;
    both)
      echo "本机同时检测到 PG 与 MySQL HA，请指定: ha-status.sh pg|mysql" >&2
      return 4 ;;
    none)
      echo "未检测到 PG/MySQL HA 部署(无 patroni.yml/etcd.conf.yml/config.toml/zz-mysql-ha.cnf)。" >&2
      return 3 ;;
    *)
      echo "用法: ha-status.sh [pg|mysql]" >&2
      return 4 ;;
  esac
}

ha_status_run() {
  require_root || return 4
  # 第一批:公共库 + 两套 config(纯赋值，供 ha_status_detect_stack 读路径变量)
  load_linuxshell_modules \
    lib/common.sh \
    lib/status-common.sh \
    lib/pg-ha/config.sh \
    lib/mysql-ha/config.sh
  ha_status_dispatch "${1:-}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ha_status_run "${1:-}"
fi
