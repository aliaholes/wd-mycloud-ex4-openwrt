#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# trial-logic5.sh : trial-logic4.sh for box/ex4-trial.sh v5 (run 7): the same 105 cases on the v5 script and a bundle-v5
# (one more file, KMODS.txt), + the V5 cases: `check` prints the addresses stock uses; the verdict's V5 lines (MACs,
# USB 3, clock, front panel, link) from a fresh disk log, from the LAN witness, with an unbound controller and equal
# MACs, with holes in the link line, and "no v5 self-test on record". Below: trial-logic4.sh's own header.
# trial-logic4.sh : trial-logic3.sh for box/ex4-trial.sh v4 (the fan): the same 90 cases on the v4 script and a
# bundle-v4 (one more file, ex4fan), + the FAN cases: the verdict's FAN line from a fresh disk log (normal run, the
# same kernel line in dmesg AND logread counted once, a fail-safe reboot, no tachometer, a silent micro), from the
# RAM ring, from the LAN witness, and "no ex4fan line on record". Below: trial-logic3.sh's own header.
# trial-logic3.sh : the shell logic of box/ex4-trial.sh v3 (check with the log gate and the two-cable wall, load-dry
# with the marker proof, go up to the jump, verdict in every case, log / klog / marker), run OFF the box on a fake
# /proc, fake sdX3 files and a fake memory image. It runs a COPY of the script with: gate() made a no-op (it rightly
# refuses anything that is not the EX4), /proc/{cmdline,uptime,ex4boot,mdstat,mounts,partitions,swaps} and /dev/sdX3
# pointed into the fake tree, `-b` relaxed to `-e`, busybox md5sum -> md5sum, /tmp/ex4boot moved into the workdir, the
# NIC sysfs folder and stock's start ledger pointed at fakes, dmesg faked, `ex4peek marker` and `ex4peek klog` pointed
# at a memory image file, insmod / rmmod called as STUBS by full path (the insmod stub loads nothing; told to "work"
# it writes what the module would print into the fake /proc/ex4boot from the bundle's own EXPECT), and the three
# lines of `go` that touch the machine (kill, remount, ifconfig) turned into no-ops. Nothing else is changed.
#   sh trial-logic.sh <ex4-trial.sh> <bundle dir> <native ex4peek> <native ex4log> <mkfixture.py> <workdir (must not exist)> [shell]
# Born Nov 16 2026 (EX4 run 5 prep).
set -u
SH=$1; B=$2; XPEEK=$3; XLOG=$4; MK=$5; W=$6; SHELL_=${7:-sh}
[ -e "$W" ] && { echo "REFUSED: $W exists"; exit 1; }
[ "$(id -u)" != 0 ] || { echo "REFUSED: never run this harness as root (it runs go up to the jump with stubs)"; exit 1; }
mkdir -p "$W/b" "$W/proc" "$W/bin" "$W/dev" "$W/net/egiga0" "$W/net/egiga1" "$W/net/bond0"; W=$(cd "$W" && pwd)
for i in bond0 egiga0 egiga1; do echo "00:90:a9:00:00:50" > "$W/net/$i/address"; done          # v5: what stock's bond shows (read on the unit)
FILES="ex4boot-l2off.ko ex4peek ex4log ex4fan KMODS.txt kernel.bin overlay.cpio atags.bin markA.bin markC.bin markH.bin SEGS EXPECT RUNID CFG LOGCFG PROVENANCE ex4-trial.sh"
for f in $FILES; do [ "$f" = ex4-trial.sh ] || cp "$B/$f" "$W/b/"; done
cp "$XPEEK" "$W/b/ex4peek"; cp "$XLOG" "$W/b/ex4log"
# The cases below are written against the test unit's shape (partition 3 = 1049415 KiB on four disks, bay 4 = sdd3
# kept off), whatever LOG_SECTORS / LOG_SKIP_* the bundle under test was built with: the test copy gets that LOGCFG.
printf 'LOG_MIN_KB=1049415\nLOG_MAX_KB=1049415\nLOG_EXACT_KB=1049415\nLOG_TAG=ex4-openwrt\nLOG_SKIP_PORT=4\nLOG_SKIP_PARTS="sdd3"\n' > "$W/b/LOGCFG"
sed -e 's#^gate() {#gate() { A_MM=c0010000; A_RP=c0020000; A_PF=c0030000; say "gate skipped (test copy)"; return 0#' \
    -e "s#/proc/cmdline#$W/proc/cmdline#g; s#/proc/uptime#$W/proc/uptime#g; s#/proc/ex4boot#$W/proc/ex4boot#g; s#/proc/mdstat#$W/proc/mdstat#g; s#/proc/mounts#$W/proc/mounts#g; s#/proc/partitions#$W/proc/partitions#g; s#/proc/swaps#$W/proc/swaps#g" \
    -e "s#/dev/\${d}3#$W/dev/\${d}3#g; s#\"/dev/\$part\"#\"$W/dev/\$part\"#g" -e 's#\[ -b "#[ -e "#g' \
    -e 's#busybox md5sum#md5sum#g' -e "s#/tmp/ex4boot#$W/tmp-ex4boot#g" \
    -e "s#^NICDIR=/sys/class/net#NICDIR=$W/net#" \
    -e "s#^STARTDIR=/mnt/HD_a4/.@database@#STARTDIR=$W/hd_a4/db#" -e "s#\"/proc/\$MP/cmdline\"#\"$W/proc/\$MP/cmdline\"#" \
    -e "s#dmesg > \"\$L/dmesg-\$STAMP.txt\" 2>/dev/null#cat \"$W/dmesg.fake\" > \"\$L/dmesg-\$STAMP.txt\"#" \
    -e "s#\"\$D/ex4peek\" marker#\"\$D/ex4peek\" marker --mem \"\${EX4_TEST_MEM}\" --to 3002000#g" \
    -e "s#\"\$D/ex4peek\" klog#\"\$D/ex4peek\" klog --mem \"\${EX4_TEST_MEM}\" --from 0 --to 3002000#g" \
    -e "s#echo \"insmod \$1/\$KO#echo \"$W/bin/insmod \$1/\$KO#; s#rmmod ex4boot#$W/bin/rmmod ex4boot#g" \
    -e 's#then kill "\$pid" 2>/dev/null; fi#then : kill; fi#' -e 's#do mount -o remount,ro "\$m" 2>/dev/null || DIRTY=1; done#do : mount; done#' \
    -e 's#do ifconfig \$i down 2>/dev/null; done#do : ifconfig; done#' "$SH" > "$W/b/ex4-trial.sh"
n=$(diff "$SH" "$W/b/ex4-trial.sh" | grep -c '^>'); echo "test copy differs from the real script in $n lines (the redirections above); shell: $SHELL_"
for pat in ': kill; fi' 'do : mount; done' 'do : ifconfig; done'; do grep -q "$pat" "$W/b/ex4-trial.sh" || { echo "REFUSED: the test copy still touches the machine ($pat not in place)"; exit 1; }; done
grep -q 'kill "\$pid"\|remount,ro "\$m"\|ifconfig \$i down' "$W/b/ex4-trial.sh" && { echo "REFUSED: a machine-touching line survived in the test copy"; exit 1; }
grep -q "^STARTDIR=$W/hd_a4/db" "$W/b/ex4-trial.sh" && grep -q "^NICDIR=$W/net" "$W/b/ex4-trial.sh" && grep -q "cat \"$W/dmesg.fake\"" "$W/b/ex4-trial.sh" && grep -q "\"$W/proc/\$MP/cmdline\"" "$W/b/ex4-trial.sh" || { echo "REFUSED: the ledger / NIC / dmesg / pid redirections are not in place in the test copy"; exit 1; }
[ "$(grep -c "ex4peek\" marker --mem" "$W/b/ex4-trial.sh")" -ge 3 ] && [ "$(grep -c "ex4peek\" klog --mem" "$W/b/ex4-trial.sh")" = 1 ] || { echo "REFUSED: ex4peek is not pointed at the memory image everywhere"; exit 1; }
grep -q "echo \"$W/bin/insmod " "$W/b/ex4-trial.sh" && [ "$(grep -c "$W/bin/rmmod ex4boot" "$W/b/ex4-trial.sh")" -ge 5 ] && ! grep -v '^#' "$W/b/ex4-trial.sh" | grep -q '[^/]rmmod ex4boot &&\|; rmmod ex4boot;' || { echo "REFUSED: the test copy does not call the insmod/rmmod stubs by full path"; exit 1; }
sed "s#$W/dev/##g" "$W/b/ex4-trial.sh" | grep -v '^[[:space:]]*#' | grep -q '/dev/\${d}3\|"/dev/\$part"\|/dev/sd' && { echo "REFUSED: the test copy still names a real disk device"; exit 1; }
remd5() { ( cd "$W/b" && md5sum $FILES > MD5SUMS ); }
remd5
RUN=$(cat "$B/RUNID")
DEF='root=/dev/ram console=ttyS0,115200 max_loop=32 :::DB88FXX81:egiga0:none'
parts() { { echo "major minor  #blocks  name"; echo; for d in sda sdb sdc sdd; do echo "   8  0 3907018584 $d"; echo "   8  1    2097152 ${d}1"; echo "   8  2 3902822400 ${d}2"; echo "   8  3    $1 ${d}3"; echo "   8  4    1048576 ${d}4"; done; } > "$W/proc/partitions"; }
stock() { parts 1049415; printf '/dev/sda4 /mnt/HD_a4 ext4 rw 0 0\n/dev/md1 /mnt/HD/HD_a2 ext4 rw 0 0\n' > "$W/proc/mounts"
          printf 'Filename Type Size Used Priority\n/dev/md0 partition 2097056 0 -1\n' > "$W/proc/swaps"
          printf 'md1 : active raid5 sda2[0] sdd2[3] sdc2[2] sdb2[1]\nmd0 : active raid1 sdd1[3] sdc1[2] sdb1[1] sda1[0]\n' > "$W/proc/mdstat"; }
