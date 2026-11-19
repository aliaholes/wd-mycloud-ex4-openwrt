#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# ex4-rwbench.sh (v8; v9 = the review's must_fix + nits; v9.3 = tuning arms; v9.4 = NFS block size + the profile verb; v9.7 = NFSv4.2,
# nfsd threads, the data canary, instruments, facts; v9.8 = the user-copy canary, the nfsd start-wait, the nfs-utils socket wall;
# v9.9 = the memory receipt + the nfsd prep before every rpc.nfsd) : THE READ-WRITE TRIAL BENCH. Runs ON the EX4's RAM trial (OpenWrt 25.12, our own v7 kernel,
# busybox ash), as root, by hand over the trial's key-only ssh. It is the ONE path in this repo that writes the data
# array, and it exists to measure the one thing a read-only trial cannot: the write path (RAID5 parity on the SoC's
# two mv_xor engines, SMB / NFS writes into md1). Everything it does is bounded, logged, and undone by a clean stop.
#
#   ex4-rwbench preflight            read-only: is this the trial, are the reboot paths patched, is the array clean?
#   ex4-rwbench arm                  preflight, then print the TOKEN to type by hand into /tmp/ex4-rw-ok
#   ex4-rwbench gate-check           exit 0 when /tmp/ex4-rw-ok holds that exact token (reads it, never writes it)
#   ex4-rwbench up CLIENT_IP [--stay] [--window-min N] [--skip-copy 0|1]  consume the token; assemble md1 read-only,
#                                    check it, switch it read-write with sync frozen, mount ext4 rw, make
#                                    Public/ex4-bench-v8/, start the guard. --stay holds the trial's auto-return (touch
#                                    /tmp/ex4-stay) for the bench; the clean stop gives it back: 5 minutes after a SAFE stop
#                                    the trial goes home by itself. --window-min: the rw window, 5..45 minutes (default 25).
#                                    (v9.3) --skip-copy: md's skip_copy, written AFTER the rw switch and BEFORE the ext4
#                                    mount (wall 11); every md / read-ahead knob is recorded first, for the clean stop
#   ex4-rwbench tune [--stripe-cache N] [--readahead-kb N] [--group-threads N]   (v9.3) only while up: md1's
#                                    stripe_cache_size (256..4096), read_ahead_kb of md1 AND of each member disk
#                                    (128..8192 KiB), group_thread_cnt (0..2); each change read back + journalled
#   ex4-rwbench local [--label L]    local dd write 2 GiB + sync, then read it back, timed; the file is removed; (v9.3)
#                                    then a raw md read by stock's method (dd if=/dev/md1 bs=1M count=1024 skip=8192,
#                                    caches dropped first, read-only). --label prefixes the three result lines (an arm)
#   ex4-rwbench serve samba4|ksmbd CLIENT_IP         one SMB server, for that one client, on the bench folder only
#   ex4-rwbench serve nfs CLIENT_IP --unauthenticated-nfs [--max-block-kb N]   (v9) NFSv3 trusts the client's ADDRESS
#                                    only: it is refused unless that flag is typed (the client passes it only with --nfs).
#                                    (v9.4) --max-block-kb 64|128|256|512|1024: nfsd's max_block_size, written BEFORE any
#                                    nfsd thread starts (refused while nfsd runs), read back, journalled; unserve gives the
#                                    kernel's value back. Every NFS results line carries max_block_size. Default: not written
#                                    (v9.7) [--vers 3|4.2] [--threads N]: 4.2 = NFSv4.2 ONLY (v3, 4.0, 4.1 off, read back from
#                                    nfsd's versions file; no rpcbind / statd / mountd listener, checked; the folder exported
#                                    as the v4 pseudo-root, fsid=0; v4 grace 10 s, recorded + given back). --threads 1..16 =
#                                    the nfsd threads rpc.nfsd starts, read back. Default (neither): v9.4's NFSv3 exactly
#                                    (v9.8) every start: /var/lib/nfs/v4recovery made 0700 root if missing (the legacy client
#                                    tracking's dir), then after rpc.nfsd up to 30 s (1 s polls) for nfsd to be really up (threads
#                                    > 0 AND a 2049 listener); the seconds, rpc.nfsd's rc and the client tracking the kernel logged
#                                    land in the serve line. rpc.nfsd rc != 0 is taken only when nfsd then runs EXACTLY the threads
#                                    asked for; not up after 30 s = refused + THE CLEAN STOP
#                                    (v9.9) [--nfsd-prep every|second|off]: right before EVERY rpc.nfsd a MEMORY RECEIPT
#                                    (MemFree, MemAvailable, the zone watermarks, buddyinfo, the top 10 slab caches, how many
#                                    threads the bulk page allocator fits) -> nfs/memrcpt-start<N>-before.out (a kept server log),
#                                    then sync + drop_caches, then the receipt again (-after); a refused start writes -refused.
#                                    every (default) = the prep on every start; second = only from the session's 2nd start; off
#   ex4-rwbench md5 NAME             (v9.7) only while up: md5 of Public/ex4-bench-v8/NAME (NAME = a-z 0-9 - .bin), the canary
#   ex4-rwbench ucanary NAME --md5 HEX   (v9.8) only while up, untimed: THE USER-COPY CANARY (FABLE-OPT F3 row): NAME (a file the
#                                    client wrote over NFS, known md5 HEX) read with dd at four odd block sizes (4093 65521 131071
#                                    1048573: partial last blocks) into md5sum, then copied file to file at bs=65521 (copy_to_user
#                                    + copy_from_user), the copy md5'd and removed; the page cache dropped before every pass. Any
#                                    md5 != HEX = a CANARY FAIL row in results.txt + THE CLEAN STOP. It tests the kernel that runs
#   ex4-rwbench xsnap begin|end NAME (v9.7) only while up: the instruments around one copy (ctxt, NIC / sata_mv / xor
#                                    interrupts, softnet_stat, nfsd pool_stats, /proc/vmstat) -> xstat-NAME.txt + one line
#   ex4-rwbench facts                (v9.7) read-only: cpuinfo, clk_summary (debugfs mounted read-only for the read if it is
#                                    not, then unmounted), the NIC's sysfs, cpufreq; -> facts.txt
#   ex4-rwbench profile [--label L] [--mib N] [--top N]   (v9.4) only while up, only on a kernel with the function
#                                    profiler (refused cleanly otherwise, nothing written): profiler on, ONE local dd write
#                                    (N MiB, default 2048) + sync, profiler off; the top N (default 60) functions of every
#                                    trace_stat/function* (merged, by total time, with hits) -> profile-L.txt beside the
#                                    results + a summary line. Counts only: MiB/s under the profiler mean nothing
#   ex4-rwbench unserve              stop every file server this bench started
#   ex4-rwbench creds                print the bench share's user + password (made at `up`, RAM only, 0600)
#   ex4-rwbench sample begin|end NAME [MIB]          CPU, mv_xor interrupts, member writes around a client copy
#   ex4-rwbench dropcache            sync + drop the page cache (before a read test)
#   ex4-rwbench zap-zeros            remove stock's two leftover zero files, only if names + sizes + contents match
#   ex4-rwbench heartbeat            the client is alive (the guard stops by itself without one)
#   ex4-rwbench results-to-share     copy the results (+ v9.4 profile-*.txt) into Public/ex4-bench-v8/ (before the stop)
#   ex4-rwbench status               what is up right now (read-only)
#   ex4-rwbench print-conf samba4|ksmbd CLIENT_IP    the server config a serve would write (read-only, no secret)
#   ex4-rwbench stop [--for-reboot]  THE CLEAN STOP: servers down, sync, umount, knobs back, mdadm --stop, verify. Exit 0 =
#                                    md1 is not read-write anywhere, a reboot is safe. Idempotent; safe to run any time.
#
# THE WALLS (each one alone keeps a write off his array):
#   1. THE TOKEN. `up` refuses unless /tmp/ex4-rw-ok is a regular root-owned file, typed AFTER `arm`, holding exactly
#      the line `arm` printed (a fresh 12-hex nonce each arm, so no token from another session or another boot can
#      pass). No script writes that file: this one only reads it, then renames it away (one token = one rw session).
#   2. THE REBOOT PATHS. `up` refuses unless every way this trial reboots by itself (the S99 auto-return, the S03
#      deadman, procd's shutdown via /etc/rc.d/K01ex4-rwstop, ex4fan's fail-safe) first runs `ex4-rwbench stop
#      --for-reboot`, and unless /usr/sbin/ex4-rwbench is byte-identical to this script. A reboot with md1
#      read-write and mounted is the one outcome this tool must never allow.
#   3. A CLEAN ARRAY OR NOTHING. Exactly four SATA partitions 2, one array: superblock 1.0, raid5, 64K, left-symmetric,
#      4 devices, Feature Map 0x0/0x1 (no recovery, no reshape), State clean, Array State AAAA on all four, the same
#      Events count, no Resync/Recovery/Reshape line, no recorded bad blocks, every member writable in the kernel.
#      Then assembled --readonly first: /proc/mdstat must say (read-only) [4/4] [UUUU] with no resync line, else stop.
#   4. A CLEAN FILE SYSTEM OR NOTHING. The ext4 superblock (read from md1, never written by us): magic, VALID set,
#      ERROR clear, a journal, the needs-recovery flag CLEAR, no orphan list. A dirty file system stays with stock.
#   5. NOTHING SYNC-SHAPED. sync_action is set to `frozen` BEFORE the switch to read-write and checked after it: no
#      resync, check or repair can start behind our back (sdd carries a known bad sector; no scrub, ever, from here).
#   6. ONLY OUR FOLDER. Writes land only under Public/ex4-bench-v8/ (refused if it exists already); the only other
#      change is the removal of stock's two zero files, after their names, sizes and every byte (zeros) match.
#   7. MOUNTED THE CAREFUL WAY. ext4 rw with the journal on (data=ordered, barrier=1), errors=remount-ro,
#      noinit_itable (no background inode-table zeroing), noatime. No fsck, no tune2fs, no resize, no quota rewrite.
#      vm.dirty_bytes 64 MiB / dirty_background_bytes 16 MiB while rw: little in flight if the power goes.
#   8. BOUNDED IN TIME. A guard (its own process) runs the clean stop by itself after the rw window (`up
#      --window-min`, else EX4RW_WINDOW_MIN, default 25 minutes: sized for local + samba4 + ksmbd with NFS off),
#      after EX4RW_IDLE_MIN minutes without a client heartbeat (default 8), on any md / disk / ext4 error line in
#      the kernel log, or if ex4fan (the only fan control) is gone.
#   9. EVERY EXIT PATH STOPS. Every rw-phase command runs the clean stop on any failure or signal (trap EXIT INT
#      TERM HUP). SIGKILL cannot be trapped: the guard covers it. A hang of the kernel cannot be covered by anything
#      in software: docs/RWBENCH.md says what that costs (journal replay + a full resync on stock, ~9-10 h).
#      v9: SIGPIPE is ignored everywhere (a dead ssh link must not kill the shell before its stop runs: output to a
#      gone terminal just fails), and once THE CLEAN STOP starts it ignores HUP / INT / TERM until it is done (the
#      stop is never left half-way); it no longer kills the guard (the stop lock serialises two stops), so a stop
#      that ends UNSAFE still leaves the guard watching.
#  10. (v9) NO UNAUTHENTICATED LISTENER BY DEFAULT. SMB needs the per-session password. NFS (address trust only) is
#      refused unless `serve nfs` is given --unauthenticated-nfs. The servers never inherit the bench's lock files.
#      (v9.7) NFSv4.2 is the same address trust (sec=sys): the same flag, the same one-client, sync, all_squash export; it
#      opens FEWER doors (nfsd's 2049 only: no rpcbind, statd or mountd listener, checked from /proc/net after the start,
#      and v3 / 4.0 / 4.1 off, read back from nfsd's versions file; either check failing = refused + the clean stop).
#      (v9.8, v95 nit 1) and NO socket an nfs-utils process holds (rpc.mountd, rpc.statd, rpcbind, rpc.nfsd, nfsdcld, rpc.idmapd,
#      rpc.gssd, rpc.svcgssd, blkmapd: their /proc/PID/fd socket inodes matched against /proc/net) listens on a non-loopback
#      address on any port but 2049 (a random-port mountd is caught, not only 111 / 32778-32780).
#  11. (v9.3) KNOBS: RAM ONLY, BOUNDED, GIVEN BACK. skip_copy is written ONLY by `up`, after the rw switch and before the
#      ext4 mount (on a mounted array ext4 got no stable pages at mount time, so a page changed under an in-flight write
#      could leave parity silently wrong: LANE2-batching §3.3, raid5.c:7164-7172 + fs/super.c:1596-1597); any later
#      attempt is refused. `tune` runs only inside a session, every value bounded (stripe cache 256..4096, read-ahead
#      128..8192 KiB, group threads 0..2), each read back. `up` records every knob it may touch (stripe_cache_size,
#      group_thread_cnt, skip_copy, read_ahead_kb of md1 and of each member disk) BEFORE changing any, and THE CLEAN
#      STOP writes every recorded value back and reads it back (journalled) before it stops md1. Every results line
#      carries the knob values it was measured under. Nothing here is written to a disk.
#      (v9.4) The same holds for nfsd's max_block_size (bounded 64..1024 KiB, written only while no nfsd thread runs, the
#      kernel's value recorded first and written back at unserve / THE CLEAN STOP) and for the function profiler (`profile`
#      turns it on for one write and off again; THE CLEAN STOP writes 0 to it whenever it exists, so no exit path leaves
#      it on; a debugfs the verb mounted is unmounted). A knob that did not go back keeps its record (knobs.saved), so a
#      second `stop` retries it; skip_copy is never touched on a mounted array, any value; a member with no read_ahead_kb
#      is journalled and left alone (never recorded, never tuned) instead of refusing `up`.
#      (v9.7) nfsd's v4 grace time (nfsv4gracetime, 10 s for --vers 4.2, else never written) is held the same way. When the
#      kernel's max_block_size was 0 (auto: nfsd sizes it at its first start) it cannot be written back (the kernel clamps
#      a written 0 to 1024 BYTES, worse than leaving it): unserve leaves the value, says so ONCE as an INFO line, and every
#      later NFS line says the value was left by an earlier --max-block-kb. RAM only, gone at the reboot.
#
# Test mode (off the box only): EX4RW_TEST=1 with EX4RW_MEMBERS="/dev/loopA .. /dev/loopD" (loop devices ONLY),
# EX4RW_MD=/dev/md9N, EX4RW_TMP (not /tmp), EX4RW_ROOT (a fake / for the reboot-path checks), EX4RW_MNT, EX4RW_RUNID;
# (v9.4) EX4RW_NFSD_DIR (a fake /proc/fs/nfsd: threads + max_block_size), EX4RW_TRACING (a fake tracing dir), and
# EX4RW_TEST_NO_RA=/dev/loopN (that member's queue has no read_ahead_kb). Test mode never touches the real debugfs or nfsd.
# (v9.7) EX4RW_PROCNET (a fake /proc/net: tcp/tcp6/udp/udp6 for the listener check; absent = that check is skipped in test
# mode only), EX4RW_TEST_NFSD_VERSIONS (what the fake rpc.nfsd writes into the fake versions file), and EX4RW_TEST_TRIAL (a
# fake root: proc/cmdline, proc/interrupts, etc/openwrt_release, uname-r, ex4fan-running): with it, check_trial runs its
# real walls on those files (without it, test mode skips check_trial as before). On the box none of these exist.
# (v9.8) EX4RW_PROCFD (a fake /proc: PID/comm + PID/fd/N -> socket:[INODE], for the nfs-utils socket wall; absent = skipped in test
# mode only), EX4RW_NFSD_WAIT (the start-wait in s, test mode only), the fake rpc.nfsd's EX4RW_TEST_NFSD_RC (its exit code),
# EX4RW_TEST_NFSD_DELAY (s before its threads appear), EX4RW_TEST_NFSD_THREADS (how many it starts), EX4RW_TEST_NFSD_KMSG (a file
# of kernel lines it "logs", appended to EX4RW_TEST_DMESG, a fake dmesg).
# (v9.9) EX4RW_TEST_MEMPROC (a fake /proc for the memory receipt: meminfo, zoneinfo, buddyinfo, [slabinfo], sys/vm/min_free_kbytes,
# sys/vm/drop_caches: the nfsd prep writes 3 into THAT file; absent = no drop in test mode, the receipt says "not readable") and
# EX4RW_TEST_SLABSYS (a fake /sys/kernel/slab: <cache>/order|partial|cpu_slabs + alias symlinks).
# tests/rwbench/ runs every refusal path that way, against real loop devices + real md + real ext4 on a build box.
set -u
trap '' PIPE		# v9: a dead ssh link makes writes fail, it never kills this shell (the clean stop must run)
VERSION=v9-rwbench-9
case "$0" in /*) SELF=$0;; *) SELF=$(pwd)/$0;; esac		# v9: the guard and return-later re-run THIS file by its absolute path
TEST=${EX4RW_TEST:-0}
T=${EX4RW_TMP:-/tmp}
ROOT=${EX4RW_ROOT:-}
S=$T/ex4-rwbench
OK=$T/ex4-rw-ok
ACTIVE=$T/ex4-rw-active
MD=/dev/md1; MNT=/mnt/md1
BENCH=Public/ex4-bench-v8
ZDIR=Public/ex4-bench; ZFILES="bench-2g.bin bench-write-2g.bin"; ZSIZE=2147483648
LOCAL_MIB=2048
WINDOW_MIN=${EX4RW_WINDOW_MIN:-25}; IDLE_MIN=${EX4RW_IDLE_MIN:-8}; GUARD_SEC=${EX4RW_GUARD_SEC:-10}; RETURN_SEC=${EX4RW_RETURN_SEC:-300}
STAY=$T/ex4-stay
WINDOW_SEC=$((WINDOW_MIN * 60)); IDLE_SEC=$((IDLE_MIN * 60)); NEED_EXTRA=3072      # free space the bench needs past the local file: one 2 GiB copy + 1 GiB
STRIPE=${EX4RW_STRIPE:-128}               # ext4 stripe= hint in 4 KiB blocks; stock mounts with 128 (a mount option, nothing on disk)
SCACHE=${EX4RW_STRIPE_CACHE:-}            # md stripe_cache_size while rw (RAM only); empty = the kernel's own
BUSER=ex4bench; BUID=1100
IFACE=${EX4RW_IFACE:-br-lan}              # the LAN interface the servers bind to (a bond later: bond0)
RAW_MIB=1024; RAW_SKIP=8192                 # (v9.3) the raw md read = stock's method (bench-2026-11-17/common.sh)
NFSD=/proc/fs/nfsd                          # (v9.4) nfsd's control files (threads, max_block_size)
DBG=/sys/kernel/debug; TR=$DBG/tracing      # (v9.4) the function profiler lives here (CONFIG_FUNCTION_PROFILER: the v10b-prof twin)
NETP=/proc/net                              # (v9.7) the listener check reads tcp/tcp6/udp/udp6 here
PROCD=/proc; NFSD_WAIT=30; KMSGF=           # (v9.8) the nfs-utils socket wall reads PID/comm + PID/fd here; the nfsd start-wait (s)
UCBS="4093 65521 131071 1048573"; UCCP=65521   # (v9.8) the user-copy canary's odd read block sizes and its copy block size
MEMP=/proc; SLABS=/sys/kernel/slab; VMP=/proc/sys/vm; NFSD_PREP=every   # (v9.9) the memory receipt reads these; the nfsd prep writes VMP/drop_caches
CT_CMD=/proc/cmdline; CT_IRQ=/proc/interrupts; CT_REL=/etc/openwrt_release; CT_KREL=; CT_FAN=     # (v9.7) check_trial's inputs (real on the box)
BADPAT='Disk failure|Operation continuing on|I/O error, dev sd|end_request: I/O error|EXT4-fs error|EXT4-fs warning.*md|Remounting filesystem read-only|journal commit I/O error|md/raid.*read error|md/raid.*write error'

say() { echo "ex4-rwbench: $*"; [ "$TEST" = 1 ] || logger -t ex4-rwbench "$*" 2>/dev/null; return 0; }
note() { say "$*"; [ -d "$S" ] && echo "$(up_s) $*" >> "$S/journal.txt"; [ "$TEST" = 1 ] || { [ -x /usr/sbin/ex4log ] && /usr/sbin/ex4log note "rwbench: $*" 2>/dev/null; }; return 0; }
die() { echo "ex4-rwbench: REFUSED: $*" >&2; [ -d "$S" ] && echo "$(up_s) REFUSED: $*" >> "$S/journal.txt"; [ "$TEST" = 1 ] || logger -t ex4-rwbench "REFUSED: $*" 2>/dev/null; exit 1; }
up_s() { awk '{ printf "%d", $1 }' /proc/uptime; }
up_cs() { awk '{ printf "%d", $1 * 100 }' /proc/uptime; }
lmtime() { ls -ln "$1" 2>/dev/null | awk '{ print $3 " " $5 }'; }        # owner uid, size (no stat applet in this busybox)

# ---------- test mode: loop devices only, never the real paths ----------
if [ "$TEST" = 1 ]; then
	MD=${EX4RW_MD:-}; MNT=${EX4RW_MNT:-}
	case "$MD" in /dev/md9[0-9]) ;; *) echo "ex4-rwbench: REFUSED: test mode needs EX4RW_MD=/dev/md90..md99" >&2; exit 1;; esac
	[ "$T" != /tmp ] && [ -n "$ROOT" ] && [ -n "$MNT" ] || { echo "ex4-rwbench: REFUSED: test mode needs EX4RW_TMP (not /tmp), EX4RW_ROOT and EX4RW_MNT" >&2; exit 1; }
	for m in ${EX4RW_MEMBERS:-}; do case "$m" in /dev/loop[0-9]*) ;; *) echo "ex4-rwbench: REFUSED: test mode takes loop devices only, not $m" >&2; exit 1;; esac; done
	LOCAL_MIB=${EX4RW_LOCAL_MIB:-64}; NEED_EXTRA=8; RAW_MIB=${EX4RW_RAW_MIB:-32}; RAW_SKIP=${EX4RW_RAW_SKIP:-16}
	WINDOW_SEC=${EX4RW_WINDOW_SEC:-$WINDOW_SEC}; IDLE_SEC=${EX4RW_IDLE_SEC:-$IDLE_SEC}
	NFSD=${EX4RW_NFSD_DIR:-$T/no-nfsd}; TR=${EX4RW_TRACING:-$T/no-tracing}; DBG=$T/no-debugfs     # v9.4: fakes only
	NETP=${EX4RW_PROCNET:-$T/no-procnet}                                                            # v9.7: fakes only
	PROCD=${EX4RW_PROCFD:-$T/no-procfd}; KMSGF=${EX4RW_TEST_DMESG:-}                                # v9.8: fakes only
	MEMP=${EX4RW_TEST_MEMPROC:-$T/no-memproc}; SLABS=${EX4RW_TEST_SLABSYS:-$T/no-slabsys}; VMP=$MEMP/sys/vm     # v9.9: fakes only
	case "${EX4RW_NFSD_WAIT:-}" in ''|*[!0-9]*) ;; *) NFSD_WAIT=$EX4RW_NFSD_WAIT;; esac
	CTR=${EX4RW_TEST_TRIAL:-}
	if [ -n "$CTR" ]; then CT_CMD=$CTR/proc/cmdline; CT_IRQ=$CTR/proc/interrupts; CT_REL=$CTR/etc/openwrt_release; CT_KREL=$CTR/uname-r; CT_FAN=$CTR/ex4fan-running; fi
fi
PE=$TR/function_profile_enabled
MDN=${MD##*/}
RB=$ROOT/usr/sbin/ex4-rwbench

