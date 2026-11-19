# build/v7: our own kernel and the P0 image (v7, phase B)

Up to v6 the trial booted OpenWrt's official kirkwood kernel. That kernel cannot use the SoC's two XOR engines
(`MV_XOR` is a bool in Linux 6.12, so no module can add it), and on this single 1 GHz core every RAID5 write then pays
for its parity in software. v7 builds OpenWrt 25.12.6 from source with the engines in, md built in, and the NAS
services in the image.

```
sh build/v7/build-v7.sh image  --work DIR [--seed-dl DIR] [--jobs N]
sh build/v7/build-v7.sh bundle --work DIR --pubkey KEY.pub --wd-gpl WDMyCloud_EX4_GPL_v2.12.127_20181219.tar.gz [--out DIR]
```

| File | What |
|---|---|
| `build-v7.sh` | both stages; every step and gate is in its header and its `die` lines |
| `diffconfig` | the OpenWrt `.config` as a diff (kirkwood/generic, one device, initramfs with xz, the package list) |
| `kernel-config.fragment` | merged into `target/linux/kirkwood/config-6.12`: `DMADEVICES`, `MV_XOR`, `ASYNC_TX_DMA`, md + raid1 + raid456 built in with **autodetect off**, ext4 quotas |
| `patches/mdadm-no-md-kmods.sed` | one line of `package/utils/mdadm/Makefile`: the package stops pulling `kmod-md-*` (whose `KCONFIG` override would turn md autodetect back on) |
| `files/usr/sbin/ex4-md-ro` | the only way the image assembles the data array: read-only, four walls (below) |
| `egress-allow.py` | the build's only way out: a local proxy that lets OpenWrt's own servers answer and refuses every other host, with a log |
| `tests/qemu-p0-idle.sh` | memory of the P0 services at idle, in qemu, on this image's real userspace |

## Where the sources come from

The tree is `git.openwrt.org/openwrt/openwrt.git`, tag `v25.12.6` (tag object `22dd0e28`, commit `64900e75`, which
`scripts/getver.sh` names `r33311-981c978eff`, the revision of the official release). The packages feed is
`git.openwrt.org/feed/packages.git` at `093d5516`, the commit the release's own `feeds.buildinfo` names. No other feed.
Every tarball comes from OpenWrt's source mirror (`sources.cdn.openwrt.org`): the build runs behind `egress-allow.py`
with OpenWrt's mirror tried first, so a package's upstream URL, or a git fallback, is refused at the proxy and logged.
OpenWrt checks every file's hash itself (`PKG_HASH`, `PKG_MIRROR_HASH`, `LINUX_KERNEL_HASH`); nothing here turns
that off. The first build of this image downloaded 107 files: 109 connections allowed, all to OpenWrt's servers, none
refused. The clean rebuild that produced the image fetched 34 more files the same way, and its log shows one refused
attempt: glib's meson tried to clone an optional subproject (sysprof) from `gitlab.gnome.org` and went on without it.

## What the image is

- **Kernel:** OpenWrt's kirkwood config + the fragment. In the built kernel: `CONFIG_MV_XOR=y`, `CONFIG_ASYNC_TX_DMA=y`,
  `CONFIG_BLK_DEV_MD=y`, `CONFIG_MD_RAID456=y`, `CONFIG_MD_RAID1=y`, `# CONFIG_MD_AUTODETECT is not set`, `CONFIG_QUOTA=y`.
  The device tree is ours (`dts/`, with `-DEX4_TRIAL`: every NAND partition read-only); its two `marvell,orion-xor`
  nodes (four channels, `dmacap,xor` + `dmacap,memcpy`) come from the kernel's `kirkwood.dtsi` and are enabled. The PHY
  set-up that ended the link flap in v6 (both PHYs on the generic driver) is in the same tree, unchanged.
