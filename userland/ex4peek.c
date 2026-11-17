/* ex4peek.c : READ-ONLY probe for the WD My Cloud EX4 (Kirkwood 88F6282) under its stock 3.2.40 kernel.
 * There is no write path in this program: /dev/mem and /dev/mtd0 are opened O_RDONLY, the mapping is PROT_READ.
 *   ex4peek regs            MPP control, GPIO (out, out-enable, blink, polarity, data-in, irq masks), device id,
 *                           sample-at-reset, NAND timing, timer/watchdog control, RSTOUT mask.  None of these
 *                           registers has a read side effect.  (UART and TWSI registers are NOT read: reads there do.)
 *   ex4peek env             the U-Boot env block (mtd0 +0xa0000, 0x20000): empty / valid CRC (prints it) / bad CRC
 *   ex4peek gpiowatch SECS  poll GPIO data-in every 50 ms and print every bit that changes (press buttons meanwhile)
 *   ex4peek klog [--from HEX] [--to HEX] [--out FILE] [--mem FILE]
 *                           (v1) AFTER A WARM RESET back to stock (the trial's own reboot, or the watchdog): look through
 *                           RAM for what is left of the TRIAL kernel's log buffer and print it. A reset does not clear
 *                           RAM; U-Boot and the stock kernel only overwrite what they use. The Linux 6.x log buffer is a
 *                           chain of blocks { 4-byte id, text } with ids counting up. The scan looks for a block whose
 *                           text starts with "Booting Linux on physical CPU 0x", "Linux version 6." or "ex4log: " and
 *                           that is linked to at least two more blocks; the stock 3.2 kernel's own log and plain text
 *                           files do not have that shape. A wrapped or partly overwritten ring comes out as several
 *                           chains in id order. No ramoops is involved: the OpenWrt 25.12.6 kirkwood kernel has no
 *                           pstore/ramoops driver built in. Reads /dev/mem with read() (RAM only, O_RDONLY). Useless
 *                           after a power cycle. Run it EARLY after stock is back: the longer stock runs, the more
 *                           of the old RAM it reuses. --out FILE saves the text, FILE.raw the bytes (never overwrites).
 *   ex4peek marker [--run ID --at POS:HEXADDR[,POS:HEXADDR...] --total N] [--scan] [--from HEX] [--to HEX] [--mem FILE]
 *                           (v2) RAM markers. A marker is one 4096-byte block that ex4boot's stub copies to a fixed
 *                           physical address as one more segment (written by build/ex4img.py `marker`): magic
 *                           "EX4MARK1", the run id, its position among the run's markers, the address it was meant
 *                           for, and a pattern made from those. Everything in it follows from (run id, position,
 *                           total, address), so this reader rebuilds the expected block and compares bit by bit:
 *                           no file is read.  --at reads the given addresses: INTACT / DAMAGED (how many bits) /
 *                           OTHER (a whole marker of another run) / ABSENT.  --scan looks at every 4 KiB step of
 *                           RAM for the magic and reports every marker it finds, whatever its run (a copy that is
 *                           not at its own address is a file copy in the page cache or tmpfs, or one of ex4boot's
 *                           source pages).  Exit 0 = every --at marker INTACT (or, with --scan alone, something
 *                           found), 4 = some, 3 = none.  Reads /dev/mem with pread, O_RDONLY.
 * Build: arm-linux-gnueabi-gcc -static -Os -march=armv5te -Wl,-z,max-page-size=0x8000 -o ex4peek ex4peek.c
 * Born Nov 16 2026. SPDX-License-Identifier: GPL-2.0-or-later. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <time.h>

#define REGBASE 0xf1000000UL
#define MAPLEN  0x30000UL              /* 0xf1000000..0xf102ffff, a multiple of the 32 KiB page */
static volatile uint32_t *regs;
static uint32_t rd(unsigned long off) { return regs[off / 4]; }

static int map_regs(void)
{
	int fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (fd < 0) { perror("open /dev/mem (read-only)"); return -1; }
	void *p = mmap(NULL, MAPLEN, PROT_READ, MAP_SHARED, fd, REGBASE);
	if (p == MAP_FAILED) { perror("mmap"); return -1; }
	regs = p; return 0;
}