members() {       # partition 2 of every disk behind a SATA (ata) host, never USB; in test mode the given loop devices
	if [ "$TEST" = 1 ]; then for m in ${EX4RW_MEMBERS:-}; do echo "$m"; done; return 0; fi
	for b in /sys/block/sd?; do
		[ -e "$b" ] || continue
		d=${b##*/}
		readlink -f "$b/device" | grep -q '/ata[0-9]' || continue
		[ -b "/dev/${d}2" ] && echo "/dev/${d}2"
	done
}
field() { awk -F' : ' -v k="$2" '{ g = $1; sub(/^ +/, "", g) } g == k { v = $2; sub(/ +$/, "", v); print v; exit }' "$1"; }
mounted_rw() { awk -v m="$MNT" '$2 == m { split($4, o, ","); if (o[1] == "rw") f = 1 } END { exit !f }' /proc/mounts; }
mounted() { awk -v m="$MNT" '$2 == m { f = 1 } END { exit !f }' /proc/mounts; }
md_up() { grep -q "^$MDN " /proc/mdstat 2>/dev/null; }
astate() { cat "/sys/block/$MDN/md/array_state" 2>/dev/null || echo none; }

need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }
need_dir() { mkdir -p "$S" && chmod 700 "$S" || die "cannot make $S"; }

