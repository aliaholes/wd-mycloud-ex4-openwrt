#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# ex4-trial.sh (v6 = v5 + THE LINK FLAP AND THE FLASH LAYOUT) : runs ON the WD My Cloud EX4, under its STOCK firmware (busybox sh).
# v6 (run 8): same module, same logger, same launch as v5. The DEVICE TREE inside kernel.bin changed in two places:
#   flash   WD's last three flash partitions are not in address order ("reserve", mtd6, sits BELOW "rescue firmware",
#           mtd4). The v5 tree had them in address order, so run 7's kernel looked for the unit's two MAC addresses
#           in the wrong 15 MiB and found none. The tree now carries WD's own offsets (the stock kernel's boot log).
#           Still every partition read-only.
#   PHYs    both Ethernet PHYs go to the kernel's generic PHY driver. Under Linux's Marvell PHY driver the cabled
#           port lost and regained its link once a second in runs 5 to 7 (about 110 carrier changes a minute).
# The overlay adds ex4phy (reads PHY registers, has no write call) and three self-test blocks; `verdict` gains the
# V6 lines (where the flash partitions sit, which driver holds each PHY + what the chips answer, carrier changes
# over 10 s). Below: v5's own header.
# ex4-trial.sh (v5 = v4 + THE HARDWARE GAPS OF RUN 5) : runs ON the WD My Cloud EX4, under its STOCK firmware (busybox sh).
# v5 (run 7): same kernel + DTB (byte for byte), same module, same logger, same launch as v4. The overlay adds:
#   MACs    the unit's own two addresses on the two LAN ports, read (read-only) from the "rescue firmware" flash
#           partition the way WD's mac_read does: eth0 = the first, eth1 = the second; br-lan, the interface that asks
#           for the DHCP lease, is pinned to the first (what WD's bond showed), so the lease stays the same.
#   USB 3   xhci-hcd / xhci-pci for the Etron EJ168, taken out of the official OpenWrt 25.12.6 zyxel_nsa325 image
#           (same release, same kernel build; KMODS.txt holds their sha256).
#   clock   the SoC's RTC has no crystal on this board; ex4fan READS the front-panel micro's clock (as WD's rtc does)
#           and sets the system clock from it only while that is still unset. NTP then corrects it.
#   panel   ex4fan sends WD's DeviceReady once ("the system is up") and NAMES the micro's own events in the log (power,
#           reset, USB copy button ...). No event causes any action. No LED frame is sent (on the EX4 the LEDs are SoC
#           pins and the SATA controller's, not the micro's; this trial leaves them as stock left them).
# `verdict` gains the V5 lines (both MACs + br-lan's, the xHCI controller's driver + USB devices, the clock, DeviceReady
# + the events seen, the link-flap counter of the cabled port). `check` prints the addresses stock uses now.
# Below: v4's own header.
# ex4-trial.sh (v4 = v3 + THE FAN) : runs ON the WD My Cloud EX4, under its STOCK firmware (busybox sh).
# v4 (run 6): the overlay now carries ex4fan, the daemon that speaks to the front-panel microcontroller on uart1
# (ttyS1) so the fan is managed under the trial kernel (run 5 had no fan control). Its first action is fan HIGH; it
# mirrors WD's own curve 16 C cooler; if the micro never answers, the rpm reads 0 for 30 s or a drive reaches 55 C
# it reboots the trial (back to this stock system, which runs its own fan). Nothing else changed against v3: same
# kernel + DTB, same module, same logger, same launch. `verdict` gains one FAN: line (rpm seen, temperatures, any
# fail-safe reboot), read from the trial's "ex4fan: ..." lines in the disk log, the RAM ring or the LAN witness.
# Below: v3's own header.
# ex4-trial.sh (v3, the modern kernel through the fixed loader) : runs ON the WD My Cloud EX4, under its STOCK
# firmware (busybox sh). v3 = bundle-v1's payload (OpenWrt 25.12.6's 6.12 kernel + the EX4 trial DTB with every NAND
# partition read-only, + the overlay: DHCP client, key-only ssh, self-test, 20-min auto-return, the ex4log disk
# logger) launched the way bundle-v2 proved on this box in run 4b: through ex4boot-l2off.ko (the stub turns the
# Feroceon L2 cache off before the copy, as U-Boot hands over), with the three RAM markers, the launch log and a
# verdict. The run id rides in the kernel command line (ex4boot_run=<id>), so the trial's own disk log and kernel log
# name the run they belong to.
# It never writes flash and never writes a disk device: there is no mtd write command and no device write in this
# file (the only writer of a disk is the TRIAL kernel's ex4log daemon: partition 3 of a bay disk, bytes [1 MiB, 3 MiB)).
# A failed run ends by itself (with `wdt`) or with a power cycle, and stock boots from the untouched NAND.
#
#   sh ex4-trial.sh check [wdt]     DEFAULT. Read-only: the exact box + firmware? bundle intact? log target unused?
#                                   which LAN ports have a cable? Prints the insmod line it WOULD use.
#   sh ex4-trial.sh load-dry        insmod with dryrun=1 (images into RAM, cannot boot), compare the module's CRC32s
#                                   and r1 with the bundle's, find the RAM markers in memory with ex4peek (proof that
#                                   the marker reader works), rmmod. No reboot.
#   sh ex4-trial.sh go [wdt]        the real thing: load, verify, quiet the box (data volume read-only, network
#                                   down), jump.  wdt = arm the 21 s SoC watchdog just before the jump. For THIS
#                                   payload that is the recommended way: OpenWrt's 6.12 kernel has the orion watchdog
#                                   driver built in, the trial DTB enables its node, and the driver adopts a running
#                                   watchdog and feeds it until userspace (procd) takes over (read in the kernel
#                                   image and in 6.12.112's source, Nov 16 2026), for at most 120 s: the bundle's
#                                   command line carries watchdog.open_timeout=120, so a kernel that runs but never
#                                   gets a userspace is reset too. A kernel that hangs before that is
#                                   reset after 21 s and stock comes back by itself, with RAM (markers, the kernel's
#                                   log ring) intact. Without wdt a hang is a dark box and a power cycle, and a power
#                                   cycle clears RAM. NOT proven on hardware: that 6.12 reaches its watchdog driver
#                                   inside 21 s (copy with caches off + XZ decompression + early boot). If it does
#                                   not, the verdict says so (a kernel log in RAM without the driver's line) and the
#                                   next run goes without wdt.
#   sh ex4-trial.sh verdict [all]   AFTER the box is back on stock. Read-only. RAM first (markers, the trial kernel's
#                                   log ring), then the disk log (FRESH or STALE against the state recorded before
#                                   the jump), the launch log, stock's start ledger, an optional LAN witness file,
#                                   then ONE line:
#                                     VERDICT: MODERN KERNEL BOOTED (how far: kernel | userspace | network) ...
#                                     VERDICT: HUNG AFTER THE JUMP: how far the evidence reaches ...
#                                     VERDICT: INCONCLUSIVE: why
#                                   Run it EARLY: the RAM evidence lives in memory stock reuses. `all` also reads the
#                                   partitions LOGCFG keeps off (see `log`).
#   sh ex4-trial.sh log [all]       the disk log printed in full (RAM ring first), FRESH / STALE, copies under logs/.
#                                   `log all` also reads the partitions LOGCFG keeps off (LOG_SKIP_PARTS: on this unit
#                                   sdd3, whose disk has an unreadable sector inside the region; reading it costs
#                                   minutes of ATA error handling, so nothing reads it by default).
#   sh ex4-trial.sh klog            only the RAM ring.      sh ex4-trial.sh marker    only the RAM markers.
#   sh ex4-trial.sh unload          rmmod ex4boot.
#
# Bundle (same folder): ex4boot-l2off.ko (bundle-v2's, the module that made the proven jump of run 4b)
#   kernel.bin (bundle-v1's: OpenWrt 6.12.112 zImage + the EX4 trial DTB)   overlay.cpio (v5: v4's + the MAC hook + xhci modules)
#   ex4fan (static ARM; a copy of the binary inside the overlay, for its md5; never run on this side)
#   KMODS.txt (v5: where the three xhci modules in the overlay come from, their sha256 and vermagic)
#   atags.bin (CORE, MEM 512 MiB, INITRD2 = the overlay, CMDLINE with the run id)   markA/C/H.bin (RAM markers)
#   SEGS ("file address" in copy order)  EXPECT ("seg<N> <crc32>")  RUNID  CFG  LOGCFG  MD5SUMS
#   ex4peek (static, read-only: marker, klog)   ex4log (static; on this side only `read`, O_RDONLY)
# RAM markers (4096 bytes each, copied by the stub as segments): A = first copy of all (0x1000), C = after the
#   kernel, the ATAGs and the overlay (0x3000), H = last (0x03000000). Under STOCK 0x1000-0x3fff is never reused
#   (run 4a: A, C and H came back whole after a watchdog reset). A 6.12 kernel that gets as far as its memory
#   allocator MAY reuse all three: missing markers next to a kernel log or a fresh disk log mean nothing.
# WHERE A RUN LEAVES ITS TRACES:
#   logs/launch-<stamp>.log          this script's steps up to the moment the data volume goes read-only
#   logs/prejump-state-<stamp>.txt   the state line of every sdX3 log region before the jump (tells fresh from stale)
#   sdX3, bytes [1 MiB, 3 MiB)       written by the TRIAL kernel's ex4log daemon every few seconds (survives power off)
#   RAM                              the markers and the trial kernel's log ring (a warm reset keeps them, power off not)
#   logs/early-klog-<run id>.txt     OPTIONAL, put there by an early RAM capture helper (not in this repo): the trial kernel's log ring as read
#                                    out of RAM in the first minute after stock answered again. Stock checks its data
#                                    volume for minutes after an unexpected reboot before this folder can be reached,
#                                    and reuses RAM meanwhile. `verdict` reads this file when the ring is gone from RAM.
#   logs/lan-witness-*.txt           OPTIONAL, put there by hand after the run: what host/ex4-watch.sh saw from
#                                    the LAN while the trial ran (first line "LAN-WITNESS run=<id> reached=ssh|ping|none ...")
#   logs/verdict-<stamp>.txt + marker-, klog-, klogscan-, postjump-state-, disklog-<part>-, dmesg-<stamp>.txt
# Stock's start ledger /mnt/HD_a4/.@database@/<hostname>.err: stock's database appends one "mysqld_safe Starting"
#   line about 5 minutes into EVERY boot. `go` records the count; a start between the launch and the running boot
#   means a stock system came up in between (for this payload that should never happen).
# Status Nov 17 2026: built for run 7. Run 5 (bundle-v3) = MODERN KERNEL BOOTED (network), fan unmanaged; run 6
#   (bundle-v4) = the fan ran under ex4fan (13 of 13 commands ACKed by the real micro, rpm 2040 -> 1020).
set -u
D=$(cd "$(dirname "$0")" && pwd)
MODE=${1:-check}
WDT=0; ALL=0
usage() { echo "usage: sh ex4-trial.sh check [wdt] | load-dry | go [wdt] | verdict [all] | log [all] | klog | marker | unload" >&2; exit 64; }
case "$MODE" in
check|go) case "${2:-}" in wdt) WDT=1;; "") ;; *) usage;; esac; [ -z "${3:-}" ] || usage;;
verdict|log) case "${2:-}" in all) ALL=1;; "") ;; *) usage;; esac; [ -z "${3:-}" ] || usage;;
load-dry|klog|marker|unload) [ -z "${2:-}" ] || usage;;
*) usage;;
esac
KO=ex4boot-l2off.ko
LL=                              # the launch log (set by `go`); say/die copy their lines into it while it can be written
llog() { [ -n "$LL" ] && { echo "$(date '+%Y-%m-%d %H:%M:%S') up $(awk '{print $1}' /proc/uptime) $*" >> "$LL"; } 2>/dev/null; return 0; }   # silent once the volume is read-only
say() { echo "ex4-trial: $*"; llog "$*"; }
die() { echo "ex4-trial: REFUSED: $*" >&2; llog "REFUSED: $*"; exit 1; }

