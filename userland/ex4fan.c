/* ex4fan.c : the fan + front-panel daemon of the EX4 (v7; bundle-v5 = run 7; v4 = run 6). One static ARM binary.
 *
 * v7 (Nov 17 2026, the panel lane; summarised in docs/PANEL.md) — still the ONE owner of ttyS1:
 *   + THE TACHOMETER without the spin: rising edges of GPIO 39 through the GPIO v2 character device (edge detection switched on
 *     for a 1 s window every 10 s, events read in one bulk read(), rpm from the kernel's timestamps). If the kernel refuses edge
 *     detection, or a window sees no edge, the line is sampled every 1 ms for 1 s (clock_nanosleep, never a spin) and, when that
 *     sampling sees the fan turning, the daemon stays on sampling for good. The sysfs fallback samples the same way.
 *   + THE MAIN LOOP is one poll() over the port (and an inotify on the panel's run folder) whose timeout is the next deadline:
 *     no 200 ms tick any more. The supervisor's heartbeat is written at most every 10 s.
 *   + THE FRONT LCD, Tier A, OFF unless `--panel` or /etc/config/ex4panel says `option mode 'tierA'`: WD's own FIELD frames
 *     (host name, IP 1 / IP 2, firmware text, drive health, free space, used %, volume state, fan rpm, temperatures, USB,
 *     LCD on/off, standby), fed from this daemon's own readings + /proc/mdstat + statvfs() of md1's mount + getifaddrs().
 *     Every LCD frame is built by a builder for one KIND of PK[] below and checked again by frame_check() right before the
 *     one writer: fixed prefix (byte-exact, captured from WD's up_send_ctl under qemu-arm) + a payload rule (text 1..16 bytes
 *     of printable ASCII, IP nibbles, VolStatus digits from {0,1,2,3,5}, temperatures 0..150 ...). No other frame can leave.
 *     A field goes out when it changes, plus a full refresh every 10 min; at most one LCD frame per 300 ms, never while a fan
 *     command is unACKed; 3 tries; an LCD frame that is never ACKed is counted and dropped, it NEVER triggers a fail-safe.
 *   + THE SHUTDOWN FRAME (WD's `up_send_ctl DeviceShutdown 1` = FA 03 03 01 01 01 FB, what WD's shutdown.sh sends on the EX4
 *     before `sleep 20; poweroff`; captured under qemu-arm only, Nov 17 2026) is a kind, but it is sent ONLY by `ex4fan ctl
 *     poweroff` AND only by a daemon started with --allow-poweroff. Nothing in the trial passes that flag or runs that command:
 *     sending it on the real box is the owner's word. MCUReset (WD's reboot frame) and DeviceShutdownByUPS are NOT kinds.
 *   + the buttons stay LOGGED ONLY (and the last eight are in the JSON).
 *   + /tmp/ex4fan.json for the web UI (rename-written): fan, temps, per drive the temperature, power state and nine SMART
 *     attributes (5 9 10 12 187 194 197 198 199) from the sector it already reads; md state; space; what the glass was given;
 *     alerts (one file per alert in /var/run/ex4panel/alerts.d/, written by any other daemon); recent button events.
 *     Before SMART READ DATA it asks the drive CHECK POWER MODE (non-data) and skips a drive in standby (keeps its last value).
 *   Nothing in v7 opens a block device for writing, assembles, mounts or runs mdadm: md state comes from /proc/mdstat, space
 *   from statvfs() of whatever is already mounted.
 *
 * v5 (Nov 17 2026), on top of the v4 fan daemon that ran on the box in run 6 (13 of 13 commands ACKed by the real micro):
 *   + TWO more frames in the whitelist, each one the bytes WD's own up_send_ctl put on the wire under qemu-arm:
 *       FA 03 01 00 00 00 FB   "DeviceReady": what WD's chk_io and up_send_init_info send once the system is up
 *                              (the host's "status OK" to the front panel). Sent once, after the first full reading,
 *                              only while nothing is wrong (micro answers, fan command ACKed, no 0 rpm).
 *       FA 01 00 03 01 00 FB   "RDateAndTime": READ the micro's clock. The SoC's own RTC has no crystal on this board
 *                              (WD's kernel: "unable to open rtc device"; 6.12: "internal RTC not ticking"); WD's
 *                              `rtc` reads the time from the micro with this frame. The answer is a 13-byte frame
 *                              FA 01 00 03 xx SS MM HH DW DD MO YY FB (BCD), which WD's rtc takes as UTC (seen:
 *                              WD's own up_read_daemon + rtc under qemu-arm). This daemon logs it next to the system
 *                              clock and sets the system clock from it ONLY when the system clock is still unset
 *                              (before 2026). It never writes the micro's clock (no W* frame exists in this file).
 *   + the micro's own events are NAMED in the log and nothing else happens: power button (21 PWR, 57 PWR2), reset
 *     button (22 RST, 52 RST2), USB copy button (26 UsbBackupPush), the push / release events of WD's manufacturing
 *     mode (23 24 25 27 2a 2b 2c 2d), power-loss / auto-power-recovery / wake-on-LAN state (40 41 42), RTC alarm (20).
 *     Names = what WD's own up_read_daemon stored for each frame under qemu-arm. LOGGED ONLY: no action.
 *   NOT in this file, on purpose: any LED frame. On the EX4 WD's `led` drives the power LED (SoC GPIO 29 blue, 28 red)
 *   and the bay LEDs (GPIO 45-48 red; the SATA controller's own pins blue) without the micro; the micro's "PwrLedRed"
 *   command exists in up_send_ctl but nothing in WD's firmware issues it, so what it does is not proven.
 *
 * On the WD My Cloud EX4 the fan is not on a SoC pin. A front-panel microcontroller ("uP", WD ships its firmware as
 * uP.bin) drives it, and the SoC talks to that micro over uart1 = /dev/ttyS1. Under WD's firmware the chain is
 * fan_control -> libtemperature.so -> up_send_ctl -> up_send_daemon / up_read_daemon -> /dev/ttyS1. Under the trial
 * kernel nothing speaks to the micro (run 5: ttyS1 tx 0 rx 0), so nothing manages the fan. This daemon does.
 *
 * THE PROTOCOL (how each line was proven: docs/MCU-PROTOCOL.md):
 *   UART: 19200 baud, 8 data bits, no parity, 1 stop bit, no flow control, raw.
 *   Every frame, both ways, is 7 bytes: FA b1 b2 b3 b4 b5 FB.
 *   box -> micro   FA 02 00 0N 00 00 FB   fan speed N: 1 low, 2 medium, 3 high, 4 highest (0 = stop: NOT in this file)
 *                  FA 03 08 01 00 00 FB   read the thermistor on the SATA board
 *                  FA 03 08 02 00 00 FB   read the thermistor on the main board
 *                  FA 03 01 00 00 00 FB   DeviceReady (v5)          FA 01 00 03 01 00 FB   read the micro's clock (v5)
 *   micro -> box   FA 30 00 00 xx xx FB   ACK (WD repeats a frame every 300 ms, up to 10 times, until it sees one)
 *                  FA 03 08 0S xx RR FB   thermistor S (1 SATA board, 2 main board): RR = raw value, degrees C = LUT[RR]
 *                  FA 01 00 03 xx SS MM HH DW DD MO YY FB   the micro's clock, 13 bytes, BCD, UTC (v5)
 *                  FA 2x / 5x / 4x 00 00 xx xx FB           buttons and power events (v5: named in the log, no action)
 *   The fan's speed is NOT read from the micro: the tachometer is SoC GPIO 39 (bit 7 of the high GPIO data-in
 *   register 0xf1010150), two pulses per turn; WD counts level changes for one second and multiplies by 15.
 *
 * THE WHITELIST: the micro also handles power, the LEDs, the LCD, shutdown and its own firmware upgrade. This daemon
 * can send exactly the eight frames of TX[] below (v4: six) and nothing else: mcu_write() is the only function that
 * writes to the port, it takes an index into that constant table, and no frame is ever built from variables. There is
 * no fan-stop frame in the table (WD's automatic mode never stops the fan either), and no frame that sets anything
 * but the fan's speed: no power, shutdown, standby, LED, LCD, clock-write or firmware-upgrade frame.
 *
 * WHAT IT DOES
 *   first action: fan HIGH (3), logged. Then every 30 s: drive temperatures (SMART attribute 194, read with an ATA
 *   pass-through SG_IO on /dev/sdX opened read-only; this kernel has no drivetemp hwmon), both thermistors, the SoC
 *   thermal zone. Every 10 s: the fan's rpm (GPIO 39 through the GPIO character device, WD's own counting method).
 *   THE CURVE = WD's own four-state curve (fan_control, read from its disassembly) moved 16 degrees C cooler:
 *     T = max(hottest drive, main-board thermistor - 10)          (WD's own formula)
 *     LOW  -> MEDIUM at T >= 46 (WD 62) · MEDIUM -> HIGH at T >= 48 (WD 64) · HIGH -> MAX at T >= 50 (WD 66)
 *     MAX  -> HIGH   at T <= 45 (WD 61) · HIGH -> MEDIUM at T <= 44 (WD 60) · MEDIUM -> LOW at T <= 41 (WD 57)
 *   so at every temperature the fan runs at least as fast as under WD's firmware. Up as many steps as it takes at
 *   once, down one step per reading. Floors: HIGH for the first 60 s, HIGH while any present drive cannot be read or
 *   the tachometer cannot be read, MAX while the rpm reads 0, MAX with no temperature at all, MAX at SoC >= 90 C.
 *   FAIL-SAFE (each one: fan MAX, the reason into the kernel log + the ex4log disk log, then a reboot; a reboot goes
 *   through U-Boot into the untouched stock system, which runs its own fan):
 *     the micro never answers (no valid frame 30 s after the start) or stops answering (none for 120 s)
 *     the rpm reads 0 for 30 s while a speed is commanded          any drive at or above 55 C (read twice)
 *     the port cannot be opened          the worker crashes or hangs 6 times
 *   Every command, level change and fail-safe goes to /dev/kmsg as "ex4fan: ..." (the kernel's RAM ring, which
 *   ex4log also copies to the disk log) and to /tmp/ex4fan.log; the current state is one line in /tmp/ex4fan.status.
 *
 *   ex4fan daemon [--foreground]        the real thing (the overlay's preinit hook starts it)
 *   ex4fan frames | events | lut | curve T...    print the whitelist / the event names / the thermistor table / the curve's walk (tests)
 *   ex4fan daemon --test-root DIR [--fast] [--foreground]     off the box: every path under DIR, no hardware, no reboot
 *       DIR/tty (the port), DIR/drives ("sda 41" lines), DIR/tach (rpm; no file = no tachometer), DIR/soc (millidegrees)
 *       DIR/now (v5: the system clock in seconds since 1970; no file = the real clock); a clock that WOULD be set is a line in DIR/clockset
 *   ex4fan daemon --test-hw [--tty ttySN] [--tach-chip TEXT --tach-line N]   an emulator: real kernel paths, another port / GPIO
 *   v7: ex4fan daemon ... [--panel] [--allow-poweroff]          LCD Tier A on; the poweroff frame allowed (the owner's word only)
 *   v7: ex4fan ctl refresh | send SLOT | notice shutdown|reboot | poweroff    a request to the running daemon (root only)
 *   v8: ex4fan ctl send-test        THE ONE TEST FRAME (decided Nov 17 2026: the trial may send ONE LCD test frame;
 *       nobody can see the glass, so the ACK is the whole measurement): the host name as WD's SysName frame, tried ONCE
 *       (no retries), at most once per boot (a second request is refused: the result file in /tmp already exists),
 *       even with the panel OFF. The result is one line in /tmp/ex4fan.sendtest and in the log; the trial's
 *       self-test asks for it once and records it.
 *   v7: ex4fan panel-kinds | panel-build KIND ARGS... | panel-check HEX | tachcalc NS...      (tests)
 *   v7 --test-root files: DIR/hostname DIR/ifaddrs ("br-lan 192.0.2.50") DIR/mdstat DIR/mounts DIR/statvfs ("total avail"
 *       bytes) DIR/release DIR/usb DIR/ex4panel.conf DIR/run/ex4panel/{ctl,alerts.d}/ DIR/tach_edges (ns timestamps);
 *       DIR/drives lines may carry SMART attributes and a power state: "sdd 43 5=0 197=8 power=standby"
 *
 * Build: arm-linux-gnueabi-gcc -static -Os -march=armv5te -Wall -Wl,-z,max-page-size=0x8000 -o ex4fan ex4fan.c
 * Born Nov 16 2026 (aliaholes). SPDX-License-Identifier: GPL-2.0-or-later. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <dirent.h>
#include <time.h>
#include <poll.h>
#include <termios.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <sys/sysmacros.h>
#include <sys/statvfs.h>
#include <sys/utsname.h>
#include <sys/inotify.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <scsi/sg.h>
#include <linux/gpio.h>

/* ---------- THE WHITELIST: every byte this program can ever put on the wire ---------- */
enum { TX_FAN_LOW, TX_FAN_MEDIUM, TX_FAN_HIGH, TX_FAN_MAX, TX_THERM_SATA, TX_THERM_MAIN, TX_READY, TX_CLOCK_READ, TX_N };
static const unsigned char TX[TX_N][7] = {
	{ 0xfa, 0x02, 0x00, 0x01, 0x00, 0x00, 0xfb },      /* up_send_ctl FanControl 1 */
	{ 0xfa, 0x02, 0x00, 0x02, 0x00, 0x00, 0xfb },      /* up_send_ctl FanControl 2 */
	{ 0xfa, 0x02, 0x00, 0x03, 0x00, 0x00, 0xfb },      /* up_send_ctl FanControl 3 */
	{ 0xfa, 0x02, 0x00, 0x04, 0x00, 0x00, 0xfb },      /* up_send_ctl FanControl 4 */
	{ 0xfa, 0x03, 0x08, 0x01, 0x00, 0x00, 0xfb },      /* up_send_ctl GetThemister 1 */
	{ 0xfa, 0x03, 0x08, 0x02, 0x00, 0x00, 0xfb },      /* up_send_ctl GetThemister 2 */
	{ 0xfa, 0x03, 0x01, 0x00, 0x00, 0x00, 0xfb },      /* up_send_ctl DeviceReady   (v5) */
	{ 0xfa, 0x01, 0x00, 0x03, 0x01, 0x00, 0xfb },      /* up_send_ctl RDateAndTime  (v5: a read) */
};
static const char *const TX_NAME[TX_N] = { "FAN_LOW", "FAN_MEDIUM", "FAN_HIGH", "FAN_MAX", "THERM_SATA", "THERM_MAIN", "READY", "CLOCK_READ" };

/* v5: what the micro tells the host by itself. b1 of a 7-byte frame FA b1 00 00 xx xx FB -> WD's own name for it
 * (what WD's up_read_daemon stored when it was fed that frame under qemu-arm, Nov 17 2026). LOGGED ONLY. */
