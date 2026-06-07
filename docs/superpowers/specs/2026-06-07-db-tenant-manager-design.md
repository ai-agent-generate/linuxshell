# 数据库多租户管理脚本设计（MySQL / PostgreSQL）

- 日期：2026-06-07
- 状态：设计待评审
- 入口：`db-tenant.sh`
- 模块：`lib/db-tenant/`

## 1. 背景与目标

`linuxshell` 已能部署 MySQL / PostgreSQL（Docker 形态与非 Docker HA 形态）。
现需要一个**日常租户管理工具**，能够：

- 创建角色并绑定数据库（一租户 = 一库一角色）。
- 对角色施加**账号级资源限制**，避免某个多租户应用瞬时爆发把连接、慢查询、排序内存占满，拖垮同实例的其他租户。
- 覆盖租户的完整生命周期：创建 / 列出 / 改限额 / 改密码 / 备份 / 删除。

### 能力边界（必须先对齐的现实）

MySQL / PostgreSQL 在**单实例共享进程**模型下（所有租户连接共用同一个 `mysqld` / `postgres`
进程），**没有**按角色切分 CPU / 内存 / IO 的硬隔离能力。本工具实现的是数据库**原生账号级软隔离 /
限流**，足以防住「连接打满 / 慢查询拖垮 / 大排序吃爆内存」这类相互拖累，但**不是** CPU/IO 硬配额。
真正的硬隔离需要「每租户独立实例」，属于另一种架构，不在本设计范围。

## 2. 范围

### 目标

- 双引擎：MySQL 与 PostgreSQL，共用同一套「租户 = 库 + 角色 + 限额」模型。
- 自动探测部署形态：同名容器在运行 → `docker exec`；否则 → 本机 socket / 客户端。
- 纯交互菜单（跑法同 `deploy.sh`）。
- 账号级资源限制（详见 §6）。
- 删除前**先成功备份数据库再删除**，备份失败则中止删除。

### 非目标

- CPU / 内存 / IO 硬隔离（需独立实例 / cgroup）。
- 代理层限流（PgBouncer / ProxySQL）。
- 每租户独立实例、跨主机编排。
- 自动恢复命令（仅打印恢复提示）、备份轮转 / 保留策略、定时备份。
- 角色与库的多对多管理（固定 1:1 模型）。

## 3. 名词与租户模型

- **租户（tenant）**：一个逻辑隔离单元，对应「一个数据库 + 一个登录角色」。
- **租户名**：即角色名，校验 `^[a-z][a-z0-9_]*$`，长度 ≤ 63（PG）/ 64（MySQL）。
- **库名**：默认等于租户名，可覆盖。
- **MySQL host**：账号的来源限定（`user`@`host`），默认 `%`，可配（如 `10.0.0.%`）。
- 模型固定为 **1 租户 = 1 库 + 1 角色**；角色权限只限于自己的库。
  - PG：角色拥有（OWNER）该库，自给自足。
  - MySQL：`GRANT ALL PRIVILEGES ON \`db\`.* TO 'user'@'host'`。

## 4. 总体架构

采用「单入口 + 引擎后端 + 统一动词接口」。

```
db-tenant.sh                 # 入口：load_linuxshell_modules + 调 db_tenant_main
lib/db-tenant/config.sh      # 默认限额、容器名、备份目录、系统名 denylist（均可环境变量覆盖）
lib/db-tenant/common.sh      # 菜单、标识符校验、denylist、密码生成、连接探测分发、只读检测、备份目录准备
lib/db-tenant/pg.sh          # PostgreSQL 后端：SQL builder（纯函数）+ exec + 动词
lib/db-tenant/mysql.sh       # MySQL 后端：同上
lib/db-tenant/main.sh        # 引擎选择 + 动作菜单 + 分发
tests/test_db_tenant.sh      # 语法 / 函数存在 / SQL 生成 / 校验 / denylist / 备份失败不删除
```

