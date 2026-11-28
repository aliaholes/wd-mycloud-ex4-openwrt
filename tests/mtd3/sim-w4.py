#!/usr/bin/env python3
"""sim-w4.py (D2 PREP, Nov 27 2026, the C4 build lane): sim-r4.py (4200d0c6) with THE WALL-4 TEST added. mtd2 and its pin now hold the
REAL stage2 v2 r4 image (d65082b2, 3421663 B) and its PROVEN marker sits beside the script (as on the box), instead of r4's "fake v2"
(v1 with one byte flipped, which the new wall 4 refuses by design). Added cases W4-1..W4-6 (mode plan, the disarmed copy, read-only):
the pin naming r2 (22d8fea5, the real image in mtd2) or r3 (28f71fd1) must be REFUSED, an unlisted image REFUSED, a missing marker, a
marker whose line 1 is another md5, and only the VOID-A16form file all REFUSED. Run against ex4-mtd3.sh dd66f91e (before) the W4 cases
FAIL (it accepts r2/r3: the finding); against the new script every case passes.

    python3 -I sim-w4.py SIMROOT SCRIPT IMGDIR DUMPDIR BUILDER S2V1 S2R4 S2R2 S2R3 MARKER

sim-r4.py = B1/mtd3/sim.py (EX4 finalize C2C3 r4, Nov 26 2026) with: the sim copies also rewrite UBI_CTRL=/dev/ubi_ctrl to
SIMROOT/ubi_ctrl (a file the sim creates), and the fake ubiattach / ubidetach demand the r4 argument lists EXACTLY:
`-m 3 -d 3 -O 2048 CTRL` and `-d 3 CTRL` (the real busybox 1.36.1 applets REQUIRE UBI_CTRL_DEV; C2 failed at A6 without it).
Everything else is B1's sim.

sim.py: sim-test of box/ex4-mtd3.sh OFF the box, Nov 26 2026, EX4 finalize B4.

    python3 -I sim.py SIMROOT SCRIPT IMGDIR DUMPDIR BUILDER S2V1

SIMROOT  a NEW folder (refused if it exists); everything this run writes goes under it
SCRIPT   ex4-mtd3.sh as shipped (never edited: sim copies are made from it, the changed lines printed)
IMGDIR   a build-mtd3.py output folder (mtd3.ubi, mtd3.ubi.md5, MANIFEST)
DUMPDIR  the Nov 16 NAND dump folder (mtd1.dd, mtd3.dd): seeds the fake flash as REGULAR FILES
BUILDER  build-mtd3.py (the fake `mount` re-extracts the volumes with its checker)
S2V1     the stage2 v1 image (d2c6d5e6), for the "mtd2 still holds v1" refusal

The fake flash tools refuse ANY path under /dev (exit 98) and are faithful to the two NAND facts that matter:
flash_eraseall and nandwrite -p SKIP the bad block (1501), and nandwrite SHIFTS data past it. SIM_MODE on nandwrite:
ok | flip1 (first write corrupted) | flipall (every write corrupted) | failrc (rc 1). The script runs under the host's
busybox sh (applets preferred, like a busybox box) except the verify cases, which run under dash so the fake
mount/umount on PATH are used (busybox sh would run its own mount applet).
"""
import hashlib, os, shutil, subprocess, sys

SIM, SCRIPT, IMGDIR, DUMPDIR, BUILDER, S2V1, S2R4, S2R2, S2R3, MARKER = (os.path.abspath(x) for x in sys.argv[1:11])
BLK = 131072; BAD = 1501
WANT_VERSION = 'Linux version 3.2.40 (kman@kmachine) (gcc version 4.6.4 20120731 (prerelease) (Linaro GCC branch-4.6.4. Marvell GCC 201301-1645.aee66e26) ) #1 Fri Nov 16 11:50:03 CST 2018'
PROC_MTD = '''dev:    size   erasesize  name
mtd0: 00100000 00020000 "u-boot"
mtd1: 00500000 00020000 "uImage"
mtd2: 00500000 00020000 "ramdisk"
mtd3: 0cd00000 00020000 "image"
mtd4: 00f00000 00020000 "rescue firmware"
mtd5: 01400000 00020000 "config"
mtd6: 00500000 00020000 "reserve"
'''
if os.path.exists(SIM):
    sys.exit(f"REFUSED: {SIM} exists")
