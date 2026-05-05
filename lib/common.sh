require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    return 1
  fi
}

detect_os() {
  if [[ ! -r /etc/os-release ]]; then
    echo "Cannot detect operating system." >&2
    return 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian)
      return 0
      ;;
    *)
      echo "Only Ubuntu/Debian systems are supported." >&2
      return 1
      ;;
  esac
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

to_lower() {
  printf "%s" "$1" | tr '[:upper:]' '[:lower:]'
}

print_step() {
  echo
  echo "==> $*"
}

ensure_data_root_writable() {
  mkdir -p "$DATA_ROOT"
  if [[ ! -w "$DATA_ROOT" ]]; then
    echo "Data root is not writable: $DATA_ROOT" >&2
    return 1
  fi
}

ensure_directories() {
  mkdir -p "$DOCKER_DIR"
  mkdir -p "${POSTGRES_DIR}"
  mkdir -p "${MYSQL_DIR}/data" "${MYSQL_DIR}/conf" "${MYSQL_DIR}/env" "${MYSQL_INIT_DIR}"
  mkdir -p "${RABBITMQ_DIR}/data" "${RABBITMQ_CONF_DIR}"
  mkdir -p "${REDIS_DIR}/data"
}

prompt_with_default() {
  local prompt_text="$1"
  local default_value="$2"
  local answer

  if [[ -n "$default_value" ]]; then
    printf "%s [%s]: " "$prompt_text" "$default_value" >&2
  else
    printf "%s: " "$prompt_text" >&2
  fi

  IFS= read -r answer
  if [[ -z "$answer" ]]; then
    printf "%s" "$default_value"
  else
    printf "%s" "$answer"
  fi
}

prompt_yes_no() {
  local prompt_text="$1"
  local default_answer="${2:-y}"
  local answer
  local normalized

  while true; do
    if [[ "$default_answer" == "y" ]]; then
      printf "%s [Y/n]: " "$prompt_text"
    else
      printf "%s [y/N]: " "$prompt_text"
    fi

    IFS= read -r answer
    answer="${answer:-$default_answer}"
    normalized="$(to_lower "$answer")"

    case "$normalized" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

port_in_use() {
  local port="$1"
  if command_exists ss; then
    ss -ltn "( sport = :${port} )" | grep -q ":${port} "
  elif command_exists netstat; then
    netstat -ltn 2>/dev/null | grep -q "[\.:]${port} "
  else
    return 1
  fi
}

assert_port_available() {
  local port="$1"
  local label="$2"

  if port_in_use "$port"; then
    echo "Port ${port} is already in use for ${label}." >&2
    return 1
  fi
}

confirm_overwrite() {
  local target="$1"
  local answer
  local normalized

  if [[ ! -f "$target" ]]; then
    return 0
  fi

  echo "File already exists: $target"
  while true; do
    printf "Choose action: [s]kip, [o]verwrite, [u]se existing, [r]einstall: "
    IFS= read -r answer
    normalized="$(to_lower "$answer")"
    case "$normalized" in
      s|skip)
        return 1
        ;;
      o|overwrite|"")
        return 0
        ;;
      u|use)
        return 2
        ;;
      r|reinstall)
        return 3
        ;;
      *)
        echo "Please enter s, o, u, or r." >&2
        ;;
    esac
  done
}
