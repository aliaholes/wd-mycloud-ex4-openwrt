#!/usr/bin/env python3
"""mkc4overlay.py (FINALIZE C4, K3 + K4's overlay half, Nov 27 2026): the C4 TEST overlay = persist-v1's overlay 85f498e5 with ONLY
the changes DESIGN-C4.md (cfc3ebd6) §3 names, each one checked here, everything else byte-identical. NEVER a production overlay:
it rides only in a C4 bundle (kernel.bin 988b393f = the TRIAL DTB, every real partition read-only; mkbundle-c4.sh's kernel wall).

  python3 -I mkc4overlay.py build --base OVERLAY --c4files DIR --nandsim KO --k2 DIR --sim IMG --sim-md5 MD5 --tries 1|2
                                  [--markgood normal|never] --label TEXT --out OUT
  python3 -I mkc4overlay.py list CPIO [NAME]

CHANGES vs the base (nothing else may differ; the builder refuses otherwise and writes OVERLAY-DIFF-C4.txt):
  REPLACED (mapped copies, copy wall = exactly these lines differ from persist-v1's own file, which is pinned by md5 first):
    usr/sbin/ex4-persist   `UBI=3; MTDN=3; ...` -> MTDN=7, and attach()'s /proc/mtd name check "image" -> "NAND simulator partition 0",
                           on that same line (AMEND 2, F2) behind THE C4SIM GATE: /tmp/ex4-c4sim.done present and
                           /tmp/ex4-c4sim.refused absent, else "the sim is NOT attached" and MODE ram (no ubiattach, no store write)
    usr/sbin/ex4-markgood  `UBI=3; MTDN=3; ...` -> MTDN=7  (--markgood never: the same line also REACH_N=3 -> REACH_N=999 = bundle-c4d),
                           and (AMEND 2, F2) mark()'s attach line behind the same C4SIM GATE (else NOT marked good, no ubiattach:
                           ex4-notgood then reboots the box to stock at 10 min, the C4d path)
    etc/config/ex4svc      option enabled '1' -> '0'   (SERVICE MODE never assembles md1 in C4: that is C5)
  ADDED: etc/init.d/ex4-c4sim + etc/rc.d/S03ex4-c4sim, etc/init.d/ex4-c4deadman + etc/rc.d/S03ex4-c4deadman (THE C4-ONLY DEADMAN),
    etc/init.d/ex4-c4cap + etc/rc.d/S03ex4-c4cap (AMEND 1, Nov 27 2026: THE ABSOLUTE BOOT CAP, reboot to stock 90 min after boot),
    lib/ex4-c4/{c4sim, nandsim.ko (K1), bin/nandwrite bin/nanddump bin/flash_erase (K2), sim-r1.img.gz [+ sim-r2.img.gz],
    sim.manifest, tries}, etc/ex4/c4-test (one line saying what this overlay is).
THE SIM RANGES: the sim image (whole 128 KiB blocks, at most 1640) is split around bad block 1501: r1 = blocks 0..min(N,1501)-1,
r2 = blocks 1502..N-1 (only when N > 1502); block 1501 is never written (nandwrite -p would skip it and shift). Each range is gzip -9
with mtime 0 (deterministic); sim.manifest holds each range's start, count and md5 of its RAW bytes (c4sim's read-back target).
OUT must be NEW and under ~/ex4-build/finalize/c4/. Nothing outside OUT is written; no device is ever opened (an argument naming /dev
is refused).
"""
import argparse, gzip, hashlib, os, stat, sys

FINALIZE = os.path.expanduser('~/ex4-build/finalize/c4')
PIN = {'base': '85f498e529124931415c745e774e5e90',                      # persist-v1 sys/overlay.cpio (B2, PERSIST-V1.md)
       'usr/sbin/ex4-persist': '2c8eef6132334be0a2df75f4972d41d9',
       'usr/sbin/ex4-markgood': '7ba8bf420feb080e8f93177ed598683d',
       'etc/config/ex4svc': '9cee134d26c1c0bcdfa1f22f48a21338',
       'nandsim.ko': '60723a02dbcc02b727d1bce8e4414c46',                  # K1
       'nandwrite': '5f628c482416750b715f0a7790f97c3c',                   # K2 (mtd-utils-2.3.0 build dir, Nov 18 13:12)
       'nanddump': 'c3fe3d23a28e7d811eea17d23fd112d5',
       'flash_erase': 'fabb81a776964694aa9a4ad3b6a131f0'}
