#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""mkrelease.py: turn one finished build (the OpenWrt tree of build/v7/build-v7.sh + its bundle) into a SIGNED,
VERSIONED release: a payload tarball, a CycloneDX SBOM with every package's name, version, binary hash and source
hash, and a small text manifest (RELEASE) that names the hash of everything else, signed with our ed25519 key by
OpenWrt's own usign. The box (update/box/ex4-update) and the CVE watch (update/cvewatch.py) trust nothing but
RELEASE + RELEASE.sig + the public key the image ships.

  python3 -I update/mkrelease.py sbom    --work W --built ISO8601 --out sbom.cdx.json [--bundle B]
  python3 -I update/mkrelease.py ident   --version V --serial N --openwrt REL --kernel KVER [--channel C] --out FILE
                                         (/etc/ex4-release for the image: written BEFORE the image is built; the board
                                         is the DTS's own compatible)
  python3 -I update/mkrelease.py release --work W --bundle B --version V --serial N --key SEC --pub PUB
                                         --usign USIGN --out DIR [--channel trial|stable] [--built ISO8601]
                                         [--valid-days D] [--successor NEXT.pub] [--allow-test-key]

  W      the build's work folder (W/openwrt = the OpenWrt tree that made the image; ONLY READ)
  B      the bundle folder build-v7.sh wrote (ONLY READ; its MD5SUMS must check). (v9.7) A bundle that carries a VARIANT
         file (on disk or named in MD5SUMS: build-v9.sh's EX4_XOR=off / EX4_PROFILE=1 / EX4_CMDLINE_ARM bench arms) is
         REFUSED: those are bench-only kernels; a release is only ever built from a default bundle.
  V      a version label: [0-9A-Za-z.+-]{1,40}, e.g. 2026.11.17-v7
  N      the serial: a whole number, 1..9999999999. The box refuses any release whose serial is not GREATER than the
         serial it runs (that is the downgrade wall), so a new release always takes a bigger one (YYYYMMDDNN works).
  SEC    the private key (usign -G). It must be mode 0600, outside this repository, and its public half must be
         update/keys/ex4-release.pub (the key the image ships) unless --allow-test-key (tests only: the release then
         says "channel test": a box accepts only its own channel, and only keys in its own key folder).
  USIGN  OpenWrt's host usign (staging_dir/host/bin/usign of the same tree), used to SIGN; the result is verified
         twice before the folder is called done: by usign -V and by update/usignpy.py.
  D      (v9) how long this RELEASE vouches for itself: not-after = built + D days (1..366, default 90). A box
         refuses an expired RELEASE (so a held-back release address shows up instead of saying "up to date"
         forever). Renewal = the same bundle released again with a bigger serial (a new not-after).
  NEXT   (v9) a usign public key to name as the SUCCESSOR of the signing key: the box adopts it into its key folder
         after this release passes every check (docs/UPDATES.md, key rotation). Must differ from the signing key.

RELEASE (ASCII, LF, at most 65536 bytes; the box parses it line by line and refuses any line it does not know):
  ex4-release 1
  board wd,mycloud-ex4
  version 2026.11.17-v7
  serial 2026111701
  channel trial
  built 2026-11-17T23:40:00Z
  not-after 1803340800 2027-02-15T23:40:00Z    (v9: epoch + the same moment in ISO; the box checks both)
  successor <16-hex key number> <56 base64>    (v9, optional, at most one)
  openwrt 25.12.6 r33311-981c978eff
  kernel 6.12.112 vermagic a44c9a44007be5720baf8da806598a35
  payload <sha256> <bytes> ex4-<version>.tar
  sbom <sha256> <bytes> sbom.cdx.json
  file <sha256> <bytes> <name>            (one per file inside the payload, sorted)
  end

Nothing here downloads, installs or writes outside --out. It refuses to overwrite anything."""
import argparse
import hashlib
import io
import json
import os
import re
import stat
import subprocess
import sys
import tarfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
TOP = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import usignpy  # noqa: E402

RX_VERSION = re.compile(r'^[0-9A-Za-z][0-9A-Za-z.+-]{0,39}$')
RX_NAME = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
RX_BOARD = re.compile(r'^[a-z0-9][a-z0-9,._-]{0,63}$')
RX_ISO = re.compile(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
MAX_RELEASE = 65536
MAX_PAYLOAD = 64 << 20


def die(msg):
    sys.exit('mkrelease: REFUSED: ' + msg)


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def tree(work):
    o = os.path.join(work, 'openwrt')
    if not os.path.isfile(os.path.join(o, 'tmp', '.packageinfo')):
        die(f'{o} is not a built OpenWrt tree (no tmp/.packageinfo)')
    return o


def one(globdir, suffix):
    hits = [f for f in os.listdir(globdir) if f.endswith(suffix)]
    if len(hits) != 1:
        die(f'expected exactly one *{suffix} in {globdir}, found {hits}')
    return os.path.join(globdir, hits[0])


def target_dir(o):
    return os.path.join(o, 'bin', 'targets', 'kirkwood', 'generic')


def build_facts(o):
    """what the tree says about itself: release, revision, kernel version + vermagic (all read from files)"""
    rel = {}
    roots = [d for d in os.listdir(os.path.join(o, 'build_dir')) if d.startswith('target-')]
    if len(roots) != 1:
        die(f'expected one build_dir/target-*, found {roots}')
    bd = os.path.join(o, 'build_dir', roots[0])
    for line in open(os.path.join(bd, 'root-kirkwood', 'etc', 'openwrt_release')):
        m = re.match(r"^(DISTRIB_[A-Z]+)='([^']*)'", line)
        if m:
            rel[m.group(1)] = m.group(2)
    kdirs = [d for d in os.listdir(os.path.join(bd, 'linux-kirkwood_generic')) if re.match(r'^linux-\d+\.\d+\.\d+$', d)]
    if len(kdirs) != 1:
        die(f'expected one linux-X.Y.Z build folder, found {kdirs}')
    kver = kdirs[0][6:]
    vm = open(os.path.join(bd, 'linux-kirkwood_generic', kdirs[0], '.vermagic')).read().strip()
    if not re.match(r'^[0-9a-f]{32}$', vm):
        die(f'the kernel vermagic {vm!r} is not 32 hex')
    num = rel.get('DISTRIB_RELEASE', '')
    rev = rel.get('DISTRIB_REVISION', '')
    if not RX_VERSION.match(num) or not RX_VERSION.match(rev):
        die('openwrt_release has no usable DISTRIB_RELEASE / DISTRIB_REVISION')
    return {'openwrt': num, 'revision': rev, 'kernel': kver, 'vermagic': vm, 'root': os.path.join(bd, 'root-kirkwood')}


# ---------------------------------------------------------------- the SBOM
def parse_packageinfo(path):
    """tmp/.packageinfo -> {binary package name: fields}, each with 'makefile' (its Source-Makefile)"""
    pk, cur, mk = {}, None, None
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.rstrip('\n')
        if line.startswith('Source-Makefile: '):
            mk = line[17:].strip(); cur = None
        elif line.startswith('Package: '):
            cur = {'name': line[9:].strip(), 'makefile': mk}
            pk[cur['name']] = cur
        elif line == '@@':
            cur = None
        elif cur is not None and ': ' in line and not line.startswith(' '):
            k, v = line.split(': ', 1)
            if k in ('Version', 'Source', 'License', 'CPE-ID', 'ABI-Version', 'URL', 'Category', 'Section'):
                cur[k] = v.strip()
    return pk


def read_manifest(path):
    out = {}
    for line in open(path):
        m = re.match(r'^(\S+) - (\S+)$', line.strip())
        if not m:
            die(f'{path}: a line that is not "name - version": {line.strip()!r}')
        out[m.group(1)] = m.group(2)
    return out


def apk_files(o):
    """every built .apk -> path (bin/packages/*/* and bin/targets/.../packages)"""
    found = {}
    roots = [os.path.join(target_dir(o), 'packages')]
    pb = os.path.join(o, 'bin', 'packages')
    for arch in os.listdir(pb):
        for feed in os.listdir(os.path.join(pb, arch)):
            roots.append(os.path.join(pb, arch, feed))
    for r in roots:
        if os.path.isdir(r):
            for f in os.listdir(r):
                if f.endswith('.apk'):
                    found[f] = os.path.join(r, f)
    return found


def source_row(o, makefile_rel, source, dl_hash_cache):
    """the source tarball a package was built from, proven: its sha256 equals a hash pinned in its own Makefile
    (PKG_HASH / PKG_MIRROR_HASH; for the kernel, LINUX_KERNEL_HASH in target/linux/generic/kernel-X.Y)"""
    if not source:
        return {'kind': 'in-tree', 'makefile': makefile_rel}
    p = os.path.join(o, 'dl', source)
    m = re.match(r'^(.*~)([0-9a-f]{40})(\.tar\.[a-z0-9]+)$', source)
    if not os.path.isfile(p) and m:            # a git snapshot: .packageinfo names the full commit, dl/ the 8-hex one
        source = m.group(1) + m.group(2)[:8] + m.group(3)
        p = os.path.join(o, 'dl', source)
    if not os.path.isfile(p):
        return {'kind': 'MISSING', 'file': source, 'makefile': makefile_rel}
    if source not in dl_hash_cache:
        dl_hash_cache[source] = sha256_file(p)
    h = dl_hash_cache[source]
    texts = []
    for rel in (makefile_rel,):
        if rel:
            mp = os.path.join(o, rel)
            if os.path.isfile(mp):
                texts.append(open(mp, errors='replace').read())
    pinned = any(h in t for t in texts)
    return {'kind': 'tarball', 'file': source, 'sha256': h, 'makefile': makefile_rel,
            'pinned': 'yes (the sha256 is the hash its Makefile pins)' if pinned else 'NO (hash not found in the Makefile)'}


def make_sbom(work, built, bundle=None):
    o = tree(work)
    facts = build_facts(o)
    man = read_manifest(one(target_dir(o), '.manifest'))
    info = parse_packageinfo(os.path.join(o, 'tmp', '.packageinfo'))
    # OpenWrt names an ABI-versioned package name+ABI, with a '-' between two digits (libsqlite3 + 0 = libsqlite3-0)
    abimap = {n + ('-' if n[-1:].isdigit() and v['ABI-Version'][:1].isdigit() else '') + v['ABI-Version']: n
              for n, v in info.items() if v.get('ABI-Version')}
    apks = apk_files(o)
    dlh = {}
    comps, problems = [], []
    ksrc = f'linux-{facts["kernel"]}.tar.xz'
    kmk = f'target/linux/generic/kernel-{facts["kernel"].rsplit(".", 1)[0]}'
    for name in sorted(man):
        ver = man[name]
        meta = info.get(name) or info.get(abimap.get(name, ''))
        props = []
        if name == 'kernel':
            src = source_row(o, kmk, ksrc, dlh)
            comp = {'type': 'operating-system', 'name': 'kernel', 'version': ver,
                    'licenses': [{'license': {'id': 'GPL-2.0-only'}}], 'cpe': f'cpe:/o:linux:linux_kernel:{facts["kernel"]}'}
            props.append(('openwrt:source-package', 'linux'))
            props.append(('openwrt:vermagic', facts['vermagic']))
        elif meta is None:
            problems.append(f'{name} {ver}: not in .packageinfo')
            comp = {'type': 'application', 'name': name, 'version': ver}
            src = {'kind': 'UNKNOWN'}
        else:
            mk = meta.get('makefile') or ''
            src = source_row(o, mk, meta.get('Source'), dlh)
            cat = meta.get('Category', '')
            comp = {'type': 'library' if cat == 'Libraries' else ('firmware' if cat == 'Firmware' else 'application'),
                    'name': name, 'version': ver}
            if meta.get('License'):
                comp['licenses'] = [{'license': {'name': x}} for x in meta['License'].split()]
            if meta.get('CPE-ID'):
                comp['cpe'] = meta['CPE-ID'] + ':' + re.sub(r'-r\d+$', '', ver)
            props.append(('openwrt:source-package', os.path.basename(os.path.dirname(mk)) if mk else name))
            if meta.get('URL'):
                comp['externalReferences'] = [{'type': 'website', 'url': meta['URL']}]
        f = apks.get(f'{name}-{ver}.apk')
        if f:
            comp['hashes'] = [{'alg': 'SHA-256', 'content': sha256_file(f)}]
        else:
            problems.append(f'{name} {ver}: no built .apk found')
        props.append(('openwrt:source-makefile', src.get('makefile') or ''))
        props.append(('openwrt:source-kind', src['kind']))
        if src['kind'] == 'tarball':
            props += [('openwrt:source-file', src['file']), ('openwrt:source-sha256', src['sha256']),
                      ('openwrt:source-hash-pinned', src['pinned'])]
            if not src['pinned'].startswith('yes'):
                problems.append(f'{name}: source {src["file"]} hash is not pinned in {src["makefile"]}')
        elif src['kind'] != 'in-tree':
            problems.append(f'{name}: source {src}')
        comp['properties'] = [{'name': k, 'value': v} for k, v in props]
        comps.append(comp)
    if bundle:
        for f in sorted(os.listdir(bundle)):
            if f in ('ex4fan', 'ex4log', 'ex4peek', 'ex4boot-l2off.ko', 'ex4-trial.sh', 'overlay.cpio'):
                comps.append({'type': 'application', 'name': 'ex4-' + f if not f.startswith('ex4') else f,
                              'version': 'repo', 'hashes': [{'alg': 'SHA-256', 'content': sha256_file(os.path.join(bundle, f))}],
                              'licenses': [{'license': {'id': 'GPL-2.0-or-later'}}],
                              'properties': [{'name': 'openwrt:source-kind', 'value': 'this repository (wd-mycloud-ex4-openwrt)'}]})
    body = {'bomFormat': 'CycloneDX', 'specVersion': '1.4', 'version': 1,
            'metadata': {'timestamp': built, 'component': {'type': 'firmware', 'name': 'wd-mycloud-ex4-openwrt',
                         'version': f'{facts["openwrt"]} {facts["revision"]}'},
                         'properties': [{'name': 'openwrt:release', 'value': facts['openwrt']},
                                        {'name': 'openwrt:revision', 'value': facts['revision']},
                                        {'name': 'openwrt:kernel', 'value': facts['kernel']},
                                        {'name': 'openwrt:vermagic', 'value': facts['vermagic']}]},
            'components': comps}
    digest = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).digest()
    body['serialNumber'] = 'urn:uuid:' + str(uuid.UUID(bytes=digest[:16], version=5))
    return body, facts, problems


# ---------------------------------------------------------------- the payload + RELEASE
def board_of_dts():
    t = open(os.path.join(TOP, 'dts', 'kirkwood-wd-mycloud-ex4.dts')).read()
    m = re.search(r'^\s*compatible\s*=\s*"([^"]+)"', t, re.M)
    if not m or not RX_BOARD.match(m.group(1)):
        die('no board compatible in dts/kirkwood-wd-mycloud-ex4.dts')
    return m.group(1)


def check_bundle(b):
    # v9.7: bench-only variants (xor-off, the profile twin, a cmdline arm) never become a release, whatever MD5SUMS says
    if os.path.lexists(os.path.join(b, 'VARIANT')):
        die(f'{b} carries a VARIANT file: a bench-only bundle (xor-off / profile twin / cmdline arm); a release is built only from a default bundle')
    sums = os.path.join(b, 'MD5SUMS')
    if not os.path.isfile(sums):
        die(f'{b}: no MD5SUMS')
    names = []
    for line in open(sums):
        m = re.match(r'^([0-9a-f]{32})  (\S+)$', line.rstrip('\n'))
        if not m or not RX_NAME.match(m.group(2)):
            die(f'{sums}: bad line {line!r}')
        if m.group(2) == 'VARIANT':
            die(f'{sums} names a VARIANT file: a bench-only bundle; a release is built only from a default bundle')
        p = os.path.join(b, m.group(2))
        if not os.path.isfile(p) or os.path.islink(p):
            die(f'{p}: not a regular file')
        if hashlib.md5(open(p, 'rb').read()).hexdigest() != m.group(1):
            die(f'{p}: md5 does not match MD5SUMS')
        names.append(m.group(2))
    return sorted(set(names + ['MD5SUMS']))


def make_tar(b, names, out):
    """deterministic: sorted, regular files only, uid/gid 0, mtime 0, modes 0644/0755"""
    with tarfile.open(out, 'w', format=tarfile.USTAR_FORMAT) as t:
        for n in names:
            p = os.path.join(b, n)
            st = os.stat(p)
            ti = tarfile.TarInfo(n)
            ti.size = st.st_size; ti.mtime = 0; ti.uid = ti.gid = 0; ti.uname = ti.gname = 'root'
            ti.mode = 0o755 if st.st_mode & stat.S_IXUSR else 0o644
            with open(p, 'rb') as f:
                t.addfile(ti, f)


def check_key(sec, pub, allow_test):
    st = os.stat(sec)
    if stat.S_IMODE(st.st_mode) != 0o600:
        die(f'{sec} has mode {oct(stat.S_IMODE(st.st_mode))}; a signing key must be 0600')
    if os.path.realpath(sec).startswith(os.path.realpath(TOP) + os.sep):
        die(f'{sec} is inside the repository; the private key never lives there')
    shipped = os.path.join(HERE, 'keys', 'ex4-release.pub')
    kn_pub, a = usignpy.read_pub(pub)
    kn_ship, a_ship = usignpy.read_pub(shipped)
    if (kn_pub, a) != (kn_ship, a_ship) and not allow_test:
        die(f'{pub} (key {kn_pub.hex()}) is not the key the image ships ({shipped}, key {kn_ship.hex()})')
    return (kn_pub, a) == (kn_ship, a_ship)


def cmd_release(a):
    if not RX_VERSION.match(a.version):
        die('--version must match [0-9A-Za-z][0-9A-Za-z.+-]{0,39}')
    if not re.match(r'^[1-9][0-9]{0,9}$', a.serial):
        die('--serial must be a whole number 1..9999999999')
    if not RX_ISO.match(a.built):
        die('--built must look like 2026-11-17T23:40:00Z')
    if os.path.exists(a.out):
        die(f'{a.out} exists (never overwrite)')
    shipped = check_key(a.key, a.pub, a.allow_test_key)
    channel = a.channel if shipped else 'test'
    if not 1 <= a.valid_days <= 366:
        die('--valid-days must be 1..366')
    import calendar, datetime
    bt = calendar.timegm(datetime.datetime.strptime(a.built, '%Y-%m-%dT%H:%M:%SZ').timetuple())
    na = bt + a.valid_days * 86400
    na_iso = datetime.datetime.fromtimestamp(na, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    succ = None
    if a.successor:
        skn, skey = usignpy.read_pub(a.successor)
        own_kn, _ = usignpy.read_pub(a.pub)
        if skn == own_kn:
            die('--successor is the signing key itself')
        import base64
        raw = open(a.successor).read().strip().split('\n')[-1].strip()
        if len(raw) != 56 or base64.b64decode(raw)[2:10] != skn:
            die(f'{a.successor}: not a usign public key line of 56 base64 characters')
        succ = (skn.hex(), raw)
    board = board_of_dts()
    names = check_bundle(a.bundle)
    sbom, facts, problems = make_sbom(a.work, a.built, a.bundle)
    if problems:
        die('the SBOM is not whole:\n  ' + '\n  '.join(problems))
    os.makedirs(a.out)
    pay = f'ex4-{a.version}.tar'
    make_tar(a.bundle, names, os.path.join(a.out, pay))
    psize = os.path.getsize(os.path.join(a.out, pay))
    if psize > MAX_PAYLOAD:
        die(f'payload {psize} B is over the box\'s limit {MAX_PAYLOAD}')
    sb = json.dumps(sbom, indent=1, sort_keys=True).encode() + b'\n'
    open(os.path.join(a.out, 'sbom.cdx.json'), 'wb').write(sb)
    lines = ['ex4-release 1', f'board {board}', f'version {a.version}', f'serial {a.serial}', f'channel {channel}',
             f'built {a.built}', f'not-after {na} {na_iso}', f'openwrt {facts["openwrt"]} {facts["revision"]}',
             f'kernel {facts["kernel"]} vermagic {facts["vermagic"]}',
             f'payload {sha256_file(os.path.join(a.out, pay))} {psize} {pay}',
             f'sbom {hashlib.sha256(sb).hexdigest()} {len(sb)} sbom.cdx.json']
    if succ:
        lines.append(f'successor {succ[0]} {succ[1]}')
    for n in names:
        p = os.path.join(a.bundle, n)
        lines.append(f'file {sha256_file(p)} {os.path.getsize(p)} {n}')
    lines.append('end')
    rel = ('\n'.join(lines) + '\n').encode('ascii')
    if len(rel) > MAX_RELEASE:
        die('RELEASE is over 65536 bytes')
    rp = os.path.join(a.out, 'RELEASE')
    open(rp, 'wb').write(rel)
    r = subprocess.run([a.usign, '-S', '-m', rp, '-s', a.key, '-x', rp + '.sig'], capture_output=True, text=True)
    if r.returncode != 0:
        die('usign -S failed: ' + r.stderr.strip())
    r = subprocess.run([a.usign, '-V', '-q', '-m', rp, '-p', a.pub, '-x', rp + '.sig'], capture_output=True, text=True)
    if r.returncode != 0:
        die('usign -V does not accept what usign -S just made: ' + r.stderr.strip())
    ok, why = usignpy.verify_files(a.pub, rp, rp + '.sig')
    if not ok:
        die('usignpy does not accept the signature: ' + why)
    print(f'mkrelease: {a.out}: RELEASE ({len(rel)} B, serial {a.serial}, channel {channel}, board {board}, '
          f'good until {na_iso}' + (f', successor key {succ[0]}' if succ else '') + '), '
          f'RELEASE.sig ({why}; usign -V agrees), {pay} ({psize} B, {len(names)} files), '
          f'sbom.cdx.json ({len(sbom["components"])} components)')
    return 0


def cmd_sbom(a):
    if not RX_ISO.match(a.built):
        die('--built must look like 2026-11-17T23:40:00Z')
    if os.path.exists(a.out):
        die(f'{a.out} exists')
    sbom, facts, problems = make_sbom(a.work, a.built, a.bundle)
    open(a.out, 'w').write(json.dumps(sbom, indent=1, sort_keys=True) + '\n')
    print(f'sbom: {len(sbom["components"])} components; {len(problems)} problem(s)')
    for p in problems:
        print('  ' + p)
    return 1 if problems else 0


def cmd_ident(a):
    """/etc/ex4-release inside the image: who the running system says it is (read by ex4-update + the web UI)"""
    if not RX_VERSION.match(a.version) or not re.match(r'^[1-9][0-9]{0,9}$', a.serial):
        die('bad --version / --serial')
    if not RX_VERSION.match(a.openwrt) or not re.match(r'^\d+\.\d+\.\d+$', a.kernel):
        die('bad --openwrt / --kernel')
    if a.channel not in ('stable', 'trial'):
        die('--channel: stable | trial')
    if os.path.exists(a.out):
        die(f'{a.out} exists')
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    open(a.out, 'w').write(f'board={board_of_dts()}\nversion={a.version}\nserial={a.serial}\nchannel={a.channel}\n'
                           f'openwrt={a.openwrt}\nkernel={a.kernel}\n')
    os.chmod(a.out, 0o644)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('sbom'); s.add_argument('--work', required=True); s.add_argument('--built', required=True)
    s.add_argument('--out', required=True); s.add_argument('--bundle')
    i = sub.add_parser('ident')
    for k in ('--version', '--serial', '--openwrt', '--kernel', '--out'):
        i.add_argument(k, required=True)
    i.add_argument('--channel', default='trial')
    r = sub.add_parser('release')
    for k in ('--work', '--bundle', '--version', '--serial', '--key', '--pub', '--usign', '--out'):
        r.add_argument(k, required=True)
    r.add_argument('--channel', default='trial', choices=['stable', 'trial'])
    r.add_argument('--built', default=None)
    r.add_argument('--allow-test-key', action='store_true')
    r.add_argument('--valid-days', type=int, default=90)
    r.add_argument('--successor')
    a = ap.parse_args()
    if a.cmd == 'release':
        if a.built is None:
            import datetime
            a.built = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        return cmd_release(a)
    return {'sbom': cmd_sbom, 'ident': cmd_ident}[a.cmd](a)


if __name__ == '__main__':
    sys.exit(main())
