# k3s 高可用服务整合 Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `linuxshell` 增加一套可重复执行的 k3s 高可用服务整合能力，覆盖基础集群、Traefik NodePort 入口、Longhorn、Redis Sentinel、数据库集群内路由、迁移模板与验证 runbook。

**Architecture:** 新增独立入口 `install-k3s-ha.sh`，按现有 `install-pg-ha.sh` / `install-mysql-ha.sh` 模式加载 `lib/k3s-ha/` 模块。脚本负责生成和应用 k3s 基础设施 manifests；生产服务迁移通过清单模板和 runbook 驱动，不在 v1 自动批量搬迁业务服务。所有系统级动作必须可通过环境变量覆盖路径并在测试中 mock，避免本地测试触碰真实 k3s、Longhorn、数据库或防火墙。

**Tech Stack:** Bash (`set -euo pipefail`)、k3s、Traefik Ingress、Longhorn、Redis Sentinel、HAProxy TCP routing、现有 Bash test harness、现有防火墙模块约定。

**Spec:** `docs/superpowers/specs/2026-06-15-k3s-ha-service-consolidation-design.md`

---

## Scope Check

该 spec 覆盖多个子系统。实现必须按里程碑推进，每个 chunk 都产生可测试的增量：

1. 基础设施与入口：入口脚本、配置、角色校验、k3s 安装命令生成、Traefik NodePort 和 `edge-health`。
2. 数据面：Longhorn 安装约定、数据库 in-cluster HAProxy router、Redis Sentinel。
3. 迁移工具与 runbook：服务盘点模板、Caddy 切流、文件迁移、数据库迁移门槛。
4. 文档与总体验证：README、远程模块列表、完整测试命令。

不要在一个任务里同时实现 k3s 安装、数据库路由、Redis、迁移 runbook。每个任务提交一次。

## File Structure

| 文件 | 责任 |
|------|------|
| `install-k3s-ha.sh` | 新入口：本地/远程加载 k3s-ha 模块，调用 `k3s_ha_main`。 |
| `lib/k3s-ha/config.sh` | 所有 `K3S_HA_*` 默认值，端口、节点 IP、镜像、路径、manifest 输出目录。 |
| `lib/k3s-ha/common.sh` | 角色解析、IP 校验、manifest 写入、kubectl apply 包装、命名空间生成、通用断言。 |
| `lib/k3s-ha/install.sh` | k3s server/agent 安装命令生成与执行，节点标签提示，token/server URL 收集。 |
| `lib/k3s-ha/ingress.sh` | Traefik NodePort HelmChartConfig、`edge-health` Deployment/Service/Ingress manifests。 |
| `lib/k3s-ha/longhorn.sh` | Longhorn 前置依赖检查、安装入口、StorageClass 与备份目标配置骨架。 |
| `lib/k3s-ha/db-router.sh` | `postgres-ha` / `mysql-ha` in-cluster HAProxy Deployment/Service/PDB manifests。 |
| `lib/k3s-ha/redis.sh` | Redis Sentinel manifests 或 chart values 生成，`redis-master` routing Service/HAProxy。 |
| `lib/k3s-ha/migration.sh` | 服务盘点、文件迁移、数据库切换、Caddy 切流 runbook/template 生成。 |
| `lib/k3s-ha/main.sh` | 角色编排和子命令入口：`install`、`render`、`apply`、`templates`。 |
| `tests/test_k3s_ha.sh` | 新 k3s-ha 模块测试，mock 系统命令，只验证生成结果和调用顺序。 |
| `docs/k3s-ha/service-inventory-template.md` | 单服务迁移盘点模板。 |
| `docs/k3s-ha/caddy-cutover-runbook.md` | Caddy upstream 灰度/回滚 runbook。 |
| `docs/k3s-ha/file-migration-runbook.md` | 本地文件到 Longhorn PVC 的单写者迁移 runbook。 |
| `docs/k3s-ha/database-cutover-checklist.md` | 数据库 seed、追平、DDL 冻结、一致性校验和回滚清单。 |
| `docs/k3s-ha/backup-restore-runbook.md` | k3s datastore、数据库、Longhorn、Redis、Caddy 回滚的恢复演练清单。 |
| `README.md` | 增加 k3s 高可用服务整合入口、端口和边界说明。 |

---

## Chunk 1: 基础设施与入口

### Task 1: 测试骨架、配置模块和入口脚本

**Files:**
- Create: `tests/test_k3s_ha.sh`
- Create: `lib/k3s-ha/config.sh`
- Create: `lib/k3s-ha/common.sh`
- Create: `lib/k3s-ha/install.sh`
- Create: `lib/k3s-ha/ingress.sh`
- Create: `lib/k3s-ha/longhorn.sh`
- Create: `lib/k3s-ha/db-router.sh`
- Create: `lib/k3s-ha/redis.sh`
- Create: `lib/k3s-ha/migration.sh`
- Create: `lib/k3s-ha/main.sh`
- Create: `install-k3s-ha.sh`

- [ ] **Step 1: 写失败测试**

在 `tests/test_k3s_ha.sh` 建立测试骨架，先断言配置默认值、入口脚本加载顺序和可执行位。

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
assert_order() {
  local file="$1" first="$2" second="$3" l1 l2
  l1="$(grep -nF -- "$first" "$file" | head -1 | cut -d: -f1)"
  l2="$(grep -nF -- "$second" "$file" | head -1 | cut -d: -f1)"
  [[ -n "$l1" ]] || fail "assert_order: '$first' not found in $file"
  [[ -n "$l2" ]] || fail "assert_order: '$second' not found in $file"
  [[ "$l1" -lt "$l2" ]] || fail "expected '$first' before '$second'"
}

load_k3s_ha() {
  # shellcheck disable=SC1090,SC1091
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/k3s-ha/config.sh"
  source "${ROOT_DIR}/lib/k3s-ha/common.sh"
  source "${ROOT_DIR}/lib/k3s-ha/install.sh"
  source "${ROOT_DIR}/lib/k3s-ha/ingress.sh"
  source "${ROOT_DIR}/lib/k3s-ha/longhorn.sh"
  source "${ROOT_DIR}/lib/k3s-ha/db-router.sh"
  source "${ROOT_DIR}/lib/k3s-ha/redis.sh"
  source "${ROOT_DIR}/lib/k3s-ha/migration.sh"
  source "${ROOT_DIR}/lib/k3s-ha/main.sh"
}

run_config_tests() {
  (
    unset K3S_HA_CLUSTER_NAME K3S_HA_TRAEFIK_HTTP_NODEPORT K3S_HA_TRAEFIK_HTTPS_NODEPORT K3S_HA_MANIFEST_DIR
    unset K3S_HA_REDIS_IMAGE K3S_HA_EDGE_HEALTH_HOST K3S_HA_LONGHORN_STORAGECLASS K3S_HA_LONGHORN_STORAGECLASS_DEFAULT
    unset K3S_HA_LONGHORN_CHART_VERSION K3S_HA_LONGHORN_BACKUP_RETAIN K3S_HA_LONGHORN_SNAPSHOT_RETAIN
    unset K3S_HA_LONGHORN_SNAPSHOT_CRON K3S_HA_LONGHORN_BACKUP_CRON K3S_HA_REDIS_SECRET_FILE K3S_HA_REDIS_SENTINEL_QUORUM
    source "${ROOT_DIR}/lib/k3s-ha/config.sh"
    assert_equals "linuxshell-k3s" "${K3S_HA_CLUSTER_NAME}"
    assert_equals "30080" "${K3S_HA_TRAEFIK_HTTP_NODEPORT}"
    assert_equals "30443" "${K3S_HA_TRAEFIK_HTTPS_NODEPORT}"
    assert_equals "/data/k3s-ha/manifests" "${K3S_HA_MANIFEST_DIR}"
    assert_equals "redis:8.6.1" "${K3S_HA_REDIS_IMAGE}"
    assert_equals "k3s-health.internal" "${K3S_HA_EDGE_HEALTH_HOST}"
    assert_equals "longhorn-ha" "${K3S_HA_LONGHORN_STORAGECLASS}"
    assert_equals "false" "${K3S_HA_LONGHORN_STORAGECLASS_DEFAULT}"
    assert_equals "1.12.0" "${K3S_HA_LONGHORN_CHART_VERSION}"
    assert_equals "7" "${K3S_HA_LONGHORN_BACKUP_RETAIN}"
    assert_equals "24" "${K3S_HA_LONGHORN_SNAPSHOT_RETAIN}"
    assert_equals "0 */6 * * *" "${K3S_HA_LONGHORN_SNAPSHOT_CRON}"
    assert_equals "30 2 * * *" "${K3S_HA_LONGHORN_BACKUP_CRON}"
    assert_equals "/data/k3s-ha/secrets/redis-password" "${K3S_HA_REDIS_SECRET_FILE}"
    assert_equals "2" "${K3S_HA_REDIS_SENTINEL_QUORUM}"
  )
}