static const struct { unsigned char b1; const char *name, *what; } EVENT[] = {
	{ 0x21, "PWR", "power button" },
	{ 0x57, "PWR2", "power button, second event (WD's chk_io keeps it apart from PWR; which press it is: not decoded)" },
	{ 0x22, "RST", "reset button" },
	{ 0x52, "RST2", "reset button, second event (not decoded)" },
	{ 0x26, "UsbBackupPush", "USB copy button" },
	{ 0x23, "PWRPush", "power button down (WD's manufacturing mode)" },
	{ 0x2a, "PWRRelease", "power button up (WD's manufacturing mode)" },
	{ 0x24, "RSTPush", "reset button down (WD's manufacturing mode)" },
	{ 0x2b, "RSTRelease", "reset button up (WD's manufacturing mode)" },
	{ 0x25, "FUNCPush", "front scroll button down (WD's manufacturing mode)" },
	{ 0x2c, "FUNCRelease", "front scroll button up (WD's manufacturing mode)" },
	{ 0x27, "FUNC2Push", "second front scroll button down (WD's manufacturing mode)" },
	{ 0x2d, "FUNC2Release", "second front scroll button up (WD's manufacturing mode)" },
	{ 0x40, "PWR_LOST", "the micro's power-loss flag" },
	{ 0x41, "APR_STAT", "auto-power-recovery state" },
	{ 0x42, "WOL_STAT", "wake-on-LAN state" },
	{ 0x20, "RTCAlarm", "the micro's clock alarm" },
};
#define N_EVENT ((int)(sizeof EVENT / sizeof EVENT[0]))
#define EVENT_LOG_MAX 40                /* named events are logged this many times, then only counted */
#define CLOCK_UNSET   1767225600.0      /* 2026-01-01 00:00:00 UTC: a system clock before this was never set */
#define CLOCK_MAX     4102444800.0      /* 2100-01-01: the micro's two-digit year cannot say more */
static const char *const LEVEL_NAME[5] = { "?", "LOW", "MEDIUM", "HIGH", "MAX" };

/* ---------- v7: THE PANEL WHITELIST, by KIND. Every prefix = bytes WD's own up_send_ctl put on the wire under qemu-arm
 * (tests/captures/stock-lcd-frames-2026-11-17.json; the three power frames: tests/captures/
 * stock-power-frames-2026-11-17.json). A frame on the wire = FA + prefix + payload + FB. The table holds no FA and no FB byte,
 * so no whole frame sits in the binary: every LCD frame is built at run time and checked by frame_check() before it is sent. */
enum { R_TEXT, R_IP, R_FIXED, R_VOL, R_USED, R_TEMP, R_ARG };
enum { PK_NAME, PK_FW, PK_HEALTH, PK_FREE, PK_FAN, PK_IP1, PK_IP2, PK_IP1OFF, PK_IP2OFF, PK_VOL, PK_USED, PK_VOLCLEAN, PK_TEMP,
       PK_LCD, PK_STANDBY, PK_USB, PK_SHUTMSG, PK_RSTMSG, PK_POWEROFF, PK_N };
static const struct pkind {
	const char *name, *wd;              /* our name; WD's up_send_ctl command that made the captured bytes */
	unsigned char plen, pre[5], rule;   /* fixed prefix after FA; payload rule */
	unsigned char nargs, args[3];       /* R_ARG: the allowed values of the one argument byte */
} PK[PK_N] = {
	{ "name",     "SysName",           3, { 0x04, 0x01, 0x00 },             R_TEXT,  0, { 0 } },
	{ "fw",       "FirmwareVer",       3, { 0x04, 0x08, 0x00 },             R_TEXT,  0, { 0 } },
	{ "health",   "HDHealthy",         3, { 0x04, 0x84, 0x00 },             R_TEXT,  0, { 0 } },
	{ "free",     "CapacityFree",      3, { 0x04, 0x85, 0x00 },             R_TEXT,  0, { 0 } },
	{ "fan",      "FanSpeed",          3, { 0x04, 0x83, 0x00 },             R_TEXT,  0, { 0 } },
	{ "ip1",      "SysIP1",            4, { 0x04, 0x02, 0x01, 0x08 },       R_IP,    0, { 0 } },
	{ "ip2",      "SysIP2",            4, { 0x04, 0x02, 0x02, 0x08 },       R_IP,    0, { 0 } },
	{ "ip1off",   "SysIP1Dis",         5, { 0x04, 0x02, 0x04, 0x00, 0x00 }, R_FIXED, 0, { 0 } },
	{ "ip2off",   "SysIP2Dis",         5, { 0x04, 0x02, 0x08, 0x00, 0x00 }, R_FIXED, 0, { 0 } },
	{ "vol",      "VolStatus",         3, { 0x04, 0x04, 0x01 },             R_VOL,   0, { 0 } },
	{ "used",     "VolUsedPct",        4, { 0x04, 0x04, 0x03, 0x04 },       R_USED,  0, { 0 } },
	{ "volclean", "VolClean",          5, { 0x04, 0x04, 0x04, 0x00, 0x00 }, R_FIXED, 0, { 0 } },
	{ "temp",     "temperature",       4, { 0x04, 0x09, 0x00, 0x00 },       R_TEMP,  0, { 0 } },
	{ "lcd",      "LCDSleepMode",      2, { 0x04, 0x82 },                   R_ARG,   2, { 0x00, 0x01 } },
	{ "standby",  "Standby",           2, { 0x04, 0x06 },                   R_ARG,   3, { 0x01, 0x08, 0x00 } },    /* WD's 0, 3, 6 */
	{ "usb",      "usbExist",          2, { 0x04, 0x0a },                   R_ARG,   2, { 0x00, 0x01 } },
	{ "shutmsg",  "DeviceShutdownMsg", 5, { 0x03, 0x03, 0x04, 0x01, 0x00 }, R_FIXED, 0, { 0 } },
	{ "rstmsg",   "DeviceRstMsg",      5, { 0x03, 0x03, 0x05, 0x01, 0x00 }, R_FIXED, 0, { 0 } },
	{ "poweroff", "DeviceShutdown 1",  5, { 0x03, 0x03, 0x01, 0x01, 0x01 }, R_FIXED, 0, { 0 } },   /* gated twice: see ctl_poweroff */
};
#define TEXT_MAX 16                     /* our cap (WD's up_send_ctl has none); MFGLCD's 16 suggests a 2 x 16 glass */
#define FRAME_MAX 24
struct frame { unsigned char b[FRAME_MAX]; int n; };

static int frame_check(const unsigned char *b, int n)        /* -> the kind, or -1: THE WALL in front of the port */
{
	int k, i, m, L;
	if (n < 7 || n > FRAME_MAX || b[0] != 0xfa || b[n - 1] != 0xfb) return -1;
	m = n - 2;                                         /* payload length between FA and FB */
	for (k = 0; k < PK_N; k++) {
		const struct pkind *p = &PK[k]; const unsigned char *q = b + 1 + p->plen;
		if (m < p->plen || memcmp(b + 1, p->pre, p->plen)) continue;
		switch (p->rule) {
		case R_TEXT:
			L = q[0];
			if (m != p->plen + 1 + L || L < 1 || L > TEXT_MAX) return -1;
			for (i = 1; i <= L; i++) if (q[i] < 0x20 || q[i] > 0x7e) return -1;
			return k;
		case R_IP:
			if (m != p->plen + 8) return -1;
			for (i = 0; i < 8; i++) if (q[i] > 0x0f) return -1;
			return k;
		case R_FIXED:
			return m == p->plen ? k : -1;
		case R_VOL: {                                  /* LEN + ASCII "<vol><status><pct><valid>", exactly as WD forms it */
			int pl, pct = 0;
			L = q[0];
			if (m != p->plen + 1 + L || L < 4 || L > 6) return -1;
			for (i = 1; i <= L; i++) if (q[i] < '0' || q[i] > '9') return -1;
			if (q[1] < '1' || !strchr("01235", q[2]) || q[L] > '1') return -1;
			pl = L - 3;                                    /* the percent's digits */
			if (pl > 1 && q[3] == '0') return -1;          /* no leading zero */
			for (i = 0; i < pl; i++) pct = pct * 10 + (q[3 + i] - '0');
			return pct <= 100 ? k : -1;
		}
		case R_USED:
			return (m == p->plen + 2 && q[0] >= 1 && q[0] <= 9 && q[1] <= 100) ? k : -1;
		case R_TEMP:
			return (m == p->plen + 4 && q[1] == 0 && q[3] == 0 && q[0] <= 150 && q[2] <= 150) ? k : -1;
		case R_ARG:
			if (m != p->plen + 3 || q[1] || q[2]) return -1;
			for (i = 0; i < p->nargs; i++) if (q[0] == p->args[i]) return k;
			return -1;
		}
		return -1;
	}
	return -1;
}
static int fr_begin(struct frame *f, int k) { f->b[0] = 0xfa; memcpy(f->b + 1, PK[k].pre, PK[k].plen); f->n = 1 + PK[k].plen; return k; }
static int fr_end(struct frame *f, int k) { f->b[f->n++] = 0xfb; if (frame_check(f->b, f->n) != k) { f->n = 0; return -1; } return 0; }
static void ascii16(char *out, const char *in, int cap)   /* printable ASCII only, at most cap bytes, trimmed */
{
	int n = 0;
	for (; *in && n < cap; in++) if ((unsigned char)*in >= 0x20 && (unsigned char)*in <= 0x7e) out[n++] = *in;
	while (n && out[n - 1] == ' ') n--;
	out[n] = 0;
}
static int build_text(struct frame *f, int k, const char *s)
{
	char t[TEXT_MAX + 1]; int L;
	if (k < 0 || k >= PK_N || PK[k].rule != R_TEXT) return -1;
	ascii16(t, s, TEXT_MAX); L = strlen(t);
	if (!L) return -1;
	fr_begin(f, k); f->b[f->n++] = L; memcpy(f->b + f->n, t, L); f->n += L;
	return fr_end(f, k);
}
static int build_ip(struct frame *f, int k, struct in_addr a)         /* the 4 octets last first, each low nibble then high */
{
	const unsigned char *o = (const unsigned char *)&a.s_addr; int i;
	if (k != PK_IP1 && k != PK_IP2) return -1;
	fr_begin(f, k);
	for (i = 3; i >= 0; i--) { f->b[f->n++] = o[i] & 15; f->b[f->n++] = o[i] >> 4; }
	return fr_end(f, k);
}
static int build_fixed(struct frame *f, int k) { if (k < 0 || k >= PK_N || PK[k].rule != R_FIXED) return -1; fr_begin(f, k); return fr_end(f, k); }
static int build_vol(struct frame *f, int vol, int st, int pct, int valid)
{
	char t[16]; int L;
	if (vol < 1 || vol > 9 || pct < 0 || pct > 100 || valid < 0 || valid > 1 || (st != 0 && st != 1 && st != 2 && st != 3 && st != 5)) return -1;
	L = snprintf(t, sizeof t, "%d%d%d%d", vol, st, pct, valid);
	fr_begin(f, PK_VOL); f->b[f->n++] = L; memcpy(f->b + f->n, t, L); f->n += L;
	return fr_end(f, PK_VOL);
}
static int build_used(struct frame *f, int vol, int pct)
{
	if (vol < 1 || vol > 9 || pct < 0 || pct > 100) return -1;
	fr_begin(f, PK_USED); f->b[f->n++] = vol; f->b[f->n++] = pct;
	return fr_end(f, PK_USED);
}
static int build_temp(struct frame *f, int a, int b)                  /* two little-endian 16-bit values, 0..150 */
{
	if (a < 0 || a > 150 || b < 0 || b > 150) return -1;
	fr_begin(f, PK_TEMP); f->b[f->n++] = a; f->b[f->n++] = 0; f->b[f->n++] = b; f->b[f->n++] = 0;
	return fr_end(f, PK_TEMP);
}
static int build_arg(struct frame *f, int k, int v)
{
	if (k < 0 || k >= PK_N || PK[k].rule != R_ARG || v < 0 || v > 255) return -1;
	fr_begin(f, k); f->b[f->n++] = v; f->b[f->n++] = 0; f->b[f->n++] = 0;
	return fr_end(f, k);
}
static int standby_code(int wd)        /* WD's Standby argument -> its byte; only the three captured ones */
{
	return wd == 0 ? 0x01 : wd == 3 ? 0x08 : wd == 6 ? 0x00 : -1;
}

/* WD's thermistor table (up_read_daemon .data at 0x12644, 192 bytes): raw value -> degrees C. Past its end WD reads zeros. */
static const unsigned char LUT[192] = {
	127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 127, 125, 122, 119,
	116, 113, 110, 108, 106, 103, 102, 100,  98,  96,  94,  93,  91,  90,  88,  87,
	 85,  84,  83,  82,  81,  80,  79,  77,  76,  75,  74,  73,  72,  71,  70,  70,
	 69,  68,  67,  66,  65,  65,  64,  63,  62,  62,  61,  60,  59,  59,  58,  57,
	 57,  56,  55,  55,  54,  53,  53,  52,  52,  51,  51,  50,  49,  49,  48,  48,
	 47,  47,  46,  46,  45,  44,  44,  43,  43,  42,  42,  41,  41,  41,  40,  40,
	 39,  39,  38,  38,  37,  37,  36,  36,  35,  35,  34,  34,  33,  33,  32,  32,
	 32,  31,  31,  30,  30,  30,  29,  29,  28,  28,  27,  27,  27,  26,  26,  26,
	 25,  25,  24,  24,  23,  23,  23,  22,  22,  21,  21,  20,  20,  20,  19,  19,
	 19,  18,  18,  17,  17,  16,  16,  16,  15,  15,  14,  14,  13,  13,  13,  13,
	 12,  12,  11,  11,  10,  10,  10,   9,   9,   8,   8,   7,   7,   7,   6,   6,
	  5,   5,   4,   4,   3,   3,   3,   2,   2,   1,   1,   0,   0,   0,   0,   0
};

/* ---------- the curve: WD's four states, every threshold 16 C cooler ---------- */
#define SHIFT       16
#define UP_LOW      (62 - SHIFT)        /* LOW -> MEDIUM at T >= 46 */
#define UP_MEDIUM   (64 - SHIFT)        /* MEDIUM -> HIGH at T >= 48 */
#define UP_HIGH     (66 - SHIFT)        /* HIGH -> MAX at T >= 50 */
#define DN_MEDIUM   (57 - SHIFT)        /* MEDIUM -> LOW at T <= 41 */
#define DN_HIGH     (60 - SHIFT)        /* HIGH -> MEDIUM at T <= 44 */
#define DN_MAX      (61 - SHIFT)        /* MAX -> HIGH at T <= 45 */
#define DRIVE_REBOOT 55                 /* any drive at or above this: back to stock */
#define SOC_MAX     90                  /* SoC thermal zone at or above this: fan MAX */

static int curve_step(int state, int t)             /* one reading through WD's state machine */
{
	switch (state) {
	case 1: return t >= UP_LOW ? 2 : 1;
	case 2: return t >= UP_MEDIUM ? 3 : t <= DN_MEDIUM ? 1 : 2;
	case 3: return t >= UP_HIGH ? 4 : t <= DN_HIGH ? 2 : 3;
	default: return t <= DN_MAX ? 3 : 4;
	}
}
static int curve_next(int state, int t)             /* up: as far as it goes; down: one step */
{
	int n = curve_step(state, t);
	while (n > state && n < 4) { int m = curve_step(n, t); if (m <= n) break; n = m; }
	return n;
}

/* ---------- timing (seconds; --fast, test only, makes every one of them ten times shorter) ---------- */
static double K = 1.0;
#define ACK_MS        300               /* WD: one try every 300 ms */
#define TRIES         10                /* WD: up to 10 tries */
#define T_TEMP        30.0
#define T_TACH        10.0
#define T_STATUS      60.0
#define T_HOLD_HIGH   60.0
#define T_MCU_START   30.0
#define T_MCU_SILENT  120.0
#define T_RPM_ZERO    30.0
#define T_FLUSH       6.0
#define T_HEARTBEAT   180.0
#define T_RETRY       15.0              /* a fan command that was not ACKed is sent again this often */
#define T_STATFILE    5.0
#define T_READY       10.0              /* v5: DeviceReady goes out no sooner than this after the start */
#define T_READY_AGAIN 60.0              /* ... and once more this long after a try that was not ACKed (two tries in all) */
#define T_CLOCK_AGAIN 30.0              /* v5: the clock is asked once more this long after a try that got no answer */
#define TACH_WINDOW   1.0               /* v7: WD's own one-second window (v5 spun for 0.5 s) */
#define TACH_SAMPLE_NS 1000000L         /* v7 fallback: one level read per millisecond (rising edges come >= 5.5 ms apart) */
#define TACH_EVENTS   256               /* v7: the kernel's event FIFO for the line: 3 s of edges at 2500 rpm */
#define T_COLLECT     10.0              /* v7: host name, addresses, md state, space, alerts: read this often */
#define T_LCD_GAP     0.3               /* v7: at most one LCD frame per 300 ms */
#define T_LCD_REFRESH 600.0             /* v7: every field again this often (the micro may have restarted) */
#define LCD_TRIES     3                 /* v7: an LCD frame is tried this many times (300 ms each), then dropped and counted */
#define T_HB_MIN      10.0              /* v7: the supervisor's heartbeat at most this often */
#define T_POLL_MAX    30.0              /* v7: the longest the main poll() sleeps */
#define MAX_CRASHES   5

