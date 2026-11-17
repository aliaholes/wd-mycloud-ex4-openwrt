#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# stubtest: prove ex4boot's relocation stub (the only hand-written assembly) on an emulated ARM926 (qemu versatilepb).
# What it proves: chunk copy, ordering, the r0/r1/r2 handoff and the jump. What it does NOT prove: the MMU/cache
# shutdown on a real Feroceon, or anything about the EX4's hardware.   usage: sh build-and-run.sh <ex4boot_stub.S>
set -e
STUB=${1:?path to ex4boot_stub.S}; D=$(cd "$(dirname "$0")" && pwd); O=${OUT:-$D/out}; mkdir -p "$O"; cd "$O"
CC=arm-linux-gnueabi-gcc; F="-march=armv5te -marm -Os -ffreestanding -nostdlib -fno-pic -fno-stack-protector -I$D"
$CC $F -Wl,-Ttext=0x8000 -Wl,--build-id=none -o target.elf "$D/target_start.S" "$D/target.c"
arm-linux-gnueabi-objcopy -O binary target.elf target.bin
$CC $F -Wl,-Ttext=0x10000 -Wl,--build-id=none -o harness.elf "$D/harness_start.S" "$D/harness.c" "$STUB"
arm-linux-gnueabi-objcopy -O binary harness.elf harness.bin
timeout 20 qemu-system-arm -M versatilepb -cpu arm926 -m 256 -nographic -monitor none -serial stdio -kernel harness.bin > run.log 2>&1 || true
cat run.log; grep -q "RESULT: PASS" run.log