stock
echo "$DEF" > "$W/proc/cmdline"; echo "1234.56 1000.00" > "$W/proc/uptime"
echo 0 > "$W/net/egiga0/carrier"; echo 1 > "$W/net/egiga1/carrier"
newdisks() { for d in sda sdb sdc sdd; do rm -f "$W/dev/${d}3"; python3 -I -c 'import sys; open(sys.argv[1],"wb").write(bytes(4<<20))' "$W/dev/${d}3"; done; chmod 000 "$W/dev/sdd3"; }   # sdd3: any attempt to open it fails loudly
newdisks
mem() { python3 -I "$MK" mem "$@"; }
mem "$W/none.img"
mem "$W/dry.img" "$B/markA.bin@1f38000" "$B/markC.bin@1f40000" "$B/markH.bin@1f48000"       # what the module holds while loaded: markers in source pages
mem "$W/dry-two.img" "$B/markA.bin@1f38000" "$B/markC.bin@1f40000"
mem "$W/acH.img" "$B/markA.bin@1000" "$B/markC.bin@3000" "$B/markH.bin@3000000"
mem "$W/a.img" "$B/markA.bin@1000"
# rings (the trial kernel's log as ex4peek would find it in RAM)
KV='Linux version 6.12.112 (builder@buildhost) (arm-openwrt-linux-muslgnueabi-gcc (OpenWrt GCC 14.3.0 r33311-981c978eff) 14.3.0, GNU ld (GNU Binutils) 2.44) #0 Sat Oct 17 21:45:38 2026'
ring() { # $1 = out lines file, $2 = run id in the command line ("" = no command line), then extra lines
	o=$1; r=$2; shift 2
	{ echo "Booting Linux on physical CPU 0x0"; echo "$KV"; echo "CPU: Feroceon 88FR131 [56251311] revision 1 (ARMv5TE), cr=00053977"; echo "OF: fdt: Machine model: Western Digital My Cloud EX4"
	  [ -n "$r" ] && echo "Kernel command line: console=ttyS0,115200n8 watchdog.open_timeout=120 ex4boot_run=$r"
	  echo "Feroceon L2: Enabling L2"; echo "Feroceon L2: Cache support initialised."; i=0; while [ $i -lt 12 ]; do echo "synthetic kernel line $i with some text to give the chain length"; i=$((i+1)); done
	  for l in "$@"; do echo "$l"; done; } > "$o"; }
ring "$W/r-kernel.txt" "$RUN" "Unpacking initramfs..." "LAST KERNEL LINE BEFORE THE RESET"
ring "$W/r-wdt.txt" "$RUN" "orion_wdt: Initial timeout 21 sec" "Run /init as init process" "Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000100" "Rebooting in 1 seconds.."
ring "$W/r-user.txt" "$RUN" "orion_wdt: Initial timeout 21 sec" "Run /init as init process" "ex4log: daemon started (bundle-v1), pid 412" "ex4log: still no usable log target after 20 s (sd disks visible: 0); I keep looking, this trail stays in the kernel log" "ex4log: net eth1 operstate=down carrier=0"
ring "$W/r-other.txt" "4-other-20261116-0000" "orion_wdt: Initial timeout 21 sec" "Run /init as init process" "ex4log: daemon started (bundle-v1), pid 412"
ring "$W/r-nocmd.txt" "" "an early line"
for r in kernel wdt user other nocmd; do mem "$W/ring-$r.img" "ring:$W/r-$r.txt@1495a58"; done
mem "$W/ring-kernel-ac.img" "ring:$W/r-kernel.txt@1495a58" "$B/markA.bin@1000" "$B/markC.bin@3000"
# disk log payloads (the shape src/ex4log.c writes)
payload() { # $1 = out, $2 = run id in cmdline ("" = none), $3 = inet line ("" = none), $4 = extras: self ret wdt
	{ echo "== EX4LOG bundle-v1  run 00112233445566778899aabbccddeeff  gen 1  seq 7  uptime 61.20 s  target sda3@ata1 =="
	  echo "-- trail (this daemon's milestones; [uptime seconds])"; echo "[     3.90] daemon started (bundle-v1), pid 412"; echo "[     4.70] log target = sda3 on ATA port 1 (2098831 sectors, dev 8:3), region [1 MiB, 3 MiB)"; echo "[    21.00] link is up on eth1"
	  echo "-- notes (/tmp/ex4-notes, 180 bytes)"; echo "[     9.00] rc.d S01 reached: procd is running the init scripts"
	  case "$4" in *ret*) echo "[  1235.00] auto-return: no /tmp/ex4-stay, rebooting to stock now";; esac
	  echo "-- status at uptime 61.20 s"; echo "loadavg: 0.50 0.20 0.07 1/50 990"
	  if [ -n "$2" ]; then echo "cmdline: console=ttyS0,115200n8 watchdog.open_timeout=120 ex4boot_run=$2"; else echo "cmdline: console=ttyS0,115200n8"; fi
	  echo "version: $KV"; echo "block devices: sda(7814037168 sectors) sdb(7814037168 sectors)"; echo "network devices:"; echo "  eth1: address=00:90:a9:00:00:50 operstate=up carrier=1 speed=1000 duplex=full"
	  echo "processes: 1:/sbin/procd 412:/usr/sbin/ex4log 901:/usr/sbin/dropbear"
	  echo '-- $ ip addr 2>&1  (exit 0, 300 bytes)'; echo "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536"; echo "    inet 127.0.0.1/8 scope host lo"; echo "5: br-lan: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500"
	  [ -n "$3" ] && echo "    inet $3 brd 192.0.2.255 scope global br-lan"
	  echo '-- $ ip route 2>&1  (exit 0, 60 bytes)'; echo "default via 192.0.2.254 dev br-lan"
	  case "$4" in *self*) echo "-- self-test (/tmp/ex4-selftest.txt, 900 bytes)"; echo "== EX4 trial self-test Mon Nov 16 22:10:00 2026 =="; echo "kernel: 6.12.112  board: wd,mycloud-ex4"; echo "== bays seen: 3 of 4 ==";; *) echo "-- self-test: (/tmp/ex4-selftest.txt: No such file or directory)";; esac
	  echo "-- dmesg (5000 bytes)"; echo "[    0.000000] Booting Linux on physical CPU 0x0"
	  case "$4" in *wdt*) echo "[    1.700000] orion_wdt: Initial timeout 21 sec";; esac
	  echo "[   12.000000] NEWEST-TRIAL-LINE"; } > "$1"; }
payload "$W/p-net.txt" "$RUN" "192.0.2.137/24" "self ret wdt"
payload "$W/p-nonet.txt" "$RUN" "" "wdt"
OWD="192.""168.1.1"          # OpenWrt's factory default, in two pieces (publish scanner)
payload "$W/p-static.txt" "$RUN" "$OWD/24" "self wdt"
payload "$W/p-notok.txt" "" "192.0.2.137/24" "self"
dlog() { python3 -I "$MK" disklog "$W/dev/$1" "$2" --run "$3" --gen "$4" --seq "$5" --uptime "$6"; }
# stock's start ledger and kernel log, faked
mkdir -p "$W/hd_a4/db"; LEDGER="$W/hd_a4/db/$(hostname).err"
i=0; while [ $i -lt 34 ]; do echo "261116 19:17:09 mysqld_safe Starting mysqld daemon with databases from /mnt/HD_a4/.@database@"; i=$((i+1)); done > "$LEDGER"
onestart() { echo "261116 22:00:00 mysqld_safe Starting mysqld daemon with databases from /mnt/HD_a4/.@database@" >> "$LEDGER"; }
printf 'Linux version 3.2.40\nFeroceon L2: Enabling L2\n' > "$W/dmesg.fake"
# the insmod stub: INSMOD_MODE = fail | ok | badcrc | badr1
cat > "$W/bin/insmod" <<STUB
#!/bin/sh
echo "insmod STUB (test): loading nothing; mode \${INSMOD_MODE:-fail}; args: \$*" >&2
[ "\${INSMOD_MODE:-fail}" = fail ] && exit 1
dry="ARMED (echo boot > /proc/ex4boot)"; case "\$*" in *dryrun=1*) dry="DRY RUN (boot refused)";; esac
wdt=0; case "\$*" in *wdt=1*) wdt=1;; esac
r1=527; [ "\$INSMOD_MODE" = badr1 ] && r1=3892
{ echo "ex4boot: \$dry; entry 0x00008000 r1 \$r1 r2 0x100; 210 chunks; stub page phys 0x1e000000; page size 32768; wdt \$wdt"
  n=0; while read -r f a; do read -r seg crc <&3; [ "\$INSMOD_MODE" = badcrc ] && [ \$n = 1 ] && crc=deadbeef
    echo "\$seg dest \$a len 1 crc32 \$crc $W/tmp-ex4boot/\${f##*/}"; n=\$((n+1)); done < "$W/b/SEGS" 3< "$W/b/EXPECT"; } > "$W/proc/ex4boot"
exit 0
STUB
printf '#!/bin/sh\necho "rmmod STUB (test)" >&2\nrm -f "%s/proc/ex4boot"\nexit 0\n' "$W" > "$W/bin/rmmod"
chmod 755 "$W/bin/insmod" "$W/bin/rmmod"
# v5: EX4_TEST_STOCK_BUSYBOX=<the stock firmware's own /bin/busybox (ARM)> + EX4_TEST_STOCK_ROOT=<a folder whose lib/ is the stock
# rootfs' lib/>: every awk the script runs is then the STOCK firmware's awk (busybox 1.20.2) under qemu-arm, not this host's.
# (Run 7 prep: the first v5 verdict failed on the box with "Call to undefined function": that awk reads NAME ( as a call.)
AWKNOTE="this host's awk"
if [ -n "${EX4_TEST_STOCK_BUSYBOX:-}" ]; then
	printf '#!/bin/sh\nexec qemu-arm -L %s %s awk "$@"\n' "$EX4_TEST_STOCK_ROOT" "$EX4_TEST_STOCK_BUSYBOX" > "$W/bin/awk"; chmod 755 "$W/bin/awk"
	[ "$(echo 'a b' | "$W/bin/awk" '{ print $2 }')" = b ] || { echo "REFUSED: the stock busybox awk does not run under qemu-arm here"; exit 1; }
	AWKNOTE="the STOCK firmware's awk under qemu-arm ($(qemu-arm -L "$EX4_TEST_STOCK_ROOT" "$EX4_TEST_STOCK_BUSYBOX" 2>&1 | head -1 | cut -d'(' -f1))"
fi
PASS=0; FAIL=0
t() { name=$1; want=$2; pat=$3; shift 3; out=$("$@" 2>&1); rc=$?
      if [ $rc = "$want" ] && echo "$out" | grep -q -- "$pat"; then PASS=$((PASS+1)); echo "PASS  $name"; else FAIL=$((FAIL+1)); echo "FAIL  $name (rc $rc, wanted $want, pattern: $pat)"; echo "$out" | tail -8 | cut -c1-400 | sed 's/^/      /'; fi; }
nt() { name=$1; pat=$2; shift 2; out=$("$@" 2>&1); if echo "$out" | grep -q -- "$pat"; then FAIL=$((FAIL+1)); echo "FAIL  $name (pattern present: $pat)"; else PASS=$((PASS+1)); echo "PASS  $name"; fi; }
chk() { if "$@"; then PASS=$((PASS+1)); echo "PASS  $CN"; else FAIL=$((FAIL+1)); echo "FAIL  $CN"; fi; }
R() { PATH="$W/bin:$PATH" EX4_TEST_MEM=${MEM:-$W/none.img} INSMOD_MODE=${IM:-fail} EX4_TWO_CABLES_OK=${TWO:-0} $SHELL_ "$W/b/ex4-trial.sh" "$@"; }
T="$W/tmp-ex4boot"

