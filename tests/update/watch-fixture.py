#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""watch-fixture.py: update/cvewatch.py's logic against a FAKE OSV (no network): the classes, the canaries, the page
cap, the payload wall. Called by tests/update/run.sh with the update/ folder and the run's work folder (whose
rel-good is a real signed test release with a real SBOM).   python3 -I watch-fixture.py UPDATE_DIR WORK_DIR"""
import json
import os
import sys
import types

U, W = sys.argv[1], sys.argv[2]
sys.path.insert(0, U)
import cvewatch  # noqa: E402

FAILS = 0


def check(cond, what):
    global FAILS
    FAILS += not cond
    print(('PASS  ' if cond else 'FAIL  ') + 'cvewatch fixture: ' + what)


def rec(vid, eco, name, fixed, cve):
    ev = [{'introduced': '0'}] + ([{'fixed': fixed}] if fixed else [])
    return {'id': vid, 'modified': 'm1', 'upstream': [cve], 'summary': 'fixture ' + vid,
            'affected': [{'package': {'ecosystem': eco, 'name': name}, 'ranges': [{'type': 'ECOSYSTEM', 'events': ev}]}]}


class FakeNet:
    def __init__(self, answers, recs, canary_empty=False, endless=False):
        self.answers, self.recs, self.sent = answers, recs, []
        self.canary_empty, self.endless = canary_empty, endless

    def call(self, method, url, body=None):
        if body is not None:
            cvewatch.wall_check(body)
        self.sent.append((method, url, body))
        if method == 'GET':
            return self.recs[url.rsplit('/', 1)[1]]
        d = json.loads(body)
        if 'page_token' in d:
            return {'vulns': [{'id': 'CVE-2099-%04d' % len(self.sent), 'modified': 'm'}], 'next_page_token': 'more' if self.endless else None}
        out = []
        for q in d['queries']:
            k = (q['package']['ecosystem'], q['package']['name'])
            if q['version'] in ('1.36.0-r0', 'v6.12.1'):
                out.append({} if self.canary_empty else {'vulns': [{'id': 'CANARY-1', 'modified': 'm'}]})
            elif k[0] == 'GIT':
                out.append({'vulns': [{'id': 'CVE-2026-0001', 'modified': 'm'}, {'id': 'CVE-2026-0002', 'modified': 'm'}],
                            'next_page_token': 'p2'})
            else:
                out.append({'vulns': [{'id': i, 'modified': 'm1'} for i in self.answers.get(k[1], [])]})
        return {'results': out}


def run(net):
    a = types.SimpleNamespace(release=os.path.join(W, 'rel-good'), keys=os.path.join(W, 'keys'),
                              map=os.path.join(U, 'osv-map.json'), replay=None, record=None, cache=None, kernel_ids=5)
    orig = cvewatch.Net
    cvewatch.Net = lambda **kw: net
    try:
        return cvewatch.run(a)
    finally:
        cvewatch.Net = orig


eco = json.load(open(os.path.join(U, 'osv-map.json')))['alpine']
recs = {'A-REBUILD': rec('A-REBUILD', eco, 'busybox', '1.38.0-r0', 'CVE-2026-1111'),
        'A-CHECK': rec('A-CHECK', eco, 'busybox', '1.37.0-r20', 'CVE-2026-2222'),
        'A-OLD': rec('A-OLD', eco, 'busybox', '1.30.0-r0', 'CVE-2019-3333'),
        'A-NOFIX': rec('A-NOFIX', eco, 'dropbear', None, 'CVE-2026-4444'),
        'A-OTHERBRANCH': rec('A-OTHERBRANCH', 'Alpine:v3.19', 'samba', '9.0.0-r0', 'CVE-2026-5555')}
answers = {'busybox': ['A-REBUILD', 'A-CHECK', 'A-OLD'], 'dropbear': ['A-NOFIX'], 'samba': ['A-OTHERBRANCH']}
net = FakeNet(answers, recs)
r = run(net)
cls = {(i['src'], i['id']): i['class'] for i in r['items']}
check(cls.get(('busybox', 'A-REBUILD')) == 'REBUILD', 'fixed in a newer upstream (1.38.0) -> REBUILD')
check(cls.get(('busybox', 'A-CHECK')) == 'CHECK', 'fixed by an Alpine patch on our upstream (1.37.0-r20) -> CHECK')
check(('busybox', 'A-OLD') not in cls and r['dropped'] == 1, 'fixed long before our version -> dropped and counted')
check(cls.get(('dropbear', 'A-NOFIX')) == 'NO-FIX-YET', 'no fix event -> NO-FIX-YET')
check(cls.get(('samba4', 'A-OTHERBRANCH')) == 'CHECK', 'a hit whose record has no entry for our branch -> CHECK (a human looks)')
check(r['kernel'] and r['kernel']['tag'] == 'v6.12.112' and r['kernel']['open_upstream_cves'] == 3,
      'the kernel is asked as GIT tag v6.12.112, every page followed (2 + 1 = %s ids)' % (r['kernel'] or {}).get('open_upstream_cves'))
check('uhttpd' in r['blind'] and 'usign' in r['blind'] and not r['unchecked'], 'OpenWrt-own projects listed BLIND; nothing UNCHECKED (%d blind)' % len(r['blind']))
bodies = [json.loads(b) for m, u, b in net.sent if b]
names = {q['package']['name'] for b in bodies for q in b.get('queries', [])}
check({'busybox', 'samba', 'nfs-utils', 'openssl', 'musl'} <= names, 'source packages asked by their Alpine names (samba4 -> samba, nfs-kernel-server -> nfs-utils, toolchain -> musl)')
check(all(set(q) <= {'package', 'version'} and set(q['package']) == {'name', 'ecosystem'} for b in bodies for q in b.get('queries', [])),
      'every query is {package: {name, ecosystem}, version}, nothing else')
try:
    run(FakeNet(answers, recs, canary_empty=True))
    check(False, 'an empty canary -> DEGRADED')
except cvewatch.Degraded as e:
    check('canary' in str(e), 'an empty canary -> DEGRADED, OSV not trusted')
try:
    run(FakeNet(answers, recs, endless=True))
    check(False, 'endless pages -> DEGRADED at the page cap')
except cvewatch.Degraded as e:
    check('page cap' in str(e), 'endless next_page_token -> DEGRADED at the page cap (%d pages)' % cvewatch.PAGE_CAP)
try:
    cvewatch.wall_check(json.dumps({'queries': [{'package': {'name': 'x', 'ecosystem': 'y'}, 'version': '1', 'hostname': 'ex4'}]}).encode())
    check(False, 'the payload wall refuses an extra key')
except cvewatch.Refused:
    check(True, 'the payload wall refuses a body with any other key (hostname)')
# v9: THE DEDUPE LEDGER (the review's nit 5): the same set of findings again = no new card; a change in the set = new
import copy
seen = os.path.join(W, 'seen-findings.json')
if os.path.exists(seen):
    os.unlink(seen)
new1, why1 = cvewatch.dedupe(seen, r)
check(new1 and os.path.isfile(seen), 'dedupe: the first report of a set is NEW and lands in the ledger (%s)' % why1[:80])
new2, why2 = cvewatch.dedupe(seen, r)
check(not new2 and 'no new card' in why2, 'dedupe: the SAME set the next morning is not new (%s)' % why2[:90])
new3, _ = cvewatch.dedupe(seen, copy.deepcopy(r))
check(not new3, 'dedupe: a new id inside a class already reported does not make the set new')
r3 = copy.deepcopy(r); r3['items'].append({'class': 'REBUILD', 'src': 'zlib', 'ours': '1.3', 'fixed_in_alpine': '1.4', 'id': 'A-ZLIB', 'cves': [], 'severity': '', 'summary': ''})
new4, why4 = cvewatch.dedupe(seen, r3)
check(new4 and 'REBUILD:zlib' in why4, 'dedupe: a NEW package needing a rebuild makes the set new (%s)' % why4[:80])
r4 = copy.deepcopy(r3); r4['items'] = [i for i in r4['items'] if i['src'] != 'zlib']
new5, why5 = cvewatch.dedupe(seen, r4)
check(new5 and 'gone since the last report: REBUILD:zlib' in why5, 'dedupe: a package that DROPPED out also counts as a change, and says what went')
check(sorted(cvewatch.findings(r)) == sorted(set(cvewatch.findings(r))) and 'KERNEL:v6.12.112' in cvewatch.findings(r), 'dedupe: the set is one member per (class, package) + the kernel tag')
sys.exit(1 if FAILS else 0)
