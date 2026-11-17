#!/usr/bin/python3 -I
# SPDX-License-Identifier: GPL-2.0-or-later
"""fan-test.py — ex4fan against a FAKE front-panel micro on a pty. Off the box.
Nothing here touches the EX4. = fan-test.py (v4, run 6: every case kept) + the v5 cases: the two new frames (DeviceReady,
the clock read) are WD's own bytes; the clock frame is read the way WD's up_read_daemon + rtc read it; the system clock
is set only when it is unset; the micro's events are named and nothing is sent in answer.

  python3 -I fan-test.py --bin <ex4fan> [--qemu] --stock-capture tests/captures/stock-daemons-*.json (each one) ...
                          [--stock-read-daemon <your own copy of up_read_daemon>] --stock-rtc-run <wd_run.py run.json of WD's `rtc -s`>
                          --src <ex4fan.c> --work DIR [--slow]

--bin        the daemon under test: the native build, or (with --qemu) the static ARM build run by qemu-arm
--stock-capture   emu_capture.py's record of the bytes WD's own up_send_ctl + up_send_daemon put on the wire
--slow       also run the real-time case (36 s): WD's 300 ms retry cadence and the 30 s "never answered" limit

What it checks: the port settings; that the first frame is FAN HIGH; that every byte the daemon ever writes is one of
its six whitelisted frames and that those six equal WD's own bytes; the curve (and that it is never slower than WD's,
against a model of WD's state machine written from fan_control's disassembly); every fail-safe path; the supervisor.
Born Nov 16 2026 (EX4 run 6 prep)."""
import argparse, json, os, pty, random, re, select, signal, subprocess, sys, termios, threading, time

ap = argparse.ArgumentParser()
ap.add_argument("--bin", required=True); ap.add_argument("--qemu", action="store_true")
ap.add_argument("--stock-capture", required=True, action="append"); ap.add_argument("--stock-read-daemon")
ap.add_argument("--stock-rtc-run", required=True)
ap.add_argument("--src", required=True); ap.add_argument("--work", required=True); ap.add_argument("--slow", action="store_true")
A = ap.parse_args()
BIN = [os.path.abspath(A.bin)]
if A.qemu: BIN = ["qemu-arm"] + BIN
W = os.path.abspath(A.work)
if os.path.exists(W): sys.exit("REFUSED: %s exists" % W)
os.makedirs(W)
PASS = FAIL = 0
def ok(cond, what, detail=""):
    global PASS, FAIL
    if cond: PASS += 1; print("PASS  " + what)
    else: FAIL += 1; print("FAIL  " + what + ("   [" + str(detail)[:600] + "]" if detail != "" else ""))
    return cond

WHITELIST = {"fa0200010000fb": "FAN_LOW", "fa0200020000fb": "FAN_MEDIUM", "fa0200030000fb": "FAN_HIGH", "fa0200040000fb": "FAN_MAX",
             "fa0308010000fb": "THERM_SATA", "fa0308020000fb": "THERM_MAIN", "fa0301000000fb": "READY", "fa0100030100fb": "CLOCK_READ"}
CLOCK_OK = "fa0100030715301202171126fb"        # the frame WD's own up_read_daemon read as 26/11/17 12:30:15 (emu rx02)
ACK = bytes.fromhex("fa3000000000fb")

class Mcu(threading.Thread):
    """the fake micro: reads the pty, answers like WD's (ACK; thermistor data), and turns the fake fan"""
    def __init__(self, root, ack=True, data=True, raw={1: 80, 2: 75}, rpm={1: 1035, 2: 1800, 3: 2600, 4: 3400}, tach=True,
                 silent=False, die_at=None, noise=False, ack_fan=True, fan_dead=False, fan_dead_until=None,
                 clock=CLOCK_OK, ack_ready=True, ack_clock=True, inject=()):
        super().__init__(daemon=True)
        self.master, self.slave = pty.openpty()
        self.root = root; os.symlink(os.ttyname(self.slave), os.path.join(root, "tty"))
        self.ack, self.data, self.raw, self.rpm, self.tach, self.silent, self.die_at = ack, data, raw, rpm, tach, silent, die_at
        self.noise, self.ack_fan, self.fan_dead, self.fan_dead_until = noise, ack_fan, fan_dead, fan_dead_until
        self.t0 = time.time(); self.frames = []; self.stream = b""; self.buf = b""; self.stop = False; self.level = None
        self.termios = None
        self.clock, self.ack_ready, self.ack_clock, self.inject = clock, ack_ready, ack_clock, sorted(inject)
    def settach(self):
        if not self.tach: return
        dead = self.fan_dead or (self.fan_dead_until is not None and time.time() - self.t0 < self.fan_dead_until)
        v = 0 if (dead or self.level is None) else self.rpm[self.level]
        with open(os.path.join(self.root, "tach.new"), "w") as f: f.write("%d\n" % v)
        os.rename(os.path.join(self.root, "tach.new"), os.path.join(self.root, "tach"))
    def run(self):
        self.settach()
        while not self.stop:
            r, _, _ = select.select([self.master], [], [], 0.05)
            if self.fan_dead_until is not None: self.settach()
            while self.inject and time.time() - self.t0 >= self.inject[0][0]:      # v5: frames the micro sends by itself (buttons)
                os.write(self.master, bytes.fromhex(self.inject.pop(0)[1]))
            if not r: continue
            try: b = os.read(self.master, 256)
            except OSError: break
            if self.termios is None:
                try: self.termios = termios.tcgetattr(self.slave)
                except Exception: pass
            self.stream += b; self.buf += b
            while len(self.buf) >= 7:
                f = self.buf[:7]; self.buf = self.buf[7:]
                t = time.time() - self.t0; h = f.hex(); self.frames.append((round(t, 3), h))
                dead = self.silent or (self.die_at is not None and t >= self.die_at)
                if dead: continue
                if self.noise:      # junk, half a frame, a 15-byte frame, a button event, then the real answer
                    os.write(self.master, bytes([0x00, 0x13, 0xfb, 0xfa, 0x30, 0x00]) + bytes.fromhex("fa03050001010203040506070809fb") + bytes.fromhex("fa2300000000fb"))
                if h.startswith("fa0200") and f[3] in (1, 2, 3, 4):
                    self.level = f[3]; self.settach()
                    if self.ack and self.ack_fan: os.write(self.master, ACK)
                elif h.startswith("fa0308") and f[3] in (1, 2):
                    if self.ack: os.write(self.master, ACK)
                    if self.data: os.write(self.master, bytes([0xfa, 0x03, 0x08, f[3], 0x00, self.raw[f[3]], 0xfb]))
                elif h == "fa0301000000fb":
                    if self.ack and self.ack_ready: os.write(self.master, ACK)
                elif h == "fa0100030100fb":
                    if self.ack and self.ack_clock: os.write(self.master, ACK)
                    if self.clock: os.write(self.master, bytes.fromhex(self.clock))

