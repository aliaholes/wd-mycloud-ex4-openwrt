#!/bin/sh
# mkstage2-v2.sh : build the stage-2 v2 uRamdisk for mtd2. = ../mkstage2.sh (a6f7a038, the method that built v1 d2c6d5e6)
# with exactly three changes: (1) ex4img.py is found at ../../build/ex4img.py (this file lives in stage2/v2/, beside build/);
# (2) /ex4/restore-stock.sh is written too (0100755, 0:0) and sh -n checked; (3) stage2.sh and restore-stock.sh are cmp'd
# back out of the image. Everything else (stock ramdisk pin, the ONE rc.sh line, e2fsck, size, rduimage header) is v1's.
#   sh mkstage2-v2.sh <stock uRamdisk> <dir with stage2.sh restore-stock.sh udhcpc.script> <ex4boot.ko> <busybox static> <ex4peek> <outdir>
# Nov 26 2026 (FINALIZE-PLAN B1). Never overwrites. Needs: debugfs, e2fsck, gzip, python3.
set -eu
STOCK=$1; S2=$2; KO=$3; BB=$4; PK=$5; OUT=$6
EX4IMG=$(cd "$(dirname "$0")/../.." && pwd)/build/ex4img.py
[ -s "$EX4IMG" ] || { echo "REFUSED: $EX4IMG not found (run mkstage2-v2.sh from its place in the repo: stage2/v2/)" >&2; exit 1; }
[ -e "$OUT" ] && { echo "REFUSED: $OUT exists" >&2; exit 1; }
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
sh -n "$S2/stage2.sh"; sh -n "$S2/restore-stock.sh"; sh -n "$S2/udhcpc.script"; sh -n "$W/rc.sh.new"
cat > "$W/cmds" <<C
mkdir /ex4
write $S2/stage2.sh /ex4/stage2.sh
write $S2/restore-stock.sh /ex4/restore-stock.sh
write $S2/udhcpc.script /ex4/udhcpc.script
write $KO /ex4/ex4boot.ko
write $BB /ex4/busybox
write $PK /ex4/ex4peek
sif /ex4/stage2.sh mode 0100755
sif /ex4/restore-stock.sh mode 0100755
sif /ex4/udhcpc.script mode 0100755
sif /ex4/busybox mode 0100755
sif /ex4/ex4peek mode 0100755
sif /ex4/ex4boot.ko mode 0100644
rm /etc/rc.sh
write $W/rc.sh.new /etc/rc.sh
sif /etc/rc.sh mode 0100755
C
for f in stage2.sh restore-stock.sh udhcpc.script ex4boot.ko busybox ex4peek; do echo "sif /ex4/$f uid 0" >> "$W/cmds"; echo "sif /ex4/$f gid 0" >> "$W/cmds"; done
printf 'sif /etc/rc.sh uid 0\nsif /etc/rc.sh gid 0\nsif /ex4 uid 0\nsif /ex4 gid 0\n' >> "$W/cmds"
debugfs -w -f "$W/cmds" "$W/ramdisk.img" > "$W/debugfs.log" 2>&1
e2fsck -fn "$W/ramdisk.img" > "$W/e2fsck.log" 2>&1 || { echo "REFUSED: e2fsck is not clean (see $W/e2fsck.log)" >&2; exit 1; }
debugfs -R "cat /etc/rc.sh" "$W/ramdisk.img" 2>/dev/null | cmp - "$W/rc.sh.new"
debugfs -R "cat /ex4/stage2.sh" "$W/ramdisk.img" 2>/dev/null | cmp - "$S2/stage2.sh"
debugfs -R "cat /ex4/restore-stock.sh" "$W/ramdisk.img" 2>/dev/null | cmp - "$S2/restore-stock.sh"
debugfs -R "cat /ex4/ex4boot.ko" "$W/ramdisk.img" 2>/dev/null | cmp - "$KO"
debugfs -R "cat /ex4/busybox" "$W/ramdisk.img" 2>/dev/null | cmp - "$BB"
[ "$(stat -c %s "$W/ramdisk.img")" = "$(stat -c %s "$W/stock.img")" ] || { echo "REFUSED: image size changed" >&2; exit 1; }
gzip -9n < "$W/ramdisk.img" > "$W/ramdisk.img.gz"
python3 -I "$EX4IMG" rduimage "$W/ramdisk.img.gz" "$OUT/uRamdisk-ex4-stage2" --time "$TS" --load 0x00e00000 --name Ramdisk --max 5242880 > "$W/rduimage.log"
SZ=$(stat -c %s "$OUT/uRamdisk-ex4-stage2")
[ "$SZ" -le 5242880 ] || { echo "REFUSED: $SZ bytes does not fit mtd2 (5 MiB)" >&2; exit 1; }
python3 -I "$EX4IMG" info "$OUT/uRamdisk-ex4-stage2"; md5sum "$OUT/uRamdisk-ex4-stage2"; diff "$W/rc.sh.stock" "$W/rc.sh.new" || true
echo "OK: $SZ bytes of 5242880"
