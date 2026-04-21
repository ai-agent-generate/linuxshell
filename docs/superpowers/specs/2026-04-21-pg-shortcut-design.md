# `pg` 快捷命令设计

为容器化部署的 PostgreSQL 提供命令行快捷入口，消除每次敲 `docker exec -it postgres psql ...` 的重复劳动。

## 目标与非目标

**目标**
- 在 `/usr/local/bin/pg` 生成一个薄 wrapper，等价于 `docker exec -i[t] postgres psql -U <user> [args...]`。
- 两种安装入口：
  1. 新装 PostgreSQL：通过 `deploy.sh` 自动安装。
  2. 已有 PostgreSQL：`deploy.sh` 菜单选项 6，或独立脚本 `install-pg-wrapper.sh`（curl|bash 友好）。
- 透传所有 `psql` 参数，默认不指定数据库。
- 自动识别 TTY（`echo "SELECT 1" | pg` 与交互式 `pg` 都工作）。
- 容器未运行时明确报错。

**非目标**
- 不安装宿主 `postgresql-client`。
- 不配置 `.pgpass` 免密（走 `docker exec` 不需要密码）。
- 不为 `pg_dump` / `pg_restore` 提供 wrapper。
- 不提供卸载逻辑（`rm /usr/local/bin/pg` 即可）。

## Wrapper 脚本内容

生成在 `/usr/local/bin/pg`（可通过 `PG_WRAPPER_BIN` 环境变量覆盖，便于测试）：

```bash
#!/usr/bin/env bash
set -euo pipefail

if ! docker inspect -f '{{.State.Running}}' postgres >/dev/null 2>&1; then
  echo "PostgreSQL container 'postgres' is not running." >&2
  exit 1
fi

if [ -t 0 ]; then
  exec docker exec -it postgres psql -U <BAKED_USER> "$@"
else
  exec docker exec -i postgres psql -U <BAKED_USER> "$@"
fi
```

说明：
- **容器名**：deploy.sh 流程内固定为 `postgres`（与 compose `container_name: postgres` 一致）；独立脚本允许在安装时选择其他容器名。
- **`-U <BAKED_USER>`**：安装时把用户烘进脚本。用户可 `pg -U other` 临时覆盖（psql 对 `-U` 选项 last-wins）。
- **不指定 `-d`**：默认连接与用户同名的库；连业务库用 `pg appdb` 或 `pg -d appdb`。
- **`-it` vs `-i`**：`[ -t 0 ]` 判断 stdin 是否 TTY，避免管道下 `the input device is not a TTY` 报错。
- **运行态检查**：`docker inspect -f '{{.State.Running}}'` 返回 `true`/`false`/退出码非 0（容器不存在）。

## 使用方式

```bash
pg                              # 进入 postgres 用户默认库的交互 shell
pg appdb                        # 切到 appdb
pg -c "SELECT now()"            # 执行一条 SQL
cat host.sql | pg appdb         # 从宿主 SQL 文件导入（管道）
echo "SELECT 1" | pg            # 管道模式，自动走 -i
pg -U readonly_user appdb       # 临时以其他身份连接
```

注意：psql 在容器内执行，因此 `pg -f /path.sql` 的 `/path.sql` 是**容器内路径**。要跑宿主文件用管道（`cat host.sql | pg`）或先 `docker cp host.sql postgres:/tmp/` 再 `pg -f /tmp/host.sql`。

## `deploy.sh` 集成

### 新增状态变量与函数

```bash
SELECT_PG_WRAPPER=0
PG_WRAPPER_BIN="${PG_WRAPPER_BIN:-/usr/local/bin/pg}"

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
  echo "Installed pg shortcut at ${PG_WRAPPER_BIN} (user: ${user})"
}
```

### 菜单与解析修改

`collect_service_selection` 的 heredoc 追加：
```
  6) Install pg shortcut (PostgreSQL already running)
```

`parse_service_selection` case 语句加：
```bash
6|pg|pg-shortcut)
  SELECT_PG_WRAPPER=1
  ;;
```

`collect_service_selection` 退出条件 `(( SELECT_CADDY || ... || SELECT_REDIS ))` 末尾加 `|| SELECT_PG_WRAPPER`。

### main 调用点

```bash
if (( SELECT_POSTGRES )); then
  configure_postgres
  prepare_postgres
  install_pg_wrapper "$POSTGRES_USER"
fi

# ... 其他服务 ...

if (( SELECT_PG_WRAPPER && ! SELECT_POSTGRES )); then
  local wrapper_user
  wrapper_user="$(prompt_with_default "PostgreSQL username to bake into 'pg'" "postgres")"
  install_pg_wrapper "$wrapper_user"
fi
```

