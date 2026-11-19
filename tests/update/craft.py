#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""craft.py: make the BAD releases tests/update/run.sh feeds the box, each from a good one (made by mkrelease.py).
Every variant that needs a valid signature is re-signed with the TEST key by OpenWrt's usign, so the box's later
walls (board, format, tar) are what refuses it, not the signature.

  python3 -I tests/update/craft.py VARIANT GOOD_DIR OUT_DIR --usign USIGN --key TEST.sec

  tamper-release   one byte of RELEASE changed after signing          (the signature must refuse)
  tamper-payload   one byte of the payload changed                    (the sha256 must refuse)
  truncate-payload the payload's last 1000 bytes gone                  (the size must refuse)
  unsigned         RELEASE.sig removed
  wrong-board      board line changed, re-signed                       (the board wall)
  serial:N         serial line changed to N, re-signed                 (the downgrade wall)
  channel:C        channel line changed to C, re-signed
  unknown-line     a line "evil 1" before end, re-signed               (the parser)
  no-end           RELEASE without its end line, re-signed             (a truncated manifest)
  huge-release     RELEASE replaced by 1 MiB of text                   (the size limit, before the signature)
  extra-member     the payload gains a file RELEASE does not list, sha256/size fixed, re-signed
  symlink-member   the payload gains a symlink, re-signed
  dotdot-member    a member named ../x, re-signed
  line:KEY:VALUE   (v9) the KEY line set to "KEY VALUE", re-signed      (built / not-after: the clock + expiry walls)
  drop:KEY         (v9) the KEY line removed, re-signed
  add:TEXT         (v9) the line TEXT added before end, re-signed      (a successor line)"""
import argparse
import hashlib
import io
import os
import shutil
import subprocess
import sys
import tarfile


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('variant'); ap.add_argument('good'); ap.add_argument('out')
    ap.add_argument('--usign', required=True); ap.add_argument('--key', required=True)
    a = ap.parse_args()
    if os.path.exists(a.out):
        sys.exit(f'craft: {a.out} exists')
    shutil.copytree(a.good, a.out)
    rp = os.path.join(a.out, 'RELEASE')
    lines = open(rp).read().split('\n')[:-1]
    pay = next(l.split()[3] for l in lines if l.startswith('payload '))
    pp = os.path.join(a.out, pay)

    def resign():
        open(rp, 'w').write('\n'.join(lines) + '\n')
        subprocess.run([a.usign, '-S', '-m', rp, '-s', a.key, '-x', rp + '.sig'], check=True)

    def set_line(key, value):
        for i, l in enumerate(lines):
            if l.startswith(key + ' '):
                lines[i] = key + ' ' + value
                return
        raise SystemExit(f'craft: no {key} line')

    def repay(extra):
        """rebuild the payload tar = the good members + extra (a TarInfo, bytes) and fix the payload line"""
        bio = io.BytesIO()
        with tarfile.open(pp, 'r') as src, tarfile.open(fileobj=bio, mode='w', format=tarfile.USTAR_FORMAT) as dst:
            for m in src.getmembers():
                dst.addfile(m, src.extractfile(m))
            ti, data = extra
            dst.addfile(ti, io.BytesIO(data) if data is not None else None)
        open(pp, 'wb').write(bio.getvalue())
        set_line('payload', f'{sha(bio.getvalue())} {len(bio.getvalue())} {pay}')

    v = a.variant
    if v == 'tamper-release':
        b = bytearray(open(rp, 'rb').read()); i = b.index(b'version ') + 8; b[i] ^= 1; open(rp, 'wb').write(bytes(b))
    elif v == 'tamper-payload':
        b = bytearray(open(pp, 'rb').read()); b[len(b) // 3] ^= 0x40; open(pp, 'wb').write(bytes(b))
    elif v == 'truncate-payload':
        b = open(pp, 'rb').read(); open(pp, 'wb').write(b[:-1000])
    elif v == 'unsigned':
        os.remove(rp + '.sig')
    elif v == 'wrong-board':
        set_line('board', 'wd,mycloud-ex2-ultra'); resign()
    elif v.startswith('serial:'):
        set_line('serial', v[7:]); resign()
    elif v.startswith('channel:'):
        set_line('channel', v[8:]); resign()
    elif v == 'unknown-line':
        lines.insert(len(lines) - 1, 'evil 1'); resign()
    elif v == 'no-end':
        lines.pop(); resign()
    elif v == 'huge-release':
        open(rp, 'w').write(('x' * 1023 + '\n') * 1024)
    elif v == 'extra-member':
        ti = tarfile.TarInfo('extra.bin'); data = b'not listed\n'; ti.size = len(data); repay((ti, data)); resign()
    elif v == 'symlink-member':
        ti = tarfile.TarInfo('evil'); ti.type = tarfile.SYMTYPE; ti.linkname = '/etc/shadow'; repay((ti, None)); resign()
    elif v == 'dotdot-member':
        ti = tarfile.TarInfo('../escaped'); data = b'x\n'; ti.size = len(data); repay((ti, data)); resign()
    elif v.startswith('line:'):
        k, val = v[5:].split(':', 1); set_line(k, val); resign()
    elif v.startswith('drop:'):
        k = v[5:]; n = len(lines); lines[:] = [l for l in lines if not l.startswith(k + ' ')]
        if len(lines) == n:
            raise SystemExit(f'craft: no {k} line')
        resign()
    elif v.startswith('add:'):
        lines.insert(len(lines) - 1, v[4:]); resign()
    else:
        sys.exit(f'craft: unknown variant {v}')


if __name__ == '__main__':
    main()
