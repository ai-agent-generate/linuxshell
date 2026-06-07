# systemd 重应用 unit + fw 命令生成 + 模块安装(权限矩阵)

fw_write_service() {
  cat >"$FW_SERVICE_FILE" <<EOF
[Unit]
Description=linuxshell firewall apply
After=network-online.target docker.service k3s.service k3s-agent.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${FW_BIN} apply --quiet
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$FW_SERVICE_FILE"
}

fw_write_command() {
  cat >"$FW_BIN" <<EOF
#!/usr/bin/env bash
set -euo pipefail
FW_LIB_DIR="\${FW_LIB_DIR:-${FW_LIB_DIR}}"
source "\${FW_LIB_DIR}/linuxshell-common.sh"
for m in config common rules docker k3s trust service menu main; do
  source "\${FW_LIB_DIR}/\${m}.sh"
done
fw_cli "\$@"
EOF
  chmod 755 "$FW_BIN"
}

# 把模块从 LINUXSHELL_MODULE_ROOT(本地=仓库/远程=临时目录)安装到 FW_LIB_DIR
fw_install_modules() {
  local root m
  root="${LINUXSHELL_MODULE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  mkdir -p "$FW_LIB_DIR"; chmod 755 "$FW_LIB_DIR"
  for m in config common rules docker k3s trust service menu main; do
    install -m 644 "${root}/lib/firewall/${m}.sh" "${FW_LIB_DIR}/${m}.sh"
  done
  install -m 644 "${root}/lib/common.sh" "${FW_LIB_DIR}/linuxshell-common.sh"
}
