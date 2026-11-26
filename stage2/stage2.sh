#!/bin/sh
# /ex4/stage2.sh : the EX4 "second-stage loader". Lives in the ramdisk (mtd2), runs under WD's own 3.2.40 kernel
# (mtd1, never rewritten), called from /etc/rc.sh right after mdev. U-Boot (mtd0) is never touched either.
#
# What it does:
#   - mtd3 is still WD's firmware image (not UBI)        -> returns at once: the box boots stock exactly as before.
#   - mtd3 is UBI with a volume "ex4boot" (UBIFS)        -> counts the attempt, loads kernel.bin (+ atags + initrd)
#     from it into RAM through ex4boot.ko with the 21 s watchdog armed, and jumps into the modern kernel.
#   - 3 attempts in a row did not end with the new system clearing the counter, or anything fails, or the file
#     "rescue" exists in the volume                      -> RESCUE: network up by DHCP + a root telnet shell on
#     port 23 under the stock kernel, with nandwrite/nanddump/ubi tools, so the unit can be repaired or put back to
#     stock over the LAN. No serial cable, no screwdriver.
# The modern system proves it is alive by writing 0 into "tries" in the ex4boot volume after a good boot.
#
# DRAFT, Nov 16 2026: syntax-checked and packed into a ramdisk off the box; it has NEVER run on hardware.
# v1, Nov 26 2026 (three fixes, each read on the stock box): (1) every log line also goes into the KERNEL LOG
# (/dev/kmsg), so `dmesg | grep ex4-stage2` shows which branch ran after a normal WD boot; (2) the log file moved
# from /tmp to /ex4: WD's boot later mounts a tmpfs over /tmp (stock /proc/mounts), which hides anything written
# there this early; (3) no shell arithmetic: stock's /bin/sh is a busybox built without math ("you disabled math
# support"), so the counter uses busybox expr.
E=/ex4; BB=$E/busybox; LOG=$E/stage2.log; MNT=/tmp/ex4mnt; T=/tmp/ex4boot
log() { echo "ex4-stage2: $*" >> $LOG; { echo "ex4-stage2: $*" > /dev/kmsg; } 2>/dev/null || echo "ex4-stage2: $*" > /dev/console 2>/dev/null; }

rescue() {
	log "RESCUE: $1"
	$BB umount $MNT 2>/dev/null
	for i in egiga0 egiga1; do
		$BB ifconfig $i up 2>/dev/null
	done
	$BB sleep 4
	for i in egiga0 egiga1; do
		$BB udhcpc -i $i -n -q -t 5 -s $E/udhcpc.script >> $LOG 2>&1 && break
	done
	$BB telnetd -l /bin/sh -p 23
	log "rescue shell: telnet to this box, port 23. Log: $LOG. Tools: $BB (nanddump, nandwrite, ubi*, md5sum, tftp)"
	while :; do $BB sleep 3600; done        # never fall through into WD's init: its image is gone
}

grep -q DB88FXX81 /proc/cmdline || exit 0
[ -x $BB ] || exit 0
MAGIC=$($BB dd if=/dev/mtd3 bs=4 count=1 2>/dev/null)
[ "$MAGIC" = "UBI#" ] || { log "mtd3 is not UBI (stock firmware image): continuing the stock boot"; exit 0; }

# from here on mtd3 is ours: the stock system cannot boot, so every failure ends in rescue, never in exit
$BB mkdir -p $MNT $T
$BB ubiattach -m 3 -d 3 -O 2048 >> $LOG 2>&1 || rescue "ubiattach mtd3 failed"
$BB sleep 1
$BB mount -t ubifs ubi3:ex4boot $MNT >> $LOG 2>&1 || rescue "no ex4boot volume"
[ -e $MNT/rescue ] && rescue "rescue requested (file 'rescue' in the ex4boot volume)"
for f in kernel.bin atags.bin initrd.cpio EXPECT ADDRS; do [ -s $MNT/$f ] || rescue "ex4boot volume lacks $f"; done
TRIES=$($BB cat $MNT/tries 2>/dev/null); case "$TRIES" in ''|*[!0-9]*) TRIES=0;; esac
[ "$TRIES" -ge 3 ] && rescue "3 boot attempts without a good boot"
N=$($BB expr "$TRIES" + 1); echo "$N" > $MNT/tries; $BB sync
$BB cp $MNT/kernel.bin $MNT/atags.bin $MNT/initrd.cpio $MNT/EXPECT $MNT/ADDRS $T/ || rescue "copy to RAM failed"
. $T/ADDRS
$BB umount $MNT || rescue "umount failed"
$BB ubidetach -d 3 >> $LOG 2>&1

A_MM=$($BB awk '$3=="setup_mm_for_reboot"{print $1}' /proc/kallsyms)
A_RP=$($BB awk '$3=="kernel_restart_prepare"{print $1}' /proc/kallsyms)
A_PF=$($BB awk '$3=="cpu_feroceon_proc_fin"{print $1}' /proc/kallsyms)
[ -n "$A_MM" ] && [ -n "$A_RP" ] && [ -n "$A_PF" ] || rescue "kallsyms lacks the functions ex4boot needs"
$BB insmod $E/ex4boot.ko segs=$T/kernel.bin@$KERNEL_ADDR,$T/atags.bin@$ATAGS_ADDR,$T/initrd.cpio@$INITRD_ADDR \
	entry=$ENTRY r2=$R2 a_setup_mm=0x$A_MM a_restart_prepare=0x$A_RP a_proc_fin=0x$A_PF wdt=1 >> $LOG 2>&1 || rescue "insmod ex4boot failed"
while read -r seg crc; do
	$BB grep -q "^$seg .* crc32 $crc " /proc/ex4boot || { $BB rmmod ex4boot; rescue "$seg failed its CRC in RAM"; }
done < $T/EXPECT
log "attempt $N: jumping into the modern kernel (watchdog armed)"
echo boot > /proc/ex4boot
rescue "the jump returned"
