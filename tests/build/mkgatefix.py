#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""tests/build/mkgatefix.py: FIXTURES for build/v9/overlay-gate.py's bundle mode (v9.8, tests/build/bundle-gate-test.sh).
Writes a SYNTHETIC bundle (no real kernel, no real modules: the bytes only have to be what the gate reads) laid out as
build-v9.sh's bundle stage lays it out: overlay.cpio (newc, carrying exactly what the overlay checks read for --no-webui
--no-rwbench), RUNID, VARIANT (absent for stock), KMODS.txt, atags.bin (ATAG_CORE + ATAG_CMDLINE + ATAG_NONE), MD5SUMS.

  mkgatefix.py key DIR                         a fixture public key line -> DIR/key.pub (not a real key: the gate compares text)
  mkgatefix.py bundle DIR --variant V --key KEY.pub [--kmods default|diet|prof] [--no-md5] [--runid R]
  mkgatefix.py md5sums DIR                     recompute DIR/MD5SUMS over the files a bundle lists (VARIANT iff present)
  mkgatefix.py refkmods FILE                   the DEFAULT kernel's KMODS.txt (for --ref-kmods)

Kmods: default = the default / uaccess / nfsdtrack kernels' bytes, diet = another set (diet and ud: JUMP_LABEL changes every
module), prof = ftrace-instrumented (carries __gnu_mcount_nc). Default --kmods follows the variant's kernel twin."""
import hashlib
import os
import struct
import sys

KVER = '6.12.112'
KOS = ('xhci-hcd', 'xhci-pci', 'xhci-plat-hcd')
TWINS = ('prof', 'prof2', 'uaccess', 'diet', 'ud', 'nfsdtrack')
BASE = '16-l2off-20261118-1300'
LISTED = ['ex4boot-l2off.ko', 'ex4peek', 'ex4log', 'ex4fan', 'KMODS.txt', 'kernel.bin', 'overlay.cpio', 'atags.bin', 'markA.bin',
          'markC.bin', 'markH.bin', 'SEGS', 'EXPECT', 'RUNID', 'CFG', 'LOGCFG', 'PROVENANCE', 'ex4-trial.sh']


def ko_bytes(kind, name):
    body = b'\x7fELF fixture ' + name.encode() + b' built for the ' + kind.encode() + b' kernel\n'
    return body + (b'\x00__gnu_mcount_nc\x00' if kind == 'prof' else b'')


def newc(entries):
    out, ino = b'', 1
    for name, mode, data in entries + [('TRAILER!!!', 0, b'')]:
        nb = name.encode() + b'\0'
        f = [ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nb), 0]
        h = b'070701' + b''.join(b'%08x' % v for v in f)
        out += h + nb
        out += b'\0' * ((-len(out)) % 4)
        out += data
        out += b'\0' * ((-len(out)) % 4)
        ino += 1
    return out


def overlay(key, kmods):
    trial = ("grep -q '^root::' /etc/shadow && sed -i 's/^root::/root:*:/' /etc/shadow\n"
             "uci -q set dropbear.@dropbear[0].PasswordAuth='off'\nuci -q set dropbear.@dropbear[0].RootPasswordAuth='off'\n"
             "uci -q delete uhttpd.main.listen_http\nuci -q add_list uhttpd.main.listen_http='127.0.0.1:80'\n"
             "uci -q delete uhttpd.main.listen_https\nuci -q delete uhttpd.main.ubus_prefix\n")
    e = [('etc', 0o040755, b''), ('etc/ex4', 0o040755, b''), ('etc/ex4/overlay-stamp', 0o100644, b'mkoverlay v8 secfix=1 keyonly=1 webui=0\n'),
         ('etc/uci-defaults', 0o040755, b''), ('etc/uci-defaults/99-ex4-trial', 0o100755, trial.encode()),
         ('etc/dropbear', 0o040700, b''), ('etc/dropbear/authorized_keys', 0o100600, (key + '\n').encode()),
         ('etc/init.d', 0o040755, b''), ('etc/init.d/ex4-trial', 0o100755, b'#!/bin/sh\nreboot\n'),
         ('etc/init.d/ex4-deadman', 0o100755, b'#!/bin/sh\nreboot -f\n'),
         ('lib', 0o040755, b''), ('lib/modules', 0o040755, b''), ('lib/modules/' + KVER, 0o040755, b'')]
    for m in KOS:
        e.append(('lib/modules/%s/%s.ko' % (KVER, m), 0o100644, ko_bytes(kmods, m)))
    return newc(e)


