# "What's this NAS for?": tuning profiles

One choice on the Storage page (and the last question after claiming the box): **Movies & big files**, **Many
users & small files**, **Backups (Time Machine / rsync)**, or **Balanced** (the default). Each profile is a small,
named set of settings of the RUNNING system. The page lists exactly what each one changes, what it costs in memory,
and why. Everything is live and can be taken back. Nothing on the disks is reshaped, checked or erased.

**State: built and tested OFF the box (fake /sys and /proc trees, the image's own busybox, uci and Samba testparm
under qemu-arm). Never run on an EX4.** No profile claims to be faster until the read-write bench has measured it
on this box. Until then the page says "Faster? Not measured on this box yet."

Sizes are 1024-based (KiB, MiB), as the owner reads them.

## The box these settings are for

Marvell Kirkwood (one Feroceon 88FR131 ARMv5TE core, ~1 GHz), 512 MB RAM, 4x WD40EFRX in RAID 5 (64 KiB chunk,
left-symmetric, superblock 1.0, no write-intent bitmap), ext4. Linux 6.12.112 (our kernel), Samba 4.22.7, ksmbd-tools 3.5.6,
busybox 1.37.0. The CPU is the limit. Receiving over the network takes 100% of it at ~55 MiB/s (run 10). For big
files, what Samba costs per byte matters more than any disk setting. Stock's numbers: SMB write 37.0 MiB/s
(27 ms of CPU per MiB), read 81.1 MiB/s (stock's bench, Nov 17 2026).

## The profiles (each is Balanced plus its own lines; `ex4-profile show NAME` prints this from the files)

**Balanced**: the kernel's and Samba's own settings, plus two:
| Setting | Value | When | RAM held | Why |
|---|---|---|---|---|
| vm.dirty_bytes | 64 MiB | live | 0 | at most 64 MiB waiting to be written (kernel default: ~20% of free memory, ~94 MiB here, estimated): less lost in a power cut, shorter stalls. The rw bench's own cap |
| vm.dirty_background_bytes | 16 MiB | live | 0 | background writing starts at 16 MiB (kernel default ~10%, ~47 MiB, estimated): a steadier stream |

**Movies & big files** (Balanced, plus):
| Setting | Value | When | RAM held | Why |
|---|---|---|---|---|
| md1 read-ahead | 6 MiB | live | 0 (page cache in flight) | 32 full stripes of 192 KiB, against the kernel's 384 KiB (2 x io_opt): keeps four disks busy on one stream |
| md1 stripe_cache_size | 2048 | live* | **32 MiB** | kernel default 256 = 4 MiB (stock's 32 KiB pages made its 256 hold 32 MiB): more full-stripe writes, fewer parity reads |
| vm.dirty_background_bytes | 32 MiB | live | 0 | bigger batches reach the array; the 64 MiB ceiling stays |
| ext4 atime | noatime | mount | 0 | reading never writes back the time a file was last read |
| ext4 commit | 30 s | mount | 0 | fewer journal flushes in a long write. **A power cut can lose up to 30 s of new writes**, nothing older |
| Samba use sendfile | yes | server | 0 | reads skip the copy through smbd. **Only for clients that do not sign** (below) |
| Samba min receivefile size | 16384 | server | 0 | writes >16 KiB skip the copy through smbd. Same signing caveat |
| Samba aio read/write size | 0 / 0 | server | 0 | one core: reads and writes happen in smbd itself, with no handoff to a thread pool and back |
| opt-in **spindown**: disks sleep | after 20 min | drive | 0 | first access waits ~10-30 s while four disks spin up; frequent sleep/wake cycles wear drives. Off by default |

**Many users & small files** (Balanced, plus):
| Setting | Value | When | RAM held | Why |
|---|---|---|---|---|
| md1 read-ahead | 128 KiB | live | 0 | a small file does not pull its neighbours off the disks |
| md1 stripe_cache_size | 1024 | live* | **16 MiB** | small writes read old data + parity first; a bigger cache keeps them for the next write nearby |
| disk scheduler | mq-deadline | live | 0 | **not in this kernel** (it offers only `none`): reported as such, applied only on a kernel that offers it |
| vm.dirty_bytes / background | 32 MiB / 8 MiB | live | 0 | a save or a sync never waits behind much |
| vm.dirty_expire_centisecs | 15 s | live | 0 | kernel default 30 s: a shorter window in a power cut |
| vm.vfs_cache_pressure | 50 | live | 0 | keep directory and inode entries cached longer (kernel default 100) |
| ext4 atime + lazytime | noatime, lazytime | mount | 0 | no atime writes; timestamps are batched with the next real write (at most 24 h later) |
| opt-in **casesensitive**: Samba case sensitive + preserve case + short preserve case | yes | server | 0 | big folders get fast (no case-insensitive scan). **Every share is affected**; Windows/Mac programs that spell names differently get "not found". Off by default |

**Backups (Time Machine / rsync)** (Balanced, plus):
| Setting | Value | When | RAM held | Why |
|---|---|---|---|---|
| md1 stripe_cache_size | 1024 | live* | **16 MiB** | backups mix big and small writes |
| ext4 atime | noatime | mount | 0 | rsync's comparisons never write atimes |
| Samba strict sync | yes | server | 0 | Samba's own default, pinned: a flush request really reaches the disks |
| Samba fruit:wipe_intentionally_left_blank_rfork, fruit:delete_empty_adfiles | yes | server | 0 | vfs_fruit's advice for Time Machine: drop empty resource forks and AppleDouble files |

\* **The array's flag.** Writing `stripe_cache_size` on a read-write md array that is idle (`clean`) makes md write its
clean/dirty flag to all four superblocks (`md_allow_write()`, drivers/md/md.c in the 6.12.112 tree). The tool never
does that: md settings apply when the array is read-only (every trial) or already `active`. On a clean read-write
array they WAIT and the page says so. They are set at the next read-only assembly (`ex4-md-ro` runs `ex4-profile
reapply`), or by the rw bench inside its own session (`--bench`). A read-only array writes nothing: `md_allow_write`
returns at once when `!md_is_rdwr()`.

**When**: *live* = takes effect at once · *mount* = needs the volume mounted read-write. A trial mounts it
`ro,noload` and is never remounted, so these WAIT · *server* = the SMB server reloads and open connections
reconnect once · *drive* = an ATA command to each disk.

## Advice on the page (no button can do these)

- One core does all the work. Moving a file at ~55 MiB/s already uses all of it. Settings change how the core spends
  its time; none adds speed the processor does not have.
- **Signing.** Windows 11 24H2+ and macOS sign every SMB packet by default. On this CPU, signing costs more per
  byte than any setting here saves, and it turns off sendfile and receivefile. Checked in Samba 4.22.7:
  `schedule_smb2_sendfile_read()` returns early on `do_signing || do_encryption` (source3/smbd/smb2_read.c:339ff);
  `is_smb2_recvfile_write()` refuses signed or encrypted packets (source3/smbd/smb2_server.c:4521ff). Linux's cifs client
  signs only when the server requires it.
- **RAID shape.** A 4-disk RAID 5 handles heavy small random writes badly: each one reads the old data and parity
  before it writes (4 disk operations for one). RAID 10 needs 2. This is decided when the array is created.
- **Fixed at creation, so ADVICE only, never a button:** RAID level, chunk size (64 KiB here), ext4 stride/stripe-width,
  inode ratio. Note that stock mounts with `stripe=128` (512 KiB), which does not match 64 KiB x 3 data disks = 48
  blocks. That is a mount option and could change at mount time later. It is not a profile knob.
- ksmbd may beat Samba on writes. That engine choice is a separate measured A/B, not a profile.
- Time Machine is a per-share switch on the Shares page, and needs Samba. ksmbd only detects Apple's AAPL context
  and never answers it.
- A fair disk scheduler (mq-deadline/BFQ) needs a kernel build: `CONFIG_MQ_IOSCHED_DEADLINE`, `_KYBER` and
  `CONFIG_IOSCHED_BFQ` are all unset in the 6.12.112 kirkwood config.

## ksmbd equivalents

| Samba | ksmbd 3.5.6 | In a profile |
|---|---|---|
| use sendfile | none (ksmbd's read path is `kernel_read` + `kernel_sendmsg`, one copy more) | no |
| min receivefile size, aio sizes | none | no |
| smb2 leases (on by default) | `smb2 leases` (OFF by default, man page) | knob exists (`ksmbd.smb2_leases`), in no profile: the A/B below runs Samba only, so ksmbd leases stay unmeasured |
| case sensitive | none | no |
| SMB2 I/O size | `smb2 max read/write` (default 4 MiB; ksmbd.init writes smaller sizes only under 256 MB of RAM) | knob exists, in no profile |

## How it works (`profiles/ex4-profile`, busybox ash + the image's uci)

`list · show [P] · diff P · apply P [--opt N] [--bench] · revert [--bench] · current · boot | reapply · check CONF ·
smbconf P · ksmbdconf P · values P · json`

- **The allow-list** (`knob_ok`): only these knobs, each with its own range: md read_ahead_kb (as
  `/sys/block/md1/queue/read_ahead_kb`: the same bdi setting as `blockdev --setra`, set via sysfs so that it can be tested
  on a fake tree) · md stripe_cache_size · md group_thread_cnt · per-disk scheduler / nr_requests / read_ahead_kb ·
  disk standby (smartctl `-s standby,N` or hdparm `-S`) · vm.dirty_bytes / dirty_background_bytes / dirty_expire_centisecs
  / vfs_cache_pressure · ext4 noatime|relatime, lazytime on|off, commit=1..60 (remount only) · Samba aio read/write size,
  use sendfile, min receivefile size, smb2 leases, case sensitive / preserve case / short preserve case, strict sync,
  two fruit options · ksmbd smb2 leases / max read / max write.
- **Forbidden**, checked before anything is read or written. A `set` or `opt` line containing data= · barrier ·
  journal · tune2fs · fsck · mkfs · mke2fs · mdadm · grow · reshape · level · raid-devices · superblock · resize · chunk ·
  bitmap · sync_action · discard · errors=, or any character outside `[A-Za-z0-9._:-]`, refuses the WHOLE profile,
  Balanced included. The remount builds its options only from the allow-list's own words.
- **RAM cap**: stripe_cache_size x 4 KiB x members (from `md/raid_disks`) <= 32 MiB, checked before any write.
  2048 on four members is exactly the cap.
- **Record, apply, roll back**: the first apply since boot records each knob's value just before it first writes it
  (`/tmp/ex4-profile/base.tsv`; Samba/ksmbd templates as they were, without our block). An apply runs live knobs one
  by one (read back after each write), then one ext4 remount, then one rewrite of each SMB template's marked block.
  On any failure, every knob that apply wrote is put back and the old choice stays. Switching profiles returns
  knobs the new one does not set to their recorded values. `revert` restores every recorded value byte-exact.
- **One truth**: `ex4.main.profile` + `list profile_opt` in `/etc/config/ex4`, written only after a full apply.
  `/tmp/ex4/profile.json` (cards + state) is what the page reads. Rule 1 of the web interface holds: the read path
  opens one small file in RAM.
- **Boot**: `/etc/init.d/ex4-profile` (START 99) applies the choice. Array and mount knobs wait until those exist. `ex4-md-ro`
  calls `reapply` after assembling (patch below). A fresh box starts on Balanced (`96_ex4_profile`).
- **Samba / ksmbd**: OpenWrt's samba.init has no hook for extra [global] lines. The tool keeps one marked block at the
  end of `/etc/samba/smb.conf.template` (and the ksmbd one). Both templates end inside `[global]`, so the block lands
  there, ahead of samba.init's dynamic lines and the shares. Share-level settings in [global] become every share's
  default, which is why case sensitivity applies to all shares.

## The A/B plan for the read-write trial (patches to the bench; no number exists yet)

`host/ex4-rwbench-client.sh ... --profiles "balanced movies smallfiles backups" --session K`:
- One session = every named profile once, **Balanced always included**, in an order shuffled from a recorded seed
  (run id + session). Three repeats = three sessions (`--session 1..3`). That means three tokens, each typed by the owner,
  and each session gets a fresh order. Window 45 min (the bench's own ceiling). A profile that would not fit in the time left is
  skipped and named, never squeezed.
- Per profile: box `profile NAME` (ex4-profile `--bench`; refused if vm.dirty_bytes > the bench's 64 MiB cap or if
  it asks for spin-down) · local 2 GiB dd write + sync / read · one SMB 2 GiB write (fsync) + read, Samba 4 only,
  client remounted, box cache dropped · small-file test: 4 clients on separate SMB connections (`nosharesock`), N/4
  files each (default 20000 total, 4-64 KiB, seeded sizes): create · (box cache dropped, remount) list + read · delete;
  files/s per phase. The box's existing `sample` lines record CPU busy (user/sys/softirq/iowait), CPU-ms per MiB, the
  **mv_xor interrupt delta per engine** and member vs md writes around every copy.
- Writes only into the bench's own new folder (`Public/ex4-bench-v8/`). The token, the clean stop, the guard, the
  reboot paths and every other wall stay unchanged. **One deliberate difference, flagged for the owner:** an `up
  --profile-ab` session mounts with `relatime` (the kernel default) instead of the bench's `noatime`, so Balanced is
  measured as it ships and noatime is a real change. atime is not a safety property (atime updates are ordinary
  journalled inode writes). The rest of the mount line is unchanged. In a profile session the bench's own two Samba lines
  (sendfile, receivefile) give way to the profile's lines.
- **THE RULE:** a profile's card claims a gain only with a number in `/usr/share/ex4/profiles/measured.tsv`
  (`profile · metric · value · Balanced · receipt`). A knob that loses or does nothing leaves its profile. A knob that
  wins in every profile moves into Balanced, the image's default. A per-profile A/B cannot say which knob did it, so
  a profile that wins or loses gets a one-knob-at-a-time pass before its card changes.

## Proven off the box vs not

Proven on the build box (the receipts are not published):
- `tests/profiles/run.sh`: **88/88 under the host busybox 1.36.1, 88/88 under the image's own busybox 1.37.0 (ARM,
  qemu-arm)**, with the image's uci for every choice. Covers: the four profiles are clean; 24 forbidden/off-list/out-of-range/shell
  lines are refused with nothing written; one bad line refuses the whole profile; a bad base refuses all profiles; the
  RAM cap (64 MiB refused, 40 MiB on 5 members refused, exactly 32 MiB allowed); apply -> apply -> apply -> apply ->
  revert restores **every file byte-exact** in three array/mount states (trial read-only, rw active, rw clean); the
  dirty_bytes <-> dirty_ratio coupling and scheduler display emulated; one remount with allow-list options only (the
  mount stub fails on anything else); waits and their reasons; reapply after a writable mount; --bench only inside a
  session; the scheduler reported as missing, never faked; spin-down only when opted in; rollback after a refused write
  mid-apply; boot; a stale template block dropped; first boot; the page's JSON; uci committed to the file itself.
- `tests/profiles/conf-test.sh`: **27/27**. Every profile's Samba lines, rendered as samba.init renders them, load in
  the image's Samba 4.22.7 testparm with no warning the plain template lacks, and every value shows in `testparm -v`.
  ksmbd parameter names are confirmed in the image's ksmbd.tools.
- `v9-profiles/patch-test.sh`: **31/31**. Every patch applies to the repo as it is now. The patched ex4.uc / ex4-apply
  compile in the image's ucode. ex4-apply's `profile` verb (image ucode) drives the tool and revert is byte-exact. The bench's
  non-profile smb.conf is byte-identical to before. Each profile's bench smb.conf loads in testparm. The patched bench
  still passes `tests/rwbench/conf-test.sh` and `stub-test.sh`, the client refuses bad `--profiles` arguments, and the
  patched page builds (128,661 B, its CSP rules). The page's script parses (bun).

Not proven: anything on the box. That includes the real sysfs/procfs writes; md accepting stripe_cache_size on the
read-only array; busybox mount's remount with `lazytime`/`nolazytime`/`commit=` against a real ext4 (the kernel parses
lazytime as a superblock flag); `smartctl -s standby` on WD40EFRX; Samba / ksmbd reloading from the template; the page in
a browser (no browser on the build boxes; the fakebox/page tests do not know the new method yet); the bench's profile
session against a real trial (its loop-test needs root and was not run); and, above all, every speed number.
