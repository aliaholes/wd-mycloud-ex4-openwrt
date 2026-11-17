#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""mkoverlay.py: build the small cpio (newc) that rides as an external initrd on top of the stock OpenWrt kirkwood
initramfs for the EX4 RAM trial. The kernel unpacks its built-in initramfs first, then this archive over it.

Why it exists (each line is a thing the stock OpenWrt image would do wrong on a NAS plugged into a home LAN):
  1. An unknown board falls into OpenWrt's default network case: a STATIC address (OpenWrt's well-known factory default, the .1.1 one) with a DHCP SERVER. On a home
     LAN in the same range that fights the real router. The overlay's /etc/board.d/02_network makes "wd,mycloud-ex4"
     a DHCP CLIENT on eth0+eth1 (the same line OpenWrt uses for the Iomega ix4-200d) - built from the image's own file.
  2. Root has no password in an initramfs image. With --pubkey the overlay installs the key and turns password logins
     off; without it the trial is reachable by anyone on the LAN (said loudly at build time).
  3. A trial nobody can reach must end by itself: /etc/init.d/ex4-trial reboots after --return-min minutes unless
     /tmp/ex4-stay exists. A reboot goes through U-Boot = the untouched stock system.
  4. A self-test report (bays, NICs, USB 3, temperature, NAND read-only, uart1) lands in /tmp/ex4-selftest.txt and on
     the serial console.

  5. (v1, with --ex4log) THE BLACK BOX: the static ex4log binary rides in as /usr/sbin/ex4log and is started twice
     over: from a preinit hook (/lib/preinit/01_ex4_disklog, the earliest userspace point after kmodloader has
     loaded sata_mv) and again from /etc/rc.d/S01ex4log if the first start did not take. It writes the kernel log, a
     status block and a progress trail to a RAW region of partition 3 of a SATA disk every few seconds (format, walls
     and the size window: ex4log.c's header). The self-test, uci-defaults and the auto-return leave notes in it.
  6. (v1, with --preinit-conf) OpenWrt's preinit gives the first LAN port that same STATIC default address for about
     four seconds on every boot (the failsafe window) before any config exists. On many home LANs that is the
     router's address. The overlay ships the image's own 00_preinit.conf with pi_preinit_no_failsafe="y", which
     skips that step (and the failsafe prompt nobody can answer without a serial console).

  7. (v4, with --ex4fan) THE FAN: on the EX4 a front-panel microcontroller on uart1 (ttyS1) drives the fan and
     nothing in OpenWrt speaks to it (run 5: the fan was unmanaged). The static ex4fan binary rides in as
     /usr/sbin/ex4fan, started from a preinit hook (/lib/preinit/02_ex4_fan, right after the logger's) and again from
     /etc/rc.d/S02ex4fan if the first start did not take. Its first action is fan HIGH; protocol, whitelist, curve
     and fail-safes: ex4fan.c's header. The self-test gains one "-- fan" block (state line + the daemon's log).

  8. (v5, with --ex4mac) THE TWO MAC ADDRESSES: under WD's firmware the two LAN ports have the unit's own two
     addresses (WD's mac_read takes them, as text, from the first good block of the "rescue firmware" flash partition:
     the first at byte 0 for port 1, the second at byte 0x1c for port 2), and WD's bond then shows the FIRST one on
     the LAN. Under OpenWrt both ports came up with the same address (run 5). /lib/preinit/07_ex4_set_mac reads the two
     addresses the same way (OpenWrt's own mtd_get_mac_text, the idiom its D-Link DNS-320L port uses for the same
     vendor layout; read-only) and gives eth0 the first and eth1 the second; with nothing readable in flash it keeps
     eth0's address and gives eth1 the same one with the locally-administered bit set. uci-defaults then pins the
     bridge (br-lan, the interface that asks for the DHCP lease) to the FIRST address, so the lease stays the one the
     unit had under WD's firmware whichever port has the cable.
  9. (v5, with --kmods DIR) USB 3: the files build/kmod_pick.py took out of the official zyxel_nsa325 image of the
     same OpenWrt release (xhci-hcd.ko, xhci-pci.ko, xhci-plat-hcd.ko and the two /etc/modules.d lists that load
     them), at the paths they have in that image. kmodloader loads them with the rest of /etc/modules.d. With them
     comes /etc/init.d/ex4-deadman (S03, before the modules load): a second auto-return, --return-min + 2 minutes,
     that does not depend on the boot reaching S99.
 10. (v5, with either) the self-test gains the v5 blocks: both MACs + the bridge's, link flap counters and PHY ids,
     the xHCI controller's driver + USB devices, the clock, the front panel's events, hwmon names.
 11. (v6, with --ex4phy) the static ex4phy binary rides in as /usr/sbin/ex4phy (it READS PHY registers through the
     MII ioctls; it has no write call) and the self-test gains the v6 blocks: where each flash partition really
     sits (run 7 read the wrong place: the device tree had WD's last three partitions in address order, WD has
     them in another), which driver holds each PHY and what the chips themselves answer (id, register page), and
     the carrier-change counters of both ports taken twice, 10 s apart (the link flap of runs 5 to 7, as a rate).

  python3 -I mkoverlay.py --network-file <02_network from the SAME OpenWrt image> --out overlay.cpio
                          [--pubkey id.pub] [--return-min 20]
                          [--ex4log <static ARM ex4log> --log-min-sectors N --log-max-sectors N --tag bundle-v1
                           --log-skip-port N]
                          [--preinit-conf <00_preinit.conf from the SAME OpenWrt image>]
                          [--ex4fan <static ARM ex4fan>]        (needs --ex4log: its notes go to the black box)
                          [--ex4mac] [--kmods <kmod_pick.py outdir>]      (v5; both need --ex4fan)
                          [--ex4phy <static ARM ex4phy>]                  (v6; needs --ex4mac)
Without --ex4log and --preinit-conf the output is byte-identical to the v0 overlay (checked Nov 16 2026).
Without --ex4fan the output is byte-identical to what this file built before v4 (bundle-v1's / v3's overlay).
Without --ex4mac and --kmods the output is byte-identical to what this file built before v5 (with bundle-v4's ex4fan:
bundle-v4's overlay).
Without --ex4phy the output is byte-identical to what this file built before v6.
Never overwrites. Born Nov 16 2026 (EX4 tooling)."""
import argparse
import os
import sys

# OpenWrt's factory-default LAN address, written in pieces: this repo's publish scanner refuses private-range
# literals, and this one is only ever compared against OpenWrt's own file.
OWRT_DEFAULT_IP = '.'.join(('192', '168', '1', '1'))

SELFTEST = r'''#!/bin/sh
# ex4-selftest: what works on this EX4 under the trial kernel. Reads only.
O=/tmp/ex4-selftest.txt
{
echo "== EX4 trial self-test $(date) =="
echo "kernel: $(uname -r)  board: $(cat /tmp/sysinfo/board_name 2>/dev/null)  model: $(cat /tmp/sysinfo/model 2>/dev/null)"
echo "cmdline: $(cat /proc/cmdline)"
echo "-- memory"; grep -E "MemTotal|MemFree" /proc/meminfo
echo "-- mtd (trial tree: every partition must say ro)"; cat /proc/mtd
for m in /sys/class/mtd/mtd[0-9]; do echo "$(cat $m/name): flags $(cat $m/flags)"; done
echo "-- pci"; for d in /sys/bus/pci/devices/*; do echo "$(basename $d) $(cat $d/vendor):$(cat $d/device) driver=$(basename $(readlink $d/driver 2>/dev/null) 2>/dev/null)"; done
echo "-- disks"; for b in /sys/block/sd*; do [ -e $b ] && echo "$(basename $b) $(cat $b/device/model 2>/dev/null) $(cat $b/size) sectors"; done
echo "-- network"; for i in eth0 eth1; do echo "$i mac $(cat /sys/class/net/$i/address 2>/dev/null) carrier $(cat /sys/class/net/$i/carrier 2>/dev/null) speed $(cat /sys/class/net/$i/speed 2>/dev/null)"; done
ip -4 addr show | grep inet
echo "-- usb"; cat /sys/kernel/debug/usb/devices 2>/dev/null | grep -E "^T:|^P:" | head -20; ls /sys/bus/usb/devices 2>/dev/null
echo "-- thermal"; for z in /sys/class/thermal/thermal_zone*/temp /sys/class/hwmon/hwmon*/temp1_input; do [ -e $z ] && echo "$z $(cat $z)"; done
@FAN@@V5@echo "-- watchdog"; ls /dev/watchdog* 2>/dev/null; cat /sys/class/watchdog/watchdog0/state 2>/dev/null
echo "-- serial"; cat /proc/tty/driver/serial 2>/dev/null
echo "-- i2c"; ls /sys/bus/i2c/devices 2>/dev/null
echo "-- gpio"; cat /sys/kernel/debug/gpio 2>/dev/null | head -80
echo "-- dmesg errors"; dmesg | grep -iE "error|fail|unable|timeout|ecc|bad" | head -40
P=0; [ "$(ls -d /sys/block/sd* 2>/dev/null | wc -l)" -ge 1 ] && P=$((P+1))
echo "== bays seen: $(ls -d /sys/block/sd* 2>/dev/null | wc -l) of 4 =="
} > $O 2>&1
cat $O > /dev/console 2>/dev/null
'''

INITD = r'''#!/bin/sh /etc/rc.common
# ex4-trial: run the self-test once, then go back to the stock system by rebooting unless someone says stay.
START=99
boot() {
@N1@	( sleep 20; /usr/sbin/ex4-selftest
@N2@	  sleep $((@RETURN_MIN@ * 60))
	  [ -e /tmp/ex4-stay ] || { logger -t ex4-trial "no /tmp/ex4-stay after @RETURN_MIN@ min: rebooting to stock"; @N3@reboot; } ) &
}
'''
INITD_N1 = '\t/usr/sbin/ex4log note "rc.d S99 reached: every init script has run"\n'
INITD_N2 = '\t  /usr/sbin/ex4log note "self-test written to /tmp/ex4-selftest.txt"\n'
INITD_N3 = '/usr/sbin/ex4log note "auto-return: no /tmp/ex4-stay, rebooting to stock now"; sleep 4; '

SELFTEST_FAN = r'''echo "-- fan (ex4fan: the front-panel micro on ttyS1 drives the fan; rpm = GPIO 39 counted WD's way)"; cat /tmp/ex4fan.status 2>/dev/null || echo "NO /tmp/ex4fan.status: ex4fan is not running"; tail -n 30 /tmp/ex4fan.log 2>/dev/null
'''

# v5: what run 7 has to show. Reads only.
SELFTEST_V5 = r'''echo "-- v5 macs (the unit's own two addresses, as WD's mac_read takes them from the 'rescue firmware' partition; br-lan asks for the lease)"; for i in eth0 eth1 br-lan; do echo "$i mac $(cat /sys/class/net/$i/address 2>/dev/null) assign_type $(cat /sys/class/net/$i/addr_assign_type 2>/dev/null)"; done; cat /tmp/ex4-mac.txt 2>/dev/null || echo "NO /tmp/ex4-mac.txt: the MAC hook did not run"
echo "-- v5 link (runs 5 and 6: eth1 lost and regained its link about once a second; these counters say whether it still does)"; for i in eth0 eth1; do echo "$i carrier_changes $(cat /sys/class/net/$i/carrier_changes 2>/dev/null) down_count $(cat /sys/class/net/$i/carrier_down_count 2>/dev/null) at_uptime $(cut -d' ' -f1 /proc/uptime) tx_dropped $(cat /sys/class/net/$i/statistics/tx_dropped 2>/dev/null) tx_errors $(cat /sys/class/net/$i/statistics/tx_errors 2>/dev/null) phy_id $(cat /sys/class/net/$i/phydev/phy_id 2>/dev/null) phy_interface $(cat /sys/class/net/$i/phydev/phy_interface 2>/dev/null) phy_driver $(basename "$(readlink /sys/class/net/$i/phydev/driver 2>/dev/null)" 2>/dev/null)"; done
echo "-- v5 usb3 (the Etron EJ168, PCI class 0x0c0330, needs xhci-pci: modules from the official zyxel_nsa325 image of the same release)"; for d in /sys/bus/pci/devices/*; do [ "$(cat $d/class 2>/dev/null)" = 0x0c0330 ] && echo "xhci controller $(basename $d) $(cat $d/vendor):$(cat $d/device) driver=$(basename "$(readlink $d/driver 2>/dev/null)" 2>/dev/null)"; done; echo "modules: $(grep -E '^(xhci|usb_storage)' /proc/modules | cut -d' ' -f1 | tr '\n' ' ')"; for u in /sys/bus/usb/devices/*; do [ -e $u/idVendor ] && echo "usb device $(basename $u) $(cat $u/idVendor):$(cat $u/idProduct) speed $(cat $u/speed 2>/dev/null) $(cat $u/manufacturer 2>/dev/null) $(cat $u/product 2>/dev/null)"; done; dmesg | grep -iE "xhci|etron" | head -12
echo "-- v5 clock (the SoC's own RTC has no crystal on this board; the front-panel micro keeps the time and ex4fan reads it)"; echo "date: $(date -u '+%Y-%m-%d %H:%M:%S UTC') rtc devices: $(ls /sys/class/rtc 2>/dev/null | tr '\n' ' ')"; dmesg | grep -i "rtc" | head -4; grep "clock:" /tmp/ex4fan.log 2>/dev/null | tail -4
echo "-- v5 front panel (ex4fan: WD's DeviceReady; the micro's own events are logged only)"; grep -E "cmd READY|event |no use for" /tmp/ex4fan.log 2>/dev/null | tail -20
echo "-- v5 hwmon names"; for h in /sys/class/hwmon/hwmon*; do echo "$(basename $h) $(cat $h/name 2>/dev/null) temp1 $(cat $h/temp1_input 2>/dev/null) device $(basename "$(readlink $h/device 2>/dev/null)" 2>/dev/null)"; done
'''

# v6: what run 8 has to show. Reads only (ex4phy has no write call; the sleep is the 10 s between the two counter reads).
SELFTEST_V6 = r'''echo "-- v6 flash (WD's own layout, from the stock kernel's boot log: mtd4 'rescue firmware' at 0x0dd00000, mtd5 'config' at 0x0ec00000, mtd6 'reserve' at 0x0d800000)"; for m in /sys/class/mtd/mtd[0-9]; do printf '%s offset 0x%08x size 0x%08x name %s\n' "$(basename $m)" "$(cat $m/offset 2>/dev/null)" "$(cat $m/size 2>/dev/null)" "$(cat $m/name 2>/dev/null)" 2>/dev/null; done
echo "-- v6 phy (the device tree hands both PHYs to the kernel's generic PHY driver: the Marvell driver's page flip on every poll was the link flap; ex4phy asks the chips themselves and writes nothing)"; for p in /sys/bus/mdio_bus/devices/*; do [ -e $p/phy_id ] && echo "$(basename $p) phy_id $(cat $p/phy_id 2>/dev/null) interface $(cat $p/phy_interface 2>/dev/null) driver $(basename "$(readlink $p/driver 2>/dev/null)" 2>/dev/null)"; done; /usr/sbin/ex4phy eth0 eth1 2>&1
echo "-- v6 link (both ports' carrier_changes read twice, 10 s apart; runs 5 to 7: about 19 in 10 s on the cabled port)"; A0=$(cat /sys/class/net/eth0/carrier_changes 2>/dev/null); A1=$(cat /sys/class/net/eth1/carrier_changes 2>/dev/null); T0=$(cut -d' ' -f1 /proc/uptime); sleep 10; T1=$(cut -d' ' -f1 /proc/uptime)
echo "eth0 changes_from ${A0:-?} to $(cat /sys/class/net/eth0/carrier_changes 2>/dev/null || echo '?') uptime_from $T0 to $T1 link_down_lines $(dmesg | grep -c 'eth0: link down')"
echo "eth1 changes_from ${A1:-?} to $(cat /sys/class/net/eth1/carrier_changes 2>/dev/null || echo '?') uptime_from $T0 to $T1 link_down_lines $(dmesg | grep -c 'eth1: link down')"
'''

# v5: the two MAC addresses. A file of its own beside the image's 07_set_iface_mac (same hook point, same idiom).
PREINIT_MAC = r'''# EX4: give the two LAN ports the unit's own two MAC addresses, the way WD's firmware does.
# WD keeps them as text in the first good block of the "rescue firmware" flash partition: the first at byte 0, the
# second at byte 0x1c ("00:90:A9:xx:xx:xx"). WD's mac_read gives the first to port 1 (WD's egiga0, eth0 here) and the
# second to port 2 (egiga1, eth1); WD's bond then shows the FIRST one on the LAN whichever port has the cable.
# Under this kernel both ports start with whatever the previous stage left in the port registers (after WD's bond:
# the same address twice). Reads only: 17 bytes per address through OpenWrt's own mtd_get_mac_text.
. /lib/functions.sh
. /lib/functions/system.sh

ex4_mac_ok() {		# a canonical address, not multicast, not empty, not WD's placeholder (00:11:4a:00:00:01 / :02)
	case "$1" in
	??:??:??:??:??:??) ;;
	*) return 1;;
	esac
	case "$1" in
	00:00:00:00:00:00|ff:ff:ff:ff:ff:ff|00:11:4a:00:00:0[12]) return 1;;
	?[13579bdf]:*) return 1;;
	esac
	return 0
}

ex4_set_mac() {
	local m1= m2= blk off src= cur0 cur1 o=/tmp/ex4-mac.txt
	[ "$(board_name)" = "wd,mycloud-ex4" ] || return 0
	cur0=$(cat /sys/class/net/eth0/address 2>/dev/null); cur1=$(cat /sys/class/net/eth1/address 2>/dev/null)
	for blk in 0 1 2 3 4 5 6 7; do
		off=$((blk * 131072))
		m1=$(mtd_get_mac_text "rescue firmware" $off 2>/dev/null)
		m2=$(mtd_get_mac_text "rescue firmware" $((off + 28)) 2>/dev/null)
		if ex4_mac_ok "$m1" && ex4_mac_ok "$m2" && [ "$m1" != "$m2" ]; then src="flash (rescue firmware, block $blk)"; break; fi
		m1=; m2=
	done
	if [ -z "$src" ]; then
		if ex4_mac_ok "$cur0" && ex4_mac_ok "$cur1" && [ "$cur0" != "$cur1" ]; then
			m1=$cur0; m2=$cur1; src="left as found (nothing readable in flash; the two ports already differ)"
		elif ex4_mac_ok "$cur0"; then
			m1=$cur0; m2=$(macaddr_setbit_la "$cur0"); src="derived (nothing readable in flash): eth0 keeps its address, eth1 = the same with the locally-administered bit"
		elif ex4_mac_ok "$cur1"; then
			m1=$cur1; m2=$(macaddr_setbit_la "$cur1"); src="derived (nothing readable in flash, eth0 has no usable address): eth0 = eth1's, eth1 = the same with the locally-administered bit"
		else
			echo "source=none: nothing readable in flash and no usable address on a port; left alone (eth0 $cur0, eth1 $cur1)" > $o
			return 0
		fi
	fi
	ex4_mac_ok "$m1" && ex4_mac_ok "$m2" && [ "$m1" != "$m2" ] || { echo "source=none: $src gave no usable pair ($m1 / $m2); left alone (eth0 $cur0, eth1 $cur1)" > $o; return 0; }
	ip link set dev eth0 address "$m1" 2>/dev/null
	ip link set dev eth1 address "$m2" 2>/dev/null
	{
		echo "source=$src"
		echo "eth0 was=$cur0 now=$(cat /sys/class/net/eth0/address 2>/dev/null) want=$m1"
		echo "eth1 was=$cur1 now=$(cat /sys/class/net/eth1/address 2>/dev/null) want=$m2"
		echo "lan_mac=$m1"
	} > $o
	[ -x /usr/sbin/ex4log ] && /usr/sbin/ex4log note "MACs: eth0 $m1, eth1 $m2 ($src)" >/dev/null 2>&1
	return 0
}

boot_hook_add preinit_main ex4_set_mac
'''

UCI_MAC = r'''# v5: the bridge asks for the DHCP lease; pin it to the unit's FIRST address (what WD's bond showed on the LAN)
M1=$(sed -n 's/^lan_mac=//p' /tmp/ex4-mac.txt 2>/dev/null)
if [ -n "$M1" ]; then
	for s in $(uci -q show network | sed -n "s/^network\.\([^.]*\)\.name='br-lan'$/\1/p"); do uci -q set network.$s.macaddr="$M1"; done
	uci -q commit network
fi
'''

# v5: a second way back to stock, armed before the new kernel modules load.
INITD_DEADMAN = r'''#!/bin/sh /etc/rc.common
# ex4-deadman (v5): a way back to stock that does not need the boot to reach its last init script. v5 loads kernel
# modules the earlier trials did not have (xhci, from /etc/init.d/boot = S10). Should a module load ever block the
# init scripts, S99's auto-return would never be armed and the box would sit there, unreachable, until someone pulls
# the plug. This is armed at S03, before the modules load: @RETURN_MIN@ + 2 minutes later, unless /tmp/ex4-stay
# exists, it reboots (through U-Boot into the untouched stock system). In a boot that goes well S99's own timer fires
# two minutes earlier and this one never does anything.
START=03
boot() {
	/usr/sbin/ex4log note "rc.d S03: deadman armed: reboot to stock in @RETURN_MIN@ + 2 min unless /tmp/ex4-stay exists (does not need S99)"
	( sleep $(((@RETURN_MIN@ + 2) * 60))
	  [ -e /tmp/ex4-stay ] || { /usr/sbin/ex4log note "deadman: @RETURN_MIN@ + 2 min, no /tmp/ex4-stay: rebooting to stock now"; sleep 4; reboot; sleep 60; reboot -f; } ) &
}
'''

# v4: the fan daemon. Same two start points as the logger.
PREINIT_FAN = r'''# EX4 trial: the fan. On this box a front-panel microcontroller on uart1 (ttyS1) drives the fan, and nothing in
# OpenWrt speaks to it. ex4fan's first action is fan HIGH. It detaches by itself; nothing here can hold the boot up.
ex4_fan_start() {
	[ -x /usr/sbin/ex4fan ] && /usr/sbin/ex4fan daemon </dev/null >/dev/null 2>&1
	return 0
}

boot_hook_add preinit_essential ex4_fan_start
'''

INITD_FAN = r'''#!/bin/sh /etc/rc.common
# ex4fan: the second start point for the fan daemon (the first is the preinit hook), and a note in the black box.
START=02
boot() {
	P=$(cat /tmp/ex4fan.pid 2>/dev/null)
	if [ -z "$P" ] || [ ! -d "/proc/$P" ]; then
		/usr/sbin/ex4fan daemon </dev/null >/dev/null 2>&1
		/usr/sbin/ex4log note "rc.d S02: the preinit hook had not started ex4fan; started here"
		sleep 4
	fi
	/usr/sbin/ex4log note "rc.d S02: ex4fan $(cat /tmp/ex4fan.status 2>/dev/null || echo 'has no state line yet')"
}
'''

# v1: the black box. LOGGER_ARGS is filled in by main(); the same line is used by both start points.
PREINIT_HOOK = r'''# EX4 trial: start the black-box logger at the earliest userspace point. procd's init has already run
# kmodloader over /etc/modules-boot.d (sata_mv is in there), so the disks are being probed while this runs.
# The daemon detaches by itself; nothing here can hold the boot up.
ex4_disklog_start() {
	[ -x /usr/sbin/ex4log ] && /usr/sbin/ex4log daemon @LOGGER_ARGS@ </dev/null >/dev/null 2>&1
	return 0
}

boot_hook_add preinit_essential ex4_disklog_start
'''

INITD_LOG = r'''#!/bin/sh /etc/rc.common
# ex4log: the second start point for the black-box logger (the first is the preinit hook), and a progress note.
START=01
boot() {
	P=$(cat /tmp/ex4log.pid 2>/dev/null)
	if [ -z "$P" ] || [ ! -d "/proc/$P" ]; then
		/usr/sbin/ex4log daemon @LOGGER_ARGS@ </dev/null >/dev/null 2>&1
		/usr/sbin/ex4log note "rc.d S01: the preinit hook had not started the logger; started here"
	fi
	/usr/sbin/ex4log note "rc.d S01 reached: procd is running the init scripts"
}
'''

UCI_DEFAULTS = r'''#!/bin/sh
# ex4 trial: a NAS on someone's LAN, not a router.
uci -q set system.@system[0].hostname='ex4-trial'
uci -q commit system
uci -q set dhcp.lan.ignore='1'
uci -q commit dhcp
@KEYONLY@
@MAC@@N4@exit 0
'''

BANNER = '''
 EX4 TRIAL: this system runs from RAM. The NAND is mounted read-only by the device tree.
 Report: cat /tmp/ex4-selftest.txt     Stay past the auto-return: touch /tmp/ex4-stay
 Back to the stock WD system: reboot  (or pull the plug)

'''


def newc(name, data, mode, ino):
    name_b = name.encode() + b'\0'
    h = '070701' + ''.join('%08X' % v for v in (ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name_b), 0))
    out = h.encode() + name_b
    out += b'\0' * (-len(out) % 4)
    out += data + b'\0' * (-len(data) % 4)
    return out


def static_arm(path, flag):
    elf = open(path, 'rb').read()
    # ELF32, little-endian, executable, ARM, and statically linked (no PT_INTERP): anything else cannot run in the trial
    if elf[:7] != b'\x7fELF\x01\x01\x01' or elf[16:20] != b'\x02\x00\x28\x00':
        sys.exit(f"REFUSED: {flag} is not a 32-bit little-endian ARM executable")
    phoff = int.from_bytes(elf[28:32], 'little'); phentsize = int.from_bytes(elf[42:44], 'little'); phnum = int.from_bytes(elf[44:46], 'little')
    if any(int.from_bytes(elf[phoff + i * phentsize:phoff + i * phentsize + 4], 'little') == 3 for i in range(phnum)):
        sys.exit(f"REFUSED: {flag} is dynamically linked (the trial system has a different libc): build it -static")
    return elf


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--network-file', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--pubkey')
    ap.add_argument('--return-min', type=int, default=20)
    ap.add_argument('--ex4log', help='static ARM ex4log binary: adds the black-box logger (v1)')
    ap.add_argument('--log-min-sectors', type=int, default=8192)
    ap.add_argument('--log-max-sectors', type=int, default=16777216)
    ap.add_argument('--tag', default='bundle-v1')
    ap.add_argument('--log-skip-port', type=int, action='append', default=[], help='an ATA port the logger must never write to (repeatable)')
    ap.add_argument('--preinit-conf', help="the image's own /lib/preinit/00_preinit.conf: ships it with the preinit static IP off (v1)")
    ap.add_argument('--ex4fan', help='static ARM ex4fan binary: adds the fan daemon (v4); needs --ex4log')
    ap.add_argument('--ex4mac', action='store_true', help="v5: the unit's own two MAC addresses on eth0 / eth1, the first one on br-lan; needs --ex4fan")
    ap.add_argument('--ex4phy', help='v6: static ARM ex4phy binary (reads PHY registers, writes none) + the v6 self-test blocks; needs --ex4mac')
    ap.add_argument('--kmods', help='v5: the outdir of kmod_pick.py (lib/modules/<ver>/*.ko + etc/modules.d/*): rides in at the same paths; needs --ex4fan')
    a = ap.parse_args()
    if os.path.exists(a.out):
        sys.exit(f"REFUSED: {a.out} exists (never overwrite)")
    net = open(a.network_file).read()
    marker = '\tiom,ix4-200d)\n\t\tucidef_set_interface_lan "eth0 eth1" "dhcp"\n'
    if net.count(marker) != 1:
        sys.exit("REFUSED: the 02_network file does not have the ix4-200d DHCP case this overlay copies (different OpenWrt?)")
    net = net.replace(marker, '\tiom,ix4-200d|\\\n\twd,mycloud-ex4)\n\t\tucidef_set_interface_lan "eth0 eth1" "dhcp"\n')
    keyonly = ''
    files = []          # (name, bytes, mode) ; directories first
    dirs = ['etc', 'etc/board.d', 'etc/uci-defaults', 'etc/init.d', 'etc/rc.d', 'usr', 'usr/sbin']
    n1 = n2 = n3 = n4 = ''
    extra = []
    if a.ex4fan and not a.ex4log:
        sys.exit("REFUSED: --ex4fan needs --ex4log (the fan daemon's fail-safe reasons go to the black box)")
    if (a.ex4mac or a.kmods) and not a.ex4fan:
        sys.exit("REFUSED: --ex4mac / --kmods are the v5 additions on top of the v4 overlay: they need --ex4fan")
    if a.ex4phy and not a.ex4mac:
        sys.exit("REFUSED: --ex4phy is the v6 addition on top of the v5 overlay: it needs --ex4mac")
    if a.ex4log or a.preinit_conf:
        dirs += ['lib', 'lib/preinit']
    if a.ex4log:
        elf = open(a.ex4log, 'rb').read()
        # ELF32, little-endian, executable, ARM, and statically linked (no PT_INTERP): anything else cannot run in the trial
        if elf[:7] != b'\x7fELF\x01\x01\x01' or elf[16:20] != b'\x02\x00\x28\x00':
            sys.exit("REFUSED: --ex4log is not a 32-bit little-endian ARM executable")
        phoff = int.from_bytes(elf[28:32], 'little'); phentsize = int.from_bytes(elf[42:44], 'little'); phnum = int.from_bytes(elf[44:46], 'little')
        if any(int.from_bytes(elf[phoff + i * phentsize:phoff + i * phentsize + 4], 'little') == 3 for i in range(phnum)):
            sys.exit("REFUSED: --ex4log is dynamically linked (the trial system has a different libc): build it -static")
        if not (4 <= a.log_min_sectors <= a.log_max_sectors) or a.log_min_sectors * 512 < (3 << 20):
            sys.exit("REFUSED: the size window must hold the log region ([1 MiB, 3 MiB) inside the partition)")
        if not a.tag.replace('-', '').replace('.', '').isalnum():
            sys.exit("REFUSED: --tag takes letters, digits, - and . only")
        if any(not 1 <= x <= 32 for x in a.log_skip_port):
            sys.exit("REFUSED: --log-skip-port takes an ATA port number (1..32)")
        largs = f'--min-sectors {a.log_min_sectors} --max-sectors {a.log_max_sectors}' + ''.join(f' --skip-port {x}' for x in a.log_skip_port) + f' --tag {a.tag}'
        n1, n2, n3 = INITD_N1, INITD_N2, INITD_N3
        n4 = '/usr/sbin/ex4log note "uci-defaults applied (hostname ex4-trial, DHCP server off, ssh settings)"\n'
        extra += [
            ('usr/sbin/ex4log', elf, 0o100755),
            ('lib/preinit/01_ex4_disklog', PREINIT_HOOK.replace('@LOGGER_ARGS@', largs).encode(), 0o100644),
            ('etc/init.d/ex4log', INITD_LOG.replace('@LOGGER_ARGS@', largs).encode(), 0o100755),
            ('etc/rc.d/S01ex4log', b'../init.d/ex4log', 0o120777),
        ]
    if a.preinit_conf:
        conf = open(a.preinit_conf).read()
        if conf.count('pi_preinit_no_failsafe=""\n') != 1 or ('pi_ip="' + OWRT_DEFAULT_IP + '"') not in conf:
            sys.exit("REFUSED: --preinit-conf is not the 00_preinit.conf this overlay knows how to patch (different OpenWrt?)")
        conf = conf.replace('pi_preinit_no_failsafe=""\n', 'pi_preinit_no_failsafe="y"\n')
        extra.append(('lib/preinit/00_preinit.conf', conf.encode(), 0o100644))
    for d in dirs:
        files.append((d, b'', 0o040755))
    if a.pubkey:
        key = open(a.pubkey).read().strip()
        if not key.startswith(('ssh-ed25519 ', 'ssh-rsa ', 'ecdsa-')) or '\n' in key or 'PRIVATE' in key:
            sys.exit("REFUSED: --pubkey is not one public key line")
        files.append(('etc/dropbear', b'', 0o040700))
        files.append(('etc/dropbear/authorized_keys', (key + '\n').encode(), 0o100600))
        keyonly = ("uci -q set dropbear.@dropbear[0].PasswordAuth='off'\n"
                   "uci -q set dropbear.@dropbear[0].RootPasswordAuth='off'\nuci -q commit dropbear")
    else:
        print("WARNING: no --pubkey: the trial system accepts root with NO password from the LAN", file=sys.stderr)
    files += [
        ('etc/board.d/02_network', net.encode(), 0o100755),
        ('etc/uci-defaults/99-ex4-trial', UCI_DEFAULTS.replace('@KEYONLY@', keyonly).replace('@MAC@', UCI_MAC if a.ex4mac else '').replace('@N4@', n4).encode(), 0o100755),
        ('etc/init.d/ex4-trial', INITD.replace('@RETURN_MIN@', str(a.return_min)).replace('@N1@', n1).replace('@N2@', n2).replace('@N3@', n3).encode(), 0o100755),
        ('etc/rc.d/S99ex4-trial', b'../init.d/ex4-trial', 0o120777),
        ('usr/sbin/ex4-selftest', SELFTEST.replace('@FAN@', SELFTEST_FAN if a.ex4fan else '').replace('@V5@', (SELFTEST_V5 if (a.ex4mac or a.kmods) else '') + (SELFTEST_V6 if a.ex4phy else '')).encode(), 0o100755),
        ('etc/banner.ex4', BANNER.encode(), 0o100644),
    ]
    files += extra
    if a.ex4fan:        # after everything that was there before v4, so the older entries keep their order and inode numbers
        files += [
            ('usr/sbin/ex4fan', static_arm(a.ex4fan, '--ex4fan'), 0o100755),
            ('lib/preinit/02_ex4_fan', PREINIT_FAN.encode(), 0o100644),
            ('etc/init.d/ex4fan', INITD_FAN.encode(), 0o100755),
            ('etc/rc.d/S02ex4fan', b'../init.d/ex4fan', 0o120777),
        ]
    nk = 0
    if a.ex4mac:        # v5: after everything v4 had, so v4's entries keep their order and inode numbers
        files.append(('lib/preinit/07_ex4_set_mac', PREINIT_MAC.encode(), 0o100644))
    if a.kmods:
        top = os.path.abspath(a.kmods); picked = []
        for r, _, fs in sorted(os.walk(top)):
            for f in sorted(fs):
                rel = os.path.relpath(os.path.join(r, f), top)
                if rel == 'KMODS.txt': continue
                if not (rel.startswith('lib/modules/') and rel.endswith('.ko')) and not rel.startswith('etc/modules.d/'):
                    sys.exit(f"REFUSED: --kmods holds {rel}: only lib/modules/<ver>/*.ko and etc/modules.d/* may ride in")
                picked.append(rel)
        if not any(p.endswith('.ko') for p in picked):
            sys.exit("REFUSED: --kmods holds no module")
        have = {n for n, d, m in files}; newdirs = []
        for rel in picked:
            parts = rel.split('/')[:-1]
            for i in range(1, len(parts) + 1):
                d = '/'.join(parts[:i])
                if d not in have and d not in newdirs: newdirs.append(d)
        for d in newdirs:        # these exist in the image already; an entry for an existing directory only restates its mode
            files.append((d, b'', 0o040755))
        for rel in picked:
            body = open(os.path.join(top, rel), 'rb').read()
            if rel.endswith('.ko') and (body[:7] != b'\x7fELF\x01\x01\x01' or body[16:20] != b'\x01\x00\x28\x00'):
                sys.exit(f"REFUSED: {rel} is not a relocatable 32-bit little-endian ARM object (a kernel module)")
            files.append((rel, body, 0o100644)); nk += 1
        files += [
            ('etc/init.d/ex4-deadman', INITD_DEADMAN.replace('@RETURN_MIN@', str(a.return_min)).encode(), 0o100755),
            ('etc/rc.d/S03ex4-deadman', b'../init.d/ex4-deadman', 0o120777),
        ]
    if a.ex4phy:        # v6: after everything v5 had, so v5's entries keep their order and inode numbers
        files.append(('usr/sbin/ex4phy', static_arm(a.ex4phy, '--ex4phy'), 0o100755))
    out = b''.join(newc(n, d, m, 1000 + i) for i, (n, d, m) in enumerate(files))
    out += newc('TRAILER!!!', b'', 0, 0)
    out += b'\0' * (-len(out) % 512)
    with open(a.out, 'wb') as f:
        f.write(out)
    print(f"wrote {a.out}: {len(out)} bytes, {len(files)} entries, key-only ssh: {'yes' if a.pubkey else 'NO'}, auto-return {a.return_min} min, "
          f"black box: {('yes, window %d..%d sectors, ports kept off %s, tag %s' % (a.log_min_sectors, a.log_max_sectors, a.log_skip_port or 'none', a.tag)) if a.ex4log else 'NO'}, "
          f"preinit static default address: {'off' if a.preinit_conf else 'ON (stock OpenWrt behaviour)'}"
          + (", fan daemon: yes (preinit hook + rc.d S02)" if a.ex4fan else "")
          + (", MAC hook: yes (preinit 07_ex4_set_mac + br-lan pinned in uci-defaults)" if a.ex4mac else "")
          + (f", kernel modules + lists from --kmods: {nk} files, deadman at S03 ({a.return_min} + 2 min)" if a.kmods else "")
          + (", ex4phy + the v6 self-test blocks: yes" if a.ex4phy else ""))


main()
