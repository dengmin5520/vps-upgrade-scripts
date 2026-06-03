#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="cpa_cli_vps_manager.sh"
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd || pwd)"
SCRIPT_REPO="${CPA_CLI_MANAGER_SCRIPT_REPO:-$SCRIPT_DIR}"
CLI_CONTAINER="cli-proxy-api"
KEEPER_CONTAINER="cpa-usage-keeper"
DOCKER_NETWORK="cliproxyapi_default"
CLI_IMAGE="eceasy/cli-proxy-api:latest"
KEEPER_IMAGE="ghcr.io/willxup/cpa-usage-keeper:latest"
CLI_PORT="8317"
KEEPER_PORT="8080"
CLI_DIR="/home/docker/CLIProxyAPI"
CLI_CONFIG="$CLI_DIR/config.yaml"
KEEPER_DIR="/home/docker/cpa-usage-keeper"
NGINX_CONF="/etc/nginx/conf.d/cpa-cli-proxy.conf"

# Test hooks keep mock tests side-effect free.
effective_euid(){ [[ -n "${CPA_CLI_MANAGER_TEST_EUID:-}" ]] && printf '%s' "$CPA_CLI_MANAGER_TEST_EUID" || printf '%s' "$EUID"; }
root_path(){ local p="$1"; [[ -n "${CPA_CLI_MANAGER_TEST_ROOT:-}" ]] && printf '%s%s' "$CPA_CLI_MANAGER_TEST_ROOT" "$p" || printf '%s' "$p"; }
run(){ "$@"; }
log(){ printf '%s\n' "$*"; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }

require_root(){
  if [[ "$(effective_euid)" != "0" ]]; then
    printf '请使用 sudo 运行本脚本：\nsudo bash %s\n' "$SCRIPT_NAME"
    exit 1
  fi
}

confirm(){ local prompt="$1" ans; printf '%s' "$prompt"; read -r ans || ans=""; [[ "$ans" == "Y" || "$ans" == "y" ]]; }
read_secret_twice(){
  local prompt1="$1" prompt2="$2" varname="$3" a b
  printf '%s' "$prompt1"; IFS= read -r -s a || a=""; printf '\n'
  printf '%s' "$prompt2"; IFS= read -r -s b || b=""; printf '\n'
  if [[ -z "$a" ]]; then log "密码不能为空，已取消。"; return 1; fi
  if [[ "$a" != "$b" ]]; then log "两次输入的密码不一致，已取消。"; return 1; fi
  printf -v "$varname" '%s' "$a"
}
pause_return(){ [[ -t 0 ]] && read -r -p "按回车继续..." _ || true; }

