#!/bin/bash
# sim-persist-c4.sh (FINALIZE C4 K5, Nov 27 2026): DESIGN-C4 §3 K5 "sim-persist + strict-ubi-forms on the MAPPED copies (MTDN=7)".
# persist-v1's own sim (persist/tests/sim-persist.sh 67621331) and its strict variant (strict-ubi-forms.sh's mkcopy rule,
# fakes/ubi-strict a102605f) run against the C4 TEST overlay's MAPPED ex4-persist / ex4-markgood (taken OUT of the built overlay),
# with the sim's fake box made to look like a C4 boot: /proc/mtd keeps WD's mtd3 "image" AND gains mtd7 "NAND simulator partition 0",
# the fake ubiattach reports mtd_num 7. Copy wall: the sim copy differs from sim-persist.sh in exactly the lines printed (all named
# below); the persist-v1 files under test are the overlay's mapped copies, which differ from persist-v1's in exactly their mapped lines.
#   bash sim-persist-c4.sh MAPPED_DIR NEVER_MARKGOOD WORKDIR     (MAPPED_DIR = an mkc4overlay.py out dir: mapped-usr_sbin_ex4-persist,
#                                                                  mapped-usr_sbin_ex4-markgood; NEVER_MARKGOOD = ov-c4d's markgood)
# Cases ADDED to the copy (named): M06 the c4d never-good markgood needs 999 checks (166 min) to mark; X01 no call in ANY case ever names mtd3 (`-m 3`).
# AMEND 2 (Nov 27 2026, finding F2: THE C4SIM GATE): every case root of the copy starts with /tmp/ex4-c4sim.done (= c4sim finished clean,
# the state every C4 boot that is not refused is in; one named mkroot line), so persist-v1's 66 cases run unchanged through the gate. ADDED:
# G01-G03 a refused / unfinished / contradictory c4sim -> the mapped ex4-persist runs MODE ram, NO ubiattach, nothing bound, seed + save write
# NOTHING to the store, the black box (ex4log note) holds the gate line and MODE ram; G04-G05 the mapped ex4-markgood: NOT marked good, no
# ubiattach, no mount, tries untouched (mark, and run when reachable).
set -u
MD=$(readlink -f "$1"); NEVER=$(readlink -f "$2"); W=$3; [ -e "$W" ] && { echo "WORKDIR $W exists"; exit 2; }; mkdir -p "$W"; W=$(readlink -f "$W")
HERE=$(cd "$(dirname "$0")" && pwd); PT=$(cd "$HERE/../../persist/tests" && pwd); SIM=$PT/sim-persist.sh; F=$PT/fakes/ubi-strict
FILES=$(cd "$PT/../files" && pwd)
m5() { md5sum < "$1" | cut -d' ' -f1; }
echo "sim-persist-c4 $(m5 "$0") $(date '+%F %T %Z') on $(hostname); sim-persist $(m5 "$SIM"); ubi-strict $(m5 "$F")"
[ "$(m5 "$SIM")" = 6762133136a5cb17c7b6611c79b7db01 ] || { echo "REFUSED: sim-persist.sh is not 67621331"; exit 9; }
[ "$(m5 "$F")" = a102605f2ec7f55da075a4542155672a ] || { echo "REFUSED: ubi-strict is not a102605f"; exit 9; }
[ "$(m5 "$FILES/usr/sbin/ex4-persist")" = 2c8eef6132334be0a2df75f4972d41d9 ] && [ "$(m5 "$FILES/usr/sbin/ex4-markgood")" = 7ba8bf420feb080e8f93177ed598683d ] \
	|| { echo "REFUSED: the persist-v1 production files are not 2c8eef61 / 7ba8bf42"; exit 9; }
