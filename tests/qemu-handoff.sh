#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# qemu-handoff3.sh : the bundle's REAL bytes through the REAL stub into the REAL 6.12 kernel, on an emulated ARM926
# (qemu versatilepb). OFF the box. What it proves, and with which bytes:
#   - the stub (loader/ex4boot_stub.S built with -DEX4_L2OFF, the source of the module that jumped in run 4b)
#     copies the bundle's six segments in SEGS order to their SEGS addresses and enters 0x8000 with r1 = 527, r2 = 0x100
#   - the bundle's kernel.bin (OpenWrt's zImage + the appended EX4 DTB) decompresses itself from that state
#     (MMU off, caches off, a machine id that is not a DT one, an ATAG list at 0x100) and starts
#   - the kernel accepts the appended DTB (machine model line) and the ATAG list was folded into it by the
#     decompressor (the kernel command line holds the bundle's run id)
#   - ex4peek klog finds THAT kernel's log ring in a copy of the guest's RAM, and ex4peek marker finds the markers
# What it does NOT prove: anything about the EX4's hardware. qemu has no Kirkwood machine and no Feroceon CPU: the
# guest is an ARM926 that reports the EX4's CPU id (-cpu arm926,midr=...); the kernel finds no timer, no UART and
# no NAND there and stops early; the Feroceon L2 and cache opcodes are dummies in qemu; versatilepb has
# 256 MiB (the list says 512), so the kernel's first allocation at the top of memory lands outside RAM. Run with
# MEMFIX=1 the SAME generator writes a test-only ATAG list that says 256 MiB (the bundle's own list is not touched),
# which lets the kernel get as far as its command line.
#   sh qemu-handoff.sh <this repo's top folder> <bundle dir> <native ex4peek> <workdir (must not exist)> [seconds, default 45]
# Born Nov 16 2026 (EX4 run 5 prep).
set -u
T=$1; B=$2; PEEK=$3; W=$4; SECS=${5:-45}
MIDR=0x56251311     # the EX4's CPU id (stock /proc/cpuinfo: Feroceon 88FR131 rev 1). OpenWrt's kirkwood kernel knows no other
                    # CPU: with qemu's own ARM926 id it stops in __lookup_processor_type before its first log line (seen Nov 16 2026).
                    # The emulated core is still an ARM926: qemu answers the Feroceon-only CP15 registers as dummies.
[ -e "$W" ] && { echo "REFUSED: $W exists"; exit 1; }
mkdir -p "$W"; W=$(cd "$W" && pwd); B=$(cd "$B" && pwd); T=$(cd "$T" && pwd)
RUN=$(cat "$B/RUNID"); PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS  $*"; }
no() { FAIL=$((FAIL+1)); echo "FAIL  $*"; }
ATAGS="$B/atags.bin"
if [ "${MEMFIX:-0}" = 1 ]; then
	SZ=$(stat -c %s "$B/overlay.cpio")
	python3 -I "$T/build/ex4img.py" atags "$W/atags-256.bin" --mem 256 --initrd "0x4000000,$SZ" --cmdline "console=ttyS0,115200n8 watchdog.open_timeout=120 ex4boot_run=$RUN" > /dev/null || exit 1
	ATAGS="$W/atags-256.bin"
	python3 -I - "$B/atags.bin" "$ATAGS" <<'PY' || exit 1
import sys
a = open(sys.argv[1], 'rb').read(); b = open(sys.argv[2], 'rb').read()
d = [i for i in range(len(a)) if a[i] != b[i]]
assert len(a) == len(b) and d == [0x1f], "the test-only list must differ from the bundle's in the MEM size alone: %r" % d
print("MEMFIX: test-only ATAG list = the bundle's with ONE byte changed (MEM size 0x20000000 -> 0x10000000)")
PY
fi
# the segment table, from the bundle's own SEGS
n=0; : > "$W/segs3.S"; DEST=
while read -r f a; do
	[ -n "$f" ] || continue
	p="$B/$f"; [ "$f" = atags.bin ] && p=$ATAGS
	printf '\t.globl seg%s, seg%s_end\n\t.align 4\nseg%s:\t.incbin "%s"\nseg%s_end:\n' $n $n $n "$p" $n >> "$W/segs3.S"
	DEST="$DEST${DEST:+, }$a"; n=$((n+1))
