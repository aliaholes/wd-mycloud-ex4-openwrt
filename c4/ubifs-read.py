#!/usr/bin/env python3
"""ubifs-read.py (FINALIZE C4 AMEND 2, Nov 27 2026; finding F4 of the C4 session): read the files of a USED UBI image (a dump of the C4
sim, written by the 6.12 kernel) the way the kernel's UBIFS mount sees them: the INDEX from the newest master node, then THE JOURNAL
REPLAYED (log -> REF nodes -> buds, every bud node applied in sqnum order with its deletions: an inode with nlink 0 removes the inode
and all its keys, a dent with inum 0 removes that name, a TRUN node drops the data blocks past its new size). build-mtd3.py check
(2be21514) is a FRESH-BUILD checker: it takes the newest node per key across every LEB and never applies a deletion, so on a used image
it shows uci temp files, `.new` names and stale bytes (C4b.0 extract, box/C4b.0-extract-full.txt). This file replaces nothing; it is
the C4c baseline's reader (C4c-BASELINE.md) and it is checked against what the box itself read (C4a.6 / C4a.8 / C4a.9 receipts).

  python3 -I ubifs-read.py IMAGE [--skip-peb N ...] [--extract DIR] [--json FILE]

UBI: every PEB's EC + VID header is checked (magic, version, CRC); PEBs given by --skip-peb (the sim's bad block 1501) and all-0xFF PEBs
are skipped; a LEB mapped twice = the higher sqnum wins unless it is a copy (copy_flag) whose data CRC fails (ubi/attach.c
ubi_compare_lebs). UBIFS (fs/ubifs/*.h + replay.c, 6.12): superblock (LEB 0), master (LEBs 1, 2: the valid node with the highest
sqnum), index walk from root_lnum/root_offs (idx node: child_cnt, level, branches of lnum/offs/len/8-byte simple key), log from
log_lnum (first node = the CS node with the master's cmt_no; REF nodes = buds; a later log LEB whose first node is older than the CS
node = the end of the log), buds scanned from their REF offset. Every node read is CRC-checked. Orphan nodes are listed (master flag
NO_ORPHS says whether any matter). Data: compr none + zlib (raw deflate) decoded; lzo/zstd reported, never guessed. Writes only --extract
(a NEW dir) and --json (a NEW file). Opens no device.
"""
import argparse, hashlib, json, os, struct, sys, zlib

PEB = 131072; VID_OFF = 2048; DATA_OFF = 4096; LEB = PEB - DATA_OFF
LAYOUT_VOL_ID = 0x7FFFEFFF; VTBL_REC = 172
UBIFS_MAGIC = 0x06101831; ROOT_INO = 1; BLOCK = 4096
INO, DATA, DENT, XENT, TRUN, PAD, SB, MST, REF, IDX, CS, ORPH = range(12)
NAMES = {0: 'INO', 1: 'DATA', 2: 'DENT', 3: 'XENT', 4: 'TRUN', 5: 'PAD', 6: 'SB', 7: 'MST', 8: 'REF', 9: 'IDX', 10: 'CS', 11: 'ORPH'}
MST_FLAGS = {1: 'DIRTY', 2: 'NO_ORPHS', 4: 'RCVRY'}


def die(m):
    sys.exit(f"ubifs-read: REFUSED: {m}")


def crc(b):                                     # crc32_le(0xffffffff, b), no final inversion (UBI_CRC32_INIT / UBIFS_CRC32_INIT)
    return (~zlib.crc32(b)) & 0xffffffff


def ubi_lebs(img, skip):
    if len(img) % PEB: die(f"image {len(img)} B is not whole 128 KiB PEBs")
    n = len(img) // PEB; cand = {}; stats = dict(pebs=n, skipped=sorted(skip), empty=0, ec_only=0, mapped=0, dup=0)
    for p in range(n):
        if p in skip: continue
        b = img[p * PEB:(p + 1) * PEB]
        if b == b'\xff' * PEB: stats['empty'] += 1; continue
        magic, ver, ec, vo, do, iseq = struct.unpack('>IB3xQIII', b[:28])
        if magic != 0x55424923 or ver != 1 or crc(b[:60]) != struct.unpack('>I', b[60:64])[0] or vo != VID_OFF or do != DATA_OFF:
            die(f"PEB {p}: bad EC header")
        v = b[VID_OFF:VID_OFF + 64]
        if v == b'\xff' * 64: stats['ec_only'] += 1; continue
        (vm, vver, vtype, copy, compat, vol, lnum, dsize, used, dpad, dcrc, sq) = struct.unpack('>IBBBBII4xIIII4xQ', v[:48])
        if vm != 0x55424921 or vver != 1 or crc(v[:60]) != struct.unpack('>I', v[60:64])[0]:
            die(f"PEB {p}: bad VID header")
        cand.setdefault((vol, lnum), []).append(dict(peb=p, sq=sq, copy=copy, dsize=dsize, dcrc=dcrc, data=b[DATA_OFF:]))
    lebs = {}
    for k, cs in cand.items():
        cs.sort(key=lambda c: c['sq'], reverse=True)
        if len(cs) > 1: stats['dup'] += 1
        pick = None
        for c in cs:                            # ubi_compare_lebs: the newer one, unless it is a copy whose data CRC is bad
            if c['copy'] and c['dsize'] and crc(c['data'][:c['dsize']]) != c['dcrc']:
                continue
            pick = c; break
        if pick is None: die(f"LEB {k}: no usable copy")
        lebs[k] = pick
    stats['mapped'] = len(lebs)
    return lebs, stats


