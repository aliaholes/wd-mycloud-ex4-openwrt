#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# ex4log-roundtrip.sh : the EX4 raw disk log, writer + reader, on a plain file. Off the box; touches no device.
#   sh ex4log-roundtrip.sh <native ex4log binary> <workdir (must not exist)>
# Checks: empty, too small, one snapshot (header re-parsed by independent Python), A/B slots over three snapshots,
# stale vs fresh, a torn newest slot, a damaged header, both slots damaged, a dmesg too big for the slot, a kernel
# ring that wraps between two snapshots, and THE WALL:
# not one byte outside [1 MiB, 3 MiB) changes. Born Nov 16 2026 (EX4 tooling).
set -u
X=$1; W=$2
[ -e "$W" ] && { echo "REFUSED: $W exists"; exit 1; }
mkdir -p "$W"; cd "$W" || exit 1
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS  $*"; }
no() { FAIL=$((FAIL+1)); echo "FAIL  $*"; }
want() { # name, expected rc, actual rc
	[ "$2" = "$3" ] && ok "$1 (rc $3)" || no "$1 (rc $3, wanted $2)"; }
mkimg() { python3 -I -c 'import sys; open(sys.argv[1],"wb").write(b"\xa5"*int(sys.argv[2]))' "$1" "$2"; }
outside() { python3 -I -c 'import sys,hashlib; d=open(sys.argv[1],"rb").read(); print(hashlib.md5(d[:1<<20]+d[3<<20:]).hexdigest())' "$1"; }
RUNA=00112233445566778899aabbccddeeff; RUNB=ffeeddccbbaa99887766554433221100

# T1 empty region
mkimg disk.img $((8<<20)); O0=$(outside disk.img)
$X read disk.img > t1.out 2>&1; want "T1 empty region reads as no log" 3 $?
[ "$($X read disk.img --state)" = "state none" ] && ok "T1 state none" || no "T1 state none"

# T2 too small
mkimg small.img $((2<<20))
$X read small.img > t2.out 2>&1; want "T2 reader refuses a device too small for the region" 2 $?
$X daemon --test-dev small.img --once --foreground > t2w.out 2>&1; want "T2 writer refuses a device too small for the region" 2 $?

# T3 one snapshot, independent parse
printf 'kernel line one\nkernel line two\nLAST-LINE-OF-DMESG\n' > dmesg1.txt
$X daemon --test-dev disk.img --once --foreground --run-id $RUNA --payload-file dmesg1.txt --tag T3; want "T3 writer wrote one snapshot" 0 $?
$X read disk.img --save t3.payload > t3.out 2>&1; want "T3 reader finds it" 0 $?
tail -c 19 t3.payload | grep -q 'LAST-LINE-OF-DMESG' && ok "T3 payload ends with the dmesg stand-in" || no "T3 payload tail"
grep -q "== EX4LOG T3  run $RUNA  gen 1  seq 1 " t3.payload && ok "T3 payload banner (run, gen 1, seq 1)" || no "T3 banner"
python3 -I - disk.img t3.payload $RUNA <<'PY' && ok "T3 independent Python parse: magic, header crc, payload crc, fields" || no "T3 independent parse"
import sys, struct, zlib
d = open(sys.argv[1], 'rb').read(); want = open(sys.argv[2], 'rb').read(); run = bytes.fromhex(sys.argv[3])
base = (1 << 20) + 1 * (1 << 20)          # seq 1 -> slot 1
h = d[base:base + 512]
assert h[:8] == b'EX4LOG1\n', h[:8]
ver, hl = struct.unpack('<II', h[8:16]); assert (ver, hl) == (1, 64)
assert h[16:32] == run
gen, seq, up, ln, crc = struct.unpack('<5I', h[32:52]); slot, flags = struct.unpack('<HH', h[52:56]); ss, hcrc = struct.unpack('<II', h[56:64])
assert (gen, seq, slot, flags, ss) == (1, 1, 1, 0, 1 << 20), (gen, seq, slot, flags, ss)
assert hcrc == zlib.crc32(h[:60]) & 0xffffffff
assert h[64:] == bytes(448)
p = d[base + 512:base + 512 + ln]
assert zlib.crc32(p) & 0xffffffff == crc and p == want
assert d[(1 << 20):(1 << 20) + 8] == b'\xa5' * 8      # slot 0 untouched so far
PY

# T4 three snapshots in one run: A/B slots
$X daemon --test-dev disk.img --count 3 --interval 0.05 --foreground --run-id $RUNB --payload-file dmesg1.txt --tag T4; want "T4 writer wrote three snapshots" 0 $?
$X read disk.img > t4.out 2>&1; want "T4 reader" 0 $?
grep -q "slot 0: OK  run $RUNB gen 2 seq 2 " t4.out && grep -q "slot 1: OK  run $RUNB gen 2 seq 3 " t4.out && ok "T4 slot 0 = seq 2, slot 1 = seq 3, gen went 1 -> 2" || { no "T4 slots"; cat t4.out | head -5; }
grep -q "RESULT: newest whole snapshot = slot 1, run $RUNB, gen 2, seq 3" t4.out && ok "T4 newest = seq 3" || no "T4 newest"

