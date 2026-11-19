# Updates: how this system stays patched

Three parts, each small enough to read in one sitting:

| Part | Where | What it does |
|---|---|---|
| **Releases** | `update/mkrelease.py` (build box) | turns one finished build into a signed, versioned release: payload tarball, CycloneDX SBOM, and a signed text manifest (`RELEASE` + `RELEASE.sig`) |
| **The box** | `update/box/ex4-update` (in the image as `/usr/sbin/ex4-update`) | `check` / `verify` / `stage`: fetches a release, checks the signature and hashes before anything else, refuses everything else. Never installs |
| **The watch** | `update/cvewatch.py` (any host) | reads a signed release's SBOM and asks OSV.dev which of its packages have known holes, so you know what needs a rebuild |

The trust anchor is one ed25519 key. Its public half is `update/keys/ex4-release.pub` (key number `cd0c35ab50a98c3c`),
and the image carries it as `/etc/ex4-update/keys/cd0c35ab50a98c3c`. Its private half never enters this repository.
The box trusts what that key signs, and nothing else. HTTPS, the download host and GitHub are not trusted: a release
that is not signed by that key is refused wherever it came from.

**What v9 adds** (bundle-v9 is the first image that carries all of this, and its release is the first one signed):

- **An expiry.** Every RELEASE says `not-after`. A box refuses an expired release, even one with the serial it
  already runs, so someone who blocks the release address cannot keep a box saying "up to date" forever.
- **Plain http is refused** unless `--insecure-http` is typed.
- **A key-rotation path.** A RELEASE may name one `successor` key, vouched for by the key that signed it.
- **No official package feeds in the image.** Packages reach this box only inside our own signed releases (below).
- **The watch dedupes.** The same set of findings the next morning is "no new finding", not a new card.

## 1. Releases

```
python3 -I update/mkrelease.py release --work W --bundle W/out/bundle-v9 --version 2026.11.17-v9 --serial 2026111702 \
    --channel trial --key $BUILD/keys/ex4-release.sec --pub update/keys/ex4-release.pub \
    --usign W/openwrt/staging_dir/host/bin/usign --out releases/2026.11.17-v9 [--valid-days 90] [--successor NEXT.pub]
```

Out comes a folder of four files, which is the whole release, ready to upload as-is:

- `RELEASE`: plain text, at most 64 KiB. Its lines: `board`, `version`, `serial`, `channel`, `built`, `not-after`
  (v9: the expiry, as epoch seconds and as ISO time; the box checks both say the same moment), `openwrt`, and
  `kernel` (with its vermagic). After those come the `payload` sha256 + size, the `sbom` sha256 + size, at most one
  `successor` line (v9, below), one `file` line per file inside the payload, and `end`.
- `RELEASE.sig`: OpenWrt's own `usign -S` over RELEASE. mkrelease checks the signature twice before it says done:
  once with `usign -V` and once with `update/usignpy.py`, a separate ed25519 verifier.
- `ex4-<version>.tar`: the bundle, deterministic (sorted, mtime 0, uid 0). The same inputs give the same bytes.
- `sbom.cdx.json`: CycloneDX 1.4, one component per installed package (the image manifest's name and version).
  Each component has the sha256 of its built `.apk` and the source tarball it was built from, with that tarball's
  sha256. That hash is checked against the hash pinned in the package's own Makefile (`PKG_HASH` /
  `PKG_MIRROR_HASH`; for the kernel, `LINUX_KERNEL_HASH`). Packages built from in-tree sources say so. This
  repository's own programs are listed too. mkrelease refuses to write an SBOM with any hole in it.

**The serial is the downgrade wall.** The box takes only a serial greater than the one it runs, so an old signed
release, with its old holes, can never be pushed back in. Use `YYYYMMDDNN`.

