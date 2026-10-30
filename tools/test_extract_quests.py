"""Offline tests for the quest relations extractor. Run from the repo root:
python -m unittest discover -s tools -p "test_extract_quests.py"
"""
import contextlib
import collections
import io
import json
import os
import struct
import subprocess
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


def reward_endpoint_fixture():
    return [
        inst(1, eq.REWARD_TYPE, _Param=[R(2)], _Data=R(3)),
        inst(2, eq.REWARD_PARAM_TYPE, _DataList=[R(4)]),
        inst(3, eq.REWARD_PARAM_TYPE, _DataList=[]),
        inst(4, eq.REWARD_DATA_TYPE, _NameHash=7),
        inst(5, eq.PROCESSOR_ENTITY_TYPE, QuestAction=R(1)),
        inst(6, eq.PROCESSOR_TYPE, ProcID=9, PrevProcCondition=R(7), Process=R(5)),
        inst(7, eq.PROC_CONDITION_TYPE, _ElementArray=[R(8)]),
        inst(8, eq.PROC_ELEMENT_TYPE, _Operator=1, _ParamArray=[R(9)], _ElementArray=[]),
        inst(9, eq.PROC_ELEMENT_PARAM_TYPE, _ProcID=10, _ResultNo=0),
        inst(10, eq.PROCESSOR_TYPE, ProcID=10, PrevProcCondition=R(18), Process=R(11)),
        inst(11, eq.PROCESSOR_ENTITY_TYPE, QuestAction=R(12)),
        inst(12, "app.quest.action.Trigger", _Param=[R(13)]),
        inst(13, "app.quest.action.TriggerParam", _ConditionParam=R(14)),
        inst(14, "app.QuestConditionParam", _Operator=0, ConditionParamArray=[R(15)]),
        inst(15, "app.quest.condition.CheckTalkEventEndNoParam",
             _TalkEventID=24, _EndNo=1, _AcceptMinusOne=False),
        inst(16, "app.Unused"),
        inst(17, "app.Unused"),
        inst(18, eq.PROC_CONDITION_TYPE, _ElementArray=[R(19)]),
        inst(19, eq.PROC_ELEMENT_TYPE, _Operator=1, _ParamArray=[], _ElementArray=[]),
    ]


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

    def test_reward_diagnostics_preserve_exact_branch_and_raw_hash(self):
        insts = [
            inst(1, "app.quest.action.QuestReward", _Param=[R(2)], _Data=R(3)),
            inst(2, "app.quest.action.QuestRewardParam", _DataList=[R(4)]),
            # Serialized _Data is a separate, empty parameter and must not shadow _Param.
            inst(3, "app.quest.action.QuestRewardParam", _DataList=[]),
            inst(4, "app.quest.action.QuestRewardData.Data", _NameHash=801888944),
            inst(5, "app.QuestProcessor.ProcessEntity", QuestAction=R(1)),
            inst(6, "app.QuestProcessor", ProcID=209900992,
                 PrevProcCondition=R(7), Process=R(5)),
            inst(7, "app.QuestProcessor.ProcCondition", _ElementArray=[R(8)]),
            inst(8, "app.QuestProcessor.ProcCondition.Element", _Operator=1,
                 _ParamArray=[R(9)], _ElementArray=[R(10)]),
            inst(9, "app.QuestProcessor.ProcCondition.ElementParam",
                 _ProcID=3952043607, _ResultNo=0),
            inst(10, "app.QuestProcessor.ProcCondition.Element", _Operator=0,
                 _ParamArray=[R(11)], _ElementArray=[]),
            inst(11, "app.QuestProcessor.ProcCondition.ElementParam",
                 _ProcID=3952043610, _ResultNo=0),
            inst(12, "app.quest.action.Trigger", _Param=[]),
            inst(13, "app.QuestProcessor.ProcessEntity", QuestAction=R(12)),
            inst(14, "app.QuestProcessor", ProcID=3952043607,
                 PrevProcCondition=R(7), Process=R(13)),
            inst(15, "app.quest.action.PlayEvent"),
            inst(16, "app.QuestProcessor.ProcessEntity", QuestAction=R(15)),
            inst(17, "app.QuestProcessor", ProcID=3952043610,
                 PrevProcCondition=R(7), Process=R(16)),
        ]

        result = eq.decode_reward_diagnostics(insts, 10030)

        self.assertEqual(result, [{
            "family": "quest_reward", "quest_id": 10030,
            "source_identity": {"quest_id": 10030, "processor_id": 209900992,
                                "action_ordinal": 0},
            "action_type": "app.quest.action.QuestReward",
            "ownership_status": "exact", "branch_status": "unverified",
            "branch_diagnostics": ["predecessor_action_semantics_unverified"],
            "precondition": [{
                "operator": "or", "operator_value": 1,
                "parameters": [{"kind": "processor_result", "proc_id": 3952043607,
                                "result_no": 0, "action_type": "app.quest.action.Trigger",
                                "result_status": "observed"}],
                "children": [{"operator": "and", "operator_value": 0,
                              "parameters": [
                    {"kind": "processor_result", "proc_id": 3952043610,
                     "result_no": 0, "action_type": "app.quest.action.PlayEvent",
                     "result_status": "observed"}],
                    "children": []}],
            }],
            "reward_rows": [{"ordinal": 0, "name_hash": 801888944}],
            "task_endpoint_join": {"status": "unproven",
                                   "reason": "journal_task_to_drawable_reward_endpoint_unverified"},
            "reward_payload_status": "complete",
            "endpoint_evidence": None,
            "unresolved_joins": ["journal_task_to_reward_endpoint",
                                 "reward_action_to_drawable_target",
                                 "current_branch_truth", "claim_state",
                                 "runtime_reward_hash_to_item_count"],
            "eligibility": "unknown",
        }])

    def test_reward_endpoint_evidence_requires_closed_single_talk_trigger(self):
        expected = {
            "kind": "single_talk_trigger", "reward_root_count": 1,
            "reward_operator": "or", "reward_operator_value": 1,
            "reward_relation_count": 1, "reward_child_count": 0,
            "relation_result_no": 0, "predecessor_processor_id": 10,
            "predecessor_action_type": "app.quest.action.Trigger",
            "trigger_parameter_count": 1, "condition_operator": "and",
            "condition_operator_value": 0, "condition_count": 1,
            "condition_type": "app.quest.condition.CheckTalkEventEndNoParam",
            "talk_event_id": 24, "end_no": 1, "accept_minus_one": False,
        }
        self.assertEqual(eq.decode_reward_diagnostics(reward_endpoint_fixture(), 10030)[0]
                         ["endpoint_evidence"], expected)

        unsupported = [
            ("multiple reward roots", lambda rows: rows[6].fields["_ElementArray"].append(R(19))),
            ("wrong root operator", lambda rows: rows[7].fields.update(_Operator=0)),
            ("multiple reward relations", lambda rows: (rows.append(inst(
                20, eq.PROC_ELEMENT_PARAM_TYPE, _ProcID=10, _ResultNo=0)),
                rows[7].fields["_ParamArray"].append(R(20)))),
            ("nonzero relation result", lambda rows: rows[8].fields.update(_ResultNo=1)),
            ("reward children", lambda rows: rows[7].fields["_ElementArray"].append(R(19))),
            ("non-Trigger predecessor", lambda rows: rows[11].__setattr__("type", "app.quest.action.PlayEvent")),
            ("multiple Trigger parameters", lambda rows: rows[11].fields["_Param"].append(R(13))),
            ("wrong condition operator", lambda rows: rows[13].fields.update(_Operator=1)),
            ("multiple conditions", lambda rows: rows[13].fields["ConditionParamArray"].append(R(15))),
            ("wrong condition type", lambda rows: rows[14].__setattr__("type", "app.quest.condition.Other")),
            ("nonpositive talk id", lambda rows: rows[14].fields.update(_TalkEventID=0)),
        ]
        for label, mutate in unsupported:
            with self.subTest(label=label):
                rows = reward_endpoint_fixture()
                mutate(rows)
                self.assertIsNone(eq.decode_reward_diagnostics(rows, 10030)[0]["endpoint_evidence"])

        for field, value in (("_TalkEventID", "24"), ("_EndNo", "1"),
                             ("_AcceptMinusOne", 0)):
            with self.subTest(field=field, invalid=value):
                rows = reward_endpoint_fixture()
                rows[14].fields[field] = value
                with self.assertRaises(ew.ExtractError):
                    eq.decode_reward_diagnostics(rows, 10030)
        for field in ("_TalkEventID", "_EndNo", "_AcceptMinusOne"):
            with self.subTest(field=field, missing=True):
                rows = reward_endpoint_fixture()
                del rows[14].fields[field]
                with self.assertRaises(ew.ExtractError):
                    eq.decode_reward_diagnostics(rows, 10030)

    def test_reward_diagnostics_preserve_hash_rows_and_unknown_endpoint(self):
        insts = [
            inst(1, "app.quest.action.QuestReward", _Param=[R(2)], _Data=R(3)),
            inst(2, "app.quest.action.QuestRewardParam", _DataList=[R(4), R(5)]),
            inst(3, "app.quest.action.QuestRewardParam", _DataList=[]),
            inst(4, "app.quest.action.QuestRewardData.Data", _NameHash=3741130030),
            inst(5, "app.quest.action.QuestRewardData.Data", _NameHash=2856910244),
            inst(6, "app.QuestProcessor.ProcessEntity", QuestAction=R(1)),
            inst(7, "app.QuestProcessor", ProcID=9, PrevProcCondition=R(8), Process=R(6)),
            inst(8, "app.QuestProcessor.ProcCondition", _ElementArray=[R(9)]),
            inst(9, "app.QuestProcessor.ProcCondition.Element", _Operator=1,
                 _ParamArray=[R(10)], _ElementArray=[]),
            inst(10, "app.QuestProcessor.ProcCondition.ElementParam", _ProcID=10, _ResultNo=0),
            inst(11, "app.quest.action.Trigger", _Param=[]),
            inst(12, "app.QuestProcessor.ProcessEntity", QuestAction=R(11)),
            inst(13, "app.QuestProcessor", ProcID=10, PrevProcCondition=R(8), Process=R(12)),
        ]
        result = eq.decode_reward_diagnostics(insts, 30150)
        self.assertEqual(result[0]["eligibility"], "unknown")
        self.assertEqual(result[0]["task_endpoint_join"]["status"], "unproven")
        self.assertEqual([row["name_hash"] for row in result[0]["reward_rows"]],
                         [3741130030, 2856910244])
        self.assertTrue(all(set(row) == {"ordinal", "name_hash"}
                            for row in result[0]["reward_rows"]))
        self.assertNotIn("source_id", result[0])
        self.assertNotIn("sources", result[0])

    def test_reward_diagnostics_reject_malformed_and_report_unsupported_domains(self):
        reward = inst(1, "app.quest.action.QuestReward", _Param=[R(2)], _Data=R(3))
        param = inst(2, "app.quest.action.QuestRewardParam", _DataList=[R(4)])
        empty_data = inst(3, "app.quest.action.QuestRewardParam", _DataList=[])
        row = inst(4, "app.quest.action.QuestRewardData.Data", _NameHash=7)
        owner = inst(5, "app.QuestProcessor.ProcessEntity", QuestAction=R(1))
        proc = inst(6, "app.QuestProcessor", ProcID=9, PrevProcCondition=R(7), Process=R(5))
        condition = inst(7, "app.QuestProcessor.ProcCondition", _ElementArray=[R(8)])
        element = inst(8, "app.QuestProcessor.ProcCondition.Element", _Operator=1,
                       _ParamArray=[R(9)], _ElementArray=[])
        predecessor = inst(9, "app.QuestProcessor.ProcCondition.ElementParam",
                           _ProcID=10, _ResultNo=0)
        base = [reward, param, empty_data, row, owner, proc, condition, element, predecessor]

        malformed = base[:-1] + [inst(9, "app.QuestProcessor.ProcCondition.ElementParam",
                                       _ProcID="10", _ResultNo=0)]
        with self.assertRaisesRegex(ew.ExtractError, "invalid reward predecessor processor id"):
            eq.decode_reward_diagnostics(malformed, 10030)

        unsupported_operator = list(base)
        unsupported_operator[7] = inst(8, "app.QuestProcessor.ProcCondition.Element",
                                       _Operator=2, _ParamArray=[R(9)], _ElementArray=[])
        row = eq.decode_reward_diagnostics(unsupported_operator, 10030)[0]
        self.assertEqual(row["branch_status"], "unsupported")
        self.assertIn("unsupported_operator", row["branch_diagnostics"])
        self.assertEqual(row["eligibility"], "unknown")

        unsupported_result = list(base)
        unsupported_result[8] = inst(9, "app.QuestProcessor.ProcCondition.ElementParam",
                                     _ProcID=10, _ResultNo=2)
        row = eq.decode_reward_diagnostics(unsupported_result, 10030)[0]
        self.assertEqual(row["branch_status"], "unsupported")
        self.assertIn("unsupported_result_no", row["branch_diagnostics"])

        unsupported_action = list(base)
        unsupported_action.extend([
            inst(10, "app.QuestProcessor.ProcessEntity", QuestAction=R(11)),
            inst(11, "app.UnknownAction"),
            inst(12, "app.QuestProcessor", ProcID=10,
                 PrevProcCondition=R(7), Process=R(10)),
        ])
        row = eq.decode_reward_diagnostics(unsupported_action, 10030)[0]
        self.assertIn("unsupported_predecessor_action_type", row["branch_diagnostics"])

        no_owner = base[:4] + base[6:]
        row = eq.decode_reward_diagnostics(no_owner, 10030)[0]
        self.assertEqual(row["ownership_status"], "missing_owner")
        self.assertEqual(row["eligibility"], "unknown")

        ambiguous_owner = base + [inst(10, "app.QuestProcessor", ProcID=11,
                                       PrevProcCondition=R(7), Process=R(5))]
        row = eq.decode_reward_diagnostics(ambiguous_owner, 10030)[0]
        self.assertEqual(row["ownership_status"], "ambiguous_owner")
        self.assertNotIn("processor_id", row["source_identity"])

        duplicate_processor = base + [
            inst(10, "app.quest.action.Trigger", _Param=[]),
            inst(11, "app.QuestProcessor.ProcessEntity", QuestAction=R(10)),
            inst(12, "app.QuestProcessor", ProcID=9,
                 PrevProcCondition=R(7), Process=R(11)),
        ]
        row = eq.decode_reward_diagnostics(duplicate_processor, 10030)[0]
        self.assertEqual(row["ownership_status"], "duplicate_processor_id")
        self.assertIn("duplicate_processor_id", row["branch_diagnostics"])

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