# ---------- (v9.3) the md / read-ahead knobs: RAM only (wall 11) ----------
kv() { cat "$1" 2>/dev/null || echo '?'; }
mqueue() {           # $1 = a member (/dev/sdX2 or a test loop): the queue dir of the DISK it sits on
	d=${1##*/}
	[ "$TEST" = 1 ] && [ "$1" = "${EX4RW_TEST_NO_RA:-}" ] && { echo "$T/no-queue-$d"; return 0; }     # v9.4 test: a member without one
	if [ -d "/sys/block/$d/queue" ]; then echo "/sys/block/$d/queue"; return 0; fi
	q=$(readlink -f "/sys/class/block/$d" 2>/dev/null) && [ -n "$q" ] && echo "${q%/*}/queue"      # .../block/sda/sda2 -> .../block/sda/queue
}
knobs() {            # the knob values right now, one word list (every results line carries it)
	m=/sys/block/$MDN/md; r=
	for p in ${EXAMINED:-$(cat "$S/members" 2>/dev/null)}; do r="$r${r:+,}$(kv "$(mqueue "$p")/read_ahead_kb")"; done
	echo "sc=$(kv $m/stripe_cache_size) gt=$(kv $m/group_thread_cnt) skip=$(kv $m/skip_copy) ra_md=$(kv /sys/block/$MDN/queue/read_ahead_kb) ra_members=${r:-?}"
}
knobs_save() {       # at up, before ANY knob is changed: what THE CLEAN STOP writes back
	m=/sys/block/$MDN/md; : > "$S/knobs.tmp"
	for k in stripe_cache_size group_thread_cnt skip_copy; do [ -r "$m/$k" ] && echo "md $k $(cat "$m/$k")" >> "$S/knobs.tmp"; done
	f=/sys/block/$MDN/queue/read_ahead_kb; [ -r "$f" ] && echo "ra $f $(cat "$f")" >> "$S/knobs.tmp"
	for p in $EXAMINED; do      # v9.4 (review nit 3): a member with no read_ahead_kb is journalled and left alone, never a refusal
		q=$(mqueue "$p")
		if [ ! -r "$q/read_ahead_kb" ]; then note "up: no read_ahead_kb for $p (${q:-no queue dir}): that member's read-ahead is not recorded and will not be tuned"; continue; fi
		echo "ra $q/read_ahead_kb $(cat "$q/read_ahead_kb")" >> "$S/knobs.tmp"
	done
	mv "$S/knobs.tmp" "$S/knobs.saved" || die "cannot record the knobs"
}
knobs_restore() {    # THE CLEAN STOP: every recorded knob back, read back; md's only while md is still assembled
	[ -s "$S/knobs.saved" ] || return 0
	KOK=; KBAD=
	while read kind k v; do
		case "$kind" in
		md) md_up || continue; f=/sys/block/$MDN/md/$k; lab=$k
			if [ "$k" = skip_copy ] && mounted; then       # v9.4 (review nit 2): never written on a mounted array, any value
				if [ "$(cat "$f" 2>/dev/null)" = "$v" ]; then KOK="$KOK $k=$v"; else KBAD="$KBAD $k (still mounted: not touched, reads $(cat "$f" 2>/dev/null), recorded $v)"; fi
				continue
			fi;;
		ra) f=$k; case "$f" in /sys/block/*/queue/read_ahead_kb|/sys/devices/*/queue/read_ahead_kb) ;; *) continue;; esac
			case "$f" in /sys/block/$MDN/*) md_up || continue;; esac
			lab=${f%/queue/read_ahead_kb}; lab="ra:${lab##*/}";;
		*) continue;;
		esac
		[ "$(cat "$f" 2>/dev/null)" = "$v" ] || echo "$v" > "$f" 2>/dev/null
		if [ "$(cat "$f" 2>/dev/null)" = "$v" ]; then KOK="$KOK $lab=$v"; else KBAD="$KBAD $lab (wanted $v, reads $(cat "$f" 2>/dev/null))"; fi
	done < "$S/knobs.saved"
	if [ -n "$KBAD" ]; then      # v9.4 (review nit 1): the record stays, so a second `stop` retries what did not go back
		cp "$S/knobs.saved" "$S/knobs.partial-$(up_s)"
		note "clean stop: knobs restored (read back):$KOK; NOT restored:$KBAD (record kept in knobs.saved: 'ex4-rwbench stop' retries)"
	else
		mv "$S/knobs.saved" "$S/knobs.restored-$(up_s)"; note "clean stop: knobs restored (read back):$KOK"
	fi
	return 0
}
# ---------- (v9.4) nfsd's max_block_size and the function profiler: RAM only, bounded, given back (wall 11) ----------
nfs_threads() {      # nfsd threads running now (0 when the nfsd file system is not even mounted)
	if [ "$TEST" = 1 ] || grep -q " $NFSD nfsd " /proc/mounts 2>/dev/null; then t=$(cat "$NFSD/threads" 2>/dev/null); echo "${t:-0}"; else echo 0; fi
}
nfs_tag() {          # the NFS suffix of a results line, only while the server is nfs
	case "$(cat "$S/server" 2>/dev/null)" in
	nfs*) w="kernel default"
		if [ -e "$S/nfs_mbs.this-serve" ]; then w="set by --max-block-kb"
		elif [ -e "$S/nfs_mbs.auto-left" ]; then w="left by an earlier --max-block-kb: the kernel's auto 0 cannot be written back"
		elif [ -s "$S/nfs_mbs.saved" ]; then w="set by --max-block-kb"; fi
		echo " | nfs max_block_size=$(kv "$NFSD/max_block_size") ($w)$([ -s "$S/nfs_serve" ] && echo " $(cat "$S/nfs_serve")")";;      # v9.7: vers/threads only when asked for
	esac
}
nfs_block_set() {    # $1 = KiB: before ANY nfsd thread starts; the kernel's value recorded first; read back
	b=$(($1 * 1024))
	if [ "$TEST" != 1 ]; then
		[ -e /sys/module/nfsd ] || modprobe nfsd 2>/dev/null
		grep -q " $NFSD nfsd " /proc/mounts || mount -t nfsd nfsd "$NFSD" || die "cannot mount $NFSD"
	fi
	[ -e "$NFSD/max_block_size" ] || die "no $NFSD/max_block_size in this kernel"
	[ "$(nfs_threads)" = 0 ] || die "nfsd runs ($(nfs_threads) threads): max_block_size is taken only before nfsd starts"
	[ -s "$S/nfs_mbs.saved" ] || cat "$NFSD/max_block_size" > "$S/nfs_mbs.saved" || die "cannot record max_block_size"
	echo "$b" > "$NFSD/max_block_size" 2>/dev/null
	r=$(cat "$NFSD/max_block_size" 2>/dev/null); [ "$r" = "$b" ] || die "the kernel did not take max_block_size $b (reads $r)"
	: > "$S/nfs_mbs.this-serve"
	note "serve nfs: max_block_size $(cat "$S/nfs_mbs.saved") -> $b (written before any nfsd thread, read back)"
}
nfs_block_restore() {    # nfsd stopped: the kernel's own value back, read back; the record stays if it did not take
	rm -f "$S/nfs_mbs.this-serve"
	[ -s "$S/nfs_mbs.saved" ] || return 0
	v=$(cat "$S/nfs_mbs.saved")
	if [ "$v" = 0 ]; then      # v9.7 (run 15 nit): 0 = auto; a written 0 is clamped to 1024 BYTES by the kernel: never written back
		if [ ! -e "$S/nfs_mbs.auto-left" ]; then
			: > "$S/nfs_mbs.auto-left"
			note "unserve: INFO: nfs max_block_size was the kernel's auto (0) before --max-block-kb; 0 is not writable back (the kernel would clamp it to 1024 bytes), so it stays $(cat "$NFSD/max_block_size" 2>/dev/null) until the reboot (RAM only); later NFS lines say so"
		fi
		return 0
	fi
	[ -e "$NFSD/max_block_size" ] && [ "$(nfs_threads)" = 0 ] && echo "$v" > "$NFSD/max_block_size" 2>/dev/null
	if [ "$(cat "$NFSD/max_block_size" 2>/dev/null)" = "$v" ]; then rm -f "$S/nfs_mbs.saved"; note "unserve: nfs max_block_size back to $v (read back)"
	else note "unserve: nfs max_block_size NOT back to $v (reads $(cat "$NFSD/max_block_size" 2>/dev/null)): RAM only, gone at the reboot; record kept"; fi
	return 0
}
nfs_grace_set() {    # v9.7, $1 = s: nfsd's v4 grace time, before any nfsd thread; the kernel's value recorded first; read back
	g=$NFSD/nfsv4gracetime
	[ -e "$g" ] || die "no $g in this kernel (no NFSv4 in nfsd?)"
	[ "$(nfs_threads)" = 0 ] || die "nfsd runs: nfsv4gracetime is taken only before nfsd starts"
	[ -s "$S/nfs_grace.saved" ] || cat "$g" > "$S/nfs_grace.saved" || die "cannot record nfsv4gracetime"
	echo "$1" > "$g" 2>/dev/null; [ "$(cat "$g" 2>/dev/null)" = "$1" ] || die "the kernel did not take nfsv4gracetime $1 (reads $(cat "$g" 2>/dev/null))"
	note "serve nfs: nfsv4gracetime $(cat "$S/nfs_grace.saved") -> $1 s (written before any nfsd thread, read back: the first OPEN waits at most this long)"
}
nfs_grace_restore() {    # nfsd stopped: the kernel's own grace time back, read back; the record stays if it did not take
	[ -s "$S/nfs_grace.saved" ] || return 0
	v=$(cat "$S/nfs_grace.saved"); g=$NFSD/nfsv4gracetime
	[ -e "$g" ] && [ "$(nfs_threads)" = 0 ] && echo "$v" > "$g" 2>/dev/null
	if [ "$(cat "$g" 2>/dev/null)" = "$v" ]; then rm -f "$S/nfs_grace.saved"; note "unserve: nfsv4gracetime back to $v (read back)"
	else note "unserve: nfsv4gracetime NOT back to $v (reads $(cat "$g" 2>/dev/null)): RAM only, gone at the reboot; record kept"; fi
	return 0
}
listening() {        # v9.7, $1 = port: a TCP LISTEN socket or any UDP socket bound to it, IPv4 or IPv6 (from $NETP)
	h=$(printf '%04X' "$1")
	cat "$NETP/tcp" "$NETP/tcp6" 2>/dev/null | awk -v h="$h" '$1 ~ /^[0-9]+:$/ { a = $2; sub(/.*:/, "", a); if (toupper(a) == h && $4 == "0A") f = 1 } END { exit !f }' && return 0
	cat "$NETP/udp" "$NETP/udp6" 2>/dev/null | awk -v h="$h" '$1 ~ /^[0-9]+:$/ { a = $2; sub(/.*:/, "", a); if (toupper(a) == h) f = 1 } END { exit !f }'
}
nfsutils_inodes() {  # v9.8: "INODE COMM" for every socket an nfs-utils process holds ($PROCD/PID/comm + $PROCD/PID/fd/* -> socket:[INODE])
	for p in "$PROCD"/[0-9]*; do
		[ -r "$p/comm" ] || continue; c=$(cat "$p/comm" 2>/dev/null)
		case "$c" in rpc.mountd|rpc.statd|rpcbind|rpc.nfsd|nfsdcld|rpc.idmapd|rpc.gssd|rpc.svcgssd|blkmapd) ;; *) continue;; esac
		for l in "$p"/fd/*; do r=$(readlink "$l" 2>/dev/null) || continue; case "$r" in 'socket:['*']') r=${r#socket:[}; echo "${r%]} $c";; esac; done
	done
}
nfsutils_lan_listeners() {    # v9.8: "PROTO PORT COMM" for each of those sockets listening (TCP LISTEN, any bound UDP) on a non-loopback address, port != 2049
	nfsutils_inodes > "$S/nfsu.inodes"
	[ -s "$S/nfsu.inodes" ] || return 0
	for pr in tcp tcp6 udp udp6; do
		[ -r "$NETP/$pr" ] || continue
		awk -v pr="$pr" '
			function hx(s,   i, n) { n = 0; s = toupper(s); for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789ABCDEF", substr(s, i, 1)) - 1; return n }
			function lo(a) { a = toupper(a); if (length(a) == 8) return substr(a, 7, 2) == "7F"
				return a == "00000000000000000000000001000000" || (substr(a, 1, 24) == "0000000000000000FFFF0000" && substr(a, 31, 2) == "7F") }
			FNR == NR { cm[$1] = $2; next }
			$1 ~ /^[0-9]+:$/ { a = $2; pt = a; sub(/.*:/, "", pt); sub(/:[^:]*$/, "", a)
				if (!($10 in cm)) next; if (pr ~ /^tcp/ && $4 != "0A") next; if (lo(a)) next
				p = hx(pt); if (p != 2049) print pr " " p " " cm[$10] }' "$S/nfsu.inodes" "$NETP/$pr"
	done
}
nfs4_verify() {      # v9.7, after rpc.nfsd: v4.2 only (v3, 4.0, 4.1 off) and nfsd's 2049 the only door (no rpcbind / statd / mountd)
	vv=$(cat "$NFSD/versions" 2>/dev/null)
	for w in -3 +4 +4.2 -4.0 -4.1; do case " $vv " in *" $w "*) ;; *) die "serve nfs --vers 4.2: nfsd's versions read '$vv', want $w in it (v4.2 only): stopping";; esac; done
	case " $vv " in *" +3 "*|*" +2 "*) die "serve nfs --vers 4.2: nfsd's versions read '$vv': v2/v3 is on: stopping";; esac
	if [ "$TEST" != 1 ] || [ -d "$NETP" ]; then
		for pt in 111 32778 32779 32780; do listening "$pt" && die "serve nfs --vers 4.2: something listens on port $pt (rpcbind 111 / statd 32778-9 / mountd 32780): v4.2 must open nfsd's 2049 only: stopping"; done
		listening 2049 || die "serve nfs --vers 4.2: nothing listens on TCP 2049 after rpc.nfsd: stopping"
		LCHK="listeners: 2049 only (111, 32778, 32779, 32780 closed)"
		if [ "$TEST" != 1 ] || [ -d "$PROCD" ]; then      # v9.8 (v95 nit 1): any LAN socket of an nfs-utils process off 2049 (a random-port mountd)
			BADL=$(nfsutils_lan_listeners | head -3 | tr '\n' ';')
			[ -z "$BADL" ] || die "serve nfs --vers 4.2: an nfs-utils process listens off 2049 on a LAN address ($BADL): v4.2 must open nfsd's 2049 only: stopping"
			LCHK="$LCHK; nfs-utils sockets on LAN: none off 2049 ($(wc -l < "$S/nfsu.inodes" | tr -d ' ') socket(s) of nfs-utils processes checked)"
		else LCHK="$LCHK; nfs-utils sockets: not checked (test mode without EX4RW_PROCFD)"; fi
	else LCHK="listeners: not checked (test mode without EX4RW_PROCNET)"; fi
	note "serve nfs: nfsd versions '$vv' (v4.2 only, read back); $LCHK"
}
nfs_threads_check() {    # v9.7, $1 = wanted: nfsd's threads read back
	[ "$(nfs_threads)" = "$1" ] || die "serve nfs --threads $1: nfsd reads $(nfs_threads) threads: stopping"
	note "serve nfs: nfsd threads $1 (read back)"
}
prof_off() {         # the function profiler off (if this kernel has one), read back; exit 0 = off or absent
	[ -e "$PE" ] || return 0
	[ "$(cat "$PE" 2>/dev/null)" = 0 ] || echo 0 > "$PE" 2>/dev/null
	[ "$(cat "$PE" 2>/dev/null)" = 0 ]
}
dbg_umount() {       # the debugfs `profile` mounted (never one it found mounted)
	[ -e "$S/debugfs-by-us" ] || return 0
	umount "$DBG/tracing" 2>/dev/null; umount "$DBG" 2>/dev/null && rm -f "$S/debugfs-by-us"
	return 0
}

# ---------- the walls, read-only ----------
check_trial() {      # v9.7: the inputs are variables (real /proc + /etc on the box; a fake root only under TEST + EX4RW_TEST_TRIAL)
	if [ "$TEST" = 1 ]; then [ -n "${CTR:-}" ] || return 0; fi
	grep -q 'ex4boot_run=' "$CT_CMD" || die "this is not the EX4 RAM trial (no ex4boot_run= in /proc/cmdline): never on stock, never anywhere else"
	grep -q "DISTRIB_ID='OpenWrt'" "$CT_REL" 2>/dev/null || die "not OpenWrt"
	kr=$(if [ -n "$CT_KREL" ]; then cat "$CT_KREL" 2>/dev/null; else uname -r; fi)
	case "$kr" in 6.12.*) ;; *) die "kernel $kr: this bench is written for the v7 6.12 kernel";; esac
	# run 15 (Nov 17 2026): an xor-off bundle (run id ends -xoroff, both orion-xor DTB nodes disabled) must show NO xor line
	# (the proof the variant is real: async_tx then uses the CPU xor); every other bundle must show the two engines.
	case "$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^ex4boot_run=/) print $i }' "$CT_CMD")" in
	*-xoroff|*-xoroff-*) grep -q 'xor' "$CT_IRQ" && die "run id says xoroff but /proc/interrupts has an xor line: this is not the xor-off kernel"
		: ;;
	*) grep -q 'xor' "$CT_IRQ" || die "no mv_xor interrupt line: this kernel has no XOR engines (the v7 kernel has two)";;
	esac
	if [ -n "$CT_FAN" ]; then [ -e "$CT_FAN" ]; else pidof ex4fan >/dev/null 2>&1; fi || die "ex4fan is not running: nothing manages the fan, no heavy disk work without it"
}
check_reboot_paths() {
	for f in "$ROOT/etc/init.d/ex4-trial" "$ROOT/etc/init.d/ex4-deadman" "$ROOT/etc/init.d/ex4-rwstop"; do
		[ -f "$f" ] || die "reboot path $f is missing (the overlay was built without --rwbench)"
		grep -q 'ex4-rwbench stop --for-reboot' "$f" || die "reboot path $f does not run 'ex4-rwbench stop --for-reboot' before it reboots: a reboot could catch md1 read-write (rebuild the overlay with the RWBENCH patch)"
	done
	[ -e "$ROOT/etc/rc.d/K01ex4-rwstop" ] || die "no $ROOT/etc/rc.d/K01ex4-rwstop: a hand 'reboot' would not stop md1 first"
	if [ "$TEST" != 1 ]; then
		grep -q 'ex4-rw-active' /usr/sbin/ex4fan 2>/dev/null || die "ex4fan's fail-safe reboot does not know the rw bench (no 'ex4-rw-active' in /usr/sbin/ex4fan): build ex4fan with the RWBENCH patch"
	fi
	[ -f "$RB" ] || die "$RB is missing: the reboot paths call it"
	[ "$(md5sum < "$RB" | cut -d' ' -f1)" = "$(md5sum < "$SELF" | cut -d' ' -f1)" ] || die "$RB differs from the script being run ($SELF): the reboot paths would run another stop"
}
check_tools() {
	for t in mdadm blockdev mount umount dd sync awk hexdump cmp md5sum flock setsid killall pidof find; do
		command -v "$t" >/dev/null 2>&1 || die "no $t"
	done
}
EXAMINED=; EV0=; UUID0=
check_examine() {      # every member: the walls of item 3. Writes only $S/examine-*.txt
	set -- $(members)
	[ $# = 4 ] || die "found $# member partitions ($*), want 4"
	EXAMINED=$*
	md_up && die "$MD is already assembled ($(grep "^$MDN " /proc/mdstat)): stop it first (ex4-md-ro stop), then run this again"
	for p in "$@"; do grep -q "${p##*/}\[" /proc/mdstat && die "$p is already in an md array: $(grep "${p##*/}\[" /proc/mdstat)"; done
	out=$S/examine-before.txt; : > "$out"; UUID0=; EV0=; ROLES=
	for p in "$@"; do
		[ "$(blockdev --getro "$p" 2>/dev/null)" = 0 ] || die "$p is read-only in the kernel (ex4-md-ro set it this boot): rw needs a fresh trial boot"
		E=$S/ex.$$; mdadm --examine "$p" > "$E" 2>&1 || { cat "$E" >> "$out"; rm -f "$E"; die "mdadm --examine $p failed (see $out)"; }
		{ echo "=== $p"; cat "$E"; } >> "$out"
		V=$(field "$E" Version); U=$(field "$E" 'Array UUID'); L=$(field "$E" 'Raid Level'); C=$(field "$E" 'Chunk Size')
		Y=$(field "$E" Layout); St=$(field "$E" State); Ev=$(field "$E" Events); N=$(field "$E" 'Raid Devices')
		F=$(field "$E" 'Feature Map'); A=$(field "$E" 'Array State'); R=$(field "$E" 'Device Role')
		grep -qE '^ *(Resync Offset|Recovery Offset|Reshape pos|Delta Devices|New Layout|New Chunksize)' "$E" && { rm -f "$E"; die "$p: a resync / recovery / reshape is recorded in its superblock: stays with stock"; }
		rm -f "$E"
		[ "$V" = 1.0 ] || die "$p: superblock version '$V', want 1.0"
		[ "$L" = raid5 ] || die "$p: level '$L', want raid5"
		[ "$C" = 64K ] || die "$p: chunk '$C', want 64K"
		[ "$Y" = left-symmetric ] || die "$p: layout '$Y', want left-symmetric"
		[ "$N" = 4 ] || die "$p: raid devices '$N', want 4"
		case "$F" in 0x0|0x1) ;; *) die "$p: feature map '$F' (0x2 = recovery in progress, 0x4 = reshape ...), want 0x0 or 0x1";; esac
		[ "$St" = clean ] || die "$p: state '$St', want clean (active = written to without a clean stop: a resync is owed; stays with stock)"
		case "$A" in AAAA*) ;; *) die "$p: array state '$A', want AAAA (all four active)";; esac
		case "$R" in 'Active device '[0-3]) ROLES="$ROLES ${R#Active device }";; *) die "$p: device role '$R', want an active device 0..3";; esac
		[ -n "$U" ] || die "$p: no Array UUID"
		[ -z "$UUID0" ] && { UUID0=$U; EV0=$Ev; }
		[ "$U" = "$UUID0" ] || die "$p: array UUID $U differs from $UUID0"
		[ "$Ev" = "$EV0" ] || die "$p: events $Ev differ from $EV0 (members out of step: stays with stock)"
		B=$(mdadm --examine-badblocks "$p" 2>&1)
		echo "$B" | grep -qE 'is empty|No bad-blocks list' || die "$p: md has bad blocks recorded on it ($(echo "$B" | head -3 | tr '\n' ' ')): stays with stock"
	done
	[ "$(echo $ROLES | tr ' ' '\n' | sort | tr '\n' ' ')" = "0 1 2 3 " ] || die "device roles '$ROLES' are not exactly 0 1 2 3"
}
SB_OUT=
check_fs_sb() {        # the ext4 superblock of the ASSEMBLED (read-only) array: item 4. Reads 1 KiB at byte 1024.
	H=$(dd if="$MD" bs=1024 skip=1 count=1 2>/dev/null | hexdump -v -e '1/1 "%02x "')
	SB_OUT=$(echo "$H" | awk '
		function le(o, n,   i, v) { v = 0; for (i = n - 1; i >= 0; i--) v = v * 256 + hx(b[o + i + 1]); return v }
		function hx(s,   i, n) { n = 0; for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1; return n }
		function bit(v, m) { return int(v / m) % 2 }
		{ n = split($0, b, " ") }
		END {
			if (n < 1024) { print "short"; exit }
			magic = le(56, 2); state = le(58, 2); compat = le(92, 4); incompat = le(96, 4); rocompat = le(100, 4); orphan = le(232, 4)
			bs = 1024; for (i = le(24, 4); i > 0; i--) bs *= 2       # no ^: some busybox awk builds have no math
			fb = le(12, 4) + (bit(incompat, 128) ? le(344, 4) * 4294967296 : 0)     # the high word counts only with 64bit (0x80)
			printf "magic=%x state=%d compat=%x incompat=%x rocompat=%x orphan=%d journal=%d recover=%d valid=%d error=%d free_mib=%d\n", magic, state, compat, incompat, rocompat, orphan, bit(compat, 4), bit(incompat, 4), bit(state, 1), bit(state, 2), fb * bs / 1048576
		}')
	echo "$SB_OUT" > "$S/ext4-sb${SB_SUFFIX:-}.txt"
	sbv() { echo "$SB_OUT" | tr ' ' '\n' | awk -F= -v k="$1" '$1 == k { print $2 }'; }
	[ "$(sbv magic)" = ef53 ] || { echo "ext4 superblock not found ($SB_OUT)"; return 1; }
	[ "$(sbv journal)" = 1 ] || { echo "no journal on the file system ($SB_OUT)"; return 1; }
	[ "$(sbv valid)" = 1 ] && [ "$(sbv error)" = 0 ] || { echo "file system state not clean / errors recorded ($SB_OUT): stays with stock"; return 1; }
	[ "$(sbv recover)" = 0 ] || { echo "the journal needs recovery (needs_recovery set: the last mount was not cleanly unmounted) ($SB_OUT): stays with stock"; return 1; }
	[ "$(sbv orphan)" = 0 ] || { echo "orphan inode list not empty ($SB_OUT): a rw mount would delete files: stays with stock"; return 1; }
	FREE_MIB=$(sbv free_mib)
	return 0
}

# ---------- the token ----------
expected_token() { [ -s "$S/nonce" ] || return 1; echo "EX4-RW $(cat "$S/runid") $(cat "$S/nonce")"; }
gate() {             # exit status 0 only for the exact token, typed after the last arm
	X=$(expected_token) || { echo "not armed (run: ex4-rwbench arm)"; return 1; }
	[ -e "$OK" ] || { echo "no $OK yet"; return 1; }
	[ -L "$OK" ] && { echo "$OK is a symlink"; return 1; }
	[ -f "$OK" ] || { echo "$OK is not a regular file"; return 1; }
	set -- $(lmtime "$OK")
	[ "${1:-x}" = 0 ] || { echo "$OK is not owned by root"; return 1; }
	[ "${2:-999}" -le 200 ] 2>/dev/null || { echo "$OK is too big to be a token"; return 1; }
	[ -n "$(find "$OK" -newer "$S/nonce" 2>/dev/null)" ] || { echo "$OK is older than the last arm: type the new token"; return 1; }
	[ "$(wc -l < "$OK" | tr -d ' ')" -le 1 ] || { echo "$OK holds more than one line"; return 1; }
	[ "$(cat "$OK")" = "$X" ] || { echo "$OK does not hold the token the last arm printed"; return 1; }
	return 0
}

# ---------- snapshots around a test ----------
snap() {             # $1 = file: uptime(cs), cpu line, xor interrupt sums, sectors written per member + md
	{
		echo "t $(up_cs)"
		head -1 /proc/stat
		awk '/xor/ { s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break; print "xor " $NF " " s }' /proc/interrupts
		for p in $EXAMINED $MD; do awk -v d="${p##*/}" '$3 == d { print "dsk " d " " $10 }' /proc/diskstats; done
	} > "$1"
}
report() {           # $1 = name, $2 = a, $3 = b, $4 = MiB moved, [$5 = seconds measured by the client]
	awk -v name="$1" -v mib="$4" -v csec="${5:-}" -v md="$MDN" -v sc="$(cat /sys/block/$MDN/md/stripe_cache_size 2>/dev/null)" -v kn="$(knobs)" -v nb="$(nfs_tag)" '
		FNR == 1 { f++ }
		$1 == "t" { t[f] = $2 }
		$1 == "cpu" { for (i = 2; i <= 9; i++) c[f, i] = $i }
		$1 == "xor" { x[f, $2] = $3; xn[$2] = 1 }
		$1 == "dsk" { d[f, $2] = $3; dn[$2] = 1 }
		END {
			sec = (t[2] - t[1]) / 100; if (sec <= 0) sec = 0.01
			tot = 0; for (i = 2; i <= 9; i++) { v[i] = c[2, i] - c[1, i]; tot += v[i] } if (tot <= 0) tot = 1
			busy = 100 * (tot - v[5] - v[6]) / tot
			w = (csec != "" && csec > 0) ? csec : sec; rate = mib / w
			printf "%s: %d MiB in %.1f s = %.1f MiB/s%s | box window %.1f s, cpu busy %.1f%% (user %.1f sys %.1f softirq %.1f iowait %.1f) = %.1f cpu-ms/MiB | ", name, mib, w, rate, (csec != "" ? " (client clock)" : ""), sec, busy, 100 * (v[2] + v[3]) / tot, 100 * v[4] / tot, 100 * v[8] / tot, 100 * v[6] / tot, (rate > 0 ? busy * 10 / rate : 0)
			s = ""; for (k in xn) { printf "%sxor %s +%d", s, k, x[2, k] - x[1, k]; s = ", " } if (s == "") printf "xor: no interrupt line"
			mw = 0; for (k in dn) if (k != md) mw += (d[2, k] - d[1, k]) / 2048
			printf " | members wrote %.0f MiB, md %s wrote %.0f MiB, stripe_cache %s | knobs %s%s\n", mw, md, (d[2, md] - d[1, md]) / 2048, sc, kn, nb
		}' "$2" "$3"
}

# ---------- servers (each one: for ONE client address, on the bench folder only, with a password) ----------
boxip() { ip -4 addr show dev br-lan 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }'; }
valid_ip() { echo "$1" | awk -F. 'NF == 4 { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1; if ($1 == 0 || $1 == 127 || $1 >= 224) exit 1; exit 0 } { exit 1 }'; }
ensure_user() {      # a unix account for the share's files, in the RAM root only; no shell, no password, no login
	[ "$TEST" = 1 ] && return 0
	grep -q "^$BUSER:" /etc/passwd || echo "$BUSER:x:$BUID:$BUID:ex4 rw bench:/var/empty:/bin/false" >> /etc/passwd
	grep -q "^$BUSER:" /etc/group || echo "$BUSER:x:$BUID:" >> /etc/group
	grep -q "^$BUSER:" /etc/shadow || echo "$BUSER:*:0:0:99999:7:::" >> /etc/shadow
}
samba_conf() {       # $1 = state dir: the bench's smb.conf on stdout (no secret in it)
	D=$1; cat <<EOF
[global]
	netbios name = EX4-BENCH
	server role = standalone server
	security = user
	interfaces = $IFACE
	bind interfaces only = yes
	hosts allow = $CLIENT
	hosts deny = 0.0.0.0/0
	map to guest = never
	restrict anonymous = 2
	invalid users = root
	server min protocol = SMB2_10
	disable netbios = yes
	smb ports = 445
	load printers = no
	printcap name = /dev/null
	passdb backend = smbpasswd:$D/private/smbpasswd
	private dir = $D/private
	lock directory = $D/lock
	state directory = $D/state
	cache directory = $D/cache
	pid directory = $D/pid
	ncalrpc dir = $D/ncalrpc
	log file = $D/log/log.%m
	max log size = 256
	use sendfile = yes
	min receivefile size = 16384
[ex4bench]
	path = $MNT/$BENCH
	valid users = $BUSER
	read only = no
	guest ok = no
	browseable = no
EOF
}
smb_why() {         # $1 = state dir: the last words smbd left (stderr + its own log), one line, for the refusal
	cat "$1/log/smbd.stderr" "$1"/log/log.* 2>/dev/null | grep -v '^ *$' | tail -4 | tr '\n\t' '  ' | cut -c1-600
}
start_samba() {
	command -v smbd >/dev/null || die "no smbd in this image"
	D=$S/samba; mkdir -p "$D/private" "$D/lock" "$D/state" "$D/cache" "$D/pid" "$D/log" "$D/ncalrpc"; chmod 700 "$D/private"
	samba_conf "$D" > "$D/smb.conf"
	printf '%s\n%s\n' "$PW" "$PW" | smbpasswd -c "$D/smb.conf" -s -a "$BUSER" > "$D/log/smbpasswd.out" 2>&1 || die "smbpasswd -a failed ($(tail -1 "$D/log/smbpasswd.out"))"
	# run 13 (Nov 17 2026): smbd died on mkdir /var/run/samba/ncalrpc (its default pipe dir; OpenWrt's init script makes
	# /var/run/samba, the bench does not use that script) -> ncalrpc dir is ours now; stderr kept; up to 30 s to come up
	smbd -D -s "$D/smb.conf" 7>&- 8>&- 2> "$D/log/smbd.stderr" || die "smbd did not start ($(smb_why "$D"))"     # v9: never hand a server our lock files
	i=0; P=; while [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); P=$(cat "$D/pid/smbd.pid" 2>/dev/null); [ -n "$P" ] && kill -0 "$P" 2>/dev/null && break; P=; done
	[ -n "$P" ] || die "smbd is not running after 30 s ($(smb_why "$D"))"
	note "serve samba4: smbd $P up after ${i} s"
	echo "samba4 $P" > "$S/server"
}
ksmbd_conf() { cat <<EOF
[global]
	server string = ex4 rw bench
	netbios name = EX4-BENCH
	interfaces = $IFACE
	bind interfaces only = yes
	hosts allow = $CLIENT
	hosts deny = 0.0.0.0/0
	map to guest = never
	restrict anonymous = 2
	server min protocol = SMB2_10
[ex4bench]
	path = $MNT/$BENCH
	valid users = $BUSER
	writeable = yes
	read only = no
	guest ok = no
	browseable = no
EOF
}
start_ksmbd() {
	command -v ksmbd.mountd >/dev/null || die "no ksmbd.mountd in this image"
	D=$S/ksmbd; mkdir -p "$D"; chmod 700 "$D"
	ksmbd_conf > "$D/ksmbd.conf"
	printf '%s\n%s\n' "$PW" "$PW" | ksmbd.adduser -P "$D/ksmbdpwd.db" -C "$D/ksmbd.conf" -a "$BUSER" > "$D/adduser.out" 2>&1 || die "ksmbd.adduser failed"
	[ -e /sys/module/ksmbd ] || modprobe ksmbd 2>/dev/null; [ -e /sys/module/ksmbd ] || die "modprobe ksmbd failed"
	mkdir -p /var/run     # run 13: ksmbd.mountd keeps /var/run/ksmbd.lock + ksmbd.fifo there (never assume an init script made it)
	ksmbd.mountd -C "$D/ksmbd.conf" -P "$D/ksmbdpwd.db" 7>&- 8>&- 2> "$D/mountd.out" || die "ksmbd.mountd did not start ($(tail -3 "$D/mountd.out" 2>/dev/null | tr '\n' ' ' | cut -c1-400))"
	i=0; P=; while [ $i -lt 30 ] && [ -z "$P" ]; do sleep 1; i=$((i + 1)); P=$(pidof ksmbd.mountd | awk '{ print $NF }'); done
	[ -n "$P" ] || die "ksmbd.mountd is not running after 30 s ($(tail -3 "$D/mountd.out" 2>/dev/null | tr '\n' ' ' | cut -c1-400))"
	note "serve ksmbd: ksmbd.mountd $P up after ${i} s"
	echo "ksmbd $P" > "$S/server"
}
nfs_state_dirs() {   # v9.8 (box only): nfs-utils' state files (run 13) + the legacy client tracking's dir, 0700 root, made only when missing
	mkdir -p /var/lib/nfs/sm "$S/nfs"; touch /var/lib/nfs/rmtab /var/lib/nfs/etab /var/lib/nfs/xtab
	V4R=/var/lib/nfs/v4recovery
	if [ ! -d "$V4R" ]; then mkdir -p "$V4R" && chown 0:0 "$V4R" && chmod 700 "$V4R" || die "cannot make $V4R (0700 root)"; V4RN="v4recovery made 0700 root"
	else V4RN="v4recovery there ($(ls -lnd "$V4R" | awk '{ print $1 " uid " $3 }'))"; fi
}
kmsg() {             # v9.8: the kernel log (a fake file only under TEST + EX4RW_TEST_DMESG)
	if [ -n "$KMSGF" ]; then cat "$KMSGF" 2>/dev/null; else dmesg 2>/dev/null; fi
}
nfs_tracking() {     # v9.8, $1 = kernel log lines before the start: the client tracking nfsd logged since (6.12: nfsd4_client_tracking_init)
	kmsg | tail -n +$(($1 + 1)) | awk '
		/NFSD: Using .* client tracking operations/ { u = $0; sub(/.*NFSD: Using /, "", u); sub(/ client tracking operations.*/, "", u) }
		/NFSD: Unable to initialize client recovery tracking/ { e = $0; sub(/.*tracking! */, "", e) }
		END { if (u != "") print u; else if (e != "") print "NONE (unable to initialize " e "; no nfsdcld, no CONFIG_NFSD_LEGACY_CLIENT_TRACKING)"; else print "not reported" }'
}
nfsd_wait() {        # v9.8 (run 17D), $1 = rpc.nfsd's rc, $2 = kernel log lines before it: nfsd REALLY up (threads > 0 AND a 2049 listener),
	# polled every 1 s for at most NFSD_WAIT (30) s; rpc.nfsd rc != 0 is taken only when nfsd then runs exactly the threads asked for
	NRC=$1; i=0; t=0; L=n
	if [ "$TEST" = 1 ] && [ ! -e "$NFSD/threads" ]; then NSTART="nfsd start: not checked (test mode without a fake nfsd)"; return 0; fi
	while :; do
		t=$(nfs_threads); L=n
		if [ "${t:-0}" -gt 0 ] 2>/dev/null; then
			if [ "$TEST" != 1 ] || [ -d "$NETP" ]; then listening 2049 && L=y; else L=-; fi
			[ "$L" != n ] && break
		fi
		[ $i -ge "$NFSD_WAIT" ] && break
		sleep 1; i=$((i + 1))
	done
	CT=$(nfs_tracking "$2")
	[ "$TEST" = 1 ] || { mkdir -p "$S/nfs"; logread 2>/dev/null | grep -E 'nfsd|mountd|statd|rpcbind|exportfs' | tail -20 > "$S/nfs/syslog.out"; }
	if [ "$L" = n ]; then
		if [ "${t:-0}" -gt 0 ] 2>/dev/null; then w="threads $t but nothing listens on 2049"; else w="no nfsd thread"; fi
		w="rpc.nfsd (rc $NRC): nfsd is not up after $NFSD_WAIT s ($w); client tracking: $CT; rpc.nfsd said: $(tail -2 "$S/nfs/rpc.nfsd.out" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
		mem_receipt "start${NSN:-0}-refused"; die "$w"      # v9.9: the memory as the refusal found it, before the clean stop
	fi
	if [ "$NRC" != 0 ] && [ "$t" != "${NT:-8}" ]; then
		w="rpc.nfsd said rc $NRC and nfsd runs $t threads, not the ${NT:-8} asked for: not taken"
		mem_receipt "start${NSN:-0}-refused"; die "$w"      # v9.9
	fi
	NSTART="nfsd up after $i s (rpc.nfsd rc $NRC$([ "$NRC" = 0 ] || echo ": taken, nfsd runs the $t threads asked for"), threads $t, 2049 $([ "$L" = y ] && echo listening || echo "not checked: test mode without EX4RW_PROCNET")); client tracking: $CT${V4RN:+; $V4RN}${PREPN:+; $PREPN}"
	note "serve nfs: $NSTART"
}
fake_nfsd() {        # v9.8 test only: the fake rpc.nfsd. One kernel line, its threads after EX4RW_TEST_NFSD_DELAY s, exit EX4RW_TEST_NFSD_RC
	[ -e "$NFSD/threads" ] || return 0
	[ -n "$KMSGF" ] && [ -f "${EX4RW_TEST_NFSD_KMSG:-}" ] && cat "$EX4RW_TEST_NFSD_KMSG" >> "$KMSGF"
	ft=${EX4RW_TEST_NFSD_THREADS:-${NT:-8}}; d=${EX4RW_TEST_NFSD_DELAY:-0}
	if [ "$d" -gt 0 ] 2>/dev/null; then ( sleep "$d"; echo "$ft" > "$NFSD/threads" ) < /dev/null > /dev/null 2>&1 7>&- 8>&- &
	else echo "$ft" > "$NFSD/threads"; fi
	return "${EX4RW_TEST_NFSD_RC:-0}"
}
# ---------- (v9.9, run 19) THE MEMORY RECEIPT + THE NFSD PREP, right before EVERY rpc.nfsd ----------
# Why, read from OUR kernel's own source (OpenWrt 6.12.112: net/sunrpc/svc.c, mm/page_alloc.c, fs/nfsd/nfssvc.c): every nfsd thread
# rpc.nfsd starts runs svc_prepare_thread(), whose svc_init_buffer() fills rq_pages with ONE alloc_pages_bulk call of
# sv_max_mesg / PAGE_SIZE + 1 order-0 pages (sv_max_mesg = max_block_size + one page: 258 pages at --max-block-kb 1024). The bulk
# allocator takes its fast path only while a zone's free pages exceed its LOW watermark + that count; otherwise it hands back ONE
# page (the only one allowed to reclaim) and svc_init_buffer() fails: -ENOMEM, silently (no page-allocation-failure splat; run 19A's
# dmesg had none). Clean page cache is never reclaimed for the rest. After the local rows the page cache holds the RAM and kswapd
# parks MemFree between low and high (OpenWrt's init.d/sysctl sets min_free_kbytes 16384 on a box over 64 MB: low ~20 MiB,
# high ~24 MiB), room for 2-3 such threads, then kswapd's luck: run 18A arm 2/8, 19A baseline 6/8, 18A baseline 8/8.
# sync + drop_caches before the start hands the bulk path the free pages. The rows it serves do not change: the client drops the
# cache before every NFS read pass already, and the write pass starts from an empty cache either way.
mi() {               # v9.9, $1 = a meminfo key: its kB, or ?
	[ -r "$MEMP/meminfo" ] || { echo '?'; return 0; }
	awk -v k="$1:" '$1 == k { print $2; f = 1 } END { if (!f) print "?" }' "$MEMP/meminfo"
}
nfs_mbs_eff() {      # v9.9: the max_block_size nfsd sizes its threads by (0 = auto: nfsd's own rule from the RAM, nfsd_get_default_max_blksize)
	b=$(cat "$NFSD/max_block_size" 2>/dev/null); case "$b" in ''|*[!0-9]*) b=0;; esac
	if [ "$b" != 0 ]; then echo "$b"; return 0; fi
	[ -r "$MEMP/meminfo" ] || { echo 0; return 0; }
	awk '$1 == "MemTotal:" { t = $2 * 1024 / 4096; r = 1048576; while (r > t && r >= 16384) r = r / 2; printf "%d\n", r; f = 1 } END { if (!f) print 0 }' "$MEMP/meminfo"
}
zone_marks() {       # v9.9: one line per zone with managed pages: free / min / low / high / managed (pages, /proc/zoneinfo)
	[ -r "$MEMP/zoneinfo" ] || { echo "(not readable: $MEMP/zoneinfo)"; return 0; }
	awk '/^Node [0-9]+, zone/ { z = $4; o[++n] = z }
		z != "" && $1 == "pages" && $2 == "free" { v[z, "free"] = $3 }
		z != "" && NF == 2 && ($1 == "min" || $1 == "low" || $1 == "high" || $1 == "managed") { v[z, $1] = $2 }
		END { for (i = 1; i <= n; i++) { z = o[i]; if (v[z, "managed"] + 0 > 0) print "zone " z " free " v[z, "free"] + 0 " min " v[z, "min"] + 0 " low " v[z, "low"] + 0 " high " v[z, "high"] + 0 " managed " v[z, "managed"] + 0 } }' "$MEMP/zoneinfo"
}
nfs_fit() {          # v9.9: how many of the asked threads the bulk fast path fits right now (the zone with the most), a FLOOR: kswapd
	# may reclaim between two thread starts. Per thread: the bulk call's P pages must fit over the low mark, then the thread holds
	# P + 3 (its scratch page + its 8 KiB kernel stack; the svc_rqst slab object not counted)
	[ -r "$MEMP/zoneinfo" ] || { echo "fit not known (no zoneinfo)"; return 0; }
	P=$(( $(nfs_mbs_eff) / 4096 + 2 ))
	zone_marks | awk -v p="$P" -v nt="${NT:-8}" '$1 == "zone" { f = $4; l = $8; k = 0; while (k < nt && f - k * (p + 3) > l + p) k++
			if (b == "" || k > bk || (k == bk && f - l > bh)) { b = $2; bk = k; bf = f; bl = l; bh = f - l } }
		END { if (b == "") print "fit not known (no zone)"; else printf "bulk fast path fits %d of %d threads (zone %s: free %d, low %d pages; %d pages per thread bulk call)\n", bk, nt, b, bf, bl, p }'
}
slab_top() {         # v9.9: the 10 biggest slab caches (KiB). /proc/slabinfo needs CONFIG_SLUB_DEBUG, which OUR 6.12 kernel lacks (its
	# .config), so there: /sys/kernel/slab, (partial + cpu slabs) x (4 KiB << order), aliases folded onto one name: a LOWER bound (full
	# slabs are only listed with SLUB_DEBUG). meminfo's Slab / SReclaimable / SUnreclaim in the receipt are the true totals
	if [ -r "$MEMP/slabinfo" ]; then
		echo "(from slabinfo: num_slabs x pagesperslab x 4 KiB)"
		awk 'NR > 2 && $1 !~ /^#/ && NF >= 15 { print $15 * $6 * 4, $1 }' "$MEMP/slabinfo" | sort -nr | head -10
	elif [ -d "$SLABS" ]; then
		echo "(no slabinfo: from $SLABS, (partial + cpu_slabs) x (4 KiB << order): a LOWER bound, full slabs uncounted without CONFIG_SLUB_DEBUG)"
		ls -l "$SLABS" 2>/dev/null | awk '$1 ~ /^l/ && $(NF-1) == "->" { t = $NF; sub(/.*\//, "", t); if (!(t in a) || $(NF-2) < a[t]) a[t] = $(NF-2) }
			$1 ~ /^d/ { d[$NF] = 1 } END { for (x in d) print x, ((x in a) ? a[x] : x) }' | while read x nm; do
			o=0; p=0; c=0
			read o 2>/dev/null < "$SLABS/$x/order"; read p r 2>/dev/null < "$SLABS/$x/partial"; read c r 2>/dev/null < "$SLABS/$x/cpu_slabs"
			case "$o$p$c" in *[!0-9]*|'') continue;; esac
			echo "$(( (p + c) * (4 << o) )) $nm"
		done | sort -nr | head -10
	else echo "(not readable: no $MEMP/slabinfo, no $SLABS)"; fi
}
mem_receipt() {      # v9.9, $1 = label (start<N>-before | -after | -refused): -> $S/nfs/memrcpt-$1.out (the client keeps nfs/*.out) + one journal line
	mkdir -p "$S/nfs"; f=$S/nfs/memrcpt-$1.out
	{	echo "# memory receipt $1: uptime $(up_s) s, $VERSION, nfsd threads now $(nfs_threads) (asked ${NT:-8}), max_block_size $(kv "$NFSD/max_block_size") (threads sized by $(nfs_mbs_eff))"
		echo "## meminfo"; grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Dirty|Writeback|Slab|SReclaimable|SUnreclaim|KernelStack):' "$MEMP/meminfo" 2>/dev/null || echo "(not readable: $MEMP/meminfo)"
		echo "## vm.min_free_kbytes $(kv "$VMP/min_free_kbytes")"
		echo "## zone watermarks (pages)"; zone_marks
		echo "## buddyinfo"; cat "$MEMP/buddyinfo" 2>/dev/null || echo "(not readable: $MEMP/buddyinfo)"
		echo "## slab top 10 (KiB cache)"; slab_top
		echo "## fit: $(nfs_fit)"
	} > "$f" 2>&1
	note "serve nfs: memory receipt $1: MemFree $(mi MemFree) kB, MemAvailable $(mi MemAvailable) kB, $(nfs_fit) (nfs/memrcpt-$1.out)"
}
nfsd_prep() {        # v9.9: right before rpc.nfsd: the receipt; then (by --nfsd-prep) sync + drop_caches and the receipt again
	PREPN=; n=$(cat "$S/nfsd_starts" 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0;; esac
	n=$((n + 1)); echo "$n" > "$S/nfsd_starts"; NSN=$n
	mem_receipt "start$n-before"
	case "$NFSD_PREP" in
	off) PREPN="nfsd prep: start $n: off (--nfsd-prep off), caches kept";;
	second) [ "$n" -ge 2 ] || PREPN="nfsd prep: start $n of this session, --nfsd-prep second: caches kept";;
	esac
	if [ -z "$PREPN" ]; then
		a=$(mi MemFree); sync
		if [ "$TEST" = 1 ] && [ ! -e "$VMP/drop_caches" ]; then PREPN="nfsd prep: start $n: sync only (test mode without a fake drop_caches)"
		elif echo 3 2>/dev/null > "$VMP/drop_caches"; then mem_receipt "start$n-after"; PREPN="nfsd prep: start $n: sync + drop_caches (MemFree $a -> $(mi MemFree) kB)"
		else PREPN="nfsd prep: start $n: drop_caches NOT written ($VMP/drop_caches), rpc.nfsd started anyway"; fi
	fi
	note "serve nfs: $PREPN"
}
start_nfs() {
	for t in rpcbind rpc.statd rpc.mountd rpc.nfsd exportfs; do command -v $t >/dev/null || die "no $t in this image"; done
	[ -e /sys/module/nfsd ] || modprobe nfsd 2>/dev/null
	grep -q ' /proc/fs/nfsd ' /proc/mounts || mount -t nfsd nfsd /proc/fs/nfsd || die "cannot mount /proc/fs/nfsd"
	# run 13 attempt 3 (Nov 17 2026): "exportfs: can't open /var/lib/nfs/etab for reading": OpenWrt's /etc/init.d/nfsd runs `exportfs -r`
	# (which writes etab); `exportfs -i -o` READS etab first, so the bench makes the state files itself, as that script makes rmtab
	nfs_state_dirs      # v9.8: + /var/lib/nfs/v4recovery 0700 root when missing (the legacy client tracking's dir)
	rpcbind 7>&- 8>&- || die "rpcbind did not start"
	rpc.statd -p 32778 -o 32779 7>&- 8>&- || die "rpc.statd did not start"
	rpc.mountd -p 32780 7>&- 8>&- || die "rpc.mountd did not start"
	# NFSv3, sec=sys: NFS authenticates the client by its ADDRESS only. One address, the bench folder only, every
	# client user squashed to the bench account. docs/RWBENCH.md says this plainly.
	exportfs -i -o "rw,sync,no_subtree_check,all_squash,anonuid=$BUID,anongid=$BUID,secure" "$CLIENT:$MNT/$BENCH" || die "exportfs failed"
	# v9.7: --threads N (default 8, v9.4's). v9.8 (run 17D): rpc.nfsd's rc is not the verdict: nfsd_wait polls for nfsd really up
	nfsd_prep; K0=$(kmsg | wc -l); rpc.nfsd -N 4 -U "${NT:-8}" 7>&- 8>&- 2> "$S/nfs/rpc.nfsd.out"; r=$?
	echo "nfs $(pidof rpc.mountd)" > "$S/server"
	nfsd_wait "$r" "$K0"
}
start_nfs4() {       # v9.7: NFSv4.2 ONLY. No rpcbind, no statd (no NLM: v4 locks in-protocol), mountd for the kernel's export
	# upcalls only (-N 2 -N 3: no MOUNT listener), the bench folder exported as the v4 pseudo-root (fsid=0): the client
	# mounts BOX:/. The same address trust, one client, sync, all_squash. nfs4_verify reads it all back after the start.
	for t in rpc.mountd rpc.nfsd exportfs; do command -v $t >/dev/null || die "no $t in this image"; done
	[ -e /sys/module/nfsd ] || modprobe nfsd 2>/dev/null
	grep -q ' /proc/fs/nfsd ' /proc/mounts || mount -t nfsd nfsd /proc/fs/nfsd || die "cannot mount /proc/fs/nfsd"
	nfs_state_dirs      # v9.8
	nfs_grace_set 10
	rpc.mountd -N 2 -N 3 7>&- 8>&- || die "rpc.mountd (upcalls only) did not start"
	exportfs -i -o "rw,sync,no_subtree_check,all_squash,anonuid=$BUID,anongid=$BUID,secure,fsid=0" "$CLIENT:$MNT/$BENCH" || die "exportfs failed"
	nfsd_prep; K0=$(kmsg | wc -l); rpc.nfsd -N 3 -N 4.0 -N 4.1 -V 4.2 -U "${NT:-8}" 7>&- 8>&- 2> "$S/nfs/rpc.nfsd.out"; r=$?      # v9.8: rc recorded, nfsd_wait decides
	echo "nfs4.2 $(pidof rpc.mountd)" > "$S/server"
	nfsd_wait "$r" "$K0"
}
servers_down() {     # every server this bench may have started; on the box also by name (nothing else runs them in a trial)
	if [ "$TEST" = 1 ]; then      # v9.4: a fake nfsd dir stands for rpc.nfsd 0 (threads -> 0), then the block size goes back
		[ -e "$NFSD/threads" ] && echo 0 > "$NFSD/threads"; nfs_block_restore; nfs_grace_restore; rm -f "$S/server" "$S/nfs_serve"; return 0
	fi
	pidof smbd >/dev/null 2>&1 && killall smbd 2>/dev/null
	if pidof ksmbd.mountd >/dev/null 2>&1 || [ -e /sys/module/ksmbd ]; then
		ksmbd.control -s >/dev/null 2>&1; killall ksmbd.mountd 2>/dev/null
		[ -e /sys/class/ksmbd-control/kill_server ] && echo hard > /sys/class/ksmbd-control/kill_server 2>/dev/null
		rmmod ksmbd 2>/dev/null
	fi
	if grep -q ' /proc/fs/nfsd ' /proc/mounts; then rpc.nfsd 0 2>/dev/null; exportfs -au 2>/dev/null; nfs_block_restore; nfs_grace_restore; fi     # v9.4: nfsd stopped first
	killall rpc.mountd rpc.statd rpcbind 2>/dev/null
	i=0; while [ $i -lt 10 ] && pidof smbd ksmbd.mountd rpc.mountd rpc.statd rpcbind >/dev/null 2>&1; do sleep 1; i=$((i + 1)); done
	killall -9 smbd ksmbd.mountd rpc.mountd rpc.statd rpcbind 2>/dev/null
	grep -q ' /proc/fs/nfsd ' /proc/mounts && umount /proc/fs/nfsd 2>/dev/null
	rm -f "$S/server" "$S/nfs_serve"
	return 0
}

