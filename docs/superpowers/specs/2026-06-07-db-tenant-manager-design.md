# 数据库多租户管理脚本设计（MySQL / PostgreSQL）

- 日期：2026-06-07
- 状态：设计待评审（已含一轮子代理评审修订）
- 入口：`db-tenant.sh`
- 模块：`lib/db-tenant/`

## 0. 修订记录

- v2（2026-06-07）：纳入技术/安全评审与仓库一致性评审的结论，重点修订：备份结构性校验、`mysqldump` 失败传播、PG `DROP … WITH (FORCE)` 与角色依赖兜底、denylist 双道防线（含 MySQL 库级 denylist 与 `replication_manager_schema`）、MySQL 凭据改 stdin 注入避免 `ps` 暴露、PG 限额改 `ALTER ROLE … IN DATABASE … SET`、租户身份统一为 `(user, host)`、自动探测确认与 `DB_TENANT_FORCE_TARGET`、入口内联 `load_linuxshell_modules`、管理员密码变量回退、测试断言补齐。
- v1：初稿。

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
- 自动探测部署形态：同名容器在运行 → `docker exec`；否则 → 本机 socket / 客户端（探测结果须经确认或可强制覆盖）。
- 纯交互菜单（跑法同 `deploy.sh`）。
- 账号级资源限制（详见 §6）。
- 删除前**先成功备份数据库（并通过完整性校验）再删除**，备份失败则中止删除。

### 非目标

- CPU / 内存 / IO 硬隔离（需独立实例 / cgroup）。
- 代理层限流（PgBouncer / ProxySQL）。
- 每租户独立实例、跨主机编排。
- 自动恢复命令（仅打印恢复提示）、备份轮转 / 保留策略、定时备份。
- 角色与库的多对多管理（固定 1:1 模型）。
- 备份角色/限额定义（备份仅库级；角色与限额需要时手动重建，drop 时打印重建提示）。

## 3. 名词与租户模型

- **租户（tenant）**：一个逻辑隔离单元，对应「一个数据库 + 一个登录角色」。
- **租户身份**：
  - PG：角色名（同时是库 OWNER）。
  - MySQL：`(user, host)` 二元组——同名 user 不同 host 视为不同账号，所有操作针对精确 `(user, host)`。
- **租户名 / 角色名 / user 名**：校验 `^[a-z][a-z0-9_]*$`，长度 ≤ 63（PG）/ 32（MySQL user 上限 32 字符）。
- **库名**：默认等于租户名，可覆盖。
- **MySQL host**：账号来源限定，默认 `%`，可配（如 `10.0.0.%`）。
- 模型固定 **1 租户 = 1 库 + 1 角色**；角色权限只限于自己的库。
  - PG：角色拥有（OWNER）该库，自给自足。
  - MySQL：`GRANT ALL PRIVILEGES ON \`db\`.* TO 'user'@'host'`。

## 4. 总体架构

采用「单入口 + 引擎后端 + 统一动词接口」。

```
db-tenant.sh                 # 入口：内联 load_linuxshell_modules（同 install-mysql-ha.sh）+ 调 db_tenant_main
lib/db-tenant/config.sh      # 默认限额、容器名、备份目录、denylist、强制目标等（均可环境变量覆盖）
lib/db-tenant/common.sh      # 菜单、标识符校验、denylist、密码生成与转义、连接探测分发、只读检测、备份目录与磁盘预检、flock
lib/db-tenant/pg.sh          # PostgreSQL 后端：SQL builder（纯函数）+ exec + 动词
lib/db-tenant/mysql.sh       # MySQL 后端：同上
lib/db-tenant/main.sh        # 引擎选择 + 动作菜单 + 分发
tests/test_db_tenant.sh      # 语法 / 函数存在 / 加载顺序 / SQL 生成 / 校验 / denylist / 备份失败不删除 / README 同步 / 可执行位
```

模块加载顺序（入口与测试逐条断言一致）：
`lib/common.sh → lib/db-tenant/config.sh → lib/db-tenant/common.sh → lib/db-tenant/pg.sh →
lib/db-tenant/mysql.sh → lib/db-tenant/main.sh`。入口**不**加载 `lib/config.sh`（那是 Docker 部署专用配置）。

### 入口引导（与既有入口一致）

