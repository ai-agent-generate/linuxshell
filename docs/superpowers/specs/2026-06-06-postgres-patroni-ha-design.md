# PostgreSQL + Patroni 两主机自动 HA 部署 — 设计方案

## 概述 (Summary)

为现有 `linuxshell` 部署项目新增一条**非 Docker、跨机器**的 PostgreSQL 高可用部署路径:在两台服务器上以 Patroni 编排 PostgreSQL 主从复制,配合第三个轻量 etcd 仲裁节点,实现**真正的自动故障转移**。

该功能以独立入口脚本 `install-pg-ha.sh` 提供(类似现有的 `install-docker.sh`),复用现有 `lib/common.sh` 等公共模块,新增逻辑收敛在 `lib/pg-ha/` 子目录中。它**不改动**现有基于 Docker 的单机 PostgreSQL 部署(`deploy.sh` 菜单项 2 保持不变)。

核心设计原则与现有项目一致:**每台机器上 `curl` 执行一次**、模块化、配置可通过环境变量覆盖、测试聚焦"配置文件生成正确性"而非真起服务。

## 目标 (Goals)

- 在两台 PostgreSQL 服务器 + 一个轻量仲裁点上,一键部署可自动故障转移的 PG 集群。
- PostgreSQL **不使用 Docker**,通过 PGDG apt 源裸机安装。
- 故障转移全自动:主库宕机后,Patroni 自动将从库提升为新主库,应用通过统一入口无感知切换。
- 应用读写**全部路由到当前主库这一台**,避免异步复制延迟导致的"读己之写不一致"。
- 提供与现有项目一致的 `curl` 一键体验:

  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-pg-ha.sh)
  ```

- 复用现有公共模块(`lib/common.sh`:`require_root`/`detect_os`/`prompt_*`/`confirm_overwrite`)。
- 保留环境变量覆盖语义(数据目录、端口、版本、集群名等)。
- 测试遵循 `tests/test_deploy.sh` 传统:断言配置文件生成正确,不依赖真实多机环境。

## 非目标 (Non-Goals)

- ❌ 不做读写分离(读写都到主库;若将来有能容忍延迟的只读场景如报表,可再开只读端口,本次不做)。
- ❌ 不做自动备份 / PITR(后续可作为独立功能)。
- ❌ 不做监控告警(Prometheus / Grafana 等)。
- ❌ 不改动现有 Docker 版 PostgreSQL 部署(`deploy.sh` 菜单项 2)。
- ❌ 不支持 3 个及以上 PG 数据节点(本次聚焦两 PG + 一仲裁)。
- ❌ 不做 SSH 编排(每台机器分别运行脚本,不在控制机统一推送)。
- ❌ 不引入 VIP / keepalived(应用侧可配置多个 HAProxy 地址实现接入冗余;VIP 留待后续)。
- ❌ 不替换现有项目的 Docker 编排方式或既有约定。

## 已确定的用户决策 (User Decisions Captured)

通过头脑风暴明确的关键决策:

1. **核心目标 = 全自动故障转移 HA**(而非仅主从复制 + 手动切换)。
2. **第三仲裁点 = 有独立第三机器**:在一台独立机器上只跑一个 etcd 投票成员(不跑 PG),使 etcd 形成 3 成员、quorum=2,可容忍任意一台宕机。
3. **执行模型 = 每台分别运行**:在每台机器上各 `curl` 执行一次脚本,交互选择本机角色;不做 SSH 编排。
4. **连接路由 = HAProxy**,且**读写都路由到当前主库**(从库不承担应用流量,仅作热备 + 故障转移目标)。
5. **复制模式 = 异步复制**(性能优先;因读写都在主库,复制延迟不影响应用读取,异步唯一影响是切换瞬间可能丢失极少量未同步事务)。
6. **集成方式 = 独立入口脚本** `install-pg-ha.sh`,复用 `lib/common.sh`。
7. **DCS 技术 = 外部 etcd 三节点**(备选 Patroni 内置 Raft;选 etcd 因生态最成熟、Patroni 官方首选)。

## 架构与拓扑 (Architecture)

```
                       应用 / 客户端
                            │
                  全部连 HAProxy:5000 (读 + 写)
              ┌─────────────┴─────────────┐
              ▼                           ▼
    ┌──────────────────┐        ┌──────────────────┐        ┌──────────────────┐
    │  节点1 (node1)    │        │  节点2 (node2)    │        │  节点3 (node3)    │
    │  ──────────────  │        │  ──────────────  │        │  ──────────────  │
    │  HAProxy :5000    │        │  HAProxy :5000    │        │  (不跑 HAProxy)   │
    │  PostgreSQL :5432 │◄──────►│  PostgreSQL :5432 │        │                  │
    │   (当前主,接流量) │ 流复制  │   (从,仅热备)     │        │                  │
    │  Patroni :8008    │        │  Patroni :8008    │        │                  │
    │  etcd #1 :2379    │◄──────►│  etcd #2 :2379    │◄──────►│  etcd #3 :2379    │
    └──────────────────┘        └──────────────────┘        └──────────────────┘
                       etcd 三成员 quorum=2,容忍任意一台宕机
