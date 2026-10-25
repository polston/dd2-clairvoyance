"""Developer-only: cut tools/layouts.json out of the game's SDK dump.

Usage: python tools/build_layouts.py --dump <il2cpp_dump.json> --enums <Enums_Internal.hpp> --out tools/layouts.json

The SDK dump and enum header are not shipped to players; the extractor reads only the output.
The dump is streamed (it is over 1 GB): top-level entries are found by their 4-space
indentation and parsed one at a time, keeping only name, parent and field list.
The output holds the fixed WANTED_TYPES plus every type the quest files can reach: a walk from
QUEST_ROOTS over subclasses and over the types named by Object and UserData fields (generic
arguments included). Behaviour components get a leading _BehaviorFlag field, and the three
native types the dump has no layout for come from NATIVE_LAYOUTS.
"""
import argparse
import json
import re

WANTED_TYPES = (
    "app.GenerateTableListData",
    "app.GenerateTableData",
    "app.GenerateTable",
    "app.GenerateTable.InitialSetData",
    "app.GenerateTable.SetInfo",
    "app.GenerateRowData",
    "app.GenerateManager.QuestFlagInfos",
    "app.GenerateManager.QuestFlagInfos.QuestFlagInfo",
    "app.GenerateSetting.BattleNoticeSettingData",
    "app.GenerateSetting.CharacterSettingData",
    "app.GenerateSetting.CommonSettingData",
    "app.GenerateSetting.GenerateSettingContainer",
    "app.GenerateSetting.GimmickSettingData",
    "app.GenerateSetting.InitialSettingData",
    "app.GenerateSetting.ItemDropSettingData",
    "app.GenerateSetting.SetFlagSettingData",
    "app.CutScenePropsRegister.RegisterInfo",
    "app.AutoSetPositionManager.PositionInfo",
    "app.RandomManualSetTable.RandomManualSetInfo",
    "app.QuestVariableCondition",
    "app.GenerateManager.QuestFlagInfos.QuestVariableInfo",
    "app.GimmickData",
    "app.Gm80_001Param",
    "app.Gm80_001Param.ItemParam",
)
WANTED_ENUMS = ("CharacterID", "ContentsArea")

QUEST_ROOTS = (
    "app.QuestProcessor", "app.QuestResultProcessor", "app.QuestOrderProcessor",
    "app.QuestContextData", "app.QuestLogResource", "app.QuestController",
    "app.QuestProcessorRegister", "app.QuestResourceCollector", "app.QuestResourceObject",
    "app.SoundOverwriteBgmCatalogRegister",
)
BEHAVIOR_FLAG = ["_BehaviorFlag", "U32", 4, 4, False]
NATIVE_LAYOUTS = {
    "via.GameObject": [["Name", "String", 4, 4, False], ["Tag", "String", 4, 4, False],
                       ["DrawSelf", "U8", 1, 1, False], ["UpdateSelf", "U8", 1, 1, False],
                       ["TimeScale", "F32", 4, 4, False]],
    "via.Transform": [["Pos", "Vec4", 16, 16, False], ["Rot", "Vec4", 16, 16, False],
                      ["Scale", "Vec4", 16, 16, False], ["ParentBone", "String", 4, 4, False],
                      ["SameJoints", "U8", 1, 1, False], ["AbsScale", "U8", 1, 1, False],
                      ["X8", "U64", 8, 8, False]],
    "via.Folder": [["Name", "String", 4, 4, False], ["Tag", "String", 4, 4, False],
                   ["Draw", "U8", 1, 1, False], ["Update", "U8", 1, 1, False],
                   ["Select", "U8", 1, 1, False], ["Path", "String", 4, 4, False],
                   ["Offset", "Position", 8, 24, False]],
}

_START = re.compile(r'^    "(.*)": \{\s*$')


def read_dump(dump_path):
    """Every top-level dump entry with an fqn other than "0", as
    {name: {"fqn", "parent", "fields"}}; fields is None when the entry has no RSZ."""
    out = {}
    buf, name = None, None
    with open(dump_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if buf is None:
                m = _START.match(line)
                if m:
                    name = m.group(1)
                    buf = ["{"]
                continue
            if line.startswith("    }"):
                buf.append("}")
                d = json.loads("".join(buf))
                buf = None
                fqn, rsz = d.get("fqn"), d.get("RSZ")
                if fqn and fqn != "0":
                    out[name] = {
                        "fqn": fqn.lower(),
                        "parent": d.get("parent"),
                        "fields": None if rsz is None else [
                            [x.get("potential_name"), x["code"], x["align"],
                             int(x.get("size", "0"), 16), bool(x["array"]), x.get("type")]
                            for x in rsz],
                    }
                continue
            buf.append(line)
    return out


def _parse_name(s, i):
    out = []
    while i < len(s) and s[i] not in ",]":
        if s.startswith("[[", i):
            args, i = _parse_args(s, i + 2)
            out.append("<" + ",".join(args) + ">")
        elif s.startswith("[]", i):
            out.append("[]")
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out), i


