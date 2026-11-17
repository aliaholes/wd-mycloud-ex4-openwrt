#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""dtb_check.py: parse the device tree APPENDED to a bundle's kernel.bin (not the source) and prove what the trial
kernel will be told: every NAND partition read-only, which reserved-memory / ramoops nodes exist, bootargs, model.
Exit 0 only if there are exactly 7 NAND partitions and all 7 carry `read-only`.
  python3 -I dtb_check.py kernel.bin [--v3 | --v6]   Born Nov 16 2026 (EX4 tooling). Off the box; reads one file.
--v3 (run 5 prep) also checks what the 6.12 handoff leans on: machine compatible, the watchdog node, the reset
controller, the L2 node, uart0, bootargs, the memory node's name, no flash-kept bad-block table, no auto-attached names.
--v6 (run 8 prep) = --v3 + the two things run 7 showed were wrong or missing:
  * the seven partitions, in the tree's order, are EXACTLY the stock kernel's own table (name, offset, size, and the
    order, which gives the mtd numbers). WD_TABLE below is copied from the boot log of firmware 2.12.127 on the test
    unit; WD's last three partitions are not in address order. The v5 tree had them in address order: its "rescue
    firmware" pointed 5 MiB too low, at WD's "reserve", and the trial found no MAC address there;
  * no partition overlaps another, and together they cover the whole 256 MiB chip;
  * both PHY nodes carry "ethernet-phy-idAAAA.BBBB" as their FIRST compatible string (the only one the kernel's
    fwnode_get_phy_id() reads), the same id on both, and not the 88E151x's own (0141.0ddx): tests/phy-id-check.py then
    proves against the kernel source that no PHY driver claims that id."""
import struct, sys

b = open(sys.argv[1], 'rb').read()
if struct.unpack('<I', b[0x24:0x28])[0] != 0x016f2818:
    sys.exit("not an ARM zImage")
zs, ze = struct.unpack('<II', b[0x28:0x30])
d = b[ze - zs:]
if len(d) < 40:
    sys.exit("no appended DTB: %d bytes follow the zImage" % len(d))
magic, total, off_struct, off_strings, off_rsv, ver, lastcomp, cpu, sz_strings, sz_struct = struct.unpack('>10I', d[:40])
if magic != 0xd00dfeed or total != len(d):
    sys.exit("no clean appended DTB (magic %#x, totalsize %d, bytes after the zImage %d)" % (magic, total, len(d)))
strs = d[off_strings:off_strings + sz_strings]
rsv = []
o = off_rsv
while True:
    a, s = struct.unpack('>QQ', d[o:o + 16]); o += 16
    if not a and not s: break
    rsv.append((a, s))
p = off_struct; path = []; nodes = {}
while True:
    tok = struct.unpack('>I', d[p:p + 4])[0]; p += 4
    if tok == 1:
        e = d.index(b'\0', p); name = d[p:e].decode(); p = (e + 4) & ~3
        path.append(name); nodes['/'.join(path) or '/'] = {}
    elif tok == 2:
        path.pop()
    elif tok == 3:
        ln, no = struct.unpack('>II', d[p:p + 8]); p += 8
        nm = strs[no:strs.index(b'\0', no)].decode()
        nodes['/'.join(path) or '/'][nm] = d[p:p + ln]; p = (p + ln + 3) & ~3
    elif tok == 4:
        continue
    elif tok == 9:
        break
    else:
        sys.exit("bad FDT token %#x" % tok)
root = nodes['/']
print("appended DTB: %d bytes, version %d; model %r; compatible %r" % (total, ver, root.get('model', b'').rstrip(b'\0').decode(),
      root.get('compatible', b'').rstrip(b'\0').split(b'\0')))
print("memory reservations (header block):", rsv or "none")
ch = [v for k, v in nodes.items() if k.endswith('/chosen')]
print("chosen bootargs:", ch[0].get('bootargs', b'').rstrip(b'\0').decode() if ch else None)
rm = [k for k in nodes if '/reserved-memory' in k]
ro = [k for k, v in nodes.items() if b'ramoops' in v.get('compatible', b'')]
print("reserved-memory nodes:", rm or "none", "| ramoops nodes:", ro or "none")
parts = [(k, v) for k, v in nodes.items() if '/partitions/partition@' in k and 'nand' in k]
bad = 0
for k, v in parts:
    off, size = struct.unpack('>II', v['reg'])
    is_ro = 'read-only' in v
    bad += not is_ro
    print("  nand %-18s %#010x + %#010x  %s" % (v['label'].rstrip(b'\0').decode(), off, size, "read-only" if is_ro else "WRITABLE"))
print("RESULT: %d NAND partitions, %d read-only, %d writable" % (len(parts), len(parts) - bad, bad))
# the stock kernel's boot log, firmware 2.12.127 ("Creating 7 MTD partitions on "orion_nand":" and the seven lines after it)
WD_TABLE = [("u-boot", 0x00000000, 0x00100000), ("uImage", 0x00100000, 0x00600000), ("ramdisk", 0x00600000, 0x00b00000),
            ("image", 0x00b00000, 0x0d800000), ("rescue firmware", 0x0dd00000, 0x0ec00000), ("config", 0x0ec00000, 0x10000000),
            ("reserve", 0x0d800000, 0x0dd00000)]
if len(sys.argv) > 2 and sys.argv[2] in ('--v3', '--v6'):
    # v3 (run 5 prep, Nov 16 2026): what else the 6.12 handoff leans on, read in the SAME appended DTB
    def node(pred):
        return [(k, v) for k, v in nodes.items() if pred(k, v)]
    def st(v):
        return v.get('status', b'okay\0').rstrip(b'\0').decode()
    fail = []
    def want(ok, what):
        print("  %s  %s" % ("ok  " if ok else "FAIL", what))
        if not ok: fail.append(what)
    comp = root.get('compatible', b'').rstrip(b'\0').split(b'\0')
    want(b'marvell,kirkwood' in comp, "root compatible lists marvell,kirkwood (the only thing a 6.12 DT boot matches the machine on; r1 is not used): %r" % comp)
    wd = node(lambda k, v: v.get('compatible', b'').rstrip(b'\0') == b'marvell,orion-wdt')
    want(len(wd) == 1 and st(wd[0][1]) == 'okay' and struct.unpack('>4I', wd[0][1]['reg']) == (0x20300, 0x28, 0x20108, 0x4),
         "one marvell,orion-wdt node, status okay, reg = TIMER block 0x20300 + RSTOUT mask 0x20108 (the two registers ex4boot's wdt=1 writes): %s" % (wd[0][0] if wd else None))
    want(len(wd) == 1 and 'interrupts' in wd[0][1] and 'clocks' in wd[0][1], "the watchdog node has its interrupt and clock")
    sc = node(lambda k, v: v.get('compatible', b'').rstrip(b'\0') == b'marvell,orion-system-controller')
    want(len(sc) == 1, "one marvell,orion-system-controller node (the reset path of `reboot` and of a panic)")
    l2 = node(lambda k, v: b'marvell,kirkwood-cache' in v.get('compatible', b''))
    want(len(l2) == 1, "one marvell,kirkwood-cache node (feroceon_of_init: enables the L2 when it finds it off)")
    ua = node(lambda k, v: k.endswith('/serial@12000'))
    want(len(ua) == 1 and st(ua[0][1]) == 'okay', "uart0 (serial@12000) is enabled: the console the command line names")
    bootargs = ch[0].get('bootargs', b'').rstrip(b'\0').decode() if ch else ''
    want(bootargs == 'console=ttyS0,115200n8', "the DTB's own bootargs (used only if the ATAG list were ignored): %r" % bootargs)
    mem = node(lambda k, v: v.get('device_type', b'').rstrip(b'\0') == b'memory')
    want(len(mem) == 1 and struct.unpack('>II', mem[0][1]['reg']) == (0, 0x20000000) and mem[0][0].split('/')[-1] == 'memory',
         "one memory node named 'memory' (the name atags_to_fdt writes to), 512 MiB at 0")
    nd = node(lambda k, v: k.endswith('/nand@12f') or v.get('compatible', b'').rstrip(b'\0') == b'marvell,orion-nand')
    want(len(nd) >= 1 and all('nand-on-flash-bbt' not in v for k, v in nd), "the NAND node has no nand-on-flash-bbt (a flash-kept bad-block table is written below the partition layer, read-only flags or not)")
    want(not rsv and not rm, "no memory reservation: the RAM markers at 0x1000 / 0x3000 are NOT protected from a 6.12 kernel that reaches its allocator (by design; the verdict reads the ring and the disk log first)")
    ubi = [v['label'].rstrip(b'\0').decode() for k, v in parts if v['label'].rstrip(b'\0') in (b'ubi', b'data', b'rootfs', b'rootfs_data')]
    want(not ubi, "no partition is named ubi / data / rootfs / rootfs_data (OpenWrt attaches or mounts such names by itself): %r" % ubi)
    if sys.argv[2] == '--v6':
        got = [(v['label'].rstrip(b'\0').decode(),) + struct.unpack('>II', v['reg']) for k, v in parts]
        got = [(n, o, o + z) for n, o, z in got]
        want(got == WD_TABLE, "the seven partitions, in the tree's order (= the mtd numbers), are the stock kernel's own table: %s" %
             ("yes" if got == WD_TABLE else "NO: " + "; ".join("%s %#x-%#x (WD: %s %#x-%#x)" % (g + w) for g, w in zip(got, WD_TABLE) if g != w)))
        names = [k.rsplit('@', 1)[1] for k, v in parts]
        want(all(int(n, 16) == o for n, (_, o, _e) in zip(names, got)), "every partition node's unit address is its offset")
        iv = sorted((o, e) for _, o, e in got)
        want(iv[0][0] == 0 and iv[-1][1] == 0x10000000 and all(a[1] == b[0] for a, b in zip(iv, iv[1:])),
             "the partitions do not overlap and cover the 256 MiB chip without a gap")
        phys = [(k, v.get('compatible', b'').rstrip(b'\0').split(b'\0')) for k, v in nodes.items() if '/ethernet-phy@' in k]
        import re
        ids = [re.fullmatch(rb'ethernet-phy-id([0-9a-f]{4})\.([0-9a-f]{4})', c[0]) for k, c in phys]
        want(len(phys) == 2 and all(ids), "two PHY nodes, each with ethernet-phy-idAAAA.BBBB as its FIRST compatible string: %r" % [c for k, c in phys])
        want(len(phys) == 2 and all(ids) and ids[0].group(0) == ids[1].group(0) and not (ids[0].group(1) == b'0141' and ids[0].group(2)[:3] == b'0dd'),
             "the same id on both, and not the 88E151x's own 0141.0ddx (the kernel then never binds the Marvell PHY driver to them)")
        macs = [v for k, v in nodes.items() if 'phy-handle' in v]
        want(len(macs) == 2, "two MAC ports with a phy-handle (both ports stay under phylib)")
    print("%s RESULT: %s" % (sys.argv[2][2:].upper(), "all checks ok" if not fail else "%d FAILED" % len(fail)))
    sys.exit(0 if len(parts) == 7 and bad == 0 and not fail else 1)
sys.exit(0 if len(parts) == 7 and bad == 0 else 1)
