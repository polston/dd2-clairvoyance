"""Runs a Lua probe chunk in the game through tools/probe/qnml_check.lua.
Usage: python tools/probe/run.py <chunk.lua> [timeout_s] --game <game folder>
Writes the chunk to reframework/data/qnml_cmd.txt, waits for the harness's
"CHK cmd ok=" line in re2_framework_log.txt, then prints the CHK lines the
chunk logged and any framework [error] line that mentions the mod. On TIMEOUT
(default 30 s) it prints TIMEOUT, blanks the queued chunk file so the harness
cannot run it later, and exits 1.
"""
import argparse
import os
import sys
import time

# The harness prefixes its own periodic dump lines with this; a chunk's lines
# never start with it.
NOISE = "~ "


def is_mod_error(line):
    """A framework or mod error line that mentions the mod or its files."""
    low = line.lower()
    if "[error]" in low and ("clairvoyance" in low or "qnml" in low):
        return True
    return "[clairvoyance]" in low and "error" in low


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("chunk")
    ap.add_argument("timeout", nargs="?", type=float, default=30.0)
    ap.add_argument("--game", required=True)
    a = ap.parse_args()
    log = os.path.join(a.game, "re2_framework_log.txt")
    cmd = os.path.join(a.game, "reframework", "data", "qnml_cmd.txt")
    with open(a.chunk, encoding="utf-8") as f:
        src = f.read()
    start = os.path.getsize(log)
    with open(cmd, "w", encoding="utf-8") as f:
        f.write(src)
    deadline = time.time() + a.timeout
    text, done = "", False
    while time.time() < deadline:
        time.sleep(0.5)
        with open(log, "rb") as f:
            f.seek(start)
            text = f.read().decode("utf-8", "replace")
        if "CHK cmd ok=" in text:
            done = True
            break
    if not done:
        print("TIMEOUT")
        with open(cmd, "w", encoding="utf-8") as f:
            f.write("")
    for line in text.splitlines():
        if "CHK " in line:
            s = line.split("CHK ", 1)[1]
            if not s.startswith(NOISE):
                print(s)
        elif is_mod_error(line):
            print("LOG", line[-200:])
    return 0 if done else 1


if __name__ == "__main__":
    sys.exit(main())
