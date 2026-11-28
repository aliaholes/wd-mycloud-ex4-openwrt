#!/bin/bash
# sim-c4sim.sh (FINALIZE C4 K5, Nov 27 2026): the C4 TEST overlay's /lib/ex4-c4/c4sim run OFF the box against STRICT fakes. Each case =
# a fresh root under WORK; c4sim runs as a COPY whose 5 path/test lines (printed) point into that root; the fake /dev/mtd7 is a regular
# 1640-block file the strict nandwrite (fakes/nandwrite-strict: mtd-utils 2.3.0's getopt + write loop) writes with NAND semantics; the
# ubi fakes are ubi-strict mtdutils (persist/tests/fakes/ubi-strict, cross-checked vs the real 6.12 binaries). dd, md5sum,
# gunzip, grep, sed are the host's real tools on those files. Nothing outside WORK is written; no real device is opened.
# AMEND 1 (Nov 27 2026): the fake node's own major:minor lives beside it as dev/mtdN.nodedev (written by the fake insmod = 90:2N, or
# ctl/nodedev); the copy's nodedev() reads that file (the REAL nodedev, busybox `ls -lnd`, is proven on real char nodes by
# c4-qemu.sh §3 under the image's own ash). New refusals R28-R32 = a node whose major:minor is not the sim's sysfs dev.
# AMEND 2 (Nov 27 2026, findings F1 + F2 of the C4 session): the strict nandwrite now makes the real tool's NEXT-BLOCK PROBE on stdin
# (fakes/nandwrite-strict header), so C02 (r1 = blocks 0..1500, bad block 1501) prints "Bad block at bba0000" exactly as the box did
# in C4b. F1 = the OLD c4sim (OLD_C4SIM, 4th argument: AMEND 1's fce8603f) refuses on it (the box's text), the new c4sim accepts it
# (the bad block is placed AFTER the range, the read-back decides); a bad block INSIDE a range still refuses (R22 r1 of the 189-block
# image, R33 r1 of the 1640-block image, R34 r2 of a 1600-block image); unplaceable bad-block text refuses (R35); a silent bad write
# refuses on the read-back (R36); a source that is not the manifest's refuses before any write (R21). F2 = THE C4SIM GATE: the
# overlay's MAPPED ex4-persist and ex4-markgood (taken out of OVERLAY, 2 path lines rewritten each, checked) run in the case roots c4sim
# left: after a refusal (G01 = C4b's exact state from the old c4sim, G02 = R36, G04 = no c4sim ever ran) -> MODE ram, the sim NOT
# attached (no ubiattach call), markgood NOT marked good, nothing written to ex4boot; after a clean c4sim (G03) the gate opens.
# E cases (AMEND 2): each EXTRA overlay (the REAL bundle-c4b / bundle-c4c overlays, built from C4a's dump 3eed83a7) runs its OWN c4sim
# + sim files through the same strict fake: rc 0, DONE, every manifest range read back = its md5, r1's next-block probe placed after
# block 1500, block 1501 never written, ex4boot tries = the overlay's.
#   bash sim-c4sim.sh OVERLAY.cpio WORK SHELL OLD_C4SIM [EXTRA_OVERLAY.cpio ...]   (OVERLAY = the built bundle-c4a overlay: its own c4sim +
#                                                    nandsim.ko + sim files + mapped ex4-persist/ex4-markgood are the ones tested;
#                                                    SHELL = dash; run on the build machine, where mkc4overlay.py may write)
set -u
OV=$(readlink -f "$1"); WORK=$2; SH=$3; OLDSIM=$(readlink -f "$4"); shift 4; EXTRA="$*"
[ -e "$WORK" ] && { echo "WORK $WORK exists"; exit 2; }
mkdir -p "$WORK/bin"; WORK=$(readlink -f "$WORK"); B=$WORK/bin
HERE=$(cd "$(dirname "$0")" && pwd); C4=$(cd "$HERE/.." && pwd); NWF=$HERE/fakes/nandwrite-strict
UBIS=$(cd "$C4/../persist/tests/fakes" && pwd)/ubi-strict
m5() { md5sum < "$1" | cut -d' ' -f1; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $*"; }
chk() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
echo "sim-c4sim $(m5 "$0") on $(hostname) $(date '+%F %T %Z'); overlay $(m5 "$OV"); nandwrite-strict $(m5 "$NWF"); ubi-strict $(m5 "$UBIS"); shell $SH"
[ "$(m5 "$UBIS")" = a102605f2ec7f55da075a4542155672a ] || { echo "REFUSED: ubi-strict is not a102605f"; exit 9; }

# ---- the files under test, OUT of the overlay (end to end: what the bundle carries)
X=$WORK/ovl; mkdir -p "$X"
python3 -I - "$OV" "$X" <<'PY'
import os, sys
d = open(sys.argv[1], 'rb').read(); o = 0; out = sys.argv[2]
while True:
    h = d[o:o + 110]; assert h[:6] == b'070701'
    f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
    mode, fs, ns = f[1], f[6], f[11]
    name = d[o + 110:o + 110 + ns - 1].decode(); o += 110 + ns; o += -o % 4
    data = d[o:o + fs]; o += fs; o += -o % 4
    if name == 'TRAILER!!!': break
    if name.startswith('lib/ex4-c4/') and (mode & 0o170000) == 0o100000:
        p = os.path.join(out, name[len('lib/ex4-c4/'):]); os.makedirs(os.path.dirname(p), exist_ok=True); open(p, 'wb').write(data)
    if name in ('usr/sbin/ex4-persist', 'usr/sbin/ex4-markgood'):           # AMEND 2: the MAPPED copies, for the gate cases
        p = os.path.join(out + '-sbin', name[len('usr/sbin/'):]); os.makedirs(os.path.dirname(p), exist_ok=True); open(p, 'wb').write(data)
PY
ls -la "$X" "$X/bin" "$X-sbin" | sed 's/^/   /'
SRCSIM=$X/c4sim
echo "c4sim under test: $(m5 "$SRCSIM"); OLD c4sim (F1 control): $(m5 "$OLDSIM"); nandsim.ko $(m5 "$X/nandsim.ko"); manifest: $(tr '\n' ';' < "$X/sim.manifest")"
echo "mapped ex4-persist $(m5 "$X-sbin/ex4-persist"); mapped ex4-markgood $(m5 "$X-sbin/ex4-markgood")"

# ---- fakes (CASE = the case root)
cat > $B/_guard <<'EOF'
g() { for a in "$@"; do case "$a" in /*) case "$a" in "$CASE"/*|"$CASE") ;; *) echo "FAKE REFUSED path outside the case: $a" >> "$CASE/calls.log"; exit 99;; esac;; esac; done; }
EOF
mk() { printf '#!/bin/bash\n. %s/_guard\necho "%s $*" >> "$CASE/calls.log"\n%s\n' "$B" "$1" "$2" > "$B/$1"; chmod 755 "$B/$1"; }
# insmod = ubox kmodloader's: `insmod PATH|NAME [params...]` (kmodloader.c main_insmod: argv[1] = a regular file path or a name)
mk insmod 'g "$@"; [ $# -ge 1 ] && [ -f "$1" ] || exit 255; [ -e "$CASE/ctl/insmod_rc" ] && exit $(cat "$CASE/ctl/insmod_rc")
want="first_id_byte=0xec second_id_byte=0xda third_id_byte=0x10 fourth_id_byte=0x95 parts=1640 badblocks=1501"; shift; [ "$*" = "$want" ] || { echo "FAKE insmod: params are not C4 s" >> "$CASE/calls.log"; exit 1; }
N=$(cat "$CASE/ctl/simn" 2>/dev/null || echo 7); S=$CASE/sys/class/mtd/mtd$N; mkdir -p $S "$CASE/sys/module/nandsim"
echo "NAND simulator partition 0" > $S/name; cat "$CASE/ctl/flags" 2>/dev/null > $S/flags || echo 0x400 > $S/flags; [ -s $S/flags ] || echo 0x400 > $S/flags
echo 2048 > $S/writesize; echo 131072 > $S/erasesize; echo 64 > $S/oobsize; echo "$(cat "$CASE/ctl/subpage" 2>/dev/null || echo 512)" > $S/subpagesize
echo 214958080 > $S/size; echo "$(cat "$CASE/ctl/badcount" 2>/dev/null || echo 1)" > $S/bad_blocks; echo "90:$((N * 2))" > $S/dev
L=$(cat "$CASE/ctl/sizeline" 2>/dev/null || echo 0cd00000); printf "mtd$N: $L 00020000 \"NAND simulator partition 0\"\nmtd$((N + 1)): 03300000 00020000 \"NAND simulator partition 1\"\n" >> "$CASE/proc/mtd"
mkdir -p "$CASE/sys/class/mtd/mtd$((N + 1))"; echo "NAND simulator partition 1" > "$CASE/sys/class/mtd/mtd$((N + 1))/name"
if [ -e "$CASE/ctl/twosims" ]; then mkdir -p "$CASE/sys/class/mtd/mtd9"; echo "NAND simulator partition 0" > "$CASE/sys/class/mtd/mtd9/name"; fi
[ -e "$CASE/ctl/nodev" ] || cp "$CASE/../erased.img" "$CASE/dev/mtd$N"
[ -e "$CASE/ctl/nodev" ] || { cat "$CASE/ctl/nodedev" 2>/dev/null || echo "90:$((N * 2))"; } > "$CASE/dev/mtd$N.nodedev"
[ -e "$CASE/ctl/dirty" ] && printf "\x00" | dd of="$CASE/dev/mtd$N" bs=1 seek=777777 conv=notrunc 2>/dev/null
exit 0'
mk ubiattach 'g "$@"; bash '"$UBIS"' mtdutils ubiattach "$@" || exit 1; [ -e "$CASE/ctl/attach_fail" ] && exit 1
[ "$*" = "-m 7 -d 3 -O 2048" ] || { echo "FAKE ubiattach: not the c4sim form" >> "$CASE/calls.log"; exit 1; }
mkdir -p "$CASE/sys/class/ubi/ubi3"; echo 7 > "$CASE/sys/class/ubi/ubi3/mtd_num"; : > "$CASE/dev/ubi3_0"; : > "$CASE/dev/ubi3_1"; exit 0'
mk ubidetach 'g "$@"; bash '"$UBIS"' mtdutils ubidetach "$@" || exit 1; [ -e "$CASE/sys/class/ubi/ubi3" ] || exit 1; mv "$CASE/sys/class/ubi/ubi3" "$CASE/detached-ubi3.$$"; exit 0'
mk mount 'g "$@"; [ "$1" = -t ] && [ "$2" = ubifs ] && [ "$3" = ubi3:ex4boot ] && [ $# = 4 ] || exit 1; [ -e "$CASE/sys/class/ubi/ubi3" ] || exit 1
[ -e "$CASE/ctl/mount_fail" ] && exit 1; rmdir "$4" 2>/dev/null || exit 1; ln -s "$CASE/vol/ex4boot" "$4"; echo "ubi3:ex4boot $4 ubifs rw 0 0" >> "$CASE/proc/mounts"; exit 0'
mk umount 'g "$@"; [ -L "$1" ] || exit 1; rm "$1"; mkdir "$1"; grep -v " $1 " "$CASE/proc/mounts" > "$CASE/proc/mounts.t"; mv "$CASE/proc/mounts.t" "$CASE/proc/mounts"; exit 0'
mk logger 'exit 0'
mk sleep 'exit 0'
mk sync 'exit 0'
mk ex4log 'exit 0'
cp "$NWF" $B/nandwrite; chmod 755 $B/nandwrite
python3 -I -c "import sys; f=open(sys.argv[1],'wb'); [f.write(b'\xff'*131072) for _ in range(1640)]" "$WORK/erased.img"
echo "erased template $(m5 "$WORK/erased.img") (want 8de6e29a25040457c32a41693eb89ffd)"

mkroot() {      # $1 = case: WD's seven partitions (trial DTB: every flags 0x0), the overlay's lib files, an ex4boot volume holding tries 0
	CASE=$WORK/$1; export CASE; [ -e "$CASE" ] && { echo "case $CASE exists"; exit 2; }
	mkdir -p $CASE/{proc,dev,tmp,ctl,vol/ex4boot,lib,sys/class/ubi,sys/module}
	i=0; for nm in u-boot uImage ramdisk image "rescue firmware" config reserve; do mkdir -p $CASE/sys/class/mtd/mtd$i; echo "$nm" > $CASE/sys/class/mtd/mtd$i/name; echo 0x0 > $CASE/sys/class/mtd/mtd$i/flags; i=$((i + 1)); done
	printf 'dev:    size   erasesize  name\nmtd0: 00100000 00020000 "u-boot"\nmtd1: 00500000 00020000 "uImage"\nmtd2: 00500000 00020000 "ramdisk"\nmtd3: 0cd00000 00020000 "image"\nmtd4: 00f00000 00020000 "rescue firmware"\nmtd5: 01400000 00020000 "config"\nmtd6: 00500000 00020000 "reserve"\n' > $CASE/proc/mtd
	: > $CASE/proc/mounts; : > $CASE/calls.log; echo 0 > $CASE/vol/ex4boot/tries
	cp -a "$X" "$CASE/lib/ex4-c4"
}
cpy() {         # c4sim (or $1, AMEND 2: the OLD one) -> $CASE/c4sim: exactly these 5 lines rewritten (checked)
	local o=$CASE/c4sim SRCSIM=${1:-$SRCSIM}
	sed -e "s#^SYS=/sys; PROC=/proc; DEV=/dev; TMPD=/tmp; LIB=/lib/ex4-c4\$#SYS=$CASE/sys; PROC=$CASE/proc; DEV=$CASE/dev; TMPD=$CASE/tmp; LIB=$CASE/lib/ex4-c4#" \
	    -e "s#^INSMOD=/sbin/insmod; NANDWRITE=/lib/ex4-c4/bin/nandwrite; UBIATTACH=/usr/sbin/ubiattach; UBIDETACH=/usr/sbin/ubidetach; EX4LOG=/usr/sbin/ex4log\$#INSMOD=$B/insmod; NANDWRITE=$B/nandwrite; UBIATTACH=$B/ubiattach; UBIDETACH=$B/ubidetach; EX4LOG=$B/ex4log#" \
	    -e 's#^ischr() { \[ -c "\$1" \]; }$#ischr() { [ -e "$1" ]; }#' \
	    -e 's#^nodedev() { set -- .*$#nodedev() { cat "$1.nodedev" 2>/dev/null || echo "not-a-char-node(missing)"; }#' \
	    -e "s#^NANDWRITE_MD5=5f628c482416750b715f0a7790f97c3c #NANDWRITE_MD5=$(m5 $B/nandwrite) #" "$SRCSIM" > "$o"
	local n; n=$(diff "$SRCSIM" "$o" | grep -c '^<'); echo "$n" > "$o.changed"; chmod 755 "$o"
	[ "$n" = 5 ] || { echo "COPY WALL: $n lines changed (want 5)"; exit 9; }
}
R() { PATH=$B:/usr/bin:/bin "$SH" $CASE/c4sim boot > $CASE/out 2>&1; echo $? > $CASE/rc; }
rc() { cat $CASE/rc; }
has() { grep -q -- "$1" $CASE/out; }
noins() { ! grep -q '^insmod ' $CASE/calls.log; }
nowrite() { ! grep -q '^nandwrite ' $CASE/calls.log; }
blkmd5() { dd if=$CASE/dev/mtd7 bs=131072 skip=$1 count=$2 2>/dev/null | md5sum | cut -d' ' -f1; }
mcpy() {        # AMEND 2: a MAPPED script ($1 = ex4-persist | ex4-markgood) -> $CASE/$1: exactly 2 lines rewritten (paths + ex4log), checked
	local s=$X-sbin/$1 o=$CASE/$1
	sed -e "s#^SYS=/sys; PROC=/proc; DEV=/dev; ETC=/etc; TMPD=/tmp; DATA=/ex4data\$#SYS=$CASE/sys; PROC=$CASE/proc; DEV=$CASE/dev; ETC=$CASE/etc; TMPD=$CASE/tmp; DATA=$CASE/ex4data#" \
	    -e "s#^SYS=/sys; PROC=/proc; DEV=/dev; TMPD=/tmp; DATA=/ex4data\$#SYS=$CASE/sys; PROC=$CASE/proc; DEV=$CASE/dev; TMPD=$CASE/tmp; DATA=$CASE/ex4data#" \
	    -e "s#/usr/sbin/ex4log#$B/ex4log#g" "$s" > "$o"; chmod 755 "$o"
	local n; n=$(diff "$s" "$o" | grep -c '^<'); [ "$n" = 2 ] || { echo "COPY WALL (mapped $1): $n lines changed (want 2)"; exit 9; }
}
PRUN() { PATH=$B:/usr/bin:/bin "$SH" $CASE/ex4-persist boot > $CASE/out.persist 2>&1; }
GRUN() { PATH=$B:/usr/bin:/bin "$SH" $CASE/ex4-markgood mark > $CASE/out.markgood 2>&1; echo $? > $CASE/rc.markgood; }
nattach() { grep -c '^ubiattach ' $CASE/calls.log; }

echo "== sh -n under $SH: c4sim + both init scripts"
for f in "$SRCSIM" "$C4/files/etc/init.d/ex4-c4sim" "$C4/files/etc/init.d/ex4-c4deadman" "$C4/files/etc/init.d/ex4-c4cap"; do chk "sh -n ${f##*/}" "$SH" -n "$f"; done

echo "== GOOD: the bundle-c4a sim (r1 only)"
mkroot c01; cpy; R
chk "C01 rc 0, DONE, ex4-c4sim.done" sh -c "[ $(rc) = 0 ] && grep -q '^ex4-c4sim: DONE' $CASE/out && [ -e $CASE/tmp/ex4-c4sim.done ]"
chk "C01 RO wall FIRST: 7 flags lines logged before the insmod call" sh -c "[ \$(grep -c 'RO wall: mtd[0-6] ' $CASE/out) = 7 ] && [ \$(grep -n 'RO wall passed' $CASE/out | cut -d: -f1) -lt \$(grep -n '+ .*insmod' $CASE/out | cut -d: -f1) ]"
chk "C01 insmod with C4's exact params, the K1 file" grep -q "^insmod $CASE/lib/ex4-c4/nandsim.ko first_id_byte=0xec second_id_byte=0xda third_id_byte=0x10 fourth_id_byte=0x95 parts=1640 badblocks=1501\$" $CASE/calls.log
chk "C01 resolved mtd7 by name" has "sim = mtd7 'NAND simulator partition 0' (by name"
chk "C01 (AMEND 1) the node check ran: node 90:14 = sysfs dev" has "node 90:14 = sysfs dev)"
chk "C01 erased check before any write" sh -c "[ \$(grep -n 'wholly erased' $CASE/out | cut -d: -f1) -lt \$(grep -n '+ gunzip' $CASE/out | cut -d: -f1) ]"
chk "C01 ONE nandwrite: -p -k -s 0 /dev/mtd7 - (strict fake parsed it), no STRICT-REFUSED" sh -c "[ \$(grep -c '^nandwrite ' $CASE/calls.log) = 1 ] && grep -q '^nandwrite -p -k -s 0 $CASE/dev/mtd7 -\$' $CASE/calls.log && ! grep -q STRICT-REFUSED $CASE/calls.log"
chk "C01 sim blocks 0..188 = persist-v1 547b8337, blocks 189..1639 still erased" eval "[ \$(blkmd5 0 189) = 547b8337cf349d8b8a11e3a8c8eaae17 ] && [ \$(blkmd5 189 1451) = \$(dd if=$WORK/erased.img bs=131072 count=1451 2>/dev/null | md5sum | cut -d' ' -f1) ]"
chk "C01 ubiattach -m 7 -d 3 -O 2048 then ubidetach -d 3 (strict mtd-utils forms)" sh -c "grep -q '^ubiattach -m 7 -d 3 -O 2048\$' $CASE/calls.log && grep -q '^ubidetach -d 3\$' $CASE/calls.log"
chk "C01 tries 0 -> 1 in ex4boot, unmounted after" eval "[ \"\$(cat $CASE/vol/ex4boot/tries)\" = 1 ] && ! grep -q ex4boot $CASE/proc/mounts && has 'tries 0 -> 1'"
chk "C01 no fake was handed a path outside the case" sh -c "! grep -q 'FAKE REFUSED' $CASE/calls.log"
chk "C01 (AMEND 2) the source md5'd on the box first = 547b8337, before the write" sh -c "[ \$(grep -n 'source sim-r1.img.gz = 547b8337cf349d8b8a11e3a8c8eaae17' $CASE/out | cut -d: -f1) -lt \$(grep -n '+ gunzip' $CASE/out | cut -d: -f1) ]"
chk "C01 (AMEND 2) the real tool's EOF shape: 190 'Writing data' lines for 189 blocks (box C4a: 190), no bad-block text" sh -c "[ \$(grep -c 'nandwrite: Writing data to block' $CASE/tmp/ex4-c4sim.log) = 190 ] && ! grep -qi 'bad block' $CASE/tmp/ex4-c4sim.nw.0"
C01=$CASE

echo "== GOOD: two ranges around bad block 1501 (a synthetic 1640-block image built by mkc4overlay.py itself)"
python3 -I - "$WORK/full.img" <<'PY'
import sys, hashlib
with open(sys.argv[1], 'wb') as f:
    for b in range(1640):
        f.write((b'BAD!' if b == 1501 else hashlib.md5(b'blk%d' % b).digest()[:4]) * 32768)
PY
FULLMD5=$(m5 "$WORK/full.img")
OV2=$HOME/ex4-build/finalize/c4/sim-c4sim-full-ov.$(basename "$WORK")
python3 -I "$C4/mkc4overlay.py" build --base "$HOME/ex4-build/finalize/persist-v1/sys/overlay.cpio" --c4files "$C4/files" --nandsim "$X/nandsim.ko" \
	--k2 "$X/bin" --sim "$WORK/full.img" --sim-md5 "$FULLMD5" --tries 2 --label "sim-c4sim two-range test" --out "$OV2" > "$WORK/full-ov.log" 2>&1
cat "$WORK/full-ov.log"; grep '^    r' "$OV2/OVERLAY-DIFF-C4.txt"
mkroot c02; mv $CASE/lib/ex4-c4 $CASE/c4a-lib-files.unused; mkdir -p $CASE/lib/ex4-c4
python3 -I - "$OV2/overlay.cpio" "$CASE/lib/ex4-c4" <<'PY'
import os, sys
d = open(sys.argv[1], 'rb').read(); o = 0
while True:
    h = d[o:o + 110]; f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]; mode, fs, ns = f[1], f[6], f[11]
    name = d[o + 110:o + 110 + ns - 1].decode(); o += 110 + ns; o += -o % 4; data = d[o:o + fs]; o += fs; o += -o % 4
    if name == 'TRAILER!!!': break
    if name.startswith('lib/ex4-c4/') and (mode & 0o170000) == 0o100000:
        p = os.path.join(sys.argv[2], name[11:]); os.makedirs(os.path.dirname(p), exist_ok=True); open(p, 'wb').write(data)
