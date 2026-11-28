#!/bin/sh
# mknandsim612.sh : K1 of FINALIZE C4 (DESIGN-C4.md cfc3ebd6 §3): nandsim.ko for the k-ud 6.12.112 kernel (kernel.bin 988b393f /
# zImage 63329ccb), built OUT OF TREE, for the C4 RAM trial only. Runs on the build machine. Never overwrites. Writes ONLY under
# ~/ex4-build/finalize/c4/k1/ (a COPY of the k-ud kernel build tree is made there: the tree RUN 20's kernel came from is only read).
#   sh mknandsim612.sh <k-ud linux-6.12.112 build tree> <outdir under ~/ex4-build/finalize/c4/>
# Source = the tree's own drivers/mtd/nand/raw/nandsim.c (cdb99588), byte for byte (cmp'd). Config = the tree's .config untouched
# (dde33356 = the bwud bundle's VARIANT kernel-config-md5). Compiler = the toolchain that built the kernel (OpenWrt GCC 14.3.0
# r33311). KCFLAGS = the two flags OpenWrt's kernel build added (read from the tree's own drivers/usb/host/.xhci-plat.o.cmd), so
# the module is compiled with the in-tree modules' exact flag set. Nov 27 2026 (C4 build lane). Nothing installed or downloaded.
set -eu
TREE=$1; OUT=$2
case "$OUT" in "$HOME"/ex4-build/finalize/c4/*) ;; *) echo "REFUSED: $OUT is not under ~/ex4-build/finalize/c4/" >&2; exit 1;; esac
[ -e "$OUT" ] && { echo "REFUSED: $OUT exists" >&2; exit 1; }
OWRT=$HOME/ex4-build/k-ud/openwrt
TC=$OWRT/staging_dir/toolchain-arm_xscale_gcc-14.3.0_musl_eabi/bin
CC=$TC/arm-openwrt-linux-muslgnueabi-
BUILD_DIR=$OWRT/build_dir/target-arm_xscale_musl_eabi
m5() { md5sum < "$1" | cut -d' ' -f1; }
[ -x "${CC}gcc" ] || { echo "REFUSED: ${CC}gcc missing" >&2; exit 1; }
[ "$(m5 "${CC}gcc")" = 1cb79cee9c8d7fe5ca8411af46c2c481 ] || { echo "REFUSED: ${CC}gcc is not the pinned OpenWrt GCC 14.3.0 (1cb79cee)" >&2; exit 1; }
[ "$(cat "$TREE/include/config/kernel.release")" = 6.12.112 ] || { echo "REFUSED: tree is not 6.12.112" >&2; exit 1; }
[ "$(m5 "$TREE/.config")" = dde33356fc1a6d003fd470861cd8c10a ] || { echo "REFUSED: tree .config is not dde33356 (the bwud kernel's)" >&2; exit 1; }
[ "$(m5 "$TREE/Module.symvers")" = 6bcb7e1b489ead99bc419abac93a9505 ] || { echo "REFUSED: Module.symvers is not 6bcb7e1b" >&2; exit 1; }
[ "$(m5 "$TREE/drivers/mtd/nand/raw/nandsim.c")" = cdb99588e0413706d32ecfcf15f73101 ] || { echo "REFUSED: nandsim.c is not cdb99588" >&2; exit 1; }
[ "$(m5 "$TREE/arch/arm/boot/zImage")" = 63329ccba89a66199545d4624144d48e ] || { echo "REFUSED: the tree's zImage is not 63329ccb (bwud's)" >&2; exit 1; }
for k in 'CONFIG_MODULES=y' 'CONFIG_MODULE_UNLOAD=y' '# CONFIG_MODVERSIONS is not set' '# CONFIG_MODULE_SIG is not set' 'CONFIG_MTD_RAW_NAND=y' \
         'CONFIG_MTD_NAND_ECC_SW_HAMMING=y' '# CONFIG_MTD_NAND_NANDSIM is not set' 'CONFIG_MODULE_STRIPPED=y'; do
	[ "$(grep -cx "$k" "$TREE/.config")" = 1 ] || { echo "REFUSED: .config lacks the line '$k'" >&2; exit 1; }
done
XCMD=$TREE/drivers/usb/host/.xhci-plat.o.cmd
KCF="-fmacro-prefix-map=$BUILD_DIR=target-arm_xscale_musl_eabi -fno-caller-saves"
grep -q -- " $KCF  -DMODULE " "$XCMD" || { echo "REFUSED: the in-tree module flags do not end in '$KCF' (read $XCMD)" >&2; exit 1; }
mkdir -p "$OUT"
touch "$OUT/.before-copy"
W=$OUT/tree; M=$OUT/mod
cp -a "$TREE" "$W"
touch "$OUT/.before-build"; sleep 1
mkdir "$M"
cp "$W/drivers/mtd/nand/raw/nandsim.c" "$M/nandsim.c"
cmp "$M/nandsim.c" "$TREE/drivers/mtd/nand/raw/nandsim.c"
printf 'obj-m := nandsim.o\n' > "$M/Makefile"
export STAGING_DIR="$OWRT/staging_dir"      # OpenWrt's gcc wrapper wants it set (no effect on code)
PATH=$TC:$PATH make -C "$W" M="$M" ARCH=arm CROSS_COMPILE=arm-openwrt-linux-muslgnueabi- KCFLAGS="$KCF" KBUILD_HAVE_NLS=no modules \
	> "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
find "$W" -newer "$OUT/.before-build" -print > "$OUT/tree-copy-written.txt"
find "$TREE" -newer "$OUT/.before-copy" -print > "$OUT/tree-original-written.txt"
[ -s "$OUT/tree-copy-written.txt" ] && echo "NOTE: the build wrote into the tree COPY: see tree-copy-written.txt" || echo "tree copy untouched by the build"
[ -s "$OUT/tree-original-written.txt" ] && { echo "REFUSED: something wrote into the ORIGINAL tree during this run" >&2; exit 1; } || echo "original tree untouched"
"${CC}gcc" --version | head -1 > "$OUT/compiler.txt"
md5sum "$M/nandsim.ko" "$M/nandsim.c" "$M/nandsim.o" > "$OUT/MD5SUMS"
cat "$OUT/MD5SUMS"
echo "OK: $M/nandsim.ko"
