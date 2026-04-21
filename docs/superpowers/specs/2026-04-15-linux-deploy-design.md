# Linux One-Click Deployment Script Design

## Summary

Build a single interactive deployment script for Ubuntu/Debian that can:

- Install Docker Engine and Docker Compose plugin
- Install Caddy only, without generating any site configuration
- Interactively choose which containers to deploy from PostgreSQL, MySQL, RabbitMQ, and Redis
- Persist all generated files and service data under `/data`
- Generate one Docker Compose file per selected service directly under `/data/docker`

The script is intended for repeatable single-host setup with clear host-side configuration files that can be edited later without changing directories.

## Scope

### In scope

- Ubuntu/Debian support only
- Interactive component selection
- Latest stable package installation for Docker and Caddy
- Per-service compose generation:
  - `/data/docker/docker-postgres.yml`
  - `/data/docker/docker-mysql.yml`
  - `/data/docker/docker-rabbitmq.yml`
  - `/data/docker/docker-redis.yml`
- Service data persistence under `/data/<service>`
- Prompting for service credentials and ports with defaults that can be accepted or overridden
- Immediate startup with `docker compose -f ... up -d`
- Idempotent reruns that do not delete existing data

### Out of scope

- Multi-node deployment
- Firewall management
- Domain / HTTPS site provisioning
- Backup and restore automation
- Monitoring and alerting
- Orchestration beyond single-host Docker Compose

## User Decisions Captured

- Deployment mode: interactive selection
- OS support: Ubuntu/Debian only
- Caddy behavior: install only
- Service credentials: mixed mode with default values that can be overridden
- Compose layout: one file per service in `/data/docker`
- MySQL version line: use LTS, not innovation latest
- MySQL remote access: only the application user is allowed remote access by default; root is not opened remotely

## High-Level Flow

1. Verify the script is running as root.
2. Verify the system is Ubuntu/Debian and that `/data` is writable.
3. Install Docker from the official repository and ensure the Compose plugin is available.
4. Install Caddy from its stable package source.
5. Prompt the user to choose any combination of:
   - Caddy
   - PostgreSQL
   - MySQL
   - RabbitMQ
   - Redis
6. For each selected service, prompt for parameters with sensible defaults.
7. Create directories under `/data`.
8. Generate per-service Docker Compose YAML files under `/data/docker`.
9. For MySQL, generate a host-side config file under `/data/mysql/conf`.
10. Start the selected services with `docker compose -f <file> up -d`.
11. Print a final summary including ports, usernames, config file paths, and data directories.

## File and Directory Layout

### Generated compose files

- `/data/docker/docker-postgres.yml`
- `/data/docker/docker-mysql.yml`
- `/data/docker/docker-rabbitmq.yml`
- `/data/docker/docker-redis.yml`

### Data and config directories

- `/data/postgres/data`
- `/data/mysql/data`
- `/data/mysql/conf`
- `/data/mysql/env`
- `/data/rabbitmq/data`
- `/data/redis/data`

The script may also create small env or metadata files for convenience when credentials are generated or confirmed.

## Component Design

### Docker installation

- Use Docker's official Ubuntu/Debian repository flow
- Install:
  - `docker-ce`
  - `docker-ce-cli`
  - `containerd.io`
  - `docker-buildx-plugin`
  - `docker-compose-plugin`
- On rerun, skip package installation when Docker is already available

### Caddy installation

- Install Caddy from its stable package source
- Do not write `/etc/caddy/Caddyfile`
- Do not create `/etc/caddy/conf`
- Do not create the `/root/conf` symlink

Those post-install commands remain a manual user step after script completion.

### PostgreSQL

- Image line: current latest stable major/minor at script authoring time, but implementation should resolve this from a configurable variable rather than hardcoding `latest`
- Default port: `5432`
- Default database: `appdb`
- Default user: `postgres`
- Default password: prompt with a default value that can be accepted or changed
- Data path: `/data/postgres/data`
- Compose file: `/data/docker/docker-postgres.yml`

