#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# stub-test.sh (v9.4: + --nfs-block, --arm-nfs, --profile/--profile-arms/--profile-mib, the profile fetch; v9.7: check_trial's
# truth table on a fake /proc, --nfs-vers/--nfs-threads/--nfs-ra-kb/--nfs-rsize/--nfs-wsize, NFS arm keys, the canary, --instruments; v9.8: --ucanary) : the examine walls of box/ex4-rwbench.sh against superblock states a loop device cannot easily be put
# in, fed from REAL `mdadm --examine` captures (captures/, mdadm 4.3, the EX4's geometry: 1.0, raid5, 64K, 4 devices)
# edited one field at a time; plus the client (host/ex4-rwbench-client.sh) against a fake ssh / sudo, every refusal
# path and every exit path. No root, no device, no network: mdadm, blockdev, id, ssh and sudo are stubs here.
#   bash tests/rwbench/stub-test.sh --work DIR
# The shell here is the build box's POSIX sh (dash), with busybox's awk/sed/grep...: busybox's own ash runs its
# applets in-process (FEATURE_PREFER_APPLETS), so a PATH stub for id or blockdev would never be called. The busybox
# ash of the image itself is exercised against real devices in loop-test.sh --ash arm.
set -u
WORK=
while [ $# -gt 0 ]; do case "$1" in --work) WORK=$2;; *) sed -n '7p' "$0" >&2; exit 64;; esac; shift 2; done
[ -n "$WORK" ] && [ ! -e "$WORK" ] || { echo "REFUSED: --work must be a NEW folder" >&2; exit 1; }
[ "$(id -u)" != 0 ] || { echo "REFUSED: no root needed, none wanted" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd)
mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd); FX=$WORK/fx; FB=$WORK/fakebin; FROOT=$WORK/root
mkdir -p "$FX" "$FB" "$FROOT/etc/init.d" "$FROOT/etc/rc.d" "$FROOT/usr/sbin"
P=0; F=0
ok() { P=$((P + 1)); echo "PASS  $*"; }
bad() { F=$((F + 1)); echo "FAIL  $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }
BB=$(command -v busybox) || { echo "REFUSED: no busybox" >&2; exit 1; }
for a in awk cat chmod cmp cut dd find grep head hexdump kill killall ls md5sum mkdir mv pidof rm sed sleep sort tail tee touch tr wc; do ln -s "$BB" "$FB/$a"; done
ASH="dash"; command -v dash > /dev/null || ASH="sh"
# ---- the stubs ----
printf '#!/bin/sh\necho 0\n' > "$FB/id"
cat > "$FB/mdadm" <<EOF
#!/bin/sh
case "\$1" in
--examine) d=\${2##*/}; [ -f "$FX/fail-\$d" ] && { echo "mdadm: cannot open \$2"; exit 1; }; cat "$FX/ex-\$d.txt";;
--examine-badblocks) d=\${2##*/}; if [ -f "$FX/bb-\$d.txt" ]; then cat "$FX/bb-\$d.txt"; else echo "Bad-blocks list is empty in \$2"; fi;;
*) echo "stub mdadm: \$* (not used by preflight)"; exit 9;;
esac
EOF
printf '#!/bin/sh\n[ "$1" = --getro ] && { cat "%s/ro-${2##*/}" 2>/dev/null || echo 0; exit 0; }\nexit 9\n' "$FX" > "$FB/blockdev"
chmod 755 "$FB/id" "$FB/mdadm" "$FB/blockdev"
cp "$TOP/box/ex4-rwbench.sh" "$FROOT/usr/sbin/ex4-rwbench"
for f in ex4-trial ex4-deadman ex4-rwstop; do printf 'ex4_rw_wait() { /usr/sbin/ex4-rwbench stop --for-reboot; }\n' > "$FROOT/etc/init.d/$f"; done
ln -s ../init.d/ex4-rwstop "$FROOT/etc/rc.d/K01ex4-rwstop"
M="/dev/loop70 /dev/loop71 /dev/loop72 /dev/loop73"
split_capture() {   # $1 = capture file: its four device blocks -> ex-loop70..73.txt
	awk -v d="$FX" 'BEGIN { n = 69 } /^\/dev\/loop[0-9]+:$/ { n++; f = d "/ex-loop" n ".txt"; next } f { print > f }' "$1"
}
PF() { env -i PATH="$FB:/usr/bin:/bin" EX4RW_TEST=1 EX4RW_MEMBERS="$M" EX4RW_MD=/dev/md98 EX4RW_TMP="$WORK/tmp" EX4RW_ROOT="$FROOT" EX4RW_MNT="$WORK/mnt" \
	$ASH "$FROOT/usr/sbin/ex4-rwbench" preflight > "$WORK/out.txt" 2>&1; }
