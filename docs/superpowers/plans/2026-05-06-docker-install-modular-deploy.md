# Docker Install and Modular Deploy Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Docker-only one-click install path and split `deploy.sh` into focused Bash modules without breaking the existing interactive deployment behavior.

**Architecture:** Keep `deploy.sh` as a thin loader and interactive entrypoint, add `install-docker.sh` as a Docker-only entrypoint, and move current monolithic logic into `lib/*.sh` modules. Entrypoints load local modules when the repository is present and download modules from GitHub raw when run through curl process substitution.

**Tech Stack:** Bash, apt, Docker Engine official repository, Docker Compose plugin, existing `tests/test_deploy.sh` harness.

**Spec:** `docs/superpowers/specs/2026-05-06-docker-install-modular-deploy-design.md`

---

## File Structure

- Modify: `deploy.sh`
  - Replace the monolithic implementation with a module loader and direct `main "$@"` guard.
  - Preserve sourceable behavior for tests.

- Create: `install-docker.sh`
  - Docker-only entrypoint.
  - Uses the same module loader pattern as `deploy.sh`.
  - Calls `install_docker_main "$@"` when executed directly.

- Create: `lib/config.sh`
  - All environment-overridable paths, image tags, defaults, project names, and selection state.

- Create: `lib/common.sh`
  - Root/OS checks, command detection, prompt helpers, writable data-root check, directory creation, port checks, overwrite confirmation.

- Create: `lib/docker.sh`
  - Apt prerequisite installation and Docker Engine / Compose plugin installation.
  - Final Docker/Compose validation.

- Create: `lib/caddy.sh`
  - Caddy layout and Caddy package installation.

- Create: `lib/compose.sh`
  - Shared Docker network, compose up, compose down helpers.

- Create: `lib/pg-wrapper.sh`
  - `install_pg_wrapper`.

- Create: `lib/services/postgres.sh`
  - PostgreSQL compose generation, prompts, reinstall/migration, prepare flow.

- Create: `lib/services/mysql.sh`
  - MySQL client detection/install, config generation, init SQL, compose generation, prompts, reinstall, prepare flow.

- Create: `lib/services/rabbitmq.sh`
  - RabbitMQ config/plugin generation, compose generation, prompts, reinstall, prepare flow.

- Create: `lib/services/redis.sh`
  - Redis compose generation, prompts, prepare flow.

- Create: `lib/deploy-main.sh`
  - Menu rendering, selection parsing, main orchestration, summary.

- Modify: `tests/test_deploy.sh`
  - Add Docker-only behavior tests.
  - Add compatibility tests for public function surface.
  - Add syntax checks for `install-docker.sh` and modules.

- Modify: `README.md`
  - Document Docker-only install command.
  - Add Docker-only menu item.
  - Clarify that selecting deployable services still installs Docker automatically.

- No required change: `install-pg-wrapper.sh`
  - Keep self-contained.

---

## Chunk 1: Guardrail Tests for Docker-Only and Compatibility

### Task 1: Add failing tests for Docker-only selection and entrypoint existence

**Files:**
- Modify: `tests/test_deploy.sh`

- [ ] **Step 1: Extend `load_script` state reset**

In `tests/test_deploy.sh`, update the unset list in `load_script` to include the new selection state:

```bash
    SELECT_DOCKER SELECT_PG_WRAPPER INSTALLED_PG_WRAPPER_USER \
    LINUXSHELL_MODULE_ROOT LINUXSHELL_MODULE_SOURCE 2>/dev/null || true
```

- [ ] **Step 2: Add install-docker skeleton assertions**

In `run_skeleton_tests`, after the existing `install-pg-wrapper.sh` assertions, add:

```bash
  local docker_standalone="${ROOT_DIR}/install-docker.sh"
  assert_file_exists "$docker_standalone"
  [[ -x "$docker_standalone" ]] || fail "expected install-docker.sh to be executable"
  bash -n "$docker_standalone" || fail "install-docker.sh has syntax errors"
  assert_contains "$docker_standalone" "lib/docker.sh"
  assert_not_contains "$docker_standalone" "docker-ce docker-ce-cli"
```

- [ ] **Step 3: Add compatibility surface assertions**

Still in `run_skeleton_tests`, after `load_script`, replace the small function list with a loop:

