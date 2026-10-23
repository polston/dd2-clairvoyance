"""Offline tests for the icon extractor (stdlib only). Run from the repo root:
python -m unittest discover -s tools -p "test_extract_icons.py" -v
"""
import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_icons as ei  # noqa: E402
import qnml_pak  # noqa: E402

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
SETTINGS = os.path.join(REPO, "reframework", "autorun", "Clairvoyance", "settings_util.lua")
INDEX = os.path.join(REPO, "reframework", "images", "Clairvoyance", "icons", "index.json")


def build_uvs():
    """A one-texture, one-sequence, two-pattern sheet; the string table follows the patterns."""
    o_tex, o_seq, o_pat, o_str = 56, 96, 104, 168
    head = b".SVU" + struct.pack("<IIIII", 1, 1, 2, 0, 0)
    head += struct.pack("<QQQQ", o_tex, o_seq, o_pat, o_str)
    tex = struct.pack("<QQ", 0, 0) + b"\0" * 24
    seq = struct.pack("<II", 2, 0)
    pats = struct.pack("<Qffffii", 7, 0.0, 0.25, 0.5, 0.75, 0, 3)
    pats += struct.pack("<Qffffii", 9, 0.5, 0.0, 1.0, 1.0, 0, 0)
    return head + tex + seq + pats + "ui/foo.tex".encode("utf-16-le") + b"\0\0"


def build_tex(fmt, w=16, h=8):
    data = bytearray(64)
    data[0:4] = b"TEX\0"
    struct.pack_into("<IHH", data, 4, 1, w, h)
    data[14] = 1
    struct.pack_into("<I", data, 16, fmt)
    struct.pack_into("<QII", data, 40, 64, w * 4, w * h)
    return bytes(data)


def flat(vals):
    return [(v, v, v, 255) for v in vals]


class ParseTests(unittest.TestCase):
    def test_uvs_two_patterns(self):
        r = ei.parse_uvs(build_uvs())
        self.assertEqual(r["texs"], ["ui/foo.tex"])
        self.assertEqual(r["seqs"], [(2, 0)])
        self.assertEqual(len(r["pats"]), 2)
        self.assertEqual(r["pats"][0]["flags"], 7)
        self.assertEqual(r["pats"][0]["cutouts"], 3)
        self.assertEqual((r["pats"][1]["left"], r["pats"][1]["right"], r["pats"][1]["tex"]),
                         (0.5, 1.0, 0))

    def test_tex_header(self):
        self.assertEqual(ei.parse_tex_header(build_tex(98)),
                         {"w": 16, "h": 8, "fmt": 98, "off": 64, "size": 128})

    def test_tex_unsupported_format(self):
        with self.assertRaises(ValueError) as cm:
            ei.parse_tex_header(build_tex(71))
        self.assertEqual(str(cm.exception), "unsupported texture format 71")


class PixelTests(unittest.TestCase):
    def test_channel_order(self):
        self.assertEqual(ei.bgra_to_rgba(bytes([0, 0, 255, 255]))[0], (255, 0, 0, 255))

    def test_cut_flags(self):
        self.assertIs(ei.cut_flags([0, 129]), True)
        self.assertIs(ei.cut_flags([128]), False)

    def test_pick_source(self):
        self.assertEqual(ei.pick_source(True, True), "minimap")
        self.assertEqual(ei.pick_source(False, True), "fullmap")
        self.assertIsNone(ei.pick_source(False, False))

    def test_whiten_flat(self):
        self.assertEqual(ei.whiten(flat([40, 40, 40])), [(255, 255, 255, 255)] * 3)

    def test_whiten_dark_glyph_percentiles(self):
        vals = [10 + round(i * 50 / 19) for i in range(20)]
        out = ei.whiten(flat(vals))
        self.assertEqual(out[0][0], 115)    # 5th percentile: nearest rank 1
        self.assertEqual(out[18][0], 255)   # 95th percentile: nearest rank 19
        self.assertEqual(out[19][0], 255)
        self.assertTrue(all(o[0] == o[1] == o[2] for o in out))

    def test_whiten_keeps_alpha(self):
        out = ei.whiten([(10, 10, 10, 255), (50, 50, 50, 255), (30, 30, 30, 40)])
        self.assertEqual(out[2][3], 40)

    def test_whiten_red_vs_blue(self):
        out = ei.whiten([(255, 0, 0, 255), (0, 0, 255, 255)])
        self.assertEqual(out[0][0], 255)
        self.assertEqual(out[1][0], 115)

    def test_fit_rect(self):
        self.assertEqual(ei.fit_rect(245, 111), (0, 18, 64, 29))
        self.assertEqual(ei.fit_rect(70, 24), (0, 21, 64, 22))


