/*
 * ex4boot.ko : a minimal "load segments and jump" (kexec-like) module for the WD My Cloud EX4's STOCK kernel
 * (Marvell LSP 3.2.40, Feroceon 88FR131 ARMv5TE, 32 KiB software pages, CONFIG_KEXEC off, modules on).
 *
 * It never touches flash. It reads files into RAM, and only when told "boot" does it shut devices down the way a
 * reboot does, turn the MMU off and jump into the new kernel. A bad kernel = pull the plug; the stock system is
 * still on the NAND, untouched.
 *
 *   insmod ex4boot.ko segs="/path/zImage@0x8000,/path/atags.bin@0x100,/path/initrd@0x4000000" \
 *          entry=0x8000 r2=0x100 [r1=<machine id>] \
 *          a_setup_mm=0x<setup_mm_for_reboot> a_restart_prepare=0x<kernel_restart_prepare> \
 *          a_proc_fin=0x<cpu_feroceon_proc_fin> [dryrun=1] [wdt=1]
 *   cat /proc/ex4boot            the plan + a CRC32 of every loaded segment (compare with the host's numbers)
 *   echo boot > /proc/ex4boot    point of no return
 *
 * The three a_* addresses come from /proc/kallsyms on the SAME running kernel (the symbols are not exported).
 * The loader script (ex4-trial.sh) fills them in and refuses if any is missing. The module refuses to arm
 * unless the first word at each address is the instruction this kernel build has there (see looks_like()).
 *
 * How the jump works (same order as 3.2's machine_kexec, with one fix): irqs off, setup_mm_for_reboot() adds a
 * 1:1 mapping of low memory, caches flushed and turned off (cpu_proc_fin), then we branch to our stub THROUGH the
 * 1:1 mapping, so the stub is already running at its physical address when it clears the MMU bit (3.2's own
 * cpu_reset turns the MMU off while still running at a virtual address and relies on the pipeline).
 * The stub copies every chunk to its final physical address and jumps to `entry` with r0=0, r1, r2.
 *
 * Source pages are chosen so that none of them (and not the stub page) lies inside any destination range.
 *
 * Born Nov 16 2026 (aliaholes). SPDX-License-Identifier: GPL-2.0-or-later. Status Nov 16 2026: v0 loaded (dryrun) and jumped once
 * on the real box without wdt (run 1: never seen again on the LAN, cause unknown). v1 = v0 + the watchdog address
 * fix below; the wdt=1 path has still never run on hardware.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/mm.h>
#include <linux/gfp.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/reboot.h>
#include <linux/delay.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <asm/cacheflush.h>
#include <asm/proc-fns.h>
#include <asm/mach-types.h>
#include <asm/page.h>
#include <asm/io.h>
#include <mach/kirkwood.h>              /* KIRKWOOD_REGS_VIRT_BASE: where THIS kernel maps the SoC's internal registers */

#define MAXSEG 6
#define RAM_END 0x20000000UL            /* the EX4 has 512 MiB; a destination past it is refused */

static char *segs;
static unsigned long entry = 0x8000, r1, r2 = 0x100;
static unsigned long a_setup_mm, a_restart_prepare, a_proc_fin;
static int dryrun;                       /* dryrun=1: load + report only, "boot" is refused */
static int wdt;                          /* wdt=1: arm the SoC watchdog (about 21 s) just before the jump */
module_param(segs, charp, 0444);
module_param(entry, ulong, 0444);
module_param(r1, ulong, 0444);
module_param(r2, ulong, 0444);
module_param(a_setup_mm, ulong, 0444);
module_param(a_restart_prepare, ulong, 0444);
module_param(a_proc_fin, ulong, 0444);
module_param(dryrun, int, 0444);
module_param(wdt, int, 0444);

extern const unsigned char ex4boot_stub[], ex4boot_stub_end[];

struct seg { char path[200]; unsigned long dest, len, crc; };
static struct seg seg[MAXSEG];
static int nseg;

struct ent { u32 dest, src, len; };      /* what the stub walks; len 0 ends the list */
struct ctl { u32 entry, r1, r2, pad; struct ent e[0]; };
static struct page *ctl_page;            /* stub code at +0, struct ctl at +CTL_OFF */
#define CTL_OFF 1024
static struct ctl *ctl;
static unsigned int nent, maxent;
static LIST_HEAD(held);                  /* pages that fell inside a destination: held until unload */
static LIST_HEAD(used);
static DEFINE_MUTEX(lock);