def vtbl(lebs):
    l0 = lebs.get((LAYOUT_VOL_ID, 0))
    if not l0: die("no layout volume")
    vols = {}
    for i in range(128):
        rec = l0['data'][i * VTBL_REC:(i + 1) * VTBL_REC]
        if crc(rec[:168]) != struct.unpack('>I', rec[168:172])[0]: die(f"vtbl record {i} CRC")
        rsv = struct.unpack('>I', rec[:4])[0]; nlen = struct.unpack('>H', rec[14:16])[0]
        if rsv: vols[i] = rec[16:16 + nlen].decode('latin1')
    return vols


class Vol:
    def __init__(self, name, lebs):
        self.name = name; self.lebs = lebs; self.notes = []; self.counts = {}

    def leb(self, lnum):
        return self.lebs[lnum]['data'] if lnum in self.lebs else b'\xff' * LEB

    def node(self, lnum, offs, want=None):
        d = self.leb(lnum)
        magic, c, sq, ln, nt = struct.unpack('<IIQIB', d[offs:offs + 21])
        if magic != UBIFS_MAGIC or ln < 24 or offs + ln > LEB or c != crc(d[offs + 8:offs + ln]):
            die(f"{self.name}: no valid node at LEB {lnum}:{offs:#x}")
        if want is not None and nt != want: die(f"{self.name}: LEB {lnum}:{offs:#x} is {NAMES.get(nt)}, want {NAMES.get(want)}")
        return dict(lnum=lnum, offs=offs, sq=sq, len=ln, type=nt, b=d[offs:offs + ln])

    def scan(self, lnum, offs=0):
        """every node of a LEB from offs until the erased tail (a bad node = the end of what was written: recovery's view)"""
        d = self.leb(lnum); o = offs; out = []
        while o + 24 <= LEB:
            if d[o:o + 4] == b'\xff\xff\xff\xff':
                if d[o:].count(0xff) != LEB - o:
                    self.notes.append(f"LEB {lnum} +{o:#x}: 0xFF then data (an unclean tail; stopped there)")
                break
            if d[o] == 0xCE: o += 1; continue                   # padding bytes
            magic, c, sq, ln, nt = struct.unpack('<IIQIB', d[o:o + 21])
            if magic != UBIFS_MAGIC or ln < 24 or o + ln > LEB or c != crc(d[o + 8:o + ln]):
                self.notes.append(f"LEB {lnum} +{o:#x}: no valid node (the end of the written data in this LEB)"); break
            out.append(dict(lnum=lnum, offs=o, sq=sq, len=ln, type=nt, b=d[o:o + ln]))
            o += (ln + struct.unpack('<I', d[o + 24:o + 28])[0]) if nt == PAD else ((ln + 7) & ~7)
        return out


def key_of(n):
    b = n['b']; a, x = struct.unpack('<II', b[24:32]); return a, x >> 29, x & 0x1fffffff


def leaf_entry(n):
    """(dict key, node) for a leaf node: ('ino', inum) | ('data', inum, blk) | ('dent', parent, name)"""
    b = n['b']; inum, kt, low = key_of(n)
    if n['type'] == INO: return ('ino', inum)
    if n['type'] == DATA: return ('data', inum, low)
    if n['type'] in (DENT, XENT):
        nlen = struct.unpack('<H', b[50:52])[0]
        return ('dent' if n['type'] == DENT else 'xent', inum, b[56:56 + nlen].decode('latin1'))
    return None


