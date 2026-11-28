#!/bin/sh
# /ex4/stage2.sh v2 : the EX4 "second-stage loader" WITH THE BELT. Lives in the ramdisk (mtd2), runs under WD's own 3.2.40
# kernel (mtd1, never rewritten), called from /etc/rc.sh right after mdev, with NO arguments. U-Boot (mtd0) is never touched.
# ex4-stage2 belt: wd-md5-v2
#
# THE BELT (FINALIZE-PLAN B1, G1a): WD's /usr/sbin/chk_image runs right after this script on every boot and ERASES mtd1
# (WD's kernel) when mtd3 is not a valid WD image (BUILD.md FINDING A). So this script hands the boot back to WD (exit 0)
# ONLY when mtd3 POSITIVELY is WD's image:
#   1. its first 2048 bytes (the page chk_image reads: u32 LE length 0x06805000 + u32 LE XOR-of-words 0xd9d7dc5d + zeros)
#      have md5 WD_HEAD_MD5, and
#   2. its first 0x6820000 bytes (833 blocks: the whole image chk_image checksums, plus the 0xFF tail of its last block)
#      have md5 WD_IMG_MD5 (read twice before giving up). Both pins = the Nov 16 2026 dump mtd3.dd (md5 5b3659fd).
# If both hold, chk_image's own checks pass by construction (len <= 0x9600000, checksum != 0, XOR matches: reproduced
# offline on the same bytes, B1/STAGE2-V2.md). Everything else takes OUR branch and never returns:
#   - first 4 bytes "UBI#"                        -> the UBI boot path (v1's contract), every failure there = rescue
#   - erased (0xFF), junk, a read error, a short read, WD's head over a torn/damaged body -> rescue at once
# The UBI path runs in a subshell; whatever ends it (a failure, a crash of the shell, the jump coming back) lands in
# rescue in this shell. There is no `exit 0` anywhere except the WD branch (and the WD branch of test mode).
#
# RESCUE (the owner's ruling, Nov 26 2026: telnet, no password): DHCP on egiga0/egiga1, `telnetd -l /bin/sh -p 23`
# (no password, LAN only, only while in rescue), the restore recipe printed to the log, sleep forever: never WD's init.
#
# TEST MODE (the only way to point this at another MTD): `stage2.sh --test-mtd N`, N >= 7, and /sys/class/mtd/mtdN/name
# not one of WD's seven partition names (a nandsim / mtdram device). A production boot can never set it: rc.sh calls this
# file with no arguments (one fixed line inside the CRC-checked ramdisk), and this file reads NO environment variable
# (every setting below is assigned here, so a kernel-cmdline variable cannot reach it). Test mode never touches the network:
# its "rescue" logs and exits 3.
#
# v2, Nov 26 2026 (FINALIZE-PLAN B1), changes from v1 (8dd6a35c): the belt above; v1's two early `exit 0`s (cmdline lacks
# DB88FXX81, busybox missing) are gone; ADDRS is PARSED (sed), never sourced (a damaged ADDRS sourced with `.` can kill the
# shell = return = chk_image); EXPECT must name seg0, seg1 and seg2 (hex-checked before grep); the tries write is read back;
# rescue mounts devpts if missing and logs the restore recipe; the MTD number is a test-only parameter.
# B1 FIX-ubi (Nov 26 2026): rescue() runs `ubidetach -d $M` first (a failed mount/copy/CRC used to leave ubi$M attached on
# mtd$M while the box sat in rescue, under restore-stock.sh's erase) and logs a WARNING if a UBI device is still on mtd$M.
# r3 (Nov 26 2026, C2/C3 build, the carried B1 nit): rescue's network is rescue_net(): DHCP in up to 6 rounds (each round:
# `udhcpc -n -q -t 4 -T 3` on every port with carrier, else on both; then 3 s), and if no lease, the static fallback
# STATIC_IP/24 (PUBLISHED COPY: set it to a free address on YOUR LAN before building; ours was a private LAN address) on the port with carrier (else egiga0), no gateway: telnet 23 is reachable from the LAN either way.
# Worst case to the fallback: about 90 s with one cabled port, about 160 s when carrier is unknown on both.
# r4 (Nov 26 2026, after C2 failed at A6 on the box): every ubiattach/ubidetach passes the REQUIRED UBI_CTRL_DEV ($DEV/ubi_ctrl;
# busybox 1.36.1's applets refuse without it) and /ex4/busybox is the r4 build whose ubiattach accepts -O (upstream had -O
# only in ubimkvol's getopt string: `ubiattach: invalid option -- 'O'`, C2.md). Nothing else changed.
E=/ex4; DEV=/dev; PROC=/proc; SYS=/sys; TMPD=/tmp
LOG=$E/stage2.log; MNT=$TMPD/ex4mnt; T=$TMPD/ex4boot; HEADF=$E/mtd-head.bin; FAILF=$E/stage2.fail
WD_BLOCKS=833                                     # 0x6820000 bytes = 833 x 128 KiB
WD_HEAD_MD5=112bcdf59b03620f1023f7501ab4bd75      # mtd3.dd bytes 0 .. 0x7ff
WD_IMG_MD5=d3041b697440f096c94d038fa3617b94       # mtd3.dd bytes 0 .. 0x681ffff
FF_HEAD_MD5=e0deebd3c3f560212af17c68b9344bae      # 2048 x 0xff (an erased first page)
M=3; TEST=0
DHCP_ROUNDS="1 2 3 4 5 6"; STATIC_IP=192.0.2.101; STATIC_MASK=255.255.255.0   # rescue network (r3)
if [ -x $E/busybox ]; then BB=$E/busybox; TO="$BB timeout 300"; else BB=busybox; TO=; fi