PY
C02LIB=$CASE/lib/ex4-c4
cpy; R
r1=$(dd if=$WORK/full.img bs=131072 count=1501 2>/dev/null | md5sum | cut -d' ' -f1); r2=$(dd if=$WORK/full.img bs=131072 skip=1502 count=138 2>/dev/null | md5sum | cut -d' ' -f1)
chk "C02 (AMEND 2, F1) the fake made the box's next-block probe after r1: 'Writing data to block 1501' + 'Bad block at bba0000' + 'Writing data to block 1502', rc 0 (box: box/C4b.3-sim.txt lines 1514-1517)" sh -c "grep -q 'Writing data to block 1501 at offset 0xbba0000' $CASE/tmp/ex4-c4sim.nw.0 && grep -q 'Bad block at bba0000, 1 block(s) will be skipped' $CASE/tmp/ex4-c4sim.nw.0 && grep -q 'Writing data to block 1502 at offset 0xbbc0000' $CASE/tmp/ex4-c4sim.nw.0 && [ \$(grep -c 'Writing data to block' $CASE/tmp/ex4-c4sim.nw.0) = 1503 ]"
chk "C02 (AMEND 2, F1) the NEW c4sim placed it AFTER the range and went on: 'nandwrite probed block 1501 (0xbba0000, bad) AFTER the range's last block 1500', DONE" sh -c "grep -q \"nandwrite probed block 1501 (0xbba0000, bad) AFTER the range's last block 1500\" $CASE/out && grep -q '^ex4-c4sim: DONE' $CASE/out && [ -e $CASE/tmp/ex4-c4sim.done ] && [ ! -e $CASE/tmp/ex4-c4sim.refused ]"
chk "C02 (AMEND 2) r2 ends at the last block (1639): no probe, no bad-block text in its output" sh -c "! grep -qi 'bad block' $CASE/tmp/ex4-c4sim.nw.1502"
chk "C02 rc 0, DONE; manifest r1 0+1501 and r2 1502+138" sh -c "[ $(rc) = 0 ] && grep -q '^r1 sim-r1.img.gz 0 1501 $r1\$' $CASE/lib/ex4-c4/sim.manifest && grep -q '^r2 sim-r2.img.gz 1502 138 $r2\$' $CASE/lib/ex4-c4/sim.manifest"
chk "C02 two nandwrite calls: -s 0 and -s 196870144 (= 1502 x 128 KiB)" sh -c "grep -q '^nandwrite -p -k -s 0 ' $CASE/calls.log && grep -q '^nandwrite -p -k -s 196870144 ' $CASE/calls.log && [ \$(grep -c '^nandwrite ' $CASE/calls.log) = 2 ]"
chk "C02 sim blocks 0..1500 + 1502..1639 = the image's; block 1501 (bad) never written (still 0xff)" eval "[ \$(blkmd5 0 1501) = $r1 ] && [ \$(blkmd5 1502 138) = $r2 ] && [ \$(blkmd5 1501 1) = \$(dd if=$WORK/erased.img bs=131072 count=1 2>/dev/null | md5sum | cut -d' ' -f1) ]"
chk "C02 tries -> 2 (bundle-c4c's value)" sh -c "[ \"\$(cat $CASE/vol/ex4boot/tries)\" = 2 ]"
echo "== WHY TWO RANGES: the same image in ONE nandwrite -p from 0, through the same strict fake"
mkdir -p $WORK/one/dev $WORK/one/ctl; CASE=$WORK/one; : > $CASE/calls.log; cp $WORK/erased.img $CASE/dev/mtd7; cp $WORK/full.img $CASE/full.img
CASE=$CASE $B/nandwrite -p -k -s 0 $CASE/dev/mtd7 $CASE/full.img > $CASE/out 2>&1; echo "   one-shot rc $?: $(cat $CASE/out)"
chk "ONE-SHOT control: the bad block shifts everything after it: blocks 1502..1639 != the image's (and 1640's worth does not fit)" eval "[ \$(blkmd5 1502 138) != $r2 ] && grep -q 'Bad block at bba0000' $CASE/out"
echo "   (AMEND 1: the two-range test overlay is LEFT at $OV2, scratch; no recursive delete under THE TMP WALL)"
echo "== F1 (AMEND 2): the OLD c4sim ($(m5 "$OLDSIM")) on the SAME two-range lib files + the same strict fake = C4b's false refusal"
mkroot f1old; mv $CASE/lib/ex4-c4 $CASE/c4a-lib-files.unused; cp -a "$C02LIB" $CASE/lib/ex4-c4; cpy "$OLDSIM"; R
chk "F1-OLD the old c4sim REFUSES on the next-block probe with the box's own words ('nandwrite met a bad block inside blocks 0..1500: the data shifted'), rc 1, refused flag, no r2 write, no attach" sh -c "[ $(rc) = 1 ] && grep -q 'REFUSED: nandwrite met a bad block inside blocks 0..1500: the data shifted' $CASE/out && [ -e $CASE/tmp/ex4-c4sim.refused ] && [ ! -e $CASE/tmp/ex4-c4sim.done ] && [ \$(grep -c '^nandwrite ' $CASE/calls.log) = 1 ] && ! grep -q '^ubiattach' $CASE/calls.log"
chk "F1-OLD and its r1 data did NOT shift (blocks 0..1500 = the image's): the old refusal was false" eval "[ \$(blkmd5 0 1501) = $r1 ]"
F1OLD=$CASE