/* ---------- paths ---------- */
static const char *root;                /* --test-root */
static int test_hw;
static const char *opt_tty = "ttyS1";               /* uart1: the kernel's name of the port (--tty, test only, names another) */
static const char *opt_chip = "10140.gpio";        /* the high GPIO bank, f1010140.gpio */
static int opt_line = 7;                           /* GPIO 39 = 32 + 7 */
static char p_log[300], p_status[300], p_pid[300], p_notes[300], p_logpid[300], p_kmsg[300], p_reboot[300], p_now[300], p_clockset[300];
static char p_json[300], p_run[300], p_ctl[300], p_alerts[300], p_conf[300];      /* v7 */
static char p_sendtest[300];                                                        /* v8 */
static int opt_panel, opt_poweroff;                /* v7: --panel, --allow-poweroff */

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}
static void nap(double s)
{
	struct timespec ts;
	if (s <= 0) return;
	ts.tv_sec = (time_t)s; ts.tv_nsec = (long)((s - (double)ts.tv_sec) * 1e9);
	nanosleep(&ts, NULL);
}
static long slurp(const char *path, char *buf, size_t cap)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC); size_t got = 0; ssize_t r;
	if (cap) buf[0] = 0;
	if (fd < 0) return -1;
	while (got + 1 < cap && (r = read(fd, buf + got, cap - 1 - got)) > 0) got += r;
	close(fd);
	buf[got] = 0;
	return got;
}
static void append(const char *path, const char *line)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
	if (fd < 0) return;
	if (write(fd, line, strlen(line)) < 0) { }
	close(fd);
}

/* ---------- the log: kernel ring (RAM + ex4log's disk log) and /tmp/ex4fan.log ---------- */
static void kmsg(const char *line)
{
	char b[400]; int fd, n;
	n = snprintf(b, sizeof b, "ex4fan: %s\n", line);
	if (root) { append(p_kmsg, b); return; }
	fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	if (fd < 0) {
		const char *node = "/dev/.ex4fan-kmsg";
		if (mknod(node, S_IFCHR | 0600, makedev(1, 11)) && errno != EEXIST) return;
		fd = open(node, O_WRONLY | O_CLOEXEC);
		if (fd < 0) return;
	}
	if (write(fd, b, n) < 0) { }          /* one open per line: the rate limit of /dev/kmsg is per open file */
	close(fd);
}
static void mark(const char *fmt, ...)
{
	char line[360], b[420]; va_list ap;
	va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
	kmsg(line);
	snprintf(b, sizeof b, "[%9.2f] %s\n", now(), line);
	append(p_log, b);
}
static void note_disklog(const char *text)          /* what `ex4log note` does: a line in /tmp/ex4-notes, and poke the logger */
{
	char b[420], p[32]; int pid;
	snprintf(b, sizeof b, "[%9.2f] ex4fan: %s\n", now(), text);
	append(p_notes, b);
	if (slurp(p_logpid, p, sizeof p) > 0 && (pid = atoi(p)) > 1 && !root) kill(pid, SIGUSR1);
}

/* ---------- the micro: one port, six frames out, a 7-byte parser in ---------- */
static int tty = -1;
static double last_rx;                  /* when the last valid frame came in (0 = never) */
static unsigned n_rx, n_ack, n_other, n_sent, n_cmd, n_cmd_acked;
static int got_ack;
static int therm[3] = { -1, -1, -1 };   /* [1] SATA board, [2] main board: degrees C */
static int therm_raw[3];
static double therm_at[3];
static unsigned char rxb[16]; static int rxn;
static unsigned n_event, n_clock;       /* v5 */
static struct { double t; int i; } evring[8]; static unsigned evn;    /* v7: the last eight named events (JSON) */
static double clock_at;                 /* when the last clock frame came in (0 = never) */
static int clock_state;                 /* 0 none, 1 read (logged), 2 the system clock was set from it */
static int ready_state, ready_tries; static double ready_at;      /* DeviceReady: 0 not sent, 1 ACKed, -1 sent, never ACKed */
static int clock_tries; static double clock_asked;
static double wall(void)                /* the system clock, seconds since 1970 (test: DIR/now when that file is there) */
{
	struct timespec ts;
	if (root) { char b[40]; if (slurp(p_now, b, sizeof b) > 0) return atof(b); }
	clock_gettime(CLOCK_REALTIME, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}
static int bcd(unsigned char c) { return ((c >> 4) > 9 || (c & 15) > 9) ? -1 : (c >> 4) * 10 + (c & 15); }
static double utc_epoch(int y, int mo, int d, int h, int mi, int sec)       /* days-from-civil; no libc time zone in it */
{
	long era, yoe, doy, doe, days;
	y -= mo <= 2;
	era = (y >= 0 ? y : y - 399) / 400; yoe = y - era * 400;
	doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1; doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
	days = era * 146097 + doe - 719468;
	return (double)days * 86400.0 + h * 3600.0 + mi * 60.0 + sec;
}
static void clock_in(const unsigned char *f)        /* f = FA 01 00 03 xx SS MM HH DW DD MO YY FB, checked */
{
	int sec = bcd(f[5]), mi = bcd(f[6]), h = bcd(f[7]), d = bcd(f[9]), mo = bcd(f[10]), y = bcd(f[11]); double t, sys;
	last_rx = now(); n_rx++; n_clock++; clock_at = last_rx;
	if (sec < 0 || sec > 59 || mi < 0 || mi > 59 || h < 0 || h > 23 || d < 1 || d > 31 || mo < 1 || mo > 12 || y < 0) {
		mark("clock: the micro sent a clock frame that is not a date (raw %02x %02x %02x %02x %02x %02x %02x): ignored", f[5], f[6], f[7], f[8], f[9], f[10], f[11]);
		return;
	}
	t = utc_epoch(2000 + y, mo, d, h, mi, sec); sys = wall();
	if (clock_state == 0) clock_state = 1;
	mark("clock: the micro says %04d-%02d-%02d %02d:%02d:%02d UTC (raw %02x %02x %02x %02x %02x %02x %02x = sec min hour dow day month year, BCD); the system clock says %.0f; micro - system = %+.0f s",
		2000 + y, mo, d, h, mi, sec, f[5], f[6], f[7], f[8], f[9], f[10], f[11], sys, t - sys);
	if (sys >= CLOCK_UNSET) return;                   /* somebody (NTP, a human) has set the system clock: the micro's is only logged */
	if (t < CLOCK_UNSET || t >= CLOCK_MAX) { mark("clock: the system clock is unset and the micro's date is before 2026 or past 2099: not used"); return; }
	if (root) { char b[80]; snprintf(b, sizeof b, "SETCLOCK %.0f\n", t); append(p_clockset, b); }
	else { struct timespec ts; ts.tv_sec = (time_t)t; ts.tv_nsec = 0; if (clock_settime(CLOCK_REALTIME, &ts)) { mark("clock: could not set the system clock: %s", strerror(errno)); return; } }
	clock_state = 2;
	mark("clock: the system clock was unset (%.0f): SET from the micro's clock to %04d-%02d-%02d %02d:%02d:%02d UTC (NTP corrects it later if it can)", sys, 2000 + y, mo, d, h, mi, sec);
}

static int port_write(const unsigned char *b, size_t n)      /* THE ONLY WRITER OF THE PORT. Called by mcu_write() (TX[] index) and */
{                                                           /* panel_write() (a frame that passed frame_check()), nothing else. */
	if (tty < 0 || !n) return -1;
	n_sent++;
	return write(tty, b, n) == (ssize_t)n ? 0 : -1;
}
static int mcu_write(int idx)           /* a fan / thermistor / ready / clock frame: an index into TX[], never bytes */
{
	if (idx < 0 || idx >= TX_N) return -1;
	return port_write(TX[idx], sizeof TX[idx]);
}

static void frame_in(const unsigned char *f)        /* f = FA b1 b2 b3 b4 b5 FB, checked */
{
	last_rx = now(); n_rx++;
	if (f[1] == 0x30 && f[2] == 0x00 && f[3] == 0x00) { got_ack = 1; n_ack++; return; }
	if (f[1] == 0x03 && f[2] == 0x08 && (f[3] == 1 || f[3] == 2)) {
		therm_raw[f[3]] = f[5];
		therm[f[3]] = f[5] < sizeof LUT ? LUT[f[5]] : 0;
		therm_at[f[3]] = last_rx;
		return;
	}
	if (f[2] == 0x00 && f[3] == 0x00) {               /* v5: the micro's own events, by WD's names. Logged, nothing else. */
		int i;
		for (i = 0; i < N_EVENT; i++) if (EVENT[i].b1 == f[1]) {
			evring[evn % 8].t = last_rx; evring[evn % 8].i = i; evn++;
			if (n_event++ < EVENT_LOG_MAX) mark("event %s: %s (frame %02x %02x %02x %02x %02x): logged only, no action", EVENT[i].name, EVENT[i].what, f[1], f[2], f[3], f[4], f[5]);
			return;
		}
	}
	if (n_other++ < 12) mark("micro sent a frame this daemon has no use for: %02x %02x %02x %02x %02x (ignored)", f[1], f[2], f[3], f[4], f[5]);
}
static void byte_in(unsigned char c)                /* WD's own framing: FA starts a frame, the 7th byte must be FB */
{
	if (c == 0xfa) { rxb[0] = c; rxn = 1; return; }
	if (rxn == 0) return;
	rxb[rxn++] = c;
	if (rxn == 7) {
		if (c == 0xfb) { frame_in(rxb); rxn = 0; }
	} else if (rxn == 13) {                           /* v5: the 13-byte clock frame (WD's reader: 13 bytes ending in FB) */
		if (c == 0xfb && rxb[1] == 0x01 && rxb[2] == 0x00 && rxb[3] == 0x03) { clock_in(rxb); rxn = 0; }
		else if (c == 0xfb) {                           /* 13 bytes ending in FB with another head: on record, so a run shows what the real micro sends */
			last_rx = now(); n_rx++;
			if (n_other++ < 12) mark("micro sent a 13-byte frame this daemon has no use for: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x (ignored)", rxb[1], rxb[2], rxb[3], rxb[4], rxb[5], rxb[6], rxb[7], rxb[8], rxb[9], rxb[10], rxb[11]);
			rxn = 0;
		}
	} else if (rxn >= 15) {                           /* the micro's 15-byte frame (its version): never asked for */
		if (c == 0xfb && n_other++ < 12) mark("micro sent a 15-byte frame this daemon has no use for: %02x %02x %02x ... (ignored)", rxb[1], rxb[2], rxb[3]);
		rxn = 0;
	}
}
static void mcu_pump(int ms)                        /* read what the micro sent, for up to ms */
{
	struct pollfd p; unsigned char b[64]; double end = now() + ms / 1000.0; int n, i, left;
	if (tty < 0) { nap(ms / 1000.0); return; }
	for (;;) {
		left = (int)((end - now()) * 1000.0 + 0.999);      /* v7: rounded UP (v5 rounded down: a burst of zero-timeout polls in its last ms) */
		if (left < 0) left = 0;
		p.fd = tty; p.events = POLLIN; p.revents = 0;
		if (poll(&p, 1, left) > 0 && (p.revents & POLLIN)) {
			n = read(tty, b, sizeof b);
			for (i = 0; i < n; i++) byte_in(b[i]);
		} else if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) nap(0.05);
		if (now() >= end) return;
	}
}
static int wait_ack(void)                           /* up to one ACK window */
{
	double end = now() + ACK_MS / 1000.0;
	while (!got_ack && now() < end) mcu_pump(20);
	return got_ack;
}
static int mcu_cmd(int idx)                         /* WD's cadence: send, 300 ms for the ACK, up to 10 times. Returns the try that was ACKed, 0 = never */
{
	int t;
	n_cmd++;
	for (t = 1; t <= TRIES; t++) {
		got_ack = 0;
		if (mcu_write(idx)) { nap(ACK_MS / 1000.0); continue; }
		if (wait_ack()) { n_cmd_acked++; return t; }
	}
	return 0;
}
static int poweroff_armed;              /* v7: set only inside ctl_poweroff(), for the one frame, and only with --allow-poweroff */
static int panel_write(const unsigned char *b, int n)       /* v7: a panel frame reaches the port only through frame_check() */
{
	int k = frame_check(b, n);
	if (k < 0) { mark("panel: REFUSED a frame that is not a whitelisted kind (%d bytes): not sent", n); return -2; }
	if (k == PK_POWEROFF && !(opt_poweroff && poweroff_armed)) { mark("panel: REFUSED the poweroff frame outside ctl_poweroff with --allow-poweroff: not sent"); return -2; }
	return port_write(b, (size_t)n);
}
static int frame_cmd(const struct frame *f, int tries)      /* v7: send one checked panel frame, ACK wait 300 ms per try. Try that was ACKed, 0 = never, -1 = refused */
{
	int t, w;
	n_cmd++;
	for (t = 1; t <= tries; t++) {
		got_ack = 0;
		if ((w = panel_write(f->b, f->n)) == -2) return -1;
		if (w) { nap(ACK_MS / 1000.0); continue; }
		if (wait_ack()) { n_cmd_acked++; return t; }
	}
	return 0;
}
static int mcu_query(int idx, int which)            /* a thermistor: ACK, then its data frame. Returns degrees C or -1 */
{
	double t0 = now(), end; int tries;
	tries = mcu_cmd(idx);
	end = now() + (tries ? 1.0 : 0.3);
	while (therm_at[which] < t0 && now() < end) mcu_pump(20);
	return therm_at[which] >= t0 ? therm[which] : -1;
}

static void clock_ask(void)                         /* v5: read the micro's clock (a query; nothing is written to the micro's clock) */
{
	double t0 = now(), end; int t;
	clock_tries++; clock_asked = t0; n_cmd++;
	for (t = 1; t <= TRIES; t++) {
		got_ack = 0;
		if (mcu_write(TX_CLOCK_READ)) { nap(ACK_MS / 1000.0); continue; }
		end = now() + ACK_MS / 1000.0;
		while (!got_ack && clock_at < t0 && now() < end) mcu_pump(20);
		if (got_ack || clock_at >= t0) break;
	}
	if (t <= TRIES) n_cmd_acked++;
	end = now() + 1.0;
	while (clock_at < t0 && now() < end) mcu_pump(20);
	if (clock_at < t0) mark("clock: asked the micro for its clock (try %d of 2): %s, no clock frame came back", clock_tries, t <= TRIES ? "ACKed" : "no answer");
}
static void ready_send(void)                        /* v5: WD's DeviceReady, the host's "the system is up" */
{
	int tries = mcu_cmd(TX_READY);
	ready_tries++; ready_at = now(); ready_state = tries > 0 ? 1 : -1;
	mark("cmd READY (WD's DeviceReady) ack=%d tries=%d (try %d of 2)", tries > 0, tries ? tries : TRIES, ready_tries);
}

