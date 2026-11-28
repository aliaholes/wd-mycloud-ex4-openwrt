#!/bin/sh
# k1-gates.sh : the gates of K1 (C4's nandsim.ko for 6.12.112), run on the build machine against the built module, read-only.
#   sh k1-gates.sh <k-ud linux-6.12.112 build tree> <k1 outdir of mknandsim612.sh>
# DESIGN-C4 §3 K1 asks for "modinfo vermagic = the running kernel's". THIS KERNEL HAS NO VERMAGIC TO COMPARE: it is built with
# CONFIG_MODULE_STRIPPED=y (OpenWrt), so (1) no module carries a vermagic string (its own in-tree modules neither) and (2) the
# kernel does not check one (kernel/module/main.c check_modinfo: the vermagic block sits inside #ifndef CONFIG_MODULE_STRIPPED).
# So the gate is replaced by what the loader DOES check, plus the build provenance (said plainly in C4-BUILD.md):
#   G1 source = the tree's nandsim.c (cdb99588)       G2 tree = 6.12.112, .config dde33356, Module.symvers 6bcb7e1b
#   G3 no vermagic in nandsim.ko AND none in the tree's own xhci-hcd.ko (the stripped-module rule holds for both), and the tree's
#      check_modinfo really skips it under CONFIG_MODULE_STRIPPED (source lines shown)
#   G4 .gnu.linkonce.this_module size == the in-tree xhci-hcd.ko's (= sizeof(struct module) of this build; the loader refuses any
#      other size: kernel/module/main.c:1900)       G5 every undefined symbol is exported by vmlinux (Module.symvers), none by a module
#   G6 license=GPL in .modinfo (GPL-only exports resolve)       G7 the parmtype of every parameter C4 passes is in .modinfo
#   G8 the .comment GCC string == xhci-hcd.ko's        G9 the compile flags of nandsim.o == xhci-plat.o's (file-specific words removed)
#   G10 ELF header: ARM, EABI5 soft-float relocatable, same e_flags as xhci-hcd.ko
set -u
TREE=$1; K1=$2; KO=$K1/mod/nandsim.ko; REF=$TREE/drivers/usb/host/xhci-hcd.ko
T=$HOME/ex4-build/k-ud/openwrt/staging_dir/toolchain-arm_xscale_gcc-14.3.0_musl_eabi/bin/arm-openwrt-linux-muslgnueabi-
R=0; pass() { echo "PASS $*"; }; fail() { echo "FAIL $*"; R=1; }
m5() { md5sum < "$1" | cut -d' ' -f1; }
echo "k1-gates $(m5 "$0"); nandsim.ko $(m5 "$KO") ($(stat -c %s "$KO") B); reference in-tree module xhci-hcd.ko $(m5 "$REF"); $(date '+%F %T %Z')"
[ "$(m5 "$K1/mod/nandsim.c")" = cdb99588e0413706d32ecfcf15f73101 ] && cmp -s "$K1/mod/nandsim.c" "$TREE/drivers/mtd/nand/raw/nandsim.c" \
	&& pass "G1 source: mod/nandsim.c = the tree's drivers/mtd/nand/raw/nandsim.c, cdb99588" || fail "G1 source"
[ "$(cat "$TREE/include/config/kernel.release")" = 6.12.112 ] && [ "$(m5 "$TREE/.config")" = dde33356fc1a6d003fd470861cd8c10a ] \
	&& [ "$(m5 "$TREE/Module.symvers")" = 6bcb7e1b489ead99bc419abac93a9505 ] && [ "$(wc -l < "$TREE/Module.symvers")" = 8761 ] \
	&& pass "G2 tree: kernel.release 6.12.112, .config dde33356, Module.symvers 6bcb7e1b (8761 lines)" || fail "G2 tree"
sect() { o=$K1/gates-sect.$$; rm -f "$o"; "${T}objcopy" -O binary --only-section="$2" "$1" "$o" 2>/dev/null; tr '\0' '\n' < "$o"; rm -f "$o"; }
modinfo_has() { sect "$1" .modinfo | grep -c "^$2"; }
vk=$(sect "$KO" .modinfo | sed -n 's/^vermagic=//p'); vr=$(sect "$REF" .modinfo | sed -n 's/^vermagic=//p')
vv=; [ -n "$vk" ] && [ "$(tr '\0' '\n' < "$TREE/vmlinux" | grep -c -x -F "$vk")" -ge 1 ] && vv=$vk       # the exact NUL-terminated string in vmlinux
SRC=$(sed -n '/^static int check_modinfo(/,/^}/p' "$TREE/kernel/module/main.c")
[ -n "$vk" ] && [ "$vk" = "$vr" ] && [ "$vk" = "$vv" ] \
	&& pass "G3 vermagic '$vk' = the in-tree xhci-hcd.ko's = the string in the tree's vmlinux" || fail "G3 vermagic: nandsim '$vk' xhci '$vr' vmlinux '$vv'"
