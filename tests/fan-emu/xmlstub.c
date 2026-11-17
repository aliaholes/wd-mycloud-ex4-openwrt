/* SPDX-License-Identifier: GPL-2.0-or-later */
/* xmlstub.c — a stand-in for WD's libxmldbc.so, used ONLY off the box (qemu-arm user mode) so that WD's own
 * up_send_ctl / up_send_daemon / up_read_daemon run without WD's xmldb daemon and every node they set or read is on record.
 * Signatures read from the real library's disassembly (Nov 16 2026):
 *   int xmldbc_set(int sock, int flags, const char *node, const char *value)
 *   int xmldbc_get_wb(int sock, int flags, const char *node, char *buf, int size)   -> bytes, or -1
 *   int xmldbc_del(int sock, int flags, const char *node) ; int xml_del(const char *node)
 * Store: one file per node under $XMLSTUB_DIR ('/' -> '^'), shared by every process of a run. Log: $XMLSTUB_DIR/LOG.
 * Only GLIBC_2.4 symbols (the stock rootfs has glibc 2.8). Build: see run_emu.sh.
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void nodefile(const char *node, char *out, int n)
{
	const char *d = getenv("XMLSTUB_DIR");
	int i, k;
	if (!d) d = "/nonexistent-xmlstub";
	k = snprintf(out, n, "%s/N", d);
	for (i = 0; node[i] && k < n - 1; i++) out[k++] = node[i] == '/' ? '^' : node[i];
	out[k] = 0;
}

static void logline(const char *op, const char *node, const char *val)
{
	char p[512], line[768];
	const char *d = getenv("XMLSTUB_DIR");
	int fd, k;
	if (!d) return;
	snprintf(p, sizeof p, "%s/LOG", d);
	fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0600);
	if (fd < 0) return;
	k = snprintf(line, sizeof line, "%d %s %s%s%s\n", (int)getpid(), op, node, val ? " = " : "", val ? val : "");
	if (k > 0) { if (write(fd, line, k) < 0) { } }
	close(fd);
}

int xmldbc_set(int sock, int flags, const char *node, const char *value)
{
	char p[512];
	int fd;
	(void)sock; (void)flags;
	logline("SET", node, value);
	nodefile(node, p, sizeof p);
	fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) return -1;
	if (write(fd, value, strlen(value)) < 0) { }
	close(fd);
	return 0;
}

int xmldbc_get_wb(int sock, int flags, const char *node, char *buf, int size)
{
	char p[512];
	int fd, n;
	(void)sock; (void)flags;
	if (size <= 0) return -1;
	buf[0] = 0;
	nodefile(node, p, sizeof p);
	fd = open(p, O_RDONLY);
	if (fd < 0) { logline("GET", node, "(none)"); return 1; }
	n = read(fd, buf, size - 1);
	close(fd);
	if (n < 0) n = 0;
	buf[n] = 0;
	logline("GET", node, buf);
	return n + 1;
}

int xmldbc_del(int sock, int flags, const char *node)
{
	char p[512];
	(void)sock; (void)flags;
	logline("DEL", node, 0);
	nodefile(node, p, sizeof p);
	unlink(p);
	return 0;
}

int xml_del(const char *node) { return xmldbc_del(0, 0, node); }
int xml_set_str(const char *node, const char *value) { return xmldbc_set(0, 0, node, value); }
