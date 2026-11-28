# c4/: the C4 trial kit (the installed system, booted from RAM, against a simulated mtd3)

C4 answers one question before anything is written to the real `mtd3`: **does the installed system (`../persist/`) behave
under OpenWrt's 6.12 kernel** (attach the UBI, seed its store, mark a good boot, restore the store next boot, fall back to safe
mode, reboot itself when it is up but unreachable)? It runs as a RAM trial from stock, like every trial in this repository: a
power cycle is stock again. Nothing here is part of an installed system.

**As published this is a reference kit.** Its builders pin OUR inputs by md5 (our v9 bundle, its kernel, persist-v1's
overlay, our nandsim build). To repeat it on your unit you would build each input yourself, read every gate, and replace the
pins. Read [../docs/LESSONS-2026-11.md](../docs/LESSONS-2026-11.md) first: half of what C4 taught is about its own kit.

## Result on our unit (Nov 27 2026): PROVEN, over two sessions

| Part | What it showed |
|---|---|
| C4a | the read-only wall first (all seven real partitions `flags 0x0`), the sim by name as `mtd7`, 6.12 attaches it with VID offset 2048 (1639 good PEBs, 1 bad), both UBIFS volumes mount rw without a format change (`w4/r0`), the first-boot seed, mark-good tries 1 -> 0 read back, **no auto-return** after 27 minutes |
| C4b | from C4a's end dump: the stored config restored and bound onto `/etc/config` (attempt 1), host keys kept, the cert remade for the stored host name, mark-good 1 -> 0 |
| C4c | the same dump at tries 2: **safe mode**, the stored config NOT used, nothing written to the store (the whole store compared with an offline baseline read by `ubifs-read.py`) |
| C4d | a build whose mark-good never marks: the not-good deadman rebooted the box to stock by itself after 10 minutes |
| every boot | the six stock flash pins (mtd0, mtd1, mtd2, mtd4, mtd3's head and its first 0x6820000 bytes) read equal before and after |

**What C4 does NOT prove:** the real NAND driver under 6.12 writing the real `mtd3` (C4 uses nandsim with mtd3's geometry
and its one bad block), and WD's 3.2.40 and 6.12 taking turns on the same UBI. The first real proof of both is the install
itself (phase D2 in [../INSTALL.md](../INSTALL.md)).

## How a C4 boot is kept safe

- **The trial kernel only.** `mkbundle-c4.sh` refuses any `kernel.bin` but the trial one (its DTB marks every real partition
  read-only); persist-v1's install `kernel.bin` (mtd3 writable) is refused by name.
- **The RO wall runs first** (`files/lib/ex4-c4/c4sim`): unless all seven partitions are WD's and every `flags` is `0x0`, and no
  `mtd7` exists yet: refused before `insmod`.
- **The sim by name and by device node**: exactly one MTD named `NAND simulator partition 0`, it must be `mtd7`, and the
  `/dev/mtd7` node's own major:minor must equal sysfs' (a stale node pointing elsewhere is refused).
- **The ranges around the bad block**: `nandwrite -p` skips a bad block and shifts everything after it, so the image is written
  in two ranges around block 1501 and each range is **read back and compared with the source md5** (computed on the box before
  the write). The read-back decides, not nandwrite's text (see LESSONS: the next-block probe).
- **A refusal means MODE ram**: c4sim writes `/tmp/ex4-c4sim.done` as its last act; the test overlay's copies of `ex4-persist`
  and `ex4-markgood` attach `mtd7` only when `.done` exists and `.refused` does not. A refused, crashed or hung sim = no attach,
  no persistence, never marked good, and the not-good deadman takes the box home.
- **Three ways home without a hand**: the not-good deadman (10 min), the C4-only deadman (45 min after a good mark,
  `files/etc/init.d/ex4-c4deadman`), and an absolute cap (90 min after boot, `files/etc/init.d/ex4-c4cap`). None of these is
  in the production overlay (the tests check that the production files carry no C4 string).

## Files

| File | What |
|---|---|
| `mknandsim612.sh` | builds `nandsim.ko` out of tree for the 6.12 kernel (never overwrites) |
| `k1-gates.sh` | read-only gates on the built module (struct module size, symbols, provenance). Note: this kernel is built with `CONFIG_MODULE_STRIPPED`, so it does NOT check vermagic at load; a wrong-kernel module would not be refused by the box |
| `mkc4overlay.py` | the C4 TEST overlay = persist-v1's overlay with exactly the listed changes (sim on `mtd7`, `ex4svc` off, the three init scripts, c4sim + nandsim + mtd-utils' nandwrite/nanddump/flash_erase, the sim image in ranges); writes `OVERLAY-DIFF-C4.txt` |
| `mkbundle-c4.sh` | a C4 bundle from a booted v9 bundle + that overlay; refuses any other kernel |
| `ubifs-read.py` | reads a USED UBI image the way the kernel mounts it (newest master, index walk, journal replayed with deletions). `../build/build-mtd3.py check` is a fresh-build checker and mis-reads a used image |
| `files/` | c4sim and the three init scripts (S03) |
| `tests/sim-c4sim.sh` + `tests/fakes/nandwrite-strict` | c4sim end to end against strict fakes (the real tools' option strings and the next-block probe) |
| `tests/sim-persist-c4.sh` | persist-v1's sims on the mapped copies (`MTDN=7`), plain and strict |
| `tests/sim-deadman.sh` | the deadman, the cap, and THE PRODUCTION WALL (no C4 file or string in the production image) |
| `tests/c4-qemu.sh` | the proofs that need qemu-arm user mode: real nandwrite vs the strict fake, `sh -n` under the image's own busybox ash |

The builders write only under `~/ex4-build/finalize/c4/` (a self-imposed wall; make the folder). Comments cite our internal
design notes (DESIGN-C4, AMEND 1/2, C2), which are not published.