P=$MD/mapped-usr_sbin_ex4-persist; G=$MD/mapped-usr_sbin_ex4-markgood
echo "mapped ex4-persist $(m5 "$P") (vs persist-v1: $(diff "$FILES/usr/sbin/ex4-persist" "$P" | grep -c '^<') lines), mapped ex4-markgood $(m5 "$G") ($(diff "$FILES/usr/sbin/ex4-markgood" "$G" | grep -c '^<')), never-good $(m5 "$NEVER") ($(diff "$FILES/usr/sbin/ex4-markgood" "$NEVER" | grep -c '^<'))"
# ---- the SRC dir under test: persist-v1's files/ with the two scripts replaced by the overlay's mapped copies (+ the never-good one)
S=$W/src-mapped; cp -a "$FILES" "$S"; cp "$P" "$S/usr/sbin/ex4-persist"; cp "$G" "$S/usr/sbin/ex4-markgood"; cp "$NEVER" "$S/usr/sbin/ex4-markgood-never"
# ---- the sim copy: exact substitutions, each with its expected count
python3 -I - "$SIM" "$W/sim-mapped.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
GATE = r"""mkroot g01; cp -a $SEEDED/. $CASE/vol/ex4data/; echo "config uhttpd main # STORED" > $CASE/vol/ex4data/etc/config/uhttpd; rm $CASE/tmp/ex4-c4sim.done; : > $CASE/tmp/ex4-c4sim.refused
cpy usr/sbin/ex4-persist p; echo 1 > $CASE/vol/ex4boot/tries; S0=$(cd $CASE/vol && find . -type f | sort | xargs md5sum | md5sum); X $CASE/p boot > $CASE/out 2>&1
chk "G01 (C4 ADDED, AMEND 2) c4sim REFUSED (.refused, no .done), a seeded store -> MODE ram, NO ubiattach, nothing bound, stored config not used; the black box holds the gate line + MODE ram" sh -c "[ \"\$(sed -n 's/^mode=//p' $CASE/tmp/ex4-persist.state | tail -n 1)\" = ram ] && ! grep -q '^ubiattach' $CASE/calls.log && ! grep -q bind $CASE/proc/mounts && ! grep -q STORED $CASE/etc/config/uhttpd && grep -q 'ex4log note persist: C4: c4sim did not finish clean' $CASE/calls.log && grep -q 'ex4log note persist: MODE ram: image defaults, nothing persists this boot' $CASE/calls.log"
X $CASE/p seed >> $CASE/out 2>&1; X $CASE/p save >> $CASE/out 2>&1; S1=$(cd $CASE/vol && find . -type f | sort | xargs md5sum | md5sum)
chk "G01 (C4 ADDED) then seed + save: 'nothing to do (mode ram)', no 'saved' line, every file of the store + ex4boot byte-identical (md5 of the tree before = after), no mount ever" sh -c "grep -q 'seed: nothing to do (mode ram)' $CASE/out && ! grep -q 'saved ' $CASE/out && [ '$S0' = '$S1' ] && ! grep -q '^mount ' $CASE/calls.log"
mkroot g02; rm $CASE/tmp/ex4-c4sim.done; cpy usr/sbin/ex4-persist p; X $CASE/p boot > $CASE/out 2>&1
chk "G02 (C4 ADDED) no .done and no .refused (c4sim crashed or hung) -> MODE ram, no ubiattach (fail closed)" sh -c "[ \"\$(sed -n 's/^mode=//p' $CASE/tmp/ex4-persist.state | tail -n 1)\" = ram ] && ! grep -q '^ubiattach' $CASE/calls.log && grep -q 'the sim is NOT attached' $CASE/out"
mkroot g03; : > $CASE/tmp/ex4-c4sim.refused; cpy usr/sbin/ex4-persist p; X $CASE/p boot > $CASE/out 2>&1
chk "G03 (C4 ADDED) .done AND .refused (contradictory) -> MODE ram, no ubiattach" sh -c "[ \"\$(sed -n 's/^mode=//p' $CASE/tmp/ex4-persist.state | tail -n 1)\" = ram ] && ! grep -q '^ubiattach' $CASE/calls.log"
mkroot g04; rm $CASE/tmp/ex4-c4sim.done; : > $CASE/tmp/ex4-c4sim.refused; cpy usr/sbin/ex4-markgood mg; mkdir -p $CASE/sys/class/ubi/ubi3; echo 7 > $CASE/sys/class/ubi/ubi3/mtd_num; echo 2 > $CASE/vol/ex4boot/tries
X $CASE/mg mark > $CASE/out 2>&1; r=$?
chk "G04 (C4 ADDED) markgood mark after a refusal (even with ubi3 already on mtd7) -> rc 1, NOT marked good, no ubiattach, no mount, tries 2 untouched, black box line" sh -c "[ $r = 1 ] && [ ! -e $CASE/tmp/ex4-good ] && ! grep -q '^ubiattach' $CASE/calls.log && ! grep -q '^mount ' $CASE/calls.log && [ \$(cat $CASE/vol/ex4boot/tries) = 2 ] && grep -q 'ex4log note markgood: C4: c4sim did not finish clean' $CASE/calls.log"
mkroot g05; rm $CASE/tmp/ex4-c4sim.done; : > $CASE/tmp/ex4-c4sim.refused; cpy usr/sbin/ex4-markgood mg; touch $CASE/ctl/ipv4
echo "   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0" >> $CASE/proc/net/tcp
( PATH=$B:/usr/bin:/bin timeout 20 dash -c ". /dev/null; $CASE/mg run" > $CASE/out 2>&1 ); r=$?
chk "G05 (C4 ADDED) markgood run, reachable, after a refusal -> 3 gate refusals, 'could not mark good after 3 tries' (ex4-notgood reboots to stock), rc 1, no ubiattach, no mount" sh -c "[ $r = 1 ] && [ \$(grep -c 'the sim is NOT attached (AMEND 2): NOT marked good' $CASE/out) = 3 ] && grep -q 'could not mark good after 3 tries' $CASE/out && [ ! -e $CASE/tmp/ex4-good ] && ! grep -q '^ubiattach' $CASE/calls.log && ! grep -q '^mount ' $CASE/calls.log"
"""
reps = [
 (': > $CASE/proc/mounts; : > $CASE/proc/mdstat; : > $CASE/calls.log', ': > $CASE/proc/mounts; : > $CASE/proc/mdstat; : > $CASE/calls.log; : > $CASE/tmp/ex4-c4sim.done', 1),
 ('mtd3: 0cd00000 00020000 "image"\\n\' > $CASE/proc/mtd', 'mtd3: 0cd00000 00020000 "image"\\nmtd7: 0cd00000 00020000 "NAND simulator partition 0"\\n\' > $CASE/proc/mtd', 1),
 ('echo 3 > "$CASE/sys/class/ubi/ubi3/mtd_num"', 'echo 7 > "$CASE/sys/class/ubi/ubi3/mtd_num"', 1),
 ("'ubiattach -m 3 -d 3 -O 2048'", "'ubiattach -m 7 -d 3 -O 2048'", 2),
 ('chk "P01 empty store, attempt 1 -> MODE first, ubiattach -m 3 -d 3 -O 2048', 'chk "P01 empty store, attempt 1 -> MODE first, ubiattach -m 7 -d 3 -O 2048', 1),
 ("sed -i 's/\"image\"/\"imagex\"/' $CASE/proc/mtd", "sed -i 's/\"NAND simulator partition 0\"/\"NAND simulator partition 9\"/' $CASE/proc/mtd", 1),
 ('chk "P08 mtd3 not named image -> MODE ram, no ubiattach call"', 'chk "P08 mtd7 not named the sim (mtd3 still \'image\') -> MODE ram, no ubiattach call"', 1),
 ('echo 3 > $CASE/sys/class/ubi/ubi3/mtd_num', 'echo 7 > $CASE/sys/class/ubi/ubi3/mtd_num', 2),
 ('echo "== copies: lines changed vs the shipped scripts (path constants + named test lines only):"',
  'mkroot m06; cpy usr/sbin/ex4-markgood-never mg; mkdir -p $CASE/sys/class/ubi/ubi3; echo 7 > $CASE/sys/class/ubi/ubi3/mtd_num; touch $CASE/ctl/ipv4\n'
  'echo "   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0" >> $CASE/proc/net/tcp\n'
  '( PATH=$B:/usr/bin:/bin dash -c ". /dev/null; $CASE/mg run" > $CASE/out 2>&1 ); r=$?; nip=$(grep -c "^ip -4 addr show dev br-lan" $CASE/calls.log); nsl=$(grep -c "^sleep 10" $CASE/calls.log)\n'
  'chk "M06 (C4 ADDED) c4d never-good markgood: it marks only after 999 reachable checks ($nip ip calls, $nsl sleeps of REACH_S 10 s = 166 min of wall time; the fake sleep is instant), far past ex4-notgood'"'"'s 10 min (M04, normal: 3 checks)" sh -c "[ $nip = 999 ] && [ $nsl = 998 ]"\n'
  'grep -h -- "-m 3 " $WORK/*/calls.log && bad "X01 (C4 ADDED) a call named mtd3" || ok "X01 (C4 ADDED) no call in any case names mtd3 (the real image partition): every attach is -m 7"\n'
  + GATE + 'echo "== copies: lines changed vs the shipped scripts (path constants + named test lines only):"', 1),
]
for a, b, n in reps:
    c = s.count(a)
    if c != n: sys.exit(f"COPY WALL: {a[:70]!r} occurs {c} times, want {n}")
    s = s.replace(a, b)