```bash
  local expected_functions=(
    require_root detect_os ensure_data_root_writable ensure_directories
    configure_caddy_layout prompt_with_default prompt_yes_no
    parse_service_selection collect_service_selection has_mysql_client
    port_in_use assert_port_available confirm_overwrite
    write_postgres_compose get_postgres_major_version configure_postgres reinstall_postgres prepare_postgres
    write_mysql_config write_mysql_init_sql write_mysql_compose configure_mysql install_mysql_client reinstall_mysql prepare_mysql
    write_rabbitmq_compose write_rabbitmq_config write_rabbitmq_enabled_plugins configure_rabbitmq reinstall_rabbitmq prepare_rabbitmq
    write_redis_compose configure_redis prepare_redis
    install_pg_wrapper install_apt_dependencies install_docker install_caddy
    ensure_shared_network start_compose_file stop_compose_file
    show_summary main
  )

  local fn
  for fn in "${expected_functions[@]}"; do
    assert_function_exists "$fn"
  done
```

- [ ] **Step 4: Add Docker selection helper tests**

In `run_helper_tests`, after the existing `pg-shortcut` assertions, add:

```bash
  parse_service_selection "7"
  [[ "${SELECT_DOCKER:-0}" -eq 1 ]] || fail "expected docker selection from '7'"
  [[ "${SELECT_PG_WRAPPER:-0}" -eq 0 ]] || fail "did not expect pg wrapper selection from '7'"

  parse_service_selection "docker"
  [[ "${SELECT_DOCKER:-0}" -eq 1 ]] || fail "expected docker selection from 'docker'"
  [[ "${SELECT_CADDY:-0}" -eq 0 ]] || fail "did not expect caddy selection from 'docker'"
```

Update the menu output assertion:

```bash
  assert_output_contains "$selection_output" "7) Docker only"
```

- [ ] **Step 5: Add a Docker-only main-flow test**

Add a new test function before `main`:

```bash
run_docker_only_tests() {
  local temp_root
  local action_log
  temp_root="$(mktemp -d)"
  trap "rm -rf '$temp_root'" RETURN
  action_log="${temp_root}/actions.log"

  export DATA_ROOT="$temp_root"
  load_script

  require_root() { echo "require_root" >>"$action_log"; }
  detect_os() { echo "detect_os" >>"$action_log"; }
  ensure_data_root_writable() { echo "ensure_data_root_writable" >>"$action_log"; }
  ensure_directories() { echo "ensure_directories" >>"$action_log"; }
  collect_service_selection() {
    SELECT_DOCKER=1
    SELECT_CADDY=0
    SELECT_POSTGRES=0
    SELECT_MYSQL=0
    SELECT_RABBITMQ=0
    SELECT_REDIS=0
    SELECT_PG_WRAPPER=0
  }
  install_docker() { echo "install_docker" >>"$action_log"; }
  install_caddy() { echo "install_caddy" >>"$action_log"; }
  configure_postgres() { echo "configure_postgres" >>"$action_log"; }
  configure_mysql() { echo "configure_mysql" >>"$action_log"; }
  configure_rabbitmq() { echo "configure_rabbitmq" >>"$action_log"; }
  configure_redis() { echo "configure_redis" >>"$action_log"; }
  install_pg_wrapper() { echo "install_pg_wrapper" >>"$action_log"; }
  show_summary() { echo "show_summary" >>"$action_log"; }

  main

  assert_contains "$action_log" "install_docker"
  assert_contains "$action_log" "show_summary"
  assert_not_contains "$action_log" "install_caddy"
  assert_not_contains "$action_log" "configure_postgres"
  assert_not_contains "$action_log" "configure_mysql"
  assert_not_contains "$action_log" "configure_rabbitmq"
  assert_not_contains "$action_log" "configure_redis"
  assert_not_contains "$action_log" "install_pg_wrapper"
}
```

Add it to the suite dispatcher:

```bash
    docker-only)
      run_docker_only_tests
      ;;
```

And to the `all` suite after `run_helper_tests`:

```bash
      run_docker_only_tests
```

- [ ] **Step 6: Run tests and verify failure**

Run:

```bash
bash tests/test_deploy.sh skeleton
```

Expected: FAIL because `install-docker.sh` does not exist.

Run:

```bash
bash tests/test_deploy.sh helpers
```

Expected: FAIL because `SELECT_DOCKER` and menu item 7 do not exist.

Run:

```bash
bash tests/test_deploy.sh docker-only
```

Expected: FAIL because Docker-only main flow is not implemented.

- [ ] **Step 7: Keep the red tests uncommitted**

Do not commit this red state. Continue directly to the implementation tasks below, then commit once the new tests pass.

---

## Chunk 2: Loader, Config, Common, and Docker Module

### Task 2: Create initial modules and thin Docker-only entrypoint

**Files:**
- Create: `lib/config.sh`
- Create: `lib/common.sh`
- Create: `lib/docker.sh`
- Create: `install-docker.sh`
- Modify: `deploy.sh`

- [ ] **Step 1: Create `lib/config.sh` from current globals**

Move the current top-level variable block from `deploy.sh:5-86` into `lib/config.sh`, then add `SELECT_DOCKER=0`.

The selection block should be:

```bash
SELECT_CADDY=0
SELECT_POSTGRES=0
SELECT_MYSQL=0
SELECT_RABBITMQ=0
SELECT_REDIS=0
SELECT_PG_WRAPPER=0
SELECT_DOCKER=0
```

Keep all current environment override forms, for example:

```bash
DATA_ROOT="${DATA_ROOT:-/data}"
DOCKER_DIR="${DOCKER_DIR:-${DATA_ROOT}/docker}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18.3}"
PG_WRAPPER_BIN="${PG_WRAPPER_BIN:-/usr/local/bin/pg}"
```

- [ ] **Step 2: Create `lib/common.sh` from current shared helpers**

Move these functions from `deploy.sh` into `lib/common.sh`:

```bash
require_root
detect_os
command_exists
to_lower
print_step
ensure_data_root_writable
ensure_directories
prompt_with_default
prompt_yes_no
port_in_use
assert_port_available
confirm_overwrite
```

Do not include a `main` call. Do not add `set -euo pipefail`; entrypoints own strict mode.

- [ ] **Step 3: Create `lib/docker.sh`**

Move `install_apt_dependencies` and `install_docker` into `lib/docker.sh`.

Update `install_docker` so it validates after installation:

```bash
validate_docker_install() {
  if ! command_exists docker; then
    echo "Docker command is not available after installation." >&2
    return 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose plugin is not available after installation." >&2
    return 1
  fi
}
```

Call `validate_docker_install` both when Docker is already installed and after package installation:

```bash
install_docker() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    print_step "Docker and Docker Compose plugin already installed"
    validate_docker_install
    return 0
  fi

  print_step "Installing Docker"
  install_apt_dependencies
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/"$(. /etc/os-release && echo "$ID")"/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  . /etc/os-release
  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable
EOF

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  validate_docker_install
}
```

- [ ] **Step 4: Add a shared loader function to `deploy.sh`**

At the top of `deploy.sh`, keep strict mode and add:

```bash
LINUXSHELL_RAW_BASE_URL="${LINUXSHELL_RAW_BASE_URL:-https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main}"
LINUXSHELL_MODULE_ROOT=""
LINUXSHELL_MODULE_SOURCE=""

load_linuxshell_modules() {
  local script_dir
  local module_root
  local module

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || pwd)"
  module_root="$script_dir"

  if [[ -f "${module_root}/lib/config.sh" ]]; then
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
```

For this step, call only the modules that exist:

```bash
load_linuxshell_modules \
  lib/config.sh \
  lib/common.sh \
  lib/docker.sh
```

Leave the still-monolithic function definitions in `deploy.sh` temporarily. The duplicated definitions are removed in later chunks after their destination modules exist.

- [ ] **Step 5: Create `install-docker.sh`**

Use the same loader implementation as `deploy.sh`, but load only:

```bash
load_linuxshell_modules \
  lib/config.sh \
  lib/common.sh \
  lib/docker.sh
```

Add:

```bash
install_docker_main() {
  require_root
  detect_os
  install_docker
  print_step "Docker installation summary"
  docker --version
  docker compose version
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  install_docker_main "$@"
fi
```

Set executable bit:

```bash
chmod +x install-docker.sh
```

- [ ] **Step 6: Run focused tests**

Run:

```bash
bash tests/test_deploy.sh skeleton
bash -n deploy.sh
bash -n install-docker.sh
bash -n lib/config.sh
bash -n lib/common.sh
bash -n lib/docker.sh
```