static int node_for(const char *sysdev, const char *want, const char *mine, char *out, size_t cap)
{       /* a device node: the system's own if it is there, else one made here from the kernel's major:minor */
	char b[64]; int ma, mi;
	if (access(want, F_OK) == 0) { snprintf(out, cap, "%s", want); return 0; }
	if (slurp(sysdev, b, sizeof b) <= 0 || sscanf(b, "%d:%d", &ma, &mi) != 2) return -1;
	if (mknod(mine, (strstr(sysdev, "/block/") ? S_IFBLK : S_IFCHR) | 0600, makedev(ma, mi)) && errno != EEXIST) return -1;
	snprintf(out, cap, "%s", mine);
	return 0;
}
static int tty_open(void)
{
	struct termios t; char path[300], sysdev[80], want[40], mine[48]; double end = now() + 10 * K;
	snprintf(sysdev, sizeof sysdev, "/sys/class/tty/%s/dev", opt_tty);
	snprintf(want, sizeof want, "/dev/%s", opt_tty);
	snprintf(mine, sizeof mine, "/dev/.ex4fan-%s", opt_tty);
	for (;;) {
		if (root) snprintf(path, sizeof path, "%s/tty", root);
		else if (node_for(sysdev, want, mine, path, sizeof path)) path[0] = 0;
		if (path[0] && (tty = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)) >= 0) break;
		if (now() >= end) return -1;
		nap(0.5 * K);
	}
	memset(&t, 0, sizeof t);
	t.c_iflag = IGNPAR;                                /* what WD's librs232 sets: raw, 8N1, no flow control */
	t.c_cflag = CS8 | CREAD | CLOCAL;
	cfsetispeed(&t, B19200); cfsetospeed(&t, B19200);
	t.c_cc[VMIN] = 0; t.c_cc[VTIME] = 0;
	tcflush(tty, TCIOFLUSH);
	if (tcsetattr(tty, TCSANOW, &t)) { close(tty); tty = -1; return -1; }
	mark("port %s open: 19200 8N1, raw, no flow control", path);
	return 0;
}

/* ---------- drive temperatures: SMART attribute 194 through an ATA pass-through (read-only) ---------- */
#define MAXDRV 8
/* v7: nine SMART attributes for the web UI, out of the sector this daemon already reads for 194 (REVIEW nit 1) */
static const unsigned char SMART_ID[] = { 5, 9, 10, 12, 187, 194, 197, 198, 199 };
#define N_SMART ((int)sizeof SMART_ID)
enum { PW_UNKNOWN, PW_ACTIVE, PW_STANDBY };
static const char *const PW_NAME[3] = { "unknown", "active", "standby" };
static struct drv { char name[8]; int temp; int power; int smart_ok; long long attr[N_SMART]; } drv[MAXDRV], drv_old[MAXDRV];
static int ndrv, ndrv_old, usb_disks;

static int smart_temp(const char *name, struct drv *dv)    /* degrees C, -1, or -2 = in standby (not woken, nothing read) */
{
	unsigned char cdb[16] = { 0x85, 4 << 1, 0x0e, 0, 0xd0, 0, 1, 0, 0, 0, 0x4f, 0, 0xc2, 0, 0xb0, 0 };
	/* ATA PASS-THROUGH(16), PIO data-in, one sector from the device: SMART (B0) READ DATA (D0), LBA mid/high 4F/C2 */
	unsigned char pm[16] = { 0x85, 3 << 1, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xe5, 0 };
	/* v7: ATA PASS-THROUGH(16), NON-DATA, CK_COND: CHECK POWER MODE (E5); the count register comes back in the sense data */
	unsigned char buf[512], sense[32], sum = 0; struct sg_io_hdr h; char sysdev[64], want[32], mine[40], path[64];
	int fd, i, j, t194 = -1, t190 = -1, cnt = -1;
	dv->power = PW_UNKNOWN; dv->smart_ok = 0;
	for (j = 0; j < N_SMART; j++) dv->attr[j] = -1;
	snprintf(sysdev, sizeof sysdev, "/sys/block/%s/dev", name);
	snprintf(want, sizeof want, "/dev/%s", name);
	snprintf(mine, sizeof mine, "/dev/.ex4fan-%s", name);
	if (node_for(sysdev, want, mine, path, sizeof path)) return -1;
	fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);          /* read-only: this file has no write to a disk */
	if (fd < 0) return -1;
	memset(&h, 0, sizeof h); memset(sense, 0, sizeof sense);
	h.interface_id = 'S'; h.dxfer_direction = SG_DXFER_NONE;
	h.cmd_len = sizeof pm; h.cmdp = pm; h.mx_sb_len = sizeof sense; h.sbp = sense; h.timeout = 5000;
	if (ioctl(fd, SG_IO, &h) == 0 && h.sb_len_wr >= 8) {
		if ((sense[0] & 0x7f) == 0x72) {                          /* descriptor sense: the ATA Status Return descriptor (09) */
			for (i = 8; i + 13 < 32 && i < 8 + sense[7]; i += 2 + sense[i + 1]) if (sense[i] == 0x09) { cnt = sense[i + 5]; break; }
		} else if ((sense[0] & 0x7e) == 0x70) cnt = sense[6];      /* fixed sense: libata puts the count at byte 6 */
	}
	if (cnt == 0x00) { close(fd); dv->power = PW_STANDBY; return -2; }      /* asleep: SMART READ DATA would spin it up */
	if (cnt > 0) dv->power = PW_ACTIVE;
	memset(&h, 0, sizeof h); memset(buf, 0, sizeof buf);
	h.interface_id = 'S'; h.dxfer_direction = SG_DXFER_FROM_DEV;
	h.cmd_len = sizeof cdb; h.cmdp = cdb; h.mx_sb_len = sizeof sense; h.sbp = sense;
	h.dxfer_len = sizeof buf; h.dxferp = buf; h.timeout = 5000;
	i = ioctl(fd, SG_IO, &h);
	close(fd);
	if (i < 0 || h.status || h.host_status || (h.driver_status & 0x0f)) return -1;
	for (i = 0; i < 512; i++) sum += buf[i];
	if (sum) return -1;                                           /* the SMART data sector carries a checksum */
	dv->smart_ok = 1;
	for (i = 0; i < 30; i++) {
		const unsigned char *e = buf + 2 + 12 * i;
		if (e[0] == 194) t194 = e[5];                               /* raw value, low byte (WD reads the same field through smartctl) */
		if (e[0] == 190) t190 = e[5];
		for (j = 0; j < N_SMART; j++) if (e[0] && e[0] == SMART_ID[j]) {      /* raw value: 48 bits, little-endian */
			long long r = 0; int k;
			for (k = 10; k >= 5; k--) r = (r << 8) | e[k];
			if (SMART_ID[j] == 194 || SMART_ID[j] == 9) r &= SMART_ID[j] == 194 ? 0xff : 0xffffffffLL;   /* temp: low byte; hours: low 32 bits */
			dv->attr[j] = r;
		}
	}
	if (t194 < 1 || t194 > 110) t194 = (t190 >= 1 && t190 <= 110) ? t190 : -1;
	return t194;
}
static int drv_find_old(const char *name) { int i; for (i = 0; i < ndrv_old; i++) if (!strcmp(drv_old[i].name, name)) return i; return -1; }
static void drv_asleep(struct drv *d)              /* a drive in standby keeps its last reading (it is not heating) */
{
	int o = drv_find_old(d->name);
	if (o >= 0) { int pw = d->power; *d = drv_old[o]; d->power = pw; }
	else d->temp = -1;
}
static void drives_read(void)
{
	memcpy(drv_old, drv, sizeof drv); ndrv_old = ndrv;
	ndrv = 0;
	if (root) {
		char b[2048], p[300], *s, *e; int t;
		snprintf(p, sizeof p, "%s/usb", root); usb_disks = slurp(p, b, sizeof b) > 0 ? atoi(b) : 0;
		snprintf(p, sizeof p, "%s/drives", root);
		if (slurp(p, b, sizeof b) <= 0) return;
		for (s = b; *s && ndrv < MAXDRV; s = e) {
			struct drv *d = &drv[ndrv]; char *tok, *sv; int j, n = 0;
			e = strchr(s, '\n'); if (e) *e++ = 0; else e = s + strlen(s);
			memset(d, 0, sizeof *d); d->power = PW_ACTIVE;
			for (j = 0; j < N_SMART; j++) d->attr[j] = -1;
			for (tok = strtok_r(s, " \t", &sv); tok; tok = strtok_r(NULL, " \t", &sv), n++) {
				if (n == 0) snprintf(d->name, sizeof d->name, "%.7s", tok);
				else if (n == 1) { t = atoi(tok); d->temp = t; }
				else if (!strcmp(tok, "power=standby")) d->power = PW_STANDBY;
				else { int id; long long v; if (sscanf(tok, "%d=%lld", &id, &v) == 2) for (j = 0; j < N_SMART; j++) if (SMART_ID[j] == id) { d->attr[j] = v; d->smart_ok = 1; } }
			}
			if (n < 2) continue;
			if (d->smart_ok) { for (j = 0; j < N_SMART; j++) if (SMART_ID[j] == 194 && d->attr[j] < 0) d->attr[j] = d->temp; }
			if (d->power == PW_STANDBY) drv_asleep(d);
			ndrv++;
		}
		return;
	} else {
		DIR *d = opendir("/sys/block"); struct dirent *de; char names[MAXDRV][8]; int n = 0, i, j, usb = 0;
		if (!d) return;
		memset(names, 0, sizeof names);
		while ((de = readdir(d)) && n < MAXDRV) if (de->d_name[0] == 's' && de->d_name[1] == 'd' && strlen(de->d_name) == 3) {
			char lp[300], tgt[300]; ssize_t k; static char usb_said[26];
			snprintf(lp, sizeof lp, "/sys/block/%s", de->d_name);
			k = readlink(lp, tgt, sizeof tgt - 1);            /* v5: USB 3 works now, so a USB disk can show up as sdX. It is not in a bay: */
			if (k > 0) { tgt[k] = 0; if (strstr(tgt, "/usb")) { /* no SMART through its bridge, and not this fan's to cool. Not counted. */
				int c = de->d_name[2] - 'a';
				usb++;
				if (c >= 0 && c < 26 && !usb_said[c]) { usb_said[c] = 1; mark("%s is a USB disk (not in a bay): not counted as a drive", de->d_name); }
				continue; } }
			memcpy(names[n++], de->d_name, 4);
		}
		closedir(d);
		usb_disks = usb;
		for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) if (strcmp(names[i], names[j]) > 0) { char t[8]; memcpy(t, names[i], 8); memcpy(names[i], names[j], 8); memcpy(names[j], t, 8); }
		for (i = 0; i < n; i++) {
			memset(&drv[ndrv], 0, sizeof drv[ndrv]); memcpy(drv[ndrv].name, names[i], 8);
			drv[ndrv].temp = smart_temp(names[i], &drv[ndrv]);
			if (drv[ndrv].temp == -2) drv_asleep(&drv[ndrv]);
			ndrv++;
		}
	}
}
static int soc_read(void)                           /* degrees C, or -1 */
{
	char b[32], p[300];
	if (root) snprintf(p, sizeof p, "%s/soc", root); else snprintf(p, sizeof p, "/sys/class/thermal/thermal_zone0/temp");
	if (slurp(p, b, sizeof b) <= 0) return -1;
	return atoi(b) / 1000;
}

/* ---------- the tachometer: GPIO 39 (v7: edge events with kernel timestamps; fallback 1 ms sampling; never a spin) ---------- */
enum { TM_NONE, TM_EDGE, TM_SAMPLE, TM_SYSFS };
static const char *const TM_NAME[4] = { "none", "edge", "sample", "sysfs" };
static int tach_fd = -1, tach_sysfs = -1, tach_mode = TM_NONE; static unsigned long tach_samples;
static double tach_win_end;                         /* > 0: an edge window is open until then */
static unsigned tach_edges_last;                    /* rising edges seen in the last window (JSON) */

static int rpm_from_ns(const unsigned long long *ts, int k)        /* k rising-edge timestamps -> rpm (two pulses a turn) */
{
	double dt;
	if (k < 3) return 0;                              /* WD: a change or two in the window is noise, not a turning fan */
	dt = (double)(ts[k - 1] - ts[0]);
	if (dt <= 0) return -1;
	return (int)((k - 1) * 30e9 / dt + 0.5);
}
static int tach_edges_set(int on)                   /* switch the line's rising-edge detection on / off (0 = done) */
{
	struct gpio_v2_line_config c;
	memset(&c, 0, sizeof c);
	c.flags = GPIO_V2_LINE_FLAG_INPUT | (on ? GPIO_V2_LINE_FLAG_EDGE_RISING : 0);
	return ioctl(tach_fd, GPIO_V2_LINE_SET_CONFIG_IOCTL, &c);
}
static void tach_init(void)
{
	char path[64], want[32], sysdev[80], mine[40]; struct gpiochip_info ci; struct gpio_v2_line_request rq; int n, fd;
	if (root) return;
	for (n = 0; n < 8 && tach_fd < 0; n++) {
		snprintf(sysdev, sizeof sysdev, "/sys/bus/gpio/devices/gpiochip%d/dev", n);
		snprintf(want, sizeof want, "/dev/gpiochip%d", n);
		snprintf(mine, sizeof mine, "/dev/.ex4fan-gpiochip%d", n);
		if (node_for(sysdev, want, mine, path, sizeof path)) continue;
		fd = open(path, O_RDONLY | O_CLOEXEC);
		if (fd < 0) continue;
		memset(&ci, 0, sizeof ci);
		if (ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, &ci) == 0 && strstr(ci.label, opt_chip) && (int)ci.lines > opt_line) {
			memset(&rq, 0, sizeof rq);
			rq.offsets[0] = opt_line; rq.num_lines = 1;
			rq.config.flags = GPIO_V2_LINE_FLAG_INPUT;             /* the pin is an input already (read live on stock) */
			rq.event_buffer_size = TACH_EVENTS;                     /* v7 */
			snprintf(rq.consumer, sizeof rq.consumer, "ex4fan-tach");
			if (ioctl(fd, GPIO_V2_GET_LINE_IOCTL, &rq) == 0) {
				tach_fd = rq.fd; fcntl(tach_fd, F_SETFL, fcntl(tach_fd, F_GETFL) | O_NONBLOCK);
				/* v7: can this line raise edge interrupts? Ask once now (and switch it off again): ENXIO = no IRQ for it */
				if (tach_edges_set(1) == 0 && tach_edges_set(0) == 0) tach_mode = TM_EDGE;
				else { tach_mode = TM_SAMPLE; mark("tachometer: the kernel refused edge detection on the line (%s): 1 ms sampling instead", strerror(errno)); tach_edges_set(0); }
				mark("tachometer: line %d of %s (%s) through the GPIO character device, mode %s", opt_line, path, ci.label, TM_NAME[tach_mode]);
			}
			else mark("tachometer: %s (%s) refused line %d: %s", path, ci.label, opt_line, strerror(errno));
		}
		close(fd);
	}
	if (tach_fd < 0 && !test_hw) {                    /* second way in: the sysfs GPIO class (GPIO 39 = base 32 + 7) */
		int e = open("/sys/class/gpio/export", O_WRONLY | O_CLOEXEC);
		if (e >= 0) { if (write(e, "39", 2) < 0) { } close(e); }
		tach_sysfs = open("/sys/class/gpio/gpio39/value", O_RDONLY | O_CLOEXEC);
		if (tach_sysfs >= 0) { tach_mode = TM_SYSFS; mark("tachometer: GPIO 39 through /sys/class/gpio (the character device did not give the line), 1 ms sampling"); }
	}
	if (tach_fd < 0 && tach_sysfs < 0) mark("tachometer: NOT readable (no GPIO line): the fan stays at HIGH or above, its rpm is unknown");
}
static int tach_level(void)                         /* 0, 1, or -1 */
{
	if (tach_fd >= 0) {
		struct gpio_v2_line_values v; v.mask = 1; v.bits = 0;
		if (ioctl(tach_fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &v)) return -1;
		return (int)(v.bits & 1);
	} else {
		char c;
		if (pread(tach_sysfs, &c, 1, 0) != 1) return -1;
		return c == '1';
	}
}
static int tach_sample(void)                        /* v7 fallback: the level every 1 ms for TACH_WINDOW, rising edges timed */
{
	static unsigned long long ts[TACH_EVENTS]; struct timespec next, now_ts; int last, v, k = 0; unsigned long i, n = (unsigned long)(TACH_WINDOW * 1e9 / TACH_SAMPLE_NS);
	if ((last = tach_level()) < 0) return -1;
	clock_gettime(CLOCK_MONOTONIC, &next);
	tach_samples = 0;
	for (i = 0; i < n; i++) {
		next.tv_nsec += TACH_SAMPLE_NS; if (next.tv_nsec >= 1000000000L) { next.tv_nsec -= 1000000000L; next.tv_sec++; }
		while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL) == EINTR) { }
		if ((v = tach_level()) < 0) return -1;
		tach_samples++;
		if (v && !last && k < TACH_EVENTS) { clock_gettime(CLOCK_MONOTONIC, &now_ts); ts[k++] = (unsigned long long)now_ts.tv_sec * 1000000000ULL + now_ts.tv_nsec; }
		last = v;
	}
	tach_edges_last = k;
	return rpm_from_ns(ts, k);
}
static void tach_open_window(void)                  /* v7: edge detection on for one window; the main poll() keeps serving the port */
{
	struct gpio_v2_line_event ev[16];
	if (tach_edges_set(1)) { mark("tachometer: edge detection refused now (%s): 1 ms sampling from here on", strerror(errno)); tach_mode = TM_SAMPLE; return; }
	while (read(tach_fd, ev, sizeof ev) > 0) { }      /* drain anything stale */
	tach_win_end = now() + TACH_WINDOW;
}
static int tach_close_window(void)                  /* v7: one bulk read of the window's events; edge detection off again */
{
	static struct gpio_v2_line_event ev[TACH_EVENTS]; static unsigned long long ts[TACH_EVENTS]; ssize_t r; int k, i, gap = 0;
	r = read(tach_fd, ev, sizeof ev);
	tach_edges_set(0); tach_win_end = 0;
	k = r > 0 ? (int)(r / sizeof ev[0]) : 0;
	for (i = 0; i < k; i++) {
		ts[i] = ev[i].timestamp_ns;
		if (i && ev[i].line_seqno != ev[i - 1].line_seqno + 1) gap = 1;
	}
	tach_edges_last = k;
	if (gap || k == TACH_EVENTS) { mark("tachometer: the window's event FIFO overflowed (%d events, a sequence gap): this reading is 'cannot read'", k); return -1; }
	if (k < 3) {                                      /* no edge: a stopped fan, or a line whose interrupt never fires. The level decides: */
		int s = tach_sample();
		if (s > 0) { mark("tachometer: no edge event in a window while 1 ms sampling sees the fan turn (%d rpm): edge interrupts do not work on this line, sampling from here on", s); tach_mode = TM_SAMPLE; }
		return s;
	}
	return rpm_from_ns(ts, k);
}
static int tach_rpm(void)                           /* test-root, sampling and sysfs modes: rpm now, or -1 = cannot be read */
{
	if (root) {
		char b[4096], p[300], *s, *e; static unsigned long long ts[TACH_EVENTS]; int k = 0;
		snprintf(p, sizeof p, "%s/tach_edges", root);           /* v7: kernel-style timestamps, through the edge path's arithmetic */
		if (slurp(p, b, sizeof b) > 0) {
			for (s = b; *s && k < TACH_EVENTS; s = e) { ts[k] = strtoull(s, &e, 10); if (e == s) break; k++; }
			tach_edges_last = k;
			return rpm_from_ns(ts, k);
		}
		snprintf(p, sizeof p, "%s/tach", root);
		if (slurp(p, b, sizeof b) <= 0) return -1;
		return atoi(b);
	}
	if (tach_mode == TM_NONE) return -1;
	return tach_sample();
}

