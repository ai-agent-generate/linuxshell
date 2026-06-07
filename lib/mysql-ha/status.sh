#!/usr/bin/env bash
# lib/mysql-ha/status.sh — MySQL HA 只读巡检
# 依赖:lib/common.sh + lib/status-common.sh + lib/mysql-ha/config.sh + lib/mysql-ha/common.sh

MYSQL_HA_DETECTED_ROLE=""
MYSQL_HA_LOCAL_IP=""

# 本机只读 SQL:mysqlchk.cnf(socket，仅本机)。读 @@global.read_only 等任何账号可读。
mysql_ha_status_local_sql() {
  mysql --defaults-extra-file="${MYSQL_HA_MYSQLCHK_CNF}" -N -B -e "$1" 2>/dev/null || true
}

# 拓扑:arbiter 从 config.toml；data 从 haproxy.cfg。node3(arbiter) 在 data 节点上无法得知。
mysql_ha_status_load_topology() {
  local hosts
  if [[ -e "${MYSQL_HA_REPMAN_CONF}" ]]; then
    hosts="$(status_extract_kv "${MYSQL_HA_REPMAN_CONF}" 's/.*db-servers-hosts = "\([^"]*\)".*/\1/p')"
    if [[ -n "$hosts" ]]; then
      MYSQL_HA_NODE1_IP="$(printf '%s' "$hosts" | sed -n 's/^\([0-9.]\{7,\}\):.*/\1/p')"
      MYSQL_HA_NODE2_IP="$(printf '%s' "$hosts" | sed -n 's/.*,\([0-9.]\{7,\}\):.*/\1/p')"
    fi
  elif [[ -e "${MYSQL_HA_HAPROXY_CFG}" ]]; then
    MYSQL_HA_NODE1_IP="$(status_extract_kv "${MYSQL_HA_HAPROXY_CFG}" 's/.*server node1 \([0-9.]\{7,\}\):.*/\1/p')"
    MYSQL_HA_NODE2_IP="$(status_extract_kv "${MYSQL_HA_HAPROXY_CFG}" 's/.*server node2 \([0-9.]\{7,\}\):.*/\1/p')"
  fi
  return 0
}

mysql_ha_status_detect_role() {
  if [[ -e "${MYSQL_HA_MYCNF}" ]]; then
    local ro; ro="$(mysql_ha_status_local_sql 'SELECT @@global.read_only')"
    case "$ro" in
      0) MYSQL_HA_DETECTED_ROLE="primary" ;;
      1) MYSQL_HA_DETECTED_ROLE="replica" ;;
      *) MYSQL_HA_DETECTED_ROLE="unknown" ;;
    esac
  elif [[ -e "${MYSQL_HA_REPMAN_CONF}" ]]; then
    MYSQL_HA_DETECTED_ROLE="arbiter"
  else
    MYSQL_HA_DETECTED_ROLE="unknown"
  fi
  printf '%s' "${MYSQL_HA_DETECTED_ROLE}"
  return 0
}

mysql_ha_status_identity() {
  status_section "本机身份"
  status_kv "集群名" "${MYSQL_HA_CLUSTER_NAME}"
  status_kv "主机名" "$(hostname 2>/dev/null || echo unknown)"
  local lip node="unknown"
  if lip="$(status_local_ip "${MYSQL_HA_NODE1_IP}" "${MYSQL_HA_NODE2_IP}" "${MYSQL_HA_NODE3_IP}" 2>/dev/null)"; then
    [[ "$lip" == "${MYSQL_HA_NODE1_IP}" ]] && node="node1"
    [[ "$lip" == "${MYSQL_HA_NODE2_IP}" ]] && node="node2"
    [[ "$lip" == "${MYSQL_HA_NODE3_IP}" ]] && node="node3"
    MYSQL_HA_LOCAL_IP="$lip"
  else lip="(未匹配 NODE*_IP)"; fi
  status_kv "本机 IP / 编号" "${lip} / ${node}"
  if [[ "${MYSQL_HA_DETECTED_ROLE}" == "primary" || "${MYSQL_HA_DETECTED_ROLE}" == "replica" ]]; then
    status_kv "server_id" "$(mysql_ha_status_local_sql 'SELECT @@server_id')"
  fi
  case "${MYSQL_HA_DETECTED_ROLE}" in
    primary) status_ok   "本机角色" "primary (MySQL 主库, read_only=0)" ;;
    replica) status_ok   "本机角色" "replica (MySQL 从库, read_only=1)" ;;
    arbiter) status_ok   "本机角色" "arbiter (仅 Replication Manager 仲裁，不跑 MySQL)" ;;
    *)       status_warn "本机角色" "无法确定(zz-mysql-ha.cnf/config.toml 缺失或本机 MySQL 不可连)" ;;
  esac
  return 0
}

