# build/v9: the trial bundle that can be kept secure

v9 = v8 ([build/v8/README.md](../v8/README.md): our own kernel with the SoC's XOR engines, the NAS services, the web
interface, the panel daemon, the net-walled image build) + what makes it **able to be updated to keep secure** (Kurt,
Nov 17 2026 15:13: "Quality work that you're proud to display. Secure, fast, able to be updated to keep secure"):

```
RELVER=2026.11.17-v9 RELSERIAL=2026111702 sh build/v9/build-v9.sh image --work DIR [--netwall SOCK --egress-log LOG] [--seed-dl DIR] [--jobs N]
EX4_RWBENCH=1 sh build/v9/build-v9.sh bundle --work DIR --pubkey KEY.pub --wd-gpl WDMyCloud_EX4_GPL_v2.12.127_20181219.tar.gz [--out DIR]
python3 -I update/mkrelease.py release --work DIR --bundle DIR/out/bundle-v9 --version 2026.11.17-v9 --serial 2026111702 ...
```

Still a RAM trial: nothing is installed, nothing writes the NAND, the array is never assembled at boot, and the one
write path (the read-write bench) does nothing until its per-session token is typed by hand.

| File | What |
|---|---|
| `build-v9.sh` | both stages: v8's, + the update path in the image, no official package feeds, the bench in the overlay; every gate a `die` line |
| `files/usr/sbin/ex4-md-ro` | v8's + THE RECOVERY WALL: refuses a member being rebuilt (Feature Map 0x2, a Recovery Offset line) or an Array State that is not AAAA, even when State says clean |
| `files/etc/smartd.conf` | unchanged from v8 |
| `overlay-gate.py` | v8's + `--rwbench FILE` / `--no-rwbench`: the bench in, with the clean stop on every reboot path, or entirely out; v9.4 + `--variant` / `--kernel-dts` (below) |
| `xor-off.dtsi` | v9.4: `EX4_XOR=off` (R1 arm X2): `&dma0` / `&dma1` `status = "disabled"`, appended to the preprocessed trial DTS |
| `kernel-config.prof.fragment` | v9.4: the PROFILE TWIN's config (R2 "v10b-prof"), read by `prof-image` |
| `kernel-config.uaccess.fragment` · `kernel-config.diet.fragment` · `kernel-config.prof2.fragment` | v9.7: the kernel twins k-uaccess (F3), k-diet (F6), k-prof2 (timed profile), read by `twin-image --twin NAME`; each line argued in the file |
| `kernel-config.ud.fragment` · `kernel-config.nfsdtrack.fragment` | v9.8: k-ud (uaccess + diet + nfsdtrack, the union, proven by `tests/build/fragment-union-test.sh`) and k-nfsdtrack (the default config + `CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y`) |
| (from `build/v8/`) | `diffconfig`, `kernel-config.fragment`, `patches/`, `netwall.py`, `egress-allow.py`: unchanged |

## What v9 changes, and why

