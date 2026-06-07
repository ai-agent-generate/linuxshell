# 数据库多租户管理脚本 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 MySQL / PostgreSQL 提供一个菜单驱动的多租户管理工具，能「一库一角色」地创建租户、施加账号级资源限制、并安全地备份后删除。

**Architecture:** 单入口 `db-tenant.sh` + `lib/db-tenant/` 模块（config / common / pg / mysql / main）。引擎差异封装在统一前缀（`pg_` / `mysql_`）的动词函数后；SQL 全部由**纯函数 builder** 产出以便无 DB 单元测试；自动探测 docker/local 连接；删除前强制「备份→完整性校验→二次确认」。

**Tech Stack:** Bash（保持 bash 3.2 兼容，测试在 macOS 上运行）、`psql` / `pg_dump` / `pg_restore`、`mysql` / `mysqldump` / `gzip`、Docker（`docker exec` / `docker cp`）。所有外部命令在测试中 mock，零副作用。

**重要约束（务必遵守）：**
- 所有脚本 `#!/usr/bin/env bash`；入口与 `tests/*.sh` 带可执行位。模块被 `source`，函数内不写 `set -euo pipefail`（入口已设）。
- 禁用 bash 4+ 特性（关联数组、`mapfile`、`${x^^}`）。大小写转换用 `to_lower`（来自 `lib/common.sh`）。
- 标识符在编排层先经 `db_tenant_validate_identifier` 白名单校验，才允许拼进 SQL。
- 测试中**不**连真实 DB、不写真实 `/data`、不装包；备份目录用 `mktemp -d` 覆盖 `DB_TENANT_BACKUP_DIR`。
- 设计依据：`docs/superpowers/specs/2026-06-07-db-tenant-manager-design.md`。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `lib/db-tenant/config.sh` | 默认配置，全部 `${VAR:-default}`，可环境变量覆盖 |
| `lib/db-tenant/common.sh` | 跨引擎：标识符校验、denylist、密码生成/转义、备份目录预检、备份路径、备份完整性校验、flock |
| `lib/db-tenant/pg.sh` | PG 后端：SQL builder（纯函数）+ 探测/exec/只读检测/守卫/备份/各动作 |
| `lib/db-tenant/mysql.sh` | MySQL 后端：同上 |
| `lib/db-tenant/main.sh` | 引擎选择 + 动作菜单 + 分发（`db_tenant_main`） |
| `db-tenant.sh` | 入口：内联 `load_linuxshell_modules`（同 `install-mysql-ha.sh`）+ 调 `db_tenant_main` |
| `tests/test_db_tenant.sh` | 语法/加载/SQL 生成/校验/denylist/备份安全/README/可执行位 |
| `README.md` | 增补「数据库多租户管理」章节 |

加载顺序（入口与测试一致）：`lib/common.sh → lib/db-tenant/config.sh → lib/db-tenant/common.sh → lib/db-tenant/pg.sh → lib/db-tenant/mysql.sh → lib/db-tenant/main.sh`。

---

## Task 1: 脚手架（测试骨架 + config.sh + 模块桩 + 入口）

**Files:**
- Create: `tests/test_db_tenant.sh`
- Create: `lib/db-tenant/config.sh`
- Create: `lib/db-tenant/common.sh`（桩）、`lib/db-tenant/pg.sh`（桩）、`lib/db-tenant/mysql.sh`（桩）、`lib/db-tenant/main.sh`（桩）
- Create: `db-tenant.sh`

- [ ] **Step 1: 写测试骨架与前两个 suite（先失败）**

创建 `tests/test_db_tenant.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file_exists() { [[ -f "$1" ]] || fail "expected file: $1"; }
assert_function_exists() { declare -F "$1" >/dev/null || fail "expected function: $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"; }
assert_not_contains() { if grep -Fq -- "$2" "$1"; then fail "did not expect '$2' in $1"; fi; }
assert_str_contains() { case "$1" in *"$2"*) :;; *) fail "expected substring '$2' in: $1";; esac; }
assert_str_missing() { case "$1" in *"$2"*) fail "did not expect substring '$2' in: $1";; *) :;; esac; }
assert_equals() { [[ "$1" == "$2" ]] || fail "expected '$1' but got '$2'"; }
assert_mode() {
  local m; m="$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null)"
  [[ "$m" == "$2" ]] || fail "expected mode $2 on $1 but got $m"
}

load_db_tenant() {
  # shellcheck disable=SC1090,SC1091
  source "${ROOT_DIR}/lib/common.sh"
  source "${ROOT_DIR}/lib/db-tenant/config.sh"
  source "${ROOT_DIR}/lib/db-tenant/common.sh"
  source "${ROOT_DIR}/lib/db-tenant/pg.sh"
  source "${ROOT_DIR}/lib/db-tenant/mysql.sh"
  source "${ROOT_DIR}/lib/db-tenant/main.sh"
}

run_skeleton_tests() {
  local entry="${ROOT_DIR}/db-tenant.sh"
  assert_file_exists "$entry"
  [[ -x "$entry" ]] || fail "expected db-tenant.sh executable"
  [[ -x "${ROOT_DIR}/tests/test_db_tenant.sh" ]] || fail "expected tests/test_db_tenant.sh executable"
  bash -n "$entry" || fail "db-tenant.sh syntax error"
  assert_contains "$entry" "lib/common.sh"
  assert_contains "$entry" "lib/db-tenant/config.sh"
  assert_contains "$entry" "lib/db-tenant/common.sh"
  assert_contains "$entry" "lib/db-tenant/pg.sh"
  assert_contains "$entry" "lib/db-tenant/mysql.sh"
  assert_contains "$entry" "lib/db-tenant/main.sh"
  assert_not_contains "$entry" "lib/config.sh"
  local m
  while IFS= read -r m; do bash -n "$m" || fail "syntax error: $m"; done \
    < <(find "${ROOT_DIR}/lib/db-tenant" -name '*.sh' -type f | sort)
  load_db_tenant
}

run_config_tests() {
  ( unset DATA_ROOT DB_TENANT_BACKUP_DIR DB_TENANT_PG_CONN_LIMIT DB_TENANT_PG_IDLE_TX_TIMEOUT
    source "${ROOT_DIR}/lib/db-tenant/config.sh"
    assert_equals "postgres" "${DB_TENANT_PG_CONTAINER}"
    assert_equals "mysql" "${DB_TENANT_MYSQL_CONTAINER}"
    assert_equals "/var/backups/db-tenant" "${DB_TENANT_BACKUP_DIR}"
    assert_equals "20" "${DB_TENANT_PG_CONN_LIMIT}"
    assert_equals "30s" "${DB_TENANT_PG_STATEMENT_TIMEOUT}"
    assert_equals "300s" "${DB_TENANT_PG_IDLE_TX_TIMEOUT}"
    assert_equals "20" "${DB_TENANT_MYSQL_MAX_USER_CONN}"
    assert_equals "0" "${DB_TENANT_MYSQL_MAX_QUERIES_PER_HOUR}"
    assert_equals "%" "${DB_TENANT_MYSQL_DEFAULT_HOST}"
    assert_str_contains "${DB_TENANT_MYSQL_SYSTEM_DATABASES}" "replication_manager_schema" )
  ( export DB_TENANT_BACKUP_DIR="/opt/bk" DB_TENANT_PG_CONN_LIMIT="99"
    source "${ROOT_DIR}/lib/db-tenant/config.sh"
    assert_equals "/opt/bk" "${DB_TENANT_BACKUP_DIR}"
    assert_equals "99" "${DB_TENANT_PG_CONN_LIMIT}" )
}

main() {
  local suite="${1:-all}"
  case "$suite" in
    skeleton) run_skeleton_tests ;;
    config) run_config_tests ;;
    all) run_skeleton_tests; run_config_tests ;;
    *) fail "unknown suite: $suite" ;;
  esac
  echo "PASS: ${suite}"
}

main "$@"
```

- [ ] **Step 2: 运行，确认失败**

Run: `chmod +x tests/test_db_tenant.sh && bash tests/test_db_tenant.sh config`
Expected: FAIL（`lib/db-tenant/config.sh` 不存在）

- [ ] **Step 3: 创建 config.sh（真实）与四个模块桩、入口**

`lib/db-tenant/config.sh`：

```bash
#!/usr/bin/env bash
# lib/db-tenant/config.sh — 数据库多租户管理工具默认配置(可被环境变量覆盖)

DATA_ROOT="${DATA_ROOT:-/data}"

DB_TENANT_PG_CONTAINER="${DB_TENANT_PG_CONTAINER:-postgres}"
DB_TENANT_MYSQL_CONTAINER="${DB_TENANT_MYSQL_CONTAINER:-mysql}"
DB_TENANT_FORCE_TARGET="${DB_TENANT_FORCE_TARGET:-}"

DB_TENANT_MYSQL_ADMIN_USER="${DB_TENANT_MYSQL_ADMIN_USER:-root}"
DB_TENANT_MYSQL_ADMIN_PASSWORD="${DB_TENANT_MYSQL_ADMIN_PASSWORD:-}"
DB_TENANT_MYSQL_SOCKET="${DB_TENANT_MYSQL_SOCKET:-/var/run/mysqld/mysqld.sock}"

DB_TENANT_BACKUP_DIR="${DB_TENANT_BACKUP_DIR:-/var/backups/db-tenant}"
DB_TENANT_BACKUP_MIN_FREE_MB="${DB_TENANT_BACKUP_MIN_FREE_MB:-512}"

DB_TENANT_PG_CONN_LIMIT="${DB_TENANT_PG_CONN_LIMIT:-20}"
DB_TENANT_PG_DB_CONN_LIMIT="${DB_TENANT_PG_DB_CONN_LIMIT:-20}"
DB_TENANT_PG_STATEMENT_TIMEOUT="${DB_TENANT_PG_STATEMENT_TIMEOUT:-30s}"
DB_TENANT_PG_IDLE_TX_TIMEOUT="${DB_TENANT_PG_IDLE_TX_TIMEOUT:-300s}"
DB_TENANT_PG_WORK_MEM="${DB_TENANT_PG_WORK_MEM:-16MB}"

DB_TENANT_MYSQL_MAX_USER_CONN="${DB_TENANT_MYSQL_MAX_USER_CONN:-20}"
DB_TENANT_MYSQL_MAX_CONN_PER_HOUR="${DB_TENANT_MYSQL_MAX_CONN_PER_HOUR:-0}"
DB_TENANT_MYSQL_MAX_QUERIES_PER_HOUR="${DB_TENANT_MYSQL_MAX_QUERIES_PER_HOUR:-0}"
DB_TENANT_MYSQL_MAX_UPDATES_PER_HOUR="${DB_TENANT_MYSQL_MAX_UPDATES_PER_HOUR:-0}"
DB_TENANT_MYSQL_DEFAULT_HOST="${DB_TENANT_MYSQL_DEFAULT_HOST:-%}"

DB_TENANT_PG_SYSTEM_NAMES="${DB_TENANT_PG_SYSTEM_NAMES:-postgres template0 template1}"
DB_TENANT_MYSQL_SYSTEM_USERS="${DB_TENANT_MYSQL_SYSTEM_USERS:-root mysql.sys mysql.session mysql.infoschema sys debian-sys-maint repl mysqlchk repman}"
DB_TENANT_MYSQL_SYSTEM_DATABASES="${DB_TENANT_MYSQL_SYSTEM_DATABASES:-mysql information_schema performance_schema sys replication_manager_schema}"
```