static const struct { unsigned long off; const char *name; } R[] = {
	{0x10000, "MPP_CTRL0 (mpp0-7)"}, {0x10004, "MPP_CTRL1 (mpp8-15)"}, {0x10008, "MPP_CTRL2 (mpp16-23)"},
	{0x1000c, "MPP_CTRL3 (mpp24-31)"}, {0x10010, "MPP_CTRL4 (mpp32-39)"}, {0x10014, "MPP_CTRL5 (mpp40-47)"},
	{0x10018, "MPP_CTRL6 (mpp48-49)"}, {0x10030, "SAMPLE_AT_RESET"}, {0x10034, "DEVICE_ID"},
	{0x10100, "GPIO_LO data-out"}, {0x10104, "GPIO_LO out-enable(0=output)"}, {0x10108, "GPIO_LO blink-en"},
	{0x1010c, "GPIO_LO in-polarity"}, {0x10110, "GPIO_LO data-in"}, {0x10118, "GPIO_LO irq-mask"}, {0x1011c, "GPIO_LO lvl-mask"},
	{0x10140, "GPIO_HI data-out"}, {0x10144, "GPIO_HI out-enable(0=output)"}, {0x10148, "GPIO_HI blink-en"},
	{0x1014c, "GPIO_HI in-polarity"}, {0x10150, "GPIO_HI data-in"}, {0x10158, "GPIO_HI irq-mask"}, {0x1015c, "GPIO_HI lvl-mask"},
	{0x10418, "NAND_READ_PARAMS"}, {0x1041c, "NAND_WRITE_PARAMS"}, {0x10470, "NAND_FLASH_CTRL"},
	{0x20108, "RSTOUTn_MASK (bit1=WD reset out)"}, {0x20300, "TIMER_CTRL (bit4=WD enable)"}, {0x20324, "WD_TIMER value"},
	{0x20100, "CPU_CONFIG"}, {0x20104, "CPU_CTRL_STAT"}, {0x20128, "L2_CONFIG"},
};

static int cmd_regs(void)
{
	unsigned i;
	if (map_regs()) return 1;
	for (i = 0; i < sizeof R / sizeof R[0]; i++)
		printf("0x%08lx = 0x%08x  %s\n", REGBASE + R[i].off, rd(R[i].off), R[i].name);
	/* decode: per-pin function + direction + level */
	for (i = 0; i < 50; i++) {
		uint32_t sel = (rd(0x10000 + 4 * (i / 8)) >> (4 * (i % 8))) & 0xf;
		unsigned long b = i < 32 ? 0x10100 : 0x10140; unsigned bit = i % 32;
		printf("mpp%-2u sel=%x%s", i, sel, sel ? "\n" : "");
		if (!sel) printf(" GPIO %s out=%u in=%u pol=%u blink=%u irqmask=%u\n",
			(rd(b + 4) >> bit) & 1 ? "INPUT " : "OUTPUT", (rd(b) >> bit) & 1, (rd(b + 0x10) >> bit) & 1,
			(rd(b + 0xc) >> bit) & 1, (rd(b + 8) >> bit) & 1, ((rd(b + 0x18) | rd(b + 0x1c)) >> bit) & 1);
	}
	return 0;
}

static uint32_t crc32_le(const unsigned char *p, size_t n)
{
	uint32_t c = 0xffffffff; size_t i; int k;
	for (i = 0; i < n; i++) { c ^= p[i]; for (k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320 & -(c & 1)); }
	return ~c;
}

