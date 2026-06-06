#!/usr/bin/env bash
# lib/pg-ha/common.sh — PG-HA 专用公共函数

pg_ha_parse_role() {
  local input
  input="$(to_lower "$1")"
  case "$input" in
    1|primary|master) PG_HA_ROLE="primary" ;;
    2|replica|standby|slave) PG_HA_ROLE="replica" ;;
    3|quorum|etcd|witness) PG_HA_ROLE="quorum" ;;
    *) echo "Unknown role: $1 (use 1/primary, 2/replica, 3/quorum)" >&2; return 1 ;;
  esac
}

pg_ha_validate_node_ips() {
  local ip
  for ip in "${PG_HA_NODE1_IP}" "${PG_HA_NODE2_IP}" "${PG_HA_NODE3_IP}"; do
    if [[ -z "$ip" ]]; then
      echo "All three node IPs must be set (PG_HA_NODE1_IP/2/3)." >&2
      return 1
    fi
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Invalid IP address: $ip" >&2
      return 1
    fi
  done
}

pg_ha_generate_password() {
  openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-25
}

pg_ha_require_passwords() {
  local var
  for var in PG_HA_ETCD_PASSWORD PG_HA_REST_PASSWORD PG_HA_SUPERUSER_PASSWORD \
             PG_HA_REPLICATION_PASSWORD PG_HA_REWIND_PASSWORD; do
    if [[ -z "${!var}" ]]; then
      echo "${var} must be set (identical on primary and replica nodes)." >&2
      return 1
    fi
  done
}

pg_ha_detect_server_type() {
  local configured value path
  configured="$(to_lower "${PG_HA_SERVER_TYPE:-auto}")"
  case "$configured" in
    cloud|dedicated)
      printf "%s" "$configured"
      return 0
      ;;
    auto|"")
      ;;
    *)
      echo "Invalid PG_HA_SERVER_TYPE: ${PG_HA_SERVER_TYPE} (use auto, cloud, or dedicated)." >&2
      return 1
      ;;
  esac

  if command_exists systemd-detect-virt && systemd-detect-virt --quiet 2>/dev/null; then
    printf "cloud"
    return 0
  fi

  for path in /sys/class/dmi/id/product_name \
              /sys/class/dmi/id/product_version \
              /sys/class/dmi/id/sys_vendor \
              /sys/class/dmi/id/chassis_asset_tag; do
    [[ -r "$path" ]] || continue
    value="$(to_lower "$(tr -d '\000' <"$path" 2>/dev/null || true)")"
    case "$value" in
      *amazon*|*ec2*|*google*|*gce*|*microsoft*|*azure*|*digitalocean*|*linode*|*akamai*|*vultr*|*alibaba*|*tencent*|*huawei*|*oracle*|*openstack*|*cloud*|*kvm*|*qemu*|*xen*|*vmware*|*virtualbox*|*bochs*|*hyper-v*|*parallels*)
        printf "cloud"
        return 0
        ;;
    esac
  done

  printf "dedicated"
}

pg_ha_resolve_watchdog() {
  local configured server_type
  configured="$(to_lower "${PG_HA_WATCHDOG:-auto}")"
  case "$configured" in
    on|off)
      printf "%s" "$configured"
      return 0
      ;;
    auto|"")
      ;;
    *)
      echo "Invalid PG_HA_WATCHDOG: ${PG_HA_WATCHDOG} (use auto, on, or off)." >&2
      return 1
      ;;
  esac

  server_type="$(pg_ha_detect_server_type)" || return 1
  case "$server_type" in
    cloud) printf "off" ;;
    dedicated) printf "on" ;;
    *)
      echo "Invalid resolved server type: ${server_type}" >&2
      return 1
      ;;
  esac
}

pg_ha_watchdog_device() {
  printf "%s" "${PG_HA_WATCHDOG_DEVICE:-/dev/watchdog}"
}