DOCKER_CMD_STATUS="未安装"; DOCKER_SERVICE_STATUS="不可用"; DOCKER_ACCESS_STATUS="不可用"; DOCKER_AVAILABLE=0
NETWORK_STATUS="无法检测，Docker 不可用"; CLI_EXISTS=0; CLI_RUNNING=0; CLI_STATUS="无法检测，Docker 不可用"; CLI_PORTS=""
KEEPER_EXISTS=0; KEEPER_RUNNING=0; KEEPER_STATUS="无法检测，Docker 不可用"; KEEPER_PORTS=""
container_exists(){ docker ps -a --filter "name=$1" --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
container_running(){ docker ps --filter "name=$1" --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

detect_state(){
  DOCKER_CMD_STATUS="未安装"; DOCKER_SERVICE_STATUS="不可用"; DOCKER_ACCESS_STATUS="不可用"; DOCKER_AVAILABLE=0
  NETWORK_STATUS="无法检测，Docker 不可用"; CLI_EXISTS=0; CLI_RUNNING=0; CLI_STATUS="无法检测，Docker 不可用"; CLI_PORTS=""
  KEEPER_EXISTS=0; KEEPER_RUNNING=0; KEEPER_STATUS="无法检测，Docker 不可用"; KEEPER_PORTS=""
  if has_cmd docker; then
    DOCKER_CMD_STATUS="已安装"
    systemctl is-active docker >/dev/null 2>&1 && DOCKER_SERVICE_STATUS="运行中" || DOCKER_SERVICE_STATUS="未运行或无法检测"
    if docker info >/dev/null 2>&1; then DOCKER_ACCESS_STATUS="可用"; DOCKER_AVAILABLE=1; fi
  fi
  if [[ "$DOCKER_AVAILABLE" == 1 ]]; then
    docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 && NETWORK_STATUS="已存在" || NETWORK_STATUS="不存在"
    if container_exists "$CLI_CONTAINER"; then
      CLI_EXISTS=1; container_running "$CLI_CONTAINER" && { CLI_RUNNING=1; CLI_STATUS="运行中"; } || CLI_STATUS="已安装但未运行"
      CLI_PORTS="$(docker port "$CLI_CONTAINER" 2>/dev/null || true)"
    else CLI_STATUS="未安装"; fi
    if container_exists "$KEEPER_CONTAINER"; then
      KEEPER_EXISTS=1; container_running "$KEEPER_CONTAINER" && { KEEPER_RUNNING=1; KEEPER_STATUS="运行中"; } || KEEPER_STATUS="已安装但未运行"
      KEEPER_PORTS="$(docker port "$KEEPER_CONTAINER" 2>/dev/null || true)"
    else KEEPER_STATUS="未安装"; fi
  fi
}

print_state(){
  cat <<EOF
========================================
 当前 VPS 状态检测
========================================

Docker：
- 命令：$DOCKER_CMD_STATUS
- 服务：$DOCKER_SERVICE_STATUS
- 权限：$DOCKER_ACCESS_STATUS

Docker 网络：
- $DOCKER_NETWORK：$NETWORK_STATUS

容器：
- $CLI_CONTAINER：$CLI_STATUS
EOF
  [[ -n "$CLI_PORTS" ]] && printf '  端口：\n%s\n' "$(printf '%s\n' "$CLI_PORTS" | sed 's/^/  - /')"
  printf '\n- %s：%s\n' "$KEEPER_CONTAINER" "$KEEPER_STATUS"
  [[ -n "$KEEPER_PORTS" ]] && printf '  端口：\n%s\n' "$(printf '%s\n' "$KEEPER_PORTS" | sed 's/^/  - /')"
  printf '\n========================================\n'
}

ensure_cli_config(){
  local secret="$1" cfg; cfg="$(root_path "$CLI_CONFIG")"; mkdir -p "$(dirname "$cfg")"
  if [[ -z "$secret" ]]; then log "CLIProxyAPI 管理密码为空，拒绝写入配置。"; return 1; fi
  if [[ -f "$cfg" ]]; then cp "$cfg" "$cfg.bak-$(date +%Y%m%d%H%M%S)" || true; fi
  python3 -c '
import sys, pathlib, json, re
p=pathlib.Path(sys.argv[1]); secret=sys.stdin.read().rstrip("\n")
text=p.read_text() if p.exists() else ""
lines=text.splitlines()
quoted=json.dumps(secret, ensure_ascii=False)
out=[]; i=0; rm_done=False; usage_done=False; port_done=False

def top_level(line):
    return bool(line) and not line.startswith((" ", "\t"))

while i < len(lines):
    line=lines[i]
    if line.startswith("remote-management:"):
        if not rm_done:
            out += ["remote-management:", "  allow-remote: true", "  secret-key: "+quoted]
            rm_done=True
        i += 1
        # Skip the whole original remote-management block.  The upstream sample
        # may contain indented comments separated by blank lines; stopping on a
        # blank line leaves duplicate allow-remote / secret-key entries and makes
        # CLIProxyAPI fail YAML parsing.
        while i < len(lines):
            nxt=lines[i]
            if top_level(nxt):
                break
            i += 1
        continue
    if re.match(r"^usage-statistics-enabled\s*:", line):
        if not usage_done:
            out.append("usage-statistics-enabled: true")
            usage_done=True
        i += 1
        continue
    if re.match(r"^port\s*:", line):
        if not port_done:
            out.append("port: 8317")
            port_done=True
        i += 1
        continue
    out.append(line); i += 1
# Ensure port is always first for readability
if not port_done:
    out.insert(0, "port: 8317")
if not rm_done: out += ["remote-management:", "  allow-remote: true", "  secret-key: "+quoted]
if not usage_done: out.append("usage-statistics-enabled: true")
p.write_text("\n".join(out).rstrip()+"\n")
' "$cfg" <<< "$secret"
  chmod 600 "$cfg" || true
}
read_cli_secret(){
  local cfg; cfg="$(root_path "$CLI_CONFIG")"
  [[ -f "$cfg" ]] || return 1
  python3 - "$cfg" <<'PY'
import sys,re
s=open(sys.argv[1]).read()
m=re.search(r'(?ms)^remote-management:\s*\n(?:^[ \t].*\n)*?^[ \t]+secret-key:\s*["\']?([^"\'\n]+)',s)
if m: print(m.group(1)); sys.exit(0)
sys.exit(1)
PY
}
get_env_value(){ docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= -v k="$2" '$1==k{print substr($0,length(k)+2); exit}'; }
container_networks(){ docker inspect "$1" --format '{{range $n,$v := .NetworkSettings.Networks}}{{println $n}}{{end}}' 2>/dev/null || true; }
container_mount_args(){
  local c="$1"
  docker inspect "$c" --format '{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}' 2>/dev/null | while IFS='|' read -r s d; do [[ -n "$s" && -n "$d" ]] && printf '%s:%s\n' "$s" "$d"; done
}
container_restart(){ docker inspect "$1" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || printf 'unless-stopped'; }
container_port_specs(){
  local c="$1"
  docker inspect "$c" --format '{{range $p,$arr := .HostConfig.PortBindings}}{{range $arr}}{{println .HostIp "|" .HostPort "|" $p}}{{end}}{{end}}' 2>/dev/null | while IFS='|' read -r hip hport cport; do
    [[ -n "$hport" && -n "$cport" ]] || continue
    if [[ -n "$hip" ]]; then printf '%s:%s:%s\n' "$hip" "$hport" "$cport"; else printf '%s:%s\n' "$hport" "$cport"; fi
  done
}
default_cli_port_spec(){ local bind="${1:-public}"; if [[ "$bind" == "local" ]]; then printf '127.0.0.1:8317:8317\n'; else printf '8317:8317\n'; fi; }
default_keeper_port_spec(){ printf '127.0.0.1:8080:8080\n'; }
container_host_endpoint(){
  local c="$1" private_port="$2" fallback="$3" line hostport host port
  line="$(docker port "$c" "$private_port/tcp" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$line" && "$line" == *"->"* ]]; then
    hostport="${line##*-> }"
    host="${hostport%:*}"; port="${hostport##*:}"
    host="${host#[}"; host="${host%]}"
    [[ -z "$host" || "$host" == "0.0.0.0" || "$host" == "::" ]] && host="127.0.0.1"
    if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then printf '%s:%s\n' "$host" "$port"; return 0; fi
  fi
  printf '%s\n' "$fallback"
}
port_is_public(){ docker port "$CLI_CONTAINER" 8317/tcp 2>/dev/null | grep -Eq '0\.0\.0\.0:8317|:::8317|:8317$' && ! docker port "$CLI_CONTAINER" 8317/tcp 2>/dev/null | grep -q '127.0.0.1:8317'; }
backup_container(){
  local c="$1" d
  d="$(root_path "/home/docker/backups/${c}-$(date +%Y%m%d%H%M%S)")"
  mkdir -p "$d"
  # 只保存结构摘要，避免把 docker inspect 里的 env secret 明文写入备份。
  {
    printf 'container=%s\n' "$c"
    printf 'networks:\n'; container_networks "$c" | sed 's/^/- /'
    printf 'ports:\n'; docker port "$c" 2>/dev/null | sed 's/^/- /' || true
    printf 'restart=%s\n' "$(container_restart "$c")"
    printf 'mounts:\n'; docker inspect "$c" --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' 2>/dev/null | sed 's/^/- /' || true
  } > "$d/summary.txt"
  [[ "$c" == "$CLI_CONTAINER" && -f "$(root_path "$CLI_CONFIG")" ]] && cp "$(root_path "$CLI_CONFIG")" "$d/config.yaml" || true
  log "已创建备份摘要：$d"
}