log() { echo "ex4-stage2: $*" >> $LOG; { echo "ex4-stage2: $*" > $DEV/kmsg; } 2>/dev/null || echo "ex4-stage2: $*" > $DEV/console 2>/dev/null; }

if [ $# -gt 0 ]; then       # never at boot (rc.sh passes nothing)
	[ $# = 2 ] && [ "$1" = --test-mtd ] || { echo "ex4-stage2: usage: stage2.sh [--test-mtd N]  (N >= 7, a simulated MTD)" >&2; exit 64; }
	case "$2" in ''|*[!0-9]*|????*) echo "ex4-stage2: REFUSED: --test-mtd needs a small number" >&2; exit 64;; esac
	[ "$2" -ge 7 ] || { echo "ex4-stage2: REFUSED: mtd0..mtd6 are the box's own partitions" >&2; exit 64; }
	TN=$($BB cat $SYS/class/mtd/mtd$2/name 2>/dev/null)
	case "$TN" in ''|u-boot|uImage|ramdisk|image|"rescue firmware"|config|reserve)
		echo "ex4-stage2: REFUSED: mtd$2 name '$TN' is empty or one of WD's partitions" >&2; exit 64;; esac
	M=$2; TEST=1; log "TEST MODE on mtd$M ($TN)"
fi
MTD=$DEV/mtd$M

carrier() {     # prints the ports whose carrier reads 1 (none = unknown)
	for i in egiga0 egiga1; do [ "$($BB cat $SYS/class/net/$i/carrier 2>/dev/null)" = 1 ] && echo $i; done
}

rescue_net() {  # r3: DHCP until a lease, at most 6 rounds; else the static fallback, so telnet 23 answers either way
	for r in $DHCP_ROUNDS; do
		up=$(carrier)
		for i in ${up:-egiga0 egiga1}; do
			if $BB udhcpc -i $i -n -q -t 4 -T 3 -s $E/udhcpc.script >> $LOG 2>&1; then
				log "rescue: DHCP lease on $i (round $r): $($BB ifconfig $i 2>/dev/null | $BB sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')"
				return 0
			fi
		done
		$BB sleep 3
	done
	si=$(carrier); si=${si%%[!a-z0-9]*}; si=${si:-egiga0}
	$BB ifconfig $si $STATIC_IP netmask $STATIC_MASK up >> $LOG 2>&1
	log "rescue: no DHCP lease in 6 rounds: static fallback $STATIC_IP/24 on $si (no gateway: LAN only)"
}