| Change | From |
|---|---|
| **The update path is in the image**: `/usr/sbin/ex4-update`, our release key as `/etc/ex4-update/keys/cd0c35ab50a98c3c`, `/etc/ex4-release` (who it is: board, version, serial, channel). The image stage refuses without `RELVER`/`RELSERIAL`; the bundle stage refuses an image without the path byte for byte | the v8 update lane's build patch, adapted to v9 |
| **Releases expire** (`not-after`, default 90 days): an expired release is refused, even at the serial already running, so a held-back release address cannot keep a box "up to date" forever; a clock behind the release's build time is refused ("set the clock first") | update review nit 1 |
| **Plain `http://` is refused** unless `--insecure-http` is typed | update review nit 4 |
| **Key rotation**: a RELEASE may name one `successor` key, vouched for by the key that signed it; adopted only after every check passes. Revocation = a new image (docs/UPDATES.md says why) | update review nit 2 |
| **No official package feeds and no apk keys in the image** (OpenWrt's key, and the build's own `public-key.pem` whose private half is world-readable in the build tree; the feed list). Our kernel cannot take official kmods; packages come only inside our signed releases. The stage checks the folder AND the packed initramfs | update builder Q1, review nit 3 |
| **The CVE watch dedupes**: the same set of findings again = no new finding, exit 0 (`--seen`, default under `--cache`) | update review nit 5 |
| **The web card** System → Updates: what runs, keys held, last check, what it found (an expired release in plain words), signature, good until, a key rotation, a stale-check note | the update lane's webui patch + v9 |
| **The read-write bench rides in** (`EX4_RWBENCH=1`): `/usr/sbin/ex4-rwbench`, `ex4_rw_wait` in the S99 auto-return and the S03 deadman, `K01ex4-rwstop`, ex4fan's fail-safe stop. Inert without the typed token | the bench lane's three patches |
| **NFS off by default** (client `--nfs`; the box refuses `serve nfs` without `--unauthenticated-nfs`) | bench review must_fix 1 |
| bench: SIGPIPE ignored; signals ignored inside the clean stop (the guard is no longer killed by it); the client holds the reboot on rc 3; `--keep-zeros` the default; servers never inherit the lock fds; ext4 ro_compat recorded and re-read after the unmount; `$0` absolute; the window sized for Samba 4 + ksmbd (25 min; 40 with `--nfs`); copies under `timeout`; NFS mounts soft; the zero folder kept | bench review nits 1-10 |
| **`ex4-md-ro` refuses an array whose Feature Map shows recovery** (0x2) even when State is clean | the bench lane's finding |
| **The claim code is eight digits**, drawn without modulo bias (the web door ships in every trial now) | web review nit / integrate review nit 4 |

## RESULTS (Nov 17 2026, the build box, `$BUILD/v9/`)

**The image** (net-walled, 17:07 to 17:31, 16 jobs, `RELVER=2026.11.17-v9 RELSERIAL=2026111702`): initramfs uImage md5
`81fdd145`, 17,765,586 B. `netwall-proof.txt`: `RESULT WALLED`. Sources: v8's `dl/` given as `--seed-dl` (files that
came from OpenWrt's mirror, every hash checked again by OpenWrt); the proxy allowed 4 connections (3 git.openwrt.org,
1 sources.cdn.openwrt.org) and refused 2 (the proof's example.com, glib's optional gitlab.gnome.org). The rootfs hook
removed `etc/apk/keys/openwrt-25.12.pem`, `etc/apk/keys/public-key.pem` and `distfeeds.list`; the packed initramfs
(1250 entries) holds no apk key, no feed list, and holds `usr/sbin/ex4-update` + `etc/ex4-release`.

**bundle-v9** (`bw-box/out/bundle-v9`, run id `12-l2off-20261117-1745`, `EX4_RWBENCH=1`, the trial key): 19 files,
MD5SUMS md5 `30be1576`, kernel.bin `9079a0d5`; size gate 6,302,767 B below RAM marker H; 614 of 2643 loader chunks;
the overlay gate (v9) 18/18. Test twin (`bw-test`, throwaway key): MD5SUMS `9ce5686f`, the same kernel.bin.

**The first signed release** (`release/2026.11.17-v9/`, serial 2026111702, channel trial, key cd0c35ab50a98c3c, good
until 2027-02-16T01:33:03Z): RELEASE md5 `2b6eab56`, payload 21,852,160 B (19 files), SBOM 169 components.

