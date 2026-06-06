# MySQL + Orchestrator 两主机自动 HA 部署 — 设计方案

> 本版本已根据三个子代理(技术准确性 / HA 架构 / 完整性与安全)的审查结论修订。修订要点见文末"审查修订记录"。
> 本方案在已上线的 PostgreSQL + Patroni HA(见 `2026-06-06-postgres-patroni-ha-design.md`)之后新增,刻意保持架构对称、代码风格与测试策略一致。

## 概述 (Summary)

为现有 `linuxshell` 部署项目新增一条**非 Docker、跨机器**的 MySQL 高可用部署路径:在两台服务器上以 **Orchestrator** 管理 MySQL 8.4 GTID 主从复制,配合第三台轻量仲裁节点(仅跑 Orchestrator,参与 raft 投票、不存数据),实现**自动故障转移**。目标系统为 **Ubuntu 24.04 LTS (noble)**,并设计为可向更新 Ubuntu 版本兼容。

该功能以独立入口脚本 `install-mysql-ha.sh` 提供(类似 `install-pg-ha.sh`),复用 `lib/common.sh` 公共模块,新增逻辑收敛在 `lib/mysql-ha/` 子目录。它**不改动**现有基于 Docker 的单机 MySQL 部署(`deploy.sh` 菜单项 3 保持不变)。

核心原则与现有项目一致:**每台机器上 `curl` 执行一次**、模块化、配置可通过环境变量覆盖、测试聚焦"配置文件生成正确性"。

### 关键认知:Orchestrator ≠ Patroni(决定本设计形态)

Patroni 是**有状态编排器**:持有 DCS leader 锁,每个周期把 leader **收敛**为可写,leader 重启后自动拉回可写。**Orchestrator 不是**——它是"故障检测 + 故障时一次性拓扑修复",**只在提升那一刻**对新主置一次 `read_only=0`,**不维护稳态可写性**(openark/orchestrator Issue #865:"无可写主"不被判定为故障、不触发恢复)。

直接后果:若仅靠 my.cnf 的 `super_read_only` 静态默认 + Orchestrator 提升时翻转,**主库/新主任意一次重启都会回到只读且无人修复 → 全集群无可写主、应用写入静默中断**("无可写主死锁")。因此本设计**必须**引入一个补足 Orchestrator 稳态能力的组件——**自愈 + 自我隔离 watcher**(见下),它同时承担 PG 版中 "Patroni 稳态收敛" 与 "watchdog 自我 fence" 两个角色。

### 与 PG HA 的组件映射

| PG HA | MySQL HA | 角色 |
|---|---|---|
| Patroni(拓扑管理 + 故障转移) | **Orchestrator**(raft 三节点 + 各自 SQLite) | 故障检测 + 自动提升 + 重新指向复制 |
| Patroni 稳态收敛循环 + softdog watchdog | **mysql-ha-watcher**(每数据节点常驻) | 维持"当前主"可写(补 Orchestrator 稳态缺失)+ 失去 raft 多数票时自我 `super_read_only=ON`(防脑裂) |
| etcd 三成员 | **Orchestrator raft**(quorum=2) | 共识,容忍任意一台宕机 |
| HAProxy + `/primary` HTTP 检查 | **HAProxy + mysqlchk** HTTP 检查 | 仅路由到当前可写主库 |
| PG 流复制 | **MySQL 8.4 GTID 复制**(可选半同步) | 主→从同步 |

## 目标 (Goals)

- 在两台 MySQL 服务器 + 一个轻量仲裁点上,一键部署可自动故障转移的 MySQL 集群。
- MySQL **不使用 Docker**,通过 MySQL 官方 APT 源裸机安装 **Oracle MySQL 8.4 LTS**(与现有 Docker 单机版同源 Oracle MySQL,保持发行版一致)。
- 故障转移自动:主库宕机后,Orchestrator 自动将从库提升为新主库(`read_only=0`),watcher 维持其可写,应用通过统一入口(HAProxy)经 mysqlchk 健康检查无感切换。
- **稳态自愈**:任一数据节点重启后,watcher 依据 Orchestrator 的拓扑判定自动把"当前主"收敛为可写,杜绝"无可写主死锁"。
- 应用读写**全部路由到当前主库这一台**,避免异步复制延迟导致"读己之写不一致"。
- Orchestrator 自身通过 **raft 三节点**实现 HA;**控制面(Orchestrator HTTP/API)启用 basic auth + 绑业务网卡**;各账号最小权限。
- 提供与现有项目一致的 `curl` 一键体验:

  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-mysql-ha.sh)
  ```

- 复用现有公共模块(`lib/common.sh`)。保留环境变量覆盖语义。默认 Ubuntu 24.04,并对更新版本提供兼容分支。

## 非目标 (Non-Goals)

- ❌ 不做读写分离(读写都到主库;将来可加只读端口或换 ProxySQL)。
- ❌ 不做自动备份 / PITR。
- ❌ 不做监控告警(Prometheus / Grafana 等)。
- ❌ 不改动现有 Docker 版 MySQL 部署(`deploy.sh` 菜单项 3)。
- ❌ 不支持 3 个及以上 MySQL 数据节点(聚焦两 MySQL + 一仲裁)。
- ❌ 不做 SSH 编排(每台机器分别运行脚本)。
- ❌ 不引入 VIP / keepalived(应用侧配多个 HAProxy 地址实现接入冗余)。
- ❌ **不主动修改防火墙**;改为引导前做跨节点连通性预检 + 文档列出需放行端口。
- ❌ **不启用 MySQL/复制/Orchestrator 传输层 TLS**(证书分发对一键脚本过重);改为最小权限账号 + Orchestrator HTTP basic auth + 绑业务网卡 + 依赖网络隔离。该取舍为**显式接受**。
- ❌ **不做内核级硬件 STONITH**(无 `/dev/watchdog` 物理 reset);改用用户态 watcher 自我隔离(有界窗口 + 依赖 watcher 存活,见"脑裂/fencing")。该取舍为**显式接受**。
- ❌ 不提供完整 teardown/卸载流程(本次仅 reinstall;teardown 列为后续)。
- ❌ 不用 ProxySQL(显式选 HAProxy:与 PG HA 对称、纯 TCP 透传不存应用凭据、应用任意账号即接即用)。
- ❌ 不用 Group Replication / InnoDB Cluster(其要求三台均为完整数据成员,无纯仲裁角色,与"2 数据 + 1 轻量仲裁"拓扑不符)。

## 已确定的用户决策 (User Decisions Captured)

1. **拓扑 = 2 数据 + 1 轻量仲裁**(沿用 PG HA 三机布局,第三台不存数据)。
2. **技术路线 = Oracle MySQL 8.4 + Orchestrator**(排除 Galera/PXC、MariaDB、Group Replication)。
3. **部署形态 = 非 Docker / 裸机 apt**。
4. **代理 = HAProxy + mysqlchk**(非 ProxySQL)。
5. **半同步 = 默认关(异步)**,提供 `MYSQL_HA_SEMISYNC=on` 开关(对标 `PG_HA_SYNC_MODE`)。
6. **防脑裂/可用性 = 自愈 + 自我隔离 watcher 入 v1**(审查推翻了"v1 不做 watcher"的初版取舍:无 watcher 则"无可写主死锁"与"分区双写"二者必居其一,均非生产可用)。
7. **数据目录 = `${DATA_ROOT}/mysql-ha/data`**(与项目 `/data` 约定一致)。
8. **执行模型 = 每台分别运行**,交互选择本机角色。
9. **连接路由 = 读写都到当前主库**。

## 目标系统与版本策略 (Target OS & Version Strategy)

- **默认 Ubuntu 24.04 LTS (noble)**,以 `detect_os` 识别;非 Ubuntu/Debian 拒绝运行。
- 软件来源与版本:
  - **MySQL 8.4 LTS**:来自 **MySQL 官方 APT 源**(`repo.mysql.com/apt/ubuntu`),组件 `mysql-8.4-lts`。**不使用交互式 `mysql-apt-config` .deb**,改为直接写 `/etc/apt/sources.list.d/mysql.list`(`deb [signed-by=...] https://repo.mysql.com/apt/ubuntu <codename> mysql-8.4-lts`)+ 导入 MySQL 签名公钥到独立 keyring,`lsb_release -cs` 取代号。**注意**:即便不用 mysql-apt-config,`mysql-community-server` 包仍会就 root 密码交互 → 仍须 `debconf-set-selections` 预置:`mysql-community-server/root-pass`、`mysql-community-server/re-root-pass`、`mysql-server/default-auth-override`(值取整串字面 `Use Strong Password Encryption (RECOMMENDED)`)。实现期用 `debconf-show mysql-community-server` 实测核对键名(noble 上 owner 偶有 `mysql-community-server` vs `mysql-server` 漂移)。
  - **Orchestrator**:优先官方 release `.deb`(`github.com/openark/orchestrator`);失败 fallback 官方二进制 + 自写 systemd unit。**锁定一个 noble 上已知可用的版本**(类比 PG HA 锁 Patroni 4.1.x)。
  - **HAProxy**:noble 的 `haproxy`(2.8.x),用新 `http-check` 语法兼容 2.8→3.x。