- 选 2（PostgreSQL）时：`prepare_postgres` 后自动安装 wrapper，用户名取 `$POSTGRES_USER`。
- 仅选 6 时：prompt 用户名（默认 `postgres`），然后生成 wrapper。
- 同时选 2 和 6：以 2 的逻辑为准，6 的分支因 `&& ! SELECT_POSTGRES` 短路跳过，避免重复 prompt。
- 仅选 6 路径不调用 `install_docker`、`configure_postgres`、`prepare_postgres`（假设用户已有运行中的 PG）。

### `show_summary` 扩展

若 `install_pg_wrapper` 被调用，追加：
```
pg shortcut: /usr/local/bin/pg (user: ${WRAPPER_USER})
```

用一个顶层变量 `INSTALLED_PG_WRAPPER_USER` 在 `install_pg_wrapper` 内设置，`show_summary` 检查非空后输出。

## 独立脚本 `install-pg-wrapper.sh`

自包含 ~40 行，不依赖 deploy.sh。放在仓库根目录。

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

**与 deploy.sh 内函数的差异**：
- 额外问容器名（独立用户可能容器名不同）。
- 独立 `require_docker` 检查（deploy.sh 流程里 docker 已装）。

## README 更新

新增章节「快捷使用 psql」：

```markdown
## 快捷使用 psql

部署 PostgreSQL 时自动安装 `pg` 命令，等价于 `docker exec -it postgres psql -U <user>`：

```bash
pg                         # 交互 shell
pg appdb                   # 切到 appdb
pg -c "SELECT now()"       # 执行一条 SQL
echo "SELECT 1" | pg       # 管道
```

已有 PostgreSQL 运行时，单独安装 `pg` 命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-pg-wrapper.sh)
```

或重新运行 `deploy.sh` 并选择菜单项 6。
```

## 测试

### `tests/test_deploy.sh` 改动

**`run_helper_tests`** 追加：
```bash
assert_function_exists "install_pg_wrapper"

parse_service_selection "6"
[[ "${SELECT_PG_WRAPPER:-0}" -eq 1 ]] || fail "expected pg wrapper selection from '6'"

parse_service_selection "pg"
[[ "${SELECT_PG_WRAPPER:-0}" -eq 1 ]] || fail "expected pg wrapper selection from 'pg'"

parse_service_selection "1"
[[ "${SELECT_PG_WRAPPER:-0}" -eq 0 ]] || fail "did not expect pg wrapper selection from '1'"
```

**`run_generation_tests`** 追加（在 `temp_root` scope 内）：
```bash
export PG_WRAPPER_BIN="${temp_root}/usr/local/bin/pg"
mkdir -p "$(dirname "$PG_WRAPPER_BIN")"

install_pg_wrapper "alice"

assert_file_exists "$PG_WRAPPER_BIN"
[[ -x "$PG_WRAPPER_BIN" ]] || fail "expected pg wrapper to be executable"
assert_contains "$PG_WRAPPER_BIN" "docker exec -it postgres psql -U alice"
assert_contains "$PG_WRAPPER_BIN" "docker exec -i postgres psql -U alice"
assert_contains "$PG_WRAPPER_BIN" "container 'postgres' is not running"
```

### 独立脚本测试

只做语法检查，避免 mock docker/root：
```bash
bash -n "${ROOT_DIR}/install-pg-wrapper.sh"
```
放入 `run_skeleton_tests` 或新建 `run_standalone_tests`。

### `load_script` unset 列表

在测试框架 `load_script` 函数的 unset 列表加入 `SELECT_PG_WRAPPER PG_WRAPPER_BIN`，保证测试独立性。

## 实现清单

按顺序：
1. deploy.sh：加 `install_pg_wrapper` 函数、状态变量、菜单项、parse case、main 分支、show_summary 行。
2. 新建 `install-pg-wrapper.sh`，`chmod +x`。
3. tests/test_deploy.sh：扩充 helper / generation / skeleton。
4. 跑 `bash tests/test_deploy.sh all` 确认全绿。
5. README.md：加「快捷使用 psql」章节。
6. 提交。

## 取舍记录

- **硬编码容器名为 `postgres` 而非参数化**：deploy.sh 的 compose 文件固定 `container_name: postgres`，没有必要参数化。独立脚本因为面向已有环境所以允许选。
- **不走 `confirm_overwrite`**：与现有 compose 生成行为一致，重跑即刷新。
- **独立脚本不复用 deploy.sh 函数**：避免为 40 行脚本拉进整个 deploy.sh 的依赖与状态；复制成本低于共享成本。
- **last-wins 靠 psql 语义**：不在 wrapper 里做复杂的参数预处理来避免重复 `-U`。