四个桩文件，内容仅头部（后续任务填充）：

`lib/db-tenant/common.sh`：
```bash
#!/usr/bin/env bash
# lib/db-tenant/common.sh — 跨引擎公共函数
```
`lib/db-tenant/pg.sh`：
```bash
#!/usr/bin/env bash
# lib/db-tenant/pg.sh — PostgreSQL 后端
```
`lib/db-tenant/mysql.sh`：
```bash
#!/usr/bin/env bash
# lib/db-tenant/mysql.sh — MySQL 后端
```
`lib/db-tenant/main.sh`：
```bash
#!/usr/bin/env bash
# lib/db-tenant/main.sh — 引擎选择与动作菜单
db_tenant_main() { echo "db-tenant (stub)"; }
```

入口 `db-tenant.sh`（内联 loader，照搬 `install-mysql-ha.sh` 结构）：
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

  if [[ -f "${module_root}/lib/db-tenant/config.sh" ]]; then
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
  lib/db-tenant/config.sh \
  lib/db-tenant/common.sh \
  lib/db-tenant/pg.sh \
  lib/db-tenant/mysql.sh \
  lib/db-tenant/main.sh

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  db_tenant_main "$@"
fi
```

- [ ] **Step 4: 运行 config 与 skeleton，确认通过**

Run: `chmod +x db-tenant.sh && bash tests/test_db_tenant.sh config && bash tests/test_db_tenant.sh skeleton`
Expected: `PASS: config` 与 `PASS: skeleton`

- [ ] **Step 5: 提交**

```bash
chmod +x db-tenant.sh tests/test_db_tenant.sh
git add db-tenant.sh lib/db-tenant/ tests/test_db_tenant.sh
git commit -m "feat(db-tenant): 脚手架(入口/config/模块桩/测试骨架)"
```

---

## Task 2: common.sh — 标识符校验 / denylist / 密码生成 / 转义

**Files:**
- Modify: `lib/db-tenant/common.sh`
- Modify: `tests/test_db_tenant.sh`

- [ ] **Step 1: 加 run_common_tests（先失败）**

在 `tests/test_db_tenant.sh` 的 `run_config_tests` 之后插入：

```bash
run_common_tests() {
  load_db_tenant
  assert_function_exists db_tenant_validate_identifier
  assert_function_exists db_tenant_is_system_name
  assert_function_exists db_tenant_generate_password
  assert_function_exists db_tenant_sql_escape_literal

  db_tenant_validate_identifier "acme" || fail "acme should be valid"
  db_tenant_validate_identifier "acme_1" || fail "acme_1 should be valid"
  if db_tenant_validate_identifier "1abc" 2>/dev/null; then fail "1abc must be rejected"; fi
  if db_tenant_validate_identifier "a-b" 2>/dev/null; then fail "a-b must be rejected"; fi
  if db_tenant_validate_identifier "a;b" 2>/dev/null; then fail "a;b must be rejected"; fi
  if db_tenant_validate_identifier "a'b" 2>/dev/null; then fail "quote must be rejected"; fi
  if db_tenant_validate_identifier "" 2>/dev/null; then fail "empty must be rejected"; fi

  db_tenant_is_system_name "postgres" "${DB_TENANT_PG_SYSTEM_NAMES}" || fail "postgres is system"
  db_tenant_is_system_name "mysql.session" "${DB_TENANT_MYSQL_SYSTEM_USERS}" || fail "mysql.session is system"
  db_tenant_is_system_name "debian-sys-maint" "${DB_TENANT_MYSQL_SYSTEM_USERS}" || fail "debian-sys-maint is system"
  db_tenant_is_system_name "repman" "${DB_TENANT_MYSQL_SYSTEM_USERS}" || fail "repman is system"
  db_tenant_is_system_name "replication_manager_schema" "${DB_TENANT_MYSQL_SYSTEM_DATABASES}" || fail "rms is system db"
  if db_tenant_is_system_name "acme" "${DB_TENANT_PG_SYSTEM_NAMES}"; then fail "acme is not system"; fi

  local pw; pw="$(db_tenant_generate_password)"
  [[ "$pw" =~ ^[A-Za-z0-9]+$ ]] || fail "password must be alphanumeric: $pw"
  assert_equals "25" "${#pw}"

  assert_equals "a''b" "$(db_tenant_sql_escape_literal pg "a'b")"
  assert_equals "a\\\\''b" "$(db_tenant_sql_escape_literal mysql "a\\'b")"
}
```

并把 `main` 的 case 与 `all` 加上 `common`：
```bash
    common) run_common_tests ;;
```
`all)` 行改为：`run_skeleton_tests; run_config_tests; run_common_tests`

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_db_tenant.sh common`
Expected: FAIL（函数不存在）

- [ ] **Step 3: 实现这些函数**

把以下内容追加到 `lib/db-tenant/common.sh`：

```bash
# 标识符白名单:小写字母开头,仅 [a-z0-9_],长度 1..max(默认63)
db_tenant_validate_identifier() {
  local name="$1" max="${2:-63}"
  if [[ -z "$name" ]]; then echo "标识符不能为空" >&2; return 1; fi
  if (( ${#name} > max )); then echo "标识符过长(>${max}): $name" >&2; return 1; fi
  if [[ ! "$name" =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "非法标识符(只允许小写字母开头、[a-z0-9_]): $name" >&2; return 1
  fi
  return 0
}

# $1=name $2=空格分隔名单 -> 命中返回0
db_tenant_is_system_name() {
  local name="$1" list="$2" item
  for item in $list; do
    [[ "$name" == "$item" ]] && return 0
  done
  return 1
}

# 25 位纯字母数字密码(规避一切 SQL/cnf 转义),与 mysql_ha_generate_password 同源
db_tenant_generate_password() {
  openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 25
}

# 按引擎转义 SQL 单引号字符串字面量。$1=pg|mysql $2=raw
db_tenant_sql_escape_literal() {
  local engine="$1" raw="$2"
  if [[ "$engine" == "mysql" ]]; then
    raw="${raw//\\/\\\\}"
  fi
  raw="${raw//\'/\'\'}"
  printf '%s' "$raw"
}
```

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/test_db_tenant.sh common`
Expected: `PASS: common`

- [ ] **Step 5: 提交**

```bash
git add lib/db-tenant/common.sh tests/test_db_tenant.sh
git commit -m "feat(db-tenant): 标识符校验/denylist/密码生成与转义"
```

---

## Task 3: common.sh — 备份目录预检 / 备份路径 / 完整性校验 / flock

**Files:**
- Modify: `lib/db-tenant/common.sh`
- Modify: `tests/test_db_tenant.sh`

- [ ] **Step 1: 加 run_backup_helper_tests（先失败）**

在 `tests/test_db_tenant.sh` 插入：

```bash
run_backup_helper_tests() {
  load_db_tenant
  assert_function_exists db_tenant_prepare_backup_dir
  assert_function_exists db_tenant_backup_path
  assert_function_exists db_tenant_verify_backup
  assert_function_exists db_tenant_with_lock

  local tmp; tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" RETURN

  ( export DB_TENANT_BACKUP_DIR="${tmp}/bk" DB_TENANT_BACKUP_MIN_FREE_MB="1"
    source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/db-tenant/common.sh"
    db_tenant_prepare_backup_dir || fail "prepare should succeed"
    assert_mode "${tmp}/bk" "700"
    local p; p="$(db_tenant_backup_path pg acme dump)"
    assert_str_contains "$p" "${tmp}/bk/pg-acme-"
    assert_str_contains "$p" ".dump" )

  # 不可能满足的最小空间 -> 预检失败
  ( export DB_TENANT_BACKUP_DIR="${tmp}/bk2" DB_TENANT_BACKUP_MIN_FREE_MB="999999999"
    source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/db-tenant/common.sh"
    if db_tenant_prepare_backup_dir 2>/dev/null; then fail "should fail on insufficient space"; fi )

  # verify: 空文件失败
  : >"${tmp}/empty.dump"
  if db_tenant_verify_backup pg "${tmp}/empty.dump" 2>/dev/null; then fail "empty file must fail verify"; fi

  # verify mysql: 损坏 gzip 失败 / 合法 gzip+完成标记 通过
  printf 'not gzip' >"${tmp}/bad.sql.gz"
  if db_tenant_verify_backup mysql "${tmp}/bad.sql.gz" 2>/dev/null; then fail "bad gzip must fail"; fi
  printf '%s\n' "-- dummy" "-- Dump completed on 2026-06-07" | gzip >"${tmp}/ok.sql.gz"
  db_tenant_verify_backup mysql "${tmp}/ok.sql.gz" || fail "valid mysql backup must pass"

  # verify pg: mock pg_restore 成功/失败
  ( source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"; source "${ROOT_DIR}/lib/db-tenant/common.sh"
    printf 'x' >"${tmp}/a.dump"
    pg_restore() { return 0; }
    db_tenant_verify_backup pg "${tmp}/a.dump" || fail "pg verify should pass when pg_restore ok"
    pg_restore() { return 1; }
    if db_tenant_verify_backup pg "${tmp}/a.dump" 2>/dev/null; then fail "pg verify should fail when pg_restore fails"; fi )
}
```

`main` 增加 `backup_helper) run_backup_helper_tests ;;`，并加入 `all`。

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_db_tenant.sh backup_helper`
Expected: FAIL（函数不存在）

