#!/bin/bash
# strict-ubi-forms.sh (C4 prep, Nov 26 2026): persist-v1's sim (sim-persist.sh 67621331) re-run with STRICT ubiattach /
# ubidetach fakes (fakes/ubi-strict), so its pass means "the REAL tool under 6.12 parses every call these scripts make".
# sim-persist.sh's own fakes accept ANY arguments: the blind spot that let A6 through in stage2 (C2.md). Three parts:
#   1. FORMS: ubi-strict's verdict (parse / refuse) for the 10 forms that c4-ubiforms.sh ran against the REAL mtd-utils binaries
#      from the 6.12 image under qemu-arm (our C4 receipts) must equal theirs.
#   2. SIM mtdutils: a copy of sim-persist.sh whose two fake lines (mk ubiattach, mk ubidetach) first call `ubi-strict mtdutils`
#      (copy wall: exactly those 2 lines differ). Must give sim-persist's full result (64 pass, 0 fail) AND no STRICT-REFUSED anywhere.
#   3. SIM bb136 (the control): the same copy with busybox 1.36.1 upstream's contract (no -O, control node required) MUST FAIL,
#      with STRICT-REFUSED lines: the test can see the A6 class of bug, so part 2's pass means something.
#   bash strict-ubi-forms.sh WORKDIR        (WORKDIR must not exist; nothing outside it is written)
set -u
W=$1; [ -e "$W" ] && { echo "WORKDIR $W exists"; exit 2; }; mkdir -p "$W"; W=$(readlink -f "$W")
HERE=$(cd "$(dirname "$0")" && pwd); SIM=$HERE/sim-persist.sh; F=$HERE/fakes/ubi-strict; SRCF=$(cd "$HERE/../files" && pwd)
m5() { md5sum < "$1" | cut -d' ' -f1; }
echo "strict-ubi-forms $(m5 "$0") ubi-strict $(m5 "$F") sim-persist $(m5 "$SIM") files: ex4-persist $(m5 "$SRCF/usr/sbin/ex4-persist") ex4-markgood $(m5 "$SRCF/usr/sbin/ex4-markgood")"
[ "$(m5 "$SIM")" = 6762133136a5cb17c7b6611c79b7db01 ] || { echo "REFUSED: sim-persist.sh is not 67621331"; exit 9; }
R=0
echo "== 1. FORMS: ubi-strict mtdutils vs the REAL 6.12 binaries (qemu, run-c4-ubiforms.txt: parse = 'UBI is not present', refuse = a parse error)"
while IFS='|' read -r want app args; do
	[ -n "$want" ] || continue
	bash "$F" mtdutils $app $args 2>/dev/null; rc=$?; got=parse; [ $rc = 0 ] || got=refuse
	[ "$got" = "$want" ] && v=SAME || { v=DIFFERENT; R=1; }
	printf '  %-9s real=%-6s fake=%-6s %s %s\n' "$v" "$want" "$got" "$app" "$args"
done <<'EOF'
parse|ubiattach|-m 3 -d 3 -O 2048
parse|ubiattach|-m 3 -d 3 -O 2048 /dev/ubi_ctrl
parse|ubiattach|-m 7 -d 3 -O 2048
refuse|ubiattach|-m 3 -d 3 -O 2048 /dev/ubi_ctrl /dev/extra
refuse|ubiattach|-m 3 -d 3 -O 0
refuse|ubiattach|-m 3 -d 3 -Z 1
refuse|ubiattach|-d 3 -O 2048
parse|ubidetach|-d 3
parse|ubidetach|-d 3 /dev/ubi_ctrl
refuse|ubidetach|-d 3 -m 3
EOF
echo "   and the A6 contract on the two persist forms (must refuse both):"
for f in "ubiattach -m 3 -d 3 -O 2048" "ubidetach -d 3"; do
	bash "$F" bb136 $f 2>/dev/null && { echo "  BLIND     bb136 parsed: $f"; R=1; } || echo "  refused   bb136: $f"
done
mkcopy() {      # $1 = model -> $W/sim-$1.sh, exactly the two fake lines changed
	o=$W/sim-$1.sh
	sed -e "s|^mk ubiattach 'g \"\$@\"; |mk ubiattach 'g \"\$@\"; bash $F $1 ubiattach \"\$@\" \|\| exit 1; |" \
	    -e "s|^mk ubidetach '|mk ubidetach 'bash $F $1 ubidetach \"\$@\" \|\| exit 1; |" "$SIM" > "$o"
	n=$(diff "$SIM" "$o" | grep -c '^>'); [ "$n" = 2 ] || { echo "COPY WALL: $n lines changed (want 2)"; exit 9; }
	diff "$SIM" "$o" | grep '^>' | sed 's/^/   changed: /' | cut -c1-200
}
for model in mtdutils bb136; do
	echo "== $([ $model = mtdutils ] && echo 2 || echo 3). SIM with ubi-strict $model"
	mkcopy $model
	bash "$W/sim-$model.sh" "$SRCF" "$W/work-$model" dash > "$W/sim-$model.out" 2>&1; rc=$?
	res=$(grep '^RESULT' "$W/sim-$model.out"); nref=$(cat "$W"/work-$model/*/calls.log 2>/dev/null | grep -c '^STRICT-REFUSED')
	echo "   rc=$rc  $res  STRICT-REFUSED lines: $nref"
	grep '^FAIL' "$W/sim-$model.out" | sed 's/^/   /' | head -n 12
	cat "$W"/work-$model/*/calls.log 2>/dev/null | grep '^STRICT-REFUSED' | sort | uniq -c | sed 's/^/   /' | head -n 6
	if [ $model = mtdutils ]; then { [ $rc = 0 ] && [ "$res" = "RESULT 64 pass, 0 fail" ] && [ "$nref" = 0 ]; } || R=1
	else { [ $rc != 0 ] && [ "$nref" -gt 0 ]; } || { echo "   CONTROL DID NOT FAIL: the strict test is blind"; R=1; }; fi
done
echo "RESULT: $([ $R = 0 ] && echo 'PASS: every ubiattach/ubidetach call persist-v1 makes parses under the 6.12 image'"'"'s REAL tools; the A6 contract fails them (control)' || echo FAIL)"
exit $R
