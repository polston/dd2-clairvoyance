"""Offline extractor: reads the installed game's archive and writes the places file.

Usage: python tools/extract_world.py --game <game folder> --out <file> [--key <file>]

Prints counts only, never positions. Exit 0 on success; exit 1 with one reason line when any
self-check fails (no output file is written then).
"""
import argparse
import collections
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import key_check  # noqa: E402
import qnml_pak  # noqa: E402
import qnml_rsz  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
LAYOUT_MSG = ("game update changed the data layout; rebuild tools/layouts.json "
              "from a new SDK dump")
KEY_MSG = "tools/pak_key.local.txt missing"
PAK_NAME = "re_chunk_000.pak"
PREFIX = "natives/STM/"
GMDATA = "AppSystem/Gimmick/UserData/Gm80_001_GmData.user"
MIN_FILES = 2000

LIST_FIELDS = (("_NormalTableList", "normal"), ("_SubQuestTableList", "subquest"),
               ("_MainQuestTableList", "mainquest"), ("_RandomNormalTableList", "random"))
KIND_OF_GIMMICK = {167: "token", 161: "beetle", 10: "chest", 11: "chest", 12: "chest", 692: "chest",
                   693: "chest", 694: "chest"}
# the lowest gimmick id of each kind: the self-check needs rows for it
FIRST_GIMMICK = {}
for _gid in sorted(KIND_OF_GIMMICK):
    FIRST_GIMMICK.setdefault(KIND_OF_GIMMICK[_gid], _gid)
CHEST_GIMMICKS = sorted(g for g, k in KIND_OF_GIMMICK.items() if k == "chest")
PHASES = ("beforeseason4", "season4")
_STR = re.compile(rb"(?:[\x20-\x7e]\x00){4,}")
_TABLE_QID = re.compile(r"/qu([0-9]{6})(?![0-9])")


class ExtractError(Exception):
    """A self-check failed; the message is the one reason line."""


def phase_of(path):
    """The first phase tag found in the lower-cased path, else None."""
    p = path.lower()
    for tag in PHASES:  # beforeseason4 is checked before season4, which it contains
        if tag in p:
            return tag
    return None


def table_qid_of(path):
    """Owning quest id for a quest-table path, or fail closed if it is malformed."""
    match = _TABLE_QID.search(path.lower())
    if not match:
        raise ExtractError("a quest-source table path has no six-digit quest owner")
    return int(match.group(1))


def check_patches(paths):
    """A reason naming the first patch archive that holds entries, else None."""
    for p in paths:
        name = os.path.basename(p)
        try:
            n = qnml_pak.patch_entry_count(p)
        except (qnml_pak.PakError, OSError) as e:
            return "cannot read patch archive %s: %s" % (name, e)
        if n > 0:
            return "patch archive %s holds %d entries; the extractor reads only the base archive" % (name, n)
    return None


def pak_files(game):
    """(base archive, patch archives): the game root only, never dlc/ or pak_mods/."""
    base = os.path.join(game, PAK_NAME)
    patches = sorted(glob.glob(os.path.join(glob.escape(game), PAK_NAME + ".patch_*.pak")))
    return base, patches


def _decode(data, layouts):
    try:
        return qnml_rsz.decode(data, layouts)
    except qnml_rsz.DecodeError:
        raise ExtractError(LAYOUT_MSG)


def _full(rel):
    return PREFIX + rel + ".3"


def _seeds(layouts):
    seeds = []
    for n in range(256):
        seeds.append("AppData/Generate/ManualSet/Field/EditField_%d/ManualSetTable_EditField_%d.user" % (n, n))
        seeds.append("AppData/Generate/ManualSet/Field/EditField_%d/ManualSetTable_Ori_EditField_%d.user" % (n, n))
    for a in layouts["enums"]["ContentsArea"]:
        for pre in ("", "Ori_"):
            seeds.append("AppData/Generate/ManualSet/Content/%s/ManualSetTable_%s%s.user" % (a, pre, a))
    return seeds


