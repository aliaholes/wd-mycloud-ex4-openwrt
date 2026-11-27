# stage2/: the second-stage loader for a future flash install

This folder builds the **stage-2 ramdisk**: WD's own stock ramdisk (the one in flash partition `mtd2`) with one
folder (`/ex4`) and **one line** added. It is the piece a permanent install would put into `mtd2`. The flash
install itself is **not done** (on one unit the `mtd2` step is done and boots): see [../INSTALL.md](../INSTALL.md) before you go
further than building.

## Status, plainly

| What | Status |
|---|---|
| Building the image off the box | Works. Done on our build machine Nov 26 2026, and again from this folder's own copy of `mkstage2.sh` |
| **Booting it from RAM** (WD's own kernel + this ramdisk, handed over by `ex4boot`, no flash write) | **PROVEN** on ONE unit, Nov 26 2026, for ONE image (md5 `d2c6d5e629e105feab45725ffa3611bf`; see below) |
| The branch that ran | "mtd3 is not UBI: continue the stock boot". The box came back as stock by itself in about 2 minutes, RAID clean, WD's daemons all up |
| The UBI branch (boot a modern kernel from flash) and the rescue shell | **Never run.** No unit has a UBI `mtd3` |
| Written to flash (`mtd2`) | **Once, on ONE unit (ours, Nov 26 2026).** `../box/ex4-install.sh` still ships with `ARMED=0`: the write ran from an armed COPY |
| Read by U-Boot from flash | **Once, on ONE unit** (Nov 26 2026): our image d2c6d5e6 written to `mtd2`, U-Boot loaded it, `stage2.sh` continued the stock boot, WD came up as before |

What the RAM proof saw on the test unit (WD firmware 2.12.127): `/proc/cmdline` carried the run id we passed
(the jump worked); `dmesg | grep ex4-stage2` gave exactly one line, `ex4-stage2: mtd3 is not UBI (stock firmware
image): continuing the stock boot`, and `/ex4/stage2.log` held the same line; the files in `/ex4` had the md5s of
the table below; `/etc/rc.sh` line 43 was the hook; the kernel freed a 3296K initrd (stock frees 1920K). Then
WD's own boot ran as always (its file system check after an unclean stop, RAID `[UUUU]`, the same daemon list as
before). The md5 of the u-boot, kernel, ramdisk and identity partitions were the same before and after.

**Your image will not be byte-identical to ours.** `debugfs` stamps inode times, so two builds of the same inputs
differ (a second build of ours did). What should be identical is the content: check it with `e2walk.py` (below).
The proof above is for our image on our unit; it says nothing about your unit until you prove yours from RAM.

## What is in the image

Everything in WD's ramdisk stays as it is, at the same size (the script refuses a size change), plus:

| Path | What | md5 in the proven image |
|---|---|---|
| `/etc/rc.sh` | WD's own, plus ONE line after `touch /dev/mdev.seq`: `[ -x /ex4/stage2.sh ] && /ex4/stage2.sh` | `afd5fa03...` (WD's: `0f71ffb2...`) |
| `/ex4/stage2.sh` | the loader script (this folder, byte-identical) | `8dd6a35c31b6a1a63703ee8184ffbe6a` |
| `/ex4/udhcpc.script` | DHCP hook for the rescue shell (this folder, byte-identical) | `8e849d615f5f1b5413d3cb28811c4f0e` |
| `/ex4/ex4boot.ko` | `ex4boot-l2off.ko` built from `../loader/` (EX4_L2OFF=1) | `477b2d2072ebe4dedc3b540f10f4309d` |
| `/ex4/busybox` | a static ARMv5 busybox 1.36.1 (yours: see below) | `fc95e2b437f783445d58e7c3c40b7751` |
| `/ex4/ex4peek` | `../userland/ex4peek.c`, static, stripped | `011211d3777d73e6c8ba86f715670c8a` |

`stage2.sh` and `udhcpc.script` are kept byte-identical to the copies inside the proven image, so they carry no
SPDX line (their licence, GPL-2.0-or-later, is stated in `../LICENSE`). The comment "DRAFT ... NEVER run on
hardware" at the top of `stage2.sh` was true when written; this table is the status now.

