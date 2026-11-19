#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# loop-test.sh (v9.4: + 7d, NFS max_block_size, the profile verb, the review's nits; v9.7: + 7e, NFSv4.2 / threads / grace / the
# listener wall, the max_block_size auto-0 INFO, the md5 / xsnap / facts verbs; v9.8: + 7f, the ucanary verb, the nfsd start-wait + client
# tracking line, the nfs-utils socket wall; v9.9: + 7g, the memory receipt + the nfsd prep before every rpc.nfsd) : box/ex4-rwbench.sh against a REAL Linux md RAID5 + ext4, built from four small sparse files on loop
# devices: the same superblock (1.0), level, chunk, layout and member count as the EX4's md1, and an ext4 laid out
# like stock's (a Public folder, stock's two 2 GiB zero files as sparse files, one file standing for his data).
# Every refusal path that needs a real array is run here; the ones that need an array state a loop device cannot be
# put in (members out of step with AAAA, bad blocks) are in stub-test.sh, fed from real examine captures.
#
#   sudo bash tests/rwbench/loop-test.sh --work DIR [--ash host|arm --arm-root ROOTFS] [--md /dev/md9N]
#
#   NEEDS ROOT (losetup, mdadm, mount) and no network. It touches only: the files under --work, four loop devices it
#   attaches and detaches, one md device /dev/md90..md99 that must be free, the kernel log (one test line). Nothing is
#   installed. --ash host = the build box's busybox ash + applets; --ash arm = the IMAGE's own busybox (ARM, under
#   qemu-arm) as the shell and for every busybox applet the script calls; mdadm/losetup/mount are the host's.
set -u
WORK=; ASHM=host; ARMROOT=; MD=/dev/md91
while [ $# -gt 0 ]; do
	case "$1" in --work) WORK=$2; shift 2;; --ash) ASHM=$2; shift 2;; --arm-root) ARMROOT=$2; shift 2;; --md) MD=$2; shift 2;;
	*) sed -n '9,16p' "$0" >&2; exit 64;; esac
done
[ "$(id -u)" = 0 ] || { echo "REFUSED: needs root (losetup, mdadm, mount)" >&2; exit 1; }
[ -n "$WORK" ] && [ ! -e "$WORK" ] || { echo "REFUSED: --work must be a NEW folder" >&2; exit 1; }
case "$MD" in /dev/md9[0-9]) ;; *) echo "REFUSED: --md must be /dev/md90..md99" >&2; exit 1;; esac
MDN=${MD##*/}; grep -q "^$MDN " /proc/mdstat && { echo "REFUSED: $MD is in use" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); SRC=$TOP/box/ex4-rwbench.sh
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)
G=$WORK/golden; W=$WORK/w; FROOT=$WORK/root; TMPD=$WORK/tmp; MNTD=$WORK/mnt; APPL=$WORK/applets; LOG=$WORK/log
mkdir -p "$G" "$W" "$FROOT/etc/init.d" "$FROOT/etc/rc.d" "$FROOT/usr/sbin" "$TMPD" "$MNTD" "$APPL" "$LOG"
APPLETS="awk basename cat chmod chown cmp cp cut date dd df dirname dmesg echo find flock grep head hexdump id kill killall ln logger ls md5sum mkdir mv pidof printf rm rmdir sed seq setsid sleep sort sync tail tee touch tr uniq wc xargs uptime sh"
if [ "$ASHM" = arm ]; then
	[ -x "$ARMROOT/bin/busybox" ] && command -v qemu-arm >/dev/null || { echo "REFUSED: --ash arm needs --arm-root (the image's rootfs) and qemu-arm" >&2; exit 1; }
	# qemu-arm -L looks every path up under the prefix first: the image's empty /proc and /sys would hide the real ones
	# (a glob of /proc/[0-9]* sees nothing). So the prefix is a copy of only what busybox needs: its loader + libc.
	mkdir -p "$WORK/armprefix/bin" && cp -a "$ARMROOT/lib" "$WORK/armprefix/" && cp "$ARMROOT/bin/busybox" "$WORK/armprefix/bin/" || exit 1
	ARMROOT=$WORK/armprefix
	for a in $APPLETS; do printf '#!/bin/sh\nexec qemu-arm -L %s %s/bin/busybox %s "$@"\n' "$ARMROOT" "$ARMROOT" "$a" > "$APPL/$a"; chmod 755 "$APPL/$a"; done
	ln -s "$(command -v readlink)" "$APPL/readlink"     # host readlink: the holder scan reads every fd on the build box
	ASH="qemu-arm -L $ARMROOT $ARMROOT/bin/busybox sh"; BBV="the image's busybox $(strings "$ARMROOT/bin/busybox" | grep -m1 -oE 'BusyBox v[0-9.]+') (ARM, qemu-arm)"
else
	BB=$(command -v busybox) || { echo "REFUSED: no busybox" >&2; exit 1; }
	for a in $APPLETS readlink; do       # an applet this busybox build lacks (Ubuntu's has no flock): the host's own tool
		if "$BB" --list 2>/dev/null | grep -qx "$a"; then ln -s "$BB" "$APPL/$a"
		else ln -s "$(command -v "$a")" "$APPL/$a"; echo "note: host busybox has no $a applet: host $(command -v "$a") used" >> "$LOG/applets.txt"; fi
	done
	ASH="$BB sh"; BBV="host $($BB | head -1 | cut -c1-40)"
fi
cp "$SRC" "$FROOT/usr/sbin/ex4-rwbench"; chmod 755 "$FROOT/usr/sbin/ex4-rwbench"
mkhooks() {      # the three reboot paths, as the --rwbench overlay writes them (their real text is checked in patch-test.sh)
	for f in ex4-trial ex4-deadman ex4-rwstop; do printf '#!/bin/sh\n# fake %s\nex4_rw_wait() { /usr/sbin/ex4-rwbench stop --for-reboot; }\n' "$f" > "$FROOT/etc/init.d/$f"; done
	rm -f "$FROOT/etc/rc.d/K01ex4-rwstop"; ln -s ../init.d/ex4-rwstop "$FROOT/etc/rc.d/K01ex4-rwstop"
}
mkhooks
P=0; F=0; FAILS=
ok() { P=$((P + 1)); echo "PASS  $*"; }
bad() { F=$((F + 1)); FAILS="$FAILS
  $*"; echo "FAIL  $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }
LOOPS=
RB() { env -i PATH="$APPL:/usr/sbin:/usr/bin:/sbin:/bin" EX4RW_TEST=1 EX4RW_MEMBERS="$LOOPS" EX4RW_MD="$MD" EX4RW_TMP="$TMPD" \
	EX4RW_ROOT="$FROOT" EX4RW_MNT="$MNTD" EX4RW_RUNID="t-$CASE" EX4RW_GUARD_SEC=1 EX4RW_RETURN_SEC=2 ${XENV:-} $ASH "${RBPATH:-$FROOT/usr/sbin/ex4-rwbench}" "$@"; }