echo "== REFUSALS (each: rc 1, the refused flag, and where it stopped)"
ref() { local id=$1 txt=$2; shift 2; mkroot $id; "$@"; cpy; R; chk "$id rc 1 + '$txt' + refused flag" sh -c "[ $(rc) = 1 ] && grep -q -- \"$txt\" $CASE/out && [ -e $CASE/tmp/ex4-c4sim.refused ] && [ ! -e $CASE/tmp/ex4-c4sim.done ]"; }
ref R01 "RO wall: a real partition is not read-only (flags: mtd3=0x400)" eval 'echo 0x400 > $CASE/sys/class/mtd/mtd3/flags'
chk "R01 stopped BEFORE insmod (no insmod call, no sim, no write)" sh -c "! grep -q '^insmod' $CASE/calls.log && [ ! -e $CASE/dev/mtd7 ] && ! grep -q '^nandwrite' $CASE/calls.log"
ref R02 "flags: mtd5=unreadable" eval 'rm $CASE/sys/class/mtd/mtd5/flags'; chk "R02 no insmod" noins
ref R03 "RO wall: /proc/mtd is not WD's seven" eval 'echo "mtd7: 0cd00000 00020000 \"NAND simulator partition 0\"" >> $CASE/proc/mtd'; chk "R03 (a sim already there) no insmod" noins
ref R04 "RO wall: /proc/mtd is not WD's seven" eval 'sed -i "s/\"image\"/\"imagex\"/" $CASE/proc/mtd'; chk "R04 no insmod" noins
ref R05 "is not K1" eval 'printf x >> $CASE/lib/ex4-c4/nandsim.ko'; chk "R05 no insmod" noins
ref R06 "nandsim is already loaded" eval 'mkdir -p $CASE/sys/module/nandsim'; chk "R06 no insmod" noins
ref R07 "insmod nandsim rc" eval 'echo 1 > $CASE/ctl/insmod_rc'; chk "R07 no write" nowrite
ref R08 "the sim is mtd8, not mtd7" eval 'echo 8 > $CASE/ctl/simn'; chk "R08 no write" nowrite
ref R09 "two MTDs are named" eval 'touch $CASE/ctl/twosims'; chk "R09 no write" nowrite
ref R10 "/proc/mtd line of mtd7 is not" eval 'echo 0cc00000 > $CASE/ctl/sizeline'; chk "R10 no write" nowrite
ref R11 "mtd7 flags 0x0, want 0x400" eval 'echo 0x0 > $CASE/ctl/flags'; chk "R11 no write" nowrite
ref R12 "is not mtd3's 2048/131072/64/512/214958080" eval 'echo 2048 > $CASE/ctl/subpage'; chk "R12 no write" nowrite
ref R13 "has 2 bad block(s), want exactly 1" eval 'echo 2 > $CASE/ctl/badcount'; chk "R13 no write" nowrite
ref R14 "is not a char device (waited 10 s" eval 'touch $CASE/ctl/nodev'; chk "R14 no write" nowrite
ref R15 "the fresh sim is not wholly erased" eval 'touch $CASE/ctl/dirty'; chk "R15 no write" nowrite
ref R16 "sim.manifest: r1 must start at 0 and end before block 1501" eval 'sed -i "s/^r1 sim-r1.img.gz 0 189 /r1 sim-r1.img.gz 0 1502 /" $CASE/lib/ex4-c4/sim.manifest'; chk "R16 no insmod" noins
ref R17 "r2 must start at block 1502" eval 'cp $CASE/lib/ex4-c4/sim-r1.img.gz $CASE/lib/ex4-c4/sim-r2.img.gz; echo "r2 sim-r2.img.gz 1501 1 547b8337cf349d8b8a11e3a8c8eaae17" >> $CASE/lib/ex4-c4/sim.manifest'; chk "R17 no insmod" noins
ref R18 "is not sim-r2.img.gz" eval 'echo "r2 sim-r1.img.gz 1502 1 547b8337cf349d8b8a11e3a8c8eaae17" >> $CASE/lib/ex4-c4/sim.manifest'
ref R19 "unknown line 'r3'" eval 'echo "r3 sim-r3.img.gz 1502 1 547b8337cf349d8b8a11e3a8c8eaae17" >> $CASE/lib/ex4-c4/sim.manifest'
ref R20 "is '3' (C4 writes 1 or 2 only)" eval 'echo 3 > $CASE/lib/ex4-c4/tries'; chk "R20 no insmod" noins
ref R21 "the source sim-r1.img.gz gunzips to md5 547b8337cf349d8b8a11e3a8c8eaae17, not the manifest's 00000000000000000000000000000000 (nothing written)" eval 'sed -i "s/ 547b8337cf349d8b8a11e3a8c8eaae17\$/ 00000000000000000000000000000000/" $CASE/lib/ex4-c4/sim.manifest'
chk "R21 (AMEND 2: the source is md5'd before the write) no nandwrite, no attach" sh -c "! grep -q '^nandwrite' $CASE/calls.log && ! grep -q '^ubiattach' $CASE/calls.log"
ref R22 "nandwrite met a bad block inside blocks 0..188 (block 100 at 0xc80000): the data shifted" eval 'printf "100\n1501\n" > $CASE/ctl/badblocks'
chk "R22 the strict fake shifted past block 100 (its Bad block line is in the log); no attach" sh -c "grep -q 'Bad block at c80000' $CASE/tmp/ex4-c4sim.log && ! grep -q '^ubiattach' $CASE/calls.log"
ref R23 "nandwrite rc 1 for blocks 0.." eval 'echo 1 > $CASE/ctl/nandwrite_rc'
ref R24 "ubiattach -m 7 -d 3 -O 2048 failed" eval 'touch $CASE/ctl/attach_fail'
ref R25 "mount ubi3:ex4boot rw failed" eval 'touch $CASE/ctl/mount_fail'; chk "R25 detached after the failed mount" grep -q '^ubidetach -d 3$' $CASE/calls.log
ref R26 "tries reads '0' after writing '1'" eval 'chmod 444 $CASE/vol/ex4boot/tries; chmod 555 $CASE/vol/ex4boot'; chmod 755 $CASE/vol/ex4boot; chmod 644 $CASE/vol/ex4boot/tries
mkroot R27; cpy; sed -i 's#^\tsimdev$#\tfor q in $SYS/class/mtd/mtd7/name; do echo "NAND simulator X" > $q; done; simdev#' $CASE/c4sim
n=$(diff "$SRCSIM" $CASE/c4sim | grep -c '^<'); R
chk "R27 (copy + 1 named test line, $n differ) sim renamed after insmod -> 'no MTD named', no write" sh -c "[ $n = 6 ] && [ $(rc) = 1 ] && grep -q \"no MTD named 'NAND simulator partition 0'\" $CASE/out && ! grep -q '^nandwrite' $CASE/calls.log"
echo "== AMEND 1 REFUSALS: the /dev/mtd7 NODE's own major:minor must equal the sim's sysfs dev (90:14)"
ref R28 "node is 90:15, not the sim's sysfs dev 90:14" eval 'echo 90:15 > $CASE/ctl/nodedev'; chk "R28 (the read-only node mtd7ro) no write, no attach" sh -c "! grep -q '^nandwrite' $CASE/calls.log && ! grep -q '^ubiattach' $CASE/calls.log"
ref R29 "node is 90:16, not the sim's sysfs dev 90:14" eval 'echo 90:16 > $CASE/ctl/nodedev'; chk "R29 (mtd8's node) no write" nowrite
ref R30 "node is not-a-char-node(-rw-r--r--), not the sim's sysfs dev 90:14" eval 'echo "not-a-char-node(-rw-r--r--)" > $CASE/ctl/nodedev'; chk "R30 (a regular file where the node should be) no write" nowrite
ref R31 "node is 31:7, not the sim's sysfs dev 90:14" eval 'echo 31:7 > $CASE/ctl/nodedev'; chk "R31 (another major) no write" nowrite
ref R32 "node is not-a-char-node(missing), not the sim's sysfs dev 90:14" eval 'echo "not-a-char-node(missing)" > $CASE/ctl/nodedev'; chk "R32 (ls saw nothing) no write" nowrite
echo "== AMEND 2 REFUSALS (F1: facts, not text)"
R33() { mv $CASE/lib/ex4-c4 $CASE/c4a-lib-files.unused; cp -a "$C02LIB" $CASE/lib/ex4-c4; printf "700\n1501\n" > $CASE/ctl/badblocks; }
ref R33 "nandwrite met a bad block inside blocks 0..1500 (block 700 at 0x5780000): the data shifted" R33
chk "R33 (a bad block inside r1 of the 1640-block image) no r2 write, no attach" sh -c "[ \$(grep -c '^nandwrite ' $CASE/calls.log) = 1 ] && ! grep -q '^ubiattach' $CASE/calls.log"
python3 -I - "$WORK/s1600.img" <<'PY'
import sys, hashlib
with open(sys.argv[1], 'wb') as f:
    for b in range(1600):
        f.write((b'BAD!' if b == 1501 else hashlib.md5(b's16-%d' % b).digest()[:4]) * 32768)