模块加载顺序（入口与测试保持一致）：
`lib/common.sh → lib/db-tenant/config.sh → lib/db-tenant/common.sh → lib/db-tenant/pg.sh →
lib/db-tenant/mysql.sh → lib/db-tenant/main.sh`。

### 统一动词接口

每个引擎后端实现同名前缀（`pg_` / `mysql_`）的同一组函数，便于 `main.sh` 分发：

- `<e>_detect_target`：判定 docker / local，准备连接所需上下文。
- `<e>_assert_writable`：HA 只读检测（standby/replica 则中止）。
- `<e>_exec_sql`：把 SQL 喂给对应客户端（凭据不进 argv）。
- `<e>_build_create_tenant_sql` / `<e>_build_set_limit_sql` / `<e>_build_set_password_sql` /
  `<e>_build_drop_sql`：**纯函数**，只产出 SQL 字符串，便于测试。
- `<e>_create_tenant` / `<e>_list_tenants` / `<e>_set_limit` / `<e>_set_password` /
  `<e>_backup_tenant` / `<e>_drop_tenant`：动作编排。

菜单层级：先选引擎（1=PostgreSQL / 2=MySQL）→ 自动探测并显示目标 → 动作菜单
（1 建租户 / 2 列出 / 3 改限额 / 4 改密码 / 5 备份 / 6 删除 / 0 退出）。

## 5. 连接探测与管理员凭据（自动探测）

| 引擎 | 容器形态 | 本机形态 |
|---|---|---|
| PostgreSQL | `docker exec -i <容器> psql -U postgres`（容器内 trust） | 以 root 跑 `sudo -u postgres psql`（peer 认证，免密） |
| MySQL | `docker exec -e MYSQL_PWD=… -i <容器> mysql -uroot`（密码走 env，不进 argv） | 临时 600 `--defaults-extra-file` 走本机 socket（同既有 `_mysql_root_exec` 模式） |

- 容器探测：`docker inspect -f '{{.State.Running}}' <容器>` 为 `true` 即 docker 形态。
- 容器名默认 `postgres` / `mysql`，可经 `DB_TENANT_PG_CONTAINER` / `DB_TENANT_MYSQL_CONTAINER` 覆盖。
- MySQL root 密码取自 `MYSQL_ADMIN_PASSWORD`，缺省时隐藏输入提示（`read -rs`）。
- PG 管理侧基本免密；MySQL 必须有 root 密码。
- **HA 只读保护**（写操作前，含备份前——避免在 standby 上白备份后才发现不能删）：
  - PG：`SELECT pg_is_in_recovery();` 为 `t` → 中止，提示「当前为 standby，请在 leader 上运行」。
  - MySQL：`SELECT @@global.super_read_only, @@global.read_only;` 任一为 1 → 中止，提示在 primary 上运行。

## 6. 资源限制参数集（核心）

### PostgreSQL（角色级 + 库级）

| 项 | 落地 SQL | 默认（config 可覆盖） |
|---|---|---|
| 并发连接上限 | `CREATE/ALTER ROLE "r" CONNECTION LIMIT n` | 20 |
| 库级连接上限 | `ALTER DATABASE "db" CONNECTION LIMIT m` | 20 |
| 单语句超时 | `ALTER ROLE "r" SET statement_timeout = '30s'` | 30s（0 = 不限） |
| 空闲事务超时 | `ALTER ROLE "r" SET idle_in_transaction_session_timeout = '60s'` | 60s |
| 单会话排序内存 | `ALTER ROLE "r" SET work_mem = '16MB'` | 16MB |

### MySQL（账号级）

| 项 | 落地 SQL（`CREATE/ALTER USER … WITH`） | 默认 |
|---|---|---|
| 并发连接上限 | `MAX_USER_CONNECTIONS n` | 20 |
| 每小时新建连接 | `MAX_CONNECTIONS_PER_HOUR a` | 0 = 不限 |
| 每小时查询数 | `MAX_QUERIES_PER_HOUR q` | 0 = 不限 |
| 每小时更新数 | `MAX_UPDATES_PER_HOUR u` | 0 = 不限 |

