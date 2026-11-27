# Reading what a trial leaves behind

For the owner, and for a coding agent helping the owner ([../AGENTS.md](../AGENTS.md)). Everything here is taken from
`box/ex4-trial.sh`, `userland/ex4log.c`, `userland/ex4peek.c`, `build/mkoverlay.py`, [../SAFETY.md](../SAFETY.md)
and [RUNS.md](RUNS.md). A line marked **(inferred)** is our reading, not something a run or the code states. Each
marker is quoted exactly as the code prints it; `...` stands for text that varies.

## Where a run leaves its traces

From the header of `box/ex4-trial.sh` (lines 106-117):

| Where | Written by | Survives |
|---|---|---|
| `logs/launch-<stamp>.log` in the bundle folder | `ex4-trial.sh go`, up to the moment the data volume goes read-only | everything (it is on the data volume) |
| `logs/prejump-state-<stamp>.txt` | `go`: the state of every partition-3 log region before the jump | everything |
| **partition 3 of one disk, bytes [1 MiB, 3 MiB)** | the TRIAL kernel's `ex4log` daemon, every few seconds | power off ("The one disk write", SAFETY.md) |
| RAM: three markers + the trial kernel's log ring | the loader's stub; the trial kernel | a warm reset (watchdog, reboot), **not** a power cycle |
| `logs/lan-witness-*.txt` (optional) | `host/ex4-watch.sh` on your computer; you copy it in by hand | everything |
| `logs/verdict-<stamp>.txt` and the other `logs/*-<stamp>.txt` | `ex4-trial.sh verdict` / `log` / `klog` / `marker` | everything |

**The 2 MiB disk log** (SAFETY.md, "The one disk write"; format in the header of `userland/ex4log.c`): two slots of
1 MiB. Each snapshot goes to slot `seq % 2`, so a write cut off by power or the watchdog can damage only the slot
being written; the other still holds the snapshot before. A snapshot is the daemon's progress trail, a status block,
a few command outputs (`ip addr`, `logread`, ...), the self-test file when it exists, and the whole kernel log.

## Getting it off the box, read-only

All of these run under the STOCK firmware, after the box is back, as root, from the bundle folder (on the test unit
`/mnt/HD/HD_a2/ex4-openwrt/bundle`). None of them loads anything or writes a device; each saves its copies under
`logs/` in the bundle folder (box/ex4-trial.sh lines 79-93, and the closing line each prints: `VERDICT ONLY: nothing
was loaded, no device was written.`, `LOG ONLY: nothing was loaded, no device was written.`).

```sh
sh ex4-trial.sh verdict          # RAM first, then the disk log, the launch log, stock's start ledger: ONE VERDICT line
sh ex4-trial.sh log              # the disk log printed in full (RAM ring first), FRESH / STALE, copies under logs/
sh ex4-trial.sh klog             # only the RAM ring
sh ex4-trial.sh marker           # only the RAM markers
```

(Modes from box/ex4-trial.sh lines 79-93.) Run `verdict` first and early: "Run it EARLY: the RAM evidence lives in
memory stock reuses." (line 86). `verdict all` and `log all` also read a partition the bundle was built to keep off
(`LOG_SKIP_PARTS`); on the test unit that disk had an unreadable sector, and reading it "costs minutes of ATA error
handling, so nothing reads it by default" (lines 89-91). Do not use `all` unless you know why.

To bring the `logs/` folder to your computer: this is **our composition**, reversing the `tar` line of README step 2
with the same `OLD` options (`OLD` as set in README step 2; [../AGENTS.md](../AGENTS.md), Step 2). It only reads on
the NAS. Run it inside a new, empty folder on your computer, and type the stock root password at ssh's prompt.

```sh
mkdir ex4-logs && cd ex4-logs
ssh $OLD root@<nas-ip> 'tar -C /mnt/HD/HD_a2/ex4-openwrt/bundle -cf - logs' | tar -xf -
```