# ---------- THE CLEAN STOP ----------
vm_restore() {       # the kernel refuses dirty_bytes 0: a saved 0 means "ratios were in use", so the ratios go back
	[ -s "$S/vm.saved" ] || return 0
	read db dbb < "$S/vm.saved"; read r br < "$S/vm.ratio"
	if [ "$db" = 0 ]; then echo "$r" > /proc/sys/vm/dirty_ratio; else echo "$db" > /proc/sys/vm/dirty_bytes; fi
	if [ "$dbb" = 0 ]; then echo "$br" > /proc/sys/vm/dirty_background_ratio; else echo "$dbb" > /proc/sys/vm/dirty_background_bytes; fi
	rm -f "$S/vm.saved"
}
holders() {          # pids whose cwd, root or an open file is under $MNT
	for p in /proc/[0-9]*; do
		n=${p#/proc/}; [ "$n" = $$ ] && continue
		for l in "$p/cwd" "$p/root" "$p"/fd/*; do
			r=$(readlink "$l" 2>/dev/null) || continue
			case "$r" in "$MNT"|"$MNT"/*) echo "$n"; break;; esac
		done
	done
}
stop_all() {         # $1 = why. Exit status 0 = SAFE: md1 is not read-write and not mounted read-write.
	trap '' HUP INT TERM PIPE      # v9: once the stop starts, no signal leaves it half-way (SIGKILL: the guard / the reboot paths)
	why=$1; need_dir
	exec 7>>"$S/stoplock"; flock 7
	note "clean stop ($why): begin; md $(astate), mount $(mounted_rw && echo rw || { mounted && echo ro || echo none; })"
	# v9: the guard is NOT killed here: the stop lock serialises two stops, and if this one ends UNSAFE the guard keeps
	# watching (it exits by itself once a SAFE stop removes $ACTIVE)
	W=$(cat "$S/pid.work" 2>/dev/null); [ -n "$W" ] && kill "$W" 2>/dev/null; rm -f "$S/pid.work"
	servers_down
	if [ -e "$PE" ]; then       # v9.4: no exit path leaves the function profiler on
		w=$(cat "$PE" 2>/dev/null)
		if prof_off; then [ "$w" = 0 ] || note "clean stop: the function profiler was on ($w): off (reads 0)"; else note "clean stop: the function profiler did NOT turn off (reads $(cat "$PE" 2>/dev/null))"; fi
	fi
	dbg_umount
	sync
	if mounted; then
		n=0
		while mounted && [ $n -lt 3 ]; do
			umount "$MNT" 2>/dev/null && break
			for h in $(holders); do note "clean stop: pid $h holds $MNT ($(tr '\0' ' ' < /proc/$h/cmdline 2>/dev/null | cut -c1-80)): TERM"; kill "$h" 2>/dev/null; done
			sleep 2; for h in $(holders); do kill -9 "$h" 2>/dev/null; done
			sync; n=$((n + 1))
		done
		if mounted_rw; then note "clean stop: umount failed 3 times: remount read-only"; mount -o remount,ro "$MNT" 2>/dev/null; sync; fi
	fi
	SBX=
	if md_up && ! mounted && [ -s "$S/ext4-sb.txt" ]; then      # v9: the ext4 superblock as the unmount left it (a read)
		SB_SUFFIX=-after; if check_fs_sb > "$S/ext4-sb-after.why" 2>&1; then SBX=ok; else SBX="not clean: $(cat "$S/ext4-sb-after.why")"; fi; SB_SUFFIX=
		for k in compat incompat rocompat; do
			b=$(tr ' ' '\n' < "$S/ext4-sb.txt" | awk -F= -v k=$k '$1 == k { print $2 }'); a=$(tr ' ' '\n' < "$S/ext4-sb-after.txt" | awk -F= -v k=$k '$1 == k { print $2 }')
			[ "$b" = "$a" ] || SBX="$SBX; feature word $k changed $b -> $a"
		done
	fi
	knobs_restore      # v9.3: every recorded knob back + read back, while md1 is still assembled (member read-ahead always)
	[ "$TEST" = 1 ] && [ -n "${EX4RW_TEST_STOP_PAUSE:-}" ] && sleep "$EX4RW_TEST_STOP_PAUSE"     # tests read the knobs back here
	if md_up && ! mounted; then
		n=0; while md_up && [ $n -lt 3 ]; do mdadm --stop "$MD" > "$S/mdstop.out" 2>&1 && break; sleep 2; n=$((n + 1)); done
	fi
	if md_up && mounted && ! mounted_rw; then      # mounted read-only and still assembled: wait for md's own clean mark
		n=0; while [ $n -lt 30 ]; do case "$(astate)" in clean|readonly|read-auto|inactive|clear) break;; esac; sleep 1; n=$((n + 1)); done
	fi
	# ---- verify ----
	SAFE=1; VERD=
	if mounted_rw; then SAFE=0; VERD="$VERD $MNT still mounted read-write;"; fi
	if md_up; then
		a=$(astate)
		case "$a" in clean|readonly|read-auto|inactive|clear) VERD="$VERD $MD still assembled but marked $a (not stopped: something holds it);";;
		*) SAFE=0; VERD="$VERD $MD still assembled and $a;";; esac
	fi
	DEG=0
	if ! md_up && [ -n "$EXAMINED$(cat "$S/members" 2>/dev/null)" ]; then
		: > "$S/examine-after.txt"; EVS=
		for p in ${EXAMINED:-$(cat "$S/members")}; do
			E=$S/exa.$$; mdadm --examine "$p" > "$E" 2>&1; { echo "=== $p"; cat "$E"; } >> "$S/examine-after.txt"
			St=$(field "$E" State); A=$(field "$E" 'Array State'); EVS="$EVS $(field "$E" Events)"; rm -f "$E"
			[ "$St" = clean ] || { DEG=1; VERD="$VERD $p state '$St' after the stop;"; }
			case "$A" in AAAA*) ;; *) DEG=1; VERD="$VERD $p array state '$A' (a member dropped out);";; esac
		done
		[ "$(echo $EVS | tr ' ' '\n' | sort -u | wc -l)" = 1 ] || { DEG=1; VERD="$VERD events differ after the stop ($EVS);"; }
		VERD="$VERD members examined after: events$EVS (before: $(cat "$S/events-before" 2>/dev/null || echo ?));"
	fi
	case "$SBX" in
	'') ;;
	ok) VERD="$VERD ext4 after the unmount: clean, feature words (compat incompat rocompat) as before;";;
	*) DEG=1; VERD="$VERD ext4 after the unmount: $SBX;";;
	esac
	if [ $SAFE = 1 ]; then
		vm_restore
		rm -f "$ACTIVE" "$S/pid.guard"
		if [ -e "$S/stay-by-us" ] && [ "$why" != "reboot path" ]; then     # the auto-return we held: give it back
			rm -f "$STAY" "$S/stay-by-us"; note "clean stop: $STAY removed (this bench made it); the trial goes home in $RETURN_SEC s unless someone touches it again"
			setsid sh "$SELF" return-later < /dev/null >> "$S/return.log" 2>&1 7>&- 8>&- &
		fi
		if [ $DEG = 1 ]; then note "clean stop: SAFE TO REBOOT, BUT LOOK:$VERD"; flock -u 7; return 3; fi
		note "clean stop: SAFE: md1 stopped or clean, nothing mounted read-write;$VERD"; flock -u 7; return 0
	fi
	note "clean stop: UNSAFE, NOT SAFE TO REBOOT:$VERD"
	flock -u 7; return 1
}

# ---------- the guard: stops by itself ----------
guard() {
	GUARD_SELF=1; echo $$ > "$S/pid.guard"
	t0=$(cat "$S/up-time"); b0=$(dmesg 2>/dev/null | grep -cE "$BADPAT")
	[ -s "$S/window" ] && WINDOW_SEC=$(cat "$S/window")
	while [ -e "$ACTIVE" ]; do
		sleep "$GUARD_SEC"; [ -e "$ACTIVE" ] || exit 0
		now=$(up_s); hb=$(cat "$S/heartbeat" 2>/dev/null || echo "$t0"); why=
		[ $((now - t0)) -ge "$WINDOW_SEC" ] && why="the rw window ($WINDOW_SEC s) is over"
		[ -z "$why" ] && [ $((now - hb)) -ge "$IDLE_SEC" ] && why="no client heartbeat for $IDLE_SEC s"
		b=$(dmesg 2>/dev/null | grep -cE "$BADPAT"); [ -z "$why" ] && [ "$b" -gt "$b0" ] && why="kernel log: $(dmesg | grep -E "$BADPAT" | tail -1 | cut -c1-160)"
		[ -z "$why" ] && [ "$TEST" != 1 ] && ! pidof ex4fan >/dev/null 2>&1 && why="ex4fan is gone (no fan control)"
		[ -z "$why" ] && [ -e "$S/guard-stop-now" ] && why="test: guard-stop-now"
		if [ -n "$why" ]; then note "guard: $why: clean stop"; stop_all "guard: $why"; exit $?; fi
	done
}

# ---------- the commands ----------
trap_stop() {        # rw-phase commands: any failure or signal = the clean stop
	trap 'rc=$?; trap - EXIT; if [ "${DONE:-0}" != 1 ] && [ -e "$ACTIVE" ]; then note "command failed or interrupted (rc $rc): clean stop"; stop_all "trap: $CMD rc $rc"; fi; exit $rc' EXIT
	trap 'exit 130' INT TERM HUP
}
need_active() { [ -e "$ACTIVE" ] && mounted_rw || die "the rw bench is not up (ex4-rwbench up CLIENT_IP first)"; EXAMINED=${EXAMINED:-$(cat "$S/members" 2>/dev/null)}; }
lock_cmd() { exec 8>>"$S/lock"; flock -n 8 || die "another ex4-rwbench command is running"; }

cmd_preflight() {
	need_root; need_dir; check_trial; check_tools; check_reboot_paths
	[ -e "$ACTIVE" ] && die "the rw bench is already up ($ACTIVE): ex4-rwbench stop"
	check_examine
	echo "$EXAMINED" > "$S/members"
	say "preflight passed: $VERSION, members $EXAMINED, array $UUID0, events $EV0, clean, AAAA, no bad blocks recorded; reboot paths patched; examine in $S/examine-before.txt"
	[ "$TEST" = 1 ] && say "TEST MODE (loop devices only)"
	return 0
}
cmd_arm() {
	cmd_preflight
	R=${EX4RW_RUNID:-$(tr ' ' '\n' < /proc/cmdline | awk -F= '$1 == "ex4boot_run" { print $2 }')}
	[ -n "$R" ] || die "no run id"
	echo "$R" | grep -qE '^[A-Za-z0-9.-]+$' || die "run id '$R' has odd characters"
	echo "$R" > "$S/runid"
	N=$(hexdump -n 6 -v -e '6/1 "%02x"' /dev/urandom); [ ${#N} = 12 ] || die "no random nonce"
	rm -f "$S/nonce"; echo "$N" > "$S/nonce"; chmod 600 "$S/nonce"
	note "armed: a new token was printed (any older token is void)"
	echo "TOKEN (type it yourself, on the box, after reading the plan; no script may write it):"
	echo "  echo '$(expected_token)' > $OK"
}
cmd_up() {
	CLIENT=${1:-}; valid_ip "$CLIENT" || die "up needs the client's IPv4 address (the one host the servers will answer)"
	shift; WSTAY=0; WMIN=; SKC=
	while [ $# -gt 0 ]; do
		case "$1" in
		--stay) WSTAY=1; shift;;
		--window-min) WMIN=${2:-}; shift 2 || die "--window-min N";;
		--skip-copy) SKC=${2:-}; shift 2 || die "--skip-copy 0|1"; case "$SKC" in 0|1) ;; *) die "--skip-copy takes 0 or 1, not '$SKC'";; esac;;
		*) die "up CLIENT_IP [--stay] [--window-min N] [--skip-copy 0|1]: not '$1'";;
		esac
	done
	if [ -n "$WMIN" ]; then
		case "$WMIN" in ''|*[!0-9]*) die "--window-min takes whole minutes";; esac
		[ "$WMIN" -ge 5 ] && [ "$WMIN" -le 45 ] || die "--window-min: 5..45 minutes, not $WMIN"
		[ "$TEST" = 1 ] && [ -n "${EX4RW_WINDOW_SEC:-}" ] || WINDOW_SEC=$((WMIN * 60))
	fi
	need_root; need_dir; lock_cmd
	r=$(gate) || die "token: $r"
	cmd_preflight >/dev/null
	set -- $EXAMINED
	mv "$OK" "$S/ex4-rw-ok.used-$(up_s)" || die "cannot consume the token"
	echo "$EV0" > "$S/events-before"; echo "$CLIENT" > "$S/client"; rm -f "$S/knobs.saved"
	# From here every exit path runs the clean stop. ACTIVE first: every reboot path now stops md1 before rebooting.
	: > "$ACTIVE"; DONE=0; CMD=up; trap_stop
	if [ $WSTAY = 1 ] && [ ! -e "$STAY" ]; then : > "$STAY"; : > "$S/stay-by-us"; note "up: $STAY made (auto-return held for the bench; the clean stop gives it back)"; fi
	note "up: token accepted (consumed); members $*, events $EV0; client $CLIENT"
	mdadm --assemble --readonly "$MD" --uuid="$UUID0" "$@" > "$S/assemble.out" 2>&1 || die "mdadm --assemble --readonly failed ($(tail -1 "$S/assemble.out"))"
	M=$(grep -A3 "^$MDN " /proc/mdstat)
	echo "$M" | grep -q '(read-only)' || die "$MD is not (read-only) after --readonly"
	echo "$M" | grep -q '\[4/4\] \[UUUU\]' || die "$MD is not [4/4] [UUUU]"
	echo "$M" | grep -qiE 'resync|recover|reshape|check' && die "$MD shows a sync line: $M"
	echo frozen > "/sys/block/$MDN/md/sync_action" || die "cannot freeze sync_action"
	[ "$(cat /sys/block/$MDN/md/sync_action)" = frozen ] || die "sync_action is not frozen"
	r=$(check_fs_sb) || die "ext4: $r"
	FREE_MIB=$(awk -F'free_mib=' '{ print $2 }' "$S/ext4-sb.txt")
	need=$((LOCAL_MIB + NEED_EXTRA)); [ "${FREE_MIB:-0}" -ge $need ] || die "only ${FREE_MIB} MiB free, the bench needs $need"
	# the walls of item 6, read on the read-only array before anything is writable
	mkdir -p "$MNT"; mount -t ext4 -o ro,noload,noatime "$MD" "$MNT" || die "read-only look-ahead mount failed"
	[ -d "$MNT/Public" ] && [ ! -L "$MNT/Public" ] || { umount "$MNT"; die "$MNT/Public is not a real folder"; }
	[ -e "$MNT/$BENCH" ] || [ -L "$MNT/$BENCH" ] && { umount "$MNT"; die "$MNT/$BENCH exists already: this bench never reuses a folder (look at it, rename it, then run again)"; }
	umount "$MNT" || die "cannot umount the look-ahead mount"
	# v9.3: every md / read-ahead knob as the kernel set it, recorded BEFORE any is changed (THE CLEAN STOP writes them back)
	knobs_save; note "up: knobs at assembly (the clean stop restores these): $(knobs)"
	# the safety knobs (RAM only), then read-write
	cat /proc/sys/vm/dirty_bytes /proc/sys/vm/dirty_background_bytes | tr '\n' ' ' > "$S/vm.saved"
	cat /proc/sys/vm/dirty_ratio /proc/sys/vm/dirty_background_ratio | tr '\n' ' ' > "$S/vm.ratio"
	echo 67108864 > /proc/sys/vm/dirty_bytes; echo 16777216 > /proc/sys/vm/dirty_background_bytes
	[ -n "$SCACHE" ] && { echo "$SCACHE" > "/sys/block/$MDN/md/stripe_cache_size" || die "stripe_cache_size $SCACHE refused"; }
	mdadm --readwrite "$MD" > "$S/readwrite.out" 2>&1 || die "mdadm --readwrite failed ($(tail -1 "$S/readwrite.out"))"
	[ "$(cat /sys/block/$MDN/md/sync_action)" = frozen ] || { echo frozen > "/sys/block/$MDN/md/sync_action"; die "sync_action was not frozen after --readwrite (frozen again, stopping)"; }
	M=$(grep -A3 "^$MDN " /proc/mdstat); echo "$M" | grep -qiE 'resync|recover|reshape|check|read-only' && die "$MD after --readwrite: $M"
	if [ -n "$SKC" ]; then      # v9.3 wall 11: after the rw switch, BEFORE the ext4 mount (stable pages are inherited at mount)
		mounted && die "skip_copy: $MNT is mounted: refused (it is set only before the ext4 mount)"
		echo "$SKC" > "/sys/block/$MDN/md/skip_copy" 2>/dev/null || die "skip_copy $SKC refused by the kernel"
		[ "$(cat "/sys/block/$MDN/md/skip_copy")" = "$SKC" ] || die "skip_copy reads $(cat "/sys/block/$MDN/md/skip_copy"), not $SKC"
		note "up: skip_copy=$SKC written (after the rw switch, before the ext4 mount; read back)"
	fi
	mount -t ext4 -o "rw,noatime,data=ordered,barrier=1,errors=remount-ro,noinit_itable,stripe=$STRIPE" "$MD" "$MNT" || die "rw mount failed (dmesg: $(dmesg | grep -i ext4 | tail -1))"
	mounted_rw || die "$MNT is not read-write after the mount"
	mkdir "$MNT/$BENCH" || die "mkdir $BENCH failed"
	PW=$(hexdump -n 12 -v -e '12/1 "%02x"' /dev/urandom); [ ${#PW} = 24 ] || die "no random password"
	printf 'user=%s\npassword=%s\n' "$BUSER" "$PW" > "$S/creds"; chmod 600 "$S/creds"
	ensure_user; chown "$BUID:$BUID" "$MNT/$BENCH" 2>/dev/null; chmod 755 "$MNT/$BENCH"
	cat > "$MNT/$BENCH/README.txt" <<EOF
ex4-bench-v8: written by the EX4 OpenWrt read-write bench ($VERSION), run $(cat "$S/runid" 2>/dev/null), $(date -u '+%Y-%m-%d %H:%M UTC').
The big test files were removed after each test. results.txt (if present) holds the numbers. Safe to delete this folder.
EOF
	echo "$(up_s)" > "$S/up-time"; echo "$(up_s)" > "$S/heartbeat"; echo "$WINDOW_SEC" > "$S/window"
	setsid sh "$SELF" guard < /dev/null >> "$S/guard.log" 2>&1 7>&- 8>&- &     # never hand the guard our locks
	sleep 1
	note "up: md1 read-write (sync frozen, dirty_bytes 64 MiB), ext4 mounted rw at $MNT ($(awk -v m="$MNT" '$2 == m { print $4 }' /proc/mounts)), $BENCH made; guard: window $WINDOW_SEC s, idle $IDLE_SEC s; knobs $(knobs); ext4 features $(tr ' ' '\n' < "$S/ext4-sb.txt" | grep -E '^(compat|incompat|rocompat)=' | tr '\n' ' ')"
	DONE=1
}
cmd_local() {
	LABEL=
	case "${1:-}" in
	'') ;;
	--label) LABEL=${2:-}; echo "$LABEL" | grep -qE '^[a-z0-9-]{1,16}$' || die "local --label: 1..16 of a-z 0-9 -"; [ $# = 2 ] || die "local [--label L]";;
	*) die "local [--label L]: not '$1'";;
	esac
	need_root; need_dir; lock_cmd; need_active; DONE=0; CMD=local; trap_stop; cd /
	LP=${LABEL:+$LABEL }
	F=$MNT/$BENCH/local-${LOCAL_MIB}m.bin; [ -e "$F" ] && die "$F exists"
	sync; [ "$TEST" = 1 ] || echo 3 > /proc/sys/vm/drop_caches
	snap "$S/snap.local-w.a"
	dd if=/dev/zero of="$F" bs=1M count="$LOCAL_MIB" 2> "$S/dd.err" & echo $! > "$S/pid.work"; wait $! || die "dd write failed: $(tail -1 "$S/dd.err")"
	[ "$TEST" = 1 ] && [ -n "${EX4RW_TEST_PAUSE:-}" ] && { sleep "$EX4RW_TEST_PAUSE" & wait $!; }     # tests: a signal lands mid-command
	sync; snap "$S/snap.local-w.b"; rm -f "$S/pid.work"
	report "${LP}local dd write + sync" "$S/snap.local-w.a" "$S/snap.local-w.b" "$LOCAL_MIB" | tee -a "$S/results.txt"
	[ "$TEST" = 1 ] || echo 3 > /proc/sys/vm/drop_caches
	snap "$S/snap.local-r.a"
	dd if="$F" of=/dev/null bs=1M 2> "$S/dd.err" & echo $! > "$S/pid.work"; wait $! || die "dd read failed: $(tail -1 "$S/dd.err")"
	snap "$S/snap.local-r.b"; rm -f "$S/pid.work"
	report "${LP}local dd read" "$S/snap.local-r.a" "$S/snap.local-r.b" "$LOCAL_MIB" | tee -a "$S/results.txt"
	rm -f "$F"; sync; echo "$(up_s)" > "$S/heartbeat"
	# v9.3: the raw md read, stock's method (common.sh: dd if=/dev/md1 of=/dev/null bs=1M count=1024 skip=8192): a READ of the
	# block device, page cache dropped first; nothing is written
	[ "$TEST" = 1 ] || echo 3 > /proc/sys/vm/drop_caches
	snap "$S/snap.raw-r.a"
	dd if="$MD" of=/dev/null bs=1M count="$RAW_MIB" skip="$RAW_SKIP" 2> "$S/dd.err" & echo $! > "$S/pid.work"; wait $! || die "raw md read failed: $(tail -1 "$S/dd.err")"
	snap "$S/snap.raw-r.b"; rm -f "$S/pid.work"
	report "${LP}raw md read (dd bs=1M count=$RAW_MIB skip=$RAW_SKIP, stock's method)" "$S/snap.raw-r.a" "$S/snap.raw-r.b" "$RAW_MIB" | tee -a "$S/results.txt"
	echo "$(up_s)" > "$S/heartbeat"
	DONE=1
}
cmd_tune() {         # v9.3: only inside a session; every argument checked before anything is written (a refusal changes nothing)
	TSC=; TRA=; TGT=
	[ $# -gt 0 ] || die "tune [--stripe-cache N] [--readahead-kb N] [--group-threads N]: name at least one"
	while [ $# -gt 0 ]; do
		case "$1" in
		--stripe-cache) TSC=${2:-}; shift 2 || die "--stripe-cache N";;
		--readahead-kb) TRA=${2:-}; shift 2 || die "--readahead-kb N";;
		--group-threads) TGT=${2:-}; shift 2 || die "--group-threads N";;
		--skip-copy) die "tune: skip_copy is written only by 'up --skip-copy', after the rw switch and BEFORE the ext4 mount: on a mounted array ext4 has no stable pages and parity could go silently wrong (wall 11). Refused; nothing changed";;
		*) die "tune [--stripe-cache N] [--readahead-kb N] [--group-threads N]: not '$1'";;
		esac
	done
	inr() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ ${#1} -le 5 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
	[ -z "$TSC" ] || inr "$TSC" 256 4096 || die "tune --stripe-cache: 256..4096, not '$TSC'"
	[ -z "$TRA" ] || inr "$TRA" 128 8192 || die "tune --readahead-kb: 128..8192 KiB, not '$TRA'"
	[ -z "$TGT" ] || inr "$TGT" 0 2 || die "tune --group-threads: 0..2, not '$TGT'"
	need_root; need_dir; lock_cmd; need_active; cd /
	[ -s "$S/knobs.saved" ] || die "no knob record from up ($S/knobs.saved): this session cannot give knobs back, so none are changed"
	K0=$(knobs); m=/sys/block/$MDN/md
	wr() {       # $1 = file, $2 = value: write, read back
		[ -w "$1" ] || die "tune: $1 is not writable here"
		echo "$2" > "$1" 2>/dev/null; [ "$(cat "$1" 2>/dev/null)" = "$2" ] || die "tune: the kernel did not take $2 for $1 (reads $(cat "$1" 2>/dev/null)); knobs now $(knobs) (the clean stop restores them)"
	}
	[ -n "$TSC" ] && wr "$m/stripe_cache_size" "$TSC"
	[ -n "$TGT" ] && wr "$m/group_thread_cnt" "$TGT"
	if [ -n "$TRA" ]; then
		wr "/sys/block/$MDN/queue/read_ahead_kb" "$TRA"
		for p in $EXAMINED; do
			q=$(mqueue "$p"); [ -e "$q/read_ahead_kb" ] || { note "tune: no read_ahead_kb for $p: skipped (never recorded, so never tuned)"; continue; }
			wr "$q/read_ahead_kb" "$TRA"
		done
	fi
	note "tune: knobs $K0 -> $(knobs)"
	echo "tune: knobs now $(knobs)" | tee -a "$S/results.txt"
	echo "$(up_s)" > "$S/heartbeat"
}
cmd_profile() {      # v9.4 (PERF-DESIGN-v2 R2): function-profiler counts for ONE local write; only while up, only on a kernel that has it
	PL=p; PM=$LOCAL_MIB; PT=60
	while [ $# -gt 0 ]; do
		case "$1" in
		--label) [ $# -ge 2 ] || die "--label L"; PL=$2; shift 2;;
		--mib) [ $# -ge 2 ] || die "--mib N"; PM=$2; shift 2;;
		--top) [ $# -ge 2 ] || die "--top N"; PT=$2; shift 2;;
		*) die "profile [--label L] [--mib N] [--top N]: not '$1'";;
		esac
	done
	echo "$PL" | grep -qE '^[a-z0-9-]{1,16}$' || die "profile --label: 1..16 of a-z 0-9 -"
	case "$PM" in ''|*[!0-9]*) die "profile --mib: whole MiB";; esac; [ ${#PM} -le 5 ] && [ "$PM" -ge 1 ] && [ "$PM" -le "$LOCAL_MIB" ] || die "profile --mib: 1..$LOCAL_MIB, not $PM"
	case "$PT" in ''|*[!0-9]*) die "profile --top: a whole number";; esac; [ ${#PT} -le 3 ] && [ "$PT" -ge 10 ] && [ "$PT" -le 500 ] || die "profile --top: 10..500, not $PT"
	need_root; need_dir; lock_cmd; need_active; cd /
	PF=$S/profile-$PL.txt; [ -e "$PF" ] && die "$PF exists (one profile per label)"
	F=$MNT/$BENCH/profile-${PM}m.bin; [ -e "$F" ] && die "$F exists"
	if [ "$TEST" != 1 ] && [ ! -e "$PE" ] && ! awk -v d="$DBG" '$2 == d && $3 == "debugfs" { f = 1 } END { exit !f }' /proc/mounts; then
		mount -t debugfs debugfs "$DBG" 2>/dev/null && : > "$S/debugfs-by-us"
	fi
	if [ ! -e "$PE" ]; then dbg_umount; die "profile: no $PE: this kernel has no function profiler (FUNCTION_PROFILER: the R2 profile twin, v10b-prof, has it); nothing written"; fi
	DONE=0; CMD=profile; trap_stop      # from here a failure or a signal = the clean stop (which turns the profiler off)
	sync; [ "$TEST" = 1 ] || echo 3 > /proc/sys/vm/drop_caches
	echo 0 > "$PE" 2>/dev/null; echo 1 > "$PE" 2>/dev/null; [ "$(cat "$PE" 2>/dev/null)" = 1 ] || die "the function profiler did not turn on (reads $(cat "$PE" 2>/dev/null))"
	note "profile $PL: function profiler ON for one $PM MiB local write"
	snap "$S/snap.prof-$PL.a"
	dd if=/dev/zero of="$F" bs=1M count="$PM" 2> "$S/dd.err" & echo $! > "$S/pid.work"; wait $! || die "profile dd write failed: $(tail -1 "$S/dd.err")"
	[ "$TEST" = 1 ] && [ -n "${EX4RW_TEST_PAUSE:-}" ] && { sleep "$EX4RW_TEST_PAUSE" & wait $!; }     # tests: read the profiler mid-run / signal it
	sync; snap "$S/snap.prof-$PL.b"; rm -f "$S/pid.work"
	prof_off || die "the function profiler did not turn off (reads $(cat "$PE" 2>/dev/null))"
	note "profile $PL: function profiler OFF (reads 0)"
	report "$PL profile local dd write + sync (PROFILER ON: counts only, never MiB/s)" "$S/snap.prof-$PL.a" "$S/snap.prof-$PL.b" "$PM" | tee -a "$S/results.txt"
	rm -f "$F"; sync
	NF0=$(ls "$TR"/trace_stat/function* 2>/dev/null | wc -l | tr -d ' ')
	for f in "$TR"/trace_stat/function*; do [ -f "$f" ] && cat "$f"; done | awk '
		$1 == "Function" || $1 ~ /^-+$/ || NF < 2 || $2 !~ /^[0-9]+$/ { next }
		{ t = (NF >= 3 ? $3 : 0); sub(/[^0-9.].*$/, "", t); h[$1] += $2; tm[$1] += t }      # no graph tracer = "Function Hit" only: time 0
		END { for (k in h) printf "%016.3f %012d %s\n", tm[k], h[k], k }' | sort -r | awk '{ printf "%.3f %d %s\n", $1, $2, $3 }' > "$S/profile-$PL.all"
	# (zero-padded keys + a plain reverse sort: the image's busybox 1.37 sort ignored 'r' on a multi-key -k list, loop-arm-1)
	{
		echo "# profile $PL ($VERSION): function profiler, one $PM MiB local dd write + sync; kernel $(uname -r); $NF0 trace_stat/function* file(s) merged"
		echo "# sorted by total time, then hits (us, summed over CPUs; nested times overlap; time 0 = a kernel without the graph tracer, hits only); top $PT of $(wc -l < "$S/profile-$PL.all" | tr -d ' ') functions; knobs $(knobs)"
		echo "# time_us hits function"
		head -n "$PT" "$S/profile-$PL.all"
	} > "$PF"
	awk -v pl="$PL" '
		{ n++; T += $1; if (n <= 5) top = top (n > 1 ? ", " : "") $3 " (" $2 " hits, " $1 " us)" }
		$3 ~ /^(mv_xor|async_tx|async_xor|dma_unmap|dmaengine_unmap)/ { X += $1 }
		$3 ~ /^(raid5_|__add_stripe_bio|submit_bio_noacct|blk_mq_|blk_attempt_plug_merge)/ { R += $1 }
		$3 == "ops_complete_reconstruct" { OC = $2 }
		END { printf "%s profile: %d functions; top 5 by time: %s; xor path %.1f%% / per-row+bio %.1f%% of summed time (nested: shares, not wall time); ops_complete_reconstruct hits %d\n", pl, n, (n ? top : "none"), (T > 0 ? 100 * X / T : 0), (T > 0 ? 100 * R / T : 0), OC }' "$S/profile-$PL.all" | tee -a "$S/results.txt"
	rm -f "$S/profile-$PL.all"
	dbg_umount
	echo "$(up_s)" > "$S/heartbeat"; DONE=1
}
cmd_serve() {
	E=${1:-}; CLIENT=${2:-}; [ $# -ge 2 ] && shift 2 || shift $#
	UNAUTH=0; MBK=; NV=; NT=; NSTART=; V4RN=; PREPN=; NSN=; NFSD_PREP=every
	need_root; need_dir; lock_cmd; need_active; cd /
	case "$E" in samba4|ksmbd|nfs) ;; *) die "serve: engine samba4 | ksmbd | nfs, not '$E'";; esac
	valid_ip "$CLIENT" || die "serve needs the client's IPv4 address"
	while [ $# -gt 0 ]; do
		case "$1" in
		--unauthenticated-nfs) [ "$E" = nfs ] || die "serve $E: unknown argument '$1'"; UNAUTH=1; shift;;
		--max-block-kb) [ "$E" = nfs ] || die "serve $E: --max-block-kb is an NFS knob"; [ $# -ge 2 ] || die "--max-block-kb N"; MBK=$2; shift 2
			case "$MBK" in 64|128|256|512|1024) ;; *) die "serve nfs --max-block-kb: 64, 128, 256, 512 or 1024, not '$MBK'";; esac;;
		--vers) [ "$E" = nfs ] || die "serve $E: --vers is an NFS knob"; [ $# -ge 2 ] || die "--vers 3|4.2"; NV=$2; shift 2      # v9.7
			case "$NV" in 3|4.2) ;; *) die "serve nfs --vers: 3 or 4.2, not '$NV'";; esac;;
		--threads) [ "$E" = nfs ] || die "serve $E: --threads is an NFS knob"; [ $# -ge 2 ] || die "--threads N"; NT=$2; shift 2      # v9.7
			case "$NT" in ''|*[!0-9]*) die "serve nfs --threads: 1..16, not '$NT'";; esac; [ ${#NT} -le 2 ] && [ "$NT" -ge 1 ] && [ "$NT" -le 16 ] || die "serve nfs --threads: 1..16, not '$NT'"
			NT=$((NT + 0));;
		--nfsd-prep) [ "$E" = nfs ] || die "serve $E: --nfsd-prep is an NFS knob"; [ $# -ge 2 ] || die "--nfsd-prep every|second|off"; NFSD_PREP=$2; shift 2      # v9.9
			case "$NFSD_PREP" in every|second|off) ;; *) die "serve nfs --nfsd-prep: every, second or off, not '$NFSD_PREP'";; esac;;
		*) die "serve $E: unknown argument '$1'";;
		esac
	done
	if [ "$E" = nfs ]; then
		[ $UNAUTH = 1 ] || die "serve nfs: NFSv3 (sec=sys) trusts the client's ADDRESS only: no password exists in the protocol, so rpcbind, statd, mountd and nfsd would listen on the LAN without a login. Refused unless you type --unauthenticated-nfs (the client: --nfs)"
		# v9.4: the kernel refuses max_block_size while nfsd runs; so do we, before anything changes
		[ -z "$MBK" ] || [ "$(nfs_threads)" = 0 ] || die "serve nfs --max-block-kb: nfsd is already running ($(nfs_threads) threads): max_block_size can only be set before nfsd starts (unserve first); nothing changed"
	fi
	[ "$CLIENT" = "$(cat "$S/client")" ] || die "client $CLIENT is not the one named at up ($(cat "$S/client"))"
	DONE=0; CMD=serve; trap_stop      # the arguments are checked before this line: a refusal above changes nothing
	PW=$(awk -F= '$1 == "password" { print $2 }' "$S/creds")
	servers_down
	[ -n "$MBK" ] && nfs_block_set "$MBK"      # v9.4: after servers_down (no nfsd thread), before rpc.nfsd starts any
	case "$E" in
	samba4) [ "$TEST" = 1 ] && echo "samba4 test" > "$S/server" || start_samba;;
	ksmbd) [ "$TEST" = 1 ] && echo "ksmbd test" > "$S/server" || start_ksmbd;;
	nfs) if [ "$NV" = 4.2 ]; then      # v9.7
			if [ "$TEST" = 1 ]; then      # the fake rpc.nfsd: grace first (as start_nfs4), then versions + threads as the real one writes them
				nfs_grace_set 10; echo "nfs4.2 test" > "$S/server"; echo "${EX4RW_TEST_NFSD_VERSIONS:--2 -3 +4 -4.0 -4.1 +4.2}" > "$NFSD/versions"
				nfsd_prep; K0=$(kmsg | wc -l); fake_nfsd; nfsd_wait $? "$K0"      # v9.8: the same start-wait as the box (v9.9: + the prep)
			else start_nfs4; fi
			nfs4_verify
		elif [ "$TEST" = 1 ]; then echo "nfs test" > "$S/server"; nfsd_prep; K0=$(kmsg | wc -l); fake_nfsd; nfsd_wait $? "$K0"      # test: the fake nfsd "starts"
		else start_nfs; fi
		[ -n "$NT" ] && nfs_threads_check "$NT"
		[ -n "$NV$NT" ] && echo "vers=${NV:-3} threads=$(nfs_threads)" > "$S/nfs_serve";;
	esac
	note "serve: $E up for $CLIENT on $MNT/$BENCH ($(cat "$S/server"))$(nfs_tag)${NSTART:+ | $NSTART}"
	echo "$(up_s)" > "$S/heartbeat"; DONE=1
}
cmd_sample() {
	need_root; need_active; W=${1:-}; NAME=${2:-}; MIB=${3:-0}; CSEC=${4:-}
	echo "$NAME" | grep -qE '^[a-z0-9-]+$' || die "sample name: a-z 0-9 - only"
	case "$W" in
	begin) snap "$S/snap.$NAME.a";;
	end) [ -f "$S/snap.$NAME.a" ] || die "no sample begin $NAME"; snap "$S/snap.$NAME.b"; report "$NAME" "$S/snap.$NAME.a" "$S/snap.$NAME.b" "$MIB" "$CSEC" | tee -a "$S/results.txt";;
	*) die "sample begin|end NAME [MIB] [CLIENT_SECONDS]";;
	esac
	echo "$(up_s)" > "$S/heartbeat"
}
cmd_md5() {          # v9.7: the canary's box half: md5 of one file the client wrote into the bench folder (a read)
	need_root; need_active; N=${1:-}; [ $# = 1 ] || die "md5 NAME"
	echo "$N" | grep -qE '^[a-z0-9-]{1,40}\.bin$' || die "md5 NAME: a-z 0-9 - then .bin, not '$N'"
	F=$MNT/$BENCH/$N
	[ -L "$F" ] && die "md5: $N is a symlink"
	[ -f "$F" ] || die "md5: $N is missing or not a regular file"
	sz=$(ls -ln "$F" | awk '{ print $5 }'); t0=$(up_cs)
	h=$(md5sum < "$F" | cut -d' ' -f1); [ ${#h} = 32 ] || die "md5: md5sum of $N failed"
	echo "canary $N md5 $h bytes $sz ($(( ($(up_cs) - t0) / 100 )) s on the box)" | tee -a "$S/results.txt"
	echo "$(up_s)" > "$S/heartbeat"
}
cmd_ucanary() {      # v9.8 (FABLE-OPT §6 row "F3 user-copy option": odd-block-size read md5 x 4): THE USER-COPY CANARY, untimed, on one
	# file the client wrote over NFS whose md5 it knows (the v9.7 pattern). The v9.7 canary is a TRANSPORT canary (nfsd copies in the
	# kernel, the box md5 reads through the page cache); this one drives copy_to_user (dd's reads, odd sizes = partial last blocks) and
	# copy_from_user (dd's writes into the pipe and into a file), i.e. exactly what CONFIG_UACCESS_WITH_MEMCPY changes, on whatever
	# kernel runs. Arguments are checked before anything (a refusal changes nothing); from the trap on, a failure or a mismatch = THE CLEAN STOP
	N=${1:-}; [ $# = 3 ] && [ "${2:-}" = --md5 ] || die "ucanary NAME --md5 HEX"
	H=$3
	echo "$N" | grep -qE '^[a-z0-9-]{1,40}\.bin$' || die "ucanary NAME: a-z 0-9 - then .bin, not '$N'"
	echo "$N" | grep -q -- '-ucopy\.bin$' && die "ucanary NAME: '$N' is a name the canary itself uses for its copy"
	echo "$H" | grep -qE '^[0-9a-f]{32}$' || die "ucanary --md5: 32 lower-case hex digits, not '$H'"
	need_root; need_dir; lock_cmd; need_active; cd /
	F=$MNT/$BENCH/$N; C=$MNT/$BENCH/${N%.bin}-ucopy.bin
	[ -L "$F" ] && die "ucanary: $N is a symlink"
	[ -f "$F" ] || die "ucanary: $N is missing or not a regular file"
	{ [ -e "$C" ] || [ -L "$C" ]; } && die "ucanary: ${C##*/} exists already (the canary never overwrites)"
	sz=$(ls -ln "$F" | awk '{ print $5 }'); [ "${sz:-0}" -gt 0 ] 2>/dev/null || die "ucanary: $N is empty"
	fk=$(df -Pk "$MNT" 2>/dev/null | awk 'NR == 2 { print $4 }'); case "$fk" in ''|*[!0-9]*) die "ucanary: cannot read the free space of $MNT (df -Pk)";; esac
	[ $((fk / 1024)) -ge $((sz / 1048576 + 64)) ] || die "ucanary: $((fk / 1024)) MiB free, the copy needs $((sz / 1048576)) MiB + 64"
	DONE=0; CMD=ucanary; trap_stop
	t0=$(up_cs); UB=; KR=$(uname -r)
	note "ucanary $N: $sz bytes, known md5 $H, kernel $KR: $UCBS then a copy at bs=$UCCP (caches dropped before each pass)"
	for b in $UCBS; do
		sync; [ "$TEST" = 1 ] || echo 3 > /proc/sys/vm/drop_caches
		t1=$(up_cs); rm -f "$S/uc.rc"
		h=$( { dd if="$F" bs="$b" 2> "$S/uc.err"; echo $? > "$S/uc.rc"; } | md5sum | cut -d' ' -f1 )
		rc=$(cat "$S/uc.rc" 2>/dev/null)
		if [ "$rc" = 0 ] && [ "$h" = "$H" ]; then r=OK; else r=FAIL; UB="$UB read bs=$b gave ${h:-nothing} (dd rc ${rc:-?});"; fi
		echo "ucanary $N read bs=$b: md5 ${h:-none} $r ($(( ($(up_cs) - t1) / 100 )) s)" | tee -a "$S/results.txt"
		echo "$(up_s)" > "$S/heartbeat"
	done
	if [ -n "$UB" ]; then
		echo "CANARY FAIL ucanary $N: the known md5 is $H;$UB kernel $KR" | tee -a "$S/results.txt"
		die "CANARY FAIL ucanary $N:$UB the known md5 is $H: a user copy changed bytes (the clean stop runs now; $N stays in the bench folder to look at)"
	fi
	sync; [ "$TEST" = 1 ] || echo 3 > /proc/sys/vm/drop_caches
	t1=$(up_cs)
	dd if="$F" of="$C" bs="$UCCP" 2> "$S/uc.err" & echo $! > "$S/pid.work"; wait $! || die "ucanary: the copy (dd bs=$UCCP) failed: $(tail -1 "$S/uc.err")"
	rm -f "$S/pid.work"; sync; [ "$TEST" = 1 ] || echo 3 > /proc/sys/vm/drop_caches
	h=$(md5sum < "$C" | cut -d' ' -f1)
	if [ "$h" = "$H" ]; then
		rm -f "$C"; sync
		echo "ucanary $N copy bs=$UCCP: md5 of the copy $h OK ($(( ($(up_cs) - t1) / 100 )) s; the copy removed)" | tee -a "$S/results.txt"
	else
		echo "ucanary $N copy bs=$UCCP: md5 of the copy ${h:-none} FAIL ($(( ($(up_cs) - t1) / 100 )) s; the copy kept to look at)" | tee -a "$S/results.txt"
		echo "CANARY FAIL ucanary $N: the known md5 is $H; the file-to-file copy at bs=$UCCP reads back ${h:-nothing}; kernel $KR" | tee -a "$S/results.txt"
		die "CANARY FAIL ucanary $N: the copy at bs=$UCCP reads back ${h:-nothing}, the known md5 is $H (the clean stop runs now; ${C##*/} kept)"
	fi
	echo "ucanary $N OK: md5 $H on 4 odd-block reads (bs $UCBS) + 1 odd-block copy (bs $UCCP); $sz bytes; kernel $KR; $(( ($(up_cs) - t0) / 100 )) s on the box" | tee -a "$S/results.txt"
	echo "$(up_s)" > "$S/heartbeat"; DONE=1
}
xsnap() {            # v9.7, $1 = file: the instruments (FABLE-OPT §2.0): uptime, ctxt, NIC / sata / xor interrupts, softnet, nfsd pools, vmstat
	{
		echo "t $(up_cs)"
		awk '$1 == "ctxt" { print "ctxt " $2 }' /proc/stat
		awk '/eth|sata|xor|mv643xx/ { s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; else break; print "irq " $NF " " s }' /proc/interrupts
		awk 'function hx(s,   i, n) { n = 0; s = tolower(s); for (i = 1; i <= length(s); i++) n = n * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1; return n }
			{ p += hx($1); d += hx($2); q += hx($3) } END { if (NR) print "softnet " p " " d " " q }' /proc/net/softnet_stat 2>/dev/null
		[ -r "$NFSD/pool_stats" ] && awk '/^#/ { for (i = 3; i <= NF; i++) h[i - 2] = $i; next } NF > 1 { for (i = 2; i <= NF; i++) v[i - 1] += $i; n = NF - 1 } END { for (i = 1; i <= n; i++) print "pool " h[i] " " v[i] }' "$NFSD/pool_stats"
		awk 'NF == 2 && $2 ~ /^[0-9]+$/ { print "vm " $1 " " $2 }' /proc/vmstat
	} > "$1"
}
cmd_xsnap() {        # v9.7: xsnap begin|end NAME around one client copy (outside the client's timed window)
	need_root; need_active; W=${1:-}; NAME=${2:-}; [ $# = 2 ] || die "xsnap begin|end NAME"
	echo "$NAME" | grep -qE '^[a-z0-9-]{1,40}$' || die "xsnap name: a-z 0-9 - only"
	case "$W" in
	begin) xsnap "$S/xsnap.$NAME.a";;
	end) [ -f "$S/xsnap.$NAME.a" ] || die "no xsnap begin $NAME"; xsnap "$S/xsnap.$NAME.b"
		awk -v name="$NAME" '
			FNR == 1 { f++ }
			$1 == "t" { t[f] = $2; next }
			{ k = $1 " " $2; if ($1 == "softnet") { a[f, "softnet processed"] = $2; a[f, "softnet dropped"] = $3; a[f, "softnet squeezed"] = $4; K["softnet processed"]; K["softnet dropped"]; K["softnet squeezed"]; next }
			  if ($1 == "ctxt") { a[f, "ctxt"] = $2; K["ctxt"]; next } a[f, k] = $3; K[k] }
			END {
				sec = (t[2] - t[1]) / 100; if (sec <= 0) sec = 0.01
				printf "# xstat %s: %.1f s between begin and end; every counter delta (end - begin), zeros left out\n", name, sec
				for (k in K) { d = a[2, k] - a[1, k]; if (d != 0) printf "%s %d\n", k, d }
			}' "$S/xsnap.$NAME.a" "$S/xsnap.$NAME.b" > "$S/xstat-$NAME.txt"
		awk -v name="$NAME" '
			NR == 1 { sub(/^# xstat [^:]*: /, ""); sec = $1; next }
			$1 == "ctxt" { c = $2 } $1 == "irq" { irq = irq (irq != "" ? ", " : "") $2 " +" $3 }
			$1 == "softnet" { sn = sn " " $2 " +" $3 } $1 == "pool" { pl = pl " " $2 " +" $3 }
			$1 == "vm" && $2 ~ /^(pgpgin|pgpgout|pgfault|pgmajfault|pswpin|pswpout|pgsteal_kswapd|pgsteal_direct|allocstall_normal|nr_dirtied|nr_written)$/ { vm = vm " " $2 " +" $3 }
			END { printf "xstat %s: %.1f s | ctxt +%d (%.0f/s) | irq %s | softnet%s | nfsd pool%s | vm%s\n", name, sec, c, (sec > 0 ? c / sec : 0), (irq != "" ? irq : "none"), (sn != "" ? sn : " none"), (pl != "" ? pl : " none"), (vm != "" ? vm : " none") }' "$S/xstat-$NAME.txt" | tee -a "$S/results.txt";;
	*) die "xsnap begin|end NAME";;
	esac
	echo "$(up_s)" > "$S/heartbeat"
}
cmd_facts() {        # v9.7, read-only (FABLE-OPT §2.0 F0): what this box is, for the receipts. debugfs: mounted read-only for the
	# clk_summary read only if it is not mounted, and unmounted again (never one it found mounted)
	[ $# = 0 ] || die "facts takes no argument"
	need_root; need_dir; lock_cmd; cd /
	FM=0
	if [ "$TEST" != 1 ] && ! awk -v d="$DBG" '$2 == d && $3 == "debugfs" { f = 1 } END { exit !f }' /proc/mounts; then
		mount -t debugfs -o ro debugfs "$DBG" 2>/dev/null && FM=1
	fi
	{
		echo "# facts ($VERSION) $(date -u '+%Y-%m-%d %H:%M:%S UTC'), uptime $(up_s) s"
		echo "## uname"; uname -a
		echo "## cmdline"; cat /proc/cmdline
		echo "## cpuinfo"; cat /proc/cpuinfo
		echo "## clk_summary"; if [ -r "$DBG/clk/clk_summary" ]; then cat "$DBG/clk/clk_summary"; else echo "(not readable: $DBG/clk/clk_summary)"; fi
		echo "## cpufreq"; for f in /sys/devices/system/cpu/cpu0/cpufreq/*; do [ -f "$f" ] && echo "${f##*/} $(cat "$f" 2>/dev/null | tr '\n' ' ')"; done
		echo "## meminfo (head)"; head -8 /proc/meminfo
		echo "## net"; for n in /sys/class/net/*; do [ -e "$n" ] || continue; d=$(readlink "$n/device/driver" 2>/dev/null); echo "${n##*/}: driver ${d##*/} mtu $(cat "$n/mtu" 2>/dev/null) speed $(cat "$n/speed" 2>/dev/null) duplex $(cat "$n/duplex" 2>/dev/null) txqlen $(cat "$n/tx_queue_len" 2>/dev/null) operstate $(cat "$n/operstate" 2>/dev/null) rps $(cat "$n/queues/rx-0/rps_cpus" 2>/dev/null) gro_flush_timeout $(cat "$n/gro_flush_timeout" 2>/dev/null) napi_defer_hard_irqs $(cat "$n/napi_defer_hard_irqs" 2>/dev/null)"; done
		for m in mv643xx_eth sata_mv; do [ -d "/sys/module/$m/parameters" ] && for f in /sys/module/$m/parameters/*; do [ -f "$f" ] && echo "module $m ${f##*/} $(cat "$f" 2>/dev/null)"; done; done
		echo "## interrupts"; cat /proc/interrupts
		echo "## nfsd"; for f in versions threads max_block_size nfsv4gracetime nfsv4leasetime pool_threads; do [ -r "$NFSD/$f" ] && echo "$f $(cat "$NFSD/$f" 2>/dev/null)"; done
	} > "$S/facts.txt" 2>&1
	CLK=read; grep -q '^(not readable: ' "$S/facts.txt" && CLK="not read"
	[ $FM = 1 ] && umount "$DBG" 2>/dev/null
	cat "$S/facts.txt"
	note "facts: $(wc -l < "$S/facts.txt" | tr -d ' ') lines in facts.txt; clk_summary $CLK$([ $FM = 1 ] && echo "; debugfs mounted read-only for it, unmounted")"
	return 0
}
cmd_zap() {
	need_root; need_dir; lock_cmd; need_active; DONE=0; CMD=zap-zeros; trap_stop; cd /
	Z=$MNT/$ZDIR
	[ -d "$Z" ] && [ ! -L "$Z" ] || { DONE=1; die "$Z is not a real folder: nothing removed"; }
	for f in $ZFILES; do
		p=$Z/$f
		[ -L "$p" ] && { DONE=1; die "$p is a symlink: nothing removed"; }
		[ -f "$p" ] || { DONE=1; die "$p is missing or not a regular file: nothing removed"; }
		sz=$(ls -ln "$p" | awk '{ print $5 }'); nl=$(ls -ln "$p" | awk '{ print $2 }')
		[ "$sz" = "$ZSIZE" ] || { DONE=1; die "$p is $sz bytes, not $ZSIZE: nothing removed"; }
		[ "$nl" = 1 ] || { DONE=1; die "$p has $nl hard links: nothing removed"; }
		r=$(cmp "$p" /dev/zero 2>&1); case "$r" in *EOF*"$p"*) ;; *) DONE=1; die "$p is not all zeros ($r): nothing removed";; esac
	done
	others=$(ls -A "$Z" | grep -vxE 'bench-2g\.bin|bench-write-2g\.bin' | tr '\n' ' ')
	for f in $ZFILES; do note "zap-zeros: $(ls -ln "$Z/$f" | awk '{ print "uid " $3 " gid " $4 " size " $5 }') $ZDIR/$f: all zeros, removing"; rm -f "$Z/$f"; done
	sync
	note "zap-zeros: $ZDIR itself kept$([ -n "$others" ] && echo " (also holds: $others)")"      # v9: the files were asked gone, not the folder
	echo "zap-zeros: removed $ZDIR/{${ZFILES% *},${ZFILES#* }} (2 x $ZSIZE bytes of zeros)" >> "$S/results.txt"
	echo "$(up_s)" > "$S/heartbeat"; DONE=1
}
cmd_status() {
	echo "version $VERSION · active $([ -e "$ACTIVE" ] && echo yes || echo no) · md $(md_up && astate || echo none) · knobs $(md_up && knobs || echo none) · mount $(mounted_rw && echo rw || { mounted && echo ro || echo none; }) · server $(cat "$S/server" 2>/dev/null || echo none) · guard $(cat "$S/pid.guard" 2>/dev/null || echo none) · uptime $(up_s) s"
	grep -A3 "^$MDN " /proc/mdstat 2>/dev/null
	[ -f "$S/results.txt" ] && cat "$S/results.txt"
	return 0
}

