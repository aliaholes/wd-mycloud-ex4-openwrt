# The read-write trial bench (v8; v9: in bundle-v9, NFS off by default, the review's nits; v9.4: NFS block size, profiles; v9.7: NFSv4.2, the canary, instruments; v9.8: the user-copy canary, the nfsd start-wait, the variant wall; v9.9: the memory receipt + the nfsd prep)

Every trial up to v7 kept the data array read-only, so the one path the v7 kernel was built for was never
measured: RAID5 writes, whose parity the SoC's two XOR engines (`mv_xor`) can compute instead of the CPU. Run 10
proved both engines probe on the real box. This bench measures what they are worth, on the owner's word, inside one
bounded window, and leaves the array exactly as clean as it found it.

| File | Runs on | What |
|---|---|---|
| `box/ex4-rwbench.sh` | the RAM trial (busybox ash, root) | the walls, the rw switch, the local test, the servers, the samples, THE CLEAN STOP, the guard |
| `host/ex4-rwbench-client.sh` | a Linux box on the same LAN (bash, a normal user + sudo for two mounts) | drives the box over the trial's key-only ssh; runs the SMB / NFS copies; a trap that always ends in the clean stop |
| `tests/rwbench/` | the build box | `loop-test.sh` (real md + ext4 on loop devices, root), `stub-test.sh` (examine variants + the client), `conf-test.sh` (the image's own testparm), `patch-test.sh` (the three patches; v9.8: the variant wall), `variant-test.sh` (v9.8: that wall on tiny bundles), `patches/`, `captures/` |

Sizes are 1024-based throughout (MiB, GiB), the way the owner reads them.

**v9 in one paragraph.** The bench rides IN bundle-v9 (built with `EX4_RWBENCH=1`) and stays inert there: nothing
switches md1 read-write until someone types the per-session token. NFS is OFF unless the client is given `--nfs`
(and the box refuses `serve nfs` without `--unauthenticated-nfs`, which only that flag passes). Stock's two zero
files are KEPT by default (`--zap-zeros` to remove them during the trial; better: delete them under stock, where the
quota counts it). A stop that says "SAFE, but look" (rc 3) holds the reboot. SIGPIPE cannot kill the shell before its
stop; once the stop starts no signal leaves it half-way; servers never hold the bench's lock; the ext4 superblock's
three feature words are recorded at `up` and re-read after the unmount.

## What it measures

One session, in this order (the client does it all; each line is one row of `results.txt`):

1. **local**: `dd` 2 GiB of zeros into the array + `sync`, timed; caches dropped; read back. The file is removed.
2. **SMB A/B**: Samba 4 (P0 default) then ksmbd, one at a time, the same share, the same client: per engine N runs
   (default 3) of a 2 GiB write (with fsync) and a 2 GiB read (client remounted and the box's cache dropped first).
3. **NFS** (v9: only with `--nfs`): NFSv3 over TCP, the same N write + read pairs.
4. (only with `--zap-zeros`) stock's two leftover zero files go (below); the numbers are copied into the bench
   folder, THE CLEAN STOP runs, and the trial reboots back to stock (unless the stop said "look": then it stays up).

Around every copy the box records: MiB/s (the client's clock for network copies), the whole CPU's busy share split
user / sys / softirq / iowait, **CPU-ms per MiB** (busy% x 10 / MiB/s, the unit `v7-design/SERVING.md` uses), the
**`mv_xor` interrupt count of each engine** (a non-zero delta during a write is the proof that the engines carried
work), and **MiB written to the four members vs to md1** (about 4/3 for full-stripe RAID5: the parity is real).

Stock's numbers to beat (bench of Nov 17 2026, same box, client: the client box, mount options not recorded): SMB write
**37.0 MiB/s at 100% CPU (27.0 ms/MiB)**, SMB read **81.1 MiB/s (~10 ms/MiB)**, local RAID5 write 88.4 MiB/s.
The bar (PLAN.md): SMB write >= 50, read >= 81. The A/B rule was written before any number (SERVING §1.4): ksmbd
replaces Samba for bulk shares only if it is >= 15% better on write AND on CPU per MiB.

## How to run it (run 11)

1. bundle-v9 already carries the bench (`EX4_RWBENCH=1 sh build/v9/build-v9.sh bundle ...`; the three patches of
   `tests/rwbench/patches/` are in the tree since v9). Without that variable the overlay is byte-identical to one
   made by the mkoverlay of before the patch, and THE OVERLAY GATE checks which of the two a bundle carries.
2. Launch the trial as every run: `ex4-trial.sh check wdt`, `load-dry`, `go wdt`.
3. On the client (the build box, never the box that runs your other work):
   `sudo -v; bash host/ex4-rwbench-client.sh --box <trial address> --key <trial private key> --out <new folder>`
   (v9 defaults: Samba 4 then ksmbd, 3 runs each, NFS off, zero files kept, a 25-minute window. `--nfs` adds the NFS
   pair and widens the window to 40 minutes; `--zap-zeros` removes stock's zero files in the trial.)
   **Unattended (a systemd unit, no terminal): `EX4RW_SUDO` must KEEP the command's stdin.** The client pipes values into
   `$SUDO tee` (the client read-ahead, `--nfs-ra-kb` / `cra=`), so a wrapper that feeds the sudo password on stdin
   (`sudo -S < pwfile`) swallows the value: `tee` writes nothing and the client's read-back wall refuses (run 16B, a safe
   refusal). Use the askpass form instead: a wrapper that runs `SUDO_ASKPASS=<a script printing the password> sudo -A -k "$@"`
   (the build box, `$BUILD/run16/sudo-wrap2.sh` + `askpass.sh`; launched through one file holding the full environment, e.g.
   `run17/launch-client.sh`). Without `EX4RW_SUDO` at all, mount.nfs fails (run 16A1/16A2).
4. It prints a line like `echo 'EX4-RW 11-l2off-... 3fa9c2d1e0b7' > /tmp/ex4-rw-ok`. **You type that line
   yourself**, in your own ssh session on the box. Nothing writes that file for you. The client waits up to 15 minutes,
   then goes on by itself: up, local, the A/B, [NFS], [zeros], results, stop, home. If the stop says "SAFE, but
   look" (exit 3) the trial stays up and the client names the files to read first; reboot by hand after.
5. Receipts land in the `--out` folder (`results-client.txt`, `box-results.txt`, `box-journal.txt`, both examines,
   the box's dmesg) and in `Public/ex4-bench-v8/results.txt` on the array.

## Tuning arms (v9.3)

Run 13 measured our 6.12 trial against stock: served SMB writes already win (Samba 40.4, ksmbd 43.0 vs 37.0 MiB/s),
reads lose (Samba 57.2, ksmbd 73.1 vs 81.1), local write 49.7 vs 86.7, local read 77.8 vs stock's raw md1 read 111.
v9.3 lets ONE session measure the md knobs `perf/PERF-DESIGN-v2.md` names, reads included, against that baseline.

- **`up --skip-copy 0|1`** (client `--skip-copy`): md's `skip_copy`, written after the rw switch and BEFORE the ext4
  mount, read back, journalled. Never on a mounted array: ext4 takes stable pages from md at mount time, so a later
  switch leaves pages that can change under an in-flight write and parity silently wrong (`perf/LANE2-batching.md`
  §3.3; `raid5.c:7164-7172`, `fs/super.c:1596-1597`). `tune --skip-copy` is refused for that reason. One skip_copy
  value per session: compare skip_copy 0 vs 1 across two sessions, each with the same control arm.
- **`tune`** (only inside a session): `--stripe-cache 256..4096`, `--readahead-kb 128..8192` (md1 AND each member
  disk; WD sets 1024 on the members, `perf/LANE-platform.md`), `--group-threads 0..2`. Every argument is checked
  before anything is written; each value is read back; the journal gets "before -> after".
- **Given back.** `up` records every knob it may touch BEFORE changing any; THE CLEAN STOP (by hand, the guard, a
  trap or a reboot path) writes each back and reads it back before `mdadm --stop` (journal: "knobs restored (read
  back)"; anything that did not take is listed as NOT restored). All of it is RAM; a reboot resets it anyway.
- **Every results line** (local rows, sample ends) ends with `| knobs sc=.. gt=.. skip=.. ra_md=.. ra_members=..,..`.
- **`local` has a third row**: the raw md read by stock's own method (`dd if=/dev/md1 of=/dev/null bs=1M count=1024
  skip=8192`, `bench-2026-11-17/common.sh`), page cache dropped first, a read only. `local --label aN` prefixes the rows.
- **The client's `--arms "sc=256,ra=128,gt=0 sc=1024,ra=1024,gt=0 ..."`** runs after the baseline (local +
  `--engines` [+ NFS]) of the same session: per arm `tune`, the labelled local rows, then `--arm-engines`' write +
  read runs named `aN-ENGINE-wR/rR`. No `--arms` = the plan of before v9.3, exactly.
- **The window.** The client prices every MiB the plan moves at a conservative 30 MiB/s, plus fixed overheads
  (180 s base, 60 s + 20 s per copy for each engine pass, 30 s per arm), asks the box for max(25 or 40, that), and
  REFUSES a plan over the box's 45 minutes before touching anything, saying how many arms fit per session. Worked
  numbers: the default baseline (3 x 2 GiB, Samba + ksmbd) needs ~24 min; each local-only arm ~3.3 min (6 fit after
  that baseline, 11 with `--engines ''`); an arm with one engine at 3 x 2 GiB ~12 min (1 after the default baseline,
  3 with `--engines ''`).

Example, two sessions (each its own token):
`--skip-copy 0 --engines ksmbd --arms "sc=256,ra=128,gt=0 sc=1024,ra=1024,gt=0 sc=2048,ra=1024,gt=0 sc=1024,ra=4096,gt=0 sc=1024,ra=1024,gt=1"`
then the same with `--skip-copy 1`. Engine arms cost ~12 min each; pick the best local arm first, then spend engine
time on it. Proven off the box (the build box, `$BUILD/v93/`): see "Proven off the box" below for the counts.

## NFS block size, NFS arms, the profile verb (v9.4)

The next rungs of `perf/PERF-DESIGN-v2.md` §3 (N0/N5 max_block_size, R2's profile twin), built while run 14 measured
the v9.3 arms. Every default is the v9.3 plan exactly: no new flag = the same commands in the same order.

- **`serve nfs CLIENT --unauthenticated-nfs --max-block-kb 64|128|256|512|1024`** (client `--nfs-block KB`, needs
  `--nfs`): nfsd's `/proc/fs/nfsd/max_block_size` (bytes) is written after `servers_down` (no nfsd thread) and BEFORE
  `rpc.nfsd` starts any; the kernel's own value is recorded first, the new one read back and journalled. `serve`
  refuses (nothing changed) if nfsd is already running; `unserve` / THE CLEAN STOP stop nfsd first, then write the
  kernel's value back (read back). Every NFS results line ends with `| nfs max_block_size=N (set by --max-block-kb |
  kernel default)`. The client mounts with `rsize=wsize=KB*1024` (still `soft,timeo=600,retrans=4`). Run 13 measured
  NFSv3 at the 64 KiB default: write 35.8, read 69.8 MiB/s at ~71% busy.
- **`--arm-nfs`** (needs `--nfs` and `--arms`): the NFS write + read runs inside every arm (the same as `nfs` in
  `--arm-engines`), each with the same `--nfs-block`. Window: an NFS arm at 3 x 2 GiB costs ~12 min, so one fits
  after the NFS baseline (45 min); two are refused with the split advice.
- **`profile [--label L] [--mib N] [--top N]`** (client `--profile` after the baseline, `--profile-arms` after each
  arm, `--profile-mib N`): only while up, only on a kernel with `CONFIG_FUNCTION_PROFILER` (the v10b-prof twin; it
  mounts debugfs if it is not mounted and unmounts it after). On a kernel without it, it refuses with nothing written
  and the session stays up (the client then ends the run through its trap: clean stop, home). Caches dropped, the
  profiler on (which resets its counters), ONE labelled local dd write of N MiB (default 2048) + sync, the profiler
  off and read back, the write file removed; every `trace_stat/function*` merged per function (hits and time summed
  over CPUs), sorted by total time, top N (default 60) -> `profile-L.txt` (RAM, fetched by the client as
  `box-profile-L.txt`, copied into the bench folder by `results-to-share`). Results get the write row (labelled
  "PROFILER ON: counts only, never MiB/s") and a summary: top 5, the share of summed time in the xor path
  (`mv_xor*`, `async_tx*`, `async_xor*`, dma unmap) and in per-row / per-bio code (`raid5_*`, `__add_stripe_bio`,
  `submit_bio_noacct`, `blk_mq_*`, `blk_attempt_plug_merge`) (profiler times nest: shares, not wall time), and the
  `ops_complete_reconstruct` hits that R2's mean batch length divides by. THE CLEAN STOP writes 0 to
  `function_profile_enabled` whenever it exists, and `stop` runs even with nothing up while the profiler reads on.
  Window: each profile is priced at 10 MiB/s + 60 s (~4.4 min at 2 GiB).
- **The review's nits 1-3** (`../../v9-arms-REVIEW.md`): a knob that does not go back keeps `knobs.saved` (and a
  `knobs.partial-*` copy), so a later `stop` retries it (`stop` runs again whenever the record exists); skip_copy is
  never written on a mounted array, any value (journalled as "still mounted: not touched"); a member disk with no
  `read_ahead_kb` is journalled and left alone (not recorded, not tuned) instead of refusing `up`.

Not proven off the box: max_block_size on the 6.12 trial kernel and a real nfsd (the tests use a fake nfsd folder:
the kernel refuses the write while nfsd runs, the box checks the thread count itself first and reads the value back),
the function profiler itself (tests use a fake tracing folder with the kernel's trace_stat column layout; the build box's
own debugfs is never touched), and every number.

## NFS first-class: NFSv4.2, threads, client read-ahead, the data canary, instruments (v9.7)

Kurt's ruling (Nov 17 2026 23:55, verbatim): *"Prolly not jumbo frames. I only need NFS. Nothing uses SMB if it doesn't have
to."* The finished box is NFS-only, no jumbo frames; the bench keeps its SMB engines for comparison only (no new SMB work).
Every v9.7 piece is behind a new flag: with none of them, the client's plan and every box command are v9.4's exactly
(the stub test checks the order, the serve arguments and the mount options byte for byte).

- **`serve nfs CLIENT --unauthenticated-nfs [--vers 3|4.2] [--threads N]`** (client `--nfs-vers`, `--nfs-threads`). 4.2 =
  NFSv4.2 ONLY: no rpcbind and no statd (no NLM: v4 locks in-protocol), `rpc.mountd -N 2 -N 3` (the kernel's export
  upcalls only, no MOUNT listener), the bench folder exported as the v4 pseudo-root (`fsid=0`; the client mounts
  `BOX:/`), `rpc.nfsd -N 3 -N 4.0 -N 4.1 -V 4.2`. After the start the box reads back `/proc/fs/nfsd/versions` (must hold
  `-3 +4 +4.2 -4.0 -4.1`, never `+2`/`+3`) and `/proc/net/tcp{,6}` + `udp{,6}` (nothing on 111 / 32778 / 32779 / 32780,
  something on TCP 2049): either failing = refused + THE CLEAN STOP. The same address trust as v3 (sec=sys), the same
  `--unauthenticated-nfs`, one client, `sync`, `all_squash` to the bench account, `secure`. nfsd's v4 grace
  (`nfsv4gracetime`) is set to 10 s before any nfsd thread (recorded, read back, given back at unserve / the stop),
  and the client does one untimed create + remove after every v4.2 mount, so the grace never lands inside a timed
  copy. `--threads 1..16` = the threads rpc.nfsd starts (default 8, v9.4's), read back. Results lines carry
  `vers=... threads=...` only when either was asked for.
- **Client-side** (FABLE-OPT F2): `--nfs-ra-kb N` (128..16384) writes THIS machine's `read_ahead_kb` on the NFS mount's
  bdi (`/sys/class/bdi/MAJ:MIN`, from `mountpoint -d`) after every mount, reads it back, and writes the value it found
  back before every unmount (also in the trap). `--nfs-rsize` / `--nfs-wsize` (KiB, 32..1024 powers of 2) each on its own;
  default = `--nfs-block`, as v9.4.
- **NFS arm keys** (with `--arm-nfs`): inside `--arms`, `nv=3|4.2`, `nt=N`, `cra=N`, `rs=KB`, `ws=KB` per arm; nv / nt reach
  the box through that arm's own unserve + serve, cra / rs / ws that arm's mounts. An arm may name only NFS keys (no
  `tune` then; its `== arm` line says "no box knob").
- **THE DATA CANARY** (`--canary`; ON by itself whenever any v9.7 NFS option or arm key is given; `--no-canary` turns it off
  for a like-for-like v9.4 comparison): before the token, the client makes a seeded, non-zero pattern file of `--mib`
  MiB (block i starts with i and the seed; the rest Python's seeded PRNG) and md5s it. Every NFS write copies that file
  (md5 as written); after the unmount the box md5s what landed (`md5 NAME`, untimed); the timed read-back is md5'd as it
  is read. Any of the three differing = a `CANARY FAIL` row in `results-client.txt` and the clean stop (the file stays in
  the bench folder to look at). (v9.8, the v95 review's nit 3) It is a TRANSPORT canary: the box's md5 reads through the
  box's page cache, so it proves the server kept and returned what it accepted, not the platters, and nfsd's copies are
  in-kernel (no copy_to_user / copy_from_user): it does NOT check a user-copy option (F3); `--ucanary` does. The pattern is removed at the end; `client.log` keeps its seed + md5 (the seed remakes it).
  Window: + the box's md5 read of every NFS write at 30 MiB/s (~3.4 min for 3 x 2 GiB): the run-15 shape (NFS baseline +
  one NFS arm at 3 x 2 GiB) no longer fits 45 min with the canary on; split it (`--engines ''` or a lower `--runs`).
- **`--instruments`** (FABLE-OPT §2.0): `facts` once after `up` (read-only: cpuinfo, `clk_summary` with debugfs mounted
  read-only for the read if it is not, cpufreq, each NIC's driver / mtu / speed / rps / GRO knobs, mv643xx_eth / sata_mv
  module parameters, `/proc/interrupts`, nfsd's knobs -> `box-facts.txt`); around every client copy, outside its timed
  window, `xsnap begin|end NAME` (ctxt, NIC / sata / xor interrupts, softnet processed / dropped / squeezed, nfsd
  `pool_stats` columns, `/proc/vmstat`: every nonzero delta in `xstat-NAME.txt`, fetched as `box-xstat-NAME.txt`, one
  summary line per copy in the results) and this machine's `/proc/self/mountstats` entry before and after
  (`mountstats-NAME.a/.b.txt`). + 15 s per copy and 30 s for facts in the window.
- **Owed fixes from run 15:** `check_trial`'s inputs are variables (real `/proc`, `/etc`, `uname -r`, `pidof ex4fan` on the
  box; a fake root only under `EX4RW_TEST=1` + `EX4RW_TEST_TRIAL`), and the stub test runs the xor-off truth table (8/8
  plus the near-miss `-xoroffx`) and the other refusals through it. The max_block_size nit: when the kernel's value was
  0 (auto) it is never written back (a written 0 is clamped to 1024 BYTES); unserve says so ONCE as an INFO line and
  later NFS lines say the value was left by an earlier `--max-block-kb`. `patch-test.sh --variant` passes a bundle's
  variant to every v9 overlay-gate call (the profile twin's overlays now pass as `--variant prof`). `mkrelease.py`
  refuses any bundle with a VARIANT file (listed in MD5SUMS or not): a release is only ever built from a default bundle.

Not proven off the box: NFSv4.2 on the 6.12 trial kernel with the image's nfs-utils 2.8.4 (the tree's kernel config has
`CONFIG_NFSD_V4=y` but no `NFSD_LEGACY_CLIENT_TRACKING` and the image has no `nfsdcld`: nfsd will warn that it cannot
track clients and may take some seconds to start; the box's read-backs catch a wrong version set or an open door, they
cannot make a missing feature work), the real `/proc/net` listener table, `pool_stats`' column set on 6.12, the
client's bdi read-ahead on a real NFS mount, and every number.

## The user-copy canary, the nfsd start-wait, the variant wall (v9.8)

Kurt, Nov 18 2026 12:45 (verbatim): *"Good morning, love. Go for whatever makes it awesome."* (answering three calls: the
kernel option over the nfsdcld package, a combined uaccess+diet twin, and the uaccess repeat with a user-copy canary first).
Every v9.8 piece is behind a new flag except the start-wait, which is a fix: with no new flag the client's plan and every
box command are v9.7's.

- **`ucanary NAME --md5 HEX`** (box) / **`--ucanary`** (client; needs `--nfs`, turns the canary on, refused with
  `--no-canary`): THE USER-COPY CANARY, FABLE-OPT §6's "F3 user-copy option: odd-block-size read md5 x 4" (NFS-only, so no
  Samba leg). Once per session (one kernel per session), right after the FIRST canary'd NFS write's box md5 said OK and the
  client unmounted, untimed: the box reads that file with busybox `dd` at four odd block sizes (4093, 65521, 131071,
  1048573 bytes: every last block partial) into `md5sum`, then copies it file to file with `dd bs=65521` (copy_to_user AND
  copy_from_user), syncs, and md5s the copy; the page cache is dropped (sync + drop_caches) before every pass. Every md5
  must be the pattern's. Rows: one per read, one for the copy, then `ucanary NAME OK: ... kernel K; N s on the box` in
  the box's `results.txt` and the client's `results-client.txt`. Any mismatch = a `CANARY FAIL ucanary` row on the box and
  a `CANARY FAIL ucanary-NAME` row on the client, then THE CLEAN STOP (the source file stays; a bad copy is kept to look
  at; a good copy is removed). It tests whichever kernel runs (stock-config v9, k-uaccess, k-diet, the coming `ud` twin).
  Refusals before anything (session stays up): bad name, a name ending `-ucopy.bin`, md5 not 32 lower-case hex, a missing
  file or a symlink, its copy's name already there, less free space than the file + 64 MiB (`df -Pk`). **Cost:** the box
  reads the file 6 times and writes it once. Window price (the house rule, 30 MiB/s): 7 x 2048 / 30 + 30 = **507 s
  (~8.4 min) per 2 GiB** (a plain `--nfs --runs 3 --mib 2048` goes 36 -> 45 min with it: it still fits). Expected on the box: ~33 s per md5-bound read (the v9.7 md5 of 2 GiB took 33 s in run 16, md5sum
  ~62 MiB/s on the Feroceon) x 5 + the copy (~30-45 s at local write speed) = **~200-230 s**; at a ~100 MiB/s disk, if md5
  kept up, 7 x 20.5 s = ~143 s. The run-17 shape (local + NFS baseline + one NFS arm at 3 x 2 GiB, canary, instruments,
  38 min) plus `--ucanary` is priced ~46 min: over the 45-minute window, REFUSED before any ssh; split it (e.g. `--runs 2`,
  or the arm in its own session).
- **The nfsd start-wait** (a fix; run 17D: `rpc.nfsd did not start` while dmesg showed `NFSD: Unable to initialize client
  recovery tracking! (-110)` / `Is nfsdcld running? If not, enable CONFIG_NFSD_LEGACY_CLIENT_TRACKING`, and nfsd came up a
  moment later): every `serve nfs` (v3 and v4.2) makes `/var/lib/nfs/v4recovery` 0700 root when it is missing (the legacy
  client tracking's directory: the kernel option, not the nfsdcld package, is the chosen fix; no install), keeps rpc.nfsd's
  stderr (`nfs/rpc.nfsd.out`, fetched with the receipts) and its rc, then polls once a second for up to 30 s until nfsd is
  REALLY up: `threads` > 0 AND something listening on 2049. rpc.nfsd's rc != 0 is taken only when nfsd then runs exactly
  the threads asked for (else refused); not up after 30 s = refused + THE CLEAN STOP, naming what was missing and the client
  tracking. The serve line always ends `| nfsd up after N s (rpc.nfsd rc R, threads T, 2049 listening); client tracking:
  X; v4recovery ...`, X read from the kernel lines logged since the start (`legacy` / `nfsdcld` / ... from "Using ... client
  tracking operations", `NONE (unable to initialize (-110) ...)`, or `not reported`). The box's syslog lines for nfsd /
  mountd land in `nfs/syslog.out`. Results lines are unchanged.
- **The nfs-utils socket wall** (v95 nit 1, v4.2): besides 111 / 32778-32780 closed and 2049 open, no socket held by an
  nfs-utils process (`rpc.mountd`, `rpc.statd`, `rpcbind`, `rpc.nfsd`, `nfsdcld`, `rpc.idmapd`, `rpc.gssd`, `rpc.svcgssd`,
  `blkmapd`: their `/proc/PID/fd` socket inodes matched against `/proc/net/{tcp,tcp6,udp,udp6}`) may listen (TCP LISTEN,
  any bound UDP) on a non-loopback address on any port but 2049: a random-port mountd is refused + THE CLEAN STOP. Loopback
  sockets and other daemons (dropbear, uhttpd) are not its business.
- **THE VARIANT WALL in patch-test** (the v95 must_fix, the test half; the gate half stays owed in `overlay-gate.py`, not
  this lane's file): with `--bundle`, before anything runs, the bundle's own VARIANT file must agree with `--variant`. No
  VARIANT file = a stock bundle, taken only with no `--variant` or `--variant stock`; a VARIANT file (regular, not a symlink,
  with a non-empty `VARIANT=` line that is not `stock`) needs `--variant` equal to its first `VARIANT=` value; the RUNID
  suffix must be that variant's (`-xoroff-diet` for `xoroff+diet`, none for stock); `--variant` without `--bundle` is
  refused. `tests/rwbench/variant-test.sh` runs the assembler's whole matrix on tiny fake bundles (each taken only under its
  own name: bwd-as-stock, bwu-as-diet, bwp2-as-prof and the rest now REFUSED) plus every file edge case.

**Proven off the box (v9.8, the build box, `$BUILD/v98/`, Nov 18 2026 run 2; box script bab36ef3, client 0f0f0b09, patch-test
0beb9ca6):** `loop-test.sh` **237/237 under the host BusyBox v1.36.1 ash and 237/237 under the image's BusyBox v1.37.0 (ARM,
qemu-arm)** (v9.7's 206 + 31: ucanary refusals x 13, pass on 3 MiB and on a 100003-byte file, the FAIL path with THE CLEAN
STOP and the source kept; the start-wait slow / rc 1 taken / rc 1 short refused / never up refused; client tracking NONE /
legacy / not reported; the nfs-utils socket wall pass + random-port mountd refused); `stub-test.sh` **161/161** (+10: the
`--ucanary` order, once per session, FAIL, refusals, window); `variant-test.sh` **55/55** (the 35-cell matrix + 20 edge
cases); `conf-test.sh` 21/21; `patch-test.sh` 33/33 on the v97 bw bundle with `--variant stock` and 33/33 on bwu with
`--variant uaccess`, and bwd with `--variant stock` REFUSED by the variant wall. Not proven: any of it on the EX4 (a real
nfsd's start time and client-tracking lines on 6.12, a real ucanary's seconds, the socket wall on the box's /proc).

**Proven off the box (v9.7, the build box, `$BUILD/v97/`, Nov 18 2026; box script md5 a1391d5f, client 36617182):**
`loop-test.sh` **206/206 under the host BusyBox v1.36.1 ash and 206/206 under the image's BusyBox v1.37.0 (ARM, qemu-arm)**
(168 + 38, run 2; run 1 caught the pool_stats header read one column off: fixed); `stub-test.sh` **151/151** (93 + 58:
the check_trial truth table 8/8 + `-xoroffx` + 5 refusals on a fake /proc, the v9.7 client flags, arm keys, the canary
pass and FAIL paths, instruments, the window); `conf-test.sh` 21/21; `patch-test.sh` 32/32 on the v94 default bundle,
32/32 on the xor-off bundle with `--variant xoroff`, 32/32 on the profile twin with `--variant prof` (30/32 without it,
as before: the control); `tests/update/run.sh` 102/102 (+ 3 VARIANT refusals).

## The memory receipt + the nfsd prep (v9.9)

Runs 18A (arm start, 2 of 8 threads) and 19A (the session's FIRST start, 6 of 8) were refused with `rpc.nfsd: error starting
threads: errno 12 (Out of memory)` and no allocation-failure splat; 18A's baseline start got 8 of 8. Read from our kernel's
own source (OpenWrt 6.12.112): each nfsd thread's `svc_init_buffer()` takes its `rq_pages` in ONE `alloc_pages_bulk` call
of max_block_size / 4 KiB + 2 order-0 pages (258 at `--max-block-kb 1024`), and that call only succeeds while the zone's
free pages exceed its LOW watermark + that count: the bulk allocator never reclaims page cache for more than one page, and
its failure is silent. After the local rows the page cache fills the 497 MiB and kswapd parks free memory between the low
and high marks, room for a few such threads, then luck.

- **Every `serve nfs`, right before rpc.nfsd (v3 and v4.2):** a MEMORY RECEIPT, `nfs/memrcpt-start<N>-before.out` (a kept
  server log, fetched with the receipts): MemFree / MemAvailable / Cached / Slab..., `vm.min_free_kbytes`, every zone's free /
  min / low / high / managed pages, `/proc/buddyinfo`, the 10 biggest slab caches (`/proc/slabinfo` when the kernel has it;
  our 6.12 kernel has no CONFIG_SLUB_DEBUG, so `/sys/kernel/slab` (partial + cpu slabs), labelled a LOWER bound), and the
  fit: how many of the asked threads the bulk fast path fits at that moment. Then **sync + drop_caches** and the receipt
  again (`-after`). A refused start also writes `-refused` (the memory as the refusal found it) before THE CLEAN STOP. Each
  receipt is one journal line; the serve line ends `; nfsd prep: start N: sync + drop_caches (MemFree A -> B kB)`. Results
  lines are unchanged. The client is unchanged (it passes no new flag).
- **`--nfsd-prep every|second|off`** (box, `serve nfs` only): `every` = the default (19A proved a first start fails too);
  `second` = only from the session's second start (run 18's narrower reading); `off` = receipts only, caches kept.
- **Why drop_caches and not the other candidates:** fewer threads or a smaller max_block_size change the server being
  measured; one nfsd start per session would not have saved 19A (a first start); compaction adds no free pages for an
  order-0 call. drop_caches changes nothing measured: the client already drops the cache before every NFS read pass.

## The walls

The full list is the header of `box/ex4-rwbench.sh` (eleven walls since v9.3); each is a `die` line in the code and a test.
The short form:

- **The token.** A fresh 12-hex nonce per `arm`; the file must be root-owned, a regular file, one line, typed after
  the arm, holding exactly the printed line; `up` renames it away (one token = one session). A stale token from an
  earlier arm or boot cannot pass.
- **Every reboot path stops md1 first.** The S99 auto-return, the S03 deadman, procd's shutdown (`K01ex4-rwstop`)
  and ex4fan's fail-safe all run `ex4-rwbench stop --for-reboot` first; the bench refuses to start unless all four are
  in place and `/usr/sbin/ex4-rwbench` is byte-identical to the script being run.
- **A clean array or nothing.** Four SATA partitions 2; superblock 1.0, raid5, 64K, left-symmetric, 4 devices;
  Feature Map 0x0 or 0x1; State clean; Array State AAAA; one Events count; roles 0-3; no resync / recovery / reshape
  line; no md bad blocks; no member read-only in the kernel. Then assembled `--readonly` first and checked again in
  `/proc/mdstat`.
- **A clean file system or nothing.** The ext4 superblock is read (1 KiB, never written by us): magic, VALID, no
  ERROR, a journal, needs_recovery CLEAR, empty orphan list. A dirty one stays with stock.
- **Nothing sync-shaped.** `sync_action` = `frozen` before the switch to read-write, re-checked after it.
- **Only our folder.** `Public/ex4-bench-v8/` (refused if it exists). The mount: `rw,noatime,data=ordered,barrier=1,
  errors=remount-ro,noinit_itable,stripe=128` (stock's stripe hint; a mount option writes nothing). No fsck, no
  tune2fs, no resize, no quota rewrite. `vm.dirty_bytes` 64 MiB / background 16 MiB while rw (restored after).
- **Bounded.** The guard stops by itself after the rw window (v9: `up --window-min`, 5..45; the client asks 25 for
  local + Samba 4 + ksmbd, about twice what those take at stock's 37 MiB/s write, and 40 with `--nfs`), after 8 min
  without a client heartbeat, on any md / disk / ext4 error line in the kernel log, or if ex4fan dies. The client's
  heartbeat runs every 30 s; every copy runs under `timeout -k 15` (4 MiB/s + 2 min), and NFS mounts `soft`.
- **Every exit path stops.** Every rw command runs the clean stop on failure or signal; the client's trap runs it on
  every way out and reboots only after it says SAFE (rc 0; rc 3 holds the reboot for a human).
  v9: SIGPIPE is ignored in both halves (a dead ssh link makes output fail, never kills the shell before its stop);
  inside THE CLEAN STOP, HUP / INT / TERM are ignored until it is done, and the stop no longer kills the guard (the stop
  lock serialises two stops; if a stop ends UNSAFE, the guard is still there).
- **Servers: one client, a password, the bench folder only.** A random per-session password (RAM, 0600, never on a
  command line: smbpasswd / ksmbd.adduser read it on stdin), `hosts allow` = the client address only, `map to guest =
  never`, `restrict anonymous = 2`, SMB2+, root refused, the share not browseable. The servers are started with the
  bench's lock files closed (v9), so a running server never holds the command lock. NFS is different, see below.
- **No unauthenticated listener by default (v9, the review's must_fix).** `serve nfs` is refused unless it is given
  `--unauthenticated-nfs`; the client passes that only with `--nfs`.

### THE CLEAN STOP

servers down (by recorded pid and, on the box, by name) -> `sync` -> `umount` (3 tries; between tries every
process with a cwd, root or open file under the mount is named in the journal and killed) -> if still mounted:
remount read-only -> `mdadm --stop` -> verify: nothing mounted rw, md1 gone or marked clean, every member examined
again (State clean, AAAA, one Events count; the counts before/after go in the journal). v9: between the unmount and
`mdadm --stop`, the ext4 superblock is read again (a read): it must be clean (VALID, no error, no needs_recovery, no
orphans) with the same compat / incompat / ro_compat words `up` recorded, i.e. the 6.12 kernel left nothing stock's
3.2.40 kernel cannot mount. Exit 0 = SAFE, 3 = SAFE but look (a member's examine or that superblock looks wrong after
the stop; the client then holds the reboot), 1 = UNSAFE. Only SAFE (0 or 3) removes the marker the reboot paths wait on.

**The one deliberate exception:** ex4fan's thermal / fan fail-safe gives the stop 120 s, then reboots even without a
SAFE: a drive at 55 C or a fan that does not turn outranks a resync. md's own reboot notifier
(`drivers/md/md.c:10044` in the v7 tree: `__md_stop_writes` + safemode 2) still marks the array clean after the
`sync()`, so the likely cost is an ext4 journal replay, not a resync. Every other path waits.

## What it changes on the array

- md1's superblocks: the Events count rises (assemble rw, the stop) on all four members together.
- The ext4 superblock: mount count / mount time / bytes written, and the journal while mounted. Clean on unmount.
- `Public/ex4-bench-v8/` with `README.txt` and `results.txt` (small; safe to delete). Every big test file is
  removed after its test.
- **Stock's `Public/ex4-bench/bench-2g.bin` + `bench-write-2g.bin` are KEPT by default (v9).** The trial has no quota
  accounting (stock mounts with `usrquota,grpquota`; the image has no `quotaon`), so removing them in the trial would
  leave stock's usage figure for their owner up to 4 GiB high until a quotacheck. **Delete them under stock
  afterwards** (its own SMB share or ssh), where the quota counts it: the same result, no drift.
  `--zap-zeros` removes them in the trial instead, only after: the folder and both files are real (no symlink), each
  exactly 2147483648 bytes, one hard link each, and `cmp` against `/dev/zero` reads every byte as zero. Anything
  else: nothing is removed. The folder itself always stays (v9: the files were asked gone, not the folder). That
  check reads all 4 GiB (busybox `cmp`): estimated 1-3 minutes on this CPU, not measured.
- Our own files are created and removed (net zero), with or without quotas.

## Residual risk, plainly

**A hang, a watchdog reset or a power cut WHILE a copy is writing.** Nothing in software covers that. md1 has no
write-intent bitmap, so a dirty stop means stock's next boot resyncs the whole array: 3.9 TB per disk at the
~110-120 MiB/s these drives read, about **9-10 hours** of a slow box with no redundancy margin (an estimate: stock's
resync speed was never measured). ext4 replays its journal at the next mount (seconds). What can be lost: the last
few seconds of a bench file (at most 64 MiB in flight, the dirty cap), never his files (we write none). md marks the
array clean 200 ms after the last write (`DEFAULT_SAFEMODE_DELAY`, `md.c:118`), so a crash between copies costs
nothing: the exposure is the copy windows themselves, a few minutes in a session. Evidence for the watchdog: runs 9
and 10 held the CPU at 100% for ~40 s (network receive) without a reset; a whole RAID5 write at 100% CPU has not been
run on this box before, and that is exactly what this bench is.

**Recovery, if the box does not come back by itself:** power-cycle; stock boots from the untouched flash. Then, on
stock: `cat /proc/mdstat` (a `resync` line = the 9-10 h case; let it finish, do not interrupt it, the data is
intact), `mdadm --examine /dev/sd[abcd]2 | grep -E 'Events|State'` (four equal counts), and the trial's own disk log
(`ex4-trial.sh log`) says how far the bench got.

**A new write error on a disk during the bench.** md may fail that member (the array goes degraded); the guard sees
the kernel line and stops at once; stock rebuilds. The known unreadable sector on bay 4 (LBA 7811940664) sits in
`sdd3`, past the end of `sdd2` (sector 7811938304): md1 never touches it, and nothing here reads or scrubs it.

**NFS authenticates by address only, so it is OFF by default (v9).** NFSv3 with `sec=sys` trusts the client's IP
and the uid it claims; there is no password in the protocol. That breaks the wall "every LAN listener
authenticates", so it runs only when the client is given `--nfs` (Kurt's call per session), and the box refuses
`serve nfs` without `--unauthenticated-nfs`. When it does run: the bench folder to the one client address, every
client user squashed to the bench account, rpcbind / statd / mountd / nfsd on the LAN only for those copies. A real
NFS service on this box (P0) will need the same honesty in its UI.

**The token stops accidents, not root.** Anyone already root on the trial can do anything; the token makes sure a
read-write session never starts by mistake, by a stale command, or from a script.

## Proven off the box vs not

Proven on the build box, all in ONE suite run on the final v9 tree (the build box, `$BUILD/v9/suite-1/`, Nov 17 2026),
the script being exactly `/usr/sbin/ex4-rwbench` of bundle-v9 (md5 500609e7):
- `loop-test.sh`: **92/92 under the build box's BusyBox v1.36.1 ash** (Ubuntu's) and **92/92 under the IMAGE's own
  BusyBox v1.37.0 ash** (ARM, qemu-arm, the v9 rootfs) (78 v8 cases + 14 for the v9 changes; as a positive control
  the v8 script run against the same v9 test fails exactly those 14);
- `stub-test.sh`: 42/42 (dash + the build box's busybox applets); `conf-test.sh`: 17/17 (the image's Samba 4.22
  testparm and ksmbd tools under qemu-arm); `patch-test.sh`: 32/32 (in-tree result, ARM build, the v9 overlay gate).

What those cover: every wall above against a real md RAID5 (superblock 1.0, 64K, left-symmetric, 4 members) and a
real ext4 on loop devices; the clean stop with a live holder; the trap on SIGTERM mid-command; the guard on window
/ heartbeat / kernel-log; SIGKILL covered by the guard; the zeros' every refusal; the examine walls on real captures
edited one field at a time; the smb.conf loaded by the image's own Samba 4.22 testparm with no warning;
ksmbd.adduser taking the password on stdin; the patched overlay (byte-identical without `--rwbench`) and
`ex4_rw_wait` cut out of it; the client's every refusal and exit path against a fake trial; (v9) `serve nfs` refused
without its flag, the window argument, a stop whose output pipe is already closed, TERM + HUP + INT sent into a busy
stop, the ext4 feature words before and after, the zero folder kept, the client holding the reboot on rc 3.

**v9.3 (tuning arms), the build box, `$BUILD/v93/` (Nov 17 2026), box script md5 78f34b66, client 9359bbf6:**
`loop-test.sh` **125/125 under the host BusyBox v1.36.1 ash and 125/125 under the image's BusyBox v1.37.0 (ARM,
qemu-arm)** (the 92 v9 cases unchanged + 33 new: skip_copy refused when malformed, written after the rw switch and
before the mount, refused through `tune` once mounted; the knob record; 11 `tune` refusals that change nothing; `tune`
read back by the test; labelled local rows + the raw md read, a read only; knobs on every results line and in
`status`; THE CLEAN STOP's restore read back BY THE TEST between the restore and `mdadm --stop`, member read-ahead
after it; the guard's stop restoring too; fsck clean after a skip_copy=1 session); `stub-test.sh` **67/67** (42 + 25:
`--arms` order and labels, 11 malformed specs refused before any ssh, `--arm-engines` / `--skip-copy` refusals, two
window refusals with the split advice, the window growing to the plan, the default plan unchanged at 25 min);
`conf-test.sh` 21/21; `patch-test.sh` 32/32. Not proven off the box: the knobs on the 6.12 trial kernel (the build
box runs 7.0; the box reads every value back and stops if one does not take) and every number.

**v9.4 (NFS block size, NFS arms, profiles, nits 1-3), the build box, `$BUILD/v94/` run 2 (Nov 17 2026), box script md5
a44951f0, client cc3b10db:** `loop-test.sh` **168/168 under the host BusyBox v1.36.1 ash and 168/168 under the image's
BusyBox v1.37.0 (ARM, qemu-arm)** (125 + 43: max_block_size refused when malformed / on SMB / without the NFS flag /
while nfsd runs, written before the fake nfsd starts and journalled in that order, carried on NFS lines only, given
back at unserve, untouched by default; `profile` refused before a session and on a kernel without the profiler with
nothing written, 9 malformed-argument refusals, the profiler read 1 during the write and 0 after, two per-CPU stat
files merged and sorted, the hits-only format, the summary, `results-to-share`, THE CLEAN STOP turning a left-on
profiler off (also with nothing up), SIGTERM mid-profile; nit 3 up + tune with a member lacking read_ahead_kb; nit 1
the record kept, retried by a second stop, restored once possible; nit 2 skip_copy untouched while a submount holds the
mount, then written back after the unmount, read by the test during the stop). Run 1's ARM pass caught the image's
busybox ignoring `r` on a multi-key `sort -k`: the merge now sorts zero-padded keys with a plain `sort -r`.
`stub-test.sh` **93/93** (67 + 26); `conf-test.sh` 21/21. `patch-test.sh` not run by the code lane (it needs a bundle).

Not proven until run 11: smbd / ksmbd / nfsd actually serving on the box (no SMB or NFS server ran here: the network
copies were faked in the client test), the `mv_xor` interrupt delta under a real md write, `mdadm --readwrite`
keeping `sync_action` frozen on the 6.12 kernel (shown on the build box's 7.0 kernel; the box re-checks it and stops
if not), the box's real `blockdev` / ata topology in `members()`, the numbers themselves.

## The patches (in the tree since v9)

`tests/rwbench/patches/` holds the v8 bench lane's diffs as the record of what was applied; v9 applied
`mkoverlay-rwbench.diff` and `ex4fan-rwbench.diff` (rebased onto the ex4fan.c of the panel lane: offset 3, no
conflict) and carried `build-v7-rwbench.diff`'s one line into `build/v9/build-v9.sh`, plus one v9 change of its own:
the overlay stamp says ` rwbench=1` when the bench rides in (so the v8 overlay gate refuses such an overlay).
`patch-test.sh` checks the result in the tree (it no longer applies anything).

- `mkoverlay-rwbench.diff`: `--rwbench FILE` (needs `--kmods`): `/usr/sbin/ex4-rwbench`, `ex4_rw_wait` in S99 and S03
  before every reboot, `/etc/init.d/ex4-rwstop` + `K01`. Without the flag, nothing changes.
- `build-v7-rwbench.diff`: passes `--rwbench` only when `EX4_RWBENCH=1`.
- `ex4fan-rwbench.diff`: `rw_stop_for_reboot()` in the supervisor's `do_reboot`, before `sync()`.
