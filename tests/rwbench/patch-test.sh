#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# patch-test.sh (v9) : the three RWBENCH patches (tests/rwbench/patches/, the v8 bench lane's diffs) are now IN the tree
# (build/mkoverlay.py, userland/ex4fan.c; build-v7-rwbench.diff's one line lives in build/v9/build-v9.sh). This test
# checks the RESULT in the tree, never edits it:
#   - mkoverlay WITHOUT --rwbench writes an overlay byte-identical to the one --base-mkoverlay writes (the mkoverlay of
#     before the patch, e.g. build/mkoverlay.py.bak-20261117-v9: no change for anyone who does not ask for the bench);
#     WITH --rwbench it carries /usr/sbin/ex4-rwbench (= box/ex4-rwbench.sh), /etc/init.d/ex4-rwstop + its K01 link,
#     S99 / S03 scripts that call ex4_rw_wait before every reboot, the stamp's " rwbench=1"; THE OVERLAY GATE
#     (build/v9/overlay-gate.py) passes each overlay with its own flag and refuses it with the other;
#   - ex4_rw_wait itself, cut out of that overlay and run with its two paths pointed at a test folder and a stub
#     clean stop: it reboots only after a SAFE answer, retries an UNSAFE one, and gives a hung stop 180 s;
#   - ex4fan.c compiles warning-free (native and, with the cross gcc, ARM) and carries the marker string.
#   bash tests/rwbench/patch-test.sh --work DIR --rootfs ROOTFS --bundle BUNDLE --kmods DIR --ex4phy BIN --pubkey KEY.pub
#        [--cross PREFIX] [--base-mkoverlay FILE] [--variant V]   (V = any name build/v9/overlay-gate.py accepts: stock, or
#        xoroff / one twin prof|prof2|uaccess|diet|ud|nfsdtrack / nomemcg, in that order, joined by +, no diet+nomemcg or ud+nomemcg)
#        (ROOTFS = the image's root, BUNDLE = a bundle folder for ex4log + ex4fan; v9.7 --variant = the bundle's VARIANT,
#        passed through to every v9 overlay-gate call: a profile twin's kmods are ftrace-instrumented, so its overlays pass
#        only as --variant prof. Not given = no --variant on any gate call, the v9.4 test exactly)
#        (v9.8, the v95 review's must_fix, the test half) THE VARIANT WALL, before anything runs: with --bundle, the bundle's own
#        VARIANT file must agree with --variant: no VARIANT file = a stock bundle, taken only with no --variant or --variant stock;
#        a VARIANT file (a regular file, not a symlink) needs --variant = its first VARIANT= value exactly (no --variant, stock or
#        another name = REFUSED); and the RUNID's suffix must be that variant's (-tok-tok for tok+tok; none for stock). --variant
#        without --bundle = REFUSED (nothing to check it against). tests/rwbench/variant-test.sh runs every refusal on tiny bundles.
set -u
WORK=; RFS=; BUN=; KM=; PHY=; PUB=; CROSS=; BASE=; VAR=
while [ $# -gt 0 ]; do
	case "$1" in --work) WORK=$2;; --rootfs) RFS=$2;; --bundle) BUN=$2;; --kmods) KM=$2;; --ex4phy) PHY=$2;; --pubkey) PUB=$2;; --cross) CROSS=$2;;
	--base-mkoverlay) BASE=$2;; --variant) VAR=$2;; *) sed -n '14,24p' "$0" >&2; exit 64;; esac; shift 2
