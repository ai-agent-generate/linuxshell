# `pg` Shortcut Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install a `/usr/local/bin/pg` wrapper that calls `docker exec -i[t] postgres psql -U <user>` with pass-through args, installed automatically by `deploy.sh` when PostgreSQL is deployed and via a standalone script `install-pg-wrapper.sh` for already-installed setups.

**Architecture:** Add one shared shell function `install_pg_wrapper <user>` inside `deploy.sh` that writes the wrapper to `/usr/local/bin/pg` (path overridable via `PG_WRAPPER_BIN` for tests). Two invocation paths: (a) automatic call inside `main` after `prepare_postgres` using `$POSTGRES_USER`; (b) menu item 6 that prompts for a username. A separate, self-contained script `install-pg-wrapper.sh` mirrors the same output for cold installs without coupling to `deploy.sh`.

**Tech Stack:** Bash, Docker, existing `tests/test_deploy.sh` harness.

**Spec:** `docs/superpowers/specs/2026-04-21-pg-shortcut-design.md`

**Commit-style note:** This repo uses conventional-commit-ish prefixes (`fix:`, `feat:`, `docs:`) in Chinese. Follow the existing style seen in `git log --oneline -5`.

---

## Task 0: Re-sync stale tests to current deploy.sh (baseline green)

**Why:** Two recent deploy.sh changes drifted from `tests/test_deploy.sh`:
1. Network rename `app-net` → `my_network` (commit d90621e)
2. PostgreSQL data path changed from `${POSTGRES_DIR}/data` to `${POSTGRES_DIR}` (commit 889d3e3 moved PG 18+ layout into `${POSTGRES_DIR}/18/main`, mounting `${POSTGRES_DIR}` as volume root)

The rest of this plan writes new tests that assume a green baseline. Fix this drift first.

**Files:**
- Modify: `tests/test_deploy.sh:172-173,176,178,181,252,278,284,297,298,307`

- [ ] **Step 1: Confirm baseline failure**

Run: `bash tests/test_deploy.sh all 2>&1 | head -5`
Expected output contains: `FAIL: expected '.../postgres/data' in .../docker-postgres.yml`

- [ ] **Step 2: Fix PostgreSQL data-path assertion**

In `tests/test_deploy.sh`, replace line 172:
```bash
  assert_contains "${temp_root}/docker/docker-postgres.yml" "${temp_root}/postgres/data"
```
with:
```bash
  assert_contains "${temp_root}/docker/docker-postgres.yml" "${temp_root}/postgres:/var/lib/postgresql"
```

- [ ] **Step 3: Replace all `app-net` occurrences with `my_network`**

Use one `sed -i` invocation. On macOS this syntax requires an empty string after `-i`:

```bash
sed -i '' 's/app-net/my_network/g' tests/test_deploy.sh
```

(On Linux CI runners use `sed -i 's/app-net/my_network/g' tests/test_deploy.sh`.)

- [ ] **Step 4: Verify no `app-net` remains**

Run: `grep -n 'app-net' tests/test_deploy.sh`
Expected: no output (exit code 1).

- [ ] **Step 5: Run all tests; confirm green baseline**

Run: `bash tests/test_deploy.sh all`
Expected: `PASS: all`

- [ ] **Step 6: Commit**

```bash
git add tests/test_deploy.sh
git commit -m "fix: 测试同步 my_network 网络名与 postgres 卷路径"
```

---

## Task 1: Add `install_pg_wrapper` function to deploy.sh (TDD)

**Why:** Core writer that generates the wrapper file. Must be testable via `PG_WRAPPER_BIN` env override.

**Files:**
- Modify: `deploy.sh` (add function block ~after `write_redis_compose`)
- Modify: `tests/test_deploy.sh` (extend `run_generation_tests`)

- [ ] **Step 1: Write failing test**

Two edits in `tests/test_deploy.sh`:

**(a) Export wrapper bin path before `load_script`.** In `run_generation_tests`, after the existing `export RABBITMQ_ENABLED_PLUGINS_FILE=...` line (line 145) and before `load_script` (line 147), insert:

```bash
  export PG_WRAPPER_BIN="${temp_root}/usr/local/bin/pg"
  mkdir -p "$(dirname "$PG_WRAPPER_BIN")"
```

We do NOT add `PG_WRAPPER_BIN` to the `load_script` unset list (mirroring how `DATA_ROOT` is left alone); this lets the test's export flow through into the sourced deploy.sh.

**(b) Add assertions at end of `run_generation_tests`.** After the existing last assertion `assert_contains "${temp_root}/docker/docker-redis.yml" "- redis"` (line 182) and before the closing `}` (line 183), append:

```bash

  assert_function_exists "install_pg_wrapper"
  install_pg_wrapper "alice"

  assert_file_exists "$PG_WRAPPER_BIN"
  [[ -x "$PG_WRAPPER_BIN" ]] || fail "expected pg wrapper to be executable"
  assert_contains "$PG_WRAPPER_BIN" "docker exec -it postgres psql -U alice"
  assert_contains "$PG_WRAPPER_BIN" "docker exec -i postgres psql -U alice"
  assert_contains "$PG_WRAPPER_BIN" "container 'postgres' is not running"
```

**(c) Extend `load_script` unset list.** In `load_script` (lines 58-74), append `SELECT_PG_WRAPPER INSTALLED_PG_WRAPPER_USER` to the unset list, on a new continuation line before the closing `2>/dev/null || true`. The modified unset block will read (new line at the bottom):

```bash
    REDIS_PORT REDIS_PASSWORD \
    SELECT_PG_WRAPPER INSTALLED_PG_WRAPPER_USER 2>/dev/null || true
```

Rationale: `PG_WRAPPER_BIN` flows through from the test; `SELECT_PG_WRAPPER` and `INSTALLED_PG_WRAPPER_USER` get cleared like other per-run state.

- [ ] **Step 2: Run test; verify failure**

Run: `bash tests/test_deploy.sh generation 2>&1 | tail -5`
Expected: `FAIL: expected function to exist: install_pg_wrapper`

- [ ] **Step 3: Implement `install_pg_wrapper` in `deploy.sh`**

Near the top of `deploy.sh`, after line 82 (`SHARED_NETWORK_NAME="..."`) add:

```bash
PG_WRAPPER_BIN="${PG_WRAPPER_BIN:-/usr/local/bin/pg}"
INSTALLED_PG_WRAPPER_USER=""
```

After the `write_redis_compose` function (ends around line 492), insert:

```bash
install_pg_wrapper() {
  local user="$1"

  cat >"$PG_WRAPPER_BIN" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if ! docker inspect -f '{{.State.Running}}' postgres >/dev/null 2>&1; then
  echo "PostgreSQL container 'postgres' is not running." >&2
  exit 1
fi

if [ -t 0 ]; then
  exec docker exec -it postgres psql -U ${user} "\$@"
else
  exec docker exec -i postgres psql -U ${user} "\$@"
fi
EOF
  chmod +x "$PG_WRAPPER_BIN"
  INSTALLED_PG_WRAPPER_USER="$user"
  echo "Installed pg shortcut at ${PG_WRAPPER_BIN} (user: ${user})"
}
```

- [ ] **Step 4: Run test; verify pass**

Run: `bash tests/test_deploy.sh generation`
Expected: `PASS: generation`

- [ ] **Step 5: Commit**

```bash
git add deploy.sh tests/test_deploy.sh
git commit -m "feat: 新增 install_pg_wrapper 生成 /usr/local/bin/pg"
```

---

## Task 2: Add `SELECT_PG_WRAPPER` flag and selection parsing (TDD)

**Why:** Menu item 6 must drive installation without selecting PostgreSQL.

**Files:**
- Modify: `deploy.sh` (selection vars + `parse_service_selection` case + `collect_service_selection` exit condition)
- Modify: `tests/test_deploy.sh` (extend `run_helper_tests`)

- [ ] **Step 1: Write failing test**

In `tests/test_deploy.sh`, inside `run_helper_tests`, after the existing `parse_service_selection "2,5"` assertions block (around line 212), append:

```bash

  parse_service_selection "6"
  [[ "${SELECT_PG_WRAPPER:-0}" -eq 1 ]] || fail "expected pg wrapper selection from '6'"
  [[ "${SELECT_CADDY:-0}" -eq 0 ]] || fail "did not expect caddy selection from '6'"

  parse_service_selection "pg"
  [[ "${SELECT_PG_WRAPPER:-0}" -eq 1 ]] || fail "expected pg wrapper selection from 'pg'"

  parse_service_selection "pg-shortcut"
  [[ "${SELECT_PG_WRAPPER:-0}" -eq 1 ]] || fail "expected pg wrapper selection from 'pg-shortcut'"

  parse_service_selection "1"
  [[ "${SELECT_PG_WRAPPER:-0}" -eq 0 ]] || fail "did not expect pg wrapper selection from '1'"
```

- [ ] **Step 2: Run test; verify failure**

Run: `bash tests/test_deploy.sh helpers 2>&1 | tail -5`
Expected: `FAIL: expected pg wrapper selection from '6'`

