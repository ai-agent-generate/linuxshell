# Linux Shell — 一键部署脚本

快速在 Ubuntu / Debian 服务器上部署 Caddy、PostgreSQL、MySQL、RabbitMQ、Redis。

---

## 一键安装（复制粘贴到服务器执行）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/deploy.sh)
```

> **注意**：需要以 `root` 身份运行，系统须为 Ubuntu / Debian。

---

## 仅安装 Docker

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-docker.sh)
```

该入口只安装 Docker Engine 与 Docker Compose plugin。完整部署仍使用 `deploy.sh`。

---

## 支持的组件

| 编号 | 组件 | 默认端口 |
|------|------|----------|
| 1 | Caddy（反向代理） | — |
| 2 | PostgreSQL 18 | 5432 |
| 3 | MySQL 8.4 | 3306 |
| 4 | RabbitMQ（含管理界面 & Web STOMP） | 5672 / 15672 / 15674 |
| 5 | Redis 8 | 6379 |
| 6 | Install pg shortcut | — |
| 7 | Docker only | — |

运行后按提示选择需要安装的组件（可多选，空格或逗号分隔）。

选择 Caddy 或任意容器服务时，脚本会自动确保 Docker 与 Docker Compose plugin 已安装；不需要额外选择 Docker only。

## PostgreSQL 高可用（Patroni，非 Docker）

在三台 Ubuntu 24.04 机器上部署 PostgreSQL 18 + Patroni + etcd + HAProxy，实现两主机自动故障转移（第三台仅作 etcd 仲裁）。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-pg-ha.sh)
```

**在每台机器各运行一次**，交互选择本机角色：

| 角色 | 说明 |
|------|------|
| 1) primary | PG 主节点（首次初始化集群） |
| 2) replica | PG 从节点（自动克隆） |
| 3) etcd-quorum | 仅 etcd 仲裁（不跑 PG） |

**推荐执行顺序**：三台先各自起 etcd → 再 primary → 最后 replica。

**应用连接**：连 HAProxy `5000`（读写都到当前主库）。为接入冗余，应用应配置**两台** HAProxy 地址（`node1:5000`、`node2:5000`）并具备连接失败重试能力。

**需放行端口**（脚本不改防火墙）：节点间 `2379`/`2380`（etcd）、`8008`（Patroni REST，HAProxy 跨机健康检查）、`5432`（PG/复制）、`5000`/`7000`（HAProxy）。

**密码**：`PG_HA_ETCD_PASSWORD`/`PG_HA_REST_PASSWORD`/`PG_HA_SUPERUSER_PASSWORD`/`PG_HA_REPLICATION_PASSWORD`/`PG_HA_REWIND_PASSWORD` **必须在 primary/replica 两台保持一致**（经环境变量或交互提供）。

**安全**：控制面启用认证（etcd RBAC + Patroni REST basic auth + HAProxy stats auth），不启用 TLS，依赖网络隔离。

**watchdog**：默认 `PG_HA_WATCHDOG=auto`。脚本会区分云/虚拟服务器与独立物理服务器：云/虚拟服务器自动关闭 watchdog 并打印防脑裂风险告警；独立物理服务器默认启用 softdog。可用 `PG_HA_WATCHDOG=on/off` 强制覆盖，也可用 `PG_HA_SERVER_TYPE=cloud/dedicated` 覆盖服务器类型判断。

**关键环境变量**：`PG_HA_NODE1_IP`/`2`/`3`、`PG_HA_MAJOR_VERSION`（默认 18）、`PG_HA_CLUSTER_NAME`（默认 pg-ha）、`PG_HA_SYNC_MODE`（默认 off；on 切零丢失同步复制）、`PG_HA_SERVER_TYPE`（默认 auto）、`PG_HA_WATCHDOG`（默认 auto）、`DATA_ROOT`（默认 /data）。

> 这是**非 Docker** 路径，与现有 Docker 版 PostgreSQL（`deploy.sh` 菜单项 2）并存，互不影响。

## MySQL 高可用（Replication Manager，非 Docker）

在两台 Ubuntu 24.04 数据机器上部署 Oracle MySQL 8.4 + Replication Manager OSC + HAProxy，实现 classic GTID 主从复制与自动故障切换；第三台低配机器仅运行 `replication-manager-osc` 监控/仲裁，不运行 MySQL 数据实例。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-mysql-ha.sh)
```

**在每台机器各运行一次**，交互选择本机角色：

| 角色 | 说明 |
|------|------|
| 1) primary | MySQL 主节点（首次建库/账号，配置为复制源） |
| 2) replica | MySQL 从节点（GTID 自动复制） |
| 3) arbiter | 仅 Replication Manager 监控/仲裁（不跑 MySQL） |

**推荐执行顺序**：arbiter → primary → replica。

**自愈与防脑裂**：Replication Manager 在 arbiter 节点监控两台数据节点，按 GTID/复制状态选择新主并设置只读状态；两台数据节点的 HAProxy 通过 `mysqlchk` 只放行当前 `read_only=0` 的可写主库。默认启用 `MYSQL_HA_SEMISYNC=on` 并配置 `failover-at-sync`，降低故障切换时的数据丢失窗口。两数据节点架构无法在所有网络分区场景同时保证自动可写与零丢失；旧主回归必须先经 Replication Manager/人工校验后再纳入流量。

**应用连接**：连 HAProxy `6446`（读写都到当前主库）。为接入冗余，应用应配置**两台** HAProxy 地址（`node1:6446`、`node2:6446`）并具备连接失败重试能力。**分区期间**被隔离节点的 HAProxy 会因 mysqlchk 转 503 而 DOWN，正常重连客户端会切到另一地址。

