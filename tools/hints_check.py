"""Compares hint text against fetched reference pages (the .txt files only).

Exits 1 when any hint shares a run of 8 consecutive words with a reference
text, printing the qid and the shared run. Exits 1 when hint text exists and
--ref is absent; exits 0 with no reference pages only for a file with no text.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from key_check import common_dir  # noqa: E402

RUN = 8


def normalize(text):
    """Lower case, punctuation removed, whitespace collapsed, as a word list."""
    return re.sub(r"[^\w\s]|_", " ", text.lower()).split()


def shared_runs(a, b, n=RUN):
    """Every distinct run of n consecutive words found in both word lists."""
    if len(a) < n or len(b) < n:
        return []
    grams = {tuple(b[i:i + n]) for i in range(len(b) - n + 1)}
    out = []
    seen = set()
    for i in range(len(a) - n + 1):
        g = tuple(a[i:i + n])
        if g in grams and g not in seen:
            seen.add(g)
            out.append(" ".join(g))
    return out


def main_path(*parts):
    """A path under the main checkout (reference/ and the sources file live only
    there), else relative to the current directory."""
    cd = common_dir()
    if cd:
        return os.path.join(os.path.dirname(cd), *parts)
    return os.path.join(*parts)


def hint_texts(entry):
    """The quest text and every step text of one hints entry."""
    out = []
    if isinstance(entry, dict):
        if isinstance(entry.get("quest"), str):
            out.append(entry["quest"])
        steps = entry.get("steps")
        if isinstance(steps, dict):
            for step in steps.values():
                if isinstance(step, dict) and isinstance(step.get("text"), str):
                    out.append(step["text"])
    return out


def check(hints, ref_dir):
    """Returns (qid, run) pairs for every shared run."""
    found = []
    for qid, entry in hints.items():
        if not re.fullmatch(r"[0-9]+", str(qid)):
            continue
        qdir = os.path.join(ref_dir, str(qid))
        if not os.path.isdir(qdir):
            continue
        refs = []
        for name in sorted(os.listdir(qdir)):
            if name.endswith(".txt"):
                with open(os.path.join(qdir, name), encoding="utf-8", errors="replace") as f:
                    refs.append(normalize(f.read()))
        for text in hint_texts(entry):
            words = normalize(text)
            for ref in refs:
                for run in shared_runs(words, ref):
                    if (qid, run) not in found:
                        found.append((qid, run))
    return found


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--hints", default="data/Clairvoyance_hints.json")
    ap.add_argument("--ref", default=None,
                    help="default: reference/hints in the main checkout")
    args = ap.parse_args(argv)
    if args.ref is None:
        args.ref = main_path("reference", "hints")
    with open(args.hints, encoding="utf-8") as f:
        hints = json.load(f)
    if not os.path.isdir(args.ref):
        if any(hint_texts(e) for e in hints.values()):
            print("hints_check: FAILED: hint text exists but there are no reference pages")
            return 1
        print("hints_check: skipped: no hint text")
        return 0
    found = check(hints, args.ref)
    for qid, run in found:
        print("hints_check: qid %s shares %d words: %s" % (qid, RUN, run))
    if found:
        return 1
    print("hints_check: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
