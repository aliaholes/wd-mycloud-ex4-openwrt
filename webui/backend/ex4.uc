// SPDX-License-Identifier: GPL-2.0-or-later
// ex4.uc : the web interface's whole backend. An rpcd ucode plugin (installed as /usr/share/rpcd/ucode/ex4.uc): it runs
// INSIDE rpcd, so a call costs no fork and no exec. The ubus object is `ex4`; who may call what is in acl/*.json.
//
// THE RULES OF THIS FILE (webui/README.md has the argument for each):
//   1. The read path never opens a disk, never runs a command, never walks a directory tree. It reads /proc, /sys and
//      a few small files other programs leave in RAM (ex4fan's status line, the watcher's caches).
//   2. A write method only ever writes /etc/config (through uci) and files under /etc/ex4 and /tmp/ex4, then asks the
//      helper (/usr/libexec/ex4/ex4-apply) to regenerate the service configs. The helper is started as an argv
//      array, never through a shell; a secret reaches it in a 0600 file under a 0700 folder in RAM, never in argv.
//   3. No method can write the array, a partition table, a superblock or the flash: no such method exists.
//      The single write under the data volume is mkdir of a new share's folder, and it is refused unless the volume
//      is mounted read-write AND the read-write token /tmp/ex4-rw-ok is valid (v8: its CONTENT is checked, see
//      rw_token_ok(); the owner writes it by hand; nothing in this repo makes it).
//   4. A name or number from the browser is checked against a pattern before it is used; a path NEVER comes from
//      the browser: a share's folder is always <volume>/<its name>.
//   5. rpcd is one thread: nothing here may make it wait. Anything slow is a job; calls into rpcd itself are deferred.
//
// EX4_ROOT (environment, tests only): a folder to use as "/" for every file this plugin touches, so the off-box tests
// can run the real rpcd on a fixture tree (tests/webui/emu/). Unset on the box.
'use strict';

import { readfile, lsdir, stat, lstat, access, mkdir, unlink, open, chmod, readlink, chown } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import { process } from 'uloop';

const ROOT = getenv('EX4_ROOT') ?? '';
const RUN = '/tmp/ex4';
const HELPER = '/usr/libexec/ex4/ex4-apply';
const UI_VERSION = '8.0';
const CACHE_MS = 1000;          // two tabs, or the LCD's daemon, inside one second share one snapshot
const SLOW_MS = 30000;          // per-disk verdicts and the address are re-read at most this often
const HOT_C = 55;               // a drive at or above this is "running hot" (WD Red: 0-65 C operating)
const MAX_SHARES = 32, MAX_USERS = 64, MAX_GROUPS = 32, MAX_EXPORTS = 32;

const RX_SHARE = /^[A-Za-z0-9][A-Za-z0-9 _.-]{0,30}[A-Za-z0-9_.-]$|^[A-Za-z0-9]$/;
const RX_USER = /^[a-z][a-z0-9_-]{0,30}$/;
const RX_HOST = /^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$/;
const RX_HASH = /^\$5\$(rounds=[0-9]{4,7}\$)?[.\/A-Za-z0-9]{1,16}\$[.\/A-Za-z0-9]{43}$/;
const RX_IP4 = /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/;
const RX_CLIENT = /^(\*|[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(\/[0-9]{1,2})?)$/;
const RX_MAIL = /^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}$/;
const RX_DNSNAME = /^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$/;
const RESERVED_SHARES = [ 'global', 'homes', 'printers', 'ipc$', 'print$', 'lost+found' ];
const SERVICES = {            // the allow-list: id -> the init scripts it switches (the first one present is its state)
	smb:  [ 'samba4', 'ksmbd' ],
	nfs:  [ 'nfsd' ],
	find: [ 'wsdd2', 'avahi-daemon' ],
	ssh:  [ 'dropbear' ],
	time: [ 'sysntpd' ]
};
const STANDBY = [ '0', '3', '6' ];   // the three screen-sleep codes captured byte-exact so far: 10 s, 5 min, never

function P(p) { return ROOT + p; }
function now_ms() { const t = clock(true); return t[0] * 1000 + int(t[1] / 1000000); }
function words(s) { return filter(split(trim(s ?? ''), /[ \t\n]+/), length); }
function rd(p, n) { return n ? readfile(P(p), n) : readfile(P(p)); }
function rdt(p) { return trim(rd(p) ?? ''); }
function isstr(v, max) { return type(v) == 'string' && length(v) <= (max ?? 256); }
function has(a, v) { return index(a, v) >= 0; }
function printable(s) {                               // plain ASCII, no control characters (a POSIX pattern cannot say this)
	for (let i = 0; i < length(s); i++) { const o = ord(s, i); if (o < 32 || o > 126) return false; }
	return true;
}
function has_ctl(s) { for (let i = 0; i < length(s); i++) { const o = ord(s, i); if (o < 32 || o == 127) return true; } return false; }
function uc() { return ROOT ? cursor(P('/etc/config'), P('/tmp/ex4-uci-save')) : cursor(); }
function fail(err, msg) { return { ok: false, err, msg }; }
function sections_of(c, conf, t) { const a = []; c.foreach(conf, t, (s) => { push(a, s); }); return a; }
let bus = null;
function bus_get() { bus ??= connect(getenv('EX4_UBUS_SOCK')); return bus; }       // unset on the box = the default socket
function kv(s) {                                      // "a=1 b=two" -> { a: "1", b: "two" }
	const o = {};
	for (let w in words(s)) { const m = match(w, /^([A-Za-z_0-9]+)=(.*)$/); if (m) o[m[1]] = m[2]; }
	return o;
}
function put(path, data, mode) {                      // a small file, default mode 0644
	const f = open(P(path), 'w', mode ?? 420);
	if (!f) return false;
	f.write(data); f.close(); chmod(P(path), mode ?? 420);
	return true;
}

mkdir(P(RUN), 448); chmod(P(RUN), 448);               // 0700: job spool, claim code, caches

// ---------------------------------------------------------------- events (the "Lately" list; the watcher appends too)
function ev(k, a) {
	const f = open(P(RUN + '/events'), 'a');
	if (f) { f.write(sprintf('%J\n', { t: time(), k, a: a ?? {} })); f.close(); }
}

// ---------------------------------------------------------------- revision counters: the page re-fetches a slow part
// only when its counter moved
const rev = { disks: 1, shares: 1, users: 1, services: 1, alerts: 1, system: 1, panel: 1, events: 0 };
let cache = null, cache_at = 0, prev = null, seq = 0;
function bump(...names) { for (let n in names) rev[n]++; cache = null; }

// ---------------------------------------------------------------- jobs: one helper process at a time, never a shell
const jobs = [], queue = [];
let job_seq = 0, running = false;
function pump() {
	if (running || !length(queue)) return;
	const q = shift(queue), id = q.j.id;
	running = true; q.j.state = 'run';
	process(P(HELPER), q.argv, { EX4_ROOT: ROOT, EX4_JOB: `${id}`, PATH: '/usr/sbin:/usr/bin:/sbin:/bin' }, function(rc) {
		q.j.state = (rc == 0) ? 'ok' : 'fail';
		q.j.msg = substr(trim(rd(`${RUN}/job-${id}.out`) ?? ''), 0, 300);
		unlink(P(`${RUN}/job-${id}.in`)); unlink(P(`${RUN}/job-${id}.out`));
		running = false;
		bump('disks', 'shares', 'users', 'services', 'alerts', 'system', 'panel');
		pump();
	});
}
function job(what, argv, secret) {
	const j = { id: ++job_seq, what, state: 'wait', t: time() };
	push(jobs, j);
	while (length(jobs) > 12 && jobs[0].state != 'run' && jobs[0].state != 'wait') shift(jobs);
	if (secret != null) put(`${RUN}/job-${j.id}.in`, secret, 384);
	push(queue, { j, argv });
	pump();
	cache = null;
	return j.id;
}