入口脚本**内联**一份与 `install-mysql-ha.sh` 相同的 `load_linuxshell_modules`（含
`LINUXSHELL_RAW_BASE_URL`、`mktemp -d` 远程回退）——不能从 `common.sh` 复用，因为远程回退时
`common.sh` 尚未下载。本地存在性判断改为 `lib/db-tenant/config.sh`。入口末尾保留
`if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then db_tenant_main "$@"; fi` 守卫。入口的加载实参列表即该工具的远程下载清单。

### 统一动词接口

每个引擎后端实现同名前缀（`pg_` / `mysql_`）的同一组函数，便于 `main.sh` 分发：

- `<e>_detect_target`：判定 docker / local（含确认与 `DB_TENANT_FORCE_TARGET` 覆盖、连通性校验），准备连接上下文。
- `<e>_assert_writable`：HA 只读检测（standby/replica 则中止）。**仅写操作与“删除前备份”调用**；独立备份不调用。
- `<e>_exec_sql`：把 SQL 喂给对应客户端（凭据不进 argv/environ）。
- `<e>_build_create_tenant_sql` / `<e>_build_set_limit_sql` / `<e>_build_set_password_sql` /
  `<e>_build_drop_sql`：**纯函数**，只产出 SQL 字符串，便于测试。入参含「对象是否已存在」标志以决定 CREATE/ALTER 分支。
- `<e>_create_tenant` / `<e>_list_tenants` / `<e>_set_limit` / `<e>_set_password` /
  `<e>_backup_tenant` / `<e>_drop_tenant`：动作编排。

公共件（`common.sh`）：`db_tenant_validate_identifier`、`db_tenant_is_system_name`、
`db_tenant_generate_password`（实现同 `mysql_ha_generate_password`，见 §7）、
`db_tenant_sql_escape_literal`（按引擎转义密码/字符串字面量）、`db_tenant_prepare_backup_dir`（mkdir 700 + 磁盘预检）、写凭据文件复用 `lib/common.sh:confirm_overwrite`。

菜单层级：先选引擎（1=PostgreSQL / 2=MySQL）→ 自动探测并**显示/确认**目标 → 动作菜单
（1 建租户 / 2 列出 / 3 改限额 / 4 改密码 / 5 备份 / 6 删除 / 0 退出）。

## 5. 连接探测与管理员凭据（自动探测 + 确认）

| 引擎 | 容器形态 | 本机形态 |
|---|---|---|
| PostgreSQL | `docker exec -i <容器> psql -U postgres`（容器内 trust） | 以 root 跑 `sudo -u postgres psql`（peer/local trust 认证，免密） |
| MySQL | `docker cp` 临时 600 cnf 进容器 → `docker exec -i <容器> mysql --defaults-extra-file=<容器内cnf>`（SQL 走 stdin）→ 用完 `rm`；凭据不进 argv/environ | 临时 600 `--defaults-extra-file` 走本机 socket（同既有 `_mysql_root_exec` 模式） |

- 容器探测：`docker inspect -f '{{.State.Running}}' <容器>` 为 `true` 即 docker 形态。
- 容器名默认 `postgres` / `mysql`，可经 `DB_TENANT_PG_CONTAINER` / `DB_TENANT_MYSQL_CONTAINER` 覆盖。
- **探测歧义处理（Docker 与 HA 可能同机并存）**：
  - 探测出目标后**打印**（形态 + 容器名或本机 socket + 端口/库）并要求用户确认。
  - 支持 `DB_TENANT_FORCE_TARGET=docker|local` 显式覆盖，跳过探测。
  - 本机形态先 `command_exists psql/mysql` 且**实测连通**，连不上给出明确错误，不静默落空。
- **MySQL root 密码**按优先级读取：`DB_TENANT_MYSQL_ADMIN_PASSWORD` → `MYSQL_HA_ROOT_PASSWORD` →
  `MYSQL_ROOT_PASSWORD` → 交互隐藏输入（`read -rs`）。PG 管理侧基本免密。
- **HA 只读保护**（写操作前；“删除前的备份”也算写流程入口，先于备份检测——避免在 standby 白备份后才发现不能删；**独立备份动作不检测**，允许在 standby 上 `pg_dump` 卸载主库）：
  - PG：`SELECT pg_is_in_recovery();` 为 `t` → 中止，提示「当前为 standby，请在 leader 上运行」。
  - MySQL：`SELECT @@global.super_read_only, @@global.read_only;` 任一为 1 → 中止，提示在 primary 上运行。

