# Run history on the test unit (Nov 16-26 2026)

All on one WD My Cloud EX4, firmware 2.12.127, four 4 TB disks in a RAID array emptied of data. Times are local.
No RAM trial wrote flash (the trial contains no flash write: README). The one flash write so far is the stage-2 step
of Nov 26 2026, the last row below ([INSTALL.md](../INSTALL.md), steps 2-4). "Back" means WD's stock firmware
answered ssh again.

| Run | Payload | Loader | Watchdog | Result | How it came back |
|---|---|---|---|---|---|
| 1 | OpenWrt 6.12.112 | first build (L2 left on) | no | never seen on the LAN; no log existed yet | power cycle by hand after 30 min |
| 2 | OpenWrt 6.12.112 + disk logger | same, watchdog address fixed | yes | no log on disk, none in RAM | by itself after about 3 min (the first proof that the 21 s watchdog reset works) |
| 3 | WD's own 3.2.40 kernel + ramdisk, a run id added to the command line | same | no | dark for 10 min; WD's start ledger showed no boot | power cycle by hand |
| 4a | same as 3 | same | yes | RAM markers A, C, H intact after the reset: the stub copied everything and RAM survives a warm reset. So the fault was after the copy | by itself |
| 4b | same as 3 | **stub turns the L2 cache off** | no | **handoff proven**: stock came up with the run id in `/proc/cmdline` | it was the payload |
| 5 | OpenWrt 6.12.112 + disk logger | L2-off | yes | **booted to the network**: ssh 62 s after launch, 4 of 4 bays, flash read-only, L2 enabled by 6.12, watchdog adopted | its own reboot after about 23 min |
| 6 | run 5 + `ex4fan` | L2-off | yes | **fan managed**: first frame FAN HIGH acknowledged, 2040 rpm; MEDIUM after 60 s, LOW 30 s later, about 1020 rpm for 20 min; 13 of 13 commands acknowledged; drives 38-41 °C | its own reboot 1332 s after launch |
| 7 | run 6 + xhci modules, the MAC hook, clock read, `DeviceReady`, a second auto-return | L2-off | yes | launched 02:56:42 on Nov 17, ssh 63 s later. **USB 3**: `xhci_hcd` bound to the Etron EJ168, SuperSpeed root hub up. **Clock**: the micro answered `2026-11-17 10:57:03 UTC`, the unset system clock was set from it. **`DeviceReady`** acknowledged at the first try. Fan as in run 6: 87 of 87 commands acknowledged, about 1050 rpm at LOW, drives 38-40 °C. **MAC addresses: not read** ("nothing readable in flash"): the port with the cable got a derived address, the bridge kept the unit's first one and the same DHCP lease. **Link flap measured**: 2329 carrier changes in 1237 s | its own reboot; stock answered 1424 s after launch |
| 8 | run 7 + WD's flash layout in the device tree + both PHYs on the generic PHY driver; **the first bundle built by `build/build.sh`** | L2-off | yes | launched 03:48:27 on Nov 17, ssh 62 s later. **Link steady**: eth1 carrier changes stayed at 1 (the first link-up) from 46 s to 1258 s of uptime, 0 `link down` lines (run 7: 2329 changes). **MACs**: eth0 and eth1 got WD's own two consecutive addresses, read from `rescue firmware` at 0x0dd00000. Both PHY chips answer id `0141.0dd1` on page 0. Fan 1011-2010 rpm, 2 of 2 fan commands acknowledged; USB 3 bound; clock set from the micro; `DeviceReady` acknowledged | its own reboot after 1347 s |
| 10 | v7's own kernel (OpenWrt 25.12.6 built from source, Linux 6.12.112) | not recorded here | not recorded here | Nov 17 2026: **both XOR engines probed**; idle CPU 5.0% (the official kernel's run: 13.5%); network receive 54.9 MiB/s; LAN TCP port 22 only. Writing to the array was not measured (README, "v7, v8 and v9") | not recorded here |
| stage 2, RAM | WD's own kernel + the stage-2 ramdisk (md5 `d2c6d5e629e105feab45725ffa3611bf`), handed over by `ex4boot`; no flash write | `ex4boot` | not recorded here | Nov 26 2026: `/proc/cmdline` carried the run id; `stage2.sh` logged exactly one line, `ex4-stage2: mtd3 is not UBI (stock firmware image): continuing the stock boot`; WD's own boot ran on (its file system check after an unclean stop, RAID `[UUUU]`, the same daemons as before); the u-boot, kernel, ramdisk and identity partitions had the same md5 before and after ([stage2/README.md](../stage2/README.md)) | by itself, as stock, in about 2 minutes |
| stage 2, flash | `mtd2` written with that stage-2 ramdisk: `ex4-install.sh backup`, then an armed `write` from a copy of the script (erase + write + read-back in 6 s, read back equal; read-back, full-partition md5, ECC and the other partitions checked by hand before any reboot) | none: a reboot through WD's own U-Boot | not recorded here | Nov 26 2026: U-Boot loaded the ramdisk from `mtd2`, `stage2.sh` logged `mtd3 is not UBI` once, WD came up with its RAID, data volume and daemons as before ([INSTALL.md](../INSTALL.md), steps 3-4) | a normal stock boot |

Other runs are not in this table: runs 11 and 14 to 18 are named in [RWBENCH.md](RWBENCH.md) and
[build/v9/README.md](../build/v9/README.md) (the read-write bench and its kernel twins); this file has no record of
runs 9, 12 and 13.

After runs 1 to 8: RAID arrays `[UUUU]`, no resync. After run 4a (an unexpected reset) stock ran a file-system
check on the data volume for about four minutes before mounting it.

What each failure taught:

- Run 1: a trial needs a black box. Hence the disk log, the RAM markers and the launch log.
- Run 2: "no trace" is not "did not run": a kernel reset by the watchdog while still decompressing leaves nothing.
- Runs 3 and 4a: testing the loader with a kernel known to be good (WD's own) separates "the jump is broken" from
  "the new kernel is broken". With the markers it showed the copy was fine and the fault came after it.
- Run 4b: the L2 cache (README, "the lesson").
- Run 7, the MAC addresses: the device tree had WD's last three flash partitions in address order; WD numbers
  them otherwise (`reserve`, mtd6, lies below `rescue firmware`, mtd4). The names and sizes in `/proc/mtd` were
  right, the offsets were not, and the kernel's `rescue firmware` started with WD's `reserve`. Every test until
  then had faked the partition with a file that began at the identity block. A test now compares the compiled
  tree with the stock kernel's own partition table, and another cuts real dumps the way the tree does.
  ([HARDWARE.md](HARDWARE.md), "Flash layout".)
- Runs 5 to 7, the link flap: once a second, for three runs, before we counted it. The cause is in
  [HARDWARE.md](HARDWARE.md), "The link flap".
- One mistake of ours worth knowing: reading a disk sector that turned out to be bad made the stock kernel spend
  minutes in ATA error handling. That is why a bay can be kept out of the log (`LOG_SKIP_PORT`).
- The stock shell is a busybox without arithmetic, `setsid`, `which` or `stty`, and its awk (1.20.2) parses
  `name (expr)` as a function call. `ex4-trial.sh` is written for exactly that shell; `tests/trial-logic.sh` can
  run its awk programs on the stock busybox under qemu-arm.

Not yet run on hardware when this was written: everything listed under "in the tree but has NOT run on real
hardware yet" in the README.