```

**故障域分析(关键正确性论证):**

| 故障场景 | etcd quorum | 结果 |
|----------|-------------|------|
| 仲裁节点 node3 宕机 | 2/3 在线,满足 | 两 PG 正常,仍可自动切换 |
| 从节点 node2 宕机 | 2/3 在线,满足 | 主库正常服务 |
| 主节点 node1 宕机 | 2/3 在线,满足 | Patroni 自动把 node2 提升为主,HAProxy 切流量 |
| 任意两台同时宕机 | 1/3 在线,失去 quorum | 集群只读保护(符合预期,避免脑裂) |

**HAProxy 只到主库的机制:** HAProxy backend 用 `option httpchk GET /primary` 探测 Patroni REST API —— **只有当前主库的 `/primary` 返回 200**,从库返回 503。因此 5000 端口的流量只会落到主库。故障转移后新主库的 `/primary` 开始返回 200,HAProxy 在数秒内(健康检查间隔)自动把 5000 切到新主库。应用始终只认 5000 一个地址。

## 角色模型与执行流程 (Roles & Execution Flow)

脚本在每台机器运行时,交互(或通过环境变量)选择**本机角色**:

| 角色 | 安装组件 | 说明 |
|------|----------|------|
| **A. PG 主节点 (primary)** | etcd + PostgreSQL + Patroni + HAProxy | 首次初始化新集群,成为初始 leader |
| **B. PG 从节点 (replica)** | etcd + PostgreSQL + Patroni + HAProxy | Patroni 自动从 leader 克隆(`pg_basebackup`)成为 replica |
| **C. 仅 etcd 仲裁 (quorum)** | 仅 etcd | 轻量,只参与投票 |

**集群信息收集**(所有角色都需要,因为 etcd 静态引导和 Patroni 都要知道三台地址):

- 三台的 IP / 主机名:`PG_HA_NODE1_IP`、`PG_HA_NODE2_IP`、`PG_HA_NODE3_IP`
- 本机 IP(advertise 用)与本机角色
- 集群名、各账号密码、各端口

支持两种输入方式:**交互提示**(默认)与**环境变量注入**(便于自动化/复测),与现有项目 `prompt_with_default` 行为一致。

**推荐执行顺序**(脚本在摘要中提示):

1. 在三台机器上分别运行脚本,先各自完成 **etcd** 组网(三成员 `initial-cluster-state=new` 静态引导,三台都启动后集群形成)。
2. 在 **node1(primary 角色)** 完成 Patroni 引导 —— 初始化新 PG 集群并成为 leader。
3. 在 **node2(replica 角色)** 启动 Patroni —— 自动从 leader 克隆成为 replica。
4. 在两台 PG 节点安装并启动 **HAProxy**。

> 因 etcd 与 Patroni 都有重试机制,即使各组件未严格按序就绪也会最终收敛;脚本不强制阻塞等待跨机状态,但会在每台本地校验各组件健康。

## 文件 / 模块布局 (File Layout)

遵循现有 `lib/` 模块化约定。新增逻辑量较大且含多个子组件,故收敛在 `lib/pg-ha/` 子目录(类比横切模块 `lib/docker.sh`,但因体量更大而用目录拆分)。

```
install-pg-ha.sh              # 新入口:薄加载器(类似 install-docker.sh)
lib/pg-ha/
├── config.sh                 # PG-HA 专用默认值与路径(不污染主 lib/config.sh)
├── common.sh                 # 角色选择、集群 IP 收集、跨组件校验辅助
├── etcd.sh                   # install_etcd / write_etcd_config / etcd 健康检查
├── patroni.sh                # PGDG 装 PG + Patroni、write_patroni_yaml、引导与禁用默认 cluster
├── haproxy.sh                # install_haproxy / write_haproxy_config
└── main.sh                   # pg_ha_main:角色编排 + 最终摘要
```

**复用**现有 `lib/common.sh`(`require_root`/`detect_os`/`command_exists`/`to_lower`/`print_step`/`prompt_with_default`/`prompt_yes_no`/`port_in_use`/`assert_port_available`/`confirm_overwrite`)。

`install-pg-ha.sh` 沿用现有入口的双模加载逻辑(本地 `lib/` 优先,否则从 `LINUXSHELL_RAW_BASE_URL` 远程下载),只加载它需要的模块:`lib/common.sh` + `lib/pg-ha/*.sh`。

> 注:`lib/pg-ha/config.sh` 自带 PG-HA 默认值,使 `install-pg-ha.sh` 无需加载主 `lib/config.sh`(后者面向 Docker 服务);若实现时发现复用 `lib/config.sh` 中的 `DATA_ROOT` 等更简洁,可加载它,但 PG-HA 专用变量仍放在 `lib/pg-ha/config.sh`。

## 配置默认值 (Configuration Defaults)

全部可通过环境变量覆盖(沿用现有 `${VAR:-default}` 模式)。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PG_HA_MAJOR_VERSION` | `18` | PostgreSQL 主版本(PGDG 源,与现有项目 18.x 一致) |
| `PG_HA_CLUSTER_NAME` | `pg-ha` | Patroni scope / etcd 集群 token |
| `PG_HA_PG_PORT` | `5432` | PostgreSQL 端口 |
| `PG_HA_PATRONI_REST_PORT` | `8008` | Patroni REST API 端口 |
| `PG_HA_ETCD_CLIENT_PORT` | `2379` | etcd client 端口 |
| `PG_HA_ETCD_PEER_PORT` | `2380` | etcd peer 端口 |
| `PG_HA_PROXY_PORT` | `5000` | HAProxy 读写端口(只到当前主库) |
| `PG_HA_PROXY_STATS_PORT` | `7000` | HAProxy stats 监控端口 |
| `DATA_ROOT` | `/data` | 数据根目录(复用现有约定) |
| `PG_HA_PGDATA` | `${DATA_ROOT}/patroni/pgdata` | PostgreSQL 数据目录 |
| `PG_HA_ETCD_DATA` | `${DATA_ROOT}/etcd` | etcd 数据目录 |
| `PG_HA_SUPERUSER_PASSWORD` | (提示输入) | postgres 超级用户密码 |
| `PG_HA_REPLICATION_PASSWORD` | (提示输入) | replicator 复制用户密码 |
| `PG_HA_REWIND_PASSWORD` | (提示输入) | rewind 用户密码(用于 pg_rewind) |
| `PG_HA_WATCHDOG` | `on` | 是否启用 softdog watchdog 防脑裂(可设 `off`) |
| `PG_HA_NODE1_IP` / `2` / `3` | (提示输入) | 三台节点 IP |
| `LINUXSHELL_RAW_BASE_URL` | GitHub raw main | 远程模块基址(测试可覆盖) |

固定启用项:复制槽 `use_slots: true`、`pg_rewind`(老主库快速重新入列)。

## 各组件设计 (Component Design)

### etcd (`lib/pg-ha/etcd.sh`)

- **安装**:优先尝试发行版包(`etcd-server`/`etcd-client`);若不可用或版本过旧,从 etcd 官方 release 下载 `v3.5.x` 二进制安装到 `/usr/local/bin`,并写入 systemd unit。实现计划中确定具体策略,二者择一并写明 fallback。
- **配置** `write_etcd_config`(写 `/etc/etcd/etcd.conf.yml`):
  - `name`:本机节点名(node1/node2/node3)
  - `data-dir`:`${PG_HA_ETCD_DATA}`
  - `listen-peer-urls` / `listen-client-urls`:本机 IP + 对应端口(client 同时监听 127.0.0.1 便于本地 patronictl)
  - `initial-advertise-peer-urls` / `advertise-client-urls`:本机 IP
  - `initial-cluster`:三成员静态列表 `node1=http://IP1:2380,node2=http://IP2:2380,node3=http://IP3:2380`
  - `initial-cluster-state: new`、`initial-cluster-token: ${PG_HA_CLUSTER_NAME}`
- **校验**:`etcdctl endpoint health` / `member list`。

### PostgreSQL + Patroni (`lib/pg-ha/patroni.sh`)

- **安装 PostgreSQL**:添加 PGDG apt 源(`apt.postgresql.org`),安装 `postgresql-${PG_HA_MAJOR_VERSION}` + `postgresql-client-${PG_HA_MAJOR_VERSION}`。
- **关键:禁用发行版默认 cluster** —— PGDG 安装会自动创建并启动一个默认 cluster(占用 5432)。必须 `pg_dropcluster --stop ${VER} main`(或等效)交还端口与数据目录控制权给 Patroni,且 `systemctl disable postgresql`,避免与 Patroni 抢占 PG 生命周期。
- **安装 Patroni**:apt 安装 `patroni` 及其 etcd 客户端依赖(使用 etcd v3 API,Patroni `etcd3` 配置段;实现计划确认具体依赖包,如发行版包不全则以 pip 补齐并写明)。
- **配置** `write_patroni_yaml`(写 `/etc/patroni/patroni.yml`),两 PG 节点配置仅 `name` 与 `connect_address` 不同:
  - `scope: ${PG_HA_CLUSTER_NAME}`、`name: nodeN`
  - `restapi`:`listen` 本机:8008、`connect_address` 本机 IP:8008
  - `etcd3`:`hosts` 三个 etcd client 地址
  - `bootstrap.dcs`:`ttl`/`loop_wait`/`retry_timeout`、`maximum_lag_on_failover`、`synchronous_mode: false`(异步)、`postgresql.use_slots: true`、`use_pg_rewind: true`、`parameters`(`wal_level: replica`、`hot_standby: on`、`max_wal_senders`、`max_replication_slots` 等)
  - `bootstrap.pg_hba`:允许复制用户跨节点、应用网段、本地连接
  - `bootstrap.initdb`:`encoding=UTF8`、`data-checksums`
  - `postgresql`:`listen` 本机:5432、`connect_address` 本机 IP:5432、`data_dir: ${PG_HA_PGDATA}`、`bin_dir: /usr/lib/postgresql/${VER}/bin`、`authentication`(superuser/replication/rewind 三组账号)、`parameters`
  - `watchdog`:`PG_HA_WATCHDOG=on` 时 `mode: required` + `device: /dev/watchdog`;`off` 时 `mode: off`
  - `tags`:`nofailover: false`、`noloadbalance`/`clonefrom` 视需要
- **watchdog**:启用时 `modprobe softdog` 并确保 `/dev/watchdog` 对 patroni 运行用户可用(配置 udev/权限),写入说明。
- **服务**:通过 systemd 管理 `patroni.service`(由 Patroni 包提供或脚本写入),`ExecStart` 指向 `/etc/patroni/patroni.yml`。
- **校验**:`patronictl -c /etc/patroni/patroni.yml list` 显示一个 Leader + 一个 Replica,且 replica `State=running`、`Lag` 合理。

### HAProxy (`lib/pg-ha/haproxy.sh`)

- **安装**:apt `haproxy`。
- **配置** `write_haproxy_config`(写 `/etc/haproxy/haproxy.cfg`):
  - `frontend pg_write` 监听 `${PG_HA_PROXY_PORT}` → `backend pg_primary`
  - `backend pg_primary`:`option httpchk GET /primary`、`http-check expect status 200`;两台 PG 各一行 `server nodeN <ip>:5432 check port 8008 inter 3s rise 2 fall 3`。只有 `/primary` 返回 200 的主库被标 UP,流量只到主库。
  - `listen stats` 监听 `${PG_HA_PROXY_STATS_PORT}`,启用 web stats。
- **部署位置**:两台 PG 节点各跑一个 HAProxy。应用侧可配置两个 HAProxy 地址(任一台的 5000)实现接入层冗余;任一 HAProxy 都会把流量导向当前主库。
- **校验**:HAProxy 启动后,stats 页/`socat` 查看 `pg_primary` backend 恰有一台 UP(主库)。

## 模块加载设计 (Module Loading)

与现有 `deploy.sh` / `install-docker.sh` 一致的双模加载:

1. 由 `BASH_SOURCE[0]` 求 `SCRIPT_DIR`。
2. 若 `${SCRIPT_DIR}/lib/pg-ha/config.sh` 存在 → 本地文件系统加载。
3. 否则创建临时目录,从 `${LINUXSHELL_RAW_BASE_URL}` 下载所需模块再 source。
4. 任一模块下载/source 失败,带模块名与 URL 报错并退出。

`install-pg-ha.sh` 只下载:`lib/common.sh` 与 `lib/pg-ha/*.sh`。

## 幂等 / 重装 / 错误处理 (Idempotency / Reinstall / Error Handling)

- **幂等**:对 `/etc/etcd/etcd.conf.yml`、`/etc/patroni/patroni.yml`、`/etc/haproxy/haproxy.cfg` 复用现有 `confirm_overwrite` 的 `[s]kip / [o]verwrite / [u]se existing / [r]einstall` 语义。
- **重装(reinstall)**:停服务 → 清理对应数据(`pgdata` / etcd data / 集群在 etcd 中的 key)→ 重新初始化。Patroni 集群清理用 `patronictl remove ${cluster}` + 清 `${PG_HA_PGDATA}`。
- **严格模式**:所有入口与模块 `set -euo pipefail`;模块只可 source、不自动调用 `pg_ha_main`,执行由入口拥有。
- **逐步校验**:etcd 健康、`patronictl list`、HAProxy backend 状态;失败即带明确信息退出。
- **不做**自动跨机回滚(与现有项目策略一致)。
- **端口检查**:沿用 `assert_port_available`(5432/8008/2379/2380/5000/7000)。

## 测试策略 (Testing Strategy)

测试先行,遵循 `tests/test_deploy.sh` 现有风格——**测配置文件生成正确性,不真起服务**(CI 无三机环境)。

### 生成与解析测试

- `write_etcd_config` 在临时目录产出含正确 `initial-cluster` 三成员、本机 name/IP/端口的配置。
- `write_patroni_yaml` 产出正确的 `scope`/`name`/`etcd3.hosts`/`data_dir`/`bin_dir`/异步模式/watchdog 开关/三组账号。
- `write_haproxy_config` 产出 `httpchk GET /primary` + `expect status 200` + 两台 server 行 + stats 段。
- 角色解析(primary/replica/quorum)与集群 IP 收集校验(缺 IP / 非法值的处理)。
- 幂等分支:存在配置时 `confirm_overwrite` 各返回值的处理路径。
- 环境变量覆盖:设置 `PG_HA_*` 后默认值被正确覆盖。

### 语法与冒烟

```bash
bash -n install-pg-ha.sh
find lib/pg-ha -name '*.sh' -print0 | xargs -0 -n1 bash -n
bash tests/test_deploy.sh all     # 现有测试保持绿色
```

### 兼容性

- `source install-pg-ha.sh` 后,现有 `lib/common.sh` 公共函数仍可用,不破坏现有 sourceable 表面。
- 现有 `deploy.sh` 行为与测试不受影响。

## 实现风险 (Implementation Risks)

### etcd 包可用性

部分较新 Ubuntu 版本的 etcd 发行版包缺失或过旧。需 fallback 到官方二进制安装,并在实现中明确选择,避免脚本在某些系统上静默失败。

### PGDG 默认 cluster 冲突

PGDG 安装后自动建并启动默认 cluster,占用 5432 并自启。若不 `pg_dropcluster` + `disable postgresql`,会与 Patroni 抢占端口/数据目录,导致引导失败。这是最易踩的坑,必须在 `patroni.sh` 中显式处理。

### Patroni 接管前 PG 不可自启

PG 的 systemd 服务必须禁用,生命周期完全交给 Patroni;否则重启后两者抢占。

### watchdog 环境限制

部分虚拟化/容器环境无 `/dev/watchdog`。默认用 `softdog`(`modprobe softdog`)缓解,并提供 `PG_HA_WATCHDOG=off` 开关用于无法启用的环境。

### HAProxy 接入单点

单台 HAProxy 是接入单点。本次不引入 VIP,而在两台 PG 节点各跑 HAProxy,应用侧配置两个地址实现接入冗余。文档需说明这一约束与应用侧配置方式。

### 两节点同步延迟与异步丢失

异步复制下,主库故障切换瞬间可能丢失极少量未同步事务(RPO 非零)。因读写都在主库,正常运行期间无一致性问题;切换丢失风险已在设计中明确接受。

### 远程 curl 加载子目录模块

`install-pg-ha.sh` 远程模式需逐个下载 `lib/pg-ha/*.sh`。加载器须正确构造子目录路径并对失败带 URL 报错。

## 文档更新 (Documentation Updates)

更新 `README.md`:

- 新增"PostgreSQL 高可用(Patroni)"小节:`install-pg-ha.sh` 一键命令、三角色说明、推荐执行顺序。
- 拓扑图与故障域说明。
- 应用连接方式:连 HAProxy `5000`,读写都到当前主库;接入冗余配两台 HAProxy 地址。
- 关键环境变量参考(`PG_HA_*`)。
- 明确这是**非 Docker** 路径,与现有 Docker 版 PostgreSQL(菜单项 2)并存。

## 成功标准 (Success Criteria)

- 在两台 PG + 一仲裁上执行 `install-pg-ha.sh`(各选角色)后,`patronictl list` 显示一个 Leader + 一个 running Replica。
- 应用连 HAProxy `5000` 可正常读写,且流量只落到主库。
- 主动 `patronictl switchover` 或模拟主库宕机后,从库自动提升,HAProxy `5000` 在数秒内切到新主库,应用恢复读写。
- 仲裁节点宕机不影响两 PG 正常服务与切换能力。
- 配置生成、解析、幂等、环境变量覆盖的单元测试全绿;所有脚本通过 `bash -n`;现有 `tests/test_deploy.sh` 不受影响。
- 现有 `deploy.sh` Docker 部署行为完全不变。
- 未来可通过新增 `lib/pg-ha/` 模块或开关扩展(如读写分离、备份),无需改动现有单机 Docker 逻辑。