def enumerate_files(pak, layouts):
    """Follow every .user path named inside the seed files to a fixed point.

    Returns (files {rel: bytes}, seed hit count, dangling reference count).
    """
    queue = [s for s in _seeds(layouts) if pak.entries.get(qnml_pak.path_hash(_full(s)))]
    seed_hits = len(queue)
    files, dangling = {}, set()
    while queue:
        rel = queue.pop()
        if rel in files or rel in dangling:
            continue
        data = pak.read(_full(rel))
        if data is None:
            dangling.add(rel)
            continue
        files[rel] = data
        for s in _STR.findall(data):
            s = s.decode("utf-16-le")
            if s.endswith(".user") and s not in files:
                queue.append(s)
    return files, seed_hits, len(dangling)


def rows_of(insts):
    """Yield (set kind, row instance) for rows held by a table's SetInfo lists."""
    kind_of = {}
    for inst in insts:
        if inst.type == "app.GenerateTable":
            for field, kind in (("_EnemySetInfo", "enemy"), ("_NpcSetInfo", "npc"),
                                ("_GimmickSetInfo", "gimmick"), ("_StrayPawnSetInfo", "stray")):
                si = qnml_rsz.deref(insts, inst.fields.get(field))
                if si is not None:
                    for r in si.fields.get("_BasicRowDatas", []):
                        kind_of[r.idx] = kind
    for inst in insts:
        if inst.type == "app.GenerateRowData" and inst.idx in kind_of:
            yield kind_of[inst.idx], inst


def params_of(insts):
    """({ParamId: {"items": [(id, n)], "trap": bool, "pawn": bool}}, set of disagreeing ParamIds).

    The first entry for a ParamId wins; a later one with different items or flags is a conflict.
    """
    params, conflicts = {}, set()
    for inst in insts:
        if inst.type != "app.Gm80_001Param":
            continue
        pid = inst.fields["ParamId"]
        lst = []
        for r in inst.fields["ItemList"]:
            ip = qnml_rsz.deref(insts, r)
            lst.append((ip.fields["ItemId"], ip.fields["ItemNum"]))
        entry = {"items": lst,
                 "trap": qnml_rsz.deref(insts, inst.fields["TrapGenerateData"]) is not None,
                 "pawn": bool(inst.fields["IsPawnRestrict"])}
        if pid in params:
            if params[pid] != entry:
                conflicts.add(pid)
        else:
            params[pid] = entry
    return params, conflicts


def chest_items(data, layouts):
    """(params, conflicts) for the chest contents file; see params_of."""
    return params_of(_decode(data, layouts))


QUEST_FLAG = "app.GenerateManager.QuestFlagInfos.QuestFlagInfo"
QUEST_VAR = "app.GenerateManager.QuestFlagInfos.QuestVariableInfo"


def gate_of(insts, cont):
    """The lossless version-2 gate for a container, or None when it is unconditional."""
    sf = qnml_rsz.deref(insts, cont.fields.get("_SetFlagSetting")) if cont else None
    if sf is not None and (not isinstance(sf, qnml_rsz.Inst) or
                           sf.type != "app.GenerateSetting.SetFlagSettingData"):
        raise ExtractError("a container has a malformed set-flag setting")
    qi = qnml_rsz.deref(insts, sf.fields.get("_QuestFlagInfos")) if sf else None
    if qi is None:
        return None
    if not isinstance(qi, qnml_rsz.Inst) or qi.type != "app.GenerateManager.QuestFlagInfos":
        raise ExtractError("a set-flag setting has a malformed quest info list")
    fields = qi.fields
    infos = fields.get("_Infos")
    check = fields.get("_CheckType")
    if type(check) is not int or check not in (0, 1):
        raise ExtractError("a quest gate has an invalid check type")
    if not isinstance(infos, list):
        raise ExtractError("a quest gate has a missing or invalid info list")
    if not infos:
        return None
    conditions = []
    for r in infos:
        el = qnml_rsz.deref(insts, r)
        if not isinstance(el, qnml_rsz.Inst):
            raise ExtractError("a quest gate contains a null condition")
        if el.type == QUEST_FLAG:
            qid = el.fields.get("_QuestID")
            finish = el.fields.get("_IsFinishCheck")
            if type(qid) is not int or type(finish) is not bool:
                raise ExtractError("a quest gate has a malformed quest condition")
            conditions.append({"kind": "quest", "qid": qid, "finish": finish})
        elif el.type == QUEST_VAR:
            condition = qnml_rsz.deref(insts, el.fields.get("_Condition"))
            if not isinstance(condition, qnml_rsz.Inst) or condition.type != "app.QuestVariableCondition":
                raise ExtractError("a quest gate has a missing variable condition")
            values = {
                "qid": condition.fields.get("_QuestID"),
                "name_hash": condition.fields.get("_NameHash"),
                "value_type": condition.fields.get("_ValueType"),
                "compare_type": condition.fields.get("_CompareType"),
                "bool_value": condition.fields.get("_BoolValue"),
                "int_value": condition.fields.get("_IntValue"),
            }
            if any(type(value) is not int for key, value in values.items() if key != "bool_value") or \
                    type(values["bool_value"]) is not bool:
                raise ExtractError("a quest gate has a malformed variable condition")
            conditions.append({"kind": "variable", **values})
        else:
            raise ExtractError("a quest gate contains an unknown condition type")
    return {"check": check, "conditions": conditions}