os.makedirs(SIM)
B = os.path.join(SIM, 'bin'); os.makedirs(B)
LOG = open(os.path.join(SIM, 'sim-output.txt'), 'w')


def out(s=''):
    print(s); LOG.write(s + '\n'); LOG.flush()


def md5f(p, n=None):
    h = hashlib.md5()
    with open(p, 'rb') as f:
        left = n
        while True:
            b = f.read(1 << 20 if left is None else min(1 << 20, left))
            if not b: break
            h.update(b)
            if left is not None:
                left -= len(b)
                if not left: break
    return h.hexdigest()


# ---- fake tools (python, refuse /dev) -----------------------------------------------------------------------------
HDR = '''#!/usr/bin/python3 -I
import os, sys, json
SIM = os.environ["SIMROOT"]; BLK = 131072; BAD = int(os.environ.get("SIM_BAD", "1501"))
for a in sys.argv[1:]:
    if a.startswith("/dev") or "/dev/" in a:
        sys.stderr.write("SIM REFUSES /dev\\n"); sys.exit(98)
def note(s):
    open(os.path.join(SIM, "tool-calls.log"), "a").write(os.path.basename(sys.argv[0]) + " " + s + "\\n")
'''
TOOLS = {
 'flash_eraseall': HDR + '''
dev = sys.argv[1]; note(dev)
if os.environ.get("SIM_MODE") == "eraserc": sys.exit(1)
n = os.path.getsize(dev) // BLK
with open(dev, "r+b") as f:
    for i in range(n):
        if i == BAD: continue                      # an erase skips a bad block: its old bytes stay
        f.seek(i * BLK); f.write(b"\\xff" * BLK)
print("Erasing 128 Kibyte @ %x -- 100 %% complete." % ((n - 1) * BLK))
''',
 'nandwrite': HDR + '''
if sys.argv[1] != "-p": sys.exit(97)
dev, src = sys.argv[2], sys.argv[3]; note(dev + " " + src)
st = os.path.join(SIM, "nandwrite.count"); c = int(open(st).read()) + 1 if os.path.exists(st) else 1; open(st, "w").write(str(c))
mode = os.environ.get("SIM_MODE", "ok")
if mode == "failrc": sys.exit(1)
data = open(src, "rb").read(); data += b"\\xff" * (-len(data) % 2048)
n = os.path.getsize(dev) // BLK; blk = 0; o = 0
with open(dev, "r+b") as f:
    while o < len(data):
        if blk == BAD: blk += 1; continue          # nandwrite -p skips the bad block and shifts the rest
        if blk >= n: sys.stderr.write("past the end\\n"); sys.exit(1)
        f.seek(blk * BLK); f.write(data[o:o + BLK]); o += BLK; blk += 1
    if mode == "flipall" or (mode == "flip1" and c == 1):
        f.seek(100000); b = f.read(1); f.seek(100000); f.write(bytes([b[0] ^ 1]))
''',
 'ubiattach': HDR + '''
note(" ".join(sys.argv[1:]))
if sys.argv[1:] != ["-m", "3", "-d", "3", "-O", "2048", os.path.join(SIM, "ubi_ctrl")]: sys.stderr.write("FAKE: ubiattach args are not the r4 list\\n"); sys.exit(1)
d = os.path.join(SIM, "sys/class/ubi/ubi3"); os.makedirs(d); open(os.path.join(d, "mtd_num"), "w").write("3\\n")
print("UBI device number 3, total 1639 LEBs")
''',
 'ubidetach': HDR + '''
note(" ".join(sys.argv[1:]))
d = os.path.join(SIM, "sys/class/ubi/ubi3")
if sys.argv[1:] != ["-d", "3", os.path.join(SIM, "ubi_ctrl")] or not os.path.isdir(d): sys.exit(1)
os.remove(os.path.join(d, "mtd_num")); os.rmdir(d)
''',
 'mount': HDR + '''
import subprocess, shutil
note(" ".join(sys.argv[1:]))
if sys.argv[1:3] != ["-t", "ubifs"] or not sys.argv[3].startswith("ubi3:") or len(sys.argv) != 5: sys.exit(1)
if not os.path.isdir(os.path.join(SIM, "sys/class/ubi/ubi3")): sys.exit(1)
vol, mnt = sys.argv[3][5:], sys.argv[4]
k = len([x for x in os.listdir(SIM) if x.startswith("mnt-extract-")])
img = os.path.join(SIM, "mnt-extract-%d.ubi" % k); ex = os.path.join(SIM, "mnt-extract-%d" % k)
with open(os.path.join(SIM, "dev-mtd3"), "rb") as f, open(img, "wb") as g:
    g.write(f.read(BAD * BLK))                     # the UBI area before the bad block
p = subprocess.run([sys.executable, "-I", os.environ["SIM_BUILDER"], "check", img, "--extract", ex], stdout=subprocess.PIPE, text=True)
open(img + ".check.txt", "w").write(p.stdout)
os.remove(img)
if p.returncode: sys.stderr.write("mount: UBIFS check failed (see %s.check.txt)\\n" % img); sys.exit(1)
src = os.path.join(ex, vol)
if os.path.isdir(src):
    for n in os.listdir(src): shutil.copy(os.path.join(src, n), os.path.join(mnt, n))
if vol == "ex4data" and "ex4data holds the empty /etc/config skeleton" in p.stdout:
    os.makedirs(os.path.join(mnt, "etc/config"), exist_ok=True)
open(os.path.join(SIM, "mounted"), "a").write(mnt + "\\n")
''',
 'umount': HDR + '''
note(" ".join(sys.argv[1:])); mnt = sys.argv[1]
m = os.path.join(SIM, "mounted")
if not os.path.exists(m) or mnt not in open(m).read().split(): sys.exit(1)
for root, dirs, files in os.walk(mnt, topdown=False):
    for n in files: os.remove(os.path.join(root, n))
    for n in dirs: os.rmdir(os.path.join(root, n))
open(m, "w").write("".join(l + "\\n" for l in open(m).read().split() if l != mnt))
''',
}
for n, src in TOOLS.items():
    p = os.path.join(B, n); open(p, 'w').write(src); os.chmod(p, 0o755)