mysql_ha_status_service_one() {
  local svc="$1" since
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    since="$(systemctl show -p ActiveEnterTimestamp --value "$svc" 2>/dev/null || true)"
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      status_ok "服务 $svc" "active, enabled${since:+, since $since}"
    else
      status_warn "服务 $svc" "active 但未设置开机自启${since:+, since $since}"
    fi
  else
    status_crit "服务 $svc" "未运行(inactive/failed)"
  fi
  return 0
}

mysql_ha_status_services() {
  status_section "服务健康"
  local p ports
  if [[ "${MYSQL_HA_DETECTED_ROLE}" == "arbiter" ]]; then
    mysql_ha_status_service_one replication-manager
    ports="${MYSQL_HA_REPMAN_API_PORT} ${MYSQL_HA_REPMAN_HTTP_PORT}"
  else
    mysql_ha_status_service_one mysql
    mysql_ha_status_service_one haproxy
    mysql_ha_status_service_one mysqlchk.socket
    status_info "replication-manager" "数据节点不运行 repman(在 arbiter 节点)"
    ports="${MYSQL_HA_MYSQL_PORT} ${MYSQL_HA_PROXY_PORT} ${MYSQL_HA_PROXY_STATS_PORT} ${MYSQL_HA_MYSQLCHK_PORT}"
  fi
  for p in $ports; do
    if port_in_use "$p"; then status_ok "端口 $p" "监听中"; else status_warn "端口 $p" "未监听"; fi
  done
  return 0
}

