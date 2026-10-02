#!/usr/bin/env python3
"""Generate a synthetic Spreadtrum PAC firmware image for tests/pac-tools.sh.

The image is deliberately real enough for the reference `unpac` binary to
accept it: correct magic, partitionsListStart == 2124, partitionCount < 1024,
length == 2580 per entry, UTF-16LE names and correct CRC-16/ARC head/data
checksums.  Payloads are placed at absolute offsets that are NOT
2124 + N*2580, by inserting a <BMAConfig>-style XML blob of a few hundred
bytes after the entry table and 4 KiB-aligning the payload area.

Usage:
    pac_fixture.py OUT.pac [--corrupt-crc]

Also writes OUT.pac.manifest with one line per payload that `extract` is
expected to write:
    <filename>\t<size>\t<sha256hex>
"""

import hashlib
import os
import struct
import sys

MAGIC = 0xFFFAFFFA
HEAD_SIZE = 2124
ENTRY_SIZE = 2580

# id, output filename, size, nFileFlag, addresses, zero_offset
ENTRIES = [
    ("FDL", "fdl1.bin", 4096, 0x101, [0x65000800, 0x9EFFFE00], False),
    ("MODEM", "modem.bin", 12345, 1, [0x1000], False),
    ("SYSTEM", "system.img", 8000, 1, [], False),
    ("NV", "nv.bin", 0, 1, [0x2000, 0x0, 0x40], False),
    ("XMLCFG", "xmlcfg.xml", 777, 2, [], False),
    ("BADPATH", "sub/dir.bin", 512, 1, [], False),
    ("EMPTYNAME", "", 256, 1, [], False),
    ("ZEROFF", "zeroff.bin", 128, 1, [], True),
    ("ONEADDR", "addr.bin", 64, 1, [0, 0x1234], False),
]

FILLER = (
    b'<?xml version="1.0" encoding="UTF-8" ?>\n'
    b"<BMAConfig>\n"
    b'  <PartitionList count="%d">\n' % len(ENTRIES)
    + b"".join(
        b'    <Partition id="%s" name="%s" size="0x%x"/>\n'
        % (e[0].encode(), e[1].encode(), e[2])
        for e in ENTRIES
    )
    + b"  </PartitionList>\n"
    b"  <Version>BP_R1.0.0</Version>\n"
    b"</BMAConfig>\n"
    + b"<!-- padding: keeps payload offsets non-uniform -->\n" * 7
)


def crc16_arc(data):
    """CRC-16/ARC: reflected poly 0x8005 (const 0xA001), init 0, no final xor."""
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc & 0xFFFF


def u16s(text, nchars):
    """UTF-16LE, NUL padded to nchars characters (2*nchars bytes)."""
    raw = text.encode("utf-16-le")
    return raw[: nchars * 2].ljust(nchars * 2, b"\x00")


def payload(tag, size):
    """Deterministic bytes, distinct per tag."""
    out = bytearray()
    tag = str(tag)
    ctr = 0
    while len(out) < size:
        out += hashlib.sha256(("%s:%d" % (tag, ctr)).encode()).digest()
        ctr += 1
    return bytes(out[:size])


def _align(v, n=0x1000):
    return (v + n - 1) & ~(n - 1)


def layout(entries=None):
    """Return (offsets, payload_start, total_size, data_bytes)."""
    entries = ENTRIES if entries is None else entries
    count = len(entries)
    payload_start = _align(HEAD_SIZE + count * ENTRY_SIZE + len(FILLER))
    offsets = []
    cur = payload_start
    for pid, name, size, _flag, _addrs, zero_off in entries:
        if size == 0:
            # No data, but keep an offset so `list` shows one.
            offsets.append(cur)
            continue
        if zero_off:
            offsets.append(0)
            continue
        offsets.append(cur)
        cur = _align(cur + size)
    total = cur
    data = bytearray(total)
    for idx, (pid, name, size, _flag, _addrs, _z) in enumerate(entries):
        if size == 0 or offsets[idx] == 0:
            continue
        off = offsets[idx]
        data[off:off + size] = payload(pid or name, size)
    return offsets, payload_start, total, data