# T5 stale vs fresh
S1=$($X read disk.img --state); S2=$($X read disk.img --state)
[ "$S1" = "$S2" ] && [ "$S1" = "state run=$RUNB gen=2 seq=3 uptime=$(echo "$S1" | sed 's/.*uptime=//')" ] && ok "T5 no write between two reads: same state line = STALE ($S1)" || no "T5 stale"
$X daemon --test-dev disk.img --once --foreground --run-id $RUNA --payload-file dmesg1.txt --tag T5
S3=$($X read disk.img --state)
[ "$S3" != "$S1" ] && echo "$S3" | grep -q "run=$RUNA gen=3 seq=1 " && ok "T5 a new run changes the state line = FRESH, and wins although its seq (1) is lower than the old run's (3): $S3" || no "T5 fresh ($S3)"

# T6 torn newest slot (seq 1 of gen 3 sits in slot 1): flip one payload byte
cp disk.img torn.img
python3 -I -c 'import sys; f=open(sys.argv[1],"r+b"); f.seek((2<<20)+512+100); b=f.read(1); f.seek(-1,1); f.write(bytes([b[0]^0x40]))' torn.img
$X read torn.img > t6.out 2>&1; want "T6 reader still returns a log" 0 $?
grep -q "slot 1: TORN" t6.out && grep -q "RESULT: newest whole snapshot = slot 0, run $RUNB, gen 2, seq 2" t6.out && grep -q "the other slot is TORN" t6.out && ok "T6 torn newest slot: falls back to the snapshot before it and says so" || { no "T6 torn"; head -5 t6.out; }

# T7 truncated payload (tail of the newest payload zeroed, as after a cut write), then a damaged header, then both
cp disk.img trunc.img
python3 -I -c 'import sys,struct; f=open(sys.argv[1],"r+b"); f.seek((2<<20)+44); n=struct.unpack("<I",f.read(4))[0]; f.seek((2<<20)+512+n//2); f.write(bytes(n-n//2))' trunc.img
$X read trunc.img > t7a.out 2>&1; want "T7 truncated payload: reader returns the other slot" 0 $?
grep -q "slot 1: TORN" t7a.out && ok "T7 truncated payload reads as TORN" || no "T7 truncated"
python3 -I -c 'import sys; f=open(sys.argv[1],"r+b"); f.seek((1<<20)+36); f.write(b"\x09")' torn.img        # slot 0 header: seq byte changed
$X read torn.img > t7b.out 2>&1; want "T7 both slots damaged = exit 4" 4 $?
grep -q "slot 0: BAD HEADER" t7b.out && [ "$($X read torn.img --state)" = "state damaged" ] && ok "T7 bad header named, state damaged" || no "T7 bad header"

# T8 magic followed by garbage
mkimg junk.img $((8<<20))
python3 -I -c 'import sys,os; f=open(sys.argv[1],"r+b"); f.seek(1<<20); f.write(b"EX4LOG1\n"+os.urandom(504))' junk.img
$X read junk.img > t8.out 2>&1; want "T8 magic + garbage = damaged, not a log" 4 $?

# T9 a dmesg too big for the slot: cut in the middle, still valid
python3 -I -c 'import sys; open(sys.argv[1],"w").write("HEAD-OF-BOOT\n"+"".join("line %07d of a very long kernel log\n"%i for i in range(90000))+"NEWEST-END\n")' big.txt
$X daemon --test-dev disk.img --once --foreground --run-id $RUNB --payload-file big.txt --tag T9; want "T9 writer with a 3 MiB dmesg" 0 $?
$X read disk.img --save t9.payload > t9.out 2>&1; want "T9 reader" 0 $?
[ "$(stat -c %s t9.payload)" -le $(( (1<<20) - 512 )) ] && grep -q "dmesg cut to fit" t9.out && grep -q "HEAD-OF-BOOT" t9.payload && tail -c 11 t9.payload | grep -q "NEWEST-END" && grep -q "ex4log: dmesg cut here to fit the slot" t9.payload && ok "T9 cut in the middle: start of boot + newest end kept, flag set, size $(stat -c %s t9.payload) <= slot" || no "T9 cut"

# T12 the kernel ring wraps between two snapshots: the start of the boot must stay in the log
printf '<6>[    0.000000] Booting Linux on physical CPU 0x0\n<6>[    0.000000] Linux version 6.12.112 EARLY-BOOT-LINE\n<6>[    1.000000] third line of the boot, long enough to compare\n' > ring.txt
printf '<6>[  900.000000] a much later line, the ring has wrapped and the boot start is gone\n<6>[  901.000000] NEWEST-AFTER-WRAP\n' > ring.txt.2
$X daemon --test-dev disk.img --count 2 --interval 0.05 --foreground --run-id $RUNA --payload-file ring.txt --tag T12; want "T12 writer, two snapshots, ring wrapped in between" 0 $?
$X read disk.img --save t12.payload > t12.out 2>&1; want "T12 reader" 0 $?
grep -q "seq 2" t12.out && grep -q "EARLY-BOOT-LINE" t12.payload && grep -q "the kernel's log ring has wrapped" t12.payload && tail -c 18 t12.payload | grep -q "NEWEST-AFTER-WRAP" && ok "T12 after a wrap the snapshot carries the kept boot start + the ring as it is now" || no "T12 wrap"

# T10 THE WALL: nothing outside [1 MiB, 3 MiB) changed after every write above
[ "$(outside disk.img)" = "$O0" ] && ok "T10 wall: bytes outside [1 MiB, 3 MiB) are untouched after 8 snapshots" || no "T10 wall"

# T11 --save never overwrites
$X read disk.img --save t9.payload > t11.out 2>&1; want "T11 --save refuses to overwrite" 2 $?

echo "ex4log-roundtrip: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