# ---- check ----
t "K1 check: bundle intact; the 6-segment insmod line through ex4boot-l2off.ko, no r1, wdt=0" 0 "would run: $W/bin/insmod $T/ex4boot-l2off.ko segs=$T/markA.bin@0x1000,$T/kernel.bin@0x8000,$T/atags.bin@0x100,$T/overlay.cpio@0x4000000,$T/markC.bin@0x3000,$T/markH.bin@0x3000000 entry=0x8000 r2=0x100 a_setup_mm=0xc0010000 a_restart_prepare=0xc0020000 a_proc_fin=0xc0030000 wdt=0" R check
t "K1 check names the module, the run id and the trial kernel" 0 "bundle intact (18 files); module ex4boot-l2off.ko, run id $RUN, trial kernel 6.12.112" R check
t "K1 check: log gate passes on the real unit's partition table; sdd3 kept off" 0 "size in the window (KiB): sda3:1049415 sdb3:1049415 sdc3:1049415\. " R check
t "K1 check: says which LAN ports have a cable" 0 "LAN ports under stock: egiga0 carrier 0, egiga1 carrier 1" R check
t "K1 check ends with CHECK ONLY" 0 "CHECK ONLY: nothing was loaded" R check
t "K2 check wdt: wdt=1 in the insmod line" 0 "a_proc_fin=0xc0030000 wdt=1" R check wdt
t "K2 check wdt: says what the watchdog does for this payload" 0 "wdt=1: the 21 s watchdog is armed just before the jump; OpenWrt's 6.12 kernel adopts and feeds it" R check wdt
t "K2 check (no wdt) says what a hang then costs" 0 "wdt=0: no watchdog. A kernel that hangs stays dark until a power cycle" R check
t "K3 unknown word -> usage" 64 "usage: sh ex4-trial.sh check \[wdt\]" R check banana
t "K3 v2's 'l2off' word is gone (one module only) -> usage" 64 "usage" R go l2off
t "K3 unknown mode -> usage" 64 "usage" R nonsense
t "K3 load-dry takes no word -> usage" 64 "usage" R load-dry wdt
echo x >> "$W/b/atags.bin"
t "K4 a changed bundle file is caught by the md5 check" 1 "REFUSED: atags.bin is damaged" R check
cp "$B/atags.bin" "$W/b/atags.bin"
echo "extra.bin 0x5000000" >> "$W/b/SEGS"; remd5
t "K4 a segment MD5SUMS does not cover is refused" 1 "REFUSED: SEGS names extra.bin" R check
cp "$B/SEGS" "$W/b/SEGS"; remd5
echo "$W/dev/sda3 /mnt/x ext4 rw 0 0" >> "$W/proc/mounts"
t "K5 log gate: sda3 mounted -> REFUSED" 1 "REFUSED: log gate: .*sda3 is MOUNTED" R check
stock; echo 'md2 : active linear sdb3[1] sda3[0]' >> "$W/proc/mdstat"
t "K5 log gate: sdX3 in an md array -> REFUSED" 1 "REFUSED: log gate: .*sda3 is a member of an md array" R check
stock; echo "$W/dev/sdc3 partition 1048572 0 -2" >> "$W/proc/swaps"
t "K5 log gate: sdc3 is swap -> REFUSED" 1 "REFUSED: log gate: .*sdc3 is SWAP" R check
stock; parts 1048576
t "K5 log gate: any other partition size -> REFUSED" 1 "REFUSED: log gate" R check
stock
echo 1 > "$W/net/egiga0/carrier"
t "K6 both LAN ports cabled: check warns (and still passes)" 0 "WARNING: both LAN ports have a live cable" R check
IM=ok
t "K6 both LAN ports cabled: go REFUSES before anything is loaded" 1 "REFUSED: BOTH LAN ports have a live cable" R go wdt
chk_() { [ ! -e "$W/proc/ex4boot" ]; }; CN="K6 nothing was loaded by that refused go"; chk chk_
rm -rf "$W/b/logs"; IM=fail
echo 0 > "$W/net/egiga0/carrier"

# ---- load-dry ----
IM=ok; MEM="$W/dry.img"
t "D1 load-dry: CRCs and r1 match, every marker found whole in RAM, module removed" 0 "dry load OK (ex4boot-l2off.ko)" R load-dry
t "D1 load-dry says the marker reader works" 0 "marker reader OK: every marker of run $RUN was found whole in RAM" R load-dry
CN="D1 the module is gone after load-dry (rmmod ran)"; chk chk_
MEM="$W/dry-two.img"
t "D2 one marker missing -> REFUSED" 1 "REFUSED: the marker reader did not find every marker of run $RUN" R load-dry
CN="D2 the module is gone after the refusal"; chk chk_
MEM="$W/dry.img"; IM=badcrc
t "D3 a segment with another crc in RAM -> REFUSED, unloaded" 1 "REFUSED: seg1 in RAM does not have crc32" R load-dry
IM=badr1
t "D3 a machine id that is not 527 -> REFUSED, unloaded" 1 "REFUSED: the module's entry / r1 / r2 are not 0x00008000 / 527 / 0x100" R load-dry
IM=fail
t "D4 insmod fails -> REFUSED" 1 "REFUSED: insmod failed" R load-dry
MEM=

# ---- verdict before any launch ----
t "V1 verdict, no launch log -> INCONCLUSIVE" 0 "VERDICT: INCONCLUSIVE: no launch log in" R verdict
t "V1 sdd3 is not read by verdict" 0 "DISK sdd3: not read (skipped (kept off in LOGCFG)" R verdict
t "V1b verdict all: sdd3 IS opened (and here fails, as arranged)" 0 "DISK sdd3: .*Permission denied" R verdict all
# ---- go, insmod refuses ----
rm -rf "$W/b/logs"
dlog sdb3 "$W/p-notok.txt" 99999999999999999999999999999999 1 3 40      # an OLD log, there before the launch (must be called STALE later)
IM=fail
t "G1 go: the (stubbed) insmod fails -> REFUSED" 1 "REFUSED: insmod failed" R go
LLF=$(ls "$W/b/logs"/launch-*.log 2>/dev/null | tail -1); PJ=$(ls "$W/b/logs"/prejump-state-*.txt 2>/dev/null | tail -1)
g1() { [ -n "$LLF" ] && grep -q "== ex4-trial go variant=l2off module=ex4boot-l2off.ko wdt=0 run=$RUN epoch=[0-9]* starts=34 payload=openwrt-6.12.112 " "$LLF" && grep -q "bundle intact" "$LLF" && grep -q "log gate passed" "$LLF" && grep -q "LAN ports under stock" "$LLF" && grep -q "log regions before the jump: sda3 state none; sdb3 state run=99999999999999999999999999999999 gen=1 seq=3 uptime=40; sdc3 state none; sdd3 skipped" "$LLF" && grep -q "REFUSED: insmod failed" "$LLF" && ! grep -q "LAST LINE" "$LLF"; }
CN="G1 the launch log holds every step up to the refusal (gate, bundle, log gate, LAN ports, log regions), and no LAST LINE"; chk g1
g1b() { [ -n "$PJ" ] && [ "$(wc -l < "$PJ")" = 4 ] && grep -q "^sdd3 skipped" "$PJ" && grep -q "^sdb3 state run=9999" "$PJ" && [ "$(basename "$PJ" .txt | sed 's/prejump-state-//')" = "$(basename "$LLF" .log | sed 's/launch-//')" ]; }
CN="G1 pre-jump state written by go itself, one line per sdX3, sdd3 skipped, same stamp as the launch log"; chk g1b
t "V2 verdict after a launch that stopped at insmod -> INCONCLUSIVE (stopped before the jump)" 0 "VERDICT: INCONCLUSIVE: the newest launch (run $RUN) stopped before the jump" R verdict
# ---- go wdt, all the way to `echo boot` (into the fake /proc/ex4boot) ----
sleep 1; IM=ok
t "G2 go wdt: runs to the end (the fake module 'loads'), says what the watchdog does" 0 "wdt=1: the 21 s watchdog will be armed just before the jump" R go wdt
LLF=$(ls "$W/b/logs"/launch-*.log 2>/dev/null | tail -1)
g2() { grep -q "variant=l2off module=ex4boot-l2off.ko wdt=1 run=$RUN " "$LLF" && tail -1 "$LLF" | grep -q "LAST LINE THIS LOG CAN HOLD.*variant=l2off wdt=1 run=$RUN" && grep -q "every segment in RAM matches EXPECT; entry 0x00008000, r1 527" "$LLF" && grep -q -- "-- [^ ]*/proc/cmdline now" "$LLF"; }
CN="G2 launch log: module, run id, verified segments, state dump, and the LAST LINE entry is its last line"; chk g2
g2b() { [ "$(cat "$W/proc/ex4boot")" = boot ]; }; CN="G2 the last thing go did was: echo boot > /proc/ex4boot"; chk g2b
rm -f "$W/proc/ex4boot"
setgap() { # make the newest launch look $1 seconds older than this "boot" (uptime $2): rewrites epoch= in the launch log's first line
	echo "$2 1.00" > "$W/proc/uptime"
	e=$(( $(date +%s) - ${2%.*} - $1 )); sed -i "1s/ epoch=[0-9]* / epoch=$e /" "$LLF"; }
