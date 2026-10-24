"""Offline tests for the hint authoring tools. Never touches the network."""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(__file__))
import hints_check  # noqa: E402
import hints_fetch  # noqa: E402
import hints_merge_pins  # noqa: E402


def words(n, prefix="w"):
    return " ".join("%s%d" % (prefix, i) for i in range(n))


class Normalize(unittest.TestCase):
    def test_normalize(self):
        self.assertEqual(hints_check.normalize("Go, NORTH!  now"), ["go", "north", "now"])


class SharedRuns(unittest.TestCase):
    def test_eight_fail_seven_pass(self):
        ref = hints_check.normalize(words(20))
        self.assertTrue(hints_check.shared_runs(hints_check.normalize(words(8)), ref))
        self.assertEqual(hints_check.shared_runs(hints_check.normalize(words(7)), ref), [])

    def test_punctuation_does_not_hide(self):
        a = hints_check.normalize("Go north, then; turn LEFT at the old bridge, quickly!")
        b = hints_check.normalize("go north then turn left at the old bridge quickly")
        self.assertTrue(hints_check.shared_runs(a, b))


class Check(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.addCleanup(self.d.cleanup)
        self.ref = os.path.join(self.d.name, "ref")
        os.makedirs(os.path.join(self.ref, "5"))
        self.hints = os.path.join(self.d.name, "h.json")

    def run_main(self, hints, ref=None):
        with open(self.hints, "w") as f:
            json.dump(hints, f)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = hints_check.main(["--hints", self.hints, "--ref", ref or self.ref])
        return code, out.getvalue()

    def test_copy_in_txt_fails_with_qid_and_run(self):
        with open(os.path.join(self.ref, "5", "1.txt"), "w") as f:
            f.write("intro " + words(10))
        code, out = self.run_main({"5": {"quest": "x", "steps": {"0": {"text": words(8)}}}})
        self.assertEqual(code, 1)
        self.assertIn("qid 5", out)
        self.assertIn(words(8), out)

    def test_paraphrase_passes(self):
        ref = hints_check.normalize(
            "Head north along the river road until you reach the broken bridge, "
            "then speak to the ferryman waiting on the far bank.")
        mine = hints_check.normalize(
            "Follow the river road to the collapsed bridge and talk with the ferryman across the water.")
        self.assertEqual(hints_check.shared_runs(mine, ref), [])

    def test_non_numeric_hint_key_not_read(self):
        os.makedirs(os.path.join(self.d.name, "ref", "x"), exist_ok=True)
        with open(os.path.join(self.ref, "..", "stray.txt"), "w") as f:
            f.write(words(10))
        self.assertEqual(hints_check.check({"..": {"quest": words(8)}}, self.ref), [])

    def test_html_ignored(self):
        with open(os.path.join(self.ref, "5", "1.html"), "w") as f:
            f.write(words(10))
        code, _ = self.run_main({"5": {"steps": {"0": {"text": words(8)}}}})
        self.assertEqual(code, 0)

    def test_no_reference_folder_with_text_fails(self):
        code, out = self.run_main({"5": {"quest": words(9)}}, ref=os.path.join(self.d.name, "none"))
        self.assertEqual(code, 1)
        self.assertIn("no reference pages", out)

    def test_no_reference_folder_without_text_skips(self):
        code, out = self.run_main({"5": {"items": [300]}}, ref=os.path.join(self.d.name, "none"))
        self.assertEqual(code, 0)
        self.assertIn("skipped: no hint text", out)


class MergePins(unittest.TestCase):
    pin = {"qid": 7, "idx": 2, "label": "Gate", "x": 1.0, "y": 2.0, "z": 3.0}

    def test_same_pin_twice_added_once(self):
        h = {}
        self.assertEqual(hints_merge_pins.merge(h, [self.pin, dict(self.pin)]), 1)
        self.assertEqual(h["7"]["steps"]["2"]["pins"],
                         [{"x": 1.0, "y": 2.0, "z": 3.0, "label": "Gate"}])

    def test_absent_qid_creates_entry_and_keeps_existing(self):
        h = {"9": {"quest": "q"}}
        hints_merge_pins.merge(h, [self.pin])
        self.assertIn("7", h)
        self.assertEqual(h["9"], {"quest": "q"})

    def test_malformed_pin_names_position(self):
        bad = [dict(self.pin), dict(self.pin, idx=2.7)]
        with self.assertRaisesRegex(ValueError, "pin 1"):
            hints_merge_pins.merge({}, bad)
        with self.assertRaisesRegex(ValueError, "pin 0"):
            hints_merge_pins.merge({}, [{"qid": 7}])
        with self.assertRaisesRegex(ValueError, "pin 0"):
            hints_merge_pins.merge({}, [dict(self.pin, label=5)])

    def test_main_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            pf, hf = os.path.join(d, "p.json"), os.path.join(d, "h.json")
            with open(pf, "w") as f:
                json.dump([self.pin], f)
            with open(hf, "w") as f:
                f.write("{}")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(hints_merge_pins.main(["--pins", pf, "--hints", hf]), 0)
            with open(hf) as f:
                self.assertEqual(len(json.load(f)["7"]["steps"]["2"]["pins"]), 1)


class Fetch(unittest.TestCase):
    def test_parse_sources(self):
        t = "# c\n\n12 example.invalid/a\n13 example.invalid/b\n"
        self.assertEqual(list(hints_fetch.parse_sources(t)),
                         [("12", "example.invalid/a"), ("13", "example.invalid/b")])
        with self.assertRaises(ValueError):
            list(hints_fetch.parse_sources("12\n"))

    def test_bad_qids_rejected(self):
        for q in ("../x", "/abs/path", "..", "1a", "C" + ":" + "x"):
            with self.assertRaises(ValueError, msg=q):
                list(hints_fetch.parse_sources("%s example.invalid/a" % q))

    def test_redirect_to_other_scheme_refused(self):
        h = hints_fetch._SafeRedirect()
        with self.assertRaises(ValueError):
            h.redirect_request(None, None, 302, "Found", {}, "ftp" + "://example.invalid/x")

    def test_visible_text_drops_scripts(self):
        t = hints_fetch.visible_text(
            "<html><head><title>t</title></head><body><script>x()</script>"
            "<p>Go  north</p><p>now</p></body></html>")
        self.assertEqual(t, "Go north\nnow\n")

    def test_rejects_non_http(self):
        with self.assertRaises(ValueError):
            hints_fetch.fetch("example.invalid/page")

    def test_main_writes_html_and_txt_without_network(self):
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "s.txt"), os.path.join(d, "out")
            with open(src, "w") as f:
                f.write("5 example.invalid/a\n5 example.invalid/b\n")
            with mock.patch.object(hints_fetch, "fetch", return_value="<p>Hello there</p>"), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(hints_fetch.main(["--sources", src, "--out", out]), 0)
            self.assertEqual(sorted(os.listdir(os.path.join(out, "5"))),
                             ["1.html", "1.txt", "2.html", "2.txt"])
            with open(os.path.join(out, "5", "2.txt")) as f:
                self.assertEqual(f.read(), "Hello there\n")


if __name__ == "__main__":
    unittest.main()
