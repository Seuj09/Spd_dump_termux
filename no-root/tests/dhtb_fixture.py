#!/usr/bin/env python3
"""Synthesize DHTB ("sprd trusted firmware") fixtures for tests/dhtb-tools.sh.

The release tools parse this header:
    u32 @0x00   magic, 0x42544844 ("DHTB")
    u32 @0x30   H, offset of the block the size fields live in
    @H+0x200+{0x20,0x30,0x50} and +8   three (offset,size) pairs; the first
                pair with both halves non-zero sums to the real image size.
    a file whose H+0x260 reaches EOF is "not a full image": the release tools
    print the size and write nothing at all.

They then scan [0x200, H+0x200) for aarch64 signatures. The fixture plants one
matching site and one near-miss decoy for each pattern, plus a start/end marker
pair for the legacy algorithm, so the ports are exercised rather than just run.

Usage: dhtb_fixture.py OUTDIR
"""
import os
import struct
import sys

MAGIC = 0x42544844


def put32(buf, off, val):
    struct.pack_into("<I", buf, off, val)


def put16(buf, off, val):
    struct.pack_into("<H", buf, off, val)


def build(h=0x1000, total=0x2000, pair=(0, 0), which=0x50, magic=True, plant=True):
    buf = bytearray(total)
    if magic:
        put32(buf, 0, MAGIC)
    put32(buf, 0x30, h)
    if plant:
        # gen-spl-unlock: u32[o]==0x34000060, u32[o-4]>>8==0x940000, u16[o+6]==0x5280
        put32(buf, 0x2FC, 0x94000012)
        put32(buf, 0x300, 0x34000060)
        put16(buf, 0x306, 0x5280)
        # near miss, only u16[o+6] differs
        put32(buf, 0x33C, 0x94000012)
        put32(buf, 0x340, 0x34000060)
        put16(buf, 0x346, 0x5281)
        # gen-fdl1-dl: u32[o]==0x34000040, u32[o-4]>>8==0x940000, u32[o+4]==0x14000000
        put32(buf, 0x37C, 0x94000012)
        put32(buf, 0x380, 0x34000040)
        put32(buf, 0x384, 0x14000000)
        # near miss, only u32[o+4] differs
        put32(buf, 0x3BC, 0x94000012)
        put32(buf, 0x3C0, 0x34000040)
        put32(buf, 0x3C4, 0x14000001)
        # gen-spl-unlock-legacy: a start marker with an end marker after it
        put16(buf, 0x402, 0x9400)
        put16(buf, 0x406, 0x3400)
        put16(buf, 0x442, 0x9400)
        put16(buf, 0x446, 0x3400)
        put32(buf, 0x448, 0x14000000)
    if pair[0] or pair[1]:
        off = h + 0x200 + which
        if off + 12 <= total:
            put32(buf, off, pair[0])
            put32(buf, off + 8, pair[1])
    return bytes(buf)


VARIANTS = {
    # first non-zero pair is the 0x50 one
    "full": dict(h=0x1000, total=0x2000, pair=(0x1000, 0x800), which=0x50),
    # only the middle pair is set
    "pair2": dict(h=0x1000, total=0x2000, pair=(0x900, 0x700), which=0x30),
    # only the first pair is set
    "pair1": dict(h=0x1000, total=0x2000, pair=(0x800, 0x600), which=0x20),
    # no pair at all: falls back to H+0x200
    "nopair": dict(h=0x1000, total=0x2000, pair=(0, 0)),
    # H+0x260 reaches EOF: the release tools write nothing
    "short": dict(h=0x1000, total=0x1200, pair=(0x1000, 0x800)),
    "badmagic": dict(h=0x1000, total=0x2000, pair=(0x1000, 0x800), magic=False),
    "zeroh": dict(h=0, total=0x2000, pair=(0x1000, 0x800)),
}


def main():
    if len(sys.argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, kw in VARIANTS.items():
        with open(os.path.join(out, name + ".bin"), "wb") as f:
            f.write(build(**kw))
    return 0


if __name__ == "__main__":
    sys.exit(main())