static u32 crc32_step(u32 c, const unsigned char *p, size_t n)
{
	size_t i; int k;
	for (i = 0; i < n; i++) { c ^= p[i]; for (k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320 & -(c & 1)); }
	return c;
}

static int in_dest(unsigned long phys)
{
	int i;
	for (i = 0; i < nseg; i++)
		if (phys + PAGE_SIZE > (seg[i].dest & PAGE_MASK) && phys < PAGE_ALIGN(seg[i].dest + seg[i].len))
			return 1;
	return 0;
}

static struct page *safe_page(void)
{
	int tries;
	for (tries = 0; tries < 20000; tries++) {
		struct page *p = alloc_page(GFP_KERNEL);
		if (!p) return NULL;
		if (!in_dest(page_to_phys(p))) { list_add(&p->lru, &used); return p; }
		list_add(&p->lru, &held);
	}
	return NULL;
}

static void free_all(void)
{
	struct page *p, *n;
	list_for_each_entry_safe(p, n, &held, lru) { list_del(&p->lru); __free_page(p); }
	list_for_each_entry_safe(p, n, &used, lru) { list_del(&p->lru); __free_page(p); }
}

static int parse_segs(void)
{
	char *s, *tok, *dup = kstrdup(segs ? segs : "", GFP_KERNEL);
	int i, j;
	if (!dup) return -ENOMEM;
	s = dup;
	while ((tok = strsep(&s, ",")) != NULL) {
		char *at = strrchr(tok, '@');
		if (!*tok) continue;
		if (!at || nseg >= MAXSEG || at - tok >= sizeof(seg[0].path)) { kfree(dup); return -EINVAL; }
		*at = 0;
		strcpy(seg[nseg].path, tok);
		if (strict_strtoul(at + 1, 0, &seg[nseg].dest) || (seg[nseg].dest & 3)) { kfree(dup); return -EINVAL; }
		nseg++;
	}
	kfree(dup);
	if (!nseg) return -EINVAL;
	for (i = 0; i < nseg; i++) {                    /* sizes first: the destination map must be complete */
		struct file *f = filp_open(seg[i].path, O_RDONLY, 0);
		if (IS_ERR(f)) { pr_err("ex4boot: cannot open %s (%ld)\n", seg[i].path, PTR_ERR(f)); return PTR_ERR(f); }
		seg[i].len = i_size_read(f->f_path.dentry->d_inode);
		filp_close(f, NULL);
		if (!seg[i].len || seg[i].dest + seg[i].len > RAM_END || seg[i].dest + seg[i].len < seg[i].dest) {
			pr_err("ex4boot: %s: size %lu at 0x%lx does not fit in RAM\n", seg[i].path, seg[i].len, seg[i].dest);
			return -EINVAL;
		}
	}
	for (i = 0; i < nseg; i++)
		for (j = 0; j < i; j++)
			if (seg[i].dest < seg[j].dest + seg[j].len && seg[j].dest < seg[i].dest + seg[i].len) {
				pr_err("ex4boot: segments %d and %d overlap\n", j, i);
				return -EINVAL;
			}
	return 0;
}

static int load_segs(void)
{
	int i;
	for (i = 0; i < nseg; i++) {
		struct file *f = filp_open(seg[i].path, O_RDONLY, 0);
		unsigned long off = 0; u32 c = 0xffffffff;
		if (IS_ERR(f)) return PTR_ERR(f);
		while (off < seg[i].len) {
			unsigned long n = min(seg[i].len - off, (unsigned long)PAGE_SIZE);
			struct page *p = safe_page();
			int got;
			if (!p || nent + 1 >= maxent) { filp_close(f, NULL); return -ENOMEM; }
			memset(page_address(p), 0, PAGE_SIZE);
			got = kernel_read(f, off, page_address(p), n);
			if (got != n) { filp_close(f, NULL); pr_err("ex4boot: short read on %s\n", seg[i].path); return -EIO; }
			c = crc32_step(c, page_address(p), n);
			ctl->e[nent].dest = seg[i].dest + off;
			ctl->e[nent].src = page_to_phys(p);
			ctl->e[nent].len = ALIGN(n, 4);
			nent++;
			off += n;
		}
		filp_close(f, NULL);
		seg[i].crc = ~c;
		pr_info("ex4boot: seg%d %s -> 0x%08lx len %lu crc32 %08lx\n", i, seg[i].path, seg[i].dest, seg[i].len, seg[i].crc);
	}
	ctl->e[nent].dest = ctl->e[nent].src = ctl->e[nent].len = 0;
	return 0;
}

