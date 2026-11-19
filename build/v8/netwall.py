#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""netwall.py: THE NET WALL of the v8 image build (build-v8.sh image --netwall SOCK). Runs INSIDE a network namespace
that has only loopback (a systemd unit with PrivateNetwork=yes, or `unshare -n`), next to the build.

  python3 -I netwall.py relay PORT SOCK          listen on 127.0.0.1:PORT and pass every connection, byte for byte, to
                                                 the unix socket SOCK, where egress-allow.py (OUTSIDE the namespace)
                                                 decides who may answer. This is the build's only way out.
  python3 -I netwall.py prove PORT OUT           the receipt, written to OUT. Exit 0 only if every line holds:
      1. this namespace has no network interface but loopback (/sys/class/net)
      2. a name lookup of an OpenWrt host FAILS here (no resolver can be reached)
      3. a direct TCP connection to a public address FAILS here (no route), for two well-known anycast addresses
      4. through the relay, CONNECT to an OpenWrt host on 443 is ALLOWED by the proxy (the way out works)
      5. through the relay, CONNECT to a host outside the allow list is REFUSED (403)
So a tool that ignores http_proxy / https_proxy has no network at all, and the proxy's log is the complete list of
connections the build made. The probe sends nothing past the proxy's answer to CONNECT (no TLS, no request).
Born Nov 17 2026 (EX4 v8, the image reviewer's nit 4)."""
import os
import socket
import sys
import threading
import time


def relay(port, sock):
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', port))
    srv.listen(64)

    def pump(a, b):
        try:
            while True:
                d = a.recv(65536)
                if not d:
                    break
                b.sendall(d)
        except OSError:
            pass
        finally:
            for s in (a, b):
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def handle(c):
        u = socket.socket(socket.AF_UNIX)
        try:
            u.connect(sock)
        except OSError:
            c.close()
            return
        t = threading.Thread(target=pump, args=(u, c), daemon=True)
        t.start()
        pump(c, u)
        t.join(600)
        c.close()
        u.close()

    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


def prove(port, out):
    lines, ok = [], True

    def say(good, text):
        nonlocal ok
        ok = ok and good
        lines.append(("PASS  " if good else "FAIL  ") + text)

    ifs = sorted(os.listdir('/sys/class/net'))
    say(ifs == ['lo'], f"the build's network namespace has these interfaces: {' '.join(ifs)} (only lo = no way out but the relay)")
    try:
        r = socket.getaddrinfo('sources.cdn.openwrt.org', 443, proto=socket.IPPROTO_TCP)
        say(False, f"a name lookup of sources.cdn.openwrt.org FAILS here: it answered {r[0][4]}")
    except OSError as e:
        say(True, f"a name lookup of sources.cdn.openwrt.org FAILS here ({e.__class__.__name__}: {e})")
    for addr in ('1.1.1.1', '8.8.8.8'):
        s = socket.socket()
        s.settimeout(5)
        try:
            s.connect((addr, 443))
            say(False, f"a direct TCP connection to {addr}:443 FAILS here: it connected")
        except OSError as e:
            say(True, f"a direct TCP connection to {addr}:443 FAILS here ({e.__class__.__name__}: {e})")
        finally:
            s.close()

    def connect_via_relay(host):
        s = socket.create_connection(('127.0.0.1', port), timeout=30)
        s.sendall(f"CONNECT {host}:443 HTTP/1.1\r\nHost: {host}:443\r\n\r\n".encode())
        d = b''
        while b'\r\n' not in d:
            c = s.recv(256)
            if not c:
                break
            d += c
        s.close()
        return d.split(b'\r\n', 1)[0].decode('latin1')

    try:
        st = connect_via_relay('sources.cdn.openwrt.org')
        say(' 200 ' in st + ' ', f"through the relay, CONNECT sources.cdn.openwrt.org:443 is allowed by the proxy outside: {st!r}")
    except OSError as e:
        say(False, f"through the relay, CONNECT sources.cdn.openwrt.org:443: {e}")
    try:
        st = connect_via_relay('example.com')
        say(' 403 ' in st + ' ', f"through the relay, CONNECT example.com:443 (not on the allow list) is refused: {st!r}")
    except OSError as e:
        say(False, f"through the relay, CONNECT example.com:443: {e}")
    with open(out, 'w') as f:
        f.write(f"netwall proof, {time.strftime('%Y-%m-%d %H:%M:%S %Z')}, pid {os.getpid()}, netns {os.readlink('/proc/self/ns/net')}\n")
        f.write('\n'.join(lines) + '\n')
        f.write(f"RESULT {'WALLED' if ok else 'NOT WALLED'}\n")
    print('\n'.join(lines))
    return 0 if ok else 1


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == 'relay':
        relay(int(sys.argv[2]), sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == 'prove':
        sys.exit(prove(int(sys.argv[2]), sys.argv[3]))
    else:
        sys.exit(__doc__)
