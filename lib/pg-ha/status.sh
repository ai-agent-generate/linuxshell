#!/usr/bin/env bash
# lib/pg-ha/status.sh — PostgreSQL HA 只读巡检
# 依赖:lib/common.sh + lib/status-common.sh + lib/pg-ha/config.sh + lib/pg-ha/common.sh
set -euo pipefail

PG_HA_DETECTED_ROLE=""
PG_HA_LOCAL_IP=""

# 本机只读 SQL:走 patroni.yml 的 local trust(postgres 为 superuser，内部视图全可读)
pg_ha_status_local_psql() {
  sudo -u postgres psql -tAqc "$1" 2>/dev/null || true
}

# 从 etcd.conf.yml 的 initial-cluster 还原节点 IP(config 默认空，部署未落盘)
pg_ha_status_load_topology() {
  local ic n ip
  ic="$(status_extract_kv "${PG_HA_ETCD_CONFIG_FILE}" 's/^initial-cluster:[[:space:]]*\(.*\)$/\1/p')"
  [[ -n "$ic" ]] || return 0
  for n in 1 2 3; do
    ip="$(printf '%s' "$ic" | sed -E -n "s/.*node${n}=http:\\/\\/([0-9.]+):[0-9]+.*/\1/p")"
    [[ -n "$ip" ]] || continue
    case "$n" in
      1) PG_HA_NODE1_IP="$ip" ;;
      2) PG_HA_NODE2_IP="$ip" ;;
      3) PG_HA_NODE3_IP="$ip" ;;
    esac
  done
}

# 角色发现:patroni.yml 存在=数据节点(再看 recovery)，否则有 etcd 配置=quorum
pg_ha_status_detect_role() {
  if [[ -e "${PG_HA_PATRONI_YAML}" ]]; then
    local rec; rec="$(pg_ha_status_local_psql 'SELECT pg_is_in_recovery()')"
    case "$rec" in
      f|false) PG_HA_DETECTED_ROLE="primary" ;;
      t|true)  PG_HA_DETECTED_ROLE="replica" ;;
      *)       PG_HA_DETECTED_ROLE="unknown" ;;
    esac
  elif [[ -e "${PG_HA_ETCD_CONFIG_FILE}" ]]; then
    PG_HA_DETECTED_ROLE="quorum"
  else
    PG_HA_DETECTED_ROLE="unknown"
  fi
  printf '%s' "${PG_HA_DETECTED_ROLE}"
  return 0
}

pg_ha_status_identity() {
  status_section "本机身份"
  status_kv "集群名" "${PG_HA_CLUSTER_NAME}"
  status_kv "主机名" "$(hostname 2>/dev/null || echo unknown)"
  local lip node="unknown"
  if lip="$(status_local_ip "${PG_HA_NODE1_IP}" "${PG_HA_NODE2_IP}" "${PG_HA_NODE3_IP}" 2>/dev/null)"; then
    [[ "$lip" == "${PG_HA_NODE1_IP}" ]] && node="node1"
    [[ "$lip" == "${PG_HA_NODE2_IP}" ]] && node="node2"
    [[ "$lip" == "${PG_HA_NODE3_IP}" ]] && node="node3"
    PG_HA_LOCAL_IP="$lip"
  else
    lip="(未匹配 NODE*_IP)"
  fi
  status_kv "本机 IP / 编号" "${lip} / ${node}"
  case "${PG_HA_DETECTED_ROLE}" in
    primary) status_ok   "本机角色" "primary (PG 主库 / Leader)" ;;
    replica) status_ok   "本机角色" "replica (PG 从库)" ;;
    quorum)  status_ok   "本机角色" "etcd-quorum (仅仲裁，不跑 PG)" ;;
    *)       status_warn "本机角色" "无法确定(patroni.yml/etcd 配置缺失或本机 PG 不可连)" ;;
  esac
  return 0
}

