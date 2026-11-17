/* SPDX-License-Identifier: GPL-2.0-or-later */
/* the "old kernel" side: scatters the target + a data blob + the info block into 32 KiB source pages placed
 * OUTSIDE the destinations (in reverse order, to catch ordering bugs), builds the same ctl block ex4boot.ko builds,
 * copies the REAL stub (ex4boot_stub.S, the same object source) into its own page and calls it. */
#include "common.h"
extern const unsigned char ex4boot_stub[], ex4boot_stub_end[], target_bin[], target_bin_end[];
struct ent { u32 dest, src, len; };
struct ctl { u32 entry, r1, r2, pad; struct ent e[1]; };
#define PG 0x8000
#define CTL_OFF 1024
#define DATA_DEST 0x04000000u
#define DATA_LEN  (3 * 1024 * 1024 + 4444)
#define SRC_TOP   0x0a000000u           /* source pages are handed out downward from here */
static u32 next_src = SRC_TOP;
static void cpy(unsigned char *d, const unsigned char *s, u32 n) { while (n--) *d++ = *s++; }
static struct ent *add(struct ent *e, u32 dest, const unsigned char *src, u32 len)
{
	u32 off = 0;
	while (off < len) {
		u32 n = len - off > PG ? PG : len - off, i;
		next_src -= PG;
		for (i = 0; i < PG; i++) ((unsigned char *)next_src)[i] = 0;
		cpy((unsigned char *)next_src, src + off, n);
		e->dest = dest + off; e->src = next_src; e->len = (n + 3) & ~3u; e++;
		off += n;
	}
	return e;
}
void hmain(void)
{
	unsigned char *stubpg = (unsigned char *)0x0b000000;
	struct ctl *ctl = (struct ctl *)(stubpg + CTL_OFF);
	struct ent *e = ctl->e;
	unsigned char *gen = (unsigned char *)0x0c000000;   /* scratch: the data blob before scattering */
	static u32 info[4];
	u32 i, x = 0x12345678, tlen = target_bin_end - target_bin;
	puts_("HARNESS: building chunks\n");
	for (i = 0; i < DATA_LEN; i++) { x = x * 1664525u + 1013904223u; gen[i] = x >> 24; }
	info[0] = 0x45583421; info[1] = DATA_DEST; info[2] = DATA_LEN; info[3] = crc32_(gen, DATA_LEN);
	cpy(stubpg, ex4boot_stub, ex4boot_stub_end - ex4boot_stub);
	ctl->entry = 0x8000; ctl->r1 = 3035; ctl->r2 = 0x100;
	e = add(e, DATA_DEST, gen, DATA_LEN);
	e = add(e, 0x100, (unsigned char *)info, sizeof info);
	e = add(e, 0x8000, target_bin, tlen);
	e->dest = e->src = e->len = 0;
	puts_("HARNESS: target len="); hex_(tlen); puts_(" chunks="); hex_(e - ctl->e); puts_(" -> calling stub\n");
	((void (*)(u32))stubpg)((u32)ctl);
	puts_("RESULT: FAIL (stub returned)\n");
	for (;;) ;
}
