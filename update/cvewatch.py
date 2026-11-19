#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""cvewatch.py: which parts of a SIGNED EX4 release have known holes, and so what needs a rebuild.

  python3 -I update/cvewatch.py --release DIR [--keys DIR] [--map FILE] [--cache DIR] [--out REPORT.json]
                                [--replay DIR | --record DIR] [--kernel-ids N] [--seen FILE | --no-dedupe]

  DIR      holds RELEASE, RELEASE.sig and sbom.cdx.json (mkrelease.py's output; the payload is not needed)
  --keys   folder of usign public keys (*.pub) the release may be signed by (default: update/keys)
  --replay answer every OSV call from files recorded earlier with --record (tests; no network at all)
  --seen   (v9) THE DEDUPE LEDGER: the set of findings (REBUILD / CHECK / NO-FIX-YET per source package, and the
           kernel tag with open CVEs) the last time this watch reported. The SAME set again = "no new finding",
           exit 0, one DEDUPE line; a set that differs in any member = exit 1 as before, and the ledger is rewritten.
           Default: <--cache>/seen-findings.json (so a morning timer files ONE card per new set, not one a day).
           --no-dedupe reports every run as new. Off with --replay unless --seen is given.

Order of work, each step refusing before the next:
 1. RELEASE.sig must be a good ed25519 signature (update/usignpy.py) by a key in --keys; RELEASE must parse.
 2. sbom.cdx.json must have the sha256 and size RELEASE names for it. Nothing in the SBOM is trusted before that.
 3. Every SOURCE package of the SBOM is asked about once, as update/osv-map.json says: userspace as the same
    upstream version in Alpine's data (a PROXY: Alpine's verdict about the upstream version, not OpenWrt's), the
    kernel as the upstream stable tag (v6.12.112) in OSV's GIT data. Two CANARIES (versions with known holes) ride
    in every batch: if either comes back empty, OSV's answer is not trusted and the run is DEGRADED.
 4. Each userspace hit's record is read (cached by id + modified) and re-checked against Alpine's own fixed
    version for that branch:
      REBUILD  the fix is in a newer UPSTREAM version than ours: pull the newer OpenWrt package, rebuild, release.
      CHECK    Alpine fixed it with a patch on the SAME upstream version: does OpenWrt carry that patch?
      (dropped, counted) Alpine's record says our version is not affected.
    The kernel's hits are counted and their ids listed: they are the upstream CVEs open on that stable tag,
    NOT filtered by our kernel config or OpenWrt's patches. Any of them means "rebuild on OpenWrt's next 6.12 bump".
 5. BLIND (OpenWrt's own projects: no OSV ecosystem covers them), UNCHECKED (a source package osv-map.json does
    not name) and OURS (this repository's programs) are printed on every run. A quiet run is not proof of safety.

THE PAYLOAD WALL: the only thing that leaves is the querybatch body {"queries": [{"package": {"name", "ecosystem"},
"version"}]} (+ OSV's own page_token when OSV asks for a next page) and GET /v1/vulns/<id>. No hostname, address,
path, serial, key or file content. --record keeps every body sent, so the test can check the bytes.

Exit: 0 nothing to rebuild (or the same findings as last time, --seen) · 1 REBUILD or CHECK items that are NEW ·
2 REFUSED (signature, hashes, shape) · 3 DEGRADED (OSV failed, a canary was empty, a page cap was hit). Never wired to a timer by this file (see docs/UPDATES.md)."""
import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import usignpy  # noqa: E402

OSV_BATCH = 'https://api.osv.dev/v1/querybatch'
OSV_QUERY = 'https://api.osv.dev/v1/query'
OSV_VULN = 'https://api.osv.dev/v1/vulns/'
UA = 'ex4-cvewatch/1 (python urllib)'
PAGE_CAP = 40
RX_HEX64 = re.compile(r'^[0-9a-f]{64}$')
RX_VULN = re.compile(r'^[A-Za-z0-9._:-]{3,80}$')
ALLOWED_KEYS = {'queries', 'package', 'name', 'ecosystem', 'version', 'page_token'}


class Refused(Exception):
    pass


class Degraded(Exception):
    pass


# ---------------------------------------------------------------- 1 + 2: trust
def parse_release(text):
    """the same grammar as update/box/ex4-update (unknown line = refused)"""
    r = {'files': []}
    lines = text.split('\n')
    if lines[-1] != '' or lines[0] != 'ex4-release 1':
        raise Refused('RELEASE: not format "ex4-release 1" or not LF-terminated')
    single = {'board', 'version', 'serial', 'channel', 'built', 'openwrt', 'kernel', 'payload', 'sbom'}
    optional = {'not-after', 'successor'}      # v9 lines (a v8 release has neither)
    ended = False
    for ln in lines[1:-1]:
        if ended:
            raise Refused('RELEASE: a line after "end"')
        w = ln.split(' ')
        k = w[0]
        if k == 'end' and len(w) == 1:
            ended = True
            continue
        if k in single or k in optional:
            if k in r:
                raise Refused(f'RELEASE: "{k}" twice')
            r[k] = w[1:]
        elif k == 'file':
            r['files'].append(w[1:])
        else:
            raise Refused(f'RELEASE: unknown line "{ln[:40]}"')
    if not ended:
        raise Refused('RELEASE: no "end" line (truncated?)')
    for k in single:
        if k not in r:
            raise Refused(f'RELEASE: no "{k}" line')
    for k in ('payload', 'sbom'):
        if len(r[k]) != 3 or not RX_HEX64.match(r[k][0]) or not r[k][1].isdigit():
            raise Refused(f'RELEASE: bad "{k}" line')
    if 'not-after' in r and (len(r['not-after']) != 2 or not r['not-after'][0].isdigit()):
        raise Refused('RELEASE: bad "not-after" line')
    if 'successor' in r and (len(r['successor']) != 2 or not re.match(r'^[0-9a-f]{16}$', r['successor'][0])
                             or not re.match(r'^[A-Za-z0-9+/]{56}$', r['successor'][1])):
        raise Refused('RELEASE: bad "successor" line')
    if len(r['kernel']) != 3 or r['kernel'][1] != 'vermagic':
        raise Refused('RELEASE: bad "kernel" line')
    if not re.match(r'^[1-9][0-9]{0,9}$', (r['serial'] or [''])[0]):
        raise Refused('RELEASE: bad serial')
    return r


def trust(rdir, keydir):
    rp, sp = os.path.join(rdir, 'RELEASE'), os.path.join(rdir, 'RELEASE.sig')
    if not os.path.isfile(sp):
        raise Refused('no RELEASE.sig: an unsigned release is never read')
    if os.path.getsize(rp) > 65536:
        raise Refused('RELEASE is over 65536 bytes')
    kn_sig, _ = usignpy.read_sig(sp)
    good = None
    for f in sorted(os.listdir(keydir)):
        if f.endswith('.pub'):
            kn, _ = usignpy.read_pub(os.path.join(keydir, f))
            if kn == kn_sig:
                ok, why = usignpy.verify_files(os.path.join(keydir, f), rp, sp)
                if not ok:
                    raise Refused('RELEASE.sig: ' + why)
                good = why
    if not good:
        raise Refused(f'RELEASE.sig is by key {kn_sig.hex()}, which is not in {keydir}')
    rel = parse_release(open(rp, 'rb').read().decode('ascii'))
    sb = os.path.join(rdir, rel['sbom'][2])
    if rel['sbom'][2] != 'sbom.cdx.json' or not os.path.isfile(sb):
        raise Refused('the SBOM RELEASE names is not here')
    data = open(sb, 'rb').read()
    if len(data) != int(rel['sbom'][1]) or hashlib.sha256(data).hexdigest() != rel['sbom'][0]:
        raise Refused('sbom.cdx.json is not the file RELEASE signs for (size or sha256)')
    return rel, json.loads(data), good


# ---------------------------------------------------------------- 3: what to ask
def upstream(v):
    return re.sub(r'-r\d+$', '', v)


def build_queries(sbom, rel, omap):
    groups, ours = {}, []
    for c in sbom.get('components', []):
        p = {q['name']: q['value'] for q in c.get('properties', [])}
        if p.get('openwrt:source-kind', '').startswith('this repository'):
            ours.append(c['name'])
            continue
        groups.setdefault(p.get('openwrt:source-package') or c['name'], []).append(c)
    queries, blind, unchecked = [], [], []
    blindset = set(omap['blind']['names'])
    for src in sorted(groups):
        comps = groups[src]
        if src == 'linux':
            queries.append({'src': 'linux', 'kind': 'kernel', 'ecosystem': 'GIT', 'name': omap['kernel_git'],
                            'version': 'v' + rel['kernel'][0], 'ours': rel['kernel'][0]})
            continue
        if src in blindset:
            blind.append(src)
            continue
        an = omap['alpine_names'].get(src)
        if not an:
            unchecked.append(src)
            continue
        want = omap.get('version_from', {}).get(src)
        pick = next((c for c in comps if c['name'] == (want or src)), None) or sorted(comps, key=lambda c: c['name'])[0]
        ours_v = upstream(pick['version'])
        queries.append({'src': src, 'kind': 'alpine', 'ecosystem': omap['alpine'], 'name': an,
                        'version': ours_v + '-r0', 'ours': ours_v, 'binaries': sorted(c['name'] for c in comps)})
    return queries, sorted(blind), sorted(unchecked), sorted(ours)


def osv_payload(qs, page_token=None):
    """THE PAYLOAD WALL: name, ecosystem, version (and OSV's own page token). Nothing else is ever copied in."""
    if page_token is not None:
        q = qs[0]
        return {'package': {'name': q['name'], 'ecosystem': q['ecosystem']}, 'version': q['version'], 'page_token': page_token}
    return {'queries': [{'package': {'name': q['name'], 'ecosystem': q['ecosystem']}, 'version': q['version']} for q in qs]}


def wall_check(body):
    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k not in ALLOWED_KEYS:
                    raise Refused(f'payload wall: key {k!r} would leave')
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(json.loads(body))


# ---------------------------------------------------------------- the network (or its recording)
class Net:
    def __init__(self, replay=None, record=None, cache=None):
        self.replay, self.record, self.cache = replay, record, cache
        self.sent = []
        if record:
            os.makedirs(record, exist_ok=True)

    def _key(self, method, url, body):
        return hashlib.sha256((method + ' ' + url + '\n').encode() + (body or b'')).hexdigest()[:32]

    def call(self, method, url, body=None):
        if body is not None:
            wall_check(body)
        self.sent.append({'method': method, 'url': url, 'body': body.decode() if body else None})
        k = self._key(method, url, body)
        if self.replay:
            p = os.path.join(self.replay, k + '.json')
            if not os.path.isfile(p):
                raise Degraded(f'replay: no recorded answer for {method} {url}')
            return json.load(open(p))
        err = None
        for i in range(4):
            req = urllib.request.Request(url, data=body, method=method,
                                         headers={'User-Agent': UA, **({'Content-Type': 'application/json'} if body else {})})
            try:
                with urllib.request.urlopen(req, timeout=90) as r:
                    d = json.load(r)
                break
            except urllib.error.HTTPError as e:
                err = f'HTTP {e.code}'
                if e.code not in (429, 500, 502, 503, 504):
                    raise Degraded(f'OSV {method} {url}: {err}')
            except (urllib.error.URLError, OSError, ValueError) as e:
                err = str(e)
            time.sleep(2 << i)
        else:
            raise Degraded(f'OSV {method} {url}: {err}')
        if self.record:
            json.dump(d, open(os.path.join(self.record, k + '.json'), 'w'))
            with open(os.path.join(self.record, 'SENT.jsonl'), 'a') as f:
                f.write(json.dumps(self.sent[-1]) + '\n')
        return d


def ask(net, qs):
    """querybatch, then every next page OSV asks for -> {index: [ {id, modified} ]}"""
    out = {}
    for start in range(0, len(qs), 500):
        chunk = qs[start:start + 500]
        d = net.call('POST', OSV_BATCH, json.dumps(osv_payload(chunk)).encode())
        res = d.get('results')
        if not isinstance(res, list) or len(res) != len(chunk):
            raise Degraded('OSV querybatch answered the wrong shape')
        for i, r in enumerate(res):
            hits = list(r.get('vulns') or [])
            tok, pages = r.get('next_page_token'), 0
            while tok:
                pages += 1
                if pages > PAGE_CAP:
                    raise Degraded(f'page cap hit for {chunk[i]["name"]} {chunk[i]["version"]}')
                p = net.call('POST', OSV_QUERY, json.dumps(osv_payload([chunk[i]], tok)).encode())
                hits += list(p.get('vulns') or [])
                tok = p.get('next_page_token')
            seen, uniq = set(), []
            for h in hits:
                if isinstance(h, dict) and RX_VULN.match(str(h.get('id', ''))) and h['id'] not in seen:
                    seen.add(h['id']); uniq.append(h)
            out[start + i] = uniq
    return out


def record_of(net, vid, modified, cache):
    if cache:
        p = os.path.join(cache, re.sub(r'[^A-Za-z0-9._-]', '_', vid) + '.json')
        if os.path.isfile(p):
            d = json.load(open(p))
            if d.get('modified') == modified:
                return d
    d = net.call('GET', OSV_VULN + vid)
    if cache:
        os.makedirs(cache, exist_ok=True)
        json.dump(d, open(p, 'w'))
    return d


# ---------------------------------------------------------------- 4: classify
def vtok(v):
    return [(0, int(t)) if t.isdigit() else (1, t) for t in re.findall(r'\d+|[a-z]+', v.lower())]


def vcmp(a, b):
    """upstream-version order good enough for 1.2.10 > 1.2.9, 3.0.5 > 3.0.5_rc1 is NOT modelled (say so: CHECK)"""
    ta, tb = vtok(a), vtok(b)
    return (ta > tb) - (ta < tb)


def classify(rec, q):
    """-> (class, fixed_version) using Alpine's affected[] entry for OUR branch + name"""
    for a in rec.get('affected', []):
        pk = a.get('package', {})
        if pk.get('ecosystem') != q['ecosystem'] or pk.get('name') != q['name']:
            continue
        fixed = None
        for rg in a.get('ranges', []):
            for ev in rg.get('events', []):
                if 'fixed' in ev:
                    fixed = ev['fixed']
        if fixed is None:
            return 'NO-FIX-YET', None
        fu = upstream(fixed)
        if vcmp(fu, q['ours']) > 0:
            return 'REBUILD', fixed
        if vcmp(fu, q['ours']) == 0:
            return 'CHECK', fixed
        return 'dropped', fixed
    return 'CHECK', None      # OSV matched but the record has no entry for our branch: a human looks


def severity(rec):
    for s in rec.get('severity', []) or []:
        if s.get('score'):
            return s['score'][:60]
    ds = rec.get('database_specific') or {}
    return str(ds.get('severity') or '')[:20]


def run(a):
    omap = json.load(open(a.map))
    rel, sbom, why = trust(a.release, a.keys)
    queries, blind, unchecked, ours = build_queries(sbom, rel, omap)
    net = Net(replay=a.replay, record=a.record)
    canaries = [{'src': 'CANARY', 'kind': 'canary', **c} for c in omap['canaries']]
    allq = queries + canaries
    hits = ask(net, allq)
    for i, c in enumerate(canaries):
        if not hits.get(len(queries) + i):
            raise Degraded(f'canary empty ({c["why"]}): OSV\'s answer is not trusted')
    report = {'release': {'version': rel['version'][0], 'serial': rel['serial'][0], 'board': rel['board'][0],
                          'openwrt': ' '.join(rel['openwrt']), 'kernel': rel['kernel'][0], 'vermagic': rel['kernel'][2],
                          'signature': why}, 'items': [], 'kernel': None, 'blind': blind, 'unchecked': unchecked,
              'ours': ours, 'asked': len(queries), 'dropped': 0, 'osv_calls': 0}
    for i, q in enumerate(queries):
        hs = hits.get(i, [])
        if q['kind'] == 'kernel':
            ids = sorted(h['id'] for h in hs)
            report['kernel'] = {'tag': q['version'], 'open_upstream_cves': len(ids), 'ids': ids[:a.kernel_ids]}
            continue
        for h in hs:
            rec = record_of(net, h['id'], h.get('modified'), a.cache)
            cls, fixed = classify(rec, q)
            if cls == 'dropped':
                report['dropped'] += 1
                continue
            cves = [x for x in (rec.get('upstream') or rec.get('aliases') or []) if x.startswith('CVE-')]
            report['items'].append({'class': cls, 'src': q['src'], 'ours': q['ours'], 'fixed_in_alpine': fixed,
                                    'id': h['id'], 'cves': cves, 'severity': severity(rec),
                                    'summary': (rec.get('summary') or rec.get('details') or '')[:160].replace('\n', ' ')})
    report['osv_calls'] = len(net.sent)
    return report


def show(r):
    rl = r['release']
    print(f"release {rl['version']} (serial {rl['serial']}, {rl['board']}), OpenWrt {rl['openwrt']}, kernel {rl['kernel']}")
    print(f"signature: {rl['signature']}; SBOM hash matches RELEASE")
    order = {'REBUILD': 0, 'NO-FIX-YET': 1, 'CHECK': 2}
    items = sorted(r['items'], key=lambda x: (order.get(x['class'], 9), x['src'], x['id']))
    for it in items:
        fx = f"fixed in Alpine {it['fixed_in_alpine']}" if it['fixed_in_alpine'] else 'no fix in Alpine yet'
        print(f"{it['class']:<10} {it['src']} {it['ours']}: {','.join(it['cves']) or it['id']} ({fx}) {it['severity']}")
    k = r['kernel']
    if k:
        print(f"KERNEL     linux {k['tag']}: {k['open_upstream_cves']} upstream CVEs open on this stable tag (OSV GIT data; "
              f"NOT filtered by our config or OpenWrt's patches): rebuild on OpenWrt's next 6.12 bump")
    print(f"asked {r['asked']} source packages in {r['osv_calls']} OSV calls; {r['dropped']} hit(s) dropped "
          f"(Alpine says our version is not affected)")
    print(f"BLIND      {len(r['blind'])} OpenWrt-own (no OSV coverage; watch openwrt.org/advisory): {' '.join(r['blind'])}")
    print(f"UNCHECKED  {len(r['unchecked'])}: {' '.join(r['unchecked']) or 'none'}")
    print(f"OURS       {len(r['ours'])} (this repository's programs; no OSV entry): {' '.join(r['ours'])}")
    need = [it for it in items if it['class'] in ('REBUILD', 'CHECK', 'NO-FIX-YET')]
    reb = sorted({it['src'] for it in items if it['class'] == 'REBUILD'})
    print('VERDICT    ' + (f"REBUILD needed for: {' '.join(reb)}" if reb else 'no REBUILD item')
          + (f"; {len(need) - sum(1 for i in items if i['class'] == 'REBUILD')} CHECK/NO-FIX item(s) for a human" if need else '')
          + ('; kernel: rebuild when OpenWrt bumps 6.12' if k and k['open_upstream_cves'] else ''))
    return 1 if need or (k and k['open_upstream_cves']) else 0


def findings(r):
    """the set the dedupe ledger compares: one member per (class, source package), and the kernel tag when it has
    open upstream CVEs. Ids and counts inside a class do not make a finding new; a new class or package does."""
    f = sorted({f"{it['class']}:{it['src']}" for it in r['items'] if it['class'] in ('REBUILD', 'CHECK', 'NO-FIX-YET')})
    k = r['kernel']
    if k and k['open_upstream_cves']:
        f.append(f"KERNEL:{k['tag']}")
    return f


def dedupe(seen, r):
    """-> (new?, why). Rewrites the ledger only when the set is new."""
    import datetime
    f = findings(r)
    key = hashlib.sha256('\n'.join(f).encode()).hexdigest()
    old = None
    if os.path.isfile(seen):
        try:
            old = json.load(open(seen))
        except (ValueError, OSError):
            old = None
    if old and old.get('key') == key:
        return False, (f"same {len(f)} finding(s) as first reported {old.get('first', '?')} "
                       f"(release {old.get('release', '?')}): no new card")
    os.makedirs(os.path.dirname(os.path.abspath(seen)), exist_ok=True)
    t = seen + '.new'
    json.dump({'key': key, 'set': f, 'release': r['release']['version'], 'serial': r['release']['serial'],
               'first': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}, open(t, 'w'), indent=1)
    os.replace(t, seen)
    gone = sorted(set((old or {}).get('set', [])) - set(f))
    added = sorted(set(f) - set((old or {}).get('set', [])))
    return True, f"new finding(s): {' '.join(added) or '-'}; gone since the last report: {' '.join(gone) or '-'}"


def main():
    ap = argparse.ArgumentParser(description='EX4 release CVE watch (see the header)')
    ap.add_argument('--release', required=True)
    ap.add_argument('--keys', default=os.path.join(HERE, 'keys'))
    ap.add_argument('--map', default=os.path.join(HERE, 'osv-map.json'))
    ap.add_argument('--cache', default=os.path.expanduser('~/.cache/ex4-cvewatch'))
    ap.add_argument('--out')
    ap.add_argument('--kernel-ids', type=int, default=50)
    g = ap.add_mutually_exclusive_group()
    g.add_argument('--replay')
    g.add_argument('--record')
    d = ap.add_mutually_exclusive_group()
    d.add_argument('--seen')
    d.add_argument('--no-dedupe', action='store_true')
    a = ap.parse_args()
    if a.replay:
        a.cache = None
    if a.seen is None and not a.no_dedupe and a.cache:
        a.seen = os.path.join(a.cache, 'seen-findings.json')
    try:
        r = run(a)
    except Refused as e:
        print(f'cvewatch: REFUSED: {e}')
        return 2
    except (usignpy.UsignError, UnicodeDecodeError, ValueError, OSError) as e:
        print(f'cvewatch: REFUSED: {e}')
        return 2
    except Degraded as e:
        print(f'cvewatch: DEGRADED: {e}')
        return 3
    rc = show(r)
    if rc == 1 and a.seen:
        new, why = dedupe(a.seen, r)
        print(('NEW        ' if new else 'DEDUPE     ') + why)
        if not new:
            rc = 0
    elif rc == 0 and a.seen:
        dedupe(a.seen, r)          # an empty set is recorded too: a finding that comes back later is new again
    if a.out:
        if os.path.exists(a.out):
            print(f'cvewatch: {a.out} exists, report not written')
            return 3
        json.dump(r, open(a.out, 'w'), indent=1)
    return rc


if __name__ == '__main__':
    sys.exit(main())
