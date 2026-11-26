#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# ex4-install.sh : runs ON the WD My Cloud EX4 under its STOCK firmware. Step 1 of the install: put the stage-2
# ramdisk (WD's own ramdisk + /ex4 + one line in rc.sh) into mtd2. It is the ONLY flash write of step 1.
# U-Boot (mtd0), WD's kernel (mtd1) and the identity partition (mtd4) are never opened for writing by this file:
# the one device it can write is the constant TARGET below, and it refuses if that constant is not /dev/mtd2.
#
#   sh ex4-install.sh plan          DEFAULT. Read-only. Runs every refusal wall and prints what `write` would do.
#   sh ex4-install.sh backup DIR    Read-only on flash. Dumps mtd2 (twice, md5 must agree) into DIR on the data disk.
#   sh ex4-install.sh write DIR     Erase + write + read back + compare. Restores the backup by itself if the
#                                   read-back differs. NEVER reboots. REFUSED while ARMED=0 below.
#   sh ex4-install.sh restore DIR   Put DIR/mtd2.backup back (same walls, same read-back). REFUSED while ARMED=0.
#
# SHIPPED DISARMED: ARMED=0. Arming is an edit of this line, made only by the unit's owner, on purpose, after reading
# INSTALL.md, on a unit where the SAME uRamdisk has already booted from RAM (file STAGE2-PROVEN in this folder holds
# its md5: see wall 6). Never write STAGE2-PROVEN by hand for an image you have not booted from RAM yourself.
# Status Nov 26 2026: on the one test unit, `plan` has run (Nov 16 with an older image, Nov 26 with the current one)
# and `write` has run once only to its ARMED=0 refusal. `backup` and `restore` have never run on hardware. Nothing
# here has written flash, anywhere.
ARMED=0
TARGET=/dev/mtd2
TARGET_NAME=ramdisk
TARGET_SIZE=5242880
set -u
D=$(cd "$(dirname "$0")" && pwd)
MODE=${1:-plan}; DIR=${2:-}
IMG="$D/uRamdisk-ex4-stage2"
say() { echo "ex4-install: $*"; }
die() { echo "ex4-install: REFUSED: $*" >&2; exit 1; }
md5of() { m=$(busybox md5sum "$1" | awk '{print $1}'); [ -n "$m" ] || die "md5 of $1 came back empty"; echo "$m"; }
md5dev() { m=$(dd if="$1" bs=131072 2>/dev/null | busybox md5sum | awk '{print $1}'); [ -n "$m" ] || die "md5 of $1 came back empty"; echo "$m"; }
md5head() { m=$(dd if="$1" bs="$2" count=1 2>/dev/null | busybox md5sum | awk '{print $1}'); [ -n "$m" ] || die "md5 came back empty"; echo "$m"; }

WANT_VERSION='Linux version 3.2.40 (kman@kmachine) (gcc version 4.6.4 20120731 (prerelease) (Linaro GCC branch-4.6.4. Marvell GCC 201301-1645.aee66e26) ) #1 Fri Nov 16 11:50:03 CST 2018'
STOCK_UIMAGE_MD5=878ee04b2b17efde852acae0f0e1ff29;   STOCK_UIMAGE_LEN=3459232     # WD 2.12.127 kernel, as shipped
STOCK_URAMDISK_MD5=8006f1d3061c3307704feeb04d3a68e9; STOCK_URAMDISK_LEN=2003252   # WD 2.12.127 ramdisk, as shipped

walls() {
	# 1. the constants: this file can only ever write mtd2
	[ "$TARGET" = /dev/mtd2 ] && [ "$TARGET_NAME" = ramdisk ] || die "wall 1: TARGET was edited; this tool writes /dev/mtd2 only"
	# 2. the exact box and firmware
	[ "$(cat /proc/version)" = "$WANT_VERSION" ] || die "wall 2: not WD firmware 2.12.127's kernel"
	grep -q "Feroceon 88FR131" /proc/cpuinfo && grep -q DB88FXX81 /proc/cmdline || die "wall 2: not an EX4"
	grep -q '^mtd2: 00500000 00020000 "ramdisk"$' /proc/mtd || die "wall 2: mtd2 is not the 5 MiB 'ramdisk' partition"
	grep -q '^mtd0: 00100000 00020000 "u-boot"$' /proc/mtd && grep -q '^mtd4: 00f00000 00020000 "rescue firmware"$' /proc/mtd || die "wall 2: flash layout differs"
	# 3. the kernel in flash is the one U-Boot will pair with our ramdisk
	[ "$(md5head /dev/mtd1 $STOCK_UIMAGE_LEN)" = "$STOCK_UIMAGE_MD5" ] || die "wall 3: mtd1 does not hold WD's 2.12.127 kernel"
	# 4. the image: present, the md5 its sidecar says, a gzip ramdisk uImage, small enough
	[ -s "$IMG" ] && [ -s "$IMG.md5" ] || die "wall 4: $IMG or $IMG.md5 missing"
	IMG_MD5=$(md5of "$IMG"); [ "$IMG_MD5" = "$(awk '{print $1}' "$IMG.md5")" ] || die "wall 4: image md5 differs from its sidecar"
	IMG_SIZE=$(wc -c < "$IMG"); [ "$IMG_SIZE" -gt 1000000 ] && [ "$IMG_SIZE" -le $TARGET_SIZE ] || die "wall 4: image size $IMG_SIZE does not fit"
	[ "$(md5head "$IMG" 4)" = 5f17afccbf287522dacddc0d09e4e03f ] || die "wall 4: not a uImage"      # md5 of the 4 magic bytes 27 05 19 56 (stock has no hexdump/od)
	# 5. no bad block inside mtd2 (nandwrite would shift the data; U-Boot's read would still follow, but refuse anyway)
	BB=$(cat /sys/class/mtd/mtd2/bad_blocks 2>/dev/null || echo unknown)
	[ "$BB" = 0 ] || [ "$BB" = unknown ] || die "wall 5: mtd2 has $BB bad block(s): stop and ask"
	# 6. this exact image has booted on this unit from RAM first
	[ -s "$D/STAGE2-PROVEN" ] && grep -q "^$IMG_MD5\$" "$D/STAGE2-PROVEN" || PROVEN=0
	say "walls 1-5 passed. image $IMG_MD5 ($IMG_SIZE bytes). proven-from-RAM: $([ "${PROVEN:-1}" = 1 ] && echo yes || echo NO)"
}