static int cmd_env(void)
{
	enum { OFF = 0xa0000, LEN = 0x20000 };
	static unsigned char buf[LEN];
	int fd = open("/dev/mtd0", O_RDONLY); size_t got = 0, i, ff = 0;
	if (fd < 0) { perror("open /dev/mtd0 (read-only)"); return 1; }
	if (lseek(fd, OFF, SEEK_SET) != OFF) { perror("lseek"); return 1; }
	while (got < LEN) { ssize_t r = read(fd, buf + got, LEN - got); if (r <= 0) { perror("read"); return 1; } got += r; }
	for (i = 0; i < LEN; i++) ff += buf[i] == 0xff;
	uint32_t stored = buf[0] | buf[1] << 8 | buf[2] << 16 | (uint32_t)buf[3] << 24, calc = crc32_le(buf + 4, LEN - 4);
	printf("env block /dev/mtd0 +0x%x len 0x%x: stored crc %08x, computed %08x, 0xff bytes %lu/%u\n",
	       OFF, LEN, stored, calc, (unsigned long)ff, LEN);
	if (ff == LEN) { puts("STATE: EMPTY (erased). U-Boot uses its compiled default environment."); return 0; }
	if (stored != calc) { puts("STATE: BAD CRC (U-Boot would use its compiled default environment)."); return 2; }
	puts("STATE: VALID saved environment:");
	for (i = 4; i < LEN && buf[i]; i += strlen((char *)buf + i) + 1) printf("  %s\n", buf + i);
	return 0;
}

static int cmd_watch(int secs)
{
	if (map_regs()) return 1;
	uint32_t lo = rd(0x10110), hi = rd(0x10150); int n = secs * 20, i;
	printf("start: lo=%08x hi=%08x ; watching %d s\n", lo, hi, secs); fflush(stdout);
	for (i = 0; i < n; i++) {
		struct timespec ts = {0, 50 * 1000 * 1000}; nanosleep(&ts, NULL);
		uint32_t l = rd(0x10110), h = rd(0x10150), d; int b;
		for (d = l ^ lo, b = 0; b < 32; b++) if (d >> b & 1) printf("t=%.2fs gpio%d -> %u\n", i / 20.0, b, l >> b & 1);
		for (d = h ^ hi, b = 0; b < 32; b++) if (d >> b & 1) printf("t=%.2fs gpio%d -> %u\n", i / 20.0, 32 + b, h >> b & 1);
		if (l != lo || h != hi) fflush(stdout);
		lo = l; hi = h;
	}
	return 0;
}

/* ---- klog: the trial kernel's printk ring, found in RAM after a warm reset ----
 * The text ring is a run of blocks { u32 id, text }, each padded to 4 bytes, ids counting up by one (a record with
 * no text has no block, so small jumps happen). Nothing in a block says how long it is: the next block is found by
 * its id. When the ring wraps, the newest blocks sit at its start and the oldest surviving ones after them, so one
 * ring can show up as two chains; they are printed in id order with the gap named. */
#define KWIN    (2u << 20)                    /* the window searched around an anchor: 1 MiB each side */
#define KCHUNK  (1u << 20)
#define KMAXREC 1100                          /* a record's text is at most 1024 bytes */
static const char *const KANCHOR[] = { "Booting Linux on physical CPU 0x", "Linux version 6.", "ex4log: " };
static uint32_t le32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static int ktext(unsigned char c) { return c == '\n' || c == '\t' || c == 27 || (c >= 32 && c < 127); }
/* A block id is a 30-bit counter: 0x3fffxxxx early in a boot (it starts a little below 2^30), small numbers once it
 * has passed 2^30. So the top byte is at most 0x3f and the third byte (0xff, or 0x00..0x08 for the first half million
 * records after the wrap) is never a text character. Without this test ordinary data passes for a chain: "\tfoo" and
 * "\nfoo" read as ids one apart, and so do neighbours in a sorted string table (both seen in a real RAM dump). */
static int kid(const unsigned char *p) { return p[3] <= 0x3f && !ktext(p[2]); }

/* What a block looks like in a real dump (qemu, Linux 6.12.112, Nov 16 2026):
 *   b2 fe ff 3f "ata1.00: ... (depth 32)" "2)" "\n" 00 00 | b3 fe ff 3f "ata1.00: LPM ..."
 * id, the text, then leftovers of how printk built it (kernel lines: the last two characters once more, because the
 * 2-byte level prefix was cut off the front by moving the text down; then the newline it dropped), a NUL, padding to
 * 4 bytes, the next id. So: the text ends at the first byte that is not text, and the next id sits at the next
 * 4-byte step within a few bytes of it. */
static size_t ktend(const unsigned char *w, size_t wlen, size_t s)
{
	size_t i = s;
	while (i < wlen && i < s + 1024 && ktext(w[i])) i++;
	return i;
}

static long knext(const unsigned char *w, size_t wlen, size_t cur, uint32_t id, uint32_t *nid)
{
	size_t i = ktend(w, wlen, cur + 4), o;
	if (i == cur + 4) return -1;                                /* a block with no text is not one */
	for (o = cur + (((i + 1 - cur) + 3) & ~(size_t)3); o <= i + 8 && o + 4 <= wlen; o += 4) {
		uint32_t v = le32(w + o);
		if (v - id >= 1 && v - id <= 8 && kid(w + o)) { *nid = v; return (long)o; }
	}
	return -1;
}

/* is the block at cur the successor of one before it? (the cheap test that throws out anchors found in ordinary text) */
static int kprev(const unsigned char *w, size_t wlen, size_t cur, uint32_t id)
{
	size_t o, lowest = cur > KMAXREC ? cur - KMAXREC : 0; uint32_t nid;
	for (o = cur; o >= lowest + 8 && o >= 8; ) {
		o -= 4;
		if (o + 8 > cur || !kid(w + o) || id - le32(w + o) < 1 || id - le32(w + o) > 8) continue;
		if (knext(w, wlen, o, le32(w + o), &nid) == (long)cur) return 1;
	}
	return 0;
}

struct kchain { size_t start, last; uint32_t first, lastid; unsigned n; };

static int kchain_at(const unsigned char *w, size_t wlen, size_t o, struct kchain *c)   /* 3 linked blocks or it is not one */
{
	uint32_t id, nid; long nx; size_t cur = o;
	if (o + 12 > wlen || !kid(w + o) || !ktext(w[o + 4]) || !ktext(w[o + 5]) || !ktext(w[o + 6]) || !ktext(w[o + 7])) return 0;
	id = le32(w + o); c->start = o; c->first = id; c->n = 1;
	while ((nx = knext(w, wlen, cur, id, &nid)) >= 0) { cur = (size_t)nx; id = nid; c->n++; }
	c->last = cur; c->lastid = id;
	return c->n >= 3;
}

static int kcmp(const void *a, const void *b)                /* ids are 30-bit counters that wrap; compare as a ring */
{
	uint32_t x = ((const struct kchain *)a)->first, y = ((const struct kchain *)b)->first;
	return x == y ? 0 : ((int32_t)((x - y) << 2) < 0 ? -1 : 1);
}

/* droplast: when a block does not fit at the end of the ring the kernel puts it at the start and leaves only its id
 * at the end, in front of whatever old text was there. That stub shows up as a chain's last block with the same id
 * as the first block of the next chain: its "text" belongs to an older record and is not printed. */
static unsigned long kprint(const unsigned char *w, size_t wlen, const struct kchain *c, uint32_t base, FILE *out, int droplast)
{
	size_t cur = c->start; uint32_t id = c->first, nid; unsigned long n = 0;
	for (;;) {
		long nx = knext(w, wlen, cur, id, &nid); size_t s = cur + 4, e = ktend(w, wlen, s);
		if (e > s && w[e - 1] == '\n') e--;
		if (e >= s + 4 && w[e - 1] == w[e - 3] && w[e - 2] == w[e - 4]) e -= 2;   /* the doubled last two characters (see above) */
		if (e > s && !(nx < 0 && droplast)) {
			printf("%6u  ", (unsigned)((id - base) & 0x3fffffff)); fwrite(w + s, 1, e - s, stdout); putchar('\n');
			if (out) { fwrite(w + s, 1, e - s, out); fputc('\n', out); }
			n++;
		}
		if (nx < 0) break;
		cur = (size_t)nx; id = nid;
	}
	return n;
}