md_up() { grep -q "^$MDN " /proc/mdstat; }
mnt_up() { awk -v m="$MNTD" '$2 == m { f = 1 } END { exit !f }' /proc/mounts; }
read VB0 VBB0 VR0 VBR0 <<< "$(cat /proc/sys/vm/dirty_bytes /proc/sys/vm/dirty_background_bytes /proc/sys/vm/dirty_ratio /proc/sys/vm/dirty_background_ratio | tr '\n' ' ')"
vm_back() {      # this build box's own writeback settings, as they were when the test started (a killed case cannot leave ours)
	if [ "$VB0" = 0 ]; then echo "$VR0" > /proc/sys/vm/dirty_ratio; else echo "$VB0" > /proc/sys/vm/dirty_bytes; fi
	if [ "$VBB0" = 0 ]; then echo "$VBR0" > /proc/sys/vm/dirty_background_ratio; else echo "$VBB0" > /proc/sys/vm/dirty_background_bytes; fi
}
rbpids() { pgrep -f -- "$FROOT/usr/sbin/ex4-rwbench|$WORK/other.sh" 2>/dev/null; }     # guards / returners left by a case
cmdpid() { pgrep -f -- "ex4-rwbench $1\$" 2>/dev/null | head -1; }                       # the shell running one command
detach() {
	for p in $(rbpids); do kill -9 "$p" 2>/dev/null; done; sleep 0.3
	mnt_up && { fuser -km "$MNTD" > /dev/null 2>&1; sleep 0.3; umount "$MNTD" 2>/dev/null; }     # a case that failed may leave a holder md_up && mdadm --stop "$MD" > /dev/null 2>&1
	for l in $LOOPS; do losetup -d "$l" 2>/dev/null; done; LOOPS=
	vm_back; true
}
attach() {       # $1 = image dir: four loop devices; anything udev auto-assembled from them is stopped
	LOOPS=; for i in 0 1 2 3; do LOOPS="$LOOPS $(losetup -f --show "$1/m$i.img")"; done; LOOPS=${LOOPS# }
	udevadm settle 2>/dev/null; sleep 0.5
	for d in /sys/block/md*; do
		[ -e "$d" ] || continue; n=${d##*/}
		for l in $LOOPS; do [ -e "$d/md/dev-${l##*/}" ] && { mdadm --stop "/dev/$n" > /dev/null 2>&1; echo "note: udev had auto-assembled /dev/$n from the test loops: stopped" >> "$LOG/udev.txt"; break; }; done
	done
}
fresh() {        # $1 = case name: a clean copy of the golden array, attached; a clean state folder
	CASE=$1; detach; rm -rf "$W" "$TMPD"; mkdir -p "$W" "$TMPD"
	for i in 0 1 2 3; do cp --sparse=always "$G/m$i.img" "$W/m$i.img"; done
	attach "$W"; XENV=; RBPATH=; mkhooks
}
type_token() {   # stands for the human: the line arm printed, typed into the token file (root-owned, after arm)
	sleep 1.1; X=$(grep -o "EX4-RW [^']*" "$1" | head -1); printf '%s\n' "$X" > "$TMPD/ex4-rw-ok"
}
fs_look() {      # after a run: assemble read-only, read-only fsck, list; prints "fsck=RC files=..." and stops
	mdadm --assemble --readonly "$MD" $LOOPS > /dev/null 2>&1 || { echo "assemble-failed"; return; }
	e2fsck -fn "$MD" > "$LOG/fsck-$CASE.txt" 2>&1; rc=$?
	mount -o ro,noload "$MD" "$MNTD" && { ( cd "$MNTD" && find . -path ./lost+found -prune -o -print | sort ) > "$LOG/files-$CASE.txt"; cat "$MNTD/Public/kurt-data.txt" > "$LOG/kurt-$CASE.txt" 2>&1; umount "$MNTD"; }
	mdadm --stop "$MD" > /dev/null 2>&1
	echo "fsck=$rc"
}
events() { for l in $LOOPS; do mdadm --examine "$l" | awk -F' : ' '/Events/ { print $2 }'; done | sort -u | tr '\n' ' '; }
mdstate() { for l in $LOOPS; do mdadm --examine "$l" | awk -F' : ' '$1 ~ /^ *State$/ { print $2 }'; done | sort -u | tr '\n' ' '; }
poke() {         # $1 = offset in the ext4 superblock, $2 = python expression of the new 2- or 4-byte LE value from the old (v)
	mdadm --assemble "$MD" $LOOPS > /dev/null 2>&1 || return 1
	python3 -I - "$MD" "$1" "$2" <<'PY'
import sys, struct
dev, off, expr = sys.argv[1], int(sys.argv[2], 0), sys.argv[3]
n = 2 if off in (0x3a,) else 4
with open(dev, "r+b") as f:
    f.seek(1024 + off); v = int.from_bytes(f.read(n), "little")
    nv = eval(expr, {"v": v}); f.seek(1024 + off); f.write(nv.to_bytes(n, "little")); f.flush()
PY
	sync; mdadm --stop "$MD" > /dev/null 2>&1
}
trap 'detach; chown -R "${SUDO_UID:-0}:${SUDO_GID:-0}" "$WORK" 2>/dev/null' EXIT

echo "== loop-test: $BBV, md $MD, kernel $(uname -r), mdadm $(mdadm --version 2>&1 | cut -d' ' -f3)"
# ---------- the golden array: as stock leaves it ----------
for i in 0 1 2 3; do truncate -s 96M "$G/m$i.img"; done
attach "$G"
mdadm --create "$MD" --run --metadata=1.0 --level=5 --raid-devices=4 --chunk=64 --layout=left-symmetric --assume-clean --homehost=ex4test $LOOPS > "$LOG/create.txt" 2>&1 || { cat "$LOG/create.txt"; exit 1; }
mke2fs -q -t ext4 -O ^metadata_csum,^64bit -E stride=16,stripe_width=48 -L ex4test "$MD" || exit 1
mount "$MD" "$MNTD" && mkdir -p "$MNTD/Public/ex4-bench" && echo "his data stands here" > "$MNTD/Public/kurt-data.txt" \
	&& truncate -s 2147483648 "$MNTD/Public/ex4-bench/bench-2g.bin" "$MNTD/Public/ex4-bench/bench-write-2g.bin" && umount "$MNTD" || exit 1
mdadm --stop "$MD" > /dev/null; mdadm --examine $LOOPS > "$LOG/examine-golden.txt" 2>&1; detach
echo "golden: $(ls -s --block-size=1M "$G" | head -1) on disk for 4 x 96 MiB members"

# ---------- 1. the whole happy path ----------
fresh happy
EV1=$(events)
RB preflight > "$LOG/happy-preflight.txt" 2>&1; check "preflight passes on a clean array (examine walls, reboot paths, md5 of itself)" '[ $? = 0 ]'
RB arm > "$LOG/happy-arm.txt" 2>&1; check "arm prints a token line" 'grep -q "^  echo .EX4-RW t-happy [0-9a-f]\{12\}. > " "$LOG/happy-arm.txt"'
RB gate-check > /dev/null 2>&1; check "gate-check says no before anything is typed" '[ $? != 0 ]'
type_token "$LOG/happy-arm.txt"
RB gate-check > "$LOG/happy-gate.txt" 2>&1; check "gate-check says yes after the token is typed" '[ $? = 0 ]'
RB up 192.0.2.10 --stay > "$LOG/happy-up.txt" 2>&1; rc=$?
check "up: rc 0" '[ $rc = 0 ]'
check "up: the token was consumed (renamed away)" '[ ! -e "$TMPD/ex4-rw-ok" ] && ls "$TMPD"/ex4-rwbench/ex4-rw-ok.used-* > /dev/null 2>&1'
check "up: md is read-write, not read-only, [4/4] [UUUU], no sync line" 'grep -A2 "^$MDN " /proc/mdstat | grep -q "\[UUUU\]" && ! grep -A2 "^$MDN " /proc/mdstat | grep -qiE "read-only|resync|recover"'
check "up: sync_action is frozen" '[ "$(cat /sys/block/$MDN/md/sync_action)" = frozen ]'
check "up: ext4 mounted rw with data=ordered-family options, errors=remount-ro, noinit_itable" 'awk -v m="$MNTD" "\$2 == m" /proc/mounts | grep -qE " rw,.*errors=remount-ro" && awk -v m="$MNTD" "\$2 == m" /proc/mounts | grep -q noinit_itable'
check "up: dirty_bytes 64 MiB while rw" '[ "$(cat /proc/sys/vm/dirty_bytes)" = 67108864 ]'
check "up: the bench folder exists with its README" '[ -f "$MNTD/Public/ex4-bench-v8/README.txt" ]'
check "up: the active marker + the held auto-return (stay) exist" '[ -e "$TMPD/ex4-rw-active" ] && [ -e "$TMPD/ex4-stay" ]'
check "up: the guard runs" 'kill -0 "$(cat "$TMPD/ex4-rwbench/pid.guard" 2>/dev/null)" 2>/dev/null'
GUARDP=$(cat "$TMPD/ex4-rwbench/pid.guard" 2>/dev/null); echo "$GUARDP" > "$LOG/guard-pid.txt"
check "up (v9): the ext4 superblock's three feature words are recorded (compat, incompat, rocompat)" 'grep -qE "compat=[0-9a-f]+ incompat=[0-9a-f]+ rocompat=[0-9a-f]+" "$TMPD/ex4-rwbench/ext4-sb.txt"'
check "up (v9): the default window (25 min) is what the guard reads" '[ "$(cat "$TMPD/ex4-rwbench/window")" = 1500 ]'
RB up 192.0.2.10 > "$LOG/happy-up2.txt" 2>&1; check "a second up refuses (no token, already up)" '[ $? != 0 ]'
RB local > "$LOG/happy-local.txt" 2>&1; rc=$?
check "local: rc 0, a write and a read line with MiB/s and cpu busy" '[ $rc = 0 ] && grep -q "local dd write + sync: 64 MiB in" "$LOG/happy-local.txt" && grep -q "local dd read: 64 MiB" "$LOG/happy-local.txt"'
check "local: members wrote more than md (parity): ratio about 4/3" 'awk "/local dd write/ { for (i = 1; i <= NF; i++) { if (\$i == \"members\") m = \$(i + 2); if (\$i == \"md\") d = \$(i + 3) } } END { exit !(d > 0 && m / d > 1.2 && m / d < 1.5) }" "$LOG/happy-local.txt"'
check "local: its file is gone afterwards" '[ ! -e "$MNTD/Public/ex4-bench-v8/local-64m.bin" ]'
check "local (v9.3): a third row, the raw md read by stock's method; all three rows carry the knobs, skip=0 (no --skip-copy given)" 'grep -q "^raw md read (dd bs=1M count=32 skip=16, stock.s method): 32 MiB in" "$LOG/happy-local.txt" && [ "$(grep -c "| knobs sc=[0-9]* gt=[0-9]* skip=0 ra_md=[0-9]* ra_members=[0-9]*,[0-9]*,[0-9]*,[0-9]*\$" "$LOG/happy-local.txt")" = 3 ]'
RB serve samba4 192.0.2.11 > "$LOG/happy-serve-wrong.txt" 2>&1; check "serve refuses a client other than the one named at up" '[ $? != 0 ] && grep -q "is not the one named at up" "$LOG/happy-serve-wrong.txt"'
check "...a refusal of the arguments changes nothing: the session is still up" '[ -e "$TMPD/ex4-rw-active" ] && md_up && mnt_up'
RB serve smb1 192.0.2.10 > /dev/null 2>&1; check "serve refuses an unknown engine, session still up" '[ $? != 0 ] && [ -e "$TMPD/ex4-rw-active" ]'
RB serve nfs 192.0.2.10 > "$LOG/happy-nfs-noflag.txt" 2>&1; check "serve nfs WITHOUT --unauthenticated-nfs: refused (v9 must_fix), says why, session still up, no server" '[ $? != 0 ] && grep -q "trusts the client.s ADDRESS only" "$LOG/happy-nfs-noflag.txt" && [ -e "$TMPD/ex4-rw-active" ] && [ ! -e "$TMPD/ex4-rwbench/server" ]'
RB serve nfs 192.0.2.10 --yes > /dev/null 2>&1; check "serve nfs with another word than the flag: refused" '[ $? != 0 ] && [ ! -e "$TMPD/ex4-rwbench/server" ]'
RB serve samba4 192.0.2.10 --unauthenticated-nfs > /dev/null 2>&1; check "serve samba4 with a stray argument: refused" '[ $? != 0 ] && [ ! -e "$TMPD/ex4-rwbench/server" ]'
RB serve nfs 192.0.2.10 --unauthenticated-nfs > "$LOG/happy-nfs-flag.txt" 2>&1; check "serve nfs WITH --unauthenticated-nfs: accepted (test placeholder), then unserve" '[ $? = 0 ] && grep -q "nfs test" "$TMPD/ex4-rwbench/server"'
RB unserve > /dev/null 2>&1
CASE=happy2
RB serve samba4 192.0.2.10 > "$LOG/happy2-serve.txt" 2>&1; check "serve samba4 (test placeholder: the servers themselves run only on the box)" '[ $? = 0 ]'
RB sample begin smb-samba4-w1 > /dev/null 2>&1; dd if=/dev/zero of="$MNTD/Public/ex4-bench-v8/smb.bin" bs=1M count=32 conv=fsync 2>/dev/null
RB sample end smb-samba4-w1 32 1.5 > "$LOG/happy2-sample.txt" 2>&1
check "sample end reports MiB/s by the client clock + cpu + member writes" 'grep -q "smb-samba4-w1: 32 MiB in 1.5 s = 21.3 MiB/s (client clock)" "$LOG/happy2-sample.txt" && grep -q "members wrote" "$LOG/happy2-sample.txt"'
rm -f "$MNTD/Public/ex4-bench-v8/smb.bin"
RB heartbeat; check "heartbeat writes the uptime" '[ -s "$TMPD/ex4-rwbench/heartbeat" ]'
RB zap-zeros > "$LOG/happy2-zap.txt" 2>&1; rc=$?
check "zap-zeros: rc 0, both zero files gone, the folder Public/ex4-bench itself kept (v9: the files were asked gone, not the folder)" '[ $rc = 0 ] && [ -d "$MNTD/Public/ex4-bench" ] && [ -z "$(ls -A "$MNTD/Public/ex4-bench")" ]'
RB results-to-share; check "results land in the bench folder" '[ -s "$MNTD/Public/ex4-bench-v8/results.txt" ]'
sleep 0.5; holdp=; ( exec sleep 300 < "$MNTD/Public/ex4-bench-v8/README.txt" ) & holdp=$!; sleep 0.5
RB stop > "$LOG/happy2-stop.txt" 2>&1; rc=$?
check "stop: rc 0 (SAFE) even with a process holding a file under the mount" '[ $rc = 0 ] && grep -q "SAFE" "$LOG/happy2-stop.txt"'
check "stop: the holder was named and killed" 'grep -q "holds $MNTD" "$TMPD/ex4-rwbench/journal.txt" && ! kill -0 $holdp 2>/dev/null'
check "stop: md stopped, nothing mounted, marker gone, guard gone" '! md_up && ! mnt_up && [ ! -e "$TMPD/ex4-rw-active" ]'
check "stop: the writeback settings are back to what they were before up" '[ "$(cat /proc/sys/vm/dirty_bytes /proc/sys/vm/dirty_background_bytes /proc/sys/vm/dirty_ratio /proc/sys/vm/dirty_background_ratio | tr "\n" " ")" = "$VB0 $VBB0 $VR0 $VBR0 " ]'
check "stop: members clean, one events count, AAAA (examine after)" '[ "$(mdstate)" = "clean " ] && [ $(events | wc -w) = 1 ] && grep -q "events" "$TMPD/ex4-rwbench/journal.txt"'
check "stop: the held auto-return was given back (stay removed)" '[ ! -e "$TMPD/ex4-stay" ]'
check "stop (v9): the ext4 superblock read after the unmount: clean, compat / incompat / rocompat as before" 'grep -q "ext4 after the unmount: clean, feature words (compat incompat rocompat) as before" "$TMPD/ex4-rwbench/journal.txt" && grep -q "rocompat=" "$TMPD/ex4-rwbench/ext4-sb-after.txt" && [ "$(grep -o "rocompat=[0-9a-f]*" "$TMPD/ex4-rwbench/ext4-sb.txt")" = "$(grep -o "rocompat=[0-9a-f]*" "$TMPD/ex4-rwbench/ext4-sb-after.txt")" ]'
sleep 2
check "stop (v9): the stop did not kill the guard; with the marker gone the guard ended by itself" '[ -n "$GUARDP" ] && ! kill -0 "$GUARDP" 2>/dev/null && grep -q "^$GUARDP\$" "$LOG/guard-pid.txt"'
sleep 3; check "return-later: 2 s after the SAFE stop with no stay, the trial would go home (test marker)" '[ -s "$TMPD/ex4-rwbench/returned" ]'
RB stop > /dev/null 2>&1; check "stop again: nothing up, rc 0" '[ $? = 0 ]'
L=$(fs_look); check "after: fsck -fn of the file system is clean" '[ "$L" = "fsck=0" ]'
check "after: his file is untouched, the bench folder holds README + results only, stock's zero folder is empty but kept" 'grep -qx "his data stands here" "$LOG/kurt-$CASE.txt" && [ "$(grep ex4-bench "$LOG/files-$CASE.txt" | tr "\n" " ")" = "./Public/ex4-bench ./Public/ex4-bench-v8 ./Public/ex4-bench-v8/README.txt ./Public/ex4-bench-v8/results.txt " ]'

# ---------- 2. the token walls ----------
fresh token
RB up 192.0.2.10 > "$LOG/tok-unarmed.txt" 2>&1; check "token: up before arm refuses" '[ $? != 0 ] && grep -q "not armed" "$LOG/tok-unarmed.txt" && ! md_up'
RB arm > "$LOG/tok-arm.txt" 2>&1
RB up 192.0.2.10 > "$LOG/tok-none.txt" 2>&1; check "token: no token file -> refused, nothing assembled" '[ $? != 0 ] && grep -q "no .*ex4-rw-ok yet" "$LOG/tok-none.txt" && ! md_up'
sleep 1.1; echo "EX4-RW t-token 000000000000" > "$TMPD/ex4-rw-ok"
RB up 192.0.2.10 > "$LOG/tok-wrong.txt" 2>&1; check "token: a wrong token -> refused" '[ $? != 0 ] && grep -q "does not hold the token" "$LOG/tok-wrong.txt" && ! md_up'
type_token "$LOG/tok-arm.txt"; echo extra >> "$TMPD/ex4-rw-ok"
RB up 192.0.2.10 > "$LOG/tok-2lines.txt" 2>&1; check "token: two lines -> refused" '[ $? != 0 ] && grep -q "more than one line" "$LOG/tok-2lines.txt"'
type_token "$LOG/tok-arm.txt"; chown 1000 "$TMPD/ex4-rw-ok"
RB up 192.0.2.10 > "$LOG/tok-owner.txt" 2>&1; check "token: not owned by root -> refused" '[ $? != 0 ] && grep -q "not owned by root" "$LOG/tok-owner.txt"'
type_token "$LOG/tok-arm.txt"; mv "$TMPD/ex4-rw-ok" "$TMPD/real"; ln -s "$TMPD/real" "$TMPD/ex4-rw-ok"
RB up 192.0.2.10 > "$LOG/tok-link.txt" 2>&1; check "token: a symlink -> refused" '[ $? != 0 ] && grep -q "symlink" "$LOG/tok-link.txt"'
rm -f "$TMPD/ex4-rw-ok"; type_token "$LOG/tok-arm.txt"; sleep 1.1; RB arm > "$LOG/tok-rearm.txt" 2>&1
RB up 192.0.2.10 > "$LOG/tok-old.txt" 2>&1; check "token: typed before the last arm -> refused (the old token is void)" '[ $? != 0 ] && grep -qE "older than the last arm|does not hold" "$LOG/tok-old.txt" && ! md_up'
RB up 999.1.1.1 > "$LOG/tok-ip.txt" 2>&1; check "up without a valid client address -> refused" '[ $? != 0 ]'
RB up 127.0.0.1 > /dev/null 2>&1; check "up with a loopback client address -> refused" '[ $? != 0 ]'

# ---------- 3. the reboot-path walls ----------
fresh hooks
RB arm > "$LOG/h-arm.txt" 2>&1; type_token "$LOG/h-arm.txt"
echo '#!/bin/sh' > "$FROOT/etc/init.d/ex4-deadman"
RB up 192.0.2.10 > "$LOG/h-deadman.txt" 2>&1; check "reboot paths: an unpatched deadman -> refused" '[ $? != 0 ] && grep -q "ex4-deadman does not run" "$LOG/h-deadman.txt" && ! md_up'
mkhooks; rm -f "$FROOT/etc/rc.d/K01ex4-rwstop"
RB up 192.0.2.10 > "$LOG/h-k01.txt" 2>&1; check "reboot paths: no K01 link -> refused" '[ $? != 0 ] && grep -q "K01ex4-rwstop" "$LOG/h-k01.txt"'
mkhooks; rm -f "$FROOT/etc/init.d/ex4-trial"
RB up 192.0.2.10 > "$LOG/h-trial.txt" 2>&1; check "reboot paths: no S99 script -> refused" '[ $? != 0 ] && grep -q "ex4-trial is missing" "$LOG/h-trial.txt"'
mkhooks; cp "$SRC" "$WORK/other.sh"; echo "# changed" >> "$WORK/other.sh"; RBPATH=$WORK/other.sh
RB preflight > "$LOG/h-md5.txt" 2>&1; check "reboot paths: the script run differs from /usr/sbin/ex4-rwbench -> refused" '[ $? != 0 ] && grep -q "differs from the script being run" "$LOG/h-md5.txt"'
RBPATH=

# ---------- 4. the array walls (real md states) ----------
fresh three
LOOPS4=$LOOPS; LOOPS=$(echo $LOOPS4 | cut -d' ' -f1-3)
RB preflight > "$LOG/a-three.txt" 2>&1; check "array: three members -> refused" '[ $? != 0 ] && grep -q "found 3 member" "$LOG/a-three.txt"'
LOOPS=$LOOPS4
fresh setro
blockdev --setro "$(echo $LOOPS | cut -d' ' -f2)"
RB preflight > "$LOG/a-ro.txt" 2>&1; check "array: a member read-only in the kernel -> refused" '[ $? != 0 ] && grep -q "is read-only in the kernel" "$LOG/a-ro.txt"'
blockdev --setrw "$(echo $LOOPS | cut -d' ' -f2)"
fresh assembled
mdadm --assemble --readonly "$MD" $LOOPS > /dev/null 2>&1
RB preflight > "$LOG/a-asm.txt" 2>&1; check "array: already assembled -> refused" '[ $? != 0 ] && grep -q "already assembled" "$LOG/a-asm.txt"'
mdadm --stop "$MD" > /dev/null 2>&1
fresh dirty
mdadm --assemble --readonly "$MD" $LOOPS > /dev/null 2>&1; echo frozen > /sys/block/$MDN/md/sync_action; mdadm --readwrite "$MD" > /dev/null 2>&1
echo 0 > /sys/block/$MDN/md/resync_start; mdadm --stop "$MD" > /dev/null 2>&1
check "fixture: the superblocks now say State active (a resync is owed)" '[ "$(mdstate)" = "active " ]'
RB arm > "$LOG/a-dirty.txt" 2>&1; check "array: State active -> refused at arm (before any token)" '[ $? != 0 ] && grep -q "state .active., want clean" "$LOG/a-dirty.txt" && ! md_up'
fresh degraded
mdadm --assemble --run "$MD" $(echo $LOOPS | cut -d' ' -f1-3) > /dev/null 2>&1; mdadm --readwrite "$MD" > /dev/null 2>&1
mount "$MD" "$MNTD" && touch "$MNTD/Public/written-degraded" && umount "$MNTD"; mdadm --stop "$MD" > /dev/null 2>&1
RB preflight > "$LOG/a-degraded.txt" 2>&1; check "array: a member left behind (three assembled without it) -> refused" '[ $? != 0 ] && grep -qE "array state|events .* differ" "$LOG/a-degraded.txt"'
check "fixture: the refusal changed nothing (events still differ, nothing up)" '[ $(events | wc -w) -ge 1 ] && ! md_up'

# ---------- 5. the file-system walls (up assembles read-only, reads the superblock, refuses, stops) ----------
for fc in "recover 0x60 v|4 needs.recovery" "errors 0x3a v|2 state.not.clean" "orphan 0xe8 12 orphan.inode"; do
	set -- $fc; FC=$1; FPAT=$4
	fresh "fs-$1"; poke "$2" "$3"
	E0=$(events)
	RB arm > "$LOG/f-$1-arm.txt" 2>&1; type_token "$LOG/f-$1-arm.txt"
	RB up 192.0.2.10 > "$LOG/f-$1.txt" 2>&1; rc=$?
	check "fs: $1 flag set -> up refused, md stopped again, nothing mounted, SAFE, marker gone" '[ $rc != 0 ] && grep -qE "$FPAT" "$LOG/f-$FC.txt" && ! md_up && ! mnt_up && [ ! -e "$TMPD/ex4-rw-active" ]'
	check "fs: $FC: the read-only assembly wrote nothing (events $E0 unchanged)" '[ "$(events)" = "$E0" ]'
done
fresh exists
mdadm --assemble "$MD" $LOOPS > /dev/null 2>&1; mount "$MD" "$MNTD"; mkdir "$MNTD/Public/ex4-bench-v8"; umount "$MNTD"; mdadm --stop "$MD" > /dev/null 2>&1
RB arm > "$LOG/x-arm.txt" 2>&1; type_token "$LOG/x-arm.txt"
RB up 192.0.2.10 > "$LOG/x-exists.txt" 2>&1; check "folder: Public/ex4-bench-v8 exists already -> refused before read-write, stopped" '[ $? != 0 ] && grep -q "exists already" "$LOG/x-exists.txt" && ! md_up'

# ---------- 6. zap-zeros refusals (each: nothing removed) ----------
for zc in size link notzero hardlink; do
	fresh "zap-$zc"
	mdadm --assemble "$MD" $LOOPS > /dev/null 2>&1; mount "$MD" "$MNTD"; Z=$MNTD/Public/ex4-bench
	case $zc in
	size) truncate -s 2147483647 "$Z/bench-2g.bin";;
	link) rm "$Z/bench-2g.bin"; ln -s bench-write-2g.bin "$Z/bench-2g.bin";;
	notzero) printf 'x' | dd of="$Z/bench-write-2g.bin" bs=1 seek=1000000000 conv=notrunc 2>/dev/null;;
	hardlink) ln "$Z/bench-2g.bin" "$MNTD/Public/also-here.bin";;
	esac
	umount "$MNTD"; mdadm --stop "$MD" > /dev/null 2>&1
	RB arm > "$LOG/z-arm.txt" 2>&1; type_token "$LOG/z-arm.txt"; RB up 192.0.2.10 > /dev/null 2>&1
	RB zap-zeros > "$LOG/z-$zc.txt" 2>&1; rc=$?
	check "zap-zeros: $zc -> refused, both names still there, the session still up" '[ $rc != 0 ] && grep -q "nothing removed" "$LOG/z-$zc.txt" && [ -e "$Z/bench-write-2g.bin" ] && { [ -e "$Z/bench-2g.bin" ] || [ -L "$Z/bench-2g.bin" ]; } && [ -e "$TMPD/ex4-rw-active" ]'
	RB stop > /dev/null 2>&1