need_dir() { [ -n "$DIR" ] && [ -d "$DIR" ] || die "give an existing folder on the data disk"; case "$DIR" in /mnt/HD/*) ;; *) die "the folder must be on the data disk (/mnt/HD/...)";; esac; }

do_backup() {
	need_dir
	[ -e "$DIR/mtd2.backup" ] && die "$DIR/mtd2.backup exists (never overwrite a backup)"
	dd if=$TARGET of="$DIR/mtd2.backup" bs=131072 2>/dev/null || die "backup read failed"
	A=$(md5of "$DIR/mtd2.backup"); B=$(md5dev $TARGET)
	[ "$A" = "$B" ] || die "two reads of mtd2 disagree ($A / $B)"
	echo "$A  mtd2.backup" > "$DIR/mtd2.backup.md5"
	say "backup: $DIR/mtd2.backup md5 $A ($(wc -c < "$DIR/mtd2.backup") bytes). Copy it OFF the box before any write."
}

flash() {       # $1 = file to write. erase, write, read back; returns 0 only if flash now holds the file
	F=$1; N=$(wc -c < "$F"); WANT=$(md5of "$F")
	say "+ flash_eraseall $TARGET"; flash_eraseall $TARGET || return 1
	say "+ nandwrite -p $TARGET $F"; nandwrite -p $TARGET "$F" || return 1
	sync
	GOT=$(md5head $TARGET "$N")
	say "read-back md5 $GOT (want $WANT)"
	[ "$GOT" = "$WANT" ]
}

case "$MODE" in
plan)
	walls
	NOW=$(md5head $TARGET $STOCK_URAMDISK_LEN)
	say "mtd2 now: $([ "$NOW" = "$STOCK_URAMDISK_MD5" ] && echo "WD's stock 2.12.127 ramdisk" || echo "NOT the stock ramdisk (md5 $NOW)")"
	say "write would: 1) need DIR/mtd2.backup + its md5 matching flash  2) flash_eraseall $TARGET  3) nandwrite -p $TARGET $IMG"
	say "            4) read back $IMG_SIZE bytes and compare md5  5) on a mismatch: write the backup back and compare again  6) never reboot"
	say "ARMED=$ARMED. PLAN ONLY: nothing was written."
	;;
backup)
	walls; do_backup
	;;
write)
	walls; need_dir
	[ "$ARMED" = 1 ] || die "ARMED=0: this copy cannot write flash. (Arming is the owner's own decision: read INSTALL.md first.)"
	[ "${PROVEN:-1}" = 1 ] || die "wall 6: this image has not been booted from RAM on this unit (no matching line in STAGE2-PROVEN)"
	[ -s "$DIR/mtd2.backup" ] && [ -s "$DIR/mtd2.backup.md5" ] || die "no backup in $DIR (run: backup $DIR)"
	BK=$(md5of "$DIR/mtd2.backup"); [ "$BK" = "$(awk '{print $1}' "$DIR/mtd2.backup.md5")" ] || die "the backup file is damaged"
	[ "$(md5dev $TARGET)" = "$BK" ] || die "flash no longer matches the backup: something else wrote mtd2; back up again"
	[ "$(wc -c < "$DIR/mtd2.backup")" = $TARGET_SIZE ] || die "the backup is not $TARGET_SIZE bytes"
	say "POINT OF NO RETURN for mtd2. Do not cut power for the next minute."
	if flash "$IMG"; then say "DONE: mtd2 holds the stage-2 ramdisk. NOT rebooting. mtd3 is still stock, so the next boot is still WD's system."; exit 0; fi
	say "read-back FAILED: writing the backup back"
	if flash "$DIR/mtd2.backup"; then die "the new image did not verify; the stock ramdisk is back and verified. Nothing changed."; fi
	echo "ex4-install: BOTH writes failed to verify. DO NOT REBOOT OR POWER OFF. The running system is in RAM and can still write flash: get help now." >&2
	exit 2
	;;
restore)
	walls; need_dir
	[ "$ARMED" = 1 ] || die "ARMED=0: this copy cannot write flash. (Arming is the owner's own decision: read INSTALL.md first.)"
	[ -s "$DIR/mtd2.backup" ] && [ "$(md5of "$DIR/mtd2.backup")" = "$(awk '{print $1}' "$DIR/mtd2.backup.md5")" ] || die "no intact backup in $DIR"
	[ "$(wc -c < "$DIR/mtd2.backup")" = $TARGET_SIZE ] || die "the backup is not $TARGET_SIZE bytes"
	if flash "$DIR/mtd2.backup"; then say "DONE: mtd2 is the backup again (verified)."; exit 0; fi
	echo "ex4-install: restore did not verify. DO NOT REBOOT OR POWER OFF. Run it again; if it fails again, get help." >&2
	exit 2
	;;
*)
	echo "usage: sh ex4-install.sh plan | backup DIR | write DIR | restore DIR" >&2; exit 64
	;;
esac
