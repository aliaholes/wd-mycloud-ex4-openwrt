#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# qemu-e2e.sh (v8 = v7 + THE WEB INTERFACE's DOOR + THE ONE LCD TEST FRAME, Nov 17 2026). The probe and the inside
# checks follow the overlay: one built with --webui (it carries www-ex4/index.html) must show, from OUTSIDE the guest
# through qemu's forwards, uhttpd started by its init script from the uci config 95_ex4_webui wrote (not from
# command-line flags): port 443 completes TLS and serves the page, port 80 answers ONLY with a redirect to https (no
# page, no /ubus), POST /ubus over https with no session: session.login, ex4.status refused ("Access denied"),
# ex4.setup_state answers claimed:false (the one door open before sign-in); and inside, the self-test sees the same
# from the guest's own tools, no rpcd login exists, and no TCP port but 22, 80 and 443 is on a LAN address (53 only
# when the rootfs carries dnsmasq). An overlay without --webui is held to v7's checks (80 and 443 closed). Every mode:
# the fake micro ACKs LCD frames, and at most ONE LCD frame, the self-test's send-test (WD's SysName), is on the wire;
# MODE normal requires exactly that one, ACKed, in the disk log. Below: v7's header.
# qemu-e2e.sh (v7 = v6 + THE SECURITY CHECKS, Nov 17 2026). MODE normal also forwards three host ports on 127.0.0.1
# through each of qemu's two user networks to the guest's ports 80, 443 and 22, and about 250 s into the boot (uhttpd
# starts at S50, the last init script about 160 s in) probes them from OUTSIDE the guest: a JSON-RPC session.login
# as root on /ubus with an empty and with a random password, a LuCI login with an empty password, a plain HTTP
# request, a TLS handshake on 443, port 22's banner (the control: the forward reaches the guest at all), and, with
# EX4_E2E_SSHKEY=<the private half of the key the overlay was built with>, a key login that reads root's password
# field as a STATE (star / EMPTY / other) plus a password-only attempt (PASS = the server offers publickey only).
# PASS = every login refused, 80 and 443 closed, port 22 reachable; inside the guest the self-test's "-- security"
# block says root's field is locked ('*'), uhttpd listens on 127.0.0.1:80 only with no /ubus, and no TCP port but 22
# (dropbear), and 53 when the rootfs has dnsmasq (the official image; v7/v8 images have none), is bound to a non-loopback
# address. Below: v6's header.
# qemu-e2e.sh (v5 = qemu-e2e.sh + the run-7 additions) : bundle-v5's overlay inside the trial's real USERSPACE, end
# to end, on an emulated ARM926 (qemu versatilepb). Off the box. What v5 adds to the machine and to MODE normal:
#   * a 64 MiB CFI flash whose device tree carries the EX4's partition names; the "rescue firmware" partition starts
#     with the identity block as WD lays it out (two MAC addresses as text, at byte 0 and byte 0x1c). The test DTB also
#     says compatible = "wd,mycloud-ex4" first, so OpenWrt's userspace takes the EX4 paths of the overlay.
#   * two NICs that both start with the SAME address (as the EX4's two ports do after WD's bond), each on its own
#     qemu user network with a DHCP server. PASS = eth0 / eth1 get the flash's two addresses, br-lan the first, and
#     br-lan takes a DHCP lease.
#   * a PCI xHCI controller (class 0x0c0330, as the EX4's Etron) with a USB disk. The TEST kernel has xhci built in:
#     this proves the self-test's report, NOT that OpenWrt's xhci-pci.ko binds the Etron (those modules are built for
#     the kirkwood kernel; kmodloader cannot load them into this one, and the boot must go on regardless).
#   * the guest has no RTC device (the test DTB disables the board's, as the EX4 has none under this kernel), so its
#     clock starts in 1970: PASS = ex4fan reads the fake micro's clock and SETS the system clock from it (the real
#     clock_settime on a real 6.12 kernel), and the date is still right when the self-test runs.
#   * the fake micro ACKs DeviceReady and sends three button frames by itself: PASS = named in the log, nothing sent back.
# Below: v4's header.
# qemu-e2e.sh : the fan daemon inside the trial's real USERSPACE, end to end, on an emulated ARM926 (qemu
# versatilepb). Off the box. What runs: a Linux 6.12.112 kernel built from kernel.org's tree for the versatile board
# with a built-in 16550 PCI serial driver (NOT the OpenWrt kirkwood kernel: qemu has no Kirkwood machine), the OpenWrt
# 25.12.6 kirkwood initramfs userspace exactly as shipped, the bundle's own overlay.cpio on top of it, an AHCI disk
# with partition 3 (the logger's target), and TWO pci-serial ports: the second one is /dev/ttyS1 in the guest, and a
# FAKE front-panel micro (fake_mcu_sock.py) sits on its other end.
#   MODE normal   the overlay as shipped. PASS = the preinit hook starts ex4fan, its first frame is FAN HIGH, every
#                 byte on the wire is whitelisted, it reads the disk's temperature through SG_IO (qemu's disks answer
#                 SMART), reads both thermistors, logs to the kernel log, and the disk log + self-test carry it.
#   MODE silent   the overlay as shipped, a micro that never answers. PASS = FAILSAFE micro-never-answered, the
#                 reason is in the disk log, and the guest REBOOTS by itself (qemu runs with -no-reboot and exits).
#   MODE deadman  (v5) an overlay built like the bundle's but with --return-min 1. PASS = the S03 deadman reboots the
#                 guest 3 minutes after it was armed, with its note in the disk log, without the boot's last init
#                 script having to do anything.
#   MODE rpmzero  a third archive swaps ex4fan's preinit hook for one with --test-hw (a PL061 GPIO line of the
#                 versatile board as the tachometer: it never moves). PASS = the GPIO character-device path works on
#                 a real 6.12 kernel, "rpm reads 0", fan MAX, FAILSAFE rpm-zero after 30 s, reboot.
# What it does NOT prove: anything about the EX4's hardware (its UART, its GPIO bank, its micro, sata_mv).
# v5: MODE normal now runs 330 s: with a live network the emulated userspace needs about 160 s to reach its last init
# script (S99), and the self-test is written 20 s after that.
#   sh qemu-e2e.sh <zImage> <versatile-pb.dtb patched by mk-e2e-dtb.sh> <openwrt rootfs dir> <overlay.cpio> <ex4log.c> <fake_mcu_sock.py> <workdir> <normal|silent|rpmzero|deadman> [seconds]
# Born Nov 16 2026 (EX4 run 6 prep); v5 Nov 17 2026 (run 7 prep).
set -eu
Z=$1; DTB=$2; ROOT=$3; OVL=$4; XLOGSRC=$5; MCU=$6; W=$7; MODE=$8
case "$MODE" in normal) SECS=${9:-330};; silent) SECS=${9:-120};; rpmzero) SECS=${9:-150};; deadman) SECS=${9:-330};; *) echo "mode?"; exit 64;; esac
MAC1=00:90:A9:AA:BB:50; MAC2=00:90:A9:AA:BB:51          # the test unit's identity (WD's OUI, made-up tail)
HF0=; HF1=; FWD=
if [ "$MODE" = normal ]; then          # v7: six free host ports, three per user network (guest 80, 443, 22)
	FWD=$(python3 -I -c 'import socket
ss = [socket.socket() for _ in range(6)]
for s in ss: s.bind(("127.0.0.1", 0))
print(" ".join(str(s.getsockname()[1]) for s in ss))')
	fp() { echo "$FWD" | cut -d' ' -f"$1"; }
	HF0=",hostfwd=tcp:127.0.0.1:$(fp 1)-:80,hostfwd=tcp:127.0.0.1:$(fp 2)-:443,hostfwd=tcp:127.0.0.1:$(fp 3)-:22"
	HF1=",hostfwd=tcp:127.0.0.1:$(fp 4)-:80,hostfwd=tcp:127.0.0.1:$(fp 5)-:443,hostfwd=tcp:127.0.0.1:$(fp 6)-:22"
fi
[ -e "$W" ] && { echo "REFUSED: $W exists"; exit 1; }
WEBUI=0; grep -a -q 'www-ex4/index.html' "$OVL" && WEBUI=1          # v8: an overlay built with --webui
DNSM=0; [ -e "$ROOT/usr/sbin/dnsmasq" ] && DNSM=1
mkdir -p "$W"; W=$(cd "$W" && pwd)
gcc -O1 -o "$W/ex4log-native" "$XLOGSRC"
( cd "$ROOT" && find . | cpio -o -H newc -R 0:0 --quiet ) > "$W/rootfs.cpio"
cat "$W/rootfs.cpio" "$OVL" > "$W/initrd.cpio"
if [ "$MODE" = rpmzero ]; then
	mkdir -p "$W/t/lib/preinit"
	cat > "$W/t/lib/preinit/02_ex4_fan" <<'HOOK'
# TEST ONLY (qemu-e2e.sh rpmzero): the same daemon, a PL061 line of the versatile board as the tachometer
ex4_fan_start() {
	[ -x /usr/sbin/ex4fan ] && /usr/sbin/ex4fan daemon --test-hw --tty ttyS1 --tach-chip gpio --tach-line 3 </dev/null >/dev/null 2>&1
	return 0
}

boot_hook_add preinit_essential ex4_fan_start
HOOK
	( cd "$W/t" && find . | cpio -o -H newc -R 0:0 --quiet ) >> "$W/initrd.cpio"
fi
if [ "$MODE" = deadman ]; then     # Nov 17 2026 (v9.1 suite): with --return-min 1 BOTH timers are armed and S99's auto-return (S99 + 20 s +
	# self-test + 1 min) beat the deadman (S03 + 3 min) whenever the emulated boot was quick (S99 at 86 s): a race in the TEST, not the
	# product. The mode proves the deadman needs no S99, so S99's rc.d link is replaced here, TEST ONLY, by a no-op that leaves a note
	# (a later cpio entry of the same name replaces the earlier one). The shipped overlay is untouched.
	mkdir -p "$W/t/etc/rc.d"
	printf '#!/bin/sh\n# TEST ONLY (qemu-e2e.sh deadman): S99 auto-return disabled so the S03 deadman alone must reboot\n[ "$1" = boot ] && /usr/sbin/ex4log note "e2e deadman: S99 auto-return disabled by the test"\nexit 0\n' > "$W/t/etc/rc.d/S99ex4-trial"
	chmod 755 "$W/t/etc/rc.d/S99ex4-trial"
	( cd "$W/t" && find . | cpio -o -H newc -R 0:0 --quiet ) >> "$W/initrd.cpio"
fi
P3S=2098831; DISKMB=$(( (P3S + 2047) / 2048 + 40 ))
python3 -I -c 'import sys
with open(sys.argv[1],"wb") as f:
    for _ in range(int(sys.argv[2])): f.write(b"\x5a"*(1<<20))' "$W/disk.img" "$DISKMB"
sgdisk -n1:2048:+8M -n2:0:+8M -n4:0:+8M -n3:51200:$((51200 + P3S - 1)) "$W/disk.img" > "$W/sgdisk.log" 2>&1
P3=$(sgdisk -i3 "$W/disk.img" | awk '/First sector/{print $3}'); P3N=$(sgdisk -i3 "$W/disk.img" | awk '/Partition size/{print $3}')
[ "$P3N" = "$P3S" ] || { echo "REFUSED: partition 3 came out as $P3N sectors"; exit 1; }
outside() { python3 -I -c 'import sys,hashlib; d=open(sys.argv[1],"rb").read(); a=int(sys.argv[2])*512+(1<<20); print(hashlib.md5(d[:a]+d[a+(2<<20):]).hexdigest())' "$W/disk.img" "$P3"; }
O0=$(outside)
# v5: the flash. 64 MiB of 0xFF; the "rescue firmware" partition of the test DTB starts at 0x01500000 and its first
# block holds the identity the way WD's does (read on the real unit: MAC text at +0 and +0x1c, 55 AA "LigRescure" at +0x32).
# v6: as on the box, "reserve" (mtd6) sits BELOW it, at 0x01000000, and starts with a UBI header: a tree that lists
# the partitions in address order (bundle-v5's mistake) would hand the hook that block, and it would find no address.
python3 -I -c 'import sys
f = bytearray(b"\xff" * (64 << 20)); o = 0x01500000
f[0x01000000:0x01000004] = b"UBI#"
blk = bytearray(2048); m1 = sys.argv[2].encode(); m2 = sys.argv[3].encode()
blk[0:17] = m1; blk[0x1c:0x1c + 17] = m2; blk[0x32:0x34] = b"\x55\xaa"; blk[0x34:0x3e] = b"LigRescure"
f[o:o + 2048] = blk
open(sys.argv[1], "wb").write(f)' "$W/flash.img" "$MAC1" "$MAC2"
python3 -I -c 'import sys
with open(sys.argv[1], "wb") as f: f.write(b"\x00" * (16 << 20))' "$W/usb.img"
qemu-system-arm -M versatilepb -cpu arm926 -m 256 -display none -no-reboot \
	-kernel "$Z" -dtb "$DTB" -initrd "$W/initrd.cpio" -append "console=ttyAMA0,115200" \
	-drive if=pflash,format=raw,file="$W/flash.img" \
	-device ahci,id=ahci0 -drive if=none,id=d0,file="$W/disk.img",format=raw -device ide-hd,drive=d0,bus=ahci0.0 \
	-chardev null,id=nul0 -device pci-serial,chardev=nul0 \
	-chardev socket,id=mcu,path="$W/mcu.sock",server=on,wait=off -device pci-serial,chardev=mcu \
	-nic user,mac=52:54:00:e4:00:01$HF0 -netdev user,id=n1$HF1 -device e1000,netdev=n1,mac=52:54:00:e4:00:01,romfile= \
	-device qemu-xhci,id=xhci -drive if=none,id=usbd,file="$W/usb.img",format=raw -device usb-storage,bus=xhci.0,drive=usbd \
	-serial file:"$W/serial.log" -qmp unix:"$W/qmp.sock",server,nowait -pidfile "$W/qemu.pid" -daemonize
QP=$(cat "$W/qemu.pid")
secprobe() {	# v7: from OUTSIDE the guest, through qemu's port forwards (host 127.0.0.1:<port> -> guest 10.0.2.15:80 / 443 / 22)
	python3 -I - "$W/secprobe.txt" "${EX4_E2E_SSHKEY:-}" $FWD <<'PY' || echo "PROBE-ERROR the probe itself failed" >> "$W/secprobe.txt"
import json, secrets, socket, ssl, subprocess, sys
out, key, ports = sys.argv[1], sys.argv[2], sys.argv[3:]
nets = [dict(zip(("http", "https", "ssh"), map(int, ports[i:i + 3]))) for i in range(0, len(ports), 3)]
log = open(out, "a")
def say(*a): print(*a, file=log, flush=True)
def http(port, path, body, ctype):
    """one POST; returns (status line, headers + body text) or None when nothing answers like HTTP (port closed)"""
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=8)
        req = ("POST %s HTTP/1.0\r\nHost: 10.0.2.15\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n" % (path, ctype, len(body))).encode() + body
        s.sendall(req); data = b""
        while True:
            c = s.recv(65536)
            if not c: break
            data += c
        s.close()
    except OSError as e:
        return None, "no HTTP answer (%s)" % e.__class__.__name__
    if not data.startswith(b"HTTP/"):
        return None, "no HTTP answer (%d bytes back)" % len(data)
    t = data.decode("latin-1"); return t.split("\r\n", 1)[0], t
def ubus_login(port, pw):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "call", "params": ["0" * 32, "session", "login", {"username": "root", "password": pw}]}).encode()
    st, t = http(port, "/ubus", body, "application/json")
    if st is None: return "refused", t
    return ("OPEN" if "ubus_rpc_session" in t else "refused"), "%s, %s" % (st, "a session id came back" if "ubus_rpc_session" in t else "no session id")
