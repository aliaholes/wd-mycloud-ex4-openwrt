#!/usr/bin/python3 -I
# SPDX-License-Identifier: GPL-2.0-or-later
"""panel-test.py — ex4fan v7's FRONT PANEL against a FAKE front-panel micro on a pty. Off the box; nothing here touches the EX4.

  python3 -I panel-test.py --bin <ex4fan> [--qemu] --lcd-capture tests/captures/stock-lcd-frames-2026-11-17.json
                           --power-capture tests/captures/stock-power-frames-2026-11-17.json --src userland/ex4fan.c --work DIR
                           [--wakeups SECONDS]

What it checks (fan-test.py keeps checking the fan; this file checks what v7 added):
  static   every LCD / panel frame the daemon can build == the bytes WD's own up_send_ctl put on the wire under qemu-arm
           (receipts above) for the same field and value; every captured WD frame that is NOT one of our kinds is REFUSED by
           the daemon's own frame_check(); the builders refuse what the rules forbid; the source has one writer and the
           poweroff gate; the binary holds no whole WD frame but the fan table.
  runs     panel OFF by default (the wire carries only the fan table); --panel: every frame on the wire checked against an
           independent Python model of WD's rules, every expected field sent, changes (md degraded + rebuild %, host name,
           an alert, a SMART count) re-sent, no spam in steady state, a micro that never ACKs LCD frames (no fail-safe), the
           buttons (logged only), the ctl requests (send / notice / poweroff refused without --allow-poweroff, sent with it,
           a foreign request file ignored), a drive in standby, the JSON for the web UI, the edge-timestamp arithmetic.
  --wakeups N   the daemon at idle under the real clock for N s, every syscall counted with qemu-arm -strace (or strace -f
           natively): wakeups per second = returns from poll / clock_nanosleep / nanosleep.
Born Nov 17 2026 (v7 panel lane)."""
import argparse, json, os, pty, re, select, signal, subprocess, sys, termios, threading, time, shutil

ap = argparse.ArgumentParser()
ap.add_argument("--bin", required=True); ap.add_argument("--qemu", action="store_true")
ap.add_argument("--lcd-capture", required=True); ap.add_argument("--power-capture", required=True)
ap.add_argument("--src", required=True); ap.add_argument("--work", required=True)
ap.add_argument("--wakeups", type=float, default=0)
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
    else: FAIL += 1; print("FAIL  " + what + ("   [" + str(detail)[:700] + "]" if detail != "" else ""))
    return cond