Expected: `skeleton` passes because `install-docker.sh` exists and public functions are still sourceable. `helpers` and `docker-only` remain red until Task 3.

- [ ] **Step 7: Keep changes uncommitted**

Do not commit yet because the Task 1 Docker selection tests are still red. Continue to Task 3 and commit after the new behavior is green.

### Task 3: Implement Docker-only selection in the current main flow

**Files:**
- Modify: `deploy.sh`
- Test: `tests/test_deploy.sh`

- [ ] **Step 1: Update selection parsing**

In the current `parse_service_selection` implementation, reset `SELECT_DOCKER=0` and add:

```bash
      7|docker)
        SELECT_DOCKER=1
        ;;
```

- [ ] **Step 2: Update the menu**

In `collect_service_selection`, append:

```text
  7) Docker only
```

Update the valid-selection condition:

```bash
if (( SELECT_CADDY || SELECT_POSTGRES || SELECT_MYSQL || SELECT_RABBITMQ || SELECT_REDIS || SELECT_PG_WRAPPER || SELECT_DOCKER )); then
```

- [ ] **Step 3: Update `main` Docker install condition**

Change:

```bash
if (( SELECT_CADDY || SELECT_POSTGRES || SELECT_MYSQL || SELECT_RABBITMQ || SELECT_REDIS )); then
  install_docker
fi
```

to:

```bash
if (( SELECT_DOCKER || SELECT_CADDY || SELECT_POSTGRES || SELECT_MYSQL || SELECT_RABBITMQ || SELECT_REDIS )); then
  install_docker
fi
```

- [ ] **Step 4: Update `show_summary`**

Add:

```bash
if (( SELECT_DOCKER )); then
  echo "Docker and Docker Compose plugin installed."
fi
```

- [ ] **Step 5: Run RED-to-GREEN tests**

Run:

```bash
bash tests/test_deploy.sh skeleton
bash tests/test_deploy.sh helpers
bash tests/test_deploy.sh docker-only
bash tests/test_deploy.sh all
bash -n deploy.sh
bash -n install-docker.sh
bash -n lib/config.sh
bash -n lib/common.sh
bash -n lib/docker.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add deploy.sh install-docker.sh lib/config.sh lib/common.sh lib/docker.sh tests/test_deploy.sh
git commit -m "feat: 新增 Docker-only 安装入口与基础模块"
```

---

## Chunk 3: Extract Service and Support Modules

### Task 4: Extract Caddy, Compose, and pg-wrapper modules

**Files:**
- Create: `lib/caddy.sh`
- Create: `lib/compose.sh`
- Create: `lib/pg-wrapper.sh`
- Modify: `deploy.sh`

- [ ] **Step 1: Update `deploy.sh` loader list**

Add these modules to the `load_linuxshell_modules` call:

```bash
  lib/caddy.sh \
  lib/compose.sh \
  lib/pg-wrapper.sh
```

- [ ] **Step 2: Move Caddy functions**

Move from `deploy.sh` into `lib/caddy.sh`:

```bash
configure_caddy_layout
install_caddy
```

- [ ] **Step 3: Move compose functions**

Move from `deploy.sh` into `lib/compose.sh`:

```bash
ensure_shared_network
start_compose_file
stop_compose_file
```

- [ ] **Step 4: Move pg wrapper function**

Move from `deploy.sh` into `lib/pg-wrapper.sh`:

```bash
install_pg_wrapper
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
bash tests/test_deploy.sh skeleton
bash tests/test_deploy.sh generation
bash tests/test_deploy.sh smoke
bash -n lib/caddy.sh
bash -n lib/compose.sh
bash -n lib/pg-wrapper.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add deploy.sh lib/caddy.sh lib/compose.sh lib/pg-wrapper.sh
git commit -m "refactor: 拆分 Caddy Compose 与 pg wrapper 模块"
```

### Task 5: Extract PostgreSQL module

**Files:**
- Create: `lib/services/postgres.sh`
- Modify: `deploy.sh`

- [ ] **Step 1: Update loader list**

Add:

```bash
  lib/services/postgres.sh
```

- [ ] **Step 2: Move PostgreSQL functions**

Move from `deploy.sh` into `lib/services/postgres.sh`:

```bash
write_postgres_compose
get_postgres_major_version
configure_postgres
reinstall_postgres
prepare_postgres
```

- [ ] **Step 3: Run focused tests**

Run:

```bash
bash tests/test_deploy.sh generation
bash tests/test_deploy.sh smoke
bash -n lib/services/postgres.sh
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add deploy.sh lib/services/postgres.sh
git commit -m "refactor: 拆分 PostgreSQL 部署模块"
```

### Task 6: Extract MySQL module

**Files:**
- Create: `lib/services/mysql.sh`
- Modify: `deploy.sh`

- [ ] **Step 1: Update loader list**

Add:

```bash
  lib/services/mysql.sh
```

- [ ] **Step 2: Move MySQL functions**

Move from `deploy.sh` into `lib/services/mysql.sh`:

```bash
has_mysql_client
write_mysql_config
write_mysql_init_sql
write_mysql_compose
configure_mysql
install_mysql_client
reinstall_mysql
prepare_mysql
```

- [ ] **Step 3: Run focused tests**

Run:

```bash
bash tests/test_deploy.sh helpers
bash tests/test_deploy.sh generation
bash tests/test_deploy.sh smoke
bash -n lib/services/mysql.sh
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add deploy.sh lib/services/mysql.sh
git commit -m "refactor: 拆分 MySQL 部署模块"
```

### Task 7: Extract RabbitMQ and Redis modules

**Files:**
- Create: `lib/services/rabbitmq.sh`
- Create: `lib/services/redis.sh`
- Modify: `deploy.sh`

- [ ] **Step 1: Update loader list**

Add:

```bash
  lib/services/rabbitmq.sh \
  lib/services/redis.sh
```

- [ ] **Step 2: Move RabbitMQ functions**

Move from `deploy.sh` into `lib/services/rabbitmq.sh`:

```bash
write_rabbitmq_compose
write_rabbitmq_config
write_rabbitmq_enabled_plugins
configure_rabbitmq
reinstall_rabbitmq
prepare_rabbitmq
```

- [ ] **Step 3: Move Redis functions**

Move from `deploy.sh` into `lib/services/redis.sh`:

```bash
write_redis_compose
configure_redis
prepare_redis
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
bash tests/test_deploy.sh generation
bash tests/test_deploy.sh smoke
bash -n lib/services/rabbitmq.sh
bash -n lib/services/redis.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add deploy.sh lib/services/rabbitmq.sh lib/services/redis.sh
git commit -m "refactor: 拆分 RabbitMQ 与 Redis 部署模块"
```

---

## Chunk 4: Extract Main Orchestration and Make `deploy.sh` Thin

### Task 8: Move menu, parser, summary, and main to `lib/deploy-main.sh`

**Files:**
- Create: `lib/deploy-main.sh`
- Modify: `deploy.sh`

- [ ] **Step 1: Update loader list**

Add `lib/deploy-main.sh` as the last loaded module.

Load order should be:

```bash
load_linuxshell_modules \
  lib/config.sh \
  lib/common.sh \
  lib/docker.sh \
  lib/caddy.sh \
  lib/compose.sh \
  lib/pg-wrapper.sh \
  lib/services/postgres.sh \
  lib/services/mysql.sh \
  lib/services/rabbitmq.sh \
  lib/services/redis.sh \
  lib/deploy-main.sh
```

- [ ] **Step 2: Move orchestration functions**

Move from `deploy.sh` into `lib/deploy-main.sh`:

```bash
parse_service_selection
collect_service_selection
show_summary
main
```

Ensure `parse_service_selection` includes Docker support:

```bash
SELECT_DOCKER=0

case "$normalized" in
  1|caddy) SELECT_CADDY=1 ;;
  2|postgres|postgresql) SELECT_POSTGRES=1 ;;
  3|mysql) SELECT_MYSQL=1 ;;
  4|rabbitmq) SELECT_RABBITMQ=1 ;;
  5|redis) SELECT_REDIS=1 ;;
  6|pg|pg-shortcut) SELECT_PG_WRAPPER=1 ;;
  7|docker) SELECT_DOCKER=1 ;;
  *) echo "Ignoring unknown selection: $token" >&2 ;;
esac
```

- [ ] **Step 3: Reduce `deploy.sh` to loader plus guard**

After extraction, `deploy.sh` should contain only:

- shebang
- strict mode
- raw base URL default
- `LINUXSHELL_MODULE_ROOT` / `LINUXSHELL_MODULE_SOURCE`
- `load_linuxshell_modules`
- module list call
- `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi`

Use:

```bash
wc -l deploy.sh
```

Expected: much smaller than the original 879 lines, ideally under 120 lines.

- [ ] **Step 4: Run full tests**

Run:

```bash
bash tests/test_deploy.sh all
bash -n deploy.sh
bash -n lib/deploy-main.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add deploy.sh lib/deploy-main.sh
git commit -m "refactor: deploy.sh 收敛为模块化入口"
```

---

## Chunk 5: Loader Coverage, Docs, and Final Verification

### Task 9: Add loader-specific tests and module syntax checks

**Files:**
- Modify: `tests/test_deploy.sh`

- [ ] **Step 1: Add local loader assertions**

Add a test function:

```bash
run_loader_tests() {
  load_script
  assert_equals "local" "${LINUXSHELL_MODULE_SOURCE:-}"
  assert_equals "$ROOT_DIR" "${LINUXSHELL_MODULE_ROOT:-}"
}
```

Add `loader` to the suite dispatcher and call `run_loader_tests` from `all`.

- [ ] **Step 2: Add module syntax checks to skeleton tests**

In `run_skeleton_tests`, add:

```bash
  local module
  while IFS= read -r module; do
    bash -n "$module" || fail "module has syntax errors: $module"
  done < <(find "${ROOT_DIR}/lib" -name '*.sh' -type f | sort)
```

- [ ] **Step 3: Run RED-to-GREEN tests**

Run:

```bash
bash tests/test_deploy.sh loader
bash tests/test_deploy.sh skeleton
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add tests/test_deploy.sh
git commit -m "test: 覆盖模块加载与语法检查"
```

### Task 10: Update README for Docker-only install

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add Docker-only one-click command**

After the existing one-click install section, add:

````markdown
## 仅安装 Docker

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-docker.sh)
```

该入口只安装 Docker Engine 与 Docker Compose plugin。完整部署仍使用 `deploy.sh`。
````

- [ ] **Step 2: Update component table**

Keep existing numeric service selections and append:

```markdown
| 7 | Docker only | — |
```

- [ ] **Step 3: Clarify automatic Docker installation**

Add a short note near the supported components section:

```markdown
选择 Caddy 或任意容器服务时，脚本会自动确保 Docker 与 Docker Compose plugin 已安装；不需要额外选择 Docker only。
```

- [ ] **Step 4: Run documentation check**

Run:

```bash
rg -n "install-docker|Docker only|7 \\| Docker" README.md
```

Expected: output shows the new command, menu item, and table row.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: README 增加 Docker-only 安装说明"
```

### Task 11: Final verification

**Files:**
- No code changes unless verification finds an issue.

- [ ] **Step 1: Run full shell test suite**

Run:

```bash
bash tests/test_deploy.sh all
```

Expected: `PASS: all`.

- [ ] **Step 2: Run syntax checks**

Run:

```bash
bash -n deploy.sh
bash -n install-docker.sh
bash -n install-pg-wrapper.sh
find lib -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

Expected: all commands exit 0.

- [ ] **Step 3: Verify `deploy.sh` size reduction**

Run:

```bash
wc -l deploy.sh
```

Expected: `deploy.sh` is under 120 lines.

- [ ] **Step 4: Verify Docker install implementation is not duplicated**

Run:

```bash
rg -n "docker-ce docker-ce-cli|install_docker\\(" deploy.sh install-docker.sh lib
```

Expected:

- Docker package list appears in `lib/docker.sh`.
- `install_docker()` is defined only in `lib/docker.sh`.
- Entrypoints only load modules and call module functions.

- [ ] **Step 5: Inspect git diff**

Run:

```bash
git status --short
git diff --stat HEAD
```

Expected: only intended files changed.

- [ ] **Step 6: Final commit if any verification fixes were needed**

If final verification required fixes:

```bash
git add <fixed-files>
git commit -m "fix: 修正 Docker-only 模块化部署验证问题"
```

---

## Execution Notes

- Use `apply_patch` for manual edits.
- Do not change default images, ports, credentials, network name, or generated compose content while refactoring.
- Keep module files source-only; no module should call `main`.
- Keep the current `source deploy.sh` testing model working throughout.
- If a function depends on globals, load `lib/config.sh` before the function's module.
- If a test failure appears after moving a function, first check module load order before changing behavior.
- Run focused tests after every extraction task; do not wait for the final suite to discover a broken move.
