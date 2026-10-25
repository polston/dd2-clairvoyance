"""Offline extractor: reads the installed game's archive and writes the quests file.

Usage: python tools/extract_quests.py --game <game folder> --out <file> [--key <file>]

Prints counts only. Exit 0 on success; exit 1 with one reason line when any self-check fails
(no output file is written then).
"""
import argparse
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_world as ew  # noqa: E402
import key_check  # noqa: E402
import qnml_pak  # noqa: E402
import qnml_rsz  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CONTEXT_PATH = "natives/STM/AppSystem/Quest/UserData/QuestContext.user.3"
QID_FIRST, QID_LAST = 10000, 39999
MIN_SCENES = 100
MIN_DECODED = 100

NPC_FIELDS = (
    ("app.quest.action.NpcControlParam", "_NpcID"),
    ("app.quest.action.PlayEventData.TalkDirectSetting.TalkNPC", "_NpcID"),
    ("app.quest.action.NpcWarpSetting.TargetInfo", "NpcID"),
    ("app.quest.condition.CheckNPCArrivedLocationParam", "_CharaID"),
    ("app.quest.action.EnemyBattleSetting", "_NpcIDs"),
    ("app.quest.action.BattleSetting", "_HostileNPCIDs"),
)
ITEM_FIELDS = (
    ("app.quest.condition.CheckHasItemParam.ItemInfo", "_ID"),
    ("app.quest.condition.CheckDeliverParam", "_ItemID"),
    ("app.quest.action.ItemSetting.Item", "_ItemId"),
    ("app.quest.condition.CheckEquipItemParam", "_ItemID"),
    ("app.quest.condition.CheckPlayerActionParam", "_ItemID"),
    ("app.quest.action.UniqueAction046Param", "_ItemID"),
)
CONTEXT_TYPE = "app.QuestContextData.ContextData"
DELIVER_TYPE = "app.QuestContextData.DeliverData"
DEST_TYPE = "app.QuestLogResource.QuestLogTaskDestination"
NOT_CHARA = ("Invalid", "ch000000_00")


