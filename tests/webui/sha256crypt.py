#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""sha256crypt.py : the $5$ password hash (Ulrich Drepper's SHA-crypt), in plain Python.

The web interface computes this hash IN THE BROWSER at first-boot claim and at a password change and sends only the
hash; rpcd's crypt() checks a sign-in against it. The tests need the same function a third time, independent of both:
api_test.py makes hashes with it, fakebox.py checks sign-ins with it (as rpcd's crypt() does on the box), and the page
test thereby proves the browser's implementation equals this one. `python3 sha256crypt.py` checks it against the
specification's own test vector and, where openssl is installed, against `openssl passwd -5`.
"""
import hashlib, re, subprocess, sys

_B64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
RX = re.compile(r'^\$5\$(?:rounds=(\d{4,7})\$)?([./A-Za-z0-9]{1,16})\$([./A-Za-z0-9]{43})$')


def crypt5(password, salt, rounds=5000):
    pw = password.encode('utf-8') if isinstance(password, str) else password
    sl = (salt.encode('ascii') if isinstance(salt, str) else salt)[:16]
    n = len(pw)
    h = lambda b: hashlib.sha256(b).digest()
    B = h(pw + sl + pw)
    ctx = pw + sl + B * (n // 32) + B[:n % 32]
    i = n
    while i > 0:
        ctx += B if i & 1 else pw
        i >>= 1
    A = h(ctx)
    DP = h(pw * n)
    P = DP * (n // 32) + DP[:n % 32]
    DS = h(sl * (16 + A[0]))
    S = DS * (len(sl) // 32) + DS[:len(sl) % 32]
    C = A
    for r in range(rounds):
        c = P if r & 1 else C
        if r % 3:
            c += S
        if r % 7:
            c += P
        c += C if r & 1 else P
        C = h(c)
    out = ''
    for a, b, c3 in ((0, 10, 20), (21, 1, 11), (12, 22, 2), (3, 13, 23), (24, 4, 14), (15, 25, 5), (6, 16, 26), (27, 7, 17), (18, 28, 8), (9, 19, 29)):
        v = C[a] << 16 | C[b] << 8 | C[c3]
        for _ in range(4):
            out += _B64[v & 63]
            v >>= 6
    v = C[31] << 8 | C[30]
    for _ in range(3):
        out += _B64[v & 63]
        v >>= 6
    return '$5$' + ('' if rounds == 5000 else 'rounds=%d$' % rounds) + sl.decode('ascii') + '$' + out


def verify(password, stored):
    """True when `stored` is a $5$ hash of `password` (what rpcd's crypt() decides on the box)."""
    m = RX.match(stored or '')
    if not m:
        return False
    return crypt5(password, m.group(2), int(m.group(1)) if m.group(1) else 5000) == stored


def selftest():
    want = '$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5'            # the specification's first vector
    got = crypt5('Hello world!', 'saltstring')
    ok = got == want
    print('spec vector:', 'ok' if ok else 'WRONG ' + got)
    want2 = '$5$rounds=10000$saltstringsaltst$3xv.VbSHBb41AL9AvLeujZkZRBAwqFMz2.opqey6IcA'
    got2 = crypt5('Hello world!', 'saltstringsaltstring', 10000)
    print('spec vector 2 (rounds, long salt):', 'ok' if got2 == want2 else 'WRONG ' + got2)
    ok = ok and got2 == want2
    try:
        for pw, salt in (('tide and lamp', 'keeperemu'), ('a' * 70, 'x'), ('pässwörd ☃', 'Zz09./aB')):
            o = subprocess.run(['openssl', 'passwd', '-5', '-salt', salt, pw], capture_output=True, text=True, timeout=10).stdout.strip()
            same = o == crypt5(pw, salt)
            print('openssl passwd -5, %d chars:' % len(pw), 'ok' if same else 'DIFFERENT')
            ok = ok and same
    except (OSError, subprocess.SubprocessError):
        print('openssl not found: only the specification vectors were checked')
    return ok


if __name__ == '__main__':
    sys.exit(0 if selftest() else 1)
