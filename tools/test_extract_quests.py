"""Offline tests for the quest relations extractor. Run from the repo root:
python -m unittest discover -s tools -p "test_extract_quests.py"
"""
import contextlib
import io
import json
import os
import struct
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_quests as eq  # noqa: E402
import extract_world as ew  # noqa: E402
import qnml_pak  # noqa: E402
import qnml_rsz  # noqa: E402

INVALID, PLAYER = 1857826560, 2891076981
CHARA = {"101": "ch300101_00", "102": "ch300102_00", "103": "ch300103_00", "104": "ch300104_00",
         "105": "ch300105_00", "106": "ch300106_00", "107": "ch300107_00",
         "1857826560": "Invalid", "2891076981": "ch000000_00"}
R = qnml_rsz.Ref


def inst(i, t, **fields):
    n = qnml_rsz.Inst(i, t)
    n.fields = fields
    return n


class RelationTests(unittest.TestCase):
    def test_paths(self):
        self.assertEqual(eq.scene_path(20090), "natives/STM/AppData/Quest/qu02/qu020090/Resident.scn.21")
        self.assertEqual(eq.scene_path(10010), "natives/STM/AppData/Quest/qu01/qu010010/Resident.scn.21")
        self.assertEqual(eq.journal_path(20090),
                         "natives/STM/AppSystem/Quest/UserData/QuestLog/qu020090_log.user.3")
        self.assertEqual(eq.CONTEXT_PATH, "natives/STM/AppSystem/Quest/UserData/QuestContext.user.3")

    def test_kept_chara(self):
        self.assertEqual(eq.kept_chara(CHARA), {101, 102, 103, 104, 105, 106, 107})

    def test_scene_every_field(self):
        kept = eq.kept_chara(CHARA)
        insts = []

        def add(t, **f):
            insts.append(inst(len(insts) + 1, t, **f))
        npc_values = [101, 102, 103, 104, [105, 0], [106, INVALID]]
        for (t, f), v in zip(eq.NPC_FIELDS, npc_values):
            add(t, **{f: v})
        add("app.quest.action.PlayEventData.TalkDirectSetting.TalkNPC", _NpcID=PLAYER)
        add("app.quest.action.NpcControlParam", _NpcID=999)
        add("app.Other", _NpcID=107, _ItemID=299)
        for (t, f), v in zip(eq.ITEM_FIELDS, range(201, 205)):
            add(t, **{f: v})
        add("app.quest.condition.CheckDeliverParam", _ItemID=0)
        add("app.quest.condition.CheckDeliverParam", _ItemID=-1)
        self.assertEqual(eq.scene_relations(insts, kept),
                         ({101, 102, 103, 104, 105, 106}, {201, 202, 203, 204}))

    def test_scene_given_and_used_items_left_out(self):
        kept = eq.kept_chara(CHARA)
        insts = [inst(1, "app.quest.action.ItemSetting.Item", _ItemId=211),
                 inst(2, "app.quest.condition.CheckPlayerActionParam", _ItemID=212),
                 inst(3, "app.quest.action.UniqueAction046Param", _ItemID=213)]
        self.assertEqual(eq.scene_relations(insts, kept), (set(), set()))

    def test_scene_holder_and_job_master_fields(self):
        kept = eq.kept_chara(CHARA)
        insts = [inst(1, "app.quest.condition.CheckNPCHolderTypeParam", _CharaID=107),
                 inst(2, "app.quest.condition.CheckJobMasterItemParam", _ItemID=207)]
        self.assertEqual(eq.scene_relations(insts, kept), ({107}, {207}))

    def test_context_cast_and_deliveries(self):
        kept = eq.kept_chara(CHARA)
        insts = [
            inst(1, "app.QuestContextData.ContextData", _IDValue=20090, CastNPCIDs=[101, 101, PLAYER, 102]),
            inst(2, "app.QuestContextData.ContextData", _IDValue=20090, CastNPCIDs=[103]),
            inst(3, "app.QuestContextData.ContextData", _IDValue=-1, CastNPCIDs=[104]),
            inst(4, "app.QuestContextData.DeliverData", _IDValue=20090, _Delivers=[R(5)]),
            inst(5, "app.QuestDeliver", _Item=R(6)),
            inst(6, "app.QuestDeliver.ItemData", _Value=[R(7), R(8)]),
            inst(7, "app.QuestDeliver.ItemData.ValueInfo", _ItemID=[300, 0]),
            inst(8, "app.QuestDeliver.ItemData.ValueInfo", _ItemID=[301]),
            inst(9, "app.QuestContextData.DeliverData", _IDValue=20141, _Delivers=[]),
        ]
        self.assertEqual(eq.context_relations(insts, kept),
                         {20090: {"cast": {101, 102, 103}, "items": {300, 301}},
                          20141: {"cast": set(), "items": set()}})

    def test_journal_dest(self):
        kept = eq.kept_chara(CHARA)
        t = "app.QuestLogResource.QuestLogTaskDestination"
        pairs = [(101, 2308), (101, 2308), (INVALID, 2313), (102, -1), (INVALID, 0), (PLAYER, 0)]
        insts = [inst(i + 1, t, _CharaID=c, _KeyLocation=k) for i, (c, k) in enumerate(pairs)]
        self.assertEqual(eq.journal_dest(insts, kept),
                         [{"cid": None, "key": 2313}, {"cid": 101, "key": 2308},
                          {"cid": 102, "key": None}])

    def test_quest_entry(self):
        self.assertEqual(eq.quest_entry({"cast": {102, 101}, "items": {300}}, None, []),
                         {"cast": [101, 102], "npcs": [], "items": [300], "dest": [], "decoded": False})
        self.assertEqual(eq.quest_entry(None, ({103}, {201, 300}), [{"cid": 101, "key": 2308}]),
                         {"cast": [], "npcs": [103], "items": [201, 300],
                          "dest": [{"cid": 101, "key": 2308}], "decoded": True})