- [ ] **Step 3: 实现**

追加到 `lib/db-tenant/common.sh`：

```bash
# 准备备份目录(700)并做磁盘可用空间预检
db_tenant_prepare_backup_dir() {
  local dir="${DB_TENANT_BACKUP_DIR}" min_mb="${DB_TENANT_BACKUP_MIN_FREE_MB}"
  mkdir -p "$dir" || { echo "无法创建备份目录: $dir" >&2; return 1; }
  chmod 700 "$dir"
  local free_mb
  free_mb="$(df -Pm "$dir" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -n "$free_mb" ]] && (( free_mb < min_mb )); then
    echo "备份目录可用空间不足: ${free_mb}MB < ${min_mb}MB ($dir)" >&2
    return 1
  fi
  return 0
}

# 备份文件路径(时间戳+PID,防同秒覆盖)。$1=engine $2=db $3=ext
db_tenant_backup_path() {
  printf '%s/%s-%s-%s-%s.%s' \
    "${DB_TENANT_BACKUP_DIR}" "$1" "$2" "$(date +%Y%m%d-%H%M%S)" "$$" "$3"
}

# 备份完整性校验。$1=pg|mysql $2=file -> 0 完整
db_tenant_verify_backup() {
  local engine="$1" file="$2"
  if [[ ! -s "$file" ]]; then echo "备份文件为空: $file" >&2; return 1; fi
  if [[ "$engine" == "pg" ]]; then
    pg_restore -l "$file" >/dev/null 2>&1 || { echo "pg_restore 校验失败: $file" >&2; return 1; }
  else
    gzip -t "$file" >/dev/null 2>&1 || { echo "gzip 校验失败: $file" >&2; return 1; }
    if ! zcat "$file" 2>/dev/null | tail -n 5 | grep -q 'Dump completed'; then
      echo "未发现 mysqldump 完成标记: $file" >&2; return 1
    fi
  fi
  return 0
}

# 写操作串行化锁(flock 不可用时降级直跑)。用法: db_tenant_with_lock <cmd...>
db_tenant_with_lock() {
  if ! command_exists flock; then "$@"; return $?; fi
  mkdir -p "${DB_TENANT_BACKUP_DIR}"
  local lock="${DB_TENANT_BACKUP_DIR}/.db-tenant.lock"
  exec 9>"$lock"
  if ! flock -n 9; then echo "另一个 db-tenant 操作正在进行,请稍后重试。" >&2; return 1; fi
  "$@"
  local rc=$?
  flock -u 9
  return $rc
}
```

> 注：macOS 无 `flock`/`zcat`？`zcat` 在 macOS 可用（等价 `gzip -dc`）；若目标环境缺 `zcat`，实现可改 `gzip -dc`。本计划用 `zcat`，Linux 服务器与 macOS 均可。

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/test_db_tenant.sh backup_helper`
Expected: `PASS: backup_helper`

- [ ] **Step 5: 提交**

```bash
git add lib/db-tenant/common.sh tests/test_db_tenant.sh
git commit -m "feat(db-tenant): 备份目录预检/路径/完整性校验/flock"
```

---

## Task 4: pg.sh — SQL builders（纯函数）

**Files:**
- Modify: `lib/db-tenant/pg.sh`
- Modify: `tests/test_db_tenant.sh`

- [ ] **Step 1: 加 run_pg_sql_tests（先失败）**

```bash
run_pg_sql_tests() {
  load_db_tenant
  assert_function_exists pg_build_create_tenant_sql
  assert_function_exists pg_build_set_limit_sql
  assert_function_exists pg_build_set_password_sql
  assert_function_exists pg_build_drop_sql
  assert_function_exists pg_build_list_sql

  local sql
  # 新建:role 不存在、db 不存在、db 新建
  sql="$(pg_build_create_tenant_sql acme acme PWD 20 20 30s 300s 16MB 0 0 1)"
  assert_str_contains "$sql" "CREATE ROLE \"acme\" LOGIN PASSWORD 'PWD' CONNECTION LIMIT 20;"
  assert_str_contains "$sql" "CREATE DATABASE \"acme\" OWNER \"acme\" CONNECTION LIMIT 20;"
  assert_str_contains "$sql" "REVOKE CONNECT ON DATABASE \"acme\" FROM PUBLIC;"
  assert_str_contains "$sql" "ALTER ROLE \"acme\" IN DATABASE \"acme\" SET statement_timeout = '30s';"
  assert_str_contains "$sql" "SET idle_in_transaction_session_timeout = '300s';"
  assert_str_contains "$sql" "SET work_mem = '16MB';"
  assert_str_missing "$sql" "BEGIN;"
  assert_str_missing "$sql" "COMMIT;"
  # 已存在:role 存在、db 存在 -> ALTER 分支,且不重复 REVOKE PUBLIC
  sql="$(pg_build_create_tenant_sql acme acme PWD 20 20 30s 300s 16MB 1 1 0)"
  assert_str_contains "$sql" "ALTER ROLE \"acme\" CONNECTION LIMIT 20;"
  assert_str_contains "$sql" "ALTER DATABASE \"acme\" OWNER TO \"acme\";"
  assert_str_missing "$sql" "CREATE DATABASE"
  assert_str_missing "$sql" "FROM PUBLIC;"

  sql="$(pg_build_set_limit_sql acme acme 30 30 10s 120s 32MB)"
  assert_str_contains "$sql" "ALTER ROLE \"acme\" CONNECTION LIMIT 30;"
  assert_str_contains "$sql" "ALTER DATABASE \"acme\" CONNECTION LIMIT 30;"
  assert_str_contains "$sql" "SET work_mem = '32MB';"

  sql="$(pg_build_set_password_sql acme NEWPW)"
  assert_str_contains "$sql" "ALTER ROLE \"acme\" PASSWORD 'NEWPW';"

  # drop:force=1, role/db 均存在
  sql="$(pg_build_drop_sql acme acme 1 1 1)"
  assert_str_contains "$sql" "pg_terminate_backend(pid)"
  assert_str_contains "$sql" "DROP DATABASE IF EXISTS \"acme\" WITH (FORCE);"
  assert_str_contains "$sql" "DROP OWNED BY \"acme\";"
  assert_str_contains "$sql" "DROP ROLE IF EXISTS \"acme\";"
  # drop:force=0 -> 无 FORCE
  sql="$(pg_build_drop_sql acme acme 0 1 1)"
  assert_str_contains "$sql" "DROP DATABASE IF EXISTS \"acme\";"
  assert_str_missing "$sql" "WITH (FORCE)"

  sql="$(pg_build_list_sql)"
  assert_str_contains "$sql" "pg_database"
  assert_str_contains "$sql" "pg_is_in_recovery" # 不要求;占位,见下方说明
}
```

> 说明：`pg_build_list_sql` 不含 `pg_is_in_recovery`，请将该行改为断言真正包含的列，例如：
> `assert_str_contains "$sql" "rolconnlimit"`。（实现见 Step 3。）

`main` 增加 `pg_sql) run_pg_sql_tests ;;` 并加入 `all`。

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_db_tenant.sh pg_sql`
Expected: FAIL（函数不存在）

- [ ] **Step 3: 实现 builders**

追加到 `lib/db-tenant/pg.sh`：

```bash
# 建租户 SQL。参数:
# 1=role 2=db 3=pw(已转义) 4=role_conn 5=db_conn 6=stmt_to 7=idle_to 8=work_mem
# 9=role_exists(0/1) 10=db_exists(0/1) 11=db_newly_created(0/1)
pg_build_create_tenant_sql() {
  local role="$1" db="$2" pw="$3" rconn="$4" dconn="$5" stmt="$6" idle="$7" wmem="$8"
  local role_exists="$9" db_exists="${10}" db_new="${11}"
  if [[ "$role_exists" == "1" ]]; then
    printf 'ALTER ROLE "%s" CONNECTION LIMIT %s;\n' "$role" "$rconn"
  else
    printf 'CREATE ROLE "%s" LOGIN PASSWORD '\''%s'\'' CONNECTION LIMIT %s;\n' "$role" "$pw" "$rconn"
  fi
  if [[ "$db_exists" == "1" ]]; then
    printf 'ALTER DATABASE "%s" OWNER TO "%s";\n' "$db" "$role"
    printf 'ALTER DATABASE "%s" CONNECTION LIMIT %s;\n' "$db" "$dconn"
  else
    printf 'CREATE DATABASE "%s" OWNER "%s" CONNECTION LIMIT %s;\n' "$db" "$role" "$dconn"
  fi
  if [[ "$db_new" == "1" ]]; then
    printf 'REVOKE CONNECT ON DATABASE "%s" FROM PUBLIC;\n' "$db"
    printf 'GRANT CONNECT ON DATABASE "%s" TO "%s";\n' "$db" "$role"
  fi
  printf 'ALTER ROLE "%s" IN DATABASE "%s" SET statement_timeout = '\''%s'\'';\n' "$role" "$db" "$stmt"
  printf 'ALTER ROLE "%s" IN DATABASE "%s" SET idle_in_transaction_session_timeout = '\''%s'\'';\n' "$role" "$db" "$idle"
  printf 'ALTER ROLE "%s" IN DATABASE "%s" SET work_mem = '\''%s'\'';\n' "$role" "$db" "$wmem"
}

# 改限额。1=role 2=db 3=rconn 4=dconn 5=stmt 6=idle 7=wmem
pg_build_set_limit_sql() {
  printf 'ALTER ROLE "%s" CONNECTION LIMIT %s;\n' "$1" "$3"
  printf 'ALTER DATABASE "%s" CONNECTION LIMIT %s;\n' "$2" "$4"
  printf 'ALTER ROLE "%s" IN DATABASE "%s" SET statement_timeout = '\''%s'\'';\n' "$1" "$2" "$5"
  printf 'ALTER ROLE "%s" IN DATABASE "%s" SET idle_in_transaction_session_timeout = '\''%s'\'';\n' "$1" "$2" "$6"
  printf 'ALTER ROLE "%s" IN DATABASE "%s" SET work_mem = '\''%s'\'';\n' "$1" "$2" "$7"
}

# 改密码。1=role 2=pw(已转义)
pg_build_set_password_sql() {
  printf 'ALTER ROLE "%s" PASSWORD '\''%s'\'';\n' "$1" "$2"
}

# 删除。1=role 2=db 3=force(0/1) 4=role_exists 5=db_exists
pg_build_drop_sql() {
  local role="$1" db="$2" force="$3" role_exists="$4" db_exists="$5"
  if [[ "$db_exists" == "1" ]]; then
    printf 'SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '\''%s'\'' AND pid <> pg_backend_pid();\n' "$db"
    if [[ "$force" == "1" ]]; then
      printf 'DROP DATABASE IF EXISTS "%s" WITH (FORCE);\n' "$db"
    else
      printf 'DROP DATABASE IF EXISTS "%s";\n' "$db"
    fi
  fi
  if [[ "$role_exists" == "1" ]]; then
    printf 'DROP OWNED BY "%s";\n' "$role"
    printf 'DROP ROLE IF EXISTS "%s";\n' "$role"
  fi
}

# 列出租户(库 owner 为非超级用户)。LEFT JOIN 暴露孤儿
pg_build_list_sql() {
  cat <<'SQL'
SELECT d.datname AS db, COALESCE(r.rolname,'<no-owner>') AS role,
       COALESCE(r.rolconnlimit::text,'-') AS role_conn_limit,
       d.datconnlimit AS db_conn_limit
FROM pg_database d
LEFT JOIN pg_roles r ON d.datdba = r.oid
WHERE d.datname NOT IN ('postgres','template0','template1')
  AND (r.rolsuper IS DISTINCT FROM true)
ORDER BY d.datname;
SQL
}
```

