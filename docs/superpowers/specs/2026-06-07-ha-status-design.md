# HA 状态巡检脚本 (PostgreSQL HA / MySQL HA) — 设计方案

## 概述 (Summary)

为现有 `linuxshell` 项目已落地的两套高可用方案(PostgreSQL 18 + Patroni + etcd + HAProxy，MySQL 8.4 + Replication Manager + HAProxy)新增**只读状态巡检脚本**。

目标读者是**刚接手、不了解历史配置的运维人员**：在任意一台 HA 节点上跑一条命令，就能立刻看清"**本机是什么角色(主/从/仲裁)、各服务是否正常、整个集群拓扑、复制是否健康、有没有隐患**"，并以退出码表达整体健康度(可直接接 cron 告警)。

核心约束：**纯只读**——绝不重启服务、不切主、不改配置、不打印密码明文，可在生产环境随时安全运行。功能以独立入口脚本提供，复用现有 `load_linuxshell_modules` 加载机制与 `lib/common.sh`，新增逻辑收敛在 `lib/pg-ha/status.sh`、`lib/mysql-ha/status.sh` 与共享库 `lib/status-common.sh`。

## 目标 (Goals)

- 在任一 HA 节点上一条命令完成本机 + 全集群的状态巡检，**无需人工输入任何密码**。
- **不依赖部署时的环境变量**(`PG_HA_ROLE` / `MYSQL_HA_ROLE` 部署后并未落盘)，纯从运行时实际状态反推本机身份。
- 彩色人类可读报告 + 标准退出码(`0`=OK / `1`=WARNING / `2`=CRITICAL)，便于 cron / 告警集成。
- 覆盖核心巡检 + 关键隐患排查 + 故障取证三档功能(见"检查项清单")。
- 提供与现有项目一致的 `curl` 一键体验与本地/远程双模运行：

  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/ha-status.sh)
  ```

- 复用现有公共模块与 `config.sh`(端口、路径、变量名单一来源)。
- 全程 `set -euo pipefail`，单项检查失败不中断整体巡检。

## 非目标 (Non-Goals)

- ❌ **不做任何写操作 / 运维动作**：不重启服务、不触发 Patroni/repman 切换、不重建从库、不改配置。运维动作由 `patronictl` / repman API 等专用工具承担。
- ❌ 不做 `--json` 机器可读输出(本期只做彩色报告 + 退出码；未来可加，故"采集"与"渲染"在代码上保持可分)。
- ❌ 不做 `--watch` 持续刷新模式。
- ❌ 不做 errant GTID 检测(用户本期未选；检查框架设计为易扩展，未来可作为一条新检查加入)。
- ❌ 不做故障切换历史 / 上次 failover 时间。
- ❌ 不修改防火墙、不安装任何软件(沿用现有项目传统；缺命令时优雅降级提示)。
- ❌ 不改动现有 `install-pg-ha.sh` / `install-mysql-ha.sh` / `deploy.sh` 的部署行为。

## 已确定的用户决策 (User Decisions Captured)

1. **职责边界 = 纯只读巡检**：只读取、展示、诊断、给健康结论，绝不改动系统。
2. **输出形态 = 彩色终端报告 + 退出码**(0/1/2)：不做 JSON / watch。
3. **功能范围**：
   - 第 1 档(核心，全做)：本机身份识别、服务健康、集群拓扑、复制健康、健康结论。
   - 第 2 档(隐患排查，全做)：入口一致性校验、防脑裂/多主检测、磁盘容量、时钟同步。
   - 第 3 档(故障取证，选做)：关键日志摘要、配置/连通性自检、连接数/负载快照。**不含** errant GTID / 切换历史。
4. **入口方式 = 两独立入口 + 总入口**：`status-pg-ha.sh`、`status-mysql-ha.sh`(对称现有 `install-*-ha.sh`) + `ha-status.sh`(自动探测本机装的是哪套 HA 并转发)。
5. **身份与凭据策略**：本机角色从运行状态自动发现；查询所需密码从 root 可读的落盘配置文件(600)自动提取，全程不回显明文。

## 文件布局 (File Layout)

```
status-pg-ha.sh          # 根入口：PG HA 巡检(对称 install-pg-ha.sh)
status-mysql-ha.sh       # 根入口：MySQL HA 巡检(对称 install-mysql-ha.sh)
ha-status.sh             # 根入口：总入口，自动探测并转发到上面之一
lib/status-common.sh     # 共享：着色 / 检查框架 / 退出码 / 表格 / 配置取值 / 通用探测
lib/pg-ha/status.sh      # PG 巡检逻辑(pg_ha_status_main)
lib/mysql-ha/status.sh   # MySQL 巡检逻辑(mysql_ha_status_main)
```

**模块加载**(复用现有 `load_linuxshell_modules`，本地优先、缺失则从 `LINUXSHELL_RAW_BASE_URL` 下载)：

- `status-pg-ha.sh` 加载：`lib/common.sh` → `lib/status-common.sh` → `lib/pg-ha/config.sh` → `lib/pg-ha/common.sh` → `lib/pg-ha/status.sh`，最后调用 `pg_ha_status_main`。
- `status-mysql-ha.sh` 加载：`lib/common.sh` → `lib/status-common.sh` → `lib/mysql-ha/config.sh` → `lib/mysql-ha/common.sh` → `lib/mysql-ha/status.sh`，最后调用 `mysql_ha_status_main`。
- `ha-status.sh` 仅加载 `lib/common.sh` + `lib/status-common.sh`(用于探测与着色)，探测后 `exec`/`source` 对应入口；远程模式下按探测结果只下载所需模块。

> 复用现有 `config.sh` 是关键：端口、文件路径、集群名、节点 IP 变量、默认值都从那里来，巡检脚本不重复定义，避免与部署逻辑漂移。

## 核心机制一：检查框架 (status-common.sh)

提供一套轻量"检查项"原语，让两套巡检逻辑只描述"检查什么"，不重复实现"怎么着色、怎么累计、怎么定退出码"。

- `status_reset`：重置全局计数器 `STATUS_WARN_COUNT=0`、`STATUS_CRIT_COUNT=0` 及问题清单数组。
- `status_section "<标题>"`：打印分区标题(复用风格类似 `print_step`)。
- `status_record <OK|WARN|CRIT|INFO> "<标题>" "<详情>"`：记录并即时彩色打印一行；`WARN`/`CRIT` 同时计入计数器并追加到"发现的问题"清单。
- 便捷封装：`status_ok` / `status_warn` / `status_crit` / `status_info`(转调 `status_record`)。
- `status_kv "<键>" "<值>"`：对齐打印键值对(用于身份区)。
- `status_table_row a b c ...`：列对齐输出(用于拓扑/复制表)。
- `status_summary`：打印总结块——整体级别、WARN/CRIT 数、问题清单。
- `status_final_code`：整体级别 = `CRIT>0?2 : WARN>0?1 : 0`，作为脚本退出码。

**着色规则**：仅当 stdout 是 tty 且未设置 `NO_COLOR` 时启用 ANSI 色(绿 OK / 黄 WARN / 红 CRIT / 灰 INFO)；重定向到文件或 cron 时自动纯文本，保证日志可读。

**阈值(默认值，均可经环境变量覆盖，沿用项目"配置可覆盖"约定)**：

| 变量 | 默认 | 含义 |
|------|------|------|
| `STATUS_DISK_WARN_PCT` / `STATUS_DISK_CRIT_PCT` | 80 / 90 | 数据目录分区使用率告警线 |
| `STATUS_PG_LAG_WARN_MB` / `STATUS_PG_LAG_CRIT_MB` | 64 / 512 | PG 复制延迟(MB) |
| `STATUS_MYSQL_LAG_WARN_SEC` / `STATUS_MYSQL_LAG_CRIT_SEC` | 30 / 300 | MySQL `Seconds_Behind_Source` |
| `STATUS_CONN_WARN_PCT` / `STATUS_CONN_CRIT_PCT` | 80 / 95 | 连接数占 max_connections 比例 |
| `STATUS_LOG_LINES` | 20 | 日志摘要抓取行数 |

**配置取值辅助**：`status_extract_kv <file> <key>` 等小函数，从落盘配置安全提取值(找不到返回空 + 调用方降级)，例如：

- HAProxy stats 凭据：从 `haproxy.cfg` 的 `stats auth admin:<pass>` 提取。
- repman API 凭据：从 `config.toml` 的 `api-credentials = "<user>:<pass>"` 提取(**保留 user，避免 401**)。

## 核心机制二：本机角色自动发现

不读部署期环境变量，按"装了什么 + 运行态"判定。判定结果存入运行期变量(如 `PG_HA_DETECTED_ROLE`)，仅供本次报告使用。

**PostgreSQL**：

1. 存在 `${PG_HA_PATRONI_YAML}`(`/etc/patroni/patroni.yml`) 且有 `patroni.service` → **PG 数据节点**；进一步：
   - `sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery()'`(走 patroni.yml 中 `local all all trust`，免密) → `f`=**primary(Leader)** / `t`=**replica**。
   - 兜底：解析 `patronictl -c <yaml> list` 中本机 `name` 行的 Role 列。