## 6. 资源限制参数集（核心）

### PostgreSQL

> 说明：角色 `CONNECTION LIMIT` 为**角色全局**并发连接上限；数据库 `CONNECTION LIMIT` 为**库级**上限；
> `statement_timeout` / `idle_in_transaction_session_timeout` / `work_mem` 用
> `ALTER ROLE "r" IN DATABASE "db" SET …` 写入，是**角色×库级**默认（仅该角色登录该库时生效），在 1:1 模型下语义最干净。

| 项 | 落地 SQL | 默认（config 可覆盖） |
|---|---|---|
| 角色并发连接上限 | `CREATE/ALTER ROLE "r" CONNECTION LIMIT n` | 20 |
| 库级并发连接上限 | `ALTER DATABASE "db" CONNECTION LIMIT m` | 20 |
| 单语句超时 | `ALTER ROLE "r" IN DATABASE "db" SET statement_timeout = '30s'` | 30s（0 = 不限） |
| 空闲事务超时 | `ALTER ROLE "r" IN DATABASE "db" SET idle_in_transaction_session_timeout = '300s'` | 300s（0 = 不限） |
| 单会话排序内存 | `ALTER ROLE "r" IN DATABASE "db" SET work_mem = '16MB'` | 16MB |

### MySQL（账号级，`CREATE/ALTER USER … WITH`）

| 项 | 落地 SQL | 默认 |
|---|---|---|
| 并发连接上限 | `MAX_USER_CONNECTIONS n` | 20 |
| 每小时新建连接 | `MAX_CONNECTIONS_PER_HOUR a` | 0 = 不限 |
| 每小时查询数 | `MAX_QUERIES_PER_HOUR q` | 0 = 不限 |
| 每小时更新数 | `MAX_UPDATES_PER_HOUR u` | 0 = 不限 |

> 语义脚注：MySQL 中 `MAX_*_PER_HOUR = 0` 表示**不限**；`MAX_USER_CONNECTIONS = 0` 表示**回退到全局
> `max_user_connections`**。能力差异（写入 README）：MySQL **无账号级语句超时**；`max_execution_time`
> 仅对 SELECT 生效且为全局/会话级，按租户设置会波及所有人，故本工具**不**设置全局超时。

## 7. 各动作流程

所有写操作前先 `<e>_assert_writable`（独立备份除外）。写操作期间用 `flock`（基于备份目录下的锁文件）串行化，避免并发删除/改限额竞态。标识符一律白名单校验并加引号（PG `"…"`、MySQL `` `…` ``）。

**密码生成**：`db_tenant_generate_password` = `openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 25`（白名单取字符，恒得 25 位 `[A-Za-z0-9]`，规避一切转义；与 `mysql_ha_generate_password` 同源，满足既有「仅字母数字」断言）。
**密码转义**：用户手填时经 `db_tenant_sql_escape_literal`——PG（`standard_conforming_strings=on`）将 `'`→`''`；MySQL 同时 `\`→`\\` 且 `'`→`''`。§10 含特殊字符（`\ ' " \` $`）用例。

### 7.1 建租户（create）

输入：租户名、库名（默认=租户名）、MySQL host（默认 `%`）、各限额、密码（默认生成）。
**幂等与防降配**：若角色/用户或库已存在，先**读现值回填为默认**并提示「该租户已存在，将更新限额」，避免一路回车把已调大的限额静默打回默认。

- PG（管理连接连 `postgres` 库；多条 DDL **不**包在事务里，`CREATE DATABASE` 不能在事务块内且无 `IF NOT EXISTS`，psql 默认 autocommit，**不要**加 `-1/--single-transaction`）：
  1. 角色不存在 → `CREATE ROLE "r" LOGIN PASSWORD '…' CONNECTION LIMIT n`；存在 → `ALTER ROLE "r" CONNECTION LIMIT n`（并按需改密码）。
  2. 库不存在 → `CREATE DATABASE "db" OWNER "r" CONNECTION LIMIT m`；存在 → `ALTER DATABASE "db" OWNER TO "r"; ALTER DATABASE "db" CONNECTION LIMIT m`。
  3. **仅当本工具新建该库**：`REVOKE CONNECT ON DATABASE "db" FROM PUBLIC; GRANT CONNECT ON DATABASE "db" TO "r";`（复用已存在库时默认不收紧，避免影响既有角色）。
  4. 套限额：`ALTER ROLE "r" IN DATABASE "db" SET statement_timeout / idle_in_transaction_session_timeout / work_mem`。
