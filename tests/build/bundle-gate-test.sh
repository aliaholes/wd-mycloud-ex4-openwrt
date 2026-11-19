#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# tests/build/bundle-gate-test.sh : THE BUNDLE GATE (build/v9/overlay-gate.py --bundle, v9.8; the v95 review's must_fix, the gate
# half). Synthetic bundles from tests/build/mkgatefix.py (no kernel, no EX4, no network). Every variant name is accepted on its own
# bundle (with and without --ref-kmods, and the overlay-only mode still passes); every refusal the must_fix names is proven, each
# on a bundle that differs from an accepted one in that ONE thing (MD5SUMS recomputed, so the refusal is the named check's):
# wrong --variant, a twin without VARIANT, VARIANT on stock, a RUNID suffix that is not the variant's, a kmod set that is not
# KMODS.txt's (and, with --ref-kmods, a diet / ud bundle on default kmods and a stock bundle on diet kmods), a twin VARIANT
# without kernel-config-md5, the command line, MD5SUMS, a foreign overlay, and variant names the scheme refuses.
# Needs: sh, python3. Exit 0 only if every case passes.   sh tests/build/bundle-gate-test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); G="$TOP/build/v9/overlay-gate.py"; F="$HERE/mkgatefix.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/ex4-bundle-gate.XXXXXX"); trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS  $*"; }
no() { fail=$((fail + 1)); echo "FAIL  $*"; }
python3 -I "$F" key "$T" || exit 1
python3 -I "$F" refkmods "$T/ref-kmods.txt" || exit 1
mk() { d=$1; v=$2; shift 2; python3 -I "$F" bundle "$T/$d" --variant "$v" --key "$T/key.pub" "$@" || no "fixture $d ($v) not built"; }
resum() { python3 -I "$F" md5sums "$T/$1"; }
# gate NAME BUNDLE VARIANT [extra args]: the gate with --bundle; rc into $T/NAME.rc, output into $T/NAME.out
gate() {
	n=$1; b=$2; v=$3; shift 3
	python3 -I "$G" "$T/$b/overlay.cpio" --pubkey "$T/key.pub" --no-webui --no-rwbench --variant "$v" --bundle "$T/$b" "$@" > "$T/$n.out" 2>&1
	echo $? > "$T/$n.rc"
}
accept() {
	n=$1; shift; gate "$n" "$@"
	[ "$(cat "$T/$n.rc")" = 0 ] && tail -1 "$T/$n.out" | grep -q '^overlay-gate: OK' && ok "$n: accepted" || no "$n: refused: $(grep '^FAIL' "$T/$n.out" | head -3 | tr '\n' ' ')"
}
# refuse NAME PATTERN BUNDLE VARIANT [extra]: refused, and the FAIL line names the check (PATTERN, grep -E)
refuse() {
	n=$1; pat=$2; shift 2; gate "$n" "$@"
	if [ "$(cat "$T/$n.rc")" != 0 ] && grep -E "^FAIL .*($pat)" "$T/$n.out" > /dev/null; then ok "$n: refused ($(grep '^FAIL' "$T/$n.out" | head -1 | cut -c1-150))"
	else no "$n: rc $(cat "$T/$n.rc"), want a FAIL matching '$pat': $(grep -E '^(FAIL|overlay-gate)' "$T/$n.out" | head -3 | tr '\n' ' ')"; fi
}

# ---- every variant name, on its own bundle: accepted (bundle mode, + --ref-kmods, and the overlay-only mode) ----
for v in stock xoroff nomemcg xoroff+nomemcg uaccess uaccess+nomemcg diet xoroff+diet ud xoroff+ud nfsdtrack nfsdtrack+nomemcg xoroff+nfsdtrack \
	prof prof2 xoroff+prof prof+nomemcg; do
	d=b-$(echo "$v" | tr + _); mk "$d" "$v"
	accept "acc-$d" "$d" "$v"
	accept "acc-ref-$d" "$d" "$v" --ref-kmods "$T/ref-kmods.txt"
	python3 -I "$G" "$T/$d/overlay.cpio" --pubkey "$T/key.pub" --no-webui --no-rwbench --variant "$v" > "$T/ovl-$d.out" 2>&1 \
		&& ! grep -q '^PASS  bundle:' "$T/ovl-$d.out" && ok "ovl-$d: the overlay-only mode (no --bundle) still passes, no bundle check runs" || no "ovl-$d: overlay-only mode: $(tail -1 "$T/ovl-$d.out")"
done
grep -q '^INFO  bundle: --ref-kmods: no kmod claim for the uaccess twin' "$T/acc-ref-b-uaccess.out" && ok "uaccess + --ref-kmods: an INFO line, no claim (its kmods may be byte-equal to the default's)" || no "uaccess + --ref-kmods: no INFO line"

