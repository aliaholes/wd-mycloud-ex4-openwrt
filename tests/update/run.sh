#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# tests/update/run.sh : the update path, off the box. The box half (update/box/ex4-update) runs under qemu-arm on
# the IMAGE'S OWN busybox ash, usign, sha256sum, tar and uclient-fetch (from the built OpenWrt tree), fetching
# over real HTTP from tests/update/srv.py on 127.0.0.1. The host half (mkrelease.py, usignpy.py, cvewatch.py)
# runs as it would on the build box.
#
#   bash tests/update/run.sh --work W --tree OPENWRT_WORK [--bundle REAL_BUNDLE --real-key SEC] [--watch-replay DIR]
#     W             scratch, must not exist (everything the test makes stays in it)
#     OPENWRT_WORK  build-v7.sh's work folder (W/openwrt is ONLY READ: its rootfs gives the box's programs, its
#                   tree the SBOM, its host usign the signer)
#     REAL_BUNDLE + SEC   also make a release of a real bundle with the real key and stage it on an emulated box
#                         that holds only update/keys/ex4-release.pub (the end-to-end "good release" case)
#     --watch-replay      a folder recorded by `cvewatch.py --record` on that real release: replayed, no network
#     --watch-release DIR (v9) the signed release the recording was made on, when it is not the one this run signs
#                         (the replay is keyed by the exact OSV request bodies, so it only answers for THAT SBOM; v9
#                         replays the v7 release's live run: also proves this cvewatch reads a pre-v9 RELEASE)
#     --stage-release DIR (v9) an already signed release (the deliverable): staged --from DIR on an emulated box that
#                         holds only update/keys/ex4-release.pub, and checked on a box that already runs its serial
# Exit 0 = every case passed. Never touches an EX4, never runs as root, installs nothing.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); U=$TOP/update
W=; TREE=; RB=; RK=; REPLAY=; WREL=; SREL=; PORT=${PORT:-18491}
while [ $# -gt 0 ]; do case "$1" in --work) W=$2; shift 2;; --tree) TREE=$2; shift 2;; --bundle) RB=$2; shift 2;;
	--real-key) RK=$2; shift 2;; --watch-replay) REPLAY=$2; shift 2;; --watch-release) WREL=$2; shift 2;; --stage-release) SREL=$2; shift 2;; *) echo "usage: see header" >&2; exit 64;; esac; done
[ "$(id -u)" != 0 ] || { echo "REFUSED: never as root" >&2; exit 1; }
[ -n "$W" ] && [ ! -e "$W" ] || { echo "REFUSED: --work must name a folder that does not exist" >&2; exit 1; }
O=$TREE/openwrt; ROOTFS=$(ls -d "$O"/build_dir/target-*/root-kirkwood 2>/dev/null)
[ -x "$ROOTFS/usr/bin/usign" ] && [ -x "$O/staging_dir/host/bin/usign" ] || { echo "REFUSED: $TREE is not a built tree" >&2; exit 1; }
QEMU=$(command -v qemu-arm) || { echo "SKIP: no qemu-arm" >&2; exit 77; }
mkdir -p "$W" && W=$(cd "$W" && pwd)
UH=$O/staging_dir/host/bin/usign
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "PASS  $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL  $*"; }
py()   { python3 -I "$@"; }

# ---- the box's programs: thin wrappers that run the IMAGE's binaries under qemu-arm
TB=$W/toolbin; mkdir -p "$TB"
for a in awk cat chmod cp cut date find grep head ls mkdir mv rm rmdir sed sha256sum sort tail tar tr uniq wc; do
	printf '#!/bin/sh\nexec "%s" -L "%s" "%s/bin/busybox" %s "$@"\n' "$QEMU" "$ROOTFS" "$ROOTFS" "$a" > "$TB/$a"
