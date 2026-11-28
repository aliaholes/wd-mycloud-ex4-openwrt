# stage2/v2/: the stage-2 ramdisk WITH THE BELT (the one an install puts into `mtd2`)

v1 (`../stage2.sh`, [../README.md](../README.md)) hands the boot back to WD whenever `mtd3` is not UBI. That is fine while
`mtd3` holds WD's image, and dangerous once it does not: WD's own boot check (`chk_image`, run right after our hook) **erases
WD's kernel in `mtd1`** when `mtd3` is not a valid WD image. v2 closes that hole. Read [../../INSTALL.md](../../INSTALL.md)
and [../../docs/LESSONS-2026-11.md](../../docs/LESSONS-2026-11.md) before you build anything here.

## Status, plainly (one unit, ours)

| What | Status |
|---|---|
| Stock branch from RAM (WD's kernel + this ramdisk through `ex4boot`) | **proven** Nov 26 2026: one dmesg line `mtd3 is WD's stock image (...): continuing the stock boot`, WD fully up, flash unchanged |
| UBI branch from RAM, against a **simulated** NAND (nandsim with mtd3's geometry, under WD's 3.2.40) | **proven** Nov 26-27 2026 for our image (md5 `d65082b20d13970bdb20e6dfe68103ff`, 3421663 bytes, the "r4" build): attach with VID offset 2048, both UBIFS volumes mount, tries 0 -> 1 -> 2 -> 3 -> rescue, an erased sim -> rescue, WD's image in the sim -> stock |
| The rescue shell at boot (forced) | **proven**: DHCP lease, telnet on port 23, the tools present, `reboot -f` back to stock |
| `restore-stock.sh` (WD's image back into mtd3) | **proven into the simulated mtd7 only**, armed, with its input from a real pipe; never against the real `mtd3` |
| Written to the real `mtd2` | **install in progress Nov 27 2026** (phase D1 in INSTALL.md) |

## The files

| File | What |
|---|---|
| `stage2.sh` | `/ex4/stage2.sh` v2. Returns to WD (exit 0) **only** when mtd3's first page AND its first 0x6820000 bytes have the md5s pinned in the file (`WD_HEAD_MD5`, `WD_IMG_MD5`). `UBI#` = boot the modern kernel from the `ex4boot` volume. Anything else (erased, junk, a read error, WD's head over a damaged body) = rescue. There is no `exit 0` outside the WD branch. |
| `restore-stock.sh` | `/ex4/restore-stock.sh`. Writes WD's image back into mtd3 from a file or stdin: stages it in RAM and checks byte count + md5 BEFORE any erase, then blocks 1..832, read back, then block 0, read back all 833. Ships `ARMED=0`. Refuses unless mtd2 holds v2. Never reboots. |
| `mkstage2-v2.sh` | `../mkstage2.sh` plus `restore-stock.sh` in `/ex4` and a read-back compare of both scripts. Same stock-ramdisk pin, same ONE added line in `rc.sh`. |

## Before you build: the belt is pinned to OUR unit's bytes

`WD_HEAD_MD5` and `WD_IMG_MD5` are the md5s of OUR `mtd3` (WD firmware 2.12.127, no bad block inside its first 833 blocks).
**If your mtd3's bytes differ, a v2 in your mtd2 sends EVERY boot to rescue instead of WD.** That is the safe side (rescue
never erases anything), but your box would then sit in rescue until you fix it. So before you build, on your own stock box,
read-only:

```
dd if=/dev/mtd3 bs=2048 count=1 | md5sum                  # must equal WD_HEAD_MD5
dd if=/dev/mtd3 bs=131072 count=833 | md5sum              # must equal WD_IMG_MD5 (about 30 s)
```

If either differs, do not edit the pins from a guess: put your own values in from your own two matching off-box dumps,
then prove the stock branch from RAM on your unit before anything is written. The belt read costs about 24-37 s on every
stock boot, only while mtd3 is still WD's.

## The lines that differ from the image we proved

The image on our unit was built from these files with three lines of `stage2.sh` different, all for publication: the
rescue fallback address (`STATIC_IP`, used only when rescue gets no DHCP lease within 6 rounds) is our LAN's in our image and
the documentation address `192.0.2.101` here (the code line and its comment), and one comment named a person. **Set
`STATIC_IP` to a free address on your LAN before building.** `restore-stock.sh` differs from ours in two comment lines only.
Your image will not be byte-identical to ours anyway (`debugfs` stamps inode times), so check its content with
`../e2walk.py` as in [../README.md](../README.md), step 6: against v1, the diff must be `/ex4/stage2.sh` changed and
`/ex4/restore-stock.sh` added.

## What the busybox must be

The UBI branch needs `ubiattach -O 2048` (WD's NAND puts the VID header at 2048). **Upstream busybox 1.36.1's `ubiattach`
rejects `-O`** (the option is only in `ubimkvol`'s option string): with a stock busybox every boot of an installed box goes to
rescue. We patched that one getopt string in our static busybox and pass `/dev/ubi_ctrl` (busybox's applets require it) on
every call. Check yours under qemu or on the box (from RAM) before you trust it: `busybox ubiattach /dev/ubi_ctrl -m 3 -d 3 -O 2048`
must not print `invalid option`.

## Test mode (the only way to aim either script at another MTD)

`stage2.sh --test-mtd N` / `restore-stock.sh --test-mtd N SRC`: N >= 7 and `/sys/class/mtd/mtdN/name` not one of WD's seven
names (a nandsim / mtdram device). A boot cannot set it: rc.sh calls `/ex4/stage2.sh` with no arguments, and neither script
reads an environment variable. stage2 test mode never touches the network: its rescue exits 3.

## Rescue: how to put WD back (the rescue prints this into `/ex4/stage2.log` and dmesg too)

```
telnet <box> 23                                   # no password; only while the box is in rescue; LAN only
/ex4/busybox sed 's/^ARMED=0$/ARMED=1/' /ex4/restore-stock.sh > /tmp/restore-armed.sh     # the owner's decision
/ex4/busybox wget -O - http://HOST:PORT/mtd3.dd | sh /tmp/restore-armed.sh -             # or: /ex4/busybox nc HOST PORT | sh ...
reboot
```

Run it unarmed first (`| sh /ex4/restore-stock.sh -`): it stages + verifies the input and writes nothing. In rescue U-Boot
hands the kernel a placeholder MAC address, so the DHCP lease may not be the address your box usually has: find the box by
looking for port 23 on your LAN. The telnet shell has no password: it exists only while the box is already broken, and only on
a LAN you trust.

Comments in these scripts cite our internal design notes (B1, C2, MAP-...), which are not published; what they taught is in
[../../docs/LESSONS-2026-11.md](../../docs/LESSONS-2026-11.md).