class IndexTests(unittest.TestCase):
    def test_lines_and_stale_removal(self):
        entries = {
            3: {"src": "fullmap", "minimap": False, "fullmap": True},
            1: {"src": "minimap", "minimap": True, "fullmap": True},
            2: {"src": None, "minimap": False, "fullmap": False},
        }
        wrote, removed = {}, []
        ei.write_index(entries, "out", lambda p, t: wrote.__setitem__(p, t),
                       lambda d: ["9.png", "1.png", "3.png", "index.json", "notes.txt"],
                       removed.append)
        text = wrote[os.path.join("out", "index.json")]
        self.assertEqual(text.splitlines(), [
            '{"1": {"src": "minimap", "minimap": true, "fullmap": true},',
            '"2": {"src": null, "minimap": false, "fullmap": false},',
            '"3": {"src": "fullmap", "minimap": false, "fullmap": true}}'])
        self.assertEqual(json.loads(text)["3"]["src"], "fullmap")
        self.assertEqual(removed, [os.path.join("out", "9.png")])


def _key_path_from(script):
    spec = importlib.util.spec_from_file_location("key_check_copy", script)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.key_path()


class KeyTests(unittest.TestCase):
    def test_missing_key_fails(self):
        with tempfile.TemporaryDirectory() as d:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = ei.main(["--game", d, "--key", os.path.join(d, "none.txt"), "--out", d])
            self.assertEqual(code, 1)
            self.assertEqual(buf.getvalue().strip(), "tools/pak_key.local.txt missing")
            self.assertEqual(os.listdir(d), [])

    def test_key_path_main_and_worktree(self):
        def git(cwd, *args):
            subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid"] + list(args),
                           cwd=cwd, check=True, capture_output=True)
        with tempfile.TemporaryDirectory() as d:
            main = os.path.join(d, "main")
            os.makedirs(os.path.join(main, "tools"))
            git(main, "init", "-q")
            shutil.copy(os.path.join(TOOLS, "key_check.py"), os.path.join(main, "tools", "key_check.py"))
            git(main, "add", "tools/key_check.py")
            git(main, "commit", "-q", "-m", "x")
            wt = os.path.join(d, "wt")
            git(main, "worktree", "add", "-q", wt, "-b", "lane")
            want = os.path.realpath(os.path.join(main, "tools", "pak_key.local.txt"))
            for root in (main, wt):
                got = _key_path_from(os.path.join(root, "tools", "key_check.py"))
                self.assertEqual(os.path.realpath(got), want, root)

    def _run_with_pak(self, secret):
        with tempfile.TemporaryDirectory() as d:
            key = os.path.join(d, "k.txt")
            with open(key, "w") as f:
                f.write(secret)
            with open(os.path.join(d, "re_chunk_000.pak"), "wb") as f:
                f.write(struct.pack("<4sBBHII", b"KPKA", 4, 2, qnml_pak.SUPPORTED_FEATURE, 0, 0)
                        + struct.pack("<Q", 0) + b"" * 128)
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = ei.main(["--game", d, "--key", key, "--out", os.path.join(d, "o")])
            self.assertEqual(sorted(os.listdir(d)), ["k.txt", "re_chunk_000.pak"])
            return code, out.getvalue() + err.getvalue()

    def test_key_value_never_in_output(self):
        for secret in ("zzzzsecretzz", "abcdef0123456789feedface"):
            code, text = self._run_with_pak(secret)
            self.assertEqual(code, 1)
            self.assertTrue(text.strip())
            self.assertNotIn(secret, text)


