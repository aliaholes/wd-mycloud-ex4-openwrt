# Installing to flash: the plan, and how far it has got

> **STATUS: install in progress Nov 27 2026, on ONE unit (ours).** Steps 2-4 ran Nov 26 (`mtd2` holds the v1 stage-2
> ramdisk; the box boots through real U-Boot into WD's system as before). The modern system for `mtd3` is now BUILT
> ([persist/](persist/README.md)) and proven from RAM against a simulated `mtd3` under both kernels ([c4/](c4/README.md));
> the two flash writes that install it (D1: stage2 v2 into `mtd2`, D2: the UBI into `mtd3`) are being made on our unit now.
> No other unit has any of this. What each proof covers and does not: [docs/LESSONS-2026-11.md](docs/LESSONS-2026-11.md).
> This page is the plan for a permanent install and an honest account of which steps have run. Read it as a map
> of the risks, not as instructions to follow. Everything else in this repository runs from RAM and goes away
> with a power cycle; **the flash write described here does not.**

The trial in the main [README](README.md) runs from RAM and needs no install. A permanent install would let the
box boot a modern system by itself. This page says how we plan to do that with the least risk we know of, what
has been proven, and what can still turn the box into a brick.

## The idea: change ONE partition, keep WD's U-Boot and kernel

WD's flash layout (from the stock firmware's own boot log; the `mtd` numbers are NOT in address order):

| mtd | name | size | does the install touch it? |
|---|---|---|---|
| mtd0 | u-boot | 1 MiB | **never** |
| mtd1 | uImage (WD's kernel 3.2.40) | 5 MiB | **never** (the plan keeps WD's kernel) |
| **mtd2** | **ramdisk** | **5 MiB** | **step 3 (v1), then D1 (v2, the belt).** WD's own ramdisk + `/ex4` + one line in `rc.sh` ([stage2/](stage2/README.md), [stage2/v2/](stage2/v2/README.md)) |
| mtd3 | image (WD's system) | 205 MiB | step D2 only, after stage2 v2 is in `mtd2`: becomes UBI with an `ex4boot` volume (kernel set + `tries`) and an `ex4data` volume (settings), [persist/](persist/README.md), written by [box/ex4-mtd3.sh](box/ex4-mtd3.sh) |
| mtd6 | reserve | 5 MiB | never |
| mtd4 | rescue firmware (holds the unit's identity: WD's two MAC addresses) | 15 MiB | **never** |
| mtd5 | config | 20 MiB | never |

Once `mtd2` holds the stage-2 ramdisk, every boot still goes U-Boot -> WD's kernel -> our ramdisk, and the one
added line runs `/ex4/stage2.sh`. While `mtd3` is still WD's image, the script returns and the box boots
stock exactly as before. Only when `mtd3` is UBI (D2) does it load the modern kernel. v2 returns to WD only when `mtd3`
POSITIVELY is WD's image (the belt, below); anything else takes our branch, whose every failure is the rescue shell.

The write itself uses the same two commands WD's own updater uses (`flash_eraseall` + `nandwrite`), through
[box/ex4-install.sh](box/ex4-install.sh), which erases, writes, reads back, compares, and puts the backup back by
itself on a mismatch. It never reboots. The dangerous window is about one minute in which the power must not go.

## box/ex4-install.sh

It runs on the stock firmware, as root. **It ships with `ARMED=0`: in that state `write` and `restore` refuse
before any flash command.** The only device it can write is the constant `/dev/mtd2`.

```
sh ex4-install.sh plan          read-only: runs every wall and says what write would do   (DEFAULT)
sh ex4-install.sh backup DIR    read-only on flash: dumps mtd2 twice, the md5s must agree
sh ex4-install.sh write DIR     REFUSED while ARMED=0
sh ex4-install.sh restore DIR   REFUSED while ARMED=0
```

Its walls, in order: (1) the target is `/dev/mtd2` and nothing else; (2) the exact firmware (WD 2.12.127's
kernel version string), an EX4, and WD's flash layout; (3) `mtd1` holds WD 2.12.127's kernel, the one U-Boot will
pair with the new ramdisk; (4) the image is next to the script, matches its `.md5` sidecar, is a uImage and fits;
(5) no bad block inside `mtd2`; (6) **this exact image has already booted from RAM on this unit** (its md5 in a
file `STAGE2-PROVEN` next to the script). `write` also needs a backup of `mtd2` that still matches the flash.

What has run, on our one unit: `plan` (it passed walls 1-5 with the current image, and wall 6 after the RAM proof);
`write` once to its `ARMED=0` refusal; then on Nov 26 2026 `backup`, and an armed `write` from a copy (it wrote `mtd2`, read
back equal). `restore` has never run anywhere.

## box/ex4-mtd3.sh (phase D2)

Runs on the stock firmware, as root, and ships with `ARMED=0` (`write`, `verify` and `restore` refuse). The only device it
can write is the constant `/dev/mtd3`.

```
sh ex4-mtd3.sh plan          read-only: every wall, and what write would do   (DEFAULT)
sh ex4-mtd3.sh backup DIR    read-only on flash: mtd3 twice (md5s must agree AND equal the pinned dump), keeps its first 0x6820000 bytes
sh ex4-mtd3.sh write DIR     erase + nandwrite -p + read back; on a mismatch writes WD's image back and verifies it. Never reboots
sh ex4-mtd3.sh verify        before any reboot: attach (-O 2048), mount both volumes, md5 every ex4boot file vs MANIFEST, tries 0
sh ex4-mtd3.sh restore DIR   WD's image back and verified
```

Its walls: (1) the constant target; (2) the exact firmware, an EX4, WD's flash layout; (3) WD's kernel in `mtd1`; (4) **stage2
v2 in `mtd2`**: pinned in a file `STAGE2-V2-IN-MTD2` beside the script, on the list `S2_UBI_PROVEN` (md5:length of a v2 whose
UBI branch was proven), with its marker `STAGE2-V2-PROVEN-<first 8 of md5>` beside it; v1, the stock ramdisk and the two v2
builds whose busybox rejects `-O` are refused by name; (5) the image: its md5 sidecar, `UBI#`, whole blocks, ending before
the bad block; plus the backup and read-back walls. **Every pin in it is OUR unit's** (the mtd3 dump md5, the bad block
1501, our proven v2 image): on your unit it refuses until you replace them with your own, from your own dumps and your own
RAM proofs. Its off-box test is `tests/mtd3/sim-w4.py` (fake flash as regular files; it refuses any path under `/dev`).

