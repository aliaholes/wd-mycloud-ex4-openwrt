#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# emu.sh : the web interface's REAL backend, off the box. OpenWrt 25.12.6's own ARM binaries (ubusd, rpcd with
# rpcd-mod-ucode, uhttpd with uhttpd-mod-ubus and TLS, ucode, uci, px5g) run under qemu-arm against a COPY of the
# image's root file system. Into that copy go: everything webui/FILES lists (the page, ex4.uc, the ACLs, the
# helper, the first-boot script), and the sample box of tests/webui/truth.py as files (/proc, /sys, /tmp ...).
# Then the command after `--` runs with the three addresses in its environment, and everything is stopped.
#
#   bash tests/webui/emu/emu.sh SRC_ROOTFS WORKDIR [--port N] [--scenario NAME] -- COMMAND [ARGS...]
#     SRC_ROOTFS   build.sh's work/ix4-rootfs (only read)        WORKDIR   scratch, must not exist
#     in COMMAND's environment:  EX4_EMU_URL (http)  EX4_EMU_URLS (https, the px5g certificate)  EX4_EMU_ROOT
#                                EX4_EMU_CALLS (every command the helper ran: name, argv, stdin)
#
# What is real and what is not:
#   real   rpcd, its session and ACL code, crypt(); uhttpd and its /ubus door; ex4.uc; ex4-apply (ucode); uci;
#          the first-boot script 95_ex4_webui; px5g making the certificate; uhttpd serving it over TLS
#   stub   the programs the helper would start on the box (init scripts, smbpasswd, exportfs, msmtp, smartctl, df,
#          logread, reboot, halt, umount, mdadm ...): each one only writes its name, arguments and stdin to
#          EX4_EMU_CALLS. So the test proves WHAT the helper asks for, not that Samba does it.
#   shim   two preloads the build host needs (mkdirstub.c into ubusd, statstub.c into rpcd; each file says why)
# Timings under qemu-user are not the box's and are never reported. Nothing here touches an EX4. Never run as root.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); TOP=$(cd "$HERE/../../.." && pwd); WEBUI=$TOP/webui
SRC=${1:?usage: emu.sh SRC_ROOTFS WORKDIR [--port N] [--scenario NAME] -- COMMAND}; W=${2:?}; shift 2
PORT=18480; SCN=trial
while [ $# -gt 0 ]; do case "$1" in --port) PORT=$2; shift 2;; --scenario) SCN=$2; shift 2;; --) shift; break;; *) echo "emu: unknown option $1" >&2; exit 64;; esac; done
[ "$(id -u)" != 0 ] || { echo "REFUSED: never run the test harness as root" >&2; exit 1; }
[ -x "$SRC/sbin/rpcd" ] || { echo "REFUSED: $SRC is not an OpenWrt root file system (no sbin/rpcd)" >&2; exit 1; }
[ -e "$W" ] && { echo "REFUSED: $W exists" >&2; exit 1; }
[ -s "$WEBUI/dist/index.html" ] || { echo "REFUSED: build the page first: python3 webui/build.py" >&2; exit 1; }
for t in qemu-arm arm-linux-gnueabi-gcc python3 curl; do command -v $t >/dev/null || { echo "SKIP: $t is not installed" >&2; exit 77; }; done
mkdir -p "$W" && W=$(cd "$W" && pwd) && cp -a "$SRC" "$W/rootfs" || exit 2
R=$W/rootfs; S=$W/ubus.sock; ST=$W/stubs; CALLS=$W/calls.log; : > "$CALLS"; mkdir -p "$ST" "$R/tmp/run" "$R/etc/rc.d" "$R/etc/ex4"   # /var is a link to tmp in the image: /var/run = tmp/run, as on a booted box
chmod -R u+w "$R"
CC="arm-linux-gnueabi-gcc -shared -fPIC -Os -marm -march=armv5te -nostdlib -fno-stack-protector -fomit-frame-pointer -fno-builtin -Wl,--hash-style=both"
$CC -o "$W/mkdirstub.so" "$HERE/mkdirstub.c" && $CC -DPREFIX="\"$R\"" -o "$W/statstub.so" "$HERE/statstub.c" -lgcc || { echo "emu: the shims did not build" >&2; exit 2; }

# ---- the interface's files, from the same list the overlay builder uses
grep -v '^#' "$WEBUI/FILES" | while IFS=$'\t' read -r src dst mode; do
	[ -n "$src" ] || continue
	mkdir -p "$R$(dirname "$dst")" && cp "$WEBUI/$src" "$R$dst" && chmod "$mode" "$R$dst" || { echo "emu: cannot install $src" >&2; exit 2; }
done
# rpcd starts the helper by its path; under qemu-user that exec lands on the build host, so the path holds a
# wrapper that runs the REAL helper in the image's own ucode
mv "$R/usr/libexec/ex4/ex4-apply" "$R/usr/libexec/ex4/ex4-apply.uc"
cat > "$R/usr/libexec/ex4/ex4-apply" <<EOF
#!/bin/sh
export EX4_ROOT="$R" EX4_NET_WAIT=\${EX4_NET_WAIT:-6} PATH="$ST:/usr/bin:/bin"
unset LD_PRELOAD
exec qemu-arm -L "$R" "$R/usr/bin/ucode" -L "$R/usr/lib/ucode/*.so" "$R/usr/libexec/ex4/ex4-apply.uc" "\$@"
EOF
chmod 755 "$R/usr/libexec/ex4/ex4-apply"

# ---- stubs: what the helper would start on the box. Name, arguments, and stdin where the real one reads it.
stub() {	# NAME [SHELL-BEFORE-CLOSING] [LAST-LINE]: writes "NAME [arg] [arg]..." (+ what SHELL adds) to the calls log
	{ echo '#!/bin/sh'
	  echo "{ printf '%s' '$1'; for a in \"\$@\"; do printf ' [%s]' \"\$a\"; done; echo; ${2:-:;} } >> '$CALLS'"
	  echo "${3:-exit 0}"; } > "$ST/$1"; chmod 755 "$ST/$1"
}
for n in exportfs reboot halt sync umount mdadm logread; do stub $n; done
stub smbpasswd "sed 's/^/  stdin: /';"
stub ksmbd.adduser "sed 's/^/  stdin: /';"
stub msmtp "sed 's/^/  stdin: /';" "[ -e '$W/msmtp.fail' ] && exit 75; exit 0"
printf '#!/bin/sh\necho "Filesystem 1K-blocks Used Available Use%%%% Mounted on"\necho "/dev/md1 11601318912 1782580 11599536332 1%%%% /mnt/md1"\n' > "$ST/df"; chmod 755 "$ST/df"
cat > "$ST/smartctl" <<EOF
#!/bin/sh
# the drive named last; the counters are those of tests/webui/truth.py
for d; do :; done; d=\${d#/dev/}
echo "smartctl [\$*]" >> "$CALLS"
python3 -I - "\$d" "$R" <<'PY'
import json, sys
s = json.load(open(sys.argv[2] + '/tmp/ex4/smart-seed/' + sys.argv[1] + '.json'))
print(json.dumps({'model_name': s['model'], 'serial_number': s['serial'], 'smart_status': {'passed': s['passed']},
    'ata_smart_attributes': {'table': [{'id': int(k), 'raw': {'value': v}} for k, v in s['a'].items()]}}))
PY
EOF
chmod 755 "$ST/smartctl"
# the image's own uci and ubus; uci keeps its scratch in the work folder (-P), not in the build host's /tmp
printf '#!/bin/sh\nexec qemu-arm -L "%s" "%s/sbin/uci" -P "%s/uci-save" "$@"\n' "$R" "$R" "$W" > "$ST/uci"
printf '#!/bin/sh\nexec qemu-arm -L "%s" "%s/bin/ubus" -s "%s" "$@"\n' "$R" "$R" "$S" > "$ST/ubus"
printf '#!/bin/sh\nexec qemu-arm -L "%s" "%s/usr/sbin/px5g" "$@"\n' "$R" "$R" > "$ST/px5g"
chmod 755 "$ST/uci" "$ST/ubus" "$ST/px5g"
# init scripts: enable/disable make or remove the rc.d link, like the real ones; everything is recorded
for n in samba4 nfsd wsdd2 avahi-daemon dropbear sysntpd network system uhttpd cron rpcd; do
	cat > "$R/etc/init.d/$n" <<EOF
#!/bin/sh
echo "init.d/$n [\$*]" >> "$CALLS"
case "\$1" in enable) : > "$R/etc/rc.d/S50$n";; disable) unlink "$R/etc/rc.d/S50$n" 2>/dev/null;; esac
exit 0
EOF
	chmod 755 "$R/etc/init.d/$n"
