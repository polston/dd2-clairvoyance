"""Read-only reader for the game's KPKA 4.2 archive (feature 0x68 only).

Layout:
  header, 16 bytes: b"KPKA", u8 major, u8 minor, u16 feature, u32 entry count, u32 fingerprint
  entry table: count * 48 bytes, encrypted (feature bit 0x08)
  remap table (bit 0x40): u64 count, then count * 16 bytes
  wrapped key (bit 0x08): 128 bytes
  chunk table (bit 0x20): u32 block size, u32 count, count * (u32 start low word, u32 meta)
Entry, 48 bytes (<IIQQQQQ): hash low, hash high, offset, compressed size, size, attr, checksum.
"""
import struct
import zlib

SUPPORTED_FEATURE = 0x68
RSA_EXPONENT = 65537


class PakError(Exception):
    """The archive uses something this reader does not support."""


def murmur3_32(data, seed=0xFFFFFFFF):
    c1, c2 = 0xCC9E2D51, 0x1B873593
    h = seed
    n = len(data) & ~3
    for i in range(0, n, 4):
        k = int.from_bytes(data[i:i + 4], "little")
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
        h = ((h << 13) | (h >> 19)) & 0xFFFFFFFF
        h = (h * 5 + 0xE6546B64) & 0xFFFFFFFF
    tail = data[n:]
    k = 0
    if len(tail) >= 3:
        k ^= tail[2] << 16
    if len(tail) >= 2:
        k ^= tail[1] << 8
    if len(tail) >= 1:
        k ^= tail[0]
        k = (k * c1) & 0xFFFFFFFF
        k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF
        k = (k * c2) & 0xFFFFFFFF
        h ^= k
    h ^= len(data)
    h ^= h >> 16
    h = (h * 0x85EBCA6B) & 0xFFFFFFFF
    h ^= h >> 13
    h = (h * 0xC2B2AE35) & 0xFFFFFFFF
    h ^= h >> 16
    return h


def path_hash(path_str):
    """64-bit entry key: upper-case hash in the high word, lower-case in the low word."""
    lo = murmur3_32(path_str.lower().encode("utf-16-le"))
    hi = murmur3_32(path_str.upper().encode("utf-16-le"))
    return (hi << 32) | lo


def _read_header(f):
    raw = f.read(16)
    if len(raw) < 16:
        raise PakError("pak header is shorter than 16 bytes")
    return struct.unpack("<4sBBHII", raw)


def patch_entry_count(path):
    """Entry count of a patch archive; reads only its 16-byte header."""
    with open(path, "rb") as f:
        magic, major, _minor, _feature, total, _fp = _read_header(f)
    if magic != b"KPKA" or major != 4:
        raise PakError("not a KPKA major 4 archive: %s" % path)
    return total


def _decrypt(data, key):
    period = 7424  # lcm(32, 29, 256): the keystream repeats after this many bytes
    ks = bytes(((i + key[i % 32] * key[i % 29]) & 0xFF) for i in range(period))
    stream = (ks * (len(data) // period + 1))[:len(data)]
    n = len(data)
    return (int.from_bytes(data, "little") ^ int.from_bytes(stream, "little")).to_bytes(n, "little")


def _zstd():
    try:
        import zstandard
    except ImportError:
        raise PakError("the zstandard package is required")
    return zstandard.ZstdDecompressor()


class Pak:
    def __init__(self, path, key_hex=None):
        self.path = path
        with open(path, "rb") as f:
            magic, major, minor, feature, total, fp = _read_header(f)
            if magic != b"KPKA":
                raise PakError("not a KPKA archive")
            extra = feature & ~SUPPORTED_FEATURE
            if extra:
                bits = ", ".join("0x%x" % (1 << b) for b in range(16) if extra >> b & 1)
                raise PakError("unsupported pak feature bit %s (feature 0x%x)" % (bits, feature))
            if (major, minor) != (4, 2) or feature != SUPPORTED_FEATURE:
                raise PakError("unsupported pak header: version %d.%d feature 0x%x" % (major, minor, feature))
            if not key_hex:
                raise PakError("pak key missing")
            self.total, self.fingerprint = total, fp
            table = f.read(total * 48)
            (remap_count,) = struct.unpack("<Q", f.read(8))
            f.read(remap_count * 16)
            wrapped = f.read(128)
            modulus = int.from_bytes(bytes.fromhex(key_hex), "little")
            key = pow(int.from_bytes(wrapped, "little"), RSA_EXPONENT, modulus).to_bytes(129, "little")
            table = _decrypt(table, key)
            self.block_size, count = struct.unpack("<II", f.read(8))
            raw = f.read(count * 8)
        self.chunks = []
        high, prev = 0, None
        for i in range(count):
            lo, meta = struct.unpack_from("<II", raw, i * 8)
            if prev is not None and lo < prev:
                high += 1 << 32
            self.chunks.append((high | lo, meta))
            prev = lo
        self.entries = {}
        for i in range(total):
            e = struct.unpack_from("<IIQQQQQ", table, i * 48)
            self.entries[(e[1] << 32) | e[0]] = e
        self._f = open(path, "rb")

    def close(self):
        self._f.close()

    def read(self, path_str):
        """Decompressed bytes of one entry, or None when the path is not in the archive."""
        e = self.entries.get(path_hash(path_str))
        return None if e is None else self._read_entry(e)

    def _read_entry(self, e):
        _hl, _hu, off, csize, usize, attr, _ck = e
        if (attr >> 16) & 0xFF:
            raise PakError("resource encryption %d is not supported" % ((attr >> 16) & 0xFF))
        f = self._f
        if attr & (1 << 24):  # chunked: offset is the first chunk index
            total = usize
            out = bytearray()
            ci = off
            dz = None
            while len(out) < total:
                start, meta = self.chunks[ci]
                clen = meta >> 10
                f.seek(start)
                b = f.read(clen)
                if clen == self.block_size:
                    out += b
                else:
                    dz = dz or _zstd()
                    out += dz.decompress(b, max_output_size=self.block_size)
                ci += 1
            return bytes(out[:total])
        f.seek(off)
        data = f.read(csize)
        comp = attr & 0xF
        if comp == 0:
            return data
        if comp == 1:
            return zlib.decompress(data, -15)
        if comp == 2:
            return _zstd().decompress(data, max_output_size=usize)
        raise PakError("compression %d is not supported" % comp)