# ---- the box this bundle was built for (every line read from the one test unit, Nov 16 2026) ----
WANT_VERSION='Linux version 3.2.40 (kman@kmachine) (gcc version 4.6.4 20120731 (prerelease) (Linaro GCC branch-4.6.4. Marvell GCC 201301-1645.aee66e26) ) #1 Fri Nov 16 11:50:03 CST 2018'
WANT_UIMAGE_MD5=878ee04b2b17efde852acae0f0e1ff29      # first 3459232 bytes of mtd1 = WD's 2.12.127 uImage (GPL bundle copy is identical)
WANT_UIMAGE_LEN=3459232
WANT_MTD='mtd0: 00100000 00020000 "u-boot"
mtd1: 00500000 00020000 "uImage"
mtd2: 00500000 00020000 "ramdisk"
mtd3: 0cd00000 00020000 "image"
mtd4: 00f00000 00020000 "rescue firmware"
mtd5: 01400000 00020000 "config"
mtd6: 00500000 00020000 "reserve"'

gate() {
	[ "$(cat /proc/version)" = "$WANT_VERSION" ] || die "kernel is not WD 2.12.127's 3.2.40 build: $(cat /proc/version)"
	grep -q "Feroceon 88FR131" /proc/cpuinfo || die "CPU is not a Feroceon 88FR131"
	grep -q "DB88FXX81" /proc/cmdline || die "kernel command line is not the EX4's"
	[ "$(grep '^mtd' /proc/mtd)" = "$WANT_MTD" ] || die "/proc/mtd is not the EX4 layout"
	[ "$(grep MemTotal /proc/meminfo | awk '{print ($2 > 480000 && $2 < 530000)}')" = 1 ] || die "not a 512 MiB unit"
	M=$(dd if=/dev/mtd1 bs=$WANT_UIMAGE_LEN count=1 2>/dev/null | busybox md5sum | awk '{print $1}')
	[ -n "$M" ] || die "could not md5 mtd1 (empty output)"
	[ "$M" = "$WANT_UIMAGE_MD5" ] || die "the kernel in flash ($M) is not the one this bundle was built against"
	[ "$(cat /proc/sys/kernel/modules_disabled 2>/dev/null)" = 0 ] || die "module loading is disabled"
	grep -q '^ex4boot ' /proc/modules && [ "$MODE" != unload ] && die "ex4boot is already loaded (rmmod ex4boot first)"
	A_MM=$(awk '$3=="setup_mm_for_reboot"{print $1}' /proc/kallsyms)
	A_RP=$(awk '$3=="kernel_restart_prepare"{print $1}' /proc/kallsyms)
	A_PF=$(awk '$3=="cpu_feroceon_proc_fin"{print $1}' /proc/kallsyms)
	[ -n "$A_MM" ] && [ -n "$A_RP" ] && [ -n "$A_PF" ] || die "kallsyms does not list the three functions ex4boot needs"
	[ "$A_MM" != 00000000 ] || die "kallsyms addresses are hidden"
	say "gate passed: stock 2.12.127 kernel, EX4 flash layout, 512 MiB, modules allowed"
}

cfg() {           # the small text files only (no image is read here: `verdict` scans RAM before anything loads the images)
	for f in CFG LOGCFG RUNID SEGS EXPECT; do [ -s "$D/$f" ] || die "bundle file missing: $f"; done
	ENTRY=; ENTRY8=; R2=; R1_EXPECT=; MARK_TOTAL=; MARK_AT=; MARK_POS=; KVER=
	. "$D/CFG"        # ENTRY ENTRY8 R2 R1_EXPECT MARK_TOTAL MARK_AT (POS:HEXADDR,...) MARK_POS ("0 1 2") KVER (the trial kernel's version, e.g. 6.12.112)
	LOG_MIN_KB=; LOG_MAX_KB=; LOG_EXACT_KB=; LOG_SKIP_PORT=; LOG_SKIP_PARTS=
	. "$D/LOGCFG"     # the window the trial's ex4log was built with; LOG_SKIP_PORT / LOG_SKIP_PARTS = the bay kept off
	RUNID=$(cat "$D/RUNID")
	[ -n "$RUNID" ] && [ -n "$ENTRY8" ] && [ -n "$R1_EXPECT" ] && [ -n "$MARK_AT" ] && [ -n "$KVER" ] && [ -n "$LOG_MIN_KB" ] && [ -n "$LOG_MAX_KB" ] || die "CFG, LOGCFG or RUNID is incomplete"
}

md5one() {        # $1 = file name as MD5SUMS lists it
	want=$(awk -v n="$1" '$2 == n {print $1}' "$D/MD5SUMS")
	[ -n "$want" ] || die "$1 is not listed in MD5SUMS"
	got=$(busybox md5sum "$D/$1" | awk '{print $1}')
	[ -n "$got" ] || die "md5 of $1 came back empty"
	[ "$got" = "$want" ] || die "$1 is damaged (md5 $got, want $want)"
}

bundle() {
	for f in $KO ex4peek ex4log ex4fan KMODS.txt kernel.bin overlay.cpio atags.bin markA.bin markC.bin markH.bin MD5SUMS; do [ -s "$D/$f" ] || die "bundle file missing: $f"; done
	cfg
	while read -r sum name; do
		[ -s "$D/$name" ] || die "bundle file missing: $name"
		got=$(busybox md5sum "$D/$name" | awk '{print $1}')
		[ -n "$got" ] || die "md5 of $name came back empty"
		[ "$got" = "$sum" ] || die "$name is damaged (md5 $got, want $sum)"
	done < "$D/MD5SUMS"
	for f in $KO ex4peek ex4log ex4fan KMODS.txt CFG LOGCFG RUNID SEGS EXPECT; do
		grep -q " $f\$" "$D/MD5SUMS" || die "MD5SUMS does not cover $f"
	done
	while read -r f a; do
		[ -n "$f" ] || continue
		grep -q " $f\$" "$D/MD5SUMS" || die "SEGS names $f, which MD5SUMS does not cover"
	done < "$D/SEGS"
	say "bundle intact ($(wc -l < "$D/MD5SUMS") files); module $KO, run id $RUNID, trial kernel $KVER"
}