# ---- WRONG VARIANT: the bundle says one thing, the gate is told another ----
refuse wrong-ud-as-diet 'VARIANT.s first line' b-ud diet
refuse wrong-diet-as-ud 'VARIANT.s first line' b-diet ud
refuse wrong-uaccess-as-stock 'stock carries no VARIANT' b-uaccess stock
refuse wrong-stock-as-uaccess 'VARIANT.s first line' b-stock uaccess
refuse wrong-nfsdtrack-as-stock 'stock carries no VARIANT' b-nfsdtrack stock
refuse wrong-ud-as-xoroff+ud 'VARIANT.s first line' b-ud xoroff+ud
refuse wrong-xoroff+ud-as-ud 'VARIANT.s first line' b-xoroff_ud ud
refuse wrong-prof2-as-prof 'VARIANT.s first line' b-prof2 prof
refuse wrong-nomemcg-as-stock 'stock carries no VARIANT' b-nomemcg stock
refuse wrong-ud-as-uaccess 'VARIANT.s first line' b-ud uaccess

# ---- VARIANT ----
mk t-novariant ud; rm "$T/t-novariant/VARIANT"; resum t-novariant
refuse twin-without-variant 'NO VARIANT FILE' t-novariant ud
mk t-novariant-nf nfsdtrack; rm "$T/t-novariant-nf/VARIANT"; resum t-novariant-nf
refuse nfsdtrack-without-variant 'NO VARIANT FILE' t-novariant-nf nfsdtrack
mk s-variant stock; printf 'VARIANT=stock\nXOR=on\n' > "$T/s-variant/VARIANT"; resum s-variant
refuse stock-with-variant 'stock carries no VARIANT' s-variant stock
mk t-nomd5 ud; sed -i '/^kernel-config-md5=/d' "$T/t-nomd5/VARIANT"; resum t-nomd5
refuse twin-variant-without-kmd5 'kernel-config-md5' t-nomd5 ud
mk t-badmd5 diet; sed -i 's/^kernel-config-md5=.*/kernel-config-md5=not-an-md5/' "$T/t-badmd5/VARIANT"; resum t-badmd5
refuse twin-variant-bad-kmd5 'kernel-config-md5' t-badmd5 diet
mk t-2md5 nfsdtrack; grep '^kernel-config-md5=' "$T/t-2md5/VARIANT" | sed 's/=./=0/' >> "$T/t-2md5/VARIANT"; resum t-2md5
refuse twin-variant-two-kmd5 'kernel-config-md5' t-2md5 nfsdtrack
mk t-xor xoroff+ud; sed -i 's/^XOR=off$/XOR=on/' "$T/t-xor/VARIANT"; resum t-xor
refuse variant-xor-line 'XOR line' t-xor xoroff+ud
mk t-twinline ud; sed -i 's/^TWIN=ud:/TWIN=diet:/' "$T/t-twinline/VARIANT"; resum t-twinline
refuse variant-twin-line 'TWIN= line' t-twinline ud
mk t-profline prof2; sed -i '/^PROFILE TWIN: never ship$/d' "$T/t-profline/VARIANT"; resum t-profline
refuse variant-profile-line 'PROFILE TWIN' t-profline prof2
mk t-carm nfsdtrack+nomemcg; sed -i '/^CMDLINE_ARM=/d' "$T/t-carm/VARIANT"; resum t-carm
refuse variant-cmdline-arm-line 'CMDLINE_ARM line' t-carm nfsdtrack+nomemcg

# ---- RUNID ----
mk r-ud-diet ud --runid 16-l2off-20261118-1300-diet; resum r-ud-diet
refuse runid-ud-says-diet 'RUNID' r-ud-diet ud
mk r-stock-ud stock --runid 16-l2off-20261118-1300-ud
refuse runid-stock-says-ud 'RUNID' r-stock-ud stock
mk r-ud-none ud --runid 16-l2off-20261118-1300
refuse runid-twin-without-suffix 'RUNID' r-ud-none ud
mk r-ud-extra ud --runid 16-l2off-20261118-1300-diet-ud
refuse runid-extra-token 'RUNID' r-ud-extra ud
mk r-order xoroff+nfsdtrack --runid 16-l2off-20261118-1300-nfsdtrack-xoroff
refuse runid-token-order 'RUNID' r-order xoroff+nfsdtrack
mk r-garbage ud --runid ud
refuse runid-no-base 'RUNID' r-garbage ud
mk r-2lines nfsdtrack; printf '16-l2off-20261118-1300-nfsdtrack\nmore\n' > "$T/r-2lines/RUNID"; resum r-2lines
refuse runid-two-lines 'RUNID' r-2lines nfsdtrack
mk r-atag nfsdtrack; printf '16-l2off-20261118-1301-nfsdtrack\n' > "$T/r-atag/RUNID"; resum r-atag
refuse runid-not-the-atag-token 'atags.bin' r-atag nfsdtrack