修正 Step 1 里那条占位断言为：
```bash
  assert_str_contains "$sql" "rolconnlimit"
```

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/test_db_tenant.sh pg_sql`
Expected: `PASS: pg_sql`

- [ ] **Step 5: 提交**

```bash
git add lib/db-tenant/pg.sh tests/test_db_tenant.sh
git commit -m "feat(db-tenant): PG SQL builders(建/改限额/改密码/删除/列出)"
```

---

## Task 5: mysql.sh — SQL builders（纯函数）

**Files:**
- Modify: `lib/db-tenant/mysql.sh`
- Modify: `tests/test_db_tenant.sh`

- [ ] **Step 1: 加 run_mysql_sql_tests（先失败）**

```bash
run_mysql_sql_tests() {
  load_db_tenant
  assert_function_exists mysql_build_create_tenant_sql
  assert_function_exists mysql_build_set_limit_sql
  assert_function_exists mysql_build_set_password_sql
  assert_function_exists mysql_build_drop_sql
  assert_function_exists mysql_build_list_sql

  local sql
  # 新建:user 不存在 -> CREATE USER ... WITH
  sql="$(mysql_build_create_tenant_sql acme '%' acme PWD 20 0 0 0 0)"
  assert_str_contains "$sql" "CREATE DATABASE IF NOT EXISTS \`acme\` CHARACTER SET utf8mb4;"
  assert_str_contains "$sql" "CREATE USER 'acme'@'%' IDENTIFIED BY 'PWD' WITH MAX_USER_CONNECTIONS 20 MAX_CONNECTIONS_PER_HOUR 0 MAX_QUERIES_PER_HOUR 0 MAX_UPDATES_PER_HOUR 0;"
  assert_str_contains "$sql" "GRANT ALL PRIVILEGES ON \`acme\`.* TO 'acme'@'%';"
  # 已存在:user 存在 -> 限额走 ALTER USER(不被 CREATE USER IF NOT EXISTS 吞掉)
  sql="$(mysql_build_create_tenant_sql acme '%' acme PWD 20 0 0 0 1)"
  assert_str_contains "$sql" "ALTER USER 'acme'@'%' WITH MAX_USER_CONNECTIONS 20"
  assert_str_missing "$sql" "CREATE USER 'acme'@'%'"

  sql="$(mysql_build_set_limit_sql acme '10.0.0.%' 30 100 1000 500)"
  assert_str_contains "$sql" "ALTER USER 'acme'@'10.0.0.%' WITH MAX_USER_CONNECTIONS 30 MAX_CONNECTIONS_PER_HOUR 100 MAX_QUERIES_PER_HOUR 1000 MAX_UPDATES_PER_HOUR 500;"

  sql="$(mysql_build_set_password_sql acme '%' NEWPW)"
  assert_str_contains "$sql" "ALTER USER 'acme'@'%' IDENTIFIED BY 'NEWPW';"

  sql="$(mysql_build_drop_sql acme '%' acme 1 1)"
  assert_str_contains "$sql" "DROP DATABASE IF EXISTS \`acme\`;"
  assert_str_contains "$sql" "DROP USER IF EXISTS 'acme'@'%';"
  # 仅 user 存在(库已不在)
  sql="$(mysql_build_drop_sql acme '%' acme 0 1)"
  assert_str_missing "$sql" "DROP DATABASE"
  assert_str_contains "$sql" "DROP USER IF EXISTS 'acme'@'%';"

  sql="$(mysql_build_list_sql)"
  assert_str_contains "$sql" "FROM mysql.user"
  assert_str_contains "$sql" "max_user_connections"
}
```

`main` 增加 `mysql_sql) run_mysql_sql_tests ;;` 并加入 `all`。

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_db_tenant.sh mysql_sql`
Expected: FAIL

- [ ] **Step 3: 实现 builders**

追加到 `lib/db-tenant/mysql.sh`：

```bash
# 建租户。1=user 2=host 3=db 4=pw(已转义) 5=muc 6=mcph 7=mqph 8=muph 9=user_exists(0/1)
mysql_build_create_tenant_sql() {
  local user="$1" host="$2" db="$3" pw="$4" muc="$5" mcph="$6" mqph="$7" muph="$8" exists="$9"
  printf 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4;\n' "$db"
  if [[ "$exists" == "1" ]]; then
    printf "ALTER USER '%s'@'%s' WITH MAX_USER_CONNECTIONS %s MAX_CONNECTIONS_PER_HOUR %s MAX_QUERIES_PER_HOUR %s MAX_UPDATES_PER_HOUR %s;\n" \
      "$user" "$host" "$muc" "$mcph" "$mqph" "$muph"
  else
    printf "CREATE USER '%s'@'%s' IDENTIFIED BY '%s' WITH MAX_USER_CONNECTIONS %s MAX_CONNECTIONS_PER_HOUR %s MAX_QUERIES_PER_HOUR %s MAX_UPDATES_PER_HOUR %s;\n" \
      "$user" "$host" "$pw" "$muc" "$mcph" "$mqph" "$muph"
  fi
  printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%s';\n" "$db" "$user" "$host"
}

# 改限额。1=user 2=host 3=muc 4=mcph 5=mqph 6=muph
mysql_build_set_limit_sql() {
  printf "ALTER USER '%s'@'%s' WITH MAX_USER_CONNECTIONS %s MAX_CONNECTIONS_PER_HOUR %s MAX_QUERIES_PER_HOUR %s MAX_UPDATES_PER_HOUR %s;\n" \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

# 改密码。1=user 2=host 3=pw(已转义)
mysql_build_set_password_sql() {
  printf "ALTER USER '%s'@'%s' IDENTIFIED BY '%s';\n" "$1" "$2" "$3"
}

# 删除。1=user 2=host 3=db 4=db_exists(0/1) 5=user_exists(0/1)
mysql_build_drop_sql() {
  [[ "$4" == "1" ]] && printf 'DROP DATABASE IF EXISTS `%s`;\n' "$3"
  [[ "$5" == "1" ]] && printf "DROP USER IF EXISTS '%s'@'%s';\n" "$1" "$2"
  return 0
}

# 列出非系统账号及其限额(库映射在编排层用 mysql.db 关联)
mysql_build_list_sql() {
  cat <<'SQL'
SELECT user, host, max_user_connections, max_connections, max_questions, max_updates
FROM mysql.user
ORDER BY user, host;
SQL
}
```

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/test_db_tenant.sh mysql_sql`
Expected: `PASS: mysql_sql`

- [ ] **Step 5: 提交**

```bash
git add lib/db-tenant/mysql.sh tests/test_db_tenant.sh
git commit -m "feat(db-tenant): MySQL SQL builders(建/改限额/改密码/删除/列出)"
```

---

## Task 6: pg.sh — 探测 / exec / 只读检测 / 守卫 / 备份 / 删除编排（含安全测试）

**Files:**
- Modify: `lib/db-tenant/pg.sh`
- Modify: `tests/test_db_tenant.sh`

- [ ] **Step 1: 加 run_pg_safety_tests（先失败）**

```bash
run_pg_safety_tests() {
  load_db_tenant
  assert_function_exists pg_detect_target
  assert_function_exists pg_exec_sql
  assert_function_exists pg_query
  assert_function_exists pg_assert_writable
  assert_function_exists pg_guard_not_system_role
  assert_function_exists pg_backup_tenant
  assert_function_exists pg_drop_tenant

  local tmp; tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" RETURN
  local log="${tmp}/exec.log"

  # 备份失败 -> 绝不执行任何 DROP
  ( export DB_TENANT_BACKUP_DIR="${tmp}/bk"
    source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"
    source "${ROOT_DIR}/lib/db-tenant/common.sh"; source "${ROOT_DIR}/lib/db-tenant/pg.sh"
    : >"$log"
    pg_assert_writable() { return 0; }
    pg_guard_not_system_role() { return 0; }
    pg_query() { echo "1"; }            # 角色/库都存在
    pg_supports_force() { return 1; }
    pg_backup_tenant() { return 1; }    # 备份失败
    pg_exec_sql() { cat >>"$log"; }     # 间谍:记录所有执行的 SQL
    prompt_with_default() { echo "acme"; }
    if pg_drop_tenant acme acme 2>/dev/null; then fail "drop must abort when backup fails"; fi
    assert_not_contains "$log" "DROP" )

  # 备份成功但二次确认不匹配 -> 不 DROP
  ( export DB_TENANT_BACKUP_DIR="${tmp}/bk2"
    source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"
    source "${ROOT_DIR}/lib/db-tenant/common.sh"; source "${ROOT_DIR}/lib/db-tenant/pg.sh"
    : >"$log"
    pg_assert_writable() { return 0; }
    pg_guard_not_system_role() { return 0; }
    pg_query() { echo "1"; }
    pg_supports_force() { return 1; }
    pg_backup_tenant() { return 0; }
    pg_exec_sql() { cat >>"$log"; }
    prompt_with_default() { echo "WRONG"; }
    if pg_drop_tenant acme acme 2>/dev/null; then fail "drop must abort on name mismatch"; fi
    assert_not_contains "$log" "DROP" )

  # 备份成功且确认匹配 -> 执行 DROP
  ( export DB_TENANT_BACKUP_DIR="${tmp}/bk3"
    source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"
    source "${ROOT_DIR}/lib/db-tenant/common.sh"; source "${ROOT_DIR}/lib/db-tenant/pg.sh"
    : >"$log"
    pg_assert_writable() { return 0; }
    pg_guard_not_system_role() { return 0; }
    pg_query() { echo "1"; }
    pg_supports_force() { return 1; }
    pg_backup_tenant() { return 0; }
    pg_exec_sql() { cat >>"$log"; }
    prompt_with_default() { echo "acme"; }
    pg_drop_tenant acme acme || fail "drop should succeed"
    assert_contains "$log" "DROP ROLE IF EXISTS \"acme\";" )
}
```

`main` 增加 `pg_safety) run_pg_safety_tests ;;` 并加入 `all`。

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_db_tenant.sh pg_safety`
Expected: FAIL