> 能力差异（写入 README）：MySQL **没有账号级语句超时**；`max_execution_time` 仅对 SELECT 生效且为
> 全局/会话级，按租户设置会波及所有人，故本工具**不**设置全局超时。PG 的 `statement_timeout` 才是
> 账号级生效。

## 7. 各动作流程

所有写操作前先 `<e>_assert_writable`。标识符一律白名单校验并加引号（PG `"…"`、MySQL `` `…` ``）。
密码默认用 `openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-25` 生成（沿用既有做法，去特殊字符规避
SQL 转义）；用户手填时对单引号做加倍转义。

### 7.1 建租户（create）

输入：租户名、库名（默认=租户名）、MySQL host（默认 `%`）、各限额（带默认）、密码（默认生成）。

- PG（`CREATE DATABASE` 不能在事务块内、无 `IF NOT EXISTS`，故 exec 层先查存在性再决定 create/alter）：
  1. 角色不存在 → `CREATE ROLE "r" LOGIN PASSWORD '…' CONNECTION LIMIT n`；存在 → `ALTER ROLE … CONNECTION LIMIT n`。
  2. 库不存在 → `CREATE DATABASE "db" OWNER "r" CONNECTION LIMIT m`；存在 → `ALTER DATABASE … OWNER … CONNECTION LIMIT …`。
  3. 收紧（可选默认开）：`REVOKE CONNECT ON DATABASE "db" FROM PUBLIC; GRANT CONNECT ON DATABASE "db" TO "r";`
  4. 套限额：`ALTER ROLE "r" SET statement_timeout / idle_in_transaction_session_timeout / work_mem`。
- MySQL：
  1. `CREATE DATABASE IF NOT EXISTS \`db\` CHARACTER SET utf8mb4;`
  2. `CREATE USER IF NOT EXISTS 'u'@'host' IDENTIFIED BY '…' WITH MAX_USER_CONNECTIONS n MAX_CONNECTIONS_PER_HOUR a MAX_QUERIES_PER_HOUR q MAX_UPDATES_PER_HOUR u;`
  3. `GRANT ALL PRIVILEGES ON \`db\`.* TO 'u'@'host';`
- 结尾打印摘要：引擎 / 库 / 角色（MySQL 含 @host）/ 密码（仅此一次）/ 连接示例 / 已套限额；可选写入 600 文件。

### 7.2 列出（list）—— 基于 catalog 实时查询，无状态文件

- PG：
  ```sql
  SELECT d.datname AS db, r.rolname AS role, r.rolconnlimit, d.datconnlimit
  FROM pg_database d JOIN pg_roles r ON d.datdba = r.oid
  WHERE NOT r.rolsuper AND d.datname NOT IN ('postgres','template0','template1')
  ORDER BY d.datname;
  ```
  再叠加 `pg_db_role_setting`（statement_timeout / work_mem 等角色级 SET）格式化展示。
- MySQL：
  ```sql
  SELECT user, host, max_user_connections, max_connections, max_questions, max_updates
  FROM mysql.user WHERE user NOT IN (<denylist>);
  ```
  以 `mysql.db` 关联出每个账号绑定的库。
- 限额**一律从 catalog 实时读取**，不维护会漂移的副本。

### 7.3 改限额（set-limit）

- PG：`ALTER ROLE "r" CONNECTION LIMIT …; ALTER DATABASE "db" CONNECTION LIMIT …; ALTER ROLE "r" SET …;`
- MySQL：`ALTER USER 'u'@'host' WITH MAX_USER_CONNECTIONS … MAX_CONNECTIONS_PER_HOUR … MAX_QUERIES_PER_HOUR … MAX_UPDATES_PER_HOUR …;`
- 先读当前值作为默认回填，幂等。

### 7.4 改密码（set-password）

- PG：`ALTER ROLE "r" PASSWORD '…';`
- MySQL：`ALTER USER 'u'@'host' IDENTIFIED BY '…';`