rescue() {
	log "RESCUE: $1"
	$BB umount $MNT 2>/dev/null
	$BB ubidetach -d $M $DEV/ubi_ctrl >> $LOG 2>&1      # never sit in rescue with a live UBI on mtd$M (B1 FIX-ubi; restore-stock.sh refuses then)
	for u in $SYS/class/ubi/ubi*; do
		[ -e $u/mtd_num ] && [ "$($BB cat $u/mtd_num 2>/dev/null)" = $M ] && log "WARNING: $u is STILL attached to mtd$M (detach failed): restore-stock.sh will refuse until: $BB umount $MNT; $BB ubidetach -d ${u##*/ubi} $DEV/ubi_ctrl"
	done
	if [ $TEST = 1 ]; then log "test mode: network untouched, exit 3"; exit 3; fi
	$BB grep -q ' /dev/pts ' $PROC/mounts 2>/dev/null || { $BB mkdir -p $DEV/pts; $BB mount -t devpts devpts $DEV/pts >> $LOG 2>&1; }
	for i in egiga0 egiga1; do
		$BB ifconfig $i up 2>/dev/null
	done
	$BB sleep 4
	rescue_net
	$BB telnetd -l /bin/sh -p 23
	log "rescue shell: telnet to this box, port 23 (no password, LAN only). Log: $LOG. Tools: $BB (nanddump, nandwrite, ubi*, md5sum, wget, nc)"
	log "put WD back: serve mtd3.dd (or its first 0x6820000 bytes) from a LAN host, then here:"
	log "  $BB sed 's/^ARMED=0\$/ARMED=1/' $E/restore-stock.sh > /tmp/restore-armed.sh"
	log "  $BB wget -O - http://HOST:PORT/mtd3.dd | sh /tmp/restore-armed.sh -     (or: $BB nc HOST PORT | sh /tmp/restore-armed.sh -)"
	log "  (unarmed first, to check the input without writing: ... | sh $E/restore-stock.sh -)   then: reboot"
	while :; do $BB sleep 3600 || sleep 3600; done        # never fall through into WD's init
}

classify() {    # prints exactly one word first: WD | UBI | ERASED | JUNK | READERR | SHORT | WDHEAD-BADBODY
	$BB rm -f $HEADF
	$BB dd if=$MTD of=$HEADF bs=2048 count=1 2>/dev/null || { echo "READERR (head read of $MTD failed)"; return; }
	n=$($BB wc -c < $HEADF 2>/dev/null); n=$(echo $n)
	[ "$n" = 2048 ] || { echo "SHORT (head read gave '$n' bytes)"; return; }
	h=$($BB md5sum < $HEADF); h=${h%% *}
	magic=$($BB dd if=$HEADF bs=4 count=1 2>/dev/null)
	[ "$magic" = "UBI#" ] && { echo UBI; return; }
	[ "$h" = "$FF_HEAD_MD5" ] && { echo "ERASED (first page all 0xFF)"; return; }
	[ "$h" = "$WD_HEAD_MD5" ] || { echo "JUNK (first page md5 $h)"; return; }
	for i in 1 2; do
		b=$($TO $BB dd if=$MTD bs=131072 count=$WD_BLOCKS 2>/dev/null | $BB md5sum); b=${b%% *}
		[ "$b" = "$WD_IMG_MD5" ] && { echo WD; return; }
	done
	echo "WDHEAD-BADBODY (first 0x6820000 bytes md5 $b, want $WD_IMG_MD5: torn restore or damage)"
}