def _parse_args(s, i):
    args = []
    while True:
        name, i = _parse_name(s, i)
        args.append(name)
        i = s.find("]", i) + 1  # skip ", <assembly>, Version=..." and its closing bracket
        if s.startswith(",[", i):
            i += 2
            continue
        return args, i + 1  # the outer closing bracket


def _rewrite_generics(s):
    out, i = [], 0
    while i < len(s):
        if s.startswith("[[", i):
            args, i = _parse_args(s, i + 2)
            out.append("<" + ",".join(args) + ">")
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def field_type_names(type_str):
    """The names a field type string leads to: itself and every generic argument."""
    s = type_str[:-2] if type_str.endswith("[]") else type_str
    s = _rewrite_generics(s)
    names = {s}
    lt = s.find("<")
    if lt > 0 and s.endswith(">"):
        inner, depth, start = s[lt + 1:-1], 0, 0
        parts = []
        for k, ch in enumerate(inner):
            if ch == "<":
                depth += 1
            elif ch == ">":
                depth -= 1
            elif ch == "," and depth == 0:
                parts.append(inner[start:k])
                start = k + 1
        parts.append(inner[start:])
        for p in parts:
            names |= field_type_names(p)
    return names


def is_behavior(dump, name):
    cur = dump[name]["parent"] if name in dump else None
    for _ in range(20):
        if cur is None:
            return False
        if cur == "via.Behavior":
            return True
        cur = dump[cur]["parent"] if cur in dump else None
    return False


def quest_types(dump):
    children = {}
    for n, e in dump.items():
        if e["parent"]:
            children.setdefault(e["parent"], []).append(n)
    seen = set()
    todo = [n for n in QUEST_ROOTS if n in dump]
    while todo:
        n = todo.pop()
        if n in seen:
            continue
        seen.add(n)
        nxt = list(children.get(n, ()))
        for f in dump[n]["fields"] or ():
            if f[1] in ("Object", "UserData") and f[5]:
                nxt.extend(m for m in field_type_names(f[5]) if m in dump)
        todo.extend(m for m in nxt if m not in seen)
    return seen


def select_types(dump):
    quest = quest_types(dump)
    names = set(WANTED_TYPES) | quest
    missing = {n for n in WANTED_TYPES if n not in dump or dump[n]["fields"] is None}
    missing |= {n for n in QUEST_ROOTS + tuple(NATIVE_LAYOUTS) if n not in dump}
    if missing:
        raise SystemExit("types not found in the dump: %s" % ", ".join(sorted(missing)))
    out = {}
    for n in names:
        # a reached type with no RSZ holds no serialized fields: an empty list
        fields = [f[:5] for f in dump[n]["fields"] or []]
        if is_behavior(dump, n):
            fields.insert(0, list(BEHAVIOR_FLAG))
        out[dump[n]["fqn"]] = {"name": n, "fields": fields}
    for n, fields in NATIVE_LAYOUTS.items():
        out[dump[n]["fqn"]] = {"name": n, "fields": [list(f) for f in fields]}
    return dict(sorted(out.items()))


def read_enum(enums_path, name):
    """Enum members as {value: first member name}; values are unsigned 32-bit."""
    pat = re.compile(r"^\s*(\w+) = (-?\d+),")
    out, inside = {}, False
    with open(enums_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if not inside:
                inside = line.strip() == "enum %s {" % name
                continue
            if line.strip().startswith("}"):
                break
            m = pat.match(line)
            if m:
                out.setdefault(int(m.group(2)) & 0xFFFFFFFF, m.group(1))
    if not out:
        raise SystemExit("enum %s not found" % name)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", required=True)
    ap.add_argument("--enums", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    chara = read_enum(a.enums, "CharacterID")
    areas = read_enum(a.enums, "ContentsArea")
    dump = read_dump(a.dump)
    layouts = {
        "types": select_types(dump),
        "enums": {
            "CharacterID": {str(k): v for k, v in sorted(chara.items())},
            "ContentsArea": [v for k, v in sorted(areas.items()) if v != "None"],
        },
    }
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(layouts, f, separators=(",", ":"), sort_keys=True)
        f.write("\n")
    print("types %d, quest types %d, CharacterID %d, ContentsArea %d" % (
        len(layouts["types"]), len(quest_types(dump)), len(chara),
        len(layouts["enums"]["ContentsArea"])))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
