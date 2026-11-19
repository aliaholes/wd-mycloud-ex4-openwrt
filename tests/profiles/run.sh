#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# run.sh : proves profiles/ex4-profile OFF the box, on fake /sys + /proc + /etc trees (no root, no disk, no kernel knob).
#   bash tests/profiles/run.sh --work NEW_DIR --rootfs ROOTFS [--ash host|arm]
#     ROOTFS = the image's own root (bin/busybox, sbin/uci, its libraries). Its uci is ALWAYS the one used (qemu-arm).
#     --ash host = the build box's busybox sh + applets (an applet that busybox build lacks: the host's tool)
#     --ash arm  = the IMAGE's busybox 1.37 (ARM, qemu-arm) as the shell AND every applet the tool calls
# What it proves (each line is a PASS/FAIL):
#   - the four shipped profiles are clean; every FORBIDDEN knob / word / character is refused and nothing is written
#   - the RAM cap (stripe_cache_size x 4 KiB x members <= 32 MiB) refuses before any write
#   - apply -> apply -> ... -> revert restores EVERY value byte-exact (sysfs, /proc/sys/vm incl. the dirty_* coupling,
#     the ext4 options, both SMB templates), in three array/mount states (trial-like, rw active, rw clean)
#   - a failed write mid-apply rolls back what was set and keeps the old choice
#   - what waits (read-only mount, clean rw array) waits and says why; `reapply` sets it once it can
#   - the scheduler this kernel lacks is reported "not on this box", never faked; spin-down only when ticked
#   - /tmp/ex4/profile.json is valid JSON with every card and the state; uci holds the one choice
set -u
WORK=; RFS=; ASH=host
while [ $# -gt 0 ]; do case "$1" in --work) WORK=$2;; --rootfs) RFS=$2;; --ash) ASH=$2;; *) sed -n '4,7p' "$0" >&2; exit 64;; esac; shift 2; done
[ -n "$WORK" ] && [ ! -e "$WORK" ] && [ -x "$RFS/sbin/uci" ] && [ -x "$RFS/bin/busybox" ] || { echo "REFUSED: --work NEW --rootfs ROOTFS (with sbin/uci, bin/busybox)" >&2; exit 1; }
command -v qemu-arm >/dev/null || { echo "REFUSED: no qemu-arm" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); PROF=$TOP/profiles; TOOL=$PROF/ex4-profile
mkdir -p "$WORK/bin" "$WORK/ucisave"; WORK=$(cd "$WORK" && pwd); RFS=$(cd "$RFS" && pwd)
P=0; F=0
ok() { P=$((P + 1)); echo "PASS  $*"; }
bad() { F=$((F + 1)); echo "FAIL  $*"; }
check() {           # on a FAIL, the first &&-piece that is false is named (the status a piece starting [ $? reads is the caller's)
	local rc0=$? piece
	if (exit $rc0); eval "$2"; then ok "$1"; return; fi
	bad "$1"
	while IFS= read -r piece; do (exit $rc0); eval "$piece" || { echo "      first false: $piece"; return; }; done <<< "$(printf '%s\n' "$2" | sed 's/ && /\n/g')"
}

# ---- the shell and the applets
APPLETS="cat awk sed grep sort tr cut wc cmp mv cp mkdir chmod date flock mktemp ls head logger rm"
if [ "$ASH" = arm ]; then
	mkdir -p "$WORK/armprefix/bin"; cp -a "$RFS/lib" "$WORK/armprefix/"; cp "$RFS/bin/busybox" "$WORK/armprefix/bin/"
	for a in $APPLETS; do printf '#!/bin/sh\nexec qemu-arm -L %s %s/bin/busybox %s "$@"\n' "$WORK/armprefix" "$WORK/armprefix" "$a" > "$WORK/bin/$a"; chmod 755 "$WORK/bin/$a"; done
	SH="qemu-arm -L $WORK/armprefix $WORK/armprefix/bin/busybox sh"; SHV="the image's $(strings "$RFS/bin/busybox" | grep -m1 -oE 'BusyBox v[0-9.]+') (ARM, qemu-arm)"
else
	BB=$(command -v busybox) || { echo "REFUSED: no busybox" >&2; exit 1; }
	for a in $APPLETS; do if "$BB" --list | grep -qx "$a"; then ln -s "$BB" "$WORK/bin/$a"; else ln -s "$(command -v "$a")" "$WORK/bin/$a"; echo "note: host busybox has no $a: host $(command -v "$a")"; fi; done
	SH="$BB sh"; SHV="host $("$BB" | head -1 | grep -oE 'BusyBox v[0-9.]+')"
fi
printf '#!/bin/sh\nexec qemu-arm -L %s %s/sbin/uci -t %s "$@"\n' "$RFS" "$RFS" "$WORK/ucisave" > "$WORK/bin/uci"; chmod 755 "$WORK/bin/uci"
cp "$HERE/stub-mount" "$WORK/bin/mount"; cp "$HERE/stub-smartctl" "$WORK/bin/smartctl"; chmod 755 "$WORK/bin/mount" "$WORK/bin/smartctl"
echo "shell: $SHV · uci: the image's (qemu-arm) · tool md5 $(md5sum < "$TOOL" | cut -c1-8)"
export PATH="$WORK/bin:/usr/bin:/bin"

# ---- a fake box: mkfake DIR ARRAY_STATE MOUNT(ro|rw|none) SCHEDULER_LINE [RAID_DISKS]
mkfake() {
	R=$1; mkdir -p "$R/sys/block/md1/queue" "$R/sys/block/md1/md" "$R/sys/block/md0/md" "$R/proc/sys/vm" "$R/etc/config" "$R/etc/samba" "$R/etc/ksmbd" "$R/tmp"
	echo 23416933248 > "$R/sys/block/md1/size"; echo 4194304 > "$R/sys/block/md0/size"
	echo 384 > "$R/sys/block/md1/queue/read_ahead_kb"; echo 256 > "$R/sys/block/md1/md/stripe_cache_size"; echo 0 > "$R/sys/block/md1/md/group_thread_cnt"
	echo "${5:-4}" > "$R/sys/block/md1/md/raid_disks"; echo "$2" > "$R/sys/block/md1/md/array_state"
	for d in sda sdb sdc sdd; do
		mkdir -p "$R/sys/block/md1/slaves/${d}2" "$R/sys/block/$d/queue"
		echo "$4" > "$R/sys/block/$d/queue/scheduler"; echo 31 > "$R/sys/block/$d/queue/nr_requests"; echo 128 > "$R/sys/block/$d/queue/read_ahead_kb"
	done
	printf '%s\n' 0 > "$R/proc/sys/vm/dirty_bytes"; echo 20 > "$R/proc/sys/vm/dirty_ratio"; echo 0 > "$R/proc/sys/vm/dirty_background_bytes"
	echo 10 > "$R/proc/sys/vm/dirty_background_ratio"; echo 3000 > "$R/proc/sys/vm/dirty_expire_centisecs"; echo 100 > "$R/proc/sys/vm/vfs_cache_pressure"
	{ echo "/dev/root / rootfs rw 0 0"; echo "tmpfs /tmp tmpfs rw,nosuid,nodev,noatime 0 0"
	  case "$3" in ro) echo "/dev/md1 /mnt/md1 ext4 ro,noatime,norecovery 0 0";; rw) echo "/dev/md1 /mnt/md1 ext4 rw,relatime,stripe=128,data=ordered 0 0";; esac; } > "$R/proc/mounts"
	cp "$TOP/webui/backend/etc/config/ex4" "$R/etc/config/ex4"
	cat "$RFS/etc/samba/smb.conf.template" > "$R/etc/samba/smb.conf.template"; cat "$RFS/etc/ksmbd/ksmbd.conf.template" > "$R/etc/ksmbd/ksmbd.conf.template"     # not cp: the rootfs copy is read-only
}
snap() { (cd "$1" && find . -type f ! -path './tmp/*' ! -path './etc/config/*' ! -name '*.log' | sort | xargs md5sum); }
T() { EX4P_ROOT=$R EX4P_DIR=${PD:-$PROF} EX4P_MOUNT=$WORK/bin/mount $SH "$TOOL" "$@"; }       # the tool, on the current fake box R
val() { cat "$R$1" 2>/dev/null; }
mopt() { awk '$2 == "/mnt/md1" { print $4 }' "$R/proc/mounts"; }
U() { "$WORK/bin/uci" -c "$R/etc/config" -q get "$1"; }