// ---------------------------------------------------------------- the read path
function cpu() {                                     // jiffies: user nice system idle iowait irq softirq
	const w = words(split(rd('/proc/stat') ?? '', '\n')[0]);
	let total = 0;
	for (let i = 1; i < length(w); i++) total += +w[i];
	return { total, idle: (+w[4]) + (+w[5]) };
}
function mem() {
	const o = {};
	for (let l in split(rd('/proc/meminfo') ?? '', '\n')) {
		const m = match(l, /^(MemTotal|MemAvailable):[ \t]+([0-9]+)/);
		if (m) o[m[1]] = +m[2];
	}
	return { total_kb: o.MemTotal ?? 0, avail_kb: o.MemAvailable ?? 0 };
}
function net() {                                     // the two real ports only: a bond or bridge above them would count twice
	let rx = 0, tx = 0;
	for (let l in split(rd('/proc/net/dev') ?? '', '\n')) {
		const m = match(l, /^[ \t]*(eth[0-9]+):[ \t]*(.*)$/);
		if (!m) continue;
		const w = words(m[2]);
		rx += +w[0]; tx += +w[8];
	}
	return { rx, tx };
}
function ports() {
	const a = [];
	for (let d in [ 'eth0', 'eth1' ]) {
		if (!access(P(`/sys/class/net/${d}`))) continue;
		const up = rdt(`/sys/class/net/${d}/carrier`) == '1', sp = rdt(`/sys/class/net/${d}/speed`);
		push(a, { dev: d, up, speed: (up && match(sp, /^[0-9]+$/)) ? +sp : null });
	}
	return a;
}
function blockdevs(rx) { return sort(filter(lsdir(P('/sys/block')) ?? [], (d) => !!match(d, rx))); }
function io() {                                      // /sys/block/<dev>/stat: field 3 = sectors read, 7 = sectors written
	let rdb = 0, wr = 0, devs = blockdevs(/^md[0-9]+$/);
	if (!length(devs)) devs = blockdevs(/^sd[a-z]$/);
	for (let d in devs) {
		const w = words(rd(`/sys/block/${d}/stat`));
		if (length(w) > 6) { rdb += (+w[2]) * 512; wr += (+w[6]) * 512; }
	}
	return { rd: rdb, wr };
}
function mounts(path) {                              // is the data volume mounted, and how
	for (let l in split(rd('/proc/mounts') ?? '', '\n')) {
		const w = split(l, ' ');
		if (length(w) > 3 && w[1] == path) return { mounted: true, rw: has(split(w[3], ','), 'rw'), dev: w[0] };
	}
	return { mounted: false, rw: false, dev: null };
}
function md_main() {                                 // the data array: the largest md device (md1 here), sysfs only
	let best = null, size = -1;
	for (let d in blockdevs(/^md[0-9]+$/)) {
		const s = +rdt(`/sys/block/${d}/size`);
		if (s > size) { size = s; best = d; }
	}
	return best;
}
function array_brief() {
	const d = md_main();
	if (!d) return null;
	const g = (f) => rdt(`/sys/block/${d}/md/${f}`);
	const done = match(g('sync_completed'), /^([0-9]+) \/ ([0-9]+)/);
	const sp = g('sync_speed');
	return {
		dev: d, level: g('level'), state: g('array_state'), degraded: +g('degraded'), disks: +g('raid_disks'),
		action: g('sync_action') || 'idle',
		pct: (done && +done[2] > 0) ? int(1000.0 * (+done[1]) / (+done[2])) / 10.0 : null,
		speed_kb: match(sp, /^[0-9]+$/) ? +sp : null,
		size_kb: int((+rdt(`/sys/block/${d}/size`)) / 2), ro: rdt(`/sys/block/${d}/ro`) == '1'
	};
}

// the panel daemon (ex4fan) is the one program that talks to the front micro and reads the drives. It leaves
// /tmp/ex4fan.json (docs/PANEL.md: fan, temps, per drive temperature + power state + nine SMART counters, space, what
// the screen was given) and, in every version, the one-line /tmp/ex4fan.status. Both are understood; the JSON wins.
function panel_json() {
	const s = rd('/tmp/ex4fan.json');
	if (!s) return null;
	try { const j = json(s); return type(j) == 'object' ? j : null; } catch (e) { return null; }
}
function climate() {
	const j = panel_json(), o = kv(rd('/tmp/ex4fan.status') ?? ''), c = { fan: null, rpm: null, board: null, disks: {}, micro: null };
	if (j) {
		c.fan = (type(j.fan?.name) == 'string' && j.fan.name != '?') ? lc(j.fan.name) : null;
		c.rpm = (type(j.fan?.rpm) == 'int' && j.fan.rpm >= 0) ? j.fan.rpm : null;
		c.board = (type(j.temps?.main) == 'int' && j.temps.main >= 0) ? j.temps.main : null;
		c.micro = j.micro ? (j.micro.answers ? 'answers' : 'silent') : null;
		for (let d in (j.drives ?? [])) if (type(d.dev) == 'string' && match(d.dev, /^sd[a-z]$/) && type(d.temp) == 'int' && d.temp >= 0) c.disks[d.dev] = d.temp;
	}
	else if (length(o)) {
		const lv = match(o.level ?? '', /\(([A-Z]+)\)/);
		c.fan = lv ? lc(lv[1]) : null;
		c.rpm = match(o.rpm ?? '', /^[0-9]+$/) ? +o.rpm : null;
		c.board = match(o.main ?? '', /^[0-9]+$/) ? +o.main : null;
		c.micro = o.micro ?? null;
		for (let p in split(o.drives ?? '', ',')) { const m = match(p, /^(sd[a-z]):([0-9]+)$/); if (m) c.disks[m[1]] = +m[2]; }
	}
	else return null;
	let hot = null;
	for (let k, v in c.disks) if (hot == null || v > hot) hot = v;
	c.hot = hot;
	return c;
}
function space() {                                   // one statvfs somebody else did. The watcher's df says "used" exactly
	const w = words(rd(RUN + '/space'));              // (the panel daemon's figure is what an unprivileged user could still take)
	if (length(w) >= 3) return { total_kb: +w[0], used_kb: +w[1], free_kb: +w[2] };
	const sp = panel_json()?.space;
	if (sp?.mounted && sp.total > 0) { const t = int(sp.total / 1024); return { total_kb: t, used_kb: int(1.0 * t * (sp.used_pct ?? 0) / 100), free_kb: int(sp.avail / 1024) }; }
	return { total_kb: null, used_kb: null, free_kb: null };
}

// ---- settings read once and kept until a write bumps `system`
let cfg = null, cfg_rev = -1;
function cache_cfg() {
	if (cfg && cfg_rev == rev.system) return cfg;
	const c = uc(), m = c.get_all('ex4', 'main') ?? {};
	cfg = { volume: m.volume ?? '/mnt/md1', claimed: m.claimed == '1', admin: m.admin ?? null,
	        trial_min: null, name: rdt('/proc/sys/kernel/hostname') };
	const t = kv(rd('/etc/ex4/trial') ?? ''), l = c.get_all('network', 'lan') ?? {}, b0 = c.get_all('network', 'bond0');
	if (t.return_min && match(t.return_min, /^[0-9]+$/)) cfg.trial_min = +t.return_min;
	cfg.lan = { mode: l.proto == 'static' ? 'static' : 'dhcp', bond: (b0 && b0.proto == 'bonding') ? (b0.bonding_policy ?? 'active-backup') : 'none' };
	const rel = match(rd('/etc/openwrt_release') ?? '', /DISTRIB_RELEASE='([^']*)'/);
	cfg.ver = { openwrt: rel ? rel[1] : null, kernel: rdt('/proc/sys/kernel/osrelease') };
	cfg_rev = rev.system;
	return cfg;
}

