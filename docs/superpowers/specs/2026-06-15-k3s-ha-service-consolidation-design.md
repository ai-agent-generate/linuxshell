# k3s 高可用服务整合与不停机迁移设计

## 概述

本设计用于把当前分散在 10+ 个低负载 VPS 上的 Go Web 服务整合到一组更少、更强的服务器上，同时保留不停机迁移、未来扩容和旧服务器下线能力。

目标拓扑采用 **k3s 管 Web 服务，数据库继续裸机 HA，Longhorn 承载共享文件目录**：

- 现有 Caddy 前端服务器继续作为 v1 单一公网入口，负责域名、TLS 和反向代理。
- `control-01` 作为轻量控制与仲裁节点，运行 k3s server、数据库仲裁/控制面、轻量监控和备份编排。
- `worker-01` 与 5 天后上线的第三台对等独立机作为工作/数据节点，运行 k3s agent、Go Web pods、Longhorn 数据副本、MySQL/PostgreSQL 数据节点。
- Go Web 服务已经容器化并有镜像仓库，迁移重点不是构建镜像，而是状态外置、k3s 工作负载定义、Caddy 切流和数据层 HA。

该设计是 v1 架构与迁移规范。它不直接安装或改动生产机器；后续实施计划会把工作拆分为脚本模块、配置模板、迁移 runbook 和验证项。

## 已确认的用户决策

1. 当前有一台前端服务器，主要通过 Caddy 反向代理到后端服务。
2. Web 服务主要是 Go 应用，已经有 Docker 镜像和 registry。
3. 当前应用存在本地文件和本机会话，不是完全无状态。
4. 本地文件类型混合，暂未逐服务区分上传文件、业务生成文件、缓存和日志。
5. 文件状态优先用共享目录方案承接，不优先改对象存储。
6. 共享目录选择 Longhorn 或类似分布式存储，不采用单点 NFS 作为目标方案。
7. 会话当前依赖进程内存或 Redis；需要迁移的服务应统一改为 Redis session。
8. MySQL 和 PostgreSQL 均按“优先自动恢复服务，接受极小概率丢最后几秒写入”的策略设计。
9. 5 天后上线的第三台服务器规格预计接近 `worker-01`，作为对等工作/数据节点。
10. 前端 Caddy 入口 v1 暂时允许单点，先解决后端整合、数据库主从和工作节点故障切换。

## 已探测机器现状

### 控制机器 `control-01`

- 主机名：`control-01`
- 系统：Ubuntu 24.04.4 LTS，kernel `6.8.0-124-generic`
- 资源：1 vCPU，约 2 GiB 内存，55 GiB 磁盘
- 类型：云/虚拟服务器
- 当前运行服务：SSH、系统基础服务、watchdog 等，无 Docker/k3s/数据库运行态
- 适合角色：k3s server、数据库仲裁、轻量监控、备份编排、运维控制

### ks3 节点机器 `worker-01`

- 主机名：`reliablesite`
- 系统：Ubuntu 24.04 LTS，kernel `6.8.0-31-generic`
- 资源：AMD Ryzen 9 5950X，32 线程，约 125 GiB 内存，1.9 TiB NVMe
- 当前运行服务：SSH 和系统基础服务，无 Docker/k3s/数据库运行态
- 适合角色：k3s 工作节点、Longhorn 存储节点、Web 服务节点、MySQL/PostgreSQL 数据节点

### 网络条件

两台已探测机器双向 ICMP RTT 约 0.4 ms，丢包为 0%。这对 k3s 控制面、数据库主从复制、Longhorn 副本同步都很有利。当前限制主要是第三台对等工作节点尚未上线；在它上线前，不能承诺单个工作节点故障后业务仍完整自动迁移。

## 目标

