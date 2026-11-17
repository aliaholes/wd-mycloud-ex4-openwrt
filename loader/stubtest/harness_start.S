/* SPDX-License-Identifier: GPL-2.0-or-later */
	.text
	.arm
	.globl _start
_start:	ldr	sp, =0x0f000000
	bl	hmain
1:	b	1b
	.globl target_bin, target_bin_end
	.align 4
target_bin:
	.incbin "target.bin"
target_bin_end:
	.align 4
