#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# tests/build/twin-variant-test.sh : the v9.8 kernel twins ud and nfsdtrack inside build-v9.sh's ONE variant scheme. Drives the
# plan-only `variant` stage (the same variant_resolve / variant_text / cmdline_of the bundle stage calls) and the `kernel-kind`
# stage (the bundle stage's own kernel_kind) on synthetic kernel .config files, one per kernel the script knows plus mixtures it
# must refuse. Touches no EX4, no network, no image tree. Needs: sh, python3. Exit 0 only if every case passes.
#   sh tests/build/twin-variant-test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); B="$TOP/build/v9/build-v9.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/ex4-twin-variant.XXXXXX"); trap 'rm -rf "$T"' EXIT INT TERM
BASE=18-l2off-20261118-1300; SZ=1234567
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS  $*"; }
no() { fail=$((fail + 1)); echo "FAIL  $*"; }
run() {
	n=$1; shift
	env -u EX4_XOR -u EX4_PROFILE -u EX4_TWIN -u EX4_CMDLINE_ARM "$@" sh "$B" variant --run "$BASE" --initrd-size "$SZ" --out "$T/$n" > "$T/$n.out" 2> "$T/$n.err"
	echo $? > "$T/$n.rc"
}
# accept NAME SUFFIX VARIANT CMDLINE-TAIL [VAR=VAL ...]
accept() {
	n=$1; suf=$2; var=$3; tail=$4; shift 4
	run "$n" "$@"
	[ "$(cat "$T/$n.rc")" = 0 ] || { no "$n: refused: $(cat "$T/$n.err")"; return; }
	[ "$(cat "$T/$n/RUNID")" = "$BASE$suf" ] && ok "$n: run id $BASE$suf" || no "$n: run id $(cat "$T/$n/RUNID"), want $BASE$suf"
	[ "$(head -n 1 "$T/$n/VARIANT")" = "VARIANT=$var" ] && ok "$n: VARIANT=$var" || no "$n: VARIANT line '$(head -n 1 "$T/$n/VARIANT" 2>/dev/null)'"
	[ "$(cat "$T/$n/CMDLINE")" = "console=ttyS0,115200n8 watchdog.open_timeout=120 ex4boot_run=$BASE$suf$tail" ] && ok "$n: command line" || no "$n: command line '$(cat "$T/$n/CMDLINE")'"
}
refuse() {
	n=$1; pat=$2; shift 2
	run "$n" "$@"
	if [ "$(cat "$T/$n.rc")" != 0 ] && grep -q "REFUSED: $pat" "$T/$n.err" && [ ! -e "$T/$n" ]; then ok "$n: refused ($(cat "$T/$n.err")), nothing written"
	else no "$n: rc $(cat "$T/$n.rc"), stderr '$(cat "$T/$n.err")', out dir $([ -e "$T/$n" ] && echo exists || echo absent)"; fi
}

accept ud            -ud                ud                ""                        EX4_TWIN=ud
accept nfsdtrack     -nfsdtrack         nfsdtrack         ""                        EX4_TWIN=nfsdtrack
accept xoroff-ud     -xoroff-ud         xoroff+ud         ""                        EX4_TWIN=ud EX4_XOR=off
accept nfsdtrack-nomemcg -nfsdtrack-nomemcg nfsdtrack+nomemcg " cgroup_disable=memory" EX4_TWIN=nfsdtrack EX4_CMDLINE_ARM=nomemcg
accept xoroff-nfsdtrack-nomemcg -xoroff-nfsdtrack-nomemcg xoroff+nfsdtrack+nomemcg " cgroup_disable=memory" EX4_TWIN=nfsdtrack EX4_XOR=off EX4_CMDLINE_ARM=nomemcg
for n in ud nfsdtrack; do
	f="$TOP/build/v9/kernel-config.$n.fragment"
	grep -qx "TWIN=$n: bench kernel twin (build/v9/kernel-config.$n.fragment md5 $(md5sum < "$f" | cut -d' ' -f1)); never a release until its arm passes (plan only: no image tree)" "$T/$n/VARIANT" \
		&& ok "$n: VARIANT's TWIN line names its fragment by md5" || no "$n: VARIANT's TWIN line: $(sed -n 3p "$T/$n/VARIANT")"
	grep -q 'PROFILE TWIN' "$T/$n/VARIANT" && no "$n: VARIANT says PROFILE TWIN" || ok "$n: not a profile twin"
done
refuse ud-nomemcg 'EX4_CMDLINE_ARM=nomemcg with EX4_TWIN=ud' EX4_TWIN=ud EX4_CMDLINE_ARM=nomemcg
refuse diet-nomemcg 'EX4_CMDLINE_ARM=nomemcg with EX4_TWIN=diet' EX4_TWIN=diet EX4_CMDLINE_ARM=nomemcg
refuse two-twins-plus 'EX4_TWIN: only' EX4_TWIN=uaccess+diet
refuse two-twins-space 'EX4_TWIN: only' "EX4_TWIN=uaccess diet"
refuse ud-plus-track 'EX4_TWIN: only' EX4_TWIN=ud+nfsdtrack
refuse UD 'EX4_TWIN: only' EX4_TWIN=UD
refuse ud-and-profile 'EX4_PROFILE=1 is the hits-only profile twin' EX4_PROFILE=1 EX4_TWIN=ud
refuse nfsdtrack-and-profile 'EX4_PROFILE=1 is the hits-only profile twin' EX4_PROFILE=1 EX4_TWIN=nfsdtrack