- [ ] **Step 3: 实现探测/exec/守卫/备份/删除**

追加到 `lib/db-tenant/pg.sh`：

```bash
# 探测目标,设置 PG_TARGET_MODE=docker|local
pg_detect_target() {
  if [[ "${DB_TENANT_FORCE_TARGET}" == "docker" ]]; then PG_TARGET_MODE=docker; return 0; fi
  if [[ "${DB_TENANT_FORCE_TARGET}" == "local" ]]; then PG_TARGET_MODE=local; return 0; fi
  if command_exists docker && \
     [[ "$(docker inspect -f '{{.State.Running}}' "${DB_TENANT_PG_CONTAINER}" 2>/dev/null)" == "true" ]]; then
    PG_TARGET_MODE=docker
  else
    PG_TARGET_MODE=local
  fi
}

# 执行 SQL(从 stdin)。$1=dbname(默认 postgres)
pg_exec_sql() {
  local dbname="${1:-postgres}"
  if [[ "${PG_TARGET_MODE:-local}" == "docker" ]]; then
    docker exec -i "${DB_TENANT_PG_CONTAINER}" psql -v ON_ERROR_STOP=1 -U postgres -d "$dbname"
  else
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$dbname"
  fi
}

# 标量查询。$1=dbname $2=sql -> 去空白的单值
pg_query() {
  local dbname="${1:-postgres}" sql="$2" out
  if [[ "${PG_TARGET_MODE:-local}" == "docker" ]]; then
    out="$(printf '%s\n' "$sql" | docker exec -i "${DB_TENANT_PG_CONTAINER}" psql -tAX -U postgres -d "$dbname" 2>/dev/null)"
  else
    out="$(printf '%s\n' "$sql" | sudo -u postgres psql -tAX -d "$dbname" 2>/dev/null)"
  fi
  printf '%s' "$out" | tr -d '[:space:]'
}

# 只读检测
pg_assert_writable() {
  if [[ "$(pg_query postgres 'SELECT pg_is_in_recovery();')" == "t" ]]; then
    echo "当前为 standby,请在 leader 上运行写操作。" >&2; return 1
  fi
  return 0
}

# 是否支持 DROP DATABASE WITH (FORCE)(PG13+)
pg_supports_force() {
  local v; v="$(pg_query postgres 'SHOW server_version_num;')"
  [[ -n "$v" ]] && (( v >= 130000 ))
}

# 守卫:拒绝系统/超级/复制角色
pg_guard_not_system_role() {
  local role="$1"
  if db_tenant_is_system_name "$role" "${DB_TENANT_PG_SYSTEM_NAMES}"; then
    echo "拒绝删除系统角色: $role" >&2; return 1
  fi
  if [[ "$(pg_query postgres "SELECT 1 FROM pg_roles WHERE rolname = '${role}' AND (rolsuper OR rolreplication OR rolbypassrls);")" == "1" ]]; then
    echo "拒绝删除超级/复制角色: $role" >&2; return 1
  fi
  return 0
}

# 角色/库是否存在(返回 0/1 字符串)
pg_role_exists() { [[ "$(pg_query postgres "SELECT 1 FROM pg_roles WHERE rolname='${1}';")" == "1" ]] && echo 1 || echo 0; }
pg_db_exists()   { [[ "$(pg_query postgres "SELECT 1 FROM pg_database WHERE datname='${1}';")" == "1" ]] && echo 1 || echo 0; }

# 备份(仅库)。$1=db;成功设置 PG_BACKUP_FILE 并返回 0
pg_backup_tenant() {
  local db="$1" file
  db_tenant_prepare_backup_dir || return 1
  file="$(db_tenant_backup_path pg "$db" dump)"
  if [[ "${PG_TARGET_MODE:-local}" == "docker" ]]; then
    docker exec -i "${DB_TENANT_PG_CONTAINER}" pg_dump -U postgres -Fc -d "$db" >"$file" || { rm -f "$file"; return 1; }
  else
    sudo -u postgres pg_dump -Fc -d "$db" >"$file" || { rm -f "$file"; return 1; }
  fi
  if ! db_tenant_verify_backup pg "$file"; then rm -f "$file"; return 1; fi
  chmod 600 "$file"
  PG_BACKUP_FILE="$file"
  echo "已备份: $file ($(du -h "$file" 2>/dev/null | awk '{print $1}'))"
  return 0
}

# 删除编排:校验->只读->守卫->备份+校验->二次确认->执行
pg_drop_tenant() {
  local role="$1" db="$2"
  db_tenant_validate_identifier "$role" || return 1
  db_tenant_validate_identifier "$db" || return 1
  if db_tenant_is_system_name "$db" "${DB_TENANT_PG_SYSTEM_NAMES}"; then echo "拒绝删除系统库: $db" >&2; return 1; fi
  pg_assert_writable || return 1
  pg_guard_not_system_role "$role" || return 1
  if ! pg_backup_tenant "$db"; then echo "备份失败,已中止删除。" >&2; return 1; fi
  echo "将删除: 数据库 \"$db\" + 角色 \"$role\""
  local typed; typed="$(prompt_with_default "确认删除请重新输入租户名" "")"
  if [[ "$typed" != "$role" ]]; then echo "名称不匹配,已取消。" >&2; return 1; fi
  local force; if pg_supports_force; then force=1; else force=0; fi
  pg_build_drop_sql "$role" "$db" "$force" "$(pg_role_exists "$role")" "$(pg_db_exists "$db")" | pg_exec_sql postgres
  echo "已删除租户: $role / $db (备份: ${PG_BACKUP_FILE:-N/A})"
}
```

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/test_db_tenant.sh pg_safety`
Expected: `PASS: pg_safety`

- [ ] **Step 5: 提交**

```bash
git add lib/db-tenant/pg.sh tests/test_db_tenant.sh
git commit -m "feat(db-tenant): PG 探测/exec/只读检测/守卫/备份/删除(备份失败即中止)"
```

---

## Task 7: mysql.sh — 探测 / exec / 只读检测 / 守卫 / 备份 / 删除编排（含安全测试）

**Files:**
- Modify: `lib/db-tenant/mysql.sh`
- Modify: `tests/test_db_tenant.sh`

- [ ] **Step 1: 加 run_mysql_safety_tests（先失败）**

```bash
run_mysql_safety_tests() {
  load_db_tenant
  assert_function_exists mysql_detect_target
  assert_function_exists mysql_resolve_admin_password
  assert_function_exists mysql_exec_sql
  assert_function_exists mysql_query
  assert_function_exists mysql_assert_writable
  assert_function_exists mysql_guard_not_system
  assert_function_exists mysql_backup_tenant
  assert_function_exists mysql_drop_tenant

  local tmp; tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" RETURN
  local log="${tmp}/exec.log"

  # 备份失败 -> 不 DROP
  ( export DB_TENANT_BACKUP_DIR="${tmp}/bk"
    source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"
    source "${ROOT_DIR}/lib/db-tenant/common.sh"; source "${ROOT_DIR}/lib/db-tenant/mysql.sh"
    : >"$log"
    mysql_assert_writable() { return 0; }
    mysql_guard_not_system() { return 0; }
    mysql_query() { echo "1"; }
    mysql_backup_tenant() { return 1; }
    mysql_exec_sql() { cat >>"$log"; }
    prompt_with_default() { echo "acme"; }
    if mysql_drop_tenant acme '%' acme 2>/dev/null; then fail "drop must abort when backup fails"; fi
    assert_not_contains "$log" "DROP" )

  # 备份成功 + 确认匹配 -> DROP 精确 user@host
  ( export DB_TENANT_BACKUP_DIR="${tmp}/bk2"
    source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"
    source "${ROOT_DIR}/lib/db-tenant/common.sh"; source "${ROOT_DIR}/lib/db-tenant/mysql.sh"
    : >"$log"
    mysql_assert_writable() { return 0; }
    mysql_guard_not_system() { return 0; }
    mysql_query() { echo "1"; }
    mysql_backup_tenant() { return 0; }
    mysql_exec_sql() { cat >>"$log"; }
    prompt_with_default() { echo "acme"; }
    mysql_drop_tenant acme '%' acme || fail "drop should succeed"
    assert_contains "$log" "DROP USER IF EXISTS 'acme'@'%';" )
}
```

`main` 增加 `mysql_safety) run_mysql_safety_tests ;;` 并加入 `all`。

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_db_tenant.sh mysql_safety`
Expected: FAIL

- [ ] **Step 3: 实现**

追加到 `lib/db-tenant/mysql.sh`：