CMD=${1:-}; [ $# -gt 0 ] && shift
case "$CMD" in
preflight) cmd_preflight;;
arm) cmd_arm;;
gate-check) need_dir; r=$(gate) && { echo "gate: the token matches"; exit 0; }; echo "gate: $r"; exit 1;;
up) cmd_up "$@";;
local) cmd_local "$@";;
tune) cmd_tune "$@";;
profile) cmd_profile "$@";;
serve) cmd_serve "$@";;
md5) cmd_md5 "$@";;
ucanary) cmd_ucanary "$@";;
xsnap) cmd_xsnap "$@";;
facts) cmd_facts "$@";;
unserve) need_root; need_dir; servers_down; note "unserve: servers down";;
creds) need_root; need_active; cat "$S/creds";;
sample) cmd_sample "$@";;
dropcache) need_root; need_active; sync; [ "$TEST" = 1 ] || echo 3 > /proc/sys/vm/drop_caches; echo "$(up_s)" > "$S/heartbeat";;
zap-zeros) cmd_zap;;
heartbeat) need_dir; [ -e "$ACTIVE" ] && echo "$(up_s)" > "$S/heartbeat"; exit 0;;
results-to-share) need_root; need_active; cp "$S/results.txt" "$MNT/$BENCH/results.txt" 2>/dev/null
	for f in "$S"/profile-*.txt "$S"/xstat-*.txt "$S"/facts.txt; do [ -f "$f" ] && cp "$f" "$MNT/$BENCH/" 2>/dev/null; done; sync;;      # v9.4: the profiles too (v9.7: xstat, facts)
