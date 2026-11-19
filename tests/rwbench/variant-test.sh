#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# variant-test.sh (v9.8, the v95 review's must_fix, the test half) : THE VARIANT WALL of tests/rwbench/patch-test.sh against tiny
# fake bundles (a RUNID file and, for a twin, a VARIANT file written the way build/v9/build-v9.sh writes them; nothing else).
# The v97 assembler's gate matrix accepted bwd / bwu / bwn under `--variant stock` and each other's names, and bwp2 as prof:
# here each fake bundle is tried under every variant name and must be taken ONLY under its own (an accepted cell runs the rest
# of patch-test without --rootfs: the tree's mkoverlay compiles, build-v9.sh parses, ex4fan builds native), plus the edge
# cases: no VARIANT= line, VARIANT=stock, a symlinked VARIANT, a RUNID suffix that disagrees, no RUNID, --variant without --bundle.
#   bash tests/rwbench/variant-test.sh --work DIR      (no root, no network, no device; needs gcc for the accepted cells)
set -u
WORK=
while [ $# -gt 0 ]; do case "$1" in --work) WORK=$2;; *) sed -n '9p' "$0" >&2; exit 64;; esac; shift 2; done
[ -n "$WORK" ] && [ ! -e "$WORK" ] || { echo "REFUSED: --work must be a NEW folder" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); PT=$HERE/patch-test.sh
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd); B=$WORK/bundles
P=0; F=0
ok() { P=$((P + 1)); echo "PASS  $*"; }
bad() { F=$((F + 1)); echo "FAIL  $*"; }
mkb() {          # $1 = name, $2 = RUNID, $3 = VARIANT value ('' = no VARIANT file = stock)
	mkdir -p "$B/$1"; printf '%s\n' "$2" > "$B/$1/RUNID"
	[ -n "$3" ] && printf 'VARIANT=%s\nXOR=on\nTWIN=fake (variant-test)\n' "$3" > "$B/$1/VARIANT"; return 0
}
R=16-l2off-20261118-0137
mkb bw "$R" ''; mkb bwu "$R-uaccess" uaccess; mkb bwd "$R-diet" diet; mkb bwp2 "$R-prof2" prof2; mkb bwn "$R-nomemcg" nomemcg
mkb bwxd "$R-xoroff-diet" xoroff+diet
N=0
run() {          # $1 = expect ok|refuse, $2 = why, $3 = what the refusal must say ('' = any), rest = patch-test args (after --work)
	local want=$1 why=$2 say=$3 w rc; shift 3; N=$((N + 1)); w=$WORK/w$N
	bash "$PT" --work "$w" "$@" > "$WORK/out$N.txt" 2>&1; rc=$?
	if [ "$want" = ok ]; then
		if [ $rc = 0 ] && grep -q "^PASS  THE VARIANT WALL: " "$WORK/out$N.txt"; then ok "$why: taken (rc 0, the wall's PASS line)"; else bad "$why: wanted taken, rc $rc ($(grep -m1 -E 'REFUSED|FAIL' "$WORK/out$N.txt"))"; fi
	else
		if [ $rc = 1 ] && grep -q "^REFUSED: variant: " "$WORK/out$N.txt" && { [ -z "$say" ] || grep -q -- "$say" "$WORK/out$N.txt"; } && [ ! -e "$w" ]; then
			ok "$why: REFUSED before anything ran (no work folder made): $(grep -m1 '^REFUSED' "$WORK/out$N.txt" | cut -c1-140)"
		else bad "$why: wanted REFUSED (variant), rc $rc, work folder $([ -e "$w" ] && echo made || echo absent): $(head -2 "$WORK/out$N.txt" | tr '\n' ' ' | cut -c1-200)"; fi
	fi
}
own() { case $1 in bw) echo stock;; bwu) echo uaccess;; bwd) echo diet;; bwp2) echo prof2;; bwn) echo nomemcg;; esac; }
# the assembler's matrix: every fake bundle under every name; only its own is taken
for b in bw bwu bwd bwp2 bwn; do
	for v in stock xoroff prof uaccess diet prof2 nomemcg; do
		if [ "$v" = "$(own $b)" ]; then run ok "matrix $b --variant $v (its own)" '' --bundle "$B/$b" --variant "$v"
		else run refuse "matrix $b --variant $v" '' --bundle "$B/$b" --variant "$v"; fi
	done
done
# the review's named cells, each with the reason it must give
run refuse "bwd (diet) as stock" "a twin is never tested as stock" --bundle "$B/bwd" --variant stock
run refuse "bwu (uaccess) as diet" "VARIANT file says VARIANT=uaccess" --bundle "$B/bwu" --variant diet
run refuse "bwp2 (prof2) as prof" "VARIANT file says VARIANT=prof2" --bundle "$B/bwp2" --variant prof
run refuse "a twin with NO --variant (the v9.7 'unmarked' gap)" "no --variant was given: pass --variant diet" --bundle "$B/bwd"
run refuse "a stock bundle as uaccess" "has no VARIANT file (a stock bundle)" --bundle "$B/bw" --variant uaccess
run ok "a stock bundle with no --variant (the v9.4 call)" '' --bundle "$B/bw"
run ok "xoroff+diet under its own name" '' --bundle "$B/bwxd" --variant xoroff+diet
run refuse "xoroff+diet as diet (half of it)" "VARIANT file says VARIANT=xoroff+diet" --bundle "$B/bwxd" --variant diet
run refuse "xoroff+diet as xoroff" "VARIANT file says VARIANT=xoroff+diet" --bundle "$B/bwxd" --variant xoroff
# edge cases of the files themselves
mkb noline "$R-diet" ''; printf 'XOR=on\nTWIN=diet without its VARIANT= line\n' > "$B/noline/VARIANT"
run refuse "a VARIANT file with no VARIANT= line" "has no VARIANT= line" --bundle "$B/noline" --variant diet
mkb vstock "$R" stock
run refuse "a VARIANT file saying VARIANT=stock" "never writes a VARIANT file for stock" --bundle "$B/vstock" --variant stock
mkb vlink "$R-diet" ''; ln -s "$B/bwd/VARIANT" "$B/vlink/VARIANT"
run refuse "a symlinked VARIANT file" "is a symlink" --bundle "$B/vlink" --variant diet
mkb rmis "$R-uaccess" diet
run refuse "VARIANT=diet but the RUNID ends -uaccess" "wants '-diet'" --bundle "$B/rmis" --variant diet
mkb rnosuf "$R" diet
run refuse "VARIANT=diet but the RUNID has no suffix" "wants '-diet'" --bundle "$B/rnosuf" --variant diet
mkb sdiet "$R-diet" ''
run refuse "no VARIANT file (stock) but the RUNID ends -diet" "carries a variant suffix" --bundle "$B/sdiet" --variant stock
mkdir -p "$B/norid"; printf 'VARIANT=diet\n' > "$B/norid/VARIANT"
run refuse "no RUNID file" "has no RUNID file" --bundle "$B/norid" --variant diet
mkb rodd "11-l2off-test" ''
run refuse "a RUNID not in the builder's form" "not in the builder's form" --bundle "$B/rodd"
run refuse "--variant uaccess without --bundle" "without --bundle" --variant uaccess
run refuse "--bundle that is not a folder" "is not a folder" --bundle "$B/missing" --variant stock
run ok "--variant stock on the stock bundle" '' --bundle "$B/bw" --variant stock
echo "== variant-test: $P passed, $F failed"; [ $F = 0 ]