var() {            # $1 = name, $2 = expected word in the refusal ("" = must pass), then edits: "N sed-expression" on device 7N
	name=$1; want=$2; shift 2; rm -f "$FX"/*; split_capture "$HERE/captures/examine-clean.txt"
	for e in "$@"; do n=${e%% *}; x=${e#* }; case "$n" in
		bb) printf 'Bad-blocks on /dev/loop71:\n          7811940000 for 8 sectors\n' > "$FX/bb-loop71.txt";;
		fail) : > "$FX/fail-loop72";;
		ro) echo 1 > "$FX/ro-loop73";;
		cap) split_capture "$HERE/captures/$x";;
		*) sed -i "$x" "$FX/ex-loop7$n.txt";;
	esac; done
	PF; rc=$?
	if [ -z "$want" ]; then check "examine: $name -> passes" '[ $rc = 0 ]'
	else check "examine: $name -> refused ($want)" '[ $rc != 0 ] && grep -q -- "$want" "$WORK/out.txt"'; fi
}
var "clean capture" ""
var "a write-intent bitmap (Feature Map 0x1)" "" "0 s/Feature Map : 0x0/Feature Map : 0x1/" "1 s/Feature Map : 0x0/Feature Map : 0x1/" "2 s/Feature Map : 0x0/Feature Map : 0x1/" "3 s/Feature Map : 0x0/Feature Map : 0x1/"
var "members out of step, all AAAA" "events 1 differ" "3 s/Events : 0/Events : 1/"
var "another array's member" "array UUID" "2 s/Array UUID : d0/Array UUID : e0/"
var "superblock 1.2" "superblock version" "0 s/Version : 1.0/Version : 1.2/"
var "raid6" "level" "0 s/Raid Level : raid5/Raid Level : raid6/"
var "chunk 512K" "chunk" "1 s/Chunk Size : 64K/Chunk Size : 512K/"
var "left-asymmetric" "layout" "2 s/Layout : left-symmetric/Layout : left-asymmetric/"
var "5 raid devices" "raid devices" "0 s/Raid Devices : 4/Raid Devices : 5/"
var "a reshape (Feature Map 0x4)" "feature map" "1 s/Feature Map : 0x0/Feature Map : 0x4/"
var "a reshape position line" "resync / recovery / reshape" "1 s/^\( *\)State : clean/  Reshape pos'n : 1024 (1.00 MiB)\n\1State : clean/"
var "real capture: recovery in progress (0x2 + Recovery Offset)" "resync / recovery / reshape" "cap examine-recovery-offset.txt"
var "real capture: written without a clean stop (State active)" "state 'active'" "cap examine-dirty-active.txt"
var "a member missing (AAA.)" "array state" "2 s/Array State : AAAA/Array State : AAA./"
var "two devices claim role 0" "device roles" "1 s/Active device 1/Active device 0/"
var "a spare" "device role" "3 s/Active device 3/spare/"
var "bad blocks recorded on a member" "bad blocks recorded" "bb x"
var "examine fails on a member" "examine /dev/loop72 failed" "fail x"
var "a member read-only in the kernel" "read-only in the kernel" "ro x"

# ---------- (v9.7) check_trial on a FAKE /proc (EX4RW_TEST_TRIAL): the xor-off truth table (run 15) + the other refusals ----------
CTR=$WORK/trial
TT() {             # $1 = name, $2 = run id ("" = no ex4boot_run=), $3 = xor line yes|no, $4 = expected refusal word ("" = passes), [$5 = edit]
	rm -rf "$CTR"; mkdir -p "$CTR/proc" "$CTR/etc"; rm -f "$FX"/*; split_capture "$HERE/captures/examine-clean.txt"
	if [ -n "$2" ]; then echo "console=ttyS0,115200n8 ex4boot_run=$2 root=/dev/ram0" > "$CTR/proc/cmdline"; else echo "console=ttyS0,115200n8 root=/dev/md0" > "$CTR/proc/cmdline"; fi
	printf '           CPU0       \n  1:      10234  orion_irq  11 Level     eth0\n 21:       4410  orion_irq  21 Level     sata_mv\n' > "$CTR/proc/interrupts"
	[ "$3" = yes ] && printf ' 30:        512  orion_irq  30 Level     mv_xor.0\n 31:        498  orion_irq  31 Level     mv_xor.1\n' >> "$CTR/proc/interrupts"
	printf "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='25.12.6'\n" > "$CTR/etc/openwrt_release"; echo 6.12.112 > "$CTR/uname-r"; : > "$CTR/ex4fan-running"
	case "${5:-}" in notowrt) echo "DISTRIB_ID='Debian'" > "$CTR/etc/openwrt_release";; oldkernel) echo 5.15.0 > "$CTR/uname-r";; nofan) rm -f "$CTR/ex4fan-running";; norel) rm -f "$CTR/etc/openwrt_release";; esac
	env -i PATH="$FB:/usr/bin:/bin" EX4RW_TEST=1 EX4RW_TEST_TRIAL="$CTR" EX4RW_MEMBERS="$M" EX4RW_MD=/dev/md98 EX4RW_TMP="$WORK/tmp" EX4RW_ROOT="$FROOT" EX4RW_MNT="$WORK/mnt" \
		$ASH "$FROOT/usr/sbin/ex4-rwbench" preflight > "$WORK/out.txt" 2>&1; rc=$?
	TW=$4
	if [ -z "$TW" ]; then check "check_trial (fake /proc): $1 -> passes" '[ $rc = 0 ] && grep -q "preflight passed" "$WORK/out.txt"'
	else check "check_trial (fake /proc): $1 -> refused ($TW)" '[ $rc != 0 ] && grep -q -- "$TW" "$WORK/out.txt"'; fi
}
TT "1/8 plain run id, two xor lines" 15-l2off-20261117-2222 yes ""
TT "2/8 plain run id, no xor line" 15-l2off-20261117-2222 no "no mv_xor interrupt line"
TT "3/8 -xoroff, no xor line" 15-l2off-20261117-2222-xoroff no ""
TT "4/8 -xoroff, an xor line" 15-l2off-20261117-2222-xoroff yes "run id says xoroff"
TT "5/8 -xoroff-prof, no xor line" 15-l2off-20261117-2222-xoroff-prof no ""
TT "6/8 -xoroff-prof, an xor line" 15-l2off-20261117-2222-xoroff-prof yes "run id says xoroff"
TT "7/8 -prof (xor on), two xor lines" 15-l2off-20261117-2222-prof yes ""
TT "8/8 -prof (xor on), no xor line" 15-l2off-20261117-2222-prof no "no mv_xor interrupt line"
TT "xoroff only as a prefix of a word (-xoroffx): NOT the xor-off kernel, so the xor line is required" 15-l2off-xoroffx no "no mv_xor interrupt line"
TT "no ex4boot_run= on the command line" "" yes "not the EX4 RAM trial"
TT "not OpenWrt" 15-l2off yes "not OpenWrt" notowrt
TT "no openwrt_release at all" 15-l2off yes "not OpenWrt" norel
TT "a 5.15 kernel" 15-l2off yes "kernel 5.15.0" oldkernel
TT "ex4fan not running" 15-l2off yes "ex4fan is not running" nofan
env -i PATH="$FB:/usr/bin:/bin" EX4RW_TEST=1 EX4RW_MEMBERS="$M" EX4RW_MD=/dev/md98 EX4RW_TMP="$WORK/tmp" EX4RW_ROOT="$FROOT" EX4RW_MNT="$WORK/mnt" $ASH "$FROOT/usr/sbin/ex4-rwbench" preflight > "$WORK/out.txt" 2>&1
check "check_trial: test mode WITHOUT EX4RW_TEST_TRIAL still skips it (as before v9.7: the loop tests' preflight)" '[ $? = 0 ]'
inblock() { sed -n '/^if \[ "$TEST" = 1 \]; then$/,/^fi$/p' "$TOP/box/ex4-rwbench.sh" | grep -qF 'CTR=${EX4RW_TEST_TRIAL:-}'; }
check "check_trial: on the box its inputs are the real /proc/cmdline, /proc/interrupts, /etc/openwrt_release, uname -r, pidof ex4fan (the fake root is read only inside the EX4RW_TEST=1 block)" 'grep -q "^CT_CMD=/proc/cmdline; CT_IRQ=/proc/interrupts; CT_REL=/etc/openwrt_release; CT_KREL=; CT_FAN= " "$TOP/box/ex4-rwbench.sh" && inblock && [ "$(grep -c "EX4RW_TEST_TRIAL" "$TOP/box/ex4-rwbench.sh")" -ge 2 ]'

# ---------- the client, against a fake trial ----------
CB=$WORK/clientbin; mkdir -p "$CB"; LOGF=$WORK/ssh.log
BOXMD5=$(md5sum < "$TOP/box/ex4-rwbench.sh" | cut -d' ' -f1)
cat > "$CB/ssh" <<EOF
#!/bin/bash
cmd=\${@: -1}; echo "\$cmd" >> "$LOGF"; sc=\$(cat "$WORK/scenario")
case "\$cmd" in
'cat /proc/cmdline') [ "\$sc" = notrial ] && echo "console=ttyS0 root=/dev/md0" || echo "console=ttyS0,115200n8 ex4boot_run=11-l2off-test";;
'md5sum < /usr/sbin/ex4-rwbench') [ "\$sc" = md5 ] && echo "00000000000000000000000000000000  -" || echo "$BOXMD5  -";;
*' preflight') [ "\$sc" = preflight ] && { echo "ex4-rwbench: REFUSED: \$1: state 'active'"; exit 1; }; echo "ex4-rwbench: preflight passed";;
*' arm') echo "TOKEN (type it yourself, on the box, after reading the plan; no script may write it):"; echo "  echo 'EX4-RW 11-l2off-test 0123456789ab' > /tmp/ex4-rw-ok";;
*' gate-check') n=\$(cat "$WORK/gates" 2>/dev/null || echo 0); echo \$((n + 1)) > "$WORK/gates"; [ "\$sc" != notoken ] && [ \$n -ge 1 ] && { echo "gate: the token matches"; exit 0; }; echo "gate: no /tmp/ex4-rw-ok yet"; exit 1;;
*' up '*) [ "\$sc" = up ] && { echo "ex4-rwbench: REFUSED: ext4: the journal needs recovery"; exit 1; }; echo "ex4-rwbench: up: md1 read-write";;
*' creds') echo "user=ex4bench"; echo "password=s3cr3tf0rtest";;
*' sample begin '*) [ "\$sc" = term ] && sleep 6; echo ok;;
*' sample end '*) echo "\${cmd##* sample end }: measured";;
*' profile --label '*) [ "\$sc" = noprof ] && { echo "ex4-rwbench: REFUSED: profile: no function_profile_enabled: this kernel has no function profiler"; exit 1; }; l=\${cmd##* profile --label }; echo "\${l%% *}: profile row";;
'ls /tmp/ex4-rwbench') printf 'journal.txt\nprofile-base.txt\nprofile-a1.txt\nprofile-x;y.txt\nprofile-../../etc.txt\nprofile-.txt\n'; [ "\$sc" = instr ] && printf 'xstat-nfs-w1.txt\nxstat-a;b.txt\n';;
'cat /tmp/ex4-rwbench/xstat-'*) echo "# xstat fetched \${cmd##*/}";;
*' ucanary '*) n=\${cmd#* ucanary }; n=\${n%% *}; h=\${cmd##* --md5 }; f="$WORK/run/mnt/\$n"; r=\$(md5sum < "\$f" 2>/dev/null | cut -d' ' -f1)
	[ "\$sc" = ucbad ] && r=fedcba9876543210fedcba9876543210
	for b in 4093 65521 131071 1048573; do [ "\$r" = "\$h" ] && echo "ucanary \$n read bs=\$b: md5 \$r OK (1 s)" || echo "ucanary \$n read bs=\$b: md5 \$r FAIL (1 s)"; done
	[ "\$r" = "\$h" ] || { echo "CANARY FAIL ucanary \$n: the known md5 is \$h; read bs=4093 gave \$r (dd rc 0); kernel 6.12.112"; echo "ex4-rwbench: REFUSED: CANARY FAIL ucanary \$n" >&2; exit 1; }
	echo "ucanary \$n copy bs=65521: md5 of the copy \$r OK (1 s; the copy removed)"; echo "ucanary \$n OK: md5 \$h on 4 odd-block reads (bs 4093 65521 131071 1048573) + 1 odd-block copy (bs 65521); \$(stat -c %s "\$f") bytes; kernel 6.12.112; 6 s on the box";;
*' md5 '*) n=\${cmd##* md5 }; f="$WORK/run/mnt/\$n"; h=\$(md5sum < "\$f" 2>/dev/null | cut -d' ' -f1); [ "\$sc" = canarybad ] && h=0123456789abcdef0123456789abcdef; echo "canary \$n md5 \$h bytes \$(stat -c %s "\$f" 2>/dev/null) (1 s on the box)";;
*' xsnap begin '*) echo ok;;
*' xsnap end '*) echo "xstat \${cmd##* xsnap end }: 1.0 s | ctxt +10 (10/s) | irq eth0 +5 | softnet processed +5 | nfsd pool none | vm none";;
*' facts') echo "# facts (fake)";;
'cat /tmp/ex4-rwbench/profile-'*) echo "# fetched \${cmd##*/}";;
*' stop') [ "\$sc" = unsafe ] && { echo "ex4-rwbench: clean stop: UNSAFE, NOT SAFE TO REBOOT"; exit 1; }; [ "\$sc" = look ] && { echo "ex4-rwbench: clean stop: SAFE TO REBOOT, BUT LOOK: /dev/loop72 state 'active' after the stop"; exit 3; }; echo "ex4-rwbench: clean stop: SAFE"; exit 0;;
'sync; reboot') echo REBOOT >> "$WORK/reboots";;
*) echo "fake: ok";;
esac
exit 0
EOF
printf '#!/bin/bash\necho "sudo $*" >> %s\ncase "$1" in mount|umount) exit 0;; esac\nexec "$@"\n' "$LOGF" > "$CB/sudo"
chmod 755 "$CB"/*
CL() {             # $1 = scenario, rest = client args
	echo "$1" > "$WORK/scenario"; shift; rm -f "$LOGF" "$WORK/gates" "$WORK/reboots"; rm -rf "$WORK/run"
	EX4RW_SSH="$CB/ssh" EX4RW_SUDO="$CB/sudo" EX4RW_CLIENT_IP=192.0.2.10 EX4RW_FAKE=1 PATH="$CB:$PATH" \
		timeout 120 bash "$TOP/host/ex4-rwbench-client.sh" --box 192.0.2.1 --key /nonexistent --out "$WORK/run" --runs 1 --mib 2 --token-wait 20 "$@" > "$WORK/client.out" 2>&1
}
called() { grep -c -- "$1" "$LOGF" 2>/dev/null || true; }
CL happy; rc=$?
check "client happy path: exit 0" '[ $rc = 0 ]'
check "client (v9 defaults): the order is preflight, arm, gate (until yes), up (window 25), local, samba4, ksmbd, stop, reboot: NO nfs, NO zap-zeros" '[ "$(grep -oE "(preflight|arm|gate-check|up 192.0.2.10 --stay --window-min [0-9]+|local|serve [a-z0-9]+ 192.0.2.10( --unauthenticated-nfs)?|zap-zeros|stop|reboot)$" "$LOGF" | uniq | tr "\n" " ")" = "preflight arm gate-check up 192.0.2.10 --stay --window-min 25 local serve samba4 192.0.2.10 serve ksmbd 192.0.2.10 stop reboot " ]'
check "client (v9 defaults): 1 write + 1 read sampled per engine, two engines (4 sample ends)" '[ "$(called " sample end ")" = 4 ]'
check "client (v9 defaults): no NFS server was asked for at all" '[ "$(called "serve nfs")" = 0 ]'
check "client: no command it sent writes the token file" '! grep -v "^sudo" "$LOGF" | grep -q "ex4-rw-ok"'
check "client: the share password never appears in a command line (ssh or sudo)" '! grep -q s3cr3tf0rtest "$LOGF"'
check "client: the credentials file is 0600" '[ "$(stat -c %a "$WORK/run/cred")" = 600 ]'
check "client: every copy went through mount and was unmounted (4 + 4)" '[ "$(called "^sudo mount ")" = 4 ] && [ "$(called "^sudo umount ")" = 4 ]'
check "client: one reboot, after the SAFE stop" '[ "$(cat "$WORK/reboots" 2>/dev/null)" = REBOOT ]'
check "client (v9.3 default = before v9.3): no tune, no --skip-copy, no labelled local" '[ "$(called " tune")" = 0 ] && [ "$(called "skip-copy")" = 0 ] && [ "$(called "local --label")" = 0 ]'
CL md5; rc=$?;      check "client: the box's ex4-rwbench is not this repo's -> refused, nothing armed" '[ $rc = 1 ] && [ "$(called " arm")" = 0 ] && grep -q "not this repo" "$WORK/client.out"'
CL notrial; rc=$?;  check "client: the address is not the trial -> refused" '[ $rc = 1 ] && [ "$(called md5sum)" = 0 ]'
CL preflight; rc=$?; check "client: preflight refused -> refused, nothing armed" '[ $rc = 1 ] && [ "$(called " arm")" = 0 ]'
CL notoken --token-wait 6; rc=$?; check "client: no token typed in time -> refused, no up, no stop needed, no reboot" '[ $rc = 1 ] && [ "$(called " up ")" = 0 ] && [ "$(called " stop")" = 0 ] && [ ! -e "$WORK/reboots" ]'
CL up; rc=$?;       check "client: up refused -> exit 1, the trap still ran the clean stop, then went home" '[ $rc = 1 ] && [ "$(called " stop")" = 1 ] && [ -e "$WORK/reboots" ]'
CL unsafe; rc=$?;   check "client: the stop says UNSAFE (3 tries) -> exit 2, NO reboot" '[ $rc = 2 ] && [ "$(called " stop")" = 3 ] && [ ! -e "$WORK/reboots" ]'
CL happy --nfs --zap-zeros; rc=$?; check "client --nfs --zap-zeros: nfs served WITH the box's explicit flag, window 40, zeros asked for, then stop, reboot" '[ $rc = 0 ] && [ "$(grep -oE "(up 192.0.2.10 --stay --window-min [0-9]+|serve nfs 192.0.2.10( --unauthenticated-nfs)?|zap-zeros|stop|reboot)$" "$LOGF" | uniq | tr "\n" " ")" = "up 192.0.2.10 --stay --window-min 40 serve nfs 192.0.2.10 --unauthenticated-nfs zap-zeros stop reboot " ] && [ "$(called "^sudo mount -t nfs -o vers=3,proto=tcp,soft")" = 2 ]'
CL look; rc=$?;     check "client: the stop says SAFE BUT LOOK (rc 3) -> exit 3, the reboot is HELD, and it says what to look at" '[ $rc = 3 ] && [ "$(called " stop")" = 1 ] && [ ! -e "$WORK/reboots" ] && grep -q "NOT rebooting" "$WORK/client.out" && grep -q "box-examine-after.txt" "$WORK/client.out"'
CL happy --no-return; rc=$?; check "client: --no-return -> SAFE stop, no reboot" '[ $rc = 0 ] && [ "$(called " stop")" = 1 ] && [ ! -e "$WORK/reboots" ]'
CL happy --dry-run; rc=$?; check "client: --dry-run -> preflight only (no arm, no up, no mount)" '[ $rc = 0 ] && [ "$(called " arm")" = 0 ] && [ "$(called "^sudo")" = 0 ]'
echo term > "$WORK/scenario"; rm -f "$LOGF" "$WORK/gates" "$WORK/reboots"; rm -rf "$WORK/run"
EX4RW_SSH="$CB/ssh" EX4RW_SUDO="$CB/sudo" EX4RW_CLIENT_IP=192.0.2.10 EX4RW_FAKE=1 PATH="$CB:$PATH" bash "$TOP/host/ex4-rwbench-client.sh" --box 192.0.2.1 --key /x --out "$WORK/run" --runs 1 --mib 2 --token-wait 20 > "$WORK/client.out" 2>&1 & CP=$!
sleep 9; kill -TERM $CP; wait $CP; rc=$?
check "client: SIGTERM mid-copy -> exit 130, the clean stop ran, then home" '[ $rc = 130 ] && [ "$(called " stop")" = 1 ] && [ -e "$WORK/reboots" ]'
# ---- v9.3: --skip-copy, --arms, --arm-engines, the window ----
CL happy --skip-copy 1 --arms "sc=256,ra=128,gt=0 sc=1024,ra=1024,gt=1" --arm-engines ksmbd; rc=$?
check "client --arms: exit 0; the order is up (--skip-copy 1, window 25), baseline local + samba4 + ksmbd, then per arm: tune, local --label aN, ksmbd; stop, reboot" '[ $rc = 0 ] && [ "$(grep -oE "(up 192.0.2.10 --stay --window-min [0-9]+( --skip-copy [01])?|local( --label a[0-9]+)?|tune .*|serve [a-z0-9]+ 192.0.2.10|stop|reboot)$" "$LOGF" | uniq | tr "\n" " ")" = "up 192.0.2.10 --stay --window-min 25 --skip-copy 1 local serve samba4 192.0.2.10 serve ksmbd 192.0.2.10 tune --stripe-cache 256 --readahead-kb 128 --group-threads 0 local --label a1 serve ksmbd 192.0.2.10 tune --stripe-cache 1024 --readahead-kb 1024 --group-threads 1 local --label a2 serve ksmbd 192.0.2.10 stop reboot " ]'
check "client --arms: arm copies are labelled a1-/a2- (8 sample ends: 4 baseline + 2 per arm), mounted and unmounted 8 + 8 times" '[ "$(called " sample end ")" = 8 ] && [ "$(called "sample end a1-ksmbd-w1 2 ")" = 1 ] && [ "$(called "sample end a2-ksmbd-r1 2 ")" = 1 ] && [ "$(called "^sudo mount ")" = 8 ] && [ "$(called "^sudo umount ")" = 8 ]'
check "client --arms: results-client.txt names each arm and its spec, and keeps the labelled local rows" 'grep -q "^== arm a1: sc=256,ra=128,gt=0 |" "$WORK/run/results-client.txt" && grep -q "^== arm a2: sc=1024,ra=1024,gt=1 |" "$WORK/run/results-client.txt" && [ -f "$WORK/run/local-a2.txt" ] && [ -f "$WORK/run/tune-a1.txt" ]'
CL happy --arms "sc=2048" --engines ""; rc=$?
check "client --arms with --engines \"\" and no --arm-engines: local + one arm (tune, local --label a1), no server at all" '[ $rc = 0 ] && [ "$(called "serve ")" = 0 ] && [ "$(called "tune --stripe-cache 2048")" = 1 ] && [ "$(called "local --label a1")" = 1 ] && [ "$(called " sample end ")" = 0 ]'
for spec in "sc=100" "sc=4097" "ra=127" "ra=8193" "gt=3" "sc=256,sc=512" "zz=1" "skip=1" "sc=256;ra=128" "sc=" "sc=256,"; do
	CL happy --arms "$spec"; rc=$?
	check "client --arms '$spec': refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "REFUSED: --arms" "$WORK/client.out"'
done
CL happy --arm-engines ksmbd; rc=$?;  check "client --arm-engines without --arms: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ]'
CL happy --arms sc=1024 --arm-engines smb1; rc=$?; check "client --arm-engines smb1: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ]'
CL happy --arms sc=1024 --arm-engines nfs; rc=$?; check "client --arm-engines nfs without --nfs: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ]'
CL happy --skip-copy 2; rc=$?;        check "client --skip-copy 2: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ]'
CL happy --arms; rc=$?;               check "client --arms with no value: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "needs a value" "$WORK/client.out"'
CL happy --runs 3 --mib 2048 --arms "sc=256 sc=1024" --arm-engines "samba4 ksmbd"; rc=$?
check "client: a plan over 45 min at 30 MiB/s (2 arms x both engines at 3 x 2 GiB) -> REFUSED before any ssh, saying how to split it" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && [ ! -e "$WORK/run" ] && grep -q "at most 45 min" "$WORK/client.out" && grep -qiE "split it|not even one arm" "$WORK/client.out"'
CL happy --runs 3 --mib 2048 --arms "sc=256 sc=512 sc=768 sc=1024 sc=2048 sc=4096 sc=300"; rc=$?
check "client: 7 local-only arms after the default baseline (~47 min) -> REFUSED: 6 fit per session, 2 sessions, the first 6 named" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "6 arm(s) fit per session" "$WORK/client.out" && grep -q "2 sessions" "$WORK/client.out" && grep -q "sc=256 sc=512 sc=768 sc=1024 sc=2048 sc=4096. now" "$WORK/client.out"'
CL happy --dry-run --runs 3 --mib 2048 --arms "sc=256 sc=1024"; rc=$?
check "client: the window grows to what the plan needs at 30 MiB/s (default baseline ~24 min + 2 local arms -> 31 min), never below 25" '[ $rc = 0 ] && grep -q "window 31 min (the plan needs ~31 min" "$WORK/client.out"'
CL happy --dry-run --runs 3 --mib 2048; rc=$?
check "client: the default plan at full size still asks the box for 25 min (needs ~24)" '[ $rc = 0 ] && grep -q "window 25 min (the plan needs ~24 min" "$WORK/client.out"'
# ---- v9.4: --nfs-block, --arm-nfs, --profile, --profile-arms, --profile-mib ----
CL happy --nfs --nfs-block 1024; rc=$?
check "client --nfs --nfs-block 1024: serve nfs carries --max-block-kb 1024 after the explicit flag, both NFS mounts rsize=wsize=1048576 (still soft,timeo=600,retrans=4), window 40" '[ $rc = 0 ] && [ "$(called "serve nfs 192.0.2.10 --unauthenticated-nfs --max-block-kb 1024\$")" = 1 ] && [ "$(called "^sudo mount -t nfs -o vers=3,proto=tcp,soft,timeo=600,retrans=4,rsize=1048576,wsize=1048576 ")" = 2 ] && [ "$(called "up 192.0.2.10 --stay --window-min 40\$")" = 1 ]'
check "client --nfs (no --nfs-block, the default): no --max-block-kb, mounts without rsize/wsize" 'CL happy --nfs; [ "$(called "max-block-kb")" = 0 ] && [ "$(called "rsize=")" = 0 ] && [ "$(called "^sudo mount -t nfs -o vers=3,proto=tcp,soft,timeo=600,retrans=4 ")" = 2 ]'
CL happy --nfs-block 1024; rc=$?; check "client --nfs-block without --nfs: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "needs --nfs" "$WORK/client.out"'
for v in 1000 32 2048 x ""; do CL happy --nfs --nfs-block "$v"; rc=$?; check "client --nfs-block '$v': refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ]'; done
CL happy --nfs --nfs-block 256 --engines "" --arms sc=1024 --arm-nfs; rc=$?
check "client --arm-nfs: the order is up (window 40), local, serve nfs (baseline), tune, local --label a1, serve nfs (arm), stop, reboot; both serves carry --max-block-kb 256" '[ $rc = 0 ] && [ "$(grep -oE "(up 192.0.2.10 --stay --window-min [0-9]+|local( --label a[0-9]+)?|tune .*|serve [a-z0-9]+ 192.0.2.10.*|stop|reboot)$" "$LOGF" | uniq | tr "\n" " ")" = "up 192.0.2.10 --stay --window-min 40 local serve nfs 192.0.2.10 --unauthenticated-nfs --max-block-kb 256 tune --stripe-cache 1024 local --label a1 serve nfs 192.0.2.10 --unauthenticated-nfs --max-block-kb 256 stop reboot " ]'
check "client --arm-nfs: the arm's NFS runs are named a1-nfs-w1 / a1-nfs-r1; 4 NFS mounts with rsize=wsize=262144" '[ "$(called "sample end a1-nfs-w1 2 ")" = 1 ] && [ "$(called "sample end a1-nfs-r1 2 ")" = 1 ] && [ "$(called "rsize=262144,wsize=262144 ")" = 4 ]'
CL happy --nfs --arms sc=1024 --arm-nfs --arm-engines nfs --engines ""; rc=$?; check "client --arm-nfs + --arm-engines nfs: NFS once per arm (2 serves: baseline + a1)" '[ $rc = 0 ] && [ "$(called "serve nfs")" = 2 ]'
CL happy --arms sc=1024 --arm-nfs; rc=$?; check "client --arm-nfs without --nfs: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "arm-nfs needs --nfs" "$WORK/client.out"'
CL happy --nfs --arm-nfs; rc=$?; check "client --arm-nfs without --arms: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ]'
CL happy --profile --arms sc=1024 --profile-arms --engines ""; rc=$?
check "client --profile --profile-arms: the order is up, local, profile base, tune, local --label a1, profile a1, stop, reboot" '[ $rc = 0 ] && [ "$(grep -oE "(up 192.0.2.10 --stay --window-min [0-9]+|local( --label a[0-9]+)?|profile --label [a-z0-9]+ --mib [0-9]+|tune .*|stop|reboot)$" "$LOGF" | uniq | tr "\n" " ")" = "up 192.0.2.10 --stay --window-min 25 local profile --label base --mib 2048 tune --stripe-cache 1024 local --label a1 profile --label a1 --mib 2048 stop reboot " ]'
check "client --profile: the profile rows land in results-client.txt; box-profile-base.txt + box-profile-a1.txt fetched; odd names (x;y, ../, empty label) never asked for" 'grep -q "^base: profile row" "$WORK/run/results-client.txt" && grep -q "^a1: profile row" "$WORK/run/results-client.txt" && grep -q "fetched profile-base.txt" "$WORK/run/box-profile-base.txt" && grep -q "fetched profile-a1.txt" "$WORK/run/box-profile-a1.txt" && [ "$(ls "$WORK/run" | grep -c "^box-profile")" = 2 ] && ! grep -qE "profile-(x|\.\.|\.txt)" "$LOGF"'
CL happy --profile --profile-mib 64; rc=$?; check "client --profile-mib 64: the box is asked for a 64 MiB profile write" '[ $rc = 0 ] && [ "$(called "profile --label base --mib 64\$")" = 1 ]'
CL noprof --profile; rc=$?; check "client --profile on a kernel without the profiler: the box refuses -> exit 1, the trap ran the clean stop (SAFE), home" '[ $rc = 1 ] && [ "$(called " stop")" = 1 ] && [ -e "$WORK/reboots" ] && grep -q "profile base refused" "$WORK/client.out"'
CL happy --profile-arms; rc=$?; check "client --profile-arms without --arms: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ]'
for v in 0 2049 x; do CL happy --profile --profile-mib "$v"; rc=$?; check "client --profile-mib '$v': refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ]'; done
CL happy; check "client (v9.4 default = before v9.4): no profile, no max-block-kb, no ls of the box folder for profiles beyond the receipt fetch" '[ "$(called " profile ")" = 0 ] && [ "$(called "max-block-kb")" = 0 ]'
CL happy --dry-run --runs 3 --mib 2048 --profile; rc=$?
check "client window: --profile adds 2048/10 + 60 s to the default baseline (~24 min -> 28 min)" '[ $rc = 0 ] && grep -q "window 28 min (the plan needs ~28 min" "$WORK/client.out"'
CL happy --runs 3 --mib 2048 --arms "sc=256 sc=512 sc=768 sc=1024 sc=2048 sc=4096" --profile-arms; rc=$?
check "client window: 6 local arms each with a profile (~7.7 min each) after the default baseline -> REFUSED: 2 fit per session, 3 sessions" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "2 arm(s) fit per session" "$WORK/client.out" && grep -q "3 sessions" "$WORK/client.out"'
CL happy --dry-run --runs 3 --mib 2048 --nfs --nfs-block 1024 --arms sc=1024 --arm-nfs; rc=$?
check "client window: the NFS baseline + one arm with NFS at 3 x 2 GiB needs ~45 min: allowed, window 45" '[ $rc = 0 ] && grep -q "window 45 min (the plan needs ~45 min" "$WORK/client.out"'
CL happy --runs 3 --mib 2048 --nfs --arms "sc=1024 sc=2048" --arm-nfs; rc=$?
check "client window: two NFS arms after the NFS baseline -> REFUSED before any ssh (1 arm fits per session)" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "1 arm(s) fit per session" "$WORK/client.out"'
# ---- v9.7: NFSv4.2, nfsd threads, client read-ahead, rsize / wsize, NFS arm keys, the canary, the instruments ----
BDR=$WORK/bdi; mkdir -p "$BDR/0:99"; echo 128 > "$BDR/0:99/read_ahead_kb"
CL7() { EX4RW_BDI_ROOT="$BDR" EX4RW_FAKE_BDI=0:99 CL "$@"; }
CL7 happy --nfs --engines "" --nfs-vers 4.2 --nfs-threads 4; rc=$?
check "client --nfs-vers 4.2 --nfs-threads 4: exit 0; serve nfs = v9.4's flag + --vers 4.2 --threads 4; both mounts vers=4.2 of BOX:/ (still soft,timeo=600,retrans=4)" '[ $rc = 0 ] && [ "$(called "serve nfs 192.0.2.10 --unauthenticated-nfs --vers 4.2 --threads 4\$")" = 1 ] && [ "$(called "^sudo mount -t nfs -o vers=4.2,proto=tcp,soft,timeo=600,retrans=4 192.0.2.1:/ ")" = 2 ]'
check "client --nfs-vers 4.2: the canary is ON by itself: the box md5s the write once (md5 nfs-w1.bin), a canary OK row, the pattern removed at the end, its seed + md5 in client.log" '[ "$(called " md5 nfs-w1.bin\$")" = 1 ] && grep -q "^canary OK nfs-w1 / nfs-r1: written, on the box and read back all md5 [0-9a-f]\{32\}\$" "$WORK/run/results-client.txt" && ! ls "$WORK/run"/canary-*.bin > /dev/null 2>&1 && grep -q "canary: seed [0-9]*, 2 MiB, md5 [0-9a-f]\{32\}" "$WORK/run/client.log"'
check "client --nfs-vers 4.2: the canary pattern is non-zero and seeded (the md5 the box saw = the client's, not the md5 of 2 MiB of zeros)" 'h=$(grep -o "canary nfs-w1.bin md5 [0-9a-f]*" "$WORK/run/results-client.txt" | cut -d" " -f4); [ -n "$h" ] && [ "$h" != "$(head -c 2097152 /dev/zero | md5sum | cut -d" " -f1)" ] && grep -q "md5 $h" "$WORK/run/client.log"'
check "client --nfs-vers 4.2: the untimed warm-up file is gone from the bench folder" '[ ! -e "$WORK/run/mnt/.ex4-warm.tmp" ]'
CL7 canarybad --nfs --engines "" --nfs-vers 4.2; rc=$?
check "client canary: the box reports another md5 -> exit 1, a loud CANARY FAIL row, the clean stop ran (SAFE), no read copy after it" '[ $rc = 1 ] && grep -q "^CANARY FAIL nfs-w1: .*the box read 0123456789abcdef0123456789abcdef" "$WORK/run/results-client.txt" && grep -q "CANARY FAIL" "$WORK/client.out" && [ "$(called " stop")" = 1 ] && [ "$(called "sample begin nfs-r1")" = 0 ]'
CL7 happy --nfs --engines "" --nfs-vers 4.2 --no-canary; rc=$?
check "client --no-canary: no md5, no pattern, no canary row" '[ $rc = 0 ] && [ "$(called " md5 ")" = 0 ] && ! grep -q "canary" "$WORK/run/results-client.txt"'
CL7 happy --nfs --engines "" --canary; rc=$?
check "client --canary on a plain --nfs: the serve and the mounts stay v9.4s byte for byte, the md5 is asked for" '[ $rc = 0 ] && [ "$(called "serve nfs 192.0.2.10 --unauthenticated-nfs\$")" = 1 ] && [ "$(called "^sudo mount -t nfs -o vers=3,proto=tcp,soft,timeo=600,retrans=4 192.0.2.1:/mnt/md1/Public/ex4-bench-v8 ")" = 2 ] && [ "$(called " md5 nfs-w1.bin\$")" = 1 ]'
CL7 happy --canary; rc=$?; check "client --canary without --nfs: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "canary needs --nfs" "$WORK/client.out"'
CL7 happy --nfs --engines "" --nfs-block 512 --nfs-rsize 256 --nfs-wsize 1024; rc=$?
check "client --nfs-rsize 256 --nfs-wsize 1024 (--nfs-block 512): mounts rsize=262144,wsize=1048576; the box still gets --max-block-kb 512" '[ $rc = 0 ] && [ "$(called "^sudo mount -t nfs -o vers=3,proto=tcp,soft,timeo=600,retrans=4,rsize=262144,wsize=1048576 ")" = 2 ] && [ "$(called "serve nfs 192.0.2.10 --unauthenticated-nfs --max-block-kb 512\$")" = 1 ]'
CL7 happy --nfs --engines "" --nfs-rsize 128; rc=$?
check "client --nfs-rsize alone: rsize only (wsize stays the kernel's)" '[ $rc = 0 ] && [ "$(called "retrans=4,rsize=131072 ")" = 2 ] && [ "$(called "wsize=")" = 0 ]'
echo 128 > "$BDR/0:99/read_ahead_kb"; CL7 happy --nfs --engines "" --nfs-ra-kb 8192; rc=$?
check "client --nfs-ra-kb 8192: written after every NFS mount (2 x 8192), given back before every unmount (2 x 128), read back; the bdi reads 128 at the end" '[ $rc = 0 ] && [ "$(grep -c "client read_ahead_kb $BDR/0:99/read_ahead_kb: 128 -> 8192 (read back)" "$WORK/run/client.log")" = 2 ] && [ "$(grep -c "read_ahead_kb: back to 128 (read back)" "$WORK/run/client.log")" = 2 ] && [ "$(cat "$BDR/0:99/read_ahead_kb")" = 128 ] && [ "$(called "^sudo tee $BDR/0:99/read_ahead_kb")" = 4 ]'
for bad in "--nfs-vers 4.1" "--nfs-vers 4" "--nfs-threads 0" "--nfs-threads 17" "--nfs-threads x" "--nfs-ra-kb 64" "--nfs-ra-kb 20000" "--nfs-rsize 48" "--nfs-wsize 2048"; do
	CL7 happy --nfs $bad; rc=$?; check "client $bad: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ]'
done
for f in "--nfs-vers 4.2" "--nfs-threads 4" "--nfs-ra-kb 1024" "--nfs-rsize 64" "--nfs-wsize 64"; do
	CL7 happy $f; rc=$?; check "client $f without --nfs: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "need --nfs" "$WORK/client.out"'
done
echo 128 > "$BDR/0:99/read_ahead_kb"; CL7 happy --nfs --engines "" --no-local --arms "nv=4.2,nt=4 sc=1024,rs=256,cra=4096" --arm-nfs; rc=$?
check "client NFS arm keys: exit 0; order = serve nfs (baseline, v9.4 args), a1 NO tune + serve nfs --vers 4.2 --threads 4, a2 tune --stripe-cache 1024 + serve nfs (v9.4 args), stop" '[ $rc = 0 ] && [ "$(grep -oE "(tune .*|serve nfs 192.0.2.10.*|stop)$" "$LOGF" | uniq | tr "\n" "|")" = "serve nfs 192.0.2.10 --unauthenticated-nfs|serve nfs 192.0.2.10 --unauthenticated-nfs --vers 4.2 --threads 4|tune --stripe-cache 1024|serve nfs 192.0.2.10 --unauthenticated-nfs|stop|" ]'
check "client NFS arm keys: a1 mounts vers=4.2 of BOX:/ (2), a2 mounts v3 with rsize=262144 and no wsize (2) and sets this machine's read-ahead 4096 (given back: 128)" '[ "$(called "^sudo mount -t nfs -o vers=4.2,proto=tcp,soft,timeo=600,retrans=4 192.0.2.1:/ ")" = 2 ] && [ "$(called "^sudo mount -t nfs -o vers=3,proto=tcp,soft,timeo=600,retrans=4,rsize=262144 ")" = 2 ] && [ "$(grep -c "128 -> 4096 (read back)" "$WORK/run/client.log")" = 2 ] && [ "$(cat "$BDR/0:99/read_ahead_kb")" = 128 ]'
check "client NFS arm keys: results-client.txt names a1 as NFS keys only (no box knob), a2 with its tune line; the canary ran on all three NFS pairs" 'grep -q "^== arm a1: nv=4.2,nt=4 | no box knob (NFS keys only: nv=4.2 nt=4 " "$WORK/run/results-client.txt" && grep -q "^== arm a2: sc=1024,rs=256,cra=4096 | " "$WORK/run/results-client.txt" && [ "$(grep -c "^canary OK" "$WORK/run/results-client.txt")" = 3 ]'
for spec in "nv=4.1" "nt=0" "nt=17" "cra=64" "rs=48" "ws=2048" "nv=4.2,nv=3" "sc=1.5"; do
	CL7 happy --nfs --arms "$spec" --arm-nfs; rc=$?; check "client --arms '$spec' (with --arm-nfs): refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "REFUSED: --arms" "$WORK/client.out"'
done
CL7 happy --nfs --arms "nv=4.2"; rc=$?; check "client NFS arm key without --arm-nfs: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "need --arm-nfs" "$WORK/client.out"'
CL7 instr --nfs --engines "" --instruments; rc=$?
check "client --instruments: facts once right after up (box-facts.txt), xsnap begin + end around each of the 2 copies (outside sample begin/end), the xstat lines in results-client.txt" '[ $rc = 0 ] && [ "$(called " facts\$")" = 1 ] && [ "$(grep -oE "(up 192.0.2.10.*|facts|local)$" "$LOGF" | tr "\n" "|")" = "up 192.0.2.10 --stay --window-min 40|facts|local|" ] && [ "$(called " xsnap begin ")" = 2 ] && [ "$(called " xsnap end ")" = 2 ] && grep -q "^# facts (fake)" "$WORK/run/box-facts.txt" && [ "$(grep -c "^xstat nfs-" "$WORK/run/results-client.txt")" = 2 ] && [ "$(grep -oE "(xsnap begin nfs-w1|sample begin nfs-w1|sample end nfs-w1.*|xsnap end nfs-w1)$" "$LOGF" | cut -d" " -f1,2 | tr "\n" "|")" = "xsnap begin|sample begin|sample end|xsnap end|" ]'
check "client --instruments: box-xstat-nfs-w1.txt fetched, an odd name never asked for; mountstats before/after files per copy" '[ -f "$WORK/run/box-xstat-nfs-w1.txt" ] && ! grep -q "xstat-a;b" "$LOGF" && [ -f "$WORK/run/mountstats-nfs-w1.a.txt" ] && [ -f "$WORK/run/mountstats-nfs-r1.b.txt" ]'
CL happy --nfs; check "client --nfs with NO v9.7 flag: no md5, no xsnap, no facts, no --vers/--threads: the v9.4 plan" '[ "$(called " md5 ")" = 0 ] && [ "$(called "xsnap")" = 0 ] && [ "$(called " facts")" = 0 ] && [ "$(called "vers 4.2\|--threads")" = 0 ] && [ "$(called "serve nfs 192.0.2.10 --unauthenticated-nfs\$")" = 1 ]'
CL happy --dry-run --runs 3 --mib 2048 --nfs; rc=$?; N0=$(grep -o "the plan needs ~[0-9]* min" "$WORK/client.out" | grep -o "[0-9]*")
CL happy --dry-run --runs 3 --mib 2048 --nfs --canary; N1=$(grep -o "the plan needs ~[0-9]* min" "$WORK/client.out" | grep -o "[0-9]*")
CL happy --dry-run --runs 3 --mib 2048 --nfs --nfs-vers 4.2 --instruments; N2=$(grep -o "the plan needs ~[0-9]* min" "$WORK/client.out" | grep -o "[0-9]*")
check "client window: the canary adds the box's md5 read (3 x 2 GiB at 30 MiB/s = +204 s: $N0 -> $N1 min); 4.2 (its canary on by itself) + instruments add the md5 read, the grace, 15 s per copy + facts ($N2 min)" '[ "$N0" = 33 ] && [ "$N1" = 36 ] && [ "$N2" = 42 ]'
CL happy --runs 3 --mib 2048 --nfs --nfs-vers 4.2 --arms sc=1024 --arm-nfs; rc=$?
check "client window: the run-15 shape (NFS baseline + one NFS arm at 3 x 2 GiB) with the v4.2 canary no longer fits 45 min -> REFUSED before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "at most 45 min" "$WORK/client.out"'
# ---- v9.8: --ucanary (the user-copy canary: once per session, after the first canary'd NFS write's box md5) ----
CL7 happy --nfs --engines "" --ucanary --runs 2; rc=$?
check "client --ucanary: exit 0; the canary on by itself; the box's ucanary asked ONCE, for nfs-w1.bin with the pattern's md5" '[ $rc = 0 ] && [ "$(called " ucanary ")" = 1 ] && h=$(grep -o "canary: seed [0-9]*, 2 MiB, md5 [0-9a-f]*" "$WORK/run/client.log" | awk "{ print \$NF }") && [ -n "$h" ] && [ "$(called " ucanary nfs-w1.bin --md5 $h\$")" = 1 ]'
check "client --ucanary: order = md5 nfs-w1.bin, ucanary nfs-w1.bin, dropcache, sample begin nfs-r1 (untimed, after the client unmounted, before the read copy); w2 gets no ucanary" '[ "$(grep -oE "( md5 nfs-w1.bin| ucanary nfs-w1.bin| dropcache| sample begin nfs-r1|^sudo umount)" "$LOGF" | sed -n "2,5p" | tr "\n" "|")" = " md5 nfs-w1.bin| ucanary nfs-w1.bin| dropcache| sample begin nfs-r1|" ] && [ "$(called " ucanary nfs-w2")" = 0 ]'
check "client --ucanary: its rows (4 reads, the copy, the OK line) in results-client.txt, both canary OK rows too" '[ "$(grep -c "^ucanary nfs-w1.bin read bs=" "$WORK/run/results-client.txt")" = 4 ] && grep -q "^ucanary nfs-w1.bin copy bs=65521: " "$WORK/run/results-client.txt" && grep -q "^ucanary nfs-w1.bin OK: md5 " "$WORK/run/results-client.txt" && [ "$(grep -c "^canary OK" "$WORK/run/results-client.txt")" = 2 ]'
CL7 happy --nfs --engines "" --no-local --ucanary --arms "nv=4.2 cra=4096" --arm-nfs; rc=$?
check "client --ucanary with two NFS arms: still ONCE per session (one kernel), on the baseline's nfs-w1" '[ $rc = 0 ] && [ "$(called " ucanary ")" = 1 ] && [ "$(called " ucanary nfs-w1.bin ")" = 1 ] && [ "$(grep -c "^canary OK" "$WORK/run/results-client.txt")" = 3 ]'
CL7 ucbad --nfs --engines "" --ucanary; rc=$?
check "client --ucanary, the box's user-copy canary FAILS: exit 1, a loud CANARY FAIL row naming ucanary, the clean stop ran (SAFE), no read copy after it" '[ $rc = 1 ] && grep -q "^CANARY FAIL ucanary-nfs-w1: .*the box.s user-copy canary" "$WORK/run/results-client.txt" && grep -q "^CANARY FAIL ucanary nfs-w1.bin" "$WORK/run/results-client.txt" && grep -q "CANARY FAIL" "$WORK/client.out" && [ "$(called " stop")" = 1 ] && [ "$(called "sample begin nfs-r1")" = 0 ]'
CL7 happy --ucanary; rc=$?; check "client --ucanary without --nfs: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "ucanary needs --nfs" "$WORK/client.out"'
CL7 happy --nfs --ucanary --no-canary; rc=$?; check "client --ucanary --no-canary: refused before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "ucanary needs the canary" "$WORK/client.out"'
CL happy --nfs --canary; check "client without --ucanary: no ucanary asked for (the v9.7 plan)" '[ "$(called "ucanary")" = 0 ]'
CL happy --dry-run --runs 3 --mib 2048 --nfs --canary; NU0=$(grep -o "the plan needs ~[0-9]* min" "$WORK/client.out" | grep -o "[0-9]*")
CL happy --dry-run --runs 3 --mib 2048 --nfs --ucanary; NU1=$(grep -o "the plan needs ~[0-9]* min" "$WORK/client.out" | grep -o "[0-9]*")
check "client window: --ucanary adds 7 x 2048 MiB at 30 MiB/s + 30 s (507 s) once: $NU0 -> $NU1 min" '[ "$NU0" = 36 ] && [ "$NU1" = 45 ]'
CL happy --runs 3 --mib 2048 --engines "" --nfs --skip-copy 1 --nfs-block 1024 --nfs-vers 3 --nfs-ra-kb 4096 --instruments --arms sc=1024,ra=1024,gt=0 --arm-nfs --ucanary; rc=$?
check "client window: the run-17 shape (local + NFS baseline + one NFS arm, 3 x 2 GiB, canary, instruments) + --ucanary no longer fits 45 min -> REFUSED before any ssh" '[ $rc = 1 ] && [ ! -s "$LOGF" ] && grep -q "at most 45 min" "$WORK/client.out"'
mkdir -p "$WORK/exists"; CL happy; EX4RW_FAKE=1 bash "$TOP/host/ex4-rwbench-client.sh" --box 192.0.2.1 --key /x --out "$WORK/exists" > "$WORK/c2.out" 2>&1; check "client: --out exists -> refused" '[ $? = 1 ] && grep -q "exists" "$WORK/c2.out"'
EX4RW_FAKE=1 bash "$TOP/host/ex4-rwbench-client.sh" --box 192.0.2.1 --key /x --out "$WORK/new1" --engines smb1 > "$WORK/c3.out" 2>&1; check "client: an unknown engine -> refused" '[ $? = 1 ]'
EX4RW_FAKE=1 bash "$TOP/host/ex4-rwbench-client.sh" --box ex4.local --key /x --out "$WORK/new2" > "$WORK/c4.out" 2>&1; check "client: a name instead of an address -> refused" '[ $? = 1 ]'
echo "== stub-test ($ASH + busybox applets): $P passed, $F failed"; [ $F = 0 ]