done

# ---------- 7. every exit path stops: signals, the guard ----------
fresh trap
RB arm > "$LOG/t-arm.txt" 2>&1; type_token "$LOG/t-arm.txt"; RB up 192.0.2.10 > /dev/null 2>&1
XENV="EX4RW_TEST_PAUSE=30"; ( RB local > "$LOG/t-local.txt" 2>&1 ) & LP=$!; sleep 3; XENV=
CP=$(cmdpid local); check "trap: found the shell running 'local' (pid ${CP:-none})" '[ -n "$CP" ]'
[ -n "$CP" ] && kill -TERM "$CP"; wait $LP 2>/dev/null; sleep 1
check "trap: SIGTERM to a running local (its file written, not yet synced or removed) -> the clean stop ran: md stopped, unmounted, marker gone" '! md_up && ! mnt_up && [ ! -e "$TMPD/ex4-rw-active" ] && grep -q "clean stop: SAFE" "$TMPD/ex4-rwbench/journal.txt"'
L=$(fs_look); check "trap: the file system is clean after the interrupted write" '[ "$L" = "fsck=0" ]'
fresh window
RB arm > "$LOG/g-arm.txt" 2>&1; type_token "$LOG/g-arm.txt"; XENV="EX4RW_WINDOW_SEC=2"; RB up 192.0.2.10 > /dev/null 2>&1; XENV=
sleep 4; check "guard: the rw window ran out -> the guard stopped md1 by itself" '! md_up && ! mnt_up && grep -q "guard: the rw window" "$TMPD/ex4-rwbench/journal.txt"'
fresh idle
RB arm > "$LOG/i-arm.txt" 2>&1; type_token "$LOG/i-arm.txt"; XENV="EX4RW_IDLE_SEC=2"; RB up 192.0.2.10 > /dev/null 2>&1; XENV=
sleep 4; check "guard: no client heartbeat -> the guard stopped md1 by itself" '! md_up && grep -q "no client heartbeat" "$TMPD/ex4-rwbench/journal.txt"'
fresh kmsg
RB arm > "$LOG/k-arm.txt" 2>&1; type_token "$LOG/k-arm.txt"; RB up 192.0.2.10 > /dev/null 2>&1; sleep 1.5
echo "ex4 rwbench loop-test: md/raid:$MDN: Disk failure on loop99 (a TEST line, nothing failed)" > /dev/kmsg
sleep 4; check "guard: an md 'Disk failure' line in the kernel log -> the guard stopped md1 by itself" '! md_up && grep -q "guard: kernel log" "$TMPD/ex4-rwbench/journal.txt"'
fresh kill9
RB arm > "$LOG/9-arm.txt" 2>&1; type_token "$LOG/9-arm.txt"; XENV="EX4RW_IDLE_SEC=8"; RB up 192.0.2.10 > /dev/null 2>&1
XENV="EX4RW_TEST_PAUSE=60"; ( RB local > /dev/null 2>&1 ) & sleep 3; XENV=; CP=$(cmdpid local); [ -n "$CP" ] && kill -KILL "$CP"
check "SIGKILL: the shell running 'local' was killed and md is still up right after (nothing could trap it)" '[ -n "$CP" ] && md_up'
sleep 12; check "SIGKILL of a running command (no trap can run): the guard's idle limit stopped md1" '! md_up && ! mnt_up'

# ---------- 7b. (v9) the window argument, a dead output pipe, a signal inside the stop ----------
fresh wargs
RB arm > "$LOG/w-arm.txt" 2>&1; type_token "$LOG/w-arm.txt"
RB up 192.0.2.10 --window-min 3 > "$LOG/w-3.txt" 2>&1; check "up --window-min 3: refused (5..45), nothing assembled, token kept" '[ $? != 0 ] && grep -q "5..45" "$LOG/w-3.txt" && ! md_up && [ -e "$TMPD/ex4-rw-ok" ]'
RB up 192.0.2.10 --window-min 50 > /dev/null 2>&1; check "up --window-min 50: refused" '[ $? != 0 ] && ! md_up'
RB up 192.0.2.10 --bogus > /dev/null 2>&1; check "up with an unknown argument: refused" '[ $? != 0 ] && ! md_up'
RB up 192.0.2.10 --stay --window-min 40 > "$LOG/w-40.txt" 2>&1; check "up --stay --window-min 40: accepted, the guard reads 2400 s" '[ $? = 0 ] && [ "$(cat "$TMPD/ex4-rwbench/window")" = 2400 ] && md_up'
( RB stop | head -c 0 ) > /dev/null 2>&1; sleep 1
check "SIGPIPE (v9): a stop whose output pipe is already closed (a dead ssh) still runs to SAFE: md stopped, unmounted, marker gone" '! md_up && ! mnt_up && [ ! -e "$TMPD/ex4-rw-active" ] && grep -q "clean stop: SAFE" "$TMPD/ex4-rwbench/journal.txt"'
fresh stopsig
RB arm > "$LOG/s-arm.txt" 2>&1; type_token "$LOG/s-arm.txt"; RB up 192.0.2.10 > /dev/null 2>&1
( exec sleep 300 < "$MNTD/Public/ex4-bench-v8/README.txt" ) & holdp=$!; sleep 0.5
( RB stop > "$LOG/s-stop.txt" 2>&1 ) & SP=$!; sleep 1
CP=$(cmdpid stop); [ -n "$CP" ] && { kill -TERM "$CP"; kill -HUP "$CP"; kill -INT "$CP"; }
wait $SP 2>/dev/null; sleep 0.5
check "a TERM + HUP + INT sent to a clean stop that is busy with a holder (v9: ignored inside the stop): the stop still ends SAFE" '[ -n "$CP" ] && ! md_up && ! mnt_up && [ ! -e "$TMPD/ex4-rw-active" ] && grep -q "SAFE" "$LOG/s-stop.txt"'
kill $holdp 2>/dev/null

# ---------- 7c. (v9.3) the knobs: skip_copy only before the mount, tune bounded and only while up, the raw read, the clean stop gives every knob back ----------
fresh knobs
J=$TMPD/ex4-rwbench/journal.txt; KS=$TMPD/ex4-rwbench/knobs.saved
lra() { for l in $LOOPS; do cat "/sys/block/${l##*/}/queue/read_ahead_kb"; done | tr '\n' ' '; }
LRA0=$(lra)
RB tune --stripe-cache 1024 > "$LOG/kn-notup.txt" 2>&1; check "tune before any session: refused (not up), nothing assembled" '[ $? != 0 ] && grep -q "is not up" "$LOG/kn-notup.txt" && ! md_up'
RB arm > "$LOG/kn-arm.txt" 2>&1; type_token "$LOG/kn-arm.txt"
RB up 192.0.2.10 --skip-copy 2 > "$LOG/kn-sc2.txt" 2>&1; check "up --skip-copy 2: refused, nothing assembled, token kept" '[ $? != 0 ] && grep -q "0 or 1" "$LOG/kn-sc2.txt" && ! md_up && [ -e "$TMPD/ex4-rw-ok" ]'
RB up 192.0.2.10 --skip-copy > /dev/null 2>&1; check "up --skip-copy without a value: refused, nothing assembled" '[ $? != 0 ] && ! md_up && [ -e "$TMPD/ex4-rw-ok" ]'
RB up 192.0.2.10 --skip-copy 1 > "$LOG/kn-up.txt" 2>&1; rc=$?
check "up --skip-copy 1: rc 0, mounted rw, skip_copy reads 1" '[ $rc = 0 ] && mnt_up && [ "$(cat /sys/block/$MDN/md/skip_copy)" = 1 ]'
check "up --skip-copy 1: journal order = knobs recorded at assembly, THEN skip_copy written, THEN the rw ext4 mount" 'a=$(grep -n "knobs at assembly" "$J" | head -1 | cut -d: -f1); b=$(grep -n "skip_copy=1 written" "$J" | head -1 | cut -d: -f1); c=$(grep -n "ext4 mounted rw" "$J" | head -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]'
SC0=$(awk '$2 == "stripe_cache_size" { print $3 }' "$KS" 2>/dev/null); GT0=$(awk '$2 == "group_thread_cnt" { print $3 }' "$KS" 2>/dev/null)
SK0=$(awk '$2 == "skip_copy" { print $3 }' "$KS" 2>/dev/null); MRA0=$(awk -v f="/sys/block/$MDN/queue/read_ahead_kb" '$2 == f { print $3 }' "$KS" 2>/dev/null)
check "up: the knob record holds the kernel's own values: skip_copy 0, a stripe cache, group threads, md1 read-ahead, the four member read-aheads as read before up ($LRA0)" '[ "$SK0" = 0 ] && [ -n "$SC0" ] && [ -n "$GT0" ] && [ -n "$MRA0" ] && [ "$(for l in $LOOPS; do awk -v f="/sys/block/${l##*/}/queue/read_ahead_kb" "\$2 == f { print \$3 }" "$KS"; done | tr "\n" " ")" = "$LRA0" ]'
RB tune --skip-copy 0 > "$LOG/kn-tsc.txt" 2>&1; check "tune --skip-copy on the mounted array: refused (wall 11), skip_copy still 1, session still up" '[ $? != 0 ] && grep -q "BEFORE the ext4 mount" "$LOG/kn-tsc.txt" && [ "$(cat /sys/block/$MDN/md/skip_copy)" = 1 ] && [ -e "$TMPD/ex4-rw-active" ] && mnt_up'
for bad in "" "--stripe-cache 255" "--stripe-cache 4097" "--stripe-cache 1k" "--readahead-kb 127" "--readahead-kb 8193" "--group-threads 3" "--group-threads -1" "--bogus 1" "--stripe-cache" "--stripe-cache 1024 --group-threads 3"; do
	RB tune $bad > "$LOG/kn-bad.txt" 2>&1; rc=$?
	check "tune ${bad:-(no argument)}: refused before anything is written (stripe cache, group threads, every read-ahead unchanged), session still up" '[ $rc != 0 ] && [ "$(cat /sys/block/$MDN/md/stripe_cache_size)" = "$SC0" ] && [ "$(cat /sys/block/$MDN/md/group_thread_cnt)" = "$GT0" ] && [ "$(cat /sys/block/$MDN/queue/read_ahead_kb)" = "$MRA0" ] && [ "$(lra)" = "$LRA0" ] && [ -e "$TMPD/ex4-rw-active" ]'
