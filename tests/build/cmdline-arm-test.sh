#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# tests/build/cmdline-arm-test.sh : EX4_CMDLINE_ARM inside build-v9.sh's variant scheme (v9.7). Drives the plan-only
# `build-v9.sh variant` stage, which calls the SAME variant_resolve / variant_text / cmdline_of the bundle stage calls, and
# checks: the run id, the VARIANT file's lines, the kernel command line inside atags.bin (decoded here, byte for byte, not
# through ex4img.py's printer), the refusal of every other value (nothing written), and the overlay gate's variant names.
# Touches no EX4, no network, no image tree. Needs: sh, python3. Exit 0 only if every case passes.
#   sh tests/build/cmdline-arm-test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); B="$TOP/build/v9/build-v9.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/ex4-cmdline-arm.XXXXXX"); trap 'rm -rf "$T"' EXIT INT TERM
BASE=15-l2off-20261118-0000; SZ=1234567; BOOT="console=ttyS0,115200n8 watchdog.open_timeout=120"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS  $*"; }
no() { fail=$((fail + 1)); echo "FAIL  $*"; }
# the ATAG_CMDLINE (0x54410009) string inside atags.bin, decoded from the bytes
atag_cmdline() {
	python3 -I - "$1" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read(); p = 0; out = []
while p + 8 <= len(b):
    size, tag = struct.unpack_from('<II', b, p)
    if size == 0:
        break
    if tag == 0x54410009:
        out.append(b[p + 8:p + 4 * size].split(b'\0', 1)[0].decode())
    p += 4 * size
if len(out) != 1:
    sys.exit("expected exactly one ATAG_CMDLINE, found %d" % len(out))
print(out[0])
PY
}
# run NAME [VAR=VAL ...]: the variant stage into $T/NAME; prints its exit code into $T/NAME.rc
run() {
	n=$1; shift
	env -u EX4_XOR -u EX4_PROFILE -u EX4_TWIN -u EX4_CMDLINE_ARM "$@" sh "$B" variant --run "$BASE" --initrd-size "$SZ" --out "$T/$n" > "$T/$n.out" 2> "$T/$n.err"
	echo $? > "$T/$n.rc"
}
# accept NAME SUFFIX VARIANT-or-"-" CMDLINE-TAIL [VAR=VAL ...]
accept() {
	n=$1; suf=$2; var=$3; tail=$4; shift 4
	run "$n" "$@"
	[ "$(cat "$T/$n.rc")" = 0 ] && ok "$n: accepted" || { no "$n: refused: $(cat "$T/$n.err")"; return; }
	[ "$(cat "$T/$n/RUNID")" = "$BASE$suf" ] && ok "$n: run id $BASE$suf" || no "$n: run id $(cat "$T/$n/RUNID"), want $BASE$suf"
	if [ "$var" = - ]; then
		[ ! -e "$T/$n/VARIANT" ] && ok "$n: no VARIANT file (a default bundle has none)" || no "$n: a VARIANT file where none belongs"
	else
		[ "$(head -n 1 "$T/$n/VARIANT")" = "VARIANT=$var" ] && ok "$n: VARIANT=$var" || no "$n: VARIANT line '$(head -n 1 "$T/$n/VARIANT" 2>/dev/null)', want VARIANT=$var"
	fi
	want="$BOOT ex4boot_run=$BASE$suf$tail"
	got=$(atag_cmdline "$T/$n/atags.bin") || { no "$n: atags.bin: $got"; return; }
	[ "$got" = "$want" ] && ok "$n: atags cmdline '$got'" || no "$n: atags cmdline '$got', want '$want'"
	[ "$(cat "$T/$n/CMDLINE")" = "$want" ] && ok "$n: CMDLINE file = atags cmdline" || no "$n: CMDLINE file differs"
}
# refuse NAME WHY-PATTERN VAR=VAL ...
refuse() {
	n=$1; pat=$2; shift 2
	run "$n" "$@"
	if [ "$(cat "$T/$n.rc")" != 0 ] && grep -q "REFUSED: $pat" "$T/$n.err" && [ ! -e "$T/$n" ]; then ok "$n: refused ($(cat "$T/$n.err")), nothing written"
	else no "$n: rc $(cat "$T/$n.rc"), stderr '$(cat "$T/$n.err")', out dir $([ -e "$T/$n" ] && echo exists || echo absent)"; fi
}