// ---- the disks: sysfs for what is plugged in, the watcher's cache for what SMART said (it asks every 30 minutes
// and never wakes a sleeping drive). Kept SLOW_MS.
let dk = null, dk_at = 0, dk_rev = -1;
function smart_of(dev, pj) {
	let s = null;
	const t = rd(`${RUN}/smart/${dev}.json`);
	if (t) try { s = json(t); } catch (e) { s = null; }
	if (!s) for (let d in (pj?.drives ?? [])) if (d.dev == dev && type(d.smart) == 'object') s = { a: d.smart, power: d.power, t: pj.wall ?? null };
	return type(s) == 'object' ? s : null;
}
function disks_now() {
	const t = now_ms();
	if (dk && dk_rev == rev.disks && t - dk_at < SLOW_MS) return dk;
	const out = [], md = md_main(), pj = panel_json(), cl = climate();
	for (let d in blockdevs(/^sd[a-z]$/)) {
		const link = readlink(P(`/sys/block/${d}`)) ?? '';
		if (index(link, '/usb') >= 0) continue;                     // a USB disk is not a bay
		const port = match(link, /\/ata([0-9]+)\//), s = smart_of(d, pj), a = s?.a ?? {};
		let member = null, slot = null;
		if (md) for (let p in lsdir(P(`/sys/block/${md}/md`)) ?? []) {
			if (index(p, `dev-${d}`) != 0) continue;
			member = rdt(`/sys/block/${md}/md/${p}/state`); slot = rdt(`/sys/block/${md}/md/${p}/slot`);
		}
		const n = (k) => (type(a[k]) == 'int') ? a[k] : null;
		const o = {
			bay: port ? +port[1] : length(out) + 1, dev: d, model: rdt(`/sys/block/${d}/device/model`), serial: s?.serial ?? null,
			size_b: (+rdt(`/sys/block/${d}/size`)) * 512, temp: cl?.disks?.[d] ?? n('194'), member, slot,
			power: s?.power ?? null, smart_t: s?.t ?? null, passed: s?.passed ?? null,
			hours: n('9'), starts: n('12'), realloc: n('5'), pending: n('197'), uncorrect: n('198'), crc: n('199'), load: n('193')
		};
		o.v = (member && index(member, 'faulty') >= 0) || o.passed === false ? 'fail'
			: ((o.realloc ?? 0) > 0 || (o.pending ?? 0) > 0 || (o.uncorrect ?? 0) > 0) ? 'watch'
			: (o.passed === true || o.hours != null) ? 'ok' : 'none';
		push(out, o);
	}
	dk = sort(out, (x, y) => x.bay - y.bay); dk_at = t; dk_rev = rev.disks;
	return dk;
}

// ---- the one sentence. `level` is the worst of the reasons; the page words them (it is the page's h1 and its title)
const LEVELS = [ 'ok', 'closed', 'watch', 'hot', 'rebuild', 'failed', 'down' ];
function health(arr, vol, cl, dl) {
	const why = [];
	if (!arr) push(why, { c: 'closed' });
	else {
		// how many members the level can lose and still hold the data
		const tol = arr.level == 'raid6' ? 2 : arr.level == 'raid1' ? arr.disks - 1 : has([ 'raid5', 'raid4', 'raid10' ], arr.level) ? 1 : 0;
		if (has([ 'inactive', 'clear', 'suspended' ], arr.state) || arr.degraded > tol)
			push(why, { c: 'array_down', state: arr.state });
		else if (arr.degraded > 0) {
			let bay = null;                                       // the member that is not in step
			for (let d in dl) if (d.member == null || index(d.member, 'in_sync') < 0) bay = d.bay;
			if (arr.action == 'recover') push(why, { c: 'rebuild', bay, pct: arr.pct, action: arr.action, speed_kb: arr.speed_kb });
			else push(why, { c: 'disk_failed', bay });
		}
		else if (has([ 'recover', 'resync', 'reshape' ], arr.action)) push(why, { c: 'rebuild', bay: null, pct: arr.pct, action: arr.action, speed_kb: arr.speed_kb });
		if (arr.action == 'check' || arr.action == 'repair') push(why, { c: 'check', pct: arr.pct });
	}
	if (cl) {
		if (cl.hot != null && cl.hot >= HOT_C) push(why, { c: 'hot', temp: cl.hot });
		if (cl.rpm === 0 && cl.fan && cl.fan != 'off') push(why, { c: 'fan_stopped' });
		if (cl.micro == 'silent') push(why, { c: 'micro_silent' });
	}
	for (let d in dl) {
		if (d.v == 'fail' && !(arr && arr.degraded > 0)) push(why, { c: 'disk_failed', bay: d.bay });
		else if (d.v == 'watch') push(why, { c: 'disk_watch', bay: d.bay, pending: d.pending ?? 0, realloc: d.realloc ?? 0, uncorrect: d.uncorrect ?? 0 });
	}
	if (vol.mounted && vol.total_kb && vol.free_kb != null && vol.free_kb * 100.0 / vol.total_kb < 3) push(why, { c: 'full', free_kb: vol.free_kb });
	const rank = { closed: 1, check: 0, disk_watch: 2, full: 2, micro_silent: 2, hot: 3, fan_stopped: 3, rebuild: 4, disk_failed: 5, array_down: 6 };
	let lv = 0;
	for (let w in why) if ((rank[w.c] ?? 0) > lv) lv = rank[w.c];
	return { level: LEVELS[lv], why };
}

function trial_now(up) {
	const c = cache_cfg();
	if (c.trial_min == null) return null;
	const stay = !!access(P('/tmp/ex4-stay'));
	return { stay, left_s: stay ? null : max(0, c.trial_min * 60 - int(up)) };
}
// what the box answers on now: netifd knows (one ubus call, no fork); else what the panel daemon was told; kept SLOW_MS
let addr_v = null, addr_at = 0;
function addr_now() {
	const t = now_ms();
	if (addr_at && t - addr_at < SLOW_MS) return addr_v;
	addr_v = null; addr_at = t;
	try {
		const d = bus_get().call('network.interface', 'dump', {});
		for (let i in (d?.interface ?? [])) if (!addr_v && i.up && i.interface != 'loopback' && length(i['ipv4-address'])) addr_v = i['ipv4-address'][0].address;
	} catch (e) { }
	if (!addr_v) { const ip = panel_json()?.panel?.ip1; if (type(ip) == 'string' && match(ip, /^[0-9.]+$/)) addr_v = ip; }
	return addr_v;
}
let was_pending = false;
function net_pending() {
	const w = words(rd(RUN + '/net.pending'));           // "<epoch when the old settings come back>"
	if (!length(w) || access(P(RUN + '/net.confirmed'))) return null;
	const left = (+w[0]) - time();
	return left > 0 ? left : null;
}
function net_pending_seen() {                        // when a trial of new settings ends, either way, re-read what is set
	const p = net_pending();
	if (was_pending && p == null) { rev.system++; cfg = null; addr_at = 0; }
	was_pending = p != null;
	return p;
}

function snapshot() {
	const t = now_ms();
	if (cache && t - cache_at < CACHE_MS) return cache;
	const cur = { t, cpu: cpu(), net: net(), io: io() };
	const r = { cpu: null, net: { rx: 0, tx: 0 }, io: { rd: 0, wr: 0 } };
	if (prev && t > prev.t) {
		// 1.0 *: ucode divides two integers as integers
		const dt = (t - prev.t) / 1000.0, dtot = cur.cpu.total - prev.cpu.total;
		if (dtot > 0) r.cpu = int(1000 * (1 - 1.0 * (cur.cpu.idle - prev.cpu.idle) / dtot)) / 1000.0;
		r.net = { rx: int(max(0, cur.net.rx - prev.net.rx) / dt), tx: int(max(0, cur.net.tx - prev.net.tx) / dt) };
		r.io = { rd: int(max(0, cur.io.rd - prev.io.rd) / dt), wr: int(max(0, cur.io.wr - prev.io.wr) / dt) };
	}
	prev = cur;
	const np = net_pending_seen(), c = cache_cfg(), up = +(words(rd('/proc/uptime'))[0] ?? 0), arr = array_brief(), cl = climate(), dl = disks_now();
	const vol = { path: c.volume, ...mounts(c.volume), ...space() };
	const es = stat(P(RUN + '/events'));
	rev.events = es ? es.size : 0;
	cache = {
		seq: ++seq, now: time(), up: int(up), name: c.name, cpu: r.cpu, load: words(rd('/proc/loadavg'))[0] ?? null,
		mem: mem(), net: r.net, io: r.io, ports: ports(), array: arr, vol, clim: cl,
		health: health(arr, vol, cl, dl),
		disks: map(dl, (d) => ({ bay: d.bay, dev: d.dev, temp: d.temp, v: d.v })),
		trial: trial_now(up), net_pending: np, addr: addr_now(), lan: c.lan,
		jobs: map(jobs, (j) => ({ id: j.id, what: j.what, state: j.state, msg: j.msg ?? null })),
		rev: { ...rev }
	};
	cache_at = t;
	return cache;
}

function m_events(req) {
	const since = int(req.args?.since ?? 0), out = [];
	for (let l in split(rd(RUN + '/events') ?? '', '\n')) {
		if (!length(l)) continue;
		try { const e = json(l); if (type(e) == 'object' && e.t >= since) push(out, e); } catch (e) { }
	}
	return { events: slice(out, -200) };
}

function m_disks(req) { return { disks: disks_now(), hot_c: HOT_C }; }

function m_array(req) {
	const d = md_main(), c = cache_cfg();
	const vol = { path: c.volume, ...mounts(c.volume), ...space() };
	if (!d) return { array: null, vol, auto_check: false };
	const a = array_brief(), g = (f) => rdt(`/sys/block/${d}/md/${f}`), members = [], dl = disks_now();
	for (let p in sort(lsdir(P(`/sys/block/${d}/md`)) ?? [])) {
		const m = match(p, /^dev-(sd[a-z])([0-9]*)$/);
		if (!m) continue;
		let bay = null;
		for (let x in dl) if (x.dev == m[1]) bay = x.bay;
		push(members, { dev: m[1], part: m[1] + m[2], bay, slot: rdt(`/sys/block/${d}/md/${p}/slot`), state: rdt(`/sys/block/${d}/md/${p}/state`) });
	}
	a.members = sort(members, (x, y) => (x.bay ?? 9) - (y.bay ?? 9));
	a.chunk_kb = int((+g('chunk_size')) / 1024); a.mismatch = match(g('mismatch_cnt'), /^[0-9]+$/) ? +g('mismatch_cnt') : null;
	a.bitmap = (g('bitmap/location') || 'none') != 'none'; a.meta = g('metadata_version');
	// no scrub is ever started by this system on its own (one drive of the test unit has a bad sector)
	return { array: a, vol, auto_check: false };
}

// ---------------------------------------------------------------- shares, users, groups, NFS exports (uci: ex4)
function sections(c, t) { const a = []; c.foreach('ex4', t, (s) => { push(a, s); }); return a; }
function aslist(v) { return type(v) == 'array' ? v : (v == null || v === '') ? [] : [ `${v}` ]; }
function find_by(c, t, name) { for (let s in sections(c, t)) if (s.name == name) return s; return null; }
function lower_eq(a, b) { return lc(a) == lc(b); }

// THE READ-WRITE TOKEN (v8; the web review's nit 4: existence alone opened the gate). /tmp/ex4-rw-ok opens the one
// write this interface can make under the data volume only if it is a regular file (not a link), mode 0600, owned by
// root (on the box; the off-box fixture tree belongs to the test user), and its one line is
//     rw-ok <this boot's /proc/sys/kernel/random/boot_id>
// so a token left from another boot, an empty file, a link or a file anyone could write opens nothing. Nothing in
// this repo writes it: the owner does, by hand, in the session he means it (SAFETY.md, "Writing to the array").
function rw_token_ok() {
	const st = lstat(P('/tmp/ex4-rw-ok')), boot = rdt('/proc/sys/kernel/random/boot_id');
	if (!st || st.type != 'file' || st.size > 128 || !match(boot, /^[0-9a-f-]{36}$/)) return false;
	if (st.perm?.group_read || st.perm?.group_write || st.perm?.other_read || st.perm?.other_write) return false;
	if (!ROOT && st.uid != 0) return false;
	return rd('/tmp/ex4-rw-ok') == `rw-ok ${boot}\n`;
}

function m_shares(req) {
	const c = uc(), cf = cache_cfg(), vol = { path: cf.volume, ...mounts(cf.volume) }, shares = [], used = {}, exports = [];
	vol.gate = rw_token_ok();
	for (let s in sections(c, 'share')) {
		used[lc(s.name)] = true;
		push(shares, { name: s.name, exists: vol.mounted && stat(P(`${cf.volume}/${s.name}`))?.type == 'directory',
			guest: s.guest ?? 'no', rw: aslist(s.rw), ro: aslist(s.ro), tm: s.tm == '1' });
	}
	for (let e in sections(c, 'export')) push(exports, { id: e['.name'], share: e.share, clients: e.clients, access: e.access ?? 'ro', squash: e.squash ?? 'root' });
	// folders already on the volume that no share offers yet (one directory read, only when this page asks)
	const folders = [];
	if (vol.mounted) for (let n in sort(lsdir(P(cf.volume)) ?? [])) {
		if (used[lc(n)] || !match(n, RX_SHARE) || has(RESERVED_SHARES, lc(n))) continue;
		if (stat(P(`${cf.volume}/${n}`))?.type == 'directory') push(folders, n);
		if (length(folders) >= 40) break;
	}
	let engine = null;
	for (let n in SERVICES.smb) if (!engine && access(P(`/etc/init.d/${n}`))) engine = n;
	return { volume: vol, engine, nfs: !!access(P('/etc/init.d/nfsd')), shares, exports, folders };
}

function who_ok(c, list) {                           // every entry is a known user, or @ + a known group
	const users = map(sections(c, 'user'), (u) => u.name), groups = map(sections(c, 'group'), (g) => g.name), out = [];
	if (type(list) != 'array' || length(list) > MAX_USERS + MAX_GROUPS) return null;
	for (let w in list) {
		if (!isstr(w, 40)) return null;
		if (substr(w, 0, 1) == '@' ? !has(groups, substr(w, 1)) : !has(users, w)) return null;
		if (!has(out, w)) push(out, w);
	}
	return out;
}
function share_fields(c, a, into) {                  // the fields share_add and share_set have in common
	if (a.guest != null) { if (!has([ 'no', 'ro', 'rw' ], a.guest)) return fail('bad_guest', 'Everyone can be: no, ro or rw.'); into.guest = a.guest; }
	for (let k in [ 'rw', 'ro' ]) if (a[k] != null) {
		const l = who_ok(c, a[k]);
		if (!l) return fail('bad_who', 'A person or group on that list does not exist.');
		into[k] = l;
	}
	if (a.tm != null) into.tm = a.tm ? '1' : '0';
	return null;
}
function share_write(c, sid, f) {
	for (let k in [ 'guest', 'tm' ]) if (f[k] != null) c.set('ex4', sid, k, f[k]);
	for (let k in [ 'rw', 'ro' ]) if (f[k] != null) { if (length(f[k])) c.set('ex4', sid, k, f[k]); else c.delete('ex4', sid, k); }
}

function m_share_add(req) {
	const a = req.args ?? {}, c = uc(), cf = cache_cfg(), name = a.name;
	if (!isstr(name, 32) || !match(name, RX_SHARE) || has(RESERVED_SHARES, lc(name)) || match(name, /\.\./))
		return fail('bad_name', 'A share name is 1 to 32 letters, digits, spaces, dots, dashes or underscores, and starts with a letter or digit.');
	const all = sections(c, 'share');
	if (length(all) >= MAX_SHARES) return fail('too_many', `This box offers at most ${MAX_SHARES} shares.`);
	for (let s in all) if (lower_eq(s.name, name)) return fail('exists', 'A share with that name already exists.');
	const f = { guest: 'no', tm: '0' }, bad = share_fields(c, a, f);
	if (bad) return bad;
	// the folder is ALWAYS <volume>/<name>. If it is not there yet it has to be made: the one write this interface
	// can make under the data volume, and only behind both gates.
	const vol = mounts(cf.volume), dir = P(`${cf.volume}/${name}`), st = vol.mounted ? stat(dir) : null;
	let made = false;
	if (!vol.mounted) return fail('no_volume', 'The data volume is not open, so there is no folder to share yet.');
	if (st && st.type != 'directory') return fail('not_folder', 'Something with that name is on the volume and it is not a folder.');
	if (!st) {
		if (!vol.rw) return fail('read_only', 'The volume is open read-only. Folders that already exist can be shared; a new one cannot be made.');
		if (!rw_token_ok()) return fail('rw_gate', 'Making a new folder writes to the array. That needs the owner\'s read-write token for this boot on the box (see SAFETY.md).');
		if (!mkdir(dir, 509)) return fail('mkdir', 'The folder could not be made.');
		chown(dir, 0, 100); made = true;
	}
	const sid = c.add('ex4', 'share');
	c.set('ex4', sid, 'name', name); share_write(c, sid, f); c.commit('ex4');
	ev('share_add', { name, made }); bump('shares');
	return { ok: true, made, job: job('shares', [ 'sync' ]) };
}
function m_share_set(req) {
	const a = req.args ?? {}, c = uc(), s = isstr(a.name, 32) ? find_by(c, 'share', a.name) : null;
	if (!s) return fail('no_share', 'No such share.');
	const f = {}, bad = share_fields(c, a, f);
	if (bad) return bad;
	share_write(c, s['.name'], f); c.commit('ex4');
	ev('share_set', { name: s.name }); bump('shares');
	return { ok: true, job: job('shares', [ 'sync' ]) };
}
function m_share_remove(req) {                       // stops offering it. The folder and every file in it stay.
	const a = req.args ?? {}, c = uc(), s = isstr(a.name, 32) ? find_by(c, 'share', a.name) : null;
	if (!s) return fail('no_share', 'No such share.');
	for (let e in sections(c, 'export')) if (e.share == s.name) c.delete('ex4', e['.name']);
	c.delete('ex4', s['.name']); c.commit('ex4');
	ev('share_remove', { name: s.name }); bump('shares');
	return { ok: true, job: job('shares', [ 'sync' ]) };
}

function export_fields(c, a, into) {
	if (a.clients != null) {
		if (!isstr(a.clients, 20) || !match(a.clients, RX_CLIENT)) return fail('bad_clients', 'Clients are one address, a range like 192.0.2.0/24, or * for anyone.');
		const m = match(a.clients, /^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)(\/([0-9]+))?$/);
		if (m && (+m[1] > 255 || +m[2] > 255 || +m[3] > 255 || +m[4] > 255 || (m[6] != null && +m[6] > 32))) return fail('bad_clients', 'That is not an address.');
		into.clients = a.clients;
	}
	if (a.access != null) { if (!has([ 'ro', 'rw' ], a.access)) return fail('bad_access', 'Access is ro or rw.'); into.access = a.access; }
	if (a.squash != null) { if (!has([ 'root', 'all', 'none' ], a.squash)) return fail('bad_squash', 'Squash is root, all or none.'); into.squash = a.squash; }
	return null;
}
// v8 (the web review's nit 5): an export open to ANY host (*), writable, with root NOT squashed hands every machine on
// the network root over the share's files. Refused as a combination; each part alone stays possible.
function export_unsafe(f) { return f.clients == '*' && f.access == 'rw' && f.squash == 'none'; }
const UNSAFE_EXPORT = 'Writable, open to every machine (*) and with root not squashed would give any device on the network root over these files. Name the machines, keep it read-only, or squash root.';
function m_export_add(req) {
	const a = req.args ?? {}, c = uc();
	if (!isstr(a.share, 32) || !find_by(c, 'share', a.share)) return fail('no_share', 'No such share.');
	if (length(sections(c, 'export')) >= MAX_EXPORTS) return fail('too_many', `At most ${MAX_EXPORTS} NFS exports.`);
	const f = { access: 'ro', squash: 'root' }, bad = export_fields(c, a, f);
	if (bad) return bad;
	if (!f.clients) return fail('bad_clients', 'Say who may mount it.');
	if (export_unsafe(f)) return fail('unsafe_export', UNSAFE_EXPORT);
	for (let e in sections(c, 'export')) if (e.share == a.share && e.clients == f.clients) return fail('exists', 'That share is already exported to those clients.');
	const id = c.add('ex4', 'export');
	c.set('ex4', id, 'share', a.share);
	for (let k, v in f) c.set('ex4', id, k, v);
	c.commit('ex4');
	ev('export_add', { share: a.share, clients: f.clients }); bump('shares');
	return { ok: true, id, job: job('shares', [ 'sync' ]) };
}
function export_by_id(c, id) { for (let e in sections(c, 'export')) if (e['.name'] == id) return e; return null; }
function m_export_set(req) {
	const a = req.args ?? {}, c = uc(), e = isstr(a.id, 40) ? export_by_id(c, a.id) : null;
	if (!e) return fail('no_export', 'No such export.');
	const f = {}, bad = export_fields(c, a, f);
	if (bad) return bad;
	if (export_unsafe({ clients: f.clients ?? e.clients, access: f.access ?? e.access ?? 'ro', squash: f.squash ?? e.squash ?? 'root' })) return fail('unsafe_export', UNSAFE_EXPORT);
	for (let k, v in f) c.set('ex4', e['.name'], k, v);
	c.commit('ex4'); bump('shares');
	return { ok: true, job: job('shares', [ 'sync' ]) };
}
function m_export_remove(req) {
	const a = req.args ?? {}, c = uc(), e = isstr(a.id, 40) ? export_by_id(c, a.id) : null;
	if (!e) return fail('no_export', 'No such export.');
	c.delete('ex4', e['.name']); c.commit('ex4');
	ev('export_remove', { share: e.share }); bump('shares');
	return { ok: true, job: job('shares', [ 'sync' ]) };
}