## The steps, and where each one stands

| Step | What | Status |
|---|---|---|
| 0 | **Two off-box copies of the whole stock flash** (every `mtd`, plain `dd` and `nanddump` with the out-of-band bytes), md5-checked at the far end | done on our unit (we hold two copies). Yours: your job, before anything else |
| 0 | Build the stage-2 ramdisk from your own stock ramdisk ([stage2/README.md](stage2/README.md)) | done on our unit |
| 1 | **Prove the stage-2 ramdisk from RAM**: WD's kernel boots it through `ex4boot`, `stage2.sh` takes the "continue stock" branch, WD comes up normally. No flash write | **PROVEN on our unit, for our image** (Nov 26 2026). The tools that did it are not published yet, so you cannot repeat this step with this repository today |
| 2 | Back up `mtd2` on the box (`ex4-install.sh backup`), copy it off, check it equals your step-0 dump | done on our unit (Nov 26 2026) |
| 3 | **THE FLASH WRITE.** Set `ARMED=1` (a one-line edit), `ex4-install.sh write DIR`. Daylight, someone at the plug, ideally a UPS | **done on ONE unit (ours, Nov 26 2026)**: erase + write + read-back took 6 s; read-back, full-partition md5, ECC and the other partitions all checked by hand before any reboot |
| 4 | Reboot and prove the hook through real U-Boot: WD must come up exactly as before | **PROVEN on our unit** (Nov 26 2026): U-Boot loaded the ramdisk from `mtd2`, `stage2.sh` logged `mtd3 is not UBI` once, WD came up with its RAID, data volume and daemons as before |
| 5 | Build stage2 v2 (the belt) and the persistent system for `mtd3` ([stage2/v2/](stage2/v2/README.md), [persist/](persist/README.md), `build/build-mtd3.py`) | **built** on our unit's build machine, Nov 26 2026 |
| 5a | Prove them from RAM: v2's stock branch through `ex4boot`; v2's UBI branch, rescue and restore under WD's kernel against a simulated mtd3 (nandsim); the installed system under 6.12 against the same simulation ([c4/](c4/README.md)) | **PROVEN on our unit** (Nov 26-27 2026), no flash written. Not covered: the real NAND driver under 6.12 on the real mtd3, and both kernels sharing one real UBI |
| D1 | **Flash write: `mtd2` <- stage2 v2** (`box/ex4-install.sh`, the step 3 flow; it wants a `STAGE2-PROVEN` file holding the image's md5, written only after your own RAM proof) | **install in progress Nov 27 2026** (our unit) |
| D2 | **Flash write: `mtd3` <- the UBI** (`box/ex4-mtd3.sh backup DIR`, `write DIR`, then `verify` under stock BEFORE any reboot), then reboot into the modern system; it marks a good boot (tries 0) | **install in progress Nov 27 2026** (our unit) |
| E | The array: copy off what you want, re-create it under the modern system (RAID5, superblock 1.2 + bitmap + bad-block log, ext4 64bit + metadata_csum), about 21 h of resync; then NFS | not run |

## The rescue path, worst case last

1. **Before step 3:** a power cycle gives you stock, always. Every RAM trial on our unit came back this way.
2. **After step 3, `mtd3` still stock:** `stage2.sh` returns at once and WD boots as before. If the hook itself
   misbehaves, `ex4-install.sh restore DIR` (armed) puts your backed-up `mtd2` back, with the same walls and the
   same read-back.
3. **After D1 + D2:** any failure, 3 boots without the new system marking a good boot, or a file `rescue` in the
   `ex4boot` volume drops into **the stage-2 rescue shell under WD's kernel**: DHCP (then a static fallback address you set
   at build time) plus a root telnet on port 23, **with no password** (only while the box is already in rescue, and only
   acceptable on a LAN you trust), and `/ex4/restore-stock.sh` to write WD's image back into `mtd3` from your dump over the
   network. The rescue shell has run on our unit (forced, from RAM: lease, telnet, tools, back to stock); `restore-stock.sh`
   has run armed only into a SIMULATED mtd3, never into the real one.