/* setup_mm_for_reboot and kernel_restart_prepare are C functions built with CONFIG_FRAME_POINTER: they start
 * "mov ip, sp" (e1a0c00d). cpu_feroceon_proc_fin is assembly and starts "mov r0, #0" (e3a00000). All three were
 * read in the stock kernel image off the box. A wrong address (a different kernel build) will almost surely not
 * have that word there: refuse instead of jumping into the weeds. */
static int looks_like(unsigned long a, u32 first_word)
{
	if (a < PAGE_OFFSET + 0x8000 || a >= (unsigned long)high_memory || (a & 3)) return 0;
	return *(u32 *)a == first_word;
}

/* Optional safety net (wdt=1): start the Kirkwood watchdog at its longest period (0xffffffff ticks of the
 * 200 MHz TCLK = about 21 s) and let it reset the SoC. A new kernel that hangs before it takes the watchdog over
 * then falls back to a normal U-Boot boot of the untouched flash, with no hand on the power plug. Mainline's
 * orion_wdt adopts a running watchdog and keeps feeding it. Stock leaves the watchdog off (read Nov 16 2026:
 * TIMER_CTRL 0x0000000f, RSTOUTn mask 0), so this is opt-in. Registers: Kirkwood functional spec, same ones
 * drivers/watchdog/orion_wdt.c writes.
 * FIXED Nov 16 2026 (v1, before wdt=1 ever ran): v0 wrote through virt 0xf1000000, taking the registers' PHYSICAL
 * base for a mapping. WD's kernel maps them at KIRKWOOD_REGS_VIRT_BASE = 0xfed00000 (its own kirkwood.h; the stock
 * image holds the literal 0xfed20300 = TIMER_CTRL and none for 0xf10203xx), and its boot log puts 0xf1000000 inside
 * the vmalloc area (0xe0800000-0xfa800000). v0's wdt=1 would have faulted with interrupts off, after the devices
 * were shut down: a dead box, no jump. Now the address comes from the kernel's own header. */
#define EX4_REG(off) (*(volatile u32 *)(KIRKWOOD_REGS_VIRT_BASE + (off)))
static void arm_watchdog(void)
{
	EX4_REG(0x20324) = 0xffffffff;            /* WDT counter */
	EX4_REG(0x20110) &= ~(1u << 3);           /* clear a stale WDT bit in the bridge cause register */
	EX4_REG(0x20300) |= 1u << 4;              /* TIMER_CTRL: WDT enable */
	EX4_REG(0x20108) |= 1u << 1;              /* RSTOUTn mask: let the WDT reset the SoC */
}

static void do_boot(void)
{
	void (*restart_prepare)(char *) = (void *)a_restart_prepare;
	void (*setup_mm)(char) = (void *)a_setup_mm;
	void (*proc_fin)(void) = (void *)a_proc_fin;
	unsigned long stub_phys = page_to_phys(ctl_page);
	void (*stub)(unsigned long) = (void *)stub_phys;      /* reached through the 1:1 map */

	pr_emerg("ex4boot: shutting devices down, then jumping to 0x%08x (r1=%u r2=0x%x). Flash is untouched.\n",
		 ctl->entry, ctl->r1, ctl->r2);
	restart_prepare(NULL);                 /* reboot notifiers, device_shutdown, syscore_shutdown */
	pr_emerg("ex4boot: bye\n");
	mdelay(100);                           /* let the UART drain */
	local_irq_disable();
	local_fiq_disable();
	if (wdt)
		arm_watchdog();
	setup_mm(0);
	flush_cache_all();
	outer_flush_all();
	outer_disable();
	proc_fin();                            /* cpu_feroceon_proc_fin: caches + L2 off */
	outer_inv_all();
	flush_cache_all();
	stub(stub_phys + CTL_OFF);
	for (;;) ;                             /* not reached */
}