What `stage2.sh` does at boot, under WD's kernel: if `mtd3` does not start with `UBI#` (true for every stock unit),
it logs one line and returns, and WD boots as always. Only on a UBI `mtd3` would it load a modern kernel from a
volume called `ex4boot` (with the 21 s watchdog armed), or fall into a rescue shell (DHCP, telnet on port 23, no
password) after 3 failed tries. Those paths have never run.

## Building it from YOUR OWN stock ramdisk

This repository does not contain WD's ramdisk and never will: you take it from your own unit. **Never publish or
share the image you build: it contains WD's ramdisk.**

1. **Your stock ramdisk.** On the stock firmware's root shell (the main README says you need one; this repository does not describe how to
   get one), read
   `mtd2` into a file on the data volume and copy it to your computer:
   `dd if=/dev/mtd2 of=/mnt/HD/HD_a2/mtd2.dd bs=131072`. This only reads. Keep this file: it is also your backup.
   Then, on your computer: `head -c 2003252 mtd2.dd > uRamdisk-stock`. Its md5 must be
   `8006f1d3061c3307704feeb04d3a68e9` (WD 2.12.127's ramdisk as shipped; `mkstage2.sh` refuses anything else).
   Cut by that exact length: WD's file is one byte longer than its own header says, and a cut by header length
   gives a different md5.
2. **`ex4boot-l2off.ko` and `ex4peek`.** `../build/build.sh` builds both (they land in its bundle folder).
   `ex4boot-l2off.ko` must have vermagic `3.2.40 mod_unload ARMv5 p2v8` (build.sh checks).
3. **A static ARMv5 busybox.** Not built by this repository. Ours is busybox 1.36.1, static, ARMv5TE, EABI
   soft-float, with its LOAD segments aligned to 0x8000 (`readelf -l` shows `Align 0x8000`; WD's kernel uses
   32 KiB pages, and `../userland/` is linked the same way with `-Wl,-z,max-page-size=0x8000`). It needs these
   applets: `dd mkdir ubiattach mount cat cp umount ubidetach awk insmod grep rmmod sleep ifconfig udhcpc
   telnetd sync expr`, and for the rescue shell `md5sum nanddump nandwrite tftp`. Check with `busybox --list`.
4. **Tools on your computer:** `debugfs` and `e2fsck` (e2fsprogs), `gzip`, `python3`. No `mkimage` and no root:
   the uImage header is written by `../build/ex4img.py rduimage` (rebuilt over WD's own payload with WD's own
   timestamp, it gives back WD's original header and payload, byte for byte).
5. **Build** (from the repository's top folder; the output folder must not exist yet):

   ```
   sh stage2/mkstage2.sh uRamdisk-stock stage2 ex4boot-l2off.ko busybox ex4peek out-stage2
   ```

   It checks the stock md5, adds exactly one line to `rc.sh` (it refuses if that is not one line), writes `/ex4`,
   runs `e2fsck -fn` (refuses unless clean), compares the written files back, and refuses an image over 5 MiB.
   The result is `out-stage2/uRamdisk-ex4-stage2` (about 3.4 MB of the 5 MiB partition).
6. **Check the content:**

   ```
   python3 stage2/e2walk.py out-stage2/work/stock.img   > stock.tsv
   python3 stage2/e2walk.py out-stage2/work/ramdisk.img > stage2.tsv
   diff stock.tsv stage2.tsv
   ```

   The diff must be exactly: `/etc/rc.sh` changed, and `/ex4` plus its five files added. Nothing else.

## What you cannot do with this repository yet

- **Prove your own image from RAM.** Our RAM proof used an older version of the trial script and a bundle builder
  that are not in this repository yet. Until they are, there is no published way to do the one step that
  `../box/ex4-install.sh` requires before it will write (its wall 6: the image's md5 in a file `STAGE2-PROVEN`).
  Do not write that file by hand.
- **Install anything.** Read [../INSTALL.md](../INSTALL.md): the flash write has been done on ONE unit only, without serial, and the full install is not done.

## Files

| File | What |
|---|---|
| `mkstage2.sh` | builds the image (off the box) |
| `stage2.sh` | the loader script that goes into `/ex4` |
| `udhcpc.script` | its DHCP hook for the rescue shell |
| `e2walk.py` | lists every path of an ext2 image (mode, owner, size, md5) through `debugfs`, no mount, no root |