function system_names() {                            // names the base system owns: never ours to add or remove
	const a = [];
	for (let f in [ '/etc/passwd', '/etc/group' ]) for (let l in split(rd(f) ?? '', '\n')) {
		const w = split(l, ':');
		if (length(w) > 2 && (+w[2] < 1000 || +w[2] >= 60000)) push(a, w[0]);
	}
	return a;
}
function m_users(req) {
	const c = uc();
	return { admin: cache_cfg().admin,
		users: map(sections(c, 'user'), (u) => ({ name: u.name, uid: +u.uid })),
		groups: map(sections(c, 'group'), (g) => ({ name: g.name, gid: +g.gid, members: aslist(g.member) })) };
}
function pass_ok(p) { return isstr(p, 128) && length(p) >= 8 && !has_ctl(p); }
function next_id(c, t, key) { let n = 1000; for (let s in sections(c, t)) if (+s[key] >= n) n = (+s[key]) + 1; return n; }
function m_user_add(req) {
	const a = req.args ?? {}, c = uc();
	if (!isstr(a.name, 31) || !match(a.name, RX_USER)) return fail('bad_name', 'A user name is 1 to 31 lower-case letters, digits, dashes or underscores, and starts with a letter.');
	if (has(system_names(), a.name) || find_by(c, 'user', a.name) || find_by(c, 'group', a.name)) return fail('exists', 'That name is taken.');
	if (length(sections(c, 'user')) >= MAX_USERS) return fail('too_many', `At most ${MAX_USERS} people.`);
	if (!pass_ok(a.password)) return fail('bad_password', 'A password is 8 to 128 characters.');
	const sid = c.add('ex4', 'user');
	c.set('ex4', sid, 'name', a.name); c.set('ex4', sid, 'uid', `${next_id(c, 'user', 'uid')}`); c.commit('ex4');
	ev('user_add', { name: a.name }); bump('users');
	return { ok: true, job: job('users', [ 'user-pass', a.name ], a.password) };
}
function m_user_passwd(req) {
	const a = req.args ?? {}, c = uc();
	if (!isstr(a.name, 31) || !find_by(c, 'user', a.name)) return fail('no_user', 'No such person.');
	if (!pass_ok(a.password)) return fail('bad_password', 'A password is 8 to 128 characters.');
	ev('user_passwd', { name: a.name });
	return { ok: true, job: job('users', [ 'user-pass', a.name ], a.password) };
}
function drop_who(c, t, key, who) {                  // take a name out of every list that holds it
	for (let s in sections(c, t)) {
		const l = aslist(s[key]);
		if (!has(l, who)) continue;
		const n = filter(l, (x) => x != who);
		if (length(n)) c.set('ex4', s['.name'], key, n); else c.delete('ex4', s['.name'], key);
	}
}
function m_user_remove(req) {
	const a = req.args ?? {}, c = uc(), u = isstr(a.name, 31) ? find_by(c, 'user', a.name) : null;
	if (!u) return fail('no_user', 'No such person.');
	drop_who(c, 'share', 'rw', u.name); drop_who(c, 'share', 'ro', u.name); drop_who(c, 'group', 'member', u.name);
	c.delete('ex4', u['.name']); c.commit('ex4');
	ev('user_remove', { name: u.name }); bump('users', 'shares');
	return { ok: true, job: job('users', [ 'user-del', u.name ]) };
}
function members_ok(c, list) {
	const users = map(sections(c, 'user'), (u) => u.name), out = [];
	if (type(list) != 'array' || length(list) > MAX_USERS) return null;
	for (let w in list) { if (!isstr(w, 31) || !has(users, w)) return null; if (!has(out, w)) push(out, w); }
	return out;
}
function m_group_add(req) {
	const a = req.args ?? {}, c = uc();
	if (!isstr(a.name, 31) || !match(a.name, RX_USER)) return fail('bad_name', 'A group name is 1 to 31 lower-case letters, digits, dashes or underscores, and starts with a letter.');
	if (has(system_names(), a.name) || find_by(c, 'user', a.name) || find_by(c, 'group', a.name)) return fail('exists', 'That name is taken.');
	if (length(sections(c, 'group')) >= MAX_GROUPS) return fail('too_many', `At most ${MAX_GROUPS} groups.`);
	const m = members_ok(c, a.members ?? []);
	if (!m) return fail('bad_who', 'A person on that list does not exist.');
	const sid = c.add('ex4', 'group');
	c.set('ex4', sid, 'name', a.name); c.set('ex4', sid, 'gid', `${next_id(c, 'group', 'gid')}`);
	if (length(m)) c.set('ex4', sid, 'member', m);
	c.commit('ex4');
	ev('group_add', { name: a.name }); bump('users');
	return { ok: true, job: job('users', [ 'sync' ]) };
}
function m_group_set(req) {
	const a = req.args ?? {}, c = uc(), g = isstr(a.name, 31) ? find_by(c, 'group', a.name) : null;
	if (!g) return fail('no_group', 'No such group.');
	const m = members_ok(c, a.members);
	if (!m) return fail('bad_who', 'A person on that list does not exist.');
	if (length(m)) c.set('ex4', g['.name'], 'member', m); else c.delete('ex4', g['.name'], 'member');
	c.commit('ex4'); bump('users');
	return { ok: true, job: job('users', [ 'sync' ]) };
}
function m_group_remove(req) {
	const a = req.args ?? {}, c = uc(), g = isstr(a.name, 31) ? find_by(c, 'group', a.name) : null;
	if (!g) return fail('no_group', 'No such group.');
	drop_who(c, 'share', 'rw', '@' + g.name); drop_who(c, 'share', 'ro', '@' + g.name);
	c.delete('ex4', g['.name']); c.commit('ex4');
	ev('group_remove', { name: g.name }); bump('users', 'shares');
	return { ok: true, job: job('users', [ 'sync' ]) };
}

// ---------------------------------------------------------------- services (only the ids in SERVICES)
function m_services(req) {
	const out = [], rc = lsdir(P('/etc/rc.d')) ?? [];
	let procd = null;
	try { procd = bus_get().call('service', 'list', {}); } catch (e) { procd = null; }
	for (let id, names in SERVICES) {
		let name = null;
		for (let n in names) if (!name && access(P(`/etc/init.d/${n}`))) name = n;
		const o = { id, present: !!name, enabled: false, running: null, rss_kb: null };
		if (name) {
			for (let l in rc) if (match(l, /^S[0-9]+/) && substr(l, 3) == name) o.enabled = true;
			if (procd) {
				let rss = 0, run = false;
				for (let n in names) for (let k, inst in (procd[n]?.instances ?? {})) {
					if (!inst.running) continue;
					run = true;
					const m = match(readfile(`/proc/${inst.pid}/status`) ?? '', /VmRSS:[ \t]+([0-9]+)/);
					if (m) rss += +m[1];
				}
				o.running = run; o.rss_kb = run ? rss : null;
			}
		}
		push(out, o);
	}
	return { trial: cache_cfg().trial_min != null, list: out };
}
function m_service_set(req) {
	const a = req.args ?? {};
	if (!isstr(a.id, 8) || !exists(SERVICES, a.id) || type(a.enabled) != 'bool') return fail('bad_service', 'No such service.');
	// ssh is how a trial is watched and how the owner gets in when this page cannot be reached: never off in a trial
	if (a.id == 'ssh' && !a.enabled && cache_cfg().trial_min != null) return fail('trial_ssh', 'Secure shell stays on during a trial: it is how the trial is watched.');
	ev('service_set', { id: a.id, on: a.enabled }); bump('services');
	return { ok: true, job: job('services', [ 'service', a.id, a.enabled ? 'on' : 'off' ]) };
}

