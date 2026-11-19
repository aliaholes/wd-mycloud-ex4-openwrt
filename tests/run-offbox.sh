#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# run-offbox.sh : every off-box test of this repo against a bundle you built. Touches no EX4, no network, no device.
#   bash tests/run-offbox.sh --bundle out/bundle --work work [--results DIR] [--slow]
#     --bundle   the folder build.sh wrote            --work   build.sh's work folder (for the OpenWrt files in it)
#                (v8: or build/v7/build-v7.sh's / build/v8/build-v8.sh's --work folder: the rootfs, the kernel tree, ex4phy
#                and the xhci modules are then taken from openwrt/build_dir/ and bundle-work/ inside it)
# v8 adds: the panel tests (tests/panel-test.py, native + the bundle's ARM ex4fan), the web interface's tests (the page
# build check, the sha256crypt self-test, the REAL backend under qemu-arm on THIS rootfs: tests/webui/emu/emu.sh +
# api_test.py --emu), and the overlay gate (build/v8/overlay-gate.py) on the bundle's overlay.
# v9 adds: the overlay gate is build/v9/overlay-gate.py (told whether the bundle carries the rw bench, from the
# overlay itself), the read-only assembler's recovery wall (tests/md-ro-test.sh), and the deadman overlay is rebuilt
# with --rwbench when the bundle's overlay has it (so e2e-deadman boots the same reboot paths the bundle ships).
#     --results  where the logs go (default ./test-results-<stamp>; must not exist)
#     --slow     also the real-time fan cases (WD's 300 ms retry cadence, the 30 s limit): about 40 s more
# In the environment, optional:
#   EX4_E2E_ZIMAGE + EX4_E2E_DTB   a test kernel built from tests/e2e-kernel.defconfig and its versatile-pb.dtb
#                                  patched by tests/mk-e2e-dtb.sh: also runs tests/qemu-e2e.sh in its four modes
#                                  (the overlay inside OpenWrt's real userspace in qemu; about 6 minutes; needs sgdisk, cpio)
#   EX4_E2E_SSHKEY                 (v7, with the two above) the PRIVATE half of the key the bundle was built with: the
#                                  e2e's security probe then also logs in with it (a throwaway test key, never your real one)
#   EX4_TEST_STOCK_BUSYBOX + EX4_TEST_STOCK_ROOT   YOUR OWN copy of the stock firmware's /bin/busybox and a folder whose
#                                  lib/ holds its libc: also runs the trial script's awk programs on the stock awk
#   EX4_STOCK_READ_DAEMON          YOUR OWN copy of the stock up_read_daemon: also compares the thermistor table with it
#   EX4_STOCK_MTD_DIR              a folder with YOUR OWN flash dumps mtd0.dd .. mtd6.dd (dd if=/dev/mtdN, under stock):
#                                  the MAC hook also runs on the real "rescue firmware" bytes, cut out of the chip the way
#                                  the bundle's device tree cuts them
# Each test is skipped, by name, when a tool it needs is missing (qemu-arm, qemu-system-arm, the ARM cross gcc, busybox).
# Exit 0 only if nothing failed. Never run it as root.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/.." && pwd)
B=; WORK=; L=; SLOW=
while [ $# -gt 0 ]; do
	case "$1" in
	--bundle) B=$2; shift 2;; --work) WORK=$2; shift 2;; --results) L=$2; shift 2;; --slow) SLOW=--slow; shift;;
	*) echo "usage: bash tests/run-offbox.sh --bundle DIR --work DIR [--results DIR] [--slow]" >&2; exit 64;;
	esac
done
[ -n "$B" ] && [ -s "$B/MD5SUMS" ] || { echo "REFUSED: --bundle must be a built bundle (no MD5SUMS in '$B')" >&2; exit 1; }
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "REFUSED: --work must be a build's work folder" >&2; exit 1; }
if [ -d "$WORK/ix4-rootfs" ]; then                                    # build/build.sh (v1..v6, the official kernel)
	R="$WORK/ix4-rootfs"; KSRC="$WORK/dts/linux-6.12.112"; EX4PHY="$WORK/ex4phy"; KMODS="$WORK/kmods"