2. 无 patroni.yml、仅有 etcd(`/etc/etcd/etcd.conf.yml` + `etcd.service`) → **etcd-quorum 节点**。
3. 节点编号：本机 IP(`hostname -I` 集合) 与 `PG_HA_NODE1/2/3_IP` 比对得出 node1/2/3。集群名取 `PG_HA_CLUSTER_NAME` 或解析 patroni.yml `scope:`。

**MySQL**：

1. 存在 `mysqld` 服务 + `${MYSQL_HA_MYCNF}`(`zz-mysql-ha.cnf`) → **MySQL 数据节点**；进一步：
   - `mysql --defaults-extra-file=${MYSQL_HA_MYSQLCHK_CNF} -N -B -e 'SELECT @@global.read_only'` → `0`=**primary** / `1`=**replica**(读系统变量无需特权，角色判断必成)。
   - 兜底：`@@server_id`(1=primary / 2=replica)。
2. 存在 `/etc/replication-manager/config.toml` + `replication-manager.service` 且**无** mysqld → **arbiter 仲裁节点**。
3. 节点编号：本机 IP 与 `MYSQL_HA_NODE1/2/3_IP` 比对；集群名取 `MYSQL_HA_CLUSTER_NAME` 或解析 config.toml 段名。

## 核心机制三：状态数据源汇总 (Data Sources)

