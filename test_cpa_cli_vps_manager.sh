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
export CPA_CLI_MANAGER_SKIP_SELF_UPDATE=1
export PATH="$TMP_ROOT/bin:$PATH"
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/state"

cat > "$TMP_ROOT/bin/systemctl" <<'SH'
#!/usr/bin/env bash
echo "systemctl $*" >> "${CPA_CLI_MANAGER_TEST_ROOT:?}/state/actions"
[[ "${1:-}" == "is-active" ]] && exit 0
exit 0
SH

cat > "$TMP_ROOT/bin/ufw" <<'SH'
#!/usr/bin/env bash
echo "ufw $*" >> "${CPA_CLI_MANAGER_TEST_ROOT:?}/state/actions"
exit 0
SH

cat > "$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
STATE="${CPA_CLI_MANAGER_TEST_ROOT:?}/state"
echo "curl $*" >> "$STATE/actions"
for arg in "$@"; do
  [[ "$arg" == "https://api.ipify.org" ]] && { printf '198.51.100.10'; exit 0; }
done
exit 0
SH

cat > "$TMP_ROOT/bin/getent" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == hosts ]]; then echo "198.51.100.10 ${2:-example.test}"; exit 0; fi
exit 1
SH

cat > "$TMP_ROOT/bin/nginx" <<'SH'
#!/usr/bin/env bash
STATE="${CPA_CLI_MANAGER_TEST_ROOT:?}/state"
echo "nginx $*" >> "$STATE/actions"
[[ -f "$STATE/nginx_fail" ]] && exit 1
exit 0
SH

cat > "$TMP_ROOT/bin/certbot" <<'SH'
#!/usr/bin/env bash
STATE="${CPA_CLI_MANAGER_TEST_ROOT:?}/state"
echo "certbot $*" >> "$STATE/actions"
[[ -f "$STATE/certbot_fail" ]] && exit 1
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
    if [[ -f "$STATE/cli_proxy_api_exists" && "$name" == "cli-proxy-api" ]]; then
      if [[ "$all" == 1 || -f "$STATE/cli_proxy_api_running" ]]; then echo cli-proxy-api; fi
    elif [[ -f "$STATE/cpa_usage_keeper_exists" && "$name" == "cpa-usage-keeper" ]]; then
      if [[ "$all" == 1 || -f "$STATE/cpa_usage_keeper_running" ]]; then echo cpa-usage-keeper; fi
    fi
    ;;
  network)
    sub="${1:-}"; shift || true
    case "$sub" in
      inspect) exit 0 ;;
      create) echo "network create $*" >> "$STATE/actions"; echo "$1"; exit 0 ;;
      connect) echo "network connect $*" >> "$STATE/actions"; exit 0 ;;
    esac
    ;;
  port)
    c="${1:-}"; p="${2:-}"
    if [[ "$c" == cli-proxy-api ]]; then
      if [[ -f "$STATE/cli_local_port" ]]; then
        [[ -z "$p" || "$p" == "8317/tcp" ]] && echo '8317/tcp -> 127.0.0.1:8317'
      else
        [[ -z "$p" || "$p" == "8317/tcp" ]] && echo '8317/tcp -> 0.0.0.0:8317'
      fi
    elif [[ "$c" == cpa-usage-keeper ]]; then
      [[ -z "$p" || "$p" == "8080/tcp" ]] && echo '8080/tcp -> 127.0.0.1:8080'
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
        cli-proxy-api)
          if [[ -f "$STATE/cli_local_port" ]]; then printf '127.0.0.1|8317|8317/tcp\n'; else printf '|8317|8317/tcp\n'; fi ;;
        cpa-usage-keeper) printf '127.0.0.1|8080|8080/tcp\n' ;;
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
      if [[ "$c" == cpa-usage-keeper ]]; then printf 'LOGIN_PASSWORD=login\nCPA_MANAGEMENT_KEY=mgmt\nCPA_PUBLIC_URL=https://old.example\n'; fi
    fi
    ;;
  pull) echo "pull $1" >> "$STATE/actions" ;;
  stop) rm -f "$STATE/${1//-/_}_running"; echo "stop $1" >> "$STATE/actions" ;;
  rm) rm -f "$STATE/${1//-/_}_exists"; echo "rm $1" >> "$STATE/actions" ;;
  run)
    echo "run $*" >> "$STATE/actions"
    name=""; envfile=""; ports=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name) name="$2"; shift 2;;
        --env-file) envfile="$2"; shift 2;;
        -p) ports+=" $2"; shift 2;;
        *) shift;;
      esac
    done
    [[ -n "$envfile" && -f "$envfile" ]] && cp "$envfile" "$STATE/last-env-file"
    [[ "$name" == cli-proxy-api && "$ports" == *'127.0.0.1:8317:8317'* ]] && touch "$STATE/cli_local_port"
    [[ "$name" == cli-proxy-api && "$ports" == *'8317:8317'* && "$ports" != *'127.0.0.1:8317:8317'* ]] && rm -f "$STATE/cli_local_port"
    [[ -n "$name" ]] && touch "$STATE/${name//-/_}_exists" "$STATE/${name//-/_}_running"
    echo mock-container-id
    ;;
  exec) echo "docker exec $*" >> "$STATE/actions"; exit 0 ;;
  *) echo "mock docker unsupported: $cmd $*" >&2; exit 0;;
