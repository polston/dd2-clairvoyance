"""Offline extractor: reads the installed game's archive and writes the map icon pictures.

Usage: python tools/extract_icons.py --game <game folder> [--key <file>]

Writes reframework/images/Clairvoyance/icons/<id>.png (64x64, whitened so the host can tint
them) and index.json. Prints counts only. Exit 0 on success; exit 1 with one reason line on
failure. Needs Pillow and texture2ddecoder (imported only when decoding).
"""
import argparse
import json
import math
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import extract_world  # noqa: E402
import key_check  # noqa: E402
import qnml_pak  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(os.path.dirname(HERE), "reframework", "images", "Clairvoyance", "icons")
KEY_MSG = extract_world.KEY_MSG
MAP_DIR = "natives/stm/gui/ui01/common/map/"
SHEETS = (("minimap", "uvs_map_03.uvs.8"), ("fullmap", "uvs_map_01.uvs.8"))
TEX_SUFFIX = ".251211553"
BC7_FORMATS = (97, 98, 99)
ICON_IDS = range(0, 81)
SEQUENCE = 1
BOX = 64
ALPHA_CUT = 128
_PNG_NAME = re.compile(r"^(\d+)\.png$")


class IconError(Exception):
    """A step failed; the message is the one reason line."""


def parse_uvs(data):
    """{texs: [path], seqs: [(count, first_pattern)], pats: [dict]} from a UVS sheet."""
    if data[:4] != b".SVU":
        raise ValueError("not a UVS sheet")
    tc, sc, pc = struct.unpack_from("<III", data, 4)
    o_tex, o_seq, o_pat, o_str = struct.unpack_from("<QQQQ", data, 24)
    texs = []
    for i in range(tc):
        (so,) = struct.unpack_from("<Q", data, o_tex + 40 * i + 8)
        p = o_str + 2 * so
        e = p
        while data[e:e + 2] != b"\x00\x00":
            e += 2
        texs.append(data[p:e].decode("utf-16-le"))
    seqs = [struct.unpack_from("<II", data, o_seq + 8 * i) for i in range(sc)]
    pats = []
    for i in range(pc):
        fl, l, t, r, b, ti, co = struct.unpack_from("<Qffffii", data, o_pat + 32 * i)
        pats.append({"flags": fl, "left": l, "top": t, "right": r, "bottom": b,
                     "tex": ti, "cutouts": co})
    return {"texs": texs, "seqs": seqs, "pats": pats}


def parse_tex_header(data):
    """{w, h, fmt, off, size} of mip 0; ValueError for a format that is not BC7."""
    if data[:4] != b"TEX\x00":
        raise ValueError("not a TEX file")
    w, h = struct.unpack_from("<HH", data, 8)
    (fmt,) = struct.unpack_from("<I", data, 16)
    if fmt not in BC7_FORMATS:
        raise ValueError("unsupported texture format %d" % fmt)
    off, _pitch, size = struct.unpack_from("<QII", data, 40)
    return {"w": w, "h": h, "fmt": fmt, "off": off, "size": size}


def bgra_to_rgba(data):
    """[(r, g, b, a)] from decoded BC7 bytes, which are B, G, R, A per pixel."""
    return [(data[i + 2], data[i + 1], data[i], data[i + 3]) for i in range(0, len(data) - 3, 4)]


def cut_flags(alphas):
    """True when any alpha is above 128."""
    return any(a > ALPHA_CUT for a in alphas)


def pick_source(has_minimap, has_fullmap):
    """The sheet to take the picture from: the minimap first, else the full map, else None."""
    if has_minimap:
        return "minimap"
    if has_fullmap:
        return "fullmap"
    return None


def _rank(sorted_vals, p):
    """Nearest-rank percentile: the 1-based index ceil(p * n) of the sorted values."""
    i = max(1, math.ceil(p * len(sorted_vals) - 1e-9))
    return sorted_vals[i - 1]


def whiten(pixels):
    """[(g, g, g, a)]: shading kept, brightness lifted to 0.45..1 so a tint still reads."""
    lum = [0.299 * r + 0.587 * g + 0.114 * b for r, g, b, a in pixels]
    opaque = sorted(l for l, px in zip(lum, pixels) if px[3] > ALPHA_CUT)
    lo = _rank(opaque, 0.05) if opaque else 0.0
    hi = _rank(opaque, 0.95) if opaque else 0.0
    out = []
    for l, px in zip(lum, pixels):
        if hi == lo:
            v = 255
        else:
            t = min(1.0, max(0.0, (l - lo) / (hi - lo)))
            v = int(math.floor(255 * (0.45 + 0.55 * t) + 0.5))
        out.append((v, v, v, px[3]))
    return out


