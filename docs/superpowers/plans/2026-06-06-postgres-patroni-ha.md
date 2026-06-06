# PostgreSQL + Patroni 两主机自动 HA 部署 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增独立入口 `install-pg-ha.sh`,在三台 Ubuntu 24.04 机器上非 Docker 部署 PostgreSQL 18 + Patroni + etcd + HAProxy,实现两主机自动故障转移。

**Architecture:** 沿用现有 `lib/` 模块化 + curl 双模加载约定;新逻辑收敛在 `lib/pg-ha/`。每台机器 curl 执行一次、交互选本机角色(primary/replica/quorum)。配置生成函数设计为纯函数,测试只验证生成内容(不真起服务),与现有 `tests/test_deploy.sh` 哲学一致,但用独立的 `tests/test_pg_ha.sh`。

**Tech Stack:** Bash(`set -euo pipefail`)、etcd v3(etcd3 段)、Patroni 4.1.x(PGDG)、PostgreSQL 18(PGDG)、HAProxy 2.8(新 http-check 语法)、systemd、softdog watchdog。

**Spec:** `docs/superpowers/specs/2026-06-06-postgres-patroni-ha-design.md`

---

## 与 spec 的细微调整(实现期发现)

- **密码不自动生成**:spec 配置表写"自动生成",但三台分别运行无法同步随机值。改为:`PG_HA_ETCD_PASSWORD`/`PG_HA_REST_PASSWORD`/`PG_HA_SUPERUSER_PASSWORD`/`PG_HA_REPLICATION_PASSWORD`/`PG_HA_REWIND_PASSWORD` 由**环境变量或交互提供,且 primary/replica 两台必须一致**(quorum 节点不需要)。`pg_ha_generate_password` 仍提供,仅用于在交互时给出建议值,不跨机自动注入。文档与摘要提示"三台一致"。

## 文件结构

| 文件 | 职责 |
|------|------|
| `install-pg-ha.sh` | 薄入口:双模加载 `lib/common.sh`+`lib/pg-ha/*.sh`,调用 `pg_ha_main` |
| `lib/pg-ha/config.sh` | 全部 `PG_HA_*` 默认值 + 文件路径变量;自兜底 `DATA_ROOT` |
| `lib/pg-ha/common.sh` | 角色解析、IP 校验、密码、预检(quorum/watchdog/连通性/时间)、交互收集 |
| `lib/pg-ha/etcd.sh` | `write_etcd_config`/`write_etcd_unit_dropin`/`install_etcd`/`enable_etcd_rbac`/`etcd_health_check`/`start_etcd` |
| `lib/pg-ha/patroni.sh` | `add_pgdg_repo`/`install_postgres_patroni`/`disable_default_cluster`/`write_patroni_yaml`/`write_patroni_unit`/`start_patroni`/`bootstrap_patroni` |
| `lib/pg-ha/haproxy.sh` | `write_haproxy_config`/`install_haproxy`/`start_haproxy` |
| `lib/pg-ha/main.sh` | `pg_ha_show_summary`/`pg_ha_main` |
| `tests/test_pg_ha.sh` | 独立测试(不污染 test_deploy.sh) |

**纯函数契约**:`write_etcd_config`/`write_patroni_yaml`/`write_haproxy_config` 等接收会变的参数(本机 name/IP)+ 读全局 `PG_HA_*` 配置,输出到全局文件路径变量(测试 export 覆盖到临时目录),与现有 `write_redis_compose(port,password)` 风格一致。

---

## Task 1: 测试框架骨架 + config 模块

**Files:**
- Create: `tests/test_pg_ha.sh`
- Create: `lib/pg-ha/config.sh`

- [ ] **Step 1: 写失败测试 — config 默认值与覆盖**

创建 `tests/test_pg_ha.sh`:

```bash
#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file_exists() { [[ -f "$1" ]] || fail "expected file to exist: $1"; }
assert_function_exists() { declare -F "$1" >/dev/null || fail "expected function: $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_not_contains() { if grep -Fq -- "$2" "$1"; then fail "did not expect '$2' in $1"; fi; }
assert_equals() { [[ "$1" == "$2" ]] || fail "expected '$1' but got '$2'"; }

# 按依赖顺序加载 PG-HA 模块(测试前先 export PG_HA_* 覆盖路径)
load_pg_ha() {
  # shellcheck disable=SC1090,SC1091
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/pg-ha/config.sh"
  source "${ROOT_DIR}/lib/pg-ha/common.sh"
  source "${ROOT_DIR}/lib/pg-ha/etcd.sh"
  source "${ROOT_DIR}/lib/pg-ha/patroni.sh"
  source "${ROOT_DIR}/lib/pg-ha/haproxy.sh"
  source "${ROOT_DIR}/lib/pg-ha/main.sh"
}

run_config_tests() {
  ( unset DATA_ROOT
    source "${ROOT_DIR}/lib/pg-ha/config.sh"
    assert_equals "/data" "${DATA_ROOT}"
    assert_equals "18" "${PG_HA_MAJOR_VERSION}"
    assert_equals "pg-ha" "${PG_HA_CLUSTER_NAME}"
    assert_equals "5000" "${PG_HA_PROXY_PORT}"
    assert_equals "30" "${PG_HA_TTL}"
    assert_equals "10" "${PG_HA_LOOP_WAIT}"
    assert_equals "10" "${PG_HA_RETRY_TIMEOUT}"
    # DCS 时序硬约束:loop_wait + 2*retry_timeout <= ttl
    [[ $(( PG_HA_LOOP_WAIT + 2 * PG_HA_RETRY_TIMEOUT )) -le "${PG_HA_TTL}" ]] \
      || fail "DCS timing constraint violated"
  )
  ( export DATA_ROOT="/opt/x" PG_HA_MAJOR_VERSION="17" PG_HA_PROXY_PORT="6000"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"
    assert_equals "/opt/x" "${DATA_ROOT}"
    assert_equals "17" "${PG_HA_MAJOR_VERSION}"
    assert_equals "6000" "${PG_HA_PROXY_PORT}"
    assert_equals "/opt/x/patroni/pgdata" "${PG_HA_PGDATA}"
  )
}

main() {
  local suite="${1:-all}"
  case "$suite" in
    config) run_config_tests ;;
    all) run_config_tests ;;
    *) fail "unknown suite: $suite" ;;
  esac
  echo "PASS: ${suite}"
}

main "$@"
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_pg_ha.sh config`
Expected: FAIL(`lib/pg-ha/config.sh` 不存在 → source 报错)

- [ ] **Step 3: 实现 config.sh**

创建 `lib/pg-ha/config.sh`(注意:**自兜底 DATA_ROOT**,不依赖主 `lib/config.sh`):

