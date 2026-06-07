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
