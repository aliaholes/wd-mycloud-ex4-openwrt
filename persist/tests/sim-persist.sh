#!/bin/bash
# sim-persist.sh (EX4 persistent system v1, FINALIZE B2): the box-side scripts (ex4-persist, ex4-markgood, ex4-svc, the
# timeout shim, 90/96 uci-defaults) run OFF the box against FAKE devices. Each case = a fresh root under $WORK; the scripts
# run as COPIES whose path-constant lines (and NAMED test-only lines, printed below) point into that root; fakes on PATH
# stand in for ubiattach / mount / mdadm / ip / uci / rpc.nfsd ... and log every call. No real device, mount or service
# is ever touched (the fakes refuse any path outside the case root).
#   bash sim-persist.sh SRC_FILES_DIR WORK SHELL     (SHELL = dash; busybox ash prefers its own mount/umount applets over
#   PATH fakes, so the device cases run under dash; busybox ash runs the timeout cases + sh -n)
set -u
SRC=$(readlink -f "$1"); WORK=$2; SH=$3
[ -e "$WORK" ] && { echo "WORK $WORK exists"; exit 2; }
mkdir -p "$WORK/bin"; WORK=$(readlink -f "$WORK"); B=$WORK/bin
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $*"; }
chk() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# ------------------------------------------------------------------ fakes (CASE = the case root, exported per case)
cat > $B/_guard <<'EOF'
g() { for a in "$@"; do case "$a" in /*) case "$a" in "$CASE"/*|"$CASE") ;; *) echo "FAKE REFUSED path outside the case: $a" >> "$CASE/calls.log"; exit 99;; esac;; esac; done; }
EOF
mk() { printf '#!/bin/bash\n. %s/_guard\necho "%s $*" >> "$CASE/calls.log"\n%s\n' "$B" "$1" "$2" > "$B/$1"; chmod 755 "$B/$1"; }
mk ubiattach 'g "$@"; [ -e "$CASE/ctl/attach_fail" ] && exit 1; mkdir -p "$CASE/sys/class/ubi/ubi3"; echo 3 > "$CASE/sys/class/ubi/ubi3/mtd_num"; touch "$CASE/dev/ubi3_0" "$CASE/dev/ubi3_1"; exit 0'
mk ubidetach '[ -e "$CASE/sys/class/ubi/ubi3" ] && mv "$CASE/sys/class/ubi/ubi3" "$CASE/detached.$$"; exit 0'
mk logger 'exit 0'
mk sync 'exit 0'
mk sleep 'exit 0'
mk modprobe 'exit 0'
mk killall 'exit 0'
mk pidof 'exit 1'
mk ip '[ -e "$CASE/ctl/ipv4" ] && echo "    inet 192.0.2.5/24 brd 192.0.2.255 scope global br-lan"; exit 0'
mk dmesg 'echo "EXT4-fs (md1): fake"; exit 0'
mk mount 'g "$@"; M=$CASE/proc/mounts
ro=rw; if [ "$1" = -t ] && [ "$2" = ubifs ]; then shift 2; [ "$1" = -o ] && { ro=$2; shift 2; }; v=${1#ubi3:}; d=$2
  [ -e "$CASE/sys/class/ubi/ubi3" ] || exit 1; [ -e "$CASE/ctl/nomount_$v" ] && exit 1; [ -d "$CASE/vol/$v" ] || exit 1
  rmdir "$d" 2>/dev/null || exit 1; ln -s "$CASE/vol/$v" "$d"; echo "ubi3:$v $d ubifs $ro 0 0" >> $M; exit 0; fi
if [ "$1" = -o ] && [ "$2" = bind ]; then s=$3; d=$4; mv "$d" "$d.under" && ln -s "$s" "$d" && echo "$s $d none rw,bind 0 0" >> $M; exit $?; fi
if [ "$1" = -o ] && [ "$2" = remount,ro ]; then sed -i "s# $3 ext4 rw# $3 ext4 ro#" $M; exit 0; fi
if [ "$1" = -t ] && [ "$2" = ext4 ]; then [ -e "$CASE/ctl/ext4_fail" ] && exit 32; d=$6; rmdir "$d" || exit 1; mkdir -p "$CASE/md1fs"; ln -s "$CASE/md1fs" "$d"; echo "/dev/md1 $d ext4 $4 0 0" >> $M; exit 0; fi
if [ "$1" = -t ] && [ "$2" = nfsd ]; then echo "nfsd $4 nfsd rw 0 0" >> $M; mkdir -p "$4"; exit 0; fi
exit 1'
mk umount 'g "$@"; M=$CASE/proc/mounts; d=$1; grep -q " $d " $M || exit 1; [ -e "$CASE/ctl/umount_busy" ] && case "$d" in *md1*) exit 1;; esac
grep -v " $d " $M > $M.t; mv $M.t $M; if [ -L "$d" ]; then rm "$d"; if [ -e "$d.under" ]; then mv "$d.under" "$d"; else mkdir "$d"; fi; fi; exit 0'
mk uci 'U=$CASE/uci; mkdir -p $U; [ "$1" = -q ] && shift; case "$1" in
get) [ -f "$U/$2" ] && cat "$U/$2" || exit 1;; set) k=${2%%=*}; v=${2#*=}; printf "%s\n" "$v" > "$U/$k";; commit) :;; esac; exit 0'
mk mdadm 'g "$@"; S=$CASE/sys/block/md1; case "$1" in
--examine) cat "$CASE/examine/${2##*/}" || exit 1;;
--assemble) [ -e "$CASE/ctl/assemble_fail" ] && exit 1; printf "md1 : active raid5 sdd2[3] sdc2[2] sdb2[1] sda2[0]\n      11720655360 blocks super 1.0 level 5, 64k chunk, algorithm 2 [4/4] [UUUU]\n" >> "$CASE/proc/mdstat"
  mkdir -p $S/md $S/queue; echo 256 > $S/md/stripe_cache_size; echo 0 > $S/md/skip_copy; echo idle > $S/md/sync_action; echo clean > $S/md/array_state; echo 128 > $S/queue/read_ahead_kb;;
