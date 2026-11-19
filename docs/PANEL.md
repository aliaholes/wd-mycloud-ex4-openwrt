# The front panel in ex4fan v7 (LCD Tier A, buttons, the shutdown frame, the tachometer, the JSON)

ex4fan is still the ONE owner of `/dev/ttyS1`. v7 adds a panel module inside it. Design and the byte-exact frame table with
receipts: the design notes (private, not published); the captures used by the tests are in `tests/captures/`
(`stock-lcd-frames-2026-11-17.json`, `stock-power-frames-2026-11-17.json`: frames only, made by WD's own `up_send_ctl` under
qemu-arm, never on the box).

## What is ON by default in a trial
Nothing new on the wire. The LCD module is OFF unless the daemon gets `--panel` or `/etc/config/ex4panel` holds
`option mode 'tierA'`. Buttons are logged only. The poweroff frame needs BOTH `--allow-poweroff` on the daemon AND
`ex4fan ctl poweroff`; nothing in the trial passes or runs either.

## The whitelist (19 kinds, `PK[]` in ex4fan.c)
name, fw, health, free, fan (text: LEN + 1..16 printable ASCII) · ip1, ip2 (WD's nibble rule) · ip1off, ip2off · vol
(VolStatus, status in {0 normal, 1 rebuilding, 2 degraded, 3 crashed, 5 resyncing}, 0..100 %) · used (VolUsedPct) · volclean ·
temp (two values 0..150) · lcd (LCDSleepMode 0/1) · standby (WD's 0 / 3 / 6, the three captured codes) · usb (0/1) · shutmsg
(DeviceShutdownMsg) · rstmsg (DeviceRstMsg) · poweroff (WD's `DeviceShutdown 1` = `FA 03 03 01 01 01 FB`, what WD's own
shutdown.sh sends on the EX4 before `sleep 20; poweroff`). Every frame is built by a builder and checked again by
`frame_check()` in front of the one writer. Not kinds (refused): ErrStatus, HDDExist, MFGLCD, MFGMode, OledTest, PwrLedRed,
HddAccessLed, MCUReset (WD's reboot frame, `FA 03 03 02 01 TT FB`), DeviceShutdownByUPS, every clock write, fan stop.

## Inputs (read-only)
host name (uname), IPv4 of `ip1_ifaces` (default `br-lan eth0`) / `ip2_ifaces` (`eth1`), `/etc/openwrt_release`,
`/proc/mdstat` (the array named by `option md`, default md1), `statvfs()` of the mount whose source is `/dev/md1` (only if
something already mounted it), the drives' SMART sector (CHECK POWER MODE first; a drive in standby is not read and keeps its
last values), one file per alert in `/var/run/ex4panel/alerts.d/` (first line = text, any daemon may write one). The folder
is 0755 and owned by root: only root-level programs can write an alert, and ex4fan cannot tell which one did (the text is cut
to 16 printable ASCII characters before it can reach the glass). (v8, the panel review's nit 2.)
Health field, worst first: `No Drives` / `Failed sdX2` (md member marked F) / `Watch sdX` (SMART 5, 187, 197 or 198 > 0) /
the first alert / `Good`.

## Sending
On change + every 10 min; at most one LCD frame per 300 ms; never while a fan command is unACKed; 3 tries; an unACKed LCD
frame is counted and dropped (never a fail-safe).

## Commands
```
ex4fan ctl send SLOT         # one field once, even with the panel off (the bench step: name ip1 ip2 fw health free used vol fan temp usb lcd standby)
ex4fan ctl send-test         # v8: THE ONE TEST FRAME: the host name as WD's SysName, ONE try (no retries), once per boot (a second is
                             # refused), panel on or off; the result line goes to /tmp/ex4fan.sendtest and the log. The trial's
                             # self-test runs it once and records it; `ex4-trial.sh verdict` prints it as "LCD TEST FRAME:"
ex4fan ctl refresh           # every field again (panel on)
ex4fan ctl notice shutdown|reboot
ex4fan ctl poweroff          # REFUSED unless the daemon runs with --allow-poweroff (Kurt's word on the real box)
```
Requests go through `/var/run/ex4panel/ctl/` (0700, root's files only).

## /tmp/ex4fan.json (for the web UI)
fan (level, rpm, tach mode, edges), temps, per drive temp + power state + verdict + SMART 5 9 10 12 187 194 197 198 199,
usb_disks, md (state, members, sync %, read-only, faulty), space, micro counters, panel (mode, what the glass was given,
LCD counters), alerts, the last eight button events.

## Tachometer
Rising edges of GPIO 39 by GPIO v2 edge events for a 1 s window every 10 s, rpm = (k - 1) x 30e9 / (t_last - t_first) ns.
A window with fewer than 3 edges is cross-checked by 1 ms sampling; if sampling sees the fan turn, the daemon stays on
sampling. No busy spin anywhere. Edge interrupts on the real board: NOT yet seen (first trial check).

## Tests
`tests/panel-test.py` (fake micro on a pty; `--wakeups N` measures idle wakeups) and `tests/fan-test.py` (the fan, unchanged
cases).
