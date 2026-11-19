#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# md-ro-test.sh (v9) : the image's read-only assembler (build/v9/files/usr/sbin/ex4-md-ro) against REAL `mdadm
# --examine` captures (tests/rwbench/captures/, mdadm 4.3, the EX4's geometry) edited one field at a time. Its
# `check` only (test mode: EX4MDRO_TEST=1; mdadm and blockdev are stubs on PATH, no device is opened, nothing is
# assembled). The v9 wall: a member being REBUILT says "State : clean" with equal events; its Feature Map (0x2)
# and its "Recovery Offset" line are what must refuse it.
#   sh tests/md-ro-test.sh WORK [SHELL]        (SHELL: the shell to run ex4-md-ro under; default sh = dash here)
# Not busybox ash: it runs its own blockdev applet in-process (FEATURE_PREFER_APPLETS), so the PATH stub is never
# called (stub-test.sh has the same note). The parsing is plain POSIX sh + awk, which the image's ash also runs.
# No root, no network.
set -u
W=${1:?usage: sh tests/md-ro-test.sh WORK [SHELL]}; SH=${2:-sh}
[ ! -e "$W" ] || { echo "REFUSED: $W exists" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/.." && pwd); MDRO=$TOP/build/v9/files/usr/sbin/ex4-md-ro
CAP=$HERE/rwbench/captures
mkdir -p "$W/fx" "$W/bin" "$W/tmp"; W=$(cd "$W" && pwd); FX=$W/fx
P=0; F=0
ok() { P=$((P + 1)); echo "PASS  $*"; }
bad() { F=$((F + 1)); echo "FAIL  $*"; }
cat > "$W/bin/mdadm" <<EOF
#!/bin/sh
[ "\$1" = --examine ] || { echo "stub mdadm: \$* (check never assembles)"; exit 9; }
cat "$FX/ex-\${2##*/}.txt"
EOF
cat > "$W/bin/blockdev" <<EOF
#!/bin/sh
case "\$1" in --setro) echo "\$2" >> "$W/setro.log";; --getro) echo 1;; *) exit 9;; esac
EOF
chmod 755 "$W/bin/mdadm" "$W/bin/blockdev"
M="/dev/loop70 /dev/loop71 /dev/loop72 /dev/loop73"
split() { awk -v d="$FX" 'BEGIN { n = 69 } /^\/dev\/loop[0-9]+:$/ { n++; f = d "/ex-loop" n ".txt"; next } f { print > f }' "$1"; }
RUN() { env -i PATH="$W/bin:/usr/bin:/bin" EX4MDRO_TEST=1 EX4MDRO_MEMBERS="${MEMB:-$M}" EX4MDRO_MDSTAT="$W/mdstat" EX4MDRO_TMP="$W/tmp" \
	$SH "$MDRO" check > "$W/out.txt" 2>&1; }
var() {            # $1 = name, $2 = word expected in the refusal ("" = must pass), then edits "N sed-expr" on member 7N
	name=$1; want=$2; shift 2; rm -f "$FX"/* "$W/setro.log"; : > "$W/mdstat"; split "$CAP/examine-clean.txt"; MEMB=
	for e in "$@"; do n=${e%% *}; x=${e#* }; case "$n" in
		cap) split "$CAP/$x";;
		md1) echo 'md1 : active (read-only) raid5 sda2[0] sdb2[1] sdc2[2] sdd2[3]' > "$W/mdstat";;
		three) MEMB="/dev/loop70 /dev/loop71 /dev/loop72";;
		*) sed -i "$x" "$FX/ex-loop7$n.txt";;
	esac; done
	RUN; rc=$?
	if [ -z "$want" ]; then
		if [ $rc = 0 ] && grep -q 'check passed' "$W/out.txt"; then ok "md-ro: $name -> passes"; else bad "md-ro: $name -> rc $rc: $(tail -1 "$W/out.txt")"; fi
	elif [ $rc != 0 ] && grep -q -- "$want" "$W/out.txt"; then ok "md-ro: $name -> refused ($(grep -o 'REFUSED: .*' "$W/out.txt" | cut -c1-120))"
	else bad "md-ro: $name -> rc $rc, wanted '$want': $(tail -1 "$W/out.txt")"; fi
}
var "clean capture (four members, AAAA, equal events)" ""
grep -c . "$W/setro.log" | grep -qx 4 && ok "md-ro: every member set read-only before it is examined" || bad "md-ro: setro log: $(cat "$W/setro.log" 2>/dev/null)"
var "a write-intent bitmap on all four (Feature Map 0x1)" "" "0 s/Feature Map : 0x0/Feature Map : 0x1/" "1 s/Feature Map : 0x0/Feature Map : 0x1/" "2 s/Feature Map : 0x0/Feature Map : 0x1/" "3 s/Feature Map : 0x0/Feature Map : 0x1/"
var "REAL capture: a member mid-recovery (Feature Map 0x2 + Recovery Offset, State clean, equal events)" "unfinished rebuild" "cap examine-recovery-offset.txt"
var "Feature Map 0x2 alone, State clean, equal events (no offset line)" "being REBUILT" "3 s/Feature Map : 0x0/Feature Map : 0x2/"
var "Feature Map 0x4 (a reshape)" "Feature Map '0x4'" "1 s/Feature Map : 0x0/Feature Map : 0x4/"
var "a Reshape pos'n line" "unfinished rebuild" "1 s/^\( *\)State : clean/  Reshape pos'n : 1024 (1.00 MiB)\n\1State : clean/"
var "a Resync Offset line" "unfinished rebuild" "2 s/^\( *\)State : clean/  Resync Offset : 2048 sectors\n\1State : clean/"
var "a member missing in Array State (AAA.)" "Array State" "2 s/Array State : AAAA/Array State : AAA./"
var "a member being replaced (AAAR)" "Array State" "0 s/Array State : AAAA/Array State : AAAR/"
var "REAL capture: written without a clean stop (State active)" "state 'active'" "cap examine-dirty-active.txt"
var "members out of step" "events" "3 s/Events : 0/Events : 1/"
var "another array's member" "array UUID" "2 s/Array UUID : d0/Array UUID : e0/"
var "superblock 1.2" "superblock version" "0 s/Version : 1.0/Version : 1.2/"
var "raid6" "level" "0 s/Raid Level : raid5/Raid Level : raid6/"
var "chunk 512K" "chunk" "1 s/Chunk Size : 64K/Chunk Size : 512K/"
var "left-asymmetric" "layout" "2 s/Layout : left-symmetric/Layout : left-asymmetric/"
var "three members found" "want 4" "three x"
var "md1 already assembled" "md1 already exists" "md1 x"
env -i PATH="$W/bin:/usr/bin:/bin" EX4MDRO_TEST=1 EX4MDRO_MEMBERS="$M" EX4MDRO_MDSTAT="$W/mdstat" EX4MDRO_TMP="$W/tmp" $SH "$MDRO" assemble > "$W/out.txt" 2>&1
[ $? != 0 ] && grep -q 'test mode runs check only' "$W/out.txt" && ok "md-ro: test mode refuses assemble (it can never open a device here)" || bad "md-ro: test-mode assemble: $(cat "$W/out.txt")"
echo "== md-ro-test: $P passed, $F failed"; [ $F = 0 ]
