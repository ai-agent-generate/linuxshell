install_apt_dependencies() {
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release
}

validate_docker_install() {
  if ! command_exists docker; then
    echo "Docker command is not available after installation." >&2
    return 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose plugin is not available after installation." >&2
    return 1
  fi
}

install_docker() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    print_step "Docker and Docker Compose plugin already installed"
    validate_docker_install
    return 0
  fi

  print_step "Installing Docker"
  install_apt_dependencies
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/"$(. /etc/os-release && echo "$ID")"/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  . /etc/os-release
  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable
EOF

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  validate_docker_install
}
