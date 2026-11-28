# What the install work taught us (Nov 26-27 2026, one unit)

Plain notes for anyone with the same box (WD My Cloud EX4, firmware 2.12.127) who reads `stage2/v2/`, `persist/`, `c4/`
and `box/ex4-mtd3.sh`. Each item is something that surprised us on real hardware or in a real tool, and what we changed
because of it. Everything was seen on ONE unit.

## NAND and its tools

**1. `nandwrite` checks the NEXT block before it notices the end of its input.** mtd-utils 2.3.0's `nandwrite`, reading
stdin, checks each new eraseblock for badness before it reads the next chunk of input. So a write that ends exactly before a
bad block prints `Bad block at <offset>, 1 block(s) will be skipped` for the block AFTER the range, then hits end of input.
Nothing shifted. It also prints one more `Writing data to block N` line than the blocks you wrote. Our first C4 kit refused on
any "bad block" text and so refused a perfect write. **Judge a write by reading it back** (md5 of exactly the blocks written,
compared with the source's md5 computed before the write), not by the tool's text. A bad-block line for an offset INSIDE the
range is a real shift; one at or past its end is the probe.

**2. `nandwrite -p` skips a bad block and shifts everything after it by one block.** Our `mtd3` has one bad block (block
1501). So an image for mtd3 must end before it (`ex4-mtd3.sh` wall 5), a simulated mtd3 is written in two ranges around it,
and putting WD's image back writes only its first 0x6820000 bytes (833 blocks; the rest of the stock partition is 0xFF).
Writing a whole dump back would push the bytes after the bad block one block later. Your bad blocks may be elsewhere: read
your own `/sys/class/mtd/mtd3/bad_blocks` and `nanddump` output before trusting any of our numbers.

**3. A fake must refuse what the real tool refuses.** Our first sims of the UBI path used fake `ubiattach`/`ubidetach` that
accepted any arguments. On the box the real busybox 1.36.1 `ubiattach` rejected `-O` (the option sits only in `ubimkvol`'s
option string upstream) and every call lacked the `/dev/ubi_ctrl` argument busybox requires. With that build in `mtd2`, every
boot of an installed box would have gone to rescue. Since then every fake copies the real tool's option string (or the proof
runs the real binary under qemu), and the scripts were run against strict fakes until they passed.

## UBI under WD's 3.2.40 and under OpenWrt's 6.12

**4. The same UBI must suit both kernels.** WD's 3.2.40 (stage2, in `mtd2`) reads `ex4boot` and writes `tries`; 6.12 (the
installed system) mounts both volumes for the whole run. What that needed:
- VID header offset 2048 on this NAND (sub-page 512): attach with `-O 2048`; ubinize `-p 128KiB -m 2048 -s 512 -O 2048`.
- UBIFS format 4 (3.2.40 mounts a newer format read-only at best, and stage2 must write); compressor none, lzo or zlib
  (3.2.40 refuses zstd); flags only BIGLPT / SPACE_FIXUP.
- 6.12 kept the media format at `w4/r0` on every rw mount we saw (no silent up-rev).
- 6.12 reserves 39 PEBs for bad-block handling on this geometry, 3.2.40 about 18: leave unallocated space for both.
- Under 6.12, mtd-utils 2.3.0's `ubiattach` takes the old form (`-m 3 -d 3 -O 2048`) correctly; only busybox needed the fix.
- Not yet seen: the two kernels taking turns on the same real UBI. C4 saw 6.12 read the image as built and its own writes back.

**5. Reading a USED UBIFS image needs the index and the journal.** `build/build-mtd3.py check --extract` is a fresh-build
checker: it takes the newest node for each key and never applies a deletion or a rename. On an image a running system wrote,
it shows uci temp files, `.new` names and stale bytes (it read `tries` as 1 where the box read 0). `c4/ubifs-read.py` walks
the index from the newest master node and replays the journal with its deletions; that is what the kernel mounts.

**6. A stripped-module kernel does not check vermagic.** OpenWrt's kernel is built with `CONFIG_MODULE_STRIPPED`, which
skips the vermagic test at module load: a module for the wrong kernel is not refused. Our nandsim build is gated off the box
instead (struct module size, symbol resolution, provenance).

## WD's stock firmware

**7. WD's boot check erases WD's kernel.** The stock ramdisk runs `chk_image` right after our hook: when `mtd3` is not a valid
WD image, it erases `mtd1` (WD's kernel) and reboots. v1 of our hook returned to WD's boot whenever `mtd3` was not UBI, so a
power cut during a `mtd3` write would have ended there. **stage2 v2 returns to WD only when mtd3 positively is WD's image**
(md5 of the first page and of the first 0x6820000 bytes); anything else is our branch, whose every failure is the rescue
shell. That read costs 24-37 s per stock boot until mtd3 is UBI. The pins are OUR unit's bytes: check yours first
(`stage2/v2/README.md`).

**8. Stock's ssh port goes dark under fast probes.** While two of our watch loops probed port 22 at once (about every 2.5 s),
stock's port 22 timed out from that one host for about 14 minutes (other hosts connected; 80/443/139/445 stayed open). It
cleared on its own after the probing stopped. Watch with ping, and probe port 22 at most once a minute, one watcher at a time.

**9. WD's `auto_fw` cron minute moves on every stock boot.** Stock's crontab has `0 4 * * * auto_fw ...` and a second entry
whose time changes each boot (we saw 14:46, 04:27, 14:01, 04:47, 12:16, 05:21 in two days). Read `crontab -l` before any
trial or write, and do not start one within 15 minutes of either time.

**10. Small stock-shell facts.** Stock busybox 1.20.2 has no `$(( ))` and its PATH has no `timeout`; every script that runs
under stock passes `sh -n` with the stock shell itself. `mdev` takes more than 2 s to create a new `/dev/mtdN`. In rescue
(stage2 under WD's kernel, before WD's init) U-Boot hands over a placeholder MAC address, so the DHCP lease may not be the
box's usual address: find a dark box by looking for port 23 on the LAN.

## The C4 trial (`c4/`)

**11. A refused sim must never be attached.** In the first C4 session, after our sim loader refused, the simulated NAND stayed
loaded with half an image in it, and the installed system's `ex4-persist` attached it by name anyway and ran as if all was
well. Harmless (only RAM was written), but it would have counted a broken boot as a result. Now the loader writes a `.done`
file as its very last act and the test copies attach only with `.done` present and no `.refused`: a refusal, a crash or a hang
means MODE ram, never marked good, and the deadman takes the box home.

**12. Give every RAM trial three ways home that need no hand:** a not-good deadman (no good mark in 10 min = reboot), a
deadman after the good mark (45 min), and an absolute cap (90 min after boot).

**13. What C4 proves and what it does not.** It proves the installed system's logic under 6.12 against a NAND with mtd3's
geometry and bad block: attach, seed, mark-good, restore, safe mode, the deadman, and that the real partitions stay read-only
and unchanged. It does NOT prove the real NAND driver under 6.12 on the real `mtd3`, nor 3.2.40 and 6.12 sharing one real UBI.
Those are first seen at phase D2 of the install.

**14. When to stop testing.** A test round earns its time when a real failure would leave a receipt it reads. Once the stock
branch, the UBI branch, the rescue, the restore and the installed system had each passed on the box (in RAM), we stopped adding
rounds that only re-proved them and went to the install.

## The install path as it now stands

1. **D1: `mtd2` <- stage2 v2** (`box/ex4-install.sh`, the same flow as the Nov 26 v1 write: backup, armed write from a copy,
   read-back). Reboot: one `mtd3 is WD's stock image` line, WD up as before.
2. **D2: `mtd3` <- the installed system** (`box/ex4-mtd3.sh`: `backup DIR`, `write DIR`, then `verify` under stock BEFORE any
   reboot: attach, mount both volumes, md5 every `ex4boot` file, tries 0). U-Boot never reads mtd3, so with the belt in mtd2
   this is the lower-risk write. Reboot: stage2 -> the modern system -> mark-good -> tries 0.
3. **The array:** copy anything you want off it, then re-create it under the modern system (RAID5, superblock 1.2 with a
   write-intent bitmap and a bad-block log, ext4 with 64bit + metadata_csum, the default inode ratio). The full resync is about
   21 hours on four 4 TB disks. The installed system's service mode (`persist/files/usr/sbin/ex4-svc`) takes superblock 1.0
   (WD's) or 1.2.

**Status: install in progress Nov 27 2026** (on our unit). INSTALL.md carries the step table; this line moves when D1 and D2
have read back.