H = {name: 0x5100 + n for n, name in enumerate((
    "app.quest.action.NpcControlParam", "app.quest.condition.CheckHasItemParam.ItemInfo",
    "app.QuestContextData.ContextData", "app.QuestContextData.DeliverData", "app.QuestDeliver",
    "app.QuestDeliver.ItemData", "app.QuestDeliver.ItemData.ValueInfo",
    "app.QuestLogResource.QuestLogTaskDestination"))}


def _type(name, *fields):
    return "%x" % H[name], {"name": name, "fields": [list(f) for f in fields]}


QLAYOUTS = {"types": dict([
    _type("app.quest.action.NpcControlParam", ("_NpcID", "U32", 4, 4, False)),
    _type("app.quest.condition.CheckHasItemParam.ItemInfo", ("_ID", "S32", 4, 4, False)),
    _type("app.QuestContextData.ContextData", ("_IDValue", "S32", 4, 4, False),
          ("CastNPCIDs", "U32", 4, 4, True)),
    _type("app.QuestContextData.DeliverData", ("_IDValue", "S32", 4, 4, False),
          ("_Delivers", "Object", 4, 4, True)),
    _type("app.QuestDeliver", ("_Item", "Object", 4, 4, False)),
    _type("app.QuestDeliver.ItemData", ("_Value", "Object", 4, 4, True)),
    _type("app.QuestDeliver.ItemData.ValueInfo", ("_ItemID", "S32", 4, 4, True)),
    _type("app.QuestLogResource.QuestLogTaskDestination", ("_CharaID", "U32", 4, 4, False),
          ("_KeyLocation", "S32", 4, 4, False)),
]), "enums": {"CharacterID": CHARA}}


def rsz_block(insts, base):
    """An RSZ block (offsets relative to the block); insts is [(type hash, [value, ...])]."""
    assert base % 4 == 0
    n = len(insts)
    inst_off = 48 + 4 * n
    data_off = inst_off + 8 * (n + 1)
    out = struct.pack("<4sIiiiiQQQ", b"RSZ" + bytes(1), 16, n, n + 1, 0, 0, inst_off, data_off, data_off)
    out += b"".join(struct.pack("<i", i + 1) for i in range(n))
    out += struct.pack("<II", 0, 0) + b"".join(struct.pack("<II", t, 0) for t, _ in insts)
    for _, values in insts:
        for v in values:
            if isinstance(v, list):
                out += struct.pack("<I", len(v)) + b"".join(struct.pack("<I", e & 0xFFFFFFFF) for e in v)
            else:
                out += struct.pack("<I", v & 0xFFFFFFFF)
    return out


def usr_file(insts):
    return (struct.pack("<4siiiQQQ", b"USR" + bytes(1), 0, 0, 0, 40, 40, 48) + bytes(8)
            + rsz_block(insts, 48))


def scn_file(insts):
    return (struct.pack("<4s5i5Q", b"SCN" + bytes(1), 0, 0, 0, 0, 0, 64, 64, 64, 64, 64)
            + rsz_block(insts, 64))


def h(name):
    return H[name]


def ctx_inst(qid, cast):
    return (h("app.QuestContextData.ContextData"), [qid, cast])


def dest_inst(cid, key):
    return (h("app.QuestLogResource.QuestLogTaskDestination"), [cid, key])


class FakePak:
    files = {}
    reads = []
    closed = 0
    total = 7
    fingerprint = 9

    def __init__(self, path, key_hex):
        pass

    def read(self, path):
        FakePak.reads.append(path)
        return FakePak.files.get(path)

    def close(self):
        FakePak.closed += 1


def e2e_files():
    context = usr_file([
        ctx_inst(20090, [101]), ctx_inst(20141, [102]),
        (h("app.QuestContextData.DeliverData"), [20141, [4]]),
        (h("app.QuestDeliver"), [5]),
        (h("app.QuestDeliver.ItemData"), [[6]]),
        (h("app.QuestDeliver.ItemData.ValueInfo"), [[400]]),
    ])
    scene_a = scn_file([(h("app.quest.action.NpcControlParam"), [103]),
                        (h("app.quest.condition.CheckHasItemParam.ItemInfo"), [201])])
    scene_b = scn_file([(h("app.quest.action.NpcControlParam"), [103])]) + bytes(1)
    return {
        eq.CONTEXT_PATH: context,
        eq.scene_path(20090): scene_a,
        eq.scene_path(10040): scene_b,
        eq.journal_path(20090): usr_file([dest_inst(101, 2308)]),
        eq.journal_path(30010): usr_file([dest_inst(104, 2400)]),
    }


