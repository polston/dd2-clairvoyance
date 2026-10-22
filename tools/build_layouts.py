"""Developer-only: cut tools/layouts.json out of the game's SDK dump.

Usage: python tools/build_layouts.py --dump <il2cpp_dump.json> --enums <Enums_Internal.hpp> --out tools/layouts.json

The SDK dump and enum header are not shipped to players; the extractor reads only the output.
The dump is streamed (it is over 1 GB): top-level entries are found by their 4-space
indentation and only the wanted types are parsed.
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

_START = re.compile(r'^    "(.*)": \{\s*$')


def read_types(dump_path):
    wanted = set(WANTED_TYPES)
    out = {}
    buf, name = None, None
    with open(dump_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if buf is None:
                m = _START.match(line)
                if m and m.group(1) in wanted:
                    name = m.group(1)
                    buf = ["{"]
                continue
            if line.startswith("    }"):
                buf.append("}")
                d = json.loads("".join(buf))
                buf = None
                fqn, rsz = d.get("fqn"), d.get("RSZ")
                if fqn and fqn != "0" and rsz is not None:
                    out[fqn.lower()] = {
                        "name": name,
                        "fields": [[x["potential_name"], x["code"], x["align"],
                                    int(x.get("size", "0"), 16), bool(x["array"])] for x in rsz],
                    }
                continue
            buf.append(line)
    missing = wanted - {t["name"] for t in out.values()}
    if missing:
        raise SystemExit("types not found in the dump: %s" % ", ".join(sorted(missing)))
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", required=True)
    ap.add_argument("--enums", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    chara = read_enum(a.enums, "CharacterID")
    areas = read_enum(a.enums, "ContentsArea")
    layouts = {
        "types": read_types(a.dump),
        "enums": {
            "CharacterID": {str(k): v for k, v in sorted(chara.items())},
            "ContentsArea": [v for k, v in sorted(areas.items()) if v != "None"],
        },
    }
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(layouts, f, separators=(",", ":"), sort_keys=True)
        f.write("\n")
    print("types %d, CharacterID %d, ContentsArea %d" % (
        len(layouts["types"]), len(chara), len(layouts["enums"]["ContentsArea"])))


if __name__ == "__main__":
    main()
