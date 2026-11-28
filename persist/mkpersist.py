#!/usr/bin/env python3
"""mkpersist.py (EX4 persistent system v1, FINALIZE-PLAN B2, Nov 26 2026): the INSTALLED system's kernel.bin + overlay,
built OFF the box from what RUN 20 already booted. NO kernel rebuild, NO image rebuild, nothing downloaded:

  kernel.bin  = the k-ud zImage the bwud bundle carries (bundle-work/split/zImage, pinned)  +  THE INSTALL DTB
                (dts/kirkwood-wd-mycloud-ex4.dts WITHOUT -DEX4_TRIAL + install.dtsi: every partition
                read-only except "image" = mtd3), compiled with the k-ud kernel tree's own cpp include path + its dtc.
  overlay.cpio = the bwud bundle's PROVEN overlay (pinned md5), entry by entry, with the trial's self-return taken out
                (S99 auto-return, S03 deadman-to-stock, the rw bench + K01, /etc/ex4/trial), its 99 uci-default rewritten
                without the late hostname (the cert CN fix), and the persistent system's files added (files/ + the UPS
                watcher from tools/ups-watch, pinned). Every kept entry is byte-identical to the base (checked).

  python3 -I mkpersist.py build --bundle B --zimage Z --linux L --dts D --ups DIR --out OUT
  python3 -I mkpersist.py list CPIO [NAME]

OUT must be NEW and under ~/ex4-build/finalize/. Never writes anything else; never touches a device (any argument naming
/dev is refused). Gates (each a REFUSED): base pins; kernel.bin of the bundle == zImage + its trial DTB (so the join is
the bundle's own); my -DEX4_TRIAL compile is BYTE-IDENTICAL to the bundle's ex4-trial.dtb; the install DTB's
decompile == the trial's (same dtc) minus exactly ONE line, the read-only inside partition@b00000; 7 partitions, 6 read-only, "image"
writable; the size gate (build-v9.sh's formula, k-ud System.map); the overlay gate below. Then feed kernel.bin +
overlay.cpio to build/build-mtd3.py (its default cmdline = the persistent atags: no trial token,
watchdog.open_timeout=120).
"""
import argparse
import hashlib
import os
import re
import stat
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FINALIZE = os.path.expanduser('~/ex4-build/finalize')
PIN = {
    'overlay.cpio': '59abc8d7fae394e295481a7d4ae51105',     # bwud bundle-v9 (RUN 20, 20-l2off-20261118-1720-ud)
    'kernel.bin': '988b393f878f4595be3725b33b8bbe46',       # same bundle
}
ZIMAGE_MD5 = '63329ccba89a66199545d4624144d48e'             # bwud bundle-work/split/zImage (k-ud kernel), md5sum Nov 26
UPS_SH_MD5 = '17197c27c0a7d8ad6397b4c3d96566b2'             # tools/ups-watch/ups_watch.sh (21/21 selftest, Nov 21)
UPS_INIT_MD5 = 'c91106f70496823b992aca341e021883'           # tools/ups-watch/openwrt/ups-watch.init
DROP = ['etc/init.d/ex4-trial', 'etc/rc.d/S99ex4-trial',            # the 20-min auto-return to stock
        'etc/init.d/ex4-deadman', 'etc/rc.d/S03ex4-deadman',        # the S03 deadman to stock
        'usr/sbin/ex4-rwbench', 'etc/init.d/ex4-rwstop', 'etc/rc.d/K01ex4-rwstop',   # the token-gated rw bench
        'etc/ex4/trial',                                            # the web page's trial clock
        'etc/uci-defaults/99-ex4-trial',                            # rewritten as 99-ex4-persist (below)
        'etc/banner.ex4', 'etc/ex4/overlay-stamp']                  # replaced