def scene_path(qid):
    return "natives/STM/AppData/Quest/qu%02d/qu%06d/Resident.scn.21" % (qid // 10000, qid)


def journal_path(qid):
    return "natives/STM/AppSystem/Quest/UserData/QuestLog/qu%06d_log.user.3" % qid


def _list(v):
    return v if isinstance(v, list) else [v]


def kept_chara(chara_enum):
    """The character ids that name a real non-player character."""
    return {int(k) for k, name in chara_enum.items() if name not in NOT_CHARA}


def scene_relations(insts, kept):
    """(npc ids in kept, item ids above 0) from the listed instance types of one scene."""
    npc_fields = dict(NPC_FIELDS)
    item_fields = dict(ITEM_FIELDS)
    npcs, items = set(), set()
    for i in insts:
        f = npc_fields.get(i.type)
        if f is not None:
            npcs.update(v for v in _list(i.fields.get(f, [])) if v in kept)
        f = item_fields.get(i.type)
        if f is not None:
            items.update(v for v in _list(i.fields.get(f, [])) if v > 0)
    return npcs, items


def context_relations(insts, kept):
    """{quest id: {"cast": set, "items": set}} from the quest context file."""
    out = {}
    for i in insts:
        if i.type not in (CONTEXT_TYPE, DELIVER_TYPE):
            continue
        qid = i.fields.get("_IDValue", 0)
        if qid <= 0:
            continue
        entry = out.setdefault(qid, {"cast": set(), "items": set()})
        entry["cast"].update(v for v in _list(i.fields.get("CastNPCIDs", [])) if v in kept)
        if i.type != DELIVER_TYPE:
            continue
        for dref in _list(i.fields.get("_Delivers", [])):
            deliver = qnml_rsz.deref(insts, dref)
            data = qnml_rsz.deref(insts, deliver.fields.get("_Item")) if deliver else None
            if data is None:
                continue
            for vref in _list(data.fields.get("_Value", [])):
                info = qnml_rsz.deref(insts, vref)
                if info is not None:
                    entry["items"].update(v for v in _list(info.fields.get("_ItemID", [])) if v > 0)
    return out


def journal_dest(insts, kept):
    """The destinations of one quest journal: unique {"cid", "key"}, sorted."""
    found = set()
    for i in insts:
        if i.type != DEST_TYPE:
            continue
        cid = i.fields.get("_CharaID")
        key = i.fields.get("_KeyLocation")
        cid = cid if cid in kept else None
        key = key if key is not None and key > 0 else None
        if cid is not None or key is not None:
            found.add((cid, key))
    ordered = sorted(found, key=lambda t: (t[0] or 0, t[1] or 0))
    return [{"cid": c, "key": k} for c, k in ordered]


def quest_entry(ctx, scene, dest):
    """One quest's output entry from its context relations, scene relations and journal dest."""
    cast = ctx["cast"] if ctx else set()
    items = set(ctx["items"]) if ctx else set()
    npcs = set()
    if scene is not None:
        npcs, scene_items = scene
        items |= scene_items
    return {"cast": sorted(cast), "npcs": sorted(npcs), "items": sorted(items),
            "dest": dest, "decoded": scene is not None}


def load_layouts():
    try:
        with open(os.path.join(HERE, "layouts.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        raise ew.ExtractError("tools/layouts.json missing or unreadable")


def extract(game, key_hex, layouts):
    """Run the whole extraction; returns (output dict, count lines). Raises ExtractError."""
    base, patches = ew.pak_files(game)
    if not os.path.isfile(base):
        raise ew.ExtractError("%s not found in the game folder" % ew.PAK_NAME)
    reason = ew.check_patches(patches)
    if reason:
        raise ew.ExtractError(reason)
    try:
        pak = qnml_pak.Pak(base, key_hex)
    except qnml_pak.PakError as e:
        raise ew.ExtractError(str(e))
    scenes, journals = {}, {}
    try:
        context = pak.read(CONTEXT_PATH)
        if context is None:
            raise ew.ExtractError("quest context file missing from the archive")
        for qid in range(QID_FIRST, QID_LAST + 1):
            data = pak.read(scene_path(qid))
            if data is not None:
                scenes[qid] = data
            data = pak.read(journal_path(qid))
            if data is not None:
                journals[qid] = data
        total, fingerprint = pak.total, pak.fingerprint
    except qnml_pak.PakError as e:
        raise ew.ExtractError(str(e))
    finally:
        pak.close()
    kept = kept_chara(layouts["enums"]["CharacterID"])
    ctx = context_relations(ew._decode(context, layouts), kept)
    dests = {qid: journal_dest(ew._decode(data, layouts), kept) for qid, data in journals.items()}
    relations, undecoded = {}, {}
    for qid, data in scenes.items():
        try:
            relations[qid] = scene_relations(qnml_rsz.decode(data, layouts), kept)
        except qnml_rsz.DecodeError as e:
            undecoded[qid] = str(e)
    if len(scenes) < MIN_SCENES:
        raise ew.ExtractError("only %d quest scenes found (expected at least %d)"
                              % (len(scenes), MIN_SCENES))
    if len(relations) < MIN_DECODED:
        raise ew.ExtractError(ew.LAYOUT_MSG)
    quests = {}
    for qid in sorted(set(ctx) | set(scenes)):
        quests[str(qid)] = quest_entry(ctx.get(qid), relations.get(qid), dests.get(qid, []))
    out = {"version": 1, "pak": "%d:%d" % (total, fingerprint), "quests": quests}
    sums = collections.Counter()
    for q in quests.values():
        for name in ("cast", "npcs", "items", "dest"):
            sums[name] += len(q[name])
    lines = [
        "quests %d, scenes %d, decoded %d, journals %d" % (
            len(quests), len(scenes), len(relations), len(journals)),
        "entries: cast %d, npcs %d, items %d, dest %d" % (
            sums["cast"], sums["npcs"], sums["items"], sums["dest"]),
    ]
    lines += ["undecoded %d: %s" % (qid, undecoded[qid]) for qid in sorted(undecoded)]
    return out, lines


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--game", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--key")
    a = ap.parse_args(argv)
    try:
        key_hex = key_check.read_key(a.key)
        if not key_hex:
            raise ew.ExtractError(ew.KEY_MSG)
        layouts = load_layouts()
        out, lines = extract(a.game, key_hex, layouts)
        ew.write_output(a.out, out)
        for ln in lines:
            print(ln)
        print("quests written: %d" % len(out["quests"]))
        return 0
    except ew.ExtractError as e:
        print(str(e))
        return 1
    except (KeyError, IndexError, ValueError, OSError) as e:
        print("extraction failed: %s" % type(e).__name__)
        return 1


if __name__ == "__main__":
    sys.exit(main())
