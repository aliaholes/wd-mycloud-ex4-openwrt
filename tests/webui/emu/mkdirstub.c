/* SPDX-License-Identifier: GPL-2.0-or-later */
/* mkdirstub.c: EMULATION ONLY, preloaded into ubusd (the message bus) under qemu-arm. Two things the build host cannot
 * give an unprivileged user:
 *   1. ubusd makes /var/run/ubus before it binds its socket and gives up when it cannot: that mkdir becomes a no-op
 *      (the socket itself goes to -s WORKDIR/ubus.sock).
 *   2. ubusd lets only uid 0 use the bus without a per-user ACL file, and on the host we are uid 1000: the peer
 *      credentials it reads are reported as uid 0, which is what every client on the real box is (rpcd, uhttpd run as root).
 * rpcd and uhttpd, whose behaviour the test is about, run UNMODIFIED. No libc needed: loaded by the image's musl. */
struct ucred_ { int pid; unsigned uid, gid; };
int mkdir(const char *path, unsigned mode) { (void)path; (void)mode; return 0; }
int getsockopt(int fd, int level, int opt, void *val, unsigned *len)
{
	if (level == 1 /* SOL_SOCKET */ && opt == 17 /* SO_PEERCRED */ && val && len && *len >= sizeof(struct ucred_)) {
		struct ucred_ *c = val; c->pid = 1; c->uid = 0; c->gid = 0; *len = sizeof *c; return 0;
	}
	{ register long r0 __asm__("r0") = fd, r1 __asm__("r1") = level, r2 __asm__("r2") = opt, r3 __asm__("r3") = (long)val,
	  r4 __asm__("r4") = (long)len, r7 __asm__("r7") = 295 /* __NR_getsockopt, ARM EABI */;
	  __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r7) : "memory");
	  return r0 < 0 ? -1 : (int)r0; }
}