/* ---------- the worker ---------- */
static volatile sig_atomic_t got_term;
static void on_term(int s) { (void)s; got_term = 1; }
static int hb_fd = -1; static double hb_last = -1e9;
static void heartbeat(void)                         /* v7: at most every T_HB_MIN (each one wakes the supervisor) */
{
	double t = now();
	if (hb_fd >= 0 && t - hb_last >= T_HB_MIN * K) { hb_last = t; if (write(hb_fd, "h", 1) < 0) { } }
}

static int level, state = 3, level_acked, rpm = -1, soc = -1, T = -1;
static double t_start, zero_since, last_fan_cmd;

static int write_atomic(const char *path, const char *data, size_t n, mode_t mode)     /* v7: every file this daemon writes whole: .new + rename */
{
	char tmp[320]; int fd, bad;
	snprintf(tmp, sizeof tmp, "%s.new", path);
	fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
	if (fd < 0) return -1;
	bad = write(fd, data, n) != (ssize_t)n;
	close(fd);
	if (bad || rename(tmp, path)) { unlink(tmp); return -1; }
	return 0;
}

/* ---------- v7: what the daemon reads besides the fan (all read-only: /proc, statvfs, getifaddrs, small files) ---------- */
static struct { int mode_tierA, lcd, standby; char if1[64], if2[64], md[12], fw[24]; time_t mtime; long mns; ino_t ino; off_t size; } conf = { 0, -1, -1, "br-lan eth0", "eth1", "md1", "", 0, 0, 0, 0 };
static char host[40], ip1s[20], ip2s[20], fwtext[24];
static struct in_addr ip1a, ip2a; static int has_ip1, has_ip2;
static struct mdstate { int present, active, ro, level, ndisks, nup, pct, wdst; char state[16], members[20], faulty[24], sync[12]; } md;
static struct { int has; unsigned long long total, avail; int used_pct; char mount[64]; } space;
#define MAX_ALERT 8
static int nalert; static char alert_id[MAX_ALERT][32], alert_text[MAX_ALERT][124];

