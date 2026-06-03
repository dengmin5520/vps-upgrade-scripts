# CPA + CLIProxyAPI VPS Manager

Interactive Bash manager for installing, upgrading, uninstalling, and exposing a VPS deployment that runs:

- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
- [cpa-usage-keeper](https://github.com/Willxup/cpa-usage-keeper)

This repository currently provides:

- `cpa_cli_vps_manager.sh` — interactive VPS management script.
- `upgrade_cpa_cli_containers_template.sh` — older dry-run-first container upgrade template.
- `tests/test_manager_basic.py` — local mock tests for the manager script.

> This project is a helper wrapper. It is not an official CLIProxyAPI or cpa-usage-keeper project.

---

## Features

`cpa_cli_vps_manager.sh` provides a menu-driven workflow:

```text
1. Install
2. Upgrade
3. Uninstall
4. Public access / reverse proxy
5. Exit
```

### Install

- Install Docker using Docker's official convenience script: `https://get.docker.com`.
- Install `cli-proxy-api` with config file, auth directory, logs directory, Docker network, and management key.
  - **Important:** The generated `config.yaml` always includes `port: 8317`. Without this line, CLIProxyAPI listens on a random port and the Docker port mapping (`8317:8317`) becomes useless — external access will fail with "connection reset".
- Install `cpa-usage-keeper` on the same Docker network.
- Keeper binds to `127.0.0.1:8080` by default instead of exposing itself directly to the public Internet.

### Upgrade

Upgrade menu:

```text
1. Upgrade CLIProxyAPI
2. Upgrade cpa-usage-keeper
3. Upgrade both
4. Back
```

Upgrade behavior:

- Checks whether this manager repository has a newer GitHub version before container upgrades.
- Supports keeping existing passwords or entering new passwords.
- Pulls latest container images.
- Recreates containers while preserving existing Docker networks, port bindings, volume mounts, and restart policy when possible.
- Uses a temporary `--env-file` for cpa-usage-keeper secrets and removes it after `docker run`.

### Uninstall

Uninstall menu:

```text
1. Uninstall CLIProxyAPI
2. Uninstall cpa-usage-keeper
3. Back
```

Default uninstall only stops and removes the selected container. It does **not** remove data directories, images, Docker networks, firewall rules, or secrets.

### Public access / reverse proxy

Public access menu:

```text
1. Configure public access
2. Allow IP + port access to CLIProxyAPI
3. Deny IP + port access to CLIProxyAPI
4. Back
```

Public access behavior:

- Uses system Nginx.
- Requires the user to enter a domain that has already been resolved to the VPS public IP.
- Writes a fixed reverse proxy configuration:
  - `https://<domain>/management.html` → CLIProxyAPI
  - `https://<domain>/cpa/` → cpa-usage-keeper
- Uses certbot automatically:

```bash
certbot --nginx \
  -d <domain> \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  --no-redirect
```

- Does not require an email address.
- Does not force HTTP → HTTPS redirects.
- If certificate issuance fails, the HTTP Nginx configuration is kept.

---

## Quick start

On the VPS:

```bash
git clone https://github.com/dengmin5520/vps-upgrade-scripts.git
cd vps-upgrade-scripts
bash -n cpa_cli_vps_manager.sh
sudo bash cpa_cli_vps_manager.sh
```

If `git clone` reports the directory already exists, use `git pull` instead:

```bash
cd ~/vps-upgrade-scripts
git pull
sudo bash cpa_cli_vps_manager.sh
```

---

## Updating the script

### Automatic update on startup

When you run `sudo bash cpa_cli_vps_manager.sh`, the script checks GitHub for a newer version **before** showing the menu. If an update is available, it runs `git pull` automatically, prints a message, and exits. Re-run the script to continue.

### Manual update

```bash
cd ~/vps-upgrade-scripts
git pull
sudo bash cpa_cli_vps_manager.sh
```

If `git clone` says `fatal: destination path 'vps-upgrade-scripts' already exists and is not an empty directory`, that means you already cloned it before. Just `cd` into the directory and `git pull`.

---

## Safety notes

- Run as root or via `sudo`.
- Most destructive actions require a second confirmation and default to `N`.
- Password input is hidden.
- Raw secrets should not be printed in terminal output.
- cpa-usage-keeper is not exposed directly by default; it is intended to be exposed through Nginx `/cpa/`.
- Public port `8317/tcp` for CLIProxyAPI can be allowed or denied from the public access menu.
- Always verify cloud provider security groups separately.

---

## Local tests

The tests use mock commands and do not install Docker or touch real Nginx/certbot:

```bash
bash -n cpa_cli_vps_manager.sh
python3 -m unittest discover -s tests -v
```

---

## Credits and upstream projects

This helper depends on and is designed around these upstream projects:

- CLIProxyAPI — https://github.com/router-for-me/CLIProxyAPI
- cpa-usage-keeper — https://github.com/Willxup/cpa-usage-keeper

Thanks to the maintainers and contributors of both projects.

---

# CPA + CLIProxyAPI VPS 管理脚本

这是一个交互式 Bash 管理脚本，用于在 VPS 上安装、升级、卸载和配置公网访问：

- [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
- [cpa-usage-keeper](https://github.com/Willxup/cpa-usage-keeper)

当前仓库包含：

- `cpa_cli_vps_manager.sh` — 交互式 VPS 管理脚本。
- `upgrade_cpa_cli_containers_template.sh` — 旧版 dry-run 优先的容器升级模板。
- `tests/test_manager_basic.py` — 本地 mock 测试。

> 本项目只是辅助封装脚本，不是 CLIProxyAPI 或 cpa-usage-keeper 官方项目。

---

## 功能

`cpa_cli_vps_manager.sh` 提供菜单式流程：

```text
1. 安装
2. 升级
3. 卸载
4. 公网访问 / 反向代理
5. 退出
```

### 安装

- 使用 Docker 官方安装脚本 `https://get.docker.com` 安装 Docker。
- 安装 `cli-proxy-api`，包括配置文件、auth 目录、日志目录、Docker 网络和管理密钥。
- 安装 `cpa-usage-keeper`，并让它和 CLIProxyAPI 位于同一个 Docker 网络。
- Keeper 默认只绑定 `127.0.0.1:8080`，不直接裸露到公网。

### 升级

升级菜单：

```text
1. 升级 CLIProxyAPI
2. 升级 cpa-usage-keeper
3. 一同升级
4. 返回
```

升级行为：

- 升级容器前，先检查管理脚本仓库是否有 GitHub 新版本。
- 支持“保存当前密码升级”和“更改密码后升级”。
- 拉取最新容器镜像。
- 重建容器时尽量保留原 Docker 网络、端口映射、volume 挂载和 restart policy。
- cpa-usage-keeper 的敏感环境变量通过临时 `--env-file` 注入，并在 `docker run` 后删除。

### 卸载

卸载菜单：

```text
1. 卸载 CLIProxyAPI
2. 卸载 cpa-usage-keeper
3. 返回
```

默认卸载只停止并删除指定容器，不删除数据目录、镜像、Docker 网络、防火墙规则或密钥。

### 公网访问 / 反向代理

公网访问菜单：

```text
1. 配置公网访问
2. 允许 IP + 端口访问 CLIProxyAPI
3. 禁止 IP + 端口访问 CLIProxyAPI
4. 返回
```

公网访问行为：

- 固定使用系统 Nginx。
- 要求用户输入已经解析到 VPS 公网 IP 的域名。
- 写入固定反向代理配置：
  - `https://<domain>/management.html` → CLIProxyAPI
  - `https://<domain>/cpa/` → cpa-usage-keeper
- 自动使用 certbot 申请证书：

```bash
certbot --nginx \
  -d <domain> \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  --no-redirect
```

- 不要求用户输入邮箱。
- 不强制 HTTP 跳转 HTTPS。
- 如果证书申请失败，保留 HTTP Nginx 配置。

---

## 快速开始

在 VPS 上：

```bash
git clone https://github.com/dengmin5520/vps-upgrade-scripts.git
cd vps-upgrade-scripts
bash -n cpa_cli_vps_manager.sh
sudo bash cpa_cli_vps_manager.sh
```

如果 `git clone` 提示目录已存在，用 `git pull` 代替：

```bash
cd ~/vps-upgrade-scripts
git pull
sudo bash cpa_cli_vps_manager.sh
```

---

## 更新脚本

### 启动时自动更新

运行 `sudo bash cpa_cli_vps_manager.sh` 时，脚本会在显示菜单**之前**检查 GitHub 是否有新版本。如果有更新，会自动执行 `git pull`，提示更新完成并退出。重新运行脚本即可继续。

### 手动更新

```bash
cd ~/vps-upgrade-scripts
git pull
sudo bash cpa_cli_vps_manager.sh
```

如果 `git clone` 提示 `fatal: destination path 'vps-upgrade-scripts' already exists and is not an empty directory`，说明你之前已经克隆过。直接 `cd` 进目录执行 `git pull` 即可。

---

## 安全说明

- 请使用 root 或 `sudo` 运行。
- 大多数危险操作都有二次确认，并且默认 `N`。
- 密码输入会隐藏。
- 脚本不应在终端输出原始密钥。
- cpa-usage-keeper 默认不直接暴露公网，推荐通过 Nginx `/cpa/` 访问。
- CLIProxyAPI 的公网 `8317/tcp` 直连可在公网访问菜单中允许或禁止。
- 云厂商安全组需要另外确认。

---

## 本地测试

测试使用 mock 命令，不会安装 Docker，也不会修改真实 Nginx/certbot：

```bash
bash -n cpa_cli_vps_manager.sh
python3 -m unittest discover -s tests -v
```

---

## 致谢和上游项目

本辅助脚本围绕以下上游项目设计：

- CLIProxyAPI — https://github.com/router-for-me/CLIProxyAPI
- cpa-usage-keeper — https://github.com/Willxup/cpa-usage-keeper

感谢两个项目的维护者和贡献者。
