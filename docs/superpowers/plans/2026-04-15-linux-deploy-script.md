# Linux Deploy Script Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an interactive Ubuntu/Debian deployment script that installs Docker and Caddy, optionally installs a host MySQL client, and generates per-service Docker Compose files under `/data/docker` for PostgreSQL, MySQL, RabbitMQ, and Redis.

**Architecture:** Use a single `deploy.sh` entrypoint with small, sourceable Bash functions so generation logic can be tested without performing package installs. Keep each service generator independent and make `/data` overridable in tests via environment variables, while defaulting to `/data` in normal execution.

**Tech Stack:** Bash, Docker Compose plugin, apt, official Docker/Caddy package repositories

---

## Chunk 1: Testable Script Skeleton

### Task 1: Add a sourceable Bash entrypoint

**Files:**
- Create: `deploy.sh`
- Test: `tests/test_deploy.sh`

- [ ] **Step 1: Write the failing test**

```bash
./tests/test_deploy.sh skeleton
```

Expected: FAIL because `deploy.sh` does not yet expose the expected functions.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_deploy.sh skeleton`
Expected: FAIL with missing file or missing function error

- [ ] **Step 3: Write minimal implementation**

Add `deploy.sh` with:
- strict mode
- a `main` guard so the file can be sourced in tests
- placeholders for:
  - `require_root`
  - `detect_os`
  - `ensure_directories`
  - `main`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_deploy.sh skeleton`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add deploy.sh tests/test_deploy.sh
git commit -m "feat: add deploy script skeleton"
```

## Chunk 2: Generation Tests First

### Task 2: Add failing tests for compose and config generation

**Files:**
- Modify: `tests/test_deploy.sh`
- Test: `tests/test_deploy.sh`

- [ ] **Step 1: Write the failing test**

Add tests that source `deploy.sh`, redirect output into a temporary root, and assert:
- PostgreSQL compose is written to `docker/docker-postgres.yml`
- MySQL compose is written to `docker/docker-mysql.yml`
- MySQL config is written to `mysql/conf/my.cnf`
- MySQL config contains `bind-address=0.0.0.0`
- MySQL config contains `binlog_expire_logs_seconds=86400`
- Redis compose includes password handling when configured
- All generated paths live under the supplied data root

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_deploy.sh generation`
Expected: FAIL because generator functions and output files do not exist yet

- [ ] **Step 3: Write minimal implementation**

Add generator function placeholders to `deploy.sh`:
- `write_postgres_compose`
- `write_mysql_config`
- `write_mysql_compose`
- `write_rabbitmq_compose`
- `write_redis_compose`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_deploy.sh generation`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add deploy.sh tests/test_deploy.sh
git commit -m "test: cover deployment file generation"
```

## Chunk 3: Interactive Service Implementation

### Task 3: Implement prompts, defaults, and file generation

**Files:**
- Modify: `deploy.sh`
- Test: `tests/test_deploy.sh`

- [ ] **Step 1: Write the failing test**

Add tests for helper functions covering:
- default-value prompt fallback
- selection parsing for multiple services
- compose files using fixed paths under the configurable data root
- MySQL client detection helper returning failure when client is absent

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_deploy.sh helpers`
Expected: FAIL because helper behavior is incomplete

- [ ] **Step 3: Write minimal implementation**

Implement in `deploy.sh`:
- directory and path constants with override support
- prompt helpers with default values
- selection parser for PostgreSQL, MySQL, RabbitMQ, Redis, and Caddy
- per-service config collection
- file overwrite prompt flow
- package install helpers:
  - Docker install
  - Caddy install
  - optional MySQL client install
- start helpers using `docker compose -f <file> up -d`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_deploy.sh helpers`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add deploy.sh tests/test_deploy.sh
git commit -m "feat: implement interactive deployment flow"
```

## Chunk 4: End-to-End Verification

### Task 4: Verify syntax and generation behavior

**Files:**
- Modify: `deploy.sh`
- Modify: `tests/test_deploy.sh`
- Test: `tests/test_deploy.sh`

- [ ] **Step 1: Write the failing test**

Add a smoke test that simulates generation into a temporary directory and fails if:
- compose files are missing
- generated YAML omits required ports or mounts
- MySQL host remote-access settings are missing

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_deploy.sh smoke`
Expected: FAIL until the full script behavior satisfies the assertions

- [ ] **Step 3: Write minimal implementation**

Make any final targeted changes in `deploy.sh` needed to satisfy smoke coverage.

- [ ] **Step 4: Run test to verify it passes**

Run:
- `bash tests/test_deploy.sh`
- `bash -n deploy.sh`

Expected:
- all test groups PASS
- shell syntax check exits 0

- [ ] **Step 5: Commit**

```bash
git add deploy.sh tests/test_deploy.sh
git commit -m "test: verify deployment script behavior"
```