**The expiry is the freeze wall (v9).** The serial alone cannot catch a box that is simply never shown anything newer:
`check` would say "up to date" off the same old, validly signed RELEASE forever. So every RELEASE vouches for itself
for a limited time: `not-after = built + --valid-days` (default 90, at most 366; the box refuses more than 400).
`ex4-update` refuses a release whose `not-after` has passed, and does so BEFORE it compares serials, so an expired
release can never make the box say "up to date". It also refuses when the box's clock reads earlier than the
release's `built` time ("set the clock first"), because an expiry cannot be judged on a clock that was never set
(the trial sets its clock from the panel micro at boot). **Renewal** = release the same bundle again with a bigger
serial (a new `not-after`); any newer release is accepted. The web page shows "Release good until" after a good
check and, after a refusal, the words "EXPIRED on <date> ... the release address may be stale, or something is
holding newer releases back".

**The key** (`usign -G`): it lives only on the build box, in `$BUILD/keys/ex4-release.sec`, mode 0600, in a
0700 folder. mkrelease refuses a key that is not 0600, a key inside this repository, and (unless `--allow-test-key`,
which tests use) any key whose public half is not `update/keys/ex4-release.pub`. A release signed by a test key always
says `channel test`, and no image is ever built as channel test.
If the key is lost, no new release can be made for the boxes already out there. If it leaks, anyone can sign
releases for them. Back up the `.sec` file offline: a copy on paper or on a USB stick in a drawer.

**Key rotation (v9).** To move to a new key without reflashing by hand: make the new pair (`usign -G`), then sign one
release with the CURRENT key and `--successor NEW.pub`. That RELEASE carries `successor <key number> <public key>`.
A box adopts it into `/etc/ex4-update/keys/` only after that release has passed every other check (signature by a
key it holds, board, channel, expiry, not a downgrade), and only if `usign -F` reads the same key number out of it;
it holds at most 4 keys. From then on, releases signed by either key are accepted. A release by a key the box does
not hold cannot hand it a successor (the signature refuses first). In a RAM trial `/etc` lives in RAM, so an adopted
key lasts until the next start; the next image simply ships the new key.

**Revocation is a new image, and only that.** Nothing a release says can make a box stop trusting a key it holds: a
"revoke" line signed by a leaked key would prove nothing, and one signed by the other key would let either key lock
the box out. So a key is dropped by building an image that no longer carries it and installing that by hand. If the
current key LEAKS, rotation does not help (the thief can rotate too): build a new image with a new key, and treat
every box as needing a hand install.

**The image says who it is** in `/etc/ex4-release` (`board= version= serial= channel= openwrt= kernel=`), written by
`mkrelease.py ident` before the image is built. `update/FILES` lists what else goes in.

## 2. The box: `ex4-update`

```
ex4-update check  [--url URL | --from DIR] [--insecure-http]   is there a newer release? (RELEASE + RELEASE.sig only)
ex4-update verify [--url URL | --from DIR] [--insecure-http]   + the payload, size and sha256 checked; nothing kept
ex4-update stage  [--url URL | --from DIR] [--insecure-http]   + unpacked into RAM, every file checked again
ex4-update status                             what the last run found (also /tmp/ex4-update/state)
ex4-update keys                               the signing keys this box holds, by key number
ex4-update install                            REFUSED: not built
```

The order, where each step refuses before the next can run, is in the file's header. In short:

1. It fetches RELEASE (64 KiB at most) and RELEASE.sig (4 KiB at most) under the shell's file size limit, so a hostile
   server cannot fill RAM first.
2. `usign -V -P /etc/ex4-update/keys` must accept the signature. No key, no signature, or a key it does not hold all
   mean REFUSED. Nothing in RELEASE is read before this point.
3. Any line it does not know is refused. Then it checks the board (the device tree's first `compatible`, which must
   also match `/etc/ex4-release`), the channel (a `trial` system also takes `stable`), (v9) the clock and the expiry,
   and only then the serial (greater, never smaller; equal = "up to date"). A `successor` key is adopted only after
   all of these have passed.
4. For `verify` and `stage`, the payload must have exactly the size and sha256 that RELEASE gives.
5. For `stage`, RAM must hold the payload twice. The tar must hold plain files only, each one listed in RELEASE and
   listed once, with no `..` and no `/`. Every file is checked again after unpacking. Only then does the folder take
   its final name.