def _round1(pos):
    return [round(float(v), 1) for v in pos]


def collect_rows(decoded, params, conflicts, chara_names):
    """Rows of the tracked kinds from decoded table files {rel: instances}.

    Returns (rows, count of chest rows without an item list, gimmick id counts,
    Counter of quest, trap, pawn and key location chest rows).
    """
    src_of = {}
    for insts in decoded.values():
        for inst in insts:
            if inst.type != "app.GenerateTableListData":
                continue
            for field, src in LIST_FIELDS:
                for r in inst.fields.get(field, []):
                    ref = qnml_rsz.deref(insts, r)
                    if ref is not None and ref.path:
                        src_of.setdefault(ref.path, src)
    rows, seen = [], {}
    gimmick_ids = collections.Counter()
    unjoined = 0
    kinds = collections.Counter()
    for rel in sorted(decoded):
        insts = decoded[rel]
        for kind, r in rows_of(insts):
            f = r.fields
            if kind == "enemy":
                k, rid = "chara", f["_CharaID"] & 0xFFFFFFFF
            elif kind == "gimmick" and f["_GimmickID"] in KIND_OF_GIMMICK:
                rid = f["_GimmickID"]
                k = KIND_OF_GIMMICK[rid]
                gimmick_ids[rid] += 1
            else:
                continue
            src = src_of.get(rel)
            if src is None:
                raise ExtractError("a table file is not referenced by any list")
            x, y, z = _round1(f["_ManualPos"])
            row = {"k": k, "uid": f["_ManualSetGuid"], "id": rid, "x": x, "y": y, "z": z, "src": src}
            if k == "chest":
                cont = qnml_rsz.deref(insts, f["_Container"])
                gs = qnml_rsz.deref(insts, cont.fields.get("_GimmickSetting")) if cont else None
                pid = gs.fields.get("_ParamId") if gs else None
                if pid in conflicts:
                    raise ExtractError("a chest row uses a ParamId with conflicting item lists")
                keyloc = bool(gs and gs.fields.get("_KeyLocationId"))
                if pid in params:
                    p = params[pid]
                    row["items"] = [{"id": i, "n": n} for i, n in p["items"]]
                    if p["trap"]:
                        row["trap"] = True
                    if p["pawn"]:
                        row["pawn"] = True
                else:
                    row["items"] = []
                    unjoined += 1
                gate = gate_of(insts, cont)
                if gate:
                    row["gate"] = gate
            if k == "chara":
                if src in ("subquest", "mainquest"):
                    row["table_qid"] = table_qid_of(rel)
                name = chara_names.get(str(rid))
                if name:
                    row["name"] = name
                ph = phase_of(rel)
                if ph:
                    row["phase"] = ph
                cont = qnml_rsz.deref(insts, f.get("_Container"))
                gate = gate_of(insts, cont)
                if gate:
                    row["gate"] = gate
            ident = json.dumps(row, sort_keys=True)
            key = (k, row["uid"])
            if key in seen:
                if seen[key] != ident:
                    raise ExtractError("a %s guid appears in two different rows" % k)
                continue
            seen[key] = ident
            rows.append(row)
            if k == "chest":
                for name in ("gate", "trap", "pawn"):
                    if name in row:
                        kinds[name] += 1
                if keyloc:
                    kinds["key locations"] += 1
    return rows, unjoined, gimmick_ids, kinds