# ---- the fake box ------------------------------------------------------------------------------------------------
P = os.path.join(SIM, 'proc'); S = os.path.join(SIM, 'sys'); os.makedirs(P); os.makedirs(os.path.join(S, 'class/mtd/mtd3'))
os.makedirs(os.path.join(S, 'class/ubi'))
open(os.path.join(SIM, 'ubi_ctrl'), 'w').close()                 # r4: the fake UBI_CTRL_DEV node
for n, t in (('version', WANT_VERSION + '\n'), ('cpuinfo', 'Processor\t: Feroceon 88FR131 rev 1 (v5l)\n'),
             ('cmdline', 'console=ttyS0,115200 root=/dev/ram0 mac_addr=... DB88FXX81\n'), ('mtd', PROC_MTD),
             ('mounts', 'rootfs / rootfs rw 0 0\n/dev/loop0 /usr/local/modules squashfs ro 0 0\n')):
    open(os.path.join(P, n), 'w').write(t)
open(os.path.join(S, 'class/mtd/mtd3/bad_blocks'), 'w').write('1\n')
def cpw(a, b):                                                  # a writable copy (the dump files are read-only)
    if os.path.exists(b): os.chmod(b, 0o644)
    shutil.copyfile(a, b); os.chmod(b, 0o644)
