# Docker Install and Modular Deploy Script Design

## Summary

Add a dedicated one-click Docker installation path while splitting the existing `deploy.sh` into focused Bash modules. The current `deploy.sh` remains the primary interactive deployment entrypoint, and a new `install-docker.sh` provides a Docker-only curl-friendly entrypoint.

The core design goal is to keep the user-facing behavior stable while making future deployment features grow by adding modules instead of expanding one large script.

## Goals

- Keep the existing `deploy.sh` one-click usage working:

  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/deploy.sh)
  ```

- Add a Docker-only one-click usage:

  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main/install-docker.sh)
  ```

- Add a Docker-only option to the interactive `deploy.sh` menu.
- Split the existing deployment code into modules with clear ownership.
- Preserve the existing sourceable function surface used by `tests/test_deploy.sh`.
- Preserve environment override behavior such as `DATA_ROOT`, image variables, compose file paths, and `PG_WRAPPER_BIN`.
- Keep service deployment behavior unchanged unless required by the Docker-only feature.

## Non-Goals

- Do not change container images, default ports, default credentials, or data directory conventions.
- Do not replace Docker Compose with another orchestrator.
- Do not add firewall, backup, monitoring, or domain provisioning.
- Do not require users to clone the repository before using one-click install commands.
- Do not introduce a build or release bundling step for script distribution.

## User Decisions Captured

- Docker one-click installation should follow the recommended approach:
  - `deploy.sh` can install only Docker through the menu.
  - `install-docker.sh` provides a dedicated Docker-only curl entrypoint.
  - Both reuse the same Docker installation module.
- The architecture should prioritize future growth by splitting `deploy.sh` into modules.
- The current curl-based one-click deployment experience must remain available.

## Proposed File Layout

### Entrypoints

- `deploy.sh`
  - Thin interactive entrypoint.
  - Loads modules.
  - Calls `main "$@"` only when executed directly.
  - Remains sourceable in tests.

- `install-docker.sh`
  - Thin Docker-only entrypoint.
  - Loads `lib/config.sh`, `lib/common.sh`, and `lib/docker.sh`.
  - Runs root and OS checks, then calls `install_docker`.

- `install-pg-wrapper.sh`
  - Remains self-contained.
  - No required changes for this feature.

### Modules

- `lib/config.sh`
  - Top-level paths, image tags, default ports, project names, shared network name, and selection state.
  - Keeps environment override semantics centralized.

- `lib/common.sh`
  - `require_root`
  - `detect_os`
  - `command_exists`
  - `to_lower`
  - `print_step`
  - prompt helpers
  - port checks
  - file overwrite confirmation

- `lib/docker.sh`
  - `install_apt_dependencies`
  - `install_docker`
  - Docker apt repository setup
  - Docker Compose plugin validation

- `lib/caddy.sh`
  - Caddy installation.
  - Caddy layout configuration.

- `lib/compose.sh`
  - Shared Docker network management.
  - `start_compose_file`
  - `stop_compose_file`

- `lib/pg-wrapper.sh`
  - `install_pg_wrapper`
  - `PG_WRAPPER_BIN` and installed-user tracking live in config or this module.

- `lib/services/postgres.sh`
  - PostgreSQL prompts.
  - Compose generation.
  - Reinstall and migration logic.
  - Prepare/start flow.

- `lib/services/mysql.sh`
  - MySQL prompts.
  - MySQL client detection and installation.
  - Config and init SQL generation.
  - Compose generation.
  - Reinstall and prepare/start flow.

- `lib/services/rabbitmq.sh`
  - RabbitMQ prompts.
  - Config and enabled plugins generation.
  - Compose generation.
  - Reinstall and prepare/start flow.

- `lib/services/redis.sh`
  - Redis prompts.
  - Compose generation.
  - Prepare/start flow.

- `lib/deploy-main.sh`
  - Service selection menu.
  - Selection parsing.
  - Main orchestration.
  - Final summary output.

## Module Loading Design

`deploy.sh` and `install-docker.sh` need to work in two modes:

1. Local repository mode, where `lib/` exists next to the entrypoint.
2. Remote curl mode, where process substitution gives Bash a temporary script path and no local `lib/` directory exists.

The entrypoints should use a shared loader pattern:

1. Determine `SCRIPT_DIR` from `BASH_SOURCE[0]`.
2. If `${SCRIPT_DIR}/lib/config.sh` exists, load modules from the local filesystem.
3. Otherwise, create a temporary directory and download the required modules from GitHub raw.
4. Source modules from that temporary directory.

The remote base URL should default to:

```bash
https://raw.githubusercontent.com/ai-agent-generate/linuxshell/main
```

It should be overridable for tests and branch testing:

```bash
LINUXSHELL_RAW_BASE_URL=https://raw.githubusercontent.com/.../branch-name
```

The loader should only download the modules needed by the current entrypoint:

- `deploy.sh` downloads all deployment modules.
- `install-docker.sh` downloads only config/common/docker modules.

The loader should fail fast with a clear error if a required module cannot be downloaded or sourced.

## Interactive Selection Design

Add Docker as a first-class selectable component.

Aliases should be accepted:

- `docker`
- `caddy`
- `postgres`, `postgresql`
- `mysql`
- `rabbitmq`
- `redis`
- `pg`, `pg-shortcut`

For compatibility with existing numeric selections, add Docker as option `7` and keep existing numbers unchanged:

```text
1) Caddy
2) PostgreSQL
3) MySQL
4) RabbitMQ
5) Redis
6) Install pg shortcut (PostgreSQL already running)
7) Docker only
```

