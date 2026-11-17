#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# run_emu.sh — re-derive the front-panel protocol from YOUR OWN copy of the stock firmware: build the xmldb stand-in
# for ARM and run emu_capture.py (WD's own up_send_ctl / up_send_daemon / up_read_daemon under qemu-arm, on a pty).
# This repo ships none of WD's files. You need, from your own unit or from WD's firmware image:
#   ROOTFS=<folder holding the unpacked stock root file system (its lib/ld-linux.so.3, lib/libc.so.6, usr/local/modules/...)>
#   RECON=<folder holding copies of the stock binaries up_send_ctl, up_send_daemon, up_read_daemon>
#   bash run_emu.sh WORKDIR [emu_capture.py flags...]
# e.g.  ROOTFS=... RECON=... bash run_emu.sh /tmp/emu1 --mcu ack --ack-frame fa3000000000fb --frame-end fb --reader \
#           --cmd "FanControl 3" --cmd "GetThemister 2" --reply fa0308020064fb
# Why you might: this repo was proven against firmware 2.12.127 only. On another firmware version, this is how to
# check that the frames in docs/MCU-PROTOCOL.md are still what YOUR firmware sends, before anything talks to the micro.
# Needs: arm-linux-gnueabi-gcc, qemu-arm (user mode), python3. Nothing here touches an EX4.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${ROOTFS:?set ROOTFS to your unpacked stock root file system}"; : "${RECON:?set RECON to a folder with up_send_ctl, up_send_daemon, up_read_daemon}"
WORK=${1:?usage: bash run_emu.sh WORKDIR [emu_capture.py flags...]}; shift
STUBDIR=$(mktemp -d)
STUB="$STUBDIR/libxmldbc.so"
arm-linux-gnueabi-gcc -shared -fPIC -O1 -marm -march=armv5te -fno-stack-protector -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
    -Wl,--hash-style=both -Wl,-soname,libxmldbc.so -o "$STUB" "$HERE/xmlstub.c"
if arm-linux-gnueabi-readelf -V "$STUB" | grep -o 'GLIBC_[0-9.]*' | sort -u | grep -v '^GLIBC_2.4$'; then
    echo "REFUSED: the stub needs a glibc newer than 2.4" >&2; exit 2; fi
exec python3 -I "$HERE/emu_capture.py" --rootfs "$ROOTFS" --recon "$RECON" --stub "$STUB" --work "$WORK" "$@"
