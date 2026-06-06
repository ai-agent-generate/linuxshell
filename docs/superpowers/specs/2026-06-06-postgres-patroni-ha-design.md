# PostgreSQL + Patroni 两主机自动 HA 部署 — 设计方案

> 本版本已根据三个子代理(技术准确性 / HA 架构 / 完整性与安全)的审查结论修订。修订要点见文末"审查修订记录"。

## 概述 (Summary)

为现有 `linuxshell` 部署项目新增一条**非 Docker、跨机器**的 PostgreSQL 高可用部署路径:在两台服务器上以 Patroni 编排 PostgreSQL 主从复制,配合第三个轻量 etcd 仲裁节点,实现**真正的自动故障转移**。目标系统为 **Ubuntu 24.04 LTS (noble)**,并设计为可向更新 Ubuntu 版本兼容。

该功能以独立入口脚本 `install-pg-ha.sh` 提供(类似现有的 `install-docker.sh`),复用现有 `lib/common.sh` 公共模块,新增逻辑收敛在 `lib/pg-ha/` 子目录。它**不改动**现有基于 Docker 的单机 PostgreSQL 部署(`deploy.sh` 菜单项 2 保持不变)。

核心原则与现有项目一致:**每台机器上 `curl` 执行一次**、模块化、配置可通过环境变量覆盖、测试聚焦"配置文件生成正确性"。

## 目标 (Goals)

