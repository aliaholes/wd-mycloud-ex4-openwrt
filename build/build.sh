#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# build.sh : build the EX4 RAM-trial bundle from source + the four upstream files of fetch.sh. Pure file work on your
# computer; it touches no device and no network.
#
#   sh build/build.sh --pubkey <your ssh PUBLIC key file> [--dl DIR] [--work DIR] [--out DIR]
#
#   --pubkey  REQUIRED. The trial system has no root password; this key is the only way in. Make one for this
#             purpose (ssh-keygen -t ed25519 -f ~/.ssh/ex4-trial) and give the .pub here. Never a private key.
#   --dl      where fetch.sh put the downloads            (default ./dl)
#   --work    scratch folder, about 600 MB, must not exist (default ./work)
#   --out     the bundle is written to <out>/bundle       (default ./out; <out>/bundle must not exist)
#
# In the environment (all optional):
#   LOG_SECTORS=2098831   the exact size, in 512-byte sectors, of the UNUSED partition 3 the trial writes its 2 MiB
#                         black-box log into (see SAFETY.md, "The one disk write"). 2098831 is what WD's firmware
#                         made on the test unit's four 4 TB disks. `ex4-trial.sh check` on the box refuses if your
#                         partition 3 has another size; only then, and only after you have made sure that partition
#                         holds nothing, rebuild with your number (the 1 KiB block count in /proc/partitions, times 2,
#                         plus 1 if `fdisk -l`/`sgdisk -p` shows an odd sector count).
#   LOG_SKIP_PORT=N LOG_SKIP_PART=sdX3
#                         keep one bay out of it altogether (N = its SATA port 1..4, sdX3 = that disk's partition 3
#                         as STOCK names it). Give both or neither. For a disk with bad sectors.
#   RETURN_MIN=20         minutes until the trial reboots itself back to stock unless /tmp/ex4-stay exists
#   STAMP=YYYYMMDD-HHMM   part of the run id (default: now)
#   RUNNO=1               the number the run id starts with (run id = <RUNNO>-l2off-<STAMP>); only a label
#   CROSS=arm-linux-gnueabi-    the cross toolchain prefix
#   JOBS=N                parallel make jobs (default: nproc)
#
# Needs: sh, python3 (3.8+), make, perl, tar, xz, gzip, sha256sum, md5sum, cpp, dtc (device-tree-compiler), a host C
# compiler, and an ARM cross gcc + binutils with a glibc for static linking (Debian/Ubuntu: gcc-arm-linux-gnueabi
# libc6-dev-armel-cross). Built and tested with gcc 13.3 / dtc 1.7.0 on Ubuntu 24.04 (arm64 host).
#
# What it builds, in order:
#   1. WD's own 3.2.40 kernel tree (from WD's GPL bundle for firmware 2.12.127), prepared for an out-of-tree module
#      build with WD's own .config. One file is added for a modern compiler (include/linux/compiler-gcc<N>.h, a copy
#      of the tree's compiler-gcc4.h). Nothing of that tree ends up in the bundle except through the module.
#   2. ex4boot-l2off.ko (loader/), against that tree.
#   3. ex4-trial.dtb (dts/, with -DEX4_TRIAL: all seven NAND partitions read-only), against Linux 6.12.112's dtsi.
#      The compiled tree is checked: WD's own partition table, and a PHY id no driver in that kernel source claims.
#   4. kernel.bin = OpenWrt 25.12.6's kirkwood zImage (out of the official iom_ix4-200d initramfs image) + that DTB.
#   5. ex4fan, ex4log, ex4peek, ex4phy (userland/), static, linked for the stock kernel's 32 KiB pages.
#   6. the three xhci modules, taken out of the official zyxel_nsa325 initramfs image of the same release, and checked
#      against kernel.bin (vermagic, every undefined symbol).
#   7. overlay.cpio (mkoverlay.py), the ATAG list, the RAM markers, and the bundle's text files + MD5SUMS.
# Then it checks its own output: the appended DTB's partitions are all read-only and WD's own, the ATAG list parses,
# the layout has no overlap. Copy <out>/bundle to the EX4's data volume and go on with README.md, "Run it".
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/.." && pwd)
PUB=; DL=dl; WORK=work; OUT=out
while [ $# -gt 0 ]; do
	case "$1" in
	--pubkey) PUB=${2:?}; shift 2;;
	--dl) DL=${2:?}; shift 2;;
	--work) WORK=${2:?}; shift 2;;
	--out) OUT=${2:?}; shift 2;;
	*) echo "usage: sh build/build.sh --pubkey KEY.pub [--dl DIR] [--work DIR] [--out DIR]" >&2; exit 64;;
	esac
