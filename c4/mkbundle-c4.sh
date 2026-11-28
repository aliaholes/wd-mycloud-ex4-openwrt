#!/bin/sh
# mkbundle-c4.sh (FINALIZE C4, K4, Nov 27 2026): a C4 RAM-trial bundle, "the bwud way" (DESIGN-C4.md cfc3ebd6 §3 K4): the bwud
# bundle-v9 RUN 20 booted (MD5SUMS 1c26b15a, run 20-l2off-20261118-1720-ud), with ONE payload change: overlay.cpio = a C4 TEST
# overlay from mkc4overlay.py. The run id, the trial ATAGs (cmdline = build-v9.sh's cmdline_of: console + watchdog.open_timeout=120 +
# ex4boot_run=<run id>; INITRD2 = 0x4000000 + the overlay's size), the three RAM markers, SEGS (bwud's six, same order + addresses),
# EXPECT, PROVENANCE and MD5SUMS are made again exactly as build-v9.sh's bundle stage makes them (lines 800-851), with bwud's own
# ex4img.py (fb8c640e). Every other file is copied from the base and must keep its base md5 (checked twice).
#   sh mkbundle-c4.sh <bwud bundle-v9 dir> <C4 overlay.cpio> <overlay md5> <ex4img.py> <tag: c4a|c4b|c4c|c4d> <outdir> [stamp]
# THE C4 KERNEL WALL (DESIGN-C4 §2): kernel.bin must be 988b393f (zImage + the TRIAL DTB: all 7 real partitions read-only); any
# other kernel.bin (persist-v1's c4bea1be = the INSTALL DTB, mtd3 writable) is REFUSED. Never overwrites; writes only <outdir>,
# which must be new and under ~/ex4-build/finalize/c4/. Touches no device.
set -eu
BASE=$1; OV=$2; OVMD5=$3; IMG=$4; TAG=$5; OUT=$6; STAMP=${7:-$(date +%Y%m%d-%H%M)}
case "$OUT" in "$HOME"/ex4-build/finalize/c4/*) ;; *) echo "REFUSED: $OUT is not under ~/ex4-build/finalize/c4/" >&2; exit 1;; esac
[ -e "$OUT" ] && { echo "REFUSED: $OUT exists" >&2; exit 1; }
case "$TAG" in c4a|c4b|c4c|c4d) ;; *) echo "REFUSED: tag $TAG is not c4a|c4b|c4c|c4d" >&2; exit 1;; esac
m5() { md5sum < "$1" | cut -d' ' -f1; }
[ "$(m5 "$BASE/MD5SUMS")" = 1c26b15a3d9abfa761b2845bb6273902 ] || { echo "REFUSED: $BASE/MD5SUMS is not bwud bundle-v9's (1c26b15a)" >&2; exit 1; }
( cd "$BASE" && md5sum -c --quiet MD5SUMS ) || { echo "REFUSED: the base bundle fails its own MD5SUMS" >&2; exit 1; }
[ "$(m5 "$BASE/kernel.bin")" = 988b393f878f4595be3725b33b8bbe46 ] || { echo "REFUSED: THE C4 KERNEL WALL: kernel.bin is not 988b393f (the trial DTB)" >&2; exit 1; }
[ "$(cat "$BASE/RUNID")" = 20-l2off-20261118-1720-ud ] || { echo "REFUSED: base run id is not bwud RUN 20's" >&2; exit 1; }
[ "$(m5 "$IMG")" = fb8c640ebf9f9893bfde826f18a0027f ] || { echo "REFUSED: $IMG is not bwud's ex4img.py (fb8c640e)" >&2; exit 1; }
[ "$(m5 "$OV")" = "$OVMD5" ] || { echo "REFUSED: overlay md5 $(m5 "$OV") != $OVMD5" >&2; exit 1; }
[ "$OVMD5" != 85f498e529124931415c745e774e5e90 ] || { echo "REFUSED: that is persist-v1's PRODUCTION overlay: a C4 bundle carries a C4 TEST overlay" >&2; exit 1; }
[ "$OVMD5" != 59abc8d7fae394e295481a7d4ae51105 ] || { echo "REFUSED: that is bwud's own trial overlay" >&2; exit 1; }
COPY="ex4boot-l2off.ko ex4peek ex4log ex4fan KMODS.txt kernel.bin CFG LOGCFG VARIANT ex4-trial.sh"
mkdir -p "$OUT"
for f in $COPY; do cp -p "$BASE/$f" "$OUT/$f"; done
cp "$OV" "$OUT/overlay.cpio"
KERNEL_ADDR=0x8000; ATAGS_ADDR=0x100; INITRD_ADDR=0x4000000; MARK_A=0x1000; MARK_C=0x3000; MARK_H=0x3000000
RUN="$TAG-l2off-$STAMP-ud"; printf '%s\n' "$RUN" > "$OUT/RUNID"
SZ=$(stat -c %s "$OUT/overlay.cpio")
CMD="console=ttyS0,115200n8 watchdog.open_timeout=120 ex4boot_run=$RUN"            # build-v9.sh cmdline_of (ARGX empty for bwud)
py() { python3 -I "$@"; }
py "$IMG" atags "$OUT/atags.bin" --mem 512 --initrd "$INITRD_ADDR,$SZ" --cmdline "$CMD" > "$OUT/atags.log"
py "$IMG" atags-parse "$OUT/atags.bin" --expect-token "ex4boot_run=$RUN" --expect-initrd "$INITRD_ADDR,$SZ" --max-end "$MARK_A" >> "$OUT/atags.log"
py "$IMG" marker "$OUT/markA.bin" --run "$RUN" --pos 0 --total 3 --dest $MARK_A >> "$OUT/atags.log"
py "$IMG" marker "$OUT/markC.bin" --run "$RUN" --pos 1 --total 3 --dest $MARK_C >> "$OUT/atags.log"
py "$IMG" marker "$OUT/markH.bin" --run "$RUN" --pos 2 --total 3 --dest $MARK_H >> "$OUT/atags.log"
printf '%s %s\n' markA.bin $MARK_A kernel.bin $KERNEL_ADDR atags.bin $ATAGS_ADDR overlay.cpio $INITRD_ADDR markC.bin $MARK_C markH.bin $MARK_H > "$OUT/SEGS"
cmp -s "$OUT/SEGS" "$BASE/SEGS" || { echo "REFUSED: SEGS differs from bwud's (names, order, addresses)" >&2; exit 1; }
( cd "$OUT" && py "$IMG" layout SEGS ) > "$OUT/layout.log" || { cat "$OUT/layout.log" >&2; echo "REFUSED: layout" >&2; exit 1; }
n=0; : > "$OUT/EXPECT"
while read -r f a; do
	echo "seg$n $(py -c 'import sys,zlib;print("%08x"%(zlib.crc32(open(sys.argv[1],"rb").read())&0xffffffff))' "$OUT/$f")" >> "$OUT/EXPECT"; n=$((n + 1))
done < "$OUT/SEGS"
[ $n = 6 ] || { echo "REFUSED: $n segments, want 6 (ex4boot MAXSEG 6)" >&2; exit 1; }
[ "$(sed -n 2p "$OUT/EXPECT")" = "$(sed -n 2p "$BASE/EXPECT")" ] || { echo "REFUSED: seg1 (kernel.bin) CRC differs from bwud's" >&2; exit 1; }
LOADED=$(py -c 'import os,sys; b=sys.argv[1]; print(sum(os.path.getsize(os.path.join(b,l.split()[0])) for l in open(os.path.join(b,"SEGS"))))' "$OUT")
CHUNKS=$(py -c 'import os,sys; b=sys.argv[1]; print(sum(-(-os.path.getsize(os.path.join(b,l.split()[0])) // 32768) for l in open(os.path.join(b,"SEGS"))))' "$OUT")
# ex4boot_main.c:292 maxent = (PAGE_SIZE 32768 - CTL_OFF 1024 - sizeof(struct ctl) 16) / sizeof(struct ent) 12 = 2644; :169 refuses at nent + 1 >= maxent
[ "$CHUNKS" -lt 2643 ] || { echo "REFUSED: $CHUNKS loader chunks: ex4boot's control page holds at most 2642" >&2; exit 1; }
{ echo "EX4 C4 RAM-trial bundle $TAG (FINALIZE C4, NEVER flashed), built $(date '+%F %T %Z') by c4/mkbundle-c4.sh $(m5 "$0"), run id $RUN"
  echo "base: bwud bundle-v9 (RUN 20, MD5SUMS 1c26b15a, run 20-l2off-20261118-1720-ud); kernel.bin 988b393f = k-ud zImage 63329ccb + ex4-trial.dtb 8b1ebc0b (every real partition read-only)"
  echo "overlay.cpio = C4 TEST overlay $OVMD5 ($SZ B; c4/mkc4overlay.py over persist-v1 85f498e5): see its OVERLAY-DIFF-C4.txt"
  echo "cmdline: $CMD ; INITRD2 $INITRD_ADDR + $SZ"
  echo "loaded into stock's RAM by the loader: $LOADED bytes in $CHUNKS chunks of 32 KiB (ex4boot's control page holds 2642)"
} > "$OUT/PROVENANCE"
( cd "$OUT" && md5sum ex4boot-l2off.ko ex4peek ex4log ex4fan KMODS.txt kernel.bin overlay.cpio atags.bin markA.bin markC.bin markH.bin SEGS EXPECT RUNID CFG LOGCFG PROVENANCE ex4-trial.sh VARIANT > MD5SUMS )
for f in $COPY; do [ "$(m5 "$OUT/$f")" = "$(awk -v n="$f" '$2 == n {print $1}' "$BASE/MD5SUMS")" ] || { echo "REFUSED: $f changed in the copy" >&2; exit 1; }; done
[ "$(awk '$2 == "kernel.bin" {print $1}' "$OUT/MD5SUMS")" = 988b393f878f4595be3725b33b8bbe46 ] || { echo "REFUSED: THE C4 KERNEL WALL (MD5SUMS)" >&2; exit 1; }
echo "bundle $OUT: run $RUN, overlay $OVMD5 ($SZ B), loaded $LOADED B; MD5SUMS $(m5 "$OUT/MD5SUMS") ($(wc -l < "$OUT/MD5SUMS") files)"
cat "$OUT/SEGS" "$OUT/EXPECT" "$OUT/layout.log"
