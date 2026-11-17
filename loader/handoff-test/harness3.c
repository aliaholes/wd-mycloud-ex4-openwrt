/* SPDX-License-Identifier: GPL-2.0-or-later */
/* handoff3 harness: the "old kernel" side of an ex4boot jump, on qemu's versatilepb (ARM926), for bundle-v3.
 * It takes the bundle's REAL segment files (incbin, in SEGS order, at their SEGS addresses), scatters them into
 * 32 KiB source pages outside every destination the way ex4boot.ko does (file order, one entry per page), builds
 * the same ctl block, copies the REAL stub (loader/ex4boot_stub.S, built with -DEX4_L2OFF like the module of
 * run 4b) into its own page and calls it: r0 = 0, r1 = 527, r2 = 0x100, entry 0x8000. What starts then is the
 * bundle's real kernel.bin (OpenWrt's 6.12 zImage + the EX4 DTB) with the bundle's real ATAG list and overlay.
 * qemu has no Kirkwood: this proves the copy, the decompressor, the ATAG -> DTB merge and the first kernel lines on
 * an ARMv5 CPU, nothing about the EX4's hardware (and qemu takes the Feroceon L2 opcodes as no-ops).
 * GPL-2.0-or-later. Born Nov 16 2026 (EX4 run 5 prep). */
typedef unsigned int u32;
static inline void putc_(char c) { *(volatile u32 *)0x101f1000 = c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void hex_(u32 v) { int i; for (i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]); }
extern const unsigned char ex4boot_stub[], ex4boot_stub_end[];
extern const unsigned char seg0[], seg0_end[], seg1[], seg1_end[], seg2[], seg2_end[], seg3[], seg3_end[], seg4[], seg4_end[], seg5[], seg5_end[];
extern const u32 seg_dest[6];
struct ent { u32 dest, src, len; };
struct ctl { u32 entry, r1, r2, pad; struct ent e[1]; };
#define PG 0x8000
#define CTL_OFF 1024
#define SRC_TOP   0x0f000000u           /* source pages are handed out downward from here (above every destination) */
#define STUB_PAGE 0x0f100000u
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
	unsigned char *stubpg = (unsigned char *)STUB_PAGE;
	struct ctl *ctl = (struct ctl *)(stubpg + CTL_OFF);
	struct ent *e = ctl->e;
	const unsigned char *s[6] = { seg0, seg1, seg2, seg3, seg4, seg5 }, *t[6] = { seg0_end, seg1_end, seg2_end, seg3_end, seg4_end, seg5_end };
	int i;
	puts_("HARNESS3: building chunks\n");
	cpy(stubpg, ex4boot_stub, ex4boot_stub_end - ex4boot_stub);
	ctl->entry = 0x8000; ctl->r1 = 527; ctl->r2 = 0x100;
	for (i = 0; i < 6; i++) {
		puts_("  seg"); putc_('0' + i); puts_(" dest="); hex_(seg_dest[i]); puts_(" len="); hex_(t[i] - s[i]); puts_("\n");
		e = add(e, seg_dest[i], s[i], t[i] - s[i]);
	}
	e->dest = e->src = e->len = 0;
	puts_("HARNESS3: chunks="); hex_(e - ctl->e); puts_(" lowest source page="); hex_(next_src); puts_(" -> calling the stub (r1=527 r2=0x100 entry=0x8000)\n");
	((void (*)(u32))stubpg)((u32)ctl);
	puts_("RESULT: FAIL (stub returned)\n");
	for (;;) ;
}