run_skeleton_tests() {
  local entry="${ROOT_DIR}/install-k3s-ha.sh"
  assert_file_exists "$entry"
  [[ -x "$entry" ]] || fail "expected install-k3s-ha.sh executable"
  bash -n "$entry"
  local modules_file; modules_file="$(mktemp)"
  trap "rm -f '$modules_file'" RETURN
  awk '/^load_linuxshell_modules \\/ {capture=1; next} capture && /^if \[\[/ {capture=0} capture {print}' "$entry" >"$modules_file"
  assert_contains "$modules_file" "lib/k3s-ha/config.sh"
  assert_contains "$modules_file" "lib/k3s-ha/main.sh"
  assert_not_contains "$entry" "lib/config.sh"
  assert_order "$modules_file" "lib/common.sh" "lib/k3s-ha/config.sh"
  assert_order "$modules_file" "lib/k3s-ha/config.sh" "lib/k3s-ha/common.sh"
  assert_order "$modules_file" "lib/k3s-ha/common.sh" "lib/k3s-ha/install.sh"
  assert_order "$modules_file" "lib/k3s-ha/install.sh" "lib/k3s-ha/ingress.sh"
  assert_order "$modules_file" "lib/k3s-ha/ingress.sh" "lib/k3s-ha/longhorn.sh"
  assert_order "$modules_file" "lib/k3s-ha/longhorn.sh" "lib/k3s-ha/db-router.sh"
  assert_order "$modules_file" "lib/k3s-ha/db-router.sh" "lib/k3s-ha/redis.sh"
  assert_order "$modules_file" "lib/k3s-ha/redis.sh" "lib/k3s-ha/migration.sh"
  assert_order "$modules_file" "lib/k3s-ha/migration.sh" "lib/k3s-ha/main.sh"
}

main() {
  local suite="${1:-all}"
  case "$suite" in
    config) run_config_tests ;;
    skeleton) run_skeleton_tests ;;
    all) run_config_tests; run_skeleton_tests ;;
    *) fail "unknown suite: $suite" ;;
  esac
  echo "PASS: ${suite}"
}

main "$@"
```

- [ ] **Step 2: 运行失败测试**

Run: `bash tests/test_k3s_ha.sh config`

Expected: 失败，原因是 `lib/k3s-ha/config.sh` 不存在。

- [ ] **Step 3: 实现 `config.sh`**

创建 `lib/k3s-ha/config.sh`：

```bash
# k3s-ha 专用配置;自兜底 DATA_ROOT,不加载主 lib/config.sh
DATA_ROOT="${DATA_ROOT:-/data}"

K3S_HA_CLUSTER_NAME="${K3S_HA_CLUSTER_NAME:-linuxshell-k3s}"
K3S_HA_ROLE="${K3S_HA_ROLE:-}"
K3S_HA_NODE_NAME="${K3S_HA_NODE_NAME:-}"
K3S_HA_NODE_IP="${K3S_HA_NODE_IP:-}"

K3S_HA_CONTROL_IP="${K3S_HA_CONTROL_IP:-}"
K3S_HA_WORKER1_IP="${K3S_HA_WORKER1_IP:-}"
K3S_HA_WORKER2_IP="${K3S_HA_WORKER2_IP:-}"
K3S_HA_CADDY_IP="${K3S_HA_CADDY_IP:-}"

K3S_HA_TRAEFIK_HTTP_NODEPORT="${K3S_HA_TRAEFIK_HTTP_NODEPORT:-30080}"
K3S_HA_TRAEFIK_HTTPS_NODEPORT="${K3S_HA_TRAEFIK_HTTPS_NODEPORT:-30443}"
K3S_HA_EDGE_HEALTH_HOST="${K3S_HA_EDGE_HEALTH_HOST:-k3s-health.internal}"

K3S_HA_MANIFEST_DIR="${K3S_HA_MANIFEST_DIR:-${DATA_ROOT}/k3s-ha/manifests}"
K3S_HA_TEMPLATE_DIR="${K3S_HA_TEMPLATE_DIR:-${DATA_ROOT}/k3s-ha/templates}"
K3S_HA_KUBECONFIG="${K3S_HA_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

K3S_HA_POSTGRES_PROXY_PORT="${K3S_HA_POSTGRES_PROXY_PORT:-5000}"
K3S_HA_MYSQL_PROXY_PORT="${K3S_HA_MYSQL_PROXY_PORT:-6446}"

K3S_HA_LONGHORN_STORAGECLASS="${K3S_HA_LONGHORN_STORAGECLASS:-longhorn-ha}"
K3S_HA_LONGHORN_STORAGECLASS_DEFAULT="${K3S_HA_LONGHORN_STORAGECLASS_DEFAULT:-false}"
K3S_HA_LONGHORN_CHART_VERSION="${K3S_HA_LONGHORN_CHART_VERSION:-1.12.0}"
K3S_HA_LONGHORN_BACKUP_TARGET="${K3S_HA_LONGHORN_BACKUP_TARGET:-}"
K3S_HA_LONGHORN_BACKUP_RETAIN="${K3S_HA_LONGHORN_BACKUP_RETAIN:-7}"
K3S_HA_LONGHORN_SNAPSHOT_RETAIN="${K3S_HA_LONGHORN_SNAPSHOT_RETAIN:-24}"
K3S_HA_LONGHORN_SNAPSHOT_CRON="${K3S_HA_LONGHORN_SNAPSHOT_CRON:-0 */6 * * *}"
K3S_HA_LONGHORN_BACKUP_CRON="${K3S_HA_LONGHORN_BACKUP_CRON:-30 2 * * *}"

K3S_HA_REDIS_IMAGE="${K3S_HA_REDIS_IMAGE:-redis:8.6.1}"
K3S_HA_REDIS_MASTER_NAME="${K3S_HA_REDIS_MASTER_NAME:-mymaster}"
K3S_HA_REDIS_PASSWORD="${K3S_HA_REDIS_PASSWORD:-}"
K3S_HA_REDIS_SECRET_FILE="${K3S_HA_REDIS_SECRET_FILE:-${DATA_ROOT}/k3s-ha/secrets/redis-password}"
K3S_HA_REDIS_SENTINEL_QUORUM="${K3S_HA_REDIS_SENTINEL_QUORUM:-2}"
K3S_HA_REDIS_SENTINEL_DOWN_AFTER_MS="${K3S_HA_REDIS_SENTINEL_DOWN_AFTER_MS:-5000}"
K3S_HA_REDIS_SENTINEL_FAILOVER_MS="${K3S_HA_REDIS_SENTINEL_FAILOVER_MS:-10000}"
```

- [ ] **Step 4: 实现入口脚本**

创建 `install-k3s-ha.sh`，按现有入口模式加载模块：

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

  if [[ -f "${module_root}/lib/k3s-ha/config.sh" ]]; then
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
  lib/k3s-ha/config.sh \
  lib/k3s-ha/common.sh \
  lib/k3s-ha/install.sh \
  lib/k3s-ha/ingress.sh \
  lib/k3s-ha/longhorn.sh \
  lib/k3s-ha/db-router.sh \
  lib/k3s-ha/redis.sh \
  lib/k3s-ha/migration.sh \
  lib/k3s-ha/main.sh

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  k3s_ha_main "$@"
fi
```

- [ ] **Step 5: 创建占位模块以满足加载**

Run:

```bash
mkdir -p lib/k3s-ha
for f in common install ingress longhorn db-router redis migration main; do
  printf '#!/usr/bin/env bash\n\n' >"lib/k3s-ha/${f}.sh"
done
```

