#!/bin/sh
# /ex4/restore-stock.sh : put WD's firmware image back into mtd3 ("image"), from a file or from stdin (wget/nc from a LAN
# host). Runs ON the EX4 under WD's own 3.2.40 kernel: in the stage-2 rescue shell, or under a running stock system.
# The one device it can write is TARGET below (mtd3); mtd0/1/2/4/5/6 are never opened for writing.
#
#   sh restore-stock.sh FILE     FILE = the Nov 16 2026 dump mtd3.dd (md5 5b3659fd) or just its first 0x6820000 bytes
#   ... | sh restore-stock.sh -  the same bytes on stdin, e.g. `/ex4/busybox wget -O - http://HOST:PORT/mtd3.dd | sh ...`
#
# What it does (ARMED=1 only; ARMED=0 = every check, nothing written):
#   1. stages the FIRST 0x6820000 bytes (833 blocks) into a tmpfs in RAM and checks their md5 = WD_IMG_MD5. Only those:
#      block 1501 of the dump is the bad block (junk), and `nandwrite -p` skips a bad block and SHIFTS what follows,
#      so writing the whole dump would push that junk into the next good block (MAP-persistent-install.md §4).
#      A wrong input is refused HERE, before anything is erased.
#   2. flash_eraseall TARGET (block 0 first, so the head is 0xFF at once).
#   3. writes blocks 1..832 (nandwrite -p -s 0x20000), reads them back, md5 must match.
#   4. ONLY THEN writes block 0 (the head chk_image reads), reads back all 833 blocks, md5 must be WD_IMG_MD5.
#   Power lost anywhere before step 4 ends = the head stays 0xFF = stage2 v2's belt sends the next boot to rescue,
#   never to WD's chk_image. Run it again from there. It NEVER reboots.
#
# WALL: it refuses unless mtd2 holds stage2 v2 (THE BELT). Under stage2 v1 (or WD's own ramdisk) an erased or half-written
# mtd3 would let chk_image ERASE mtd1 on the next boot (BUILD.md FINDING A).
# WALL 5 (B1 FIX-ubi, Nov 26 2026): it refuses while ANY UBI device is attached to the target (/sys/class/ubi/ubi*/mtd_num) or
# its mtdblock is mounted; checked in walls() and again right before the erase. A live UBI (e.g. left by a failed ex4boot
# mount/copy before rescue) keeps erasing and writing EC headers in the background, which could land inside blocks 1..832
# AFTER the read-back passed. Fix it first: `/ex4/busybox umount /tmp/ex4mnt; /ex4/busybox ubidetach -d N /dev/ubi_ctrl`.
# r4 (Nov 26 2026): this file runs no ubi* tool; only the detach recipe in that line and in wall 5's message gained the REQUIRED
# UBI_CTRL_DEV argument (busybox 1.36.1's ubidetach prints its usage and does nothing without it: C3.md A20 finding).
#
# SHIPPED DISARMED: ARMED=0. Arming = an edit of that line on a copy, made only by the unit's owner, on purpose (the rescue log prints it:
# sed 's/^ARMED=0$/ARMED=1/' /ex4/restore-stock.sh > /tmp/restore-armed.sh).
# TEST MODE: `restore-stock.sh --test-mtd N SRC` (N >= 7, a nandsim/mtdram device, never a name of WD's partitions) writes
# /dev/mtdN instead and skips the mtd2 wall (it does not touch mtd3). Nothing in this file reads an environment variable.
# WALL 6 (r3, Nov 26 2026, the carried B1 nit): it refuses, before staging and before any erase, if ANY block below the one
# that starts at 0x6820000 is bad, i.e. blocks 0..832 (0x6820000 / 0x20000 = 833 exactly; the box: 128 KiB blocks, /proc/mtd).
# `nandwrite -p` skips a bad block and SHIFTS everything after it, so WD's image would land one block off. 3.2.40 has no
# sysfs bad_blocks, so the test is WD's own: stock `nanddump -o -b` (omit OOB, OMIT BAD BLOCKS) of one 2048-byte page per
# block, the exact form chk_image uses on every boot; 2048 bytes out = good, 0 = bad, anything else = cannot prove it good.
# Status Nov 26 2026 (B1): written + exercised only in the off-box harness with fake devices (B1/STAGE2-V2.md). Never ran on the box.
ARMED=0
E=/ex4; DEV=/dev; PROC=/proc; SYS=/sys; TMPD=/tmp
TARGET=$DEV/mtd3; TARGET_NAME=image; TARGET_SIZE=214958080; TEST=0; TNUM=3
BLK=131072; WD_BLOCKS=833; WD_BYTES=109182976                 # 0x6820000
LAST_OFF=109051904                                             # block 832 = 0x6800000, the last block written
WD_IMG_MD5=d3041b697440f096c94d038fa3617b94                    # mtd3.dd bytes 0 .. 0x681ffff
WD_HEAD_BLOCK_MD5=dcad92ea4ee1b16446c45fcd4dda0ca7             # mtd3.dd block 0
WD_TAIL_MD5=ce3b37c3a08bf1387da339b36293450a                   # mtd3.dd blocks 1 .. 832
WANT_VERSION='Linux version 3.2.40 (kman@kmachine) (gcc version 4.6.4 20120731 (prerelease) (Linaro GCC branch-4.6.4. Marvell GCC 201301-1645.aee66e26) ) #1 Fri Nov 16 11:50:03 CST 2018'
STAGE=$TMPD/ex4-restore; IMG=$STAGE/mtd3-first-0x6820000.bin
PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH            # fixed: never the caller's
if [ -x $E/busybox ]; then BB=$E/busybox; else BB=busybox; fi
set -u
say() { echo "restore-stock: $*"; }
die() { echo "restore-stock: REFUSED: $*" >&2; exit 1; }
md5s() { m=$($BB md5sum); m=${m%% *}; echo "$m"; }

if [ "${1:-}" = --test-mtd ]; then
	N=${2:-}; case "$N" in ''|*[!0-9]*|????*) die "--test-mtd needs a small number";; esac
	[ "$N" -ge 7 ] || die "mtd0..mtd6 are the box's own partitions"
	TN=$($BB cat $SYS/class/mtd/mtd$N/name 2>/dev/null)
	case "$TN" in ''|u-boot|uImage|ramdisk|image|"rescue firmware"|config|reserve) die "mtd$N name '$TN' is empty or one of WD's partitions";; esac
	TSZ=$($BB cat $SYS/class/mtd/mtd$N/size 2>/dev/null)
	case "$TSZ" in ''|*[!0-9]*) die "mtd$N has no readable size";; esac
	[ "$TSZ" -ge $WD_BYTES ] || die "mtd$N is $TSZ bytes, smaller than $WD_BYTES"
	TARGET=$DEV/mtd$N; TARGET_NAME=$TN; TEST=1; TNUM=$N; shift 2
fi
SRC=${1:-}
[ $# = 1 ] && [ -n "$SRC" ] || { echo "usage: sh restore-stock.sh [--test-mtd N] FILE|-" >&2; exit 64; }

ubi_wall() {    # 5. nothing holds the target: no UBI device attached to it, its mtdblock not mounted
	[ -d $SYS/class/mtd/mtd$TNUM ] || die "wall 5: $SYS/class/mtd/mtd$TNUM missing (sysfs not mounted?): cannot prove no UBI sits on $TARGET"
	for u in $SYS/class/ubi/ubi*; do
		[ -e "$u/mtd_num" ] || continue                 # volume dirs (ubiN_M) have no mtd_num
		un=$($BB cat "$u/mtd_num" 2>/dev/null)
		case "$un" in ''|*[!0-9]*) die "wall 5: cannot read $u/mtd_num ('$un')";; esac
		[ "$un" != "$TNUM" ] || die "wall 5: $u is attached to $TARGET (a live UBI writes under an erase). First: $BB umount /tmp/ex4mnt; $BB ubidetach -d ${u##*/ubi} $DEV/ubi_ctrl"
	done
	! $BB grep -q "^/dev/mtdblock$TNUM " $PROC/mounts || die "wall 5: /dev/mtdblock$TNUM is mounted"
}

bb_wall() {     # 6. no bad block in blocks 0..832 of the target (r3): one stock `nanddump -o -b` page per block
	ND=$(command -v nanddump 2>/dev/null) || die "wall 6: nanddump (WD's mtd-utils) not found: cannot check bad blocks"
	nanddump --help 2>&1 | $BB grep -q -e '--omitbad' || die "wall 6: $ND is not WD's mtd-utils nanddump (no --omitbad): refusing"
	n=$($BB seq 0 $BLK $LAST_OFF | $BB wc -l); n=$(echo $n)
	[ "$n" = $WD_BLOCKS ] || die "wall 6: seq gave $n block offsets, want $WD_BLOCKS"
	P=$TMPD/ex4-bbprobe
	for off in $($BB seq 0 $BLK $LAST_OFF); do
		$BB rm -f $P
		nanddump -o -b -f $P -s $off -l 2048 $TARGET >/dev/null 2>&1; rc=$?
		n=$($BB wc -c < $P 2>/dev/null); n=$(echo $n)
		[ $rc = 0 ] && [ "$n" = 2048 ] && continue
		$BB rm -f $P
		[ $rc = 0 ] && [ "$n" = 0 ] && die "wall 6: the block at offset $off of $TARGET is BAD (below 0x6820000): nandwrite would shift WD's image. Nothing erased."
		die "wall 6: nanddump at offset $off gave rc $rc and '$n' bytes: cannot prove that block is good. Nothing erased."
	done
	$BB rm -f $P
	say "wall 6 passed: blocks 0..832 of $TARGET are all good ($WD_BLOCKS one-page probes, $ND -o -b)"
}

