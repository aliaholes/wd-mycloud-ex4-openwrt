#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""truth.py : the sample box every web-interface test runs against, and the fixture tree made from it.

The numbers are those of the unit this port was made on (a 2012 WD My Cloud EX4, four WD40EFRX in RAID 5, about
1.7 GB used of 10.8 TB, the disk in bay 4 with one unreadable sector, no scheduled array check). What would identify
that unit is NOT here: serial numbers, addresses, names of people and of private shares are made up.

Two users:
  fakebox.py imports box() and answers the interface's calls from it (no OpenWrt needed);
  emu/emu.sh runs  python3 truth.py --root DIR --scenario NAME  to write the same box as files (/proc, /sys, /tmp,
  /etc/config) under DIR, where the REAL rpcd + ex4.uc read them through EX4_ROOT.

Scenarios: trial (the default: a read-only RAM trial, bay 4 wants watching) · copy (the same while a file arrives) ·
healthy · closed (no array assembled) · rebuild · failed · hot · rw (volume read-write, token present) · installed
(not a trial).  --tick N rewrites the counters N times, one second apart (rates for the real backend).
"""
import argparse, json, os, sys, time

KIB_TOTAL = 11601318912          # 10.8 TiB as the file system reports it
KIB_USED = 1782580               # 1.7 GiB
MD_KIB = 11708466624             # /proc/mdstat's own figure for md1
DISK_SECTORS = 7814037168        # WD40EFRX
HOT_C = 55
BOOT_ID = '6f2c1d0e-4b7a-4c39-9e51-0a8d3f7b2c64'   # the sample box's /proc/sys/kernel/random/boot_id (made up)


def box(scenario='trial'):
    b = {
        'scenario': scenario, 'name': 'ex4', 'addr': '192.0.2.50', 'up': 328, 'trial_min': 20,
        'mem_total_kb': 508876, 'mem_avail_kb': 471208,
        'ports': [{'dev': 'eth0', 'up': True, 'speed': 1000}, {'dev': 'eth1', 'up': False, 'speed': None}],
        'cpu': 0.04, 'rx': 2100, 'tx': 900, 'io_rd': 0, 'io_wr': 0, 'load': '0.42',
        'fan': 'low', 'rpm': 1020, 'board': 44,
        'disks': [
            {'bay': 1, 'dev': 'sda', 'serial': 'WD-WCC4E0000A01', 'temp': 38, 'hours': 102531, 'starts': 318, 'load': 2140, 'realloc': 0, 'pending': 0, 'uncorrect': 0, 'crc': 0},
            {'bay': 2, 'dev': 'sdb', 'serial': 'WD-WCC4E0000B02', 'temp': 39, 'hours': 102498, 'starts': 312, 'load': 2096, 'realloc': 0, 'pending': 0, 'uncorrect': 0, 'crc': 0},
            {'bay': 3, 'dev': 'sdc', 'serial': 'WD-WCC4E0000C03', 'temp': 41, 'hours': 102540, 'starts': 315, 'load': 2118, 'realloc': 0, 'pending': 0, 'uncorrect': 0, 'crc': 0},
            {'bay': 4, 'dev': 'sdd', 'serial': 'WD-WCC4E0000D04', 'temp': 40, 'hours': 99812, 'starts': 297, 'load': 1987, 'realloc': 0, 'pending': 1, 'uncorrect': 0, 'crc': 0},
        ],
        'array': {'dev': 'md1', 'level': 'raid5', 'state': 'readonly', 'degraded': 0, 'disks': 4, 'action': 'idle', 'done': None,
                  'speed_kb': None, 'ro': True, 'mismatch': 0, 'chunk_kb': 64, 'meta': '1.0', 'bitmap': False,
                  'members': {'sda': 'in_sync', 'sdb': 'in_sync', 'sdc': 'in_sync', 'sdd': 'in_sync'}},
        'vol': {'path': '/mnt/md1', 'mounted': True, 'rw': False, 'gate': False},
        'folders': ['Public', 'SmartWare', 'TimeMachineBackup', 'Media', 'Backups'],
        'smart_age': 720,
    }
    for d in b['disks']:
        d['model'] = 'WDC WD40EFRX-68W'
    if scenario == 'copy':
        b.update(cpu=0.97, rx=38.6 * 1048576, tx=0.4 * 1048576, io_rd=0, io_wr=0, load='1.12')
        b['disks'][2]['temp'] = 42
    elif scenario == 'healthy':
        b['disks'][3]['pending'] = 0
    elif scenario == 'closed':
        b['array'] = None
        b['vol'].update(mounted=False)
        b['disks'][3]['pending'] = 0
    elif scenario == 'rebuild':
        b['array'].update(state='active', degraded=1, action='recover', done=(1601000000, 7814037168 - 4096), speed_kb=31200, ro=False)
        b['array']['members']['sdd'] = 'spare'
        b['vol'].update(rw=True)
        b['disks'][3].update(pending=0, hours=12, starts=1, load=1, serial='WD-WX42D0000E05')
    elif scenario == 'failed':
        b['array'].update(state='clean', degraded=1, ro=False)
        b['array']['members']['sdd'] = 'faulty'
        b['vol'].update(rw=True)
        b['disks'][3].update(pending=48, realloc=312)
    elif scenario == 'hot':
        for d, t in zip(b['disks'], (54, 56, 57, 55)):
            d['temp'] = t
        b.update(fan='max', rpm=3100, board=58)
    elif scenario in ('rw', 'installed'):
        b['array'].update(state='clean', ro=False)
        b['vol'].update(rw=True, gate=(scenario == 'rw'))
    if scenario == 'installed':
        b['trial_min'] = None
        b['up'] = 3 * 86400 + 4 * 3600
    return b


# ---------------------------------------------------------------- the same box as a tree of files
def _w(root, path, text, mode=0o644):
    p = root + path
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + '.new', 'w') as f:
        f.write(text)
    os.chmod(p + '.new', mode)
    os.replace(p + '.new', p)


def counters(root, b, n):
    """/proc/stat, /proc/net/dev, /sys/block/*/stat after n seconds of this scenario's rates."""
    busy = int(100 * n * b['cpu'])
    _w(root, '/proc/stat', 'cpu  %d 0 %d %d 0 0 0 0 0 0\ncpu0 0 0 0 0 0 0 0 0 0 0\n' % (1000 + busy // 2, 500 + busy - busy // 2, 90000 + 100 * n - busy))
    _w(root, '/proc/net/dev', 'Inter-|   Receive                                                |  Transmit\n'
       ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n'
       '    lo: 9000 90 0 0 0 0 0 0 9000 90 0 0 0 0 0 0\n'
       '  eth0: %d 100 0 0 0 0 0 0 %d 100 0 0 0 0 0 0\n  eth1: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\nbr-lan: %d 100 0 0 0 0 0 0 %d 100 0 0 0 0 0 0\n'
       % (5000000 + int(b['rx'] * n), 3000000 + int(b['tx'] * n), 5000000 + int(b['rx'] * n), 3000000 + int(b['tx'] * n)))
    if b['array']:
        _w(root, '/sys/block/md1/stat', '900 0 %d 0 40 0 %d 0 0 0 0\n' % (72000 + int(b['io_rd'] * n / 512), 320 + int(b['io_wr'] * n / 512)))
    for d in b['disks']:
        _w(root, '/sys/block/%s/stat' % d['dev'], '300 0 24000 0 10 0 80 0 0 0 0\n')
    _w(root, '/proc/uptime', '%d.00 %d.00\n' % (b['up'] + n, b['up'] + n))


def write_tree(root, b):
    _w(root, '/proc/meminfo', 'MemTotal: %9d kB\nMemFree: %9d kB\nMemAvailable: %9d kB\nBuffers: 2000 kB\nCached: 9000 kB\n' % (b['mem_total_kb'], b['mem_avail_kb'] - 8000, b['mem_avail_kb']))
    _w(root, '/proc/loadavg', '%s 0.31 0.18 1/71 1234\n' % b['load'])
    _w(root, '/proc/sys/kernel/hostname', b['name'] + '\n')
    _w(root, '/proc/sys/kernel/osrelease', '6.12.112\n')
    mounts = 'rootfs / rootfs rw 0 0\nproc /proc proc rw,nosuid,nodev,noexec,noatime 0 0\ntmpfs /tmp tmpfs rw,nosuid,nodev,noatime 0 0\n'
    if b['vol']['mounted']:
        mounts += '/dev/md1 %s ext4 %s 0 0\n' % (b['vol']['path'], 'rw,noatime,stripe=48' if b['vol']['rw'] else 'ro,noatime,norecovery')
    _w(root, '/proc/mounts', mounts)
    for p in b['ports']:
        _w(root, '/sys/class/net/%s/carrier' % p['dev'], '1\n' if p['up'] else '0\n')
        if p['up']:
            _w(root, '/sys/class/net/%s/speed' % p['dev'], '%d\n' % p['speed'])
    os.makedirs(root + '/sys/devices/platform/pcie/ata', exist_ok=True)
    for d in b['disks']:
        dev = d['dev']
        real = '/sys/devices/platform/pcie/0000:00:01.0/0000:01:00.0/ata%d/host%d/target%d:0:0/%d:0:0:0/block/%s' % (d['bay'], d['bay'] - 1, d['bay'] - 1, d['bay'] - 1, dev)
        _w(root, real + '/size', '%d\n' % DISK_SECTORS)
        _w(root, real + '/device/model', d['model'] + '\n')
        _w(root, real + '/removable', '0\n')
        os.makedirs(root + '/sys/block', exist_ok=True)
        link = root + '/sys/block/' + dev
        if os.path.islink(link):
            os.unlink(link)
        # the real sysfs link is relative (../devices/...); the plugin only looks for /ataN/ and /usb in it
        os.symlink('..' + real[len('/sys'):], link)
        sm = {'t': int(time.time()) - b['smart_age'], 'dev': dev, 'model': 'WDC WD40EFRX-68WT0N0', 'serial': d['serial'], 'power': 'active', 'passed': d['pending'] < 40,
              'a': {'5': d['realloc'], '9': d['hours'], '12': d['starts'], '193': d['load'], '194': d['temp'], '197': d['pending'], '198': d['uncorrect'], '199': d['crc']}}
        _w(root, '/tmp/ex4/smart/%s.json' % dev, json.dumps(sm) + '\n', 0o600)
    md = root + '/sys/block/md1'
    if b['array']:
        a = b['array']
        _w(root, '/sys/block/md1/size', '%d\n' % (MD_KIB * 2))
        _w(root, '/sys/block/md1/ro', '1\n' if a['ro'] else '0\n')
        for k, v in (('level', a['level']), ('array_state', a['state']), ('degraded', a['degraded']), ('raid_disks', a['disks']), ('sync_action', a['action']),
                     ('sync_completed', '%d / %d' % a['done'] if a['done'] else 'none'), ('sync_speed', a['speed_kb'] if a['speed_kb'] else 'none'),
                     ('chunk_size', a['chunk_kb'] * 1024), ('mismatch_cnt', a['mismatch']), ('metadata_version', a['meta']), ('bitmap/location', '+8' if a['bitmap'] else 'none')):
            _w(root, '/sys/block/md1/md/' + k, '%s\n' % v)
        for i, (dev, st) in enumerate(sorted(a['members'].items())):
            _w(root, '/sys/block/md1/md/dev-%s2/state' % dev, st + '\n')
            _w(root, '/sys/block/md1/md/dev-%s2/slot' % dev, ('%d\n' % i) if st == 'in_sync' else 'none\n')
    elif os.path.isdir(md):
        os.rename(md, md + '.gone-%d' % int(time.time()))
    temps = ','.join('%s:%d' % (d['dev'], d['temp']) for d in b['disks'])
    lv = {'low': 1, 'medium': 2, 'high': 3, 'max': 4}[b['fan']]
    hot = max(d['temp'] for d in b['disks'])
    _w(root, '/tmp/ex4fan.status', 'status up=%d level=%d(%s) acked=1 rpm=%d tach=ok drives=%s main=%d sata=41 soc=52 T=%d micro=answers frames_in=412 acks=40 cmds=6/6 other=0 ready=acked events=0 clock=set\n'
       % (b['up'] - 20, lv, b['fan'].upper(), b['rpm'], temps, b['board'], hot))
    # what ex4fan's json_write() leaves for the web interface (docs/PANEL.md); the screen is fed nothing by default
    fj = {'v': 1, 'up': b['up'] - 20, 'wall': int(time.time()) - 8, 'fan': {'level': lv, 'name': b['fan'].upper(), 'acked': 1, 'rpm': b['rpm'], 'tach': 'edges', 'edges': 34},
          'temps': {'main': b['board'], 'sata': 41, 'soc': 52, 'T': hot},
          'drives': [{'dev': d['dev'], 'temp': d['temp'], 'power': 'active', 'verdict': 'watch' if d['pending'] or d['realloc'] else 'good',
                      'smart': {'5': d['realloc'], '9': d['hours'], '10': 0, '12': d['starts'], '187': 0, '194': d['temp'], '197': d['pending'], '198': d['uncorrect'], '199': d['crc']}} for d in b['disks']],
          'usb_disks': 0, 'space': {'mounted': b['vol']['mounted'], 'mount': b['vol']['path'] if b['vol']['mounted'] else '', 'total': KIB_TOTAL * 1024 if b['vol']['mounted'] else 0,
                                    'avail': (KIB_TOTAL - KIB_USED) * 1024 if b['vol']['mounted'] else 0, 'used_pct': 0},
          'micro': {'answers': True, 'frames_in': 412, 'acks': 40, 'cmds': 6, 'cmds_acked': 6, 'other': 0, 'ready': 'acked', 'clock': 'set'},
          'panel': {'mode': 'off', 'poweroff_allowed': False, 'lcd_frames': 0, 'lcd_acked': 0, 'lcd_unacked': 0, 'sent': {}, 'host': b['name'], 'ip1': b['addr'], 'ip2': '', 'fw': 'OpenWrt 25.12.6'},
          'alerts': [], 'events': [], 'events_total': 0}
    _w(root, '/tmp/ex4fan.json', json.dumps(fj) + '\n')
    if b['vol']['mounted']:
        _w(root, '/tmp/ex4/space', '%d %d %d %d\n' % (KIB_TOTAL, KIB_USED, KIB_TOTAL - KIB_USED, int(time.time())))
        for f in b['folders']:
            os.makedirs(root + b['vol']['path'] + '/' + f, exist_ok=True)
    elif os.path.exists(root + '/tmp/ex4/space'):
        os.unlink(root + '/tmp/ex4/space')
    # v8: the read-write token is checked by CONTENT: "rw-ok <this boot's boot_id>", mode 0600 (ex4.uc rw_token_ok())
    _w(root, '/proc/sys/kernel/random/boot_id', BOOT_ID + '\n')
    for p, on in (('/tmp/ex4-rw-ok', b['vol']['gate']),):
        if on:
            _w(root, p, 'rw-ok %s\n' % BOOT_ID, 0o600)
        elif os.path.exists(root + p):
            os.unlink(root + p)
    if b['trial_min'] is not None:
        _w(root, '/etc/ex4/trial', 'return_min=%d\n' % b['trial_min'])
    elif os.path.exists(root + '/etc/ex4/trial'):
        os.unlink(root + '/etc/ex4/trial')
    _w(root, '/etc/openwrt_release', "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='25.12.6'\n")
    counters(root, b, 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    ap.add_argument('--scenario', default='trial')
    ap.add_argument('--tick', type=int, default=0, help='rewrite the counters this many times, one second apart')
    ap.add_argument('--only-counters', action='store_true')
    a = ap.parse_args()
    if not os.path.isdir(a.root) or os.path.realpath(a.root) == '/':
        sys.exit('REFUSED: --root must be an existing scratch folder, never /')
    b = box(a.scenario)
    if not a.only_counters:
        write_tree(a.root, b)
    for n in range(1, a.tick + 1):
        time.sleep(1)
        counters(a.root, b, n)


if __name__ == '__main__':
    main()
