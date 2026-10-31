import os
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class DevWorkflowTest(unittest.TestCase):
    def test_justfile_exposes_the_supported_workflow(self):
        source = (ROOT / "Justfile").read_text(encoding="utf-8")
        for recipe in ("doctor", "check", "deploy", "reset-scripts", "probe",
                       "shot", "verify-install"):
            self.assertRegex(source, rf"(?m)^{re.escape(recipe)}(?:\s|:)")
        self.assertNotIn("C:" + "\\Users\\", source)
        just = shutil.which("just")
        if just:
            subprocess.run([just, "--fmt", "--check"], cwd=ROOT, check=True)
        self.assertIn(".tmp-tests/", (ROOT / ".gitignore").read_text(encoding="utf-8"))

    def test_dev_script_owns_tool_discovery_and_unique_temp(self):
        source = (ROOT / "scripts" / "dev.ps1").read_text(encoding="utf-8")
        for action in ("doctor", "check", "deploy", "reset-scripts", "probe",
                       "shot", "verify-install"):
            self.assertIn(f'"{action}"', source)
        self.assertIn("[guid]::NewGuid()", source)
        self.assertIn("LOCALAPPDATA", source)
        self.assertIn("uv python find 3.12", source)
        self.assertIn("UV_CACHE_DIR", source)
        self.assertIn(r".tmp-tests\dev", source)
        self.assertIn('tools\\probe\\qnml_check.lua', source)
        self.assertIn('probe harness installed', source)
        self.assertNotIn("C:" + "\\Users\\", source)

    @staticmethod
    def _write_bmp(path, width, height, rectangles, labels=()):
        background = (26, 27, 28)
        button = (51, 52, 54)
        stride = (width * 3 + 3) & ~3
        pixels = bytearray(stride * height)
        for y in range(height):
            for x in range(width):
                rgb = button if any(
                    left <= x <= right and top <= y <= bottom
                    for left, top, right, bottom in rectangles
                ) else background
                off = (height - 1 - y) * stride + x * 3
                pixels[off:off + 3] = bytes((rgb[2], rgb[1], rgb[0]))
        header = struct.pack(
            "<2sIHHIIIIHHIIIIII",
            b"BM", 54 + len(pixels), 0, 0, 54, 40, width, height,
            1, 24, 0, len(pixels), 2835, 2835, 0, 0,
        )
        path.write_bytes(header + pixels)
        if labels:
            DevWorkflowTest._add_labels(path, labels)

    @staticmethod
    def _add_labels(path, labels):
        output = path.with_name(path.stem + "-labeled.bmp")
        env = os.environ.copy()
        env["QNML_TEST_INPUT"] = str(path.resolve())
        env["QNML_TEST_OUTPUT"] = str(output.resolve())
        env["QNML_TEST_LABELS"] = ";".join(
            f"{header},{buttons},{'true' if semantic else 'false'}"
            for header, buttons, semantic in labels)
        script = r'''
Add-Type -AssemblyName System.Drawing
$source = [System.Drawing.Bitmap]::FromFile($env:QNML_TEST_INPUT)
try {
    $graphics = [System.Drawing.Graphics]::FromImage($source)
    try {
        $font = [System.Drawing.Font]::new("Arial", 10,
            [System.Drawing.FontStyle]::Regular,
            [System.Drawing.GraphicsUnit]::Pixel)
        try {
            foreach ($group in $env:QNML_TEST_LABELS.Split(";")) {
                $parts = $group.Split(",")
                $header = [int]$parts[0]
                $buttons = [int]$parts[1]
                $semantic = [bool]::Parse($parts[2])
                $headerText = if ($semantic) { "ScriptRunner" } else { "PluginLoader" }
                $middleText = if ($semantic) { "Reset scripts" } else { "Open console" }
                $graphics.DrawString($headerText, $font,
                    [System.Drawing.Brushes]::White, 15, $header + 3)
                $graphics.DrawString("Run script", $font,
                    [System.Drawing.Brushes]::White, 21, $buttons + 3)
                $graphics.DrawString($middleText, $font,
                    [System.Drawing.Brushes]::White, 75, $buttons + 3)
                $graphics.DrawString("Spawn Debug Console", $font,
                    [System.Drawing.Brushes]::White, 137, $buttons + 3)
            }
        } finally { $font.Dispose() }
    } finally { $graphics.Dispose() }
    $source.Save($env:QNML_TEST_OUTPUT, [System.Drawing.Imaging.ImageFormat]::Bmp)
} finally { $source.Dispose() }
'''
        subprocess.run([
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-Command", script,
        ], cwd=ROOT, env=env, text=True, capture_output=True, check=True)
        output.replace(path)

    def test_reset_scripts_locates_the_second_button_without_cursor_input(self):
        script = ROOT / "scripts" / "reset-scripts.ps1"
        source = script.read_text(encoding="utf-8")
        self.assertIn("PostMessageW", source)
        self.assertIn("GetForegroundWindow", source)
        self.assertIn("CHK ready", source)
        self.assertIn("OcrEngine", source)
        self.assertIn('"scriptrunner"', source)
        self.assertIn('"reset"', source)
        self.assertIn("$readyIndex -gt $reloadIndex", source)
        self.assertNotIn("[ScriptState] Running script", source)
        self.assertIn('if ($_.Exception.Message -ne "reset target not found") { throw }', source)
        for forbidden in ("SetCursorPos", "mouse_event", "keybd_event", "SendInput"):
            self.assertNotIn(forbidden, source)
        scratch = ROOT / ".tmp-tests"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            image = Path(td) / "buttons.bmp"
            self._write_bmp(image, 280, 140, [
                (10, 20, 260, 40),
                (20, 50, 69, 67),
                (74, 50, 131, 67),
                (136, 50, 235, 67),
            ], labels=[(20, 50, True)])
            result = subprocess.run([
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(script), "-Screenshot", str(image), "-LocateOnly",
            ], cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"reset target 103,(?:5\d|6[0-7])")

    def test_reset_scripts_fails_closed_on_ambiguous_button_rows(self):
        script = ROOT / "scripts" / "reset-scripts.ps1"
        scratch = ROOT / ".tmp-tests"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            image = Path(td) / "ambiguous.bmp"
            rows = []
            for top in (35, 95):
                rows.extend([
                    (10, top - 25, 260, top - 8),
                    (20, top, 69, top + 17),
                    (74, top, 131, top + 17),
                    (136, top, 235, top + 17),
                ])
            self._write_bmp(image, 280, 140, rows)
            self._add_labels(image, [(top - 25, top, True) for top in (35, 95)])
            result = subprocess.run([
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(script), "-Screenshot", str(image), "-LocateOnly",
            ], cwd=ROOT, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ambiguous reset target", result.stdout + result.stderr)

    def test_reset_scripts_accepts_a_text_interrupted_header_edge(self):
        script = ROOT / "scripts" / "reset-scripts.ps1"
        scratch = ROOT / ".tmp-tests"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            image = Path(td) / "short-header-edge.bmp"
            self._write_bmp(image, 280, 140, [
                (10, 35, 260, 40),
                (20, 50, 69, 67),
                (74, 50, 131, 67),
                (136, 50, 235, 67),
            ], labels=[(35, 50, True)])
            result = subprocess.run([
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(script), "-Screenshot", str(image), "-LocateOnly",
            ], cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"reset target 103,(?:5\d|6[0-7])")

    def test_reset_scripts_rejects_an_unbound_three_button_pattern(self):
        script = ROOT / "scripts" / "reset-scripts.ps1"
        scratch = ROOT / ".tmp-tests"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            image = Path(td) / "unbound.bmp"
            self._write_bmp(image, 280, 140, [
                (20, 50, 69, 67),
                (74, 50, 131, 67),
                (136, 50, 235, 67),
            ])
            result = subprocess.run([
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(script), "-Screenshot", str(image), "-LocateOnly",
            ], cwd=ROOT, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reset target not found", result.stdout + result.stderr)

    def test_reset_guidance_uses_only_the_verified_command(self):
        local_skill = (ROOT / ".claude" / "skills" / "verified-live-handoff" /
                       "SKILL.md").read_text(encoding="utf-8")
        harness = (ROOT / "tools" / "probe" / "qnml_check.lua").read_text(
            encoding="utf-8")
        runner = (ROOT / "tools" / "probe" / "run.py").read_text(
            encoding="utf-8")
        for source in (local_skill, harness, runner):
            self.assertIn("just reset-scripts", source)
        self.assertIn("Never use `focus.ps1`, `shot.ps1`, `input.ps1`", local_skill)
        self.assertNotIn("copy it into the game's reframework/autorun/", runner)

    def test_reset_scripts_rejects_a_non_script_runner_button_row(self):
        script = ROOT / "scripts" / "reset-scripts.ps1"
        scratch = ROOT / ".tmp-tests"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as td:
            image = Path(td) / "wrong-section.bmp"
            self._write_bmp(image, 280, 140, [
                (10, 20, 260, 40),
                (20, 50, 69, 67),
                (74, 50, 131, 67),
                (136, 50, 235, 67),
            ], labels=[(20, 50, False)])
            result = subprocess.run([
                "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", str(script), "-Screenshot", str(image), "-LocateOnly",
            ], cwd=ROOT, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reset target not found", result.stdout + result.stderr)

    def test_local_limit_gate_never_reuses_a_compiler_input(self):
        utility = (ROOT / "scripts" / "check_util.ps1").read_text(encoding="utf-8")
        gate = (ROOT / "scripts" / "check.ps1").read_text(encoding="utf-8")
        self.assertIn("function New-QnmlTempFilePath", utility)
        self.assertIn("New-QnmlTempFilePath", gate)
        self.assertNotRegex(gate, r"Test-Fits\s+\$lines\s+\$mid\s+\$tmp\b")


if __name__ == "__main__":
    unittest.main()
