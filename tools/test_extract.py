"""Offline tests for the extractor modules. Run from the repo root:
python -m unittest discover -s tools -p "test_*.py"
"""
import contextlib
import getpass
import importlib.util
import io
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_world as ew  # noqa: E402
import key_check  # noqa: E402
import qnml_pak  # noqa: E402
import qnml_rsz  # noqa: E402

TOOLS = os.path.dirname(os.path.abspath(__file__))
LAYOUT_LINE = "game update changed the data layout; rebuild tools/layouts.json from a new SDK dump"
PAIR_LAYOUTS = {"types": {"11223344": {"name": "t.Pair", "fields": [
    ["a", "S32", 4, 4, False], ["b", "S32", 4, 4, False]]}}, "enums": {}}


def build_blob(a, b):
    """A user-data file holding one t.Pair instance (fields a and b)."""
    base = 48
    usr = struct.pack("<4siiiQQQ", b"USR\0", 0, 0, 0, 40, 40, base) + b"\0" * 8
    rsz = struct.pack("<4sIiiiiQQQ", b"RSZ\0", 16, 1, 2, 0, 0, 52, 68, 68)
    rsz += struct.pack("<i", 1)                              # object table: instance 1
    rsz += struct.pack("<II", 0, 0) + struct.pack("<II", 0x11223344, 0)  # null + t.Pair
    rsz += struct.pack("<ii", a, b)
    return usr + rsz


def header(major, minor, feature, count):
    return struct.pack("<4sBBHII", b"KPKA", major, minor, feature, count, 0)


class PakTests(unittest.TestCase):
    def test_murmur_vector(self):
        # value recorded from the working prototype for this path
        p = "natives/STM/AppData/Generate/ManualSet/Content/DNG_010/ManualSetTable_DNG_010.user.3"
        self.assertEqual(qnml_pak.path_hash(p), 0xBDF763871FA76FA5)

    def test_unsupported_feature_fails(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "x.pak")
            with open(p, "wb") as f:
                f.write(header(4, 2, 0x6C, 0))
            with self.assertRaises(qnml_pak.PakError) as cm:
                qnml_pak.Pak(p)
            self.assertIn("0x4", str(cm.exception))

    def test_patch_pak_nonempty_fails(self):
        with tempfile.TemporaryDirectory() as d:
            p3, p0 = os.path.join(d, "p3.pak"), os.path.join(d, "p0.pak")
            p1 = os.path.join(d, "p1.pak")
            with open(p1, "wb") as f:
                f.write(header(4, 1, 0, 1))
            self.assertIn("p1.pak", ew.check_patches([p1]))
            with open(p3, "wb") as f:
                f.write(header(4, 1, 0, 3))
            with open(p0, "wb") as f:
                f.write(header(4, 1, 0, 0))
            self.assertEqual(qnml_pak.patch_entry_count(p3), 3)
            reason = ew.check_patches([p3])
            self.assertIn("p3.pak", reason)
            self.assertIsNone(ew.check_patches([p0]))

    def test_pak_selection(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "dlc"))
            os.makedirs(os.path.join(d, "pak_mods"))
            for rel in ("re_chunk_000.pak", "re_chunk_000.pak.patch_001.pak",
                        "dlc/x.pak", "pak_mods/y.pak"):
                open(os.path.join(d, rel), "wb").close()
            base, patches = ew.pak_files(d)
            self.assertEqual(base, os.path.join(d, "re_chunk_000.pak"))
            self.assertEqual(patches, [os.path.join(d, "re_chunk_000.pak.patch_001.pak")])


class RszTests(unittest.TestCase):
    def test_rsz_synthetic(self):
        insts = qnml_rsz.decode(build_blob(7, -9), PAIR_LAYOUTS)
        self.assertEqual(len(insts), 1)
        self.assertEqual(insts[0].type, "t.Pair")
        self.assertEqual(insts[0].fields, {"a": 7, "b": -9})
        with self.assertRaises(qnml_rsz.DecodeError):
            qnml_rsz.decode(build_blob(7, -9) + b"\0", PAIR_LAYOUTS)

    def test_layout_failure_message(self):
        with self.assertRaises(ew.ExtractError) as cm:
            ew._decode(build_blob(1, 2) + b"\0", PAIR_LAYOUTS)
        self.assertEqual(str(cm.exception), LAYOUT_LINE)
        insts = ew._decode(build_blob(1, 2), PAIR_LAYOUTS)
        self.assertEqual(len(insts), 1)

    def test_guid_form(self):
        b = bytes(range(16))
        self.assertEqual(qnml_rsz.guid_str(b), "03020100-0504-0706-0809-0a0b0c0d0e0f")