accept unset          ""                  -               ""
accept nomemcg        -nomemcg            nomemcg         " cgroup_disable=memory"   EX4_CMDLINE_ARM=nomemcg
accept empty          ""                  -               ""                         EX4_CMDLINE_ARM=
accept xoroff-nomemcg -xoroff-nomemcg     xoroff+nomemcg  " cgroup_disable=memory"   EX4_XOR=off EX4_CMDLINE_ARM=nomemcg
accept prof-nomemcg   -prof-nomemcg       prof+nomemcg    " cgroup_disable=memory"   EX4_PROFILE=1 EX4_CMDLINE_ARM=nomemcg
accept uaccess-nomemcg -uaccess-nomemcg   uaccess+nomemcg " cgroup_disable=memory"   EX4_TWIN=uaccess EX4_CMDLINE_ARM=nomemcg
accept xoroff         -xoroff             xoroff          ""                         EX4_XOR=off
accept diet           -diet               diet            ""                         EX4_TWIN=diet
# the VARIANT file's CMDLINE_ARM line, word for word
grep -qx 'CMDLINE_ARM=nomemcg: the kernel command line adds cgroup_disable=memory (bench arm; kernel, DTB, kmods unchanged)' "$T/nomemcg/VARIANT" \
	&& ok "nomemcg: VARIANT's CMDLINE_ARM line" || no "nomemcg: VARIANT lacks the CMDLINE_ARM line: $(cat "$T/nomemcg/VARIANT")"
grep -q 'cgroup_disable' "$T/unset/CMDLINE" "$T/xoroff/CMDLINE" "$T/diet/CMDLINE" && no "a bundle without the arm carries cgroup_disable" || ok "no arm, no cgroup_disable on any command line"
for v in memcg NOMEMCG ' nomemcg' 'nomemcg ' 'nomemcg;reboot' 'nomemcg cgroup_disable=cpu' 'cgroup_disable=memory' nomemcg,nomemcg 0 1 yes; do
	refuse "bad-$(printf '%s' "$v" | tr -c 'A-Za-z0-9' _)" 'EX4_CMDLINE_ARM: only nomemcg' "EX4_CMDLINE_ARM=$v"
done
refuse diet-nomemcg 'EX4_CMDLINE_ARM=nomemcg with EX4_TWIN=diet' EX4_TWIN=diet EX4_CMDLINE_ARM=nomemcg
refuse bad-twin 'EX4_TWIN: only' EX4_TWIN=fast EX4_CMDLINE_ARM=nomemcg
refuse prof-and-twin 'EX4_PROFILE=1 is the hits-only profile twin' EX4_PROFILE=1 EX4_TWIN=uaccess
# the overlay gate knows the same names (and only them)
python3 -I - "$TOP/build/v9/overlay-gate.py" > "$T/gate.out" 2>&1 <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location('gate', sys.argv[1]); g = importlib.util.module_from_spec(s); s.loader.exec_module(g)
good = ['stock', 'nomemcg', 'xoroff+nomemcg', 'prof+nomemcg', 'xoroff+prof+nomemcg', 'uaccess+nomemcg', 'prof2+nomemcg', 'diet', 'xoroff+prof']
bad = ['diet+nomemcg', 'nomemcg+xoroff', 'nomemcg+nomemcg', 'stock+nomemcg', 'memcg', 'NOMEMCG', '', 'prof+prof2']
wrong = [v for v in good if not g.variant_ok(v)] + [v for v in bad if g.variant_ok(v)]
print("gate variant names:", "OK" if not wrong else "WRONG %r" % wrong)
sys.exit(1 if wrong else 0)
PY
[ $? = 0 ] && ok "overlay gate: $(cat "$T/gate.out")" || no "overlay gate: $(cat "$T/gate.out")"
echo "cmdline-arm-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