--stop) [ -e "$CASE/ctl/stop_fail" ] && exit 1; sed -i "/^md1 /,+1d" "$CASE/proc/mdstat";;
--readwrite) :;; *) exit 1;; esac; exit 0'
for t in rpcbind rpc.statd rpc.mountd exportfs; do mk $t 'exit 0'; done
mk rpc.nfsd 'N=$CASE/proc/fs/nfsd; if [ "$1" = 0 ]; then echo 0 > $N/threads; exit 0; fi; c=$(cat "$CASE/ctl/nfsd_calls" 2>/dev/null || echo 0); c=$((c + 1)); echo $c > "$CASE/ctl/nfsd_calls"
[ -e "$CASE/ctl/nfsd_fail_first" ] && [ $c = 1 ] && exit 1; echo 8 > $N/threads; echo "   1: 00000000:0801 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0" >> "$CASE/proc/net/tcp"; exit 0'
mk ex4log 'exit 0'

mkroot() {      # $1 = case name
	CASE=$WORK/$1; export CASE; [ -e "$CASE" ] && { echo "case $CASE exists"; exit 2; }
	mkdir -p $CASE/{sys/class/ubi,proc/net,proc/sys/vm,proc/fs/nfsd,dev,etc/config,etc/dropbear,etc/uci-defaults,etc/ex4,etc/init.d,tmp,ex4data,ctl,vol/ex4boot,vol/ex4data/etc/config,mnt/md1,vln,examine,uci}
	printf 'dev:    size   erasesize  name\nmtd0: 00100000 00020000 "u-boot"\nmtd1: 00500000 00020000 "uImage"\nmtd2: 00500000 00020000 "ramdisk"\nmtd3: 0cd00000 00020000 "image"\n' > $CASE/proc/mtd
	: > $CASE/proc/mounts; : > $CASE/proc/mdstat; : > $CASE/calls.log
	printf '  sl  local_address rem_address   st\n' > $CASE/proc/net/tcp
	printf 'MemFree:  100000 kB\n' > $CASE/proc/meminfo; echo 0 > $CASE/proc/sys/vm/drop_caches; echo 0 > $CASE/proc/sys/vm/dirty_bytes; echo 0 > $CASE/proc/sys/vm/dirty_background_bytes
	echo 0 > $CASE/proc/fs/nfsd/threads; echo 12.34 > $CASE/proc/uptime
	printf 'kernel\n' > $CASE/vol/ex4boot/kernel.bin; printf 'seg0 00000000\n' > $CASE/vol/ex4boot/EXPECT; echo 1 > $CASE/vol/ex4boot/tries
	printf "config uhttpd main\n" > $CASE/etc/config/uhttpd; printf "config ex4 main\n" > $CASE/etc/config/ex4; chmod 600 $CASE/etc/config/ex4
	printf "x\n" > $CASE/etc/uci-defaults/95_ex4_webui
	for k in ed25519 rsa; do echo "RAMKEY-$k" > $CASE/etc/dropbear/dropbear_${k}_host_key; done
	echo RAMCRT > $CASE/etc/uhttpd.crt; echo RAMKEY > $CASE/etc/uhttpd.key; echo "fp=X names=ex4,ex4.local made=1 days=825" > $CASE/etc/ex4/cert.info
}
cpy() {         # $1 = script, $2 = name in the case: the constant lines rewritten, every other line equal (checked)
	local s=$SRC/$1 o=$CASE/$2
	sed -e "s#^SYS=/sys; PROC=/proc; DEV=/dev; ETC=/etc; TMPD=/tmp; DATA=/ex4data\$#SYS=$CASE/sys; PROC=$CASE/proc; DEV=$CASE/dev; ETC=$CASE/etc; TMPD=$CASE/tmp; DATA=$CASE/ex4data#" \
	    -e "s#^SYS=/sys; PROC=/proc; DEV=/dev; TMPD=/tmp; DATA=/ex4data\$#SYS=$CASE/sys; PROC=$CASE/proc; DEV=$CASE/dev; TMPD=$CASE/tmp; DATA=$CASE/ex4data#" \
	    -e "s#^SYS=/sys; PROC=/proc; DEV=/dev; ETC=/etc; TMPD=/tmp; MNT=/mnt/md1; MD=/dev/md1; MDN=md1\$#SYS=$CASE/sys; PROC=$CASE/proc; DEV=$CASE/dev; ETC=$CASE/etc; TMPD=$CASE/tmp; MNT=$CASE/mnt/md1; MD=$CASE/dev/md1; MDN=md1#" \
	    -e "s#^VMP=/proc/sys/vm; NFSD=/proc/fs/nfsd; VLN=/var/lib/nfs; NFSD_WAIT=30\$#VMP=$CASE/proc/sys/vm; NFSD=$CASE/proc/fs/nfsd; VLN=$CASE/vln; NFSD_WAIT=3#" \
	    -e 's#\[ -b "\$DEV/\${d}2" \]#[ -e "$DEV/${d}2" ]#' \
	    -e "s#/usr/sbin/ex4log#$B/ex4log#g; s#/usr/libexec/ex4/ex4-apply#$CASE/no-ex4-apply#g; s#/usr/sbin/ex4-selftest#$CASE/no-selftest#g" "$s" > "$o"
	local n; n=$(diff "$s" "$o" | grep -c '^<')
	echo "$n" > "$o.changed"; chmod 755 "$o"
}
X() { PATH=$B:/usr/bin:/bin "$SH" "$@"; }

