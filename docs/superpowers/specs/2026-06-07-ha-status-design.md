# HA 状态巡检脚本 (PostgreSQL HA / MySQL HA) — 设计方案

> 本版本已根据 4 个子代理(技术准确性 / 巡检逻辑正确性 / 完整性与可实现性 / 安全与只读)的审查结论修订。修订要点见文末"审查修订记录"。

## 概述 (Summary)

为现有 `linuxshell` 项目已落地的两套高可用方案(PostgreSQL 18 + Patroni + etcd + HAProxy，MySQL 8.4 + Replication Manager + HAProxy)新增**只读状态巡检脚本**。

目标读者是**刚接手、不了解历史配置的运维人员**：在任意一台 HA 节点上跑一条命令，就能看清"**本机是什么角色(主/从/仲裁)、各服务是否正常、整个集群拓扑、复制是否健康、有没有隐患**"，并以退出码表达整体健康度(可接 cron 告警)。

核心约束：**纯只读**——绝不重启服务、不切主、不改配置、不打印密码明文，可在生产环境随时安全运行。功能以独立入口脚本提供，复用现有 `load_linuxshell_modules` 加载机制与 `lib/common.sh`，新增逻辑收敛在 `lib/pg-ha/status.sh`、`lib/mysql-ha/status.sh` 与共享库 `lib/status-common.sh`。

## 目标 (Goals)