所有数据源均为本机可达且只读：

| 维度 | PG HA 数据源 | MySQL HA 数据源 |
|------|-------------|-----------------|
| 服务态 | `systemctl is-active/is-enabled` + `show -p ActiveEnterTimestamp`：`etcd`/`patroni`/`haproxy` | `mysql`/`haproxy`/`mysqlchk.socket`/`replication-manager` |
| 端口监听 | `port_in_use`(复用 common.sh)：5432/8008/2379/2380/5000/7000 | 3306/6446/7001/9200/10005/10001 |
| 本机角色 | `sudo -u postgres psql`(local trust) | `mysql --defaults-extra-file=mysqlchk.cnf` |
| 集群拓扑 | `patronictl -c /etc/patroni/patroni.yml list` | repman API(凭据取自 config.toml) |
| 主库判定 | 各节点 `GET http://IP:8008/primary`(200/503，免认证) | 各节点 `@@global.read_only` / mysqlchk `GET :9200`(200/503) |
| 复制 | `pg_stat_replication` / `pg_replication_slots`(主库)；`pg_is_in_recovery`/`pg_last_wal_replay_lsn`(从库) | `SHOW REPLICA STATUS` / `Rpl_semi_sync_*` 状态变量 |
| HAProxy 后端 | stats CSV：`curl -u admin:<pass> 'http://127.0.0.1:7000/;csv'` | `http://127.0.0.1:7001/;csv` |
| etcd 健康/quorum | `curl http://127.0.0.1:2379/health`；`etcdctl member list`(凭据从 patroni.yml etcd 段) | — |
| 磁盘 | `df -P ${PG_HA_PGDATA}` / `${PG_HA_ETCD_DATA}` | `df -P ${MYSQL_HA_DATADIR}` |
| 时钟 | `timedatectl show -p NTPSynchronized`(复用 common.sh 思路) | 同左 |
| 日志 | `journalctl -u <svc> -n ${STATUS_LOG_LINES} -p warning` | 同左 |
| 配置自检 | 文件存在 + `stat -c %a` 权限校验 + `pg_ha_check_connectivity` 跨节点端口探测 | `mysql_ha_check_connectivity` |

