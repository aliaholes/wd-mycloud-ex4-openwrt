#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# build/v7/build-v7.sh : the EX4 v7 RAM-trial bundle with OUR OWN kernel. Two stages, both reproducible from an
# empty folder:
#
#   sh build/v7/build-v7.sh image  --work DIR [--seed-dl DIR] [--jobs N]
#   sh build/v7/build-v7.sh bundle --work DIR --pubkey KEY.pub --wd-gpl WDMyCloud_EX4_GPL_v2.12.127_20181219.tar.gz [--out DIR]
#
# image  : OpenWrt 25.12.6 (tag v25.12.6 = r33311-981c978eff) built from source in DIR/openwrt: kirkwood/generic,
#          the kernel config fragment (the SoC's XOR/copy engines: DMADEVICES + MV_XOR + ASYNC_TX_DMA; md + raid1 +
#          raid456 BUILT IN with autodetect OFF; ext4 quotas), the package list of THE NAMED LIST (diffconfig), an initramfs
#          kernel. Every source comes from OpenWrt's own servers: git.openwrt.org for the tree and the packages feed
#          (both pinned to the release's commits, checked), and OpenWrt's source mirror for every tarball, through
#          build/v7/egress-allow.py, a local proxy that refuses every other host (its log is the receipt). OpenWrt's
#          own hash checks (PKG_HASH, PKG_MIRROR_HASH, LINUX_KERNEL_HASH) stay on: nothing here turns them off.
#          --seed-dl DIR copies files you already hold (e.g. linux-6.12.112.tar.xz) into dl/; OpenWrt checks their
#          hashes like any download. Between package/install and target/install it disables, IN THE IMAGE, every
#          service that touches data or listens on the LAN without a login (see ROOTFS HOOK below), so a RAM trial
#          starts none of them.
# bundle : bundle-v7, laid out exactly like bundle-v6 (build/build.sh): the trial loader built against WD's 3.2.40
#          tree, the static ARM programs, OUR kernel's zImage + the EX4 trial DTB (dts/, -DEX4_TRIAL: every NAND
#          partition read-only), the overlay (build/mkoverlay.py, fed this image's own 02_network + 00_preinit.conf
#          and this image's own xhci modules), ATAGs, RAM markers, SEGS / EXPECT / CFG / LOGCFG / MD5SUMS. Adds a
#          SIZE gate (the kernel's decompression must end below RAM marker H at 0x3000000) and the MV_XOR proof.
#
# Needs (image): what OpenWrt's build needs (gcc g++ make gawk flex bison python3 perl git curl rsync unzip file
# libncurses-dev zlib1g-dev libssl-dev swig), ~25 GB, a few hours on 1 core / ~1 h on 20. Built on Ubuntu 24.04 arm64.
# Needs (bundle): build/build.sh's list (ARM cross gcc with a static glibc, dtc, cpp).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd)
STAGE=${1:-}; [ $# -gt 0 ] && shift
WORK=; SEED=; JOBS=$(nproc 2>/dev/null || echo 2); PUB=; WDGPL=; OUT=
while [ $# -gt 0 ]; do
	case "$1" in
	--work) WORK=${2:?}; shift 2;;
	--seed-dl) SEED=${2:?}; shift 2;;
	--jobs) JOBS=${2:?}; shift 2;;
	--pubkey) PUB=${2:?}; shift 2;;
	--wd-gpl) WDGPL=${2:?}; shift 2;;
	--out) OUT=${2:?}; shift 2;;
	*) echo "usage: see the header of $0" >&2; exit 64;;
	esac
done
die() { echo "build-v7: REFUSED: $*" >&2; exit 1; }
say() { echo "build-v7: $(date '+%H:%M:%S') $*"; }
[ -n "$WORK" ] || die "--work DIR is required"
py() { python3 -I "$@"; }