class ObjectiveExtractorTests(unittest.TestCase):
    def test_ordered_tasks_guidance_and_recursive_reminders(self):
        task_type = "app.QuestLogResource.QuestLogTaskData"
        dest_type = "app.QuestLogResource.QuestLogTaskDestination"
        concierge_type = "app.QuestLogConciergeData"
        concierge_dest_type = "app.QuestLogConciergeData.Destination"
        reminder_type = "app.ConciergeConditionQuestLogReminder"
        task_condition_type = "app.QuestLogResource.QuestLogCondition"
        qvar_type = "app.ConciergeConditionQuestVariable"
        item_type = "app.ConciergeConditionItem"
        or_type = "app.ConciergeConditionQuestVariableGroupOR"
        insts = [
            inst(1, task_type, _HasDestination=False, _Destinations=[]),
            inst(2, task_type, _HasDestination=True, _Destinations=[R(3), R(4)]),
            inst(3, dest_type, _SetDestination=False, _DestType=2, _CharaID=0xF0000001,
                 _KeyLocation=0, _Area=17, _LocalArea=0, _HasShowConditions=True,
                 _IsUpdateCondition=True, _ShowConditions=[R(5)], _HasDisplayConditions=True,
                 _Conditions=[R(6)]),
            inst(4, dest_type, _SetDestination=True, _DestType=3, _CharaID=101,
                 _KeyLocation=2308, _Area=19, _LocalArea=42, _HasShowConditions=False,
                 _IsUpdateCondition=False, _ShowConditions=[], _HasDisplayConditions=False,
                 _Conditions=[]),
            inst(5, task_condition_type, _QuestID=30150, _NameHash=4294967295,
                 _ValueType=2, _CompareType=4, _BoolValue=True, _IntValue=-7),
            inst(6, task_condition_type, _QuestID=-7, _NameHash=8, _ValueType=1,
                 _CompareType=2, _BoolValue=False, _IntValue=0),
            inst(7, reminder_type, _ReminderMsgId="00112233-4455-6677-8899-aabbccddeeff",
                 _IsFinished=True, _IsOr=False, _ReminderList=[R(8), R(9)]),
            inst(8, reminder_type, _ReminderMsgId="10112233-4455-6677-8899-aabbccddeeff",
                 _IsFinished=False, _IsOr=True, _ReminderList=[R(10)]),
            inst(9, reminder_type, _ReminderMsgId="20112233-4455-6677-8899-aabbccddeeff",
                 _IsFinished=True, _IsOr=False, _ReminderList=[]),
            inst(10, reminder_type, _ReminderMsgId="30112233-4455-6677-8899-aabbccddeeff",
                 _IsFinished=False, _IsOr=False, _ReminderList=[]),
            inst(11, or_type, _IsEnabled=True, _IsNot=True, Conditions=[R(22), R(23)]),
            inst(12, qvar_type, _IsEnabled=True, _IsNot=False, _QuestID=7,
                 _NameHash=8, _ValueType=1, _CompareType=2, _BoolValue=False, _IntValue=0),
            inst(13, item_type, _IsEnabled=False, _IsNot=True, _ItemID=400,
                 _SetNum=False, _Num=1),
            inst(14, concierge_type, _TaskIndex=1, _Destinations=[R(15), R(16)]),
            inst(15, concierge_dest_type, _GuidancePos=R(18), _ConciergeType=3,
                 _CharaID=0xF0000001, _GimmickID=29, _IsCharaAtDestination=False,
                 _DeliveryIsNot=True, _DeliveryCheckStorage=True, _DeliveryGroupID=-1,
                 _DeliverData=[], _RegisterConditions=[R(7)], _Conditions=[R(11)]),
            inst(16, concierge_dest_type, _GuidancePos=R(19), _ConciergeType=5,
                 _CharaID=102, _GimmickID=-1, _IsCharaAtDestination=True,
                 _DeliveryIsNot=False, _DeliveryCheckStorage=False, _DeliveryGroupID=2,
                 _DeliverData=[], _RegisterConditions=[], _Conditions=[]),
            inst(17, "app.QuestLogResource", _QuestId=30150,
                 _TaskList=[R(1), R(2)], _ConciergeList=[R(14), R(24)]),
            inst(18, "app.ClassSelector`1<app.GuidanceData>", _Process=R(20)),
            inst(19, "app.ClassSelector`1<app.GuidanceData>", _Process=R(21)),
            inst(20, "app.GuidanceKeyLocation", _KeyLocation=2308),
            inst(21, "app.GuidanceLocalArea", LocalArea=0),
            inst(22, "app.ClassSelector`1<app.ConciergeConditionBase>", _Process=R(12)),
            inst(23, "app.ClassSelector`1<app.ConciergeConditionBase>", _Process=R(13)),
            inst(24, concierge_type, _TaskIndex=1, _Destinations=[]),
        ]

        extension = eq.decode_journal_objectives(insts, {}, eq.kept_chara(CHARA) | {0xF0000001})
        self.assertEqual(extension["tasks"], [
            {"index": 0, "has_destination": False, "destinations": []},
            {"index": 1, "has_destination": True, "destinations": [
                {"index": 0, "set_destination": False, "dest_type": 2,
                 "cid": 0xF0000001, "key": None, "area": 17, "local_area": 0,
                 "has_show_conditions": True, "show_conditions": [
                     {"kind": "quest_log_condition", "qid": 30150, "name_hash": 4294967295,
                      "value_type": 2, "compare_type": 4, "bool_value": True, "int_value": -7}],
                 "is_update_condition": True, "has_display_conditions": True,
                 "display_conditions": [{"kind": "quest_log_condition", "qid": -7,
                     "name_hash": 8, "value_type": 1, "compare_type": 2,
                     "bool_value": False, "int_value": 0}]},
                {"index": 1, "set_destination": True, "dest_type": 3, "cid": 101,
                 "key": 2308, "area": 19, "local_area": 42,
                 "has_show_conditions": False, "show_conditions": [],
                 "is_update_condition": False, "has_display_conditions": False,
                 "display_conditions": []}]},
        ])
        self.assertEqual(extension["guidance"][0]["task_index"], 1)
        self.assertEqual([g["task_index"] for g in extension["guidance"]], [1, 1])
        self.assertEqual([g["index"] for g in extension["guidance"]], [0, 1])
        self.assertEqual([x["index"] for x in extension["guidance"][0]["destinations"]], [0, 1])
        first = extension["guidance"][0]["destinations"][0]
        self.assertEqual(first["target"], {"kind": "key_location", "key": 2308})
        self.assertEqual(extension["guidance"][0]["destinations"][1]["target"],
                         {"kind": "local_area", "local_area": 0})
        self.assertEqual(first["cid"], 0xF0000001)
        self.assertEqual(first["delivery"], {"is_not": True, "check_storage": True,
            "group_id": -1, "refs": []})
        self.assertEqual(first["register_conditions"][0], {
            "kind": "quest_log_reminder", "reminder_msg_id": "00112233-4455-6677-8899-aabbccddeeff",
            "is_finished": True, "is_or": False, "reminders": [
                {"kind": "quest_log_reminder", "reminder_msg_id": "10112233-4455-6677-8899-aabbccddeeff",
                 "is_finished": False, "is_or": True, "reminders": [
                     {"kind": "quest_log_reminder", "reminder_msg_id": "30112233-4455-6677-8899-aabbccddeeff",
                      "is_finished": False, "is_or": False, "reminders": []}]},
                {"kind": "quest_log_reminder", "reminder_msg_id": "20112233-4455-6677-8899-aabbccddeeff",
                 "is_finished": True, "is_or": False, "reminders": []}]})
        self.assertEqual(first["conditions"][0], {"kind": "quest_variable_or", "enabled": True,
            "is_not": True, "children": [
                {"kind": "quest_variable", "enabled": True, "is_not": False, "qid": 7,
                 "name_hash": 8, "value_type": 1, "compare_type": 2, "bool_value": False, "int_value": 0},
                {"kind": "item", "enabled": False, "is_not": True, "item_id": 400,
                 "set_num": False, "num": 1}]})

    def test_concierge_task_index_out_of_range_rejected(self):
        insts = [
            inst(1, "app.QuestLogResource", _QuestId=30150,
                 _TaskList=[R(2)], _ConciergeList=[R(3)]),
            inst(2, "app.QuestLogResource.QuestLogTaskData",
                 _HasDestination=False, _Destinations=[]),
            inst(3, "app.QuestLogConciergeData", _TaskIndex=1,
                 _Destinations=[]),
        ]
        with self.assertRaises(ew.ExtractError):
            eq.decode_journal_objectives(insts, {})

    def test_unknown_condition_and_target_fail_closed(self):
        unknown = inst(1, "app.ConciergeConditionFuture", _IsEnabled=True, _IsNot=False)
        with self.assertRaises(ew.ExtractError):
            eq.decode_condition(unknown, [])
        bad_target = inst(2, "app.QuestLogConciergeData.Destination", _GuidancePos=None,
                          _CharaID=101, _ConciergeType=0, _GimmickID=0,
                          _IsCharaAtDestination=False, _DeliveryIsNot=False,
                          _DeliveryCheckStorage=False, _DeliveryGroupID=-1,
                          _DeliverData=[], _RegisterConditions=[], _Conditions=[])
        with self.assertRaises(ew.ExtractError):
            eq.decode_guidance_destination([bad_target], bad_target, 0, {})

    def test_delivery_structure_and_reference_integrity(self):
        insts = [
            inst(1, "app.QuestContextData.DeliverData", _IDValue=30150,
                 _Delivers=[R(2), R(3)]),
            inst(2, "app.QuestDeliver", _SerialNum=71, _Item=R(4)),
            inst(3, "app.QuestDeliver", _SerialNum=72, _Item=R(5)),
            inst(4, "app.QuestDeliver.ItemData", _IncompletePossible=True,
                 _Operator=1, _Value=[R(6), R(7)]),
            inst(5, "app.QuestDeliver.ItemData", _IncompletePossible=False,
                 _Operator=0, _Value=[R(8)]),
            inst(6, "app.QuestDeliver.ItemData.ValueInfo", _ItemID=[378, 400], _Count=5,
                 _IsAllItem=False, _IsInfinite=False, _IgnoreRestrictionItem=[9]),
            inst(7, "app.QuestDeliver.ItemData.ValueInfo", _ItemID=[401], _Count=1,
                 _IsAllItem=True, _IsInfinite=True, _IgnoreRestrictionItem=[]),
            inst(8, "app.QuestDeliver.ItemData.ValueInfo", _ItemID=[500], _Count=2,
                 _IsAllItem=False, _IsInfinite=False, _IgnoreRestrictionItem=[]),
            inst(9, "app.QuestDeliverSelectData", _QuestID=30150, _Key=71),
            inst(10, "app.QuestDeliverSelectData", _QuestID=30150, _Key=72),
        ]
        delivery_catalog, delivery_index = eq.decode_deliveries(insts)
        deliveries = delivery_catalog[30150]
        self.assertEqual(deliveries, [{"key": 71, "serial": 71, "incomplete_possible": True,
            "operator": 1, "groups": [
                {"index": 0, "item_ids": [378, 400], "count": 5, "is_all_item": False,
                 "is_infinite": False, "ignore_restriction_items": [9]},
                {"index": 1, "item_ids": [401], "count": 1, "is_all_item": True,
                 "is_infinite": True, "ignore_restriction_items": []}]},
            {"key": 72, "serial": 72, "incomplete_possible": False, "operator": 0,
             "groups": [{"index": 0, "item_ids": [500], "count": 2, "is_all_item": False,
                         "is_infinite": False, "ignore_restriction_items": []}]}])
        refs = eq.decode_delivery_refs(insts, [R(9), R(10)], delivery_index)
        self.assertEqual(refs, [{"qid": 30150, "key": 71, "serial": 71},
                                {"qid": 30150, "key": 72, "serial": 72}])
        self.assertEqual(eq.decode_delivery_refs(insts, [R(9)], delivery_index, group_id=1),
                         [{"qid": 30150, "key": 71, "serial": 71}])
        with self.assertRaises(ew.ExtractError):
            eq.decode_delivery_refs(insts, [R(10)], delivery_index, group_id=1)
        for mutate in (
                lambda: setattr(insts[8], "type", "app.OtherSelectData"),
                lambda: setattr(insts[8], "fields", {"_QuestID": 30150, "_Key": 9}),
                lambda: setattr(insts[8], "fields", {"_QuestID": 30151, "_Key": 0})):
            before = [dict(x.fields) for x in insts]
            mutate()
            with self.assertRaises(ew.ExtractError):
                eq.decode_delivery_refs(insts, [R(9)], delivery_index)
            for x, fields in zip(insts, before):
                x.fields = fields
                x.type = "app.QuestDeliverSelectData" if x.idx == 9 else x.type

    def test_duplicate_delivery_keys_and_serials_rejected(self):
        base = [inst(1, "app.QuestContextData.DeliverData", _IDValue=30150,
                     _Delivers=[R(2), R(3)]),
                inst(2, "app.QuestDeliver", _SerialNum=71, _Item=R(4)),
                inst(3, "app.QuestDeliver", _SerialNum=71, _Item=R(4)),
                inst(4, "app.QuestDeliver.ItemData", _IncompletePossible=False,
                     _Operator=0, _Value=[])]
        with self.assertRaises(ew.ExtractError):
            eq.decode_deliveries(base)
        base[2].fields["_SerialNum"] = 72
        base[0].fields["_Delivers"] = [R(2), R(2)]
        with self.assertRaises(ew.ExtractError):
            eq.decode_deliveries(base)

    def test_emitted_delivery_serial_mismatch_is_rejected(self):
        quests = {"30150": {"deliveries": [{"key": 71, "serial": 71}],
            "guidance": [{"destinations": [{"delivery": {"refs": [
                {"qid": 30150, "key": 71, "serial": 72}]}}]}]}}
        with self.assertRaises(ew.ExtractError):
            eq.validate_delivery_integrity(quests)

    def test_emitted_delivery_group_out_of_range_is_rejected(self):
        quests = {"30150": {"deliveries": [
            {"key": 71, "serial": 71, "groups": []}],
            "guidance": [{"destinations": [{"delivery": {
                "group_id": 0,
                "refs": [{"qid": 30150, "key": 71, "serial": 71}]}}]}]}}
        with self.assertRaises(ew.ExtractError):
            eq.validate_delivery_integrity(quests)

    def test_non_item_delivery_is_diagnostic_only_and_cannot_resolve_guidance(self):
        insts = [inst(1, "app.QuestContextData.DeliverData", _IDValue=30150,
                      _Delivers=[R(2)]),
                 inst(2, "app.QuestDeliver", _SerialNum=71, _Item=None),
                 inst(3, "app.QuestDeliverSelectData", _QuestID=30150, _Key=71)]
        diagnostics = collections.Counter()
        definitions, index = eq.decode_deliveries(insts, diagnostics)
        self.assertEqual(definitions, {30150: []})
        self.assertEqual(diagnostics["delivery_records_without_item_data"], 1)
        with self.assertRaises(ew.ExtractError):
            eq.decode_delivery_refs(insts, [R(3)], index)

    def test_zero_delivery_item_sentinel_is_counted_but_not_shipped(self):
        insts = [inst(1, "app.QuestContextData.DeliverData", _IDValue=30150,
                      _Delivers=[R(2)]),
                 inst(2, "app.QuestDeliver", _SerialNum=71, _Item=R(3)),
                 inst(3, "app.QuestDeliver.ItemData", _IncompletePossible=True,
                      _Operator=0, _Value=[R(4)]),
                 inst(4, "app.QuestDeliver.ItemData.ValueInfo", _ItemID=[0, 378],
                      _Count=1, _IsAllItem=False, _IsInfinite=False,
                      _IgnoreRestrictionItem=[])]
        diagnostics = collections.Counter()
        definitions, _ = eq.decode_deliveries(insts, diagnostics)
        self.assertEqual(definitions[30150][0]["groups"][0]["item_ids"], [378])
        self.assertEqual(diagnostics["delivery_item_id_zero_sentinels"], 1)


