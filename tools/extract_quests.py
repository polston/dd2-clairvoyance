"""Offline extractor: reads the installed game's archive and writes the quests file.

Usage: python tools/extract_quests.py --game <game folder> --out <file> [--key <file>]

Prints counts only. Exit 0 on success; exit 1 with one reason line when any self-check fails
(no output file is written then).
"""
import argparse
import collections
import json
import os
import re
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
    ("app.quest.condition.CheckNPCHolderTypeParam", "_CharaID"),
)
ITEM_FIELDS = (
    ("app.quest.condition.CheckHasItemParam.ItemInfo", "_ID"),
    ("app.quest.condition.CheckDeliverParam", "_ItemID"),
    ("app.quest.condition.CheckEquipItemParam", "_ItemID"),
    ("app.quest.condition.CheckJobMasterItemParam", "_ItemID"),
)
CONTEXT_TYPE = "app.QuestContextData.ContextData"
DELIVER_TYPE = "app.QuestContextData.DeliverData"
DEST_TYPE = "app.QuestLogResource.QuestLogTaskDestination"
NOT_CHARA = ("Invalid", "ch000000_00")
QUEST_LOG_TYPE = "app.QuestLogResource"
TASK_TYPE = "app.QuestLogResource.QuestLogTaskData"
CONCIERGE_TYPE = "app.QuestLogConciergeData"
CONCIERGE_DEST_TYPE = "app.QuestLogConciergeData.Destination"
GUIDANCE_KEY_TARGET_TYPE = "app.GuidanceKeyLocation"
GUIDANCE_AREA_TARGET_TYPE = "app.GuidanceLocalArea"
GUIDANCE_SELECTOR_TYPE = "app.ClassSelector`1<app.GuidanceData>"
CONDITION_SELECTOR_TYPE = "app.ClassSelector`1<app.ConciergeConditionBase>"
DELIVER_SELECT_TYPE = "app.QuestDeliverSelectData"
DELIVER_DATA_TYPE = DELIVER_TYPE
QUEST_DELIVER_TYPE = "app.QuestDeliver"
ITEM_DATA_TYPE = "app.QuestDeliver.ItemData"
ITEM_VALUE_TYPE = "app.QuestDeliver.ItemData.ValueInfo"
REMINDER_TYPE = "app.ConciergeConditionQuestLogReminder"
QUEST_VARIABLE_TYPE = "app.ConciergeConditionQuestVariable"
ITEM_CONDITION_TYPE = "app.ConciergeConditionItem"
QUEST_VARIABLE_OR_TYPE = "app.ConciergeConditionQuestVariableGroupOR"
DELIVERY_CONDITION_TYPE = "app.ConciergeConditionDelivery"
SUBSKILL_CONDITION_TYPE = "app.ConciergeConditionSubskill"
DAYTIME_CONDITION_TYPE = "app.ConciergeConditionDayTime"
TASK_CONDITION_TYPE = "app.QuestLogResource.QuestLogCondition"
GUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
S32_MIN, S32_MAX = -(2 ** 31), 2 ** 31 - 1
U32_MAX = 2 ** 32 - 1


