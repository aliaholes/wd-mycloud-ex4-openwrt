#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""kmod_pick.py: take kernel modules for the EX4 trial out of an OFFICIAL OpenWrt image, and prove they fit the trial kernel.
Off the box; reads files only; never overwrites.

Why: the EX4's USB 3.0 controller (Etron EJ168, PCI 1b6f:7023, class 0c0330) needs xhci-pci, and the image the trial
boots (OpenWrt 25.12.6 kirkwood, iom_ix4-200d initramfs) does not carry it. The SAME release's zyxel_nsa325 initramfs
image does (that NAS has a USB 3 controller too): same target, same kernel build, so the modules are the ones OpenWrt
built for exactly this kernel. No package download is needed, and the image file is one the release's own `sha256sums`
lists (https://downloads.openwrt.org/releases/25.12.6/targets/kirkwood/generic/sha256sums).

  python3 -I kmod_pick.py pick  <donor initramfs uImage> <sha256 it must have> <outdir> NAME...
        NAME = a path inside the donor's initramfs (lib/modules/6.12.112/xhci-pci.ko, etc/modules.d/54-usb3 ...).
        Writes each one under <outdir>/<same path>, byte for byte, plus <outdir>/KMODS.txt (sha256 + modinfo of each).
  python3 -I kmod_pick.py check <kernel.bin of the bundle (zImage + DTB)> <outdir> [--ref <module that loaded on the box>]
                                [--shipped <lib/modules dir of the trial image's own initramfs>]
                                [--source <kernel source tree of the same version>]
        every *.ko under <outdir>: vermagic == the kernel's own vermagic string (and == the reference module's), every
        undefined symbol is exported by another picked module (its __ksymtab_strings) or by that kernel (its name is a
        whole string in the kernel image; or, for names the linker merged into a longer export's string, a module of the
        trial image's own initramfs imports the same symbol, or the kernel source of that version exports it from
        an always-built file), the dependency list is inside the picked set or built in. Prints "KMOD CHECK: PASS" and exits 0, else the reasons and exit 1.
Born Nov 17 2026 (EX4 run 7 prep)."""
import hashlib, lzma, os, struct, sys


def payload(path):
    d = open(path, 'rb').read()
    if d[:4] == b'\x27\x05\x19\x56':
        size = struct.unpack('>I', d[12:16])[0]; d = d[64:64 + size]
    best = None; i = 0
    while True:
        i = d.find(b'\xfd7zXZ\x00', i)
        if i < 0: break
        try:
            o = lzma.LZMADecompressor(lzma.FORMAT_AUTO).decompress(d[i:])
            if best is None or len(o) > len(best): best = o
        except Exception: pass
        i += 1
    if not best or len(best) < 1 << 20: sys.exit("REFUSED: no xz kernel payload in " + path)
    return best


def cpio_entries(img):
    p = img.find(b'070701')
    while p >= 0:
        try:
            int(img[p + 6:p + 110], 16); break
        except ValueError:
            p = img.find(b'070701', p + 1)
    if p < 0: sys.exit("REFUSED: no initramfs archive inside the kernel image")
    out = {}
    while True:
        if img[p:p + 6] != b'070701': sys.exit("REFUSED: initramfs archive is cut at %#x" % p)
        f = [int(img[p + 6 + 8 * i:p + 14 + 8 * i], 16) for i in range(13)]
        ns, fs = f[11], f[6]; name = img[p + 110:p + 110 + ns - 1].decode(); p = (p + 110 + ns + 3) & ~3
        body = img[p:p + fs]; p = (p + fs + 3) & ~3
        if name == 'TRAILER!!!': break
        out[name] = (f[1], body)
    return out


def elf_sections(d):
    if d[:7] != b'\x7fELF\x01\x01\x01' or struct.unpack_from('<H', d, 18)[0] != 40: raise ValueError("not a 32-bit little-endian ARM ELF")
    shoff, = struct.unpack_from('<I', d, 32); shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 46)
    secs = [struct.unpack_from('<IIIIIIIIII', d, shoff + i * shentsize) for i in range(shnum)]
    stro = secs[shstrndx][4]
    return {d[stro + s[0]:d.index(b'\0', stro + s[0])].decode(): s for s in secs}, secs


def modinfo(d):
    S, _ = elf_sections(d)
    s = S['.modinfo']; raw = d[s[4]:s[4] + s[5]]; info = {}
    for kv in raw.split(b'\0'):
        if b'=' in kv:
            k, v = kv.decode('latin1').split('=', 1); info.setdefault(k, []).append(v)
    return info


def symbols(d):
    """(undefined symbols, symbols this module EXPORTS = the names in its __ksymtab_strings section)"""
    S, secs = elf_sections(d)
    st = S['.symtab']; strs = secs[st[6]]; und = set()
    for i in range(1, st[5] // 16):
        name, value, size, inf, other, shndx = struct.unpack_from('<IIIBBH', d, st[4] + 16 * i)
        n = d[strs[4] + name:d.index(b'\0', strs[4] + name)].decode()
        if n and shndx == 0: und.add(n)
    exp = set()
    if '__ksymtab_strings' in S:
        k = S['__ksymtab_strings']; exp = {x.decode() for x in d[k[4]:k[4] + k[5]].split(b'\0') if x}
    return und, exp


_SRC = {}
def exported_in_source(src, name):
    """'kernel/irq/manage.c:1234 EXPORT_SYMBOL(name)' if the kernel source of the same version exports it in a file that is
    always built (kernel/, mm/, lib/, fs/ top level, drivers/base/), else ''"""
    if name in _SRC: return _SRC[name]
    hit = ''
    for top in ('kernel', 'mm', 'lib', 'drivers/base', 'fs'):
        for r, _, fs in os.walk(os.path.join(src, top)):
            for f in fs:
                if not f.endswith('.c'): continue
                p = os.path.join(r, f)
                try: lines = open(p, errors='replace').read().splitlines()
                except OSError: continue
                for i, l in enumerate(lines):
                    if l.strip() in ('EXPORT_SYMBOL(%s);' % name, 'EXPORT_SYMBOL_GPL(%s);' % name):
                        hit = "%s:%d %s" % (os.path.relpath(p, src), i + 1, l.strip()); break
                if hit: break
            if hit: break
        if hit: break
    _SRC[name] = hit
    return hit


def walk(top):
    for r, _, fs in sorted(os.walk(top)):
        for f in sorted(fs):
            yield os.path.join(r, f)


def pick(a):
    donor, want, out, names = a[0], a[1].lower(), a[2], a[3:]
    if os.path.exists(out): sys.exit("REFUSED: %s exists (never overwrite)" % out)
    got = hashlib.sha256(open(donor, 'rb').read()).hexdigest()
    if got != want: sys.exit("REFUSED: %s has sha256 %s, not %s" % (donor, got, want))
    ent = cpio_entries(payload(donor)); lines = ["donor: %s" % os.path.basename(donor), "donor sha256: %s (must be the release's own sha256sums line)" % got]
    for n in names:
        if n not in ent or (ent[n][0] & 0o170000) != 0o100000: sys.exit("REFUSED: %s is not a regular file in the donor's initramfs" % n)
    for n in names:
        dst = os.path.join(out, n); os.makedirs(os.path.dirname(dst), exist_ok=True)
        body = ent[n][1]; open(dst, 'wb').write(body)
        line = "%s  %s  %d bytes" % (hashlib.sha256(body).hexdigest(), n, len(body))
        if n.endswith('.ko'):
            mi = modinfo(body)
            line += "  vermagic=[%s] depends=[%s] alias=[%s]" % (mi.get('vermagic', ['?'])[0], mi.get('depends', [''])[0], ' '.join(mi.get('alias', [])))
        else:
            line += "  content=%r" % body.decode('latin1')
        lines.append(line); print(line)
    open(os.path.join(out, 'KMODS.txt'), 'w').write('\n'.join(lines) + '\n')
    print("picked %d files from %s into %s" % (len(names), donor, out))


def check(a):
    kbin, out = a[0], a[1]; ref = a[a.index('--ref') + 1] if '--ref' in a else None
    shipped = a[a.index('--shipped') + 1] if '--shipped' in a else None
    src = a[a.index('--source') + 1] if '--source' in a else None
    img = payload(kbin); bad = []
    # what this kernel is known to export: every symbol a module of the trial image's OWN initramfs imports (those
    # modules were built with this kernel and several of them loaded on the box in runs 5 and 6)
    known = set()
    if shipped:
        for p in walk(shipped):
            if p.endswith('.ko'): known |= symbols(open(p, 'rb').read())[0]
    kos = [p for p in walk(out) if p.endswith('.ko')]
    if not kos: sys.exit("REFUSED: no .ko under " + out)
    mods = {os.path.basename(p)[:-3].replace('-', '_'): open(p, 'rb').read() for p in kos}
    vms = {n: modinfo(d).get('vermagic', ['?'])[0] for n, d in mods.items()}
    vm = sorted(set(vms.values()))
    if len(vm) != 1: bad.append("the picked modules carry different vermagic strings: %s" % vms)
    kvm = vm[0].encode()
    if img.count(kvm) < 1: bad.append("the kernel image does not hold the vermagic string %r" % vm[0])
    if ref:
        rvm = modinfo(open(ref, 'rb').read()).get('vermagic', ['?'])[0]
        if rvm != vm[0]: bad.append("vermagic %r is not the reference module's %r (%s)" % (vm[0], rvm, ref))
        else: print("vermagic [%s] == %s's (a module that loaded on the box) and is in the kernel image %d time(s)" % (vm[0], os.path.basename(ref), img.count(kvm)))
    allglob = {}
    for n, d in mods.items():
        for g in symbols(d)[1]: allglob.setdefault(g, n)
    builtin = set()
    for n, d in sorted(mods.items()):
        und, _ = symbols(d); miss = []; frm = {}
        for u in sorted(und):
            if u in allglob and allglob[u] != n: frm.setdefault(allglob[u], []).append(u)
            elif img.find(b'\0' + u.encode() + b'\0') >= 0: frm.setdefault('kernel', []).append(u)
            elif u in known and img.find(u.encode() + b'\0') >= 0: frm.setdefault("kernel (its name is the tail of a longer export's string: the linker merges those; a module of the trial image imports it too)", []).append(u)
            elif src and img.find(u.encode() + b'\0') >= 0 and exported_in_source(src, u): frm.setdefault("kernel (tail of a longer export's string; %s)" % exported_in_source(src, u), []).append(u)
            else: miss.append(u)
        deps = [x for x in modinfo(d).get('depends', [''])[0].split(',') if x]
        for dep in deps:
            if dep.replace('-', '_') not in mods:
                if img.find(dep.encode()) < 0: bad.append("%s depends on %s, which is neither picked nor named in the kernel image" % (n, dep))
                else: builtin.add(dep)
        print("%-14s %3d undefined symbols: %s%s; depends=[%s]" % (n, len(und), ', '.join("%d from %s" % (len(v), k) for k, v in sorted(frm.items())), (" MISSING: " + ' '.join(miss)) if miss else '', ','.join(deps)))
        if miss: bad.append("%s needs symbols nobody exports: %s" % (n, ' '.join(miss[:8])))
    if builtin: print("dependencies not picked but named in the kernel image (built in): %s" % ' '.join(sorted(builtin)))
    if bad:
        for b in bad: print("KMOD CHECK: FAIL: " + b)
        sys.exit(1)
    print("KMOD CHECK: PASS (%d modules: %s)" % (len(mods), ' '.join(sorted(mods))))


if len(sys.argv) >= 6 and sys.argv[1] == 'pick': pick(sys.argv[2:])
elif len(sys.argv) >= 4 and sys.argv[1] == 'check': check(sys.argv[2:])
else: sys.exit(__doc__)
