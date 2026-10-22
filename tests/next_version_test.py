import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
import next_version as nv


def c(subject, body=""):
    return (subject, body)


class ParseTest(unittest.TestCase):
    def test_plain(self):
        p = nv.parse_subject("feat: add thing")
        self.assertEqual((p.type, p.scope, p.breaking, p.description), ("feat", None, False, "add thing"))

    def test_scope(self):
        p = nv.parse_subject("fix(map): stop crash")
        self.assertEqual((p.type, p.scope, p.breaking, p.description), ("fix", "map", False, "stop crash"))

    def test_bang(self):
        self.assertTrue(nv.parse_subject("feat!: drop api").breaking)
        p = nv.parse_subject("refactor(core)!: rename")
        self.assertTrue(p.breaking)
        self.assertEqual(p.scope, "core")

    def test_invalid(self):
        for s in ["", "added stuff", "Feat: x", "feat:x", "feat: ", "wip: x", "feat(: x", "feat(a b): x"]:
            self.assertIsNone(nv.parse_subject(s), s)


class BumpTest(unittest.TestCase):
    def test_no_release(self):
        self.assertIsNone(nv.bump("1.2.3", [c("docs: x"), c("ci: y"), c("chore: z")]))
        self.assertIsNone(nv.bump("1.2.3", []))

    def test_patch_fix_and_perf(self):
        self.assertEqual(nv.bump("1.2.3", [c("fix: x")]), "1.2.4")
        self.assertEqual(nv.bump("1.2.3", [c("perf: x")]), "1.2.4")

    def test_minor(self):
        self.assertEqual(nv.bump("1.2.3", [c("fix: a"), c("feat(x): b")]), "1.3.0")

    def test_major_bang(self):
        self.assertEqual(nv.bump("1.2.3", [c("feat: a"), c("fix!: b")]), "2.0.0")
        self.assertEqual(nv.bump("1.2.3", [c("chore(deps)!: b")]), "2.0.0")

    def test_major_footer(self):
        body = "Explain.\n\nBREAKING CHANGE: old config no longer loads"
        self.assertEqual(nv.bump("1.2.3", [c("fix: a", body)]), "2.0.0")

    def test_footer_must_start_line(self):
        self.assertIsNone(nv.bump("1.2.3", [c("docs: a", "see BREAKING CHANGE: nope")]))

    def test_breaking_change_hyphen_footer(self):
        self.assertEqual(nv.bump("0.9.1", [c("docs: a", "BREAKING-CHANGE: x")]), "1.0.0")

    def test_nonconforming_ignored(self):
        self.assertIsNone(nv.bump("1.0.0", [c("random words"), c("Merge pull request #1")]))


class NotesTest(unittest.TestCase):
    def test_groups(self):
        commits = [
            c("feat(map): add pins"),
            c("fix: stop crash"),
            c("perf(core): faster"),
            c("docs: ignore me"),
            c("feat!: new format"),
            c("fix: second", "BREAKING CHANGE: gone"),
        ]
        out = nv.notes(commits)
        self.assertIn("## Breaking changes", out)
        self.assertIn("## Features", out)
        self.assertIn("## Fixes", out)
        self.assertIn("- **map**: add pins", out)
        self.assertIn("- stop crash", out)
        self.assertIn("- **core**: faster", out)
        self.assertNotIn("ignore me", out)
        self.assertNotIn("feat:", out)
        self.assertLess(out.index("Breaking changes"), out.index("Features"))
        self.assertLess(out.index("Features"), out.index("Fixes"))
        # breaking commits listed under breaking only
        self.assertEqual(out.count("new format"), 1)

    def test_omits_empty(self):
        out = nv.notes([c("fix: only")])
        self.assertNotIn("Features", out)
        self.assertNotIn("Breaking", out)
        self.assertIn("## Fixes", out)

    def test_empty(self):
        self.assertEqual(nv.notes([c("docs: x")]).strip(), "")


class CheckTest(unittest.TestCase):
    def test_accepts(self):
        self.assertEqual(nv.check(["feat: a", "fix(x)!: b", "Merge branch 'x'", "revert: y"]), [])

    def test_rejects(self):
        self.assertEqual(nv.check(["ok: nope", "feat: fine", "just words"]), ["ok: nope", "just words"])

    def test_blank_lines_skipped(self):
        self.assertEqual(nv.check(["", "docs: x", ""]), [])


class TagTest(unittest.TestCase):
    def test_parse_tag(self):
        self.assertEqual(nv.parse_tag("v1.2.3"), (1, 2, 3))
        self.assertIsNone(nv.parse_tag("v1.2"))
        self.assertIsNone(nv.parse_tag("1.2.3"))
        self.assertIsNone(nv.parse_tag("v1.2.3-rc1"))


if __name__ == "__main__":
    unittest.main()