- 将 10+ 个低负载 VPS 的 Web 服务逐步整合到 k3s 集群。
- 支持未来上线新服务器、迁移服务、drain 旧服务器、下线旧服务器的标准流程。
- 单个 Web pod 或单个工作节点故障时，业务可以由 k3s 在剩余工作节点恢复。
- MySQL 和 PostgreSQL 使用主从复制与自动故障切换，应用始终连接 HAProxy 入口。
- 本地文件目录通过 Longhorn PVC 承接，使 Web pods 可以跨节点重调度。
- Go 服务 session 统一迁移到 Redis，避免 Caddy 切流或 pod 重建导致用户随机掉登录。
- 保留现有 Caddy 前端入口作为 v1 单一入口，并利用 Caddy upstream 完成灰度切流和快速回滚。
- 对所有迁移形成可重复 runbook，而不是一次性手工搬迁。

## 非目标

- v1 不做前端 Caddy 入口高可用。入口单点是已接受风险，后续可通过 Cloudflare/DNS 容灾或双入口升级。
- v1 不把 MySQL/PostgreSQL 放入 k3s operator 或 StatefulSet。数据库继续使用裸机 HA，降低恢复复杂度并复用现有项目能力。
- v1 不默认改造应用为对象存储。文件先走共享目录/Longhorn；后续可逐服务演进到 S3 兼容存储。
- v1 不承诺两台独立工作节点同时故障后的自动恢复。该场景依赖备份恢复。
- v1 不把仍依赖本地关键状态或进程内 session 的服务纳入自动迁移池。
- v1 不做跨地域容灾。
- v1 不自动修改公网 DNS 或第三方云厂商负载均衡。

## 推荐方案

推荐采用 **方案 A：k3s + 两工作节点 + 数据库裸机 HA**。

Web 层由 k3s 负责服务编排、滚动发布、节点 drain 和跨节点重调度。数据库层继续使用现有仓库已经形成的非 Docker HA 方向：PostgreSQL 使用 Patroni + etcd + HAProxy，MySQL 使用 Replication Manager + HAProxy。共享文件目录使用 Longhorn PVC。

该方案的优点是边界清晰：

- k3s 处理无状态或已外置状态的 Web 服务。
- Longhorn 处理需要共享目录语义的文件状态。
- Redis 处理 session 状态。
- 数据库 HA 由专门的数据库控制面处理，不把数据库恢复问题混进 k3s。
- Caddy 作为灰度与回滚入口，降低一次性迁移风险。

不推荐 v1 “全部进 k3s，包括数据库”。这会引入数据库 operator、PVC 恢复、备份验证、故障切换策略等额外复杂度，不适合作为当前整合工作的第一步。

也不推荐继续只用 Docker Compose/脚本整合。短期改造少，但扩容、移机、滚动迁移和故障恢复会继续依赖人工流程，与长期目标不一致。

## 总体架构

```text
公网用户
  |
  v
现有 Caddy 前端入口
  - TLS / 域名
  - 反向代理
  - upstream 灰度切流 / 回滚
  |
  v
k3s 暴露入口
  |
  +-- control-01 控制/仲裁节点
  |     - k3s server
  |     - PostgreSQL etcd 仲裁
  |     - MySQL Replication Manager 仲裁
  |     - 轻量监控与备份编排
  |
  +-- worker-01 工作/数据节点 A
  |     - k3s agent
  |     - Go Web pods
  |     - Longhorn 数据副本
  |     - MySQL/PostgreSQL 数据节点
  |
  +-- 第三台对等独立机 工作/数据节点 B
        - k3s agent
        - Go Web pods
        - Longhorn 数据副本
        - MySQL/PostgreSQL 数据节点
```

第三台机器的 IP、主机名和磁盘路径不在设计中硬编码。上线后作为部署参数录入，并纳入 k3s 节点、Longhorn 存储节点、数据库数据节点和防火墙白名单。

## 节点职责

### 控制/仲裁节点

`control-01` 资源较小，不承载主要 Web 流量和数据库数据目录。它承担低负载但关键的控制职责：