done
[ -n "$WORK" ] && [ ! -e "$WORK" ] || { echo "REFUSED: --work must be a NEW folder" >&2; exit 1; }
# v9.7 assembler (integration): the list widened to lane B's variant names, exactly the 18 the overlay gate accepts
# v9.8 assembler (integration): + lane B's ud / nfsdtrack: exactly the 24 names overlay-gate.py variant_ok accepts
case "$VAR" in ''|stock|xoroff|prof|prof2|uaccess|diet|ud|nfsdtrack|nomemcg|xoroff+prof|xoroff+prof2|xoroff+uaccess|xoroff+diet|xoroff+ud|xoroff+nfsdtrack|xoroff+nomemcg|prof+nomemcg|prof2+nomemcg|uaccess+nomemcg|nfsdtrack+nomemcg|xoroff+prof+nomemcg|xoroff+prof2+nomemcg|xoroff+uaccess+nomemcg|xoroff+nfsdtrack+nomemcg) ;;
*) echo "REFUSED: --variant must be a name the overlay gate accepts (stock, xoroff, prof, prof2, uaccess, diet, ud, nfsdtrack, nomemcg, joined in order by +), not '$VAR'" >&2; exit 1;; esac
GV=(); [ -n "$VAR" ] && GV=(--variant "$VAR")
# ---- v9.8 THE VARIANT WALL (v95 must_fix): a bundle is tested only under its OWN variant ----
VWHY=
vrefuse() { echo "REFUSED: variant: $*" >&2; exit 1; }
if [ -n "$BUN" ]; then
	[ -d "$BUN" ] || vrefuse "--bundle $BUN is not a folder"
	[ -f "$BUN/RUNID" ] && [ ! -L "$BUN/RUNID" ] || vrefuse "$BUN has no RUNID file (or it is a symlink)"
	RID=$(head -1 "$BUN/RUNID")
	[[ "$RID" =~ ^[0-9]+-l2off-[0-9]{8}-[0-9]{4}(-[a-z0-9]+)*$ ]] || vrefuse "RUNID '$RID' is not in the builder's form (NN-l2off-YYYYMMDD-HHMM[-variant tokens])"
	RSUF=$(echo "$RID" | sed -E 's/^[0-9]+-l2off-[0-9]{8}-[0-9]{4}//')
	if [ -e "$BUN/VARIANT" ] || [ -L "$BUN/VARIANT" ]; then
		[ -L "$BUN/VARIANT" ] && vrefuse "$BUN/VARIANT is a symlink"
		[ -f "$BUN/VARIANT" ] || vrefuse "$BUN/VARIANT is not a regular file"
		BV=$(awk -F= '$1 == "VARIANT" { print substr($0, 9); exit }' "$BUN/VARIANT")
		[ -n "$BV" ] || vrefuse "$BUN/VARIANT has no VARIANT= line (or an empty one): a twin bundle must say what it is"
		[ "$BV" != stock ] || vrefuse "$BUN/VARIANT says VARIANT=stock: the builder never writes a VARIANT file for stock"
		[ -n "$VAR" ] || vrefuse "the bundle is VARIANT=$BV (its VARIANT file) but no --variant was given: pass --variant $BV"
		[ "$VAR" != stock ] || vrefuse "--variant stock, but the bundle carries a VARIANT file (VARIANT=$BV): a twin is never tested as stock"
		[ "$VAR" = "$BV" ] || vrefuse "--variant $VAR, but the bundle's VARIANT file says VARIANT=$BV"
		[ "$RSUF" = "-${BV//+/-}" ] || vrefuse "the bundle's RUNID '$RID' ends '${RSUF:-(no suffix)}', VARIANT=$BV wants '-${BV//+/-}'"
		VWHY="the bundle's VARIANT file says VARIANT=$BV = --variant $VAR; RUNID $RID ends -${BV//+/-}"
	else
		case "$VAR" in ''|stock) ;; *) vrefuse "--variant $VAR, but the bundle has no VARIANT file (a stock bundle)";; esac
		[ -z "$RSUF" ] || vrefuse "the bundle has no VARIANT file (stock) but its RUNID '$RID' carries a variant suffix '$RSUF'"
		VWHY="no VARIANT file (stock) and --variant ${VAR:-not given}; RUNID $RID has no variant suffix"
	fi