- MySQL（先探测 `(user, host)` 是否存在，避免 `CREATE USER IF NOT EXISTS … WITH` 在已存在时静默丢限额）：
  1. `CREATE DATABASE IF NOT EXISTS \`db\` CHARACTER SET utf8mb4;`
  2. 不存在 → `CREATE USER 'u'@'host' IDENTIFIED BY '…' WITH MAX_USER_CONNECTIONS n MAX_CONNECTIONS_PER_HOUR a MAX_QUERIES_PER_HOUR q MAX_UPDATES_PER_HOUR u;`
     存在 → `ALTER USER 'u'@'host' WITH MAX_USER_CONNECTIONS n …;`（并按需 `IDENTIFIED BY`）。
  3. `GRANT ALL PRIVILEGES ON \`db\`.* TO 'u'@'host';`
- 结尾打印摘要：引擎 / 库 / 角色（MySQL 含 `@host`）/ 密码（仅此一次）/ 连接示例 / 已套限额；可选写入 600 凭据文件（复用 `confirm_overwrite`）。

### 7.2 列出（list）—— 基于 catalog 实时查询，无状态文件

- PG（用 **LEFT JOIN / 并列孤儿对象**以暴露 drift 残留）：
  ```sql
  SELECT d.datname AS db, r.rolname AS role, r.rolconnlimit, d.datconnlimit
  FROM pg_database d LEFT JOIN pg_roles r ON d.datdba = r.oid
  WHERE d.datname NOT IN ('postgres','template0','template1')
    AND (r.rolsuper IS DISTINCT FROM true)
  ORDER BY d.datname;
  ```
  叠加 `pg_db_role_setting`（按 `setdatabase` 区分「角色×库」级 SET）格式化展示；额外列出「有库无 owner 角色 / 有角色无库」的孤儿，标注 drift。
- MySQL：
  ```sql
  SELECT user, host, max_user_connections, max_connections, max_questions, max_updates
  FROM mysql.user WHERE user NOT IN (<用户 denylist>);
  ```
  以 `mysql.db` 关联出每个 `(user,host)` 绑定的库，并排除库 denylist。
- 限额**一律从 catalog 实时读取**，不维护会漂移的副本。

### 7.3 改限额（set-limit）

- 先按租户身份定位对象并**读现值回填默认**，幂等。
- PG：`ALTER ROLE "r" CONNECTION LIMIT …; ALTER DATABASE "db" CONNECTION LIMIT …; ALTER ROLE "r" IN DATABASE "db" SET …;`
- MySQL：针对精确 `(user, host)` 执行 `ALTER USER 'u'@'host' WITH MAX_USER_CONNECTIONS … MAX_CONNECTIONS_PER_HOUR … MAX_QUERIES_PER_HOUR … MAX_UPDATES_PER_HOUR;`。
  若同名 user 存在多个 host，**列出全部 host 让用户选择**目标（不盲目全改、也不只改一个）。

### 7.4 改密码（set-password）

- PG：`ALTER ROLE "r" PASSWORD '…';`
- MySQL：针对精确 `(user, host)` 执行 `ALTER USER 'u'@'host' IDENTIFIED BY '…';`；多 host 时列出选择。

### 7.5 备份（backup）

可单独触发（**不要求可写**，standby 也允许），也被删除流程复用。备份**仅数据库**。

- 目录：`${DB_TENANT_BACKUP_DIR:-/var/backups/db-tenant}`（目录 700、文件 600）；
  `db_tenant_prepare_backup_dir` 先校验可写并**预检可用磁盘空间**（低于阈值告警/中止）。
