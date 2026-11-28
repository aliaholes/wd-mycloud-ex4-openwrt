#!/bin/sh
# ex4-mtd3.sh : runs ON the WD My Cloud EX4 under its STOCK firmware. Phase D2 of the finalize plan: put OUR UBI image
# (volumes ex4boot + ex4data, made by build/build-mtd3.py) into mtd3, the partition that holds WD's firmware
# image today. It is the ONLY flash write of D2. U-Boot (mtd0), WD's kernel (mtd1), the stage-2 ramdisk (mtd2) and the
# identity partition (mtd4) are only ever READ here: the one device it can write is the constant TARGET below, and
# wall 1 refuses if that constant is not /dev/mtd3.
#
#   sh ex4-mtd3.sh plan          DEFAULT. Read-only. Runs every refusal wall and prints what `write` would do.
#   sh ex4-mtd3.sh backup DIR    Read-only on flash. Reads mtd3 twice (md5s must agree AND equal the Nov 16 dump,
#                                5b3659fd), keeps DIR/mtd3.backup (205 MiB) + DIR/mtd3.head (its first 0x6820000 bytes =
#                                WD's image without the bad-block tail, the only part a restore writes back).
#   sh ex4-mtd3.sh write DIR     Erase mtd3 + nandwrite -p the image + read back the image's length + compare md5.
#                                On a mismatch writes DIR/mtd3.head back and verifies it. NEVER reboots. ARMED=0 refuses.
#   sh ex4-mtd3.sh verify        After a good write, BEFORE any reboot: attach mtd3 (-O 2048), mount both volumes rw
#                                (the first rw mount runs UBIFS's free-space fixup + auto-resize HERE, under stock, with
#                                a person watching, instead of at boot), md5 every ex4boot file vs MANIFEST, tries = 0,
#                                ex4data has /etc/config, then unmount + detach. Writes flash through UBI: ARMED=0 refuses.
#   sh ex4-mtd3.sh restore DIR   Write DIR/mtd3.head back (WD's image) and verify. ARMED=0 refuses.
#
# WHY THE WALLS (phase D2 of the install plan, INSTALL.md):
#  - stage2 v1 (in mtd2 since Nov 26) RETURNS into WD's boot whenever mtd3 is not UBI; WD's chk_image then ERASES mtd1
#    when mtd3 is not a valid WD image (stage2-20261126/BUILD.md FINDING A). A power cut between the erase below and the
#    first UBI header would be exactly that: a dark box. So this tool refuses unless mtd2 already holds stage2 v2 (THE
#    BELT: any mtd3 that is not positively WD's takes our branch, whose every failure is rescue): its md5 + length are
#    pinned in the file STAGE2-V2-IN-MTD2 next to this script, written only after the D1 write read back verified.
#  - the bad block: mtd3-relative block 1501 (0xBBA0000). nandwrite -p skips a bad block and SHIFTS what follows by
#    128 KiB, so the image must end before it, and a restore writes only the first 0x6820000 bytes (WD's data ends at
#    block 832; everything after it in the Nov 16 dump is 0xFF except the bad block itself).
#
# SHIPPED DISARMED: ARMED=0. Arming is an edit of this line, made only by the unit's owner, on purpose (D2 is its own decision), daylight,
# UPS online. Status Nov 26 2026: written + sim-tested off the box; it has
# NEVER run on the EX4. No mode has run there, not even plan.
# r4 (Nov 26 2026, after C2 failed at A6): verify's ubiattach/ubidetach pass UBI_CTRL (/dev/ubi_ctrl), the argument busybox
# 1.36.1's applets REQUIRE (without it they print usage and do nothing), and /ex4/busybox must be the r4 build (its
# ubiattach takes -O; upstream's rejects it: C2.md). Nothing else changed.
# D2 PREP (Nov 27 2026, C4 build lane; DESIGN-C4 cfc3ebd6 §0 FINDING): wall 4 accepted ANY pinned non-v1, non-stock image, so a pin
# naming stage2 v2 r2 (22d8fea5) or r3 (28f71fd1) passed, and their busybox ubiattach rejects -O (C2 A6): every boot after D2 would go
# to rescue. Wall 4 now accepts ONLY an image on the S2_UBI_PROVEN list (md5:length; today r4 d65082b2, the image whose UBI branch
# r4 + r4b PROVED), refuses r2 + r3 by name, and wants that image's PROVEN marker (STAGE2-V2-PROVEN-<first 8 of its md5>, line 1 = the
# full md5) beside this script. Adding an image to the list = an edit of that one line, after its marker exists. Nothing else changed.
ARMED=0
TARGET=/dev/mtd3
TARGET_NAME=image
MTD2=/dev/mtd2
MTD1=/dev/mtd1
PROC=/proc
SYS=/sys
UBI_CTRL=/dev/ubi_ctrl
MNTBASE=/tmp
set -u
D=$(cd "$(dirname "$0")" && pwd)
MODE=${1:-plan}; DIR=${2:-}
IMG="$D/mtd3.ubi"
PIN2="$D/STAGE2-V2-IN-MTD2"
BLK=131072
say() { echo "ex4-mtd3: $*"; }
die() { echo "ex4-mtd3: REFUSED: $*" >&2; exit 1; }
md5of() { m=$(busybox md5sum "$1" | awk '{print $1}'); [ -n "$m" ] || die "md5 of $1 came back empty"; echo "$m"; }
md5dev() { m=$(dd if="$1" bs=$BLK 2>/dev/null | busybox md5sum | awk '{print $1}'); [ -n "$m" ] || die "md5 of $1 came back empty"; echo "$m"; }
md5blk() { m=$(dd if="$1" bs=$BLK count="$2" 2>/dev/null | busybox md5sum | awk '{print $1}'); [ -n "$m" ] || die "md5 came back empty"; echo "$m"; }
md5head() { m=$(dd if="$1" bs="$2" count=1 2>/dev/null | busybox md5sum | awk '{print $1}'); [ -n "$m" ] || die "md5 came back empty"; echo "$m"; }

