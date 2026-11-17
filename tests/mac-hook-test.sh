#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# mac-hook-test.sh : the v5 MAC hook (lib/preinit/07_ex4_set_mac, taken out of the bundle's own overlay.cpio) run case by
# case under busybox ash, off the box, with OpenWrt 25.12.6's OWN /lib/functions.sh + /lib/functions/system.sh (so the
# real mtd_get_mac_text, macaddr_canonicalize and macaddr_setbit_la run). Faked: the flash partition (a file), the two
# ports' sysfs address files, `ip` (writes the new address into the fake sysfs file and logs the call), board_name.
#   sh mac-hook-test.sh <overlay.cpio> <openwrt rootfs dir> <workdir> [<kernel.bin>]      Never overwrites <workdir>.
# What it proves: the hook's decisions. What it does not: the real flash read (tests/qemu-e2e.sh does that on a CFI
# flash through the kernel's mtdblock) or the EX4's NAND.          Born Nov 17 2026 (EX4 run 7 prep).
# v6, optional: with <kernel.bin> and EX4_STOCK_MTD_DIR=<a folder with YOUR OWN dumps mtd0.dd .. mtd6.dd, taken under
# the stock firmware> two more cases run on real bytes (tests/flash-slice.py): the hook on the "rescue firmware"
# partition exactly as the device tree in kernel.bin cuts it out of the chip, and on the range bundle-v5's tree gave
# that name (run 7: "nothing readable in flash"). Run 7 is the reason these exist: every case above fakes the
# partition with a file that STARTS at the identity block, so a tree that points the name at the wrong place passed.
set -u
OVL=$1; ROOT=$2; W=$3; KB=${4:-}; HERE=$(cd "$(dirname "$0")" && pwd)
[ -e "$W" ] && { echo "REFUSED: $W exists"; exit 1; }
mkdir -p "$W"; W=$(cd "$W" && pwd); ROOT=$(cd "$ROOT" && pwd)
python3 -I - "$OVL" "$W/hook.orig" <<'PY' || exit 1
import sys
d = open(sys.argv[1], 'rb').read(); p = 0
while True:
    assert d[p:p + 6] == b'070701'
    f = [int(d[p + 6 + 8 * i:p + 14 + 8 * i], 16) for i in range(13)]
    ns, fs = f[11], f[6]; name = d[p + 110:p + 110 + ns - 1].decode(); p = (p + 110 + ns + 3) & ~3
    body = d[p:p + fs]; p = (p + fs + 3) & ~3
    if name == 'TRAILER!!!': sys.exit("no lib/preinit/07_ex4_set_mac in the overlay")
    if name == 'lib/preinit/07_ex4_set_mac': open(sys.argv[2], 'wb').write(body); break
PY
# OpenWrt's two function files, unchanged but for the absolute paths of the files they source themselves
mkdir -p "$W/fn"
for f in lib/functions.sh lib/functions/system.sh; do
	sed -e "s#\. /lib/functions\.sh#. $W/fn/functions.sh#" -e "s#\. /lib/functions/system\.sh#. $W/fn/system.sh#" -e "s#\. /usr/share/libubox/jshn\.sh#. $ROOT/usr/share/libubox/jshn.sh#" "$ROOT/$f" > "$W/fn/$(basename $f)"
done
# the hook as shipped, with its absolute paths pointed into the work dir (nothing else changes)
sed -e "s#^\. /lib/functions\.sh#. $W/fn/functions.sh#" -e "s#^\. /lib/functions/system\.sh#. $W/fn/system.sh#" \
    -e "s#/sys/class/net/#\$FAKE/sys/class/net/#g" -e "s#o=/tmp/ex4-mac.txt#o=\$FAKE/ex4-mac.txt#" -e "s#/usr/sbin/ex4log#\$FAKE/ex4log#g" "$W/hook.orig" > "$W/hook.sh"
