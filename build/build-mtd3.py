#!/usr/bin/env python3
"""build-mtd3.py: the EX4's mtd3 UBI image, built OFF the box, and our own offline checker for it. Pure file work.

  build --kernel K --initrd I --out DIR [--cmdline S] [--boot-lebs N] [--data-lebs N] [--compr-boot C] [--compr-data C]
        [--ex4img PATH] [--tools DIR]
        DIR must not exist and must sit under ~/ex4-build/finalize/ (the one place these builders write).
        Makes, in DIR:
          boot/      kernel.bin atags.bin initrd.cpio EXPECT ADDRS tries   (the ex4boot volume's files, stage2.sh v1's contract)
          data/      etc/config/ (empty skeleton)                           (the ex4data volume)
          ex4boot.ubifs ex4data.ubifs ubinize.cfg  -> mtd3.ubi (+ mtd3.ubi.md5, MANIFEST, build.log, check.txt)
        atags.bin comes from ex4img.py atags (CORE, MEM 512, INITRD2 = INITRD_ADDR + initrd size, CMDLINE).
        EXPECT = "segN crc32" for seg0 kernel.bin, seg1 atags.bin, seg2 initrd.cpio: the CRC ex4boot.ko prints
        (crc32_step from 0xffffffff, inverted = zlib.crc32), lowercase %08x, one line each, newline-terminated.
        ADDRS = shell assignments KERNEL_ADDR ATAGS_ADDR INITRD_ADDR ENTRY R2 (stage2.sh SOURCES it).
  check IMAGE [--boot-dir DIR] [--extract DIR]
        Reads every PEB of IMAGE: EC + VID headers (magic, version, CRC, offsets, image_seq), the layout volume (both
        copies, every record CRC, names, sizes), each UBIFS volume (superblock vs what WD's 3.2.40 validate_sb()
        accepts, every node's CRC in the non-LPT LEBs, node types 3.2.40 knows), then rebuilds the files of each
        volume from its nodes (uncompressed or zlib data; LZO is reported, not decoded) and, with --boot-dir,
        compares them byte for byte with the inputs + re-derives EXPECT. Exit 1 on any failure.

Geometry (stock's own attach of mtd5, box dmesg 2026-11-26 11:15): PEB 128 KiB, LEB 126976, min I/O 2048, sub-page 512,
VID header 2048, data offset 4096. mtd3 = 1640 PEBs; the one bad block is mtd3-relative 1501 (0xBBA0000).

Format choice, argued from WD's GPL 3.2.40 tree (fs/ubifs/ubifs-media.h:49,62; sb.c:545-575, 448, 613-620):
  UBIFS_FORMAT_VERSION 4, RO_COMPAT 0: a fmt_version > 4 mounts READ-ONLY at best (stage2 must write `tries`), so the
  image must say 4. mtd-utils 2.3.0's mkfs.ubifs writes 4 unless double_hash/encryption (mkfs.ubifs.c:2516-2523).
  default_compr must be < UBIFS_COMPR_TYPES_CNT = 3 (none 0, lzo 1, zlib 2; zstd = 3 is REFUSED by sb.c:448).
  Flags 3.2.40 reads: BIGLPT 0x2, SPACE_FIXUP 0x4 only; DOUBLE_HASH/ENCRYPTION/AUTHENTICATION are refused here.
  -F (space fixup) because nandwrite programs the all-0xFF tail pages of every LEB; 3.2.40 supports it (sb.c:620,783).

Born Nov 26 2026 (EX4 finalize, phase B3). Writes only into --out / --extract (new folders). Never touches a device.
"""
import argparse
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import zlib

PEB = 131072
MIN_IO = 2048
SUB_PAGE = 512
VID_OFF = 2048
DATA_OFF = 4096
LEB = PEB - DATA_OFF                 # 126976
MTD3_PEBS = 1640
BAD_REL = 1501                       # the known bad block, mtd3-relative
UNALLOC_MIN = 40                     # PEBs left unallocated (6.12: 2048*20/1024 = 40 limit, 3.2.40: 1% = 16)
LAYOUT_VOL_ID = 0x7FFFEFFF
IMAGE_SEQ = 0x45583433               # "EX43", fixed so two builds of the same inputs differ only in UBIFS UUIDs
VTBL_REC = 172
COMPR = {'none': 0, 'lzo': 1, 'zlib': 2}
COMPR_NAME = {v: k for k, v in COMPR.items()}
NODE = {0: 'INO', 1: 'DATA', 2: 'DENT', 3: 'XENT', 4: 'TRUN', 5: 'PAD', 6: 'SB', 7: 'MST', 8: 'REF', 9: 'IDX', 10: 'CS', 11: 'ORPH'}
UBIFS_MAGIC = 0x06101831
ROOT_INO = 1

