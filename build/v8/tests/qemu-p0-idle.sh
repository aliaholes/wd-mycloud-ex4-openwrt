#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# qemu-p0-idle.sh (v8 = v7 + THE HONEST NUMBER). v7 quoted `free`'s "used" (19.5 MB), which does not count the RAM the
# trial's root file system itself takes (an initramfs is a tmpfs: "Shmem", ~60 MB) and went DOWN while services started
# (the v7 image review's nit 1). v8 also records, per snapshot, the sum of every process's Pss (proportional: a shared
# library page counted once, split between its users; /proc/PID/smaps_rollup) and prints three numbers:
#   honest-high = sum of VmRSS + Shmem   (over-counts shared pages; what the review asked for)
#   honest      = sum of Pss   + Shmem   (the processes' real share + the RAM-disk root)
#   installed   = sum of Pss              (what the same services would take with the root file system on a disk)
# With the web interface in the overlay, uhttpd (TLS) and rpcd (with ex4.uc loaded) are among the processes.
# Below: v7's header.
# qemu-p0-idle.sh (v7): memory of the v7 image's P0 services at idle, measured in qemu. Boots the e2e test kernel
# (tests/e2e-kernel.defconfig, versatilepb) with the v7 image's REAL userspace + the bundle's overlay + a third,
# test-only archive whose S99 script waits for the boot to settle, records `free` and every process's VmRSS, starts
# every P0 service that can run on this kernel against EMPTY tmpfs shares (smbd, wsdd2, avahi, rpcbind + the kernel
# nfsd, smartd is already up), waits 60 s, records again, and prints both between markers on the serial console.
# The fake front-panel micro of the e2e answers on the second serial port, so ex4fan runs as on the box.
# What it does NOT measure: CPU (qemu's TCG is not the EX4's core); ksmbd (the test kernel has no ksmbd, and the
# image's modules are built for the kirkwood kernel); anything about real disks or md.
#   sh qemu-p0-idle.sh <zImage> <e2e dtb> <rootfs dir> <overlay.cpio> <fake_mcu_sock.py> <workdir> [seconds, default 420]
set -eu
Z=$1; DTB=$2; ROOT=$3; OVL=$4; MCU=$5; W=$6; SECS=${7:-420}
[ -e "$W" ] && { echo "REFUSED: $W exists"; exit 1; }
mkdir -p "$W/t/etc/rc.d" "$W/t/usr/sbin"; W=$(cd "$W" && pwd)
cat > "$W/t/usr/sbin/ex4-p0-measure" <<'M'
#!/bin/sh
# TEST ONLY (qemu-p0-idle.sh)
snap() {
	echo "== $1 $(cut -d' ' -f1 /proc/uptime)"
	free
	grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Shmem|Slab|SReclaimable|SUnreclaim|KernelStack|PageTables|AnonPages):' /proc/meminfo
	T=0; PT=0
	for d in /proc/[0-9]*; do
		r=$(awk '/^VmRSS:/{print $2}' $d/status 2>/dev/null); [ -n "$r" ] || continue
		n=$(awk '/^Name:/{print $2}' $d/status 2>/dev/null)
		p=$(awk '/^Pss:/{print $2}' $d/smaps_rollup 2>/dev/null); [ -n "$p" ] || p=0
		echo "rss ${d#/proc/} $n $r pss $p"; T=$((T + r)); PT=$((PT + p))
	done
	echo "rss-total-kB $T"
	echo "pss-total-kB $PT"
	echo "listen-tcp $(awk 'NR>1 && $4=="0A" {print $2}' /proc/net/tcp /proc/net/tcp6 | sort -u | tr '\n' ' ')"
}
(
	sleep 40
	{ echo "EX4-P0-BEGIN"; snap before; } > /dev/console 2>&1
	mkdir -p /mnt/p0share && mount -t tmpfs -o size=16m tmpfs /mnt/p0share
	cat > /tmp/p0-smb.conf <<C
[global]
  server min protocol = SMB2_10
  map to guest = bad user
  disable netbios = yes
  load printers = no
  use sendfile = yes
  min receivefile size = 16384
[p0]
  path = /mnt/p0share
  guest ok = yes
  read only = yes
  vfs objects = catia fruit streams_xattr
C
	{
		mkdir -p /var/lib/samba/private /var/cache/samba /var/run/samba /var/log/samba /var/lock
		echo "start smbd: $(nice -n 10 smbd -D -s /tmp/p0-smb.conf -l /var/log/samba 2>&1; echo rc=$?)"
		sleep 10; echo "smbd: $(pidof smbd || { echo not-running; tail -20 /var/log/samba/log.smbd 2>/dev/null; })"
		echo "start wsdd2: $(wsdd2 -w -N EX4 -G WORKGROUP -d 2>&1; echo rc=$?)"
		echo "start avahi: $(/etc/init.d/avahi-daemon start 2>&1; echo rc=$?)"
		echo "start rpcbind: $(/etc/init.d/rpcbind start 2>&1; echo rc=$?)"
		echo "/mnt/p0share *(ro,no_subtree_check,fsid=1)" > /etc/exports
		echo "start nfsd: $(/etc/init.d/nfsd start 2>&1; echo rc=$?)"
		echo "smartd: $(pidof smartd || echo not-running)"
	} > /dev/console 2>&1
	sleep 60
	{ snap after; echo "EX4-P0-END"; } > /dev/console 2>&1
) &
M
chmod 755 "$W/t/usr/sbin/ex4-p0-measure"
ln -s ../../usr/sbin/ex4-p0-measure "$W/t/etc/rc.d/S99zzp0measure"
( cd "$ROOT" && find . | cpio -o -H newc -R 0:0 --quiet ) > "$W/initrd.cpio"
cat "$OVL" >> "$W/initrd.cpio"
( cd "$W/t" && find . | cpio -o -H newc -R 0:0 --quiet ) >> "$W/initrd.cpio"
python3 -I -c 'import sys
with open(sys.argv[1],"wb") as f: f.write(b"\xff" * (64 << 20))' "$W/flash.img"
python3 -I "$MCU" "$W/mcu.sock" "$W/mcu.json" --secs "$SECS" > "$W/mcu.log" 2>&1 &
MP=$!
timeout $((SECS + 30)) qemu-system-arm -M versatilepb -cpu arm926 -m 256 -display none -no-reboot \
	-kernel "$Z" -dtb "$DTB" -initrd "$W/initrd.cpio" -append "console=ttyAMA0,115200" \
	-drive if=pflash,format=raw,file="$W/flash.img" \
	-chardev null,id=nul0 -device pci-serial,chardev=nul0 \
	-chardev socket,id=mcu,path="$W/mcu.sock",server=on,wait=off -device pci-serial,chardev=mcu \
	-nic user,mac=52:54:00:e4:00:01 \
	-serial file:"$W/serial.log" > "$W/qemu.log" 2>&1 &
