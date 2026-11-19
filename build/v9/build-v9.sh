#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# build/v9/build-v9.sh : the EX4 v9 RAM-trial bundle = v8 (below) + the signed update path IN the image + the
# read-write bench in the overlay (inert without its typed per-session token) + the recovery wall in ex4-md-ro.
# Two stages, both reproducible from an empty folder:
#
#   RELVER=V RELSERIAL=N [RELCHANNEL=trial] sh build/v9/build-v9.sh image --work DIR [--netwall SOCK --egress-log LOG]
#                                  [--seed-dl DIR] [--jobs N]
#   [EX4_RWBENCH=1] [EX4_XOR=on|off] [EX4_PROFILE=0|1] [EX4_TWIN=uaccess|diet|ud|nfsdtrack|prof2] [EX4_CMDLINE_ARM=nomemcg]
#        sh build/v9/build-v9.sh bundle --work DIR --pubkey KEY.pub
#                                  --wd-gpl WDMyCloud_EX4_GPL_v2.12.127_20181219.tar.gz [--out DIR] [--no-webui]
#   sh build/v9/build-v9.sh prof-image --from V9WORK --work DIR [--jobs N]          (v9.4: the PROFILE TWIN's image)
#   sh build/v9/build-v9.sh twin-image --twin uaccess|diet|ud|nfsdtrack|prof2|prof --from V9WORK --work DIR [--jobs N]   (v9.7; ud, nfsdtrack v9.8)
#   [EX4_* as bundle] sh build/v9/build-v9.sh variant --run RUNBASE --initrd-size N --out DIR        (v9.7: plan only)
#   sh build/v9/build-v9.sh kernel-kind --config KERNEL.config      (v9.8: prints which kernel a .config is, or refuses)
#
# What v9.8 adds (Nov 18 2026; Kurt 12:45 "Go for whatever makes it awesome", answering the morning report's three calls). The
# defaults build exactly what v9.7 built (no flag = the same bundle files, the same run id form):
#   two kernel twins in the ONE variant scheme (each its own token; build-v9 still refuses two twins at once):
#     ud        = uaccess + diet + nfsdtrack (build/v9/kernel-config.ud.fragment, the union of the three; run 17: uaccess moved
#                 local write / read, diet moved NFS write: different costs). Run id suffix -ud, VARIANT=ud; refused with
#                 nomemcg (no memory controller, as diet).
#     nfsdtrack = the DEFAULT config + CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y (17D: every nfsd start printed "Unable to initialize
#                 client recovery tracking! (-110)"; the kernel option, not the nfsdcld package). Run id suffix -nfsdtrack.
#     kernel_kind reads a sixth mark (CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y), so ud and nfsdtrack are told from diet / default.
#   bundle: THE BUNDLE GATE (the v95 review's must_fix, the gate half): after MD5SUMS the overlay gate runs again with --bundle
#            on the finished bundle (VARIANT == the variant, RUNID suffix == its tokens, the overlay's .ko set == KMODS.txt,
#            a kernel twin's VARIANT carries kernel-config-md5=). A refusal renames the bundle to bundle-v9.REFUSED.
#
# What v9.7 adds (Nov 17-18 2026, FABLE-OPT F3 + F6 + trial 3 "the build night"; Kurt 23:55: "Prolly not jumbo frames. I
# only need NFS."). The defaults build exactly what v9.4 built (no flag = the same bundle files, the same run id form):
#   twin-image (prof-image generalised; prof-image = twin-image --twin prof, unchanged): a KERNEL TWIN = a cp -a of the
#            frozen v9 image tree + build/v9/kernel-config.<twin>.fragment, the kernel and every kernel module rebuilt,
#            offline, the same checks as prof-image + (all twins) THE SECURITY KEEP LIST and THE NAS KEEP LIST read back
#            from the built kernel's .config, THE SIZE ESTIMATE against marker H, and (KSTRICT fragments) a kernel .config
#            that differs from v9's ONLY in symbols the fragment names (OWRT / KCFG / KMAY lines). Receipt TWIN.txt (+
#            PROFILE-TWIN.txt for the profile twins), which records the md5 of the built kernel .config.
#              uaccess = F3: CONFIG_UACCESS_WITH_MEMCPY=y and nothing else. diet = F6 (K2 + K3 + K5): the cgroup pile and
#              the router-only net hooks out, JUMP_LABEL=y, ext4 / jbd2 / mbcache / sata_mv and the NFS server stack built
#              in. prof2 = the hits-only profile twin's lines + FUNCTION_GRAPH_TRACER (the profiler records time per
#              function, not only hits), on the DEFAULT config. Never shipped: prof2 is a profile twin (never ship); uaccess
#              and diet are bench twins until their arms pass.
#   bundle + EX4_TWIN=uaccess|diet|prof2 (EX4_PROFILE=1 is EX4_TWIN=prof): the image tree must BE that twin: its parent
#            holds TWIN.txt naming it with the md5 of the kernel .config the bundle finds, and the kernel .config carries
#            the twin's marks; any other pairing is refused (a twin kernel without its flag, a flag on another kernel).
#            Run id suffix -uaccess / -diet / -prof2 (after -xoroff, before -nomemcg); the VARIANT file says which.
#          + EX4_CMDLINE_ARM=nomemcg (run 15's by-hand arm) is now part of the same scheme: VARIANT=nomemcg (or
#            xoroff+nomemcg, ...), refused on the diet twin (no memory controller to disable)
#          + the overlay gate is told the full variant (xoroff, the kernel twin, nomemcg)
#   variant (new stage, builds nothing): the run id, the VARIANT file and atags.bin a bundle with these EX4_* would get,
#            from the SAME functions the bundle stage calls (tests/build/cmdline-arm-test.sh drives it)
#
# What v9.4 adds (Nov 17 2026, PERF-DESIGN-v2 §3 R1 arm X2 and R2 "v10b-prof"; Kurt 20:19: "The goal is to beat stock at
# everything"). The defaults build exactly what v9.3 built (no flag = the same bundle files, the same run id form):
#   bundle + EX4_XOR=off (default on): build/v9/xor-off.dtsi is appended to the preprocessed trial DTS, so BOTH orion-xor
#            nodes (xor@60800 = dma0, xor@60900 = dma1) are status "disabled" in kernel.bin's DTB; the kernel is the same.
#            The stage also builds the default DTB, decompiles both and REFUSES unless they differ in exactly those two
#            status lines (bundle-work/dts/xor-off.diff). Run id gets the suffix -xoroff; a VARIANT file says XOR=off.
#          + EX4_PROFILE=1: the image tree (DIR/openwrt, usually a symlink) must be a PROFILE TWIN (its kernel .config has
#            CONFIG_FUNCTION_TRACER=y and its tree's parent holds PROFILE-TWIN.txt from prof-image); a profile kernel WITHOUT
#            EX4_PROFILE=1, or EX4_PROFILE=1 on a stock kernel, is refused. Run id suffix -prof; VARIANT says
#            "PROFILE TWIN: never ship"; PROVENANCE says it too. Bench only, never released.
#          + the overlay gate is told the variant (--variant, --kernel-dts): profile kmods (ftrace-instrumented) ride only
#            in a bundle marked PROFILE, and the DTB's xor status must match EX4_XOR
#   prof-image (new stage): cp -a of V9WORK/openwrt (the frozen v9 image tree, never modified: the stage proves it with
#            find -newer afterwards) into DIR/openwrt, build/v9/kernel-config.prof.fragment applied (FTRACE,
#            FUNCTION_TRACER, DYNAMIC_FTRACE, FUNCTION_PROFILER, KALLSYMS; DEBUG_FS checked; nothing else (KALLSYMS_ALL: OpenWrt forces it off): the
#            resolved .config may differ from v9's ONLY in those CONFIG_KERNEL_ lines), the kernel and every kernel package
#            cleaned and rebuilt, the rootfs reinstalled, the SAME rootfs hook, the initramfs kernel. OFFLINE: every
#            proxy points at a closed port and `make download` must pass first (every source already in dl/); no
#            namespace wall (that needs root), so the receipt says RESULT OFFLINE, not WALLED.
#
# What v9 changes against build/v8/build-v8.sh (Kurt, Nov 17 2026 15:13: "Secure, fast, able to be updated to keep
# secure"; the v8 update / bench reviews):
#   image  + THE UPDATE PATH (update/FILES): /usr/sbin/ex4-update, our release key as /etc/ex4-update/keys/<key number>,
#            and /etc/ex4-release (mkrelease.py ident: board, RELVER, RELSERIAL, RELCHANNEL). RELVER + RELSERIAL are
#            required: an image that cannot say who it is cannot judge a downgrade.
#          + NO OFFICIAL PACKAGE FEEDS: the ROOTFS HOOK removes /etc/apk/keys/* (OpenWrt's release key AND the build
#            tree's own key, whose private half sits world-readable in the build tree) and the official feed list
#            (/etc/apk/repositories.d/distfeeds.list). Our kernel cannot take official kmods (its vermagic is ours), so
#            nothing here installs from OpenWrt's feeds: packages come only inside our own signed releases. The stage
#            refuses a rootfs that still carries any apk key or a feed line.
#          + ex4-md-ro from build/v9/files (refuses a member being rebuilt: Feature Map 0x2, a Recovery Offset line,
#            an Array State other than AAAA)
#          = everything else from build/v8/ (diffconfig, kernel-config.fragment, patches/, netwall.py, egress-allow.py)
#   bundle + the image is checked to carry the update path byte for byte (update/box/ex4-update, the key, a serial)
#          + EX4_RWBENCH=1: box/ex4-rwbench.sh rides in as /usr/sbin/ex4-rwbench with the clean stop on every reboot
#            path (build/mkoverlay.py --rwbench); build/v9/overlay-gate.py checks that too (or its absence)
#          + bundle-v9, laid out exactly like bundle-v8
# Below: v8's own header (the stages are otherwise unchanged).
#
# What v8 changes against build/v7/build-v7.sh (each from Kurt's 15:13 answer or a v7 review, Nov 17 2026):
#   image  + px5g-mbedtls (the web interface's certificate maker; v7's image had none, so HTTPS could not start)
#          + smartd out of rc.d, and an /etc/smartd.conf that watches nothing (review nit: a package update must not be
#            able to turn its sample config into DEVICESCAN); smartctl stays for the interface's reads
#          + THE NET WALL (--netwall SOCK): the whole stage runs in a network namespace that has only loopback; the
#            egress proxy runs OUTSIDE and is reached through the unix socket SOCK (netwall.py relay). netwall.py prove
#            writes the receipt (no interface but lo, no name lookup, no direct route, the proxy allows OpenWrt and
#            refuses the rest) and the stage REFUSES to start if any line fails. Without --netwall the stage runs as
#            v7 did (the proxy in the environment only) and its receipt says so.
#          = dnsmasq, firewall4, nftables, odhcpd, uboot-envtools, block-mount stay out (Kurt 15:13: leave them out),
#            and the stage refuses a resolved .config or a rootfs that carries any of them
#   bundle + the web interface (webui/; Kurt 15:13: it rides in this trial: HTTPS 443 on the LAN, claimed by a code
#            read over ssh, no default password); --no-webui leaves it out
#          + THE OVERLAY GATE (build/v8/overlay-gate.py): the bundle stage REFUSES an overlay.cpio without the security
#            fix (root '*', key-only ssh, exactly the given key, the web door in the state its flag asks for), so a
#            stale mkoverlay.py can never ship root:: and an open web server again
#          + ex4fan from userland/ex4fan.c as it stands (the panel lane's daemon, LCD OFF by default, + `ctl send-test`)
#          + bundle-v8, laid out exactly like bundle-v7; the size gate and the loader's chunk count recomputed
# Below: v7's own header (the stages are otherwise unchanged).
#
# image  : OpenWrt 25.12.6 (tag v25.12.6 = r33311-981c978eff) built from source in DIR/openwrt: kirkwood/generic,
#          the kernel config fragment (the SoC's XOR/copy engines: DMADEVICES + MV_XOR + ASYNC_TX_DMA; md + raid1 +
#          raid456 BUILT IN with autodetect OFF; ext4 quotas), the package list of PLAN.md's NAMED LIST, an initramfs
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
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../.." && pwd); H8=$TOP/build/v8
STAGE=${1:-}; [ $# -gt 0 ] && shift
WORK=; SEED=; JOBS=$(nproc 2>/dev/null || echo 2); PUB=; WDGPL=; OUT=; NETWALL=; EGLOG=; WEBUI=1; FROM=; TWARG=; RUNB=; ISZ=; KCONF=
while [ $# -gt 0 ]; do
	case "$1" in
	--config) KCONF=${2:?}; shift 2;;
	--twin) TWARG=${2:?}; shift 2;;
	--run) RUNB=${2:?}; shift 2;;
	--initrd-size) ISZ=${2:?}; shift 2;;
	--work) WORK=${2:?}; shift 2;;
	--seed-dl) SEED=${2:?}; shift 2;;
	--jobs) JOBS=${2:?}; shift 2;;
	--pubkey) PUB=${2:?}; shift 2;;
	--wd-gpl) WDGPL=${2:?}; shift 2;;
	--out) OUT=${2:?}; shift 2;;
	--netwall) NETWALL=${2:?}; shift 2;;
	--egress-log) EGLOG=${2:?}; shift 2;;
	--no-webui) WEBUI=0; shift;;
	--from) FROM=${2:?}; shift 2;;
	*) echo "usage: see the header of $0" >&2; exit 64;;
	esac
