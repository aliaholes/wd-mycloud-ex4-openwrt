#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# mkstage2.sh : build the stage-2 uRamdisk for mtd2 = WD's own 2.12.127 ramdisk + /ex4 (stage2.sh, ex4boot.ko, a static
# busybox, ex4peek) + ONE added line in /etc/rc.sh. Off the box, no root (debugfs). Never overwrites.
#   sh mkstage2.sh <stock uRamdisk> <stage2 dir> <ex4boot.ko> <busybox static> <ex4peek> <outdir>
# The stock uRamdisk must be WD's 2.12.127 one (md5 8006f1d3061c3307704feeb04d3a68e9), else REFUSED.
# Nov 26 2026 (v1): no mkimage. The uImage header is written by our own ../build/ex4img.py rduimage (same fields
# mkimage -T ramdisk -C gzip writes; proven on WD's own payload: it rebuilds the stock mtd2 header byte for byte),
# with the stock header's own timestamp, so the same inputs give the same image. Needs: debugfs, e2fsck, gzip, python3.
set -eu
STOCK=$1; S2=$2; KO=$3; BB=$4; PK=$5; OUT=$6
EX4IMG=$(cd "$(dirname "$0")/.." && pwd)/build/ex4img.py
[ -s "$EX4IMG" ] || { echo "REFUSED: $EX4IMG not found (run mkstage2.sh from its place in the repo: stage2/, beside build/)" >&2; exit 1; }
[ -e "$OUT" ] && { echo "REFUSED: $OUT exists" >&2; exit 1; }
for f in "$STOCK" "$S2/stage2.sh" "$S2/udhcpc.script" "$KO" "$BB" "$PK"; do [ -s "$f" ] || { echo "REFUSED: input $f is missing or empty" >&2; exit 1; }; done
[ "$(md5sum < "$STOCK" | cut -d' ' -f1)" = 8006f1d3061c3307704feeb04d3a68e9 ] || { echo "REFUSED: not WD's 2.12.127 uRamdisk" >&2; exit 1; }
mkdir -p "$OUT"; W="$OUT/work"; mkdir "$W"
PSZ=$(od -An -tu1 -j12 -N4 "$STOCK" | awk '{print $1*16777216+$2*65536+$3*256+$4}')      # payload size from the uImage header
TS=$(od -An -tx1 -j8 -N4 "$STOCK" | tr -d ' \n'); TS=0x$TS                                    # the stock header's timestamp
tail -c +65 "$STOCK" | head -c "$PSZ" | gunzip > "$W/ramdisk.img"
cp "$W/ramdisk.img" "$W/stock.img"
debugfs -R "cat /etc/rc.sh" "$W/stock.img" 2>/dev/null > "$W/rc.sh.stock"
[ "$(grep -c '^touch /dev/mdev.seq$' "$W/rc.sh.stock")" = 1 ] || { echo "REFUSED: rc.sh anchor line not found exactly once" >&2; exit 1; }
sed 's|^touch /dev/mdev.seq$|touch /dev/mdev.seq\n[ -x /ex4/stage2.sh ] \&\& /ex4/stage2.sh   # EX4 revival: returns at once while mtd3 is stock|' "$W/rc.sh.stock" > "$W/rc.sh.new"
[ "$(diff "$W/rc.sh.stock" "$W/rc.sh.new" | grep -c '^>')" = 1 ] || { echo "REFUSED: rc.sh patch is not exactly one added line" >&2; exit 1; }
sh -n "$S2/stage2.sh"; sh -n "$S2/udhcpc.script"; sh -n "$W/rc.sh.new"
cat > "$W/cmds" <<C
mkdir /ex4
write $S2/stage2.sh /ex4/stage2.sh
write $S2/udhcpc.script /ex4/udhcpc.script
write $KO /ex4/ex4boot.ko
write $BB /ex4/busybox
write $PK /ex4/ex4peek
sif /ex4/stage2.sh mode 0100755
sif /ex4/udhcpc.script mode 0100755
sif /ex4/busybox mode 0100755
sif /ex4/ex4peek mode 0100755
sif /ex4/ex4boot.ko mode 0100644
rm /etc/rc.sh
write $W/rc.sh.new /etc/rc.sh
sif /etc/rc.sh mode 0100755
C
for f in stage2.sh udhcpc.script ex4boot.ko busybox ex4peek; do echo "sif /ex4/$f uid 0" >> "$W/cmds"; echo "sif /ex4/$f gid 0" >> "$W/cmds"; done
printf 'sif /etc/rc.sh uid 0\nsif /etc/rc.sh gid 0\nsif /ex4 uid 0\nsif /ex4 gid 0\n' >> "$W/cmds"
debugfs -w -f "$W/cmds" "$W/ramdisk.img" > "$W/debugfs.log" 2>&1
e2fsck -fn "$W/ramdisk.img" > "$W/e2fsck.log" 2>&1 || { echo "REFUSED: e2fsck is not clean (see $W/e2fsck.log)" >&2; exit 1; }
debugfs -R "cat /etc/rc.sh" "$W/ramdisk.img" 2>/dev/null | cmp - "$W/rc.sh.new"
debugfs -R "cat /ex4/ex4boot.ko" "$W/ramdisk.img" 2>/dev/null | cmp - "$KO"
debugfs -R "cat /ex4/busybox" "$W/ramdisk.img" 2>/dev/null | cmp - "$BB"
[ "$(stat -c %s "$W/ramdisk.img")" = "$(stat -c %s "$W/stock.img")" ] || { echo "REFUSED: image size changed" >&2; exit 1; }
gzip -9n < "$W/ramdisk.img" > "$W/ramdisk.img.gz"
python3 -I "$EX4IMG" rduimage "$W/ramdisk.img.gz" "$OUT/uRamdisk-ex4-stage2" --time "$TS" --load 0x00e00000 --name Ramdisk --max 5242880 > "$W/rduimage.log"
SZ=$(stat -c %s "$OUT/uRamdisk-ex4-stage2")
[ "$SZ" -le 5242880 ] || { echo "REFUSED: $SZ bytes does not fit mtd2 (5 MiB)" >&2; exit 1; }
python3 -I "$EX4IMG" info "$OUT/uRamdisk-ex4-stage2"; md5sum "$OUT/uRamdisk-ex4-stage2"; diff "$W/rc.sh.stock" "$W/rc.sh.new" || true
echo "OK: $SZ bytes of 5242880"
