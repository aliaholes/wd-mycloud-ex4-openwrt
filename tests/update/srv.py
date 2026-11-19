#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""srv.py: a tiny release server for tests/update/run.sh, on 127.0.0.1 only. It serves one folder, and can misbehave
on purpose: --cut NAME sends NAME's true Content-Length but only half its body, then closes (a download cut off in
the middle). --stream NAME sends NAME with no Content-Length at all, then 1 MiB of zeros per second until the client
goes away (a server trying to fill the box's RAM).

  python3 -I tests/update/srv.py --dir DIR --port N [--cut NAME] [--stream NAME] --log FILE"""
import argparse
import http.server
import os
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', required=True)
    ap.add_argument('--port', type=int, required=True)
    ap.add_argument('--cut', action='append', default=[])
    ap.add_argument('--stream', action='append', default=[])
    ap.add_argument('--log', required=True)
    a = ap.parse_args()
    root = os.path.realpath(a.dir)
    logf = open(a.log, 'a', buffering=1)

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *x):
            logf.write(self.address_string() + ' ' + (x[0] % x[1:]) + '\n')

        def do_GET(self):
            name = self.path.split('?', 1)[0].rsplit('/', 1)[-1]
            p = os.path.join(root, name)
            if name in a.stream:
                self.send_response(200); self.send_header('Content-Type', 'application/octet-stream'); self.end_headers()
                try:
                    for _ in range(600):
                        self.wfile.write(b'\0' * (1 << 20)); self.wfile.flush(); time.sleep(0.05)
                except OSError:
                    pass
                return
            if not name or not os.path.isfile(p) or os.path.dirname(os.path.realpath(p)) != root:
                self.send_error(404); return
            data = open(p, 'rb').read()
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data[:len(data) // 2] if name in a.cut else data)
            if name in a.cut:
                self.wfile.flush(); self.close_connection = True

    http.server.ThreadingHTTPServer(('127.0.0.1', a.port), H).serve_forever()


if __name__ == '__main__':
    main()