RC_LINKS = [('etc/rc.d/S04ex4-notgood', 'ex4-notgood'), ('etc/rc.d/S05ex4-persist', 'ex4-persist'),
            ('etc/rc.d/K85ex4-persist', 'ex4-persist'), ('etc/rc.d/S96ex4-svc', 'ex4-svc'),
            ('etc/rc.d/K01ex4-svc', 'ex4-svc'), ('etc/rc.d/S97ex4-persist-seed', 'ex4-persist-seed'),
            ('etc/rc.d/S98ex4-markgood', 'ex4-markgood'), ('etc/rc.d/S99ups-watch', 'ups-watch'),
            ('etc/rc.d/K01ups-watch', 'ups-watch')]
HOSTNAME_LINES = "uci -q set system.@system[0].hostname='ex4-trial'\nuci -q commit system\n"
NOTE_OLD = '(hostname ex4-trial, '
NOTE_NEW = '(hostname by 90_ex4_persist_name before the cert, '
STAMP = b'mkpersist v1 persist=1 secfix=1 keyonly=1 webui=1 rwbench=0 autoreturn=0\n'
SECURITY_LINES = ["grep -q '^root::' /etc/shadow && sed -i 's/^root::/root:*:/' /etc/shadow",
                  "uci -q set dropbear.@dropbear[0].PasswordAuth='off'",
                  "uci -q set dropbear.@dropbear[0].RootPasswordAuth='off'"]
BANNED = [b'ex4-stay', b'rebooting to stock', b'auto-return', b'ex4_rw_wait']   # in any NEW or kept script: refused
PART_RE = re.compile(r'^\s*partition@([0-9a-f]+) \{')


def die(m):
    sys.exit(f"mkpersist: REFUSED: {m}")


def md5b(b):
    return hashlib.md5(b).hexdigest()


def rd(p):
    with open(p, 'rb') as f:
        return f.read()


def newc_parse(d):
    out = []; o = 0
    while True:
        h = d[o:o + 110]
        if h[:6] != b'070701':
            die(f"not a newc cpio at offset {o}")
        f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        mode, fs, ns = f[1], f[6], f[11]
        name = d[o + 110:o + 110 + ns - 1].decode(); o += 110 + ns; o += -o % 4
        data = d[o:o + fs]; o += fs; o += -o % 4
        if name == 'TRAILER!!!':
            return out
        out.append((name, data, mode))


def newc(name, data, mode, ino):
    nb = name.encode() + b'\0'
    h = '070701' + ''.join('%08X' % v for v in (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nb), 0))
    o = h.encode() + nb; o += b'\0' * (-len(o) % 4)
    return o + data + b'\0' * (-len(data) % 4)


def run(log, argv, out=None):
    for a in argv:
        if a.startswith('/dev') or '/dev/' in a:
            die(f"an argument names a device: {a}")
    log.write('$ ' + ' '.join(argv) + (f' > {out}' if out else '') + '\n')
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if out:
        with open(out, 'xb') as f:
            f.write(p.stdout)
    else:
        log.write(p.stdout.decode(errors='replace'))
    log.write(p.stderr.decode(errors='replace') + f'[rc {p.returncode}]\n')
    if p.returncode:
        die(f"{os.path.basename(argv[0])} failed (rc {p.returncode}); see build.log")
    return p.stdout


def dts_parts(text):
    """partition@addr -> (label, has read-only) from a decompiled DTS"""
    parts = {}; cur = None
    for ln in text.splitlines():
        m = PART_RE.match(ln)
        if m:
            cur = m.group(1); parts[cur] = [None, False]; continue
        if cur is not None:
            s = ln.strip()
            if s.startswith('label = '):
                parts[cur][0] = s[len('label = '):].rstrip(';').strip('"')
            elif s == 'read-only;':
                parts[cur][1] = True
            elif s == '};':
                cur = None
    return parts


