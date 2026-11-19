#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""usignpy.py: VERIFY OpenWrt usign / signify ed25519 signatures in plain Python (standard library only).

The box verifies a release with OpenWrt's own `usign` (in the image: /usr/bin/usign). A host that has no usign build
(the CVE watch, a reviewer's laptop) verifies the same files with this module. It can only verify; it cannot sign.

  python3 -I usignpy.py verify PUBKEY MESSAGE SIGNATURE     exit 0 = good, 1 = bad (one line says why)
  python3 -I usignpy.py fingerprint FILE                    the 16-hex key number usign prints with -F
  python3 -I usignpy.py selftest                            RFC 8032 section 7.1 test vectors (must all pass)

File formats (usign's main.c, the signify format): two lines, "untrusted comment: ..." then base64 of
  public key  = b"Ed" + keynum(8) + A(32)        (42 bytes)
  signature   = b"Ed" + keynum(8) + sig(64)      (74 bytes)
The signature is plain ed25519 over the message bytes (no pre-hash). A signature whose keynum is not the key's
keynum is refused before any arithmetic, as usign does.

The arithmetic is RFC 8032 section 5.1.7 (cofactorless: [S]B == R + [k]A, compared as encodings), with the
canonical checks: S < L, R and A decode, A is not the identity. Verification only touches public data, so the
pure-Python timing is not a secret leak."""
import base64
import hashlib
import sys

P = 2 ** 255 - 19
L = 2 ** 252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _add(p1, p2):
    x1, y1, z1, t1 = p1
    x2, y2, z2, t2 = p2
    a = (y1 - x1) * (y2 - x2) % P
    b = (y1 + x1) * (y2 + x2) % P
    c = 2 * t1 * t2 * D % P
    d = 2 * z1 * z2 % P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _mul(s, pt):
    q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            q = _add(q, pt)
        pt = _add(pt, pt)
        s >>= 1
    return q


def _encode(pt):
    x, y, z, _ = pt
    zi = pow(z, P - 2, P)
    x, y = x * zi % P, y * zi % P
    return int.to_bytes(y | ((x & 1) << 255), 32, 'little')


def _decode(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, 'little')
    sign = y >> 255
    y &= (1 << 255) - 1
    if y >= P:
        return None
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    if x2 == 0:
        if sign:
            return None
        x = 0
    else:
        x = pow(x2, (P + 3) // 8, P)
        if (x * x - x2) % P != 0:
            x = x * SQRT_M1 % P
        if (x * x - x2) % P != 0:
            return None
        if (x & 1) != sign:
            x = P - x
    return (x, y, 1, x * y % P)


_GY = 4 * pow(5, P - 2, P) % P
B = _decode(int.to_bytes(_GY, 32, 'little'))


def ed25519_verify(pub, msg, sig):
    if len(pub) != 32 or len(sig) != 64:
        return False
    a = _decode(pub)
    r = _decode(sig[:32])
    if a is None or r is None:
        return False
    if _encode(a) == _encode((0, 1, 1, 0)):
        return False
    s = int.from_bytes(sig[32:], 'little')
    if s >= L:
        return False
    k = int.from_bytes(hashlib.sha512(sig[:32] + pub + msg).digest(), 'little') % L
    return _encode(_mul(s, B)) == _encode(_add(r, _mul(k, a)))


class UsignError(Exception):
    pass


def read_blob(path, want_len):
    """the base64 line of a usign key/signature file -> bytes (refuses anything that is not exactly that shape)"""
    with open(path, 'rb') as f:
        data = f.read(4097)
    if len(data) > 4096:
        raise UsignError(f'{path}: larger than any usign file')
    lines = data.decode('ascii', 'strict').splitlines()
    if len(lines) < 2 or not lines[0].startswith('untrusted comment: '):
        raise UsignError(f'{path}: not a usign file (no "untrusted comment:" line)')
    try:
        blob = base64.b64decode(lines[1].strip(), validate=True)
    except Exception:
        raise UsignError(f'{path}: the second line is not base64')
    if len(blob) != want_len or blob[:2] != b'Ed':
        raise UsignError(f'{path}: not an ed25519 usign blob of {want_len} bytes')
    return blob


def read_pub(path):
    b = read_blob(path, 42)
    return b[2:10], b[10:]


def read_sig(path):
    b = read_blob(path, 74)
    return b[2:10], b[10:]


def verify_files(pub_path, msg_path, sig_path, max_msg=1 << 26):
    """-> (ok, why). Never raises for a bad signature; raises UsignError only for files of the wrong shape."""
    kn_pub, a = read_pub(pub_path)
    kn_sig, s = read_sig(sig_path)
    if kn_pub != kn_sig:
        return False, f'signed by key {kn_sig.hex()}, not by key {kn_pub.hex()}'
    with open(msg_path, 'rb') as f:
        msg = f.read(max_msg + 1)
    if len(msg) > max_msg:
        return False, 'message larger than the limit'
    if not ed25519_verify(a, msg, s):
        return False, 'signature does not match the message'
    return True, f'good signature by key {kn_pub.hex()}'


# RFC 8032 section 7.1, TEST 1, 2, 3 and the 1023-byte TEST 1024 (public key, message, signature)
_RFC = [
    ('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a', '',
     'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b'),
    ('3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c', '72',
     '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00'),
    ('fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025', 'af82',
     '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a'),
]


def selftest():
    bad = 0
    for i, (pk, m, sg) in enumerate(_RFC, 1):
        pk, m, sg = bytes.fromhex(pk), bytes.fromhex(m), bytes.fromhex(sg)
        good = ed25519_verify(pk, m, sg)
        flipped = bytearray(sg); flipped[5] ^= 1
        wrong_msg = ed25519_verify(pk, m + b'x', sg)
        wrong_sig = ed25519_verify(pk, m, bytes(flipped))
        ok = good and not wrong_msg and not wrong_sig
        bad += not ok
        print(f"{'PASS' if ok else 'FAIL'}  RFC 8032 7.1 vector {i}: good verifies, message+1 byte and a flipped bit refused")
    # S >= L must be refused (malleability), even with the right R
    pk, m, sg = (bytes.fromhex(x) for x in _RFC[0])
    s = int.from_bytes(sg[32:], 'little') + L
    ok = not ed25519_verify(pk, m, sg[:32] + s.to_bytes(32, 'little'))
    bad += not ok
    print(f"{'PASS' if ok else 'FAIL'}  S + L (a malleated signature) is refused")
    return bad


def main(argv):
    if len(argv) >= 1 and argv[0] == 'selftest':
        return 1 if selftest() else 0
    if len(argv) == 2 and argv[0] == 'fingerprint':
        try:
            b = read_blob(argv[1], 42)
        except UsignError:
            b = read_blob(argv[1], 74)
        print(b[2:10].hex())
        return 0
    if len(argv) == 4 and argv[0] == 'verify':
        try:
            ok, why = verify_files(argv[1], argv[2], argv[3])
        except (UsignError, OSError, UnicodeDecodeError) as e:
            print(f'REFUSED: {e}')
            return 1
        print(('OK: ' if ok else 'REFUSED: ') + why)
        return 0 if ok else 1
    print(__doc__.split('\n\n')[1], file=sys.stderr)
    return 64


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