# 单个 systemd 服务:active+enabled->OK；active 未自启->WARN；否则->CRIT
pg_ha_status_service_one() {
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

pg_ha_status_services() {
  status_section "服务健康"
  pg_ha_status_service_one etcd
  local p ports
  if [[ "${PG_HA_DETECTED_ROLE}" == "quorum" ]]; then
    status_info "patroni/haproxy" "etcd-quorum 节点不运行，跳过"
    ports="${PG_HA_ETCD_CLIENT_PORT} ${PG_HA_ETCD_PEER_PORT}"
  else
    pg_ha_status_service_one patroni
    pg_ha_status_service_one haproxy
    ports="${PG_HA_PG_PORT} ${PG_HA_PATRONI_REST_PORT} ${PG_HA_ETCD_CLIENT_PORT} ${PG_HA_PROXY_PORT}"
  fi
  for p in $ports; do
    if port_in_use "$p"; then status_ok "端口 $p" "监听中"; else status_warn "端口 $p" "未监听"; fi
  done
  return 0
}

pg_ha_status_topology() {
  status_section "集群拓扑"
  if [[ "${PG_HA_DETECTED_ROLE}" == "quorum" ]]; then
    if curl -fsS "http://127.0.0.1:${PG_HA_ETCD_CLIENT_PORT}/health" 2>/dev/null \
         | grep -q '"health"[[:space:]]*:[[:space:]]*"true"'; then
      status_ok "etcd 本机健康" "/health=true(PG 拓扑明细见数据节点)"
    else
      status_warn "etcd 本机健康" "/health 非 true 或不可达"
    fi
    return 0
  fi
  command_exists patronictl || { status_warn "集群拓扑" "patronictl 不可用"; return 0; }
  local out; out="$(patronictl -c "${PG_HA_PATRONI_YAML}" list 2>/dev/null || true)"
  [[ -n "$out" ]] || { status_warn "集群拓扑" "patronictl list 无输出"; return 0; }
  printf '%s\n' "$out" | status_redact
  if printf '%s' "$out" | grep -qiE 'Leader'; then
    status_ok "集群 Leader" "存在"
  else
    _pg_probe_leader() { patronictl -c "${PG_HA_PATRONI_YAML}" list 2>/dev/null | grep -qiE 'Leader'; }
    local rc=0; status_recheck _pg_probe_leader || rc=$?
    case "$rc" in
      0)  status_ok   "集群 Leader" "存在(复采)" ;;
      10) status_warn "集群 Leader" "首检无 Leader，复采已恢复(疑似切换中)" ;;
      *)  status_crit "集群 Leader" "持续无 Leader(选举失败/集群异常)" ;;
    esac
  fi
  return 0
}

pg_ha_status_replication() {
  case "${PG_HA_DETECTED_ROLE}" in primary|replica) ;; *) status_info "复制健康" "本机非 PG 数据节点，跳过"; return 0 ;; esac
  status_section "复制健康"
  if [[ "${PG_HA_DETECTED_ROLE}" == "primary" ]]; then
    local rows failover_mb
    failover_mb=$(( PG_HA_MAX_LAG_ON_FAILOVER / 1024 / 1024 ))
    [[ "$failover_mb" -lt 1 ]] && failover_mb=1
    rows="$(pg_ha_status_local_psql "SELECT client_addr||' '||state||' '||COALESCE(sync_state,'async')||' '||COALESCE((pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn)/1024/1024)::bigint::text,'?') FROM pg_stat_replication")"
    [[ -n "$rows" ]] || { status_warn "复制" "主库无已连接 standby(从库未连接?)"; return 0; }
    local line addr st sync lagmb
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      addr="$(awk '{print $1}' <<<"$line")"; st="$(awk '{print $2}' <<<"$line")"
      sync="$(awk '{print $3}' <<<"$line")"; lagmb="$(awk '{print $4}' <<<"$line")"
      if [[ "$st" != "streaming" ]]; then
        status_crit "standby ${addr}" "state=${st}(非 streaming)"
      elif [[ "$lagmb" =~ ^[0-9]+$ ]] && [[ "$lagmb" -ge "${STATUS_PG_LAG_CRIT_MB}" ]]; then
        status_crit "standby ${addr}" "滞后 ${lagmb}MB(>=${STATUS_PG_LAG_CRIT_MB}MB)"
      elif [[ "$lagmb" =~ ^[0-9]+$ ]] && [[ "$lagmb" -gt "$failover_mb" ]]; then
        status_warn "standby ${addr}" "滞后 ${lagmb}MB 超 failover 阈值 ${failover_mb}MB(主库故障时不会被选为新主)"
      else
        status_ok "standby ${addr}" "streaming, sync=${sync}, 滞后 ${lagmb}MB"
      fi
    done <<<"$rows"
  else
    local rec; rec="$(pg_ha_status_local_psql 'SELECT pg_is_in_recovery()')"
    if [[ "$rec" == "t" || "$rec" == "true" ]]; then
      status_ok "本机从库" "处于 recovery(正常接收复制)"
    else
      status_crit "本机从库" "pg_is_in_recovery()=${rec}(从库却非 recovery?)"
    fi
  fi
  return 0
}