/* idpos = physical address of a block id whose text starts with an anchor. Returns the end of the window handled, 0 if not a ring. */
static unsigned long long klog_window(int fd, unsigned long long idpos, unsigned long long from, unsigned long long to, FILE *out, const char *outname)
{
	static unsigned char w[KWIN]; static struct kchain all[256]; struct kchain *ch; uint32_t nid;
	unsigned long long base; size_t wlen, got = 0, o, ao, lo, hi; int nall = 0, nch, i, anchor = -1, first, last; unsigned long recs = 0;
	base = idpos > from + KWIN / 2 ? idpos - KWIN / 2 : from + ((idpos - from) & 3);     /* keeps the 4-byte phase of idpos */
	wlen = to - base < KWIN ? (size_t)(to - base) : KWIN;
	while (got < wlen) { ssize_t r = pread(fd, w + got, wlen - got, (off_t)(base + got)); if (r <= 0) break; got += r; }
	wlen = got;
	ao = (size_t)(idpos - base);
	if (ao + 12 > wlen || !kid(w + ao)) return 0;
	if (knext(w, wlen, ao, le32(w + ao), &nid) < 0 && !kprev(w, wlen, ao, le32(w + ao))) return 0;      /* cheap: no neighbour, not a ring */
	for (o = ao & 3; o + 12 <= wlen && nall < 256; o += 4)
		if (kchain_at(w, wlen, o, &all[nall])) {
			if (all[nall].start <= ao && ao <= all[nall].last) anchor = nall;
			o = all[nall].last; nall++;
		}
	if (anchor < 0) return 0;                               /* the anchor is not inside a chain of 3 or more: not a ring */
	/* The ring is ONE array: its chains lie a record or two apart (a block the scan could not link, the leftover at
	 * the wrap point). Other things in a kernel's data look like chains too (tables of numbered names), but they
	 * are not next door. Keep the anchor's chain and the neighbours within 5 KiB of each other. */
	for (first = anchor; first > 0 && all[first].start - all[first - 1].last <= 5120; first--) ;
	for (last = anchor; last + 1 < nall && all[last + 1].start - all[last].last <= 5120; last++) ;
	ch = &all[first]; nch = last - first + 1; lo = ch[0].start; hi = ch[nch - 1].last;
	qsort(ch, nch, sizeof ch[0], kcmp);
	printf("ex4peek klog: a Linux 6.x log buffer at physical 0x%08llx..0x%08llx, %d chain(s)%s\n", base + lo, base + hi, nch,
	       nch > 1 ? " (the ring wrapped, or stock has overwritten parts of it)" : "");
	for (i = 0; i < nch; i++) {
		int stub = i + 1 < nch && ch[i + 1].first == ch[i].lastid;
		if (i && ch[i].first != ch[i - 1].lastid && ((ch[i].first - ch[i - 1].lastid - 1) & 0x3fffffff)) {
			printf("        [... gap: %u record ids missing between the chains ...]\n", (unsigned)((ch[i].first - ch[i - 1].lastid - 1) & 0x3fffffff));
			if (out) fprintf(out, "[... gap: %u record ids missing ...]\n", (unsigned)((ch[i].first - ch[i - 1].lastid - 1) & 0x3fffffff));
		}
		recs += kprint(w, wlen, &ch[i], ch[0].first, out, stub);
	}
	printf("ex4peek klog: %lu records. First column = the record id counted from the oldest one found. Time stamps live in another table and are not recovered. "
	       "Kernel lines are stored with their last two characters doubled; a doubled ending is cut here, so a line that really ends in a doubled pair loses two characters (the .raw file has the bytes as found).\n", recs);
	if (outname) {
		char rn[512]; int fo; size_t keep = hi + 2048 < wlen ? hi + 2048 : wlen;
		snprintf(rn, sizeof rn, "%s.raw", outname);
		fo = open(rn, O_WRONLY | O_CREAT | O_EXCL, 0644);
		if (fo >= 0) { if (write(fo, w + lo, keep - lo) != (ssize_t)(keep - lo)) perror("write .raw"); close(fo); printf("ex4peek klog: raw bytes 0x%08llx..0x%08llx saved to %s\n", base + lo, base + keep, rn); }
		else perror(rn);
	}
	return base + wlen;
}

