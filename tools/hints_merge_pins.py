"""Appends pins from a JSON array of {qid, idx, label, x, y, z} to the hints file.

Entries are created when absent; exact duplicate pins are skipped.
"""
import argparse
import json
import sys


def merge(hints, pins):
    """Merges pins into hints in place; returns the number added."""
    added = 0
    for p in pins:
        entry = hints.setdefault(str(p["qid"]), {})
        steps = entry.setdefault("steps", {})
        step = steps.setdefault(str(int(p["idx"])), {})
        lst = step.setdefault("pins", [])
        pin = {"x": p["x"], "y": p["y"], "z": p["z"], "label": p["label"]}
        if pin not in lst:
            lst.append(pin)
            added += 1
    return added


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--pins", required=True)
    ap.add_argument("--hints", default="data/Clairvoyance_hints.json")
    args = ap.parse_args(argv)
    with open(args.pins, encoding="utf-8") as f:
        pins = json.load(f)
    with open(args.hints, encoding="utf-8") as f:
        hints = json.load(f)
    added = merge(hints, pins)
    with open(args.hints, "w", encoding="utf-8", newline="\n") as f:
        json.dump(hints, f, indent=1, ensure_ascii=False, sort_keys=True)
        f.write("\n")
    print("hints_merge_pins: added %d pin(s)" % added)
    return 0


if __name__ == "__main__":
    sys.exit(main())