static void conf_read(void)                         /* /etc/config/ex4panel (UCI): what the web UI set. Unknown options ignored */
{
	char b[2048], *s, *e; struct stat st;
	if (stat(p_conf, &st)) { conf.mode_tierA = 0; conf.lcd = conf.standby = -1; conf.mtime = 0; conf.ino = 0; return; }
	/* v8 (the panel review's nit 1): not the second alone: a web UI write inside the same second as the last read has a
	 * new inode (uci commits by rename), a new size or new nanoseconds */
	if (st.st_mtime == conf.mtime && st.st_mtim.tv_nsec == conf.mns && st.st_ino == conf.ino && st.st_size == conf.size) return;
	conf.mtime = st.st_mtime; conf.mns = st.st_mtim.tv_nsec; conf.ino = st.st_ino; conf.size = st.st_size;
	conf.mode_tierA = 0; conf.lcd = conf.standby = -1; conf.fw[0] = 0;
	snprintf(conf.if1, sizeof conf.if1, "br-lan eth0"); snprintf(conf.if2, sizeof conf.if2, "eth1"); snprintf(conf.md, sizeof conf.md, "md1");
	if (slurp(p_conf, b, sizeof b) <= 0) return;
	for (s = b; *s; s = e) {
		char key[32], val[80], *v; int n;
		e = strchr(s, '\n'); if (e) *e++ = 0; else e = s + strlen(s);
		while (*s == ' ' || *s == '\t') s++;
		if (sscanf(s, "option %31s %n", key, &n) != 1) continue;
		v = s + n; if (*v == '\'' || *v == '"') { char q = *v++; char *z = strchr(v, q); if (z) *z = 0; }
		ascii16(val, v, sizeof val - 1);
		if (!strcmp(key, "mode")) conf.mode_tierA = !strcmp(val, "tierA");
		else if (!strcmp(key, "lcd_sleep_mode") && (!strcmp(val, "0") || !strcmp(val, "1"))) conf.lcd = atoi(val);
		else if (!strcmp(key, "standby") && standby_code(atoi(val)) >= 0 && val[0] >= '0' && val[0] <= '9') conf.standby = atoi(val);
		else if (!strcmp(key, "ip1_ifaces")) snprintf(conf.if1, sizeof conf.if1, "%.63s", val);
		else if (!strcmp(key, "ip2_ifaces")) snprintf(conf.if2, sizeof conf.if2, "%.63s", val);
		else if (!strcmp(key, "md") && !strncmp(val, "md", 2) && strlen(val) < sizeof conf.md && strspn(val + 2, "0123456789") == strlen(val + 2)) snprintf(conf.md, sizeof conf.md, "%.11s", val);
		else if (!strcmp(key, "firmware")) ascii16(conf.fw, val, TEXT_MAX);
	}
}
static int in_list(const char *list, const char *name)    /* name is one of the space-separated words of list */
{
	size_t n = strlen(name); const char *p = list;
	while ((p = strstr(p, name))) { if ((p == list || p[-1] == ' ') && (p[n] == 0 || p[n] == ' ')) return 1; p += n; }
	return 0;
}
static void read_ips(void)
{
	has_ip1 = has_ip2 = 0;
	if (root) {
		char b[1024], p[300], *s, *e, nm[32], ad[32]; struct in_addr a;
		snprintf(p, sizeof p, "%s/ifaddrs", root);
		if (slurp(p, b, sizeof b) <= 0) return;
		for (s = b; *s; s = e) {
			e = strchr(s, '\n'); if (e) *e++ = 0; else e = s + strlen(s);
			if (sscanf(s, "%31s %31s", nm, ad) != 2 || inet_pton(AF_INET, ad, &a) != 1) continue;
			if (!has_ip1 && in_list(conf.if1, nm)) { ip1a = a; has_ip1 = 1; }
			else if (!has_ip2 && in_list(conf.if2, nm)) { ip2a = a; has_ip2 = 1; }
		}
	} else {
		struct ifaddrs *ifa, *i;
		if (getifaddrs(&ifa)) return;
		for (i = ifa; i; i = i->ifa_next) {
			if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || !i->ifa_name) continue;
			if (!has_ip1 && in_list(conf.if1, i->ifa_name)) { ip1a = ((struct sockaddr_in *)i->ifa_addr)->sin_addr; has_ip1 = 1; }
			else if (!has_ip2 && in_list(conf.if2, i->ifa_name)) { ip2a = ((struct sockaddr_in *)i->ifa_addr)->sin_addr; has_ip2 = 1; }
		}
		freeifaddrs(ifa);
	}
	ip1s[0] = ip2s[0] = 0;
	if (has_ip1) inet_ntop(AF_INET, &ip1a, ip1s, sizeof ip1s);
	if (has_ip2) inet_ntop(AF_INET, &ip2a, ip2s, sizeof ip2s);
}
static void read_md(void)                           /* /proc/mdstat only: never mdadm, never a block device */
{
	char b[8192], p[300], *s, *e, *l; int in = 0;
	memset(&md, 0, sizeof md); md.pct = -1;
	if (root) snprintf(p, sizeof p, "%s/mdstat", root); else snprintf(p, sizeof p, "/proc/mdstat");
	if (slurp(p, b, sizeof b) <= 0) return;
	for (s = b; *s; s = e) {
		e = strchr(s, '\n'); if (e) *e++ = 0; else e = s + strlen(s);
		if (!in) {
			char nm[16], *tok, *sv; int n = 0;
			if (sscanf(s, "%15s :", nm) != 1 || strcmp(nm, conf.md) || !strstr(s, " : ")) continue;
			in = 1; md.present = 1;
			for (tok = strtok_r(strstr(s, " : ") + 3, " ", &sv); tok; tok = strtok_r(NULL, " ", &sv), n++) {
				if (!strcmp(tok, "active")) md.active = 1;
				else if (strstr(tok, "read-only")) md.ro = 1;
				else if (!strncmp(tok, "raid", 4)) md.level = atoi(tok + 4);
				else if (strchr(tok, '[') && strstr(tok, "(F)")) {
					char d[12]; size_t k = strcspn(tok, "[");
					snprintf(d, sizeof d, "%.*s", (int)(k < 11 ? k : 11), tok);
					if (strlen(md.faulty) + strlen(d) + 2 < sizeof md.faulty) { if (md.faulty[0]) strcat(md.faulty, " "); strcat(md.faulty, d); }
				}
			}
			continue;
		}
		if (*s != ' ' && *s != '\t') break;           /* the next array or the end */
		if ((l = strstr(s, "] ["))) { int a, c; char u[20];
			char *q = l; while (q > s && *q != '[') q--;
			if (sscanf(q, "[%d/%d] [%19[U_]]", &a, &c, u) == 3) { md.ndisks = a; md.nup = c; snprintf(md.members, sizeof md.members, "%s", u); } }
		{ static const char *const SY[] = { "recovery", "resync", "reshape", "check", "repair" }; int k;
		  for (k = 0; k < 5; k++) if ((l = strstr(s, SY[k])) && (l = strchr(l, '='))) { md.pct = (int)atof(l + 1); snprintf(md.sync, sizeof md.sync, "%s", SY[k]); break; } }
	}
	if (!md.present) return;
	if (!md.active) { snprintf(md.state, sizeof md.state, "inactive"); md.wdst = 3; }
	else if (md.nup < md.ndisks && md.ndisks - md.nup > (md.level == 6 ? 2 : md.level == 1 ? md.ndisks - 1 : md.level >= 4 ? 1 : 0)) { snprintf(md.state, sizeof md.state, "failed"); md.wdst = 3; }
	else if (md.nup < md.ndisks && !strcmp(md.sync, "recovery")) { snprintf(md.state, sizeof md.state, "rebuilding"); md.wdst = 1; }
	else if (md.nup < md.ndisks) { snprintf(md.state, sizeof md.state, "degraded"); md.wdst = 2; }
	else if (md.sync[0] && strcmp(md.sync, "recovery")) { snprintf(md.state, sizeof md.state, "%s", !strcmp(md.sync, "check") ? "checking" : "resyncing"); md.wdst = 5; }
	else { snprintf(md.state, sizeof md.state, "clean"); md.wdst = 0; }
	if (md.pct > 100) md.pct = 100;
}
static void read_space(void)                        /* statvfs() of the md's mount, if something already mounted it */
{
	char b[8192], p[300], *s, *e, dev[96], mnt[96], want[24];
	space.has = 0; space.mount[0] = 0;
	if (root) snprintf(p, sizeof p, "%s/mounts", root); else snprintf(p, sizeof p, "/proc/mounts");
	snprintf(want, sizeof want, "/dev/%s", conf.md);
	if (slurp(p, b, sizeof b) <= 0) return;
	for (s = b; *s; s = e) {
		e = strchr(s, '\n'); if (e) *e++ = 0; else e = s + strlen(s);
		if (sscanf(s, "%95s %95s", dev, mnt) == 2 && !strcmp(dev, want)) { snprintf(space.mount, sizeof space.mount, "%.63s", mnt); break; }
	}
	if (!space.mount[0]) return;
	if (root) {
		unsigned long long t, a; snprintf(p, sizeof p, "%s/statvfs", root);
		if (slurp(p, b, sizeof b) <= 0 || sscanf(b, "%llu %llu", &t, &a) != 2 || !t || a > t) return;
		space.total = t; space.avail = a; space.used_pct = (int)((t - a) * 100.0 / t + 0.5);
	} else {
		struct statvfs v;
		if (statvfs(space.mount, &v) || !v.f_blocks) return;
		space.total = (unsigned long long)v.f_blocks * v.f_frsize; space.avail = (unsigned long long)v.f_bavail * v.f_frsize;
		space.used_pct = (int)((double)(v.f_blocks - v.f_bfree) * 100.0 / v.f_blocks + 0.5);
	}
	if (space.used_pct > 100) space.used_pct = 100;
	space.has = 1;
}
static void read_alerts(void)                       /* one file per alert in alerts.d/, first line = the text. Any daemon may write one */
{
	DIR *d = opendir(p_alerts); struct dirent *de; int i, j;
	nalert = 0;
	if (!d) return;
	while ((de = readdir(d)) && nalert < MAX_ALERT) {
		char f[400], b[200], *nl; struct stat st; const char *n = de->d_name;
		if (n[0] == '.' || strlen(n) > 31 || strspn(n, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != strlen(n)) continue;
		snprintf(f, sizeof f, "%s/%.31s", p_alerts, n);
		if (lstat(f, &st) || !S_ISREG(st.st_mode) || st.st_size > 4096) continue;
		if (slurp(f, b, sizeof b) < 0) continue;
		if ((nl = strchr(b, '\n'))) *nl = 0;
		snprintf(alert_id[nalert], sizeof alert_id[0], "%.31s", n);
		ascii16(alert_text[nalert], b, sizeof alert_text[0] - 1);
		if (!alert_text[nalert][0]) snprintf(alert_text[nalert], sizeof alert_text[0], "%.31s", n);
		nalert++;
	}
	closedir(d);
	for (i = 0; i < nalert; i++) for (j = i + 1; j < nalert; j++) if (strcmp(alert_id[i], alert_id[j]) > 0) {
		char t1[32], t2[124]; memcpy(t1, alert_id[i], 32); memcpy(t2, alert_text[i], 124);
		memcpy(alert_id[i], alert_id[j], 32); memcpy(alert_text[i], alert_text[j], 124); memcpy(alert_id[j], t1, 32); memcpy(alert_text[j], t2, 124);
	}
}
static long long drv_attr(const struct drv *d, int id) { int j; for (j = 0; j < N_SMART; j++) if (SMART_ID[j] == id) return d->attr[j]; return -1; }
static const char *drv_verdict(const struct drv *d)
{
	if (drv_attr(d, 5) > 0 || drv_attr(d, 197) > 0 || drv_attr(d, 198) > 0 || drv_attr(d, 187) > 0) return "watch";
	if (!d->smart_ok) return "unknown";
	return "good";
}
static void collect(void)
{
	char b[200], p[300];
	conf_read();
	if (root) { snprintf(p, sizeof p, "%s/hostname", root); if (slurp(p, b, sizeof b) <= 0) b[0] = 0; ascii16(host, b, sizeof host - 1); }
	else { struct utsname u; if (uname(&u) == 0) ascii16(host, u.nodename, sizeof host - 1); }
	read_ips(); read_md(); read_space(); read_alerts();
	if (conf.fw[0]) snprintf(fwtext, sizeof fwtext, "%s", conf.fw);
	else {
		char r[1024], *v, *z; if (root) snprintf(p, sizeof p, "%s/release", root); else snprintf(p, sizeof p, "/etc/openwrt_release");
		fwtext[0] = 0;
		if (slurp(p, r, sizeof r) > 0 && (v = strstr(r, "DISTRIB_RELEASE="))) {
			v += 16; if (*v == '\'' || *v == '"') v++;
			z = v + strcspn(v, "'\"\n"); *z = 0;
			snprintf(b, sizeof b, "OpenWrt %s", v); ascii16(fwtext, b, TEXT_MAX);
		}
	}
}

/* ---------- v7: the LCD, Tier A: one slot per field the micro draws ---------- */
enum { S_NAME, S_IP1, S_IP2, S_FW, S_HEALTH, S_FREE, S_USED, S_VOL, S_FAN, S_TEMP, S_USB, S_LCD, S_STANDBY, S_N };
static const char *const SLOT_NAME[S_N] = { "name", "ip1", "ip2", "fw", "health", "free", "used", "vol", "fan", "temp", "usb", "lcd", "standby" };
static struct slot { struct frame want, sent; char text[40], sent_text[40]; int due, acked; } sl[S_N];
static unsigned lcd_frames, lcd_acked, lcd_unacked, lcd_logged; static double next_lcd, next_refresh; static int panel_was_on;
static int panel_on(void) { return opt_panel || conf.mode_tierA; }

static void want_text(int s, int k, const char *t) { if (build_text(&sl[s].want, k, t) == 0) snprintf(sl[s].text, sizeof sl[s].text, "%s", t); }
static void panel_compute(void)                     /* our readings -> the frame each slot should carry (n = 0: nothing to send) */
{
	int i, tdrv = 0, s; char t[48];
	for (s = 0; s < S_N; s++) { sl[s].want.n = 0; sl[s].text[0] = 0; }
	if (host[0]) want_text(S_NAME, PK_NAME, host);
	if (has_ip1) { build_ip(&sl[S_IP1].want, PK_IP1, ip1a); snprintf(sl[S_IP1].text, sizeof sl[0].text, "%s", ip1s); }
	else { build_fixed(&sl[S_IP1].want, PK_IP1OFF); snprintf(sl[S_IP1].text, sizeof sl[0].text, "none"); }
	if (has_ip2) { build_ip(&sl[S_IP2].want, PK_IP2, ip2a); snprintf(sl[S_IP2].text, sizeof sl[0].text, "%s", ip2s); }
	else { build_fixed(&sl[S_IP2].want, PK_IP2OFF); snprintf(sl[S_IP2].text, sizeof sl[0].text, "none"); }
	if (fwtext[0]) want_text(S_FW, PK_FW, fwtext);
	/* drive health, worst first: no drives / an md member marked faulty / a drive that wants watching / an alert / good */
	{
		char w[TEXT_MAX + 8] = ""; int nw = 0;
		for (i = 0; i < ndrv; i++) if (!strcmp(drv_verdict(&drv[i]), "watch") && strlen(w) + strlen(drv[i].name) + 1 <= TEXT_MAX - 6) { strcat(w, " "); strcat(w, drv[i].name); nw++; }
		if (!ndrv) snprintf(t, sizeof t, "No Drives");
		else if (md.faulty[0]) snprintf(t, sizeof t, "Failed %s", md.faulty);
		else if (nw) snprintf(t, sizeof t, "Watch%s", w);
		else if (nalert) snprintf(t, sizeof t, "%.16s", alert_text[0]);
		else snprintf(t, sizeof t, "Good");
		want_text(S_HEALTH, PK_HEALTH, t);
	}
	if (space.has) {
		double a = (double)space.avail;
		if (a >= 1099511627776.0) snprintf(t, sizeof t, "%.3f TB", a / 1099511627776.0);
		else if (a >= 1073741824.0) snprintf(t, sizeof t, "%.3f GB", a / 1073741824.0);
		else snprintf(t, sizeof t, "%.3f MB", a / 1048576.0);
		want_text(S_FREE, PK_FREE, t);
		if (build_used(&sl[S_USED].want, 1, space.used_pct) == 0) snprintf(sl[S_USED].text, sizeof sl[0].text, "%d%%", space.used_pct);
	}
	if (md.present) { int pct = (md.wdst == 1 || md.wdst == 5) && md.pct >= 0 ? md.pct : 0;
		if (build_vol(&sl[S_VOL].want, 1, md.wdst, pct, 1) == 0) snprintf(sl[S_VOL].text, sizeof sl[0].text, "%s %d%%", md.state, pct); }
	else if (build_fixed(&sl[S_VOL].want, PK_VOLCLEAN) == 0) snprintf(sl[S_VOL].text, sizeof sl[0].text, "no volume");
	if (rpm >= 0) { snprintf(t, sizeof t, "%drpm", rpm); want_text(S_FAN, PK_FAN, t); }
	for (i = 0; i < ndrv; i++) if (drv[i].temp > tdrv) tdrv = drv[i].temp;
	if (tdrv > 0 && therm[2] >= 0 && build_temp(&sl[S_TEMP].want, tdrv, therm[2]) == 0) snprintf(sl[S_TEMP].text, sizeof sl[0].text, "%d %d", tdrv, therm[2]);
	if (build_arg(&sl[S_USB].want, PK_USB, usb_disks > 0) == 0) snprintf(sl[S_USB].text, sizeof sl[0].text, "%d", usb_disks > 0);
	if (conf.lcd >= 0 && build_arg(&sl[S_LCD].want, PK_LCD, conf.lcd) == 0) snprintf(sl[S_LCD].text, sizeof sl[0].text, "%d", conf.lcd);
	if (conf.standby >= 0 && build_arg(&sl[S_STANDBY].want, PK_STANDBY, standby_code(conf.standby)) == 0) snprintf(sl[S_STANDBY].text, sizeof sl[0].text, "%d", conf.standby);
}
static void hexs(char *o, const struct frame *f) { int i; for (i = 0; i < f->n; i++) sprintf(o + 2 * i, "%02x", f->b[i]); o[2 * f->n] = 0; }
static int slot_send(int s, const char *why)        /* one slot's frame, LCD_TRIES tries. 1 = ACKed */
{
	char hx[2 * FRAME_MAX + 1]; int tries = frame_cmd(&sl[s].want, LCD_TRIES);
	lcd_frames++;
	if (tries > 0) lcd_acked++; else lcd_unacked++;
	sl[s].sent = sl[s].want; memcpy(sl[s].sent_text, sl[s].text, sizeof sl[s].sent_text); sl[s].acked = tries > 0; sl[s].due = 0;
	hexs(hx, &sl[s].want);
	if (lcd_logged++ < 40 || tries <= 0) {
		if (tries <= 0 && lcd_unacked > 20) return 0;
		mark("lcd %s '%s' ack=%d tries=%d frame %s (%s)%s", SLOT_NAME[s], sl[s].text, tries > 0, tries > 0 ? tries : LCD_TRIES, hx, why,
		     tries == 0 ? ": not ACKed, dropped until the next refresh (never a fail-safe)" : "");
	}
	return tries > 0;
}
static int panel_pending(void)
{
	int s;
	if (!panel_on()) return 0;
	for (s = 0; s < S_N; s++) if (sl[s].want.n && (sl[s].due || sl[s].want.n != sl[s].sent.n || memcmp(sl[s].want.b, sl[s].sent.b, sl[s].want.n))) return 1;
	return 0;
}
static void panel_tick(void)                        /* at most ONE LCD frame per call, T_LCD_GAP apart, never while a fan command is unACKed */
{
	int s; double t = now();
	if (panel_on() && !panel_was_on) { mark("panel: LCD Tier A ON (%s): WD's field frames from our readings", opt_panel ? "--panel" : "/etc/config/ex4panel mode tierA"); for (s = 0; s < S_N; s++) sl[s].due = 1; next_refresh = t + T_LCD_REFRESH * K; }
	if (!panel_on() && panel_was_on) mark("panel: LCD Tier A OFF (the glass keeps what it was last given)");
	panel_was_on = panel_on();
	if (!panel_was_on || !level_acked || last_rx <= 0 || t < next_lcd) return;
	if (t >= next_refresh) { for (s = 0; s < S_N; s++) sl[s].due = 1; next_refresh = t + T_LCD_REFRESH * K; }
	for (s = 0; s < S_N; s++) if (sl[s].want.n && (sl[s].due || sl[s].want.n != sl[s].sent.n || memcmp(sl[s].want.b, sl[s].sent.b, sl[s].want.n))) {
		slot_send(s, sl[s].due ? "refresh" : "changed"); heartbeat();
		next_lcd = now() + T_LCD_GAP * K;
		return;
	}
}

/* ---------- v7: requests from `ex4fan ctl` (root only: the folder is 0700, every file must be ours and not group/world-writable) ---------- */
static void ctl_poweroff(void)
{
	struct frame f; int a, b;
	if (!opt_poweroff) {
		mark("ctl poweroff: REFUSED: this daemon was not started with --allow-poweroff (the trial never passes it). Sending WD's DeviceShutdown frame on the real box is the owner's word. Nothing sent.");
		return;
	}
	build_fixed(&f, PK_SHUTMSG); a = frame_cmd(&f, TRIES);
	poweroff_armed = 1; if (build_fixed(&f, PK_POWEROFF) == 0) b = frame_cmd(&f, TRIES); else b = -1; poweroff_armed = 0;
	mark("ctl poweroff: DeviceShutdownMsg ack=%d, DeviceShutdown 1 (fa0303010101fb) ack=%d. What the micro does next (cut power after its delay?) is NOT proven; the caller still runs its own sync / unmount / poweroff", a > 0, b > 0);
}
static void ctl_send_test(void)                     /* v8: ONE LCD frame, tried once, once per boot; the ACK is the measurement */
{
	char hx[2 * FRAME_MAX + 1], res[320]; int t; struct stat st;
	if (stat(p_sendtest, &st) == 0) { mark("ctl send-test: REFUSED: the one test frame of this boot was already asked for (%s exists): nothing sent", p_sendtest); return; }
	collect(); panel_compute();
	if (!sl[S_NAME].want.n) snprintf(res, sizeof res, "send-test: nothing sent: no host name to put in the frame");
	else if (last_rx <= 0) snprintf(res, sizeof res, "send-test: nothing sent: the micro has not answered anything yet");
	else {
		t = frame_cmd(&sl[S_NAME].want, 1);
		lcd_frames++; if (t > 0) lcd_acked++; else lcd_unacked++;
		hexs(hx, &sl[S_NAME].want);
		snprintf(res, sizeof res, "send-test: ONE LCD frame (WD's SysName, text '%s', %d bytes, one try): ack=%d %s frame %s", sl[S_NAME].text, sl[S_NAME].want.n, t > 0,
		         t > 0 ? "(the micro ACKed it)" : t < 0 ? "(REFUSED by frame_check: not sent)" : "(no ACK within 300 ms)", hx);
	}
	mark("ctl %s", res);
	strcat(res, "\n");
	write_atomic(p_sendtest, res, strlen(res), 0644);
}
static void ctl_do(char *line)
{
	char w1[16] = "", w2[16] = ""; int s, n;
	n = sscanf(line, "%15s %15s", w1, w2);
	if (n < 1) return;
	if (!strcmp(w1, "refresh")) { for (s = 0; s < S_N; s++) sl[s].due = 1; mark("ctl refresh: every field again%s", panel_on() ? "" : " (the panel is OFF: nothing is sent)"); return; }
	if (!strcmp(w1, "send") && n == 2) {                /* the hand bench step: ONE field, once, even with the panel off */
		for (s = 0; s < S_N; s++) if (!strcmp(w2, SLOT_NAME[s])) break;
		if (s == S_N) { mark("ctl send %s: no such field (name ip1 ip2 fw health free used vol fan temp usb lcd standby)", w2); return; }
		collect(); panel_compute();
		if (!sl[s].want.n) { mark("ctl send %s: nothing to send (no reading for it)", w2); return; }
		if (last_rx <= 0) { mark("ctl send %s: the micro has not answered yet: not sent", w2); return; }
		slot_send(s, "ctl send"); return;
	}
	if (!strcmp(w1, "notice") && n == 2 && (!strcmp(w2, "shutdown") || !strcmp(w2, "reboot"))) {
		struct frame f; int k = !strcmp(w2, "shutdown") ? PK_SHUTMSG : PK_RSTMSG, a;
		build_fixed(&f, k); a = frame_cmd(&f, TRIES);
		mark("ctl notice %s: %s ack=%d", w2, PK[k].wd, a > 0); return;
	}
	if (!strcmp(w1, "poweroff") && n == 1) { ctl_poweroff(); return; }
	if (!strcmp(w1, "send-test") && n == 1) { ctl_send_test(); return; }
	mark("ctl: unknown request '%.40s' (ignored)", line);
}
static void ctl_scan(void)
{
	DIR *d = opendir(p_ctl); struct dirent *de; int done = 0;
	if (!d) return;
	while ((de = readdir(d)) && done < 8) {
		char f[400], b[256]; struct stat st; size_t L = strlen(de->d_name);
		if (de->d_name[0] == '.' || (L > 4 && !strcmp(de->d_name + L - 4, ".new"))) continue;
		snprintf(f, sizeof f, "%.300s/%.80s", p_ctl, de->d_name);
		if (lstat(f, &st) || !S_ISREG(st.st_mode)) continue;
		if (st.st_uid != geteuid() || (st.st_mode & 022) || st.st_size > 200) { mark("ctl: %s is not ours, is group/world-writable or too big: ignored and removed", de->d_name); unlink(f); continue; }
		if (slurp(f, b, sizeof b) < 0) continue;
		unlink(f); done++;
		{ char *nl = strchr(b, '\n'); if (nl) *nl = 0; }
		ctl_do(b);
	}
	closedir(d);
}

/* ---------- the state: one line (v5, unchanged) + v7's JSON for the web UI ---------- */
static char jb[12288]; static size_t jn;
static void J(const char *fmt, ...) { va_list ap; if (jn >= sizeof jb) return; va_start(ap, fmt); jn += vsnprintf(jb + jn, sizeof jb - jn, fmt, ap); va_end(ap); if (jn > sizeof jb) jn = sizeof jb; }
static void JS(const char *s)                       /* a JSON string; everything we put in is printable ASCII already */
{
	J("\"");
	for (; *s; s++) { unsigned char c = *s; if (c == '"' || c == '\\') J("\\%c", c); else if (c < 0x20 || c > 0x7e) J("\\u%04x", c); else J("%c", c); }
	J("\"");
}
static void json_write(void)
{
	int i, j, s;
	jn = 0;
	J("{\"v\":1,\"up\":%d,\"wall\":%.0f,", (int)(now() - t_start), wall());
	J("\"fan\":{\"level\":%d,\"name\":\"%s\",\"acked\":%d,\"rpm\":%d,\"tach\":\"%s\",\"edges\":%u},", level, LEVEL_NAME[level], level_acked, rpm, root ? "test" : TM_NAME[tach_mode], tach_edges_last);
	J("\"temps\":{\"main\":%d,\"sata\":%d,\"soc\":%d,\"T\":%d},\"drives\":[", therm[2], therm[1], soc, T);
	for (i = 0; i < ndrv; i++) {
		J("%s{\"dev\":", i ? "," : ""); JS(drv[i].name);
		J(",\"temp\":%d,\"power\":\"%s\",\"verdict\":\"%s\",\"smart\":{", drv[i].temp, PW_NAME[drv[i].power], drv_verdict(&drv[i]));
		for (j = 0; j < N_SMART; j++) J("%s\"%d\":%lld", j ? "," : "", SMART_ID[j], drv[i].attr[j]);
		J("}}");
	}
	J("],\"usb_disks\":%d,\"md\":{\"name\":", usb_disks); JS(conf.md);
	J(",\"present\":%s,\"level\":%d,\"state\":", md.present ? "true" : "false", md.level); JS(md.state);
	J(",\"members\":"); JS(md.members); J(",\"disks\":%d,\"up\":%d,\"sync\":", md.ndisks, md.nup); JS(md.sync);
	J(",\"pct\":%d,\"readonly\":%s,\"faulty\":", md.pct, md.ro ? "true" : "false"); JS(md.faulty);
	J("},\"space\":{\"mounted\":%s,\"mount\":", space.has ? "true" : "false"); JS(space.mount);
	J(",\"total\":%llu,\"avail\":%llu,\"used_pct\":%d},", space.total, space.avail, space.used_pct);
	J("\"micro\":{\"answers\":%s,\"frames_in\":%u,\"acks\":%u,\"cmds\":%u,\"cmds_acked\":%u,\"other\":%u,\"ready\":\"%s\",\"clock\":\"%s\"},",
	  last_rx > 0 ? "true" : "false", n_rx, n_ack, n_cmd, n_cmd_acked, n_other, ready_state > 0 ? "acked" : ready_state < 0 ? "not-acked" : "not-sent", clock_state == 2 ? "set" : clock_state == 1 ? "read" : "none");
	J("\"panel\":{\"mode\":\"%s\",\"poweroff_allowed\":%s,\"lcd_frames\":%u,\"lcd_acked\":%u,\"lcd_unacked\":%u,\"sent\":{", panel_on() ? "tierA" : "off", opt_poweroff ? "true" : "false", lcd_frames, lcd_acked, lcd_unacked);
	for (s = 0, j = 0; s < S_N; s++) if (sl[s].sent.n) { J("%s\"%s\":", j++ ? "," : "", SLOT_NAME[s]); JS(sl[s].sent_text); }
	J("},\"host\":"); JS(host); J(",\"ip1\":"); JS(ip1s); J(",\"ip2\":"); JS(ip2s); J(",\"fw\":"); JS(fwtext);
	J("},\"alerts\":[");
	for (i = 0; i < nalert; i++) { J("%s{\"id\":", i ? "," : ""); JS(alert_id[i]); J(",\"text\":"); JS(alert_text[i]); J("}"); }
	J("],\"events\":[");
	for (i = 0, j = (int)(evn > 8 ? evn - 8 : 0); j < (int)evn; j++, i++) { J("%s{\"up\":%.1f,\"name\":\"%s\"}", i ? "," : "", evring[j % 8].t - t_start, EVENT[evring[j % 8].i].name); }
	J("],\"events_total\":%u}\n", n_event);
	if (jn < sizeof jb) write_atomic(p_json, jb, jn, 0644);
}
static void status(int to_kmsg)
{
	char d[160], line[400]; int i, n = 0;
	d[0] = 0;
	for (i = 0; i < ndrv; i++) {
		if (drv[i].temp >= 0) n += snprintf(d + n, sizeof d - n, "%s%s:%d", i ? "," : "", drv[i].name, drv[i].temp);
		else n += snprintf(d + n, sizeof d - n, "%s%s:?", i ? "," : "", drv[i].name);
	}
	snprintf(line, sizeof line, "status up=%d level=%d(%s) acked=%d rpm=%d tach=%s drives=%s main=%d sata=%d soc=%d T=%d micro=%s frames_in=%u acks=%u cmds=%u/%u other=%u ready=%s events=%u clock=%s",
		(int)(now() - t_start), level, LEVEL_NAME[level], level_acked, rpm, rpm < 0 ? "none" : "ok", ndrv ? d : "none",
		therm[2], therm[1], soc, T, last_rx > 0 ? "answers" : "silent", n_rx, n_ack, n_cmd_acked, n_cmd, n_other,
		ready_state > 0 ? "acked" : ready_state < 0 ? "not-acked" : "not-sent", n_event, clock_state == 2 ? "set" : clock_state == 1 ? "read" : "none");
	if (to_kmsg) mark("%s", line);
	strcat(line, "\n");
	write_atomic(p_status, line, strlen(line), 0644);
	json_write();
}
static void set_level(int lv, const char *why)
{
	int tries;
	if (lv < 1) lv = 1;
	if (lv > 4) lv = 4;
	tries = mcu_cmd(TX_FAN_LOW + lv - 1);
	level = lv; level_acked = tries > 0; last_fan_cmd = now();
	mark("cmd FAN=%d(%s) ack=%d tries=%d why=%s", lv, LEVEL_NAME[lv], tries > 0, tries ? tries : TRIES, why);
}
static void failsafe(const char *fmt, ...)
{
	char why[200], line[300]; va_list ap;
	va_start(ap, fmt); vsnprintf(why, sizeof why, fmt, ap); va_end(ap);
	snprintf(line, sizeof line, "FAILSAFE reason=%s -> fan MAX, then reboot (back to the stock system, which runs its own fan)", why);
	mark("%s", line);
	if (tty >= 0) set_level(4, "fail-safe");
	status(1);
	note_disklog(line);
	nap(T_FLUSH * K);                                 /* ex4log writes a snapshot with the note in it */
	_exit(99);                                        /* the supervisor does the reboot */
}

static void apply(void)                             /* the curve's state plus the floors -> the level on the wire */
{
	int want = state, i, present = ndrv, valid = 0; const char *why = "curve";
	for (i = 0; i < ndrv; i++) if (drv[i].temp >= 0) valid++;
	if (now() - t_start < T_HOLD_HIGH * K && want < 3) { want = 3; why = "first minute: HIGH"; }
	if (present && valid < present && want < 3) { want = 3; why = "a drive's temperature cannot be read: HIGH"; }
	if (rpm < 0 && want < 3) { want = 3; why = "no tachometer: HIGH"; }
	if (!valid && therm[2] < 0 && want < 4) { want = 4; why = "no temperature at all: MAX"; }
	if (soc >= SOC_MAX && want < 4) { want = 4; why = "SoC hot: MAX"; }
	if (zero_since > 0 && want < 4) { want = 4; why = "rpm reads 0: MAX"; }
	if (want != level) { char w[120]; snprintf(w, sizeof w, "%s (T=%d)", why, T); set_level(want, w); status(1); }
	else if (!level_acked && now() - last_fan_cmd >= T_RETRY * K) set_level(want, "the last fan command was not ACKed: again");
}
static void temps(void)
{
	int i, hot = -1, tdrv = 0, b, n;
	drives_read(); heartbeat();
	for (i = 0; i < ndrv; i++) {
		if (drv[i].temp >= DRIVE_REBOOT && !root) { struct drv tmp = drv[i]; int again = smart_temp(drv[i].name, &tmp); if (again >= 0) drv[i] = tmp, drv[i].temp = again; }
		if (drv[i].temp >= DRIVE_REBOOT) hot = i;
		if (drv[i].temp > tdrv) tdrv = drv[i].temp;
	}
	soc = soc_read();
	mcu_query(TX_THERM_MAIN, 2); heartbeat();
	mcu_query(TX_THERM_SATA, 1); heartbeat();
	if (therm_at[2] > 0 && now() - therm_at[2] > 3 * T_TEMP * K) therm[2] = -1;        /* stale: three readings missed */
	if (therm_at[1] > 0 && now() - therm_at[1] > 3 * T_TEMP * K) therm[1] = -1;
	b = therm[2] < 0 ? 0 : therm[2] > 20 ? therm[2] - 10 : therm[2];                    /* WD: board - 10 */
	T = tdrv > b ? tdrv : b;
	if (hot >= 0) { status(1); failsafe("drive-hot %s=%dC (limit %d, read twice)", drv[hot].name, drv[hot].temp, DRIVE_REBOOT); }
	n = curve_next(state, T);
	if (n != state) { mark("curve %s -> %s at T=%d", LEVEL_NAME[state], LEVEL_NAME[n], T); state = n; }
	apply();
}
static void tach(int r)                             /* v7: the reading arrives from the window, the sampler or the test file */
{
	rpm = r;
	if (rpm == 0) {
		if (zero_since <= 0) { zero_since = now(); mark("rpm reads 0 with FAN=%d commanded: fan to MAX; a reboot follows if it still reads 0 in %d s", level, (int)(T_RPM_ZERO * K + 0.5)); }
		else if (now() - zero_since >= T_RPM_ZERO * K) { status(1); failsafe("rpm-zero for %d s while FAN=%d(%s) was commanded", (int)(now() - zero_since + 0.5), level, LEVEL_NAME[level]); }
	} else {
		if (zero_since > 0 && rpm > 0) mark("rpm is back: %d", rpm);
		zero_since = 0;
	}
	apply();
}

static double dmin(double a, double b) { return a < b ? a : b; }
static int worker(int hb)
{
	double next_temp, next_tach, next_status, t, dl; struct sigaction sa; int first_temps = 0, ino = -1, to, i, r;
	struct pollfd pf[2]; unsigned char b[256];
	hb_fd = hb;
	memset(&sa, 0, sizeof sa); sa.sa_handler = on_term; sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
	t_start = now();
	mark("start pid=%d%s%s%s%s", (int)getpid(), root ? " TEST-ROOT" : "", test_hw ? " TEST-HW" : "", opt_panel ? " PANEL" : "", opt_poweroff ? " ALLOW-POWEROFF" : "");
	if (tty_open()) failsafe("port-open-failed (%s)", strerror(errno));
	set_level(3, "start: first action");
	heartbeat();
	tach_init();
	/* v7: the panel's run folder: ctl/ (requests, root only) and alerts.d/ (one file per alert, any daemon) */
	if (root) { char p[320]; snprintf(p, sizeof p, "%s/run", root); mkdir(p, 0755); }
	mkdir(p_run, 0755); mkdir(p_ctl, 0700); chmod(p_ctl, 0700); mkdir(p_alerts, 0755);
	if ((ino = inotify_init1(IN_NONBLOCK | IN_CLOEXEC)) >= 0) {
		if (inotify_add_watch(ino, p_ctl, IN_CLOSE_WRITE | IN_MOVED_TO) < 0 || inotify_add_watch(ino, p_alerts, IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_DELETE) < 0) { close(ino); ino = -1; }
	}
	if (ino < 0) mark("panel: no inotify on %s: requests and alerts are looked at every %d s", p_run, (int)(T_TACH * K + 0.5));
	ctl_scan();                                       /* a request older than this daemon is acted on now */
	collect();
	next_temp = now(); next_tach = now() + 5 * K; next_status = now() + T_STATUS * K;
	for (;;) {
		heartbeat();
		if (got_term) { set_level(3, "stopping: the fan is left at HIGH"); status(1); return 0; }
		/* v7: sleep in ONE poll() until the next thing that is due (no tick) */
		t = now();
		dl = dmin(next_temp, tach_win_end > 0 ? tach_win_end : next_tach);
		dl = dmin(dl, next_status);
		dl = dmin(dl, t + T_POLL_MAX * K);
		if (last_rx <= 0) dl = dmin(dl, t_start + T_MCU_START * K);
		else dl = dmin(dl, last_rx + T_MCU_SILENT * K);
		if (first_temps && ready_tries == 0) dl = dmin(dl, t_start + T_READY * K);
		if (ready_tries == 1 && ready_state < 0) dl = dmin(dl, ready_at + T_READY_AGAIN * K);
		if (clock_tries == 1 && clock_at <= 0) dl = dmin(dl, clock_asked + T_CLOCK_AGAIN * K);
		if (panel_pending()) dl = dmin(dl, next_lcd);
		to = (int)((dl - t) * 1000.0 + 0.999);
		if (to < 0) to = 0;
		pf[0].fd = tty; pf[0].events = POLLIN; pf[0].revents = 0;
		pf[1].fd = ino; pf[1].events = POLLIN; pf[1].revents = 0;
		r = poll(pf, ino >= 0 ? 2 : 1, to);
		if (r > 0 && (pf[0].revents & POLLIN)) { ssize_t k; while ((k = read(tty, b, sizeof b)) > 0) for (i = 0; i < k; i++) byte_in(b[i]); }
		else if (r > 0 && (pf[0].revents & (POLLERR | POLLHUP | POLLNVAL))) nap(0.05);
		if (r > 0 && ino >= 0 && (pf[1].revents & POLLIN)) {
			char ev[1024]; while (read(ino, ev, sizeof ev) > 0) { }
			ctl_scan(); read_alerts(); panel_compute();
		}
		if (got_term) continue;
		t = now();
		if (t >= next_temp) { temps(); next_temp = now() + T_TEMP * K; first_temps = 1; }
		t = now();
		if (tach_win_end > 0 && t >= tach_win_end) {      /* an edge window ends: its reading, then everything that rides on the 10 s beat */
			tach(tach_close_window());
			goto beat;
		}
		if (tach_win_end <= 0 && t >= next_tach) {
			if (!root && tach_mode == TM_EDGE) { tach_open_window(); if (tach_mode == TM_EDGE) continue; }
			tach(tach_rpm());
		beat:
			next_tach = now() + (zero_since > 0 ? T_TACH / 2 : T_TACH) * K;
			if (ino < 0) ctl_scan();
			collect(); panel_compute();
			if (now() >= next_status) { status(1); next_status = now() + T_STATUS * K; } else status(0);
		}
		t = now();
		if (last_rx <= 0 && t - t_start >= T_MCU_START * K) failsafe("micro-never-answered: no valid frame in %d s (%u frames sent)", (int)(t - t_start), n_sent);
		if (last_rx > 0 && t - last_rx >= T_MCU_SILENT * K) failsafe("micro-went-silent: no valid frame for %d s", (int)(t - last_rx));
		/* v5: once the first full reading is in and the micro answers: read its clock, then tell it the system is up.
		 * Neither is sent to a micro that has never answered (the first ten frames stay FAN HIGH), neither can reboot. */
		if (first_temps && last_rx > 0 && clock_at <= 0 && (clock_tries == 0 || (clock_tries == 1 && t - clock_asked >= T_CLOCK_AGAIN * K))) { clock_ask(); heartbeat(); t = now(); }
		if (first_temps && last_rx > 0 && level_acked && zero_since <= 0 && t - t_start >= T_READY * K
		    && (ready_tries == 0 || (ready_tries == 1 && ready_state < 0 && t - ready_at >= T_READY_AGAIN * K))) { ready_send(); heartbeat(); status(1); t = now(); }
		if (t >= next_status) { status(1); next_status = t + T_STATUS * K; }
		panel_tick();
	}
}

/* ---------- the supervisor: restarts a worker that died or hangs; does the reboot ---------- */
/* v8 (RWBENCH, docs/RWBENCH.md): while /tmp/ex4-rw-active exists the read-write bench may hold md1 read-write.
 * Its clean stop runs first, for at most 120 s (the fan is already at MAX). This is the ONE reboot path that goes
 * on even when the stop did not say SAFE: a drive at 55 C or a fan that does not turn outranks a resync (md's own
 * reboot notifier still marks the array clean after sync(); the ext4 journal replays on the next mount). */
static void rw_stop_for_reboot(void)
{
	pid_t p; int st = -1, i;
	if (access("/tmp/ex4-rw-active", F_OK) != 0) return;
	kmsg("fail-safe: the rw bench is up (/tmp/ex4-rw-active): its clean stop first (at most 120 s)");
	p = fork();
	if (p == 0) { execl("/usr/sbin/ex4-rwbench", "ex4-rwbench", "stop", "--for-reboot", (char *)NULL); _exit(127); }
	if (p < 0) { kmsg("fail-safe: fork for the rw clean stop failed: rebooting anyway"); return; }
	for (i = 0; i < 120; i++) { if (waitpid(p, &st, WNOHANG) == p) break; nap(1); }
	if (i == 120) { kill(p, SIGKILL); waitpid(p, &st, 0); kmsg("fail-safe: the rw clean stop did not finish in 120 s: rebooting anyway"); return; }
	kmsg(WIFEXITED(st) && (WEXITSTATUS(st) == 0 || WEXITSTATUS(st) == 3) ? "fail-safe: the rw clean stop said SAFE" : "fail-safe: the rw clean stop did NOT say SAFE: rebooting anyway (thermal / fan fail-safe)");
}
static void do_reboot(const char *why)
{
	char b[300];
	snprintf(b, sizeof b, "rebooting now: %s", why);
	kmsg(b);
	if (root) { snprintf(b, sizeof b, "REBOOT %s\n", why); append(p_reboot, b); exit(0); }
	rw_stop_for_reboot();
	sync();
	reboot(RB_AUTOBOOT);
	execl("/sbin/reboot", "reboot", "-f", (char *)NULL);
	{ int fd = open("/proc/sysrq-trigger", O_WRONLY); if (fd >= 0) { if (write(fd, "b", 1) < 0) { } close(fd); } }
	for (;;) { nap(30); sync(); reboot(RB_AUTOBOOT); }
}
static pid_t child;
static void sup_term(int s) { (void)s; if (child > 0) kill(child, SIGTERM); }

static int supervise(void)
{
	int crashes = 0, st, hb[2]; struct pollfd p; char c[16], b[200]; struct sigaction sa;
	memset(&sa, 0, sizeof sa); sa.sa_handler = sup_term; sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
	for (;;) {
		if (pipe(hb)) return 2;
		child = fork();
		if (child < 0) return 2;
		if (child == 0) { close(hb[0]); _exit(worker(hb[1])); }
		close(hb[1]);
		for (;;) {
			int r;
			p.fd = hb[0]; p.events = POLLIN; p.revents = 0;
			r = poll(&p, 1, (int)(T_HEARTBEAT * K * 1000));
			if (r < 0 && errno == EINTR) continue;
			if (r == 0) { snprintf(b, sizeof b, "supervisor: the worker gave no sign of life for %d s: killing it", (int)(T_HEARTBEAT * K)); kmsg(b); kill(child, SIGKILL); break; }
			if (read(hb[0], c, sizeof c) <= 0) break;       /* the pipe closed: the worker is gone */
		}
		close(hb[0]);
		while (waitpid(child, &st, 0) < 0 && errno == EINTR) { }
		if (WIFEXITED(st) && WEXITSTATUS(st) == 0) return 0;                      /* asked to stop */
		if (WIFEXITED(st) && WEXITSTATUS(st) == 99) do_reboot("the worker's fail-safe");
		crashes++;
		snprintf(b, sizeof b, "supervisor: the worker ended unexpectedly (%s %d), crash %d of %d", WIFSIGNALED(st) ? "signal" : "exit", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st), crashes, MAX_CRASHES + 1);
		kmsg(b); { char l[260]; snprintf(l, sizeof l, "[%9.2f] %s\n", now(), b); append(p_log, l); }
		if (crashes > MAX_CRASHES) {
			snprintf(b, sizeof b, "FAILSAFE reason=worker-crash-loop (%d crashes) -> reboot (back to the stock system, which runs its own fan)", crashes);
			kmsg(b); note_disklog(b); nap(T_FLUSH * K);
			do_reboot("worker crash loop");
		}
		nap(1.0 * K);
	}
}