- 在任一 HA 节点上一条命令完成本机 + 全集群的状态巡检，**无需人工输入任何密码**。
- **不依赖部署时的环境变量**(`PG_HA_ROLE` / `MYSQL_HA_ROLE` 部署后并未落盘)，纯从运行时实际状态反推本机身份。
- 彩色人类可读报告 + 标准退出码(`0`=OK / `1`=WARNING / `2`=CRITICAL)，便于 cron / 告警集成。
- 覆盖核心巡检 + 关键隐患排查 + 故障取证 + **静默退化检测**(见检查项清单)。
- **故障切换瞬态不误报**：对 failover 敏感的判定采用"二次复采确认"。
- **诚实反映单机视角的局限**：跨节点不可达时如实标注巡检覆盖度，不假装看到全局。
- 提供与现有项目一致的 `curl` 一键体验与本地/远程双模运行：

  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/ha-status.sh)
  ```

- 复用现有公共模块与 `config.sh`(端口、路径、变量名单一来源)。
- 全程 `set -euo pipefail`，单项检查失败不中断整体巡检。

## 非目标 (Non-Goals)

- ❌ **不做任何写操作 / 运维动作**：不重启服务、不触发 Patroni/repman 切换、不重建从库、不改配置。运维动作由 `patronictl` / repman API 等专用工具承担。
- ❌ 不做 `--json` 机器可读输出(本期只做彩色报告 + 退出码；`status_record` 抽象为未来 JSON 预留接缝)。
- ❌ 不做 `--watch` 持续刷新模式。
- ❌ 不做 errant GTID 检测、不做故障切换历史 / 上次 failover 时间(检查框架易扩展，未来可加)。
- ❌ 不修改防火墙、不安装任何软件(沿用现有项目传统；缺命令时优雅降级提示)。
- ❌ 不改动现有 `install-pg-ha.sh` / `install-mysql-ha.sh` / `deploy.sh` 的部署行为。

## 已确定的用户决策 (User Decisions Captured)

1. **职责边界 = 纯只读巡检**：只读取、展示、诊断、给健康结论，绝不改动系统。
2. **输出形态 = 彩色终端报告 + 退出码**(0/1/2)：不做 JSON / watch。
3. **功能范围**：核心(身份/服务/拓扑/复制/结论) + 隐患排查(入口一致性/防脑裂/磁盘/时钟) + 故障取证(日志摘要/配置连通性自检/连接负载) + **静默退化检测**(审查新增)。不含 errant GTID / 切换历史。
4. **入口方式 = 两独立入口 + 总入口**：`status-pg-ha.sh`、`status-mysql-ha.sh` + `ha-status.sh`(自动探测并转发)。
5. **身份与凭据策略**：本机角色从运行状态自动发现；查询所需密码从 root 可读的落盘配置文件(600)自动提取，全程不回显明文、不进命令行。
6. **故障切换瞬态 = 二次复采确认**：对 failover 敏感判定(入口一致性/无主/多主)检测到异常时，间隔 `STATUS_RECHECK_DELAY`(默认 3s)重采一次，两次都异常才判 CRIT，否则降 WARN 并标注"疑似切换中"。

## 文件布局 (File Layout)

```
status-pg-ha.sh          # 根入口：PG HA 巡检(对称 install-pg-ha.sh，须 chmod +x)
status-mysql-ha.sh       # 根入口：MySQL HA 巡检(对称 install-mysql-ha.sh，须 chmod +x)
ha-status.sh             # 根入口：总入口，自动探测并在本进程内加载对应逻辑(须 chmod +x)
lib/status-common.sh     # 共享：着色 / 检查框架 / 瞬态复采 / 退出码 / 表格 / 配置取值 / 探测 / 凭据安全传参
lib/pg-ha/status.sh      # PG 巡检逻辑(pg_ha_status_main)
lib/mysql-ha/status.sh   # MySQL 巡检逻辑(mysql_ha_status_main)
```

**模块加载**(复用现有 `load_linuxshell_modules`，本地优先、缺失则从 `LINUXSHELL_RAW_BASE_URL` 下载)。三个入口的 `load_linuxshell_modules` 参数清单(即远程下载列表)逐行写定：

- `status-pg-ha.sh`：`lib/common.sh` `lib/status-common.sh` `lib/pg-ha/config.sh` `lib/pg-ha/common.sh` `lib/pg-ha/status.sh` → 调 `pg_ha_status_main "$@"`。
- `status-mysql-ha.sh`：`lib/common.sh` `lib/status-common.sh` `lib/mysql-ha/config.sh` `lib/mysql-ha/common.sh` `lib/mysql-ha/status.sh` → 调 `mysql_ha_status_main "$@"`。
- `ha-status.sh`：先加载 `lib/common.sh` `lib/status-common.sh` `lib/pg-ha/config.sh` `lib/mysql-ha/config.sh`(后两者为纯赋值，安全 source，供探测读路径变量) → 调探测函数 → 据结果**再次** `load_linuxshell_modules` 追加对应那套 `common.sh`+`status.sh` → 调对应 `*_status_main`。**允许在 `ha-status.sh` 内多次调用 `load_linuxshell_modules`**(每次独立下载/ source，无重复加载冲突)。

**依赖声明**：`status-common.sh` 依赖 `common.sh`(复用 `print_step`/`command_exists`/`port_in_use`/`to_lower`)；`*/status.sh` 依赖 `config.sh`+`common.sh`+`status-common.sh`+对应 `*/common.sh`。

> 复用现有 `config.sh` 是关键：端口、文件路径、集群名、节点 IP 变量、默认值都从那里来，巡检不重复定义、不与部署逻辑漂移。

## 核心机制一：检查框架 (status-common.sh)

提供一套轻量"检查项"原语，让两套巡检逻辑只描述"检查什么"，复用着色/累计/退出码/瞬态复采。

- `status_reset`：重置 `STATUS_WARN_COUNT=0`、`STATUS_CRIT_COUNT=0`、问题清单、覆盖度计数。
- `status_section "<标题>"`：分区标题。
- `status_record <OK|WARN|CRIT|INFO> "<标题>" "<详情>"`：记录并即时着色打印一行；WARN/CRIT 计入计数器与"发现的问题"清单。**这是采集与渲染的接缝**——检查函数只调它、不自行 `echo` 彩色串，未来加 `--json` 只需替换其后端。
- 便捷封装：`status_ok` / `status_warn` / `status_crit` / `status_info`。
- `status_kv` / `status_table_row`：对齐输出(身份区/拓扑表)。
- `status_recheck <采集闭包>`：**瞬态二次复采原语**——首次判定为 failover 敏感异常时，`sleep ${STATUS_RECHECK_DELAY}` 后重跑闭包；两次都异常 → CRIT；好转 → WARN("疑似切换中，复采已恢复")。
- `status_cover_seen` / `status_cover_unreachable`：累计跨节点探测"已覆盖/不可达"节点数，供覆盖度小节使用。
- `status_summary` / `status_final_code`：打印总结(整体级别、WARN/CRIT 数、覆盖度、问题清单)；退出码 = `CRIT>0?2 : WARN>0?1 : 0`。

**着色规则**：`status-common.sh` 顶部一次性判定 `[[ -t 1 && -z "${NO_COLOR:-}" ]]` 设 `STATUS_COLOR`；非 tty / 设了 `NO_COLOR` → 纯文本(便于重定向/cron)。`set -u` 下一律 `${NO_COLOR:-}` 写法。

**阈值(默认值集中在 `status-common.sh` 顶部以 `${VAR:-default}` 注入，可被环境变量覆盖)**：

| 变量 | 默认 | 含义 |
|------|------|------|
| `STATUS_RECHECK_DELAY` | 3 | 瞬态二次复采间隔(秒) |
| `STATUS_DISK_WARN_PCT` / `STATUS_DISK_CRIT_PCT` | 80 / 90 | 数据目录分区使用率 |
| `STATUS_PG_LAG_CRIT_MB` | 512 | PG 复制延迟"大延迟"CRIT 线 |
| `STATUS_MYSQL_LAG_WARN_SEC` / `STATUS_MYSQL_LAG_CRIT_SEC` | 30 / 300 | MySQL `Seconds_Behind_Source`(仅 IO/SQL 线程均 Yes 时参与判定) |
| `STATUS_CONN_WARN_PCT` / `STATUS_CONN_CRIT_PCT` | 80 / 95 | 连接数占 max_connections 比例 |
| `STATUS_LOG_LINES` | 20 | 日志摘要抓取行数 |

> PG 复制延迟的 **WARN 线不取固定值**，而是与部署的 `PG_HA_MAX_LAG_ON_FAILOVER`(默认 1MB，`config.sh`)挂钩：从库滞后 > 该值 → WARN("超过 failover 候选阈值，主库故障时该从库不会被选为新主")；滞后 > `STATUS_PG_LAG_CRIT_MB` → CRIT。这样"巡检健康"与"HA 可切换"一致。

**配置取值与凭据安全(`status-common.sh`)**：

- `status_extract_kv <file> <pattern>`：用 `sed -n 's/.../\1/p'` **只取捕获组的值**，绝不 `grep` 整行、绝不回显值(防止密码进输出)。
- 凭据安全传参约定(见"健壮性与只读保证·凭据处理纪律")：HTTP 凭据走 `curl -K <tmpfile>` / `--netrc-file`，etcd 凭据走 `ETCDCTL_USER`/`ETCDCTL_PASSWORD` 环境变量，MySQL 走 `--defaults-extra-file`。临时文件 `umask 077 + mktemp + trap rm EXIT`。
- `status_redact`：对要展示的日志行/配置佐证做脱敏(过滤 `password=`/`:pass@`/`-p<...>`/`auth .*:` 等模式)。

## 核心机制二：本机角色自动发现

不读部署期环境变量，按"装了什么 + 运行态"判定，结果存入运行期变量(如 `PG_HA_DETECTED_ROLE`)仅供本次报告。

**PostgreSQL**：

1. 存在 `${PG_HA_PATRONI_YAML}` 且有 `patroni.service` → **PG 数据节点**；再 `sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'`(走 patroni.yml 的 `local all all trust`，免密、且该 OS 用户即 PG superuser，内部视图全可读) → `f`=**primary** / `t`=**replica**。兜底解析 `patronictl list` 本机行 Role。
2. 无 patroni.yml、仅有 etcd(`etcd.conf.yml`+`etcd.service`) → **etcd-quorum 节点**。
3. 节点编号：本机 IP(`hostname -I` 集合) ∩ `PG_HA_NODE1/2/3_IP`，并据此得出**本机对外 IP**(供后述对外 IP 端点访问)。集群名取 `PG_HA_CLUSTER_NAME` 或 patroni.yml `scope:`。

