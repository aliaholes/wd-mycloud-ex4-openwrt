# Run history on the test unit (Nov 16-17 2026)

All on one WD My Cloud EX4, firmware 2.12.127, four 4 TB disks in a RAID array emptied of data. Times are local.
No run wrote flash. "Back" means WD's stock firmware answered ssh again.

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

After every run: RAID arrays `[UUUU]`, no resync. After run 4a (an unexpected reset) stock ran a file-system
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