WANT_VERSION='Linux version 3.2.40 (kman@kmachine) (gcc version 4.6.4 20120731 (prerelease) (Linaro GCC branch-4.6.4. Marvell GCC 201301-1645.aee66e26) ) #1 Fri Nov 16 11:50:03 CST 2018'
STOCK_UIMAGE_MD5=878ee04b2b17efde852acae0f0e1ff29;   STOCK_UIMAGE_LEN=3459232     # WD 2.12.127 kernel, as shipped
STOCK_URAMDISK_MD5=8006f1d3061c3307704feeb04d3a68e9; STOCK_URAMDISK_LEN=2003252   # WD 2.12.127 ramdisk (no belt)
S2V1_MD5=d2c6d5e629e105feab45725ffa3611bf;          S2V1_LEN=3413669             # stage2 v1 (no belt): refused by name
S2R2_MD5=22d8fea57c4827fcadcf51be3dd2b76b; S2R3_MD5=28f71fd15f293942071ee2dfcb356b65  # stage2 v2 r2 / r3: busybox rejects -O: refused by name
S2_UBI_PROVEN="d65082b20d13970bdb20e6dfe68103ff:3421663"                          # md5:length of each stage2 v2 whose UBI branch is PROVEN (r4)
MTD3_SIZE=214958080                                                               # 1640 blocks of 128 KiB
DUMP_MD5=5b3659fd07a307af86316385abc4878b                                         # OUR unit's Nov 16 2026 mtd3 dump (yours may differ: then this tool refuses until you pin your own)
HEAD_LEN=109182976; HEAD_BLKS=833; HEAD_MD5=d3041b697440f096c94d038fa3617b94      # its first 0x6820000 bytes (blocks 0..832)
WD_BLK0_MD5=dcad92ea4ee1b16446c45fcd4dda0ca7                                      # its first block (starts 00 50 80 06 5d dc d7 d9)
UBI_MAGIC_MD5=4ada0680313a5de5a5b78678aa9e5928                                    # md5 of the 4 bytes "UBI#" (stock has no od)
BAD_BLK=1501                                                                      # the image must end before this block