done
die() { echo "build-v9: REFUSED: $*" >&2; exit 1; }
say() { echo "build-v9: $(date '+%H:%M:%S') $*"; }
[ -n "$WORK" ] || [ "$STAGE" = variant ] || [ "$STAGE" = kernel-kind ] || die "--work DIR is required"
py() { python3 -I "$@"; }

# ---- the pins (from the release's own buildinfo files, downloads.openwrt.org/releases/25.12.6/targets/kirkwood/generic/) ----
OWRT_GIT=https://git.openwrt.org/openwrt/openwrt.git
OWRT_TAG=v25.12.6
OWRT_TAG_OBJ=22dd0e28678a6cd6fbadea2d5aaded3a805ab8a4      # the signed tag object (tagger Hauke Mehrtens)
OWRT_COMMIT=64900e756efa667774214f9c6b17c113222e01f7       # "OpenWrt v25.12.6: adjust config defaults"
OWRT_REV=r33311-981c978eff                                  # version.buildinfo of the official release
FEED_PACKAGES="src-git packages https://git.openwrt.org/feed/packages.git^093d551675b1119a06ef224d419905e8d6b2af1a"
FEED_PKGS="samba4-server ksmbd-server kmod-fs-ksmbd nfs-kernel-server wsdd2 avahi-nodbus-daemon msmtp smartmontools smartd rsync proto-bonding"
# packages the image must NOT carry (Kurt, Nov 17 2026 15:13: dnsmasq, the firewall, uboot-envtools and block-mount stay out)
NOTPKGS="kmod-md-mod kmod-md-raid456 dnsmasq dnsmasq-full firewall4 firewall nftables odhcpd odhcpd-ipv6only uboot-envtools block-mount luci luci-base"
KVER=6.12.112
PROXY_PORT=${PROXY_PORT:-18443}
# services the ROOTFS HOOK takes out of /etc/rc.d (installed, startable by hand, never at boot)
NOBOOT="mdadm samba4 ksmbd nfsd rpcbind wsdd2 avahi-daemon smartd"
# kernel modules the hook keeps from autoloading (USB disks would shift the sdX names the trial's log gate uses)
NOAUTOLOAD="usb-storage usb-storage-uas"

# ---- the ROOTFS HOOK and the initramfs step, shared by `image` and `prof-image` (v9.4: moved here unchanged) ----
rootfs_hook() {
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
	[ -x "$R/usr/sbin/px5g" ] || die "the rootfs has no /usr/sbin/px5g (the web interface's certificate)"
	grep -v '^#' "$R/etc/smartd.conf" | grep -q . && die "the rootfs's /etc/smartd.conf still names a device (build/v9/files/etc/smartd.conf did not take)"
	# v9: NO OFFICIAL PACKAGE FEEDS (docs/UPDATES.md): no apk signing key, no feed list. Packages come only in our releases.
	for k in "$R"/etc/apk/keys/*; do [ -e "$k" ] || continue; rm -f "$k"; echo "apk: removed the package key etc/apk/keys/${k##*/}" >> "$WORK/rootfs-hook.txt"; done
	if [ -f "$R/etc/apk/repositories.d/distfeeds.list" ]; then rm -f "$R/etc/apk/repositories.d/distfeeds.list"; echo "apk: removed the official feed list etc/apk/repositories.d/distfeeds.list" >> "$WORK/rootfs-hook.txt"; fi
	[ -z "$(ls -A "$R/etc/apk/keys" 2>/dev/null)" ] || die "the rootfs still holds an apk key"
	cat "$R"/etc/apk/repositories "$R"/etc/apk/repositories.d/* 2>/dev/null | grep -v '^[[:space:]]*#' | grep -q . && die "the rootfs still names a package feed"
	cmp -s "$R/usr/sbin/ex4-update" "$TOP/update/box/ex4-update" || die "the rootfs's /usr/sbin/ex4-update is not update/box/ex4-update"
	cmp -s "$R/usr/sbin/ex4-md-ro" "$HERE/files/usr/sbin/ex4-md-ro" || die "the rootfs's /usr/sbin/ex4-md-ro is not build/v9/files' (the recovery wall)"
	grep -q '^serial=[1-9][0-9]*$' "$R/etc/ex4-release" || die "the rootfs has no /etc/ex4-release with a serial"
	for p in $NOTPKGS; do [ -e "$R/lib/apk/packages/$p.list" ] && die "the rootfs carries $p"; done
	echo "smartd.conf: $(grep -c . "$R/etc/smartd.conf") lines, none names a device; px5g md5 $(md5sum < "$R/usr/sbin/px5g" | cut -d' ' -f1)" >> "$WORK/rootfs-hook.txt"
	ls "$R"/etc/rc.d > "$WORK/rc.d-after-hook.txt"
	for s in $NOBOOT; do grep -q "^[SK][0-9][0-9]$s\$" "$WORK/rc.d-after-hook.txt" && die "$s is still in rc.d"; done
	ls -A "$R/etc/apk/keys" "$R/etc/apk/repositories.d" > "$WORK/apk-after-hook.txt" 2>&1

}
initramfs_and_checks() {
	make -j"$JOBS" target/install > "$WORK/make-2.log" 2>&1 || { tail -40 "$WORK/make-2.log" >&2; die "target/install"; }
	IMG=$(ls "$O"/bin/targets/kirkwood/generic/*iom_ix4-200d-initramfs-uImage)
	[ -s "$IMG" ] || die "no initramfs image came out"
	grep -q "^CONFIG_MV_XOR=y" "$O"/build_dir/target-*/linux-kirkwood_generic/linux-$KVER/.config || die "the built kernel's .config has no CONFIG_MV_XOR=y"
	grep -q "^# CONFIG_MD_AUTODETECT is not set" "$O"/build_dir/target-*/linux-kirkwood_generic/linux-$KVER/.config || die "the built kernel can autodetect md arrays"
	# v9: the hook's removals must be in what target/install packed, not only in the folder (it rebuilds nothing, but check)
	[ -z "$(ls -A "$R/etc/apk/keys" 2>/dev/null)" ] && [ ! -e "$R/etc/apk/repositories.d/distfeeds.list" ] || die "an apk key or the feed list came back during target/install"
	CPIO=$(ls "$O"/build_dir/target-*/linux-kirkwood_generic/linux-$KVER/usr/initramfs_data.cpio 2>/dev/null | head -n 1 || true)
	[ -n "$CPIO" ] || die "no usr/initramfs_data.cpio in the kernel tree: cannot prove what the initramfs carries"
	for dec in cat "xz -dc" "zstd -dc" "gzip -dc"; do
		$dec < "$CPIO" 2>/dev/null | cpio -t --quiet 2>/dev/null > "$WORK/initramfs-list.txt" || true
		[ -s "$WORK/initramfs-list.txt" ] && break
	done
	[ -s "$WORK/initramfs-list.txt" ] || die "cannot list $CPIO"
	grep -qE '^\.?/?etc/apk/keys/.' "$WORK/initramfs-list.txt" && die "the initramfs ($CPIO) still carries an apk key"
	grep -qE '^\.?/?etc/apk/repositories.d/distfeeds.list$' "$WORK/initramfs-list.txt" && die "the initramfs still carries the official feed list"
	grep -qE '^\.?/?usr/sbin/ex4-update$' "$WORK/initramfs-list.txt" || die "the initramfs has no usr/sbin/ex4-update"
	grep -qE '^\.?/?etc/ex4-release$' "$WORK/initramfs-list.txt" || die "the initramfs has no etc/ex4-release"
	echo "initramfs ($CPIO, listed with $dec): $(wc -l < "$WORK/initramfs-list.txt") entries; no apk key, no feed list; ex4-update + /etc/ex4-release present" >> "$WORK/rootfs-hook.txt"
}