随后用 `apply_patch` 把 `lib/k3s-ha/main.sh` 改成最小函数：

```bash
k3s_ha_main() {
  require_root
  detect_os
  local cmd="${1:-help}"
  case "$cmd" in
    help|-h|--help)
      cat <<'USAGE'
Usage: install-k3s-ha.sh <help>
USAGE
      ;;
    *)
      echo "Command not implemented yet: $cmd" >&2
      return 1
      ;;
  esac
}
```

- [ ] **Step 6: 运行测试**

Run: `chmod +x install-k3s-ha.sh tests/test_k3s_ha.sh && bash tests/test_k3s_ha.sh all`

Expected: `PASS: all`

- [ ] **Step 7: 语法检查**

Run: `bash -n install-k3s-ha.sh && find lib/k3s-ha -name '*.sh' -type f -print0 | xargs -0 -n1 bash -n && bash -n tests/test_k3s_ha.sh`

Expected: exit 0, no syntax errors.

- [ ] **Step 8: 提交**

```bash
git add install-k3s-ha.sh lib/k3s-ha tests/test_k3s_ha.sh
git commit -m "feat(k3s-ha): 新增入口与配置骨架"
```

### Task 2: common 工具、角色解析和 manifest 写入

**Files:**
- Modify: `tests/test_k3s_ha.sh`
- Modify: `lib/k3s-ha/common.sh`

- [ ] **Step 1: 写失败测试**

在 `tests/test_k3s_ha.sh` 增加 `run_common_tests`，把 `common) run_common_tests ;;` 加入 `main()` case，并把 `all` 加上该 suite。

```bash
run_common_tests() {
  load_k3s_ha

  k3s_ha_parse_role "1"; assert_equals "server" "${K3S_HA_ROLE}"
  k3s_ha_parse_role "server"; assert_equals "server" "${K3S_HA_ROLE}"
  k3s_ha_parse_role "2"; assert_equals "worker" "${K3S_HA_ROLE}"
  k3s_ha_parse_role "worker"; assert_equals "worker" "${K3S_HA_ROLE}"
  k3s_ha_parse_role "3"; assert_equals "addons" "${K3S_HA_ROLE}"
  k3s_ha_parse_role "addons"; assert_equals "addons" "${K3S_HA_ROLE}"
  if k3s_ha_parse_role "bad" 2>/dev/null; then fail "expected bad role to fail"; fi

  (
    export K3S_HA_CONTROL_IP=10.0.0.10 K3S_HA_WORKER1_IP=10.0.0.11 K3S_HA_WORKER2_IP=10.0.0.12 K3S_HA_CADDY_IP=10.0.0.20
    k3s_ha_validate_ips
  )
  (
    export K3S_HA_CONTROL_IP=10.0.0.10 K3S_HA_WORKER1_IP=not-ip K3S_HA_WORKER2_IP=10.0.0.12 K3S_HA_CADDY_IP=10.0.0.20
    if k3s_ha_validate_ips 2>/dev/null; then fail "expected invalid IP to fail"; fi
  )

  local tdir; tdir="$(mktemp -d)"; trap "rm -rf '$tdir'" RETURN
  export K3S_HA_MANIFEST_DIR="$tdir"
  k3s_ha_write_manifest "test.yaml" "apiVersion: v1"
  assert_file_exists "${tdir}/test.yaml"
  assert_contains "${tdir}/test.yaml" "apiVersion: v1"
}
```

- [ ] **Step 2: 运行失败测试**

Run: `bash tests/test_k3s_ha.sh common`

Expected: 失败，提示 `k3s_ha_parse_role` 不存在。

- [ ] **Step 3: 实现 common 函数**

在 `lib/k3s-ha/common.sh` 中实现：

```bash
k3s_ha_parse_role() {
  local role
  role="$(to_lower "$1")"
  case "$role" in
    1|server) K3S_HA_ROLE="server" ;;
    2|worker) K3S_HA_ROLE="worker" ;;
    3|addons) K3S_HA_ROLE="addons" ;;
    *) echo "Invalid k3s-ha role: $1" >&2; return 1 ;;
  esac
}

k3s_ha_is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

k3s_ha_validate_ips() {
  local name value
  for name in K3S_HA_CONTROL_IP K3S_HA_WORKER1_IP K3S_HA_WORKER2_IP K3S_HA_CADDY_IP; do
    value="${!name:-}"
    if [[ -z "$value" || ! "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$name must be an IPv4 address." >&2
      return 1
    fi
  done
}

k3s_ha_write_manifest() {
  local name="$1" content="$2" path
  mkdir -p "$K3S_HA_MANIFEST_DIR"
  path="${K3S_HA_MANIFEST_DIR}/${name}"
  printf '%s\n' "$content" >"$path"
}

k3s_ha_kubectl_apply() {
  local file="$1"
  kubectl --kubeconfig "$K3S_HA_KUBECONFIG" apply -f "$file"
}
```

- [ ] **Step 4: 运行测试**

Run: `bash tests/test_k3s_ha.sh common`

Expected: `PASS: common`

- [ ] **Step 5: 提交**

```bash
git add tests/test_k3s_ha.sh lib/k3s-ha/common.sh
git commit -m "feat(k3s-ha): 增加角色校验与 manifest 工具"
```

### Task 3: k3s 安装命令生成与主编排

**Files:**
- Modify: `tests/test_k3s_ha.sh`
- Modify: `lib/k3s-ha/install.sh`
- Modify: `lib/k3s-ha/main.sh`

- [ ] **Step 1: 写失败测试**

新增 `run_install_tests`，并把 `install) run_install_tests ;;` 加入 `main()` case，把 `run_install_tests` 加入 `all` suite。

```bash
run_install_tests() {
  load_k3s_ha

  local server_cmd worker_cmd
  export K3S_HA_CONTROL_IP=10.0.0.10 K3S_HA_NODE_NAME=control-01 K3S_HA_NODE_IP=10.0.0.10
  export K3S_HA_TOKEN="token-value"

  server_cmd="$(k3s_ha_server_install_command)"
  case "$server_cmd" in
    *"--disable servicelb"* ) : ;; *) fail "server install must disable servicelb" ;; esac
  case "$server_cmd" in
    *"--write-kubeconfig-mode 600"* ) : ;; *) fail "server install must set kubeconfig mode" ;; esac
  case "$server_cmd" in
    *"--node-name control-01"* ) : ;; *) fail "server install must include node name" ;; esac
  case "$server_cmd" in
    *"--node-ip 10.0.0.10"* ) : ;; *) fail "server install must include node ip" ;; esac
  case "$server_cmd" in
    *"--node-taint node-role.kubernetes.io/control-plane=true:NoSchedule"* ) : ;; *) fail "server must taint control node" ;; esac
  case "$server_cmd" in
    *"--node-label node-role=control"* ) : ;; *) fail "server must label control node" ;; esac

  export K3S_HA_NODE_NAME=worker-a K3S_HA_NODE_IP=10.0.0.11
  worker_cmd="$(k3s_ha_worker_install_command)"
  case "$worker_cmd" in
    *"K3S_URL=https://10.0.0.10:6443"* ) : ;; *) fail "worker command must include K3S_URL" ;; esac
  case "$worker_cmd" in
    *"K3S_TOKEN=token-value"* ) : ;; *) fail "worker command must include token" ;; esac
  case "$worker_cmd" in
    *"--node-name worker-a"* ) : ;; *) fail "worker install must include node name" ;; esac
  case "$worker_cmd" in
    *"--node-ip 10.0.0.11"* ) : ;; *) fail "worker install must include node ip" ;; esac
  case "$worker_cmd" in
    *"--node-label node-role=worker-data"* ) : ;; *) fail "worker must get worker-data label" ;; esac
}
```

- [ ] **Step 2: 运行失败测试**

Run: `bash tests/test_k3s_ha.sh install`

Expected: 失败，提示 install command 函数不存在。

- [ ] **Step 3: 实现安装命令函数**

在 `lib/k3s-ha/install.sh`：