static int cmd_klog(int argc, char **argv)
{
	const char *mem = "/dev/mem", *outname = NULL; unsigned long long from = 0x00100000ULL, to = 0x20000000ULL, pos, done_to = 0; int i, fd, found = 0;
	static unsigned char buf[KCHUNK + 64]; FILE *out = NULL; size_t carry = 0;   /* RAM ends below 2 GiB: a 32-bit off_t is enough */
	for (i = 0; i < argc; i++) {
		if (!strcmp(argv[i], "--mem") && i + 1 < argc) mem = argv[++i];
		else if (!strcmp(argv[i], "--from") && i + 1 < argc) from = strtoull(argv[++i], NULL, 16);
		else if (!strcmp(argv[i], "--to") && i + 1 < argc) to = strtoull(argv[++i], NULL, 16);
		else if (!strcmp(argv[i], "--out") && i + 1 < argc) outname = argv[++i];
		else { fprintf(stderr, "ex4peek klog: unknown option %s\n", argv[i]); return 64; }
	}
	if (from >= to || to > 0x7fffffffULL) { fprintf(stderr, "ex4peek klog: bad range\n"); return 64; }
	fd = open(mem, O_RDONLY);
	if (fd < 0) { perror("open memory (read-only)"); return 1; }
	if (outname) {
		int o = open(outname, O_WRONLY | O_CREAT | O_EXCL, 0644);
		if (o < 0 || !(out = fdopen(o, "w"))) { perror(outname); return 1; }
	}
	printf("ex4peek klog: scanning %s 0x%08llx..0x%08llx for a Linux 6.x log buffer (read-only)\n", mem, from, to);
	for (pos = from; pos < to; ) {
		size_t want = to - pos < KCHUNK ? (size_t)(to - pos) : KCHUNK, got = 0, k, total; unsigned a;
		while (got < want) { ssize_t r = pread(fd, buf + carry + got, want - got, (off_t)(pos + got)); if (r <= 0) break; got += r; }
		if (!got) { printf("ex4peek klog: read stopped at 0x%08llx\n", pos); break; }
		total = carry + got;
		for (k = 0; k < total; k++) {
			unsigned long long at = pos - carry + k, end;          /* physical address of this byte */
			if (buf[k] != 'B' && buf[k] != 'L' && buf[k] != 'e') continue;
			if (at < done_to || at < from + 4) continue;
			for (a = 0; a < sizeof KANCHOR / sizeof KANCHOR[0]; a++) {
				size_t al = strlen(KANCHOR[a]);
				if (k + al > total || memcmp(buf + k, KANCHOR[a], al)) continue;
				end = klog_window(fd, at - 4, from, to, out, found ? NULL : outname);
				if (end) { found++; done_to = end; }
				break;
			}
		}
		carry = total < 40 ? total : 40;                  /* longer than any anchor: one split across two reads is still seen */
		memmove(buf, buf + total - carry, carry);
		pos += got;
	}
	if (out) fclose(out);
	if (!found) puts("ex4peek klog: RESULT: no Linux 6.x log buffer found in RAM (power was cycled, or the trial kernel never printed, or stock has reused that memory).");
	else printf("ex4peek klog: RESULT: %d log buffer(s) found.\n", found);
	return found ? 0 : 3;
}

/* ---- marker: the block ex4boot's stub leaves at a fixed physical address (v2) ----
 * Layout (little-endian), 4096 bytes:
 *   0x000 "EX4MARK1"   0x008 version (1)   0x00c pos   0x010 total   0x014 dest   0x018 seed   0x01c header crc32
 *   0x020 run id, 64 bytes, NUL padded      0x060..0x0ff zero       0x100..0xfff 960 words of xorshift32(seed)
 *   seed = crc32(run id bytes + pos + total + dest as three LE words) | 1
 *   header crc32 = crc32 of bytes 0x000..0x01b followed by bytes 0x020..0x05f
 * build/ex4img.py `marker` writes the same thing; tests/trial-logic.sh and tests/qemu-handoff.sh check one against the other. */
#define MK_LEN 4096
#define MK_BITS (MK_LEN * 8)
static void put32(unsigned char *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

static int mk_build(unsigned char *b, const char *run, uint32_t pos, uint32_t total, uint32_t dest)
{
	unsigned char t[64 + 12], h[0x1c + 64]; size_t rl = strlen(run); uint32_t seed, x; int i;
	if (!rl || rl > 63) return -1;
	memcpy(t, run, rl); put32(t + rl, pos); put32(t + rl + 4, total); put32(t + rl + 8, dest);
	seed = crc32_le(t, rl + 12) | 1;
	memset(b, 0, MK_LEN);
	memcpy(b, "EX4MARK1", 8); put32(b + 8, 1); put32(b + 0xc, pos); put32(b + 0x10, total); put32(b + 0x14, dest); put32(b + 0x18, seed);
	memcpy(b + 0x20, run, rl);
	memcpy(h, b, 0x1c); memcpy(h + 0x1c, b + 0x20, 64);
	put32(b + 0x1c, crc32_le(h, sizeof h));
	for (x = seed, i = 0x100; i < MK_LEN; i += 4) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; put32(b + i, x); }
	return 0;
}

