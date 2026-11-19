#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# ex4-rwbench-client.sh (v8; v9 = the review's must_fix + nits; v9.3 = tuning arms; v9.4 = NFS block size, NFS arms, profiles; v9.7 = NFSv4.2,
# nfsd threads, client read-ahead, rsize/wsize, NFS arm keys, the data canary, instruments; v9.8 = the user-copy canary) : the CLIENT half of the read-write trial bench (docs/RWBENCH.md). Runs on a Linux
# machine on the same LAN as the EX4 (the build box, never the box that runs your other work), as a normal user
# with sudo for the two mounts. It drives box/ex4-rwbench.sh (in the trial as /usr/sbin/ex4-rwbench) over the
# trial's key-only ssh, and runs the SMB and NFS copies itself. It never writes the token file: you type it.
#
#   bash host/ex4-rwbench-client.sh --box IP --key PRIVATE_KEY --out DIR [--runs N] [--mib N] [--engines "samba4 ksmbd"]
#        [--nfs] [--no-local] [--zap-zeros] [--no-return] [--token-wait SEC] [--dry-run]
#        [--skip-copy 0|1] [--arms "sc=256,ra=128,gt=0 sc=1024,ra=1024,gt=0 ..."] [--arm-engines "samba4 ksmbd"]
#        [--nfs-block KB] [--arm-nfs] [--profile] [--profile-arms] [--profile-mib N]
#        [--nfs-vers 3|4.2] [--nfs-threads N] [--nfs-ra-kb N] [--nfs-rsize KB] [--nfs-wsize KB] [--canary|--no-canary] [--instruments]
#        [--ucanary]
#
#   --box        the trial's address (the EX4 keeps its DHCP lease under the trial)
#   --key        the trial's ssh PRIVATE key (the one whose .pub the bundle was built with)
#   --out        a NEW folder for every receipt (refused if it exists)
#   --runs       copies per engine and direction (default 3; the median is what counts)
#   --mib        size of each copy (default 2048 = the stock bench's 2 GiB)
#   --engines    the SMB servers to A/B, one at a time, on the same share (default "samba4 ksmbd")
#   --nfs        (v9: OFF by default) also the NFSv3 pair. NFSv3 trusts the client's ADDRESS only (no password in
#                the protocol): rpcbind, statd, mountd and nfsd then listen on the LAN for those minutes. Only when you
#                mean it; the box refuses `serve nfs` without the flag this passes. The window grows by 15 minutes.
#   --no-local   skip the box's own dd pair
#   --zap-zeros  remove stock's two zero files in Public/ex4-bench/ during the trial. (v9: the DEFAULT keeps them:
#                the trial has no quota accounting, so delete them under stock afterwards, where the quota counts it)
#   --no-return  after the clean stop, leave the trial up (default: reboot it back to stock at once). A stop that
#                says "SAFE, but look" (rc 3: a member's examine or the ext4 superblock looks odd after the stop)
#                ALWAYS leaves the trial up and says what to look at (v9)
#   --dry-run    print the plan; ssh only for read-only checks (preflight); no mount, no rw
#   (v9.3) --skip-copy 0|1   passed to the box's `up`: md's skip_copy, written after the rw switch and BEFORE the ext4 mount
#                (the box's wall 11). Default: not passed (the kernel's own value, today's behaviour).
#   (v9.3) --arms "SPEC SPEC ..."   tuning arms, run AFTER the baseline (local + --engines [+ NFS]) of the same session.
#                SPEC = comma list of sc=N (stripe_cache_size 256..4096), ra=N (read_ahead_kb of md1 + every member,
#                128..8192), gt=N (group_thread_cnt 0..2), at least one. Arm i (a1, a2, ...): the box's `tune`, then the
#                local pair + the raw md read labelled a<i>, then --arm-engines' write+read runs named a<i>-ENGINE-w/rN.
#                Every box results line carries the knobs it ran under; results-client.txt gets an "== arm a<i>" line.
#                Default: no arms = the plan of before v9.3 exactly. skip_copy is never an arm (it is set only at up).
#   (v9.3) --arm-engines "samba4 ksmbd"   engines run inside every arm (default none: the local rows only)
#   (v9.3) THE WINDOW: the plan's time is computed at a conservative 30 MiB/s for every MiB it moves (local 2048 w +
#                2048 r + 1024 raw, each copy, the zero check) + fixed overheads; window = max(25 / 40 with --nfs, that),
#                and a plan over the box's 45 minutes is REFUSED before anything is touched, with how to split it.
#   (v9.4) --nfs-block KB   (needs --nfs) KB in 64 128 256 512 1024: every `serve nfs` (baseline and arms) gets
#                --max-block-kb KB (nfsd's max_block_size, set before nfsd starts) and every NFS mount rsize=wsize=KB*1024
#                (still soft,timeo=600,retrans=4). Default: neither (the kernel's value, today's mounts).
#   (v9.4) --arm-nfs        (needs --nfs and --arms) the NFS write+read runs inside every arm too (= nfs in --arm-engines)
#   (v9.4) --profile        after the baseline: the box's `profile --label base` (one local write under the function
#                profiler; the box refuses on a kernel without one, which ends the run before any arm). --profile-arms:
#                `profile --label aN` after each arm. --profile-mib N (1..2048, default 2048) sizes that write. The
#                profile-*.txt files come back with the receipts (box-profile-*.txt). Window: each profile is priced at
#                10 MiB/s (the profiler slows the write) + 60 s.
#   (v9.7, all need --nfs; none given = the v9.4 plan exactly)
#   --nfs-vers 3|4.2   4.2: the box serves NFSv4.2 ONLY (`serve nfs ... --vers 4.2`: nfsd's 2049 the one door, no rpcbind /
#                statd / mountd listener, the folder as the v4 pseudo-root) and this mounts BOX:/ with vers=4.2 (still soft,
#                timeo=600,retrans=4), then one untimed create + remove (the server's v4 grace, 10 s, never lands in a copy)
#   --nfs-threads N    1..16: nfsd's threads (`serve nfs ... --threads N`, read back by the box). Default: the box's 8
#   --nfs-ra-kb N      128..16384: THIS machine's read_ahead_kb on the NFS mount's bdi (/sys/class/bdi/MAJ:MIN), written after
#                every mount, read back, the value found written back before every unmount (FABLE-OPT F2). Default: untouched
#   --nfs-rsize KB / --nfs-wsize KB   32 64 128 256 512 1024, each on its own (default: --nfs-block, as v9.4)
#   (arms) inside --arms, with --arm-nfs: nv=3|4.2, nt=N, cra=N, rs=KB, ws=KB per arm (the box-side nv / nt by that arm's own
#                unserve + serve; cra / rs / ws on that arm's mounts); an arm may name only these (no tune then)
#   --canary     (ON by itself whenever any v9.7 NFS option or arm key is given; --canary turns it on for a plain --nfs, and
#                --no-canary off): every NFS write copies a seeded non-zero pattern file made here before the token (md5 here),
#                the box md5s what landed (`md5 NAME`, untimed), the read-back is md5'd as it is read. Any mismatch = a loud
#                CANARY FAIL row in results-client.txt and the clean stop. Window: + the box's md5 read of every NFS write
#   --instruments  `facts` once after up (box-facts.txt), and around every copy the box's `xsnap begin|end` (ctxt, NIC /
#                sata_mv / xor interrupts, softnet, nfsd pool_stats, vmstat -> box-xstat-*.txt + one line per copy) and,
#                on NFS, this machine's /proc/self/mountstats entry before and after (mountstats-NAME.a/.b). + 15 s per copy
#   (v9.8) --ucanary   THE USER-COPY CANARY (FABLE-OPT F3 row; needs --nfs, turns the canary on, refused with --no-canary): ONCE per
#                session (one kernel per session), right after the FIRST canary'd NFS write's box md5 said OK, the box's
#                `ucanary NAME --md5 PATTERN_MD5` (untimed, outside every copy): four odd-block-size dd reads of that file into
#                md5sum + one odd-block file-to-file copy, caches dropped before each, every md5 = the pattern's. Its rows land in
#                results-client.txt; anything but its OK line = a loud CANARY FAIL row and the clean stop. Window: + 7 x --mib
#                at 30 MiB/s + 30 s (the box reads the file 6 times and writes it once: ~8.4 min priced for 2 GiB)
#
# The order: md5 of the box's /usr/sbin/ex4-rwbench == this repo's box/ex4-rwbench.sh -> preflight -> arm (prints
# the token) -> WAIT for you to type it on the box -> up -> local -> per engine: serve, write+read x N, unserve ->
# [NFS] -> (v9.4) [profile base] -> (v9.3) [per arm: tune, local --label, arm engines (v9.4: + NFS), profile aN] -> [zap-zeros] -> results -> stop (must say SAFE; it
# also gives every knob back) -> reboot to stock. A trap on EXIT INT TERM HUP unmounts
# here and runs the box's clean stop on every way out, and nothing reboots unless the stop said SAFE (rc 0).
# v9: every copy runs under `timeout -k 15` (a stalled mount can never hang this script past its clean stop); NFS
# mounts soft; SIGPIPE is ignored (a closed terminal must not kill the cleanup).
set -u
trap '' PIPE
BOX=; KEY=; OUT=; RUNS=3; MIB=2048; ENGINES="samba4 ksmbd"; NFS=0; LOCAL=1; ZAP=0; RETURN=1; TOKWAIT=900; DRY=0
SKC=; ARMS=; ARMENG=; ARMENG_SET=0; NFSB=; ARMNFS=0; PROF=0; PROFARMS=0; PMIB=2048
NFSV=; NFST=; NFSRA=; NRS=; NWS=; CANARY=auto; INSTR=0; NEW97=0      # v9.7
UCAN=0; UCDONE=0      # v9.8
SSH_BIN=${EX4RW_SSH:-ssh}; SUDO=${EX4RW_SUDO:-sudo}; PY=${EX4RW_PY:-python3}
while [ $# -gt 0 ]; do
	case "$1" in
	--box) BOX=$2; shift 2;; --key) KEY=$2; shift 2;; --out) OUT=$2; shift 2;; --runs) RUNS=$2; shift 2;; --mib) MIB=$2; shift 2;;
	--engines) ENGINES=$2; shift 2;; --nfs) NFS=1; shift;; --no-nfs) NFS=0; shift;; --no-local) LOCAL=0; shift;;
	--zap-zeros) ZAP=1; shift;; --keep-zeros) ZAP=0; shift;;
	--no-return) RETURN=0; shift;; --token-wait) TOKWAIT=$2; shift 2;; --dry-run) DRY=1; shift;;
	--arm-nfs) ARMNFS=1; shift;; --profile) PROF=1; shift;; --profile-arms) PROFARMS=1; shift;;
	--canary) CANARY=1; shift;; --no-canary) CANARY=0; shift;; --instruments) INSTR=1; shift;;
	--ucanary) UCAN=1; shift;;      # v9.8
	--skip-copy|--arms|--arm-engines|--nfs-block|--profile-mib|--nfs-vers|--nfs-threads|--nfs-ra-kb|--nfs-rsize|--nfs-wsize) [ $# -ge 2 ] || { echo "ex4-rwbench-client: REFUSED: $1 needs a value" >&2; exit 1; }
		case "$1" in --skip-copy) SKC=$2;; --arms) ARMS=$2;; --arm-engines) ARMENG=$2; ARMENG_SET=1;; --nfs-block) NFSB=${2:-empty};; --profile-mib) PMIB=${2:-empty};;
		--nfs-vers) NFSV=${2:-empty}; NEW97=1;; --nfs-threads) NFST=${2:-empty}; NEW97=1;; --nfs-ra-kb) NFSRA=${2:-empty}; NEW97=1;;
		--nfs-rsize) NRS=${2:-empty}; NEW97=1;; --nfs-wsize) NWS=${2:-empty}; NEW97=1;; esac; shift 2;;
	*) sed -n '9,83p' "$0" >&2; exit 64;;
	esac
