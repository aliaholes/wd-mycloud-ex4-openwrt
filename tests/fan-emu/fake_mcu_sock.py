#!/usr/bin/python3 -I
# SPDX-License-Identifier: GPL-2.0-or-later
"""fake_mcu_sock.py — the fake front-panel micro on a unix socket (qemu's pci-serial chardev), for tests/qemu-e2e.sh.
Answers what ex4fan sends: ACK to DeviceReady; ACK + the 13-byte clock frame to the clock read; and
it sends button frames by itself (--events "SECONDS:HEX,SECONDS:HEX"). Records every byte it receives.
  fake_mcu_sock.py SOCKET OUT.json [--silent] [--secs N] [--clock HEX] [--events T:HEX,...]
Born Nov 17 2026 (EX4 run 7 prep)."""
import json, socket, sys, time
path, out = sys.argv[1], sys.argv[2]; silent = "--silent" in sys.argv
def opt(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default
secs = float(opt("--secs", "600")); clock = bytes.fromhex(opt("--clock", "fa0100030715301202171126fb"))
events = sorted((float(t), bytes.fromhex(h)) for t, h in (e.split(":") for e in opt("--events", "").split(",") if e))
s = socket.socket(socket.AF_UNIX)
for _ in range(100):
    try: s.connect(path); break
    except OSError: time.sleep(0.1)
else: sys.exit("no socket " + path)
s.settimeout(0.2); t0 = time.time(); stream = b""; buf = b""; frames = []; sent = []; RAW = {1: 80, 2: 75}; first = None
ACK = bytes.fromhex("fa3000000000fb")
def save(): json.dump({"frames": frames, "stream": stream.hex(), "leftover": buf.hex(), "events_sent": sent}, open(out, "w"))
while time.time() - t0 < secs:
    while events and first is not None and time.time() - first >= events[0][0] and not silent:      # counted from the guest's first frame
        t, e = events.pop(0); s.sendall(e); sent.append([round(time.time() - t0, 3), e.hex()])
    try: b = s.recv(256)
    except socket.timeout: continue
    except OSError: break
    if not b: break
    stream += b; buf += b
    while buf and buf[0] != 0xfa:            # line noise when the guest's UART comes up: recorded, not a frame
        buf = buf[1:]
    while len(buf) >= 7:
        f = buf[:7]; buf = buf[7:]; frames.append([round(time.time() - t0, 3), f.hex()])
        if first is None: first = time.time()
        if silent: continue
        if f[1] == 0x02 and f[2] == 0x00: s.sendall(ACK)
        elif f[1] == 0x03 and f[2] == 0x08 and f[3] in (1, 2): s.sendall(ACK + bytes([0xfa, 3, 8, f[3], 0, RAW[f[3]], 0xfb]))
        elif f.hex() == "fa0301000000fb": s.sendall(ACK)
        elif f.hex() == "fa0100030100fb": s.sendall(ACK + clock)
    save()
save()