V() { R verdict; }
# ---- HUNG ----
setgap 400 30.00; MEM="$W/none.img"
t "H1 jumped, nothing anywhere (power cycle) -> HUNG, evidence reaches only the launch log" 0 "VERDICT: HUNG AFTER THE JUMP: run $RUN (wdt=1) jumped and left no kernel log in RAM, no fresh disk log and no LAN witness. no RAM marker of run $RUN at its address.*the evidence reaches only the LAUNCH LOG.*stock started again 4[0-9][0-9] s after the launch line (a power cycle" V
t "H1 the old log on sdb3 is called STALE and does not count" 0 "DISK sdb3: state run=9999.*: STALE" V
setgap 48 30.00; MEM="$W/acH.img"
t "H2 back within a minute (watchdog), markers A and C whole, no ring -> HUNG, evidence reaches the end of the copy" 0 "VERDICT: HUNG AFTER THE JUMP: .*RAM markers A and C are whole at their addresses: the stub copied every segment.*END OF THE COPY.*an early reset (the 21 s watchdog, or a crash-reboot)" V
MEM="$W/a.img"
t "H3 only marker A -> the stub did not finish" 0 "VERDICT: HUNG AFTER THE JUMP: .*marker A (the first copy) is whole but C (copied after the kernel and the overlay) is ABSENT.*START OF THE COPY" V
MEM="$W/ring-other.img"
t "H4 a ring that names ANOTHER run does not count -> HUNG" 0 "VERDICT: HUNG AFTER THE JUMP" V
t "H4 and it is said" 0 "ring: it names ANOTHER run" V
IMG3="$(dirname "$MK")/../build/ex4img.py"            # an EARLIER run's markers (another run id), as run 4b left them on the box
python3 -I "$IMG3" marker "$W/oA.bin" --run 3-l2off-20261116-2040 --pos 0 --total 3 --dest 0x1000 > /dev/null
python3 -I "$IMG3" marker "$W/oC.bin" --run 3-l2off-20261116-2040 --pos 1 --total 3 --dest 0x3000 > /dev/null
mem "$W/old.img" "$W/oA.bin@1000" "$W/oC.bin@3000"; MEM="$W/old.img"
t "H5 an EARLIER run's markers still whole at the addresses (the box's state on Nov 16: run 4b's) -> this run's stub never copied" 0 "VERDICT: HUNG AFTER THE JUMP: .*the markers of an EARLIER run still sit whole at the addresses (A OTHER, C OTHER): RAM survived, and this run's stub never wrote its first marker.*BEFORE THE COPY" V
# ---- BOOTED: kernel ----
MEM="$W/ring-kernel-ac.img"
t "B1 ring with this run's id, no watchdog-driver line, wdt=1, back early -> BOOTED (kernel), cut by the watchdog, rerun without wdt" 0 "VERDICT: MODERN KERNEL BOOTED (how far: kernel): the 6.12.112 kernel started and printed its log, but there is no sign that it reached userspace. Evidence: the 6.12 kernel's own log ring is in RAM ([0-9]* lines, run id in it: this); .*The 21 s watchdog very likely cut a boot that was still going.*Run it again WITHOUT wdt" V
t "B1 the ring's facts are printed (version, command line, L2 state, last lines)" 0 "ring: L2 at entry: OFF, enabled by 6.12 (as after U-Boot) · watchdog driver line: no · reached /init: no · ex4log lines (userspace): 0" V
t "B1 the ring's last line is shown" 0 "   LAST KERNEL LINE BEFORE THE RESET" V
MEM="$W/ring-wdt.img"
t "B2 ring with the watchdog-driver line, /init and a panic -> BOOTED (kernel, reached /init), watchdog WAS taken over" 0 "VERDICT: MODERN KERNEL BOOTED (how far: kernel): the 6.12.112 kernel started and reached /init, but userspace left no trace.*6.12 HAD taken the watchdog over" V
t "B2 the crash line is called out" 0 "ring: IT HOLDS A CRASH: Kernel panic - not syncing: Attempted to kill init" V
setgap 175 30.00
t "B2b the same ring, back about 3 minutes after the launch with wdt -> the mark of a userspace that never opened the watchdog" 0 "VERDICT: MODERN KERNEL BOOTED (how far: kernel): .*stock started again 17[0-9] s after the launch line: with wdt that is the mark of a kernel that ran but whose userspace never opened the watchdog" V
setgap 48 30.00
MEM="$W/ring-nocmd.img"
t "B3 a ring that stops before its command line -> BOOTED (kernel), run id unknown" 0 "VERDICT: MODERN KERNEL BOOTED (how far: kernel): .*run id in it: unknown" V
MEM="$W/none.img"; cp "$W/r-kernel.txt" "$W/b/logs/early-klog-$RUN.txt"
t "B6 no ring in RAM any more, but an early capture of this run is on file -> BOOTED (kernel), said as early capture" 0 "VERDICT: MODERN KERNEL BOOTED (how far: kernel): .*the 6.12 kernel's own log ring was in RAM right after the reset (early capture, [0-9]* lines, run id in it: this)" V
t "B6 the verdict says where the ring came from" 0 "ring: nothing in RAM now, but an EARLY CAPTURE of run $RUN is on file" V
mv "$W/b/logs/early-klog-$RUN.txt" "$W/b/logs/early-klog-4-other.txt"
t "B7 an early capture filed under another run id is not read" 0 "VERDICT: HUNG AFTER THE JUMP" V
rm -f "$W/b/logs/early-klog-4-other.txt"
# ---- BOOTED: userspace ----
MEM="$W/ring-user.img"
t "B4 ring with ex4log lines (userspace ran, no disk) -> BOOTED (userspace)" 0 "VERDICT: MODERN KERNEL BOOTED (how far: userspace): Linux 6.12.112 ran on this box from RAM and its userspace came up, but no LAN address and no ssh from the LAN is on record" V
MEM="$W/none.img"; dlog sda3 "$W/p-nonet.txt" 00112233445566778899aabbccddeeff 1 7 61
t "B5 fresh disk log without a LAN address -> BOOTED (userspace)" 0 "VERDICT: MODERN KERNEL BOOTED (how far: userspace): .*the disk log on sda3 is FRESH (last snapshot at trial uptime 61 s, run id in it: this)" V
t "B5 FRESH is said for sda3, STALE for the old one" 0 "DISK sda3: state run=00112233445566778899aabbccddeeff gen=1 seq=7 uptime=61: FRESH, written after the jump (before: state none)" V
t "B5 with the watchdog line in the disk log's dmesg and an early return: taken over, not cut" 0 "6.12 HAD taken the watchdog over" V
# ---- BOOTED: network ----
setgap 1290 30.00
dlog sda3 "$W/p-net.txt" 00112233445566778899aabbccddeeff 1 250 1236
t "N1 fresh disk log with a LAN address, self-test, auto-return note, back after 21 min -> BOOTED (network), auto-return" 0 "VERDICT: MODERN KERNEL BOOTED (how far: network): Linux 6.12.112 ran on this box from RAM, its userspace came up and it was on the LAN. Evidence: the disk log on sda3 is FRESH (last snapshot at trial uptime 1236 s, run id in it: this); the trial held 192.0.2.137/24 on br-lan; the self-test was written; the auto-return note is in the log (it rebooted to stock by itself); stock started again 12[0-9][0-9] s after the launch line: that is the trial's own 20-minute auto-return\.$" V
t "N1 the digest shows the trail, the notes and the self-test" 0 "   \[    21.00\] link is up on eth1" V
t "N1 ssh server and self-test are reported" 0 "LAN addresses: 192.0.2.137/24 on br-lan · ssh server running: yes · self-test written: yes · auto-return note: yes" V
nt "N1 no watchdog remark on a 20-minute run" "watchdog very likely cut\|HAD taken the watchdog" V
dlog sda3 "$W/p-static.txt" 00112233445566778899aabbccddeeff 1 251 1240
t "N2 the trial held OpenWrt's default static address -> loud warning (the overlay's network setup did not apply)" 0 "disk log: WARNING: the trial held $OWD" V
dlog sda3 "$W/p-nonet.txt" 00112233445566778899aabbccddeeff 1 252 1244
echo "LAN-WITNESS run=$RUN reached=ssh ip=192.0.2.137 token=yes at=2026-11-16T22:05:00" > "$W/b/logs/lan-witness-1.txt"
t "N3 no address in the disk log, but the LAN witness says ssh reached it -> BOOTED (network)" 0 "VERDICT: MODERN KERNEL BOOTED (how far: network): .*ssh from the LAN reached it (LAN-WITNESS run=$RUN reached=ssh ip=192.0.2.137" V
echo "LAN-WITNESS run=4-other reached=ssh ip=192.0.2.137" > "$W/b/logs/lan-witness-1.txt"
t "N4 a LAN witness for another run does not count" 0 "VERDICT: MODERN KERNEL BOOTED (how far: userspace)" V
echo "LAN-WITNESS run=$RUN reached=ping ip=192.0.2.137" > "$W/b/logs/lan-witness-1.txt"
t "N5 ping only: said, still userspace" 0 "VERDICT: MODERN KERNEL BOOTED (how far: userspace): .*a candidate host answered ping on the LAN but the trial key did not get in: not proof" V
rm -f "$W/b/logs/lan-witness-1.txt"
dlog sda3 "$W/p-notok.txt" 00112233445566778899aabbccddeeff 1 253 1250
t "N6 a fresh log whose command line has no run id still counts (fresh = written after the jump); said as unknown" 0 "VERDICT: MODERN KERNEL BOOTED (how far: network): .*run id in it: unknown" V
# ---- the rest ----
echo "99999.00 9.00" > "$W/proc/uptime"
t "I1 this kernel is older than the launch -> INCONCLUSIVE" 0 "VERDICT: INCONCLUSIVE: this kernel started BEFORE the newest launch" V
setgap 1290 30.00; onestart
t "S1 one start of stock in between -> NOTE after the verdict" 0 "VERDICT: MODERN KERNEL BOOTED .*NOTE: stock's start ledger counts 1 start(s) of stock's userland between the launch and this boot" V
echo 4242 > "$W/hd_a4/db/$(hostname).pid"; mkdir -p "$W/proc/4242"; printf '/usr/libexec/mysqld\0--basedir=/usr\0' > "$W/proc/4242/cmdline"
nt "S2 the same start, but it is this boot's own database -> no NOTE" "NOTE: stock's start ledger" V
echo "$DEF ex4boot_run=3-l2off-20261116-2040" > "$W/proc/cmdline"
t "S3 stock's own command line holds a bundle-v2 token -> noted, verdict unchanged" 0 "note: [^ ]*/proc/cmdline holds ex4boot_run=3-l2off-20261116-2040: THIS kernel was started by an ex4boot jump" V
echo "$DEF" > "$W/proc/cmdline"
# no jump on record / hung: the words MODERN KERNEL BOOTED never appear
newdisks; MEM="$W/none.img"
for m in "$W/none.img" "$W/acH.img" "$W/a.img" "$W/ring-other.img"; do MEM=$m; nt "X1 no ring of this run, no fresh disk log, no witness: the words MODERN KERNEL BOOTED never appear ($(basename "$m"))" "MODERN KERNEL BOOTED" V; done
# ---- log / klog / marker ----
MEM="$W/ring-user.img"; dlog sdc3 "$W/p-net.txt" 00112233445566778899aabbccddeeff 2 9 80
t "L1 log: prints the fresh disk log in full" 0 "NEWEST-TRIAL-LINE" R log
t "L1 log: FRESH against the pre-jump state of the newest launch" 0 "DISK sdc3: FRESH: written after the last jump (before: state none)" R log
t "L1 log: the RAM ring is found and saved" 0 "RAM: saved to .*klog-" R log
t "L2 klog alone" 0 "RESULT: 1 log buffer(s) found" R klog
MEM="$W/acH.img"
t "L3 marker alone" 0 "MARKER ONLY: read-only" R marker
t "L3 marker reports this run's markers" 0 "MARKER pos=0 at=0x00001000 run=$RUN state=INTACT" R marker
# ---- THE FAN (v4): the verdict's FAN line ----
setgap 1290 30.00; MEM="$W/none.img"; rm -f "$W/b/logs"/lan-witness-*.txt "$W/b/logs"/early-klog-*.txt
fanpayload() { o=$1; shift; payload "$o.base" "$RUN" "192.0.2.137/24" "self wdt"; { cat "$o.base"; for l in "$@"; do echo "$l"; done; } > "$o"; }
ST1='ex4fan: status up=60 level=3(HIGH) acked=1 rpm=2610 tach=ok drives=sda:40,sdb:41,sdc:41,sdd:43 main=50 sata=47 soc=57 T=43 micro=answers frames_in=9 acks=5 cmds=5/5 other=0'
ST2='ex4fan: status up=120 level=2(MEDIUM) acked=1 rpm=1790 tach=ok drives=sda:40,sdb:41,sdc:41,sdd:42 main=50 sata=47 soc=56 T=42 micro=answers frames_in=14 acks=8 cmds=8/8 other=0'
dlog sda3 "$W/p-net.txt" 00112233445566778899aabbccddeeff 1 300 1236
t "F0 a fresh disk log without one ex4fan line -> FAN: no ex4fan line on record" 0 "FAN: no ex4fan line on record for run $RUN" V
fanpayload "$W/p-fan1.txt" "<12>[    4.100000] ex4fan: start pid=68" "<12>[    4.200000] ex4fan: cmd FAN=3(HIGH) ack=1 tries=1 why=start: first action" \
	"Tue Nov 17 07:40:00 2026 user.warn kernel: [    4.100000] ex4fan: start pid=68" "Tue Nov 17 07:40:00 2026 user.warn kernel: [    4.200000] ex4fan: cmd FAN=3(HIGH) ack=1 tries=1 why=start: first action" \
	"<12>[   64.000000] $ST1" "<12>[   70.000000] ex4fan: cmd FAN=2(MEDIUM) ack=1 tries=1 why=curve (T=43)" "<12>[  124.000000] $ST2"
