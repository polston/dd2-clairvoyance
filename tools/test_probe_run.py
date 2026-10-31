"""Tests for the local in-game probe runner safety boundary."""

import os
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "probe"))
import run as probe_run  # noqa: E402


class ProbeSourceSafety(unittest.TestCase):
    def test_managed_construction_mutation_and_release_are_rejected(self):
        cases = {
            "local x = t:create_instance()": "create_instance",
            "x : set_field ('A', 1)": "set_field",
            "local x = o.add_ref(o)": "add_ref",
            "o:release()": "release",
            "local f = sdk.create_resource": "sdk.create_resource",
            'o:call("set_Enabled", false)': "set_Enabled",
            'o["call"](o, "set_Value", 1)': "set_Value",
        }
        for source, expected in cases.items():
            with self.subTest(source=source):
                self.assertEqual(probe_run.unsafe_probe_call(source), expected)

    def test_bracket_member_calls_are_rejected(self):
        cases = {
            'return sdk["create_resource"]("x")': "sdk.create_resource",
            'return (sdk)["create_resource"]("x")': "sdk.create_resource",
            'return sdk[ [=[create_resource]=] ]("x")': "sdk.create_resource",
            'return sdk[ [=[\ncreate_resource]=] ]("x")': "sdk.create_resource",
            'return (sdk).create_resource("x")': "sdk.create_resource",
            'return o["release"](o)': "release",
            'return o["re\\108ease"](o)': "release",
            "return o['set_field'](o, 'A', 1)": "set_field",
        }
        for source, expected in cases.items():
            with self.subTest(source=source):
                self.assertEqual(probe_run.unsafe_probe_call(source), expected)

    def test_dynamic_and_indirect_engine_access_is_rejected(self):
        cases = {
            'return sdk["create_" .. "resource"]("x")':
                "dynamic sdk access",
            'local s = sdk; return s.create_resource("x")':
                "indirect sdk access",
            'local f = o.call; return f(o, "set_Enabled", false)':
                "indirect managed call",
            'local method = "set_Enabled"; return o:call(method, false)':
                "dynamic managed method",
            'local method = "set_Enabled"; return o["call"](o, method, false)':
                "dynamic managed method",
            'return o:call("Dispose")': "raw managed call",
            'return o:call("get_Count")': "raw managed call",
            'local f = o["ca" .. "ll"]; return f(o, "set_Enabled", false)':
                "indirect managed call",
            'return o[method](o)': "dynamic member call",
            'return rawget(_G, "sdk").create_resource("x")':
                "indirect global access",
        }
        for source, expected in cases.items():
            with self.subTest(source=source):
                self.assertEqual(probe_run.unsafe_probe_call(source), expected)

    def test_secondary_code_loading_is_rejected(self):
        cases = {
            'return load("return sdk.create_resource(\\"x\\")")()': "load",
            'return loadfile("probe.lua")()': "loadfile",
            'return dofile("probe.lua")': "dofile",
            'return require(module_name)': "require",
            'return require("not.reviewed")': "require",
        }
        for source, expected in cases.items():
            with self.subTest(source=source):
                self.assertEqual(probe_run.unsafe_probe_call(source), expected)

    def test_reviewed_read_only_globals_remain_allowed(self):
        source = """
local D = _G.QNML_DEBUG
local qlm = sdk.get_managed_singleton("app.QuestLogManager")
local td = sdk.find_type_definition("app.QuestLogManager")
local world = require("Clairvoyance.world")
return D, qlm, td, world
"""
        self.assertIsNone(probe_run.unsafe_probe_call(source))

    def test_phase0_uses_the_reviewed_managed_call_capability(self):
        path = os.path.join(
            os.path.dirname(__file__), "probe", "objective_phase0.lua")
        with open(path, encoding="utf-8") as stream:
            source = stream.read()
        self.assertIn("reviewed_call", source)
        self.assertIn("reviewed_invoke", source)
        self.assertNotRegex(source, r":call\s*\(\s*name\b")
        tokens = probe_run._lua_tokens(source)
        needed = set()
        for pos, token in enumerate(tokens):
            if token in probe_run.REVIEWED_CAPABILITIES:
                self.assertLess(pos + 1, len(tokens))
                self.assertEqual(tokens[pos + 1], "(")
                args = probe_run._call_arguments(tokens, pos + 1)
                index = probe_run.REVIEWED_CAPABILITIES[token]
                self.assertGreater(len(args), index)
                self.assertEqual(len(args[index]), 1)
                self.assertIsInstance(args[index][0], tuple)
                needed.add(args[index][0][1])
        harness_path = os.path.join(
            os.path.dirname(__file__), "probe", "qnml_check.lua")
        with open(harness_path, encoding="utf-8") as stream:
            harness = stream.read()
        reviewed_block = harness.split("reviewed_methods = {", 1)[1].split("\n}", 1)[0]
        allowed = set(re.findall(r'\["([^"]+)"\]\s*=\s*true', reviewed_block))
        talk_methods = {
            "getTalkEventInitialSpeaker", "isEventPlayable",
            "canTalkEventInteract", "getHistory"}
        forgery_methods = {
            "get_IsEnableFake", "get__Golden", "isFakeShopKeeped",
            "isFakeShopRemainingMinute"}
        monster_methods = {
            "get_Transform", "get_UniversalPosition", "get_IsDead"}
        brine_methods = {"get_FilterInfo", "castRay"}
        self.assertEqual(needed | talk_methods | forgery_methods | monster_methods |
                         brine_methods,
                         probe_run.REVIEWED_METHODS)
        self.assertEqual(allowed, probe_run.REVIEWED_METHODS)
        self.assertEqual(needed - allowed, set())

    def test_reviewed_capabilities_require_direct_allowlisted_literals(self):
        rejected = {
            'return reviewed_call(o, "set_Enabled", false)':
                "unreviewed managed method",
            'return reviewed_call(o, method)':
                "unreviewed managed method",
            'local f = reviewed_call; return f(o, "get_Count")':
                "indirect reviewed call",
            'return reviewed_invoke(method, o, name)':
                "unreviewed managed method",
            'local f = reviewed_invoke; return f(method, o, "getContext")':
                "indirect reviewed call",
        }
        for source, expected in rejected.items():
            with self.subTest(source=source):
                self.assertEqual(probe_run.unsafe_probe_call(source), expected)
        for source in (
                'return reviewed_call(o, "get_Count")',
                'return reviewed_try_call(o, "get_Count")',
                'return reviewed_invoke(method, o, "getContext")'):
            with self.subTest(source=source):
                self.assertIsNone(probe_run.unsafe_probe_call(source))
        self.assertIsNone(
            probe_run.unsafe_probe_call("return reviewed_array_elements(entries)"))
        for source in (
                "local f = reviewed_array_elements; return f(entries)",
                "return reviewed_array_elements(entries, extra)"):
            with self.subTest(source=source):
                self.assertEqual(
                    probe_run.unsafe_probe_call(source),
                    "unreviewed array read")

    def test_talk_event_methods_are_reviewed_literals(self):
        methods = (
            "getTalkEventInitialSpeaker", "isEventPlayable",
            "canTalkEventInteract", "getHistory")
        for method in methods:
            source = 'return reviewed_call(tem, "%s", value)' % method
            with self.subTest(method=method):
                self.assertEqual(
                    probe_run.unsafe_probe_call(source),
                    None)
        near_misses = (
            "getTalkEventInitialSpeakerExtra", "isEventPlayableNow",
            "canTalkEventInteractById", "getHistoryList")
        for method in near_misses:
            source = 'return reviewed_call(tem, "%s", value)' % method
            with self.subTest(near_miss=method):
                self.assertEqual(
                    probe_run.unsafe_probe_call(source),
                    "unreviewed managed method")
        self.assertEqual(
            probe_run.unsafe_probe_call(
                'return reviewed_call(tem, method, value)'),
            "unreviewed managed method")

    def test_monster_probe_getters_are_reviewed_literals(self):
        methods = ("get_Transform", "get_UniversalPosition", "get_IsDead")
        for method in methods:
            source = 'return reviewed_call(character, "%s")' % method
            with self.subTest(method=method):
                self.assertIsNone(probe_run.unsafe_probe_call(source))
        near_misses = ("get_TransformExtra", "get_UniversalPositionExtra",
                       "get_IsDeadExtra", "isDead")
        for method in near_misses:
            source = 'return reviewed_call(character, "%s")' % method
            with self.subTest(near_miss=method):
                self.assertEqual(
                    probe_run.unsafe_probe_call(source),
                    "unreviewed managed method")

    def test_brine_probe_reads_are_exact_and_setters_stay_rejected(self):
        for method in ("get_FilterInfo", "castRay"):
            source = 'return reviewed_call(object, "%s")' % method
            with self.subTest(method=method):
                self.assertIsNone(probe_run.unsafe_probe_call(source))
        for method in ("set_FilterInfo", "castSphere", "initCastRayQuery"):
            source = 'return reviewed_call(object, "%s")' % method
            with self.subTest(method=method):
                self.assertEqual(
                    probe_run.unsafe_probe_call(source),
                    "unreviewed managed method")

    def test_forgery_state_methods_are_reviewed_literals(self):
        methods = ("isFakeShopKeeped", "isFakeShopRemainingMinute")
        for method in methods:
            source = 'return reviewed_call(item_manager, "%s")' % method
            with self.subTest(method=method):
                self.assertIsNone(probe_run.unsafe_probe_call(source))
        for method in ("isFakeShopKeepedExtra", "isFakeShopRemainingMinutes"):
            source = 'return reviewed_call(item_manager, "%s")' % method
            with self.subTest(near_miss=method):
                self.assertEqual(
                    probe_run.unsafe_probe_call(source),
                    "unreviewed managed method")
        probe = Path(__file__).parent / "probe" / "forgery_money.lua"
        source = probe.read_text(encoding="utf-8")
        self.assertIn("reviewed_array_elements(entries)", source)
        self.assertNotIn(":get_elements()", source)
        self.assertNotIn("golden=%s", source)
        self.assertNotIn("talk_gold=%s", source)
        self.assertIn("golden_readable=%s", source)

    def test_comments_preserve_token_boundaries(self):
        source = 'return--[[ gap ]]sdk.create_resource("x")'
        self.assertEqual(probe_run.unsafe_probe_call(source), "sdk.create_resource")

    def test_identifier_boundaries_do_not_reject_unrelated_names(self):
        source = "local fake_sdk = {}; return fake_sdk.create_resource"
        self.assertIsNone(probe_run.unsafe_probe_call(source))

    def test_phase0_objective_probe_is_bounded_and_read_only(self):
        path = os.path.join(
            os.path.dirname(__file__), "probe", "objective_phase0.lua")
        with open(path, encoding="utf-8") as stream:
            source = stream.read()

        self.assertIsNone(probe_run.unsafe_probe_call(source))
        self.assertNotIn("D.set", source)
        self.assertNotIn("json.dump_file", source)
        self.assertNotRegex(source, r"\b(?:fs|io)\s*[\.:\[]")
        self.assertIn("local CAP =", source)
        for family in (
                "destination", "concierge", "shop", "pickup", "chest",
                "loot", "grant", "transform", "delivery", "unresolved"):
            with self.subTest(family=family):
                self.assertIn('section("%s"' % family, source)
        self.assertNotRegex(
            source,
            r"L\([^\n]*(?:\.x|\.y|\.z|UniversalPosition|Position)")
        self.assertIn("for key, row in pairs(rows) do", source)
        self.assertNotIn(
            "for i = 1, math.min(n, cap) do out[#out + 1] = rows[i] end",
            source)
        self.assertIn("return value:get_element(i)", source)
        self.assertIn('qlm:get_field("_QuestLogInfoDict")', source)
        self.assertIn('F(gm, "<ManagedGimmicksByIDs>k__BackingField")', source)
        self.assertIn('find_item_context_method("app.ContextHolder")', source)
        self.assertIn('"RestoredContexts", "Contexts"', source)
        self.assertIn("local function current_world_output", source)
        self.assertIn("adapter.item_locations", source)
        self.assertIn('pcall(wt.q, "input", nil)', source)

    def test_phase0_probe_fails_closed_at_reviewed_evidence_boundaries(self):
        path = os.path.join(
            os.path.dirname(__file__), "probe", "objective_phase0.lua")
        with open(path, encoding="utf-8") as stream:
            source = stream.read()

        # REFramework arrays can be direct wrappers or userdata vectors;
        # counts must be integral and non-negative before indexing.
        self.assertIn("local function valid_count", source)
        self.assertIn("return value:get_size()", source)
        self.assertIn("local rows_type = type(rows)", source)
        self.assertIn("math.tointeger(value) == value and value >= 0", source)

        # Native evaluator exceptions and original destination identity/gates
        # stay visible instead of being collapsed into an ordinary nil.
        self.assertNotIn("local function call_result", source)
        self.assertIn('reviewed_try_call(dest, "evaluateShow")', source)
        self.assertIn('reviewed_try_call(task, "getActiveDestinations")', source)
        self.assertIn('reviewed_try_call(dest, "evaluateRegisterCondition", qid)', source)
        self.assertIn('F(task, "_HasDestination")', source)
        self.assertIn('F(dest, "_SetDestination")', source)
        self.assertIn('F(dest, "_HasShowConditions")', source)
        self.assertIn('F(dest, "_HasDisplayConditions")', source)
        self.assertIn("source_index", source)
        self.assertIn("object_id", source)

        # Availability evidence uses the repository's measured read paths and
        # cannot turn unreadable identifiers/state into a positive example.
        self.assertIn('F(gimmick, "ItemId")', source)
        self.assertIn('reviewed_call(gimmick, "get_GmContext")', source)
        self.assertIn("local function item_context_like", source)
        self.assertIn("local function save_item_contexts", source)
        self.assertIn('reviewed_call(gimmick, "get_UniqId")', source)
        self.assertIn("debug.getupvalue(reads.save_records", source)
        self.assertIn('F(value, "UniqueID")', source)
        self.assertIn('"holder_unique_id"', source)
        self.assertIn('F(F(drop, "MyContext"), "_ItemId")', source)
        self.assertIn('F(drop, "<IsDeleted>k__BackingField")', source)
        self.assertIn("chest_evidence_readable", source)
        self.assertIn("shop_joined_finite", source)
        self.assertIn("if item_id == nil then return nil, nil, 1 end", source)

        # Grants without a current-task join and incomplete/truncated delivery
        # expressions remain explicitly unresolved.
        self.assertIn("grant_task_ownership_unknown", source)
        self.assertIn("task_owned=", source)
        self.assertIn("delivery_refs_truncated", source)
        self.assertIn("delivery_ref_unresolved", source)
        self.assertIn('F(item_data, "_IncompletePossible")', source)
        self.assertIn('F(value, "_Count")', source)
        self.assertIn('F(value, "_IgnoreRestrictionItem")', source)
        self.assertIn("resolved=%s", source)
        self.assertIn("focus_quests_truncated", source)
        self.assertIn("destination_source_list_truncated", source)
        self.assertIn("concierge_destinations_truncated", source)
        self.assertIn("shop_catalog_truncated", source)
        self.assertIn("pickup_scan_truncated", source)
        self.assertIn("chest_rows_truncated", source)
        self.assertIn("loot_rows_truncated", source)
        self.assertIn("grant_processors_truncated", source)
        self.assertIn("if skipped > 0 then return nil, nil, skipped end", source)

    def test_comments_and_strings_do_not_trigger_the_guard(self):
        source = """
-- x:create_instance()
local a = "sdk.create_resource('x')"
local b = 'o:release()'
--[[ y:set_field('A', 1) ]]
return a .. b
"""
        self.assertIsNone(probe_run.unsafe_probe_call(source))