# ---- the pins (from the release's own buildinfo files, downloads.openwrt.org/releases/25.12.6/targets/kirkwood/generic/) ----
OWRT_GIT=https://git.openwrt.org/openwrt/openwrt.git
OWRT_TAG=v25.12.6
OWRT_TAG_OBJ=22dd0e28678a6cd6fbadea2d5aaded3a805ab8a4      # the signed tag object (tagger Hauke Mehrtens)
OWRT_COMMIT=64900e756efa667774214f9c6b17c113222e01f7       # "OpenWrt v25.12.6: adjust config defaults"
OWRT_REV=r33311-981c978eff                                  # version.buildinfo of the official release
FEED_PACKAGES="src-git packages https://git.openwrt.org/feed/packages.git^093d551675b1119a06ef224d419905e8d6b2af1a"
FEED_PKGS="samba4-server ksmbd-server kmod-fs-ksmbd nfs-kernel-server wsdd2 avahi-nodbus-daemon msmtp smartmontools smartd rsync proto-bonding"
KVER=6.12.112
PROXY_PORT=${PROXY_PORT:-18443}
# services the ROOTFS HOOK takes out of /etc/rc.d (installed, startable by hand, never at boot)
NOBOOT="mdadm samba4 ksmbd nfsd rpcbind wsdd2 avahi-daemon"
# kernel modules the hook keeps from autoloading (USB disks would shift the sdX names the trial's log gate uses)
NOAUTOLOAD="usb-storage usb-storage-uas"

