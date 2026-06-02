import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "cpa_cli_vps_manager.sh"


class SelfUpdateTests(unittest.TestCase):
    def test_script_uses_its_own_clone_for_self_update_not_hardcoded_root_repo(self):
        if not shutil.which("git"):
            self.skipTest("git unavailable")
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            origin = base / "origin.git"
            seed = base / "seed"
            clone = base / "clone"
            subprocess.run(["git", "init", "--bare", str(origin)], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["git", "init", str(seed)], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["git", "-C", str(seed), "config", "user.email", "test@example.com"], check=True)
            subprocess.run(["git", "-C", str(seed), "config", "user.name", "Test"], check=True)
            shutil.copy2(SCRIPT, seed / "cpa_cli_vps_manager.sh")
            subprocess.run(["git", "-C", str(seed), "add", "."], check=True)
            subprocess.run(["git", "-C", str(seed), "commit", "-m", "initial"], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["git", "-C", str(seed), "branch", "-M", "main"], check=True)
            subprocess.run(["git", "-C", str(seed), "remote", "add", "origin", str(origin)], check=True)
            subprocess.run(["git", "-C", str(seed), "push", "-u", "origin", "main"], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["git", "clone", "--branch", "main", str(origin), str(clone)], check=True, stdout=subprocess.DEVNULL)

            # Advance origin after the user cloned, simulating a later GitHub update.
            marker = "SELF_UPDATE_MARKER_FROM_TEST"
            (seed / "marker.txt").write_text(marker)
            subprocess.run(["git", "-C", str(seed), "add", "."], check=True)
            subprocess.run(["git", "-C", str(seed), "commit", "-m", "update"], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["git", "-C", str(seed), "push", "origin", "main"], check=True, stdout=subprocess.DEVNULL)

            env = os.environ.copy()
            env["CPA_CLI_MANAGER_TEST_EUID"] = "0"
            env.pop("CPA_CLI_MANAGER_SKIP_SELF_UPDATE", None)
            result = subprocess.run(
                ["bash", str(clone / "cpa_cli_vps_manager.sh")],
                input="2\n4\n5\n",
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=env,
                timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("脚本已更新到最新版本", result.stdout)
            self.assertTrue((clone / "marker.txt").exists(), result.stdout)
            head = subprocess.check_output(["git", "-C", str(clone), "rev-parse", "HEAD"], text=True).strip()
            remote = subprocess.check_output(["git", "-C", str(clone), "rev-parse", "origin/main"], text=True).strip()
            self.assertEqual(head, remote)


if __name__ == "__main__":
    unittest.main()