elif [ -n "$VAR" ]; then vrefuse "--variant $VAR without --bundle: nothing to check the variant against"; fi
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd)
mkdir -p "$WORK/b/build" "$WORK/b/userland"; WORK=$(cd "$WORK" && pwd)
P=0; F=0
ok() { P=$((P + 1)); echo "PASS  $*"; }
bad() { F=$((F + 1)); echo "FAIL  $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }
cp "$TOP/build/mkoverlay.py" "$WORK/b/build/"; cp "$TOP/userland/ex4fan.c" "$WORK/b/userland/"
[ -n "$VWHY" ] && ok "THE VARIANT WALL: $VWHY"
check "the tree's mkoverlay.py carries the RWBENCH patch (--rwbench, ex4_rw_wait, K01ex4-rwstop)" 'grep -q "add_argument(.--rwbench" "$WORK/b/build/mkoverlay.py" && grep -q "^ex4_rw_wait() {" "$WORK/b/build/mkoverlay.py" && grep -q "K01ex4-rwstop" "$WORK/b/build/mkoverlay.py"'
check "the tree's ex4fan.c carries the RWBENCH patch (rw_stop_for_reboot)" 'grep -q "^static void rw_stop_for_reboot(void)" "$WORK/b/userland/ex4fan.c"'
python3 -I -m py_compile "$WORK/b/build/mkoverlay.py"; check "mkoverlay.py compiles" '[ $? = 0 ]'
sh -n "$TOP/build/v9/build-v9.sh"; check "build-v9.sh parses" '[ $? = 0 ]'
check "build-v9.sh: --rwbench only with EX4_RWBENCH=1 (and the gate is told which)" 'grep -q "RWB=\${EX4_RWBENCH:-0}" "$TOP/build/v9/build-v9.sh" && grep -q "\[ \"\$RWB\" = 1 \] && set -- \"\$@\" --rwbench" "$TOP/build/v9/build-v9.sh" && grep -q "GATE=\"\$GATE --no-rwbench\"" "$TOP/build/v9/build-v9.sh"'
gcc -Wall -Wextra -O2 -o "$WORK/ex4fan-native" "$WORK/b/userland/ex4fan.c" 2> "$WORK/ex4fan-native.log"; check "ex4fan.c builds native with -Wall -Wextra, no warnings" '[ $? = 0 ] && [ ! -s "$WORK/ex4fan-native.log" ]'
check "ex4fan carries the marker string the bench checks for" 'grep -q "ex4-rw-active" "$WORK/ex4fan-native"'
check "ex4fan: the stop runs before sync()+reboot in do_reboot, after the test-root early exit" 'awk "/^static void do_reboot/,/^}/" "$WORK/b/userland/ex4fan.c" | grep -n "rw_stop_for_reboot();\|sync();\|exit(0); }" | tr "\n" " " | grep -qE "exit\(0\); \}.*rw_stop_for_reboot\(\);.*sync\(\);"'
if [ -n "$CROSS" ] && command -v "${CROSS}gcc" > /dev/null; then
	"${CROSS}gcc" -static -Os -march=armv5te -Wall -o "$WORK/ex4fan-arm" "$WORK/b/userland/ex4fan.c" 2> "$WORK/ex4fan-arm.log"; check "patched ex4fan.c builds static ARM (armv5te), no warnings" '[ $? = 0 ] && [ ! -s "$WORK/ex4fan-arm.log" ]'
else echo "SKIP  ARM build of ex4fan (no --cross)"; fi
if [ -n "$RFS" ]; then
	ARGS=(--network-file "$RFS/etc/board.d/02_network" --pubkey "$PUB" --return-min 20 --ex4log "$BUN/ex4log" --log-min-sectors 2098831 --log-max-sectors 2098831
	      --tag ex4-openwrt --preinit-conf "$RFS/lib/preinit/00_preinit.conf" --ex4fan "$BUN/ex4fan" --ex4mac --kmods "$KM" --ex4phy "$PHY" --log-skip-port 4)
	python3 -I "$WORK/b/build/mkoverlay.py" "${ARGS[@]}" --out "$WORK/ov-norw.cpio" > "$WORK/ov-norw.log"
	if [ -n "$BASE" ]; then
		python3 -I "$BASE" "${ARGS[@]}" --out "$WORK/ov-orig.cpio" > "$WORK/ov-orig.log"
		check "mkoverlay WITHOUT --rwbench: overlay byte-identical to the one the pre-patch mkoverlay ($(basename "$BASE")) writes" 'cmp -s "$WORK/ov-orig.cpio" "$WORK/ov-norw.cpio"'
	else echo "SKIP  the byte-identity check (no --base-mkoverlay)"; cp "$WORK/ov-norw.cpio" "$WORK/ov-orig.cpio"; fi
	G9=$TOP/build/v9/overlay-gate.py
	python3 -I "$G9" "$WORK/ov-norw.cpio" --pubkey "$PUB" --no-webui --no-rwbench "${GV[@]}" > "$WORK/gate-norw.log" 2>&1; check "overlay gate v9: the overlay without the bench passes with --no-rwbench" '[ $? = 0 ]'
	python3 -I "$G9" "$WORK/ov-norw.cpio" --pubkey "$PUB" --no-webui --rwbench "$TOP/box/ex4-rwbench.sh" "${GV[@]}" > "$WORK/gate-norw2.log" 2>&1; check "overlay gate v9: ...and is refused when the bundle asks for the bench" '[ $? != 0 ] && grep -q "^FAIL  rw bench" "$WORK/gate-norw2.log"'
	python3 -I "$WORK/b/build/mkoverlay.py" "${ARGS[@]}" --rwbench "$TOP/box/ex4-rwbench.sh" --out "$WORK/ov-rw.cpio" > "$WORK/ov-rw.log"; check "mkoverlay WITH --rwbench writes an overlay" '[ $? = 0 ] && grep -q "rw bench: /usr/sbin/ex4-rwbench" "$WORK/ov-rw.log"'
	python3 -I "$G9" "$WORK/ov-rw.cpio" --pubkey "$PUB" --no-webui --rwbench "$TOP/box/ex4-rwbench.sh" "${GV[@]}" > "$WORK/gate-rw.log" 2>&1; check "overlay gate v9: the bench overlay passes with --rwbench (its stamp says rwbench=1)" '[ $? = 0 ] && grep -q "rwbench=1" "$WORK/gate-rw.log"'
	python3 -I "$G9" "$WORK/ov-rw.cpio" --pubkey "$PUB" --no-webui --no-rwbench "${GV[@]}" > "$WORK/gate-rw2.log" 2>&1; check "overlay gate v9: ...and is refused with --no-rwbench" '[ $? != 0 ]'
	python3 -I "$TOP/build/v8/overlay-gate.py" "$WORK/ov-rw.cpio" --pubkey "$PUB" --no-webui > "$WORK/gate-rw-v8.log" 2>&1; check "overlay gate v8 refuses the bench overlay (its stamp differs: a v8 bundle stage can never ship it by accident)" '[ $? != 0 ]'
	A=(); skip=0; for x in "${ARGS[@]}"; do [ $skip = 1 ] && { skip=0; continue; }; [ "$x" = --kmods ] && { skip=1; continue; }; A+=("$x"); done
	python3 -I "$WORK/b/build/mkoverlay.py" "${A[@]}" --rwbench "$TOP/box/ex4-rwbench.sh" --out "$WORK/ov-nokm.cpio" > "$WORK/ov-nokm.log" 2>&1; check "--rwbench without --kmods (no deadman to patch) is refused" '[ $? != 0 ] && grep -q "needs --kmods" "$WORK/ov-nokm.log"'
	python3 -I "$WORK/b/build/mkoverlay.py" "${ARGS[@]}" --rwbench "$TOP/README.md" --out "$WORK/ov-bad.cpio" > "$WORK/ov-bad.log" 2>&1; check "--rwbench with a file that is not the bench script is refused" '[ $? != 0 ] && grep -q "is not box/ex4-rwbench.sh" "$WORK/ov-bad.log"'
	mkdir -p "$WORK/x" && ( cd "$WORK/x" && cpio -id --quiet < "$WORK/ov-rw.cpio" ) 2>/dev/null
	X=$WORK/x
	check "overlay: usr/sbin/ex4-rwbench is box/ex4-rwbench.sh byte for byte, mode 755" 'cmp -s "$X/usr/sbin/ex4-rwbench" "$TOP/box/ex4-rwbench.sh" && [ -x "$X/usr/sbin/ex4-rwbench" ]'
	check "overlay: etc/rc.d/K01ex4-rwstop -> ../init.d/ex4-rwstop" '[ "$(readlink "$X/etc/rc.d/K01ex4-rwstop")" = ../init.d/ex4-rwstop ]'
	check "overlay: ex4-rwstop has STOP=01 and runs the clean stop" 'grep -q "^STOP=01" "$X/etc/init.d/ex4-rwstop" && grep -q "ex4-rwbench stop --for-reboot" "$X/etc/init.d/ex4-rwstop"'
	check "overlay: S99 ex4-trial calls ex4_rw_wait before its reboot" 'grep -q "{ ex4_rw_wait; logger -t ex4-trial" "$X/etc/init.d/ex4-trial" && grep -q "^ex4_rw_wait()" "$X/etc/init.d/ex4-trial"'
	check "overlay: S03 deadman calls ex4_rw_wait before reboot AND before reboot -f" 'grep -q "{ ex4_rw_wait; /usr/sbin/ex4log note" "$X/etc/init.d/ex4-deadman" && grep -q "ex4_rw_wait; reboot -f" "$X/etc/init.d/ex4-deadman"'
	for f in ex4-trial ex4-deadman ex4-rwstop; do sh -n "$X/etc/init.d/$f"; check "overlay: $f parses (sh -n)" '[ $? = 0 ]'; done
	check "overlay: every entry the unpatched overlay had is still there" '[ -z "$(comm -23 <(cpio -t --quiet < "$WORK/ov-orig.cpio" | sort) <(cpio -t --quiet < "$WORK/ov-rw.cpio" | sort))" ]'
	# ex4_rw_wait, cut out of the real init script, its two paths re-pointed at a test folder
	T=$WORK/w; mkdir -p "$T"
	awk '/^ex4_rw_wait\(\) \{/,/^\}/' "$X/etc/init.d/ex4-trial" | sed -e "s#/tmp/#$T/#g" -e "s#/usr/sbin/ex4-rwbench#$T/stub#g" -e "s#/usr/sbin/ex4log#$T/ex4log#g" -e 's/sleep 60/sleep 1/' -e 's/-lt 180/-lt 3/' > "$T/wait.sh"
	printf '#!/bin/sh\necho "$@" >> %s/ex4log.txt\n' "$T" > "$T/ex4log"; chmod 755 "$T/ex4log"
	run_wait() { busybox sh -c ". '$T/wait.sh'; logger() { :; }; ex4_rw_wait"; }      # busybox ash, as on the box
	mkstub() { printf '#!/bin/sh\nn=$(cat %s/n 2>/dev/null || echo 0); n=$((n + 1)); echo $n > %s/n\n%s\n' "$T" "$T" "$1" > "$T/stub"; chmod 755 "$T/stub"; rm -f "$T/n"; }
	rm -f "$T/ex4-rw-active"; mkstub 'exit 1'; run_wait; check "ex4_rw_wait: no marker -> returns at once, the stop is never called" '[ ! -e "$T/n" ]'
	: > "$T/ex4-rw-active"; mkstub "rm -f $T/ex4-rw-active; exit 0"; run_wait; check "ex4_rw_wait: marker + a SAFE stop -> one call, returns" '[ "$(cat "$T/n")" = 1 ]'
	: > "$T/ex4-rw-active"; mkstub "[ \$n -ge 3 ] && { rm -f $T/ex4-rw-active; exit 0; }; exit 1"; run_wait; check "ex4_rw_wait: UNSAFE twice -> waits and tries again, returns only after SAFE (3 calls)" '[ "$(cat "$T/n")" = 3 ] && grep -c "NOT rebooting" "$T/ex4log.txt" | grep -qx 2'
	: > "$T/ex4-rw-active"; mkstub "exit 0"; ( run_wait ) & WP=$!; sleep 4; kill $WP 2>/dev/null; wait $WP 2>/dev/null
	check "ex4_rw_wait: rc 0 but the marker still there -> NOT taken as SAFE (keeps trying)" '[ "$(cat "$T/n")" -ge 2 ]'
	rm -f "$T/ex4log.txt"; : > "$T/ex4-rw-active"; mkstub "[ \$n -ge 2 ] && { rm -f $T/ex4-rw-active; exit 0; }; sleep 30"; run_wait
	check "ex4_rw_wait: a stop that hangs is given its time (here 3 s), counted as rc 124, then tried again" 'grep -q "said rc 124" "$T/ex4log.txt" && [ "$(cat "$T/n")" = 2 ]'
else echo "SKIP  the overlay checks (no --rootfs)"; fi
echo "== patch-test: $P passed, $F failed"; [ $F = 0 ]