class RowTests(unittest.TestCase):
    def test_phase_tag(self):
        self.assertEqual(ew.phase_of("a/DNG_01/_beforeSeason4/x.user"), "beforeseason4")
        self.assertEqual(ew.phase_of("a/b__Season4/x.user"), "season4")
        self.assertEqual(ew.phase_of("a/b_season4/x.user"), "season4")
        self.assertIsNone(ew.phase_of("a/b/x.user"))

    def test_chara_set_only(self):
        def inst(i, t, path=None, **fields):
            n = qnml_rsz.Inst(i, t, path)
            n.fields = fields
            return n
        R = qnml_rsz.Ref

        def row(guid, cid):
            return dict(_ManualSetGuid=guid, _GimmickID=0, _CharaID=cid, _ManualPos=(1.04, 2.0, 3.0),
                        _Container=R(0))
        table = [
            inst(1, "app.GenerateTable", _EnemySetInfo=R(2), _NpcSetInfo=R(3)),
            inst(2, "app.GenerateTable.SetInfo", _BasicRowDatas=[R(4)]),
            inst(3, "app.GenerateTable.SetInfo", _BasicRowDatas=[R(5)]),
            inst(4, "app.GenerateRowData", **row("g1", 5)),
            inst(5, "app.GenerateRowData", **row("g2", 6)),
        ]
        lst = [inst(1, "app.GenerateTableData", path="t.user"),
               inst(2, "app.GenerateTableListData", _NormalTableList=[R(1)], _SubQuestTableList=[],
                    _MainQuestTableList=[], _RandomNormalTableList=[])]
        rows, unjoined, _ids, _kinds = ew.collect_rows({"t.user": table, "l.user": lst}, {}, set(), {"5": "ch5"})
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["k"], rows[0]["uid"], rows[0]["id"], rows[0]["name"], rows[0]["src"]),
                         ("chara", "g1", 5, "ch5", "normal"))
        self.assertEqual(rows[0]["x"], 1.0)

    def test_third_chest_types(self):
        def inst(i, t, path=None, **fields):
            n = qnml_rsz.Inst(i, t, path)
            n.fields = fields
            return n
        R = qnml_rsz.Ref
        for gid in (12, 693, 694):
            with self.subTest(gimmick=gid):
                table = [
                    inst(1, "app.GenerateTable", _GimmickSetInfo=R(2)),
                    inst(2, "app.GenerateTable.SetInfo", _BasicRowDatas=[R(3)]),
                    inst(3, "app.GenerateRowData", _GimmickID=gid, _ManualSetGuid="g1",
                         _ManualPos=(1.0, 2.0, 3.0), _Container=R(4)),
                    inst(4, "app.Container", _GimmickSetting=R(5)),
                    inst(5, "app.GimmickSetting", _ParamId=1),
                ]
                lst = [inst(1, "app.GenerateTableData", path="t.user"),
                       inst(2, "app.GenerateTableListData", _NormalTableList=[R(1)], _SubQuestTableList=[],
                            _MainQuestTableList=[], _RandomNormalTableList=[])]
                rows, unjoined, _ids, _kinds = ew.collect_rows(
                    {"t.user": table, "l.user": lst},
                    {1: {"items": [(500, 2)], "trap": False, "pawn": False}}, set(), {})
                self.assertEqual(len(rows), 1)
                self.assertEqual((rows[0]["k"], rows[0]["id"], rows[0]["items"]),
                                 ("chest", gid, [{"id": 500, "n": 2}]))
                self.assertEqual(unjoined, 0)

    def test_params_of_flags(self):
        def inst(i, t, **fields):
            n = qnml_rsz.Inst(i, t)
            n.fields = fields
            return n
        R = qnml_rsz.Ref
        insts = [
            inst(1, "app.Gm80_001Param", ParamId=1, ItemList=[R(3)], TrapGenerateData=R(4),
                 IsPawnRestrict=True),
            inst(2, "app.Gm80_001Param", ParamId=2, ItemList=[R(3)], TrapGenerateData=R(0),
                 IsPawnRestrict=False),
            inst(3, "app.Gm80_001Param.ItemParam", ItemId=7, ItemNum=1),
            inst(4, "app.TrapGenerateData"),
        ]
        params, conflicts = ew.params_of(insts)
        self.assertEqual(params[1], {"items": [(7, 1)], "trap": True, "pawn": True})
        self.assertEqual(params[2], {"items": [(7, 1)], "trap": False, "pawn": False})
        self.assertEqual(conflicts, set())

    def test_params_of_flag_conflict(self):
        def inst(i, t, **fields):
            n = qnml_rsz.Inst(i, t)
            n.fields = fields
            return n
        R = qnml_rsz.Ref
        insts = [
            inst(1, "app.Gm80_001Param", ParamId=1, ItemList=[], TrapGenerateData=R(0), IsPawnRestrict=True),
            inst(2, "app.Gm80_001Param", ParamId=1, ItemList=[], TrapGenerateData=R(0), IsPawnRestrict=False),
        ]
        params, conflicts = ew.params_of(insts)
        self.assertEqual(conflicts, {1})

    def test_collect_rows_kind_fields(self):
        def inst(i, t, path=None, **fields):
            n = qnml_rsz.Inst(i, t, path)
            n.fields = fields
            return n
        R = qnml_rsz.Ref
        QF = "app.GenerateManager.QuestFlagInfos.QuestFlagInfo"
        QV = "app.GenerateManager.QuestFlagInfos.QuestVariableInfo"
        # (guid, ParamId, set-flag instances, expected quest/var)
        table = [inst(1, "app.GenerateTable", _GimmickSetInfo=R(2)),
                 inst(2, "app.GenerateTable.SetInfo", _BasicRowDatas=[R(10 + i) for i in range(6)])]
        base = 100

        def chest(n, guid, pid, check_type=None, infos=()):
            sf = R(0)
            extra = []
            if check_type is not None:
                sf = R(base + n * 10 + 1)
                extra = [inst(base + n * 10 + 1, "app.SetFlagSetting", _QuestFlagInfos=R(base + n * 10 + 2)),
                         inst(base + n * 10 + 2, "app.QuestFlagInfos", _CheckType=check_type,
                              _Infos=[R(base + n * 10 + 3 + j) for j in range(len(infos))])]
                for j, (t, f) in enumerate(infos):
                    extra.append(inst(base + n * 10 + 3 + j, t, **f))
            return [inst(10 + n, "app.GenerateRowData", _GimmickID=10, _ManualSetGuid=guid,
                         _ManualPos=(1.0, 2.0, 3.0), _Container=R(base + n * 10)),
                    inst(base + n * 10, "app.Container", _GimmickSetting=R(base + n * 10 + 9),
                         _SetFlagSetting=sf),
                    inst(base + n * 10 + 9, "app.GimmickSetting", _ParamId=pid)] + extra
        body = []
        body += chest(0, "plain", 1)
        body += chest(1, "all", 1, 0, [(QF, dict(_QuestID=11020, _IsFinishCheck=True))])
        body += chest(2, "any", 1, 1, [(QF, dict(_QuestID=5, _IsFinishCheck=False)),
                                       (QF, dict(_QuestID=6, _IsFinishCheck=True))])
        body += chest(3, "var", 1, 0, [(QV, {})])
        body += chest(4, "trap", 2)
        body += chest(5, "pawn", 3)
        insts = table + body
        insts.sort(key=lambda i: i.idx)
        by = {i.idx: i for i in insts}
        top = max(by)
        full = [by.get(k) or inst(k, "app.Filler") for k in range(1, top + 1)]
        lst = [inst(1, "app.GenerateTableData", path="t.user"),
               inst(2, "app.GenerateTableListData", _NormalTableList=[R(1)], _SubQuestTableList=[],
                    _MainQuestTableList=[], _RandomNormalTableList=[])]
        params = {1: {"items": [], "trap": False, "pawn": False},
                  2: {"items": [], "trap": True, "pawn": False},
                  3: {"items": [], "trap": False, "pawn": True}}
        rows, _unj, _ids, kinds = ew.collect_rows({"t.user": full, "l.user": lst}, params, set(), {})
        r = {x["uid"]: x for x in rows}
        for k in ("quest", "trap", "pawn"):
            self.assertNotIn(k, r["plain"])
        self.assertEqual(r["all"]["quest"], {"any": False, "q": [[11020, True]]})
        self.assertEqual(r["any"]["quest"], {"any": True, "q": [[5, False], [6, True]]})
        self.assertEqual(r["var"]["quest"], {"any": False, "q": [], "var": True})
        self.assertTrue(r["trap"]["trap"])
        self.assertNotIn("pawn", r["trap"])
        self.assertTrue(r["pawn"]["pawn"])
        self.assertEqual((kinds["quest"], kinds["trap"], kinds["pawn"]), (3, 1, 1))
        with self.assertRaises(ew.ExtractError):
            ew.collect_rows({"t.user": full, "l.user": lst}, params, {2}, {})
        ew.collect_rows({"t.user": full, "l.user": lst}, params, {99}, {})

    def test_missing_key_fails(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "out.json")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = ew.main(["--game", d, "--out", out, "--key", os.path.join(d, "none.txt")])
            self.assertEqual(code, 1)
            self.assertEqual(buf.getvalue().strip(), "tools/pak_key.local.txt missing")
            self.assertFalse(os.path.exists(out))