```bash
k3s_ha_server_install_command() {
  printf '%s' "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server --disable servicelb --write-kubeconfig-mode 600 --node-name ${K3S_HA_NODE_NAME:-control} --node-ip ${K3S_HA_NODE_IP:-${K3S_HA_CONTROL_IP}} --node-label node-role=control --node-taint node-role.kubernetes.io/control-plane=true:NoSchedule' sh -"
}

k3s_ha_worker_install_command() {
  if [[ -z "${K3S_HA_CONTROL_IP:-}" || -z "${K3S_HA_TOKEN:-}" ]]; then
    echo "K3S_HA_CONTROL_IP and K3S_HA_TOKEN are required for worker install." >&2
    return 1
  fi
  printf '%s' "curl -sfL https://get.k3s.io | K3S_URL=https://${K3S_HA_CONTROL_IP}:6443 K3S_TOKEN=${K3S_HA_TOKEN} INSTALL_K3S_EXEC='agent --node-name ${K3S_HA_NODE_NAME:-worker} --node-ip ${K3S_HA_NODE_IP:-} --node-label node-role=worker-data' sh -"
}

k3s_ha_install_k3s() {
  case "${K3S_HA_ROLE}" in
    server) eval "$(k3s_ha_server_install_command)" ;;
    worker) eval "$(k3s_ha_worker_install_command)" ;;
    *) echo "k3s install only supports server or worker role." >&2; return 1 ;;
  esac
}
```

Do not run these commands in tests; tests inspect strings only.

- [ ] **Step 4: 实现 `main.sh` 子命令骨架**

`lib/k3s-ha/main.sh`：

```bash
k3s_ha_main() {
  require_root
  detect_os

  local cmd="${1:-help}"
  case "$cmd" in
    install)
      k3s_ha_parse_role "${2:-${K3S_HA_ROLE:-}}"
      k3s_ha_install_k3s
      ;;
    help|-h|--help)
      cat <<'USAGE'
Usage: install-k3s-ha.sh <install|help> [role]
USAGE
      ;;
    *)
      echo "Unknown k3s-ha command: $cmd" >&2
      return 1
      ;;
  esac
}
```

- [ ] **Step 5: 运行测试**

Run: `bash tests/test_k3s_ha.sh install`

Expected: `PASS: install`

- [ ] **Step 6: 提交**

```bash
git add tests/test_k3s_ha.sh lib/k3s-ha/install.sh lib/k3s-ha/main.sh
git commit -m "feat(k3s-ha): 增加 k3s 安装命令生成"
```

### Task 4: Traefik NodePort 与 edge-health manifests

**Files:**
- Modify: `tests/test_k3s_ha.sh`
- Modify: `lib/k3s-ha/ingress.sh`

- [ ] **Step 1: 写失败测试**

新增 `run_ingress_tests`：
同时把 `ingress) run_ingress_tests ;;` 加入 `main()` case，把 `run_ingress_tests` 加入 `all` suite。

```bash
run_ingress_tests() {
  load_k3s_ha
  local tdir; tdir="$(mktemp -d)"; trap "rm -rf '$tdir'" RETURN
  export K3S_HA_MANIFEST_DIR="$tdir"

  k3s_ha_render_ingress

  assert_file_exists "${tdir}/traefik-nodeport.yaml"
  assert_file_exists "${tdir}/edge-health.yaml"
  assert_contains "${tdir}/traefik-nodeport.yaml" "nodePort: 30080"
  assert_contains "${tdir}/traefik-nodeport.yaml" "nodePort: 30443"
  assert_contains "${tdir}/edge-health.yaml" "k3s-health.internal"
  assert_contains "${tdir}/edge-health.yaml" "/-/edge-health"
  assert_contains "${tdir}/edge-health.yaml" "return 200"
}
```

- [ ] **Step 2: 运行失败测试**

Run: `bash tests/test_k3s_ha.sh ingress`

Expected: 失败，提示 `k3s_ha_render_ingress` 不存在。

- [ ] **Step 3: 实现 manifest 生成**

`lib/k3s-ha/ingress.sh` 生成两个文件：

- `traefik-nodeport.yaml`：`HelmChartConfig`，固定 web/websecure NodePort。
- `edge-health.yaml`：Namespace、ConfigMap、Deployment、Service、Ingress。ConfigMap 写入 nginx `location = /-/edge-health { return 200 'ok\n'; }`，保证 Caddy 主动健康检查拿到 HTTP 200。

核心片段：

```bash
k3s_ha_render_ingress() {
  k3s_ha_write_manifest "traefik-nodeport.yaml" "$(cat <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        nodePort: ${K3S_HA_TRAEFIK_HTTP_NODEPORT}
      websecure:
        nodePort: ${K3S_HA_TRAEFIK_HTTPS_NODEPORT}
    service:
      type: NodePort
EOF
)"

  k3s_ha_write_manifest "edge-health.yaml" "$(cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: edge-health
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edge-health
  namespace: edge-health
spec:
  replicas: 2
  selector:
    matchLabels:
      app: edge-health
  template:
    metadata:
      labels:
        app: edge-health
    spec:
      containers:
        - name: http
          image: nginx:alpine
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
          ports:
            - containerPort: 80
      volumes:
        - name: nginx-conf
          configMap:
            name: edge-health-nginx
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: edge-health-nginx
  namespace: edge-health
data:
  default.conf: |
    server {
      listen 80;
      location = /-/edge-health {
        return 200 'ok\n';
      }
    }
---
apiVersion: v1
kind: Service
metadata:
  name: edge-health
  namespace: edge-health
spec:
  selector:
    app: edge-health
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: edge-health
  namespace: edge-health
spec:
  rules:
    - host: ${K3S_HA_EDGE_HEALTH_HOST}
      http:
        paths:
          - path: /-/edge-health
            pathType: Exact
            backend:
              service:
                name: edge-health
                port:
                  number: 80
EOF
)"
}
```

The test must assert `return 200` exists so a default nginx 404 cannot slip through.

- [ ] **Step 4: 运行测试**

Run: `bash tests/test_k3s_ha.sh ingress`

Expected: `PASS: ingress`

- [ ] **Step 5: 提交**

```bash
git add tests/test_k3s_ha.sh lib/k3s-ha/ingress.sh
git commit -m "feat(k3s-ha): 生成 Traefik 入口配置"
```

---

## Chunk 2: 数据面与备份

### Task 5: Longhorn 安装约定、StorageClass 与备份骨架

**Files:**
- Modify: `tests/test_k3s_ha.sh`
- Modify: `lib/k3s-ha/config.sh`
- Modify: `lib/k3s-ha/longhorn.sh`

- [ ] **Step 1: 写失败测试**

新增 `run_longhorn_tests`，并把 `longhorn) run_longhorn_tests ;;` 加入 `main()` case，把 `run_longhorn_tests` 加入 `all` suite。验证生成的 manifests 包含 Longhorn HelmChart 安装资源、显式非默认 StorageClass、双副本配置、周期快照/备份计划、recurring job 绑定和备份目标说明。

```bash
run_longhorn_tests() {
  load_k3s_ha
  local tdir; tdir="$(mktemp -d)"; trap "rm -rf '$tdir'" RETURN
  export K3S_HA_MANIFEST_DIR="$tdir"
  export K3S_HA_LONGHORN_CHART_VERSION="1.12.0"
  export K3S_HA_LONGHORN_BACKUP_TARGET="s3://linuxshell-longhorn-backups@us-east-1/"

  k3s_ha_render_longhorn

  assert_file_exists "${tdir}/longhorn-install.yaml"
  assert_file_exists "${tdir}/longhorn-storageclass.yaml"
  assert_file_exists "${tdir}/longhorn-recurring-jobs.yaml"
  assert_file_exists "${tdir}/longhorn-node-disk.md"
  assert_contains "${tdir}/longhorn-install.yaml" "HelmChart"
  assert_contains "${tdir}/longhorn-install.yaml" "namespace: kube-system"
  assert_contains "${tdir}/longhorn-install.yaml" "targetNamespace: longhorn-system"
  assert_contains "${tdir}/longhorn-install.yaml" "createNamespace: true"
  assert_contains "${tdir}/longhorn-install.yaml" "https://charts.longhorn.io"
  assert_contains "${tdir}/longhorn-install.yaml" "version: 1.12.0"
  assert_contains "${tdir}/longhorn-storageclass.yaml" "numberOfReplicas: \"2\""
  assert_contains "${tdir}/longhorn-storageclass.yaml" "reclaimPolicy: Retain"
  assert_contains "${tdir}/longhorn-storageclass.yaml" "storageclass.kubernetes.io/is-default-class: \"false\""
  assert_contains "${tdir}/longhorn-storageclass.yaml" "recurringJobSelector"
  assert_contains "${tdir}/longhorn-storageclass.yaml" "ha-snapshot"
  assert_contains "${tdir}/longhorn-storageclass.yaml" "ha-backup"
  assert_contains "${tdir}/longhorn-recurring-jobs.yaml" "backup"
  assert_contains "${tdir}/longhorn-recurring-jobs.yaml" "snapshot"
  assert_contains "${tdir}/longhorn-recurring-jobs.yaml" "0 */6 * * *"
  assert_contains "${tdir}/longhorn-recurring-jobs.yaml" "30 2 * * *"
  assert_file_exists "${tdir}/longhorn-backup-target.md"
  assert_contains "${tdir}/longhorn-backup-target.md" "s3://linuxshell-longhorn-backups@us-east-1/"
}
```