def run(name, secs, drives="sda 40\nsdb 41\nsdc 41\nsdd 43\n", soc=57000, fast=True, script=None, sig=signal.SIGTERM, sysclock=None, **mk):
    """one daemon run against one fake micro; returns everything it left behind"""
    root = os.path.join(W, name); os.makedirs(root)
    if drives is not None: open(os.path.join(root, "drives"), "w").write(drives)
    open(os.path.join(root, "soc"), "w").write("%d\n" % soc)
    if sysclock is not None: open(os.path.join(root, "now"), "w").write("%d\n" % sysclock)
    m = Mcu(root, **mk); m.start()
    args = BIN + ["daemon", "--test-root", root, "--foreground"] + (["--fast"] if fast else [])
    p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    t0 = time.time(); done = False
    while time.time() - t0 < secs:
        if script: script(time.time() - t0, root, p, m)
        if p.poll() is not None: done = True; break
        time.sleep(0.05)
    if not done:
        p.send_signal(sig)
        try: p.wait(timeout=8)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
    time.sleep(0.2); m.stop = True
    rd = lambda f: open(os.path.join(root, f)).read() if os.path.exists(os.path.join(root, f)) else ""
    return {"root": root, "rc": p.returncode, "self_ended": done, "frames": m.frames, "stream": m.stream, "termios": m.termios, "kmsg": rd("kmsg"),
            "log": rd("ex4fan.log"), "status": rd("ex4fan.status"), "reboot": rd("reboot"), "notes": rd("ex4-notes"), "clockset": rd("clockset"), "out": p.stdout.read().decode("latin1"), "secs": time.time() - t0}