# ======== 1. the shipped profiles are clean
R=$WORK/f0; mkfake "$R" readonly ro "[none]"
for p in balanced movies smallfiles backups; do T check "$PROF/$p.conf" > "$WORK/check-$p.out" 2>&1; check "shipped profile $p.conf passes the allow-list" '[ $? = 0 ]'; done

# ======== 2. FORBIDDEN: each bad conf refused, nothing written
B0=$(snap "$R"); n=0
while IFS='|' read -r why line; do
	n=$((n + 1)); PD=$WORK/bad$n; mkdir -p "$PD"; cp "$PROF/balanced.conf" "$PD/"; printf 'title\tbad\n%s\n' "$line" > "$PD/movies.conf"
	T apply movies > "$WORK/bad$n.out" 2>&1; rc=$?
	check "refused ($why): $line" '[ $rc != 0 ] && grep -q REFUSED "$WORK/bad$n.out" && [ "$(snap "$R")" = "$B0" ] && [ ! -s "$R/mount.log" ]'
done <<'EOF'
data=writeback, even under an allowed knob|set	ext4.atime	data=writeback
nobarrier|set	ext4.atime	nobarrier
barrier=0|set	ext4.opts	barrier=0
a journal change|set	ext4.journal_async_commit	on
tune2fs|set	tune2fs.O	^has_journal
fsck|set	fsck.ext4	y
mkfs|opt	spindown	mkfs.ext4	1
mdadm grow|set	mdadm.grow	5
raid level|set	md.level	6
reshape|set	md.reshape	1
raid-devices|set	md.raid-devices	5
superblock write|set	md.superblock	write
chunk|set	md.chunk	128
sync_action|set	md.sync_action	check
discard|set	ext4.discard	on
errors= mount option|set	ext4.errors=continue	on
a knob not on the allow-list|set	md.skip_copy	1
a value out of range|set	md.stripe_cache_size	99999
a dirty ceiling of 1 GiB|set	vm.dirty_bytes	1073741824
a shell character|set	vm.dirty_bytes	67108864;reboot
a command substitution|set	vm.vfs_cache_pressure	$(reboot)
an unknown directive|run	tune2fs -O ^has_journal /dev/md1
a set with an extra field|set	ext4.commit	5	data=journal
an unknown opt|opt	turbo	ext4.commit	1
EOF
PD=$WORK/bad-mixed; mkdir -p "$PD"; cp "$PROF/balanced.conf" "$PD/"; { cat "$PROF/movies.conf"; printf 'set\text4.atime\tnoatime,data=writeback\n'; } > "$PD/movies.conf"
T apply movies > "$WORK/bad-mixed.out" 2>&1; rc=$?
check "one forbidden line among good ones refuses the WHOLE profile, before anything is written" '[ $rc != 0 ] && [ "$(snap "$R")" = "$B0" ] && [ "$(val /proc/sys/vm/dirty_ratio)" = 20 ]'
PD=$WORK/bad-bal; mkdir -p "$PD"; { cat "$PROF/balanced.conf"; printf 'set\tmdadm.level\t6\n'; } > "$PD/balanced.conf"; cp "$PROF/movies.conf" "$PD/"
T apply movies > "$WORK/bad-bal.out" 2>&1; rc=$?
check "a forbidden line in balanced.conf (the base) refuses every profile" '[ $rc != 0 ] && [ "$(snap "$R")" = "$B0" ]'
unset PD

