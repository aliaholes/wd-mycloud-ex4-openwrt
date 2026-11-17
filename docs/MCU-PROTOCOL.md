# The EX4's front-panel microcontroller: protocol notes

Established on one WD My Cloud EX4, firmware 2.12.127. Words used below: **seen on the unit** = observed on the
real hardware; **stock under emulation** = WD's own programs (`up_send_ctl`, `up_send_daemon`, `up_read_daemon`,
`rtc`, `led`, `mac_read`) run under qemu-arm on a PC against a pseudo-terminal or a fake micro, with every byte
recorded (`tests/fan-emu/`, records in `tests/captures/`); **read** = from disassembly only.

## The link

- SoC UART1 (pins MPP13/MPP14) = `/dev/ttyS1` under both kernels.
- **19200 baud, 8 data bits, no parity, 1 stop bit, no flow control, raw** (stock under emulation: the port
  settings WD's daemon left on the pty; seen on the unit: `ex4fan` talks with these settings).
- Frames in both directions: `FA b1 b2 b3 b4 b5 FB`, 7 bytes. Two longer replies exist: the clock (13 bytes) and
  the micro's version (15 bytes).
- WD sends a frame, waits 300 ms for an ACK, and repeats it up to 10 times (stock under emulation). On the real
  unit one try was always enough (seen: 13 commands, 13 ACKs, each on the first try).
- Under stock, roughly every 62 s one query goes out and two frames come back (seen on the unit as counters:
  tx +7, rx +14).

## Host to micro

| Bytes | WD's name (`up_send_ctl ...`) | Meaning | Status |
|---|---|---|---|
| `FA 02 00 01 00 00 FB` | `FanControl 1` | fan low | stock under emulation; **sent on the unit, ACKed** |
| `FA 02 00 02 00 00 FB` | `FanControl 2` | fan medium | same |
| `FA 02 00 03 00 00 FB` | `FanControl 3` | fan high | same |
| `FA 02 00 04 00 00 FB` | `FanControl 4` | fan highest | stock under emulation; in `ex4fan`, not needed during run 6 |
| `FA 02 00 00 00 00 FB` | `FanControl 0` | fan stop | stock under emulation. **Never sent by us; not in `ex4fan`** |
| `FA 03 08 01 00 00 FB` | `GetThemister 1` | read thermistor, SATA board | stock under emulation; **sent on the unit** |
| `FA 03 08 02 00 00 FB` | `GetThemister 2` | read thermistor, main board | same |
| `FA 03 01 00 00 00 FB` | `DeviceReady` | the system is up (WD's `chk_io` and `up_send_init_info` send it) | stock under emulation; **sent on the unit, ACKed at the first try** (run 7) |
| `FA 01 00 03 01 00 FB` | `RDateAndTime` | read the micro's clock | stock under emulation; **sent on the unit, answered** (run 7) |
| `FA 03 05 00 00 00 FB` | `MCUVer` | ask for the micro's firmware version | stock under emulation. Never sent by us |
| `FA 03 09 00 00 00 FB` | `GetOnCause` | ask why the unit powered on | same |
| `FA 03 02 02 00 00 FB` | `APRStat` | auto-power-recovery state | same |
| `FA 03 12 02 00 00 FB` | `WOLStat` | wake-on-LAN state | same |
| `FA 03 10 xx 00 00 FB` | `PwrLedRed N` | xx = 00/01/02 (blue off/on/blink), 0A/0B/0C (red) by WD's argument table | stock under emulation. Nothing in WD's firmware issues it on the EX4; effect unknown. Never sent by us |
| `FA 04 83 00 01 32 FB` | `FanSpeed 2` | unknown (a duty value?) | stock under emulation, one sample. Never sent by us |

Commands that exist by name in this firmware's `up_send_ctl` but put nothing on the wire: `FanStatusGet`,
`HddAccessLed`, `temperature`, `GetThemister 3/4` (those two print a stored value).

The micro also accepts clock-write, alarm, shutdown/standby and firmware-upgrade commands (their names are in WD's
programs). We captured none of them on purpose and describe none here.

## Micro to host

| Bytes | Meaning | Status |
|---|---|---|
| `FA 30 00 00 xx xx FB` | ACK | stock under emulation (WD's reader stores "ack"); **seen on the unit** |
| `FA 03 08 0S xx RR FB` | thermistor S (1 SATA board, 2 main board), raw value RR | read + stock under emulation; **seen on the unit** (main board; the SATA-board value read as 0 °C there) |
| `FA 01 00 03 xx SS MM HH DW DD MO YY FB` | the clock, BCD, taken as UTC by WD's `rtc` | stock under emulation: WD's reader stored `26/11/17 Mon 12:30:15` for `FA 01 00 03 07 15 30 12 02 17 11 26 FB`, and `rtc -s` set the epoch 1794918615. **Seen on the unit** (run 7): `03 57 10 03 17 11 26` = 10:57:03 UTC on 17 Nov 2026, a Tuesday, day-of-week byte 03 (WD's reader printed `Mon` for 02) |
| `FA 03 05 ...` (15 bytes) | the micro's version | read only |
| `FA 21 00 00 xx 00 FB` | power button ("PWR") | stock under emulation |
| `FA 57 00 00 00 00 FB` | power button, second kind ("PWR2"; which press: unknown) | same |
| `FA 22 ...` / `FA 52 ...` | reset button ("RST" / "RST2") | same |
| `FA 26 ...` | USB-copy button ("UsbBackupPush") | same |
| `FA 23` `24` `25` `27` | power / reset / scroll / second scroll button pressed (WD's manufacturing mode) | same |
| `FA 2A` `2B` `2C` `2D` | the same four, released | same |
| `FA 40 00 00 xx 00 FB` | power-loss flag | same |
| `FA 41 ...` / `FA 42 ...` | auto-power-recovery state / wake-on-LAN state | same |
| `FA 20 ...` | clock alarm | same |

No button or event frame has been seen on the real unit yet (nobody pressed one during run 7); `ex4fan` writes each one it receives to its log and
does nothing else.

## Thermistor table

Raw value to °C, 192 entries (index = raw value; larger raw = cooler; past the end WD reads 0). It is the
array `LUT[]` in `userland/ex4fan.c`. Spot checks, stock under emulation: raw 0x50 → 47, 0x64 → 37, 0x4B → 50,
0x0B → 127, 0xC8 → 0.

## The fan's speed, and WD's fan curve

- The tachometer is **not** on the micro: it is SoC **GPIO 39**, two pulses per turn. WD counts level changes for
  one second and multiplies by 15. Seen on the unit: about 1000 to 1050 rpm at LOW, 1500 at MEDIUM, 2040 at HIGH.
- Drive temperatures: SMART attribute 194. Board temperature: the main-board thermistor.
- WD's automatic curve (read): `T = max(hottest drive, main-board thermistor - 10)`; LOW → MEDIUM at T ≥ 62,
  MEDIUM → HIGH at ≥ 64, HIGH → MAX at ≥ 66; MAX → HIGH at ≤ 61, HIGH → MEDIUM at ≤ 60, MEDIUM → LOW at ≤ 57; one
  step per minute, never stop; alert at 65, shutdown at 75.
- `ex4fan` uses the same shape 16 °C cooler (MEDIUM from 46, HIGH from 48, MAX from 50), starts at HIGH, and is
  never slower than WD's curve at any temperature. That shift is our choice, not a measured optimum.

## The clock

The SoC's own RTC does not tick on this board (stock: `unable to open rtc device (rtc0)`; 6.12:
`rtc-mv: internal RTC not ticking`). The time lives in the micro. `ex4fan` only reads it. On the unit (run 7) it
asked 6.7 s after the kernel started, got the frame above, and set the system clock, which still stood at 7 s
after 1970; NTP took over later.

## How to check this on your own firmware

`tests/fan-emu/run_emu.sh` runs your own copy of WD's three programs under qemu-arm and records what they send.
`tests/fan-test.py` compares `ex4fan`'s eight frames with such records. If your firmware's bytes differ from the
tables above, do not run `ex4fan` against your micro.