if [ "$STAGE" = image ]; then
	for t in git make gcc g++ gawk flex bison python3 perl curl rsync unzip file swig patch; do
		command -v "$t" >/dev/null || die "$t not found"
	done
	mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd); O="$WORK/openwrt"
	[ -e "$O" ] && die "$O exists (this stage starts from an empty folder)"
	PLOG="$WORK/egress.log"
	py "$HERE/egress-allow.py" --port "$PROXY_PORT" --log "$PLOG" &
	PXPID=$!; trap 'kill $PXPID 2>/dev/null || true' EXIT INT TERM
	sleep 1; kill -0 $PXPID 2>/dev/null || die "the egress proxy did not start (port $PROXY_PORT busy?)"
	P=http://127.0.0.1:$PROXY_PORT
	export https_proxy=$P http_proxy=$P HTTPS_PROXY=$P HTTP_PROXY=$P DOWNLOAD_MIRROR=https://sources.cdn.openwrt.org
	unset no_proxy NO_PROXY || true

	say "1/7 the OpenWrt tree from $OWRT_GIT, tag $OWRT_TAG"
	git clone -q "$OWRT_GIT" "$O"
	cd "$O"
	[ "$(git rev-parse "$OWRT_TAG")" = "$OWRT_TAG_OBJ" ] || die "tag $OWRT_TAG is not the object $OWRT_TAG_OBJ"
	[ "$(git rev-parse "$OWRT_TAG^{commit}")" = "$OWRT_COMMIT" ] || die "tag $OWRT_TAG does not point at $OWRT_COMMIT"
	git -c advice.detachedHead=false checkout -q "$OWRT_TAG"
	[ "$(./scripts/getver.sh)" = "$OWRT_REV" ] || die "getver says $(./scripts/getver.sh), the release says $OWRT_REV"
	grep -qxF "$FEED_PACKAGES" feeds.conf.default || die "feeds.conf.default does not pin the packages feed the release used"

	say "2/7 the packages feed (only that one), pinned"
	echo "$FEED_PACKAGES" > feeds.conf
	./scripts/feeds update -a > "$WORK/feeds-update.log" 2>&1 || { tail -20 "$WORK/feeds-update.log" >&2; die "feeds update"; }
	[ "$(git -C feeds/packages rev-parse HEAD)" = "${FEED_PACKAGES##*^}" ] || die "feeds/packages is not at ${FEED_PACKAGES##*^}"
	./scripts/feeds install $FEED_PKGS > "$WORK/feeds-install.log" 2>&1 || die "feeds install"

	say "3/7 our changes to the tree: the mdadm dependency line, the kernel config fragment, our files/"
	cp package/utils/mdadm/Makefile "$WORK/mdadm.Makefile.orig"
	sed -i -f "$HERE/patches/mdadm-no-md-kmods.sed" package/utils/mdadm/Makefile
	[ "$(diff "$WORK/mdadm.Makefile.orig" package/utils/mdadm/Makefile | grep -c '^[<>]')" = 2 ] || die "the mdadm sed did not change exactly one line"
	T=target/linux/kirkwood/config-6.12
	for s in $(grep -oE '^(# )?CONFIG_[A-Z0-9_]+' "$HERE/kernel-config.fragment" | sed 's/^# //'); do
		sed -i -E "/^(# )?$s(=| is not set)/d" "$T"
	done
	grep -E '^CONFIG_[A-Z0-9_]+=|^# CONFIG_[A-Z0-9_]+ is not set' "$HERE/kernel-config.fragment" >> "$T"
	git diff --stat > "$WORK/tree-changes.txt"; git diff > "$WORK/tree-changes.diff"
	mkdir -p files; cp -R "$HERE/files/." files/
	find files -type f | sort > "$WORK/files-list.txt"

	say "4/7 .config from build/v7/diffconfig"
	cp "$HERE/diffconfig" .config
	make defconfig > "$WORK/defconfig.log" 2>&1 || die "make defconfig"
	for p in mdadm e2fsprogs smartmontools smartd samba4-server ksmbd-server kmod-fs-ksmbd nfs-kernel-server kmod-fs-nfsd \
		wsdd2 avahi-nodbus-daemon msmtp kmod-bonding proto-bonding rsync kmod-usb-storage kmod-usb-storage-uas kmod-fs-vfat \
		kmod-fs-exfat rpcd rpcd-mod-ucode uhttpd kmod-usb3 kmod-ata-marvell-sata kmod-fs-ext4; do
		grep -qx "CONFIG_PACKAGE_$p=y" .config || die "the resolved .config lacks $p"
	done
	for p in kmod-md-mod kmod-md-raid456 dnsmasq firewall4 odhcpd-ipv6only uboot-envtools block-mount; do
		grep -q "^CONFIG_PACKAGE_$p=[ym]" .config && die "the resolved .config selects $p (it must not)"
	done
	grep -q '=m$' .config && die "the resolved .config builds packages that go into no image: $(grep '=m$' .config | tr '\n' ' ')"
	./scripts/diffconfig.sh > "$WORK/diffconfig.resolved"

	if [ -n "$SEED" ]; then mkdir -p dl; cp -L "$SEED"/* dl/ 2>/dev/null || true; fi
	say "5/7 make download (OpenWrt's mirror first; every other host is refused by the proxy; OpenWrt checks every hash)"
	make -j"$JOBS" download > "$WORK/download.log" 2>&1 || { tail -30 "$WORK/download.log" >&2; die "make download (refused hosts: $PLOG)"; }

	say "6/7 compile: tools, toolchain, kernel, packages, rootfs"
	make -j"$JOBS" tools/install toolchain/install target/compile package/compile package/install > "$WORK/make-1.log" 2>&1 || {
		tail -40 "$WORK/make-1.log" >&2; die "compile (log: $WORK/make-1.log; for the failing package: make -j1 V=s package/<name>/compile)"; }

	say "ROOTFS HOOK: services that stay off at boot, autoloads that stay off"
	R=$(ls -d "$O"/build_dir/target-*/root-kirkwood)
	[ -d "$R/etc/rc.d" ] || die "no rootfs at $R"
	: > "$WORK/rootfs-hook.txt"
	for s in $NOBOOT; do
		[ -x "$R/etc/init.d/$s" ] || die "the image has no /etc/init.d/$s (the hook's list is stale)"
		for l in "$R"/etc/rc.d/S??"$s" "$R"/etc/rc.d/K??"$s"; do
			[ -L "$l" ] || continue; rm "$l"; echo "rc.d: removed ${l##*/}" >> "$WORK/rootfs-hook.txt"
		done
	done
	mkdir -p "$R/usr/share/ex4/modules.d.off"
	for m in $NOAUTOLOAD; do
		for x in "$R"/etc/modules.d/*; do
			b=${x##*/}; case "$b" in "$m"|[0-9][0-9]-"$m") ;; *) continue;; esac
			mv "$x" "$R/usr/share/ex4/modules.d.off/$b"; echo "modules.d: $b kept from autoloading (modprobe by hand)" >> "$WORK/rootfs-hook.txt"
		done
	done
	ls "$R"/etc/rc.d > "$WORK/rc.d-after-hook.txt"
	for s in $NOBOOT; do grep -q "^[SK][0-9][0-9]$s\$" "$WORK/rc.d-after-hook.txt" && die "$s is still in rc.d"; done

	say "7/7 the initramfs kernel"
	make -j"$JOBS" target/install > "$WORK/make-2.log" 2>&1 || { tail -40 "$WORK/make-2.log" >&2; die "target/install"; }
	IMG=$(ls "$O"/bin/targets/kirkwood/generic/*iom_ix4-200d-initramfs-uImage)
	[ -s "$IMG" ] || die "no initramfs image came out"
	grep -q "^CONFIG_MV_XOR=y" "$O"/build_dir/target-*/linux-kirkwood_generic/linux-$KVER/.config || die "the built kernel's .config has no CONFIG_MV_XOR=y"
	grep -q "^# CONFIG_MD_AUTODETECT is not set" "$O"/build_dir/target-*/linux-kirkwood_generic/linux-$KVER/.config || die "the built kernel can autodetect md arrays"
	REFUSED=$(grep -c ' REFUSE ' "$PLOG" || true)
	say "done: $IMG ($(stat -c %s "$IMG") bytes); the proxy refused $REFUSED connection attempt(s), allowed $(grep -c ' ALLOW ' "$PLOG" || true) (log: $PLOG)"
	exit 0
fi

if [ "$STAGE" = bundle ]; then
	WORK=$(cd "$WORK" && pwd); O="$WORK/openwrt"
	[ -n "$PUB" ] || die "--pubkey is required: without a key the trial system would accept root with no password from the LAN"
	[ -s "$PUB" ] || die "$PUB not found"
	grep -q 'PRIVATE KEY' "$PUB" && die "$PUB is a PRIVATE key. Give the .pub file."
	[ "$(grep -c . "$PUB")" = 1 ] || die "$PUB must hold exactly one public key line"
	[ -s "$WDGPL" ] || die "--wd-gpl: WD's GPL bundle (see build/SOURCES.sha256)"
	want=$(awk '$2 == "WDMyCloud_EX4_GPL_v2.12.127_20181219.tar.gz" {print $1}' "$TOP/build/SOURCES.sha256")
	[ "$(sha256sum < "$WDGPL" | cut -d' ' -f1)" = "$want" ] || die "$WDGPL does not have sha256 $want"
	CROSS=${CROSS:-arm-linux-gnueabi-}
	for t in python3 make perl tar gzip sha256sum md5sum cpp dtc "${CROSS}gcc" "${CROSS}strip" "${CROSS}nm"; do command -v "$t" >/dev/null || die "$t not found"; done
	LOG_SECTORS=${LOG_SECTORS:-2098831}; LOG_SKIP_PORT=${LOG_SKIP_PORT:-}; LOG_SKIP_PART=${LOG_SKIP_PART:-}
	RETURN_MIN=${RETURN_MIN:-20}; STAMP=${STAMP:-$(date +%Y%m%d-%H%M)}; RUNNO=${RUNNO:-1}
	case "$RUNNO$LOG_SECTORS$RETURN_MIN" in *[!0-9]*) die "RUNNO, LOG_SECTORS, RETURN_MIN must be numbers";; esac
	[ -z "$LOG_SKIP_PORT$LOG_SKIP_PART" ] || { [ -n "$LOG_SKIP_PORT" ] && [ -n "$LOG_SKIP_PART" ]; } || die "LOG_SKIP_PORT and LOG_SKIP_PART go together"
	case "$LOG_SKIP_PART" in ''|sd[a-d]3) ;; *) die "LOG_SKIP_PART must look like sdd3";; esac
	OUT=${OUT:-$WORK/out}; B="$OUT/bundle-v7"; BW="$WORK/bundle-work"
	[ -e "$B" ] && die "$B exists (never overwrite)"; [ -e "$BW" ] && die "$BW exists"
	mkdir -p "$B" "$BW"; PUB=$(cd "$(dirname "$PUB")" && pwd)/$(basename "$PUB")
	IMG=$(ls "$O"/bin/targets/kirkwood/generic/*iom_ix4-200d-initramfs-uImage) || die "run the image stage first"
	L=$(ls -d "$O"/build_dir/target-*/linux-kirkwood_generic/linux-$KVER)
	R=$(ls -d "$O"/build_dir/target-*/root-kirkwood)

	say "1/7 WD's kernel tree (for the loader module only)"
	mkdir "$BW/wd"
	tar -xzf "$WDGPL" -C "$BW/wd" WDMyCloud_EX4_GPL_v2.12.127_20181219/kernel/linux-3.2.40.tar.gz
	tar -xzf "$BW/wd/WDMyCloud_EX4_GPL_v2.12.127_20181219/kernel/linux-3.2.40.tar.gz" -C "$BW/wd"
	rm -rf "$BW/wd/WDMyCloud_EX4_GPL_v2.12.127_20181219"
	TREE="$BW/wd/linux-3.2.40"
	grep -q '^CONFIG_MV_32KB_SW_PAGE_SIZE_SUPPORT=y' "$TREE/.config" || die "WD's .config is not the EX4's"
	GCCMAJ=$("${CROSS}gcc" -dumpversion | cut -d. -f1)
	[ -e "$TREE/include/linux/compiler-gcc$GCCMAJ.h" ] || cp "$TREE/include/linux/compiler-gcc4.h" "$TREE/include/linux/compiler-gcc$GCCMAJ.h"
	KMAKE="make -C $TREE ARCH=arm CROSS_COMPILE=$CROSS KCFLAGS=-DALPHA_CUSTOMIZE"
	$KMAKE -j"$JOBS" modules_prepare > "$BW/wd-prepare.log" 2>&1 || die "modules_prepare (log $BW/wd-prepare.log)"

	say "2/7 ex4boot-l2off.ko"
	mkdir "$BW/mod"; cp "$TOP/loader/ex4boot_main.c" "$TOP/loader/ex4boot_stub.S" "$TOP/loader/Makefile" "$BW/mod/"
	$KMAKE M="$BW/mod" EX4_L2OFF=1 modules > "$BW/mod-build.log" 2>&1 || die "module build (log $BW/mod-build.log)"
	py -c 'import sys; d=open(sys.argv[1],"rb").read(); sys.exit(0 if b"vermagic=3.2.40 mod_unload ARMv5 p2v8 " in d else 1)' "$BW/mod/ex4boot.ko" || die "the module's vermagic"

	say "3/7 ex4-trial.dtb against OUR kernel's own (OpenWrt-patched) $KVER tree"
	mkdir "$BW/dts"
	cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -DEX4_TRIAL -I "$L/arch/arm/boot/dts/marvell" -I "$L/include" "$TOP/dts/kirkwood-wd-mycloud-ex4.dts" > "$BW/dts/ex4-trial.pp.dts"
	dtc -q -I dts -O dtb -o "$BW/dts/ex4-trial.dtb" "$BW/dts/ex4-trial.pp.dts" 2> "$BW/dts/dtc.log" || { cat "$BW/dts/dtc.log" >&2; die "dtc"; }
	dtc -q -I dtb -O dts "$BW/dts/ex4-trial.dtb" > "$BW/dts/ex4-trial.decompiled.dts" 2>/dev/null
	# THE XOR ENGINES IN THE TREE: both orion-xor nodes present and not disabled
	py - "$BW/dts/ex4-trial.decompiled.dts" <<'PY' || die "the DTB does not carry both XOR engines enabled"