def build(corrupt_crc=False, entries=None, count_override=None):
    entries = ENTRIES if entries is None else entries
    offsets, payload_start, total, data = layout(entries)
    count = len(entries) if count_override is None else count_override

    hdr = bytearray(HEAD_SIZE)
    hdr[0x000:0x02C] = u16s("BP_R1.0.0", 22)
    struct.pack_into("<I", hdr, 0x02C, 0)
    struct.pack_into("<I", hdr, 0x030, total & 0xFFFFFFFF)
    hdr[0x034:0x234] = u16s("ums9230", 256)
    hdr[0x234:0x434] = u16s("pac_fixture", 256)
    struct.pack_into("<I", hdr, 0x434, count)
    struct.pack_into("<I", hdr, 0x438, HEAD_SIZE)
    struct.pack_into("<I", hdr, 0x43C, 0)  # dwMode
    struct.pack_into("<I", hdr, 0x440, 0)  # dwFlashType
    struct.pack_into("<I", hdr, 0x444, 0)  # dwNandStrategy
    struct.pack_into("<I", hdr, 0x448, 0)  # dwIsNvBackup
    struct.pack_into("<I", hdr, 0x44C, 0)  # dwNandPageType
    hdr[0x450:0x518] = u16s("ums9230-fixture", 100)
    struct.pack_into("<I", hdr, 0x518, 0)
    struct.pack_into("<I", hdr, 0x51C, 0)
    struct.pack_into("<I", hdr, 0x520, 0)
    struct.pack_into("<I", hdr, 0x844, MAGIC)
    struct.pack_into("<H", hdr, 0x848, 0)
    struct.pack_into("<H", hdr, 0x84A, 0)

    table = bytearray()
    for idx, (pid, name, size, flag, addrs, _z) in enumerate(entries):
        ent = bytearray(ENTRY_SIZE)
        off = offsets[idx]
        struct.pack_into("<I", ent, 0x000, ENTRY_SIZE)
        ent[0x004:0x204] = u16s(pid, 256)
        ent[0x204:0x404] = u16s(name, 256)
        struct.pack_into("<I", ent, 0x5FC, (size >> 32) & 0xFFFFFFFF)
        struct.pack_into("<I", ent, 0x600, (off >> 32) & 0xFFFFFFFF)
        struct.pack_into("<I", ent, 0x604, size & 0xFFFFFFFF)
        struct.pack_into("<I", ent, 0x608, flag)
        struct.pack_into("<I", ent, 0x60C, 0)
        struct.pack_into("<I", ent, 0x610, off & 0xFFFFFFFF)
        struct.pack_into("<I", ent, 0x614, 0)
        struct.pack_into("<I", ent, 0x618, len(addrs))
        for a, v in enumerate(addrs):
            struct.pack_into("<I", ent, 0x61C + 4 * a, v)
        table += ent

    img = bytearray()
    img += hdr
    img += table
    img += FILLER
    img += b"\x00" * (payload_start - len(img))
    img += bytes(data[payload_start:])
    assert len(img) == total, (len(img), total)

    # wCRC1 over [0, 2120) -- includes dwMagic, excludes the two CRC halves.
    struct.pack_into("<H", img, 0x848, crc16_arc(bytes(img[:0x848])))
    # wCRC2 over [2124, dwLoSize).
    struct.pack_into("<H", img, 0x84A, crc16_arc(bytes(img[HEAD_SIZE:total])))
    if corrupt_crc:
        img[0x84A] ^= 0xFF  # leave the stated CRC wrong on purpose

    manifest = []
    for idx, (pid, name, size, _flag, _addrs, _z) in enumerate(entries):
        if not name or offsets[idx] == 0 or size == 0 or "/" in name or "\\" in name or ":" in name:
            continue
        manifest.append("%s\t%d\t%s" % (name, size, hashlib.sha256(payload(pid, size)).hexdigest()))
    return bytes(img), manifest


def _entries_by_name():
    return {e[1]: e for e in ENTRIES}


# Extra shapes needed to pin the edge cases: an unsafe name in each position,
# each rejected character, and the guard-triggering header fields.
def variants():
    E = _entries_by_name()
    fdl, unsafe, addr = E["fdl1.bin"], E["sub/dir.bin"], E["addr.bin"]
    out = {
        "safe3": [E["fdl1.bin"], E["modem.bin"], E["system.img"]],
        "unsafe_last": [fdl, unsafe],
        "unsafe_mid": [fdl, unsafe, addr],
        "unsafe_first": [unsafe, fdl],
        "colon": [fdl, ("C", "a:b.bin", 64, 1, [], False)],
        "backslash": [fdl, ("D", "a\\b.bin", 64, 1, [], False)],
        "dotdot": [fdl, ("E", "../x.bin", 64, 1, [], False)],
        "emptyname": [fdl, E[""]],
        "zeroff": [fdl, E["zeroff.bin"]],
        "onlyunsafe": [unsafe],
    }
    return out