# ---- v9.7: THE VARIANT SCHEME, shared by `bundle` and `variant` (one place decides run id, VARIANT and command line) ----
# Tokens, in this order: xoroff (EX4_XOR=off) · one kernel twin (prof = EX4_PROFILE=1, prof2 / uaccess / diet = EX4_TWIN) ·
# nomemcg (EX4_CMDLINE_ARM). Run id suffix = "-" + each token; VARIANT = the tokens joined with "+", or "stock" for none.
variant_resolve() {
	XOR=${EX4_XOR:-on}; case "$XOR" in on|off) ;; *) die "EX4_XOR must be on or off";; esac
	PROF=${EX4_PROFILE:-0}; case "$PROF" in 0|1) ;; *) die "EX4_PROFILE must be 0 or 1";; esac
	TWIN=${EX4_TWIN:-}; case "$TWIN" in ''|uaccess|diet|ud|nfsdtrack|prof2|prof) ;; *) die "EX4_TWIN: only uaccess, diet, ud, nfsdtrack, prof2 or prof (or unset)";; esac
	if [ "$PROF" = 1 ]; then
		[ -z "$TWIN" ] || [ "$TWIN" = prof ] || die "EX4_PROFILE=1 is the hits-only profile twin (EX4_TWIN=prof); it cannot go with EX4_TWIN=$TWIN"
		TWIN=prof
	fi
	[ "$TWIN" = prof ] && PROF=1
	PROFILE=0; case "$TWIN" in prof|prof2) PROFILE=1;; esac
	CARM=${EX4_CMDLINE_ARM:-}; ARGX=
	case "$CARM" in '') ;; nomemcg) ARGX=" cgroup_disable=memory";; *) die "EX4_CMDLINE_ARM: only nomemcg (or unset)";; esac
	case "$CARM:$TWIN" in nomemcg:diet|nomemcg:ud) die "EX4_CMDLINE_ARM=nomemcg with EX4_TWIN=$TWIN: the $TWIN kernel has no memory controller to disable (the arm would measure nothing)";; esac
	VSUF=; VT=
	[ "$XOR" = off ] && { VSUF="$VSUF-xoroff"; VT=xoroff; }
	[ -n "$TWIN" ] && { VSUF="$VSUF-$TWIN"; VT="${VT:+$VT+}$TWIN"; }
	[ -n "$CARM" ] && { VSUF="$VSUF-$CARM"; VT="${VT:+$VT+}$CARM"; }
	VARIANT=${VT:-stock}
	return 0
}
# the VARIANT file's text (bundle: PTW / TWF are the twin's receipts; variant stage: unset, so "plan only")
variant_text() {
	echo "VARIANT=$VARIANT"; echo "XOR=$XOR"
	[ "$XOR" = off ] && echo "XOR=off: both orion-xor nodes (xor@60800, xor@60900) status disabled in kernel.bin's DTB (build/v9/xor-off.dtsi md5 $(md5sum < "$HERE/xor-off.dtsi" | cut -d' ' -f1)); the kernel still has CONFIG_MV_XOR=y; async_tx uses the CPU xor"
	[ -n "$CARM" ] && echo "CMDLINE_ARM=$CARM: the kernel command line adds$ARGX (bench arm; kernel, DTB, kmods unchanged)"
	if [ "$TWIN" = prof ]; then
		echo "PROFILE TWIN: never ship"
		echo "PROFILE=1: kernel with FTRACE / FUNCTION_TRACER / DYNAMIC_FTRACE / FUNCTION_PROFILER / KALLSYMS ($([ -n "${PTW:-}" ] && sed -n 2p "$PTW" || echo 'plan only: no image tree'))"
	elif [ "$TWIN" = prof2 ]; then
		echo "PROFILE TWIN: never ship"
		echo "TWIN=prof2: kernel with FTRACE / FUNCTION_TRACER / FUNCTION_GRAPH_TRACER / DYNAMIC_FTRACE / FUNCTION_PROFILER / KALLSYMS: the profiler records time per function ($([ -n "${TWF:-}" ] && sed -n 2p "$TWF" || echo 'plan only: no image tree'))"
	elif [ -n "$TWIN" ]; then
		echo "TWIN=$TWIN: bench kernel twin (build/v9/kernel-config.$TWIN.fragment md5 $(md5sum < "$HERE/kernel-config.$TWIN.fragment" | cut -d' ' -f1)); never a release until its arm passes ($([ -n "${TWF:-}" ] && sed -n 2p "$TWF" || echo 'plan only: no image tree'))"
	fi
	[ -n "${TWF:-}" ] && grep '^kernel-config-md5=' "$TWF"
	return 0
}
cmdline_of() { printf '%s\n' "console=ttyS0,115200n8 watchdog.open_timeout=120 ex4boot_run=$1$ARGX"; }
# which kernel is this? From its .config: default, prof, prof2, uaccess, diet, ud or nfsdtrack; anything else is refused
# (v9.8: a sixth mark, NFSD_LEGACY_CLIENT_TRACKING=y; ud = uaccess + diet + that mark, nfsdtrack = that mark alone)
kernel_kind() {
	kc=$1; m=
	for l in 'CONFIG_FUNCTION_TRACER=y' 'CONFIG_FUNCTION_GRAPH_TRACER=y' 'CONFIG_UACCESS_WITH_MEMCPY=y' 'CONFIG_JUMP_LABEL=y' '# CONFIG_MEMCG is not set' 'CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y'; do
		if grep -qx "$l" "$kc"; then m="${m}1"; else m="${m}0"; fi
	done
	case "$m" in
	000000) KK=default;; 100000) KK=prof;; 110000) KK=prof2;; 001000) KK=uaccess;; 000110) KK=diet;; 001111) KK=ud;; 000001) KK=nfsdtrack;;
	*) die "this image's kernel is no kernel this script knows (FUNCTION_TRACER, FUNCTION_GRAPH_TRACER, UACCESS_WITH_MEMCPY, JUMP_LABEL, no MEMCG, NFSD_LEGACY_CLIENT_TRACKING = $m in $kc)";;
	esac
}
# THE SECURITY KEEP LIST (FABLE-LANE-kernel.md §4.1: no hardening option is dropped to win cycles) and THE NAS KEEP LIST
# (the md / raid5 / XOR engine stack; the NFS server: nfsd, NFSv4 (4.2 rides in NFSD_V4 on 6.12), lockd, sunrpc, exportfs).
# Every twin's built kernel must still say each line (y for the security list; y or m for the module half of the NAS list).
SECKEEP="CONFIG_STACKPROTECTOR=y CONFIG_HARDENED_USERCOPY=y CONFIG_FORTIFY_SOURCE=y CONFIG_SLAB_FREELIST_HARDENED=y CONFIG_SLAB_FREELIST_RANDOM=y
CONFIG_LIST_HARDENED=y CONFIG_STRICT_KERNEL_RWX=y CONFIG_STRICT_MODULE_RWX=y CONFIG_SECCOMP=y CONFIG_SECCOMP_FILTER=y CONFIG_NAMESPACES=y
CONFIG_UTS_NS=y CONFIG_IPC_NS=y CONFIG_USER_NS=y CONFIG_PID_NS=y CONFIG_NET_NS=y CONFIG_PANIC_ON_OOPS=y CONFIG_SCHED_STACK_END_CHECK=y
CONFIG_SECURITY_DMESG_RESTRICT=y CONFIG_BPF_UNPRIV_DEFAULT_OFF=y CONFIG_CGROUPS=y CONFIG_CGROUP_PIDS=y"
NASKEEP_Y="CONFIG_BLK_DEV_MD=y CONFIG_MD_RAID456=y CONFIG_MV_XOR=y CONFIG_ASYNC_TX_DMA=y CONFIG_DMADEVICES=y CONFIG_NFSD_V4=y CONFIG_QUOTA=y"
NASKEEP_YM="CONFIG_NFSD CONFIG_LOCKD CONFIG_SUNRPC CONFIG_EXPORTFS CONFIG_GRACE_PERIOD CONFIG_EXT4_FS CONFIG_JBD2 CONFIG_SATA_MV"