**MySQL**：

1. 存在 `mysqld` 服务 + `${MYSQL_HA_MYCNF}` → **MySQL 数据节点**；再 `mysql --defaults-extra-file=${MYSQL_HA_MYSQLCHK_CNF} -N -B -e 'SELECT @@global.read_only'`(读系统变量无需特权，角色判断必成) → `0`=**primary** / `1`=**replica**。兜底 `@@server_id`。
2. 存在 `${MYSQL_HA_REPMAN_CONF}` + `replication-manager.service` 且**无** mysqld → **arbiter 仲裁节点**。
3. 节点编号同 PG。

**已查实的账号权限结论**(代码出处见"实现核实"，可直接据此实现)：

- `mysqlchk` 账号有 `REPLICATION CLIENT`(`mysql.sh:168`)，`SHOW REPLICA STATUS`、`SHOW STATUS LIKE 'Rpl_semi_sync%'` **可用**；但**无 `PROCESS`**，`SHOW PROCESSLIST` 只能看到自身连接 → 连接数/长查询统计需用 root 凭据或**降级为 INFO 并说明**。
- `mysqlchk.cnf` 是 `[client]`+`socket=`，**仅本机可用**；远程节点状态只能经 mysqlchk HTTP 端点(见下)。
- Patroni `GET /primary`、`/health`、`/cluster` 健康端点**免认证**(HAProxy 即以免认证方式探 `/primary`)；`restapi.authentication` 只保护写方法。
- etcd 启用了 RBAC，集群级 `member list` 需 `root:${PG_HA_ETCD_PASSWORD}`；免认证的 `GET /health` 可用作主判据。

## 核心机制三：端点绑定与数据源 (Endpoints & Data Sources)

