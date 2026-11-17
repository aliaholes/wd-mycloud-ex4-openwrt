/* ex4log.c : the EX4 RAM trial's black box. One static ARM binary, two jobs.
 *
 *   TRIAL SIDE (runs under the trial kernel, started from the overlay's preinit hook):
 *     ex4log daemon [--min-sectors N] [--max-sectors N] [--skip-port N]... [--tag TEXT]
 *         Waits for a SATA disk, picks ONE raw target (partition 3 of a SATA disk, size inside the window, not
 *         mounted, no holders; the disk on the LOWEST ATA port wins, so the choice does not depend on the order
 *         the kernel happens to name the disks in; it waits up to 8 s for port 1 once any disk is there;
 *         --skip-port keeps it off a port for good, e.g. a bay whose disk has bad sectors in the region), then
 *         every few seconds writes a snapshot there: its own progress trail, a status
 *         block (/proc + /sys reads), a few command outputs (ip addr, logread, ...), the self-test file when it
 *         exists, and the whole kernel log (dmesg). Every milestone also goes to /dev/kmsg as "ex4log: ...", so a
 *         run where no disk ever shows up still leaves a trail in the kernel log buffer (RAM; see ex4peek klog).
 *     ex4log note TEXT...     append a line to /tmp/ex4-notes (the daemon carries that file) and poke the daemon
 *
 *   STOCK SIDE (runs under WD's firmware; opens the device O_RDONLY, there is no write call on this path):
 *     ex4log read DEV [--state] [--save FILE]
 *         Checks both slots (magic, header crc, payload crc), prints the newest valid snapshot.
 *         --state prints one line only ("state none" | "state damaged" | "state run=.. gen=.. seq=.. uptime=..").
 *         exit 0 = a valid log was found · 3 = no log (no magic in either slot) · 4 = damaged only · 2 = error
 *
 *   TEST (any box): ex4log daemon --test-dev FILE [--once | --count N --interval SECS] [--run-id 32HEX]
 *                                 [--payload-file F] --foreground
 *
 * ON-DISK FORMAT (little-endian), inside the target partition:
 *   region = [1 MiB, 3 MiB) : two slots of 1 MiB. Snapshot number seq goes to slot seq%2, so a write that is cut
 *   off (power, watchdog) can only damage the slot being written; the other one still holds the snapshot before.
 *   slot = one 512-byte header sector + payload (text, up to 1 MiB - 512).
 *   header (64 bytes, rest of the sector zero):
 *     0  magic "EX4LOG1\n"      8  version (1)      12 header length (64)     16 run id (16 bytes, random per boot)
 *     32 gen (one more than the newest log found on the disk when the daemon started: orders runs)
 *     36 seq (1, 2, 3... inside a run)   40 uptime seconds   44 payload length   48 crc32 of the payload (zlib)
 *     52 slot (u16)  54 flags (u16; bit0 = dmesg cut in the middle to fit)   56 slot size   60 crc32 of bytes 0..59
 *   Order of a write: payload, flush, header, flush. A reader tells FRESH from STALE by comparing the state line
 *   taken before the jump with the one after it (ex4-trial.sh does that).
 *
 * WALLS in the writer: it only ever opens a partition whose sysfs "partition" is 3, whose disk hangs off an ATA
 * port, whose size is inside the window, that is not mounted and has no holders; and every write is bounds-checked
 * against [1 MiB, 3 MiB). It never opens a whole-disk node.
 *
 * Build (32 KiB pages for the stock kernel; fine on the 4 KiB trial kernel too):
 *   arm-linux-gnueabi-gcc -static -Os -march=armv5te -Wall -Wl,-z,max-page-size=0x8000 -o ex4log ex4log.c
 * Born Nov 16 2026 (aliaholes). SPDX-License-Identifier: GPL-2.0-or-later. */
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
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
#include <limits.h>
#include <time.h>
#include <poll.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/klog.h>
#include <sys/ioctl.h>
#include <sys/sysmacros.h>
#include <linux/fs.h>

#define MAGIC        "EX4LOG1\n"
#define REGION_OFF   (1u << 20)
#define SLOT_SIZE    (1u << 20)
#define NSLOTS       2
#define SECTOR       512u
#define HDR_LEN      64u
#define CAP          (SLOT_SIZE - SECTOR)
#define FLAG_CUT     1u