PY
OV3=$HOME/ex4-build/finalize/c4/sim-c4sim-1600-ov.$(basename "$WORK")
python3 -I "$C4/mkc4overlay.py" build --base "$HOME/ex4-build/finalize/persist-v1/sys/overlay.cpio" --c4files "$C4/files" --nandsim "$X/nandsim.ko" \
	--k2 "$X/bin" --sim "$WORK/s1600.img" --sim-md5 "$(m5 "$WORK/s1600.img")" --tries 1 --label "sim-c4sim r2-inside test" --out "$OV3" > "$WORK/s1600-ov.log" 2>&1
cat "$WORK/s1600-ov.log"; grep '^    r' "$OV3/OVERLAY-DIFF-C4.txt"
R34() { mv $CASE/lib/ex4-c4 $CASE/c4a-lib-files.unused; mkdir -p $CASE/lib/ex4-c4
	python3 -I -c "
import os, sys
d = open(sys.argv[1], 'rb').read(); o = 0
while True:
    h = d[o:o + 110]; f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]; mode, fs, ns = f[1], f[6], f[11]
    name = d[o + 110:o + 110 + ns - 1].decode(); o += 110 + ns; o += -o % 4; data = d[o:o + fs]; o += fs; o += -o % 4
    if name == 'TRAILER!!!': break
    if name.startswith('lib/ex4-c4/') and (mode & 0o170000) == 0o100000:
        p = os.path.join(sys.argv[2], name[11:]); os.makedirs(os.path.dirname(p), exist_ok=True); open(p, 'wb').write(data)