done
: > "$R/etc/rc.d/S50dropbear"; : > "$R/etc/rc.d/S50sysntpd"

# ---- the sample box, and the config files a booted system has
python3 -I "$HERE/../truth.py" --root "$R" --scenario "$SCN" || exit 2
mkdir -p "$R/tmp/ex4/smart-seed" && cp "$R"/tmp/ex4/smart/*.json "$R/tmp/ex4/smart-seed/"
printf "config system\n\toption hostname 'ex4'\n\toption timezone 'UTC'\n\toption zonename 'UTC'\n" > "$R/etc/config/system"
printf "config interface 'loopback'\n\toption device 'lo'\n\toption proto 'static'\n\toption ipaddr '127.0.0.1'\n\toption netmask '255.0.0.0'\n\nconfig device\n\toption name 'br-lan'\n\toption type 'bridge'\n\tlist ports 'eth0'\n\tlist ports 'eth1'\n\nconfig interface 'lan'\n\toption device 'br-lan'\n\toption proto 'dhcp'\n" > "$R/etc/config/network"

# ---- first boot, the real script (uci is the image's own, through the wrapper in $ST)
EX4_ROOT="$R" PATH="$ST:$PATH" sh "$R/etc/uci-defaults/95_ex4_webui" > "$W/uci-defaults.log" 2>&1; echo "rc=$?" >> "$W/uci-defaults.log"

# ---- the three daemons
PIDS=""; trap 'kill $PIDS 2>/dev/null; wait 2>/dev/null' EXIT
qemu-arm -E LD_PRELOAD="$W/mkdirstub.so" -L "$R" "$R/sbin/ubusd" -s "$S" > "$W/ubusd.log" 2>&1 & PIDS="$PIDS $!"; sleep 1
qemu-arm -E LD_PRELOAD="$W/statstub.so" -E EX4_ROOT="$R" -E EX4_UBUS_SOCK="$S" -L "$R" "$R/sbin/rpcd" -s "$S" -t 30 > "$W/rpcd.log" 2>&1 & PIDS="$PIDS $!"; RPCD=$!; sleep 4
TLS=""; [ -s "$R/etc/uhttpd.crt" ] && [ -s "$R/etc/uhttpd.key" ] && TLS="-s 127.0.0.1:$((PORT + 1)) -C $R/etc/uhttpd.crt -K $R/etc/uhttpd.key"
qemu-arm -L "$R" "$R/usr/sbin/uhttpd" -f -h "$R/www-ex4" -p 127.0.0.1:$PORT $TLS -u /ubus -U "$S" -n 3 > "$W/uhttpd.log" 2>&1 & PIDS="$PIDS $!"; sleep 2
if ! qemu-arm -L "$R" "$R/bin/ubus" -s "$S" list ex4 >/dev/null 2>&1; then echo "emu: rpcd did not register the ex4 object:" >&2; cat "$W/rpcd.log" >&2; exit 2; fi

export EX4_EMU_URL="http://127.0.0.1:$PORT" EX4_EMU_URLS="https://127.0.0.1:$((PORT + 1))" EX4_EMU_ROOT="$R" EX4_EMU_CALLS="$CALLS" EX4_EMU_WORK="$W" EX4_EMU_RPCD=$RPCD
[ -n "$TLS" ] || export EX4_EMU_URLS=""
"$@"; RC=$?
echo "emu: children of rpcd alive at the end: $(ps --ppid $RPCD -o pid= 2>/dev/null | wc -l)"
[ -s "$W/rpcd.log" ] && { echo "emu: rpcd's own log:"; tail -8 "$W/rpcd.log"; }
exit $RC
