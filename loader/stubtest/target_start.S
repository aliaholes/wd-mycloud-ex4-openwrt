/* SPDX-License-Identifier: GPL-2.0-or-later */
	.text
	.arm
	.globl _start
_start:	ldr	sp, =0x00700000
	bl	tmain
1:	b	1b
