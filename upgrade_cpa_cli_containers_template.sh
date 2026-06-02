#!/usr/bin/env bash
# Template: upgrade CLIProxyAPI + cpa-usage-keeper containers on a VPS.
# Fill placeholders on the VPS; do not paste real secrets into chat.
set -Eeuo pipefail

APPLY=0
YES=0
CLI_CONTAINER="${CLI_CONTAINER:-cli-proxy-api}"
KEEPER_CONTAINER="${KEEPER_CONTAINER:-cpa-usage-keeper}"
CLI_IMAGE="${CLI_IMAGE:-eceasy/cli-proxy-api:latest}"
KEEPER_IMAGE="${KEEPER_IMAGE:-ghcr.io/willxup/cpa-usage-keeper:latest}"
CLI_MANAGEMENT_KEY="${CLI_MANAGEMENT_KEY:-REPLACE_WITH_CPA_MANAGEMENT_KEY}"
KEEPER_LOGIN_PASSWORD="${KEEPER_LOGIN_PASSWORD:-REPLACE_WITH_KEEPER_LOGIN_PASSWORD}"
KEEPER_HOST_PORT="${KEEPER_HOST_PORT:-8080}"
KEEPER_APP_BASE_PATH="${KEEPER_APP_BASE_PATH:-/cpa}"
CPA_PUBLIC_URL="${CPA_PUBLIC_URL:-}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/cpa-cli-upgrade-backups}"

usage(){ cat <<'USAGE'
Usage: sudo bash upgrade_cpa_cli_containers_template.sh [--dry-run|--apply] [-y]
Environment overrides: CLI_CONTAINER, KEEPER_CONTAINER, CLI_IMAGE, KEEPER_IMAGE,
CLI_MANAGEMENT_KEY, KEEPER_LOGIN_PASSWORD, KEEPER_HOST_PORT,
KEEPER_APP_BASE_PATH, CPA_PUBLIC_URL, BACKUP_ROOT.

The script discovers the current Docker networks attached to each existing
container before recreation, then restores each container to its own previous
network set after upgrade. It does not hard-code cliproxyapi_default/hermes-net.
USAGE
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) APPLY=0; shift;;
    --apply) APPLY=1; shift;;
    -y|--yes) YES=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $1" >&2; usage; exit 2;;
  esac
done