**ONE suite run, all green** (`suite-1/`, 2015 s, logs kept; the sysctls the loop-tests touch read the same before,
between and after): loop-test 92/92 (host BusyBox 1.36.1) and 92/92 (the image's BusyBox 1.37.0, ARM); update 112/112
(incl. the real bundle with the real key, the recorded live OSV run replayed, the deliverable release staged); rwbench
stub 42/42, conf 17/17, patch 32/32; run-offbox with every optional input on the TEST twin 28 tests 0 failing (e2e
normal 68/68 incl. the key login, silent 11, rpmzero 11, deadman 12; webui-api 285/285; md-ro 20/20; overlay gate
18/18; fan 120/117/120; panel 81/81 x2; trial-logic 144 x3; mac-hook 21; handoff 10, memfix 11) and on the
DELIVERABLE 28 tests 0 failing (e2e normal 65/65: no key login).

**Not proven by any of this:** everything only the real box can show (as v8), the browser page test (no browser
runtime on the build box; the page's script was parsed, not run), real HTTPS fetches by `ex4-update`, a real release on GitHub.

## v9.4: the bench variants (Nov 17 2026, PERF-DESIGN-v2 §3 R1 arm X2 + R2 profile twin; bench only)

Kurt, 20:19: "The goal is to beat stock at everything." Two bench variants of the same bundle, so the next rungs are
measured, not guessed. **No flag = v9.3's bundle exactly** (proved below).

```
EX4_XOR=off     EX4_RWBENCH=1 ... sh build/v9/build-v9.sh bundle --work W ...    # R1 X2: both XOR engines off in the DTB
sh build/v9/build-v9.sh prof-image --from $BUILD/v9/img --work $BUILD/v10prof --jobs 12   # the profile twin's image
EX4_PROFILE=1   EX4_RWBENCH=1 ... sh build/v9/build-v9.sh bundle --work W ...    # W/openwrt -> v10prof/openwrt
```

| Variant | What changes | Marked by | Refused when |
|---|---|---|---|
| `EX4_XOR=off` | kernel.bin's DTB only: `xor@60800` + `xor@60900` `status = "disabled"` (mv_xor does not probe; async_tx uses the CPU xor). The kernel is the same (`CONFIG_MV_XOR=y` stays) | run id suffix `-xoroff`, `VARIANT` file (in MD5SUMS), a PROVENANCE line | the decompiled DTB differs from the default one in anything but those two status lines (`bundle-work/dts/xor-off.diff`) |
| `EX4_PROFILE=1` | the image tree is the PROFILE TWIN (`prof-image`): + `FTRACE`, `FUNCTION_TRACER`, `DYNAMIC_FTRACE`, `FUNCTION_PROFILER`, `KALLSYMS`; `DEBUG_FS` was already on (`KALLSYMS_ALL` is forced off by OpenWrt's `include/kernel-defaults.mk:118`; not needed for function counts). No `PERF_EVENTS`, no perf package | run id suffix `-prof`, `VARIANT` + PROVENANCE say **PROFILE TWIN: never ship** | a tracing kernel without `EX4_PROFILE=1`, `EX4_PROFILE=1` on a stock kernel, a twin without its `PROFILE-TWIN.txt` receipt |
| both | `EX4_XOR=off EX4_PROFILE=1` | `-xoroff-prof` | either rule above |

**The overlay gate knows the variant** (`--variant stock|xoroff|prof|xoroff+prof`, `--kernel-dts`): a profile twin's
kmods are ftrace-instrumented (they reference `__gnu_mcount_nc`) while their vermagic string is the same as stock's,
so the gate checks the instrumentation itself: all of them under `prof`, none otherwise. It also checks the DTB's xor
status against the variant. Default calls (no `--variant`) mean stock and stay compatible with v9.3's callers.

**`prof-image`** never writes its source: `cp -a` of the frozen v9 tree into a new folder, the copy's 1234 absolute
symlinks and 223 staging_dir text files that named the source repointed at the copy, the fragment applied (the resolved
`.config` may differ from v9's only in the fragment's `CONFIG_KERNEL_` lines + new "is not set" lines), `make download`
first with every proxy on a closed port (all sources must already be in `dl/`), the kernel and the kernel packages
cleaned and rebuilt, the rootfs reinstalled with the SAME rootfs hook (now a shared function, moved unchanged), the
initramfs kernel. It refuses unless every kernel module in the rootfs was rebuilt (none byte-equal to v9's) and the overlay's xhci three are ftrace-instrumented, no log shows a fetch,
and `find SRC -newer start` lists nothing. The receipt says `RESULT OFFLINE` (not WALLED: a namespace wall needs root).
mkrelease must never be given a profile bundle (its `VARIANT` says so; mkrelease does not read it yet).


### v9.4 RESULTS (Nov 17 2026, the build box, `$BUILD/v94/`, lane B proof bundles; the final bundles are the assembler's)

- **Default = v9.3:** `proof-default-final` (v9.3's repo + only these build/v9 files, the BOX key, RUNNO 14, STAMP
  20261117-2105, the v9 image) has v9.3's `bw-box` MD5SUMS line for line except PROVENANCE, whose only changed line is
  the build time. Against the canon tree (`proof-default-canon`) overlay.cpio / atags.bin / EXPECT also differ: the code
  lane's box/ex4-rwbench.sh (41b18fd9 vs 78f34b66) rides in the overlay; the kernel and DTB are v9.3's.
- **X2 (`EX4_XOR=off`):** run id `14-l2off-20261117-2105-xoroff`, kernel.bin `7a01f511`, DTB `b1695b27` (default
  `8b1ebc0b`). The DTB cut from kernel.bin's tail and decompiled with the kernel tree's own `scripts/dtc/dtc` differs
  from the default in exactly two lines: `xor@60800` and `xor@60900` `status = "okay"` -> `"disabled"`. overlay.cpio
  is byte-equal to the default bundle's.
- **The PROFILE TWIN** (`prof-image`, 885 s at -j12 under nice 19, `$BUILD/v10prof/`): initramfs uImage `102ac394`,
  18,545,762 B (v9 17,765,586); decompressed image 29,461,264 B (v9 25,968,528). DYNAMIC_FTRACE took. The kernel
  `.config` also gained what FTRACE selects by itself (TRACING, TRACEPOINTS, EVENT_TRACING, CONTEXT_SWITCH_TRACER,
  RING_BUFFER, STACKTRACE, FTRACE_MCOUNT_RECORD...); PERF_EVENTS stays off. 58 kmods, all rebuilt, 55 instrumented (the
  3 without are lib/ code built without -pg upstream). Source tree: `find -newer` 0 entries; no fetch line in any log.
  Try 1 (`$BUILD/v10prof-try1`, kept) was refused by its own gate: KALLSYMS_ALL is forced off by OpenWrt.
- **`proof-prof`** (`-prof`, `EX4_PROFILE=1`): size gate peak 0x2e106e1, margin 2,029,855 B below marker H (v9:
  6,302,767); 640 of 2643 loader chunks; layout clean. `proof-xoroff-prof` the same + the X2 DTB. Refused as they must
  be: the twin without `EX4_PROFILE=1`, `EX4_PROFILE=1` on the v9 image, `EX4_XOR=maybe`; the gate refuses
  `--variant prof` on stock kmods and a DTB whose xor status does not match the variant.


## v9.7: the kernel twins + one variant scheme (Nov 18 2026, FABLE-OPT F3 + F6 + trial 3 "the build night"; bench only)

Kurt, Nov 17 23:55: "Prolly not jumbo frames. I only need NFS. Nothing uses SMB if it doesn't have to." Standing: 20:19 "The
goal is to beat stock at everything." **No flag = v9.4's bundle exactly** (proved below).

```
sh build/v9/build-v9.sh twin-image --twin uaccess|diet|prof2 --from $BUILD/v9/img --work $BUILD/k-<twin> --jobs 12
EX4_TWIN=uaccess|diet|prof2 EX4_RWBENCH=1 ... sh build/v9/build-v9.sh bundle --work W ...      # W/openwrt -> k-<twin>/openwrt
EX4_CMDLINE_ARM=nomemcg ... bundle ...                       # cgroup_disable=memory on the command line (run 15's arm)
EX4_* ... sh build/v9/build-v9.sh variant --run RUNBASE --initrd-size N --out DIR      # plan only: run id, VARIANT, atags.bin
sh tests/build/cmdline-arm-test.sh                           # drives `variant`: 57 checks
```

| Twin | Kernel config against v9's | Marked by | Refused when |
|---|---|---|---|
| `uaccess` (F3 = K1) | `UACCESS_WITH_MEMCPY=y`, nothing else (KSTRICT) | run id `-uaccess`, VARIANT `uaccess`, PROVENANCE "bench kernel twin" | the tree's kernel is not the uaccess one, its `TWIN.txt` names another twin or another kernel `.config` md5 |
| `diet` (F6 = K2 + K3 + K5) | cgroup pile (memcg, blkcg, group sched, cgroup-BPF, RDMA, cpuacct) and router hooks (MPTCP, mroute v4/v6, SEG6 lwtunnel, VRF) out; `JUMP_LABEL=y`; ext4, jbd2, mbcache, sata_mv and the NFS server stack (nfsd, lockd, sunrpc, grace) built in; every other moved symbol named in the fragment (KSTRICT) | `-diet`, VARIANT `diet` | as above; `EX4_CMDLINE_ARM=nomemcg` with it (no memory controller to disable) |
| `prof2` (timed profile) | v10prof's lines + `FUNCTION_GRAPH_TRACER=y` on the DEFAULT config: the function profiler records time per function | `-prof2`, VARIANT + PROVENANCE **PROFILE TWIN: never ship** | as above, + its `PROFILE-TWIN.txt` |
| `prof` (v9.4) | `EX4_PROFILE=1` = `EX4_TWIN=prof`, unchanged | `-prof` | as v9.4 |

**The variant scheme.** Tokens in this order: `xoroff` · one kernel twin (`prof`, `prof2`, `uaccess`, `diet`) · `nomemcg`.
Run id suffix = `-` + each; VARIANT = the tokens joined with `+` (or no VARIANT file for none). The overlay gate takes the
same strings (`--variant`), refuses unknown, repeated, out-of-order, two-twin and `diet+nomemcg` strings, and checks the
kmods' ftrace instrumentation for `prof` AND `prof2`. Which kernel a twin bundle carries is the bundle stage's check: the
twin's `TWIN.txt` records the md5 of the kernel `.config` it built, and the kernel's own marks (FUNCTION_TRACER,
FUNCTION_GRAPH_TRACER, UACCESS_WITH_MEMCPY, JUMP_LABEL, no MEMCG) must spell the same twin. `EX4_CMDLINE_ARM=nomemcg`
(run 15's by-hand arm) is now one of the tokens: its VARIANT file's first line says `VARIANT=nomemcg` (v9.4's by-hand form
said `VARIANT=stock`); its atags.bin is byte-equal to the by-hand one.

**What `twin-image` checks** (prof-image's checks, for every twin, + new ones): the copy never writes its source (`find
-newer` empty); offline (`make download` with every proxy on a closed port; no fetch line in any log); the resolved
OpenWrt `.config` moves only the fragment's OWRT symbols and the OMAY ones it names; every kernel module rebuilt (each rootfs `.ko`
byte-equal to its kmod package's freshly built copy, which is newer than the stage: v9.4's "none byte-equal to v9's" rule
was wrong for uaccess, whose rebuilt modules are byte-equal to v9's because copy_to_user lives out of line in the kernel; the
rootfs is reinstalled, so a module that became built-in leaves no stale `.ko`); profile twins:
instrumented kmods, the others: none; **THE SECURITY KEEP LIST** (stack protector, hardened usercopy, fortify, slab
freelist hardened + random, list hardening, strict kernel / module RWX, seccomp + filter, all namespaces, panic on oops,
stack-end check, dmesg restrict, unprivileged BPF off, cgroups + pids) and **THE NAS KEEP LIST** (md, raid456, mv_xor,
async_tx DMA, DMA devices, NFSv4 server, quota; nfsd / lockd / sunrpc / exportfs / grace / ext4 / jbd2 / sata_mv y or m,
each module either in the rootfs or in `modules.builtin`) read back from the BUILT kernel; KSTRICT twins: the built kernel
`.config` differs from v9's only in symbols the fragment names (`CONFIG_INITRAMFS_SOURCE` must differ by the tree path
alone); **THE SIZE ESTIMATE**: decompressed image + uImage + 64 KiB for the DTB + the decompressor's slack, from 0x8000,
below marker H (0x3000000); the bundle's size gate stays the authority.

**mkrelease does not read VARIANT yet** (update/ is not this lane): a twin or profile bundle must never be given to it.


### v9.7 RESULTS (Nov 18 2026, the build box, lane B; proof bundles in `$BUILD/v97/proof-*`, the final bundles are the assembler's)

- **The three twins** (`twin-image`, -j12 under nice 19, offline, each a fresh `cp -a` of `$BUILD/v9/img/openwrt`; `find
  -newer` on the source 0 entries, no fetch line in any log, every one):

  | Twin (`$BUILD/k-*/`) | Wall | uImage | Decompressed | Size estimate margin | Bundle size gate margin | Loader chunks | kmods |
  |---|---|---|---|---|---|---|---|
  | v9 default (v9.4) | | 17,765,586 B | 25,968,528 B | | 6,302,767 B | 615 | 58 |
  | `k-uaccess` | 875 s | 17,763,426 B `ab3e9eea` | 25,968,528 B | 6,239,246 B | 6,304,927 B | 615 | 58, all rebuilt, all byte-equal to v9's |
  | `k-diet` | 876 s | 17,609,570 B `be1d9db1` | 26,994,928 B | 5,366,702 B | 5,432,383 B | 610 | 45 (13 built in), all rebuilt, none byte-equal |
  | `k-prof2` | 872 s | 18,559,370 B `b7bcaf51` | 29,469,616 B | 1,942,214 B | 2,007,895 B | 642 | 58, all rebuilt, 55 instrumented |

  k-uaccess: kernel `.config` differs from v9's in exactly `UACCESS_WITH_MEMCPY` (+ the tree path in INITRAMFS_SOURCE);
  `__copy_to_user_memcpy` / `__clear_user_memset` in System.map. k-diet: 54 symbols, every one named by the fragment
  (KSTRICT); the 13 modules that became built in are listed in `modules.builtin` (ubox kmodloader marks those BUILTIN, so
  their `modules.d` lines stay harmless). k-prof2: v10prof's kernel `.config` + `FUNCTION_GRAPH_TRACER=y` and nothing
  else between them; `ftrace_graph_caller`, `return_to_handler`, `profile_graph_entry` / `_return` in System.map.
- **Default = v9.4:** `proof-default-old` (v9.4's build-v9.sh 1d72afc1 + gate 494d20ed) and `proof-default-new` (these
  files), same repo otherwise, BOX key, RUNNO 14, STAMP 20261117-2105, v9 image: MD5SUMS line for line equal except
  PROVENANCE, whose only changed line is the build time. Same for `-prof` (v10prof), `-xoroff`. `-nomemcg`: also VARIANT,
  whose only change is its first line (`VARIANT=stock` -> `VARIANT=nomemcg`); atags.bin byte-equal.
- **Twin bundles:** `proof-uaccess` (`-uaccess`; overlay.cpio byte-equal to the default's: same kmods), `proof-diet`,
  `proof-xoroff-diet`, `proof-prof2` (overlay gate: `variant prof2` all 3 xhci kmods instrumented). Refused as they must
  be: each twin with no flag, with another twin's flag, with `EX4_PROFILE=1`; `EX4_TWIN=diet` and `EX4_PROFILE=1` on
  the v9 image; v10prof with no flag or as prof2; `diet` + `nomemcg`.
- **Tries kept, not deleted:** `k-diet-try1` (OMAY list short: PIMSM / throttling / FREEZER / two invisible packages),
  `k-diet-try2` (KSTRICT: LWTUNNEL pair + INITRAMFS_SOURCE path), `k-uaccess-try2` (v9.4's "no kmod byte-equal to v9's"
  rule refused a correct deterministic rebuild), `k-uaccess-try1` / `k-diet-try3` / `k-prof2-try1` (stopped in `cp -a`:
  the script was edited under a running build; the runner now never runs while its repo is edited).

## v9.8: the ud twin, the nfsdtrack line, THE BUNDLE GATE (Nov 18 2026; bench only)

Kurt, 12:45: "Go for whatever makes it awesome" (answering the morning report's three calls: the nfsd start, a combined
uaccess + diet twin, a uaccess repeat + canary). **No flag = v9.7's bundle exactly**, plus one more gate run at the end.

```
sh build/v9/build-v9.sh twin-image --twin ud        --from $BUILD/v9/img --work $BUILD/k-ud        --jobs 12
sh build/v9/build-v9.sh twin-image --twin nfsdtrack --from $BUILD/v9/img --work $BUILD/k-nfsdtrack --jobs 12
EX4_TWIN=ud        EX4_RWBENCH=1 ... sh build/v9/build-v9.sh bundle --work W ...    # W/openwrt -> k-ud/openwrt;        run id ...-ud
EX4_TWIN=nfsdtrack EX4_RWBENCH=1 ... sh build/v9/build-v9.sh bundle --work W ...    # W/openwrt -> k-nfsdtrack/openwrt; run id ...-nfsdtrack
sh build/v9/build-v9.sh kernel-kind --config KERNEL.config                         # which kernel a .config is (or REFUSED)
python3 -I build/v9/overlay-gate.py B/overlay.cpio --pubkey K ... --variant V --bundle B [--ref-kmods DEFAULT/KMODS.txt]
```

| Change | Why |
|---|---|
| **twin `ud`** = uaccess + diet + nfsdtrack, its OWN token (`-ud`, `VARIANT=ud`); build-v9 still refuses two twins (`EX4_TWIN=uaccess+diet` is refused by name) | run 17: uaccess moved local write +19% / read +45% (user copies), diet moved NFS write +7% (in-kernel copies, cgroup charges): different costs, so the v10 candidate is both. `nomemcg` is refused on ud as on diet (no memory controller) |
| **twin `nfsdtrack`** = the DEFAULT config + `CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y` | every nfsd start in runs 16 + 17 printed "Unable to initialize client recovery tracking! (-110) / Is nfsdcld running?": NFSv4 had no client recovery store. The kernel option, not the nfsdcld package (no installs). It lets the default-kernel control start nfsd the way ud does. **Not claimed: that it is 17D's cause** (the same warning printed on all 19 starts, 18 started; 17D's rpc.nfsd error text was not captured) |
| **kernel_kind's sixth mark** (`CONFIG_NFSD_LEGACY_CLIENT_TRACKING=y`) | ud = 001111, nfsdtrack = 000001: neither can pass as diet / default, and a mixture no twin is (uaccess + diet without the line, diet + the line, ...) is refused |
| **THE BUNDLE GATE** (`overlay-gate.py --bundle DIR`, run by the bundle stage after MD5SUMS; a refusal renames the bundle `bundle-v9.REFUSED`) | the v95 review's must_fix (gate half): the overlay-only gate never saw what the finished bundle SAYS it is. Now: VARIANT == the variant (absent for stock), its XOR / CMDLINE_ARM / PROFILE / TWIN lines agree, a twin's VARIANT carries one `kernel-config-md5=`; RUNID = base + exactly the variant's tokens; atags.bin's command line carries the RUNID token and `cgroup_disable=memory` iff nomemcg; the overlay's .ko set == KMODS.txt by md5; optional `--ref-kmods` (the default kernel's KMODS.txt): diet / ud share no kmod md5 with it, default-kernel variants equal it; MD5SUMS matches, VARIANT listed iff present. The overlay-only mode (no `--bundle`) is unchanged for build time |
| `kernel-kind` stage | the bundle stage's own kernel_kind on any .config, for tests and the assembler |

**Known consequence:** a `prof` bundle made from v9.4's v10prof tree (no TWIN.txt, so its VARIANT has no `kernel-config-md5=`)
is now refused at the end of the bundle stage. Rebuild prof with this `twin-image --twin prof` (it writes TWIN.txt), or use prof2.

Tests (`tests/build/`, no EX4, no network): `bundle-gate-test.sh` (synthetic bundles from `mkgatefix.py`: every variant
accepted on its own bundle, with and without `--ref-kmods`, overlay-only mode still passing; every refusal the must_fix
names, each on a bundle that differs in that one thing), `twin-variant-test.sh` (the variant stage for ud / nfsdtrack, the
refusals, kernel-kind on every kernel and five mixtures), `fragment-union-test.sh` (ud == the union of its three sources),
`cmdline-arm-test.sh` (v9.7's, unchanged, still green).

### v9.8 RESULTS (Nov 18 2026, the build box, lane B; proof bundles in `$BUILD/v98/proof-*`, the final bundles are the assembler's)

| Twin (`$BUILD/k-*/`) | Wall | uImage | Decompressed | Size estimate margin | Bundle size gate margin | Loader chunks | kmods |
|---|---|---|---|---|---|---|---|
| `k-nfsdtrack` | 858 s | 17,776,402 B `3ddd2eba` | 27,017,104 B | 5,177,694 B | 5,243,375 B | 616 | 58, all rebuilt, 57 byte-equal to v9's (nfsd.ko differs) |
| `k-ud` | 850 s | 17,611,322 B | 27,003,120 B | 5,356,758 B | 5,422,439 B | 611 | 45 (13 built in), all rebuilt, none byte-equal |

k-nfsdtrack: kernel `.config` = v9's + `NFSD_LEGACY_CLIENT_TRACKING=y` only (+ the INITRAMFS_SOURCE path). k-ud: 56 symbols vs v9 (diet's
54 + UACCESS_WITH_MEMCPY + NFSD_LEGACY_CLIENT_TRACKING), every one named (KSTRICT); vs k-diet's `.config` exactly those two lines;
`__copy_to_user_memcpy`, `__clear_user_memset`, `nfsd4_umh_cltrack_init`, `nfsd4_legacy_tracking_init` in System.map; keep lists
37 lines + the six NAS modules (built in) read back. Offline (0 fetch lines), source tree unchanged (find -newer 0), both.
Proof bundles (TEST key): `-ud`, `-nfsdtrack`, `-xoroff-ud`, default (kernel.bin `9079a0d5` = v9.4's), each bundle gate OK; each
kernel.bin's head == its own tree's zImage; the nfsdtrack overlay == the default's (same xhci kmods). Refused as they must be:
ud unmarked / as diet / as uaccess / + nomemcg, nfsdtrack unmarked, diet as ud, ud and nfsdtrack flags on the v9 image. The new
gate on the five real v97 box bundles: each accepted under its own variant only (5/5 right, 30/30 wrong refused); patch-test on
those five with the new gate 33/33 each. Tests: bundle-gate 105/105, twin-variant 41/41, fragment-union 23/23, cmdline-arm 57/57.