# ======== 3. THE RAM CAP
PD=$WORK/ram; mkdir -p "$PD"; cp "$PROF/balanced.conf" "$PD/"; printf 'title\tram\nset\tmd.stripe_cache_size\t4096\n' > "$PD/movies.conf"
T apply movies > "$WORK/ram1.out" 2>&1; rc=$?
check "stripe_cache_size 4096 x 4 KiB x 4 = 64 MiB: refused (cap 32 MiB), nothing written" '[ $rc != 0 ] && grep -q "over the 32768 KiB cap" "$WORK/ram1.out" && [ "$(snap "$R")" = "$B0" ]'
R=$WORK/f5; mkfake "$R" readonly ro "[none]" 5; B5=$(snap "$R"); unset PD
T apply movies > "$WORK/ram2.out" 2>&1; rc=$?
check "the shipped Movies (2048) on a 5-member array = 40 MiB: refused, nothing written" '[ $rc != 0 ] && grep -q "40960 KiB" "$WORK/ram2.out" && [ "$(snap "$R")" = "$B5" ]'
R=$WORK/f0; T apply movies > "$WORK/ram3.out" 2>&1
check "the shipped Movies (2048) on the EX4's 4 members = exactly 32 MiB: allowed" '[ "$(val /sys/block/md1/md/stripe_cache_size)" = 2048 ]'
T revert > /dev/null 2>&1
check "  ... and reverted byte-exact" '[ "$(snap "$R")" = "$B0" ]'