# ---- the command line (atags.bin) ----
mk c-nomemcg nomemcg
python3 -I - "$T/c-nomemcg/atags.bin" <<'PY'
import struct, sys
c = b'console=ttyS0,115200n8 watchdog.open_timeout=120 ex4boot_run=16-l2off-20261118-1300-nomemcg\0'
c += b'\0' * ((-len(c)) % 4)
open(sys.argv[1], 'wb').write(struct.pack('<IIIII', 5, 0x54410001, 0, 4096, 0) + struct.pack('<II', 2 + len(c) // 4, 0x54410009) + c + struct.pack('<II', 0, 0))
PY
resum c-nomemcg
refuse nomemcg-without-cgroup-word 'atags.bin' c-nomemcg nomemcg
mk c-stockarm stock; cp "$T/b-nomemcg/atags.bin" "$T/c-stockarm/atags.bin"; resum c-stockarm
refuse stock-with-cgroup-word 'atags.bin' c-stockarm stock

# ---- the kmod set ----
mk k-md5 ud; sed -i '0,/xhci-pci.ko$/s/^[0-9a-f]\{32\}\(  .*xhci-pci.ko\)$/00000000000000000000000000000000\1/' "$T/k-md5/KMODS.txt"; resum k-md5
refuse kmods-md5-differs 'KMODS.txt' k-md5 ud
mk k-missing diet; sed -i '/xhci-plat-hcd.ko$/d' "$T/k-missing/KMODS.txt"; resum k-missing
refuse kmods-overlay-has-one-unlisted 'KMODS.txt' k-missing diet
mk k-extra ud; echo "0123456789abcdef0123456789abcdef  ./lib/modules/6.12.112/extra.ko" >> "$T/k-extra/KMODS.txt"; resum k-extra
refuse kmods-listed-not-in-overlay 'KMODS.txt' k-extra ud
mk k-diet-default diet --kmods default
accept kmods-diet-on-default-no-ref k-diet-default diet
refuse kmods-diet-on-default-kmods 'share no md5' k-diet-default diet --ref-kmods "$T/ref-kmods.txt"
mk k-ud-default ud --kmods default
refuse kmods-ud-on-default-kmods 'share no md5' k-ud-default ud --ref-kmods "$T/ref-kmods.txt"
mk k-stock-diet stock --kmods diet
refuse kmods-stock-on-diet-kmods 'default kernel.s kmods' k-stock-diet stock --ref-kmods "$T/ref-kmods.txt"
mk k-nomemcg-diet nomemcg --kmods diet
refuse kmods-nomemcg-on-diet-kmods 'default kernel.s kmods' k-nomemcg-diet nomemcg --ref-kmods "$T/ref-kmods.txt"
mk k-prof-default prof --kmods default
refuse kmods-prof-uninstrumented 'ftrace-instrumented' k-prof-default prof

# ---- MD5SUMS, the overlay, the arguments ----
mk m-edit ud; echo "TWIN=ud: edited after MD5SUMS" >> "$T/m-edit/VARIANT"
refuse md5sums-variant-edited-after 'MD5SUMS' m-edit ud
mk m-unlisted ud; sed -i '/  VARIANT$/d' "$T/m-unlisted/MD5SUMS"
refuse md5sums-variant-not-listed 'MD5SUMS' m-unlisted ud
mk o-foreign ud
python3 -I "$G" "$T/b-ud/overlay.cpio" --pubkey "$T/key.pub" --no-webui --no-rwbench --variant ud --bundle "$T/o-foreign" > "$T/o-foreign.out" 2>&1
[ $? != 0 ] && grep -q "^FAIL  bundle: the gated overlay is the bundle's own" "$T/o-foreign.out" && ok "foreign-overlay: refused (the gated overlay is not the bundle's)" || no "foreign-overlay: not refused"
for v in ud+nomemcg diet+nomemcg diet+ud uaccess+diet ud+nfsdtrack nfsdtrack+xoroff nomemcg+ud UD 'uaccess diet' stock+ud; do
	python3 -I "$G" "$T/b-ud/overlay.cpio" --pubkey "$T/key.pub" --no-webui --no-rwbench --variant "$v" --bundle "$T/b-ud" > "$T/badname.out" 2>&1
	[ $? != 0 ] && ! grep -q '^PASS' "$T/badname.out" && ok "variant name '$v': refused before any check" || no "variant name '$v' accepted"
done
python3 -I "$G" "$T/b-ud/overlay.cpio" --pubkey "$T/key.pub" --no-webui --no-rwbench --variant ud --ref-kmods "$T/ref-kmods.txt" > "$T/refonly.out" 2>&1
[ $? != 0 ] && ! grep -q '^PASS' "$T/refonly.out" && ok "--ref-kmods without --bundle: refused (usage)" || no "--ref-kmods without --bundle accepted"
echo "bundle-gate-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