done < "$B/SEGS"
[ $n = 6 ] || { echo "REFUSED: SEGS has $n segments, the harness takes 6"; exit 1; }
{ printf '\t.section .rodata\n\t.globl seg_dest\n\t.align 4\nseg_dest: .word %s\n' "$DEST"; cat "$W/segs3.S"; printf '\t.align 4\n'; } > "$W/segs3.full.S"
CC=arm-linux-gnueabi-gcc; F="-march=armv5te -marm -Os -ffreestanding -nostdlib -fno-pic -fno-stack-protector"
$CC $F -DEX4_L2OFF -Wl,-Ttext=0x08000000 -Wl,--build-id=none -o "$W/harness3.elf" "$T/loader/handoff-test/start3.S" "$T/loader/handoff-test/harness3.c" "$W/segs3.full.S" "$T/loader/ex4boot_stub.S" > "$W/build.log" 2>&1 || { cat "$W/build.log"; echo "REFUSED: harness build failed"; exit 1; }
arm-linux-gnueabi-objdump -d "$W/harness3.elf" | awk '/<ex4boot_stub>:/,/<ex4boot_stub_end>:/' > "$W/stub.dis"
grep -q 'mcr.*15, 1, ip, cr15, cr11, {0}' "$W/stub.dis" && grep -q 'mcr.*15, 1, ip, cr15, cr9, {0}' "$W/stub.dis" && grep -q 'bic.*0x400000' "$W/stub.dis" && ok "the stub in the harness is the L2-off one (clean, disable, invalidate L2 are in its disassembly)" || no "the harness stub is not the L2-off build"
( sleep "$SECS"; echo "stop"; echo "pmemsave 0 0x10000000 \"$W/ram.bin\""; echo "info registers"; sleep 2; echo quit ) | \
	timeout $((SECS + 60)) qemu-system-arm -M versatilepb -cpu "arm926,midr=$MIDR" -m 256 -display none -serial "file:$W/serial.log" -monitor stdio -kernel "$W/harness3.elf" > "$W/monitor.log" 2>&1
cat "$W/serial.log"
grep -q "calling the stub" "$W/serial.log" && ! grep -q "RESULT: FAIL" "$W/serial.log" && ok "the harness built the chunk list and called the stub; the stub did not return" || no "harness / stub"
[ -s "$W/ram.bin" ] || { no "no RAM copy from qemu"; echo "qemu-handoff: $PASS passed, $FAIL failed"; exit 1; }
# 1. the copy: every segment at its address, bit for bit (the kernel has run since: the zImage and marker pages may
#    have been reused by it, so only the segments a 6.12 boot does not write early are compared: ATAGs, overlay)
#    In the MEMFIX run the kernel gets far enough to reuse page 0 and to free the overlay: reported, not asserted.
python3 -I - "$W/ram.bin" "$B" "$ATAGS" "${MEMFIX:-0}" <<'PY' && ok "segments in guest RAM after the jump (MEMFIX=0: the ATAG list at 0x100 and the overlay at 0x4000000 are there bit for bit; MEMFIX=1: reported only)" || no "segments in guest RAM"
import sys
ram = open(sys.argv[1], 'rb').read(); b = sys.argv[2]; strict = sys.argv[4] != '1'
for f, a in (l.split() for l in open(b + '/SEGS') if l.strip()):
    a = int(a, 0); d = open(sys.argv[3] if f == 'atags.bin' else b + '/' + f, 'rb').read()
    same = ram[a:a + len(d)] == d
    print("   %-13s @%#010x %8d bytes: %s" % (f, a, len(d), "identical" if same else "differs (the zImage: the kernel was unpacked over it; anything else: the running kernel reused that memory)"))
    if strict and f in ('atags.bin', 'overlay.cpio'): assert same, f
PY
"$PEEK" marker --mem "$W/ram.bin" --to 10000000 --run "$RUN" --total 3 --at "$(. "$B/CFG"; echo "$MARK_AT")" > "$W/marker.txt" 2>&1
cat "$W/marker.txt"
if [ "${MEMFIX:-0}" = 1 ]; then
	echo "NOTE  markers after a kernel that reached its allocator: A $(awk '$2 == "pos=0" { print $5 }' "$W/marker.txt"), C $(awk '$2 == "pos=1" { print $5 }' "$W/marker.txt"), H $(awk '$2 == "pos=2" { print $5 }' "$W/marker.txt") (a running 6.12 reuses page 0: ABSENT here is expected, and is why the verdict reads the ring and the disk log first)"
else
	grep -q "^MARKER pos=0 .* run=$RUN state=INTACT" "$W/marker.txt" && grep -q "^MARKER pos=1 .* run=$RUN state=INTACT" "$W/marker.txt" && ok "RAM markers A and C of run $RUN are whole at 0x1000 and 0x3000 after a kernel that stopped early (the decompressor and the kernel's first steps do not write there)" || no "markers A / C after the jump"
	grep -q "^MARKER pos=2 .* run=$RUN state=INTACT" "$W/marker.txt" && ok "marker H is whole at 0x03000000 (nothing in the decompressor's working area reaches it)" || no "marker H after the jump"