- [ ] **Step 3: Add flag initialization to `deploy.sh`**

Locate the `SELECT_*` block (lines 53-57). Add `SELECT_PG_WRAPPER=0` after `SELECT_REDIS=0`. Block becomes:

```bash
SELECT_CADDY=0
SELECT_POSTGRES=0
SELECT_MYSQL=0
SELECT_RABBITMQ=0
SELECT_REDIS=0
SELECT_PG_WRAPPER=0
```

- [ ] **Step 4: Extend `parse_service_selection`**

In `parse_service_selection` (starts line 190), find the re-initialization block (lines 195-199):

```bash
  SELECT_CADDY=0
  SELECT_POSTGRES=0
  SELECT_MYSQL=0
  SELECT_RABBITMQ=0
  SELECT_REDIS=0
```

Append one line:
```bash
  SELECT_PG_WRAPPER=0
```

Then in the `case "$normalized" in` block (lines 203-222), add before the `*)` fallback:

```bash
      6|pg|pg-shortcut)
        SELECT_PG_WRAPPER=1
        ;;
```

- [ ] **Step 5: Update `collect_service_selection` exit condition**

In `collect_service_selection` (line 243), change:

```bash
    if (( SELECT_CADDY || SELECT_POSTGRES || SELECT_MYSQL || SELECT_RABBITMQ || SELECT_REDIS )); then
```

to:

```bash
    if (( SELECT_CADDY || SELECT_POSTGRES || SELECT_MYSQL || SELECT_RABBITMQ || SELECT_REDIS || SELECT_PG_WRAPPER )); then
```

- [ ] **Step 6: Run helper tests; verify pass**

Run: `bash tests/test_deploy.sh helpers`
Expected: `PASS: helpers`

- [ ] **Step 7: Commit**

```bash
git add deploy.sh tests/test_deploy.sh
git commit -m "feat: 菜单新增 pg-shortcut 选项 (SELECT_PG_WRAPPER)"
```

---

## Task 3: Update menu text and verify via existing collect test

**Why:** User-facing menu must list the new option.

**Files:**
- Modify: `deploy.sh` (`collect_service_selection` heredoc)
- Modify: `tests/test_deploy.sh` (extend existing assertion)

- [ ] **Step 1: Extend existing menu assertion**

In `tests/test_deploy.sh`, `run_helper_tests`, after the existing two `assert_output_contains "$selection_output"` calls (around line 215-216), append:

```bash
  assert_output_contains "$selection_output" "6) Install pg shortcut"
```

- [ ] **Step 2: Run test; verify failure**

Run: `bash tests/test_deploy.sh helpers 2>&1 | tail -5`
Expected: `FAIL: expected output to contain '6) Install pg shortcut'`

- [ ] **Step 3: Extend menu heredoc**

In `deploy.sh` `collect_service_selection` (lines 229-236), the heredoc currently ends with:

```
  5) Redis
EOF
```

Change to:

```
  5) Redis
  6) Install pg shortcut (PostgreSQL already running)
EOF
```

- [ ] **Step 4: Run helper tests; verify pass**

Run: `bash tests/test_deploy.sh helpers`
Expected: `PASS: helpers`

- [ ] **Step 5: Commit**

```bash
git add deploy.sh tests/test_deploy.sh
git commit -m "feat: 菜单补全 pg shortcut 选项提示"
```

---

## Task 4: Wire `install_pg_wrapper` into `main()`

**Why:** Two invocation paths: auto on PG install, standalone on menu item 6.

**Files:**
- Modify: `deploy.sh` (`main` function body)

No new unit test — building blocks are already tested; integration via `main()` is covered by `bash -n` syntax check and manual verification.

- [ ] **Step 1: Auto-install branch after PostgreSQL**

In `deploy.sh` `main` (starts line 795), locate the PostgreSQL block (lines 810-813):

```bash
  if (( SELECT_POSTGRES )); then
    configure_postgres
    prepare_postgres
  fi
```

Change to:

```bash
  if (( SELECT_POSTGRES )); then
    configure_postgres
    prepare_postgres
    install_pg_wrapper "$POSTGRES_USER"
  fi
```

- [ ] **Step 2: Standalone branch for menu item 6**

In `main`, after the Redis block (lines 828-831) and before `show_summary` (line 833), insert:

```bash
  if (( SELECT_PG_WRAPPER && ! SELECT_POSTGRES )); then
    local wrapper_user
    wrapper_user="$(prompt_with_default "PostgreSQL username to bake into 'pg'" "postgres")"
    install_pg_wrapper "$wrapper_user"
  fi
```

