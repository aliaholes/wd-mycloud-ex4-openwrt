#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# mk-e2e-dtb.sh : the TEST device tree of tests/qemu-e2e.sh. Takes the versatile-pb.dtb the test kernel build made and changes
# two things: the root compatible gains "wd,mycloud-ex4" in front (the kernel still matches "arm,versatile-pb"; OpenWrt's
# userspace takes the first string as the board name, so the overlay's EX4 paths run), and the 64 MiB CFI flash gets the
# EX4's seven partition names, every one read-only, in WD's ORDER: as on the box, the tree lists "rescue firmware"
# (15 MiB, here at 0x01500000), "config", then "reserve", and "reserve" sits BELOW "rescue firmware" (here at
# 0x01000000). So mtd4 is not the partition with the fourth-lowest address, as on the box. The board's RTC nodes are
# disabled (the EX4 has no RTC device under this kernel).
#   sh mk-e2e-dtb.sh <versatile-pb.dtb> <out.dtb>          Off the box. Never overwrites.   Born Nov 17 2026 (EX4 run 7 prep).
set -eu
IN=$1; OUT=$2
[ -e "$OUT" ] && { echo "REFUSED: $OUT exists" >&2; exit 1; }
T=$(mktemp -d)
dtc -q -I dtb -O dts -o "$T/in.dts" "$IN"
python3 -I - "$T/in.dts" "$T/out.dts" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = 'compatible = "arm,versatile-pb";'
assert s.count(a) == 1, "root compatible"
s = s.replace(a, 'compatible = "wd,mycloud-ex4", "arm,versatile-pb";')
b = '''		partitions {
			compatible = "arm,arm-firmware-suite";
		};'''
assert s.count(b) == 1, "flash partitions node"
parts = [("u-boot", 0x0, 0x100000), ("uImage", 0x100000, 0x500000), ("ramdisk", 0x600000, 0x500000), ("image", 0xb00000, 0x500000),
         ("rescue firmware", 0x1500000, 0xf00000), ("config", 0x2400000, 0x1400000), ("reserve", 0x1000000, 0x500000)]
n = '''		partitions {
			compatible = "fixed-partitions";
			#address-cells = <0x01>;
			#size-cells = <0x01>;
''' + ''.join('''
			partition@%x {
				label = "%s";
				reg = <0x%x 0x%x>;
				read-only;
			};
''' % (o, l, o, z) for l, o, z in parts) + '''		};'''
s = s.replace(b, n)
# the EX4 has no working RTC device under this kernel (rtc-mv: "internal RTC not ticking"): take the versatile board's away
# too, so the guest's clock starts unset as on the box and OpenWrt's sysfixtime finds no /dev/rtc0 to restore from
import re
k = 0
for m in list(re.finditer(r'\n(\t+)rtc@[0-9a-f]+ \{\n', s))[::-1]:
    s = s[:m.end()] + m.group(1) + '\tstatus = "disabled";\n' + s[m.end():]; k += 1
assert k >= 1, "no rtc node in the versatile tree"
open(sys.argv[2], 'w').write(s)
PY
dtc -q -I dts -O dtb -o "$OUT" "$T/out.dts"
rm -rf "$T"
echo "wrote $OUT: board name wd,mycloud-ex4 (first compatible), flash with 7 read-only partitions, RTC nodes disabled"