# ======== 4. ROUND TRIPS, three box states
roundtrip() {      # $1 name, $2 array state, $3 mount, $4 scheduler line
	R=$WORK/rt-$1; mkfake "$R" "$2" "$3" "$4"; B=$(snap "$R"); M0=$(mopt)
	T apply movies --opt spindown > "$WORK/rt-$1-movies.out" 2>&1
	check "[$1] apply movies --opt spindown: ok, uci = movies + spindown, COMMITTED to /etc/config/ex4 (the file itself)" '[ $? = 0 ] && [ "$(U ex4.main.profile)" = movies ] && [ "$(U ex4.main.profile_opt)" = spindown ] && grep -qx "	option profile .movies." "$R/etc/config/ex4" && grep -qx "	list profile_opt .spindown." "$R/etc/config/ex4" && [ ! -s "$WORK/ucisave/ex4" ]'
	check "[$1]   vm.dirty_bytes 64 MiB, dirty_background_bytes 32 MiB (ratios zeroed, as the kernel does)" '[ "$(val /proc/sys/vm/dirty_bytes)" = 67108864 ] && [ "$(val /proc/sys/vm/dirty_background_bytes)" = 33554432 ] && [ "$(val /proc/sys/vm/dirty_ratio)" = 0 ]'
	check "[$1]   md1 read-ahead 6144 KiB" '[ "$(val /sys/block/md1/queue/read_ahead_kb)" = 6144 ]'
	check "[$1]   Samba template: our block with sendfile, receivefile, aio 0, nothing else touched" 'grep -qx "	use sendfile = yes" "$R/etc/samba/smb.conf.template" && grep -qx "	min receivefile size = 16384" "$R/etc/samba/smb.conf.template" && [ "$(T_strip "$R/etc/samba/smb.conf.template" | md5sum)" = "$(md5sum < "$RFS/etc/samba/smb.conf.template")" ]'
	check "[$1]   ksmbd template untouched (no ksmbd knob in Movies)" 'cmp -s "$R/etc/ksmbd/ksmbd.conf.template" "$RFS/etc/ksmbd/ksmbd.conf.template"'
	check "[$1]   spin-down: smartctl -s standby,240 on all four disks" '[ "$(grep -c "standby,240 /dev/sd" "$R/smartctl.log")" = 4 ]'
	T apply smallfiles --opt casesensitive > "$WORK/rt-$1-small.out" 2>&1
	check "[$1] apply smallfiles --opt casesensitive: Movies-only knobs go back (sendfile gone, spin-down off), its own set" '[ $? = 0 ] && ! grep -qx "	use sendfile = yes" "$R/etc/samba/smb.conf.template" && grep -qx "	case sensitive = yes" "$R/etc/samba/smb.conf.template" && [ "$(grep -c "standby,off /dev/sd" "$R/smartctl.log")" = 4 ] && [ "$(val /sys/block/md1/queue/read_ahead_kb)" = 128 ] && [ "$(val /proc/sys/vm/vfs_cache_pressure)" = 50 ] && [ "$(val /proc/sys/vm/dirty_bytes)" = 33554432 ]'
	T apply backups > "$WORK/rt-$1-backups.out" 2>&1
	check "[$1] apply backups: case-sensitive gone, fruit options in, vfs_cache_pressure back to 100" '[ $? = 0 ] && ! grep -qx "	case sensitive = yes" "$R/etc/samba/smb.conf.template" && grep -qx "	fruit:wipe_intentionally_left_blank_rfork = yes" "$R/etc/samba/smb.conf.template" && [ "$(val /proc/sys/vm/vfs_cache_pressure)" = 100 ] && [ "$(val /proc/sys/vm/dirty_expire_centisecs)" = 3000 ]'
	T apply balanced > "$WORK/rt-$1-balanced.out" 2>&1
	check "[$1] apply balanced: only the two dirty caps differ from the boot values; no Samba block left" '[ $? = 0 ] && [ "$(val /proc/sys/vm/dirty_bytes)" = 67108864 ] && [ "$(val /proc/sys/vm/dirty_background_bytes)" = 16777216 ] && cmp -s "$R/etc/samba/smb.conf.template" "$RFS/etc/samba/smb.conf.template" && [ "$(val /sys/block/md1/md/stripe_cache_size)" = 256 ]'
	T revert > "$WORK/rt-$1-revert.out" 2>&1
	check "[$1] revert: EVERY file byte-exact as before the first apply, the mount line identical, no choice in uci (file)" '[ $? = 0 ] && [ "$(snap "$R")" = "$B" ] && [ "$(mopt)" = "$M0" ] && [ -z "$(U ex4.main.profile)" ] && ! grep -q "option profile " "$R/etc/config/ex4"'
	check "[$1]   the mount stub saw no option outside the allow-list" '! grep -q BAD "$R/mount.log" 2>/dev/null'
	T apply movies > /dev/null 2>&1; T revert > /dev/null 2>&1
	check "[$1] apply movies -> revert directly: byte-exact again" '[ "$(snap "$R")" = "$B" ] && [ "$(mopt)" = "$M0" ]'
}
T_strip() { awk '$0 == "	# >>> ex4-profile (written by ex4-profile from the Storage page; do not edit by hand)" { on = 1; next } on && $0 == "	# <<< ex4-profile" { on = 0; next } !on' "$1"; }
roundtrip trial readonly ro "[none]"
check "[trial] stripe cache 2048 set on the read-only array (md writes nothing for a read-only array)" 'R=$WORK/rt-trial; T apply movies > /dev/null 2>&1; [ "$(val /sys/block/md1/md/stripe_cache_size)" = 2048 ]'
check "[trial] ext4 knobs WAIT on the ro,noload mount (said in current + json), the mount is never touched" 'R=$WORK/rt-trial; T current | grep -q "ext4.commit.*read-only" && [ ! -s "$R/mount.log" ] && python3 -c "import json,sys; j=json.load(open(sys.argv[1])); assert any(s[\"k\"]==\"ext4.commit\" and s[\"st\"]==\"waits\" for s in j[\"state\"])" "$R/tmp/ex4/profile.json"'
R=$WORK/rt-trial; T revert > /dev/null 2>&1
roundtrip rwactive active rw "[none] mq-deadline"
check "[rwactive] ext4: one remount -> noatime, commit=30 (and back to relatime, no commit= after revert)" 'R=$WORK/rt-rwactive; T apply movies > /dev/null 2>&1; [ "$(mopt)" = "rw,noatime,stripe=128,commit=30,data=ordered" ] && T revert > /dev/null 2>&1 && [ "$(mopt)" = "rw,relatime,stripe=128,data=ordered" ]'
check "[rwactive] a kernel that offers mq-deadline gets it (Many users), and back to none on revert" 'R=$WORK/rt-rwactive; T apply smallfiles > /dev/null 2>&1; [ "$(val /sys/block/sda/queue/scheduler)" = "none [mq-deadline]" ] && T revert > /dev/null 2>&1 && [ "$(val /sys/block/sda/queue/scheduler)" = "[none] mq-deadline" ]'
roundtrip rwclean clean rw "[none]"