import re, sys
t = open(sys.argv[1]).read()
ok = []
for n in ('60800', '60900'):
    i = t.find('xor@%s {' % n)
    body = t[i:t.find('\n\t\t};', i)] if i >= 0 else ''
    if 'marvell,orion-xor' in body and 'status = "okay"' in body and body.count('dmacap,xor') == 2:
        ok.append(n)
print("dtb: XOR engines enabled (orion-xor, okay, two xor channels each):", ok)
sys.exit(0 if ok == ['60800', '60900'] else 1)
PY

	say "4/7 kernel.bin = OUR zImage + ex4-trial.dtb; the gates"
	py "$TOP/build/ex4img.py" split "$IMG" "$BW/split" > "$BW/split.log"
	py "$TOP/build/ex4img.py" join "$BW/split/zImage" "$BW/dts/ex4-trial.dtb" "$B/kernel.bin" >> "$BW/split.log"
	py "$TOP/tests/dtb_check.py" "$B/kernel.bin" --v6 > "$BW/dtb-check.log" 2>&1 || { cat "$BW/dtb-check.log" >&2; die "dtb_check --v6"; }
	py "$TOP/build/kimg_extract.py" "$B/kernel.bin" "$BW/Image" > "$BW/kimg.log" 2>&1 || { cat "$BW/kimg.log" >&2; die "kimg_extract"; }
	py "$TOP/tests/phy-id-check.py" "$L" "$B/kernel.bin" "$BW/Image" > "$BW/phy-id-check.log" 2>&1 || { cat "$BW/phy-id-check.log" >&2; die "phy-id-check"; }
	# THE XOR ENGINE IN THE KERNEL: config, symbols, driver strings
	{
		grep -E '^CONFIG_(DMADEVICES|DMA_ENGINE|MV_XOR|ASYNC_TX_DMA|ASYNC_TX_ENABLE_CHANNEL_SWITCH|BLK_DEV_MD|MD_RAID1|MD_RAID456|QUOTA|QFMT_V2)=|^# CONFIG_MD_AUTODETECT is not set' "$L/.config"
		echo "System.map: $(grep -cE ' (mv_xor_probe|mv_xor_prep_dma_xor|mv_xor_prep_dma_memcpy|mv_xor_driver|async_xor|dma_async_device_register|raid5_run|md_run)$' "$L/System.map") of 8 symbols: $(grep -oE ' (mv_xor_probe|mv_xor_prep_dma_xor|mv_xor_prep_dma_memcpy|mv_xor_driver|async_xor|dma_async_device_register|raid5_run|md_run)$' "$L/System.map" | tr -d ' ' | tr '\n' ' ')"
		echo "decompressed image strings: orion-xor=$(grep -c 'marvell,orion-xor' "$BW/Image" || true) mv_xor=$(grep -ac 'mv_xor' "$BW/Image" || true)"
	} > "$BW/xor-proof.txt"
	grep -q '^CONFIG_MV_XOR=y' "$BW/xor-proof.txt" && grep -q '^CONFIG_ASYNC_TX_DMA=y' "$BW/xor-proof.txt" && grep -q 'System.map: 8 of 8' "$BW/xor-proof.txt" \
		&& ! grep -q 'orion-xor=0' "$BW/xor-proof.txt" || { cat "$BW/xor-proof.txt" >&2; die "the XOR engine is not in the kernel"; }
	# THE SIZE GATE: the decompressor at 0x8000 relocates itself past the end of the decompressed image when they
	# overlap, then decompresses; its peak must stay below RAM marker H (0x3000000), and so below the overlay (0x4000000)
	TEXT=$(awk '$3 == "_text" {print $1}' "$L/System.map"); END=$(awk '$3 == "_end" {print $1}' "$L/System.map")
	py - "$TEXT" "$END" "$B/kernel.bin" > "$BW/size-gate.txt" <<'PY' || { cat "$BW/size-gate.txt" >&2; die "the kernel does not fit below RAM marker H"; }