E2E_OUT = {"version": 1, "pak": "7:9", "quests": {
    "10040": {"cast": [], "npcs": [], "items": [], "dest": [], "decoded": False},
    "20090": {"cast": [101], "npcs": [103], "items": [201], "dest": [{"cid": 101, "key": 2308}],
              "decoded": True},
    "20141": {"cast": [102], "npcs": [], "items": [400], "dest": [], "decoded": False}}}


class ExtractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.game = self.tmp.name
        open(os.path.join(self.game, "re_chunk_000.pak"), "wb").close()
        FakePak.files = e2e_files()
        FakePak.reads = []
        FakePak.closed = 0
        for p in (mock.patch.object(qnml_pak, "Pak", FakePak),
                  mock.patch.object(eq, "MIN_SCENES", 1),
                  mock.patch.object(eq, "MIN_DECODED", 1)):
            p.start()
            self.addCleanup(p.stop)

    def test_extract_end_to_end(self):
        out, lines = eq.extract(self.game, "00", QLAYOUTS)
        self.assertEqual(out, E2E_OUT)
        self.assertEqual(list(out["quests"]), ["10040", "20090", "20141"])
        self.assertEqual(lines[0], "quests 3, scenes 2, decoded 1, journals 2")
        self.assertEqual(lines[1], "entries: cast 2, npcs 1, items 2, dest 1")
        self.assertTrue(lines[2].startswith("undecoded 10040: "))
        self.assertEqual(len(lines), 3)
        self.assertEqual(FakePak.closed, 1)
        for p in (eq.scene_path(10000), eq.scene_path(39999), eq.journal_path(39999)):
            self.assertIn(p, FakePak.reads)
        for p in (eq.scene_path(9999), eq.scene_path(40000)):
            self.assertNotIn(p, FakePak.reads)

    def test_self_checks(self):
        del FakePak.files[eq.CONTEXT_PATH]
        with self.assertRaises(ew.ExtractError) as cm:
            eq.extract(self.game, "00", QLAYOUTS)
        self.assertEqual(str(cm.exception), "quest context file missing from the archive")
        self.assertEqual(FakePak.closed, 1)

        FakePak.files = e2e_files()
        del FakePak.files[eq.scene_path(10040)]
        with mock.patch.object(eq, "MIN_SCENES", 100):
            with self.assertRaises(ew.ExtractError) as cm:
                eq.extract(self.game, "00", QLAYOUTS)
        self.assertEqual(str(cm.exception), "only 1 quest scenes found (expected at least 100)")

        FakePak.files = e2e_files()
        with mock.patch.object(eq, "MIN_DECODED", 2):
            with self.assertRaises(ew.ExtractError) as cm:
                eq.extract(self.game, "00", QLAYOUTS)
        self.assertEqual(str(cm.exception), ew.LAYOUT_MSG)

        FakePak.files = e2e_files()
        FakePak.files[eq.journal_path(20090)] += bytes(1)
        with self.assertRaises(ew.ExtractError) as cm:
            eq.extract(self.game, "00", QLAYOUTS)
        self.assertEqual(str(cm.exception), ew.LAYOUT_MSG)

        FakePak.files = e2e_files()
        with open(os.path.join(self.game, "re_chunk_000.pak.patch_001.pak"), "wb") as f:
            f.write(struct.pack("<4sBBHII", b"KPKA", 4, 1, 0, 1, 0))
        with self.assertRaises(ew.ExtractError) as cm:
            eq.extract(self.game, "00", QLAYOUTS)
        self.assertIn("re_chunk_000.pak.patch_001.pak", str(cm.exception))

    def test_main(self):
        out_path = os.path.join(self.game, "quests.json")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = eq.main(["--game", self.game, "--out", out_path,
                            "--key", os.path.join(self.game, "no_such_key.txt")])
        self.assertEqual((code, buf.getvalue()), (1, ew.KEY_MSG + "\n"))
        self.assertFalse(os.path.exists(out_path))

        key = os.path.join(self.game, "k.txt")
        with open(key, "w") as f:
            f.write("00")
        buf = io.StringIO()
        with mock.patch.object(eq, "load_layouts", return_value=QLAYOUTS):
            with contextlib.redirect_stdout(buf):
                code = eq.main(["--game", self.game, "--out", out_path, "--key", key])
        self.assertEqual(code, 0)
        with open(out_path, encoding="utf-8") as f:
            self.assertEqual(json.load(f), E2E_OUT)
        self.assertEqual(buf.getvalue().splitlines()[-1], "quests written: 3")


if __name__ == "__main__":
    unittest.main()