- [ ] **Step 2: 实现 `longhorn.sh`**

Functions:

- `k3s_ha_check_longhorn_prereqs`: checks `open-iscsi`/`iscsid` availability and warns if missing.
- `k3s_ha_render_longhorn_install`: writes `longhorn-install.yaml` as a k3s HelmChart resource with `metadata.namespace: kube-system`, `spec.targetNamespace: longhorn-system`, `spec.createNamespace: true`, repo `https://charts.longhorn.io`, chart `longhorn`, and `${K3S_HA_LONGHORN_CHART_VERSION}`.
- `k3s_ha_render_longhorn`: writes HelmChart install resource, StorageClass, recurring snapshot/backup jobs, backup target instructions, and worker disk/tag instructions.
- `k3s_ha_apply_longhorn`: applies `longhorn-install.yaml`, waits for Longhorn CRDs such as `recurringjobs.longhorn.io` to become Established, waits for Longhorn manager rollout, then applies StorageClass/RecurringJob resources and prints manual backup-target command.

StorageClass must be named `${K3S_HA_LONGHORN_STORAGECLASS}`, set `storageclass.kubernetes.io/is-default-class` from `${K3S_HA_LONGHORN_STORAGECLASS_DEFAULT}` which defaults to `"false"`, use `Retain`, set `numberOfReplicas: "2"`, and include a `recurringJobSelector` binding to `ha-snapshot` and `ha-backup`. Business manifests must explicitly set `storageClassName: ${K3S_HA_LONGHORN_STORAGECLASS}` only for critical shared file PVCs; logs/cache/temp PVCs must not rely on Longhorn by default. The node/disk guide must state that Longhorn storage is enabled only on the two worker/data nodes, existing volumes must be assigned the same recurring job group/labels if they were created before the StorageClass selector existed, and replicas must be rebuilt after a single-node failure.

The recurring job manifest must define:

- `RecurringJob` named `ha-snapshot` with schedule `${K3S_HA_LONGHORN_SNAPSHOT_CRON}` and retain `${K3S_HA_LONGHORN_SNAPSHOT_RETAIN}`.
- `RecurringJob` named `ha-backup` with schedule `${K3S_HA_LONGHORN_BACKUP_CRON}` and retain `${K3S_HA_LONGHORN_BACKUP_RETAIN}`.
- note that `K3S_HA_LONGHORN_BACKUP_TARGET` must be configured before production use.

- [ ] **Step 3: 运行测试**

Run: `bash tests/test_k3s_ha.sh longhorn`

Expected: `PASS: longhorn`

- [ ] **Step 4: 提交**

```bash
git add tests/test_k3s_ha.sh lib/k3s-ha/config.sh lib/k3s-ha/longhorn.sh
git commit -m "feat(k3s-ha): 增加 Longhorn 存储配置"
```

### Task 6: PostgreSQL/MySQL in-cluster HAProxy router

**Files:**
- Modify: `tests/test_k3s_ha.sh`
- Modify: `lib/k3s-ha/db-router.sh`

- [ ] **Step 1: 写失败测试**

新增 `run_db_router_tests`：
同时把 `db-router) run_db_router_tests ;;` 加入 `main()` case，把 `run_db_router_tests` 加入 `all` suite。

```bash
run_db_router_tests() {
  load_k3s_ha
  local tdir; tdir="$(mktemp -d)"; trap "rm -rf '$tdir'" RETURN
  export K3S_HA_MANIFEST_DIR="$tdir"
  export K3S_HA_WORKER1_IP=10.0.0.11 K3S_HA_WORKER2_IP=10.0.0.12

  k3s_ha_render_db_router

  assert_file_exists "${tdir}/postgres-ha-router.yaml"
  assert_file_exists "${tdir}/mysql-ha-router.yaml"
  assert_contains "${tdir}/postgres-ha-router.yaml" "10.0.0.11:5000"
  assert_contains "${tdir}/postgres-ha-router.yaml" "10.0.0.12:5000"
  assert_contains "${tdir}/mysql-ha-router.yaml" "10.0.0.11:6446"
  assert_contains "${tdir}/mysql-ha-router.yaml" "10.0.0.12:6446"
  assert_contains "${tdir}/postgres-ha-router.yaml" "podAntiAffinity"
  assert_contains "${tdir}/postgres-ha-router.yaml" "PodDisruptionBudget"
  assert_contains "${tdir}/mysql-ha-router.yaml" "podAntiAffinity"
  assert_contains "${tdir}/mysql-ha-router.yaml" "PodDisruptionBudget"
  assert_contains "${tdir}/postgres-ha-router.yaml" "option tcp-check"
  assert_contains "${tdir}/mysql-ha-router.yaml" "option tcp-check"
  assert_contains "${tdir}/postgres-ha-router.yaml" "retries 3"
  assert_contains "${tdir}/mysql-ha-router.yaml" "retries 3"
}
```

- [ ] **Step 2: 实现 `db-router.sh`**

Generate:

- Namespace `data-routing`.
- ConfigMap with HAProxy TCP config.
- Deployment with 2 replicas.
- ClusterIP Service mapping `postgres-ha:5432` and `mysql-ha:3306`.
- PDB `minAvailable: 1`.
- `podAntiAffinity` keyed by app label, required for both PostgreSQL and MySQL router pods.

HAProxy config must use both worker HAProxy backends and include concrete TCP health/retry settings:

```haproxy
defaults
  mode tcp
  timeout connect 3s
  timeout client 30s
  timeout server 30s
  retries 3

backend postgres
  option tcp-check
  default-server inter 2s fall 2 rise 2
  server node-a ${K3S_HA_WORKER1_IP}:${K3S_HA_POSTGRES_PROXY_PORT} check
  server node-b ${K3S_HA_WORKER2_IP}:${K3S_HA_POSTGRES_PROXY_PORT} check
```

MySQL uses the same pattern with `${K3S_HA_MYSQL_PROXY_PORT}`.

- [ ] **Step 3: 运行测试**

Run: `bash tests/test_k3s_ha.sh db-router`

Expected: `PASS: db-router`

- [ ] **Step 4: 提交**

```bash
git add tests/test_k3s_ha.sh lib/k3s-ha/db-router.sh
git commit -m "feat(k3s-ha): 生成数据库集群内路由"
```

### Task 7: Redis Sentinel manifests

**Files:**
- Modify: `tests/test_k3s_ha.sh`
- Modify: `lib/k3s-ha/config.sh`
- Modify: `lib/k3s-ha/redis.sh`

- [ ] **Step 1: 写失败测试**

新增 `run_redis_tests`：
同时把 `redis) run_redis_tests ;;` 加入 `main()` case，把 `run_redis_tests` 加入 `all` suite。