dlog sda3 "$W/p-fan1.txt" 00112233445566778899aabbccddeeff 1 301 1237
t "F1 normal run: rpm range, the last reading, ACK count, no fail-safe" 0 "^FAN: rpm seen: 1790 to 2610 · last reading: level=2(MEDIUM) drives=sda:40,sdb:41,sdc:41,sdd:42 main=50 sata=47 soc=56 T=42 · fan commands ACKed by the micro: 2 of 2 · fail-safe reboot: none\$" V
t "F1 the same kernel line in dmesg and in logread is counted once (1 start, 5 lines)" 0 "^-- fan: 5 ex4fan line(s) in the fresh disk log on sda3 (.*); the daemon started 1 time(s), worker crashes: 0\$" V
t "F1 first and last command are shown" 0 "^fan: first command: cmd FAN=3(HIGH) ack=1 tries=1 why=start: first action\$" V
t "F1 the verdict's evidence names the fan" 0 "VERDICT: MODERN KERNEL BOOTED (how far: network): .* ex4fan ran (see the FAN line);" V
fanpayload "$W/p-fan2.txt" "<12>[    4.100000] ex4fan: start pid=68" "<12>[    4.200000] ex4fan: cmd FAN=3(HIGH) ack=1 tries=1 why=start: first action" "<12>[   64.000000] $ST1" \
	"<12>[   94.000000] ex4fan: FAILSAFE reason=drive-hot sdd=56C (limit 55, read twice) -> fan MAX, then reboot (back to the stock system, which runs its own fan)" "<12>[   94.100000] ex4fan: cmd FAN=4(MAX) ack=1 tries=1 why=fail-safe"
dlog sda3 "$W/p-fan2.txt" 00112233445566778899aabbccddeeff 1 302 100
t "F2 a fail-safe reboot is named with its reason" 0 "^FAN: rpm seen: 2610 to 2610 · .* · fan commands ACKed by the micro: 2 of 2 · fail-safe reboot: drive-hot sdd=56C (limit 55, read twice)\$" V
t "F2 and the verdict's evidence says the fail-safe rebooted the trial" 0 "VERDICT: MODERN KERNEL BOOTED (how far: network): .* ex4fan's FAIL-SAFE rebooted the trial (drive-hot sdd=56C (limit 55, read twice));" V
fanpayload "$W/p-fan3.txt" "<12>[    4.100000] ex4fan: start pid=68" "<12>[    4.200000] ex4fan: cmd FAN=3(HIGH) ack=1 tries=1 why=start: first action" "<12>[    4.300000] ex4fan: tachometer: NOT readable (no GPIO line): the fan stays at HIGH or above, its rpm is unknown" \
	"<12>[   64.000000] ex4fan: status up=60 level=3(HIGH) acked=1 rpm=-1 tach=none drives=sda:40 main=50 sata=47 soc=57 T=40 micro=answers frames_in=9 acks=5 cmds=5/5 other=0"
dlog sda3 "$W/p-fan3.txt" 00112233445566778899aabbccddeeff 1 303 1238
t "F3 no tachometer: the rpm is called not readable, never 0" 0 "^FAN: rpm seen: not readable (no tachometer line) · last reading: level=3(HIGH) drives=sda:40 main=50 sata=47 soc=57 T=40 · fan commands ACKed by the micro: 1 of 1 · fail-safe reboot: none\$" V
fanpayload "$W/p-fan4.txt" "<12>[    4.100000] ex4fan: start pid=68" "<12>[    7.200000] ex4fan: cmd FAN=3(HIGH) ack=0 tries=10 why=start: first action" \
	"<12>[   34.100000] ex4fan: FAILSAFE reason=micro-never-answered: no valid frame in 30 s (40 frames sent) -> fan MAX, then reboot (back to the stock system, which runs its own fan)" "<12>[   37.200000] ex4fan: cmd FAN=4(MAX) ack=0 tries=10 why=fail-safe" \
	"<12>[   37.300000] ex4fan: status up=33 level=4(MAX) acked=0 rpm=0 tach=ok drives=sda:40 main=-1 sata=-1 soc=57 T=40 micro=silent frames_in=0 acks=0 cmds=0/4 other=0"
dlog sda3 "$W/p-fan4.txt" 00112233445566778899aabbccddeeff 1 304 44
t "F4 a micro that never answered: 0 of 2 ACKed, rpm never above 0, the fail-safe's reason" 0 "^FAN: rpm seen: never above 0 · last reading: level=4(MAX) drives=sda:40 main=-1 sata=-1 soc=57 T=40 · fan commands ACKed by the micro: 0 of 2 · fail-safe reboot: micro-never-answered: no valid frame in 30 s (40 frames sent)\$" V
# from the RAM ring (no fresh disk log): put sda3 back to the state the launch recorded, then a ring of this run with fan lines
python3 -I -c 'import sys; open(sys.argv[1],"wb").write(bytes(4<<20))' "$W/dev/sda3"
ring "$W/r-fan.txt" "$RUN" "orion_wdt: Initial timeout 21 sec" "Run /init as init process" "ex4log: daemon started (bundle-v1), pid 412" "ex4fan: start pid=68" "ex4fan: cmd FAN=3(HIGH) ack=1 tries=1 why=start: first action" "$ST1"
mem "$W/ring-fan.img" "ring:$W/r-fan.txt@1495a58"; MEM="$W/ring-fan.img"
t "F5 no fresh disk log, the ring of this run holds ex4fan lines -> FAN from the ring" 0 "^FAN: rpm seen: 2610 to 2610 · last reading: level=3(HIGH) drives=sda:40,sdb:41,sdc:41,sdd:43 main=50 sata=47 soc=57 T=43 · fan commands ACKed by the micro: 1 of 1 · fail-safe reboot: none\$" V
t "F5 it says where the lines came from" 0 "^-- fan: 3 ex4fan line(s) in the trial kernel's log ring" V
ring "$W/r-fan-other.txt" "4-other-20261116-0000" "orion_wdt: Initial timeout 21 sec" "ex4fan: start pid=68" "$ST1"
mem "$W/ring-fan-other.img" "ring:$W/r-fan-other.txt@1495a58"; MEM="$W/ring-fan-other.img"
t "F6 ex4fan lines in a ring that names ANOTHER run do not count" 0 "^FAN: no ex4fan line on record for run $RUN" V
MEM="$W/none.img"
{ echo "LAN-WITNESS run=$RUN reached=ssh ip=192.0.2.101 mac=00:90:a9:00:00:50 token=yes at=2026-11-17T00:30:00 stock_back=not-seen rounds=9 kernel=6.12.112"
  echo "# the trial's /tmp/ex4fan.log as last read:"; echo "[     4.20] ex4fan: cmd FAN=3(HIGH) ack=1 tries=1 why=start: first action"; echo "[    64.00] $ST1"
  echo "# /tmp/ex4fan.status, one line per round of this watch:"; echo "00:31:20 $ST2"; } > "$W/b/logs/lan-witness-6.txt"