def luci_login(port, pw):
    st, t = http(port, "/cgi-bin/luci/", ("luci_username=root&luci_password=%s" % pw).encode(), "application/x-www-form-urlencoded")
    if st is None: return "refused", t
    ok = "sysauth" in t.lower() and " 302 " in st + " "
    return ("OPEN" if ok else "refused"), "%s, %s" % (st, "a sysauth cookie came back" if ok else "no sysauth cookie")
def https(port, method, path, body=b"", ctype="application/json"):
    """v8: one request over TLS; returns (status line, full text) or (None, why)"""
    try:
        raw = socket.create_connection(("127.0.0.1", port), timeout=15)
        ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(raw, server_hostname="ex4")
        req = ("%s %s HTTP/1.0\r\nHost: ex4\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n" % (method, path, ctype, len(body))).encode() + body
        s.sendall(req); data = b""
        while True:
            c = s.recv(65536)
            if not c: break
            data += c
        s.close()
    except (OSError, ssl.SSLError) as e:
        return None, "no HTTPS answer (%s)" % e.__class__.__name__
    if not data.startswith(b"HTTP/"):
        return None, "no HTTP answer over TLS (%d bytes back)" % len(data)
    t = data.decode("latin-1"); return t.split("\r\n", 1)[0], t
def rpc(port, obj, method, args):
    body = json.dumps({"jsonrpc": "2.0", "id": 7, "method": "call", "params": ["0" * 32, obj, method, args]}).encode()
    return https(port, "POST", "/ubus", body)
