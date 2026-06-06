# MySQL + Orchestrator 两主机自动 HA 部署 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增独立入口 `install-mysql-ha.sh`,在三台 Ubuntu 24.04 机器上非 Docker 部署 Oracle MySQL 8.4 + Orchestrator + HAProxy/mysqlchk + watcher,实现两主机自动故障转移 + 稳态自愈 + 失多数票自我隔离。

**Architecture:** 沿用现有 `lib/` 模块化 + curl 双模加载约定;新逻辑收敛在 `lib/mysql-ha/`。每台机器 curl 执行一次、交互选本机角色(primary/replica/arbiter)。配置生成函数为纯函数,测试只验证生成内容(不真起服务),用独立 `tests/test_mysql_ha.sh`。**关键:Orchestrator 只在提升瞬间置一次 read_only,不维护稳态可写性 → 引入 `mysql-ha-watcher` 常驻补足(自愈收敛 + 失 raft 多数票自我 `super_read_only=ON`)。**

**Tech Stack:** Bash(`set -euo pipefail`)、Oracle MySQL 8.4 LTS(MySQL APT 源)、GTID 复制(可选半同步)、Orchestrator(openark,raft + SQLite,HTTP basic auth)、HAProxy 2.8(新 http-check 语法)+ mysqlchk(systemd socket 激活)、systemd。

**Spec:** `docs/superpowers/specs/2026-06-06-mysql-orchestrator-ha-design.md`

---

## 与 spec 的细微调整(实现期确认)

- **密码不自动跨机同步**:三台分别运行无法同步随机值。`MYSQL_HA_ROOT/REPL/ORCH/ORCH_HTTP/MYSQLCHK/WATCHER/APP_PASSWORD` 由环境变量或交互提供,且**数据节点两台必须一致**(`ORCH`/`ORCH_HTTP` 三台一致)。`mysql_ha_generate_password` 仅用于交互时给建议值。
- **账号经 GTID 复制**:账号仅在 primary 用 SQL 创建,经 binlog 复制到 replica;replica 不重复建。mysqlchk/watcher 本地凭据文件密码须与 primary 生成值一致(故两台相同)。
- **本机工具走 socket**:mysqlchk/watcher 连本机 MySQL 走 `/var/run/mysqld/mysqld.sock`,不受 `bind-address` 业务网卡限制。
- **datadir 迁移**:apt 在 `/var/lib/mysql` 初始化(含 debconf root 密码),再 rsync 到 `${MYSQL_HA_DATADIR}` 保留 root 凭据,避免 `--initialize` 与 debconf 冲突。

## 文件结构

| 文件 | 职责 |
|------|------|
| `install-mysql-ha.sh` | 薄入口:双模加载 `lib/common.sh`+`lib/mysql-ha/*.sh`,调用 `mysql_ha_main` |
| `lib/mysql-ha/config.sh` | 全部 `MYSQL_HA_*` 默认值 + 文件路径变量;自兜底 `DATA_ROOT` |
| `lib/mysql-ha/common.sh` | 角色解析、IP 校验、密码、预检(连通性/时间/raft quorum)、交互收集 |
| `lib/mysql-ha/mysql.sh` | APT 源、装包、`write_my_cnf`、datadir 迁移/AppArmor、建账号、配复制 |
| `lib/mysql-ha/orchestrator.sh` | `write_orchestrator_config`/client cnf/unit/install/start/discover |
| `lib/mysql-ha/mysqlchk.sh` | `write_mysqlchk_script`(完整 HTTP)/cnf/socket/service unit + setup/start |
| `lib/mysql-ha/watcher.sh` | `write_watcher_script`(自愈+自我隔离)/cnf/unit + setup/start |
| `lib/mysql-ha/haproxy.sh` | `write_haproxy_config`/install/start |
| `lib/mysql-ha/main.sh` | `mysql_ha_show_summary`/`mysql_ha_main` |
| `tests/test_mysql_ha.sh` | 独立测试(不污染 test_deploy.sh / test_pg_ha.sh) |

**纯函数契约**:`write_my_cnf`/`write_orchestrator_config`/`write_mysqlchk_script`/`write_watcher_script`/`write_haproxy_config` 接收会变的参数(server_id/角色/本机 IP)+ 读全局 `MYSQL_HA_*`,输出到全局文件路径变量(测试 export 覆盖到临时目录)。

---

## Task 1: 测试框架骨架 + config 模块

**Files:**
- Create: `tests/test_mysql_ha.sh`
- Create: `lib/mysql-ha/config.sh`

- [ ] **Step 1: 写失败测试 — config 默认值与覆盖**

创建 `tests/test_mysql_ha.sh`:

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
assert_mode() { # $1=file $2=expected octal(e.g. 600)
  local m; m="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null)"
  [[ "$m" == "$2" ]] || fail "expected mode $2 on $1 but got $m"
}

# 按依赖顺序加载 MySQL-HA 模块(测试前先 export MYSQL_HA_* 覆盖路径)
load_mysql_ha() {
  # shellcheck disable=SC1090,SC1091
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/mysql-ha/config.sh"
  source "${ROOT_DIR}/lib/mysql-ha/common.sh"
  source "${ROOT_DIR}/lib/mysql-ha/mysql.sh"
  source "${ROOT_DIR}/lib/mysql-ha/orchestrator.sh"
  source "${ROOT_DIR}/lib/mysql-ha/mysqlchk.sh"
  source "${ROOT_DIR}/lib/mysql-ha/watcher.sh"
  source "${ROOT_DIR}/lib/mysql-ha/haproxy.sh"
  source "${ROOT_DIR}/lib/mysql-ha/main.sh"
}