```bash
# PG-HA 专用配置;自兜底 DATA_ROOT,不加载主 lib/config.sh
DATA_ROOT="${DATA_ROOT:-/data}"

PG_HA_MAJOR_VERSION="${PG_HA_MAJOR_VERSION:-18}"
PG_HA_CLUSTER_NAME="${PG_HA_CLUSTER_NAME:-pg-ha}"

PG_HA_PG_PORT="${PG_HA_PG_PORT:-5432}"
PG_HA_PATRONI_REST_PORT="${PG_HA_PATRONI_REST_PORT:-8008}"
PG_HA_ETCD_CLIENT_PORT="${PG_HA_ETCD_CLIENT_PORT:-2379}"
PG_HA_ETCD_PEER_PORT="${PG_HA_ETCD_PEER_PORT:-2380}"
PG_HA_PROXY_PORT="${PG_HA_PROXY_PORT:-5000}"
PG_HA_PROXY_STATS_PORT="${PG_HA_PROXY_STATS_PORT:-7000}"

PG_HA_PGDATA="${PG_HA_PGDATA:-${DATA_ROOT}/patroni/pgdata}"
PG_HA_ETCD_DATA="${PG_HA_ETCD_DATA:-${DATA_ROOT}/etcd}"

PG_HA_TTL="${PG_HA_TTL:-30}"
PG_HA_LOOP_WAIT="${PG_HA_LOOP_WAIT:-10}"
PG_HA_RETRY_TIMEOUT="${PG_HA_RETRY_TIMEOUT:-10}"
PG_HA_MAX_LAG_ON_FAILOVER="${PG_HA_MAX_LAG_ON_FAILOVER:-1048576}"
PG_HA_MAX_SLOT_WAL_KEEP_SIZE="${PG_HA_MAX_SLOT_WAL_KEEP_SIZE:-10GB}"

PG_HA_SYNC_MODE="${PG_HA_SYNC_MODE:-off}"
PG_HA_SYNC_STRICT="${PG_HA_SYNC_STRICT:-off}"
PG_HA_WATCHDOG="${PG_HA_WATCHDOG:-on}"

PG_HA_APP_ALLOWED_CIDR="${PG_HA_APP_ALLOWED_CIDR:-}"

PG_HA_SUPERUSER_PASSWORD="${PG_HA_SUPERUSER_PASSWORD:-}"
PG_HA_REPLICATION_PASSWORD="${PG_HA_REPLICATION_PASSWORD:-}"
PG_HA_REWIND_PASSWORD="${PG_HA_REWIND_PASSWORD:-}"
PG_HA_ETCD_PASSWORD="${PG_HA_ETCD_PASSWORD:-}"
PG_HA_REST_PASSWORD="${PG_HA_REST_PASSWORD:-}"
PG_HA_STATS_PASSWORD="${PG_HA_STATS_PASSWORD:-}"

PG_HA_NODE1_IP="${PG_HA_NODE1_IP:-}"
PG_HA_NODE2_IP="${PG_HA_NODE2_IP:-}"
PG_HA_NODE3_IP="${PG_HA_NODE3_IP:-}"

# 运行期由 collect_config 设定
PG_HA_ROLE="${PG_HA_ROLE:-}"
PG_HA_NODE_NAME="${PG_HA_NODE_NAME:-}"
PG_HA_NODE_IP="${PG_HA_NODE_IP:-}"

# 文件路径(测试 export 覆盖到临时目录)
PG_HA_ETCD_CONFIG_FILE="${PG_HA_ETCD_CONFIG_FILE:-/etc/etcd/etcd.conf.yml}"
PG_HA_ETCD_UNIT_DROPIN="${PG_HA_ETCD_UNIT_DROPIN:-/etc/systemd/system/etcd.service.d/override.conf}"
PG_HA_PATRONI_YAML="${PG_HA_PATRONI_YAML:-/etc/patroni/patroni.yml}"
PG_HA_PATRONI_UNIT="${PG_HA_PATRONI_UNIT:-/etc/systemd/system/patroni.service}"
PG_HA_HAPROXY_CFG="${PG_HA_HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_pg_ha.sh config`
Expected: `PASS: config`

- [ ] **Step 5: 提交**

```bash
git add tests/test_pg_ha.sh lib/pg-ha/config.sh
git commit -m "feat(pg-ha): add config module and test scaffold"
```

---

## Task 2: 入口脚本 install-pg-ha.sh + skeleton 测试

**Files:**
- Create: `install-pg-ha.sh`
- Modify: `tests/test_pg_ha.sh`(加 `run_skeleton_tests` + 注册)

- [ ] **Step 1: 写失败测试 — skeleton**

在 `tests/test_pg_ha.sh` 的 `run_config_tests` 之后插入:

```bash
run_skeleton_tests() {
  local entry="${ROOT_DIR}/install-pg-ha.sh"
  assert_file_exists "$entry"
  [[ -x "$entry" ]] || fail "expected install-pg-ha.sh to be executable"
  bash -n "$entry" || fail "install-pg-ha.sh has syntax errors"
  assert_contains "$entry" "lib/pg-ha/main.sh"
  assert_contains "$entry" "lib/common.sh"
  assert_not_contains "$entry" "lib/config.sh"

  local module
  while IFS= read -r module; do
    bash -n "$module" || fail "module has syntax errors: $module"
  done < <(find "${ROOT_DIR}/lib/pg-ha" -name '*.sh' -type f | sort)

  load_pg_ha
  local fn
  for fn in pg_ha_parse_role pg_ha_validate_node_ips write_etcd_config \
            write_patroni_yaml write_haproxy_config pg_ha_main; do
    assert_function_exists "$fn"
  done
}
```

并在 `main()` 的 `case` 中加入 skeleton 分发与 all 调用:

```bash
    skeleton) run_skeleton_tests ;;
```

`all)` 分支改为:

```bash
    all) run_skeleton_tests; run_config_tests ;;
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_pg_ha.sh skeleton`
Expected: FAIL(`install-pg-ha.sh` 不存在)

- [ ] **Step 3: 实现 install-pg-ha.sh**

创建 `install-pg-ha.sh`(沿用 `install-docker.sh` 的 `load_linuxshell_modules`):

```bash
#!/usr/bin/env bash

set -euo pipefail

LINUXSHELL_RAW_BASE_URL="${LINUXSHELL_RAW_BASE_URL:-https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main}"
LINUXSHELL_MODULE_ROOT=""
LINUXSHELL_MODULE_SOURCE=""

load_linuxshell_modules() {
  local script_dir module_root module
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || pwd)"
  module_root="$script_dir"

  if [[ -f "${module_root}/lib/pg-ha/config.sh" ]]; then
    LINUXSHELL_MODULE_SOURCE="local"
  else
    module_root="$(mktemp -d)"
    LINUXSHELL_MODULE_SOURCE="remote"
    for module in "$@"; do
      mkdir -p "${module_root}/$(dirname "$module")"
      if ! curl -fsSL "${LINUXSHELL_RAW_BASE_URL}/${module}" -o "${module_root}/${module}"; then
        echo "Failed to download module: ${LINUXSHELL_RAW_BASE_URL}/${module}" >&2
        return 1
      fi
    done
  fi

  LINUXSHELL_MODULE_ROOT="$module_root"
  for module in "$@"; do
    # shellcheck disable=SC1090
    source "${module_root}/${module}"
  done
}

load_linuxshell_modules \
  lib/common.sh \
  lib/pg-ha/config.sh \
  lib/pg-ha/common.sh \
  lib/pg-ha/etcd.sh \
  lib/pg-ha/patroni.sh \
  lib/pg-ha/haproxy.sh \
  lib/pg-ha/main.sh

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  pg_ha_main "$@"
fi
```

创建占位模块(后续任务填充),使 source 不报错。创建 `lib/pg-ha/common.sh`、`lib/pg-ha/etcd.sh`、`lib/pg-ha/patroni.sh`、`lib/pg-ha/haproxy.sh`、`lib/pg-ha/main.sh`,每个先放最小内容,例如 `lib/pg-ha/common.sh`:

```bash
pg_ha_parse_role() { return 0; }
pg_ha_validate_node_ips() { return 0; }
```

`lib/pg-ha/etcd.sh`:

```bash
write_etcd_config() { return 0; }
```

`lib/pg-ha/patroni.sh`:

```bash
write_patroni_yaml() { return 0; }
```

`lib/pg-ha/haproxy.sh`:

```bash
write_haproxy_config() { return 0; }
```

`lib/pg-ha/main.sh`:

```bash
pg_ha_main() { return 0; }
```