C4FILES = {'lib/ex4-c4/c4sim': 0o100755, 'etc/init.d/ex4-c4sim': 0o100755, 'etc/init.d/ex4-c4deadman': 0o100755,
           'etc/init.d/ex4-c4cap': 0o100755}       # AMEND 1: THE ABSOLUTE BOOT CAP
BLK = 131072; BAD = 1501; NBLK = 1640
# AMEND 2 (F2, Nov 27 2026): THE C4SIM GATE, the head of the mapped attach lines. c4sim writes /tmp/ex4-c4sim.done as its very last act
# and /tmp/ex4-c4sim.refused on any refusal; a refused, crashed or hung c4sim = no .done = the sim is never attached (MODE ram).
GATE = '\t{ [ -e $TMPD/ex4-c4sim.done ] && [ ! -e $TMPD/ex4-c4sim.refused ]; } || { '
GATE_WHY = 'c4sim did not finish clean (no $TMPD/ex4-c4sim.done, or $TMPD/ex4-c4sim.refused is there)'
BANNED = [b'ex4-stay', b'rebooting to stock', b'auto-return', b'ex4_rw_wait']       # mkpersist's list
BANNED_OK = {'etc/init.d/ex4-c4deadman', 'etc/init.d/ex4-c4cap'}   # THE C4-ONLY DEADMAN + THE C4-ONLY BOOT CAP: the only files allowed a way
                                                                   # back to stock (a C4 boot = a bundle go; never in production)


def die(m):
    sys.exit(f"mkc4overlay: REFUSED: {m}")


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


def newc(name, data, mode, ino):         # = mkpersist.py's writer (uid/gid 0, nlink 1, mtime 0)
    nb = name.encode() + b'\0'
    h = '070701' + ''.join('%08X' % v for v in (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nb), 0))
    o = h.encode() + nb; o += b'\0' * (-len(o) % 4)
    return o + data + b'\0' * (-len(data) % 4)


def swap_lines(text, reps, what):
    """reps = [(old_line, new_line)]: each old line must occur EXACTLY once as a whole line; returns the new text + the copy wall."""
    lines = text.split('\n')
    for old, new in reps:
        idx = [i for i, l in enumerate(lines) if l == old]
        if len(idx) != 1:
            die(f"{what}: the line {old!r} occurs {len(idx)} times (want 1)")
        lines[idx[0]] = new
    out = '\n'.join(lines)
    a, b = text.split('\n'), out.split('\n')
    changed = [i + 1 for i, (x, y) in enumerate(zip(a, b)) if x != y]
    if len(a) != len(b) or len(changed) != len(reps):
        die(f"{what}: copy wall: {len(changed)} line(s) differ, want exactly {len(reps)}")
    return out, changed