# repman REST API(best-effort)。凭据从 config.toml(仅 arbiter 有)，必带 user。
# 协议/端点为实现核实点:先 HTTPS(-k) 再 HTTP；任何失败返回非 0 由调用方降级。
mysql_ha_status_repman_api() {
  local host="$1" cred user pass url resp
  cred="$(status_extract_kv "${MYSQL_HA_REPMAN_CONF}" 's/.*api-credentials = "\([^"]*\)".*/\1/p')"
  [[ -n "$cred" ]] || return 1
  user="${cred%%:*}"; pass="${cred#*:}"
  for url in "https://${host}:${MYSQL_HA_REPMAN_API_PORT}/api/clusters/${MYSQL_HA_CLUSTER_NAME}/topology" \
             "http://${host}:${MYSQL_HA_REPMAN_API_PORT}/api/clusters/${MYSQL_HA_CLUSTER_NAME}/topology"; do
    resp="$(status_curl_cred "$user" "$pass" -fsSk --max-time 5 "$url" 2>/dev/null || true)"
    [[ -n "$resp" ]] && { printf '%s' "$resp"; return 0; }
  done
  return 1
}

mysql_ha_status_topology() {
  status_section "集群拓扑"
  if [[ "${MYSQL_HA_DETECTED_ROLE}" == "arbiter" && -e "${MYSQL_HA_REPMAN_CONF}" ]]; then
    local resp; resp="$(mysql_ha_status_repman_api 127.0.0.1 || true)"
    if [[ -n "$resp" ]]; then
      printf '%s\n' "$resp" | status_redact
      status_ok "repman API" "已获取集群拓扑"
    else
      status_warn "repman API" "不可达/认证失败(:${MYSQL_HA_REPMAN_API_PORT})，见实现核实点(协议/认证)"
    fi
  else
    status_info "集群拓扑" "data 节点无 repman 凭据；拓扑由防脑裂/入口一致性经 mysqlchk 推断"
  fi
}

mysql_ha_status_replication() {
  case "${MYSQL_HA_DETECTED_ROLE}" in primary|replica) ;; *) status_info "复制健康" "本机非 MySQL 数据节点，跳过"; return 0 ;; esac
  status_section "复制健康"
  if [[ "${MYSQL_HA_DETECTED_ROLE}" == "replica" ]]; then
    local st io sql sbm
    st="$(mysql_ha_status_local_sql 'SHOW REPLICA STATUS\G')"
    [[ -n "$st" ]] || { status_crit "复制" "从库无 REPLICA STATUS(复制未配置?)"; return 0; }
    io="$(printf '%s' "$st" | sed -n 's/.*Replica_IO_Running:[[:space:]]*\([A-Za-z]*\).*/\1/p' | head -1)"
    sql="$(printf '%s' "$st" | sed -n 's/.*Replica_SQL_Running:[[:space:]]*\([A-Za-z]*\).*/\1/p' | head -1)"
    sbm="$(printf '%s' "$st" | sed -n 's/.*Seconds_Behind_Source:[[:space:]]*\([0-9A-Za-z]*\).*/\1/p' | head -1)"
    if [[ "$io" != "Yes" || "$sql" != "Yes" ]]; then
      status_crit "复制线程" "IO=${io} SQL=${sql}(复制中断；延迟指标此时无意义)"
    elif [[ "$sbm" =~ ^[0-9]+$ ]]; then
      if [[ "$sbm" -ge "${STATUS_MYSQL_LAG_CRIT_SEC}" ]]; then status_crit "复制延迟" "${sbm}s(>=${STATUS_MYSQL_LAG_CRIT_SEC}s)"
      elif [[ "$sbm" -ge "${STATUS_MYSQL_LAG_WARN_SEC}" ]]; then status_warn "复制延迟" "${sbm}s(>=${STATUS_MYSQL_LAG_WARN_SEC}s)"
      else status_ok "复制" "IO/SQL 均 Yes, 延迟 ${sbm}s"; fi
    else
      status_ok "复制" "IO/SQL 均 Yes(延迟未知)"
    fi
  else
    local hosts; hosts="$(mysql_ha_status_local_sql 'SHOW REPLICA HOSTS')"
    if [[ -n "$hosts" ]]; then status_ok "主库复制" "已有从库连接"; else status_warn "主库复制" "无从库连接(SHOW REPLICA HOSTS 空)"; fi
  fi
}

mysql_ha_status_degradation() {
  case "${MYSQL_HA_DETECTED_ROLE}" in primary|replica) ;; *) return 0 ;; esac
  status_section "静默退化检测"
  if [[ "$(to_lower "${MYSQL_HA_SEMISYNC}")" == "on" && "${MYSQL_HA_DETECTED_ROLE}" == "primary" ]]; then
    local sstat sclients
    sstat="$(mysql_ha_status_local_sql "SHOW STATUS LIKE 'Rpl_semi_sync_source_status'" | awk '{print $2}')"
    sclients="$(mysql_ha_status_local_sql "SHOW STATUS LIKE 'Rpl_semi_sync_source_clients'" | awk '{print $2}')"
    if [[ "$sstat" == "OFF" ]]; then status_warn "半同步" "source_status=OFF(已退化为异步，RPO>0)"
    elif [[ "$sclients" == "0" ]]; then status_warn "半同步" "source_clients=0(无半同步从库，已退化)"
    elif [[ -n "$sstat" ]]; then status_ok "半同步" "ON(source_clients=${sclients})"; fi
  fi
  if [[ "${MYSQL_HA_DETECTED_ROLE}" == "replica" ]]; then
    local st io sql ro
    st="$(mysql_ha_status_local_sql 'SHOW REPLICA STATUS\G')"
    io="$(printf '%s' "$st" | sed -n 's/.*Replica_IO_Running:[[:space:]]*\([A-Za-z]*\).*/\1/p' | head -1)"
    sql="$(printf '%s' "$st" | sed -n 's/.*Replica_SQL_Running:[[:space:]]*\([A-Za-z]*\).*/\1/p' | head -1)"
    [[ "$io" == "No" && "$sql" == "Yes" ]] && status_crit "复制 IO 断" "IO=No 但 SQL=Yes(已停止拉新数据，迷惑性假象)"
    ro="$(mysql_ha_status_local_sql 'SELECT @@global.read_only')"
    [[ "$ro" == "0" ]] && status_crit "僵尸主" "本机是从库却 read_only=0(可写，脑裂嫌疑)"
  fi
  if [[ "${MYSQL_HA_DETECTED_ROLE}" == "primary" ]]; then
    local sro; sro="$(mysql_ha_status_local_sql 'SELECT @@global.super_read_only')"
    [[ "$sro" == "1" || "$sro" == "ON" ]] && status_crit "不可写主" "主库 super_read_only=ON(当前无可写主)"
  fi
  return 0
}

