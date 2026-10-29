import re
import shutil
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class DevWorkflowTest(unittest.TestCase):
    def test_justfile_exposes_the_supported_workflow(self):
        source = (ROOT / "Justfile").read_text(encoding="utf-8")
        for recipe in ("doctor", "check", "deploy", "probe", "shot", "verify-install"):
            self.assertRegex(source, rf"(?m)^{re.escape(recipe)}(?:\s|:)")
        self.assertNotIn("C:" + "\\Users\\", source)
        just = shutil.which("just")
        if just:
            subprocess.run([just, "--fmt", "--check"], cwd=ROOT, check=True)

    def test_dev_script_owns_tool_discovery_and_unique_temp(self):
        source = (ROOT / "scripts" / "dev.ps1").read_text(encoding="utf-8")
        for action in ("doctor", "check", "deploy", "probe", "shot", "verify-install"):
            self.assertIn(f'"{action}"', source)
        self.assertIn("[guid]::NewGuid()", source)
        self.assertIn("LOCALAPPDATA", source)
        self.assertIn("uv python find 3.12", source)
        self.assertNotIn("C:" + "\\Users\\", source)

    def test_local_limit_gate_never_reuses_a_compiler_input(self):
        utility = (ROOT / "scripts" / "check_util.ps1").read_text(encoding="utf-8")
        gate = (ROOT / "scripts" / "check.ps1").read_text(encoding="utf-8")
        self.assertIn("function New-QnmlTempFilePath", utility)
        self.assertIn("New-QnmlTempFilePath", gate)
        self.assertNotRegex(gate, r"Test-Fits\s+\$lines\s+\$mid\s+\$tmp\b")


if __name__ == "__main__":
    unittest.main()
