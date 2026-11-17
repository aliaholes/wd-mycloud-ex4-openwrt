# ex4boot: how the loader works

`loader/ex4boot_main.c` + `loader/ex4boot_stub.S`, a module for WD's stock kernel (Marvell LSP 3.2.40, Feroceon
88FR131, ARMv5TE, `CONFIG_KEXEC` off, modules on, 32 KiB software pages). It never touches flash: there is no MTD
call in it.

## Interface

```
insmod ex4boot.ko segs="/path/file@0xADDR,..." entry=0x8000 r2=0x100 \
       a_setup_mm=0x... a_restart_prepare=0x... a_proc_fin=0x... [dryrun=1] [wdt=1]
cat /proc/ex4boot              # the plan and a CRC32 of every loaded segment
echo boot > /proc/ex4boot      # point of no return
```

`box/ex4-trial.sh` does all of this; do not call the module by hand.

- Up to six segments, each a file copied to a physical address. The trial uses: RAM marker A (0x1000), the kernel
  with its device tree appended (0x8000), the ATAG list (0x100), the overlay archive (0x4000000), marker C
  (0x3000), marker H (0x03000000).
- `a_*` are the addresses of `setup_mm_for_reboot`, `kernel_restart_prepare` and `cpu_feroceon_proc_fin` from
  `/proc/kallsyms`: WD's kernel does not export them. The module refuses unless the first instruction at each
  address is the one this kernel build has there.
- `dryrun=1` loads and reports, and refuses `boot`.
- `wdt=1` arms the SoC watchdog (about 21 s) immediately before the jump.
- `r1` is not passed: the module hands on the machine id the running kernel was booted with (527). A device-tree
  kernel ignores it.

## The jump

1. `kernel_restart_prepare()`: devices are shut down as for a reboot.
2. Interrupts off. `setup_mm_for_reboot()` adds a 1:1 mapping of low memory.
3. Caches flushed and switched off (`cpu_feroceon_proc_fin`).
4. Branch to the stub **through the 1:1 mapping**, so it runs at its physical address before the MMU goes off
   (3.2's own reset path switches the MMU off while still executing at a virtual address).
5. The stub: MMU off; **L2 cache cleaned, disabled, invalidated**; copy every chunk to its destination; jump to
   `entry` with `r0 = 0`, `r1`, `r2`.

Source pages are chosen so that none of them, and not the stub's own page, lies inside a destination range.

## What the new kernel needs from the handoff

- A zImage with the device tree appended; the kernel must have `CONFIG_ARM_APPENDED_DTB` and
  `CONFIG_ARM_ATAG_DTB_COMPAT` (OpenWrt's kirkwood kernel has both). The decompressor folds the ATAG list
  (memory size, command line, initrd address) into the device tree.
- The ATAG list at 0x100: CORE, MEM 512 MiB, INITRD2 (the overlay), CMDLINE, NONE.
- The overlay is a second cpio archive passed as an initrd; the kernel unpacks it on top of its built-in
  initramfs. That is how the DHCP-client setup, your ssh key, the fan daemon and the logger get into an
  unmodified official OpenWrt image.
- The command line carries `watchdog.open_timeout=120`: with the watchdog armed, the kernel feeds it for at most
  120 s while it waits for userspace to take over, so a kernel without a working userspace is reset as well.

## The L2 cache

See the README. In source terms: WD's `outer_cache` has no `flush_all`, `inv_all` or `disable`, so the generic
calls a kexec would make do nothing on this kernel; the enable bit is bit 22 (0x00400000) of the Feroceon "extra
features" CP15 register; the four instructions the stub uses are ones WD's own kernel image contains. Mainline's
`feroceon_l2_init` prints `bootloader left the L2 cache on!` and carries on if it finds the bit set. After the
fixed stub, 6.12 printed `Feroceon L2: Enabling L2` on the unit, i.e. it found the cache off as after U-Boot.

## The watchdog as a safety net

- Under stock the SoC watchdog is off. `wdt=1` sets it going right before the jump.
- OpenWrt's 6.12 kernel has the orion watchdog driver built in; when it finds the watchdog running it adopts it
  and keeps feeding it, then procd takes over. Seen on the unit in runs 5, 6 and 7.
- WD's own kernel never feeds a running watchdog. Starting WD's kernel through the loader with `wdt=1` therefore
  resets it 21 s later; that is only useful as a deliberate probe.
- A watchdog reset is a warm reset: RAM survives it on this board (seen: our markers came back whole), which is
  what lets `verdict` read the dead kernel's log out of memory afterwards. A power cycle clears it.

## RAM markers and the black box

`ex4-trial.sh verdict` has to tell "the stub never ran" from "the kernel died early" without a serial console:

- three 4 KiB marker blocks copied by the stub as its first, second-to-last and last segments. Two sit at
  0x1000 and 0x3000, inside the first 32 KiB page, which the stock kernel reserves and never reuses; the third is
  in ordinary memory;
- `ex4peek klog`, which finds a Linux 6.x printk ring in a copy of physical memory;
- `ex4log`, which writes the kernel log, a status block and the init scripts' progress notes to a raw region of
  a disk every few seconds from the earliest point in userspace (format in `userland/ex4log.c`).

## What the emulator tests do and do not prove

`loader/stubtest/` and `tests/qemu-handoff.sh` run the real stub, and then the real bundle bytes through the real
stub into the real OpenWrt kernel, on qemu's ARM926 "versatilepb" told to report the EX4's CPU id. They prove the
copy, the ordering, the register handoff, the appended device tree, the ATAG folding and the overlay unpacking.
qemu has no Kirkwood machine: its L2 and Feroceon cache operations are no-ops, and nothing about the EX4's
peripherals is exercised. The L2 fix is proven only by the real unit.