**需放行端口**（脚本不改防火墙）：
- 节点间互通：`3306`（复制/HAProxy/Replication Manager 监控）、`9200`（mysqlchk 跨机检查）、`10005`（Replication Manager API）
- 应用接入：`6446`（HAProxy）
- 仅本机/运维：`7001`（HAProxy stats，不建议全网放行）

**密码**：`MYSQL_HA_ROOT_PASSWORD`/`MYSQL_HA_REPL_PASSWORD`/`MYSQL_HA_REPMAN_PASSWORD`/`MYSQL_HA_MYSQLCHK_PASSWORD`/`MYSQL_HA_APP_PASSWORD` **必须在两台数据节点保持一致**；`MYSQL_HA_REPMAN_API_PASSWORD` 用于第三台 Replication Manager API。账号仅在 primary 创建，经 GTID 复制到 replica。

**安全**：Replication Manager API（10005）使用配置账号和自签名 HTTPS；MySQL 账号按监控、复制、健康检查、应用分离；复制链路启用 MySQL 自动生成证书的 SSL，应用连接仍建议依赖内网隔离或自行加 TLS。

**故障恢复**：旧主 failover 回归可能带 errant GTID，需经 Replication Manager 重新纳管或重装全量重建后再放行流量（半同步可降低概率但不能替代恢复校验）。

**版本兼容性**：`MYSQL_HA_VERSION` 默认且当前仅支持 `8.4`。本路径不再使用已停更的 Orchestrator；Replication Manager 使用 Signal18 APT 仓库的 `replication-manager-osc` 包。

**关键环境变量**：`MYSQL_HA_NODE1_IP`/`2`/`3`、`MYSQL_HA_VERSION`（默认 8.4）、`MYSQL_HA_CLUSTER_NAME`（默认 mysql-ha）、`MYSQL_HA_SEMISYNC`（默认 on；半同步降低 RPO）、`MYSQL_HA_REPMAN_PASSWORD`、`MYSQL_HA_REPMAN_API_PASSWORD`、`DATA_ROOT`（默认 /data）。

> 这是**非 Docker** 路径，与现有 Docker 版 MySQL（`deploy.sh` 菜单项 3）**并存但同机不可并跑**（均占 3306 / server_id 易撞）。

## 数据库多租户管理（db-tenant.sh）

为已部署的 MySQL / PostgreSQL 按「一库一角色」管理多租户，并对角色施加账号级资源限制，
避免某个租户瞬时爆发拖垮同实例的其他租户。

一键运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/db-tenant.sh)
```

或本地：`bash db-tenant.sh`（菜单驱动：先选引擎，再选 建/列出/改限额/改密码/备份/删除）。

- **自动探测**：同名容器在运行用 `docker exec`；否则用本机 socket/客户端（探测结果会要求确认；可用
  `DB_TENANT_FORCE_TARGET=docker|local` 覆盖）。
- **资源限制**：
  - PostgreSQL：角色/库连接上限、`statement_timeout`、`idle_in_transaction_session_timeout`、`work_mem`。
  - MySQL：`MAX_USER_CONNECTIONS`、每小时连接/查询/更新配额。**MySQL 无账号级语句超时**
    （`max_execution_time` 仅对 SELECT 生效且为全局/会话级，本工具不设置）。
  - 数值语义：各「每小时」配额 `0` 表示不限；`MAX_USER_CONNECTIONS=0` 表示回退到全局
    `max_user_connections`（并非真正无限）。
- **删除前先备份**：删除会先把库 `pg_dump`/`mysqldump` 到 `DB_TENANT_BACKUP_DIR`
  （默认 `/var/backups/db-tenant`），并做完整性校验，**校验失败则中止删除**；随后需重输租户名二次确认。
  备份仅含数据库，角色/限额需另行重建。
- **HA 注意**：写操作（含删除）需在 `primary`/`leader` 节点运行；独立备份可在 standby。
- **端口/防火墙**：本工具为客户端工具，**不监听端口、不修改防火墙**。
- MySQL 管理员密码取自 `DB_TENANT_MYSQL_ADMIN_PASSWORD`，缺省回退 `MYSQL_HA_ROOT_PASSWORD` /
  `MYSQL_ROOT_PASSWORD`，再缺则交互输入。

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

## 数据目录

所有数据默认存放在 `/data`：

```
/data/
├── docker/          # compose 文件
├── postgres/        # PostgreSQL 数据（PG 18 格式：postgres/18/main）
├── mysql/           # MySQL 数据与配置
├── rabbitmq/        # RabbitMQ 数据与配置
├── redis/           # Redis 数据
└── mysql-ha/        # MySQL HA 数据与 Replication Manager 状态
```

可通过环境变量覆盖数据目录：

```bash
DATA_ROOT=/opt/data bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/deploy.sh)
```

## PostgreSQL 重装说明

已安装的 PostgreSQL 在脚本提示 `[r]einstall` 时，可选择：

- **[c]lean**：清空数据目录，全新初始化
- **[m]igrate**：将旧版 `data/` 目录迁移至 PG 18+ 的版本子目录结构（保留数据）

## 共享网络

所有容器加入同一个 Docker 网络 `my_network`，服务间可通过容器名直接互访（如 `postgres:5432`）。

## 环境变量参考

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DATA_ROOT` | `/data` | 数据根目录 |
| `POSTGRES_IMAGE` | `postgres:18.3` | PostgreSQL 镜像 |
| `MYSQL_IMAGE` | `mysql:8.4.8` | MySQL 镜像 |
| `RABBITMQ_IMAGE` | `rabbitmq:management` | RabbitMQ 镜像 |
| `REDIS_IMAGE` | `redis:8.6.1` | Redis 镜像 |
| `SHARED_NETWORK_NAME` | `my_network` | Docker 共享网络名 |