else                                                                  # v8: build-v7.sh / build-v8.sh (our own kernel)
	R=$(ls -d "$WORK"/openwrt/build_dir/target-*/root-kirkwood 2>/dev/null | head -1)
	KSRC=$(ls -d "$WORK"/openwrt/build_dir/target-*/linux-kirkwood_generic/linux-6.12.112 2>/dev/null | head -1)
	EX4PHY="$WORK/bundle-work/ex4phy"; KMODS="$WORK/bundle-work/kmods"
	[ -n "$R" ] && [ -d "$R/etc" ] || { echo "REFUSED: --work must be build.sh's work folder (ix4-rootfs) or build-v7/v8's (openwrt/build_dir/target-*/root-kirkwood): neither in '$WORK'" >&2; exit 1; }
fi
[ "$(id -u)" != 0 ] || { echo "REFUSED: never run the test harness as root" >&2; exit 1; }
L=${L:-test-results-$(date +%Y%m%d-%H%M%S)}; [ -e "$L" ] && { echo "REFUSED: $L exists" >&2; exit 1; }
mkdir -p "$L/bin"; L=$(cd "$L" && pwd); B=$(cd "$B" && pwd); WORK=$(cd "$WORK" && pwd); R=$(cd "$R" && pwd)
WEBUI=0; grep -a -q 'www-ex4/index.html' "$B/overlay.cpio" && WEBUI=1        # v8: the bundle carries the web interface
RWB=0; grep -a -q 'usr/sbin/ex4-rwbench' "$B/overlay.cpio" && RWB=1           # v9: the bundle carries the rw bench
have() { command -v "$1" >/dev/null 2>&1; }
NAMES=; SKIPPED=
run() { # $1 = name, rest = command: its output goes to $L/<name>.log
	n=$1; shift; NAMES="$NAMES $n"
	( "$@" > "$L/$n.log" 2>&1; echo "rc=$?" >> "$L/$n.log" ) &
}
skip() { SKIPPED="$SKIPPED|$1: $2"; }
( cd "$B" && md5sum -c MD5SUMS > "$L/bundle-md5.log" 2>&1 ) || { echo "REFUSED: the bundle does not match its own MD5SUMS (see $L/bundle-md5.log)" >&2; exit 1; }
cmp -s "$TOP/box/ex4-trial.sh" "$B/ex4-trial.sh" || { echo "REFUSED: the bundle's ex4-trial.sh is not this repo's box/ex4-trial.sh" >&2; exit 1; }
gcc -O1 -Wall -Wextra -o "$L/bin/ex4fan-native" "$TOP/userland/ex4fan.c" 2> "$L/native-build.log" \
 && gcc -O1 -o "$L/bin/ex4log-native" "$TOP/userland/ex4log.c" 2>> "$L/native-build.log" \
 && gcc -O1 -o "$L/bin/ex4peek-native" "$TOP/userland/ex4peek.c" 2>> "$L/native-build.log" || { echo "REFUSED: the native test builds failed (see $L/native-build.log)" >&2; exit 1; }
C=; for c in "$HERE"/captures/stock-daemons-*.json "$HERE"/captures/stock-read-daemon-*.json; do C="$C --stock-capture $c"; done
C="$C --stock-rtc-run $HERE/captures/stock-rtc-set-UTC0.json --src $TOP/userland/ex4fan.c"
[ -n "${EX4_STOCK_READ_DAEMON:-}" ] && C="$C --stock-read-daemon $EX4_STOCK_READ_DAEMON"

run dtb-check        python3 -I "$HERE/dtb_check.py" "$B/kernel.bin" --v6
if [ -n "$KSRC" ] && [ -d "$KSRC/drivers/net/phy" ]; then run phy-id-check sh -c 'python3 -I "$1/build/kimg_extract.py" "$2/kernel.bin" "$3/Image-phy" > "$3/kimg-phy.log" 2>&1 && python3 -I "$1/tests/phy-id-check.py" "$4" "$2/kernel.bin" "$3/Image-phy"' sh "$TOP" "$B" "$L" "$KSRC"
else skip phy-id-check "no kernel source in this work folder (a work folder of an older build.sh)"; fi
if have qemu-arm && [ -s "$EX4PHY" ]; then
	run ex4phy sh -c 'o=$(qemu-arm "$1" lo 2>&1); rc=$?; echo "$o"; [ $rc = 1 ] && echo "$o" | grep -q "^lo phy none (SIOCGMIIPHY: " && echo "PASS  the ARM ex4phy runs and reports an interface without a PHY (rc 1)" || echo "FAIL  ex4phy lo: rc $rc"
		python3 -I - "$2" "$1" <<PY