fi
# 2. the kernel's own log ring, with the tool the box will use
"$PEEK" klog --mem "$W/ram.bin" --from 0 --to 10000000 --out "$W/klog.txt" > "$W/klogscan.txt" 2>&1; rc=$?
tail -3 "$W/klogscan.txt" | cut -c1-200
[ $rc = 0 ] && ok "ex4peek klog finds a Linux 6.x log ring in the guest's RAM" || no "ex4peek klog found no ring (rc $rc)"
if [ -s "$W/klog.txt" ]; then
	echo "---- the ring ($(wc -l < "$W/klog.txt") lines) ----"; cut -c1-180 "$W/klog.txt" | head -${SHOW:-45}; echo "----"
	grep -q "^CPU: Feroceon 88FR131" "$W/klog.txt" && ok "the kernel runs as on a Feroceon 88FR131 (the id the guest reports): $(grep -m1 '^CPU: Feroceon' "$W/klog.txt")" || no "no Feroceon CPU line"
	grep -q "^Linux version $(. "$B/CFG"; echo "$KVER") " "$W/klog.txt" && ok "the ring starts with the bundle kernel's version line: $(grep -m1 '^Linux version' "$W/klog.txt" | cut -c1-90)" || no "no version line of the bundle's kernel in the ring"
	grep -q "Machine model: Western Digital My Cloud EX4" "$W/klog.txt" && ok "the kernel took the appended EX4 DTB: $(grep -m1 'Machine model' "$W/klog.txt")" || no "no EX4 machine model line (the appended DTB was not used)"
	if grep -q "^Kernel command line: console=ttyS0,115200n8 watchdog.open_timeout=120 ex4boot_run=$RUN\$" "$W/klog.txt"; then ok "the decompressor folded the ATAG command line into the DTB: $(grep -m1 'Kernel command line' "$W/klog.txt")"
		grep -q "^Unknown kernel command line parameters \"ex4boot_run=$RUN\", will be passed to user space" "$W/klog.txt" && ok "the kernel took watchdog.open_timeout=120 as one of its own parameters (the only word it calls unknown is the run id)" || no "the kernel's list of unknown parameters is not the run id alone: $(grep -m1 'Unknown kernel command line' "$W/klog.txt")"
	elif [ "${MEMFIX:-0}" = 1 ]; then no "MEMFIX run: the kernel did not print a command line with the run id"
	elif grep -q "Kernel command line:" "$W/klog.txt"; then no "a kernel command line WITHOUT the run id: $(grep -m1 'Kernel command line' "$W/klog.txt")"
	else echo "NOTE  no 'Kernel command line' in the ring in this run (with 512 MiB claimed on a 256 MiB machine the kernel stops before it): the MEMFIX=1 run decides this point"; fi
	if [ "${MEMFIX:-0}" = 1 ]; then
		grep -q "node   0: \[mem 0x0000000000000000-0x000000000fffffff\]" "$W/klog.txt" && ok "the ATAG memory size reached the kernel through the DTB (256 MiB from the test-only list; the DTB alone says 512)" || no "MEMFIX run: memory is not the ATAG's 256 MiB"
		grep -q "^Unpacking initramfs" "$W/klog.txt" && grep -q "^Freeing initrd memory: $(( ($(stat -c %s "$B/overlay.cpio") + 4095) / 4096 * 4 ))K" "$W/klog.txt" && ok "the kernel unpacked the EXTERNAL initrd (the bundle's overlay.cpio, handed over as ATAG_INITRD2) on top of its built-in initramfs: $(grep -m1 '^Freeing initrd memory' "$W/klog.txt")" || no "MEMFIX run: no 'Unpacking initramfs' / 'Freeing initrd memory' for the overlay"
		grep -q "^Feroceon L2: Enabling L2" "$W/klog.txt" && ! grep -q "bootloader left the L2 cache on" "$W/klog.txt" && ok "6.12 found the L2 off and enabled it itself (in qemu the L2 register is a dummy: this checks the kernel's path, not the stub's write)" || no "MEMFIX run: L2 lines"
		grep -q "ttyS0 at MMIO 0xf1012000" "$W/klog.txt" && ok "the kernel got as far as its serial driver (device initcalls); it stops at the first console character, qemu has no UART and no timer there" || echo "NOTE  the kernel did not reach its serial driver in $SECS s"
	else
		grep -q "node   0: \[mem 0x0000000000000000-0x000000001fffffff\]" "$W/klog.txt" && ok "with the bundle's own list the kernel sees 512 MiB" || no "memory is not 512 MiB with the bundle's list"
	fi
	grep -q "Error: invalid dtb\|unrecognized/unsupported machine ID\|Unhandled fault\|Kernel panic" "$W/klog.txt" && echo "NOTE  the ring holds: $(grep -m1 'Error: invalid dtb\|unrecognized/unsupported machine ID\|Unhandled fault\|Kernel panic' "$W/klog.txt" | cut -c1-160)"
fi
echo "qemu-handoff: $PASS passed, $FAIL failed   (MEMFIX=${MEMFIX:-0}, $SECS s of guest time, workdir $W)"
[ $FAIL = 0 ]