walls() {      # $1 = restore: skip walls 4-5 (putting WD's image back needs neither the belt nor our image)
	LEVEL=${1:-full}
	# 1. the constants: this file can only ever write mtd3, and reads the real kernel interfaces
	[ "$TARGET" = /dev/mtd3 ] && [ "$TARGET_NAME" = image ] && [ "$MTD2" = /dev/mtd2 ] && [ "$MTD1" = /dev/mtd1 ] \
		&& [ "$PROC" = /proc ] && [ "$SYS" = /sys ] || die "wall 1: a constant was edited; this tool writes /dev/mtd3 only"
	# 2. the exact box, firmware and flash layout
	[ "$(cat $PROC/version)" = "$WANT_VERSION" ] || die "wall 2: not WD firmware 2.12.127's kernel"
	grep -q "Feroceon 88FR131" $PROC/cpuinfo && grep -q DB88FXX81 $PROC/cmdline || die "wall 2: not an EX4"
	grep -q '^mtd3: 0cd00000 00020000 "image"$' $PROC/mtd || die "wall 2: mtd3 is not the 205 MiB 'image' partition"
	grep -q '^mtd2: 00500000 00020000 "ramdisk"$' $PROC/mtd && grep -q '^mtd1: 00500000 00020000 "uImage"$' $PROC/mtd \
		&& grep -q '^mtd0: 00100000 00020000 "u-boot"$' $PROC/mtd && grep -q '^mtd4: 00f00000 00020000 "rescue firmware"$' $PROC/mtd \
		|| die "wall 2: flash layout differs"
	# 3. WD's kernel is in mtd1 (the thing chk_image would erase; also what U-Boot pairs with the ramdisk)
	[ "$(md5head $MTD1 $STOCK_UIMAGE_LEN)" = "$STOCK_UIMAGE_MD5" ] || die "wall 3: mtd1 does not hold WD's 2.12.127 kernel"
	[ "$LEVEL" = restore ] || walls45
	walls67
}

walls45() {
	# 4. THE BELT: stage2 v2 is in mtd2 (pinned md5 + length, written after the D1 read-back), never v1 or stock
	[ -s "$PIN2" ] || die "wall 4: no $PIN2 (stage2 v2 must be in mtd2 and pinned before mtd3 can change)"
	P2_MD5=$(awk 'NR==1{print $1}' "$PIN2"); P2_LEN=$(awk 'NR==1{print $2}' "$PIN2")
	case "$P2_MD5" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *) die "wall 4: $PIN2 line 1 is not 'md5 length'";; esac
	case "$P2_LEN" in ''|*[!0-9]*) die "wall 4: $PIN2 line 1 is not 'md5 length'";; esac
	echo "$P2_MD5" | grep -q '^[0-9a-f]\{32\}$' || die "wall 4: the pinned md5 is not 32 hex digits"
	[ "$P2_MD5" != "$S2V1_MD5" ] && [ "$P2_MD5" != "$STOCK_URAMDISK_MD5" ] || die "wall 4: the pin names stage2 v1 or the stock ramdisk: neither has the belt"
	[ "$P2_LEN" -gt 1000000 ] && [ "$P2_LEN" -le 5242880 ] || die "wall 4: pinned length $P2_LEN does not fit mtd2"
	[ "$P2_MD5" != "$S2R2_MD5" ] && [ "$P2_MD5" != "$S2R3_MD5" ] || die "wall 4: the pin names stage2 v2 r2 or r3: their busybox ubiattach rejects -O (C2 A6), so every boot after this write would go to rescue"
	S2OK=0; for e in $S2_UBI_PROVEN; do [ "$e" = "$P2_MD5:$P2_LEN" ] && S2OK=1; done
	[ $S2OK = 1 ] || die "wall 4: the pin $P2_MD5 ($P2_LEN bytes) is not a stage2 v2 whose UBI branch is PROVEN (allowed: $S2_UBI_PROVEN)"
	MARK="$D/STAGE2-V2-PROVEN-$(echo "$P2_MD5" | awk '{print substr($0, 1, 8)}')"
	[ -s "$MARK" ] && [ "$(awk 'NR==1' "$MARK")" = "$P2_MD5" ] || die "wall 4: no PROVEN marker $MARK whose first line is $P2_MD5 beside this script"
	[ "$(md5head $MTD2 $S2V1_LEN)" != "$S2V1_MD5" ] || die "wall 4: mtd2 still holds stage2 v1 (no belt): write stage2 v2 first (phase D1)"
	[ "$(md5head $MTD2 $P2_LEN)" = "$P2_MD5" ] || die "wall 4: mtd2 does not hold the pinned stage2 v2 ($P2_MD5, $P2_LEN bytes)"
	# 5. the image: present, its sidecar md5, UBI, whole 128 KiB blocks, ends before the bad block
	[ -s "$IMG" ] && [ -s "$IMG.md5" ] && [ -s "$D/MANIFEST" ] || die "wall 5: $IMG, $IMG.md5 or $D/MANIFEST missing"
	IMG_MD5=$(md5of "$IMG"); [ "$IMG_MD5" = "$(awk '{print $1}' "$IMG.md5")" ] || die "wall 5: image md5 differs from its sidecar"
	IMG_SIZE=$(wc -c < "$IMG")
	[ "$(expr "$IMG_SIZE" % $BLK)" = 0 ] || die "wall 5: image size $IMG_SIZE is not whole 128 KiB blocks"
	IMG_BLKS=$(expr "$IMG_SIZE" / $BLK)
	[ "$IMG_BLKS" -ge 8 ] && [ "$IMG_BLKS" -lt $BAD_BLK ] || die "wall 5: image is $IMG_BLKS blocks: it must end before bad block $BAD_BLK"
	[ "$(md5head "$IMG" 4)" = "$UBI_MAGIC_MD5" ] || die "wall 5: the image does not start with 'UBI#'"
}

walls67() {
	# 6. nothing else holds mtd3: no UBI device on it, no mount of its block device; bad blocks = the known one only
	for u in $SYS/class/ubi/ubi*; do
		[ -e "$u/mtd_num" ] || continue
		[ "$(cat "$u/mtd_num")" != 3 ] || die "wall 6: $u is attached to mtd3 (ubidetach it first)"
	done
	! grep -q 'mtdblock3' $PROC/mounts || die "wall 6: mtd3's block device is mounted"
	BB=$(cat $SYS/class/mtd/mtd3/bad_blocks 2>/dev/null || echo unknown)
	[ "$BB" = 1 ] || [ "$BB" = unknown ] || die "wall 6: mtd3 has $BB bad block(s), the records say 1 (block $BAD_BLK): stop and ask"
	# 7. what mtd3 holds now (a read of the first block only)
	B0=$(md5blk $TARGET 1); H4=$(md5head $TARGET 4)
	if [ "$B0" = "$WD_BLK0_MD5" ]; then NOW=wd; elif [ "$H4" = "$UBI_MAGIC_MD5" ]; then NOW=ubi; else NOW=other; fi
	if [ "$LEVEL" = restore ]; then say "walls 1-3 + 6 passed (restore level). mtd3 now: $NOW"
	else say "walls 1-6 passed. stage2 v2 $P2_MD5 in mtd2. image $IMG_MD5 ($IMG_SIZE bytes, $IMG_BLKS blocks). mtd3 now: $NOW"; fi
}