import sys, hashlib
d = open(sys.argv[1], "rb").read(); p = 0; body = None
while True:
    f = [int(d[p + 6 + 8 * i:p + 14 + 8 * i], 16) for i in range(13)]
    ns, fs = f[11], f[6]; name = d[p + 110:p + 110 + ns - 1].decode(); p = (p + 110 + ns + 3) & ~3
    b = d[p:p + fs]; p = (p + fs + 3) & ~3
    if name == "usr/sbin/ex4phy": body = b
    if name == "TRAILER!!!": break
same = body == open(sys.argv[2], "rb").read()
print(("PASS" if same else "FAIL") + "  the overlay carries exactly that binary as usr/sbin/ex4phy")
bad = [s for s in (b"SIOCSMIIREG", b"/dev/mtd", b"/dev/sd") if body and s in body]
print(("PASS" if body and not bad else "FAIL") + "  no device path in it: %r" % bad)
PY' sh "$EX4PHY" "$B/overlay.cpio"
else skip ex4phy "needs qemu-arm and the work folder's ex4phy"; fi
run kernel-facts     sh -c 'python3 -I "$1/build/kimg_extract.py" "$2/kernel.bin" "$3/Image" > "$3/kimg.log" 2>&1 && python3 -I "$1/tests/kparam.py" "$3/Image" watchdog.handle_boot_enabled panic > "$3/kparam.txt" 2>&1; cat "$3/kimg.log" "$3/kparam.txt"; awk "/^watchdog.handle_boot_enabled/ {k=1} /^panic/ {k=2} /bytes at arg/ && /u32=1\\)/ {ok[k]=1} END {print (ok[1] ? \"PASS\" : \"FAIL\") \"  the trial kernel adopts a watchdog that is already running (watchdog.handle_boot_enabled = 1, read from the image)\"; print (ok[2] ? \"PASS\" : \"FAIL\") \"  a kernel panic reboots (panic = 1, read from the image)\"}" "$3/kparam.txt"' _ "$TOP" "$B" "$L"
run ex4log-roundtrip sh "$HERE/ex4log-roundtrip.sh" "$L/bin/ex4log-native" "$L/w-roundtrip"
run klog-synth       sh -c 'python3 -I "$1/klog-synth.py" "$2/klog-a.img" "$2/klog-a.expect" "$2/klog-b.img" "$2/klog-b.expect" && for x in a b; do "$3" klog --mem "$2/klog-$x.img" --out "$2/klog-$x.out" > "$2/klog-$x.scan" 2>&1 && cmp "$2/klog-$x.out" "$2/klog-$x.expect" && echo "PASS  ring $x recovered byte for byte" || echo "FAIL  ring $x"; done' _ "$HERE" "$L" "$L/bin/ex4peek-native"
run fan-native       python3 -I "$HERE/fan-test.py" --bin "$L/bin/ex4fan-native" $C --work "$L/w-fan-native" $SLOW
if gcc -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -o "$L/bin/ex4fan-asan" "$TOP/userland/ex4fan.c" 2>> "$L/native-build.log"; then
	run fan-asan env ASAN_OPTIONS=detect_leaks=0:handle_segv=0 python3 -I "$HERE/fan-test.py" --bin "$L/bin/ex4fan-asan" $C --work "$L/w-fan-asan"
else skip fan-asan "this compiler has no address sanitizer"; fi
if have qemu-arm; then run fan-arm python3 -I "$HERE/fan-test.py" --bin "$B/ex4fan" --qemu $C --work "$L/w-fan-arm" $SLOW
else skip fan-arm "qemu-arm (user mode) not found"; fi
# v8: the panel (the panel lane's patch 1) and THE ONE TEST FRAME
PC="--lcd-capture $HERE/captures/stock-lcd-frames-2026-11-17.json --power-capture $HERE/captures/stock-power-frames-2026-11-17.json --src $TOP/userland/ex4fan.c"
run panel-native python3 -I "$HERE/panel-test.py" --bin "$L/bin/ex4fan-native" $PC --work "$L/w-panel-native"
if have qemu-arm; then run panel-arm python3 -I "$HERE/panel-test.py" --bin "$B/ex4fan" --qemu $PC --work "$L/w-panel-arm"
else skip panel-arm "qemu-arm (user mode) not found"; fi
# v8: the web interface (the web lane's patch 3) and the overlay gate
run webui-build python3 -I "$TOP/webui/build.py" --check
run webui-hash  python3 -I "$HERE/webui/sha256crypt.py"
if [ $WEBUI = 1 ] && have qemu-arm && have arm-linux-gnueabi-gcc && have curl && [ -x "$R/usr/sbin/px5g" ]; then
	run webui-api bash "$HERE/webui/emu/emu.sh" "$R" "$L/w-webui" -- python3 -I "$HERE/webui/api_test.py" --emu