- k3s server/API。
- PostgreSQL HA 的 etcd 第三仲裁成员。
- MySQL HA 的 Replication Manager 仲裁/监控节点。
- 备份任务调度、巡检脚本、轻量监控入口。
- 运维工具与集群状态查看。

控制节点故障时，已有 Web pod 在工作节点上继续运行。数据库自动故障切换能力会因失去第三仲裁而降级，需尽快恢复控制节点。

### 工作/数据节点

`worker-01` 与第三台对等独立机承载主要业务：

- 运行 k3s agent。
- 承载 Go Web pods。
- 作为 Longhorn storage nodes 保存共享文件卷副本。
- 分别作为 MySQL/PostgreSQL 的两个数据节点。
- 暴露 k3s 服务入口给前端 Caddy。

任意一台工作节点故障时，Web pods 应迁移到剩余工作节点；Longhorn 以降级状态继续提供卷；数据库由 HA 控制面提升可用从库。

## Web 服务部署模型

每个 Go 服务在 k3s 中至少包含以下对象：

- `Deployment`：声明镜像、环境变量、启动参数、探针、资源限制。
- `Service`：提供集群内稳定访问名。
- `Ingress` 或 k3s 入口服务：接收来自现有 Caddy 的流量。
- `Secret`：保存数据库、Redis、RabbitMQ 等连接凭据。
- `ConfigMap`：保存非敏感配置。
- `PersistentVolumeClaim`：仅在服务确实需要共享文件目录时使用 Longhorn PVC。

Deployment 必须提供：

- readiness probe，用于切流前判断实例是否可接流量。
- liveness probe，用于异常进程自愈。
- graceful shutdown 配置，使 Caddy/k3s 停止新流量后有时间处理已有连接。
- 资源 requests/limits，防止多个低负载服务整合后互相挤占。

## 状态外置设计

### Session

所有需要横向迁移、滚动发布或跨节点调度的 Go 服务，必须使用 Redis 作为 session 后端。当前仍使用进程内存 session 的服务有两种处理方式：

- 推荐：迁移前改为 Redis session，然后纳入自动迁移池。
- 临时：保持单实例部署，明确标记为不可自动迁移服务；Caddy 切流或 pod 重建时可能导致登录失效。

不允许把进程内存 session 的服务直接部署成多副本，否则用户请求落到不同 pod 时会出现随机掉登录或状态不一致。

### 文件目录

迁移前对每个服务执行目录分类：

| 类型 | 处理方式 |
|------|----------|
| 用户上传文件 | 迁入 Longhorn PVC |
| 必须保留的业务生成文件 | 迁入 Longhorn PVC |
| 可重建缓存 | 使用 `emptyDir`、节点本地临时目录或应用缓存机制 |
| 日志 | 输出到 stdout/stderr，由日志系统收集 |
| 临时文件 | 使用容器临时目录或 `emptyDir` |

只有关键文件目录挂载到 Longhorn PVC。不要把日志、缓存和临时文件放入 Longhorn，以免放大 IO 和副本同步压力。

### Longhorn

Longhorn 在两台独立工作/数据节点上保存副本，用于承接共享目录语义。两节点副本模型可以支持任意一台工作节点故障后的降级运行，但有边界：

- 单节点故障后，卷副本数下降，需要尽快恢复故障节点或加入新节点重建副本。
- 两台工作节点同时故障不能自动恢复，必须依赖外部备份。
- Longhorn 不是数据库备份替代品，也不是跨地域容灾。
- 需要配置周期性快照和外部备份目标。

## 数据库 HA 设计

### PostgreSQL

PostgreSQL 继续使用仓库现有非 Docker HA 方向：

- 两台工作/数据节点运行 PostgreSQL 18 + Patroni。
- 控制/仲裁节点运行 etcd 第三成员。
- 两台数据节点运行 HAProxy，应用连接 `:5000`。
- HAProxy 健康检查只把流量转发到当前 primary。
- 默认按自动恢复优先设计，接受极小 RPO；强一致场景可单独启用同步复制配置。