def kmods_txt(kind):
    lines = ['xhci modules: from this build\'s own image (lib/modules/%s, byte-identical to the copies inside kernel.bin\'s initramfs)' % KVER,
             '%s  ./etc/modules.d/54-usb3' % hashlib.md5(b'xhci-pci\n').hexdigest()]
    for m in KOS:
        lines.append('%s  ./lib/modules/%s/%s.ko' % (hashlib.md5(ko_bytes(kind, m)).hexdigest(), KVER, m))
    return '\n'.join(lines) + '\n'


def atags(cmdline):
    c = cmdline.encode() + b'\0'
    c += b'\0' * ((-len(c)) % 4)
    return (struct.pack('<IIIII', 5, 0x54410001, 0, 4096, 0) + struct.pack('<II', 2 + len(c) // 4, 0x54410009) + c
            + struct.pack('<II', 0, 0))


def variant_text(v):
    toks = v.split('+')
    twin = ([t for t in toks if t in TWINS] or [None])[0]
    out = ['VARIANT=' + v, 'XOR=' + ('off' if 'xoroff' in toks else 'on')]
    if 'xoroff' in toks:
        out.append('XOR=off: both orion-xor nodes (xor@60800, xor@60900) status disabled in kernel.bin\'s DTB')
    if 'nomemcg' in toks:
        out.append('CMDLINE_ARM=nomemcg: the kernel command line adds cgroup_disable=memory (bench arm; kernel, DTB, kmods unchanged)')
    if twin == 'prof':
        out += ['PROFILE TWIN: never ship', 'PROFILE=1: kernel with FTRACE (fixture)']
    elif twin == 'prof2':
        out += ['PROFILE TWIN: never ship', 'TWIN=prof2: kernel with FUNCTION_GRAPH_TRACER (fixture)']
    elif twin:
        out.append('TWIN=%s: bench kernel twin (fixture)' % twin)
    if twin:
        out.append('kernel-config-md5=' + hashlib.md5(('fixture kernel .config of ' + twin).encode()).hexdigest())
    return '\n'.join(out) + '\n'


def md5sums(d):
    names = LISTED + (['VARIANT'] if os.path.isfile(os.path.join(d, 'VARIANT')) else [])
    with open(os.path.join(d, 'MD5SUMS'), 'w') as f:
        for n in names:
            f.write('%s  %s\n' % (hashlib.md5(open(os.path.join(d, n), 'rb').read()).hexdigest(), n))


def main():
    a = sys.argv[1:]
    if a[:1] == ['key'] and len(a) == 2:
        os.makedirs(a[1], exist_ok=True)
        open(os.path.join(a[1], 'key.pub'), 'w').write('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREfixturefixturefixturefixturefixture0001 gate-fixture\n')
        return 0
    if a[:1] == ['md5sums'] and len(a) == 2:
        md5sums(a[1])
        return 0
    if a[:1] == ['refkmods'] and len(a) == 2:
        open(a[1], 'w').write(kmods_txt('default'))
        return 0
    if a[:1] != ['bundle'] or len(a) < 2:
        sys.exit(__doc__)
    d, rest = a[1], a[2:]
    v, key, kind, domd5, rid = None, None, None, True, None
    while rest:
        if rest[0] == '--variant':
            v, rest = rest[1], rest[2:]
        elif rest[0] == '--key':
            key, rest = open(rest[1]).read().strip(), rest[2:]
        elif rest[0] == '--kmods':
            kind, rest = rest[1], rest[2:]
        elif rest[0] == '--runid':
            rid, rest = rest[1], rest[2:]
        elif rest[0] == '--no-md5':
            domd5, rest = False, rest[1:]
        else:
            sys.exit(__doc__)
    if not v or not key:
        sys.exit(__doc__)
    toks = [] if v == 'stock' else v.split('+')
    twin = ([t for t in toks if t in TWINS] or [None])[0]
    if kind is None:
        kind = 'prof' if twin in ('prof', 'prof2') else 'diet' if twin in ('diet', 'ud') else 'default'
    os.makedirs(d)
    w = lambda n, b: open(os.path.join(d, n), 'wb').write(b if isinstance(b, bytes) else b.encode())
    for n in LISTED:
        w(n, 'fixture ' + n + '\n')
    rid = rid or BASE + ''.join('-' + t for t in toks)
    w('RUNID', rid + '\n')
    w('overlay.cpio', overlay(key, kind))
    w('KMODS.txt', kmods_txt(kind))
    w('atags.bin', atags('console=ttyS0,115200n8 watchdog.open_timeout=120 ex4boot_run=' + rid + (' cgroup_disable=memory' if 'nomemcg' in toks else '')))
    if toks:
        w('VARIANT', variant_text(v))
    if domd5:
        md5sums(d)
    return 0


if __name__ == '__main__':
    sys.exit(main())