done
die() { echo "build: REFUSED: $*" >&2; exit 1; }
say() { echo "build: $*"; }
[ -n "$PUB" ] || die "--pubkey is required: without a key the trial system would accept root with no password from the LAN"
[ -s "$PUB" ] || die "$PUB not found"
grep -q 'PRIVATE KEY' "$PUB" && die "$PUB is a PRIVATE key. Give the .pub file."
[ "$(grep -c . "$PUB")" = 1 ] || die "$PUB must hold exactly one public key line"
CROSS=${CROSS:-arm-linux-gnueabi-}; JOBS=${JOBS:-$(nproc 2>/dev/null || echo 2)}
LOG_SECTORS=${LOG_SECTORS:-2098831}; LOG_SKIP_PORT=${LOG_SKIP_PORT:-}; LOG_SKIP_PART=${LOG_SKIP_PART:-}
RETURN_MIN=${RETURN_MIN:-20}; STAMP=${STAMP:-$(date +%Y%m%d-%H%M)}; RUNNO=${RUNNO:-1}
case "$RUNNO" in ''|*[!0-9]*) die "RUNNO must be a number";; esac
case "$LOG_SECTORS" in ''|*[!0-9]*) die "LOG_SECTORS must be a number";; esac
case "$RETURN_MIN" in ''|*[!0-9]*) die "RETURN_MIN must be a number";; esac
[ -z "$LOG_SKIP_PORT$LOG_SKIP_PART" ] || { [ -n "$LOG_SKIP_PORT" ] && [ -n "$LOG_SKIP_PART" ]; } || die "LOG_SKIP_PORT and LOG_SKIP_PART go together"
case "$LOG_SKIP_PART" in ''|sd[a-d]3) ;; *) die "LOG_SKIP_PART must look like sdd3";; esac
for t in python3 make perl tar xz gzip sha256sum md5sum cpp dtc cc "${CROSS}gcc" "${CROSS}strip"; do
	command -v "$t" >/dev/null || die "$t not found (see the Needs line in this script's header)"
done
[ -e "$WORK" ] && die "$WORK exists (give another --work, or remove it yourself)"
[ -e "$OUT/bundle" ] && die "$OUT/bundle exists (never overwrite)"
mkdir -p "$WORK" "$OUT"; WORK=$(cd "$WORK" && pwd); OUT=$(cd "$OUT" && pwd); DL=$(cd "$DL" && pwd); PUB=$(cd "$(dirname "$PUB")" && pwd)/$(basename "$PUB")
py() { python3 -I "$@"; }

# ---- 0. the downloads: present, and exactly the files this was built and tested with ----
grep -v '^#' "$HERE/SOURCES.sha256" | while read -r sum name url; do
	[ -n "$sum" ] || continue
	[ -s "$DL/$name" ] || { echo "build: REFUSED: $DL/$name is missing (run: sh build/fetch.sh $DL)" >&2; exit 1; }
	got=$(sha256sum < "$DL/$name" | cut -d' ' -f1)
	[ "$got" = "$sum" ] || { echo "build: REFUSED: $DL/$name has sha256 $got, want $sum" >&2; exit 1; }
	echo "build: source ok: $name"
done
IX4="$DL/openwrt-25.12.6-kirkwood-generic-iom_ix4-200d-initramfs-uImage"
NSA="$DL/openwrt-25.12.6-kirkwood-generic-zyxel_nsa325-initramfs-uImage"
NSA_SHA=$(awk '$2 ~ /zyxel_nsa325/ {print $1}' "$HERE/SOURCES.sha256")
KVER=6.12.112

# ---- 1. WD's 3.2.40 tree, prepared ----
say "1/7 WD's kernel tree (unpacking 1.1 GB; a few minutes)"
mkdir "$WORK/wd"
tar -xzf "$DL/WDMyCloud_EX4_GPL_v2.12.127_20181219.tar.gz" -C "$WORK/wd" WDMyCloud_EX4_GPL_v2.12.127_20181219/kernel/linux-3.2.40.tar.gz
tar -xzf "$WORK/wd/WDMyCloud_EX4_GPL_v2.12.127_20181219/kernel/linux-3.2.40.tar.gz" -C "$WORK/wd"
rm -rf "$WORK/wd/WDMyCloud_EX4_GPL_v2.12.127_20181219"
TREE="$WORK/wd/linux-3.2.40"
[ -s "$TREE/.config" ] || die "WD's tree has no .config (not the 2.12.127 bundle?)"
grep -q '^CONFIG_MV_32KB_SW_PAGE_SIZE_SUPPORT=y' "$TREE/.config" || die "WD's .config is not the EX4's (no 32 KiB software pages)"
GCCMAJ=$("${CROSS}gcc" -dumpversion | cut -d. -f1)
[ -e "$TREE/include/linux/compiler-gcc$GCCMAJ.h" ] || cp "$TREE/include/linux/compiler-gcc4.h" "$TREE/include/linux/compiler-gcc$GCCMAJ.h"
KMAKE="make -C $TREE ARCH=arm CROSS_COMPILE=$CROSS KCFLAGS=-DALPHA_CUSTOMIZE"
$KMAKE -j"$JOBS" modules_prepare > "$WORK/wd-prepare.log" 2>&1 || { tail -20 "$WORK/wd-prepare.log" >&2; die "modules_prepare failed in WD's tree (log: $WORK/wd-prepare.log)"; }

