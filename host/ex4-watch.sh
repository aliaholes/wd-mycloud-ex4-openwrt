#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# ex4-watch.sh : the LAN-side witness for an EX4 RAM trial. Runs on YOUR computer (the one that holds the trial's ssh
# key and sits on the same LAN), never on the EX4. It only looks: ping sweep, the neighbour table, the ssh banner on
# port 22, and (only on a host that looks like the trial) a key-only ssh that reads files. It changes nothing on the
# trial system (it never creates /tmp/ex4-stay) and nothing on the LAN. Needs: bash, fping, nc, ip, ssh.
#
# Required in the environment:
#   NET=<first three octets of your LAN, e.g. 10.0.0>     BOXIP=<the EX4's address under stock>
#   KEY=<the trial's ssh PRIVATE key, the one whose .pub you gave build.sh>
# Optional: BUNDLE=<the built bundle dir> (for its RUNID), OUI (default 00:90:a9, WD's prefix), STEP (seconds, default 20)
#
#   bash ex4-watch.sh baseline [OUTDIR]
#        BEFORE the jump, while stock is up: sweep $NET.0/24, save "ip mac" for every host that answers, and the
#        ssh banner of the box under stock. Prints the OUTDIR to give to `watch`.
#   bash ex4-watch.sh watch OUTDIR [RUNID] [MINUTES, default 30]
#        AFTER the launch: every 20 s sweep again. A CANDIDATE is: the box's own address, any host with WD's MAC
#        prefix (00:90:a9), any MAC that was not in the baseline. On a candidate whose port 22 answers as dropbear
#        (OpenWrt's ssh server; stock's banner is recorded and never mistaken for it) it logs in with the trial key
#        and reads: /proc/cmdline (the run id must be in it), uname, ip addr, the self-test, logread, dmesg, and on
#        every round the fan state line (/tmp/ex4fan.status), the fan log, the link counters and the three MACs.
#        Ends when stock's own banner is back on the box's address, or after MINUTES.
#        Leaves OUTDIR/lan-witness-<RUNID>.txt, first line:
#          LAN-WITNESS run=<id> reached=ssh|ping|none ip=<ip> mac=<mac> token=yes|no at=<time> ...
#        Copy that file into the bundle's logs/ folder on the box before `sh ex4-trial.sh verdict`: the verdict reads it.
#   reached=ssh  : logged in with the trial key AND /proc/cmdline held ex4boot_run=<RUNID>  (the modern system, on the LAN)
#   reached=ping : a candidate answered ping while stock's banner was gone, but no key login worked
#   reached=none : nothing seen
# Test hook (tests/watch-test.sh): WATCH_FAKE=<dir> replaces the three network primitives with canned files.
# Born Nov 16 2026; used as the witness of runs 5, 6 and 7 (as run5-/run6-/run7-watch.sh) on the one test unit.
set -u
NET=${NET:?set NET to the first three octets of your LAN (e.g. NET=10.0.0)}; BOXIP=${BOXIP:?set BOXIP to the address of the EX4 under stock}; OUI=${OUI:-00:90:a9}
KEY=${KEY:-}; [ -n "$KEY" ] || [ -n "${WATCH_FAKE:-}" ] || { echo "REFUSED: set KEY to the trial's ssh private key" >&2; exit 64; }
BUNDLE=${BUNDLE:-out/bundle}
STEP=${STEP:-20}
FAKE=${WATCH_FAKE:-}; ROUND=0
say() { echo "$(date '+%H:%M:%S') $*"; [ -n "${LOG:-}" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; return 0; }

sweep() {          # prints "ip mac" for every host on the /24 that has a usable neighbour entry after a ping sweep
	if [ -n "$FAKE" ]; then cat "$FAKE/neigh-$ROUND.txt" 2>/dev/null; return 0; fi
	fping -a -q -r 0 -t 250 -g "$NET.0/24" > /dev/null 2>&1
	ip -4 neigh show | awk -v n="$NET." 'index($1, n) == 1 && $0 ~ /lladdr/ && $NF != "FAILED" && $NF != "INCOMPLETE" { for (i = 1; i <= NF; i++) if ($i == "lladdr") print $1, tolower($(i + 1)) }' | sort -u
}
banner() {         # $1 = ip: the first line port 22 sends (empty if closed)
	if [ -n "$FAKE" ]; then cat "$FAKE/banner-$1-$ROUND.txt" 2>/dev/null; return 0; fi
	timeout 4 nc -w 3 "$1" 22 < /dev/null 2>/dev/null | head -c 120 | head -1 | tr -d '\r'
}
tssh() {           # $1 = ip, $2 = remote command: key-only, never asks, never stores the trial's (RAM-made) host key
	if [ -n "$FAKE" ]; then cat "$FAKE/ssh-$1-$ROUND-$(echo "$2" | cksum | cut -d' ' -f1).txt" 2>/dev/null; return $?; fi
	timeout 25 ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=6 "root@$1" "$2" 2>> "$OUT/ssh-errors.txt"
}

MODE=${1:-}
case "$MODE" in
baseline)
	OUT=${2:-./ex4-watch-$(date +%Y%m%d-%H%M%S)}
	[ -e "$OUT" ] && { echo "REFUSED: $OUT exists"; exit 1; }
	mkdir -p "$OUT" || exit 1; LOG="$OUT/watch.log"
	sweep > "$OUT/neigh-baseline.txt"
	banner "$BOXIP" > "$OUT/stock-banner.txt"
	say "baseline: $(wc -l < "$OUT/neigh-baseline.txt") hosts answer on $NET.0/24; the box ($BOXIP) has MAC $(awk -v b="$BOXIP" '$1 == b { print $2 }' "$OUT/neigh-baseline.txt"), ssh banner under stock: '$(cat "$OUT/stock-banner.txt")'"
	[ -s "$OUT/stock-banner.txt" ] || say "WARNING: no ssh banner from $BOXIP: is stock up? Without it the watch cannot tell stock from the trial on that address."
	grep -qi dropbear "$OUT/stock-banner.txt" && say "WARNING: stock's own banner says dropbear: the watch tells the trial from stock by the run id in /proc/cmdline only."
	echo "$OUT"
	;;