if [ "$STAGE" = image ]; then
	for t in git make gcc g++ gawk flex bison python3 perl curl rsync unzip file swig patch; do
		command -v "$t" >/dev/null || die "$t not found"
	done
	mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd); O="$WORK/openwrt"
	[ -e "$O" ] && die "$O exists (this stage starts from an empty folder)"
	RELVER=${RELVER:-}; RELSERIAL=${RELSERIAL:-}; RELCHANNEL=${RELCHANNEL:-trial}
	[ -n "$RELVER" ] && [ -n "$RELSERIAL" ] || die "RELVER=<version label> RELSERIAL=<serial> are required: the image says who it is in /etc/ex4-release (update/mkrelease.py)"
	py "$TOP/update/usignpy.py" fingerprint "$TOP/update/keys/ex4-release.pub" > /dev/null || die "update/keys/ex4-release.pub is not a usign public key"
	if [ -n "$NETWALL" ]; then
		# THE NET WALL: the proxy runs OUTSIDE this namespace (its log: --egress-log); the relay is our only way out
		[ -S "$NETWALL" ] || die "--netwall $NETWALL is not a socket (start egress-allow.py --unix $NETWALL outside first)"
		[ -n "$EGLOG" ] && [ -f "$EGLOG" ] || die "--netwall needs --egress-log, the outside proxy's log file"
		PLOG=$EGLOG
		py "$H8/netwall.py" relay "$PROXY_PORT" "$NETWALL" &
		PXPID=$!; trap 'kill $PXPID 2>/dev/null || true' EXIT INT TERM
		sleep 1; kill -0 $PXPID 2>/dev/null || die "the net-wall relay did not start (port $PROXY_PORT busy?)"
		py "$H8/netwall.py" prove "$PROXY_PORT" "$WORK/netwall-proof.txt" || { cat "$WORK/netwall-proof.txt" >&2; die "THE NET WALL does not hold here: this namespace can reach the network without the proxy"; }
		say "the net wall holds (receipt $WORK/netwall-proof.txt): only loopback, no name lookup, no direct route; the proxy outside allows OpenWrt and refuses the rest"
	else
		PLOG="$WORK/egress.log"
		py "$H8/egress-allow.py" --port "$PROXY_PORT" --log "$PLOG" &
		PXPID=$!; trap 'kill $PXPID 2>/dev/null || true' EXIT INT TERM
		sleep 1; kill -0 $PXPID 2>/dev/null || die "the egress proxy did not start (port $PROXY_PORT busy?)"
		echo "RESULT NO NET WALL: the egress proxy was set in the environment only (a tool that ignored it would have left no line)" > "$WORK/netwall-proof.txt"
	fi
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
	sed -i -f "$H8/patches/mdadm-no-md-kmods.sed" package/utils/mdadm/Makefile
	[ "$(diff "$WORK/mdadm.Makefile.orig" package/utils/mdadm/Makefile | grep -c '^[<>]')" = 2 ] || die "the mdadm sed did not change exactly one line"
	T=target/linux/kirkwood/config-6.12
	for s in $(grep -oE '^(# )?CONFIG_[A-Z0-9_]+' "$H8/kernel-config.fragment" | sed 's/^# //'); do
		sed -i -E "/^(# )?$s(=| is not set)/d" "$T"
	done
	grep -E '^CONFIG_[A-Z0-9_]+=|^# CONFIG_[A-Z0-9_]+ is not set' "$H8/kernel-config.fragment" >> "$T"
	git diff --stat > "$WORK/tree-changes.txt"; git diff > "$WORK/tree-changes.diff"
	mkdir -p files; cp -R "$HERE/files/." files/
	# THE UPDATE PATH (update/FILES): ex4-update, our release key under its usign key number, /etc/ex4-release
	UP="$TOP/update"; FP=$(py "$UP/usignpy.py" fingerprint "$UP/keys/ex4-release.pub") || die "update/keys/ex4-release.pub"
	grep -v '^#' "$UP/FILES" | grep . > "$WORK/update-files.txt"
	while IFS="$(printf '\t')" read -r src dst mode; do
		dst=$(echo "$dst" | sed "s/@FINGERPRINT@/$FP/")
		mkdir -p "files$(dirname "$dst")" && cp "$UP/$src" "files$dst" && chmod "$mode" "files$dst" || die "update/FILES: $src"
	done < "$WORK/update-files.txt"
	py "$UP/mkrelease.py" ident --version "$RELVER" --serial "$RELSERIAL" --openwrt "${OWRT_TAG#v}" --kernel "$KVER" \
		--channel "$RELCHANNEL" --out files/etc/ex4-release || die "mkrelease ident"
	find files -type f | sort > "$WORK/files-list.txt"

	say "4/7 .config from build/v8/diffconfig"
	cp "$H8/diffconfig" .config
	make defconfig > "$WORK/defconfig.log" 2>&1 || die "make defconfig"
	for p in mdadm e2fsprogs smartmontools smartd samba4-server ksmbd-server kmod-fs-ksmbd nfs-kernel-server kmod-fs-nfsd \
		wsdd2 avahi-nodbus-daemon msmtp kmod-bonding proto-bonding rsync kmod-usb-storage kmod-usb-storage-uas kmod-fs-vfat \
		kmod-fs-exfat rpcd rpcd-mod-ucode uhttpd kmod-usb3 kmod-ata-marvell-sata kmod-fs-ext4 \
		uhttpd-mod-ubus libustream-mbedtls px5g-mbedtls ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus ucode-mod-uloop; do
		grep -qx "CONFIG_PACKAGE_$p=y" .config || die "the resolved .config lacks $p"
	done
	for p in $NOTPKGS; do
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

	rootfs_hook
	say "7/7 the initramfs kernel"
	initramfs_and_checks
	REFUSED=$(grep -c ' REFUSE ' "$PLOG" || true)
	say "done: $IMG ($(stat -c %s "$IMG") bytes); the proxy refused $REFUSED connection attempt(s), allowed $(grep -c ' ALLOW ' "$PLOG" || true) (log: $PLOG)"
	exit 0
fi

