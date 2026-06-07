#!/usr/bin/env bash
write_my_cnf() {
  local server_id="$1"
  local role="$2"   # primary | replica
  local semisync_block=""

  if [[ "$(to_lower "${MYSQL_HA_SEMISYNC}")" == "on" ]]; then
    # 两台数据节点都可能在切换后成为 source 或 replica,因此同时加载两种半同步插件。
    semisync_block="plugin_load_add=semisync_source.so
plugin_load_add=semisync_replica.so
rpl_semi_sync_source_enabled=1
rpl_semi_sync_source_timeout=${MYSQL_HA_SEMISYNC_TIMEOUT}
rpl_semi_sync_source_wait_for_replica_count=1
rpl_semi_sync_replica_enabled=1"
  fi

  mkdir -p "$(dirname "${MYSQL_HA_MYCNF}")"
  cat >"${MYSQL_HA_MYCNF}" <<EOF
[mysqld]
server_id=${server_id}
bind-address=${MYSQL_HA_NODE_IP}
port=${MYSQL_HA_MYSQL_PORT}
datadir=${MYSQL_HA_DATADIR}
report_host=${MYSQL_HA_NODE_IP}
report_port=${MYSQL_HA_MYSQL_PORT}
skip_name_resolve=ON

gtid_mode=ON
enforce_gtid_consistency=ON
log_bin=mysql-bin
binlog_format=ROW
log_replica_updates=ON
relay_log=relay-bin
relay_log_recovery=ON
binlog_expire_logs_seconds=${MYSQL_HA_BINLOG_EXPIRE_SECONDS}

# boot 安全默认:重启即只读,由 Replication Manager 在故障切换时提升可写
super_read_only=ON
${semisync_block}
EOF
  # my.cnf 不含任何密码,644 合理(MySQL 期望该文件可读)
  chmod 644 "${MYSQL_HA_MYCNF}"
}

mysql_ha_mysql_repo_component() {
  case "${MYSQL_HA_VERSION}" in
    8.0) printf "mysql-8.0" ;;
    *) printf "mysql-%s-lts" "${MYSQL_HA_VERSION}" ;;
  esac
}