done
die() { echo "ex4-rwbench-client: REFUSED: $*" >&2; [ -n "${OUT:-}" ] && [ -d "$OUT" ] && echo "$(date '+%F %T') REFUSED: $*" >> "$OUT/client.log"; exit 1; }
say() { echo "ex4-rwbench-client: $*"; [ -d "${OUT:-/nonexistent}" ] && echo "$(date '+%F %T') $*" >> "$OUT/client.log"; return 0; }
[ -n "$BOX" ] && [ -n "$KEY" ] && [ -n "$OUT" ] || die "--box, --key and --out are required"
echo "$BOX" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || die "--box takes an IPv4 address"
[ -r "$KEY" ] || [ -n "${EX4RW_FAKE:-}" ] || die "cannot read the key $KEY"
echo "$RUNS $MIB" | grep -qE '^[1-9][0-9]* [1-9][0-9]*$' || die "--runs and --mib take positive whole numbers"
for e in $ENGINES; do case "$e" in samba4|ksmbd) ;; *) die "--engines: samba4 and/or ksmbd, not '$e'";; esac; done
# ---- v9.3: skip_copy, the arms, the window (all checked here, before any ssh) ----
case "$SKC" in ''|0|1) ;; *) die "--skip-copy takes 0 or 1, not '$SKC'";; esac
inr() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$1))" -ge "$2" ] && [ "$((10#$1))" -le "$3" ]; }
# ---- v9.7: the NFS options (checked before the arms: an arm's NFS keys default to these) ----
pow2kb() { case "$1" in 32|64|128|256|512|1024) return 0;; esac; return 1; }
if [ -n "$NFSV$NFST$NFSRA$NRS$NWS" ]; then [ $NFS = 1 ] || die "--nfs-vers / --nfs-threads / --nfs-ra-kb / --nfs-rsize / --nfs-wsize need --nfs"; fi
case "$NFSV" in ''|3|4.2) ;; *) die "--nfs-vers: 3 or 4.2, not '$NFSV'";; esac
[ -z "$NFST" ] || inr "$NFST" 1 16 || die "--nfs-threads: 1..16, not '$NFST'"; [ -n "$NFST" ] && NFST=$((10#$NFST))
[ -z "$NFSRA" ] || inr "$NFSRA" 128 16384 || die "--nfs-ra-kb: 128..16384, not '$NFSRA'"; [ -n "$NFSRA" ] && NFSRA=$((10#$NFSRA))
[ -z "$NRS" ] || pow2kb "$NRS" || die "--nfs-rsize: 32, 64, 128, 256, 512 or 1024 (KiB), not '$NRS'"
[ -z "$NWS" ] || pow2kb "$NWS" || die "--nfs-wsize: 32, 64, 128, 256, 512 or 1024 (KiB), not '$NWS'"
ARMN=0; ANFS=0; declare -a ARMSPEC ARMTUNE ARMNV ARMNT ARMCRA ARMRS ARMWS
read -r -a ARMLIST <<< "$ARMS"      # no glob expansion of the specs
for a in "${ARMLIST[@]}"; do
	[[ "$a" =~ ^[a-z]+=[0-9.]+(,[a-z]+=[0-9.]+)*$ ]] || die "--arms: '$a' is not a comma list of sc=N, ra=N, gt=N (v9.7, with --arm-nfs: nv=, nt=, cra=, rs=, ws=)"
	t=; seen=,; anv=; ant=; acra=; ars=; aws=
	IFS=, read -r -a kvs <<< "$a"
	for kv in "${kvs[@]}"; do
		k=${kv%%=*}; v=${kv#*=}
		case ",$seen," in *",$k,"*) die "--arms: '$a' names $k twice";; esac; seen="$seen$k,"
		case "$k" in
		sc) inr "$v" 256 4096 || die "--arms: '$a': sc (stripe_cache_size) 256..4096, not $v"; t="$t --stripe-cache $((10#$v))";;
		ra) inr "$v" 128 8192 || die "--arms: '$a': ra (read_ahead_kb) 128..8192, not $v"; t="$t --readahead-kb $((10#$v))";;
		gt) inr "$v" 0 2 || die "--arms: '$a': gt (group_thread_cnt) 0..2, not $v"; t="$t --group-threads $((10#$v))";;
		nv) case "$v" in 3|4.2) anv=$v;; *) die "--arms: '$a': nv (NFS version) 3 or 4.2, not $v";; esac; ANFS=1;;
		nt) inr "$v" 1 16 || die "--arms: '$a': nt (nfsd threads) 1..16, not $v"; ant=$((10#$v)); ANFS=1;;
		cra) inr "$v" 128 16384 || die "--arms: '$a': cra (client read_ahead_kb) 128..16384, not $v"; acra=$((10#$v)); ANFS=1;;
		rs) pow2kb "$v" || die "--arms: '$a': rs (rsize KiB) 32..1024 in powers of 2, not $v"; ars=$v; ANFS=1;;
		ws) pow2kb "$v" || die "--arms: '$a': ws (wsize KiB) 32..1024 in powers of 2, not $v"; aws=$v; ANFS=1;;
		*) die "--arms: '$a': unknown knob '$k' (sc, ra, gt; with --arm-nfs nv, nt, cra, rs, ws; skip_copy is --skip-copy, set only at up)";;
		esac
	done
	ARMN=$((ARMN + 1)); ARMSPEC[$ARMN]=$a; ARMTUNE[$ARMN]=${t# }
	ARMNV[$ARMN]=${anv:-$NFSV}; ARMNT[$ARMN]=${ant:-$NFST}; ARMCRA[$ARMN]=${acra:-$NFSRA}; ARMRS[$ARMN]=${ars:-$NRS}; ARMWS[$ARMN]=${aws:-$NWS}
done
[ -z "$(echo "$ARMS" | tr -d ' ')" ] && [ -n "$ARMS" ] && die "--arms: empty"
for e in $ARMENG; do case "$e" in samba4|ksmbd) ;; nfs) [ $NFS = 1 ] || die "--arm-engines nfs needs --nfs";; *) die "--arm-engines: samba4, ksmbd (nfs with --nfs), not '$e'";; esac; done
[ $ARMENG_SET = 1 ] && [ -n "$ARMENG" ] && [ $ARMN = 0 ] && die "--arm-engines without --arms: there is no arm to run them in"
# ---- v9.4: NFS block size, NFS inside the arms, the profiles (checked here too, before any ssh) ----
case "$NFSB" in '') ;; 64|128|256|512|1024) [ $NFS = 1 ] || die "--nfs-block needs --nfs";; *) die "--nfs-block: 64, 128, 256, 512 or 1024 (KiB), not '$NFSB'";; esac
if [ $ARMNFS = 1 ]; then
	[ $NFS = 1 ] || die "--arm-nfs needs --nfs"; [ $ARMN -gt 0 ] || die "--arm-nfs without --arms: there is no arm to run it in"
	case " $ARMENG " in *" nfs "*) ;; *) ARMENG="${ARMENG:+$ARMENG }nfs";; esac