def scene_path(qid):
    return "natives/STM/AppData/Quest/qu%02d/qu%06d/Resident.scn.21" % (qid // 10000, qid)


def journal_path(qid):
    return "natives/STM/AppSystem/Quest/UserData/QuestLog/qu%06d_log.user.3" % qid


def _list(v):
    return v if isinstance(v, list) else [v]


def _integer(value, label, low=S32_MIN, high=S32_MAX):
    if type(value) is not int or value < low or value > high:
        raise ew.ExtractError("invalid %s" % label)
    return value


def _boolean(value, label):
    if type(value) is not bool:
        raise ew.ExtractError("invalid %s" % label)
    return value


def _field(inst, name):
    if inst is None or name not in inst.fields:
        raise ew.ExtractError("missing required field %s" % name)
    return inst.fields[name]


def _ref_array(insts, value, label, expected=None):
    if not isinstance(value, list):
        raise ew.ExtractError("invalid %s array" % label)
    result = []
    for ref in value:
        item = qnml_rsz.deref(insts, ref)
        if item is None or (expected is not None and item.type != expected):
            raise ew.ExtractError("invalid %s reference" % label)
        result.append(item)
    return result


def decode_condition(inst, insts, depth=0):
    """Decode the closed set of serialized concierge conditions without evaluating them."""
    if depth > 64:
        raise ew.ExtractError("condition nesting too deep")
    if inst is None:
        raise ew.ExtractError("missing condition")
    if inst.type == CONDITION_SELECTOR_TYPE:
        inst = qnml_rsz.deref(insts, _field(inst, "_Process"))
        if inst is None:
            raise ew.ExtractError("unresolved condition selector")
    t = inst.type
    if t == QUEST_VARIABLE_TYPE:
        return {"kind": "quest_variable", "enabled": _boolean(_field(inst, "_IsEnabled"), "condition enabled"),
                "is_not": _boolean(_field(inst, "_IsNot"), "condition negation"),
                "qid": _integer(_field(inst, "_QuestID"), "condition quest id", 1),
                "name_hash": _integer(_field(inst, "_NameHash"), "condition name hash", 0, U32_MAX),
                "value_type": _integer(_field(inst, "_ValueType"), "condition value type"),
                "compare_type": _integer(_field(inst, "_CompareType"), "condition compare type"),
                "bool_value": _boolean(_field(inst, "_BoolValue"), "condition bool value"),
                "int_value": _integer(_field(inst, "_IntValue"), "condition int value")}
    if t == ITEM_CONDITION_TYPE:
        return {"kind": "item", "enabled": _boolean(_field(inst, "_IsEnabled"), "condition enabled"),
                "is_not": _boolean(_field(inst, "_IsNot"), "condition negation"),
                "item_id": _integer(_field(inst, "_ItemID"), "condition item id", 1),
                "set_num": _boolean(_field(inst, "_SetNum"), "condition set num"),
                "num": _integer(_field(inst, "_Num"), "condition item count", 1)}
    if t == QUEST_VARIABLE_OR_TYPE:
        children = _ref_array(insts, _field(inst, "Conditions"), "OR conditions")
        return {"kind": "quest_variable_or",
                "enabled": _boolean(_field(inst, "_IsEnabled"), "condition enabled"),
                "is_not": _boolean(_field(inst, "_IsNot"), "condition negation"),
                "children": [decode_condition(child, insts, depth + 1) for child in children]}
    if t == REMINDER_TYPE:
        msg_id = _field(inst, "_ReminderMsgId")
        if not isinstance(msg_id, str) or not GUID_RE.fullmatch(msg_id):
            raise ew.ExtractError("invalid quest-log reminder message id")
        reminders = _ref_array(insts, _field(inst, "_ReminderList"), "reminders", REMINDER_TYPE)
        return {"kind": "quest_log_reminder", "reminder_msg_id": msg_id,
                "is_finished": _boolean(_field(inst, "_IsFinished"), "reminder finished"),
                "is_or": _boolean(_field(inst, "_IsOr"), "reminder OR flag"),
                "reminders": [decode_condition(child, insts, depth + 1) for child in reminders]}
    if t in (DELIVERY_CONDITION_TYPE, SUBSKILL_CONDITION_TYPE, DAYTIME_CONDITION_TYPE):
        raise ew.ExtractError("unsupported active condition family: %s" % t)
    raise ew.ExtractError("unknown active condition family: %s" % t)


def _condition_array(insts, value, label):
    return [decode_condition(item, insts) for item in _ref_array(insts, value, label)]


def decode_task_condition(inst):
    if inst is None or inst.type != TASK_CONDITION_TYPE:
        raise ew.ExtractError("unknown active task condition family: %s" %
                              (inst.type if inst is not None else "null"))
    return {"kind": "quest_log_condition",
            "qid": _integer(_field(inst, "_QuestID"), "task condition quest id"),
            "name_hash": _integer(_field(inst, "_NameHash"), "task condition name hash", 0, U32_MAX),
            "value_type": _integer(_field(inst, "_ValueType"), "task condition value type"),
            "bool_value": _boolean(_field(inst, "_BoolValue"), "task condition bool value"),
            "int_value": _integer(_field(inst, "_IntValue"), "task condition int value"),
            "compare_type": _integer(_field(inst, "_CompareType"), "task condition compare type")}


def _task_condition_array(insts, value, label):
    return [decode_task_condition(item) for item in _ref_array(insts, value, label)]


def _decode_task_destination(insts, destination, index):
    if destination.type != DEST_TYPE:
        raise ew.ExtractError("unknown task destination type: %s" % destination.type)
    cid = _integer(_field(destination, "_CharaID"), "destination character id", 0, U32_MAX)
    key = _integer(_field(destination, "_KeyLocation"), "destination key")
    area = _integer(_field(destination, "_Area"), "destination area")
    local_area = _integer(_field(destination, "_LocalArea"), "destination local area")
    return {"index": index,
            "set_destination": _boolean(_field(destination, "_SetDestination"), "set destination"),
            "dest_type": _integer(_field(destination, "_DestType"), "destination type"),
            "cid": None if cid in (0, INVALID_CHARA_ID, PLAYER_CHARA_ID) else cid,
            "key": key if key > 0 else None,
            "area": area if area >= 0 else None,
            "local_area": local_area if local_area >= 0 else None,
            "has_show_conditions": _boolean(_field(destination, "_HasShowConditions"), "show condition flag"),
            "show_conditions": _task_condition_array(insts, _field(destination, "_ShowConditions"), "show conditions"),
            "is_update_condition": _boolean(_field(destination, "_IsUpdateCondition"), "update condition flag"),
            "has_display_conditions": _boolean(_field(destination, "_HasDisplayConditions"), "display condition flag"),
            "display_conditions": _task_condition_array(insts, _field(destination, "_Conditions"), "display conditions")}


INVALID_CHARA_ID = 1857826560
PLAYER_CHARA_ID = 2891076981


def _decode_item_delivery(insts, deliver, key, qid, diagnostics=None):
    if deliver.type != QUEST_DELIVER_TYPE:
        raise ew.ExtractError("unknown quest delivery type: %s" % deliver.type)
    item = qnml_rsz.deref(insts, _field(deliver, "_Item"))
    if item is None:
        return None
    if item.type != ITEM_DATA_TYPE:
        raise ew.ExtractError("unknown quest item delivery type: %s" % item.type)
    groups = []
    values = _ref_array(insts, _field(item, "_Value"), "delivery groups", ITEM_VALUE_TYPE)
    for index, value in enumerate(values):
        raw_item_ids = _field(value, "_ItemID")
        if not isinstance(raw_item_ids, list):
            raise ew.ExtractError("invalid delivery item ids")
        item_ids = []
        for raw_id in raw_item_ids:
            item_id = _integer(raw_id, "delivery item id", 0)
            if item_id == 0:
                if diagnostics is not None:
                    diagnostics["delivery_item_id_zero_sentinels"] += 1
                continue
            item_ids.append(item_id)
        if not item_ids:
            raise ew.ExtractError("empty delivery item group")
        ignore = [_integer(v, "ignored restriction item", 1)
                  for v in _field(value, "_IgnoreRestrictionItem")]
        groups.append({"index": index, "item_ids": item_ids,
                       "count": _integer(_field(value, "_Count"), "delivery count", 1),
                       "is_all_item": _boolean(_field(value, "_IsAllItem"), "all-item flag"),
                       "is_infinite": _boolean(_field(value, "_IsInfinite"), "infinite flag"),
                       "ignore_restriction_items": ignore})
    return {"qid": qid, "key": key,
            "serial": _integer(_field(deliver, "_SerialNum"), "delivery serial", 0),
            "incomplete_possible": _boolean(_field(item, "_IncompletePossible"), "incomplete flag"),
            "operator": _integer(_field(item, "_Operator"), "delivery operator"), "groups": groups}


def decode_deliveries(insts, diagnostics=None):
    """Index item delivery definitions by quest and QuestDeliver serial."""
    result, lookup = {}, {}
    serials, pairs = collections.defaultdict(set), set()
    for data in insts:
        if data.type != DELIVER_DATA_TYPE:
            continue
        raw_qid = _integer(_field(data, "_IDValue"), "delivery quest id")
        if raw_qid <= 0:
            if diagnostics is not None:
                diagnostics["delivery_data_without_quest_id"] += 1
            continue
        qid = raw_qid
        refs = _field(data, "_Delivers")
        delivers = _ref_array(insts, refs, "quest deliveries", QUEST_DELIVER_TYPE)
        result.setdefault(qid, [])
        lookup.setdefault(qid, {})
        for key, deliver in enumerate(delivers):
            serial = _integer(_field(deliver, "_SerialNum"), "delivery serial", 0)
            pair = (qid, serial)
            if pair in pairs:
                raise ew.ExtractError("duplicate quest delivery key")
            pairs.add(pair)
            if serial in serials[qid]:
                raise ew.ExtractError("duplicate quest delivery serial")
            serials[qid].add(serial)
            row = _decode_item_delivery(insts, deliver, serial, qid, diagnostics)
            if row is None:
                if diagnostics is not None:
                    diagnostics["delivery_records_without_item_data"] += 1
                lookup[qid][serial] = {"serial": serial, "has_item_data": False}
                continue
            row["key"] = serial
            result[qid].append({k: v for k, v in row.items() if k != "qid"})
            lookup[qid][serial] = {"serial": serial, "has_item_data": True,
                                   "group_count": len(row["groups"])}
    return result, lookup


def decode_delivery_refs(insts, refs, delivery_index, group_id=-1):
    group_id = _integer(group_id, "delivery group id", -1)
    output = []
    for ref in refs:
        selection = qnml_rsz.deref(insts, ref)
        if selection is None or selection.type != DELIVER_SELECT_TYPE:
            raise ew.ExtractError("unknown quest delivery reference type")
        qid = _integer(_field(selection, "_QuestID"), "delivery reference quest id", 1)
        key = _integer(_field(selection, "_Key"), "delivery reference key", 0)
        target = delivery_index.get(qid, {}).get(key)
        if target is None:
            raise ew.ExtractError("unresolved quest delivery reference")
        if not target["has_item_data"]:
            raise ew.ExtractError("referenced quest delivery has no item data")
        if group_id >= target["group_count"]:
            raise ew.ExtractError("delivery group index out of range")
        output.append({"qid": qid, "key": key, "serial": target["serial"]})
    return output


def decode_guidance_destination(insts, destination, index, delivery_index):
    if destination.type != CONCIERGE_DEST_TYPE:
        raise ew.ExtractError("unknown concierge destination type: %s" % destination.type)
    target_obj = qnml_rsz.deref(insts, _field(destination, "_GuidancePos"))
    if target_obj is None:
        raise ew.ExtractError("unknown concierge target type")
    if target_obj.type == GUIDANCE_SELECTOR_TYPE:
        target_obj = qnml_rsz.deref(insts, _field(target_obj, "_Process"))
        if target_obj is None:
            raise ew.ExtractError("unresolved concierge target selector")
    if target_obj.type == GUIDANCE_KEY_TARGET_TYPE:
        key = _integer(_field(target_obj, "_KeyLocation"), "guidance key")
        if key <= 0:
            raise ew.ExtractError("invalid concierge key target")
        target = {"kind": "key_location", "key": key}
    elif target_obj.type == GUIDANCE_AREA_TARGET_TYPE:
        local_area = _integer(_field(target_obj, "LocalArea"), "guidance local area", 0)
        target = {"kind": "local_area", "local_area": local_area}
    else:
        raise ew.ExtractError("unknown concierge target type: %s" % target_obj.type)
    cid = _integer(_field(destination, "_CharaID"), "guidance character id", 0, U32_MAX)
    refs = _field(destination, "_DeliverData")
    if not isinstance(refs, list):
        raise ew.ExtractError("invalid delivery reference array")
    group_id = _integer(_field(destination, "_DeliveryGroupID"), "delivery group id", -1)
    delivery_refs = decode_delivery_refs(insts, refs, delivery_index, group_id)
    return {"index": index, "target": target,
            "cid": None if cid in (0, INVALID_CHARA_ID, PLAYER_CHARA_ID) else cid,
            "concierge_type": _integer(_field(destination, "_ConciergeType"), "concierge type"),
            "gimmick_id": _integer(_field(destination, "_GimmickID"), "gimmick id"),
            "is_chara_at_destination": _boolean(_field(destination, "_IsCharaAtDestination"), "character-at-destination flag"),
            "register_conditions": _condition_array(insts, _field(destination, "_RegisterConditions"), "register conditions"),
            "conditions": _condition_array(insts, _field(destination, "_Conditions"), "conditions"),
            "delivery": {"is_not": _boolean(_field(destination, "_DeliveryIsNot"), "delivery negation"),
                         "check_storage": _boolean(_field(destination, "_DeliveryCheckStorage"), "delivery storage flag"),
                         "group_id": group_id, "refs": delivery_refs}}


def decode_journal_objectives(insts, delivery_index, kept=None):
    """Produce source-ordered version-2 task and guidance arrays for one journal."""
    roots = [item for item in insts if item.type == QUEST_LOG_TYPE]
    if len(roots) != 1:
        raise ew.ExtractError("quest journal root missing or duplicated")
    root = roots[0]
    tasks = []
    task_rows = _ref_array(insts, _field(root, "_TaskList"), "quest tasks", TASK_TYPE)
    for task_index, task in enumerate(task_rows):
        dest_rows = _ref_array(insts, _field(task, "_Destinations"), "task destinations")
        destinations = [_decode_task_destination(insts, row, index)
                        for index, row in enumerate(dest_rows)]
        tasks.append({"index": task_index,
                      "has_destination": _boolean(_field(task, "_HasDestination"), "task has-destination flag"),
                      "destinations": destinations})
    guidance = []
    concierge_rows = _ref_array(insts, _field(root, "_ConciergeList"), "concierge records", CONCIERGE_TYPE)
    for concierge_index, concierge in enumerate(concierge_rows):
        task_index = _integer(_field(concierge, "_TaskIndex"), "concierge task index", 0)
        if task_index >= len(tasks):
            raise ew.ExtractError("concierge task index out of range")
        destinations = _ref_array(insts, _field(concierge, "_Destinations"), "concierge destinations")
        guidance.append({"index": concierge_index, "task_index": task_index,
                         "destinations": [decode_guidance_destination(insts, row, index, delivery_index)
                                          for index, row in enumerate(destinations)]})
    return {"tasks": tasks, "guidance": guidance}


def archive_source_diagnostics(instances):
    """Count unproven archive families; this deliberately emits no source descriptors."""
    counts = collections.Counter()
    reward_types = {"app.quest.action.QuestReward",
                    "app.quest.action.QuestRewardParam",
                    "app.quest.action.QuestRewardData.Data"}
    for inst in instances:
        name = inst.type.lower()
        if inst.type in reward_types:
            counts["reward_records"] += 1
        if "gift" in name and name.startswith("app.quest.action."):
            counts["gift_records"] += 1
        if name.startswith("app.quest.action.") and any(
                family in name for family in ("forgery", "craft", "ageing", "aging", "transform")):
            counts["transform_records"] += 1
    return counts


def validate_delivery_integrity(quests):
    """Fail before output replacement if any emitted reference loses its exact definition."""
    by_quest = {}
    for qid, quest in quests.items():
        keys, serials = set(), set()
        for delivery in quest["deliveries"]:
            key = _integer(delivery.get("key"), "delivery key", 0)
            serial = _integer(delivery.get("serial"), "delivery serial", 0)
            if key in keys:
                raise ew.ExtractError("duplicate quest delivery key")
            if serial in serials:
                raise ew.ExtractError("duplicate quest delivery serial")
            keys.add(key)
            serials.add(serial)
        by_quest[int(qid)] = {delivery["key"]: delivery for delivery in quest["deliveries"]}
    for quest in quests.values():
        for guidance in quest["guidance"]:
            for destination in guidance["destinations"]:
                group_id = _integer(destination["delivery"].get("group_id", -1),
                                    "delivery group id", -1)
                for ref in destination["delivery"]["refs"]:
                    target = by_quest.get(ref["qid"], {}).get(ref["key"])
                    if target is None:
                        raise ew.ExtractError("unresolved emitted quest delivery reference")
                    if _integer(ref.get("serial"), "delivery reference serial", 0) != target["serial"]:
                        raise ew.ExtractError("emitted quest delivery serial mismatch")
                    if group_id >= len(target.get("groups", [])):
                        raise ew.ExtractError("emitted delivery group index out of range")


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
    context_insts = ew._decode(context, layouts)
    ctx = context_relations(context_insts, kept)
    extraction_diagnostics = collections.Counter()
    deliveries, delivery_index = decode_deliveries(context_insts, extraction_diagnostics)
    journal_insts = {qid: ew._decode(data, layouts) for qid, data in journals.items()}
    dests = {qid: journal_dest(insts, kept) for qid, insts in journal_insts.items()}
    objectives = {qid: decode_journal_objectives(insts, delivery_index, kept)
                  for qid, insts in journal_insts.items()}
    relations, undecoded, decoded_scene_insts = {}, {}, []
    for qid, data in scenes.items():
        try:
            insts = qnml_rsz.decode(data, layouts)
            decoded_scene_insts.extend(insts)
            relations[qid] = scene_relations(insts, kept)
        except qnml_rsz.DecodeError as e:
            undecoded[qid] = str(e)
    if len(scenes) < MIN_SCENES:
        raise ew.ExtractError("only %d quest scenes found (expected at least %d)"
                              % (len(scenes), MIN_SCENES))
    if len(relations) < MIN_DECODED:
        raise ew.ExtractError(ew.LAYOUT_MSG)
    source_diagnostics = archive_source_diagnostics(
        context_insts + decoded_scene_insts +
        [inst for rows in journal_insts.values() for inst in rows])
    quests = {}
    for qid in sorted(set(ctx) | set(scenes) | set(journals) | set(deliveries)):
        entry = quest_entry(ctx.get(qid), relations.get(qid), dests.get(qid, []))
        entry.update(objectives.get(qid, {"tasks": [], "guidance": []}))
        entry["deliveries"] = deliveries.get(qid, [])
        quests[str(qid)] = entry
    validate_delivery_integrity(quests)
    out = {"version": 2, "pak": "%d:%d" % (total, fingerprint), "quests": quests}
    sums = collections.Counter()
    for q in quests.values():
        for name in ("cast", "npcs", "items", "dest"):
            sums[name] += len(q[name])
        sums["tasks"] += len(q["tasks"])
        sums["task_destinations"] += sum(len(t["destinations"]) for t in q["tasks"])
        sums["guidance"] += len(q["guidance"])
        sums["guidance_destinations"] += sum(len(g["destinations"]) for g in q["guidance"])
        sums["deliveries"] += len(q["deliveries"])
        sums["delivery_refs"] += sum(len(d["delivery"]["refs"])
                                      for g in q["guidance"] for d in g["destinations"])
    lines = [
        "quests %d, scenes %d, decoded %d, journals %d" % (
            len(quests), len(scenes), len(relations), len(journals)),
        "entries: cast %d, npcs %d, items %d, dest %d" % (
            sums["cast"], sums["npcs"], sums["items"], sums["dest"]),
        "objectives: tasks %d, task destinations %d, concierge records %d, guidance destinations %d, deliveries %d, delivery refs %d" % (
            sums["tasks"], sums["task_destinations"], sums["guidance"],
            sums["guidance_destinations"], sums["deliveries"], sums["delivery_refs"]),
        "diagnostics: delivery item-id zero sentinels %d, records without quest id %d, records without item data %d, reward records %d, gift records %d, transformation records %d, eligible archive source descriptors 0" % (
            extraction_diagnostics["delivery_item_id_zero_sentinels"],
            extraction_diagnostics["delivery_data_without_quest_id"],
            extraction_diagnostics["delivery_records_without_item_data"],
            source_diagnostics["reward_records"], source_diagnostics["gift_records"],
            source_diagnostics["transform_records"]),
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
