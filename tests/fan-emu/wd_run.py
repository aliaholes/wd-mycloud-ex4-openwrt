#!/usr/bin/python3 -I
# SPDX-License-Identifier: GPL-2.0-or-later
"""wd_run.py — run ONE of WD's own EX4 userland binaries off the box (qemu-arm user mode) and record what it
tries to do: every shell command it spawns (stubs that only log), every xmldb node it sets / reads (the xmldb
stand-in), every libshare register / memory call (the libshare stand-in, shstub.c), and its system calls (-strace).
Nothing here touches the EX4. Sister of emu_capture.py (which drives up_send_ctl + the two daemons on a pty).

  wd_run.py --rootfs DIR --bin PATH --stub libxmldbc.so [--shstub libshare.so] --work DIR
            [--stub-cmd NAME[=TEXT]] ... [--file GUESTPATH=HOSTFILE] ... [--xml NODE=VALUE] ... [--reg ADDR=VALUE] ... -- ARGS...

--stub-cmd NAME        a command of that name in PATH that logs its arguments (shell.log) and prints TEXT (if given)
--stub-cmd NAME=@FILE  ... and runs FILE (a shell snippet; $W is the work dir) after logging
--file G=H             H is copied to <work>/root/G before the run (the guest sees it at G)
--xml NODE=VALUE       a node the xmldb stand-in already holds
Output: <work>/run.json (rc, stdout, shell.log, xml/LOG, sh/LOG, strace lines with open / ioctl / write / exec).
Born Nov 17 2026 (EX4 run 7 prep)."""
import argparse, json, os, shutil, subprocess, sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rootfs", required=True); ap.add_argument("--bin", required=True)
    ap.add_argument("--stub", required=True); ap.add_argument("--shstub"); ap.add_argument("--work", required=True)
    ap.add_argument("--stub-cmd", action="append", default=[]); ap.add_argument("--file", action="append", default=[])
    ap.add_argument("--xml", action="append", default=[]); ap.add_argument("--timeout", type=float, default=40.0)
    ap.add_argument("--env", action="append", default=[], help="K=V: one more variable in the guest's environment")
    ap.add_argument("--reg", action="append", default=[], help="ADDR=VALUE (hex): a register the libshare stand-in already holds")
    ap.add_argument("args", nargs="*")
    a = ap.parse_args()
    W = os.path.abspath(a.work); a.bin = os.path.abspath(a.bin)
    if os.path.exists(W): sys.exit("work dir exists: " + W)
    for d in ("root/dev", "root/tmp", "root/proc", "root/etc", "libs", "bin", "xml", "sh", "cwd"): os.makedirs(os.path.join(W, d))
    R = os.path.abspath(a.rootfs)
    os.symlink(os.path.join(R, "lib"), os.path.join(W, "root/lib"))
    def needed(path):
        o = subprocess.run(["arm-linux-gnueabi-readelf", "-d", path], stdout=subprocess.PIPE).stdout.decode()
        return [l.split("[")[1].split("]")[0] for l in o.splitlines() if "(NEEDED)" in l]
    def find(soname):
        for d in ("usr/local/modules/usrlib", "usr/local/modules/lib", "lib", "usr/lib"):
            c = os.path.join(R, d, soname)
            if os.path.isfile(os.path.realpath(c)) and os.path.realpath(c).startswith(R): return os.path.realpath(c)
            if os.path.islink(c):
                t = os.readlink(c)
                for _ in range(8):
                    t2 = os.path.join(R, t.lstrip("/")) if t.startswith("/") else os.path.join(os.path.dirname(c), t)
                    if os.path.islink(t2): c = t2; t = os.readlink(t2); continue
                    if os.path.isfile(t2): return t2
                    break
        return None
    skip = {"libc.so.6", "libxmldbc.so", "ld-linux.so.3", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1", "libgcc_s.so.1"}
    if a.shstub: skip.add("libshare.so")
    todo = [a.bin]; seen = {}
    while todo:
        for n in needed(todo.pop()):
            if n in seen or n in skip: continue
            f = find(n); seen[n] = f
            if not f: sys.exit("cannot find " + n + " in the rootfs")
            shutil.copy(f, os.path.join(W, "libs", n)); todo.append(f)
    shutil.copy(a.stub, os.path.join(W, "libs/libxmldbc.so"))
    if a.shstub: shutil.copy(a.shstub, os.path.join(W, "libs/libshare.so"))
    for sc in a.stub_cmd:
        name, _, text = sc.partition("=")
        p = os.path.join(W, "bin", name)
        with open(p, "w") as f:
            f.write("#!/bin/sh\nW='" + W + "'\necho \"" + name + " $*\" >> \"$W/shell.log\"\n")
            if text.startswith("@"): f.write(open(text[1:]).read() + "\n")
            elif text: f.write("printf '%s\\n' '" + text.replace("'", "'\\''") + "'\n")
        os.chmod(p, 0o700)
    for fs in a.file:
        g, _, h = fs.partition("=")
        dst = os.path.join(W, "root", g.lstrip("/")); os.makedirs(os.path.dirname(dst), exist_ok=True); shutil.copy(h, dst)
    for xs in a.xml:
        n, _, v = xs.partition("=")
        open(os.path.join(W, "xml", "N" + n.replace("/", "^")), "w").write(v)
    for rs in a.reg:
        n, _, v = rs.partition("=")
        open(os.path.join(W, "sh", "R%08x" % int(n, 16)), "w").write("%08x\n" % int(v, 16))
    cmd = ["qemu-arm", "-strace", "-L", os.path.join(W, "root"), "-E", "LD_LIBRARY_PATH=" + os.path.join(W, "libs"),
           "-E", "XMLSTUB_DIR=" + os.path.join(W, "xml"), "-E", "SHSTUB_DIR=" + os.path.join(W, "sh"),
           "-E", "PATH=" + os.path.join(W, "bin") + ":/usr/bin:/bin"] + [x for e in a.env for x in ("-E", e)] + [a.bin] + a.args
    env = {"PATH": "/usr/bin:/bin", "HOME": W}
    try:
        r = subprocess.run(cmd, cwd=os.path.join(W, "cwd"), env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=a.timeout)
        rc = r.returncode; so = r.stdout.decode("latin1"); se = r.stderr.decode("latin1")
    except subprocess.TimeoutExpired as e:
        rc = "timeout"; so = (e.stdout or b"").decode("latin1"); se = (e.stderr or b"").decode("latin1")
    def rd(p):
        p = os.path.join(W, p)
        return open(p).read() if os.path.exists(p) else ""
    keep = [l for l in se.splitlines() if any(k in l for k in (" open(", " openat(", " ioctl(", " execve(", " mmap2(", "/dev/", "stime(", "settimeofday(", "clock_settime(")) and "/lib" not in l and ".so" not in l]
    if not keep and not so: keep = se.splitlines()[-12:]          # nothing recognisable: show how it ended
    out = {"bin": os.path.basename(a.bin), "args": a.args, "rc": rc, "stdout": so[-4000:], "shell": rd("shell.log").splitlines(),
           "xml": rd("xml/LOG").splitlines(), "sh": rd("sh/LOG").splitlines(), "strace": keep[-80:], "libs": sorted(seen)}
    json.dump(out, open(os.path.join(W, "run.json"), "w"), indent=1)
    print("== %s %s -> rc %s" % (out["bin"], " ".join(a.args), rc))
    for k in ("stdout", "shell", "xml", "sh", "strace"):
        v = out[k]
        if v: print("-- " + k + ":\n" + (v if isinstance(v, str) else "\n".join(v)))

main()