def ex(*a): return subprocess.run(BIN + list(a), stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout.decode().strip()

TX = {"fa0200010000fb", "fa0200020000fb", "fa0200030000fb", "fa0200040000fb", "fa0308010000fb", "fa0308020000fb", "fa0301000000fb", "fa0100030100fb"}
ACK = bytes.fromhex("fa3000000000fb")

# ---------- an independent model of WD's rules (FRONT-PANEL.md section 2), written from the table, not from ex4fan.c ----------
def m_text(pre, s): b = s.encode("ascii"); return "fa" + pre + "%02x" % len(b) + b.hex() + "fb"
def m_ip(port, a): o = [int(x) for x in a.split(".")][::-1]; return "fa0402%02x08" % port + "".join("%02x%02x" % (x & 15, x >> 4) for x in o) + "fb"
def m_vol(v, s, p, ok_): t = ("%d%d%d%d" % (v, s, p, ok_)).encode(); return "fa040401" + "%02x" % len(t) + t.hex() + "fb"
def m_used(v, p): return "fa040403" + "04%02x%02xfb" % (v, p)
def m_temp(a, b): return "fa04090000%02x00%02x00fb" % (a, b)
M = {"name": lambda s: m_text("040100", s), "fw": lambda s: m_text("040800", s), "health": lambda s: m_text("048400", s),
     "free": lambda s: m_text("048500", s), "fan": lambda s: m_text("048300", s)}
KIND_RE = [("name", r"^fa040100([0-9a-f]{2})((?:[2-7][0-9a-f])+)fb$"), ("fw", r"^fa040800([0-9a-f]{2})((?:[2-7][0-9a-f])+)fb$"),
           ("health", r"^fa048400([0-9a-f]{2})((?:[2-7][0-9a-f])+)fb$"), ("free", r"^fa048500([0-9a-f]{2})((?:[2-7][0-9a-f])+)fb$"),
           ("fan", r"^fa048300([0-9a-f]{2})((?:[2-7][0-9a-f])+)fb$"), ("ip1", r"^fa04020108(0[0-9a-f]){8}fb$"), ("ip2", r"^fa04020208(0[0-9a-f]){8}fb$"),
           ("ip1off", r"^fa0402040000fb$"), ("ip2off", r"^fa0402080000fb$"), ("vol", r"^fa040401(0[4-6])((?:3[0-9])+)fb$"),
           ("used", r"^fa04040304(0[1-9])([0-9a-f]{2})fb$"), ("volclean", r"^fa0404040000fb$"), ("temp", r"^fa04090000([0-9a-f]{2})00([0-9a-f]{2})00fb$"),
           ("lcd", r"^fa04820[01]0000fb$"), ("standby", r"^fa0406(01|08|00)0000fb$"), ("usb", r"^fa040a0[01]0000fb$"),
           ("shutmsg", r"^fa0303040100fb$"), ("rstmsg", r"^fa0303050100fb$"), ("poweroff", r"^fa0303010101fb$")]
def m_kind(h):
    """the model's verdict on one frame: its kind, or None (the model's own whitelist)"""
    for k, rx in KIND_RE:
        m = re.match(rx, h)
        if not m: continue
        if k in ("name", "fw", "health", "free", "fan"):
            L = int(m.group(1), 16); t = bytes.fromhex(m.group(2))
            if L != len(t) or not 1 <= L <= 16 or any(c < 0x20 or c > 0x7e for c in t): return None
        if k == "vol":
            t = bytes.fromhex(m.group(2)).decode(); L = int(m.group(1), 16)
            if L != len(t) or t[0] == "0" or t[1] not in "01235" or t[-1] not in "01" or int(t[2:-1]) > 100 or (len(t[2:-1]) > 1 and t[2] == "0"): return None
        if k == "used" and int(m.group(2), 16) > 100: return None
        if k == "temp" and (int(m.group(1), 16) > 150 or int(m.group(2), 16) > 150): return None
        return k
    return None
def text_of(h): return bytes.fromhex(h[10:-2]).decode()

# ---------------- 0. static ----------------
print("== static: every frame the daemon can build == WD's own bytes")
lcd = json.load(open(A.lcd_capture))["runs"]; pw = json.load(open(A.power_capture))["runs"]
runs = [(r["cmd"].split(None, 1)[1] if " " in r["cmd"] else "", r["frames_box_to_mcu"]) for r in lcd + pw]
def ours(cmd):
    """WD's up_send_ctl command line -> our panel-build arguments, or None when it is not one of our kinds"""
    import shlex
    try: a = shlex.split(cmd)
    except ValueError: return None
    if not a: return None
    c, r = a[0], a[1:]
    simple = {"SysName": "name", "FirmwareVer": "fw", "HDHealthy": "health", "CapacityFree": "free", "FanSpeed": "fan"}
    if c in simple and len(r) == 1: return [simple[c], r[0]]
    if c == "SysIP1" and len(r) == 1: return ["ip1", r[0]]
    if c == "SysIP2" and len(r) == 1: return ["ip2", r[0]]
    if c in ("SysIP1Dis", "SysIP2Dis", "VolClean", "DeviceShutdownMsg", "DeviceRstMsg") and not r:
        return [{"SysIP1Dis": "ip1off", "SysIP2Dis": "ip2off", "VolClean": "volclean", "DeviceShutdownMsg": "shutmsg", "DeviceRstMsg": "rstmsg"}[c]]
    if c == "DeviceShutdown" and r == ["1"]: return ["poweroff"]
    if c == "VolStatus" and len(r) == 4: return ["vol"] + r
    if c == "VolUsedPct" and len(r) == 2: return ["used"] + r
    if c == "temperature" and len(r) == 2: return ["temp"] + r
    if c == "LCDSleepMode" and len(r) == 1: return ["lcd", r[0]]
    if c == "Standby" and len(r) == 1: return ["standby", r[0]]
    if c == "usbExist" and len(r) == 1: return ["usb", r[0]]
    return None
same = refused_ok = cut16 = 0; mism = []; notref = []; accepted_kinds = set()
for cmd, frames in runs:
    if len(frames) != 1: continue
    wd = frames[0]; a = ours(cmd)
    mine = ex("panel-build", *a) if a else None
    chk = ex("panel-check", wd)
    if a and mine != "REFUSED" and a[0] in M and len(a[1].encode()) > 16:      # WD has no length cap: our cap cuts to 16, frame_check refuses WD's
        if mine == M[a[0]](a[1][:16]) and chk == "REFUSED": cut16 += 1
        else: mism.append((cmd, wd, mine, chk))
    elif a and mine != "REFUSED":
        if mine == wd and chk == a[0]: same += 1; accepted_kinds.add(a[0])
        else: mism.append((cmd, wd, mine, chk))
    else:
        if chk == "REFUSED": refused_ok += 1
        else: notref.append((cmd, wd, chk, mine))
ok(not mism and same >= 30, "%d captured WD frames: panel-build gives the same bytes and frame_check names the same kind" % same, mism[:4])
ok(accepted_kinds == {k for k, _ in KIND_RE}, "every one of the 19 kinds is covered by a WD capture (%d)" % len(accepted_kinds), sorted({k for k, _ in KIND_RE} - accepted_kinds))
ok(cut16 >= 3, "%d captured WD text frames longer than 16 bytes: frame_check refuses WD's, our builder sends the first 16 bytes" % cut16)
ok(not notref and refused_ok >= 60, "%d captured WD frames outside our kinds or rules (ErrStatus, HDDExist, MFGLCD, MFGMode, OledTest, PwrLedRed, MCUReset, DeviceShutdown 0/5/20/.., DeviceShutdownByUPS, GetOnCause, VolStatus 4/6, long text, temperature 255 ...) are REFUSED by frame_check" % refused_ok, notref[:6])
for args, why in ((["name", "x" * 0], "empty text"), (["vol", "1", "4", "0", "1"], "VolStatus 4 (Lock)"), (["vol", "1", "6", "100", "1"], "VolStatus 6 (Formatting)"),
                  (["vol", "0", "0", "0", "1"], "volume 0"), (["vol", "1", "1", "101", "1"], "101 %"), (["temp", "151", "40"], "151 C"), (["lcd", "2"], "LCDSleepMode 2"),
                  (["standby", "1"], "Standby 1 (never captured)"), (["used", "1", "101"], "101 % used"), (["ip1", "300.1.1.1"], "a bad address"), (["errstatus", "1"], "ErrStatus (no such kind)"),
                  (["mfglcd", "1", "X"], "MFGLCD (no such kind)"), (["mcureset", "10"], "MCUReset (no such kind)"), (["name", "Ü"], "non-ASCII only")):
    ok(ex("panel-build", *args).startswith("REFUSED"), "panel-build refuses %s" % why)
ok(ex("panel-build", "name", "ABCDEFGHIJKLMNOPQRSTUVWXYZ") == m_text("040100", "ABCDEFGHIJKLMNOP"), "text is cut to 16 bytes (WD's up_send_ctl has no cap; MFGLCD's is 16)")
ok(ex("panel-check", "fa040100114142434445464748494a4b4c4d4e4f505152fb") == "REFUSED", "frame_check refuses a 17-byte text frame")
ok(ex("panel-check", "fa0401000441fbfb") == "REFUSED" and ex("panel-check", "fa04010002410afb") == "REFUSED", "frame_check refuses a wrong LEN and a control byte in text")

print("== static: source and binary")
src = open(A.src).read(); code = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
pw_body = code[code.index("static int panel_write"):code.index("static int frame_cmd")]
ok(pw_body.index("frame_check(b, n)") < pw_body.index("port_write(b, (size_t)n)") and "if (k < 0)" in pw_body and "PK_POWEROFF && !(opt_poweroff && poweroff_armed)" in pw_body,
   "source: panel_write runs frame_check (refuse on -1) and the poweroff gate BEFORE the one port_write")
ok(len(re.findall(r"\bpanel_write\s*\(", code)) == 2 and len(re.findall(r"\bport_write\s*\(", code)) == 3 and len(re.findall(r"\bwrite\s*\(\s*tty\b", code)) == 1,
   "source: one write(tty) (in port_write), port_write used by mcu_write + panel_write only, panel_write used by frame_cmd only")
arm = [m.start() for m in re.finditer(r"poweroff_armed\s*=\s*1", code)]
cp = code[code.index("static void ctl_poweroff"):code.index("static void ctl_do")]
ok(len(arm) == 1 and "poweroff_armed = 1" in cp and cp.index("if (!opt_poweroff)") < cp.index("poweroff_armed = 1") and "return;" in cp[:cp.index("poweroff_armed = 1")],
   "source: poweroff_armed is set in ONE place, inside ctl_poweroff, after the --allow-poweroff check returns early")
ok(code.count("opt_poweroff = 1") == 1 and '"--allow-poweroff"' in code, "source: --allow-poweroff is the only way to set it")
ok(not re.search(r"\bmdadm\b|\bmount\s*\(|BLKROSET|\"/dev/md", code) and not re.search(r"open\([^)]*/dev/sd", code),
   "source: no mdadm, no mount(), no BLKROSET, no /dev/md* opened, no /dev/sd* opened by name (md state = /proc/mdstat, space = statvfs)")
sm = code[code.index("static int smart_temp"):code.index("static int drv_find_old")]
ok("O_RDONLY" in sm and "O_WRONLY" not in sm and "O_RDWR" not in sm and "SG_DXFER_TO" not in sm and sm.count("SG_IO") == 2 and "SG_DXFER_NONE" in sm and "0xe5" in sm,
   "source: the drive is opened read-only; its two SG_IO are CHECK POWER MODE (non-data) and SMART READ DATA (from the device)")
binb = open(A.bin, "rb").read()
wdframes = {f for _, fr in runs for f in fr}
inbin = sorted(f for f in wdframes if f not in TX and bytes.fromhex(f) in binb)
ok(not inbin, "binary: none of the %d other WD frames captured is in it as a whole (the panel's are built at run time)" % len(wdframes - TX), inbin[:5])
ok(ex("tachcalc", *[str(int(i * 1e9 / 68)) for i in range(68)]) in ("2039", "2040", "2041"), "tachcalc: 68 rising edges in a second, evenly spaced = 2040 rpm (two pulses a turn)", ex("tachcalc", *[str(int(i * 1e9 / 68)) for i in range(68)]))
ok(ex("tachcalc", "0", "1000000") == "0" and ex("tachcalc") == "0", "tachcalc: fewer than 3 edges = 0 rpm (WD: one change is noise)")
ok(ex("tachcalc", *[str(int(5e8 + i * 1e9 / 51)) for i in range(40)]) in ("1529", "1530", "1531"), "tachcalc: a window that starts mid-way (40 edges at 51/s) = 1530 rpm: period from timestamps, no window quantisation")

# ---------------- 1. runs against a fake micro ----------------
class Mcu(threading.Thread):
    """the fake micro: frames of any length (FA .. FB), ACKs, thermistor data, a fake fan for the tach file"""
    def __init__(self, root, ack_lcd=True, inject=(), rpm={1: 1035, 2: 1800, 3: 2600, 4: 3400}):
        super().__init__(daemon=True)
        self.master, self.slave = pty.openpty(); self.root = root
        os.symlink(os.ttyname(self.slave), os.path.join(root, "tty"))
        self.ack_lcd, self.inject, self.rpm = ack_lcd, sorted(inject), rpm
        self.t0 = time.time(); self.frames = []; self.buf = b""; self.stop = False; self.junk = b""
    def settach(self, lv):
        with open(os.path.join(self.root, "tach.new"), "w") as f: f.write("%d\n" % self.rpm[lv])
        os.rename(os.path.join(self.root, "tach.new"), os.path.join(self.root, "tach"))
    def run(self):
        while not self.stop:
            r, _, _ = select.select([self.master], [], [], 0.05)
            while self.inject and time.time() - self.t0 >= self.inject[0][0]: os.write(self.master, bytes.fromhex(self.inject.pop(0)[1]))
            if not r: continue
            try: b = os.read(self.master, 256)
            except OSError: break
            self.buf += b
            while True:
                i = self.buf.find(b"\xfa")
                if i < 0: self.junk += self.buf; self.buf = b""; break
                if i: self.junk += self.buf[:i]; self.buf = self.buf[i:]
                j = self.buf.find(b"\xfb")
                if j < 0: break
                f = self.buf[:j + 1]; self.buf = self.buf[j + 1:]; h = f.hex()
                self.frames.append((round(time.time() - self.t0, 3), h))
                if h.startswith("fa0200") and len(f) == 7: self.settach(f[3]); os.write(self.master, ACK)
                elif h.startswith("fa0308") and len(f) == 7: os.write(self.master, ACK + bytes([0xfa, 0x03, 0x08, f[3], 0, {1: 80, 2: 75}[f[3]], 0xfb]))
                elif h in ("fa0301000000fb",): os.write(self.master, ACK)
                elif h == "fa0100030100fb": os.write(self.master, ACK + bytes.fromhex("fa0100030715301202171126fb"))
                elif h.startswith("fa04") or h.startswith("fa0303"):
                    if self.ack_lcd: os.write(self.master, ACK)

BASE = {"drives": "sda 40 5=0 9=12000 10=0 12=51 187=0 197=0 198=0 199=0\nsdb 41 5=0 9=12001 197=0\nsdc 41 5=0 197=0\nsdd 43 5=0 197=0\n",
        "soc": "57000\n", "hostname": "Kurt-EX4\n", "ifaddrs": "lo 127.0.0.1\nbr-lan 192.0.2.50\n", "release": "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='25.12.0'\n",
        "mdstat": "Personalities : [raid1] [raid6] [raid5] [raid4]\nmd1 : active (read-only) raid5 sda2[0] sdb2[1] sdc2[2] sdd2[3]\n      11701135296 blocks super 1.0 level 5, 64k chunk, algorithm 2 [4/4] [UUUU]\n\nmd0 : active raid1 sda1[0] sdb1[1]\n      2097088 blocks [4/2] [UU__]\n\nunused devices: <none>\n",
        "mounts": "/dev/root / squashfs ro 0 0\n/dev/md1 /mnt/md1 ext4 ro,noload 0 0\n", "statvfs": "11981842964480 11980017381376\n"}
def wr(root, name, text):
    p = os.path.join(root, name); open(p + ".t", "w").write(text); os.rename(p + ".t", p)
def run(name, secs, args=(), files=None, script=None, ack_lcd=True, inject=()):
    root = os.path.join(W, name); os.makedirs(root)
    for k, v in dict(BASE, **(files or {})).items():
        if v is not None: wr(root, k, v)
    m = Mcu(root, ack_lcd=ack_lcd, inject=inject); m.settach(3); m.start()
    p = subprocess.Popen(BIN + ["daemon", "--test-root", root, "--foreground", "--fast"] + list(args), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    t0 = time.time(); done = False; fired = set()
    while time.time() - t0 < secs:
        if script: script(time.time() - t0, root, fired)
        if p.poll() is not None: done = True; break
        time.sleep(0.05)
    if not done:
        p.send_signal(signal.SIGTERM)
        try: p.wait(timeout=10)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
    time.sleep(0.2); m.stop = True
    rd = lambda f: open(os.path.join(root, f)).read() if os.path.exists(os.path.join(root, f)) else ""
    js = None
    try: js = json.loads(rd("ex4fan.json"))
    except Exception as e: js = {"_error": str(e), "_raw": rd("ex4fan.json")[:300]}
    out = p.stdout.read().decode("latin1")
    if re.search(r"runtime error|AddressSanitizer|LeakSanitizer", out): SAN.append((name, out[:400]))
    return {"root": root, "rc": p.returncode, "self_ended": done, "frames": m.frames, "junk": m.junk, "log": rd("ex4fan.log"), "kmsg": rd("kmsg"),
            "status": rd("ex4fan.status"), "json": js, "reboot": rd("reboot"), "out": out}
SAN = []
def lcdf(r): return [(t, h) for t, h in r["frames"] if h not in TX]
def wall(r, what, allow=None):
    bad = [h for _, h in r["frames"] if h not in TX and (m_kind(h) is None or (allow is not None and m_kind(h) not in allow))]
    ok(not bad and not r["junk"], "%s: every frame on the wire is a fan-table frame or passes the model of WD's rules (%d frames, %d panel)" % (what, len(r["frames"]), len(lcdf(r))), (bad[:5], r["junk"][:20]))
TIERA = {"name", "fw", "health", "free", "fan", "ip1", "ip2", "ip1off", "ip2off", "vol", "used", "volclean", "temp", "lcd", "standby", "usb"}
gib = lambda a: "%.3f TB" % (a / 1099511627776.0)

print("== panel OFF (the default: what the trial runs today)")
r = run("off", 9)
ok(r["frames"] and not lcdf(r) and r["rc"] == 0, "no --panel, no config: not one panel frame on the wire, only the fan table (%d frames)" % len(r["frames"]), lcdf(r)[:3])
j = r["json"]
ok("_error" not in j and j.get("v") == 1, "/tmp/ex4fan.json is written and parses", j.get("_error", ""))
ok(j.get("panel", {}).get("mode") == "off" and j["panel"]["poweroff_allowed"] is False and j["panel"]["lcd_frames"] == 0, "JSON: panel off, poweroff not allowed, 0 LCD frames")
ok([d["dev"] for d in j.get("drives", [])] == ["sda", "sdb", "sdc", "sdd"] and all(sorted(d["smart"], key=int) == ["5", "9", "10", "12", "187", "194", "197", "198", "199"] for d in j["drives"]),
   "JSON: four drives, each with the nine SMART attributes (5 9 10 12 187 194 197 198 199: REVIEW nit 1's eight + 194)")
ok(j["drives"][0]["smart"]["9"] == 12000 and j["drives"][0]["smart"]["12"] == 51 and j["drives"][0]["smart"]["194"] == 40 and j["drives"][2]["smart"]["9"] == -1 and j["drives"][0]["verdict"] == "good",
   "JSON: attribute values as read (-1 = not reported), 194 = the temperature, verdict good")
ok(j.get("md", {}).get("state") == "clean" and j["md"]["members"] == "UUUU" and j["md"]["readonly"] is True and j["md"]["level"] == 5 and j["md"]["disks"] == 4,
   "JSON: md1 clean RAID5 [UUUU], read-only, from /proc/mdstat (md0 ignored)", j.get("md"))
ok(j.get("space", {}).get("mounted") is True and j["space"]["mount"] == "/mnt/md1" and j["space"]["used_pct"] == 0 and j["space"]["avail"] == 11980017381376, "JSON: space from statvfs of md1's mount", j.get("space"))
ok(j["fan"]["rpm"] > 0 and j["temps"]["main"] == 50 and j["micro"]["answers"] is True and j["panel"]["host"] == "Kurt-EX4" and j["panel"]["ip1"] == "192.0.2.50" and j["panel"]["fw"] == "OpenWrt 25.12.0",
   "JSON: fan rpm, board 50 C, the micro answers, host / address / firmware text read")

print("== panel ON (--panel): WD's own fields from our readings")
r = run("tiera", 9, ["--panel"])
wall(r, "tierA", TIERA)
hs = [h for _, h in lcdf(r)]
want = [M["name"]("Kurt-EX4"), m_ip(1, "192.0.2.50"), "fa0402080000fb", M["fw"]("OpenWrt 25.12.0"), M["health"]("Good"), M["free"](gib(11980017381376)), m_used(1, 0), m_vol(1, 0, 0, 1),
        m_temp(43, 50), "fa040a000000fb"]
ok(all(w in hs for w in want), "every expected field went out, byte-exact to the model: name, IP 1, IP 2 none, firmware, Good, %s free, 0 %% used, volume normal, 43/50 C, no USB" % gib(11980017381376), [w for w in want if w not in hs])
ok(any(m_kind(h) == "fan" and text_of(h).endswith("rpm") for h in hs), "the fan rpm text went out", [h for h in hs if m_kind(h) == "fan"])
first_ack = min(t for t, h in r["frames"] if h == "fa0200030000fb")
tl = [t for t, _ in lcdf(r)]
ok(tl and min(tl) > first_ack and all(b - a >= 0.025 for a, b in zip(tl, tl[1:])), "LCD frames only after the first fan command, and never two closer than the 300 ms gap (30 ms on the fast clock)", tl[:8])
ok(sum(1 for h in hs if m_kind(h) == "name") == 1 and sum(1 for h in hs if m_kind(h) == "fw") == 1, "steady state: the name and firmware went out once (no refresh spam)")
ok(not [h for h in hs if m_kind(h) in ("shutmsg", "rstmsg", "poweroff")], "no shutdown / reboot / poweroff frame without a request")
ok(r["json"]["panel"]["mode"] == "tierA" and r["json"]["panel"]["sent"].get("name") == "Kurt-EX4" and r["json"]["panel"]["lcd_unacked"] == 0 and r["rc"] == 0 and not r["reboot"],
   "JSON: panel tierA, what the glass was given, all ACKed; no fail-safe", r["json"].get("panel"))
ok("lcd name 'Kurt-EX4' ack=1 tries=1 frame " + M["name"]("Kurt-EX4") in r["log"], "the log names each LCD frame with its bytes")

print("== changes are re-sent")
def chg(t, root, f):
    if t > 3 and "md" not in f:
        f.add("md"); wr(root, "mdstat", BASE["mdstat"].replace("[4/4] [UUUU]", "[4/3] [UUU_]\n      [=======>.............]  recovery = 37.2% (1452/3900) finish=190.0min speed=120000K/sec").replace("sdd2[3]", "sdd2[3](F)"))
    if t > 5 and "host" not in f: f.add("host"); wr(root, "hostname", "nas-two\n")
    if t > 6 and "md2" not in f: f.add("md2"); wr(root, "mdstat", BASE["mdstat"].replace("[4/4] [UUUU]", "[4/3] [UUU_]\n      [=======>.............]  recovery = 37.2% (1452/3900) finish=190.0min speed=120000K/sec"))
    if t > 7 and "alert" not in f: f.add("alert"); os.makedirs(os.path.join(root, "run/ex4panel/alerts.d"), exist_ok=True); wr(root, "run/ex4panel/alerts.d/temp-sdd", "Disk 4 is hot\nmore text\n")
    if t > 9 and "smart" not in f: f.add("smart"); wr(root, "drives", BASE["drives"].replace("sdd 43 5=0 197=0", "sdd 43 5=0 197=8"))
    if t > 11 and "ip" not in f: f.add("ip"); wr(root, "ifaddrs", "br-lan 192.0.2.50\neth1 10.0.0.2\n")
r = run("changes", 14, ["--panel"], script=chg)
wall(r, "changes", TIERA)
hs = [h for _, h in lcdf(r)]
for w, what in ((m_vol(1, 1, 37, 1), "md1 rebuilding 37 % -> VolStatus 1 1 37 1"), (M["health"]("Failed sdd2"), "a member marked (F) -> 'Failed sdd2'"),
                (M["name"]("nas-two"), "host name changed -> SysName nas-two"), (M["health"]("Disk 4 is hot"), "an alert file -> its first line on the health field"),
                (M["health"]("Watch sdd"), "sdd's pending count 8 -> 'Watch sdd' (outranks the alert)"), (m_ip(2, "10.0.0.2"), "eth1 got an address -> SysIP2 10.0.0.2")):
    ok(w in hs, what, w)
ok(hs.index(M["health"]("Watch sdd")) > hs.index(M["health"]("Disk 4 is hot")) > hs.index(M["health"]("Good")), "the health field's order follows the inputs: Good, then the alert, then Watch sdd")
j = r["json"]
ok(j["md"]["state"] == "rebuilding" and j["md"]["pct"] == 37 and j["md"]["members"] == "UUU_" and j["alerts"] == [{"id": "temp-sdd", "text": "Disk 4 is hot"}] and j["drives"][3]["verdict"] == "watch",
   "JSON: rebuilding 37 %, UUU_, the alert, sdd 'watch'", (j["md"], j["alerts"]))

print("== a micro that never ACKs an LCD frame")
r = run("noack", 9, ["--panel"], ack_lcd=False)
nl = [h for _, h in lcdf(r)]
ok(r["rc"] == 0 and not r["reboot"] and "FAILSAFE" not in r["kmsg"] and "cmd FAN=3(HIGH) ack=1" in r["kmsg"], "no fail-safe, no reboot; fan commands still ACKed")
ok(nl and nl.count(nl[0]) == 3 and r["json"]["panel"]["lcd_unacked"] >= 5 and r["json"]["panel"]["lcd_acked"] == 0, "each LCD frame tried 3 times then dropped and counted (%d unACKed)" % r["json"]["panel"]["lcd_unacked"], (nl[:4], r["json"]["panel"]))
ok("not ACKed, dropped until the next refresh (never a fail-safe)" in r["log"], "the log says so")

print("== the buttons: logged only")
btn = [(3.0, "fa2100000000fb"), (3.3, "fa5700000000fb"), (3.6, "fa2200000000fb"), (3.9, "fa5200000000fb"), (4.2, "fa2600000000fb"), (4.5, "fa2500000000fb")]
r = run("buttons", 8, ["--panel"], inject=btn)
ok(all("event %s:" % n in r["log"] and "logged only, no action" in r["log"] for n in ("PWR", "PWR2", "RST", "RST2", "UsbBackupPush", "FUNCPush")), "PWR PWR2 RST RST2 UsbBackupPush FUNCPush: each named in the log, logged only")
ok([e["name"] for e in r["json"]["events"]] == ["PWR", "PWR2", "RST", "RST2", "UsbBackupPush", "FUNCPush"] and r["json"]["events_total"] == 6, "JSON: the six events, in order", r["json"].get("events"))
ok(not [h for _, h in r["frames"] if h.startswith("fa0303")] and r["rc"] == 0 and not r["reboot"], "no shutdown / reboot frame, no reboot: a button does nothing in the trial")

print("== ctl requests")
def ctl(root, *words): return subprocess.run(BIN + ["ctl", "--test-root", root] + list(words), stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout.decode()
def req1(t, root, f):
    if t > 3 and "a" not in f: f.add("a"); ctl(root, "poweroff")
    if t > 4 and "b" not in f: f.add("b"); ctl(root, "send", "name")
    if t > 5 and "c" not in f: f.add("c"); ctl(root, "notice", "shutdown")
    if t > 6 and "d" not in f:
        f.add("d"); p = os.path.join(root, "run/ex4panel/ctl/evil"); open(p, "w").write("poweroff\n"); os.chmod(p, 0o666)
    if t > 7 and "e" not in f: f.add("e"); ctl(root, "send", "nonsense")
r = run("ctl-off", 9, [], script=req1)
fr = [h for _, h in lcdf(r)]
ok("ctl poweroff: REFUSED: this daemon was not started with --allow-poweroff" in r["log"] and "fa0303010101fb" not in fr, "ctl poweroff WITHOUT --allow-poweroff: refused in the log, the DeviceShutdown frame never on the wire")
ok(fr.count(M["name"]("Kurt-EX4")) == 1 and [m_kind(h) for h in fr].count("name") == 1, "ctl send name (panel off, the hand bench step): exactly one SysName frame", fr)
ok(fr.count("fa0303040100fb") == 1 and "ctl notice shutdown: DeviceShutdownMsg ack=1" in r["log"], "ctl notice shutdown: one DeviceShutdownMsg frame, ACKed")
ok("evil is not ours, is group/world-writable or too big: ignored and removed" in r["log"] and not os.path.exists(os.path.join(r["root"], "run/ex4panel/ctl/evil")), "a world-writable request file: ignored and removed")
ok("ctl send nonsense: no such field" in r["log"] and set(m_kind(h) for h in fr) == {"name", "shutmsg"}, "an unknown field: refused; nothing else went on the wire", set(m_kind(h) for h in fr))
ok(oct(os.stat(os.path.join(r["root"], "run/ex4panel/ctl")).st_mode & 0o777) == "0o700", "the ctl folder is 0700")
def req2(t, root, f):
    if t > 3 and "a" not in f: f.add("a"); ctl(root, "poweroff")
r = run("ctl-allow", 6, ["--allow-poweroff"], script=req2)
fr = [h for _, h in lcdf(r)]
wdpow = [x["frames_box_to_mcu"][0] for x in pw if x["cmd"] == "up_send_ctl DeviceShutdown 1"]
ok(fr == ["fa0303040100fb", "fa0303010101fb"] and wdpow and wdpow[0] == "fa0303010101fb", "ctl poweroff WITH --allow-poweroff (test only): DeviceShutdownMsg then DeviceShutdown 1, byte-equal to WD's capture %s" % (wdpow[:1]), fr)
ok("DeviceShutdown 1 (fa0303010101fb) ack=1" in r["log"] and r["json"]["panel"]["poweroff_allowed"] is True, "logged; JSON says the flag was given")

print("== v8: ctl send-test, THE ONE TEST FRAME (panel off)")
def req3(t, root, f):
    if t > 3 and "a" not in f: f.add("a"); ctl(root, "send-test")
    if t > 4.5 and "b" not in f: f.add("b"); ctl(root, "send-test")
r = run("sendtest", 7, [], script=req3)
fr = [h for _, h in lcdf(r)]
st = open(os.path.join(r["root"], "ex4fan.sendtest")).read() if os.path.exists(os.path.join(r["root"], "ex4fan.sendtest")) else ""
ok(fr == [M["name"]("Kurt-EX4")], "send-test with the panel OFF: exactly ONE frame on the wire, WD's SysName with the host name", fr)
ok(st.startswith("send-test: ONE LCD frame (WD's SysName, text 'Kurt-EX4'") and " ack=1 " in st and st.count("\n") == 1, "the result file: one line, ack=1", st)
ok("ctl send-test: REFUSED: the one test frame of this boot was already asked for" in r["log"], "a second send-test in the same boot: refused, nothing sent")
r = run("sendtest-noack", 7, [], script=req3, ack_lcd=False)
fr = [h for _, h in lcdf(r)]
st = open(os.path.join(r["root"], "ex4fan.sendtest")).read() if os.path.exists(os.path.join(r["root"], "ex4fan.sendtest")) else ""
ok(fr == [M["name"]("Kurt-EX4")] and " ack=0 (no ACK within 300 ms)" in st, "a micro that does not ACK it: still ONE frame (one try, no retries), ack=0 recorded", (fr, st))
ok("FAILSAFE" not in r["kmsg"] and not r["reboot"], "an unACKed test frame is never a fail-safe")

print("== a drive in standby")
def sleep_sdd(t, root, f):
    if t > 4 and "s" not in f: f.add("s"); wr(root, "drives", BASE["drives"].replace("sdd 43 5=0 197=0", "sdd 99 power=standby"))
r = run("standby", 8, [], script=sleep_sdd)
d = r["json"]["drives"][3]
ok(d["power"] == "standby" and d["temp"] == 43 and d["smart"]["197"] == 0 and "sdd:43" in r["status"] and "FAILSAFE" not in r["kmsg"], "sdd goes to standby: not read (99 C in the file never seen), keeps its last 43 C and attributes", d)
r = run("standby0", 9, [], files={"drives": BASE["drives"].replace("sdd 43 5=0 197=0", "sdd 43 power=standby")})
ok(r["json"]["drives"][3]["temp"] == -1 and "sdd:?" in r["status"] and "cmd FAN=3(HIGH)" in r["kmsg"] and "cmd FAN=2" not in r["kmsg"] and "cmd FAN=1" not in r["kmsg"],
   "a drive asleep from the start: temperature unknown -> the fan stays at HIGH past the first minute (never below)")

print("== the tachometer's edge arithmetic in a run")
edges = "\n".join(str(int(1e12 + i * 1e9 / 51)) for i in range(51)) + "\n"
r = run("edges", 5, [], files={"tach_edges": edges})
ok(r["json"]["fan"]["rpm"] in (1529, 1530, 1531) and r["json"]["fan"]["edges"] == 51 and "rpm=153" in r["status"], "51 rising-edge timestamps in a second -> 1530 rpm in the status and the JSON", r["json"]["fan"])

print("== config file turns the panel on (what the web UI writes)")
r = run("conf", 7, [], files={"ex4panel.conf": "config panel 'main'\n\toption mode 'tierA'\n\toption lcd_sleep_mode '1'\n\toption standby '3'\n\toption firmware 'Alia v7'\n"})
hs = [h for _, h in lcdf(r)]
ok(r["json"]["panel"]["mode"] == "tierA" and "fa0482010000fb" in hs and "fa0406080000fb" in hs and M["fw"]("Alia v7") in hs, "mode tierA from /etc/config/ex4panel; LCDSleepMode 1, Standby 3 (5 min), our firmware text", [m_kind(h) for h in hs])
wall(r, "conf", TIERA)

ok(not SAN, "no sanitizer report from any run (meaningful with an ASan/UBSan build)", SAN[:2])

# ---------------- 2. wakeups at idle (real clock) ----------------
if A.wakeups:
    print("== wakeups at idle, real clock, %d s measured after a 75 s warm-up" % A.wakeups)
    for mode in ("off", "panel"):
        root = os.path.join(W, "wake-" + mode); os.makedirs(root)
        for k, v in BASE.items(): wr(root, k, v)
        m = Mcu(root); m.settach(3); m.start()
        log = os.path.join(W, "strace-%s.txt" % mode)
        if A.qemu: cmd = ["qemu-arm", "-strace", BIN[1]]
        else: cmd = ["strace", "-f", "-o", log] + BIN
        args = cmd + ["daemon", "--test-root", root, "--foreground"] + (["--panel"] if mode == "panel" else [])
        lf = open(log, "wb") if A.qemu else subprocess.DEVNULL
        p = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=lf)
        def count():
            if A.qemu: lf.flush()
            t = open(log, "rb").read().decode("latin1")
            calls = re.findall(r"\b(?:poll|ppoll|clock_nanosleep|clock_nanosleep_time64|nanosleep)\([^\n]*", t)
            zero = [c for c in calls if re.search(r"tv_sec=0, tv_nsec=0\}|^poll\(0x[0-9a-f]+,\d+,0\)", c)]
            return len(calls) - len(zero), len(t.splitlines())     # a zero-timeout poll does not sleep: not a wakeup
        time.sleep(75); c0, l0 = count(); t0 = time.time()
        time.sleep(A.wakeups); c1, l1 = count(); dt = time.time() - t0
        p.send_signal(signal.SIGTERM)
        try: p.wait(timeout=15)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
        m.stop = True
        w = (c1 - c0) / dt
        print("MEASURE  %s: %d sleeping calls (poll/clock_nanosleep/nanosleep) in %.0f s = %.2f wakeups/s; %d syscalls = %.1f/s (both processes: worker + supervisor)" % (mode, c1 - c0, dt, w, l1 - l0, (l1 - l0) / dt))
        ok(w < 2.0, "%s: idle wakeups %.2f/s < 2/s (v5: 5/s from the 200 ms tick + a 0.5 s spin every 10 s)" % (mode, w))

print("panel-test: %d passed, %d failed   (%s, workdir %s)" % (PASS, FAIL, " ".join(BIN), W))
sys.exit(1 if FAIL else 0)