# ---- kernel-kind: the six marks, read from a kernel .config ----
# kc NAME LINE... : a .config with v9's six marks at their default ("is not set" / MEMCG=y) unless a LINE overrides one
kc() {
	n=$1; shift
	{
		printf '%s\n' "CONFIG_ARM=y" "# CONFIG_FUNCTION_TRACER is not set" "# CONFIG_FUNCTION_GRAPH_TRACER is not set" "# CONFIG_UACCESS_WITH_MEMCPY is not set" \
			"# CONFIG_JUMP_LABEL is not set" "CONFIG_MEMCG=y" "# CONFIG_NFSD_LEGACY_CLIENT_TRACKING is not set" | while read -r l; do
			s=$(printf '%s\n' "$l" | sed -E 's/^# //; s/[= ].*//'); o=
			for x in "$@"; do case "$x" in "$s="*|"# $s "*) o=$x;; esac; done
			printf '%s\n' "${o:-$l}"
		done
	} > "$T/$n.config"
}
kind() {
	n=$1; want=$2
	got=$(sh "$B" kernel-kind --config "$T/$n.config" 2> "$T/$n.kerr"); rc=$?
	if [ "$want" = REFUSE ]; then
		[ "$rc" != 0 ] && grep -q 'REFUSED: this image.s kernel is no kernel this script knows' "$T/$n.kerr" && ok "kernel-kind $n: refused" || no "kernel-kind $n: rc $rc '$got'"
	else
		[ "$rc" = 0 ] && [ "$got" = "$want" ] && ok "kernel-kind $n: $got" || no "kernel-kind $n: rc $rc '$got' $(cat "$T/$n.kerr"), want $want"
	fi
}
kc k-default;                                                                                   kind k-default default
kc k-prof CONFIG_FUNCTION_TRACER=y;                                                             kind k-prof prof
kc k-prof2 CONFIG_FUNCTION_TRACER=y CONFIG_FUNCTION_GRAPH_TRACER=y;                              kind k-prof2 prof2
kc k-uaccess CONFIG_UACCESS_WITH_MEMCPY=y;                                                      kind k-uaccess uaccess
kc k-diet CONFIG_JUMP_LABEL=y "# CONFIG_MEMCG is not set";                                      kind k-diet diet
kc k-ud CONFIG_UACCESS_WITH_MEMCPY=y CONFIG_JUMP_LABEL=y "# CONFIG_MEMCG is not set" CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y; kind k-ud ud
kc k-nfsdtrack CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y;                                            kind k-nfsdtrack nfsdtrack
# mixtures no twin is: uaccess+diet without the tracking line (not ud), diet+tracking, uaccess+tracking, ud + a tracer
kc x-ud-notrack CONFIG_UACCESS_WITH_MEMCPY=y CONFIG_JUMP_LABEL=y "# CONFIG_MEMCG is not set";  kind x-ud-notrack REFUSE
kc x-diet-track CONFIG_JUMP_LABEL=y "# CONFIG_MEMCG is not set" CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y; kind x-diet-track REFUSE
kc x-uaccess-track CONFIG_UACCESS_WITH_MEMCPY=y CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y;          kind x-uaccess-track REFUSE
kc x-ud-prof CONFIG_FUNCTION_TRACER=y CONFIG_UACCESS_WITH_MEMCPY=y CONFIG_JUMP_LABEL=y "# CONFIG_MEMCG is not set" CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y; kind x-ud-prof REFUSE
kc x-prof-track CONFIG_FUNCTION_TRACER=y CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y;                  kind x-prof-track REFUSE
sh "$B" kernel-kind > /dev/null 2> "$T/kk-noarg.err" && no "kernel-kind without --config accepted" || { grep -q 'REFUSED: kernel-kind: --config' "$T/kk-noarg.err" && ok "kernel-kind without --config: refused" || no "kernel-kind without --config: $(cat "$T/kk-noarg.err")"; }
# the overlay gate knows the same names (and only them)
python3 -I - "$TOP/build/v9/overlay-gate.py" > "$T/gate.out" 2>&1 <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location('gate', sys.argv[1]); g = importlib.util.module_from_spec(s); s.loader.exec_module(g)
good = ['ud', 'nfsdtrack', 'xoroff+ud', 'xoroff+nfsdtrack', 'nfsdtrack+nomemcg', 'xoroff+nfsdtrack+nomemcg', 'diet', 'uaccess', 'stock']
bad = ['ud+nomemcg', 'xoroff+ud+nomemcg', 'diet+ud', 'uaccess+diet', 'ud+nfsdtrack', 'nfsdtrack+ud', 'nfsdtrack+xoroff', 'prof+ud', 'UD', 'u d']
wrong = [v for v in good if not g.variant_ok(v)] + [v for v in bad if g.variant_ok(v)]
print("gate variant names:", "OK" if not wrong else "WRONG %r" % wrong)
sys.exit(1 if wrong else 0)
PY
[ $? = 0 ] && ok "overlay gate: $(cat "$T/gate.out")" || no "overlay gate: $(cat "$T/gate.out")"
echo "twin-variant-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
