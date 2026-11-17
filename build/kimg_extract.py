#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""kimg_extract.py: pull the uncompressed kernel Image out of a legacy uImage / zImage (gzip, xz or lzma payload), off the box.
Usage: python3 -I kimg_extract.py IN OUT   (IN = uImage or raw partition dump; OUT = Image)   Born Nov 16 2026 (EX4 tooling)."""
import sys, zlib, lzma, struct
d = open(sys.argv[1], 'rb').read()
if d[:4] == b'\x27\x05\x19\x56':
    size = struct.unpack('>I', d[12:16])[0]; d = d[64:64+size]
best = None
i = 0
while True:
    i = d.find(b'\x1f\x8b\x08', i)
    if i < 0: break
    try:
        o = zlib.decompressobj(31).decompress(d[i:])
        if best is None or len(o) > len(best[1]): best = ('gzip@%#x' % i, o)
    except Exception: pass
    i += 1
for magic, name in ((b'\xfd7zXZ\x00', 'xz'), (b'\x5d\x00\x00', 'lzma')):
    i = 0
    while True:
        i = d.find(magic, i)
        if i < 0: break
        try:
            o = lzma.LZMADecompressor(lzma.FORMAT_AUTO).decompress(d[i:])
            if best is None or len(o) > len(best[1]): best = ('%s@%#x' % (name, i), o)
        except Exception: pass
        i += 1
if not best or len(best[1]) < 1 << 20: sys.exit("no kernel payload found")
open(sys.argv[2], 'wb').write(best[1]); print(best[0], len(best[1]), "bytes ->", sys.argv[2])