def fit_rect(w, h, box=BOX):
    """(x, y, w, h) of the cut scaled to fit a box x box canvas, centered, half rounded up."""
    if w <= 0 or h <= 0:
        return (0, 0, 0, 0)
    if w >= h:
        nw, nh = box, max(1, (2 * h * box + w) // (2 * w))
    else:
        nw, nh = max(1, (2 * w * box + h) // (2 * h)), box
    return ((box - nw + 1) // 2, (box - nh + 1) // 2, nw, nh)


def index_lines(entries):
    """The index.json text: one id per line in id order."""
    ids = sorted(entries)
    lines = []
    for n, i in enumerate(ids):
        e = entries[i]
        body = json.dumps({"src": e["src"], "minimap": e["minimap"], "fullmap": e["fullmap"]})
        lines.append(("{" if n == 0 else "") + '"%d": %s' % (i, body)
                     + ("}" if n == len(ids) - 1 else ","))
    return "\n".join(lines) + "\n"


def write_index(entries, out_dir, writer, lister, remover):
    """Write index.json and remove picture files for ids that no longer produce one."""
    writer(os.path.join(out_dir, "index.json"), index_lines(entries))
    keep = {"%d.png" % i for i, e in entries.items() if e["src"]}
    for name in lister(out_dir):
        if _PNG_NAME.match(name) and name not in keep:
            remover(os.path.join(out_dir, name))


def _decode_texture(tex_bytes):
    """(w, h, BGRA bytes) of mip 0."""
    import texture2ddecoder
    hd = parse_tex_header(tex_bytes)
    block = tex_bytes[hd["off"]:hd["off"] + hd["size"]]
    return hd["w"], hd["h"], bytes(texture2ddecoder.decode_bc7(block, hd["w"], hd["h"]))


def _cut(pat, w, h, bgra):
    """(cut width, cut height, [(r, g, b, a)]) of a pattern's pixel rectangle."""
    def px(v, n):
        return min(n, max(0, int(math.floor(v * n + 0.5))))
    x0, x1 = px(pat["left"], w), px(pat["right"], w)
    y0, y1 = px(pat["top"], h), px(pat["bottom"], h)
    if x1 <= x0 or y1 <= y0:
        return 0, 0, []
    rows = [bgra[(y * w + x0) * 4:(y * w + x1) * 4] for y in range(y0, y1)]
    return x1 - x0, y1 - y0, bgra_to_rgba(b"".join(rows))


def _render(cw, ch, pixels):
    """A 64x64 RGBA PIL image holding the whitened cut, fitted and centered."""
    from PIL import Image
    img = Image.new("RGBA", (cw, ch))
    img.putdata(whiten(pixels))
    x, y, nw, nh = fit_rect(cw, ch)
    canvas = Image.new("RGBA", (BOX, BOX), (0, 0, 0, 0))
    canvas.paste(img.resize((nw, nh), Image.LANCZOS), (x, y))
    return canvas


def _sheet_cuts(pak, sheet_name):
    """{id: (cut w, cut h, pixels)} for ids 0-80 of one sheet."""
    raw = pak.read(MAP_DIR + sheet_name)
    if raw is None:
        raise IconError("%s not found in the archive" % sheet_name)
    sheet = parse_uvs(raw)
    count, first = sheet["seqs"][SEQUENCE]
    if count < len(ICON_IDS):
        raise IconError("game update changed the icon sheet layout")
    textures = {}
    cuts = {}
    for i in ICON_IDS:
        pat = sheet["pats"][first + i]
        ti = pat["tex"]
        if ti not in textures:
            name = sheet["texs"][ti].replace("\\", "/").rsplit("/", 1)[-1].lower()
            tb = pak.read(MAP_DIR + name + TEX_SUFFIX)
            if tb is None:
                raise IconError("texture %s not found in the archive" % name)
            textures[ti] = _decode_texture(tb)
        w, h, bgra = textures[ti]
        cuts[i] = _cut(pat, w, h, bgra)
    return cuts


def extract(game, key_hex, out_dir):
    """Write the pictures and index; returns the entries."""
    base, patches = extract_world.pak_files(game)
    if not os.path.exists(base):
        raise IconError("%s not found in the game folder" % extract_world.PAK_NAME)
    why = extract_world.check_patches(patches)
    if why:
        raise IconError(why)
    try:
        pak = qnml_pak.Pak(base, key_hex)
    except (qnml_pak.PakError, OSError, struct.error) as e:
        raise IconError("cannot read archive: %s" % (e if isinstance(e, qnml_pak.PakError) else type(e).__name__))
    try:
        cuts = {name: _sheet_cuts(pak, f) for name, f in SHEETS}
    except (qnml_pak.PakError, ValueError, IndexError, struct.error) as e:
        raise IconError("extraction failed: %s" % e)
    finally:
        pak.close()
    os.makedirs(out_dir, exist_ok=True)
    entries = {}
    for i in ICON_IDS:
        flags = {}
        for name, _f in SHEETS:
            cw, ch, px = cuts[name][i]
            flags[name] = cut_flags([p[3] for p in px])
        src = pick_source(flags["minimap"], flags["fullmap"])
        entries[i] = {"src": src, "minimap": flags["minimap"], "fullmap": flags["fullmap"]}
        if src:
            cw, ch, px = cuts[src][i]
            _render(cw, ch, px).save(os.path.join(out_dir, "%d.png" % i), optimize=True)
    return entries


def _write_text(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--game", required=True)
    ap.add_argument("--key")
    ap.add_argument("--out", default=OUT_DIR, help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    try:
        key_hex = key_check.read_key(a.key)
        if not key_hex:
            raise IconError(KEY_MSG)
        entries = extract(a.game, key_hex, a.out)
        write_index(entries, a.out, _write_text, os.listdir, os.remove)
        n = sum(1 for e in entries.values() if e["src"])
        print("pictures written: %d" % n)
        return 0
    except IconError as e:
        print(str(e))
        return 1
    except ImportError as e:
        print("missing module: %s (needs Pillow and texture2ddecoder)" % e.name or type(e).__name__)
        return 1
    except (KeyError, IndexError, ValueError, OSError, struct.error) as e:
        print("extraction failed: %s" % type(e).__name__)
        return 1


if __name__ == "__main__":
    sys.exit(main())
