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

## 防火墙管理（iptables，与 Docker/k3s 共存）

在同时跑 Docker 和 k3s 的服务器上交互式管理防火墙规则。底层用 iptables 自管理,不依赖 ufw/firewalld;主机入站 `INPUT` 默认 DROP 白名单,Docker 发布端口 deny-by-default,k3s 节点逐端口放行。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-firewall.sh)
```

安装后用 `fw` 命令（无参进交互菜单）：

```bash
fw                # 交互菜单:查看/添加/删除/启停
fw status         # 当前状态(policy/跳转/规则数)
fw list           # 列出规则
fw apply          # 重新应用(docker daemon 重启后需手动跑)
fw disable 30m    # 临时禁用,30 分钟后自动恢复
```

**Docker 端口 deny-by-default**：容器发布端口（经 `DOCKER-USER`）默认拒绝外部访问,即使 `INPUT=DROP` 也不让 redis/mysql 等绕过暴露。对外服务（如 Caddy 80/443）需在菜单"添加 Docker 端口放行"登记来源。

**k3s 节点**：菜单录入各节点 IP,脚本逐端口放行 k3s 必需端口（`6443/10250/2379-2380` TCP、`8472` UDP VXLAN）及 CNI（pod `10.42.0.0/16`、`cni0`/`flannel.1`）。改了 k3s 默认 CIDR/端口用环境变量覆盖。

**IPv6**：自动同管（ip6tables 镜像,放行 NDP/echo 必需 ICMPv6,排除 redirect）。

**关键环境变量**：`FW_RULES_FILE`（默认 `/etc/linuxshell-fw/rules.conf`）、`FW_BIN`（默认 `/usr/local/bin/fw`）、`FW_SSH_PORT`、`FW_K3S_TCP_PORTS`/`FW_K3S_UDP_PORTS`/`FW_K3S_POD_CIDR`、`FW_LIB_DIR`。

**已知局限**：Docker daemon 单独重启会重置 `DOCKER-USER`,需 `fw apply` 重建（boot 时 systemd 自动重建）；kube-proxy 周期 reconcile 可能短暂重排 INPUT,`fw apply` 会重新置顶。apply 失败时查 `fw status`。

> 防火墙是安全关键组件,远程 `curl|bash` 前请核对脚本来源。