esac
SH
chmod +x "$TMP_ROOT/bin/"*

source "$SCRIPT"
fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }
actions(){ [[ -f "$TMP_ROOT/state/actions" ]] && cat "$TMP_ROOT/state/actions" || true; }
clear_actions(){ : > "$TMP_ROOT/state/actions"; }
reset_runtime(){ rm -f "$TMP_ROOT/state/actions" "$TMP_ROOT/state/last-env-file" "$TMP_ROOT/state/cli_proxy_api_exists" "$TMP_ROOT/state/cli_proxy_api_running" "$TMP_ROOT/state/cpa_usage_keeper_exists" "$TMP_ROOT/state/cpa_usage_keeper_running" "$TMP_ROOT/state/cli_local_port" "$TMP_ROOT/state/nginx_fail" "$TMP_ROOT/state/certbot_fail"; }

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
reset_runtime; touch "$TMP_ROOT/state/cli_proxy_api_exists" "$TMP_ROOT/state/cli_proxy_api_running"
mapfile -t specs < <(container_port_specs cli-proxy-api)
[[ "${specs[0]:-}" == '8317:8317/tcp' ]] || fail "bad port spec: ${specs[*]-}"
pass 'port spec empty HostIp'

# Test recreate_cli preserves mounts/ports and succeeds in mock without entering menu.
clear_actions
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

# Test install CLIProxyAPI happy path without touching the real host.
reset_runtime
install_cli_proxy_api <<< $'install-secret\ninstall-secret\nY\n' >/tmp/install-cli.out
run_line="$(grep '^run ' "$TMP_ROOT/state/actions" | tail -1)"
[[ "$run_line" == *'--name cli-proxy-api'* ]] || fail "install cli did not run container: $run_line"
[[ "$run_line" == *'-p 8317:8317'* ]] || fail "install cli missing public port: $run_line"
[[ "$run_line" == *'/CLIProxyAPI/config.yaml:/CLIProxyAPI/config.yaml'* ]] || fail "install cli missing config mount: $run_line"
grep -q '^ufw allow 8317/tcp$' "$TMP_ROOT/state/actions" || fail 'install cli did not open firewall'
pass 'install_cli_proxy_api happy path'

