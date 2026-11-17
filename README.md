# OpenWrt on the WD My Cloud EX4, from RAM, with the case closed

> ## WARNING / DISCLAIMER: read this before anything else
>
> **This was tested on ONE unit.** A WD My Cloud EX4 (the original 4-bay Kirkwood model, WD codename
> "Lightning 4A"), running exactly this:
>
> | What | The version we saw on the one test unit |
> |---|---|
> | WD firmware | **2.12.127** |
> | Stock kernel | `Linux version 3.2.40 (kman@kmachine) (gcc version 4.6.4 20120731 (prerelease) (Linaro GCC branch-4.6.4. Marvell GCC 201301-1645.aee66e26) ) #1 Fri Nov 16 11:50:03 CST 2018` |
> | U-Boot | 1.1.4 (Aug 14 2013), `Marvell version: 3.5.9.LIGHTNING-4A.01` |
> | SoC / RAM / flash | Marvell 88F6282 (CPU Feroceon 88FR131 rev 1), 512 MiB, 256 MiB Samsung NAND |
> | Disks | four WD40EFRX (4 TB), partitioned by WD's firmware |
>
> **We do not know what version your unit runs.** Other firmware versions, other hardware revisions, other disks,
> or a unit that merely looks the same (EX2, EX2 Ultra, EX4100, PR4100 and DL4100 are different machines) may
> behave differently. `ex4-trial.sh` checks for the firmware above and **refuses to run on anything else**. Do
> not edit that check away: the loader jumps to addresses that exist only in this exact stock kernel.
>
> **It runs from RAM only, and it is still at your own risk.** Nothing here writes the NAND flash: no step, no
> script and no program in this repository contains a flash write, and the device tree the new kernel gets marks
> every flash partition read-only. A power cycle brings the stock WD system back. But a kernel module is loaded
> into WD's kernel, your data volumes are remounted read-only and the machine is taken over while it runs. An
> unclean return can make the RAID resync or the stock system check its file system for minutes. The trial also
> **writes one 2 MiB log into an unused disk partition** (see [SAFETY.md](SAFETY.md), "The one disk write").
>
> **Security fix, Nov 17 2026:** bundles built before that date left the trial's web server open to the LAN with
> no root password. If you built one, rebuild before running it again. Details: [SAFETY.md](SAFETY.md), "SECURITY NOTE".
>
> **Back up your data first.** Assume every disk in the NAS could be lost, and do not run this on the only copy
> of anything.
>
> **No warranty of any kind.** This is free software under the GPL, provided "as is", without warranty of
> merchantability or fitness for any purpose (COPYING, sections 11 and 12). If it breaks your NAS, your data or
> your network, that is yours to carry.
>
> **Not affiliated with WD.** This project is not made, endorsed or supported by Western Digital, and it is not
> an official OpenWrt port either. Do not ask them for help with it.

## What this is

A way to boot a current Linux (OpenWrt 25.12.6, kernel 6.12.112) on a WD My Cloud EX4 **without opening the case,
without a serial cable and without writing flash**. WD stopped updating this NAS years ago; its last firmware runs
a 2013-era kernel 3.2.40.

You get a root shell on WD's stock firmware over ssh, copy one folder to the data volume, and run one script. The
script loads a small kernel module (`ex4boot`) into WD's kernel. The module puts the new kernel into RAM, shuts
the old kernel down and jumps. About a minute later the box answers ssh again as OpenWrt, running entirely from
RAM. After 20 minutes it reboots itself back to WD's firmware unless you tell it to stay. Pull the plug at any
time and you are back on stock too.

**It is a trial boot, not an installation.** Nothing persists. That is the point of this first release: it lets
EX4 owners (and anyone porting OpenWrt or Debian to this board) run and debug a modern kernel on the real
hardware with a way back that needs no tools. A permanent install is the next step and is not in here.

## What works (seen on the test unit)