fi
[ $ANFS = 1 ] && { case " $ARMENG " in *" nfs "*) ;; *) die "--arms: nv=, nt=, cra=, rs=, ws= are NFS arm keys: they need --arm-nfs";; esac; NEW97=1; }
[ $PROFARMS = 1 ] && [ $ARMN = 0 ] && die "--profile-arms without --arms: there is no arm to profile"
inr "$PMIB" 1 2048 || die "--profile-mib: 1..2048, not '$PMIB'"; PMIB=$((10#$PMIB))
PROF_SEC=$(( PMIB / 10 + 60 ))      # one profile: the write at a pessimistic 10 MiB/s under the profiler + 60 s
# ---- v9.7: the canary (ON by itself with any v9.7 NFS option or arm key), the instruments ----
if [ $UCAN = 1 ]; then      # v9.8: the user-copy canary checks a file an NFS canary write left, with the pattern's md5
	[ $NFS = 1 ] || die "--ucanary needs --nfs (it checks the file the first NFS canary write leaves on the box)"
	[ "$CANARY" = 0 ] && die "--ucanary needs the canary (the pattern file and its md5): drop --no-canary"
	CANARY=1
fi
if [ "$CANARY" = auto ]; then CANARY=$NEW97; fi
[ $CANARY = 1 ] && [ $NFS = 0 ] && die "--canary needs --nfs (it guards the NFS copies)"
V42B=0; [ "$NFSV" = 4.2 ] && V42B=1
V42A=0; ANP=0; case " $ARMENG " in *" nfs "*) ANP=1;; esac
for i in $(seq 1 $ARMN); do [ "${ARMNV[$i]}" = 4.2 ] && V42A=1; done
plan_sec() {         # $1 = MiB moved, $2 = number of engine passes, $3 = fixed seconds: at a conservative 30 MiB/s
	echo $(( $1 / 30 + $2 * (60 + 20 * RUNS) + $3 ))
}
NENG=$(echo $ENGINES | wc -w); [ $NFS = 1 ] && NENG=$((NENG + 1)); NAE=$(echo $ARMENG | wc -w); PASS=$((RUNS * 2 * MIB))
BASE_SEC=$(( $(plan_sec $((LOCAL * 5120 + NENG * PASS + ZAP * 4096)) "$NENG" 180) + PROF * PROF_SEC ))
ARM_SEC=$(( $(plan_sec $((LOCAL * 5120 + NAE * PASS)) "$NAE" 30) + PROFARMS * PROF_SEC ))
# v9.7 (all 0 without a v9.7 flag): the box's md5 read of every canary write (at 30 MiB/s), 30 s per v4.2 pass (its grace),
# 15 s per instrumented copy + 30 s for facts
BASE_SEC=$(( BASE_SEC + CANARY * NFS * RUNS * MIB / 30 + V42B * NFS * 30 + INSTR * (NENG * RUNS * 2 * 15 + 30) ))
ARM_SEC=$(( ARM_SEC + CANARY * ANP * RUNS * MIB / 30 + V42A * ANP * 30 + INSTR * NAE * RUNS * 2 * 15 ))
# v9.8 (0 without --ucanary): the user-copy canary once per session, in the baseline's NFS pass (--ucanary needs --nfs, which always runs
# one): the box reads the file 6 times (4 odd-block reads, the copy's read, the copy's md5) and writes it once, at 30 MiB/s, + 30 s of syncs
BASE_SEC=$(( BASE_SEC + UCAN * (7 * MIB / 30 + 30) ))
NEED_SEC=$((BASE_SEC + ARMN * ARM_SEC)); NEED_MIN=$(( (NEED_SEC + 59) / 60 ))
if [ $NEED_MIN -gt 45 ]; then
	K=$(( (2700 - BASE_SEC) / ARM_SEC ))
	if [ $ARMN -gt 0 ] && [ $K -ge 1 ]; then
		die "the plan needs ~$NEED_MIN min at a conservative 30 MiB/s (baseline ~$(( (BASE_SEC + 59) / 60 )) min + $ARMN arms x ~$(( (ARM_SEC + 59) / 60 )) min); the box's rw window is at most 45 min. Split it: $K arm(s) fit per session after this baseline, so $(( (ARMN + K - 1) / K )) sessions (each its own token), e.g. --arms '$(echo $ARMS | cut -d' ' -f1-$K)' now and the rest after; or drop the baseline engines (--engines '') / lower --runs, --mib, --arm-engines"
	elif [ $ARMN -gt 0 ]; then
		die "the plan needs ~$NEED_MIN min at a conservative 30 MiB/s (baseline ~$(( (BASE_SEC + 59) / 60 )) min + $ARMN arms x ~$(( (ARM_SEC + 59) / 60 )) min); the box's rw window is at most 45 min, and not even one arm fits after this baseline: drop the baseline engines (--engines ''), or lower --runs, --mib or --arm-engines"
	else
		die "the plan needs ~$NEED_MIN min at a conservative 30 MiB/s; the box's rw window is at most 45 min: split it over sessions (fewer --engines per run, or lower --runs / --mib)"
	fi
fi
[ "$(id -u)" != 0 ] || die "run as your normal user (sudo is asked for the mounts only)"
[ -e "$OUT" ] && die "$OUT exists (every run gets a new folder)"
mkdir -p "$OUT/mnt" && chmod 700 "$OUT" || die "cannot make $OUT"; OUT=$(cd "$OUT" && pwd); MNT=$OUT/mnt
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/.." && pwd); BOXSH=$TOP/box/ex4-rwbench.sh
[ -f "$BOXSH" ] || die "no $BOXSH"
CLIENT=${EX4RW_CLIENT_IP:-$(ip -4 route get "$BOX" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')}
[ -n "$CLIENT" ] || die "cannot tell this machine's address toward $BOX"
WMIN=25; [ $NFS = 1 ] && WMIN=40          # the guard's rw window: local + samba4 + ksmbd fit 25 min with ~2x room
[ $NEED_MIN -gt $WMIN ] && WMIN=$NEED_MIN   # v9.3: never less than the plan needs at 30 MiB/s (<= 45, checked above)
TMO=$((MIB / 4 + 120))                      # one copy may take this long (4 MiB/s + 2 min), then it is killed
say "window $WMIN min (the plan needs ~$NEED_MIN min at 30 MiB/s), copy timeout $TMO s"
say "client $(hostname) $CLIENT -> box $BOX · runs $RUNS x $MIB MiB · engines '$ENGINES' · nfs $NFS · local $LOCAL · zap $ZAP · return $RETURN · dry $DRY · out $OUT"
say "skip_copy ${SKC:-not set (kernel default)} · arms $ARMN$(for i in $(seq 1 $ARMN); do printf ' a%s=%s' "$i" "${ARMSPEC[$i]}"; done) · arm engines '${ARMENG}'"
say "nfs block ${NFSB:-not set (kernel default)} · profile base $PROF · profile arms $PROFARMS · profile write $PMIB MiB"
[ $UCAN = 1 ] && say "v9.8: user-copy canary ON: once, after the first canary'd NFS write (4 odd-block dd reads + 1 odd-block copy on the box, untimed)"
say "v9.7: nfs vers ${NFSV:-not set (v3, v9.4's)} · nfsd threads ${NFST:-not set (the box's 8)} · client read_ahead_kb ${NFSRA:-not set} · rsize ${NRS:-${NFSB:-not set}} · wsize ${NWS:-${NFSB:-not set}} · canary $CANARY · instruments $INSTR$(for i in $(seq 1 $ARMN); do [ $ANP = 1 ] && printf ' · a%s nfs: nv=%s nt=%s cra=%s rs=%s ws=%s' "$i" "${ARMNV[$i]:-3}" "${ARMNT[$i]:--}" "${ARMCRA[$i]:--}" "${ARMRS[$i]:-${NFSB:--}}" "${ARMWS[$i]:-${NFSB:--}}"; done)"

SSHO=(-i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o PasswordAuthentication=no -o ConnectTimeout=10
      -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o UserKnownHostsFile="$OUT/known_hosts" -o StrictHostKeyChecking=accept-new)
box() { "$SSH_BIN" "${SSHO[@]}" "root@$BOX" "$@"; }                # the trial's host key is new each boot: pinned per run in $OUT
RB=/usr/sbin/ex4-rwbench

UP=0; HB=; SAFE=unknown; PAT=; RA_P=
cleanup() {
	rc=$?; trap - EXIT INT TERM HUP
	[ -n "$HB" ] && kill "$HB" 2>/dev/null
	[ -n "$PAT" ] && rm -f "$PAT"      # v9.7: the canary pattern (its seed + md5 are in client.log: the seed remakes it)
	[ -n "$RA_P" ] && declare -F ra_back > /dev/null && ra_back      # v9.7: this machine's read-ahead back before the unmount
	if mountpoint -q "$MNT" 2>/dev/null; then $SUDO umount "$MNT" 2>/dev/null || $SUDO umount -l "$MNT" 2>/dev/null; fi
	if [ $UP = 1 ]; then
		n=0; SAFE=no
		while [ $n -lt 3 ]; do
			box "$RB stop" > "$OUT/stop.$n.txt" 2>&1; src=$?; cat "$OUT/stop.$n.txt"
			if [ $src = 0 ] || [ $src = 3 ]; then SAFE=yes; [ $src = 3 ] && SAFE=yes-look; break; fi
			n=$((n + 1)); sleep 5
		done
		for f in results.txt journal.txt examine-before.txt examine-after.txt ext4-sb.txt ext4-sb-after.txt guard.log assemble.out readwrite.out; do
			box "cat /tmp/ex4-rwbench/$f" > "$OUT/box-$f" 2>/dev/null
		done
		box "dmesg" > "$OUT/box-dmesg.txt" 2>/dev/null
		# v9.4: the profiles (names are the box's own label set, a-z 0-9 -; anything else is never fetched)
		for f in $(box "ls /tmp/ex4-rwbench" 2>/dev/null | grep -E '^(profile-[a-z0-9-]{1,16}|xstat-[a-z0-9-]{1,40})\.txt$'); do box "cat /tmp/ex4-rwbench/$f" > "$OUT/box-$f" 2>/dev/null; done      # v9.7: + xstat
		# run 13: the servers' own logs (RAM on the trial: gone at the reboot); logs only, never a password file
		box 'for f in /tmp/ex4-rwbench/samba/log/* /tmp/ex4-rwbench/ksmbd/*.out /tmp/ex4-rwbench/nfs/*.log /tmp/ex4-rwbench/nfs/*.out; do [ -f "$f" ] && { echo "== $f"; tail -c 32768 "$f"; }; done' > "$OUT/box-server-logs.txt" 2>/dev/null
		if [ "$SAFE" = no ]; then
			say "THE CLEAN STOP DID NOT SAY SAFE (3 tries, $OUT/stop.*.txt). NOT rebooting. md1 may still be read-write: ssh in and look (ex4-rwbench status); the trial's own timers will not reboot it either while /tmp/ex4-rw-active exists."
			exit 2
		fi
		if [ "$SAFE" = yes-look ]; then      # v9: rc 3 = stopped, nothing read-write, but something looks odd: a human first
			say "clean stop: SAFE, BUT LOOK (rc 3). NOT rebooting: the trial stays up so you can look before stock boots into it."
			say "  look at: $OUT/box-examine-after.txt (State clean, Array State AAAA, ONE Events count on all four), $OUT/box-journal.txt (the stop's verdict line), $OUT/box-ext4-sb-after.txt, $OUT/box-dmesg.txt (md / ata / EXT4 lines)"
			say "  then: on the box 'cat /proc/mdstat' (nothing assembled), and reboot by hand when it looks right. The trial's auto-return comes back by itself 5 minutes after the stop unless /tmp/ex4-stay exists."
			exit 3
		fi
		say "clean stop: SAFE ($SAFE)"
		if [ $RETURN = 1 ]; then say "back to stock: reboot"; box "sync; reboot" > /dev/null 2>&1; fi
	fi
	exit $rc
}
trap cleanup EXIT; trap 'exit 130' INT TERM HUP

# ---- read-only checks ----
CL=$(box 'cat /proc/cmdline') || die "no key ssh to $BOX (is the trial up, is this the trial key?)"
echo "$CL" | grep -q 'ex4boot_run=' || die "$BOX is not the EX4 RAM trial (no ex4boot_run= in its /proc/cmdline)"
H1=$(box "md5sum < $RB" | cut -d' ' -f1); H2=$(md5sum < "$BOXSH" | cut -d' ' -f1)
[ -n "$H1" ] && [ "$H1" = "$H2" ] || die "the box's $RB ($H1) is not this repo's box/ex4-rwbench.sh ($H2): rebuild the bundle with EX4_RWBENCH=1"
box "$RB preflight" > "$OUT/preflight.txt" 2>&1 || { cat "$OUT/preflight.txt"; die "preflight refused (above)"; }
cat "$OUT/preflight.txt"
if [ $DRY = 1 ]; then say "dry run: preflight passed; the plan is in the header; nothing was armed, mounted or written"; exit 0; fi
for t in mount.cifs mount.nfs mountpoint "$PY"; do command -v "$t" >/dev/null || [ -n "${EX4RW_FAKE:-}" ] || die "no $t on this machine"; done
# ---- v9.7: the canary pattern, made BEFORE the token (never inside the rw window): seeded, non-zero, md5 here ----
PYGEN='import hashlib, os, random, sys
p, mib, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
r = random.Random(seed); h = hashlib.md5()
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
for i in range(mib):
    b = i.to_bytes(8, "little") + seed.to_bytes(8, "little") + r.randbytes((1 << 20) - 16)
    if os.write(fd, b) != len(b): sys.exit(3)
    h.update(b)
os.fsync(fd); os.close(fd)
print(h.hexdigest())'
if [ $CANARY = 1 ]; then
	AV=$(df -Pk "$OUT" | awk 'NR == 2 { print $4 }'); [ "${AV:-0}" -ge $((MIB * 1024 + 262144)) ] || die "the canary needs $MIB MiB + 256 MiB free under $OUT (has $((${AV:-0} / 1024)) MiB)"
	SEED=$(od -An -N4 -tu4 /dev/urandom | tr -d ' '); PAT=$OUT/canary-$SEED.bin
	PMD5=$("$PY" -I -c "$PYGEN" "$PAT" "$MIB" "$SEED") && [[ "$PMD5" =~ ^[0-9a-f]{32}$ ]] || die "could not make the canary pattern ($PMD5)"
	say "canary: seed $SEED, $MIB MiB, md5 $PMD5 ($PAT; removed at the end, the seed remakes it byte for byte)"
fi

# ---- the token: printed by the box, typed by YOU ----
box "$RB arm" > "$OUT/arm.txt" 2>&1 || { cat "$OUT/arm.txt"; die "arm refused"; }
echo; cat "$OUT/arm.txt" | sed -n '/^TOKEN/,$p'; echo
say "waiting up to $TOKWAIT s for the token on the box (this script never writes it)"
w=0; until box "$RB gate-check" > "$OUT/gate.txt" 2>&1; do
	[ $w -ge "$TOKWAIT" ] && die "no token after $TOKWAIT s ($(cat "$OUT/gate.txt")): nothing was made read-write"
	sleep 5; w=$((w + 5))
done
say "token seen: $(cat "$OUT/gate.txt")"

# ---- read-write from here: every exit path runs the clean stop ----
UP=1
box "$RB up $CLIENT --stay --window-min $WMIN${SKC:+ --skip-copy $SKC}" > "$OUT/up.txt" 2>&1 || { cat "$OUT/up.txt"; die "up refused (above): the trap runs the clean stop"; }
cat "$OUT/up.txt"
( while sleep 30; do box "$RB heartbeat" > /dev/null 2>&1; done ) & HB=$!
[ $INSTR = 1 ] && { box "$RB facts" > "$OUT/box-facts.txt" 2>&1 || say "facts said rc $? (see $OUT/box-facts.txt): going on, it measures nothing"; }      # v9.7

if [ $LOCAL = 1 ]; then box "$RB local" > "$OUT/local.txt" 2>&1 || { cat "$OUT/local.txt"; die "local bench failed"; }; cat "$OUT/local.txt"; fi

PYIO='import os, sys, time
p, mode, mib = sys.argv[1], sys.argv[2], int(sys.argv[3])
buf = b"\0" * (1 << 20); n = 0; t = time.time()
if mode == "write":
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    for _ in range(mib): n += os.write(fd, buf)
    os.fsync(fd); os.close(fd)
else:
    fd = os.open(p, os.O_RDONLY)
    while True:
        b = os.read(fd, 1 << 20)
        if not b: break
        n += len(b)
    os.close(fd)
dt = time.time() - t
print("%s %d %.3f" % (mode, n >> 20, dt))
sys.exit(0 if n >> 20 == mib else 3)'
# v9.7, the canary's copies: wpat = write the pattern file (md5 as written), rmd5 = read back with an md5 as it is read
PYCAN='import hashlib, os, sys, time
p, mode, mib, src = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
h = hashlib.md5(); n = 0
if mode == "wpat":
    s = os.open(src, os.O_RDONLY)
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644); t = time.time()
    for _ in range(mib):
        b = os.read(s, 1 << 20)
        if len(b) != 1 << 20: sys.exit(4)
        n += os.write(fd, b); h.update(b)
    os.fsync(fd); os.close(fd); os.close(s)
else:
    fd = os.open(p, os.O_RDONLY); t = time.time()
    while True:
        b = os.read(fd, 1 << 20)
        if not b: break
        n += len(b); h.update(b)
    os.close(fd)
dt = time.time() - t
print("%s %d %.3f %s" % (mode, n >> 20, dt, h.hexdigest()))
sys.exit(0 if n >> 20 == mib else 3)'
COPY_MD5=
ms_snap() {      # v9.7 --instruments: this machine's /proc/self/mountstats entry for the bench mount ($1 = name, $2 = a|b)
	awk -v m="$MNT" '$1 == "device" { on = ($5 == m) } on' /proc/self/mountstats > "$OUT/mountstats-$1.$2.txt" 2>/dev/null
}
copy() {         # $1 = name, $2 = write|read (v9.7 wpat|rmd5), $3 = file on the mount: one timed copy with the box's sample around it
	local out sec
	[ $INSTR = 1 ] && { box "$RB xsnap begin $1" > /dev/null || die "xsnap begin $1"; ms_snap "$1" a; }      # v9.7, outside the timed window
	box "$RB sample begin $1" > /dev/null || die "sample begin $1"
	case "$2" in
	write|read) out=$(timeout -k 15 "$TMO" "$PY" -I -c "$PYIO" "$3" "$2" "$MIB") || die "$1: the $2 copy failed or timed out after $TMO s ($out)";;
	*) out=$(timeout -k 15 "$TMO" "$PY" -I -c "$PYCAN" "$3" "$2" "$MIB" "$PAT") || die "$1: the $2 copy failed or timed out after $TMO s ($out)";;
	esac
	sec=$(echo "$out" | awk '{ print $3 }'); COPY_MD5=$(echo "$out" | awk '{ print $4 }')
	box "$RB sample end $1 $MIB $sec" | tee -a "$OUT/results-client.txt"
	[ $INSTR = 1 ] && { ms_snap "$1" b; box "$RB xsnap end $1" | tee -a "$OUT/results-client.txt"; }
}
canary_fail() {  # v9.7: loud, in the receipts, then the clean stop (the trap): never silent
	echo "CANARY FAIL $1: the pattern's md5 is $PMD5 (seed $SEED), $2 read $3" | tee -a "$OUT/results-client.txt"
	die "CANARY FAIL $1: $2 read $3, the pattern is $PMD5: data did not survive the round trip (the clean stop runs now; the file stays in the bench folder to look at)"
}
canary_box() {   # $1 = copy name: the box md5s the file the write left (untimed, after the client's unmount)
	local h
	[ "$COPY_MD5" = "$PMD5" ] || canary_fail "$1" "the client, while writing," "${COPY_MD5:-nothing}"
	h=$(box "$RB md5 $1.bin" 2>&1 | tee -a "$OUT/results-client.txt" | awk '$1 == "canary" { print $4 }')
	[ "$h" = "$PMD5" ] || canary_fail "$1" "the box" "${h:-nothing (see results-client.txt)}"
}
ucanary_box() {  # v9.8 --ucanary, $1 = copy name: the box's user-copy canary on the file that write left (untimed; once per session)
	local out
	UCDONE=1
	out=$(box "$RB ucanary $1.bin --md5 $PMD5" 2>&1)
	echo "$out" | tee -a "$OUT/results-client.txt"
	echo "$out" | grep -q "^ucanary $1.bin OK: md5 $PMD5 " || canary_fail "ucanary-$1" "the box's user-copy canary (4 odd-block dd reads + 1 odd-block copy)" "$(echo "$out" | grep -m1 -E 'CANARY FAIL|REFUSED|FAIL' | cut -c1-240)"
}
umnt() {         # v9.7: this machine's read-ahead given back first (only when --nfs-ra-kb / cra= set it), then the same umount
	[ -n "$RA_P" ] && ra_back
	$SUDO umount "$MNT"
}
smb_mount() { $SUDO mount -t cifs "//$BOX/ex4bench" "$MNT" -o "credentials=$OUT/cred,vers=3.1.1,uid=$(id -u),gid=$(id -g),file_mode=0644,dir_mode=0755" || die "mount.cifs failed"; }
# run 13 attempt 4 (Nov 17 2026): soft,timeo=150,retrans=3 gave EIO 70 s into the first 2 GiB write ("server not responding, timed out"):
# the client queues hundreds of MiB of WRITEs and the last waits > 15 s behind them at ~40 MiB/s. Still soft (the bench must stay killable),
# but 60 s x 4 retries (< the copy's own timeout -k cap); real mounts on the finished NAS are hard (perf/PERF-DESIGN).
# v9.4: --nfs-block; v9.7: the CURRENT NFS settings (the globals, or one arm's own nv / nt / cra / rs / ws). With no v9.7 flag the
# mount options and the serve arguments are v9.4's byte for byte
CUR_NV=$NFSV; CUR_NT=$NFST; CUR_CRA=$NFSRA; CUR_RS=${NRS:-$NFSB}; CUR_WS=${NWS:-$NFSB}
nfs_opts() {
	local o=vers=3,proto=tcp,soft,timeo=600,retrans=4
	[ "$CUR_NV" = 4.2 ] && o=vers=4.2,proto=tcp,soft,timeo=600,retrans=4
	echo "$o${CUR_RS:+,rsize=$((CUR_RS * 1024))}${CUR_WS:+,wsize=$((CUR_WS * 1024))}"
}
nfs_serve_args() { echo "--unauthenticated-nfs${NFSB:+ --max-block-kb $NFSB}${CUR_NV:+ --vers $CUR_NV}${CUR_NT:+ --threads $CUR_NT}"; }
BDIR=/sys/class/bdi; [ -n "${EX4RW_FAKE:-}" ] && BDIR=${EX4RW_BDI_ROOT:-$BDIR}
bdi_of() { if [ -n "${EX4RW_FAKE:-}" ] && [ -n "${EX4RW_FAKE_BDI:-}" ]; then echo "$EX4RW_FAKE_BDI"; else mountpoint -d "$MNT"; fi; }
ra_set() {       # v9.7 (FABLE-OPT F2): this machine's read_ahead_kb on the NFS mount's bdi; the value found is given back at umnt
	local d; d=$(bdi_of) && [[ "$d" =~ ^[0-9]+:[0-9]+$ ]] || die "--nfs-ra-kb: cannot tell the NFS mount's bdi (got '$d')"
	RA_P=$BDIR/$d/read_ahead_kb; [ -r "$RA_P" ] || { RA_P=; die "--nfs-ra-kb: no $BDIR/$d/read_ahead_kb"; }
	RA_OLD=$(cat "$RA_P")
	echo "$CUR_CRA" | $SUDO tee "$RA_P" > /dev/null; [ "$(cat "$RA_P")" = "$CUR_CRA" ] || die "--nfs-ra-kb: $RA_P reads $(cat "$RA_P"), not $CUR_CRA"
	echo "$(date '+%F %T') client read_ahead_kb $RA_P: $RA_OLD -> $CUR_CRA (read back)" >> "$OUT/client.log"
}
ra_back() {
	local p=$RA_P; RA_P=
	[ -e "$p" ] || { echo "$(date '+%F %T') client read_ahead_kb $p: gone (the mount is gone; nothing to give back)" >> "$OUT/client.log"; return 0; }
	echo "$RA_OLD" | $SUDO tee "$p" > /dev/null
	if [ "$(cat "$p")" = "$RA_OLD" ]; then echo "$(date '+%F %T') client read_ahead_kb $p: back to $RA_OLD (read back)" >> "$OUT/client.log"
	else say "client read_ahead_kb $p NOT back to $RA_OLD (reads $(cat "$p")): it goes with this mount"; fi
}
nfs_mount() {
	if [ "$CUR_NV" = 4.2 ]; then $SUDO mount -t nfs -o "$(nfs_opts)" "$BOX:/" "$MNT" || die "mount.nfs (v4.2) failed"
	else $SUDO mount -t nfs -o "$(nfs_opts)" "$BOX:/mnt/md1/Public/ex4-bench-v8" "$MNT" || die "mount.nfs failed"; fi
	[ -n "$CUR_CRA" ] && ra_set
	if [ "$CUR_NV" = 4.2 ]; then      # v9.7: one untimed create + remove, so the server's v4 grace (10 s) never lands inside a timed copy
		timeout -k 5 120 "$PY" -I -c 'import os, sys; p = sys.argv[1]; os.close(os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)); os.unlink(p)' "$MNT/.ex4-warm.tmp" || die "v4.2: the warm-up create on the mount failed (grace never ended?)"
	fi
}
pass() {         # $1 = engine, $2 = mount function
	local r wm=write rm=read can=0
	case "$1" in nfs|*-nfs) [ $CANARY = 1 ] && { can=1; wm=wpat; rm=rmd5; };; esac      # v9.7: the canary on every NFS pair
	for r in $(seq 1 "$RUNS"); do
		$2; copy "$1-w$r" $wm "$MNT/$1-w$r.bin"; umnt || die "umount after the write"
		[ $can = 1 ] && canary_box "$1-w$r"
		[ $can = 1 ] && [ $UCAN = 1 ] && [ $UCDONE = 0 ] && ucanary_box "$1-w$r"      # v9.8: once, the box md5 said OK, the client unmounted
		box "$RB dropcache" || die "dropcache"
		$2; copy "$1-r$r" $rm "$MNT/$1-w$r.bin"
		if [ $can = 1 ]; then [ "$COPY_MD5" = "$PMD5" ] || canary_fail "$1-r$r" "the client's read-back" "${COPY_MD5:-nothing}"; echo "canary OK $1-w$r / $1-r$r: written, on the box and read back all md5 $PMD5" | tee -a "$OUT/results-client.txt"; fi
		rm -f "$MNT/$1-w$r.bin"; umnt || die "umount after the read"
	done
}
box "$RB creds" | awk -F= '$1 == "user" { print "username=" $2 } $1 == "password" { print "password=" $2 }' > "$OUT/cred"; chmod 600 "$OUT/cred"
grep -q '^password=.' "$OUT/cred" || die "no share password from the box"
for e in $ENGINES; do
	box "$RB serve $e $CLIENT" > "$OUT/serve-$e.txt" 2>&1 || { cat "$OUT/serve-$e.txt"; die "serve $e failed"; }
	pass "$e" smb_mount
	box "$RB unserve" > /dev/null
