configure_caddy_layout() {
  mkdir -p "$CADDY_CONF_DIR"
  printf "import %s/*\n" "$CADDY_CONF_DIR" >"$CADDY_MAIN_FILE"
  ln -sfn "$CADDY_CONF_DIR" "$ROOT_HOME"
}

install_caddy() {
  if command_exists caddy; then
    print_step "Caddy already installed"
  else
    print_step "Installing Caddy"
    install_apt_dependencies
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
  fi

  configure_caddy_layout
}