ensure_network(){ docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || docker network create "$DOCKER_NETWORK" >/dev/null; }
ensure_container_on_network(){ local n="$1" c="$2"; docker inspect "$c" --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' 2>/dev/null | grep -qx "$n" || docker network connect "$n" "$c" >/dev/null 2>&1 || true; }
open_firewall_port(){
  local port="$1"
  if has_cmd ufw; then ufw allow "$port/tcp" || true
  elif has_cmd firewall-cmd; then firewall-cmd --permanent --add-port="$port/tcp" || true; firewall-cmd --reload || true
  else log "未检测到 ufw 或 firewalld，请确认云厂商安全组和系统防火墙已允许 $port/tcp。"; fi
}
close_firewall_port(){
  local port="$1"
  if has_cmd ufw; then ufw delete allow "$port/tcp" || true
  elif has_cmd firewall-cmd; then firewall-cmd --permanent --remove-port="$port/tcp" || true; firewall-cmd --reload || true
  else log "未检测到 ufw 或 firewalld，请手动确认 $port/tcp 防火墙规则。"; fi
}
public_ip(){ curl -fsS https://api.ipify.org 2>/dev/null || true; }
keeper_env_file(){
  local login="$1" cpakey="$2" public_url="${3:-}" f
  f="$(mktemp)"; chmod 600 "$f"
  {
    printf 'CPA_BASE_URL=http://cli-proxy-api:8317\n'
    printf 'CPA_MANAGEMENT_KEY=%s\n' "$cpakey"
    printf 'LOGIN_PASSWORD=%s\n' "$login"
    printf 'AUTH_ENABLED=true\nAPP_BASE_PATH=/cpa\nAPP_PORT=8080\nREDIS_QUEUE_ADDR=cli-proxy-api:8317\n'
    [[ -n "$public_url" ]] && printf 'CPA_PUBLIC_URL=%s\n' "$public_url"
  } > "$f"
  printf '%s' "$f"
}

install_docker(){
  detect_state; [[ "$DOCKER_AVAILABLE" == 1 ]] && { log "Docker 已安装且可用，无需重复安装。"; return; }
  cat <<'EOF'
即将安装 Docker。

脚本将尝试：
- 下载 Docker 官方安装脚本到 /tmp/get-docker.sh
- 安装 Docker Engine
- 启动 Docker 服务
- 设置 Docker 开机自启

EOF
  confirm "是否继续？输入 Y 确认，其他任意键取消，默认 N：" || { log "已取消安装 Docker。"; return; }
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  systemctl enable docker || true; systemctl start docker || true
  detect_state; [[ "$DOCKER_AVAILABLE" == 1 ]] && log "Docker 安装完成。Docker 服务已启动。" || log "Docker 安装失败，请检查系统版本、网络连接或包管理器状态。"
}

install_cli_proxy_api(){
  detect_state
  [[ "$DOCKER_AVAILABLE" != 1 ]] && { log "宿主机当前无可用 Docker。\nCLIProxyAPI 是容器服务，请先安装 Docker。"; return; }
  [[ "$CLI_EXISTS" == 1 ]] && { cat <<'EOF'
检测到 cli-proxy-api 容器已经存在。

当前脚本第一版不会覆盖已有容器。
如需更新，请使用“升级”功能。
如需重装，请先使用“卸载”功能。

已取消安装 CLIProxyAPI。
EOF
return; }
  local secret
  read_secret_twice "请输入 CLIProxyAPI 管理员密码：" "请再次输入 CLIProxyAPI 管理员密码：" secret || { log "已取消安装 CLIProxyAPI。"; return; }
  cat <<'EOF'
即将安装 CLIProxyAPI：
- 容器名：cli-proxy-api
- 镜像：eceasy/cli-proxy-api:latest
- Docker 网络：cliproxyapi_default
- 访问端口：8317
- 配置目录：/home/docker/CLIProxyAPI
- 管理员密码：已输入，已隐藏
安装完成后将尝试开放系统防火墙 8317/tcp。
EOF
  confirm "是否继续？输入 Y 确认，其他任意键取消，默认 N：" || { log "已取消安装 CLIProxyAPI。"; return; }
  mkdir -p "$(root_path "$CLI_DIR")" "$(root_path "$CLI_DIR/auths")" "$(root_path "$CLI_DIR/logs")"
  ensure_cli_config "$secret"
  ensure_network
  docker pull "$CLI_IMAGE"
  docker run -d --name "$CLI_CONTAINER" --restart unless-stopped --network "$DOCKER_NETWORK" -p 8317:8317 \
    -v "$(root_path "$CLI_CONFIG"):/CLIProxyAPI/config.yaml" \
    -v "$(root_path "$CLI_DIR/auths"):/root/.cli-proxy-api" \
    -v "$(root_path "$CLI_DIR/logs"):/CLIProxyAPI/logs" "$CLI_IMAGE"
  open_firewall_port 8317
  docker ps --filter "name=$CLI_CONTAINER" >/dev/null || true; curl -fsS http://127.0.0.1:8317/ >/dev/null 2>&1 || true
  local ip; ip="$(public_ip)"; [[ -z "$ip" ]] && ip="你的VPS公网IP"
  printf 'CLIProxyAPI 安装完成。\n\n请使用以下地址访问管理页面：\nhttp://%s:8317/management.html\n\n如果无法访问，请检查云厂商安全组、防火墙和容器日志。\n' "$ip"
}

install_cpa_usage_keeper(){
  detect_state
  [[ "$DOCKER_AVAILABLE" != 1 ]] && { log "宿主机当前无可用 Docker。\ncpa-usage-keeper 是容器服务，请先安装 Docker。"; return; }
  [[ "$CLI_EXISTS" != 1 ]] && { log "未检测到 cli-proxy-api 容器。\ncpa-usage-keeper 需要连接 CLIProxyAPI。\n请先安装 CLIProxyAPI。"; return; }
  [[ "$CLI_RUNNING" != 1 ]] && { log "检测到 cli-proxy-api 容器存在，但当前未运行。\n请先启动或修复 CLIProxyAPI 后再安装 cpa-usage-keeper。"; return; }
  [[ "$KEEPER_EXISTS" == 1 ]] && { log "检测到 cpa-usage-keeper 容器已经存在。\n当前脚本第一版不会覆盖已有容器。\n如需更新，请使用“升级”功能。\n如需重装，请先使用“卸载”功能。\n已取消安装 cpa-usage-keeper。"; return; }
  local login cpakey
  read_secret_twice "请输入 cpa-usage-keeper 登录密码：" "请再次输入 cpa-usage-keeper 登录密码：" login || { log "已取消安装 cpa-usage-keeper。"; return; }
  read_secret_twice "请输入 CLIProxyAPI 管理密码，用于 cpa-usage-keeper 连接 CLIProxyAPI：" "请再次输入 CLIProxyAPI 管理密码：" cpakey || { log "已取消安装 cpa-usage-keeper。"; return; }
  cat <<'EOF'
即将安装 cpa-usage-keeper：
- 容器名：cpa-usage-keeper
- 镜像：ghcr.io/willxup/cpa-usage-keeper:latest
- Docker 网络：cliproxyapi_default
- 连接 CLIProxyAPI：http://cli-proxy-api:8317
- 本机访问地址：http://127.0.0.1:8080/cpa/
- 端口绑定：127.0.0.1:8080:8080
- 密码：已输入，已隐藏
EOF
  confirm "是否继续？输入 Y 确认，其他任意键取消，默认 N：" || { log "已取消安装 cpa-usage-keeper。"; return; }
  mkdir -p "$(root_path "$KEEPER_DIR/data")"; ensure_network; ensure_container_on_network "$DOCKER_NETWORK" "$CLI_CONTAINER"
  docker pull "$KEEPER_IMAGE"
  local envf; envf="$(keeper_env_file "$login" "$cpakey")"
  if ! docker run -d --name "$KEEPER_CONTAINER" --restart unless-stopped --network "$DOCKER_NETWORK" -p 127.0.0.1:8080:8080 \
    --env-file "$envf" -v "$(root_path "$KEEPER_DIR/data"):/data" "$KEEPER_IMAGE"; then
    rm -f "$envf"
    return 1
  fi
  rm -f "$envf"
  docker exec "$KEEPER_CONTAINER" getent hosts "$CLI_CONTAINER" >/dev/null 2>&1 || true
  docker exec "$KEEPER_CONTAINER" curl -fsS http://cli-proxy-api:8317/ >/dev/null 2>&1 || true
  curl -fsS http://127.0.0.1:8080/cpa/ >/dev/null 2>&1 || true
  log "cpa-usage-keeper 安装完成。\n当前访问地址：http://127.0.0.1:8080/cpa/\n注意：当前 cpa-usage-keeper 仅监听本机 127.0.0.1。"
}

self_update_check(){
  [[ "${CPA_CLI_MANAGER_SKIP_SELF_UPDATE:-}" == "1" ]] && return 0
  log "正在检查管理脚本是否有新版本..."
  [[ -d "$SCRIPT_REPO/.git" ]] || { log "未检测到 Git 仓库，跳过脚本自更新检查。"; return 0; }
  local branch head remote behind ahead
  branch="$(git -C "$SCRIPT_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ -n "$branch" && "$branch" != "HEAD" ]] || branch="main"
  if ! git -C "$SCRIPT_REPO" fetch origin "$branch" >/dev/null 2>&1; then
    log "无法检查 GitHub 脚本版本（网络不通或权限问题），本次操作已取消，避免用旧脚本继续写配置。"
    return 1
  fi
  head="$(git -C "$SCRIPT_REPO" rev-parse HEAD 2>/dev/null || true)"
  remote="$(git -C "$SCRIPT_REPO" rev-parse "origin/$branch" 2>/dev/null || true)"
  if [[ -z "$head" || -z "$remote" ]]; then
    log "无法比较脚本版本，跳过自更新检查。"
    return 0
  fi
  if [[ "$head" != "$remote" ]]; then
    behind="$(git -C "$SCRIPT_REPO" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)"
    ahead="$(git -C "$SCRIPT_REPO" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"
    if [[ "${behind:-0}" -gt 0 && "${ahead:-0}" -eq 0 ]]; then
      log "发现脚本新版本（落后 ${behind} 个提交），正在自动更新..."
      if git -C "$SCRIPT_REPO" pull --ff-only origin "$branch" >/dev/null 2>&1; then
        log "脚本已更新到最新版本。请重新运行：sudo bash $SCRIPT_NAME"
        exit 0
      else
        log "脚本自动更新失败，请手动执行：cd '$SCRIPT_REPO' && git pull --ff-only"
        return 1
      fi
    fi
    log "脚本仓库与 origin/$branch 不一致且无法安全快进，请手动处理：cd '$SCRIPT_REPO' && git status"
    return 1
  fi
  log "管理脚本已是最新版本，继续执行。"
}