> **凭据提取统一原则**：脚本以 root 运行可读 600 配置文件；提取出的密码仅用于本地 `curl`/`mysql` 调用，绝不 `echo`。报告中涉及凭据处只显示来源文件，不显示值。

## 检查项清单：PostgreSQL HA (status-pg-ha.sh)

按报告分区，括号内为级别判定要点：

1. **身份**：本机角色(primary/replica/etcd-quorum)、hostname、本机 IP、node 编号、集群名、PG 大版本。
2. **服务健康**：`etcd`/`patroni`/`haproxy` 各自 active(CRIT if failed)、enabled(WARN if 未开机自启)、运行时长；对应端口监听(CRIT if 该角色应监听却未监听)。
3. **集群拓扑**：`patronictl list` 全表(Member/Host/Role/State/TL/Lag)，**高亮本机**；明确指出当前 Leader 是谁(CRIT if 无 Leader)。
4. **复制健康**：从库复制延迟 vs 阈值、`state`(streaming?)、同步/异步模式、复制是否中断(CRIT)；复制槽 `active` 状态与 WAL 保留。
5. **入口一致性**：HAProxy stats 后端 `pg_primary` 各 server UP/DOWN；交叉校验"HAProxy 唯一 UP 的后端" == "Patroni Leader / `GET /primary`=200 的节点"(不一致 → CRIT，疑似路由错乱)。
6. **防脑裂**：etcd `/health` + 成员数与 quorum(成员 <2 可服务 → CRIT，自动故障转移能力受损)；统计 `GET /primary`=200 的节点数(>1 → CRIT 多主)。
7. **磁盘**：`PGDATA`、`etcd data` 所在分区使用率 vs 阈值；WAL 目录大小提示。
8. **时钟同步**：NTP 同步状态(未同步 → WARN，etcd/Patroni 租约时间敏感)。
9. **关键日志摘要**：`etcd`/`patroni`/`haproxy` 最近 `STATUS_LOG_LINES` 行 warning+ 级日志，高亮 error/fatal/failover。
10. **配置/连通性自检**：`patroni.yml`/`haproxy.cfg`/`etcd.conf.yml` 存在性 + 权限(非 600 → WARN)；节点间 2379/8008/5432 可达性探测。
11. **连接数/负载**：`pg_stat_activity` 连接数 vs `max_connections`(阈值)、最长事务时长、复制槽数量。
12. **结论**：整体级别 + WARN/CRIT 计数 + 问题清单 + 退出码。

## 检查项清单：MySQL HA (status-mysql-ha.sh)