/* ---------- small helpers ---------- */
static uint32_t crc_tab[256];
static void crc_init(void)
{
	uint32_t c; int n, k;
	for (n = 0; n < 256; n++) { c = n; for (k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320u & -(c & 1)); crc_tab[n] = c; }
}
static uint32_t crc32z(const unsigned char *p, size_t n)
{
	uint32_t c = 0xffffffffu; size_t i;
	for (i = 0; i < n; i++) c = crc_tab[(c ^ p[i]) & 0xff] ^ (c >> 8);
	return ~c;
}
static void put32(unsigned char *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void put16(unsigned char *p, uint32_t v) { p[0] = v; p[1] = v >> 8; }
static uint32_t get32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint32_t get16(const unsigned char *p) { return p[0] | p[1] << 8; }

static double uptime(void)
{
	struct timespec ts;
	if (clock_gettime(CLOCK_MONOTONIC, &ts)) return 0;
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static long slurp(const char *path, char *buf, size_t cap)        /* returns bytes read, -1 on error; always NUL-ends */
{
	int fd = open(path, O_RDONLY | O_CLOEXEC); size_t got = 0; ssize_t r;
	if (cap) buf[0] = 0;
	if (fd < 0) return -1;
	while (got + 1 < cap && (r = read(fd, buf + got, cap - 1 - got)) > 0) got += r;
	close(fd);
	buf[got] = 0;
	return got;
}
static void chomp(char *s) { size_t n = strlen(s); while (n && (s[n - 1] == '\n' || s[n - 1] == ' ')) s[--n] = 0; }

static int pwrite_all(int fd, const unsigned char *p, size_t n, off_t off)
{
	while (n) {
		ssize_t w = pwrite(fd, p, n, off);
		if (w < 0) { if (errno == EINTR) continue; return -1; }
		if (!w) { errno = EIO; return -1; }
		p += w; n -= w; off += w;
	}
	return 0;
}
static int pread_all(int fd, unsigned char *p, size_t n, off_t off)
{
	while (n) {
		ssize_t r = pread(fd, p, n, off);
		if (r < 0) { if (errno == EINTR) continue; return -1; }
		if (!r) { errno = EIO; return -1; }
		p += r; n -= r; off += r;
	}
	return 0;
}

/* ---------- the format ---------- */
struct hdr { unsigned char run[16]; uint32_t gen, seq, up, len, crc, slot, flags, slot_size; };
enum { S_EMPTY, S_BADHDR, S_TORN, S_OK };
static const char *S_NAME[] = { "EMPTY (no magic)", "BAD HEADER (magic present, header does not check)", "TORN (header fine, payload crc wrong)", "OK" };

static void hdr_pack(unsigned char *s, const struct hdr *h)       /* s = one zeroed sector */
{
	memcpy(s, MAGIC, 8); put32(s + 8, 1); put32(s + 12, HDR_LEN); memcpy(s + 16, h->run, 16);
	put32(s + 32, h->gen); put32(s + 36, h->seq); put32(s + 40, h->up); put32(s + 44, h->len); put32(s + 48, h->crc);
	put16(s + 52, h->slot); put16(s + 54, h->flags); put32(s + 56, h->slot_size); put32(s + 60, crc32z(s, 60));
}
static int hdr_parse(const unsigned char *s, int slot, struct hdr *h)   /* S_EMPTY / S_BADHDR / S_OK (payload not checked) */
{
	if (memcmp(s, MAGIC, 8)) return S_EMPTY;
	if (get32(s + 8) != 1 || get32(s + 12) != HDR_LEN || get32(s + 60) != crc32z(s, 60)) return S_BADHDR;
	memcpy(h->run, s + 16, 16);
	h->gen = get32(s + 32); h->seq = get32(s + 36); h->up = get32(s + 40); h->len = get32(s + 44); h->crc = get32(s + 48);
	h->slot = get16(s + 52); h->flags = get16(s + 54); h->slot_size = get32(s + 56);
	if (h->slot != (uint32_t)slot || h->slot_size != SLOT_SIZE || h->len > CAP || h->seq % NSLOTS != (uint32_t)slot) return S_BADHDR;
	return S_OK;
}
static int slot_check(int fd, int slot, struct hdr *h, unsigned char *payload)   /* payload: CAP bytes or NULL */
{
	unsigned char sec[SECTOR]; off_t base = (off_t)REGION_OFF + (off_t)slot * SLOT_SIZE; int st;
	static unsigned char scratch[CAP];
	if (pread_all(fd, sec, SECTOR, base)) return -1;
	st = hdr_parse(sec, slot, h);
	if (st != S_OK) return st;
	if (!payload) payload = scratch;
	if (h->len && pread_all(fd, payload, h->len, base + SECTOR)) return -1;
	return crc32z(payload, h->len) == h->crc ? S_OK : S_TORN;
}
static int newer(const struct hdr *a, const struct hdr *b) { return a->gen != b->gen ? a->gen > b->gen : a->seq > b->seq; }
static void hex16(const unsigned char *r, char *o) { int i; for (i = 0; i < 16; i++) sprintf(o + 2 * i, "%02x", r[i]); }

static long long dev_bytes(int fd)
{
	struct stat st; uint64_t n = 0;
	if (fstat(fd, &st)) return -1;
	if (S_ISBLK(st.st_mode)) return ioctl(fd, BLKGETSIZE64, &n) ? -1 : (long long)n;
	return st.st_size;
}

/* ---------- READ (stock side; O_RDONLY) ---------- */
static int cmd_read(int argc, char **argv)
{
	const char *dev = NULL, *save = NULL; int state = 0, i, st[NSLOTS], best = -1, fd, any_dmg = 0;
	struct hdr h[NSLOTS]; static unsigned char pay[NSLOTS][CAP]; char rid[33]; long long sz;
	for (i = 0; i < argc; i++) {
		if (!strcmp(argv[i], "--state")) state = 1;
		else if (!strcmp(argv[i], "--save") && i + 1 < argc) save = argv[++i];
		else if (argv[i][0] == '-') { fprintf(stderr, "ex4log read: unknown option %s\n", argv[i]); return 2; }
		else dev = argv[i];
	}
	if (!dev) { fprintf(stderr, "usage: ex4log read DEV [--state] [--save FILE]\n"); return 2; }
	fd = open(dev, O_RDONLY | O_CLOEXEC);
	if (fd < 0) { fprintf(stderr, "ex4log read: open %s (read-only): %s\n", dev, strerror(errno)); return 2; }
	sz = dev_bytes(fd);
	if (sz < (long long)REGION_OFF + (long long)NSLOTS * SLOT_SIZE) {
		fprintf(stderr, "ex4log read: %s is %lld bytes: too small to hold the log region\n", dev, sz); return 2;
	}
	for (i = 0; i < NSLOTS; i++) {
		st[i] = slot_check(fd, i, &h[i], pay[i]);
		if (st[i] < 0) { fprintf(stderr, "ex4log read: read error on %s slot %d: %s\n", dev, i, strerror(errno)); return 2; }
		if (st[i] == S_OK && (best < 0 || newer(&h[i], &h[best]))) best = i;
		if (st[i] == S_BADHDR || st[i] == S_TORN) any_dmg = 1;
	}
	close(fd);
	if (state) {
		if (best < 0) { puts(any_dmg ? "state damaged" : "state none"); return any_dmg ? 4 : 3; }
		hex16(h[best].run, rid);
		printf("state run=%s gen=%u seq=%u uptime=%u\n", rid, h[best].gen, h[best].seq, h[best].up);
		return 0;
	}
	printf("ex4log: %s (%lld bytes), log region [%u, %u)\n", dev, sz, REGION_OFF, REGION_OFF + NSLOTS * SLOT_SIZE);
	for (i = 0; i < NSLOTS; i++) {
		printf("ex4log: slot %d: %s", i, S_NAME[st[i]]);
		if (st[i] == S_OK || st[i] == S_TORN) { hex16(h[i].run, rid); printf("  run %s gen %u seq %u uptime %u s len %u%s", rid, h[i].gen, h[i].seq, h[i].up, h[i].len, h[i].flags & FLAG_CUT ? " (dmesg cut to fit)" : ""); }
		putchar('\n');
	}
	if (best < 0) {
		puts(any_dmg ? "ex4log: RESULT: a log was started here but no slot is whole (damaged)." : "ex4log: RESULT: no log yet (no magic in either slot).");
		return any_dmg ? 4 : 3;
	}
	hex16(h[best].run, rid);
	printf("ex4log: RESULT: newest whole snapshot = slot %d, run %s, gen %u, seq %u, written at uptime %u s, %u bytes%s\n",
	       best, rid, h[best].gen, h[best].seq, h[best].up, h[best].len,
	       st[1 - best] == S_TORN ? " (the other slot is TORN: a later write was cut off; this is the one before it)" : "");
	puts("ex4log: ----- payload -----");
	fwrite(pay[best], 1, h[best].len, stdout);
	if (h[best].len && pay[best][h[best].len - 1] != '\n') putchar('\n');
	puts("ex4log: ----- end -----");
	if (save) {                                             /* after the print: a save that fails must not hide the log */
		int o = open(save, O_WRONLY | O_CREAT | O_EXCL, 0644);
		if (o < 0) { fprintf(stderr, "ex4log read: --save %s: %s (never overwrites)\n", save, strerror(errno)); return 2; }
		if (write(o, pay[best], h[best].len) != (ssize_t)h[best].len || close(o)) { fprintf(stderr, "ex4log read: short write to %s\n", save); return 2; }
		printf("ex4log: saved the payload to %s\n", save);
	}
	return 0;
}

/* ---------- the payload builder (trial side) ---------- */
static char *A; static size_t alen;               /* everything except dmesg */
#define ACAP (384u * 1024)
static char trail[16384]; static size_t tlen;
static int quiet_kmsg;

static void addf(const char *fmt, ...)
{
	va_list ap; int n;
	if (alen + 1 >= ACAP) return;
	va_start(ap, fmt); n = vsnprintf(A + alen, ACAP - alen, fmt, ap); va_end(ap);
	if (n > 0) alen += (size_t)n < ACAP - alen ? (size_t)n : ACAP - alen - 1;
}
static void add_file(const char *title, const char *path, size_t cap)
{
	static char b[65536]; long n;
	if (cap > sizeof b) cap = sizeof b;
	n = slurp(path, b, cap);
	if (n < 0) { addf("-- %s: (%s: %s)\n", title, path, strerror(errno)); return; }
	addf("-- %s (%s, %ld bytes%s)\n%s%s", title, path, n, (size_t)n + 1 >= cap ? ", capped" : "", b, n && b[n - 1] != '\n' ? "\n" : "");
}
static void add_cmd(const char *cmd, int timeout_s, size_t cap)
{
	static char b[131072]; size_t got = 0; int p[2], status = 0, timed = 0; pid_t pid; double end = uptime() + timeout_s;
	if (cap > sizeof b) cap = sizeof b;
	if (pipe(p)) return;
	pid = fork();
	if (pid < 0) { close(p[0]); close(p[1]); return; }
	if (!pid) {
		int n = open("/dev/null", O_RDONLY);
		setpgid(0, 0);
		dup2(n, 0); dup2(p[1], 1); dup2(p[1], 2); close(p[0]); close(p[1]);
		execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
		_exit(127);
	}
	close(p[1]);
	for (;;) {
		struct pollfd pf = { p[0], POLLIN, 0 }; double left = end - uptime(); ssize_t r;
		if (left <= 0) { timed = 1; break; }
		if (poll(&pf, 1, (int)(left * 1000) + 1) <= 0) continue;
		if (got + 1 >= cap) { char sink[4096]; r = read(p[0], sink, sizeof sink); }
		else { r = read(p[0], b + got, cap - 1 - got); if (r > 0) got += r; }
		if (r <= 0) break;
	}
	close(p[0]);
	if (timed) { kill(-pid, SIGKILL); kill(pid, SIGKILL); }
	waitpid(pid, &status, 0);
	b[got] = 0;
	addf("-- $ %s  (%s, %lu bytes%s)\n%s%s", cmd, timed ? "KILLED: timeout" : WIFEXITED(status) ? (WEXITSTATUS(status) ? "exit non-zero" : "exit 0") : "died",
	     (unsigned long)got, got + 1 >= cap ? ", capped" : "", b, got && b[got - 1] != '\n' ? "\n" : "");
}

static void kmsg(const char *line)
{
	int fd; char b[300];
	if (quiet_kmsg) return;
	fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	if (fd < 0) {                                           /* preinit: /dev may not have the node yet; make our own (/tmp is nodev) */
		const char *node = "/dev/.ex4log-kmsg";
		if (mknod(node, S_IFCHR | 0600, makedev(1, 11)) && errno != EEXIST) { node = "/.ex4log-kmsg"; if (mknod(node, S_IFCHR | 0600, makedev(1, 11)) && errno != EEXIST) return; }
		fd = open(node, O_WRONLY | O_CLOEXEC);
		if (fd < 0) return;
	}
	snprintf(b, sizeof b, "<6>ex4log: %s\n", line);
	if (write(fd, b, strlen(b)) < 0) { /* nothing to do about it */ }
	close(fd);
}
static void mark(const char *fmt, ...)            /* a milestone: into the trail and into the kernel log */
{
	char line[240]; va_list ap; int n;
	va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
	n = snprintf(trail + tlen, sizeof trail - tlen, "[%9.2f] %s\n", uptime(), line);
	if (n > 0 && tlen + n < sizeof trail) tlen += n;
	kmsg(line);
}

static void add_status(void)
{
	char b[4096], p[PATH_MAX]; DIR *d; struct dirent *e; static const char *NA[] = { "address", "operstate", "carrier", "speed", "duplex" }; unsigned i;
	addf("-- status at uptime %.2f s\n", uptime());
	if (slurp("/proc/loadavg", b, sizeof b) > 0) addf("loadavg: %s", b);
	if (slurp("/proc/cmdline", b, sizeof b) > 0) addf("cmdline: %s", b);
	if (slurp("/proc/version", b, sizeof b) > 0) addf("version: %s", b);
	if (slurp("/tmp/sysinfo/board_name", b, sizeof b) > 0) addf("board_name: %s", b);
	if (slurp("/tmp/sysinfo/model", b, sizeof b) > 0) addf("model: %s", b);
	if (slurp("/proc/meminfo", b, 200) > 0) addf("meminfo (head):\n%s\n", b);
	addf("block devices:");
	if ((d = opendir("/sys/block"))) {
		while ((e = readdir(d))) {
			if (e->d_name[0] == '.' || !strncmp(e->d_name, "ram", 3) || !strncmp(e->d_name, "loop", 4) || !strncmp(e->d_name, "mtdblock", 8)) continue;
			snprintf(p, sizeof p, "/sys/block/%s/size", e->d_name); slurp(p, b, 64); chomp(b);
			addf(" %s(%s sectors)", e->d_name, b);
		}
		closedir(d);
	}
	addf("\nnetwork devices:\n");
	if ((d = opendir("/sys/class/net"))) {
		while ((e = readdir(d))) {
			if (e->d_name[0] == '.') continue;
			addf("  %s:", e->d_name);
			for (i = 0; i < sizeof NA / sizeof NA[0]; i++) {
				snprintf(p, sizeof p, "/sys/class/net/%s/%s", e->d_name, NA[i]);
				if (slurp(p, b, 64) > 0) { chomp(b); addf(" %s=%s", NA[i], b); } else addf(" %s=-", NA[i]);
			}
			addf("\n");
		}
		closedir(d);
	}
	addf("processes:");
	if ((d = opendir("/proc"))) {
		while ((e = readdir(d))) {
			if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
			snprintf(p, sizeof p, "/proc/%s/cmdline", e->d_name);
			if (slurp(p, b, 64) <= 0) continue;                       /* kernel threads have no cmdline: skipped */
			addf(" %s:%s", e->d_name, b);
		}
		closedir(d);
	}
	addf("\n");
	add_file("partitions", "/proc/partitions", 4096);
	add_file("mtd", "/proc/mtd", 2048);
	add_file("interrupts", "/proc/interrupts", 8192);
	add_file("net/dev", "/proc/net/dev", 4096);
	add_file("modules", "/proc/modules", 8192);
	add_file("mounts", "/proc/mounts", 4096);
}

static void mark_net(void)                        /* one line per network device into the trail + kernel log */
{
	DIR *d = opendir("/sys/class/net"); struct dirent *e; char p[PATH_MAX], o[32], c[32];
	while (d && (e = readdir(d))) {
		if (e->d_name[0] == '.' || !strcmp(e->d_name, "lo")) continue;
		snprintf(p, sizeof p, "/sys/class/net/%s/operstate", e->d_name); if (slurp(p, o, sizeof o) <= 0) strcpy(o, "-"); chomp(o);
		snprintf(p, sizeof p, "/sys/class/net/%s/carrier", e->d_name); if (slurp(p, c, sizeof c) <= 0) strcpy(c, "-"); chomp(c);
		mark("net %s operstate=%s carrier=%s", e->d_name, o, c);
	}
	if (d) closedir(d);
}

static size_t build_payload(unsigned char *out, const unsigned char run[16], uint32_t gen, uint32_t seq, const char *tag,
			    const char *target, const char *payload_file, uint32_t *flags, int fast)
{
	static char *K; static size_t kcap; long klen = 0; char rid[33]; size_t room, n;
	static char *H, *J; static size_t hlen, jcap; static double h_up;      /* H = the kernel log as last seen before its ring wrapped */
	const char *dm; size_t dlen;
	hex16(run, rid);
	alen = 0; *flags = 0;
	addf("== EX4LOG %s  run %s  gen %u  seq %u  uptime %.2f s  target %s ==\n", tag, rid, gen, seq, uptime(), target);
	addf("-- trail (this daemon's milestones; [uptime seconds])\n%s", trail);
	add_file("notes", "/tmp/ex4-notes", 8192);
	add_status();
	if (fast) addf("-- (shutdown snapshot: command outputs skipped to finish before the kill)\n");
	else {
		add_cmd("ip addr 2>&1", 4, 8192);
		add_cmd("ip route 2>&1", 4, 4096);
		add_cmd("ubus call network.interface.lan status 2>&1", 4, 8192);
		add_cmd("cat /etc/config/network 2>&1", 3, 8192);
		add_cmd("logread 2>&1 | tail -n 400", 6, 65536);
	}
	add_file("self-test", "/tmp/ex4-selftest.txt", 65536);
	if (payload_file) {                                                     /* test only: stands in for dmesg (FILE.2, if there, from seq 2 on) */
		char p2[PATH_MAX]; int fd; struct stat st;
		snprintf(p2, sizeof p2, "%s.2", payload_file);
		fd = seq >= 2 ? open(p2, O_RDONLY) : -1;
		if (fd < 0) fd = open(payload_file, O_RDONLY);
		if (fd >= 0 && !fstat(fd, &st)) {
			if ((size_t)st.st_size + 1 > kcap) { free(K); kcap = st.st_size + 1; K = malloc(kcap); }
			klen = K ? read(fd, K, st.st_size) : 0;
		}
		if (fd >= 0) close(fd);
	} else {
		int sz = klogctl(10, NULL, 0);                                  /* SYSLOG_ACTION_SIZE_BUFFER */
		if (sz < 4096) sz = 1 << 17;
		if ((size_t)sz + 1 > kcap) { free(K); kcap = sz + 1; K = malloc(kcap); }
		klen = K ? klogctl(3, K, sz) : -1;                              /* SYSLOG_ACTION_READ_ALL */
	}
	if (klen < 0) { addf("-- dmesg: (klogctl failed: %s)\n", strerror(errno)); klen = 0; }
	dm = K; dlen = klen;
	if (klen > 0) {
		/* The kernel's ring is finite: once it wraps, the start of the boot is gone from it. While the first bytes
		 * still match what we saw before, remember the whole log; after a wrap, carry that copy in front. */
		size_t c = hlen < 64 ? hlen : 64; if ((size_t)klen < c) c = klen;
		if (!H || c < 16 || !memcmp(H, K, c)) {
			char *t = realloc(H, klen);
			if (t) { H = t; memcpy(H, K, klen); hlen = klen; h_up = uptime(); }
		} else {
			char mid[160]; int ml = snprintf(mid, sizeof mid, "\n[... ex4log: the kernel's log ring has wrapped. Above: the log as last seen whole, at uptime %.0f s. Below: the ring now ...]\n", h_up);
			if (hlen + ml + klen > jcap) { free(J); jcap = hlen + ml + klen; J = malloc(jcap); }
			if (J) { memcpy(J, H, hlen); memcpy(J + hlen, mid, ml); memcpy(J + hlen + ml, K, klen); dm = J; dlen = hlen + ml + klen; }
		}
	}
	addf("-- dmesg (%lu bytes%s)\n", (unsigned long)dlen, dm != K ? ", the kept start + the ring now" : "");
	room = CAP - alen;
	memcpy(out, A, alen); n = alen;
	if (dlen <= room) { memcpy(out + n, dm, dlen); n += dlen; }
	else {                                                                  /* keep the start of the boot and the newest end */
		static const char cut[] = "\n[... ex4log: dmesg cut here to fit the slot ...]\n";
		size_t half = (room - (sizeof cut - 1)) / 2;
		memcpy(out + n, dm, half); n += half;
		memcpy(out + n, cut, sizeof cut - 1); n += sizeof cut - 1;
		memcpy(out + n, dm + dlen - half, half); n += half;
		*flags |= FLAG_CUT;
	}
	return n;
}

/* ---------- target discovery + the walls (trial side) ---------- */
struct target { char disk[32], part[40]; unsigned long long sectors; unsigned maj, min; int port; };

static int mounted(const char *part)
{
	static char m[16384]; char pat[64]; char *q;
	if (slurp("/proc/mounts", m, sizeof m) <= 0) return 0;
	snprintf(pat, sizeof pat, "/dev/%s ", part);
	for (q = m; (q = strstr(q, pat)); q++) if (q == m || q[-1] == '\n') return 1;
	return 0;
}
static int has_entries(const char *dir)
{
	DIR *d = opendir(dir); struct dirent *e; int n = 0;
	if (!d) return 0;
	while ((e = readdir(d))) if (e->d_name[0] != '.') n++;
	closedir(d);
	return n;
}
static int on_ata(const char *disk)                 /* the ATA port number the disk hangs off (1, 2, ...), 0 if it is not on one */
{
	char p[PATH_MAX], r[PATH_MAX], *q;
	snprintf(p, sizeof p, "/sys/block/%s", disk);
	if (!realpath(p, r)) return 0;
	if (strstr(r, "/usb")) return 0;
	for (q = r; (q = strstr(q, "/ata")); q += 4) if (q[4] >= '0' && q[4] <= '9') return atoi(q + 4);
	return 0;
}
static int cmp_t(const void *a, const void *b)
{
	const struct target *x = a, *y = b;
	return x->port != y->port ? x->port - y->port : strcmp(x->disk, y->disk);
}

#define MAXSKIP 8
static int skip_port[MAXSKIP], nskip;

static int find_targets(struct target *t, int max, unsigned long long min_s, unsigned long long max_s, int *disks_seen)
{
	DIR *d = opendir("/sys/block"); struct dirent *e; int n = 0, k, port; char p[PATH_MAX], b[64];
	*disks_seen = 0;
	if (!d) return 0;
	while ((e = readdir(d)) && n < max) {
		struct target c; unsigned long long sz;
		if (strncmp(e->d_name, "sd", 2) || strlen(e->d_name) > 8) continue;
		(*disks_seen)++;
		if (!(port = on_ata(e->d_name))) continue;
		for (k = 0; k < nskip && skip_port[k] != port; k++) ;
		if (k < nskip) continue;                                /* a port we were told to keep off */
		memset(&c, 0, sizeof c);
		c.port = port;
		snprintf(c.disk, sizeof c.disk, "%.8s", e->d_name);
		snprintf(c.part, sizeof c.part, "%.8s3", e->d_name);
		snprintf(p, sizeof p, "/sys/block/%s/%s/partition", c.disk, c.part);
		if (slurp(p, b, sizeof b) <= 0 || atoi(b) != 3) continue;
		snprintf(p, sizeof p, "/sys/block/%s/%s/size", c.disk, c.part);
		if (slurp(p, b, sizeof b) <= 0) continue;
		sz = strtoull(b, NULL, 10);
		if (sz < min_s || sz > max_s || sz * 512ull < (unsigned long long)REGION_OFF + (unsigned long long)NSLOTS * SLOT_SIZE) continue;
		snprintf(p, sizeof p, "/sys/block/%s/%s/dev", c.disk, c.part);
		if (slurp(p, b, sizeof b) <= 0 || sscanf(b, "%u:%u", &c.maj, &c.min) != 2) continue;
		snprintf(p, sizeof p, "/sys/block/%s/%s/holders", c.disk, c.part);
		if (has_entries(p) || mounted(c.part)) continue;
		c.sectors = sz;
		t[n++] = c;
	}
	closedir(d);
	qsort(t, n, sizeof t[0], cmp_t);
	return n;
}

static int open_target(const struct target *t)
{
	/* Our own node, made from sysfs' major:minor, so nothing depends on who fills /dev and when. NOT under /tmp
	 * first: OpenWrt mounts /tmp nodev, and a device node on a nodev mount opens with EACCES (found in the qemu
	 * end-to-end test, Nov 16 2026: the first build could never have written a byte). */
	static const char *const DIRS[] = { "/dev", "", "/tmp" };
	char node[64]; int fd = -1, e = ENOENT; unsigned i; long long sz;
	for (i = 0; i < sizeof DIRS / sizeof DIRS[0] && fd < 0; i++) {
		snprintf(node, sizeof node, "%s/.ex4log-%d-%s", DIRS[i], (int)getpid(), t->part);
		unlink(node);
		if (mknod(node, S_IFBLK | 0600, makedev(t->maj, t->min))) { e = errno; continue; }
		fd = open(node, O_RDWR | O_CLOEXEC);
		if (fd < 0) e = errno;
		unlink(node);
	}
	if (fd < 0) { errno = e; return -1; }
	sz = dev_bytes(fd);
	if (sz != (long long)(t->sectors * 512ull)) { close(fd); errno = EINVAL; return -1; }     /* not the partition sysfs described */
	return fd;
}

static int write_slot(int fd, const struct hdr *h, const unsigned char *payload)
{
	static unsigned char padded[CAP]; unsigned char sec[SECTOR];
	off_t base = (off_t)REGION_OFF + (off_t)h->slot * SLOT_SIZE; size_t plen = (h->len + SECTOR - 1) / SECTOR * SECTOR;
	if (h->slot >= NSLOTS || h->len > CAP || plen > CAP) { errno = ERANGE; return -1; }             /* the bounds wall */
	memcpy(padded, payload, h->len); memset(padded + h->len, 0, plen - h->len);
	if (plen && pwrite_all(fd, padded, plen, base + SECTOR)) return -1;
	if (fsync(fd)) return -1;
	memset(sec, 0, sizeof sec); hdr_pack(sec, h);
	if (pwrite_all(fd, sec, SECTOR, base)) return -1;
	return fsync(fd);
}

static volatile sig_atomic_t got_usr1, got_term;
static void on_sig(int s) { if (s == SIGUSR1) got_usr1 = 1; else got_term = 1; }

static void nap(double secs)                      /* sleeps, but returns at once on a signal */
{
	struct timespec ts; ts.tv_sec = (time_t)secs; ts.tv_nsec = (long)((secs - ts.tv_sec) * 1e9);
	if (!got_usr1 && !got_term) nanosleep(&ts, NULL);
}

static int parse_run(const char *hex, unsigned char run[16])
{
	int i; unsigned v;
	if (strlen(hex) != 32) return -1;
	for (i = 0; i < 16; i++) { if (sscanf(hex + 2 * i, "%2x", &v) != 1) return -1; run[i] = v; }
	return 0;
}
static void make_run(unsigned char run[16])
{
	char b[64]; int i, fd; unsigned v, k = 0;
	if (slurp("/proc/sys/kernel/random/boot_id", b, sizeof b) >= 32) {
		for (i = 0; b[i] && k < 16; i++) { if (b[i] == '-') continue; if (sscanf(b + i, "%2x", &v) != 1) break; run[k++] = v; i++; }
		if (k == 16) return;
	}
	fd = open("/dev/urandom", O_RDONLY);
	if (fd >= 0) { k = read(fd, run, 16) == 16 ? 16 : 0; close(fd); if (k == 16) return; }
	for (i = 0; i < 16; i++) run[i] = (unsigned char)((unsigned)time(NULL) >> (i % 4 * 8)) ^ (unsigned char)(getpid() * (i + 1));
}

static int cmd_daemon(int argc, char **argv)
{
	unsigned long long min_s = 8192, max_s = 16777216;      /* 4 MiB .. 8 GiB in 512-byte sectors */
	const char *tag = "ex4log", *test_dev = NULL, *payload_file = NULL, *run_hex = NULL;
	int once = 0, fg = 0, i, fd = -1, nfail = 0, last_disks = -1, announced_wait = 0, have_link = 0, have_selftest = 0;
	unsigned char run[16]; uint32_t gen = 1, seq = 0; char tname[64] = "(none yet)"; struct sigaction sa;
	static unsigned char pay[CAP]; double last_alive = 0, t_start, test_interval = -1, first_seen = -1, settle = 8; long count = 0;

	for (i = 0; i < argc; i++) {
		if (!strcmp(argv[i], "--min-sectors") && i + 1 < argc) min_s = strtoull(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--max-sectors") && i + 1 < argc) max_s = strtoull(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--tag") && i + 1 < argc) tag = argv[++i];
		else if (!strcmp(argv[i], "--skip-port") && i + 1 < argc && nskip < MAXSKIP) skip_port[nskip++] = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--settle") && i + 1 < argc) settle = atof(argv[++i]);
		else if (!strcmp(argv[i], "--test-dev") && i + 1 < argc) test_dev = argv[++i];
		else if (!strcmp(argv[i], "--payload-file") && i + 1 < argc) payload_file = argv[++i];
		else if (!strcmp(argv[i], "--run-id") && i + 1 < argc) run_hex = argv[++i];
		else if (!strcmp(argv[i], "--once")) once = 1;
		else if (!strcmp(argv[i], "--count") && i + 1 < argc) count = atol(argv[++i]);
		else if (!strcmp(argv[i], "--interval") && i + 1 < argc) test_interval = atof(argv[++i]);
		else if (!strcmp(argv[i], "--foreground")) fg = 1;
		else { fprintf(stderr, "ex4log daemon: unknown option %s\n", argv[i]); return 2; }
	}
	if (min_s > max_s) { fprintf(stderr, "ex4log daemon: --min-sectors is above --max-sectors\n"); return 2; }
	if (run_hex) { if (parse_run(run_hex, run)) { fprintf(stderr, "ex4log daemon: --run-id wants 32 hex digits\n"); return 2; } }
	else make_run(run);
	if (test_dev) quiet_kmsg = 1;
	if (!fg && !once) {
		pid_t p = fork();
		if (p < 0) return 2;
		if (p) return 0;
		setsid();
		p = fork();
		if (p < 0) _exit(2);
		if (p) _exit(0);
		if (chdir("/")) { /* stay where we are */ }
		i = open("/dev/null", O_RDWR);
		if (i >= 0) { dup2(i, 0); dup2(i, 1); dup2(i, 2); if (i > 2) close(i); }
	}
	{ FILE *pf = test_dev ? NULL : fopen("/tmp/ex4log.pid", "w"); if (pf) { fprintf(pf, "%d\n", (int)getpid()); fclose(pf); } }
	memset(&sa, 0, sizeof sa); sa.sa_handler = on_sig;
	sigaction(SIGUSR1, &sa, NULL); sigaction(SIGTERM, &sa, NULL);
	signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN);
	A = malloc(ACAP);
	if (!A) return 2;
	if (!getenv("PATH")) setenv("PATH", "/usr/sbin:/usr/bin:/sbin:/bin", 1);
	t_start = uptime();
	{
		char sk[64] = "none"; int o = 0;
		for (i = 0; i < nskip; i++) o += snprintf(sk + o, sizeof sk - o, "%s%d", i ? "," : "", skip_port[i]);
		mark("daemon started (%s), pid %d, window %llu..%llu sectors, ATA ports kept off: %s, interval 5 s then 15 s", tag, (int)getpid(), min_s, max_s, sk);
	}

	for (;;) {
		struct hdr h; uint32_t flags; size_t n; char b[64];
		int term = got_term;
		got_usr1 = 0;
		/* 1. a target */
		if (fd < 0) {
			if (test_dev) {
				fd = open(test_dev, O_RDWR | O_CLOEXEC);
				if (fd < 0) { fprintf(stderr, "ex4log: open %s: %s\n", test_dev, strerror(errno)); return 2; }
				if (dev_bytes(fd) < (long long)REGION_OFF + (long long)NSLOTS * SLOT_SIZE) { fprintf(stderr, "ex4log: %s is too small for the log region\n", test_dev); return 2; }
				snprintf(tname, sizeof tname, "%s", "test-dev");
			} else {
				struct target t[8]; int disks, k, nt = find_targets(t, 8, min_s, max_s, &disks);
				if (disks != last_disks) { mark("sd disks visible: %d, usable log targets: %d", disks, nt); last_disks = disks; }
				if (nt && first_seen < 0) first_seen = uptime();
				/* lowest port wins; if port 1's disk is not there yet, give it a moment before settling for another */
				if (nt && t[0].port != 1 && uptime() - first_seen < settle) nt = 0;
				for (k = nfail % (nt ? nt : 1); k < nt && fd < 0; k++) {
					fd = open_target(&t[k]);
					if (fd < 0) {                           /* say it once per reason, then once a minute: do not flood the log we are saving */
						static char last[96]; static double last_t; char why[96];
						snprintf(why, sizeof why, "cannot open %s (%u:%u): %s", t[k].part, t[k].maj, t[k].min, strerror(errno));
						if (strcmp(why, last) || uptime() - last_t >= 60) { mark("%s", why); snprintf(last, sizeof last, "%s", why); last_t = uptime(); }
					}
					else { snprintf(tname, sizeof tname, "%s@ata%d", t[k].part, t[k].port); mark("log target = %s on ATA port %d (%llu sectors, dev %u:%u), region [1 MiB, 3 MiB)", t[k].part, t[k].port, t[k].sectors, t[k].maj, t[k].min); }
				}
				if (fd < 0 && ((announced_wait == 0 && uptime() - t_start > 20) || (announced_wait == 1 && uptime() - t_start > 120))) {
					mark("still no usable log target after %d s (sd disks visible: %d); I keep looking, this trail stays in the kernel log", announced_wait ? 120 : 20, disks);
					mark_net(); announced_wait++;
				}
			}
			if (fd >= 0) {                                       /* order this run after whatever is on the disk */
				struct hdr o; int s;
				for (s = 0; s < NSLOTS; s++) if (slot_check(fd, s, &o, NULL) == S_OK && o.gen >= gen) gen = o.gen + 1;
			}
		}
		/* 2. cheap milestones */
		if (!test_dev) {
			if (!have_selftest && !access("/tmp/ex4-selftest.txt", R_OK)) { have_selftest = 1; mark("self-test report is present"); }
			if (!have_link) {
				DIR *d = opendir("/sys/class/net"); struct dirent *e; char p[PATH_MAX];
				while (d && (e = readdir(d))) {
					if (e->d_name[0] == '.' || !strcmp(e->d_name, "lo")) continue;
					snprintf(p, sizeof p, "/sys/class/net/%s/carrier", e->d_name);
					if (slurp(p, b, sizeof b) > 0 && b[0] == '1') { have_link = 1; mark("link is up on %s", e->d_name); break; }
				}
				if (d) closedir(d);
			}
			if (uptime() - last_alive >= 60) { last_alive = uptime(); mark("alive: seq %u, target %s", seq, tname); }
		}
		if (term) mark("SIGTERM (the system is shutting down or returning to stock): last snapshot");
		/* 3. a snapshot */
		if (fd >= 0) {
			seq++;
			n = build_payload(pay, run, gen, seq, tag, tname, payload_file, &flags, term);
			memcpy(h.run, run, 16); h.gen = gen; h.seq = seq; h.up = (uint32_t)uptime(); h.len = n; h.crc = crc32z(pay, n);
			h.slot = seq % NSLOTS; h.flags = flags; h.slot_size = SLOT_SIZE;
			if (write_slot(fd, &h, pay)) {
				mark("write of seq %u to %s FAILED: %s; dropping this target", seq, tname, strerror(errno));
				close(fd); fd = -1; nfail++; seq--;
				if (test_dev) return 2;
			} else if (seq == 1) {
				struct hdr v; int st = slot_check(fd, h.slot, &v, NULL);
				mark("first snapshot written to %s and read back: %s", tname, st == S_OK && v.seq == 1 ? "OK" : "DOES NOT VERIFY");
			}
		}
		if (once || term || (count && (long)seq >= count)) break;
		nap(test_interval >= 0 ? test_interval : fd < 0 ? 0.5 : uptime() < 300 ? 5 : 15);
	}
	if (fd >= 0) close(fd);
	return 0;
}

static int cmd_note(int argc, char **argv)
{
	FILE *f = fopen("/tmp/ex4-notes", "a"); char b[32]; int i;
	if (!f) return 2;
	fprintf(f, "[%9.2f]", uptime());
	for (i = 0; i < argc; i++) fprintf(f, " %s", argv[i]);
	fputc('\n', f); fclose(f);
	if (slurp("/tmp/ex4log.pid", b, sizeof b) > 0 && atoi(b) > 1) kill(atoi(b), SIGUSR1);
	return 0;
}

int main(int argc, char **argv)
{
	crc_init();
	if (argc >= 2 && !strcmp(argv[1], "read")) return cmd_read(argc - 2, argv + 2);
	if (argc >= 2 && !strcmp(argv[1], "daemon")) return cmd_daemon(argc - 2, argv + 2);
	if (argc >= 3 && !strcmp(argv[1], "note")) return cmd_note(argc - 2, argv + 2);
	fprintf(stderr, "usage: ex4log read DEV [--state] [--save FILE]      (read-only)\n"
			"       ex4log daemon [--min-sectors N] [--max-sectors N] [--tag T]   (trial side: WRITES the log region)\n"
			"       ex4log note TEXT...\n");
	return 64;
}