def extract(game, key_hex, layouts):
    """Run the whole extraction; returns (output dict, count lines). Raises ExtractError."""
    base, patches = pak_files(game)
    if not os.path.isfile(base):
        raise ExtractError("%s not found in the game folder" % PAK_NAME)
    reason = check_patches(patches)
    if reason:
        raise ExtractError(reason)
    try:
        pak = qnml_pak.Pak(base, key_hex)
    except qnml_pak.PakError as e:
        raise ExtractError(str(e))
    try:
        files, seed_hits, dangling = enumerate_files(pak, layouts)
        gm = pak.read(_full(GMDATA))
    except qnml_pak.PakError as e:
        raise ExtractError(str(e))
    finally:
        pak.close()
    if dangling:
        raise ExtractError("%d dangling file references" % dangling)
    if seed_hits == 0:
        raise ExtractError("no content seed files found in the archive")
    if len(files) < MIN_FILES:
        raise ExtractError("only %d generate files found (expected at least %d)" % (len(files), MIN_FILES))
    if gm is None:
        raise ExtractError("chest contents file missing from the archive")
    params, conflicts = chest_items(gm, layouts)
    decoded = {rel: _decode(data, layouts) for rel, data in files.items()}
    rows, unjoined, gimmick_ids, kinds = collect_rows(
        decoded, params, conflicts, layouts["enums"]["CharacterID"])
    by_k = collections.Counter(r["k"] for r in rows)
    for k in ("token", "beetle", "chest"):
        gid = FIRST_GIMMICK[k]
        if gimmick_ids[gid] == 0:
            raise ExtractError("no %s rows (gimmick %d) found" % (k, gid))
    order = {"chest": 0, "token": 1, "beetle": 2, "chara": 3}
    rows.sort(key=lambda r: (order[r["k"]], r["uid"]))
    out = {"version": 2, "pak": "%d:%d" % (pak.total, pak.fingerprint), "rows": rows}

    chara = [r for r in rows if r["k"] == "chara"]
    chests = collections.Counter(r["id"] for r in rows if r["k"] == "chest")
    lines = [
        "files %d, content seed hits %d, dangling references 0" % (len(files), seed_hits),
        "tokens (%d) %d, beetles (%d) %d" % (
            FIRST_GIMMICK["token"], by_k["token"], FIRST_GIMMICK["beetle"], by_k["beetle"]),
        "chests %d (%s), without item list %d" % (
            by_k["chest"], ", ".join("%d: %d" % (g, chests[g]) for g in CHEST_GIMMICKS),
            unjoined),
        "kinds: gated %d, trap %d, pawn %d, key locations %d" % (
            kinds["gate"], kinds["trap"], kinds["pawn"], kinds["key locations"]),
        "chara rows %d, ids %d" % (len(chara), len({r["id"] for r in chara})),
        "chara src: " + ", ".join("%s %d" % (s, sum(1 for r in chara if r["src"] == s))
                                  for s in ("normal", "subquest", "mainquest", "random")),
        "chara phase: " + ", ".join("%s %d" % (p, sum(1 for r in chara if r.get("phase") == p))
                                    for p in PHASES),
    ]
    return out, lines


def write_output(path, data):
    """Write JSON to <path>.tmp then replace <path>; on any failure leave neither file."""
    tmp = path + ".tmp"
    try:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, separators=(",", ":"))
        os.replace(tmp, path)
    except Exception as e:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise ExtractError("could not write the output file (%s)" % type(e).__name__)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--game", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--key")
    a = ap.parse_args(argv)
    try:
        key_hex = key_check.read_key(a.key)
        if not key_hex:
            raise ExtractError(KEY_MSG)
        try:
            with open(os.path.join(HERE, "layouts.json"), encoding="utf-8") as f:
                layouts = json.load(f)
        except (OSError, ValueError):
            raise ExtractError("tools/layouts.json missing or unreadable")
        out, lines = extract(a.game, key_hex, layouts)
        write_output(a.out, out)
        for ln in lines:
            print(ln)
        print("rows written: %d" % len(out["rows"]))
        return 0
    except ExtractError as e:
        print(str(e))
        return 1
    except (KeyError, IndexError, ValueError, OSError) as e:
        print("extraction failed: %s" % type(e).__name__)
        return 1


if __name__ == "__main__":
    sys.exit(main())