### 7.5 备份（backup）

可单独触发，也被删除流程复用。备份**仅数据库**（角色 / 限额定义不在备份内——需要时手动重建）。

- 目录：`${DB_TENANT_BACKUP_DIR:-/var/backups/db-tenant}`，目录 700、文件 600；先校验可写。
- 时间戳：`date +%Y%m%d-%H%M%S`。
- PG：`pg_dump -Fc`（自定义压缩格式，便于 `pg_restore`）。
  - docker：`docker exec <容器> pg_dump -U postgres -Fc -d "db"` > 文件（**不带 `-t`**，避免 TTY 破坏二进制流）。
  - 本机：`sudo -u postgres pg_dump -Fc -d "db"` > 文件。
  - 文件名 `pg-<db>-<时间戳>.dump`。
- MySQL：`mysqldump --single-transaction --routines --triggers --events --databases "db" | gzip`。
  - docker：`docker exec -e MYSQL_PWD=… <容器> mysqldump … | gzip` > 文件。
  - 本机：`mysqldump --defaults-extra-file=<临时> … | gzip` > 文件。
  - 文件名 `mysql-<db>-<时间戳>.sql.gz`。
- **校验**：退出码为 0 且文件非空（`set -o pipefail` 下 `mysqldump` 失败会让整条管道失败）。
- 打印备份路径 + 大小，以及恢复提示。

### 7.6 删除（drop）—— 备份 → 校验 → 再删除

1. `<e>_assert_writable`（HA 只读先行中止）。
2. denylist 拦截系统库 / 角色。
3. 调 `<e>_backup_tenant` 执行备份。
4. **校验备份成功（退出码 0 且文件非空）；失败 → 报错中止，绝不继续删除。**
5. 打印备份路径 + 大小。
6. **二次确认**：要求重新输入租户名，匹配才继续。
7. 执行删除：
   - PG：`SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='db' AND pid<>pg_backend_pid();`
     然后连到 `postgres` 库执行 `DROP DATABASE IF EXISTS "db"; DROP ROLE IF EXISTS "r";`。
   - MySQL：按 catalog 查出该 user 的所有 host，`DROP DATABASE IF EXISTS \`db\`;` 再逐个 `DROP USER IF EXISTS 'u'@'host';`。
8. 打印恢复提示（因备份为库级，完整还原还需另行重建角色 / 限额）。

## 8. 安全约束

- 标识符仅允许白名单字符（`^[a-z][a-z0-9_]*$`）并强制加引号，杜绝标识符注入；超长拒绝。
- 系统名 denylist：
  - PG：`postgres template0 template1` 及任意超级用户角色。
  - MySQL：`root mysql.sys mysql.session mysql.infoschema sys debian-sys-maint` 及 HA 账号
    `repl mysqlchk repman healthcheck`。均可在 `config.sh` 配置。
- 凭据不进 argv：MySQL 用临时 600 defaults-file（本机）/ `MYSQL_PWD` env（docker）；新密码仅结尾打印一次。
- 删除二次确认；只读保护防止在 standby 误删。
- 备份文件 600、目录 700。
- 不修改防火墙、不动系统服务、不碰部署用数据目录。

## 9. 配置项（`lib/db-tenant/config.sh`，均可环境变量覆盖）