# ======== 5. waits, not-on-this-box, reapply, --bench
R=$WORK/w1; mkfake "$R" clean rw "[none]"; T apply movies > "$WORK/w1.out" 2>&1
check "clean rw array: stripe_cache_size WAITS (md would write its clean flag), read-ahead still set" '[ "$(val /sys/block/md1/md/stripe_cache_size)" = 256 ] && [ "$(val /sys/block/md1/queue/read_ahead_kb)" = 6144 ] && grep -q "md.stripe_cache_size.*clean flag" "$R/tmp/ex4-profile/pending"'
T apply movies --bench > "$WORK/w1b.out" 2>&1; rc=$?
check "--bench outside a rw bench session is refused" '[ $rc != 0 ] && grep -q "only for a rw bench session" "$WORK/w1b.out"'
touch "$R/tmp/ex4-rw-active"; T apply movies --bench > "$WORK/w1c.out" 2>&1
check "--bench inside a session (/tmp/ex4-rw-active) sets it" '[ "$(val /sys/block/md1/md/stripe_cache_size)" = 2048 ]'
T revert > /dev/null 2>&1
check "  revert on a clean rw array: stripe cache restore WAITS too (exit 3, said), everything else restored" '[ "$(val /sys/block/md1/queue/read_ahead_kb)" = 384 ] && grep -q "md.stripe_cache_size" "$R/tmp/ex4-profile/pending"'
echo active > "$R/sys/block/md1/md/array_state"; T revert > /dev/null 2>&1
check "  ... and completes once the array is active" '[ "$(val /sys/block/md1/md/stripe_cache_size)" = 256 ] && [ ! -e "$R/tmp/ex4-profile/base.tsv" ]'
R=$WORK/w2; mkfake "$R" readonly ro "[none]"; T apply smallfiles > /dev/null 2>&1
check "Many users on this kernel: the scheduler is reported not on this box (offers only none), never faked" 'grep -q "disk.scheduler@sda.*offers only: none" "$R/tmp/ex4-profile/unavail" && [ "$(val /sys/block/sda/queue/scheduler)" = "[none]" ]'
check "no spin-down without the opt-in" '[ ! -s "$R/smartctl.log" ]'
sed -i 's#/dev/md1 /mnt/md1 ext4 ro,noatime,norecovery#/dev/md1 /mnt/md1 ext4 rw,relatime,stripe=128,data=ordered#' "$R/proc/mounts"; T reapply > /dev/null 2>&1
check "reapply after a writable mount sets the waiting ext4 knobs (noatime,lazytime)" '[ "$(mopt)" = "rw,noatime,lazytime,stripe=128,data=ordered" ] && ! grep -q "^ext4" "$R/tmp/ex4-profile/pending"'
R=$WORK/w3; mkfake "$R" readonly ro "[none]"; "$WORK/bin/uci" -c "$R/etc/config" set ex4.main.profile=movies; "$WORK/bin/uci" -c "$R/etc/config" commit ex4
T boot > /dev/null 2>&1
check "boot applies the uci choice (movies) with a fresh state" '[ "$(val /sys/block/md1/queue/read_ahead_kb)" = 6144 ] && grep -q "^profile movies" "$R/tmp/ex4-profile/applied"'
cp "$R/etc/samba/smb.conf.template" "$WORK/tpl-with-block"; mkdir -p "$WORK/w4"; R=$WORK/w4; mkfake "$R" readonly ro "[none]"; cat "$WORK/tpl-with-block" > "$R/etc/samba/smb.conf.template"
"$WORK/bin/uci" -c "$R/etc/config" set ex4.main.profile=balanced; "$WORK/bin/uci" -c "$R/etc/config" commit ex4; T boot > /dev/null 2>&1
check "a block left by an earlier boot is dropped when the choice no longer wants it" 'cmp -s "$R/etc/samba/smb.conf.template" "$RFS/etc/samba/smb.conf.template"'