应用侧不要直接连接 `:5432` 数据库端口，应连接 HAProxy 入口，并具备连接失败重试能力。

### MySQL

MySQL 继续使用仓库现有非 Docker HA 方向：

- 两台工作/数据节点运行 MySQL 8.4 主从。
- 控制/仲裁节点运行 Replication Manager 监控/仲裁。
- 两台数据节点运行 HAProxy，应用连接 `:6446`。
- HAProxy 通过 `mysqlchk` 只放行当前可写主库。
- 默认按自动恢复优先设计，接受极小 RPO。

应用侧不要直接连接 `:3306` 数据库端口，应连接 HAProxy 入口，并具备连接失败重试能力。

### Redis 与 RabbitMQ

Redis 是 session 关键依赖。v1 需要明确 Redis 的可用性级别：

- 若 Redis 只用于 session，可以先采用主从/哨兵或单实例加备份，根据服务容忍度决定。
- 若 Redis 承载队列、限流、缓存穿透保护等关键业务状态，应按高可用组件单独设计。

RabbitMQ 是否进入 k3s 或使用独立部署，应按当前服务依赖盘点决定。若 RabbitMQ 是核心业务队列，应避免仅单实例无备份运行。

## Caddy 入口与切流

v1 保留现有 Caddy 前端服务器。它的职责：

- 继续管理公网域名和 TLS。
- 把后端 upstream 从分散 VPS 逐步切到 k3s 暴露入口。
- 支持逐服务、低权重、短窗口的灰度迁移。
- 作为第一回滚点：迁移失败时优先把 upstream 切回旧 VPS。

Caddy 配置应按服务拆分，避免一次变更影响所有域名。每个服务切流前后记录：

- 原 upstream。
- 新 k3s upstream。
- 健康检查方式。
- 回滚配置。
- 切流时间与观察窗口。

## 不停机迁移 runbook

所有服务迁移、未来扩容、服务器替换和旧节点下线都走同一套流程。

### 1. 新节点准备

- 安装 Ubuntu 24.04 基线依赖。
- 配置 SSH、防火墙、时间同步。
- 安装/加入 k3s。
- 配置 Longhorn 存储磁盘。
- 给节点打角色标签，例如 `node-role=worker-data`。
- 将节点加入数据库复制拓扑，等待复制追平。

### 2. 服务状态盘点

对每个待迁移服务记录：

- 镜像名和版本。
- 当前 VPS IP、端口和 Caddy 域名。
- 启动命令、环境变量和配置文件。
- session 后端。
- 本地文件目录及分类。
- 数据库连接目标。
- Redis/RabbitMQ 等依赖。
- 健康检查 URL。
- 回滚方式。

### 3. 状态外置改造

- 内存 session 改为 Redis session。
- 关键文件目录同步到 Longhorn PVC。
- 缓存、日志、临时目录从业务持久状态中移除。
- 数据库连接改为 HAProxy 入口。
- 敏感配置改为 k3s Secret。

### 4. k3s 预部署

- 创建 Deployment/Service/Ingress/PVC/Secret/ConfigMap。
- 设置 replicas、探针、资源限制和优雅退出。
- 服务在 k3s 内部健康后，先不接生产全量流量。

### 5. 灰度切流

- Caddy upstream 加入新 k3s 后端。
- 先低权重或只迁一个低风险域名/服务。
- 观察 5xx、延迟、登录状态、文件读写、数据库连接数和业务日志。
- 失败时立即将 Caddy upstream 切回旧 VPS。

### 6. 放量迁移

- 逐服务提升新后端流量。
- 每次只迁一个服务或一组低风险服务。
- 数据库切换和 Web 切流不放在同一窗口。
- 确认稳定后再迁下一个服务。

### 7. Drain 旧 VPS