import os, sys
text, end = int(sys.argv[1], 16), int(sys.argv[2], 16)
image = end - text                         # decompressed kernel incl. bss (its built-in initramfs is inside, xz)
z = os.path.getsize(sys.argv[3])           # zImage + appended DTB: what the decompressor copies past the image
slack = 0x10000 + 0x20000 + 0x10000        # its stack + malloc + the DTB's growth from the ATAG fold (generous)
peak = 0x8000 + image + z + slack
print(f"decompressed image {image} B, kernel.bin {z} B, worst-case peak 0x{peak:x}, marker H 0x3000000, overlay 0x4000000, margin {0x3000000 - peak} B")
sys.exit(0 if peak < 0x3000000 else 1)
PY
	cat "$BW/size-gate.txt"

	say "5/7 ex4fan, ex4log, ex4peek, ex4phy (as build/build.sh)"
	for p in ex4fan ex4log ex4peek; do
		"${CROSS}gcc" -static -Os -march=armv5te -Wall -Wl,-z,max-page-size=0x8000 -o "$B/$p" "$TOP/userland/$p.c" 2> "$BW/$p.build.log" || die "$p"
		chmod 755 "$B/$p"
	done
	"${CROSS}strip" "$B/ex4log" "$B/ex4peek"
	grep -q 'SIOCSMIIREG\|SIOCETHTOOL\|SIOCSIF' "$TOP/userland/ex4phy.c" && die "ex4phy.c must stay read-only"
	"${CROSS}gcc" -static -Os -march=armv5te -Wall -Wl,-z,max-page-size=0x8000 -o "$BW/ex4phy" "$TOP/userland/ex4phy.c" 2> "$BW/ex4phy.build.log" || die "ex4phy"
	"${CROSS}strip" "$BW/ex4phy"

	say "6/7 xhci modules: OUR image's own (the overlay's --kmods also brings the second auto-return, the deadman)"
	K="$BW/kmods"; mkdir -p "$K/lib/modules/$KVER" "$K/etc/modules.d"
	for m in xhci-hcd xhci-pci xhci-plat-hcd; do cp "$R/lib/modules/$KVER/$m.ko" "$K/lib/modules/$KVER/" || die "our image has no $m.ko"; done
	for f in "$R"/etc/modules.d/*usb3* "$R"/etc/modules.d/*xhci*; do [ -f "$f" ] && cp "$f" "$K/etc/modules.d/"; done
	ls "$K/etc/modules.d" | grep -q . || die "no xhci autoload list in our image"
	{ echo "xhci modules: from this build's own image (lib/modules/$KVER, byte-identical to the copies inside kernel.bin's initramfs)"
	  ( cd "$K" && find . -type f | sort | xargs md5sum ); } > "$B/KMODS.txt"

	say "7/7 overlay.cpio, ATAGs, markers, the bundle's text files"
	set -- --network-file "$R/etc/board.d/02_network" --pubkey "$PUB" --return-min "$RETURN_MIN" \
		--ex4log "$B/ex4log" --log-min-sectors "$LOG_SECTORS" --log-max-sectors "$LOG_SECTORS" --tag ex4-openwrt \
		--preinit-conf "$R/lib/preinit/00_preinit.conf" --ex4fan "$B/ex4fan" --ex4mac --kmods "$K" --ex4phy "$BW/ex4phy" --out "$B/overlay.cpio"
	[ -z "$LOG_SKIP_PORT" ] || set -- "$@" --log-skip-port "$LOG_SKIP_PORT"
	py "$TOP/build/mkoverlay.py" "$@" > "$BW/mkoverlay.log"
	cp "$BW/mod/ex4boot.ko" "$B/ex4boot-l2off.ko"
	cp "$TOP/box/ex4-trial.sh" "$B/ex4-trial.sh"
	KERNEL_ADDR=0x8000; ATAGS_ADDR=0x100; INITRD_ADDR=0x4000000; MARK_A=0x1000; MARK_C=0x3000; MARK_H=0x3000000
	RUN="$RUNNO-l2off-$STAMP"; printf '%s\n' "$RUN" > "$B/RUNID"
	SZ=$(stat -c %s "$B/overlay.cpio")
	py "$TOP/build/ex4img.py" atags "$B/atags.bin" --mem 512 --initrd "$INITRD_ADDR,$SZ" --cmdline "console=ttyS0,115200n8 watchdog.open_timeout=120 ex4boot_run=$RUN" > "$BW/atags.log"
	py "$TOP/build/ex4img.py" atags-parse "$B/atags.bin" --expect-token "ex4boot_run=$RUN" --expect-initrd "$INITRD_ADDR,$SZ" --max-end "$MARK_A" >> "$BW/atags.log" || die "ATAGs"
	py "$TOP/build/ex4img.py" marker "$B/markA.bin" --run "$RUN" --pos 0 --total 3 --dest $MARK_A >> "$BW/atags.log"
	py "$TOP/build/ex4img.py" marker "$B/markC.bin" --run "$RUN" --pos 1 --total 3 --dest $MARK_C >> "$BW/atags.log"
	py "$TOP/build/ex4img.py" marker "$B/markH.bin" --run "$RUN" --pos 2 --total 3 --dest $MARK_H >> "$BW/atags.log"
	printf '%s %s\n' markA.bin $MARK_A kernel.bin $KERNEL_ADDR atags.bin $ATAGS_ADDR overlay.cpio $INITRD_ADDR markC.bin $MARK_C markH.bin $MARK_H > "$B/SEGS"
	( cd "$B" && py "$TOP/build/ex4img.py" layout SEGS ) > "$BW/layout.log" || { cat "$BW/layout.log" >&2; die "layout overlaps"; }
	# the loader's chunk table: one 32 KiB page per chunk on the stock kernel, (32768 - 1024 - 16) / 12 = 2644 entries, one kept free
	py - "$B" <<'PY' >> "$BW/layout.log" || die "too many 32 KiB chunks for the loader's table"
import os, sys
b = sys.argv[1]; n = 0
for line in open(os.path.join(b, 'SEGS')):
    f = line.split()[0]; n += -(-os.path.getsize(os.path.join(b, f)) // 32768)
print(f"loader chunks: {n} of 2643"); sys.exit(0 if n <= 2643 else 1)
PY
	n=0; : > "$B/EXPECT"
	while read -r f a; do
		echo "seg$n $(py -c 'import sys,zlib;print("%08x"%(zlib.crc32(open(sys.argv[1],"rb").read())&0xffffffff))' "$B/$f")" >> "$B/EXPECT"; n=$((n + 1))
	done < "$B/SEGS"
	printf 'ENTRY=0x8000\nENTRY8=0x00008000\nR2=0x100\nR1_EXPECT=527\nMARK_TOTAL=3\nMARK_AT="0:%s,1:%s,2:%s"\nMARK_POS="0 1 2"\nKVER=%s\n' ${MARK_A#0x} ${MARK_C#0x} ${MARK_H#0x} $KVER > "$B/CFG"
	printf 'LOG_MIN_KB=%s\nLOG_MAX_KB=%s\nLOG_EXACT_KB=%s\nLOG_TAG=%s\nLOG_SKIP_PORT=%s\nLOG_SKIP_PARTS="%s"\n' $((LOG_SECTORS / 2)) $((LOG_SECTORS / 2)) $((LOG_SECTORS / 2)) ex4-openwrt "$LOG_SKIP_PORT" "$LOG_SKIP_PART" > "$B/LOGCFG"
	{
		echo "EX4 RAM-trial bundle-v7, built $(date '+%Y-%m-%d %H:%M:%S %Z') by build/v7/build-v7.sh, run id $RUN"
		echo "kernel.bin = zImage of OUR OpenWrt $(cat "$O/version" 2>/dev/null || echo 25.12.6) build ($(basename "$IMG"), md5 $(md5sum < "$IMG" | cut -d' ' -f1)) + dts/kirkwood-wd-mycloud-ex4.dts (-DEX4_TRIAL)"
		echo "tree: $OWRT_GIT $OWRT_TAG ($OWRT_COMMIT, $OWRT_REV) + build/v7 (diffconfig, kernel-config.fragment, patches/, files/)"
		echo "ex4-trial.dtb md5 $(md5sum < "$BW/dts/ex4-trial.dtb" | cut -d' ' -f1) · ex4phy md5 $(md5sum < "$BW/ex4phy" | cut -d' ' -f1)"
		echo "$(cat "$BW/size-gate.txt")"
		echo "overlay: key-only ssh, auto-return $RETURN_MIN min (+2 deadman), disk log window $LOG_SECTORS sectors exactly, port kept off: ${LOG_SKIP_PORT:-none}"
	} > "$B/PROVENANCE"
	( cd "$B" && md5sum ex4boot-l2off.ko ex4peek ex4log ex4fan KMODS.txt kernel.bin overlay.cpio atags.bin markA.bin markC.bin markH.bin SEGS EXPECT RUNID CFG LOGCFG PROVENANCE ex4-trial.sh > MD5SUMS )
	cp "$BW/xor-proof.txt" "$BW/size-gate.txt" "$OUT/" 2>/dev/null || true
	say "done: $B ($(ls "$B" | wc -l) files, $(du -sk "$B" | cut -f1) KiB), run id $RUN"
	exit 0
fi
die "first argument: image or bundle"
