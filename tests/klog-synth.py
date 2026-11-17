#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""klog-synth.py: build a fake RAM image holding a Linux 6.x printk text ring plus decoys, to test `ex4peek klog --mem`.
Blocks are laid out the way a real dump shows them (qemu, 6.12.112): u32 id, the text, for kernel lines the last two
characters once more, a newline, a NUL, padding to 4 bytes; lines that came in through /dev/kmsg have no doubled pair. Off the box.  usage: klog-synth.py OUT EXPECT [OUT2 EXPECT2]
Born Nov 16 2026 (EX4 tooling)."""
import os, struct, sys, random
random.seed(7)
def block(rid, l):
    t = l.encode()
    body = t + (b'' if l.startswith(('ex4log: ', 'init: ')) else t[-2:]) + b'\n\0'
    blk = struct.pack('<I', rid) + body
    return blk + b'\0' * (-len(blk) % 4)
lines = ["Booting Linux on physical CPU 0x0",
         "Linux version 6.12.112 (builder@buildhost) (arm-openwrt-linux-muslgnueabi-gcc (OpenWrt GCC 14.3.0) 14.3.0) #0 Sat Oct 17 21:45:38 2026",
         "CPU: Feroceon 88FR131 [56251311] revision 1 (ARMv5TE), cr=0005397f",
         "OF: fdt: Machine model: Western Digital My Cloud EX4",
         "Memory policy: Data cache writeback"] + ["synthetic record %d %s" % (i, "x" * random.randint(0, 200)) for i in range(300)] + \
        ["ex4log: daemon started (bundle-v1), pid 412", "ex4log: sd disks visible: 0, usable log targets: 0", "LAST RECORD"]
ring = b''; rid = 0x3fff8001
for i, l in enumerate(lines):
    if i == 100: rid += 3                    # a gap in the ids (records without text have no block)
    ring += block(rid, l); rid += 1
img = bytearray(os.urandom(6 << 20))
# decoy 1: the same text as a plain dmesg file (time-stamped lines): must NOT be taken for a ring
decoy = ("[    0.000000] Booting Linux on physical CPU 0x0\n[    0.000000] Linux version 6.12.112 (builder@buildhost)\n" * 3).encode()
img[0x40000:0x40000 + len(decoy)] = decoy
# decoy 2: the format string as it sits in the kernel's own rodata
fmt = b"\0Booting Linux on physical CPU 0x%x\n\0Linux version %s\0"
img[0x90000:0x90000 + len(fmt)] = fmt
# the real ring, deliberately straddling a 1 MiB chunk edge of the scanner (marker split across two reads)
pos = (3 << 20) - 4 - 10
img[pos:pos + len(ring) + 4096] = ring + bytes(4096)
open(sys.argv[1], 'wb').write(img)
open(sys.argv[2], 'w').write("\n".join(lines) + "\n")
print("ring at 0x%x, %d records, %d bytes" % (pos, len(lines), len(ring)))

# second image: a WRAPPED 16 KiB ring. Records are laid down in order; one that does not fit at the end goes to the
# start (as the kernel does), overwriting the oldest. What is left: the newest part at the start, older ones after.
if len(sys.argv) > 4:
    size = 16384; buf = bytearray(size); head = 0; rid = 0x3fff9000; live = {}       # offset -> (id, text)
    wl = ["Booting Linux on physical CPU 0x0", "Linux version 6.12.112 (builder@buildhost) #0"] + \
         ["wrapped ring record %d %s" % (i, "y" * random.randint(10, 120)) for i in range(400)] + ["ex4log: alive: seq 9, target sda3", "NEWEST RECORD"]
    for l in wl:
        blk = block(rid, l)
        if head + len(blk) > size:                               # does not fit: its id stays at the end as a stub, the block goes to the start
            buf[head:head + 4] = blk[:4]
            for o in [o for o in live if o < head + 4 and o + live[o][2] > head]: del live[o]
            head = 0
        for o in [o for o in live if o < head + len(blk) and o + live[o][2] > head]: del live[o]
        buf[head:head + len(blk)] = blk; live[head] = (rid, l, len(blk)); head += len(blk); rid += 1
    img2 = bytearray(os.urandom(4 << 20)); p2 = 0x180000
    img2[p2:p2 + size] = buf
    open(sys.argv[3], 'wb').write(img2)
    surv = sorted(live.values())
    open(sys.argv[4], 'w').write("".join(t + "\n" for _, t, _ in surv))
    print("wrapped ring at 0x%x: %d of %d records survive whole (ids %#x..%#x)" % (p2, len(surv), len(wl), surv[0][0], surv[-1][0]))
