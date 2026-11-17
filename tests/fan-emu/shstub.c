/* SPDX-License-Identifier: GPL-2.0-or-later */
/* shstub.c — a stand-in for WD's libshare.so, used ONLY off the box (qemu-arm user mode) so that WD's own
 * `led` runs without /dev/mem and every SoC register it reads or writes is on record. Signatures read from the real
 * library's disassembly (NAS fan-recon-2026-11-16/proof/libshare.so.disassembly.txt, Nov 16-17 2026):
 *   unsigned LIB_Read_CPU_Register(unsigned off)             = LIB_Read_Mem(0xf1000000 + off)   (/dev/mem, one 32-bit word)
 *   int      LIB_Write_CPU_Register(unsigned off, unsigned v) = LIB_Write_Mem(0xf1000000 + off, v)
 * The register model: one file per address under $SHSTUB_DIR (R<hex address>), seeded by the test with the values read
 * live from the stock box (ex4peek regs); an address with no file reads 0. Log: $SHSTUB_DIR/LOG ("RD addr = v", "WR addr
 * = v (was w, bits set s, bits cleared c)"). Only GLIBC_2.4 symbols. Build: as xmlstub.c, soname libshare.so.
 * Born Nov 17 2026 (EX4 run 7 prep). */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void logline(const char *line)
{
	char p[512]; const char *d = getenv("SHSTUB_DIR"); int fd;
	if (!d) return;
	snprintf(p, sizeof p, "%s/LOG", d);
	fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0600);
	if (fd < 0) return;
	if (write(fd, line, strlen(line)) < 0) { }
	close(fd);
}
static unsigned model_get(unsigned addr)
{
	char p[512], b[32]; const char *d = getenv("SHSTUB_DIR"); int fd, n;
	if (!d) return 0;
	snprintf(p, sizeof p, "%s/R%08x", d, addr);
	fd = open(p, O_RDONLY);
	if (fd < 0) return 0;
	n = read(fd, b, sizeof b - 1); close(fd);
	if (n < 0) n = 0;
	b[n] = 0;
	return (unsigned)strtoul(b, 0, 16);
}
static void model_set(unsigned addr, unsigned v)
{
	char p[512], b[32]; const char *d = getenv("SHSTUB_DIR"); int fd, n;
	if (!d) return;
	snprintf(p, sizeof p, "%s/R%08x", d, addr);
	fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) return;
	n = snprintf(b, sizeof b, "%08x\n", v);
	if (write(fd, b, n) < 0) { }
	close(fd);
}
unsigned LIB_Read_Mem(unsigned addr)
{
	char l[160]; unsigned v = model_get(addr);
	snprintf(l, sizeof l, "RD %08x = %08x\n", addr, v); logline(l);
	return v;
}
int LIB_Write_Mem(unsigned addr, unsigned v)
{
	char l[200]; unsigned w = model_get(addr);
	snprintf(l, sizeof l, "WR %08x = %08x (was %08x, bits set %08x, bits cleared %08x)\n", addr, v, w, v & ~w, w & ~v); logline(l);
	model_set(addr, v);
	return 0;
}
unsigned LIB_Read_CPU_Register(unsigned off) { return LIB_Read_Mem(0xf1000000u + off); }
int LIB_Write_CPU_Register(unsigned off, unsigned v) { LIB_Write_Mem(0xf1000000u + off, v); return 0; }
int LIB_Get_Dev_SCSI_Map(unsigned a, unsigned b, unsigned c, unsigned d)
{
	char l[160];
	snprintf(l, sizeof l, "CALL LIB_Get_Dev_SCSI_Map(%08x, %08x, %08x, %08x) -> 0\n", a, b, c, d); logline(l);
	return 0;
}