def c_build(a):
    for v in vars(a).values():
        if isinstance(v, str) and (v.startswith('/dev') or '/dev/' in v):
            die(f"an argument names /dev: {v}")
    out = os.path.abspath(a.out)
    if not out.startswith(FINALIZE + '/'): die(f"--out {out} is not under {FINALIZE}/")
    if os.path.exists(out): die(f"--out {out} exists")
    if a.tries not in ('1', '2'): die("--tries must be 1 or 2")
    base_b = rd(a.base)
    if md5b(base_b) != PIN['base']: die(f"base overlay md5 {md5b(base_b)} is not persist-v1's {PIN['base']}")
    base = newc_parse(base_b)
    names = [n for n, _, _ in base]
    if len(set(names)) != len(names): die("the base overlay names an entry twice")
    by = {n: (d, m) for n, d, m in base}
    for n in ('usr/sbin/ex4-persist', 'usr/sbin/ex4-markgood', 'etc/config/ex4svc'):
        if n not in by or md5b(by[n][0]) != PIN[n]: die(f"base {n} is not persist-v1's {PIN[n]}")
    # ---- the mapped copies (copy wall)
    rep = {}
    p_new, p_ch = swap_lines(by['usr/sbin/ex4-persist'][0].decode(), [
        ('UBI=3; MTDN=3; VID=2048; SAFE_AT=2', 'UBI=3; MTDN=7; VID=2048; SAFE_AT=2'),
        ('\tgrep -q "^mtd$MTDN: [0-9a-f]* [0-9a-f]* \\"image\\"\\$" $PROC/mtd 2>/dev/null || { say "mtd$MTDN is not \\"image\\" in /proc/mtd: no persistence"; return 1; }',
         GATE + 'say "C4: ' + GATE_WHY + ': the sim is NOT attached (AMEND 2): no persistence"; return 1; }; '
         'grep -q "^mtd$MTDN: [0-9a-f]* [0-9a-f]* \\"NAND simulator partition 0\\"\\$" $PROC/mtd 2>/dev/null || { say "mtd$MTDN is not \\"NAND simulator partition 0\\" in /proc/mtd: no persistence"; return 1; }')],
        'ex4-persist')
    rep['usr/sbin/ex4-persist'] = (p_new.encode(), p_ch)
    mg_line = 'UBI=3; MTDN=7; VID=2048; REACH_N=3; REACH_S=10; TRIES_MAX=3' if a.markgood == 'normal' else \
              'UBI=3; MTDN=7; VID=2048; REACH_N=999; REACH_S=10; TRIES_MAX=3'
    m_new, m_ch = swap_lines(by['usr/sbin/ex4-markgood'][0].decode(), [
        ('UBI=3; MTDN=3; VID=2048; REACH_N=3; REACH_S=10; TRIES_MAX=3', mg_line),
        ('\tattached || ubiattach -m $MTDN -d $UBI -O $VID >> $LOG 2>&1 || { say "ubiattach failed: NOT marked good"; return 1; }',
         GATE + 'say "C4: ' + GATE_WHY + ': the sim is NOT attached (AMEND 2): NOT marked good"; return 1; }; '
         'attached || ubiattach -m $MTDN -d $UBI -O $VID >> $LOG 2>&1 || { say "ubiattach failed: NOT marked good"; return 1; }')],
                             'ex4-markgood')
    rep['usr/sbin/ex4-markgood'] = (m_new.encode(), m_ch)
    s_new, s_ch = swap_lines(by['etc/config/ex4svc'][0].decode(), [("\toption enabled '1'", "\toption enabled '0'")], 'ex4svc')
    rep['etc/config/ex4svc'] = (s_new.encode(), s_ch)
    # ---- the K-files
    def pinned(p, key):
        b = rd(p)
        if md5b(b) != PIN[key]: die(f"{p} md5 {md5b(b)} is not {key} {PIN[key]}")
        return b
    add = []
    have = set(names)
    for d in ('lib/ex4-c4', 'lib/ex4-c4/bin'):
        if d in have: die(f"the base already has {d}")
        add.append((d, b'', 0o040755))
    for rel, mode in C4FILES.items():
        p = os.path.join(a.c4files, rel)
        st = os.lstat(p)
        if not stat.S_ISREG(st.st_mode): die(f"{p} is not a regular file")
        add.append((rel, rd(p), mode))
    add.append(('lib/ex4-c4/nandsim.ko', pinned(a.nandsim, 'nandsim.ko'), 0o100644))
    for t in ('nandwrite', 'nanddump', 'flash_erase'):
        add.append((f'lib/ex4-c4/bin/{t}', pinned(os.path.join(a.k2, t), t), 0o100755))
    sim = rd(a.sim)
    if md5b(sim) != a.sim_md5: die(f"--sim md5 {md5b(sim)} != --sim-md5 {a.sim_md5}")
    if not sim or len(sim) % BLK: die(f"--sim is {len(sim)} B: not whole 128 KiB blocks")
    n = len(sim) // BLK
    if n > NBLK: die(f"--sim is {n} blocks, more than the sim's {NBLK}")
    ranges = [('r1', 0, min(n, BAD))]
    if n > BAD + 1:
        ranges.append(('r2', BAD + 1, n - (BAD + 1)))
    man = ''
    for tag, st_, cnt in ranges:
        raw = sim[st_ * BLK:(st_ + cnt) * BLK]
        gz = gzip.compress(raw, compresslevel=9, mtime=0)
        if gzip.decompress(gz) != raw: die(f"{tag}: gzip round trip failed")
        add.append((f'lib/ex4-c4/sim-{tag}.img.gz', gz, 0o100644))
        man += f"{tag} sim-{tag}.img.gz {st_} {cnt} {md5b(raw)}\n"
    add.append(('lib/ex4-c4/sim.manifest', man.encode(), 0o100644))
    add.append(('lib/ex4-c4/tries', (a.tries + '\n').encode(), 0o100644))
    if 'etc/ex4/c4-test' in have: die("the base already has etc/ex4/c4-test")
    add.append(('etc/ex4/c4-test', (f"C4 TEST overlay (never production): {a.label}; base persist-v1 {PIN['base']}; sim {a.sim_md5} "
                                    f"({n} blocks); tries {a.tries}; markgood {a.markgood}\n").encode(), 0o100644))
    for ln, tgt in (('etc/rc.d/S03ex4-c4sim', 'ex4-c4sim'), ('etc/rc.d/S03ex4-c4deadman', 'ex4-c4deadman'), ('etc/rc.d/S03ex4-c4cap', 'ex4-c4cap')):
        if ln in have: die(f"the base already has {ln}")
        add.append((ln, ('../init.d/' + tgt).encode(), 0o120777))
    an = [x for x, _, _ in add]
    if len(set(an)) != len(an) or set(an) & have: die("an added entry is named twice or exists in the base")
    # ---- assemble: base order kept, replaced entries in place, additions at the end
    entries = []
    for nme, d, m in base:
        if nme in rep: entries.append((nme, rep[nme][0], m))
        else: entries.append((nme, d, m))
    entries += add
    for nme, d, m in entries:
        if stat.S_ISREG(m) and (d.startswith(b'#!') or nme.startswith(('etc/init.d/', 'etc/uci-defaults/', 'etc/rc.d/'))):
            for b in BANNED:
                if b in d and nme not in BANNED_OK and nme not in ('usr/sbin/ex4-selftest', 'usr/share/rpcd/ucode/ex4.uc') and nme not in have:
                    die(f"{nme} carries '{b.decode()}'")
    # every base entry not replaced: byte-identical (name, data, mode), same order
    kept = 0
    for (nb, db, mb), (ne, de, me) in zip(base, entries):
        if nb != ne: die(f"order changed at {nb}")
        if nb in rep: continue
        if (db, mb) != (de, me): die(f"kept entry {nb} changed")
        kept += 1
    cp = b''.join(newc(x, d, m, 1000 + i) for i, (x, d, m) in enumerate(entries)) + newc('TRAILER!!!', b'', 0, 0)
    cp += b'\0' * (-len(cp) % 512)
    # re-parse what we wrote: the same entries back
    if newc_parse(cp) != entries: die("the written cpio does not parse back to the same entries")
    os.makedirs(out)
    with open(os.path.join(out, 'overlay.cpio'), 'xb') as f:
        f.write(cp)
    for rel in ('usr/sbin/ex4-persist', 'usr/sbin/ex4-markgood', 'etc/config/ex4svc'):
        with open(os.path.join(out, 'mapped-' + rel.replace('/', '_')), 'xb') as f:
            f.write(rep[rel][0])
    with open(os.path.join(out, 'OVERLAY-DIFF-C4.txt'), 'x') as f:
        f.write(f"base persist-v1 overlay {PIN['base']} ({len(base)} entries) -> C4 TEST overlay {md5b(cp)} ({len(entries)} entries, {len(cp)} B); label {a.label}\n")
        f.write(f"kept byte-identical: {kept}; replaced: {len(rep)}; added: {len(add)}; dropped: 0\n")
        for rel, (d, ch) in rep.items():
            f.write(f"REPLACED {rel}  {PIN[rel]} -> {md5b(d)}  copy wall: lines {ch} differ, nothing else\n")
            ol, nl = by[rel][0].decode().split('\n'), d.decode().split('\n')
            for i in ch:
                f.write(f"    -{i}: {ol[i - 1]}\n    +{i}: {nl[i - 1]}\n")
        for x, d, m in add:
            f.write(f"ADDED    {x}  mode {m:o}  {len(d)} B  md5 {md5b(d)}\n")
        f.write("sim.manifest:\n" + ''.join('    ' + l + '\n' for l in man.strip().split('\n')))
    with open(os.path.join(out, 'MD5SUMS'), 'x') as f:
        for x in sorted(os.listdir(out)):
            if x != 'MD5SUMS':
                f.write(f"{md5b(rd(os.path.join(out, x)))}  {x}\n")
    print(f"built {out}/overlay.cpio {len(cp)} B md5 {md5b(cp)}: {len(entries)} entries (kept {kept}, replaced {len(rep)}, added {len(add)}); "
          f"sim {a.sim_md5} = {n} blocks -> {', '.join(f'{t} {s}+{c}' for t, s, c in ranges)}; tries {a.tries}; markgood {a.markgood}")


def c_list(a):
    for n, d, m in newc_parse(rd(a.cpio)):
        print(f"{m:06o} {len(d):9d} {md5b(d)} {n}")
        if a.name == n:
            sys.stderr.buffer.write(d)


ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
sp = ap.add_subparsers(dest='cmd', required=True)
s = sp.add_parser('build')
for k in ('--base', '--c4files', '--nandsim', '--k2', '--sim', '--sim-md5', '--tries', '--label', '--out'):
    s.add_argument(k, required=True)
s.add_argument('--markgood', choices=('normal', 'never'), default='normal')
s.set_defaults(f=c_build)
s = sp.add_parser('list'); s.add_argument('cpio'); s.add_argument('name', nargs='?'); s.set_defaults(f=c_list)
a = ap.parse_args(); a.f(a)