class CrashDetection(unittest.TestCase):
    def _fixture(self):
        temp = tempfile.TemporaryDirectory()
        root = temp.name
        data = os.path.join(root, "reframework", "data")
        os.makedirs(data)
        log = os.path.join(root, "re2_framework_log.txt")
        command = os.path.join(data, "qnml_cmd.txt")
        chunk = os.path.join(root, "probe.lua")
        for path, text in ((log, "start\n"), (command, ""),
                           (chunk, "return 'ok'\n")):
            with open(path, "w", encoding="utf-8") as stream:
                stream.write(text)
        return temp, root, log, chunk

    def test_engine_exception_and_dump_write_are_fatal(self):
        self.assertEqual(probe_run.crash_evidence(
            "[REFramework] [error] Exception occurred: c0000005"),
            "engine exception")
        self.assertEqual(probe_run.crash_evidence(
            "Attempting to write dump to reframework_crash.dmp"),
            "crash dump write")

    def test_unrelated_mod_error_is_not_engine_crash_evidence(self):
        self.assertIsNone(probe_run.crash_evidence(
            "[Clairvoyance] error: fixture"))

    def test_changed_dump_stamp_is_fatal(self):
        self.assertFalse(probe_run.crash_dump_changed((10, 20), (10, 20)))
        self.assertTrue(probe_run.crash_dump_changed((10, 20), (11, 20)))
        self.assertTrue(probe_run.crash_dump_changed(None, (1, 1)))

    def test_runner_catches_crash_after_success_line(self):
        temp, root, log, chunk = self._fixture()
        self.addCleanup(temp.cleanup)
        sleeps = 0

        def fake_sleep(_seconds):
            nonlocal sleeps
            sleeps += 1
            line = ("CHK cmd ok=true ok\n" if sleeps == 1 else
                    "[REFramework] [error] Exception occurred: c0000005\n")
            with open(log, "a", encoding="utf-8") as stream:
                stream.write(line)

        clock = 0.0

        def fake_time():
            nonlocal clock
            clock += 0.1
            return clock

        output = StringIO()
        argv = ["run.py", chunk, "5", "--game", root]
        with (mock.patch.object(sys, "argv", argv),
              mock.patch.object(probe_run.time, "sleep", fake_sleep),
              mock.patch.object(probe_run.time, "time", fake_time),
              redirect_stdout(output)):
            code = probe_run.main()
        self.assertEqual(code, 1)
        self.assertIn("CRASH: engine exception", output.getvalue())

    def test_runner_catches_dump_change_after_success_line(self):
        temp, root, log, chunk = self._fixture()
        self.addCleanup(temp.cleanup)
        dump = os.path.join(root, "reframework_crash.dmp")
        with open(dump, "wb") as stream:
            stream.write(b"old")
        sleeps = 0

        def fake_sleep(_seconds):
            nonlocal sleeps
            sleeps += 1
            if sleeps == 1:
                with open(log, "a", encoding="utf-8") as stream:
                    stream.write("CHK cmd ok=true ok\n")
            else:
                with open(dump, "wb") as stream:
                    stream.write(b"new crash dump")

        clock = 0.0

        def fake_time():
            nonlocal clock
            clock += 0.1
            return clock

        output = StringIO()
        argv = ["run.py", chunk, "5", "--game", root]
        with (mock.patch.object(sys, "argv", argv),
              mock.patch.object(probe_run.time, "sleep", fake_sleep),
              mock.patch.object(probe_run.time, "time", fake_time),
              redirect_stdout(output)):
            code = probe_run.main()
        self.assertEqual(code, 1)
        self.assertIn("CRASH: crash dump changed", output.getvalue())

    def test_runner_reports_crash_before_success_as_crash_not_timeout(self):
        temp, root, log, chunk = self._fixture()
        self.addCleanup(temp.cleanup)

        def fake_sleep(_seconds):
            with open(log, "a", encoding="utf-8") as stream:
                stream.write("[REFramework] [error] Exception occurred: c0000005\n")

        output = StringIO()
        argv = ["run.py", chunk, "5", "--game", root]
        with (mock.patch.object(sys, "argv", argv),
              mock.patch.object(probe_run.time, "sleep", fake_sleep),
              redirect_stdout(output)):
            code = probe_run.main()
        self.assertEqual(code, 1)
        self.assertIn("CRASH: engine exception", output.getvalue())
        self.assertNotIn("TIMEOUT", output.getvalue())

    def test_runner_returns_failure_for_harness_rejection(self):
        temp, root, log, chunk = self._fixture()
        self.addCleanup(temp.cleanup)

        def fake_sleep(_seconds):
            with open(log, "a", encoding="utf-8") as stream:
                stream.write("CHK cmd ok=false unsafe probe call: release\n")

        output = StringIO()
        argv = ["run.py", chunk, "5", "--game", root]
        with (mock.patch.object(sys, "argv", argv),
              mock.patch.object(probe_run.time, "sleep", fake_sleep),
              redirect_stdout(output)):
            code = probe_run.main()
        self.assertEqual(code, 1)
        self.assertIn("cmd ok=false", output.getvalue())


if __name__ == "__main__":
    unittest.main()
