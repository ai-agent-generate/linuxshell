# MySQL + Orchestrator 两主机自动 HA 部署 — 设计方案

> 本方案在已上线的 PostgreSQL + Patroni HA(见 `2026-06-06-postgres-patroni-ha-design.md`)之后新增,刻意保持架构对称、代码风格与测试策略一致。

## 概述 (Summary)

为现有 `linuxshell` 部署项目新增一条**非 Docker、跨机器**的 MySQL 高可用部署路径:在两台服务器上以 **Orchestrator** 管理 MySQL 8.4 GTID 主从复制,配合第三台轻量仲裁节点(仅跑 Orchestrator,参与 raft 投票、不存数据),实现**自动故障转移**。目标系统为 **Ubuntu 24.04 LTS (noble)**,并设计为可向更新 Ubuntu 版本兼容。

该功能以独立入口脚本 `install-mysql-ha.sh` 提供(类似 `install-pg-ha.sh`),复用 `lib/common.sh` 公共模块,新增逻辑收敛在 `lib/mysql-ha/` 子目录。它**不改动**现有基于 Docker 的单机 MySQL 部署(`deploy.sh` 菜单项 3 保持不变)。

核心原则与现有项目一致:**每台机器上 `curl` 执行一次**、模块化、配置可通过环境变量覆盖、测试聚焦"配置文件生成正确性"。

### 与 PG HA 的组件映射

| PG HA | MySQL HA | 角色 |
|---|---|---|
| Patroni | **Orchestrator** | 故障检测 + 自动提升 + 重新指向复制 |
| etcd 三成员 | **Orchestrator raft**(3 节点 + 各自 SQLite 后端) | 共识,quorum=2,容忍任意一台宕机 |
| HAProxy + `/primary` HTTP 检查 | **HAProxy + mysqlchk** HTTP 检查 | 仅路由到当前可写主库 |
| PG 流复制 | **MySQL 8.4 GTID 复制**(可选半同步) | 主→从同步 |
| softdog watchdog(防脑裂兜底) | **read_only 管控 + 半同步 + 文档化残留风险** | 防脑裂(⚠️ 最弱环节,见"脑裂/fencing") |

## 目标 (Goals)