else skip webui-api "needs a bundle with the web interface, qemu-arm, arm-linux-gnueabi-gcc, curl and a rootfs with px5g"; fi
python3 -I - "$B/overlay.cpio" "$L/overlay-key.pub" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read(); p = 0
while True:
    f = [int(d[p + 6 + 8 * i:p + 14 + 8 * i], 16) for i in range(13)]
    ns, fs = f[11], f[6]; name = d[p + 110:p + 110 + ns - 1].decode(); p = (p + 110 + ns + 3) & ~3
    body = d[p:p + fs]; p = (p + fs + 3) & ~3
    if name == 'etc/dropbear/authorized_keys': open(sys.argv[2], 'wb').write(body); break
    if name == 'TRAILER!!!': break
PY
if [ $WEBUI = 1 ]; then GATE="--webui $TOP/webui"; else GATE=--no-webui; fi
if [ $RWB = 1 ]; then GATE="$GATE --rwbench $TOP/box/ex4-rwbench.sh"; else GATE="$GATE --no-rwbench"; fi
if [ -s "$TOP/build/v9/overlay-gate.py" ]; then run overlay-gate python3 -I "$TOP/build/v9/overlay-gate.py" "$B/overlay.cpio" --pubkey "$L/overlay-key.pub" $GATE
else skip overlay-gate "no build/v9/overlay-gate.py"; fi
if [ -s "$TOP/build/v9/files/usr/sbin/ex4-md-ro" ]; then run md-ro sh "$HERE/md-ro-test.sh" "$L/w-md-ro"
else skip md-ro "no build/v9/files/usr/sbin/ex4-md-ro"; fi
run trial-logic-sh   env -u EX4_TEST_STOCK_BUSYBOX -u EX4_TEST_STOCK_ROOT sh "$HERE/trial-logic.sh" "$TOP/box/ex4-trial.sh" "$B" "$L/bin/ex4peek-native" "$L/bin/ex4log-native" "$HERE/mkfixture.py" "$L/w-logic-sh" sh
if have busybox; then
	run trial-logic-ash env -u EX4_TEST_STOCK_BUSYBOX -u EX4_TEST_STOCK_ROOT sh "$HERE/trial-logic.sh" "$TOP/box/ex4-trial.sh" "$B" "$L/bin/ex4peek-native" "$L/bin/ex4log-native" "$HERE/mkfixture.py" "$L/w-logic-ash" "busybox ash"
	run mac-hook        sh "$HERE/mac-hook-test.sh" "$B/overlay.cpio" "$R" "$L/w-mac" "$B/kernel.bin"
else skip trial-logic-ash "busybox not found"; skip mac-hook "busybox not found"; fi
if [ -n "${EX4_TEST_STOCK_BUSYBOX:-}" ] && have qemu-arm; then
	run trial-logic-stockawk sh "$HERE/trial-logic.sh" "$TOP/box/ex4-trial.sh" "$B" "$L/bin/ex4peek-native" "$L/bin/ex4log-native" "$HERE/mkfixture.py" "$L/w-logic-stockawk" sh
else skip trial-logic-stockawk "needs EX4_TEST_STOCK_BUSYBOX (your own copy of the stock busybox) and qemu-arm"; fi
run watch            sh "$HERE/watch-test.sh" "$TOP/host/ex4-watch.sh" "$L/w-watch"
if have arm-linux-gnueabi-gcc && have qemu-system-arm; then
	run stub         env OUT="$L/w-stub" sh "$TOP/loader/stubtest/build-and-run.sh" "$TOP/loader/ex4boot_stub.S"
	run handoff      sh "$HERE/qemu-handoff.sh" "$TOP" "$B" "$L/bin/ex4peek-native" "$L/w-handoff"
	run handoff-memfix env MEMFIX=1 sh "$HERE/qemu-handoff.sh" "$TOP" "$B" "$L/bin/ex4peek-native" "$L/w-handoff-memfix"