**The URL** must be `https://` (v9: `http://` is refused unless `--insecure-http` is typed: the signature would
still decide, but anyone on the way could watch, or quietly hold back newer releases). It is the first line of
`/etc/ex4-update/url`. Without that file it is
`https://github.com/aliaholes/wd-mycloud-ex4-openwrt/releases/latest/download`. **No release has been published there
yet**, so today `check` reports "could not fetch ... not found (404)". To use that default, upload the four files as
assets of one GitHub release. If a new release lands between the RELEASE fetch and the payload fetch, the hashes
disagree and the run refuses, which is safe. `--from DIR` reads the same four files from a USB stick.
`uclient-fetch` checks HTTPS certificates against the image's CA bundle. That keeps fetches private; it does not
create trust.

**It never runs on its own.** No cron, no timer, no hotplug. It runs only when someone types it, or (once the
web patch lands) when the System page asks. **It never installs.** A staged release stays in RAM and is gone at the
next boot. Writing the flash is a separate phase that has not been built, and it is Kurt's call.

**What the web interface shows** (System → Updates, in the bundle since v9): what runs (version, serial, channel),
how many signing keys the box holds, when the last check ran and against which address, what it found (an expired
release in plain words, with its date), the signature state, how long a good release is good for, a key it was told
about, and a note when the last check is more than a month old. It reads `/etc/ex4-release` and
`/tmp/ex4-update/state`, both plain files, every value through a whitelist, so no process starts.

## 3. The watch: `cvewatch.py`

```
python3 -I update/cvewatch.py --release releases/2026.11.17-v7 [--out report.json]
```

It needs only `RELEASE`, `RELEASE.sig` and `sbom.cdx.json`. First it checks the signature with `usignpy.py`, then the
SBOM's sha256 and size against RELEASE. It trusts nothing in the SBOM before both checks pass. Then:

- **Userspace** is asked as the same upstream version in Alpine's data at OSV (`Alpine:v3.24`). OSV has no OpenWrt
  ecosystem: it answers `400 invalid ecosystem`. Alpine ships upstream versions much as OpenWrt does, so this is a
  proxy, not proof. Each result falls into one of three classes:
  - **REBUILD**: Alpine fixed it in a newer upstream version.
  - **CHECK**: Alpine fixed it with a patch on our same upstream version. Does OpenWrt carry the patch?
  - **dropped**: Alpine's own record says our version is not affected.

  Alpine's fixed version can sit on a newer branch than ours (samba 4.23 vs our 4.22, mbedtls 4 vs our 3.6 LTS), so a
  REBUILD can also be met by a fix on our own branch.
- **The kernel** is asked as the upstream stable tag (`v6.12.112`) in OSV's GIT data, which holds the Linux kernel
  CNA's records. The run reports a count and the ids. They are **not** filtered by our kernel config or by OpenWrt's
  patches. Any count above zero means "rebuild when OpenWrt bumps 6.12".
- **BLIND**: OpenWrt's own projects (uhttpd, rpcd, procd, ubus, netifd, usign ...). No OSV ecosystem covers them, so
  watch `openwrt.org/advisory`. **UNCHECKED**: a source package that `update/osv-map.json` does not name. **OURS**:
  this repository's programs. All three lists print on every run: a quiet run is not proof of safety.
- **Two canaries** (versions with known holes) ride in every batch. If either comes back empty, the run reports
  DEGRADED (exit 3) and its answer is not trusted.
- **The payload wall:** the only things sent to OSV are `{package: {name, ecosystem}, version}` and OSV's own
  `page_token`, plus `GET /v1/vulns/<id>`. No hostname, address, path or key ever goes out. With `--record DIR`,
  every body sent is kept, and `tests/update/run.sh` checks those bytes.

Exit codes: 0 nothing to rebuild (or nothing NEW, below) · 1 NEW REBUILD / CHECK / kernel items · 2 refused
(signature, hash, shape) · 3 degraded. The watch is not wired to any timer. A morning job can run it like any other
read-only check.

**The dedupe ledger (v9).** With `--cache DIR` (the default `~/.cache/ex4-cvewatch`) the watch keeps
`DIR/seen-findings.json`: the set of findings it last reported, one member per (class, source package) plus the
kernel tag when it has open CVEs. The same set the next morning prints `DEDUPE  same N finding(s) as first reported
<date>: no new card` and exits 0; a set that gains or loses any member prints `NEW  new finding(s): ...; gone since
the last report: ...` and exits 1 as before. A new CVE id inside a class already reported does not count as new (the
card is already out); a new package or class does. `--seen FILE` names another ledger, `--no-dedupe` reports every
run. The morning hook (a patch for the studio, not in this repository) needs no change: it already passes `--cache`.