- 在两台 MySQL 服务器 + 一个轻量仲裁点上,一键部署可自动故障转移的 MySQL 集群。
- MySQL **不使用 Docker**,通过 MySQL 官方 APT 源裸机安装 **Oracle MySQL 8.4 LTS**(与现有 Docker 单机版同源 Oracle MySQL,保持发行版一致)。
- 故障转移自动:主库宕机后,Orchestrator 自动将从库提升为新主库(`read_only=0`),应用通过统一入口(HAProxy)经 mysqlchk 健康检查无感切换。
- 应用读写**全部路由到当前主库这一台**,避免异步复制延迟导致"读己之写不一致"。
- Orchestrator 自身通过 **raft 三节点**实现 HA(仲裁节点提供第三票),控制面账号最小权限。
- 提供与现有项目一致的 `curl` 一键体验:

  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-mysql-ha.sh)
  ```

- 复用现有公共模块(`lib/common.sh`)。
- 保留环境变量覆盖语义。
- 默认 Ubuntu 24.04,并对更新 Ubuntu 版本提供兼容分支。

## 非目标 (Non-Goals)

- ❌ 不做读写分离(读写都到主库;将来可加只读端口或换 ProxySQL)。
- ❌ 不做自动备份 / PITR。
- ❌ 不做监控告警(Prometheus / Grafana 等)。
- ❌ 不改动现有 Docker 版 MySQL 部署(`deploy.sh` 菜单项 3)。
- ❌ 不支持 3 个及以上 MySQL 数据节点(聚焦两 MySQL + 一仲裁)。
- ❌ 不做 SSH 编排(每台机器分别运行脚本)。
- ❌ 不引入 VIP / keepalived(应用侧配多个 HAProxy 地址实现接入冗余)。
- ❌ **不主动修改防火墙**(沿用现有项目传统);改为引导前做跨节点连通性预检 + 文档列出需放行端口。
- ❌ **不启用 MySQL/复制/Orchestrator TLS**(证书分发对一键脚本过重);改为最小权限账号 + 绑业务网卡 + 依赖网络隔离。该取舍为**显式接受**。
- ❌ **v1 不做内核级 STONITH / 自我隔离 watcher**(分区双写残留风险靠 read_only 管控 + 半同步 + 文档声明缓解,见"脑裂/fencing")。该取舍为**显式接受**。
- ❌ 不提供完整 teardown/卸载流程(本次仅 reinstall;teardown 列为后续)。
- ❌ 不用 ProxySQL(显式选择 HAProxy:与 PG HA 对称、纯 TCP 透传不存应用凭据、应用任意账号即接即用)。
- ❌ 不用 Group Replication / InnoDB Cluster(其要求三台均为完整数据成员,无纯仲裁角色,与"2 数据 + 1 轻量仲裁"拓扑不符)。

## 已确定的用户决策 (User Decisions Captured)

1. **拓扑 = 2 数据 + 1 轻量仲裁**(沿用 PG HA 三机布局,第三台不存数据)。
2. **技术路线 = Oracle MySQL 8.4 + Orchestrator**(保留原生 Oracle MySQL,排除 Galera/PXC、MariaDB、Group Replication)。
3. **部署形态 = 非 Docker / 裸机 apt**(与 PG HA 一致)。
4. **代理 = HAProxy + mysqlchk**(与 PG HA 对称;非 ProxySQL)。
5. **半同步 = 默认关(异步)**,提供 `MYSQL_HA_SEMISYNC=on` 开关(对标 `PG_HA_SYNC_MODE`)。
6. **防脑裂 v1 = read_only 管控 + 半同步选项 + 文档化残留风险**(不做自我隔离 watcher)。
7. **数据目录 = `${DATA_ROOT}/mysql-ha/data` + 处理 AppArmor**(与项目 `/data` 约定一致)。
8. **执行模型 = 每台分别运行**,交互选择本机角色,不做 SSH 编排。
9. **连接路由 = 读写都到当前主库**(从库不承担应用流量)。

## 目标系统与版本策略 (Target OS & Version Strategy)

- **默认 Ubuntu 24.04 LTS (noble)**,以 `detect_os` 识别;非 Ubuntu/Debian 拒绝运行(沿用现有 `detect_os`)。
- 软件来源与版本:
  - **MySQL 8.4 LTS**:来自 **MySQL 官方 APT 源**(`repo.mysql.com/apt/ubuntu`),组件 `mysql-8.4-lts`。**不使用交互式 `mysql-apt-config` .deb**,改为直接写 `/etc/apt/sources.list.d/mysql.list` + 导入 MySQL 签名公钥,`lsb_release -cs` 取代号,跨版本稳定(类比 PG HA 用 PGDG 官方脚本加源)。
  - **root 密码非交互**:`debconf-set-selections` 预置 `mysql-community-server/root-pass`、`re-root-pass`、`default-auth-override`(强密码加密),避免安装卡在交互。
  - **Orchestrator**:优先官方 release `.deb`(`github.com/openark/orchestrator`);若安装失败则 fallback 官方二进制 + 自写 systemd unit(类比 PG HA 的 etcd 二进制 fallback)。
  - **HAProxy**:noble 的 `haproxy`(2.8.x),用新 `http-check` 语法兼容 2.8→3.x。
- **跨版本兼容**:
  - MySQL APT suite/codename 用 `lsb_release -cs` 自动选,不手拼。
  - MySQL 8.4 复制/半同步术语用新名(`CHANGE REPLICATION SOURCE TO`、`rpl_semi_sync_source_*`、`log_replica_updates`、`SOURCE_AUTO_POSITION`),不依赖已移除的 `master/slave` 旧语法。
  - 8.4 中 `SUPER` 已弃用 → Orchestrator/管理账号改用动态权限(`SYSTEM_VARIABLES_ADMIN`、`REPLICATION_SLAVE_ADMIN` 等)。
  - HAProxy 3.x → 新 `http-check` 语法,一次性兼容。

## 架构与拓扑 (Architecture)

```
                          应用 / 客户端
                               │
                 全部连 HAProxy:6446 (读+写,始终当前主库)
             ┌─────────────────┴─────────────────┐
             ▼                                   ▼
   ┌────────────────────┐      ┌────────────────────┐      ┌────────────────────┐
   │  节点1 (node1)      │      │  节点2 (node2)      │      │  节点3 (node3)      │
   │  HAProxy :6446      │      │  HAProxy :6446      │      │  (不跑 HAProxy/MySQL)│
   │  mysqlchk :9200     │      │  mysqlchk :9200     │      │                     │
   │  MySQL :3306 ───────┼─GTID─┼─► MySQL :3306       │      │                     │
   │   (当前主,可写)     │ 复制 │   (从,super_read_only)│     │                     │
   │  Orchestrator :3000 │◄────►│  Orchestrator :3000 │◄────►│  Orchestrator :3000 │
   │  raft :10008        │      │  raft :10008        │      │  raft :10008 (仲裁)  │
   └────────────────────┘      └────────────────────┘      └────────────────────┘
                  Orchestrator raft 三成员 quorum=2,容忍任意一台宕机
