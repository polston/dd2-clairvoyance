"""Decoder for the game's user-data and scene files (a USR or SCN container around an RSZ block).

Standard library only. Field layouts come from tools/layouts.json (see build_layouts.py).

File layout:
  USR header: magic b"USR\0", resource count, user-data count, info count (i32 x3),
              resource table, user-data table, data offset (u64 x3)
  SCN header: 64 bytes, magic b"SCN\0", counts for info, resource, folder, prefab and
              user-data (i32 x5), offsets of the folder, resource, prefab and user-data tables
              and of the data (u64 x5); the data offset (byte 56) is the RSZ block, which runs
              to the last byte of the file
  RSZ block at the data offset (every RSZ offset is relative to it):
              magic b"RSZ\0", version u32, object count, instance count, user-data count,
              reserved (i32 x4 in all), instance offset, data offset, user-data offset (u64 x3),
              then the object table (i32 per object)
  instance infos: (type hash u32, crc u32) per instance; instance 0 is the null instance
  user-data infos: (instance id i32, type hash u32, path offset u64); the path is UTF-16
  data: instances 1..N-1 in order (instances that are user-data references carry no data).
        Each field is aligned to its own alignment, measured from the start of the file.
        Arrays: u32 count (aligned to 4) then the elements. Object and UserData fields are an
        i32 instance index. String and Resource fields are a u32 char count then UTF-16.
"""
import struct


class DecodeError(Exception):
    """The file does not match the layouts, or was not consumed to its last byte."""


class Ref:
    __slots__ = ("idx",)

    def __init__(self, idx):
        self.idx = idx

    def __repr__(self):
        return "Ref(%d)" % self.idx


class Inst:
    """One instance: its 1-based id, type name, decoded fields and (for references) a path."""
    __slots__ = ("idx", "type", "fields", "path")

    def __init__(self, idx, type_, path=None):
        self.idx, self.type, self.fields, self.path = idx, type_, {}, path

    def __repr__(self):
        return "<%s #%d>" % (self.type, self.idx)


_SCALAR = {
    "Bool": "<?", "S8": "<b", "U8": "<B", "S16": "<h", "U16": "<H", "S32": "<i", "U32": "<I",
    "S64": "<q", "U64": "<Q", "F32": "<f", "F64": "<d", "C16": "<H",
}
_STRINGY = ("String", "Resource", "RuntimeType")
_FLOATS = ("Vec3", "Vec4", "Quaternion", "Float2", "Float3", "Float4", "Vec2", "Range", "Color", "Mat4")


def guid_str(b):
    """Lower-case .NET Guid.ToString() form (the first three groups are little-endian)."""
    a, b2, c = struct.unpack_from("<IHH", b, 0)
    return "%08x-%04x-%04x-%s-%s" % (a, b2, c, b[8:10].hex(), b[10:16].hex())


def _wstr(buf, off):
    end = off
    while buf[end:end + 2] != b"\0\0":
        if end >= len(buf):
            raise DecodeError("unterminated string")
        end += 2
    return buf[off:end].decode("utf-16-le", "replace")


class _Reader:
    def __init__(self, buf):
        self.buf = buf

    def align(self, pos, a):
        if a > 1 and pos % a:
            pos += a - pos % a
        return pos

    def value(self, pos, code, align, size):
        buf = self.buf
        if code in _STRINGY:
            pos = self.align(pos, 4)
            (n,) = struct.unpack_from("<I", buf, pos)
            pos += 4
            if pos + 2 * n > len(buf):
                raise DecodeError("string runs past the end")
            return buf[pos:pos + 2 * n].decode("utf-16-le", "replace").rstrip("\0"), pos + 2 * n
        if code in ("Object", "UserData"):
            pos = self.align(pos, 4)
            return Ref(struct.unpack_from("<i", buf, pos)[0]), pos + 4
        pos = self.align(pos, align)
        if code in _SCALAR:
            return struct.unpack_from(_SCALAR[code], buf, pos)[0], pos + size
        if code == "Guid":
            return guid_str(buf[pos:pos + 16]), pos + 16
        if code == "Position":
            return struct.unpack_from("<3d", buf, pos), pos + 24
        if code in ("Int2", "RangeI"):
            return struct.unpack_from("<2i", buf, pos), pos + size
        if code == "Uint2":
            return struct.unpack_from("<2I", buf, pos), pos + size
        if code in _FLOATS:
            return struct.unpack_from("<%df" % (size // 4), buf, pos), pos + size
        if pos + size > len(buf):
            raise DecodeError("value runs past the end")
        return buf[pos:pos + size], pos + size


def decode(data, layouts):
    """Decode a user-data or scene file to a list of instances (instance ids 1.. in order).

    A Ref's idx is the 1-based instance id; use deref(). Raises DecodeError when a type has no
    layout, the data is truncated, or the file is not consumed to its last byte.
    """
    try:
        return _decode(data, layouts["types"])
    except (struct.error, IndexError, ValueError) as e:
        raise DecodeError("malformed data: %s" % e)


def deref(insts, ref):
    """The instance a Ref points to, or None for the null reference."""
    if isinstance(ref, Ref):
        return insts[ref.idx - 1] if ref.idx > 0 else None
    return ref


def _decode(buf, types):
    if buf[:4] == b"USR\0":
        base = struct.unpack_from("<iiiQQQ", buf, 4)[-1]
    elif buf[:4] == b"SCN\0":
        base = struct.unpack_from("<5i5Q", buf, 4)[-1]
    else:
        raise DecodeError("not a user-data or scene file")
    if buf[base:base + 4] != b"RSZ\0":
        raise DecodeError("no RSZ block")
    (_ver, obj_count, inst_count, ud_n, _r, inst_off, data_off, ud_off) = struct.unpack_from(
        "<IiiiiQQQ", buf, base + 4)
    ud_paths = {}
    for i in range(ud_n):
        iid, _h, po = struct.unpack_from("<iIQ", buf, base + ud_off + 16 * i)
        ud_paths[iid] = _wstr(buf, base + po)
    insts, typed = [], []
    for i in range(1, inst_count):
        (h,) = struct.unpack_from("<I", buf, base + inst_off + 8 * i)
        t = types.get("%x" % h)
        inst = Inst(i, t["name"] if t else "?%08x" % h, ud_paths.get(i))
        insts.append(inst)
        typed.append((inst, t, h))
    rd = _Reader(buf)
    pos = base + data_off
    for inst, t, h in typed:
        if inst.idx in ud_paths:
            continue
        if t is None:
            raise DecodeError("no layout for type %08x" % h)
        for fname, code, align, size, is_arr in t["fields"]:
            if is_arr:
                pos = rd.align(pos, 4)
                (n,) = struct.unpack_from("<I", buf, pos)
                pos += 4
                vals = []
                for _ in range(n):
                    v, pos = rd.value(pos, code, align, size)
                    vals.append(v)
                inst.fields[fname] = vals
            else:
                inst.fields[fname], pos = rd.value(pos, code, align, size)
    if pos != len(buf):
        raise DecodeError("%d bytes left after the last instance" % (len(buf) - pos))
    return insts
