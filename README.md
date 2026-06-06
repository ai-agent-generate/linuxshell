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

**watchdog**：默认 `PG_HA_WATCHDOG=on`（softdog 防脑裂）。无 `/dev/watchdog` 的云主机会启动失败，需显式设 `PG_HA_WATCHDOG=off`（将关闭防脑裂兜底）。

**关键环境变量**：`PG_HA_NODE1_IP`/`2`/`3`、`PG_HA_MAJOR_VERSION`（默认 18）、`PG_HA_CLUSTER_NAME`（默认 pg-ha）、`PG_HA_SYNC_MODE`（默认 off；on 切零丢失同步复制）、`DATA_ROOT`（默认 /data）。

> 这是**非 Docker** 路径，与现有 Docker 版 PostgreSQL（`deploy.sh` 菜单项 2）并存，互不影响。

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
└── redis/           # Redis 数据
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
