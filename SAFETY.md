# Safety and security notes

Read the warning at the top of [README.md](README.md) first. This page is the detail behind it.

## What can go wrong, and what it costs

| What happens | What it costs | Seen on the test unit |
|---|---|---|
| The script refuses (`REFUSED: ...`) | nothing; nothing was loaded or changed | many times |
| `load-dry` crashes the stock kernel (a module built by a modern compiler in a 2013 kernel) | a power cycle; possibly a RAID resync | never |
| The new kernel hangs, launched with `wdt` | 21 s, then the SoC resets and stock boots by itself | twice |
| The new kernel hangs, launched without `wdt` | the box stays dark until you power-cycle it | twice |
| The fan daemon cannot talk to the front-panel micro, reads 0 rpm, or a drive reaches 55 °C | fan to maximum, then an automatic reboot to stock | in emulation only |
| The trial runs but you cannot reach it | it reboots to stock after 20 minutes by itself (a second timer fires at 22 minutes) | never needed |
| Stock comes back after an unclean stop | it checks the data volume before mounting it (about 4 minutes on our unit); the RAID may resync | the check: yes; a resync: never |

The stock system is never modified: the NAND is not written by anything in this repository, and the device tree
given to the new kernel marks all seven flash partitions `read-only` (the build checks the compiled tree for
that, and so does `tests/dtb_check.py`).

## The one disk write

The trial keeps a black-box log so that a failed boot can be diagnosed afterwards. Its daemon (`ex4log`) writes
**2 MiB, raw, into bytes [1 MiB, 3 MiB) of partition 3 of one SATA disk** (the one on the lowest port), every few
seconds while the trial runs.

On disks partitioned by WD's firmware, partition 3 is a spare of about 1 GiB that the firmware leaves unused
unless you created a volume that spans disks ("JBOD"/linear). On the test unit all four were unused and zeroed.

Walls around that write:

- `ex4-trial.sh` refuses to launch if a partition 3 is mounted, is swap, or is a member of an md array.
- The bundle is built for one exact partition size (`LOG_SECTORS`, default 2098831 sectors, what WD's firmware
  made on 4 TB disks). `check` refuses if yours differs, and the daemon refuses any partition of another size.
- The daemon cannot write outside the 2 MiB window (`tests/ex4log-roundtrip.sh` proves that on a file).

**What the walls cannot know:** whether an unmounted partition 3 of exactly that size holds something you care
about, for example on a disk that was partitioned by a different NAS or by hand. If `check` reports a partition
3 you do not recognise, stop. If your partition 3 has another size, read `build/build.sh`'s header before you
rebuild for it, and make sure the partition is really empty first.

To keep a bay out of it entirely (a disk with bad sectors: ours had one, and reading it stalled the stock kernel
for minutes), build with `LOG_SKIP_PORT` and `LOG_SKIP_PART`.

## SECURITY NOTE, Nov 17 2026: the web door of older bundles

**What was open.** Every bundle built before this date (the build log's "v6" and earlier; on GitHub, every commit
before this note) left OpenWrt's own web server running on the trial system: uhttpd on ports 80 and 443 of
every address, with the LuCI web interface and the `/ubus` door to rpcd. root's password field in the image is
empty, and rpcd's login (which LuCI uses too) treats an empty field as "no password needed". Our overlay only
switched ssh to key-only. So while a trial ran (at most about 20 minutes, until the automatic return to stock),
anyone on the same LAN could log in (we reproduced this in emulation on the old image) to the web interface or the `/ubus` door as root with an empty or
any password, and from there change anything on the running trial system, including undoing the read-only
settings (the device tree marks the NAND read-only, but root can load kernel code: that wall is against
accidents, not against an intruder). Nothing was reachable from outside your LAN unless your router forwards
ports to the NAS. We found this in our own review, not from a report.

**What changed.** At first boot, before any network service starts, the overlay now
(1) turns root's empty password field into `*`, which matches no password at all (the ssh key still works),
and (2) gives the web server one listener, `127.0.0.1:80`, with no HTTPS listener and no `/ubus` door, so it
cannot be reached from the LAN. The self-test gains a `-- security` block (root's password field as a state,
never the field itself; the web server's settings; every port open on a LAN address), and `verdict` prints it
as a `SECURITY:` line. `build/mkoverlay.py` now refuses to build without a key. `tests/qemu-e2e.sh` checks all of
it from outside an emulated trial system: logins on `/ubus` and LuCI with an empty and a random password fail,
ports 80 and 443 do not answer, and the key still logs in.

**What to do.** If you built a bundle before this note, do not run it again: pull this repository and rebuild.

## Security of the trial system

- **Key-only.** An OpenWrt initramfs image has no root password. `build.sh` and `build/mkoverlay.py` therefore
  refuse to build without a public key; the overlay installs it, switches ssh password logins off, locks root's
  empty password field (`*`) and keeps the web server on `127.0.0.1` (see the security note above). Without that,
  anyone on your LAN could log in as root.
- **Generate your OWN key** (`ssh-keygen -t ed25519 -f ~/.ssh/ex4-trial`) and keep the private half on your
  computer. This repository contains no key of any kind, and a bundle you build is yours alone: do not share a
  built bundle, because it carries your public key and your choice of log partition size.
- **One network cable only.** OpenWrt bridges the two LAN ports, without spanning tree. Two cables into the same
  switch are a loop that can take your network down. The script refuses to launch while both ports have a live
  link (override: `EX4_TWO_CABLES_OK=1`, only if the cables go to separate networks).
- **It is a DHCP client, not a router.** OpenWrt's defaults for an unknown board are a static router address and
  a DHCP server, which would fight your real router. The overlay turns the board into a DHCP client, switches the
  DHCP server off, and removes the few seconds at boot where OpenWrt's failsafe mode takes the static address.
  `verdict` warns loudly if the trial ever held that default address.
- **The host key changes.** The trial makes a new ssh host key in RAM on every boot, on the address your ssh
  client knows as the stock NAS. Expect the warning; the README's ssh line avoids storing the throwaway key.
- **Stock's old ssh.** Reaching the stock firmware needs obsolete algorithms (`ssh-dss`,
  `diffie-hellman-group1-sha1`, CBC ciphers) enabled for that one host. That weakness is WD's firmware, and one
  more reason to want a modern system on this box. Do not expose the stock NAS to the internet.
- **Not hardened.** The trial is stock OpenWrt 25.12.6 plus our overlay, meant to run for minutes on a home LAN.
  It is not a reviewed, maintained distribution for this device.

## The front-panel microcontroller

The micro controls power, LEDs, the LCD and the fan, and can be told to shut the unit down or to update its own
firmware. `ex4fan` can send eight fixed frames and nothing else (four fan speeds, two thermistor reads, "system
ready", clock read); the fan-stop frame and every power, LED, LCD, clock-write and upgrade frame are absent from
the binary, which `tests/fan-test.py` checks on the compiled program. If you extend it, keep that property: one
wrong frame to a power controller is not undone by a reboot. On another firmware version, re-derive the frames
from your own firmware first (`tests/fan-emu/run_emu.sh`).

Do not hold the power button down during a trial: a long press is handled by the micro itself, not by us.

## Before you start: a checklist

1. Backups exist and are somewhere else.
2. The unit is the original My Cloud EX4, on firmware 2.12.127 (`check` tells you).
3. Exactly one LAN cable is plugged in.
4. You built the bundle yourself, with your own key.
5. You can reach the power plug.
6. Nobody is using the NAS: `go` stops everything that has files open on the data volumes.
