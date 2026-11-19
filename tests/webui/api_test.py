#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""api_test.py : every method of the web interface's backend, through its real door (POST /ubus, JSON-RPC).

ONE test list, two backends:
  the fake   python3 tests/webui/fakebox.py --port 18490 &      python3 tests/webui/api_test.py --url http://127.0.0.1:18490
  the real   bash tests/webui/emu/emu.sh ROOTFS WORK -- python3 tests/webui/api_test.py --emu
             (rpcd + ex4.uc + ex4-apply as ARM binaries under qemu; --emu takes the addresses from emu.sh's environment
             and ALSO reads the files the backend wrote and the commands its helper asked for)
That the same list passes on both is what makes the fake a fair stand-in for the page tests.

It checks: what a browser without a session can reach; the first-boot claim; the sign-in brake; every read method
against the sample box (truth.py); every write method, its refusals (bad names, injection attempts, limits) and what
it leaves in /etc/config and in the services' own files; that no secret ever travels in a command line; the network
change that takes itself back; the health sentence's levels; the two gates in front of the one write to the data volume.
--slow adds the waits that take a minute (the claim lock-out).
Exit 0 only if nothing failed.
"""
import argparse, json, os, re, subprocess, sys, time, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sha256crypt import crypt5          # noqa: E402
import truth                            # noqa: E402

Z = '0' * 32
PASS, FAIL = [], []
ADMIN, PW1, PW2 = 'keeper', 'tide and lamp, 12+', 'a new harbour light'


def ok(cond, name, detail=''):
    (PASS if cond else FAIL).append(name)
    print(('  ok   ' if cond else '  FAIL ') + name + ((' :: ' + str(detail)[:300]) if (detail and not cond) else ''))
    return cond


class Box:
    def __init__(self, url, root=None, calls=None):
        self.url, self.root, self.calls, self.sid, self.n = url.rstrip('/'), root, calls, Z, 0
        self.emu = root is not None

    def raw(self, body):
        req = urllib.request.Request(self.url + '/ubus', data=json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=40) as r:
            return json.loads(r.read().decode())

    def call(self, obj, method, args=None, sid=None):
        """-> (code, data): code 0 + the reply object, or the ubus / JSON-RPC error code and None."""
        self.n += 1
        j = self.raw({'jsonrpc': '2.0', 'id': self.n, 'method': 'call', 'params': [self.sid if sid is None else sid, obj, method, args or {}]})
        if 'error' in j:
            return j['error']['code'], None
        res = j.get('result') or [0]
        return res[0], (res[1] if len(res) > 1 else None)

    def ex4(self, method, args=None, sid=None):
        code, data = self.call('ex4', method, args, sid)
        return data if code == 0 and data is not None else {'ok': False, 'err': 'rpc_%s' % code}

    def wait_job(self, jid, timeout=90):
        end = time.time() + timeout
        while time.time() < end:
            for j in self.ex4('status').get('jobs', []):
                if j['id'] == jid and j['state'] in ('ok', 'fail'):
                    return j
            time.sleep(0.4)
        return {'state': 'timeout'}

    def done(self, reply, timeout=90):
        """a write method's reply -> its job's final state ('ok' / 'fail' / 'refused')"""
        if not reply.get('ok'):
            return 'refused:' + str(reply.get('err'))
        return self.wait_job(reply['job'], timeout)['state'] if 'job' in reply else 'ok'

    # ---- test controls: the real backend is steered through its fixture tree, the fake through /_test
    def claim_code(self):
        if self.emu:
            return open(self.root + '/tmp/ex4/claim').read().strip()
        with urllib.request.urlopen(self.url + '/_test/claim', timeout=10) as r:
            return json.loads(r.read().decode())['code']

    def scenario(self, name):
        if self.emu:
            subprocess.run([sys.executable, '-I', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'truth.py'), '--root', self.root, '--scenario', name], check=True)
            if self.sid != Z:                # a finished job drops the backend's 30 s caches
                self.done(self.ex4('support_bundle'))
            time.sleep(1.2)
        else:
            req = urllib.request.Request(self.url + '/_test/scenario', data=json.dumps({'name': name}).encode(), headers={'Content-Type': 'application/json'})
            urllib.request.urlopen(req, timeout=10).read()

    def file(self, path):
        try:
            return open(self.root + path).read()
        except OSError:
            return None

    def calls_text(self):
        return open(self.calls).read() if self.calls else ''


def t_doors(b):
    print('-- 1. without a session')
    for obj, m, a in (('ex4', 'status', {}), ('ex4', 'shares', {}), ('ex4', 'share_add', {'name': 'x'}), ('session', 'login', {'username': 'root', 'password': ''}),
                      ('session', 'login', {'username': ADMIN, 'password': PW1}), ('file', 'read', {'path': '/etc/shadow'}), ('file', 'exec', {'command': '/bin/sh'}),
                      ('uci', 'get', {'config': 'rpcd'}), ('system', 'board', {}), ('ex4', 'restart', {})):
        code, data = b.call(obj, m, a, Z)
        ok(code != 0 and data is None, 'no session: %s.%s is refused' % (obj, m), (code, data))
    code, data = b.call('ex4', 'status', {}, 'f' * 32)
    ok(code != 0, 'a session id that does not exist is refused', (code, data))


def t_claim(b, slow):
    print('-- 2. first boot: no account exists, no default password')
    st = b.ex4('setup_state')
    ok(st.get('claimed') is False and st.get('name') == 'ex4', 'setup_state says unclaimed', st)
    r = b.ex4('sign_in', {'username': 'root', 'password': ''})
    ok(r.get('ok') is False and r.get('err') == 'unclaimed', 'nobody can sign in before the claim (root, empty password)', r)
    r = b.ex4('sign_in', {'username': 'admin', 'password': 'admin'})
    ok(r.get('ok') is False, 'nobody can sign in before the claim (admin/admin)', r)
    code = b.claim_code()
    ok(re.fullmatch(r'\d{8}', code or '') is not None, 'the box holds an eight-digit code (v9)')
    if b.emu:
        ok(b.file('/var/run/ex4panel/alerts.d/00-claim') == 'setup %s\n' % code, 'and offers it to the front screen as an alert line (16 characters)')
    good = {'code': code, 'username': ADMIN, 'hash': crypt5(PW1, 'Qe1.Zr8/abCD'), 'hostname': 'ex4'}
    wrong = '%08d' % ((int(code) + 1) % 100000000)
    r = b.ex4('setup_claim', dict(good, code=wrong))
    ok(r.get('ok') is False and r.get('err') == 'bad_code', 'a wrong code is refused', r)
    if slow:
        for _ in range(3):
            b.ex4('setup_claim', dict(good, code=wrong))
        r = b.ex4('setup_claim', dict(good, code=wrong))
        ok(r.get('err') == 'wait' and r.get('wait_s') == 60, 'the fifth wrong code starts a 60 s pause', r)
        code2 = b.claim_code()
        ok(code2 != code, 'and the box makes a new code')
        r = b.ex4('setup_claim', dict(good, code=code2))
        ok(r.get('err') == 'wait', 'inside the pause even the right code waits', r)
        time.sleep(61)
        good['code'] = code2
    for field, val, err in (('username', 'root', 'bad_name'), ('username', 'Keeper', 'bad_name'), ('username', 'a b', 'bad_name'),
                            ('hash', 'plaintext-password', 'bad_hash'), ('hash', '$1$abc$' + 'x' * 22, 'bad_hash'), ('hash', good['hash'] + '\n', 'bad_hash'),
                            ('hostname', 'Bad_Name', 'bad_host'), ('hostname', '-ex4', 'bad_host'), ('hostname', 'a' * 40, 'bad_host')):
        r = b.ex4('setup_claim', dict(good, **{field: val}))
        ok(r.get('ok') is False and r.get('err') == err, 'claim refuses %s=%r' % (field, val[:20]), r)
    r = b.ex4('setup_claim', good)
    ok(r.get('ok') is True, 'the right code, a name and a hash claim the box', r)
    ok(b.ex4('setup_state').get('claimed') is True, 'setup_state says claimed')
    r = b.ex4('setup_claim', good)
    ok(r.get('ok') is False and r.get('err') == 'claimed', 'a second claim is refused', r)
    if b.emu:
        cfg = b.file('/etc/config/rpcd') or ''
        ok(cfg.count('config login') == 1 and "option username '%s'" % ADMIN in cfg and good['hash'] in cfg and "list read 'ex4'" in cfg and "list write 'ex4'" in cfg,
           'rpcd holds one login: the administrator, the hash, the group ex4', cfg)
        ok('root' not in cfg and PW1 not in cfg, 'no root login and no plaintext in rpcd\'s config')
        ok(b.file('/tmp/ex4/claim') is None and b.file('/var/run/ex4panel/alerts.d/00-claim') is None, 'the code is gone, from the box and from the screen\'s alerts')


def t_signin(b):
    print('-- 3. sign-in and its brake')
    r = [b.ex4('sign_in', {'username': ADMIN, 'password': 'wrong %d' % i}) for i in range(3)]
    ok([x.get('ok') for x in r] == [False] * 3 and [x.get('wait_s') for x in r] == [0, 0, 1], 'three wrong passwords: the third starts a 1 s lock-out', r)
    r = b.ex4('sign_in', {'username': ADMIN, 'password': PW1})
    ok(r.get('ok') is False and r.get('err') == 'wait' and r.get('wait_s', 0) >= 1, 'inside the lock-out the RIGHT password is refused too', r)
    time.sleep(1.3)
    r = b.ex4('sign_in', {'username': ADMIN, 'password': 'still wrong'})
    ok(r.get('wait_s') == 2, 'the next failure doubles it', r)
    time.sleep(2.3)
    for bad in ({'username': 'root', 'password': PW1}, {'username': ADMIN + '\n', 'password': PW1}, {'username': ADMIN, 'password': ''}, {'username': ADMIN}):
        r = b.ex4('sign_in', bad)
        ok(r.get('ok') is False, 'sign-in refuses %r' % (bad.get('username'),), r)
    time.sleep(4.2)                          # root's try above went to rpcd and counted: 4 s
    r = b.ex4('sign_in', {'username': ADMIN, 'password': PW1})
    ok(r.get('ok') is True and re.fullmatch(r'[0-9a-f]{32}', r.get('sid', '')) is not None and r.get('timeout') == 900, 'the right password signs in: a 128-bit session, 15 minutes', r)
    b.sid = r.get('sid', Z)
    if b.emu:                                # v8: from a clean brake (the sign-in above reset it), a burst of parallel guesses
        import concurrent.futures            # cannot all slip past it while the first is still inside rpcd
        with concurrent.futures.ThreadPoolExecutor(8) as px:
            rs = list(px.map(lambda i: Box(b.url).ex4('sign_in', {'username': ADMIN, 'password': 'parallel %d' % i}, Z), range(8)))
        nbad = sum(1 for x in rs if x.get('err') == 'bad')
        ok(nbad <= 2 and all(x.get('ok') is False for x in rs) and all(x.get('err') in ('bad', 'wait') for x in rs),
           'v8: 8 wrong guesses at once: at most 2 reach a password check without the brake (the rest wait)', [(x.get('err'), x.get('wait_s')) for x in rs])
        time.sleep(max([x.get('wait_s') or 0 for x in rs] + [0]) + 1.3)
        r2 = b.ex4('sign_in', {'username': ADMIN, 'password': PW1}, Z)
        ok(r2.get('ok') is True, 'v8: after the burst\'s lock-out the right password signs in (and the brake starts from zero again)', r2)
    code, data = b.call('ex4', 'status')
    ok(code == 0 and isinstance(data, dict), 'the session reads ex4.status')
    for obj, m, a in (('file', 'read', {'path': '/etc/shadow'}), ('file', 'exec', {'command': '/bin/sh', 'params': ['-c', 'id']}), ('uci', 'get', {'config': 'rpcd'}),
                      ('session', 'grant', {'scope': 'ubus', 'objects': [['*', '*']]}), ('session', 'login', {'username': ADMIN, 'password': PW1}), ('ex4', 'no_such_method', {})):
        code, data = b.call(obj, m, a)
        ok(code != 0 and data is None, 'the administrator\'s session cannot call %s.%s' % (obj, m), (code, data))


def t_read(b):
    print('-- 4. the read path against the sample box')
    T = truth.box('trial')
    s = b.ex4('status')
    ok(s.get('name') == 'ex4' and isinstance(s.get('seq'), int) and abs(s.get('now', 0) - time.time()) < 120, 'status: name, sequence, clock', s)
    a = s.get('array') or {}
    ok((a.get('dev'), a.get('level'), a.get('state'), a.get('degraded'), a.get('disks'), a.get('ro'), a.get('size_kb')) == ('md1', 'raid5', 'readonly', 0, 4, True, truth.MD_KIB), 'status: the array as it is (RAID 5, four members, read-only)', a)
    v = s.get('vol') or {}
    ok((v.get('path'), v.get('mounted'), v.get('rw'), v.get('total_kb'), v.get('used_kb')) == ('/mnt/md1', True, False, truth.KIB_TOTAL, truth.KIB_USED), 'status: the volume (mounted read-only, 1.7 GiB of 10.8 TiB)', v)
    c = s.get('clim') or {}
    ok((c.get('fan'), c.get('rpm'), c.get('board'), c.get('hot')) == ('low', 1020, 44, 41) and c.get('disks') == {d['dev']: d['temp'] for d in T['disks']}, 'status: fan, board and the four drive temperatures', c)
    h = s.get('health') or {}
    ok(h.get('level') == 'watch' and h.get('why') == [{'c': 'disk_watch', 'bay': 4, 'pending': 1, 'realloc': 0, 'uncorrect': 0}], 'status: the verdict is "one disk wants watching", bay 4, one unreadable sector', h)
    ok([(d['bay'], d['dev'], d['v']) for d in s.get('disks', [])] == [(1, 'sda', 'ok'), (2, 'sdb', 'ok'), (3, 'sdc', 'ok'), (4, 'sdd', 'watch')], 'status: four bays, the fourth marked', s.get('disks'))
    t = s.get('trial') or {}
    ok(t.get('stay') is False and 0 < t.get('left_s', 0) <= 20 * 60, 'status: a trial with its clock', t)
    ok([(p['dev'], p['up'], p['speed']) for p in s.get('ports', [])] == [('eth0', True, 1000), ('eth1', False, None)], 'status: the two ports', s.get('ports'))
    ok(s.get('mem', {}).get('total_kb') == T['mem_total_kb'] and set(s.get('rev', {})) >= {'disks', 'shares', 'users', 'services', 'alerts', 'system', 'panel', 'events'}, 'status: memory and the revision counters')
    size = len(json.dumps(b.raw({'jsonrpc': '2.0', 'id': 1, 'method': 'call', 'params': [b.sid, 'ex4', 'status', {}]}), separators=(',', ':')))
    ok(size <= 1536, 'one idle poll is at most 1.5 KB (%d bytes)' % size)
    s1 = b.ex4('status')
    s2 = b.ex4('status')
    time.sleep(1.2)
    s3 = b.ex4('status')
    ok(s1.get('seq') == s2.get('seq') and s3.get('seq', 0) > s1.get('seq', 0), 'two polls inside a second share one snapshot; a later one is fresh')
    j = b.raw([{'jsonrpc': '2.0', 'id': 1, 'method': 'call', 'params': [b.sid, 'ex4', 'status', {}]}, {'jsonrpc': '2.0', 'id': 2, 'method': 'call', 'params': [b.sid, 'ex4', 'events', {'since': 0}]}])
    ok(isinstance(j, list) and len(j) == 2 and all('result' in x for x in j), 'two calls travel in one request')

    d = b.ex4('disks').get('disks', [])
    ok(len(d) == 4 and all(x['model'] == 'WDC WD40EFRX-68W' and x['size_b'] == truth.DISK_SECTORS * 512 and x['member'] == 'in_sync' for x in d), 'disks: four WD40EFRX, all in step', d)
    ok([(x['hours'], x['pending'], x['realloc'], x['temp'], x['serial']) for x in d] == [(t_['hours'], t_['pending'], t_['realloc'], t_['temp'], t_['serial']) for t_ in T['disks']], 'disks: hours, counters, temperatures, serials', d)
    ar = b.ex4('array')
    a = ar.get('array') or {}
    ok(ar.get('auto_check') is False and a.get('mismatch') == 0 and a.get('chunk_kb') == 64 and a.get('bitmap') is False and a.get('meta') == '1.0', 'array: 64 KiB chunks, no bitmap, no scheduled check', ar)
    ok([(m['dev'], m['bay'], m['state']) for m in a.get('members', [])] == [('sda', 1, 'in_sync'), ('sdb', 2, 'in_sync'), ('sdc', 3, 'in_sync'), ('sdd', 4, 'in_sync')], 'array: its four members by bay', a.get('members'))
    p = b.ex4('panel')
    ok(p.get('tier') == 'A' and p.get('on') is False and p.get('lcd') is True and p.get('standby') == '3' and p.get('sent') == {} and p.get('standby_codes') == ['0', '3', '6'] and p.get('daemon') is True, 'panel: the screen is fed nothing until it is switched on', p)
    sy = b.ex4('system')
    ok(sy.get('name') == 'ex4' and sy.get('admin') == ADMIN and sy.get('version', {}).get('openwrt') == '25.12.6' and sy.get('version', {}).get('kernel') == '6.12.112' and 'America/Los_Angeles' in sy.get('zones', []), 'system: name, administrator, versions, zones', sy)
    ok(sy.get('net', {}).get('mode') == 'dhcp' and sy.get('net', {}).get('bond') == 'none' and sy.get('net', {}).get('pending') is None, 'system: address from the router, no bond', sy.get('net'))
    if b.emu:
        fp = (sy.get('cert') or {}).get('fp', '')
        der = subprocess.run(['openssl', 'x509', '-inform', 'der', '-in', b.root + '/etc/uhttpd.crt', '-noout', '-fingerprint', '-sha256'], capture_output=True, text=True).stdout
        ok(len(fp) == 79 and fp.replace(':', '') == der.strip().split('=')[-1].replace(':', ''), 'system: the certificate fingerprint is the real certificate\'s', (fp, der))
        txt = subprocess.run(['openssl', 'x509', '-inform', 'der', '-in', b.root + '/etc/uhttpd.crt', '-noout', '-text'], capture_output=True, text=True).stdout
        ok(('DNS:ex4, DNS:ex4.local' in txt or 'DNS:ex4.local, DNS:ex4' in txt) and 'IP Address' not in txt and 'id-ecPublicKey' in txt and 'TLS Web Server Authentication' in txt, 'px5g made an EC certificate with the box\'s names')
        if os.environ.get('EX4_EMU_URLS'):
            o = subprocess.run(['curl', '-sk', '-m', '20', '-o', '/dev/null', '-w', '%{http_code} %{ssl_verify_result}', os.environ['EX4_EMU_URLS'] + '/'], capture_output=True, text=True).stdout
            ok(o.startswith('200'), 'uhttpd serves the page over TLS with that certificate', o)
        # v9: the Updates card's two reads: /etc/ex4-release (who this system says it is) and ex4-update's state file,
        # each value through a whitelist (a line that does not match is dropped, never shown)
        os.makedirs(b.root + '/etc/ex4-update/keys', exist_ok=True); os.makedirs(b.root + '/tmp/ex4-update', exist_ok=True)
        open(b.root + '/etc/ex4-release', 'w').write('board=wd,mycloud-ex4\nversion=2026.11.17-v9\nserial=2026111702\nchannel=trial\nopenwrt=25.12.6\nkernel=6.12.112\n')
        open(b.root + '/etc/ex4-update/keys/cd0c35ab50a98c3c', 'w').write('untrusted comment: test\nx\n')
        open(b.root + '/tmp/ex4-update/state', 'w').write('checked=1795000000\ncmd=check\nresult=refused\nwhy=expired\nsig=good\nurl=https://github.com\n'
                                                           'expires=2027-02-15T23:40:00Z\nlatest=<script>x</script>\n')
        u = b.ex4('system').get('update') or {}
        ok(u.get('running') == '2026.11.17-v9' and u.get('serial') == '2026111702' and u.get('channel') == 'trial' and u.get('keys') == 1, 'system.update: what runs (from /etc/ex4-release) and the one key held', u)
        ok(u.get('result') == 'refused' and u.get('why') == 'expired' and u.get('expires') == '2027-02-15T23:40:00Z' and u.get('checked') == 1795000000, 'system.update: an EXPIRED release is reported as such, with its date (v9)', u)
        ok(u.get('latest') is None, 'system.update: a state value outside the whitelist (markup) is dropped, not passed on', u.get('latest'))
        os.unlink(b.root + '/tmp/ex4-update/state'); os.unlink(b.root + '/etc/ex4-update/keys/cd0c35ab50a98c3c')
        u = b.ex4('system').get('update') or {}
        ok(u.get('checked') is None and u.get('keys') == 0, 'system.update: no check yet, no key: said so (never a made-up result)', u)
    sv = b.ex4('services')
    ok(sv.get('trial') is True and [x['id'] for x in sv.get('list', [])] == ['smb', 'nfs', 'find', 'ssh', 'time'], 'services: the allow-list', sv)
    al = b.ex4('alerts')
    ok(al.get('enabled') is False and al.get('has_pass') is False and sorted(al.get('events', [])) == ['disk', 'raid', 'space', 'temp'] and al.get('space_pct') == 90, 'alerts: off, every event ticked', al)


def t_shares(b):
    print('-- 5. shares, people, groups, NFS exports')
    sh = b.ex4('shares')
    ok(sh.get('shares') == [] and sh.get('volume', {}).get('mounted') is True and sh.get('volume', {}).get('rw') is False and set(sh.get('folders', [])) == {'Public', 'SmartWare', 'TimeMachineBackup', 'Media', 'Backups'}, 'shares: none yet; the folders already on the volume are offered', sh)
    for name in ('', '.hidden', '../etc', 'a/b', 'a\\b', 'x' * 33, 'global', 'IPC$', 'name;rm', 'nl\nname', 'q"uote', "it's", 'tab\tname', ' lead', 'trail '):
        r = b.ex4('share_add', {'name': name})
        ok(r.get('ok') is False and r.get('err') == 'bad_name', 'share_add refuses the name %r' % name[:12], r)
    r = b.ex4('share_add', {'name': 'Brand New'})
    ok(r.get('ok') is False and r.get('err') == 'read_only', 'a NEW folder is refused on a read-only volume', r)
    r = b.ex4('share_add', {'name': 'Public', 'guest': 'rw'})
    ok(b.done(r) == 'ok' and r.get('made') is False, 'an EXISTING folder can be shared', r)
    r = b.ex4('share_add', {'name': 'public'})
    ok(r.get('err') == 'exists', 'the same name in another case is taken', r)
    r = b.ex4('share_add', {'name': 'Media', 'rw': ['nobody-here']})
    ok(r.get('err') == 'bad_who', 'a share cannot name a person who does not exist', r)

    for name in ('root', 'Anna', '9lives', 'a b', 'x' * 32, 'nobody', 'daemon', "o'brien", 'semi;colon'):
        r = b.ex4('user_add', {'name': name, 'password': 'long enough pw'})
        ok(r.get('ok') is False and r.get('err') in ('bad_name', 'exists'), 'user_add refuses the name %r' % name[:12], r)
    r = b.ex4('user_add', {'name': 'anna', 'password': 'short'})
    ok(r.get('err') == 'bad_password', 'a 5-character password is refused', r)
    secret = "s3cret pass'word; $(id) `id`"
    ok(b.done(b.ex4('user_add', {'name': 'anna', 'password': secret})) == 'ok', 'user_add anna (a password full of shell characters)')
    ok(b.done(b.ex4('user_add', {'name': 'ben', 'password': 'another long one'})) == 'ok', 'user_add ben')
    ok(b.ex4('user_add', {'name': 'anna', 'password': 'whatever long'}).get('err') == 'exists', 'a second anna is refused')
    ok(b.done(b.ex4('group_add', {'name': 'family', 'members': ['anna', 'ben']})) == 'ok', 'group_add family')
    ok(b.ex4('group_add', {'name': 'crew', 'members': ['ghost']}).get('err') == 'bad_who', 'a group cannot hold a person who does not exist')
    ok(b.ex4('group_add', {'name': 'anna'}).get('err') == 'exists', 'a group cannot take a person\'s name')
    u = b.ex4('users')
    ok(u.get('admin') == ADMIN and [(x['name'], x['uid']) for x in u.get('users', [])] == [('anna', 1000), ('ben', 1001)] and u.get('groups') == [{'name': 'family', 'gid': 1000, 'members': ['anna', 'ben']}], 'users: two people, one group', u)
    ok(b.done(b.ex4('share_add', {'name': 'Media', 'rw': ['anna'], 'ro': ['@family']})) == 'ok', 'share Media: anna may change, the family may read')
    ok(b.done(b.ex4('share_add', {'name': 'TimeMachineBackup', 'rw': ['ben'], 'tm': True})) == 'ok', 'share TimeMachineBackup for ben, Time Machine on')
    ok(b.done(b.ex4('share_set', {'name': 'Public', 'guest': 'ro'})) == 'ok', 'share_set: Public becomes read-only for everyone')
    ok(b.ex4('share_set', {'name': 'Nope', 'guest': 'ro'}).get('err') == 'no_share', 'share_set refuses an unknown share')
    ok(b.ex4('share_set', {'name': 'Public', 'guest': 'yes'}).get('err') == 'bad_guest', 'share_set refuses an unknown access word')
    sh = b.ex4('shares')
    ok([(s['name'], s['guest'], s['rw'], s['ro'], s['tm'], s['exists']) for s in sh.get('shares', [])] ==
       [('Public', 'ro', [], [], False, True), ('Media', 'no', ['anna'], ['@family'], False, True), ('TimeMachineBackup', 'no', ['ben'], [], True, True)], 'shares: as set', sh.get('shares'))
    ok(set(sh.get('folders', [])) == {'SmartWare', 'Backups'}, 'the folders still unshared are still offered')

    for c in ('1.2.3.4;rm -rf', '300.1.1.1/24', '10.0.0.0/33', 'host(rw,no_root_squash)', '192.0.2.0/24 *(rw)', '', '192.0.2.0/24\n/ *(rw)'):
        r = b.ex4('export_add', {'share': 'Media', 'clients': c})
        ok(r.get('ok') is False and r.get('err') == 'bad_clients', 'export_add refuses the clients %r' % c[:16], r)
    ok(b.ex4('export_add', {'share': 'Nope', 'clients': '*'}).get('err') == 'no_share', 'export_add refuses an unknown share')
    r = b.ex4('export_add', {'share': 'Media', 'clients': '192.0.2.0/24', 'access': 'rw'})
    ok(b.done(r) == 'ok', 'export Media to the LAN', r)
    r2 = b.ex4('export_add', {'share': 'Public', 'clients': '192.0.2.20', 'squash': 'all'})
    ok(b.done(r2) == 'ok', 'export Public to one machine, everyone squashed')
    ok(b.ex4('export_add', {'share': 'Media', 'clients': '192.0.2.0/24'}).get('err') == 'exists', 'the same export twice is refused')
    ok(b.ex4('export_set', {'id': r.get('id'), 'squash': 'never'}).get('err') == 'bad_squash', 'export_set refuses an unknown squash')
    ok(b.done(b.ex4('export_set', {'id': r.get('id'), 'squash': 'none'})) == 'ok', 'export_set')
    ex = b.ex4('shares').get('exports', [])
    ok([(e['share'], e['clients'], e['access'], e['squash']) for e in ex] == [('Media', '192.0.2.0/24', 'rw', 'none'), ('Public', '192.0.2.20', 'ro', 'all')], 'exports: as set', ex)
    r3 = b.ex4('export_add', {'share': 'Public', 'clients': '*', 'access': 'rw', 'squash': 'none'})
    ok(r3.get('ok') is False and r3.get('err') == 'unsafe_export', 'v8: export_add refuses * + rw + root not squashed (any device would be root over the files)', r3)
    ok(b.ex4('export_set', {'id': r.get('id'), 'clients': '*'}).get('err') == 'unsafe_export', 'v8: export_set refuses turning the rw / no-squash export into one for *')
    ex = b.ex4('shares').get('exports', [])
    ok([(e['share'], e['clients'], e['access'], e['squash']) for e in ex] == [('Media', '192.0.2.0/24', 'rw', 'none'), ('Public', '192.0.2.20', 'ro', 'all')], 'v8: the refused calls changed nothing', ex)

    if b.emu:
        smb = b.file('/etc/config/samba4') or ''
        ok(smb.count('config sambashare') == 3 and "option path '/mnt/md1/Public'" in smb and "option path '/mnt/md1/Media'" in smb, 'samba4\'s uci file holds the three shares, each at <volume>/<name>', smb)
        ok("option read_only 'no'" not in smb and 'write_list' not in smb and 'timemachine' not in smb, 'on a read-only volume no share is writable, whatever its settings', smb)
        ok("option users 'anna @family'" in smb and "option guest_ok 'yes'" in smb and "option disable_netbios '1'" in smb and "option samba_nice '5'" in smb, 'who gets in, guest for Public, no NetBIOS, niced below the interface', smb)
        ex = b.file('/etc/exports') or ''
        ok('/mnt/md1/Media 192.0.2.0/24(ro,sync,no_subtree_check,no_root_squash)\n' in ex and '/mnt/md1/Public 192.0.2.20(ro,sync,no_subtree_check,all_squash)\n' in ex, '/etc/exports: both lines, forced read-only on a read-only volume', ex)
        pw = b.file('/etc/passwd') or ''
        ok('anna:x:1000:100:anna:/var:/bin/false\n' in pw and 'ben:x:1001:100:' in pw and pw.startswith('root:x:0:0:'), '/etc/passwd: the base system\'s lines kept, ours added without a shell', pw)
        ok('family:x:1000:anna,ben\n' in (b.file('/etc/group') or '') and 'anna:*:' in (b.file('/etc/shadow') or ''), '/etc/group and /etc/shadow: the group; no Unix password')
        calls = b.calls_text()
        ok("smbpasswd [-s] [-a] [anna]\n  stdin: %s\n  stdin: %s\n" % (secret, secret) in calls, 'the SMB password reached smbpasswd on stdin, byte for byte', calls[-600:])
        ok(all(secret not in l for l in calls.split('\n') if not l.startswith('  stdin: ')), 'and in no command line')
        ok(not [f for f in os.listdir(b.root + '/tmp/ex4') if f.startswith('job-')], 'no job spool file is left behind')
        ok(not os.path.exists(b.root + '/mnt/md1/Brand New'), 'nothing was made on the volume')

    ok(b.done(b.ex4('export_remove', {'id': r2.get('id')})) == 'ok', 'export_remove')
    ok(b.done(b.ex4('user_passwd', {'name': 'ben', 'password': 'changed long one'})) == 'ok', 'user_passwd')
    ok(b.ex4('user_passwd', {'name': 'ghost', 'password': 'changed long one'}).get('err') == 'no_user', 'user_passwd refuses an unknown person')
    ok(b.done(b.ex4('group_set', {'name': 'family', 'members': ['anna']})) == 'ok', 'group_set')
    ok(b.done(b.ex4('user_remove', {'name': 'ben'})) == 'ok', 'user_remove ben')
    sh = b.ex4('shares')
    ok([s['rw'] for s in sh.get('shares', []) if s['name'] == 'TimeMachineBackup'] == [[]], 'a removed person leaves every share\'s lists')
    ok(b.done(b.ex4('share_remove', {'name': 'TimeMachineBackup'})) == 'ok', 'share_remove')
    ok(b.done(b.ex4('group_remove', {'name': 'family'})) == 'ok', 'group_remove')
    sh = b.ex4('shares')
    ok([(s['name'], s['ro']) for s in sh.get('shares', [])] == [('Public', []), ('Media', [])] and 'TimeMachineBackup' in sh.get('folders', []), 'the share is gone, its folder is still there', sh)
    if b.emu:
        ok(os.path.isdir(b.root + '/mnt/md1/TimeMachineBackup'), 'share_remove left the folder on the volume')
        ok('smbpasswd [-x] [ben]' in b.calls_text() and 'ben:' not in (b.file('/etc/passwd') or ''), 'ben is gone from the SMB server and from /etc/passwd')


def t_services(b):
    print('-- 6. services')
    ok(b.ex4('service_set', {'id': 'telnet', 'enabled': True}).get('err') == 'bad_service', 'an id off the allow-list is refused')
    ok(b.ex4('service_set', {'id': '../../bin/sh', 'enabled': True}).get('err') == 'bad_service', 'a path as an id is refused')
    ok(b.ex4('service_set', {'id': 'ssh', 'enabled': False}).get('err') == 'trial_ssh', 'secure shell cannot be switched off during a trial')
    ok(b.done(b.ex4('service_set', {'id': 'smb', 'enabled': True})) == 'ok', 'SMB on')
    ok(b.done(b.ex4('service_set', {'id': 'nfs', 'enabled': True})) == 'ok', 'NFS on')
    sv = {x['id']: x for x in b.ex4('services').get('list', [])}
    ok(sv['smb']['enabled'] and sv['nfs']['enabled'] and sv['ssh']['enabled'] and not sv['find']['enabled'], 'services: SMB and NFS enabled now', sv)
    ok(b.done(b.ex4('service_set', {'id': 'nfs', 'enabled': False})) == 'ok', 'NFS off')
    ok(not {x['id']: x for x in b.ex4('services').get('list', [])}['nfs']['enabled'], 'services: NFS disabled again')
    if b.emu:
        c = b.calls_text()
        ok('init.d/samba4 [enable]\ninit.d/samba4 [start]' in c and 'init.d/nfsd [enable]\ninit.d/nfsd [start]' in c and 'init.d/nfsd [stop]\ninit.d/nfsd [disable]' in c, 'the helper asked the init scripts, in order')


def t_alerts(b):
    print('-- 7. e-mail alerts')
    ok(b.ex4('alerts_set', {'enabled': True}).get('err') == 'incomplete', 'alerts cannot be switched on without a server and addresses')
    for k, v, e in (('to', 'a@b.org\nBcc: x@y.org', 'bad_mail'), ('to', 'no-at-sign', 'bad_mail'), ('from', 'a b@c.org', 'bad_mail'), ('host', 'smtp.example.org; rm', 'bad_host'),
                    ('host', 'smtp\nhost evil', 'bad_host'), ('port', 70000, 'bad_port'), ('tls', 'maybe', 'bad_tls'), ('user', 'me"\npasswordeval "id', 'bad_user'),
                    ('password', 'line\nbreak', 'bad_password'), ('events', ['disk', 'moon'], 'bad_events'), ('space_pct', 10, 'bad_pct')):
        r = b.ex4('alerts_set', {k: v})
        ok(r.get('ok') is False and r.get('err') == e, 'alerts_set refuses %s=%r' % (k, str(v)[:18]), r)
    mailpw = 'app pass word 16'
    r = b.ex4('alerts_set', {'enabled': True, 'to': 'owner@example.org', 'from': 'ex4@example.org', 'host': 'smtp.example.org', 'port': 465, 'tls': 'tls',
                             'user': 'ex4@example.org', 'password': mailpw, 'events': ['disk', 'raid', 'temp'], 'space_pct': 85})
    ok(b.done(r) == 'ok', 'alerts_set: a full, valid setting', r)
    al = b.ex4('alerts')
    ok(al.get('enabled') is True and al.get('has_pass') is True and al.get('port') == 465 and al.get('tls') == 'tls' and sorted(al.get('events')) == ['disk', 'raid', 'temp'] and al.get('space_pct') == 85, 'alerts: as set', al)
    ok(mailpw not in json.dumps(al), 'the mail password is never sent back')
    ok(b.done(b.ex4('alerts_test')) == 'ok', 'alerts_test: the test message is handed to the mail program')
    if b.emu:
        ok(b.file('/etc/ex4/smtp-pass') == mailpw and oct(os.stat(b.root + '/etc/ex4/smtp-pass').st_mode & 0o777) == '0o600', 'the mail password is in its own 0600 file')
        rc = b.file('/etc/msmtprc') or ''
        ok('host smtp.example.org\nport 465\nfrom ex4@example.org\n' in rc and 'tls on\ntls_starttls off\n' in rc and 'passwordeval "cat /etc/ex4/smtp-pass"' in rc and mailpw not in rc, 'msmtprc: server, port, TLS, the password only by reference', rc)
        c = b.calls_text()
        ok('msmtp [-C]' in c and '  stdin: To: owner@example.org' in c and '  stdin: Subject: [ex4] Test message' in c and mailpw not in c, 'msmtp got the message on stdin and no password')
        open(os.path.join(os.environ['EX4_EMU_WORK'], 'msmtp.fail'), 'w').close()
        ok(b.done(b.ex4('alerts_test')) == 'fail', 'a mail server that refuses makes the test job fail, visibly')
        os.unlink(os.path.join(os.environ['EX4_EMU_WORK'], 'msmtp.fail'))
        ok((b.ex4('alerts').get('last') or {}).get('ok') is False, 'and "last" says so')


def t_system(b):
    print('-- 8. name, clock, address, the screen')
    for a, e in (({'hostname': 'Has_Underscore'}, 'bad_name'), ({'hostname': 'x' * 33}, 'bad_name'), ({'hostname': 'ok\nevil'}, 'bad_name'), ({'zonename': 'Mars/Olympus'}, 'bad_zone'), ({'zonename': '../../etc/passwd'}, 'bad_zone')):
        r = b.ex4('system_set', a)
        ok(r.get('ok') is False and r.get('err') == e, 'system_set refuses %r' % (a,), r)
    r = b.ex4('system_set', {'hostname': 'vault', 'zonename': 'America/Los_Angeles'})
    ok(b.done(r) == 'ok' and r.get('renamed') is True, 'system_set: a new name and time zone', r)
    sy = b.ex4('system')
    ok(sy.get('zonename') == 'America/Los_Angeles', 'system: the zone is stored', sy.get('zonename'))
    if b.emu:
        cfg = b.file('/etc/config/system') or ''
        ok("option hostname 'vault'" in cfg and "option timezone 'PST8PDT,M3.2.0,M11.1.0'" in cfg and "option zonename 'America/Los_Angeles'" in cfg, '/etc/config/system: name, zone name and its POSIX string', cfg)
        ok(b.file('/proc/sys/kernel/hostname') == 'vault\n' and 'init.d/system [reload]' in b.calls_text(), 'the helper applied the name and reloaded the system service')
        ok(sy.get('name') == 'vault', 'system: the new name')
    ok(b.done(b.ex4('system_set', {'hostname': 'ex4'})) == 'ok', 'and back to ex4')

    for a, e in (({'mode': 'auto'}, 'bad_mode'), ({'mode': 'static', 'addr': '192.0.2.300', 'mask': '255.255.255.0'}, 'bad_addr'), ({'mode': 'static', 'addr': '192.0.2.60', 'mask': '255.0.255.0'}, 'bad_mask'),
                 ({'mode': 'static', 'addr': '192.0.2.60', 'mask': '255.255.255.0', 'gw': 'router'}, 'bad_gw'), ({'mode': 'static', 'addr': '192.0.2.60', 'mask': '255.255.255.0', 'dns': ['1.1.1.1; reboot']}, 'bad_dns'),
                 ({'mode': 'dhcp', 'bond': 'lacp'}, 'bad_bond'), ({'mode': 'static', 'addr': "1.2.3.4'", 'mask': '255.255.255.0'}, 'bad_addr')):
        r = b.ex4('net_set', a)
        ok(r.get('ok') is False and r.get('err') == e, 'net_set refuses %r' % (a,), r)
    ok(b.ex4('net_confirm').get('err') == 'nothing', 'net_confirm with nothing waiting is refused')
    want = {'mode': 'static', 'addr': '192.0.2.60', 'mask': '255.255.255.0', 'gw': '192.0.2.1', 'dns': ['192.0.2.1', '9.9.9.9'], 'bond': 'active-backup'}
    r = b.ex4('net_set', want)
    ok(b.done(r) == 'ok' and r.get('rollback_s') == 90, 'net_set: fixed address + the two ports as one with a spare', r)
    p = b.ex4('status').get('net_pending')
    ok(isinstance(p, int) and p > 0, 'status: the change is waiting to be confirmed', p)
    ok(b.ex4('net_set', want).get('err') == 'pending', 'a second change while one waits is refused')
    if b.emu:
        n = b.file('/etc/config/network') or ''
        ok("config interface 'bond0'" in n and "option proto 'bonding'" in n and "option bonding_policy 'active-backup'" in n and "list slaves 'eth0'" in n and "list slaves 'eth1'" in n, 'network: the bond as proto-bonding reads it', n)
        ok("option device 'bond-bond0'" in n and "option proto 'static'" in n and "option ipaddr '192.0.2.60'" in n and "option gateway '192.0.2.1'" in n and "list dns '9.9.9.9'" in n, 'network: lan on the bond, fixed address', n)
        ok('init.d/network [reload]' in b.calls_text(), 'the helper reloaded the network')
        time.sleep(9)                        # emu.sh sets the wait to 6 s (90 s on the box)
        n = b.file('/etc/config/network') or ''
        ok('bond0' not in n and "option device 'br-lan'" in n and "option proto 'dhcp'" in n and 'ipaddr' not in n.split("config interface 'lan'")[1], 'unconfirmed, the old settings came back by themselves', n)
        ok(b.ex4('status').get('net_pending') is None and any(e['k'] == 'net_rollback' for e in b.ex4('events', {'since': 0}).get('events', [])), 'and the events list says so')
        ok(b.done(b.ex4('net_set', {'mode': 'dhcp', 'bond': 'active-backup'})) == 'ok', 'net_set again: the bond, address from the router')
    ok(b.ex4('net_confirm').get('ok') is True, 'net_confirm keeps a change')
    ok(b.ex4('status').get('net_pending') is None, 'nothing is pending after the confirmation')
    if b.emu:
        time.sleep(9)
        n = b.file('/etc/config/network') or ''
        ok("config interface 'bond0'" in n and "option device 'bond-bond0'" in n and "option proto 'dhcp'" in n, 'confirmed, the new settings stayed', n)
        ok(b.ex4('system').get('net', {}).get('bond') == 'active-backup', 'system: the bond is reported')

    for a, e in (({'standby': '2'}, 'bad_standby'), ({'standby': 'never'}, 'bad_standby'), ({'standby': "6'\n\toption mode 'tierA"}, 'bad_standby')):
        r = b.ex4('panel_set', a)
        ok(r.get('ok') is False and r.get('err') == e, 'panel_set refuses %r' % (a,), r)
    ok(b.ex4('panel_set', {'on': True, 'lcd': False, 'standby': '6'}).get('ok') is True, 'panel_set: feed the screen, screen off, never sleeps')
    p = b.ex4('panel')
    ok((p.get('on'), p.get('lcd'), p.get('standby')) == (True, False, '6'), 'panel: as set', p)
    if b.emu:
        cfg = b.file('/etc/config/ex4panel') or ''
        ok("option mode 'tierA'" in cfg and "option lcd_sleep_mode '1'" in cfg and "option standby '6'" in cfg, '/etc/config/ex4panel holds the option names ex4fan reads (mode, lcd_sleep_mode, standby)', cfg)
    b.ex4('panel_set', {'on': False, 'lcd': True, 'standby': '3'})
    if b.emu:
        ok("option mode 'off'" in (b.file('/etc/config/ex4panel') or ''), 'and off again: the screen is sent nothing')


def t_health(b):
    print('-- 9. the sentence, in every state')
    def level(name):
        b.scenario(name)
        return b.ex4('status').get('health') or {}
    h = level('healthy')
    ok(h.get('level') == 'ok' and h.get('why') == [], 'healthy: all is well', h)
    h = level('closed')
    ok(h.get('level') == 'closed' and h.get('why') == [{'c': 'closed'}] and b.ex4('status').get('array') is None and b.ex4('status').get('vol', {}).get('mounted') is False, 'closed: no array assembled is said plainly, not as an alarm', h)
    ok(b.ex4('share_add', {'name': 'SmartWare'}).get('err') == 'no_volume', 'closed: nothing can be shared while the volume is not open')
    h = level('rebuild')
    w = {x['c']: x for x in h.get('why', [])}
    ok(h.get('level') == 'rebuild' and 'disk_failed' not in w and abs((w.get('rebuild', {}).get('pct') or 0) - 20.4) < 0.3 and w.get('rebuild', {}).get('bay') == 4, 'rebuild: the array is rebuilding onto bay 4, 20 % done', h)
    h = level('failed')
    w = {x['c']: x for x in h.get('why', [])}
    ok(h.get('level') == 'failed' and w.get('disk_failed', {}).get('bay') == 4, 'failed: a disk has failed, bay 4', h)
    h = level('hot')
    ok(h.get('level') in ('hot',) and any(x['c'] == 'hot' and x['temp'] == 57 for x in h.get('why', [])), 'hot: the box is running hot, 57 C', h)

    print('-- 10. the one write to the data volume, and its two gates')
    b.scenario('installed')                  # volume read-write, no token
    st = b.ex4('status')
    ok(st.get('trial') is None and st.get('vol', {}).get('rw') is True, 'installed: not a trial, volume read-write')
    r = b.ex4('share_add', {'name': 'Fresh Folder'})
    ok(r.get('ok') is False and r.get('err') == 'rw_gate', 'a new folder is refused without the owner\'s read-write token', r)
    if b.emu:
        ok(not os.path.exists(b.root + '/mnt/md1/Fresh Folder'), 'and nothing was made')
    if b.emu:                                # v8: the token is checked by its CONTENT, not its existence
        boot = open(b.root + '/proc/sys/kernel/random/boot_id').read().strip()
        for text, mode, why in (('test token\n', 0o600, 'a token with the wrong words'), ('rw-ok 00000000-0000-0000-0000-000000000000\n', 0o600, 'a token from another boot'),
                                ('rw-ok %s\n' % boot, 0o644, 'the right words in a file others can read'), ('', 0o600, 'an empty file')):
            with open(b.root + '/tmp/ex4-rw-ok', 'w') as f:
                f.write(text)
            os.chmod(b.root + '/tmp/ex4-rw-ok', mode)
            time.sleep(1.1)
            r = b.ex4('share_add', {'name': 'Fresh Folder'})
            ok(r.get('ok') is False and r.get('err') == 'rw_gate' and not os.path.exists(b.root + '/mnt/md1/Fresh Folder'), 'v8: %s opens nothing (rw_gate, no folder made)' % why, r)
        os.unlink(b.root + '/tmp/ex4-rw-ok')
        os.symlink('/proc/sys/kernel/random/boot_id', b.root + '/tmp/ex4-rw-ok')
        r = b.ex4('share_add', {'name': 'Fresh Folder'})
        ok(r.get('ok') is False and r.get('err') == 'rw_gate', 'v8: a symbolic link as the token opens nothing', r)
        os.unlink(b.root + '/tmp/ex4-rw-ok')
    b.scenario('rw')                         # the token is there
    r = b.ex4('share_add', {'name': 'Fresh Folder', 'rw': ['anna']})
    ok(b.done(r) == 'ok' and r.get('made') is True, 'with read-write AND the token, the folder is made', r)
    if b.emu:
        ok(os.path.isdir(b.root + '/mnt/md1/Fresh Folder') and sorted(os.listdir(b.root + '/mnt/md1')) == ['Backups', 'Fresh Folder', 'Media', 'Public', 'SmartWare', 'TimeMachineBackup'], 'exactly one new folder, directly under the volume')
        smb = b.file('/etc/config/samba4') or ''
        ok("option path '/mnt/md1/Fresh Folder'" in smb and "option write_list 'anna'" in smb, 'on a read-write volume the share is writable for anna', smb)
        ok('/mnt/md1/Media 192.0.2.0/24(rw,' in (b.file('/etc/exports') or ''), 'and the NFS export is read-write as set')
    ok(b.done(b.ex4('share_remove', {'name': 'Fresh Folder'})) == 'ok', 'share_remove')
    if b.emu:
        ok(os.path.isdir(b.root + '/mnt/md1/Fresh Folder'), 'removing the share kept the folder')
    b.scenario('trial')
    ok(b.ex4('status').get('health', {}).get('level') == 'watch', 'back to the trial: one disk wants watching')


def t_watch(b):
    print('-- 9b. the watcher (cron): SMART without waking a drive, free space, alerts on a change')
    if not b.emu:
        print('  (only against the real backend: the fake has no helper)')
        return
    helper, seed = b.root + '/usr/libexec/ex4/ex4-apply', b.root + '/tmp/ex4/smart-seed/'
    def watch(age=3600):
        for d in 'abcd':                     # make the cache look half an hour old, so SMART is asked again
            p = b.root + '/tmp/ex4/smart/sd%s.json' % d
            os.utime(p, (time.time() - age, time.time() - age))
        return subprocess.run([helper, 'watch'], capture_output=True, text=True, timeout=120)
    def seed_set(dev, **attrs):
        j = json.load(open(seed + dev + '.json'))
        for k, v in attrs.items():
            if k == 'passed':
                j['passed'] = v
            else:
                j['a'][k[1:]] = v
        json.dump(j, open(seed + dev + '.json', 'w'))
    n0 = b.calls_text().count('smartctl [')
    r = watch()
    c = b.calls_text()
    ok(r.returncode == 0, 'ex4-apply watch runs', r.stderr[-300:])
    ok(c.count('smartctl [') == n0 + 4 and 'smartctl [-n standby --json=c -i -A -H /dev/sda]' in c, 'it asked each of the four drives, with -n standby (a sleeping drive stays asleep), for counters only')
    ok(not re.search(r'smartctl \[[^\]]*(-t |--test|-s |--smart|-o |-X|-S )', c), 'no self-test was started and no drive setting changed')
    j = json.loads(b.file('/tmp/ex4/smart/sdd.json'))
    ok(j['a']['197'] == 1 and j['a']['9'] == 99812 and j['serial'] == 'WD-WCC4E0000D04' and j['power'] == 'active', 'the SMART cache the page reads is rewritten from the drive\'s answer', j)
    ok((b.file('/tmp/ex4/space') or '').startswith('%d %d ' % (truth.KIB_TOTAL, truth.KIB_USED)), 'free space comes from one df here, never from the page')
    ok(json.loads(b.file('/tmp/ex4/watch.state'))['disks'] == {'sda': 'ok', 'sdb': 'ok', 'sdc': 'ok', 'sdd': 'watch'}, 'the watcher\'s own state')
    ev = [e for e in b.ex4('events', {'since': 0}).get('events', []) if e['k'] == 'disk_watch']
    ok(len(ev) == 1 and ev[0]['a'].get('dev') == 'sdd' and ev[0]['a'].get('pending') == 1, 'first sight of bay 4\'s unreadable sector is an event', ev)
    ok('  stdin: Subject: [ex4] Disk sdd wants watching' in c and '  stdin: To: owner@example.org' in c, 'and an e-mail (alerts are on, "disk" is ticked)')
    m0 = c.count('msmtp [')
    watch(age=10)                            # five minutes later: nothing changed
    c = b.calls_text()
    ok(c.count('msmtp [') == m0 and c.count('smartctl [') == n0 + 4, 'an unchanged box sends nothing and, inside 30 minutes, asks the drives nothing')
    seed_set('sdb', a5=8)                    # bay 2 starts moving sectors
    watch()
    c = b.calls_text()
    ok(c.count('msmtp [') == m0 + 1 and '  stdin: Subject: [ex4] Disk sdb wants watching' in c and 'moved sectors 8' in c, 'a second disk going bad is told once', c[-500:])
    b.scenario('failed')
    watch(age=10)
    c = b.calls_text()
    ok('  stdin: Subject: [ex4] A disk has dropped out of the array' in c and 'Your files are still safe' in c, 'a degraded array is told, with what it means for the files')
    b.scenario('hot')
    watch(age=10)
    c = b.calls_text()
    ok('  stdin: Subject: [ex4] A disk is running hot' in c and '  stdin: Subject: [ex4] The array is whole again' in c, 'heat is told; so is the array coming back')
    ok(not any(l.startswith('  stdin: Subject:') and 'full' in l for l in c.split('\n')), '"space" is not ticked: no space mail')
    seed_set('sdb', a5=0)
    b.scenario('trial')
    watch()


def t_account(b):
    print('-- 11. the administrator: password change, sign out everywhere, events, bundle')
    r = b.ex4('keeper_passwd', {'old': 'not the password', 'hash': crypt5(PW2, 'NewSalt.99')})
    ok(r.get('ok') is False and r.get('err') == 'bad', 'keeper_passwd refuses a wrong current password', r)
    ok(b.ex4('keeper_passwd', {'old': PW1, 'hash': PW2}).get('err') == 'bad_hash', 'keeper_passwd refuses a new password that is not a hash')
    time.sleep(1.2)
    other = b.ex4('sign_in', {'username': ADMIN, 'password': PW1}, Z).get('sid', Z)       # v8: a second session, elsewhere
    r = b.ex4('keeper_passwd', {'old': PW1, 'hash': crypt5(PW2, 'NewSalt.99')})
    ok(r.get('ok') is True, 'keeper_passwd with the right current password', r)
    time.sleep(0.5)
    ok(other != Z and b.call('ex4', 'status', {}, other)[0] != 0 and r.get('ended', 0) >= 1, 'v8: the password change ended the OTHER session', (r, other))
    ok(b.call('ex4', 'status')[0] == 0, 'v8: ... and the session that changed it stays signed in')
    old_sid = b.sid
    r = b.ex4('sign_in', {'username': ADMIN, 'password': PW1}, Z)
    ok(r.get('ok') is False, 'the old password no longer signs in', r)
    time.sleep(1.2)
    r = b.ex4('sign_in', {'username': ADMIN, 'password': PW2}, Z)
    ok(r.get('ok') is True, 'the new one does', r)
    second = r.get('sid', Z)
    r = b.ex4('signout_all')
    ok(r.get('ok') is True and r.get('n', 0) >= 2, 'signout_all', r)
    time.sleep(0.5)
    ok(b.call('ex4', 'status', {}, old_sid)[0] != 0 and b.call('ex4', 'status', {}, second)[0] != 0, 'every session is dead afterwards')
    r = b.ex4('sign_in', {'username': ADMIN, 'password': PW2}, Z)
    b.sid = r.get('sid', Z)
    ok(r.get('ok') is True, 'signing in again works')
    code, _ = b.call('session', 'destroy')
    ok(code == 0 and b.call('ex4', 'status')[0] != 0, 'sign out: the session ends itself')
    b.sid = b.ex4('sign_in', {'username': ADMIN, 'password': PW2}, Z).get('sid', Z)

    ev = b.ex4('events', {'since': 0}).get('events', [])
    kinds = [e['k'] for e in ev]
    ok(all(k in kinds for k in ('claimed', 'signin', 'share_add', 'user_add', 'service_set', 'alerts_set', 'net_set', 'keeper_passwd', 'signout_all')) and all(isinstance(e['t'], int) for e in ev), 'events: what happened, with times', kinds)
    ok(PW1 not in json.dumps(ev) and PW2 not in json.dumps(ev), 'no password in the events')
    ok(b.done(b.ex4('support_bundle')) == 'ok', 'support_bundle')
    t = b.ex4('bundle_get').get('text', '')
    ok('ex4 support bundle' in t and len(t) > 200, 'bundle_get returns it')
    if b.emu:
        ok('192.0.2.60' not in t and '192.0.2.x' in t and 'WD-WCC4E' not in t and 'SERIAL-sda' in t, 'addresses and serial numbers are masked in the bundle', t[:400])
        ok('logread' in b.calls_text(), 'the helper read the log')

    print('-- 12. trial and power')
    ok(b.ex4('trial_stay').get('ok') is True and b.ex4('status').get('trial', {}).get('stay') is True and b.ex4('status').get('trial', {}).get('left_s') is None, 'trial_stay: the clock stops')
    if b.emu:
        ok(os.path.exists(b.root + '/tmp/ex4-stay'), '/tmp/ex4-stay exists')
        before = b.calls_text()
        for _ in range(40):
            b.ex4('status'); b.ex4('disks'); b.ex4('array'); b.ex4('shares'); b.ex4('users'); b.ex4('panel'); b.ex4('alerts'); b.ex4('events', {'since': 0})
        kids = subprocess.run(['ps', '--ppid', os.environ.get('EX4_EMU_RPCD', '1'), '-o', 'pid='], capture_output=True, text=True).stdout.split()
        ok(b.calls_text() == before and not kids, '320 read calls started no process at all')
    r = b.ex4('restart')
    ok(r.get('ok') is True, 'restart is accepted', r)
    if b.emu:
        b.wait_job(r['job'])
        c = b.calls_text().split('\n')
        want = ['init.d/samba4 [stop]', 'init.d/nfsd [stop]', 'sync', 'umount [%s/mnt/md1]' % b.root, 'mdadm [--stop] [/dev/md1]', 'sync', 'reboot']
        idx = []
        for w in want:
            idx.append(next((i for i in range(idx[-1] + 1 if idx else 0, len(c)) if c[i] == w), -1))
        ok(all(i >= 0 for i in idx), 'restart = stop sharing, flush, unmount, stop the array, THEN reboot', c[-12:])
        ok(not any(re.match(r'mdadm \[--(create|grow|add|fail|remove|zero|assemble|build)', l) for l in c) and not any(l.startswith(('mkfs', 'fsck', 'dd ', 'tune2fs', 'mount ')) for l in c), 'in the whole run no command that could write the array or a file system was asked for')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--url')
    ap.add_argument('--emu', action='store_true', help='take the addresses from emu.sh and check files + commands too')
    ap.add_argument('--slow', action='store_true')
    a = ap.parse_args()
    if a.emu:
        b = Box(os.environ['EX4_EMU_URL'], os.environ['EX4_EMU_ROOT'], os.environ['EX4_EMU_CALLS'])
    elif a.url:
        b = Box(a.url)
    else:
        ap.error('--url or --emu')
    print('backend: %s (%s)' % (b.url, 'the real rpcd + ex4.uc under qemu-arm' if b.emu else 'fakebox.py'))
    for t in (t_doors, lambda x: t_claim(x, a.slow), t_signin, t_read, t_shares, t_services, t_alerts, t_system, t_health, t_watch, t_account):
        try:
            t(b)
        except Exception as e:           # a crash in one block is a failure of that block, the rest still runs
            ok(False, 'test block crashed: %r' % (e,))
    print('\n%d passed, %d failed%s' % (len(PASS), len(FAIL), (': ' + '; '.join(FAIL[:12])) if FAIL else ''))
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