def _key_path_from(script):
    spec = importlib.util.spec_from_file_location("key_check_copy", script)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.key_path()


class KeyPathTests(unittest.TestCase):
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


class KeyCheckVerbTests(unittest.TestCase):
    def test_path_verb_prints_the_key_path_only(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = key_check.main(["--path"])
        self.assertEqual(code, 0)
        self.assertEqual(buf.getvalue().strip(), key_check.key_path())


class OutputTests(unittest.TestCase):
    def test_write_failure_leaves_no_file(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "places.json")
            with self.assertRaises(ew.ExtractError):
                ew.write_output(out, {"rows": [object()]})
            self.assertEqual(os.listdir(d), [])
            ew.write_output(out, {"rows": []})
            self.assertEqual(os.listdir(d), ["places.json"])

    def test_write_creates_missing_folder(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "a", "b", "places.json")
            ew.write_output(out, {"rows": []})
            self.assertEqual(os.listdir(os.path.join(d, "a", "b")), ["places.json"])

    def test_main_write_failure_exits_1(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "places.json")
            key = os.path.join(d, "k.txt")
            with open(key, "w") as f:
                f.write("00")
            buf = io.StringIO()
            with mock.patch.object(ew, "extract", return_value=({"rows": [object()]}, [])):
                with contextlib.redirect_stdout(buf):
                    code = ew.main(["--game", d, "--out", out, "--key", key])
            self.assertEqual(code, 1)
            self.assertEqual(os.listdir(d), ["k.txt"])


class HygieneTests(unittest.TestCase):
    def test_no_personal_paths(self):
        drive = re.compile("[A-Za-z]" + ":" + "[\\\\/]")
        others = ("/Us" + "ers/", "/ho" + "me/")
        user = getpass.getuser().lower()
        checked = 0
        for dp, dns, fns in os.walk(TOOLS):
            dns[:] = [x for x in dns if x != "__pycache__"]
            for fn in fns:
                if fn == "pak_key.local.txt":
                    continue
                with open(os.path.join(dp, fn), encoding="utf-8", errors="replace") as f:
                    text = f.read()
                checked += 1
                self.assertIsNone(drive.search(text), fn)
                for o in others:
                    self.assertNotIn(o, text, fn)
                self.assertNotIn(user, text.lower(), fn)
        self.assertTrue(os.path.exists(os.path.join(TOOLS, "layouts.json")))
        self.assertGreater(checked, 5)


if __name__ == "__main__":
    unittest.main()
