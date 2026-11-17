/* ex4fan.c : the fan + front-panel daemon of the EX4 RAM trial (bundle-v5, run 7; v4 = run 6). One static ARM binary.
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
#define TACH_WINDOW   0.5
#define MAX_CRASHES   5

/* ---------- paths ---------- */
static const char *root;                /* --test-root */
static int test_hw;
static const char *opt_tty = "ttyS1";               /* uart1: the kernel's name of the port (--tty, test only, names another) */
static const char *opt_chip = "10140.gpio";        /* the high GPIO bank, f1010140.gpio */
static int opt_line = 7;                           /* GPIO 39 = 32 + 7 */
static char p_log[300], p_status[300], p_pid[300], p_notes[300], p_logpid[300], p_kmsg[300], p_reboot[300], p_now[300], p_clockset[300];

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

static int mcu_write(int idx)           /* THE ONLY WRITER OF THE PORT. A frame is an index into TX[], never bytes. */
{
	if (idx < 0 || idx >= TX_N || tty < 0) return -1;
	n_sent++;
	return write(tty, TX[idx], sizeof TX[idx]) == (ssize_t)sizeof TX[idx] ? 0 : -1;
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
		left = (int)((end - now()) * 1000.0);
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
static struct drv { char name[8]; int temp; } drv[MAXDRV];
static int ndrv;

static int smart_temp(const char *name)             /* degrees C, or -1 */
{
	unsigned char cdb[16] = { 0x85, 4 << 1, 0x0e, 0, 0xd0, 0, 1, 0, 0, 0, 0x4f, 0, 0xc2, 0, 0xb0, 0 };
	/* ATA PASS-THROUGH(16), PIO data-in, one sector from the device: SMART (B0) READ DATA (D0), LBA mid/high 4F/C2 */
	unsigned char buf[512], sense[32], sum = 0; struct sg_io_hdr h; char sysdev[64], want[32], mine[40], path[64];
	int fd, i, t194 = -1, t190 = -1;
	snprintf(sysdev, sizeof sysdev, "/sys/block/%s/dev", name);
	snprintf(want, sizeof want, "/dev/%s", name);
	snprintf(mine, sizeof mine, "/dev/.ex4fan-%s", name);
	if (node_for(sysdev, want, mine, path, sizeof path)) return -1;
	fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);          /* read-only: this file has no write to a disk */
	if (fd < 0) return -1;
	memset(&h, 0, sizeof h); memset(buf, 0, sizeof buf);
	h.interface_id = 'S'; h.dxfer_direction = SG_DXFER_FROM_DEV;
	h.cmd_len = sizeof cdb; h.cmdp = cdb; h.mx_sb_len = sizeof sense; h.sbp = sense;
	h.dxfer_len = sizeof buf; h.dxferp = buf; h.timeout = 5000;
	i = ioctl(fd, SG_IO, &h);
	close(fd);
	if (i < 0 || h.status || h.host_status || (h.driver_status & 0x0f)) return -1;
	for (i = 0; i < 512; i++) sum += buf[i];
	if (sum) return -1;                                           /* the SMART data sector carries a checksum */
	for (i = 0; i < 30; i++) {
		const unsigned char *e = buf + 2 + 12 * i;
		if (e[0] == 194) t194 = e[5];                               /* raw value, low byte (WD reads the same field through smartctl) */
		if (e[0] == 190) t190 = e[5];
	}
	if (t194 < 1 || t194 > 110) t194 = (t190 >= 1 && t190 <= 110) ? t190 : -1;
	return t194;
}
static void drives_read(void)
{
	ndrv = 0;
	if (root) {
		char b[512], p[300], *s, *e; int t;
		snprintf(p, sizeof p, "%s/drives", root);
		if (slurp(p, b, sizeof b) <= 0) return;
		for (s = b; *s && ndrv < MAXDRV; s = e) {
			e = strchr(s, '\n'); if (e) *e++ = 0; else e = s + strlen(s);
			if (sscanf(s, "%7s %d", drv[ndrv].name, &t) == 2) drv[ndrv++].temp = t;
		}
		return;
	} else {
		DIR *d = opendir("/sys/block"); struct dirent *de; char names[MAXDRV][8]; int n = 0, i, j;
		if (!d) return;
		memset(names, 0, sizeof names);
		while ((de = readdir(d)) && n < MAXDRV) if (de->d_name[0] == 's' && de->d_name[1] == 'd' && strlen(de->d_name) == 3) {
			char lp[300], tgt[300]; ssize_t k; static char usb_said[26];
			snprintf(lp, sizeof lp, "/sys/block/%s", de->d_name);
			k = readlink(lp, tgt, sizeof tgt - 1);            /* v5: USB 3 works now, so a USB disk can show up as sdX. It is not in a bay: */
			if (k > 0) { tgt[k] = 0; if (strstr(tgt, "/usb")) { /* no SMART through its bridge, and not this fan's to cool. Not counted. */
				int c = de->d_name[2] - 'a';
				if (c >= 0 && c < 26 && !usb_said[c]) { usb_said[c] = 1; mark("%s is a USB disk (not in a bay): not counted as a drive", de->d_name); }
				continue; } }
			memcpy(names[n++], de->d_name, 4);
		}
		closedir(d);
		for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) if (strcmp(names[i], names[j]) > 0) { char t[8]; memcpy(t, names[i], 8); memcpy(names[i], names[j], 8); memcpy(names[j], t, 8); }
		for (i = 0; i < n; i++) { memcpy(drv[ndrv].name, names[i], 8); drv[ndrv].temp = smart_temp(names[i]); ndrv++; }
	}
}
static int soc_read(void)                           /* degrees C, or -1 */
{
	char b[32], p[300];
	if (root) snprintf(p, sizeof p, "%s/soc", root); else snprintf(p, sizeof p, "/sys/class/thermal/thermal_zone0/temp");
	if (slurp(p, b, sizeof b) <= 0) return -1;
	return atoi(b) / 1000;
}