H = {name: 0x5100 + n for n, name in enumerate((
    "app.quest.action.NpcControlParam", "app.quest.condition.CheckHasItemParam.ItemInfo",
    "app.QuestContextData.ContextData", "app.QuestContextData.DeliverData", "app.QuestDeliver",
    "app.QuestDeliver.ItemData", "app.QuestDeliver.ItemData.ValueInfo",
    "app.QuestLogResource.QuestLogTaskDestination", "app.QuestLogResource",
    "app.QuestLogResource.QuestLogTaskData", "app.QuestLogConciergeData",
    "app.QuestDeliverSelectData"))}


def _type(name, *fields):
    return "%x" % H[name], {"name": name, "fields": [list(f) for f in fields]}


QLAYOUTS = {"types": dict([
    _type("app.quest.action.NpcControlParam", ("_NpcID", "U32", 4, 4, False)),
    _type("app.quest.condition.CheckHasItemParam.ItemInfo", ("_ID", "S32", 4, 4, False)),
    _type("app.QuestContextData.ContextData", ("_IDValue", "S32", 4, 4, False),
          ("CastNPCIDs", "U32", 4, 4, True)),
    _type("app.QuestContextData.DeliverData", ("_IDValue", "S32", 4, 4, False),
          ("_Delivers", "Object", 4, 4, True)),
    _type("app.QuestDeliver", ("_SerialNum", "S32", 4, 4, False), ("_Item", "Object", 4, 4, False)),
    _type("app.QuestDeliver.ItemData", ("_Value", "Object", 4, 4, True),),
    _type("app.QuestDeliver.ItemData.ValueInfo", ("_ItemID", "S32", 4, 4, True)),
    _type("app.QuestLogResource.QuestLogTaskDestination", ("_CharaID", "U32", 4, 4, False),
          ("_KeyLocation", "S32", 4, 4, False)),
    _type("app.QuestLogResource", ("_QuestId", "S32", 4, 4, False),
          ("_TaskList", "Object", 4, 4, True), ("_ConciergeList", "Object", 4, 4, True)),
    _type("app.QuestLogResource.QuestLogTaskData", ("_HasDestination", "Bool", 1, 1, False),
          ("_Destinations", "Object", 4, 4, True)),
    _type("app.QuestLogConciergeData", ("_TaskIndex", "S32", 4, 4, False),
          ("_Destinations", "Object", 4, 4, True)),
    _type("app.QuestDeliverSelectData", ("_QuestID", "S32", 4, 4, False),
          ("_Key", "S32", 4, 4, False)),
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
        (h("app.QuestDeliver"), [71, 0]),
    ])
    scene_a = scn_file([(h("app.quest.action.NpcControlParam"), [103]),
                        (h("app.quest.condition.CheckHasItemParam.ItemInfo"), [201])])
    scene_b = scn_file([(h("app.quest.action.NpcControlParam"), [103])]) + bytes(1)
    return {
        eq.CONTEXT_PATH: context,
        eq.scene_path(20090): scene_a,
        eq.scene_path(10040): scene_b,
        eq.journal_path(20090): usr_file([dest_inst(101, 2308),
            (h("app.QuestLogResource"), [20090, [], []])]),
        eq.journal_path(30010): usr_file([dest_inst(104, 2400),
            (h("app.QuestLogResource"), [30010, [], []])]),
    }


E2E_OUT = {"version": 2, "pak": "7:9", "quests": {
    "10040": {"cast": [], "npcs": [], "items": [], "dest": [], "decoded": False,
              "tasks": [], "guidance": [], "deliveries": [], "reward_diagnostics": []},
    "30010": {"cast": [], "npcs": [], "items": [], "dest": [{"cid": 104, "key": 2400}],
              "decoded": False, "tasks": [], "guidance": [], "deliveries": [], "reward_diagnostics": []},
    "20090": {"cast": [101], "npcs": [103], "items": [201], "dest": [{"cid": 101, "key": 2308}],
              "decoded": True, "tasks": [], "guidance": [], "deliveries": [], "reward_diagnostics": []},
    "20141": {"cast": [102], "npcs": [], "items": [], "dest": [], "decoded": False,
              "tasks": [], "guidance": [], "deliveries": [], "reward_diagnostics": []}}}


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
        self.assertEqual(list(out["quests"]), ["10040", "20090", "20141", "30010"])
        self.assertEqual(lines[0], "quests 4, scenes 2, decoded 1, journals 2")
        self.assertEqual(lines[1], "entries: cast 2, npcs 1, items 1, dest 2")
        self.assertEqual(lines[2], "objectives: tasks 0, task destinations 0, concierge records 0, guidance destinations 0, deliveries 0, delivery refs 0")
        self.assertEqual(lines[3], "diagnostics: delivery item-id zero sentinels 0, records without quest id 0, records without item data 1, reward records 0, gift records 0, transformation records 0, reward diagnostics 0, eligible archive source descriptors 0")
        self.assertEqual(lines[4], "reward endpoints: closed single-talk Trigger members 0")
        self.assertTrue(lines[5].startswith("undecoded 10040: "))
        self.assertEqual(len(lines), 6)
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
        self.assertEqual(buf.getvalue().splitlines()[-1], "quests written: 4")

    def test_main_preserves_existing_output_when_reward_validation_fails(self):
        out_path = os.path.join(self.game, "quests.json")
        original = b"preserve previous artifact"
        with open(out_path, "wb") as f:
            f.write(original)
        key = os.path.join(self.game, "k.txt")
        with open(key, "w") as f:
            f.write("00")
        buf = io.StringIO()
        with mock.patch.object(eq, "load_layouts", return_value=QLAYOUTS), \
                mock.patch.object(eq, "decode_reward_diagnostics",
                                  side_effect=ew.ExtractError("duplicate reward processor id")), \
                contextlib.redirect_stdout(buf):
            code = eq.main(["--game", self.game, "--out", out_path, "--key", key])
        self.assertEqual(code, 1)
        self.assertEqual(buf.getvalue(), "duplicate reward processor id\n")
        with open(out_path, "rb") as f:
            self.assertEqual(f.read(), original)

    def _run_real_archive_oracle(self):
        game = os.path.join(chr(67) + chr(58) + chr(92), "Program Files (x86)",
                            "Steam", "steamapps", "common", "Dragons Dogma 2")
        key_hex = eq.key_check.read_key()
        if not os.path.isfile(os.path.join(game, ew.PAK_NAME)) or not key_hex:
            self.skipTest("local game archive or local key unavailable")
        out, lines = eq.extract(game, key_hex, eq.load_layouts())
        artifact_path = os.path.join(os.path.dirname(eq.HERE), "data", "Clairvoyance_quests.json")
        with open(artifact_path, encoding="utf-8") as artifact_file:
            self.assertEqual(json.load(artifact_file), out)
        self.assertEqual(out["pak"], "318966:1887616979")
        self.assertNotIn("reward_catalog_evidence", out)
        self.assertEqual(lines[0], "quests 122, scenes 114, decoded 105, journals 86")
        self.assertEqual(lines[2], "objectives: tasks 298, task destinations 341, concierge records 246, guidance destinations 240, deliveries 184, delivery refs 77")
        self.assertEqual(lines[3], "diagnostics: delivery item-id zero sentinels 15, records without quest id 1, records without item data 0, reward records 496, gift records 0, transformation records 0, reward diagnostics 124, eligible archive source descriptors 0")
        self.assertEqual(lines[4], "reward endpoints: closed single-talk Trigger members 17")
        quests = out["quests"]
        legacy_fields = ("cast", "npcs", "items", "dest", "decoded")
        fixture_path = os.path.join(os.path.dirname(__file__), "fixtures",
                                    "quests_v1_legacy.json")
        with open(fixture_path, encoding="utf-8") as fixture_file:
            legacy = json.load(fixture_file)
        self.assertEqual({qid: {field: quest.get(field) for field in legacy_fields}
                          for qid, quest in quests.items()}, legacy)
        key_targets = area_targets = npc_links = ref_count = group_count = item_id_count = 0
        delivery_count = 0
        top_level_reminders = destinations_with_refs = false_with_dest = 0
        show_flags = display_flags = update_flags = 0
        multi_nonempty = multi_with_empty = 0
        conditions = collections.Counter()
        negative_task_condition_qids = 0

        def walk(value):
            nonlocal negative_task_condition_qids
            if isinstance(value, dict):
                if "kind" in value:
                    conditions[value["kind"]] += 1
                    if value["kind"] == "quest_log_condition" and value["qid"] < 0:
                        negative_task_condition_qids += 1
                for child in value.values():
                    walk(child)
            elif isinstance(value, list):
                for child in value:
                    walk(child)

        for qid, quest in quests.items():
            deliveries = {d["key"]: d for d in quest["deliveries"]}
            self.assertEqual(len(deliveries), len(quest["deliveries"]))
            self.assertEqual(len({d["serial"] for d in quest["deliveries"]}), len(quest["deliveries"]))
            delivery_count += len(deliveries)
            task_sets = []
            nonempty_task_sets = []
            for delivery in quest["deliveries"]:
                for group in delivery["groups"]:
                    group_count += 1
                    item_id_count += len(group["item_ids"])
                    self.assertTrue(all(type(item_id) is int and 0 < item_id <= 2 ** 31 - 1
                                        for item_id in group["item_ids"]))
            for task in quest["tasks"]:
                self.assertEqual(task["index"], quest["tasks"].index(task))
                task_set = frozenset((d["cid"], d["key"]) for d in task["destinations"]
                                     if d["cid"] is not None or d["key"] is not None)
                task_sets.append(task_set)
                if task_set:
                    nonempty_task_sets.append(task_set)
                if not task["has_destination"] and task_set:
                    false_with_dest += 1
                for destination in task["destinations"]:
                    show_flags += destination["has_show_conditions"]
                    display_flags += destination["has_display_conditions"]
                    update_flags += destination["is_update_condition"]
                    walk(destination["show_conditions"])
                    walk(destination["display_conditions"])
            if len(set(nonempty_task_sets)) > 1:
                multi_nonempty += 1
            if len(set(task_sets)) > 1:
                multi_with_empty += 1
            for concierge in quest["guidance"]:
                self.assertEqual(concierge["index"], quest["guidance"].index(concierge))
                for destination in concierge["destinations"]:
                    if destination["target"]["kind"] == "key_location":
                        key_targets += 1
                    else:
                        self.assertEqual(destination["target"]["kind"], "local_area")
                        area_targets += 1
                    npc_links += destination["cid"] is not None
                    top_level_reminders += sum(c.get("kind") == "quest_log_reminder"
                                               for c in destination["register_conditions"])
                    destinations_with_refs += bool(destination["delivery"]["refs"])
                    walk(destination["register_conditions"])
                    walk(destination["conditions"])
                    for ref in destination["delivery"]["refs"]:
                        ref_count += 1
                        resolved = quests[str(ref["qid"])]["deliveries"]
                        match = next(d for d in resolved if d["key"] == ref["key"])
                        self.assertEqual(match["serial"], ref["serial"])
        self.assertEqual((key_targets, area_targets, npc_links, top_level_reminders, ref_count),
                         (226, 14, 144, 51, 77))
        self.assertEqual((multi_nonempty, multi_with_empty, false_with_dest,
                          show_flags, display_flags, update_flags, destinations_with_refs),
                         (57, 61, 52, 55, 27, 0, 73))
        self.assertEqual((group_count, item_id_count), (194, 1082))
        self.assertEqual(delivery_count, 184)
        self.assertEqual(conditions, collections.Counter({"quest_log_condition": 405,
            "quest_log_reminder": 53, "quest_variable": 103, "item": 10,
            "quest_variable_or": 6}))
        self.assertEqual(negative_task_condition_qids, 260)
        self.assertEqual(sum(len(quest["reward_diagnostics"]) for quest in quests.values()), 124)
        reward_diagnostics = [row for quest in quests.values()
                              for row in quest["reward_diagnostics"]]
        self.assertEqual(sum(row["family"] == "quest_reward" for row in reward_diagnostics), 124)
        self.assertTrue(all(row["eligibility"] == "unknown" for row in reward_diagnostics))
        self.assertTrue(all("sources" not in quest for quest in quests.values()))
        raw_hashes = {reward["name_hash"] for row in reward_diagnostics
                      for reward in row["reward_rows"]}
        self.assertTrue({801888944, 3741130030, 2856910244}.issubset(raw_hashes))
        self.assertTrue(all(set(reward) == {"ordinal", "name_hash"}
                            for row in reward_diagnostics for reward in row["reward_rows"]))
        self.assertTrue(all("runtime_reward_hash_to_item_count" in row["unresolved_joins"]
                            for row in reward_diagnostics))
        self.assertFalse(any("catalog_join" in reward
                             for row in reward_diagnostics for reward in row["reward_rows"]))

        spellbound = quests["30150"]
        self.assertEqual([task["index"] for task in spellbound["tasks"]],
                         list(range(len(spellbound["tasks"]))))
        self.assertGreaterEqual(len(spellbound["tasks"]), 2)
        self.assertFalse(any(d["key"] == 3262 for d in spellbound["tasks"][0]["destinations"]))
        self.assertTrue(any(d["key"] == 3262 for d in spellbound["tasks"][1]["destinations"]))
        refs = [ref for g in spellbound["guidance"] for d in g["destinations"]
                for ref in d["delivery"]["refs"]]
        self.assertEqual(len(refs), 4)
        self.assertEqual(len({(r["qid"], r["key"]) for r in refs}), 1)
        delivery = next(d for d in quests[str(refs[0]["qid"])]["deliveries"]
                        if d["key"] == refs[0]["key"])
        self.assertEqual(delivery["operator"], 0)
        self.assertEqual(len(delivery["groups"]), 5)
        self.assertEqual(sum(len(g["item_ids"]) for g in delivery["groups"]), 10)


class RealDataOracleTests(unittest.TestCase):
    def test_real_archive_oracle(self):
        ExtractTests._run_real_archive_oracle(self)


if __name__ == "__main__":
    unittest.main()