watch)
	OUT=${2:?usage: ex4-watch.sh watch OUTDIR [RUNID] [MINUTES]}
	RUN=${3:-$(cat "$BUNDLE/RUNID" 2>/dev/null)}; MIN=${4:-30}
	[ -s "$OUT/neigh-baseline.txt" ] || { echo "REFUSED: no baseline in $OUT (run: baseline)"; exit 1; }
	[ -n "$RUN" ] || { echo "REFUSED: no run id (give it, or BUNDLE=<dir with RUNID>)"; exit 1; }
	[ -n "$FAKE" ] || [ -r "$KEY" ] || { echo "REFUSED: trial key $KEY not readable"; exit 1; }
	LOG="$OUT/watch.log"; WIT="$OUT/lan-witness-$RUN.txt"
	[ -e "$WIT" ] && { echo "REFUSED: $WIT exists (one watch per run id and OUTDIR)"; exit 1; }
	STOCKB=$(cat "$OUT/stock-banner.txt" 2>/dev/null)
	REACHED=none; RIP=; RMAC=; TOKEN=no; DETAIL=; SEENGONE=0; END=$(( $(date +%s) + MIN * 60 )); STOCKBACK=
	say "watch: run $RUN, up to $MIN min, every $STEP s; candidates = $BOXIP, MAC prefix $OUI, any MAC not in the baseline"
	while :; do
		ROUND=$((ROUND + 1))
		sweep > "$OUT/neigh-now.txt"
		CAND=$(awk -v b="$BOXIP" -v o="$OUI" 'NR == FNR { base[$2] = 1; next } $1 == b || index($2, o) == 1 || !($2 in base) { print $1 "," $2 }' "$OUT/neigh-baseline.txt" "$OUT/neigh-now.txt")
		BOXB=$(banner "$BOXIP")
		if [ -n "$STOCKB" ] && [ "$BOXB" = "$STOCKB" ]; then
			if [ $SEENGONE = 1 ]; then STOCKBACK=$(date '+%Y-%m-%dT%H:%M:%S'); say "stock's own ssh banner is back on $BOXIP: the trial is over"; break; fi
		else
			[ $SEENGONE = 0 ] && say "stock's banner is gone from $BOXIP (now: '${BOXB:-nothing}'): the jump happened"
			SEENGONE=1
		fi
		for c in $CAND; do
			ip=${c%,*}; mac=${c#*,}
			[ "$ip" = "$BOXIP" ] && b=$BOXB || b=$(banner "$ip")
			[ -n "$STOCKB" ] && [ "$b" = "$STOCKB" ] && continue                 # stock itself
			if [ $SEENGONE = 1 ] && [ "$REACHED" = none ]; then REACHED=ping; RIP=$ip; RMAC=$mac; say "candidate $ip ($mac) answers ping; port 22 says '${b:-nothing}'"; fi
			case "$b" in *[Dd]ropbear*) ;; *) continue;; esac
			CL=$(tssh "$ip" 'cat /proc/cmdline')
			[ -n "$CL" ] || { say "candidate $ip ($mac): dropbear on port 22, the trial key was not let in (yet)"; continue; }
			case " $CL " in *" ex4boot_run=$RUN "*) TOKEN=yes;; *) TOKEN=no;; esac
			if [ "$REACHED" != ssh ] || ! grep -q "^== bays seen" "$OUT/trial-selftest.txt" 2>/dev/null; then      # v5: until the self-test is whole
				echo "$CL" > "$OUT/trial-cmdline.txt"
				tssh "$ip" 'uname -a; cat /tmp/sysinfo/board_name /tmp/sysinfo/model 2>/dev/null; uptime' > "$OUT/trial-uname.txt"
				tssh "$ip" 'ip addr; ip route' > "$OUT/trial-ipaddr.txt"
				tssh "$ip" 'cat /tmp/ex4-selftest.txt' > "$OUT/trial-selftest.txt"
				tssh "$ip" 'logread' > "$OUT/trial-logread.txt"
				tssh "$ip" 'dmesg' > "$OUT/trial-dmesg.txt"
				DETAIL="kernel=$(awk 'NR == 1 { print $3 }' "$OUT/trial-uname.txt") selftest_bytes=$(wc -c < "$OUT/trial-selftest.txt") dmesg_lines=$(wc -l < "$OUT/trial-dmesg.txt")"
				grep -E '^security (root_password_field|uhttpd|tcp_lan_ports|udp_lan_ports) ' "$OUT/trial-selftest.txt" 2>/dev/null | while read -r SL; do say "self-test (v7): $SL"; done
			fi
			if [ "$TOKEN" = yes ]; then
				FS=$(tssh "$ip" 'cat /tmp/ex4fan.status' | head -1)
				if [ -n "$FS" ]; then
					echo "$(date '+%H:%M:%S') ex4fan: $FS" >> "$OUT/trial-fan.txt"
					FL=$(tssh "$ip" 'cat /tmp/ex4fan.log'); [ -n "$FL" ] && echo "$FL" > "$OUT/trial-fanlog.txt"
					say "fan: $(echo "$FS" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^(level|rpm|drives|main|sata|soc|T|micro)=/) printf "%s ", $i }')"
				else
					say "fan: no /tmp/ex4fan.status on the trial (ex4fan is not running?)"
				fi
				LK=$(tssh "$ip" 'echo "eth1 carrier_changes $(cat /sys/class/net/eth1/carrier_changes) uptime $(cut -d" " -f1 /proc/uptime) eth0 $(cat /sys/class/net/eth0/address) eth1 $(cat /sys/class/net/eth1/address) br-lan $(cat /sys/class/net/br-lan/address)"' | head -1)
				[ -n "$LK" ] && { echo "$(date '+%H:%M:%S') link: $LK" >> "$OUT/trial-link.txt"; say "link: $LK"; }
				[ "$REACHED" = ssh ] || say "IN: key-only ssh into $ip ($mac); /proc/cmdline holds ex4boot_run=$RUN; $DETAIL; files in $OUT/trial-*.txt"
				REACHED=ssh; RIP=$ip; RMAC=$mac
			else
				say "candidate $ip ($mac): the trial key got in, but /proc/cmdline has no ex4boot_run=$RUN: '$CL' (not counted)"
			fi
		done
		[ "$(date +%s)" -ge "$END" ] && { say "time is up ($MIN min)"; break; }
		[ -n "$FAKE" ] && [ ! -e "$FAKE/neigh-$((ROUND + 1)).txt" ] && { say "(test: no more canned rounds)"; break; }
		[ -n "$FAKE" ] || sleep "$STEP"
	done
	[ "$REACHED" = ssh ] || TOKEN=no
	echo "LAN-WITNESS run=$RUN reached=$REACHED ip=${RIP:-none} mac=${RMAC:-none} token=$TOKEN at=$(date '+%Y-%m-%dT%H:%M:%S') stock_back=${STOCKBACK:-not-seen} rounds=$ROUND $DETAIL" > "$WIT"
	{ echo "# written by ex4-watch.sh; details: $OUT/watch.log"
	  if [ -s "$OUT/trial-fanlog.txt" ]; then echo "# the trial's /tmp/ex4fan.log as last read:"; awk '{ p = index($0, "] "); if (p) print substr($0, 1, p + 1) "ex4fan: " substr($0, p + 2) }' "$OUT/trial-fanlog.txt"; fi
	  if [ -s "$OUT/trial-fan.txt" ]; then echo "# /tmp/ex4fan.status, one line per round of this watch:"; cat "$OUT/trial-fan.txt"; fi
	  if [ -s "$OUT/trial-link.txt" ]; then echo "# eth1's carrier_changes counter and the three addresses, one line per round of this watch:"; cat "$OUT/trial-link.txt"; fi
	  if [ -s "$OUT/trial-selftest.txt" ]; then echo "# the trial's self-test (/tmp/ex4-selftest.txt) as last read:"; cat "$OUT/trial-selftest.txt"; fi
	} >> "$WIT"
	say "witness: $(head -1 "$WIT")"
	say "copy $WIT into the bundle's logs/ folder on the box (as lan-witness-$RUN.txt) before running verdict"
	;;
*)
	echo "usage: bash ex4-watch.sh baseline [OUTDIR] | watch OUTDIR [RUNID] [MINUTES]" >&2; exit 64
	;;
esac