```bash
# 探测目标,设置 MYSQL_TARGET_MODE=docker|local
mysql_detect_target() {
  if [[ "${DB_TENANT_FORCE_TARGET}" == "docker" ]]; then MYSQL_TARGET_MODE=docker; return 0; fi
  if [[ "${DB_TENANT_FORCE_TARGET}" == "local" ]]; then MYSQL_TARGET_MODE=local; return 0; fi
  if command_exists docker && \
     [[ "$(docker inspect -f '{{.State.Running}}' "${DB_TENANT_MYSQL_CONTAINER}" 2>/dev/null)" == "true" ]]; then
    MYSQL_TARGET_MODE=docker
  else
    MYSQL_TARGET_MODE=local
  fi
}

# 解析管理员密码:DB_TENANT_MYSQL_ADMIN_PASSWORD -> MYSQL_HA_ROOT_PASSWORD -> MYSQL_ROOT_PASSWORD -> 交互
mysql_resolve_admin_password() {
  if [[ -z "${DB_TENANT_MYSQL_ADMIN_PASSWORD}" ]]; then
    DB_TENANT_MYSQL_ADMIN_PASSWORD="${MYSQL_HA_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
  fi
  if [[ -z "${DB_TENANT_MYSQL_ADMIN_PASSWORD}" ]]; then
    printf "MySQL %s 密码: " "${DB_TENANT_MYSQL_ADMIN_USER}" >&2
    IFS= read -rs DB_TENANT_MYSQL_ADMIN_PASSWORD; echo >&2
  fi
}

# 写临时 600 admin cnf 到 $1
mysql_write_admin_cnf() {
  ( umask 077; cat >"$1" <<EOF
[client]
user=${DB_TENANT_MYSQL_ADMIN_USER}
password=${DB_TENANT_MYSQL_ADMIN_PASSWORD}
EOF
  )
}

# 执行 SQL(从 stdin)。凭据经临时 cnf,docker 用 docker cp 进容器用完即删
mysql_exec_sql() {
  local cnf rc=0; cnf="$(mktemp)"; mysql_write_admin_cnf "$cnf"
  if [[ "${MYSQL_TARGET_MODE:-local}" == "docker" ]]; then
    local incnf="/tmp/.db-tenant-$$.cnf"
    docker cp "$cnf" "${DB_TENANT_MYSQL_CONTAINER}:${incnf}" >/dev/null
    docker exec -i "${DB_TENANT_MYSQL_CONTAINER}" mysql --defaults-extra-file="${incnf}" || rc=$?
    docker exec "${DB_TENANT_MYSQL_CONTAINER}" rm -f "${incnf}" >/dev/null 2>&1 || true
  else
    mysql --defaults-extra-file="$cnf" --socket="${DB_TENANT_MYSQL_SOCKET}" || rc=$?
  fi
  rm -f "$cnf"
  return $rc
}

# 标量查询(-N -B 去表头),$1=sql
mysql_query() {
  local sql="$1" cnf out rc=0; cnf="$(mktemp)"; mysql_write_admin_cnf "$cnf"
  if [[ "${MYSQL_TARGET_MODE:-local}" == "docker" ]]; then
    local incnf="/tmp/.db-tenant-q-$$.cnf"
    docker cp "$cnf" "${DB_TENANT_MYSQL_CONTAINER}:${incnf}" >/dev/null
    out="$(printf '%s\n' "$sql" | docker exec -i "${DB_TENANT_MYSQL_CONTAINER}" mysql --defaults-extra-file="${incnf}" -N -B 2>/dev/null)" || rc=$?
    docker exec "${DB_TENANT_MYSQL_CONTAINER}" rm -f "${incnf}" >/dev/null 2>&1 || true
  else
    out="$(printf '%s\n' "$sql" | mysql --defaults-extra-file="$cnf" --socket="${DB_TENANT_MYSQL_SOCKET}" -N -B 2>/dev/null)" || rc=$?
  fi
  rm -f "$cnf"
  printf '%s' "$out" | tr -d '[:space:]'
  return 0
}

# 只读检测
mysql_assert_writable() {
  local r; r="$(mysql_query 'SELECT @@global.super_read_only + @@global.read_only;')"
  if [[ -n "$r" && "$r" != "0" ]]; then
    echo "当前为只读(replica),请在 primary 上运行写操作。" >&2; return 1
  fi
  return 0
}

# 守卫:拒绝系统用户/系统库
mysql_guard_not_system() {
  local user="$1" db="$2"
  if db_tenant_is_system_name "$user" "${DB_TENANT_MYSQL_SYSTEM_USERS}"; then
    echo "拒绝删除系统账号: $user" >&2; return 1
  fi
  if db_tenant_is_system_name "$db" "${DB_TENANT_MYSQL_SYSTEM_DATABASES}"; then
    echo "拒绝删除系统库: $db" >&2; return 1
  fi
  return 0
}

mysql_user_exists() {
  [[ "$(mysql_query "SELECT 1 FROM mysql.user WHERE user='${1}' AND host='${2}';")" == "1" ]] && echo 1 || echo 0
}
mysql_db_exists() {
  [[ "$(mysql_query "SELECT 1 FROM information_schema.schemata WHERE schema_name='${1}';")" == "1" ]] && echo 1 || echo 0
}

# 备份(仅库)。$1=db;成功设置 MYSQL_BACKUP_FILE 返回 0
mysql_backup_tenant() {
  local db="$1" file tmpsql rc=0
  db_tenant_prepare_backup_dir || return 1
  file="$(db_tenant_backup_path mysql "$db" sql.gz)"
  tmpsql="$(mktemp)"
  local cnf; cnf="$(mktemp)"; mysql_write_admin_cnf "$cnf"
  if [[ "${MYSQL_TARGET_MODE:-local}" == "docker" ]]; then
    local incnf="/tmp/.db-tenant-dump-$$.cnf"
    docker cp "$cnf" "${DB_TENANT_MYSQL_CONTAINER}:${incnf}" >/dev/null
    docker exec "${DB_TENANT_MYSQL_CONTAINER}" mysqldump --defaults-extra-file="${incnf}" \
      --single-transaction --routines --triggers --events --databases "$db" >"$tmpsql" || rc=$?
    docker exec "${DB_TENANT_MYSQL_CONTAINER}" rm -f "${incnf}" >/dev/null 2>&1 || true
  else
    mysqldump --defaults-extra-file="$cnf" --socket="${DB_TENANT_MYSQL_SOCKET}" \
      --single-transaction --routines --triggers --events --databases "$db" >"$tmpsql" || rc=$?
  fi
  rm -f "$cnf"
  if (( rc != 0 )); then rm -f "$tmpsql"; return 1; fi
  gzip -c "$tmpsql" >"$file" || { rm -f "$tmpsql" "$file"; return 1; }
  rm -f "$tmpsql"
  if ! db_tenant_verify_backup mysql "$file"; then rm -f "$file"; return 1; fi
  chmod 600 "$file"
  MYSQL_BACKUP_FILE="$file"
  echo "已备份: $file ($(du -h "$file" 2>/dev/null | awk '{print $1}'))"
  return 0
}

# 删除编排(精确 user@host)
mysql_drop_tenant() {
  local user="$1" host="$2" db="$3"
  db_tenant_validate_identifier "$user" 32 || return 1
  db_tenant_validate_identifier "$db" || return 1
  mysql_assert_writable || return 1
  mysql_guard_not_system "$user" "$db" || return 1
  if ! mysql_backup_tenant "$db"; then echo "备份失败,已中止删除。" >&2; return 1; fi
  echo "将删除: 数据库 \`$db\` + 账号 '$user'@'$host'"
  local typed; typed="$(prompt_with_default "确认删除请重新输入租户名" "")"
  if [[ "$typed" != "$user" ]]; then echo "名称不匹配,已取消。" >&2; return 1; fi
  mysql_build_drop_sql "$user" "$host" "$db" "$(mysql_db_exists "$db")" "$(mysql_user_exists "$user" "$host")" | mysql_exec_sql
  echo "已删除租户: $user@$host / $db (备份: ${MYSQL_BACKUP_FILE:-N/A})"
}
```

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/test_db_tenant.sh mysql_safety`
Expected: `PASS: mysql_safety`

- [ ] **Step 5: 提交**

```bash
git add lib/db-tenant/mysql.sh tests/test_db_tenant.sh
git commit -m "feat(db-tenant): MySQL 探测/exec(docker cp 注入)/只读检测/守卫/备份/删除"
```

---

## Task 8: 两引擎 create / list / set-limit / set-password 动作编排

**Files:**
- Modify: `lib/db-tenant/pg.sh`、`lib/db-tenant/mysql.sh`
- Modify: `tests/test_db_tenant.sh`

> 这些动作的核心 SQL 已在 Task 4/5 builder 中测过。这里只补「函数存在 + create 在‘已存在’时回填现值（防降配）」的 mock 测试。

- [ ] **Step 1: 加 run_action_tests（先失败）**

```bash
run_action_tests() {
  load_db_tenant
  for fn in pg_create_tenant pg_list_tenants pg_set_limit pg_set_password \
            mysql_create_tenant mysql_list_tenants mysql_set_limit mysql_set_password; do
    assert_function_exists "$fn"
  done

  local tmp; tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" RETURN
  local log="${tmp}/exec.log"

  # PG create:角色/库已存在 -> 用现值回填(不被默认覆盖) -> 生成 ALTER 分支且连接限额取现值 50
  ( source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"
    source "${ROOT_DIR}/lib/db-tenant/common.sh"; source "${ROOT_DIR}/lib/db-tenant/pg.sh"
    : >"$log"
    pg_assert_writable() { return 0; }
    pg_role_exists() { echo 1; }
    pg_db_exists() { echo 1; }
    pg_query() { echo "50"; }   # 现有 role 连接上限=50
    pg_exec_sql() { cat >>"$log"; }
    prompt_with_default() { echo "${2:-}"; }   # 全部回车采用默认(=回填的现值)
    prompt_yes_no() { return 0; }
    pg_create_tenant acme
    assert_contains "$log" "ALTER ROLE \"acme\" CONNECTION LIMIT 50;" )
}
```

`main` 增加 `action) run_action_tests ;;` 并加入 `all`。

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_db_tenant.sh action`
Expected: FAIL

- [ ] **Step 3: 实现 PG 动作**

追加到 `lib/db-tenant/pg.sh`：

