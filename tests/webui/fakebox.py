#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""fakebox.py : a tiny local stand-in for the box, for working on the page and for the page tests.

  python3 tests/webui/fakebox.py [--port 18490] [--scenario trial] [--claimed]
  then open  http://127.0.0.1:18490/

It serves webui/dist/index.html and answers POST /ubus the way the box does: JSON-RPC, rpcd-style sessions, the SAME
access lists (it reads webui/backend/acl/*.json), and a Python model of every `ex4` method fed from the sample box in
truth.py. It listens on 127.0.0.1 only, needs nothing but python3, and touches nothing outside its own memory.

It is a MODEL, not the backend: the real one is webui/backend/ex4.uc. What keeps the model honest is that
tests/webui/api_test.py runs the same list of checks against both (this file, and the real rpcd under qemu via
emu/emu.sh). When ex4.uc changes, change this, and run both.

Test controls (not part of the product; only this fake has them):
  GET  /_test/claim                      the eight-digit setup code (v9)
  POST /_test/scenario {"name": "copy"}  switch the sample box's state (truth.py lists them)
  POST /_test/reset {"claimed": true}    start over; claimed = an administrator `keeper` / `tide and lamp, 12+` exists
  POST /_test/expire                     drop every session (as 15 idle minutes would)
--claimed starts that way.
"""
import argparse, hashlib, json, os, random, re, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import truth                                # noqa: E402
from sha256crypt import crypt5, verify, RX as RX_HASH   # noqa: E402

WEBUI = os.path.join(HERE, '..', '..', 'webui')
Z = '0' * 32
RX_SHARE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9 _.-]{0,30}[A-Za-z0-9_.-]$|^[A-Za-z0-9]$')
RX_USER = re.compile(r'^[a-z][a-z0-9_-]{0,30}$')
RX_HOST = re.compile(r'^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$')
RX_CLIENT = re.compile(r'^(\*|[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?)$')
RX_MAIL = re.compile(r'^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}$')
RX_DNSNAME = re.compile(r'^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$')
RESERVED = ['global', 'homes', 'printers', 'ipc$', 'print$', 'lost+found']
SYSTEM_NAMES = ['root', 'daemon', 'ftp', 'network', 'nobody', 'ntp', 'dnsmasq', 'logd', 'ubus', 'adm', 'mail', 'dialout', 'audio', 'www-data', 'users', 'nogroup']
SERVICES = ['smb', 'nfs', 'find', 'ssh', 'time']
ZONES = [l.split()[0] for l in open(os.path.join(WEBUI, 'backend', 'share', 'zones')) if l.strip()]
HOT_C = 55
ADMIN, ADMIN_PW = 'keeper', 'tide and lamp, 12+'
UNSAFE_EXPORT = 'Writable, open to every machine (*) and with root not squashed would give any device on the network root over these files. Name the machines, keep it read-only, or squash root.'


def isstr(v, n=256):
    return isinstance(v, str) and len(v) <= n


def full(rx, v):
    return rx.fullmatch(v) is not None        # fullmatch: '$' alone would let a trailing newline through


def fail(err, msg):
    return {'ok': False, 'err': err, 'msg': msg}


def ip_ok(s):
    return isstr(s, 15) and re.fullmatch(r'[0-9]{1,3}(\.[0-9]{1,3}){3}', s) is not None and all(int(x) <= 255 for x in s.split('.'))


def mask_ok(s):
    if not ip_ok(s):
        return False
    v = 0
    for x in s.split('.'):
        v = v << 8 | int(x)
    return v != 0 and (((~v) & 0xffffffff) + 1) & (~v & 0xffffffff) == 0


def printable(s):
    return all(32 <= ord(c) <= 126 for c in s)


def has_ctl(s):
    return any(ord(c) < 32 or ord(c) == 127 for c in s)


class Fake:
    def __init__(self, scenario='trial', claimed=False):
        self.lock = threading.RLock()
        acl = json.load(open(os.path.join(WEBUI, 'backend', 'acl', 'ex4.json')))['ex4']
        un = json.load(open(os.path.join(WEBUI, 'backend', 'acl', 'unauthenticated.json')))['unauthenticated']
        self.acl_none = un['read']['ubus']
        self.acl_sess = {}
        for part in ('read', 'write'):
            for obj, ms in acl[part]['ubus'].items():
                self.acl_sess.setdefault(obj, set()).update(ms)
        self.reset(scenario, claimed)

    def reset(self, scenario='trial', claimed=False):
        with self.lock:
            self.scn, self.t0, self.seq = scenario, time.time(), 0
            self.claimed, self.admin, self.hash = False, None, None
            self.sessions, self.fails, self.locked_until = {}, 0, 0.0
            self.code, self.claim_fails, self.claim_locked = None, 0, 0.0
            self.shares, self.users, self.groups, self.exports, self.exp_n = [], [], [], [], 0
            self.enabled = {'ssh', 'time'}
            self.alerts = {'enabled': False, 'to': '', 'from': '', 'host': '', 'port': 587, 'tls': 'starttls', 'user': '', 'events': ['disk', 'raid', 'temp', 'space'], 'space_pct': 90}
            self.mailpw, self.alert_last = None, None
            self.name, self.zone = 'ex4', 'UTC'
            self.net = {'mode': 'dhcp', 'addr': '', 'mask': '', 'gw': '', 'dns': [], 'bond': 'none'}
            self.pending = None            # (until, the settings to go back to)
            self.panel = {'on': False, 'lcd': True, 'standby': '3'}
            self.events, self.jobs, self.job_n, self.stay, self.bundle = [], [], 0, False, None
            self.rev = {k: 1 for k in ('disks', 'shares', 'users', 'services', 'alerts', 'system', 'panel')}
            self.extra_folders = []
            if claimed:
                self.claimed, self.admin, self.hash = True, ADMIN, crypt5(ADMIN_PW, 'FakeBoxSalt01')
                self.ev('claimed', {'admin': ADMIN})

    # ---- small things
    def box(self):
        return truth.box(self.scn)

    def ev(self, k, a=None):
        self.events.append({'t': int(time.time()), 'k': k, 'a': a or {}})
        del self.events[:-200]

    def bump(self, *names):
        for n in names:
            self.rev[n] += 1
        self._snap = None

    def job(self, what, msg='', ok=True):
        self.job_n += 1
        self.jobs.append({'id': self.job_n, 'what': what, 'state': 'run', 'msg': None, '_done': time.time() + 0.25, '_ok': ok, '_msg': msg})
        del self.jobs[:-12]
        self._snap = None
        return self.job_n

    def jobs_now(self):
        out = []
        for j in self.jobs:
            if j['state'] == 'run' and time.time() >= j['_done']:
                j['state'], j['msg'] = ('ok' if j['_ok'] else 'fail'), j['_msg']
                self.bump(*self.rev.keys())
            out.append({'id': j['id'], 'what': j['what'], 'state': j['state'], 'msg': j['msg']})
        return out

    def vol(self):
        b = self.box()
        v = {'path': b['vol']['path'], 'mounted': b['vol']['mounted'], 'rw': b['vol']['rw'], 'dev': '/dev/md1' if b['vol']['mounted'] else None}
        if v['mounted']:
            v.update(total_kb=truth.KIB_TOTAL, used_kb=truth.KIB_USED, free_kb=truth.KIB_TOTAL - truth.KIB_USED)
        else:
            v.update(total_kb=None, used_kb=None, free_kb=None)
        return v

    def folders(self):
        b = self.box()
        return (b['folders'] + self.extra_folders) if b['vol']['mounted'] else []

    def disks(self):
        b, out = self.box(), []
        for d in b['disks']:
            member = b['array']['members'].get(d['dev']) if b['array'] else None
            passed = d['pending'] < 40
            v = 'fail' if (member and 'faulty' in member) or not passed else 'watch' if d['realloc'] or d['pending'] or d['uncorrect'] else 'ok'
            slot = None if not b['array'] else (str(sorted(b['array']['members']).index(d['dev'])) if member == 'in_sync' else 'none')
            out.append({'bay': d['bay'], 'dev': d['dev'], 'model': d['model'], 'serial': d['serial'], 'size_b': truth.DISK_SECTORS * 512, 'temp': d['temp'], 'member': member, 'slot': slot,
                        'power': 'active', 'smart_t': int(time.time()) - b['smart_age'], 'passed': passed, 'hours': d['hours'], 'starts': d['starts'], 'realloc': d['realloc'],
                        'pending': d['pending'], 'uncorrect': d['uncorrect'], 'crc': d['crc'], 'load': d['load'], 'v': v})
        return out

    def array(self):
        a = self.box()['array']
        if not a:
            return None
        pct = int(1000.0 * a['done'][0] / a['done'][1]) / 10.0 if a['done'] else None
        return {'dev': a['dev'], 'level': a['level'], 'state': a['state'], 'degraded': a['degraded'], 'disks': a['disks'], 'action': a['action'], 'pct': pct,
                'speed_kb': a['speed_kb'], 'size_kb': truth.MD_KIB, 'ro': a['ro']}

    def health(self, arr, vol, dl, b):
        why = []
        if not arr:
            why.append({'c': 'closed'})
        else:
            tol = 1
            if arr['state'] in ('inactive', 'clear', 'suspended') or arr['degraded'] > tol:
                why.append({'c': 'array_down', 'state': arr['state']})
            elif arr['degraded'] > 0:
                bay = None
                for d in dl:
                    if d['member'] is None or 'in_sync' not in d['member']:
                        bay = d['bay']
                if arr['action'] == 'recover':
                    why.append({'c': 'rebuild', 'bay': bay, 'pct': arr['pct'], 'action': arr['action'], 'speed_kb': arr['speed_kb']})
                else:
                    why.append({'c': 'disk_failed', 'bay': bay})
        hot = max(d['temp'] for d in b['disks'])
        if hot >= HOT_C:
            why.append({'c': 'hot', 'temp': hot})
        for d in dl:
            if d['v'] == 'fail' and not (arr and arr['degraded'] > 0):
                why.append({'c': 'disk_failed', 'bay': d['bay']})
            elif d['v'] == 'watch':
                why.append({'c': 'disk_watch', 'bay': d['bay'], 'pending': d['pending'], 'realloc': d['realloc'], 'uncorrect': d['uncorrect']})
        rank = {'closed': 1, 'check': 0, 'disk_watch': 2, 'full': 2, 'micro_silent': 2, 'hot': 3, 'fan_stopped': 3, 'rebuild': 4, 'disk_failed': 5, 'array_down': 6}
        lv = max([rank.get(w['c'], 0) for w in why] or [0])
        return {'level': ['ok', 'closed', 'watch', 'hot', 'rebuild', 'failed', 'down'][lv], 'why': why}

    def net_pending(self):
        if self.pending and time.time() >= self.pending[0]:
            self.net, self.pending = self.pending[1], None
            self.ev('net_rollback')
            self.bump('system')
        return max(1, int(self.pending[0] - time.time())) if self.pending else None

    # ---- read methods
    def m_status(self, a):
        b = self.box()
        t = int(time.time())
        if getattr(self, '_snap', None) and time.time() - self._snap_at < 1.0:
            return self._snap
        self.seq += 1
        arr, dl, vol = self.array(), self.disks(), self.vol()
        jit = (lambda v: int(v * random.uniform(0.86, 1.06))) if self.scn == 'copy' else (lambda v: int(v * random.uniform(0.5, 1.5)))
        up = b['up'] + int(time.time() - self.t0)
        self._snap = {
            'seq': self.seq, 'now': t, 'up': up, 'name': self.name, 'cpu': round(min(1.0, b['cpu'] * random.uniform(0.97, 1.03)), 3), 'load': b['load'],
            'mem': {'total_kb': b['mem_total_kb'], 'avail_kb': b['mem_avail_kb']}, 'net': {'rx': jit(b['rx']), 'tx': jit(b['tx'])}, 'io': {'rd': 0, 'wr': jit(b['rx']) if self.scn == 'copy' and vol['rw'] else 0},
            'ports': b['ports'], 'array': arr, 'vol': vol,
            'clim': {'fan': b['fan'], 'rpm': b['rpm'], 'board': b['board'], 'disks': {d['dev']: d['temp'] for d in b['disks']}, 'micro': 'answers', 'hot': max(d['temp'] for d in b['disks'])},
            'health': self.health(arr, vol, dl, b), 'disks': [{'bay': d['bay'], 'dev': d['dev'], 'temp': d['temp'], 'v': d['v']} for d in dl],
            'trial': None if b['trial_min'] is None else {'stay': self.stay, 'left_s': None if self.stay else max(0, b['trial_min'] * 60 - up)},
            'net_pending': self.net_pending(), 'addr': b['addr'], 'lan': {'mode': self.net['mode'], 'bond': self.net['bond']},
            'jobs': self.jobs_now(), 'rev': dict(self.rev, events=sum(len(json.dumps(e)) for e in self.events)),
        }
        self._snap_at = time.time()
        return self._snap

    def m_events(self, a):
        since = a.get('since') or 0
        return {'events': [e for e in self.events if e['t'] >= since][-200:]}

    def m_disks(self, a):
        return {'disks': self.disks(), 'hot_c': HOT_C}

    def m_array(self, a):
        arr, b = self.array(), self.box()
        if not arr:
            return {'array': None, 'vol': self.vol(), 'auto_check': False}
        raw = b['array']
        dl = self.disks()
        arr['members'] = [{'dev': d['dev'], 'part': d['dev'] + '2', 'bay': d['bay'], 'slot': d['slot'], 'state': raw['members'][d['dev']]} for d in dl]
        arr.update(chunk_kb=raw['chunk_kb'], mismatch=raw['mismatch'], bitmap=raw['bitmap'], meta=raw['meta'])
        return {'array': arr, 'vol': self.vol(), 'auto_check': False}

    def m_shares(self, a):
        v = self.vol()
        vol = {'path': v['path'], 'mounted': v['mounted'], 'rw': v['rw'], 'dev': v['dev'], 'gate': self.box()['vol']['gate']}
        fl = self.folders()
        used = {s['name'].lower() for s in self.shares}
        return {'volume': vol, 'engine': 'samba4', 'nfs': True,
                'shares': [dict(s, exists=vol['mounted'] and s['name'] in fl) for s in self.shares], 'exports': list(self.exports),
                'folders': sorted(f for f in fl if f.lower() not in used)}

    def m_users(self, a):
        return {'admin': self.admin, 'users': list(self.users), 'groups': list(self.groups)}

    def m_services(self, a):
        mem = {'smb': 9420, 'nfs': 1180, 'find': 1464, 'ssh': 1052, 'time': 876}
        return {'trial': self.box()['trial_min'] is not None,
                'list': [{'id': i, 'present': True, 'enabled': i in self.enabled, 'running': i in self.enabled, 'rss_kb': mem[i] if i in self.enabled else None} for i in SERVICES]}

    def m_alerts(self, a):
        return dict(self.alerts, has_pass=bool(self.mailpw), sender=True, last=self.alert_last)

    def m_system(self, a):
        b = self.box()
        up = b['up'] + int(time.time() - self.t0)
        fp = hashlib.sha256(('fake certificate of ' + self.name).encode()).hexdigest().upper()
        return {'name': self.name, 'zonename': self.zone, 'zones': sorted(ZONES), 'admin': self.admin, 'version': {'openwrt': '25.12.6', 'kernel': '6.12.112', 'ui': '8.0'}, 'up': up, 'now': int(time.time()),
                'trial': None if b['trial_min'] is None else {'stay': self.stay, 'left_s': None if self.stay else max(0, b['trial_min'] * 60 - up)},
                'cert': {'fp': ':'.join(fp[i:i + 4] for i in range(0, 64, 4)), 'names': [self.name, self.name + '.local'], 'made': int(self.t0) - 86400 * 3, 'days': 825},
                'net': dict(self.net, device='bond-bond0' if self.net['bond'] != 'none' else 'br-lan', ports=b['ports'], live=b['addr'], pending=self.net_pending())}

    def m_panel(self, a):
        b = self.box()
        watch = [d['dev'] for d in b['disks'] if d['pending'] or d['realloc']]
        sent = {'name': self.name, 'ip1': b['addr'], 'fw': 'OpenWrt 25.12.6', 'health': ('Watch ' + ' '.join(watch)) if watch else 'Good', 'free': '10.803 TB', 'used': '0', 'vol': 'normal',
                'fan': '%drpm' % b['rpm'], 'temp': '%d %d' % (max(d['temp'] for d in b['disks']), b['board'])}
        on = self.panel['on']                  # the real daemon fills `sent` only while it feeds the screen
        return {'tier': 'A', 'on': on, 'live': on, 'lcd': self.panel['lcd'], 'standby': self.panel['standby'], 'standby_codes': ['0', '3', '6'], 'sent': sent if on else {}, 'sent_age_s': 8, 'daemon': True}

    def m_bundle_get(self, a):
        return {'ok': True, 'text': self.bundle} if self.bundle else fail('none', 'No bundle has been made yet.')

    # ---- shares, people, groups, exports
    def find(self, lst, name):
        return next((x for x in lst if x['name'] == name), None) if isstr(name, 40) else None

    def who_ok(self, lst):
        if not isinstance(lst, list):
            return None
        out = []
        for w in lst:
            if not isstr(w, 40):
                return None
            if (w[1:] not in [g['name'] for g in self.groups]) if w.startswith('@') else (w not in [u['name'] for u in self.users]):
                return None
            if w not in out:
                out.append(w)
        return out

    def share_fields(self, a, into):
        if a.get('guest') is not None:
            if a['guest'] not in ('no', 'ro', 'rw'):
                return fail('bad_guest', 'Everyone can be: no, ro or rw.')
            into['guest'] = a['guest']
        for k in ('rw', 'ro'):
            if a.get(k) is not None:
                l = self.who_ok(a[k])
                if l is None:
                    return fail('bad_who', 'A person or group on that list does not exist.')
                into[k] = l
        if a.get('tm') is not None:
            into['tm'] = bool(a['tm'])
        return None

    def m_share_add(self, a):
        name = a.get('name')
        if not isstr(name, 32) or not full(RX_SHARE, name) or name.lower() in RESERVED or '..' in name:
            return fail('bad_name', 'A share name is 1 to 32 letters, digits, spaces, dots, dashes or underscores, and starts with a letter or digit.')
        if len(self.shares) >= 32:
            return fail('too_many', 'This box offers at most 32 shares.')
        if any(s['name'].lower() == name.lower() for s in self.shares):
            return fail('exists', 'A share with that name already exists.')
        f = {'name': name, 'guest': 'no', 'rw': [], 'ro': [], 'tm': False}
        bad = self.share_fields(a, f)
        if bad:
            return bad
        v, made = self.vol(), False
        if not v['mounted']:
            return fail('no_volume', 'The data volume is not open, so there is no folder to share yet.')
        if name not in self.folders():
            if not v['rw']:
                return fail('read_only', 'The volume is open read-only. Folders that already exist can be shared; a new one cannot be made.')
            if not self.box()['vol']['gate']:
                return fail('rw_gate', "Making a new folder writes to the array. That needs the owner's read-write token on the box (see SAFETY.md).")
            self.extra_folders.append(name)
            made = True
        self.shares.append(f)
        self.ev('share_add', {'name': name, 'made': made})
        self.bump('shares')
        return {'ok': True, 'made': made, 'job': self.job('shares')}

    def m_share_set(self, a):
        s = self.find(self.shares, a.get('name'))
        if not s:
            return fail('no_share', 'No such share.')
        f = {}
        bad = self.share_fields(a, f)
        if bad:
            return bad
        s.update(f)
        self.ev('share_set', {'name': s['name']})
        self.bump('shares')
        return {'ok': True, 'job': self.job('shares')}

    def m_share_remove(self, a):
        s = self.find(self.shares, a.get('name'))
        if not s:
            return fail('no_share', 'No such share.')
        self.exports = [e for e in self.exports if e['share'] != s['name']]
        self.shares.remove(s)
        self.ev('share_remove', {'name': s['name']})
        self.bump('shares')
        return {'ok': True, 'job': self.job('shares')}

    def export_fields(self, a, into):
        if a.get('clients') is not None:
            c = a['clients']
            if not isstr(c, 20) or not full(RX_CLIENT, c):
                return fail('bad_clients', 'Clients are one address, a range like 192.0.2.0/24, or * for anyone.')
            if c != '*':
                ip, _, pre = c.partition('/')
                if any(int(x) > 255 for x in ip.split('.')) or (pre and int(pre) > 32):
                    return fail('bad_clients', 'That is not an address.')
            into['clients'] = c
        if a.get('access') is not None:
            if a['access'] not in ('ro', 'rw'):
                return fail('bad_access', 'Access is ro or rw.')
            into['access'] = a['access']
        if a.get('squash') is not None:
            if a['squash'] not in ('root', 'all', 'none'):
                return fail('bad_squash', 'Squash is root, all or none.')
            into['squash'] = a['squash']
        return None

    def m_export_add(self, a):
        if not self.find(self.shares, a.get('share')):
            return fail('no_share', 'No such share.')
        if len(self.exports) >= 32:
            return fail('too_many', 'At most 32 NFS exports.')
        f = {'access': 'ro', 'squash': 'root'}
        bad = self.export_fields(a, f)
        if bad:
            return bad
        if not f.get('clients'):
            return fail('bad_clients', 'Say who may mount it.')
        if f['clients'] == '*' and f['access'] == 'rw' and f['squash'] == 'none':      # v8: as ex4.uc's export_unsafe()
            return fail('unsafe_export', UNSAFE_EXPORT)
        if any(e['share'] == a['share'] and e['clients'] == f['clients'] for e in self.exports):
            return fail('exists', 'That share is already exported to those clients.')
        self.exp_n += 1
        e = {'id': 'cfg%06x' % (0x0a0000 + self.exp_n), 'share': a['share'], 'clients': f['clients'], 'access': f['access'], 'squash': f['squash']}
        self.exports.append(e)
        self.ev('export_add', {'share': a['share'], 'clients': f['clients']})
        self.bump('shares')
        return {'ok': True, 'id': e['id'], 'job': self.job('shares')}

    def m_export_set(self, a):
        e = next((x for x in self.exports if x['id'] == a.get('id')), None)
        if not e:
            return fail('no_export', 'No such export.')
        f = {}
        bad = self.export_fields(a, f)
        if bad:
            return bad
        m = dict(e, **f)
        if m['clients'] == '*' and m['access'] == 'rw' and m['squash'] == 'none':
            return fail('unsafe_export', UNSAFE_EXPORT)
        e.update(f)
        self.bump('shares')
        return {'ok': True, 'job': self.job('shares')}

    def m_export_remove(self, a):
        e = next((x for x in self.exports if x['id'] == a.get('id')), None)
        if not e:
            return fail('no_export', 'No such export.')
        self.exports.remove(e)
        self.ev('export_remove', {'share': e['share']})
        self.bump('shares')
        return {'ok': True, 'job': self.job('shares')}

    def taken(self, name):
        return name in SYSTEM_NAMES or self.find(self.users, name) or self.find(self.groups, name)

    def m_user_add(self, a):
        n = a.get('name')
        if not isstr(n, 31) or not full(RX_USER, n):
            return fail('bad_name', 'A user name is 1 to 31 lower-case letters, digits, dashes or underscores, and starts with a letter.')
        if self.taken(n):
            return fail('exists', 'That name is taken.')
        if len(self.users) >= 64:
            return fail('too_many', 'At most 64 people.')
        p = a.get('password')
        if not isstr(p, 128) or len(p) < 8 or has_ctl(p):
            return fail('bad_password', 'A password is 8 to 128 characters.')
        self.users.append({'name': n, 'uid': max([u['uid'] for u in self.users] + [999]) + 1})
        self.ev('user_add', {'name': n})
        self.bump('users')
        return {'ok': True, 'job': self.job('users', 'password set for ' + n)}

    def m_user_passwd(self, a):
        if not self.find(self.users, a.get('name')):
            return fail('no_user', 'No such person.')
        p = a.get('password')
        if not isstr(p, 128) or len(p) < 8 or has_ctl(p):
            return fail('bad_password', 'A password is 8 to 128 characters.')
        self.ev('user_passwd', {'name': a['name']})
        return {'ok': True, 'job': self.job('users', 'password set for ' + a['name'])}

    def m_user_remove(self, a):
        u = self.find(self.users, a.get('name'))
        if not u:
            return fail('no_user', 'No such person.')
        for s in self.shares:
            s['rw'] = [w for w in s['rw'] if w != u['name']]
            s['ro'] = [w for w in s['ro'] if w != u['name']]
        for g in self.groups:
            g['members'] = [m for m in g['members'] if m != u['name']]
        self.users.remove(u)
        self.ev('user_remove', {'name': u['name']})
        self.bump('users', 'shares')
        return {'ok': True, 'job': self.job('users')}

    def members_ok(self, lst):
        if not isinstance(lst, list):
            return None
        out = []
        for w in lst:
            if not isstr(w, 31) or not self.find(self.users, w):
                return None
            if w not in out:
                out.append(w)
        return out

    def m_group_add(self, a):
        n = a.get('name')
        if not isstr(n, 31) or not full(RX_USER, n):
            return fail('bad_name', 'A group name is 1 to 31 lower-case letters, digits, dashes or underscores, and starts with a letter.')
        if self.taken(n):
            return fail('exists', 'That name is taken.')
        if len(self.groups) >= 32:
            return fail('too_many', 'At most 32 groups.')
        m = self.members_ok(a.get('members') or [])
        if m is None:
            return fail('bad_who', 'A person on that list does not exist.')
        self.groups.append({'name': n, 'gid': max([g['gid'] for g in self.groups] + [999]) + 1, 'members': m})
        self.ev('group_add', {'name': n})
        self.bump('users')
        return {'ok': True, 'job': self.job('users')}

    def m_group_set(self, a):
        g = self.find(self.groups, a.get('name'))
        if not g:
            return fail('no_group', 'No such group.')
        m = self.members_ok(a.get('members'))
        if m is None:
            return fail('bad_who', 'A person on that list does not exist.')
        g['members'] = m
        self.bump('users')
        return {'ok': True, 'job': self.job('users')}

    def m_group_remove(self, a):
        g = self.find(self.groups, a.get('name'))
        if not g:
            return fail('no_group', 'No such group.')
        for s in self.shares:
            s['rw'] = [w for w in s['rw'] if w != '@' + g['name']]
            s['ro'] = [w for w in s['ro'] if w != '@' + g['name']]
        self.groups.remove(g)
        self.ev('group_remove', {'name': g['name']})
        self.bump('users', 'shares')
        return {'ok': True, 'job': self.job('users')}

    # ---- services, alerts
    def m_service_set(self, a):
        if not isstr(a.get('id'), 8) or a['id'] not in SERVICES or not isinstance(a.get('enabled'), bool):
            return fail('bad_service', 'No such service.')
        if a['id'] == 'ssh' and not a['enabled'] and self.box()['trial_min'] is not None:
            return fail('trial_ssh', 'Secure shell stays on during a trial: it is how the trial is watched.')
        (self.enabled.add if a['enabled'] else self.enabled.discard)(a['id'])
        self.ev('service_set', {'id': a['id'], 'on': a['enabled']})
        self.bump('services')
        return {'ok': True, 'job': self.job('services', a['id'] + (' on' if a['enabled'] else ' off'))}

    def m_alerts_set(self, a):
        s = {}
        if a.get('enabled') is not None:
            if not isinstance(a['enabled'], bool):
                return fail('bad', 'enabled is true or false.')
            s['enabled'] = a['enabled']
        for k in ('to', 'from'):
            if a.get(k) is not None:
                if not isstr(a[k]) or not full(RX_MAIL, a[k]):
                    return fail('bad_mail', 'That does not look like an e-mail address.')
                s[k] = a[k]
        if a.get('host') is not None:
            if not isstr(a['host'], 253) or not full(RX_DNSNAME, a['host']):
                return fail('bad_host', 'The mail server is a name like smtp.example.org.')
            s['host'] = a['host']
        if a.get('port') is not None:
            if type(a['port']) is not int or not 1 <= a['port'] <= 65535:
                return fail('bad_port', 'The port is a number from 1 to 65535.')
            s['port'] = a['port']
        if a.get('tls') is not None:
            if a['tls'] not in ('starttls', 'tls', 'none'):
                return fail('bad_tls', 'Encryption is starttls, tls or none.')
            s['tls'] = a['tls']
        if a.get('user') is not None:
            if not isstr(a['user'], 128) or not printable(a['user']) or '"' in a['user'] or '\\' in a['user']:
                return fail('bad_user', 'The account name has a character a mail server would not take.')
            s['user'] = a['user']
        if a.get('space_pct') is not None:
            if type(a['space_pct']) is not int or not 50 <= a['space_pct'] <= 99:
                return fail('bad_pct', 'The space warning is 50 to 99 percent.')
            s['space_pct'] = a['space_pct']
        if a.get('events') is not None:
            if not isinstance(a['events'], list) or any(e not in ('disk', 'raid', 'temp', 'space') for e in a['events']):
                return fail('bad_events', 'Unknown event.')
            s['events'] = list(dict.fromkeys(a['events']))
        if a.get('password') is not None and (not isstr(a['password'], 256) or has_ctl(a['password'])):
            return fail('bad_password', 'That password has a character that cannot be stored.')
        now = dict(self.alerts, **s)
        if now['enabled'] and not (now['to'] and now['from'] and now['host']):
            return fail('incomplete', 'Alerts need a recipient, a sender address and a mail server before they can be switched on.')
        self.alerts = now
        if a.get('password') is not None:
            self.mailpw = a['password']
        self.ev('alerts_set', {'on': now['enabled']})
        self.bump('alerts')
        return {'ok': True, 'job': self.job('alerts')}

    def m_alerts_test(self, a):
        if not (self.alerts['to'] and self.alerts['from'] and self.alerts['host']):
            return fail('incomplete', 'Fill in a recipient, a sender address and a mail server first.')
        self.alert_last = {'t': int(time.time()), 'ok': True}
        self.ev('alert_test', {'ok': True})
        return {'ok': True, 'job': self.job('alert-test', 'the mail server took the test message')}

    # ---- system
    def m_system_set(self, a):
        renamed = False
        if a.get('hostname') is not None:
            if not isstr(a['hostname'], 32) or not full(RX_HOST, a['hostname']):
                return fail('bad_name', 'A name is 1 to 32 lower-case letters, digits or dashes; no dash at either end.')
        if a.get('zonename') is not None:
            if not isstr(a['zonename'], 40) or a['zonename'] not in ZONES:
                return fail('bad_zone', 'Pick a time zone from the list.')
        if a.get('hostname') is not None:
            renamed, self.name = a['hostname'] != self.name, a['hostname']
        if a.get('zonename') is not None:
            self.zone = a['zonename']
        self.ev('system_set', {'name': a.get('hostname'), 'zone': a.get('zonename')})
        self.bump('system', 'panel')
        return {'ok': True, 'renamed': renamed, 'job': self.job('system', 'name and clock applied')}

    def m_net_set(self, a):
        if a.get('mode') not in ('dhcp', 'static'):
            return fail('bad_mode', 'The address comes from the router (dhcp) or is fixed (static).')
        if (a.get('bond') or 'none') not in ('none', 'active-backup'):
            return fail('bad_bond', 'The two ports work alone (none) or as one with a spare (active-backup).')
        want = {'mode': a['mode'], 'bond': a.get('bond') or 'none', 'addr': '', 'mask': '', 'gw': '', 'dns': []}
        if a['mode'] == 'static':
            if not ip_ok(a.get('addr')):
                return fail('bad_addr', 'The address is four numbers, like 192.0.2.50.')
            if not mask_ok(a.get('mask')):
                return fail('bad_mask', 'The mask is four numbers, like 255.255.255.0.')
            if a.get('gw') not in (None, '') and not ip_ok(a['gw']):
                return fail('bad_gw', 'The router is four numbers, like 192.0.2.1.')
            dns = a.get('dns') or []
            if not isinstance(dns, list) or len(dns) > 3:
                return fail('bad_dns', 'Up to three name servers.')
            if any(not ip_ok(d) for d in dns):
                return fail('bad_dns', 'A name server is four numbers, like 192.0.2.1.')
            want.update(addr=a['addr'], mask=a['mask'], gw=a.get('gw') or '', dns=dns)
        if self.net_pending():
            return fail('pending', 'A network change is already waiting to be confirmed.')
        self.pending, self.net = (time.time() + 90, dict(self.net)), want
        self.ev('net_set', {'mode': want['mode'], 'bond': want['bond']})
        self.bump('system')
        return {'ok': True, 'rollback_s': 90, 'job': self.job('network', 'applied; the old settings come back in 90 s unless confirmed')}

    def m_net_confirm(self, a):
        if not self.net_pending():
            return fail('nothing', 'No network change is waiting.')
        self.pending = None
        self.ev('net_confirm')
        self.bump('system')
        return {'ok': True}

    def m_cert_renew(self, a):
        self.ev('cert_renew')
        return {'ok': True, 'job': self.job('certificate', 'a new certificate is in place')}

    def m_restart(self, a):
        self.ev('power', {'what': 'restart'})
        return {'ok': True, 'job': self.job('restart', 'restarting')}

    def m_shutdown(self, a):
        self.ev('power', {'what': 'shutdown'})
        return {'ok': True, 'job': self.job('shutdown', 'shutting down')}

    def m_trial_stay(self, a):
        if self.box()['trial_min'] is None:
            return fail('no_trial', 'This is not a trial boot.')
        self.stay = True
        self._snap = None
        self.ev('trial_stay')
        return {'ok': True}

    def m_support_bundle(self, a):
        self.bundle = 'ex4 support bundle, made by fakebox.py\naddresses, hardware addresses and serial numbers are masked\n\n==== events\n' + '\n'.join(json.dumps(e) for e in self.events) + '\n' + '(a fake has no log)\n' * 8
        return {'ok': True, 'job': self.job('bundle', 'the bundle is ready')}

    def m_panel_set(self, a):
        if a.get('on') is not None and not isinstance(a['on'], bool):
            return fail('bad', 'on is true or false.')
        if a.get('lcd') is not None and not isinstance(a['lcd'], bool):
            return fail('bad', 'lcd is true or false.')
        if a.get('standby') is not None and a['standby'] not in ('0', '3', '6'):
            return fail('bad_standby', 'Only 10 seconds, 5 minutes and never are known to the screen so far.')
        for k in ('on', 'lcd', 'standby'):
            if a.get(k) is not None:
                self.panel[k] = a[k]
        self.bump('panel')
        self.ev('panel_set')
        return {'ok': True}

    # ---- the doors
    @staticmethod
    def lock_s(n):
        return 0 if n < 3 else min(300, 2 ** (n - 3))

    def new_code(self):
        self.code = '%08d' % random.SystemRandom().randrange(100000000)
        return self.code

    def m_setup_state(self, a):
        if not self.claimed and not self.code:
            self.new_code()
        fp = hashlib.sha256(('fake certificate of ' + self.name).encode()).hexdigest().upper()
        return {'claimed': self.claimed, 'name': self.name, 'cert_fp': ':'.join(fp[i:i + 4] for i in range(0, 64, 4)), 'ver': {'openwrt': '25.12.6', 'kernel': '6.12.112', 'ui': '8.0'}, 'trial': self.box()['trial_min'] is not None}

    def m_setup_claim(self, a):
        if self.claimed:
            return fail('claimed', 'This box already has an administrator.')
        if time.time() < self.claim_locked:
            return {'ok': False, 'err': 'wait', 'wait_s': int(self.claim_locked - time.time() + 0.999)}
        if not self.code:
            self.new_code()
        if not isstr(a.get('code'), 6) or a['code'] != self.code:
            self.claim_fails += 1
            if self.claim_fails >= 5:
                self.claim_fails = 0
                self.new_code()
                self.claim_locked = time.time() + 60
                self.ev('claim_locked')
                return {'ok': False, 'err': 'wait', 'wait_s': 60, 'msg': 'Five wrong codes. The box has made a new code; read it again in a minute.'}
            return fail('bad_code', 'That is not the code the box is showing.')
        u = a.get('username')
        if not isstr(u, 31) or not full(RX_USER, u) or u == 'root':
            return fail('bad_name', 'An administrator name is 1 to 31 lower-case letters, digits, dashes or underscores, starts with a letter and is not root.')
        if not isstr(a.get('hash'), 140) or not full(RX_HASH, a['hash']):
            return fail('bad_hash', 'The password did not arrive in the form this box stores.')
        if a.get('hostname') is not None and (not isstr(a['hostname'], 32) or not full(RX_HOST, a['hostname'])):
            return fail('bad_host', 'A name is 1 to 32 lower-case letters, digits or dashes; no dash at either end.')
        self.claimed, self.admin, self.hash, self.code, self.claim_fails = True, u, a['hash'], None, 0
        if a.get('hostname'):
            self.name = a['hostname']
        self.bump('system', 'panel')
        self.ev('claimed', {'admin': u})
        return {'ok': True}

    def check_login(self, username, password):
        """what rpcd's `session login` decides: the one login section, crypt() against its hash"""
        return username == self.admin and verify(password, self.hash)

    def new_session(self, timeout=900):
        sid = '%032x' % random.SystemRandom().getrandbits(128)
        self.sessions[sid] = [time.time() + timeout, timeout]
        return sid

    def m_sign_in(self, a):
        if not self.claimed:
            return fail('unclaimed', 'This box has no administrator yet.')
        if time.time() < self.locked_until:
            return {'ok': False, 'err': 'wait', 'wait_s': int(self.locked_until - time.time() + 0.999)}
        u, p = a.get('username'), a.get('password')
        if not isstr(u, 31) or not full(RX_USER, u) or not isstr(p, 256) or not p:
            return fail('bad', 'Name or password not right.')
        if self.check_login(u, p):
            self.fails = 0
            self.ev('signin')
            return {'ok': True, 'sid': self.new_session(), 'timeout': 900, 'admin': u}
        self.fails += 1
        w = self.lock_s(self.fails)
        self.locked_until = time.time() + w
        if w >= 4:
            self.ev('signin_fail', {'n': self.fails})
        return {'ok': False, 'err': 'wait' if w else 'bad', 'wait_s': w, 'msg': 'Name or password not right.'}

    def m_keeper_passwd(self, a):
        if not isstr(a.get('hash'), 140) or not full(RX_HASH, a['hash']):
            return fail('bad_hash', 'The new password did not arrive in the form this box stores.')
        if time.time() < self.locked_until:
            return {'ok': False, 'err': 'wait', 'wait_s': int(self.locked_until - time.time() + 0.999)}
        if not isstr(a.get('old'), 256) or not a.get('old'):
            return fail('bad', 'The current password is not right.')
        if not self.check_login(self.admin, a['old']):
            self.fails += 1
            self.locked_until = time.time() + self.lock_s(self.fails)
            return {'ok': False, 'err': 'bad', 'wait_s': self.lock_s(self.fails), 'msg': 'The current password is not right.'}
        self.hash = a['hash']
        mine = a.get('ubus_rpc_session')                # v8: a new password ends every OTHER session (as ex4.uc)
        n = len([s for s in self.sessions if s != mine])
        self.sessions = {s: v for s, v in self.sessions.items() if s == mine}
        self.ev('keeper_passwd', {'ended': n})
        return {'ok': True, 'ended': n}

    def m_signout_all(self, a):
        n = len(self.sessions)
        self.sessions = {}
        self.ev('signout_all', {'n': n})
        return {'ok': True, 'n': n}

    # ---- the /ubus door: sessions and the access lists, as uhttpd-mod-ubus + rpcd apply them
    def call(self, sid, obj, method, args):
        with self.lock:
            sess = self.sessions.get(sid)
            if sess and time.time() > sess[0]:
                del self.sessions[sid]
                sess = None
            if sess:
                sess[0] = time.time() + sess[1]
            allowed = method in self.acl_none.get(obj, []) or (sess is not None and method in self.acl_sess.get(obj, ()))
            if not allowed:
                return None
            if obj == 'session':
                if method == 'destroy':
                    self.sessions.pop(sid, None)
                    return [0]
                return [0, {'access': True}]
            fn = getattr(self, 'm_' + method, None)
            if obj != 'ex4' or fn is None:
                return [3]                     # UBUS_STATUS_METHOD_NOT_FOUND
            args = dict(args) if isinstance(args, dict) else {}
            args['ubus_rpc_session'] = sid             # as uhttpd-mod-ubus puts the caller's session id into every call
            return [0, fn(args)]


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    fake = None

    def log_message(self, *a):
        pass

    def send(self, code, body, ctype='application/json', extra=()):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split('?')[0]
        if path in ('/', '/index.html'):
            page = open(os.path.join(WEBUI, 'dist', 'index.html'), 'rb').read()
            etag = '"%s"' % hashlib.md5(page).hexdigest()[:16]
            if self.headers.get('If-None-Match') == etag:
                self.send_response(304)
                self.send_header('ETag', etag)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            return self.send(200, page, 'text/html', (('ETag', etag),))      # like uhttpd: an ETag, no Cache-Control, no compression
        if path == '/_test/claim':
            with self.fake.lock:
                return self.send(200, json.dumps({'code': self.fake.code}).encode())
        self.send(404, b'{}')

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode('utf-8') or 'null')
        except (ValueError, UnicodeDecodeError):
            return self.send(200, json.dumps({'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700, 'message': 'Parse error'}}).encode())
        path = self.path.split('?')[0]
        if path == '/_test/scenario':
            with self.fake.lock:
                self.fake.scn, self.fake._snap = body['name'], None
                self.fake.bump(*self.fake.rev.keys())
            return self.send(200, b'{}')
        if path == '/_test/reset':
            self.fake.reset(body.get('scenario', 'trial'), bool(body.get('claimed')))
            self.fake._snap = None
            return self.send(200, b'{}')
        if path == '/_test/expire':
            with self.fake.lock:
                self.fake.sessions = {}
            return self.send(200, b'{}')
        if path != '/ubus':
            return self.send(404, b'{}')

        def one(c):
            if not isinstance(c, dict) or c.get('method') != 'call' or not isinstance(c.get('params'), list) or len(c['params']) < 3:
                return {'jsonrpc': '2.0', 'id': c.get('id') if isinstance(c, dict) else None, 'error': {'code': -32600, 'message': 'Invalid request'}}
            p = c['params']
            r = self.fake.call(p[0], p[1], p[2], p[3] if len(p) > 3 else {})
            if r is None:
                return {'jsonrpc': '2.0', 'id': c.get('id'), 'error': {'code': -32002, 'message': 'Access denied'}}
            return {'jsonrpc': '2.0', 'id': c.get('id'), 'result': r}
        out = [one(c) for c in body] if isinstance(body, list) else one(body)
        self.send(200, json.dumps(out, separators=(',', ':')).encode())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=18490)
    ap.add_argument('--scenario', default='trial')
    ap.add_argument('--claimed', action='store_true')
    a = ap.parse_args()
    if not os.path.exists(os.path.join(WEBUI, 'dist', 'index.html')):
        sys.exit('REFUSED: build the page first: python3 webui/build.py')
    Handler.fake = Fake(a.scenario, a.claimed)
    srv = ThreadingHTTPServer(('127.0.0.1', a.port), Handler)       # loopback only: this is a test tool
    print('fakebox: http://127.0.0.1:%d/  (scenario %s, %s)' % (a.port, a.scenario, 'claimed: %s / %s' % (ADMIN, ADMIN_PW) if a.claimed else 'unclaimed; code: GET /_test/claim'), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
