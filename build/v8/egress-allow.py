#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""egress-allow.py: a tiny HTTP(S) proxy for the v7/v8 image build that lets the build reach OpenWrt's own servers and
NOTHING else. OpenWrt's download.pl tries a package's upstream URL before (or after) OpenWrt's source mirror, and a
git-sourced package falls back to a git clone of its upstream. Run under this proxy (http_proxy / https_proxy point
here), every such attempt is refused at the CONNECT and written to the log, so every byte of source either comes
from an OpenWrt server or does not come at all. Whatever arrives is still hash-checked by OpenWrt's own build
(PKG_HASH / PKG_MIRROR_HASH / LINUX_KERNEL_HASH); this proxy never touches the bytes, it only picks who may answer.

  python3 -I egress-allow.py --port 18443 --log egress.log [--allow HOST ...]
  python3 -I egress-allow.py --unix PATH  --log egress.log      (v8: listen on a unix socket instead, mode 0600)

v8: the build itself runs in a network namespace with nothing but loopback (build-v8.sh, THE NET WALL); this proxy
runs OUTSIDE it and is reached through a unix socket (a socket file crosses network namespaces, a TCP port does not),
via netwall.py's relay inside. So a tool that ignores the proxy settings finds no network at all instead of a quiet
direct connection: the proxy's log is then the complete list of what the build reached.

Default allow list: git.openwrt.org, sources.cdn.openwrt.org, sources.openwrt.org, mirror2.openwrt.org,
downloads.openwrt.org (port 443 only). Plain-HTTP requests are refused whatever the host (every allowed host speaks
HTTPS). Log lines: "<unix time> ALLOW|REFUSE <host>:<port>". Listens on 127.0.0.1 only."""
import argparse
import select
import socket
import sys
import threading
import time

DEFAULT_ALLOW = ['git.openwrt.org', 'sources.cdn.openwrt.org', 'sources.openwrt.org', 'mirror2.openwrt.org',
                 'downloads.openwrt.org']


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=18443)
    ap.add_argument('--unix', help='v8: listen on this unix socket path (must not exist) instead of 127.0.0.1:PORT')
    ap.add_argument('--log', required=True)
    ap.add_argument('--allow', action='append', default=[])
    a = ap.parse_args()
    allow = set(h.lower() for h in (a.allow or DEFAULT_ALLOW))
    lock = threading.Lock()
    logf = open(a.log, 'a', buffering=1)

    def log(verdict, hp):
        with lock:
            logf.write(f"{int(time.time())} {verdict} {hp}\n")

    def relay(c, u):
        socks = [c, u]
        try:
            while True:
                r, _, x = select.select(socks, [], socks, 300)
                if x or not r:
                    return
                for s in r:
                    d = s.recv(65536)
                    if not d:
                        return
                    (u if s is c else c).sendall(d)
        except OSError:
            return

    def handle(c):
        try:
            c.settimeout(30)
            buf = b''
            while b'\r\n\r\n' not in buf:
                d = c.recv(4096)
                if not d or len(buf) > 16384:
                    return
                buf += d
            line = buf.split(b'\r\n', 1)[0].decode('latin1', 'replace')
            parts = line.split()
            if len(parts) < 2 or parts[0].upper() != 'CONNECT':
                host = parts[1] if len(parts) > 1 else '?'
                log('REFUSE', 'plain-http ' + host[:200])
                c.sendall(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                return
            hp = parts[1]
            host, _, port = hp.rpartition(':')
            host = host.strip('[]').lower()
            if host not in allow or port != '443':
                log('REFUSE', hp[:200])
                c.sendall(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                return
            try:
                u = socket.create_connection((host, 443), timeout=30)
            except OSError as e:
                log('FAILED', f"{hp} {e}")
                c.sendall(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                return
            log('ALLOW', hp)
            c.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
            rest = buf.split(b'\r\n\r\n', 1)[1]
            if rest:
                u.sendall(rest)
            c.settimeout(None); u.settimeout(None)
            relay(c, u)
            u.close()
        except OSError:
            pass
        finally:
            try:
                c.close()
            except OSError:
                pass

    if a.unix:
        import os
        if os.path.exists(a.unix):
            sys.exit(f"REFUSED: {a.unix} exists")
        s = socket.socket(socket.AF_UNIX)
        old = os.umask(0o177)
        s.bind(a.unix)
        os.umask(old)
        where = 'unix:' + a.unix
    else:
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(('127.0.0.1', a.port))
        where = f"127.0.0.1:{a.port}"
    s.listen(64)
    log('START', f"{where} allow={','.join(sorted(allow))}")
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


if __name__ == '__main__':
    sys.exit(main())