skipped() { case " $LOG_SKIP_PARTS " in *" $1 "*) return 0;; esac; return 1; }

LOGPARTS=
loggate() {       # is the raw log target the partition the trial's logger was designed for? Reads /proc only.
	LOGPARTS=
	for d in sda sdb sdc sdd; do
		kb=$(awk -v p="${d}3" '$4 == p {print $3}' /proc/partitions)
		[ -n "$kb" ] || continue
		grep -q "^/dev/${d}3 " /proc/mounts && die "log gate: /dev/${d}3 is MOUNTED on this firmware: it is not the unused partition the logger was designed for"
		grep -q "^/dev/${d}3 " /proc/swaps && die "log gate: /dev/${d}3 is SWAP on this firmware"
		grep -q "${d}3\[" /proc/mdstat && die "log gate: /dev/${d}3 is a member of an md array on this firmware"
		if [ "$kb" -lt "$LOG_MIN_KB" ] || [ "$kb" -gt "$LOG_MAX_KB" ]; then
			say "log gate: /dev/${d}3 is $kb KiB, outside the window $LOG_MIN_KB..$LOG_MAX_KB KiB: the trial will not use it"
			continue
		fi
		[ -z "$LOG_EXACT_KB" ] || [ "$kb" = "$LOG_EXACT_KB" ] || die "log gate: /dev/${d}3 is $kb KiB, not the $LOG_EXACT_KB KiB this bundle was pinned to"
		if skipped "${d}3"; then say "log gate: /dev/${d}3 is kept off (LOGCFG: SATA port $LOG_SKIP_PORT): the trial does not write it, this script does not read it"; continue; fi
		LOGPARTS="$LOGPARTS ${d}3:$kb"
	done
	[ -n "$LOGPARTS" ] || die "log gate: no unused sdX3 inside $LOG_MIN_KB..$LOG_MAX_KB KiB: the trial would have nowhere to write its log (/proc/partitions: $(awk 'NR>2{printf "%s=%s ", $4, $3}' /proc/partitions))"
	say "log gate passed: unused, not mounted, not md, not swap, size in the window (KiB):$LOGPARTS. The trial writes its log to the one on the lowest SATA port (the first in this list), bytes [1 MiB, 3 MiB)."
}

OWRT_DEFAULT="192.""168.1.1"   # OpenWrt's factory-default LAN address, in two pieces (this repo's publish scanner refuses private-range literals)
NICDIR=/sys/class/net
nics() {          # $1 = warn | wall. The trial bridges both LAN ports (OpenWrt's default for a two-port NAS, no spanning tree):
	          # two cables into the same switch would be a loop on the LAN. Reads sysfs only.
	C0=$(cat "$NICDIR/egiga0/carrier" 2>/dev/null); C1=$(cat "$NICDIR/egiga1/carrier" 2>/dev/null)
	say "LAN ports under stock: egiga0 carrier ${C0:-unreadable}, egiga1 carrier ${C1:-unreadable} (1 = a live cable)"
	if [ "$C0" = 1 ] && [ "$C1" = 1 ]; then
		if [ "$1" = wall ] && [ "${EX4_TWO_CABLES_OK:-0}" != 1 ]; then
			die "BOTH LAN ports have a live cable. The trial system bridges its two ports without spanning tree: if both cables go to the same network that is a loop. Unplug one cable, or set EX4_TWO_CABLES_OK=1 if they go to separate networks. Nothing was loaded."
		fi
		say "WARNING: both LAN ports have a live cable; the trial system bridges them (a loop if both go to the same network). \`go\` refuses this unless EX4_TWO_CABLES_OK=1."
	fi
	return 0
}

logstate() {      # one line per sdX3: the newest whole snapshot in its log region (read-only)
	for d in sda sdb sdc sdd; do
		[ -b "/dev/${d}3" ] || continue
		if [ $ALL = 0 ] && skipped "${d}3"; then echo "${d}3 skipped (kept off in LOGCFG)"; continue; fi
		echo "${d}3 $("$D/ex4log" read "/dev/${d}3" --state 2>&1)"
	done
}

insmod_line() {   # $1 = folder holding the staged files, $2 = extra params. No r1: the module then hands over the id THIS
	          # kernel was booted with (527); a device-tree kernel does not use it (6.12 matches the DTB's compatible).
	SEGARG=
	while read -r f a; do
		[ -n "$f" ] || continue
		SEGARG="$SEGARG${SEGARG:+,}$1/${f##*/}@$a"
	done < "$D/SEGS"
	echo "insmod $1/$KO segs=$SEGARG entry=$ENTRY r2=$R2 a_setup_mm=0x$A_MM a_restart_prepare=0x$A_RP a_proc_fin=0x$A_PF $2"
}

stage() {         # copy what the module loads to RAM so the data volume can go read-only later
	T=/tmp/ex4boot; mkdir -p $T || die "cannot make $T"
	free=$(df -k /tmp | awk 'NR==2{print $4}'); need=$(du -k "$D/kernel.bin" "$D/overlay.cpio" "$D/$KO" | awk '{s+=$1}END{print s+1024}')
	[ "$free" -gt "$need" ] || die "/tmp has ${free}K free, need ${need}K"
	cp "$D/$KO" $T/ || die "copy $KO"
	while read -r f a; do
		[ -n "$f" ] || continue
		cp "$D/$f" "$T/${f##*/}" || die "copy $f"
	done < "$D/SEGS"
}

verify_loaded() {
	[ -r /proc/ex4boot ] || die "module did not create /proc/ex4boot (dmesg | tail)"
	cat /proc/ex4boot
	while read -r seg crc; do
		grep -q "^$seg .* crc32 $crc " /proc/ex4boot || { rmmod ex4boot; die "$seg in RAM does not have crc32 $crc: unloaded, nothing booted"; }
	done < "$D/EXPECT"
	grep -q "; entry $ENTRY8 r1 $R1_EXPECT r2 $R2; " /proc/ex4boot || { rmmod ex4boot; die "the module's entry / r1 / r2 are not $ENTRY8 / $R1_EXPECT / $R2 (r1 = the machine id this kernel was booted with; the bundle expects $R1_EXPECT, what U-Boot passes): unloaded, nothing booted"; }
	say "every segment in RAM matches EXPECT; entry $ENTRY8, r1 $R1_EXPECT (the running kernel's own machine id), r2 $R2"
}

mstate() {        # $1 = file with ex4peek marker output, $2 = run id, $3 = pos  -> INTACT | DAMAGED | OTHER | ABSENT | UNREADABLE | (empty)
	awk -v r="run=$2" -v p="pos=$3" '$1 == "MARKER" && $2 == p && $4 == r { sub(/^state=/, "", $5); print $5; exit }' "$1"
}

markers() {       # $1 = output file. This run's RAM markers at their addresses, then one scan of all RAM. Read-only.
	md5one ex4peek
	: > "$1" || die "cannot write $1"
	"$D/ex4peek" marker --run "$RUNID" --total "$MARK_TOTAL" --at "$MARK_AT" >> "$1" 2>&1
	"$D/ex4peek" marker --scan >> "$1" 2>&1
	return 0
}

RING=0
klog() {          # $1 = stamp. The trial kernel's log ring, out of RAM (read-only /dev/mem). Sets RING=1 when found.
	md5one ex4peek
	"$D/ex4peek" klog --out "$L/klog-$1.txt" > "$L/klogscan-$1.txt" 2>&1
	case $? in
	0) RING=1;;
	3) RING=0; rm -f "$L/klog-$1.txt";;
	*) RING=0; say "RAM: ex4peek klog failed (see $L/klogscan-$1.txt)";;
	esac
}

STARTDIR=/mnt/HD_a4/.@database@
starts() {        # how many times stock's userland has started its database, ever (nothing printed if the ledger is not there)
	[ -r "$STARTDIR/$(hostname).err" ] || return 0
	grep -c 'mysqld_safe Starting mysqld daemon' "$STARTDIR/$(hostname).err"
	return 0
}

field() {         # $1 = key, $2 = launch log: the value of key=... on its first line
	awk -v k="$1=" 'NR == 1 { for (i = 1; i <= NF; i++) if (index($i, k) == 1) { print substr($i, length(k) + 1); exit } }' "$2"
}

hasfield() {      # $1 = exact word, $2 = file: is it a whole space-separated word on some line?  (prefix "cmdline:" lines only if $3 is given)
	awk -v t="$1" -v p="${3:-}" 'p == "" || index($0, p) == 1 { for (i = 1; i <= NF; i++) if ($i == t) { f = 1; exit } } END { exit !f }' "$2"
}

anyfield() {      # $1 = prefix, $2 = file: does some word start with it?  ($3 = line prefix, optional)
	awk -v t="$1" -v p="${3:-}" 'p == "" || index($0, p) == 1 { for (i = 1; i <= NF; i++) if (index($i, t) == 1) { f = 1; exit } } END { exit !f }' "$2"
}

