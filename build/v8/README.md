# build/v8: one trial bundle that carries everything

v8 = v7 (our own kernel with the SoC's XOR engines, md built in, the NAS services in the image: see
[build/v7/README.md](../v7/README.md), which still describes the kernel, the image and `ex4-md-ro`) + **the web
interface** ([webui/README.md](../../webui/README.md)) + **the panel daemon with the LCD** ([docs/PANEL.md](../../docs/PANEL.md))
+ every fix the v7 reviews asked for. Still a RAM trial: nothing is installed, nothing writes the NAND, the array is
never assembled at boot, and there is no read-write command.

```
sh build/v8/build-v8.sh image  --work DIR [--netwall SOCK --egress-log LOG] [--seed-dl DIR] [--jobs N]
sh build/v8/build-v8.sh bundle --work DIR --pubkey KEY.pub --wd-gpl WDMyCloud_EX4_GPL_v2.12.127_20181219.tar.gz [--out DIR] [--no-webui]
```

| File | What |
|---|---|
| `build-v8.sh` | both stages (v7's, with the changes below); every gate is a `die` line |
| `diffconfig` | v7's + `libustream-mbedtls`, `px5g-mbedtls` and the ucode modules the web interface needs (v7's image had no certificate maker, so HTTPS could not have started) |
| `kernel-config.fragment`, `patches/` | unchanged from v7 |
| `files/usr/sbin/ex4-md-ro` | unchanged from v7 (read-only assembly only) |
| `files/etc/smartd.conf` | v8: smartd watches nothing (and is out of rc.d); the interface reads SMART itself |
| `egress-allow.py` | v7's proxy + `--unix PATH` (listen on a socket file, for the net wall) |
| `netwall.py` | v8: THE NET WALL's relay and its proof |
| `overlay-gate.py` | v8: THE OVERLAY GATE |
| `tests/qemu-p0-idle.sh` | v7's idle-memory run + the honest numbers (below) |

## What v8 changes, and why

| Change | From |
|---|---|
| The web interface rides in the bundle: HTTPS on 443 of the trial's address, port 80 only redirects, no web login until the box is claimed with a six-digit code read over ssh (`ex4-claim`) | Kurt, Nov 17 2026 15:13 (the next trial carries it); the web lane's patches 1 and 1b: `build/mkoverlay.py --webui`, and 99-ex4-trial no longer pins uhttpd to loopback when `--webui` is given |
| dnsmasq, firewall4 / nftables, odhcpd, uboot-envtools, block-mount, LuCI stay out; the image stage refuses a `.config` or a rootfs that carries any of them | Kurt 15:13 ("leave them out") |
| `ex4fan` = the panel lane's daemon (LCD Tier A OFF by default) + `ctl send-test`: ONE LCD frame (the host name), one try, once per boot; the trial's self-test runs it once and records the ACK | Kurt 15:13 (one test frame, ACK only: nobody can see the glass) |
| THE NET WALL: the image stage runs in a network namespace with nothing but loopback; the proxy runs outside behind a socket file; `netwall.py prove` must pass first | image review nit 4 (the v7 proxy was environment-only) |
| THE OVERLAY GATE: the bundle stage refuses an overlay without root `*`, key-only ssh and exactly the given key, or with the web door in the wrong state | image review nit 3 |
| smartd out of boot, `/etc/smartd.conf` names no device | image review nit 6 |
| the honest idle-memory number | image review nit 1 |
| sign-in brake counted before the check, one check in flight; `signout_all` ends every interface session; a password change ends the others; uhttpd 16 requests / 32 connections / 15 s timeout; the read-write token checked by content; NFS `*` + rw + no root squash refused; the Lately list wraps | web review nits 1 to 5, 8 |
| `conf_read` sees a write in the same second (inode, size, nanoseconds); a note on who may write `alerts.d` | panel review nits 1 and 2 |
| `tests/qemu-e2e.sh` asserts the web door from outside (uhttpd started by its own init script from the uci config, not from command-line flags) and the one LCD frame on the wire | web review: "port 80 only redirects" was unproven |

## The net wall, how it is run

The image stage is started by two units: the proxy, with the network, and the build, without:

```
systemd-run --user --unit=ex4v8-egress python3 -I build/v8/egress-allow.py --unix $V/egress.sock --log $V/egress.log
sudo systemd-run --unit=ex4v8-image -p User=$USER -p PrivateNetwork=yes ... \
     sh build/v8/build-v8.sh image --work $V/img --netwall $V/egress.sock --egress-log $V/egress.log
```

`PrivateNetwork=yes` gives the build a network namespace of its own with only `lo`; a socket file crosses that wall,
a TCP port does not. `netwall.py relay` inside turns the build's `http(s)_proxy` port into the socket. Before the
first `git clone`, `netwall.py prove` checks, and writes into `netwall-proof.txt`: only `lo` exists; a name lookup
fails; a direct TCP connection to two public addresses fails ("Network is unreachable"); through the relay the proxy
allows OpenWrt's mirror and refuses another host. The stage refuses to run if any of that fails. (Ubuntu 24.04
blocks unprivileged user namespaces, so `unshare --net` as a user is refused there; the system unit is the way that
needs no change to the host.)

