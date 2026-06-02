import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "cpa_cli_vps_manager.sh"


def extract_python_snippet():
    text = SCRIPT.read_text()
    start = text.index("  python3 -c '\n") + len("  python3 -c '\n")
    end = text.index("\n' \"$cfg\" <<< \"$secret\"", start)
    return text[start:end]


class ConfigPatchTests(unittest.TestCase):
    def test_remote_management_block_with_blank_comment_lines_is_replaced_without_duplicates(self):
        snippet = extract_python_snippet()
        original = """remote-management:
  allow-remote: false
  secret-key: old

  # comments inside upstream sample block
  allow-remote: true

  secret-key: duplicate
usage-statistics-enabled: false
proxy-url: ""
"""
        with tempfile.TemporaryDirectory() as d:
            cfg = Path(d) / "config.yaml"
            cfg.write_text(original)
            subprocess.run(
                ["python3", "-c", snippet, str(cfg)],
                input="new-secret",
                text=True,
                check=True,
            )
            out = cfg.read_text()
        self.assertEqual(out.count("remote-management:"), 1)
        self.assertEqual(out.count("allow-remote:"), 1)
        self.assertEqual(out.count("secret-key:"), 1)
        self.assertIn('secret-key: "new-secret"', out)
        self.assertIn("usage-statistics-enabled: true", out)
        self.assertIn('proxy-url: ""', out)


if __name__ == "__main__":
    unittest.main()