| 变量 | 默认 | 说明 |
|---|---|---|
| `DB_TENANT_PG_CONTAINER` | `postgres` | PG 容器名 |
| `DB_TENANT_MYSQL_CONTAINER` | `mysql` | MySQL 容器名 |
| `DB_TENANT_MYSQL_ADMIN_USER` | `root` | MySQL 管理员 |
| `MYSQL_ADMIN_PASSWORD` | （空，提示输入） | MySQL 管理员密码 |
| `DB_TENANT_BACKUP_DIR` | `/var/backups/db-tenant` | 备份目录 |
| `DB_TENANT_PG_CONN_LIMIT` | `20` | PG 角色并发连接 |
| `DB_TENANT_PG_DB_CONN_LIMIT` | `20` | PG 库级并发连接 |
| `DB_TENANT_PG_STATEMENT_TIMEOUT` | `30s` | PG 语句超时（0=不限） |
| `DB_TENANT_PG_IDLE_TX_TIMEOUT` | `60s` | PG 空闲事务超时 |
| `DB_TENANT_PG_WORK_MEM` | `16MB` | PG 单会话排序内存 |
| `DB_TENANT_MYSQL_MAX_USER_CONN` | `20` | MySQL 并发连接 |
| `DB_TENANT_MYSQL_MAX_CONN_PER_HOUR` | `0` | MySQL 每小时连接 |
| `DB_TENANT_MYSQL_MAX_QUERIES_PER_HOUR` | `0` | MySQL 每小时查询 |
| `DB_TENANT_MYSQL_MAX_UPDATES_PER_HOUR` | `0` | MySQL 每小时更新 |
| `DB_TENANT_MYSQL_DEFAULT_HOST` | `%` | MySQL 账号默认 host |
| `DB_TENANT_PG_SYSTEM_NAMES` | `postgres template0 template1` | PG denylist |
| `DB_TENANT_MYSQL_SYSTEM_USERS` | `root mysql.sys …` | MySQL denylist |

## 10. 测试策略（`tests/test_db_tenant.sh`，不碰真实 DB）

- `bash -n` 语法检查全部新文件；断言模块存在与加载顺序同入口一致。
- **SQL 纯函数生成**：
  - `pg_build_create_tenant_sql` 输出含 `CREATE ROLE "acme"`、`CONNECTION LIMIT 20`、`OWNER "acme"`、
    `statement_timeout = '30s'`、`work_mem`。
  - `mysql_build_create_tenant_sql` 输出含 `CREATE USER`、`MAX_USER_CONNECTIONS 20`、
    ``GRANT ALL PRIVILEGES ON `acme`.*``。
  - `*_build_set_limit_sql` / `*_build_drop_sql` 含预期子句。
- **校验**：`db_tenant_validate_identifier` 拒绝 `a-b` / `1abc` / `a;b` / `a'b`，接受 `acme` / `acme_1`。
- **denylist**：`db_tenant_is_system_name postgres` 为真（拒绝），`acme` 为假。
- **备份失败不删除**：mock `<e>_backup_tenant` 返回非 0，对 `<e>_exec_sql` / drop 设探针，断言未发生任何 DROP。
- exec 层全部 mock，零副作用（不写真实 `/data`、不连真实 DB、备份目录用 `mktemp -d` 覆盖）。

## 11. 与现有约定对齐

- 入口 `db-tenant.sh` 用既有 `load_linuxshell_modules` 模式，本地缺模块时按列表远程下载；入口的加载列表
  即该工具的远程下载清单。
- 复用 `lib/common.sh` 的 `require_root` / `command_exists` / `to_lower` / `print_step` /
  `prompt_with_default` / `prompt_yes_no`。
- 全程脚本 `#!/usr/bin/env bash` + `set -euo pipefail`；中文交互与输出。
- 保持入口脚本与 `tests/*.sh` 可执行位。
- README 增补「数据库多租户管理」章节：用法、引擎能力差异（尤其 MySQL 无账号级语句超时）、备份目录、
  HA 须在 primary/leader 上运行。

## 12. 假设与未来扩展

### 假设

- 单主机至多一个 PG 实例、一个 MySQL 实例（单容器或单本机集群）。多实例不在 v1。
- 以 root 运行（本机 socket / `sudo -u postgres` / docker / 备份目录均需要）。
- HA 形态下在 primary / leader 上运行。

### 未来扩展（非本期）

- 备份保留 / 轮转策略、定时备份。
- 一键恢复命令。
- 备份连角色 / 限额定义一起打包（当前为库级备份，预留易扩展）。
- 可选 `/usr/local/bin/dbtenant` 常驻命令（类似 `pg` 包装器）。
- 代理层限流（PgBouncer / ProxySQL）接入位。
