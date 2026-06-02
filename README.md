# CPA + CLIProxyAPI Docker container upgrade runbook

Use this when upgrading a VPS deployment that contains `cli-proxy-api` and `cpa-usage-keeper` containers.

## Upstream references checked

- CLIProxyAPI official repo: `router-for-me/CLIProxyAPI`
  - Official Compose image: `eceasy/cli-proxy-api:latest`
  - Compose uses `pull_policy: always`.
  - Official mounts: config file to `/CLIProxyAPI/config.yaml`, auth directory to `/root/.cli-proxy-api`, logs to `/CLIProxyAPI/logs`.
  - Official ports include `8317`, `8085`, `1455`, `54545`, `51121`, `11451`.
  - Management API is configured in `config.yaml` under `remote-management`; `secret-key` may be plaintext and is hashed on startup. Empty disables `/v0/management` routes.
  - Keeper requires `usage-statistics-enabled: true` in CLIProxyAPI config.
- CPA Usage Keeper official repo: `Willxup/cpa-usage-keeper`
  - Official/recommended Docker image: `ghcr.io/willxup/cpa-usage-keeper:latest`.
  - Recommended CPA+Keeper deployment is Docker Compose on the same Docker network.
  - Keeper server should call CPA with `CPA_BASE_URL=http://cli-proxy-api:8317` when both containers share a network.
  - Keeper Redis/RESP queue address should be `REDIS_QUEUE_ADDR=cli-proxy-api:8317` when using Docker DNS and the default CPA port.
  - Public deployments should enable `AUTH_ENABLED=true` and set `LOGIN_PASSWORD`; terminate HTTPS at reverse proxy unless using Keeper built-in TLS.

## Durable upgrade pattern

1. Start with a dry-run. Do not recreate containers until current config is inspected and masked.
2. Back up current `docker inspect` for both containers and the CLIProxyAPI config file.
3. Preserve existing CLIProxyAPI mounts and port bindings rather than replacing them with generic defaults.
4. Patch CLIProxyAPI config intentionally:
   - `remote-management.allow-remote: true` when Keeper must call management API over Docker network.
   - `remote-management.secret-key: <CPA_MANAGEMENT_KEY>` using the plaintext value provided for this deployment.
   - `usage-statistics-enabled: true` for Keeper usage ingestion.
5. Pull current images (`docker pull ...:latest`) before recreate. Do not assume `latest` changed; compare image IDs if deciding whether an upgrade is necessary.
6. Recreate `cli-proxy-api` first, then recreate `cpa-usage-keeper`.
7. Before recreation, query and preserve each container's existing Docker network set with `docker inspect ... .NetworkSettings.Networks`; after recreation, attach each container back to its own previous networks. Do **not** hard-code `cliproxyapi_default`, `hermes-net`, or any other network name in the upgrade template. If `cpa-usage-keeper` is missing/new, fall back to the CLI container's current network set so Docker DNS for `cli-proxy-api` still works.
8. Configure Keeper with Docker-internal service names, not public URLs:
   - `CPA_BASE_URL=http://cli-proxy-api:8317`
   - `REDIS_QUEUE_ADDR=cli-proxy-api:8317`
9. Keep credential semantics distinct:
   - `CPA_MANAGEMENT_KEY` is for Keeper -> CLIProxyAPI management API and Redis/RESP queue authentication.
   - `LOGIN_PASSWORD` is only Keeper Web UI login protection.
   - SSH/VPS password is a third credential and must not be reused implicitly.
10. Verify from inside Keeper:
    - Docker DNS resolves `cli-proxy-api`.
    - TCP/HTTP to `cli-proxy-api:8317` works.
11. Verify from the host/reverse proxy:
    - Keeper endpoint returns an HTTP status consistent with login protection (usually redirect/login/200/401/404 depending base path).
    - Logs for both containers show no startup or auth errors.

## CLIProxyAPI environment variable pitfall

CLIProxyAPI's official `docker-compose.yml` only declares one environment variable: `DEPLOY`. The management secret-key is **exclusively** configured via `config.yaml` under `remote-management.secret-key`. There is no `MANAGEMENT_PASSWORD` env var — setting `-e MANAGEMENT_PASSWORD=...` on the CLI container is silently ignored.

When writing upgrade scripts:
- **DO** patch `config.yaml` with `remote-management.secret-key` (this is the only way to set the management key).
- **DO NOT** pass `-e MANAGEMENT_PASSWORD=...` to the CLI container — it gives a false sense of configuration and has no effect.
- The CLI config patching must happen **before** container recreation since the new container reads config.yaml at startup.

## CPA Usage Keeper full env var reference

Official `.env.example` at `Willxup/cpa-usage-keeper` documents all env vars. Key ones for upgrade scripts:

| Env var | Required | Default | Notes |
|---|---|---|---|
| `CPA_BASE_URL` | yes | — | `http://cli-proxy-api:8317` in Docker |
| `CPA_MANAGEMENT_KEY` | yes | — | Keeper → CLI management auth |
| `REDIS_QUEUE_ADDR` | no | auto from CPA_BASE_URL | Explicit `cli-proxy-api:8317` when non-default port |
| `AUTH_ENABLED` | no | `false` | Set `true` for public deployments |
| `LOGIN_PASSWORD` | no | — | Required when AUTH_ENABLED=true |
| `AUTH_SESSION_TTL` | no | `168h` | |
| `APP_PORT` | no | `8080` | |
| `APP_BASE_PATH` | no | `/` | e.g. `/cpa` for subpath |
| `WORK_DIR` | no | `./data` (`/data` in Docker) | |
| `REQUEST_TIMEOUT` | no | `30s` | |
| `TLS_SKIP_VERIFY` | no | `false` | |
| `QUOTA_AUTO_REFRESH_ENABLED` | no | `false` | |
| `LOG_LEVEL` | no | `info` | |
| `LOG_FILE_ENABLED` | no | `true` | |
| `BACKUP_ENABLED` | no | `true` | |

## Script guidance

A sanitized reusable template exists at `scripts/upgrade_cpa_cli_containers_template.sh`. Before running it on a VPS:

1. Copy to the VPS as root, e.g. `/root/upgrade-cpa-cli-containers.sh`.
2. Fill the placeholder secrets locally on the VPS; do not paste secrets into chat.
3. `chmod 600 /root/upgrade-cpa-cli-containers.sh`.
4. Run dry-run first: `sudo bash /root/upgrade-cpa-cli-containers.sh --dry-run`.
5. Apply only after reviewing the dry-run: `sudo bash /root/upgrade-cpa-cli-containers.sh --apply -y`.

## Safety notes

- Do not print raw env files or `docker inspect` env output containing secrets. Redact `KEY`, `PASSWORD`, `TOKEN`, and `SECRET` values.
- Prefer binding public-sensitive container ports to `127.0.0.1` unless an existing deployment intentionally exposes them through firewall/reverse proxy.
- When multiple VPSs are involved, state the target IP/host before running commands and do not carry over previous VPS assumptions.

## Related references

- `references/cpa-cli-container-upgrade-script-hardening.md` — script hardening lessons and the direct SSH upgrade pattern (bypass full script transfer when it's cumbersome).
- `references/cpa-keeper-us-vps-topology-38.55.146.20.md` — US VPS container topology snapshot.