def _fix_head_crc(buf):
    struct.pack_into("<H", buf, 0x848, crc16_arc(bytes(buf[:0x848])))
    return buf


def suite(outdir):
    """Write every fixture tests/pac-tools.sh compares against the vendor tool.

    Each name describes the property it pins; the corruptions are applied to a
    built image and the head CRC is repaired where the corruption is not the
    head CRC itself, so only the intended field is ever wrong.
    """
    os.makedirs(outdir, exist_ok=True)
    written = []

    def put(name, data, manifest=None):
        with open(os.path.join(outdir, name + ".pac"), "wb") as fh:
            fh.write(data)
        if manifest is not None:
            with open(os.path.join(outdir, name + ".pac.manifest"), "w") as fh:
                fh.write("\n".join(manifest) + "\n")
        written.append(name)

    base, manifest = build()
    put("main", base, manifest)
    put("bad", build(corrupt_crc=True)[0])

    b = bytearray(base)
    struct.pack_into("<H", b, 0x848, 0xABCD)
    put("badheadcrc", bytes(b))

    b = bytearray(base)
    struct.pack_into("<I", b, 0x30, 0xDEAD)
    put("wronglosize", bytes(_fix_head_crc(b)))

    b = bytearray(base)
    struct.pack_into("<I", b, 0x844, 0x12345678)
    put("nomagic", bytes(b))

    b = bytearray(base)
    struct.pack_into("<I", b, 0x438, 999)
    put("badoff", bytes(_fix_head_crc(b)))

    for name, count in (("count1023", 1023), ("count1024", 1024),
                        ("count5000", 5000)):
        b = bytearray(base)
        struct.pack_into("<I", b, 0x434, count)
        put(name, bytes(_fix_head_crc(b)))

    b = bytearray(base)
    struct.pack_into("<I", b, 2124, 7)
    put("badentrylen", bytes(_fix_head_crc(b)))

    for name, entries in variants().items():
        put(name, build(entries=entries)[0])

    # Every extractable entry with a safe name, so `extract` runs to the end
    # and the manifest covers the whole set. `main` cannot be used for this:
    # its unsafe entry stops the vendor tool partway through.
    safe = [e for e in ENTRIES if e[1] and e[1] != "sub/dir.bin"]
    img, man = build(entries=safe)
    put("payloads", img, man)

    # One entry per type value around the vendor's decimal/hex print cutoff,
    # plus every address-count shape.
    probe = [("ID%d" % v, "t%03d.bin" % v, 0x10, v, [], False)
             for v in (0, 1, 9, 10, 11, 0x7f, 0xff, 0x100, 0x101, 0x1000)]
    probe += [("A0", "a0.bin", 0x20, 1, [], False),
              ("A1", "a1.bin", 0x20, 1, [0x1111], False),
              ("A2", "a2.bin", 0x20, 1, [0x1111, 0x2222], False),
              ("A3", "a3.bin", 0x20, 1, [0x1111, 0x2222, 0x3333], False),
              ("A4", "a4.bin", 0x20, 1, [0x1111, 0x2222, 0x3333, 0x4444], False)]
    put("probe", build(entries=probe)[0])

    with open(os.path.join(outdir, "INDEX"), "w") as fh:
        fh.write("\n".join(written) + "\n")
    return 0


def main(argv):
    args = argv[1:]
    if args and args[0] == "--suite":
        if len(args) != 2:
            sys.stderr.write("usage: pac_fixture.py --suite OUTDIR\n")
            return 2
        return suite(args[1])
    corrupt = "--corrupt-crc" in args
    args = [a for a in args if a != "--corrupt-crc"]
    if len(args) != 1:
        sys.stderr.write("usage: pac_fixture.py OUT.pac [--corrupt-crc]\n"
                         "       pac_fixture.py --suite OUTDIR\n")
        return 2
    out = args[0]
    img, manifest = build(corrupt)
    with open(out, "wb") as fh:
        fh.write(img)
    with open(out + ".manifest", "w") as fh:
        fh.write("\n".join(manifest) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