| | Evidence |
|---|---|
| The jump out of WD's kernel | Run 4b, Nov 16 2026: WD's own kernel restarted through the loader; the run id we put on the new command line showed up in `/proc/cmdline` |
| OpenWrt 25.12.6 / Linux 6.12.112 boots from RAM | Run 5, Nov 16 2026: key-only ssh login 62 s after the launch; `Linux ex4-trial 6.12.112 armv5tel`; 509 MB of RAM seen; no error lines in dmesg |
| All four drive bays | Run 5: `sata_mv` found 4 of 4 disks at SATA 3.0 Gbps |
| Flash is read-only under the new kernel | Run 5: all seven MTD partitions without the writeable flag; the one known bad block reported as before |
| Gigabit Ethernet, DHCP client | Runs 5 to 8: 1000 Mb/s link, same DHCP lease as under stock. Run 8, Nov 17 2026: **a steady link** (one carrier change, the first link-up, in 21 minutes; runs 5 to 7 flapped about twice a second, see "The link flap" in docs/HARDWARE.md) |
| The unit's own two MAC addresses | Run 8: eth0 and eth1 got WD's own pair (two consecutive addresses), read-only from the `rescue firmware` partition at WD's offset; the DHCP lease kept the first |
| A bundle built by `build/build.sh` | Run 8 was the first bundle produced by this repository's own build script, and every result in this table from run 8 came from it |
| Watchdog as the automatic way back | Run 2 and 4a: a failed boot was reset after 21 s and stock came back by itself. Runs 5 to 7: 6.12 took the running watchdog over |
| The fan | Run 6, Nov 17 2026: our `ex4fan` drove the front-panel microcontroller for 20 minutes: 13 of 13 commands acknowledged, 2040 rpm at HIGH down to about 1020 rpm at LOW (stock's own idle speed), drives at 38 to 41 °C |
| Drive temperatures | Run 6: SMART attribute 194 through `sata_mv` |
| USB 3 controller | Run 7, Nov 17 2026: `xhci_hcd` bound to the Etron EJ168 (PCI 1b6f:7023) with the modules taken from the official OpenWrt image for the Zyxel NSA325; a SuperSpeed root hub with two ports came up. No device was plugged in, and there is no usb-storage module, so a USB disk would be listed, not usable |
| The clock | Run 7: the board has no working SoC RTC (stock has none either). `ex4fan` read the front-panel micro's clock (`2026-11-17 10:57:03 UTC`) 6.7 s after kernel start and set the system clock from it, which was still unset. It never writes the micro's clock |
| "System ready" to the front panel | Run 7: WD's `DeviceReady` frame, sent once, acknowledged at the first try |
| The way back | Nine jumps on the test unit, four of them failures while the loader was being debugged. Every one ended on the stock system with the RAID clean: two by the watchdog, two by a power cycle by hand, five by the trial's own reboot. After the first failure the md5 of the U-Boot, kernel, ramdisk and identity partitions equalled the dumps taken before; the script re-checks the kernel partition's md5 before every run |

## What is in the tree but has NOT run on real hardware yet

- **Button presses written to the log** (no button does anything). Nobody pressed one in runs 7 or 8.
- **`ex4phy`** ran in run 8 (it read both PHY chips: id `0141.0dd1`, register page 0); listed here only because it is new.

## What does not work

- **It is not installed.** RAM only; every reboot is WD's firmware again.
- **The PHY temperature sensors.** The link-flap fix hands both Ethernet PHYs to the kernel's generic PHY driver
  (the Marvell driver switched the 88E151x to its fibre register page on every poll, and the Kirkwood MAC read
  "no link" there: 2329 carrier changes in 20 minutes in run 7). The generic driver does not expose the PHYs'
  temperature sensors. A proper kernel fix that keeps the Marvell driver is future work. Details:
  [docs/HARDWARE.md](docs/HARDWARE.md), "The link flap".
- **Your RAID is not assembled.** The trial sees the four disks; the stock OpenWrt image has no mdadm and this
  release adds none. Nothing mounts your data.
- **LEDs, LCD, buttons.** Mapped (see [docs/HARDWARE.md](docs/HARDWARE.md)), not driven. The front panel shows
  whatever stock left there. No button is acted on.
- **Both LAN ports are bridged without spanning tree.** Use ONE cable. The script refuses two live cables.
- The kernel still prints `rtc-mv: internal RTC not ticking`; the SATA-board thermistor read 0 on our unit.

## Run it

Read [SAFETY.md](SAFETY.md) first. You need a Linux computer on the same LAN and a root shell on the NAS's stock
firmware.

### 1. Build the bundle (on your computer)

```sh
ssh-keygen -t ed25519 -f ~/.ssh/ex4-trial -C ex4-trial      # your OWN key, made for this; never reuse ours (there is none)
sh build/fetch.sh dl                                         # 3 downloads; WD's GPL bundle (1.1 GB) you fetch yourself; all 4 checked by sha256
sh build/build.sh --pubkey ~/.ssh/ex4-trial.pub --dl dl      # a few minutes; writes out/bundle/
bash tests/run-offbox.sh --bundle out/bundle --work work     # optional: the off-box tests against what you built
```

`build.sh` lists the packages it needs in its header (an ARM cross gcc, `dtc`, `python3`, `make`). Nothing is
downloaded at build time, and no binary is shipped in this repository: the OpenWrt kernel comes from
downloads.openwrt.org, the loader is compiled against WD's own GPL kernel source, and the hashes are pinned in
`build/SOURCES.sha256`. WD's GPL bundle for firmware 2.12.127 (`WDMyCloud_EX4_GPL_v2.12.127_20181219.tar.gz`) is
the one file `fetch.sh` does not download: we have no link to it that we could verify, so get it from WD's support
site and put it into `dl/`; `fetch.sh` then checks it against the hash of the file we built with.

The build is reproducible as far as we tried: with Ubuntu 24.04's `arm-linux-gnueabi-gcc` 13.3 and `dtc` 1.7.0 on
an arm64 host, `build.sh` gives the same `ex4fan` (md5 `dd3a5887cb7f5e4089cf372d235607ef`), `ex4log`
(`9c1cf806467dbbea6b6e372cd807fcca`) and `ex4peek` (`011211d3777d73e6c8ba86f715670c8a`) that ran on the test unit.
Another compiler version will give other bytes; the tests in `tests/` are what tell you whether they behave.

### 2. Copy it to the NAS's data volume

The bundle must live on the data volume (not in `/tmp`): the logs it leaves have to survive the jump. On the test
unit the first volume is `/mnt/HD/HD_a2`. This firmware's ssh server is old and needs old algorithms switched on
in a modern client:

```sh
OLD='-o HostKeyAlgorithms=+ssh-dss -o PubkeyAcceptedAlgorithms=+ssh-dss -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 -o Ciphers=+aes128-cbc,3des-cbc'
ssh $OLD root@<nas-ip> 'mkdir -p /mnt/HD/HD_a2/ex4-openwrt'
tar -C out -cf - bundle | ssh $OLD root@<nas-ip> 'tar -C /mnt/HD/HD_a2/ex4-openwrt -xf -'
```

### 3. Check, dry-load, go (on the NAS, as root)

```sh
cd /mnt/HD/HD_a2/ex4-openwrt/bundle
sh ex4-trial.sh check wdt        # reads only. Is this the exact firmware? Is the bundle intact? Is the log partition unused?
sh ex4-trial.sh load-dry         # loads the module with dryrun=1, compares checksums in RAM, unloads. Cannot boot.
cd / && nohup sh /mnt/HD/HD_a2/ex4-openwrt/bundle/ex4-trial.sh go wdt
```

Stop at the first `REFUSED`. Every refusal says why, and none of them is a bug to work around.

`go` remounts the data volumes read-only, takes the network down and jumps; your ssh session goes silent. `wdt`
arms the SoC's 21-second watchdog just before the jump: if the new kernel hangs, the box resets and stock comes
back by itself. Use it. (The stock shell has no `setsid`; `nohup` on that last command is what keeps it alive
when the session drops. Do not put it in the background with `&`.)

### 4. Log in to the trial

After about a minute:

```sh
ssh -i ~/.ssh/ex4-trial -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@<nas-ip>
cat /tmp/ex4-selftest.txt        # bays, NICs, flash layout + flags, USB, temperatures, fan, clock, PHYs, link changes
cat /tmp/ex4fan.status           # fan level, rpm, drive temperatures, whether the micro answers
touch /tmp/ex4-stay              # only if you want it to stay past the 20-minute auto-return
```

The trial takes a DHCP lease; it usually gets the address the NAS had. If not, look in your router for the host
`ex4-trial`. `host/ex4-watch.sh` can watch the LAN for you and record what it saw.

### 5. Go back to stock

- `reboot` inside the trial, or
- wait: it reboots itself 20 minutes after boot unless `/tmp/ex4-stay` exists, or
- **pull the power plug and put it back.** This always works. The flash was never written, so the box boots WD's
  firmware exactly as before.

After an unclean return stock checks its data volume before it mounts it (about four minutes on our unit). Then:

```sh
sh /mnt/HD/HD_a2/ex4-openwrt/bundle/ex4-trial.sh verdict
```

prints one line (`MODERN KERNEL BOOTED (how far: ...)`, `HUNG AFTER THE JUMP: ...` or `INCONCLUSIVE: ...`) from
what the run left behind: the disk log, the kernel log still in RAM after a warm reset, the launch log.
If you report a result, include that output and your firmware version.

## How the loader works, and the lesson that cost us three runs

WD's kernel has no kexec. `ex4boot` is a small kexec of its own, built against WD's own kernel source:

1. It reads the segments (new kernel with the device tree appended, an ATAG list, the overlay archive, three RAM
   markers) into kernel memory and reports a CRC32 of each, which the script compares with the bundle's.
2. On `echo boot > /proc/ex4boot` it does what a reboot does (device shutdown), turns interrupts off, adds a 1:1
   mapping of low memory, flushes and disables the caches, and branches to a small position-independent stub
   through that 1:1 mapping, so the stub already runs at its physical address when it switches the MMU off.
3. The stub copies each segment to its final physical address and jumps to the kernel with `r0 = 0`, the machine
   id in `r1` and the ATAG list in `r2`, which is what U-Boot would do.

It needs three functions WD's kernel does not export; the script takes their addresses from `/proc/kallsyms` and
the module refuses unless the instruction at each address is the one this kernel build has there.

**The L2 cache lesson.** The first two attempts at the new kernel died without a trace, and so did a third with
WD's own kernel as the payload. The Feroceon CPU has an L2 cache. U-Boot starts a kernel with the L2 **off**.
WD's kernel turns it on and offers no way to turn it off again, so our first loader jumped with the L2 on and
still holding the old kernel's cache lines for the very addresses the new kernel was being copied to. Mainline's
decompressor does not touch the L2, and mainline's cache driver, finding it already on, only prints a warning and
keeps it. The fix is nine instructions in the stub: after the MMU is off, clean the L2, clear its enable bit,
invalidate it, which is the state U-Boot hands over. With that, WD's kernel restarted through the loader (run 4b)
and 6.12 booted on the first try (run 5). If you write a kexec-style loader for any Feroceon/Kirkwood box: hand
over with the L2 off.

Two more things this firmware taught us: WD's kernel maps the SoC's registers at virtual `0xfed00000` (our first
build wrote the watchdog through the physical address and would have crashed the box); and it uses 32 KiB software
pages, so
a static ARM program for the stock side must be linked with `-Wl,-z,max-page-size=0x8000` or it is killed at exec.

More: [docs/LOADER.md](docs/LOADER.md).

## The front-panel microcontroller (fan, clock, buttons)

The EX4's fan is not on a SoC pin. A microcontroller on the front panel drives it and talks to the SoC over the
second UART (`/dev/ttyS1`), **19200 baud, 8N1, no flow control**. Frames are 7 bytes, `FA b1 b2 b3 b4 b5 FB`.

| Direction | Frame | Meaning | State |
|---|---|---|---|
| host → micro | `FA 02 00 0N 00 00 FB` | fan speed N: 1 low, 2 medium, 3 high, 4 highest (0 = stop) | 1 to 4 **used on the real unit**, acknowledged 13 of 13. `ex4fan` cannot send 0 |
| host → micro | `FA 03 08 01 00 00 FB` / `FA 03 08 02 00 00 FB` | read thermistor: SATA board / main board | **used on the real unit** |
| host → micro | `FA 03 01 00 00 00 FB` | "DeviceReady": the system is up | **used on the real unit** (run 7), acknowledged |
| host → micro | `FA 01 00 03 01 00 FB` | read the micro's clock | **used on the real unit** (run 7) |
| micro → host | `FA 30 00 00 xx xx FB` | ACK. WD resends a frame every 300 ms, up to 10 times, until it sees one | **seen on the real unit** |
| micro → host | `FA 03 08 0S xx RR FB` | thermistor S, raw value RR (a 192-entry table turns it into °C) | **seen on the real unit** |
| micro → host | `FA 01 00 03 xx SS MM HH DW DD MO YY FB` | the clock: 13 bytes, BCD, UTC | **seen on the real unit** (run 7: `03 57 10 03 17 11 26` = 10:57:03 on 17 Nov 2026, day-of-week field 03) |
| micro → host | `FA 21..` `FA 57..` / `FA 22..` `FA 52..` / `FA 26..` | power button / reset button / USB-copy button | from WD's parser, emulation only |

The fan's speed is not read from the micro: the tachometer is SoC GPIO 39, two pulses per turn.

`ex4fan` can send exactly the eight frames above (fan 1 to 4, two thermistor reads, DeviceReady, clock read). They
sit in one constant table; no frame is ever built from variables. The micro also handles power-off, LEDs, the LCD
and its own firmware upgrade; none of those frames is in the program. If the micro stops answering, the fan reads
0 rpm for 30 s, or a drive reaches 55 °C, `ex4fan` sets the fan to maximum, logs why, and reboots to stock.

The full table, the frames we captured but never send, the event codes, and how each line was established:
[docs/MCU-PROTOCOL.md](docs/MCU-PROTOCOL.md).

## What is where

| Folder | What |
|---|---|
| `loader/` | `ex4boot`: the kernel module and its relocation stub, plus two emulator tests of the stub |
| `dts/` | the device tree for the EX4 (`wd,mycloud-ex4`), written against Linux 6.12's kirkwood includes |
| `userland/` | `ex4fan` (fan, clock, panel), `ex4log` (the black-box disk log), `ex4peek` (read-only: finds the trial kernel's log and our RAM markers in memory), `ex4phy` (read-only: asks the Ethernet PHYs for their id and register page) |
| `box/` | `ex4-trial.sh`, the one script that runs on the NAS |
| `build/` | `fetch.sh`, `build.sh`, and the Python tools they use |
| `host/` | `ex4-watch.sh`, an optional LAN-side witness |
| `tests/` | everything that can be tested without the NAS: several hundred checks, many of them in emulators |
| `docs/` | the protocol, the loader, the hardware map, the run history |

## Helping

The most useful things, in order: a `check wdt` output from a unit with **another firmware version** (it will
refuse; the refusal tells us what differs), a `verdict` from a run on a second unit of the same firmware, a
proper kernel fix for the link flap (so the Marvell PHY driver can stay), and the device tree going upstream. [docs/HARDWARE.md](docs/HARDWARE.md) lists what is still
unmapped.

## Credits and licence

By aliaholes. Written by an AI and tested on one real unit by a human who stayed near the power plug.

Code: GPL-2.0-or-later. Documentation: CC0. Details per folder in [LICENSE](LICENSE). It stands on the work of
the OpenWrt kirkwood maintainers and on the kernel source WD published under the GPL.
