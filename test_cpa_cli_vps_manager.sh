#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd)"
SCRIPT="$SCRIPT_DIR/cpa_cli_vps_manager.sh"
TMP_ROOT="$(mktemp -d)"
cleanup(){ rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
export CPA_CLI_MANAGER_TEST_EUID=0
export CPA_CLI_MANAGER_TEST_ROOT="$TMP_ROOT"
export CPA_CLI_MANAGER_SOURCE_ONLY=1
export PATH="$TMP_ROOT/bin:$PATH"
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/state"
cat > "$TMP_ROOT/bin/systemctl" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "is-active" ]] && exit 0
exit 0
SH
cat > "$TMP_ROOT/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
STATE="${CPA_CLI_MANAGER_TEST_ROOT:?}/state"
cmd="${1:-}"; shift || true
case "$cmd" in
  info) exit 0 ;;
  ps)
    all=0; name=""; fmt=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -a) all=1; shift;;
        --filter) name="${2#name=}"; shift 2;;
        --format) fmt="$2"; shift 2;;
        *) shift;;
      esac
    done
    if [[ -f "$STATE/cli_exists" && "$name" == "cli-proxy-api" ]]; then
      if [[ "$fmt" == *'{{.Names}}'* ]]; then echo cli-proxy-api; else echo cli-proxy-api; fi
    elif [[ -f "$STATE/keeper_exists" && "$name" == "cpa-usage-keeper" ]]; then
      if [[ "$fmt" == *'{{.Names}}'* ]]; then echo cpa-usage-keeper; else echo cpa-usage-keeper; fi
    fi
    ;;
  network)
    sub="${1:-}"; shift || true
    if [[ "$sub" == inspect ]]; then exit 0; elif [[ "$sub" == create ]]; then echo "$1"; exit 0; fi
    ;;
  port)
    c="${1:-}"; p="${2:-}"
    if [[ "$c" == cli-proxy-api ]]; then
      if [[ -z "$p" || "$p" == "8317/tcp" ]]; then echo '8317/tcp -> 0.0.0.0:8317'; fi
    elif [[ "$c" == cpa-usage-keeper ]]; then
      if [[ -z "$p" || "$p" == "8080/tcp" ]]; then echo '8080/tcp -> 127.0.0.1:8080'; fi
    fi
    ;;
  inspect)
    c=""; fmt=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --format ]]; then fmt="$2"; shift 2; else c="$1"; shift; fi
    done
    if [[ "$fmt" == *'HostConfig.RestartPolicy.Name'* ]]; then echo unless-stopped
    elif [[ "$fmt" == *'NetworkSettings.Networks'* ]]; then echo cliproxyapi_default
    elif [[ "$fmt" == *'HostConfig.PortBindings'* ]]; then
      case "$c" in
        cli-proxy-api) printf '|8317|8317/tcp\n' ;;
        cpa-usage-keeper) printf '127.0.0.1|8080|8080/tcp\n' ;;
        *) if [[ -f "$STATE/cli_proxy_api_exists" ]]; then printf '|8317|8317/tcp\n'; else printf '127.0.0.1|8080|8080/tcp\n'; fi ;;
      esac
    elif [[ "$fmt" == *'.Mounts'* ]]; then
      if [[ "$c" == cli-proxy-api ]]; then
        printf '%s/home/docker/CLIProxyAPI/config.yaml|/CLIProxyAPI/config.yaml\n' "${CPA_CLI_MANAGER_TEST_ROOT}"
        printf '%s/home/docker/CLIProxyAPI/auths|/root/.cli-proxy-api\n' "${CPA_CLI_MANAGER_TEST_ROOT}"
        printf '%s/home/docker/CLIProxyAPI/logs|/CLIProxyAPI/logs\n' "${CPA_CLI_MANAGER_TEST_ROOT}"
      else
        printf '%s/home/docker/cpa-usage-keeper/data|/data\n' "${CPA_CLI_MANAGER_TEST_ROOT}"
      fi
    elif [[ "$fmt" == *'.Config.Env'* ]]; then
      if [[ "$c" == cpa-usage-keeper ]]; then printf 'LOGIN_PASSWORD=login\nCPA_MANAGEMENT_KEY=mgmt\nCPA_PUBLIC_URL=https://example.test\n'; fi
    fi
    ;;
  pull) echo pull "$1" >> "$STATE/actions" ;;
  stop) rm -f "$STATE/${1//-/_}_running"; echo stop "$1" >> "$STATE/actions" ;;
  rm) rm -f "$STATE/${1//-/_}_exists"; echo rm "$1" >> "$STATE/actions" ;;
  run)
    echo "run $*" >> "$STATE/actions"
    name=""
    while [[ $# -gt 0 ]]; do [[ "$1" == --name ]] && { name="$2"; shift 2; } || shift; done
    [[ -n "$name" ]] && touch "$STATE/${name//-/_}_exists" "$STATE/${name//-/_}_running"
    echo mock-container-id
    ;;
  exec) exit 0 ;;
  *) echo "mock docker unsupported: $cmd $*" >&2; exit 0;;