[ "$(grep -c '\$FAKE' "$W/hook.sh")" -ge 5 ] || { echo "REFUSED: the hook does not have the lines this harness rewrites"; exit 1; }
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS  $*"; }
no() { FAIL=$((FAIL+1)); echo "FAIL  $*"; }
ident() {       # $1 = file, $2 = byte offset, $3 = first address text, $4 = second
	python3 -I -c 'import sys
p, off, m1, m2 = sys.argv[1], int(sys.argv[2]), sys.argv[3].encode(), sys.argv[4].encode()
d = bytearray(open(p, "rb").read()); b = bytearray(64)
b[0:len(m1)] = m1; b[0x1c:0x1c + len(m2)] = m2; b[0x32:0x34] = b"\x55\xaa"; d[off:off + 64] = b
open(p, "wb").write(d)' "$@"
}
blank() { python3 -I -c 'import sys; open(sys.argv[1], "wb").write(b"\xff" * (15 << 20))' "$1"; }
run() {         # $1 = case name, $2 = board, $3 = eth0 address, $4 = eth1 address, $5 = flash file or "" (no such partition)
	F="$W/$1"; mkdir -p "$F/sys/class/net/eth0" "$F/sys/class/net/eth1"
	printf '%s\n' "$3" > "$F/sys/class/net/eth0/address"; printf '%s\n' "$4" > "$F/sys/class/net/eth1/address"
	printf '#!/bin/sh\necho "$*" >> "%s/notes"\n' "$F" > "$F/ex4log"; chmod 755 "$F/ex4log"
	cat > "$F/drive.sh" <<EOF
FAKE='$F'; FLASH='$5'; BOARD='$2'
boot_hook_add() { echo "hook \$1 \$2" >> "\$FAKE/hooks"; }
. '$W/hook.sh'
board_name() { echo "\$BOARD"; }
find_mtd_part() { [ "\$1" = "rescue firmware" ] && [ -n "\$FLASH" ] && echo "\$FLASH"; }
mtd_get_part_size() { echo 15728640; }
ip() { echo "ip \$*" >> "\$FAKE/ipcalls"; [ "\$1 \$2 \$3 \$5" = "link set dev address" ] && echo "\$6" > "\$FAKE/sys/class/net/\$4/address"; return 0; }
ex4_set_mac; echo "rc=\$?" > "\$FAKE/rc"
EOF
	busybox ash "$F/drive.sh" > "$F/out" 2>&1
	E0=$(cat "$F/sys/class/net/eth0/address"); E1=$(cat "$F/sys/class/net/eth1/address"); SRC=$(sed -n 's/^source=//p' "$F/ex4-mac.txt" 2>/dev/null); LAN=$(sed -n 's/^lan_mac=//p' "$F/ex4-mac.txt" 2>/dev/null)
}
want() {        # $1 = what, $2 = eth0, $3 = eth1, $4 = text the source line must hold, $5 = lan_mac
	if [ "$E0" = "$2" ] && [ "$E1" = "$3" ] && [ "$LAN" = "$5" ] && [ "$(cat "$F/rc")" = "rc=0" ] && case "$SRC" in *"$4"*) true;; *) false;; esac; then ok "$1 -> eth0 $E0, eth1 $E1, lan_mac ${LAN:-none} [$SRC]"
	else no "$1: eth0 $E0 (want $2), eth1 $E1 (want $3), lan_mac '$LAN' (want '$5'), source '$SRC' (want '$4'), $(cat "$F/rc"), out: $(head -3 "$F/out" | tr '\n' ' ')"; fi
}
BOND=00:90:a9:00:00:50
blank "$W/f1"; ident "$W/f1" 0 00:90:A9:00:00:50 00:90:A9:00:00:51
run real wd,mycloud-ex4 $BOND $BOND "$W/f1"
want "the unit's own block (text at byte 0 and byte 0x1c of the partition), both ports carrying WD's bond address" 00:90:a9:00:00:50 00:90:a9:00:00:51 "flash (rescue firmware, block 0)" 00:90:a9:00:00:50
grep -q "^hook preinit_main ex4_set_mac$" "$W/real/hooks" && ok "the hook registers itself at preinit_main (where the image's own 07_set_iface_mac runs)" || no "hook registration: $(cat "$W/real/hooks" 2>/dev/null)"
[ "$(cat "$W/real/ipcalls")" = "ip link set dev eth0 address 00:90:a9:00:00:50
ip link set dev eth1 address 00:90:a9:00:00:51" ] && ok "exactly two commands: ip link set dev eth0 address <first>, ip link set dev eth1 address <second> (WD's mac_read order: first -> port 1, second -> port 2)" || no "ip calls: $(cat "$W/real/ipcalls")"
grep -q "^note MACs: eth0 00:90:a9:00:00:50, eth1 00:90:a9:00:00:51 (flash (rescue firmware, block 0))$" "$W/real/notes" && ok "a note for the black box names both addresses and where they came from" || no "note: $(cat "$W/real/notes" 2>/dev/null)"
grep -q "^eth1 was=$BOND now=00:90:a9:00:00:51 want=00:90:a9:00:00:51$" "$W/real/ex4-mac.txt" && ok "/tmp/ex4-mac.txt records was / now / want per port" || no "ex4-mac.txt: $(cat "$W/real/ex4-mac.txt")"
blank "$W/f2"; ident "$W/f2" 262144 00:90:A9:01:02:03 00:90:A9:01:02:04
run block2 wd,mycloud-ex4 $BOND $BOND "$W/f2"
want "block 0 and 1 erased (a bad first block: WD writes the identity to the first GOOD one), identity in block 2" 00:90:a9:01:02:03 00:90:a9:01:02:04 "block 2" 00:90:a9:01:02:03
blank "$W/f3"
run erased wd,mycloud-ex4 $BOND $BOND "$W/f3"
want "nothing in flash (8 blocks erased), both ports the same" $BOND 02:90:a9:00:00:50 "derived (nothing readable in flash): eth0 keeps its address, eth1 = the same with the locally-administered bit" $BOND
run nopart wd,mycloud-ex4 $BOND $BOND ""
want "no 'rescue firmware' partition at all" $BOND 02:90:a9:00:00:50 "derived" $BOND
run differ wd,mycloud-ex4 00:90:a9:00:00:50 00:90:a9:00:00:51 "$W/f3"
want "nothing in flash, the ports already differ" 00:90:a9:00:00:50 00:90:a9:00:00:51 "left as found" 00:90:a9:00:00:50
blank "$W/f4"; ident "$W/f4" 0 00:11:4A:00:00:01 00:11:4A:00:00:02
run placeholder wd,mycloud-ex4 $BOND $BOND "$W/f4"
want "WD's placeholder pair in flash (00:11:4A:00:00:01 / :02, what mac_read falls back to): not used" $BOND 02:90:a9:00:00:50 "derived" $BOND
blank "$W/f5"; ident "$W/f5" 0 00:90:A9:00:00:50 00:90:A9:00:00:50
run same wd,mycloud-ex4 $BOND $BOND "$W/f5"
want "the same address twice in flash: not used" $BOND 02:90:a9:00:00:50 "derived" $BOND
blank "$W/f6"; ident "$W/f6" 0 01:90:A9:00:00:50 00:90:A9:00:00:51
run multicast wd,mycloud-ex4 $BOND $BOND "$W/f6"
want "a multicast first address in flash: not used" $BOND 02:90:a9:00:00:50 "derived" $BOND
blank "$W/f7"; ident "$W/f7" 0 "GARBAGE-NOT-A-MAC" 00:90:A9:00:00:51
run garbage wd,mycloud-ex4 $BOND $BOND "$W/f7"
want "text that is not an address at byte 0: not used" $BOND 02:90:a9:00:00:50 "derived" $BOND
run noaddr wd,mycloud-ex4 00:00:00:00:00:00 00:00:00:00:00:00 "$W/f3"
if [ "$E0" = 00:00:00:00:00:00 ] && [ "$E1" = 00:00:00:00:00:00 ] && [ ! -e "$W/noaddr/ipcalls" ] && grep -q "^source=none: nothing readable in flash and no usable address on a port; left alone" "$W/noaddr/ex4-mac.txt"; then ok "nothing in flash and no usable address on either port: nothing is set, the file says so"; else no "noaddr: $E0 $E1 $(cat "$W/noaddr/ex4-mac.txt" 2>/dev/null)"; fi
run otherboard iom,ix4-200d $BOND $BOND "$W/f1"
if [ "$E0" = "$BOND" ] && [ "$E1" = "$BOND" ] && [ ! -e "$W/otherboard/ipcalls" ] && [ ! -e "$W/otherboard/ex4-mac.txt" ] && [ "$(cat "$W/otherboard/rc")" = "rc=0" ]; then ok "another board name: the hook does nothing at all"; else no "otherboard: $E0 $E1"; fi
# the reader is OpenWrt's own, and it opens the partition's block device for reading only
grep -q 'mtd_get_mac_text "rescue firmware" \$off' "$W/hook.orig" && grep -q 'dd bs=1 if="\$part" skip="\$offset" count="\$length"' "$ROOT/lib/functions/system.sh" && ok "the flash read is OpenWrt's own mtd_get_mac_text (dd if=<the partition's block device>, 17 bytes): nothing in the hook can write flash" || no "reader"
! sed 's#2>/dev/null##g; s#>/dev/null##g' "$W/hook.orig" | grep -qE 'dd .*of=|mtd write|flash_erase|nandwrite|> */dev/' && ok "static: the hook holds no write to a device (no dd of=, no mtd write, no redirect into /dev)" || no "static: a device write in the hook"
if [ -n "$KB" ] && [ -n "${EX4_STOCK_MTD_DIR:-}" ]; then
	# the unit's two addresses, read here from the stock dump of mtd4 (never written into this repo)
	RM=$(python3 -I -c 'import sys; d = open(sys.argv[1] + "/mtd4.dd", "rb").read(64); a = d[0:17].decode().lower(); b = d[0x1c:0x1c + 17].decode().lower(); la = "%02x" % (int(a[:2], 16) | 2) + a[2:]; print(a, b, la)' "$EX4_STOCK_MTD_DIR")
	set -- $RM; RM1=$1; RM2=$2; RLA=$3
	python3 -I "$HERE/flash-slice.py" "$KB" "$EX4_STOCK_MTD_DIR" "rescue firmware" "$W/slice-tree" > "$W/slice-tree.log" 2>&1; SRC1=$?
	[ $SRC1 = 0 ] && ok "real bytes: the tree in kernel.bin cuts 'rescue firmware' out of the chip exactly where the stock dump of that name sits [$(cut -c1-200 "$W/slice-tree.log")]" || no "real bytes: $(cat "$W/slice-tree.log")"
	run realflash wd,mycloud-ex4 $RM1 $RM1 "$W/slice-tree"
	want "real bytes: the hook on that partition, both ports carrying the first address as after WD's bond" $RM1 $RM2 "flash (rescue firmware, block 0)" $RM1
	python3 -I "$HERE/flash-slice.py" --v5-layout "$EX4_STOCK_MTD_DIR" "rescue firmware" "$W/slice-v5" > "$W/slice-v5.log" 2>&1; SRC5=$?
	[ $SRC5 = 3 ] && grep -q "it starts with a UBI erase-block header" "$W/slice-v5.log" && ok "real bytes: bundle-v5's layout hands the same name 5 MiB too low, the start of WD's UBI 'reserve' partition [$(cut -c1-200 "$W/slice-v5.log")]" || no "real bytes, v5 layout: rc $SRC5 $(cat "$W/slice-v5.log")"
	run v5flash wd,mycloud-ex4 $RM1 $RM1 "$W/slice-v5"
	want "real bytes: the hook on bundle-v5's range = what run 7 logged" $RM1 $RLA "derived (nothing readable in flash): eth0 keeps its address, eth1 = the same with the locally-administered bit" $RM1
else echo "-- skipped: the two real-bytes cases (need <kernel.bin> as the 4th argument and EX4_STOCK_MTD_DIR)"; fi
echo "mac-hook-test: $PASS passed, $FAIL failed   (workdir $W)"
[ $FAIL = 0 ]
