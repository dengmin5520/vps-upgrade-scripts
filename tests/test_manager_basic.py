import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "cpa_cli_vps_manager.sh"


def write_exe(path: Path, content: str):
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run_manager(input_text: str, mockbin: Path, euid: str = "0", test_root: Path | None = None, timeout: int = 8):
    env = os.environ.copy()
    env["PATH"] = f"{mockbin}:{env['PATH']}"
    env["CPA_CLI_MANAGER_TEST_EUID"] = euid
    if test_root is not None:
        env["CPA_CLI_MANAGER_TEST_ROOT"] = str(test_root)
    return subprocess.run(
        ["bash", str(SCRIPT)],
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        timeout=timeout,
    )


def make_mockbin(
    base: Path,
    docker_mode: str = "absent",
    cli_exists: bool = False,
    cli_running: bool = False,
    keeper_exists: bool = False,
    keeper_running: bool = False,
    cli_bind: str = "public",
    certbot_success: bool = True,
):
    mockbin = base / "bin"
    mockbin.mkdir()
    log = base / "calls.log"

    write_exe(mockbin / "systemctl", f"""#!/usr/bin/env bash
printf 'systemctl %q ' "$@" >> {log}; printf '\n' >> {log}
if [[ ${{1:-}} == is-active && ${{2:-}} == docker ]]; then echo inactive; exit 3; fi
exit 0
""")
    write_exe(mockbin / "ufw", f"#!/usr/bin/env bash\nprintf 'ufw %q ' \"$@\" >> {log}; printf '\\n' >> {log}\nexit 0\n")
    write_exe(mockbin / "firewall-cmd", f"#!/usr/bin/env bash\nprintf 'firewall-cmd %q ' \"$@\" >> {log}; printf '\\n' >> {log}\nexit 0\n")
    write_exe(mockbin / "curl", f"""#!/usr/bin/env bash
printf 'curl %q ' "$@" >> {log}; printf '\n' >> {log}
last="${{@: -1}}"
if [[ "$last" == "https://api.ipify.org" ]]; then echo 203.0.113.10; exit 0; fi
exit 22
""")
    write_exe(mockbin / "nginx", f"#!/usr/bin/env bash\nprintf 'nginx %q ' \"$@\" >> {log}; printf '\\n' >> {log}\nexit 0\n")
    write_exe(mockbin / "certbot", f"""#!/usr/bin/env bash
printf 'certbot %q ' "$@" >> {log}; printf '\n' >> {log}
[[ "{certbot_success}" == "True" ]] && exit 0 || exit 1
""")
    # Avoid real package manager side effects if a test path reaches install_pkg.
    write_exe(mockbin / "apt-get", f"#!/usr/bin/env bash\nprintf 'apt-get %q ' \"$@\" >> {log}; printf '\\n' >> {log}\nexit 0\n")
    write_exe(mockbin / "getent", "#!/usr/bin/env bash\nif [[ $1 == hosts ]]; then echo '203.0.113.10 example.com'; exit 0; fi\nexit 1\n")

    if docker_mode != "absent":
        port_line = "8317/tcp -> 0.0.0.0:8317" if cli_bind == "public" else "8317/tcp -> 127.0.0.1:8317"
        docker_script = f'''#!/usr/bin/env bash
set -e
printf 'docker ' >> {log}; printf '%q ' "$@" >> {log}; printf '\n' >> {log}
cmd="${{1:-}}"; shift || true
case "$cmd" in
  info)
    [[ "{docker_mode}" == "ok" ]] && exit 0 || exit 1
    ;;
  network)
    sub="${{1:-}}"; shift || true
    if [[ "$sub" == "inspect" ]]; then exit 1; fi
    exit 0
    ;;
  ps)
    all=0; name=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -a) all=1 ;;
        --filter) shift; name="${{1#name=}}" ;;
        --format) shift ;;
      esac
      shift || true
    done
    if [[ "$name" == "cli-proxy-api" && "{cli_exists}" == "True" ]]; then
      [[ "$all" == 1 || "{cli_running}" == "True" ]] && echo "cli-proxy-api"
    elif [[ "$name" == "cpa-usage-keeper" && "{keeper_exists}" == "True" ]]; then
      [[ "$all" == 1 || "{keeper_running}" == "True" ]] && echo "cpa-usage-keeper"
    fi
    ;;
  port)
    if [[ "${{1:-}}" == "cli-proxy-api" ]]; then echo "{port_line}"; fi
    if [[ "${{1:-}}" == "cpa-usage-keeper" ]]; then echo "8080/tcp -> 127.0.0.1:8080"; fi
    ;;
  inspect)
    c="${{1:-}}"; fmt=""
    while [[ $# -gt 0 ]]; do [[ "$1" == "--format" ]] && {{ shift; fmt="${{1:-}}"; }}; shift || true; done
    if [[ "$fmt" == *'.Config.Env'* ]]; then
      [[ "$c" == "cpa-usage-keeper" ]] && printf 'LOGIN_PASSWORD=oldlogin\nCPA_MANAGEMENT_KEY=oldkey\nCPA_PUBLIC_URL=https://old.example\n'
    elif [[ "$fmt" == *'.NetworkSettings.Networks'* ]]; then
      echo cliproxyapi_default
    elif [[ "$fmt" == *'.HostConfig.PortBindings'* ]]; then
      if [[ "$c" == "cli-proxy-api" ]]; then echo '127.0.0.1|18317|8317/tcp'; fi
      if [[ "$c" == "cpa-usage-keeper" ]]; then echo '127.0.0.1|18080|8080/tcp'; fi
    elif [[ "$fmt" == *'.Mounts'* ]]; then
      [[ "$c" == "cli-proxy-api" ]] && printf '/custom/cli-config.yaml|/CLIProxyAPI/config.yaml\n/custom/auths|/root/.cli-proxy-api\n/custom/logs|/CLIProxyAPI/logs\n'
      [[ "$c" == "cpa-usage-keeper" ]] && echo '/custom/keeper-data|/data'
    elif [[ "$fmt" == *'.HostConfig.RestartPolicy.Name'* ]]; then
      echo unless-stopped
    else
      echo '{{"Name":"'$c'"}}'
    fi
    ;;
  run|pull|stop|rm|exec)
    exit 0
    ;;
  *) exit 0 ;;
esac
'''
        write_exe(mockbin / "docker", docker_script)
    return mockbin, log