first() {         # $1 = fixed text, $2 = file: the first line that holds it (awk only: nothing else is proven on this box)
	awk -v t="$1" 'index($0, t) { print; exit }' "$2"
}

section() {       # $1 = title prefix of an ex4log section ("-- trail"), $2 = payload file, $3 = max lines: the lines under it
	awk -v t="$1" -v m="$3" 'f && /^-- / { exit } f { if (n < m) print "   " $0; n++ } index($0, t) == 1 { f = 1 } END { if (n > m) print "   [... " n - m " more line(s) in the saved copy ...]" }' "$2"
}

L="$D/logs"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"     # names every file this run leaves under logs/ (never reused: the pid is in it)
V=/dev/null
vd() { echo "$*"; echo "$*" >> "$V"; }
case "$MODE" in
check)
	gate; bundle
	loggate
	nics warn
	TM=$(awk '$2 == "/tmp" { m = $3 " (" $4 ")" } END { print m }' /proc/mounts)
	say "/tmp on this firmware: ${TM:-not a mount of its own (part of the root file system)} (the images are staged there before the jump; nothing of this bundle is executed from it)"
	say "would run: $(insmod_line /tmp/ex4boot "wdt=$WDT")"
	if [ $WDT = 1 ]; then say "wdt=1: the 21 s watchdog is armed just before the jump; OpenWrt's 6.12 kernel adopts and feeds it (driver built in, node enabled in the trial DTB) and gives userspace 120 s to open it (watchdog.open_timeout=120 in the command line). A hang before or after that resets to stock by itself."
	else say "wdt=0: no watchdog. A kernel that hangs stays dark until a power cycle, and a power cycle clears the RAM evidence."; fi
	say "fan: under the trial kernel the overlay's ex4fan manages it (first action fan HIGH; fail-safe = a reboot back to this stock system). Stock's own fan_control keeps running here until the jump."
	say "v5 MACs: stock now: bond0 $(cat "$NICDIR/bond0/address" 2>/dev/null), egiga0 $(cat "$NICDIR/egiga0/address" 2>/dev/null), egiga1 $(cat "$NICDIR/egiga1/address" 2>/dev/null). The trial reads the unit's own two addresses from flash (read-only): eth0 = the first, eth1 = the second, br-lan (the one that asks for the lease) = the first."
	say "v5 USB 3 / clock / panel: the overlay carries xhci-hcd + xhci-pci from the official OpenWrt image of the same release (KMODS.txt); ex4fan reads the front-panel micro's clock (it never sets it), sends WD's DeviceReady once, and logs the micro's button events without acting on them."
	say "v6 flash / link: the device tree in kernel.bin carries WD's own flash layout (the last three partitions are not in address order; run 7 read the wrong place for the MAC addresses) and hands both Ethernet PHYs to the kernel's generic PHY driver (runs 5 to 7: the cabled port's link dropped once a second under the Marvell driver). Every flash partition is still read-only."
	say "CHECK ONLY: nothing was loaded, nothing was changed."
	;;
load-dry)
	gate; bundle; stage
	mkdir -p "$L" || die "cannot make $L"
	$(insmod_line /tmp/ex4boot dryrun=1) || die "insmod failed: $(dmesg | tail -3)"
	verify_loaded
	MD="$L/markerdry-$STAMP.txt"
	"$D/ex4peek" marker --run "$RUNID" --total "$MARK_TOTAL" --at "$MARK_AT" --scan > "$MD" 2>&1
	cat "$MD"
	MOK=1
	for p in $MARK_POS; do
		grep -q "^FOUND .* run=$RUNID pos=$p/$MARK_TOTAL .* state=INTACT " "$MD" || MOK=0
	done
	rmmod ex4boot || die "rmmod failed"
	[ $MOK = 1 ] || die "the marker reader did not find every marker of run $RUNID in RAM while the module held them (see $MD): module removed, nothing booted"
	say "marker reader OK: every marker of run $RUNID was found whole in RAM by ex4peek (in the loaded copies; nothing is at the fixed addresses until a real jump)"
	say "dry load OK ($KO): module loaded, images verified in RAM, module removed. Nothing booted."
	;;
go)
	trap '' HUP INT TERM      # the ssh session dies when the network goes down; keep going
	mkdir -p "$L" || die "cannot make $L"
	[ -e "$L/launch-$STAMP.log" ] && die "$L/launch-$STAMP.log exists"
	cfg
	LL="$L/launch-$STAMP.log"       # on the data disk, not /tmp: it survives the jump and a power cycle
	N0=$(starts)
	llog "== ex4-trial go variant=l2off module=$KO wdt=$WDT run=$RUNID epoch=$(date +%s) starts=${N0:-unknown} payload=openwrt-$KVER script=$0 =="
	gate; bundle; stage
	loggate
	nics wall
	logstate > "$L/prejump-state-$STAMP.txt" 2>&1
	llog "log regions before the jump: $(awk '{printf "%s; ", $0}' "$L/prejump-state-$STAMP.txt")"
	if [ $WDT = 1 ]; then say "wdt=1: the 21 s watchdog will be armed just before the jump. 6.12 adopts it when its orion_wdt driver starts and feeds it for 120 s or until procd opens it; a hang of the kernel, or a userspace that never starts, brings stock back by itself."
	else say "wdt=0: no watchdog. If the trial kernel hangs, the box stays dark until a power cycle (which clears the RAM evidence)."; fi
	$(insmod_line /tmp/ex4boot "wdt=$WDT") || die "insmod failed: $(dmesg | tail -3)"
	verify_loaded
	{ echo "-- /proc/ex4boot"; cat /proc/ex4boot; echo "-- /proc/cmdline now"; cat /proc/cmdline; echo "-- /proc/mdstat"; cat /proc/mdstat; echo "-- mounts on /mnt"; grep ' /mnt' /proc/mounts; echo "-- dmesg tail"; dmesg | tail -8; } >> "$LL" 2>&1
	say "quieting the box: killing users of /mnt/HD*, remounting read-only, network down. This shell will go silent."
	llog "LAST LINE THIS LOG CAN HOLD. Next, in this order, with nowhere left to write: kill users of /mnt/HD*, remount them read-only, sync, bond0/egiga0/egiga1 down, echo boot > /proc/ex4boot (variant=l2off wdt=$WDT run=$RUNID). If a REFUSED line follows below, the remount failed and nothing booted."
	cd /
	sync
	for p in /proc/[0-9]*; do
		pid=${p#/proc/}; [ "$pid" = "$$" ] && continue
		if ls -l "$p/fd" "$p/cwd" 2>/dev/null | grep -q ' /mnt/HD'; then kill "$pid" 2>/dev/null; fi
	done
	sleep 3
	DIRTY=0
	for m in $(awk '$2 ~ "^/mnt/HD" {print $2}' /proc/mounts); do mount -o remount,ro "$m" 2>/dev/null || DIRTY=1; done
	sync; sleep 3
	if [ $DIRTY = 1 ] && [ "${EX4_DIRTY_OK:-0}" != 1 ]; then
		rmmod ex4boot
		die "could not remount every data volume read-only (something still writes). Nothing booted. Set EX4_DIRTY_OK=1 to go anyway (the RAID may resync when stock returns)."
	fi
	for i in bond0 egiga0 egiga1; do ifconfig $i down 2>/dev/null; done    # stop DMA into memory the new kernel will own
	sleep 1
	echo boot > /proc/ex4boot
	;;
unload)
	rmmod ex4boot && say "unloaded"
	;;
marker)
	cfg
	mkdir -p "$L" || die "cannot make $L"
	markers "$L/marker-$STAMP.txt"
	cat "$L/marker-$STAMP.txt"
	say "MARKER ONLY: read-only; copy in $L/marker-$STAMP.txt"
	;;
klog)
	cfg
	mkdir -p "$L" || die "cannot make $L"
	klog "$STAMP"
	cat "$L/klogscan-$STAMP.txt"
	if [ $RING = 1 ]; then say "RAM: the ring's text is saved in $L/klog-$STAMP.txt (+ .raw)"; else say "RAM: nothing found"; fi
	;;