# ---- 2. the loader module ----
say "2/7 ex4boot-l2off.ko"
mkdir "$WORK/mod"; cp "$TOP/loader/ex4boot_main.c" "$TOP/loader/ex4boot_stub.S" "$TOP/loader/Makefile" "$WORK/mod/"
$KMAKE M="$WORK/mod" EX4_L2OFF=1 modules > "$WORK/mod-build.log" 2>&1 || { tail -20 "$WORK/mod-build.log" >&2; die "the module build failed (log: $WORK/mod-build.log)"; }
[ -s "$WORK/mod/ex4boot.ko" ] || die "no ex4boot.ko came out"
py -c 'import sys; d=open(sys.argv[1],"rb").read(); sys.exit(0 if b"vermagic=3.2.40 mod_unload ARMv5 p2v8 " in d else 1)' "$WORK/mod/ex4boot.ko" || die "the module's vermagic is not '3.2.40 mod_unload ARMv5 p2v8' (what the stock kernel's own modules carry)"

# ---- 3. the device tree ----
say "3/7 ex4-trial.dtb"
mkdir "$WORK/dts"
tar -xJf "$DL/linux-$KVER.tar.xz" -C "$WORK/dts" --wildcards "linux-$KVER/arch/arm/boot/dts/marvell/kirkwood*.dtsi" "linux-$KVER/include/dt-bindings" "linux-$KVER/include/uapi/linux/input-event-codes.h" "linux-$KVER/kernel/irq" \
	"linux-$KVER/drivers/net/phy" "linux-$KVER/drivers/net/ethernet/marvell/mv643xx_eth.c" "linux-$KVER/include/linux"
L="$WORK/dts/linux-$KVER"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -DEX4_TRIAL -I "$L/arch/arm/boot/dts/marvell" -I "$L/include" "$TOP/dts/kirkwood-wd-mycloud-ex4.dts" > "$WORK/dts/ex4-trial.pp.dts"
dtc -q -I dts -O dtb -o "$WORK/dts/ex4-trial.dtb" "$WORK/dts/ex4-trial.pp.dts" 2> "$WORK/dts/dtc.log" || { cat "$WORK/dts/dtc.log" >&2; die "dtc failed"; }

# ---- 4. kernel.bin ----
say "4/7 kernel.bin (OpenWrt $KVER zImage + ex4-trial.dtb)"
B="$OUT/bundle"; mkdir "$B"
py "$HERE/ex4img.py" split "$IX4" "$WORK/ix4" > "$WORK/split.log"
py "$HERE/ex4img.py" join "$WORK/ix4/zImage" "$WORK/dts/ex4-trial.dtb" "$B/kernel.bin" >> "$WORK/split.log"
py "$TOP/tests/dtb_check.py" "$B/kernel.bin" --v6 > "$WORK/dtb-check.log" 2>&1 || { cat "$WORK/dtb-check.log" >&2; die "the DTB appended to kernel.bin failed its check (every NAND partition read-only, WD's own partition table, the PHY nodes)"; }
py "$HERE/kimg_extract.py" "$B/kernel.bin" "$WORK/Image" > "$WORK/kimg.log" 2>&1 || { cat "$WORK/kimg.log" >&2; die "could not unpack the kernel image out of kernel.bin"; }
py "$TOP/tests/phy-id-check.py" "$L" "$B/kernel.bin" "$WORK/Image" > "$WORK/phy-id-check.log" 2>&1 || { cat "$WORK/phy-id-check.log" >&2; die "a PHY driver in Linux $KVER claims the id the device tree gives the two PHYs (or the source no longer reads as the fix expects)"; }

