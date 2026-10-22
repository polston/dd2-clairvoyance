#!/usr/bin/env python3
"""Semantic version from Conventional Commits.

Modes:
  next    print the next version (no "v") for commits since the latest v<x.y.z>
          tag reachable from HEAD, or nothing when no release is due
  notes   print Markdown release notes for the same range
  check   validate commit subjects (stdin, one per line, or --range A..B)
"""
import argparse
import re
import subprocess
import sys
from typing import List, NamedTuple, Optional, Tuple

TYPES = ("feat", "fix", "perf", "refactor", "docs", "test", "build", "ci", "chore", "style", "revert")
SUBJECT_RE = re.compile(r"^(?P<type>%s)(?:\((?P<scope>[^()\s]+)\))?(?P<bang>!)?: (?P<desc>\S.*)$" % "|".join(TYPES))
FOOTER_RE = re.compile(r"^BREAKING[ -]CHANGE: ", re.MULTILINE)
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")

Commit = Tuple[str, str]  # (subject, body)


class Parsed(NamedTuple):
    type: str
    scope: Optional[str]
    breaking: bool
    description: str


def parse_subject(subject: str) -> Optional[Parsed]:
    m = SUBJECT_RE.match(subject)
    if not m:
        return None
    return Parsed(m.group("type"), m.group("scope"), bool(m.group("bang")), m.group("desc"))


def parse_tag(tag: str) -> Optional[Tuple[int, int, int]]:
    m = TAG_RE.match(tag)
    return tuple(int(x) for x in m.groups()) if m else None


def _is_breaking(subject: str, body: str) -> bool:
    p = parse_subject(subject)
    if p is None:
        return False
    return p.breaking or bool(FOOTER_RE.search(body))


def bump(version: str, commits: List[Commit]) -> Optional[str]:
    major, minor, patch = (int(x) for x in version.split("."))
    level = 0  # 0 none, 1 patch, 2 minor, 3 major
    for subject, body in commits:
        p = parse_subject(subject)
        if p is None:
            continue
        if _is_breaking(subject, body):
            level = max(level, 3)
        elif p.type == "feat":
            level = max(level, 2)
        elif p.type in ("fix", "perf"):
            level = max(level, 1)
    if level == 3:
        return "%d.0.0" % (major + 1)
    if level == 2:
        return "%d.%d.0" % (major, minor + 1)
    if level == 1:
        return "%d.%d.%d" % (major, minor, patch + 1)
    return None


def _line(p: Parsed) -> str:
    return "- **%s**: %s" % (p.scope, p.description) if p.scope else "- %s" % p.description


def notes(commits: List[Commit]) -> str:
    breaking, feats, fixes = [], [], []
    for subject, body in commits:
        p = parse_subject(subject)
        if p is None:
            continue
        if _is_breaking(subject, body):
            breaking.append(_line(p))
        elif p.type == "feat":
            feats.append(_line(p))
        elif p.type in ("fix", "perf"):
            fixes.append(_line(p))
    out = []
    for title, items in (("Breaking changes", breaking), ("Features", feats), ("Fixes", fixes)):
        if items:
            out.append("## %s\n\n%s\n" % (title, "\n".join(items)))
    return "\n".join(out)


def check(subjects: List[str]) -> List[str]:
    bad = []
    for s in subjects:
        s = s.rstrip("\r\n")
        if not s.strip():
            continue
        if s.startswith("Merge "):
            continue
        if parse_subject(s) is None:
            bad.append(s)
    return bad


def _git(*args: str) -> str:
    r = subprocess.run(["git", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       universal_newlines=True, encoding="utf-8")
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.exit(r.returncode)
    return r.stdout


def latest_tag() -> Optional[str]:
    best = None
    for t in _git("tag", "--merged", "HEAD").split():
        v = parse_tag(t)
        if v and (best is None or v > best[0]):
            best = (v, t)
    return best[1] if best else None


def commits_since(tag: str) -> List[Commit]:
    raw = _git("log", "%s..HEAD" % tag, "--format=%s%x1f%b%x1e")
    out = []
    for rec in raw.split("\x1e"):
        rec = rec.strip("\n")
        if not rec:
            continue
        subject, _, body = rec.partition("\x1f")
        out.append((subject.strip(), body))
    return out


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["next", "notes", "check"])
    ap.add_argument("--range", dest="rng", help="check: git revision range A..B")
    a = ap.parse_args(argv)
    if a.mode == "check":
        if a.rng:
            subjects = _git("log", a.rng, "--format=%s").splitlines()
        else:
            subjects = sys.stdin.read().splitlines()
        bad = check(subjects)
        for s in bad:
            print("not a Conventional Commit subject: %s" % s)
        return 1 if bad else 0
    tag = latest_tag()
    if tag is None:
        return 0
    commits = commits_since(tag)
    if a.mode == "next":
        v = bump(tag[1:], commits)
        if v:
            print(v)
    else:
        text = notes(commits)
        if text:
            print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