```bash
# 读现有角色连接上限(不存在回显默认)
pg_current_role_conn() {
  local v; v="$(pg_query postgres "SELECT rolconnlimit FROM pg_roles WHERE rolname='${1}';")"
  [[ -n "$v" && "$v" != "-1" ]] && echo "$v" || echo "${DB_TENANT_PG_CONN_LIMIT}"
}

pg_create_tenant() {
  local role="${1:-}"
  if [[ -z "$role" ]]; then role="$(prompt_with_default "租户名(=角色名)" "")"; fi
  db_tenant_validate_identifier "$role" || return 1
  local db; db="$(prompt_with_default "数据库名" "$role")"
  db_tenant_validate_identifier "$db" || return 1
  pg_assert_writable || return 1

  local rexist dexist; rexist="$(pg_role_exists "$role")"; dexist="$(pg_db_exists "$db")"
  local def_conn="${DB_TENANT_PG_CONN_LIMIT}"
  if [[ "$rexist" == "1" ]]; then
    def_conn="$(pg_current_role_conn "$role")"
    echo "该租户/角色已存在,以下为现值回填(回车保持不变)。"
  fi
  local rconn dconn stmt idle wmem pw escpw
  rconn="$(prompt_with_default "角色并发连接上限" "$def_conn")"
  dconn="$(prompt_with_default "库级并发连接上限" "${DB_TENANT_PG_DB_CONN_LIMIT}")"
  stmt="$(prompt_with_default "单语句超时" "${DB_TENANT_PG_STATEMENT_TIMEOUT}")"
  idle="$(prompt_with_default "空闲事务超时" "${DB_TENANT_PG_IDLE_TX_TIMEOUT}")"
  wmem="$(prompt_with_default "单会话排序内存" "${DB_TENANT_PG_WORK_MEM}")"
  if [[ "$rexist" == "1" ]]; then
    pw=""; escpw=""
  else
    pw="$(db_tenant_generate_password)"; escpw="$(db_tenant_sql_escape_literal pg "$pw")"
  fi
  local db_new=0; [[ "$dexist" == "0" ]] && db_new=1

  pg_build_create_tenant_sql "$role" "$db" "$escpw" "$rconn" "$dconn" "$stmt" "$idle" "$wmem" \
    "$rexist" "$dexist" "$db_new" | pg_exec_sql postgres

  echo "== 租户就绪(PostgreSQL) =="
  echo "库: $db  角色: $role"
  [[ -n "$pw" ]] && echo "密码(仅显示一次): $pw"
  echo "连接示例: psql -h <host> -U $role -d $db"
}

pg_list_tenants() { pg_build_list_sql | pg_exec_sql postgres; }

pg_set_limit() {
  local role; role="$(prompt_with_default "租户名(角色)" "")"; db_tenant_validate_identifier "$role" || return 1
  local db; db="$(prompt_with_default "数据库名" "$role")"; db_tenant_validate_identifier "$db" || return 1
  pg_assert_writable || return 1
  local cur; cur="$(pg_current_role_conn "$role")"
  local rconn dconn stmt idle wmem
  rconn="$(prompt_with_default "角色并发连接上限" "$cur")"
  dconn="$(prompt_with_default "库级并发连接上限" "${DB_TENANT_PG_DB_CONN_LIMIT}")"
  stmt="$(prompt_with_default "单语句超时" "${DB_TENANT_PG_STATEMENT_TIMEOUT}")"
  idle="$(prompt_with_default "空闲事务超时" "${DB_TENANT_PG_IDLE_TX_TIMEOUT}")"
  wmem="$(prompt_with_default "单会话排序内存" "${DB_TENANT_PG_WORK_MEM}")"
  pg_build_set_limit_sql "$role" "$db" "$rconn" "$dconn" "$stmt" "$idle" "$wmem" | pg_exec_sql postgres
  echo "已更新限额: $role"
}

pg_set_password() {
  local role; role="$(prompt_with_default "租户名(角色)" "")"; db_tenant_validate_identifier "$role" || return 1
  pg_assert_writable || return 1
  local pw escpw; pw="$(db_tenant_generate_password)"; escpw="$(db_tenant_sql_escape_literal pg "$pw")"
  pg_build_set_password_sql "$role" "$escpw" | pg_exec_sql postgres
  echo "新密码(仅显示一次): $pw"
}
```

- [ ] **Step 4: 实现 MySQL 动作**

追加到 `lib/db-tenant/mysql.sh`：

```bash
mysql_current_user_muc() {
  local v; v="$(mysql_query "SELECT max_user_connections FROM mysql.user WHERE user='${1}' AND host='${2}';")"
  [[ -n "$v" ]] && echo "$v" || echo "${DB_TENANT_MYSQL_MAX_USER_CONN}"
}

mysql_create_tenant() {
  local user="${1:-}"
  if [[ -z "$user" ]]; then user="$(prompt_with_default "租户名(=用户名)" "")"; fi
  db_tenant_validate_identifier "$user" 32 || return 1
  local db; db="$(prompt_with_default "数据库名" "$user")"; db_tenant_validate_identifier "$db" || return 1
  local host; host="$(prompt_with_default "允许来源 host" "${DB_TENANT_MYSQL_DEFAULT_HOST}")"
  mysql_assert_writable || return 1

  local uexist; uexist="$(mysql_user_exists "$user" "$host")"
  local def_muc="${DB_TENANT_MYSQL_MAX_USER_CONN}"
  if [[ "$uexist" == "1" ]]; then def_muc="$(mysql_current_user_muc "$user" "$host")"; echo "该账号已存在,现值回填(回车保持不变)。"; fi
  local muc mcph mqph muph pw escpw
  muc="$(prompt_with_default "并发连接上限" "$def_muc")"
  mcph="$(prompt_with_default "每小时新建连接(0=不限)" "${DB_TENANT_MYSQL_MAX_CONN_PER_HOUR}")"
  mqph="$(prompt_with_default "每小时查询数(0=不限)" "${DB_TENANT_MYSQL_MAX_QUERIES_PER_HOUR}")"
  muph="$(prompt_with_default "每小时更新数(0=不限)" "${DB_TENANT_MYSQL_MAX_UPDATES_PER_HOUR}")"
  if [[ "$uexist" == "1" ]]; then pw=""; escpw=""; else pw="$(db_tenant_generate_password)"; escpw="$(db_tenant_sql_escape_literal mysql "$pw")"; fi

  mysql_build_create_tenant_sql "$user" "$host" "$db" "$escpw" "$muc" "$mcph" "$mqph" "$muph" "$uexist" | mysql_exec_sql

  echo "== 租户就绪(MySQL) =="
  echo "库: $db  账号: '$user'@'$host'"
  [[ -n "$pw" ]] && echo "密码(仅显示一次): $pw"
  echo "连接示例: mysql -h <host> -u $user -p $db"
}

mysql_list_tenants() {
  # 排除系统账号(在输出层用 grep -v 过滤名单首词不够稳,改用 SQL NOT IN 由编排拼装)
  local notin="" u
  for u in ${DB_TENANT_MYSQL_SYSTEM_USERS}; do notin="${notin:+$notin,}'${u}'"; done
  printf "SELECT user, host, max_user_connections, max_connections, max_questions, max_updates FROM mysql.user WHERE user NOT IN (%s) ORDER BY user, host;\n" "$notin" | mysql_exec_sql
}

mysql_set_limit() {
  local user; user="$(prompt_with_default "租户名(用户)" "")"; db_tenant_validate_identifier "$user" 32 || return 1
  local host; host="$(prompt_with_default "host" "${DB_TENANT_MYSQL_DEFAULT_HOST}")"
  mysql_assert_writable || return 1
  local cur; cur="$(mysql_current_user_muc "$user" "$host")"
  local muc mcph mqph muph
  muc="$(prompt_with_default "并发连接上限" "$cur")"
  mcph="$(prompt_with_default "每小时新建连接" "${DB_TENANT_MYSQL_MAX_CONN_PER_HOUR}")"
  mqph="$(prompt_with_default "每小时查询数" "${DB_TENANT_MYSQL_MAX_QUERIES_PER_HOUR}")"
  muph="$(prompt_with_default "每小时更新数" "${DB_TENANT_MYSQL_MAX_UPDATES_PER_HOUR}")"
  mysql_build_set_limit_sql "$user" "$host" "$muc" "$mcph" "$mqph" "$muph" | mysql_exec_sql
  echo "已更新限额: '$user'@'$host'"
}

mysql_set_password() {
  local user; user="$(prompt_with_default "租户名(用户)" "")"; db_tenant_validate_identifier "$user" 32 || return 1
  local host; host="$(prompt_with_default "host" "${DB_TENANT_MYSQL_DEFAULT_HOST}")"
  mysql_assert_writable || return 1
  local pw escpw; pw="$(db_tenant_generate_password)"; escpw="$(db_tenant_sql_escape_literal mysql "$pw")"
  mysql_build_set_password_sql "$user" "$host" "$escpw" | mysql_exec_sql
  echo "新密码(仅显示一次): $pw"
}
```

- [ ] **Step 5: 运行确认通过**

Run: `bash tests/test_db_tenant.sh action`
Expected: `PASS: action`

- [ ] **Step 6: 提交**

```bash
git add lib/db-tenant/pg.sh lib/db-tenant/mysql.sh tests/test_db_tenant.sh
git commit -m "feat(db-tenant): create/list/set-limit/set-password 动作(create 回填现值防降配)"
```

---

## Task 9: main.sh — 引擎选择 + 动作菜单 + 分发

**Files:**
- Modify: `lib/db-tenant/main.sh`
- Modify: `tests/test_db_tenant.sh`

- [ ] **Step 1: 加 run_dispatch_tests（先失败）**

```bash
run_dispatch_tests() {
  load_db_tenant
  assert_function_exists db_tenant_dispatch
  assert_function_exists db_tenant_main

  local tmp; tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" RETURN
  local log="${tmp}/dispatch.log"

  ( source "${ROOT_DIR}/lib/db-tenant/config.sh"; source "${ROOT_DIR}/lib/common.sh"
    source "${ROOT_DIR}/lib/db-tenant/common.sh"; source "${ROOT_DIR}/lib/db-tenant/pg.sh"
    source "${ROOT_DIR}/lib/db-tenant/mysql.sh"; source "${ROOT_DIR}/lib/db-tenant/main.sh"
    : >"$log"
    pg_detect_target() { :; }
    pg_create_tenant() { echo "pg_create" >>"$log"; }
    db_tenant_dispatch pg 1
    assert_contains "$log" "pg_create"

    : >"$log"
    mysql_detect_target() { :; }
    mysql_resolve_admin_password() { :; }
    mysql_drop_tenant() { echo "mysql_drop $*" >>"$log"; }
    mysql_pick_tenant() { REPLY_USER=acme; REPLY_HOST='%'; REPLY_DB=acme; }
    db_tenant_dispatch mysql 6
    assert_contains "$log" "mysql_drop acme % acme" )
}
```

`main` 增加 `dispatch) run_dispatch_tests ;;` 并加入 `all`。

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_db_tenant.sh dispatch`
Expected: FAIL

- [ ] **Step 3: 实现 main.sh**

把 `lib/db-tenant/main.sh` 全文替换为：

```bash
#!/usr/bin/env bash
# lib/db-tenant/main.sh — 引擎选择与动作菜单