pg_ha_status_degradation() {
  case "${PG_HA_DETECTED_ROLE}" in primary|replica) ;; *) return 0 ;; esac
  status_section "静默退化检测"
  if [[ "${PG_HA_DETECTED_ROLE}" == "primary" ]]; then
    local inactive; inactive="$(pg_ha_status_local_psql "SELECT slot_name FROM pg_replication_slots WHERE active=false")"
    if [[ -n "$inactive" ]]; then
      status_warn "复制槽 inactive" "$(printf '%s' "$inactive" | tr '\n' ',')(WAL 会为其堆积，可能撑爆磁盘)"
    else
      status_ok "复制槽" "全部 active"
    fi
  fi
  if command_exists patronictl; then
    local pls; pls="$(patronictl -c "${PG_HA_PATRONI_YAML}" list 2>/dev/null || true)"
    if printf '%s' "$pls" | grep -qiE 'Maintenance|paused'; then
      status_warn "Patroni 维护模式" "集群处于 pause/maintenance，自动故障切换已禁用(记得 resume)"
    else
      status_ok "Patroni 维护模式" "未暂停"
    fi
    local tls tlcount
    tls="$(printf '%s\n' "$pls" | grep -oE '\| *[0-9]+ *\|' | grep -oE '[0-9]+' | sort -un)"
    tlcount="$(printf '%s\n' "$tls" | grep -c . || true)"
    [[ "$tlcount" -gt 1 ]] && status_warn "时间线(TL)分叉" "节点 TL 不一致($(printf '%s' "$tls" | tr '\n' ' '))，可能发生过未对齐切换"
  fi
  return 0
}

pg_ha_status_ingress() {
  case "${PG_HA_DETECTED_ROLE}" in primary|replica) ;; *) return 0 ;; esac
  status_section "入口一致性"
  local pass; pass="$(status_extract_kv "${PG_HA_HAPROXY_CFG}" 's/.*stats auth admin:\(.*\)/\1/p')"
  [[ -n "$pass" ]] || { status_warn "HAProxy stats" "无法从 haproxy.cfg 提取 stats 凭据"; return 0; }
  _pg_up_count() {
    status_curl_cred admin "$pass" -fsS "http://127.0.0.1:${PG_HA_PROXY_STATS_PORT}/;csv" 2>/dev/null \
      | awk -F, '$1=="pg_primary" && $18=="UP" {n++} END{print n+0}'
  }
  local up; up="$(_pg_up_count)"
  if [[ "$up" == "1" ]]; then
    status_ok "HAProxy 写入口" "唯一 UP 后端"
  else
    _pg_probe_ingress() { [[ "$(_pg_up_count)" == "1" ]]; }
    local rc=0; status_recheck _pg_probe_ingress || rc=$?
    case "$rc" in
      0)  status_ok   "HAProxy 写入口" "复采为唯一 UP 后端" ;;
      10) status_warn "HAProxy 写入口" "首检 UP 后端数=${up}，复采已恢复(疑似切换中)" ;;
      *)  if [[ "$up" == "0" ]]; then status_crit "HAProxy 写入口" "无 UP 后端(当前无写入口)"
          else status_crit "HAProxy 写入口" "${up} 个后端同时 UP(路由错乱/双主嫌疑)"; fi ;;
    esac
  fi
  return 0
}

pg_ha_status_splitbrain() {
  status_section "防脑裂 / 仲裁"
  if curl -fsS "http://127.0.0.1:${PG_HA_ETCD_CLIENT_PORT}/health" 2>/dev/null \
       | grep -q '"health"[[:space:]]*:[[:space:]]*"true"'; then
    status_ok "etcd 本机" "/health=true"
  else
    status_crit "etcd 本机" "/health 非 true 或不可达(影响自动故障转移)"
  fi
  [[ "${PG_HA_DETECTED_ROLE}" == "quorum" ]] && { status_info "多主检测" "quorum 节点不参与 PG 主判定"; return 0; }
  local ip primaries=0 code
  for ip in "${PG_HA_NODE1_IP}" "${PG_HA_NODE2_IP}"; do
    [[ -n "$ip" ]] || continue
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 4 "http://${ip}:${PG_HA_PATRONI_REST_PORT}/primary" 2>/dev/null || true)"
    case "$code" in
      200) primaries=$((primaries+1)); status_cover_seen ;;
      503) status_cover_seen ;;
      *)   status_cover_unreachable; status_warn "节点 ${ip}" "Patroni REST 不可达(未纳入主判定)" ;;
    esac
  done
  if [[ "$primaries" -gt 1 ]]; then status_crit "多主检测" "可达范围内发现 ${primaries} 个可写主(脑裂)"
  elif [[ "$primaries" -eq 1 ]]; then status_ok "多主检测" "可达范围内恰好 1 个主"
  else status_warn "多主检测" "可达范围内未发现主(可能切换中或探测受限)"; fi
  status_info "说明" "单机视角在网络分区下看不到对侧；多主检测为尽力而为，以 etcd Leader 为准"
  return 0
}