**端点绑定 vs 访问地址(实现时反复用到，写错地址会全盘误报)**：

| 端点 | 绑定 | 本机访问地址 | 跨节点访问 |
|------|------|-------------|-----------|
| etcd 2379 | 对外 IP **+ 127.0.0.1** | `127.0.0.1:2379` | 各节点对外 IP(需放行) |
| HAProxy stats 7000/7001 | `*` | `127.0.0.1:7000/7001` | 仅本机用 |
| Patroni REST 8008 | **仅对外 IP** | **本机对外 IP**(非 127.0.0.1) | 各节点对外 IP(需放行) |
| mysqlchk 9200 | **仅对外 IP** | **本机对外 IP**(非 127.0.0.1) | 各节点对外 IP(需放行) |
| repman API 10005 | `0.0.0.0` | arbiter 本机 | data 节点远程探 arbiter |

**数据源汇总**(均为只读；凭据传参遵守凭据纪律)：

| 维度 | PG HA | MySQL HA |
|------|-------|----------|
| 服务态 | `systemctl is-active/is-enabled/show -p`：`etcd`/`patroni`/`haproxy` | `mysql`/`haproxy`/`mysqlchk.socket`(data)；`replication-manager`(arbiter) |
| 端口监听 | `port_in_use`(本机)，**按角色裁剪**：数据节点 5432/8008/2379/2380/5000/7000；quorum 仅 2379/2380 | 数据节点 3306/6446/7001/9200；arbiter 仅 10005(+10001) |
| 本机角色 | `sudo -u postgres psql`(local trust=superuser) | `mysql --defaults-extra-file=mysqlchk.cnf`(socket) |
| 集群拓扑 | 数据节点 `patronictl -c ... list`；**quorum 节点改用 `etcdctl get --prefix /service/<cluster>/`**(需 root 凭据，无则降级仅展示 etcd 健康) | repman API(凭据取自 config.toml，**必带 user**；**不复用** `mysql_ha_repman_api_url` 的硬编码 http://) |
| 主判定(事实来源) | etcd 中的 **leader key**(即 `patronictl list` 的 Leader 列所读)；各节点 `GET http://<对外IP>:8008/primary`(200/503) 为辅助 | repman 拓扑的 **master**；各节点 `GET http://<对外IP>:9200`(200=可写主/503=只读) 为辅助 |
| 复制 | `pg_stat_replication`/`pg_replication_slots`(主)；`pg_is_in_recovery`/`pg_last_wal_replay_lsn`(从) | `SHOW REPLICA STATUS`/`Rpl_semi_sync_*`(本机，mysqlchk 账号够权) |
| HAProxy 后端 | `curl -K <tmp> 'http://127.0.0.1:7000/;csv'` | `http://127.0.0.1:7001/;csv` |
| etcd 健康/quorum | 主判据 `curl http://127.0.0.1:2379/health`；增强 `etcdctl member list`(`ETCDCTL_USER=root`/`ETCDCTL_PASSWORD=${PG_HA_ETCD_PASSWORD}`，失败降级) | — |
| 磁盘 | `df -P ${PG_HA_PGDATA}` / `${PG_HA_ETCD_DATA}` | `df -P ${MYSQL_HA_DATADIR}` |
| 时钟 | `timedatectl show -p NTPSynchronized` | 同左 |
| 日志 | `journalctl -u <svc> -n ${STATUS_LOG_LINES} -p warning`(输出前 `status_redact` 脱敏) | 同左(含 `mysqlchk@*`) |
| 配置自检 | 文件存在 + `stat` 模式位**与属主**校验 + `pg_ha_check_connectivity` 跨节点端口探测 | 同左(`mysql_ha_check_connectivity`；mysqlchk.cnf 属主应 mysql、config.toml 应 root) |

## 检查项清单：PostgreSQL HA (status-pg-ha.sh)

1. **身份**：角色、hostname、本机对外 IP、node 编号、集群名、PG 大版本。
2. **服务健康**：`etcd`/`patroni`/`haproxy` active(CRIT if failed)/enabled(WARN if 未自启)/运行时长；端口监听**按角色裁剪**(quorum 仅 2379/2380，不因缺 8008/5432 误报)。
3. **集群拓扑**：数据节点 `patronictl list` 全表高亮本机；quorum 节点用 etcd 数据通路。当前 Leader(无 Leader → **二次复采**，仍无 → CRIT；复采恢复 → WARN"疑似选举中")。
4. **复制健康**：从库滞后与 `PG_HA_MAX_LAG_ON_FAILOVER` 挂钩判级、`state`=streaming?、同步/异步模式、复制中断(CRIT)。
5. **静默退化(PG)**：① 主库 `pg_replication_slots.active=false` → WARN，接近 `max_slot_wal_keep_size` → CRIT(WAL 堆积撑爆磁盘)；② Patroni **paused/maintenance** → WARN("自动故障切换已禁用")；③ 各节点 timeline(TL) 不一致 → WARN。
6. **入口一致性**：HAProxy `pg_primary` 各 server UP/DOWN；以 **etcd Leader(事实来源)** 为准，校验 HAProxy 是否把流量指向它。不一致/两后端都 UP/都 DOWN → **二次复采**，仍异常才 CRIT(两后端都 UP=路由错乱；都 DOWN=当前无写入口)，复采恢复 → WARN"疑似切换中"。
7. **防脑裂**：以 etcd Leader key 为单一事实来源(DCS 天然防双主)；etcd 健康成员=2(3 节点)→ WARN(零容错)，< quorum → CRIT。多主为**尽力而为**：统计可达节点中 `GET /primary`=200 的数量，**对端不可达单列第三态、不计入主数**；明确声明"单机视角在网络分区下无法看到对侧"。
8. **磁盘**：`PGDATA`/`etcd data` 分区使用率 vs 阈值；**与复制槽联动**(存在 inactive 槽且使用率 > WARN → 升 CRIT)。
9. **时钟同步**：NTP 未同步 → WARN。
10. **关键日志摘要**：`etcd`/`patroni`/`haproxy` 最近告警日志(脱敏后)，高亮 error/fatal/failover。
11. **配置/连通性自检**：`patroni.yml`/`haproxy.cfg`/`etcd.conf.yml` 存在 + 权限(模式位+属主，非预期 → WARN)；节点间 2379/8008/5432 可达性(复用 `pg_ha_check_connectivity`)。
12. **连接数/负载**：`pg_stat_activity` 连接数 vs `max_connections`(PG superuser 可读，完整)；最长事务时长。
13. **结论**：整体级别 + 计数 + **覆盖度** + 问题清单 + 退出码。

## 检查项清单：MySQL HA (status-mysql-ha.sh)

1. **身份**：角色(primary/replica/arbiter)、hostname、本机对外 IP、node 编号、集群名、server_id、版本。
2. **服务健康**：data 节点 `mysql`/`haproxy`/`mysqlchk.socket`；arbiter `replication-manager`；active/enabled/运行时长 + 端口监听**按角色裁剪**(data 节点不查本机 repman 服务，改探 arbiter 10005 可达性)。
3. **集群拓扑**：repman API(master/slaves/各节点 state)高亮本机；无 master → **二次复采**，仍无 → CRIT。API 不可达 → WARN(附"repman 未运行/端口未放行")，非 CRIT。
4. **复制健康**：**判定顺序固定**——先 `Replica_IO_Running`/`Replica_SQL_Running`(任一非 Yes → CRIT) → `Last_Error` → 再看 `Seconds_Behind_Source`(仅两线程均 Yes 时参与阈值判定，否则只展示不判级，避免 IO 断时 NULL 被当 0)。
5. **静默退化(MySQL)**：① 配了 `MYSQL_HA_SEMISYNC=on` 时主库 `Rpl_semi_sync_source_status=OFF` 或 `Rpl_semi_sync_source_clients=0` → WARN("半同步已退化为异步，RPO>0")；② `Replica_IO_Running=No` 但 `Replica_SQL_Running=Yes` → CRIT(复制实际已断)；③ 僵尸主/不可写主：从库 `read_only=0` → CRIT；被 repman 认定为 master 却 `super_read_only=ON` → CRIT(无可写主)。
6. **入口一致性**：HAProxy `mysql_primary` UP/DOWN + mysqlchk `GET :9200`；以 **repman master(事实来源)** 为准校验。不一致/两后端异常 → **二次复采**，仍异常才 CRIT，复采恢复 → WARN"疑似切换中"。
7. **防脑裂**：以 repman 拓扑为事实来源；统计可达数据节点中 `read_only=0` 的数量，**对端不可达单列第三态**；"本机 `read_only=0` 但 repman 认为非 master"=僵尸主 → CRIT。arbiter 上 `replication-manager` 未运行 → CRIT。**声明单机盲区**。
8. **磁盘**：`datadir`/repman datadir 分区使用率 vs 阈值；binlog 占用。
9. **时钟同步**：NTP 未同步 → WARN。
10. **关键日志摘要**：`mysql`/`haproxy`/`mysqlchk@*`/`replication-manager` 最近日志(脱敏)，高亮 error/failover。
11. **配置/连通性自检**：`zz-mysql-ha.cnf`/`config.toml`/`mysqlchk.cnf`/`haproxy.cfg` 存在 + 权限(config.toml 属主 root、mysqlchk.cnf 属主 mysql，均 600，非预期 → WARN)；节点间 3306/9200/10005 可达性。
12. **连接数/负载**：`Threads_connected` vs `max_connections`(`SHOW STATUS`/`SHOW VARIABLES`，mysqlchk 账号可读)；**长查询统计需 PROCESS 权限，mysqlchk 不具备 → 该子项用 root 凭据或降级 INFO 并提示**。
13. **结论**：整体级别 + 计数 + **覆盖度** + 问题清单 + 退出码。

## 角色裁剪矩阵 (Role-Aware Sectioning)

本机没有的组件标 `INFO`(跳过)而非报错；端口监听亦按角色裁剪：

| 检查区 | PG primary/replica | PG etcd-quorum | MySQL primary/replica | MySQL arbiter |
|--------|:---:|:---:|:---:|:---:|
| 身份 | ✓ | ✓ | ✓ | ✓ |
| 本机服务(DB/haproxy) | ✓ | 跳过 | ✓ | 跳过 |
| etcd / repman | ✓ | ✓(仅 etcd) | 探 arbiter API | ✓(repman 本机) |
| 集群拓扑 | ✓(patronictl) | ✓(**etcdctl 数据通路**) | ✓(repman API) | ✓(repman API) |
| 复制 / 静默退化 | ✓ | 跳过 | ✓ | 跳过(无本地 DB) |
| 入口一致性 | ✓ | 跳过 | ✓ | 跳过 |
| 防脑裂 | ✓(etcd 视角) | ✓(etcd 视角) | ✓(repman 视角) | ✓(repman 视角) |
| 磁盘/时钟/日志/配置自检 | ✓ | ✓(自身组件) | ✓ | ✓(自身组件) |
| 连接数/负载 | ✓ | 跳过 | ✓ | 跳过 |

> **quorum 节点凭据现实**：无 patroni.yml 可提取 etcd 密码，`etcdctl member list` 多半无凭据 → 默认只用免认证 `/health`，拓扑明细降级 WARN/INFO，不报 CRIT。

## 巡检覆盖度与置信度 (Coverage & Confidence)

单机巡检对跨节点状态是"尽力而为"。总结块(检查项 13)明确打印"**跨节点探测覆盖 N/M 节点**"；当关键跨节点数据源不可达时，**防脑裂/入口一致性结论标注"不完整，可能漏报"**，不假装看到全局。这是对"每台分别运行 + 跨节点依赖端口放行"前提的诚实交代。

## 健壮性与只读保证 (Robustness & Read-Only Guarantees)

- 入口与模块 `#!/usr/bin/env bash` + `set -euo pipefail`；每个检查内部对易失败命令用子 shell + `|| true` 隔离，**单项失败降级为 WARN/INFO，绝不中断整体**。
- 远程节点/API/缺命令 → WARN/INFO + 提示，不崩。尽量不强依赖 `jq`(repman JSON 优先 `grep/sed`，jq 仅增强)。
- **`require_root || exit 4`**：在加载模块后、读取任何配置/执行任何检查**之前**第一步执行(`lib/common.sh` 的 `require_root` 是 `return` 非 `exit`，入口必须显式 `|| exit`)。
- **只读命令白名单**(立正面约束，非黑名单)：
  - `patronictl`：**仅 `list`**(可带 `-c`/`--format`)；禁 `switchover/failover/edit-config/remove/reinit/restart/reload/pause/resume`。
  - `etcdctl`：仅 `endpoint health`/`member list`/`endpoint status`；禁 `put/del/user/role/auth/move-leader/snapshot/defrag` 等。
  - `psql`/`mysql`：仅 `SELECT`/`SHOW`/只读系统函数；**禁 `pg_promote()`/`pg_terminate_backend()`/`ALTER SYSTEM`/`SET GLOBAL`/`STOP|START REPLICA`/`FLUSH` 等**。
  - `curl`：仅 GET(repman 若需 `POST /api/login` 取 JWT 为唯一例外，且 body/凭据走 stdin/`-K`，token 不外露)。
- **凭据处理纪律**：① 处理凭据的函数内 `set +x`，全脚本禁 `set -x`；② 凭据变量 `local`、**绝不 `export`**、用后 `unset`；③ HTTP 凭据经 `curl -K`/`--netrc-file`(临时文件 `umask 077`+`mktemp`+`trap rm EXIT`)，etcd 经 `ETCDCTL_USER/PASSWORD` 环境变量(子 shell 内、不导出全局)，MySQL 经 `--defaults-extra-file`；**严禁** `curl -u user:pass` / `mysql -p<pass>` / `etcdctl --user=root:pass` 等命令行明文；④ 提取用 `sed` 捕获组、不回显整行；展示日志/配置佐证前过 `status_redact`。
- 报告可打印节点 IP / 配置文件路径(对运维必要、非机密)，但**绝不打印任何密码值**；可选 `STATUS_REDACT_IP=1` 对 IP 末段打码(非默认)。

## 退出码 (Exit Codes)

- `0` 全 OK / `1` 有 WARNING / `2` 有 CRITICAL。
- `3` 总入口未识别到 HA 部署。
- `4` 前置/用法错误(非 root、缺关键依赖、参数错误)——**与健康度分开**，让 cron 能区分"巡检没跑起来"和"巡检发现问题"。
- `ha-status.sh` 透传被转发子脚本的退出码。

## 总入口探测与转发 (ha-status.sh)

探测逻辑实现为 `lib/status-common.sh` 的函数 `ha_status_detect_stack`(返回 `pg|mysql|both|none`)，入口只"加载 → 调探测 → 据结果加载对应模块 → 调 main"，符合"入口只加载+调用"约定，且可测。

1. 探测**仅用文件存在性**(`test -e`，不读内容)：`${PG_HA_PATRONI_YAML}`/`${PG_HA_ETCD_CONFIG_FILE}` → 候选 PG；`${MYSQL_HA_REPMAN_CONF}`/`${MYSQL_HA_MYCNF}` → 候选 MySQL。**走 config 路径变量**(已加载)而非裸写 `/etc`，使测试可用 `export` 覆盖路径、不触碰真实系统。
2. 仅一个候选 → 本进程 `load_linuxshell_modules` 追加对应 `common.sh`+`status.sh`，调 `*_status_main "$@"`，透传退出码。
3. 两者都有 → 提示用 `ha-status.sh pg|mysql` 指定。
4. 都没有 → 提示"未检测到 HA 部署"，退出码 3。
5. 支持显式 `ha-status.sh pg|mysql` 跳过探测。

> **不 `exec`/不二次 `curl` 子入口**：`bash <(curl ...)` 下 `BASH_SOURCE` 是进程替换文件、本地无子入口脚本；改为本进程内加载逻辑模块并调函数，本地/远程行为一致、零重复下载。`status-pg-ha.sh`/`status-mysql-ha.sh` 作为独立入口仍各自完整加载并调 main。

## 测试计划 (Testing)

对称现有测试，**全程 mock / mktemp / 路径变量覆盖，不触碰真实系统、服务、网络**(遵守 AGENTS.md；现有测试以 `bash tests/...` 调用)：

- `tests/test_pg_ha.sh` / `tests/test_mysql_ha.sh` 各增：
  - `lib/*/status.sh`、`lib/status-common.sh` 语法(`bash -n`)。
  - 关键函数存在性(`*_status_main`、角色发现、各分区检查、`status_record`/`status_recheck`/`ha_status_detect_stack`/`status_extract_kv` 等)。
  - 检查框架：`status_record CRIT` → `status_final_code`=2；WARN → 1；全 OK → 0。默认阈值断言(`source status-common.sh` 后)。
  - 角色发现：mktemp 伪造 `patroni.yml`/etcd 配置 + 函数覆盖 stub(`systemctl`/`psql`/`mysql`/`patronictl`/`curl`/`etcdctl`)，断言判定结果。
  - 配置取值：伪造 `haproxy.cfg`/`config.toml` 断言能提取 stats / api 凭据(MySQL 断言**保留 user**；PG 断言 etcd 凭据提取)。
  - `ha_status_detect_stack` 四分支(仅 PG / 仅 MySQL / both / none) + none→退出码 3，用路径变量覆盖伪造存在性。
  - **着色**：`NO_COLOR=1` 时输出无 ANSI(`\033`)。
  - **只读强断言**(对 `status*.sh`+`lib/status-common.sh`+`lib/*/status.sh` 全量，用**命令前缀精确匹配**避免误杀日志关键词 `failover`)：命中即 fail——
    - 服务控制 `systemctl (start|stop|restart|reload|enable|disable|mask|kill)`、`service `；
    - `patronictl .*(switchover|failover|edit-config|remove|reinit|restart|reload|pause|resume)`；`etcdctl .*(put|del|user |role |auth |move-leader|snapshot|defrag)`；
    - SQL 写 `(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|GRANT|REVOKE|TRUNCATE|SET +GLOBAL|FLUSH|RESET|STOP +REPLICA|START +REPLICA|CHANGE +REPLICATION|KILL |pg_promote|pg_terminate_backend)`；
    - HTTP 写 `curl .*(-X +(POST|PUT|DELETE|PATCH))`(豁免 repman `/api/login` 单点)；
    - 明文凭据 `curl .*(-u |--user )`、`mysql .*-p[^ ]`、`etcdctl .*--user=`、`--password=`；
    - 写系统路径 `> +/(etc|data|var|usr|run)/`、`tee +/(etc|...)`(豁免 `mktemp`/`$TMPDIR` 产物)。
    - 正向断言：凭据使用处出现 `--netrc-file`/`-K`/`ETCDCTL_PASSWORD` 安全传参标志。
  - **防泄露正向测试**：对含已知密码串的伪造配置跑提取/自检/日志脱敏，断言报告输出**不含该密码串**。
- 三入口语法 + **可执行位**(`[[ -x ... ]]`，对称 `install-*-ha.sh` 的 `-rwxr-xr-x`) + 远程下载列表 `grep` 含新模块文件名。
- 跨模块/入口加载变更 → 运行全部三个测试与全量 `bash -n`。

## 文档 (Docs)

- `README.md` 新增"HA 状态巡检"章节：三入口 `curl` 用法、退出码语义(含 3/4)、需 root、可覆盖阈值环境变量、各分区简述、**单机视角覆盖度说明**。与现有 HA 章节端口/路径/版本表述一致。

## 实现时需进一步核实的点 (To Verify During Implementation)

1. **repman API 协议 / 认证 / 端点**(唯一剩余开放项)：按 `replication-manager-osc v3.1.28` 核实 REST API 是 HTTP 还是自签名 HTTPS(代码 `repman.sh` 只显式配了 `http-server`/`http-port`=10001 的 Web 控制台，`api-port`=10005 协议待证)、basic auth 还是 `POST /api/login` 取 JWT、集群拓扑端点路径。凭据从 `config.toml` `api-credentials` 取且**必带 user**(默认 admin)；**不复用** `mysql_ha_repman_api_url`(其硬编码 `http://`)。不可达一律降级 WARN。

> 以下原"待核实"经子代理对照代码**已确认**，不再是开放项：mysqlchk 有 REPLICATION CLIENT(`mysql.sh:168`)；Patroni `/primary` GET 免认证(`haproxy.sh:26` 即免认证探测)；HAProxy stats `/;csv` 端点成立(stats 绑 `*:port`、`stats uri /`)；etcd `/health` 免认证且绑 127.0.0.1(`etcd.sh:12`)，但 `member list` 需 `root:${PG_HA_ETCD_PASSWORD}`。

## 未来可扩展 (Future Extensions)

- errant GTID 检测、最近 failover 时间。
- `--json`(经 `status_record` 接缝换后端)、`--watch`。
- 只读运维"建议命令"打印(发现问题给出建议的手工命令，仍不自动执行)。

## 审查修订记录 (Review Revisions)

经 4 个并行子代理审查后，本版相对初稿的主要修订：

- **技术准确性**：修正端点绑定/访问地址(mysqlchk/Patroni 用对外 IP，etcd/stats 用 127.0.0.1)；etcd RBAC 下 `member list` 需 root 认证、优先用 `/health`；MySQL 跨节点状态只能经 mysqlchk HTTP；写定 mysqlchk 账号权限(有 REPLICATION CLIENT、无 PROCESS)；4 个原"待核实"中 3 个已确认、仅留 repman API。
- **巡检逻辑**：failover 敏感判定引入二次复采(用户决策);防脑裂改用 DCS/仲裁视角并诚实声明单机盲区、不可达单列第三态;补静默退化检测(PG 复制槽 inactive / Patroni paused / etcd 剩 2 节点 / TL 分叉;MySQL 半同步退化 / IO 线程断 / 僵尸主);PG 滞后阈值与 `maximum_lag_on_failover` 挂钩、MySQL 先判 IO/SQL 线程;新增覆盖度与置信度。
- **可实现性**：`ha-status.sh` 改为本进程加载逻辑模块并调 main(不 exec 子入口)、探测逻辑下沉 `status-common.sh` 并走 config 路径变量;三入口远程下载清单写定;退出码增加 3(未识别)/4(前置错误)。
- **安全/只读**：禁命令行明文凭据(curl `-K`/netrc、etcdctl 环境变量、mysql defaults-extra-file);立只读命令白名单(patronictl 仅 list、psql 禁 pg_promote 等);新增凭据处理纪律(禁 xtrace、local 不 export、临时文件 600+trap、提取不回显、日志/配置脱敏);`require_root||exit`;测试只读断言强化为命令前缀精确匹配 + 防泄露正向测试。