echo "$SRC" | grep -q '^#ifndef CONFIG_MODULE_STRIPPED$' && grep -qx 'CONFIG_MODULE_STRIPPED=y' "$TREE/.config" \
	&& echo "NOTE G3: this kernel does NOT check vermagic at load (check_modinfo's test sits inside #ifndef CONFIG_MODULE_STRIPPED; .config has CONFIG_MODULE_STRIPPED=y): G3 is our offline check, the loader would not catch a mismatch. G4 + G5 are what the loader does check." \
	|| echo "NOTE G3: check_modinfo is not the stripped form (read it below)"
echo "$SRC" | sed -n '1,22p' | sed 's/^/      | /'
tm() { "${T}readelf" -S -W "$1" | awk '$2 == ".gnu.linkonce.this_module" {print $6}'; }
a=$(tm "$KO"); b=$(tm "$REF")
[ -n "$a" ] && [ "$a" = "$b" ] && pass "G4 .gnu.linkonce.this_module size 0x$a = xhci-hcd.ko's 0x$b (the loader's sizeof(struct module) check, kernel/module/main.c:1900)" || fail "G4 this_module size $a vs $b"
U=$("${T}nm" -u "$KO" | awk '{print $2}' | sort -u); n=0; bad=
for s in $U; do
	n=$((n + 1)); l=$(awk -v s="$s" '$2 == s' "$TREE/Module.symvers")
	[ -n "$l" ] || { bad="$bad $s(absent)"; continue; }
	[ "$(echo "$l" | awk '{print $3}')" = vmlinux ] || bad="$bad $s(module:$(echo "$l" | awk '{print $3}'))"
done
[ -z "$bad" ] && pass "G5 all $n undefined symbols are exported by vmlinux (Module.symvers)" || fail "G5 symbols:$bad"
"${T}nm" -u "$KO" | awk '{print $2}' | sort -u | while read -r s; do awk -v s="$s" '$2 == s {printf "      %-40s %s %s\n", $2, $3, $4}' "$TREE/Module.symvers"; done
[ "$(modinfo_has "$KO" license=GPL)" = 1 ] && pass "G6 license=GPL" || fail "G6 license"
g7=0; for p in first_id_byte second_id_byte third_id_byte fourth_id_byte parts badblocks; do
	[ "$(modinfo_has "$KO" "parmtype=$p:")" = 1 ] || { fail "G7 parmtype $p missing"; g7=1; }
done; [ $g7 = 0 ] && pass "G7 the 6 parameters C4 passes each have one parmtype"; echo "      parmtypes: $(sect "$KO" .modinfo | grep -E '^parmtype=(first_id_byte|second_id_byte|third_id_byte|fourth_id_byte|parts|badblocks):' | tr '\n' ' ')"
cm() { "${T}readelf" -p .comment "$1" | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' | sort -u; }
[ -n "$(cm "$KO")" ] && [ "$(cm "$KO")" = "$(cm "$REF")" ] && pass "G8 .comment = xhci-hcd.ko's: $(cm "$KO" | tr '\n' ' ')" || fail "G8 .comment: $(cm "$KO") vs $(cm "$REF")"
flags() { sed -n '1p' "$1" | sed 's/^savedcmd_[^ ]* := //' | tr ' ' '\n' | grep -v -e '^-Wp,-MMD' -e '^-DKBUILD_BASENAME=' -e '^-DKBUILD_MODNAME=' \
	-e '^-D__KBUILD_MODNAME=' -e '\.c$' -e '\.o$' -e '^-o$' -e '^$' | sort; }
fa=$(flags "$K1/mod/.nandsim.o.cmd"); fb=$(flags "$TREE/drivers/usb/host/.xhci-plat.o.cmd")
if [ "$fa" = "$fb" ]; then pass "G9 compile flags of nandsim.o = the in-tree xhci-plat.o's ($(echo "$fa" | wc -l) words, file-specific words removed)"
else fail "G9 compile flags differ (< xhci-plat.o, > nandsim.o):"; echo "$fb" > "$K1/flags-xhci.txt"; echo "$fa" | diff "$K1/flags-xhci.txt" - | sed 's/^/      /'; fi
eh() { "${T}readelf" -h "$1" | grep -E 'Class|Machine|Type:|Flags' | sed 's/  */ /g'; }
[ "$(eh "$KO")" = "$(eh "$REF")" ] && pass "G10 ELF header = xhci-hcd.ko's: $(eh "$KO" | tr '\n' ';')" || fail "G10 ELF header"
echo "RESULT: $([ $R = 0 ] && echo 'K1 GATES PASS' || echo 'K1 GATES FAIL')"
exit $R