static void paths(void)
{
	const char *t = root ? root : "/tmp";
	snprintf(p_log, sizeof p_log, "%s/ex4fan.log", t); snprintf(p_status, sizeof p_status, "%s/ex4fan.status", t);
	snprintf(p_pid, sizeof p_pid, "%s/ex4fan.pid", t); snprintf(p_notes, sizeof p_notes, "%s/ex4-notes", t);
	snprintf(p_logpid, sizeof p_logpid, "%s/ex4log.pid", t); snprintf(p_kmsg, sizeof p_kmsg, "%s/kmsg", t);
	snprintf(p_reboot, sizeof p_reboot, "%s/reboot", t);
	snprintf(p_now, sizeof p_now, "%s/now", t); snprintf(p_clockset, sizeof p_clockset, "%s/clockset", t);
	snprintf(p_json, sizeof p_json, "%s/ex4fan.json", t);                                  /* v7 */
	snprintf(p_sendtest, sizeof p_sendtest, "%s/ex4fan.sendtest", t);                      /* v8 */
	if (root) snprintf(p_run, sizeof p_run, "%s/run/ex4panel", root); else snprintf(p_run, sizeof p_run, "/var/run/ex4panel");
	snprintf(p_ctl, sizeof p_ctl, "%.280s/ctl", p_run); snprintf(p_alerts, sizeof p_alerts, "%.280s/alerts.d", p_run);
	if (root) snprintf(p_conf, sizeof p_conf, "%s/ex4panel.conf", root); else snprintf(p_conf, sizeof p_conf, "/etc/config/ex4panel");
}