- **Packages:** PLAN.md's named list (mdadm, e2fsprogs, smartmontools + smartd, samba4-server with vfs_fruit / recycle /
  streams and quota reporting, ksmbd, nfs-kernel-server + nfsd, wsdd2, avahi without dbus, msmtp, bonding, rsync,
  USB storage + vfat + exfat, rpcd + rpcd-mod-ucode, uhttpd + its ubus module). **Left out:** dnsmasq, odhcpd,
  firewall4 / nftables, ppp (a NAS on a home LAN is a DHCP client, not a router), uboot-envtools (it writes the U-Boot
  environment in NAND), block-mount (its hotplug can `swapon` any partition with a swap signature: WD's sdX1), LuCI
  (the web interface is ours, phase D), Samba's NetBIOS daemon (SMB1-era), the ix4-200d's own board drivers.
- **What starts at boot in a trial:** procd, logd, netifd, dropbear (key only), rpcd, uhttpd (the overlay binds it to
  127.0.0.1), cron, ntpd, smartd. **What does not**, though installed: `mdadm`, `samba4`, `ksmbd`, `nfsd`, `rpcbind`,
  `wsdd2`, `avahi-daemon` (their `/etc/rc.d` links are removed while the image is built), and the USB-storage modules
  (their `/etc/modules.d` entries are moved to `/usr/share/ex4/modules.d.off/`: a USB disk would shift the `sdX` names
  the trial's log gate uses). Every file service starts by hand, against a share someone configured, after
  `ex4-md-ro assemble`. So in a trial nothing listens on the LAN without a login: only ssh (key only).

## ex4-md-ro: the walls

`ex4-md-ro check | assemble | stop`. It refuses unless exactly four SATA partitions 2 carry one array: superblock 1.0,
raid5, 64K chunk, left-symmetric, State clean, the same Array UUID and the same Events count. Then:

1. every member is set read-only in the kernel (`blockdev --setro`) before mdadm assembles. In Linux 6.12 that flag makes
   a user-space `write()` to the partition fail (`-EPERM`, `block/fops.c`) and a write open by path fail (`-EACCES`,
   `block/bdev.c`), but a bio written by the kernel itself only gets a warning (`bio_check_ro`, `block/blk-core.c`). What
   stops md is md: a read-only member forces the array to `MD_RDONLY` (`drivers/md/md.c:6121`), where md fails every
   write bio (`md.c:433`) and writes no superblock.
2. `mdadm --assemble --readonly` (never `--run`, never `--force`); refused unless `/proc/mdstat` says `(read-only)` and `[UUUU]`.
3. `/dev/md1` is set read-only.
4. ext4 is mounted `ro,noload` (no journal replay).

There is **no read-write command in this image**. Writing to the array is a later phase: its own command, which refuses
unless `/tmp/ex4-rw-ok` holds a token Kurt types in that session (never created by any script), plus SERVING.md 3.3's
conditions (clean array, frozen sync, bounded window, clean stop on every return path).

## Size

The loader copies the bundle in 32 KiB chunks (2643 at most); the kernel decompresses itself at 0x8000. `build-v7.sh
bundle` refuses if the decompressor's worst case would reach RAM marker H (0x3000000). The first bundle: initramfs
uImage 17,754,922 B, kernel.bin 17,754,777 B, decompressed image 25,968,528 B, worst-case peak 0x29faa29, 6.0 MiB
below marker H.

## What was tested, off the box (Nov 17 2026, the build box)

- `tests/run-offbox.sh` on a bundle-v7 (a throwaway key, so the e2e also logs in): 17 tests, 16 clean. The e2e ran
  **this image's userspace** + the overlay on the e2e test kernel: normal 54/54 (incl. every v7 security check from
  outside: no /ubus or LuCI login, 80 and 443 closed, key-only ssh, root `*`), silent 11/11, rpmzero 11/11.
  `qemu-handoff` 10/10 on OUR kernel through the real stub: it decompresses at 0x8000 from the bundle's own layout,
  takes the appended EX4 DTB and the ATAG command line, and runs as the Feroceon.
- The one failure, `handoff-memfix` "no Unpacking initramfs", is the emulator: with md built in, the kernel's xor
  benchmark (`crypto/xor.c`, `do_xor_speed`) waits for time to advance, and qemu's versatilepb has no Kirkwood timer, so
  `ktime_get()` never moves (the guest was stopped in `clocksource_mmio_readl_down` called from `ktime_get`). On the
  EX4 the orion timer ticks (stock's own dmesg prints this benchmark). The official kernel had no built-in xor, so v6
  never reached that line.
- The initramfs inside kernel.bin was unpacked and compared with the rootfs folder the e2e booted: 1238 entries, 0
  regular files differ (the cpio adds the 9 base `/dev` nodes); the rc.d links of the services above are absent.
- `tests/qemu-p0-idle.sh`: with smbd (+ notifyd, cleanupd), wsdd2, avahi, rpcbind + nfsd and smartd up on empty tmpfs
  shares, `free` reported 19.5 MB used (23.6 MB before they started: noise of the test kernel); the processes' VmRSS add
  up to 42.6 MB (shared libraries counted once per process). ksmbd is not in that number (no ksmbd in the test kernel).
  CPU under qemu means nothing; idle CPU is for the first trial on the box.