# ======== 6. rollback on a failed write
R=$WORK/rb; mkfake "$R" readonly ro "[none]"; T apply backups > /dev/null 2>&1; B=$(snap "$R")
chmod 444 "$R/sys/block/md1/md/stripe_cache_size"
T apply movies > "$WORK/rb.out" 2>&1; rc=$?
chmod 644 "$R/sys/block/md1/md/stripe_cache_size"
check "a refused write mid-apply: exit 1, every knob it set put back, the old choice (backups) kept in the file" '[ $rc != 0 ] && grep -q "rolling back" "$WORK/rb.out" && [ "$(snap "$R")" = "$B" ] && [ "$(U ex4.main.profile)" = backups ] && grep -qx "	option profile .backups." "$R/etc/config/ex4"'

# ======== 6b. first boot (96_ex4_profile): a fresh box starts on Balanced; an existing choice is kept
R=$WORK/fb; mkfake "$R" readonly ro "[none]"; EX4_ROOT=$R $SH "$PROF/96_ex4_profile" > /dev/null 2>&1
check "96_ex4_profile on a fresh box: profile = balanced, committed" 'grep -qx "	option profile .balanced." "$R/etc/config/ex4"'
"$WORK/bin/uci" -c "$R/etc/config" set ex4.main.profile=movies; "$WORK/bin/uci" -c "$R/etc/config" commit ex4; EX4_ROOT=$R $SH "$PROF/96_ex4_profile" > /dev/null 2>&1
check "96_ex4_profile again: the owner's choice (movies) is kept" 'grep -qx "	option profile .movies." "$R/etc/config/ex4"'

# ======== 7. the page's file
R=$WORK/f0; T json > /dev/null 2>&1
check "profile.json: valid JSON, four cards, each change has label/value/when/ram_kib/why, Movies' stripe cache = 32768 KiB, nothing measured yet" 'python3 - "$R/tmp/ex4/profile.json" <<PY
import json, sys
j = json.load(open(sys.argv[1]))
ids = [p["id"] for p in j["profiles"]]
assert ids == ["balanced", "movies", "smallfiles", "backups"], ids
for p in j["profiles"]:
    assert p["measured"] is None and p["title"] and p["blurb"]
    for c in p["changes"]:
        assert all(k in c for k in ("k", "label", "value", "when", "ram_kib", "why", "opt")), c
m = [c for c in j["profiles"][1]["changes"] if c["k"] == "md.stripe_cache_size"][0]
assert m["ram_kib"] == 32768 and m["value"] == "2048 stripes", m
assert "spindown" in j["profiles"][1]["warn"] and "casesensitive" in j["profiles"][2]["warn"]
assert any("RAID 10" in a for a in j["profiles"][0]["advice"])
PY'
echo "== profiles run.sh ($SHV): $P passed, $F failed"; [ $F = 0 ]