/* a whole, self-consistent marker of ANY run in b? fills run/pos/total/dest */
static int mk_parse(const unsigned char *b, char *run, uint32_t *pos, uint32_t *total, uint32_t *dest)
{
	unsigned char e[MK_LEN]; int i;
	if (memcmp(b, "EX4MARK1", 8) || le32(b + 8) != 1 || b[0x20 + 63]) return 0;
	for (i = 0; i < 63 && b[0x20 + i]; i++) if (b[0x20 + i] < 33 || b[0x20 + i] > 126) return 0;
	if (!i) return 0;
	memcpy(run, b + 0x20, 64); *pos = le32(b + 0xc); *total = le32(b + 0x10); *dest = le32(b + 0x14);
	if (mk_build(e, run, *pos, *total, *dest)) return 0;
	return memcmp(e, b, MK_LEN) ? 1 : 2;                       /* 1 = header reads as a marker but bytes differ, 2 = whole */
}

static unsigned mk_bitdiff(const unsigned char *a, const unsigned char *b)
{
	unsigned n = 0; int i;
	for (i = 0; i < MK_LEN; i++) { unsigned char x = a[i] ^ b[i]; while (x) { n += x & 1; x >>= 1; } }
	return n;
}

static int mk_read(int fd, unsigned long long at, unsigned char *b)
{
	size_t got = 0;
	while (got < MK_LEN) { ssize_t r = pread(fd, b + got, MK_LEN - got, (off_t)(at + got)); if (r <= 0) return -1; got += r; }
	return 0;
}

