# AGENTS.md

本文件适用于整个 `linuxshell` 仓库。

## 项目概览

这是一个面向 Ubuntu / Debian 服务器的一键部署脚本项目，主要用 Bash 部署 Docker、Caddy、PostgreSQL、MySQL、RabbitMQ、Redis，以及非 Docker 的 PostgreSQL HA 和 MySQL HA 方案。

入口脚本：

- `deploy.sh`: 交互式常规部署入口，会按需加载 `lib/` 下的模块。
- `install-docker.sh`: 仅安装 Docker Engine 和 Docker Compose plugin。
- `install-pg-wrapper.sh`: 安装 `pg` 快捷命令。
- `install-pg-ha.sh`: PostgreSQL 18 + Patroni + etcd + HAProxy 高可用入口。
- `install-mysql-ha.sh`: MySQL 8.4 + Replication Manager + HAProxy 高可用入口。

## 目录结构

- `lib/config.sh`: 常规 Docker 部署默认配置。
- `lib/common.sh`: 全局公共 Bash 工具函数。
- `lib/services/`: Docker 化服务模块。
- `lib/pg-ha/`: PostgreSQL HA 模块，按 `config -> common -> etcd -> patroni -> haproxy -> main` 顺序加载。
- `lib/mysql-ha/`: MySQL HA 模块，按 `config -> common -> mysql -> repman -> mysqlchk -> haproxy -> main` 顺序加载。
- `tests/`: Bash 测试，主要覆盖语法、函数存在性、配置生成和安全约束。
- `docs/superpowers/`: 设计说明与历史实现计划，仅在需要理解背景时参考。

## 开发约定

- 与用户的对话、状态更新、最终回复以及 git 提交说明均使用中文。
- 所有 Bash 脚本保持 `#!/usr/bin/env bash` 和 `set -euo pipefail`。
- 新增函数优先放到对应模块中，入口脚本只负责模块加载和调用主函数。
- 保持脚本既能本地运行，也能通过 `bash <(curl -fsSL ...)` 远程运行。入口脚本的 `load_linuxshell_modules` 会在本地模块不存在时下载依赖模块。
- 修改模块加载顺序时，同步检查入口脚本和对应测试里的加载顺序。
- 配置默认值集中放在 `config.sh`，允许通过环境变量覆盖。
- 涉及密码、token、账号信息时，不要写入真实密钥；测试中使用临时值或 mock。
- 避免让测试或本地验证改动真实 `/data`、系统服务、防火墙、APT 源或 Docker 状态。需要生成文件时使用 `mktemp -d` 或可覆盖的环境变量。

## 测试与验证

常用验证命令：

```bash
bash tests/test_deploy.sh
bash tests/test_pg_ha.sh
bash tests/test_mysql_ha.sh
```

快速语法检查：

```bash
find . -name '*.sh' -type f -not -path './.git/*' -print0 | xargs -0 -n1 bash -n
```

修改常规部署路径时至少运行 `bash tests/test_deploy.sh`。修改 PostgreSQL HA 路径时运行 `bash tests/test_pg_ha.sh`。修改 MySQL HA 路径时运行 `bash tests/test_mysql_ha.sh`。跨模块公共函数或入口加载逻辑变更时运行全部测试。

## 安全注意事项

- 部署脚本面向 root 服务器执行；本地开发时不要直接运行会安装软件、启动服务或写入系统目录的入口路径，除非明确需要并确认环境。
- HA 路径涉及数据库数据目录、复制状态、HAProxy 放行规则和故障切换逻辑。任何改动都要考虑已有数据、旧主回归、网络分区和连接重试行为。
- 脚本不负责修改防火墙；文档或输出中提到端口时，保持与 README 和实际配置一致。
- 修改默认镜像、数据库版本、端口、账号权限或数据目录布局时，同步更新 README 和测试断言。

## 提交前检查

- 保持脚本可执行位，尤其是根目录入口脚本和 `tests/*.sh`。
- 新增模块时更新入口脚本远程下载列表，并补充至少一条测试覆盖模块存在性或生成结果。
- 文档变更不强制运行完整测试，但若文档包含命令、端口、版本、环境变量或执行顺序，应与代码和 README 对齐。
