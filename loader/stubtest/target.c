/* SPDX-License-Identifier: GPL-2.0-or-later */
/* the "new kernel": linked at 0x00008000 like a zImage. Reports what it was handed. */
#include "common.h"
void tmain(u32 r0, u32 r1, u32 r2)
{
	u32 *info = (u32 *)r2;               /* our fake "atags": [magic][data addr][data len][expected crc] */
	u32 c;
	puts_("TARGET entered: r0="); hex_(r0); puts_(" r1="); hex_(r1); puts_(" r2="); hex_(r2); puts_("\n");
	if (info[0] != 0x45583421) { puts_("RESULT: FAIL (info block magic wrong)\n"); for (;;) ; }
	c = crc32_((unsigned char *)info[1], info[2]);
	puts_("data crc="); hex_(c); puts_(" expected="); hex_(info[3]); puts_("\n");
	puts_(c == info[3] && r0 == 0 && r1 == 3035 ? "RESULT: PASS\n" : "RESULT: FAIL\n");
	for (;;) ;
}
