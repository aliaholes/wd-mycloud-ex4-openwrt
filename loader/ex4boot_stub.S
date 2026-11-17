/* ex4boot_stub.S : position-independent. Entered at its PHYSICAL address through a 1:1 mapping, irqs off, caches off.
 * r0 = physical address of struct ctl { entry, r1, r2, pad, { dest, src, len }... } ; a len of 0 ends the list.
 * Turns the MMU off (the same bits 3.2's cpu_feroceon_reset clears), copies every chunk, jumps: r0=0, r1, r2.
 * SPDX-License-Identifier: GPL-2.0-or-later. Born Nov 16 2026.
 *
 * EX4_L2OFF (build flag, Nov 16 2026 v2; WITHOUT it this file assembles to the v0/v1 stub, byte for byte):
 * also turns the Feroceon L2 cache OFF and empties it before the copy, which is the state U-Boot hands a kernel
 * (stock boot log: "Feroceon L2: Enabling L2" = the bit was 0 at entry). Why: cpu_feroceon_proc_fin only CLEANS
 * the L2 and leaves it enabled and full of the old kernel's lines; this kernel's outer_cache has no flush_all /
 * inv_all / disable, so ex4boot_main.c's outer_*() calls do nothing. WD's 3.2.40 decompressor empties the L2
 * itself ("L2 cache might be present containing valid data (from u-boot) ... we do it ourselves"); mainline's
 * (6.12) does not, and mainline's feroceon_l2_init only prints "bootloader left the L2 cache on!" and keeps it.
 * The three L2 instructions are copied from WD's tree: arch/arm/mm/proc-feroceon.S (clean), cache-feroceon-l2.c
 * (read/write_extra_features, bit 0x00400000; l2_inv_all, which enable_l2 runs with the L2 off). */
	.text
	.arm
	.align	5
	.globl	ex4boot_stub
ex4boot_stub:
	mov	r9, r0
	mov	ip, #0
	mcr	p15, 0, ip, c7, c7, 0		@ invalidate I+D caches
	mcr	p15, 0, ip, c7, c10, 4		@ drain write buffer
	mcr	p15, 0, ip, c8, c7, 0		@ invalidate TLBs
	mrc	p15, 0, ip, c1, c0, 0
	bic	ip, ip, #0x000f			@ write buffer, D-cache, alignment, MMU
	bic	ip, ip, #0x1100			@ I-cache, S
	mcr	p15, 0, ip, c1, c0, 0		@ MMU off; we are at virt == phys
	nop
	nop
	nop
#ifdef EX4_L2OFF
	mov	ip, #0
	mcr	p15, 1, ip, c15, c9, 0		@ clean entire L2 (nothing can be dirty: proc_fin cleaned it, caches are off)
	mcr	p15, 0, ip, c7, c10, 4		@ drain write buffer
	mrc	p15, 1, ip, c15, c1, 0		@ Feroceon extra features
	bic	ip, ip, #0x00400000		@ L2 enable off
	mcr	p15, 1, ip, c15, c1, 0
	mov	ip, #0
	mcr	p15, 1, ip, c15, c11, 0		@ invalidate entire L2
	mcr	p15, 0, ip, c7, c10, 4		@ drain write buffer
#endif
	add	r4, r9, #16
1:	ldr	r5, [r4], #4			@ dest
	ldr	r6, [r4], #4			@ src
	ldr	r7, [r4], #4			@ len (bytes, multiple of 4)
	cmp	r7, #0
	beq	3f
2:	ldr	r8, [r6], #4
	str	r8, [r5], #4
	subs	r7, r7, #4
	bgt	2b
	b	1b
3:	mov	r0, #0
	ldr	r1, [r9, #4]
	ldr	r2, [r9, #8]
	ldr	pc, [r9, #0]
	.globl	ex4boot_stub_end
ex4boot_stub_end:
