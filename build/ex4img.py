#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""ex4img.py: image plumbing for the WD My Cloud EX4 revival. Pure file work, off the box; touches no device.

  split  UIMAGE OUTDIR            legacy uImage (kernel + appended DTB, the OpenWrt kirkwood shape) -> zImage, old.dtb
  join   ZIMAGE DTB OUT           zImage + DTB appended (what stock U-Boot 1.1.4 / ex4boot can start: the kernel needs
                                  CONFIG_ARM_APPENDED_DTB + CONFIG_ARM_ATAG_DTB_COMPAT, both on in OpenWrt kirkwood)
  uimage PAYLOAD OUT [--name N] [--max BYTES]
                                  wrap as a legacy uImage: arm/linux/kernel, comp none, load = entry = 0x8000 (the stock
                                  mtd1 header values). --max 5242880 refuses anything that does not fit mtd1.
  atags  OUT [--mem MB] [--initrd ADDR,SIZE] [--cmdline S] [--mv-uboot HEX]
                                  the ATAG list a Marvell U-Boot hands the kernel (CORE, MEM, INITRD2, CMDLINE, NONE),
                                  for ex4boot's r2=0x100 segment. --mv-uboot appends a raw Marvell tag body (stock-kernel boots).
  info   FILE                     what a file is (uImage header, zImage size, appended DTB, crc32 the way ex4boot prints it)
 v2 (Nov 16 2026, the stock-kernel handoff test):
  payload UIMAGE OUT [--with-header] [--expect-md5 HEX]
                                  the payload of a legacy uImage found at the start of UIMAGE (a file or a raw mtd dump),
                                  both CRCs checked. --with-header keeps the 64-byte header in front (the bytes exactly
                                  as flash holds them: what `nand read` puts in RAM). --expect-md5 = md5 of header+payload.
  atags-parse FILE [--at HEX] [--expect-token T] [--expect-initrd ADDR,SIZE] [--max-end HEX]
                                  read an ATAG list back (a file, or a memory dump with --at 0x100) and check it:
                                  CORE first, every size sane, ends in NONE. Prints every tag. Exit 1 on any failure.
  atags-clone CAPTURE OUT --cmdline-add TOKEN [--at HEX]
                                  U-Boot's OWN list, read live from the box's RAM (physical 0x100; stock keeps that page),
                                  re-emitted tag for tag, byte for byte, with ONE change: TOKEN appended to the command
                                  line (size worked out the way U-Boot 1.1.4 does: (8 + strlen + 1 + 4) >> 2 words).
                                  Nov 26 2026: [--initrd ADDR,SIZE] = a second change, INITRD2's start and size (the
                                  stage-2 ramdisk RAM proof: a bigger ramdisk than the one U-Boot loaded).
  rduimage GZ OUT --time HEX [--name Ramdisk] [--load 0x00e00000] [--max BYTES]
                                  wrap gzip data as a legacy ramdisk uImage (os linux, arch arm, type ramdisk, comp gzip):
                                  the header mkimage -T ramdisk -C gzip writes, by our own code (mkstage2.sh).
  marker OUT --run ID --pos N --total N --dest HEX
                                  one 4096-byte RAM marker block (layout: userland/ex4peek.c, `marker`), loaded by ex4boot as
                                  one more segment at --dest.
  layout SEGS [--root DIR]        SEGS = lines "file address" in copy order (files relative to DIR, default the
                                  current folder): sizes, ranges, and a refusal on any overlap
                                  between segments or with the places a 3.2.40 boot writes before it reads them
                                  (decompressor page table 0x4000-0x7fff; U-Boot's vector copy 0x0-0x3f is noted only).

Born Nov 16 2026 (EX4 tooling). Every output path must not exist yet (never overwrites)."""
import argparse
import hashlib
import os
import struct
import sys
import time
import zlib

UMAGIC = 0x27051956
ZMAGIC = 0x016f2818
FDT = 0xd00dfeed


def rd(p):
    with open(p, 'rb') as f:
        return f.read()


def wr(p, b):
    if os.path.exists(p):
        sys.exit(f"REFUSED: {p} exists (never overwrite)")
    with open(p, 'wb') as f:
        f.write(b)
    print(f"wrote {p}  {len(b)} bytes  crc32 {zlib.crc32(b) & 0xffffffff:08x}")


def parse_uimage(b):
    if len(b) < 64 or struct.unpack('>I', b[:4])[0] != UMAGIC:
        return None
    magic, hcrc, t, size, load, ep, dcrc, os_, arch, typ, comp = struct.unpack('>7I4B', b[:32])
    name = b[32:64].rstrip(b'\0').decode('latin1')
    h = bytearray(b[:64]); h[4:8] = b'\0\0\0\0'
    return dict(hcrc_ok=(zlib.crc32(bytes(h)) & 0xffffffff) == hcrc, time=t, size=size, load=load, ep=ep,
                dcrc_ok=(zlib.crc32(b[64:64 + size]) & 0xffffffff) == dcrc, os=os_, arch=arch, type=typ, comp=comp, name=name)


def zimage_len(z):
    if len(z) < 0x30 or struct.unpack('<I', z[0x24:0x28])[0] != ZMAGIC:
        sys.exit("REFUSED: not an ARM zImage (magic 0x016f2818 missing at 0x24)")
    start, end = struct.unpack('<II', z[0x28:0x30])
    return end - start


def split_payload(p):
    n = zimage_len(p)
    z, rest = p[:n], p[n:]
    if rest and struct.unpack('>I', rest[:4])[0] != FDT:
        sys.exit("REFUSED: bytes after the zImage are not a device tree")
    if rest:
        dl = struct.unpack('>I', rest[4:8])[0]
        if dl > len(rest):
            sys.exit("REFUSED: appended DTB is truncated")
        rest = rest[:dl]
    return z, rest


def c_split(a):
    b = rd(a.uimage); u = parse_uimage(b)
    if not u or not u['hcrc_ok'] or not u['dcrc_ok']:
        sys.exit("REFUSED: not a legacy uImage with good CRCs")
    z, d = split_payload(b[64:64 + u['size']])
    os.makedirs(a.outdir, exist_ok=True)
    wr(os.path.join(a.outdir, 'zImage'), z)
    if d:
        wr(os.path.join(a.outdir, 'old.dtb'), d)
    print(f"uImage name {u['name']!r} load {u['load']:#x} ep {u['ep']:#x}; zImage {len(z)} + dtb {len(d)}")


def c_join(a):
    z = rd(a.zimage); d = rd(a.dtb)
    if zimage_len(z) != len(z):
        sys.exit("REFUSED: the zImage already has something appended (split it first)")
    if struct.unpack('>I', d[:4])[0] != FDT or struct.unpack('>I', d[4:8])[0] != len(d):
        sys.exit("REFUSED: not a clean DTB")
    wr(a.out, z + d)


def c_uimage(a):
    p = rd(a.payload)
    zimage_len(p)
    name = a.name.encode()[:31]
    h = struct.pack('>7I4B32s', UMAGIC, 0, int(time.time()), len(p), 0x8000, 0x8000, zlib.crc32(p) & 0xffffffff,
                    5, 2, 2, 0, name)          # os linux(5) arch arm(2) type kernel(2) comp none(0)
    h = h[:4] + struct.pack('>I', zlib.crc32(h) & 0xffffffff) + h[8:]
    out = h + p
    if a.max and len(out) > a.max:
        sys.exit(f"REFUSED: uImage is {len(out)} bytes, over --max {a.max}")
    wr(a.out, out)


def c_rduimage(a):
    """Nov 26 2026 (stage-2 v1): our own writer for the ramdisk uImage header, so mkstage2.sh needs no mkimage
    (u-boot-tools is not on the build box, and nothing gets installed). Same fields mkimage -T ramdisk -C gzip
    writes and WD's stock mtd2 header holds: os linux(5) arch arm(2) type ramdisk(3) comp gzip(1)."""
    p = rd(a.payload)
    if p[:2] != b'\x1f\x8b':
        sys.exit("REFUSED: payload is not gzip data")
    load = int(a.load, 0)
    name = a.name.encode()[:31]
    h = struct.pack('>7I4B32s', UMAGIC, 0, int(a.time, 0), len(p), load, load, zlib.crc32(p) & 0xffffffff,
                    5, 2, 3, 1, name)
    h = h[:4] + struct.pack('>I', zlib.crc32(h) & 0xffffffff) + h[8:]
    out = h + p
    if a.max and len(out) > a.max:
        sys.exit(f"REFUSED: uImage is {len(out)} bytes, over --max {a.max}")
    u = parse_uimage(out)
    assert u and u['hcrc_ok'] and u['dcrc_ok'] and u['type'] == 3 and u['comp'] == 1
    wr(a.out, out)
    print(f"ramdisk uImage: name {u['name']!r} time {u['time']:#x} load {u['load']:#x} ep {u['ep']:#x} data {u['size']} bytes, "
          f"header + data CRCs OK; md5 {hashlib.md5(out).hexdigest()}")


def tag(t, body=b''):
    body += b'\0' * (-len(body) % 4)
    return struct.pack('<II', (8 + len(body)) // 4, t) + body


def c_atags(a):
    out = tag(0x54410001, struct.pack('<III', 0, 0, 0))                    # ATAG_CORE flags, pagesize, rootdev
    out += tag(0x54410002, struct.pack('<II', a.mem << 20, 0))             # ATAG_MEM size, start
    if a.initrd:
        addr, size = (int(x, 0) for x in a.initrd.split(','))
        out += tag(0x54420005, struct.pack('<II', addr, size))             # ATAG_INITRD2 (physical)
    if a.cmdline is not None:
        out += tag(0x54410009, a.cmdline.encode() + b'\0')                 # ATAG_CMDLINE
    if a.mv_uboot:
        out += tag(0x41000403, bytes.fromhex(a.mv_uboot))                  # ATAG_MV_UBOOT (Marvell LSP kernels only)
    out += struct.pack('<II', 0, 0)                                        # ATAG_NONE
    if len(out) > 0x7f00:
        sys.exit("REFUSED: ATAG list would run into the kernel at 0x8000")
    wr(a.out, out)


def c_info(a):
    b = rd(a.file)
    print(f"{a.file}: {len(b)} bytes, crc32 {zlib.crc32(b) & 0xffffffff:08x}")
    u = parse_uimage(b)
    if u:
        print("  legacy uImage:", u)
        b = b[64:64 + u['size']]
    if len(b) > 0x30 and struct.unpack('<I', b[0x24:0x28])[0] == ZMAGIC:
        z, d = split_payload(b)
        print(f"  zImage {len(z)} bytes; appended DTB {len(d)} bytes; payload crc32 {zlib.crc32(b) & 0xffffffff:08x}")


# ---- v2: the stock-kernel handoff test ----
ATAG = {0x54410001: 'CORE', 0x54410002: 'MEM', 0x54410003: 'VIDEOTEXT', 0x54410004: 'RAMDISK', 0x54410005: 'INITRD',
        0x54420005: 'INITRD2', 0x54410006: 'SERIAL', 0x54410007: 'REVISION', 0x54410009: 'CMDLINE', 0x41000403: 'MV_UBOOT'}


def c_payload(a):
    b = rd(a.uimage); u = parse_uimage(b)
    if not u or not u['hcrc_ok'] or not u['dcrc_ok']:
        sys.exit("REFUSED: no legacy uImage with good header and data CRCs at the start of the input")
    whole = b[:64 + u['size']]
    md5 = hashlib.md5(whole).hexdigest()
    if a.expect_md5 and md5 != a.expect_md5:
        sys.exit(f"REFUSED: header+payload md5 is {md5}, expected {a.expect_md5}")
    print(f"uImage name {u['name']!r} type {u['type']} comp {u['comp']} load {u['load']:#x} ep {u['ep']:#x} payload {u['size']} bytes; header+payload md5 {md5}")
    wr(a.out, whole if a.with_header else whole[64:])


def parse_atags(b, base=0):
    """-> list of (offset, tag, size_words, body). Raises ValueError on a broken list."""
    tags = []; o = base
    while True:
        if o + 8 > len(b):
            raise ValueError(f"list runs off the end at {o:#x}")
        size, tag = struct.unpack('<II', b[o:o + 8])
        if size == 0:
            if tag != 0:
                raise ValueError(f"size 0 with tag {tag:#x} at {o:#x} (ATAG_NONE must be 0,0)")
            tags.append((o, 0, 0, b''))
            return tags
        if size < 2 or size > 0x400 or o + 4 * size > len(b):
            raise ValueError(f"tag {tag:#x} at {o:#x} has size {size} words")
        tags.append((o, tag, size, b[o + 8:o + 4 * size]))
        o += 4 * size


def show_atags(tags):
    for o, tag, size, body in tags:
        name = ATAG.get(tag, 'NONE' if tag == 0 and size == 0 else '?')
        if name == 'CORE':
            d = "flags %#x pagesize %#x rootdev %#x" % struct.unpack('<III', body[:12]) if len(body) >= 12 else "(no body)"
        elif name == 'MEM':
            d = "size %#x start %#x" % struct.unpack('<II', body[:8])
        elif name == 'INITRD2':
            d = "start %#x size %#x (%d)" % (struct.unpack('<II', body[:8]) + (struct.unpack('<I', body[4:8])[0],))
        elif name == 'CMDLINE':
            d = repr(body.split(b'\0')[0].decode('latin1'))
        elif name == 'MV_UBOOT':
            v, tclk, sysclk, usb = struct.unpack('<IIII', body[:16])
            d = f"uboot_version {v:#x} tclk {tclk} sysclk {sysclk} isUsbHost {usb:#x} mac0 {body[16:22].hex(':')} mac1 {body[22:28].hex(':')} mtu {struct.unpack('<4H', body[40:48])} nand_ecc {struct.unpack('<I', body[48:52])[0]} ({len(body)} body bytes)"
        else:
            d = body.hex() if body else ''
        print(f"  +{o:#06x} {name:9s} {tag:#010x} size {size:2d} words  {d}")


def c_atags_parse(a):
    b = rd(a.file); base = int(a.at, 0) if a.at else 0
    try:
        tags = parse_atags(b, base)
    except ValueError as e:
        sys.exit(f"REFUSED: {e}")
    show_atags(tags)
    end = tags[-1][0] + 8
    print(f"list is {end - base} bytes ({base:#x}..{end:#x})")
    if tags[0][1] != 0x54410001:
        sys.exit("REFUSED: the first tag is not ATAG_CORE (the kernel would ignore the whole list)")
    cmd = [t for t in tags if t[1] == 0x54410009]
    if a.expect_token is not None:
        if len(cmd) != 1 or a.expect_token not in cmd[0][3].split(b'\0')[0].decode('latin1').split(' '):
            sys.exit(f"REFUSED: the command line does not hold the token {a.expect_token!r}")
        print(f"OK: command line holds {a.expect_token!r}")
    if a.expect_initrd:
        addr, size = (int(x, 0) for x in a.expect_initrd.split(','))
        ird = [struct.unpack('<II', t[3][:8]) for t in tags if t[1] == 0x54420005]
        if ird != [(addr, size)]:
            sys.exit(f"REFUSED: INITRD2 is {ird}, expected start {addr:#x} size {size:#x}")
        print(f"OK: INITRD2 start {addr:#x} size {size:#x}")
    if a.max_end and 0x100 + (end - base) > int(a.max_end, 0):          # the list is always loaded at physical 0x100
        sys.exit(f"REFUSED: loaded at 0x100 the list ends at {0x100 + end - base:#x}, past {a.max_end}")


def c_atags_clone(a):
    b = rd(a.capture); base = int(a.at, 0) if a.at else 0
    try:
        tags = parse_atags(b, base)
    except ValueError as e:
        sys.exit(f"REFUSED: capture: {e}")
    if tags[0][1] != 0x54410001 or sum(1 for t in tags if t[1] == 0x54410009) != 1:
        sys.exit("REFUSED: capture is not a U-Boot list (no CORE first, or not exactly one CMDLINE)")
    tok = a.cmdline_add
    if not tok or ' ' in tok or any(ord(c) < 33 or ord(c) > 126 for c in tok):
        sys.exit("REFUSED: the token must be printable ASCII without spaces")
    ird = None
    if a.initrd:                                                     # Nov 26 2026: a second change, INITRD2's start+size only
        ird = tuple(int(x, 0) for x in a.initrd.split(','))
        if len(ird) != 2 or sum(1 for t in tags if t[1] == 0x54420005) != 1:
            sys.exit("REFUSED: --initrd needs ADDR,SIZE and a capture with exactly one INITRD2 tag")
    out = b''
    for o, tag, size, body in tags:
        if tag == 0x54420005 and ird:
            old = struct.unpack('<II', body[:8])
            out += struct.pack('<II', size, tag) + struct.pack('<II', *ird) + body[8:]
            print(f"INITRD2: start {old[0]:#x} size {old[1]:#x} -> start {ird[0]:#x} size {ird[1]:#x}")
        elif tag == 0x54410009:
            old = body.split(b'\0')[0]
            new = old + b' ' + tok.encode()
            words = (8 + len(new) + 1 + 4) >> 2                      # U-Boot 1.1.4 setup_commandline_tag
            nb = new + b'\0' * (4 * words - 8 - len(new))
            out += struct.pack('<II', words, tag) + nb
            print(f"command line: {old.decode('latin1')!r} + {tok!r} ({size} -> {words} words)")
        elif size == 0:
            out += struct.pack('<II', 0, 0)
        else:
            out += struct.pack('<II', size, tag) + body               # verbatim
    if len(out) > 0xe00:
        sys.exit("REFUSED: the list would reach the first RAM marker at 0x1000")
    wr(a.out, out)


def marker_block(run, pos, total, dest):
    rb = run.encode()
    if not rb or len(rb) > 63 or any(c < 33 or c > 126 for c in rb):
        sys.exit("REFUSED: run id must be 1..63 printable ASCII characters without spaces")
    seed = (zlib.crc32(rb + struct.pack('<III', pos, total, dest)) & 0xffffffff) | 1
    head = b'EX4MARK1' + struct.pack('<IIIII', 1, pos, total, dest, seed)
    rid = rb + b'\0' * (64 - len(rb))
    hcrc = zlib.crc32(head + rid) & 0xffffffff
    x = seed; pat = bytearray()
    for _ in range((4096 - 0x100) // 4):
        x ^= (x << 13) & 0xffffffff; x ^= x >> 17; x ^= (x << 5) & 0xffffffff
        pat += struct.pack('<I', x)
    blk = head + struct.pack('<I', hcrc) + rid + b'\0' * (0x100 - 0x60) + bytes(pat)
    assert len(blk) == 4096
    return blk


def c_marker(a):
    dest = int(a.dest, 0)
    if dest & 0xfff:
        sys.exit("REFUSED: --dest must be a multiple of 4096 (the reader scans at 4 KiB steps)")
    wr(a.out, marker_block(a.run, a.pos, a.total, dest))


def c_layout(a):
    segs = []
    base = a.root or os.getcwd()                                        # SEGS names files relative to the bundle folder
    for line in open(a.segs):
        line = line.split('#')[0].split()
        if not line:
            continue
        f, addr = line[0], int(line[1], 0)
        n = os.path.getsize(os.path.join(base, f))
        segs.append((f, addr, addr + ((n + 3) & ~3), n))                # the stub copies whole words
    if not 1 <= len(segs) <= 6:
        sys.exit(f"REFUSED: {len(segs)} segments (ex4boot takes 1..6)")
    for f, lo, hi, n in segs:
        print(f"  {lo:#010x}..{hi:#010x}  {n:8d} bytes  {f}")
        if lo & 3 or hi > 0x20000000:
            sys.exit(f"REFUSED: {f}: address not word aligned or past 512 MiB")
    bad = 0
    for i, (f, lo, hi, n) in enumerate(segs):
        for g, lo2, hi2, n2 in segs[:i]:
            if lo < hi2 and lo2 < hi:
                print(f"OVERLAP: {f} and {g}"); bad = 1
        if lo < 0x8000 and hi > 0x4000:
            print(f"OVERLAP: {f} lies in 0x4000-0x7fff, where the decompressor builds its page table"); bad = 1
        if lo < 0x40:
            print(f"OVERLAP: {f} covers the exception vectors U-Boot left at 0x0-0x3f"); bad = 1
    if bad:
        sys.exit("REFUSED: overlapping layout")
    print(f"OK: {len(segs)} segments, no overlap (each other, the decompressor's page table at 0x4000-0x7fff, 0x0-0x3f)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest='cmd', required=True)
    s = sp.add_parser('payload'); s.add_argument('uimage'); s.add_argument('out'); s.add_argument('--with-header', action='store_true')
    s.add_argument('--expect-md5'); s.set_defaults(f=c_payload)
    s = sp.add_parser('atags-parse'); s.add_argument('file'); s.add_argument('--at'); s.add_argument('--expect-token')
    s.add_argument('--expect-initrd'); s.add_argument('--max-end'); s.set_defaults(f=c_atags_parse)
    s = sp.add_parser('atags-clone'); s.add_argument('capture'); s.add_argument('out'); s.add_argument('--cmdline-add', required=True)
    s.add_argument('--at'); s.add_argument('--initrd'); s.set_defaults(f=c_atags_clone)
    s = sp.add_parser('rduimage'); s.add_argument('payload'); s.add_argument('out'); s.add_argument('--name', default='Ramdisk')
    s.add_argument('--load', default='0x00e00000'); s.add_argument('--time', required=True)
    s.add_argument('--max', type=int, default=0); s.set_defaults(f=c_rduimage)
    s = sp.add_parser('marker'); s.add_argument('out'); s.add_argument('--run', required=True); s.add_argument('--pos', type=int, required=True)
    s.add_argument('--total', type=int, required=True); s.add_argument('--dest', required=True); s.set_defaults(f=c_marker)
    s = sp.add_parser('layout'); s.add_argument('segs'); s.add_argument('--root'); s.set_defaults(f=c_layout)
    s = sp.add_parser('split'); s.add_argument('uimage'); s.add_argument('outdir'); s.set_defaults(f=c_split)
    s = sp.add_parser('join'); s.add_argument('zimage'); s.add_argument('dtb'); s.add_argument('out'); s.set_defaults(f=c_join)
    s = sp.add_parser('uimage'); s.add_argument('payload'); s.add_argument('out'); s.add_argument('--name', default='EX4 Linux')
    s.add_argument('--max', type=int, default=0); s.set_defaults(f=c_uimage)
    s = sp.add_parser('atags'); s.add_argument('out'); s.add_argument('--mem', type=int, default=512); s.add_argument('--initrd')
    s.add_argument('--cmdline'); s.add_argument('--mv-uboot'); s.set_defaults(f=c_atags)
    s = sp.add_parser('info'); s.add_argument('file'); s.set_defaults(f=c_info)
    a = ap.parse_args(); a.f(a)


main()