If you used `host/ex4-watch.sh`, copy its `lan-witness-<RUNID>.txt` into the bundle's `logs/` folder on the box
**before** `verdict`: "Copy that file into the bundle's logs/ folder on the box before `sh ex4-trial.sh verdict`: the
verdict reads it." (host/ex4-watch.sh header).

**Before you share any of it:** the output names the unit's MAC addresses and the trial's LAN addresses (the `V5 MACS`
line, the `disk log: ... LAN addresses` part, `check`'s `v5 MACs: stock now: ...` line). Mask them if you post it.

## Reading order

1. The last line that starts `VERDICT:` (below, "The verdict line").
2. The `time:` line: how long after the launch stock came back.
3. The `ring:` lines (RAM) and the `disk log:` lines (the 2 MiB log).
4. `FAN:`, `V5 ...`, `V6 ...`, `SECURITY:`, `LCD TEST FRAME:`: the trial's own self-test, when the disk log or the LAN
   witness holds it.

## The verdict line

From box/ex4-trial.sh lines 778-801. Every `verdict` prints exactly one of these, then a closing `VERDICT ONLY: nothing was loaded, no device was written. ...` line (line 803).

| Line | Meaning | For the owner |
|---|---|---|
| `VERDICT: MODERN KERNEL BOOTED (how far: network): Linux ... ran on this box from RAM, its userspace came up and it was on the LAN` | the trial worked end to end | harmless; run 5 is quoted as this verdict in the header of box/ex4-trial.sh, line 121; runs 6 to 8 also reached the network, so **(inferred)** the same |
| `VERDICT: MODERN KERNEL BOOTED (how far: userspace): ... but no LAN address and no ssh from the LAN is on record` | the system came up; the network evidence is missing | harmless to the box; worth a second run with `host/ex4-watch.sh` watching **(inferred)** |
| `VERDICT: MODERN KERNEL BOOTED (how far: kernel): the ... kernel started and reached /init, but userspace left no trace` or `... printed its log, but there is no sign that it reached userspace` | the kernel ran, userspace did not show | stop and report it with the `ring:` lines **(inferred: no run on the test unit ended this way)** |
| `VERDICT: HUNG AFTER THE JUMP: run ... jumped and left no kernel log in RAM, no fresh disk log and no LAN witness. ...` | the jump happened; nothing of the new kernel came back. The rest of the line says how far the evidence reaches (next table) | stop; report it. Do not change anything to "fix" it |
| `VERDICT: INCONCLUSIVE: no launch log in ...` | no `go` of this bundle is on record | harmless; nothing was booted |
| `VERDICT: INCONCLUSIVE: the newest launch (run ...) stopped before the jump ...` | `go` refused or stopped before its last step: "nothing was booted by it" | harmless; read the launch log's last lines for the `REFUSED:` reason |
| `VERDICT: INCONCLUSIVE: this kernel started BEFORE the newest launch ...` | the jump did not happen, or the clock is wrong | harmless to the box; read the launch log **(inferred)** |

### How far a HUNG verdict's evidence reaches (the RAM markers)

From box/ex4-trial.sh lines 793-798. Markers A (0x1000), C (0x3000) and H (0x03000000) are written by the loader's stub
as it copies (docs/LOADER.md, "RAM markers and the black box").

| Marker states in the line | Meaning |
|---|---|
| A and C `INTACT` | "the stub copied every segment ... so the evidence reaches the END OF THE COPY: the fault is in the jump, the decompressor, or the kernel before its first log line" |
| A `INTACT`, C not | "the evidence reaches the START OF THE COPY: the stub did not finish" |
| A `OTHER` | "the markers of an EARLIER run still sit whole at the addresses ... the fault is in the stock kernel's shutdown path or in the jump into the stub" |
| `DAMAGED` | "the stub wrote it and RAM lost part of it (power was off for a moment, or a kernel reused the page)" |
| none of this run | "after a power cycle that is expected (RAM was cleared) and the evidence reaches only the LAUNCH LOG" |

Missing markers next to a kernel log or a fresh disk log "mean nothing": a 6.12 kernel that reaches its memory
allocator may reuse all three (box/ex4-trial.sh lines 104-105).

## The `time:` line

From box/ex4-trial.sh lines 744-749 (seconds between the launch line and stock starting again):

| Text | Meaning | For the owner |
|---|---|---|
| `... an early reset (the 21 s watchdog, or a crash-reboot)` (with `wdt`) or `... an early reset (a crash-reboot, or a quick power cycle)` (without) | under 150 s | read the `CUT` sentence at the end of the verdict line, if there is one |
| `... with wdt that is the mark of a kernel that ran but whose userspace never opened the watchdog ...` | 150-300 s with `wdt`: the 120 s `watchdog.open_timeout` ran out | stop and report **(inferred)** |
| `... that is the trial's own 20-minute auto-return` | 1150-1500 s | harmless: the normal end of a trial |
| `... (a power cycle, or a reset at that moment)` | anything else | harmless if you pulled the plug yourself |
| `how long the trial ran cannot be told (the clock is behind the launch time stamp)` | the clock was not usable | not a failure in itself |

**The CUT sentence** (lines 774-777), only after an early return with `wdt` and some evidence of the new kernel:

- `The 21 s watchdog very likely cut a boot that was still going: ... Run it again WITHOUT wdt.` The script's own
  advice. Without `wdt`, "a hang is a dark box and a power cycle" (line 74). The owner decides; an agent does not
  (AGENTS.md, "When it fails").
- `6.12 HAD taken the watchdog over (its driver's line is on record), so the early return is a crash-reboot, or a hang after that point`: stop and report.

**The BETWEEN note** (lines 738-741): `NOTE: stock's start ledger counts N start(s) of stock's userland between the launch
and this boot`: the box went through stock one more time since the launch, so the RAM evidence is probably not from
this run **(inferred)**. Harmless; it explains a weak verdict.

## The RAM lines

From box/ex4-trial.sh lines 476-526 and `userland/ex4peek.c`.

| Marker | Meaning |
|---|---|
| `ex4peek klog: RESULT: N log buffer(s) found.` | the trial kernel's log was still in RAM (a warm reset) |
| `ex4peek klog: RESULT: no Linux 6.x log buffer found in RAM (power was cycled, or the trial kernel never printed, or stock has reused that memory).` | expected after a power cycle |
| `ring: ... Version line: ...` with `Linux version 6.` | the new kernel started |
| `ring: L2 at entry: OFF, enabled by 6.12 (as after U-Boot)` | the loader handed over correctly (the "L2 cache lesson", README) |
| `ring: L2 at entry: LEFT ON (the fault of runs 1-2: the loader did not turn it off)` | the old loader fault; with this repository's `ex4boot-l2off.ko` it should not appear: stop and report **(inferred)** |
| `watchdog driver line: yes` | the ring holds `orion_wdt: Initial timeout`: 6.12 took the watchdog over |
| `reached /init: yes` | the ring holds `Run /init as init process` |
| `ring: IT HOLDS A CRASH: ...` | a `Kernel panic`, `Unable to handle kernel`, `Internal error:` or `Unhandled fault` line: stop and report it |
| `ring: it names ANOTHER run: it is left over from an earlier trial ...` | old evidence, ignored by the verdict |
| `ring: nothing in RAM now, but an EARLY CAPTURE of run ... is on file` | a `logs/early-klog-<run id>.txt` was put there by "an early RAM capture helper (not in this repo)" (line 111) |
| `note: /proc/cmdline holds ex4boot_run=...: THIS kernel was started by an ex4boot jump (a bundle-v2 run)` | the running stock kernel itself came through the loader (the run 4b kind of test), not a run of this bundle |

## The disk log lines

The state line comes from `ex4log read DEV --state` (userland/ex4log.c header): `state none`, `state damaged`, or
`state run=.. gen=.. seq=.. uptime=..`. `verdict` and `log` compare it with the pre-jump record (box/ex4-trial.sh
lines 446-462, 533-550).

| Marker | Meaning | For the owner |
|---|---|---|
| `DISK sdX3: no log (no magic in either slot)` / `DISK sdX3: no log yet (no magic in either slot)` | no trial has ever written there | harmless if this is your first run |
| `... FRESH, written after the jump` / `FRESH: written after the last jump` | the new system's userspace wrote its log during this run | good: the strongest evidence after ssh |
| `... STALE (identical to the state before the jump: the trial wrote nothing here)` | nothing new on disk | the trial's userspace did not get to its logger, or wrote another disk; read the RAM lines |
| `... AGE UNKNOWN (no pre-jump record)` | the pre-jump state file is missing | cannot be called fresh or stale |
| `state damaged` | a slot was being written when power or the watchdog cut it | the other slot normally still holds the snapshot before (ex4log.c header) **(inferred: no run on the test unit reported it)** |
| `DISK sdX3: not read (skipped ...)` | the bundle keeps that bay off (`LOG_SKIP_PARTS`) | harmless |
| `disk log: WARNING: the trial held ... (OpenWrt's router default): the overlay's network setup did not apply` | the trial took OpenWrt's factory router address, which may clash with your router | stop and report; SAFETY.md, "It is a DHCP client, not a router" |
| `disk log: ... ssh server running: not in the newest snapshot (written while shutting down, ...)` | the last snapshot was taken while the trial was rebooting | harmless ("run 6 showed it", the comment at box/ex4-trial.sh line 560) |

Inside the saved disk log (`logs/disklog-<part>-<stamp>.txt`), the sections are headed `-- trail`, `-- notes`,
`-- status at uptime ...`, `-- $ <command>`, `-- self-test (/tmp/ex4-selftest.txt ...)`, `-- dmesg (...)`, and
`-- (shutdown snapshot: command outputs skipped to finish before the kill)` (userland/ex4log.c). The notes the
overlay writes (build/mkoverlay.py), in boot order:

| Note | Meaning |
|---|---|
| `rc.d S01 reached: procd is running the init scripts` | init started |
| `rc.d S02: ex4fan ...` | the fan daemon's first state |
| `rc.d S03: deadman armed: reboot to stock in 20 + 2 min unless /tmp/ex4-stay exists (does not need S99)` | the second auto-return is set (20 is the default `RETURN_MIN`, build/build.sh) |
| `MACs: eth0 ..., eth1 ... (...)` | the MAC hook ran |
| `uci-defaults applied (hostname ex4-trial, DHCP server off, ssh settings; security: root password field ...` | the network and security setup ran |
| `rc.d S99 reached: every init script has run` | the boot finished |
| `self-test written to /tmp/ex4-selftest.txt` | the self-test exists |
| `auto-return: no /tmp/ex4-stay, rebooting to stock now` | the 20-minute return fired: the normal end |
| `deadman: 20 + 2 min, no /tmp/ex4-stay: rebooting to stock now` | the second timer fired: the first one did not (stop and report if this appears without the one above **(inferred)**) |
| `rc.d S01: the preinit hook had not started the logger; started here` / `rc.d S02: the preinit hook had not started ex4fan; started here` | the backup start was needed; the run went on |

(In the overlay source these notes carry `@RETURN_MIN@`; the built bundle has the number.)

## The FAN line

From box/ex4-trial.sh lines 585-623, reading the trial's `ex4fan: ...` lines (userland/ex4fan.c).

| Marker | Meaning | For the owner |
|---|---|---|
| `FAN: rpm seen: A to B · ... fan commands ACKed by the micro: N of M · fail-safe reboot: none` | the fan was managed | harmless; run 6: 13 of 13, 2040 down to about 1020 rpm |
| `fail-safe reboot: ...` (from a `FAILSAFE reason=...` line) | ex4fan set the fan to maximum and rebooted to stock | the safety net worked; report the reason |
| `rpm seen: never above 0` / `not readable (no tachometer line)` | no tachometer reading | stop and report **(inferred)** |
| `worker crashes: N` above 0 | the daemon's worker ended and was restarted | report it **(inferred)** |
| `FAN: no ex4fan line on record for run ...` | no evidence either way | not a failure in itself |

## The V5, V6, SECURITY and LCD lines

From box/ex4-trial.sh lines 624-729, read from the trial's self-test.

| Marker | What good looks like (test unit) | When to worry |
|---|---|---|
| `V5 MACS: ... the two ports differ: yes · br-lan (the lease) carries eth0's, the unit's first: yes · source: ...` | run 8: WD's own two addresses, read from `rescue firmware` | `NO`, a source `the MAC hook did not run`, or one saying `nothing readable in flash` (build/mkoverlay.py lines 228-234): run 7 had that before the v6 device tree fix (RUNS.md, run 7). On a current bundle, report it |
| `V5 USB3: ... bound to a driver: 1 of 1 ...` | run 7: `xhci_hcd` bound to the Etron EJ168 | `0 of 1`: report |
| `V5 CLOCK: the micro says ... · system clock set from the micro: yes` | run 7 | `asked, no clock frame came back`: report **(inferred)** |
| `V5 PANEL: cmd READY ...` | run 7: `DeviceReady` acknowledged | `no DeviceReady line on record`: report |
| `V5 LINK` / `V6 LINK: ... carrier changes in ... s (... a minute ...)` | run 8: 1 carrier change (the first link-up) in 21 minutes | dozens a minute = the link flap of runs 5 to 7 (run 7: 2329 in 1237 s; docs/HARDWARE.md, "The link flap"). On a current bundle, report it |
| `V6 FLASH: ... WD's own layout (0x0dd00000 / 0x0ec00000 / 0x0d800000): yes` | run 8 | `NO`: stop and report |
| `V6 PHY: ... the generic driver holds every PHY: yes · ... both on register page 0: yes` | run 8: both PHYs `0141.0dd1`, page 0 | `NO`: report |
| `SECURITY: root's password field: ... · TCP ports open on a LAN address: ... · web ports 80 / 443 closed to the LAN: yes` | v7 and later bundles (SAFETY.md, "SECURITY NOTE") | `NO`, or `the self-test on record has no security block (a bundle older than v7 ...)`: do not run that bundle again; rebuild (SAFETY.md) |
| `LCD TEST FRAME: ...` | v8 bundles only: one frame, one try | informational; "What the glass shows has never been seen" (README) |

## Refusals

Every `REFUSED:` line comes from `die` in box/ex4-trial.sh, which exits at once; none of them is reached after the
jump. "Stop at the first `REFUSED`. Every refusal says why, and none of them is a bug to work around." (README).

| `ex4-trial: REFUSED: ...` | What it means | For the owner |
|---|---|---|
| `kernel is not WD 2.12.127's 3.2.40 build: ...` | another firmware | stop for good on this box; README, "Helping", asks for this `check wdt` output |
| `CPU is not a Feroceon 88FR131` / `kernel command line is not the EX4's` / `/proc/mtd is not the EX4 layout` / `not a 512 MiB unit` | not the machine this was built for | stop for good |
| `the kernel in flash (...) is not the one this bundle was built against` | `mtd1` does not hold WD's 2.12.127 kernel | stop for good |
| `module loading is disabled` / `kallsyms does not list the three functions ex4boot needs` / `kallsyms addresses are hidden` | the stock kernel will not let the loader in | stop |
| `ex4boot is already loaded (rmmod ex4boot first)` | a module from an earlier step is still in | `sh ex4-trial.sh unload`, then `check` again |
| `bundle file missing: ...` / `... is damaged (md5 ..., want ...)` / `MD5SUMS does not cover ...` / `CFG, LOGCFG or RUNID is incomplete` | the copy on the NAS is incomplete or damaged | copy the bundle again (README step 2) |
| `log gate: /dev/sdX3 is MOUNTED ...` / `... is SWAP ...` / `... is a member of an md array ...` | partition 3 is in use on this NAS: not the unused spare the log was designed for | stop. SAFETY.md, "The one disk write" |
| `log gate: /dev/sdX3 is ... KiB, not the ... KiB this bundle was pinned to` / `log gate: no unused sdX3 inside ...` | your partition 3 has another size | stop. An owner-only decision, never an agent's (AGENTS.md, Wall 5b): SAFETY.md says "read `build/build.sh`'s header before you rebuild for it, and make sure the partition is really empty first" |
| `BOTH LAN ports have a live cable. ...` | two cables | unplug one cable (SAFETY.md, "One network cable only") |
| `/tmp has ...K free, need ...K` / `cannot make ...` / `copy ...` | no room or no write on stock | stop and report **(inferred)** |
| `module did not create /proc/ex4boot (dmesg \| tail)` / `insmod failed: ...` | the module did not load | stop and report |
| `... in RAM does not have crc32 ...: unloaded, nothing booted` / `the module's entry / r1 / r2 are not ...: unloaded, nothing booted` | what landed in RAM is not what the bundle expects | stop; the script already unloaded the module |
| `the marker reader did not find every marker of run ... in RAM while the module held them ...: module removed, nothing booted` | `load-dry`'s marker check failed | stop and report |
| `could not remount every data volume read-only (something still writes). Nothing booted. ...` | something still uses the NAS | the owner finds and stops what uses it (SAFETY.md checklist item 6); an agent stops nothing on the NAS itself. Then try again |
| `.../launch-....log exists` | a launch log of the same stamp is there | retry (the stamp carries the time and pid, line 336) **(inferred)** |

## The real runs, as a reader would meet them

From [RUNS.md](RUNS.md). Runs 1 to 4 were made with earlier bundles; their verdict lines are not on record, so the
"what you would see" column for them is **(inferred)** from today's code.

| Run | What happened | What you would see | For the owner |
|---|---|---|---|
| 1 | never on the LAN, no watchdog, no log existed yet; power cycle after 30 min | (inferred) `HUNG AFTER THE JUMP`, no markers ("after a power cycle that is expected"); with `wdt`, a reset after 21 s instead | with `wdt` the box comes back by itself; without, the plug |
| 2 | watchdog reset, back after about 3 min; no log on disk or in RAM | (inferred) `HUNG AFTER THE JUMP` and an early `time:` line. RUNS.md: "no trace" is not "did not run" | the watchdog way back works; report |
| 3 | WD's own kernel as the payload, no watchdog, dark for 10 min | (inferred) `HUNG AFTER THE JUMP`; the start ledger showed no boot | power cycle; the loader test, not a trial of OpenWrt |
| 4a | as 3 with `wdt`; markers A, C, H intact after the reset | (inferred) `HUNG AFTER THE JUMP` with "A and C INTACT ... the evidence reaches the END OF THE COPY" | the fault was after the copy (the L2 cache) |
| 4b | L2-off stub: stock came up with the run id in `/proc/cmdline` | the `note: /proc/cmdline holds ex4boot_run=...` line | the handoff works |
| 5 | OpenWrt booted to the network, ssh 62 s after launch | `MODERN KERNEL BOOTED (how far: network)` (box/ex4-trial.sh line 121) and the auto-return `time:` line | harmless: the expected result |
| 6 | as 5 + the fan managed, 13 of 13 commands acknowledged | (inferred) `MODERN KERNEL BOOTED (how far: network)`; `FAN: rpm seen: ... ACKed by the micro: 13 of 13 ...` (inferred wording) | harmless |
| 7 | USB 3, clock, `DeviceReady`; MACs not read; link flap 2329 changes in 1237 s | the V5 lines; `V5 LINK` with a high rate | the MAC and link problems were fixed in the v6 device tree (run 8). On a current bundle they would be a report |
| 8 | first bundle from `build/build.sh`; link steady, WD's own MACs, PHYs `0141.0dd1` page 0 | (inferred) `MODERN KERNEL BOOTED (how far: network)`; `V6 FLASH ... yes`, `V6 PHY ... yes` | harmless: what a good run of today's `build/build.sh` bundle looks like |

After every one of these runs: RAID arrays `[UUUU]`, no resync. After run 4a stock checked its data volume for about
four minutes before mounting it (RUNS.md).