done
RB tune --stripe-cache 1024 --readahead-kb 1024 --group-threads 1 > "$LOG/kn-tune.txt" 2>&1; rc=$?
check "tune sc 1024, ra 1024, gt 1: rc 0; read back by the test: stripe_cache 1024, group threads 1, md1 read-ahead 1024, every member's read-ahead 1024" '[ $rc = 0 ] && [ "$(cat /sys/block/$MDN/md/stripe_cache_size)" = 1024 ] && [ "$(cat /sys/block/$MDN/md/group_thread_cnt)" = 1 ] && [ "$(cat /sys/block/$MDN/queue/read_ahead_kb)" = 1024 ] && [ "$(lra)" = "1024 1024 1024 1024 " ]'
KN="knobs sc=1024 gt=1 skip=1 ra_md=1024 ra_members=1024,1024,1024,1024"
check "tune: journalled before -> after" 'grep -q "tune: knobs sc=$SC0 gt=$GT0 skip=1 ra_md=$MRA0 .* -> sc=1024 gt=1 skip=1 ra_md=1024 ra_members=1024,1024,1024,1024" "$J"'
RB local --label "A B" > /dev/null 2>&1; check "local --label with odd characters: refused, session still up" '[ $? != 0 ] && [ -e "$TMPD/ex4-rw-active" ]'
RB local --bogus > /dev/null 2>&1; check "local with an unknown argument: refused, session still up" '[ $? != 0 ] && [ -e "$TMPD/ex4-rw-active" ]'
RB local --label a1 > "$LOG/kn-local.txt" 2>&1; rc=$?
check "local --label a1: write, read and raw md read rows, each labelled a1 and each carrying the knobs it ran under" '[ $rc = 0 ] && [ "$(grep -c "^a1 .*| $KN\$" "$LOG/kn-local.txt")" = 3 ] && grep -q "^a1 local dd write + sync: 64 MiB in" "$LOG/kn-local.txt" && grep -q "^a1 local dd read: 64 MiB in" "$LOG/kn-local.txt" && grep -q "^a1 raw md read (dd bs=1M count=32 skip=16, stock.s method): 32 MiB in .* MiB/s" "$LOG/kn-local.txt"'
check "raw md read: a read only (md wrote 0 MiB during it)" 'grep "raw md read" "$LOG/kn-local.txt" | grep -q "md $MDN wrote 0 MiB"'
RB sample begin kn-s1 > /dev/null 2>&1; RB sample end kn-s1 1 > "$LOG/kn-sample.txt" 2>&1
check "sample end: the line carries the knobs" 'grep -q "| $KN\$" "$LOG/kn-sample.txt"'
check "status: shows the knobs while up" 'RB status 2>/dev/null | head -1 | grep -q "knobs sc=1024 gt=1 skip=1"'
XENV="EX4RW_TEST_STOP_PAUSE=6"; ( RB stop > "$LOG/kn-stop.txt" 2>&1 ) & SP=$!; XENV=
n=0; while [ $n -lt 100 ] && ! grep -q "knobs restored" "$J" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
KB=$(echo "$(cat /sys/block/$MDN/md/stripe_cache_size 2>/dev/null) $(cat /sys/block/$MDN/md/group_thread_cnt 2>/dev/null) $(cat /sys/block/$MDN/md/skip_copy 2>/dev/null) $(cat /sys/block/$MDN/queue/read_ahead_kb 2>/dev/null)"); KMNT=$(mnt_up && echo mounted || echo unmounted)
wait $SP; rc=$?
check "THE CLEAN STOP gives the md knobs back BEFORE mdadm --stop: read back by the test during the stop (unmounted, md still up): stripe_cache $SC0, group threads $GT0, skip_copy 0, md1 read-ahead $MRA0" '[ "$KB" = "$SC0 $GT0 0 $MRA0" ] && [ "$KMNT" = unmounted ]'
check "THE CLEAN STOP: SAFE, md stopped; every member read-ahead back to what it was before up ($LRA0)" '[ $rc = 0 ] && ! md_up && ! mnt_up && [ "$(lra)" = "$LRA0" ]'
check "THE CLEAN STOP: the journal lists every knob restored (read back), none NOT restored; the record is kept as knobs.restored-*" 'grep -q "knobs restored (read back): stripe_cache_size=$SC0 group_thread_cnt=$GT0 skip_copy=0 ra:$MDN=$MRA0 ra:loop[0-9]*=" "$J" && ! grep -q "NOT restored" "$J" && [ ! -e "$KS" ] && ls "$TMPD"/ex4-rwbench/knobs.restored-* > /dev/null 2>&1'
RB tune --stripe-cache 1024 > "$LOG/kn-after.txt" 2>&1; check "tune after the stop: refused (not up)" '[ $? != 0 ] && grep -q "is not up" "$LOG/kn-after.txt"'
L=$(fs_look); check "knobs: the file system is clean after a skip_copy=1 session" '[ "$L" = "fsck=0" ]'
fresh knobsguard
RB arm > "$LOG/kg-arm.txt" 2>&1; type_token "$LOG/kg-arm.txt"; LRA0=$(lra); RB up 192.0.2.10 > /dev/null 2>&1
RB tune --readahead-kb 4096 > /dev/null 2>&1; : > "$TMPD/ex4-rwbench/guard-stop-now"; sleep 4
check "the guard's stop gives the knobs back too: md stopped, every member read-ahead back to $LRA0, journal says restored" '! md_up && [ "$(lra)" = "$LRA0" ] && grep -q "guard: test: guard-stop-now" "$J" && grep -q "knobs restored (read back)" "$J" && ! grep -q "NOT restored" "$J"'

# ---------- 7d. (v9.4) nfsd max_block_size (fake nfsd dir), the profile verb (fake tracing dir), the review's nits 1-3 ----------
fresh v94
J=$TMPD/ex4-rwbench/journal.txt; RS=$TMPD/ex4-rwbench/results.txt; NFD=$WORK/fake-nfsd; TRD=$WORK/fake-tracing
rm -rf "$NFD" "$TRD"; mkdir -p "$NFD" "$TRD/trace_stat"; echo 0 > "$NFD/threads"; echo 524288 > "$NFD/max_block_size"
XB="EX4RW_NFSD_DIR=$NFD EX4RW_TRACING=$TRD"; XENV=$XB
mbs() { cat "$NFD/max_block_size"; }
RB profile --label pre > "$LOG/v94-prof-notup.txt" 2>&1; check "profile before any session: refused (not up), nothing assembled" '[ $? != 0 ] && grep -q "is not up" "$LOG/v94-prof-notup.txt" && ! md_up'
RB arm > "$LOG/v94-arm.txt" 2>&1; type_token "$LOG/v94-arm.txt"
RB up 192.0.2.10 > "$LOG/v94-up.txt" 2>&1; check "v9.4 session: up rc 0" '[ $? = 0 ] && mnt_up'
NR0=$(wc -l < "$RS" 2>/dev/null || echo 0)
RB profile --label p0 > "$LOG/v94-prof-none.txt" 2>&1; rc=$?
check "profile on a kernel WITHOUT the function profiler (no function_profile_enabled): refused, says why, nothing written (no profile file, no results line), session still up" '[ $rc != 0 ] && grep -q "has no function profiler" "$LOG/v94-prof-none.txt" && [ ! -e "$TMPD/ex4-rwbench/profile-p0.txt" ] && [ "$(wc -l < "$RS" 2>/dev/null || echo 0)" = "$NR0" ] && [ -e "$TMPD/ex4-rw-active" ] && mnt_up'
for bad in "--max-block-kb 1000" "--max-block-kb" "--max-block-kb 32" "--max-block-kb 2048"; do
	RB serve nfs 192.0.2.10 --unauthenticated-nfs $bad > "$LOG/v94-nfsbad.txt" 2>&1; rc=$?
	check "serve nfs $bad: refused before anything changed (max_block_size still 524288, no server), session still up" '[ $rc != 0 ] && [ "$(mbs)" = 524288 ] && [ ! -e "$TMPD/ex4-rwbench/server" ] && [ ! -e "$TMPD/ex4-rwbench/nfs_mbs.saved" ] && [ -e "$TMPD/ex4-rw-active" ]'
done
RB serve samba4 192.0.2.10 --max-block-kb 1024 > "$LOG/v94-smbmbk.txt" 2>&1; check "serve samba4 --max-block-kb: refused (an NFS knob), max_block_size unchanged, no server" '[ $? != 0 ] && [ "$(mbs)" = 524288 ] && [ ! -e "$TMPD/ex4-rwbench/server" ]'
RB serve nfs 192.0.2.10 --max-block-kb 1024 > /dev/null 2>&1; check "serve nfs --max-block-kb without --unauthenticated-nfs: refused, unchanged" '[ $? != 0 ] && [ "$(mbs)" = 524288 ] && [ ! -e "$TMPD/ex4-rwbench/server" ]'
RB serve nfs 192.0.2.10 --unauthenticated-nfs --max-block-kb 1024 > "$LOG/v94-nfs1m.txt" 2>&1; rc=$?
check "serve nfs --max-block-kb 1024: rc 0; max_block_size reads 1048576; the kernel's 524288 recorded; the (fake) nfsd started AFTER the write" '[ $rc = 0 ] && [ "$(mbs)" = 1048576 ] && [ "$(cat "$TMPD/ex4-rwbench/nfs_mbs.saved")" = 524288 ] && [ "$(cat "$NFD/threads")" = 8 ]'
check "serve nfs --max-block-kb 1024: journal order = max_block_size 524288 -> 1048576 (before any nfsd thread) THEN the serve line, which carries it" 'a=$(grep -n "max_block_size 524288 -> 1048576 (written before any nfsd thread" "$J" | head -1 | cut -d: -f1); b=$(grep -n "serve: nfs up for 192.0.2.10.*nfs max_block_size=1048576 (set by --max-block-kb)" "$J" | head -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]'
RB sample begin nfs-w1 > /dev/null 2>&1; RB sample end nfs-w1 1 > "$LOG/v94-nfs-sample.txt" 2>&1
check "an NFS results line carries max_block_size (after the knobs)" 'grep -q "^nfs-w1: .*| knobs sc=.* | nfs max_block_size=1048576 (set by --max-block-kb)\$" "$LOG/v94-nfs-sample.txt"'
RB serve nfs 192.0.2.10 --unauthenticated-nfs --max-block-kb 512 > "$LOG/v94-nfs-running.txt" 2>&1; rc=$?
check "serve nfs --max-block-kb while nfsd runs (8 threads): refused, says so, nothing changed (1048576, nfsd still up, server still nfs), session still up" '[ $rc != 0 ] && grep -q "nfsd is already running" "$LOG/v94-nfs-running.txt" && [ "$(mbs)" = 1048576 ] && [ "$(cat "$NFD/threads")" = 8 ] && grep -q "^nfs" "$TMPD/ex4-rwbench/server" && [ -e "$TMPD/ex4-rw-active" ]'
RB unserve > /dev/null 2>&1
check "unserve: nfsd stopped (threads 0) THEN max_block_size back to the kernel's 524288 (read back, journalled), record gone" '[ "$(cat "$NFD/threads")" = 0 ] && [ "$(mbs)" = 524288 ] && grep -q "unserve: nfs max_block_size back to 524288 (read back)" "$J" && [ ! -e "$TMPD/ex4-rwbench/nfs_mbs.saved" ]'
RB serve nfs 192.0.2.10 --unauthenticated-nfs > /dev/null 2>&1; RB sample begin nfs-w2 > /dev/null 2>&1; RB sample end nfs-w2 1 > "$LOG/v94-nfs-def.txt" 2>&1
check "serve nfs with no --max-block-kb (the default): max_block_size not written (524288, no record); the line says kernel default" '[ "$(mbs)" = 524288 ] && [ ! -e "$TMPD/ex4-rwbench/nfs_mbs.saved" ] && grep -q "| nfs max_block_size=524288 (kernel default)\$" "$LOG/v94-nfs-def.txt" && ! grep -q "max_block_size .* -> " "$LOG/v94-nfs-def.txt"'
RB unserve > /dev/null 2>&1; RB serve samba4 192.0.2.10 > /dev/null 2>&1; RB sample begin smb-x > /dev/null 2>&1; RB sample end smb-x 1 > "$LOG/v94-smb.txt" 2>&1; RB unserve > /dev/null 2>&1
check "an SMB results line carries no NFS suffix (ends with the knobs)" 'grep -q "| knobs sc=[0-9]* gt=[0-9]* skip=[0-9]* ra_md=[0-9]* ra_members=[0-9,]*\$" "$LOG/v94-smb.txt" && ! grep -q "max_block_size" "$LOG/v94-smb.txt"'
# the profiler appears (a fake one: the file + two per-CPU stat files in the kernel's own column layout)
echo 0 > "$TRD/function_profile_enabled"
printf '  Function                               Hit    Time            Avg             s^2\n  --------                               ---    ----            ---             ---\n  raid5_make_request                     100    5000.000 us     50.000 us       1.000 us\n  mv_xor_tx_submit                       200    3000.000 us     15.000 us       1.000 us\n  ops_complete_reconstruct               50    100.000 us      2.000 us        0.000 us\n' > "$TRD/trace_stat/function0"
printf '  Function                               Hit    Time            Avg             s^2\n  --------                               ---    ----            ---             ---\n  raid5_make_request                     20    1000.000 us     50.000 us       1.000 us\n  submit_bio_noacct                      400    7000.500 us     17.501 us       1.000 us\n' > "$TRD/trace_stat/function1"
for bad in "--label A" "--label" "--label abcdefghijklmnopq" "--mib 0" "--mib 65" "--mib x" "--top 9" "--top 501" "--bogus"; do
	RB profile $bad > "$LOG/v94-profbad.txt" 2>&1; rc=$?
	check "profile $bad: refused, profiler untouched (0), no profile file, session still up" '[ $rc != 0 ] && [ "$(cat "$TRD/function_profile_enabled")" = 0 ] && ! ls "$TMPD"/ex4-rwbench/profile-*.txt > /dev/null 2>&1 && [ -e "$TMPD/ex4-rw-active" ]'