log(){ printf '\n[%s] %s\n' "$(date '+%F %T %z')" "$*"; }
redact(){ sed -E 's/(PASSWORD|KEY|TOKEN|SECRET)=([^[:space:]]+)/\1=[REDACTED]/g; s/(secret-key: ).*/\1[REDACTED]/g'; }
run(){
  printf '+ %s\n' "$*" | redact
  if [[ "$APPLY" == 1 ]]; then
    eval "$@"
  fi
}
exists_container(){ docker inspect "$1" >/dev/null 2>&1; }
exists_network(){ docker network inspect "$1" >/dev/null 2>&1; }
container_networks(){ docker inspect "$1" --format '{{range $n,$v := .NetworkSettings.Networks}}{{println $n}}{{end}}'; }
join_by_comma(){ local IFS=,; echo "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
[[ "$CLI_MANAGEMENT_KEY" != REPLACE_WITH_* && "$KEEPER_LOGIN_PASSWORD" != REPLACE_WITH_* ]] || { echo "fill CLI_MANAGEMENT_KEY and KEEPER_LOGIN_PASSWORD first" >&2; exit 1; }
exists_container "$CLI_CONTAINER" || { echo "CLI container not found: $CLI_CONTAINER" >&2; exit 1; }

mapfile -t CLI_NETWORKS < <(container_networks "$CLI_CONTAINER")
[[ ${#CLI_NETWORKS[@]} -gt 0 ]] || { echo "no Docker networks found on $CLI_CONTAINER" >&2; exit 1; }
CLI_PRIMARY_NETWORK="${CLI_NETWORKS[0]}"

KEEPER_EXISTS=0
KEEPER_NETWORKS=()
if exists_container "$KEEPER_CONTAINER"; then
  KEEPER_EXISTS=1
  mapfile -t KEEPER_NETWORKS < <(container_networks "$KEEPER_CONTAINER")
fi
if [[ ${#KEEPER_NETWORKS[@]} -eq 0 ]]; then
  # New/missing keeper fallback: attach to CLI's networks so Docker DNS for
  # $CLI_CONTAINER works, while still avoiding a hard-coded network name.
  KEEPER_NETWORKS=("${CLI_NETWORKS[@]}")
fi
KEEPER_PRIMARY_NETWORK="${KEEPER_NETWORKS[0]}"

log "preserve networks: $CLI_CONTAINER=[$(join_by_comma "${CLI_NETWORKS[@]}")] $KEEPER_CONTAINER=[$(join_by_comma "${KEEPER_NETWORKS[@]}")]"

if [[ "$APPLY" == 1 ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="$BACKUP_ROOT/$TS"
  mkdir -p "$BACKUP_DIR"
fi
log "mode=$([[ $APPLY == 1 ]] && echo APPLY || echo DRY-RUN), backup=${BACKUP_DIR:-<none>}"

CLI_CONFIG_SRC="$(docker inspect "$CLI_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/CLIProxyAPI/config.yaml"}}{{.Source}}{{end}}{{end}}')"
CLI_AUTHS_SRC="$(docker inspect "$CLI_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/root/.cli-proxy-api"}}{{.Source}}{{end}}{{end}}')"
CLI_LOGS_SRC="$(docker inspect "$CLI_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/CLIProxyAPI/logs"}}{{.Source}}{{end}}{{end}}')"
: "${CLI_CONFIG_SRC:=/home/docker/CLIProxyAPI/config.yaml}"
: "${CLI_AUTHS_SRC:=/home/docker/CLIProxyAPI/auths}"
: "${CLI_LOGS_SRC:=/home/docker/CLIProxyAPI/logs}"
[[ -f "$CLI_CONFIG_SRC" ]] || { echo "config not found: $CLI_CONFIG_SRC" >&2; exit 1; }

if [[ "$APPLY" == 1 ]]; then
  docker inspect "$CLI_CONTAINER" > "$BACKUP_DIR/${CLI_CONTAINER}.inspect.json"
  exists_container "$KEEPER_CONTAINER" && docker inspect "$KEEPER_CONTAINER" > "$BACKUP_DIR/${KEEPER_CONTAINER}.inspect.json" || true
  cp -a "$CLI_CONFIG_SRC" "$BACKUP_DIR/config.yaml.bak"
  python3 - "$CLI_CONFIG_SRC" "$CLI_MANAGEMENT_KEY" <<'PY'
import sys,re,pathlib
p=pathlib.Path(sys.argv[1]); key=sys.argv[2]; s=p.read_text()
lines=s.splitlines()
rm_idx=next((i for i,l in enumerate(lines) if re.match(r'^remote-management:\s*$', l)), None)
if rm_idx is None:
    lines=['remote-management:', '  allow-remote: true', f'  secret-key: "{key}"', ''] + lines
else:
    end=len(lines)
    for i in range(rm_idx+1, len(lines)):
        if re.match(r'^[^\s#][^:]*:\s*$', lines[i]):
            end=i
            break
    sec=lines[rm_idx+1:end]
    def set_or_add(sec, name, value):
        pat=re.compile(rf'^(\s*{re.escape(name)}:\s*).*$')
        for j,l in enumerate(sec):
            if pat.match(l):
                sec[j]=pat.sub(rf'\1{value}', l)
                return sec
        sec.append(f'  {name}: {value}')
        return sec
    sec=set_or_add(sec, 'allow-remote', 'true')
    sec=set_or_add(sec, 'secret-key', f'"{key}"')
    lines=lines[:rm_idx+1]+sec+lines[end:]
for i,l in enumerate(lines):
    if re.match(r'^usage-statistics-enabled:\s*', l):
        lines[i]='usage-statistics-enabled: true'
        break
else:
    lines.append('usage-statistics-enabled: true')
p.write_text('\n'.join(lines)+'\n')
PY
else
  echo "+ backup inspect/config and patch remote-management + usage-statistics-enabled"
fi

run "docker pull '$CLI_IMAGE'"
run "docker pull '$KEEPER_IMAGE'"
for n in "${CLI_NETWORKS[@]}" "${KEEPER_NETWORKS[@]}"; do
  exists_network "$n" || { echo "previous Docker network no longer exists: $n" >&2; exit 1; }
done

mapfile -t CLI_PORT_ARGS < <(docker inspect "$CLI_CONTAINER" --format '{{range $p,$b:=.HostConfig.PortBindings}}{{range $b}}{{printf "-p %s:%s:%s\n" .HostIp .HostPort $p}}{{end}}{{end}}' | sed 's/-p :/-p 127.0.0.1:/')
[[ ${#CLI_PORT_ARGS[@]} -gt 0 ]] || CLI_PORT_ARGS=(-p 127.0.0.1:8317:8317/tcp -p 127.0.0.1:8085:8085/tcp -p 127.0.0.1:1455:1455/tcp -p 127.0.0.1:54545:54545/tcp -p 127.0.0.1:51121:51121/tcp -p 127.0.0.1:11451:11451/tcp)

KEEPER_DATA_SRC="/home/docker/cpa-usage-keeper/data"
if exists_container "$KEEPER_CONTAINER"; then
  old="$(docker inspect "$KEEPER_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')"; [[ -n "$old" ]] && KEEPER_DATA_SRC="$old"
fi
run "mkdir -p '$KEEPER_DATA_SRC'"

[[ "$APPLY" == 0 || "$YES" == 1 ]] || { read -r -p "Type UPGRADE to recreate containers: " a; [[ "$a" == UPGRADE ]]; }
run "docker stop '$CLI_CONTAINER' >/dev/null 2>&1 || true; docker rm '$CLI_CONTAINER' >/dev/null 2>&1 || true"
run "docker run -d --name '$CLI_CONTAINER' --restart unless-stopped --network '$CLI_PRIMARY_NETWORK' ${CLI_PORT_ARGS[*]} -v '$CLI_CONFIG_SRC:/CLIProxyAPI/config.yaml' -v '$CLI_AUTHS_SRC:/root/.cli-proxy-api' -v '$CLI_LOGS_SRC:/CLIProxyAPI/logs' '$CLI_IMAGE'"
for n in "${CLI_NETWORKS[@]}"; do
  [[ "$n" != "$CLI_PRIMARY_NETWORK" ]] && run "docker network connect '$n' '$CLI_CONTAINER' >/dev/null 2>&1 || true"
done

KEEPER_ENV="${BACKUP_DIR:-$BACKUP_ROOT/DRY-RUN}/keeper.env"
if [[ "$APPLY" == 1 ]]; then
  cat > "$KEEPER_ENV" <<EOF
TZ=Asia/Shanghai
CPA_BASE_URL=http://$CLI_CONTAINER:8317
CPA_MANAGEMENT_KEY=$CLI_MANAGEMENT_KEY
REDIS_QUEUE_ADDR=$CLI_CONTAINER:8317
AUTH_ENABLED=true
LOGIN_PASSWORD=$KEEPER_LOGIN_PASSWORD
APP_BASE_PATH=$KEEPER_APP_BASE_PATH
CPA_PUBLIC_URL=$CPA_PUBLIC_URL
WORK_DIR=/data
EOF
  chmod 600 "$KEEPER_ENV"
else
  echo "+ write keeper.env with secrets redacted"
fi
run "docker stop '$KEEPER_CONTAINER' >/dev/null 2>&1 || true; docker rm '$KEEPER_CONTAINER' >/dev/null 2>&1 || true"
run "docker run -d --name '$KEEPER_CONTAINER' --restart unless-stopped --network '$KEEPER_PRIMARY_NETWORK' -p 127.0.0.1:$KEEPER_HOST_PORT:8080/tcp --env-file '$KEEPER_ENV' -v '$KEEPER_DATA_SRC:/data' '$KEEPER_IMAGE'"
for n in "${KEEPER_NETWORKS[@]}"; do
  [[ "$n" != "$KEEPER_PRIMARY_NETWORK" ]] && run "docker network connect '$n' '$KEEPER_CONTAINER' >/dev/null 2>&1 || true"
done

if [[ "$APPLY" == 1 ]]; then
  sleep 8
  docker ps --filter "name=$CLI_CONTAINER" --filter "name=$KEEPER_CONTAINER" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  docker exec "$KEEPER_CONTAINER" sh -c "getent hosts '$CLI_CONTAINER'; (wget -qO- --timeout=5 http://'$CLI_CONTAINER':8317/ >/dev/null && echo HTTP_OK) || echo CHECK_MANUALLY" || true
  curl -sS -o /dev/null -w 'KEEPER_HTTP=%{http_code}\n' --max-time 8 "http://127.0.0.1:$KEEPER_HOST_PORT$KEEPER_APP_BASE_PATH/" || true
  docker logs --tail 40 "$CLI_CONTAINER" 2>&1 | redact || true
  docker logs --tail 60 "$KEEPER_CONTAINER" 2>&1 | redact || true
fi
log "done backup=${BACKUP_DIR:-<none>}"
