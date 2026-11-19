#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# tests/build/fragment-union-test.sh : THE UNION RULE of build/v9/kernel-config.ud.fragment (v9.8). The ud twin is uaccess + diet +
# nfsdtrack and nothing else, so a later edit of one source fragment that is not carried into ud (or a line ud gains on its own)
# is a FAIL here, before any build. Checks: KSTRICT in all four; ud's OWRT / KCFG / OMAY / KMAY lines == the union of the three
# sources' (as sets, exact text); ud's KWANT == the sources' KWANT with the three "is not set" lines that name another twin's
# mark removed, + UACCESS_WITH_MEMCPY=y + NFSD_LEGACY_CLIENT_TRACKING=y; no symbol set two ways; every line a known kind; and
# nfsdtrack is exactly its one KCFG line. Needs: sh, python3. Exit 0 only if every case passes.
#   sh tests/build/fragment-union-test.sh [FRAGDIR]     (default build/v9; another folder = a negative check of the test itself)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd)
python3 -I - "${1:-$TOP/build/v9}" <<'PY'
import os, re, sys
d = sys.argv[1]; passed = failed = 0
def check(ok, text):
    global passed, failed
    print(("PASS  " if ok else "FAIL  ") + text)
    passed += ok; failed += not ok
def lines(n):
    return [l.rstrip('\n') for l in open(os.path.join(d, 'kernel-config.%s.fragment' % n)) if l.strip() and not l.startswith('#')]
def kind(ls, k):
    return {l for l in ls if l.split(' ', 1)[0] == k}
F = {n: lines(n) for n in ('uaccess', 'diet', 'nfsdtrack', 'ud')}
for n, ls in F.items():
    bad = [l for l in ls if not re.fullmatch(r'(OWRT|KCFG|OMAY|KMAY|KWANT) \S.*|KSTRICT yes', l)]
    check(not bad, f"{n}: every line is OWRT / KCFG / OMAY / KMAY / KWANT / KSTRICT yes: {bad}")
    check('KSTRICT yes' in ls, f"{n}: KSTRICT yes (the built kernel may differ from v9's only in named symbols)")
    check(len(ls) == len(set(ls)), f"{n}: no line twice: {[l for l in ls if ls.count(l) > 1][:3]}")
for k in ('OWRT', 'KCFG', 'OMAY', 'KMAY'):
    want = kind(F['uaccess'], k) | kind(F['diet'], k) | kind(F['nfsdtrack'], k)
    got = kind(F['ud'], k)
    check(got == want, f"ud: its {k} lines are exactly the union of uaccess + diet + nfsdtrack ({len(got)} vs {len(want)}): missing {sorted(want - got)[:4]}, extra {sorted(got - want)[:4]}")
marks_off = {'KWANT # CONFIG_UACCESS_WITH_MEMCPY is not set', 'KWANT # CONFIG_JUMP_LABEL is not set'}
want = (kind(F['uaccess'], 'KWANT') | kind(F['diet'], 'KWANT') | kind(F['nfsdtrack'], 'KWANT')) - marks_off
got = kind(F['ud'], 'KWANT')
check(got == want, f"ud: KWANT = the sources' minus the other twins' 'is not set' marks ({len(got)} vs {len(want)}): missing {sorted(want - got)}, extra {sorted(got - want)}")
for m in ('KWANT CONFIG_UACCESS_WITH_MEMCPY=y', 'KWANT CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y', 'KWANT CONFIG_JUMP_LABEL=y', 'KWANT # CONFIG_MEMCG is not set'):
    check(m in got, f"ud: {m[6:]} is wanted (one of the ud kernel's marks for build-v9.sh's kernel_kind)")
def sym(l):
    s = l.split(' ', 1)[1]
    return re.sub(r'^# ', '', s).split('=')[0].split(' ')[0].replace('CONFIG_KERNEL_', 'CONFIG_')
sets = {}
for l in kind(F['ud'], 'OWRT') | kind(F['ud'], 'KCFG') | kind(F['ud'], 'KWANT'):
    sets.setdefault(sym(l), set()).add(l.split(' ', 1)[1].replace('CONFIG_KERNEL_', 'CONFIG_'))
two = {s: v for s, v in sets.items() if len(v) > 1}
check(not two, f"ud: no symbol is set or wanted two ways: {two}")
check(F['nfsdtrack'] == ['KSTRICT yes', 'KCFG CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y', 'KWANT CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y',
                         'KWANT # CONFIG_UACCESS_WITH_MEMCPY is not set', 'KWANT # CONFIG_JUMP_LABEL is not set'],
      f"nfsdtrack: the default config + that ONE line (its KWANT also pins the default kernel's other marks): {F['nfsdtrack']}")
print(f"fragment-union-test: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