/* ---------- v7: the test / bench subcommands ---------- */
static int panel_build_cli(int argc, char **argv)   /* panel-build KIND ARGS...: the frame the daemon would send, or REFUSED */
{
	struct frame f; int k, rc = -1; char hx[2 * FRAME_MAX + 1];
	for (k = 0; k < PK_N; k++) if (!strcmp(argv[0], PK[k].name)) break;
	if (k == PK_N) { printf("REFUSED no such kind\n"); return 1; }
	switch (PK[k].rule) {
	case R_TEXT: if (argc == 2) rc = build_text(&f, k, argv[1]); break;
	case R_IP: { struct in_addr a; if (argc == 2 && inet_pton(AF_INET, argv[1], &a) == 1) rc = build_ip(&f, k, a); break; }
	case R_FIXED: if (argc == 1) rc = build_fixed(&f, k); break;
	case R_VOL: if (argc == 5) rc = build_vol(&f, atoi(argv[1]), atoi(argv[2]), atoi(argv[3]), atoi(argv[4])); break;
	case R_USED: if (argc == 3) rc = build_used(&f, atoi(argv[1]), atoi(argv[2])); break;
	case R_TEMP: if (argc == 3) rc = build_temp(&f, atoi(argv[1]), atoi(argv[2])); break;
	case R_ARG: if (argc == 2) rc = build_arg(&f, k, k == PK_STANDBY ? standby_code(atoi(argv[1])) : atoi(argv[1])); break;
	}
	if (rc) { printf("REFUSED\n"); return 1; }
	hexs(hx, &f); printf("%s\n", hx);
	return 0;
}
static int ctl_cli(int argc, char **argv)           /* ex4fan ctl [--test-root DIR] WORDS...: one request file into the daemon's ctl/ */
{
	char line[200] = "", f[400]; int i, n = 0;
	if (argc >= 2 && !strcmp(argv[0], "--test-root")) { root = argv[1]; argv += 2; argc -= 2; }
	paths();
	for (i = 0; i < argc; i++) n += snprintf(line + n, sizeof line - n, "%s%s", i ? " " : "", argv[i]);
	if (!argc || n >= (int)sizeof line - 2) { fprintf(stderr, "usage: ex4fan ctl refresh | send SLOT | send-test | notice shutdown|reboot | poweroff\n"); return 64; }
	strcat(line, "\n");
	snprintf(f, sizeof f, "%s/req-%d-%ld", p_ctl, (int)getpid(), (long)time(NULL));
	if (write_atomic(f, line, strlen(line), 0600)) { fprintf(stderr, "ex4fan ctl: cannot write into %s (%s): is the daemon running, are you root?\n", p_ctl, strerror(errno)); return 2; }
	printf("request written: %s (the daemon's log says what it did)\n", f);
	return 0;
}

int main(int argc, char **argv)
{
	int i, fg = 0, fast = 0; char b[32];
	if (argc >= 2 && !strcmp(argv[1], "frames")) {
		for (i = 0; i < TX_N; i++) printf("%-11s %02x%02x%02x%02x%02x%02x%02x\n", TX_NAME[i], TX[i][0], TX[i][1], TX[i][2], TX[i][3], TX[i][4], TX[i][5], TX[i][6]);
		return 0;
	}
	if (argc >= 2 && !strcmp(argv[1], "events")) {      /* v5: the event names (tests) */
		for (i = 0; i < N_EVENT; i++) printf("%02x %s\n", EVENT[i].b1, EVENT[i].name);
		return 0;
	}
	if (argc >= 2 && !strcmp(argv[1], "panel-kinds")) {        /* v7 */
		for (i = 0; i < PK_N; i++) { int j; printf("%-9s %-18s ", PK[i].name, PK[i].wd); for (j = 0; j < PK[i].plen; j++) printf("%02x", PK[i].pre[j]); printf(" rule=%d\n", PK[i].rule); }
		return 0;
	}
	if (argc >= 3 && !strcmp(argv[1], "panel-build")) return panel_build_cli(argc - 2, argv + 2);
	if (argc == 3 && !strcmp(argv[1], "panel-check")) {        /* panel-check HEX: the kind frame_check() gives it, or REFUSED */
		unsigned char fb[64]; int n = 0, k; const char *h = argv[2];
		while (h[0] && h[1] && n < 64) { unsigned v; if (sscanf(h, "%2x", &v) != 1) break; fb[n++] = v; h += 2; }
		k = frame_check(fb, n);
		printf("%s\n", k < 0 ? "REFUSED" : PK[k].name); return k < 0;
	}
	if (argc >= 2 && !strcmp(argv[1], "tachcalc")) {           /* tachcalc NS...: rpm from rising-edge timestamps (the edge path's arithmetic) */
		static unsigned long long ts[TACH_EVENTS]; int k = 0;
		for (i = 2; i < argc && k < TACH_EVENTS; i++) ts[k++] = strtoull(argv[i], NULL, 10);
		printf("%d\n", rpm_from_ns(ts, k)); return 0;
	}
	if (argc >= 2 && !strcmp(argv[1], "ctl")) return ctl_cli(argc - 2, argv + 2);
	if (argc >= 2 && !strcmp(argv[1], "lut")) { for (i = 0; i < (int)sizeof LUT; i++) printf("%02x", LUT[i]); printf("\n"); return 0; }
	if (argc >= 2 && !strcmp(argv[1], "curve")) {       /* curve START T T T...: the state after each reading */
		int s = argc >= 3 ? atoi(argv[2]) : 3;
		for (i = 3; i < argc; i++) { s = curve_next(s, atoi(argv[i])); printf("%d%s", s, i + 1 < argc ? " " : "\n"); }
		return 0;
	}
	if (argc < 2 || strcmp(argv[1], "daemon")) {
		fprintf(stderr, "usage: ex4fan daemon [--foreground] [--panel] [--allow-poweroff] | frames | events | lut | curve START T...\n"
				"       ex4fan ctl refresh | send SLOT | send-test | notice shutdown|reboot | poweroff\n"
				"       ex4fan panel-kinds | panel-build KIND ARGS... | panel-check HEX | tachcalc NS...\n"
				"       ex4fan daemon --test-root DIR [--fast] [--foreground]\n"
				"       ex4fan daemon --test-hw [--tty ttySN] [--tach-chip TEXT --tach-line N] [--foreground]\n");
		return 64;
	}
	for (i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "--foreground")) fg = 1;
		else if (!strcmp(argv[i], "--fast")) fast = 1;
		else if (!strcmp(argv[i], "--test-hw")) test_hw = 1;
		else if (!strcmp(argv[i], "--panel")) opt_panel = 1;                  /* v7 */
		else if (!strcmp(argv[i], "--allow-poweroff")) opt_poweroff = 1;      /* v7: the owner's word only on the real box */
		else if (!strcmp(argv[i], "--test-root") && i + 1 < argc) root = argv[++i];
		else if (!strcmp(argv[i], "--tty") && i + 1 < argc) opt_tty = argv[++i];
		else if (!strcmp(argv[i], "--tach-chip") && i + 1 < argc) opt_chip = argv[++i];
		else if (!strcmp(argv[i], "--tach-line") && i + 1 < argc) opt_line = atoi(argv[++i]);
		else { fprintf(stderr, "ex4fan: unknown option %s\n", argv[i]); return 64; }
	}
	if (fast && !root) { fprintf(stderr, "ex4fan: --fast only with --test-root\n"); return 64; }
	if (strlen(opt_tty) > 16 || strchr(opt_tty, '/')) { fprintf(stderr, "ex4fan: --tty takes a port name (ttyS0), not a path\n"); return 64; }
	if (!test_hw && (strcmp(opt_tty, "ttyS1") || strcmp(opt_chip, "10140.gpio") || opt_line != 7)) { fprintf(stderr, "ex4fan: --tty / --tach-chip / --tach-line only with --test-hw\n"); return 64; }
	if (fast) K = 0.1;
	paths();
	if (slurp(p_pid, b, sizeof b) > 0 && atoi(b) > 1 && kill(atoi(b), 0) == 0) { fprintf(stderr, "ex4fan: already running (pid %d)\n", atoi(b)); return 0; }
	if (!fg) {
		pid_t p = fork();
		if (p < 0) return 2;
		if (p > 0) return 0;
		setsid();
		{ int n = open("/dev/null", O_RDWR); if (n >= 0) { dup2(n, 0); dup2(n, 1); dup2(n, 2); if (n > 2) close(n); } }
	}
	signal(SIGPIPE, SIG_IGN);
	{ FILE *pf = fopen(p_pid, "w"); if (pf) { fprintf(pf, "%d\n", (int)getpid()); fclose(pf); } }
	return supervise();
}