need_dir() { [ -n "$DIR" ] && [ -d "$DIR" ] || die "give an existing folder on the data disk"; case "$DIR" in /mnt/HD/*) ;; *) die "the folder must be on the data disk (/mnt/HD/...)";; esac; }

backup_ok() {   # the backup files are whole and are the Nov 16 dump
	[ -s "$DIR/mtd3.backup" ] && [ -s "$DIR/mtd3.head" ] || die "no backup in $DIR (run: backup $DIR)"
	[ "$(wc -c < "$DIR/mtd3.backup")" = $MTD3_SIZE ] && [ "$(md5of "$DIR/mtd3.backup")" = $DUMP_MD5 ] || die "$DIR/mtd3.backup is not the Nov 16 dump ($DUMP_MD5)"
	[ "$(wc -c < "$DIR/mtd3.head")" = $HEAD_LEN ] && [ "$(md5of "$DIR/mtd3.head")" = $HEAD_MD5 ] || die "$DIR/mtd3.head is not the dump's first 0x6820000 bytes ($HEAD_MD5)"
}

do_backup() {
	need_dir
	[ "$NOW" = wd ] || die "mtd3 does not start with WD's image: nothing to back up (your off-box dump is the copy)"
	if [ -e "$DIR/mtd3.backup" ] || [ -e "$DIR/mtd3.head" ]; then die "a backup exists in $DIR (never overwrite a backup)"; fi
	dd if=$TARGET of="$DIR/mtd3.backup" bs=$BLK 2>/dev/null || die "backup read failed"
	A=$(md5of "$DIR/mtd3.backup"); B=$(md5dev $TARGET)
	[ "$A" = "$B" ] || die "two reads of mtd3 disagree ($A / $B)"
	[ "$A" = $DUMP_MD5 ] || die "mtd3 reads $A, not the Nov 16 dump $DUMP_MD5: stop and ask"
	dd if="$DIR/mtd3.backup" of="$DIR/mtd3.head" bs=$BLK count=$HEAD_BLKS 2>/dev/null || die "head copy failed"
	[ "$(md5of "$DIR/mtd3.head")" = $HEAD_MD5 ] || die "mtd3.head is not $HEAD_MD5"
	echo "$A  mtd3.backup" > "$DIR/mtd3.backup.md5"; echo "$HEAD_MD5  mtd3.head" > "$DIR/mtd3.head.md5"
	say "backup: $DIR/mtd3.backup md5 $A ($MTD3_SIZE bytes) = the Nov 16 dump; $DIR/mtd3.head md5 $HEAD_MD5 ($HEAD_LEN bytes)."
}

flash() {       # $1 = file, $2 = its length in blocks, $3 = its md5. erase, write, read back; 0 only if flash now holds it
	F=$1
	say "+ flash_eraseall $TARGET"; flash_eraseall $TARGET || return 1
	say "+ nandwrite -p $TARGET $F"; nandwrite -p $TARGET "$F" || return 1
	sync
	GOT=$(md5blk $TARGET "$2")
	say "read-back md5 of $2 blocks: $GOT (want $3)"
	[ "$GOT" = "$3" ]
}

put_back() {    # the restore path: WD's image (first 0x6820000 bytes) back, verified
	flash "$DIR/mtd3.head" $HEAD_BLKS $HEAD_MD5 || return 1
	FULL=$(md5dev $TARGET)
	say "whole mtd3 now md5 $FULL ($([ "$FULL" = $DUMP_MD5 ] && echo "= the Nov 16 dump" || echo "differs from the dump past the head: expected only if the bad block now reads differently"))"
	return 0
}

case "$MODE" in
plan)
	walls
	say "write would: 1) need DIR/mtd3.backup (= $DUMP_MD5) + DIR/mtd3.head (= $HEAD_MD5) and mtd3 still = the backup"
	say "            2) flash_eraseall $TARGET  3) nandwrite -p $TARGET $IMG  4) read back $IMG_BLKS blocks and compare md5"
	say "            5) on a mismatch: write DIR/mtd3.head back and compare again  6) never reboot; then: verify, then the owner's reboot"
	say "ARMED=$ARMED. PLAN ONLY: nothing was written."
	;;
backup)
	walls; do_backup
	;;
write)
	walls; need_dir
	[ "$ARMED" = 1 ] || die "ARMED=0: this copy cannot write flash. (Arming is the owner's own decision: read INSTALL.md first.)"
	[ "$NOW" = wd ] || die "mtd3 does not start with WD's image (now: $NOW): a write starts only from stock (restore first)"
	backup_ok
	[ "$(md5dev $TARGET)" = $DUMP_MD5 ] || die "mtd3 no longer reads as the backup: something else wrote it; stop and ask"
	say "POINT OF NO RETURN for mtd3. Do not cut power for the next few minutes (the belt in mtd2 makes a cut a rescue boot, not a dark box)."
	if flash "$IMG" "$IMG_BLKS" "$IMG_MD5"; then
		say "DONE: mtd3 holds the UBI image (verified raw). NOT rebooting. Next: sh $0 verify (before any reboot)."; exit 0
	fi
	say "read-back FAILED: writing WD's image back"
	if put_back; then die "the new image did not verify; WD's image is back and verified. Nothing changed."; fi
	echo "ex4-mtd3: BOTH writes failed to verify. DO NOT REBOOT OR POWER OFF. The running system is in RAM and can still write flash: run restore again, then get help." >&2
	exit 2
	;;
verify)
	walls
	[ "$ARMED" = 1 ] || die "ARMED=0: verify attaches UBI and mounts rw (UBI writes flash). (Arming is the owner's own decision: read INSTALL.md first.)"
	[ "$NOW" = ubi ] || die "mtd3 does not start with 'UBI#' (now: $NOW)"
	[ ! -e $SYS/class/ubi/ubi3 ] || die "ubi3 is in use"
	if [ -x /ex4/busybox ]; then UA="/ex4/busybox ubiattach"; UD="/ex4/busybox ubidetach"; else UA=ubiattach; UD=ubidetach; fi
	M=$MNTBASE/ex4mtd3-verify; mkdir -p $M/boot $M/data || die "cannot make $M"
	fail() { umount $M/boot 2>/dev/null; umount $M/data 2>/dev/null; $UD -d 3 $UBI_CTRL 2>/dev/null
		echo "ex4-mtd3: VERIFY FAILED: $1. DO NOT REBOOT: run restore DIR (WD's image back), then look." >&2; exit 1; }
	say "+ $UA -m 3 -d 3 -O 2048 $UBI_CTRL"; $UA -m 3 -d 3 -O 2048 $UBI_CTRL || fail "ubiattach"
	sleep 1
	say "+ mount -t ubifs ubi3:ex4boot $M/boot (rw: the free-space fixup + resize run now)"
	mount -t ubifs ubi3:ex4boot $M/boot || fail "mount ex4boot"
	while read -r want name; do
		[ -s "$M/boot/$name" ] || fail "ex4boot lacks $name"
		got=$(md5of "$M/boot/$name"); [ "$got" = "$want" ] || fail "$name md5 $got, MANIFEST says $want"
		say "ok $name $got"
	done < "$D/MANIFEST"
	for f in kernel.bin atags.bin initrd.cpio EXPECT ADDRS; do grep -q "  $f\$" "$D/MANIFEST" || fail "MANIFEST lacks $f"; done
	[ "$(cat $M/boot/tries)" = 0 ] || fail "tries is not 0"
	umount $M/boot || fail "umount ex4boot"
	mount -t ubifs ubi3:ex4data $M/data || fail "mount ex4data"
	[ -d $M/data/etc/config ] || fail "ex4data lacks /etc/config"
	umount $M/data || fail "umount ex4data"
	$UD -d 3 $UBI_CTRL || fail "ubidetach"
	say "VERIFIED: both volumes mount under WD's 3.2.40, every ex4boot file = MANIFEST, tries 0. NOT rebooting (the owner reboots)."
	;;
restore)
	walls restore; need_dir
	[ "$ARMED" = 1 ] || die "ARMED=0: this copy cannot write flash. (Arming is the owner's own decision: read INSTALL.md first.)"
	backup_ok
	if put_back; then say "DONE: mtd3 is WD's image again (first 0x6820000 bytes verified)."; exit 0; fi
	echo "ex4-mtd3: restore did not verify. DO NOT REBOOT OR POWER OFF. Run it again; if it fails again, get help." >&2
	exit 2
	;;
*)
	echo "usage: sh ex4-mtd3.sh plan | backup DIR | write DIR | verify | restore DIR" >&2; exit 64
	;;
esac