password_mode(){
  local modevar="$1"; cat <<'EOF'
请选择密码处理方式：
1. 保存当前密码升级
2. 更改密码后升级
3. 取消
EOF
  local c; printf '请输入选项 [1-3]：'; read -r c || c=3
  case "$c" in 1) printf -v "$modevar" keep;; 2) printf -v "$modevar" change;; *) log "已取消升级。"; return 1;; esac
}

recreate_cli(){
  local secret="$1" bind="${2:-preserve}" restart firstnet
  local networks=() port_specs=() mount_specs=() docker_args=()
  [[ -z "$secret" ]] && { log "CLIProxyAPI 管理密码为空，已取消重建。"; return 1; }
  mapfile -t networks < <(container_networks "$CLI_CONTAINER"); [[ ${#networks[@]} -eq 0 ]] && networks=("$DOCKER_NETWORK")
  mapfile -t port_specs < <(container_port_specs "$CLI_CONTAINER")
  mapfile -t mount_specs < <(container_mount_args "$CLI_CONTAINER")
  [[ ${#mount_specs[@]} -eq 0 ]] && mount_specs=("$(root_path "$CLI_CONFIG"):/CLIProxyAPI/config.yaml" "$(root_path "$CLI_DIR/auths"):/root/.cli-proxy-api" "$(root_path "$CLI_DIR/logs"):/CLIProxyAPI/logs")
  firstnet="${networks[0]}"; restart="$(container_restart "$CLI_CONTAINER")"
  if [[ "$bind" == preserve ]]; then
    [[ ${#port_specs[@]} -eq 0 ]] && mapfile -t port_specs < <(default_cli_port_spec public)
  else
    mapfile -t port_specs < <(default_cli_port_spec "$bind")
  fi
  ensure_cli_config "$secret" || return 1
  backup_container "$CLI_CONTAINER"
  docker pull "$CLI_IMAGE"; docker stop "$CLI_CONTAINER" || true; docker rm "$CLI_CONTAINER" || true; docker network inspect "$firstnet" >/dev/null 2>&1 || docker network create "$firstnet" >/dev/null
  docker_args=(-d --name "$CLI_CONTAINER" --restart "${restart:-unless-stopped}" --network "$firstnet")
  for p in "${port_specs[@]}"; do [[ -n "$p" ]] && docker_args+=(-p "$p"); done
  for m in "${mount_specs[@]}"; do [[ -n "$m" ]] && docker_args+=(-v "$m"); done
  docker run "${docker_args[@]}" "$CLI_IMAGE"
  for n in "${networks[@]:1}"; do docker network inspect "$n" >/dev/null 2>&1 && docker network connect "$n" "$CLI_CONTAINER" >/dev/null 2>&1 || true; done
}
recreate_keeper(){
  local login="$1" cpakey="$2" public_url="${3:-}" restart firstnet
  local networks=() port_specs=() mount_specs=() docker_args=() envargs=()
  [[ -z "$login" || -z "$cpakey" ]] && { log "cpa-usage-keeper 密码为空，已取消重建。"; return 1; }
  mapfile -t networks < <(container_networks "$KEEPER_CONTAINER"); [[ ${#networks[@]} -eq 0 ]] && networks=("$DOCKER_NETWORK")
  mapfile -t port_specs < <(container_port_specs "$KEEPER_CONTAINER"); [[ ${#port_specs[@]} -eq 0 ]] && mapfile -t port_specs < <(default_keeper_port_spec)
  mapfile -t mount_specs < <(container_mount_args "$KEEPER_CONTAINER"); [[ ${#mount_specs[@]} -eq 0 ]] && mount_specs=("$(root_path "$KEEPER_DIR/data"):/data")
  firstnet="${networks[0]}"; restart="$(container_restart "$KEEPER_CONTAINER")"; mkdir -p "$(root_path "$KEEPER_DIR/data")"
  local envf; envf="$(keeper_env_file "$login" "$cpakey" "$public_url")"
  backup_container "$KEEPER_CONTAINER"
  docker pull "$KEEPER_IMAGE"; docker stop "$KEEPER_CONTAINER" || true; docker rm "$KEEPER_CONTAINER" || true; docker network inspect "$firstnet" >/dev/null 2>&1 || docker network create "$firstnet" >/dev/null
  docker_args=(-d --name "$KEEPER_CONTAINER" --restart "${restart:-unless-stopped}" --network "$firstnet")
  for p in "${port_specs[@]}"; do [[ -n "$p" ]] && docker_args+=(-p "$p"); done
  for m in "${mount_specs[@]}"; do [[ -n "$m" ]] && docker_args+=(-v "$m"); done
  if ! docker run "${docker_args[@]}" --env-file "$envf" "$KEEPER_IMAGE"; then
    rm -f "$envf"
    return 1
  fi
  rm -f "$envf"
  for n in "${networks[@]:1}"; do docker network inspect "$n" >/dev/null 2>&1 && docker network connect "$n" "$KEEPER_CONTAINER" >/dev/null 2>&1 || true; done
}

upgrade_cli(){
  detect_state; [[ "$DOCKER_AVAILABLE" != 1 ]] && { log "宿主机当前无可用 Docker，无法执行容器升级。"; return; }; [[ "$CLI_EXISTS" != 1 ]] && { log "未检测到 cli-proxy-api 容器。无法升级不存在的服务，请先进入“安装”菜单安装 CLIProxyAPI。"; return; }
  self_update_check || return; local mode secret; password_mode mode || return
  if [[ "$mode" == keep ]]; then secret="$(read_cli_secret || true)"; [[ -z "$secret" ]] && { log "无法从现有配置中读取升级所需密码。请选择“更改密码后升级”。"; return; }; else read_secret_twice "请输入新的 CLIProxyAPI 管理密码：" "请再次输入新的 CLIProxyAPI 管理密码：" secret || return; fi
  log "即将升级 CLIProxyAPI：密码已隐藏，将保留网络、端口和 volume，并创建备份。"; confirm "是否继续？输入 Y 确认，其他任意键取消，默认 N：" || { log "已取消升级。"; return; }
  recreate_cli "$secret" preserve; log "CLIProxyAPI 升级完成。已保留原 Docker 网络、端口映射和 volume 挂载。"
}
upgrade_keeper(){
  detect_state; [[ "$DOCKER_AVAILABLE" != 1 ]] && { log "宿主机当前无可用 Docker，无法执行容器升级。"; return; }; [[ "$KEEPER_EXISTS" != 1 ]] && { log "未检测到 cpa-usage-keeper 容器。无法升级不存在的服务，请先进入“安装”菜单安装 cpa-usage-keeper。"; return; }
  self_update_check || return; local mode login cpakey; password_mode mode || return
  if [[ "$mode" == keep ]]; then login="$(get_env_value "$KEEPER_CONTAINER" LOGIN_PASSWORD || true)"; cpakey="$(get_env_value "$KEEPER_CONTAINER" CPA_MANAGEMENT_KEY || true)"; [[ -z "$login" || -z "$cpakey" ]] && { log "无法从现有配置中读取升级所需密码。请选择“更改密码后升级”。"; return; }; else read_secret_twice "请输入新的 cpa-usage-keeper 登录密码：" "请再次输入新的 cpa-usage-keeper 登录密码：" login || return; read_secret_twice "请输入 CLIProxyAPI 管理密码：" "请再次输入 CLIProxyAPI 管理密码：" cpakey || return; fi
  log "即将升级 cpa-usage-keeper：密码已隐藏，将保留网络、端口和 volume，并创建备份。"; confirm "是否继续？输入 Y 确认，其他任意键取消，默认 N：" || { log "已取消升级。"; return; }
  recreate_keeper "$login" "$cpakey" "$(get_env_value "$KEEPER_CONTAINER" CPA_PUBLIC_URL || true)"; log "cpa-usage-keeper 升级完成。已保留原 Docker 网络、端口映射和 volume 挂载。"
}
upgrade_both(){
  detect_state; [[ "$CLI_EXISTS" != 1 || "$KEEPER_EXISTS" != 1 ]] && { log "当前缺少目标服务，无法一同升级。请先进入“安装”菜单补齐缺少的服务。"; return; }
  self_update_check || return; local mode csecret login cpakey; password_mode mode || return
  if [[ "$mode" == keep ]]; then csecret="$(read_cli_secret || true)"; login="$(get_env_value "$KEEPER_CONTAINER" LOGIN_PASSWORD || true)"; cpakey="$(get_env_value "$KEEPER_CONTAINER" CPA_MANAGEMENT_KEY || true)"; [[ -z "$csecret" || -z "$login" || -z "$cpakey" ]] && { log "无法从现有配置中读取升级所需密码。请选择“更改密码后升级”。"; return; }; else read_secret_twice "请输入新的 CLIProxyAPI 管理密码：" "请再次输入新的 CLIProxyAPI 管理密码：" csecret || return; cpakey="$csecret"; read_secret_twice "请输入新的 cpa-usage-keeper 登录密码：" "请再次输入新的 cpa-usage-keeper 登录密码：" login || return; fi
  log "即将一同升级 CLIProxyAPI 与 cpa-usage-keeper：密码已隐藏，将分别保留网络、端口和 volume。"; confirm "是否继续？输入 Y 确认，其他任意键取消，默认 N：" || { log "已取消升级。"; return; }
  recreate_cli "$csecret" preserve; recreate_keeper "$login" "$cpakey" "$(get_env_value "$KEEPER_CONTAINER" CPA_PUBLIC_URL || true)"; log "CLIProxyAPI 与 cpa-usage-keeper 已完成升级。"
}

uninstall_container(){
  local c="$1" label="$2" data="$3"; detect_state
  [[ "$DOCKER_AVAILABLE" != 1 ]] && { log "宿主机当前无可用 Docker，无法检测或卸载容器。"; return; }
  container_exists "$c" || { log "未检测到 $c 容器，无需卸载。"; return; }
  log "即将卸载 $label：仅停止并删除容器；保留数据目录 $data；不删除镜像、网络、防火墙规则。"
  confirm "是否继续？输入 Y 确认，其他任意键取消，默认 N：" || { log "已取消卸载 $label。"; return; }
  docker stop "$c" || true; docker rm "$c" || true; log "$label 容器已卸载。以下数据已保留：$data"
}

install_pkg(){
  local pkgs=("$@"); if has_cmd apt-get; then apt-get update; apt-get install -y "${pkgs[@]}"; elif has_cmd dnf; then dnf install -y "${pkgs[@]}"; elif has_cmd yum; then yum install -y "${pkgs[@]}"; else log "未检测到支持的包管理器，请手动安装：${pkgs[*]}"; return 1; fi
}
valid_domain(){ [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; }
write_nginx_conf(){
  local domain="$1" mode="${2:-both}" cli_endpoint="${3:-127.0.0.1:8317}" keeper_endpoint="${4:-127.0.0.1:8080}" conf; conf="$(root_path "$NGINX_CONF")"; mkdir -p "$(dirname "$conf")"; [[ -f "$conf" ]] && cp "$conf" "$conf.bak-$(date +%Y%m%d%H%M%S)"
  cat > "$conf" <<EOF
server {
    listen 80;
    server_name $domain;
    client_max_body_size 50m;
EOF
  if [[ "$mode" == "cli" || "$mode" == "both" ]]; then
    cat >> "$conf" <<EOF
    location / {
        proxy_pass http://$cli_endpoint;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
EOF
  fi
  if [[ "$mode" == "keeper" || "$mode" == "both" ]]; then
    cat >> "$conf" <<EOF
    location = /cpa {
        return 301 /cpa/;
    }
    location /cpa/ {
        proxy_pass http://$keeper_endpoint/cpa/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
EOF
  fi
  if [[ "$mode" == "keeper" ]]; then
    cat >> "$conf" <<'EOF'
    location / {
        return 302 /cpa/;
    }
EOF
  fi
  cat >> "$conf" <<'EOF'
}
EOF
}
public_access_label(){
  case "$1" in
    cli) printf 'CLIProxyAPI' ;;
    keeper) printf 'cpa-usage-keeper' ;;
    both) printf 'CLIProxyAPI + cpa-usage-keeper' ;;
    *) printf '%s' "$1" ;;
  esac
}
public_access_urls(){
  local scheme="$1" domain="$2" mode="$3" label; label="$(public_access_label "$mode")"
  case "$mode" in
    cli) log "反代后的网址：$scheme://$domain/management.html" ;;
    keeper) log "反代后的网址：$scheme://$domain/cpa/" ;;
    both) log "反代后的网址：$scheme://$domain/management.html 和 $scheme://$domain/cpa/" ;;
  esac
}
configure_public_access(){
  local mode="${1:-both}"
  case "$mode" in cli|keeper|both) ;; *) log "未知公网访问配置模式：$mode"; return 1;; esac
  detect_state; [[ "$DOCKER_AVAILABLE" != 1 ]] && { log "宿主机当前无可用 Docker，无法配置公网访问。"; return; }
  if [[ "$mode" == "cli" || "$mode" == "both" ]]; then
    [[ "$CLI_RUNNING" != 1 ]] && { log "未检测到正在运行的 cli-proxy-api 容器。请先安装或修复 CLIProxyAPI。"; return; }
  fi
  if [[ "$mode" == "keeper" || "$mode" == "both" ]]; then
    [[ "$KEEPER_RUNNING" != 1 ]] && { log "未检测到正在运行的 cpa-usage-keeper 容器。请先安装或修复 cpa-usage-keeper。"; return; }
  fi
  local domain ip resolved cli_endpoint keeper_endpoint; printf '请输入已经解析到本 VPS 的域名，例如 example.com：'; read -r domain || domain=""
  valid_domain "$domain" || { log "域名格式不合法，已取消。"; return; }
  ip="$(public_ip)"; resolved="$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | tr '\n' ' ' || true)"
  if [[ -n "$ip" && -n "$resolved" && "$resolved" != *"$ip"* ]]; then log "警告：当前域名解析结果似乎没有指向本 VPS 公网 IP。当前 IP：$ip 域名解析：$resolved"; confirm "是否仍然继续配置？输入 Y 确认，其他任意键取消，默认 N：" || { log "已取消配置公网访问。"; return; }; fi
  cli_endpoint="$(container_host_endpoint "$CLI_CONTAINER" 8317 "127.0.0.1:8317")"
  keeper_endpoint="$(container_host_endpoint "$KEEPER_CONTAINER" 8080 "127.0.0.1:8080")"
  cat <<EOF
即将配置 $(public_access_label "$mode") 公网访问：
- 写入 Nginx HTTP 反向代理配置：$NGINX_CONF
- 开放系统防火墙 80/tcp 和 443/tcp
- 自动申请 HTTPS 证书，不强制 HTTP 跳转 HTTPS
- certbot 失败时保留 HTTP 配置
EOF
  if [[ "$mode" == "cli" || "$mode" == "both" ]]; then log "CLIProxyAPI 本机反代目标：http://$cli_endpoint"; fi
  if [[ "$mode" == "keeper" || "$mode" == "both" ]]; then log "cpa-usage-keeper 本机反代目标：http://$keeper_endpoint/cpa/"; fi
  if [[ "$mode" == "keeper" || "$mode" == "both" ]]; then
    cat <<'EOF'
- cpa-usage-keeper 将通过 /cpa/ 反代，并在 HTTPS 成功后尝试更新 CPA_PUBLIC_URL，保证“返回 CPA”功能指向公网域名
EOF
  fi
  confirm "是否继续？输入 Y 确认，其他任意键取消，默认 N：" || { log "已取消配置公网访问。"; return; }
  has_cmd nginx || { log "未检测到 Nginx，将安装 Nginx。"; install_pkg nginx || return; systemctl enable nginx || true; systemctl start nginx || true; }
  local conf backup https_ok=0
  conf="$(root_path "$NGINX_CONF")"
  [[ -f "$conf" ]] && backup="$conf.pre-public-access-$(date +%Y%m%d%H%M%S).bak" && cp "$conf" "$backup" || backup=""
  write_nginx_conf "$domain" "$mode" "$cli_endpoint" "$keeper_endpoint"
  if ! nginx -t; then
    [[ -n "$backup" && -f "$backup" ]] && cp "$backup" "$conf"
    log "Nginx 配置测试失败，已恢复旧配置，不 reload。"
    return
  fi
  systemctl reload nginx || true; open_firewall_port 80; open_firewall_port 443
  has_cmd certbot || install_pkg certbot python3-certbot-nginx || true
  if has_cmd certbot && certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email --no-redirect; then
    if nginx -t; then systemctl reload nginx || true; fi
    https_ok=1
    log "HTTPS 证书申请成功。"
    public_access_urls https "$domain" "$mode"
  else
    log "certbot 申请证书失败，已保留 HTTP 反代配置。"
    public_access_urls http "$domain" "$mode"
  fi
  if [[ "$mode" == "keeper" || "$mode" == "both" ]]; then
    if [[ "$KEEPER_RUNNING" == 1 && "$https_ok" == 1 ]]; then
      local cur login cpakey; cur="$(get_env_value "$KEEPER_CONTAINER" CPA_PUBLIC_URL || true)"
      if [[ "$cur" != "https://$domain" ]]; then
        log "检测到 cpa-usage-keeper 的 CPA_PUBLIC_URL 需要更新为 https://$domain，用于保证“返回 CPA”功能可用。"
        if confirm "是否允许重建 cpa-usage-keeper 以更新 CPA_PUBLIC_URL？输入 Y 确认，其他任意键跳过，默认 N："; then
          login="$(get_env_value "$KEEPER_CONTAINER" LOGIN_PASSWORD || true)"; cpakey="$(get_env_value "$KEEPER_CONTAINER" CPA_MANAGEMENT_KEY || true)"
          if [[ -n "$login" && -n "$cpakey" ]]; then
            if recreate_keeper "$login" "$cpakey" "https://$domain"; then
              keeper_endpoint="$(container_host_endpoint "$KEEPER_CONTAINER" 8080 "$keeper_endpoint")"
              write_nginx_conf "$domain" "$mode" "$cli_endpoint" "$keeper_endpoint"
              if nginx -t; then systemctl reload nginx || true; log "cpa-usage-keeper 重建后已重新写入并 reload 反代配置，当前反代目标：http://$keeper_endpoint/cpa/"; else log "cpa-usage-keeper 重建后 Nginx 配置测试失败，请检查 $NGINX_CONF。"; fi
              log "已更新 CPA_PUBLIC_URL。请登录 cpa-usage-keeper 测试“返回 CPA”按钮是否能跳回 https://$domain。"
              public_access_urls https "$domain" "$mode"
            fi
          else
            log "无法读取 Keeper secret，已跳过重建。CPA_PUBLIC_URL 未更新，“返回 CPA”功能可能仍指向旧地址。"
          fi
        else
          log "已跳过 CPA_PUBLIC_URL 更新。“返回 CPA”功能可能仍指向旧地址。"
        fi
      else
        log "cpa-usage-keeper 的 CPA_PUBLIC_URL 已是 https://$domain。请登录测试“返回 CPA”功能。"
      fi
    elif [[ "$KEEPER_RUNNING" == 1 ]]; then
      log "HTTPS 未配置成功，已跳过 CPA_PUBLIC_URL 更新，避免返回地址指向不可用 HTTPS。"
    fi
    log "注意：如果 cpa-usage-keeper 页面里的“返回 CPA”功能仍不可用，说明现有镜像/前端可能不支持 CPA_PUBLIC_URL 覆盖，需要重构 cpa-usage-keeper 后再重新部署。"
  fi
}
public_access_reverse_proxy_menu(){ while true; do detect_state; print_state; cat <<'EOF'
请选择要配置的公网访问服务：
1. 配置 cliproxyapi 公网访问
2. 配置 cpa-usage-keeper 公网访问
3. 配置 cliproxyapi + cpa-usage-keeper 公网访问
4. 退出
EOF
printf '请输入选项 [1-4]：'; local c; read -r c || c=4; case "$c" in 1) configure_public_access cli; pause_return;; 2) configure_public_access keeper; pause_return;; 3) configure_public_access both; pause_return;; 4) return;; *) log "无效选项，请重新输入。";; esac; done; }
require_cli_secret_or_prompt(){
  local varname="$1" secret
  secret="$(read_cli_secret || true)"
  if [[ -z "$secret" ]]; then
    log "无法从现有配置读取 CLIProxyAPI 管理密码。为避免把密码覆盖为空，请重新输入。"
    read_secret_twice "请输入 CLIProxyAPI 管理密码：" "请再次输入 CLIProxyAPI 管理密码：" secret || return 1
  fi
  printf -v "$varname" '%s' "$secret"
}
allow_ip_port(){
  detect_state
  [[ "$CLI_RUNNING" != 1 ]] && { log "未检测到正在运行的 cli-proxy-api 容器。"; return; }
  confirm "即将允许 IP + 端口访问 CLIProxyAPI，并放行 8317/tcp。是否继续？输入 Y 确认，其他任意键取消，默认 N：" || { log "已取消允许 IP + 端口访问。"; return; }
  if ! port_is_public; then
    local secret; require_cli_secret_or_prompt secret || return
    recreate_cli "$secret" public
  fi
  open_firewall_port 8317
  log "已允许 IP + 端口访问 CLIProxyAPI。"
}
forbid_ip_port(){
  detect_state
  [[ "$CLI_EXISTS" != 1 ]] && { log "未检测到 cli-proxy-api 容器，无需禁止 IP + 端口访问。"; return; }
  confirm "即将禁止 IP + 端口访问 CLIProxyAPI，并关闭系统防火墙 8317/tcp 放行。是否继续？输入 Y 确认，其他任意键取消，默认 N：" || { log "已取消禁止 IP + 端口访问。"; return; }
  if port_is_public; then
    local secret; require_cli_secret_or_prompt secret || return
    recreate_cli "$secret" local
  fi
  close_firewall_port 8317
  log "已禁止系统层面的 IP + 端口访问 CLIProxyAPI。请同时确认云厂商安全组未放行 8317/tcp。"
}

install_menu(){ while true; do detect_state; print_state; cat <<'EOF'
请选择要安装的组件：
1. 安装 Docker
2. 安装 CLIProxyAPI
3. 安装 cpa-usage-keeper
4. 返回主菜单
EOF
printf '请输入选项 [1-4]：'; local c; read -r c || c=4; case "$c" in 1) install_docker; pause_return;; 2) install_cli_proxy_api; pause_return;; 3) install_cpa_usage_keeper; pause_return;; 4) return;; *) log "无效选项，请重新输入。";; esac; done; }
upgrade_menu(){ while true; do detect_state; print_state; cat <<'EOF'
请选择升级方式：
1. 升级 CLIProxyAPI
2. 升级 cpa-usage-keeper
3. 一同升级 CLIProxyAPI + cpa-usage-keeper
4. 返回主菜单
EOF
printf '请输入选项 [1-4]：'; local c; read -r c || c=4; case "$c" in 1) upgrade_cli; pause_return;; 2) upgrade_keeper; pause_return;; 3) upgrade_both; pause_return;; 4) return;; *) log "无效选项，请重新输入。";; esac; done; }
uninstall_menu(){ while true; do detect_state; print_state; cat <<'EOF'
请选择要卸载的服务：
1. 卸载 CLIProxyAPI
2. 卸载 cpa-usage-keeper
3. 返回主菜单
EOF
printf '请输入选项 [1-3]：'; local c; read -r c || c=3; case "$c" in 1) uninstall_container "$CLI_CONTAINER" "CLIProxyAPI" "$CLI_DIR"; pause_return;; 2) uninstall_container "$KEEPER_CONTAINER" "cpa-usage-keeper" "$KEEPER_DIR/data"; pause_return;; 3) return;; *) log "无效选项，请重新输入。";; esac; done; }
public_access_menu(){ while true; do detect_state; print_state; cat <<'EOF'
请选择公网访问操作：
1. 配置公网访问
2. 允许 IP + 端口访问 CLIProxyAPI
3. 禁止 IP + 端口访问 CLIProxyAPI
4. 返回主菜单
EOF
printf '请输入选项 [1-4]：'; local c; read -r c || c=4; case "$c" in 1) public_access_reverse_proxy_menu;; 2) allow_ip_port; pause_return;; 3) forbid_ip_port; pause_return;; 4) return;; *) log "无效选项，请重新输入。";; esac; done; }
main_menu(){ while true; do detect_state; cat <<'EOF'
========================================
 CPA + CLIProxyAPI VPS 管理脚本
========================================
当前脚本用于管理：
- Docker
- CLIProxyAPI
- cpa-usage-keeper
请选择操作：
1. 安装
2. 升级
3. 卸载
4. 公网访问 / 反向代理
5. 退出
EOF
printf '请输入选项 [1-5]：'; local c; read -r c || c=5; case "$c" in 1) install_menu;; 2) upgrade_menu;; 3) uninstall_menu;; 4) public_access_menu;; 5) log "已退出。"; return 0;; *) log "无效选项，请重新输入。";; esac; done; }

require_root
self_update_check
main_menu