t "F7 no disk log, no ring, a LAN witness of this run with fan lines -> FAN from the witness" 0 "^FAN: rpm seen: 1790 to 2610 · last reading: level=2(MEDIUM) .* · fan commands ACKed by the micro: 1 of 1 · fail-safe reboot: none\$" V
t "F7 it says where the lines came from" 0 "^-- fan: 3 ex4fan line(s) in the LAN witness file" V
sed -i "1s/run=$RUN /run=4-other /" "$W/b/logs/lan-witness-6.txt"
t "F8 a LAN witness of another run does not count for the fan either" 0 "^FAN: no ex4fan line on record for run $RUN" V
rm -f "$W/b/logs/lan-witness-6.txt"
ls "$W/b/logs"/verdict-*.txt > /dev/null 2>&1 && { PASS=$((PASS+1)); echo "PASS  verdict copies are kept under logs/ ($(ls "$W/b/logs"/verdict-*.txt | wc -l))"; } || { FAIL=$((FAIL+1)); echo "FAIL  no verdict copy"; }
# ---- V5 (run 7): check's address line, the verdict's V5 lines ----
t "W0 check prints the addresses stock uses now (bond0, egiga0, egiga1) and what the trial will do" 0 "v5 MACs: stock now: bond0 00:90:a9:00:00:50, egiga0 00:90:a9:00:00:50, egiga1 00:90:a9:00:00:50. The trial reads the unit's own two addresses from flash (read-only): eth0 = the first, eth1 = the second, br-lan" R check
t "W0 check names the v5 additions (modules from the official image, the clock read, DeviceReady, events logged only)" 0 "v5 USB 3 / clock / panel: the overlay carries xhci-hcd + xhci-pci from the official OpenWrt image of the same release (KMODS.txt)" R check
rm -f "$W/b/KMODS.txt.keep"; mv "$W/b/KMODS.txt" "$W/b/KMODS.txt.keep"
t "W0 a bundle without KMODS.txt is refused" 1 "REFUSED: bundle file missing: KMODS.txt" R check
mv "$W/b/KMODS.txt.keep" "$W/b/KMODS.txt"
setgap 1290 30.00; MEM="$W/none.img"; rm -f "$W/b/logs"/lan-witness-*.txt "$W/b/logs"/early-klog-*.txt
ST5='ex4fan: status up=120 level=1(LOW) acked=1 rpm=1020 tach=ok drives=sda:39,sdb:39,sdc:41,sdd:38 main=49 sata=0 soc=53 T=41 micro=answers frames_in=40 acks=20 cmds=20/20 other=0 ready=acked events=2 clock=set'
v5self() {      # the six v5 blocks of the self-test, as the overlay's script prints them. $1 = eth1 mac, $2 = xhci driver ("" = unbound), $3 = "holes" for a link line with empty values
	echo "-- v5 macs (the unit's own two addresses, as WD's mac_read takes them from the 'rescue firmware' partition; br-lan asks for the lease)"
	echo "eth0 mac 00:90:a9:00:00:50 assign_type 3"; echo "eth1 mac $1 assign_type 3"; echo "br-lan mac 00:90:a9:00:00:50 assign_type 3"
	if [ "$1" = 00:90:a9:00:00:50 ]; then echo "NO /tmp/ex4-mac.txt: the MAC hook did not run"; else echo "source=flash (rescue firmware, block 0)"; echo "eth0 was=00:90:a9:00:00:50 now=00:90:a9:00:00:50 want=00:90:a9:00:00:50"; echo "eth1 was=00:90:a9:00:00:50 now=$1 want=$1"; echo "lan_mac=00:90:a9:00:00:50"; fi
	echo "-- v5 link (runs 5 and 6: eth1 lost and regained its link about once a second; these counters say whether it still does)"
	echo "eth0 carrier_changes 1 down_count 1 at_uptime 46.10 tx_dropped 0 tx_errors 0 phy_id 0x01410dd1 phy_interface rgmii-id phy_driver Marvell 88E1510"
	if [ "${3:-}" = holes ]; then echo "eth1 carrier_changes 43 down_count 21 at_uptime 46.12 tx_dropped 0 tx_errors 0 phy_id  phy_interface  phy_driver "
	else echo "eth1 carrier_changes 43 down_count 21 at_uptime 46.12 tx_dropped 7 tx_errors 0 phy_id 0x01410dd1 phy_interface rgmii-id phy_driver Marvell 88E1510"; fi
	echo "-- v5 usb3 (the Etron EJ168, PCI class 0x0c0330, needs xhci-pci: modules from the official zyxel_nsa325 image of the same release)"
	echo "xhci controller 0000:02:00.0 0x1b6f:0x7023 driver=$2"
	if [ -n "$2" ]; then echo "modules: xhci_pci xhci_plat_hcd xhci_hcd "; echo "usb device usb1 1d6b:0002 speed 480 Linux 6.12.112 ehci_hcd EHCI Host Controller"; echo "usb device usb2 1d6b:0002 speed 480 Linux 6.12.112 xhci-hcd xHCI Host Controller"; echo "usb device usb3 1d6b:0003 speed 5000 Linux 6.12.112 xhci-hcd xHCI Host Controller"
	else echo "modules: "; echo "usb device usb1 1d6b:0002 speed 480 Linux 6.12.112 ehci_hcd EHCI Host Controller"; fi
	echo "-- v5 clock (the SoC's own RTC has no crystal on this board; the front-panel micro keeps the time and ex4fan reads it)"
	echo "date: 2026-11-17 09:40:46 UTC rtc devices: "; echo "[    2.969301] rtc-mv f1010300.rtc: internal RTC not ticking"
	echo "[     6.31] clock: the micro says 2026-11-17 09:40:06 UTC (raw 06 40 09 03 17 11 26 = sec min hour dow day month year, BCD); the system clock says 6; micro - system = +1794908400 s"
	echo "[     6.31] clock: the system clock was unset (6): SET from the micro's clock to 2026-11-17 09:40:06 UTC (NTP corrects it later if it can)"
	echo "-- v5 front panel (ex4fan: WD's DeviceReady; the micro's own events are logged only)"
	echo "[    14.02] cmd READY (WD's DeviceReady) ack=1 tries=1 (try 1 of 2)"; echo "[    90.10] event PWR: power button (frame 21 00 00 00 00): logged only, no action"; echo "[    95.40] event UsbBackupPush: USB copy button (frame 26 00 00 01 00): logged only, no action"
	echo "-- v5 hwmon names"; echo "hwmon0 f1072004.mdio-mii:00 temp1 31000 device f1072004.mdio-mii:00"
	echo "-- watchdog"; echo "/dev/watchdog"
}
v5payload() { o=$1; shift; payload "$o.base" "$RUN" "192.0.2.101/24" "self wdt"
	{ awk '/^== bays seen/ { exit } { print }' "$o.base"; v5self "$@"; echo "== bays seen: 4 of 4 =="; awk 'f { print } /^== bays seen/ { f = 1 }' "$o.base"
	  echo "<12>[    4.100000] ex4fan: start pid=68"; echo "<12>[    4.200000] ex4fan: cmd FAN=3(HIGH) ack=1 tries=1 why=start: first action"; echo "<12>[  124.000000] $ST5"; } > "$o"; }
dlog sda3 "$W/p-net.txt" 00112233445566778899aabbccddeeff 1 400 1236
t "W1 a fresh disk log whose self-test has no v5 block -> V5: no v5 self-test on record" 0 "^V5: no v5 self-test on record for run $RUN" V
v5payload "$W/p-v5a.txt" 00:90:a9:00:00:51 xhci_hcd
dlog sda3 "$W/p-v5a.txt" 00112233445566778899aabbccddeeff 1 401 1237
t "W2 MACs: both ports, br-lan, distinct, the lease's address, the source" 0 "^V5 MACS: eth0 00:90:a9:00:00:50 · eth1 00:90:a9:00:00:51 · br-lan 00:90:a9:00:00:50 · the two ports differ: yes · br-lan (the lease) carries eth0's, the unit's first: yes · source: flash (rescue firmware, block 0)\$" V
t "W2 USB 3: the controller, its driver, the modules, the USB devices" 0 "^V5 USB3: xHCI controller: 0000:02:00.0 0x1b6f:0x7023 driver=xhci_hcd · bound to a driver: 1 of 1 · modules loaded: xhci_pci xhci_plat_hcd xhci_hcd · USB devices listed: 3 (usb1 1d6b:0002 speed 480 Linux 6.12.112 ehci_hcd EHCI Host Controller; usb2 .*; usb3 1d6b:0003 speed 5000 .*)\$" V
t "W2 clock: what the micro said, that the system clock was set from it, the self-test's date" 0 "^V5 CLOCK: the micro says 2026-11-17 09:40:06 UTC (raw 06 40 09 03 17 11 26 = sec min hour dow day month year, BCD); the system clock says 6; micro - system = +1794908400 s · system clock set from the micro: yes · the self-test's date: 2026-11-17 09:40:46 UTC rtc devices:\$" V
t "W2 panel: DeviceReady's ACK, the events by name, ex4fan's last state" 0 "^V5 PANEL: cmd READY (WD's DeviceReady) ack=1 tries=1 (try 1 of 2) · events from the micro (logged only, no action): PWR UsbBackupPush · ex4fan's last state: ready=acked events=2 clock=set\$" V
t "W2 link: the cabled port's flap counter as a rate, its PHY, its tx counters" 0 "^V5 LINK: eth1: 43 carrier changes in 46.12 s of uptime (56 a minute), PHY id 0x01410dd1 driver Marvell 88E1510 interface rgmii-id, tx_dropped 7 tx_errors 0 · eth0: 1 carrier changes in 46.10 s of uptime (1 a minute), PHY id 0x01410dd1 driver Marvell 88E1510 interface rgmii-id, tx_dropped 0 tx_errors 0\$" V
t "W2 the FAN line still reads the same disk log, with the v5 state line" 0 "^FAN: rpm seen: 1020 to 1020 · last reading: level=1(LOW) drives=sda:39,sdb:39,sdc:41,sdd:38 main=49 sata=0 soc=53 T=41 · fan commands ACKed by the micro: 1 of 1 · fail-safe reboot: none\$" V
t "W2 the verdict's evidence names the v5 self-test" 0 "VERDICT: MODERN KERNEL BOOTED (how far: network): .* ex4fan ran (see the FAN line); the v5 self-test is on record (see the V5 lines);" V
v5payload "$W/p-v5b.txt" 00:90:a9:00:00:50 "" holes
dlog sda3 "$W/p-v5b.txt" 00112233445566778899aabbccddeeff 1 402 1238
t "W3 the hook did not run and both ports carry one address: the line says NO" 0 "^V5 MACS: eth0 00:90:a9:00:00:50 · eth1 00:90:a9:00:00:50 · br-lan 00:90:a9:00:00:50 · the two ports differ: NO · br-lan (the lease) carries eth0's, the unit's first: yes · source: the MAC hook did not run\$" V
t "W3 a controller without a driver: 0 of 1 bound, no modules, one USB device" 0 "^V5 USB3: xHCI controller: 0000:02:00.0 0x1b6f:0x7023 driver= · bound to a driver: 0 of 1 · modules loaded: none · USB devices listed: 1 (usb1 .*)\$" V
t "W3 a link line with empty values (no PHY attached) is still read by its keys" 0 "^V5 LINK: eth1: 43 carrier changes in 46.12 s of uptime (56 a minute), PHY id ? driver ? interface ?, tx_dropped 0 tx_errors 0 · eth0: " V
# ---- V6 (run 8): the flash layout, the PHY driver, the link over 10 s ----
t "X0 check names the v6 changes (WD's own flash layout, both PHYs on the generic driver, still read-only)" 0 "v6 flash / link: the device tree in kernel.bin carries WD's own flash layout .* hands both Ethernet PHYs to the kernel's generic PHY driver .* Every flash partition is still read-only" R check
v6self() {      # the three v6 blocks of the self-test. $1 = good | bad (bad = what bundle-v5's tree and the Marvell driver gave in run 7)
	echo "-- v6 flash (WD's own layout, from the stock kernel's boot log: mtd4 'rescue firmware' at 0x0dd00000, mtd5 'config' at 0x0ec00000, mtd6 'reserve' at 0x0d800000)"
	echo "mtd0 offset 0x00000000 size 0x00100000 name u-boot"; echo "mtd1 offset 0x00100000 size 0x00500000 name uImage"; echo "mtd2 offset 0x00600000 size 0x00500000 name ramdisk"; echo "mtd3 offset 0x00b00000 size 0x0cd00000 name image"
	if [ "$1" = good ]; then echo "mtd4 offset 0x0dd00000 size 0x00f00000 name rescue firmware"; echo "mtd5 offset 0x0ec00000 size 0x01400000 name config"; echo "mtd6 offset 0x0d800000 size 0x00500000 name reserve"
	else echo "mtd4 offset 0x0d800000 size 0x00f00000 name rescue firmware"; echo "mtd5 offset 0x0e700000 size 0x01400000 name config"; echo "mtd6 offset 0x0fb00000 size 0x00500000 name reserve"; fi
	echo "-- v6 phy (the device tree hands both PHYs to the kernel's generic PHY driver: the Marvell driver's page flip on every poll was the link flap; ex4phy asks the chips themselves and writes nothing)"
	if [ "$1" = good ]; then echo "f1072004.mdio-bus-mii:00 phy_id 0x01410000 interface rgmii driver Generic PHY"; echo "f1072004.mdio-bus-mii:01 phy_id 0x01410000 interface rgmii driver Generic PHY"
		echo "eth0 phy addr 0 chip_id 0141.0dd1 page 0 bmcr 1140 bmsr 7949 status17 0000"; echo "eth1 phy addr 1 chip_id 0141.0dd1 page 0 bmcr 1140 bmsr 796d status17 ac08"
	else echo "f1072004.mdio-bus-mii:00 phy_id 0x01410dd1 interface rgmii driver Marvell 88E1510"; echo "f1072004.mdio-bus-mii:01 phy_id 0x01410dd1 interface rgmii driver "
		echo "eth0 phy none (SIOCGMIIPHY: Operation not supported)"; echo "eth1 phy addr 1 chip_id 0141.0dd1 page 1 bmcr 1140 bmsr 7949 status17 0000"; fi
	echo "-- v6 link (both ports' carrier_changes read twice, 10 s apart; runs 5 to 7: about 19 in 10 s on the cabled port)"
	if [ "$1" = good ]; then echo "eth0 changes_from 0 to 0 uptime_from 47.10 to 57.13 link_down_lines 0"; echo "eth1 changes_from 3 to 3 uptime_from 47.10 to 57.13 link_down_lines 1"
	else echo "eth0 changes_from ? to ? uptime_from 47.10 to 57.13 link_down_lines 0"; echo "eth1 changes_from 43 to 62 uptime_from 47.10 to 57.10 link_down_lines 31"; fi
}
v6payload() { o=$1; k=$2; payload "$o.base" "$RUN" "192.0.2.101/24" "self wdt"
	{ awk '/^== bays seen/ { exit } { print }' "$o.base"; v5self 00:90:a9:00:00:51 xhci_hcd | sed '$d' | sed '$d' | { if [ "${3:-}" = noclock ]; then grep -v "clock: "; else cat; fi; }; v6self "$k"; echo "-- watchdog"; echo "/dev/watchdog"; echo "== bays seen: 4 of 4 =="; awk 'f { print } /^== bays seen/ { f = 1 }' "$o.base"
	  echo "<12>[    4.100000] ex4fan: start pid=68"; echo "<12>[    4.200000] ex4fan: cmd FAN=3(HIGH) ack=1 tries=1 why=start: first action"; echo "<12>[  124.000000] $ST5"; } > "$o"; }