" "$OV3/overlay.cpio" "$CASE/lib/ex4-c4"; printf "1501\n1550\n" > $CASE/ctl/badblocks; }
ref R34 "nandwrite met a bad block inside blocks 1502..1599 (block 1550 at 0xc1c0000): the data shifted" R34
chk "R34 (a bad block inside r2) r1 was accepted first (its probe of 1501 logged), no attach" sh -c "grep -q \"nandwrite probed block 1501 (0xbba0000, bad) AFTER the range's last block 1500\" $CASE/out && grep -q 'wrote + read back blocks 0..1500' $CASE/out && ! grep -q '^ubiattach' $CASE/calls.log"
ref R35 "nandwrite printed bad-block text that is not one whole 'Bad block at <hex>, 1 block(s) will be skipped' line (1 mention(s), 0 whole line(s)) for blocks 0..188" eval 'echo "bad block table: unreadable" > $CASE/ctl/nw_text'
chk "R35 (unplaceable bad-block text) no attach" sh -c "! grep -q '^ubiattach' $CASE/calls.log"
ref R36 "read-back of blocks 0..188 =" eval 'echo 50 > $CASE/ctl/nw_flip'
chk "R36 (a silent bad write in block 50, no text at all) the read-back refuses; no bad-block text; no attach" sh -c "! grep -qi 'bad block' $CASE/tmp/ex4-c4sim.nw.0 && ! grep -q '^ubiattach' $CASE/calls.log"
R36=$CASE
echo "== F2 (AMEND 2): THE C4SIM GATE: the overlay's MAPPED ex4-persist + ex4-markgood in the roots c4sim left"
gate() {        # $1 = id, $2 = the case root c4sim left: mapped persist boot + mapped markgood mark there; record attach counts
	CASE=$2; export CASE; mcpy ex4-persist; mcpy ex4-markgood; mkdir -p $CASE/etc/config $CASE/ex4data
	a0=$(nattach); t0=$(cat $CASE/vol/ex4boot/tries); PRUN; a1=$(nattach); GRUN; a2=$(nattach); t2=$(cat $CASE/vol/ex4boot/tries)
	echo "   $1: ubiattach calls before/after persist/after markgood = $a0/$a1/$a2; ex4boot tries $t0 -> $t2; state: $(tr '\n' ' ' < $CASE/tmp/ex4-persist.state)"
}
gate G01 "$F1OLD"
chk "G01 (C4b's exact state: the OLD c4sim refused, nandsim loaded, r1 written) -> persist: the gate says 'the sim is NOT attached', MODE ram, NO ubiattach call" sh -c "grep -q 'C4: c4sim did not finish clean' $CASE/out.persist && grep -q 'the sim is NOT attached (AMEND 2): no persistence' $CASE/out.persist && grep -q 'MODE ram: image defaults, nothing persists this boot' $CASE/out.persist && [ \"\$(sed -n 's/^mode=//p' $CASE/tmp/ex4-persist.state | tail -n 1)\" = ram ] && [ $a1 = 0 ]"
chk "G01 -> markgood: rc 1, 'NOT marked good', no ubiattach, no /tmp/ex4-good, ex4boot tries untouched, no mount" sh -c "[ \$(cat $CASE/rc.markgood) = 1 ] && grep -q 'the sim is NOT attached (AMEND 2): NOT marked good' $CASE/out.markgood && [ $a2 = 0 ] && [ ! -e $CASE/tmp/ex4-good ] && [ $t2 = $t0 ] && ! grep -q '^mount ' $CASE/calls.log"
gate G02 "$R36"
chk "G02 (a read-back refusal) -> MODE ram, no ubiattach by persist or markgood, not marked good" sh -c "[ \"\$(sed -n 's/^mode=//p' $CASE/tmp/ex4-persist.state | tail -n 1)\" = ram ] && grep -q 'the sim is NOT attached' $CASE/out.persist && [ $a2 = 0 ] && [ ! -e $CASE/tmp/ex4-good ] && [ \$(cat $CASE/rc.markgood) = 1 ]"
mkroot g04; gate G04 "$CASE"
chk "G04 (no c4sim ever ran: no .done, no .refused) -> MODE ram, no ubiattach, not marked good (fail closed)" sh -c "[ \"\$(sed -n 's/^mode=//p' $CASE/tmp/ex4-persist.state | tail -n 1)\" = ram ] && grep -q 'the sim is NOT attached' $CASE/out.persist && [ $a2 = 0 ] && [ ! -e $CASE/tmp/ex4-good ]"
mkroot g05; : > $CASE/tmp/ex4-c4sim.done; : > $CASE/tmp/ex4-c4sim.refused; gate G05 "$CASE"
chk "G05 (.done AND .refused both there: contradictory) -> MODE ram, no ubiattach" sh -c "[ \"\$(sed -n 's/^mode=//p' $CASE/tmp/ex4-persist.state | tail -n 1)\" = ram ] && [ $a2 = 0 ]"
gate G03 "$C01"
chk "G03 (CONTROL: a clean c4sim, C01) -> the gate OPENS: persist calls ubiattach -m 7 -d 3 -O 2048 (c4sim's 1 + persist's 1 = 2), no 'NOT attached' line" sh -c "[ $a0 = 1 ] && [ $a1 = 2 ] && [ \"\$(grep '^ubiattach' $CASE/calls.log | tail -n 1)\" = 'ubiattach -m 7 -d 3 -O 2048' ] && ! grep -q 'NOT attached' $CASE/out.persist"
echo "== E (AMEND 2): the REAL extra overlays' own c4sim + sim files (C4a's dump), end to end through the strict fake"
ne=0
for EOV in $EXTRA; do
	ne=$((ne + 1)); EOV=$(readlink -f "$EOV"); mkroot e$ne; mv $CASE/lib/ex4-c4 $CASE/c4a-lib-files.unused; mkdir -p $CASE/lib/ex4-c4
	python3 -I -c "
