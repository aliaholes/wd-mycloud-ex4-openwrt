#!/bin/bash
# sim-deadman.sh (FINALIZE C4, Nov 27 2026): THE C4-ONLY DEADMAN (files/etc/init.d/ex4-c4deadman) run off the box, as a COPY whose named
# lines are rewritten for the clock (C4_MIN 45 -> 0, C4_HANG 180 -> 1, its 10 s poll -> 1 s) and the paths (/tmp/ex4-good, ex4log) point
# into a case root; `reboot`, `logger` are fakes that log. Real sleep, real dash. Then THE PRODUCTION WALL: the deadman (and every other
# C4 file) is in NO persist-v1 production artefact, and persist-v1's own files are byte-identical to B2's pins.
#   bash sim-deadman.sh WORKDIR [PERSIST_V1_DIR [C4_OVERLAY...]]  (PERSIST_V1_DIR = the build machine's ~/ex4-build/finalize/persist-v1, for the production
#                                                    wall; C4_OVERLAY = built C4 TEST overlays that must CARRY the cap: P5)
# AMEND 1 (Nov 27 2026): THE ABSOLUTE BOOT CAP (files/etc/init.d/ex4-c4cap) too, as a COPY whose named lines are rewritten (C4_HANG
# 180 -> 1, UPTIME -> a case file, /tmp/ex4-good + ex4log -> the case); C4_CAP_MIN stays 90: the case's fake uptime puts the boot
# near minute 90, so the cap's own arithmetic is what is tested. X01 real sleep; X02-X04 a fake sleep that logs its argument (exact);
# X05 the deadman and the cap side by side (independent: whichever comes first reboots, the other is harmless). P2/P3/P5 below.
set -u
W=$1; PV=${2:-}; shift; [ $# -gt 0 ] && shift; OVS="$*"; [ -e "$W" ] && { echo "WORKDIR $W exists"; exit 2; }; mkdir -p "$W/bin"; W=$(readlink -f "$W")
HERE=$(cd "$(dirname "$0")" && pwd); DM=$HERE/../files/etc/init.d/ex4-c4deadman; CAP=$HERE/../files/etc/init.d/ex4-c4cap
m5() { md5sum < "$1" | cut -d' ' -f1; }
PASS=0; FAIL=0; ok() { PASS=$((PASS + 1)); echo "PASS $*"; }; bad() { FAIL=$((FAIL + 1)); echo "FAIL $*"; }
chk() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
echo "sim-deadman $(m5 "$0") $(date '+%F %T %Z') on $(hostname); ex4-c4deadman $(m5 "$DM"); ex4-c4cap $(m5 "$CAP")"
B=$W/bin
printf '#!/bin/sh\necho "reboot $*" >> "$CASE/calls.log"\nexit 0\n' > $B/reboot
printf '#!/bin/sh\necho "logger $*" >> "$CASE/calls.log"\n' > $B/logger
chmod 755 $B/*
mkcase() {
	CASE=$W/$1; export CASE; mkdir -p $CASE/tmp; : > $CASE/calls.log; : > $CASE/blackbox
	printf '#!/bin/sh\n[ "$1" = note ] && shift; echo "$*" >> "%s/blackbox"\n' "$CASE" > $CASE/ex4log; chmod 755 $CASE/ex4log
	sed -e 's#^C4_MIN=45$#C4_MIN=0#' -e 's#^C4_HANG=180$#C4_HANG=1#' -e "s#/tmp/ex4-good#$CASE/tmp/ex4-good#g" -e "s#/usr/sbin/ex4log#$CASE/ex4log#g" \
	    -e 's#while \[ ! -e \(.*\) \]; do sleep 10; done#while [ ! -e \1 ]; do sleep 1; done#' "$DM" > $CASE/dm
	n=$(diff "$DM" $CASE/dm | grep -c '^<'); echo "   copy: $n lines differ from ex4-c4deadman:"; diff "$DM" $CASE/dm | grep '^>' | cut -c1-170 | sed 's/^/      /'
	[ "$n" = 7 ] || { echo "COPY WALL: $n lines (want 7: C4_MIN, C4_HANG, the header comment naming /tmp/ex4-good, the armed note, the poll, the good note, the reboot note)"; exit 9; }
}
run() { PATH=$B:/usr/bin:/bin dash -c ". $CASE/dm; boot"; }
echo "== D01 not marked good: the deadman never fires (ex4-notgood owns that box)"
mkcase d01; run; sleep 4
chk "D01 armed line in the black box, no reboot in 4 s without /tmp/ex4-good" sh -c "grep -q '^rc.d S03: C4 deadman armed (C4 TEST only)' $CASE/blackbox && ! grep -q '^reboot' $CASE/calls.log"
touch $CASE/tmp/ex4-good     # lets D01's loop end (its fake reboot only logs)
echo "== D02 marked good: reboot through procd after C4_MIN (0 here), then reboot -f after C4_HANG (1 s here) when the fake reboot returns"
mkcase d02; run; sleep 2; touch $CASE/tmp/ex4-good; sleep 9
chk "D02 'marked good' then the reboot note, in that order, in the black box" sh -c "grep -n 'c4 deadman: marked good' $CASE/blackbox | grep -q . && [ \$(grep -n 'c4 deadman: marked good' $CASE/blackbox | cut -d: -f1) -lt \$(grep -n 'min after mark-good: rebooting to stock now (C4 TEST only)' $CASE/blackbox | cut -d: -f1) ]"
chk "D02 'reboot' then 'reboot -f' (the hang fallback)" sh -c "[ \"\$(grep '^reboot' $CASE/calls.log | tr '\n' '|')\" = 'reboot |reboot -f|' ]"
echo "   black box (D02):"; sed 's/^/      /' $CASE/blackbox
echo "   THE EXPECTED BLACK-BOX LINES ON THE BOX (C4_MIN 45, ex4log note prefix as ex4-notgood's):"
grep -o 'ex4log note "[^"]*"' "$DM" | sed 's/^ex4log note //; s/\$C4_MIN/45/g; s/^/      /'
# ---- AMEND 1: THE ABSOLUTE BOOT CAP
BF=$W/binfs; mkdir -p $BF; cp $B/reboot $B/logger $BF/; printf '#!/bin/sh\necho "sleep $*" >> "$CASE/calls.log"\nexit 0\n' > $BF/sleep; chmod 755 $BF/*
mkcap() {      # $1 = case, $2 = the fake /proc/uptime text ('' = no file)
	CASE=$W/$1; export CASE; mkdir -p $CASE/tmp; : > $CASE/calls.log; : > $CASE/blackbox
	printf '#!/bin/sh\n[ "$1" = note ] && shift; echo "$*" >> "%s/blackbox"\n' "$CASE" > $CASE/ex4log; chmod 755 $CASE/ex4log
	[ -n "$2" ] && echo "$2" > $CASE/uptime
	sed -e 's#^C4_HANG=180$#C4_HANG=1#' -e "s#^UPTIME=/proc/uptime\$#UPTIME=$CASE/uptime#" -e "s#/tmp/ex4-good#$CASE/tmp/ex4-good#g" -e "s#/usr/sbin/ex4log#$CASE/ex4log#g" "$CAP" > $CASE/cap
	n=$(diff "$CAP" $CASE/cap | grep -c '^<'); echo "   copy: $n lines differ from ex4-c4cap:"; diff "$CAP" $CASE/cap | grep '^>' | cut -c1-170 | sed 's/^/      /'
	[ "$n" = 5 ] || { echo "COPY WALL: $n lines (want 5: C4_HANG, UPTIME, the armed note, the /tmp/ex4-good test, the reboot note)"; exit 9; }
	grep -q '^C4_CAP_MIN=90$' $CASE/cap || { echo "COPY WALL: C4_CAP_MIN is not 90 in the copy"; exit 9; }
}
runcap() { PATH=$1:/usr/bin:/bin dash -c ". $CASE/cap; boot"; }
echo "== X01 boot cap, real sleep: uptime 5397 s -> fires in 3 s, not marked good: reboot through procd, then reboot -f after C4_HANG"
mkcap x01 '5397.42 1000.00'; runcap $B; sleep 1
chk "X01 armed line names uptime 5397 s, fires in 3 s; no reboot after 1 s" sh -c "grep -q '^rc.d S03: C4 boot cap armed (C4 TEST only): reboot to stock 90 min after boot whatever happens (uptime 5397 s, fires in 3 s;' $CASE/blackbox && ! grep -q '^reboot' $CASE/calls.log"
sleep 9
chk "X01 then 'c4 boot cap: 90 min after boot (marked good: no): rebooting to stock now', 'reboot' then 'reboot -f'" sh -c "grep -q '^c4 boot cap: 90 min after boot (marked good: no): rebooting to stock now (C4 TEST only)\$' $CASE/blackbox && [ \"\$(grep '^reboot' $CASE/calls.log | tr '\n' '|')\" = 'reboot |reboot -f|' ]"
chk "X01 the logger line" grep -q '^logger -t ex4-c4cap 90 min after boot (marked good: no): rebooting to stock (C4 TEST only)$' $CASE/calls.log
echo "   black box (X01):"; sed 's/^/      /' $CASE/blackbox
echo "== X02 fake sleep: uptime 42.99 s (an early S03) -> sleep 5358 exactly; marked good -> the note says yes"
mkcap x02 '42.99 10.00'; touch $CASE/tmp/ex4-good; runcap $BF; sleep 2
chk "X02 sleep 5358 (= 90 x 60 - 42), then sleep 4, reboot, sleep 1, reboot -f" sh -c "[ \"\$(grep -E '^(sleep|reboot)' $CASE/calls.log | tr '\n' '|')\" = 'sleep 5358|sleep 4|reboot |sleep 1|reboot -f|' ]"
chk "X02 note: marked good: yes" grep -q '^c4 boot cap: 90 min after boot (marked good: yes): rebooting to stock now (C4 TEST only)$' $CASE/blackbox
echo "== X03 fake sleep: uptime already past 90 min (6000 s) -> fires at once (sleep 1)"
mkcap x03 '6000.00 10.00'; runcap $BF; sleep 2
chk "X03 armed 'uptime 6000 s, fires in 1 s'; first sleep 1, then reboot" sh -c "grep -q 'uptime 6000 s, fires in 1 s;' $CASE/blackbox && [ \"\$(grep -E '^(sleep|reboot)' $CASE/calls.log | head -3 | tr '\n' '|')\" = 'sleep 1|sleep 4|reboot |' ]"
echo "== X04 fake sleep: /proc/uptime unreadable -> counted from 0 = the full 5400 s (never sooner, never no cap)"
mkcap x04 ''; runcap $BF 2> $CASE/stderr; sleep 2
chk "X04 armed 'uptime 0 s, fires in 5400 s'; sleep 5400; still reboots after it" sh -c "grep -q 'uptime 0 s, fires in 5400 s;' $CASE/blackbox && grep -q '^sleep 5400$' $CASE/calls.log && grep -q '^reboot -f$' $CASE/calls.log"
chk "X04 nothing on stderr (the redirect is silent)" sh -c "[ ! -s $CASE/stderr ]"
echo "== X05 the deadman and the cap side by side (real sleeps): good at 1 s, deadman C4_MIN 0 -> reboots first; the cap (uptime 5394 = 6 s) after; both log, neither waits on the other"
mkcap x05 '5394.00 10.00'; cp $CASE/cap $CASE/cap.keep
sed -e 's#^C4_MIN=45$#C4_MIN=0#' -e 's#^C4_HANG=180$#C4_HANG=1#' -e "s#/tmp/ex4-good#$CASE/tmp/ex4-good#g" -e "s#/usr/sbin/ex4log#$CASE/ex4log#g" \
    -e 's#while \[ ! -e \(.*\) \]; do sleep 10; done#while [ ! -e \1 ]; do sleep 1; done#' "$DM" > $CASE/dm
PATH=$B:/usr/bin:/bin dash -c ". $CASE/dm; boot"; runcap $B; sleep 1; touch $CASE/tmp/ex4-good; sleep 15
chk "X05 black box: deadman's 'rebooting to stock now' BEFORE the cap's; four reboot calls (each: reboot, reboot -f)" sh -c "[ \$(grep -n 'min after mark-good: rebooting to stock now' $CASE/blackbox | cut -d: -f1) -lt \$(grep -n '^c4 boot cap: 90 min after boot (marked good: yes)' $CASE/blackbox | cut -d: -f1) ] && [ \$(grep -c '^reboot' $CASE/calls.log) = 4 ]"
echo "   black box (X05):"; sed 's/^/      /' $CASE/blackbox
echo "   THE EXPECTED CAP BLACK-BOX LINES ON THE BOX (C4_CAP_MIN 90; uptime + seconds as the box reads them):"
grep -o 'ex4log note "[^"]*"' "$CAP" | sed 's/^ex4log note //; s/\$C4_CAP_MIN/90/g; s/^/      /'
if [ -n "$PV" ]; then
	echo "== THE PRODUCTION WALL: persist-v1 ($PV) is byte-identical to B2's pins and holds no C4 file"
	chk "P1 persist-v1 mtd3.ubi 547b8337, overlay 85f498e5, kernel.bin c4bea1be, mtd3/boot/initrd.cpio 85f498e5" sh -c \
		"[ \$(md5sum < $PV/mtd3/mtd3.ubi | cut -c1-32) = 547b8337cf349d8b8a11e3a8c8eaae17 ] && [ \$(md5sum < $PV/sys/overlay.cpio | cut -c1-32) = 85f498e529124931415c745e774e5e90 ] && [ \$(md5sum < $PV/sys/kernel.bin | cut -c1-32) = c4bea1be264392552fc3a81bee962df8 ] && [ \$(md5sum < $PV/mtd3/boot/initrd.cpio | cut -c1-32) = 85f498e529124931415c745e774e5e90 ]"
	python3 -I - "$PV/sys/overlay.cpio" > $W/pv1-names.txt <<'PY'
import sys
d = open(sys.argv[1], 'rb').read(); o = 0
while True:
    h = d[o:o + 110]; f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]; fs, ns = f[6], f[11]
    n = d[o + 110:o + 110 + ns - 1].decode(); o += 110 + ns; o += -o % 4; o += fs; o += -o % 4
    if n == 'TRAILER!!!': break
    print(n)
PY
	chk "P2 the production overlay has no ex4-c4deadman, ex4-c4cap, ex4-c4sim, lib/ex4-c4, nandsim or c4-test entry ($(wc -l < $W/pv1-names.txt) entries read)" sh -c "! grep -E 'c4deadman|c4cap|c4sim|ex4-c4|nandsim|c4-test' $W/pv1-names.txt"
	chk "P3 the production overlay + mtd3.ubi + kernel.bin hold no 'c4 deadman' / 'c4 boot cap' / 'C4 boot cap' / 'ex4-c4cap' / 'C4 TEST' string" sh -c "for f in $PV/sys/overlay.cpio $PV/mtd3/mtd3.ubi $PV/sys/kernel.bin; do ! grep -a -q -e 'c4 deadman' -e 'c4 boot cap' -e 'C4 boot cap' -e 'ex4-c4cap' -e 'C4_CAP_MIN' -e 'C4 TEST' \$f || exit 1; done"
	[ -d "$PV/src/ex4/persist/files" ] && chk "P4 persist-v1 src/ files = B2's SRC-MD5SUMS (md5sum -c)" sh -c "cd $PV/src && md5sum -c --quiet ../SRC-MD5SUMS"
fi
for OV in $OVS; do
	python3 -I - "$OV" > $W/ov-names.txt <<'PY'
import sys, hashlib
d = open(sys.argv[1], 'rb').read(); o = 0
while True:
    h = d[o:o + 110]; f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]; mode, fs, ns = f[1], f[6], f[11]
    n = d[o + 110:o + 110 + ns - 1].decode(); o += 110 + ns; o += -o % 4; data = d[o:o + fs]; o += fs; o += -o % 4
    if n == 'TRAILER!!!': break
    print('%06o %s %s' % (mode, hashlib.md5(data).hexdigest(), n))
PY
	chk "P5 the C4 TEST overlay $(m5 "$OV") CARRIES the cap: etc/init.d/ex4-c4cap = $(m5 "$CAP") mode 100755 + etc/rc.d/S03ex4-c4cap" sh -c "grep -q '^100755 $(m5 "$CAP") etc/init.d/ex4-c4cap\$' $W/ov-names.txt && grep -q '^120777 [0-9a-f]* etc/rc.d/S03ex4-c4cap\$' $W/ov-names.txt"
done
echo "RESULT $PASS pass, $FAIL fail"
[ $FAIL = 0 ]