def read_volume(v):
    sb = v.node(0, 0, SB)['b']
    log_lebs, lpt_lebs, orph_lebs = struct.unpack('<III', sb[56:68])
    fmt = struct.unpack('<I', sb[80:84])[0]; compr = struct.unpack('<H', sb[84:86])[0]
    msts = [n for l in (1, 2) for n in v.scan(l) if n['type'] == MST]
    if not msts: die(f"{v.name}: no master node")
    m = max(msts, key=lambda n: n['sq'])['b']
    highest_inum, cmt_no, flags, log_lnum, root_lnum, root_offs, root_len = struct.unpack('<QQIIIII', m[24:60])
    info = dict(fmt=fmt, default_compr=compr, log_lebs=log_lebs, lpt_lebs=lpt_lebs, orph_lebs=orph_lebs, master_sqnum=max(n['sq'] for n in msts),
                cmt_no=cmt_no, master_flags=[nm for bit, nm in MST_FLAGS.items() if flags & bit], log_lnum=log_lnum,
                root=f"{root_lnum}:{root_offs:#x}/{root_len}", highest_inum=highest_inum)
    # ---- the index (the committed state)
    tree = {}; nidx = 0

    def walk(lnum, offs):
        nonlocal nidx
        ix = v.node(lnum, offs, IDX); nidx += 1; b = ix['b']
        cnt, level = struct.unpack('<HH', b[24:28])
        for i in range(cnt):
            bl, bo, blen = struct.unpack('<III', b[28 + i * 20:40 + i * 20])
            if level > 0:
                walk(bl, bo)
            else:
                n = v.node(bl, bo)
                if n['len'] != blen: die(f"{v.name}: branch len {blen} != node len {n['len']} at {bl}:{bo:#x}")
                k = leaf_entry(n)
                if k is None: die(f"{v.name}: an indexed {NAMES.get(n['type'])} node")
                tree[k] = n
    walk(root_lnum, root_offs)
    info['index'] = dict(idx_nodes=nidx, leaves=len(tree))
    # ---- the log -> buds (replay.c ubifs_replay_journal / replay_log_leb)
    first_log, nlog = 3, log_lebs
    lnum = log_lnum; cs_sq = None; buds = []; seen = 0
    while True:
        nodes = v.scan(lnum)
        if cs_sq is None:
            if not nodes or nodes[0]['type'] != CS or struct.unpack('<Q', nodes[0]['b'][24:32])[0] != cmt_no:
                die(f"{v.name}: log LEB {lnum} does not start with the CS node of commit {cmt_no}")
            cs_sq = nodes[0]['sq']; nodes = nodes[1:]
        elif not nodes or nodes[0]['sq'] < cs_sq:
            break                                               # older log data: the end of this log
        end = False
        for n in nodes:
            if n['sq'] < cs_sq: end = True; break
            if n['type'] == REF:
                rl, ro, jh = struct.unpack('<III', n['b'][24:36]); buds.append((n['sq'], rl, ro, jh))
            elif n['type'] == PAD: pass
            elif n['type'] == CS: die(f"{v.name}: a second CS node in the log at {lnum}")
            else: die(f"{v.name}: a {NAMES.get(n['type'])} node in the log")
        seen += 1
        if end or seen >= nlog: break
        lnum = first_log + (lnum - first_log + 1) % nlog
        if lnum == log_lnum: break
    rep = []
    for sq, rl, ro, jh in buds:
        rep += v.scan(rl, ro)
    rep.sort(key=lambda n: n['sq'])
    info['journal'] = dict(buds=[f"LEB {rl}+{ro:#x} jhead {jh}" for _, rl, ro, jh in buds], nodes={})
    for n in rep:
        t = NAMES.get(n['type']); info['journal']['nodes'][t] = info['journal']['nodes'].get(t, 0) + 1
        b = n['b']
        if n['type'] == INO:
            inum = key_of(n)[0]; nlink = struct.unpack('<I', b[92:96])[0]
            if nlink == 0:
                for k in [k for k in tree if k[1] == inum]: del tree[k]       # ubifs_tnc_remove_ino: every key of the inode
            else:
                tree[('ino', inum)] = n
        elif n['type'] in (DENT, XENT):
            k = leaf_entry(n); tgt = struct.unpack('<Q', b[40:48])[0]
            if tgt == 0: tree.pop(k, None)                          # a deletion entry
            else: tree[k] = n
        elif n['type'] == DATA:
            tree[leaf_entry(n)] = n
        elif n['type'] == TRUN:
            inum = struct.unpack('<I', b[24:28])[0]; old, new = struct.unpack('<QQ', b[40:56])
            mn = new // BLOCK + (1 if new % BLOCK else 0)
            for k in [k for k in tree if k[0] == 'data' and k[1] == inum and k[2] >= mn]: del tree[k]
        elif n['type'] in (PAD, CS, REF, IDX):
            pass
        else:
            die(f"{v.name}: a {t} node in a bud")
    # ---- orphans (listed; NO_ORPHS in the master flags = none apply)
    orph = []
    for l in range(3 + log_lebs + lpt_lebs, 3 + log_lebs + lpt_lebs + orph_lebs):
        for n in v.scan(l):
            if n['type'] == ORPH:
                cnt = (n['len'] - 32) // 8; orph += list(struct.unpack(f'<{cnt}Q', n['b'][32:32 + 8 * cnt]))
    info['orphans'] = orph
    # ---- the files
    inos = {k[1]: n for k, n in tree.items() if k[0] == 'ino'}
    dents = [(k[1], k[2], struct.unpack('<Q', n['b'][40:48])[0]) for k, n in tree.items() if k[0] == 'dent']
    paths = {ROOT_INO: ''}
    for _ in range(32):
        for par, name, tgt in dents:
            if par in paths and tgt not in paths: paths[tgt] = paths[par] + '/' + name
    files = {}; problems = []
    for inum, path in sorted(paths.items(), key=lambda x: x[1]):
        if inum not in inos: problems.append(f"{path or '/'} (inum {inum}): a name with no inode"); continue
        b = inos[inum]['b']; size = struct.unpack('<Q', b[48:56])[0]
        nlink, uid, gid, mode, fl, dlen = struct.unpack('<IIIIII', b[92:116])
        kind = {0o100000: 'file', 0o040000: 'dir', 0o120000: 'link'}.get(mode & 0o170000, 'other')
        e = dict(inum=inum, kind=kind, mode=oct(mode & 0o7777), size=size, nlink=nlink, sqnum=inos[inum]['sq'])
        if kind == 'file':
            buf = bytearray(size); ok = True
            for k, n in tree.items():
                if k[0] != 'data' or k[1] != inum: continue
                nb = n['b']; dsize, ct = struct.unpack('<IH', nb[40:46]); pay = nb[48:]
                if ct == 0: ch = pay[:dsize]
                elif ct == 2: ch = zlib.decompressobj(-15).decompress(pay)
                else: ok = False; problems.append(f"{path}: block {k[2]} compr {ct} not decoded"); continue
                if len(ch) != dsize: problems.append(f"{path}: block {k[2]} {len(ch)} B, header {dsize}")
                lo = k[2] * BLOCK
                if lo < size: buf[lo:min(size, lo + len(ch))] = ch[:max(0, size - lo)]
            e['bytes'] = bytes(buf) if ok else None
            if ok: e['md5'] = hashlib.md5(buf).hexdigest()
        elif kind == 'link':
            e['target'] = b[160:160 + dlen].decode('latin1')
        files[path or '/'] = e
    unreached = [i for i in inos if i not in paths]
    if unreached: problems.append(f"inodes with no name: {sorted(unreached)}")
    return info, files, problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('image'); ap.add_argument('--skip-peb', type=int, action='append', default=[])
    ap.add_argument('--extract'); ap.add_argument('--json')
    a = ap.parse_args()
    for p in (a.extract, a.json):
        if p and os.path.exists(p): die(f"{p} exists")
    img = open(a.image, 'rb').read()
    print(f"image {a.image}: {len(img)} B, md5 {hashlib.md5(img).hexdigest()}")
    lebs, st = ubi_lebs(img, set(a.skip_peb))
    print(f"UBI: {st}")
    vols = vtbl(lebs); out = {}; bad = 0
    for vid, name in sorted(vols.items()):
        v = Vol(name, {l: d for (vv, l), d in lebs.items() if vv == vid})
        info, files, problems = read_volume(v)
        print(f"== volume {vid} '{name}': {json.dumps(info)}")
        for nt in v.notes: print(f"   note: {nt}")
        for p in problems: print(f"   PROBLEM: {p}"); bad += 1
        for p, e in files.items():
            print(f"   {e['kind']:5s} {e['mode']} {p}" + (f"  {e['size']} B md5 {e.get('md5', 'UNDECODED')}" if e['kind'] == 'file' else '')
                  + (f" -> {e['target']}" if e['kind'] == 'link' else ''))
        out[name] = dict(info=info, files={p: {k: x for k, x in e.items() if k != 'bytes'} for p, e in files.items()}, problems=problems)
        if a.extract:
            for p, e in files.items():
                q = os.path.join(a.extract, name + p)
                if e['kind'] == 'dir': os.makedirs(q, exist_ok=True)
                elif e['kind'] == 'file' and e.get('bytes') is not None:
                    os.makedirs(os.path.dirname(q), exist_ok=True)
                    with open(q, 'xb') as f: f.write(e['bytes'])
    if a.json:
        with open(a.json, 'x') as f: json.dump(out, f, indent=1, sort_keys=True)
    print(f"RESULT: {'OK' if not bad else f'{bad} PROBLEM(S)'}")
    sys.exit(1 if bad else 0)


main()