# the proven v9.9 layout (bundle-v9 SEGS/CFG, RUN 20): kernel at 0x8000, ATAGs at 0x100, the cpio at 0x4000000, entry 0x8000
ADDRS = (('KERNEL_ADDR', 0x8000), ('ATAGS_ADDR', 0x100), ('INITRD_ADDR', 0x4000000), ('ENTRY', 0x8000), ('R2', 0x100))
DEFAULT_CMDLINE = 'console=ttyS0,115200n8 watchdog.open_timeout=120'
FINALIZE = os.path.expanduser('~/ex4-build/finalize')
TOOLS = os.path.expanduser('~/ex4-build/v9/img/openwrt/staging_dir/host/bin')
EX4IMG = os.path.join(FINALIZE, 'src', 'ex4img.py')
EPOCH = 1795737600                   # 2026-11-26 00:00 UTC: every staged file's mtime (reproducible inode times)


def crc_ubi(b):                      # crc32_le(0xffffffff, b) with no final inversion: UBI_CRC32_INIT and UBIFS_CRC32_INIT
    return zlib.crc32(b) ^ 0xffffffff


def crc_ex4boot(b):                  # ex4boot_main.c: ~crc32_step(0xffffffff, ...) = the zlib / IEEE crc32
    return zlib.crc32(b) & 0xffffffff


def die(msg):
    sys.exit(f"build-mtd3: REFUSED: {msg}")


def md5(p):
    h = hashlib.md5()
    with open(p, 'rb') as f:
        for blk in iter(lambda: f.read(1 << 20), b''):
            h.update(blk)
    return h.hexdigest()


# ------------------------------------------------------------------------------------------------------------ build
def run(log, argv):
    for a in argv:
        if a.startswith('/dev') or '/dev/' in a:
            die(f"an argument names a device: {a}")
    log.write('$ ' + ' '.join(argv) + '\n')
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log.write(p.stdout + f'[rc {p.returncode}]\n')
    if p.returncode:
        die(f"{os.path.basename(argv[0])} failed (rc {p.returncode}); see build.log")
    return p.stdout


def stage_copy(src, dst):
    with open(src, 'rb') as f, open(dst, 'xb') as g:       # plain bytes: no xattrs, no owner, never overwrites
        shutil.copyfileobj(f, g)
    os.chmod(dst, 0o644)


