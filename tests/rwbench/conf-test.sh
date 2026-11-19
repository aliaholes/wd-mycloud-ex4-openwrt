#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# conf-test.sh : the two SMB server configs box/ex4-rwbench.sh writes (print-conf: rendered exactly as `serve` writes
# them), checked by the IMAGE's own tools under qemu-arm: Samba 4's testparm must load the smb.conf with no unknown or
# invalid parameter and show the walls (one client address, no guest, no anonymous, SMB2+); every ksmbd parameter we
# use must be one ksmbd.tools knows. Also: ksmbd.adduser of the image takes the password on stdin (never argv).
#   bash tests/rwbench/conf-test.sh --work DIR --rootfs ROOTFS          (ROOTFS = the image's root folder)
set -u
WORK=; RFS=
while [ $# -gt 0 ]; do case "$1" in --work) WORK=$2;; --rootfs) RFS=$2;; *) sed -n '7p' "$0" >&2; exit 64;; esac; shift 2; done
[ -n "$WORK" ] && [ ! -e "$WORK" ] && [ -x "$RFS/usr/bin/testparm" ] || { echo "REFUSED: --work NEW --rootfs ROOTFS (with usr/bin/testparm)" >&2; exit 1; }
command -v qemu-arm > /dev/null || { echo "REFUSED: no qemu-arm" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd)
mkdir -p "$WORK/tmp" "$WORK/root"; WORK=$(cd "$WORK" && pwd)
P=0; F=0
ok() { P=$((P + 1)); echo "PASS  $*"; }
bad() { F=$((F + 1)); echo "FAIL  $*"; }
check() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }
PC() { env -i PATH=/usr/bin:/bin EX4RW_TEST=1 EX4RW_MD=/dev/md97 EX4RW_TMP="$WORK/tmp" EX4RW_ROOT="$WORK/root" EX4RW_MNT=/mnt/md1 sh "$TOP/box/ex4-rwbench.sh" print-conf "$@"; }
PC samba4 192.0.2.10 > "$WORK/smb.conf"; check "print-conf samba4 renders" '[ $? = 0 ] && [ -s "$WORK/smb.conf" ]'
PC ksmbd 192.0.2.10 > "$WORK/ksmbd.conf"; check "print-conf ksmbd renders" '[ $? = 0 ] && [ -s "$WORK/ksmbd.conf" ]'
PC samba4 127.0.0.1 > /dev/null 2>&1; check "print-conf refuses a loopback client" '[ $? != 0 ]'
check "neither config holds a password" '! grep -qi "password" "$WORK/smb.conf" "$WORK/ksmbd.conf"'
for d in private lock state cache pid log; do mkdir -p "$WORK/tmp/ex4-rwbench/samba/$d"; done      # start_samba makes these before smbd
qemu-arm -L "$RFS" "$RFS/usr/bin/testparm" -s "$WORK/smb.conf" > "$WORK/testparm.out" 2> "$WORK/testparm.err"; rc=$?
qemu-arm -L "$RFS" "$RFS/usr/bin/testparm" -s -v "$WORK/smb.conf" > "$WORK/testparm-v.out" 2> /dev/null
check "Samba 4.22 testparm (the image's own, ARM) loads the smb.conf" '[ $rc = 0 ] && grep -q "Loaded services file OK" "$WORK/testparm.err"'
check "testparm: no unknown, invalid or deprecated parameter, no error" '! grep -qiE "unknown parameter|invalid|ignoring|deprecated|ERROR" "$WORK/testparm.err"'
T=$WORK/testparm.out
check "testparm: hosts allow = the one client" 'grep -qx "	hosts allow = 192.0.2.10" "$T"'
check "testparm: everyone else denied" 'grep -qx "	hosts deny = 0.0.0.0/0" "$T"'
check "testparm: bound to the LAN interface only" 'grep -qx "	interfaces = br-lan" "$T" && grep -qx "	bind interfaces only = Yes" "$T"'
check "testparm: no guest mapping (map to guest = Never is the default, so testparm omits it; Bad User is NOT set)" '! grep -qi "map to guest = Bad" "$T"'
check "testparm: restrict anonymous = 2" 'grep -qx "	restrict anonymous = 2" "$T"'
check "testparm -v: SMB2_10 and up only (4.22 prints it as SMB2), map to guest Never, guest ok No everywhere" 'grep -qxE "	server min protocol = SMB2(_10)?" "$WORK/testparm-v.out" && grep -qx "	map to guest = Never" "$WORK/testparm-v.out" && grep -qx "	guest ok = No" "$WORK/testparm-v.out" && ! grep -qx "	guest ok = Yes" "$WORK/testparm-v.out"'
check "testparm: root may not log in" 'grep -qx "	invalid users = root" "$T"'
check "testparm: the share: one user, writable, no guest, not browseable" 'awk "/^\[ex4bench\]/,0" "$T" | grep -qx "	valid users = ex4bench" && awk "/^\[ex4bench\]/,0" "$T" | grep -qx "	read only = No" && ! awk "/^\[ex4bench\]/,0" "$T" | grep -q "guest ok = Yes" && awk "/^\[ex4bench\]/,0" "$T" | grep -qx "	browseable = No"'
check "testparm: the share path is the bench folder only" 'grep -qx "	path = /mnt/md1/Public/ex4-bench-v8" "$T"'
# run 13 (Nov 17 2026): START the image's smbd on the rendered smb.conf. testparm alone passed while the box's first real
# smbd died on mkdir /var/run/samba/ncalrpc. Overridden for a non-root run under qemu only: interface lo, port 44599,
# client 127.0.0.1. Everything else (every directory, the passdb, the share) is exactly what serve writes.
SD=$WORK/tmp/ex4-rwbench/samba; mkdir -p "$SD/ncalrpc"; chmod 700 "$SD/private"
check "smb.conf: ncalrpc dir is inside the bench's own state dir (never smbd's default under /var/run/samba)" 'grep -qx "	ncalrpc dir = $SD/ncalrpc" "$WORK/smb.conf"'
check "smb.conf: no directory parameter points outside the bench's state dir" '! grep -E "^	(private|lock|state|cache|pid|ncalrpc) dir(ectory)? = " "$WORK/smb.conf" | grep -v " = $SD/"'
SP=44599; VRS0=$(ls -A /var/run/samba 2>/dev/null)
timeout 45 qemu-arm -L "$RFS" "$RFS/usr/sbin/smbd" -F -s "$WORK/smb.conf" --option="interfaces=lo" --option="smb ports=$SP" --option="hosts allow=127.0.0.1" --option="log level=2" > "$WORK/smbd-run.out" 2>&1 &
SMBQ=$!; up=0; i=0
while [ $i -lt 40 ]; do sleep 1; i=$((i + 1)); [ -s "$SD/pid/smbd.pid" ] && ss -ltn 2>/dev/null | grep -q "127.0.0.1:$SP " && { up=1; break; }; kill -0 $SMBQ 2>/dev/null || break; done
check "the image's smbd (ARM, qemu) STARTS on the rendered smb.conf: pid file written, listening (after ${i} s)" '[ $up = 1 ]'
[ $up = 1 ] || { echo "      smbd said:"; grep -v "^ *$" "$WORK/smbd-run.out" | tail -6 | sed "s/^/      /"; }
check "smbd made nothing under /var/run/samba (all of its state is in the bench dir)" '[ "$VRS0" = "$(ls -A /var/run/samba 2>/dev/null)" ]'
kill $SMBQ 2>/dev/null; pkill -P $SMBQ 2>/dev/null; wait $SMBQ 2>/dev/null
B=$RFS/usr/libexec/ksmbd.tools
miss=; for k in $(sed -n 's/^\t\([a-z0-9 ]*[a-z0-9]\) = .*/\1/p' "$WORK/ksmbd.conf" | tr ' ' '_'); do grep -aq -- "$(echo "$k" | tr '_' ' ')" "$B" || miss="$miss $k"; done
check "ksmbd: every parameter in our ksmbd.conf is a string ksmbd.tools (3.5.6) knows" '[ -z "$miss" ]'
[ -n "$miss" ] && echo "      unknown to ksmbd.tools:$miss"
mkdir -p "$WORK/k"; ln -s "$B" "$WORK/k/ksmbd.adduser"
printf 'pw-on-stdin-42\npw-on-stdin-42\n' | qemu-arm -L "$RFS" "$WORK/k/ksmbd.adduser" -P "$WORK/k/pwd.db" -C "$WORK/ksmbd.conf" -a ex4bench > "$WORK/k/out" 2>&1
check "ksmbd.adduser (the image's, ARM) takes the password on stdin and writes the user" '[ $? = 0 ] && grep -q "^ex4bench:" "$WORK/k/pwd.db" && ! grep -q "pw-on-stdin-42" "$WORK/k/pwd.db"'
echo "== conf-test: $P passed, $F failed"; [ $F = 0 ]