- 在两台 PostgreSQL 服务器 + 一个轻量仲裁点上,一键部署可自动故障转移的 PG 集群。
- PostgreSQL **不使用 Docker**,通过 PGDG apt 源裸机安装 PostgreSQL 18。
- 故障转移全自动:主库宕机后,Patroni 自动将从库提升为新主库,应用通过统一入口无感知切换。
- 应用读写**全部路由到当前主库这一台**,避免异步复制延迟导致的"读己之写不一致"。
- 控制面(etcd / Patroni REST)**启用认证**,防止 leader key 被篡改或写操作被滥用。
- 提供与现有项目一致的 `curl` 一键体验:

  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-pg-ha.sh)
  ```

- 复用现有公共模块(`lib/common.sh`)。
- 保留环境变量覆盖语义。
- 默认 Ubuntu 24.04,并对更新 Ubuntu 版本提供兼容分支。

## 非目标 (Non-Goals)

- ❌ 不做读写分离(读写都到主库;将来可加只读端口)。
- ❌ 不做自动备份 / PITR。
- ❌ 不做监控告警(Prometheus / Grafana 等)。**注意**:因此复制槽 WAL 堆积、磁盘容量需靠 `max_slot_wal_keep_size` 护栏而非告警(见组件设计)。
- ❌ 不改动现有 Docker 版 PostgreSQL 部署(`deploy.sh` 菜单项 2)。
- ❌ 不支持 3 个及以上 PG 数据节点(聚焦两 PG + 一仲裁)。
- ❌ 不做 SSH 编排(每台机器分别运行脚本)。
- ❌ 不引入 VIP / keepalived(应用侧配多个 HAProxy 地址实现接入冗余)。
- ❌ **不主动修改防火墙**(沿用现有项目传统);改为在引导前做跨节点连通性预检 + 文档列出需放行端口(见网络与前置条件)。
- ❌ **不启用 etcd/复制 TLS**(证书分发对一键脚本过重);改为 RBAC + basic auth + 绑定业务网卡 + 依赖网络隔离(见安全设计)。该取舍为**显式接受**。
- ❌ 不提供完整 teardown/卸载流程(本次仅 reinstall;teardown 列为后续)。

## 已确定的用户决策 (User Decisions Captured)

1. **核心目标 = 全自动故障转移 HA**(而非仅主从复制 + 手动切换)。
2. **第三仲裁点 = 有独立第三机器**:仅跑一个 etcd 投票成员,使 etcd 形成 3 成员、quorum=2,可容忍任意一台宕机。
3. **执行模型 = 每台分别运行**:每台 `curl` 执行一次,交互选择本机角色;不做 SSH 编排。
4. **连接路由 = HAProxy**,且**读写都路由到当前主库**(从库不承担应用流量)。
5. **复制模式 = 异步复制**(默认);另提供 `PG_HA_SYNC_MODE` 可选开关切换为同步(零丢失)以应对支付类场景。
6. **集成方式 = 独立入口脚本** `install-pg-ha.sh`。
7. **DCS = 外部 etcd 三节点**(用 etcd v3 API / Patroni `etcd3` 段)。
8. **目标系统 = Ubuntu 24.04 LTS (noble)**,兼容更新版本。
9. **控制面安全 = 启用认证**:etcd RBAC + Patroni REST basic auth + 绑业务网卡 + 不上 TLS;密码脚本自动生成。

## 目标系统与版本策略 (Target OS & Version Strategy)

- **默认 Ubuntu 24.04 LTS (noble)**,以 `detect_os` 识别;非 Ubuntu/Debian 拒绝运行(沿用现有 `detect_os`)。
- 软件来源与版本(noble 基线):
  - **PostgreSQL 18 + Patroni**:均来自 **PGDG**(`apt.postgresql.org`)。PGDG 的 patroni 与 `postgresql-18` 同源、版本协调;**锁定到已修复 etcd3 import 问题的 Patroni 4.1.x**。
  - **python3-etcd**:来自 Ubuntu universe(`apt install python3-etcd`)。**即使用 `etcd3` 段也必须安装**(Patroni etcd3 模块的已知依赖)。
  - **etcd**:优先 noble universe 的 `etcd-server`/`etcd-client`(3.4.x);若缺失/过旧则 fallback 官方二进制(v3.5.x)。
  - **HAProxy**:noble 的 `haproxy`(2.8.x)。
- **跨版本兼容**(用户要求"考虑更新版本"),用 `detect_os` 的版本号驱动:
  - **etcd ≥ 3.6 移除 v2 API** → 始终用 `etcd3` 段,绝不依赖 v2;按发行版 etcd 版本选择安装策略。
  - **PGDG suite 名随代号变**(`noble-pgdg`→`oracular-pgdg`→`plucky-pgdg`)→ 用官方 `apt.postgresql.org.sh` 脚本按 `lsb_release -cs` 自动选 suite,不手拼 suite 名。
  - **HAProxy 3.x(更新版本)** → 采用新 `http-check` 语法,一次性兼容 2.8→3.x。
  - **PEP 668 跨版本一致** → 默认 apt;pip 仅用 venv,且不硬编码 `python3.12` 路径。

## 架构与拓扑 (Architecture)

```
                       应用 / 客户端
                            │
                  全部连 HAProxy:5000 (读 + 写)
              ┌─────────────┴─────────────┐
              ▼                           ▼
    ┌──────────────────┐        ┌──────────────────┐        ┌──────────────────┐
    │  节点1 (node1)    │        │  节点2 (node2)    │        │  节点3 (node3)    │
    │  HAProxy :5000    │        │  HAProxy :5000    │        │  (不跑 HAProxy)   │
    │  PostgreSQL :5432 │◄──────►│  PostgreSQL :5432 │        │                  │
    │   (当前主,接流量) │ 流复制  │   (从,仅热备)     │        │                  │
    │  Patroni :8008    │        │  Patroni :8008    │        │                  │
    │   (REST basic auth)│        │   (REST basic auth)│       │                  │
    │  etcd #1 :2379    │◄──────►│  etcd #2 :2379    │◄──────►│  etcd #3 :2379    │
    │   (RBAC 认证)      │        │   (RBAC 认证)      │        │   (RBAC 认证)     │
    └──────────────────┘        └──────────────────┘        └──────────────────┘
                       etcd 三成员 quorum=2,容忍任意一台宕机
