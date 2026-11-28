# persist/: the INSTALLED system ("persist-v1"), the one that lives in `mtd3`

This folder builds the modern system an install puts into `mtd3`: the kernel set `stage2.sh` boots (`kernel.bin`, ATAGs,
`initrd.cpio`, `EXPECT`, `ADDRS`, the `tries` counter) in a UBIFS volume `ex4boot`, and the box's own settings in a second
small UBIFS volume `ex4data`. Read [../INSTALL.md](../INSTALL.md) and [../docs/LESSONS-2026-11.md](../docs/LESSONS-2026-11.md)
first. **This writes flash only through `../box/ex4-mtd3.sh` (ships `ARMED=0`), never by itself.**

## Status, plainly (one unit, ours)

| What | Status |
|---|---|
| Built off the box (our image: `mtd3.ubi` md5 `547b8337cf349d8b8a11e3a8c8eaae17`) | done Nov 26 2026; the off-box sims pass (`tests/`) |
| Under WD's 3.2.40 against a simulated mtd3 (nandsim): attach, both volumes mount, tries 0 -> 3 -> rescue | **proven** Nov 26-27 2026 (stage2 v2 r4, see `../stage2/v2/README.md`) |
| Under OpenWrt 6.12 from RAM, against the same simulated NAND (the C4 trial, `../c4/`) | **proven** Nov 27 2026: first-boot seed, mark-good 1 -> 0 read back, no auto-return, the stored config restored on the next boot, safe mode at tries 2, the not-good deadman reboots by itself |
| Written to the real `mtd3`, booted from flash | **install in progress Nov 27 2026** (phase D2 in INSTALL.md) |

What C4 does NOT prove: the real NAND driver under 6.12 on the real `mtd3` (C4 ran on nandsim with mtd3's geometry), and
3.2.40 and 6.12 taking turns writing the SAME UBI (each was seen reading the image as built and its own writes back).
Both are first seen at D2.

## What the installed system does at boot

- **No auto-return.** The trial's 20-minute reboot to stock, its deadman-to-stock and the read-write bench are taken out.
- **The tries counter.** stage2 (in mtd2, under WD's kernel) writes `tries = N+1` into `ex4boot` before every jump and refuses
  to jump at 3 (rescue: telnet, LAN). `ex4-markgood` (S98) writes `tries = 0` once the box is REACHABLE (br-lan has IPv4 AND
  sshd listens on 22, three checks 10 s apart), and reads it back.
- **The not-good deadman** (`ex4-notgood`, S04): no good mark within 10 minutes with carrier = reboot, so tries climbs.
- **Safe mode** (tries >= 2): the stored `/etc/config` is NOT used and nothing is written to the store (image defaults: DHCP,
  key-only ssh). The stored config is left for a person to fix.
- **What persists** (`ex4-persist`, an allow-list): `/etc/config/*` (bind-mounted live from `/ex4data`), dropbear's HOST keys
  (never `authorized_keys`: the image's key is the only key), the HTTPS cert, `/etc/ex4/smtp-pass`, `/etc/ups-watch/*`.
- **SERVICE MODE** (`ex4-svc`, `/etc/config/ex4svc`, **`enabled '1'` in this image**): behind THE RECOVERY WALL (the
  read-only checks of `ex4-md-ro`: 4 SATA members, raid5, one UUID, equal events, nothing rebuilding or reshaping) it assembles
  `md1` **read-write**, sets the measured knobs, mounts ext4 rw at `/mnt/md1` and serves NFSv3 (exports only from
  `/etc/config/ex4`). SMB stays off. **On first boot your existing WD array is mounted read-write.** If that is not what you
  want, set `enabled '0'` in `files/etc/config/ex4svc` before you build.
- The **install DTB** (`install.dtsi`): every flash partition read-only except `image` (mtd3). `mkpersist.py` proves the
  compiled DTB differs from the trial DTB by exactly that one line.
- The UPS watcher is in the image and off (`files/etc/ups-watch/ups-watch.conf.example`); smartd only logs.

## Building it

`mkpersist.py` takes a v9 bundle that has already booted on your unit (its kernel and its proven overlay, both pinned by md5)
and makes `kernel.bin` (that zImage + the install DTB) and `overlay.cpio` (the proven overlay, entry by entry, with the trial's
self-return taken out and `files/` added). Then `../build/build-mtd3.py build` makes `mtd3.ubi` (UBIFS format 4: a newer format
mounts read-only under WD's 3.2.40; `ex4boot` uncompressed, `ex4data` zlib; ubinize -p 128KiB -m 2048 -s 512 -O 2048) and
`build-mtd3.py check` re-reads every PEB and rebuilds every file from its nodes. The builders refuse to write outside
`~/ex4-build/finalize/` (make that folder; it is a self-imposed wall, not a requirement of the tools they call).

**The pins are ours, so as published this is a reference, not a recipe you can run unchanged.** `mkpersist.py` refuses any
base bundle, zImage or UPS-watcher source whose md5 is not the one we booted. That is on purpose: you build from YOUR booted
bundle, and you change the pins only after reading each gate. The UPS watcher's two source files (`ups_watch.sh` and its
OpenWrt init script, the `--ups DIR` input) are not in this repository yet.

## Known issue, not fixed (F5)

In `files/usr/sbin/ex4-persist`, `T=$(read_tries)` also captures `read_tries`' own log line. On one failure path only (the
`ex4boot` volume does not mount read-only) `T` is not a number, the safe-mode test errors out as false, and the boot goes on
as attempt 0 (the stored config is restored instead of safe mode). It was never hit on the box. The fix changes the image,
so it waits for a rebuild.

## Tests (off the box, fake devices)

| File | What |
|---|---|
| `tests/sim-persist.sh` | ex4-persist, ex4-markgood, ex4-svc, the timeout shim and the uci-defaults against fake devices (`bash sim-persist.sh files WORK dash`) |
| `tests/strict-ubi-forms.sh` + `tests/fakes/ubi-strict` | the same with STRICT fakes of mtd-utils' `ubiattach`/`ubidetach` (the real option strings). A fake that accepts any arguments let a real bug through once (see LESSONS) |

Comments in these files cite our internal design notes (FINALIZE-PLAN B2, C4 ...), which are not published.