open(sys.argv[2], 'w').write(s)
PY
[ -s "$W/sim-mapped.sh" ] || exit 9
NEXP=72                                           # AMEND 2: persist-v1's 66 + G01 (2) + G02 + G03 + G04 + G05
echo "== the sim copy vs sim-persist.sh 67621331 (every changed line):"; diff "$SIM" "$W/sim-mapped.sh" | grep '^[<>]' | cut -c1-230 | sed 's/^/   /'
R=0
echo "== A. the mapped copies under persist-v1's sim (dash)"
bash "$W/sim-mapped.sh" "$S" "$W/work-plain" dash > "$W/sim-plain.out" 2>&1; rc=$?
grep -E '^(FAIL|RESULT)|C4 ADDED' "$W/sim-plain.out" | sed 's/^/   /'
{ [ $rc = 0 ] && grep -q "^RESULT $NEXP pass, 0 fail\$" "$W/sim-plain.out"; } || R=1
mkcopy() {      # strict-ubi-forms.sh's rule, on the MAPPED sim copy: exactly the two fake lines get `ubi-strict MODEL` in front
	o=$W/sim-mapped-$1.sh
	sed -e "s|^mk ubiattach 'g \"\$@\"; |mk ubiattach 'g \"\$@\"; bash $F $1 ubiattach \"\$@\" \|\| exit 1; |" \
	    -e "s|^mk ubidetach '|mk ubidetach 'bash $F $1 ubidetach \"\$@\" \|\| exit 1; |" "$W/sim-mapped.sh" > "$o"
	n=$(diff "$W/sim-mapped.sh" "$o" | grep -c '^>'); [ "$n" = 2 ] || { echo "COPY WALL: $n lines changed (want 2)"; exit 9; }
}
for model in mtdutils bb136; do
	echo "== $([ $model = mtdutils ] && echo B || echo C). the mapped sim with ubi-strict $model"
	mkcopy $model
	bash "$W/sim-mapped-$model.sh" "$S" "$W/work-$model" dash > "$W/sim-$model.out" 2>&1; rc=$?
	res=$(grep '^RESULT' "$W/sim-$model.out"); nref=$(cat "$W"/work-$model/*/calls.log 2>/dev/null | grep -c '^STRICT-REFUSED')
	echo "   rc=$rc  $res  STRICT-REFUSED lines: $nref"
	cat "$W"/work-$model/*/calls.log 2>/dev/null | grep '^STRICT-REFUSED' | sort | uniq -c | sed 's/^/   /' | head -n 6
	if [ $model = mtdutils ]; then { [ $rc = 0 ] && [ "$res" = "RESULT $NEXP pass, 0 fail" ] && [ "$nref" = 0 ]; } || R=1
	else { [ $rc != 0 ] && [ "$nref" -gt 0 ]; } || { echo "   CONTROL DID NOT FAIL: the strict test is blind"; R=1; }; fi
done
echo "== the forms the mapped copies make, under ubi-strict mtdutils (= the real 6.12 binaries' verdicts, run-c4-ubiforms.txt):"
for f in "ubiattach -m 7 -d 3 -O 2048" "ubidetach -d 3"; do set -- $f; bash "$F" mtdutils "$@" 2>/dev/null && echo "   parse: $f" || { echo "   REFUSED: $f"; R=1; }; done
echo "RESULT: $([ $R = 0 ] && echo "PASS: the MAPPED ex4-persist/ex4-markgood pass persist-v1's whole sim + the C4SIM GATE cases ($NEXP/$NEXP) plain AND under the strict mtd-utils fake (0 refusals); the busybox-1.36 control fails" || echo FAIL)"
exit $R