echo "== shell: $SH; sources: $SRC"
for f in usr/sbin/ex4-persist usr/sbin/ex4-markgood usr/sbin/ex4-svc usr/sbin/ex4-rwbench usr/bin/timeout usr/libexec/ex4/smart-alert etc/uci-defaults/90_ex4_persist_name etc/uci-defaults/96_ex4_persist_boot etc/init.d/ex4-notgood etc/init.d/ex4-persist etc/init.d/ex4-persist-seed etc/init.d/ex4-markgood etc/init.d/ex4-svc; do
	chk "sh -n $f" "$SH" -n "$SRC/$f"
done
grep -q '\$((' "$SRC/usr/sbin/ex4-persist" && echo "note: ex4-persist uses \$(( )) (OpenWrt busybox ash has shell math; WD's stock sh does not, and never runs this)"

# ------------------------------------------------------------------ timeout shim (real sleep; both shells)
T=$SRC/usr/bin/timeout
s0=$(date +%s); PATH=/usr/bin:/bin "$SH" $T 1 sleep 5; r=$?; s1=$(date +%s)
chk "timeout 1 sleep 5 -> 124 in <= 4 s (rc $r, $((s1 - s0)) s)" test $r = 124 -a $((s1 - s0)) -le 4
PATH=/usr/bin:/bin "$SH" $T 5 true; chk "timeout 5 true -> 0" test $? = 0
PATH=/usr/bin:/bin "$SH" $T 5 sh -c 'exit 7'; chk "timeout 5 (exit 7) -> 7" test $? = 7
PATH=/usr/bin:/bin "$SH" $T x true 2>/dev/null; chk "timeout x -> 125" test $? = 125
[ "$SH" = dash ] || { echo "== $SH: device cases skipped (its mount/umount applets shadow the fakes)"; echo "RESULT $PASS pass, $FAIL fail"; [ $FAIL = 0 ]; exit; }