done
XENV="$XB EX4RW_TEST_PAUSE=4"; ( RB profile --label p1 --mib 16 --top 10 > "$LOG/v94-prof.txt" 2>&1 ) & PP=$!; XENV=$XB
n=0; while [ $n -lt 100 ] && ! grep -q "profile p1: function profiler ON" "$J" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done; sleep 0.5
PMID=$(cat "$TRD/function_profile_enabled"); wait $PP; rc=$?
check "profile p1: rc 0; the profiler read 1 DURING the write and 0 after it" '[ $rc = 0 ] && [ "$PMID" = 1 ] && [ "$(cat "$TRD/function_profile_enabled")" = 0 ]'
PF1=$TMPD/ex4-rwbench/profile-p1.txt
check "profile p1: profile-p1.txt merges function0 + function1 (hits and time summed per function), sorted by total time" '[ "$(sed -n 4p "$PF1")" = "7000.500 400 submit_bio_noacct" ] && [ "$(sed -n 5p "$PF1")" = "6000.000 120 raid5_make_request" ] && [ "$(sed -n 6p "$PF1")" = "3000.000 200 mv_xor_tx_submit" ] && [ "$(sed -n 7p "$PF1")" = "100.000 50 ops_complete_reconstruct" ] && [ "$(grep -vc "^#" "$PF1")" = 4 ] && grep -q "^# profile p1 .* 2 trace_stat/function\* file(s) merged" "$PF1"'
check "profile p1: results get the write row (labelled PROFILER ON, with knobs) and the summary (4 functions, top first, xor-path + per-row shares, ops_complete_reconstruct hits)" 'grep -q "^p1 profile local dd write + sync (PROFILER ON: counts only, never MiB/s): 16 MiB in .*| knobs sc=" "$RS" && grep -q "^p1 profile: 4 functions; top 5 by time: submit_bio_noacct (400 hits, 7000.500 us), raid5_make_request (120 hits, 6000.000 us)" "$RS" && grep -q "xor path 18.6% / per-row+bio 80.7% of summed time" "$RS" && grep -q "ops_complete_reconstruct hits 50\$" "$RS"'
check "profile p1: its write file is gone, the journal says ON then OFF" '[ ! -e "$MNTD/Public/ex4-bench-v8/profile-16m.bin" ] && grep -q "profile p1: function profiler OFF (reads 0)" "$J"'
mkdir -p "$WORK/fake-tracing-hits/trace_stat"; echo 0 > "$WORK/fake-tracing-hits/function_profile_enabled"     # a kernel without the graph tracer: "Function Hit" only
printf '  Function                               Hit\n  --------                               ---\n  raid5_make_request                     100\n  submit_bio_noacct                      400\n' > "$WORK/fake-tracing-hits/trace_stat/function0"
XENV="EX4RW_NFSD_DIR=$NFD EX4RW_TRACING=$WORK/fake-tracing-hits"; RB profile --label h1 --mib 8 --top 10 > "$LOG/v94-prof-hits.txt" 2>&1; rc=$?; XENV=$XB
check "profile on a kernel with hits only (no graph tracer: two columns): rc 0, functions kept with time 0, sorted by hits" '[ $rc = 0 ] && [ "$(sed -n 4p "$TMPD/ex4-rwbench/profile-h1.txt")" = "0.000 400 submit_bio_noacct" ] && [ "$(sed -n 5p "$TMPD/ex4-rwbench/profile-h1.txt")" = "0.000 100 raid5_make_request" ] && grep -q "^h1 profile: 2 functions" "$RS" && [ "$(cat "$WORK/fake-tracing-hits/function_profile_enabled")" = 0 ]'
RB profile --label p1 --mib 16 > "$LOG/v94-prof-again.txt" 2>&1; check "profile with a label already used: refused, profiler untouched" '[ $? != 0 ] && grep -q "one profile per label" "$LOG/v94-prof-again.txt" && [ "$(cat "$TRD/function_profile_enabled")" = 0 ]'
RB results-to-share; check "results-to-share copies the profile file into the bench folder" '[ -s "$MNTD/Public/ex4-bench-v8/profile-p1.txt" ]'
echo 1 > "$TRD/function_profile_enabled"
RB stop > "$LOG/v94-stop.txt" 2>&1; rc=$?
check "THE CLEAN STOP with the profiler left on: SAFE, and it wrote 0 to it (read back), journalled" '[ $rc = 0 ] && ! md_up && [ "$(cat "$TRD/function_profile_enabled")" = 0 ] && grep -q "clean stop: the function profiler was on (1): off (reads 0)" "$J"'
echo 1 > "$TRD/function_profile_enabled"
RB stop > "$LOG/v94-stop2.txt" 2>&1; check "stop with nothing up but the profiler on: it still runs and turns it off" '[ $? = 0 ] && [ "$(cat "$TRD/function_profile_enabled")" = 0 ]'
fresh v94term
NFD=$WORK/fake-nfsd; TRD=$WORK/fake-tracing; echo 0 > "$TRD/function_profile_enabled"; XB="EX4RW_NFSD_DIR=$NFD EX4RW_TRACING=$TRD"; XENV=$XB
RB arm > "$LOG/v94t-arm.txt" 2>&1; type_token "$LOG/v94t-arm.txt"; RB up 192.0.2.10 > /dev/null 2>&1
XENV="$XB EX4RW_TEST_PAUSE=30"; ( RB profile --label p2 --mib 8 > "$LOG/v94t-prof.txt" 2>&1 ) & PP=$!; XENV=$XB; sleep 3
PMID=$(cat "$TRD/function_profile_enabled"); CP=$(cmdpid "profile --label p2 --mib 8"); [ -n "$CP" ] && kill -TERM "$CP"; wait $PP 2>/dev/null; sleep 1
check "SIGTERM to a running profile (profiler on: $PMID) -> the clean stop ran (md stopped, unmounted, marker gone) and the profiler is OFF" '[ -n "$CP" ] && [ "$PMID" = 1 ] && ! md_up && ! mnt_up && [ ! -e "$TMPD/ex4-rw-active" ] && [ "$(cat "$TRD/function_profile_enabled")" = 0 ]'
# review nit 3 (a member with no read_ahead_kb) + nit 1 (a knob that did not go back keeps its record; stop retries)
fresh nits
J=$TMPD/ex4-rwbench/journal.txt; KS=$TMPD/ex4-rwbench/knobs.saved
NORA=$(echo $LOOPS | cut -d' ' -f2); OTH=$(echo $LOOPS | cut -d' ' -f3); LRA0=$(lra); XENV="EX4RW_TEST_NO_RA=$NORA"
RB arm > "$LOG/n-arm.txt" 2>&1; type_token "$LOG/n-arm.txt"
RB up 192.0.2.10 > "$LOG/n-up.txt" 2>&1; rc=$?
check "nit 3: a member with no read_ahead_kb does NOT refuse up: rc 0, journalled, that member not in the record, the other three are" '[ $rc = 0 ] && mnt_up && grep -q "up: no read_ahead_kb for $NORA" "$J" && ! grep -q "/${NORA##*/}/queue" "$KS" && [ "$(grep -c "^ra /sys/block/loop[0-9]*/queue/read_ahead_kb" "$KS")" = 3 ]'
NRA0=$(cat /sys/block/${NORA##*/}/queue/read_ahead_kb)
RB tune --readahead-kb 1024 > "$LOG/n-tune.txt" 2>&1; rc=$?
check "nit 3: tune --readahead-kb 1024: rc 0, that member skipped (journalled, its read-ahead untouched), the others 1024" '[ $rc = 0 ] && grep -q "tune: no read_ahead_kb for $NORA: skipped" "$J" && [ "$(cat /sys/block/${NORA##*/}/queue/read_ahead_kb)" = "$NRA0" ] && [ "$(cat /sys/block/${OTH##*/}/queue/read_ahead_kb)" = 1024 ]'
OV=$(awk -v f="/sys/block/${OTH##*/}/queue/read_ahead_kb" '$2 == f { print $3 }' "$KS")
sed -i "s|^ra /sys/block/${OTH##*/}/queue/read_ahead_kb .*|ra /sys/block/${OTH##*/}/queue/read_ahead_kb abc|" "$KS"      # a value the kernel refuses
RB stop > "$LOG/n-stop1.txt" 2>&1; rc=$?
check "nit 1: a member read-ahead that cannot go back: the stop is still SAFE, says NOT restored, and KEEPS knobs.saved for a retry" '[ $rc = 0 ] && ! md_up && grep -q "NOT restored: ra:${OTH##*/} (wanted abc" "$J" && grep -q "record kept in knobs.saved" "$J" && [ -s "$KS" ]'
RB stop > "$LOG/n-stop2.txt" 2>&1; rc=$?
check "nit 1: a second stop (nothing up, the record there) runs again and retries it (still NOT restored, record still kept)" '[ $rc = 0 ] && [ "$(grep -c "NOT restored: ra:${OTH##*/}" "$J")" = 2 ] && [ -s "$KS" ] && ! grep -q "nothing is up" "$LOG/n-stop2.txt"'
sed -i "s|^ra /sys/block/${OTH##*/}/queue/read_ahead_kb abc|ra /sys/block/${OTH##*/}/queue/read_ahead_kb $OV|" "$KS"
RB stop > "$LOG/n-stop3.txt" 2>&1; rc=$?
check "nit 1: once it can go back, the next stop restores it (read back), the record becomes knobs.restored-*, every member read-ahead is what it was ($LRA0)" '[ $rc = 0 ] && [ ! -e "$KS" ] && tail -1 "$J" | grep -q "SAFE" && grep "knobs restored" "$J" | tail -1 | grep -v -q "NOT restored" && [ "$(lra)" = "$LRA0" ]'
RB stop > "$LOG/n-stop4.txt" 2>&1; check "nit 1: and after that, stop says nothing is up" '[ $? = 0 ] && grep -q "nothing is up" "$LOG/n-stop4.txt"'
# review nit 2: skip_copy is never written on a mounted array, any value (umount made to fail: md stays assembled, mounted read-only)
fresh nit2
J=$TMPD/ex4-rwbench/journal.txt; KS=$TMPD/ex4-rwbench/knobs.saved
RB arm > "$LOG/n2-arm.txt" 2>&1; type_token "$LOG/n2-arm.txt"; RB up 192.0.2.10 --skip-copy 1 > /dev/null 2>&1
# a submount makes every umount of the bench mount fail with EBUSY (busybox ash may run its own umount applet: no PATH stub)
mount -t tmpfs -o size=1m,ro ex4test-submount "$MNTD/lost+found"
RB stop > "$LOG/n2-stop1.txt" 2>&1; rc=$?
umount "$MNTD/lost+found"
check "nit 2: umount fails 3 times -> remounted read-only, md still assembled; skip_copy NOT touched (still 1), journalled, record kept; the stop is SAFE (nothing read-write)" '{ [ $rc = 0 ] || [ $rc = 3 ]; } && md_up && mnt_up && ! awk -v m="$MNTD" "\$2 == m { split(\$4, o, \",\"); if (o[1] == \"rw\") f = 1 } END { exit !f }" /proc/mounts && [ "$(cat /sys/block/$MDN/md/skip_copy)" = 1 ] && grep -q "skip_copy (still mounted: not touched, reads 1, recorded 0)" "$J" && [ -s "$KS" ]'
XENV="EX4RW_TEST_STOP_PAUSE=6"; ( RB stop > "$LOG/n2-stop2.txt" 2>&1 ) & SP=$!; XENV=
n=0; while [ $n -lt 150 ] && [ "$(grep -c "knobs restored" "$J")" -lt 2 ]; do sleep 0.1; n=$((n + 1)); done
SKM=$(cat /sys/block/$MDN/md/skip_copy 2>/dev/null); KMNT=$(mnt_up && echo mounted || echo unmounted); wait $SP; rc=$?
check "nit 2: the next stop unmounts, THEN writes skip_copy back to 0 (read by the test during the stop, md still up), then stops md; record restored" '[ $rc = 0 ] && [ "$SKM" = 0 ] && [ "$KMNT" = unmounted ] && ! md_up && [ ! -e "$KS" ] && grep "knobs restored" "$J" | tail -1 | grep -q "skip_copy=0"'
XENV=

# ---------- 7e. (v9.7) NFSv4.2 only + threads + grace (fake nfsd + fake /proc/net), the auto-0 max_block_size, md5 / xsnap / facts ----------
fresh v97
J=$TMPD/ex4-rwbench/journal.txt; RS=$TMPD/ex4-rwbench/results.txt; NFD=$WORK/fake-nfsd7; PN=$WORK/fake-procnet; BF=$MNTD/Public/ex4-bench-v8
rm -rf "$NFD" "$PN"; mkdir -p "$NFD" "$PN"; echo 0 > "$NFD/threads"; echo 0 > "$NFD/max_block_size"; echo 90 > "$NFD/nfsv4gracetime"; echo "+3 +4 +4.0 +4.1 +4.2" > "$NFD/versions"
printf '# pool packets-arrived sockets-enqueued threads-woken threads-timedout\n0 100 10 90 0\n' > "$NFD/pool_stats"
TCPH='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
pn_only2049() { printf '%s\n   0: 00000000:0801 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 4001 1 0 100 0 0 10 0\n   1: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 4002 1 0 100 0 0 10 0\n' "$TCPH" > "$PN/tcp"
	printf '%s\n   0: 00000000000000000000000000000000:0801 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 4003 1 0 100 0 0 10 0\n' "$TCPH" > "$PN/tcp6"; : > "$PN/udp"; : > "$PN/udp6"; }
pn_only2049
X7="EX4RW_NFSD_DIR=$NFD EX4RW_PROCNET=$PN EX4RW_NFSD_WAIT=2"; XENV=$X7      # v9.8: a 2 s start-wait in the tests
mbs() { cat "$NFD/max_block_size"; }; grace() { cat "$NFD/nfsv4gracetime"; }
RB md5 x.bin > "$LOG/v97-md5-notup.txt" 2>&1; check "md5 before any session: refused (not up)" '[ $? != 0 ] && grep -q "is not up" "$LOG/v97-md5-notup.txt"'
RB facts extra > /dev/null 2>&1; check "facts with an argument: refused" '[ $? != 0 ]'
RB facts > "$LOG/v97-facts.txt" 2>&1; rc=$?
check "facts (read-only, no session needed): rc 0; cpuinfo, the nfsd knobs (fake), the nic section and interrupts in facts.txt; clk_summary said not read (test mode never mounts debugfs); journalled" '[ $rc = 0 ] && grep -q "^## cpuinfo" "$TMPD/ex4-rwbench/facts.txt" && grep -q "^nfsv4gracetime 90\$" "$TMPD/ex4-rwbench/facts.txt" && grep -q "^## net" "$TMPD/ex4-rwbench/facts.txt" && grep -q "^## interrupts" "$TMPD/ex4-rwbench/facts.txt" && grep -q "^(not readable: " "$TMPD/ex4-rwbench/facts.txt" && grep -q "facts: [0-9]* lines in facts.txt; clk_summary not read" "$J" && ! md_up'
RB arm > "$LOG/v97-arm.txt" 2>&1; type_token "$LOG/v97-arm.txt"
RB up 192.0.2.10 > "$LOG/v97-up.txt" 2>&1; check "v9.7 session: up rc 0" '[ $? = 0 ] && mnt_up'
for bad in "--vers 4.1" "--vers 4" "--vers" "--threads 0" "--threads 17" "--threads x" "--threads 007" "--threads"; do
	RB serve nfs 192.0.2.10 --unauthenticated-nfs $bad > "$LOG/v97-bad.txt" 2>&1; rc=$?
	check "serve nfs $bad: refused before anything changed (grace 90, threads 0, no server), session still up" '[ $rc != 0 ] && [ "$(grace)" = 90 ] && [ "$(cat "$NFD/threads")" = 0 ] && [ ! -e "$TMPD/ex4-rwbench/server" ] && [ -e "$TMPD/ex4-rw-active" ]'
done
RB serve ksmbd 192.0.2.10 --vers 4.2 > /dev/null 2>&1; check "serve ksmbd --vers 4.2: refused (an NFS knob)" '[ $? != 0 ] && [ ! -e "$TMPD/ex4-rwbench/server" ]'
RB serve samba4 192.0.2.10 --threads 4 > /dev/null 2>&1; check "serve samba4 --threads 4: refused (an NFS knob)" '[ $? != 0 ] && [ ! -e "$TMPD/ex4-rwbench/server" ]'
RB serve nfs 192.0.2.10 --vers 4.2 > "$LOG/v97-noflag.txt" 2>&1; check "serve nfs --vers 4.2 WITHOUT --unauthenticated-nfs: refused (v4.2 is the same address trust), nothing changed" '[ $? != 0 ] && grep -q "trusts the client.s ADDRESS only" "$LOG/v97-noflag.txt" && [ "$(grace)" = 90 ] && [ ! -e "$TMPD/ex4-rwbench/server" ]'
RB serve nfs 192.0.2.10 --unauthenticated-nfs --vers 4.2 --threads 4 > "$LOG/v97-v42.txt" 2>&1; rc=$?
check "serve nfs --vers 4.2 --threads 4: rc 0; server nfs4.2; versions v4.2-only (as the fake rpc.nfsd wrote them); threads 4 read back; grace 90 recorded, 10 written" '[ $rc = 0 ] && grep -q "^nfs4.2" "$TMPD/ex4-rwbench/server" && [ "$(cat "$NFD/threads")" = 4 ] && [ "$(grace)" = 10 ] && [ "$(cat "$TMPD/ex4-rwbench/nfs_grace.saved")" = 90 ]'
check "serve nfs --vers 4.2: journal order = grace 90 -> 10 (before any nfsd thread), versions read back + listeners 2049 only, threads 4, then the serve line (vers=4.2 threads=4)" 'a=$(grep -n "nfsv4gracetime 90 -> 10 s (written before any nfsd thread" "$J" | cut -d: -f1 | tail -1); b=$(grep -n "nfsd versions .-2 -3 +4 -4.0 -4.1 +4.2. (v4.2 only, read back); listeners: 2049 only (111, 32778, 32779, 32780 closed)" "$J" | cut -d: -f1 | tail -1); c=$(grep -n "serve nfs: nfsd threads 4 (read back)" "$J" | cut -d: -f1 | tail -1); d=$(grep -n "serve: nfs up for 192.0.2.10 .*(nfs4.2 test) | nfs max_block_size=0 (kernel default) vers=4.2 threads=4" "$J" | cut -d: -f1 | tail -1); [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ]'
RB sample begin n42-w1 > /dev/null 2>&1; RB sample end n42-w1 1 > "$LOG/v97-sample.txt" 2>&1
check "an NFSv4.2 results line ends with max_block_size and vers=4.2 threads=4" 'grep -q "| nfs max_block_size=0 (kernel default) vers=4.2 threads=4\$" "$LOG/v97-sample.txt"'
RB unserve > /dev/null 2>&1
check "unserve after v4.2: threads 0, THEN grace back to 90 (read back, journalled), the record and the vers/threads tag gone" '[ "$(cat "$NFD/threads")" = 0 ] && [ "$(grace)" = 90 ] && grep -q "unserve: nfsv4gracetime back to 90 (read back)" "$J" && [ ! -e "$TMPD/ex4-rwbench/nfs_grace.saved" ] && [ ! -e "$TMPD/ex4-rwbench/nfs_serve" ]'
RB serve nfs 192.0.2.10 --unauthenticated-nfs --threads 2 > /dev/null 2>&1; rc=$?; RB sample begin n3-w1 > /dev/null 2>&1; RB sample end n3-w1 1 > "$LOG/v97-v3t.txt" 2>&1
check "serve nfs --threads 2 (v3): rc 0, threads 2, grace never written (90, no record), the line says vers=3 threads=2" '[ $rc = 0 ] && [ "$(cat "$NFD/threads")" = 2 ] && [ "$(grace)" = 90 ] && [ ! -e "$TMPD/ex4-rwbench/nfs_grace.saved" ] && grep -q "| nfs max_block_size=0 (kernel default) vers=3 threads=2\$" "$LOG/v97-v3t.txt"'
RB unserve > /dev/null 2>&1
# the run-15 nit: the kernel reported 0 (auto) before --max-block-kb; 0 cannot be written back
RB serve nfs 192.0.2.10 --unauthenticated-nfs --max-block-kb 1024 > /dev/null 2>&1; RB unserve > /dev/null 2>&1
check "auto 0: unserve does NOT write 0 back (the kernel would clamp it to 1024 bytes): max_block_size stays 1048576; ONE INFO line (not a NOT-back failure); the record of 0 kept" '[ "$(mbs)" = 1048576 ] && [ "$(grep -c "unserve: INFO: nfs max_block_size was the kernel.s auto (0)" "$J")" = 1 ] && ! grep -q "max_block_size NOT back" "$J" && [ "$(cat "$TMPD/ex4-rwbench/nfs_mbs.saved")" = 0 ]'
RB serve nfs 192.0.2.10 --unauthenticated-nfs > /dev/null 2>&1; RB sample begin a0-w1 > /dev/null 2>&1; RB sample end a0-w1 1 > "$LOG/v97-auto.txt" 2>&1; RB unserve > /dev/null 2>&1
check "auto 0: a later default serve says the value was left by an earlier --max-block-kb (never \"kernel default\")" 'grep -q "| nfs max_block_size=1048576 (left by an earlier --max-block-kb: the kernel.s auto 0 cannot be written back)\$" "$LOG/v97-auto.txt"'
RB serve nfs 192.0.2.10 --unauthenticated-nfs --max-block-kb 512 > /dev/null 2>&1; RB sample begin a1-w1 > /dev/null 2>&1; RB sample end a1-w1 1 > "$LOG/v97-auto2.txt" 2>&1; RB unserve > /dev/null 2>&1
check "auto 0: a second --max-block-kb is set + said (set by --max-block-kb), the record still says 0, and its unserve adds NO second INFO" 'grep -q "| nfs max_block_size=524288 (set by --max-block-kb)\$" "$LOG/v97-auto2.txt" && [ "$(cat "$TMPD/ex4-rwbench/nfs_mbs.saved")" = 0 ] && [ "$(grep -c "unserve: INFO: nfs max_block_size" "$J")" = 1 ]'
# md5: the canary's box half
head -c 3145728 /dev/urandom > "$BF/t-w1.bin"; ln -s t-w1.bin "$BF/t-ln.bin"; HM=$(md5sum < "$BF/t-w1.bin" | cut -d" " -f1)
RB md5 t-w1.bin > "$LOG/v97-md5.txt" 2>&1; rc=$?
check "md5 t-w1.bin: rc 0; the md5 the box prints = this machine's md5 of the same bytes; bytes 3145728; in results.txt" '[ $rc = 0 ] && grep -q "^canary t-w1.bin md5 $HM bytes 3145728 " "$LOG/v97-md5.txt" && grep -q "^canary t-w1.bin md5 $HM" "$RS"'
for bad in "../x.bin" "T.bin" "t-w1.txt" "missing.bin" "t-ln.bin" "t-w1.bin extra" ""; do
	RB md5 $bad > "$LOG/v97-md5bad.txt" 2>&1; rc=$?; check "md5 '$bad': refused, the session still up (no stop)" '[ $rc != 0 ] && grep -q "REFUSED" "$LOG/v97-md5bad.txt" && [ -e "$TMPD/ex4-rw-active" ] && mnt_up'
done
rm -f "$BF/t-w1.bin" "$BF/t-ln.bin"
# xsnap: the instruments around a copy
RB xsnap end x1 > /dev/null 2>&1; check "xsnap end without a begin: refused" '[ $? != 0 ]'
RB xsnap begin "X;1" > /dev/null 2>&1; check "xsnap with an odd name: refused" '[ $? != 0 ]'
RB xsnap begin x1 > /dev/null 2>&1; printf '# pool packets-arrived sockets-enqueued threads-woken threads-timedout\n0 1124 10 1114 2\n' > "$NFD/pool_stats"; sleep 1
RB xsnap end x1 > "$LOG/v97-xsnap.txt" 2>&1; rc=$?
check "xsnap begin/end x1: rc 0; xstat-x1.txt holds the nonzero deltas (pool packets-arrived +1024, threads-woken +1024, threads-timedout +2, ctxt); the one-line summary in results.txt names ctxt, irq, softnet, the nfsd pool and vm" '[ $rc = 0 ] && grep -q "^pool packets-arrived 1024\$" "$TMPD/ex4-rwbench/xstat-x1.txt" && grep -q "^pool threads-woken 1024\$" "$TMPD/ex4-rwbench/xstat-x1.txt" && grep -q "^pool threads-timedout 2\$" "$TMPD/ex4-rwbench/xstat-x1.txt" && ! grep -q "^pool sockets-enqueued" "$TMPD/ex4-rwbench/xstat-x1.txt" && grep -q "^ctxt [0-9]" "$TMPD/ex4-rwbench/xstat-x1.txt" && grep -q "^xstat x1: [0-9.]* s | ctxt +[0-9]* ([0-9]*/s) | irq .* | softnet.* | nfsd pool.* packets-arrived +1024.* | vm" "$RS"'
RB results-to-share; check "results-to-share copies xstat-*.txt and facts.txt into the bench folder too" '[ -s "$BF/xstat-x1.txt" ] && [ -s "$BF/facts.txt" ]'
# the listener wall: something on 111 (rpcbind) after a v4.2 start = refused + THE CLEAN STOP (a door was open)
printf '%s\n   0: 00000000:006F 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 4009 1 0 100 0 0 10 0\n' "$TCPH" >> "$PN/tcp"
RB serve nfs 192.0.2.10 --unauthenticated-nfs --vers 4.2 > "$LOG/v97-111.txt" 2>&1; rc=$?
check "serve nfs --vers 4.2 with something listening on 111: refused, says which port, and the clean stop ran (md stopped, unmounted, marker gone, grace back to 90, threads 0)" '[ $rc != 0 ] && grep -q "something listens on port 111" "$LOG/v97-111.txt" && ! md_up && ! mnt_up && [ ! -e "$TMPD/ex4-rw-active" ] && [ "$(grace)" = 90 ] && [ "$(cat "$NFD/threads")" = 0 ]'
fresh v97b
J=$TMPD/ex4-rwbench/journal.txt; pn_only2049; echo 0 > "$NFD/threads"
RB arm > "$LOG/v97b-arm.txt" 2>&1; type_token "$LOG/v97b-arm.txt"; RB up 192.0.2.10 > /dev/null 2>&1
env -i PATH="$APPL:/usr/sbin:/usr/bin:/sbin:/bin" EX4RW_TEST=1 EX4RW_MEMBERS="$LOOPS" EX4RW_MD="$MD" EX4RW_TMP="$TMPD" EX4RW_ROOT="$FROOT" EX4RW_MNT="$MNTD" EX4RW_RUNID="t-$CASE" EX4RW_GUARD_SEC=1 EX4RW_RETURN_SEC=2 \
	EX4RW_NFSD_DIR="$NFD" EX4RW_PROCNET="$PN" EX4RW_NFSD_WAIT=2 EX4RW_TEST_NFSD_VERSIONS="+3 +4 +4.0 +4.1 +4.2" $ASH "$FROOT/usr/sbin/ex4-rwbench" serve nfs 192.0.2.10 --unauthenticated-nfs --vers 4.2 > "$LOG/v97b-vers.txt" 2>&1; rc=$?; XENV=$X7
check "serve nfs --vers 4.2 when nfsd's versions read back with v3 on: refused, says so, the clean stop ran (SAFE: md stopped, grace back)" '[ $rc != 0 ] && grep -q "want -3 in it (v4.2 only)" "$LOG/v97b-vers.txt" && ! md_up && [ ! -e "$TMPD/ex4-rw-active" ] && [ "$(grace)" = 90 ] && tail -1 "$J" | grep -q "SAFE"'
rm -f "$PN/tcp"; mkdir -p "$PN"; : > "$PN/tcp"; : > "$PN/tcp6"
fresh v97c
J=$TMPD/ex4-rwbench/journal.txt; echo 0 > "$NFD/threads"; XENV=$X7
RB arm > "$LOG/v97c-arm.txt" 2>&1; type_token "$LOG/v97c-arm.txt"; RB up 192.0.2.10 > /dev/null 2>&1
RB serve nfs 192.0.2.10 --unauthenticated-nfs --vers 4.2 > "$LOG/v97c-no2049.txt" 2>&1; rc=$?
check "serve nfs --vers 4.2 with NOTHING on 2049 after the start: refused (v9.8: by the start-wait, after its 2 s, saying threads 8 but no 2049) + the clean stop (SAFE)" '[ $rc != 0 ] && grep -q "nfsd is not up after 2 s (threads 8 but nothing listens on 2049)" "$LOG/v97c-no2049.txt" && ! md_up && [ ! -e "$TMPD/ex4-rw-active" ] && tail -1 "$J" | grep -q "SAFE"'
XENV=

# ---------- 7f. (v9.8) the user-copy canary (ucanary), the nfsd start-wait + client tracking, the nfs-utils socket wall ----------
fresh v98
J=$TMPD/ex4-rwbench/journal.txt; RS=$TMPD/ex4-rwbench/results.txt; BF=$MNTD/Public/ex4-bench-v8; KM=$WORK/fake-dmesg; PFD=$WORK/fake-procfd
rm -rf "$NFD" "$PN" "$PFD"; mkdir -p "$NFD" "$PN" "$PFD"; echo 0 > "$NFD/threads"; echo 0 > "$NFD/max_block_size"; echo 90 > "$NFD/nfsv4gracetime"; echo "+3 +4 +4.0 +4.1 +4.2" > "$NFD/versions"
pn_only2049; printf '[    1.0] boot line one\n[    2.0] boot line two\n' > "$KM"
X8="EX4RW_NFSD_DIR=$NFD EX4RW_PROCNET=$PN EX4RW_NFSD_WAIT=4 EX4RW_TEST_DMESG=$KM"; XENV=$X8
RB ucanary x.bin --md5 0123456789abcdef0123456789abcdef > "$LOG/v98-uc-notup.txt" 2>&1; check "ucanary before any session: refused (not up)" '[ $? != 0 ] && grep -q "is not up" "$LOG/v98-uc-notup.txt"'
RB arm > "$LOG/v98-arm.txt" 2>&1; type_token "$LOG/v98-arm.txt"
RB up 192.0.2.10 > "$LOG/v98-up.txt" 2>&1; check "v9.8 session: up rc 0" '[ $? = 0 ] && mnt_up'
# the ucanary: a 3 MiB non-zero file the "client" wrote, its md5 known here
head -c 3145728 /dev/urandom > "$BF/nfs-w1.bin"; UH=$(md5sum < "$BF/nfs-w1.bin" | cut -d" " -f1); ln -s nfs-w1.bin "$BF/uc-ln.bin"
for bad in "nfs-w1.bin" "nfs-w1.bin --md5" "nfs-w1.bin --md5 0123" "nfs-w1.bin --md5 $(echo "$UH" | tr a-f A-F)" "nfs-w1.bin --sum $UH" "../nfs-w1.bin --md5 $UH" "NFS.bin --md5 $UH" "nfs-w1.txt --md5 $UH" "missing.bin --md5 $UH" "uc-ln.bin --md5 $UH" "nfs-w1-ucopy.bin --md5 $UH" "nfs-w1.bin --md5 $UH extra"; do
	RB ucanary $bad > "$LOG/v98-ucbad.txt" 2>&1; rc=$?
	check "ucanary $bad: refused before anything ran, the session still up (no stop), no copy, no results row" '[ $rc != 0 ] && grep -q "REFUSED" "$LOG/v98-ucbad.txt" && [ -e "$TMPD/ex4-rw-active" ] && mnt_up && [ ! -e "$BF/nfs-w1-ucopy.bin" ] && ! grep -q "^ucanary" "$RS" 2>/dev/null'
done
: > "$BF/nfs-w1-ucopy.bin"; RB ucanary nfs-w1.bin --md5 "$UH" > "$LOG/v98-ucexist.txt" 2>&1; rc=$?
check "ucanary when its copy's name exists already: refused (never overwrites), the stand-in file untouched, session still up" '[ $rc != 0 ] && grep -q "exists already" "$LOG/v98-ucexist.txt" && [ -e "$BF/nfs-w1-ucopy.bin" ] && [ ! -s "$BF/nfs-w1-ucopy.bin" ] && [ -e "$TMPD/ex4-rw-active" ]'
rm -f "$BF/nfs-w1-ucopy.bin"
RB ucanary nfs-w1.bin --md5 "$UH" > "$LOG/v98-uc.txt" 2>&1; rc=$?
check "ucanary nfs-w1.bin (right md5): rc 0; four read rows at bs 4093 65521 131071 1048573 each md5 = the known one, OK" '[ $rc = 0 ] && for b in 4093 65521 131071 1048573; do grep -q "^ucanary nfs-w1.bin read bs=$b: md5 $UH OK (" "$LOG/v98-uc.txt" || exit 1; done'
check "ucanary: the copy row (bs 65521, md5 of the copy = the known one, the copy removed) and the OK summary (4 reads + 1 copy, the bytes, the kernel), all in results.txt; the source kept, the session still up" 'grep -q "^ucanary nfs-w1.bin copy bs=65521: md5 of the copy $UH OK (.*the copy removed)" "$LOG/v98-uc.txt" && grep -q "^ucanary nfs-w1.bin OK: md5 $UH on 4 odd-block reads (bs 4093 65521 131071 1048573) + 1 odd-block copy (bs 65521); 3145728 bytes; kernel $(uname -r); " "$RS" && [ "$(grep -c "^ucanary nfs-w1.bin" "$RS")" = 6 ] && [ ! -e "$BF/nfs-w1-ucopy.bin" ] && [ "$(md5sum < "$BF/nfs-w1.bin" | cut -d" " -f1)" = "$UH" ] && [ -e "$TMPD/ex4-rw-active" ] && mnt_up'
check "ucanary: journalled (name, bytes, known md5, kernel, the four sizes and the copy size)" 'grep -q "ucanary nfs-w1.bin: 3145728 bytes, known md5 $UH, kernel .*: 4093 65521 131071 1048573 then a copy at bs=65521" "$J"'
# a canary of an odd size (not a whole MiB, smaller than the biggest block): partial blocks everywhere
head -c 100003 /dev/urandom > "$BF/odd-w1.bin"; OH=$(md5sum < "$BF/odd-w1.bin" | cut -d" " -f1)
RB ucanary odd-w1.bin --md5 "$OH" > "$LOG/v98-ucodd.txt" 2>&1; check "ucanary on a 100003-byte file (every block size partial, 1048573 > the file): rc 0, OK" '[ $? = 0 ] && grep -q "^ucanary odd-w1.bin OK: md5 $OH .* 100003 bytes" "$LOG/v98-ucodd.txt"'
rm -f "$BF/odd-w1.bin" "$BF/uc-ln.bin"
# the start-wait: nfsd slow to come up (the fake's threads appear after 2 s), the kernel's -110 line = client tracking NONE
K110=$WORK/kmsg-110.txt; KLEG=$WORK/kmsg-legacy.txt; K110B=$WORK/kmsg-110b.txt
printf '[  553.084539] NFSD: Unable to initialize client recovery tracking! (-110)\n[  553.091202] NFSD: Is nfsdcld running? If not, enable CONFIG_NFSD_LEGACY_CLIENT_TRACKING.\n' > "$K110"
printf '[  600.000000] NFSD: Using legacy client tracking operations.\n' > "$KLEG"; cp "$K110" "$K110B"
XENV="$X8 EX4RW_TEST_NFSD_DELAY=2 EX4RW_TEST_NFSD_KMSG=$K110"
RB serve nfs 192.0.2.10 --unauthenticated-nfs > "$LOG/v98-slow.txt" 2>&1; rc=$?; XENV=$X8
check "serve nfs, nfsd up only after 2 s: rc 0 (no longer refused), threads 8, the journal says up after 2..3 s with rpc.nfsd rc 0" '[ $rc = 0 ] && [ "$(cat "$NFD/threads")" = 8 ] && grep -qE "serve nfs: nfsd up after [23] s \(rpc.nfsd rc 0, threads 8, 2049 listening\)" "$J"'
check "serve nfs: the serve line carries the start seconds and the client tracking the kernel reported (NONE, -110)" 'grep -qE "serve: nfs up for 192.0.2.10 .* \| nfsd up after [23] s .*client tracking: NONE \(unable to initialize \(-110\)" "$J"'
RB unserve > /dev/null 2>&1
XENV="$X8 EX4RW_TEST_NFSD_KMSG=$KLEG"
RB serve nfs 192.0.2.10 --unauthenticated-nfs --threads 4 > /dev/null 2>&1; rc=$?; XENV=$X8
check "serve nfs, the kernel logs legacy tracking (CONFIG_NFSD_LEGACY_CLIENT_TRACKING): rc 0, up after 0 s, the serve line says client tracking: legacy (only lines AFTER the start counted)" '[ $rc = 0 ] && grep "serve: nfs up for" "$J" | tail -1 | grep -q "nfsd up after 0 s (rpc.nfsd rc 0, threads 4, 2049 listening); client tracking: legacy"'
RB unserve > /dev/null 2>&1
RB serve nfs 192.0.2.10 --unauthenticated-nfs > /dev/null 2>&1; rc=$?
check "serve nfs, no new kernel line: client tracking: not reported (the old -110 / legacy lines are not re-read)" '[ $rc = 0 ] && grep "serve: nfs up for" "$J" | tail -1 | grep -q "client tracking: not reported"'
RB unserve > /dev/null 2>&1
XENV="$X8 EX4RW_TEST_NFSD_RC=1"; RB serve nfs 192.0.2.10 --unauthenticated-nfs > /dev/null 2>&1; rc=$?; XENV=$X8
check "serve nfs, rpc.nfsd rc 1 but nfsd runs exactly the 8 threads asked for (17D): taken, and the line says rc 1: taken" '[ $rc = 0 ] && grep "serve: nfs up for" "$J" | tail -1 | grep -q "rpc.nfsd rc 1: taken, nfsd runs the 8 threads asked for"'
RB unserve > /dev/null 2>&1
RB sample begin v98-x > /dev/null 2>&1; RB sample end v98-x 1 > "$LOG/v98-sample.txt" 2>&1
check "results lines are unchanged by the start-wait (no start text in a sample line)" '! grep -q "nfsd up after" "$LOG/v98-sample.txt"'
XENV="$X8 EX4RW_TEST_NFSD_RC=1 EX4RW_TEST_NFSD_THREADS=3"; RB serve nfs 192.0.2.10 --unauthenticated-nfs > "$LOG/v98-rc1.txt" 2>&1; rc=$?; XENV=$X8
check "serve nfs, rpc.nfsd rc 1 AND only 3 of 8 threads: refused (not taken) + THE CLEAN STOP (SAFE: md stopped, marker gone, threads 0)" '[ $rc != 0 ] && grep -q "rpc.nfsd said rc 1 and nfsd runs 3 threads, not the 8 asked for" "$LOG/v98-rc1.txt" && ! md_up && [ ! -e "$TMPD/ex4-rw-active" ] && [ "$(cat "$NFD/threads")" = 0 ] && tail -1 "$J" | grep -q "SAFE"'
fresh v98b
J=$TMPD/ex4-rwbench/journal.txt; echo 0 > "$NFD/threads"; XENV=$X8
RB arm > "$LOG/v98b-arm.txt" 2>&1; type_token "$LOG/v98b-arm.txt"; RB up 192.0.2.10 > /dev/null 2>&1
XENV="$X8 EX4RW_NFSD_WAIT=2 EX4RW_TEST_NFSD_DELAY=5 EX4RW_TEST_NFSD_KMSG=$K110B"
RB serve nfs 192.0.2.10 --unauthenticated-nfs > "$LOG/v98b-never.txt" 2>&1; rc=$?; XENV=$X8
check "serve nfs, nfsd not up within the wait (2 s; its threads come at 5 s): refused, says no nfsd thread after 2 s + the client tracking, THE CLEAN STOP ran (SAFE)" '[ $rc != 0 ] && grep -q "nfsd is not up after 2 s (no nfsd thread); client tracking: NONE (unable to initialize (-110)" "$LOG/v98b-never.txt" && ! md_up && [ ! -e "$TMPD/ex4-rw-active" ] && tail -1 "$J" | grep -q "SAFE"'
sleep 5; echo 0 > "$NFD/threads"      # the fake's late thread writer is done
# the nfs-utils socket wall (v95 nit 1), v4.2: a random-port mountd on the LAN is caught, loopback and other daemons are not
fresh v98c
J=$TMPD/ex4-rwbench/journal.txt; echo 0 > "$NFD/threads"; echo 90 > "$NFD/nfsv4gracetime"; pn_only2049
rm -rf "$PFD"; mkdir -p "$PFD/120/fd" "$PFD/121/fd" "$PFD/122/fd"
echo rpc.mountd > "$PFD/120/comm"; ln -s "socket:[5002]" "$PFD/120/fd/3"; ln -s "pipe:[77]" "$PFD/120/fd/4"; ln -s /dev/null "$PFD/120/fd/0"
echo dropbear > "$PFD/121/comm"; ln -s "socket:[5003]" "$PFD/121/fd/3"
echo rpc.statd > "$PFD/122/comm"; ln -s "socket:[5004]" "$PFD/122/fd/3"
# 5002 = mountd on 127.0.0.1:40001 (loopback: fine), 5003 = dropbear on 0.0.0.0:22 (not nfs-utils: fine), 5004 = statd, a CLOSED (TIME_WAIT 06) LAN socket
printf '   2: 0100007F:9C41 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 5002 1 0 100 0 0 10 0\n   3: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 5003 1 0 100 0 0 10 0\n   4: 0A00A8C0:9C42 0B00A8C0:0801 06 00000000:00000000 00:00000000 00000000     0        0 5004 1 0 100 0 0 10 0\n' >> "$PN/tcp"
XENV="$X8 EX4RW_PROCFD=$PFD"
RB arm > "$LOG/v98c-arm.txt" 2>&1; type_token "$LOG/v98c-arm.txt"; RB up 192.0.2.10 > /dev/null 2>&1
RB serve nfs 192.0.2.10 --unauthenticated-nfs --vers 4.2 > "$LOG/v98c-ok.txt" 2>&1; rc=$?
check "v4.2 + the nfs-utils socket wall, only loopback / non-nfs-utils / non-listening sockets: rc 0; the journal says none off 2049 and how many sockets it checked (2)" '[ $rc = 0 ] && grep -q "listeners: 2049 only (111, 32778, 32779, 32780 closed); nfs-utils sockets on LAN: none off 2049 (2 socket(s) of nfs-utils processes checked)" "$J"'
RB unserve > /dev/null 2>&1
# now mountd listens on a random LAN port (0.0.0.0:40000 TCP, inode 5005) and on UDP [::]:40002 (inode 5006)
ln -s "socket:[5005]" "$PFD/120/fd/5"; ln -s "socket:[5006]" "$PFD/120/fd/6"
printf '   5: 00000000:9C40 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 5005 1 0 100 0 0 10 0\n' >> "$PN/tcp"
printf '%s\n   0: 00000000000000000000000000000000:9C42 00000000000000000000000000000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 5006 2 0 0\n' "$TCPH" > "$PN/udp6"
RB serve nfs 192.0.2.10 --unauthenticated-nfs --vers 4.2 > "$LOG/v98c-mountd.txt" 2>&1; rc=$?
check "v4.2 with rpc.mountd listening on random LAN ports (tcp 40000, udp6 40002): refused, names both ports and the process, THE CLEAN STOP ran (SAFE, grace back to 90)" '[ $rc != 0 ] && grep -q "an nfs-utils process listens off 2049 on a LAN address (" "$LOG/v98c-mountd.txt" && grep -q "tcp 40000 rpc.mountd" "$LOG/v98c-mountd.txt" && grep -q "udp6 40002 rpc.mountd" "$LOG/v98c-mountd.txt" && ! md_up && [ ! -e "$TMPD/ex4-rw-active" ] && [ "$(grace)" = 90 ] && tail -1 "$J" | grep -q "SAFE"'
: > "$PN/udp6"; XENV=
# the ucanary FAIL path: a known md5 that is NOT the file's = every read row FAIL, a loud CANARY FAIL row, no copy, THE CLEAN STOP (SAFE)
fresh v98d
J=$TMPD/ex4-rwbench/journal.txt; RS=$TMPD/ex4-rwbench/results.txt; XENV=
RB arm > "$LOG/v98d-arm.txt" 2>&1; type_token "$LOG/v98d-arm.txt"; RB up 192.0.2.10 > /dev/null 2>&1
head -c 2097152 /dev/urandom > "$BF/nfs-w1.bin"; WH=$(head -c 2097152 /dev/zero | md5sum | cut -d" " -f1)
RB ucanary nfs-w1.bin --md5 "$WH" > "$LOG/v98d-ucfail.txt" 2>&1; rc=$?
check "ucanary with a known md5 that is not the file's: rc != 0; four read rows FAIL; a CANARY FAIL ucanary row (in results.txt and on stderr's refusal); no copy made; THE CLEAN STOP ran (SAFE: md stopped, unmounted, marker gone)" '[ $rc != 0 ] && [ "$(grep -c "^ucanary nfs-w1.bin read bs=[0-9]*: md5 [0-9a-f]* FAIL (" "$RS")" = 4 ] && grep -q "^CANARY FAIL ucanary nfs-w1.bin: the known md5 is $WH; read bs=4093 gave " "$RS" && grep -q "REFUSED: CANARY FAIL ucanary nfs-w1.bin" "$LOG/v98d-ucfail.txt" && ! grep -q "^ucanary nfs-w1.bin copy" "$RS" && ! md_up && ! mnt_up && [ ! -e "$TMPD/ex4-rw-active" ] && tail -1 "$J" | grep -q "SAFE"'
check "ucanary FAIL: the source file stays on the array to look at, no copy (read back read-only after the stop)" '[ "$(fs_look)" = fsck=0 ] && grep -q "^./Public/ex4-bench-v8/nfs-w1.bin\$" "$LOG/files-$CASE.txt" && ! grep -q "ucopy" "$LOG/files-$CASE.txt"'

# ---------- 7g. (v9.9, run 19) the memory receipt + the nfsd prep before every rpc.nfsd (fake /proc + fake /sys/kernel/slab) ----------
MP=$WORK/fake-memproc; SL=$WORK/fake-slab
mkmem() {        # $1 = MemFree kB, $2 = the zone's free pages: a 509 MB EX4 after the local rows (OpenWrt min_free_kbytes 16384)
	rm -rf "$MP"; mkdir -p "$MP/sys/vm"; : > "$MP/sys/vm/drop_caches"; echo 16384 > "$MP/sys/vm/min_free_kbytes"
	printf 'MemTotal:         509140 kB\nMemFree:        %8d kB\nMemAvailable:     396436 kB\nBuffers:            1200 kB\nCached:           380000 kB\nDirty:                 0 kB\nSlab:              21000 kB\nSReclaimable:       9000 kB\nSUnreclaim:        12000 kB\n' "$1" > "$MP/meminfo"
	printf 'Node 0, zone   Normal\n  per-node stats\n      nr_free_pages %d\n  pages free     %d\n        boost    0\n        min      4096\n        low      5120\n        high     6144\n        spanned  131072\n        present  131072\n        managed  127285\n        protection: (0, 0)\nNode 0, zone  Movable\n  pages free     0\n        min      0\n        low      0\n        high     0\n        managed  0\n' "$2" "$2" > "$MP/zoneinfo"
	echo 'Node 0, zone   Normal    120     80     40     10      3      1      0      0      0      0      0' > "$MP/buddyinfo"
}
rm -rf "$SL"; mkdir -p "$SL/:a-0000192" "$SL/kmalloc-8k" "$SL/:t-0000064"
ln -s :a-0000192 "$SL/dentry"; ln -s :a-0000192 "$SL/zz-alias"; ln -s :t-0000064 "$SL/kmalloc-64"
echo 0 > "$SL/:a-0000192/order"; echo 10 > "$SL/:a-0000192/partial"; echo 1 > "$SL/:a-0000192/cpu_slabs"
echo 3 > "$SL/kmalloc-8k/order"; echo "2 N0=2" > "$SL/kmalloc-8k/partial"; echo "1 N0=1" > "$SL/kmalloc-8k/cpu_slabs"
echo 0 > "$SL/:t-0000064/order"; echo 5 > "$SL/:t-0000064/partial"; echo 1 > "$SL/:t-0000064/cpu_slabs"
fresh v99
J=$TMPD/ex4-rwbench/journal.txt; RS=$TMPD/ex4-rwbench/results.txt; NR=$TMPD/ex4-rwbench/nfs
rm -rf "$NFD" "$PN"; mkdir -p "$NFD" "$PN"; echo 0 > "$NFD/threads"; echo 0 > "$NFD/max_block_size"; echo 90 > "$NFD/nfsv4gracetime"; echo "+3 +4 +4.0 +4.1 +4.2" > "$NFD/versions"
pn_only2049; printf '[    1.0] boot line one\n' > "$KM"; mkmem 22000 5500
X9="EX4RW_NFSD_DIR=$NFD EX4RW_PROCNET=$PN EX4RW_NFSD_WAIT=4 EX4RW_TEST_DMESG=$KM EX4RW_TEST_MEMPROC=$MP EX4RW_TEST_SLABSYS=$SL"; XENV=$X9
RB arm > "$LOG/v99-arm.txt" 2>&1; type_token "$LOG/v99-arm.txt"; RB up 192.0.2.10 > /dev/null 2>&1; check "v9.9 session: up rc 0" '[ $? = 0 ] && mnt_up'
for bad in "--nfsd-prep" "--nfsd-prep never" "--nfsd-prep EVERY" "--nfsd-prep 2"; do
	RB serve nfs 192.0.2.10 --unauthenticated-nfs $bad > "$LOG/v99-bad.txt" 2>&1; rc=$?
	check "serve nfs $bad: refused before anything changed (no receipt, no drop, no server, threads 0), session still up" '[ $rc != 0 ] && grep -q "REFUSED" "$LOG/v99-bad.txt" && [ ! -e "$NR/memrcpt-start1-before.out" ] && [ ! -s "$MP/sys/vm/drop_caches" ] && [ ! -e "$TMPD/ex4-rwbench/server" ] && [ "$(cat "$NFD/threads")" = 0 ] && [ -e "$TMPD/ex4-rw-active" ]'
done
RB serve samba4 192.0.2.10 --nfsd-prep every > "$LOG/v99-smb.txt" 2>&1; check "serve samba4 --nfsd-prep: refused (an NFS knob), nothing changed" '[ $? != 0 ] && grep -q "is an NFS knob" "$LOG/v99-smb.txt" && [ ! -e "$TMPD/ex4-rwbench/server" ]'
# start 1 (the session's FIRST start, as run 19A's), the default prep, --max-block-kb 1024: 258 pages per thread's bulk call
RB serve nfs 192.0.2.10 --unauthenticated-nfs --max-block-kb 1024 > "$LOG/v99-s1.txt" 2>&1; rc=$?
check "start 1 (default --nfsd-prep every, block 1024): rc 0, threads 8, drop_caches written 3 (the FIRST start is prepped, run 19A), the start counter 1" '[ $rc = 0 ] && [ "$(cat "$NFD/threads")" = 8 ] && [ "$(cat "$MP/sys/vm/drop_caches")" = 3 ] && [ "$(cat "$TMPD/ex4-rwbench/nfsd_starts")" = 1 ]'
check "start 1: the BEFORE receipt is a kept server log (nfs/*.out) with MemFree, MemAvailable, min_free_kbytes, the zone line, buddyinfo, the slab top from /sys/kernel/slab (lower bound, aliases folded: kmalloc-8k 96, dentry 44, kmalloc-64 24) and the fit" 'R=$NR/memrcpt-start1-before.out; grep -q "^MemFree: *22000 kB" "$R" && grep -q "^MemAvailable: *396436 kB" "$R" && grep -q "^## vm.min_free_kbytes 16384\$" "$R" && grep -q "^zone Normal free 5500 min 4096 low 5120 high 6144 managed 127285\$" "$R" && ! grep -q "^zone Movable" "$R" && grep -q "^Node 0, zone   Normal    120" "$R" && grep -q "^(no slabinfo: from .*a LOWER bound" "$R" && [ "$(sed -n "/^## slab top/,/^## fit/p" "$R" | grep -E "^[0-9]+ " | tr "\n" ",")" = "96 kmalloc-8k,44 dentry,24 kmalloc-64," ] && grep -q "^# memory receipt start1-before: .*v9-rwbench-9, nfsd threads now 0 (asked 8), max_block_size 1048576 (threads sized by 1048576)" "$R"'
check "start 1: the fit from the source (free 5500, low 5120, 258 pages per bulk call): the bulk fast path fits 1 of 8 threads" 'grep -q "^## fit: bulk fast path fits 1 of 8 threads (zone Normal: free 5500, low 5120 pages; 258 pages per thread bulk call)\$" "$NR/memrcpt-start1-before.out"'
check "start 1: journal order = max_block_size write, BEFORE receipt, AFTER receipt, the prep line, then nfsd up; the serve line carries the prep" 'a=$(grep -n "max_block_size 0 -> 1048576" "$J" | tail -1 | cut -d: -f1); b=$(grep -n "memory receipt start1-before: MemFree 22000 kB, MemAvailable 396436 kB, bulk fast path fits 1 of 8" "$J" | cut -d: -f1); c=$(grep -n "memory receipt start1-after: " "$J" | cut -d: -f1); d=$(grep -n "serve nfs: nfsd prep: start 1: sync + drop_caches (MemFree 22000 -> 22000 kB)" "$J" | cut -d: -f1); e=$(grep -n "serve nfs: nfsd up after" "$J" | tail -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ -n "$e" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] && [ "$d" -lt "$e" ] && grep "serve: nfs up for" "$J" | tail -1 | grep -q "; nfsd prep: start 1: sync + drop_caches"'
RB sample begin v99-x > /dev/null 2>&1; RB sample end v99-x 1 > "$LOG/v99-sample.txt" 2>&1
check "results lines are unchanged by the prep (no receipt or prep text in a sample line)" '! grep -qE "memory receipt|nfsd prep" "$LOG/v99-sample.txt" && ! grep -qE "memory receipt|nfsd prep" "$RS"'
RB unserve > /dev/null 2>&1; : > "$MP/sys/vm/drop_caches"; mkmem 21000 5300
# start 2, no --max-block-kb (1048576 stays: the auto 0 is not writable back), slabinfo present this time
printf 'slabinfo - version: 2.1\n# name            <active_objs> <num_objs> <objsize> <objperslab> <pagesperslab> : tunables <limit> <batchcount> <sharedfactor> : slabdata <active_slabs> <num_slabs> <sharedavail>\nkmalloc-8k            12     16   8192    4    8 : tunables    0    0    0 : slabdata      4      4      0\ndentry              2000   2100    192   21    1 : tunables    0    0    0 : slabdata    100    100      0\n' > "$MP/slabinfo"
RB serve nfs 192.0.2.10 --unauthenticated-nfs > "$LOG/v99-s2.txt" 2>&1; rc=$?
check "start 2 (default): rc 0, prepped again (drop_caches 3), counter 2, its own receipts (start2-before + -after), start 1's kept" '[ $rc = 0 ] && [ "$(cat "$MP/sys/vm/drop_caches")" = 3 ] && [ "$(cat "$TMPD/ex4-rwbench/nfsd_starts")" = 2 ] && [ -s "$NR/memrcpt-start2-before.out" ] && [ -s "$NR/memrcpt-start2-after.out" ] && [ -s "$NR/memrcpt-start1-before.out" ]'
check "start 2: slabinfo read when the kernel has it (num_slabs x pagesperslab x 4: dentry 400, kmalloc-8k 128); free 5300 fits 0 of 8 at 258 pages (the 18A-arm shape)" 'R=$NR/memrcpt-start2-before.out; grep -q "^(from slabinfo" "$R" && [ "$(sed -n "/^## slab top/,/^## fit/p" "$R" | grep -E "^[0-9]+ " | tr "\n" ",")" = "400 dentry,128 kmalloc-8k," ] && grep -q "fits 0 of 8 threads (zone Normal: free 5300, low 5120 pages; 258 pages" "$R"'
RB unserve > /dev/null 2>&1; rm -f "$MP/slabinfo"
RB stop > "$LOG/v99-stop.txt" 2>&1; check "v9.9 session: the clean stop after the serves (SAFE: md stopped, marker gone)" '[ $? = 0 ] && ! md_up && [ ! -e "$TMPD/ex4-rw-active" ]'      # fresh() does not stop a live md
fresh v99b
J=$TMPD/ex4-rwbench/journal.txt; NR=$TMPD/ex4-rwbench/nfs; echo 0 > "$NFD/threads"; echo 0 > "$NFD/max_block_size"; mkmem 22000 5500; XENV=$X9
RB arm > "$LOG/v99b-arm.txt" 2>&1; type_token "$LOG/v99b-arm.txt"; RB up 192.0.2.10 > /dev/null 2>&1
RB serve nfs 192.0.2.10 --unauthenticated-nfs --threads 4 --nfsd-prep second > "$LOG/v99b-s1.txt" 2>&1; rc=$?
check "--nfsd-prep second, start 1: rc 0, the BEFORE receipt only (auto 0: threads sized by 65536 from MemTotal = 18 pages, fits 4 of 4), caches kept (drop_caches untouched, no -after), journalled" '[ $rc = 0 ] && [ ! -s "$MP/sys/vm/drop_caches" ] && [ -s "$NR/memrcpt-start1-before.out" ] && [ ! -e "$NR/memrcpt-start1-after.out" ] && grep -q "max_block_size 0 (threads sized by 65536)" "$NR/memrcpt-start1-before.out" && grep -q "^## fit: bulk fast path fits 4 of 4 threads (zone Normal: free 5500, low 5120 pages; 18 pages per thread bulk call)" "$NR/memrcpt-start1-before.out" && grep -q "serve nfs: nfsd prep: start 1 of this session, --nfsd-prep second: caches kept" "$J"'
RB unserve > /dev/null 2>&1
RB serve nfs 192.0.2.10 --unauthenticated-nfs --nfsd-prep second > "$LOG/v99b-s2.txt" 2>&1; rc=$?
check "--nfsd-prep second, start 2: rc 0, prepped (drop_caches 3, start2-after written)" '[ $rc = 0 ] && [ "$(cat "$MP/sys/vm/drop_caches")" = 3 ] && [ -s "$NR/memrcpt-start2-after.out" ] && grep -q "serve nfs: nfsd prep: start 2: sync + drop_caches" "$J"'
RB unserve > /dev/null 2>&1; : > "$MP/sys/vm/drop_caches"
RB serve nfs 192.0.2.10 --unauthenticated-nfs --nfsd-prep off > "$LOG/v99b-s3.txt" 2>&1; rc=$?
check "--nfsd-prep off, start 3: rc 0, the receipt still written (before), no drop, journalled off" '[ $rc = 0 ] && [ ! -s "$MP/sys/vm/drop_caches" ] && [ -s "$NR/memrcpt-start3-before.out" ] && [ ! -e "$NR/memrcpt-start3-after.out" ] && grep -q "serve nfs: nfsd prep: start 3: off (--nfsd-prep off), caches kept" "$J"'
RB unserve > /dev/null 2>&1
# the run-19A failure shape: rpc.nfsd rc 1, 6 of 8 threads -> refused, the -refused receipt, THE CLEAN STOP (SAFE)
XENV="$X9 EX4RW_TEST_NFSD_RC=1 EX4RW_TEST_NFSD_THREADS=6"; RB serve nfs 192.0.2.10 --unauthenticated-nfs > "$LOG/v99b-19a.txt" 2>&1; rc=$?; XENV=$X9
check "the 19A shape (rc 1, 6 of 8): refused (not taken), start4-before/-after AND start4-refused receipts kept, the refused receipt journalled before the stop, SAFE" '[ $rc != 0 ] && grep -q "rpc.nfsd said rc 1 and nfsd runs 6 threads, not the 8 asked for" "$LOG/v99b-19a.txt" && [ -s "$NR/memrcpt-start4-before.out" ] && [ -s "$NR/memrcpt-start4-after.out" ] && grep -q "nfsd threads now 6 (asked 8)" "$NR/memrcpt-start4-refused.out" && a=$(grep -n "memory receipt start4-refused" "$J" | cut -d: -f1) && b=$(grep -n "REFUSED: rpc.nfsd said rc 1" "$J" | cut -d: -f1) && [ "$a" -lt "$b" ] && ! md_up && [ ! -e "$TMPD/ex4-rw-active" ] && tail -1 "$J" | grep -q "SAFE"'
# no fake memproc at all (every older case): receipts say not readable, no drop is attempted, the serve still works
fresh v99c
J=$TMPD/ex4-rwbench/journal.txt; NR=$TMPD/ex4-rwbench/nfs; echo 0 > "$NFD/threads"; echo 0 > "$NFD/max_block_size"
XENV="EX4RW_NFSD_DIR=$NFD EX4RW_PROCNET=$PN EX4RW_NFSD_WAIT=4 EX4RW_TEST_DMESG=$KM"
RB arm > "$LOG/v99c-arm.txt" 2>&1; type_token "$LOG/v99c-arm.txt"; RB up 192.0.2.10 > /dev/null 2>&1
RB serve nfs 192.0.2.10 --unauthenticated-nfs > "$LOG/v99c-s1.txt" 2>&1; rc=$?
check "test mode without the fakes: rc 0; the receipt says not readable (meminfo, zoneinfo, slab), fit not known; sync only, nothing written" '[ $rc = 0 ] && R=$NR/memrcpt-start1-before.out && grep -q "^(not readable: .*no-memproc/meminfo)" "$R" && grep -q "^(not readable: .*no-memproc/zoneinfo)" "$R" && grep -q "^(not readable: no .*slabinfo, no .*no-slabsys)" "$R" && grep -q "^## fit: fit not known (no zoneinfo)" "$R" && grep -q "serve nfs: nfsd prep: start 1: sync only (test mode without a fake drop_caches)" "$J" && [ ! -e "$TMPD/no-memproc" ]'
RB unserve > /dev/null 2>&1; RB stop > /dev/null 2>&1; check "v99c: the clean stop (SAFE)" '! md_up && [ ! -e "$TMPD/ex4-rw-active" ]'; XENV=

# ---------- 8. test-mode walls (so a test can never reach a real disk) ----------
CASE=walls
out=$(env -i PATH=/usr/bin:/bin EX4RW_TEST=1 EX4RW_MD=/dev/md1 EX4RW_TMP="$TMPD" EX4RW_ROOT="$FROOT" EX4RW_MNT="$MNTD" $ASH "$SRC" preflight 2>&1); check "test mode refuses /dev/md1" '[ $? != 0 ] && echo "$out" | grep -q "md90..md99"'
out=$(env -i PATH=/usr/bin:/bin EX4RW_TEST=1 EX4RW_MD=$MD EX4RW_MEMBERS=/dev/sda2 EX4RW_TMP="$TMPD" EX4RW_ROOT="$FROOT" EX4RW_MNT="$MNTD" $ASH "$SRC" preflight 2>&1); check "test mode refuses a non-loop member" '[ $? != 0 ] && echo "$out" | grep -q "loop devices only"'
out=$(env -i PATH=/usr/bin:/bin EX4RW_TEST=1 EX4RW_MD=$MD EX4RW_TMP=/tmp EX4RW_ROOT="$FROOT" EX4RW_MNT="$MNTD" $ASH "$SRC" preflight 2>&1); check "test mode refuses EX4RW_TMP=/tmp (the real token's folder)" '[ $? != 0 ]'
out=$(env -i PATH="$APPL:/usr/sbin:/usr/bin:/sbin:/bin" $ASH "$SRC" preflight 2>&1); check "outside test mode, on a machine that is not the trial -> refused" '[ $? != 0 ] && echo "$out" | grep -q "not the EX4 RAM trial"'
detach
[ -s "$LOG/udev.txt" ] && echo "note: $(wc -l < "$LOG/udev.txt") times udev auto-assembled the test loops (the box has no udev): stopped each time"
echo "== loop-test ($BBV): $P passed, $F failed"; [ $F = 0 ] || echo "failed:$FAILS"
[ $F = 0 ]