# Test install keeper happy path and that env-file is populated but removed after docker run.
reset_runtime; touch "$TMP_ROOT/state/cli_proxy_api_exists" "$TMP_ROOT/state/cli_proxy_api_running"
install_cpa_usage_keeper <<< $'keeper-login\nkeeper-login\nmgmt-key\nmgmt-key\nY\n' >/tmp/install-keeper.out
run_line="$(grep '^run ' "$TMP_ROOT/state/actions" | tail -1)"
[[ "$run_line" == *'--name cpa-usage-keeper'* ]] || fail "install keeper did not run container: $run_line"
[[ "$run_line" == *'-p 127.0.0.1:8080:8080'* ]] || fail "install keeper missing local port: $run_line"
[[ -f "$TMP_ROOT/state/last-env-file" ]] || fail 'install keeper env file was not passed to docker'
grep -q '^LOGIN_PASSWORD=keeper-login$' "$TMP_ROOT/state/last-env-file" || fail 'keeper env missing login'
grep -q '^CPA_MANAGEMENT_KEY=mgmt-key$' "$TMP_ROOT/state/last-env-file" || fail 'keeper env missing management key'
pass 'install_cpa_usage_keeper happy path'

# Test upgrade both keep-password path preserves both services.
reset_runtime; touch "$TMP_ROOT/state/cli_proxy_api_exists" "$TMP_ROOT/state/cli_proxy_api_running" "$TMP_ROOT/state/cpa_usage_keeper_exists" "$TMP_ROOT/state/cpa_usage_keeper_running"
ensure_cli_config 'new-secret'
upgrade_both <<< $'1\nY\n' >/tmp/upgrade-both.out
[[ "$(grep -c '^run ' "$TMP_ROOT/state/actions")" -eq 2 ]] || fail "upgrade both should recreate two containers: $(actions)"
grep -q 'run .*--name cli-proxy-api' "$TMP_ROOT/state/actions" || fail 'upgrade both did not recreate cli'
grep -q 'run .*--name cpa-usage-keeper' "$TMP_ROOT/state/actions" || fail 'upgrade both did not recreate keeper'
pass 'upgrade_both keep path'

# Test uninstall default cancel is non-destructive.
reset_runtime; touch "$TMP_ROOT/state/cli_proxy_api_exists" "$TMP_ROOT/state/cli_proxy_api_running"
uninstall_container "$CLI_CONTAINER" "CLIProxyAPI" "$CLI_DIR" <<< $'\n' >/tmp/uninstall-cancel.out
actions | grep -q '^stop cli-proxy-api' && fail 'uninstall default cancel stopped container'
actions | grep -q '^rm cli-proxy-api' && fail 'uninstall default cancel removed container'
pass 'uninstall cancel is safe'

# Test allow IP+port cancel is non-destructive.
reset_runtime; touch "$TMP_ROOT/state/cli_proxy_api_exists" "$TMP_ROOT/state/cli_proxy_api_running"
allow_ip_port <<< $'\n' >/tmp/allow-cancel.out
actions | grep -q '^run ' && fail 'allow cancel recreated container'
actions | grep -q '^ufw allow 8317/tcp' && fail 'allow cancel opened firewall'
pass 'allow_ip_port cancel is safe'

# Test forbid IP+port converts public binding to local binding and closes firewall.
reset_runtime; touch "$TMP_ROOT/state/cli_proxy_api_exists" "$TMP_ROOT/state/cli_proxy_api_running"
ensure_cli_config 'new-secret'
forbid_ip_port <<< $'Y\n' >/tmp/forbid.out
run_line="$(grep '^run ' "$TMP_ROOT/state/actions" | tail -1)"
[[ "$run_line" == *'-p 127.0.0.1:8317:8317'* ]] || fail "forbid did not bind CLI locally: $run_line"
grep -q '^ufw delete allow 8317/tcp$' "$TMP_ROOT/state/actions" || fail 'forbid did not close firewall'
pass 'forbid_ip_port localizes port'

# Test nginx conf writer for combined HTTP mode.
reset_runtime
write_nginx_conf 'proxy.example.test' both '127.0.0.1:8317' '127.0.0.1:8080'
conf="$TMP_ROOT/etc/nginx/conf.d/cpa-cli-proxy.conf"
grep -q 'server_name proxy.example.test;' "$conf" || fail 'nginx conf missing server_name'
grep -q 'proxy_pass http://127.0.0.1:8317;' "$conf" || fail 'nginx conf missing cli upstream'
grep -q 'proxy_pass http://127.0.0.1:8080/cpa/;' "$conf" || fail 'nginx conf missing keeper upstream'
! grep -q 'listen 443 ssl' "$conf" || fail 'HTTP-only nginx conf unexpectedly contains 443'
pass 'write_nginx_conf both HTTP mode'