# ------------------------------------------------------------------ ex4-persist
mkroot p01; cpy usr/sbin/ex4-persist p; echo 1 > $CASE/vol/ex4boot/tries
X $CASE/p boot > $CASE/out 2>&1
chk "P01 empty store, attempt 1 -> MODE first, ubiattach -m 3 -d 3 -O 2048, nothing bound" sh -c "grep -q '^mode=first' $CASE/tmp/ex4-persist.state && grep -q 'ubiattach -m 3 -d 3 -O 2048' $CASE/calls.log && ! grep -q bind $CASE/proc/mounts && [ -e $CASE/etc/uci-defaults/95_ex4_webui ]"
chk "P01 tries read ro and the ro mount undone" sh -c "grep -q '^tries=1' $CASE/tmp/ex4-persist.state && grep -q 'mount -t ubifs -o ro ubi3:ex4boot' $CASE/calls.log && ! grep -q ex4boot $CASE/proc/mounts"
rm -f $CASE/etc/uci-defaults/95_ex4_webui; echo "dropbear-ecdsa" > $CASE/etc/dropbear/dropbear_ecdsa_host_key
X $CASE/p seed >> $CASE/out 2>&1
chk "P02 seed: config + keys + cert in the store, webui-done, seeded, bound, MODE persist" sh -c "cmp -s $CASE/vol/ex4data/etc/config/ex4 $CASE/etc/config.under/ex4 && [ -s $CASE/vol/ex4data/etc/dropbear/dropbear_ecdsa_host_key ] && cmp -s $CASE/vol/ex4data/etc/uhttpd.key $CASE/etc/uhttpd.key && [ -e $CASE/vol/ex4data/etc/ex4-persist/webui-done ] && [ -e $CASE/vol/ex4data/etc/ex4-persist/seeded ] && grep -q ' $CASE/etc/config none rw,bind' $CASE/proc/mounts && grep -q '^mode=persist' $CASE/tmp/ex4-persist.state"
chk "P02 seeded key mode 600" sh -c "[ \$(stat -c %a $CASE/vol/ex4data/etc/uhttpd.key) = 600 ]"
X $CASE/p seed >> $CASE/out 2>&1; chk "P03 seed again (mode persist) -> nothing to do" grep -q 'seed: nothing to do (mode persist)' $CASE/out
echo "changed" > $CASE/etc/uhttpd.crt; X $CASE/p save > $CASE/out.save 2>&1
chk "P04 save copies a changed cert only (one 'saved' line: uhttpd.crt)" sh -c "grep -q changed $CASE/vol/ex4data/etc/uhttpd.crt && [ \$(grep -c 'saved ' $CASE/out.save) = 1 ] && grep -q 'saved .*uhttpd.crt' $CASE/out.save"
# a seeded store on the next boot
SEEDED=$CASE/vol/ex4data
mkroot p05; cp -a $SEEDED/. $CASE/vol/ex4data/; echo "config uhttpd main # STORED" > $CASE/vol/ex4data/etc/config/uhttpd; echo "config newpkg" > $CASE/etc/config/newpkg
cpy usr/sbin/ex4-persist p; echo 1 > $CASE/vol/ex4boot/tries; X $CASE/p boot > $CASE/out 2>&1
chk "P05 seeded store, attempt 1 -> MODE persist, stored config bound" sh -c "grep -q '^mode=persist' $CASE/tmp/ex4-persist.state && grep -q STORED $CASE/etc/config/uhttpd"
chk "P05 the image's NEW config file merged into the store, existing ones not overwritten" sh -c "[ -e $CASE/vol/ex4data/etc/config/newpkg ] && grep -q STORED $CASE/vol/ex4data/etc/config/uhttpd"
chk "P05 host keys + cert restored from the store (RAM ones replaced), key 600" sh -c "grep -q dropbear-ecdsa $CASE/etc/dropbear/dropbear_ecdsa_host_key && grep -q changed $CASE/etc/uhttpd.crt && [ \$(stat -c %a $CASE/etc/uhttpd.key) = 600 ]"
chk "P05 95_ex4_webui removed (first-boot script; would un-claim)" test ! -e $CASE/etc/uci-defaults/95_ex4_webui
mkroot p06; cp -a $SEEDED/. $CASE/vol/ex4data/; cpy usr/sbin/ex4-persist p; echo 2 > $CASE/vol/ex4boot/tries; X $CASE/p boot > $CASE/out 2>&1
chk "P06 seeded, attempt 2 -> MODE safe: nothing bound, nothing restored, flag file, 95 stays" sh -c "grep -q '^mode=safe' $CASE/tmp/ex4-persist.state && ! grep -q bind $CASE/proc/mounts && grep -q RAMCRT $CASE/etc/uhttpd.crt && [ -e $CASE/tmp/ex4-safe-config ] && [ -e $CASE/etc/uci-defaults/95_ex4_webui ]"
X $CASE/p seed >> $CASE/out 2>&1; X $CASE/p save >> $CASE/out 2>&1
chk "P06 safe: seed + save write NOTHING to the store" sh -c "grep -q 'seed: nothing to do (mode safe)' $CASE/out && ! grep -q 'saved ' $CASE/out && grep -q changed $CASE/vol/ex4data/etc/uhttpd.crt"
mkroot p07; cpy usr/sbin/ex4-persist p; touch $CASE/ctl/attach_fail; X $CASE/p boot > $CASE/out 2>&1
chk "P07 ubiattach fails -> MODE ram, boot goes on (rc 0)" sh -c "grep -q '^mode=ram' $CASE/tmp/ex4-persist.state && ! grep -q 'mode=persist\|mode=first' $CASE/tmp/ex4-persist.state"
mkroot p08; cpy usr/sbin/ex4-persist p; sed -i 's/"image"/"imagex"/' $CASE/proc/mtd; X $CASE/p boot > $CASE/out 2>&1
chk "P08 mtd3 not named image -> MODE ram, no ubiattach call" sh -c "grep -q '^mode=ram' $CASE/tmp/ex4-persist.state && ! grep -q ubiattach $CASE/calls.log"
mkroot p09; cpy usr/sbin/ex4-persist p; touch $CASE/ctl/nomount_ex4data; X $CASE/p boot > $CASE/out 2>&1
chk "P09 ex4data does not mount -> MODE ram" sh -c "grep -q '^mode=ram' $CASE/tmp/ex4-persist.state && ! grep -q '^data=yes' $CASE/tmp/ex4-persist.state"
mkroot p10; cpy usr/sbin/ex4-persist p; echo garbage > $CASE/vol/ex4boot/tries; X $CASE/p boot > $CASE/out 2>&1
chk "P10 tries unreadable text -> taken as 0 -> MODE first" sh -c "grep -q '^tries=0' $CASE/tmp/ex4-persist.state && grep -q '^mode=first' $CASE/tmp/ex4-persist.state"
mkroot p11; cp -a $SEEDED/. $CASE/vol/ex4data/; cpy usr/sbin/ex4-persist p; X $CASE/p boot > $CASE/out 2>&1; X $CASE/p stop >> $CASE/out 2>&1
chk "P11 stop: bind + ex4data unmounted, UBI detached" sh -c "! grep -q . $CASE/proc/mounts && [ ! -e $CASE/sys/class/ubi/ubi3 ] && [ -d $CASE/etc/config ] && [ ! -L $CASE/etc/config ]"