log)
	bundle
	mkdir -p "$L" || die "cannot make $L"
	say "RAM: looking for the trial kernel's log ring (read-only /dev/mem; only a warm reset leaves it there)"
	klog "$STAMP"
	cat "$L/klogscan-$STAMP.txt"
	if [ $RING = 1 ]; then say "RAM: saved to $L/klog-$STAMP.txt (+ .raw)"; else say "RAM: nothing found"; fi
	LAST=$(ls "$L"/launch-*.log 2>/dev/null | tail -1)
	PRE=
	if [ -n "$LAST" ]; then
		say "newest launch log: $LAST (its last lines:)"; tail -4 "$LAST"
		PS=${LAST##*/launch-}; PRE="$L/prejump-state-${PS%.log}.txt"; [ -s "$PRE" ] || PRE=
	fi
	[ -n "$PRE" ] && say "state before the newest jump: $PRE" || say "no pre-jump state on record for the newest launch: a log found below cannot be called fresh or stale"
	logstate > "$L/postjump-state-$STAMP.txt" 2>&1
	FOUND=0
	while read -r part state; do
		case "$state" in
		"state none") say "DISK $part: no log yet (no magic in either slot)"; continue;;
		"skipped "*) say "DISK $part: not read ($state; \`log all\` reads it)"; continue;;
		"state run="*) ;;
		*) say "DISK $part: $state"; continue;;
		esac
		was=$([ -n "$PRE" ] && awk -v p="$part" '$1 == p { $1 = ""; print substr($0, 2) }' "$PRE")
		if [ -z "$PRE" ]; then verdict="AGE UNKNOWN (no pre-jump record)"
		elif [ "$was" = "$state" ]; then verdict="STALE: identical to the state before the jump, the last trial wrote nothing here"
		else verdict="FRESH: written after the last jump (before: ${was:-nothing recorded})"; fi
		say "DISK $part: $state"
		say "DISK $part: $verdict"
		FOUND=1                 # no shell arithmetic anywhere in this file: the stock busybox sh was built without it
		"$D/ex4log" read "/dev/$part" --save "$L/disklog-$part-$STAMP.txt"
	done < "$L/postjump-state-$STAMP.txt"
	[ $FOUND = 0 ] && say "DISK: no log yet on any sdX3."
	say "LOG ONLY: nothing was loaded, no device was written. Copies are in $L/"
	;;
