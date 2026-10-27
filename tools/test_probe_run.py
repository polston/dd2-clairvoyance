"""Tests for the local in-game probe runner safety boundary."""

import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
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

    def test_comments_preserve_token_boundaries(self):
        source = 'return--[[ gap ]]sdk.create_resource("x")'
        self.assertEqual(probe_run.unsafe_probe_call(source), "sdk.create_resource")

    def test_identifier_boundaries_do_not_reject_unrelated_names(self):
        source = "local fake_sdk = {}; return fake_sdk.create_resource"
        self.assertIsNone(probe_run.unsafe_probe_call(source))

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