pg_ha_check_watchdog() {
  local watchdog_mode server_type device
  watchdog_mode="$(pg_ha_resolve_watchdog)" || return 1
  if [[ "$watchdog_mode" != "on" ]]; then
    if [[ "$(to_lower "${PG_HA_WATCHDOG:-auto}")" == "auto" ]]; then
      server_type="$(pg_ha_detect_server_type)" || return 1
      if [[ "$server_type" == "cloud" ]]; then
        echo "PG_HA_WATCHDOG=auto detected cloud/virtual server; watchdog disabled." >&2
        echo "WARNING: split-brain protection is OFF unless your platform provides another fencing mechanism." >&2
      fi
    fi
    return 0
  fi

  device="$(pg_ha_watchdog_device)"
  if [[ ! -e "$device" ]]; then
    echo "PG_HA_WATCHDOG=${PG_HA_WATCHDOG} resolved to on, but ${device} is unavailable on this host." >&2
    echo "For cloud servers use PG_HA_WATCHDOG=auto/off; for dedicated servers enable a watchdog device or set PG_HA_WATCHDOG=off only if you accept split-brain risk." >&2
    return 1
  fi
}

pg_ha_wait_etcd_quorum() {
  local endpoint attempt
  endpoint="${PG_HA_NODE_IP:-127.0.0.1}:${PG_HA_ETCD_CLIENT_PORT}"
  for attempt in $(seq 1 30); do
    # 用 etcd /health 端点判断:它无需认证,而 `endpoint health --cluster` 在
    # RBAC auth 启用后(primary 引导阶段会启用)的 member-list 步骤需要凭据,
    # 会导致 replica 部署时预检误失败。本机 etcd 健康即表示集群有多数派可服务。
    if curl -fsS "http://${endpoint}/health" 2>/dev/null | grep -q '"health"[[:space:]]*:[[:space:]]*"true"'; then
      return 0
    fi
    sleep 2
  done
  echo "etcd not healthy at ${endpoint}. Ensure all three etcd nodes are up and ${PG_HA_ETCD_CLIENT_PORT}/${PG_HA_ETCD_PEER_PORT} are reachable between nodes." >&2
  return 1
}

