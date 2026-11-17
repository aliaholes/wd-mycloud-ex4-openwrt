/* SPDX-License-Identifier: GPL-2.0-or-later */
/* handoff3: entry. The segment table (segs3.S) is generated from the bundle's SEGS by tests/qemu-handoff3.sh. */
	.text
	.arm
	.globl _start
_start:	ldr	sp, =0x0f800000
	bl	hmain
1:	b	1b
	.ltorg