- **跨版本兼容**:APT codename 用 `lsb_release -cs` 自动选;复制/半同步用 8.4 新术语(`CHANGE REPLICATION SOURCE TO`、`rpl_semi_sync_source_*`、`log_replica_updates`、`SOURCE_AUTO_POSITION`);`SUPER` 已弃用 → 管理账号用动态权限(`SYSTEM_VARIABLES_ADMIN`、`REPLICATION_SLAVE_ADMIN`)。

## 8.4 认证与无 TLS 跨机连接处理 (caching_sha2 + No TLS)

8.4 默认认证插件 `caching_sha2_password`,且 `mysql_native_password` 组件**默认不加载**。在**无 TLS**(本设计显式接受)下,跨机连接做 sha2 握手时服务端默认不下发 RSA 公钥 → 会报 `Authentication requires secure connection` 而失败。这是 8.4 裸机非 TLS 部署的头号坑,必须处理:

- **复制连接(replica→source)**:`CHANGE REPLICATION SOURCE TO ... SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1`(显式从源拉公钥)。
- **Orchestrator/其它跨机连接(orchestrator→各 MySQL)**:连接时启用 `--get-server-public-key` 等价语义(Orchestrator 的 MySQL 连接参数里开启获取服务端公钥)。
- 不改用 `mysql_native_password`(8.4 默认关闭,且更弱);坚持 caching_sha2 + 拉公钥。
- 本机连接(mysqlchk/watcher → localhost)走 socket 或 `127.0.0.1`,不受此影响。

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
   │  watcher (常驻)     │      │  watcher (常驻)     │      │                     │
   │  MySQL :3306 ───────┼─GTID─┼─► MySQL :3306       │      │                     │
   │   (当前主,可写)     │ 复制 │   (从,super_read_only)│     │                     │
   │  Orchestrator :3000 │◄────►│  Orchestrator :3000 │◄────►│  Orchestrator :3000 │
   │  raft :10008        │      │  raft :10008        │      │  raft :10008 (仲裁)  │
   └────────────────────┘      └────────────────────┘      └────────────────────┘
         Orchestrator raft 三成员 quorum=2,容忍任意一台宕机;3000 启用 basic auth