```bash
run_redis_tests() {
  load_k3s_ha
  local tdir; tdir="$(mktemp -d)"; trap "rm -rf '$tdir'" RETURN
  export K3S_HA_MANIFEST_DIR="$tdir"
  export K3S_HA_REDIS_PASSWORD="test-redis-password"

  k3s_ha_render_redis

  assert_file_exists "${tdir}/redis-sentinel.yaml"
  assert_contains "${tdir}/redis-sentinel.yaml" "redis:8.6.1"
  assert_contains "${tdir}/redis-sentinel.yaml" "redis-auth"
  assert_contains "${tdir}/redis-sentinel.yaml" "secretKeyRef"
  assert_contains "${tdir}/redis-sentinel.yaml" "key: password"
  assert_contains "${tdir}/redis-sentinel.yaml" "REDIS_PASSWORD"
  assert_contains "${tdir}/redis-sentinel.yaml" "appendonly yes"
  assert_contains "${tdir}/redis-sentinel.yaml" "appendfsync everysec"
  assert_contains "${tdir}/redis-sentinel.yaml" "mymaster"
  assert_contains "${tdir}/redis-sentinel.yaml" "replicaof"
  assert_contains "${tdir}/redis-sentinel.yaml" "sentinel monitor"
  assert_contains "${tdir}/redis-sentinel.yaml" "sentinel auth-pass"
  assert_contains "${tdir}/redis-sentinel.yaml" "app.kubernetes.io/component: sentinel"
  assert_contains "${tdir}/redis-sentinel.yaml" "topologySpreadConstraints"
  assert_contains "${tdir}/redis-sentinel.yaml" "tolerations"
  assert_contains "${tdir}/redis-sentinel.yaml" "node-role.kubernetes.io/control-plane"
  assert_contains "${tdir}/redis-sentinel.yaml" "node-role=worker-data"
  assert_contains "${tdir}/redis-sentinel.yaml" "requiredDuringSchedulingIgnoredDuringExecution"
  assert_contains "${tdir}/redis-sentinel.yaml" "podAntiAffinity"
  assert_contains "${tdir}/redis-sentinel.yaml" "redis-master"
  assert_contains "${tdir}/redis-sentinel.yaml" "tcp-check send"
  assert_contains "${tdir}/redis-sentinel.yaml" "AUTH"
  assert_contains "${tdir}/redis-sentinel.yaml" "ROLE"
  assert_contains "${tdir}/redis-sentinel.yaml" "master"
  assert_contains "${tdir}/redis-sentinel.yaml" "PodDisruptionBudget"
  assert_file_exists "${tdir}/redis-backup-restore-runbook.md"
  assert_contains "${tdir}/redis-backup-restore-runbook.md" "Sentinel failover"
  assert_contains "${tdir}/redis-backup-restore-runbook.md" "old master rejoin"
}
```

- [ ] **Step 2: 实现 `redis.sh`**

Render a v1 Redis Sentinel manifest with:

- Namespace `session-store`.
- `k3s_ha_resolve_redis_password`: resolves Redis auth without rotating it on every render. Priority is `K3S_HA_REDIS_PASSWORD`, then an existing `K3S_HA_REDIS_SECRET_FILE` with mode `600`, otherwise generate a password once, create parent directory, write the file with mode `600`, and reuse it on later renders. Production apply output must warn that operators should back up this local secret file or supply `K3S_HA_REDIS_PASSWORD` from their secret manager.
- Secret `redis-auth` with key `password` from the resolved password. Redis server, Sentinel, and HAProxy must all reference the same Secret key through `secretKeyRef` / `REDIS_PASSWORD`; do not hardcode three independent password values in the manifest.
- Redis headless Service for stable pod DNS.
- Redis StatefulSet with 2 pods, `nodeSelector: node-role=worker-data`, required pod anti-affinity for the Redis server pods, and PVC template using `${K3S_HA_LONGHORN_STORAGECLASS}`.
- Bootstrap config where pod ordinal `0` starts as initial master and pod ordinal `1` starts with `replicaof redis-0.redis-headless 6379` only when the data directory/config state is empty. Existing writable Redis/Sentinel config must be preserved so Sentinel rewrite state survives restarts and an old master returning after failover cannot overwrite the promoted master state.
- Redis config with `appendonly yes` and `appendfsync everysec`.
- Sentinel Deployment with 3 replicas, label `app.kubernetes.io/component: sentinel`, `sentinel monitor ${K3S_HA_REDIS_MASTER_NAME}`, quorum from config, `sentinel auth-pass`, `topologySpreadConstraints`/anti-affinity across `kubernetes.io/hostname`, and a `node-role.kubernetes.io/control-plane` toleration so replicas can cover control + two workers.
- `redis-master` HAProxy routing Deployment with 2 replicas, PDB, pod anti-affinity, and an application-level Redis role check that only routes to the current Redis master. HAProxy must use `tcp-check send` for `AUTH` when a password exists, then `ROLE` or `INFO replication`, and must `tcp-check expect` `master`/`role:master` before marking a backend up.
- `redis-backup-restore-runbook.md` covering AOF/RDB backup, Longhorn PVC backup, Sentinel failover verification, old master rejoin verification, and application reconnect check.

Tests should verify generated YAML contains a single Redis auth Secret reference, AOF, `appendfsync everysec`, Sentinel monitor/auth, `replicaof`, Redis server node selector and required anti-affinity, PDB, route service, HAProxy AUTH, and HAProxy role-based `tcp-check`.

- [ ] **Step 3: 运行测试**

Run: `bash tests/test_k3s_ha.sh redis`

Expected: `PASS: redis`

- [ ] **Step 4: 提交**

```bash
git add tests/test_k3s_ha.sh lib/k3s-ha/config.sh lib/k3s-ha/redis.sh
git commit -m "feat(k3s-ha): 生成 Redis Sentinel 配置"
```

### Task 8: 数据面备份与恢复演练清单

**Files:**
- Modify: `tests/test_k3s_ha.sh`
- Modify: `lib/k3s-ha/migration.sh`
- Create: `docs/k3s-ha/backup-restore-runbook.md`

- [ ] **Step 1: 写失败测试**

新增 `run_backup_restore_tests`，并把 `backup-restore) run_backup_restore_tests ;;` 加入 `main()` case，把 `run_backup_restore_tests` 加入 `all` suite。

```bash
run_backup_restore_tests() {
  load_k3s_ha
  local tdir; tdir="$(mktemp -d)"; trap "rm -rf '$tdir'" RETURN
  export K3S_HA_TEMPLATE_DIR="$tdir"

  k3s_ha_write_backup_restore_runbook

  assert_file_exists "${tdir}/backup-restore-runbook.md"
  assert_contains "${tdir}/backup-restore-runbook.md" "k3s SQLite datastore"
  assert_contains "${tdir}/backup-restore-runbook.md" "PostgreSQL restore drill"
  assert_contains "${tdir}/backup-restore-runbook.md" "MySQL restore drill"
  assert_contains "${tdir}/backup-restore-runbook.md" "Longhorn volume restore"
  assert_contains "${tdir}/backup-restore-runbook.md" "Longhorn replica rebuild after new node join"
  assert_contains "${tdir}/backup-restore-runbook.md" "Redis Sentinel failover"
  assert_contains "${tdir}/backup-restore-runbook.md" "Caddy upstream rollback"
  assert_file_exists "${ROOT_DIR}/docs/k3s-ha/backup-restore-runbook.md"
  cmp -s "${tdir}/backup-restore-runbook.md" "${ROOT_DIR}/docs/k3s-ha/backup-restore-runbook.md" || fail "backup restore runbook drift"
}
```

- [ ] **Step 2: 实现 runbook 生成**

在 `lib/k3s-ha/migration.sh` 中实现 `k3s_ha_write_backup_restore_runbook`，写入：

- k3s single-server SQLite datastore 备份与恢复演练。
- manifests/Secrets 备份，Secrets 必须加密保存。
- PostgreSQL restore drill：从备份恢复到测试实例并验证核心库表。
- MySQL restore drill：从备份恢复到测试实例并验证核心库表。
- Longhorn volume restore：从外部备份恢复 PVC 并挂载到测试 pod。
- Longhorn replica rebuild after new node join：上线第三台或替换节点后确认 Longhorn volume replica 自动/手动重建完成，再允许旧节点下线。
- Redis Sentinel failover：手动停止 master、观察 replica 提升、验证 `redis-master` 入口和应用重连。
- Caddy upstream rollback：从新 k3s upstream 切回旧 upstream 的演练步骤。

