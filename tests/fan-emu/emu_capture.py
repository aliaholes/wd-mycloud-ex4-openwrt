#!/usr/bin/python3 -I
# SPDX-License-Identifier: GPL-2.0-or-later
"""emu_capture.py — run WD's OWN front-panel binaries off the box and record the bytes they put on the wire.

Needs qemu-arm (user mode). Nothing here touches the EX4.
WD's up_send_daemon (+ optionally up_read_daemon) run under qemu-arm with the stock rootfs' own ld.so, libc and librs232.so;
/dev/ttyS1 is a pty; libxmldbc.so is our stand-in (xmlstub.c: a file store + a log of every node set / read); the two shell
commands the daemons spawn (rm, xmldbc) are stubs that only log. Then WD's up_send_ctl is run once per command line and
every byte that arrives on the pty is recorded with its time. A fake MCU can answer (see --mcu).

  emu_capture.py --rootfs DIR --recon DIR --stub libxmldbc.so --work DIR [--mcu silent|ack] [--reader]
                 [--reply HEX ...] --cmd "FanControl 3" --cmd "GetThemister 2" ...   -> work/capture.json + stdout

--mcu silent : nothing answers (stock then repeats each frame 10 times, 300 ms apart: that repeat is recorded too)
--mcu ack    : after each whole frame (the frame end byte seen) the fake MCU writes --ack-frame (hex) back
--reply HEX  : bytes written to the pty (MCU -> box) after the commands, one per flag, 0.5 s apart; needs --reader
"""
import argparse, json, os, pty, select, shutil, signal, subprocess, sys, termios, threading, time

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rootfs", required=True); ap.add_argument("--recon", required=True)
    ap.add_argument("--stub", required=True); ap.add_argument("--work", required=True)
    ap.add_argument("--mcu", default="silent", choices=["silent", "ack"])
    ap.add_argument("--ack-frame", default=""); ap.add_argument("--frame-end", default="")
    ap.add_argument("--reader", action="store_true")
    ap.add_argument("--cmd", action="append", default=[]); ap.add_argument("--reply", action="append", default=[])
    ap.add_argument("--settle", type=float, default=4.0)
    a = ap.parse_args()
    W = os.path.abspath(a.work)
    if os.path.exists(W): sys.exit("work dir exists: " + W)
    for d in ("root/dev", "root/tmp", "libs", "bin", "xml", "cwd"): os.makedirs(os.path.join(W, d))
    R = os.path.abspath(a.rootfs)
    os.symlink(os.path.join(R, "lib"), os.path.join(W, "root/lib"))
    open(os.path.join(W, "root/tmp/msg_info.txt"), "w").close()
    # the NEEDED closure of the three binaries, as real files under their sonames (the rootfs' absolute symlinks do not resolve here)
    def needed(path):
        o = subprocess.run(["arm-linux-gnueabi-readelf", "-d", path], stdout=subprocess.PIPE).stdout.decode()
        return [l.split("[")[1].split("]")[0] for l in o.splitlines() if "(NEEDED)" in l]
    def find(soname):
        for d in ("usr/local/modules/usrlib", "usr/local/modules/lib", "lib", "usr/lib"):
            c = os.path.join(R, d, soname)
            if os.path.isfile(os.path.realpath(c)) and os.path.realpath(c).startswith(R): return os.path.realpath(c)
            if os.path.islink(c):    # an absolute link into the rootfs: resolve it against the rootfs, one hop at a time
                t = os.readlink(c)
                for _ in range(8):
                    t2 = os.path.join(R, t.lstrip("/")) if t.startswith("/") else os.path.join(os.path.dirname(c), t)
                    if os.path.islink(t2): c = t2; t = os.readlink(t2); continue
                    if os.path.isfile(t2): return t2
                    break
        return None
    todo = [os.path.join(a.recon, b) for b in ("up_send_ctl", "up_send_daemon", "up_read_daemon")]; seen = {}
    while todo:
        for n in needed(todo.pop()):
            if n in seen or n in ("libc.so.6", "libxmldbc.so", "ld-linux.so.3", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1", "libgcc_s.so.1"): continue
            f = find(n); seen[n] = f
            if not f: sys.exit("cannot find " + n + " in the rootfs")
            shutil.copy(f, os.path.join(W, "libs", n)); todo.append(f)
    shutil.copy(a.stub, os.path.join(W, "libs/libxmldbc.so"))
    for name in ("rm", "xmldbc", "up_send_ctl"):
        p = os.path.join(W, "bin", name)
        with open(p, "w") as f:
            f.write("#!/bin/sh\necho \"$(date +%s.%N) " + name + " $*\" >> '" + W + "/shell.log'\n")
            if name == "xmldbc":   # the one real effect stock relies on: `xmldbc -d NODE` deletes the node
                f.write("if [ \"$1\" = \"-d\" ]; then /bin/rm -f \"" + W + "/xml/N$(echo \"$2\" | tr / ^)\"; fi\n")
        os.chmod(p, 0o700)
    master, slave = pty.openpty()
    os.symlink(os.ttyname(slave), os.path.join(W, "root/dev/ttyS1"))
    env = {"PATH": "/usr/bin:/bin", "HOME": W}
    def q(binary, *args):
        return ["qemu-arm", "-L", os.path.join(W, "root"), "-E", "LD_LIBRARY_PATH=" + os.path.join(W, "libs"),
                "-E", "XMLSTUB_DIR=" + os.path.join(W, "xml"), "-E", "PATH=" + os.path.join(W, "bin") + ":/usr/bin:/bin",
                os.path.join(a.recon, binary)] + list(args)
    t0 = time.time(); rec = []; lock = threading.Lock(); stop = [False]
    ack = bytes.fromhex(a.ack_frame) if a.ack_frame else b""; fend = bytes.fromhex(a.frame_end) if a.frame_end else b""
    def pump():
        while not stop[0]:
            r, _, _ = select.select([master], [], [], 0.05)
            if not r: continue
            try: b = os.read(master, 4096)
            except OSError: break
            with lock: rec.append((round(time.time() - t0, 4), "box->mcu", b.hex()))
            if a.mcu == "ack" and ack and fend and b.endswith(fend):
                os.write(master, ack)
                with lock: rec.append((round(time.time() - t0, 4), "mcu->box", ack.hex()))
    th = threading.Thread(target=pump, daemon=True); th.start()
    procs = []; out = {"work": W, "pty": os.ttyname(slave), "libs": {k: v.replace(R, "<rootfs>") for k, v in seen.items()}, "runs": []}
    def spawn(binary, *args):
        lf = open(os.path.join(W, binary + ".out"), "wb")
        p = subprocess.Popen(q(binary, *args), cwd=os.path.join(W, "cwd"), env=env, stdin=subprocess.DEVNULL, stdout=lf, stderr=subprocess.STDOUT)
        procs.append(p); return p
    try:
        tio0 = termios.tcgetattr(slave)
        spawn("up_send_daemon"); time.sleep(1.5)
        if a.reader: spawn("up_read_daemon"); time.sleep(1.0)
        tio1 = termios.tcgetattr(slave)
        names = {v: k for k, v in vars(termios).items() if k.startswith("B") and k[1:].isdigit()}
        out["termios_before"] = {"iflag": tio0[0], "oflag": tio0[1], "cflag": tio0[2], "lflag": tio0[3], "ispeed": names.get(tio0[4]), "ospeed": names.get(tio0[5])}
        out["termios_after"] = {"iflag": tio1[0], "oflag": tio1[1], "cflag": tio1[2], "lflag": tio1[3], "ispeed": names.get(tio1[4]), "ospeed": names.get(tio1[5]),
                                "CSIZE_is_CS8": (tio1[2] & termios.CSIZE) == termios.CS8, "PARENB": bool(tio1[2] & termios.PARENB),
                                "CSTOPB": bool(tio1[2] & termios.CSTOPB), "CRTSCTS": bool(tio1[2] & termios.CRTSCTS),
                                "IXON": bool(tio1[0] & termios.IXON), "IXOFF": bool(tio1[0] & termios.IXOFF),
                                "ICANON": bool(tio1[3] & termios.ICANON), "ECHO": bool(tio1[3] & termios.ECHO), "OPOST": bool(tio1[1] & termios.OPOST),
                                "VMIN": tio1[6][termios.VMIN] if isinstance(tio1[6][termios.VMIN], int) else tio1[6][termios.VMIN][0],
                                "VTIME": tio1[6][termios.VTIME] if isinstance(tio1[6][termios.VTIME], int) else tio1[6][termios.VTIME][0]}
        out["msg_info"] = open(os.path.join(W, "root/tmp/msg_info.txt")).read().strip()
        for c in a.cmd:
            with lock: n0 = len(rec)
            ts = round(time.time() - t0, 4)
            r = subprocess.run(q("up_send_ctl", *c.split()), cwd=os.path.join(W, "cwd"), env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
            time.sleep(a.settle)
            with lock: got = rec[n0:]
            out["runs"].append({"cmd": c, "t": ts, "rc": r.returncode, "stdout": r.stdout.decode("latin1"), "wire": got})
        for h in a.reply:
            b = bytes.fromhex(h); xl = os.path.join(W, "xml/LOG")
            n0 = len(open(xl).read().splitlines()) if os.path.exists(xl) else 0
            s0 = len(open(os.path.join(W, "shell.log")).read().splitlines()) if os.path.exists(os.path.join(W, "shell.log")) else 0
            with lock: w0 = len(rec)
            os.write(master, b); time.sleep(0.8)
            new = open(xl).read().splitlines()[n0:] if os.path.exists(xl) else []
            snew = open(os.path.join(W, "shell.log")).read().splitlines()[s0:] if os.path.exists(os.path.join(W, "shell.log")) else []
            with lock: echo = rec[w0:]
            out["runs"].append({"reply": h, "xml": new, "shell": [x.split(" ", 1)[1] for x in snew], "wire_after": echo})
    finally:
        stop[0] = True
        for p in procs:
            p.send_signal(signal.SIGKILL); p.wait()
        mi = out.get("msg_info", "").split()
        if mi and mi[0].isdigit(): subprocess.run(["ipcrm", "-q", mi[0]], stderr=subprocess.DEVNULL)
    for b in ("up_send_daemon", "up_read_daemon"):
        p = os.path.join(W, b + ".out")
        if os.path.exists(p): out[b + "_stdout"] = open(p, "rb").read().decode("latin1")[-3000:]
    for f in ("shell.log", "xml/LOG"):
        p = os.path.join(W, f)
        if os.path.exists(p): out[f] = open(p).read()[-6000:]
    json.dump(out, open(os.path.join(W, "capture.json"), "w"), indent=1)
    print(json.dumps(out, indent=1))

main()