run_config_tests() {
  ( unset DATA_ROOT
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"
    assert_equals "/data" "${DATA_ROOT}"
    assert_equals "8.4" "${MYSQL_HA_VERSION}"
    assert_equals "mysql-ha" "${MYSQL_HA_CLUSTER_NAME}"
    assert_equals "3306" "${MYSQL_HA_MYSQL_PORT}"
    assert_equals "6446" "${MYSQL_HA_PROXY_PORT}"
    assert_equals "9200" "${MYSQL_HA_MYSQLCHK_PORT}"
    assert_equals "3000" "${MYSQL_HA_ORCH_PORT}"
    assert_equals "10008" "${MYSQL_HA_ORCH_RAFT_PORT}"
    assert_equals "off" "${MYSQL_HA_SEMISYNC}"
    assert_equals "" "${MYSQL_HA_APP_ALLOWED_CIDR}"
    assert_equals "/data/mysql-ha/data" "${MYSQL_HA_DATADIR}"
  )
  ( export DATA_ROOT="/opt/x" MYSQL_HA_VERSION="8.4" MYSQL_HA_PROXY_PORT="7000"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"
    assert_equals "/opt/x" "${DATA_ROOT}"
    assert_equals "7000" "${MYSQL_HA_PROXY_PORT}"
    assert_equals "/opt/x/mysql-ha/data" "${MYSQL_HA_DATADIR}"
    assert_equals "/opt/x/mysql-ha/orchestrator" "${MYSQL_HA_ORCH_DATADIR}"
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

Run: `bash tests/test_mysql_ha.sh config`
Expected: FAIL(`lib/mysql-ha/config.sh` 不存在 → source 报错)

- [ ] **Step 3: 实现 config.sh**

创建 `lib/mysql-ha/config.sh`(**自兜底 DATA_ROOT**,不加载主 `lib/config.sh`):

```bash
# MySQL-HA 专用配置;自兜底 DATA_ROOT,不加载主 lib/config.sh
DATA_ROOT="${DATA_ROOT:-/data}"

MYSQL_HA_VERSION="${MYSQL_HA_VERSION:-8.4}"
MYSQL_HA_CLUSTER_NAME="${MYSQL_HA_CLUSTER_NAME:-mysql-ha}"

MYSQL_HA_MYSQL_PORT="${MYSQL_HA_MYSQL_PORT:-3306}"
MYSQL_HA_PROXY_PORT="${MYSQL_HA_PROXY_PORT:-6446}"
MYSQL_HA_PROXY_STATS_PORT="${MYSQL_HA_PROXY_STATS_PORT:-7001}"
MYSQL_HA_MYSQLCHK_PORT="${MYSQL_HA_MYSQLCHK_PORT:-9200}"
MYSQL_HA_ORCH_PORT="${MYSQL_HA_ORCH_PORT:-3000}"
MYSQL_HA_ORCH_RAFT_PORT="${MYSQL_HA_ORCH_RAFT_PORT:-10008}"

MYSQL_HA_DATADIR="${MYSQL_HA_DATADIR:-${DATA_ROOT}/mysql-ha/data}"
MYSQL_HA_ORCH_DATADIR="${MYSQL_HA_ORCH_DATADIR:-${DATA_ROOT}/mysql-ha/orchestrator}"

MYSQL_HA_WATCHER_INTERVAL="${MYSQL_HA_WATCHER_INTERVAL:-5}"
MYSQL_HA_INSTANCE_POLL_SECONDS="${MYSQL_HA_INSTANCE_POLL_SECONDS:-5}"
MYSQL_HA_RECOVERY_BLOCK_SECONDS="${MYSQL_HA_RECOVERY_BLOCK_SECONDS:-3600}"
MYSQL_HA_PROMOTION_LAG_SECONDS="${MYSQL_HA_PROMOTION_LAG_SECONDS:-60}"
MYSQL_HA_BINLOG_EXPIRE_SECONDS="${MYSQL_HA_BINLOG_EXPIRE_SECONDS:-604800}"

MYSQL_HA_SEMISYNC="${MYSQL_HA_SEMISYNC:-off}"
MYSQL_HA_SEMISYNC_TIMEOUT="${MYSQL_HA_SEMISYNC_TIMEOUT:-1000}"

MYSQL_HA_APP_DB="${MYSQL_HA_APP_DB:-appdb}"
MYSQL_HA_APP_USER="${MYSQL_HA_APP_USER:-appuser}"
MYSQL_HA_APP_ALLOWED_CIDR="${MYSQL_HA_APP_ALLOWED_CIDR:-}"

MYSQL_HA_ROOT_PASSWORD="${MYSQL_HA_ROOT_PASSWORD:-}"
MYSQL_HA_REPL_PASSWORD="${MYSQL_HA_REPL_PASSWORD:-}"
MYSQL_HA_ORCH_PASSWORD="${MYSQL_HA_ORCH_PASSWORD:-}"
MYSQL_HA_ORCH_HTTP_PASSWORD="${MYSQL_HA_ORCH_HTTP_PASSWORD:-}"
MYSQL_HA_MYSQLCHK_PASSWORD="${MYSQL_HA_MYSQLCHK_PASSWORD:-}"
MYSQL_HA_WATCHER_PASSWORD="${MYSQL_HA_WATCHER_PASSWORD:-}"
MYSQL_HA_APP_PASSWORD="${MYSQL_HA_APP_PASSWORD:-}"
MYSQL_HA_STATS_PASSWORD="${MYSQL_HA_STATS_PASSWORD:-}"

MYSQL_HA_NODE1_IP="${MYSQL_HA_NODE1_IP:-}"
MYSQL_HA_NODE2_IP="${MYSQL_HA_NODE2_IP:-}"
MYSQL_HA_NODE3_IP="${MYSQL_HA_NODE3_IP:-}"

# 服务账号用户名(随 MySQL 运行用户;cnf 文件 owner 须 = 对应 service User)
MYSQL_HA_SERVICE_USER="${MYSQL_HA_SERVICE_USER:-mysql}"

# 运行期由 collect_config 设定
MYSQL_HA_ROLE="${MYSQL_HA_ROLE:-}"
MYSQL_HA_NODE_NAME="${MYSQL_HA_NODE_NAME:-}"
MYSQL_HA_NODE_IP="${MYSQL_HA_NODE_IP:-}"
MYSQL_HA_SERVER_ID="${MYSQL_HA_SERVER_ID:-}"

# 文件路径(测试 export 覆盖到临时目录)
MYSQL_HA_MYCNF="${MYSQL_HA_MYCNF:-/etc/mysql/mysql.conf.d/zz-mysql-ha.cnf}"
MYSQL_HA_ORCH_CONF="${MYSQL_HA_ORCH_CONF:-/etc/orchestrator.conf.json}"
MYSQL_HA_ORCH_UNIT="${MYSQL_HA_ORCH_UNIT:-/etc/systemd/system/orchestrator.service}"
MYSQL_HA_ORCH_CLIENT_CNF="${MYSQL_HA_ORCH_CLIENT_CNF:-/etc/mysql/orchestrator-client.cnf}"
MYSQL_HA_HAPROXY_CFG="${MYSQL_HA_HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
MYSQL_HA_MYSQLCHK_SCRIPT="${MYSQL_HA_MYSQLCHK_SCRIPT:-/usr/local/bin/mysqlchk}"
MYSQL_HA_MYSQLCHK_SOCKET="${MYSQL_HA_MYSQLCHK_SOCKET:-/etc/systemd/system/mysqlchk.socket}"
MYSQL_HA_MYSQLCHK_SERVICE="${MYSQL_HA_MYSQLCHK_SERVICE:-/etc/systemd/system/mysqlchk@.service}"
MYSQL_HA_MYSQLCHK_CNF="${MYSQL_HA_MYSQLCHK_CNF:-/etc/mysql/mysqlchk.cnf}"
MYSQL_HA_WATCHER_SCRIPT="${MYSQL_HA_WATCHER_SCRIPT:-/usr/local/bin/mysql-ha-watcher}"
MYSQL_HA_WATCHER_UNIT="${MYSQL_HA_WATCHER_UNIT:-/etc/systemd/system/mysql-ha-watcher.service}"
MYSQL_HA_WATCHER_CNF="${MYSQL_HA_WATCHER_CNF:-/etc/mysql/mysql-ha-watcher.cnf}"
MYSQL_HA_MYSQL_SOCKET="${MYSQL_HA_MYSQL_SOCKET:-/var/run/mysqld/mysqld.sock}"
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_mysql_ha.sh config`
Expected: `PASS: config`

- [ ] **Step 5: 提交**

```bash
git add tests/test_mysql_ha.sh lib/mysql-ha/config.sh
git commit -m "feat(mysql-ha): add config module and test scaffold"
```

---

## Task 2: 入口脚本 install-mysql-ha.sh + skeleton 测试

**Files:**
- Create: `install-mysql-ha.sh`
- Create: `lib/mysql-ha/common.sh`/`mysql.sh`/`orchestrator.sh`/`mysqlchk.sh`/`watcher.sh`/`haproxy.sh`/`main.sh`(占位)
- Modify: `tests/test_mysql_ha.sh`

- [ ] **Step 1: 写失败测试 — skeleton**

在 `run_config_tests` 之后插入:

```bash
run_skeleton_tests() {
  local entry="${ROOT_DIR}/install-mysql-ha.sh"
  assert_file_exists "$entry"
  [[ -x "$entry" ]] || fail "expected install-mysql-ha.sh to be executable"
  bash -n "$entry" || fail "install-mysql-ha.sh has syntax errors"
  assert_contains "$entry" "lib/mysql-ha/main.sh"
  assert_contains "$entry" "lib/common.sh"
  assert_not_contains "$entry" "lib/config.sh"

  local module
  while IFS= read -r module; do
    bash -n "$module" || fail "module has syntax errors: $module"
  done < <(find "${ROOT_DIR}/lib/mysql-ha" -name '*.sh' -type f | sort)

  load_mysql_ha
  local fn
  for fn in mysql_ha_parse_role mysql_ha_validate_node_ips write_my_cnf \
            write_orchestrator_config write_mysqlchk_script write_watcher_script \
            write_haproxy_config mysql_ha_main; do
    assert_function_exists "$fn"
  done
}
```

`main()` 加 `skeleton) run_skeleton_tests ;;`,`all)` 改为 `all) run_skeleton_tests; run_config_tests ;;`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_mysql_ha.sh skeleton`
Expected: FAIL(`install-mysql-ha.sh` 不存在)

- [ ] **Step 3: 实现 install-mysql-ha.sh + 占位模块**

创建 `install-mysql-ha.sh`:

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

  if [[ -f "${module_root}/lib/mysql-ha/config.sh" ]]; then
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
  lib/mysql-ha/config.sh \
  lib/mysql-ha/common.sh \
  lib/mysql-ha/mysql.sh \
  lib/mysql-ha/orchestrator.sh \
  lib/mysql-ha/mysqlchk.sh \
  lib/mysql-ha/watcher.sh \
  lib/mysql-ha/haproxy.sh \
  lib/mysql-ha/main.sh

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  mysql_ha_main "$@"
fi
```

创建占位模块(每个先放最小内容,使 source 不报错):

`lib/mysql-ha/common.sh`:
```bash
#!/usr/bin/env bash
# lib/mysql-ha/common.sh — MySQL-HA 专用公共函数(占位,后续任务填充)
mysql_ha_parse_role() { return 0; }
mysql_ha_validate_node_ips() { return 0; }
```

`lib/mysql-ha/mysql.sh`:
```bash
#!/usr/bin/env bash
write_my_cnf() { return 0; }
```

`lib/mysql-ha/orchestrator.sh`:
```bash
#!/usr/bin/env bash
write_orchestrator_config() { return 0; }
```

`lib/mysql-ha/mysqlchk.sh`:
```bash
#!/usr/bin/env bash
write_mysqlchk_script() { return 0; }
```

`lib/mysql-ha/watcher.sh`:
```bash
#!/usr/bin/env bash
write_watcher_script() { return 0; }
```

`lib/mysql-ha/haproxy.sh`:
```bash
#!/usr/bin/env bash
write_haproxy_config() { return 0; }
```

`lib/mysql-ha/main.sh`:
```bash
#!/usr/bin/env bash
mysql_ha_main() { return 0; }
```

设可执行:`chmod +x install-mysql-ha.sh`

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_mysql_ha.sh skeleton`
Expected: `PASS: skeleton`

- [ ] **Step 5: 提交**

```bash
git add install-mysql-ha.sh lib/mysql-ha/*.sh tests/test_mysql_ha.sh
git commit -m "feat(mysql-ha): add entrypoint and module skeletons"
```

---

## Task 3: common.sh — 角色解析、IP 校验、密码

**Files:**
- Modify: `lib/mysql-ha/common.sh`
- Modify: `tests/test_mysql_ha.sh`

- [ ] **Step 1: 写失败测试**

```bash
run_common_tests() {
  load_mysql_ha

  mysql_ha_parse_role "1"; assert_equals "primary" "${MYSQL_HA_ROLE}"
  mysql_ha_parse_role "primary"; assert_equals "primary" "${MYSQL_HA_ROLE}"
  mysql_ha_parse_role "2"; assert_equals "replica" "${MYSQL_HA_ROLE}"
  mysql_ha_parse_role "replica"; assert_equals "replica" "${MYSQL_HA_ROLE}"
  mysql_ha_parse_role "3"; assert_equals "arbiter" "${MYSQL_HA_ROLE}"
  mysql_ha_parse_role "arbiter"; assert_equals "arbiter" "${MYSQL_HA_ROLE}"
  if mysql_ha_parse_role "bogus" 2>/dev/null; then fail "expected bogus role to fail"; fi

  ( export MYSQL_HA_NODE1_IP="10.0.0.1" MYSQL_HA_NODE2_IP="10.0.0.2" MYSQL_HA_NODE3_IP="10.0.0.3"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/common.sh"
    mysql_ha_validate_node_ips || fail "expected valid IPs to pass" )
  ( export MYSQL_HA_NODE1_IP="10.0.0.1" MYSQL_HA_NODE2_IP="" MYSQL_HA_NODE3_IP="10.0.0.3"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/common.sh"
    if mysql_ha_validate_node_ips 2>/dev/null; then fail "expected empty IP to fail"; fi )
  ( export MYSQL_HA_NODE1_IP="not-an-ip" MYSQL_HA_NODE2_IP="10.0.0.2" MYSQL_HA_NODE3_IP="10.0.0.3"
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/common.sh"
    if mysql_ha_validate_node_ips 2>/dev/null; then fail "expected invalid IP to fail"; fi )

  local pw
  pw="$(mysql_ha_generate_password)"
  [[ ${#pw} -ge 16 ]] || fail "expected generated password length >= 16"
  # 密码仅字母数字(避免 JSON/SQL/cnf 转义)
  [[ "$pw" =~ ^[A-Za-z0-9]+$ ]] || fail "generated password must be alphanumeric only: $pw"
}
```

`main()` 加 `common) run_common_tests ;;`,`all)` 末尾追加 `; run_common_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_mysql_ha.sh common`
Expected: FAIL(占位 `mysql_ha_parse_role` 不设 `MYSQL_HA_ROLE`)

- [ ] **Step 3: 实现**

替换 `lib/mysql-ha/common.sh` 占位,加入:

```bash
mysql_ha_parse_role() {
  local input
  input="$(to_lower "$1")"
  case "$input" in
    1|primary|master|source) MYSQL_HA_ROLE="primary" ;;
    2|replica|standby|slave) MYSQL_HA_ROLE="replica" ;;
    3|arbiter|quorum|witness) MYSQL_HA_ROLE="arbiter" ;;
    *) echo "Unknown role: $1 (use 1/primary, 2/replica, 3/arbiter)" >&2; return 1 ;;
  esac
}

mysql_ha_validate_node_ips() {
  local ip
  for ip in "${MYSQL_HA_NODE1_IP}" "${MYSQL_HA_NODE2_IP}" "${MYSQL_HA_NODE3_IP}"; do
    if [[ -z "$ip" ]]; then
      echo "All three node IPs must be set (MYSQL_HA_NODE1_IP/2/3)." >&2
      return 1
    fi
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Invalid IP address: $ip" >&2
      return 1
    fi
  done
}

# 仅字母数字:避免 / + = 破坏 JSON(orchestrator.conf.json)/SQL/cnf 的转义
mysql_ha_generate_password() {
  openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-25
}

mysql_ha_require_passwords() {
  local var vars="MYSQL_HA_ORCH_PASSWORD MYSQL_HA_ORCH_HTTP_PASSWORD"
  if [[ "${MYSQL_HA_ROLE}" != "arbiter" ]]; then
    vars="$vars MYSQL_HA_ROOT_PASSWORD MYSQL_HA_REPL_PASSWORD MYSQL_HA_MYSQLCHK_PASSWORD MYSQL_HA_WATCHER_PASSWORD MYSQL_HA_APP_PASSWORD"
  fi
  for var in $vars; do
    if [[ -z "${!var}" ]]; then
      echo "${var} must be set (identical across nodes as documented)." >&2
      return 1
    fi
  done
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_mysql_ha.sh common`
Expected: `PASS: common`

- [ ] **Step 5: 提交**

```bash
git add lib/mysql-ha/common.sh tests/test_mysql_ha.sh
git commit -m "feat(mysql-ha): role parsing, IP validation, password helpers"
```

---

## Task 4: common.sh — 预检函数(连通性/时间/raft quorum)

**Files:**
- Modify: `lib/mysql-ha/common.sh`
- Modify: `tests/test_mysql_ha.sh`

- [ ] **Step 1: 写失败测试**

```bash
run_precheck_tests() {
  load_mysql_ha
  assert_function_exists mysql_ha_check_connectivity
  assert_function_exists mysql_ha_check_time_sync
  assert_function_exists mysql_ha_preflight_connectivity
  assert_function_exists mysql_ha_wait_raft_quorum

  # raft quorum 等待:mock curl 返回 healthy 立即成功
  ( source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/common.sh"
    export MYSQL_HA_ORCH_HTTP_PASSWORD=x MYSQL_HA_ORCH_PORT=3000
    curl() { echo '{"Healthy":true}'; }
    mysql_ha_wait_raft_quorum || fail "expected raft quorum wait to succeed when healthy" )
}
```

`main()` 加 `precheck) run_precheck_tests ;;`,`all)` 追加 `; run_precheck_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_mysql_ha.sh precheck`
Expected: FAIL(`mysql_ha_check_connectivity` 等未定义)

- [ ] **Step 3: 实现**

向 `lib/mysql-ha/common.sh` 追加:

```bash
mysql_ha_check_connectivity() {
  local host="$1" port="$2"
  if command_exists nc; then
    nc -z -w 3 "$host" "$port" >/dev/null 2>&1
  else
    timeout 3 bash -c ">/dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

# 非阻塞:仅探测节点间关键端口并提示(部署顺序下后部署节点未启属正常)
mysql_ha_preflight_connectivity() {
  local node_ip unreachable=0
  for node_ip in "${MYSQL_HA_NODE1_IP}" "${MYSQL_HA_NODE2_IP}" "${MYSQL_HA_NODE3_IP}"; do
    if ! mysql_ha_check_connectivity "$node_ip" "${MYSQL_HA_ORCH_PORT}"; then
      echo "Note: orchestrator ${MYSQL_HA_ORCH_PORT} on ${node_ip} not reachable yet (node may not be started)." >&2
      unreachable=1
    fi
  done
  if [[ "$unreachable" -eq 1 ]]; then
    echo "If this persists after all nodes are deployed, open ${MYSQL_HA_ORCH_PORT}/${MYSQL_HA_ORCH_RAFT_PORT}/3306/9200 between nodes." >&2
  fi
  return 0
}

mysql_ha_check_time_sync() {
  if command_exists timedatectl; then
    if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q '^yes$'; then
      echo "Warning: system clock not NTP-synchronized; raft elections are time-sensitive." >&2
      echo "Consider: apt-get install -y chrony" >&2
    fi
  fi
}

# 阻塞等待本机 Orchestrator raft 健康(对标 PG 版 etcd quorum 握手)
# 注:/api/raft-health 返回结构以实现期实测为准(spec Open Item #2)
mysql_ha_wait_raft_quorum() {
  local attempt out
  for attempt in $(seq 1 30); do
    out="$(curl -fsS --netrc-file <(printf 'machine 127.0.0.1 login admin password %s\n' "${MYSQL_HA_ORCH_HTTP_PASSWORD}") \
            "http://127.0.0.1:${MYSQL_HA_ORCH_PORT}/api/raft-health" 2>/dev/null || true)"
    if printf '%s' "$out" | grep -qi 'healthy'; then
      return 0
    fi
    sleep 2
  done
  echo "Orchestrator raft not healthy. Ensure all three orchestrator nodes are up and ${MYSQL_HA_ORCH_PORT}/${MYSQL_HA_ORCH_RAFT_PORT} are reachable between nodes." >&2
  return 1
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_mysql_ha.sh precheck`
Expected: `PASS: precheck`

- [ ] **Step 5: 提交**

```bash
git add lib/mysql-ha/common.sh tests/test_mysql_ha.sh
git commit -m "feat(mysql-ha): preflight checks (connectivity/time/raft quorum)"
```

---

## Task 5: mysql.sh — write_my_cnf(核心纯函数,含半同步分支)

**Files:**
- Modify: `lib/mysql-ha/mysql.sh`
- Modify: `tests/test_mysql_ha.sh`

- [ ] **Step 1: 写失败测试**

```bash
run_mysql_cnf_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export MYSQL_HA_NODE_IP="10.0.0.1"
  export MYSQL_HA_DATADIR="${temp_root}/data"
  export MYSQL_HA_MYCNF="${temp_root}/zz-mysql-ha.cnf"
  export MYSQL_HA_SEMISYNC="off"
  load_mysql_ha

  # primary, 异步
  write_my_cnf "1" "primary"
  assert_file_exists "${MYSQL_HA_MYCNF}"
  assert_contains "${MYSQL_HA_MYCNF}" "server_id=1"
  assert_contains "${MYSQL_HA_MYCNF}" "gtid_mode=ON"
  assert_contains "${MYSQL_HA_MYCNF}" "enforce_gtid_consistency=ON"
  assert_contains "${MYSQL_HA_MYCNF}" "log_replica_updates=ON"
  assert_contains "${MYSQL_HA_MYCNF}" "super_read_only=ON"
  assert_contains "${MYSQL_HA_MYCNF}" "binlog_expire_logs_seconds=604800"
  assert_contains "${MYSQL_HA_MYCNF}" "datadir=${temp_root}/data"
  assert_contains "${MYSQL_HA_MYCNF}" "bind-address=10.0.0.1"
  assert_not_contains "${MYSQL_HA_MYCNF}" "rpl_semi_sync"
  assert_mode "${MYSQL_HA_MYCNF}" "644"

  # replica server_id=2
  write_my_cnf "2" "replica"
  assert_contains "${MYSQL_HA_MYCNF}" "server_id=2"

  # 半同步 on + primary
  ( export MYSQL_HA_SEMISYNC="on" MYSQL_HA_MYCNF="${temp_root}/semi-src.cnf" MYSQL_HA_NODE_IP=10.0.0.1
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/mysql.sh"
    write_my_cnf "1" "primary"
    assert_contains "${temp_root}/semi-src.cnf" "plugin_load_add=semisync_source.so"
    assert_contains "${temp_root}/semi-src.cnf" "rpl_semi_sync_source_enabled=1"
    assert_contains "${temp_root}/semi-src.cnf" "rpl_semi_sync_source_wait_for_replica_count=1" )

  # 半同步 on + replica
  ( export MYSQL_HA_SEMISYNC="on" MYSQL_HA_MYCNF="${temp_root}/semi-rep.cnf" MYSQL_HA_NODE_IP=10.0.0.2
    source "${ROOT_DIR}/lib/mysql-ha/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/mysql-ha/mysql.sh"
    write_my_cnf "2" "replica"
    assert_contains "${temp_root}/semi-rep.cnf" "plugin_load_add=semisync_replica.so"
    assert_contains "${temp_root}/semi-rep.cnf" "rpl_semi_sync_replica_enabled=1" )
}
```

`main()` 加 `mysqlcnf) run_mysql_cnf_tests ;;`,`all)` 追加 `; run_mysql_cnf_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_mysql_ha.sh mysqlcnf`
Expected: FAIL(占位 `write_my_cnf` 不写文件)

- [ ] **Step 3: 实现**

替换 `lib/mysql-ha/mysql.sh` 占位,加入:

```bash
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
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_mysql_ha.sh mysqlcnf`
Expected: `PASS: mysqlcnf`

- [ ] **Step 5: 提交**

```bash
git add lib/mysql-ha/mysql.sh tests/test_mysql_ha.sh
git commit -m "feat(mysql-ha): generate my.cnf with gtid/super_read_only/semisync branches"
```

---

## Task 6: mysql.sh — APT 源/装包/datadir 迁移/AppArmor/建账号/配复制

**Files:**
- Modify: `lib/mysql-ha/mysql.sh`
- Modify: `tests/test_mysql_ha.sh`(扩展 `run_mysql_cnf_tests` 末尾函数存在断言)

> 系统安装/操作函数,无法在 CI 真跑;测试只断言函数存在 + 语法。

- [ ] **Step 1: 写失败测试**

在 `run_mysql_cnf_tests` 主体(顶层,非子 shell)末尾追加:

```bash
  assert_function_exists add_mysql_repo
  assert_function_exists install_mysql
  assert_function_exists apply_apparmor_datadir
  assert_function_exists relocate_datadir
  assert_function_exists start_mysql
  assert_function_exists bootstrap_mysql_accounts
  assert_function_exists setup_replication
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_mysql_ha.sh mysqlcnf`
Expected: FAIL(`add_mysql_repo` 等未定义)

- [ ] **Step 3: 实现**

向 `lib/mysql-ha/mysql.sh` 追加:

```bash
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
  local root_cnf
  root_cnf="$(mktemp)"; chmod 600 "$root_cnf"
  cat >"$root_cnf" <<EOF
[client]
user=root
password=${MYSQL_HA_ROOT_PASSWORD}
socket=${MYSQL_HA_MYSQL_SOCKET}
EOF
  mysql --defaults-extra-file="$root_cnf"
  local rc=$?
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
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_mysql_ha.sh mysqlcnf && bash -n lib/mysql-ha/mysql.sh`
Expected: `PASS: mysqlcnf`,语法检查无输出

- [ ] **Step 5: 提交**

```bash
git add lib/mysql-ha/mysql.sh tests/test_mysql_ha.sh
git commit -m "feat(mysql-ha): apt repo, install, datadir relocate, accounts, replication"
```

---

## Task 7: orchestrator.sh — write_orchestrator_config(核心纯函数)

**Files:**
- Modify: `lib/mysql-ha/orchestrator.sh`
- Modify: `tests/test_mysql_ha.sh`

- [ ] **Step 1: 写失败测试**

```bash
run_orchestrator_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export MYSQL_HA_NODE1_IP="10.0.0.1" MYSQL_HA_NODE2_IP="10.0.0.2" MYSQL_HA_NODE3_IP="10.0.0.3"
  export MYSQL_HA_ORCH_CONF="${temp_root}/orchestrator.conf.json"
  export MYSQL_HA_ORCH_DATADIR="${temp_root}/orch"
  export MYSQL_HA_ORCH_PASSWORD="orchpw" MYSQL_HA_ORCH_HTTP_PASSWORD="httppw"
  load_mysql_ha

  write_orchestrator_config "10.0.0.1"
  assert_file_exists "${MYSQL_HA_ORCH_CONF}"
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"BackendDB\": \"sqlite\""
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"RaftEnabled\": true"
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"RaftBind\": \"10.0.0.1\""
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"ListenAddress\": \"10.0.0.1:3000\""
  assert_contains "${MYSQL_HA_ORCH_CONF}" "10.0.0.3"
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"AuthenticationMethod\": \"basic\""
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"HTTPAuthPassword\": \"httppw\""
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"ApplyMySQLPromotionAfterMasterFailover\": true"
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"FailMasterPromotionIfSQLThreadNotUpToDate\": true"
  assert_contains "${MYSQL_HA_ORCH_CONF}" "\"ReasonableReplicationLagSeconds\": 60"
  assert_mode "${MYSQL_HA_ORCH_CONF}" "600"
  # JSON 合法性(无 python3 则跳过)
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "${MYSQL_HA_ORCH_CONF}" >/dev/null || fail "orchestrator.conf.json is not valid JSON"
  fi

  assert_function_exists write_orchestrator_client_cnf
  assert_function_exists write_orchestrator_unit
  assert_function_exists install_orchestrator
  assert_function_exists start_orchestrator
  assert_function_exists orchestrator_discover
}
```

`main()` 加 `orchestrator) run_orchestrator_tests ;;`,`all)` 追加 `; run_orchestrator_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_mysql_ha.sh orchestrator`
Expected: FAIL(占位 `write_orchestrator_config` 不写文件)

- [ ] **Step 3: 实现**

替换 `lib/mysql-ha/orchestrator.sh` 占位,加入:

```bash
write_orchestrator_config() {
  local node_ip="$1"
  mkdir -p "$(dirname "${MYSQL_HA_ORCH_CONF}")"
  cat >"${MYSQL_HA_ORCH_CONF}" <<EOF
{
  "Debug": false,
  "ListenAddress": "${node_ip}:${MYSQL_HA_ORCH_PORT}",
  "MySQLTopologyUser": "orchestrator",
  "MySQLTopologyPassword": "${MYSQL_HA_ORCH_PASSWORD}",
  "MySQLConnectTimeoutSeconds": 1,
  "MySQLTopologyUseMutualTLS": false,
  "AuthenticationMethod": "basic",
  "HTTPAuthUser": "admin",
  "HTTPAuthPassword": "${MYSQL_HA_ORCH_HTTP_PASSWORD}",
  "BackendDB": "sqlite",
  "SQLite3DataFile": "${MYSQL_HA_ORCH_DATADIR}/orchestrator.sqlite3",
  "RaftEnabled": true,
  "RaftDataDir": "${MYSQL_HA_ORCH_DATADIR}",
  "RaftBind": "${node_ip}",
  "DefaultRaftPort": ${MYSQL_HA_ORCH_RAFT_PORT},
  "RaftNodes": ["${MYSQL_HA_NODE1_IP}", "${MYSQL_HA_NODE2_IP}", "${MYSQL_HA_NODE3_IP}"],
  "InstancePollSeconds": ${MYSQL_HA_INSTANCE_POLL_SECONDS},
  "RecoveryPeriodBlockSeconds": ${MYSQL_HA_RECOVERY_BLOCK_SECONDS},
  "RecoverMasterClusterFilters": ["*"],
  "ApplyMySQLPromotionAfterMasterFailover": true,
  "FailMasterPromotionIfSQLThreadNotUpToDate": true,
  "ReasonableReplicationLagSeconds": ${MYSQL_HA_PROMOTION_LAG_SECONDS},
  "PostFailoverProcesses": [
    "mysql --defaults-extra-file=${MYSQL_HA_ORCH_CLIENT_CNF} -h {failedHost} -P {failedPort} -e 'SET GLOBAL super_read_only=1' || true"
  ]
}
EOF
  chmod 600 "${MYSQL_HA_ORCH_CONF}"
}

# orchestrator 账号客户端凭据(供 PostFailover 钩子远程连旧主;不进 argv,无 TLS 取公钥)
write_orchestrator_client_cnf() {
  mkdir -p "$(dirname "${MYSQL_HA_ORCH_CLIENT_CNF}")"
  cat >"${MYSQL_HA_ORCH_CLIENT_CNF}" <<EOF
[client]
user=orchestrator
password=${MYSQL_HA_ORCH_PASSWORD}
get-server-public-key
EOF
  chmod 600 "${MYSQL_HA_ORCH_CLIENT_CNF}"
}

write_orchestrator_unit() {
  mkdir -p "$(dirname "${MYSQL_HA_ORCH_UNIT}")"
  cat >"${MYSQL_HA_ORCH_UNIT}" <<EOF
[Unit]
Description=orchestrator MySQL HA
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/orchestrator/orchestrator --config ${MYSQL_HA_ORCH_CONF} http
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

install_orchestrator() {
  print_step "Installing Orchestrator"
  if command_exists orchestrator || [[ -x /usr/local/orchestrator/orchestrator ]]; then
    echo "orchestrator already installed."
  else
    export DEBIAN_FRONTEND=noninteractive
    # 版本锁定 + 资产文件名形态实现期核对(spec Open Item #1)
    local ver="v3.2.6" arch tmp
    arch="$(dpkg --print-architecture)"
    tmp="$(mktemp -d)"
    if curl -fsSL "https://github.com/openark/orchestrator/releases/download/${ver}/orchestrator_${ver#v}_${arch}.deb" -o "${tmp}/orchestrator.deb" \
       && apt-get install -y "${tmp}/orchestrator.deb"; then
      echo "orchestrator installed from .deb (${ver})."
    else
      echo "deb unavailable; installing official binary ${ver}." >&2
      curl -fsSL "https://github.com/openark/orchestrator/releases/download/${ver}/orchestrator-${ver#v}-linux-${arch}.tar.gz" -o "${tmp}/orch.tar.gz"
      mkdir -p /usr/local/orchestrator
      tar -xzf "${tmp}/orch.tar.gz" -C /usr/local/orchestrator
      write_orchestrator_unit
    fi
    rm -rf "${tmp}"
  fi
  mkdir -p "${MYSQL_HA_ORCH_DATADIR}"
}

start_orchestrator() {
  systemctl daemon-reload
  systemctl enable orchestrator
  systemctl restart orchestrator
}

# raft 模式 discover/forget 等写命令需经 raft leader;client 默认走 API leader
# 具体调用形态(orchestrator-client 的 API/auth 传入)实现期核对(spec Open Item #1)
orchestrator_discover() {
  print_step "Discovering cluster topology via orchestrator"
  ORCHESTRATOR_API="http://127.0.0.1:${MYSQL_HA_ORCH_PORT}/api" \
    orchestrator-client -c discover -i "${MYSQL_HA_NODE1_IP}:${MYSQL_HA_MYSQL_PORT}" || true
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_mysql_ha.sh orchestrator`
Expected: `PASS: orchestrator`

- [ ] **Step 5: 提交**

```bash
git add lib/mysql-ha/orchestrator.sh tests/test_mysql_ha.sh
git commit -m "feat(mysql-ha): orchestrator config (sqlite+raft+basic auth+failover) and install"
```

---

## Task 8: mysqlchk.sh — 健康检查脚本(完整 HTTP)+ socket/service unit + cnf

**Files:**
- Modify: `lib/mysql-ha/mysqlchk.sh`
- Modify: `tests/test_mysql_ha.sh`

- [ ] **Step 1: 写失败测试**

```bash
run_mysqlchk_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export MYSQL_HA_NODE_IP="10.0.0.1"
  export MYSQL_HA_MYSQLCHK_SCRIPT="${temp_root}/mysqlchk"
  export MYSQL_HA_MYSQLCHK_SOCKET="${temp_root}/mysqlchk.socket"
  export MYSQL_HA_MYSQLCHK_SERVICE="${temp_root}/mysqlchk@.service"
  export MYSQL_HA_MYSQLCHK_CNF="${temp_root}/mysqlchk.cnf"
  export MYSQL_HA_MYSQLCHK_PASSWORD="chkpw"
  load_mysql_ha

  write_mysqlchk_script
  assert_file_exists "${MYSQL_HA_MYSQLCHK_SCRIPT}"
  assert_contains "${MYSQL_HA_MYSQLCHK_SCRIPT}" "@@global.read_only"
  assert_contains "${MYSQL_HA_MYSQLCHK_SCRIPT}" "HTTP/1.1 200 OK"
  assert_contains "${MYSQL_HA_MYSQLCHK_SCRIPT}" "HTTP/1.1 503 Service Unavailable"
  assert_contains "${MYSQL_HA_MYSQLCHK_SCRIPT}" "Content-Length"
  # 必须用 printf 输出 CRLF,不用 echo
  assert_contains "${MYSQL_HA_MYSQLCHK_SCRIPT}" 'printf'
  grep -q $'\\\\r\\\\n' "${MYSQL_HA_MYSQLCHK_SCRIPT}" || fail "mysqlchk must emit CRLF (\\r\\n)"

  write_mysqlchk_cnf
  assert_contains "${MYSQL_HA_MYSQLCHK_CNF}" "user=mysqlchk"
  assert_contains "${MYSQL_HA_MYSQLCHK_CNF}" "password=chkpw"
  assert_mode "${MYSQL_HA_MYSQLCHK_CNF}" "600"

  write_mysqlchk_socket_unit
  assert_contains "${MYSQL_HA_MYSQLCHK_SOCKET}" "ListenStream=10.0.0.1:9200"
  assert_contains "${MYSQL_HA_MYSQLCHK_SOCKET}" "Accept=yes"

  write_mysqlchk_service_unit
  assert_contains "${MYSQL_HA_MYSQLCHK_SERVICE}" "StandardInput=socket"
  assert_contains "${MYSQL_HA_MYSQLCHK_SERVICE}" "StandardOutput=socket"
  assert_contains "${MYSQL_HA_MYSQLCHK_SERVICE}" "ExecStart=${temp_root}/mysqlchk"

  assert_function_exists setup_mysqlchk
  assert_function_exists start_mysqlchk
}
```

`main()` 加 `mysqlchk) run_mysqlchk_tests ;;`,`all)` 追加 `; run_mysqlchk_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_mysql_ha.sh mysqlchk`
Expected: FAIL(占位 `write_mysqlchk_script` 不写文件)

- [ ] **Step 3: 实现**

替换 `lib/mysql-ha/mysqlchk.sh` 占位,加入:

```bash
write_mysqlchk_script() {
  mkdir -p "$(dirname "${MYSQL_HA_MYSQLCHK_SCRIPT}")"
  # 首段含可变路径(展开);第二段固定逻辑(单引号 heredoc 不展开)
  cat >"${MYSQL_HA_MYSQLCHK_SCRIPT}" <<EOF
#!/usr/bin/env bash
# mysqlchk:当前可写主库(read_only=0)返回 200,否则 503。供 HAProxy option httpchk 探测。
DEFAULTS_FILE="${MYSQL_HA_MYSQLCHK_CNF}"
EOF
  cat >>"${MYSQL_HA_MYSQLCHK_SCRIPT}" <<'EOF'
RO="$(mysql --defaults-extra-file="$DEFAULTS_FILE" -N -B -e 'SELECT @@global.read_only' 2>/dev/null)"
if [[ "$RO" == "0" ]]; then
  BODY="MySQL writable primary"
  STATUS="HTTP/1.1 200 OK"
else
  BODY="MySQL not writable"
  STATUS="HTTP/1.1 503 Service Unavailable"
fi
printf '%s\r\n' "$STATUS"
printf 'Content-Type: text/plain\r\n'
printf 'Connection: close\r\n'
printf 'Content-Length: %s\r\n' "${#BODY}"
printf '\r\n'
printf '%s' "$BODY"
EOF
  chmod 755 "${MYSQL_HA_MYSQLCHK_SCRIPT}"
}

write_mysqlchk_cnf() {
  mkdir -p "$(dirname "${MYSQL_HA_MYSQLCHK_CNF}")"
  cat >"${MYSQL_HA_MYSQLCHK_CNF}" <<EOF
[client]
user=mysqlchk
password=${MYSQL_HA_MYSQLCHK_PASSWORD}
socket=${MYSQL_HA_MYSQL_SOCKET}
EOF
  chmod 600 "${MYSQL_HA_MYSQLCHK_CNF}"
  chown "${MYSQL_HA_SERVICE_USER}:${MYSQL_HA_SERVICE_USER}" "${MYSQL_HA_MYSQLCHK_CNF}" 2>/dev/null || true
}

write_mysqlchk_socket_unit() {
  mkdir -p "$(dirname "${MYSQL_HA_MYSQLCHK_SOCKET}")"
  cat >"${MYSQL_HA_MYSQLCHK_SOCKET}" <<EOF
[Unit]
Description=mysqlchk health check socket

[Socket]
ListenStream=${MYSQL_HA_NODE_IP}:${MYSQL_HA_MYSQLCHK_PORT}
Accept=yes

[Install]
WantedBy=sockets.target
EOF
}

write_mysqlchk_service_unit() {
  mkdir -p "$(dirname "${MYSQL_HA_MYSQLCHK_SERVICE}")"
  cat >"${MYSQL_HA_MYSQLCHK_SERVICE}" <<EOF
[Unit]
Description=mysqlchk health check responder

[Service]
ExecStart=${MYSQL_HA_MYSQLCHK_SCRIPT}
StandardInput=socket
StandardOutput=socket
User=${MYSQL_HA_SERVICE_USER}
EOF
}

setup_mysqlchk() {
  write_mysqlchk_script
  write_mysqlchk_cnf
  write_mysqlchk_socket_unit
  write_mysqlchk_service_unit
}

start_mysqlchk() {
  systemctl daemon-reload
  systemctl enable --now mysqlchk.socket
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_mysql_ha.sh mysqlchk`
Expected: `PASS: mysqlchk`

- [ ] **Step 5: 提交**

```bash
git add lib/mysql-ha/mysqlchk.sh tests/test_mysql_ha.sh
git commit -m "feat(mysql-ha): mysqlchk full-HTTP responder + socket activation + creds"
```

---

## Task 9: watcher.sh — 自愈 + 自我隔离 watcher

**Files:**
- Modify: `lib/mysql-ha/watcher.sh`
- Modify: `tests/test_mysql_ha.sh`

- [ ] **Step 1: 写失败测试**

```bash
run_watcher_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export MYSQL_HA_NODE_IP="10.0.0.1" MYSQL_HA_CLUSTER_NAME="mysql-ha"
  export MYSQL_HA_WATCHER_SCRIPT="${temp_root}/mysql-ha-watcher"
  export MYSQL_HA_WATCHER_UNIT="${temp_root}/mysql-ha-watcher.service"
  export MYSQL_HA_WATCHER_CNF="${temp_root}/watcher.cnf"
  export MYSQL_HA_WATCHER_PASSWORD="watchpw" MYSQL_HA_ORCH_HTTP_PASSWORD="httppw"
  load_mysql_ha

  write_watcher_script
  assert_file_exists "${MYSQL_HA_WATCHER_SCRIPT}"
  # 三分支:失多数票自我隔离 / 本机是主→可写 / 别人是主→只读
  assert_contains "${MYSQL_HA_WATCHER_SCRIPT}" "super_read_only=ON"
  assert_contains "${MYSQL_HA_WATCHER_SCRIPT}" "read_only=OFF"
  assert_contains "${MYSQL_HA_WATCHER_SCRIPT}" "raft-health"
  assert_contains "${MYSQL_HA_WATCHER_SCRIPT}" "api/master"

  write_watcher_cnf
  assert_contains "${MYSQL_HA_WATCHER_CNF}" "user=watcher"
  assert_contains "${MYSQL_HA_WATCHER_CNF}" "password=watchpw"
  assert_contains "${MYSQL_HA_WATCHER_CNF}" "http_password = httppw"
  assert_mode "${MYSQL_HA_WATCHER_CNF}" "600"

  write_watcher_unit
  assert_contains "${MYSQL_HA_WATCHER_UNIT}" "Restart=always"
  assert_contains "${MYSQL_HA_WATCHER_UNIT}" "ExecStart=${temp_root}/mysql-ha-watcher"

  assert_function_exists setup_watcher
  assert_function_exists start_watcher
}
```

`main()` 加 `watcher) run_watcher_tests ;;`,`all)` 追加 `; run_watcher_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_mysql_ha.sh watcher`
Expected: FAIL(占位 `write_watcher_script` 不写文件)

- [ ] **Step 3: 实现**

替换 `lib/mysql-ha/watcher.sh` 占位,加入:

```bash
write_watcher_script() {
  mkdir -p "$(dirname "${MYSQL_HA_WATCHER_SCRIPT}")"
  cat >"${MYSQL_HA_WATCHER_SCRIPT}" <<EOF
#!/usr/bin/env bash
# mysql-ha-watcher:补足 Orchestrator 稳态可写性 + 失 raft 多数票自我隔离。
# 凭据从 600 的 cnf 读取(脚本不含密码)。
CNF="${MYSQL_HA_WATCHER_CNF}"
ORCH="http://127.0.0.1:${MYSQL_HA_ORCH_PORT}"
CLUSTER="${MYSQL_HA_CLUSTER_NAME}"
SELF_IP="${MYSQL_HA_NODE_IP}"
INTERVAL="${MYSQL_HA_WATCHER_INTERVAL}"
EOF
  cat >>"${MYSQL_HA_WATCHER_SCRIPT}" <<'EOF'

http_pass="$(awk -F'=' '/^\[orchestrator\]/{f=1} f&&/http_password/{gsub(/[ \t]/,"",$2);print $2;exit}' "$CNF")"
ORCH_USER="admin"

orch_get() { # $1=api path
  curl -fsS --netrc-file <(printf 'machine 127.0.0.1 login %s password %s\n' "$ORCH_USER" "$http_pass") \
    "${ORCH}/$1" 2>/dev/null
}
make_writable() { mysql --defaults-extra-file="$CNF" -e "SET GLOBAL read_only=OFF" 2>/dev/null || true; }
self_fence()   { mysql --defaults-extra-file="$CNF" -e "SET GLOBAL super_read_only=ON" 2>/dev/null || true; }

while true; do
  raft="$(orch_get 'api/raft-health')"
  if [[ -z "$raft" ]] || ! printf '%s' "$raft" | grep -qi 'healthy'; then
    # 本机失去 raft 多数视角(分区/orchestrator 不可达)→ 自我隔离
    self_fence
    sleep "$INTERVAL"; continue
  fi
  master_json="$(orch_get "api/master/${CLUSTER}")"
  master_host="$(printf '%s' "$master_json" | grep -oE '"Hostname"[^,]*' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"
  if [[ "$master_host" == "$SELF_IP" ]]; then
    make_writable      # 本机是当前主 → 收敛为可写
  else
    self_fence         # 别人是主/未知 → 保守置只读
  fi
  sleep "$INTERVAL"
done
EOF
  chmod 755 "${MYSQL_HA_WATCHER_SCRIPT}"
}

write_watcher_cnf() {
  mkdir -p "$(dirname "${MYSQL_HA_WATCHER_CNF}")"
  cat >"${MYSQL_HA_WATCHER_CNF}" <<EOF
[client]
user=watcher
password=${MYSQL_HA_WATCHER_PASSWORD}
socket=${MYSQL_HA_MYSQL_SOCKET}

[orchestrator]
http_user = admin
http_password = ${MYSQL_HA_ORCH_HTTP_PASSWORD}
EOF
  chmod 600 "${MYSQL_HA_WATCHER_CNF}"
  chown "${MYSQL_HA_SERVICE_USER}:${MYSQL_HA_SERVICE_USER}" "${MYSQL_HA_WATCHER_CNF}" 2>/dev/null || true
}

write_watcher_unit() {
  mkdir -p "$(dirname "${MYSQL_HA_WATCHER_UNIT}")"
  cat >"${MYSQL_HA_WATCHER_UNIT}" <<EOF
[Unit]
Description=mysql-ha-watcher (writability convergence + self-fence)
After=network-online.target mysql.service orchestrator.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MYSQL_HA_WATCHER_SCRIPT}
Restart=always
RestartSec=2
User=${MYSQL_HA_SERVICE_USER}

[Install]
WantedBy=multi-user.target
EOF
}

setup_watcher() {
  write_watcher_script
  write_watcher_cnf
  write_watcher_unit
}

start_watcher() {
  systemctl daemon-reload
  systemctl enable --now mysql-ha-watcher.service
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_mysql_ha.sh watcher`
Expected: `PASS: watcher`

- [ ] **Step 5: 提交**

```bash
git add lib/mysql-ha/watcher.sh tests/test_mysql_ha.sh
git commit -m "feat(mysql-ha): writability-convergence + self-fence watcher"
```

---

## Task 10: haproxy.sh — write_haproxy_config + install/start

**Files:**
- Modify: `lib/mysql-ha/haproxy.sh`
- Modify: `tests/test_mysql_ha.sh`

- [ ] **Step 1: 写失败测试**

```bash
run_haproxy_tests() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN

  export MYSQL_HA_NODE1_IP="10.0.0.1" MYSQL_HA_NODE2_IP="10.0.0.2"
  export MYSQL_HA_HAPROXY_CFG="${temp_root}/haproxy.cfg"
  export MYSQL_HA_STATS_PASSWORD="statspw"
  load_mysql_ha

  write_haproxy_config
  assert_file_exists "${MYSQL_HA_HAPROXY_CFG}"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "bind *:6446"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "mode tcp"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "option httpchk"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "http-check send meth GET uri /"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "http-check expect status 200"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "on-marked-down shutdown-sessions"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "server node1 10.0.0.1:3306 check port 9200"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "server node2 10.0.0.2:3306 check port 9200"
  assert_contains "${MYSQL_HA_HAPROXY_CFG}" "stats auth admin:statspw"
  assert_mode "${MYSQL_HA_HAPROXY_CFG}" "600"

  assert_function_exists install_haproxy
  assert_function_exists start_haproxy
}
```

`main()` 加 `haproxy) run_haproxy_tests ;;`,`all)` 追加 `; run_haproxy_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_mysql_ha.sh haproxy`
Expected: FAIL(占位 `write_haproxy_config` 不写文件)

- [ ] **Step 3: 实现**

替换 `lib/mysql-ha/haproxy.sh` 占位,加入:

```bash
write_haproxy_config() {
  mkdir -p "$(dirname "${MYSQL_HA_HAPROXY_CFG}")"
  cat >"${MYSQL_HA_HAPROXY_CFG}" <<EOF
global
    maxconn 2000
    log /dev/log local0

defaults
    log global
    mode tcp
    retries 2
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 5s

frontend mysql_write
    bind *:${MYSQL_HA_PROXY_PORT}
    mode tcp
    default_backend mysql_primary

backend mysql_primary
    mode tcp
    option httpchk
    http-check send meth GET uri /
    http-check expect status 200
    default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions
    server node1 ${MYSQL_HA_NODE1_IP}:${MYSQL_HA_MYSQL_PORT} check port ${MYSQL_HA_MYSQLCHK_PORT}
    server node2 ${MYSQL_HA_NODE2_IP}:${MYSQL_HA_MYSQL_PORT} check port ${MYSQL_HA_MYSQLCHK_PORT}

listen stats
    bind *:${MYSQL_HA_PROXY_STATS_PORT}
    mode http
    stats enable
    stats uri /
    stats auth admin:${MYSQL_HA_STATS_PASSWORD}
EOF
  chmod 600 "${MYSQL_HA_HAPROXY_CFG}"
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

Run: `bash tests/test_mysql_ha.sh haproxy`
Expected: `PASS: haproxy`

- [ ] **Step 5: 提交**

```bash
git add lib/mysql-ha/haproxy.sh tests/test_mysql_ha.sh
git commit -m "feat(mysql-ha): generate haproxy config (tcp + httpchk mysqlchk)"
```

---

## Task 11: main.sh — collect_config + 编排 + summary

**Files:**
- Modify: `lib/mysql-ha/common.sh`(加 `mysql_ha_collect_config`)
- Modify: `lib/mysql-ha/main.sh`
- Modify: `tests/test_mysql_ha.sh`

- [ ] **Step 1: 写失败测试**

```bash
run_orchestration_tests() {
  local temp_root action_log
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN
  action_log="${temp_root}/actions.log"

  export MYSQL_HA_NODE1_IP="10.0.0.1" MYSQL_HA_NODE2_IP="10.0.0.2" MYSQL_HA_NODE3_IP="10.0.0.3"
  export MYSQL_HA_ORCH_PASSWORD=x MYSQL_HA_ORCH_HTTP_PASSWORD=x
  export MYSQL_HA_ROOT_PASSWORD=x MYSQL_HA_REPL_PASSWORD=x MYSQL_HA_MYSQLCHK_PASSWORD=x
  export MYSQL_HA_WATCHER_PASSWORD=x MYSQL_HA_APP_PASSWORD=x MYSQL_HA_STATS_PASSWORD=x
  export MYSQL_HA_APP_ALLOWED_CIDR="10.0.0.0/24"
  load_mysql_ha

  # mock 所有副作用函数
  require_root() { :; }
  detect_os() { :; }
  mysql_ha_check_time_sync() { :; }
  mysql_ha_preflight_connectivity() { :; }
  mysql_ha_wait_raft_quorum() { :; }
  install_mysql() { echo install_mysql >>"$action_log"; }
  relocate_datadir() { echo relocate_datadir >>"$action_log"; }
  write_my_cnf() { echo "write_my_cnf $1 $2" >>"$action_log"; }
  start_mysql() { echo start_mysql >>"$action_log"; }
  bootstrap_mysql_accounts() { echo bootstrap_mysql_accounts >>"$action_log"; }
  setup_replication() { echo setup_replication >>"$action_log"; }
  install_orchestrator() { echo install_orchestrator >>"$action_log"; }
  write_orchestrator_client_cnf() { echo write_orchestrator_client_cnf >>"$action_log"; }
  write_orchestrator_config() { echo write_orchestrator_config >>"$action_log"; }
  start_orchestrator() { echo start_orchestrator >>"$action_log"; }
  orchestrator_discover() { echo orchestrator_discover >>"$action_log"; }
  setup_mysqlchk() { echo setup_mysqlchk >>"$action_log"; }
  start_mysqlchk() { echo start_mysqlchk >>"$action_log"; }
  install_haproxy() { echo install_haproxy >>"$action_log"; }
  start_haproxy() { echo start_haproxy >>"$action_log"; }
  setup_watcher() { echo setup_watcher >>"$action_log"; }
  start_watcher() { echo start_watcher >>"$action_log"; }
  mysql_ha_show_summary() { echo summary >>"$action_log"; }

  # arbiter:仅 orchestrator
  : >"$action_log"
  mysql_ha_collect_config() { MYSQL_HA_ROLE=arbiter; MYSQL_HA_NODE_NAME=node3; MYSQL_HA_NODE_IP=10.0.0.3; MYSQL_HA_SERVER_ID=0; }
  mysql_ha_main
  assert_contains "$action_log" "install_orchestrator"
  assert_not_contains "$action_log" "install_mysql"
  assert_not_contains "$action_log" "install_haproxy"
  assert_not_contains "$action_log" "setup_watcher"

  # primary:mysql + 建账号 + orchestrator + discover + mysqlchk + haproxy + watcher;不配复制
  : >"$action_log"
  mysql_ha_collect_config() { MYSQL_HA_ROLE=primary; MYSQL_HA_NODE_NAME=node1; MYSQL_HA_NODE_IP=10.0.0.1; MYSQL_HA_SERVER_ID=1; }
  mysql_ha_main
  assert_contains "$action_log" "install_mysql"
  assert_contains "$action_log" "write_my_cnf 1 primary"
  assert_contains "$action_log" "bootstrap_mysql_accounts"
  assert_contains "$action_log" "orchestrator_discover"
  assert_contains "$action_log" "setup_watcher"
  assert_not_contains "$action_log" "setup_replication"

  # replica:mysql + 配复制 + orchestrator + mysqlchk + haproxy + watcher;不建账号/不 discover
  : >"$action_log"
  mysql_ha_collect_config() { MYSQL_HA_ROLE=replica; MYSQL_HA_NODE_NAME=node2; MYSQL_HA_NODE_IP=10.0.0.2; MYSQL_HA_SERVER_ID=2; }
  mysql_ha_main
  assert_contains "$action_log" "write_my_cnf 2 replica"
  assert_contains "$action_log" "setup_replication"
  assert_contains "$action_log" "setup_watcher"
  assert_not_contains "$action_log" "bootstrap_mysql_accounts"
  assert_not_contains "$action_log" "orchestrator_discover"
}
```

`main()` 加 `orchestration) run_orchestration_tests ;;`,`all)` 追加 `; run_orchestration_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_mysql_ha.sh orchestration`
Expected: FAIL(`mysql_ha_collect_config`/真实 `mysql_ha_main` 未实现)

- [ ] **Step 3: 实现**

向 `lib/mysql-ha/common.sh` 追加:

```bash
mysql_ha_collect_config() {
  cat >&2 <<'GUIDE'

=== MySQL 高可用部署 ===
本脚本需在【每台机器各运行一次】,每次选择"本机"的角色(这是正常流程,不是重复)。
推荐顺序: (1) 先 arbiter(仲裁) -> (2) 再 primary(主库) -> (3) 最后 replica(从库)
三个节点 IP 与各项密码,必须在所有数据节点上填写【完全一致】。

GUIDE
  local role_input
  role_input="$(prompt_with_default "Node role (1=primary, 2=replica, 3=arbiter)" "1")"
  mysql_ha_parse_role "$role_input"

  MYSQL_HA_NODE1_IP="$(prompt_with_default "Node1 (primary) IP" "${MYSQL_HA_NODE1_IP}")"
  MYSQL_HA_NODE2_IP="$(prompt_with_default "Node2 (replica) IP" "${MYSQL_HA_NODE2_IP}")"
  MYSQL_HA_NODE3_IP="$(prompt_with_default "Node3 (arbiter) IP" "${MYSQL_HA_NODE3_IP}")"

  case "${MYSQL_HA_ROLE}" in
    primary) MYSQL_HA_NODE_NAME="node1"; MYSQL_HA_NODE_IP="${MYSQL_HA_NODE1_IP}"; MYSQL_HA_SERVER_ID=1 ;;
    replica) MYSQL_HA_NODE_NAME="node2"; MYSQL_HA_NODE_IP="${MYSQL_HA_NODE2_IP}"; MYSQL_HA_SERVER_ID=2 ;;
    arbiter) MYSQL_HA_NODE_NAME="node3"; MYSQL_HA_NODE_IP="${MYSQL_HA_NODE3_IP}"; MYSQL_HA_SERVER_ID=0 ;;
  esac

  # orchestrator topology + Web 认证密码(三台一致;arbiter 也需连 MySQL 监控 + 提供 Web auth)
  MYSQL_HA_ORCH_PASSWORD="$(prompt_with_default "orchestrator topology password (identical on ALL nodes)" "${MYSQL_HA_ORCH_PASSWORD}")"
  MYSQL_HA_ORCH_HTTP_PASSWORD="$(prompt_with_default "orchestrator web/API password (identical on ALL nodes)" "${MYSQL_HA_ORCH_HTTP_PASSWORD:-$(mysql_ha_generate_password)}")"

  if [[ "${MYSQL_HA_ROLE}" != "arbiter" ]]; then
    MYSQL_HA_APP_ALLOWED_CIDR="$(prompt_with_default "Application allowed CIDR (e.g. 10.0.0.0/24)" "${MYSQL_HA_APP_ALLOWED_CIDR}")"
    MYSQL_HA_ROOT_PASSWORD="$(prompt_with_default "MySQL root password (identical on data nodes)" "${MYSQL_HA_ROOT_PASSWORD}")"
    MYSQL_HA_REPL_PASSWORD="$(prompt_with_default "replication password (identical on data nodes)" "${MYSQL_HA_REPL_PASSWORD}")"
    MYSQL_HA_MYSQLCHK_PASSWORD="$(prompt_with_default "mysqlchk password (identical on data nodes)" "${MYSQL_HA_MYSQLCHK_PASSWORD:-$(mysql_ha_generate_password)}")"
    MYSQL_HA_WATCHER_PASSWORD="$(prompt_with_default "watcher password (identical on data nodes)" "${MYSQL_HA_WATCHER_PASSWORD:-$(mysql_ha_generate_password)}")"
    MYSQL_HA_APP_PASSWORD="$(prompt_with_default "application '${MYSQL_HA_APP_USER}' password (identical on data nodes)" "${MYSQL_HA_APP_PASSWORD}")"
    MYSQL_HA_STATS_PASSWORD="$(prompt_with_default "HAProxy stats password" "${MYSQL_HA_STATS_PASSWORD:-$(mysql_ha_generate_password)}")"
  fi
}
```

替换 `lib/mysql-ha/main.sh` 占位:

```bash
#!/usr/bin/env bash
# lib/mysql-ha/main.sh — MySQL-HA 主编排入口

mysql_ha_show_summary() {
  print_step "MySQL HA deployment summary"
  echo "Role: ${MYSQL_HA_ROLE} (${MYSQL_HA_NODE_NAME} @ ${MYSQL_HA_NODE_IP})"
  echo "Cluster: ${MYSQL_HA_CLUSTER_NAME} | orchestrator raft: ${MYSQL_HA_NODE1_IP},${MYSQL_HA_NODE2_IP},${MYSQL_HA_NODE3_IP}"
  echo "Orchestrator Web/API: http://${MYSQL_HA_NODE_IP}:${MYSQL_HA_ORCH_PORT} (basic auth, user 'admin')"
  if [[ "${MYSQL_HA_ROLE}" != "arbiter" ]]; then
    echo "App connects to HAProxy :${MYSQL_HA_PROXY_PORT} (read+write, always current primary)"
    echo "Configure your app with BOTH HAProxy addresses (${MYSQL_HA_NODE1_IP}:${MYSQL_HA_PROXY_PORT}, ${MYSQL_HA_NODE2_IP}:${MYSQL_HA_PROXY_PORT}) and connection-retry."
    echo "Writability is maintained by mysql-ha-watcher; a node loses raft majority -> self-fences (super_read_only=ON)."
    if [[ "$(to_lower "${MYSQL_HA_SEMISYNC}")" == "on" ]]; then
      echo "Semi-sync: ON (near-zero RPO)."
    else
      echo "Semi-sync: OFF (async, RPO>0). Set MYSQL_HA_SEMISYNC=on for payment/strong-consistency workloads."
    fi
    echo "After a failover, a returning old primary likely needs full rebuild (errant GTID); re-add via orchestrator/reinstall before serving traffic."
  fi
  echo "Passwords must be identical across data nodes (orchestrator passwords across all nodes). Store them securely."
}

mysql_ha_main() {
  require_root
  detect_os
  mysql_ha_collect_config
  mysql_ha_validate_node_ips
  mysql_ha_check_time_sync
  mysql_ha_require_passwords
  if [[ "${MYSQL_HA_ROLE}" != "arbiter" && -z "${MYSQL_HA_APP_ALLOWED_CIDR}" ]]; then
    echo "MYSQL_HA_APP_ALLOWED_CIDR must be set for data nodes (e.g. 10.0.0.0/24)." >&2
    return 1
  fi

  case "${MYSQL_HA_ROLE}" in
    arbiter)
      install_orchestrator
      write_orchestrator_client_cnf
      write_orchestrator_config "${MYSQL_HA_NODE_IP}"
      start_orchestrator
      ;;
    primary)
      install_mysql
      relocate_datadir
      write_my_cnf "1" "primary"
      start_mysql
      bootstrap_mysql_accounts
      install_orchestrator
      write_orchestrator_client_cnf
      write_orchestrator_config "${MYSQL_HA_NODE_IP}"
      start_orchestrator
      mysql_ha_wait_raft_quorum
      orchestrator_discover
      setup_mysqlchk
      start_mysqlchk
      install_haproxy
      start_haproxy
      setup_watcher
      start_watcher
      ;;
    replica)
      install_mysql
      relocate_datadir
      write_my_cnf "2" "replica"
      start_mysql
      setup_replication
      install_orchestrator
      write_orchestrator_client_cnf
      write_orchestrator_config "${MYSQL_HA_NODE_IP}"
      start_orchestrator
      setup_mysqlchk
      start_mysqlchk
      install_haproxy
      start_haproxy
      setup_watcher
      start_watcher
      ;;
  esac

  mysql_ha_show_summary
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_mysql_ha.sh orchestration`
Expected: `PASS: orchestration`

- [ ] **Step 5: 提交**

```bash
git add lib/mysql-ha/common.sh lib/mysql-ha/main.sh tests/test_mysql_ha.sh
git commit -m "feat(mysql-ha): config collection, role orchestration, summary"
```

---

## Task 12: README 文档更新

**Files:**
- Modify: `README.md`
- Modify: `tests/test_mysql_ha.sh`

- [ ] **Step 1: 写失败测试**

```bash
run_docs_tests() {
  local readme="${ROOT_DIR}/README.md"
  assert_contains "$readme" "install-mysql-ha.sh"
  assert_contains "$readme" "Orchestrator"
  assert_contains "$readme" "MYSQL_HA_NODE1_IP"
  assert_contains "$readme" "mysql-ha-watcher"
}
```

`main()` 加 `docs) run_docs_tests ;;`,`all)` 追加 `; run_docs_tests`。

- [ ] **Step 2: 运行测试确认失败**

Run: `bash tests/test_mysql_ha.sh docs`
Expected: FAIL(README 未含相关内容)

- [ ] **Step 3: 实现**

在 `README.md` 的"PostgreSQL 高可用"小节之后插入新小节(放在"快捷使用 psql"之前):

````markdown
## MySQL 高可用(Orchestrator,非 Docker)

在三台 Ubuntu 24.04 机器上部署 Oracle MySQL 8.4 + Orchestrator + HAProxy,实现两主机自动故障转移(第三台仅作 orchestrator raft 仲裁)。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-mysql-ha.sh)
```

**在每台机器各运行一次**,交互选择本机角色:

| 角色 | 说明 |
|------|------|
| 1) primary | MySQL 主节点(首次建库/账号,配置为复制源) |
| 2) replica | MySQL 从节点(GTID 自动复制) |
| 3) arbiter | 仅 Orchestrator raft 仲裁(不跑 MySQL) |

**推荐执行顺序**:arbiter → primary → replica。

**自愈与防脑裂**:每个数据节点跑 `mysql-ha-watcher`——本机被 Orchestrator 判定为当前主且 raft 健康时维持其可写;失去 raft 多数票(网络分区)时自我 `super_read_only=ON` 隔离。这补足了 Orchestrator 不维护稳态可写性的缺口(否则节点重启后会"无可写主")。⚠️ watcher 为用户态、有界窗口、依赖自身存活(`Restart=always`),非内核硬 STONITH;强一致场景建议 `MYSQL_HA_SEMISYNC=on`。

**应用连接**:连 HAProxy `6446`(读写都到当前主库)。为接入冗余,应用应配置**两台** HAProxy 地址(`node1:6446`、`node2:6446`)并具备连接失败重试能力。**分区期间**被隔离节点的 HAProxy 会因 mysqlchk 转 503 而 DOWN,正常重连客户端会切到另一地址。

**需放行端口**(脚本不改防火墙):
- 节点间互通:`3306`(复制/HAProxy/orchestrator 监控)、`9200`(mysqlchk 跨机检查)、`3000`(orchestrator API)、`10008`(raft)
- 应用接入:`6446`(HAProxy)
- 仅本机/运维:`7001`(HAProxy stats,不建议全网放行)

**密码**:`MYSQL_HA_ROOT_PASSWORD`/`MYSQL_HA_REPL_PASSWORD`/`MYSQL_HA_MYSQLCHK_PASSWORD`/`MYSQL_HA_WATCHER_PASSWORD`/`MYSQL_HA_APP_PASSWORD` **必须在两台数据节点保持一致**;`MYSQL_HA_ORCH_PASSWORD`/`MYSQL_HA_ORCH_HTTP_PASSWORD` 三台一致。账号仅在 primary 创建,经 GTID 复制到 replica。

**安全**:Orchestrator Web/API(3000)启用 basic auth + 绑业务网卡;账号最小权限;不启用 TLS,依赖网络隔离。

**故障恢复**:旧主 failover 回归大概率带 errant GTID,需经 Orchestrator 重新纳管或重装全量重建后再放行流量(异步复制特性;`MYSQL_HA_SEMISYNC=on` 可降低概率)。

**关键环境变量**:`MYSQL_HA_NODE1_IP`/`2`/`3`、`MYSQL_HA_VERSION`(默认 8.4)、`MYSQL_HA_CLUSTER_NAME`(默认 mysql-ha)、`MYSQL_HA_SEMISYNC`(默认 off;on 切半同步逼近零丢失)、`DATA_ROOT`(默认 /data)。

> 这是**非 Docker** 路径,与现有 Docker 版 MySQL(`deploy.sh` 菜单项 3)**并存但同机不可并跑**(均占 3306 / server_id 易撞)。
````

并在"数据目录"小节的目录树补一行 `├── mysql-ha/      # MySQL HA 数据与 orchestrator 状态`。

- [ ] **Step 4: 运行测试确认通过**

Run: `bash tests/test_mysql_ha.sh docs`
Expected: `PASS: docs`

- [ ] **Step 5: 提交**

```bash
git add README.md tests/test_mysql_ha.sh
git commit -m "docs: README 增加 MySQL + Orchestrator HA 说明"
```

---

## Task 13: 全套验证 + 现有测试保持绿色

**Files:** 无新增(仅验证)

- [ ] **Step 1: 运行 MySQL-HA 全套测试**

Run: `bash tests/test_mysql_ha.sh all`
Expected: `PASS: all`

- [ ] **Step 2: 全部脚本语法检查**

Run:
```bash
bash -n install-mysql-ha.sh
find lib/mysql-ha -name '*.sh' -print0 | xargs -0 -n1 bash -n
```
Expected: 无任何输出(全部通过)

- [ ] **Step 3: 现有测试保持绿色**

Run:
```bash
bash tests/test_deploy.sh all
bash tests/test_pg_ha.sh all
```
Expected: 两个都 `PASS: all`

- [ ] **Step 4: 确认现有入口不受影响**

Run: `bash -n deploy.sh && bash -n install-docker.sh && bash -n install-pg-ha.sh && bash -n install-pg-wrapper.sh`
Expected: 无输出

- [ ] **Step 5: 最终提交(如有未提交变更)**

```bash
git add -A
git commit -m "test(mysql-ha): full suite green; existing tests unaffected" || echo "nothing to commit"
```

---

## Self-Review(计划完成后自查)

**1. Spec 覆盖** — 逐节核对 spec → 任务:

| spec 要求 | 实现任务 |
|-----------|----------|
| config 默认值 + DATA_ROOT 自兜底 + 文件/权限路径 | Task 1 |
| 入口双模加载 + 不加载 lib/config.sh | Task 2 |
| 角色解析(primary/replica/arbiter)/IP 校验/密码(字母数字) | Task 3 |
| 预检(连通性/时间/raft quorum 阻塞握手) | Task 4 |
| my.cnf(server_id/gtid/log_replica_updates/super_read_only/binlog_expire/半同步分支) | Task 5 |
| APT 源(非交互 debconf)/装包/datadir 迁移+AppArmor/账号(GTID 复制语义)/复制(GET_SOURCE_PUBLIC_KEY) | Task 6 |
| orchestrator.conf.json(sqlite+raft+basic auth+落后阈值+PostFailover 钩子)+ JSON 合法 + client cnf | Task 7 |
| mysqlchk 完整 HTTP(CRLF/Content-Length/printf)+ socket 绑业务网卡 + cnf 600 | Task 8 |
| watcher 三分支(自我隔离/收敛可写/维持只读)+ 凭据不入命令行 + Restart=always | Task 9 |
| HAProxy(mode tcp + httpchk + on-marked-down + stats auth)+ 文件 600 | Task 10 |
| 角色编排(arbiter 仅 orchestrator;replica 不建账号/不 discover;watcher 仅数据节点)+ summary | Task 11 |
| README(三角色/端口分类/watcher/半同步/rejoin/并存同机不可并跑) | Task 12 |
| 独立 test_mysql_ha.sh + 现有测试绿 | Task 1-13 |

控制面认证:Orchestrator basic auth(Task 7)、HAProxy stats auth(Task 10)、文件 600 矩阵(Task 7/8/9/10 + assert_mode)。caching_sha2+无 TLS:`GET_SOURCE_PUBLIC_KEY`(Task 6)、`get-server-public-key`(Task 7 client cnf)。

**2. Placeholder 扫描** — 无 "TBD/TODO";系统函数(install_mysql/bootstrap_mysql_accounts/install_orchestrator 等)给完整实现;所有 write_* 给完整 heredoc。实现期需实测项(orchestrator 版本/API 路径、半同步 .so 名、AppArmor、debconf 键名)在代码注释里指向 spec Open Items,**非占位**。

**3. 类型/命名一致性** — 函数名跨任务一致:`write_my_cnf`/`bootstrap_mysql_accounts`/`setup_replication`/`write_orchestrator_config`/`write_orchestrator_client_cnf`/`orchestrator_discover`/`write_mysqlchk_script`/`setup_mysqlchk`/`write_watcher_script`/`setup_watcher`/`write_haproxy_config`/`mysql_ha_main`/`mysql_ha_collect_config`/`mysql_ha_show_summary`/`mysql_ha_wait_raft_quorum`/`mysql_ha_require_passwords`。全局变量名与 config.sh 一致;main 调用的函数均在 Task 6-10 定义(`setup_mysqlchk`/`setup_watcher` 等聚合函数在对应任务实现)。

**范围说明(对 spec 的有意收窄):** 本计划聚焦"首次三角色部署 + 配置生成正确性"。spec 中的 **reinstall 两类路径(MySQL 数据层全量重建 vs Orchestrator/raft 重置)、`confirm_overwrite` 幂等分支、CLONE/重建细节**涉及运行期状态,无法用配置生成测试覆盖,建议作为**第二个计划**(`2026-06-06-mysql-orchestrator-ha-reinstall.md`)单独实现,保持本计划可独立交付、可测试。自动 failover / watcher 收敛 / 分区自我隔离 / 半同步 的**运行期正确性**依赖 spec"成功标准"里的手工/集成验收(本计划单元测试只保证配置/编排正确);其中 spec Open Items(orchestrator release 版本与 API 路径、半同步 .so 名、AppArmor profile、debconf 键名)必须在三台实测中确认并据实回填代码。
