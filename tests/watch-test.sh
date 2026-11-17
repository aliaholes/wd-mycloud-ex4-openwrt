#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# watch-test.sh : host/ex4-watch.sh on canned network answers (WATCH_FAKE): what it calls the trial, what it does not.
#   sh watch-test.sh <ex4-watch.sh> <workdir (must not exist)>        Born Nov 16 2026 (EX4 run 5 prep).
set -u
WS=$1; W=$2
export NET=192.0.2 BOXIP=192.0.2.101      # RFC 5737 documentation addresses: nothing here touches a network
[ -e "$W" ] && { echo "REFUSED: $W exists"; exit 1; }
mkdir -p "$W"; W=$(cd "$W" && pwd); RUN=5-l2off-20261116-2222; PASS=0; FAIL=0
ck() { echo "$1" | cksum | cut -d' ' -f1; }
STOCK="SSH-2.0-OpenSSH_5.9"; DB="SSH-2.0-dropbear_2025.88"; WD=00:90:a9:00:00:50
base() { printf '192.0.2.101 %s\n192.0.2.162 aa:bb:cc:00:00:01\n192.0.2.254 aa:bb:cc:00:00:02\n' "$WD"; }
mk() { # $1 = scenario dir: baseline = round 0
	mkdir -p "$1"; base > "$1/neigh-0.txt"; echo "$STOCK" > "$1/banner-192.0.2.101-0.txt"; }
sshfile() { # $1 = dir, $2 = ip, $3 = round, $4 = cmdline text
	echo "$4" > "$1/ssh-$2-$3-$(ck 'cat /proc/cmdline').txt"
	echo "Linux ex4-trial 6.12.112 #0 armv5tel GNU/Linux" > "$1/ssh-$2-$3-$(ck 'uname -a; cat /tmp/sysinfo/board_name /tmp/sysinfo/model 2>/dev/null; uptime').txt"
	echo "inet 192.0.2.137/24" > "$1/ssh-$2-$3-$(ck 'ip addr; ip route').txt"
	echo "== EX4 trial self-test ==" > "$1/ssh-$2-$3-$(ck 'cat /tmp/ex4-selftest.txt').txt"
	echo "log" > "$1/ssh-$2-$3-$(ck 'logread').txt"; echo "dmesg line" > "$1/ssh-$2-$3-$(ck 'dmesg').txt"; }
run() { # $1 = name: baseline + watch on the scenario; prints the witness line
	WATCH_FAKE="$W/$1" bash "$WS" baseline "$W/$1/out" > "$W/$1/baseline.log" 2>&1 || { echo "baseline failed"; cat "$W/$1/baseline.log"; return; }
	WATCH_FAKE="$W/$1" bash "$WS" watch "$W/$1/out" "$RUN" 1 > "$W/$1/watch.log" 2>&1
	head -1 "$W/$1/out/lan-witness-$RUN.txt" 2>/dev/null; }
t() { name=$1; pat=$2; got=$(run "$3"); if echo "$got" | grep -q -- "$pat"; then PASS=$((PASS+1)); echo "PASS  $name"; else FAIL=$((FAIL+1)); echo "FAIL  $name (pattern: $pat)"; echo "      got: $got"; sed 's/^/      /' "$W/$3/watch.log" | tail -6; fi; }
# A: stock goes away, the trial shows up on another address with the box's MAC, key login works and holds the run id, stock returns
mk "$W/a"; printf '192.0.2.162 aa:bb:cc:00:00:01\n' > "$W/a/neigh-1.txt"
printf '192.0.2.137 %s\n192.0.2.162 aa:bb:cc:00:00:01\n' "$WD" > "$W/a/neigh-2.txt"; echo "$DB" > "$W/a/banner-192.0.2.137-2.txt"
sshfile "$W/a" 192.0.2.137 2 "console=ttyS0,115200n8 ex4boot_run=$RUN"
base > "$W/a/neigh-3.txt"; echo "$STOCK" > "$W/a/banner-192.0.2.101-3.txt"
t "A trial on a new address with WD's MAC, key login, run id in /proc/cmdline -> reached=ssh token=yes, and it sees stock return" "^LAN-WITNESS run=$RUN reached=ssh ip=192.0.2.137 mac=$WD token=yes at=.* stock_back=20.* kernel=6.12.112 selftest_bytes=[1-9]" a
# B: the trial takes the box's OWN address (same MAC, same lease)
mk "$W/b"; base > "$W/b/neigh-1.txt"; echo "$DB" > "$W/b/banner-192.0.2.101-1.txt"; sshfile "$W/b" 192.0.2.101 1 "console=ttyS0,115200n8 ex4boot_run=$RUN"
t "B the trial on the box's own address (banner changed from stock's to dropbear) -> reached=ssh" "^LAN-WITNESS run=$RUN reached=ssh ip=192.0.2.101 .* token=yes" b
# C: only an unrelated new device appears
mk "$W/c"; printf '192.0.2.162 aa:bb:cc:00:00:01\n192.0.2.55 de:ad:be:ef:00:01\n' > "$W/c/neigh-1.txt"
t "C a new device that is not the trial (no ssh) -> reached=ping only, token=no" "^LAN-WITNESS run=$RUN reached=ping ip=192.0.2.55 mac=de:ad:be:ef:00:01 token=no" c
# D: a dropbear host lets the key in but has no run id (not this run)
mk "$W/d"; printf '192.0.2.137 %s\n' "$WD" > "$W/d/neigh-1.txt"; echo "$DB" > "$W/d/banner-192.0.2.137-1.txt"; sshfile "$W/d" 192.0.2.137 1 "console=ttyS0,115200n8"
t "D key login works but /proc/cmdline has no run id -> NOT counted as ssh" "^LAN-WITNESS run=$RUN reached=ping ip=192.0.2.137 .* token=no" d
# E: nothing at all
mk "$W/e"; printf '192.0.2.162 aa:bb:cc:00:00:01\n' > "$W/e/neigh-1.txt"
t "E the box is gone and nothing shows up -> reached=none" "^LAN-WITNESS run=$RUN reached=none ip=none mac=none token=no" e
# F: stock never leaves (the launch did not happen): its banner is never mistaken for the trial
mk "$W/f"; base > "$W/f/neigh-1.txt"; echo "$STOCK" > "$W/f/banner-192.0.2.101-1.txt"
t "F stock never left: reached=none (stock's own banner is never a candidate)" "^LAN-WITNESS run=$RUN reached=none " f
grep -q 'ex4-stay\|reboot\|rm \|> */tmp\|touch ' "$WS" && { c=$(grep -v '^[[:space:]]*#' "$WS" | grep -c 'ex4-stay\|reboot\|[^a-z]rm \|touch '); [ "$c" = 0 ] && { PASS=$((PASS+1)); echo "PASS  static: outside comments the watcher has no rm, touch, reboot or ex4-stay (it only reads the trial)"; } || { FAIL=$((FAIL+1)); echo "FAIL  static: the watcher changes something ($c lines)"; }; } || { PASS=$((PASS+1)); echo "PASS  static: the watcher has no rm, touch, reboot or ex4-stay"; }
echo "watch-test: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