t "X1 a self-test with the v5 blocks but no v6 blocks (an older bundle's log) -> the V6 line says so" 0 "^V6: the self-test on record has no v6 blocks" V
v6payload "$W/p-v6a.txt" good
dlog sda3 "$W/p-v6a.txt" 00112233445566778899aabbccddeeff 1 403 1239
t "X2 flash: the three partitions WD does not keep in address order, at WD's own offsets, with WD's mtd numbers" 0 "^V6 FLASH: rescue firmware mtd4 at 0x0dd00000, config mtd5 at 0x0ec00000, reserve mtd6 at 0x0d800000 · WD's own layout (0x0dd00000 / 0x0ec00000 / 0x0d800000): yes\$" V
t "X2 PHY: the generic driver on both, the chips' own ids and page 0" 0 "^V6 PHY: f1072004.mdio-bus-mii:00 id 0x01410000 driver Generic PHY; f1072004.mdio-bus-mii:01 id 0x01410000 driver Generic PHY · the generic driver holds every PHY: yes (2 of 2) · asked from the chips: eth0 chip id 0141.0dd1 register page 0; eth1 chip id 0141.0dd1 register page 0 · both on register page 0: yes\$" V
t "X2 link: no carrier change in the 10 s between the two reads" 0 "^V6 LINK: eth1: 0 carrier changes in 10.0 s (0 a minute; counter 3 -> 3), link down lines in the kernel log: 1 · eth0: 0 carrier changes in 10.0 s (0 a minute; counter 0 -> 0), link down lines in the kernel log: 0\$" V
t "X2 the V5 lines are still there beside them" 0 "^V5 MACS: eth0 00:90:a9:00:00:50 · eth1 00:90:a9:00:00:51 " V
v6payload "$W/p-v6b.txt" bad
dlog sda3 "$W/p-v6b.txt" 00112233445566778899aabbccddeeff 1 404 1240
t "X3 flash: bundle-v5's layout (address order) is called out" 0 "^V6 FLASH: rescue firmware mtd4 at 0x0d800000, config mtd5 at 0x0e700000, reserve mtd6 at 0x0fb00000 · WD's own layout (0x0dd00000 / 0x0ec00000 / 0x0d800000): NO\$" V
t "X3 PHY: the Marvell driver on one, none on the other, a port without MII, a chip on page 1 -> NO twice" 0 "^V6 PHY: f1072004.mdio-bus-mii:00 id 0x01410dd1 driver Marvell 88E1510; f1072004.mdio-bus-mii:01 id 0x01410dd1 driver NONE · the generic driver holds every PHY: NO (0 of 2) · asked from the chips: eth0 phy none (SIOCGMIIPHY: Operation not supported); eth1 chip id 0141.0dd1 register page 1 · both on register page 0: NO\$" V
t "X3 link: run 7's flap as a rate, and a port whose counter could not be read" 0 "^V6 LINK: eth1: 19 carrier changes in 10.0 s (114 a minute; counter 43 -> 62), link down lines in the kernel log: 31 · eth0: ? carrier changes in 10.0 s (? a minute; counter ? -> ?), link down lines in the kernel log: 0\$" V
v6payload "$W/p-v6c.txt" good noclock
dlog sda3 "$W/p-v6c.txt" 00112233445566778899aabbccddeeff 1 405 1241
t "X4 no clock line of ex4fan on record: the verdict says unknown, not no (the review nit of bundle-v5)" 0 "^V5 CLOCK: no clock line on record · system clock set from the micro: unknown (no clock line on record) · the self-test's date: 2026-11-17 09:40:46 UTC rtc devices:\$" V
# ---- v8: the web interface's door in the SECURITY line, and the one LCD test frame ----
t "Y0 check names the v8 web interface and the one LCD test frame" 0 "v8 panel: ex4fan leaves the front screen alone (LCD Tier A off) and the self-test sends ONE LCD frame" R check
v8sec() {       # $1 = webui-good | webui-bad | loop   (the self-test's v8 security lines + the panel send-test block)
	echo "-- security (v8)"
	echo "security root_password_field locked_star (no password matches; the ssh key still works)"
	case "$1" in
	loop) echo "security uhttpd listen_http 127.0.0.1:80 listen_https none ubus_prefix none"; echo "security tcp_lan_ports 22"; echo "security udp_lan_ports 546"; echo "security webui no";;
	webui-good) echo "security uhttpd listen_http 0.0.0.0:80,[::]:80 listen_https 0.0.0.0:443,[::]:443 ubus_prefix /ubus"; echo "security tcp_lan_ports 22 80 443"; echo "security udp_lan_ports 546"; echo "security webui yes"
		echo "security http80 HTTP/1.1 307 Temporary Redirect location https://ex4/ubus"
		echo 'security ubus_anon_session_login {"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"Access denied"}}'
		echo 'security ubus_anon_ex4_status {"jsonrpc":"2.0","id":2,"error":{"code":-32002,"message":"Access denied"}}'
		echo 'security ubus_anon_setup_state {"jsonrpc":"2.0","id":3,"result":[0,{"claimed":false,"name":"ex4-trial"}]}'
		echo "security uhttpd_max_requests 16 redirect_https 1 home /www-ex4 rpcd_logins 0"
		echo "-- panel send-test (v8: ONE LCD frame)"; echo "send-test: ONE LCD frame (WD's SysName, text 'ex4-trial', 15 bytes, one try): ack=1 (the micro ACKed it) frame fa04010009657834"
		;;
	webui-bad) echo "security uhttpd listen_http 0.0.0.0:80 listen_https 0.0.0.0:443 ubus_prefix /ubus"; echo "security tcp_lan_ports 22 80 443 139"; echo "security udp_lan_ports 546"; echo "security webui yes"
		echo "security http80 HTTP/1.1 200 OK location "
		echo 'security ubus_anon_session_login {"jsonrpc":"2.0","id":1,"result":[0,{"ubus_rpc_session":"x"}]}'
		echo 'security ubus_anon_ex4_status {"jsonrpc":"2.0","id":2,"error":{"code":-32002,"message":"Access denied"}}'
		echo 'security ubus_anon_setup_state '
		echo "security uhttpd_max_requests 3 redirect_https 0 home /www rpcd_logins 1"
		echo "-- panel send-test (v8: ONE LCD frame)"; echo "send-test: no answer from ex4fan in 10 s (an older daemon, or not running)"
		;;
	esac
}
for v8k in webui-good webui-bad loop; do       # (not $k: v6payload sets k)
	v6payload "$W/p-v8$v8k.base" good
	awk '/^== bays seen/ { exit } { print }' "$W/p-v8$v8k.base" > "$W/p-v8$v8k.txt"; v8sec $v8k >> "$W/p-v8$v8k.txt"; awk 'f { print } /^== bays seen/ { f = 1; print }' "$W/p-v8$v8k.base" >> "$W/p-v8$v8k.txt"