- 从 Caddy upstream 移除旧 VPS。
- 等待连接耗尽。
- 确认旧 VPS 不再接收新请求。
- 确认旧本地文件目录不再增长。
- 停止旧服务但保留机器和数据观察窗口。

### 8. 下线旧服务器

- 创建最终快照或备份。
- 记录释放前状态。
- 观察窗口结束后释放旧 VPS。

## 故障处理边界

| 场景 | v1 行为 |
|------|---------|
| 单个 Web pod 故障 | k3s 自动重建 |
| 单个工作节点故障 | pods 调度到另一工作节点；Longhorn 降级运行 |
| PostgreSQL 主节点故障 | Patroni 提升从库，HAProxy 指向新主 |
| MySQL 主节点故障 | Replication Manager 提升从库，HAProxy 指向新主 |
| 控制/仲裁节点故障 | 已有服务继续运行；数据库自动切换能力降级，需尽快恢复 |
| 前端 Caddy 故障 | v1 单点，需人工恢复 |
| 两台工作节点同时故障 | 依赖备份恢复 |
| Longhorn 卷双副本同时不可用 | 依赖 Longhorn 备份恢复 |
| 服务仍使用本地关键状态 | 不进入自动迁移池 |
| 网络分区 | 数据库 HA 控制面尽力避免双写；旧主回归需要巡检确认 |

## 监控与告警

至少覆盖：

- 节点存活、CPU、内存、磁盘、网络。
- k3s node readiness、pod 重启次数、Deployment 可用副本数。
- Longhorn volume 状态、副本数、重建进度、备份状态。
- PostgreSQL Patroni leader、复制延迟、HAProxy 后端状态。
- MySQL 主从状态、复制延迟、HAProxy 后端状态。
- Redis 可用性、内存、连接数。
- Caddy 5xx、上游失败、证书状态。
- 备份任务成功/失败。

告警必须区分“自动恢复中”和“需要人工处理”。例如单个 pod 重启可以先记录，Longhorn 副本降级、数据库 failover、备份失败必须告警。

## 备份与恢复

主从复制和 Longhorn 副本都不是备份。v1 必须建立独立备份：

- PostgreSQL：周期性逻辑备份或物理备份，并定期做恢复演练。
- MySQL：周期性逻辑备份或物理备份，并定期做恢复演练。
- Longhorn：关键 PVC 配置快照和外部备份目标。
- Caddy：配置文件纳入版本管理或独立备份。
- k3s：关键 manifests、Secrets 的可恢复副本；Secrets 备份要加密保存。

恢复演练至少覆盖：

- 单服务从备份恢复文件目录。
- 数据库从备份恢复到测试实例。
- 新节点加入后重建 Longhorn 副本。
- Caddy upstream 配置回滚。

## 安全与网络

防火墙采用白名单原则：

- 公网只暴露现有 Caddy 入口和必要 SSH 运维入口。
- k3s API、Longhorn、数据库、HAProxy 管理端口不对公网开放。
- Caddy 到 k3s 入口只允许必要源 IP。
- 节点间放行 k3s、Longhorn、数据库 HA 和复制所需端口。
- 数据库应用端口只允许 k3s 节点或指定应用网段访问。
- 所有数据库密码、Redis 密码、RabbitMQ 密码、镜像仓库凭据进入 Secret 或 600 权限文件，不写入 README 示例真实值。

现有仓库已有防火墙模块，设计后续实施时应复用其 Docker/k3s 共存和信任 IP 能力，而不是引入 ufw/firewalld。

## 迁移准入清单

单个服务进入 k3s 生产流量前必须满足：

- 镜像版本明确且可回滚。
- readiness/liveness probe 可用。
- session 已使用 Redis，或明确标记为单实例不可自动迁移。
- 本地文件目录已分类。
- 关键文件目录已挂 Longhorn PVC。
- 日志、缓存、临时文件未放入 Longhorn。
- 数据库连接已指向 HAProxy 入口。
- 配置和密钥已迁入 ConfigMap/Secret。
- Caddy upstream 有回滚配置。
- 监控可看到服务错误率和延迟。
- 旧 VPS 保留观察窗口。