ubi_branch() {  # runs in a subshell; every way out of it ends in rescue in the caller
	fail() { echo "$1" > $FAILF; exit 1; }
	hexval() { $BB sed -n "s/^$1=\(0x[0-9a-fA-F][0-9a-fA-F]*\)\$/\1/p" $T/ADDRS | $BB head -n 1; }
	$BB mkdir -p $MNT $T || fail "mkdir $MNT $T failed"
	$BB ubiattach -m $M -d $M -O 2048 $DEV/ubi_ctrl >> $LOG 2>&1 || fail "ubiattach mtd$M failed"
	$BB sleep 1
	$BB mount -t ubifs ubi$M:ex4boot $MNT >> $LOG 2>&1 || fail "no ex4boot volume"
	[ -e $MNT/rescue ] && fail "rescue requested (file 'rescue' in the ex4boot volume)"
	for f in kernel.bin atags.bin initrd.cpio EXPECT ADDRS; do [ -s $MNT/$f ] || fail "ex4boot volume lacks $f"; done
	TRIES=$($BB cat $MNT/tries 2>/dev/null); case "$TRIES" in ''|*[!0-9]*) TRIES=0;; ???*) TRIES=999;; esac
	[ "$TRIES" -ge 3 ] && fail "3 boot attempts without a good boot (tries=$TRIES)"
	N=$($BB expr "$TRIES" + 1); echo "$N" > $MNT/tries; $BB sync
	[ "$($BB cat $MNT/tries 2>/dev/null)" = "$N" ] || fail "could not record attempt $N in tries"
	$BB cp $MNT/kernel.bin $MNT/atags.bin $MNT/initrd.cpio $MNT/EXPECT $MNT/ADDRS $T/ || fail "copy to RAM failed"
	$BB umount $MNT || fail "umount failed"
	$BB ubidetach -d $M $DEV/ubi_ctrl >> $LOG 2>&1
	KERNEL_ADDR=$(hexval KERNEL_ADDR); ATAGS_ADDR=$(hexval ATAGS_ADDR); INITRD_ADDR=$(hexval INITRD_ADDR)
	ENTRY=$(hexval ENTRY); R2=$(hexval R2)
	[ -n "$KERNEL_ADDR" ] && [ -n "$ATAGS_ADDR" ] && [ -n "$INITRD_ADDR" ] && [ -n "$ENTRY" ] && [ -n "$R2" ] \
		|| fail "ADDRS lacks a 0x-hex KERNEL_ADDR / ATAGS_ADDR / INITRD_ADDR / ENTRY / R2"
	A_MM=$($BB awk '$3=="setup_mm_for_reboot"{print $1}' $PROC/kallsyms)
	A_RP=$($BB awk '$3=="kernel_restart_prepare"{print $1}' $PROC/kallsyms)
	A_PF=$($BB awk '$3=="cpu_feroceon_proc_fin"{print $1}' $PROC/kallsyms)
	[ -n "$A_MM" ] && [ -n "$A_RP" ] && [ -n "$A_PF" ] || fail "kallsyms lacks the functions ex4boot needs"
	$BB insmod $E/ex4boot.ko segs=$T/kernel.bin@$KERNEL_ADDR,$T/atags.bin@$ATAGS_ADDR,$T/initrd.cpio@$INITRD_ADDR \
		entry=$ENTRY r2=$R2 a_setup_mm=0x$A_MM a_restart_prepare=0x$A_RP a_proc_fin=0x$A_PF wdt=1 >> $LOG 2>&1 || fail "insmod ex4boot failed"
	for s in seg0 seg1 seg2; do
		c=$($BB sed -n "s/^$s \([0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]\)\$/\1/p" $T/EXPECT | $BB head -n 1)
		[ -n "$c" ] || { $BB rmmod ex4boot; fail "EXPECT lacks a crc32 line for $s"; }
		$BB grep -q "^$s .* crc32 $c " $PROC/ex4boot || { $BB rmmod ex4boot; fail "$s failed its CRC in RAM"; }
	done
	log "attempt $N: jumping into the modern kernel (watchdog armed)"
	echo boot > $PROC/ex4boot
	fail "the jump returned"
}

V=$(classify)
case "$V" in
WD)	log "mtd3 is WD's stock image (first page + first 0x6820000 bytes = the Nov 16 pins): continuing the stock boot"; exit 0;;
UBI)	log "mtd3 is UBI: taking the ex4boot path on mtd$M";;
*)	rescue "mtd$M is neither WD's image nor UBI: ${V:-classify gave nothing}";;
esac
$BB rm -f $FAILF
( ubi_branch )
RC=$?
R=$($BB cat $FAILF 2>/dev/null)
rescue "${R:-the UBI path ended without a reason (rc $RC)}"
while :; do sleep 3600; done