- 文件名：`<engine>-<db>-<时间戳>-<$$>.{dump|sql.gz}`（时间戳 `date +%Y%m%d-%H%M%S` + PID/随机后缀，防同秒覆盖）。
- **PG**（直接重定向，`docker exec` 退出码可靠反映 `pg_dump`）：
  - docker：`docker exec -i <容器> pg_dump -U postgres -Fc -d "db" > 文件`（**`docker exec` 不加 `-t`**，避免分配 TTY 破坏 `-Fc` 二进制流）。
  - 本机：`sudo -u postgres pg_dump -Fc -d "db" > 文件`。
- **MySQL**（**先 dump 到临时文件、校验退出码，再 gzip**，规避管道失败传播的不确定性；如用管道则必须查 `${PIPESTATUS[0]}`）：
  - docker：复用 §5 的「`docker cp` 临时 600 cnf 进容器」机制，`docker exec <容器> mysqldump --defaults-extra-file=<容器内cnf> --single-transaction --routines --triggers --events --databases "db" > 临时sql`，校验退出码后 `gzip 临时sql`，并 `rm` 容器内 cnf。
  - 本机：`mysqldump --defaults-extra-file=<临时> --single-transaction --routines --triggers --events --databases "db" > 临时sql`，校验后 `gzip`。
- **完整性校验（不止看大小）**：
  - PG：`pg_restore -l "文件" >/dev/null`（能列出归档目录即完整）。
  - MySQL：`gzip -t "文件"`（压缩完整）且 `zcat "文件" | tail` 含 `-- Dump completed`。
- 校验失败：**删除半成品文件**并报错；删除流程下据此中止。
- 打印备份路径 + 大小 + 恢复提示。

### 7.6 删除（drop）—— 只读检测 → 备份 → 完整性校验 → 二次确认 → 删除

1. `<e>_assert_writable`（HA 只读先行中止，避免白备份）。
2. **denylist 双道防线**：静态名单 + **catalog 属性判定**——
   - PG：拒绝 `rolsuper / rolreplication / rolbypassrls` 为真的角色、拒绝 owner 为超级用户的库、拒绝系统库名单。
   - MySQL：拒绝用户 denylist 与**库 denylist**（含 `mysql information_schema performance_schema sys replication_manager_schema` 及 HA 库）。
3. 调 `<e>_backup_tenant` 备份并做 §7.5 完整性校验。
4. **校验通过才继续；任一失败 → 报错中止、清理半成品，绝不删除。**
5. 打印备份路径 + 大小，并**列出将被删除的对象**（库 + 精确 `user@host` 列表）。
6. **二次确认**：要求重新输入租户名，匹配才继续。
7. 执行删除（PG 管理连接全程连 `postgres` 库，绝不连目标库）：
   - PG：`SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='db' AND pid<>pg_backend_pid();`
     PG13+ 用 `DROP DATABASE IF EXISTS "db" WITH (FORCE);`（内建强制断开），低版本则 terminate 后轮询 `pg_stat_activity` 至无连接或超时再 `DROP DATABASE IF EXISTS "db";`；
     再 `DROP OWNED BY "r";`（兜底依赖）后 `DROP ROLE IF EXISTS "r";`。**任一步失败都上报**，不被 `IF EXISTS` 静默掩盖。
   - MySQL：`DROP DATABASE IF EXISTS \`db\`;` 后，**只删第 5 步确认过的精确 `(user, host)`**：`DROP USER IF EXISTS 'u'@'host';`（不按“所有同名 host”地毯式删）。
8. 打印恢复提示（备份为库级，完整还原还需另行重建角色 / 限额；list 可读出旧限额辅助重建）。

## 8. 安全约束

- 标识符仅允许白名单字符（`^[a-z][a-z0-9_]*$`）并强制加引号，杜绝标识符注入；超长拒绝。
- 密码转义按引擎处理（见 §7）；自动生成密码仅 `[A-Za-z0-9]`，规避转义。
- 凭据不进 argv/environ：
  - MySQL 本机用临时 600 defaults-file；**docker 经 stdin 注入 defaults-file**（不用 `MYSQL_PWD`，避免宿主 `ps` 在 `docker exec -e` 窗口看到明文）。
  - 新密码仅结尾打印一次，可选写 600 文件。
