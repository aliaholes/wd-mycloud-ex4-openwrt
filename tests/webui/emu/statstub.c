/* SPDX-License-Identifier: GPL-2.0-or-later */
/* statstub.c: EMULATION ONLY, preloaded into rpcd under qemu-arm. qemu's user mode looks absolute paths up under the
 * -L root for open(), not for statx(), and this musl asks statx() for every stat(): so under emulation rpcd "cannot
 * see" its own plugins and config although it could open them. This gives stat()/lstat() the same look-up-under-the-
 * root rule that open() already has. It changes where a path is looked for, nothing about what rpcd does with it.
 * Built with -DPREFIX="/abs/rootfs". No libc: loaded by the image's musl (arm, 64-bit time_t layout below). */
typedef unsigned long long u64; typedef long long s64; typedef unsigned u32;
struct ts64 { s64 tv_sec; long tv_nsec; long pad; };
struct mstat {                                    /* musl arch/arm/bits/stat.h */
	u64 st_dev; int pad0; long ino_trunc; u32 st_mode; u32 st_nlink; u32 st_uid; u32 st_gid; u64 st_rdev; int pad1;
	s64 st_size; long st_blksize; s64 st_blocks; struct { long s, n; } a32, m32, c32; u64 st_ino;
	struct ts64 st_atim, st_mtim, st_ctim;
};
struct kts { s64 sec; u32 nsec; int r; };
struct kstatx { u32 mask, blksize; u64 attr; u32 nlink, uid, gid; unsigned short mode, sp0; u64 ino, size, blocks, amask;
	struct kts a, b, c, m; u32 rmaj, rmin, dmaj, dmin; u64 spare[14]; };
static long sys5(long n, long a, long b, long c, long d, long e)
{
	register long r0 __asm__("r0") = a, r1 __asm__("r1") = b, r2 __asm__("r2") = c, r3 __asm__("r3") = d, r4 __asm__("r4") = e, r7 __asm__("r7") = n;
	__asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r7) : "memory");
	return r0;
}
static u64 mkdev(u32 ma, u32 mi) { return ((u64)(ma & 0xfffff000) << 32) | ((u64)(ma & 0xfff) << 8) | ((u64)(mi & 0xffffff00) << 12) | (mi & 0xff); }
static int do_stat(int dirfd, const char *p, struct mstat *st, int flags)
{
	static const char pre[] = PREFIX; char buf[1024]; struct kstatx x; long r = -2; unsigned i = 0, j = 0;
	if (p && p[0] == '/') {
		while (pre[i] && i < sizeof buf - 1) { buf[i] = pre[i]; i++; }
		while (p[j] && i < sizeof buf - 1) buf[i++] = p[j++];
		buf[i] = 0;
		if (!p[j]) r = sys5(397, dirfd, (long)buf, flags, 0x7ff, (long)&x);
	}
	if (r < 0) r = sys5(397, dirfd, (long)p, flags, 0x7ff, (long)&x);
	if (r < 0) return -1;                         /* errno is not set: every caller here only tests for failure */
	for (i = 0; i < sizeof *st; i++) ((char *)st)[i] = 0;
	st->st_dev = mkdev(x.dmaj, x.dmin); st->st_ino = x.ino; st->ino_trunc = (long)x.ino; st->st_mode = x.mode; st->st_nlink = x.nlink;
	st->st_uid = x.uid; st->st_gid = x.gid; st->st_rdev = mkdev(x.rmaj, x.rmin); st->st_size = x.size; st->st_blksize = x.blksize; st->st_blocks = x.blocks;
	st->st_atim.tv_sec = x.a.sec; st->st_atim.tv_nsec = x.a.nsec; st->st_mtim.tv_sec = x.m.sec; st->st_mtim.tv_nsec = x.m.nsec;
	st->st_ctim.tv_sec = x.c.sec; st->st_ctim.tv_nsec = x.c.nsec;
	return 0;
}
int __stat_time64(const char *p, struct mstat *st)  { return do_stat(-100, p, st, 0); }
int __lstat_time64(const char *p, struct mstat *st) { return do_stat(-100, p, st, 0x100); }
int __fstatat_time64(int fd, const char *p, struct mstat *st, int fl) { return do_stat(fd, p, st, fl); }
