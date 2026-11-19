#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# conf-test.sh : every profile's Samba lines, rendered the way the box renders them, loaded by the IMAGE's own Samba
# 4.22 testparm (ARM, qemu-arm): the image's smb.conf.template + ex4-profile's marked block, put through the same
# substitutions as net/samba4/files/samba.init, then the dynamic lines ex4-apply's settings produce (no netbios, port
# 445), then a guest share and (for Backups) a Time Machine share with fruit, as samba.init writes them.
# Pass = testparm loads it, prints no warning the plain template does not print, and shows each of our values.
# ksmbd: no shipped profile sets a ksmbd knob; the mechanism is checked with a test conf: every parameter it writes
# must be a string the image's ksmbd.tools (3.5.6) knows.
#   bash tests/profiles/conf-test.sh --work NEW_DIR --rootfs ROOTFS
set -u
WORK=; RFS=
while [ $# -gt 0 ]; do case "$1" in --work) WORK=$2;; --rootfs) RFS=$2;; *) sed -n '10p' "$0" >&2; exit 64;; esac; shift 2; done
[ -n "$WORK" ] && [ ! -e "$WORK" ] && [ -x "$RFS/usr/bin/testparm" ] || { echo "REFUSED: --work NEW --rootfs ROOTFS (with usr/bin/testparm)" >&2; exit 1; }
command -v qemu-arm >/dev/null || { echo "REFUSED: no qemu-arm" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); TOOL=$TOP/profiles/ex4-profile
mkdir -p "$WORK/root/tmp" "$WORK/share/Public" "$WORK/share/TM"; WORK=$(cd "$WORK" && pwd); RFS=$(cd "$RFS" && pwd)
P=0; F=0
ok() { P=$((P + 1)); echo "PASS  $*"; }
bad() { F=$((F + 1)); echo "FAIL  $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }
TP() { qemu-arm -L "$RFS" "$RFS/usr/bin/testparm" "$@"; }
render() {         # $1 = block file, $2 = 1 for the Time Machine share (macos) -> smb.conf on stdout, as samba.init would
	sed -e 's#|NAME|#ex4#g' -e 's#|WORKGROUP|#WORKGROUP#g' -e 's#|DESCRIPTION|#ex4#g' -e 's#|INTERFACES|#br-lan #g' -e 's#|CHARSET|#UTF-8#g' "$RFS/etc/samba/smb.conf.template"
	if [ -s "$1" ]; then echo '	# >>> ex4-profile (written by ex4-profile from the Storage page; do not edit by hand)'; cat "$1"; echo '	# <<< ex4-profile'; fi
	printf '\n######### Dynamic written config options #########\n\tdisable netbios = yes\n\tsmb ports = 445\n'
	printf '\n[Public]\n\tpath = %s\n\tcreate mask = 0664\n\tdirectory mask = 0775\n\tread only = no\n\tguest ok = yes\n' "$WORK/share/Public"
	if [ "$2" = 1 ]; then
		printf '\n[TM]\n\tpath = %s\n\tvalid users = kurt\n\tread only = no\n\tfruit:encoding = native\n\tfruit:metadata = stream\n\tfruit:veto_appledouble = no\n\tfruit:time machine = yes\n\tvfs objects = catia fruit streams_xattr\n' "$WORK/share/TM"
	fi
}
NOISE='unknown parameter|invalid|ignoring|deprecated|error|warning'
: > "$WORK/empty"; render "$WORK/empty" 1 > "$WORK/plain.conf"
TP -s "$WORK/plain.conf" > "$WORK/plain.out" 2> "$WORK/plain.err"; rc=$?
check "the plain template (no profile) loads in the image's testparm (the baseline)" '[ $rc = 0 ] && grep -q "Loaded services file OK" "$WORK/plain.err"'
grep -iE "$NOISE" "$WORK/plain.err" | sort -u > "$WORK/plain.noise"
[ -s "$WORK/plain.noise" ] && { echo "      (the plain template's own notes, not counted against a profile:)"; sed 's/^/        /' "$WORK/plain.noise"; }
for case in "balanced|" "movies|" "movies|--opt spindown" "smallfiles|" "smallfiles|--opt casesensitive" "backups|"; do
	p=${case%%|*}; o=${case#*|}; tag=$p${o:+-${o##* }}
	EX4P_ROOT=$WORK/root EX4P_DIR=$TOP/profiles sh "$TOOL" smbconf "$p" $o > "$WORK/$tag.block" 2> "$WORK/$tag.block.err"
	check "[$tag] ex4-profile smbconf renders" '[ $? = 0 ] && [ ! -s "$WORK/$tag.block.err" ]'
	render "$WORK/$tag.block" 1 > "$WORK/$tag.conf"
	TP -s "$WORK/$tag.conf" > "$WORK/$tag.out" 2> "$WORK/$tag.err"; rc=$?
	TP -s -v "$WORK/$tag.conf" > "$WORK/$tag.v" 2> /dev/null
	grep -iE "$NOISE" "$WORK/$tag.err" | sort -u > "$WORK/$tag.noise"
	check "[$tag] the image's Samba 4.22 testparm loads it, no warning the plain template lacks" '[ $rc = 0 ] && grep -q "Loaded services file OK" "$WORK/$tag.err" && [ -z "$(comm -23 "$WORK/$tag.noise" "$WORK/plain.noise")" ]'
	miss=
	while IFS= read -r l; do
		k=$(echo "$l" | sed 's/^\t//; s/ = .*//'); v=$(echo "$l" | sed 's/.* = //')
		case "$v" in yes) want='(Yes|yes)';; no) want='(No|no)';; *) want=$v;; esac
		grep -qiE "^	$k = $want\$" "$WORK/$tag.v" || miss="$miss [$k = $v]"
	done < "$WORK/$tag.block"
	check "[$tag] testparm -v shows every value of the block ($(wc -l < "$WORK/$tag.block") lines)" '[ -z "$miss" ]'
	[ -n "$miss" ] && echo "      not shown:$miss"