done
printf '#!/bin/sh\nexec "%s" -L "%s" "%s/usr/bin/usign" "$@"\n' "$QEMU" "$ROOTFS" "$ROOTFS" > "$TB/usign"
printf '#!/bin/sh\nexec "%s" -L "%s" "%s/bin/uclient-fetch" "$@"\n' "$QEMU" "$ROOTFS" "$ROOTFS" > "$TB/uclient-fetch"
chmod 755 "$TB"/*
BOXSH() { env -i PATH="$TB" EX4_UPDATE_ROOT="$1" "$QEMU" -L "$ROOTFS" "$ROOTFS/bin/busybox" sh "$U/box/ex4-update" "${@:2}"; }

# ---- keys: TEST (the box in most cases trusts this one) and WRONG (never trusted)
mkdir -m 700 "$W/keys"
"$UH" -G -s "$W/keys/test.sec" -p "$W/keys/test.pub" -c "EX4 update TEST key (tests only)" > /dev/null
"$UH" -G -s "$W/keys/wrong.sec" -p "$W/keys/wrong.pub" -c "EX4 update WRONG key (tests only)" > /dev/null
chmod 600 "$W/keys"/*.sec
TFP=$("$UH" -F -p "$W/keys/test.pub")

# ---- 1. usignpy: the RFC vectors, and agreement with OpenWrt's usign both ways
py "$U/usignpy.py" selftest > "$W/usignpy-selftest.log" 2>&1 && ok "usignpy: RFC 8032 vectors ($(grep -c PASS "$W/usignpy-selftest.log") lines)" || bad "usignpy selftest: $(cat "$W/usignpy-selftest.log")"
head -c 5000 /dev/urandom > "$W/msg"; "$UH" -S -m "$W/msg" -s "$W/keys/test.sec" -x "$W/msg.sig"
py "$U/usignpy.py" verify "$W/keys/test.pub" "$W/msg" "$W/msg.sig" > /dev/null && ok "usignpy accepts a signature usign made" || bad "usignpy rejects usign's signature"
cp "$W/msg" "$W/msg2"; printf 'x' | dd of="$W/msg2" bs=1 seek=100 conv=notrunc 2> /dev/null
py "$U/usignpy.py" verify "$W/keys/test.pub" "$W/msg2" "$W/msg.sig" > /dev/null && bad "usignpy accepts a changed message" || ok "usignpy refuses a changed message"
py "$U/usignpy.py" verify "$W/keys/wrong.pub" "$W/msg" "$W/msg.sig" > "$W/o" ; grep -q 'not by key' "$W/o" && ok "usignpy refuses the wrong key by key number" || bad "usignpy wrong key: $(cat "$W/o")"
[ "$(py "$U/usignpy.py" fingerprint "$W/keys/test.pub")" = "$TFP" ] && ok "usignpy's fingerprint = usign -F ($TFP)" || bad "fingerprint differs"

# ---- 2. mkrelease: its walls, then a small good release (a 3-file fixture bundle, so qemu's sha256 is quick)
FB=$W/fixture-bundle; mkdir "$FB"
head -c 300000 /dev/urandom > "$FB/kernel.bin"; head -c 70000 /dev/urandom > "$FB/overlay.cpio"; printf '10-test\n' > "$FB/RUNID"
( cd "$FB" && md5sum kernel.bin overlay.cpio RUNID > MD5SUMS )
MK() { py "$U/mkrelease.py" release --work "$TREE" --bundle "$FB" --usign "$UH" --built 2026-11-17T23:00:00Z "$@"; }
cp "$W/keys/test.sec" "$W/keys/loose.sec"; chmod 644 "$W/keys/loose.sec"
MK --version t1 --serial 200 --key "$W/keys/loose.sec" --pub "$W/keys/test.pub" --allow-test-key --out "$W/r-x1" > "$W/o" 2>&1
grep -q 'must be 0600' "$W/o" && [ ! -e "$W/r-x1" ] && ok "mkrelease refuses a key that is not 0600" || bad "mkrelease 0644 key: $(tail -1 "$W/o")"
MK --version t1 --serial 200 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --out "$W/r-x2" > "$W/o" 2>&1
grep -q 'not the key the image ships' "$W/o" && ok "mkrelease refuses a key that is not update/keys/ex4-release.pub (without --allow-test-key)" || bad "mkrelease foreign key: $(tail -1 "$W/o")"
MK --version 't/1' --serial 200 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --allow-test-key --out "$W/r-x3" > "$W/o" 2>&1
grep -q -- '--version must' "$W/o" && ok "mkrelease refuses a version with a slash" || bad "mkrelease version: $(tail -1 "$W/o")"
MK --version t1 --serial 0200 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --allow-test-key --out "$W/r-x4" > "$W/o" 2>&1
grep -q -- '--serial must' "$W/o" && ok "mkrelease refuses serial 0200 (no leading zero)" || bad "mkrelease serial: $(tail -1 "$W/o")"
cp -a "$FB" "$W/fb-bad"; printf 'z' >> "$W/fb-bad/RUNID"
py "$U/mkrelease.py" release --work "$TREE" --bundle "$W/fb-bad" --usign "$UH" --built 2026-11-17T23:00:00Z --version t1 --serial 200 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --allow-test-key --out "$W/r-x5" > "$W/o" 2>&1
grep -q 'md5 does not match' "$W/o" && ok "mkrelease refuses a bundle whose MD5SUMS do not check" || bad "mkrelease bad bundle: $(tail -1 "$W/o")"
# v9.7: a bench-only bundle (VARIANT file: xor-off / profile twin / cmdline arm) never becomes a release, listed in MD5SUMS or not
cp -a "$FB" "$W/fb-var"; printf 'VARIANT=prof\nPROFILE TWIN: never ship\n' > "$W/fb-var/VARIANT"; ( cd "$W/fb-var" && md5sum kernel.bin overlay.cpio RUNID VARIANT > MD5SUMS )
py "$U/mkrelease.py" release --work "$TREE" --bundle "$W/fb-var" --usign "$UH" --built 2026-11-17T23:00:00Z --version t1 --serial 200 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --allow-test-key --out "$W/r-xv1" > "$W/o" 2>&1
grep -q 'carries a VARIANT file' "$W/o" && [ ! -e "$W/r-xv1" ] && ok "mkrelease refuses a bundle with a VARIANT file named in its MD5SUMS (bench-only; nothing written)" || bad "mkrelease VARIANT listed: $(tail -1 "$W/o")"
cp -a "$FB" "$W/fb-var2"; printf 'VARIANT=xoroff\n' > "$W/fb-var2/VARIANT"
py "$U/mkrelease.py" release --work "$TREE" --bundle "$W/fb-var2" --usign "$UH" --built 2026-11-17T23:00:00Z --version t1 --serial 200 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --allow-test-key --out "$W/r-xv2" > "$W/o" 2>&1
grep -q 'carries a VARIANT file' "$W/o" && [ ! -e "$W/r-xv2" ] && ok "mkrelease refuses a bundle with a VARIANT file even when MD5SUMS does not name it" || bad "mkrelease VARIANT unlisted: $(tail -1 "$W/o")"
cp -a "$FB" "$W/fb-var3"; ln -s RUNID "$W/fb-var3/VARIANT"
py "$U/mkrelease.py" release --work "$TREE" --bundle "$W/fb-var3" --usign "$UH" --built 2026-11-17T23:00:00Z --version t1 --serial 200 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --allow-test-key --out "$W/r-xv3" > "$W/o" 2>&1
grep -q 'carries a VARIANT file' "$W/o" && [ ! -e "$W/r-xv3" ] && ok "mkrelease refuses a bundle whose VARIANT is a symlink" || bad "mkrelease VARIANT symlink: $(tail -1 "$W/o")"
MK --version t1 --serial 200 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --allow-test-key --out "$W/rel-good" > "$W/mk-good.log" 2>&1 \
	&& ok "mkrelease: a test release ($(cut -c1-150 "$W/mk-good.log"))" || { bad "mkrelease good: $(cat "$W/mk-good.log")"; exit 1; }
MK --version t1 --serial 200 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --allow-test-key --out "$W/rel-good" > "$W/o" 2>&1
grep -q 'exists' "$W/o" && ok "mkrelease never overwrites" || bad "mkrelease overwrote"
grep -q '^channel test$' "$W/rel-good/RELEASE" && ok "a release signed by a test key says channel test" || bad "channel of a test release"
py "$U/mkrelease.py" release --work "$TREE" --bundle "$FB" --usign "$UH" --built 2026-11-17T23:00:00Z --version t1 --serial 200 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --allow-test-key --out "$W/rel-good2" > /dev/null 2>&1
cmp -s "$W/rel-good/RELEASE" "$W/rel-good2/RELEASE" && cmp -s "$W/rel-good/sbom.cdx.json" "$W/rel-good2/sbom.cdx.json" && cmp -s "$W/rel-good/ex4-t1.tar" "$W/rel-good2/ex4-t1.tar" \
	&& ok "mkrelease is reproducible (same inputs: RELEASE, SBOM and payload byte-identical)" || bad "mkrelease not reproducible"

MK --version t1 --serial 200 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --allow-test-key --valid-days 0 --out "$W/r-x6" > "$W/o" 2>&1
grep -q -- '--valid-days must be 1..366' "$W/o" && [ ! -e "$W/r-x6" ] && ok "mkrelease refuses --valid-days 0 (v9)" || bad "mkrelease valid-days 0: $(tail -1 "$W/o")"
MK --version t1 --serial 200 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --allow-test-key --valid-days 367 --out "$W/r-x7" > "$W/o" 2>&1
grep -q -- '--valid-days must be 1..366' "$W/o" && ok "mkrelease refuses --valid-days 367 (no release vouches for itself past a year)" || bad "mkrelease valid-days 367: $(tail -1 "$W/o")"
MK --version t1 --serial 200 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --allow-test-key --successor "$W/keys/test.pub" --out "$W/r-x8" > "$W/o" 2>&1
grep -q -- '--successor is the signing key itself' "$W/o" && ok "mkrelease refuses a successor that is the signing key itself" || bad "mkrelease successor self: $(tail -1 "$W/o")"
NA=$(awk '$1 == "not-after" { print $2 " " $3 }' "$W/rel-good/RELEASE")
[ "$NA" = "$(python3 -c 'import calendar,time; e=calendar.timegm(time.strptime("2026-11-17T23:00:00Z","%Y-%m-%dT%H:%M:%SZ"))+90*86400; print(e, time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e)))')" ] \
	&& ok "RELEASE carries not-after = built + 90 days by default, as epoch AND ISO ($NA)" || bad "not-after line: '$NA'"
py "$U/mkrelease.py" ident --version 2026.11.18-v8 --serial 2026111801 --openwrt 25.12.6 --kernel 6.12.112 --channel trial --out "$W/ident.txt" \
	&& [ "$(head -1 "$W/ident.txt")" = "board=wd,mycloud-ex4" ] && grep -qx 'serial=2026111801' "$W/ident.txt" && ok "mkrelease ident: /etc/ex4-release with the DTS's board" || bad "ident"
py "$U/mkrelease.py" ident --version v8 --serial 1 --openwrt 25.12.6 --kernel 6.12.112 --channel test --out "$W/ident2.txt" > /dev/null 2>&1 \
	&& bad "ident accepted channel test (an image must never be channel test)" || ok "mkrelease ident refuses channel test for an image"

# ---- 3. the bad releases
for v in tamper-release tamper-payload truncate-payload unsigned wrong-board serial:100 channel:stable unknown-line no-end huge-release extra-member symlink-member dotdot-member; do
	py "$HERE/craft.py" "$v" "$W/rel-good" "$W/rel-${v/:/-}" --usign "$UH" --key "$W/keys/test.sec" || bad "craft $v"
done
mkdir "$W/rel-wrongkey"; cp "$W/rel-good"/* "$W/rel-wrongkey/"; "$UH" -S -m "$W/rel-wrongkey/RELEASE" -s "$W/keys/wrong.sec" -x "$W/rel-wrongkey/RELEASE.sig"
# v9: the clock and the expiry, each re-signed with the test key (so the expiry wall, not the signature, refuses)
ep() { python3 -c 'import calendar,sys,time; print(calendar.timegm(time.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ")))' "$1"; }
CR() { py "$HERE/craft.py" "$1" "$2" "$3" --usign "$UH" --key "$W/keys/test.sec" || bad "craft $1"; }
CR "line:built:2026-01-01T00:00:00Z" "$W/rel-good" "$W/rel-t1"; CR "line:not-after:$(ep 2026-02-01T00:00:00Z) 2026-02-01T00:00:00Z" "$W/rel-t1" "$W/rel-expired"
CR "line:built:2030-01-01T00:00:00Z" "$W/rel-good" "$W/rel-t2"; CR "line:not-after:$(ep 2030-02-01T00:00:00Z) 2030-02-01T00:00:00Z" "$W/rel-t2" "$W/rel-future"
CR "drop:not-after" "$W/rel-good" "$W/rel-noexpiry"
CR "line:not-after:$(ep 2027-01-02T00:00:00Z) 2027-01-01T00:00:00Z" "$W/rel-good" "$W/rel-namismatch"
CR "line:not-after:$(ep 2028-04-01T00:00:00Z) 2028-04-01T00:00:00Z" "$W/rel-good" "$W/rel-toolong"
CR "line:not-after:$(ep 2026-11-17T22:00:00Z) 2026-11-17T22:00:00Z" "$W/rel-good" "$W/rel-nabefore"
# v9: the key rotation: NEXT is named as the successor by a release the TEST key signs
"$UH" -G -s "$W/keys/next.sec" -p "$W/keys/next.pub" -c "EX4 update NEXT key (tests only)" > /dev/null; chmod 600 "$W/keys/next.sec"
NFP=$("$UH" -F -p "$W/keys/next.pub")
MK --version t3 --serial 300 --key "$W/keys/test.sec" --pub "$W/keys/test.pub" --allow-test-key --successor "$W/keys/next.pub" --out "$W/rel-succ" > "$W/mk-succ.log" 2>&1 \
	&& grep -q "^successor $NFP [A-Za-z0-9+/]\{56\}\$" "$W/rel-succ/RELEASE" && ok "mkrelease --successor: RELEASE names key $NFP (its key number + 56 base64)" || bad "mkrelease successor: $(cat "$W/mk-succ.log")"
MK --version t4 --serial 400 --key "$W/keys/next.sec" --pub "$W/keys/next.pub" --allow-test-key --out "$W/rel-next" > /dev/null 2>&1 || bad "mkrelease rel-next"
CR "add:successor 0123456789abcdef $(sed -n 2p "$W/keys/next.pub")" "$W/rel-good" "$W/rel-succ-badnum"
CR "line:serial:100" "$W/rel-succ" "$W/rel-succ-downgrade"
mkdir "$W/rel-succ-wrongkey"; cp "$W/rel-succ"/* "$W/rel-succ-wrongkey/"; "$UH" -S -m "$W/rel-succ-wrongkey/RELEASE" -s "$W/keys/wrong.sec" -x "$W/rel-succ-wrongkey/RELEASE.sig"
CR "line:built:2026-01-01T00:00:00Z" "$W/rel-succ" "$W/rel-st"; CR "line:not-after:$(ep 2026-02-01T00:00:00Z) 2026-02-01T00:00:00Z" "$W/rel-st" "$W/rel-succ-expired"

# ---- 4. an emulated box: its identity, its device tree, its RAM, its key folder (the key file named by its fingerprint)
mkbox() {	# mkbox NAME SERIAL CHANNEL [BOARD] [PUBKEY]
	local b=$W/box-$1; mkdir -p "$b/etc/ex4-update/keys" "$b/proc/device-tree" "$b/tmp"
	local pub=${5:-$W/keys/test.pub}; cp "$pub" "$b/etc/ex4-update/keys/$("$UH" -F -p "$pub")"
	printf 'board=%s\nversion=v-%s\nserial=%s\nchannel=%s\nopenwrt=25.12.6\nkernel=6.12.112\n' "${4:-wd,mycloud-ex4}" "$2" "$2" "$3" > "$b/etc/ex4-release"
	printf '%s\0marvell,kirkwood-88f6282\0marvell,kirkwood\0' "${4:-wd,mycloud-ex4}" > "$b/proc/device-tree/compatible"
	printf 'MemTotal:         512000 kB\nMemFree:          400000 kB\nMemAvailable:     420000 kB\n' > "$b/proc/meminfo"
	echo "$b"
}
BOX=$(mkbox main 150 test)
SRVD=$W/srv; mkdir "$SRVD"
srv_start() { python3 -I "$HERE/srv.py" --dir "$SRVD" --port "$PORT" --log "$W/srv.log" "$@" & SRVPID=$!; for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.3; (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; done; }
srv_stop() { [ -n "${SRVPID:-}" ] && { kill "$SRVPID" 2>/dev/null; wait "$SRVPID" 2>/dev/null; }; SRVPID=; }
trap 'srv_stop' EXIT
serve() { rm -rf "$SRVD"; mkdir "$SRVD"; cp -a "$1"/. "$SRVD"/; }
URL=http://127.0.0.1:$PORT
staged_n() { ls "$BOX/tmp/ex4-update/staged" 2>/dev/null | wc -l; }
leftover() { ls -d "$BOX"/tmp/ex4-update/work.* 2> /dev/null | wc -l; }

case_() {	# case_ NAME WANT_RC WANT_REGEX RELEASE_DIR CMD [box]
	local name=$1 want=$2 rx=$3 rel=$4 cmd=$5 b=${6:-$BOX}
	[ -n "$rel" ] && serve "$rel"
	local before; before=$(staged_n)
	BOXSH "$b" "$cmd" --url "$URL" --insecure-http > "$W/case.out" 2>&1; local rc=$?
	cp "$W/case.out" "$W/case-$(echo "$name" | tr -c 'A-Za-z0-9' '_').out"
	local msg; msg=$(grep -m1 -E 'REFUSED|could not|staged in|verified:' "$W/case.out" || grep -m1 -E 'newer|up to date' "$W/case.out"); msg=$(printf '%s' "$msg" | cut -c1-170)
	if [ $rc = "$want" ] && grep -qE "$rx" "$W/case.out" && [ "$(leftover)" = 0 ] && { [ "$cmd" = stage ] && [ "$want" = 0 ] || [ "$(staged_n)" = "$before" ]; }; then
		ok "box $name: rc $rc, \"$msg\""
	else
		bad "box $name: rc $rc (want $want), \"$msg\", staged $before -> $(staged_n), work dirs left $(leftover)"
	fi
}

srv_start
case_ "a good signed release: check finds it newer" 0 'newer release: t1 \(serial 200' "$W/rel-good" check
grep -q '^sig=good$' "$BOX/tmp/ex4-update/state" && grep -q "^key=$TFP\$" "$BOX/tmp/ex4-update/state" && grep -q '^result=newer$' "$BOX/tmp/ex4-update/state" \
	&& ok "state file after check: result=newer sig=good key=$TFP" || bad "state after check: $(tr '\n' ' ' < "$BOX/tmp/ex4-update/state")"
grep -q "^expires=$(awk '$1 == "not-after" { print $3 }' "$W/rel-good/RELEASE")\$" "$BOX/tmp/ex4-update/state" && ok "state file after check: expires= the release's not-after (the web card shows it, v9)" || bad "state expires: $(tr '\n' ' ' < "$BOX/tmp/ex4-update/state")"
cp "$W/srv.log" "$W/srv.log.before" 2>/dev/null
BOXSH "$BOX" check --url "$URL" > "$W/case.out" 2>&1; rc=$?
[ $rc = 64 ] && grep -q 'is plain http' "$W/case.out" && cmp -s "$W/srv.log" "$W/srv.log.before" && ok "a plain http:// URL WITHOUT --insecure-http: refused (64) before anything is fetched (v9)" || bad "http without the flag: rc $rc $(cat "$W/case.out")"
printf '%s\n' "$URL" > "$BOX/etc/ex4-update/url"
BOXSH "$BOX" check > "$W/case.out" 2>&1; rc=$?
[ $rc = 64 ] && grep -q 'is plain http' "$W/case.out" && ok "an http:// address in /etc/ex4-update/url is refused the same way (no flag typed)" || bad "url file http: rc $rc $(cat "$W/case.out")"
rm -f "$BOX/etc/ex4-update/url"
BOXSH "$BOX" keys > "$W/case.out" 2>&1; rc=$?
[ $rc = 0 ] && grep -q "^key $TFP: untrusted comment" "$W/case.out" && grep -q '^1 signing key(s) held' "$W/case.out" && ok "keys: lists the one key held, by its key number" || bad "keys: rc $rc $(cat "$W/case.out")"
! grep -qvE '^[a-z_]+=[A-Za-z0-9.,:/+_-]{0,120}$' "$BOX/tmp/ex4-update/state" && [ "$(grep -c '^checked=[0-9]*$' "$BOX/tmp/ex4-update/state")" = 1 ] \
	&& ok "state file: every line KEY=VALUE (the web page's parser contract), checked= a number" || bad "state file format: $(tr '\n' '|' < "$BOX/tmp/ex4-update/state")"
case_ "a good signed release: verify" 0 'verified: ex4-t1.tar' "" verify
case_ "a good signed release: stage into RAM" 0 'staged in RAM: .*/staged/200 \(4 files' "" stage
( cd "$BOX/tmp/ex4-update/staged/200" && md5sum -c --quiet "$FB/MD5SUMS" ) 2> /dev/null; (cd "$FB" && for f in kernel.bin overlay.cpio RUNID MD5SUMS; do cmp -s "$f" "$BOX/tmp/ex4-update/staged/200/$f" || exit 1; done) \
	&& ok "the staged files are byte-identical to the bundle's" || bad "staged files differ"
case_ "tampered byte in RELEASE" 1 'REFUSED: the signature is not good' "$W/rel-tamper-release" check
case_ "tampered byte in the payload" 1 "REFUSED: the payload's sha256 is not the one" "$W/rel-tamper-payload" stage
case_ "truncated payload (at rest)" 1 'REFUSED: the payload is [0-9]+ bytes, RELEASE says' "$W/rel-truncate-payload" stage
srv_stop; serve "$W/rel-good"; srv_start --cut ex4-t1.tar
BOXSH "$BOX" stage --url "$URL" --insecure-http > "$W/case.out" 2>&1; rc=$?
[ $rc != 0 ] && [ "$(staged_n)" = 1 ] && [ "$(leftover)" = 0 ] && ok "download cut off mid-body: rc $rc, \"$(grep -m1 -E 'REFUSED|could not' "$W/case.out" | cut -c1-150)\", nothing new staged" || bad "cut download: rc $rc $(cat "$W/case.out")"
srv_stop; srv_start
case_ "wrong key (signed by a key the box does not hold)" 1 'REFUSED: the signature is not good, or is by a key' "$W/rel-wrongkey" check
case_ "unsigned (no RELEASE.sig)" 1 'REFUSED: no RELEASE.sig' "$W/rel-unsigned" check
case_ "another board's release (validly signed)" 1 "REFUSED: this release is for 'wd,mycloud-ex2-ultra'" "$W/rel-wrong-board" check
case_ "downgrade: serial 100 on a box at 150 (validly signed)" 1 'REFUSED: release .* \(serial 100\) is OLDER' "$W/rel-serial-100" stage
case_ "another channel's release (stable on a test box)" 1 "REFUSED: this release is channel 'stable'" "$W/rel-channel-stable" check
case_ "an unknown line in RELEASE (validly signed)" 1 "REFUSED: unknown line 'evil'" "$W/rel-unknown-line" check
case_ "RELEASE without its end line (validly signed)" 1 "REFUSED: no 'end' line" "$W/rel-no-end" check
case_ "a 1 MiB RELEASE (refused at the size limit, before any signature check)" 1 'REFUSED: RELEASE (is larger than|was cut off at the size limit)' "$W/rel-huge-release" check
case_ "payload with a file RELEASE does not list (validly signed)" 1 "REFUSED: the payload's files are not the ones RELEASE lists" "$W/rel-extra-member" stage
case_ "payload with a symlink (validly signed)" 1 'REFUSED: the payload holds something that is not a plain file' "$W/rel-symlink-member" stage
case_ "payload with a ../ member (validly signed)" 1 'REFUSED: (a bad name|the payload)' "$W/rel-dotdot-member" stage
[ ! -e "$BOX/tmp/escaped" ] && [ ! -e "$BOX/tmp/ex4-update/escaped" ] && ok "nothing escaped the staging folder" || bad "a ../ member escaped"
srv_stop; serve "$W/rel-good"; srv_start --stream RELEASE
BOXSH "$BOX" check --url "$URL" --insecure-http > "$W/case.out" 2>&1; rc=$?
grep -qE 'REFUSED: RELEASE (is larger|was cut off)' "$W/case.out" && [ $rc = 1 ] && [ "$(leftover)" = 0 ] && ok "a server streaming endless bytes as RELEASE: cut at 64 KiB, rc 1" || bad "stream: rc $rc $(cat "$W/case.out")"
srv_stop; srv_start
B2=$(mkbox same 200 test)
case_ "same serial as running: check says up to date (and until when)" 0 'up to date: v-200 .*release good until 20' "$W/rel-good" check "$B2"
case_ "same serial as running: stage refuses" 1 'REFUSED: nothing newer' "" stage "$B2"
# ---- v9: the clock and the expiry
case_ "EXPIRED release (validly signed, not-after in the past): refused, says expired and when" 1 'REFUSED: release t1 \(serial 200\) EXPIRED on 2026-02-01T00:00:00Z' "$W/rel-expired" check
grep -q '^why=expired$' "$BOX/tmp/ex4-update/state" && grep -q '^expires=2026-02-01T00:00:00Z$' "$BOX/tmp/ex4-update/state" && ok "state after an expired release: why=expired expires=2026-02-01T00:00:00Z (the web card's words)" || bad "expired state: $(tr '\n' ' ' < "$BOX/tmp/ex4-update/state")"
case_ "EXPIRED release with the SAME serial as running: refused, never 'up to date' (the freeze the review named)" 1 'REFUSED: release t1 .*EXPIRED' "$W/rel-expired" check "$B2"
case_ "a release built in the future (the box's clock is behind): refused 'set the clock first'" 1 'REFUSED: this system.s clock reads .* before this release was built \(2030-01-01T00:00:00Z\)' "$W/rel-future" check
case_ "no not-after line (validly signed): refused" 1 'REFUSED: a required line is missing' "$W/rel-noexpiry" check
case_ "not-after epoch and ISO disagree (validly signed): refused" 1 'REFUSED: not-after: .* are not the same moment' "$W/rel-namismatch" check
case_ "a release vouching for itself 500 days (validly signed): refused" 1 'REFUSED: this release vouches for itself for more than 400 days' "$W/rel-toolong" check
case_ "not-after before built (validly signed): refused" 1 'REFUSED: not-after .* is not after built' "$W/rel-nabefore" check
# ---- v9: the key rotation
BS=$(mkbox rot 150 test); BN=$(mkbox norot 150 test)
case_ "rotation: a release from a held key whose successor line passes every check: the successor key is adopted" 0 "KEY ROTATION: now also trusting key $NFP" "$W/rel-succ" check "$BS"
cmp -s "$BS/etc/ex4-update/keys/$NFP" "$W/keys/next.pub" 2>/dev/null || [ "$(sed -n 2p "$BS/etc/ex4-update/keys/$NFP")" = "$(sed -n 2p "$W/keys/next.pub")" ] && ok "rotation: keys/$NFP holds exactly the successor's public key" || bad "rotation: key file $(ls "$BS/etc/ex4-update/keys")"
grep -q "^successor=$NFP\$" "$BS/tmp/ex4-update/state" && ok "rotation: the state file names the successor (the web card's Key rotation line)" || bad "rotation state"
case_ "rotation: a release signed by the SUCCESSOR key: accepted by the box that adopted it" 0 "newer release: t4 \(serial 400.*key $NFP" "$W/rel-next" check "$BS"
case_ "rotation: the same release on a box that never saw the successor: refused (bad signature)" 1 'REFUSED: the signature is not good' "$W/rel-next" check "$BN"
case_ "rotation: the successor named on a DOWNGRADE (validly signed): refused, key NOT adopted" 1 'REFUSED: release .* OLDER' "$W/rel-succ-downgrade" check "$BN"
[ ! -e "$BN/etc/ex4-update/keys/$NFP" ] && ok "rotation: after the refused downgrade the key folder holds only the old key" || bad "rotation: downgrade adopted the key"
case_ "rotation: the successor named on an EXPIRED release: refused, key NOT adopted" 1 'EXPIRED' "$W/rel-succ-expired" check "$BN"
case_ "rotation: the successor in a release by a key the box does not hold: refused at the signature" 1 'REFUSED: the signature is not good' "$W/rel-succ-wrongkey" check "$BN"
case_ "rotation: a successor line whose key number is not its key's own: refused" 1 'REFUSED: the successor key in RELEASE does not carry its own key number 0123456789abcdef' "$W/rel-succ-badnum" check "$BN"
[ "$(ls "$BN/etc/ex4-update/keys" | wc -l)" = 1 ] && ok "rotation: after four refusals the never-rotated box still holds exactly one key" || bad "rotation: keys on BN: $(ls "$BN/etc/ex4-update/keys")"
B3=$(mkbox ex2 150 test wd,mycloud-ex2-ultra)
case_ "the box is another board than the release" 1 "REFUSED: this release is for 'wd,mycloud-ex4'" "$W/rel-good" check "$B3"
B4=$(mkbox nokey 150 test); rm "$B4"/etc/ex4-update/keys/*
case_ "no key in the box's key folder" 1 'REFUSED: no signing key' "$W/rel-good" check "$B4"
B5=$(mkbox noident 150 test); rm "$B5/etc/ex4-release"
case_ "no /etc/ex4-release" 1 'REFUSED: .*ex4-release is missing' "$W/rel-good" check "$B5"
B6=$(mkbox liar 150 test); printf 'wd,other\0' > "$B6/proc/device-tree/compatible"
case_ "device tree and /etc/ex4-release disagree" 1 "REFUSED: the device tree says 'wd,other'" "$W/rel-good" check "$B6"
B7=$(mkbox lowram 150 test); printf 'MemAvailable:       8000 kB\n' > "$B7/proc/meminfo"
case_ "too little RAM to stage" 1 'REFUSED: RAM:' "$W/rel-good" stage "$B7"
B8=$(mkbox trial 150 trial)
case_ "a trial box refuses a test-channel release" 1 "REFUSED: this release is channel 'test'" "$W/rel-good" check "$B8"
srv_stop
BOXSH "$BOX" check --url "http://127.0.0.1:$PORT" --insecure-http > "$W/case.out" 2>&1; rc=$?
[ $rc = 2 ] && grep -q 'could not fetch' "$W/case.out" && grep -q '^result=unreachable$' "$BOX/tmp/ex4-update/state" && ok "server down: rc 2, could not fetch, state result=unreachable" || bad "server down: rc $rc $(cat "$W/case.out")"
B9=$(mkbox local 150 test)
BOXSH "$B9" stage --from "$W/rel-good" > "$W/case.out" 2>&1; rc=$?
[ $rc = 0 ] && [ -f "$B9/tmp/ex4-update/staged/200/kernel.bin" ] && ok "stage --from a local folder (a USB stick): rc 0" || bad "--from: rc $rc $(cat "$W/case.out")"
BOXSH "$B9" stage --from "$W/rel-tamper-payload" > "$W/case.out" 2>&1; rc=$?
[ $rc = 1 ] && grep -q "sha256 is not the one" "$W/case.out" && ok "stage --from a tampered local folder: refused" || bad "--from tampered: rc $rc"
BOXSH "$BOX" install > "$W/case.out" 2>&1; rc=$?
[ $rc = 1 ] && grep -q 'installing is not built' "$W/case.out" && ok "install: refused, not built" || bad "install: rc $rc"
BOXSH "$BOX" check --url "ftp://x/y" > "$W/case.out" 2>&1; rc=$?
[ $rc = 64 ] && ok "a URL that is not http(s): refused (64)" || bad "ftp url: rc $rc"
BOXSH "$BOX" check --url 'https://x/$(reboot)' > "$W/case.out" 2>&1; rc=$?
[ $rc = 64 ] && ok "a URL with shell characters: refused (64)" || bad "shell url: rc $rc"

# ---- 5. the real bundle, the real key: a box that holds ONLY the shipped public key stages it
if [ -n "$RB" ] && [ -n "$RK" ]; then
	NRB=$(( $(grep -c . "$RB/MD5SUMS") + 1 ))
	py "$U/mkrelease.py" release --work "$TREE" --bundle "$RB" --usign "$UH" --version 2026.11.17-real --serial 2026111799 --channel trial \
		--key "$RK" --pub "$U/keys/ex4-release.pub" --built 2026-11-17T22:02:28Z --out "$W/rel-v7" > "$W/mk-v7.log" 2>&1 \
		&& ok "mkrelease: the real bundle ($(cat "$RB/RUNID")), signed with the real release key in this test's scratch ($(cut -c1-200 "$W/mk-v7.log"))" || bad "mkrelease real: $(cat "$W/mk-v7.log")"
	BR=$(mkbox real 2026111600 trial wd,mycloud-ex4 "$U/keys/ex4-release.pub")
	serve "$W/rel-v7"; srv_start
	case_ "REAL: the real bundle, real key, box holding only update/keys/ex4-release.pub: stage" 0 "staged in RAM: .*/staged/2026111799 \\($NRB files" "" stage "$BR"
	srv_stop
	( cd "$BR/tmp/ex4-update/staged/2026111799" && md5sum -c --quiet MD5SUMS ) > /dev/null 2>&1 && ok "REAL: the staged bundle passes its own MD5SUMS" || bad "REAL: staged bundle md5"
	BRT=$(mkbox realtest 2026111600 trial wd,mycloud-ex4)   # holds the TEST key only
	BOXSH "$BRT" check --from "$W/rel-v7" > "$W/case.out" 2>&1; rc=$?
	[ $rc = 1 ] && grep -q 'signature is not good' "$W/case.out" && ok "REAL: a box with another key refuses the real release" || bad "REAL other key: rc $rc"
	# the watch's trust walls, on the real release
	py "$U/cvewatch.py" --release "$W/rel-tamper-release" --keys "$W/keys" --replay "$W" > "$W/o" 2>&1; rc=$?
	[ $rc = 2 ] && ok "cvewatch: tampered RELEASE refused (rc 2: $(cut -c1-90 "$W/o"))" || bad "cvewatch tampered: rc $rc $(cat "$W/o")"
	mkdir "$W/rel-v7-sbomx"; cp "$W/rel-v7"/RELEASE* "$W/rel-v7"/sbom.cdx.json "$W/rel-v7-sbomx/"; sed -i 's/"busybox"/"busyb0x"/' "$W/rel-v7-sbomx/sbom.cdx.json"
	py "$U/cvewatch.py" --release "$W/rel-v7-sbomx" --replay "$W" > "$W/o" 2>&1; rc=$?
	[ $rc = 2 ] && grep -q 'not the file RELEASE signs for' "$W/o" && ok "cvewatch: an edited SBOM refused (its hash is signed)" || bad "cvewatch sbom edit: rc $rc $(cat "$W/o")"
	py "$U/cvewatch.py" --release "$W/rel-v7" --keys "$W/keys" --replay "$W" > "$W/o" 2>&1; rc=$?
	[ $rc = 2 ] && grep -q 'which is not in' "$W/o" && ok "cvewatch: the real release refused when the real key is not in --keys" || bad "cvewatch keys: rc $rc $(cat "$W/o")"
	mkdir "$W/rel-v7-unsigned"; cp "$W/rel-v7"/RELEASE "$W/rel-v7"/sbom.cdx.json "$W/rel-v7-unsigned/"
	py "$U/cvewatch.py" --release "$W/rel-v7-unsigned" --replay "$W" > "$W/o" 2>&1; rc=$?
	[ $rc = 2 ] && ok "cvewatch: unsigned release refused" || bad "cvewatch unsigned: rc $rc"
	if [ -n "$REPLAY" ]; then
		py "$U/cvewatch.py" --release "${WREL:-$W/rel-v7}" --replay "$REPLAY" --out "$W/watch-replay.json" > "$W/watch-replay.txt" 2>&1; rc=$?
		[ $rc = 0 ] || [ $rc = 1 ] && grep -q '^VERDICT' "$W/watch-replay.txt" && ok "cvewatch replay of the recorded live run ($(awk '$1 == "version" { print $2 }' "${WREL:-$W/rel-v7}/RELEASE")): rc $rc, $(grep '^VERDICT' "$W/watch-replay.txt" | cut -c1-140)" || bad "cvewatch replay: rc $rc $(tail -3 "$W/watch-replay.txt")"
		py - "$REPLAY/SENT.jsonl" <<'PY' && ok "cvewatch payload wall: every recorded body holds only package/name/ecosystem/version/page_token" || bad "payload wall"
import json, sys
allowed = {'queries', 'package', 'name', 'ecosystem', 'version', 'page_token'}
for line in open(sys.argv[1]):
    s = json.loads(line)
    if s['method'] == 'GET':
        assert s['url'].startswith('https://api.osv.dev/v1/vulns/') and s['body'] is None, s
        continue
    assert s['url'] in ('https://api.osv.dev/v1/querybatch', 'https://api.osv.dev/v1/query'), s['url']
    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                assert k in allowed, k
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
        else:
            assert isinstance(o, str)
            for bad in ('192.168.', '10.0.', 'sil' + 'kalia', 'ex4-build', '/home', 'aliaholes', '00:90:a9'):
                assert bad not in o, (bad, o)
    walk(json.loads(s['body']))
PY
	fi
fi

# ---- 5b. (v9) the deliverable release itself, as signed
if [ -n "$SREL" ]; then
	SS=$(awk '$1 == "serial" { print $2 }' "$SREL/RELEASE"); SN=$(grep -c '^file ' "$SREL/RELEASE")
	BD=$(mkbox deliver 2026111600 trial wd,mycloud-ex4 "$U/keys/ex4-release.pub")
	BOXSH "$BD" stage --from "$SREL" > "$W/case.out" 2>&1; rc=$?
	[ $rc = 0 ] && grep -q "staged in RAM: .*/staged/$SS ($SN files" "$W/case.out" && ( cd "$BD/tmp/ex4-update/staged/$SS" && md5sum -c --quiet MD5SUMS ) > /dev/null 2>&1 \
		&& ok "DELIVERABLE: $(awk '$1 == "version" { print $2 }' "$SREL/RELEASE") (serial $SS) staged --from its folder on a box holding only the shipped key: $SN files, its own MD5SUMS check" || bad "DELIVERABLE stage: rc $rc $(cat "$W/case.out")"
	BU=$(mkbox delivered "$SS" trial wd,mycloud-ex4 "$U/keys/ex4-release.pub")
	BOXSH "$BU" check --from "$SREL" > "$W/case.out" 2>&1; rc=$?
	[ $rc = 0 ] && grep -q "up to date: v-$SS (serial $SS), signature good (key cd0c35ab50a98c3c), release good until $(awk '$1 == "not-after" { print $3 }' "$SREL/RELEASE")" "$W/case.out" \
		&& ok "DELIVERABLE: a box already running serial $SS reads it as up to date, good until $(awk '$1 == "not-after" { print $3 }' "$SREL/RELEASE")" || bad "DELIVERABLE check: rc $rc $(cat "$W/case.out")"
	py "$U/cvewatch.py" --release "$SREL" --replay "$W/no-such-recording" > "$W/o" 2>&1; rc=$?
	[ $rc = 3 ] && grep -q 'replay: no recorded answer' "$W/o" && ok "DELIVERABLE: cvewatch accepts its signature and SBOM hash (it got as far as asking OSV; this run replays nothing)" || bad "DELIVERABLE cvewatch trust: rc $rc $(cat "$W/o")"
fi

# ---- 6. cvewatch on fixtures: the classes, the canary wall
py "$HERE/watch-fixture.py" "$U" "$W" > "$W/watch-fixture.log" 2>&1; rc=$?
while read -r l; do case "$l" in PASS*) ok "${l#PASS  }";; FAIL*) bad "${l#FAIL  }";; esac; done < "$W/watch-fixture.log"
[ $rc = 0 ] || bad "watch-fixture.py rc $rc: $(tail -2 "$W/watch-fixture.log")"

echo "tests/update: $PASS passed, $FAIL failed (work: $W)"
[ $FAIL = 0 ]