if [ "$STAGE" = prof-image ] || [ "$STAGE" = twin-image ]; then
	# THE KERNEL TWINS (v9.4's PROFILE TWIN generalised in v9.7): the v9 image tree + build/v9/kernel-config.<twin>.fragment.
	# prof / prof2 = profile twins (NEVER shipped, bench only); uaccess / diet = bench twins (FABLE-OPT F3 / F6), never a
	# release until their arms pass. prof-image is twin-image --twin prof.
	if [ "$STAGE" = prof-image ]; then
		[ -z "$TWARG" ] || [ "$TWARG" = prof ] || die "prof-image is twin-image --twin prof (got --twin $TWARG)"
		TWARG=prof
	fi
	case "$TWARG" in uaccess|diet|ud|nfsdtrack|prof2|prof) ;; *) die "--twin uaccess|diet|ud|nfsdtrack|prof2|prof is required";; esac
	TW=$TWARG; case "$TW" in prof|prof2) PROFT=1;; *) PROFT=0;; esac
	[ -n "$FROM" ] || die "--from V9WORK (the work folder of the v9 image stage: V9WORK/openwrt) is required"
	FROM=$(cd "$FROM" && pwd -P); SRC="$FROM/openwrt"
	[ -d "$SRC/build_dir" ] && [ -f "$SRC/.config" ] || die "$SRC is not a built image tree"
	FRAG="$HERE/kernel-config.$TW.fragment"; [ -s "$FRAG" ] || die "no $FRAG"
	grep -vE '^(#|$)' "$FRAG" | grep -vE '^(OWRT|KCFG|OMAY|KMAY|KWANT) [^ ]|^KSTRICT yes$' | grep -q . && die "$FRAG has a line that is none of OWRT / KCFG / OMAY / KMAY / KWANT / KSTRICT yes"
	mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd -P); O="$WORK/openwrt"
	[ -e "$O" ] && die "$O exists (this stage starts from a fresh copy)"
	case "$WORK/" in "$SRC/"*) die "--work must not be inside the source tree";; esac
	T0=$(date +%s); : > "$WORK/prof-start.stamp"; sleep 1
	# OFFLINE: no proxy that works, no mirror. A tool that tried the network would fail, and its failure is in a log.
	P=http://127.0.0.1:9
	export https_proxy=$P http_proxy=$P HTTPS_PROXY=$P HTTP_PROXY=$P DOWNLOAD_MIRROR=
	unset no_proxy NO_PROXY || true

	say "1/6 [$TW] cp -a $SRC -> $O (the source is never written)"
	cp -a "$SRC" "$O"
	# absolute symlinks into the source tree would make the copy build INTO the source: repoint them at the copy
	find "$O" -type l -lname "$SRC/*" > "$WORK/abs-links.txt"
	while read -r l; do t=$(readlink "$l"); ln -sfn "$O${t#"$SRC"}" "$l"; done < "$WORK/abs-links.txt"
	[ -z "$(find "$O" -type l -lname "$SRC/*" | head -n 1)" ] || die "a symlink still points into $SRC"
	say "   $(wc -l < "$WORK/abs-links.txt") absolute symlink(s) into the source repointed at the copy ($WORK/abs-links.txt)"
	# text files in staging_dir that name the source tree (libtool .la, .pc, fakeroot / quilt / autotools scripts): the copy's own
	grep -rlIF "$SRC" "$O"/staging_dir > "$WORK/abs-text.txt" 2>/dev/null || true
	while read -r f; do sed -i "s#$SRC#$O#g" "$f"; done < "$WORK/abs-text.txt"
	[ -z "$(grep -rlIF "$SRC/" "$O"/staging_dir 2>/dev/null | head -n 1)" ] || die "a staging_dir text file still names $SRC"
	say "   $(wc -l < "$WORK/abs-text.txt") staging_dir text file(s) naming the source rewritten to the copy ($WORK/abs-text.txt)"
	cd "$O"

	say "2/6 the $TW config: build/v9/kernel-config.$TW.fragment"
	cp .config "$WORK/config.v9"; KT=target/linux/kirkwood/config-6.12; cp "$KT" "$WORK/kconfig-target.v9"
	L=$(ls -d "$O"/build_dir/target-*/linux-kirkwood_generic/linux-$KVER); cp "$L/.config" "$WORK/kernel-config.v9"
	cp "$L/System.map" "$WORK/System.map.v9"
	grep -E '^(OWRT|KCFG) ' "$FRAG" > "$WORK/twin-lines.txt"
	# a line is "CONFIG_X=v" or "# CONFIG_X is not set"; whatever the file said about CONFIG_X before is removed first
	while read -r kind line; do
		sym=$(printf '%s\n' "$line" | sed -E 's/^# //; s/[= ].*//')
		case "$kind" in OWRT) f=.config;; KCFG) f=$KT;; esac
		sed -i -E "/^(# )?$sym(=| is not set)/d" "$f"; echo "$line" >> "$f"
	done < "$WORK/twin-lines.txt"
	make defconfig > "$WORK/defconfig.log" 2>&1 || die "make defconfig"
	grep '^OWRT ' "$WORK/twin-lines.txt" | sed 's/^OWRT //' > "$WORK/owrt-lines.txt"
	while read -r line; do grep -qxF "$line" .config || echo "$line"; done < "$WORK/owrt-lines.txt" > "$WORK/twin-missing.txt"
	[ ! -s "$WORK/twin-missing.txt" ] || die "the resolved .config dropped $(tr '\n' ' ' < "$WORK/twin-missing.txt")(a dependency the ARMv5 build lacks?)"
	[ "$PROFT" = 0 ] || grep -qx 'CONFIG_KERNEL_DEBUG_FS=y' .config || die "CONFIG_KERNEL_DEBUG_FS is not y (the profiler's files live in debugfs)"
	diff "$WORK/config.v9" .config > "$WORK/config.diff" || true
	# NOTHING ELSE: every line the resolved .config SETS or DROPS against v9's is one the fragment names (OWRT) or allows to
	# follow (OMAY: an option whose parent the fragment turned off); the only other change allowed is a NEW "is not set" line
	{ grep -E '^< ' "$WORK/config.diff"; grep -E '^> CONFIG_' "$WORK/config.diff"; } | sed -E 's/^[<>] //; s/^# //; s/[= ].*//' | sort -u > "$WORK/config.diff.syms"
	{ sed -E 's/^# //; s/[= ].*//' "$WORK/owrt-lines.txt"; grep '^OMAY ' "$FRAG" | awk '{print $2}'; } | sort -u > "$WORK/twin-syms"
	[ -z "$(comm -23 "$WORK/config.diff.syms" "$WORK/twin-syms")" ] || die "the resolved .config changed more than the fragment: $(comm -23 "$WORK/config.diff.syms" "$WORK/twin-syms" | tr '\n' ' ')"
	grep -E '^> ' "$WORK/config.diff" | grep -vE '^> CONFIG_' | grep -vE '^> # CONFIG_[A-Z0-9_]+ is not set$' | grep -q . && die "the resolved .config gained a line that is neither the fragment's nor an option left off: $WORK/config.diff"
	./scripts/diffconfig.sh > "$WORK/diffconfig.$TW"
	diff "$WORK/kconfig-target.v9" "$KT" > "$WORK/kconfig-target.diff" || true
	grep -q '=m$' .config && die "the resolved .config builds packages that go into no image"

	say "3/6 make download, offline: every source must already be in dl/ (a fetch would fail on the closed proxy)"
	make -j1 download > "$WORK/download.log" 2>&1 || { tail -30 "$WORK/download.log" >&2; die "make download needs a source not in dl/ (NO DOWNLOADS: stop, report)"; }

	say "4/6 clean the kernel and every kernel package (their vermagic hash follows the kernel config)"
	make target/linux/clean package/kernel/linux/clean > "$WORK/clean.log" 2>&1 || { tail -20 "$WORK/clean.log" >&2; die "clean"; }
	find bin/targets/kirkwood/generic/packages -name 'kmod-*' -type f > "$WORK/stale-kmod-files.txt" 2>/dev/null || true
	xargs -r rm -f < "$WORK/stale-kmod-files.txt"     # stale v9 kmod packages in OUR copy: package/install must not pick one

	say "5/6 compile: the kernel, the kernel packages, the rootfs (make -j$JOBS)"
	make -j"$JOBS" target/compile package/compile package/install > "$WORK/make-1.log" 2>&1 || {
		tail -40 "$WORK/make-1.log" >&2; die "compile (log: $WORK/make-1.log)"; }
	rootfs_hook

	say "6/6 the initramfs kernel"
	initramfs_and_checks
	L=$(ls -d "$O"/build_dir/target-*/linux-kirkwood_generic/linux-$KVER); KC="$L/.config"
	DYN=n/a
	if [ "$PROFT" = 1 ]; then
		for c in CONFIG_FTRACE=y CONFIG_FUNCTION_TRACER=y CONFIG_FUNCTION_PROFILER=y CONFIG_KALLSYMS=y CONFIG_DEBUG_FS=y; do
			grep -qx "$c" "$KC" || die "the built kernel's .config lacks $c"
		done
		grep -qx 'CONFIG_DYNAMIC_FTRACE=y' "$KC" && DYN=yes || DYN="NO (the ARMv5 build did not take it)"
		grep -qx '# CONFIG_PERF_EVENTS is not set' "$KC" || die "the profile kernel must not carry PERF_EVENTS (nothing else)"
		grep -q ' ftrace_profile_' "$L/System.map" && grep -q ' function_trace_call$' "$L/System.map" || die "System.map has no function profiler / tracer symbols"
		if [ "$TW" = prof2 ]; then
			grep -q ' ftrace_graph_caller$' "$L/System.map" && grep -q ' profile_graph_return$' "$L/System.map" || die "System.map has no graph tracer / timed profiler symbols (ftrace_graph_caller, profile_graph_return)"
		fi
	fi
	grep '^KWANT ' "$FRAG" | sed 's/^KWANT //' > "$WORK/kwant-lines.txt"
	while read -r line; do grep -qxF "$line" "$KC" || echo "$line"; done < "$WORK/kwant-lines.txt" > "$WORK/kwant-missing.txt"
	[ ! -s "$WORK/kwant-missing.txt" ] || die "the built kernel's .config lacks $(tr '\n' ' ' < "$WORK/kwant-missing.txt")"
	kernel_kind "$KC"; [ "$KK" = "$TW" ] || die "the built kernel reads as the '$KK' kernel, not '$TW'"
	# THE SECURITY KEEP LIST + THE NAS KEEP LIST (above): read back from the built kernel, not assumed from the fragment
	: > "$WORK/keep-lists.txt"
	for c in $SECKEEP $NASKEEP_Y; do grep -qx "$c" "$KC" || die "the built kernel lost $c (a keep-list line)"; echo "keep $c" >> "$WORK/keep-lists.txt"; done
	for s in $NASKEEP_YM; do v=$(grep -E "^$s=(y|m)$" "$KC") || die "the built kernel has no $s (y or m): the NAS needs it"; echo "keep $v" >> "$WORK/keep-lists.txt"; done
	diff "$WORK/kernel-config.v9" "$KC" > "$WORK/kernel-config.diff" || true
	# CONFIG_INITRAMFS_SOURCE names the tree's own build_dir: it must be v9's value with the source path swapped for the
	# copy's, and is then not a config change (checked here, left out of the symbol list)
	[ "$(grep '^CONFIG_INITRAMFS_SOURCE=' "$WORK/kernel-config.v9" | sed "s#$SRC#$O#g")" = "$(grep '^CONFIG_INITRAMFS_SOURCE=' "$KC")" ] || die "CONFIG_INITRAMFS_SOURCE differs from v9's by more than the tree's path"
	grep -E '^[<>] ' "$WORK/kernel-config.diff" | sed -E 's/^[<>] //' | grep -E '^(# )?CONFIG_[A-Z0-9_]+( is not set$|=)' | sed -E 's/^# //; s/[= ].*//' | grep -vx CONFIG_INITRAMFS_SOURCE | sort -u > "$WORK/kernel-config.diff.syms"
	if grep -qx 'KSTRICT yes' "$FRAG"; then
		# KSTRICT: the built kernel .config differs from v9's only in symbols the fragment sets (KCFG, OWRT as CONFIG_X) or
		# names as a consequence (KMAY: what Kconfig's select / depends moves with them). Menu comment lines are ignored.
		{ grep -E '^(OWRT|KCFG) ' "$FRAG" | sed -E 's/^(OWRT|KCFG) //; s/^# //; s/[= ].*//; s/^CONFIG_KERNEL_/CONFIG_/'; grep '^KMAY ' "$FRAG" | awk '{print $2}'; } | sort -u > "$WORK/kernel-allowed-syms"
		[ -z "$(comm -23 "$WORK/kernel-config.diff.syms" "$WORK/kernel-allowed-syms")" ] || die "KSTRICT: the built kernel .config changed symbols the fragment does not name: $(comm -23 "$WORK/kernel-config.diff.syms" "$WORK/kernel-allowed-syms" | tr '\n' ' ')"
	fi
	R=$(ls -d "$O"/build_dir/target-*/root-kirkwood)
	# the NAS's modules: each one either a module in the rootfs or built in (modules.builtin)
	for k in fs/nfsd/nfsd.ko net/sunrpc/sunrpc.ko fs/lockd/lockd.ko fs/ext4/ext4.ko fs/jbd2/jbd2.ko drivers/ata/sata_mv.ko; do
		b=${k##*/}
		if [ -e "$R/lib/modules/$KVER/$b" ]; then echo "module $b" >> "$WORK/keep-lists.txt"
		elif grep -qx "kernel/$k" "$L/modules.builtin"; then echo "built-in $b" >> "$WORK/keep-lists.txt"
		else die "$b is neither in the rootfs nor built in"; fi
	done
	# every kernel module REBUILT, proven from THIS build, not from bytes: each rootfs .ko must be byte-equal to its kmod
	# package's freshly built (stripped) copy, packages/ipkg-*/kmod-*/lib/modules/KVER/, and that copy newer than the start
	# stamp (the rootfs copy carries the release's normalised mtime, so its own mtime proves nothing). Byte-equality to v9's
	# module is then only recorded: a config line that never reaches module code (uaccess: copy_to_user is out of line in
	# the kernel) leaves a deterministic rebuild byte-equal; prof (struct module) and diet (JUMP_LABEL) change every one.
	# profile twins: the overlay's xhci three ftrace-instrumented (lib/ code is built without -pg upstream: asn1_decoder,
	# oid_registry and the data-only nls_ucs2_utils legitimately carry no mcount call); other twins: none
	: > "$WORK/kmods-mcount.txt"; n=0; same=0; inst=0
	SR=$(ls -d "$SRC"/build_dir/target-*/root-kirkwood); PK=$(cd "$L/.." && pwd)/packages
	for k in $(find "$R/lib/modules/$KVER" -name '*.ko' | sort); do
		n=$((n + 1)); b=${k##*/}
		f=$(find "$PK"/ipkg-* -path "*/lib/modules/$KVER/$b" -type f 2>/dev/null)
		[ "$(printf '%s\n' "$f" | grep -c .)" = 1 ] || die "rootfs $b: not exactly one built copy under $PK/ipkg-* ($f)"
		cmp -s "$k" "$f" || die "rootfs $b is not this build's packaged copy ($f)"
		[ -n "$(find "$f" -newer "$WORK/prof-start.stamp")" ] || die "rootfs $b: its packaged copy ($f) is older than this stage (not rebuilt)"
		echo "rebuilt $b <- ${f#"$PK"/}" >> "$WORK/kmods-mcount.txt"
		cmp -s "$k" "$SR/lib/modules/$KVER/$b" && { same=$((same + 1)); echo "byte-equal-to-v9 $b" >> "$WORK/kmods-mcount.txt"; }
		if grep -q __gnu_mcount_nc "$k"; then inst=$((inst + 1)); echo "instrumented $b" >> "$WORK/kmods-mcount.txt"; else echo "no-mcount $b" >> "$WORK/kmods-mcount.txt"; fi
	done
	[ "$n" -gt 0 ] || die "no kernel module in the rootfs"
	if [ "$PROFT" = 1 ]; then
		for m in xhci-hcd xhci-pci xhci-plat-hcd; do grep -qx "instrumented $m.ko" "$WORK/kmods-mcount.txt" || die "no instrumented $m.ko (the overlay's kmods)"; done
	else
		[ "$inst" = 0 ] || die "$inst kernel module(s) of a non-profile twin are ftrace-instrumented: $WORK/kmods-mcount.txt"
	fi
	# THE SIZE ESTIMATE (the bundle's size gate is the authority; this refuses a twin that cannot pass it): decompressed
	# image + the uImage (+64 KiB for the trial DTB the bundle appends) + the decompressor's slack, from 0x8000, below marker H
	SZE=$(py - "$L/System.map" "$IMG" <<'PY'
import os, sys
m = {}
for l in open(sys.argv[1]):
    f = l.split()
    if len(f) == 3:
        m[f[2]] = int(f[0], 16)
image = m['_end'] - m['_text']
u = os.path.getsize(sys.argv[2])
peak = 0x8000 + image + u + 0x10000 + 0x10000 + 0x20000 + 0x10000
print(f"decompressed image {image} B, uImage {u} B (+64 KiB for the DTB), worst-case peak 0x{peak:x}, marker H 0x3000000, overlay 0x4000000, margin {0x3000000 - peak} B")
sys.exit(0 if peak < 0x3000000 else 1)
PY
) || die "THE SIZE ESTIMATE: the $TW kernel does not fit below RAM marker H: $SZE"
	# NO DOWNLOADS: no log may show a fetch; THE SOURCE: nothing in it changed
	cat "$WORK"/download.log "$WORK"/make-1.log "$WORK"/make-2.log | grep -nE 'Downloading|Cloning into|download\.pl|wget |curl: |Connection refused' > "$WORK/fetch-lines.txt" || true
	[ ! -s "$WORK/fetch-lines.txt" ] || die "a log shows a fetch attempt: $WORK/fetch-lines.txt"
	find "$SRC" -newer "$WORK/prof-start.stamp" > "$WORK/source-changed.txt" 2>&1 || true
	[ ! -s "$WORK/source-changed.txt" ] || die "THE SOURCE TREE CHANGED during this stage: $WORK/source-changed.txt"
	IMGV9=$(ls "$SRC"/bin/targets/kirkwood/generic/*iom_ix4-200d-initramfs-uImage)
	{
		echo "RESULT OFFLINE: $STAGE ran with every proxy at a closed port (127.0.0.1:9) and no mirror; make download passed (every source in dl/); no log line shows a fetch; no network-namespace wall (that needs root)"
	} > "$WORK/netwall-proof.txt"
	SECS=$(( $(date +%s) - T0 )); FMD5=$(md5sum < "$FRAG" | cut -d' ' -f1)
	SIZES="initramfs uImage: $(stat -c %s "$IMG") B (v9: $(stat -c %s "$IMGV9") B); System.map _end-_text: $(py -c 'import sys; m={l.split()[2]: int(l.split()[0], 16) for l in open(sys.argv[1]) if len(l.split()) == 3}; print(m["_end"] - m["_text"])' "$L/System.map") B (v9: $(py -c 'import sys; m={l.split()[2]: int(l.split()[0], 16) for l in open(sys.argv[1]) if len(l.split()) == 3}; print(m["_end"] - m["_text"])' "$WORK/System.map.v9") B)"
	{
		echo "TWIN=$TW"
		echo "built $(date '+%Y-%m-%d %H:%M:%S %Z') by build/v9/build-v9.sh twin-image --twin $TW in $SECS s, make -j$JOBS"
		echo "config: build/v9/kernel-config.$TW.fragment md5 $FMD5; the built kernel .config differs from v9's in $(wc -l < "$WORK/kernel-config.diff.syms") symbol(s) (kernel-config.diff)$(grep -qx 'KSTRICT yes' "$FRAG" && echo ', every one named by the fragment (KSTRICT)')"
		echo "kernel-config-md5=$(md5sum < "$KC" | cut -d' ' -f1)"
		echo "source tree: $SRC (unchanged: find -newer listed 0 entries); copy: $O"
		echo "kernel modules: $n, every one rebuilt (this build's packaged copy, newer than the stage), $same byte-equal to v9's, $inst ftrace-instrumented (kmods-mcount.txt)"
		echo "$SIZES"
		echo "size estimate: $SZE"
		echo "keep lists: $(grep -c '^keep ' "$WORK/keep-lists.txt") kernel .config lines read back (security + NAS), NAS modules: $(grep -E '^(module|built-in) ' "$WORK/keep-lists.txt" | tr '\n' ' ')"
		if [ "$PROFT" = 1 ]; then echo "PROFILE TWIN: never ship"; else echo "bench twin: never a release until its arm passes (FABLE-OPT trial 3)"; fi
	} > "$WORK/TWIN.txt"
	if [ "$PROFT" = 1 ]; then
		{
			echo "PROFILE TWIN: never ship"
			echo "built $(date '+%Y-%m-%d %H:%M:%S %Z') by build/v9/build-v9.sh $STAGE$([ "$TW" = prof ] || echo " --twin $TW") in $SECS s, make -j$JOBS"
			echo "source tree: $SRC (unchanged: find -newer listed 0 entries); copy: $O"
			echo "config: build/v9/kernel-config.$TW.fragment md5 $FMD5; DYNAMIC_FTRACE: $DYN$([ "$TW" = prof2 ] && echo '; FUNCTION_GRAPH_TRACER: yes (the profiler records time per function)')"
			echo "kernel modules: $n, every one rebuilt (this build's packaged copy, newer than the stage), $same byte-equal to v9's, $inst ftrace-instrumented incl. the overlay's xhci three (kmods-mcount.txt)"
			echo "$SIZES"
		} > "$WORK/PROFILE-TWIN.txt"
		cat "$WORK/PROFILE-TWIN.txt"
	fi
	cat "$WORK/TWIN.txt"
	if [ "$TW" = prof ]; then say "done: $IMG (the PROFILE TWIN's image; bundle it with EX4_PROFILE=1 and DIR/openwrt as the bundle work's openwrt)"
	else say "done: $IMG (the $TW twin's image; bundle it with EX4_TWIN=$TW and DIR/openwrt as the bundle work's openwrt)"; fi
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
	OUT=${OUT:-$WORK/out}; B="$OUT/bundle-v9"; BW="$WORK/bundle-work"
	RWB=${EX4_RWBENCH:-0}; case "$RWB" in 0|1) ;; *) die "EX4_RWBENCH must be 0 or 1";; esac
	[ "$RWB" = 0 ] || [ -s "$TOP/box/ex4-rwbench.sh" ] || die "EX4_RWBENCH=1 but no box/ex4-rwbench.sh"
	# v9.4 + v9.7 variants (default = v9.3's bundle exactly): EX4_XOR=off (R1 arm X2), EX4_PROFILE=1 / EX4_TWIN (the kernel
	# twins), EX4_CMDLINE_ARM=nomemcg (run 15: cgroup_disable=memory on the command line; kernel, DTB, kmods unchanged).
	# variant_resolve (above) sets XOR PROF TWIN PROFILE CARM ARGX VSUF VARIANT, the same for the `variant` stage.
	variant_resolve
	[ "$XOR" = on ] || [ -s "$HERE/xor-off.dtsi" ] || die "EX4_XOR=off but no build/v9/xor-off.dtsi"
	case "$TWIN" in ''|prof) ;; *) [ -s "$HERE/kernel-config.$TWIN.fragment" ] || die "EX4_TWIN=$TWIN but no build/v9/kernel-config.$TWIN.fragment";; esac
	[ "$RWB" = 0 ] || grep -q 'ex4-rw-active' "$TOP/userland/ex4fan.c" || die "EX4_RWBENCH=1 needs ex4fan.c with the RWBENCH patch (its fail-safe must stop md1 first)"
	if [ "$WEBUI" = 1 ]; then
		[ -s "$TOP/webui/FILES" ] || die "no webui/FILES"
		py "$TOP/webui/build.py" --check > "$WORK/webui-check.log" 2>&1 || { cat "$WORK/webui-check.log" >&2; die "webui/dist is not the build of webui/src: run python3 webui/build.py first"; }
	fi
	[ -e "$B" ] && die "$B exists (never overwrite)"; [ -e "$BW" ] && die "$BW exists"
	mkdir -p "$B" "$BW"; PUB=$(cd "$(dirname "$PUB")" && pwd)/$(basename "$PUB")
	IMG=$(ls "$O"/bin/targets/kirkwood/generic/*iom_ix4-200d-initramfs-uImage) || die "run the image stage first"
	L=$(ls -d "$O"/build_dir/target-*/linux-kirkwood_generic/linux-$KVER)
	R=$(ls -d "$O"/build_dir/target-*/root-kirkwood)
	# THE UPDATE PATH IS IN THE IMAGE: the command, our key, who the image says it is (and no official feed)
	FP=$(py "$TOP/update/usignpy.py" fingerprint "$TOP/update/keys/ex4-release.pub") || die "update/keys/ex4-release.pub"
	cmp -s "$R/usr/sbin/ex4-update" "$TOP/update/box/ex4-update" || die "the image's /usr/sbin/ex4-update is not update/box/ex4-update (rebuild the image)"
	cmp -s "$R/etc/ex4-update/keys/$FP" "$TOP/update/keys/ex4-release.pub" || die "the image does not hold update/keys/ex4-release.pub as keys/$FP"
	grep -q '^serial=[1-9][0-9]*$' "$R/etc/ex4-release" || die "the image has no /etc/ex4-release with a serial"
	[ -z "$(ls -A "$R/etc/apk/keys" 2>/dev/null)" ] || die "the image carries an apk package key (rebuild the image with build-v9.sh)"
	cmp -s "$R/usr/sbin/ex4-md-ro" "$HERE/files/usr/sbin/ex4-md-ro" || die "the image's ex4-md-ro is not build/v9/files' (rebuild the image)"
	# THE KERNEL MARK (v9.4 THE PROFILE MARK, generalised in v9.7): the kernel this bundle finds, the EX4_* flag and the image
	# tree's own receipt must all name the same kernel. A twin kernel only with its flag; a flag only on its twin.
	kernel_kind "$L/.config"; TP=$(cd -P "$O/.." && pwd); PTW=; TWF=
	case "$KK" in
	default)
		[ "$PROF" = 0 ] || die "EX4_PROFILE=1 but this image's kernel is not a profile twin (no CONFIG_FUNCTION_TRACER=y in $L/.config)"
		[ -z "$TWIN" ] || die "EX4_TWIN=$TWIN but this image's kernel is the default one ($L/.config carries none of the twin's marks)"
		[ ! -e "$TP/TWIN.txt" ] && [ ! -e "$TP/PROFILE-TWIN.txt" ] || die "the image tree's parent ($TP) holds a twin receipt but its kernel is the default one"
		;;
	prof)
		[ "$PROF" = 1 ] || die "this image's kernel is a PROFILE TWIN (CONFIG_FUNCTION_TRACER=y): bundle it only with EX4_PROFILE=1 (never ship)"
		PTW=$TP/PROFILE-TWIN.txt
		[ -s "$PTW" ] && head -n 1 "$PTW" | grep -qx 'PROFILE TWIN: never ship' || die "a tracing kernel without its prof-image receipt ($PTW)"
		if [ -e "$TP/TWIN.txt" ]; then
			TWF=$TP/TWIN.txt
			head -n 1 "$TWF" | grep -qx 'TWIN=prof' && grep -qx "kernel-config-md5=$(md5sum < "$L/.config" | cut -d' ' -f1)" "$TWF" || die "$TWF does not name this profile kernel (TWIN=prof + the md5 of $L/.config)"
		fi
		;;
	*)
		[ "$TWIN" = "$KK" ] || die "this image's kernel is the $KK twin: bundle it only with EX4_TWIN=$KK$([ "$KK" = prof2 ] && echo ' (a PROFILE TWIN: never ship)') (EX4_TWIN is '${TWIN}')"
		TWF=$TP/TWIN.txt
		[ -s "$TWF" ] && head -n 1 "$TWF" | grep -qx "TWIN=$KK" || die "the $KK kernel without its twin-image receipt ($TWF, first line TWIN=$KK)"
		grep -qx "kernel-config-md5=$(md5sum < "$L/.config" | cut -d' ' -f1)" "$TWF" || die "$TWF records another kernel .config than $L/.config (md5)"
		if [ "$KK" = prof2 ]; then
			PTW=$TP/PROFILE-TWIN.txt
			[ -s "$PTW" ] && head -n 1 "$PTW" | grep -qx 'PROFILE TWIN: never ship' || die "the prof2 kernel without its PROFILE-TWIN.txt receipt ($PTW)"
		fi
		;;
	esac

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
	if [ "$XOR" = off ]; then
		# R1 arm X2: the default DTB first (for the diff), then the same preprocessed source + xor-off.dtsi
		cp "$BW/dts/ex4-trial.pp.dts" "$BW/dts/xor-on.pp.dts"
		dtc -q -I dts -O dtb -o "$BW/dts/xor-on.dtb" "$BW/dts/xor-on.pp.dts" 2> "$BW/dts/dtc-on.log" || { cat "$BW/dts/dtc-on.log" >&2; die "dtc (the default DTB)"; }
		dtc -q -I dtb -O dts "$BW/dts/xor-on.dtb" > "$BW/dts/xor-on.decompiled.dts" 2>/dev/null
		cat "$HERE/xor-off.dtsi" >> "$BW/dts/ex4-trial.pp.dts"
	fi
	dtc -q -I dts -O dtb -o "$BW/dts/ex4-trial.dtb" "$BW/dts/ex4-trial.pp.dts" 2> "$BW/dts/dtc.log" || { cat "$BW/dts/dtc.log" >&2; die "dtc"; }
	dtc -q -I dtb -O dts "$BW/dts/ex4-trial.dtb" > "$BW/dts/ex4-trial.decompiled.dts" 2>/dev/null
	if [ "$XOR" = on ]; then
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
	else
		# EX4_XOR=off: both orion-xor nodes disabled, and the DTB differs from the default one in EXACTLY those two lines
		py - "$BW/dts/xor-on.decompiled.dts" "$BW/dts/ex4-trial.decompiled.dts" "$BW/dts/xor-off.diff" > "$BW/dts/xor-check.txt" <<'PY' || { cat "$BW/dts/xor-check.txt" "$BW/dts/xor-off.diff" >&2; die "EX4_XOR=off: the DTB is not the default one with both XOR engines disabled and nothing else changed"; }