mysql_ha_status_ingress() {
  case "${MYSQL_HA_DETECTED_ROLE}" in primary|replica) ;; *) return 0 ;; esac
  status_section "入口一致性"
  local pass; pass="$(status_extract_kv "${MYSQL_HA_HAPROXY_CFG}" 's/.*stats auth admin:\(.*\)/\1/p')"
  [[ -n "$pass" ]] || { status_warn "HAProxy stats" "无法提取 stats 凭据"; return 0; }
  _my_up_count() {
    status_curl_cred admin "$pass" -fsS "http://127.0.0.1:${MYSQL_HA_PROXY_STATS_PORT}/;csv" 2>/dev/null \
      | awk -F, '$1=="mysql_primary" && $18=="UP" {n++} END{print n+0}'
  }
  local up; up="$(_my_up_count)"
  if [[ "$up" == "1" ]]; then status_ok "HAProxy 写入口" "唯一 UP 后端"
  else
    _my_probe_ingress() { [[ "$(_my_up_count)" == "1" ]]; }
    local rc=0; status_recheck _my_probe_ingress || rc=$?
    case "$rc" in
      0)  status_ok   "HAProxy 写入口" "复采为唯一 UP 后端" ;;
      10) status_warn "HAProxy 写入口" "首检 UP 后端数=${up}，复采已恢复(疑似切换中)" ;;
      *)  if [[ "$up" == "0" ]]; then status_crit "HAProxy 写入口" "无 UP 后端(当前无写入口)"
          else status_crit "HAProxy 写入口" "${up} 个后端同时 UP(路由错乱/双主嫌疑)"; fi ;;
    esac
  fi
}

mysql_ha_status_splitbrain() {
  status_section "防脑裂 / 仲裁"
  if [[ "${MYSQL_HA_DETECTED_ROLE}" == "arbiter" ]]; then
    if systemctl is-active --quiet replication-manager 2>/dev/null; then status_ok "repman 仲裁" "replication-manager 运行中"
    else status_crit "repman 仲裁" "replication-manager 未运行(失去自动故障切换)"; fi
    return 0
  fi
  local ip writable=0 code
  for ip in "${MYSQL_HA_NODE1_IP}" "${MYSQL_HA_NODE2_IP}"; do
    [[ -n "$ip" ]] || continue
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 4 "http://${ip}:${MYSQL_HA_MYSQLCHK_PORT}/" 2>/dev/null || true)"
    case "$code" in
      200) writable=$((writable+1)); status_cover_seen ;;
      503) status_cover_seen ;;
      *)   status_cover_unreachable; status_warn "节点 ${ip}" "mysqlchk 不可达(未纳入主判定)" ;;
    esac
  done
  if [[ "$writable" -gt 1 ]]; then status_crit "多主检测" "可达范围内 ${writable} 个可写主(脑裂)"
  elif [[ "$writable" -eq 1 ]]; then status_ok "多主检测" "可达范围内恰好 1 个可写主"
  else status_warn "多主检测" "可达范围内未发现可写主(切换中或探测受限)"; fi
  status_info "说明" "单机视角在网络分区下看不到对侧；以 repman 仲裁为准"
}