static int cmd_marker(int argc, char **argv)
{
	const char *mem = "/dev/mem", *run = NULL, *atlist = NULL; unsigned long long from = 0, to = 0x20000000ULL, a; uint32_t total = 0;
	int i, fd, scan = 0, nat = 0, intact = 0, damaged = 0, other = 0, absent = 0, found = 0, found_dest = 0;
	static unsigned char b[MK_LEN], e[MK_LEN], chunk[1 << 20]; unsigned long long atv[16]; uint32_t atp[16];
	for (i = 0; i < argc; i++) {
		if (!strcmp(argv[i], "--mem") && i + 1 < argc) mem = argv[++i];
		else if (!strcmp(argv[i], "--run") && i + 1 < argc) run = argv[++i];
		else if (!strcmp(argv[i], "--at") && i + 1 < argc) atlist = argv[++i];
		else if (!strcmp(argv[i], "--total") && i + 1 < argc) total = strtoul(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--from") && i + 1 < argc) from = strtoull(argv[++i], NULL, 16);
		else if (!strcmp(argv[i], "--to") && i + 1 < argc) to = strtoull(argv[++i], NULL, 16);
		else if (!strcmp(argv[i], "--scan")) scan = 1;
		else { fprintf(stderr, "ex4peek marker: unknown option %s\n", argv[i]); return 64; }
	}
	if (atlist) {
		char *dup = strdup(atlist), *tok, *sv = dup;
		if (!run || !total) { fprintf(stderr, "ex4peek marker: --at needs --run ID and --total N\n"); return 64; }
		while ((tok = strsep(&sv, ",")) != NULL) {
			char *c = strchr(tok, ':');
			if (!c || nat >= 16) { fprintf(stderr, "ex4peek marker: --at wants POS:HEXADDR[,POS:HEXADDR...]\n"); return 64; }
			atp[nat] = strtoul(tok, NULL, 10); atv[nat] = strtoull(c + 1, NULL, 16); nat++;
		}
	}
	if (!nat && !scan) { fprintf(stderr, "ex4peek marker: nothing to do (--at and/or --scan)\n"); return 64; }
	if (from >= to || to > 0x7fffffffULL || (from & 0xfff)) { fprintf(stderr, "ex4peek marker: bad range\n"); return 64; }
	fd = open(mem, O_RDONLY);
	if (fd < 0) { perror("open memory (read-only)"); return 1; }
	for (i = 0; i < nat; i++) {
		char r2[64]; uint32_t p2, t2, d2; unsigned nd; int k;
		if (mk_build(e, run, atp[i], total, (uint32_t)atv[i])) { fprintf(stderr, "ex4peek marker: bad run id\n"); return 64; }
		if (mk_read(fd, atv[i], b)) { printf("MARKER pos=%u at=0x%08llx run=%s state=UNREADABLE\n", atp[i], atv[i], run); absent++; continue; }
		nd = mk_bitdiff(b, e); k = mk_parse(b, r2, &p2, &t2, &d2);
		if (!nd) { printf("MARKER pos=%u at=0x%08llx run=%s state=INTACT bits_wrong=0/%d\n", atp[i], atv[i], run, MK_BITS); intact++; }
		else if (k == 2) { printf("MARKER pos=%u at=0x%08llx run=%s state=OTHER (a whole marker of run %s pos %u/%u meant for 0x%08x sits here)\n", atp[i], atv[i], run, r2, p2, t2, d2); other++; }
		else if (nd < MK_BITS / 4) { printf("MARKER pos=%u at=0x%08llx run=%s state=DAMAGED bits_wrong=%u/%d (the marker was here; RAM lost or changed part of it)\n", atp[i], atv[i], run, nd, MK_BITS); damaged++; }
		else { printf("MARKER pos=%u at=0x%08llx run=%s state=ABSENT bits_wrong=%u/%d (about half = unrelated bytes)\n", atp[i], atv[i], run, nd, MK_BITS); absent++; }
	}
	if (scan) {
		printf("ex4peek marker: scanning %s 0x%08llx..0x%08llx at every 4 KiB step (read-only)\n", mem, from, to);
		for (a = from; a < to; ) {
			size_t want = to - a < sizeof chunk ? (size_t)(to - a) : sizeof chunk, got = 0, k;
			while (got < want) { ssize_t r = pread(fd, chunk + got, want - got, (off_t)(a + got)); if (r <= 0) break; got += r; }
			if (!got) { printf("ex4peek marker: read stopped at 0x%08llx\n", a); break; }
			for (k = 0; k + MK_LEN <= got; k += MK_LEN) {
				char r2[64]; uint32_t p2, t2, d2; int st;
				if (memcmp(chunk + k, "EX4MARK1", 8)) continue;
				st = mk_parse(chunk + k, r2, &p2, &t2, &d2);
				if (!st) { printf("FOUND at=0x%08llx state=MAGIC-ONLY (the 8 magic bytes, no readable header)\n", a + k); continue; }
				printf("FOUND at=0x%08llx run=%s pos=%u/%u dest=0x%08x state=%s where=%s\n", a + k, r2, p2, t2, d2,
				       st == 2 ? "INTACT" : "DAMAGED", a + k == d2 ? "dest" : "elsewhere");
				found++; if (a + k == d2) found_dest++;
			}
			a += got;
			if (got & 0xfff) break;
		}
	}
	printf("ex4peek marker: RESULT: asked=%d intact=%d damaged=%d other=%d absent=%d", nat, intact, damaged, other, absent);
	if (scan) printf(" scan_found=%d scan_at_dest=%d", found, found_dest);
	putchar('\n');
	if (nat) return intact == nat ? 0 : (intact || damaged ? 4 : 3);
	return found ? 0 : 3;
}

int main(int argc, char **argv)
{
	if (argc >= 2 && !strcmp(argv[1], "regs")) return cmd_regs();
	if (argc >= 2 && !strcmp(argv[1], "env")) return cmd_env();
	if (argc >= 3 && !strcmp(argv[1], "gpiowatch")) return cmd_watch(atoi(argv[2]));
	if (argc >= 2 && !strcmp(argv[1], "klog")) return cmd_klog(argc - 2, argv + 2);
	if (argc >= 2 && !strcmp(argv[1], "marker")) return cmd_marker(argc - 2, argv + 2);
	fprintf(stderr, "usage: ex4peek regs | env | gpiowatch SECS | klog [--from HEX] [--to HEX] [--out FILE] | marker [--run ID --total N --at POS:HEX,...] [--scan]   (read-only; see the source header)\n");
	return 64;
}
