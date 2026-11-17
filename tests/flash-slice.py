#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""flash-slice.py: what would the trial kernel see in one flash partition? Off the box; reads your own dumps.

  python3 -I flash-slice.py <kernel.bin | --v5-layout> <dir with mtd0.dd .. mtd6.dd> <partition label> <out file>

The dumps are the seven partitions as the STOCK firmware names them (dd if=/dev/mtdN of=mtdN.dd, taken under stock).
This puts them back where the stock kernel says they sit on the chip (STOCK_TABLE: its own boot log on firmware
2.12.127), then cuts out the range that the device tree appended to <kernel.bin> gives the partition called <label>.
With a correct tree the result is the stock dump of the same name, byte for byte. With bundle-v5's tree
(--v5-layout: the last three partitions in address order) "rescue firmware" comes out 5 MiB too low: it starts with
WD's "reserve" partition, a UBI volume, which is why run 7 found no MAC address there.
Prints what the slice starts with. Exit 0 if the slice equals the stock dump of that name, 3 if it does not.
Never overwrites <out file>. Born Nov 17 2026 (EX4 run 8 prep)."""
import os, struct, sys

STOCK_TABLE = [("u-boot", 0x00000000, 0x00100000), ("uImage", 0x00100000, 0x00500000), ("ramdisk", 0x00600000, 0x00500000),
               ("image", 0x00b00000, 0x0cd00000), ("rescue firmware", 0x0dd00000, 0x00f00000), ("config", 0x0ec00000, 0x01400000),
               ("reserve", 0x0d800000, 0x00500000)]          # index = WD's mtd number
V5_TABLE = STOCK_TABLE[:4] + [("rescue firmware", 0x0d800000, 0x00f00000), ("config", 0x0e700000, 0x01400000), ("reserve", 0x0fb00000, 0x00500000)]

def dtb_table(path):
    b = open(path, 'rb').read()
    if b[:4] != b'\xd0\x0d\xfe\xed':
        if struct.unpack('<I', b[0x24:0x28])[0] != 0x016f2818: sys.exit("%s is neither a DTB nor an ARM zImage" % path)
        zs, ze = struct.unpack('<II', b[0x28:0x30]); b = b[ze - zs:]
    magic, total, off_struct, off_strings = struct.unpack('>4I', b[:16])
    if magic != 0xd00dfeed: sys.exit("no device tree in %s" % path)
    strs = b[off_strings:off_strings + struct.unpack('>I', b[32:36])[0]]
    p = off_struct; path_ = []; out = []; cur = None
    while True:
        tok = struct.unpack('>I', b[p:p + 4])[0]; p += 4
        if tok == 1:
            e = b.index(b'\0', p); path_.append(b[p:e].decode()); p = (e + 4) & ~3
            cur = {} if ('nand' in '/'.join(path_) and path_[-1].startswith('partition@')) else None
            if cur is not None: out.append(cur)
        elif tok == 2: path_.pop(); cur = None
        elif tok == 3:
            ln, no = struct.unpack('>II', b[p:p + 8]); p += 8
            if cur is not None: cur[strs[no:strs.index(b'\0', no)].decode()] = b[p:p + ln]
            p = (p + ln + 3) & ~3
        elif tok == 4: continue
        elif tok == 9: break
        else: sys.exit("bad FDT token")
    return [(c['label'].rstrip(b'\0').decode(),) + struct.unpack('>II', c['reg']) for c in out]

def main():
    if len(sys.argv) != 5: sys.exit(__doc__)
    src, ddir, label, outp = sys.argv[1:]
    if os.path.exists(outp): sys.exit("REFUSED: %s exists" % outp)
    table = V5_TABLE if src == '--v5-layout' else dtb_table(src)
    chip = bytearray(b'\xff' * 0x10000000)
    for i, (name, off, size) in enumerate(STOCK_TABLE):
        d = open(os.path.join(ddir, 'mtd%d.dd' % i), 'rb').read()
        if len(d) != size: sys.exit("mtd%d.dd is %d bytes, the stock table says %d (%s)" % (i, len(d), size, name))
        chip[off:off + size] = d
    hit = [t for t in table if t[0] == label]
    if len(hit) != 1: sys.exit("the tree has %d partitions called %r" % (len(hit), label))
    _, off, size = hit[0]
    sl = bytes(chip[off:off + size])
    open(outp, 'wb').write(sl)
    i = [n for n, _, _ in STOCK_TABLE].index(label)
    same = sl == open(os.path.join(ddir, 'mtd%d.dd' % i), 'rb').read()
    head = sl[:64]
    kind = ("two MAC addresses as text at byte 0 and byte 0x1c, 55 AA at 0x32 (WD's identity block)" if head[2:3] == b':' and head[0x1e:0x1f] == b':' and head[0x32:0x34] == b'\x55\xaa'
            else "a UBI erase-block header (UBI#)" if head[:4] == b'UBI#' else "a uImage header" if head[:4] == b'\x27\x05\x19\x56' else "erased flash" if head == b'\xff' * 64 else "something else")
    print("layout: %s; partition %r = chip %#010x + %#x; it starts with %s; equal to the stock dump mtd%d.dd of the same name: %s" %
          ("bundle-v5's (address order)" if src == '--v5-layout' else "the device tree in " + os.path.basename(src), label, off, size, kind, i, "yes" if same else "NO"))
    sys.exit(0 if same else 3)
main()