pg_ha_check_connectivity() {
  local host="$1" port="$2"
  if command_exists nc; then
    nc -z -w 3 "$host" "$port" >/dev/null 2>&1
  else
    timeout 3 bash -c ">/dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

pg_ha_setup_watchdog() {
  local watchdog_mode device
  watchdog_mode="$(pg_ha_resolve_watchdog)" || return 1
  [[ "$watchdog_mode" == "on" ]] || return 0
  device="$(pg_ha_watchdog_device)"
  echo "softdog" >/etc/modules-load.d/softdog.conf
  modprobe softdog 2>/dev/null || true
  cat >/etc/udev/rules.d/99-watchdog.rules <<'RULES'
KERNEL=="watchdog*", OWNER="postgres", GROUP="postgres", MODE="0600"
RULES
  udevadm control --reload 2>/dev/null || true
  udevadm trigger 2>/dev/null || true
  if [[ -e "$device" ]]; then
    chown postgres:postgres "$device" 2>/dev/null || true
  fi
}

pg_ha_preflight_connectivity() {
  # 非阻塞:仅探测并提示。因每台分别运行、按 quorum→primary→replica 顺序部署时,
  # 后部署节点的 etcd 尚未启动属正常,不应中断。真正的就绪门禁由
  # pg_ha_wait_etcd_quorum(本机 etcd /health)负责。
  local node_ip unreachable=0
  for node_ip in "${PG_HA_NODE1_IP}" "${PG_HA_NODE2_IP}" "${PG_HA_NODE3_IP}"; do
    if ! pg_ha_check_connectivity "$node_ip" "${PG_HA_ETCD_CLIENT_PORT}"; then
      echo "Note: etcd ${PG_HA_ETCD_CLIENT_PORT} on ${node_ip} not reachable yet (node may not be started)." >&2
      unreachable=1
    fi
  done
  if [[ "$unreachable" -eq 1 ]]; then
    echo "If this persists after all nodes are deployed, open ${PG_HA_ETCD_CLIENT_PORT}/${PG_HA_ETCD_PEER_PORT} between nodes." >&2
  fi
  return 0
}

pg_ha_check_time_sync() {
  if command_exists timedatectl; then
    if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q '^yes$'; then
      echo "Warning: system clock not NTP-synchronized; etcd/Patroni leases are time-sensitive." >&2
      echo "Consider: apt-get install -y chrony" >&2
    fi
  fi
}

pg_ha_collect_config() {
  cat >&2 <<'GUIDE'

=== PostgreSQL 高可用部署 ===
本脚本需在【每台机器各运行一次】,每次选择"本机"的角色(这是正常流程,不是重复)。
推荐顺序: (1) 先在 etcd-quorum 节点运行 -> (2) 再 primary(主库) -> (3) 最后 replica(从库)
三个节点 IP 与各项密码,必须在所有节点上填写【完全一致】。

GUIDE
  local role_input
  role_input="$(prompt_with_default "Node role (1=primary, 2=replica, 3=etcd-quorum)" "1")"
  pg_ha_parse_role "$role_input"

  PG_HA_NODE1_IP="$(prompt_with_default "Node1 (primary) IP" "${PG_HA_NODE1_IP}")"
  PG_HA_NODE2_IP="$(prompt_with_default "Node2 (replica) IP" "${PG_HA_NODE2_IP}")"
  PG_HA_NODE3_IP="$(prompt_with_default "Node3 (etcd quorum) IP" "${PG_HA_NODE3_IP}")"

  case "${PG_HA_ROLE}" in
    primary) PG_HA_NODE_NAME="node1"; PG_HA_NODE_IP="${PG_HA_NODE1_IP}" ;;
    replica) PG_HA_NODE_NAME="node2"; PG_HA_NODE_IP="${PG_HA_NODE2_IP}" ;;
    quorum)  PG_HA_NODE_NAME="node3"; PG_HA_NODE_IP="${PG_HA_NODE3_IP}" ;;
  esac

  # etcd RBAC 密码三台一致(node3 仅 etcd 也需 root 密码用于 auth)
  PG_HA_ETCD_PASSWORD="$(prompt_with_default "etcd password (MUST be identical on all nodes)" "${PG_HA_ETCD_PASSWORD}")"

  if [[ "${PG_HA_ROLE}" != "quorum" ]]; then
    PG_HA_SERVER_TYPE="$(prompt_with_default "Server type (auto=detect, cloud, dedicated)" "${PG_HA_SERVER_TYPE}")"
    PG_HA_APP_ALLOWED_CIDR="$(prompt_with_default "Application allowed CIDR (e.g. 10.0.0.0/24)" "${PG_HA_APP_ALLOWED_CIDR}")"
    PG_HA_REST_PASSWORD="$(prompt_with_default "Patroni REST password (identical on PG nodes)" "${PG_HA_REST_PASSWORD}")"
    PG_HA_SUPERUSER_PASSWORD="$(prompt_with_default "postgres superuser password (identical on PG nodes)" "${PG_HA_SUPERUSER_PASSWORD}")"
    PG_HA_REPLICATION_PASSWORD="$(prompt_with_default "replication password (identical on PG nodes)" "${PG_HA_REPLICATION_PASSWORD}")"
    PG_HA_REWIND_PASSWORD="$(prompt_with_default "rewind password (identical on PG nodes)" "${PG_HA_REWIND_PASSWORD}")"
    PG_HA_STATS_PASSWORD="$(prompt_with_default "HAProxy stats password" "${PG_HA_STATS_PASSWORD:-$(pg_ha_generate_password)}")"
  fi
}