### MySQL

- Image line: MySQL LTS
- Default port: `3306`
- Default database: `appdb`
- Default application user: `app`
- Default application password: prompt with default value that can be changed
- Default root password: prompt with default value that can be changed
- Data path: `/data/mysql/data`
- Config path: `/data/mysql/conf/my.cnf`
- Compose file: `/data/docker/docker-mysql.yml`

#### MySQL config requirements

The generated `my.cnf` must include at least:

```cnf
[mysqld]
bind-address=0.0.0.0
default-authentication-plugin=mysql_native_password
server-id=1
log-bin=mysql-bin
binlog_expire_logs_seconds=86400
```

#### MySQL access model

- MySQL listens on the published host port, so the host machine can connect to it directly
- The host can connect using `127.0.0.1:<port>` or the server IP once the container is running
- Only the application user is created for remote access by default, for example `'app'@'%'`
- Root is not opened for remote access by default

#### MySQL client on the host

Host access requires a MySQL client binary on the host. The deployment script should:

- Detect whether a MySQL client is present
- If missing, prompt whether to install a client package on the host
- Prefer installing the Debian/Ubuntu default client package available on the system

If the host client is not installed, users can still execute SQL through the container, but host-side direct `mysql` command usage will not be available.

### RabbitMQ

- Image line: latest stable release line with management UI
- Default AMQP port: `5672`
- Default management port: `15672`
- Default user: `admin`
- Default password: prompt with default value that can be changed
- Data path: `/data/rabbitmq/data`
- Compose file: `/data/docker/docker-rabbitmq.yml`

### Redis

- Image line: latest stable release line
- Default port: `6379`
- Password: optional
- Data path: `/data/redis/data`
- Compose file: `/data/docker/docker-redis.yml`

If the Redis password is blank, generate a config that starts Redis without `requirepass`. If provided, start Redis with password protection enabled.

## Compose Generation Rules

- Generate only the files for services the user selected
- If a target compose file already exists, prompt for one of:
  - skip generation
  - overwrite
  - use existing file and only start/restart it
- Never delete an existing data directory
- Use `restart: unless-stopped`
- Use fixed `container_name` values for easier administration
- Write readable YAML intended for direct host-side editing

## Interaction Design

### Selection phase

Present the available components and allow free combination:

- Caddy
- PostgreSQL
- MySQL
- RabbitMQ
- Redis

### Service parameter phase

For each selected service, prompt for:

- host port
- database or username where applicable
- passwords where applicable

All prompts must provide a default value and allow pressing Enter to accept it.

### Client tooling phase

If MySQL is selected and no host `mysql` client is found, prompt whether to install the client package.

## Error Handling

- Use shell strict mode
- Fail fast on unrecoverable package installation or file write errors
- Print a clear message before each major step
- Validate required commands after installation
- Detect common problems such as:
  - unsupported OS
  - missing root privileges
  - `/data` not writable
  - port conflicts
  - Docker daemon unavailable after install

Do not attempt automatic rollback. Preserve partial state for inspection.

## Idempotency

- Re-running the script must not remove existing data
- Existing package installs should be detected and skipped when healthy
- Existing compose files must not be overwritten without confirmation
- Existing containers should be reconciled with `docker compose up -d`

## Testing Strategy

Implementation should use test-first verification where practical for shell scripting:

- `bash -n` syntax validation
- Focused checks for generated file content
- Validation that target paths are under `/data`
- Validation that MySQL config contains:
  - `bind-address=0.0.0.0`
  - `binlog_expire_logs_seconds=86400`
- Validation that compose files map expected ports and volumes
- Validation that reruns do not remove existing directories

## Open Implementation Notes

- "Use latest version" for Docker and Caddy should mean latest stable package available from the official repository at install time
- Container images should avoid floating `latest` tags where that would make behavior unpredictable; use explicit version variables in the script so the current intended stable versions are obvious and easy to update
- MySQL should follow the LTS line by explicit image tag selection
