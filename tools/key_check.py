"""Report whether the pak key file exists; optionally create it from a local source.

Prints only "key: present" or "key: missing". The key value is never printed.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KEY_NAME = "pak_key.local.txt"


def common_dir():
    """The repository's common git directory (the main checkout's .git), or None."""
    try:
        out = subprocess.run(
            ["git", "-C", HERE, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0 or not out.stdout.strip():
        return None
    return os.path.normpath(out.stdout.strip())


def key_path():
    """tools/pak_key.local.txt in the main checkout, else beside this script."""
    cd = common_dir()
    if cd:
        return os.path.join(os.path.dirname(cd), "tools", KEY_NAME)
    return os.path.join(HERE, KEY_NAME)


def read_key(path=None):
    """The key hex string, or None when the file is missing or empty."""
    path = path or key_path()
    try:
        with open(path, encoding="ascii") as f:
            text = f.read().strip()
    except OSError:
        return None
    return text or None


def _extract(source):
    with open(source, encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"bytes\.fromhex\(\s*((?:[\"'][0-9a-fA-F]*[\"']\s*)+)\)", text)
    if not m:
        return None
    return "".join(re.findall(r"[0-9a-fA-F]+", m.group(1)))


def _exclude(path_rel):
    cd = common_dir()
    if not cd:
        return
    info = os.path.join(cd, "info")
    os.makedirs(info, exist_ok=True)
    ex = os.path.join(info, "exclude")
    try:
        with open(ex, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    if path_rel not in [x.strip() for x in lines]:
        with open(ex, "a", encoding="utf-8", newline="\n") as f:
            if lines and lines[-1] != "":
                f.write("\n")
            f.write(path_rel + "\n")


def write_from(source):
    key = _extract(source)
    if not key or len(key) < 64:
        return False
    dest = key_path()
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w", encoding="ascii", newline="") as f:
        f.write(key)
    _exclude("tools/" + KEY_NAME)
    return True


def main(argv):
    if argv == ["--path"]:
        print(key_path())
        return 0
    if len(argv) == 2 and argv[0] == "--write-from":
        write_from(argv[1])
    elif argv:
        print("usage: key_check.py [--path | --write-from <file>]")
        return 2
    print("key: present" if read_key() else "key: missing")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