- **denylist 双道防线**：静态名单（可配）+ catalog 属性动态判定（见 §7.6）。
  - PG 系统库：`postgres template0 template1` + 任意超级用户/复制角色（动态）。
  - MySQL 系统用户：`root mysql.sys mysql.session mysql.infoschema sys debian-sys-maint` + HA 账号 `repl mysqlchk repman`。
  - MySQL 系统库：`mysql information_schema performance_schema sys replication_manager_schema`。
  - 注：HA 账号名可能被 `MYSQL_HA_REPMAN_USER` 等改成自定义值；文档提示「自定义过则需同步 config denylist」。
- 删除二次确认 + 展示精确待删对象；只读保护防止在 standby 误删。
- 写操作 `flock` 串行化；备份文件名含 PID/随机后缀防同秒覆盖。
- 备份文件 600、目录 700；备份前磁盘预检，失败清理半成品。
- 不修改防火墙、不动系统服务、不碰部署用数据目录、不新增监听端口。

## 9. 配置项（`lib/db-tenant/config.sh`，均可环境变量覆盖）

| 变量 | 默认 | 说明 |
|---|---|---|
| `DB_TENANT_PG_CONTAINER` | `postgres` | PG 容器名 |
| `DB_TENANT_MYSQL_CONTAINER` | `mysql` | MySQL 容器名 |
| `DB_TENANT_FORCE_TARGET` | （空=自动探测） | `docker` / `local` 强制目标，跳过探测 |
| `DB_TENANT_MYSQL_ADMIN_USER` | `root` | MySQL 管理员 |
| `DB_TENANT_MYSQL_ADMIN_PASSWORD` | （空） | MySQL 管理员密码；空时回退 `MYSQL_HA_ROOT_PASSWORD` → `MYSQL_ROOT_PASSWORD` → 交互输入 |
| `DB_TENANT_BACKUP_DIR` | `/var/backups/db-tenant` | 备份目录 |
| `DB_TENANT_BACKUP_MIN_FREE_MB` | `512` | 备份前最小可用空间（MB），不足则告警/中止 |
| `DB_TENANT_PG_CONN_LIMIT` | `20` | PG 角色并发连接 |
| `DB_TENANT_PG_DB_CONN_LIMIT` | `20` | PG 库级并发连接 |
| `DB_TENANT_PG_STATEMENT_TIMEOUT` | `30s` | PG 语句超时（0=不限） |
| `DB_TENANT_PG_IDLE_TX_TIMEOUT` | `300s` | PG 空闲事务超时（0=不限） |
| `DB_TENANT_PG_WORK_MEM` | `16MB` | PG 单会话排序内存 |
| `DB_TENANT_MYSQL_MAX_USER_CONN` | `20` | MySQL 并发连接（0=用全局） |
| `DB_TENANT_MYSQL_MAX_CONN_PER_HOUR` | `0` | MySQL 每小时连接（0=不限） |
| `DB_TENANT_MYSQL_MAX_QUERIES_PER_HOUR` | `0` | MySQL 每小时查询（0=不限） |
| `DB_TENANT_MYSQL_MAX_UPDATES_PER_HOUR` | `0` | MySQL 每小时更新（0=不限） |
| `DB_TENANT_MYSQL_DEFAULT_HOST` | `%` | MySQL 账号默认 host |
| `DB_TENANT_PG_SYSTEM_NAMES` | `postgres template0 template1` | PG 库/角色静态 denylist |
| `DB_TENANT_MYSQL_SYSTEM_USERS` | `root mysql.sys mysql.session mysql.infoschema sys debian-sys-maint repl mysqlchk repman` | MySQL 用户 denylist |
| `DB_TENANT_MYSQL_SYSTEM_DATABASES` | `mysql information_schema performance_schema sys replication_manager_schema` | MySQL 库 denylist |

## 10. 测试策略（`tests/test_db_tenant.sh`，不碰真实 DB）

- `bash -n` 语法检查全部新文件。
- **入口/加载断言（对齐 `test_mysql_ha.sh:run_skeleton_tests`）**：逐条断言 `db-tenant.sh` 含
  `lib/common.sh`、`lib/db-tenant/config.sh`、`lib/db-tenant/common.sh`、`lib/db-tenant/pg.sh`、
  `lib/db-tenant/mysql.sh`、`lib/db-tenant/main.sh`，且**不**含 `lib/config.sh`；加载顺序一致。
