"""Offline tests for the extractor modules. Run from the repo root:
python -m unittest discover -s tools -p "test_*.py"
"""
import contextlib
import collections
import getpass
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


def build_scene(a, b, pad=0):
    """A scene file holding one t.Pair instance; pad bytes sit between header and RSZ block."""
    hdr = struct.pack("<4s5i5Q", b"SCN\0", 0, 0, 0, 0, 0, 64, 64, 64, 64, 64 + pad)
    return hdr + b"\0" * pad + build_blob(a, b)[48:]


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

    def test_rsz_scene(self):
        insts = qnml_rsz.decode(build_scene(7, -9), PAIR_LAYOUTS)
        self.assertEqual([(i.type, i.fields) for i in insts], [("t.Pair", {"a": 7, "b": -9})])
        with self.assertRaises(qnml_rsz.DecodeError):
            qnml_rsz.decode(build_scene(7, -9) + b"\0", PAIR_LAYOUTS)

    def test_rsz_scene_uses_the_header_offset(self):
        # a decoy RSZ magic in the padding must not be taken for the block
        s = build_scene(3, 4, pad=16)
        s = s[:64] + b"RSZ\0" + s[68:]
        self.assertEqual(qnml_rsz.decode(s, PAIR_LAYOUTS)[0].fields, {"a": 3, "b": 4})

    def test_rsz_unknown_container(self):
        with self.assertRaises(qnml_rsz.DecodeError) as cm:
            qnml_rsz.decode(b"XYZ\0" + build_blob(1, 2)[4:], PAIR_LAYOUTS)
        self.assertEqual(str(cm.exception), "not a user-data or scene file")

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
    def test_non_chest_item_placement_relation(self):
        def inst(i, t, path=None, **fields):
            n = qnml_rsz.Inst(i, t, path)
            n.fields = fields
            return n
        R = qnml_rsz.Ref
        table = [
            inst(1, "app.GenerateTable", _GimmickSetInfo=R(2)),
            inst(2, "app.GenerateTable.SetInfo", _BasicRowDatas=[R(3)]),
            inst(3, "app.GenerateRowData", _ManualSetGuid="00000000-0000-0000-0000-000000000123",
                 _GimmickID=163, _ManualPos=(1.25, 2.5, 3.75), _Container=R(4)),
            inst(4, "app.Container", _GimmickSetting=R(5), _SetFlagSetting=R(6)),
            inst(5, "app.GimmickSetting", _ParamId=7),
            inst(6, "app.GenerateSetting.SetFlagSettingData", _QuestFlagInfos=R(7)),
            inst(7, "app.GenerateManager.QuestFlagInfos", _CheckType=0, _Infos=[R(8)]),
            inst(8, ew.QUEST_FLAG, _QuestID=11040, _IsFinishCheck=False),
        ]
        listing = [inst(1, "app.GenerateTableData", path="normal.user"),
                   inst(2, "app.GenerateTableListData", _NormalTableList=[R(1)],
                        _SubQuestTableList=[], _MainQuestTableList=[], _RandomNormalTableList=[])]
        params = {7: {"items": [(999, 9)], "trap": False, "pawn": False}}
        pickup_params = ew.pickup_params_of([
            inst(1, "app.Gm82_000Param", ParamId=7, ItemId=500, ItemNum=2)])
        rows, *_ = ew.collect_rows({"normal.user": table, "list.user": listing}, params, set(), {},
                                   pickup_params=pickup_params)
        item = next(row for row in rows if row["k"] == "item")
        self.assertEqual(item, {"k": "item", "uid": "00000000-0000-0000-0000-000000000123",
                                "id": 500, "n": 2, "x": 1.2, "y": 2.5, "z": 3.8,
                                "src": "normal", "gate": {"check": 0, "conditions": [
                                    {"kind": "quest", "qid": 11040, "finish": False}]}})

    def test_chest_param_overlap_cannot_fabricate_pickup_output(self):
        def inst(i, t, path=None, **fields):
            n = qnml_rsz.Inst(i, t, path)
            n.fields = fields
            return n
        R = qnml_rsz.Ref
        table = [inst(1, "app.GenerateTable", _GimmickSetInfo=R(2)),
                 inst(2, "app.GenerateTable.SetInfo", _BasicRowDatas=[R(3)]),
                 inst(3, "app.GenerateRowData", _ManualSetGuid="00000000-0000-0000-0000-000000000123",
                      _GimmickID=163, _ManualPos=(1.0, 2.0, 3.0), _Container=R(4)),
                 inst(4, "app.Container", _GimmickSetting=R(5)),
                 inst(5, "app.GimmickSetting", _ParamId=7)]
        listing = [inst(1, "app.GenerateTableData", path="normal.user"),
                   inst(2, "app.GenerateTableListData", _NormalTableList=[R(1)],
                        _SubQuestTableList=[], _MainQuestTableList=[], _RandomNormalTableList=[])]
        rows, *_ = ew.collect_rows({"normal.user": table, "list.user": listing},
                                   {7: {"items": [(500, 2)], "trap": False, "pawn": False}}, set(), {})
        self.assertEqual(rows, [])

    def test_unknown_gimmick_is_skipped(self):
        rows, *_ = self._one_unrecognized_gimmick()
        self.assertFalse(any(row["k"] == "gimmick" for row in rows))

    @staticmethod
    def _one_unrecognized_gimmick():
        def inst(i, t, path=None, **fields):
            n = qnml_rsz.Inst(i, t, path)
            n.fields = fields
            return n
        R = qnml_rsz.Ref
        table = [inst(1, "app.GenerateTable", _GimmickSetInfo=R(2)),
                 inst(2, "app.GenerateTable.SetInfo", _BasicRowDatas=[R(3)]),
                 inst(3, "app.GenerateRowData", _ManualSetGuid="unknown", _GimmickID=42,
                      _ManualPos=(1.0, 2.0, 3.0), _Container=R(0))]
        listing = [inst(1, "app.GenerateTableData", path="normal.user"),
                   inst(2, "app.GenerateTableListData", _NormalTableList=[R(1)],
                        _SubQuestTableList=[], _MainQuestTableList=[], _RandomNormalTableList=[])]
        return ew.collect_rows({"normal.user": table, "list.user": listing}, {}, set(), {})

    def test_pickup_param_conflicts_are_rejected(self):
        def inst(i, t, **fields):
            n = qnml_rsz.Inst(i, t)
            n.fields = fields
            return n
        data = [inst(1, "app.Gm82_000Param", ParamId=7, ItemId=500, ItemNum=2),
                inst(2, "app.Gm82_000Param", ParamId=7, ItemId=501, ItemNum=1)]
        with self.assertRaises(ew.ExtractError):
            ew.pickup_params_of(data)

    def test_pickup_params_ignore_nonpositive_outputs(self):
        def inst(i, **fields):
            n = qnml_rsz.Inst(i, "app.Gm82_000Param")
            n.fields = fields
            return n
        data = [inst(1, ParamId=7, ItemId=500, ItemNum=2)]
        for i, (item_id, count) in enumerate(((0, 1), (-1, 1), (500, 0), (500, -1)), 2):
            data.append(inst(i, ParamId=7, ItemId=item_id, ItemNum=count))
        self.assertEqual(ew.pickup_params_of(data), {7: {"item": 500, "count": 2}})

    def test_pickup_params_reject_malformed_types(self):
        for field in ("ParamId", "ItemId", "ItemNum"):
            for value in (None, True, 1.5, "1"):
                with self.subTest(field=field, value=value):
                    n = qnml_rsz.Inst(1, "app.Gm82_000Param")
                    n.fields = {"ParamId": 7, "ItemId": 500, "ItemNum": 2}
                    n.fields[field] = value
                    with self.assertRaises(ew.ExtractError):
                        ew.pickup_params_of([n])

    def test_non_chest_item_placement_rejects_bad_identity_output_or_position(self):
        def inst(i, t, path=None, **fields):
            n = qnml_rsz.Inst(i, t, path)
            n.fields = fields
            return n
        R = qnml_rsz.Ref

        def collect(uid, count, position, duplicate=False):
            row_refs = [R(3), R(6)] if duplicate else [R(3)]
            table = [inst(1, "app.GenerateTable", _GimmickSetInfo=R(2)),
                     inst(2, "app.GenerateTable.SetInfo", _BasicRowDatas=row_refs),
                     inst(3, "app.GenerateRowData", _ManualSetGuid=uid, _GimmickID=163,
                          _ManualPos=position, _Container=R(4)),
                     inst(4, "app.Container", _GimmickSetting=R(5)),
                     inst(5, "app.GimmickSetting", _ParamId=7)]
            if duplicate:
                table.extend([inst(6, "app.GenerateRowData", _ManualSetGuid=uid, _GimmickID=163,
                                   _ManualPos=position, _Container=R(7)),
                              inst(7, "app.Container", _GimmickSetting=R(8)),
                              inst(8, "app.GimmickSetting", _ParamId=7)])
            listing = [inst(1, "app.GenerateTableData", path="normal.user"),
                       inst(2, "app.GenerateTableListData", _NormalTableList=[R(1)],
                            _SubQuestTableList=[], _MainQuestTableList=[], _RandomNormalTableList=[])]
            return ew.collect_rows({"normal.user": table, "list.user": listing}, {}, set(), {},
                                   pickup_params={7: {"item": 500, "count": count}})

        cases = (("bad-guid", 1, (1.0, 2.0, 3.0)),
                 ("00000000-0000-0000-0000-000000000123", 0, (1.0, 2.0, 3.0)),
                 ("00000000-0000-0000-0000-000000000123", 1, (1.0, float("nan"), 3.0)))
        for args in cases:
            with self.subTest(args=args), self.assertRaises(ew.ExtractError):
                collect(*args)
        with self.assertRaises(ew.ExtractError):
            collect("00000000-0000-0000-0000-000000000123", 1, (1.0, 2.0, 3.0), duplicate=True)

    def test_gate_schema_and_rejection_boundaries(self):
        def inst(i, t, **fields):
            n = qnml_rsz.Inst(i, t)
            n.fields = fields
            return n
        R = qnml_rsz.Ref
        qtype = "app.GenerateManager.QuestFlagInfos.QuestFlagInfo"
        vtype = "app.GenerateManager.QuestFlagInfos.QuestVariableInfo"
        ctype = "app.QuestVariableCondition"

        def decode(check=0, infos=(), *, qi_fields=None, flag_fields=None, var_fields=None,
                   condition_fields=None, omit_infos=False, omit_check=False,
                   missing_qi=False, missing_sf=False):
            entries = [R(0) if kind == "null" else R(10 + i)
                       for i, kind in enumerate(infos)]
            nodes = {}
            for i, kind in enumerate(infos):
                idx = 10 + i
                if kind == "null":
                    continue
                if kind == "unknown":
                    nodes[idx] = inst(idx, "app.GenerateManager.QuestFlagInfos.Unknown")
                elif kind == "quest":
                    nodes[idx] = inst(idx, qtype, **(flag_fields if flag_fields is not None else {
                        "_QuestID": 30030, "_IsFinishCheck": True}))
                elif kind == "variable":
                    nodes[idx] = inst(idx, vtype, **(var_fields if var_fields is not None else {
                        "_Condition": R(20)}))
                    nodes[20] = inst(20, ctype, **(condition_fields if condition_fields is not None else {
                        "_QuestID": 51010, "_NameHash": 110914987, "_ValueType": 1,
                        "_CompareType": 1, "_BoolValue": True, "_IntValue": 7}))
            if not missing_qi:
                qfields = {} if qi_fields is None else dict(qi_fields)
                if not omit_check:
                    qfields.setdefault("_CheckType", check)
                if not omit_infos:
                    qfields.setdefault("_Infos", entries)
                nodes[2] = inst(2, "app.GenerateManager.QuestFlagInfos", **qfields)
            if not missing_sf:
                nodes[1] = inst(1, "app.GenerateSetting.SetFlagSettingData",
                                **({} if missing_qi else {"_QuestFlagInfos": R(2)}))
            cont = inst(3, "app.Container", **({} if missing_sf else {"_SetFlagSetting": R(1)}))
            all_nodes = [cont] + list(nodes.values())
            by_idx = {node.idx: node for node in all_nodes}
            insts = [by_idx.get(i + 1) or inst(i + 1, "app.Filler") for i in range(max(by_idx))]
            return ew.gate_of(insts, cont)

        self.assertIsNone(decode(missing_sf=True))
        self.assertIsNone(decode(missing_qi=True))
        self.assertIsNone(decode(0, []))
        self.assertIsNone(decode(1, []))
        self.assertEqual(decode(0, ["quest"]), {
            "check": 0, "conditions": [{"kind": "quest", "qid": 30030, "finish": True}]})
        self.assertEqual(decode(1, ["quest"]), {
            "check": 1, "conditions": [{"kind": "quest", "qid": 30030, "finish": True}]})
        self.assertEqual(decode(0, ["variable"]), {
            "check": 0, "conditions": [{"kind": "variable", "qid": 51010,
                "name_hash": 110914987, "value_type": 1, "compare_type": 1,
                "bool_value": True, "int_value": 7}]})
        self.assertEqual(len(decode(1, ["quest", "variable"]) ["conditions"]), 2)

        for fields in ({"_Infos": None}, {"_Infos": "bad"}):
            with self.subTest(infos_shape=fields), self.assertRaises(ew.ExtractError):
                decode(qi_fields=fields)
        with self.assertRaises(ew.ExtractError):
            decode(qi_fields={"_Infos": ["bad"]})
        with self.assertRaises(ew.ExtractError):
            decode(omit_infos=True)
        with self.assertRaises(ew.ExtractError):
            decode(omit_check=True, infos=[])
        with self.assertRaises(ew.ExtractError):
            decode(omit_check=True, infos=["quest"])
        for check in (None, True, "0", -1, 2):
            with self.subTest(check=check), self.assertRaises(ew.ExtractError):
                decode(check=check, infos=[])
            with self.subTest(check_nonempty=check), self.assertRaises(ew.ExtractError):
                decode(check=check, infos=["quest"])
        for infos in (["null"], ["unknown"]):
            with self.subTest(infos=infos), self.assertRaises(ew.ExtractError):
                decode(infos=infos)
        for fields in ({"_QuestID": 1}, {"_QuestID": "1", "_IsFinishCheck": True},
                       {"_QuestID": 1, "_IsFinishCheck": 1}):
            with self.subTest(quest_fields=fields), self.assertRaises(ew.ExtractError):
                decode(infos=["quest"], flag_fields=fields)
        for fields in ({}, {"_QuestID": 1}, {"_QuestID": 1, "_NameHash": 2,
                       "_ValueType": 1, "_CompareType": 1, "_BoolValue": True},
                       {"_QuestID": 1, "_NameHash": 2, "_ValueType": True,
                        "_CompareType": 1, "_BoolValue": True, "_IntValue": 4}):
            with self.subTest(variable_fields=fields), self.assertRaises(ew.ExtractError):
                decode(infos=["variable"], condition_fields=fields)
        for fields in ({}, {"_Condition": R(0)}, {"_Condition": None}):
            with self.subTest(variable_element_fields=fields), self.assertRaises(ew.ExtractError):
                decode(infos=["variable"], var_fields=fields)

    def test_phase_tag(self):
        self.assertEqual(ew.phase_of("a/DNG_01/_beforeSeason4/x.user"), "beforeseason4")
        self.assertEqual(ew.phase_of("a/b/BEFORESEASON4_season4/x.user"), "beforeseason4")
        self.assertEqual(ew.phase_of("a/b/BeforeSeason4_season4/x.user"), "beforeseason4")
        self.assertEqual(ew.phase_of("a/b__Season4/x.user"), "season4")
        self.assertEqual(ew.phase_of("a/b_season4/x.user"), "season4")
        self.assertIsNone(ew.phase_of("a/b/BeforeSeason5/x.user"))
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

    def test_quest_table_owner_ids(self):
        def inst(i, t, path=None, **fields):
            n = qnml_rsz.Inst(i, t, path)
            n.fields = fields
            return n
        R = qnml_rsz.Ref

        def collect(src, path):
            table = [inst(1, "app.GenerateTable", _EnemySetInfo=R(2)),
                     inst(2, "app.GenerateTable.SetInfo", _BasicRowDatas=[R(3)]),
                     inst(3, "app.GenerateRowData", _ManualSetGuid="g1", _GimmickID=0,
                          _CharaID=5, _ManualPos=(1.0, 2.0, 3.0), _Container=R(0))]
            lists = [inst(1, "app.GenerateTableData", path=path),
                     inst(2, "app.GenerateTableListData")]
            # Supply all four lists; the chosen list contains the table.
            lists[1].fields.update({"_NormalTableList": [], "_SubQuestTableList": [],
                                    "_MainQuestTableList": [], "_RandomNormalTableList": []})
            field = {"normal": "_NormalTableList", "subquest": "_SubQuestTableList",
                     "mainquest": "_MainQuestTableList", "random": "_RandomNormalTableList"}[src]
            lists[1].fields[field] = [R(1)]
            rows, *_ = ew.collect_rows({path: table, "l.user": lists}, {}, set(), {})
            return rows[0]

        self.assertEqual(collect("normal", "a/b/t.user")["src"], "normal")
        self.assertNotIn("table_qid", collect("random", "a/b/t.user"))
        for src in ("subquest", "mainquest"):
            with self.subTest(src=src):
                self.assertEqual(collect(src, "a/qu123456/t.user")["table_qid"], 123456)
                for path in ("a/qu12345/t.user", "a/qu1234567/t.user", "a/t.user"):
                    with self.assertRaises(ew.ExtractError):
                        collect(src, path)

    def test_conditional_fixture_matches_synthetic_rows(self):
        def inst(i, t, path=None, **fields):
            n = qnml_rsz.Inst(i, t, path)
            n.fields = fields
            return n
        R = qnml_rsz.Ref
        qflag = "app.GenerateManager.QuestFlagInfos.QuestFlagInfo"
        qvar = "app.GenerateManager.QuestFlagInfos.QuestVariableInfo"
        normal = [inst(1, "app.GenerateTable", _EnemySetInfo=R(2)),
                  inst(2, "app.GenerateTable.SetInfo", _BasicRowDatas=[R(3)]),
                  inst(3, "app.GenerateRowData", _ManualSetGuid="00000000-0000-0000-0000-000000000001",
                       _GimmickID=0, _CharaID=5, _ManualPos=(1.0, 2.0, 3.0), _Container=R(0))]
        quest = [inst(1, "app.GenerateTable", _EnemySetInfo=R(2)),
                 inst(2, "app.GenerateTable.SetInfo", _BasicRowDatas=[R(3)]),
                 inst(3, "app.GenerateRowData", _ManualSetGuid="00000000-0000-0000-0000-000000000002",
                      _GimmickID=0, _CharaID=6, _ManualPos=(10.0, 2.0, 3.0), _Container=R(4)),
                 inst(4, "app.Container", _SetFlagSetting=R(5)),
                 inst(5, "app.GenerateSetting.SetFlagSettingData", _QuestFlagInfos=R(6)),
                 inst(6, "app.GenerateManager.QuestFlagInfos", _CheckType=0, _Infos=[R(7), R(8)]),
                 inst(7, qflag, _QuestID=11040, _IsFinishCheck=False),
                 inst(8, qvar, _Condition=R(9)),
                 inst(9, "app.QuestVariableCondition", _QuestID=51010, _NameHash=110914987,
                      _ValueType=1, _CompareType=1, _BoolValue=True, _IntValue=0)]
        chest = [inst(1, "app.GenerateTable", _GimmickSetInfo=R(2)),
                 inst(2, "app.GenerateTable.SetInfo", _BasicRowDatas=[R(3)]),
                 inst(3, "app.GenerateRowData", _ManualSetGuid="00000000-0000-0000-0000-000000000003",
                      _GimmickID=10, _ManualPos=(30.0, 2.0, 4.0), _Container=R(4)),
                 inst(4, "app.Container", _GimmickSetting=R(5), _SetFlagSetting=R(6)),
                 inst(5, "app.GimmickSetting", _ParamId=1),
                 inst(6, "app.GenerateSetting.SetFlagSettingData", _QuestFlagInfos=R(7)),
                 inst(7, "app.GenerateManager.QuestFlagInfos", _CheckType=1, _Infos=[R(8)]),
                 inst(8, qflag, _QuestID=11040, _IsFinishCheck=False)]
        listing = [inst(1, "app.GenerateTableData", path="a-normal.user"),
                   inst(2, "app.GenerateTableData", path="manual/beforeseason4/qu020082/c-quest.user"),
                   inst(3, "app.GenerateTableData", path="b-chest.user"),
                   inst(4, "app.GenerateTableListData", _NormalTableList=[R(1), R(3)],
                        _SubQuestTableList=[R(2)], _MainQuestTableList=[], _RandomNormalTableList=[])]
        rows, *_ = ew.collect_rows({"a-normal.user": normal, "b-chest.user": chest,
                                    "manual/beforeseason4/qu020082/c-quest.user": quest,
                                    "list.user": listing},
                                   {1: {"items": [], "trap": False, "pawn": False}}, set(),
                                   {"5": "ch5", "6": "ch6"})
        order = {"chest": 0, "token": 1, "beetle": 2, "chara": 3}
        rows.sort(key=lambda r: (order[r["k"]], r["uid"]))
        fixture_path = os.path.join(os.path.dirname(TOOLS), "tests", "fixtures",
                                    "conditional_places_v2.json")
        with open(fixture_path, encoding="utf-8") as f:
            expected = json.load(f)
        self.assertEqual({"version": 2, "rows": rows}, expected)

    def test_generated_conditional_data_oracle(self):
        path = os.path.join(os.path.dirname(TOOLS), "data", "Clairvoyance_places.json")
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        self.assertEqual(data["version"], 2)
        chara = [row for row in data["rows"] if row["k"] == "chara"]
        self.assertEqual(len(chara), 3248)
        source_counts = collections.Counter(row["src"] for row in chara)
        self.assertEqual(source_counts["normal"], 3035)
        self.assertEqual(source_counts["subquest"] + source_counts["mainquest"], 213)
        quest_rows = [row for row in chara if row["src"] in ("subquest", "mainquest")]
        self.assertTrue(all(type(row.get("table_qid")) is int for row in quest_rows))
        self.assertEqual(len({row["table_qid"] for row in quest_rows}), 29)
        self.assertFalse(any(row.get("phase") == "season5" for row in chara))
        phase_rows = [row for row in chara if "phase" in row]
        self.assertEqual(len(phase_rows), 351)
        self.assertEqual(sum("gate" in row for row in phase_rows), 336)
        unphased_normal = [row for row in chara if row["src"] == "normal" and "phase" not in row]
        quest_gates = [row for row in unphased_normal if "gate" in row and
                       any(c["kind"] == "quest" for c in row["gate"]["conditions"])]
        variable_gates = [row for row in unphased_normal if "gate" in row and
                          any(c["kind"] == "variable" for c in row["gate"]["conditions"])]
        # Includes two BeforeSeason5 path rows, which intentionally emit no phase tag.
        self.assertEqual(len(quest_gates), 493)
        all_normal_quest_gates = [row for row in chara if row["src"] == "normal" and
                                  "gate" in row and any(c["kind"] == "quest"
                                  for c in row["gate"]["conditions"])]
        self.assertEqual(len(all_normal_quest_gates), 829)
        self.assertEqual(len(variable_gates), 15)

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
                    {1: {"items": [(500, 2), (600, 3)], "trap": False, "pawn": False}}, set(), {})
                self.assertEqual(len(rows), 1)
                self.assertEqual((rows[0]["k"], rows[0]["id"], rows[0]["items"]),
                                 ("chest", gid, [{"id": 500, "n": 2}, {"id": 600, "n": 3}]))
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
                extra = [inst(base + n * 10 + 1, "app.GenerateSetting.SetFlagSettingData", _QuestFlagInfos=R(base + n * 10 + 2)),
                         inst(base + n * 10 + 2, "app.GenerateManager.QuestFlagInfos", _CheckType=check_type,
                              _Infos=[R(base + n * 10 + 3 + j) for j in range(len(infos))])]
                for j, (t, f) in enumerate(infos):
                    if t == QV:
                        extra.append(inst(base + n * 10 + 3 + j, t,
                                          _Condition=R(base + n * 10 + 8)))
                        extra.append(inst(base + n * 10 + 8, "app.QuestVariableCondition",
                                          **(f or {"_QuestID": 51010, "_NameHash": 110914987,
                                                  "_ValueType": 1, "_CompareType": 1,
                                                  "_BoolValue": True, "_IntValue": 0})))
                    else:
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
        self.assertEqual(r["all"]["gate"], {"check": 0, "conditions": [
            {"kind": "quest", "qid": 11020, "finish": True}]})
        self.assertEqual(r["any"]["gate"], {"check": 1, "conditions": [
            {"kind": "quest", "qid": 5, "finish": False},
            {"kind": "quest", "qid": 6, "finish": True}]})
        self.assertEqual(r["var"]["gate"], {"check": 0, "conditions": [
            {"kind": "variable", "qid": 51010, "name_hash": 110914987,
             "value_type": 1, "compare_type": 1, "bool_value": True, "int_value": 0}]})
        self.assertTrue(r["trap"]["trap"])
        self.assertNotIn("pawn", r["trap"])
        self.assertTrue(r["pawn"]["pawn"])
        self.assertEqual((kinds["gate"], kinds["trap"], kinds["pawn"]), (3, 1, 1))
        with self.assertRaises(ew.ExtractError):
            ew.collect_rows({"t.user": full, "l.user": lst}, params, {2}, {})
        ew.collect_rows({"t.user": full, "l.user": lst}, params, {99}, {})

    def test_key_locations_and_unknown_element(self):
        def inst(i, t, path=None, **fields):
            n = qnml_rsz.Inst(i, t, path)
            n.fields = fields
            return n
        R = qnml_rsz.Ref
        table = [inst(1, "app.GenerateTable", _GimmickSetInfo=R(2)),
                 inst(2, "app.GenerateTable.SetInfo", _BasicRowDatas=[R(3), R(4)]),
                 inst(3, "app.GenerateRowData", _GimmickID=10, _ManualSetGuid="k5",
                      _ManualPos=(1.0, 2.0, 3.0), _Container=R(6)),
                 inst(4, "app.GenerateRowData", _GimmickID=10, _ManualSetGuid="k0",
                      _ManualPos=(1.0, 2.0, 3.0), _Container=R(7)),
                 inst(5, "app.GenerateRowData", _GimmickID=10, _ManualSetGuid="unk",
                      _ManualPos=(1.0, 2.0, 3.0), _Container=R(8)),
                 inst(6, "app.Container", _GimmickSetting=R(9)),
                 inst(7, "app.Container", _GimmickSetting=R(10)),
                 inst(8, "app.Container", _GimmickSetting=R(10), _SetFlagSetting=R(11)),
                 inst(9, "app.GimmickSetting", _ParamId=1, _KeyLocationId=5),
                 inst(10, "app.GimmickSetting", _ParamId=1, _KeyLocationId=0),
                 inst(11, "app.GenerateSetting.SetFlagSettingData", _QuestFlagInfos=R(12)),
                 inst(12, "app.GenerateManager.QuestFlagInfos", _CheckType=0, _Infos=[R(13)]),
                 inst(13, "app.GenerateManager.QuestFlagInfos.SomethingNew")]
        full = list(table)
        lst = [inst(1, "app.GenerateTableData", path="t.user"),
               inst(2, "app.GenerateTableListData", _NormalTableList=[R(1)], _SubQuestTableList=[],
                    _MainQuestTableList=[], _RandomNormalTableList=[])]
        params = {1: {"items": [], "trap": False, "pawn": False}}
        rows, _unj, _ids, kinds = ew.collect_rows({"t.user": full, "l.user": lst}, params, set(), {})
        r = {x["uid"]: x for x in rows}
        self.assertEqual(kinds["key locations"], 1)
        self.assertNotIn("key locations", r["k5"])
        self.assertEqual(kinds["gate"], 0)
        bad = list(full)
        bad[1] = inst(2, "app.GenerateTable.SetInfo", _BasicRowDatas=[R(3), R(4), R(5)])
        with self.assertRaises(ew.ExtractError):
            ew.collect_rows({"t.user": bad, "l.user": lst}, params, set(), {})

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
                if fn.endswith(".local.txt"):
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