- [ ] **Step 3: 复制到 repo docs 并保持一致**

将生成内容复制到 `docs/k3s-ha/backup-restore-runbook.md`，并在本 task 内增加一致性验证：

```bash
cmp -s "${tdir}/backup-restore-runbook.md" "${ROOT_DIR}/docs/k3s-ha/backup-restore-runbook.md" || fail "backup restore runbook drift"
```

- [ ] **Step 4: 运行测试**

Run: `bash tests/test_k3s_ha.sh backup-restore`

Expected: `PASS: backup-restore`

- [ ] **Step 5: 提交**

```bash
git add tests/test_k3s_ha.sh lib/k3s-ha/migration.sh docs/k3s-ha/backup-restore-runbook.md
git commit -m "docs(k3s-ha): 增加备份恢复演练清单"
```

---

## Chunk 3: 迁移模板与 runbook

### Task 9: 服务盘点模板与迁移文档生成

**Files:**
- Modify: `tests/test_k3s_ha.sh`
- Modify: `lib/k3s-ha/migration.sh`
- Create: `docs/k3s-ha/service-inventory-template.md`
- Create: `docs/k3s-ha/caddy-cutover-runbook.md`
- Create: `docs/k3s-ha/file-migration-runbook.md`
- Create: `docs/k3s-ha/database-cutover-checklist.md`

- [ ] **Step 1: 写失败测试**

新增 `run_migration_tests`，并把 `migration) run_migration_tests ;;` 加入 `main()` case，把 `run_migration_tests` 加入 `all` suite。测试必须验证模板写入并包含关键门槛。

```bash
run_migration_tests() {
  load_k3s_ha
  local tdir; tdir="$(mktemp -d)"; trap "rm -rf '$tdir'" RETURN
  export K3S_HA_TEMPLATE_DIR="$tdir"

  k3s_ha_write_migration_templates

  assert_file_exists "${tdir}/service-inventory-template.md"
  assert_file_exists "${tdir}/caddy-cutover-runbook.md"
  assert_file_exists "${tdir}/file-migration-runbook.md"
  assert_file_exists "${tdir}/database-cutover-checklist.md"
  assert_contains "${tdir}/service-inventory-template.md" "Caddy 域名"
  assert_contains "${tdir}/service-inventory-template.md" "当前 upstream"
  assert_contains "${tdir}/service-inventory-template.md" "启动命令"
  assert_contains "${tdir}/service-inventory-template.md" "环境变量"
  assert_contains "${tdir}/service-inventory-template.md" "配置文件"
  assert_contains "${tdir}/service-inventory-template.md" "本地目录分类"
  assert_contains "${tdir}/service-inventory-template.md" "session 后端"
  assert_contains "${tdir}/caddy-cutover-runbook.md" ":30080"
  assert_contains "${tdir}/caddy-cutover-runbook.md" "不要指向控制节点"
  assert_contains "${tdir}/caddy-cutover-runbook.md" "Host"
  assert_contains "${tdir}/caddy-cutover-runbook.md" "k3s-health.internal"
  assert_contains "${tdir}/file-migration-runbook.md" "最终增量同步"
  assert_contains "${tdir}/file-migration-runbook.md" "单写者"
  assert_contains "${tdir}/file-migration-runbook.md" "新 k3s 服务不能接生产写流量"
  assert_contains "${tdir}/file-migration-runbook.md" "不能直接回切旧文件状态"
  assert_contains "${tdir}/database-cutover-checklist.md" "DDL 冻结"
  assert_contains "${tdir}/database-cutover-checklist.md" "数据库迁移与 Web 切流分开"
  assert_contains "${tdir}/database-cutover-checklist.md" "索引"
  assert_contains "${tdir}/database-cutover-checklist.md" "触发器"
  assert_contains "${tdir}/database-cutover-checklist.md" "函数"
  assert_contains "${tdir}/database-cutover-checklist.md" "视图"
  assert_contains "${tdir}/database-cutover-checklist.md" "账号权限"
  assert_contains "${tdir}/database-cutover-checklist.md" "Caddy 切流计划"
  assert_contains "${tdir}/caddy-cutover-runbook.md" "edge-health"
}
```

- [ ] **Step 2: 实现模板生成函数**

`k3s_ha_write_migration_templates` writes the same content to `$K3S_HA_TEMPLATE_DIR`. Keep each template focused:

- `service-inventory-template.md`: one service per file. Required fields: service name, owner, image, tag, registry, current VPS IP, current port, Caddy domain, current upstream, target k3s namespace, startup command, environment variables, config files, local directory classification, session backend, DB engine/connection target, Redis usage, RabbitMQ usage, health URL, readiness URL, rollback owner and rollback command.
- `caddy-cutover-runbook.md`: add k3s worker upstreams as `http://<worker-ip>:30080`, never point Caddy to the control node, preserve original `Host`, configure active health check with `Host: k3s-health.internal` and `GET /-/edge-health`, configure passive failure removal, use low-weight/single-service cutover, monitor 5xx/latency/login/file writes, rollback by restoring old upstream.
- `file-migration-runbook.md`: initial sync, continuous sync, explicit single-writer rule, new k3s service cannot receive production write traffic before cutover, old VPS drain/read-only, final sync, file count/size/checksum validation, rollback limitation requiring reverse sync or forbidding direct cutback to stale old file state.
- `database-cutover-checklist.md`: database migration and Web cutover in separate windows, seed path, DDL freeze, app read-only/stop-write window, lag threshold, row count, index/constraint/trigger/function/view/account validation, checksums, backup/snapshot record, connection string change record, Caddy cutover plan, promotion, rollback.

- [ ] **Step 3: Copy generated templates into repo docs**

After tests pass, copy template content into committed docs under `docs/k3s-ha/`. Keep these docs identical to generated templates so users can read them without running the script.

Add a consistency test in `run_migration_tests` after repo docs exist:

```bash
cmp -s "${tdir}/service-inventory-template.md" "${ROOT_DIR}/docs/k3s-ha/service-inventory-template.md" || fail "service inventory template drift"
cmp -s "${tdir}/caddy-cutover-runbook.md" "${ROOT_DIR}/docs/k3s-ha/caddy-cutover-runbook.md" || fail "caddy runbook drift"
cmp -s "${tdir}/file-migration-runbook.md" "${ROOT_DIR}/docs/k3s-ha/file-migration-runbook.md" || fail "file migration runbook drift"
cmp -s "${tdir}/database-cutover-checklist.md" "${ROOT_DIR}/docs/k3s-ha/database-cutover-checklist.md" || fail "database checklist drift"
```

- [ ] **Step 4: 运行测试**

Run: `bash tests/test_k3s_ha.sh migration`

Expected: `PASS: migration`

- [ ] **Step 5: 提交**

```bash
git add tests/test_k3s_ha.sh lib/k3s-ha/migration.sh docs/k3s-ha
git commit -m "docs(k3s-ha): 增加服务迁移 runbook"
```

### Task 10: render/apply 总编排

**Files:**
- Modify: `tests/test_k3s_ha.sh`
- Modify: `lib/k3s-ha/main.sh`
- Modify: `lib/k3s-ha/ingress.sh`
- Modify: `lib/k3s-ha/longhorn.sh`
- Modify: `lib/k3s-ha/db-router.sh`
- Modify: `lib/k3s-ha/redis.sh`

- [ ] **Step 1: 写失败测试**

新增 `run_main_tests`：
同时把 `main) run_main_tests ;;` 加入 `main()` case，把 `run_main_tests` 加入 `all` suite。

