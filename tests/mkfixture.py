#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""mkfixture.py : fixtures for trial-logic3.sh (off the box).
  mkfixture.py mem OUT [FILE@HEXADDR ...] [ring:LINESFILE@HEXADDR]
        a fake memory image (0x3002000 bytes: random page 0..0x8000, zeros after), with files (RAM markers) placed at
        addresses and, optionally, a Linux 6.x printk text ring built from LINESFILE the way a real dump shows it
        (u32 id, text, kernel lines with their last two characters doubled, newline, NUL, padding to 4 bytes).
  mkfixture.py disklog DEV PAYLOADFILE --run 32HEX --gen N --seq N --uptime N
        write one valid ex4log snapshot into DEV's log region (format: src/ex4log.c header), slot seq%2.
Born Nov 16 2026 (EX4 run 5 prep)."""
import os, struct, sys, zlib

def block(rid, l):
    t = l.encode()
    body = t + (b'' if l.startswith(('ex4log: ', 'init: ')) else t[-2:]) + b'\n\0'
    blk = struct.pack('<I', rid) + body
    return blk + b'\0' * (-len(blk) % 4)

def mem(out, specs):
    buf = bytearray(os.urandom(0x8000)) + bytearray(0x3002000 - 0x8000)
    for spec in specs:
        f, addr = spec.rsplit('@', 1); a = int(addr, 16)
        if f.startswith('ring:'):
            d = b''; rid = 0x3fff8001
            for l in open(f[5:]).read().splitlines():
                if l: d += block(rid, l); rid += 1
        else:
            d = open(f, 'rb').read()
        buf[a:a + len(d)] = d
    open(out, 'wb').write(buf)

def disklog(dev, payload, run, gen, seq, up):
    p = open(payload, 'rb').read(); slot = seq % 2; off = (1 << 20) + slot * (1 << 20)
    assert len(p) <= (1 << 20) - 512 and len(run) == 32
    s = bytearray(512)
    s[0:8] = b'EX4LOG1\n'; s[8:16] = struct.pack('<II', 1, 64); s[16:32] = bytes.fromhex(run)
    s[32:52] = struct.pack('<IIIII', gen, seq, up, len(p), zlib.crc32(p) & 0xffffffff)
    s[52:60] = struct.pack('<HHI', slot, 0, 1 << 20)
    s[60:64] = struct.pack('<I', zlib.crc32(bytes(s[:60])) & 0xffffffff)
    with open(dev, 'r+b') as f:
        f.seek(off + 512); f.write(p); f.seek(off); f.write(s)

a = sys.argv
if a[1] == 'mem':
    mem(a[2], a[3:])
elif a[1] == 'disklog':
    o = dict(zip(a[4::2], a[5::2]))
    disklog(a[2], a[3], o['--run'], int(o['--gen']), int(o['--seq']), int(o['--uptime']))
else:
    sys.exit(__doc__)