4. **THE DARK BOX: the case none of the above can reach.** If the power goes during step 3's minute, or the new
   ramdisk reads back correctly but U-Boot still fails to boot it, the box will not answer on the network at all.
   Then the only unbrick we know of is **serial**: open the case, attach a 3.3 V USB-TTL adapter (115200 8N1), load
   U-Boot into RAM through the SoC's boot ROM with `kwboot`, and write your `mtd2` dump back. We have NOT done this
   on our unit. Whether U-Boot ever falls back to `mtd4` by itself is unknown. **If you cannot or will not open the
   case and use serial, do not do step 3.**

## Known risks, said plainly

- **U-Boot reading our ramdisk from flash: seen on ONE unit.** Step 4 on ours (Nov 26 2026): U-Boot read and booted
  our header from `mtd2`. One unit is not every unit: a different U-Boot build or NAND could still differ, and the
  dark-box case below still applies to yours. We did it without serial; we do not recommend that.
- **WD's boot can erase its own kernel.** WD's stock ramdisk runs a check (`chk_image`) on every boot. Read from its
  code: when `mtd3` does not hold a valid WD image (size, checksum record or checksum wrong), it runs
  `flash_eraseall /dev/mtd1` and reboots, unless a marker file exists in the config volume. Steps 1-4 are not
  exposed (`mtd3` stays WD's). **D2 is:** if the hook ever returned or failed to run while `mtd3` is not WD's image,
  WD's boot would go on into that check and erase `mtd1`. That is why D1 comes first: stage2 v2 returns to WD only on a
  positive md5 match of WD's image and never otherwise, and `box/ex4-mtd3.sh` refuses to write unless v2 is in `mtd2`.
  A power cut during the `mtd3` erase or write then lands in rescue, not in `chk_image`. The belt's md5s are OUR unit's:
  check yours ([stage2/v2/README.md](stage2/v2/README.md)) or every boot goes to rescue.
- **The stock shell has no `$(( ))` arithmetic** (its busybox was built without it). `stage2.sh` runs under it at
  boot; any edit must pass `sh -n` with the stock firmware's own shell, not only on your computer.
- **One unit, one firmware.** Everything here was seen on one EX4 with WD firmware 2.12.127. The script refuses
  anything else; do not edit that away.

## If you go ahead anyway

You carry the risk (see the warning and the licence in the [README](README.md)). At minimum: two verified off-box
copies of your whole flash; your own RAM proof of your own image; a UPS; daylight; and a serial adapter you have
already tested on your unit. Never share your flash dumps or your built image: they contain WD's firmware and your
unit's identity.