# ------------------------------------------------------------------ ex4-markgood
mkroot m01; cpy usr/sbin/ex4-markgood mg; mkdir -p $CASE/sys/class/ubi/ubi3; echo 3 > $CASE/sys/class/ubi/ubi3/mtd_num; echo 2 > $CASE/vol/ex4boot/tries
X $CASE/mg mark > $CASE/out 2>&1
chk "M01 mark: tries 2 -> 0, read back, ex4boot unmounted, /tmp/ex4-good" sh -c "[ \$(cat $CASE/vol/ex4boot/tries) = 0 ] && [ -e $CASE/tmp/ex4-good ] && ! grep -q ex4boot $CASE/proc/mounts && [ ! -e $CASE/vol/ex4boot/tries.new ]"
mkroot m02; cpy usr/sbin/ex4-markgood mg; echo 1 > $CASE/vol/ex4boot/tries; rm $CASE/vol/ex4boot/kernel.bin; X $CASE/mg mark > $CASE/out 2>&1
chk "M02 ex4boot without kernel.bin -> NOT marked, tries untouched, attach done by markgood itself" sh -c "[ \$(cat $CASE/vol/ex4boot/tries) = 1 ] && [ ! -e $CASE/tmp/ex4-good ] && grep -q 'ubiattach -m 3 -d 3 -O 2048' $CASE/calls.log"
mkroot m03; cpy usr/sbin/ex4-markgood mg; touch $CASE/ctl/attach_fail; X $CASE/mg mark > $CASE/out 2>&1; r=$?
chk "M03 attach fails -> rc 1, NOT marked" sh -c "[ $r = 1 ] && [ ! -e $CASE/tmp/ex4-good ]"
mkroot m04; cpy usr/sbin/ex4-markgood mg; mkdir -p $CASE/sys/class/ubi/ubi3; echo 3 > $CASE/sys/class/ubi/ubi3/mtd_num; touch $CASE/ctl/ipv4
echo "   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0" >> $CASE/proc/net/tcp
mkdir -p $CASE/ex4data; echo "ubi3:ex4data $CASE/ex4data ubifs rw 0 0" >> $CASE/proc/mounts
X $CASE/mg run > $CASE/out 2>&1
chk "M04 run: br-lan IPv4 + :22 LISTEN -> marked, boots.log line in ex4data" sh -c "[ -e $CASE/tmp/ex4-good ] && grep -q 'good tries_was=1' $CASE/ex4data/var/boots.log"
mkroot m05; cpy usr/sbin/ex4-markgood mg; touch $CASE/ctl/ipv4; echo "   0: 00000000:0016 00000000:0000 01 00000000:00000000 00:00000000 00000000     0        0 1 1 0" >> $CASE/proc/net/tcp
( PATH=$B:/usr/bin:/bin timeout 5 dash -c ". /dev/null; $CASE/mg run" > $CASE/out 2>&1 ); r=$?
chk "M05 :22 ESTABLISHED only (not LISTEN) -> never marked (still waiting at 5 s)" sh -c "[ $r = 124 ] && [ ! -e $CASE/tmp/ex4-good ]"