def c_build(a):
    out = os.path.realpath(a.out)
    if not (out + '/').startswith(os.path.realpath(FINALIZE) + '/'):
        die(f"--out must be under {FINALIZE}/")
    if os.path.exists(out):
        die(f"{out} exists (never overwrite)")
    for p in (a.kernel, a.initrd):
        if not os.path.isfile(p) or os.path.getsize(p) == 0:
            die(f"{p} is not a non-empty file")
    if a.compr_boot not in COMPR or a.compr_data not in COMPR:
        die("compressor must be none, lzo or zlib (3.2.40 knows types 0..2 only)")
    if not a.cmdline or '\0' in a.cmdline or len(a.cmdline) > 1000:
        die("bad --cmdline")
    if 'ex4boot_run=' in a.cmdline:
        die("the cmdline carries a trial token (ex4boot_run=): the persistent atags must not")
    mkfs = os.path.join(a.tools, 'mkfs.ubifs'); ubinize = os.path.join(a.tools, 'ubinize')
    for t in (mkfs, ubinize, a.ex4img):
        if not os.path.isfile(t):
            die(f"tool missing: {t}")
    total = a.boot_lebs + a.data_lebs + 2
    if MTD3_PEBS - 1 - total < UNALLOC_MIN:
        die(f"{a.boot_lebs}+{a.data_lebs} LEBs leave {MTD3_PEBS - 1 - total} PEBs unallocated (< {UNALLOC_MIN})")

    os.makedirs(out); boot = os.path.join(out, 'boot'); data = os.path.join(out, 'data')
    os.makedirs(boot); os.makedirs(os.path.join(data, 'etc', 'config'))
    log = open(os.path.join(out, 'build.log'), 'w')
    log.write(f"build-mtd3.py build, inputs: kernel {a.kernel} md5 {md5(a.kernel)}; initrd {a.initrd} md5 {md5(a.initrd)}\n"
              f"cmdline {a.cmdline!r}; ex4img {a.ex4img} md5 {md5(a.ex4img)}; tools {a.tools}\n")
    stage_copy(a.kernel, os.path.join(boot, 'kernel.bin'))
    stage_copy(a.initrd, os.path.join(boot, 'initrd.cpio'))
    addr = dict(ADDRS)
    isize = os.path.getsize(os.path.join(boot, 'initrd.cpio'))
    run(log, [sys.executable, '-I', a.ex4img, 'atags', os.path.join(boot, 'atags.bin'), '--mem', '512',
              '--initrd', f"{addr['INITRD_ADDR']:#x},{isize:#x}", '--cmdline', a.cmdline])
    run(log, [sys.executable, '-I', a.ex4img, 'atags-parse', os.path.join(boot, 'atags.bin'),
              '--expect-initrd', f"{addr['INITRD_ADDR']:#x},{isize:#x}", '--max-end', '0x8000'])
    segs = os.path.join(out, 'SEGS')
    with open(segs, 'w') as f:
        f.write(f"kernel.bin {addr['KERNEL_ADDR']:#x}\natags.bin {addr['ATAGS_ADDR']:#x}\ninitrd.cpio {addr['INITRD_ADDR']:#x}\n")
    run(log, [sys.executable, '-I', a.ex4img, 'layout', segs, '--root', boot])
    with open(os.path.join(boot, 'EXPECT'), 'x') as f:
        for i, n in enumerate(('kernel.bin', 'atags.bin', 'initrd.cpio')):
            with open(os.path.join(boot, n), 'rb') as g:
                f.write(f"seg{i} {crc_ex4boot(g.read()):08x}\n")
    with open(os.path.join(boot, 'ADDRS'), 'x') as f:
        f.write(''.join(f"{k}={v:#x}\n" for k, v in ADDRS))
    with open(os.path.join(boot, 'tries'), 'x') as f:
        f.write('0\n')
    for root, dirs, files in os.walk(out):
        for n in dirs:
            os.chmod(os.path.join(root, n), 0o755)
        for n in files:
            os.chmod(os.path.join(root, n), 0o644)
        for n in files + dirs:
            os.utime(os.path.join(root, n), (EPOCH, EPOCH))
    os.chmod(boot, 0o755); os.chmod(data, 0o755)
    os.utime(boot, (EPOCH, EPOCH)); os.utime(data, (EPOCH, EPOCH))

    for t in (mkfs, ubinize):                                 # the tool versions, for the record (rc not judged)
        v = subprocess.run([t, '--version'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        log.write(f"$ {t} --version\n{v.stdout}[rc {v.returncode}] md5 {md5(t)}\n")
    for vol, src, lebs, comp in (('ex4boot', boot, a.boot_lebs, a.compr_boot), ('ex4data', data, a.data_lebs, a.compr_data)):
        run(log, [mkfs, '-r', src, '-m', str(MIN_IO), '-e', str(LEB), '-c', str(lebs), '-x', comp, '-F', '-U',
                  '-o', os.path.join(out, vol + '.ubifs')])
    cfg = os.path.join(out, 'ubinize.cfg')
    with open(cfg, 'w') as f:
        for vid, (vol, lebs) in enumerate((('ex4boot', a.boot_lebs), ('ex4data', a.data_lebs))):
            f.write(f"[{vol}]\nmode=ubi\nimage={os.path.join(out, vol + '.ubifs')}\nvol_id={vid}\nvol_type=dynamic\n"
                    f"vol_name={vol}\nvol_size={lebs * LEB}\nvol_alignment=1\n\n")
    img = os.path.join(out, 'mtd3.ubi')
    run(log, [ubinize, '-o', img, '-p', str(PEB), '-m', str(MIN_IO), '-s', str(SUB_PAGE), '-O', str(VID_OFF),
              '-Q', str(IMAGE_SEQ), cfg])
    m = md5(img)
    with open(img + '.md5', 'x') as f:
        f.write(f"{m}  mtd3.ubi\n")
    with open(os.path.join(out, 'MANIFEST'), 'x') as f:       # what the box-side verify compares after a mount
        for n in ('kernel.bin', 'atags.bin', 'initrd.cpio', 'EXPECT', 'ADDRS', 'tries'):
            f.write(f"{md5(os.path.join(boot, n))}  {n}\n")
    log.close()
    print(f"built {img}: {os.path.getsize(img)} bytes ({os.path.getsize(img) // PEB} PEBs), md5 {m}")
    rc = check(img, boot, os.path.join(out, 'check-extract'), os.path.join(out, 'check.txt'))
    sys.exit(rc)


# ------------------------------------------------------------------------------------------------------------ check
class Report:
    def __init__(self, path=None):
        self.lines = []; self.bad = 0; self.path = path

    def ok(self, s):
        self.lines.append('OK    ' + s); print('OK    ' + s)

    def info(self, s):
        self.lines.append('      ' + s); print('      ' + s)

    def fail(self, s):
        self.lines.append('FAIL  ' + s); print('FAIL  ' + s); self.bad += 1

    def save(self):
        if self.path:
            with open(self.path, 'x') as f:
                f.write('\n'.join(self.lines) + '\n')


def parse_ubi(img, r):
    n = len(img) // PEB
    if len(img) % PEB:
        r.fail(f"image length {len(img)} is not a whole number of 128 KiB PEBs")
    r.info(f"image: {len(img)} bytes = {n} PEBs of mtd3's {MTD3_PEBS}")
    if n > BAD_REL:
        r.fail(f"image reaches the bad block at mtd3-relative {BAD_REL}: nandwrite -p would shift everything after it")
    else:
        r.ok(f"image ends before the bad block (PEB {BAD_REL}): no nandwrite skip can shift it")
    lebs = {}; empty = 0; ecs = set(); seqs = set(); bad = 0
    for p in range(n):
        b = img[p * PEB:(p + 1) * PEB]
        if b == b'\xff' * PEB:
            empty += 1; continue
        magic, ver, ec, vo, do, iseq = struct.unpack('>IB3xQIII', b[:28])
        hcrc = struct.unpack('>I', b[60:64])[0]
        if magic != 0x55424923 or ver != 1 or crc_ubi(b[:60]) != hcrc or vo != VID_OFF or do != DATA_OFF:
            bad += 1; r.fail(f"PEB {p}: EC header magic {magic:#x} ver {ver} vid {vo} data {do} crc {'ok' if crc_ubi(b[:60]) == hcrc else 'BAD'}")
            continue
        if b[28:60] != bytes(32):
            r.fail(f"PEB {p}: EC header padding not zero")
        ecs.add(ec); seqs.add(iseq)
        v = b[VID_OFF:VID_OFF + 64]
        if v == b'\xff' * 64:
            continue                                            # an EC header and nothing else = a free PEB
        (vm, vver, vtype, copy, compat, vol, lnum, dsize, used, dpad, dcrc, sq) = struct.unpack('>IBBBBII4xIIII4xQ', v[:48])
        vcrc = struct.unpack('>I', v[60:64])[0]
        if vm != 0x55424921 or vver != 1 or crc_ubi(v[:60]) != vcrc or vtype not in (1, 2):
            bad += 1; r.fail(f"PEB {p}: VID header magic {vm:#x} ver {vver} type {vtype} crc {'ok' if crc_ubi(v[:60]) == vcrc else 'BAD'}"); continue
        if (vol, lnum) in lebs:
            r.fail(f"PEB {p}: vol {vol:#x} LEB {lnum} appears twice")
        if vtype == 2 and dcrc != crc_ubi(b[DATA_OFF:DATA_OFF + dsize]):
            r.fail(f"PEB {p}: static data CRC mismatch")
        lebs[(vol, lnum)] = dict(peb=p, type=vtype, copy=copy, compat=compat, dpad=dpad, sqnum=sq, data=b[DATA_OFF:])
    r.info(f"PEBs: {len(lebs)} mapped, {n - len(lebs) - empty} EC-only, {empty} all-0xFF; erase counters {sorted(ecs)}; image_seq {[hex(s) for s in seqs]}")
    if not bad:
        r.ok(f"every non-empty PEB: EC header 'UBI#' v1 CRC ok, VID offset {VID_OFF}, data offset {DATA_OFF}; every VID header 'UBI!' v1 CRC ok")
    if len(seqs) > 1:
        r.fail(f"more than one image_seq: {seqs}")
    if img[:4] == b'UBI#':
        r.ok("first 4 bytes = 'UBI#' (stage2.sh v1 line 41-42 takes the UBI branch)")
    else:
        r.fail("first 4 bytes are not 'UBI#'")
    return lebs


def parse_vtbl(lebs, r):
    cp = [lebs.get((LAYOUT_VOL_ID, i)) for i in (0, 1)]
    if not all(cp):
        r.fail("the layout volume does not have both LEB 0 and LEB 1"); return {}
    if cp[0]['data'][:128 * VTBL_REC] != cp[1]['data'][:128 * VTBL_REC]:
        r.fail("the two volume-table copies differ")
    else:
        r.ok(f"layout volume: both copies present (PEBs {cp[0]['peb']}, {cp[1]['peb']}) and identical")
    vols = {}; t = cp[0]['data']; badrec = 0
    for i in range(128):
        rec = t[i * VTBL_REC:(i + 1) * VTBL_REC]
        rsv, align, dpad, vtype, upd, nlen = struct.unpack('>IIIBBH', rec[:16])
        name = rec[16:16 + 128]; flags = rec[144]; crc = struct.unpack('>I', rec[168:172])[0]
        if crc != crc_ubi(rec[:168]):
            badrec += 1; r.fail(f"vtbl record {i}: CRC mismatch"); continue
        if rsv == 0:
            if rec[:168] != bytes(168):
                r.fail(f"vtbl record {i}: empty but not zero")
            continue
        vols[i] = dict(name=name[:nlen].decode('latin1'), reserved=rsv, align=align, dpad=dpad, type=vtype, upd=upd, flags=flags)
    if not badrec:
        r.ok("volume table: all 128 records' CRCs ok")
    alloc = sum(v['reserved'] for v in vols.values())
    for i, v in sorted(vols.items()):
        r.info(f"volume {i} '{v['name']}': {v['reserved']} LEBs ({v['reserved'] * LEB} B), {'dynamic' if v['type'] == 1 else 'static'}, "
               f"align {v['align']}, upd_marker {v['upd']}, flags {v['flags']:#x}")
        if v['upd']:
            r.fail(f"volume {v['name']} has its update marker set (3.2.40 treats it as corrupted)")
    free = MTD3_PEBS - 1 - 2 - alloc                    # 1 bad, 2 layout
    k6_rsv = 40 - 1 + 1 + 1                             # 6.12: limit 2048*20/1024=40 minus 1 bad = 39 BEB, +1 WL +1 EBA
    k3_rsv = 1639 // 100 * 1 + 1 + 1                    # 3.2.40: 1% of 1639 good = 16 BEB (misc.c:101-104), +1 WL +1 EBA
    r.info(f"allocated {alloc} LEBs + 2 layout; unallocated {free} PEBs of 1639 good; reserves: 3.2.40 ~{k3_rsv}, 6.12 ~{k6_rsv}")
    if free >= UNALLOC_MIN and free - max(k3_rsv, k6_rsv) >= 0:
        r.ok(f"{free} PEBs unallocated (>= {UNALLOC_MIN}): both kernels can take their full bad-block reserve")
    else:
        r.fail(f"only {free} PEBs unallocated")
    names = sorted(v['name'] for v in vols.values())
    if names == ['ex4boot', 'ex4data']:
        r.ok("volume names: ex4boot, ex4data")
    else:
        r.fail(f"volume names {names}")
    return vols


def scan_leb(d, lnum, r, vname, nodes):
    o = 0; n = 0
    while o + 24 <= len(d):
        if d[o:o + 4] == b'\xff\xff\xff\xff':
            rest = d[o:]
            if rest.count(0xff) != len(rest):
                r.fail(f"{vname} LEB {lnum} +{o:#x}: 0xFF run followed by data"); return n
            return n
        if d[o] == 0xCE:                                    # UBIFS_PADDING_BYTE up to the next min-I/O boundary
            o += 1; continue
        magic, crc, sq, ln, ntype, grp = struct.unpack('<IIQIBB', d[o:o + 22])
        if magic != UBIFS_MAGIC:
            r.fail(f"{vname} LEB {lnum} +{o:#x}: no node magic"); return n
        if ln < 24 or o + ln > len(d) or crc != crc_ubi(d[o + 8:o + ln]):
            r.fail(f"{vname} LEB {lnum} +{o:#x}: node len {ln} CRC {'ok' if o + ln <= len(d) and crc == crc_ubi(d[o + 8:o + ln]) else 'BAD'}")
            return n
        if ntype not in NODE:
            r.fail(f"{vname} LEB {lnum} +{o:#x}: node type {ntype}: WD's 3.2.40 knows 0..11 only")
        nodes.append((lnum, o, ntype, sq, d[o:o + ln])); n += 1
        if ntype == 5:                                      # pad node: skip pad_len more bytes
            o += ln + struct.unpack('<I', d[o + 24:o + 28])[0]
        else:
            o += (ln + 7) & ~7
    return n


def parse_ubifs(vname, vlebs, vsize, r):
    sb = vlebs.get(0)
    if sb is None:
        r.fail(f"{vname}: LEB 0 (superblock) not mapped"); return None
    d = sb['data']
    magic, crc, sq, ln, ntype = struct.unpack('<IIQIB', d[:21])
    if magic != UBIFS_MAGIC or ntype != 6 or ln != 4096 or crc != crc_ubi(d[8:4096]):
        r.fail(f"{vname}: superblock node magic {magic:#x} type {ntype} len {ln} CRC {'ok' if crc == crc_ubi(d[8:4096]) else 'BAD'}"); return None
    (key_hash, key_fmt, flags, min_io, leb, leb_cnt, max_leb, max_bud, log_lebs, lpt_lebs, orph_lebs, jheads, fanout, lsave,
     fmtv, compr) = struct.unpack('<2xBBIIIIIQIIIIIIIH', d[24:24 + 62])
    rp_uid, rp_gid, rp_size, tgran = struct.unpack('<IIQI', d[88:108])
    uuid = d[108:124]; roc = struct.unpack('<I', d[124:128])[0]
    tail = d[128:4096]; nz = [i + 128 for i, x in enumerate(tail) if x]
    eff = leb_cnt                                   # sb.c:622-636: the auto-resize to the volume runs BEFORE validate_sb()
    if leb_cnt < vsize and leb_cnt < max_leb:       # (in memory on a ro mount, written back on a rw one)
        eff = min(max_leb, vsize)
    main = eff - 1 - 2 - log_lebs - lpt_lebs - orph_lebs
    r.info(f"{vname} superblock: fmt_version {fmtv} ro_compat {roc} compr {COMPR_NAME.get(compr, compr)} flags {flags:#x} "
           f"min_io {min_io} leb {leb} leb_cnt {leb_cnt} (3.2.40 resizes to {eff} at mount) max_leb_cnt {max_leb} (volume {vsize}) log {log_lebs} lpt {lpt_lebs} "
           f"orph {orph_lebs} main {main} jheads {jheads} fanout {fanout} key_hash {key_hash} key_fmt {key_fmt} time_gran {tgran} "
           f"rp_size {rp_size} uuid {uuid.hex()}")
    probs = []
    if fmtv != 4: probs.append(f"fmt_version {fmtv} (3.2.40 = 4; >4 mounts read-only at best)")
    if roc != 0: probs.append(f"ro_compat_version {roc}")
    if compr >= 3: probs.append(f"default_compr {compr} (3.2.40 knows 0..2)")
    if flags & ~0x6: probs.append(f"flags {flags:#x} beyond BIGLPT|SPACE_FIXUP")
    if key_hash != 0 or key_fmt != 0: probs.append("key hash/format not R5/simple")
    if min_io != MIN_IO or leb != LEB: probs.append("min_io/LEB size differ from the NAND's")
    jheads += 2                                     # sb.c:607 c->jhead_cnt = on-flash value + NONDATA_JHEADS_CNT (2)
    min_cnt = 1 + 2 + log_lebs + lpt_lebs + orph_lebs + jheads + 6            # sb.c:396-397 validate_sb()
    if eff < min_cnt or eff > vsize: probs.append(f"leb_cnt {leb_cnt} (resized {eff}) outside {min_cnt}..{vsize}")
    if max_leb < leb_cnt: probs.append("max_leb_cnt < leb_cnt")
    if log_lebs < 2 or lpt_lebs < 2 or orph_lebs < 1 or main < 9: probs.append("an area below 3.2.40's minimum (log 2, lpt 2, orph 1, main 9)")
    if max_bud < leb * 3 or max_bud > leb * main: probs.append("max_bud_bytes out of range")
    if jheads != 3: probs.append(f"jhead_cnt {jheads - 2} on flash (3.2.40 needs 1: sb.c:423-424)")
    if fanout < 3: probs.append("fanout < 3")
    if rp_size > main * leb: probs.append("rp_size > main area")
    if not 1 <= tgran <= 1000000000: probs.append("time_gran")
    if nz: probs.append(f"{len(nz)} non-zero byte(s) in 3.2.40's padding2 (newer-format fields) at {nz[:8]}")
    if probs:
        for p in probs: r.fail(f"{vname}: {p}")
    else:
        r.ok(f"{vname}: superblock passes every validate_sb() test of WD's 3.2.40 (fmt 4, ro_compat 0, compr "
             f"{COMPR_NAME.get(compr)}, flags {flags:#x}{' = SPACE_FIXUP' if flags == 4 else ''}, padding2 all zero)")
    nodes = []; skipped = []; before = r.bad
    first_lpt = 3 + log_lebs
    tail0 = d[4096:]                                # LEB 0 past the SB node: 3.2.40 never reads it (sb.c:491 reads
    if tail0.count(0xff) != len(tail0):             # UBIFS_SB_NODE_SZ at offset 0; sb.c:512 rewrites the LEB with the SB only)
        t0 = []; b0 = r.bad
        scan_leb(tail0, 0, r, vname + ' (LEB 0 tail)', t0)
        if r.bad == b0 and [(x[2], len(x[4])) for x in t0] == [(0, 64), (5, 28)] and t0[0][4][24:64] == bytes(40):
            r.info(f"{vname}: LEB 0 +0x1000: a 64-byte all-zero node (type 0, CRC ok) + a pad node to 0x1800, then 0xFF = mtd-utils 2.3.0's unconditional empty "
                   f"signature node (mkfs.ubifs.c:2584-2588 prepares it even without authentication). 3.2.40 never reads LEB 0 "
                   f"past 4096 (sb.c:491) and rewrites LEB 0 with the SB alone on its first rw mount (SPACE_FIXUP clear, "
                   f"sb.c:797-798 + 507-512)")
        else:
            r.fail(f"{vname}: LEB 0 holds unexpected data after the superblock node")
    for lnum in sorted(vlebs):
        if lnum == 0:
            continue
        if first_lpt <= lnum < first_lpt + lpt_lebs:
            skipped.append(lnum); continue                  # LPT LEBs hold LPT nodes (crc16 format), not ubifs_ch nodes
        scan_leb(vlebs[lnum]['data'], lnum, r, vname, nodes)
    cnt = {}
    for nd in nodes:
        cnt[NODE.get(nd[2], nd[2])] = cnt.get(NODE.get(nd[2], nd[2]), 0) + 1
    r.info(f"{vname}: mapped LEBs {sorted(vlebs)}; LPT LEBs not node-scanned {skipped}; nodes {cnt}")
    if r.bad == before:
        r.ok(f"{vname}: {len(nodes)} nodes, every node CRC ok, every node type one WD's 3.2.40 knows (0..11)")
    if cnt.get('XENT'):
        r.fail(f"{vname}: {cnt['XENT']} xattr node(s): the staged files carried xattrs")
    return dict(compr=compr, nodes=nodes, flags=flags, fmt=fmtv)


def rebuild(vname, u, r):
    """files of a freshly made UBIFS from its nodes: newest node per key wins (mkfs writes each once)."""
    inos = {}; dents = []; data = {}
    for lnum, o, t, sq, b in u['nodes']:
        if t == 0:
            inum = struct.unpack('<I', b[24:28])[0]
            size = struct.unpack('<Q', b[48:56])[0]; nlink, uid, gid, mode, flags, dlen = struct.unpack('<IIIIII', b[92:116])
            if inum not in inos or sq > inos[inum][0]:
                inos[inum] = (sq, dict(size=size, mode=mode, nlink=nlink, flags=flags))
        elif t == 2:
            parent = struct.unpack('<I', b[24:28])[0]; inum = struct.unpack('<Q', b[40:48])[0]
            typ = b[49]; nlen = struct.unpack('<H', b[50:52])[0]; name = b[56:56 + nlen].decode('latin1')
            dents.append((parent, name, inum, typ))
        elif t == 1:
            inum, k = struct.unpack('<II', b[24:32]); blk = k & 0x1fffffff
            dsize, ctype = struct.unpack('<IH', b[40:46])
            if (inum, blk) not in data or sq > data[(inum, blk)][0]:
                data[(inum, blk)] = (sq, dsize, ctype, b[48:])
    paths = {ROOT_INO: ''}
    for _ in range(16):
        for parent, name, inum, typ in dents:
            if parent in paths and inum not in paths:
                paths[inum] = paths[parent] + '/' + name
    files = {}; undecoded = 0
    for inum, path in paths.items():
        if inum not in inos:
            r.fail(f"{vname}: {path or '/'} has no inode node"); continue
        st = inos[inum][1]
        if st['mode'] & 0o170000 != 0o100000:
            files[path or '/'] = ('dir' if st['mode'] & 0o170000 == 0o040000 else 'other', oct(st['mode'] & 0o7777), None); continue
        buf = bytearray(st['size']); ok = True
        for (i, blk), (sq, dsize, ctype, payload) in data.items():
            if i != inum:
                continue
            if ctype == 0:
                chunk = payload[:dsize]
            elif ctype == 2:
                chunk = zlib.decompressobj(-15).decompress(payload)     # UBIFS zlib = raw deflate (compress.c windowBits -15)
            else:
                ok = False; undecoded += 1; continue
            if len(chunk) != dsize:
                r.fail(f"{vname}: {path} block {blk}: {len(chunk)} bytes, header says {dsize}")
            buf[blk * 4096:blk * 4096 + len(chunk)] = chunk
        files[path] = ('file', oct(st['mode'] & 0o7777), bytes(buf[:st['size']]) if ok else None)
    if undecoded:
        r.info(f"{vname}: {undecoded} LZO block(s) not decoded (no LZO in the stdlib): those files are checked by size only")
    for p, (kind, mode, b) in sorted(files.items()):
        r.info(f"{vname}: {kind:5s} {mode} {p}" + (f"  {len(b)} B md5 {hashlib.md5(b).hexdigest()} crc32 {crc_ex4boot(b):08x}" if b is not None else ''))
    return files


def check(image, boot_dir=None, extract=None, report=None):
    r = Report(report)
    img = open(image, 'rb').read()
    r.info(f"check of {image}: md5 {hashlib.md5(img).hexdigest()}")
    lebs = parse_ubi(img, r)
    vols = parse_vtbl(lebs, r)
    out = {}
    for vid, v in sorted(vols.items()):
        vlebs = {ln: x for (vi, ln), x in lebs.items() if vi == vid}
        if any(x['type'] != v['type'] for x in vlebs.values()):
            r.fail(f"{v['name']}: a VID header's volume type differs from the volume table's")
        if max(vlebs, default=-1) >= v['reserved']:
            r.fail(f"{v['name']}: a LEB number is past the volume's {v['reserved']} LEBs")
        u = parse_ubifs(v['name'], vlebs, v['reserved'], r)
        if u:
            out[v['name']] = rebuild(v['name'], u, r)
    stray = {vi for (vi, ln) in lebs if vi != LAYOUT_VOL_ID and vi not in vols}
    if stray:
        r.fail(f"LEBs of volume ids not in the table: {stray}")
    b = out.get('ex4boot', {})
    need = ['kernel.bin', 'atags.bin', 'initrd.cpio', 'EXPECT', 'ADDRS']
    for n in need:
        f = b.get('/' + n)
        if not f or f[0] != 'file' or (f[2] is not None and not f[2]):
            r.fail(f"ex4boot lacks a non-empty /{n} (stage2.sh line 50 would go to rescue)")
    if all(b.get('/' + n, (0, 0, None))[2] is not None for n in need):
        ex = b['/EXPECT'][2].decode('latin1'); ad = b['/ADDRS'][2].decode('latin1')
        want = ''.join(f"seg{i} {crc_ex4boot(b['/' + n][2]):08x}\n" for i, n in enumerate(need[:3]))
        if ex == want:
            r.ok(f"EXPECT inside the volume = the CRC32 of the volume's own kernel.bin / atags.bin / initrd.cpio, in insmod order: {ex.split()}")
        else:
            r.fail(f"EXPECT {ex!r} != re-derived {want!r}")
        if re.fullmatch(r'(?:(KERNEL_ADDR|ATAGS_ADDR|INITRD_ADDR|ENTRY|R2)=0x[0-9a-f]+\n){5}', ad) and \
                dict(l.split('=') for l in ad.split()) == {k: f"{v:#x}" for k, v in ADDRS}:
            r.ok(f"ADDRS = five plain assignments, the proven v9.9 values: {ad.split()}")
        else:
            r.fail(f"ADDRS {ad!r}")
        t = b.get('/tries')
        if t and t[2] is not None:
            (r.ok if t[2].strip() == b'0' else r.fail)(f"tries = {t[2]!r}")
    if boot_dir:
        for n in need + ['tries']:
            p = os.path.join(boot_dir, n); f = b.get('/' + n)
            if not os.path.exists(p) or not f:
                continue
            want = open(p, 'rb').read()
            if f[2] is None:
                r.info(f"{n}: not decoded; input {len(want)} B")
            elif f[2] == want:
                r.ok(f"/{n} re-extracted from the image = the input byte for byte ({len(want)} B, md5 {hashlib.md5(want).hexdigest()})")
            else:
                r.fail(f"/{n} re-extracted ({len(f[2])} B) differs from the input ({len(want)} B)")
    d = out.get('ex4data', {})
    if '/etc/config' in d and d['/etc/config'][0] == 'dir' and not [p for p in d if p.startswith('/etc/config/')]:
        r.ok("ex4data holds the empty /etc/config skeleton")
    elif d:
        r.fail(f"ex4data tree: {sorted(d)}")
    if extract:
        os.makedirs(extract)
        for vn, files in out.items():
            for p, (kind, mode, data) in files.items():
                if kind == 'file' and data is not None:
                    q = os.path.join(extract, vn + p); os.makedirs(os.path.dirname(q), exist_ok=True)
                    with open(q, 'xb') as g:
                        g.write(data)
    r.info(f"RESULT: {'PASS' if not r.bad else 'FAIL'} ({r.bad} failure(s))")
    r.save()
    return 1 if r.bad else 0


def c_check(a):
    sys.exit(check(a.image, a.boot_dir, a.extract, a.report))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest='cmd', required=True)
    s = sp.add_parser('build'); s.add_argument('--kernel', required=True); s.add_argument('--initrd', required=True)
    s.add_argument('--out', required=True); s.add_argument('--cmdline', default=DEFAULT_CMDLINE)
    s.add_argument('--boot-lebs', type=int, default=480); s.add_argument('--data-lebs', type=int, default=48)
    s.add_argument('--compr-boot', default='none'); s.add_argument('--compr-data', default='zlib')
    s.add_argument('--ex4img', default=EX4IMG); s.add_argument('--tools', default=TOOLS); s.set_defaults(f=c_build)
    s = sp.add_parser('check'); s.add_argument('image'); s.add_argument('--boot-dir'); s.add_argument('--extract')
    s.add_argument('--report'); s.set_defaults(f=c_check)
    a = ap.parse_args(); a.f(a)


if __name__ == '__main__':
    main()