def get80(port, path):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=8)
        s.sendall(("GET %s HTTP/1.0\r\nHost: ex4\r\n\r\n" % path).encode()); data = b""
        while True:
            c = s.recv(65536)
            if not c: break
            data += c
        s.close()
    except OSError as e:
        return None, "", "no HTTP answer (%s)" % e.__class__.__name__
    t = data.decode("latin-1"); head, _, body = t.partition("\r\n\r\n")
    loc = [l.split(":", 1)[1].strip() for l in head.split("\r\n")[1:] if l.lower().startswith("location:")]
    return head.split("\r\n", 1)[0], (loc[0] if loc else ""), body
def tls(port):
    try:
        raw = socket.create_connection(("127.0.0.1", port), timeout=8)
        ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(raw, server_hostname="ex4"); v = s.version(); s.close()
        return "answers", "TLS handshake completed (%s)" % v
    except (OSError, ssl.SSLError) as e:
        return "closed", "no TLS handshake (%s)" % e.__class__.__name__
def banner(port):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=8); b = s.recv(200); s.close()
        return b.split(b"\r\n", 1)[0].decode("latin-1").strip()          # the identification line only
    except OSError:
        return ""
def ssh(port, args, cmd):
    base = ["ssh", "-p", str(port), "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=15",
            "-o", "BatchMode=yes", "-o", "LogLevel=ERROR"] + args + ["root@127.0.0.1", cmd]
    try:
        r = subprocess.run(base, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return 255, "", "timeout"
res = {}
def put(name, val, why):
    worst = {"OPEN": 3, "answers": 3, "offered": 3, "EMPTY": 3, "OTHER": 3, "other": 2, "works": 2, "yes": 2, "served": 2, "redirects": 2, "denied": 1, "unclaimed": 1,
             "refused": 1, "closed": 1, "star": 1, "not-offered": 1}
    say("  %-20s %-9s %s" % (name, val, why))
    if name not in res or worst.get(val, 0) > worst.get(res[name], 0): res[name] = val
rnd = secrets.token_hex(8)
for i, n in enumerate(nets):
    b = banner(n["ssh"]); say("net%d: host ports http %d https %d ssh %d; port 22 banner: %r" % (i, n["http"], n["https"], n["ssh"], b[:60]))
    put("reach", "yes" if b.startswith("SSH-") else "no", "the guest's ssh server answered through this net's forward" if b.startswith("SSH-") else "nothing from port 22 on this net")
    for name, (v, why) in (("ubus_login_empty", ubus_login(n["http"], "")), ("ubus_login_random", ubus_login(n["http"], rnd)), ("luci_login_empty", luci_login(n["http"], ""))):
        put(name, v, why)
    st, t = http(n["http"], "/", b"", "text/plain"); put("http80", "closed" if st is None else "answers", t if st is None else st)
    v, why = tls(n["https"]); put("https443", v, why)
    # v8: the web interface's door, asked the way a browser on the LAN would
    for path in ("/", "/ubus"):
        st, loc, body = get80(n["http"], path)
        red = st is not None and (" 301 " in st + " " or " 302 " in st + " " or " 307 " in st + " " or " 308 " in st + " ") and loc.startswith("https://") and "<html" not in body.lower()
        put("http80_redirect", "redirects" if red else ("closed" if st is None else "OTHER"), "GET %s on 80: %s, Location %r, %d body bytes" % (path, st, loc, len(body)))
    st, t = https(n["https"], "GET", "/")
    page = st is not None and " 200 " in st + " " and "<!doctype html" in t.lower() and "content-security-policy" in t.lower()
    put("https_page", "served" if page else ("closed" if st is None else "OTHER"), "GET / on 443: %s, %d bytes" % (st, len(t)))
    for name, (obj, m, a) in (("anon_session_login", ("session", "login", {"username": "root", "password": ""})), ("anon_ex4_status", ("ex4", "status", {})),
                              ("anon_file_read", ("file", "read", {"path": "/etc/shadow"}))):
        st, t = rpc(n["https"], obj, m, a)
        body = t.partition("\r\n\r\n")[2] if st else ""
        # refused = rpcd's ACL says "Access denied", or the object does not exist at all ("Object not found": e.g. this image has
        # no rpcd file plugin); anything carrying a result or a session id is not refused
        v = "denied" if st and ("Access denied" in body or "Object not found" in body) and '"result"' not in body and "ubus_rpc_session" not in body else ("closed" if st is None else "OTHER")
        put(name, v, "%s.%s over https: %s %s" % (obj, m, st, body[:120]))
    st, t = rpc(n["https"], "ex4", "setup_state", {})
    body = t.partition("\r\n\r\n")[2] if st else ""
    put("anon_setup_state", "unclaimed" if '"claimed":false' in body.replace(" ", "") else ("closed" if st is None else "OTHER"), "ex4.setup_state over https: %s %s" % (st, body[:160]))
    if key:
        rc, so, se = ssh(n["ssh"], ["-i", key, "-o", "IdentitiesOnly=yes", "-o", "PasswordAuthentication=no"],
                         "F=$(sed -n 's/^root:\\([^:]*\\):.*/\\1/p' /etc/shadow); case \"$F\" in '*') echo star;; '') echo EMPTY;; *) echo other;; esac")
        put("ssh_key", "works" if rc == 0 else "fails", "rc %d %s" % (rc, (so or se)[:120]))
        if rc == 0: put("shadow_root_field", so.splitlines()[-1] if so else "unknown", "read over the key login (the state only, never the field itself unless it is * or empty)")
        rc, so, se = ssh(n["ssh"], ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive"], "true")
        offered = "password" in se.split("Permission denied", 1)[-1] or "keyboard-interactive" in se.split("Permission denied", 1)[-1]
        put("ssh_password", "offered" if offered else "not-offered", "rc %d: %s" % (rc, se[-120:]))
for k in ("reach", "ubus_login_empty", "ubus_login_random", "luci_login_empty", "http80", "https443", "ssh_key", "shadow_root_field", "ssh_password",
          "http80_redirect", "https_page", "anon_session_login", "anon_ex4_status", "anon_file_read", "anon_setup_state"):
    say("RESULT %s %s" % (k, res.get(k, "skipped")))
PY
}
if [ "$MODE" = silent ]; then python3 -I "$MCU" "$W/mcu.sock" "$W/mcu.json" --silent --secs "$SECS" > "$W/mcu.log" 2>&1 &
else python3 -I "$MCU" "$W/mcu.sock" "$W/mcu.json" --secs "$SECS" --events "40:fa2100000000fb,42:fa2200000000fb,44:fa2600000100fb" > "$W/mcu.log" 2>&1 & fi
T0=$(date +%s); SELF=0; PROBED=0
while [ $(( $(date +%s) - T0 )) -lt "$SECS" ]; do
	kill -0 "$QP" 2>/dev/null || { SELF=1; break; }
	if [ "$MODE" = normal ] && [ $PROBED = 0 ] && [ $(( $(date +%s) - T0 )) -ge "${EX4_E2E_PROBE_AT:-250}" ]; then
		echo "probe at $(( $(date +%s) - T0 )) s after qemu started" > "$W/secprobe.txt"; secprobe; PROBED=1
	fi
	sleep 1
done
RAN=$(( $(date +%s) - T0 ))
if [ $SELF = 0 ]; then
	python3 -I - "$W/qmp.sock" <<'PY' || true
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile('rw'); f.readline()
for c in ("qmp_capabilities", "quit"):
    f.write(json.dumps({"execute": c}) + "\n"); f.flush(); f.readline()
PY
	sleep 2; kill "$QP" 2>/dev/null || true
fi
wait 2>/dev/null || true
dd if="$W/disk.img" of="$W/p3.img" bs=512 skip="$P3" count="$P3N" 2>/dev/null
"$W/ex4log-native" read "$W/p3.img" --save "$W/disklog.txt" > "$W/read.out" 2>&1 || true
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS  $*"; }
no() { FAIL=$((FAIL+1)); echo "FAIL  $*"; }
has() { grep -a -q -- "$2" "$1" && ok "$3" || { no "$3   (no '$2' in $1)"; }; }
hasnt() { grep -a -q -- "$2" "$1" && no "$3   ('$2' is in $1)" || ok "$3"; }
echo "--- mode $MODE: qemu ran $RAN s, ended by itself: $SELF; serial lines about ttyS / ex4fan:"
grep -aE "ttyS[01] at|ex4fan: (start|port|tacho|cmd|FAILSAFE|rebooting)|reboot: Restarting" "$W/serial.log" | cut -c1-200 | head -24
python3 -I - "$W/mcu.json" "$MODE" <<'PY' && ok "wire: the first frame is FAN HIGH and every frame the guest sent is one of the eight whitelisted ones (see the line above)" || no "wire"
import json, sys
d = json.load(open(sys.argv[1])); fr = [h for t, h in d["frames"]]
WL = {"fa0200010000fb": "LOW", "fa0200020000fb": "MEDIUM", "fa0200030000fb": "HIGH", "fa0200040000fb": "MAX", "fa0308010000fb": "TH_SATA", "fa0308020000fb": "TH_MAIN",
      "fa0301000000fb": "READY", "fa0100030100fb": "CLOCK_READ"}
s = bytes.fromhex(d["stream"]); noise = s[:s.index(b"\xfa")] if b"\xfa" in s else s
# v8: the self-test's ONE LCD test frame (ex4fan ctl send-test: WD's SysName, FA 04 01 00 LEN text FB) is the only other frame allowed
lcd = [h for h in fr if h.startswith("fa040100") and len(h) == 2 * (5 + int(h[8:10], 16) + 1)]
seq = []
for h in fr:
    n = WL.get(h, "LCD_NAME" if h in lcd else "??" + h)
    if not seq or seq[-1] != n: seq.append(n)
print("   %d frames from the guest (%d bytes of line noise before the first), order without repeats: %s; LCD frames: %s" % (len(fr), len(noise), " ".join(seq[:24]), [bytes.fromhex(h[10:-2]).decode() for h in lcd]))
assert fr and fr[0] == "fa0200030000fb", fr[:3]
assert all(h in WL or h in lcd for h in fr), [h for h in fr if h not in WL and h not in lcd][:5]
assert len(lcd) <= 1, ("more than ONE LCD frame", lcd)
assert d["leftover"] == "" and len(s) - len(noise) == sum(len(h) // 2 for h in fr), "bytes outside whole frames"
if sys.argv[2] == "normal":
    assert len(lcd) == 1 and bytes.fromhex(lcd[0][10:-2]).decode() == "ex4-trial", ("normal: exactly ONE LCD frame, the host name", lcd)
    assert "LOW" not in seq and "MEDIUM" not in seq and {"TH_SATA", "TH_MAIN"} <= set(seq), seq
    assert fr.count("fa0301000000fb") == 1 and fr.count("fa0100030100fb") == 1, ("READY / CLOCK_READ counts", fr.count("fa0301000000fb"), fr.count("fa0100030100fb"))
    assert fr.index("fa0301000000fb") > fr.index("fa0308020000fb") and len(d["events_sent"]) == 3, ("READY after the first reading; three button frames sent by the fake micro", d["events_sent"])
if sys.argv[2] == "silent": assert fr[:10] == ["fa0200030000fb"] * 10 and "fa0301000000fb" not in fr and "fa0100030100fb" not in fr, fr[:10]
if sys.argv[2] == "rpmzero": assert "MAX" in seq, seq
PY
has "$W/serial.log" "ttyS1 at " "the guest has a 16550 as ttyS1 (the second pci-serial port)"
[ "$MODE" = normal ] && has "$W/disklog.txt" "ctl send-test: ONE LCD frame (WD's SysName, text 'ex4-trial', [0-9]* bytes, one try): ack=1 (the micro ACKed it) frame fa040100" "v8 panel: the self-test asked ex4fan for its ONE LCD test frame; one try, ACKed, in the disk log"
[ "$MODE" = normal ] && has "$W/disklog.txt" "^send-test: ONE LCD frame" "v8 panel: the self-test recorded the send-test result (/tmp/ex4fan.sendtest)"
[ "$MODE" = normal ] && has "$W/disklog.txt" '"panel":{"mode":"off"' "v8 panel: /tmp/ex4fan.json is in the self-test, and the panel is OFF (no Tier A feed by default)"
has "$W/serial.log" "ex4fan: start pid=" "the preinit hook started ex4fan (its start line is on the console)"
has "$W/serial.log" "ex4fan: port /dev/.*ttyS1 open: 19200 8N1" "ex4fan opened ttyS1 and set 19200 8N1"
[ "$(outside)" = "$O0" ] && ok "wall: every byte of the disk outside partition 3's [1 MiB, 3 MiB) is unchanged (SMART reads write nothing)" || no "wall: the disk changed outside the log region"
[ -s "$W/disklog.txt" ] && ok "the disk log is readable by the host reader ($(grep -c . "$W/disklog.txt") lines)" || no "no disk log"
case "$MODE" in
deadman)
	[ $SELF = 1 ] && ok "the guest REBOOTED by itself after $RAN s" || no "the guest did not reboot in $SECS s"
	has "$W/disklog.txt" "rc.d S03: deadman armed: reboot to stock in 1 + 2 min unless /tmp/ex4-stay exists" "disk log: the deadman was armed at S03 (this overlay: --return-min 1, so 3 minutes)"
	has "$W/disklog.txt" "deadman: 1 + 2 min, no /tmp/ex4-stay: rebooting to stock now" "disk log: the deadman's note, written before it rebooted"
	has "$W/disklog.txt" "e2e deadman: S99 auto-return disabled by the test" "disk log: S99's auto-return was out of the race (the test's stand-in ran), so only the deadman could reboot"
	! grep -q "auto-return: no /tmp/ex4-stay, rebooting to stock now" "$W/disklog.txt" && ok "disk log: no S99 auto-return note (it cannot have been S99)" || no "disk log: S99's auto-return fired in deadman mode"
	hasnt "$W/disklog.txt" "FAILSAFE" "no fail-safe of ex4fan was involved"
	has "$W/serial.log" "reboot: Restarting system" "console: the kernel restarted"
	python3 -I -c 'import sys; r = int(sys.argv[1]); sys.exit(0 if 170 <= r <= 290 else 1)' "$RAN" && ok "timing: the reboot came $RAN s after qemu started (armed about 20 s into the boot + 180 s + the note's 4 s)" || no "timing: $RAN s"
	;;
normal)
	[ $SELF = 0 ] && ok "no reboot: the guest ran the full $SECS s" || no "the guest ended by itself after $RAN s"
	has "$W/disklog.txt" "ex4fan: cmd FAN=3(HIGH) ack=1 tries=1 why=start: first action" "disk log: the first command, FAN HIGH, ACKed at the first try"
	has "$W/disklog.txt" "ex4fan: status .*drives=sda:[0-9][0-9]* main=50 sata=47 .*micro=answers" "disk log: a state line with the disk's temperature (SG_IO SMART on the emulated AHCI disk), both thermistors (50 C, 47 C), micro=answers; the USB disk is not in the drive list"
	has "$W/disklog.txt" "ex4fan: sdb is a USB disk (not in a bay): not counted as a drive" "v5: a USB disk that shows up as sdb is named once and left out of the fan's drive list"
	has "$W/disklog.txt" "ex4fan: tachometer: NOT readable" "disk log: no EX4 GPIO bank on this machine -> tachometer not readable (the fan then stays at HIGH: no LOW / MEDIUM frame above)"
	has "$W/disklog.txt" "^-- fan (ex4fan" "disk log: the self-test carries the fan block"
	has "$W/disklog.txt" "rc.d S02: ex4fan status up=" "disk log: the S02 note with ex4fan's state line (the preinit start had taken)"
	hasnt "$W/disklog.txt" "FAILSAFE" "no fail-safe"
	grep -a "ex4fan: status" "$W/disklog.txt" | tail -1 | cut -c1-300
	echo "--- v5"
	M1=$(echo $MAC1 | tr A-F a-f); M2=$(echo $MAC2 | tr A-F a-f)
	has "$W/serial.log" 'Creating 7 MTD partitions' "v5 machine: the CFI flash came up with the EX4's seven partition names"
	echo "--- v6"
	has "$W/disklog.txt" "^mtd4 offset 0x01500000 size 0x00f00000 name rescue firmware" "v6 flash: the kernel numbers the partitions in the TREE's order, not by address: mtd4 is 'rescue firmware' although 'reserve' lies below it (the self-test's v6 flash block)"
	has "$W/disklog.txt" "^mtd6 offset 0x01000000 size 0x00500000 name reserve" "v6 flash: mtd6 is 'reserve', below mtd4, as in WD's layout (the MAC checks below therefore read the right partition by NAME, past the UBI header planted at the start of 'reserve')"
	has "$W/disklog.txt" "^eth[01] phy addr [0-9]* chip_id 0141\.0c20 page ? " "v6 ex4phy: the static ARM binary ran in the trial userspace and READ a PHY's id through the MII ioctls (the emulated e1000's PHY, 0141.0c20; that PHY has no register 22, printed as ?)"
	has "$W/disklog.txt" "^eth[01] phy none (SIOCGMIIPHY: " "v6 ex4phy: a port whose driver has no MII ioctl is reported, not fatal"
	has "$W/disklog.txt" "^eth0 changes_from [0-9]* to [0-9]* uptime_from [0-9.]* to [0-9.]* link_down_lines [0-9]*\$" "v6 link: the self-test read eth0's carrier_changes twice, 10 s apart"
	has "$W/disklog.txt" "^eth1 changes_from [0-9]* to [0-9]* uptime_from [0-9.]* to [0-9.]* link_down_lines [0-9]*\$" "v6 link: ... and eth1's"
	echo "--- v5 (continued)"
	has "$W/disklog.txt" "MACs: eth0 $M1, eth1 $M2 (flash (rescue firmware, block 0))" "v5 MACs: the preinit hook read both addresses from the 'rescue firmware' partition (OpenWrt's own mtd_get_mac_text) and its note is in the disk log"
	has "$W/disklog.txt" "^eth0 mac $M1 " "v5 MACs: self-test: eth0 carries the unit's first address"
	has "$W/disklog.txt" "^eth1 mac $M2 " "v5 MACs: self-test: eth1 carries the unit's second address"
	has "$W/disklog.txt" "^br-lan mac $M1 " "v5 MACs: self-test: br-lan (the DHCP client's interface) carries the FIRST address"
	has "$W/disklog.txt" "^eth0 was=52:54:00:e4:00:01 now=$M1 want=$M1" "v5 MACs: /tmp/ex4-mac.txt: both ports started with the same address (as after WD's bond), eth0 changed"
	has "$W/disklog.txt" "option macaddr '$M1'" "v5 MACs: /etc/config/network pins br-lan's address (uci-defaults)"
	has "$W/disklog.txt" "inet 10\.0\.2\.15/24 .*br-lan" "v5 network: br-lan took a DHCP lease from qemu's user network (10.0.2.15): the bridge with two distinct port addresses works end to end"
	has "$W/disklog.txt" "^xhci controller 0000:00:[0-9a-f.]* 0x1b36:0x000d driver=xhci_hcd" "v5 usb3 report: the self-test finds the class 0x0c0330 controller and names its driver (test kernel: built-in xhci; NOT a proof for OpenWrt's module on the Etron)"
	has "$W/disklog.txt" "^usb device .* QEMU QEMU USB HARDDRIVE" "v5 usb3 report: the self-test lists the USB disk behind it"
	has "$W/disklog.txt" "rc.d S03: deadman armed: reboot to stock in 20 + 2 min unless /tmp/ex4-stay exists" "v5 deadman: armed at S03, before the modules load (22 minutes; not reached in this run)"
	has "$W/disklog.txt" "rc.d S99 reached: every init script has run" "v5 kmods: the boot reached the last init script although kmodloader cannot load kirkwood modules into this test kernel"
	has "$W/serial.log" "module xhci_hcd: .gnu.linkonce.this_module section size must match" "v5 kmods: kmodloader DID find the overlay's xhci-hcd.ko through /etc/modules.d/54-usb-xhci-hcd and handed it to the kernel (this test kernel refuses it: another build; the kirkwood kernel is the one it was built for)"
	has "$W/disklog.txt" "ex4fan: clock: the system clock was unset (.*): SET from the micro's clock to 2026-11-17 12:30:15 UTC" "v5 clock: a guest that starts in 1970: ex4fan read the micro's clock and SET the system clock (clock_settime on a real 6.12 kernel)"
	has "$W/disklog.txt" "^date: 2026-11-1[78] " "v5 clock: the self-test's date is in 2026-11-17 (it stayed set)"
	has "$W/disklog.txt" "ex4fan: cmd READY (WD's DeviceReady) ack=1 tries=1 (try 1 of 2)" "v5 panel: DeviceReady sent once, ACKed"
	has "$W/disklog.txt" "ex4fan: event PWR: power button (frame 21 00 00 00 00): logged only, no action" "v5 panel: the power button's frame is named in the log"
	has "$W/disklog.txt" "ex4fan: event RST: reset button" "v5 panel: the reset button's frame is named"
	has "$W/disklog.txt" "ex4fan: event UsbBackupPush: USB copy button (frame 26 00 00 01 00)" "v5 panel: the USB copy button's frame is named"
	has "$W/disklog.txt" " ready=acked events=3 clock=set" "v5 panel: the state line ends ready=acked events=3 clock=set"
	[ $SELF = 0 ] && ok "v5 panel: three button frames, and the guest neither rebooted nor shut down" || no "the guest ended by itself"
	echo "--- v7 security: from OUTSIDE the guest (qemu forwards host 127.0.0.1 ports to the guest's 80 / 443 / 22 on both user networks)"
	[ -s "$W/secprobe.txt" ] && sed 's/^/   /' "$W/secprobe.txt" || echo "   (no probe ran: the guest ended before ${EX4_E2E_PROBE_AT:-250} s)"
	has "$W/secprobe.txt" "^RESULT reach yes" "v7 outside: the forward reaches the guest (port 22's ssh banner answered), so 'closed' below means closed"
	has "$W/secprobe.txt" "^RESULT ubus_login_empty refused" "v7 outside: POST /ubus session.login as root with an EMPTY password gets no session"
	has "$W/secprobe.txt" "^RESULT ubus_login_random refused" "v7 outside: POST /ubus session.login as root with a RANDOM password gets no session"
	has "$W/secprobe.txt" "^RESULT luci_login_empty refused" "v7 outside: a LuCI login as root with an empty password gets no sysauth cookie"
	if [ $WEBUI = 1 ]; then
	echo "--- v8: this overlay carries the web interface (uhttpd started by its init script from the uci config 95_ex4_webui wrote)"
	has "$W/secprobe.txt" "^RESULT http80_redirect redirects" "v8 outside: port 80 answers GET / and GET /ubus ONLY with a redirect to https:// (no page, no /ubus on plain HTTP)"
	has "$W/secprobe.txt" "^RESULT https443 answers" "v8 outside: port 443 completes a TLS handshake (the box's own certificate, made by px5g at first boot)"
	has "$W/secprobe.txt" "^RESULT https_page served" "v8 outside: GET / over https serves the interface's one page (with its Content-Security-Policy)"
	has "$W/secprobe.txt" "^RESULT anon_session_login denied" "v8 outside: POST /ubus session.login with no session over https: Access denied (rpcd's session.login door is closed to browsers)"
	has "$W/secprobe.txt" "^RESULT anon_ex4_status denied" "v8 outside: POST /ubus ex4.status with no session: Access denied"
	has "$W/secprobe.txt" "^RESULT anon_file_read denied" "v8 outside: POST /ubus file.read /etc/shadow with no session: refused (Access denied, or no file object at all)"
	has "$W/secprobe.txt" "^RESULT anon_setup_state unclaimed" "v8 outside: ex4.setup_state, the one door open before sign-in, answers claimed:false (no administrator, no default password)"
	else
	has "$W/secprobe.txt" "^RESULT http80 closed" "v7 outside: port 80 does not answer HTTP from outside the guest"
	has "$W/secprobe.txt" "^RESULT https443 closed" "v7 outside: port 443 completes no TLS handshake from outside the guest"
	fi
	if [ -n "${EX4_E2E_SSHKEY:-}" ]; then
		has "$W/secprobe.txt" "^RESULT ssh_key works" "v7 outside: key ssh as root still works (dropbear accepts the key with root's field '*')"
		has "$W/secprobe.txt" "^RESULT shadow_root_field star" "v7 outside: over that key login, root's password field reads '*'"
		has "$W/secprobe.txt" "^RESULT ssh_password not-offered" "v7 outside: a password-only ssh attempt is refused; the server offers publickey only"
	else
		echo "   (no EX4_E2E_SSHKEY: the key-login checks are skipped; the self-test's field state below stands in)"
	fi
	has "$W/disklog.txt" "^security root_password_field locked_star" "v7 inside: the self-test reads root's password field as locked ('*'), never printing it"
	if [ $WEBUI = 1 ]; then
	has "$W/disklog.txt" "^security uhttpd listen_http 0.0.0.0:80,\[::\]:80 listen_https 0.0.0.0:443,\[::\]:443 ubus_prefix /ubus" "v8 inside: uhttpd's uci config as 95_ex4_webui wrote it (80 + 443 on every address, /ubus), and 99-ex4-trial did NOT pin it back to loopback"
	has "$W/disklog.txt" "^security webui yes" "v8 inside: the self-test knows the interface rode in"
	has "$W/disklog.txt" "^security http80 HTTP/1.[01] 30[1278] .* location https://" "v8 inside: port 80, asked from the guest itself (busybox nc), answers GET /ubus with a redirect to https"
	has "$W/disklog.txt" "^security ubus_anon_session_login .*Access denied" "v8 inside: session.login with no session, over https from the guest (uclient-fetch): Access denied"
	has "$W/disklog.txt" "^security ubus_anon_ex4_status .*Access denied" "v8 inside: ex4.status with no session: Access denied"
	has "$W/disklog.txt" '^security ubus_anon_setup_state .*"claimed":false' "v8 inside: ex4.setup_state with no session: claimed false"
	has "$W/disklog.txt" "^security uhttpd_max_requests 16 redirect_https 1 home /www-ex4 rpcd_logins 0" "v8 inside: 16 requests at once (not 3: the web review's nit), port 80 redirects, the interface's own document root, NO rpcd login (no default password)"
	has "$W/disklog.txt" "security: root password field locked (\*), web interface on 443, port 80 redirects, no web login until claimed" "v8 inside: uci-defaults' note in the disk log"
	WANT="22 80 443"
	else
	has "$W/disklog.txt" "^security uhttpd listen_http 127.0.0.1:80 listen_https none ubus_prefix none" "v7 inside: uhttpd's settings: 127.0.0.1:80 only, no HTTPS listener, no /ubus"
	has "$W/disklog.txt" "security: root password field locked (\*), web server on 127.0.0.1:80 only, no /ubus" "v7 inside: uci-defaults' note in the disk log"
	WANT="22"
	fi
	[ $DNSM = 1 ] && WANT="$WANT 53"
	TL=$(grep -a "^security tcp_lan_ports" "$W/disklog.txt" | tail -1)
	echo "   $TL"; grep -a "^security \(udp_lan_ports\|tcp_listen_all\|udp_bound_all\)" "$W/disklog.txt" | tail -3 | sed 's/^/   /'
	GOT=$(echo "$TL" | awk '/^security tcp_lan_ports/ { for (i = 3; i <= NF; i++) if ($i != "none") print $i }' | sort -n | uniq | tr '\n' ' ' | sed 's/ $//')
	WS=$(echo $WANT | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ $//')
	[ -n "$TL" ] && [ "$GOT" = "$WS" ] && ok "v8 inside: the TCP ports on a non-loopback address are exactly: $WS (22 = dropbear$([ $WEBUI = 1 ] && echo ', 80 = the redirect, 443 = the interface')$([ $DNSM = 1 ] && echo ', 53 = dnsmasq'))" || no "v8 inside: TCP ports on a non-loopback address: '$GOT', want exactly '$WS'"
	;;
silent)
	[ $SELF = 1 ] && ok "the guest REBOOTED by itself after $RAN s (qemu -no-reboot exits on a guest reset)" || no "the guest did not reboot in $SECS s"
	has "$W/disklog.txt" "ex4fan: FAILSAFE reason=micro-never-answered" "disk log: FAILSAFE micro-never-answered (the note reached the disk before the reboot)"
	has "$W/disklog.txt" "ex4fan: cmd FAN=3(HIGH) ack=0 tries=10" "disk log: the unanswered first command, ack=0 after 10 tries"
	has "$W/serial.log" "ex4fan: rebooting now: the worker's fail-safe" "console: the supervisor announced the reboot"
	has "$W/serial.log" "reboot: Restarting system" "console: the kernel restarted (the reboot system call)"
	;;
rpmzero)
	[ $SELF = 1 ] && ok "the guest REBOOTED by itself after $RAN s" || no "the guest did not reboot in $SECS s"
	has "$W/disklog.txt" "ex4fan: tachometer: line 3 of /dev/.*gpiochip[0-9] (.*) through the GPIO character device" "disk log: the tachometer line was taken through the GPIO character device (GPIO v2 ioctls on a real 6.12 kernel)"
	has "$W/disklog.txt" "ex4fan: rpm reads 0 with FAN=3 commanded: fan to MAX" "disk log: a line that never moves reads 0 rpm -> fan to MAX"
	has "$W/disklog.txt" "ex4fan: FAILSAFE reason=rpm-zero for 3[0-9] s while FAN=4(MAX) was commanded" "disk log: FAILSAFE rpm-zero after 30 s"
	has "$W/serial.log" "reboot: Restarting system" "console: the kernel restarted"
	;;
esac
echo "qemu-e2e $MODE: $PASS passed, $FAIL failed   (workdir $W)"
[ $FAIL = 0 ]