mysql_ha_installed_mysql_major_minor() {
  mysqld --version 2>/dev/null | sed -n 's/.* Ver \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

mysql_ha_mysql_installed_matches_target() {
  local installed
  installed="$(mysql_ha_installed_mysql_major_minor)"
  [[ "$installed" == "${MYSQL_HA_VERSION}" ]]
}

add_mysql_repo() {
  local repo_component
  repo_component="$(mysql_ha_mysql_repo_component)"
  print_step "Adding MySQL APT repository (${repo_component})"
  export DEBIAN_FRONTEND=noninteractive
  local codename keyring
  codename="$(lsb_release -cs 2>/dev/null || echo noble)"
  keyring="/usr/share/keyrings/mysql.gpg"
  apt-get install -y curl ca-certificates gnupg lsb-release
  # 导入 MySQL 签名公钥到独立 keyring(2023 key 已过期,Oracle 仓库当前发布 2025 key)
  curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 | gpg --batch --yes --dearmor -o "$keyring"
  cat >/etc/apt/sources.list.d/mysql.list <<EOF
deb [signed-by=${keyring}] https://repo.mysql.com/apt/ubuntu ${codename} ${repo_component}
EOF
}

install_mysql() {
  print_step "Installing MySQL ${MYSQL_HA_VERSION}"
  if command_exists mysqld; then
    if mysql_ha_mysql_installed_matches_target; then
      echo "mysqld already installed with target version ${MYSQL_HA_VERSION}."
      return 0
    fi
    echo "mysqld is installed but not ${MYSQL_HA_VERSION}; upgrading via MySQL APT repository."
    add_mysql_repo
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y mysql-server rsync
    return 0
  fi
  add_mysql_repo
  export DEBIAN_FRONTEND=noninteractive
  # 非交互预置 root 密码 + 强密码加密(键名实现期用 debconf-show 核对,spec Open Item #5)
  debconf-set-selections <<EOF
mysql-community-server mysql-community-server/root-pass password ${MYSQL_HA_ROOT_PASSWORD}
mysql-community-server mysql-community-server/re-root-pass password ${MYSQL_HA_ROOT_PASSWORD}
mysql-server mysql-server/default-auth-override select Use Strong Password Encryption (RECOMMENDED)
EOF
  apt-get update
  apt-get install -y mysql-server rsync
}

# datadir 移出 /var/lib/mysql 时,若存在 AppArmor profile 才加 local 规则(Oracle 社区包通常不装)
apply_apparmor_datadir() {
  [[ "${MYSQL_HA_DATADIR}" == "/var/lib/mysql" ]] && return 0
  [[ -f /etc/apparmor.d/usr.sbin.mysqld ]] || return 0
  mkdir -p /etc/apparmor.d/local
  {
    echo "${MYSQL_HA_DATADIR}/ r,"
    echo "${MYSQL_HA_DATADIR}/** rwk,"
  } >>/etc/apparmor.d/local/usr.sbin.mysqld
  apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld 2>/dev/null || true
}

# apt 在 /var/lib/mysql 初始化(含 debconf root 密码),再 rsync 到自定义 datadir 保留 root 凭据
relocate_datadir() {
  [[ "${MYSQL_HA_DATADIR}" == "/var/lib/mysql" ]] && return 0
  print_step "Relocating MySQL datadir to ${MYSQL_HA_DATADIR}"
  if [[ -f "${MYSQL_HA_DATADIR}/auto.cnf" || -d "${MYSQL_HA_DATADIR}/mysql" ]]; then
    echo "MySQL datadir already exists at ${MYSQL_HA_DATADIR}; skipping relocation."
    apply_apparmor_datadir
    chown -R mysql:mysql "${MYSQL_HA_DATADIR}"
    chmod 750 "${MYSQL_HA_DATADIR}"
    return 0
  fi
  if [[ -d "${MYSQL_HA_DATADIR}" ]] && [[ -n "$(find "${MYSQL_HA_DATADIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Refusing to copy /var/lib/mysql into non-empty ${MYSQL_HA_DATADIR}; move or empty it first." >&2
    return 1
  fi
  systemctl stop mysql 2>/dev/null || true
  apply_apparmor_datadir
  mkdir -p "${MYSQL_HA_DATADIR}"
  rsync -a /var/lib/mysql/ "${MYSQL_HA_DATADIR}/"
  chown -R mysql:mysql "${MYSQL_HA_DATADIR}"
  chmod 750 "${MYSQL_HA_DATADIR}"
}

start_mysql() {
  systemctl daemon-reload
  systemctl enable mysql
  systemctl restart mysql
}

# 私有:用 root 经本机 socket 执行 SQL(凭据走临时 600 defaults-file,不进 argv)
_mysql_root_exec() {
  local root_cnf rc=0
  root_cnf="$(mktemp)"; chmod 600 "$root_cnf"
  cat >"$root_cnf" <<EOF
[client]
user=root
password=${MYSQL_HA_ROOT_PASSWORD}
socket=${MYSQL_HA_MYSQL_SOCKET}
EOF
  mysql --defaults-extra-file="$root_cnf" || rc=$?
  rm -f "$root_cnf"
  return $rc
}

# 仅 primary:建账号(经 GTID 复制到 replica;replica 不重复建)
bootstrap_mysql_accounts() {
  print_step "Creating MySQL HA accounts (primary only; replicate via GTID)"
  local ip
  # 先解除只读(my.cnf 默认 super_read_only=ON),使账号 DDL 可写入并入 binlog
  _mysql_root_exec <<SQL
SET GLOBAL read_only = OFF;
CREATE USER IF NOT EXISTS 'mysqlchk'@'localhost' IDENTIFIED BY '${MYSQL_HA_MYSQLCHK_PASSWORD}';
GRANT REPLICATION CLIENT ON *.* TO 'mysqlchk'@'localhost';
CREATE DATABASE IF NOT EXISTS \`${MYSQL_HA_APP_DB}\`;
CREATE USER IF NOT EXISTS '${MYSQL_HA_APP_USER}'@'${MYSQL_HA_APP_ALLOWED_CIDR}' IDENTIFIED BY '${MYSQL_HA_APP_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${MYSQL_HA_APP_DB}\`.* TO '${MYSQL_HA_APP_USER}'@'${MYSQL_HA_APP_ALLOWED_CIDR}';
SQL
  # repl:node1/node2 两台(failover 角色互换)
  for ip in "${MYSQL_HA_NODE1_IP}" "${MYSQL_HA_NODE2_IP}"; do
    _mysql_root_exec <<SQL
CREATE USER IF NOT EXISTS 'repl'@'${ip}' IDENTIFIED BY '${MYSQL_HA_REPL_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'${ip}';
SQL
  done
  # Replication Manager:三台 IP 均授权,便于未来从任意节点运行监控/恢复
  for ip in "${MYSQL_HA_NODE1_IP}" "${MYSQL_HA_NODE2_IP}" "${MYSQL_HA_NODE3_IP}"; do
    _mysql_root_exec <<SQL
CREATE USER IF NOT EXISTS '${MYSQL_HA_REPMAN_USER}'@'${ip}' IDENTIFIED BY '${MYSQL_HA_REPMAN_PASSWORD}' PASSWORD EXPIRE NEVER;
GRANT SELECT, PROCESS, RELOAD, SUPER, REPLICATION CLIENT, REPLICATION SLAVE ON *.* TO '${MYSQL_HA_REPMAN_USER}'@'${ip}';
GRANT REPLICATION_SLAVE_ADMIN, BINLOG_ADMIN, SYSTEM_VARIABLES_ADMIN, CONNECTION_ADMIN ON *.* TO '${MYSQL_HA_REPMAN_USER}'@'${ip}';
CREATE DATABASE IF NOT EXISTS replication_manager_schema;
GRANT ALL PRIVILEGES ON replication_manager_schema.* TO '${MYSQL_HA_REPMAN_USER}'@'${ip}';
SQL
  done
}

# 仅 replica:指向 primary(MySQL 8.4 caching_sha2;复制链路使用 MySQL 自动生成的 SSL)
setup_replication() {
  print_step "Configuring replication from primary (${MYSQL_HA_NODE1_IP})"
  _mysql_root_exec <<SQL
STOP REPLICA;
RESET REPLICA ALL;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${MYSQL_HA_NODE1_IP}',
  SOURCE_PORT=${MYSQL_HA_MYSQL_PORT},
  SOURCE_USER='repl',
  SOURCE_PASSWORD='${MYSQL_HA_REPL_PASSWORD}',
  SOURCE_AUTO_POSITION=1,
  SOURCE_SSL=1,
  GET_SOURCE_PUBLIC_KEY=0;
START REPLICA;
SQL
}
