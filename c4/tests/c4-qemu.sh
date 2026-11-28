#!/bin/sh
# c4-qemu.sh (FINALIZE C4 K5, Nov 27 2026): the two proofs that need qemu-arm (run on a machine with qemu-arm user mode).
#   1. FORMS: the REAL K2 nandwrite (5f628c48) under qemu-arm with the 6.12 image's own musl + libgcc_s (-L SYSROOT, the r4b sysroot)
#      vs the strict fake (fakes/nandwrite-strict) on the same argument lists. On this host there is no MTD subsystem, so a form the
#      real tool PARSES stops at libmtd ("can't initialize libmtd" / an MTD error); a form it refuses stops in its option checks
#      (usage text, or a named errmsg_die before the device is opened). Two checks sit AFTER libmtd in the source (stdin + --input-skip
#      :344; -s not page-aligned :306): the real tool cannot reach them here, the fake applies them (stricter by design, named).
#   2. SH -N under the IMAGE'S OWN busybox ash (aecf7b8a, from the zImage's initramfs) for every C4 shell file + the mapped copies.
#   3. (AMEND 1, Nov 27 2026) the REAL helpers under that same ash + busybox: c4sim's nodedev() (the line copied OUT of the c4sim given
#      in FILES, never retyped) on real host char nodes (/dev/null 1:3, /dev/zero 1:5, /dev/full 1:7, /dev/random 1:8), a regular
#      file, a directory, a missing path; and ex4-c4cap's uptime line (copied out of the ex4-c4cap in FILES) on fake uptime files.
#      Only lstat of those nodes (ls -lnd); nothing is opened for writing. AMEND 1 also LEAVES the work dir (no recursive delete,
#      THE TMP WALL); its path is printed.
#   4. (AMEND 2, Nov 27 2026) the F1 + F2 code under that same ash + busybox (grep -o/-oi, BRE \{1,8\}, wc, sed, $((0x..))): c4sim's
#      bbfacts() (the function copied OUT of the c4sim in FILES, from its 'bbfacts() {' line to its closing '}', never retyped) on the
#      BOX'S OWN C4b nandwrite output (box/C4b.3-sim.txt lines 15-1517, the '  nandwrite: ' prefix stripped: NWBOX, 5th fixed arg) and on
#      made-up outputs; and THE C4SIM GATE line copied out of the mapped ex4-persist and ex4-markgood in FILES, with and without the flags.
#   sh c4-qemu.sh SYSROOT NANDWRITE FAKE NWBOX FILES... (FILES = shell files to sh -n)  read-only except a temp dir under $HOME/ex4-build/finalize/c4/
set -u
S=$1; NW=$2; FK=$3; NWBOX=$4; shift 4; FILES="$*"
Q="/usr/bin/qemu-arm -L $S"
m5() { md5sum < "$1" | cut -d' ' -f1; }
W=$HOME/ex4-build/finalize/c4/forms-$$; mkdir -p "$W"; head -c 214958080 /dev/zero | tr '\0' '\377' > "$W/dev7"
echo "c4-qemu $(m5 "$0") $(date '+%F %T %Z') on $(hostname); real nandwrite $(m5 "$NW"); fake $(m5 "$FK"); busybox $(m5 "$S/bin/busybox"); libc $(m5 "$S/lib/libc.so"); libgcc_s $(m5 "$S/lib/libgcc_s.so.1"); $(/usr/bin/qemu-arm --version | head -1)"
R=0
real() { o=$($Q "$NW" "$@" < /dev/null 2>&1); rc=$?
	if printf '%s' "$o" | grep -q 'Usage: nandwrite'; then echo "refuse(usage)"
	elif printf '%s' "$o" | grep -qi -e "can't pad" -e 'negative' -e 'blockalign' -e 'mutually exclusive'; then echo "refuse(opt)"
	elif printf '%s' "$o" | grep -qi -e libmtd -e 'MTD' -e 'not a character device' -e 'No such device'; then echo "parse"
	else echo "other(rc $rc)"; fi
	printf '      real rc %s: %s\n' "$rc" "$(printf '%s' "$o" | head -n 1 | sed "s#$W/dev7#DEV#g")" >> "$W/real.txt"; }
fake() { rm -f "$W/calls.log"; CASE=$W "$FK" "$@" < /dev/null > /dev/null 2>&1 && echo parse || echo refuse; }
echo "== 1. nandwrite forms: REAL (qemu) vs STRICT FAKE"
while IFS='|' read -r note args; do
	[ -n "$args" ] || continue
	set -- $args; a=; for x in "$@"; do [ "$x" = DEV ] && x=$W/dev7; a="$a $x"; done
	r=$(real $a); f=$(fake $a); rv=${r%%(*}
	if [ "$rv" = "$f" ]; then v=SAME; elif [ "$note" = stricter ] && [ "$rv" = parse ] && [ "$f" = refuse ]; then v="STRICTER(by design)"; else v=DIFFERENT; R=1; fi
	printf '  %-20s real=%-14s fake=%-7s nandwrite%s\n' "$v" "$r" "$f" "$(echo "$a" | sed "s#$W/dev7#DEV#g")"
	tail -n 1 "$W/real.txt"
done <<'EOF'
same|-p -k -s 0 DEV -
same|-p -k -s 196870144 DEV -
same|-p -k -s 0 DEV
same|--pad --skip-all-ffs --start=0 DEV -
same|-p -k -s 0 DEV - extra
same|-p -k
same|-p -Z -s 0 DEV -
same|-p -o DEV -
same|-s -5 DEV -
same|-b 3 DEV -
same|-a -n DEV -
same|--bogus DEV -
stricter|--input-skip=4096 DEV -
stricter|-p -s 1000 DEV -
EOF
echo "== 2. sh -n under the 6.12 image's own busybox ash (qemu)"
for f in $FILES; do $Q "$S/bin/busybox" ash -n "$f" > "$W/shn.out" 2>&1; rc=$?; printf '  rc=%s %s %s %s\n' $rc "$(m5 "$f")" "${f##*/}" "$(head -c 200 "$W/shn.out")"; [ $rc = 0 ] || R=1; done
$Q "$S/bin/busybox" ash -c 'echo $((6 * 7))' > "$W/ctl.out" 2>&1; echo "  control: busybox ash -c 'echo \$((6 * 7))' -> $(cat "$W/ctl.out") (shell math present in the image's ash)"
printf 'if then fi\n' > "$W/bad.sh"; $Q "$S/bin/busybox" ash -n "$W/bad.sh" > /dev/null 2>&1; echo "  control: a broken file -> rc $? (must be non-zero)"
echo "== 3. the AMEND 1 helpers, REAL busybox ash + ls (qemu)"
SIMF=; CAPF=; for f in $FILES; do case "${f##*/}" in c4sim) SIMF=$f;; ex4-c4cap) CAPF=$f;; esac; done
if [ -z "$SIMF" ] || [ -z "$CAPF" ]; then echo "  FAIL: FILES must name c4sim and ex4-c4cap"; R=1; else
  grep '^nodedev() { set -- ' "$SIMF" > "$W/nd.sh"; [ "$(wc -l < "$W/nd.sh")" = 1 ] || { echo "  FAIL: nodedev line not found once"; R=1; }
  : > "$W/plain"; chmod 644 "$W/plain"; mkdir "$W/adir"; chmod 755 "$W/adir"
  for pair in /dev/null=1:3 /dev/zero=1:5 /dev/full=1:7 /dev/random=1:8 "$W/plain=not-a-char-node(-rw-r--r--)" "$W/adir=not-a-char-node(drwxr-xr-x)" "$W/missing=not-a-char-node(missing)"; do
    pth=${pair%%=*}; want=${pair#*=}
    got=$($Q "$S/bin/busybox" ash -c ". $W/nd.sh; nodedev $pth" 2>&1)
    if [ "$got" = "$want" ]; then v=SAME; else v=DIFFERENT; R=1; fi
    printf '  %-9s nodedev %-22s -> %-28s (want %s; host ls -lnd: %s)\n' "$v" "$(echo "$pth" | sed "s#$W/##")" "$got" "$want" "$(ls -lnd "$pth" 2>&1 | cut -c1-60)"
  done
  grep "$(printf '^\t')up=; read -r up x 2>/dev/null < \$UPTIME; " "$CAPF" | sed "s/^$(printf '\t')//" > "$W/up.sh"; [ "$(wc -l < "$W/up.sh")" = 1 ] || { echo "  FAIL: uptime line not found once"; R=1; }
  for pair in '5397.42 1000.00=5397' '42.99 10.00=42' '0.51 0.10=0' 'garbage x=0' '=0' 'none=0'; do
    txt=${pair%%=*}; want=${pair#*=}; U=$W/uptime.$want.$(echo "$txt" | tr -c 'a-z0-9' _)
    [ "$txt" = none ] || printf '%s\n' "$txt" > "$U"
    got=$($Q "$S/bin/busybox" ash -c "UPTIME=$U; . $W/up.sh; echo \$up" 2>&1)
    if [ "$got" = "$want" ]; then v=SAME; else v=DIFFERENT; R=1; fi
    printf '  %-9s uptime file %-18s -> up=%s (want %s)\n' "$v" "'$txt'" "$got" "$want"
  done
fi
echo "== 4. AMEND 2: c4sim's bbfacts() + THE C4SIM GATE, REAL busybox ash (qemu)"
PERF=; MARF=; for f in $FILES; do case "${f##*/}" in *mapped-usr_sbin_ex4-persist) PERF=$f;; ov-c4a_mapped-usr_sbin_ex4-markgood) MARF=$f;; esac; done
if [ -z "$SIMF" ] || [ -z "$PERF" ] || [ -z "$MARF" ] || [ ! -s "$NWBOX" ]; then echo "  FAIL: FILES must name c4sim + the mapped ex4-persist + ov-c4a's mapped ex4-markgood, and NWBOX must exist"; R=1; else
  sed -n '/^bbfacts() {/,/^}$/p' "$SIMF" > "$W/bb.sh"; echo "  bbfacts copied out of c4sim: $(wc -l < "$W/bb.sh") lines, md5 $(m5 "$W/bb.sh")"
  printf 'BLK=131072; TMPD=%s\nsay() { echo "SAY $*"; }\nrefuse() { echo "REFUSED $*"; exit 1; }\n' "$W" > "$W/stub.sh"
  echo "  NWBOX (the box's own C4b nandwrite output) md5 $(m5 "$NWBOX"), $(wc -l < "$NWBOX") lines, $(grep -c 'Writing data to block' "$NWBOX") 'Writing data' lines"
  printf 'Writing data to block 0 at offset 0x0\nWriting data to block 1 at offset 0x20000\n' > "$W/nw-clean"
  { printf 'Writing data to block 99 at offset 0xc60000\nWriting data to block 100 at offset 0xBad block at c80000, 1 block(s) will be skipped\nc80000\n'; } > "$W/nw-inside"
  printf 'Writing data to block 1639 at offset 0xccc0000\ntoo many bad blocks, cannot complete request\n' > "$W/nw-toomany"
  printf 'Bad block at 1234567890, 1 block(s) will be skipped\n' > "$W/nw-9hex"
  printf 'Writing data to block 1502 at offset 0xbbc0000\nBad block at bba0000, 1 block(s) will be skipped\n' > "$W/nw-before"
  while IFS='|' read -r nwf st cnt want; do
    [ -n "$nwf" ] || continue
    [ "$nwf" = BOX ] && nwf=$NWBOX || nwf=$W/$nwf
    got=$($Q "$S/bin/busybox" ash -c ". $W/stub.sh; . $W/bb.sh; bbfacts $nwf $st $cnt; echo RC=\$?" 2>&1 | tr '\n' ' ')
    case "$got" in *"$want"*) v=SAME;; *) v=DIFFERENT; R=1;; esac
    printf '  %-9s bbfacts %-11s %s %s -> %s\n             (want: %s)\n' "$v" "${nwf##*/}" "$st" "$cnt" "$(echo "$got" | cut -c1-230)" "$want"
  done <<'EOF'
