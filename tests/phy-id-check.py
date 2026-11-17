#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""phy-id-check.py: prove that NO PHY driver in a Linux source tree claims the PHY id the EX4 device tree puts on its
two Ethernet PHYs, so that the kernel falls back to its built-in generic PHY driver for them (docs/HARDWARE.md,
"The link flap"). Reads only.

  python3 -I phy-id-check.py <linux source dir | linux-X.Y.Z.tar.xz> <kernel.bin | file.dtb> [<decompressed Image>]

What it does:
  1. reads the appended device tree (or a .dtb) and takes the id out of each PHY node's FIRST compatible string,
     "ethernet-phy-idAAAA.BBBB": that is the only string the kernel's fwnode_get_phy_id() looks at;
  2. collects every (phy_id, phy_id_mask) pair of every `struct phy_driver` under drivers/net/ in the source
     (.phy_id / .phy_id_mask initialisers and the PHY_ID_MATCH_EXACT / _MODEL / _VENDOR macros), resolving the
     #define names it meets;
  3. fails if any pair matches the id the way the kernel's phy_bus_match() does ((id & mask) == (drv_id & mask)),
     if a pair cannot be resolved to numbers, or if fewer than 150 pairs were found (a parser that went blind).
With <decompressed Image> (build/kimg_extract.py makes it from kernel.bin) it also checks that the source is a fair
witness for the kernel BINARY we boot, which is OpenWrt's build and carries OpenWrt's patches: every "Marvell 88E..."
PHY driver name inside the Image is a driver name in the source's marvell.c, "Generic PHY" is in it, and none of the
PHY drivers OpenWrt adds on top of kernel.org (its swconfig switch drivers) is.
It also checks, in the same source, the three facts the fix leans on: the 88E1510 driver entry carries the fibre
feature and marvell_read_status(); marvell_read_status() selects the fibre page; mv643xx_eth leaves the MAC's own
(hardware) auto-negotiation on while the PHY autonegotiates. If a future kernel changes one of them this test says so.
Born Nov 17 2026 (EX4, run 8 prep)."""
import io, os, re, struct, sys, tarfile

def die(m):
    print("phy-id-check: FAIL: " + m); sys.exit(1)

def load_source(src):
    """-> {relative path: text} for include/linux/*.h and drivers/net/**/*.[ch]"""
    out = {}
    want = lambda p: (p.startswith('drivers/net/') and p.endswith(('.c', '.h'))) or \
                     (p.startswith('include/linux/') and p.endswith('.h') and p.count('/') == 2)
    if os.path.isdir(src):
        for base in ('drivers/net', 'include/linux'):
            for dp, dn, fn in os.walk(os.path.join(src, base)):
                if base == 'include/linux': dn[:] = []
                for f in fn:
                    rel = os.path.relpath(os.path.join(dp, f), src)
                    if want(rel):
                        out[rel] = open(os.path.join(dp, f), encoding='latin-1').read()
    else:
        with tarfile.open(src) as t:
            for m in t:
                if not m.isfile(): continue
                rel = m.name.split('/', 1)[1] if '/' in m.name else m.name
                if want(rel):
                    out[rel] = t.extractfile(m).read().decode('latin-1')
    return out

def dtb_phy_ids(path):
    b = open(path, 'rb').read()
    if b[:4] != b'\xd0\x0d\xfe\xed':
        if struct.unpack('<I', b[0x24:0x28])[0] != 0x016f2818: die("%s is neither a DTB nor an ARM zImage" % path)
        zs, ze = struct.unpack('<II', b[0x28:0x30]); b = b[ze - zs:]
    magic, total, off_struct, off_strings = struct.unpack('>4I', b[:16])
    if magic != 0xd00dfeed: die("no device tree in %s" % path)
    sz_strings = struct.unpack('>I', b[32:36])[0]; strs = b[off_strings:off_strings + sz_strings]
    p = off_struct; pathl = []; nodes = {}
    while True:
        tok = struct.unpack('>I', b[p:p + 4])[0]; p += 4
        if tok == 1:
            e = b.index(b'\0', p); pathl.append(b[p:e].decode()); p = (e + 4) & ~3; nodes['/'.join(pathl)] = {}
        elif tok == 2: pathl.pop()
        elif tok == 3:
            ln, no = struct.unpack('>II', b[p:p + 8]); p += 8
            nodes['/'.join(pathl)][strs[no:strs.index(b'\0', no)].decode()] = b[p:p + ln]; p = (p + ln + 3) & ~3
        elif tok == 4: continue
        elif tok == 9: break
        else: die("bad FDT token")
    ids = []
    for k, v in nodes.items():
        if '/ethernet-phy@' not in k: continue
        first = v.get('compatible', b'').split(b'\0')[0].decode()
        m = re.fullmatch(r'ethernet-phy-id([0-9a-fA-F]{4})\.([0-9a-fA-F]{4})', first)
        ids.append((k, first, (int(m.group(1), 16) << 16 | int(m.group(2), 16)) if m else None))
    return ids

def main():
    if len(sys.argv) not in (3, 4): die("usage: phy-id-check.py <linux source dir or tarball> <kernel.bin or dtb> [<decompressed Image>]")
    files = load_source(sys.argv[1])
    if not files: die("no kernel source under %s" % sys.argv[1])
    defs = {}
    for text in files.values():
        for m in re.finditer(r'^[ \t]*#[ \t]*define[ \t]+(\w+)[ \t]+(.+?)[ \t]*(?:/\*.*)?$', text, re.M):
            defs.setdefault(m.group(1), m.group(2).strip())
    def ev(expr, depth=0):
        expr = re.sub(r'/\*.*?\*/', '', expr).strip()
        if depth > 12: raise ValueError(expr)
        expr = re.sub(r'GENMASK\(\s*(\d+)\s*,\s*(\d+)\s*\)', lambda m: hex(((1 << (int(m.group(1)) + 1)) - 1) & ~((1 << int(m.group(2))) - 1)), expr)
        expr = re.sub(r'\b(0x[0-9a-fA-F]+|\d+)[uUlL]+\b', r'\1', expr)
        def name(m):
            n = m.group(0)
            if n not in defs: raise ValueError("unknown name %s" % n)
            return '(' + str(ev(defs[n], depth + 1)) + ')'
        expr = re.sub(r'\b[A-Za-z_]\w*\b', name, expr)
        if not re.fullmatch(r'[0-9a-fA-FxX()|&~<>+\- \t]+', expr): raise ValueError(expr)
        return eval(expr, {'__builtins__': {}}) & 0xffffffff
    pairs = []; unresolved = []
    for rel, text in sorted(files.items()):
        if not rel.endswith('.c') or 'phy_driver' not in text: continue
        t = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        for m in re.finditer(r'\.phy_id\s*=\s*([^,}]+)[,}]', t):
            tail = t[m.end():m.end() + 400]
            mm = re.search(r'\.phy_id_mask\s*=\s*([^,}]+)[,}]', tail)
            nxt = re.search(r'\.phy_id\s*=', tail)
            if mm and (not nxt or mm.start() < nxt.start()): mask = mm.group(1)
            else:
                back = t[max(0, m.start() - 400):m.start()]
                mb = list(re.finditer(r'\.phy_id_mask\s*=\s*([^,}]+)[,}]', back))
                mask = mb[-1].group(1) if mb else None
            idx = m.group(1).strip().strip('()').strip()
            mac_def = None
            if re.fullmatch(r'_\w+', idx):
                # the id is a macro parameter (#define FOO_DRIVER(_id, _name) { .phy_id = _id, ... }): take the
                # id from every place the macro is used
                for d in re.finditer(r'#[ \t]*define[ \t]+(\w+)\(([^)]*)\)', t[:m.start()]): mac_def = d
            if mac_def and idx in [x.strip() for x in mac_def.group(2).split(',')]:
                pos = [x.strip() for x in mac_def.group(2).split(',')].index(idx)
                uses = [u for u in re.finditer(r'\b%s\(([^;{}]*?)\)\s*[,}]' % mac_def.group(1), t) if u.start() > m.end()]
                if not uses: unresolved.append((rel, idx, str(mask), "macro %s is never used" % mac_def.group(1)))
                for u in uses:
                    try:
                        arg = u.group(1).split(',')[pos]
                        mk = ev(mask) if mask is not None else None
                        if mk is None: raise ValueError("no mask beside it")
                        pairs.append((rel, ev(arg), mk, '%s(%s)' % (mac_def.group(1), arg.strip())))
                    except Exception as e:
                        unresolved.append((rel, u.group(0)[:60], str(mask), str(e)))
                continue
            try:
                if mask is None: raise ValueError("no mask beside it")
                pairs.append((rel, ev(m.group(1)), ev(mask), m.group(1).strip()))
            except Exception as e:
                unresolved.append((rel, m.group(1).strip(), str(mask), str(e)))
        for kind, mask in (('EXACT', 0xffffffff), ('MODEL', 0xfffffff0), ('VENDOR', 0xfffffc00)):
            for m in re.finditer(r'PHY_ID_MATCH_%s\(([^)]+(?:\([^)]*\))?[^)]*)\)' % kind, t):
                if re.match(r'\s*id\s*$', m.group(1)): continue        # the macro's own definition
                a = m.group(1).strip()
                if re.fullmatch(r'_\w+', a):                           # a macro parameter, as above
                    d = None
                    for d in re.finditer(r'#[ \t]*define[ \t]+(\w+)\(([^)]*)\)', t[:m.start()]): pass
                    ps = [x.strip() for x in d.group(2).split(',')] if d else []
                    uses = [u for u in re.finditer(r'\b%s\(([^;{}]*?)\)\s*[,}]' % d.group(1), t) if u.start() > m.end()] if a in ps else []
                    if not uses: unresolved.append((rel, a, kind, "macro parameter with no use found"))
                    for u in uses:
                        try: pairs.append((rel, ev(u.group(1).split(',')[ps.index(a)]), mask, '%s(...) -> PHY_ID_MATCH_%s' % (d.group(1), kind)))
                        except Exception as e: unresolved.append((rel, u.group(0)[:60], kind, str(e)))
                    continue
                try: pairs.append((rel, ev(m.group(1)), mask, 'PHY_ID_MATCH_%s(%s)' % (kind, m.group(1).strip())))
                except Exception as e: unresolved.append((rel, m.group(1).strip(), kind, str(e)))
    print("phy-id-check: %d (id, mask) pairs of PHY drivers read from %d source files; %d could not be resolved" % (len(pairs), len(files), len(unresolved)))
    for u in unresolved: print("  UNRESOLVED %s: id %s mask %s (%s)" % u)
    fail = 0
    ids = dtb_phy_ids(sys.argv[2])
    if len(ids) != 2: die("expected 2 ethernet-phy nodes in the device tree, found %d" % len(ids))
    for node, comp, pid in ids:
        if pid is None:
            print("  FAIL  %s: first compatible is %r, not ethernet-phy-idAAAA.BBBB (the kernel would read the id from the chip and bind the Marvell driver)" % (node, comp)); fail += 1; continue
        hits = [p for p in pairs if (pid & p[2]) == (p[1] & p[2])]
        print("  %s  %s: id 0x%08x (%s): claimed by %d of %d driver entries%s" % ("ok  " if not hits else "FAIL", node, pid, comp, len(hits), len(pairs),
              "" if not hits else ": " + "; ".join("%s %s" % (h[0], h[3]) for h in hits[:4])))
        fail += bool(hits)
    real = 0x01410dd0
    hits = [p for p in pairs if (real & p[2]) == (p[1] & p[2])]
    ok = len(hits) == 1 and hits[0][0] == 'drivers/net/phy/marvell.c'
    print("  %s  self-check of the parser: the 88E151x's real id 0x%08x is claimed by exactly one entry, in marvell.c: %s" % ("ok  " if ok else "FAIL", real, [(h[0], h[3]) for h in hits])); fail += not ok
    mv = files.get('drivers/net/phy/marvell.c', ''); mac = files.get('drivers/net/ethernet/marvell/mv643xx_eth.c', '')
    def fact(ok, what):
        nonlocal fail
        print("  %s  %s" % ("ok  " if ok else "FAIL", what)); fail += not ok
    ent = re.search(r'\.phy_id = MARVELL_PHY_ID_88E1510,(.*?)\n\t\},', mv, re.S)
    fact(bool(ent) and 'PHY_GBIT_FIBRE_FEATURES' in ent.group(1) and '.read_status = marvell_read_status' in ent.group(1),
         "marvell.c: the 88E1510 entry has .features = PHY_GBIT_FIBRE_FEATURES and .read_status = marvell_read_status")
    rs = re.search(r'static int marvell_read_status\(struct phy_device \*phydev\)\n\{(.*?)\n\}', mv, re.S)
    fact(bool(rs) and 'marvell_set_page(phydev, MII_MARVELL_FIBER_PAGE)' in rs.group(1) and 'ETHTOOL_LINK_MODE_FIBRE_BIT' in rs.group(1),
         "marvell.c: marvell_read_status() selects the FIBRE register page on every call when the PHY supports fibre (the page flip)")
    al = re.search(r'static void mv643xx_eth_adjust_link\(struct net_device \*dev\)\n\{(.*?)\n\}', mac, re.S)
    fact(bool(al) and re.search(r'autoneg == AUTONEG_ENABLE\) \{\s*/\* enable auto negotiation \*/\s*pscr &= ~autoneg_disable;', al.group(1)) is not None,
         "mv643xx_eth.c: with PHY autonegotiation on, adjust_link() leaves the MAC's own hardware negotiation on (it follows what it polls from the PHY)")
    fact('netdev_info(dev, "link down\\n")' in mac, "mv643xx_eth.c: 'link down' is printed from the MAC's own link interrupt (handle_link_event)")
    gp = files.get('drivers/net/phy/phy_device.c', '')
    fact('sscanf(cp, "ethernet-phy-id%4x.%4x", &upper, &lower)' in gp and 'd->driver = &genphy_driver.mdiodrv.driver' in gp,
         "phy_device.c: the id comes from the first compatible string, and a PHY no driver claims gets the generic driver")
    if len(sys.argv) == 4:
        img = open(sys.argv[3], 'rb').read()
        src_names = set(re.findall(r'\.name\s*=\s*"([^"]+)"', mv))
        bin_names = set(m.decode() for m in re.findall(rb'(?<![\x20-\x7e])(Marvell 88[A-Z][0-9A-Za-z/ ()]{3,40})\x00', img))
        extra = sorted(bin_names - src_names)
        fact(len(bin_names) >= 10 and not extra, "the kernel image names %d Marvell PHY drivers, every one of them a driver name in this source's marvell.c%s" % (len(bin_names), "" if not extra else ": NOT in the source: %r" % extra))
        fact(b'\x00Generic PHY\x00' in img, "the kernel image carries the generic PHY driver ('Generic PHY')")
        ow = [n for n in (b'Atheros AR8216', b'Marvell 88E6060', b'IC+ IP17', b'Realtek RTL8306', b'ADM6996', b'Lantiq PSB6970', b'RTL8366', b'mvsw61xx') if n in img]
        fact(not ow, "none of OpenWrt's own extra PHY-level switch drivers is in the kernel image: %r" % ow)
    if unresolved: fail += 1
    if len(pairs) < 150: print("  FAIL  only %d pairs found: the parser missed most drivers" % len(pairs)); fail += 1
    print("phy-id-check: %s" % ("PASS" if not fail else "%d FAILED" % fail)); sys.exit(1 if fail else 0)
main()