walls() {
	# 1. the constant: only mtd3 (or, in test mode, a simulated MTD >= 7)
	[ $TEST = 1 ] || [ "$TARGET" = $DEV/mtd3 ] || die "wall 1: TARGET was edited; this tool writes mtd3 only"
	# 2. the exact box and kernel
	[ "$($BB cat $PROC/version)" = "$WANT_VERSION" ] || die "wall 2: not WD firmware 2.12.127's kernel"
	$BB grep -q "Feroceon 88FR131" $PROC/cpuinfo && $BB grep -q DB88FXX81 $PROC/cmdline || die "wall 2: not an EX4"
	$BB grep -q '^mtd3: 0cd00000 00020000 "image"$' $PROC/mtd || die "wall 2: mtd3 is not the 205 MiB 'image' partition"
	# 3. THE BELT is in mtd2 (production only): its gzip payload holds stage2 v2's marker line
	if [ $TEST = 0 ]; then
		MK1="ex4-stage2 belt"; MK2=": wd-md5-v2"       # split so this file does not carry the marker itself
		$BB dd if=$DEV/mtd2 bs=64 skip=1 2>/dev/null | $BB gunzip -c 2>/dev/null | $BB tr '\000' '\n' | $BB grep -q -F "$MK1$MK2" \
			|| die "wall 3: mtd2 does not hold stage2 v2 (the belt). Under v1 an erased mtd3 lets chk_image erase mtd1. Write stage2 v2 first."
	fi
	# 4. the tools
	command -v flash_eraseall >/dev/null 2>&1 || die "wall 4: flash_eraseall (WD's mtd-utils) not found"
	[ -x $E/busybox ] || die "wall 4: $E/busybox (nandwrite, md5sum) missing"
	ubi_wall
	bb_wall
	BAD=$($BB cat $SYS/class/mtd/${TARGET##*/}/bad_blocks 2>/dev/null || echo unknown)
	say "walls passed. target $TARGET ($TARGET_NAME), bad blocks in it: $BAD (the Nov 16 one is block 1501, past the 833 written)"
}

stage() {       # the first WD_BYTES of SRC into RAM; returns only if their md5 is WD's
	$BB mkdir -p $STAGE
	$BB grep -q " $STAGE " $PROC/mounts || $BB mount -t tmpfs -o size=112m tmpfs $STAGE || die "tmpfs on $STAGE failed"
	if [ "$SRC" = "$IMG" ]; then say "using the copy already staged in RAM"
	elif [ "$SRC" = - ]; then $BB head -c $WD_BYTES > $IMG
	else [ -r "$SRC" ] || die "cannot read $SRC"; $BB head -c $WD_BYTES "$SRC" > $IMG
	fi
	n=$($BB wc -c < $IMG); n=$(echo $n)
	[ "$n" = $WD_BYTES ] || die "input gave $n bytes, need $WD_BYTES (nothing erased)"
	GOT=$(md5s < $IMG)
	[ "$GOT" = $WD_IMG_MD5 ] || die "input md5 $GOT is not WD's image $WD_IMG_MD5 (nothing erased)"
	say "input staged in RAM and verified: $WD_BYTES bytes, md5 $GOT"
}

walls
stage
if [ "$ARMED" != 1 ]; then
	say "would: 1) flash_eraseall $TARGET  2) blocks 1..832 -> nandwrite -p -s 0x20000, read back (want $WD_TAIL_MD5)"
	say "       3) block 0 -> nandwrite -p -s 0, read back blocks 0..832 (want $WD_IMG_MD5)  4) never reboot"
	say "ARMED=0. CHECK ONLY: nothing was written. (staged copy left in $IMG; umount $STAGE to free the RAM)"
	exit 0
fi
ubi_wall        # again, right before the erase (staging took a while)
say "POINT OF NO RETURN for $TARGET. The belt in mtd2 keeps a cut here safe (next boot = rescue)."
say "+ flash_eraseall $TARGET"; flash_eraseall $TARGET || die "flash_eraseall failed: mtd3 is partly erased; the next boot goes to rescue. Run again."
H=$($BB dd if=$TARGET bs=2048 count=1 2>/dev/null | md5s)
say "head after erase: $H (0xFF page = e0deebd3c3f560212af17c68b9344bae)"
say "+ blocks 1..832"
$BB dd if=$IMG bs=$BLK skip=1 count=832 2>/dev/null | $BB nandwrite -p -s 0x20000 $TARGET || die "tail write failed: head left erased on purpose (next boot = rescue). Run again."
GOT=$($BB dd if=$TARGET bs=$BLK skip=1 count=832 2>/dev/null | md5s)
[ "$GOT" = $WD_TAIL_MD5 ] || die "tail read-back $GOT != $WD_TAIL_MD5: head left erased on purpose (next boot = rescue). Run again with SRC=$IMG"
say "tail verified ($GOT)"
$BB dd if=$IMG of=$STAGE/head.bin bs=$BLK count=1 2>/dev/null
[ "$(md5s < $STAGE/head.bin)" = $WD_HEAD_BLOCK_MD5 ] || die "staged head block is wrong; head left erased"
say "+ block 0 (the head chk_image reads)"
$BB nandwrite -p -s 0 $TARGET $STAGE/head.bin || die "head write failed: the belt sees a non-WD head (next boot = rescue). Run again."
GOT=$($BB dd if=$TARGET bs=$BLK count=$WD_BLOCKS 2>/dev/null | md5s)
if [ "$GOT" = $WD_IMG_MD5 ]; then
	say "DONE: $TARGET holds WD's image again (first 0x6820000 bytes md5 $GOT). NOT rebooting. Next boot: the belt sees WD -> stock."
	exit 0
fi
echo "restore-stock: full read-back $GOT != $WD_IMG_MD5. The belt will send the next boot to rescue (safe). Run again with SRC=$IMG" >&2
exit 2
