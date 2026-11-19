#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""overlay-gate.py: THE OVERLAY GATE (v8; the image reviewer's nit 3; v9: + the read-write bench's reboot paths). A bundle builder calls this on the overlay.cpio it
just made and REFUSES the bundle unless the overlay carries the security fix of Nov 17 2026, so a stale
build/mkoverlay.py can never again ship root's empty password field and a web server open to the LAN.

  python3 -I overlay-gate.py OVERLAY.cpio --pubkey KEY.pub (--webui WEBUI_DIR | --no-webui) (--rwbench FILE | --no-rwbench)
                             [--variant VARIANT] [--kernel-dts DECOMPILED.dts] [--bundle DIR [--ref-kmods KMODS.txt]]

VARIANT (v9.7, build-v9.sh's variant scheme): "stock", or tokens joined with "+" in this order: xoroff · ONE kernel twin of
prof / prof2 (profile twins: never ship) / uaccess / diet / ud / nfsdtrack (bench twins; ud and nfsdtrack v9.8) · nomemcg (the
cgroup_disable=memory boot word; refused with diet and ud, whose kernels have no memory controller). v9.4's stock / xoroff /
prof / xoroff+prof mean what they meant.

Checks (each prints PASS or FAIL; exit 0 only when every one passes):
  - the archive parses as newc to its TRAILER, and no entry is group- or world-writable
  - /etc/ex4/overlay-stamp says "mkoverlay v8 secfix=1 keyonly=1 webui=N" with N matching the flag (+ " rwbench=1"
    with --rwbench)
  - /etc/uci-defaults/99-ex4-trial turns an EMPTY root field into '*' (the exact v7 line) and turns ssh password
    logins off (PasswordAuth + RootPasswordAuth 'off')
  - /etc/dropbear/authorized_keys is exactly the one key of KEY.pub, mode 0600, in a 0700 folder
  - the overlay carries no /etc/shadow and no /etc/passwd of its own
  - --no-webui: 99-ex4-trial pins uhttpd to 127.0.0.1:80 and deletes the HTTPS listener and /ubus
    --webui:    99-ex4-trial does NOT touch uhttpd; every file of webui/FILES is in the overlay byte for byte with its
                mode; 95_ex4_webui removes every rpcd login and sets redirect_https; rpcd's unauthenticated ACL is the
                interface's (no session.login door)
  - (v9) --no-rwbench: no /usr/sbin/ex4-rwbench, no ex4-rwstop, no ex4_rw_wait anywhere (nothing can switch md1
    read-write); --rwbench FILE: /usr/sbin/ex4-rwbench is FILE byte for byte (0755), K01ex4-rwstop -> ../init.d/ex4-rwstop
    (STOP=01, runs the clean stop), and the S99 auto-return and the S03 deadman call ex4_rw_wait before every reboot
  - (v9.4) the KERNEL VARIANT (--variant, default stock): every kernel module in the overlay (lib/modules/*/*.ko, the
    xhci kmods) is ftrace-instrumented (references __gnu_mcount_nc) when the variant names prof or prof2, and NONE is otherwise:
    a PROFILE TWIN's kmods (built with FUNCTION_TRACER; the same vermagic string as stock, so vermagic cannot tell them
    apart) can never ride in a bundle that is not marked PROFILE, and a profile bundle cannot carry stock kmods.
    --kernel-dts (the decompiled DTB of the bundle's kernel.bin): both orion-xor nodes (xor@60800, xor@60900) are
    status "okay" (stock / prof) or status "disabled" (xoroff, PERF-DESIGN-v2 R1 arm X2); that NOTHING ELSE in the DTB
    differs is build-v9.sh's check (it decompiles both DTBs and diffs them).
    (v9.7) the kernel twins uaccess / diet (not instrumented) and nomemcg (kmods and DTB unchanged) are named variants; which
    kernel a twin bundle carries is build-v9.sh's check (the twin's receipt records the md5 of its kernel .config).
  - (v9.8) THE BUNDLE GATE, --bundle DIR (the v95 review's must_fix, the gate half: the overlay-only mode cannot see what the
    finished bundle says it is). OVERLAY must be DIR/overlay.cpio. Then, against --variant:
      VARIANT       DIR/VARIANT absent for "stock"; otherwise present and its first line VARIANT=<variant>; its XOR= line,
                    CMDLINE_ARM= line, "PROFILE TWIN: never ship" line and TWIN= line say the same tokens; a kernel twin's
                    VARIANT carries exactly one kernel-config-md5=<32 hex> line (the twin receipt's md5 of its kernel .config)
      RUNID         one line, <n>-l2off-<stamp> + "-<token>" for each token in order (none for stock)
      atags.bin     exactly one ATAG_CMDLINE, carrying ex4boot_run=<RUNID> and cgroup_disable=memory iff nomemcg
      KMODS.txt     its .ko lines (name + md5) are exactly the overlay's lib/modules/*/*.ko, by md5 (every variant; the
                    diet / ud / prof kmods differ from the default kernel's, so this ties the overlay to the receipt)
      --ref-kmods   (optional: the DEFAULT kernel's bundle KMODS.txt) diet / ud: no .ko md5 in common with it (a JUMP_LABEL
                    rebuild changes every module); stock / xoroff / nomemcg (default kernel): exactly its .ko set
      MD5SUMS       every listed file matches; VARIANT listed iff present
Born Nov 17 2026 (EX4 v8); v9 the same day; v9.4 (the variant checks) the same night; v9.7 (the kernel twins) Nov 18."""
import hashlib
import os
import re
import struct
import sys


def entries(path):
    d = open(path, 'rb').read()
    p, out = 0, {}
    while True:
        if d[p:p + 6] != b'070701':
            sys.exit(f"FAIL  {path} is not a newc archive at byte {p}")
        f = [int(d[p + 6 + 8 * i:p + 14 + 8 * i], 16) for i in range(13)]
        mode, fs, ns = f[1], f[6], f[11]
        name = d[p + 110:p + 110 + ns - 1].decode()
        p = (p + 110 + ns + 3) & ~3
        body = d[p:p + fs]
        p = (p + fs + 3) & ~3
        if name == 'TRAILER!!!':
            return out
        out[name] = (mode, body)


KERNEL_TWINS = ('prof', 'prof2', 'uaccess', 'diet', 'ud', 'nfsdtrack')
NOMEMCG_TWINS = ('diet', 'ud')      # kernels without a memory controller: nomemcg would measure nothing
ORDER = ('xoroff',) + KERNEL_TWINS + ('nomemcg',)


def variant_ok(v):
    """build-v9.sh's variant string: 'stock', or known tokens, each once, in ORDER, at most one kernel twin, no diet+nomemcg."""
    if v == 'stock':
        return True
    toks = v.split('+')
    if not toks or any(t not in ORDER for t in toks) or len(set(toks)) != len(toks):
        return False
    if sum(t in KERNEL_TWINS for t in toks) > 1 or ('nomemcg' in toks and any(t in toks for t in NOMEMCG_TWINS)):
        return False
    return toks == sorted(toks, key=ORDER.index)


def kmods_txt(path):
    """KMODS.txt -> {lib/modules/.../x.ko: md5} (its '<md5>  ./path' lines; the first line is prose)."""
    out = {}
    for line in open(path):
        f = line.split()
        if len(f) == 2 and re.fullmatch(r'[0-9a-f]{32}', f[0]) and f[1].endswith('.ko'):
            out[f[1][2:] if f[1].startswith('./') else f[1]] = f[0]
    return out


def atag_cmdlines(path):
    b = open(path, 'rb').read()
    p, out = 0, []
    while p + 8 <= len(b):
        size, tag = struct.unpack_from('<II', b, p)
        if size == 0:
            break
        if tag == 0x54410009:
            out.append(b[p + 8:p + 4 * size].split(b'\0', 1)[0].decode('utf-8', 'replace'))
        p += 4 * size
    return out


def bundle_checks(bdir, ovl, variant, e, kos, refk, check):
    """v9.8 THE BUNDLE GATE: what the finished bundle says it is must be --variant (see the docstring)."""
    toks = [] if variant == 'stock' else variant.split('+')
    twin = ([t for t in toks if t in KERNEL_TWINS] or [None])[0]
    fp = lambda n: os.path.join(bdir, n)
    check(os.path.realpath(ovl) == os.path.realpath(fp('overlay.cpio')), f"bundle: the gated overlay is the bundle's own overlay.cpio ({ovl})")
    vt = open(fp('VARIANT')).read().splitlines() if os.path.isfile(fp('VARIANT')) else None
    if not toks:
        check(vt is None, f"bundle: variant stock carries no VARIANT file (found: {vt[:1] if vt else None})")
    else:
        check(vt is not None and vt[:1] == ['VARIANT=' + variant], f"bundle: VARIANT's first line is VARIANT={variant}: {vt[:1] if vt is not None else 'NO VARIANT FILE'}")
        vt = vt or []
        xl = [l for l in vt if l.startswith('XOR=') and len(l) <= 7]
        check(xl == ['XOR=' + ('off' if 'xoroff' in toks else 'on')], f"bundle: VARIANT's XOR line matches the variant: {xl}")
        cl = [l.split(':')[0] for l in vt if l.startswith('CMDLINE_ARM=')]
        check(cl == (['CMDLINE_ARM=nomemcg'] if 'nomemcg' in toks else []), f"bundle: VARIANT's CMDLINE_ARM line matches the variant: {cl}")
        pl = vt.count('PROFILE TWIN: never ship')
        check(pl == (1 if twin in ('prof', 'prof2') else 0), f"bundle: 'PROFILE TWIN: never ship' in VARIANT exactly when the twin is a profile twin: {pl}")
        tl = sorted({l.split(':')[0] for l in vt if l.startswith('TWIN=')})
        check(tl == ([] if twin in (None, 'prof') else ['TWIN=' + twin]), f"bundle: VARIANT's TWIN= line names the variant's kernel twin: {tl}")
        if twin is not None:
            km = [l for l in vt if l.startswith('kernel-config-md5=')]
            check(len(km) == 1 and re.fullmatch(r'kernel-config-md5=[0-9a-f]{32}', km[0]) is not None,
                  f"bundle: the kernel twin {twin}'s VARIANT carries one kernel-config-md5=<md5> line (its twin receipt's kernel .config): {km}")
    rid = open(fp('RUNID')).read().split('\n') if os.path.isfile(fp('RUNID')) else ['']
    rid = rid[0] if len(rid) <= 2 and (len(rid) == 1 or rid[1] == '') else None
    suf = ''.join('-' + t for t in toks)
    base = rid[:len(rid) - len(suf)] if rid and rid.endswith(suf) else None
    ok = base is not None and re.fullmatch(r'[0-9]+-l2off-[0-9A-Za-z]+(-[0-9A-Za-z]+)*', base) is not None and base.split('-')[-1] not in ORDER
    check(ok, f"bundle: RUNID {rid!r} is <n>-l2off-<stamp> + {suf!r} (the variant's tokens, nothing else)")
    cls = atag_cmdlines(fp('atags.bin')) if os.path.isfile(fp('atags.bin')) else []
    cw = cls[0].split() if len(cls) == 1 else []
    check(len(cls) == 1 and rid is not None and ('ex4boot_run=' + rid) in cw and ('cgroup_disable=memory' in cw) == ('nomemcg' in toks),
          f"bundle: atags.bin's one command line carries ex4boot_run=<RUNID>{' and cgroup_disable=memory' if 'nomemcg' in toks else ', no cgroup_disable'}: {cls}")
    ov = {n: hashlib.md5(e[n][1]).hexdigest() for n in kos}
    km = kmods_txt(fp('KMODS.txt')) if os.path.isfile(fp('KMODS.txt')) else {}
    check(bool(km) and km == ov, f"bundle: KMODS.txt's .ko lines are exactly the overlay's kernel modules, by md5: {len(km)} listed, {len(ov)} in the overlay, {len(set(km.items()) ^ set(ov.items()))} differ")
    if refk is not None:
        ref = kmods_txt(refk)
        if twin in NOMEMCG_TWINS:
            common = sorted(n for n, m in ov.items() if m in set(ref.values()))
            check(bool(ref) and bool(ov) and not common, f"bundle: --ref-kmods: the {twin} twin's kmods share no md5 with the default kernel's (a JUMP_LABEL rebuild): {common}")
        elif twin is None:
            check(bool(ref) and ov == ref, f"bundle: --ref-kmods: a default-kernel variant carries exactly the default kernel's kmods: {len(set(ov.items()) ^ set(ref.items()))} differ")
        else:
            print(f"INFO  bundle: --ref-kmods: no kmod claim for the {twin} twin (its kmods may be byte-equal to the default kernel's)")
    sums = {}
    if os.path.isfile(fp('MD5SUMS')):
        for line in open(fp('MD5SUMS')):
            f = line.split()
            if len(f) == 2:
                sums[f[1]] = f[0]
    bad = [n for n, m in sums.items() if not os.path.isfile(fp(n)) or hashlib.md5(open(fp(n), 'rb').read()).hexdigest() != m]
    check(bool(sums) and not bad and ('VARIANT' in sums) == os.path.isfile(fp('VARIANT')),
          f"bundle: MD5SUMS: {len(sums)} files, every one matches, VARIANT listed iff present: mismatched {bad}")


def main():
    a = sys.argv[1:]
    if len(a) < 5 or a[1] != '--pubkey':
        sys.exit(__doc__)
    ovl, pub, rest = a[0], a[2], a[3:]
    if rest[:1] == ['--no-webui']:
        webui, rest = None, rest[1:]
    elif rest[:1] == ['--webui'] and len(rest) >= 2:
        webui, rest = rest[1], rest[2:]
    else:
        sys.exit(__doc__)
    if rest[:1] == ['--no-rwbench']:
        rwb, rest = None, rest[1:]
    elif len(rest) >= 2 and rest[0] == '--rwbench':
        rwb, rest = rest[1], rest[2:]
    else:
        sys.exit(__doc__)
    variant, kdts, bdir, refk = 'stock', None, None, None
    while rest:
        if rest[0] == '--variant' and len(rest) >= 2 and variant_ok(rest[1]):
            variant, rest = rest[1], rest[2:]
        elif rest[0] == '--kernel-dts' and len(rest) >= 2:
            kdts, rest = rest[1], rest[2:]
        elif rest[0] == '--bundle' and len(rest) >= 2:
            bdir, rest = rest[1], rest[2:]
        elif rest[0] == '--ref-kmods' and len(rest) >= 2:
            refk, rest = rest[1], rest[2:]
        else:
            sys.exit(__doc__)
    if refk is not None and bdir is None:
        sys.exit(__doc__)
    toks = set(variant.split('+'))
    prof, xoroff = bool(toks & {'prof', 'prof2'}), 'xoroff' in toks
    e = entries(ovl)
    fails = 0

    def check(ok, text):
        nonlocal fails
        print(("PASS  " if ok else "FAIL  ") + text)
        fails += 0 if ok else 1

    def body(n):
        return e.get(n, (0, b''))[1].decode('utf-8', 'replace')

    check(True, f"{ovl}: {len(e)} entries up to the TRAILER")
    loose = [n for n, (m, _) in e.items() if (m & 0o170000) != 0o120000 and m & 0o022]
    check(not loose, f"no entry is group- or world-writable (symlinks aside): {loose[:5]}")
    stamp = body('etc/ex4/overlay-stamp').strip()
    want = 'mkoverlay v8 secfix=1 keyonly=1 webui=%d' % (1 if webui else 0) + (' rwbench=1' if rwb else '')
    check(stamp == want, f"etc/ex4/overlay-stamp is {want!r}: {stamp!r} (an older mkoverlay.py writes none)")
    u = body('etc/uci-defaults/99-ex4-trial')
    check("grep -q '^root::' /etc/shadow && sed -i 's/^root::/root:*:/' /etc/shadow" in u,
          "99-ex4-trial turns an EMPTY root password field into '*' (v7's exact line)")
    check("PasswordAuth='off'" in u and "RootPasswordAuth='off'" in u, "99-ex4-trial turns ssh password logins off (PasswordAuth, RootPasswordAuth)")
    key = open(pub).read().strip()
    ak = e.get('etc/dropbear/authorized_keys')
    check(ak is not None and ak[1].decode().strip() == key and (ak[0] & 0o777) == 0o600,
          "etc/dropbear/authorized_keys is exactly the given key, mode 0600")
    dd = e.get('etc/dropbear')
    check(dd is not None and (dd[0] & 0o777) == 0o700, "etc/dropbear is a 0700 folder")
    check('etc/shadow' not in e and 'etc/passwd' not in e, "the overlay carries no /etc/shadow or /etc/passwd of its own")
    loop = "uci -q add_list uhttpd.main.listen_http='127.0.0.1:80'" in u and 'uci -q delete uhttpd.main.listen_https' in u and 'uci -q delete uhttpd.main.ubus_prefix' in u
    if webui is None:
        check(loop, "no web interface: 99-ex4-trial pins uhttpd to 127.0.0.1:80, no HTTPS listener, no /ubus")
        check('etc/uci-defaults/95_ex4_webui' not in e and 'www-ex4/index.html' not in e, "no web interface file rides in")
    else:
        check(not any(l.lstrip().startswith('uci') and 'uhttpd' in l for l in u.splitlines()),
              "web interface: 99-ex4-trial runs no uci command on uhttpd (it would close the interface's door again)")
        n = bad = 0
        for line in open(os.path.join(webui, 'FILES')):
            if not line.strip() or line.startswith('#'):
                continue
            src, dst, mode = line.rstrip('\n').split('\t')
            got = e.get(dst.lstrip('/'))
            n += 1
            if got is None or got[1] != open(os.path.join(webui, src), 'rb').read() or (got[0] & 0o7777) != int(mode, 8):
                bad += 1
                print(f"      differs or missing: {dst}")
        check(n > 0 and bad == 0, f"web interface: all {n} files of webui/FILES are in the overlay byte for byte, with their modes")
        w = body('etc/uci-defaults/95_ex4_webui')
        check('while uci -q delete rpcd.@login[0]' in w and "redirect_https='1'" in w, "95_ex4_webui removes every rpcd login and makes port 80 redirect")
        un = body('usr/share/rpcd/acl.d/unauthenticated.json')
        check('"login"' not in un and 'setup_claim' in un, "rpcd's unauthenticated ACL is the interface's: no session.login door")
        check('etc/ex4/trial' in e, "etc/ex4/trial (the page's trial clock) is there")
    t99, t03 = body('etc/init.d/ex4-trial'), body('etc/init.d/ex4-deadman')
    if rwb is None:
        check(not any(n in e for n in ('usr/sbin/ex4-rwbench', 'etc/init.d/ex4-rwstop', 'etc/rc.d/K01ex4-rwstop')),
              "no rw bench: no /usr/sbin/ex4-rwbench, no ex4-rwstop (nothing in this overlay can switch md1 read-write)")
        check('ex4_rw_wait' not in t99 + t03, "no rw bench: the reboot paths carry no ex4_rw_wait")
    else:
        rb = e.get('usr/sbin/ex4-rwbench')
        check(rb is not None and rb[1] == open(rwb, 'rb').read() and (rb[0] & 0o777) == 0o755,
              f"rw bench: usr/sbin/ex4-rwbench is {rwb} byte for byte, mode 0755")
        k = e.get('etc/rc.d/K01ex4-rwstop')
        check(k is not None and (k[0] & 0o170000) == 0o120000 and k[1] == b'../init.d/ex4-rwstop', "rw bench: etc/rc.d/K01ex4-rwstop -> ../init.d/ex4-rwstop")
        st = body('etc/init.d/ex4-rwstop')
        check('STOP=01' in st and 'ex4-rwbench stop --for-reboot' in st, "rw bench: ex4-rwstop (STOP=01) runs the clean stop on any procd shutdown")
        check('ex4_rw_wait() {' in t99 and '{ ex4_rw_wait; logger -t ex4-trial' in t99, "rw bench: the S99 auto-return calls ex4_rw_wait before its reboot")
        check('ex4_rw_wait() {' in t03 and '{ ex4_rw_wait; /usr/sbin/ex4log note' in t03 and 'ex4_rw_wait; reboot -f' in t03,
              "rw bench: the S03 deadman calls ex4_rw_wait before reboot AND before reboot -f")
    # v9.4: THE KERNEL VARIANT. The kmods must come from the kernel this bundle is marked as.
    kos = sorted(n for n in e if n.startswith('lib/modules/') and n.endswith('.ko'))
    inst = [n for n in kos if b'__gnu_mcount_nc' in e[n][1]]
    if prof:
        check(bool(kos) and len(inst) == len(kos),
              f"variant {variant}: every kernel module in the overlay is ftrace-instrumented (a PROFILE TWIN's own kmods): {len(inst)} of {len(kos)}")
    else:
        check(not inst, f"variant {variant}: no kernel module in the overlay is ftrace-instrumented (a profile twin's kmods never ride unmarked): {len(inst)} of {len(kos)} {inst[:3]}")
    if kdts is not None:
        t = open(kdts).read()
        want_st = 'disabled' if xoroff else 'okay'
        got = {}
        for n in ('60800', '60900'):
            i = t.find('xor@%s {' % n)
            body = t[i:t.find('\n\t\t};', i)] if i >= 0 else ''
            st = [l.strip() for l in body.splitlines() if l.startswith('\t\t\tstatus = ')]
            got[n] = st[0] if len(st) == 1 and 'marvell,orion-xor' in body else None
        check(all(v == 'status = "%s";' % want_st for v in got.values()),
              f"variant {variant}: both orion-xor nodes of the kernel's DTB are status \"{want_st}\": {got}")
    if bdir is not None:
        bundle_checks(bdir, ovl, variant, e, kos, refk, check)
    print(f"overlay-gate: {'OK' if not fails else 'REFUSED'} ({fails} check(s) failed){' [bundle ' + bdir + ']' if bdir is not None else ''}")
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