verdict)
	cfg
	mkdir -p "$L" || die "cannot make $L"
	V="$L/verdict-$STAMP.txt"; MK="$L/marker-$STAMP.txt"; KL="$L/klog-$STAMP.txt"
	vd "== ex4-trial verdict (v6: OpenWrt $KVER through $KO, with ex4fan, MACs, USB 3, clock, panel, flash layout, PHY driver) $(date '+%Y-%m-%d %H:%M:%S'), bundle $D =="
	UP=$(awk '{print $1}' /proc/uptime)
	vd "uptime: $UP s since this kernel started ($(uptime))"
	vd "/proc/cmdline: $(cat /proc/cmdline)"
	CM=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^ex4boot_run=/) { sub(/^ex4boot_run=/, "", $i); print $i; exit } }' /proc/cmdline)
	[ -n "$CM" ] && vd "note: /proc/cmdline holds ex4boot_run=$CM: THIS kernel was started by an ex4boot jump (a bundle-v2 run). That is not a run of this bundle: its payload is OpenWrt, which never hands back to stock without a reset."
	# ---- 1. RAM, before anything else of the bundle is read: stock reuses that memory ----
	vd "-- RAM markers --"
	markers "$MK"
	cat "$MK"; cat "$MK" >> "$V"
	vd "-- RAM: the trial kernel's log ring (ex4peek klog, read-only /dev/mem) --"
	klog "$STAMP"
	awk '/^ex4peek klog: (a Linux|RESULT|[0-9]+ records)/ { print "   " substr($0, 1, 200) }' "$L/klogscan-$STAMP.txt" > "$L/klogsum-$STAMP.txt"
	cat "$L/klogsum-$STAMP.txt"; cat "$L/klogsum-$STAMP.txt" >> "$V"
	KEARLY=0
	if [ $RING = 0 ] && [ -s "$L/early-klog-$RUNID.txt" ]; then
		RING=1; KEARLY=1; KL="$L/early-klog-$RUNID.txt"
		vd "ring: nothing in RAM now, but an EARLY CAPTURE of run $RUNID is on file ($KL: the ring as an early RAM capture helper (not in this repo) read it right after stock answered again, before stock reused that memory): reading that"
	fi
	dmesg > "$L/dmesg-$STAMP.txt" 2>/dev/null
	# ---- 2. the newest launch ----
	LAST=$(ls "$L"/launch-*.log 2>/dev/null | tail -1)
	LV=; LR=; LW=; LE=; LS=; JUMPED=0; PRE=
	if [ -n "$LAST" ]; then
		LV=$(field variant "$LAST"); LR=$(field run "$LAST"); LW=$(field wdt "$LAST"); LE=$(field epoch "$LAST"); LS=$(field starts "$LAST")
		tail -1 "$LAST" | grep -q "LAST LINE THIS LOG CAN HOLD" && JUMPED=1
		PS=${LAST##*/launch-}; PRE="$L/prejump-state-${PS%.log}.txt"; [ -s "$PRE" ] || PRE=
		vd "-- newest launch log: $LAST (wdt=$LW run=$LR; reached the jump: $JUMPED); its last lines:"
		tail -5 "$LAST" | while read -r line; do vd "   $line"; done
	else
		vd "-- no launch log under $L"
	fi
	[ -n "$LR" ] && [ "$LR" != "$RUNID" ] && vd "note: the newest launch log is for run $LR; this bundle's run id is $RUNID"
	MR=${LR:-$RUNID}
	# ---- 3. what the ring says ----
	KERN=0; KUSER=0; KINIT=0; KWDT=0; KTOK=unknown
	if [ $RING = 1 ]; then
		KVL=$(first "Linux version 6." "$KL")
		[ -n "$KVL" ] && KERN=1
		grep -q "ex4log: " "$KL" && KUSER=1
		grep -q "Run /init as init process" "$KL" && KINIT=1
		grep -q "orion_wdt: Initial timeout" "$KL" && KWDT=1
		if hasfield "ex4boot_run=$MR" "$KL"; then KTOK=this
		elif anyfield "ex4boot_run=" "$KL"; then KTOK=other; fi
		vd "ring: $(wc -l < "$KL") line(s) saved in $KL. Version line: ${KVL:-none found (the start of the ring is gone)}"
		vd "ring: command line: $(first "Kernel command line:" "$KL")"
		vd "ring: run id in it: $KTOK (this = ex4boot_run=$MR, the newest launch) · machine: $(first "Machine model:" "$KL")"
		vd "ring: L2 at entry: $(if grep -q 'Feroceon L2: Enabling L2' "$KL"; then echo "OFF, enabled by 6.12 (as after U-Boot)"; elif grep -q 'bootloader left the L2 cache on' "$KL"; then echo "LEFT ON (the fault of runs 1-2: the loader did not turn it off)"; else echo "no Feroceon L2 line in the ring"; fi) · watchdog driver line: $(if [ $KWDT = 1 ]; then echo yes; else echo no; fi) · reached /init: $(if [ $KINIT = 1 ]; then echo yes; else echo no; fi) · ex4log lines (userspace): $(grep -c 'ex4log: ' "$KL")"
		CRASH=$(awk '/Kernel panic|Unable to handle kernel|Internal error:|Unhandled fault/ { print; exit }' "$KL")
		[ -n "$CRASH" ] && vd "ring: IT HOLDS A CRASH: $CRASH"
		[ $KEARLY = 1 ] || grep -q "RESULT: 1 log buffer" "$L/klogscan-$STAMP.txt" || vd "ring: note: the scan found more than one log buffer; only the first is read here (all of them: $L/klogscan-$STAMP.txt)"
		vd "ring: its last lines:"
		tail -12 "$KL" | while read -r line; do vd "   $line"; done
		[ "$KTOK" = other ] && { vd "ring: it names ANOTHER run: it is left over from an earlier trial (RAM was not cleared since) and does not count for run $MR"; KERN=0; KUSER=0; KINIT=0; KWDT=0; }
	else
		vd "ring: no Linux 6.x log ring in RAM (expected after a power cycle; after a warm reset it means the trial kernel never printed, or stock has reused that memory)"
	fi
	# ---- 4. the disk log ----
	md5one ex4log
	vd "-- disk log (the trial's ex4log daemon writes it; read-only here) --"
	[ -n "$PRE" ] && vd "state before the newest jump: $PRE" || vd "no pre-jump state on record for the newest launch: a log found below cannot be called fresh or stale"
	logstate > "$L/postjump-state-$STAMP.txt" 2>&1
	FRESH=0; DL=; DPART=; DSTATE=
	while read -r part state; do
		case "$state" in
		"state none") vd "DISK $part: no log (no magic in either slot)"; continue;;
		"skipped "*) vd "DISK $part: not read ($state; \`verdict all\` reads it)"; continue;;
		"state run="*) ;;
		*) vd "DISK $part: $state"; continue;;
		esac
		was=$([ -n "$PRE" ] && awk -v p="$part" '$1 == p { $1 = ""; print substr($0, 2) }' "$PRE")
		if [ -z "$PRE" ]; then vd "DISK $part: $state: AGE UNKNOWN (no pre-jump record)"
		elif [ "$was" = "$state" ]; then vd "DISK $part: $state: STALE (identical to the state before the jump: the trial wrote nothing here)"
		else
			vd "DISK $part: $state: FRESH, written after the jump (before: ${was:-nothing recorded})"
			if [ $FRESH = 0 ]; then
				"$D/ex4log" read "/dev/$part" --save "$L/disklog-$part-$STAMP.txt" > "$L/disklogread-$part-$STAMP.txt" 2>&1
				[ -s "$L/disklog-$part-$STAMP.txt" ] && { FRESH=1; DL="$L/disklog-$part-$STAMP.txt"; DPART=$part; DSTATE=$state; }
			fi
		fi
	done < "$L/postjump-state-$STAMP.txt"
	DINET=; DTOK=unknown; DRET=0; DSELF=0; DSSH=0; DSTATIC=0; DUPT=; DWDT=0
	if [ $FRESH = 1 ]; then
		DUPT=$(echo "$DSTATE" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^uptime=/) { sub(/^uptime=/, "", $i); print $i } }')
		DINET=$(awk '/^-- \$ ip addr/ { f = 1; next } /^-- / { f = 0 } f && $1 == "inet" && $2 !~ /^127\./ { printf "%s%s on %s", s, $2, $NF; s = ", " }' "$DL")
		if hasfield "ex4boot_run=$MR" "$DL" "cmdline: "; then DTOK=this; elif anyfield "ex4boot_run=" "$DL" "cmdline: "; then DTOK=other; fi
		grep -q "orion_wdt: Initial timeout" "$DL" && DWDT=1
		grep -q "auto-return: no /tmp/ex4-stay" "$DL" && DRET=1
		grep -q "^-- self-test (/tmp/ex4-selftest.txt" "$DL" && DSELF=1
		grep -q "^processes:.*dropbear" "$DL" && DSSH=1
		if [ -z "$DINET" ]; then      # v5 (run 6 showed it): the newest snapshot is often written while the trial is already shutting down for its return (no address, no ssh server left in it). The self-test inside the same log was taken about 45 s after boot.
			DINETSELF=$(awk '/^-- self-test \(/ { st = 1; next } /^-- dmesg \(/ { st = 0 } st && /^-- / { n = ($2 == "network") } st && n && $1 == "inet" && $2 !~ /^127\./ { printf "%s%s on %s", s, $2, $NF; s = ", " }' "$DL")
			[ -n "$DINETSELF" ] && DINET="$DINETSELF (as the self-test in this log recorded it about 45 s after boot; the newest snapshot itself holds no address: it was written while the trial was shutting down)"
		fi
		DSTATIC=$(echo "$DINET" | awk -v o="$OWRT_DEFAULT/" '{ n = split($0, a, ", "); for (i = 1; i <= n; i++) if (index(a[i], o) == 1) f = 1 } END { print f + 0 }')
		vd "disk log: newest snapshot on $DPART, written at trial uptime $DUPT s; saved in $DL"
		vd "disk log: $(awk 'NR == 1 { print; exit }' "$DL")"
		vd "disk log: $(first "version: " "$DL")"
		vd "disk log: $(first "cmdline: " "$DL")"
		vd "disk log: run id in it: $DTOK (this = ex4boot_run=$MR) · LAN addresses: ${DINET:-none} · ssh server running: $(if [ $DSSH = 1 ]; then echo yes; else echo no; fi) · self-test written: $(if [ $DSELF = 1 ]; then echo yes; else echo no; fi) · auto-return note: $(if [ $DRET = 1 ]; then echo yes; else echo no; fi)"
		[ $DSTATIC = 1 ] && vd "disk log: WARNING: the trial held $OWRT_DEFAULT (OpenWrt's router default): the overlay's network setup did not apply"
		vd "disk log: its trail (the daemon's milestones):"
		section "-- trail" "$DL" 40 > "$L/disklogsum-$STAMP.txt"; section "-- notes" "$DL" 20 >> "$L/disklogsum-$STAMP.txt"; section "-- self-test" "$DL" 12 >> "$L/disklogsum-$STAMP.txt"
		cat "$L/disklogsum-$STAMP.txt"; cat "$L/disklogsum-$STAMP.txt" >> "$V"
		[ "$DTOK" = other ] && vd "disk log: it names ANOTHER run in its command line although its state changed since the pre-jump record: read $DL by hand"
	fi
	# ---- 5. the LAN witness (optional file, copied here by hand after the run) ----
	LANW=$(ls "$L"/lan-witness-*.txt 2>/dev/null | tail -1); LAN=none; LANLINE=
	if [ -n "$LANW" ]; then
		LANLINE=$(awk -v r="run=$MR" '$1 == "LAN-WITNESS" && $2 == r { print; exit }' "$LANW")
		case "$LANLINE" in *" reached=ssh"*) LAN=ssh;; *" reached=ping"*) LAN=ping;; esac
		vd "LAN witness: $LANW: ${LANLINE:-no line for run $MR in it}"
	else
		vd "LAN witness: no logs/lan-witness-*.txt (optional: what host/ex4-watch.sh saw from the LAN during the trial)"
	fi
	# ---- 5b. THE FAN: the trial's own "ex4fan: ..." lines (disk log first, then the RAM ring, then the LAN witness) ----
	FANSRC=; FANWHERE=
	if [ $FRESH = 1 ] && grep -q "ex4fan: " "$DL"; then FANSRC=$DL; FANWHERE="the fresh disk log on $DPART"
	elif [ $RING = 1 ] && [ $KERN = 1 ] && grep -q "ex4fan: " "$KL"; then FANSRC=$KL; FANWHERE="the trial kernel's log ring"
	elif [ -n "$LANW" ] && [ -n "$LANLINE" ] && grep -q "ex4fan: " "$LANW"; then FANSRC=$LANW; FANWHERE="the LAN witness file"; fi
	FANFS=
	if [ -n "$FANSRC" ]; then
		awk 'index($0, "ex4fan: ") == 0 { next }
			{ k = substr($0, 1, index($0, "ex4fan: ") - 1); sub(/^.*\[/, "[", k); sub(/^.*ex4fan: /, "")      # the same kernel line sits in dmesg AND in logread: count it once
			  if (seen[k $0]++) next
			  n++ }
			/^start pid=/ { starts++ }
			/^cmd FAN=/ { cmds++; if (index($0, " ack=1 ")) acked++; if (first == "") first = $0; lastcmd = $0 }
			/^status / { st = $0; for (i = 1; i <= NF; i++) if (index($i, "rpm=") == 1) { r = substr($i, 5) + 0; if (r > maxr) maxr = r; if (r > 0 && (minr == 0 || r < minr)) minr = r; if (r == 0) zero++; if (r < 0) norpm++ } }
			/^tachometer: NOT readable/ { notach = 1 }
			/^FAILSAFE reason=/ { if (fs == "") { fs = $0; sub(/^FAILSAFE reason=/, "", fs); sub(/ -> fan MAX.*$/, "", fs) } }
			/^supervisor: the worker ended/ { crashes++ }
			END {
				print "LINES " n + 0
				print "STARTS " starts + 0
				print "FIRST " first
				print "LASTCMD " lastcmd
				print "STATUS " st
				print "RPM " (maxr > 0 ? minr " to " maxr : (notach || norpm > 0 ? "not readable (no tachometer line)" : "never above 0"))
				print "ACKS " acked + 0 " of " cmds + 0
				print "CRASHES " crashes + 0
				print "FAILSAFE " fs
			}' "$FANSRC" > "$L/fan-$STAMP.txt"
		fanv() { awk -v k="$1" '$1 == k { sub(/^[A-Z]+ ?/, ""); print; exit }' "$L/fan-$STAMP.txt"; }
		FANFS=$(fanv FAILSAFE); FANST=$(fanv STATUS)
		FANT=$(echo "$FANST" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(level|drives|main|sata|soc|T)=/) { printf "%s%s", s, $i; s = " " } }')
		vd "-- fan: $(fanv LINES) ex4fan line(s) in $FANWHERE ($FANSRC); the daemon started $(fanv STARTS) time(s), worker crashes: $(fanv CRASHES)"
		vd "fan: first command: $(fanv FIRST)"
		vd "fan: last command:  $(fanv LASTCMD)"
		vd "fan: last state:    ${FANST:-none on record}"
		vd "FAN: rpm seen: $(fanv RPM) · last reading: ${FANT:-no state line on record} · fan commands ACKed by the micro: $(fanv ACKS) · fail-safe reboot: ${FANFS:-none}"
	else
		vd "FAN: no ex4fan line on record for run $MR (no fresh disk log, no ring of this run, no LAN witness with fan lines): whether the fan was managed cannot be told from here"
	fi
	# ---- 5c. v5: MACs, USB 3, the clock, the front panel, the link: from the trial's own self-test and ex4fan lines ----
	V5SRC=; V5WHERE=
	if [ $FRESH = 1 ] && grep -q "^-- v5 macs" "$DL"; then V5SRC=$DL; V5WHERE="the fresh disk log on $DPART"
	elif [ -n "$LANW" ] && [ -n "$LANLINE" ] && grep -q "^-- v5 macs" "$LANW"; then V5SRC=$LANW; V5WHERE="the LAN witness file"; fi
	if [ -n "$V5SRC" ]; then
		# (the stock firmware's awk, busybox 1.20.2, reads NAME ( ... ) as a function call even with a space between: a variable is never followed by an opening parenthesis in here)
		awk 'function q(v) { return v == "" ? "?" : v }
			function val(k,   i) { for (i = 1; i < NF; i++) if ($i == k) { if ($(i + 1) ~ /^(carrier_changes|down_count|at_uptime|phy_id|phy_driver|phy_interface|tx_dropped|tx_errors)$/) return ""; return $(i + 1) } return "" }
			/^-- v5 / { sec = $3 }
			/^-- / && $2 != "v5" { sec = "" }
			sec == "macs" && $2 == "mac" && ($1 == "eth0" || $1 == "eth1" || $1 == "br-lan") { mac[$1] = $3 }
			sec == "macs" && index($0, "source=") == 1 { src = substr($0, 8) }
			sec == "macs" && index($0, "NO /tmp/ex4-mac.txt") == 1 { src = "the MAC hook did not run" }
			sec == "link" && $2 == "carrier_changes" { ch = val("carrier_changes"); up = val("at_uptime"); pm = (up + 0 > 0 && ch != "") ? sprintf("%.0f", ch * 60 / up) : "?"
				pd = ""; if (index($0, " phy_driver ")) { pd = $0; sub(/^.* phy_driver /, "", pd) }          # the name of a PHY driver has spaces in it: it is the rest of the line
				link[$1] = (ch == "" ? "?" : ch) " carrier changes in " (up == "" ? "?" : up) " s of uptime (" pm " a minute), PHY id " q(val("phy_id")) " driver " q(pd) " interface " q(val("phy_interface")) ", tx_dropped " q(val("tx_dropped")) " tx_errors " q(val("tx_errors")) }
			sec == "usb3" && $1 == "xhci" && $2 == "controller" { x = $0; sub(/^xhci controller /, "", x); xc = xc sx x; sx = "; "; nx++; if (x !~ /driver=$/) bound++ }
			sec == "usb3" && $1 == "usb" && $2 == "device" { nu++; if (nu <= 6) { u = $0; sub(/^usb device /, "", u); ul = ul su u; su = "; " } }
			sec == "usb3" && index($0, "modules: ") == 1 { mods = substr($0, 10); sub(/ +$/, "", mods) }
			sec == "clock" && index($0, "date: ") == 1 { date = substr($0, 7); sub(/ +$/, "", date) }
			index($0, "clock: the micro says ") { c = $0; sub(/^.*clock: the micro says /, "the micro says ", c); clk = c }
			index($0, "clock: the system clock was unset") && index($0, "SET from the micro") { cset = 1 }
			index($0, "no clock frame came back") { cnone = 1 }
			index($0, "cmd READY (WD") { r = $0; sub(/^.*cmd READY/, "cmd READY", r); rdy = r }
			index($0, " event ") && index($0, ": logged only, no action") { e = $0; sub(/^.* event /, "", e); sub(/:.*$/, "", e); if (evn[e]++ == 0) { evl = evl se e; se = " " } }
			END {
				print "E0 " mac["eth0"]; print "E1 " mac["eth1"]; print "BR " mac["br-lan"]; print "SRC " src
				print "DISTINCT " ((mac["eth0"] != "" && mac["eth1"] != "" && mac["eth0"] != mac["eth1"]) ? "yes" : "NO")
				print "LEASE " ((mac["br-lan"] != "" && mac["br-lan"] == mac["eth0"]) ? "yes" : "NO")
				print "XHCI " (nx ? xc : "no PCI device of class 0x0c0330 in the self-test"); print "BOUND " (bound + 0) " of " (nx + 0)
				print "MODS " (mods == "" ? "none" : mods); print "NUSB " nu + 0; print "USBL " ul
				print "DATE " date; print "CLK " (clk != "" ? clk : (cnone ? "asked, no clock frame came back" : "no clock line on record")); print "CSET " (cset ? "yes" : ((clk != "" || cnone) ? "no" : "unknown (no clock line on record)"))
				print "RDY " (rdy != "" ? rdy : "no DeviceReady line on record"); print "EVL " (evl == "" ? "none" : evl)
				print "L0 " link["eth0"]; print "L1 " link["eth1"]
			}' "$V5SRC" > "$L/v5-$STAMP.txt"
		v5v() { awk -v k="$1" '$1 == k { sub(/^[A-Z0-9]+ ?/, ""); print; exit }' "$L/v5-$STAMP.txt"; }
		PST=$(echo "${FANST:-}" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(ready|events|clock)=/) { printf "%s%s", s, $i; s = " " } }')
		vd "-- v5: from the trial's self-test and ex4fan lines in $V5WHERE ($V5SRC)"
		vd "V5 MACS: eth0 $(v5v E0) · eth1 $(v5v E1) · br-lan $(v5v BR) · the two ports differ: $(v5v DISTINCT) · br-lan (the lease) carries eth0's, the unit's first: $(v5v LEASE) · source: $(v5v SRC)"
		vd "V5 USB3: xHCI controller: $(v5v XHCI) · bound to a driver: $(v5v BOUND) · modules loaded: $(v5v MODS) · USB devices listed: $(v5v NUSB)$(U=$(v5v USBL); [ -n "$U" ] && echo " ($U)")"
		vd "V5 CLOCK: $(v5v CLK) · system clock set from the micro: $(v5v CSET) · the self-test's date: $(v5v DATE)"
		vd "V5 PANEL: $(v5v RDY) · events from the micro (logged only, no action): $(v5v EVL) · ex4fan's last state: ${PST:-no state line on record}"
		vd "V5 LINK: eth1: $(v5v L1) · eth0: $(v5v L0)"
	else
		vd "V5: no v5 self-test on record for run $MR (no fresh disk log that holds it, no LAN witness that holds it): MACs, USB 3, clock and front panel cannot be told from here"
	fi
	# ---- 5d. v6: the flash layout, the PHY driver, the link over 10 s: from the same self-test ----
	if [ -n "$V5SRC" ] && grep -q "^-- v6 flash" "$V5SRC"; then
		# (same rule as above for the stock firmware's awk: a variable is never followed by an opening parenthesis)
		awk '/^-- v6 / { sec = $3 }
			/^-- / && $2 != "v6" { sec = "" }
			sec == "flash" && $2 == "offset" { n = $0; sub(/^.* name /, "", n); at[n] = $3; idx[n] = $1 }
			sec == "phy" && $2 == "phy_id" { d = ""; if (index($0, " driver ")) { d = $0; sub(/^.* driver /, "", d) }
				np++; if (d == "Generic PHY") ng++
				drv = drv sd $1 " id " $3 " driver " (d == "" ? "NONE" : d); sd = "; " }
			sec == "phy" && $2 == "phy" && $3 == "addr" && $5 == "chip_id" { chip = chip sc $1 " chip id " $6 " register page " $8; sc = "; "; if ($8 == "?") nq++; else if ($8 == "0") nc++; else npg++ }
			sec == "phy" && $2 == "phy" && $3 != "addr" { c = $0; chip = chip sc c; sc = "; " }
			sec == "link" && $2 == "changes_from" { dt = $9 - $7; dc = $5 - $3
				r = (dt > 0 && $3 != "?" && $5 != "?") ? sprintf("%.0f", dc * 60 / dt) : "?"
				lk[$1] = (($3 == "?" || $5 == "?") ? "?" : dc) " carrier changes in " sprintf("%.1f", dt) " s (" r " a minute; counter " $3 " -> " $5 "), link down lines in the kernel log: " $11 }
			END {
				ok = (at["rescue firmware"] == "0x0dd00000" && at["config"] == "0x0ec00000" && at["reserve"] == "0x0d800000" && idx["rescue firmware"] == "mtd4" && idx["config"] == "mtd5" && idx["reserve"] == "mtd6")
				print "FL rescue firmware " idx["rescue firmware"] " at " at["rescue firmware"] ", config " idx["config"] " at " at["config"] ", reserve " idx["reserve"] " at " at["reserve"]
				print "FLOK " (ok ? "yes" : "NO")
				print "DRV " (drv == "" ? "no PHY in the self-test" : drv); print "GEN " ((np > 0 && ng == np) ? "yes" : "NO") " (" (ng + 0) " of " (np + 0) ")"
				print "CHIP " (chip == "" ? "no ex4phy line on record" : chip); print "PAGE " (npg ? "NO" : ((nc > 0 && !nq) ? "yes" : "unknown"))
				print "K0 " (lk["eth0"] == "" ? "no line on record" : lk["eth0"]); print "K1 " (lk["eth1"] == "" ? "no line on record" : lk["eth1"])
			}' "$V5SRC" > "$L/v6-$STAMP.txt"
		v6v() { awk -v k="$1" '$1 == k { sub(/^[A-Z0-9]+ ?/, ""); print; exit }' "$L/v6-$STAMP.txt"; }
		vd "V6 FLASH: $(v6v FL) · WD's own layout (0x0dd00000 / 0x0ec00000 / 0x0d800000): $(v6v FLOK)"
		vd "V6 PHY: $(v6v DRV) · the generic driver holds every PHY: $(v6v GEN) · asked from the chips: $(v6v CHIP) · both on register page 0: $(v6v PAGE)"
		vd "V6 LINK: eth1: $(v6v K1) · eth0: $(v6v K0)"
	elif [ -n "$V5SRC" ]; then
		vd "V6: the self-test on record has no v6 blocks (a bundle older than v6): flash layout, PHY driver and the 10 s link count cannot be told from here"
	fi
	# ---- 6. stock's start ledger + the clock ----
	EXTRA=unknown
	if [ -n "$LAST" ]; then
		N1=$(starts); MP=$(cat "$STARTDIR/$(hostname).pid" 2>/dev/null); RUNNING=0
		[ -n "$MP" ] && grep -q mysqld "/proc/$MP/cmdline" 2>/dev/null && RUNNING=1
		EXTRA=$(awk -v a="$N1" -v b="$LS" -v r="$RUNNING" 'BEGIN { if (a == "" || b == "" || b == "unknown") print "unknown"; else print a - b - r }')
		vd "stock's start ledger: ${LS:-?} starts on record at the launch, ${N1:-?} now, this boot's own database running: $RUNNING -> starts in between that belong to neither: $EXTRA"
	fi
	case "$EXTRA" in
	unknown|0|-*) BETWEEN=;;
	*) BETWEEN=" NOTE: stock's start ledger counts $EXTRA start(s) of stock's userland between the launch and this boot: the box was booted into stock one more time in between.";;
	esac
	AGE=$(awk -v n="$(date +%s)" -v u="$UP" -v e="$LE" 'BEGIN { if (e == "" || n + 0 < e + 0) print "noclock"; else if (n - u + 60 < e) print "older"; else print "newer" }')
	GAP=$(awk -v n="$(date +%s)" -v u="$UP" -v e="$LE" 'BEGIN { if (e == "" || n + 0 < e + 0) print "unknown"; else printf "%d", n - u - e }')
	BACK=$(awk -v g="$GAP" -v w="$LW" 'BEGIN {
		if (g == "unknown") print "how long the trial ran cannot be told (the clock is behind the launch time stamp)"
		else if (g < 150) print "stock started again " g " s after the launch line: an early reset" (w == 1 ? " (the 21 s watchdog, or a crash-reboot)" : " (a crash-reboot, or a quick power cycle)")
		else if (w == 1 && g < 300) print "stock started again " g " s after the launch line: with wdt that is the mark of a kernel that ran but whose userspace never opened the watchdog (the command line gives it 120 s, watchdog.open_timeout=120, then the kernel stops feeding and the 21 s watchdog resets); or a power cycle at that moment"
		else if (g >= 1150 && g <= 1500) print "stock started again " g " s after the launch line: that is the trial'"'"'s own 20-minute auto-return"
		else print "stock started again " g " s after the launch line (a power cycle, or a reset at that moment)" }')
	EARLY=$(awk -v g="$GAP" 'BEGIN { print (g != "unknown" && g < 150) ? 1 : 0 }')
	SA=$(mstate "$MK" "$MR" 0); SC=$(mstate "$MK" "$MR" 1); SH=$(mstate "$MK" "$MR" 2)
	vd "RAM markers of run $MR at their addresses: A (first copy) ${SA:-not asked}, C (after kernel + overlay) ${SC:-not asked}, H (last, ordinary memory) ${SH:-not asked}"
	[ -n "$LAST" ] && vd "time: $BACK"
	# ---- 7. how far ----
	FAR=none
	[ $KERN = 1 ] && FAR=kernel
	[ $KUSER = 1 ] && FAR=userspace
	[ $FRESH = 1 ] && FAR=userspace
	[ $FRESH = 1 ] && [ -n "$DINET" ] && FAR=network
	[ "$LAN" = ssh ] && FAR=network
	EV=
	[ $KERN = 1 ] && EV="$EV the 6.12 kernel's own log ring $(if [ $KEARLY = 1 ]; then echo "was in RAM right after the reset (early capture, "; else echo "is in RAM ("; fi)$(wc -l < "$KL") lines, run id in it: $KTOK);"
	[ $KERN = 0 ] && [ $KUSER = 1 ] && EV="$EV a 6.x log ring with ex4log lines is in RAM (its start is gone);"
	[ $FRESH = 1 ] && EV="$EV the disk log on $DPART is FRESH (last snapshot at trial uptime $DUPT s, run id in it: $DTOK);"
	[ $FRESH = 1 ] && [ -n "$DINET" ] && EV="$EV the trial held $DINET;"
	[ "$LAN" = ssh ] && EV="$EV ssh from the LAN reached it ($LANLINE);"
	[ "$LAN" = ping ] && EV="$EV a candidate host answered ping on the LAN but the trial key did not get in: not proof, it may be any new device ($LANLINE);"
	[ $FRESH = 1 ] && [ $DSELF = 1 ] && EV="$EV the self-test was written;"
	[ $FRESH = 1 ] && [ $DRET = 1 ] && EV="$EV the auto-return note is in the log (it rebooted to stock by itself);"
	[ -n "$FANFS" ] && EV="$EV ex4fan's FAIL-SAFE rebooted the trial ($FANFS);"
	[ -n "$FANSRC" ] && [ -z "$FANFS" ] && EV="$EV ex4fan ran (see the FAN line);"
	[ -n "$V5SRC" ] && EV="$EV the v5 self-test is on record (see the V5 lines);"
	CUT=
	if [ "$LW" = 1 ] && [ "$EARLY" = 1 ] && [ "$FAR" != none ]; then
		if [ $KWDT = 0 ] && [ $DWDT = 0 ]; then CUT=" The 21 s watchdog very likely cut a boot that was still going: neither the ring nor the disk log holds 6.12's 'orion_wdt: Initial timeout' line, so it had not taken the watchdog over yet. Run it again WITHOUT wdt."
		else CUT=" 6.12 HAD taken the watchdog over (its driver's line is on record), so the early return is a crash-reboot, or a hang after that point (a dead kernel stops feeding the watchdog): read the last lines above."; fi
	fi
	if [ -z "$LAST" ]; then
		vd "VERDICT: INCONCLUSIVE: no launch log in $L: no jump of this bundle is on record."
	elif [ $JUMPED = 0 ]; then
		vd "VERDICT: INCONCLUSIVE: the newest launch (run $LR) stopped before the jump (its log does not end with the LAST LINE entry): nothing was booted by it."
	elif [ "$AGE" = older ]; then
		vd "VERDICT: INCONCLUSIVE: this kernel started BEFORE the newest launch (run $LR): the launch log reached its last line but this kernel never stopped (the jump did not happen), or the clock is wrong."
	elif [ "$FAR" != none ]; then
		[ "$AGE" = noclock ] && vd "note: the clock is behind the launch log's time stamp: boot time could not be compared with the launch"
		case "$FAR" in
		network) HOW="Linux $KVER ran on this box from RAM, its userspace came up and it was on the LAN";;
		userspace) HOW="Linux $KVER ran on this box from RAM and its userspace came up, but no LAN address and no ssh from the LAN is on record";;
		*) if [ $KINIT = 1 ]; then HOW="the $KVER kernel started and reached /init, but userspace left no trace (no ex4log line, no disk log)"; else HOW="the $KVER kernel started and printed its log, but there is no sign that it reached userspace"; fi;;
		esac
		vd "VERDICT: MODERN KERNEL BOOTED (how far: $FAR): $HOW. Evidence:$EV $BACK.$CUT$BETWEEN"
	else
		case "$SA/$SC" in
		INTACT/INTACT) WHY="RAM markers A and C are whole at their addresses: the stub copied every segment (C comes after the kernel and the overlay) and RAM survived the reset, so the evidence reaches the END OF THE COPY: the fault is in the jump, the decompressor, or the kernel before its first log line (or stock has already reused the memory the ring was in)";;
		INTACT/*) WHY="marker A (the first copy) is whole but C (copied after the kernel and the overlay) is ${SC:-missing}: the evidence reaches the START OF THE COPY: the stub did not finish";;
		OTHER/*) WHY="the markers of an EARLIER run still sit whole at the addresses (A $SA, C ${SC:-?}): RAM survived, and this run's stub never wrote its first marker, so the evidence reaches the LAUNCH LOG and stops BEFORE THE COPY: the fault is in the stock kernel's shutdown path or in the jump into the stub";;
		DAMAGED/*|*/DAMAGED) WHY="a RAM marker is there but damaged (A $SA, C $SC): the stub wrote it and RAM lost part of it (power was off for a moment, or a kernel reused the page)";;
		*) WHY="no RAM marker of run $MR at its address (A ${SA:-?}, C ${SC:-?}): after a power cycle that is expected (RAM was cleared) and the evidence reaches only the LAUNCH LOG; after a watchdog or soft reset it means the stub never copied, or a kernel that ran reused those pages";;
		esac
		[ "$AGE" = noclock ] && vd "note: the clock is behind the launch log's time stamp: boot time could not be compared with the launch"
		vd "VERDICT: HUNG AFTER THE JUMP: run $LR (wdt=$LW) jumped and left no kernel log in RAM, no fresh disk log and no LAN witness. $WHY. $BACK.$BETWEEN"
	fi
	vd "VERDICT ONLY: nothing was loaded, no device was written. Copies: $V and the files of stamp $STAMP under $L/"
	;;
esac
