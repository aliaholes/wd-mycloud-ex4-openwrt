#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""overlay-gate.py: THE OVERLAY GATE (v8; the image reviewer's nit 3). A bundle builder calls this on the overlay.cpio it
just made and REFUSES the bundle unless the overlay carries the security fix of Nov 17 2026, so a stale
build/mkoverlay.py can never again ship root's empty password field and a web server open to the LAN.

  python3 -I overlay-gate.py OVERLAY.cpio --pubkey KEY.pub (--webui WEBUI_DIR | --no-webui)

Checks (each prints PASS or FAIL; exit 0 only when every one passes):
  - the archive parses as newc to its TRAILER, and no entry is group- or world-writable
  - /etc/ex4/overlay-stamp says "mkoverlay v8 secfix=1 keyonly=1 webui=N" with N matching the flag
  - /etc/uci-defaults/99-ex4-trial turns an EMPTY root field into '*' (the exact v7 line) and turns ssh password
    logins off (PasswordAuth + RootPasswordAuth 'off')
  - /etc/dropbear/authorized_keys is exactly the one key of KEY.pub, mode 0600, in a 0700 folder
  - the overlay carries no /etc/shadow and no /etc/passwd of its own
  - --no-webui: 99-ex4-trial pins uhttpd to 127.0.0.1:80 and deletes the HTTPS listener and /ubus
    --webui:    99-ex4-trial does NOT touch uhttpd; every file of webui/FILES is in the overlay byte for byte with its
                mode; 95_ex4_webui removes every rpcd login and sets redirect_https; rpcd's unauthenticated ACL is the
                interface's (no session.login door)
Born Nov 17 2026 (EX4 v8)."""
import os
import sys


def entries(path):
    d = open(path, 'rb').read()
    p, out = 0, {}
    while True:
        if d[p:p + 6] != b'070701':
            sys.exit(f"FAIL  {path} is not a newc archive at byte {p}")
        f = [int(d[p + 6 + 8 * i:p + 14 + 8 * i], 16) for i in range(13)]
        mode, fs, ns = f[1], f[6], f[11]
        name = d[p + 110:p + 110 + ns - 1].decode()
        p = (p + 110 + ns + 3) & ~3
        body = d[p:p + fs]
        p = (p + fs + 3) & ~3
        if name == 'TRAILER!!!':
            return out
        out[name] = (mode, body)


def main():
    a = sys.argv[1:]
    if len(a) < 4 or a[1] != '--pubkey':
        sys.exit(__doc__)
    ovl, pub = a[0], a[2]
    if a[3] == '--no-webui' and len(a) == 4:
        webui = None
    elif a[3] == '--webui' and len(a) == 5:
        webui = a[4]
    else:
        sys.exit(__doc__)
    e = entries(ovl)
    fails = 0

    def check(ok, text):
        nonlocal fails
        print(("PASS  " if ok else "FAIL  ") + text)
        fails += 0 if ok else 1

    def body(n):
        return e.get(n, (0, b''))[1].decode('utf-8', 'replace')

    check(True, f"{ovl}: {len(e)} entries up to the TRAILER")
    loose = [n for n, (m, _) in e.items() if (m & 0o170000) != 0o120000 and m & 0o022]
    check(not loose, f"no entry is group- or world-writable (symlinks aside): {loose[:5]}")
    stamp = body('etc/ex4/overlay-stamp').strip()
    want = 'mkoverlay v8 secfix=1 keyonly=1 webui=%d' % (1 if webui else 0)
    check(stamp == want, f"etc/ex4/overlay-stamp is {want!r}: {stamp!r} (an older mkoverlay.py writes none)")
    u = body('etc/uci-defaults/99-ex4-trial')
    check("grep -q '^root::' /etc/shadow && sed -i 's/^root::/root:*:/' /etc/shadow" in u,
          "99-ex4-trial turns an EMPTY root password field into '*' (v7's exact line)")
    check("PasswordAuth='off'" in u and "RootPasswordAuth='off'" in u, "99-ex4-trial turns ssh password logins off (PasswordAuth, RootPasswordAuth)")
    key = open(pub).read().strip()
    ak = e.get('etc/dropbear/authorized_keys')
    check(ak is not None and ak[1].decode().strip() == key and (ak[0] & 0o777) == 0o600,
          "etc/dropbear/authorized_keys is exactly the given key, mode 0600")
    dd = e.get('etc/dropbear')
    check(dd is not None and (dd[0] & 0o777) == 0o700, "etc/dropbear is a 0700 folder")
    check('etc/shadow' not in e and 'etc/passwd' not in e, "the overlay carries no /etc/shadow or /etc/passwd of its own")
    loop = "uci -q add_list uhttpd.main.listen_http='127.0.0.1:80'" in u and 'uci -q delete uhttpd.main.listen_https' in u and 'uci -q delete uhttpd.main.ubus_prefix' in u
    if webui is None:
        check(loop, "no web interface: 99-ex4-trial pins uhttpd to 127.0.0.1:80, no HTTPS listener, no /ubus")
        check('etc/uci-defaults/95_ex4_webui' not in e and 'www-ex4/index.html' not in e, "no web interface file rides in")
    else:
        check(not any(l.lstrip().startswith('uci') and 'uhttpd' in l for l in u.splitlines()),
              "web interface: 99-ex4-trial runs no uci command on uhttpd (it would close the interface's door again)")
        n = bad = 0
        for line in open(os.path.join(webui, 'FILES')):
            if not line.strip() or line.startswith('#'):
                continue
            src, dst, mode = line.rstrip('\n').split('\t')
            got = e.get(dst.lstrip('/'))
            n += 1
            if got is None or got[1] != open(os.path.join(webui, src), 'rb').read() or (got[0] & 0o7777) != int(mode, 8):
                bad += 1
                print(f"      differs or missing: {dst}")
        check(n > 0 and bad == 0, f"web interface: all {n} files of webui/FILES are in the overlay byte for byte, with their modes")
        w = body('etc/uci-defaults/95_ex4_webui')
        check('while uci -q delete rpcd.@login[0]' in w and "redirect_https='1'" in w, "95_ex4_webui removes every rpcd login and makes port 80 redirect")
        un = body('usr/share/rpcd/acl.d/unauthenticated.json')
        check('"login"' not in un and 'setup_claim' in un, "rpcd's unauthenticated ACL is the interface's: no session.login door")
        check('etc/ex4/trial' in e, "etc/ex4/trial (the page's trial clock) is there")
    print(f"overlay-gate: {'OK' if not fails else 'REFUSED'} ({fails} check(s) failed)")
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