import difflib, sys
on, off = open(sys.argv[1]).read(), open(sys.argv[2]).read()
def node(t, n):
    i = t.find('xor@%s {' % n)
    return t[i:t.find('\n\t\t};', i)] if i >= 0 else ''
d = [l for l in difflib.unified_diff(on.splitlines(), off.splitlines(), 'xor-on.decompiled.dts', 'xor-off.decompiled.dts', n=3, lineterm='')]
open(sys.argv[3], 'w').write('\n'.join(d) + '\n')
minus = [l for l in d if l.startswith('-') and not l.startswith('---')]
plus = [l for l in d if l.startswith('+') and not l.startswith('+++')]
ok = []
for n in ('60800', '60900'):
    b = node(off, n)
    if 'marvell,orion-xor' in b and '\t\t\tstatus = "disabled";' in b and 'status = "okay"' not in b and b.count('dmacap,xor') == 2:
        ok.append(n)
two = minus == ['-\t\t\tstatus = "okay";'] * 2 and plus == ['+\t\t\tstatus = "disabled";'] * 2
print("dtb: EX4_XOR=off: orion-xor nodes disabled:", ok, "; diff against the default DTB:", len(minus), "line(s) out,", len(plus), "in, only the two status lines:", two)
sys.exit(0 if ok == ['60800', '60900'] and two else 1)
PY
		cat "$BW/dts/xor-check.txt"
	fi

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
	[ "$WEBUI" = 1 ] && set -- "$@" --webui "$TOP/webui"
	[ "$RWB" = 1 ] && set -- "$@" --rwbench "$TOP/box/ex4-rwbench.sh"     # docs/RWBENCH.md: inert without the typed token
	py "$TOP/build/mkoverlay.py" "$@" > "$BW/mkoverlay.log"
	# THE OVERLAY GATE: refuse an overlay without the security fix (a stale mkoverlay.py), or with the web door in the
	# wrong state for this bundle's flag
	if [ "$WEBUI" = 1 ]; then GATE="--webui $TOP/webui"; else GATE=--no-webui; fi
	if [ "$RWB" = 1 ]; then GATE="$GATE --rwbench $TOP/box/ex4-rwbench.sh"; else GATE="$GATE --no-rwbench"; fi
	GATE="$GATE --variant $VARIANT --kernel-dts $BW/dts/ex4-trial.decompiled.dts"     # v9.4: kmods + DTB match the variant
	py "$HERE/overlay-gate.py" "$B/overlay.cpio" --pubkey "$PUB" $GATE > "$BW/overlay-gate.log" 2>&1 || { cat "$BW/overlay-gate.log" >&2; mv "$B/overlay.cpio" "$B/overlay.cpio.REFUSED"; die "THE OVERLAY GATE refused overlay.cpio (kept as overlay.cpio.REFUSED, not in any MD5SUMS): see $BW/overlay-gate.log"; }
	tail -1 "$BW/overlay-gate.log"
	cp "$BW/mod/ex4boot.ko" "$B/ex4boot-l2off.ko"
	cp "$TOP/box/ex4-trial.sh" "$B/ex4-trial.sh"
	KERNEL_ADDR=0x8000; ATAGS_ADDR=0x100; INITRD_ADDR=0x4000000; MARK_A=0x1000; MARK_C=0x3000; MARK_H=0x3000000
	RUN="$RUNNO-l2off-$STAMP$VSUF"; printf '%s\n' "$RUN" > "$B/RUNID"
	EXTRA=
	if [ "$VARIANT" != stock ]; then
		# v9.4 / v9.7: a variant bundle says what it is in its own text file (covered by MD5SUMS; the default bundle has none)
		variant_text > "$B/VARIANT"
		EXTRA=VARIANT
	fi
	SZ=$(stat -c %s "$B/overlay.cpio")
	py "$TOP/build/ex4img.py" atags "$B/atags.bin" --mem 512 --initrd "$INITRD_ADDR,$SZ" --cmdline "$(cmdline_of "$RUN")" > "$BW/atags.log"
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
		echo "EX4 RAM-trial bundle-v9, built $(date '+%Y-%m-%d %H:%M:%S %Z') by build/v9/build-v9.sh, run id $RUN"
		echo "kernel.bin = zImage of OUR OpenWrt $(cat "$O/version" 2>/dev/null || echo 25.12.6) build ($(basename "$IMG"), md5 $(md5sum < "$IMG" | cut -d' ' -f1)) + dts/kirkwood-wd-mycloud-ex4.dts (-DEX4_TRIAL)"
		echo "tree: $OWRT_GIT $OWRT_TAG ($OWRT_COMMIT, $OWRT_REV) + build/v8 (diffconfig, kernel-config.fragment, patches/) + build/v9/files"
		echo "update path: /etc/ex4-release $(tr '\n' ' ' < "$R/etc/ex4-release"); ex4-update md5 $(md5sum < "$R/usr/sbin/ex4-update" | cut -d' ' -f1); release key $FP; no apk key, no official feed"
		echo "ex4-md-ro md5 $(md5sum < "$R/usr/sbin/ex4-md-ro" | cut -d' ' -f1) (refuses a member being rebuilt)"
		if [ "$RWB" = 1 ]; then echo "rw bench: YES, inert until its per-session token is typed: /usr/sbin/ex4-rwbench md5 $(md5sum < "$TOP/box/ex4-rwbench.sh" | cut -d' ' -f1), the clean stop on S99 / S03 / K01 / ex4fan"
		else echo "rw bench: no"; fi
		echo "image stage egress: $(grep '^RESULT' "$WORK/netwall-proof.txt" 2>/dev/null || echo 'no receipt')"
		echo "ex4-trial.dtb md5 $(md5sum < "$BW/dts/ex4-trial.dtb" | cut -d' ' -f1) · ex4phy md5 $(md5sum < "$BW/ex4phy" | cut -d' ' -f1)"
		echo "$(cat "$BW/size-gate.txt")"
		echo "overlay: key-only ssh, root '*', auto-return $RETURN_MIN min (+2 deadman), disk log window $LOG_SECTORS sectors exactly, port kept off: ${LOG_SKIP_PORT:-none}; $(tail -1 "$BW/overlay-gate.log")"
		if [ "$WEBUI" = 1 ]; then echo "web interface: YES (HTTPS 443 on the LAN, port 80 redirects, no web login until claimed with ex4-claim over ssh): index.html md5 $(md5sum < "$TOP/webui/dist/index.html" | cut -d' ' -f1), ex4.uc md5 $(md5sum < "$TOP/webui/backend/ex4.uc" | cut -d' ' -f1)"
		else echo "web interface: no (uhttpd on 127.0.0.1:80 only)"; fi
		echo "ex4fan md5 $(md5sum < "$B/ex4fan" | cut -d' ' -f1) (userland/ex4fan.c md5 $(md5sum < "$TOP/userland/ex4fan.c" | cut -d' ' -f1)); LCD Tier A off unless /etc/config/ex4panel says tierA; the self-test sends ONE LCD frame (ctl send-test)"
		[ "$PROFILE" = 1 ] && echo "PROFILE TWIN: never ship (bench only; kernel .config has CONFIG_FUNCTION_TRACER=y; $(sed -n 4p "$PTW"))"
		[ "$TWIN" = prof2 ] && echo "TWIN=prof2: + FUNCTION_GRAPH_TRACER (the profiler records time per function); $(sed -n 3p "$TWF")"
		case "$TWIN" in uaccess|diet|ud|nfsdtrack) echo "TWIN=$TWIN: bench kernel twin, never a release until its arm passes; $(sed -n 3p "$TWF")";; esac
		[ "$XOR" = off ] && echo "XOR=off (PERF-DESIGN-v2 R1 arm X2): both orion-xor nodes disabled in ex4-trial.dtb; $(tail -1 "$BW/dts/xor-check.txt" 2>/dev/null)"
		echo "loaded into stock's RAM by the loader: $(py -c 'import os,sys; b=sys.argv[1]; print(sum(os.path.getsize(os.path.join(b,l.split()[0])) for l in open(os.path.join(b,"SEGS"))))' "$B") bytes in $(grep -o 'loader chunks: [0-9]*' "$BW/layout.log" | tail -1 | cut -d' ' -f3) chunks of 32 KiB"
	} > "$B/PROVENANCE"
	( cd "$B" && md5sum ex4boot-l2off.ko ex4peek ex4log ex4fan KMODS.txt kernel.bin overlay.cpio atags.bin markA.bin markC.bin markH.bin SEGS EXPECT RUNID CFG LOGCFG PROVENANCE ex4-trial.sh $EXTRA > MD5SUMS )
	# v9.8 THE BUNDLE GATE (v95 must_fix): the finished bundle's own VARIANT / RUNID / KMODS.txt must say this variant
	py "$HERE/overlay-gate.py" "$B/overlay.cpio" --pubkey "$PUB" $GATE --bundle "$B" > "$BW/bundle-gate.log" 2>&1 || {
		cat "$BW/bundle-gate.log" >&2; mv "$B" "$B.REFUSED"; die "THE BUNDLE GATE refused $B (renamed $B.REFUSED): see $BW/bundle-gate.log"; }
	tail -1 "$BW/bundle-gate.log"
	cp "$BW/xor-proof.txt" "$BW/size-gate.txt" "$OUT/" 2>/dev/null || true
	say "done: $B ($(ls "$B" | wc -l) files, $(du -sk "$B" | cut -f1) KiB), run id $RUN"
	exit 0