# ---- 5. the three static ARM programs ----
say "5/7 ex4fan, ex4log, ex4peek, ex4phy"
for p in ex4fan ex4log ex4peek; do
	"${CROSS}gcc" -static -Os -march=armv5te -Wall -Wl,-z,max-page-size=0x8000 -o "$B/$p" "$TOP/userland/$p.c" 2> "$WORK/$p.build.log" || { cat "$WORK/$p.build.log" >&2; die "$p did not build"; }
	chmod 755 "$B/$p"
done
"${CROSS}strip" "$B/ex4log" "$B/ex4peek"        # as in the bundles that ran on the test unit (ex4fan went in unstripped)
# ex4phy lives only inside the overlay (the trial's self-test runs it); it must not be able to write a PHY register
grep -q 'SIOCSMIIREG\|SIOCETHTOOL\|SIOCSIF' "$TOP/userland/ex4phy.c" && die "userland/ex4phy.c names an ioctl that changes something: it must stay read-only"
"${CROSS}gcc" -static -Os -march=armv5te -Wall -Wl,-z,max-page-size=0x8000 -o "$WORK/ex4phy" "$TOP/userland/ex4phy.c" 2> "$WORK/ex4phy.build.log" || { cat "$WORK/ex4phy.build.log" >&2; die "ex4phy did not build"; }
"${CROSS}strip" "$WORK/ex4phy"

# (the kernel's kernel/irq/ source rides along from step 3: two symbols xhci-pci imports, free_irq and
#  request_threaded_irq, sit in the kernel image only as the tail of a longer export's name; the check then wants to
#  see their EXPORT_SYMBOL line in the source of the same version)
# ---- 6. OpenWrt's own files: two config files of the image we boot, three modules of its sibling ----
say "6/7 xhci modules out of the official zyxel_nsa325 image, checked against kernel.bin"
py "$HERE/initramfs_extract.py" "$IX4" "$WORK/ix4-rootfs" > "$WORK/ix4-rootfs.log"
py "$HERE/kmod_pick.py" pick "$NSA" "$NSA_SHA" "$WORK/kmods" lib/modules/$KVER/xhci-hcd.ko lib/modules/$KVER/xhci-pci.ko lib/modules/$KVER/xhci-plat-hcd.ko etc/modules.d/54-usb-xhci-hcd etc/modules.d/54-usb3 > "$WORK/kmods.log"
py "$HERE/kmod_pick.py" check "$B/kernel.bin" "$WORK/kmods" --ref "$WORK/ix4-rootfs/lib/modules/$KVER/sata_mv.ko" --shipped "$WORK/ix4-rootfs/lib/modules/$KVER" --source "$L" > "$WORK/kmods.check.log" 2>&1 || { tail -20 "$WORK/kmods.check.log" >&2; die "the picked modules do not fit kernel.bin"; }
cp "$WORK/kmods/KMODS.txt" "$B/KMODS.txt"

# ---- 7. overlay, ATAGs, markers, the text files ----
say "7/7 overlay.cpio and the bundle's bookkeeping"
set -- --network-file "$WORK/ix4-rootfs/etc/board.d/02_network" --pubkey "$PUB" --return-min "$RETURN_MIN" \
	--ex4log "$B/ex4log" --log-min-sectors "$LOG_SECTORS" --log-max-sectors "$LOG_SECTORS" --tag ex4-openwrt \
	--preinit-conf "$WORK/ix4-rootfs/lib/preinit/00_preinit.conf" --ex4fan "$B/ex4fan" --ex4mac --kmods "$WORK/kmods" --ex4phy "$WORK/ex4phy" --out "$B/overlay.cpio"