## 实施分解

后续 implementation plan 应拆成以下工作包，避免一次性大改：

1. **现状盘点工具/模板**：生成每个服务的迁移清单，记录镜像、端口、目录、session、数据库和 Caddy upstream。
2. **k3s 基础模块**：安装 k3s server/agent、节点标签、基础网络、与防火墙模块对接。
3. **Longhorn 部署与存储约定**：安装 Longhorn、配置默认 StorageClass、备份目标和 PVC 模板。
4. **Redis session 约定**：定义 Redis 部署方式、连接 Secret 和应用迁移要求。
5. **Web 服务 manifest 模板**：Deployment/Service/Ingress/PVC/Secret/ConfigMap 模板和健康检查约定。
6. **Caddy 切流 runbook**：upstream 灰度、回滚、连接耗尽和旧 VPS 下线步骤。
7. **数据库 HA 接入**：把现有 PG/MySQL HA 脚本作为目标数据层，补充与 k3s 应用连接的文档和验证。
8. **监控备份 runbook**：定义巡检命令、告警项、备份恢复演练。

## 验证策略

设计落地后的验证分三层：

### 本地脚本测试

- 新增或修改 Bash 模块时运行对应 `tests/test_*.sh`。
- k3s、防火墙、数据库入口加载顺序有变化时运行全部测试。
- 所有 shell 文件运行 `bash -n`。

### 测试环境验证

- k3s 节点 join/leave。
- Deployment 滚动发布和回滚。
- pod 故障重建。
- 工作节点 drain。
- Longhorn PVC 跨节点重新挂载。
- Redis session 跨 pod 保持登录。
- Caddy upstream 切到 k3s 后端再回滚。

### 生产迁移验证

- 每次只迁一个服务或一组低风险服务。
- 迁移前记录旧服务 QPS、错误率、延迟、登录状态和文件写入路径。
- 迁移后观察同一组指标。
- 旧 VPS 下线前确认没有新请求和本地文件写入。

## 主要风险与缓解

| 风险 | 缓解 |
|------|------|
| 服务实际仍写本地文件 | 迁移准入必须做目录盘点；切流后观察旧目录是否增长 |
| 内存 session 导致掉登录 | 统一 Redis session；未改造服务只允许单实例 |
| Longhorn 双节点副本降级 | 配置告警和外部备份；故障后优先恢复副本数 |
| Caddy 入口单点 | v1 接受；后续单独设计双入口或 Cloudflare/DNS 容灾 |
| 数据库自动 failover 后旧主回归异常 | 使用现有 HA 巡检脚本；旧主回归必须校验后再纳入流量 |
| 一次迁移过多服务难以回滚 | 按服务逐个迁移，Caddy upstream 作为第一回滚点 |
| 控制节点资源不足 | 控制节点只运行轻量组件，不承载 Web 和数据库数据 |
| 备份不可恢复 | 定期恢复演练，不只检查备份任务成功 |

## 成功标准

- 第三台对等独立机上线后，两台工作节点均能承载 Web pods 和 Longhorn 副本。
- 一个低风险 Go 服务可从旧 VPS 灰度迁移到 k3s，并可通过 Caddy upstream 快速回滚。
- 迁移后的服务在 pod 重建或单工作节点 drain 后仍能恢复。
- Redis session 生效，跨 pod 请求不导致登录状态丢失。
- 关键文件目录通过 Longhorn PVC 挂载，跨节点恢复后文件可读写。
- 应用数据库连接通过 MySQL/PostgreSQL HAProxy 入口。
- 单个数据库主节点故障时，HAProxy 最终指向新主。
- 旧 VPS 可按 runbook drain 并下线，不出现新增本地写入。