设可执行:`chmod +x install-pg-ha.sh`

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_pg_ha.sh skeleton`
Expected: `PASS: skeleton`

- [ ] **Step 5: 提交**

```bash
git add install-pg-ha.sh lib/pg-ha/*.sh tests/test_pg_ha.sh
git commit -m "feat(pg-ha): add entrypoint and module skeletons"
```

---

## Task 3: common.sh — 角色解析、IP 校验、密码

**Files:**
- Modify: `lib/pg-ha/common.sh`
- Modify: `tests/test_pg_ha.sh`(加 `run_common_tests`)

- [ ] **Step 1: 写失败测试**

在 `tests/test_pg_ha.sh` 加:

```bash
run_common_tests() {
  load_pg_ha

  pg_ha_parse_role "1"; assert_equals "primary" "${PG_HA_ROLE}"
  pg_ha_parse_role "primary"; assert_equals "primary" "${PG_HA_ROLE}"
  pg_ha_parse_role "2"; assert_equals "replica" "${PG_HA_ROLE}"
  pg_ha_parse_role "replica"; assert_equals "replica" "${PG_HA_ROLE}"
  pg_ha_parse_role "3"; assert_equals "quorum" "${PG_HA_ROLE}"
  pg_ha_parse_role "quorum"; assert_equals "quorum" "${PG_HA_ROLE}"
  if pg_ha_parse_role "bogus" 2>/dev/null; then fail "expected bogus role to fail"; fi

  ( export PG_HA_NODE1_IP="10.0.0.1" PG_HA_NODE2_IP="10.0.0.2" PG_HA_NODE3_IP="10.0.0.3"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    pg_ha_validate_node_ips || fail "expected valid IPs to pass" )
  ( export PG_HA_NODE1_IP="10.0.0.1" PG_HA_NODE2_IP="" PG_HA_NODE3_IP="10.0.0.3"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    if pg_ha_validate_node_ips 2>/dev/null; then fail "expected empty IP to fail"; fi )
  ( export PG_HA_NODE1_IP="not-an-ip" PG_HA_NODE2_IP="10.0.0.2" PG_HA_NODE3_IP="10.0.0.3"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    if pg_ha_validate_node_ips 2>/dev/null; then fail "expected invalid IP to fail"; fi )

  local pw
  pw="$(pg_ha_generate_password)"
  [[ ${#pw} -ge 16 ]] || fail "expected generated password length >= 16"
}
```

`main()` 加 `common) run_common_tests ;;`,`all)` 末尾追加 `; run_common_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_pg_ha.sh common`
Expected: FAIL(占位 `pg_ha_parse_role` 不设 `PG_HA_ROLE`)

- [ ] **Step 3: 实现**

替换 `lib/pg-ha/common.sh` 中占位,加入:

```bash
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
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_pg_ha.sh common`
Expected: `PASS: common`

- [ ] **Step 5: 提交**

```bash
git add lib/pg-ha/common.sh tests/test_pg_ha.sh
git commit -m "feat(pg-ha): role parsing, IP validation, password helpers"
```

---

## Task 4: common.sh — 预检函数(watchdog/quorum/连通性/时间)

**Files:**
- Modify: `lib/pg-ha/common.sh`
- Modify: `tests/test_pg_ha.sh`(加 `run_precheck_tests`)

- [ ] **Step 1: 写失败测试**

```bash
run_precheck_tests() {
  load_pg_ha

  # watchdog: off 时直接通过
  ( export PG_HA_WATCHDOG="off"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    pg_ha_check_watchdog || fail "expected watchdog off to pass" )

  # quorum 等待:mock etcdctl 成功立即返回 0
  ( source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/pg-ha/common.sh"
    export PG_HA_NODE1_IP=10.0.0.1 PG_HA_NODE2_IP=10.0.0.2 PG_HA_NODE3_IP=10.0.0.3
    etcdctl() { return 0; }
    pg_ha_wait_etcd_quorum || fail "expected quorum wait to succeed when etcdctl healthy" )

  assert_function_exists pg_ha_check_connectivity
  assert_function_exists pg_ha_check_time_sync
}
```

`main()` 加 `precheck) run_precheck_tests ;;`,`all)` 追加 `; run_precheck_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_pg_ha.sh precheck`
Expected: FAIL(`pg_ha_check_watchdog` 等未定义)

- [ ] **Step 3: 实现**

向 `lib/pg-ha/common.sh` 追加:

```bash
pg_ha_check_watchdog() {
  [[ "$(to_lower "${PG_HA_WATCHDOG}")" == "on" ]] || return 0
  if [[ ! -e /dev/watchdog ]]; then
    echo "PG_HA_WATCHDOG=on but /dev/watchdog is unavailable on this host." >&2
    echo "Set PG_HA_WATCHDOG=off for this environment, or enable a watchdog device." >&2
    return 1
  fi
}

pg_ha_wait_etcd_quorum() {
  local endpoints attempt
  endpoints="${PG_HA_NODE1_IP}:${PG_HA_ETCD_CLIENT_PORT},${PG_HA_NODE2_IP}:${PG_HA_ETCD_CLIENT_PORT},${PG_HA_NODE3_IP}:${PG_HA_ETCD_CLIENT_PORT}"
  for attempt in $(seq 1 30); do
    if ETCDCTL_API=3 etcdctl --endpoints="$endpoints" endpoint health --cluster >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "etcd cluster not healthy. Ensure all three etcd nodes are up and ${PG_HA_ETCD_CLIENT_PORT}/${PG_HA_ETCD_PEER_PORT} are reachable between nodes." >&2
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

pg_ha_check_time_sync() {
  if command_exists timedatectl; then
    if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q '^yes$'; then
      echo "Warning: system clock not NTP-synchronized; etcd/Patroni leases are time-sensitive." >&2
      echo "Consider: apt-get install -y chrony" >&2
    fi
  fi
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_pg_ha.sh precheck`
Expected: `PASS: precheck`

- [ ] **Step 5: 提交**

```bash
git add lib/pg-ha/common.sh tests/test_pg_ha.sh
git commit -m "feat(pg-ha): preflight checks (watchdog/quorum/connectivity/time)"
```

---

## Task 5: etcd.sh — write_etcd_config + write_etcd_unit_dropin

**Files:**
- Modify: `lib/pg-ha/etcd.sh`
- Modify: `tests/test_pg_ha.sh`(加 `run_etcd_tests`)

- [ ] **Step 1: 写失败测试**

```bash
run_etcd_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export PG_HA_NODE1_IP="10.0.0.1" PG_HA_NODE2_IP="10.0.0.2" PG_HA_NODE3_IP="10.0.0.3"
  export PG_HA_ETCD_DATA="${temp_root}/etcd"
  export PG_HA_ETCD_CONFIG_FILE="${temp_root}/etcd.conf.yml"
  export PG_HA_ETCD_UNIT_DROPIN="${temp_root}/dropin/override.conf"
  load_pg_ha

  write_etcd_config "node1" "10.0.0.1"
  assert_file_exists "${temp_root}/etcd.conf.yml"
  assert_contains "${temp_root}/etcd.conf.yml" "name: node1"
  assert_contains "${temp_root}/etcd.conf.yml" "initial-cluster: node1=http://10.0.0.1:2380,node2=http://10.0.0.2:2380,node3=http://10.0.0.3:2380"
  assert_contains "${temp_root}/etcd.conf.yml" "initial-cluster-state: new"
  assert_contains "${temp_root}/etcd.conf.yml" "initial-cluster-token: pg-ha"
  assert_contains "${temp_root}/etcd.conf.yml" "listen-client-urls: http://10.0.0.1:2379,http://127.0.0.1:2379"

  write_etcd_unit_dropin
  assert_file_exists "${temp_root}/dropin/override.conf"
  assert_contains "${temp_root}/dropin/override.conf" "ExecStart="
  assert_contains "${temp_root}/dropin/override.conf" "--config-file=${temp_root}/etcd.conf.yml"
}
```

`main()` 加 `etcd) run_etcd_tests ;;`,`all)` 追加 `; run_etcd_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_pg_ha.sh etcd`
Expected: FAIL(占位 `write_etcd_config` 不写文件)

- [ ] **Step 3: 实现**

替换 `lib/pg-ha/etcd.sh` 占位,加入:

```bash
write_etcd_config() {
  local node_name="$1"
  local node_ip="$2"
  mkdir -p "$(dirname "${PG_HA_ETCD_CONFIG_FILE}")"
  cat >"${PG_HA_ETCD_CONFIG_FILE}" <<EOF
name: ${node_name}
data-dir: ${PG_HA_ETCD_DATA}
listen-peer-urls: http://${node_ip}:${PG_HA_ETCD_PEER_PORT}
listen-client-urls: http://${node_ip}:${PG_HA_ETCD_CLIENT_PORT},http://127.0.0.1:${PG_HA_ETCD_CLIENT_PORT}
initial-advertise-peer-urls: http://${node_ip}:${PG_HA_ETCD_PEER_PORT}
advertise-client-urls: http://${node_ip}:${PG_HA_ETCD_CLIENT_PORT}
initial-cluster: node1=http://${PG_HA_NODE1_IP}:${PG_HA_ETCD_PEER_PORT},node2=http://${PG_HA_NODE2_IP}:${PG_HA_ETCD_PEER_PORT},node3=http://${PG_HA_NODE3_IP}:${PG_HA_ETCD_PEER_PORT}
initial-cluster-state: new
initial-cluster-token: ${PG_HA_CLUSTER_NAME}
EOF
}

write_etcd_unit_dropin() {
  mkdir -p "$(dirname "${PG_HA_ETCD_UNIT_DROPIN}")"
  cat >"${PG_HA_ETCD_UNIT_DROPIN}" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/etcd --config-file=${PG_HA_ETCD_CONFIG_FILE}
EOF
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_pg_ha.sh etcd`
Expected: `PASS: etcd`

- [ ] **Step 5: 提交**

```bash
git add lib/pg-ha/etcd.sh tests/test_pg_ha.sh
git commit -m "feat(pg-ha): generate etcd config and systemd drop-in"
```

---

## Task 6: etcd.sh — install_etcd / start_etcd / enable_etcd_rbac / etcd_health_check

**Files:**
- Modify: `lib/pg-ha/etcd.sh`
- Modify: `tests/test_pg_ha.sh`(扩展 `run_etcd_tests` 末尾加函数存在断言)

> 这些是系统安装/操作函数,无法在 CI 真跑;测试只断言函数存在 + 语法。

- [ ] **Step 1: 写失败测试**

在 `run_etcd_tests` 末尾追加:

```bash
  assert_function_exists install_etcd
  assert_function_exists start_etcd
  assert_function_exists enable_etcd_rbac
  assert_function_exists etcd_health_check
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_pg_ha.sh etcd`
Expected: FAIL(`install_etcd` 等未定义)

- [ ] **Step 3: 实现**

向 `lib/pg-ha/etcd.sh` 追加:

```bash
install_etcd() {
  print_step "Installing etcd"
  if command_exists etcd; then
    echo "etcd already installed."
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  if apt-get install -y etcd-server etcd-client 2>/dev/null; then
    echo "etcd installed from distribution packages."
  else
    echo "Distribution etcd unavailable; installing official binary v3.5.16." >&2
    local ver="v3.5.16" arch tmp
    arch="$(dpkg --print-architecture)"
    tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ver}/etcd-${ver}-linux-${arch}.tar.gz" \
      -o "${tmp}/etcd.tar.gz"
    tar -xzf "${tmp}/etcd.tar.gz" -C "${tmp}" --strip-components=1
    install -m 0755 "${tmp}/etcd" "${tmp}/etcdctl" /usr/bin/
    rm -rf "${tmp}"
    cat >/etc/systemd/system/etcd.service <<'UNIT'
[Unit]
Description=etcd
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/etcd
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
  fi
  mkdir -p "${PG_HA_ETCD_DATA}"
}

start_etcd() {
  write_etcd_unit_dropin
  systemctl daemon-reload
  systemctl enable etcd
  systemctl restart etcd
}

etcd_health_check() {
  local endpoint="${PG_HA_NODE_IP}:${PG_HA_ETCD_CLIENT_PORT}"
  ETCDCTL_API=3 etcdctl --endpoints="$endpoint" endpoint health
}

# 仅在 primary 执行一次:创建 RBAC 用户并启用认证(集群级生效)
enable_etcd_rbac() {
  local ep="${PG_HA_NODE1_IP}:${PG_HA_ETCD_CLIENT_PORT}"
  if ETCDCTL_API=3 etcdctl --endpoints="$ep" auth status 2>/dev/null | grep -q "Authentication Status: true"; then
    echo "etcd auth already enabled."
    return 0
  fi
  ETCDCTL_API=3 etcdctl --endpoints="$ep" user add root:"${PG_HA_ETCD_PASSWORD}"
  ETCDCTL_API=3 etcdctl --endpoints="$ep" user grant-role root root
  ETCDCTL_API=3 etcdctl --endpoints="$ep" user add patroni:"${PG_HA_ETCD_PASSWORD}"
  ETCDCTL_API=3 etcdctl --endpoints="$ep" role add patroni-role
  ETCDCTL_API=3 etcdctl --endpoints="$ep" role grant-permission patroni-role --prefix=true readwrite "/service/${PG_HA_CLUSTER_NAME}/"
  ETCDCTL_API=3 etcdctl --endpoints="$ep" user grant-role patroni patroni-role
  ETCDCTL_API=3 etcdctl --endpoints="$ep" auth enable
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_pg_ha.sh etcd && bash -n lib/pg-ha/etcd.sh`
Expected: `PASS: etcd`,语法检查无输出

- [ ] **Step 5: 提交**

```bash
git add lib/pg-ha/etcd.sh tests/test_pg_ha.sh
git commit -m "feat(pg-ha): etcd install/start/RBAC/health functions"
```

---

## Task 7: patroni.sh — write_patroni_yaml(核心纯函数)

**Files:**
- Modify: `lib/pg-ha/patroni.sh`
- Modify: `tests/test_pg_ha.sh`(加 `run_patroni_tests`)

- [ ] **Step 1: 写失败测试**

```bash
run_patroni_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export PG_HA_NODE1_IP="10.0.0.1" PG_HA_NODE2_IP="10.0.0.2" PG_HA_NODE3_IP="10.0.0.3"
  export PG_HA_PGDATA="${temp_root}/pgdata"
  export PG_HA_PATRONI_YAML="${temp_root}/patroni.yml"
  export PG_HA_ETCD_PASSWORD="etcdpw" PG_HA_REST_PASSWORD="restpw"
  export PG_HA_SUPERUSER_PASSWORD="superpw" PG_HA_REPLICATION_PASSWORD="reppw" PG_HA_REWIND_PASSWORD="rewpw"
  export PG_HA_APP_ALLOWED_CIDR="10.0.0.0/24"
  export PG_HA_WATCHDOG="on" PG_HA_SYNC_MODE="off"
  load_pg_ha

  write_patroni_yaml "node1" "10.0.0.1"
  assert_file_exists "${temp_root}/patroni.yml"
  assert_contains "${temp_root}/patroni.yml" "scope: pg-ha"
  assert_contains "${temp_root}/patroni.yml" "name: node1"
  assert_contains "${temp_root}/patroni.yml" "listen: 10.0.0.1:8008"
  assert_contains "${temp_root}/patroni.yml" "etcd3:"
  assert_contains "${temp_root}/patroni.yml" "- 10.0.0.1:2379"
  assert_contains "${temp_root}/patroni.yml" "username: patroni"
  assert_contains "${temp_root}/patroni.yml" "password: etcdpw"
  assert_contains "${temp_root}/patroni.yml" "ttl: 30"
  assert_contains "${temp_root}/patroni.yml" "loop_wait: 10"
  assert_contains "${temp_root}/patroni.yml" "retry_timeout: 10"
  assert_contains "${temp_root}/patroni.yml" "maximum_lag_on_failover: 1048576"
  assert_contains "${temp_root}/patroni.yml" "synchronous_mode: false"
  assert_contains "${temp_root}/patroni.yml" "use_slots: true"
  assert_contains "${temp_root}/patroni.yml" "use_pg_rewind: true"
  assert_contains "${temp_root}/patroni.yml" "max_slot_wal_keep_size: 10GB"
  assert_contains "${temp_root}/patroni.yml" "wal_log_hints:"
  assert_contains "${temp_root}/patroni.yml" "data_dir: ${temp_root}/pgdata"
  assert_contains "${temp_root}/patroni.yml" "bin_dir: /usr/lib/postgresql/18/bin"
  assert_contains "${temp_root}/patroni.yml" "data-checksums"
  assert_contains "${temp_root}/patroni.yml" "host all all 10.0.0.0/24 md5"
  assert_contains "${temp_root}/patroni.yml" "mode: required"
  assert_contains "${temp_root}/patroni.yml" "device: /dev/watchdog"
  # DCS 时序硬约束断言(从生成文件解析)
  local ttl lw rt
  ttl="$(grep -E '^\s*ttl:' "${temp_root}/patroni.yml" | head -1 | grep -oE '[0-9]+')"
  lw="$(grep -E '^\s*loop_wait:' "${temp_root}/patroni.yml" | head -1 | grep -oE '[0-9]+')"
  rt="$(grep -E '^\s*retry_timeout:' "${temp_root}/patroni.yml" | head -1 | grep -oE '[0-9]+')"
  [[ $(( lw + 2 * rt )) -le "$ttl" ]] || fail "generated yaml violates loop_wait+2*retry_timeout<=ttl"

  # watchdog off 分支
  ( export PG_HA_WATCHDOG="off" PG_HA_PATRONI_YAML="${temp_root}/patroni-off.yml"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"
    source "${ROOT_DIR}/lib/pg-ha/common.sh"; source "${ROOT_DIR}/lib/pg-ha/patroni.sh"
    export PG_HA_NODE1_IP=10.0.0.1 PG_HA_NODE2_IP=10.0.0.2 PG_HA_NODE3_IP=10.0.0.3
    export PG_HA_ETCD_PASSWORD=x PG_HA_REST_PASSWORD=x PG_HA_SUPERUSER_PASSWORD=x
    export PG_HA_REPLICATION_PASSWORD=x PG_HA_REWIND_PASSWORD=x PG_HA_APP_ALLOWED_CIDR=10.0.0.0/24
    write_patroni_yaml "node1" "10.0.0.1"
    assert_contains "${temp_root}/patroni-off.yml" 'mode: "off"'
    assert_not_contains "${temp_root}/patroni-off.yml" "device: /dev/watchdog" )

  # sync on 分支
  ( export PG_HA_SYNC_MODE="on" PG_HA_PATRONI_YAML="${temp_root}/patroni-sync.yml"
    source "${ROOT_DIR}/lib/pg-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"
    source "${ROOT_DIR}/lib/pg-ha/common.sh"; source "${ROOT_DIR}/lib/pg-ha/patroni.sh"
    export PG_HA_NODE1_IP=10.0.0.1 PG_HA_NODE2_IP=10.0.0.2 PG_HA_NODE3_IP=10.0.0.3
    export PG_HA_ETCD_PASSWORD=x PG_HA_REST_PASSWORD=x PG_HA_SUPERUSER_PASSWORD=x
    export PG_HA_REPLICATION_PASSWORD=x PG_HA_REWIND_PASSWORD=x PG_HA_APP_ALLOWED_CIDR=10.0.0.0/24
    write_patroni_yaml "node1" "10.0.0.1"
    assert_contains "${temp_root}/patroni-sync.yml" "synchronous_mode: true" )
}
```

`main()` 加 `patroni) run_patroni_tests ;;`,`all)` 追加 `; run_patroni_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_pg_ha.sh patroni`
Expected: FAIL(占位 `write_patroni_yaml` 不写文件)

- [ ] **Step 3: 实现**

替换 `lib/pg-ha/patroni.sh` 占位,加入:

```bash
write_patroni_yaml() {
  local node_name="$1"
  local node_ip="$2"
  local sync_mode="false" sync_strict="false" watchdog_block

  [[ "$(to_lower "${PG_HA_SYNC_MODE}")" == "on" ]] && sync_mode="true"
  [[ "$(to_lower "${PG_HA_SYNC_STRICT}")" == "on" ]] && sync_strict="true"

  if [[ "$(to_lower "${PG_HA_WATCHDOG}")" == "on" ]]; then
    watchdog_block="watchdog:
  mode: required
  device: /dev/watchdog
  safety_margin: 5"
  else
    watchdog_block="watchdog:
  mode: \"off\""
  fi

  mkdir -p "$(dirname "${PG_HA_PATRONI_YAML}")"
  cat >"${PG_HA_PATRONI_YAML}" <<EOF
scope: ${PG_HA_CLUSTER_NAME}
name: ${node_name}

restapi:
  listen: ${node_ip}:${PG_HA_PATRONI_REST_PORT}
  connect_address: ${node_ip}:${PG_HA_PATRONI_REST_PORT}
  authentication:
    username: patroni
    password: ${PG_HA_REST_PASSWORD}

etcd3:
  hosts:
    - ${PG_HA_NODE1_IP}:${PG_HA_ETCD_CLIENT_PORT}
    - ${PG_HA_NODE2_IP}:${PG_HA_ETCD_CLIENT_PORT}
    - ${PG_HA_NODE3_IP}:${PG_HA_ETCD_CLIENT_PORT}
  username: patroni
  password: ${PG_HA_ETCD_PASSWORD}
  protocol: http

bootstrap:
  dcs:
    ttl: ${PG_HA_TTL}
    loop_wait: ${PG_HA_LOOP_WAIT}
    retry_timeout: ${PG_HA_RETRY_TIMEOUT}
    maximum_lag_on_failover: ${PG_HA_MAX_LAG_ON_FAILOVER}
    synchronous_mode: ${sync_mode}
    synchronous_mode_strict: ${sync_strict}
    postgresql:
      use_slots: true
      use_pg_rewind: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        max_slot_wal_keep_size: ${PG_HA_MAX_SLOT_WAL_KEEP_SIZE}
        wal_log_hints: "on"
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - local all all trust
    - host replication replicator ${PG_HA_NODE1_IP}/32 md5
    - host replication replicator ${PG_HA_NODE2_IP}/32 md5
    - host all all ${PG_HA_APP_ALLOWED_CIDR} md5
    - host all all 127.0.0.1/32 md5

postgresql:
  listen: ${node_ip}:${PG_HA_PG_PORT}
  connect_address: ${node_ip}:${PG_HA_PG_PORT}
  data_dir: ${PG_HA_PGDATA}
  bin_dir: /usr/lib/postgresql/${PG_HA_MAJOR_VERSION}/bin
  authentication:
    superuser:
      username: postgres
      password: ${PG_HA_SUPERUSER_PASSWORD}
    replication:
      username: replicator
      password: ${PG_HA_REPLICATION_PASSWORD}
    rewind:
      username: rewind_user
      password: ${PG_HA_REWIND_PASSWORD}

${watchdog_block}

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF
  chmod 600 "${PG_HA_PATRONI_YAML}"
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_pg_ha.sh patroni`
Expected: `PASS: patroni`

- [ ] **Step 5: 提交**

```bash
git add lib/pg-ha/patroni.sh tests/test_pg_ha.sh
git commit -m "feat(pg-ha): generate patroni.yml with watchdog/sync branches"
```

---

## Task 8: patroni.sh — write_patroni_unit(自写 service 绕过包装层)

**Files:**
- Modify: `lib/pg-ha/patroni.sh`
- Modify: `tests/test_pg_ha.sh`(扩展 `run_patroni_tests`)

- [ ] **Step 1: 写失败测试**

在 `run_patroni_tests` 主体(顶层,非子 shell)末尾追加:

```bash
  export PG_HA_PATRONI_UNIT="${temp_root}/patroni.service"
  write_patroni_unit
  assert_file_exists "${temp_root}/patroni.service"
  assert_contains "${temp_root}/patroni.service" "After=network-online.target etcd.service"
  assert_contains "${temp_root}/patroni.service" "User=postgres"
  assert_contains "${temp_root}/patroni.service" "ExecStart=/usr/bin/patroni ${temp_root}/patroni.yml"
  assert_contains "${temp_root}/patroni.service" "KillMode=process"
  assert_contains "${temp_root}/patroni.service" "Restart=no"
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_pg_ha.sh patroni`
Expected: FAIL(`write_patroni_unit` 未定义)

- [ ] **Step 3: 实现**

向 `lib/pg-ha/patroni.sh` 追加:

```bash
write_patroni_unit() {
  mkdir -p "$(dirname "${PG_HA_PATRONI_UNIT}")"
  cat >"${PG_HA_PATRONI_UNIT}" <<EOF
[Unit]
Description=Patroni PostgreSQL HA
After=network-online.target etcd.service
Wants=network-online.target etcd.service

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/bin/patroni ${PG_HA_PATRONI_YAML}
ExecReload=/bin/kill -s HUP \$MAINPID
KillMode=process
Restart=no
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_pg_ha.sh patroni`
Expected: `PASS: patroni`

- [ ] **Step 5: 提交**

```bash
git add lib/pg-ha/patroni.sh tests/test_pg_ha.sh
git commit -m "feat(pg-ha): self-written patroni.service unit"
```

---

## Task 9: patroni.sh — PGDG 安装 + 禁用默认 cluster + 引导

**Files:**
- Modify: `lib/pg-ha/patroni.sh`
- Modify: `tests/test_pg_ha.sh`(扩展 `run_patroni_tests` 末尾函数存在断言)

> 系统安装函数,测试只断言存在 + 语法。

- [ ] **Step 1: 写失败测试**

在 `run_patroni_tests` 主体末尾追加:

```bash
  assert_function_exists add_pgdg_repo
  assert_function_exists install_postgres_patroni
  assert_function_exists disable_default_cluster
  assert_function_exists start_patroni
  assert_function_exists bootstrap_patroni
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_pg_ha.sh patroni`
Expected: FAIL(`add_pgdg_repo` 等未定义)

- [ ] **Step 3: 实现**

向 `lib/pg-ha/patroni.sh` 追加:

```bash
add_pgdg_repo() {
  print_step "Adding PGDG apt repository"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y postgresql-common
  # 官方脚本按 lsb_release -cs 自动选 suite,跨 Ubuntu 版本稳定
  /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
}

install_postgres_patroni() {
  print_step "Installing PostgreSQL ${PG_HA_MAJOR_VERSION} + Patroni"
  add_pgdg_repo
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  # PGDG patroni 与 PG 同源;python3-etcd 是 etcd3 模块的必需依赖
  apt-get install -y \
    "postgresql-${PG_HA_MAJOR_VERSION}" \
    "postgresql-client-${PG_HA_MAJOR_VERSION}" \
    patroni \
    python3-etcd
}

# PGDG 装包会自动建并启动默认 cluster 占用 5432;交还控制权给 Patroni
disable_default_cluster() {
  print_step "Disabling distribution default PostgreSQL cluster"
  if pg_lsclusters -h 2>/dev/null | grep -q "^${PG_HA_MAJOR_VERSION}\s\+main"; then
    pg_dropcluster --stop "${PG_HA_MAJOR_VERSION}" main || true
  fi
  systemctl disable --now postgresql 2>/dev/null || true
  mkdir -p "${PG_HA_PGDATA}"
  chown -R postgres:postgres "$(dirname "${PG_HA_PGDATA}")"
}

start_patroni() {
  write_patroni_unit
  chown postgres:postgres "${PG_HA_PATRONI_YAML}"
  systemctl daemon-reload
  systemctl enable patroni
  systemctl restart patroni
}

# primary 首次引导:等 etcd quorum + 启用 RBAC,再起 Patroni 成为 leader
bootstrap_patroni() {
  pg_ha_wait_etcd_quorum
  enable_etcd_rbac
  start_patroni
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_pg_ha.sh patroni && bash -n lib/pg-ha/patroni.sh`
Expected: `PASS: patroni`,语法检查无输出

- [ ] **Step 5: 提交**

```bash
git add lib/pg-ha/patroni.sh tests/test_pg_ha.sh
git commit -m "feat(pg-ha): PGDG install, drop default cluster, bootstrap"
```

---

## Task 10: haproxy.sh — write_haproxy_config + install/start

**Files:**
- Modify: `lib/pg-ha/haproxy.sh`
- Modify: `tests/test_pg_ha.sh`(加 `run_haproxy_tests`)

- [ ] **Step 1: 写失败测试**

```bash
run_haproxy_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export PG_HA_NODE1_IP="10.0.0.1" PG_HA_NODE2_IP="10.0.0.2"
  export PG_HA_HAPROXY_CFG="${temp_root}/haproxy.cfg"
  export PG_HA_STATS_PASSWORD="statspw"
  load_pg_ha

  write_haproxy_config
  assert_file_exists "${temp_root}/haproxy.cfg"
  assert_contains "${temp_root}/haproxy.cfg" "bind *:5000"
  assert_contains "${temp_root}/haproxy.cfg" "option httpchk"
  assert_contains "${temp_root}/haproxy.cfg" "http-check send meth GET uri /primary"
  assert_contains "${temp_root}/haproxy.cfg" "http-check expect status 200"
  assert_contains "${temp_root}/haproxy.cfg" "on-marked-down shutdown-sessions"
  assert_contains "${temp_root}/haproxy.cfg" "server node1 10.0.0.1:5432 check port 8008"
  assert_contains "${temp_root}/haproxy.cfg" "server node2 10.0.0.2:5432 check port 8008"
  assert_contains "${temp_root}/haproxy.cfg" "stats auth admin:statspw"
  # 不应出现已弃用的老语法
  assert_not_contains "${temp_root}/haproxy.cfg" "option httpchk GET /primary"

  assert_function_exists install_haproxy
  assert_function_exists start_haproxy
}
```

`main()` 加 `haproxy) run_haproxy_tests ;;`,`all)` 追加 `; run_haproxy_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_pg_ha.sh haproxy`
Expected: FAIL(占位 `write_haproxy_config` 不写文件)

- [ ] **Step 3: 实现**

替换 `lib/pg-ha/haproxy.sh` 占位,加入:

```bash
write_haproxy_config() {
  mkdir -p "$(dirname "${PG_HA_HAPROXY_CFG}")"
  cat >"${PG_HA_HAPROXY_CFG}" <<EOF
global
    maxconn 1000
    log /dev/log local0

defaults
    log global
    mode tcp
    retries 2
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 5s

frontend pg_write
    bind *:${PG_HA_PROXY_PORT}
    default_backend pg_primary

backend pg_primary
    option httpchk
    http-check send meth GET uri /primary
    http-check expect status 200
    default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions
    server node1 ${PG_HA_NODE1_IP}:${PG_HA_PG_PORT} check port ${PG_HA_PATRONI_REST_PORT}
    server node2 ${PG_HA_NODE2_IP}:${PG_HA_PG_PORT} check port ${PG_HA_PATRONI_REST_PORT}

listen stats
    bind *:${PG_HA_PROXY_STATS_PORT}
    mode http
    stats enable
    stats uri /
    stats auth admin:${PG_HA_STATS_PASSWORD}
EOF
}

install_haproxy() {
  print_step "Installing HAProxy"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y haproxy
}

start_haproxy() {
  write_haproxy_config
  systemctl enable haproxy
  systemctl restart haproxy
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_pg_ha.sh haproxy`
Expected: `PASS: haproxy`

- [ ] **Step 5: 提交**

```bash
git add lib/pg-ha/haproxy.sh tests/test_pg_ha.sh
git commit -m "feat(pg-ha): generate haproxy config (new http-check syntax)"
```

---

## Task 11: main.sh — collect_config + 编排 + summary

**Files:**
- Modify: `lib/pg-ha/common.sh`(加 `pg_ha_collect_config`)
- Modify: `lib/pg-ha/main.sh`(`pg_ha_main` + `pg_ha_show_summary`)
- Modify: `tests/test_pg_ha.sh`(加 `run_orchestration_tests`)

- [ ] **Step 1: 写失败测试**

```bash
run_orchestration_tests() {
  local temp_root action_log
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN
  action_log="${temp_root}/actions.log"

  export PG_HA_NODE1_IP="10.0.0.1" PG_HA_NODE2_IP="10.0.0.2" PG_HA_NODE3_IP="10.0.0.3"
  export PG_HA_ETCD_PASSWORD=x PG_HA_REST_PASSWORD=x PG_HA_SUPERUSER_PASSWORD=x
  export PG_HA_REPLICATION_PASSWORD=x PG_HA_REWIND_PASSWORD=x PG_HA_STATS_PASSWORD=x
  export PG_HA_APP_ALLOWED_CIDR="10.0.0.0/24"
  load_pg_ha

  # mock 所有副作用函数
  require_root() { :; }
  detect_os() { :; }
  install_etcd() { echo install_etcd >>"$action_log"; }
  write_etcd_config() { echo write_etcd_config >>"$action_log"; }
  start_etcd() { echo start_etcd >>"$action_log"; }
  enable_etcd_rbac() { echo enable_etcd_rbac >>"$action_log"; }
  install_postgres_patroni() { echo install_postgres_patroni >>"$action_log"; }
  disable_default_cluster() { echo disable_default_cluster >>"$action_log"; }
  write_patroni_yaml() { echo write_patroni_yaml >>"$action_log"; }
  start_patroni() { echo start_patroni >>"$action_log"; }
  bootstrap_patroni() { echo bootstrap_patroni >>"$action_log"; }
  install_haproxy() { echo install_haproxy >>"$action_log"; }
  start_haproxy() { echo start_haproxy >>"$action_log"; }
  pg_ha_wait_etcd_quorum() { :; }
  pg_ha_check_watchdog() { :; }
  pg_ha_check_time_sync() { :; }
  pg_ha_show_summary() { echo summary >>"$action_log"; }

  # quorum 角色:只装 etcd,不碰 patroni/haproxy
  : >"$action_log"
  pg_ha_collect_config() { PG_HA_ROLE=quorum; PG_HA_NODE_NAME=node3; PG_HA_NODE_IP=10.0.0.3; }
  pg_ha_main
  assert_contains "$action_log" "install_etcd"
  assert_not_contains "$action_log" "install_postgres_patroni"
  assert_not_contains "$action_log" "install_haproxy"

  # primary 角色:etcd + patroni + haproxy + bootstrap
  : >"$action_log"
  pg_ha_collect_config() { PG_HA_ROLE=primary; PG_HA_NODE_NAME=node1; PG_HA_NODE_IP=10.0.0.1; }
  pg_ha_main
  assert_contains "$action_log" "install_etcd"
  assert_contains "$action_log" "install_postgres_patroni"
  assert_contains "$action_log" "bootstrap_patroni"
  assert_contains "$action_log" "install_haproxy"

  # replica 角色:etcd + patroni(start,非 bootstrap) + haproxy
  : >"$action_log"
  pg_ha_collect_config() { PG_HA_ROLE=replica; PG_HA_NODE_NAME=node2; PG_HA_NODE_IP=10.0.0.2; }
  pg_ha_main
  assert_contains "$action_log" "install_postgres_patroni"
  assert_contains "$action_log" "start_patroni"
  assert_not_contains "$action_log" "bootstrap_patroni"
  assert_contains "$action_log" "install_haproxy"
}
```

`main()` 加 `orchestration) run_orchestration_tests ;;`,`all)` 追加 `; run_orchestration_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_pg_ha.sh orchestration`
Expected: FAIL(`pg_ha_collect_config`/真实 `pg_ha_main` 未实现)

- [ ] **Step 3: 实现**

向 `lib/pg-ha/common.sh` 追加:

```bash
pg_ha_collect_config() {
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
    PG_HA_APP_ALLOWED_CIDR="$(prompt_with_default "Application allowed CIDR (e.g. 10.0.0.0/24)" "${PG_HA_APP_ALLOWED_CIDR}")"
    PG_HA_REST_PASSWORD="$(prompt_with_default "Patroni REST password (identical on PG nodes)" "${PG_HA_REST_PASSWORD}")"
    PG_HA_SUPERUSER_PASSWORD="$(prompt_with_default "postgres superuser password (identical on PG nodes)" "${PG_HA_SUPERUSER_PASSWORD}")"
    PG_HA_REPLICATION_PASSWORD="$(prompt_with_default "replication password (identical on PG nodes)" "${PG_HA_REPLICATION_PASSWORD}")"
    PG_HA_REWIND_PASSWORD="$(prompt_with_default "rewind password (identical on PG nodes)" "${PG_HA_REWIND_PASSWORD}")"
    PG_HA_STATS_PASSWORD="$(prompt_with_default "HAProxy stats password" "${PG_HA_STATS_PASSWORD:-$(pg_ha_generate_password)}")"
  fi
}
```

替换 `lib/pg-ha/main.sh` 占位:

```bash
pg_ha_show_summary() {
  print_step "PostgreSQL HA deployment summary"
  echo "Role: ${PG_HA_ROLE} (${PG_HA_NODE_NAME} @ ${PG_HA_NODE_IP})"
  echo "Cluster: ${PG_HA_CLUSTER_NAME} | etcd: ${PG_HA_NODE1_IP},${PG_HA_NODE2_IP},${PG_HA_NODE3_IP}"
  if [[ "${PG_HA_ROLE}" != "quorum" ]]; then
    echo "App connects to HAProxy :${PG_HA_PROXY_PORT} (read+write, always current primary)"
    echo "Configure your app with BOTH HAProxy addresses (${PG_HA_NODE1_IP}:${PG_HA_PROXY_PORT}, ${PG_HA_NODE2_IP}:${PG_HA_PROXY_PORT}) and connection-retry."
    echo "Verify: patronictl -c ${PG_HA_PATRONI_YAML} list"
  fi
  if [[ "$(to_lower "${PG_HA_WATCHDOG}")" == "off" ]]; then
    echo "WARNING: watchdog disabled — split-brain protection is OFF (double-write risk on Patroni failure)."
  fi
  echo "Passwords must be identical across primary/replica. Store them securely."
}

pg_ha_main() {
  require_root
  detect_os
  pg_ha_collect_config
  pg_ha_validate_node_ips
  pg_ha_check_time_sync

  case "${PG_HA_ROLE}" in
    quorum)
      install_etcd
      write_etcd_config "${PG_HA_NODE_NAME}" "${PG_HA_NODE_IP}"
      start_etcd
      ;;
    primary)
      pg_ha_check_watchdog
      install_etcd
      write_etcd_config "${PG_HA_NODE_NAME}" "${PG_HA_NODE_IP}"
      start_etcd
      install_postgres_patroni
      disable_default_cluster
      write_patroni_yaml "${PG_HA_NODE_NAME}" "${PG_HA_NODE_IP}"
      bootstrap_patroni
      install_haproxy
      start_haproxy
      ;;
    replica)
      pg_ha_check_watchdog
      install_etcd
      write_etcd_config "${PG_HA_NODE_NAME}" "${PG_HA_NODE_IP}"
      start_etcd
      install_postgres_patroni
      disable_default_cluster
      write_patroni_yaml "${PG_HA_NODE_NAME}" "${PG_HA_NODE_IP}"
      pg_ha_wait_etcd_quorum
      start_patroni
      install_haproxy
      start_haproxy
      ;;
  esac

  pg_ha_show_summary
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_pg_ha.sh orchestration`
Expected: `PASS: orchestration`

- [ ] **Step 5: 提交**

```bash
git add lib/pg-ha/common.sh lib/pg-ha/main.sh tests/test_pg_ha.sh
git commit -m "feat(pg-ha): config collection, role orchestration, summary"
```

---

## Task 12: README 文档更新

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 写失败测试**

在 `tests/test_pg_ha.sh` 加:

```bash
run_docs_tests() {
  local readme="${ROOT_DIR}/README.md"
  assert_contains "$readme" "install-pg-ha.sh"
  assert_contains "$readme" "Patroni"
  assert_contains "$readme" "PG_HA_NODE1_IP"
}
```

`main()` 加 `docs) run_docs_tests ;;`,`all)` 追加 `; run_docs_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_pg_ha.sh docs`
Expected: FAIL(README 未含相关内容)

- [ ] **Step 3: 实现**

在 `README.md` 的"支持的组件"表之后插入新小节(放在"快捷使用 psql"之前):

````markdown
## PostgreSQL 高可用(Patroni,非 Docker)

在三台 Ubuntu 24.04 机器上部署 PostgreSQL 18 + Patroni + etcd + HAProxy,实现两主机自动故障转移(第三台仅作 etcd 仲裁)。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-pg-ha.sh)
```

**在每台机器各运行一次**,交互选择本机角色:

| 角色 | 说明 |
|------|------|
| 1) primary | PG 主节点(首次初始化集群) |
| 2) replica | PG 从节点(自动克隆) |
| 3) etcd-quorum | 仅 etcd 仲裁(不跑 PG) |

**推荐执行顺序**:三台先各自起 etcd → 再 primary → 最后 replica。

**应用连接**:连 HAProxy `5000`(读写都到当前主库)。为接入冗余,应用应配置**两台** HAProxy 地址(`node1:5000`、`node2:5000`)并具备连接失败重试能力。

**需放行端口**(脚本不改防火墙):节点间 `2379`/`2380`(etcd)、`8008`(Patroni REST,HAProxy 跨机健康检查)、`5432`(PG/复制)、`5000`/`7000`(HAProxy)。

**密码**:`PG_HA_ETCD_PASSWORD`/`PG_HA_REST_PASSWORD`/`PG_HA_SUPERUSER_PASSWORD`/`PG_HA_REPLICATION_PASSWORD`/`PG_HA_REWIND_PASSWORD` **必须在 primary/replica 两台保持一致**(经环境变量或交互提供)。

**安全**:控制面启用认证(etcd RBAC + Patroni REST basic auth + HAProxy stats auth),不启用 TLS,依赖网络隔离。

**watchdog**:默认 `PG_HA_WATCHDOG=on`(softdog 防脑裂)。无 `/dev/watchdog` 的云主机会启动失败,需显式设 `PG_HA_WATCHDOG=off`(将关闭防脑裂兜底)。

**关键环境变量**:`PG_HA_NODE1_IP`/`2`/`3`、`PG_HA_MAJOR_VERSION`(默认 18)、`PG_HA_CLUSTER_NAME`(默认 pg-ha)、`PG_HA_SYNC_MODE`(默认 off;on 切零丢失同步复制)、`DATA_ROOT`(默认 /data)。

> 这是**非 Docker** 路径,与现有 Docker 版 PostgreSQL(`deploy.sh` 菜单项 2)并存,互不影响。
````

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_pg_ha.sh docs`
Expected: `PASS: docs`

- [ ] **Step 5: 提交**

```bash
git add README.md tests/test_pg_ha.sh
git commit -m "docs: README 增加 PostgreSQL + Patroni HA 说明"
```

---

## Task 13: 全套验证 + 现有测试保持绿色

**Files:** 无新增(仅验证)

- [ ] **Step 1: 运行 PG-HA 全套测试**

Run: `bash tests/test_pg_ha.sh all`
Expected: `PASS: all`

- [ ] **Step 2: 全部脚本语法检查**

Run:
```bash
bash -n install-pg-ha.sh
find lib/pg-ha -name '*.sh' -print0 | xargs -0 -n1 bash -n
```
Expected: 无任何输出(全部通过)

- [ ] **Step 3: 现有测试保持绿色**

Run: `bash tests/test_deploy.sh all`
Expected: `PASS: all`(现有 Docker 部署不受影响)

- [ ] **Step 4: 确认现有入口不受影响**

Run: `bash -n deploy.sh && bash -n install-docker.sh && bash -n install-pg-wrapper.sh`
Expected: 无输出

- [ ] **Step 5: 最终提交(如有未提交变更)**

```bash
git add -A
git commit -m "test(pg-ha): full suite green; existing tests unaffected" || echo "nothing to commit"
```

---

## Self-Review(计划完成后自查)

**1. Spec 覆盖** — 逐节核对 spec → 任务:

| spec 要求 | 实现任务 |
|-----------|----------|
| config 默认值 + DATA_ROOT 自兜底 | Task 1 |
| 入口双模加载 + 不加载 lib/config.sh | Task 2 |
| 角色解析/IP 校验/密码 | Task 3 |
| 预检(watchdog/quorum/连通性/时间) | Task 4 |
| etcd config(etcd3/三成员) + unit `--config-file` | Task 5 |
| etcd 安装/RBAC/健康检查 | Task 6 |
| patroni.yml(etcd3+凭据/ttl 约束/sync/watchdog/槽护栏/三账号) | Task 7 |
| 自写 patroni.service 绕过包装层 | Task 8 |
| PGDG 安装/禁用默认 cluster/引导 | Task 9 |
| HAProxy 新 http-check 语法 + stats auth | Task 10 |
| 角色编排 + 摘要 | Task 11 |
| README 更新 | Task 12 |
| 独立 test_pg_ha.sh + 现有测试绿 | Task 1-13 |

控制面认证:etcd RBAC(Task 6)、Patroni REST auth(Task 7 yaml)、stats auth(Task 10)、文件 600(Task 7)。reinstall 拆分:本计划聚焦首次部署正确性;reinstall 两类路径作为**已知后续增强**记录(见下"范围说明")。

**2. Placeholder 扫描** — 无 "TBD/TODO";安装函数(install_etcd 等)给了完整实现而非占位;所有 write_* 给了完整 heredoc。

**3. 类型/命名一致性** — 函数名跨任务一致:`write_etcd_config`/`write_patroni_yaml`/`write_haproxy_config`/`write_etcd_unit_dropin`/`write_patroni_unit`/`pg_ha_main`/`pg_ha_collect_config`/`pg_ha_show_summary`/`enable_etcd_rbac`/`bootstrap_patroni`/`start_patroni`。全局变量名与 config.sh 一致。

**范围说明(对 spec 的有意收窄):** 本计划聚焦"首次三角色部署 + 配置生成正确性"。spec 中的 **reinstall 两类路径(PG 层 vs etcd 成员级)、复制槽清理、pg_rewind fallback** 涉及运行期状态,无法用配置生成测试覆盖,且体量大;建议作为**第二个计划**(`2026-06-06-postgres-patroni-ha-reinstall.md`)单独实现,保持本计划可独立交付、可测试。自动 failover / 单主路由的运行期正确性,依赖 spec"成功标准"里的手工/集成验收(本计划的单元测试只保证配置正确)。