[ -z "$LOG_SKIP_PORT" ] || set -- "$@" --log-skip-port "$LOG_SKIP_PORT"
py "$HERE/mkoverlay.py" "$@"
cp "$WORK/mod/ex4boot.ko" "$B/ex4boot-l2off.ko"
cp "$TOP/box/ex4-trial.sh" "$B/ex4-trial.sh"
KERNEL_ADDR=0x8000; ATAGS_ADDR=0x100; INITRD_ADDR=0x4000000; MARK_A=0x1000; MARK_C=0x3000; MARK_H=0x3000000
RUN="$RUNNO-l2off-$STAMP"
printf '%s\n' "$RUN" > "$B/RUNID"
SZ=$(stat -c %s "$B/overlay.cpio")
py "$HERE/ex4img.py" atags "$B/atags.bin" --mem 512 --initrd "$INITRD_ADDR,$SZ" --cmdline "console=ttyS0,115200n8 watchdog.open_timeout=120 ex4boot_run=$RUN" > "$WORK/atags.log"
py "$HERE/ex4img.py" atags-parse "$B/atags.bin" --expect-token "ex4boot_run=$RUN" --expect-initrd "$INITRD_ADDR,$SZ" --max-end "$MARK_A" >> "$WORK/atags.log" || die "the ATAG list did not parse back"
py "$HERE/ex4img.py" marker "$B/markA.bin" --run "$RUN" --pos 0 --total 3 --dest $MARK_A >> "$WORK/atags.log"
py "$HERE/ex4img.py" marker "$B/markC.bin" --run "$RUN" --pos 1 --total 3 --dest $MARK_C >> "$WORK/atags.log"
py "$HERE/ex4img.py" marker "$B/markH.bin" --run "$RUN" --pos 2 --total 3 --dest $MARK_H >> "$WORK/atags.log"
# copy order = this order: marker A first, the payload (kernel, ATAGs, overlay), marker C, marker H last
printf '%s %s\n' markA.bin $MARK_A kernel.bin $KERNEL_ADDR atags.bin $ATAGS_ADDR overlay.cpio $INITRD_ADDR markC.bin $MARK_C markH.bin $MARK_H > "$B/SEGS"
( cd "$B" && py "$HERE/ex4img.py" layout SEGS ) > "$WORK/layout.log" || { cat "$WORK/layout.log" >&2; die "the segment layout overlaps"; }
n=0; : > "$B/EXPECT"
while read -r f a; do
	echo "seg$n $(py -c 'import sys,zlib;print("%08x"%(zlib.crc32(open(sys.argv[1],"rb").read())&0xffffffff))' "$B/$f")" >> "$B/EXPECT"
	n=$((n + 1))
done < "$B/SEGS"
printf 'ENTRY=0x8000\nENTRY8=0x00008000\nR2=0x100\nR1_EXPECT=527\nMARK_TOTAL=3\nMARK_AT="0:%s,1:%s,2:%s"\nMARK_POS="0 1 2"\nKVER=%s\n' ${MARK_A#0x} ${MARK_C#0x} ${MARK_H#0x} $KVER > "$B/CFG"
# /proc/partitions on the box counts 1 KiB blocks; the trial's ex4log counts 512-byte sectors: one window, two units
printf 'LOG_MIN_KB=%s\nLOG_MAX_KB=%s\nLOG_EXACT_KB=%s\nLOG_TAG=%s\nLOG_SKIP_PORT=%s\nLOG_SKIP_PARTS="%s"\n' $((LOG_SECTORS / 2)) $((LOG_SECTORS / 2)) $((LOG_SECTORS / 2)) ex4-openwrt "$LOG_SKIP_PORT" "$LOG_SKIP_PART" > "$B/LOGCFG"
{
	echo "EX4 RAM-trial bundle, built $(date '+%Y-%m-%d %H:%M:%S %Z') by build/build.sh, run id $RUN"
	echo "compiler: $("${CROSS}gcc" --version | head -1) · dtc $(dtc --version | awk '{print $NF}')"
	echo "kernel.bin = zImage of $(basename "$IX4") + dts/kirkwood-wd-mycloud-ex4.dts (-DEX4_TRIAL: 7 NAND partitions, 7 read-only, WD's own offsets; both PHYs on the generic driver)"
	echo "ex4-trial.dtb md5 $(md5sum < "$WORK/dts/ex4-trial.dtb" | cut -d' ' -f1) · ex4phy (inside overlay.cpio only) md5 $(md5sum < "$WORK/ex4phy" | cut -d' ' -f1)"
	echo "ex4boot-l2off.ko = loader/ built against WD's linux-3.2.40 (GPL bundle 2.12.127) with EX4_L2OFF=1"
	echo "overlay: key-only ssh, auto-return $RETURN_MIN min (+2 deadman), disk log window $LOG_SECTORS sectors exactly, port kept off: ${LOG_SKIP_PORT:-none}"
	echo "xhci modules: see KMODS.txt (donor $(basename "$NSA"), sha256 $NSA_SHA)"
	echo "sources:"; grep -v '^#' "$HERE/SOURCES.sha256" | awk '{print "  " $1 "  " $2}'
} > "$B/PROVENANCE"
( cd "$B" && md5sum ex4boot-l2off.ko ex4peek ex4log ex4fan KMODS.txt kernel.bin overlay.cpio atags.bin markA.bin markC.bin markH.bin SEGS EXPECT RUNID CFG LOGCFG PROVENANCE ex4-trial.sh > MD5SUMS )
say "done: $B ($(ls "$B" | wc -l) files, $(du -sk "$B" | cut -f1) KiB), run id $RUN"
say "next: copy that folder to the EX4's data volume and follow README.md, 'Run it'. First command there: sh ex4-trial.sh check wdt"