cpw(os.path.join(DUMPDIR, 'mtd1.dd'), os.path.join(SIM, 'dev-mtd1'))
s2v1 = open(S2V1, 'rb').read()
fake_v2 = open(S2R4, 'rb').read()                                  # sim-w4: the REAL r4 image (the only one wall 4 accepts now)
assert hashlib.md5(fake_v2).hexdigest() == 'd65082b20d13970bdb20e6dfe68103ff' and len(fake_v2) == 3421663, 'S2R4 is not d65082b2'
r2img = open(S2R2, 'rb').read(); r3img = open(S2R3, 'rb').read()
assert hashlib.md5(r2img).hexdigest() == '22d8fea57c4827fcadcf51be3dd2b76b' and hashlib.md5(r3img).hexdigest() == '28f71fd15f293942071ee2dfcb356b65'
FV2_MD5 = hashlib.md5(fake_v2).hexdigest()
def put_mtd2(img):
    open(os.path.join(SIM, 'dev-mtd2'), 'wb').write(img + b'\xff' * (5242880 - len(img)))
put_mtd2(fake_v2)
HD = os.path.join(SIM, 'HD'); os.makedirs(HD)
BOX = os.path.join(SIM, 'box'); os.makedirs(BOX)
for n in ('mtd3.ubi', 'mtd3.ubi.md5', 'MANIFEST'):
    shutil.copy(os.path.join(IMGDIR, n), os.path.join(BOX, n))
open(os.path.join(BOX, 'STAGE2-V2-IN-MTD2'), 'w').write(f"{FV2_MD5} {len(fake_v2)}\n")
MK = os.path.join(BOX, 'STAGE2-V2-PROVEN-d65082b2'); shutil.copyfile(MARKER, MK)       # the marker beside the script, as on the box
assert open(MK).readline().strip() == 'd65082b20d13970bdb20e6dfe68103ff', 'MARKER line 1 is not d65082b2'
DUMP = os.path.join(DUMPDIR, 'mtd3.dd'); DUMP_MD5 = md5f(DUMP)
MTD3 = os.path.join(SIM, 'dev-mtd3')
def reseed():
    cpw(DUMP, MTD3)


# ---- sim copies of the script: exact line replacements, each asserted once, the diff printed -------------------
orig = open(SCRIPT).read()
def simcopy(name, armed, keep_wall1=False):
    s = orig
    reps = [('TARGET=/dev/mtd3\n', f'TARGET={MTD3}\n'), ('MTD2=/dev/mtd2\n', f'MTD2={SIM}/dev-mtd2\n'),
            ('MTD1=/dev/mtd1\n', f'MTD1={SIM}/dev-mtd1\n'), ('PROC=/proc\n', f'PROC={P}\n'), ('SYS=/sys\n', f'SYS={S}\n'),
            ('UBI_CTRL=/dev/ubi_ctrl\n', f'UBI_CTRL={SIM}/ubi_ctrl\n'), ('MNTBASE=/tmp\n', f'MNTBASE={SIM}\n'), ('/mnt/HD/*) ;;', f'{HD}/*) ;;')]
    if not keep_wall1:
        reps.append(('[ "$TARGET" = /dev/mtd3 ] && [ "$TARGET_NAME" = image ] && [ "$MTD2" = /dev/mtd2 ] && [ "$MTD1" = /dev/mtd1 ] \\\n'
                     '\t\t&& [ "$PROC" = /proc ] && [ "$SYS" = /sys ]',
                     f'[ "$TARGET" = {MTD3} ] && [ "$TARGET_NAME" = image ] && [ "$MTD2" = {SIM}/dev-mtd2 ] && [ "$MTD1" = {SIM}/dev-mtd1 ] \\\n'
                     f'\t\t&& [ "$PROC" = {P} ] && [ "$SYS" = {S} ]'))
    if armed:
        reps.append(('\nARMED=0\n', '\nARMED=1\n'))
    for a, b in reps:
        assert s.count(a) == 1, a
        s = s.replace(a, b)
    p = os.path.join(BOX, name); open(p, 'w').write(s)
    ch = [i + 1 for i, (x, y) in enumerate(zip(orig.split('\n'), s.split('\n'))) if x != y]
    out(f"sim copy {name}: {len(ch)} line(s) differ from ex4-mtd3.sh {md5f(SCRIPT)}: lines {ch}")
    return p
DISARMED = simcopy('ex4-mtd3.sim-disarmed.sh', False)
ARMED = simcopy('ex4-mtd3.sim-armed.sh', True)
UNWALLED = simcopy('ex4-mtd3.sim-wall1-unedited.sh', True, keep_wall1=True)

