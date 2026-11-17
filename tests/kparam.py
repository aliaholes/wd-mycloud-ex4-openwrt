#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""kparam.py IMAGE NAME... : read built-in kernel parameter defaults out of a decompressed ARM Linux Image (VA base 0xc0008000).
For each NAME (e.g. watchdog.handle_boot_enabled): find the string, find the struct kernel_param that points at it
(name, mod, ops, perm/level/flags, arg), print the bytes at arg. Read-only."""
import sys, struct
BASE = 0xc0008000
img = open(sys.argv[1], 'rb').read()
def off(va): return va - BASE
def va(o): return o + BASE
for name in sys.argv[2:]:
    nb = name.encode() + b'\0'
    pos = -1; hits = []
    while True:
        pos = img.find(nb, pos + 1)
        if pos < 0: break
        if pos == 0 or img[pos - 1] == 0: hits.append(pos)
    print(f"{name}: {len(hits)} string hit(s) at {[hex(va(h)) for h in hits]}")
    for h in hits:
        pat = struct.pack('<I', va(h)); p = -1
        while True:
            p = img.find(pat, p + 1)
            if p < 0: break
            if p % 4: continue
            n, mod, ops, pl, arg = struct.unpack('<IIIII', img[p:p + 20])
            perm = pl & 0xffff
            ok = (BASE <= ops < BASE + len(img)) and (BASE <= arg < BASE + len(img)) and mod == 0
            print(f"  kernel_param? at {hex(va(p))}: mod={mod:#x} ops={ops:#x} perm={perm:#o} level={(pl>>16)&0xff} flags={(pl>>24)&0xff} arg={arg:#x} plausible={ok}")
            if ok:
                d = img[off(arg):off(arg) + 8]
                print(f"    bytes at arg: {d.hex()}  (u8={d[0]} u32={struct.unpack('<I', d[:4])[0]})")
