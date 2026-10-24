"""Offline tests for build_layouts. Run from the repo root:
python -m unittest discover -s tools -p "test_build_layouts.py"
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_layouts as bl  # noqa: E402


def write_dump(path, entries):
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(entries, indent=4))


def entry(fqn, parent=None, fields=None):
    d = {"fqn": fqn}
    if parent is not None:
        d["parent"] = parent
    if fields is not None:
        d["RSZ"] = [{"potential_name": n, "code": c, "align": 4, "size": "4", "array": a, "type": t}
                    for n, c, t, a in fields]
    return d


class LayoutWalkTests(unittest.TestCase):
    def minimal(self, extra, drop=()):
        stub_fields = [("f", "U32", "System.UInt32", False)]
        counter = iter(range(10000))

        def nxt():
            return "%x" % (0x1000 + next(counter))
        stubs = {}
        for n in bl.WANTED_TYPES:
            stubs[n] = entry(nxt(), fields=stub_fields)
        for n in bl.QUEST_ROOTS:
            stubs[n] = entry(nxt(), fields=stub_fields)
        for n in bl.NATIVE_LAYOUTS:
            stubs[n] = entry(nxt())
        stubs["via.Behavior"] = entry(nxt(), parent="via.Component")
        merged = {**stubs, **extra}
        for n in drop:
            merged.pop(n, None)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = os.path.join(tmp.name, "dump.json")
        write_dump(path, merged)
        return bl.read_dump(path)

    def extras(self, items):
        return {n: entry("%x" % (0x2000 + j), **kw) for j, (n, kw) in enumerate(items)}

    def walk_items(self):
        u32 = [("x", "U32", "System.UInt32", False)]
        return [
            ("app.QuestProcessor", dict(fields=[("Process", "Object", "t.Base", False)])),
            ("t.Base", dict(fields=u32)),
            ("t.Sub", dict(parent="t.Base", fields=[("_l", "Object", "t.Leaf[]", True)])),
            ("t.Leaf", dict(fields=[("_g", "Object", "System.Collections.Generic.List`1<t.Arg>", True)])),
            ("t.Arg", dict(fields=u32)),
            ("t.Unrelated", dict(fields=u32)),
        ]

    def test_read_dump(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = os.path.join(tmp.name, "dump.json")
        noname = entry("C3", fields=[("_y", "U32", "System.UInt32", False)])
        del noname["RSZ"][0]["potential_name"]
        write_dump(path, {
            "t.A": entry("A1", parent="via.Behavior", fields=[("_x", "U32", "System.UInt32", False)]),
            "t.Zero": entry("0", fields=[("_x", "U32", "System.UInt32", False)]),
            "t.NoRsz": entry("B2"),
            "t.NoName": noname,
        })
        d = bl.read_dump(path)
        self.assertEqual(d["t.A"], {"fqn": "a1", "parent": "via.Behavior",
                                    "fields": [["_x", "U32", 4, 4, False, "System.UInt32"]]})
        self.assertNotIn("t.Zero", d)
        self.assertIsNone(d["t.NoRsz"]["fields"])
        self.assertIsNone(d["t.NoName"]["fields"][0][0])

    def test_field_type_names(self):
        f = bl.field_type_names
        self.assertEqual(f("t.B[]"), {"t.B"})
        self.assertEqual(f("System.Collections.Generic.List`1<t.C>"),
                         {"System.Collections.Generic.List`1<t.C>", "t.C"})
        self.assertEqual(
            f("app.ClassSelector`1[[t.D, application, Version=0.0.0.0, Culture=neutral, PublicKeyToken=null]][]"),
            {"app.ClassSelector`1<t.D>", "t.D"})
        self.assertEqual(
            f("System.Collections.Generic.Dictionary`2[[System.Int32, System.Private.CoreLib, Version=1.0.0.0, "
              "Culture=neutral, PublicKeyToken=null],[t.E, application, Version=0.0.0.0, Culture=neutral, "
              "PublicKeyToken=null]]"),
            {"System.Collections.Generic.Dictionary`2<System.Int32,t.E>", "System.Int32", "t.E"})
        self.assertEqual(
            f("System.Collections.Generic.Dictionary`2<System.UInt32,System.Collections.Generic.List`1<t.F>>"),
            {"System.Collections.Generic.Dictionary`2<System.UInt32,System.Collections.Generic.List`1<t.F>>",
             "System.UInt32", "System.Collections.Generic.List`1<t.F>", "t.F"})

    def test_walk_reaches_subclasses_and_arguments(self):
        dump = self.minimal(self.extras(self.walk_items()))
        q = bl.quest_types(dump)
        for n in ("t.Base", "t.Sub", "t.Leaf", "t.Arg", "app.QuestProcessor"):
            self.assertIn(n, q)
        self.assertNotIn("t.Unrelated", q)
        self.assertNotIn("System.Collections.Generic.List`1<t.Arg>", q)

    def test_behavior_prefix(self):
        items = self.walk_items() + [
            ("app.QuestController", dict(parent="via.Behavior", fields=[("_c", "U32", "System.UInt32", False)]))]
        dump = self.minimal(self.extras(items))
        sel = bl.select_types(dump)
        self.assertEqual(sel[dump["app.QuestController"]["fqn"]]["fields"],
                         [bl.BEHAVIOR_FLAG, ["_c", "U32", 4, 4, False]])
        self.assertNotIn(bl.BEHAVIOR_FLAG, sel[dump["t.Leaf"]["fqn"]]["fields"])
        loop = self.minimal(self.extras([("t.P", dict(parent="t.Q")), ("t.Q", dict(parent="t.P"))]))
        self.assertFalse(bl.is_behavior(loop, "t.P"))

    def test_native_layouts(self):
        items = [("app.QuestProcessor", dict(fields=[("_n", "Object", "t.NoRsz", False)])),
                 ("t.NoRsz", dict())]
        dump = self.minimal(self.extras(items))
        sel = bl.select_types(dump)
        for n, layout in bl.NATIVE_LAYOUTS.items():
            self.assertEqual(sel[dump[n]["fqn"]]["fields"], layout)
        self.assertNotIn(dump["t.NoRsz"]["fqn"], sel)

    def test_wanted_entry_shape(self):
        dump = self.minimal({})
        sel = bl.select_types(dump)
        self.assertEqual(sel[dump["app.GimmickData"]["fqn"]],
                         {"name": "app.GimmickData", "fields": [["f", "U32", 4, 4, False]]})

    def test_missing_root_exits(self):
        dump = self.minimal({}, drop=("app.QuestLogResource",))
        with self.assertRaises(SystemExit) as cm:
            bl.select_types(dump)
        self.assertIn("app.QuestLogResource", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