def c_build(a):
    out = os.path.realpath(a.out)
    if not (out + '/').startswith(os.path.realpath(FINALIZE) + '/'):
        die(f"--out must be under {FINALIZE}/")
    if os.path.exists(out):
        die(f"{out} exists (never overwrite)")
    for p in (a.bundle, a.zimage, a.linux, a.dts, a.ups):
        if '/dev/' in p or p.startswith('/dev'):
            die(f"a path names a device: {p}")
    ov = rd(os.path.join(a.bundle, 'overlay.cpio')); kb = rd(os.path.join(a.bundle, 'kernel.bin')); z = rd(a.zimage)
    if md5b(ov) != PIN['overlay.cpio']: die(f"base overlay.cpio md5 {md5b(ov)} is not the pinned bwud one {PIN['overlay.cpio']}")
    if md5b(kb) != PIN['kernel.bin']: die(f"base kernel.bin md5 {md5b(kb)} is not the pinned bwud one")
    if md5b(z) != ZIMAGE_MD5: die(f"zImage md5 {md5b(z)} is not the pinned k-ud one {ZIMAGE_MD5}")
    trial_dtb = rd(os.path.join(a.bundle, '..', '..', 'bundle-work', 'dts', 'ex4-trial.dtb'))
    if kb != z + trial_dtb: die("the bundle's kernel.bin is not zImage + its ex4-trial.dtb (the join is not the one this tool does)")
    dtc = os.path.join(a.linux, 'scripts', 'dtc', 'dtc')
    for t in (dtc, os.path.join(a.linux, 'System.map'), os.path.join(a.linux, '.config')):
        if not os.path.isfile(t): die(f"missing in the kernel tree: {t}")
    os.makedirs(out); w = os.path.join(out, 'work'); os.makedirs(w)
    log = open(os.path.join(out, 'build.log'), 'w')
    log.write(f"mkpersist.py build: bundle {a.bundle} (overlay {PIN['overlay.cpio']}, kernel.bin {PIN['kernel.bin']}); zImage {a.zimage} {ZIMAGE_MD5}\n"
              f"linux {a.linux} (.config md5 {md5b(rd(os.path.join(a.linux, '.config')))}); dts {a.dts} md5 {md5b(rd(a.dts))}; "
              f"install.dtsi md5 {md5b(rd(os.path.join(HERE, 'install.dtsi')))}; mkpersist.py md5 {md5b(rd(os.path.abspath(__file__)))}\n")

    # ---- 1. THE INSTALL DTB
    inc = ['-I', os.path.join(a.linux, 'arch/arm/boot/dts/marvell'), '-I', os.path.join(a.linux, 'include')]
    cpp = ['cpp', '-nostdinc', '-undef', '-D__DTS__', '-x', 'assembler-with-cpp']
    run(log, cpp + ['-DEX4_TRIAL'] + inc + [a.dts], os.path.join(w, 'trial.pp.dts'))
    run(log, cpp + inc + [a.dts], os.path.join(w, 'install.pp.dts'))
    with open(os.path.join(w, 'install.pp.dts'), 'ab') as f:
        f.write(b'\n' + rd(os.path.join(HERE, 'install.dtsi')))
    for n in ('trial', 'install'):
        run(log, [dtc, '-q', '-I', 'dts', '-O', 'dtb', '-o', os.path.join(w, n + '.dtb'), os.path.join(w, n + '.pp.dts')])
        run(log, [dtc, '-q', '-I', 'dtb', '-O', 'dts', os.path.join(w, n + '.dtb')], os.path.join(w, n + '.decompiled.dts'))
    if rd(os.path.join(w, 'trial.dtb')) != trial_dtb: die("my -DEX4_TRIAL compile is not byte-identical to the bundle's ex4-trial.dtb")
    mine_trial = rd(os.path.join(w, 'trial.decompiled.dts')).decode()     # both decompiled by the SAME dtc (k-ud tree's)
    inst = rd(os.path.join(w, 'install.decompiled.dts')).decode()
    tl, il = mine_trial.splitlines(), inst.splitlines()
    if len(tl) != len(il) + 1: die(f"install DTB: {len(il)} lines vs trial {len(tl)}: want exactly one fewer")
    k = next((i for i in range(len(il)) if tl[i] != il[i]), len(il))
    if tl[k].strip() != 'read-only;' or tl[:k] + tl[k + 1:] != il: die("install DTB is not the trial DTB minus exactly one read-only line")
    owner = None
    for ln in tl[:k]:
        m = PART_RE.match(ln)
        if m: owner = m.group(1)
        elif ln.strip() == '};': pass
    if owner != 'b00000': die(f"the one removed read-only line sits in partition@{owner}, not partition@b00000 (image)")
    parts = dts_parts(inst)
    want = {'0': 'u-boot', '100000': 'uImage', '600000': 'ramdisk', 'b00000': 'image', 'dd00000': 'rescue firmware',
            'ec00000': 'config', 'd800000': 'reserve'}
    if {k2: v[0] for k2, v in parts.items()} != want: die(f"install DTB partitions {parts} are not WD's seven")
    rw = [v[0] for v in parts.values() if not v[1]]
    if rw != ['image']: die(f"install DTB writable partitions = {rw}, want ['image'] only")
    log.write(f"install DTB: 7 partitions, writable: {rw}; trial-path DTB byte-identical to the bundle's (8b1ebc0b); install == trial minus 1 line (partition@b00000 read-only)\n")

    # ---- 2. kernel.bin = zImage + install DTB, + build-v9.sh's size gate
    dtb = rd(os.path.join(w, 'install.dtb'))
    kbin = z + dtb
    with open(os.path.join(out, 'kernel.bin'), 'xb') as f:
        f.write(kbin)
    sm = {}
    for ln in open(os.path.join(a.linux, 'System.map')):
        p = ln.split()
        if len(p) == 3 and p[2] in ('_text', '_end'): sm[p[2]] = int(p[0], 16)
    image = sm['_end'] - sm['_text']; slack = 0x10000 + 0x20000 + 0x10000
    peak = 0x8000 + image + len(kbin) + slack
    gate = f"decompressed image {image} B, kernel.bin {len(kbin)} B, worst-case peak 0x{peak:x}, marker H 0x3000000, overlay 0x4000000, margin {0x3000000 - peak} B"
    log.write('size gate: ' + gate + '\n')
    if peak >= 0x3000000: die("size gate: " + gate)

    # ---- 3. overlay.cpio
    base = newc_parse(ov)
    names = [n for n, _, _ in base]
    for d in DROP:
        if names.count(d) != 1: die(f"the base overlay has {names.count(d)} entries named {d} (want exactly 1)")
    by = {n: (dd, m) for n, dd, m in base}
    t99 = by['etc/uci-defaults/99-ex4-trial'][0].decode()
    if t99.count(HOSTNAME_LINES) != 1 or t99.count(NOTE_OLD) != 1: die("99-ex4-trial is not the text this tool rewrites")
    p99 = t99.replace(HOSTNAME_LINES, '').replace(NOTE_OLD, NOTE_NEW).replace('# ex4 trial: a NAS', '# ex4 persistent system v1 (was 99-ex4-trial, hostname lines moved to 90_ex4_persist_name): a NAS')
    for s in SECURITY_LINES:
        if s not in p99: die(f"99-ex4-persist lost a security line: {s}")
    keep = [(n, dd, m) for n, dd, m in base if n not in DROP]
    have = {n for n, _, _ in keep}
    add = [('etc/uci-defaults/99-ex4-persist', p99.encode(), 0o100755), ('etc/ex4/overlay-stamp', STAMP, 0o100644)]
    fdir = os.path.join(HERE, 'files')
    for r, ds, fs in sorted(os.walk(fdir)):
        ds.sort()
        rel = os.path.relpath(r, fdir)
        if rel != '.':
            parts_ = rel.split('/')
            for i in range(1, len(parts_) + 1):
                dn = '/'.join(parts_[:i])
                if dn not in have and dn not in {x for x, _, _ in add}:
                    add.append((dn, b'', 0o040755 if dn != 'etc/ups-watch' else 0o040700))
        for fn in sorted(fs):
            src = os.path.join(r, fn); name = os.path.relpath(src, fdir)
            st = os.lstat(src)
            if not stat.S_ISREG(st.st_mode): die(f"files/{name} is not a regular file")
            add.append((name, rd(src), 0o100755 if st.st_mode & 0o111 else (0o100600 if name.startswith('etc/ups-watch/') else 0o100644)))
    ups_sh = rd(os.path.join(a.ups, 'ups_watch.sh')); ups_init = rd(os.path.join(a.ups, 'openwrt', 'ups-watch.init'))
    if md5b(ups_sh) != UPS_SH_MD5 or md5b(ups_init) != UPS_INIT_MD5: die("the UPS watcher files are not the pinned ones")
    for dn in ('usr/libexec/ups-watch',):
        add.append((dn, b'', 0o040755))
    add += [('usr/libexec/ups-watch/ups_watch.sh', ups_sh, 0o100755), ('etc/init.d/ups-watch', ups_init, 0o100755)]
    for ln, tgt in RC_LINKS:
        add.append((ln, ('../init.d/' + tgt).encode(), 0o120777))
    an = [n for n, _, _ in add]
    dup = sorted({n for n in an if an.count(n) > 1} | (set(an) & have))
    if dup: die(f"entries named twice: {dup}")
    for ln, tgt in RC_LINKS:
        if 'etc/init.d/' + tgt not in set(an) | have: die(f"{ln} points at a missing init script {tgt}")
    entries = keep + add
    for n, dd, m in entries:
        if stat.S_ISREG(m) and (dd.startswith(b'#!') or n.startswith(('etc/init.d/', 'etc/uci-defaults/', 'etc/rc.d/'))):
            for b in BANNED:
                if b in dd and n not in ('usr/sbin/ex4-selftest',) and not (n == 'usr/share/rpcd/ucode/ex4.uc'):
                    die(f"{n} still carries '{b.decode()}' (the trial's self-return)")
    # kept entries byte-identical
    for n, dd, m in keep:
        if by[n] != (dd, m): die(f"kept entry {n} changed")
    cp = b''.join(newc(n, dd, m, 1000 + i) for i, (n, dd, m) in enumerate(entries)) + newc('TRAILER!!!', b'', 0, 0)
    cp += b'\0' * (-len(cp) % 512)
    with open(os.path.join(out, 'overlay.cpio'), 'xb') as f:
        f.write(cp)
    with open(os.path.join(out, 'OVERLAY-DIFF.txt'), 'x') as f:
        f.write(f"base overlay {PIN['overlay.cpio']} ({len(base)} entries) -> persist overlay {md5b(cp)} ({len(entries)} entries)\n")
        f.write(f"kept byte-identical: {len(keep)}\n")
        for d in DROP: f.write(f"DROPPED  {d}  md5 {md5b(by[d][0])}\n")
        for n, dd, m in add: f.write(f"ADDED    {n}  mode {m:o}  {len(dd)} B  md5 {md5b(dd)}\n")
    log.write(f"overlay.cpio {len(cp)} B md5 {md5b(cp)}: kept {len(keep)}, dropped {len(DROP)}, added {len(add)}\n")
    log.close()
    with open(os.path.join(out, 'MD5SUMS'), 'x') as f:
        for n in ('kernel.bin', 'overlay.cpio', 'work/install.dtb', 'work/install.decompiled.dts', 'OVERLAY-DIFF.txt'):
            f.write(f"{md5b(rd(os.path.join(out, n)))}  {n}\n")
    print(f"built {out}: kernel.bin {len(kbin)} B md5 {md5b(kbin)} (install DTB {md5b(dtb)}, writable: image only); "
          f"overlay.cpio {len(cp)} B md5 {md5b(cp)} (kept {len(keep)}, dropped {len(DROP)}, added {len(add)}); {gate}")


def c_list(a):
    for n, d, m in newc_parse(rd(a.cpio)):
        print(f"{m:06o} {len(d):8d} {md5b(d)} {n}")
        if a.name == n:
            sys.stderr.write(d.decode(errors='replace'))


ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
sp = ap.add_subparsers(dest='cmd', required=True)
s = sp.add_parser('build')
for k in ('--bundle', '--zimage', '--linux', '--dts', '--ups', '--out'):
    s.add_argument(k, required=True)
s.set_defaults(f=c_build)
s = sp.add_parser('list'); s.add_argument('cpio'); s.add_argument('name', nargs='?'); s.set_defaults(f=c_list)
a = ap.parse_args(); a.f(a)
