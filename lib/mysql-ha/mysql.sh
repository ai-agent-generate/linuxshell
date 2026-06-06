#!/usr/bin/env bash
write_my_cnf() {
  local server_id="$1"
  local role="$2"   # primary | replica
  local semisync_block=""

  if [[ "$(to_lower "${MYSQL_HA_SEMISYNC}")" == "on" ]]; then
    if [[ "$role" == "primary" ]]; then
      semisync_block="plugin_load_add=semisync_source.so
rpl_semi_sync_source_enabled=1
rpl_semi_sync_source_timeout=${MYSQL_HA_SEMISYNC_TIMEOUT}
rpl_semi_sync_source_wait_for_replica_count=1"
    else
      semisync_block="plugin_load_add=semisync_replica.so
rpl_semi_sync_replica_enabled=1"
    fi
  fi

  mkdir -p "$(dirname "${MYSQL_HA_MYCNF}")"
  cat >"${MYSQL_HA_MYCNF}" <<EOF
[mysqld]
server_id=${server_id}
bind-address=${MYSQL_HA_NODE_IP}
port=${MYSQL_HA_MYSQL_PORT}
datadir=${MYSQL_HA_DATADIR}

gtid_mode=ON
enforce_gtid_consistency=ON
log_bin=mysql-bin
binlog_format=ROW
log_replica_updates=ON
relay_log=relay-bin
relay_log_recovery=ON
binlog_expire_logs_seconds=${MYSQL_HA_BINLOG_EXPIRE_SECONDS}

# boot 安全默认:重启即只读,由 mysql-ha-watcher 依 Orchestrator 拓扑收敛回可写
super_read_only=ON
${semisync_block}
EOF
  # my.cnf 不含任何密码,644 合理(MySQL 期望该文件可读)
  chmod 644 "${MYSQL_HA_MYCNF}"
}

add_mysql_repo() {
  print_step "Adding MySQL APT repository (mysql-${MYSQL_HA_VERSION}-lts)"
  export DEBIAN_FRONTEND=noninteractive
  local codename keyring
  codename="$(lsb_release -cs 2>/dev/null || echo noble)"
  keyring="/usr/share/keyrings/mysql.gpg"
  apt-get install -y curl ca-certificates gnupg lsb-release
  # 导入 MySQL 签名公钥到独立 keyring(指纹 B7B3B788A8D3785C)
  curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 | gpg --batch --yes --dearmor -o "$keyring"
  cat >/etc/apt/sources.list.d/mysql.list <<EOF
deb [signed-by=${keyring}] https://repo.mysql.com/apt/ubuntu ${codename} mysql-${MYSQL_HA_VERSION}-lts
EOF
}

install_mysql() {
  print_step "Installing MySQL ${MYSQL_HA_VERSION}"
  if command_exists mysqld; then
    echo "mysqld already installed."
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
CREATE USER IF NOT EXISTS 'watcher'@'localhost' IDENTIFIED BY '${MYSQL_HA_WATCHER_PASSWORD}';
GRANT SYSTEM_VARIABLES_ADMIN, REPLICATION CLIENT ON *.* TO 'watcher'@'localhost';
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
  # orchestrator:三台 IP(仲裁节点也连 MySQL 监控);8.4 动态权限替代弃用的 SUPER
  for ip in "${MYSQL_HA_NODE1_IP}" "${MYSQL_HA_NODE2_IP}" "${MYSQL_HA_NODE3_IP}"; do
    _mysql_root_exec <<SQL
CREATE USER IF NOT EXISTS 'orchestrator'@'${ip}' IDENTIFIED BY '${MYSQL_HA_ORCH_PASSWORD}';
GRANT PROCESS, REPLICATION SLAVE, REPLICATION CLIENT, RELOAD ON *.* TO 'orchestrator'@'${ip}';
GRANT SYSTEM_VARIABLES_ADMIN, REPLICATION_SLAVE_ADMIN ON *.* TO 'orchestrator'@'${ip}';
GRANT SELECT ON mysql.* TO 'orchestrator'@'${ip}';
SQL
  done
}

# 仅 replica:指向 primary(8.4 + caching_sha2 + 无 TLS → GET_SOURCE_PUBLIC_KEY=1)
setup_replication() {
  print_step "Configuring replication from primary (${MYSQL_HA_NODE1_IP})"
  _mysql_root_exec <<SQL
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${MYSQL_HA_NODE1_IP}',
  SOURCE_PORT=${MYSQL_HA_MYSQL_PORT},
  SOURCE_USER='repl',
  SOURCE_PASSWORD='${MYSQL_HA_REPL_PASSWORD}',
  SOURCE_AUTO_POSITION=1,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL
}