class ModuleMessageTests(unittest.TestCase):
    def test_missing_module_named(self):
        from unittest import mock
        err = ImportError("x", name="texture2ddecoder")
        with tempfile.TemporaryDirectory() as d:
            key = os.path.join(d, "k.txt")
            with open(key, "w") as f:
                f.write("00")
            buf = io.StringIO()
            with mock.patch.object(ei, "extract", side_effect=err), contextlib.redirect_stdout(buf):
                code = ei.main(["--game", d, "--key", key, "--out", d])
        self.assertEqual(code, 1)
        self.assertIn("missing module: texture2ddecoder (", buf.getvalue())


class CutTests(unittest.TestCase):
    def test_cut_rectangle(self):
        px = [bytes([i, i + 1, i + 2, 255]) for i in range(0, 32, 4)]
        bgra = b"".join(px)  # 4x2 pixels
        pat = {"left": 0.25, "right": 0.75, "top": 0.0, "bottom": 0.5}
        cw, ch, got = ei._cut(pat, 4, 2, bgra)
        self.assertEqual((cw, ch), (2, 1))
        self.assertEqual(got, [(6, 5, 4, 255), (10, 9, 8, 255)])

    def test_cut_empty(self):
        pat = {"left": 0.5, "right": 0.5, "top": 0.0, "bottom": 1.0}
        self.assertEqual(ei._cut(pat, 4, 2, bytes(32)), (0, 0, []))


def _lua_table(text, name):
    m = re.search(r"M\.%s\s*=\s*\{(.*?)\n?\}\s*\n" % name, text, re.S)
    return m.group(1) if m else ""


class PinTests(unittest.TestCase):
    def setUp(self):
        with open(SETTINGS, encoding="utf-8") as f:
            self.lua = f.read()
        if "M.HAS_MINIMAP" not in self.lua:
            self.skipTest("settings_util.lua has no M.HAS_MINIMAP yet; the pin runs once it lands")

    def _flags(self, name):
        body = _lua_table(self.lua, name)
        return {int(i): v == "true" for i, v in re.findall(r"\[(\d+)\]\s*=\s*(true|false)", body)}

    def test_flags_choices_and_v12(self):
        with open(INDEX, encoding="utf-8") as f:
            index = json.load(f)
        mini, full = self._flags("HAS_MINIMAP"), self._flags("HAS_FULLMAP")
        for key, got in (("minimap", mini), ("fullmap", full)):
            want = {int(i): e[key] for i, e in index.items()}
            for i in want:
                self.assertEqual(got.get(i, False), want[i], "%s id %d" % (key, i))
            self.assertEqual({i for i in got if got[i]} - set(want), set())
        folder = os.path.dirname(INDEX)
        choices = [int(i) for i in re.findall(r"\{\s*(\d+)\s*,\s*\"", _lua_table(self.lua, "ICON_CHOICES"))]
        self.assertTrue(choices)
        for i in choices:
            self.assertTrue(os.path.exists(os.path.join(folder, "%d.png" % i)), "ICON_CHOICES id %d" % i)
        v12 = [int(i) for i in re.findall(r"icon_\w+\s*=\s*(\d+)", _lua_table(self.lua, "V12_ICON"))]
        self.assertTrue(v12)
        for i in v12:
            self.assertTrue(mini.get(i), "V12_ICON %d minimap" % i)
            self.assertTrue(full.get(i), "V12_ICON %d fullmap" % i)


if __name__ == "__main__":
    unittest.main()