This avoids breaking users who already choose services by number. The visible label should make clear that Docker-only installs Docker and Compose, then exits after the summary.

## Main Flow

`deploy.sh` should keep the current high-level flow:

1. Require root.
2. Detect Ubuntu/Debian.
3. Ensure the data root is writable.
4. Ensure required directories exist.
5. Collect component selection.
6. Install Docker when:
   - Docker-only is selected, or
   - Caddy is selected, or
   - any container service is selected.
7. Install Caddy if selected.
8. Configure and prepare selected services.
9. Install the pg shortcut after PostgreSQL deployment.
10. Install only the pg shortcut when selected without PostgreSQL.
11. Print a deployment summary.

The Docker-only path should not prompt for service settings, should not generate compose files, and should not create service-specific directories beyond what the existing initialization already creates. If avoiding service directory creation is simple after the split, the Docker-only path can skip `ensure_directories` and only run root/OS checks plus `install_docker`.

## Docker Installation Behavior

The existing Docker installation behavior should move to `lib/docker.sh` without changing the package set:

- `docker-ce`
- `docker-ce-cli`
- `containerd.io`
- `docker-buildx-plugin`
- `docker-compose-plugin`

It should continue to:

- install apt prerequisites,
- configure Docker's official apt repository,
- install Docker packages,
- enable and start the Docker service,
- skip installation when both `docker` and `docker compose` are already available.

After installation, `install_docker` should validate:

```bash
command -v docker
docker compose version
```

If either check fails, it should return a clear error.

## Compatibility Requirements

The following functions should remain available after `source deploy.sh` because the current tests and future contributors depend on this sourceable surface:

- `require_root`
- `detect_os`
- `ensure_directories`
- `configure_caddy_layout`
- `prompt_with_default`
- `prompt_yes_no`
- `parse_service_selection`
- `collect_service_selection`
- `write_postgres_compose`
- `write_mysql_config`
- `write_mysql_init_sql`
- `write_mysql_compose`
- `write_rabbitmq_compose`
- `write_rabbitmq_config`
- `write_rabbitmq_enabled_plugins`
- `write_redis_compose`
- `install_pg_wrapper`
- `install_docker`
- `install_caddy`
- `install_mysql_client`
- `ensure_shared_network`
- `start_compose_file`
- `stop_compose_file`
- `reinstall_postgres`
- `prepare_postgres`
- `reinstall_mysql`
- `prepare_mysql`
- `reinstall_rabbitmq`
- `prepare_rabbitmq`
- `prepare_redis`
- `show_summary`
- `main`

Tests may add explicit coverage for this compatibility surface before moving functions into modules.

## Error Handling

- Keep strict mode in entrypoints and modules.
- Modules must be safe to source and must not call `main` directly.
- Entrypoints should own process-level execution.
- Remote module loading should fail with the module name and URL that failed.
- Docker installation should fail if the final Docker or Compose checks are not healthy.
- The split should not add automatic rollback behavior.

## Testing Strategy

Use test-first changes for the split and Docker-only feature.

### New behavior tests

- `parse_service_selection "docker"` sets `SELECT_DOCKER=1`.
- Numeric Docker-only selection sets `SELECT_DOCKER=1`.
- Docker-only selection is accepted as a valid menu selection.
- Docker-only path calls `install_docker`.
- Docker-only path does not call service configure or compose generation functions.
- `install-docker.sh` exists, is executable, and passes `bash -n`.
- `install-docker.sh` uses the shared Docker module rather than duplicating install logic.

### Compatibility tests

- Source `deploy.sh` and assert existing public functions still exist.
- Existing generation, helper, and smoke tests remain green.
- Local module loader uses filesystem modules when `lib/` exists.
- Remote module loader can be tested with a `file://` or temporary HTTP-style base path if practical; if not, isolate URL construction into a function and test that function without network.

### Verification commands

```bash
bash tests/test_deploy.sh all
bash -n deploy.sh
bash -n install-docker.sh
bash -n install-pg-wrapper.sh
find lib -name '*.sh' -print0 | xargs -0 -n1 bash -n
```

## Implementation Risks

### Curl entrypoint regression

Splitting into modules can break `bash <(curl .../deploy.sh)` if the entrypoint assumes local files exist. The remote module loader is required to preserve the current one-click user experience.

### Numeric menu compatibility

Renumbering existing menu items can break users who already know the numbers. Docker should be appended as a new option unless there is a strong reason to reorder.

### Global state drift

The existing script uses global variables heavily. Moving variables into modules must preserve initialization order. `lib/config.sh` should be loaded first, before modules that read paths, image tags, or selection flags.

### Test drift during split

Moving functions between files can temporarily make tests fail due to source order, not behavior. The implementation plan should move modules in small chunks and keep tests green after each chunk.

### Duplicate Docker logic

`install-docker.sh` must source `lib/docker.sh`; it should not copy the Docker installation implementation. Tests should catch obvious duplication by checking for a source/load call and by keeping Docker install code in only one module.

## Documentation Updates

Update `README.md` with:

- Docker-only one-click install command.
- Updated component table including Docker-only selection.
- Note that selecting any container service still installs Docker automatically.
- Note that `deploy.sh` remains the full interactive entrypoint.

## Success Criteria

- `deploy.sh` is substantially smaller and acts primarily as an entrypoint.
- Docker installation logic exists in one shared module.
- Users can install only Docker through `install-docker.sh`.
- Users can install only Docker through the `deploy.sh` menu.
- Existing deployment behavior and tests continue to pass.
- Future services can be added by creating a module and adding selection/orchestration glue, without editing a large monolithic script.