ENV = dict(os.environ, PATH=B + ':' + os.environ['PATH'], SIMROOT=SIM, SIM_BUILDER=os.path.abspath(BUILDER))
results = []
def run(label, script, mode, d=None, sim_mode='ok', want_rc=None, sh=('busybox', 'sh'), want_text=None):
    e = dict(ENV, SIM_MODE=sim_mode)
    for f in ('nandwrite.count',):
        q = os.path.join(SIM, f)
        if os.path.exists(q): os.remove(q)
    argv = list(sh) + [script, mode] + ([d] if d else [])
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=e)
    ok = (want_rc is None or p.returncode == want_rc) and (want_text is None or want_text in p.stdout)
    results.append((label, ok))
    out(f"=== [{'PASS' if ok else 'FAIL'}] {label}  ({' '.join([os.path.basename(argv[0])] + argv[1:2] + [os.path.basename(script), mode] + ([os.path.relpath(d, SIM)] if d else []))}, SIM_MODE={sim_mode}) rc={p.returncode} want {want_rc}")
    for l in p.stdout.rstrip().split('\n'):
        out('    ' + l)
    return p

def state(label):
    h = md5f(MTD3); img = os.path.join(BOX, 'mtd3.ubi'); n = os.path.getsize(img)
    out(f"    fake mtd3 now: full md5 {h}{' (= the Nov 16 dump)' if h == DUMP_MD5 else ''}; first {n // BLK} blocks md5 "
        f"{md5f(MTD3, n)}{' (= the image)' if md5f(MTD3, n) == md5f(img) else ''}")
    return h

out(f"SIM ROOT {SIM}; script {SCRIPT} md5 {md5f(SCRIPT)}; image {md5f(os.path.join(IMGDIR, 'mtd3.ubi'))}; dump {DUMP_MD5}; "
    f"fake stage2 v2 {FV2_MD5} ({len(fake_v2)} B)")