status) cmd_status;;
print-conf) CLIENT=${2:-}; valid_ip "$CLIENT" || die "print-conf samba4|ksmbd CLIENT_IP"      # read-only: the config a serve would write
	case "${1:-}" in samba4) samba_conf "$S/samba";; ksmbd) ksmbd_conf;; *) die "print-conf samba4|ksmbd CLIENT_IP";; esac;;
guard) [ -e "$ACTIVE" ] && guard;;
return-later) sleep "$RETURN_SEC"
	if [ -e "$STAY" ] || [ -e "$ACTIVE" ]; then note "return-later: $([ -e "$STAY" ] && echo "$STAY exists" || echo "a new rw session is up"): not going home"; exit 0; fi
	note "return-later: $RETURN_SEC s after the clean stop, no $STAY: back to the stock system now"
	if [ "$TEST" = 1 ]; then echo "would reboot at $(up_s)" > "$S/returned"; exit 0; fi
	sync; reboot;;
stop) need_root; cd /; [ "${1:-}" = --for-reboot ] && W="reboot path" || W="by hand"
	if [ ! -e "$ACTIVE" ] && ! md_up && ! mounted && [ ! -s "$S/knobs.saved" ] && ! { [ -e "$PE" ] && [ "$(cat "$PE" 2>/dev/null)" != 0 ]; }; then
		echo "ex4-rwbench: stop: nothing is up (SAFE)"; exit 0
	fi      # v9.4: a knob record left by an earlier stop (or a profiler left on) = run the stop again: it retries them
	stop_all "$W"; exit $?;;
*) sed -n '10,71p' "$SELF" >&2; exit 64;;
esac