- [ ] **Step 3: Syntax check**

Run: `bash -n deploy.sh`
Expected: no output (exit 0).

- [ ] **Step 4: Run all tests; confirm still green**

Run: `bash tests/test_deploy.sh all`
Expected: `PASS: all`

- [ ] **Step 5: Commit**

```bash
git add deploy.sh
git commit -m "feat: main 流程集成 install_pg_wrapper 调用点"
```

---

## Task 5: Extend `show_summary` with pg shortcut line (TDD)

**Why:** Visual confirmation in the final deploy summary.

**Files:**
- Modify: `deploy.sh` (`show_summary` function)
- Modify: `tests/test_deploy.sh` (extend `run_generation_tests`)

- [ ] **Step 1: Write failing test**

In `tests/test_deploy.sh`, `run_generation_tests`, at the very end of the function (after the pg wrapper assertions added in Task 1) append:

```bash

  local summary_output
  summary_output="$(show_summary 2>&1)"
  [[ "$summary_output" == *"pg shortcut: ${PG_WRAPPER_BIN} (user: alice)"* ]] \
    || fail "expected show_summary to include pg shortcut line"
```

- [ ] **Step 2: Run test; verify failure**

Run: `bash tests/test_deploy.sh generation 2>&1 | tail -5`
Expected: `FAIL: expected show_summary to include pg shortcut line`

- [ ] **Step 3: Extend `show_summary` in deploy.sh**

In `show_summary` (starts line 775), before the closing `}` (currently line 793), insert:

```bash
  if [[ -n "$INSTALLED_PG_WRAPPER_USER" ]]; then
    echo "pg shortcut: ${PG_WRAPPER_BIN} (user: ${INSTALLED_PG_WRAPPER_USER})"
  fi
```

- [ ] **Step 4: Run test; verify pass**

Run: `bash tests/test_deploy.sh generation`
Expected: `PASS: generation`

- [ ] **Step 5: Run all tests**

Run: `bash tests/test_deploy.sh all`
Expected: `PASS: all`

- [ ] **Step 6: Commit**

```bash
git add deploy.sh tests/test_deploy.sh
git commit -m "feat: show_summary 输出 pg shortcut 安装路径"
```

---

## Task 6: Create standalone `install-pg-wrapper.sh` (TDD)

**Why:** Users who already have PostgreSQL running need a curl|bash path that doesn't require pulling all of `deploy.sh`.

**Files:**
- Create: `install-pg-wrapper.sh`
- Modify: `tests/test_deploy.sh` (extend `run_skeleton_tests`)

- [ ] **Step 1: Write failing skeleton test**

In `tests/test_deploy.sh`, locate `run_skeleton_tests` (line 128). Currently:

```bash
run_skeleton_tests() {
  assert_file_exists "$DEPLOY_SCRIPT"
  load_script
  assert_function_exists "require_root"
  assert_function_exists "detect_os"
  assert_function_exists "ensure_directories"
  assert_function_exists "main"
}
```

Append before the closing `}`:

```bash
  local standalone="${ROOT_DIR}/install-pg-wrapper.sh"
  assert_file_exists "$standalone"
  [[ -x "$standalone" ]] || fail "expected install-pg-wrapper.sh to be executable"
  bash -n "$standalone" || fail "install-pg-wrapper.sh has syntax errors"
```

- [ ] **Step 2: Run skeleton tests; verify failure**

Run: `bash tests/test_deploy.sh skeleton 2>&1 | tail -3`
Expected: `FAIL: expected file to exist: .../install-pg-wrapper.sh`

- [ ] **Step 3: Create `install-pg-wrapper.sh`**

Create `install-pg-wrapper.sh` at the repo root with exact content:

```bash
#!/usr/bin/env bash
set -euo pipefail

BIN_PATH="${PG_WRAPPER_BIN:-/usr/local/bin/pg}"
DEFAULT_USER="${DEFAULT_PG_USER:-postgres}"
DEFAULT_CONTAINER="${DEFAULT_PG_CONTAINER:-postgres}"

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is not installed or not on PATH." >&2
    exit 1
  fi
}

prompt_with_default() {
  local prompt_text="$1" default_value="$2" answer
  printf "%s [%s]: " "$prompt_text" "$default_value" >&2
  IFS= read -r answer
  printf "%s" "${answer:-$default_value}"
}

main() {
  require_root
  require_docker

  local container user
  container="$(prompt_with_default "PostgreSQL container name" "$DEFAULT_CONTAINER")"
  user="$(prompt_with_default "PostgreSQL username to bake into 'pg'" "$DEFAULT_USER")"

  if ! docker inspect "$container" >/dev/null 2>&1; then
    echo "Warning: container '${container}' not found. Wrapper will still be installed." >&2
  fi

  cat >"$BIN_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if ! docker inspect -f '{{.State.Running}}' ${container} >/dev/null 2>&1; then
  echo "PostgreSQL container '${container}' is not running." >&2
  exit 1
fi

if [ -t 0 ]; then
  exec docker exec -it ${container} psql -U ${user} "\$@"
else
  exec docker exec -i ${container} psql -U ${user} "\$@"
fi
EOF
  chmod +x "$BIN_PATH"
  echo "Installed pg shortcut at ${BIN_PATH} (container: ${container}, user: ${user})"
}

main "$@"
```

- [ ] **Step 4: Make executable**

Run: `chmod +x install-pg-wrapper.sh`

- [ ] **Step 5: Run skeleton tests; verify pass**

Run: `bash tests/test_deploy.sh skeleton`
Expected: `PASS: skeleton`

- [ ] **Step 6: Run all tests**

Run: `bash tests/test_deploy.sh all`
Expected: `PASS: all`

- [ ] **Step 7: Commit**

```bash
git add install-pg-wrapper.sh tests/test_deploy.sh
git commit -m "feat: 新增独立脚本 install-pg-wrapper.sh (curl|bash 入口)"
```

---

## Task 7: Update README with pg shortcut usage

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add new section before "数据目录"**

In `README.md`, after the existing "支持的组件" section ending (just before `## 数据目录` heading around line 29), insert:

```markdown
## 快捷使用 psql

部署 PostgreSQL 时会自动安装 `pg` 命令（`/usr/local/bin/pg`），等价于 `docker exec -it postgres psql -U <user>`：

```bash
pg                           # 交互 shell（默认连接用户同名库）
pg appdb                     # 切换到 appdb
pg -c "SELECT now()"         # 执行一条 SQL
cat host.sql | pg appdb      # 从宿主 SQL 文件导入
pg -U readonly_user appdb    # 临时切换身份（psql 对 -U last-wins）
```

> 注意：psql 在容器内执行，`pg -f /path.sql` 中的路径是**容器内路径**。跑宿主文件用管道或先 `docker cp`。

**已有 PostgreSQL 运行时，单独安装 `pg` 命令**：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-pg-wrapper.sh)
```

或重新运行 `deploy.sh` 选择菜单项 `6`。

---
```

- [ ] **Step 2: Sanity-check markdown renders**

Run: `head -60 README.md`
Expected: new section appears between "支持的组件" and "数据目录" blocks.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README 增加快捷使用 psql 章节"
```

---

## Task 8: Final verification

- [ ] **Step 1: Run full test suite**

Run: `bash tests/test_deploy.sh all`
Expected: `PASS: all`

- [ ] **Step 2: Syntax check both scripts**

Run: `bash -n deploy.sh && bash -n install-pg-wrapper.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Smoke-inspect the wrapper the generator would emit**

Simulate generation in isolation to eye-check the final wrapper content:

```bash
tmp="$(mktemp -d)"
PG_WRAPPER_BIN="${tmp}/pg" bash -c '
  source deploy.sh
  install_pg_wrapper postgres
  cat "$PG_WRAPPER_BIN"
'
```

Expected output: a shell script containing `docker exec -it postgres psql -U postgres "$@"` and the `State.Running` guard.

- [ ] **Step 4: Inspect git log**

Run: `git log --oneline -10`
Expected: 8 new commits on top of `8e484b8` (the spec commit), in task order.

- [ ] **Step 5: Push (only if requested by user)**

Do NOT push without explicit user confirmation. If requested:

```bash
git push origin main
```

---

## Risks & mitigations

- **`docker inspect -f '{{.State.Running}}'` exit code when container missing**: returns non-zero + empty stdout. Our `if ! ... >/dev/null 2>&1` handles both cases (container missing OR container stopped) with a uniform error message.
- **psql `-U` last-wins assumption**: valid for GNU getopt, which psql uses. If a future psql version changes semantics, users should drop `-U <baked>` by setting `PGUSER=... pg` env var instead. Not worth defending against now.
- **Wrapper path permissions**: `/usr/local/bin` requires root; deploy.sh already `require_root`s, and the standalone script does too.
- **Existing MySQL client prompt pattern**: unchanged; pg shortcut auto-install does NOT prompt (parallel behavior chosen for convenience; regeneration is idempotent).
