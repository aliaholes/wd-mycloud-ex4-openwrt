#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# fetch.sh : get the four upstream files build.sh needs: download three from their publishers, check all four by sha256.
#   sh build/fetch.sh [DOWNLOAD_DIR, default ./dl]
# Nothing is redistributed in this repo: the OpenWrt images come from downloads.openwrt.org, the kernel source (for
# the device-tree include files only) from kernel.org, and WD's GPL source bundle for firmware 2.12.127 (1.1 GB; the
# stock kernel tree the loader module is built against) from WD.
#   * The two OpenWrt hashes are the lines of the release's own sha256sums file; the kernel's is in kernel.org's
#     sha256sums.asc. Check them there yourself if you like: that is the point of pinning them.
#   * WD's GPL bundle is NOT downloaded by this script. We took "WDMyCloud_EX4_GPL_v2.12.127_20181219.tar.gz"
#     (1,088,585,585 bytes) from WD's download server on Nov 16 2026, but we kept no link we could verify again when
#     this was written, and WD publishes no hash for it, so SOURCES.sha256 carries no URL for it: only the sha256 of
#     the file we built with. Get it from WD's support site (My Cloud EX4, GPL source code for firmware 2.12.127),
#     put it into the download folder under exactly that name, and run this script: it checks the file and tells
#     you if it is not the one we built against. WD's GPL source is firmware specific: no other version will do.
# A file that is already there is not downloaded again, only checked. A file with the wrong hash is refused and left
# in place under the name <file>.BAD-SHA256 for you to look at.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
DL=${1:-dl}; mkdir -p "$DL"
command -v sha256sum >/dev/null || { echo "REFUSED: sha256sum not found" >&2; exit 1; }
if command -v curl >/dev/null; then get() { curl -fL --retry 3 -o "$2" "$1"; }
elif command -v wget >/dev/null; then get() { wget -O "$2" "$1"; }
else echo "REFUSED: neither curl nor wget found" >&2; exit 1; fi
grep -v '^#' "$HERE/SOURCES.sha256" | while read -r sum name url; do
	[ -n "$sum" ] || continue
	f="$DL/$name"
	if [ ! -s "$f" ] && [ "$url" = "-" ]; then
		echo "MISSING: $name: this script has no link for it (see its header). Put the file into $DL yourself and run this again." >&2; exit 1
	fi
	if [ ! -s "$f" ]; then
		echo "fetch: $name  <-  $url"
		get "$url" "$f.part" && mv "$f.part" "$f" || { echo "FAILED: could not download $name (see the note about it in this script's header)" >&2; rm -f "$f.part"; exit 1; }
	fi
	got=$(sha256sum < "$f" | cut -d' ' -f1)
	if [ "$got" = "$sum" ]; then echo "ok:    $name  sha256 $sum"
	else mv "$f" "$f.BAD-SHA256"; echo "REFUSED: $name has sha256 $got, want $sum (kept as $name.BAD-SHA256)" >&2; exit 1; fi
done
echo "fetch: all four files are in $DL and match build/SOURCES.sha256"