# ------------------------------------------------------------------ ex4-svc (wall, start, stop)
EX='          Magic : a92b4efc
        Version : 1.0
    Feature Map : 0x1
     Array UUID : 11111111:22222222:33333333:44444444
     Raid Level : raid5
   Raid Devices : 4
     Chunk Size : 64K
         Layout : left-symmetric
          State : clean
         Events : 4242
    Array State : AAAA ("A" == active, "." == missing, "R" == replacing)'
svcroot() {     # $1 = case; members sda..sdd behind ata hosts; examine text = EX with sed $2 applied to member $3 (or all)
	mkroot $1; cpy usr/sbin/ex4-svc svc
	n=0; for d in sda sdb sdc sdd; do n=$((n + 1))
		mkdir -p $CASE/devices/pci0/ata$n/host0/target/$d $CASE/sys/block/$d/queue; ln -s $CASE/devices/pci0/ata$n/host0/target/$d $CASE/sys/block/$d/device
		echo 128 > $CASE/sys/block/$d/queue/read_ahead_kb; touch $CASE/dev/${d}2
		if [ -z "${3:-}" ] || [ "$3" = $d ]; then echo "$EX" | sed "${2:-}" > $CASE/examine/${d}2; else echo "$EX" > $CASE/examine/${d}2; fi
	done
	mkdir -p $CASE/etc/init.d; printf '#!/bin/sh\necho "smartd $*" >> "%s/calls.log"\n' "$CASE" > $CASE/etc/init.d/smartd; chmod 755 $CASE/etc/init.d/smartd
}
W() { X $CASE/svc check > $CASE/out 2>&1; }
svcroot s01; W; chk "S01 wall: clean 1.0 + bitmap -> passes, no setro, no write call" sh -c "grep -q 'wall passed: 4 members' $CASE/out && ! grep -qE 'setro|--assemble' $CASE/calls.log"
svcroot s02 's/State : clean/State : active/'; W; chk "S02 wall: dirty (active) WITH bitmap -> passes, says DIRTY" grep -q 'DIRTY on 4 member' $CASE/out
svcroot s03 's/State : clean/State : active/; s/Feature Map : 0x1/Feature Map : 0x0/'; W; chk "S03 wall: dirty WITHOUT bitmap -> REFUSED" grep -q "REFUSED.*a full resync is a person's call" $CASE/out
svcroot s04 's/Feature Map : 0x1/Feature Map : 0x3/' sdc; W; chk "S04 wall: a member being rebuilt (0x3) -> REFUSED" grep -q 'REFUSED: .*sdc2: Feature Map .0x3' $CASE/out
svcroot s05 's/    Array State/  Recovery Offset : 123 sectors\n    Array State/' sdb; W; chk "S05 wall: Recovery Offset line -> REFUSED" grep -q 'REFUSED: .*unfinished rebuild' $CASE/out
svcroot s06 's/Array State : AAAA/Array State : AAA./' sdd; W; chk "S06 wall: Array State AAA. -> REFUSED" grep -q "REFUSED: .*Array State 'AAA\." $CASE/out
svcroot s07 's/Events : 4242/Events : 4241/' sda; W; chk "S07 wall: events differ -> REFUSED" grep -q 'REFUSED: .*events' $CASE/out
svcroot s08 's/Version : 1.0/Version : 1.2/; s/Feature Map : 0x1/Feature Map : 0x9/'; W; chk "S08 wall: 1.2 + bitmap + bad-block log (E1 shape) -> passes" grep -q 'wall passed' $CASE/out
svcroot s09 's/Version : 1.0/Version : 0.90/'; W; chk "S09 wall: super 0.90 -> REFUSED" grep -q "REFUSED: .*superblock version '0.90'" $CASE/out
svcroot s10; rm $CASE/sys/block/sdd/device; ln -s $CASE/devices/usb1/x $CASE/sys/block/sdd/device; W
chk "S10 wall: a member on USB is not a member -> found 3, REFUSED" grep -q 'REFUSED: found 3 SATA' $CASE/out
svcroot s11; X $CASE/svc start > $CASE/out 2>&1
K=$CASE/sys/block/md1
chk "S11 start: assemble (no --run/--force), knobs read back (sc 1024, skip 1, ra 1024 md1 + 4 members), dirty_bytes 64M" sh -c "grep -q 'mdadm --assemble' $CASE/calls.log && ! grep -qE -- '--run|--force' $CASE/calls.log && [ \$(cat $K/md/stripe_cache_size) = 1024 ] && [ \$(cat $K/md/skip_copy) = 1 ] && [ \$(cat $K/queue/read_ahead_kb) = 1024 ] && [ \$(cat $CASE/sys/block/sdc/queue/read_ahead_kb) = 1024 ] && [ \$(cat $CASE/proc/sys/vm/dirty_bytes) = 67108864 ]"
chk "S11 start: ext4 rw with the bench's options, rw-active file, smartd started, no exports -> NFS not started" sh -c "grep -q ' $CASE/mnt/md1 ext4 rw,noatime,data=ordered,barrier=1,errors=remount-ro,noinit_itable,stripe=128 ' $CASE/proc/mounts && [ -e $CASE/tmp/ex4-rw-active ] && grep -q 'smartd start' $CASE/calls.log && grep -q 'NFS not started' $CASE/out && ! grep -q rpc.nfsd $CASE/calls.log"
a=$(grep -n 'wr $SYS/block/$MDN/md/skip_copy' $SRC/usr/sbin/ex4-svc | cut -d: -f1); m=$(grep -n 'mount -t ext4 -o' $SRC/usr/sbin/ex4-svc | cut -d: -f1)
chk "S11 skip_copy written BEFORE the ext4 mount (script lines $a < $m) and reads 1 while mounted" sh -c "[ -n '$a' ] && [ -n '$m' ] && [ $a -lt $m ] && [ \$(cat $K/md/skip_copy) = 1 ]"
X $CASE/svc stop --for-reboot >> $CASE/out 2>&1; r=$?
chk "S12 stop: rc 0 SAFE, unmounted, mdadm --stop, rw-active gone" sh -c "[ $r = 0 ] && ! grep -q md1 $CASE/proc/mounts && grep -q 'mdadm --stop' $CASE/calls.log && [ ! -e $CASE/tmp/ex4-rw-active ] && ! grep -q '^md1 ' $CASE/proc/mdstat"
svcroot s13; printf '/mnt/md1/Backups 192.0.2.10(rw,sync,no_subtree_check)\n' > $CASE/etc/exports; touch $CASE/ctl/nfsd_fail_first; X $CASE/svc start > $CASE/out 2>&1
chk "S13 NFS: drop_caches before EVERY rpc.nfsd (2 starts, first fails), v3 only TCP only (-N 4 -U 8), up on try 2" sh -c "[ \$(grep -c 'rpc.nfsd -N 4 -U 8' $CASE/calls.log) = 2 ] && [ \$(grep -c 'nfsd prep: sync + drop_caches' $CASE/out) = 2 ] && grep -q 'NFSv3 up (try 2' $CASE/out && [ \$(cat $CASE/proc/sys/vm/drop_caches) = 3 ]"
chk "S13 statd 32778/32779, mountd 32780, exportfs -ra" sh -c "grep -q 'rpc.statd -p 32778 -o 32779' $CASE/calls.log && grep -q 'rpc.mountd -p 32780' $CASE/calls.log && grep -q 'exportfs -ra' $CASE/calls.log"
svcroot s14; touch $CASE/ctl/ext4_fail; X $CASE/svc start > $CASE/out 2>&1; r=$?
chk "S14 ext4 mount fails -> md1 stopped, rw-active removed, rc 1" sh -c "[ $r = 1 ] && grep -q 'mdadm --stop' $CASE/calls.log && [ ! -e $CASE/tmp/ex4-rw-active ]"
svcroot s15; X $CASE/svc start > $CASE/out 2>&1; touch $CASE/ctl/umount_busy; X $CASE/svc stop >> $CASE/out 2>&1; r=$?
chk "S15 stop with a busy mount -> rc 3, md1 NOT stopped, remounted ro" sh -c "[ $r = 3 ] && ! grep -q 'mdadm --stop' $CASE/calls.log && grep -q ' ext4 ro' $CASE/proc/mounts"
svcroot s16; echo 0 > $CASE/uci/ex4svc.main.enabled; X $CASE/svc start > $CASE/out 2>&1
chk "S16 ex4svc.main.enabled=0 -> nothing assembled" sh -c "grep -q 'md1 left alone' $CASE/out && ! grep -q 'mdadm' $CASE/calls.log"
svcroot s17; echo 99999 > $CASE/uci/ex4svc.main.stripe_cache; X $CASE/svc start > $CASE/out 2>&1
chk "S17 stripe_cache 99999 -> REFUSED before any mdadm call" sh -c "grep -q 'REFUSED: stripe_cache 99999' $CASE/out && ! grep -q mdadm $CASE/calls.log"