## Kernel modules and packages from OpenWrt's feeds: NOT in this image (v9)

**Packages come only through our signed releases.** Since v9 the image carries no `/etc/apk/keys/*` and no official
feed list (`/etc/apk/repositories.d/distfeeds.list`): the image build removes them, and refuses a root file system
(and checks the packed initramfs) that still has either. `apk add` on the box therefore has nowhere to fetch from and
no key to trust an index with. (The SBOM still lists `apk-mbedtls` and `openwrt-keyring`: they are built and
installed like every package, and the hook removes their key and feed files afterwards; `apk` stays for reading
the installed-package database.) Why, in three lines:

- **Kernel modules from OpenWrt's official feed do not fit.** Every kmod depends on
  `kernel (=6.12.112~<vermagic>-r1)`. The official 25.12.6 kirkwood kernel's vermagic is `3111a561bff35e9cf86e6ff2a5ba88bc`
  (read from the official image's `/lib/apk/db/installed`). Ours is `a44c9a44007be5720baf8da806598a35`, because our
  config adds the XOR engines and md. apk refuses to install them, and forcing one in would load a module built for
  another kernel. Kernel fixes therefore always mean a rebuild of our own image.
- **Userspace from the official 25.12 feeds** can install in principle: same release, same `arm_xscale` / musl ABI.
  25.12 uses **apk v3** (`apk-mbedtls 3.0.5`), not opkg. Its indexes (`packages.adb`) are signed with OpenWrt's
  ECDSA key `/etc/apk/keys/openwrt-25.12.pem`; usign/opkg signing was the 24.10-and-older scheme. Pinning in apk
  works through version constraints in `/etc/apk/world` (`name=ver`, `name~ver`) and `@tag` repositories. But a
  package installed that way is not in our SBOM, and on a RAM trial it vanishes at reboot. **Our path is the whole
  image, rebuilt from source and released signed.**
- Up to v8 the image also trusted `/etc/apk/keys/public-key.pem`, a key the build made for itself, whose private half
  sits world-readable in the build tree. Anyone who could read that tree could have signed a package index the box
  would accept. v9 removes it along with OpenWrt's own key. We serve no apk repository; nothing is lost.

## Tests

`bash tests/update/run.sh --work W --tree BUILD_WORK [--bundle B --real-key SEC] [--watch-replay REC]` runs the box
half under qemu-arm, using the image's own busybox ash, usign, sha256sum, tar and uclient-fetch, over real HTTP to
`tests/update/srv.py`. It covers:

- a good release through check, verify and stage, byte-identical when staged;
- refusals for: a tampered RELEASE byte, a tampered payload byte, a payload truncated at rest, a download cut off
  mid-body, the wrong key, no signature, another board, a downgrade, another channel, an unknown line, a missing
  `end`, a 1 MiB RELEASE, a server streaming endless bytes, and a validly signed payload with an extra file, a
  symlink or a `../` member;
- box-side checks: same serial, no key, no identity, a device tree that disagrees, too little RAM;
- (v9) the expiry: an expired release (also with the serial already running: never "up to date"), a clock behind the
  release's build time, no `not-after`, epoch and ISO that disagree, a 500-day validity, `not-after` before `built`;
  the state file and web card words; plain `http://` refused without `--insecure-http` (also from
  `/etc/ex4-update/url`), before anything is fetched;
- (v9) the key rotation: a successor adopted after every check, a release by the successor then accepted on that box
  and refused on a box that never saw it; never adopted from a downgrade, an expired release, a release by an unheld
  key, or a line whose key number is not its key's own;
- input handling: `--from` a folder, `install`, bad URLs;
- the real bundle signed with the real key, staged on a box that holds only the shipped key;
- the watch's trust walls, its classes (`tests/update/watch-fixture.py`, a fake OSV), and a replay of a recorded
  live OSV run with the payload wall checked on its bytes; (v9) the dedupe ledger (same set, a new id inside a class,
  a new package, a package that went away).