```

**故障域分析:**

| 故障场景 | etcd quorum | 结果 |
|----------|-------------|------|
| 仲裁节点 node3 宕机 | 2/3,满足 | 两 PG 正常,仍可自动切换 |
| 从节点 node2 宕机 | 2/3,满足 | 主库正常服务 |
| 主节点 node1 宕机(整机) | 2/3,满足 | Patroni 自动把 node2 提升为主,HAProxy 切流量 |
| 主节点 Patroni **进程失能**(非整机宕机) | 2/3,满足 | **依赖 watchdog** 物理 reset 旧主,否则有双主写入风险(见安全/HAProxy 设计) |
| 任意两台同时宕机 | 1/3,失去 quorum | 现存主库 demote 为只读(避免脑裂,符合预期) |

**HAProxy 只到主库的机制:** backend 用 Patroni REST `/primary` 健康检查 —— 只有当前主库返回 200,从库返回 503。故障转移后新主库 `/primary` 返回 200,HAProxy 在健康检查窗口内自动把 5000 切到新主库。窗口期的双主防护见"HAProxy 设计"与"安全设计"。

> Patroni REST 的只读健康检查端点(GET `/primary` 等)**默认不需要认证**;basic auth 只保护不安全方法(POST/PUT/PATCH/DELETE)。因此启用 REST auth 不影响 HAProxy 健康检查。

## 角色模型与执行流程 (Roles & Execution Flow)

每台机器运行时交互(或环境变量)选择**本机角色**:

| 角色 | 安装组件 | 说明 |
|------|----------|------|
| **A. PG 主节点 (primary)** | etcd + PostgreSQL + Patroni + HAProxy | 首次初始化新集群,成为初始 leader |
| **B. PG 从节点 (replica)** | etcd + PostgreSQL + Patroni + HAProxy | Patroni 自动从 leader 克隆(`pg_basebackup`)成为 replica |
| **C. 仅 etcd 仲裁 (quorum)** | 仅 etcd | 轻量,只参与投票 |

**集群信息收集**(所有角色都需要):三台 IP(`PG_HA_NODE1_IP`/`2`/`3`)、本机 IP 与角色、集群名、各账号密码、各端口。支持交互提示与环境变量注入两种方式。

**执行流程与护栏**(把"推荐顺序"从注释升级为代码检查):

1. **三台先各自完成 etcd 组网**(三成员 `initial-cluster-state: new` 静态引导)。
2. **node1(primary)在 Patroni 引导前**:显式执行 `etcdctl endpoint health --cluster`(带超时与重试)**阻塞等待 etcd quorum 就绪**;失败则报"etcd 集群未就绪,请确认三台 etcd 均已启动且 2379/2380 互通"并退出。然后引导新 PG 集群成为 leader。
3. **node2(replica)启动 Patroni 前校验**:① 本机 `PG_HA_PGDATA` 为空(否则纳入 reinstall 清理);② DCS 中已存在 leader。满足后 Patroni 自动 `pg_basebackup` 克隆成为 replica。
4. 在两台 PG 节点安装并启动 **HAProxy**。

> 只用 IP、不依赖 DNS(刻意决策);Patroni `name` 与 etcd `name` 用 `nodeN`,与系统 hostname 解耦。

## 网络与前置条件 (Network & Prerequisites)

- **端口连通性(脚本不改防火墙,但做预检 + 文档)**:三机互通需放行
  - `2379`/`2380`(etcd client/peer)
  - `8008`(Patroni REST;HAProxy `check port 8008` 需**跨机**访问对端)
  - `5432`(PostgreSQL,流复制 + HAProxy 到 PG)
  - `5000`/`7000`(HAProxy 读写/stats)

  primary 引导前对上述关键端口做跨节点探测(`nc`/`curl`),不通则 fail fast 给出明确指引。文档列出需放行清单(ufw/安全组)。
- **时间同步**:校验 `timedatectl` 的 `System clock synchronized: yes`(noble 默认 `systemd-timesyncd`);不同步则警告并建议装 chrony。etcd lease / Patroni TTL 对时钟偏移敏感。
- **systemd 依赖顺序**:自写的 `patroni.service` 加 `After=network-online.target etcd.service`、`Wants=network-online.target`,避免重启后 Patroni 早于 etcd 起来反复刷错。

## 文件 / 模块布局 (File Layout)

```
install-pg-ha.sh              # 新入口:薄加载器(沿用 install-docker.sh 双模加载)
lib/pg-ha/
├── config.sh                 # PG-HA 专用默认值;自兜底 DATA_ROOT,不加载主 lib/config.sh
├── common.sh                 # 角色选择、集群 IP 收集、连通性/时间/watchdog 预检、密码生成
├── etcd.sh                   # install_etcd / write_etcd_config / write_etcd_unit / etcd RBAC / 健康检查
├── patroni.sh                # PGDG 装 PG+Patroni、write_patroni_yaml、write_patroni_unit、禁用默认 cluster
├── haproxy.sh                # install_haproxy / write_haproxy_config
└── main.sh                   # pg_ha_main:角色编排 + 最终摘要(避免与现有 main 同名)
```

**复用** `lib/common.sh`。**加载策略钉死**:`lib/pg-ha/config.sh` 自带全部 `PG_HA_*` 变量并 `DATA_ROOT="${DATA_ROOT:-/data}"` 自兜底;`install-pg-ha.sh` **不加载** `lib/config.sh`(避免引入 Docker/`SELECT_*` 无关状态)。远程 curl 模式逐个下载 `lib/common.sh` + `lib/pg-ha/*.sh`(现有加载器已支持子目录路径)。

## 配置默认值 (Configuration Defaults)

全部可通过环境变量覆盖。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PG_HA_MAJOR_VERSION` | `18` | PostgreSQL 主版本(PGDG) |
| `PG_HA_CLUSTER_NAME` | `pg-ha` | Patroni scope / etcd token |
| `PG_HA_PG_PORT` | `5432` | PostgreSQL 端口 |
| `PG_HA_PATRONI_REST_PORT` | `8008` | Patroni REST API 端口 |
| `PG_HA_ETCD_CLIENT_PORT` | `2379` | etcd client 端口 |
| `PG_HA_ETCD_PEER_PORT` | `2380` | etcd peer 端口 |
| `PG_HA_PROXY_PORT` | `5000` | HAProxy 读写端口(只到主库) |
| `PG_HA_PROXY_STATS_PORT` | `7000` | HAProxy stats 端口 |
| `DATA_ROOT` | `/data` | 数据根(自兜底) |
| `PG_HA_PGDATA` | `${DATA_ROOT}/patroni/pgdata` | PostgreSQL 数据目录 |
| `PG_HA_ETCD_DATA` | `${DATA_ROOT}/etcd` | etcd 数据目录 |
| `PG_HA_TTL` | `30` | DCS leader TTL |
| `PG_HA_LOOP_WAIT` | `10` | Patroni 循环间隔 |
| `PG_HA_RETRY_TIMEOUT` | `10` | DCS 操作重试超时 |
| `PG_HA_MAX_LAG_ON_FAILOVER` | `1048576` | 故障转移最大允许落后(1MB) |
| `PG_HA_MAX_SLOT_WAL_KEEP_SIZE` | `10GB` | 复制槽 WAL 上限护栏(从库长宕保命) |
| `PG_HA_SYNC_MODE` | `off` | 同步复制开关(`on` 启用 synchronous_mode) |
| `PG_HA_SYNC_STRICT` | `off` | 同步严格模式(`on` 时不降级,从库不可用则拒写) |
| `PG_HA_WATCHDOG` | `on` | softdog watchdog(防 Patroni 失能脑裂) |
| `PG_HA_APP_ALLOWED_CIDR` | (提示输入,无默认) | 应用网段 pg_hba 授权;**不默认 0.0.0.0/0** |
| `PG_HA_SUPERUSER_PASSWORD` | (提示或自动生成) | postgres 超级用户密码 |
| `PG_HA_REPLICATION_PASSWORD` | (提示或自动生成) | replicator 复制用户密码 |
| `PG_HA_REWIND_PASSWORD` | (提示或自动生成) | rewind 用户密码 |
| `PG_HA_ETCD_PASSWORD` | (自动生成) | etcd RBAC patroni 用户密码 |
| `PG_HA_REST_PASSWORD` | (自动生成) | Patroni REST basic auth 密码 |
| `PG_HA_STATS_PASSWORD` | (自动生成) | HAProxy stats 页密码 |
| `PG_HA_NODE1_IP`/`2`/`3` | (提示输入) | 三节点 IP |
| `LINUXSHELL_RAW_BASE_URL` | GitHub raw main | 远程模块基址 |

固定启用:`use_slots: true`、`use_pg_rewind: true`、`initdb` 带 `data-checksums`(满足 pg_rewind 前提)。

**硬约束**(实现与测试必须遵守):`PG_HA_LOOP_WAIT + 2 * PG_HA_RETRY_TIMEOUT ≤ PG_HA_TTL`(默认 `10 + 2*10 = 30 ≤ 30`)。

## 各组件设计 (Component Design)

### etcd (`lib/pg-ha/etcd.sh`)

- **安装**:优先 noble `etcd-server`/`etcd-client`(3.4.x);缺失/过旧 fallback 官方二进制(v3.5.x)+ 自写 unit。
- **unit 注意**:Ubuntu `etcd-server` 包默认从 `/etc/default/etcd` 读环境变量,其 unit **不一定读 yaml**。若用 `/etc/etcd/etcd.conf.yml`,必须用 systemd drop-in 覆盖 `ExecStart=/usr/bin/etcd --config-file=/etc/etcd/etcd.conf.yml`,否则会以单机默认配置启动(静默坑)。
- **配置** `write_etcd_config`(纯函数,写 `/etc/etcd/etcd.conf.yml`):`name`、`data-dir`、`listen-peer-urls`/`listen-client-urls`(本机 IP + `127.0.0.1`)、`initial-advertise-peer-urls`/`advertise-client-urls`、`initial-cluster`(三成员)、`initial-cluster-state: new`、`initial-cluster-token`。
- **RBAC**:首台 etcd 就绪后,启用认证:创建 `root`、`patroni` 用户并授权集群所用 key 前缀,`auth enable`。Patroni `etcd3` 段配 `username/password`。健康检查用 `ETCDCTL_API=3 etcdctl ... endpoint health`(认证后带凭据)。
- **API**:始终 `etcd3`(v3/gRPC);不依赖 v2(etcd 3.4 默认关、3.6 移除)。

### PostgreSQL + Patroni (`lib/pg-ha/patroni.sh`)

- **加 PGDG 源**(免维护 keyring,跨版本稳):
  ```bash
  apt-get install -y postgresql-common
  /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
  ```
- **安装**:`apt-get install -y postgresql-${VER} postgresql-client-${VER} patroni python3-etcd`。其中 `patroni` 取自 PGDG(4.1.x,与 PG18 协调);`python3-etcd` 取自 universe(etcd3 模块依赖,**必装**)。
- **PEP 668**:默认 apt,**不裸 `pip install`**。仅当需特定 patroni 版本且无包时,用独立 venv(`python3 -m venv /opt/patroni`),unit ExecStart 指向 venv 内 patroni;不用 `--break-system-packages`。
- **禁用发行版默认 cluster**(最易踩坑):PGDG 装完会自动 `initdb` 并起 `${VER} main` 占 5432 自启 → `pg_dropcluster --stop ${VER} main` + `systemctl disable postgresql` + 确认 `pg_lsclusters` 为空,把端口/数据目录交给 Patroni(`data_dir` 用独立的 `${PG_HA_PGDATA}`)。
- **绕过包装层**:Debian/Ubuntu/PGDG 的 patroni 包用 `patroni@.service` 模板 + `pg_createconfig_patroni`,与本设计"自生成配置 + 自控生命周期"冲突。**采用自写方案**:`write_patroni_yaml` 生成 `/etc/patroni/patroni.yml`,`write_patroni_unit` 自写 `/etc/patroni/patroni.service`(`ExecStart=/usr/bin/patroni /etc/patroni/patroni.yml`、`User=postgres`、`Restart=no`、`KillMode=process`,参考 Patroni 上游 unit,而非 `patroni@.service`)。
- **`write_patroni_yaml`**(纯函数,接收本机 name/IP、三节点 IP、端口、密码等):
  - `scope`/`name`/`restapi`(`listen` 业务网卡:8008、`connect_address` 本机 IP:8008、`authentication.username/password` basic auth)
  - `etcd3`:`hosts`(三 etcd client)、`username`/`password`(RBAC)、`protocol: http`
  - `bootstrap.dcs`:`ttl`/`loop_wait`/`retry_timeout`(满足硬约束)、`maximum_lag_on_failover`、`synchronous_mode`(由 `PG_HA_SYNC_MODE`)、`synchronous_mode_strict`(由 `PG_HA_SYNC_STRICT`)、`postgresql.use_slots: true`、`use_pg_rewind: true`、`parameters`(`wal_level: replica`、`hot_standby: on`、`max_wal_senders`、`max_replication_slots`、`max_slot_wal_keep_size`、`wal_log_hints: on`)
  - `bootstrap.pg_hba`:复制用户限定三节点 IP/掩码、应用限定 `${PG_HA_APP_ALLOWED_CIDR}`、本地连接
  - `bootstrap.initdb`:`encoding=UTF8`、`data-checksums`
  - `postgresql`:`listen` 业务网卡:5432、`connect_address`、`data_dir`、`bin_dir: /usr/lib/postgresql/${VER}/bin`、`authentication`(superuser/replication/rewind 三组账号)
  - `watchdog`:`PG_HA_WATCHDOG=on` 时 `mode: required` + `device: /dev/watchdog`;`off` 时 `mode: off`
- **复制槽**:PG11+ 下 Patroni **自动维护**物理槽(故障转移后不丢、旧主回归可用),无需手工管理。`max_slot_wal_keep_size` 作为护栏:从库长宕时主库可主动失效旧槽、丢弃过旧 WAL 保命(代价是该从库需重新 basebackup)。
- **pg_rewind 回退**:旧主回归 pg_rewind 失败(WAL 缺失/timeline 分叉)时,Patroni 自动 fallback 到 reinit(全量 `pg_basebackup`);文档提示耗时与磁盘占用。
- **校验**:`patronictl -c /etc/patroni/patroni.yml list` 显示一 Leader + 一 running Replica。

### HAProxy (`lib/pg-ha/haproxy.sh`)

- **安装**:apt `haproxy`(2.8.x)。
- **配置** `write_haproxy_config`(纯函数,写 `/etc/haproxy/haproxy.cfg`),用**新 `http-check` 语法**(兼容 2.8→3.x):
  ```
  frontend pg_write
      bind *:${PROXY_PORT}
      default_backend pg_primary

  backend pg_primary
      option httpchk
      http-check send meth GET uri /primary
      http-check expect status 200
      default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions
      server node1 <ip1>:5432 check port 8008
      server node2 <ip2>:5432 check port 8008

  listen stats
      bind *:${STATS_PORT}
      stats enable
      stats uri /
      stats auth admin:${STATS_PASSWORD}
  ```
  - `inter 1s fall 2` 把"探测到旧主不可用"窗口压到约 2s(原 `3s*3=9s` 过大);`on-marked-down shutdown-sessions` 在旧主降级时立即掐断既有连接,防止继续写旧主。
  - `stats auth` 保护 stats 页(密码自动生成)。
- **部署位置**:两台 PG 节点各跑一个 HAProxy。应用侧配置**两个** HAProxy 地址,且应用需具备**连接失败重试/多地址轮询**能力(否则接入冗余名存实亡)——文档明确。

## 安全设计 (Security Design)

> 整体姿态:**RBAC + basic auth + 绑业务网卡 + 依赖网络隔离**,不上 TLS(显式接受)。密码由脚本用 `openssl rand` 自动生成,在最终摘要中一次性展示并提示妥善保存。

- **etcd**:启用 RBAC(`root` + `patroni` 用户),`auth enable`;监听绑业务网卡(+ `127.0.0.1`)。无 TLS,依赖网络隔离。
- **Patroni REST(8008)**:配 `restapi.authentication`(basic auth)保护写操作(switchover/failover/restart);`listen` 绑业务网卡。只读健康检查端点不需认证,HAProxy 正常工作。
- **配置文件权限**:`/etc/patroni/patroni.yml`、`/etc/etcd/etcd.conf.yml`、含密码的文件一律 `chmod 600` + owner 为对应运行用户(patroni→postgres)。
- **pg_hba**:复制用户限定三节点 IP;应用限定 `${PG_HA_APP_ALLOWED_CIDR}`;**不使用 `0.0.0.0/0`**。
- **复制连接**:明文(无 TLS),**显式接受**,依赖网络隔离。
- **环境变量注入**:提示密码经环境变量注入会落入 shell history/进程 environ 的风险。
- **HAProxy stats**:`stats auth` 保护。

## watchdog / 防脑裂 (Watchdog)

watchdog 是 **Patroni 进程失能**(崩溃/OOM/被杀/主机高负载/VM 被 hypervisor 暂停)时,在旧主继续写之前由内核物理 reset 主机的**唯一兜底**;DCS 锁只能覆盖"Patroni 正常"的情形。因此:

- **生产强烈建议必开**;`PG_HA_WATCHDOG=off` 时在摘要打印显著告警("已关闭防脑裂兜底,接受双主写入风险")。
- **softdog 持久化三件套**(否则重启失效):
  1. `/etc/modules-load.d/softdog.conf` 写 `softdog` + 立即 `modprobe softdog`;
  2. udev 规则 `/etc/udev/rules.d/99-watchdog.rules`:`KERNEL=="watchdog", OWNER="postgres", GROUP="postgres", MODE="0600"` + `udevadm control --reload && udevadm trigger`;
  3. 首次兜底 `chown postgres /dev/watchdog`。
- **`mode: required` 的反噬**:若 `/dev/watchdog` 不可用(很多云 VM),`required` 会让该节点**拒绝成为 leader → 集群无主**。因此安装期**实际检测** `/dev/watchdog` 是否可用:`on` 但不可用则**报错**,提示用户显式改 `PG_HA_WATCHDOG=off`,而非静默让集群起不来。
- watchdog 解决"进程失能",不解决"整机硬挂"(机器没了无意义);文档澄清边界。

## 模块加载设计 (Module Loading)

与现有 `install-docker.sh` 一致的双模加载:本地 `lib/pg-ha/config.sh` 存在则本地加载;否则从 `${LINUXSHELL_RAW_BASE_URL}` 下载 `lib/common.sh` + `lib/pg-ha/*.sh` 到临时目录再 source。任一模块失败带模块名与 URL 报错。所有入口/模块 `set -euo pipefail`,模块只可 source、不自调用 `pg_ha_main`。

## 幂等 / 重装 / 错误处理 (Idempotency / Reinstall / Error Handling)

- **幂等**:对 `/etc/etcd/etcd.conf.yml`、`/etc/patroni/patroni.yml`、`/etc/haproxy/haproxy.cfg` 复用 `confirm_overwrite` 的 `[s]kip/[o]verwrite/[u]se/[r]einstall`。
- **reinstall 拆成两类**(关键,避免破坏好集群):
  - **(a) 重装 PG/Patroni 层**:停 `patroni.service` → 清 `${PG_HA_PGDATA}` → `patronictl remove ${cluster}`(需 etcd 在线)→ 清理孤儿复制槽 → 重新引导。
  - **(b) 重建 etcd 成员**:**不能**对已存在集群用 `initial-cluster-state: new`(会破坏成员关系)。走 etcd `member remove` + `member add`(`state: existing`)流程;或全集群重置(危险,单独路径 + 显著告警)。
- **pg_rewind 失败**:Patroni 自动 reinit 兜底(见组件设计)。
- **端口检查**:`assert_port_available` 检查本机端口;跨机连通性见网络与前置条件。
- 不做自动跨机回滚。

## 测试策略 (Testing Strategy)

遵循 `tests/test_deploy.sh` 风格——**测配置生成正确性,不真起服务**;但**显式承认边界**:自动 failover / 单主路由等运行期正确性无法被配置生成测试覆盖,须靠成功标准里的手工/集成验收(可选 `--integration` 脚本,CI 不强制跑)。

- **独立测试文件**:新建 `tests/test_pg_ha.sh`,独立 `source` `lib/pg-ha/*.sh`(或 `install-pg-ha.sh`);**不污染** `tests/test_deploy.sh` 的 `load_script`(后者 source `deploy.sh` 仅为 Docker 服务)。现有测试保持绿色。
- **纯函数契约**:`write_etcd_config`/`write_patroni_yaml`/`write_haproxy_config` 设计为**接收显式参数**(本机 name/IP、三节点 IP、端口、密码……)的纯函数,与 `write_redis_compose(port,password)` 风格一致,便于在临时目录注入任意组合断言。
- **断言点**:
  - etcd:`initial-cluster` 三成员、本机 name/IP/端口、`etcd3` 相关。
  - patroni:`scope`/`name`/`etcd3.hosts`+凭据/`data_dir`/`bin_dir`、`synchronous_mode` 开关分支、watchdog `on`/`off` 分支、三组账号写入、REST auth。
  - **DCS 时序硬约束**:断言生成的 yaml 满足 `loop_wait + 2*retry_timeout ≤ ttl`。
  - haproxy:`http-check send meth GET uri /primary` + `expect status 200` + `on-marked-down shutdown-sessions` + 两 server 行 + `stats auth`。
  - 角色解析、集群 IP 收集(缺 IP/非法值处理)、幂等分支、环境变量覆盖。
  - 密码确实写入但**测试中不回显**(避免进 CI 日志)。
  - (可选)若有 `python3 -c 'import yaml'`,对生成 YAML 做 `yaml.safe_load` 解析断言(无依赖则跳过)。
- **语法冒烟**:
  ```bash
  bash -n install-pg-ha.sh
  find lib/pg-ha -name '*.sh' -print0 | xargs -0 -n1 bash -n
  bash tests/test_pg_ha.sh all
  bash tests/test_deploy.sh all      # 保持绿色
  ```

## 实现风险 (Implementation Risks)

| 风险 | 缓解 |
|------|------|
| etcd 发行版包 unit 默认读 `/etc/default/etcd` 而非 yaml | drop-in 覆盖 `ExecStart --config-file`;或二进制 fallback 自写 unit |
| noble 无 `patroni-etcd` 包、自带 `patroni@.service` 包装层 | 用 PGDG patroni + 自写 patroni.yml/patroni.service 绕过 |
| etcd3 模块即使配 etcd3 仍需 `python3-etcd` | 显式 `apt install python3-etcd`;锁 patroni 4.1.x 修复版 |
| PEP 668 拦截 pip | 默认 apt;pip 仅 venv |
| PGDG 默认 cluster 占用 5432 自启 | `pg_dropcluster` + `disable postgresql` |
| watchdog `mode: required` 在无 `/dev/watchdog` 反噬成无主 | 安装期检测,不可用则报错提示改 off |
| 故障转移窗口双主写入 | `inter 1s fall 2` + `on-marked-down shutdown-sessions` + watchdog 兜底 |
| 从库长宕复制槽撑爆主库磁盘(且不做监控) | `max_slot_wal_keep_size` 护栏 |
| etcd `new` 引导对成员级重装有破坏性 | reinstall 区分 PG 层 vs etcd 成员级 |
| 跨节点端口未通(尤其 8008)致 backend 全 DOWN | 引导前连通性预检 + 文档放行清单 |
| HAProxy 接入单点 | 两台各跑 HAProxy + 应用多地址重连 |
| 异步 RPO 非零 | 默认接受;`PG_HA_SYNC_MODE=on` 可换零丢失 |
| AppArmor 拦自定义路径 | 列为排查项(`aa-status`),一般本栈影响小 |

## 文档更新 (Documentation Updates)

更新 `README.md`:新增"PostgreSQL 高可用(Patroni)"小节 —— `install-pg-ha.sh` 一键命令、三角色与推荐执行顺序、拓扑与故障域、应用连接(连 5000、读写都主库、配两台 HAProxy 地址且需重连能力)、需放行端口清单、`PG_HA_*` 环境变量参考、安全说明(控制面认证 + 不上 TLS 依赖隔离)、watchdog 说明(默认开/无 watchdog 改 off)、明确这是**非 Docker** 路径与菜单项 2 并存。

## 成功标准 (Success Criteria)

- 在两台 PG + 一仲裁执行 `install-pg-ha.sh`(各选角色)后,`patronictl list` 显示一 Leader + 一 running Replica。
- 应用连 HAProxy `5000` 正常读写,流量只落主库。
- `patronictl switchover` 或模拟主库宕机后,从库自动提升,HAProxy `5000` 在数秒内切到新主库,应用恢复读写。
- 仲裁节点宕机不影响两 PG 服务与切换能力。
- etcd RBAC 生效(未认证客户端无法读写 key);Patroni REST 写操作需认证;配置文件 `600`。
- 配置生成/解析/幂等/环境变量覆盖/DCS 时序约束的单元测试全绿(`tests/test_pg_ha.sh`);所有脚本 `bash -n` 通过;现有 `tests/test_deploy.sh` 不受影响。
- 现有 `deploy.sh` Docker 部署行为完全不变。

## 审查修订记录 (Review Revisions)

三个子代理审查后整合的关键修订:

**技术准确性(Ubuntu 24.04 实测):** etcd 用 `etcd3` 段 + 必装 `python3-etcd`;改用 PGDG patroni(4.1.x)+ 自写 patroni.yml/service 绕过 `patroni@.service` 包装层;默认 apt 规避 PEP 668;HAProxy 新 `http-check` 语法;etcd unit `--config-file` 覆盖;PGDG 用官方 `.sh` 加源;watchdog udev 持久化。

**HA 架构:** 固化 `ttl/loop_wait/retry_timeout=30/10/10` + 硬约束 + 单测断言;watchdog 升为必备 + `required` 反噬检测;故障转移窗口防双主(`inter 1s fall 2` + `on-marked-down shutdown-sessions`);`max_slot_wal_keep_size` 护栏;`PG_HA_SYNC_MODE` 同步开关。

**完整性/安全:** 控制面启用认证(etcd RBAC + Patroni REST auth + stats auth + 文件 600);端口连通性预检 + etcd quorum 就绪握手;reinstall 拆 PG 层/etcd 成员级 + 复制槽清理 + pg_rewind 回退;`PG_HA_APP_ALLOWED_CIDR`(不默认全网);`lib/pg-ha/config.sh` 自兜底 DATA_ROOT;独立 `tests/test_pg_ha.sh`;配置生成函数纯函数化;replica 克隆前提校验;时间同步/IP-only/systemd 依赖。