# ------------------------------------------------------------------ the shim + 90 uci-default
mkroot r01; sed "s#/usr/sbin/ex4-svc#$CASE/fakesvc#" $SRC/usr/sbin/ex4-rwbench > $CASE/rwb; printf '#!/bin/sh\necho "svc $*" >> %s/calls.log\n' "$CASE" > $CASE/fakesvc; chmod 755 $CASE/rwb $CASE/fakesvc
X $CASE/rwb stop --for-reboot; chk "R01 ex4-rwbench shim: stop --for-reboot -> ex4-svc stop --for-reboot" grep -q 'svc stop --for-reboot' $CASE/calls.log
X $CASE/rwb up 2>/dev/null; chk "R02 ex4-rwbench shim: anything else -> 64, ex4-svc not called" sh -c "[ $? = 64 ] && [ \$(grep -c svc $CASE/calls.log) = 1 ]"
mkroot u01; sed "s#/proc/sys/kernel/hostname#$CASE/hostname#" $SRC/etc/uci-defaults/90_ex4_persist_name > $CASE/u90; X $CASE/u90
chk "U01 90: no configured name -> 'ex4' in uci AND the kernel name, before 95 makes the cert" sh -c "[ \"\$(cat $CASE/hostname)\" = ex4 ] && [ \"\$(cat '$CASE/uci/system.@system[0].hostname')\" = ex4 ]"
mkroot u02; sed "s#/proc/sys/kernel/hostname#$CASE/hostname#" $SRC/etc/uci-defaults/90_ex4_persist_name > $CASE/u90; echo vault > "$CASE/uci/system.@system[0].hostname"; X $CASE/u90
chk "U02 90: a stored name ('vault') is kept and given to the kernel" sh -c "[ \"\$(cat $CASE/hostname)\" = vault ] && [ \"\$(cat '$CASE/uci/system.@system[0].hostname')\" = vault ]"

echo "== copies: lines changed vs the shipped scripts (path constants + named test lines only):"
for c in p01/p:usr/sbin/ex4-persist m01/mg:usr/sbin/ex4-markgood s11/svc:usr/sbin/ex4-svc; do
	echo "  ${c#*:}: $(cat $WORK/${c%%:*}.changed) line(s):"; diff $SRC/${c#*:} $WORK/${c%%:*} | grep '^<' | sed 's/^< /      was: /' | cut -c1-150
done
grep -h 'FAKE REFUSED' $WORK/*/calls.log && bad "a fake was handed a path outside its case" || ok "no fake was ever handed a path outside its case root"
echo "RESULT $PASS pass, $FAIL fail"
[ $FAIL = 0 ]