/* ---------- the tachometer: GPIO 39, counted the way WD counts it ---------- */
static int tach_fd = -1, tach_sysfs = -1; static unsigned long tach_samples;
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
			snprintf(rq.consumer, sizeof rq.consumer, "ex4fan-tach");
			if (ioctl(fd, GPIO_V2_GET_LINE_IOCTL, &rq) == 0) { tach_fd = rq.fd; mark("tachometer: line %d of %s (%s) through the GPIO character device", opt_line, path, ci.label); }
			else mark("tachometer: %s (%s) refused line %d: %s", path, ci.label, opt_line, strerror(errno));
		}
		close(fd);
	}
	if (tach_fd < 0 && !test_hw) {                    /* second way in: the sysfs GPIO class (GPIO 39 = base 32 + 7) */
		int e = open("/sys/class/gpio/export", O_WRONLY | O_CLOEXEC);
		if (e >= 0) { if (write(e, "39", 2) < 0) { } close(e); }
		tach_sysfs = open("/sys/class/gpio/gpio39/value", O_RDONLY | O_CLOEXEC);
		if (tach_sysfs >= 0) mark("tachometer: GPIO 39 through /sys/class/gpio (the character device did not give the line)");
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
static int tach_rpm(void)                           /* rpm, or -1 = cannot be read */
{
	double t0, t; int last, v, changes = 0;
	if (root) {
		char b[32], p[300];
		snprintf(p, sizeof p, "%s/tach", root);
		if (slurp(p, b, sizeof b) <= 0) return -1;
		return atoi(b);
	}
	if (tach_fd < 0 && tach_sysfs < 0) return -1;
	if ((last = tach_level()) < 0) return -1;
	tach_samples = 0;
	for (t0 = now(); (t = now()) - t0 < TACH_WINDOW; ) {
		if ((v = tach_level()) < 0) return -1;
		tach_samples++;
		if (v != last) { changes++; last = v; }
	}
	if (changes <= 1) return 0;                       /* WD: one change in the window is noise, not a turning fan */
	return (int)(changes * 15.0 / (t - t0) + 0.5);    /* two pulses a turn = four level changes a turn: changes per second x 15 */
}

/* ---------- the worker ---------- */
static volatile sig_atomic_t got_term;
static void on_term(int s) { (void)s; got_term = 1; }
static int hb_fd = -1;
static void heartbeat(void) { if (hb_fd >= 0 && write(hb_fd, "h", 1) < 0) { } }

static int level, state = 3, level_acked, rpm = -1, soc = -1, T = -1;
static double t_start, zero_since, last_fan_cmd;

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
	{ char tmp[320]; int fd; snprintf(tmp, sizeof tmp, "%s.new", p_status);
	  fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	  if (fd >= 0) { if (write(fd, line, strlen(line)) < 0 || write(fd, "\n", 1) < 0) { } close(fd); rename(tmp, p_status); } }
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
		if (drv[i].temp >= DRIVE_REBOOT && !root) { int again = smart_temp(drv[i].name); if (again >= 0) drv[i].temp = again; }
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
static void tach(void)
{
	rpm = tach_rpm();
	if (rpm == 0) {
		if (zero_since <= 0) { zero_since = now(); mark("rpm reads 0 with FAN=%d commanded: fan to MAX; a reboot follows if it still reads 0 in %d s", level, (int)(T_RPM_ZERO * K + 0.5)); }
		else if (now() - zero_since >= T_RPM_ZERO * K) { status(1); failsafe("rpm-zero for %d s while FAN=%d(%s) was commanded", (int)(now() - zero_since + 0.5), level, LEVEL_NAME[level]); }
	} else {
		if (zero_since > 0 && rpm > 0) mark("rpm is back: %d", rpm);
		zero_since = 0;
	}
	apply();
}

static int worker(int hb)
{
	double next_temp, next_tach, next_status, next_file = 0, t; struct sigaction sa; int first_temps = 0;
	hb_fd = hb;
	memset(&sa, 0, sizeof sa); sa.sa_handler = on_term; sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
	t_start = now();
	mark("start pid=%d%s%s", (int)getpid(), root ? " TEST-ROOT" : "", test_hw ? " TEST-HW" : "");
	if (tty_open()) failsafe("port-open-failed (%s)", strerror(errno));
	set_level(3, "start: first action");
	heartbeat();
	tach_init();
	next_temp = now(); next_tach = now() + 5 * K; next_status = now() + T_STATUS * K;
	for (;;) {
		heartbeat();
		mcu_pump(200);
		if (got_term) { set_level(3, "stopping: the fan is left at HIGH"); status(1); return 0; }
		t = now();
		if (t >= next_temp) { temps(); next_temp = now() + T_TEMP * K; first_temps = 1; }
		if (t >= next_tach) { tach(); next_tach = now() + (zero_since > 0 ? T_TACH / 2 : T_TACH) * K; }
		t = now();
		if (last_rx <= 0 && t - t_start >= T_MCU_START * K) failsafe("micro-never-answered: no valid frame in %d s (%u frames sent)", (int)(t - t_start), n_sent);
		if (last_rx > 0 && t - last_rx >= T_MCU_SILENT * K) failsafe("micro-went-silent: no valid frame for %d s", (int)(t - last_rx));
		/* v5: once the first full reading is in and the micro answers: read its clock, then tell it the system is up.
		 * Neither is sent to a micro that has never answered (the first ten frames stay FAN HIGH), neither can reboot. */
		if (first_temps && last_rx > 0 && clock_at <= 0 && (clock_tries == 0 || (clock_tries == 1 && t - clock_asked >= T_CLOCK_AGAIN * K))) { clock_ask(); heartbeat(); t = now(); }
		if (first_temps && last_rx > 0 && level_acked && zero_since <= 0 && t - t_start >= T_READY * K
		    && (ready_tries == 0 || (ready_tries == 1 && ready_state < 0 && t - ready_at >= T_READY_AGAIN * K))) { ready_send(); heartbeat(); status(1); t = now(); }
		if (t >= next_status) { status(1); next_status = t + T_STATUS * K; next_file = t + T_STATFILE * K; }
		else if (t >= next_file) { status(0); next_file = t + T_STATFILE * K; }
	}
}

/* ---------- the supervisor: restarts a worker that died or hangs; does the reboot ---------- */
static void do_reboot(const char *why)
{
	char b[300];
	snprintf(b, sizeof b, "rebooting now: %s", why);
	kmsg(b);
	if (root) { snprintf(b, sizeof b, "REBOOT %s\n", why); append(p_reboot, b); exit(0); }
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
	if (argc >= 2 && !strcmp(argv[1], "lut")) { for (i = 0; i < (int)sizeof LUT; i++) printf("%02x", LUT[i]); printf("\n"); return 0; }
	if (argc >= 2 && !strcmp(argv[1], "curve")) {       /* curve START T T T...: the state after each reading */
		int s = argc >= 3 ? atoi(argv[2]) : 3;
		for (i = 3; i < argc; i++) { s = curve_next(s, atoi(argv[i])); printf("%d%s", s, i + 1 < argc ? " " : "\n"); }
		return 0;
	}
	if (argc < 2 || strcmp(argv[1], "daemon")) {
		fprintf(stderr, "usage: ex4fan daemon [--foreground] | frames | events | lut | curve START T...\n"
				"       ex4fan daemon --test-root DIR [--fast] [--foreground]\n"
				"       ex4fan daemon --test-hw [--tty ttySN] [--tach-chip TEXT --tach-line N] [--foreground]\n");
		return 64;
	}
	for (i = 2; i < argc; i++) {
		if (!strcmp(argv[i], "--foreground")) fg = 1;
		else if (!strcmp(argv[i], "--fast")) fast = 1;
		else if (!strcmp(argv[i], "--test-hw")) test_hw = 1;
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