esac
SH
chmod +x "$TMP_ROOT/bin/systemctl" "$TMP_ROOT/bin/docker"
source "$SCRIPT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }

# Test config patching preserves single blocks and strips duplicate remote-management children after comments.
mkdir -p "$TMP_ROOT/home/docker/CLIProxyAPI"
cat > "$TMP_ROOT/home/docker/CLIProxyAPI/config.yaml" <<'YAML'
remote-management:
  allow-remote: false
# comment in block
  secret-key: old
usage-statistics-enabled: false
port: 1234
YAML
ensure_cli_config 'new-secret'
grep -q '^port: 8317$' "$TMP_ROOT/home/docker/CLIProxyAPI/config.yaml" || fail 'port not patched'
[[ "$(grep -c '^remote-management:$' "$TMP_ROOT/home/docker/CLIProxyAPI/config.yaml")" -eq 1 ]] || fail 'duplicate remote-management'
[[ "$(grep -c 'secret-key:' "$TMP_ROOT/home/docker/CLIProxyAPI/config.yaml")" -eq 1 ]] || fail 'duplicate secret-key'
grep -q '^usage-statistics-enabled: true$' "$TMP_ROOT/home/docker/CLIProxyAPI/config.yaml" || fail 'usage not enabled'
read_cli_secret >/tmp/secret.out
[[ "$(cat /tmp/secret.out)" == 'new-secret' ]] || fail 'read_cli_secret failed'
pass 'config patch/read secret'

# Test port rendering: empty HostIp must become 8317:8317/tcp, not :8317:8317/tcp or space-polluted form.
touch "$TMP_ROOT/state/cli_proxy_api_exists" "$TMP_ROOT/state/cli_proxy_api_running"
mapfile -t specs < <(container_port_specs cli-proxy-api)
[[ "${specs[0]:-}" == '8317:8317/tcp' ]] || fail "bad port spec: ${specs[*]-}"
pass 'port spec empty HostIp'

# Test recreate_cli preserves mounts/ports and succeeds in mock without entering menu.
recreate_cli 'new-secret' preserve >/tmp/recreate.out
run_line="$(grep '^run ' "$TMP_ROOT/state/actions" | tail -1)"
[[ "$run_line" == *'-p 8317:8317/tcp'* ]] || fail "recreate missing port: $run_line"
[[ "$run_line" != *'-p :'* ]] || fail "recreate generated invalid empty IP: $run_line"
[[ "$run_line" == *'/CLIProxyAPI/config.yaml'* ]] || fail "recreate missing config mount: $run_line"
pass 'recreate_cli preserve'

# Test keeper env preservation path.
touch "$TMP_ROOT/state/cpa_usage_keeper_exists" "$TMP_ROOT/state/cpa_usage_keeper_running"
mapfile -t kspecs < <(container_port_specs cpa-usage-keeper)
[[ "${kspecs[0]:-}" == '127.0.0.1:8080:8080/tcp' ]] || fail "bad keeper port spec: ${kspecs[*]-}"
pass 'keeper port spec'

echo 'ALL_TESTS_PASS'