done
check "[balanced] adds no Samba line at all (Samba's own defaults)" '[ ! -s "$WORK/balanced.block" ]'
check "[movies] sendfile + receivefile + aio 0 in [global]" 'grep -qx "	use sendfile = Yes" "$WORK/movies.v" && grep -qx "	min receivefile size = 16384" "$WORK/movies.v" && grep -qx "	aio read size = 0" "$WORK/movies.v"'
check "[smallfiles --opt casesensitive] case sensitive = Yes is the [global] default every share inherits (no share overrides it)" 'awk "/^\[Public\]/{exit} 1" "$WORK/smallfiles-casesensitive.v" | grep -qx "	case sensitive = Yes" && ! awk "/^\[Public\]/,0" "$WORK/smallfiles-casesensitive.v" | grep -q "case sensitive"'
check "[smallfiles] without the opt-in: case sensitivity left at Samba's default (Auto)" 'awk "/^\[Public\]/{exit} 1" "$WORK/smallfiles.v" | grep -qx "	case sensitive = Auto"'
check "[backups] fruit options present and the Time Machine share keeps fruit:time machine" 'grep -q "fruit:delete_empty_adfiles = yes" "$WORK/backups.out" && awk "/^\[TM\]/,0" "$WORK/backups.out" | grep -q "fruit:time machine = yes"'
# ksmbd: the mechanism, with a test conf (no shipped profile sets a ksmbd knob)
PD=$WORK/kprof; mkdir -p "$PD"; cp "$TOP/profiles/balanced.conf" "$PD/"
printf 'title\tk\nset\tksmbd.smb2_leases\tyes\nset\tksmbd.smb2_max_read\t4M\nset\tksmbd.smb2_max_write\t4M\n' > "$PD/movies.conf"
EX4P_ROOT=$WORK/root EX4P_DIR=$PD sh "$TOOL" ksmbdconf movies > "$WORK/ksmbd.block"
B=$RFS/usr/libexec/ksmbd.tools; miss=
while IFS= read -r l; do k=$(echo "$l" | sed 's/^\t//; s/ = .*//'); grep -aq -- "$k" "$B" || miss="$miss $k"; done < "$WORK/ksmbd.block"
check "ksmbd: every parameter a ksmbd knob writes is a string the image's ksmbd.tools knows (3 lines)" '[ "$(wc -l < "$WORK/ksmbd.block")" = 3 ] && [ -z "$miss" ]'
{ cat "$RFS/etc/ksmbd/ksmbd.conf.template"; echo '	# >>> ex4-profile'; cat "$WORK/ksmbd.block"; echo '	# <<< ex4-profile'; } > "$WORK/ksmbd.tpl"
check "ksmbd: the template ends inside [global], so the block lands in [global]" '[ "$(grep -c "^\[" "$WORK/ksmbd.tpl")" = 1 ] && grep -qx "\[global\]" "$WORK/ksmbd.tpl"'
check "samba: the template ends inside [global] too" '[ "$(grep -c "^\[" "$RFS/etc/samba/smb.conf.template")" = 1 ]'
echo "== profiles conf-test: $P passed, $F failed"; [ $F = 0 ]
