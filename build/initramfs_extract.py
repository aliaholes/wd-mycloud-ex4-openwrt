#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""initramfs_extract.py: unpack the initramfs that an OpenWrt initramfs-uImage carries inside its kernel, off the box.

  python3 -I initramfs_extract.py <openwrt ...-initramfs-uImage> <outdir (must not exist)> [PATH ...]

Without PATH: every regular file, directory and symlink of the archive is written under <outdir> (device nodes are
skipped: nothing here needs them, and making them needs root). With PATHs (e.g. etc/board.d/02_network): only those.
Reads one file, writes only under <outdir>, never overwrites. The image is data from the network: paths that are
absolute or climb out with ".." are refused.
"""
import lzma, os, stat, struct, sys


def payload(path):
    d = open(path, 'rb').read()
    if d[:4] == b'\x27\x05\x19\x56':
        size = struct.unpack('>I', d[12:16])[0]; d = d[64:64 + size]
    best = None; i = 0
    while True:
        i = d.find(b'\xfd7zXZ\x00', i)
        if i < 0: break
        try:
            o = lzma.LZMADecompressor(lzma.FORMAT_AUTO).decompress(d[i:])
            if best is None or len(o) > len(best): best = o
        except Exception: pass
        i += 1
    if not best or len(best) < 1 << 20: sys.exit("REFUSED: no xz kernel payload in " + path)
    return best


def entries(img):
    p = img.find(b'070701')
    while p >= 0:
        try:
            int(img[p + 6:p + 110], 16); break
        except ValueError:
            p = img.find(b'070701', p + 1)
    if p < 0: sys.exit("REFUSED: no initramfs archive inside the kernel image")
    while True:
        if img[p:p + 6] != b'070701': sys.exit("REFUSED: initramfs archive is cut at %#x" % p)
        f = [int(img[p + 6 + 8 * i:p + 14 + 8 * i], 16) for i in range(13)]
        ns, fs = f[11], f[6]; name = img[p + 110:p + 110 + ns - 1].decode(); p = (p + 110 + ns + 3) & ~3
        body = img[p:p + fs]; p = (p + fs + 3) & ~3
        if name == 'TRAILER!!!': return
        yield name, f[1], body


def main():
    if len(sys.argv) < 3: sys.exit(__doc__)
    src, out, want = sys.argv[1], sys.argv[2], set(sys.argv[3:])
    if os.path.exists(out): sys.exit("REFUSED: %s exists (never overwrite)" % out)
    os.makedirs(out); root = os.path.realpath(out); n = 0; got = set()
    for name, mode, body in entries(payload(src)):
        if name in ('.', ''): continue
        if name.startswith('/') or '..' in name.split('/'): sys.exit("REFUSED: archive entry with an unsafe path: %r" % name)
        if want and name not in want: continue
        dst = os.path.join(root, name)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.realpath(os.path.dirname(dst)) != os.path.dirname(dst): sys.exit("REFUSED: %r would be written through a symlink" % name)
        if stat.S_ISDIR(mode): os.makedirs(dst, exist_ok=True)
        elif stat.S_ISLNK(mode): os.symlink(body.rstrip(b'\0').decode(), dst)
        elif stat.S_ISREG(mode):
            with open(dst, 'xb') as f: f.write(body)
            os.chmod(dst, mode & 0o755)
        else: continue
        n += 1; got.add(name)
    if want - got: sys.exit("REFUSED: not in the image's initramfs: " + " ".join(sorted(want - got)))
    print("wrote %d entries under %s" % (n, out))


main()