QP=$!
T0=$(date +%s)
while [ $(( $(date +%s) - T0 )) -lt "$SECS" ]; do
	grep -q EX4-P0-END "$W/serial.log" 2>/dev/null && break
	kill -0 $QP 2>/dev/null || break
	sleep 5
done
kill $QP 2>/dev/null || true; kill $MP 2>/dev/null || true; wait 2>/dev/null || true
sed -n '/EX4-P0-BEGIN/,/EX4-P0-END/p' "$W/serial.log" > "$W/p0.txt"
grep -q EX4-P0-END "$W/p0.txt" || { echo "FAIL: no measurement on the console (see $W/serial.log)"; exit 1; }
python3 -I - "$W/p0.txt" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
for part in ("before", "after"):
    blk = t.split("== " + part, 1)[1].split("== ", 1)[0] if ("== " + part) in t else ""
    m = re.search(r"Mem:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", blk)
    tot = re.search(r"rss-total-kB (\d+)", blk)
    pss = re.search(r"pss-total-kB (\d+)", blk)
    shm = re.search(r"^Shmem:\s+(\d+) kB", blk, re.M)
    procs = re.findall(r"^rss \d+ (\S+) (\d+)(?: pss \d+)?$", blk, re.M)
    print(f"{part}: free used {m.group(2) if m else '?'} kB, shared {m.group(4) if m else '?'} kB, sum of VmRSS {tot.group(1) if tot else '?'} kB over {len(procs)} processes")
    if tot and pss and shm:
        r_, p_, s_ = int(tot.group(1)), int(pss.group(1)), int(shm.group(1))
        print(f"  HONEST {part}: honest-high (VmRSS {r_} + tmpfs root {s_}) = {(r_ + s_) / 1024:.1f} MiB; honest (Pss {p_} + tmpfs root {s_}) = {(p_ + s_) / 1024:.1f} MiB; installed (Pss alone) = {p_ / 1024:.1f} MiB; the bar is 64 MB")
    print("  " + ", ".join(f"{n} {r}" for n, r in sorted(procs, key=lambda x: -int(x[1]))[:14]))
print([l for l in t.splitlines() if l.startswith(("start ", "smartd:", "smbd:", "listen-tcp"))])
PY