fi
if [ "$STAGE" = variant ]; then
	# v9.7, PLAN ONLY (builds nothing, needs no image): what a bundle with these EX4_* would get as run id, VARIANT file and
	# atags.bin, from the same variant_resolve / variant_text / cmdline_of the bundle stage calls. tests/build/ drives it.
	variant_resolve
	[ -n "$OUT" ] && [ -n "$RUNB" ] && [ -n "$ISZ" ] || die "variant: --run RUNBASE --initrd-size N --out DIR are required"
	case "$ISZ" in *[!0-9]*) die "--initrd-size must be a number";; esac
	case "$RUNB" in *[!A-Za-z0-9-]*) die "--run: letters, digits and - only";; esac
	[ -e "$OUT" ] && die "$OUT exists (never overwrite)"
	mkdir -p "$OUT"; RUN="$RUNB$VSUF"; printf '%s\n' "$RUN" > "$OUT/RUNID"
	[ "$VARIANT" = stock ] || variant_text > "$OUT/VARIANT"
	cmdline_of "$RUN" > "$OUT/CMDLINE"
	py "$TOP/build/ex4img.py" atags "$OUT/atags.bin" --mem 512 --initrd "0x4000000,$ISZ" --cmdline "$(cmdline_of "$RUN")" > "$OUT/atags.log"
	py "$TOP/build/ex4img.py" atags-parse "$OUT/atags.bin" --expect-token "ex4boot_run=$RUN" --expect-initrd "0x4000000,$ISZ" --max-end 0x1000 >> "$OUT/atags.log" || die "ATAGs"
	echo "run id $RUN; variant $VARIANT"
	exit 0
fi
if [ "$STAGE" = kernel-kind ]; then
	# v9.8: the bundle stage's own kernel_kind on any kernel .config (tests/build/twin-variant-test.sh; the assembler's check)
	[ -n "$KCONF" ] && [ -f "$KCONF" ] || die "kernel-kind: --config KERNEL.config (a file) is required"
	kernel_kind "$KCONF"; echo "$KK"
	exit 0
fi
die "first argument: image, prof-image, twin-image, bundle, variant or kernel-kind"