static int ex4_read(char *page, char **start, off_t off, int count, int *eof, void *data)
{
	int i, n = 0;
	n += scnprintf(page + n, count - n, "ex4boot: %s; entry 0x%08lx r1 %lu r2 0x%lx; %u chunks; stub page phys 0x%08lx; page size %lu; wdt %d\n",
		       dryrun ? "DRY RUN (boot refused)" : "ARMED (echo boot > /proc/ex4boot)", entry, r1, r2, nent,
		       (unsigned long)page_to_phys(ctl_page), PAGE_SIZE, wdt);
	for (i = 0; i < nseg; i++)
		n += scnprintf(page + n, count - n, "seg%d dest 0x%08lx len %lu crc32 %08lx %s\n", i, seg[i].dest, seg[i].len, seg[i].crc, seg[i].path);
	*eof = 1;
	return n;
}

static int ex4_write(struct file *file, const char __user *buf, unsigned long count, void *data)
{
	char cmd[8] = "";
	if (count < 4 || copy_from_user(cmd, buf, min(count, 7UL))) return -EINVAL;
	if (strncmp(cmd, "boot", 4)) return -EINVAL;
	if (dryrun) { pr_err("ex4boot: dryrun=1, boot refused\n"); return -EPERM; }
	if (!capable(CAP_SYS_BOOT)) return -EPERM;
	mutex_lock(&lock);
	do_boot();
	return count;
}

static int __init ex4boot_init(void)
{
	struct proc_dir_entry *pe;
	int ret;
	unsigned int stub_len = ex4boot_stub_end - ex4boot_stub;

	BUILD_BUG_ON(KIRKWOOD_REGS_VIRT_BASE != 0xfed00000UL);   /* the value read in WD's 2.12.127 tree; a different tree must be looked at first */
	if (PAGE_SIZE < CTL_OFF + sizeof(struct ctl) + 64 * sizeof(struct ent) || stub_len > CTL_OFF) return -EINVAL;
	if (!r1) r1 = machine_arch_type;
	if ((entry & 3) || entry >= RAM_END || (r2 & 3) || r2 >= RAM_END) return -EINVAL;
	if (!dryrun && (!looks_like(a_setup_mm, 0xe1a0c00d) || !looks_like(a_restart_prepare, 0xe1a0c00d) ||
			!looks_like(a_proc_fin, 0xe3a00000))) {
		pr_err("ex4boot: a_setup_mm / a_restart_prepare / a_proc_fin missing or not function addresses on this kernel: refused (dryrun=1 only loads)\n");
		return -EINVAL;
	}
	ret = parse_segs();
	if (ret) return ret;
	ctl_page = safe_page();
	if (!ctl_page) { free_all(); return -ENOMEM; }
	memset(page_address(ctl_page), 0, PAGE_SIZE);
	memcpy(page_address(ctl_page), ex4boot_stub, stub_len);
	ctl = page_address(ctl_page) + CTL_OFF;
	maxent = (PAGE_SIZE - CTL_OFF - sizeof(struct ctl)) / sizeof(struct ent);
	ctl->entry = entry; ctl->r1 = r1; ctl->r2 = r2;
	ret = load_segs();
	if (ret) { free_all(); return ret; }
	flush_icache_range((unsigned long)page_address(ctl_page), (unsigned long)page_address(ctl_page) + PAGE_SIZE);
	pe = create_proc_entry("ex4boot", 0600, NULL);
	if (!pe) { free_all(); return -ENOMEM; }
	pe->read_proc = ex4_read;
	pe->write_proc = ex4_write;
	pr_info("ex4boot: loaded %d segment(s), %u chunks, %s\n", nseg, nent, dryrun ? "DRY RUN" : "armed: echo boot > /proc/ex4boot");
	return 0;
}

static void __exit ex4boot_exit(void)
{
	remove_proc_entry("ex4boot", NULL);
	free_all();
}

module_init(ex4boot_init);
module_exit(ex4boot_exit);
MODULE_LICENSE("GPL");
MODULE_AUTHOR("aliaholes");
MODULE_DESCRIPTION("WD My Cloud EX4: boot another kernel from RAM out of the stock 3.2.40 kernel (flash untouched)");