1. **身份**：本机角色(primary/replica/arbiter)、hostname、本机 IP、node 编号、集群名、server_id、MySQL 版本。
2. **服务健康**：数据节点 `mysql`/`haproxy`/`mysqlchk.socket`；arbiter `replication-manager`；active/enabled/运行时长 + 端口监听。
3. **集群拓扑**：repman API 集群状态(master / slaves / 各节点 state)，**高亮本机**；明确当前 master(CRIT if 无)。arbiter 上这是主视角。
4. **复制健康**：`Replica_IO_Running`/`Replica_SQL_Running`(任一非 Yes → CRIT)、`Seconds_Behind_Source` vs 阈值、半同步 `Rpl_semi_sync_*` 状态、`Last_Error` 摘要。
5. **入口一致性**：HAProxy stats 后端 `mysql_primary` UP/DOWN；mysqlchk `GET :9200`(200/503)；交叉校验"HAProxy 唯一 UP 后端" == "`read_only=0` 的实际主"(不一致 → CRIT)。
6. **防脑裂**：统计 `read_only=0` 的数据节点数(>1 → CRIT 多主红线)；arbiter 上 `replication-manager` 是否在监控(未运行 → CRIT，失去自动故障切换)。
7. **磁盘**：`datadir`、repman datadir 分区使用率 vs 阈值；binlog 占用提示。
8. **时钟同步**：NTP 状态(未同步 → WARN，failover 决策时间敏感)。
9. **关键日志摘要**：`mysql`/`haproxy`/`mysqlchk@*`/`replication-manager` 最近日志，高亮 error/failover。
10. **配置/连通性自检**：`zz-mysql-ha.cnf`/`config.toml`/`mysqlchk.cnf`/`haproxy.cfg` 存在性 + 权限(config.toml/mysqlchk.cnf 非 600 → WARN)；节点间 3306/9200/10005 可达性。
11. **连接数/负载**：`Threads_connected` vs `max_connections`(阈值)、长查询(`SHOW PROCESSLIST` 中超时阈值的查询数)。
12. **结论**：整体级别 + 计数 + 问题清单 + 退出码。

## 角色裁剪矩阵 (Role-Aware Sectioning)

本机没有的组件标 `INFO`(跳过)而非报错：

| 检查区 | PG primary/replica | PG etcd-quorum | MySQL primary/replica | MySQL arbiter |
|--------|:---:|:---:|:---:|:---:|
| 身份 | ✓ | ✓ | ✓ | ✓ |
| 本机服务(DB/haproxy) | ✓ | 跳过 | ✓ | 跳过 |
| etcd / repman 服务 | ✓ | ✓(仅 etcd) | ✓(经 arbiter) | ✓(repman) |
| 集群拓扑 | ✓ | ✓(经 etcd) | ✓ | ✓ |
| 复制健康 | ✓ | 跳过 | ✓ | 跳过(无本地 DB) |
| 入口一致性 | ✓ | 跳过 | ✓ | 跳过 |
| 防脑裂(etcd/repman) | ✓ | ✓ | ✓ | ✓ |
| 磁盘/时钟/日志/配置自检 | ✓ | ✓(自身组件) | ✓ | ✓(自身组件) |
| 连接数/负载 | ✓ | 跳过 | ✓ | 跳过 |

## 健壮性与只读保证 (Robustness & Read-Only Guarantees)

- 入口与模块均 `#!/usr/bin/env bash` + `set -euo pipefail`；每个检查函数内部对易失败命令用子 shell + `|| true` 隔离，**单项失败降级为 WARN/INFO，绝不中断整体巡检**。
- 远程节点 / API 不可达 → WARN(附"可能未启动 / 端口未放行"提示)，不崩溃。
- 缺命令(`patronictl`/`mysql`/`curl`/`etcdctl`/`jq`)→ 该项 INFO/WARN + 安装提示；尽量不强依赖 `jq`(repman JSON 解析优先用 `grep/sed`，`jq` 仅作增强)。
- **只读审计**：脚本内不得出现 `systemctl start/stop/restart`、`patronictl switchover/failover`、写文件、`mysql` 的非 SELECT/SHOW 语句；测试用断言把关(见测试计划)。
- 报告与日志中不出现任何密码明文。
- `require_root`：查询需读 600 配置 + `sudo -u postgres`，非 root 时明确报错退出。

## 退出码 (Exit Codes)

- `0`：全部 OK(允许有 INFO)。
- `1`：存在 WARNING，无 CRITICAL。
- `2`：存在 CRITICAL。
- `ha-status.sh` 透传被转发子脚本的退出码；探测失败(未识别到 HA)→ 退出码 `3` + 指引。

## 总入口探测逻辑 (ha-status.sh)

1. 判定本机部署：
   - 存在 `/etc/patroni/patroni.yml` 或 `/etc/etcd/etcd.conf.yml` → 候选 **PG**。
   - 存在 `/etc/replication-manager/config.toml` 或 `${MYSQL_HA_MYCNF}` → 候选 **MySQL**。
