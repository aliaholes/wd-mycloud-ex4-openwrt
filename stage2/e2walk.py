#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""e2walk.py IMG : every path in an ext2 image with mode uid gid size and md5 (regular files) or link target, via debugfs only (no mount, no root)."""
import subprocess, sys, hashlib
img = sys.argv[1]
def dbg(cmd):
    return subprocess.run(['debugfs', '-R', cmd, img], capture_output=True).stdout
out = []
def walk(d):
    for line in dbg(f'ls -p "{d}"').decode('latin1').splitlines():
        f = line.strip().split('/')
        if len(f) < 7: continue
        ino, mode, uid, gid, name, size = f[1], f[2], f[3], f[4], f[5], f[6]
        if name in ('.', '..'): continue
        p = (d.rstrip('/') + '/' + name)
        m = int(mode, 8); kind = m & 0o170000
        extra = ''
        if kind == 0o100000:
            extra = 'md5=' + hashlib.md5(dbg(f'cat "{p}"')).hexdigest()
        elif kind == 0o120000:
            st = dbg(f'stat "{p}"').decode('latin1')
            extra = 'link=' + (st.split('Fast link dest: ')[1].split('\n')[0].strip('"') if 'Fast link dest: ' in st else 'slow:' + hashlib.md5(dbg(f'cat "{p}"')).hexdigest())
        out.append(f'{p}\t{mode}\t{uid}\t{gid}\t{size}\t{extra}')
        if kind == 0o040000 and name != 'lost+found' or (kind == 0o040000 and name == 'lost+found'):
            walk(p)
walk('/')
print('\n'.join(sorted(out)))