# 删除动作:交互选出租户身份后调用对应引擎删除
db_tenant_drop_action() {
  local engine="$1"
  if [[ "$engine" == "pg" ]]; then
    local role db
    role="$(prompt_with_default "要删除的租户名(角色)" "")"
    db="$(prompt_with_default "数据库名" "$role")"
    pg_drop_tenant "$role" "$db"
  else
    local user host db
    user="$(prompt_with_default "要删除的租户名(用户)" "")"
    host="$(prompt_with_default "host" "${DB_TENANT_MYSQL_DEFAULT_HOST}")"
    db="$(prompt_with_default "数据库名" "$user")"
    mysql_drop_tenant "$user" "$host" "$db"
  fi
}

db_tenant_backup_action() {
  local engine="$1"
  if [[ "$engine" == "pg" ]]; then
    local db; db="$(prompt_with_default "要备份的数据库名" "")"
    db_tenant_validate_identifier "$db" || return 1
    pg_backup_tenant "$db"
  else
    local db; db="$(prompt_with_default "要备份的数据库名" "")"
    db_tenant_validate_identifier "$db" || return 1
    mysql_backup_tenant "$db"
  fi
}

# 按引擎+动作号分发。$1=pg|mysql $2=action(1..6)
db_tenant_dispatch() {
  local engine="$1" action="$2"
  case "$action" in
    1) ${engine}_create_tenant ;;
    2) ${engine}_list_tenants ;;
    3) ${engine}_set_limit ;;
    4) ${engine}_set_password ;;
    5) db_tenant_backup_action "$engine" ;;
    6) db_tenant_drop_action "$engine" ;;
    *) echo "未知动作: $action" >&2; return 1 ;;
  esac
}

db_tenant_action_menu() {
  local engine="$1" choice
  while true; do
    cat >&2 <<'MENU'

=== 动作菜单 ===
 1) 创建租户
 2) 列出租户
 3) 修改限额
 4) 修改密码
 5) 备份租户
 6) 删除租户
 0) 退出
MENU
    choice="$(prompt_with_default "请选择" "0")"
    case "$choice" in
      0) return 0 ;;
      1|2|3|4|5|6) db_tenant_dispatch "$engine" "$choice" || true ;;
      *) echo "无效选择" >&2 ;;
    esac
  done
}

db_tenant_main() {
  require_root || return 1
  local engine_choice engine
  cat >&2 <<'MENU'

=== 数据库多租户管理 ===
 1) PostgreSQL
 2) MySQL
MENU
  engine_choice="$(prompt_with_default "选择引擎" "1")"
  case "$engine_choice" in
    1) engine=pg; pg_detect_target ;;
    2) engine=mysql; mysql_detect_target; mysql_resolve_admin_password ;;
    *) echo "无效引擎" >&2; return 1 ;;
  esac
  echo "目标形态: ${engine} / ${PG_TARGET_MODE:-${MYSQL_TARGET_MODE:-?}}" >&2
  if ! prompt_yes_no "确认对该目标操作?" "y"; then echo "已取消。" >&2; return 0; fi
  db_tenant_action_menu "$engine"
}
```

- [ ] **Step 4: 运行确认通过**

Run: `bash tests/test_db_tenant.sh dispatch`
Expected: `PASS: dispatch`

> 注：测试里 `mysql_pick_tenant`/`REPLY_*` 是预留的多 host 选择钩子；当前 `db_tenant_drop_action` 用 `prompt_with_default` 直接取 user/host/db，dispatch 测试通过 mock `mysql_drop_tenant` + `prompt_with_default` 即可。若实现未用 `mysql_pick_tenant`，删除该 mock 行；保持测试与实现一致。

- [ ] **Step 5: 提交**

```bash
git add lib/db-tenant/main.sh tests/test_db_tenant.sh
git commit -m "feat(db-tenant): 菜单与分发(引擎选择/动作菜单/删除-备份动作)"
```

---

## Task 10: README + docs 测试 + 全量校验 + 收尾

**Files:**
- Modify: `README.md`
- Modify: `tests/test_db_tenant.sh`

- [ ] **Step 1: 加 run_docs_tests（先失败）**

```bash
run_docs_tests() {
  local readme="${ROOT_DIR}/README.md"
  assert_contains "$readme" "db-tenant.sh"
  assert_contains "$readme" "多租户"
  assert_contains "$readme" "DB_TENANT_BACKUP_DIR"
  assert_contains "$readme" "primary"
}
```

`main` 增加 `docs) run_docs_tests ;;`，并把 `all)` 行补全为按序运行全部 suite：
```bash
    all) run_skeleton_tests; run_config_tests; run_common_tests; run_backup_helper_tests; \
         run_pg_sql_tests; run_mysql_sql_tests; run_pg_safety_tests; run_mysql_safety_tests; \
         run_action_tests; run_dispatch_tests; run_docs_tests ;;
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/test_db_tenant.sh docs`
Expected: FAIL（README 未含相应内容）

- [ ] **Step 3: 在 README.md 增补章节**

在 README 合适位置（HA 章节之后）追加：

```markdown
## 数据库多租户管理（db-tenant.sh）

为已部署的 MySQL / PostgreSQL 按「一库一角色」管理多租户，并对角色施加账号级资源限制，
避免某个租户瞬时爆发拖垮同实例的其他租户。

一键运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/db-tenant.sh)
```

或本地：`bash db-tenant.sh`

- **自动探测**：同名容器在运行用 `docker exec`；否则用本机 socket/客户端（探测结果会要求确认；可用
  `DB_TENANT_FORCE_TARGET=docker|local` 覆盖）。
- **资源限制**：
  - PostgreSQL：角色/库连接上限、`statement_timeout`、`idle_in_transaction_session_timeout`、`work_mem`。
  - MySQL：`MAX_USER_CONNECTIONS`、每小时连接/查询/更新配额。**MySQL 无账号级语句超时**（`max_execution_time`
    仅对 SELECT 生效且全局/会话级，本工具不设置）；`0` 表示不限。
- **删除前先备份**：删除会先把库 `pg_dump`/`mysqldump` 到 `DB_TENANT_BACKUP_DIR`（默认 `/var/backups/db-tenant`），
  并做完整性校验，**校验失败则中止删除**；随后需重输租户名二次确认。备份仅含数据库，角色/限额需另行重建。
- **HA 注意**：写操作（含删除）需在 `primary`/`leader` 节点运行；独立备份可在 standby。
- **端口/防火墙**：本工具为客户端工具，**不监听端口、不修改防火墙**。
- MySQL 管理员密码取自 `DB_TENANT_MYSQL_ADMIN_PASSWORD`，缺省回退 `MYSQL_HA_ROOT_PASSWORD` /
  `MYSQL_ROOT_PASSWORD`，再缺则交互输入。
```

- [ ] **Step 4: 运行整套测试 + 语法扫描，确认全绿**

Run: `bash tests/test_db_tenant.sh`
Expected: `PASS: all`

Run: `find . -name '*.sh' -type f -not -path './.git/*' -print0 | xargs -0 -n1 bash -n`
Expected: 无输出（全部语法正确）

Run: `bash tests/test_deploy.sh && bash tests/test_pg_ha.sh && bash tests/test_mysql_ha.sh`
Expected: 三个既有套件 `PASS`（确认未破坏其它路径）

- [ ] **Step 5: 确认可执行位并提交**

```bash
chmod +x db-tenant.sh tests/test_db_tenant.sh
git add README.md tests/test_db_tenant.sh
git commit -m "docs(db-tenant): README 章节 + docs 测试 + 全量校验"
```

---

## 自审（Self-Review）

**1. Spec 覆盖核对：**
- 双引擎 + 自动探测 → Task 6/7 `*_detect_target` + `DB_TENANT_FORCE_TARGET`；菜单确认在 Task 9。✓
- 资源限制参数集（PG `IN DATABASE SET`；MySQL `WITH` 四项）→ Task 4/5 builders + Task 8 动作。✓
- 一库一角色 + 幂等 + 防降配回填 → Task 4/5（exists 分支）+ Task 8（`*_current_*` 回填）。✓
- 列出基于 catalog（PG LEFT JOIN 暴露孤儿；MySQL NOT IN 系统账号）→ Task 4/5 builder + Task 8 list。✓
- 删除：只读检测→备份→完整性校验→二次确认→执行；备份失败即中止 → Task 6/7 编排 + 安全测试。✓
- 备份仅库 + 完整性校验（`pg_restore -l` / `gzip -t` + `Dump completed`）+ 磁盘预检 + 防同秒覆盖 → Task 3/6/7。✓
- 凭据安全（MySQL `docker cp` 临时 600 cnf，不用 `MYSQL_PWD`；管理员密码回退）→ Task 7。✓
- denylist 双道（静态名单 + catalog 属性）→ Task 6 `pg_guard_not_system_role`、Task 7 `mysql_guard_not_system`，名单在 config。✓
- 标识符白名单 + 密码转义（PG/MySQL 差异）→ Task 2。✓
- 仓库一致性（入口内联 loader、复用 common、加载顺序、`-x`、README 同步）→ Task 1/9/10。✓
- `flock` 串行化 → Task 3 `db_tenant_with_lock`（菜单可按需包裹；若不强制，作为可选）。⚠ 见下。

**2. 占位符扫描：** 无 TBD/TODO；Task 4 Step 1 的占位断言已在 Step 3 给出修正行。✓

**3. 类型/命名一致性：** builder 参数顺序在测试与实现间一致；`PG_TARGET_MODE`/`MYSQL_TARGET_MODE`、
`PG_BACKUP_FILE`/`MYSQL_BACKUP_FILE`、`db_tenant_dispatch` 动作号（1..6）跨 Task 一致。✓

**4. 已知取舍（实现时按此办）：**
- `flock` 仅在 `db_tenant_with_lock` 提供；本计划未强制每个写操作包裹它（菜单为单进程交互，竞态风险低）。
  如需严格串行，可在 `db_tenant_dispatch` 写动作(1/3/4/5/6)外层包 `db_tenant_with_lock`。属可选增强，不影响测试。
- 多 host 同名账号的「列出选择」(spec §7.3/H4) 在本计划中以「显式输入 host」实现（删除/改限额都要求输入 host）；
  `mysql_pick_tenant` 为未来交互选择预留，当前非必需。
- `pg_list_tenants` 的角色级 SET（statement_timeout 等）展示从简（仅列连接上限）；如需展示 `pg_db_role_setting`
  可在 list builder 增列，不影响删除/限额正确性。
```