for sh in (('busybox', 'sh'), ('dash',)):
    p = subprocess.run(list(sh) + ['-n', SCRIPT], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    results.append((f"{' '.join(sh)} -n", p.returncode == 0)); out(f"=== [{'PASS' if p.returncode == 0 else 'FAIL'}] {' '.join(sh)} -n ex4-mtd3.sh rc={p.returncode} {p.stdout.strip()}")
BK = os.path.join(HD, 'bk'); os.makedirs(BK)
reseed()

# A. disarmed copy: plan works, every writing mode refuses
run('plan (disarmed): walls pass, nothing written', DISARMED, 'plan', want_rc=0, want_text='PLAN ONLY')
run('backup (disarmed is fine: read-only)', DISARMED, 'backup', BK, want_rc=0, want_text='= the Nov 16 dump')
run('backup again: refused, never overwrite', DISARMED, 'backup', BK, want_rc=1, want_text='a backup exists')
for m in ('write', 'restore'):
    run(f'{m} with ARMED=0: refused', DISARMED, m, BK, want_rc=1, want_text='ARMED=0')
run('verify with ARMED=0: refused', DISARMED, 'verify', want_rc=1, want_text='ARMED=0')
out(f"    backup files: mtd3.backup {md5f(os.path.join(BK, 'mtd3.backup'))}  mtd3.head {md5f(os.path.join(BK, 'mtd3.head'))}")
state('after A')

# B. refusals (armed copy)
def refuse(label, text, setup, undo, mode='write', d=BK, script=ARMED):
    setup(); run(label, script, mode, d, want_rc=1, want_text=text); undo()
pin = os.path.join(BOX, 'STAGE2-V2-IN-MTD2'); pin_txt = open(pin).read()
refuse('no STAGE2-V2-IN-MTD2 pin: refused', 'wall 4: no', lambda: os.rename(pin, pin + '.off'), lambda: os.rename(pin + '.off', pin))
refuse('pin names stage2 v1: refused', 'neither has the belt', lambda: open(pin, 'w').write(f"{hashlib.md5(s2v1).hexdigest()} {len(s2v1)}\n"),
       lambda: open(pin, 'w').write(pin_txt))
# ---- W4 (sim-w4): THE WALL-4 TEST, mode plan on the disarmed copy (read-only), each must REFUSE
def w4(label, text, setup, undo):
    setup(); run(label, DISARMED, 'plan', want_rc=1, want_text=text); undo()
def pin_img(img):
    open(pin, 'w').write(f"{hashlib.md5(img).hexdigest()} {len(img)}\n"); put_mtd2(img)
def unpin(): open(pin, 'w').write(pin_txt); put_mtd2(fake_v2)
w4('W4-1 pin + mtd2 = stage2 v2 r2 (22d8fea5, the real image): refused', 'r2 or r3', lambda: pin_img(r2img), unpin)
w4('W4-2 pin + mtd2 = stage2 v2 r3 (28f71fd1, the real image): refused', 'r2 or r3', lambda: pin_img(r3img), unpin)
unl = fake_v2[:-1] + bytes([fake_v2[-1] ^ 0xff])
w4('W4-3 pin + mtd2 = an image not on the PROVEN list: refused', 'is not a stage2 v2 whose UBI branch is PROVEN', lambda: pin_img(unl), unpin)
w4('W4-4 the PROVEN marker missing: refused', 'no PROVEN marker', lambda: os.rename(MK, MK + '.off'), lambda: os.rename(MK + '.off', MK))
mk_txt = open(MK).read()
w4("W4-5 the marker's line 1 = another md5: refused", 'no PROVEN marker', lambda: open(MK, 'w').write('22d8fea57c4827fcadcf51be3dd2b76b\n'),
   lambda: open(MK, 'w').write(mk_txt))
def void_only(): os.rename(MK, MK + '.VOID-A16form')
def unvoid(): os.rename(MK + '.VOID-A16form', MK)
w4('W4-6 only STAGE2-V2-PROVEN-d65082b2.VOID-A16form present: refused', 'no PROVEN marker', void_only, unvoid)
run('W4-7 the real r4 pin + its marker: plan passes (walls 1-6)', DISARMED, 'plan', want_rc=0, want_text='stage2 v2 d65082b20d13970bdb20e6dfe68103ff in mtd2')
refuse('mtd2 still holds stage2 v1: refused', 'mtd2 still holds stage2 v1', lambda: put_mtd2(s2v1), lambda: put_mtd2(fake_v2))
refuse('mtd2 holds something else than the pin: refused', 'does not hold the pinned stage2 v2',
       lambda: put_mtd2(fake_v2[:-5] + b'XXXXX'), lambda: put_mtd2(fake_v2))
sc = os.path.join(BOX, 'mtd3.ubi.md5'); sc_txt = open(sc).read()
refuse('image md5 differs from its sidecar: refused', 'differs from its sidecar', lambda: open(sc, 'w').write('0' * 32 + '  mtd3.ubi\n'),
       lambda: open(sc, 'w').write(sc_txt))
img = os.path.join(BOX, 'mtd3.ubi'); img_b = open(img, 'rb').read()
def setimg(b):
    open(img, 'wb').write(b); open(sc, 'w').write(hashlib.md5(b).hexdigest() + '  mtd3.ubi\n')
refuse("image not starting with 'UBI#': refused", "does not start with 'UBI#'", lambda: setimg(b'XBI#' + img_b[4:]), lambda: setimg(img_b))
refuse('image reaching the bad block: refused', 'must end before bad block', lambda: setimg(img_b + b'\xff' * BLK * 1400), lambda: setimg(img_b))
bb = os.path.join(S, 'class/mtd/mtd3/bad_blocks')
refuse('mtd3 with 2 bad blocks: refused', 'bad block(s)', lambda: open(bb, 'w').write('2\n'), lambda: open(bb, 'w').write('1\n'))
u3 = os.path.join(S, 'class/ubi/ubi7')
def att(): os.makedirs(u3); open(os.path.join(u3, 'mtd_num'), 'w').write('3\n')
def det(): os.remove(os.path.join(u3, 'mtd_num')); os.rmdir(u3)
refuse('a UBI device attached to mtd3: refused', 'is attached to mtd3', att, det)
m1 = os.path.join(SIM, 'dev-mtd1'); m1_b = open(m1, 'rb').read()
refuse("mtd1 not WD's kernel: refused", 'wall 3', lambda: open(m1, 'wb').write(b'\0' + m1_b[1:]), lambda: open(m1, 'wb').write(m1_b))
pv = os.path.join(P, 'version')
refuse('another kernel version: refused', 'wall 2', lambda: open(pv, 'w').write('Linux version 6.12.112\n'),
       lambda: open(pv, 'w').write(WANT_VERSION + '\n'))
refuse('TARGET pointed elsewhere, wall 1 left as shipped: refused', 'wall 1', lambda: None, lambda: None, script=UNWALLED)
refuse('DIR not on the data disk: refused', 'data disk', lambda: None, lambda: None, d=SIM)
BK2 = os.path.join(HD, 'bk-bad'); os.makedirs(BK2)
for n in ('mtd3.backup', 'mtd3.head'): cpw(os.path.join(BK, n), os.path.join(BK2, n))
with open(os.path.join(BK2, 'mtd3.backup'), 'r+b') as f: f.seek(5000); f.write(b'Z')
refuse('backup file damaged: refused', 'is not the Nov 16 dump', lambda: None, lambda: None, d=BK2)
def poke():
    with open(MTD3, 'r+b') as f: f.seek(900 * BLK + 7); f.write(b'\0')
refuse('mtd3 changed after the backup: refused', 'no longer reads as the backup', poke, reseed)
state('after B (nothing may have changed)')

# C. the good path: write -> raw read-back; a second write refused; verify (dash, fake mount); restore
run('write ok', ARMED, 'write', BK, want_rc=0, want_text='DONE: mtd3 holds the UBI image')
state('after the good write')
run('write again while mtd3 is UBI: refused', ARMED, 'write', BK, want_rc=1, want_text='a write starts only from stock')
run('verify ok (dash: the fake mount re-extracts the volumes)', ARMED, 'verify', want_rc=0, want_text='VERIFIED', sh=('dash',))
with open(MTD3, 'r+b') as f:
    f.seek(100 * BLK + 4096 + 5000); b = f.read(1); f.seek(100 * BLK + 4096 + 5000); f.write(bytes([b[0] ^ 1]))
run('verify with one flipped byte in the kernel data: VERIFY FAILED', ARMED, 'verify', want_rc=1, want_text='VERIFY FAILED', sh=('dash',))
run('restore ok', ARMED, 'restore', BK, want_rc=0, want_text="WD's image again")
h = state('after restore'); results.append(('restore leaves mtd3 = the Nov 16 dump, byte for byte', h == DUMP_MD5))

# D. failure paths of write
reseed()
run('one corrupt write -> WD image restored by itself', ARMED, 'write', BK, sim_mode='flip1', want_rc=1, want_text='Nothing changed')
h = state('after flip1'); results.append(('flip1 leaves mtd3 = the dump', h == DUMP_MD5))
reseed()
run('every write corrupt -> rc 2, DO NOT REBOOT', ARMED, 'write', BK, sim_mode='flipall', want_rc=2, want_text='BOTH writes failed')
state('after flipall')
reseed()
run('nandwrite rc 1 every time -> rc 2', ARMED, 'write', BK, sim_mode='failrc', want_rc=2, want_text='BOTH writes failed')
state('after failrc')
reseed()
run('flash_eraseall rc 1 every time -> rc 2', ARMED, 'write', BK, sim_mode='eraserc', want_rc=2, want_text='BOTH writes failed')
reseed()
run('restore after a failed run, plain', ARMED, 'restore', BK, want_rc=0)
calls = open(os.path.join(SIM, 'tool-calls.log')).read()
results.append(('no fake tool was ever handed a /dev path', '/dev/' not in calls))
out('tool calls (all): ' + str(len(calls.splitlines())) + ' lines; any /dev path: ' + str('/dev/' in calls))
out('')
out(f"SUMMARY: {sum(ok for _, ok in results)}/{len(results)} PASS")
for l, ok in results:
    if not ok: out(f"  FAIL: {l}")
sys.exit(0 if all(ok for _, ok in results) else 1)