else skip "stub, handoff, handoff-memfix" "need arm-linux-gnueabi-gcc and qemu-system-arm"; fi
if [ -n "${EX4_E2E_ZIMAGE:-}" ] && [ -n "${EX4_E2E_DTB:-}" ] && have qemu-system-arm && have sgdisk && have cpio; then
	for m in normal silent rpmzero; do
		run e2e-$m sh "$HERE/qemu-e2e.sh" "$EX4_E2E_ZIMAGE" "$EX4_E2E_DTB" "$R" "$B/overlay.cpio" "$TOP/userland/ex4log.c" "$HERE/fan-emu/fake_mcu_sock.py" "$L/w-e2e-$m" $m
	done
	# the deadman: the bundle's own overlay, rebuilt with the same files and a 1-minute auto-return
	PUB="$L/overlay-return1.pub"; python3 -I - "$B/overlay.cpio" "$PUB" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read(); p = 0
while True:
    f = [int(d[p + 6 + 8 * i:p + 14 + 8 * i], 16) for i in range(13)]
    ns, fs = f[11], f[6]; name = d[p + 110:p + 110 + ns - 1].decode(); p = (p + 110 + ns + 3) & ~3
    body = d[p:p + fs]; p = (p + fs + 3) & ~3
    if name == 'etc/dropbear/authorized_keys': open(sys.argv[2], 'wb').write(body); break
    if name == 'TRAILER!!!': sys.exit("no authorized_keys in the overlay")
PY
	. "$B/LOGCFG"
	python3 -I "$TOP/build/mkoverlay.py" --network-file "$R/etc/board.d/02_network" --pubkey "$PUB" --return-min 1 --ex4log "$B/ex4log" \
		--log-min-sectors 2098831 --log-max-sectors 2098831 --tag ex4-openwrt --preinit-conf "$R/lib/preinit/00_preinit.conf" \
		--ex4fan "$B/ex4fan" --ex4mac --kmods "$KMODS" --ex4phy "$EX4PHY" $([ $WEBUI = 1 ] && echo "--webui $TOP/webui") $([ $RWB = 1 ] && echo "--rwbench $TOP/box/ex4-rwbench.sh") --out "$L/overlay-return1.cpio" > "$L/overlay-return1.log" 2>&1 \
	 && run e2e-deadman sh "$HERE/qemu-e2e.sh" "$EX4_E2E_ZIMAGE" "$EX4_E2E_DTB" "$R" "$L/overlay-return1.cpio" "$TOP/userland/ex4log.c" "$HERE/fan-emu/fake_mcu_sock.py" "$L/w-e2e-deadman" deadman
else skip "e2e-normal, e2e-silent, e2e-rpmzero, e2e-deadman" "need EX4_E2E_ZIMAGE + EX4_E2E_DTB (a test kernel, see tests/e2e-kernel.defconfig), qemu-system-arm, sgdisk, cpio"; fi
wait
TOTALFAIL=0
for f in $NAMES; do
	p=$(grep -a -c '^PASS' "$L/$f.log"); x=$(grep -a -c '^FAIL' "$L/$f.log"); rc=$(grep -a '^rc=' "$L/$f.log" | tail -1)
	san=$(grep -a -c -i 'ERROR: AddressSanitizer\|runtime error' "$L/$f.log")
	echo "== $f: $p PASS, $x FAIL, $rc$([ "$san" != 0 ] && echo ", SANITIZER REPORTS: $san") :: $(grep -a 'passed\|RESULT:\|KMOD CHECK\|read-only' "$L/$f.log" | tail -1 | cut -c1-110)"
	grep -a '^FAIL' "$L/$f.log" | cut -c1-300 | head -6
	[ "$x" = 0 ] && [ "$rc" = "rc=0" ] && [ "$san" = 0 ] || TOTALFAIL=$((TOTALFAIL + 1))
done
echo "$SKIPPED" | tr '|' '\n' | sed -n 's/^\(..*\)$/-- skipped: \1/p'
echo "run-offbox: $(echo $NAMES | wc -w) test(s) run, $TOTALFAIL with a failure; logs in $L"
[ $TOTALFAIL = 0 ]