BOX|0|1501|SAY nandwrite probed block 1501 (0xbba0000, bad) AFTER the range's last block 1500
BOX|0|1502|REFUSED nandwrite met a bad block inside blocks 0..1501 (block 1501 at 0xbba0000): the data shifted
nw-clean|0|189|RC=0
nw-inside|0|189|REFUSED nandwrite met a bad block inside blocks 0..188 (block 100 at 0xc80000): the data shifted
nw-toomany|1502|138|REFUSED nandwrite printed bad-block text that is not one whole 'Bad block at <hex>, 1 block(s) will be skipped' line (1 mention(s), 0 whole line(s))
nw-9hex|0|189|REFUSED nandwrite printed bad-block text that is not one whole
nw-before|1502|138|SAY nandwrite reported block 1501 (0xbba0000, bad) BEFORE the range's first block 1502
EOF
  for pair in "$PERF=no persistence" "$MARF=NOT marked good"; do
    f=${pair%%=*}; tail=${pair#*=}
    grep "$(printf '^\t'){ \[ -e \$TMPD/ex4-c4sim.done \] && \[ ! -e \$TMPD/ex4-c4sim.refused \]; } || " "$f" | sed "s/^$(printf '\t')//" > "$W/gate.sh"
    [ "$(wc -l < "$W/gate.sh")" = 1 ] || { echo "  FAIL: the gate line is not in ${f##*/} exactly once"; R=1; continue; }
    for st in none done refused both; do
      T=$W/gt-$st-$$; mkdir -p "$T"; case $st in done) : > "$T/ex4-c4sim.done";; refused) : > "$T/ex4-c4sim.refused";; both) : > "$T/ex4-c4sim.done"; : > "$T/ex4-c4sim.refused";; esac
      got=$($Q "$S/bin/busybox" ash -c "TMPD=$T; PROC=$W/noproc; MTDN=7; UBI=3; SYS=$W/nosys; LOG=$W/gate.log; say() { echo \"SAY \$*\"; }; attached() { echo ATTACHED-CHECK; return 0; }; ubiattach() { echo UBIATTACH \$*; }; f() { $(cat "$W/gate.sh")
echo PAST-GATE; }; f; echo RC=\$?" 2>&1 | tr '\n' ' ')
      if [ $st = done ]; then case "$got" in *"NOT attached"*) v=DIFFERENT; R=1;; *) v=SAME;; esac
      else case "$got" in *"the sim is NOT attached (AMEND 2): $tail"*RC=1*) case "$got" in *UBIATTACH*|*PAST-GATE*|*ATTACHED-CHECK*) v=DIFFERENT; R=1;; *) v=SAME;; esac;; *) v=DIFFERENT; R=1;; esac; fi
      printf '  %-9s gate %-38s flags=%-7s -> %s\n' "$v" "${f##*/}" "$st" "$(echo "$got" | cut -c1-200)"
    done
  done
fi
echo "  work dir left (scratch): $W"
echo "RESULT: $([ $R = 0 ] && echo PASS || echo FAIL)"
exit $R