done
dlog sda3 "$W/p-v8webui-good.txt" 00112233445566778899aabbccddeeff 1 420 1250
t "Y1 the web interface, door right: redirect, anonymous calls refused, unclaimed, no web login, ports 22 80 443" 0 "^SECURITY: root's password field: locked_star · uhttpd: listen_http 0.0.0.0:80,\[::\]:80 listen_https 0.0.0.0:443,\[::\]:443 ubus_prefix /ubus · TCP ports open on a LAN address: 22 80 443 · UDP: 546 · the web interface rode in: port 80 only redirects to https: yes · anonymous /ubus: session.login refused, ex4.status refused · setup state: unclaimed · web logins: 0 · LAN TCP ports 22 and 443 open and nothing but 22 / 80 / 443: yes\$" V
t "Y1 the one LCD test frame: the micro's ACK is in the verdict" 0 "^LCD TEST FRAME: ONE LCD frame (WD's SysName, text 'ex4-trial', 15 bytes, one try): ack=1 (the micro ACKed it) frame fa04010009657834\$" V
dlog sda3 "$W/p-v8webui-bad.txt" 00112233445566778899aabbccddeeff 1 421 1251
t "Y2 a door left open: no redirect, an anonymous login answered, a fourth LAN port -> NO and ANSWERED" 0 "· the web interface rode in: port 80 only redirects to https: NO · anonymous /ubus: session.login ANSWERED, ex4.status refused · setup state: no answer · web logins: 1 · LAN TCP ports 22 and 443 open and nothing but 22 / 80 / 443: NO\$" V
t "Y2 a self-test that asked for the frame and got no answer says so" 0 "^LCD TEST FRAME: no answer from ex4fan in 10 s (an older daemon, or not running)\$" V
dlog sda3 "$W/p-v8loop.txt" 00112233445566778899aabbccddeeff 1 422 1252
t "Y3 no web interface: v7's judgment (80 and 443 closed to the LAN)" 0 "^SECURITY: root's password field: locked_star · uhttpd: listen_http 127.0.0.1:80 listen_https none ubus_prefix none · TCP ports open on a LAN address: 22 · UDP: 546 · web ports 80 / 443 closed to the LAN: yes\$" V
nt "Y3 ... and no LCD TEST FRAME line when the self-test has no send-test block" "^LCD TEST FRAME" V
python3 -I -c 'import sys; open(sys.argv[1],"wb").write(bytes(4<<20))' "$W/dev/sda3"
{ echo "LAN-WITNESS run=$RUN reached=ssh ip=192.0.2.101 mac=00:90:a9:00:00:50 token=yes at=2026-11-17T01:40:00 stock_back=not-seen rounds=9 kernel=6.12.112"
  echo "# the trial's /tmp/ex4fan.log as last read:"; echo "[     4.20] ex4fan: cmd FAN=3(HIGH) ack=1 tries=1 why=start: first action"; echo "[   124.00] $ST5"
  echo "# the trial's self-test (/tmp/ex4-selftest.txt) as last read:"; v5self 00:90:a9:00:00:51 xhci_hcd; } > "$W/b/logs/lan-witness-7.txt"
t "W4 no disk log: the V5 lines come from the LAN witness (which carries the self-test)" 0 "^-- v5: from the trial's self-test and ex4fan lines in the LAN witness file" V
t "W4 ... with the same content" 0 "^V5 MACS: eth0 00:90:a9:00:00:50 · eth1 00:90:a9:00:00:51 · br-lan 00:90:a9:00:00:50 · the two ports differ: yes " V
t "W4 ... and the panel line reads ex4fan's state from the witness" 0 "^V5 PANEL: cmd READY (WD's DeviceReady) ack=1 tries=1 (try 1 of 2) · events from the micro (logged only, no action): PWR UsbBackupPush · ex4fan's last state: ready=acked events=2 clock=set\$" V
sed -i "1s/run=$RUN /run=4-other /" "$W/b/logs/lan-witness-7.txt"
t "W5 a LAN witness of another run does not count for the V5 lines" 0 "^V5: no v5 self-test on record for run $RUN" V
rm -f "$W/b/logs/lan-witness-7.txt"
# the newest snapshot written during the shutdown (no address in its `ip addr`), the self-test in it holding the address (run 6's nit)
payload "$W/p-late.base" "$RUN" "" "self wdt"
awk '/^processes:/ { sub(/ 901:\/usr\/sbin\/dropbear/, "") } { print } /^kernel: 6.12.112  board: wd,mycloud-ex4/ { print "-- network"; print "eth0 mac 00:90:a9:00:00:50 carrier 0 speed -1"; print "    inet 127.0.0.1/8 scope host lo"; print "    inet 192.0.2.101/24 brd 192.0.2.255 scope global br-lan"; print "-- usb" }' "$W/p-late.base" > "$W/p-late.txt"
dlog sda3 "$W/p-late.txt" 00112233445566778899aabbccddeeff 1 410 1330
t "W6 a last snapshot without an address (written during the shutdown), the self-test in it with one -> how far: network, and the line says where the address is from" 0 "VERDICT: MODERN KERNEL BOOTED (how far: network): .* the trial held 192.0.2.101/24 on br-lan (as the self-test in this log recorded it about 45 s after boot; the newest snapshot itself holds no address" V
t "W6 ... and its ssh field does not say a flat no: a snapshot written while shutting down proves nothing about ssh (run 6 and 8 nit)" 0 "ssh server running: not in the newest snapshot (written while shutting down, so its no proves nothing: the LAN witness below decides)" V
dlog sda3 "$W/p-nonet.txt" 00112233445566778899aabbccddeeff 1 411 1331
t "W6 no address in the snapshot and no self-test in the log -> still how far: userspace" 0 "VERDICT: MODERN KERNEL BOOTED (how far: userspace)" V
python3 -I -c 'import sys; open(sys.argv[1],"wb").write(bytes(4<<20))' "$W/dev/sda3"
[ "$(grep -c 'vd "V5 ' "$SH")" = 5 ] && [ "$(grep -c 'vd "V5: no v5 self-test' "$SH")" = 1 ] && { PASS=$((PASS+1)); echo "PASS  static: the verdict prints five V5 lines (MACS, USB3, CLOCK, PANEL, LINK) or the one 'no v5 self-test' line"; } || { FAIL=$((FAIL+1)); echo "FAIL  static: V5 lines"; }
# ---- static checks on the REAL script ----
l=$(grep -n 'vd "VERDICT: MODERN KERNEL BOOTED' "$SH" | cut -d: -f1)
g=$(awk -v l="$l" 'NR < l && /^\telif \[ "\$FAR" != none \]; then$/ {g = NR} END {print g}' "$SH"); e=$(awk -v g="$g" -v l="$l" 'NR > g && NR < l && /^\t(elif|else|fi)/ {n++} END {print n + 0}' "$SH")
[ "$(grep -c 'vd "VERDICT: MODERN KERNEL BOOTED' "$SH")" = 1 ] && [ -n "$g" ] && [ "$e" = 0 ] && { PASS=$((PASS+1)); echo "PASS  static: the one line that prints VERDICT: MODERN KERNEL BOOTED (line $l) sits inside 'elif [ \"\$FAR\" != none ]' (line $g) with no elif/else/fi between"; } || { FAIL=$((FAIL+1)); echo "FAIL  static: MODERN KERNEL BOOTED guard (line $l, guard $g, branches between $e)"; }
f=$(grep -n '^[[:space:]]*\[.*\] && FAR=\|^[[:space:]]*FAR=' "$SH" | grep -v 'FAR=none$' | grep -v '\$KERN = 1 \] && FAR=kernel\|\$KUSER = 1 \] && FAR=userspace\|\$FRESH = 1 \] && FAR=userspace\|\$FRESH = 1 \] && \[ -n "\$DINET" \] && FAR=network\|"\$LAN" = ssh \] && FAR=network' | wc -l)
[ "$f" = 0 ] && [ "$(grep -c 'FAR=' "$SH")" = 6 ] && { PASS=$((PASS+1)); echo "PASS  static: FAR leaves 'none' only through the ring of this run (KERN, KUSER), a FRESH disk log, or an ssh LAN witness (5 lines)"; } || { FAIL=$((FAIL+1)); echo "FAIL  static: FAR is set somewhere else ($f stray, $(grep -c 'FAR=' "$SH") assignments)"; }
grep -q '\$((' "$SH" && { FAIL=$((FAIL+1)); echo "FAIL  static: shell arithmetic in the script (the stock sh has none)"; } || { PASS=$((PASS+1)); echo "PASS  static: no \$(( )) anywhere in the script"; }
grep -v '^[[:space:]]*#' "$SH" | grep -q '\\|' && { FAIL=$((FAIL+1)); echo "FAIL  static: a GNU-only \\| alternation outside comments"; } || { PASS=$((PASS+1)); echo "PASS  static: no \\| alternation outside comments (only awk does alternation: awk is what is proven on the stock busybox)"; }
if grep -v '^[[:space:]]*#' "$SH" | grep -v 'dd if=/dev/mtd1 bs=\$WANT_UIMAGE_LEN count=1 2>/dev/null | busybox md5sum' \
	| grep -v 'grep -q "^/dev/\${d}3 " /proc/mounts && die\|grep -q "^/dev/\${d}3 " /proc/swaps && die\|log gate: /dev/\${d}3 is\|\[ -b "/dev/\${d}3" \] || continue\|echo "\${d}3 \$("\$D/ex4log" read "/dev/\${d}3" --state 2>&1)"\|"\$D/ex4log" read "/dev/\$part" --save ' \
	| sed 's#/dev/null##g; s#read-only /dev/mem##g' | grep -n '/dev/\|nandwrite\|flash_erase\|ubiformat\|ubiupdatevol\|ubimkvol\|mkfs\|fdisk\|parted\|mdadm\|^[[:space:]]*reboot\|[;&|] *reboot\|ifconfig .* up\|udhcpc\| dd of=\|> */dev'; then FAIL=$((FAIL+1)); echo "FAIL  static: a line that names a device, a flash or disk tool, reboot or a network change"; else PASS=$((PASS+1)); echo "PASS  static: outside comments the script names no /dev node except /dev/null, the read-only md5 of /dev/mtd1, the log gate's /proc greps and messages, and sdX3 as the argument of 'ex4log read' (O_RDONLY); no flash tool, disk tool, mdadm or reboot"; fi
[ "$(grep -c 'ex4boot\.ko' "$SH")" = 0 ] && grep -q '^KO=ex4boot-l2off.ko$' "$SH" && { PASS=$((PASS+1)); echo "PASS  static: the script knows one module, ex4boot-l2off.ko (the L2-on module is not named anywhere)"; } || { FAIL=$((FAIL+1)); echo "FAIL  static: module name"; }
echo "trial-logic: $PASS passed, $FAIL failed   (shell: $SHELL_ -> $(readlink -f "$(command -v "$SHELL_")"); awk: $AWKNOTE)"
[ $FAIL = 0 ]