# Test nginx conf writer keeps explicit HTTPS server block when requested.
reset_runtime
write_nginx_conf 'proxy.example.test' both '127.0.0.1:8317' '127.0.0.1:8080' https
conf="$TMP_ROOT/etc/nginx/conf.d/cpa-cli-proxy.conf"
grep -q 'listen 443 ssl http2;' "$conf" || fail 'HTTPS nginx conf missing listen 443'
grep -q 'ssl_certificate /etc/letsencrypt/live/proxy.example.test/fullchain.pem;' "$conf" || fail 'HTTPS nginx conf missing certificate path'
grep -q 'ssl_certificate_key /etc/letsencrypt/live/proxy.example.test/privkey.pem;' "$conf" || fail 'HTTPS nginx conf missing private key path'
grep -q 'proxy_pass http://127.0.0.1:8317;' "$conf" || fail 'HTTPS nginx conf missing cli upstream'
grep -q 'proxy_pass http://127.0.0.1:8080/cpa/;' "$conf" || fail 'HTTPS nginx conf missing keeper upstream'
pass 'write_nginx_conf both HTTPS mode'

# Test successful public access writes explicit HTTPS 443 config after certbot.
reset_runtime; touch "$TMP_ROOT/state/cli_proxy_api_exists" "$TMP_ROOT/state/cli_proxy_api_running" "$TMP_ROOT/state/cpa_usage_keeper_exists" "$TMP_ROOT/state/cpa_usage_keeper_running"
configure_public_access both <<< $'proxy.example.test\nY\n\n' >/tmp/public-success.out
conf="$TMP_ROOT/etc/nginx/conf.d/cpa-cli-proxy.conf"
grep -q 'listen 443 ssl http2;' "$conf" || fail 'public access success did not persist listen 443'
grep -q 'ssl_certificate /etc/letsencrypt/live/proxy.example.test/fullchain.pem;' "$conf" || fail 'public access success missing certificate path'
grep -q 'proxy_pass http://127.0.0.1:8317;' "$conf" || fail 'public access success missing cli upstream'
grep -q 'proxy_pass http://127.0.0.1:8080/cpa/;' "$conf" || fail 'public access success missing keeper upstream'
grep -q 'HTTPS 证书申请成功，已写入 443 反代配置' /tmp/public-success.out || fail 'public access success did not report HTTPS config write'
pass 'public access success writes persistent HTTPS config'

# Test configure_public_access invalid domain stops before nginx/certbot.
reset_runtime; touch "$TMP_ROOT/state/cli_proxy_api_exists" "$TMP_ROOT/state/cli_proxy_api_running"
configure_public_access cli <<< $'bad_domain\n' >/tmp/public-invalid.out || true
actions | grep -q '^nginx ' && fail 'invalid domain still touched nginx'
actions | grep -q '^certbot ' && fail 'invalid domain still touched certbot'
pass 'public access invalid domain safe'

# Test nginx -t failure restores existing config and does not run certbot.
reset_runtime; touch "$TMP_ROOT/state/cli_proxy_api_exists" "$TMP_ROOT/state/cli_proxy_api_running" "$TMP_ROOT/state/nginx_fail"
mkdir -p "$TMP_ROOT/etc/nginx/conf.d"
echo 'old-config' > "$TMP_ROOT/etc/nginx/conf.d/cpa-cli-proxy.conf"
configure_public_access cli <<< $'proxy.example.test\nY\n' >/tmp/public-nginx-fail.out || true
[[ "$(cat "$TMP_ROOT/etc/nginx/conf.d/cpa-cli-proxy.conf")" == 'old-config' ]] || fail 'nginx failure did not restore old config'
actions | grep -q '^certbot ' && fail 'nginx failure still ran certbot'
pass 'public access restores on nginx failure'

echo 'ALL_TESTS_PASS'