class ManagerBasicTests(unittest.TestCase):
    def test_bash_n_passes(self):
        result = subprocess.run(["bash", "-n", str(SCRIPT)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_non_root_exits_with_sudo_hint(self):
        with tempfile.TemporaryDirectory() as d:
            mockbin, _ = make_mockbin(Path(d))
            result = run_manager("", mockbin, euid="1000")
        self.assertEqual(result.returncode, 1)
        self.assertIn("请使用 sudo 运行本脚本", result.stdout)
        self.assertIn("sudo bash cpa_cli_vps_manager.sh", result.stdout)

    def test_main_menu_exit(self):
        with tempfile.TemporaryDirectory() as d:
            mockbin, _ = make_mockbin(Path(d))
            result = run_manager("5\n", mockbin)
        self.assertEqual(result.returncode, 0)
        self.assertIn("CPA + CLIProxyAPI VPS 管理脚本", result.stdout)
        self.assertIn("已退出", result.stdout)

    def test_default_n_does_not_execute_docker_install(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            mockbin, log = make_mockbin(base, docker_mode="absent")
            result = run_manager("1\n1\n\n4\n5\n", mockbin)
            calls = log.read_text()
        self.assertEqual(result.returncode, 0)
        self.assertIn("已取消安装 Docker", result.stdout)
        self.assertNotIn("get.docker.com", calls)
        self.assertNotIn("enable docker", calls)

    def test_install_keeper_without_docker_prompts_install_docker(self):
        with tempfile.TemporaryDirectory() as d:
            mockbin, _ = make_mockbin(Path(d), docker_mode="absent")
            result = run_manager("1\n3\n4\n5\n", mockbin)
        self.assertEqual(result.returncode, 0)
        self.assertIn("宿主机当前无可用 Docker", result.stdout)
        self.assertIn("请先安装 Docker", result.stdout)

    def test_install_keeper_without_cli_prompts_install_cli(self):
        with tempfile.TemporaryDirectory() as d:
            mockbin, _ = make_mockbin(Path(d), docker_mode="ok", cli_exists=False, keeper_exists=False)
            result = run_manager("1\n3\n4\n5\n", mockbin)
        self.assertEqual(result.returncode, 0)
        self.assertIn("未检测到 cli-proxy-api 容器", result.stdout)
        self.assertIn("请先安装 CLIProxyAPI", result.stdout)

    def test_install_existing_cli_does_not_overwrite(self):
        with tempfile.TemporaryDirectory() as d:
            mockbin, _ = make_mockbin(Path(d), docker_mode="ok", cli_exists=True, cli_running=True)
            result = run_manager("1\n2\n4\n5\n", mockbin)
        self.assertEqual(result.returncode, 0)
        self.assertIn("检测到 cli-proxy-api 容器已经存在", result.stdout)
        self.assertIn("不会覆盖已有容器", result.stdout)

    def test_cli_install_writes_config_and_docker_run_without_printing_secret(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            root = base / "rootfs"
            mockbin, log = make_mockbin(base, docker_mode="ok")
            result = run_manager("1\n2\nsuper-secret\nsuper-secret\nY\n4\n5\n", mockbin, test_root=root)
            calls = log.read_text()
            cfg = root / "home/docker/CLIProxyAPI/config.yaml"
            cfg_text = cfg.read_text()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("CLIProxyAPI 安装完成", result.stdout)
        self.assertNotIn("super-secret", result.stdout)
        self.assertIn("remote-management:", cfg_text)
        self.assertIn("allow-remote: true", cfg_text)
        self.assertIn('secret-key: "super-secret"', cfg_text)
        self.assertIn("usage-statistics-enabled: true", cfg_text)
        self.assertIn("docker run", calls)
        self.assertIn("--name cli-proxy-api", calls)
        self.assertIn("-p 8317:8317", calls)

    def test_keeper_install_does_not_print_secrets_and_runs_container(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            root = base / "rootfs"
            mockbin, log = make_mockbin(base, docker_mode="ok", cli_exists=True, cli_running=True)
            result = run_manager("1\n3\nlogin-secret\nlogin-secret\nkey-secret\nkey-secret\nY\n4\n5\n", mockbin, test_root=root)
            calls = log.read_text()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("cpa-usage-keeper 安装完成", result.stdout)
        self.assertNotIn("login-secret", result.stdout)
        self.assertNotIn("key-secret", result.stdout)
        self.assertIn("docker run", calls)
        self.assertIn("--name cpa-usage-keeper", calls)
        self.assertIn("--env-file", calls)
        self.assertNotIn("CPA_BASE_URL=http://cli-proxy-api:8317", calls)
        self.assertNotIn("login-secret", calls)
        self.assertNotIn("key-secret", calls)
        self.assertIn("-p 127.0.0.1:8080:8080", calls)

    def test_uninstall_default_n_does_not_stop_or_rm(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            mockbin, log = make_mockbin(base, docker_mode="ok", cli_exists=True, cli_running=True)
            result = run_manager("3\n1\n\n3\n5\n", mockbin)
            calls = log.read_text()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("已取消卸载 CLIProxyAPI", result.stdout)
        self.assertNotIn("docker stop cli-proxy-api", calls)
        self.assertNotIn("docker rm cli-proxy-api", calls)

    def test_public_certbot_failure_keeps_http_and_no_secret_leak(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            root = base / "rootfs"
            mockbin, log = make_mockbin(base, docker_mode="ok", cli_exists=True, cli_running=True, keeper_exists=True, keeper_running=True, certbot_success=False)
            result = run_manager("4\n1\nexample.com\nY\n\n4\n5\n", mockbin, test_root=root)
            calls = log.read_text()
            conf = root / "etc/nginx/conf.d/cpa-cli-proxy.conf"
            conf_text = conf.read_text()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("certbot 申请证书失败，已保留 HTTP 反代配置", result.stdout)
        self.assertIn("server_name example.com", conf_text)
        self.assertIn("proxy_pass http://127.0.0.1:8317", conf_text)
        self.assertIn("proxy_pass http://127.0.0.1:8080/cpa/", conf_text)
        self.assertIn("certbot --nginx", calls)
        self.assertIn("-d", calls)
        self.assertIn("example.com", calls)
        self.assertNotIn("oldlogin", result.stdout)
        self.assertNotIn("oldkey", result.stdout)

    def test_public_access_menu_contains_https_options(self):
        with tempfile.TemporaryDirectory() as d:
            mockbin, _ = make_mockbin(Path(d), docker_mode="ok")
            result = run_manager("4\n4\n5\n", mockbin)
        self.assertEqual(result.returncode, 0)
        self.assertIn("配置公网访问", result.stdout)
        self.assertIn("允许 IP + 端口访问 CLIProxyAPI", result.stdout)
        self.assertIn("禁止 IP + 端口访问 CLIProxyAPI", result.stdout)

    def test_cli_recreate_preserves_existing_port_and_mounts(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            root = base / "rootfs"
            cfg = root / "home/docker/CLIProxyAPI/config.yaml"
            cfg.parent.mkdir(parents=True)
            cfg.write_text('remote-management:\n  allow-remote: true\n  secret-key: "old-secret"\nusage-statistics-enabled: true\n')
            mockbin, log = make_mockbin(base, docker_mode="ok", cli_exists=True, cli_running=True, keeper_exists=False, cli_bind="local")
            result = run_manager("2\n1\n1\nY\n4\n5\n", mockbin, test_root=root)
            calls = log.read_text()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("-p 127.0.0.1:18317:8317/tcp", calls)
        self.assertIn("-v /custom/cli-config.yaml:/CLIProxyAPI/config.yaml", calls)
        self.assertIn("-v /custom/auths:/root/.cli-proxy-api", calls)
        self.assertIn("-v /custom/logs:/CLIProxyAPI/logs", calls)

    def test_keeper_recreate_preserves_existing_port_and_mount(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            root = base / "rootfs"
            mockbin, log = make_mockbin(base, docker_mode="ok", cli_exists=True, cli_running=True, keeper_exists=True, keeper_running=True)
            result = run_manager("2\n2\n1\nY\n4\n5\n", mockbin, test_root=root)
            calls = log.read_text()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("-p 127.0.0.1:18080:8080/tcp", calls)
        self.assertIn("-v /custom/keeper-data:/data", calls)
        self.assertIn("--env-file", calls)
        self.assertNotIn("oldlogin", calls)
        self.assertNotIn("oldkey", calls)


if __name__ == "__main__":
    unittest.main()