- **可执行位**：断言 `db-tenant.sh` 与 `tests/test_db_tenant.sh` 为 `-x`。
- **README 同步（对齐 `run_docs_tests`）**：断言 README 含 `db-tenant.sh` 与能力差异关键词。
- **SQL 纯函数生成**：
  - `pg_build_create_tenant_sql`：含 `CREATE ROLE "acme"`、`CONNECTION LIMIT 20`、`OWNER "acme"`、
    `IN DATABASE "acme" SET statement_timeout = '30s'`、`work_mem`；且**不**含包裹 `CREATE DATABASE` 的 `BEGIN/COMMIT`。
  - 已存在分支：mock catalog 返回「用户已存在」→ MySQL 断言生成 `ALTER USER … WITH`（而非被 `CREATE USER IF NOT EXISTS` 吞掉）。
  - `mysql_build_create_tenant_sql`：含 `MAX_USER_CONNECTIONS 20`、``GRANT ALL PRIVILEGES ON `acme`.*``。
  - `*_build_set_limit_sql` / `*_build_drop_sql` 含预期子句；drop 针对精确 `'u'@'host'`。
- **校验**：`db_tenant_validate_identifier` 拒绝 `a-b` / `1abc` / `a;b` / `a'b`，接受 `acme` / `acme_1`。
- **denylist**：`db_tenant_is_system_name` 对 `postgres` / `mysql.session` / `debian-sys-maint` / `repman` /
  `replication_manager_schema` 为真（拒绝），对 `acme` 为假。
- **密码**：`db_tenant_generate_password` 输出 `^[A-Za-z0-9]+$` 且长度 25；
  `db_tenant_sql_escape_literal` 对含 `\ ' " \` $` 的密码按引擎正确转义。
- **备份安全**：
  - mock `<e>_backup_tenant` 返回非 0 → 断言删除流程未发出任何 `DROP`（探针标志）。
  - mock 备份「文件非空但完整性校验失败」（`pg_restore -l`/`gzip -t` 返回非 0）→ 同样判失败、不删除。
- exec 层全部 mock，零副作用（不写真实 `/data`、不连真实 DB、备份目录用 `mktemp -d` 覆盖）。

## 11. 与现有约定对齐

- 入口 `db-tenant.sh` **内联** `load_linuxshell_modules`（同 `install-mysql-ha.sh`），本地缺模块时按列表远程下载；入口加载列表即远程下载清单。
- 复用 `lib/common.sh`：`require_root` / `command_exists` / `to_lower` / `print_step` /
  `prompt_with_default` / `prompt_yes_no` / `confirm_overwrite`（写凭据文件）。
- 密码生成在 `lib/db-tenant/common.sh` 以 `db_tenant_generate_password` 实现（与 `mysql_ha_generate_password` 同源，复制非调用，因 common.sh 无通用密码函数）。
- 全程脚本 `#!/usr/bin/env bash` + `set -euo pipefail`；中文交互与输出。
- 保持入口脚本与 `tests/*.sh` 可执行位。
- README 增补「数据库多租户管理」章节：用法、引擎能力差异（尤其 MySQL 无账号级语句超时、`0` 的语义）、
  备份目录与完整性校验、HA 须在 primary/leader 运行、**本工具不监听端口/不改防火墙**、作为**独立入口**（不并入
  `deploy.sh` 菜单，类似 `install-pg-ha.sh`）。

## 12. 假设与未来扩展

### 假设

- 单主机至多一个 PG 实例、一个 MySQL 实例（单容器或单本机集群）。多实例不在 v1（探测歧义由确认/`DB_TENANT_FORCE_TARGET` 缓解）。
- 以 root 运行（本机 socket / `sudo -u postgres` / docker / 备份目录均需要）。
- HA 形态下写操作（含删除）在 primary / leader 上运行；独立备份可在 standby。
- 并发由 `flock` 串行化；不支持跨主机协同。

### 未来扩展（非本期）

- 备份保留 / 轮转策略、定时备份。
- 一键恢复命令。
- drop 前把角色/限额重建语句导出为 `.meta` 文件（当前仅打印提示）。
- 备份连角色 / 限额定义一起打包。
- 可选 `/usr/local/bin/dbtenant` 常驻命令（类似 `pg` 包装器）。
- 代理层限流（PgBouncer / ProxySQL）接入位。