```bash
run_main_tests() {
  load_k3s_ha
  local tdir; tdir="$(mktemp -d)"; trap "rm -rf '$tdir'" RETURN
  export K3S_HA_MANIFEST_DIR="$tdir"
  export K3S_HA_WORKER1_IP=10.0.0.11 K3S_HA_WORKER2_IP=10.0.0.12

  k3s_ha_render_all

  assert_file_exists "${tdir}/traefik-nodeport.yaml"
  assert_file_exists "${tdir}/edge-health.yaml"
  assert_file_exists "${tdir}/longhorn-storageclass.yaml"
  assert_file_exists "${tdir}/longhorn-recurring-jobs.yaml"
  assert_file_exists "${tdir}/postgres-ha-router.yaml"
  assert_file_exists "${tdir}/mysql-ha-router.yaml"
  assert_file_exists "${tdir}/redis-sentinel.yaml"

  local log="${tdir}/apply.log"
  k3s_ha_kubectl_apply() { printf '%s\n' "$1" >>"$log"; }
  k3s_ha_apply_all
  assert_order "$log" "traefik-nodeport.yaml" "edge-health.yaml"
  assert_order "$log" "edge-health.yaml" "longhorn-storageclass.yaml"
  assert_order "$log" "longhorn-storageclass.yaml" "longhorn-recurring-jobs.yaml"
  assert_order "$log" "longhorn-recurring-jobs.yaml" "postgres-ha-router.yaml"
  assert_order "$log" "postgres-ha-router.yaml" "mysql-ha-router.yaml"
  assert_order "$log" "mysql-ha-router.yaml" "redis-sentinel.yaml"
}
```

- [ ] **Step 2: 实现 render/apply**

`k3s_ha_render_all` calls:

```bash
k3s_ha_render_ingress
k3s_ha_render_longhorn
k3s_ha_render_db_router
k3s_ha_render_redis
```

`k3s_ha_apply_all` applies generated files in explicit dependency order. Each renderer owns any Namespace/ConfigMap resources inside its own YAML file, so apply order is file-level:

1. `traefik-nodeport.yaml`
2. `edge-health.yaml`
3. `longhorn-storageclass.yaml`
4. `longhorn-recurring-jobs.yaml`
5. `postgres-ha-router.yaml`
6. `mysql-ha-router.yaml`
7. `redis-sentinel.yaml`

Do not use `kubectl apply -f "$K3S_HA_MANIFEST_DIR"` blindly because ordering matters. The test must mock `k3s_ha_kubectl_apply` and assert order.

- [ ] **Step 3: 运行测试**

Run: `bash tests/test_k3s_ha.sh main`

Expected: `PASS: main`

- [ ] **Step 4: 提交**

```bash
git add tests/test_k3s_ha.sh lib/k3s-ha
git commit -m "feat(k3s-ha): 增加 manifest 渲染编排"
```

---

## Chunk 4: 文档、验证与发布前检查

### Task 11: README 与远程加载列表

**Files:**
- Modify: `README.md`
- Modify: `install-k3s-ha.sh`
- Modify: `tests/test_k3s_ha.sh`

- [ ] **Step 1: 写 README 断言**

在 `tests/test_k3s_ha.sh` 增加 `run_docs_tests`，并把 `docs) run_docs_tests ;;` 加入 `main()` case，把 `run_docs_tests` 加入 `all` suite：

```bash
run_docs_tests() {
  assert_contains "${ROOT_DIR}/README.md" "k3s 高可用服务整合"
  assert_contains "${ROOT_DIR}/README.md" "install-k3s-ha.sh"
  assert_contains "${ROOT_DIR}/README.md" "30080"
  assert_contains "${ROOT_DIR}/README.md" "30443"
  assert_contains "${ROOT_DIR}/README.md" "6443"
  assert_contains "${ROOT_DIR}/README.md" "8472/udp"
  assert_contains "${ROOT_DIR}/README.md" "Redis Sentinel"
  assert_contains "${ROOT_DIR}/README.md" "Longhorn"
  assert_contains "${ROOT_DIR}/README.md" "postgres-ha"
  assert_contains "${ROOT_DIR}/README.md" "mysql-ha"
  assert_contains "${ROOT_DIR}/README.md" "edge-health"
  assert_contains "${ROOT_DIR}/README.md" "docs/k3s-ha/"

  local entry="${ROOT_DIR}/install-k3s-ha.sh"
  assert_order "$entry" "lib/common.sh" "lib/k3s-ha/config.sh"
  assert_order "$entry" "lib/k3s-ha/config.sh" "lib/k3s-ha/common.sh"
  assert_order "$entry" "lib/k3s-ha/common.sh" "lib/k3s-ha/install.sh"
  assert_order "$entry" "lib/k3s-ha/install.sh" "lib/k3s-ha/ingress.sh"
  assert_order "$entry" "lib/k3s-ha/ingress.sh" "lib/k3s-ha/longhorn.sh"
  assert_order "$entry" "lib/k3s-ha/longhorn.sh" "lib/k3s-ha/db-router.sh"
  assert_order "$entry" "lib/k3s-ha/db-router.sh" "lib/k3s-ha/redis.sh"
  assert_order "$entry" "lib/k3s-ha/redis.sh" "lib/k3s-ha/migration.sh"
  assert_order "$entry" "lib/k3s-ha/migration.sh" "lib/k3s-ha/main.sh"
}
```

- [ ] **Step 2: 更新 README**

增加章节：

- 一键入口命令。
- 节点角色：server、worker、addons。
- 关键端口：`6443`、`10250`、`8472/udp`、`30080`、`30443`、Longhorn、数据库 HA 端口、Redis Sentinel。
- v1 边界：Caddy 入口单点、RabbitMQ 不纳入核心、数据库裸机 HA。
- 迁移准入：Redis session、Longhorn PVC、数据库 router、Caddy health check。
- 提醒：`install-k3s-ha.sh install` 会改动目标机器；开发验证使用 `render`、`templates` 和测试，不在本地开发机执行安装。
- 链接 `docs/k3s-ha/` 下的服务盘点、Caddy 切流、文件迁移、数据库切换、备份恢复 runbook。

- [ ] **Step 3: 确认远程加载列表完整**

`install-k3s-ha.sh` 的 `load_linuxshell_modules` 必须包含新增模块，并由 `run_docs_tests` 用 `assert_order` 验证完整顺序：

```text
lib/common.sh
lib/k3s-ha/config.sh
lib/k3s-ha/common.sh
lib/k3s-ha/install.sh
lib/k3s-ha/ingress.sh
lib/k3s-ha/longhorn.sh
lib/k3s-ha/db-router.sh
lib/k3s-ha/redis.sh
lib/k3s-ha/migration.sh
lib/k3s-ha/main.sh
```

- [ ] **Step 4: 运行文档测试**

Run: `bash tests/test_k3s_ha.sh docs`

Expected: `PASS: docs`

- [ ] **Step 5: 提交**

```bash
git add README.md install-k3s-ha.sh tests/test_k3s_ha.sh
git commit -m "docs(k3s-ha): 增加使用说明"
```

### Task 12: 全量验证

**Files:**
- Modify: no production files unless verification finds an issue.

- [ ] **Step 1: shell 语法检查**

Run:

```bash
find . -name '*.sh' -type f -not -path './.git/*' -print0 | xargs -0 -n1 bash -n
```

Expected: exit 0, no syntax errors.

- [ ] **Step 2: k3s-ha 测试**

Run: `bash tests/test_k3s_ha.sh all`

Expected: `PASS: all`

- [ ] **Step 3: 入口加载相关测试**

Run:

```bash
bash tests/test_firewall.sh
bash tests/test_deploy.sh
bash tests/test_db_tenant.sh
bash tests/test_pg_ha.sh
bash tests/test_mysql_ha.sh
```

Expected: all print `PASS`.

- [ ] **Step 4: git 状态检查**

Run: `git status --short`

Expected: only intentional tracked changes are present; `.superpowers/` remains untracked companion scratch if still present.

- [ ] **Step 5: 最终提交**

If verification changes nothing:

```bash
git status --short
```

If verification required fixes:

```bash
git add <fixed-files>
git commit -m "fix(k3s-ha): 修复验证发现的问题"
```

---

## Execution Notes

- Do not run `install-k3s-ha.sh install` on the local development machine unless explicitly targeting a disposable server.
- All tests must mock `kubectl`, `curl`, `systemctl`, package installation, and any command that would alter host state.
- Use `mktemp -d` or `K3S_HA_MANIFEST_DIR` overrides for generated files.
- Do not store real passwords, tokens, registry credentials or server secrets in tests or docs.
- Keep RabbitMQ outside v1 core. Services depending on critical RabbitMQ queues require a separate HA spec before being marked automatically recoverable.
- Before implementation begins, use `superpowers:subagent-driven-development`; split workers by chunk so write scopes do not overlap.