// ---------------------------------------------------------------- e-mail alerts
const ALERT_EVENTS = [ 'disk', 'raid', 'temp', 'space' ];
function m_alerts(req) {
	const c = uc(), a = c.get_all('ex4', 'alerts') ?? {}, last = kv(rd(RUN + '/alert.last') ?? '');
	return { enabled: a.enabled == '1', to: a.to ?? '', from: a.from ?? '', host: a.host ?? '', port: +(a.port ?? 587),
		tls: a.tls ?? 'starttls', user: a.user ?? '', has_pass: (stat(P('/etc/ex4/smtp-pass'))?.size ?? 0) > 0,
		events: aslist(a.events), space_pct: +(a.space_pct ?? 90), sender: !!access(P('/usr/bin/msmtp')),
		last: length(last) ? { t: +last.t, ok: last.ok == '1' } : null };
}
function m_alerts_set(req) {
	const a = req.args ?? {}, c = uc(), set = {};
	if (a.enabled != null) { if (type(a.enabled) != 'bool') return fail('bad', 'enabled is true or false.'); set.enabled = a.enabled ? '1' : '0'; }
	for (let k in [ 'to', 'from' ]) if (a[k] != null) { if (!isstr(a[k]) || !match(a[k], RX_MAIL)) return fail('bad_mail', 'That does not look like an e-mail address.'); set[k] = a[k]; }
	if (a.host != null) { if (!isstr(a.host, 253) || !match(a.host, RX_DNSNAME)) return fail('bad_host', 'The mail server is a name like smtp.example.org.'); set.host = a.host; }
	if (a.port != null) { if (type(a.port) != 'int' || a.port < 1 || a.port > 65535) return fail('bad_port', 'The port is a number from 1 to 65535.'); set.port = `${a.port}`; }
	if (a.tls != null) { if (!has([ 'starttls', 'tls', 'none' ], a.tls)) return fail('bad_tls', 'Encryption is starttls, tls or none.'); set.tls = a.tls; }
	if (a.user != null) { if (!isstr(a.user, 128) || !printable(a.user) || match(a.user, /["\\]/)) return fail('bad_user', 'The account name has a character a mail server would not take.'); set.user = a.user; }
	if (a.space_pct != null) { if (type(a.space_pct) != 'int' || a.space_pct < 50 || a.space_pct > 99) return fail('bad_pct', 'The space warning is 50 to 99 percent.'); set.space_pct = `${a.space_pct}`; }
	if (a.events != null) {
		if (type(a.events) != 'array') return fail('bad_events', 'events is a list.');
		for (let e in a.events) if (!has(ALERT_EVENTS, e)) return fail('bad_events', 'Unknown event.');
		set.events = uniq(a.events);
	}
	if (a.password != null && (!isstr(a.password, 256) || has_ctl(a.password))) return fail('bad_password', 'That password has a character that cannot be stored.');
	if (!c.get_all('ex4', 'alerts')) c.set('ex4', 'alerts', 'alerts');
	for (let k, v in set) { if (k == 'events' && !length(v)) c.delete('ex4', 'alerts', 'events'); else c.set('ex4', 'alerts', k, v); }
	const now = { ...(c.get_all('ex4', 'alerts') ?? {}) };
	if (now.enabled == '1' && (!now.to || !now.from || !now.host)) { c.revert('ex4'); return fail('incomplete', 'Alerts need a recipient, a sender address and a mail server before they can be switched on.'); }
	c.commit('ex4');
	if (a.password != null) { mkdir(P('/etc/ex4'), 448); put('/etc/ex4/smtp-pass', a.password, 384); }   // straight to a 0600 file: no argv, no fork
	ev('alerts_set', { on: now.enabled == '1' }); bump('alerts');
	return { ok: true, job: job('alerts', [ 'sync' ]) };
}
function m_alerts_test(req) {
	const c = uc(), a = c.get_all('ex4', 'alerts') ?? {};
	if (!a.to || !a.from || !a.host) return fail('incomplete', 'Fill in a recipient, a sender address and a mail server first.');
	return { ok: true, job: job('alert-test', [ 'alert-test' ]) };
}

// ---------------------------------------------------------------- system: name, clock, address, certificate, power
let zones = null;
function zone_table() {                              // "Area/City POSIX-TZ-string" per line
	if (zones) return zones;
	zones = {};
	for (let l in split(rd('/usr/share/ex4/zones') ?? '', '\n')) { const w = words(l); if (length(w) == 2) zones[w[0]] = w[1]; }
	return zones;
}
function ip_ok(s) {
	const m = isstr(s, 15) ? match(s, RX_IP4) : null;
	return !!m && +m[1] <= 255 && +m[2] <= 255 && +m[3] <= 255 && +m[4] <= 255;
}
function mask_ok(s) {
	if (!ip_ok(s)) return false;
	const m = match(s, RX_IP4);
	let v = ((+m[1]) << 24) | ((+m[2]) << 16) | ((+m[3]) << 8) | (+m[4]), seen0 = false;
	for (let i = 31; i >= 0; i--) { const b = (v >> i) & 1; if (b && seen0) return false; if (!b) seen0 = true; }
	return v != 0;
}
function net_cfg(c) {
	const l = c.get_all('network', 'lan') ?? {}, b = c.get_all('network', 'bond0');
	return { mode: l.proto == 'static' ? 'static' : 'dhcp', addr: l.ipaddr ?? '', mask: l.netmask ?? '', gw: l.gateway ?? '',
		dns: aslist(l.dns), bond: (b && b.proto == 'bonding') ? (b.bonding_policy ?? 'active-backup') : 'none', device: l.device ?? null };
}
// what update/box/ex4-update last found (/tmp/ex4-update/state: one KEY=VALUE per line, words only) and what this
// system says it is (/etc/ex4-release). Two small reads, no process; the page never starts a check on its own.
function update_now() {
	const id = {}, st = {};
	for (let l in split(rd('/etc/ex4-release') ?? '', '\n')) { const m = match(l, /^([a-z_]+)=([A-Za-z0-9.,+_-]{0,64})$/); if (m) id[m[1]] = m[2]; }
	for (let l in split(rd('/tmp/ex4-update/state') ?? '', '\n')) { const m = match(l, /^([a-z_]+)=([A-Za-z0-9.,:\/+_-]{0,120})$/); if (m) st[m[1]] = m[2]; }
	const keys_held = length(filter(lsdir(P('/etc/ex4-update/keys')) ?? [], (f) => match(f, /^[0-9a-f]{16}$/)));
	return { running: id.version ?? null, serial: id.serial ?? null, channel: id.channel ?? null, keys: keys_held,
		checked: st.checked ? +st.checked : null, result: st.result ?? null, sig: st.sig ?? null, key: st.key ?? null,
		latest: st.latest ?? null, latest_serial: st.latest_serial ?? null, staged: st.staged ?? null, why: st.why ?? null, from: st.url ?? null,
		expires: st.expires ?? null, successor: st.successor ?? null };   // v9: the release's not-after; a key it handed on
}
function m_system(req) {
	const c = uc(), cf = cache_cfg(), sys = sections_of(c, 'system', 'system')[0] ?? {}, up = +(words(rd('/proc/uptime'))[0] ?? 0);
	const cert = kv(rd('/etc/ex4/cert.info') ?? '');
	return { name: cf.name, zonename: sys.zonename ?? 'UTC', zones: sort(keys(zone_table())), admin: cf.admin,
		version: { ...cf.ver, ui: UI_VERSION }, update: update_now(),
		up: int(up), now: time(), trial: trial_now(up),
		cert: length(cert) ? { fp: cert.fp ?? null, names: split(cert.names ?? '', ','), made: +(cert.made ?? 0), days: +(cert.days ?? 0) } : null,
		net: { ...net_cfg(c), ports: ports(), live: addr_now(), pending: net_pending() } };
}
function m_system_set(req) {
	const a = req.args ?? {}, c = uc(), sys = sections_of(c, 'system', 'system')[0];
	if (!sys) return fail('no_system', 'The system settings are missing.');
	let renamed = false;
	if (a.hostname != null) {
		if (!isstr(a.hostname, 32) || !match(a.hostname, RX_HOST)) return fail('bad_name', 'A name is 1 to 32 lower-case letters, digits or dashes; no dash at either end.');
		c.set('system', sys['.name'], 'hostname', a.hostname); renamed = a.hostname != cache_cfg().name;
	}
	if (a.zonename != null) {
		const z = zone_table();
		if (!isstr(a.zonename, 40) || !exists(z, a.zonename)) return fail('bad_zone', 'Pick a time zone from the list.');
		c.set('system', sys['.name'], 'zonename', a.zonename); c.set('system', sys['.name'], 'timezone', z[a.zonename]);
	}
	c.commit('system');
	ev('system_set', { name: a.hostname ?? null, zone: a.zonename ?? null }); bump('system', 'panel');
	return { ok: true, renamed, job: job('system', [ 'system' ]) };
}
function m_net_set(req) {
	const a = req.args ?? {}, want = {};
	if (!has([ 'dhcp', 'static' ], a.mode)) return fail('bad_mode', 'The address comes from the router (dhcp) or is fixed (static).');
	if (!has([ 'none', 'active-backup' ], a.bond ?? 'none')) return fail('bad_bond', 'The two ports work alone (none) or as one with a spare (active-backup).');
	want.mode = a.mode; want.bond = a.bond ?? 'none';
	if (a.mode == 'static') {
		if (!ip_ok(a.addr)) return fail('bad_addr', 'The address is four numbers, like 192.0.2.50.');
		if (!mask_ok(a.mask)) return fail('bad_mask', 'The mask is four numbers, like 255.255.255.0.');
		if (a.gw != null && a.gw !== '' && !ip_ok(a.gw)) return fail('bad_gw', 'The router is four numbers, like 192.0.2.1.');
		if (type(a.dns ?? []) != 'array' || length(a.dns ?? []) > 3) return fail('bad_dns', 'Up to three name servers.');
		for (let d in (a.dns ?? [])) if (!ip_ok(d)) return fail('bad_dns', 'A name server is four numbers, like 192.0.2.1.');
		want.addr = a.addr; want.mask = a.mask; want.gw = a.gw ?? ''; want.dns = a.dns ?? [];
	}
	if (net_pending()) return fail('pending', 'A network change is already waiting to be confirmed.');
	put(RUN + '/net.want', sprintf('%J\n', want), 384);
	unlink(P(RUN + '/net.confirmed'));
	ev('net_set', { mode: want.mode, bond: want.bond }); bump('system');
	// the helper applies it and takes it back after 90 s unless net_confirm arrives: a headless box must not be
	// lockable out by a typing mistake
	return { ok: true, rollback_s: 90, job: job('network', [ 'net-apply' ]) };
}
function m_net_confirm(req) {
	if (!net_pending()) return fail('nothing', 'No network change is waiting.');
	put(RUN + '/net.confirmed', '1\n', 384); cache = null;
	ev('net_confirm', {}); bump('system');
	return { ok: true };
}
function m_cert_renew(req) { ev('cert_renew', {}); return { ok: true, job: job('certificate', [ 'cert', 'restart' ]) }; }
function m_restart(req) { ev('power', { what: 'restart' }); return { ok: true, job: job('restart', [ 'power', 'restart' ]) }; }
function m_shutdown(req) { ev('power', { what: 'shutdown' }); return { ok: true, job: job('shutdown', [ 'power', 'halt' ]) }; }
function m_trial_stay(req) {
	if (cache_cfg().trial_min == null) return fail('no_trial', 'This is not a trial boot.');
	put('/tmp/ex4-stay', 'web interface\n'); cache = null; ev('trial_stay', {});
	return { ok: true };
}
function m_support_bundle(req) { return { ok: true, job: job('bundle', [ 'bundle' ]) }; }
function m_bundle_get(req) {
	const t = rd(RUN + '/bundle.txt', 400000);
	return t ? { ok: true, text: t } : fail('none', 'No bundle has been made yet.');
}

// ---------------------------------------------------------------- the front panel. This file never opens the micro's
// serial port (one owner: ex4fan). It writes /etc/config/ex4panel; the panel daemon reads it.
function m_panel(req) {
	const c = uc(), p = c.get_all('ex4panel', 'main') ?? {}, j = panel_json(), sent = {};
	for (let k, v in (j?.panel?.sent ?? {})) if (type(v) == 'string' && length(k) <= 16) sent[k] = substr(v, 0, 32);
	return { tier: 'A', on: p.mode == 'tierA', live: j?.panel?.mode == 'tierA', lcd: (p.lcd_sleep_mode ?? '0') != '1', standby: p.standby ?? '3',
		standby_codes: STANDBY, sent, sent_age_s: (j && type(j.wall) == 'int') ? max(0, time() - j.wall) : null, daemon: !!climate() };
}
function m_panel_set(req) {                          // the option names are the ones ex4fan's conf_read() takes (docs/PANEL.md)
	const a = req.args ?? {};
	if (!access(P('/etc/config/ex4panel'))) put('/etc/config/ex4panel', '', 384);
	const c = uc();
	if (!c.get_all('ex4panel', 'main')) c.set('ex4panel', 'main', 'panel');
	if (a.on != null) { if (type(a.on) != 'bool') return fail('bad', 'on is true or false.'); c.set('ex4panel', 'main', 'mode', a.on ? 'tierA' : 'off'); }
	if (a.lcd != null) { if (type(a.lcd) != 'bool') return fail('bad', 'lcd is true or false.'); c.set('ex4panel', 'main', 'lcd_sleep_mode', a.lcd ? '0' : '1'); }
	if (a.standby != null) { if (!has(STANDBY, a.standby)) return fail('bad_standby', 'Only 10 seconds, 5 minutes and never are known to the screen so far.'); c.set('ex4panel', 'main', 'standby', a.standby); }
	c.commit('ex4panel'); bump('panel');
	ev('panel_set', {});
	return { ok: true };
}

// ---------------------------------------------------------------- the doors: first-boot claim, sign-in, sign-out
// There is NO default password. Until somebody claims the box it has no web account at all. Claiming needs a
// eight-digit code (v9; six until v8) only someone already inside it (ssh, key-only) or at its screen can read.
// rpcd's own `session login` does every password check and hands out the session; this file adds the brake rpcd
// lacks: after the second failure a lock-out starts and doubles (1 s, 2 s ... 5 min), and inside it nothing is
// checked at all. The brake is GLOBAL (the web server does not tell us who is asking): a hostile device on the LAN
// can keep it running. A file /var/run/ex4panel/presence, touched on a front-button press, clears it (a hook: the
// panel daemon logs buttons only, so far).
// v8 (the web review's nit 1): a failure is COUNTED BEFORE rpcd checks the password (the count is taken back when the
// password was right), and only ONE password check is in flight at a time: a burst of parallel guesses gets 'wait'
// instead of each slipping past the lock check while the first is still inside rpcd. The claim needs neither: its check
// is synchronous inside rpcd's one thread, so two claims can never overlap.
let fails = 0, locked_until = 0, locked_wall = 0, sids = [], inflight = false;
let claim_fails = 0, claim_locked_until = 0;
function lock_s(n) { return n < 3 ? 0 : min(300, 2 ** (n - 3)); }          // (declared before its first user: ucode does not hoist)
function brake_take() {                              // before a password check: count it as failed until proven right
	fails++; locked_wall = time(); locked_until = now_ms() + lock_s(fails) * 1000; inflight = true;
}
const NULL_SID = '00000000000000000000000000000000';
// v8 (the web review's nit 2): end EVERY web session of this interface (any rpcd session whose ACL names the ex4
// object), not only the ones this rpcd counted since it started, except `keep` (null = none). rpcd's `session list`
// answers with one reply per session, read through defer()'s data callback. done(n) gets how many were ended.
function end_sessions(keep, done) {
	const found = {};
	for (let s in sids) found[s] = true;
	bus_get().defer('session', 'list', {}, function(rc) {
		let n = 0;
		for (let s in keys(found)) if (s != keep && s != NULL_SID) { bus_get().defer('session', 'destroy', { ubus_rpc_session: s }, function() { }); n++; }
		sids = keep ? [ keep ] : [];
		done(n);
	}, function(r) {
		if (type(r?.ubus_rpc_session) == 'string' && r.ubus_rpc_session != NULL_SID && r?.acls?.ubus?.ex4 != null) found[r.ubus_rpc_session] = true;
	});
}
function claim_code(fresh) {
	let code = fresh ? null : (match(rdt(RUN + '/claim'), /^[0-9]{8}$/) ? rdt(RUN + '/claim') : null);
	if (!code) {
		// v9: EIGHT digits (the web door ships in every trial: the reviewer's "go to 8"), drawn without modulo bias:
		// a 31-bit draw at or above 2100000000 (the last partial block of 10^8) is thrown away and drawn again
		let v = -1;
		for (let i = 0; i < 16 && (v < 0 || v >= 2100000000); i++) {
			const r = readfile('/dev/urandom', 4);
			v = ((ord(r, 0) & 0x7f) << 24) | (ord(r, 1) << 16) | (ord(r, 2) << 8) | ord(r, 3);
		}
		if (v < 0 || v >= 2100000000) die('no random number for the claim code');
		code = sprintf('%08d', v % 100000000);
		put(RUN + '/claim', code + '\n', 384);
		// one alert file is how any program puts a line on the front screen (docs/PANEL.md): the code, 16 characters at most
		mkdir(P('/var/run/ex4panel'), 493); mkdir(P('/var/run/ex4panel/alerts.d'), 493);
		put('/var/run/ex4panel/alerts.d/00-claim', `setup ${code}\n`, 420);
	}
	return code;
}
function cert_fp() { return kv(rd('/etc/ex4/cert.info') ?? '').fp ?? null; }
function m_setup_state(req) {
	const c = cache_cfg();
	if (!c.claimed) claim_code(false);
	return { claimed: c.claimed, name: c.name, cert_fp: cert_fp(), ver: { ...c.ver, ui: UI_VERSION }, trial: c.trial_min != null };
}
function m_setup_claim(req) {
	const a = req.args ?? {}, cf = cache_cfg(), t = now_ms();
	if (cf.claimed) return fail('claimed', 'This box already has an administrator.');
	if (t < claim_locked_until) return { ok: false, err: 'wait', wait_s: int((claim_locked_until - t + 999) / 1000) };
	if (!isstr(a.code, 8) || a.code != claim_code(false)) {
		if (++claim_fails >= 5) { claim_fails = 0; claim_code(true); claim_locked_until = now_ms() + 60000; ev('claim_locked', {}); return { ok: false, err: 'wait', wait_s: 60, msg: 'Five wrong codes. The box has made a new code; read it again in a minute.' }; }
		return fail('bad_code', 'That is not the code the box is showing.');
	}
	if (!isstr(a.username, 31) || !match(a.username, RX_USER) || a.username == 'root') return fail('bad_name', 'An administrator name is 1 to 31 lower-case letters, digits, dashes or underscores, starts with a letter and is not root.');
	if (!isstr(a.hash, 140) || !match(a.hash, RX_HASH)) return fail('bad_hash', 'The password did not arrive in the form this box stores.');
	if (a.hostname != null && (!isstr(a.hostname, 32) || !match(a.hostname, RX_HOST))) return fail('bad_host', 'A name is 1 to 32 lower-case letters, digits or dashes; no dash at either end.');
	const c = uc();
	for (let s in sections_of(c, 'rpcd', 'login')) c.delete('rpcd', s['.name']);      // no other web login survives, root's least of all
	const sid = c.add('rpcd', 'login');
	c.set('rpcd', sid, 'username', a.username); c.set('rpcd', sid, 'password', a.hash);
	c.set('rpcd', sid, 'read', [ 'ex4' ]); c.set('rpcd', sid, 'write', [ 'ex4' ]);
	c.commit('rpcd');
	if (!c.get_all('ex4', 'main')) c.set('ex4', 'main', 'main');
	c.set('ex4', 'main', 'claimed', '1'); c.set('ex4', 'main', 'admin', a.username); c.commit('ex4');
	let renamed = false;
	if (a.hostname != null && a.hostname != cf.name) {
		const sys = sections_of(c, 'system', 'system')[0];
		if (sys) { c.set('system', sys['.name'], 'hostname', a.hostname); c.commit('system'); renamed = true; }
	}
	unlink(P(RUN + '/claim')); unlink(P('/var/run/ex4panel/alerts.d/00-claim'));
	claim_fails = 0; bump('system', 'panel');
	ev('claimed', { admin: a.username });
	if (renamed) job('system', [ 'system' ]);
	return { ok: true };
}
function presence() {                                // a front-button press since the lock-out began
	const st = stat(P('/var/run/ex4panel/presence'));
	return !!st && st.mtime >= locked_wall;
}
function m_sign_in(req) {
	const a = req.args ?? {}, t = now_ms(), cf = cache_cfg();
	if (!cf.claimed) return fail('unclaimed', 'This box has no administrator yet.');
	if (t < locked_until && presence()) { fails = 0; locked_until = 0; ev('lock_cleared', {}); }
	if (t < locked_until) return { ok: false, err: 'wait', wait_s: int((locked_until - t + 999) / 1000) };
	if (!isstr(a.username, 31) || !match(a.username, RX_USER) || !isstr(a.password, 256) || !length(a.password))
		return fail('bad', 'Name or password not right.');
	if (inflight) return { ok: false, err: 'wait', wait_s: 1, msg: 'Another sign-in is being checked; try again in a second.' };
	brake_take();
	bus_get().defer('session', 'login', { username: a.username, password: a.password, timeout: 900 }, function(rc, res) {
		inflight = false;
		if (rc == 0 && res?.ubus_rpc_session) {
			fails = 0; locked_until = 0; push(sids, res.ubus_rpc_session); if (length(sids) > 256) shift(sids);
			ev('signin', {});
			req.reply({ ok: true, sid: res.ubus_rpc_session, timeout: res.timeout, admin: a.username });
		}
		else {
			if (lock_s(fails) >= 4) ev('signin_fail', { n: fails });
			req.reply({ ok: false, err: lock_s(fails) ? 'wait' : 'bad', wait_s: lock_s(fails), msg: 'Name or password not right.' });
		}
	});
	return req.defer();
}
function m_keeper_passwd(req) {                      // the old password is checked by rpcd; the new one arrives as a hash
	const a = req.args ?? {}, cf = cache_cfg(), t = now_ms();
	if (!isstr(a.hash, 140) || !match(a.hash, RX_HASH)) return fail('bad_hash', 'The new password did not arrive in the form this box stores.');
	if (t < locked_until) return { ok: false, err: 'wait', wait_s: int((locked_until - t + 999) / 1000) };
	if (!isstr(a.old, 256) || !length(a.old)) return fail('bad', 'The current password is not right.');
	if (inflight) return { ok: false, err: 'wait', wait_s: 1, msg: 'Another sign-in is being checked; try again in a second.' };
	brake_take();
	const mine = a.ubus_rpc_session;                 // uhttpd puts the caller's own session id into every call
	bus_get().defer('session', 'login', { username: cf.admin, password: a.old, timeout: 10 }, function(rc, res) {
		inflight = false;
		if (rc != 0 || !res?.ubus_rpc_session)
			return req.reply({ ok: false, err: 'bad', wait_s: lock_s(fails), msg: 'The current password is not right.' });
		fails = 0; locked_until = 0;
		bus_get().defer('session', 'destroy', { ubus_rpc_session: res.ubus_rpc_session }, function() { });
		const c = uc();
		for (let s in sections_of(c, 'rpcd', 'login')) if (s.username == cf.admin) c.set('rpcd', s['.name'], 'password', a.hash);
		c.commit('rpcd');
		// v8: a new password ends every OTHER session (whoever knew the old one is out); the caller stays signed in
		end_sessions(type(mine) == 'string' ? mine : null, function(n) {
			ev('keeper_passwd', { ended: n });
			req.reply({ ok: true, ended: n });
		});
	});
	return req.defer();
}
function m_signout_all(req) {                        // v8: every web session of this interface, the caller's too
	end_sessions(null, function(n) {
		ev('signout_all', { n });
		req.reply({ ok: true, n });
	});
	return req.defer();
}

return {
	ex4: {
		// no session needed (acl/unauthenticated.json)
		setup_state:  { call: m_setup_state },
		setup_claim:  { args: { code: '', username: '', hash: '', hostname: '' }, call: m_setup_claim },
		sign_in:      { args: { username: '', password: '' }, call: m_sign_in },
		// read (acl/ex4.json, "read")
		status:       { call: function(req) { return snapshot(); } },
		events:       { args: { since: 0 }, call: m_events },
		disks:        { call: m_disks },
		array:        { call: m_array },
		shares:       { call: m_shares },
		users:        { call: m_users },
		services:     { call: m_services },
		alerts:       { call: m_alerts },
		system:       { call: m_system },
		panel:        { call: m_panel },
		bundle_get:   { call: m_bundle_get },
		// write (acl/ex4.json, "write")
		share_add:    { args: { name: '', guest: '', rw: [], ro: [], tm: false }, call: m_share_add },
		share_set:    { args: { name: '', guest: '', rw: [], ro: [], tm: false }, call: m_share_set },
		share_remove: { args: { name: '' }, call: m_share_remove },
		export_add:   { args: { share: '', clients: '', access: '', squash: '' }, call: m_export_add },
		export_set:   { args: { id: '', clients: '', access: '', squash: '' }, call: m_export_set },
		export_remove: { args: { id: '' }, call: m_export_remove },
		user_add:     { args: { name: '', password: '' }, call: m_user_add },
		user_passwd:  { args: { name: '', password: '' }, call: m_user_passwd },
		user_remove:  { args: { name: '' }, call: m_user_remove },
		group_add:    { args: { name: '', members: [] }, call: m_group_add },
		group_set:    { args: { name: '', members: [] }, call: m_group_set },
		group_remove: { args: { name: '' }, call: m_group_remove },
		service_set:  { args: { id: '', enabled: false }, call: m_service_set },
		alerts_set:   { args: { enabled: false, to: '', from: '', host: '', port: 0, tls: '', user: '', password: '', events: [], space_pct: 0 }, call: m_alerts_set },
		alerts_test:  { call: m_alerts_test },
		system_set:   { args: { hostname: '', zonename: '' }, call: m_system_set },
		net_set:      { args: { mode: '', addr: '', mask: '', gw: '', dns: [], bond: '' }, call: m_net_set },
		net_confirm:  { call: m_net_confirm },
		keeper_passwd: { args: { old: '', hash: '' }, call: m_keeper_passwd },
		signout_all:  { call: m_signout_all },
		cert_renew:   { call: m_cert_renew },
		restart:      { call: m_restart },
		shutdown:     { call: m_shutdown },
		trial_stay:   { call: m_trial_stay },
		support_bundle: { call: m_support_bundle },
		panel_set:    { args: { on: false, lcd: false, standby: '' }, call: m_panel_set }
	}
};