import os, sys
d = open(sys.argv[1], 'rb').read(); o = 0
while True:
    h = d[o:o + 110]; f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]; mode, fs, ns = f[1], f[6], f[11]
    name = d[o + 110:o + 110 + ns - 1].decode(); o += 110 + ns; o += -o % 4; data = d[o:o + fs]; o += fs; o += -o % 4
    if name == 'TRAILER!!!': break
    if name.startswith('lib/ex4-c4/') and (mode & 0o170000) == 0o100000:
        p = os.path.join(sys.argv[2], name[11:]); os.makedirs(os.path.dirname(p), exist_ok=True); open(p, 'wb').write(data)
" "$EOV" "$CASE/lib/ex4-c4"
	echo "   e$ne = $EOV ($(m5 "$EOV")): c4sim $(m5 $CASE/lib/ex4-c4/c4sim); manifest $(tr '\n' ';' < $CASE/lib/ex4-c4/sim.manifest) tries $(cat $CASE/lib/ex4-c4/tries)"
	SRCSIM=$CASE/lib/ex4-c4/c4sim cpy; R; et=$(cat $CASE/lib/ex4-c4/tries)
	allok=1; while read -r tg f st cnt mm; do [ "$(blkmd5 $st $cnt)" = "$mm" ] || allok=0; done < $CASE/lib/ex4-c4/sim.manifest
	chk "E$ne rc 0, DONE, .done, every manifest range in the sim = its md5 (read here, block by block)" sh -c "[ $(rc) = 0 ] && grep -q '^ex4-c4sim: DONE' $CASE/out && [ -e $CASE/tmp/ex4-c4sim.done ] && [ $allok = 1 ]"
	chk "E$ne r1 ends at 1500: the probe of 1501 placed AFTER it (not a refusal); block 1501 still erased" sh -c "grep -q \"nandwrite probed block 1501 (0xbba0000, bad) AFTER the range's last block 1500\" $CASE/out && [ \$(dd if=$CASE/dev/mtd7 bs=131072 skip=1501 count=1 2>/dev/null | md5sum | cut -d' ' -f1) = \$(dd if=$WORK/erased.img bs=131072 count=1 2>/dev/null | md5sum | cut -d' ' -f1) ]"
	chk "E$ne ex4boot tries 0 -> $et (the overlay's own tries file; the fake ex4boot volume)" sh -c "[ \"\$(cat $CASE/vol/ex4boot/tries)\" = $et ] && grep -q 'tries 0 -> $et' $CASE/out"
done
grep -h 'FAKE REFUSED' $WORK/*/calls.log && bad "a fake was handed a path outside its case" || ok "no fake was ever handed a path outside its case root"
echo "== copy wall: lines changed in every case copy vs the overlay's c4sim:"; diff "$SRCSIM" "$C01/c4sim" | grep '^[<>]' | cut -c1-200 | sed 's/^/   /'
echo "RESULT $PASS pass, $FAIL fail"
[ $FAIL = 0 ]