```

**故障域分析:**

| 故障场景 | raft quorum | 结果 |
|----------|-------------|------|
| 仲裁节点 node3 宕机 | 2/3,满足 | 两 MySQL 正常,仍可自动切换 |
| 从节点 node2 宕机 | 2/3,满足 | 主库正常服务 |
| 主节点 node1 整机宕机 | 2/3,满足 | Orchestrator 提升 node2 为主(`read_only=0`),HAProxy 经 mysqlchk 在数秒内切流量 |
| 主节点 **网络分区但自身仍运行** | 2/3,满足 | ⚠️ **潜在双写窗口**(旧主 read_only 可能仍为 0 且仍有应用可直连其本地 HAProxy);见"脑裂/fencing" |
| 任意两台同时宕机 | 1/3,失去 quorum | Orchestrator 不自动提升(避免误判);需人工介入 |

**HAProxy 只到主库的机制:** backend 用 mysqlchk HTTP 健康检查 —— mysqlchk 查本机 `@@global.read_only`,只有当前可写主库(`read_only=0`)返回 200,从库(`read_only=1`)返回 503。故障转移后 Orchestrator 把新主置 `read_only=0`,其 mysqlchk 转为 200,HAProxy 在健康检查窗口内自动把 6446 切到新主库。

## 角色模型与执行流程 (Roles & Execution Flow)

每台机器运行时交互(或环境变量)选择**本机角色**:

| 角色 | 安装组件 | 说明 |
|------|----------|------|
| **A. 主节点 (primary)** | MySQL + Orchestrator + HAProxy + mysqlchk | 初始主库;建库/账号并配置为复制源,初始可写 |
| **B. 从节点 (replica)** | MySQL + Orchestrator + HAProxy + mysqlchk | `CHANGE REPLICATION SOURCE TO node1`(GTID 自动定位),默认 `super_read_only=ON` |
| **C. 仅仲裁 (arbiter)** | 仅 Orchestrator | raft 第三票 + 额外监控视角,无 MySQL 数据 |

**集群信息收集**(所有角色都需要):三台 IP(`MYSQL_HA_NODE1_IP`/`2`/`3`)、本机角色、集群名、各账号密码、各端口。支持交互提示与环境变量注入两种方式。

**执行流程与护栏:**

1. **三台先各自起 Orchestrator**(raft 三成员组网,quorum=2)。
2. **node1(primary)**:装 MySQL → `write_my_cnf`(server_id=1) → 启动 → 建 `repl`/`orchestrator`/`mysqlchk`/应用账号 → 显式置自身可写(`SET GLOBAL super_read_only=OFF; read_only=OFF`)→ 装/起 mysqlchk + HAProxy → 运行 `orchestrator-client -c discover -i node1:3306` 纳管拓扑。
3. **node2(replica)**:校验本机 datadir 为空(否则纳入 reinstall 清理)→ 装 MySQL → `write_my_cnf`(server_id=2,`super_read_only=ON`)→ 启动 → `CHANGE REPLICATION SOURCE TO`(指向 node1,`SOURCE_AUTO_POSITION=1`)+ `START REPLICA` → 装/起 mysqlchk + HAProxy。Orchestrator 自动发现该从库。
4. **node3(arbiter)**:仅装/起 Orchestrator,加入 raft。

> 只用 IP、不依赖 DNS(刻意决策);Orchestrator/raft `node` 标识用三台 IP。

## 网络与前置条件 (Network & Prerequisites)

- **端口连通性(脚本不改防火墙,但做预检 + 文档)**:三机互通需放行
  - `3306`(MySQL:GTID 复制 + HAProxy→MySQL + Orchestrator 监控连接)
  - `9200`(mysqlchk;HAProxy 跨机健康检查对端)
  - `3000`(Orchestrator HTTP/API,节点间互访)
  - `10008`(Orchestrator raft 节点间通信)
  - `6446`/`7001`(HAProxy 读写端口 / stats)

  primary 引导前对关键端口做跨节点探测(非阻塞提示,真正就绪门禁见各组件)。文档列出需放行清单(ufw/安全组)。
- **时间同步**:校验 `timedatectl` 的 NTP 同步状态;不同步则警告并建议装 chrony(raft 选举 / Orchestrator 心跳对时钟偏移敏感)。
- **systemd 依赖顺序**:自写/覆盖的 unit 加 `After=network-online.target`、`Wants=network-online.target`。

## 文件 / 模块布局 (File Layout)

```
install-mysql-ha.sh           # 新入口:薄加载器(沿用 install-pg-ha.sh 双模加载)
lib/mysql-ha/
├── config.sh                 # MYSQL_HA_* 默认值;自兜底 DATA_ROOT,不加载主 lib/config.sh
├── common.sh                 # 角色选择、集群 IP 收集、连通性/时间预检、密码生成、半同步开关解析
├── mysql.sh                  # 加 MySQL APT 源、装 mysql-server、write_my_cnf、建账号、配复制、AppArmor 处理
├── orchestrator.sh           # 装 orchestrator、write_orchestrator_config(sqlite+raft+failover)、write_orchestrator_unit、discover
├── mysqlchk.sh               # write_mysqlchk_script + write_mysqlchk_socket_unit + write_mysqlchk_service_unit + 凭据文件
├── haproxy.sh                # write_haproxy_config(mysql_primary 后端 + mysqlchk 检查)、install/start(MySQL 专用,独立于 pg-ha 的 haproxy.sh)
└── main.sh                   # mysql_ha_main:角色编排 + 最终摘要
```

**复用** `lib/common.sh`。**加载策略钉死**:`lib/mysql-ha/config.sh` 自带全部 `MYSQL_HA_*` 变量并 `DATA_ROOT="${DATA_ROOT:-/data}"` 自兜底;`install-mysql-ha.sh` **不加载** `lib/config.sh`(避免引入 Docker/`SELECT_*` 无关状态)。远程 curl 模式逐个下载 `lib/common.sh` + `lib/mysql-ha/*.sh`(现有加载器已支持子目录路径)。

> `lib/mysql-ha/haproxy.sh` 与 `lib/pg-ha/haproxy.sh` 是**各自独立**的文件(函数名同为 `write_haproxy_config`/`install_haproxy`/`start_haproxy`,但分属不同入口脚本、不会同时 source),避免耦合。

## 配置默认值 (Configuration Defaults)

全部可通过环境变量覆盖。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `MYSQL_HA_VERSION` | `8.4` | MySQL 版本(APT 组件 `mysql-8.4-lts`) |
| `MYSQL_HA_CLUSTER_NAME` | `mysql-ha` | Orchestrator 集群别名 |
| `MYSQL_HA_MYSQL_PORT` | `3306` | MySQL 端口 |
| `MYSQL_HA_PROXY_PORT` | `6446` | HAProxy 读写端口(应用连这个,只到主库) |
| `MYSQL_HA_PROXY_STATS_PORT` | `7001` | HAProxy stats 端口 |
| `MYSQL_HA_MYSQLCHK_PORT` | `9200` | mysqlchk 健康检查端口 |
| `MYSQL_HA_ORCH_PORT` | `3000` | Orchestrator HTTP/API 端口 |
| `MYSQL_HA_ORCH_RAFT_PORT` | `10008` | Orchestrator raft 端口 |
| `DATA_ROOT` | `/data` | 数据根(自兜底) |
| `MYSQL_HA_DATADIR` | `${DATA_ROOT}/mysql-ha/data` | MySQL 数据目录(含 AppArmor 处理) |
| `MYSQL_HA_ORCH_DATADIR` | `${DATA_ROOT}/mysql-ha/orchestrator` | Orchestrator SQLite + raft 数据目录 |
| `MYSQL_HA_SEMISYNC` | `off` | 半同步开关(`on` 启用 source/replica 半同步插件) |
| `MYSQL_HA_SEMISYNC_TIMEOUT` | `1000` | 半同步等待 ack 超时(ms,超时回退异步) |
| `MYSQL_HA_APP_DB` | `appdb` | 应用数据库名 |
| `MYSQL_HA_APP_USER` | `appuser` | 应用账号 |
| `MYSQL_HA_APP_ALLOWED_CIDR` | (提示输入,无默认) | 应用账号授权网段;**不默认 0.0.0.0/0 / %** |
| `MYSQL_HA_ROOT_PASSWORD` | (提示或自动生成) | MySQL root 密码 |
| `MYSQL_HA_REPL_PASSWORD` | (提示或自动生成) | `repl` 复制用户密码 |
| `MYSQL_HA_ORCH_PASSWORD` | (提示或自动生成) | `orchestrator` topology 用户密码 |
| `MYSQL_HA_MYSQLCHK_PASSWORD` | (自动生成) | `mysqlchk` 健康检查用户密码 |
| `MYSQL_HA_APP_PASSWORD` | (提示或自动生成) | 应用账号密码 |
| `MYSQL_HA_STATS_PASSWORD` | (自动生成) | HAProxy stats 页密码 |
| `MYSQL_HA_NODE1_IP`/`2`/`3` | (提示输入) | 三节点 IP |
| `LINUXSHELL_RAW_BASE_URL` | GitHub raw main | 远程模块基址 |

**一致性约束**:`MYSQL_HA_ROOT_PASSWORD`/`REPL`/`ORCH`/`MYSQLCHK`/`APP_PASSWORD` **必须在 node1/node2 两台保持一致**(经环境变量或交互提供)。`repl` 账号按 node1/node2 两台 IP 授权(failover 后角色互换);`orchestrator` 账号按 **node1/node2/node3 三台 IP** 授权(仲裁节点也连 MySQL 监控)。

**文件路径**(测试 export 覆盖到临时目录):

| 变量 | 默认值 |
|------|--------|
| `MYSQL_HA_MYCNF` | `/etc/mysql/mysql.conf.d/zz-mysql-ha.cnf` |
| `MYSQL_HA_ORCH_CONF` | `/etc/orchestrator.conf.json` |
| `MYSQL_HA_ORCH_UNIT` | `/etc/systemd/system/orchestrator.service` |
| `MYSQL_HA_HAPROXY_CFG` | `/etc/haproxy/haproxy.cfg` |
| `MYSQL_HA_MYSQLCHK_SCRIPT` | `/usr/local/bin/mysqlchk` |
| `MYSQL_HA_MYSQLCHK_SOCKET` | `/etc/systemd/system/mysqlchk.socket` |
| `MYSQL_HA_MYSQLCHK_SERVICE` | `/etc/systemd/system/mysqlchk@.service` |
| `MYSQL_HA_MYSQLCHK_CNF` | `/etc/mysql/mysqlchk.cnf` |

## 各组件设计 (Component Design)

### MySQL (`lib/mysql-ha/mysql.sh`)

- **加 MySQL APT 源**:写 `/etc/apt/sources.list.d/mysql.list`(`deb https://repo.mysql.com/apt/ubuntu <codename> mysql-8.4-lts`)+ 导入 MySQL 签名公钥到 keyring;非交互预置 debconf root 密码与认证插件。`apt-get update && apt-get install -y mysql-server`。
- **`write_my_cnf`**(纯函数,接收本机 server_id 与角色):写 `${MYSQL_HA_MYCNF}`:
  - `server_id`(node1=1 / node2=2,**必须唯一**)、`bind-address`(业务网卡)、`port`、`datadir=${MYSQL_HA_DATADIR}`
  - GTID:`gtid_mode=ON`、`enforce_gtid_consistency=ON`
  - binlog:`log_bin`、`binlog_format=ROW`、`log_replica_updates=ON`(从库可被再提升为源的前提)、`binlog_expire_logs_seconds`
  - relay:`relay_log`、`relay_log_recovery=ON`
  - **boot 安全默认**:`super_read_only=ON`(**两台数据节点 my.cnf 都置 ON**),使任何节点重启后默认只读,不会因旧配置自动可写造成双写;primary 引导阶段与 Orchestrator 提升时才显式翻转为可写(见"脑裂/fencing")
  - 半同步块(由 `MYSQL_HA_SEMISYNC` 控制,见下)
- **建账号**(primary 引导阶段,经本地 socket / root 执行):
  - `repl`@`<node1_ip>`、`repl`@`<node2_ip>`:`REPLICATION SLAVE`(主从角色会因 failover 互换,两台 IP 都需授权)
  - `orchestrator`@`<node1_ip>`、`@<node2_ip>`、`@<node3_ip>`:`PROCESS, REPLICATION SLAVE, REPLICATION CLIENT, RELOAD` + 动态权限 `SYSTEM_VARIABLES_ADMIN, REPLICATION_SLAVE_ADMIN` + `SELECT ON mysql.*`(8.4 用动态权限替代弃用的 `SUPER`)。**三台 IP 都要授权**:仲裁节点(node3)的 Orchestrator 也会连 node1/node2 的 MySQL 做监控
  - `mysqlchk`@`localhost`:`REPLICATION CLIENT`(读 read_only/复制状态;凭据放 600 的 `MYSQL_HA_MYSQLCHK_CNF`,不进程参数)
  - 应用账号 `MYSQL_HA_APP_USER`@`${MYSQL_HA_APP_ALLOWED_CIDR}`:`ALL ON ${MYSQL_HA_APP_DB}.*`(**不用 `%`/`0.0.0.0/0`**)
- **配复制**(replica):`CHANGE REPLICATION SOURCE TO SOURCE_HOST='<node1_ip>', SOURCE_USER='repl', SOURCE_PASSWORD='...', SOURCE_AUTO_POSITION=1; START REPLICA;`
- **AppArmor**:datadir 移出 `/var/lib/mysql` 时,若存在 `/etc/apparmor.d/usr.sbin.mysqld` profile,则在 `/etc/apparmor.d/local/usr.sbin.mysqld` 增加 `${MYSQL_HA_DATADIR}/ rwk` 规则(或 `tunables/alias` 别名)并 `apparmor_parser -r` 重载,否则 mysqld 启动被拒(列为实测风险)。datadir 初始化前 `chown mysql:mysql` + 适当权限。

### 半同步复制 (`MYSQL_HA_SEMISYNC`)

- `off`(默认):纯 GTID 异步复制,RPO>0(主库突宕可能丢最后若干事务),对标 `PG_HA_SYNC_MODE=off`。
- `on`:
  - 主库 `INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so'`;从库 `rpl_semi_sync_replica SONAME 'semisync_replica.so'`(8.4 新插件名)。
  - 主库 `rpl_semi_sync_source_enabled=1`、`rpl_semi_sync_source_wait_for_replica_count=1`、`rpl_semi_sync_source_timeout=${MYSQL_HA_SEMISYNC_TIMEOUT}`;从库 `rpl_semi_sync_replica_enabled=1`。
  - 逼近零丢失;代价:从库不可达且超时后主库回退异步(可用性优先)。

### Orchestrator (`lib/mysql-ha/orchestrator.sh`)

- **安装**:官方 release `.deb`;失败 fallback 官方二进制 + 自写 `${MYSQL_HA_ORCH_UNIT}`(`After=network-online.target`、`ExecStart=/usr/local/orchestrator/orchestrator --config ${MYSQL_HA_ORCH_CONF} http`)。
- **`write_orchestrator_config`**(纯函数,接收本机 IP、三节点 IP):写 `${MYSQL_HA_ORCH_CONF}`(合法 JSON):
  - `ListenAddress: ":3000"`、`MySQLTopologyUser/Password`(topology 账号)
  - 后端:`BackendDB: "sqlite"`、`SQLite3DataFile: "${MYSQL_HA_ORCH_DATADIR}/orchestrator.sqlite3"`(仲裁节点无 MySQL,SQLite 后端使其真正轻量)
  - raft:`RaftEnabled: true`、`RaftDataDir: "${MYSQL_HA_ORCH_DATADIR}"`、`RaftBind: "<本机 IP>"`、`DefaultRaftPort: 10008`、`RaftNodes: ["<ip1>","<ip2>","<ip3>"]`
  - 故障转移:`RecoverMasterClusterFilters: ["*"]`、`ApplyMySQLPromotionAfterMasterFailover: true`、`FailMasterPromotionIfSQLThreadNotUpToDate: true`、`RecoveryPeriodBlockSeconds`
  - `PostFailoverProcesses`:对**可达的旧主**执行 `SET GLOBAL super_read_only=1`(尽力 fencing)+ 记录日志(分区不可达时无效,见"脑裂/fencing")
  - 文件 `chmod 600`(含 topology 密码)
- **discover**:primary 复制就绪后执行 `orchestrator-client -c discover -i <node1_ip>:3306`,把集群纳管;Orchestrator 自动发现 replica。

### mysqlchk (`lib/mysql-ha/mysqlchk.sh`)

- **`write_mysqlchk_script`**(纯函数,写 `${MYSQL_HA_MYSQLCHK_SCRIPT}`):用 `mysqlchk` 账号(读 `${MYSQL_HA_MYSQLCHK_CNF}`)查 `SELECT @@global.read_only`:
  - `0`(当前可写主库)→ 输出 `HTTP/1.1 200 OK`(+ 简短 body)
  - 非 0 或连接失败 → 输出 `HTTP/1.1 503 Service Unavailable`
- **systemd socket 激活**:`write_mysqlchk_socket_unit`(`ListenStream=9200`、`Accept=yes`)+ `write_mysqlchk_service_unit`(`mysqlchk@.service`,`StandardInput=socket`、`StandardOutput=socket`、低权限 `User`),`systemctl enable --now mysqlchk.socket`。
- 仅在两台 MySQL 节点部署;仲裁节点不需要。

### HAProxy (`lib/mysql-ha/haproxy.sh`)

- **安装**:apt `haproxy`(2.8.x)。
- **`write_haproxy_config`**(纯函数,写 `${MYSQL_HA_HAPROXY_CFG}`),用**新 `http-check` 语法**(兼容 2.8→3.x):
  ```
  frontend mysql_write
      bind *:${MYSQL_HA_PROXY_PORT}
      mode tcp
      default_backend mysql_primary

  backend mysql_primary
      mode tcp
      option httpchk
      http-check send meth GET uri /
      http-check expect status 200
      default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions
      server node1 <ip1>:3306 check port ${MYSQL_HA_MYSQLCHK_PORT}
      server node2 <ip2>:3306 check port ${MYSQL_HA_MYSQLCHK_PORT}

  listen stats
      bind *:${MYSQL_HA_PROXY_STATS_PORT}
      mode http
      stats enable
      stats uri /
      stats auth admin:${MYSQL_HA_STATS_PASSWORD}
  ```
  - `inter 1s fall 2` 把"探测到旧主不可写"窗口压到约 2s;`on-marked-down shutdown-sessions` 在旧主降级时立即掐断既有连接,防止继续写旧主。
  - `stats auth` 保护 stats 页(密码自动生成);文件 `chmod 600`。
- **部署位置**:两台 MySQL 节点各跑一个 HAProxy。应用侧配置**两个** HAProxy 地址(`node1:6446`、`node2:6446`),且应用需具备**连接失败重试/多地址轮询**能力——文档明确。

## 脑裂 / fencing (Split-brain / Fencing) ⚠️

> **这是 Orchestrator + 异步复制相比 Patroni+watchdog 的真实短板,必须诚实对待。** Orchestrator 没有内核级 STONITH。

**风险:** 旧主被**网络分区但自身仍在运行**、且仍有应用能直连其本地 HAProxy 时,其 `read_only` 可能仍为 0,存在**双写窗口**。

**v1 缓解(显式接受残留风险):**

1. **boot 安全默认**:两台数据节点 my.cnf 均 `super_read_only=ON`。任何节点重启后默认只读,杜绝"旧主重启后自动可写"这一最常见双写来源。
2. **Orchestrator 提升语义**:`ApplyMySQLPromotionAfterMasterFailover: true` 使新主被显式置 `read_only=0`;旧主回归后由 Orchestrator 重新指向为新主的 replica 并保持只读。
3. **PostFailover fencing 钩子**:对**可达的**旧主置 `super_read_only=1`(分区不可达时无效)。
4. **半同步选项**:`MYSQL_HA_SEMISYNC=on` 限制故障切换时的数据分歧量。
5. **代理层兜底**:mysqlchk 仅在 `read_only=0` 时返回 200;`on-marked-down shutdown-sessions` 立即掐断旧连接。
6. **文档显式声明**:与 PG HA 对故障窗口的诚实处理一致,在 README 明确分区双写残留风险与运维建议(failover 后旧主务必经 Orchestrator 重新纳管为只读 replica 后再放行流量;必要时人工 fencing)。

**边界与后续:** 真正消除分区双写需"自我隔离"(节点失去 raft 多数票时自动 `super_read_only=1`),列为 **v1 非目标**、后续可选增强。强一致/支付类场景**建议 `MYSQL_HA_SEMISYNC=on`**。

## 安全设计 (Security Design)

> 整体姿态:**最小权限账号 + 绑业务网卡 + 依赖网络隔离**,不上 TLS(显式接受)。密码由脚本 `openssl rand` 自动生成,在最终摘要中一次性展示并提示妥善保存。

- **MySQL 账号**:`repl`/`orchestrator` 按节点 IP/CIDR 授权(非 `%`);`mysqlchk` 仅 `localhost` + 最小权限;应用账号限 `MYSQL_HA_APP_ALLOWED_CIDR`。
- **Orchestrator**:topology 账号最小动态权限;`ListenAddress`/`RaftBind` 绑业务网卡;`orchestrator.conf.json` 含密码 → `chmod 600`。无 TLS,依赖网络隔离。
- **配置文件权限**:`${MYSQL_HA_MYCNF}`(若含半同步无敏感信息可 644;含密码的初始化片段不落盘)、`${MYSQL_HA_ORCH_CONF}`、`${MYSQL_HA_MYSQLCHK_CNF}`、`${MYSQL_HA_HAPROXY_CFG}` 一律 `chmod 600` + owner 收紧。
- **凭据不入命令行**:mysqlchk / 复制配置经凭据文件或 here-doc,不在 `ps` 可见的参数里出现密码。
- **复制连接**:明文(无 TLS),**显式接受**,依赖网络隔离。
- **环境变量注入**:提示密码经环境变量注入会落入 shell history/进程 environ 的风险。
- **HAProxy stats**:`stats auth` 保护。

## 模块加载设计 (Module Loading)

与现有 `install-pg-ha.sh` 一致的双模加载:本地 `lib/mysql-ha/config.sh` 存在则本地加载;否则从 `${LINUXSHELL_RAW_BASE_URL}` 下载 `lib/common.sh` + `lib/mysql-ha/*.sh` 到临时目录再 source。任一模块失败带模块名与 URL 报错。所有入口/模块 `set -euo pipefail`,模块只可 source、不自调用 `mysql_ha_main`。

## 幂等 / 重装 / 错误处理 (Idempotency / Reinstall / Error Handling)

- **幂等**:对 `${MYSQL_HA_MYCNF}`、`${MYSQL_HA_ORCH_CONF}`、`${MYSQL_HA_HAPROXY_CFG}`、各 unit 复用 `confirm_overwrite` 的 `[s]kip/[o]verwrite/[u]se/[r]einstall`。
- **reinstall 拆成两类**(关键,避免破坏好集群):
  - **(a) 重装 MySQL 数据层**:停 `mysql` → 清 `${MYSQL_HA_DATADIR}` → 重新初始化、建账号、(replica)重配复制。
  - **(b) 重置 Orchestrator**:停 `orchestrator` → `orchestrator-client -c forget`(或清 `${MYSQL_HA_ORCH_DATADIR}` 的 SQLite/raft)→ 重新组网。**注意**:raft 成员级重置需谨慎,单独路径 + 显著告警。
- **replica 克隆前提校验**:本机 `${MYSQL_HA_DATADIR}` 为空(否则纳入 reinstall);primary 复制源就绪。
- **端口检查**:`assert_port_available` 检查本机端口;跨机连通性见网络与前置条件。
- 不做自动跨机回滚。

## 测试策略 (Testing Strategy)

遵循 `tests/test_pg_ha.sh` 风格——**测配置生成正确性,不真起服务**;但**显式承认边界**:自动 failover / 单主路由 / 分区双写等运行期正确性无法被配置生成测试覆盖,须靠成功标准里的手工/集成验收。

- **独立测试文件**:新建 `tests/test_mysql_ha.sh`,独立 `source` `lib/common.sh` + `lib/mysql-ha/*.sh`;**不污染** `tests/test_deploy.sh` 与 `tests/test_pg_ha.sh`。现有测试保持绿色。
- **纯函数契约**:`write_my_cnf`/`write_orchestrator_config`/`write_haproxy_config`/`write_mysqlchk_script` 设计为**接收显式参数**的纯函数,便于在临时目录注入任意组合断言。
- **断言点**:
  - my.cnf:`server_id` 随角色(node1=1/node2=2)、`gtid_mode=ON`、`enforce_gtid_consistency=ON`、`log_replica_updates=ON`、两节点 `super_read_only=ON`、半同步 `on`/`off` 分支(插件与变量)。
  - orchestrator:`BackendDB=sqlite`、`RaftEnabled=true`、`RaftNodes` 三 IP、`DefaultRaftPort`、`ApplyMySQLPromotionAfterMasterFailover=true`、topology user 写入;且 `python3 -m json.tool`(或 `python3 -c json.load`)校验 JSON 合法(无依赖则跳过)。
  - mysqlchk:脚本含 `@@global.read_only` 查询、`200`/`503` 两分支;socket `ListenStream=9200`。
  - haproxy:`http-check send meth GET uri /` + `expect status 200` + `on-marked-down shutdown-sessions` + 两 server 行(`check port 9200`)+ `stats auth` + `mode tcp`。
  - 角色解析(primary/replica/arbiter 同义词)、集群 IP 收集(缺 IP/非法值处理)、幂等分支、环境变量覆盖。
  - 密码确实写入但**测试中不回显**(避免进 CI 日志);含密码文件断言 `600`。
- **语法冒烟**:
  ```bash
  bash -n install-mysql-ha.sh
  find lib/mysql-ha -name '*.sh' -print0 | xargs -0 -n1 bash -n
  bash tests/test_mysql_ha.sh all
  bash tests/test_deploy.sh all      # 保持绿色
  bash tests/test_pg_ha.sh all       # 保持绿色
  ```

## 实现风险 (Implementation Risks)

| 风险 | 缓解 |
|------|------|
| MySQL APT 源 `mysql-apt-config` 交互式 .deb 卡住 | 直接写 source.list + 导入公钥,非交互;debconf 预置 root 密码 |
| MySQL 8.4 移除/弃用旧术语(`SUPER`/`master/slave`) | 用动态权限 + `CHANGE REPLICATION SOURCE`/`rpl_semi_sync_source_*`/`log_replica_updates` |
| 改 datadir 被 AppArmor 拦截致 mysqld 起不来 | 检测 profile 存在则加 local 规则/alias 并 reload;datadir 预建 chown mysql |
| 旧主重启后自动可写造成双写 | 两节点 my.cnf `super_read_only=ON` 安全默认;Orchestrator 提升才翻转可写 |
| 网络分区双写(Orchestrator 无 STONITH) | read_only 管控 + PostFailover fencing 钩子 + 半同步选项 + on-marked-down + **文档化残留风险**(v1 接受) |
| Orchestrator raft 成员级重置破坏性 | reinstall 区分 MySQL 数据层 vs Orchestrator 重置 + 告警 |
| 跨节点端口未通(尤其 9200/3000/10008)致 backend 全 DOWN 或 raft 不成 | 引导前连通性预检 + 文档放行清单 |
| HAProxy 接入单点 | 两台各跑 HAProxy + 应用多地址重连 |
| 异步 RPO 非零 | 默认接受;`MYSQL_HA_SEMISYNC=on` 可逼近零丢失 |
| Orchestrator(openark)维护活跃度一般 | 锁定一个已知可用 release 版本;二进制 fallback;配置最小化 |
| server_id 冲突致复制错乱 | 由角色严格分配 node1=1/node2=2,单测断言 |

## 文档更新 (Documentation Updates)

更新 `README.md`:新增"MySQL 高可用(Orchestrator)"小节 —— `install-mysql-ha.sh` 一键命令、三角色(primary/replica/arbiter)与推荐执行顺序(arbiter→primary→replica)、拓扑与故障域、应用连接(连 6446、读写都主库、配两台 HAProxy 地址且需重连能力)、需放行端口清单、`MYSQL_HA_*` 环境变量参考、安全说明(最小权限账号 + 不上 TLS 依赖隔离)、**脑裂/fencing 残留风险与运维建议 + 半同步开关**、明确这是**非 Docker** 路径与菜单项 3 并存。数据目录表补充 `mysql-ha/`。

## 成功标准 (Success Criteria)

- 在两台 MySQL + 一仲裁执行 `install-mysql-ha.sh`(各选角色)后,Orchestrator(`orchestrator-client -c topology -i <cluster>` 或 Web :3000)显示一主一从、复制正常。
- 应用连 HAProxy `6446` 正常读写,流量只落主库。
- 模拟主库宕机后,从库自动提升为新主(`read_only=0`),HAProxy `6446` 在数秒内切到新主库,应用恢复读写。
- 仲裁节点宕机不影响两 MySQL 服务与切换能力;任意两台宕机时不误切换。
- `MYSQL_HA_SEMISYNC=on` 时半同步插件生效(`SHOW STATUS LIKE 'Rpl_semi_sync%'`)。
- 控制面账号最小权限;含密码配置文件 `600`;mysqlchk 仅主库返回 200。
- 配置生成/解析(JSON 合法)/幂等/环境变量覆盖/server_id 分配的单元测试全绿(`tests/test_mysql_ha.sh`);所有脚本 `bash -n` 通过;现有 `tests/test_deploy.sh`、`tests/test_pg_ha.sh` 不受影响。
- 现有 `deploy.sh` Docker 部署行为完全不变。

## 待澄清 / 实现期需实测确认 (Open Items for Implementation)

1. **Orchestrator release 版本锁定**:实现期选定一个 noble 上可用的 `.deb`/二进制版本并固化(参考 PG HA 锁 Patroni 4.1.x 的做法)。
2. **rejoin 旧主的 read_only 策略**:实测 Orchestrator 在旧主回归时是否稳定将其置只读 replica;若有边界,补充运维步骤/钩子。
3. **MySQL 8.4 半同步插件 .so 名**:实测 `semisync_source.so`/`semisync_replica.so` 在 8.4 包中的实际路径与变量名。
4. **AppArmor profile 是否随 MySQL 社区包安装**:实测决定 AppArmor 处理是否需执行(条件化)。