2. 仅一个候选 → 直接转发到对应 `status-*-ha.sh`(透传参数与退出码)。
3. 两者都有 → 打印提示，要求 `ha-status.sh pg` 或 `ha-status.sh mysql` 指定；同时支持显式子命令。
4. 都没有 → 提示"本机未检测到 PG/MySQL HA 部署"，退出码 3。
5. 支持 `ha-status.sh pg|mysql` 显式指定，跳过探测。

## 测试计划 (Testing)

对称现有测试，**全程 mock / mktemp，不触碰真实系统、服务、网络**(遵守 AGENTS.md)：

- `tests/test_pg_ha.sh` 增加：
  - `lib/pg-ha/status.sh`、`lib/status-common.sh` 语法检查(`bash -n`)。
  - 关键函数存在性(`pg_ha_status_main`、角色发现函数、各分区检查函数、`status_record` 等)。
  - 检查框架单元行为：`status_record CRIT` 后 `status_final_code` 返回 2；`WARN` → 1；全 OK → 0。
  - 角色发现逻辑：用临时目录伪造 `patroni.yml`/etcd 配置 + stub 命令，断言判定结果。
  - 配置取值：伪造 `haproxy.cfg` 断言能提取 stats 凭据。
  - **只读约束断言**：grep 整个 `status*.sh` 不含 `systemctl (start|stop|restart)`、`switchover`、`failover`、重定向写系统路径等。
- `tests/test_mysql_ha.sh` 增加：同构用例(含 repman `api-credentials` 提取须保留 user 的断言、`read_only` 角色判定 stub、只读约束断言)。
- 入口脚本(`status-pg-ha.sh`/`status-mysql-ha.sh`/`ha-status.sh`)语法 + 可执行位 + 远程下载列表包含新模块。
- 跨模块/入口加载逻辑变更 → 运行全部三个测试(`test_deploy.sh`/`test_pg_ha.sh`/`test_mysql_ha.sh`)与全量 `bash -n` 语法检查。

## 文档 (Docs)

- `README.md` 新增"HA 状态巡检"章节：三个入口的 `curl` 一键用法、退出码语义、需 root、可覆盖阈值环境变量、各报告分区简述。
- 与现有 PG HA / MySQL HA 章节的端口、路径、版本表述保持一致。

## 实现时需进一步核实的点 (To Verify During Implementation)

不影响整体设计，仅在写代码时落实：

1. **mysqlchk 用户权限**：`mysqlchk.cnf` 中 `mysqlchk` 账号是否有 `REPLICATION CLIENT`(查 `SHOW REPLICA STATUS`)。角色判定(`@@global.read_only`)必成；若复制详情权限不足，则降级为 WARN + 提示，不报错(读 `lib/mysql-ha/mysql.sh` 中 `mysqlchk` 授权语句确认)。
2. **repman API 认证与端点**：按 `replication-manager-osc v3.1.28` 核实是 basic auth 还是先 `POST /api/login` 取 JWT，以及集群拓扑端点路径；自签名 HTTPS 用 `curl -k`。凭据从 `config.toml` `api-credentials` 取，**务必带 user**(参见历史"漏传用户名致 401"教训)。
3. **HAProxy stats CSV 端点**：确认 `stats uri /` 下 CSV 取法为 `/;csv`(必要时回退解析 HTML)。
4. **Patroni REST `/primary` 免认证**：确认 GET 健康端点无需 basic auth(预期成立)；若需，则从 patroni.yml `restapi.authentication` 提取。

## 未来可扩展 (Future Extensions)

检查框架与"采集/渲染分层"为下列项预留低成本扩展位，本期不实现：

- errant GTID 检测、最近一次 failover 时间。
- `--json` 结构化输出(接 Prometheus/Zabbix)、`--watch` 持续刷新。
- 只读运维"建议命令"打印(发现问题时给出建议的 `patronictl`/repman 手工命令，仍不自动执行)。