## RESULTS (Nov 17 2026, the build box)

**The image** (`image`, behind the net wall, 15:24 to 15:53 with 16 jobs): initramfs uImage md5 `1df051b8`, 17,754,730 B.
`netwall-proof.txt`: `RESULT WALLED` (only `lo`; the name lookup failed; 1.1.1.1 and 8.8.8.8: "Network is unreachable";
the proxy allowed OpenWrt's mirror and refused example.com). The proxy's log: 145 connections allowed (142 to
sources.cdn.openwrt.org, 3 to git.openwrt.org), 2 refused (the proof's own example.com, and glib's optional
gitlab.gnome.org subproject, as in v7). OpenWrt's hash checks stayed on. In the rootfs: px5g present; smartd, mdadm,
samba4, ksmbd, nfsd, rpcbind, wsdd2, avahi out of rc.d; none of dnsmasq / firewall4 / nftables / odhcpd /
uboot-envtools / block-mount / LuCI.

**bundle-v8** (run id `11-l2off-20261117-1612`): 19 files, kernel.bin `324ab3f0` (17,754,585 B), overlay.cpio
`86e74fb9` (2,131,456 B, 60 entries, the overlay gate: 13 of 13), ex4fan `6bcbdc1b`. **Size gate**: decompressed
image 25,968,528 B, worst-case peak `0x29fa969`, 6,313,623 B below RAM marker H. The loader copies 19,898,481 B in
612 of its 2643 chunks (bundle-v7: 605). The web interface adds about 260 KB to the overlay; the kernel's peak does
not move (the overlay sits at 0x4000000).

**Tests** (`tests/run-offbox.sh --slow`, every optional input: the e2e test kernel, the stock busybox, WD's
up_read_daemon, the flash dumps; on the bundle built with a throwaway key so the e2e also logs in): 27 tests, 26
clean; the one failure was a test of mine (the parallel-guess check sat where an earlier test had left the brake at
eight seconds), fixed in `api_test.py` and re-run alone on the same image: **281 passed, 0 failed**. The rest:
e2e normal **68/68** (65 on the deliverable, which skips the 3 key-login checks), silent 11/11, rpmzero 11/11,
deadman 12/12, panel 81/81 native and ARM, fan 120/120 native and ARM (117/117 ASan+UBSan), trial-logic 144/144 in
dash, busybox ash and on the stock firmware's own awk, mac-hook 21/21 (with the real flash bytes), overlay-gate 13/13,
handoff 10/10, handoff-memfix 11/11 + 1 SKIP (the emulator's missing clock at "xor: measuring"), ex4phy 3/3,
ex4log-roundtrip 30/30, watch 7/7, dtb-check, phy-id-check, kernel-facts 2/2, klog-synth 2/2, stub, webui build
check and hash self-test. The page in a caged browser against the fake box: 199/199.

**The web door, seen from outside the emulated trial** (uhttpd started by its own init script): port 80 answers
`GET /` and `GET /ubus` with `307 Temporary Redirect` to `https://`, no body; 443 serves the page (TLS, the box's own
px5g certificate); anonymous `session.login` and `ex4.status`: "Access denied"; `file.read`: "Object not found" (the
image has no file plugin); `setup_state`: `claimed:false`; LAN TCP ports exactly 22, 80, 443; no rpcd login exists.
The one LCD frame: exactly one `SysName` frame (`ex4-trial`) on the wire, ACKed by the fake micro, recorded.

**Idle memory, honestly** (`tests/qemu-p0-idle.sh`, the e2e test kernel, this image's userspace + the bundle's
overlay with the web interface; smbd + helpers, wsdd2, avahi, rpcbind + nfsd started on empty tmpfs shares):

| | idle, before the services | every P0 service up |
|---|---|---|
| `free` "used" (what v7 quoted; it leaves out the RAM-disk root, and it went DOWN as services started) | 17.6 MiB | 14.4 MiB |
| sum of VmRSS + the tmpfs root (over-counts shared pages) | 75.3 MiB | **101.3 MiB** |
| sum of Pss + the tmpfs root (the honest figure) | 61.8 MiB | **77.4 MiB** |
| sum of Pss alone (the same services with the root on a disk: an installed system) | 6.8 MiB | 18.3 MiB |

So **in a RAM trial the 64 MB bar is NOT met**: 59 MiB of it is the operating system itself, unpacked into RAM. An
installed system would not carry that; its estimate (Pss alone, 18.3 MiB) is far under the bar, but it is an
estimate from qemu, not a measurement on the box. smbd and its two helpers are the largest (about 18 MB of VmRSS).
ksmbd is not in these numbers (the test kernel has no ksmbd).

**Not proven by any of this**: everything about the real box that qemu cannot be (the XOR engines' write path, SMB
throughput, CPU per poll and p95 while a copy runs, the TLS handshake's cost on the 1 GHz core, whether the real
micro ACKs an LCD frame, what the glass shows). The image stage's `build-v8.sh` was `c41de072`; the final file differs
only in the bundle stage and one message string (see `image-inputs.md5` on the build box).