```

**故障域分析:**

| 故障场景 | raft quorum | 结果 |
|----------|-------------|------|
| 仲裁节点 node3 宕机 | 2/3,满足 | 两 MySQL 正常,仍可自动切换 |
| 从节点 node2 宕机 | 2/3,满足 | 主库正常服务 |
| 主节点 node1 整机宕机 | 2/3,满足 | Orchestrator 提升 node2(`read_only=0`),watcher 维持其可写,HAProxy 经 mysqlchk 在数秒内切流量 |
| **当前主 MySQL 重启**(整机存活) | 2/3,满足 | my.cnf 回到只读 → **watcher 检测到本机仍是 Orchestrator 认定的主 + raft 健康 → 自动 `super_read_only=OFF` 恢复可写**(自愈,不再死锁) |
| **主节点网络分区**(自身仍运行) | 旧主侧失多数 | 旧主的本机 Orchestrator 失去 raft 多数 → **watcher 自我 `super_read_only=ON`** → 其 mysqlchk 转 503 → 本机 HAProxy 标 DOWN + 掐连接;新主侧正常提升。残留:watcher 轮询窗口内的有界双写(见"脑裂/fencing") |
| 两台数据节点同时宕机 | 1/3,失多数 | Orchestrator 不自动提升;watcher 自我隔离;需人工介入 |
| **两台全只读(无可写主)** | — | 仅当 watcher 失效且发生重启才可能;watcher `Restart=always` + 摘要告警兜底;此状态下 6446 全 DOWN,需人工 `SET GLOBAL super_read_only=OFF` |

**HAProxy 只到主库的机制:** backend 用 mysqlchk HTTP 健康检查 —— 只有 `read_only=0` 的当前可写主库返回 200,从库返回 503。故障转移后新主 `read_only=0`,其 mysqlchk 转 200,HAProxy 在健康检查窗口内自动把 6446 切到新主库。

## 角色模型与执行流程 (Roles & Execution Flow)

| 角色 | 安装组件 | 说明 |
|------|----------|------|
| **A. 主节点 (primary)** | MySQL + Orchestrator + HAProxy + mysqlchk + watcher | 初始主库;建库/账号并配置为复制源 |
| **B. 从节点 (replica)** | MySQL + Orchestrator + HAProxy + mysqlchk + watcher | `CHANGE REPLICATION SOURCE TO node1`,默认 `super_read_only=ON` |
| **C. 仅仲裁 (arbiter)** | 仅 Orchestrator | raft 第三票 + 额外监控视角,无 MySQL 数据 |

**账号经 GTID 复制(关键机制,必须讲清):** `gtid_mode=ON` + `log_bin` 下,**所有 MySQL 账号仅在 primary 用 `CREATE USER`/`GRANT` 创建,经 binlog/GTID 自动复制到 replica**。因此:
- **replica 绝不重复执行任何 `CREATE USER`/`GRANT`**(否则 GTID 冲突使复制中断);replica 路径只在本机落地各凭据文件。
- `mysqlchk`/`watcher` 这类 `@localhost` 账号的 `mysql.user` 行同样复制到 replica → **node2 本地凭据文件必须写入与 node1 完全相同的密码**(取自统一的 `MYSQL_HA_*_PASSWORD`,故两台必须一致),否则 node2 的 mysqlchk/watcher 连不上本机 MySQL。
- 时序:primary 先建账号、再被 replica 以 `SOURCE_AUTO_POSITION=1` 接上(账号作为已有事务被回放/续传),避免竞态。

**执行流程与护栏:**

1. **三台先各自起 Orchestrator**(raft 三成员组网)。
2. **node1(primary)**:装 MySQL → `write_my_cnf`(server_id=1,`super_read_only=ON` 安全默认)→ 启动 → **临时 `SET GLOBAL super_read_only=OFF; read_only=OFF`** 以便建库/账号 → 建 `repl`/`orchestrator`/`mysqlchk`/`watcher`/应用账号 → 装/起 Orchestrator → **阻塞等待 raft quorum 就绪**(轮询本机 Orchestrator API 的 raft 健康/leader,超时 fail fast)→ `orchestrator-client -c discover -i <node1_ip>:3306`(经 raft leader)纳管拓扑 → 装/起 mysqlchk + HAProxy → **最后启用 watcher**(此时 Orchestrator 已知 node1 为主,watcher 维持其可写)。
3. **node2(replica)**:校验本机 datadir 为空(否则 reinstall)→ 装 MySQL → `write_my_cnf`(server_id=2,`super_read_only=ON`)→ 启动 → `CHANGE REPLICATION SOURCE TO ... SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1; START REPLICA`(账号经复制自动到位)→ 装/起 Orchestrator(自动发现该从库)→ 装/起 mysqlchk + HAProxy + watcher(watcher 判定本机非主 → 维持只读)。
4. **node3(arbiter)**:仅装/起 Orchestrator,加入 raft。

> 只用 IP、不依赖 DNS。**推荐顺序 arbiter→primary→replica**(arbiter+primary 即达 quorum=2);该顺序由 primary 的"raft quorum 就绪阻塞握手"在代码层兜底(对标 PG 版 `etcdctl endpoint health --cluster`),而非仅文档建议。

## 网络与前置条件 (Network & Prerequisites)

**端口分类(脚本不改防火墙,但做预检 + 文档):**

| 类别 | 端口 | 放行范围 |
|------|------|----------|
| **节点间必通** | `3306`(复制/HAProxy→MySQL/Orchestrator 监控)、`9200`(mysqlchk 跨机检查)、`3000`(Orchestrator HTTP/API)、`10008`(raft) | 三节点互通 |
| **应用接入** | `6446`(HAProxy 读写) | 应用网段 → 两台 HAProxy |
| **仅本机/运维** | `7001`(HAProxy stats) | 默认仅本机或运维网段,**不建议全网放行** |

primary 引导前对节点间端口做跨节点探测(非阻塞提示);真正就绪门禁由 raft quorum 握手 + 本机服务健康负责。文档列出放行清单。
- **时间同步**:校验 `timedatectl` NTP 同步;不同步则警告并建议 chrony(raft 选举/心跳对时钟敏感)。
- **systemd 依赖**:自写/覆盖 unit 加 `After=network-online.target`、`Wants=network-online.target`。

## 文件 / 模块布局 (File Layout)

```
install-mysql-ha.sh           # 新入口:薄加载器(沿用 install-pg-ha.sh 双模加载)
lib/mysql-ha/
├── config.sh                 # MYSQL_HA_* 默认值;自兜底 DATA_ROOT,不加载主 lib/config.sh
├── common.sh                 # 角色选择、集群 IP 收集、连通性/时间预检、密码生成、半同步开关解析
├── mysql.sh                  # 加 MySQL APT 源、装 mysql-server、write_my_cnf、建账号、配复制、AppArmor 条件处理
├── orchestrator.sh           # 装 orchestrator、write_orchestrator_config(sqlite+raft+failover+basic auth)、unit、raft 就绪握手、discover
├── mysqlchk.sh               # write_mysqlchk_script(完整 HTTP 响应)+ socket/service unit + 凭据文件
├── watcher.sh                # write_watcher_script(自愈+自我隔离)+ unit + 凭据文件
├── haproxy.sh                # write_haproxy_config(mysql_primary 后端 + mysqlchk 检查)、install/start
└── main.sh                   # mysql_ha_main:角色编排 + 最终摘要
```

**复用** `lib/common.sh`。**加载策略钉死**:`lib/mysql-ha/config.sh` 自带全部 `MYSQL_HA_*` 变量并 `DATA_ROOT="${DATA_ROOT:-/data}"` 自兜底;`install-mysql-ha.sh` **不加载** `lib/config.sh`。远程 curl 模式逐个下载 `lib/common.sh` + `lib/mysql-ha/*.sh`。

> `lib/mysql-ha/haproxy.sh` 与 `lib/pg-ha/haproxy.sh` 函数同名(`write_haproxy_config` 等)但**分属不同入口脚本、不会同时 source**(各自 `install-*-ha.sh` 与各自 `tests/test_*_ha.sh` 独立加载),无覆盖风险。

## 配置默认值 (Configuration Defaults)

全部可通过环境变量覆盖。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `MYSQL_HA_VERSION` | `8.4` | MySQL 版本(APT 组件 `mysql-8.4-lts`) |
| `MYSQL_HA_CLUSTER_NAME` | `mysql-ha` | Orchestrator 集群别名 |
| `MYSQL_HA_MYSQL_PORT` | `3306` | MySQL 端口 |
| `MYSQL_HA_PROXY_PORT` | `6446` | HAProxy 读写端口(应用连这个) |
| `MYSQL_HA_PROXY_STATS_PORT` | `7001` | HAProxy stats 端口(仅本机/运维) |
| `MYSQL_HA_MYSQLCHK_PORT` | `9200` | mysqlchk 健康检查端口(绑业务网卡) |
| `MYSQL_HA_ORCH_PORT` | `3000` | Orchestrator HTTP/API(绑业务网卡 + basic auth) |
| `MYSQL_HA_ORCH_RAFT_PORT` | `10008` | Orchestrator raft 端口 |
| `MYSQL_HA_WATCHER_INTERVAL` | `5` | watcher 轮询间隔(秒) |
| `MYSQL_HA_INSTANCE_POLL_SECONDS` | `5` | Orchestrator 探测间隔 |
| `MYSQL_HA_RECOVERY_BLOCK_SECONDS` | `3600` | 恢复后阻塞窗口(防抖动重复 recover) |
| `MYSQL_HA_PROMOTION_LAG_SECONDS` | `60` | 提升前最大允许从库落后(异步下防把落后过多的从库提成主丢数据) |
| `MYSQL_HA_BINLOG_EXPIRE_SECONDS` | `604800` | binlog 保留(7d;够容忍从库短宕回归,又不撑爆磁盘) |
| `DATA_ROOT` | `/data` | 数据根(自兜底) |
| `MYSQL_HA_DATADIR` | `${DATA_ROOT}/mysql-ha/data` | MySQL 数据目录(含 AppArmor 条件处理) |
| `MYSQL_HA_ORCH_DATADIR` | `${DATA_ROOT}/mysql-ha/orchestrator` | Orchestrator SQLite + raft 数据目录 |
| `MYSQL_HA_SEMISYNC` | `off` | 半同步开关(`on` 逼近零丢失;支付/强一致建议开) |
| `MYSQL_HA_SEMISYNC_TIMEOUT` | `1000` | 半同步等待 ack 超时(ms,超时回退异步) |
| `MYSQL_HA_APP_DB` | `appdb` | 应用数据库名 |
| `MYSQL_HA_APP_USER` | `appuser` | 应用账号 |
| `MYSQL_HA_APP_ALLOWED_CIDR` | (提示输入,无默认) | 应用账号授权网段;**不默认 0.0.0.0/0 / %** |
| `MYSQL_HA_ROOT_PASSWORD` | (提示或自动生成) | MySQL root 密码 |
| `MYSQL_HA_REPL_PASSWORD` | (提示或自动生成) | `repl` 复制用户密码 |
| `MYSQL_HA_ORCH_PASSWORD` | (提示或自动生成) | `orchestrator` topology 用户密码 |
| `MYSQL_HA_ORCH_HTTP_PASSWORD` | (自动生成) | Orchestrator Web/API basic auth 密码 |
| `MYSQL_HA_MYSQLCHK_PASSWORD` | (自动生成) | `mysqlchk`@localhost 密码 |
| `MYSQL_HA_WATCHER_PASSWORD` | (自动生成) | `watcher`@localhost 密码 |
| `MYSQL_HA_APP_PASSWORD` | (提示或自动生成) | 应用账号密码 |
| `MYSQL_HA_STATS_PASSWORD` | (自动生成) | HAProxy stats 页密码 |
| `MYSQL_HA_NODE1_IP`/`2`/`3` | (提示输入) | 三节点 IP |
| `LINUXSHELL_RAW_BASE_URL` | GitHub raw main | 远程模块基址 |

**一致性约束**:`MYSQL_HA_ROOT_PASSWORD`/`REPL`/`ORCH`/`ORCH_HTTP`/`MYSQLCHK`/`WATCHER`/`APP_PASSWORD` **必须在 node1/node2 两台保持一致**(账号行经 GTID 复制下发,本地凭据文件须与之匹配;`ORCH_HTTP` 三台一致以便互访/人工登录)。授权范围:`repl` 按 node1/node2 两台 IP(failover 角色互换);`orchestrator` 按 **node1/node2/node3 三台 IP**(仲裁节点也连 MySQL 监控);`mysqlchk`/`watcher` 限 `localhost`;应用账号限 `MYSQL_HA_APP_ALLOWED_CIDR`。

**密码生成**:复用/对齐 `lib/pg-ha/common.sh:pg_ha_generate_password` 的字符集(仅 `[A-Za-z0-9]`),**避免 `/ + =` 破坏 JSON(orchestrator.conf.json)/ SQL(`IDENTIFIED BY`)/ cnf / HAProxy `stats auth` 的转义**。

**文件路径**(测试 export 覆盖到临时目录)与**权限矩阵**:

| 变量 | 默认值 | 权限 | 说明 |
|------|--------|------|------|
| `MYSQL_HA_MYCNF` | `/etc/mysql/mysql.conf.d/zz-mysql-ha.cnf` | **644** | **不含任何密码**(账号密码经 SQL/socket 设置),644 合理 |
| `MYSQL_HA_ORCH_CONF` | `/etc/orchestrator.conf.json` | **600** | 含 topology + http 密码 |
| `MYSQL_HA_ORCH_UNIT` | `/etc/systemd/system/orchestrator.service` | 644 | |
| `MYSQL_HA_HAPROXY_CFG` | `/etc/haproxy/haproxy.cfg` | **600** | 含 stats 密码 |
| `MYSQL_HA_MYSQLCHK_SCRIPT` | `/usr/local/bin/mysqlchk` | 755 | |
| `MYSQL_HA_MYSQLCHK_SOCKET` | `/etc/systemd/system/mysqlchk.socket` | 644 | |
| `MYSQL_HA_MYSQLCHK_SERVICE` | `/etc/systemd/system/mysqlchk@.service` | 644 | |
| `MYSQL_HA_MYSQLCHK_CNF` | `/etc/mysql/mysqlchk.cnf` | **600** | owner 必须 = mysqlchk@.service 的 `User=` |
| `MYSQL_HA_WATCHER_SCRIPT` | `/usr/local/bin/mysql-ha-watcher` | 755 | |
| `MYSQL_HA_WATCHER_UNIT` | `/etc/systemd/system/mysql-ha-watcher.service` | 644 | |
| `MYSQL_HA_WATCHER_CNF` | `/etc/mysql/mysql-ha-watcher.cnf` | **600** | 含 MySQL + Orchestrator HTTP 凭据;owner = watcher 服务 `User=` |

## 各组件设计 (Component Design)

### MySQL (`lib/mysql-ha/mysql.sh`)

- **加 MySQL APT 源 + 装包**:见"版本策略"(直接写 source.list + 导入公钥 + debconf 预置)。`apt-get install -y mysql-server`。
- **`write_my_cnf`**(纯函数,接收 server_id):写 `${MYSQL_HA_MYCNF}`:`server_id`(node1=1/node2=2,**唯一**)、`bind-address`(业务网卡)、`port`、`datadir=${MYSQL_HA_DATADIR}`、`gtid_mode=ON`、`enforce_gtid_consistency=ON`、`log_bin`、`binlog_format=ROW`、`log_replica_updates=ON`、`relay_log`、`relay_log_recovery=ON`、`binlog_expire_logs_seconds=${MYSQL_HA_BINLOG_EXPIRE_SECONDS}`、**`super_read_only=ON`(两台数据节点都置 ON,boot 安全默认——重启即只读,由 watcher 收敛回可写)**、半同步块(由 `MYSQL_HA_SEMISYNC` 控制)。**不含任何密码**。
- **建账号**(仅 primary,经 socket/root;经 GTID 复制到 replica):
  - `repl`@`<node1_ip>`、`@<node2_ip>`:`REPLICATION SLAVE`
  - `orchestrator`@`<node1_ip>`、`@<node2_ip>`、`@<node3_ip>`:`PROCESS, REPLICATION SLAVE, REPLICATION CLIENT, RELOAD` + 动态 `SYSTEM_VARIABLES_ADMIN, REPLICATION_SLAVE_ADMIN` + `SELECT ON mysql.*`(8.4 用动态权限替代弃用的 SUPER;`SYSTEM_VARIABLES_ADMIN` 足以设 `read_only`/`super_read_only`)
  - `mysqlchk`@`localhost`:`REPLICATION CLIENT`(读状态)
  - `watcher`@`localhost`:`SYSTEM_VARIABLES_ADMIN, REPLICATION CLIENT`(设/读 `super_read_only`)
  - 应用账号 `MYSQL_HA_APP_USER`@`${MYSQL_HA_APP_ALLOWED_CIDR}`:`ALL ON ${MYSQL_HA_APP_DB}.*`(**不用 `%`/`0.0.0.0/0`**)
- **配复制**(replica):`CHANGE REPLICATION SOURCE TO SOURCE_HOST='<node1_ip>', SOURCE_USER='repl', SOURCE_PASSWORD='...', SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1; START REPLICA;`
- **AppArmor**:Oracle 社区包在 noble **通常不附带** AppArmor profile(与 Ubuntu 归档的 `mysql-server-8.0` 不同),故 datadir 移到 `/data` 多半畅通。条件化处理:**若存在** `/etc/apparmor.d/usr.sbin.mysqld` 才加 `/etc/apparmor.d/local/...` 规则(`${MYSQL_HA_DATADIR}/ rwk`)并 `apparmor_parser -r`,否则空跑。datadir 初始化:`chown mysql:mysql` + 适当权限 + `mysqld --initialize`(空目录)。若 `/data` 为特殊挂载点,留意 systemd `ProtectSystem` 影响(实测项)。

### 半同步复制 (`MYSQL_HA_SEMISYNC`)

- `off`(默认):纯 GTID 异步,RPO>0。
- `on`:主库 `INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so'` + `rpl_semi_sync_source_enabled=1`、`rpl_semi_sync_source_wait_for_replica_count=1`、`rpl_semi_sync_source_timeout=${MYSQL_HA_SEMISYNC_TIMEOUT}`;从库 `rpl_semi_sync_replica SONAME 'semisync_replica.so'` + `rpl_semi_sync_replica_enabled=1`。逼近零丢失;并**显著降低 failover 后旧主的 errant GTID 概率**(commit 必先达从库)。代价:从库不可达且超时后回退异步。

### Orchestrator (`lib/mysql-ha/orchestrator.sh`)

- **安装**:官方 `.deb`;失败 fallback 二进制 + 自写 unit(`After=network-online.target`、`ExecStart=.../orchestrator --config ${MYSQL_HA_ORCH_CONF} http`)。
- **`write_orchestrator_config`**(纯函数,接收本机 IP、三节点 IP):写 `${MYSQL_HA_ORCH_CONF}`(合法 JSON):
  - `ListenAddress: "<本机IP>:3000"`(**绑业务网卡,非裸 `:3000`**);**`AuthenticationMethod: "basic"` + `HTTPAuthUser` + `HTTPAuthPassword`(=`MYSQL_HA_ORCH_HTTP_PASSWORD`)**——控制面认证,对标 PG 版 Patroni REST auth(3000 能触发 failover/set-read-only,不能裸奔)
  - `MySQLTopologyUser/Password`;启用获取服务端公钥(无 TLS + caching_sha2)
  - 后端:`BackendDB: "sqlite"`、`SQLite3DataFile: "${MYSQL_HA_ORCH_DATADIR}/orchestrator.sqlite3"`
  - raft:`RaftEnabled: true`、`RaftDataDir: "${MYSQL_HA_ORCH_DATADIR}"`、`RaftBind: "<本机IP>"`、`DefaultRaftPort: 10008`、`RaftNodes: ["<ip1>","<ip2>","<ip3>"]`
  - 故障转移护栏:`RecoverMasterClusterFilters: ["*"]`、`ApplyMySQLPromotionAfterMasterFailover: true`、`FailMasterPromotionIfSQLThreadNotUpToDate: true`、`InstancePollSeconds: ${MYSQL_HA_INSTANCE_POLL_SECONDS}`、`RecoveryPeriodBlockSeconds: ${MYSQL_HA_RECOVERY_BLOCK_SECONDS}`(非零防抖动)、**落后阈值**(`ReasonableReplicationLagSeconds`/`FailMasterPromotionOnLagMinutes` 一类,对标 PG `maximum_lag_on_failover`,异步下防把落后过多的从库提成主)
  - `PostFailoverProcesses`:对**可达**旧主置 `super_read_only=1`(尽力 fencing)——见下"钩子约束"
  - 文件 `chmod 600`
- **钩子约束**:`Pre/PostFailoverProcesses` 是 Orchestrator 在本机 shell 执行的命令;凭据经 `--defaults-extra-file`/`--login-path`(**不在命令行带密码**,消解与"凭据不入命令行"的矛盾);且**所有钩子必须以 `exit 0` 收尾**(尽力而为,旧主不可达返回非零会**阻断** failover)。
- **raft quorum 就绪握手**:primary 在 `discover` 前轮询本机 Orchestrator API 的 raft 健康/leader 状态,确认多数派在线再继续,超时 fail fast 并提示"确认三台 Orchestrator 与 10008 互通"。
- **discover**:`orchestrator-client -c discover -i <node1_ip>:3306`;raft 模式下 discover/forget 等写命令需经 **raft leader**(client 默认走 leader/`--api`)。

### mysql-ha-watcher (`lib/mysql-ha/watcher.sh`) — 补足 Orchestrator 稳态 + 自我隔离

- **`write_watcher_script`**(纯函数,写 `${MYSQL_HA_WATCHER_SCRIPT}`):常驻 `Restart=always` 守护(内部 `sleep ${MYSQL_HA_WATCHER_INTERVAL}` 循环),每轮:
  1. 查**本机** Orchestrator API(`localhost:3000`,带 basic auth)的 raft 健康与"本集群当前主"。
  2. **若本机 Orchestrator raft 不健康/无 leader 可达(本机被分区)→ 自我隔离**:`SET GLOBAL super_read_only=ON`。
  3. **若 raft 健康且 Orchestrator 判定"本机(self IP:3306)= 当前主"→ 收敛为可写**:`SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF`。
  4. **若 raft 健康且当前主是别人 → 维持只读**:`SET GLOBAL super_read_only=ON`。
  - 连本机 MySQL 用 `watcher`@localhost(经 `${MYSQL_HA_WATCHER_CNF}`,不带命令行密码);**保守原则:任何不确定一律置只读**(安全优先)。
- **unit**:`mysql-ha-watcher.service`,`Restart=always`、低权限 `User=`、`After=mysql.service orchestrator.service`。
- **部署位置**:仅两台数据节点;仲裁节点不需要。
- **边界(诚实)**:watcher 是用户态近似,不是内核硬件 STONITH——分区后到 watcher 下一轮自我隔离之间有**有界双写窗口**(≤ 轮询间隔 + 检测);且 watcher 自身是 fencing 的单点(`Restart=always` + 摘要告警缓解)。半同步进一步限制分歧量。

### mysqlchk (`lib/mysql-ha/mysqlchk.sh`)

- **`write_mysqlchk_script`**(纯函数):用 `mysqlchk`@localhost(经 `${MYSQL_HA_MYSQLCHK_CNF}`)查 `SELECT @@global.read_only`。**输出完整合法 HTTP 响应,用 `printf` 输出 CRLF(不要 `echo`)**:
  - 可写主(`read_only=0`):
    ```
    HTTP/1.1 200 OK\r\n
    Content-Type: text/plain\r\n
    Connection: close\r\n
    Content-Length: <n>\r\n
    \r\n
    MySQL writable primary\r\n
    ```
  - 非可写/连接失败:`HTTP/1.1 503 Service Unavailable\r\n` + 同样的头部结构 + body。
  - 脚本**无需解析** HTTP 请求,固定输出响应即可。
- **systemd socket 激活**:`.socket`(**`ListenStream=<本机业务IP>:9200`**——绑业务网卡,既非 `127.0.0.1`(否则 HAProxy 跨机 check 不通)亦非裸 `0.0.0.0`;`Accept=yes`)+ `mysqlchk@.service`(`StandardInput=socket`/`StandardOutput=socket`、低权限 `User=`,该 `User` 须能读 600 的 `${MYSQL_HA_MYSQLCHK_CNF}`,即 cnf owner = 该 `User`)。
- 仅两台 MySQL 节点;仲裁节点不需要。
- **暴露语义**:9200 无认证,仅暴露 `read_only` 布尔(谁是主),不含密码;依赖网络隔离(与不上 TLS 同一取舍)。

### HAProxy (`lib/mysql-ha/haproxy.sh`)

- **安装**:apt `haproxy`。
- **`write_haproxy_config`**(纯函数,新 `http-check` 语法):
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
  - `inter 1s fall 2` 使"旧主转不可写"约 2s 标 DOWN;`rise 2` 使新主从 503→200 约 2s 标 UP(接入恢复 ≈ Orchestrator 检测+提升 + ~2s rise,`rise` 防 mysqlchk 抖动误判)。`on-marked-down shutdown-sessions` 旧主降级即掐连接。
  - **双 200 窗口**:提升前 Orchestrator 对**可达**旧主置 read_only=1 收窄;不可达(分区)时靠 watcher 自我隔离令旧主 mysqlchk 转 503(其本机 HAProxy 才会 DOWN)。该窗口为"脑裂/fencing"承认的有界残留。
  - `stats auth` 保护;文件 `chmod 600`。
- **部署位置**:两台 MySQL 节点各跑一个 HAProxy;应用配两个地址(`node1:6446`、`node2:6446`)+ **连接失败重试/多地址轮询**能力(文档明确)。**分区接入纪律**:分区期间应用经被分区节点的 HAProxy 写入有害——但 watcher 自我隔离会令其本机 HAProxy 转 DOWN,正常重连客户端会切到另一地址。

## 脑裂 / fencing (Split-brain / Fencing)

> Orchestrator 无内核级 STONITH,且**不维护稳态可写性**。本设计用 watcher 同时补足这两点。

- **可用性(自愈)**:任一数据节点重启回到 `super_read_only=ON`,watcher 依 Orchestrator 拓扑把"当前主"收敛回可写 → 杜绝"无可写主死锁"。
- **安全(自我隔离)**:节点失去 raft 多数视角(分区)时 watcher 主动 `super_read_only=ON`,其 mysqlchk 转 503、本机 HAProxy DOWN + 掐连接,阻断旧主继续被写。
- **提升语义澄清**:`ApplyMySQLPromotionAfterMasterFailover` 仅在**提升那一刻**置一次 `read_only=0`;**稳态可写性由 watcher 维持**(不要误以为 Orchestrator 持续保证)。
- **rejoin 旧主**:failover 后旧主回归**默认不自动 rejoin**,且异步下大概率带 **errant GTID**(本地有、新主无的事务)→ 通常需**全量重建**(见"幂等/重装";对标 PG 的 pg_rewind→reinit 自动兜底,MySQL 无等价内建,故走重建路径)。半同步可大幅降低此概率。
- **残留风险(显式接受)**:watcher 自我隔离是用户态、有界窗口(≤ 轮询间隔)、且依赖 watcher 进程存活(`Restart=always` 兜底);非内核硬 reset。强一致/支付类**建议 `MYSQL_HA_SEMISYNC=on`**。README 明确这些边界与运维建议。

## 安全设计 (Security Design)

> 姿态:**最小权限账号 + Orchestrator HTTP basic auth + 绑业务网卡 + 依赖网络隔离**,不上传输层 TLS(显式接受)。密码 `openssl rand` 自动生成(字母数字集),摘要一次性展示。

- **MySQL 账号**:repl/orchestrator 按节点 IP 授权(非 `%`);mysqlchk/watcher 限 localhost 且最小权限;应用账号限 `MYSQL_HA_APP_ALLOWED_CIDR`。
- **控制面**:Orchestrator 3000 启用 basic auth + 绑业务网卡(能触发 failover 的写 API 不可裸奔——这是相对 PG 版必须对齐的加固点)。
- **敏感暴露面**:9200(mysqlchk,无认证、仅 read_only 布尔)、3000(已加 auth)、7001(stats,默认仅本机/运维)——均依赖网络隔离;文档列明。
- **文件权限**:见上"权限矩阵"(my.cnf 644 无密码;orchestrator.conf.json/haproxy.cfg/mysqlchk.cnf/watcher.cnf 600 + owner 收紧)。
- **凭据不入命令行**:复制/监控/钩子/watcher 一律经凭据文件 / `--login-path` / `--defaults-extra-file`,`ps` 不可见明文密码。
- **复制连接**:明文(无 TLS),显式接受,依赖网络隔离;caching_sha2 经 `GET_SOURCE_PUBLIC_KEY`/获取服务端公钥握手。

## 模块加载设计 (Module Loading)

与 `install-pg-ha.sh` 一致的双模加载:本地存在 `lib/mysql-ha/config.sh` 则本地加载;否则从 `${LINUXSHELL_RAW_BASE_URL}` 下载 `lib/common.sh` + `lib/mysql-ha/*.sh` 再 source。失败带模块名与 URL 报错。所有入口/模块 `set -euo pipefail`,模块只可 source、不自调用 `mysql_ha_main`。

## 幂等 / 重装 / 错误处理 (Idempotency / Reinstall / Error Handling)

- **幂等**:对 `${MYSQL_HA_MYCNF}`、`${MYSQL_HA_ORCH_CONF}`、`${MYSQL_HA_HAPROXY_CFG}`、各 unit 复用 `confirm_overwrite` 的 `[s]kip/[o]verwrite/[u]se/[r]einstall`。
- **reinstall 拆两类**:
  - **(a) 重装 MySQL 数据层**:停 mysql → 清 `${MYSQL_HA_DATADIR}`。**replica 重装 = 清 datadir 后【全量重建】**(实现期定:`CLONE` 插件 / 重新初始化后 `CHANGE REPLICATION SOURCE`);因异步无复制槽,若 binlog 已 purge 导致 GTID 缺口,增量接续会 `ERROR 1236`,**必须全量**。**primary 重装**(清 datadir 丢账号)须**同时重置 replica 复制位点**,否则重建账号的事务会与 replica 已有 GTID 重复冲突。
  - **(b) 重置 Orchestrator**:停 orchestrator → `orchestrator-client -c forget`(经 leader)或清 `${MYSQL_HA_ORCH_DATADIR}`(SQLite/raft)。**raft 成员级重置有破坏性,单独路径 + 显著告警**。
- **replica 克隆前提校验**:本机 datadir 为空;primary 源就绪。
- **端口检查**:`assert_port_available` 本机端口;跨机连通性见前置条件。不做自动跨机回滚。

## 测试策略 (Testing Strategy)

遵循 `tests/test_pg_ha.sh` 风格——**测配置生成正确性,不真起服务**;**显式承认**自动 failover / 单主路由 / watcher 收敛 / 分区自我隔离 / 双写窗口等运行期正确性须靠手工/集成验收。

- **独立测试文件** `tests/test_mysql_ha.sh`,独立 source `lib/common.sh` + `lib/mysql-ha/*.sh`;不污染 `test_deploy.sh`/`test_pg_ha.sh`。
- **纯函数契约**:`write_my_cnf`/`write_orchestrator_config`/`write_mysqlchk_script`/`write_watcher_script`/`write_haproxy_config` 接显式参数。
- **断言点**:
  - my.cnf:`server_id` 随角色(node1=1/node2=2)、`gtid_mode=ON`、`enforce_gtid_consistency=ON`、`log_replica_updates=ON`、两节点 `super_read_only=ON`、`binlog_expire_logs_seconds`、半同步 `on`/`off` 分支;**文件权限 644**。
  - orchestrator:`BackendDB=sqlite`、`RaftEnabled=true`、`RaftNodes` 三 IP、`ListenAddress` 绑本机 IP、**`AuthenticationMethod=basic` + HTTPAuth**、`ApplyMySQLPromotionAfterMasterFailover=true`、落后阈值/`RecoveryPeriodBlockSeconds` 非零、topology user;`python3 -m json.tool` 校验 JSON 合法(无依赖则跳过);**文件 600**。
  - 复制语句含 `SOURCE_AUTO_POSITION=1` + **`GET_SOURCE_PUBLIC_KEY=1`**。
  - mysqlchk:含 `@@global.read_only`、`200`/`503` 两分支、**输出含 `\r\n` 且有空行分隔头与 body**、`printf`(非 `echo`);socket `ListenStream` 绑本机 IP:9200。
  - watcher:三分支(raft 不健康→ON / 本机是主→OFF / 别人是主→ON)、保守默认只读、连接经凭据文件。
  - haproxy:`http-check send meth GET uri /` + `expect status 200` + `on-marked-down shutdown-sessions` + 两 server 行(`check port 9200`)+ `stats auth` + `mode tcp`;**文件 600**。
  - **角色编排 mock 断言**(对标 `test_pg_ha.sh:run_orchestration_tests`):arbiter 仅装 orchestrator(不装 MySQL/HAProxy/mysqlchk/watcher);**replica 不调用建账号、不 discover**;watcher/mysqlchk 仅在数据节点。
  - 角色解析(primary/replica/arbiter 同义词)、IP 校验、环境变量覆盖、密码字符集(仅字母数字)、**密码不回显**。
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
| **无可写主死锁**(super_read_only 默认 + Orchestrator 不维护稳态可写) | **watcher 自愈收敛 + `Restart=always` + 摘要告警** |
| **分区双写**(Orchestrator 无 STONITH) | watcher 自我隔离 + 半同步 + on-marked-down + PostFailover 钩子 + 文档化有界残留 |
| mysqlchk HTTP 响应不合法致 backend 恒 DOWN | 写死完整 HTTP 字节流(CRLF/Content-Length/空行)+ `printf` + 单测断言 |
| 8.4 caching_sha2 + 无 TLS 致复制/监控握手失败 | `GET_SOURCE_PUBLIC_KEY=1` / 获取服务端公钥;不退回 native |
| PostFailover 钩子返回非零阻断 failover / 密码进 ps | 钩子尽力而为 `exit 0` + 凭据文件 |
| 账号经 GTID 复制,replica 误重复建致复制中断 | 账号仅 primary 建,replica 不建;凭据文件两台一致 |
| Orchestrator 3000 裸奔可被触发 failover | basic auth + 绑业务网卡 |
| 改 datadir 被 AppArmor 拦 | 条件处理(Oracle 社区包多半无 profile,常空跑) |
| debconf 键名漂移卡安装 | 预置 root-pass + `mysql-server/default-auth-override`;`debconf-show` 实测 |
| 异步把落后过多从库提成主丢数据 | 落后阈值护栏(对标 PG maximum_lag) |
| 从库长宕 binlog 过期 → GTID 缺口需重建 | `binlog_expire_logs_seconds` 足够长 + reinstall 全量重建路径 + 风险披露 |
| raft 未成多数即 discover 行为不定 | raft quorum 就绪阻塞握手(对标 PG etcd health) |
| 与 Docker 单机 MySQL 同机冲突 | 文档明确同机不可并跑(3306/server_id 撞);数据目录已隔离 |
| Orchestrator(openark)维护活跃度一般 | 锁定可用 release;二进制 fallback;配置最小化 |

## 文档更新 (Documentation Updates)

更新 `README.md`:新增"MySQL 高可用(Orchestrator)"小节——`install-mysql-ha.sh` 一键命令、三角色(primary/replica/arbiter)与推荐顺序(arbiter→primary→replica)、拓扑与故障域、应用连接(连 6446、读写都主库、配两台 HAProxy 地址 + 重连、分区接入纪律)、需放行端口清单(按"节点间/应用/本机"分类)、`MYSQL_HA_*` 环境变量参考、安全说明(最小权限 + Orchestrator basic auth + 不上 TLS 依赖隔离)、**watcher 作用(自愈 + 自我隔离)与有界残留风险 + 半同步开关 + 旧主回归需重建的运维步骤**、明确这是**非 Docker** 路径与菜单项 3 **并存但同机不可并跑**。数据目录表补充 `mysql-ha/`。

## 成功标准 (Success Criteria)

- 两台 MySQL + 一仲裁执行 `install-mysql-ha.sh`(各选角色)后,Orchestrator(`-c topology -alias <cluster>` 或 Web :3000 经 auth)显示一主一从、复制正常。
- 应用连 HAProxy `6446` 正常读写,流量只落主库。
- 模拟主库整机宕机后,从库自动提升、watcher 维持其可写,HAProxy `6446` 在数秒内切到新主库。
- **重启当前主 MySQL 后,watcher 在数个轮询周期内自动恢复其可写**(无"无可写主死锁")。
- **模拟主库网络分区后,旧主 watcher 自我 `super_read_only=ON`、其 mysqlchk 转 503、本机 HAProxy DOWN**。
- 仲裁宕机不影响服务与切换;两台数据节点同宕时不误切换。
- `MYSQL_HA_SEMISYNC=on` 时半同步生效(`SHOW STATUS LIKE 'Rpl_semi_sync%'`)。
- Orchestrator 3000 未认证无法调用写 API;含密码文件 600、my.cnf 644;mysqlchk 仅主库 200。
- 配置生成/JSON 合法/幂等/环境变量覆盖/server_id 分配/角色编排 mock 的单测全绿(`tests/test_mysql_ha.sh`);所有脚本 `bash -n` 通过;`test_deploy.sh`、`test_pg_ha.sh` 不受影响。
- 现有 `deploy.sh` Docker 部署行为完全不变。

## 待澄清 / 实现期需实测确认 (Open Items for Implementation)

1. **Orchestrator release 版本锁定**:选定 noble 可用的 `.deb`/二进制版本并固化;核对 raft+sqlite、basic auth 键名、落后阈值键名(`FailMasterPromotionOnLagMinutes`/`ReasonableReplicationLagSeconds`)、`orchestrator-client` 子命令与 `-alias`/`-i` 参数形态。
2. **watcher 查询 Orchestrator 的具体 API**:实测"raft 健康/leader"与"本集群当前主"的 API 路径(如 `/api/raft-health`、`/api/master/<alias>`)与返回结构。
3. **MySQL 8.4 半同步 .so 名与变量名**:实测 `semisync_source.so`/`semisync_replica.so` 与 `rpl_semi_sync_*` 在 8.4 包中的实际名。
4. **AppArmor**:实测 Oracle 社区包是否装 profile(预期"大概率不装,分支空跑");`mysqld --initialize` 与自定义 datadir 的交互。
5. **debconf 键名**:`debconf-show mysql-community-server` 实测 owner 段(`mysql-community-server` vs `mysql-server`)。
6. **CLONE vs 重新初始化** 作为 replica 全量重建手段在自定义 datadir 下的可行性。

## 审查修订记录 (Review Revisions)

三个子代理审查后整合的关键修订:

**HA 架构(最重要):** 发现"`super_read_only=ON` 双默认 + Orchestrator 不维护稳态可写 = 无可写主死锁"(Orchestrator≠Patroni,无稳态收敛循环)。据此**引入 mysql-ha-watcher**(自愈收敛 + 失多数票自我隔离),把它从初版"v1 非目标"升为**必备组件**,同时承担 PG 版的"Patroni 稳态收敛"与"watchdog 自我 fence"两个角色;澄清"提升仅置一次 read_only";补落后阈值/`RecoveryPeriodBlockSeconds`/`InstancePollSeconds` 护栏与 raft quorum 就绪阻塞握手(对标 PG);承认分区双写为有界残留;旧主 rejoin 走全量重建并在设计闭环。

**技术准确性(Ubuntu 24.04 + 8.4 实测向):** mysqlchk 必须输出完整合法 HTTP(CRLF/Content-Length/空行,`printf` 非 `echo`),否则 backend 恒 DOWN;新增"caching_sha2 + 无 TLS"处理(`GET_SOURCE_PUBLIC_KEY=1` / 获取服务端公钥);PostFailover 钩子需具体命令 + 凭据文件 + `exit 0`;debconf 键名更正 `mysql-server/default-auth-override` 并保留 root-pass 预置;AppArmor 预期重校准为"Oracle 社区包多半不装、分支空跑";`orchestrator-client` discover/forget 需经 raft leader;`SYSTEM_VARIABLES_ADMIN` 足以设 super_read_only(权限够)。

**完整性/安全:** Orchestrator 3000 启用 basic auth + 绑业务网卡(补齐相对 PG 版的控制面认证退化);mysqlchk 9200 绑业务网卡 + 暴露语义文档化;讲清"账号经 GTID 复制、replica 不重复建、凭据文件两台一致";reinstall 区分 MySQL 数据层(replica 全量重建、primary 重装需重置 replica 位点)vs Orchestrator/raft 重置;统一权限矩阵(my.cnf 644、敏感文件 600)+ 逐文件断言;端口清单按"节点间/应用/本机"分类(stats 不全网放行);"与 Docker 单机 MySQL 并存"精确化为"同机不可并跑";密码生成复用 PG 字母数字集避免 JSON/SQL/cnf 转义;测试补角色编排 mock 断言(arbiter 仅 orchestrator、replica 不建账号/不 discover)。