def wire_ok(r, what):
    """THE WALL: the byte stream is whole 7-byte frames and every one is whitelisted"""
    s = r["stream"]; bad = [s[i:i + 7].hex() for i in range(0, len(s), 7) if s[i:i + 7].hex() not in WHITELIST]
    return ok(len(s) % 7 == 0 and not bad and len(s) > 0, "%s: every byte on the wire is a whole whitelisted frame (%d frames)" % (what, len(s) // 7), bad[:5])
def fans(r): return [WHITELIST[h] for _, h in r["frames"] if h.startswith("fa0200") and h in WHITELIST]
def dedup(x):
    o = []
    for i in x:
        if not o or o[-1] != i: o.append(i)
    return o

# ---------------- 0. static: the whitelist is WD's own bytes; one writer; the table; the LUT ----------------
print("== static")
cap = {"runs": []}; stock = {}
for c in A.stock_capture: cap["runs"] += json.load(open(c))["runs"]
for r in cap["runs"]:
    if "cmd" in r:
        w = "".join(x[2] for x in r["wire"] if x[1] == "box->mcu"); fr = sorted(set(w[i:i + 14] for i in range(0, len(w), 14)))
        if len(fr) == 1: stock[r["cmd"]] = fr[0]
mine = dict(l.split() for l in subprocess.run(BIN + ["frames"], stdout=subprocess.PIPE).stdout.decode().splitlines())
want = {"FAN_LOW": "FanControl 1", "FAN_MEDIUM": "FanControl 2", "FAN_HIGH": "FanControl 3", "FAN_MAX": "FanControl 4", "THERM_SATA": "GetThemister 1", "THERM_MAIN": "GetThemister 2",
        "READY": "DeviceReady", "CLOCK_READ": "RDateAndTime"}
ok(set(mine) == set(want) and len(mine) == 8, "the daemon's table holds eight frames (v4's six + READY + CLOCK_READ): " + " ".join(sorted(mine)))
for k, c in want.items():
    ok(c in stock and mine.get(k) == stock[c], "%-10s %s == the bytes WD's own `up_send_ctl %s` put on the wire (%s)" % (k, mine.get(k), c, stock.get(c)))
ok("FanControl 0" in stock and stock["FanControl 0"] not in mine.values(), "WD's fan-STOP frame (%s) is not in the daemon's table" % stock.get("FanControl 0"))
ok({v: k for k, v in mine.items()} == {h: n for h, n in WHITELIST.items()}, "this test's whitelist == the daemon's table")
src = open(A.src).read(); code = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
ok(len(re.findall(r"\bwrite\s*\(\s*tty\b", code)) == 1 and "write(tty, TX[idx], sizeof TX[idx])" in code, "source: exactly one write to the port, and it writes TX[idx]")
ok(not re.findall(r"\b(pwrite|writev|sendto|send|dprintf|fprintf|fputs|fputc|fwrite)\s*\(\s*tty\b", code) and not re.findall(r"tcsendbreak|TIOCSTI|TIOCMSET|TIOCMBIS", code), "source: no other call can put a byte or a line state on the port")
wopens = sorted(re.findall(r'open\(([^,()]+), O_(?:WRONLY|RDWR)', code))
ok(wopens == sorted(['path', 'path', '"/dev/kmsg"', 'node', '"/sys/class/gpio/export"', 'tmp', '"/proc/sysrq-trigger"', '"/dev/null"']) and len(re.findall(r"O_WRONLY|O_RDWR", code)) == 8,
   "source: the eight opens for writing are the log files (2), /dev/kmsg (2), the status file, the sysfs GPIO export, the sysrq trigger, /dev/null and the port", wopens)
body = code[code.index("static int smart_temp"):code.index("static void drives_read")]
ok("open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)" in body and "O_WRONLY" not in body and "O_RDWR" not in body and "write(" not in body and "SG_DXFER_FROM_DEV" in body and "SG_DXFER_TO" not in body,
   "source: a disk is opened O_RDONLY and the one SG_IO moves data FROM the device (SMART READ DATA)")
binb = open(A.bin, "rb").read(); tab = b"".join(bytes.fromhex(mine[k]) for k in ("FAN_LOW", "FAN_MEDIUM", "FAN_HIGH", "FAN_MAX", "THERM_SATA", "THERM_MAIN"))
tab8 = tab + bytes.fromhex(mine["READY"]) + bytes.fromhex(mine["CLOCK_READ"])
ok(binb.count(tab) == 1 and binb.count(tab8) == 1, "binary: the frame table is in it once, as one constant block of 56 bytes (v4's 42 bytes first, unchanged)")
others = {c: f for c, f in stock.items() if f not in mine.values()}
ok(len(others) >= 10 and not [c for c, f in others.items() if bytes.fromhex(f) in binb], "binary: none of the %d other frames WD's up_send_ctl was seen to send is in it (fan stop, the 6 PwrLedRed frames, MCUVer, GetOnCause, WOLStat, APRStat ...)" % len(others), [c for c, f in others.items() if bytes.fromhex(f) in binb])
allfr = set(m.group(0).hex() for m in re.finditer(rb"\xfa[\x00-\x57][\x00-\x10][\x00-\x0f][\x00-\x01]\x00\xfb", binb))
ok(allfr == set(mine.values()), "binary: every 7-byte run that looks like a host frame (FA cmd sub arg 0/1 00 FB) is one of the eight", sorted(allfr - set(mine.values())))
ok(len(re.findall(r"clock_settime\s*\(", code)) == 1 and "if (sys >= CLOCK_UNSET) return;" in code and code.index("if (sys >= CLOCK_UNSET) return;") < code.index("clock_settime(CLOCK_REALTIME"), "source: the system clock is set in one place, and only after the check that it is still unset (before 2026)")
rows = re.findall(r"\{\s*0xfa,\s*0x([0-9a-f]{2}),\s*0x([0-9a-f]{2}),\s*0x([0-9a-f]{2}),\s*0x([0-9a-f]{2}),\s*0x([0-9a-f]{2}),\s*0xfb\s*\}", code)
ok(len(rows) == 8 and not [r for r in rows if r[0] == "01" and r[2] in ("02", "04", "06")] and "clock_settime" in code and "WDateAndTime" not in code,
   "source: the table has eight rows and none is a clock WRITE (WD's are FA 01 reg 02 .., FA 01 00 04 .., FA 01 00 06 ..); the one clock frame is the read FA 01 00 03", rows)
ok(not [r for r in rows if r[0] == "03" and r[1] in ("03", "10", "05", "09", "12", "02")] and not [r for r in rows if r[0] in ("04", "55")],
   "source: no row is a shutdown / reset / power-LED / version / wake / LCD frame (03 03 .., 03 10 .., 04 .., 55 ..)", rows)
ev = dict(l.split() for l in subprocess.run(BIN + ["events"], stdout=subprocess.PIPE).stdout.decode().splitlines())
seen = {}
for r in cap["runs"]:
    if "reply" in r and r["xml"]:
        m = re.search(r"SET /runtime/(?:button|MFG|usbBackup) = Button:(\w+)", r["xml"][0])
        if m: seen[r["reply"][2:4]] = m.group(1)
ok(len(seen) >= 13 and all(ev.get(b) == nm for b, nm in seen.items()), "the %d button names == what WD's own up_read_daemon stored for each frame (run under qemu-arm): %s" % (len(seen), " ".join("%s=%s" % kv for kv in sorted(seen.items()))), {b: (nm, ev.get(b)) for b, nm in seen.items() if ev.get(b) != nm})
ok({"40", "41", "42", "20"} <= set(ev) and len(ev) == 17, "the events table holds 17 names (13 buttons + PWR_LOST, APR_STAT, WOL_STAT, RTCAlarm)")
wdrtc = [r for r in cap["runs"] if r.get("reply") == CLOCK_OK]
ok(wdrtc and wdrtc[0]["xml"] and "SET /runtime/rtc = 26/11/17 Mon 12:30:15" in wdrtc[0]["xml"][0], "WD's own up_read_daemon read the test's clock frame %s as 26/11/17 12:30:15" % CLOCK_OK, wdrtc and wdrtc[0]["xml"])
rtcrun = json.load(open(A.stock_rtc_run)); wd_epoch = [int(m.group(1)) for l in rtcrun["strace"] for m in [re.search(r"settimeofday\(\{tv_sec = (\d+)", l)] if m]
ok(rtcrun["args"] == ["-s"] and wd_epoch == [1794918615], "WD's own `rtc -s`, given that time, called settimeofday(%s) = 2026-11-17 12:30:15 UTC (so the micro's clock is UTC)" % wd_epoch)
ok(binb.count(b"\xfa\x02\x00\x00\x00\x00\xfb") == 0, "binary: WD's fan-stop frame is nowhere in it")
lut = bytes.fromhex(subprocess.run(BIN + ["lut"], stdout=subprocess.PIPE).stdout.decode().strip())
if A.stock_read_daemon:     # optional: needs YOUR OWN copy of the stock firmware's up_read_daemon (never shipped here)
    rdd = open(A.stock_read_daemon, "rb").read()
    ok(len(lut) == 192 and rdd[0x204c + (0x12644 - 0x1204c):0x204c + 0x6b8] == lut, "the thermistor table == the 192 bytes at 0x12644 in WD's up_read_daemon")
else:
    ok(len(lut) == 192, "the thermistor table has 192 entries")
    print("SKIP  the thermistor table against the bytes in WD's up_read_daemon (give --stock-read-daemon <your own copy>)")
for r in cap["runs"]:
    if "reply" in r and r["xml"]:
        m = re.search(r"SET /runtime/themister/(sata|main) = (\d+)", r["xml"][0]); raw = bytes.fromhex(r["reply"])[5]
        if m:
            v = lut[raw] if raw < 192 else 0
            ok(v == int(m.group(2)), "thermistor raw 0x%02x: the table says %d C, WD's own up_read_daemon (run under qemu-arm) stored %s C" % (raw, v, m.group(2)))

# ---------------- 1. the curve against a model of WD's state machine ----------------
print("== curve")
def stock_step(state, r6, r7, T, fp=10):
    """fan_control's automatic loop, one pass (from its disassembly: cases at ac10/ac34/abd4/abac, new state = max(status1, status2))"""
    if T <= 0: return state, r6, r7
    if state == 1:
        if T > fp + 51: r6 = 2
        if 65 - T <= 3: r7 = 2
    elif state == 2:
        if T > fp + 53: r6 = 3
        elif T <= fp + 47: r6 = 1
        if 65 - T <= 1: r7 = 3
        elif 65 - T > 6: r7 = 1
    elif state == 3:
        if T > fp + 55: r6 = 4
        elif T <= fp + 50: r6 = 2
        if 65 - T < 0: r7 = 4
        elif 65 - T > 4: r7 = 2
    else:
        if T <= fp + 52: r6 = 3
        if 65 - T > 3: r7 = 3
    return max(r6, r7), r6, r7
def mine_walk(start, ts): return [int(x) for x in subprocess.run(BIN + ["curve", str(start)] + [str(t) for t in ts], stdout=subprocess.PIPE).stdout.decode().split()]
ok(mine_walk(3, [43, 43, 41, 46, 47, 48, 50, 49, 45, 44, 41, 60, 30]) == [2, 2, 1, 2, 2, 3, 4, 4, 3, 2, 1, 4, 3], "the walk 43 43 41 46 47 48 50 49 45 44 41 60 30 from HIGH gives MED MED LOW MED MED HIGH MAX MAX HIGH MED LOW MAX HIGH")
ok(all(mine_walk(s, [t])[0] == 4 for s in (1, 2, 3, 4) for t in range(50, 100)), "MAX at 50 C and above, from every state, in one reading")
ok(all(mine_walk(s, [t])[0] >= 1 for s in (1, 2, 3, 4) for t in range(-5, 46)), "never below LOW")
random.seed(20261116); worse = []; same16 = 0; n = 0
for trial in range(300):
    ts = []; t = random.randint(25, 70)
    for _ in range(60): t = max(15, min(80, t + random.choice([-4, -2, -1, -1, 0, 0, 1, 1, 2, 5]))); ts.append(t)
    m = mine_walk(1, ts); s, r6, r7 = 1, 1, 1
    for i, T in enumerate(ts):
        s, r6, r7 = stock_step(s, r6, r7, T); n += 1
        if m[i] < s: worse.append((trial, i, T, m[i], s))
ok(not worse, "300 random temperature walks (%d readings): the daemon's level is never below WD's own level at the same reading" % n, worse[:3])
# and it IS WD's curve, 16 C lower: WD's machine fed T+16, stepped to its fixed point on the way up
bad = []
for trial in range(300):
    ts = []; t = random.randint(20, 60)
    for _ in range(60): t = max(10, min(70, t + random.choice([-4, -2, -1, -1, 0, 0, 1, 1, 2, 5]))); ts.append(t)
    m = mine_walk(1, ts); s, r6, r7 = 1, 1, 1
    for i, T in enumerate(ts):
        p = s; s, r6, r7 = stock_step(s, r6, r7, T + 16)
        while s > p and s < 4:
            p = s; s2, r6b, r7b = stock_step(s, r6, r7, T + 16)
            if s2 <= s: break
            s, r6, r7 = s2, r6b, r7b
        if m[i] != s: bad.append((trial, i, T, m[i], s)); break
ok(not bad, "300 more walks: the daemon's state == WD's machine fed (T + 16), climbing as far as it goes in one reading", bad[:3])

# ---------------- 2. the normal run ----------------
print("== normal run (fast clock: every time limit ten times shorter)")
r = run("normal", 14)
t = r["termios"]
ok(t is not None and t[4] == termios.B19200 and t[5] == termios.B19200 and (t[2] & termios.CSIZE) == termios.CS8 and not t[2] & termios.PARENB and not t[2] & termios.CSTOPB
   and not t[2] & termios.CRTSCTS and not t[0] & (termios.IXON | termios.IXOFF) and not t[3] & (termios.ICANON | termios.ECHO | termios.ISIG) and not t[1] & termios.OPOST,
   "the port is set to 19200 8N1, raw, no flow control (read back from the pty)", t and t[:6])
ok(r["frames"] and r["frames"][0][1] == "fa0200030000fb", "the FIRST frame on the wire is FAN HIGH", r["frames"][:3])
wire_ok(r, "normal")
ok("cmd FAN=3(HIGH) ack=1 tries=1 why=start: first action" in r["kmsg"], "the first command is logged, ACKed at the first try")
ok(dedup(fans(r)) == ["FAN_HIGH", "FAN_MEDIUM", "FAN_HIGH"], "drives at 43 C: HIGH for the first minute, then MEDIUM (43 <= 44), never LOW (43 > 41); HIGH again when told to stop", dedup(fans(r)))
ok(r["frames"] and min(tt for tt, h in r["frames"] if h == "fa0200020000fb") >= 5.5, "the step down comes only after the first-minute hold (6 s on the fast clock)")
st = [l for l in r["kmsg"].splitlines() if " status " in l]
ok(st and re.search(r"rpm=(2600|1800) tach=ok drives=sda:40,sdb:41,sdc:41,sdd:43 main=50 sata=47 soc=57 T=43 micro=answers", st[-1]) is not None, "status line: rpm, four drive temperatures, both thermistors (raw 75 -> 50 C, raw 80 -> 47 C), SoC, T=43", st[-1:] )
ok(r["rc"] == 0 and not r["reboot"] and "FAILSAFE" not in r["kmsg"], "no fail-safe, no reboot; SIGTERM ends it with exit 0")
ok(fans(r)[-1] == "FAN_HIGH" and "stopping: the fan is left at HIGH" in r["kmsg"], "told to stop, it leaves the fan at HIGH")
ok(os.path.exists(os.path.join(r["root"], "ex4fan.status")) and "level=" in r["status"], "/tmp/ex4fan.status holds the state line")
ok({h for _, h in r["frames"]} >= {"fa0308010000fb", "fa0308020000fb"}, "both thermistors are asked")
hs = [h for _, h in r["frames"]]
ok(hs.count("fa0301000000fb") == 1 and "cmd READY (WD's DeviceReady) ack=1 tries=1 (try 1 of 2)" in r["kmsg"], "v5: DeviceReady goes out once and is ACKed", hs.count("fa0301000000fb"))
ok(hs.index("fa0301000000fb") > max(hs.index("fa0308010000fb"), hs.index("fa0308020000fb"), hs.index("fa0200030000fb")) and min(tt for tt, h in r["frames"] if h == "fa0301000000fb") >= 0.9,
   "v5: ... after FAN HIGH and the first full reading, not before 1 s on the fast clock (10 s real)")
ok(hs.count("fa0100030100fb") == 1 and "clock: the micro says 2026-11-17 12:30:15 UTC (raw 15 30 12 02 17 11 26" in r["kmsg"], "v5: the clock is asked once; the answer is logged as 2026-11-17 12:30:15 UTC, as WD's reader has it", hs.count("fa0100030100fb"))
ok(not r["clockset"] and " ready=acked events=0 clock=read" in r["status"] and "SET from the micro" not in r["kmsg"], "v5: a system clock that is already set (this host's) is left alone: clock=read, nothing set", r["status"][-80:])

r = run("cool", 14, drives="sda 35\nsdb 36\n", raw={1: 110, 2: 100})
ok(dedup(fans(r)) == ["FAN_HIGH", "FAN_LOW", "FAN_HIGH"] and "curve HIGH -> MEDIUM at T=36" in r["kmsg"] and "curve MEDIUM -> LOW at T=36" in r["kmsg"],
   "drives at 36 C, board 37 C: the curve steps HIGH -> MEDIUM -> LOW one reading at a time under the first-minute hold, then LOW goes on the wire", dedup(fans(r)))
wire_ok(r, "cool")

def heat(t, root, p, m):
    v = 43 if t < 7 else 47 if t < 10 else 49 if t < 13 else 52
    open(os.path.join(root, "drives.new"), "w").write("sda 40\nsdb %d\n" % v); os.rename(os.path.join(root, "drives.new"), os.path.join(root, "drives"))
r = run("heat", 19, script=heat)
ok(dedup(fans(r)) == ["FAN_HIGH", "FAN_MEDIUM", "FAN_HIGH", "FAN_MAX", "FAN_HIGH"] and "curve MEDIUM -> HIGH at T=49" in r["kmsg"] and "curve HIGH -> MAX at T=52" in r["kmsg"],
   "a drive climbing 43 -> 47 -> 49 -> 52 C: MEDIUM, stays MEDIUM at 47, HIGH at 49, MAX at 52 (then HIGH when told to stop)", dedup(fans(r)))
ok(not r["reboot"] and "FAILSAFE" not in r["kmsg"], "52 C is below the 55 C limit: MAX, no reboot")
wire_ok(r, "heat")

# ---------------- 3. the fail-safes ----------------
print("== fail-safes")
def hot(t, root, p, m):
    if t > 4 and not os.path.exists(os.path.join(root, "hotdone")):
        open(os.path.join(root, "drives.new"), "w").write("sda 40\nsdb 41\nsdc 41\nsdd 56\n"); os.rename(os.path.join(root, "drives.new"), os.path.join(root, "drives")); open(os.path.join(root, "hotdone"), "w").close()
r = run("drive-hot", 20, script=hot)
ok(r["self_ended"] and "REBOOT" in r["reboot"] and "FAILSAFE reason=drive-hot sdd=56C" in r["kmsg"], "a drive at 56 C: FAILSAFE drive-hot, reboot", r["kmsg"][-300:])
ok(fans(r)[-1] == "FAN_MAX", "the last fan frame before the reboot is MAX")
ok("FAILSAFE reason=drive-hot" in r["notes"], "the reason is in /tmp/ex4-notes (the ex4log disk log carries that file)")
wire_ok(r, "drive-hot")

r = run("silent", 20, silent=True)
ok(r["self_ended"] and "FAILSAFE reason=micro-never-answered" in r["kmsg"] and "REBOOT" in r["reboot"], "a micro that never answers: FAILSAFE micro-never-answered, reboot", r["kmsg"][-300:])
ok(3.0 <= r["secs"] <= 20, "... %.1f s after the start on the fast clock (the limits are ten times shorter, WD's 10 x 300 ms tries per command are not: the real-clock case below times the 30 s)" % r["secs"])
ok(r["frames"][0][1] == "fa0200030000fb" and [h for _, h in r["frames"][:10]] == ["fa0200030000fb"] * 10, "FAN HIGH is sent 10 times before anything else (WD's retry count)")
ok(not [h for _, h in r["frames"] if h in ("fa0301000000fb", "fa0100030100fb")], "v5: a micro that never answers is never sent DeviceReady or the clock read")
ok("cmd FAN=3(HIGH) ack=0 tries=10" in r["kmsg"], "the unanswered command is logged with ack=0")
wire_ok(r, "silent")

r = run("dies", 30, die_at=5.0)
ok(r["self_ended"] and "FAILSAFE reason=micro-went-silent" in r["kmsg"] and "REBOOT" in r["reboot"], "a micro that stops answering: FAILSAFE micro-went-silent, reboot", r["kmsg"][-300:])
ok(15 <= r["secs"] <= 26, "... %.1f s into the run (silent from 5 s, limit 12 s on the fast clock)" % r["secs"])
wire_ok(r, "dies")

r = run("rpm-zero", 20, fan_dead=True)
ok(r["self_ended"] and "FAILSAFE reason=rpm-zero" in r["kmsg"] and "REBOOT" in r["reboot"], "the tachometer reads 0: FAILSAFE rpm-zero, reboot", r["kmsg"][-300:])
ok("rpm reads 0 with FAN=3 commanded: fan to MAX" in r["kmsg"] and "FAN_MAX" in fans(r), "at the first 0 reading the fan is sent to MAX")
z = [float(m.group(1)) for m in re.finditer(r"\[\s*([0-9.]+)\] rpm reads 0", r["log"])]; f = [float(m.group(1)) for m in re.finditer(r"\[\s*([0-9.]+)\] FAILSAFE", r["log"])]
ok(z and f and 2.9 <= f[0] - z[0] <= 4.5, "the reboot comes %.1f s after the first 0 reading (limit 3 s on the fast clock = 30 s real)" % (f[0] - z[0] if z and f else -1))
wire_ok(r, "rpm-zero")

r = run("rpm-back", 14, fan_dead_until=2.0)
ok(not r["reboot"] and "rpm is back" in r["kmsg"] and "FAILSAFE" not in r["kmsg"], "a fan that reads 0 for 2 s and then turns: no reboot, 'rpm is back' logged", r["kmsg"][-400:])
ok("FAN_MAX" in fans(r) and dedup(fans(r))[-2] in ("FAN_MEDIUM", "FAN_HIGH"), "... MAX while it read 0, back to the curve afterwards", dedup(fans(r)))

print("== floors")
r = run("no-tach", 14, drives="sda 35\n", raw={1: 110, 2: 100}, tach=False)
ok(set(fans(r)) == {"FAN_HIGH"} and not r["reboot"] and "tach=none" in r["status"], "no tachometer: the fan never goes below HIGH (drives at 35 C), no reboot", dedup(fans(r)))
r = run("drive-unreadable", 14, drives="sda 35\nsdb -1\n", raw={1: 110, 2: 100})
ok(set(fans(r)) == {"FAN_HIGH"} and "sdb:?" in r["status"], "one drive whose temperature cannot be read: never below HIGH", dedup(fans(r)))
r = run("no-drives", 14, drives=None, raw={1: 110, 2: 100})
ok(dedup(fans(r)) == ["FAN_HIGH", "FAN_LOW", "FAN_HIGH"] and "drives=none" in r["status"] and "T=27" in r["status"], "no drives at all (empty bays): the board thermistor alone drives the curve (37 C - 10 = 27: LOW)", dedup(fans(r)))
r = run("blind", 14, drives=None, data=False)
ok("FAN_MAX" in fans(r) and "no temperature at all: MAX" in r["kmsg"] and not r["reboot"], "no drive temperature and no thermistor data (ACKs only): MAX, no reboot", dedup(fans(r)))
r = run("soc-hot", 10, soc=93000, drives="sda 35\n", raw={1: 110, 2: 100})
ok("FAN_MAX" in fans(r) and "SoC hot: MAX" in r["kmsg"], "SoC thermal zone at 93 C: MAX")

print("== a micro that behaves differently")
r = run("noise", 20, noise=True)
ok(r["rc"] == 0 and not r["reboot"] and "cmd FAN=3(HIGH) ack=1" in r["kmsg"] and "main=50 sata=47" in r["status"], "junk, a half frame, a 15-byte frame and a button event before every answer: still ACKed, thermistors still read, no crash", r["kmsg"][-300:])
ok(r["kmsg"].count("micro sent a 15-byte frame this daemon has no use for") == 12 and r["kmsg"].count("no use for") == 12, "v5: the foreign 15-byte frames are logged 12 times, then counted only", r["kmsg"].count("no use for"))
nev = r["kmsg"].count("event PWRPush: power button down (WD's manufacturing mode) (frame 23 00 00 00 00): logged only, no action")
ok(nev >= 10 and nev <= 40 and " events=%d " % nev in r["status"],
   "v5: the button event in the noise is NAMED (PWRPush) every time (%d times, the state line counts the same); the 40-line cap is the events-flood case" % nev, (nev, r["status"][-60:]))
wire_ok(r, "noise")
r = run("no-fan-ack", 14, ack_fan=False)
ok(not r["reboot"] and "cmd FAN=3(HIGH) ack=0 tries=10" in r["kmsg"] and "micro=answers" in r["status"] and "the last fan command was not ACKed: again" in r["kmsg"], "a micro that answers the thermistors but never ACKs a fan frame: no reboot, the command is sent again every 1.5 s (15 s real), ack=0 on record")
ok("fa0301000000fb" not in [h for _, h in r["frames"]] and " ready=not-sent " in r["status"], "v5: DeviceReady is NOT sent while the fan command stands un-ACKed (the host does not say 'all is well')")
wire_ok(r, "no-fan-ack")

print("== v5: the clock, DeviceReady, the micro's events")
r = run("clock-unset", 8, sysclock=86400)
ok("SETCLOCK 1794918615" in r["clockset"] and r["clockset"].count("SETCLOCK") == 1 and "clock: the system clock was unset (86400): SET from the micro's clock to 2026-11-17 12:30:15 UTC" in r["kmsg"] and " clock=set" in r["status"],
   "a system clock still in 1970: SET, once, to 1794918615 = the value WD's own rtc -s computed from the same frame", r["clockset"])
wire_ok(r, "clock-unset")
r = run("clock-2014", 8, sysclock=86400, clock="fa0100030700000004010114fb")
ok(not r["clockset"] and "the micro says 2014-01-01 00:00:00 UTC" in r["kmsg"] and "the micro's date is before 2026 or past 2099: not used" in r["kmsg"] and " clock=read" in r["status"],
   "a micro that says 2014-01-01 (WD's own default date) with an unset system clock: logged, NOT used", r["kmsg"][-300:])
r = run("clock-garbage", 8, sysclock=86400, clock="fa010003071a301202171126fb")
ok(not r["clockset"] and "clock frame that is not a date (raw 1a 30 12 02 17 11 26): ignored" in r["kmsg"] and " clock=none" in r["status"] and not r["reboot"], "a clock frame with a byte that is not BCD: ignored, logged, nothing set", r["kmsg"][-300:])
r = run("clock-other13", 8, clock="fa0900030715301202171126fb")
ok("micro sent a 13-byte frame this daemon has no use for: 09 00 03 07 15 30 12 02 17 11 26" in r["kmsg"] and " clock=none" in r["status"], "a 13-byte frame with another head: on record, not taken as a clock")
r = run("clock-none", 12, clock=None)
hs = [h for _, h in r["frames"]]
ok(hs.count("fa0100030100fb") == 2 and r["kmsg"].count("no clock frame came back") == 2 and "(try 2 of 2): ACKed, no clock frame came back" in r["kmsg"] and " clock=none" in r["status"] and not r["reboot"],
   "a micro that ACKs the clock read but sends no clock: asked twice (3 s apart on the fast clock = 30 s real), then never again; no reboot", hs.count("fa0100030100fb"))
wire_ok(r, "clock-none")
r = run("clock-data-only", 8, ack_clock=False)
ok([h for _, h in r["frames"]].count("fa0100030100fb") == 1 and "the micro says 2026-11-17 12:30:15 UTC" in r["kmsg"], "a micro that answers the clock read with the clock frame alone (no ACK): read at the first try, not repeated")
r = run("ready-no-ack", 14, ack_ready=False)
hs = [h for _, h in r["frames"]]
ok(hs.count("fa0301000000fb") == 20 and "cmd READY (WD's DeviceReady) ack=0 tries=10 (try 1 of 2)" in r["kmsg"] and "(try 2 of 2)" in r["kmsg"] and " ready=not-acked " in r["status"] and not r["reboot"] and "FAILSAFE" not in r["kmsg"],
   "a micro that never ACKs DeviceReady: WD's 10 tries, once more 6 s later (60 s real), then never again; no reboot, ready=not-acked on record", hs.count("fa0301000000fb"))
ok("main=50 sata=47" in r["status"] and dedup(fans(r))[:2] == ["FAN_HIGH", "FAN_MEDIUM"], "... and the fan curve runs on as if nothing had happened", dedup(fans(r)))
wire_ok(r, "ready-no-ack")
EV = [("fa2100000000fb", "event PWR: power button (frame 21 00 00 00 00): logged only, no action"), ("fa5700000000fb", "event PWR2: power button, second event"),
      ("fa2200000000fb", "event RST: reset button (frame 22 00 00 00 00)"), ("fa5200000000fb", "event RST2: reset button, second event"),
      ("fa2600000100fb", "event UsbBackupPush: USB copy button (frame 26 00 00 01 00)"), ("fa2500000000fb", "event FUNCPush: front scroll button down"), ("fa2c00000000fb", "event FUNCRelease: front scroll button up"),
      ("fa4000000100fb", "event PWR_LOST: the micro's power-loss flag"), ("fa4100000100fb", "event APR_STAT:"), ("fa4200000100fb", "event WOL_STAT:"), ("fa2000000000fb", "event RTCAlarm:")]
base = run("events-base", 9)
r = run("events", 9, inject=[(3.0 + 0.2 * i, h) for i, (h, _) in enumerate(EV)])
ok(all(t in r["kmsg"] for _, t in EV) and " events=%d " % len(EV) in r["status"], "eleven events from the micro (power, reset, USB copy, scroll, power-loss, APR, WOL, alarm): each one NAMED in the log", [t for _, t in EV if t not in r["kmsg"]])
ok(not r["reboot"] and "FAILSAFE" not in r["kmsg"] and r["rc"] == 0 and sorted(set(h for _, h in r["frames"])) == sorted(set(h for _, h in base["frames"])) and abs(len(r["frames"]) - len(base["frames"])) <= 4,
   "... and NOTHING is done about them: no reboot, no shutdown, the same frames on the wire as a run without events (%d vs %d)" % (len(r["frames"]), len(base["frames"])))
wire_ok(r, "events")
r = run("events-flood", 9, inject=[(3.0 + 0.02 * i, "fa2100000000fb") for i in range(120)])
ok(r["kmsg"].count("event PWR: power button") == 40 and " events=120 " in r["status"] and not r["reboot"] and "main=50 sata=47" in r["status"], "a power button that sends 120 events: logged 40 times, counted 120, no action, the readings go on", r["kmsg"].count("event PWR:"))

print("== the supervisor")
def segv(t, root, p, m):
    if 3 < t and not os.path.exists(os.path.join(root, "kill1")):
        open(os.path.join(root, "kill1"), "w").close()
        kids = subprocess.run(["pgrep", "-P", str(p.pid)], stdout=subprocess.PIPE).stdout.decode().split()
        for k in kids: os.kill(int(k), signal.SIGSEGV)
r = run("crash-once", 10, script=segv)
ok("supervisor: the worker ended unexpectedly (signal 11), crash 1 of 6" in r["kmsg"] and r["kmsg"].count(" start pid=") == 2 and not r["reboot"], "a worker killed with SIGSEGV is started again (crash 1 of 6), no reboot", r["kmsg"][-300:])
ok(fans(r).count("FAN_HIGH") >= 2 and "cmd FAN=3(HIGH) ack=1 tries=1 why=start: first action" in r["kmsg"].split("crash 1 of 6")[-1], "the new worker's first action is FAN HIGH again")
def killloop(t, root, p, m):
    """kill each new worker once it has started (SIGKILL: a SIGSEGV would hold the dying process for a second while the host writes a core file)"""
    n = len([x for x in os.listdir(root) if x.startswith("kill")])
    if t < 1.0 or n >= 7: return
    for k in subprocess.run(["pgrep", "-P", str(p.pid)], stdout=subprocess.PIPE).stdout.decode().split():
        try: st = open("/proc/%s/stat" % k).read().rsplit(")", 1)[1].split()[0]
        except OSError: continue
        if st == "Z" or os.path.exists(os.path.join(root, "done-%s" % k)): continue
        if open(os.path.join(root, "kmsg")).read().count(" start pid=") <= n: continue        # the new worker has not logged its start yet
        try: os.kill(int(k), signal.SIGKILL)
        except ProcessLookupError: continue
        open(os.path.join(root, "done-%s" % k), "w").close(); open(os.path.join(root, "kill%d" % n), "w").close(); return
r = run("crash-loop", 25, script=killloop)
ok(r["self_ended"] and "FAILSAFE reason=worker-crash-loop (6 crashes)" in r["kmsg"] and "REBOOT worker crash loop" in r["reboot"], "six crashes: FAILSAFE worker-crash-loop, reboot", r["kmsg"][-300:])
def stopit(t, root, p, m):
    if 2 < t and not os.path.exists(os.path.join(root, "s1")):
        open(os.path.join(root, "s1"), "w").close()
        for k in subprocess.run(["pgrep", "-P", str(p.pid)], stdout=subprocess.PIPE).stdout.decode().split(): os.kill(int(k), signal.SIGSTOP)
r = run("hang", 30, script=stopit)
ok("supervisor: the worker gave no sign of life for 18 s: killing it" in r["kmsg"] and r["kmsg"].count(" start pid=") == 2, "a worker that hangs (SIGSTOP) is killed after 18 s without a heartbeat (180 s real) and started again", r["kmsg"][-300:])

root2 = os.path.join(W, "second"); os.makedirs(root2); open(os.path.join(root2, "ex4fan.pid"), "w").write("%d\n" % os.getpid())
p2 = subprocess.run(BIN + ["daemon", "--test-root", root2, "--foreground", "--fast"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
ok(p2.returncode == 0 and b"already running" in p2.stdout and not os.path.exists(os.path.join(root2, "kmsg")), "a second start while one runs does nothing (the pid file names a live process)")
for bad in (["daemon", "--fast"], ["ready"], ["clock"], ["led", "on"], ["daemon", "--tty", "ttyS0"], ["daemon", "--test-hw", "--tty", "/dev/ttyS0"], ["daemon", "--tach-line", "3"], ["daemon", "--bogus"], ["send", "fa0200000000fb"]):
    pb = subprocess.run(BIN + bad, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
    ok(pb.returncode == 64, "refused: ex4fan %s (exit 64)" % " ".join(bad), pb.stdout[:200])

if A.slow:
    print("== real clock")
    r = run("silent-real", 50, silent=True, fast=False)
    ts = [tt for tt, h in r["frames"][:10]]; gaps = [ts[i + 1] - ts[i] for i in range(9)]
    ok(len(ts) == 10 and all(0.28 <= g <= 0.40 for g in gaps), "real clock: FAN HIGH is repeated every 300 ms, 10 times (WD's cadence): gaps %s" % " ".join("%.2f" % g for g in gaps))
    f = [float(m.group(1)) for m in re.finditer(r"\[\s*([0-9.]+)\] FAILSAFE reason=micro-never-answered", r["log"])]; s0 = [float(m.group(1)) for m in re.finditer(r"\[\s*([0-9.]+)\] start pid", r["log"])]
    ok(f and s0 and 30 <= f[0] - s0[0] <= 37 and "REBOOT" in r["reboot"], "real clock: micro-never-answered fires %.1f s after the start (limit 30 s)" % (f[0] - s0[0] if f and s0 else -1))
    wire_ok(r, "silent-real")

print("fan-test: %d passed, %d failed   (%s, workdir %s)" % (PASS, FAIL, " ".join(BIN), W))
sys.exit(1 if FAIL else 0)