done
if [ $NFS = 1 ]; then
	box "$RB serve nfs $CLIENT $(nfs_serve_args)" > "$OUT/serve-nfs.txt" 2>&1 || { cat "$OUT/serve-nfs.txt"; die "serve nfs failed"; }
	pass nfs nfs_mount
	box "$RB unserve" > /dev/null
fi
# ---- v9.4: the baseline's profile (the box refuses on a kernel without the function profiler: the run ends cleanly) ----
profile() {      # $1 = label
	box "$RB profile --label $1 --mib $PMIB" > "$OUT/profile-$1.out" 2>&1 || { cat "$OUT/profile-$1.out"; die "profile $1 refused or failed (above)"; }
	tee -a "$OUT/results-client.txt" < "$OUT/profile-$1.out"
}
[ $PROF = 1 ] && profile base
# ---- v9.3: the tuning arms, after the baseline, in the same session ----
for i in $(seq 1 $ARMN); do
	say "arm a$i: ${ARMSPEC[$i]} (tune ${ARMTUNE[$i]:-none})"
	CUR_NV=${ARMNV[$i]}; CUR_NT=${ARMNT[$i]}; CUR_CRA=${ARMCRA[$i]}; CUR_RS=${ARMRS[$i]:-$NFSB}; CUR_WS=${ARMWS[$i]:-$NFSB}      # v9.7
	if [ -n "${ARMTUNE[$i]}" ]; then
		box "$RB tune ${ARMTUNE[$i]}" > "$OUT/tune-a$i.txt" 2>&1 || { cat "$OUT/tune-a$i.txt"; die "arm a$i: tune refused"; }
		echo "== arm a$i: ${ARMSPEC[$i]} | $(tail -1 "$OUT/tune-a$i.txt")" | tee -a "$OUT/results-client.txt"
	else echo "== arm a$i: ${ARMSPEC[$i]} | no box knob (NFS keys only: nv=${CUR_NV:-3} nt=${CUR_NT:-8} cra=${CUR_CRA:--} rs=${CUR_RS:--} ws=${CUR_WS:--})" | tee -a "$OUT/results-client.txt"; fi
	if [ $LOCAL = 1 ]; then box "$RB local --label a$i" > "$OUT/local-a$i.txt" 2>&1 || { cat "$OUT/local-a$i.txt"; die "arm a$i: local failed"; }; tee -a "$OUT/results-client.txt" < "$OUT/local-a$i.txt"; fi
	for e in $ARMENG; do
		if [ "$e" = nfs ]; then
			box "$RB serve nfs $CLIENT $(nfs_serve_args)" > "$OUT/serve-a$i-nfs.txt" 2>&1 || { cat "$OUT/serve-a$i-nfs.txt"; die "arm a$i: serve nfs failed"; }
			pass "a$i-nfs" nfs_mount
		else
			box "$RB serve $e $CLIENT" > "$OUT/serve-a$i-$e.txt" 2>&1 || { cat "$OUT/serve-a$i-$e.txt"; die "arm a$i: serve $e failed"; }
			pass "a$i-$e" smb_mount
		fi
		box "$RB unserve" > /dev/null
	done
	[ $PROFARMS = 1 ] && profile "a$i"
done
if [ $ZAP = 1 ]; then box "$RB zap-zeros" > "$OUT/zap.txt" 2>&1; cat "$OUT/zap.txt"; fi
box "$RB results-to-share" > /dev/null
say "bench done; results: $OUT/results-client.txt (+ box-results.txt after the stop)"
exit 0
