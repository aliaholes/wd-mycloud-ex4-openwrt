#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
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
[ -e "$W" ] && { echo "REFUSED: $W exists"; exit 1; }
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
	-nic user,mac=52:54:00:e4:00:01 -netdev user,id=n1 -device e1000,netdev=n1,mac=52:54:00:e4:00:01,romfile= \
	-device qemu-xhci,id=xhci -drive if=none,id=usbd,file="$W/usb.img",format=raw -device usb-storage,bus=xhci.0,drive=usbd \
	-serial file:"$W/serial.log" -qmp unix:"$W/qmp.sock",server,nowait -pidfile "$W/qemu.pid" -daemonize
QP=$(cat "$W/qemu.pid")
if [ "$MODE" = silent ]; then python3 -I "$MCU" "$W/mcu.sock" "$W/mcu.json" --silent --secs "$SECS" > "$W/mcu.log" 2>&1 &
else python3 -I "$MCU" "$W/mcu.sock" "$W/mcu.json" --secs "$SECS" --events "40:fa2100000000fb,42:fa2200000000fb,44:fa2600000100fb" > "$W/mcu.log" 2>&1 & fi
T0=$(date +%s); SELF=0
while [ $(( $(date +%s) - T0 )) -lt "$SECS" ]; do
	kill -0 "$QP" 2>/dev/null || { SELF=1; break; }
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
seq = []
for h in fr:
    n = WL.get(h, "??" + h)
    if not seq or seq[-1] != n: seq.append(n)
print("   %d frames from the guest (%d bytes of line noise before the first), order without repeats: %s" % (len(fr), len(noise), " ".join(seq[:24])))
assert fr and fr[0] == "fa0200030000fb", fr[:3]
assert all(h in WL for h in fr), [h for h in fr if h not in WL][:5]
assert d["leftover"] == "" and len(s) - len(noise) == 7 * len(fr), "bytes outside whole frames"
if sys.argv[2] == "normal":
    assert "LOW" not in seq and "MEDIUM" not in seq and {"TH_SATA", "TH_MAIN"} <= set(seq), seq
    assert fr.count("fa0301000000fb") == 1 and fr.count("fa0100030100fb") == 1, ("READY / CLOCK_READ counts", fr.count("fa0301000000fb"), fr.count("fa0100030100fb"))
    assert fr.index("fa0301000000fb") > fr.index("fa0308020000fb") and len(d["events_sent"]) == 3, ("READY after the first reading; three button frames sent by the fake micro", d["events_sent"])
if sys.argv[2] == "silent": assert fr[:10] == ["fa0200030000fb"] * 10 and "fa0301000000fb" not in fr and "fa0100030100fb" not in fr, fr[:10]
if sys.argv[2] == "rpmzero": assert "MAX" in seq, seq
PY
has "$W/serial.log" "ttyS1 at " "the guest has a 16550 as ttyS1 (the second pci-serial port)"
has "$W/serial.log" "ex4fan: start pid=" "the preinit hook started ex4fan (its start line is on the console)"
has "$W/serial.log" "ex4fan: port /dev/.*ttyS1 open: 19200 8N1" "ex4fan opened ttyS1 and set 19200 8N1"
[ "$(outside)" = "$O0" ] && ok "wall: every byte of the disk outside partition 3's [1 MiB, 3 MiB) is unchanged (SMART reads write nothing)" || no "wall: the disk changed outside the log region"
[ -s "$W/disklog.txt" ] && ok "the disk log is readable by the host reader ($(grep -c . "$W/disklog.txt") lines)" || no "no disk log"
case "$MODE" in
deadman)
	[ $SELF = 1 ] && ok "the guest REBOOTED by itself after $RAN s" || no "the guest did not reboot in $SECS s"
	has "$W/disklog.txt" "rc.d S03: deadman armed: reboot to stock in 1 + 2 min unless /tmp/ex4-stay exists" "disk log: the deadman was armed at S03 (this overlay: --return-min 1, so 3 minutes)"
	has "$W/disklog.txt" "deadman: 1 + 2 min, no /tmp/ex4-stay: rebooting to stock now" "disk log: the deadman's note, written before it rebooted"
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
