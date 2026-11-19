// SPDX-License-Identifier: GPL-2.0-or-later
// app.js : the whole page's behaviour. One file, no framework, no library, nothing fetched but POST /ubus.
// Rules: every call is async and at most one poll is in flight; a hidden tab asks for nothing; every string that
// came from the box enters the page through textContent (share names, host names and SMART model strings are data
// an attacker can reach); no inline style attribute and no eval (the Content-Security-Policy forbids both).
'use strict';
(function () {
if (window.top !== window.self) return;            // never inside someone else's frame (a <meta> policy cannot say frame-ancestors)
const D = document, $ = (id) => D.getElementById(id), Z = '00000000000000000000000000000000';
const SVGNS = 'http://www.w3.org/2000/svg';
function el(tag, attrs, kids) {
	const n = D.createElement(tag);
	for (const k in attrs || {}) { if (k === 'text') n.textContent = attrs[k]; else if (k === 'style') throw new Error('no inline styles'); else if (attrs[k] !== false && attrs[k] != null) n.setAttribute(k, attrs[k] === true ? '' : attrs[k]); }
	(kids || []).forEach((c) => { if (c != null) n.appendChild(typeof c === 'string' ? D.createTextNode(c) : c); });
	return n;
}
function sv(tag, attrs, text) { const n = D.createElementNS(SVGNS, tag); for (const k in attrs || {}) n.setAttribute(k, attrs[k]); if (text != null) n.textContent = text; return n; }
function icon(name) { const s = sv('svg', { 'class': 'i', 'aria-hidden': 'true' }); s.appendChild(sv('use', { href: '#i-' + name })); return s; }
function fill(n, kids) { n.textContent = ''; (kids || []).forEach((c) => { if (c != null) n.appendChild(typeof c === 'string' ? D.createTextNode(c) : c); }); return n; }
function txt(id, s) { const n = $(id); if (n.textContent !== s) n.textContent = s; }
function state(kind, text) { return el('span', { 'class': 'state ' + kind }, [kind === 'good' ? icon('ok') : kind ? icon('warn') : null, el('span', { text })]); }
function kvs(id, rows) { fill($(id), [].concat.apply([], rows.filter(Boolean).map((r) => [el('dt', { text: r[0] }), el('dd', { text: r[1] })]))); }
function meter(id, pct, now, text) { const m = $(id); m.setAttribute('aria-valuenow', String(now)); if (text) m.setAttribute('aria-valuetext', text); m.firstElementChild.style.width = Math.max(0, Math.min(100, pct)) + '%'; }
const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/* ---------- words and numbers ---------- */
const f1 = (v) => v.toFixed(1), mib = (b) => (b || 0) / 1048576;
const NUM = ['no', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight'];
const num = (n) => NUM[n] || String(n), cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
const plural = (n, one, many) => (n === 1 ? one : many);
function size(kb) {                                // binary steps, the labels a file manager shows
	if (kb == null) return '?';
	const u = ['KB', 'MB', 'GB', 'TB']; let v = kb, i = 0;
	while (v >= 1024 && i < 3) { v /= 1024; i++; }
	return (v >= 100 || i === 0 ? String(Math.round(v)) : v.toFixed(1)) + ' ' + u[i];
}
function dur(s) {
	const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
	if (d) return d + plural(d, ' day', ' days') + (h ? ' ' + h + plural(h, ' hour', ' hours') : '');
	if (h) return h + plural(h, ' hour', ' hours') + (m ? ' ' + m + ' min' : '');
	return m ? m + ' min' : 'under a minute';
}
const mmss = (s) => Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
const years = (h) => (h == null ? '?' : (h / 8766).toFixed(1) + ' years');
const commas = (n) => (n == null ? '?' : String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ','));
function when(t) {
	const d = new Date(t * 1000), n = new Date(), hm = String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
	if (d.toDateString() === n.toDateString()) return hm;
	if (n - d < 6 * 86400000) return d.toLocaleDateString('en', { weekday: 'long' });
	return d.toLocaleDateString('en', { day: 'numeric', month: 'short' });
}
function ago(s) { return s < 90 ? 'a minute ago' : s < 5400 ? Math.round(s / 60) + ' minutes ago' : s < 129600 ? Math.round(s / 3600) + ' hours ago' : Math.round(s / 86400) + ' days ago'; }
const FAN = { low: 'turning slowly', medium: 'at half speed', high: 'turning fast', max: 'at full speed' };
const fp4 = (fp) => (fp || '').split(':').slice(0, 4).join(' ');

/* ---------- SHA-256 and sha256crypt ($5$): the administrator's password leaves this page only as this hash ---------- */
const K = new Uint32Array([@SHA256_K@]);
function sha256(m) {
	const H = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
	const l = m.length, n = ((l + 9 + 63) >> 6) << 6, b = new Uint8Array(n), w = new Uint32Array(64), v = new DataView(b.buffer);
	b.set(m); b[l] = 0x80; v.setUint32(n - 8, Math.floor(l / 536870912)); v.setUint32(n - 4, (l << 3) >>> 0);
	for (let o = 0; o < n; o += 64) {
		for (let i = 0; i < 16; i++) w[i] = v.getUint32(o + i * 4);
		for (let i = 16; i < 64; i++) { const x = w[i - 15], y = w[i - 2]; w[i] = (w[i - 16] + ((x >>> 7 | x << 25) ^ (x >>> 18 | x << 14) ^ (x >>> 3)) + w[i - 7] + ((y >>> 17 | y << 15) ^ (y >>> 19 | y << 13) ^ (y >>> 10))) | 0; }
		let a = H[0], bb = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
		for (let i = 0; i < 64; i++) {
			const t1 = (h + ((e >>> 6 | e << 26) ^ (e >>> 11 | e << 21) ^ (e >>> 25 | e << 7)) + ((e & f) ^ (~e & g)) + K[i] + w[i]) | 0;
			const t2 = (((a >>> 2 | a << 30) ^ (a >>> 13 | a << 19) ^ (a >>> 22 | a << 10)) + ((a & bb) ^ (a & c) ^ (bb & c))) | 0;
			h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = bb; bb = a; a = (t1 + t2) | 0;
		}
		H[0] += a; H[1] += bb; H[2] += c; H[3] += d; H[4] += e; H[5] += f; H[6] += g; H[7] += h;
	}
	const out = new Uint8Array(32), ov = new DataView(out.buffer);
	for (let i = 0; i < 8; i++) ov.setUint32(i * 4, H[i]);
	return out;
}
function cat() { let n = 0; for (const a of arguments) n += a.length; const o = new Uint8Array(n); n = 0; for (const a of arguments) { o.set(a, n); n += a.length; } return o; }
function rep(a, len) { const o = new Uint8Array(len); for (let i = 0; i < len; i++) o[i] = a[i % a.length]; return o; }
const B64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
function crypt5(password, salt) {
	const enc = new TextEncoder(), pw = enc.encode(password), sl = enc.encode(salt).slice(0, 16), n = pw.length;
	const B = sha256(cat(pw, sl, pw));
	let ctx = cat(pw, sl, rep(B, n));
	for (let i = n; i > 0; i >>= 1) ctx = cat(ctx, i & 1 ? B : pw);
	const A = sha256(ctx), P = rep(sha256(rep(pw, n * n)), n), S = rep(sha256(rep(sl, sl.length * (16 + A[0]))), sl.length);
	let C = A;
	for (let r = 0; r < 5000; r++) C = sha256(cat(r & 1 ? P : C, r % 3 ? S : new Uint8Array(0), r % 7 ? P : new Uint8Array(0), r & 1 ? C : P));
	let out = '';
	const put = (v, k) => { while (k--) { out += B64[v & 63]; v >>= 6; } };
	[[0, 10, 20], [21, 1, 11], [12, 22, 2], [3, 13, 23], [24, 4, 14], [15, 25, 5], [6, 16, 26], [27, 7, 17], [18, 28, 8], [9, 19, 29]].forEach((t) => put(C[t[0]] << 16 | C[t[1]] << 8 | C[t[2]], 4));
	put(C[31] << 8 | C[30], 3);
	return '$5$' + salt + '$' + out;
}
function hashNew(password) {                       // null when this browser gets the specification's own test vector wrong
	if (crypt5('Hello world!', 'saltstring') !== '$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5') return null;
	const r = new Uint8Array(16); crypto.getRandomValues(r);
	let salt = ''; r.forEach((x) => { salt += B64[x & 63]; });
	return crypt5(password, salt);
}

/* ---------- the door to the box: POST /ubus, JSON-RPC, a batch per request ---------- */
const DENIED = { denied: true };
let sid = Z, rid = 0;
try { sid = sessionStorage.getItem('ex4-sid') || Z; } catch (e) { }
function setSid(s) { sid = s || Z; try { if (s) sessionStorage.setItem('ex4-sid', s); else sessionStorage.removeItem('ex4-sid'); } catch (e) { } }
async function rpc(calls, as) {                    // [[method, args, object?], ...] -> [reply or null, ...]
	const body = calls.map((c) => ({ jsonrpc: '2.0', id: ++rid, method: 'call', params: [as || sid, c[2] || 'ex4', c[0], c[1] || {}] }));
	const r = await fetch('/ubus', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), cache: 'no-store', credentials: 'omit' });
	if (!r.ok) throw new Error('http ' + r.status);
	const j = await r.json();
	return j.map((x) => { if (x.error) { if (x.error.code === -32002) throw DENIED; return null; } return x.result && x.result[0] === 0 ? (x.result[1] || {}) : null; });
}
const call = async (m, a, as) => (await rpc([[m, a]], as))[0];

/* ---------- state ---------- */
let S = null, page = 'overview', inApp = false, setup = null;
const slow = {}, WIN = 300, samples = [];          // slow parts by name: { rev, data }; five minutes of samples
const PARTS = { overview: ['events', 'disks'], storage: ['disks', 'array'], shares: ['shares', 'users'], users: ['users'], services: ['services'], alerts: ['alerts'], panel: ['panel'], system: ['system'], more: [] };
const REVOF = { events: 'events', disks: 'disks', array: 'disks', shares: 'shares', users: 'users', services: 'services', alerts: 'alerts', panel: 'panel', system: 'system' };
const TITLES = { overview: 'Overview', storage: 'Storage', shares: 'Shares', users: 'Users', services: 'Services', alerts: 'Alerts', panel: 'Front panel', system: 'System', more: 'More' };
const dirty = {}, watched = {};

/* ---------- toast, dialog ---------- */
let toastT;
function toast(msg, bad) { const t = $('toast'); t.textContent = msg; t.className = 'toast' + (bad ? ' bad' : ''); clearTimeout(toastT); toastT = setTimeout(() => { t.textContent = ''; }, bad ? 9000 : 3200); }
let dlgOk = null;
function ask(title, kids, okLabel, onOk, danger) {
	txt('dlg-h', title); fill($('dlg-b'), kids); txt('dlg-err', '');
	const ok = $('dlg-ok'); ok.textContent = okLabel || 'Save'; ok.className = 'btn ' + (danger ? 'danger' : 'primary'); ok.disabled = false;
	dlgOk = onOk; $('dlg').showModal();
	const first = $('dlg-b').querySelector('input,select'); if (first) first.focus(); else ok.focus();
}
$('dlg-no').addEventListener('click', () => $('dlg').close());
$('dlg-f').addEventListener('submit', async (e) => {
	e.preventDefault();
	const ok = $('dlg-ok'); ok.disabled = true;
	let err = 'The box did not answer.';
	try { err = await dlgOk(); } catch (x) { if (x === DENIED) { $('dlg').close(); return toDoor('Signed out. Sign in again to go on.'); } }
	ok.disabled = false;
	if (err) txt('dlg-err', err); else { $('dlg').close(); poll(true); }
});
async function act(method, args, done) {           // a write: null when the box took it, else the sentence to show
	const r = await call(method, args);
	if (!r || !r.ok) return (r && r.msg) || (r && r.err === 'wait' ? 'Too many tries. Wait ' + r.wait_s + ' s.' : 'The box refused that.');
	if (r.job) watched[r.job] = done || 'Done.';
	return null;
}
let hintN = 0;
function field(label, input, hint) {                // a label holding its control; the hint sits beside it, tied on by aria-describedby
	const id = hint ? 'hint' + (++hintN) : null; if (id) input.setAttribute('aria-describedby', id);
	input.setAttribute('data-f', label);
	return el('div', { 'class': 'lab' }, [el('label', {}, [label, input]), hint ? el('span', { 'class': 'hint', id, text: hint }) : null]);
}
function input(type, value, attrs) { const i = el('input', Object.assign({ type }, attrs || {})); if (value != null) i.value = value; return i; }
function select(options, value) { const s = el('select', {}, options.map((o) => el('option', { value: o[0], text: o[1] }))); s.value = value; return s; }
function check(label, on) { const c = el('input', { type: 'checkbox' }); c.checked = !!on; return { box: c, node: el('label', { 'class': 'inline' }, [c, el('span', { text: label })]) }; }

/* ---------- the sentence ---------- */
function bayOf(dev) { const d = (S.disks || []).find((x) => x.dev === dev); return d ? d.bay : '?'; }
function arrWord(a) { return !a ? 'not open' : a.state === 'readonly' || a.ro ? 'whole and open read-only' : a.state === 'clean' ? 'clean' : a.state === 'active' ? 'in step and in use' : a.state; }
function sentence() {
	const h = S.health, why = h.why, by = (c) => why.find((w) => w.c === c), a = S.array, c = S.clim, nd = (S.disks || []).length;
	const moving = mib(S.net.rx) > 1 ? 'A copy is arriving at about ' + Math.round(mib(S.net.rx)) + ' MiB/s. ' : mib(S.net.tx) > 1 ? 'A copy is leaving at about ' + Math.round(mib(S.net.tx)) + ' MiB/s. ' : 'Nothing is moving. ';
	const rest = (c && c.hot != null ? c.hot + ' °C at the warmest and the fan ' + (FAN[c.fan] || c.fan) + '.' : 'No word from the fan controller yet.');
	const watch = why.filter((w) => w.c === 'disk_watch');
	const w0 = watch[0], seen = w0 ? (w0.pending ? 'met ' + num(w0.pending) + plural(w0.pending, ' sector', ' sectors') + ' it could not read' : w0.realloc ? 'has moved ' + num(w0.realloc) + plural(w0.realloc, ' sector', ' sectors') + ' to its spares' : 'reported an error it could not correct') : '';
	let x;
	if (h.level === 'down') return ['The array is down.', 'The array cannot be read as it is. Do not pull or swap disks. Look at Storage, then at the log; your files are most likely still on the disks.'];
	if ((x = by('disk_failed'))) return ['A disk has failed.', 'The disk in bay ' + (x.bay || '?') + ' has dropped out. Your files are still safe: the others hold everything. Replace that disk; until then there is no spare.'];
	if ((x = by('rebuild'))) {
		const left = x.pct != null && x.speed_kb && a ? (1 - x.pct / 100) * a.size_kb / Math.max(1, a.disks - 1) / x.speed_kb : null;
		return ['The array is rebuilding.', (x.pct != null ? x.pct + '% done' : 'Under way') + (left ? ', about ' + dur(left) + ' to go' : '') + '. Your files are safe and you can keep using the box; it will be slower until this is done.'];
	}
	if ((x = by('hot'))) return ['The box is running hot.', 'The warmest disk is at ' + x.temp + ' °C and the fan is ' + (c ? FAN[c.fan] || c.fan : 'unknown') + '. Check that the vents are clear and the room is not too warm.'];
	if (by('fan_stopped')) return ['The fan has stopped.', 'The fan was told to turn and is not turning. Shut the box down until that is looked at; disks do not like heat.'];
	if (w0) return [watch.length > 1 ? cap(num(watch.length)) + ' disks want watching.' : 'One disk wants watching.',
		'The disk in bay ' + w0.bay + ' ' + seen + '. ' + (a ? 'The array is still whole and your files are safe. ' : '') + 'Nothing to do today; if the count grows, replace that disk.'];
	if (by('full')) return ['The volume is nearly full.', 'Less than 3% is free. Nothing is lost; make room when you can.'];
	if (by('micro_silent')) return ['The front panel is not answering.', 'The fan runs at full speed to be safe. ' + moving];
	if (h.level === 'closed') return ['The array is not open.', 'The disks are in their bays and nothing on them is being touched. This boot has not opened the array, so there is nothing to share yet. ' + rest];
	return ['All is well.', moving + cap(num(nd)) + plural(nd, ' disk', ' disks') + ' healthy, the array is ' + arrWord(a) + ', ' + rest.charAt(0).toLowerCase() + rest.slice(1)];
}

/* ---------- overview ---------- */
function chip(kind, text) { return el('li', { 'class': 'chip ' + kind }, [kind === 'good' ? icon('ok') : kind ? icon('warn') : null, el('span', { text })]); }
function rOverview() {
	const st = sentence(), c = S.clim, a = S.array, v = S.vol, dl = S.disks || [], bad = dl.filter((d) => d.v === 'watch' || d.v === 'fail');
	txt('say', st[0]); txt('lede', st[1]);
	D.title = S.name + ' · ' + st[0].replace(/\.$/, '').toLowerCase();
	txt('upfor', 'up ' + dur(S.up));
	const facts = [];
	facts.push(!a ? chip('', 'Array not open') : a.degraded ? chip('crit', 'Array on ' + num(a.disks - a.degraded) + ' of ' + num(a.disks)) : chip('good', a.ro ? 'Array whole, read-only' : 'Array clean'));
	if (bad.length) bad.forEach((d) => facts.push(chip(d.v === 'fail' ? 'crit' : 'warn', 'Bay ' + d.bay + (d.v === 'fail' ? ' failed' : ' wants watching'))));
	else if (dl.length) facts.push(chip('good', dl.length + ' of ' + dl.length + ' disks healthy'));
	if (c && c.hot != null) { const ts = Object.values(c.disks); facts.push(chip('', Math.min.apply(null, ts) + ' to ' + c.hot + ' °C')); facts.push(chip('', 'Fan ' + c.fan + (c.rpm != null ? ' · ' + commas(c.rpm) + ' rpm' : ''))); }
	fill($('facts'), facts);
	// the portrait: the screen says what the real one was given (its name page); the lights follow the disks
	const busy = mib(S.io.rd + S.io.wr) > 1, lines = [String(S.name).slice(0, 16), S.addr || location.hostname];
	const lc = $('lcd').children; lc[0].textContent = lines[0]; lc[1].textContent = lines[1];
	$('lcd').setAttribute('aria-label', 'Front screen: ' + lines.join(', '));
	fill($('bays'), dl.map((d) => el('div', { 'class': 'bay', title: 'Bay ' + d.bay + (d.temp != null ? ', ' + d.temp + ' °C' : '') + (d.v === 'watch' ? ', wants watching' : d.v === 'fail' ? ', failed' : '') },
		[el('span', { 'class': 'led' + (d.v === 'fail' ? ' crit' : d.v === 'watch' ? ' warn' : busy && !reduce ? ' busy' : '') }), el('b', { text: String(d.bay) }), el('span', { text: d.temp != null ? d.temp + '°' : '' })])));
	// numbers
	const rx = mib(S.net.rx), tx = mib(S.net.tx), cpu = S.cpu == null ? 0 : Math.round(S.cpu * 100);
	txt('k-in', f1(rx)); txt('k-out', f1(tx)); txt('k-cpu', String(cpu)); meter('m-cpu', cpu, cpu);
	fill($('act-state'), rx > 1 || tx > 1 ? [el('span', { 'class': 'dot s1' }), el('span', { text: rx >= tx ? 'A copy is arriving' : 'A copy is leaving' })] : [el('span', { text: 'Nothing is moving' })]);
	txt('act-note', cpu > 90 ? 'The processor is the limit here: one core, fully used. This is as fast as this box can move a file.' : 'One core, mostly resting.');
	rChart(); rTable();
	// space
	if (v.mounted && v.total_kb) {
		const pct = 100 * v.used_kb / v.total_kb;
		fill($('cap-big'), [size(v.free_kb).split(' ')[0], el('small', { text: size(v.free_kb).split(' ')[1] + ' free' })]);
		meter('m-cap', Math.max(pct, 0.6), Math.round(pct), size(v.used_kb) + ' used of ' + size(v.total_kb));
		txt('cap-note', size(v.used_kb) + ' used of ' + size(v.total_kb) + '. ' + (a && a.level === 'raid5' ? cap(num(a.disks)) + ' disks as RAID 5: any one of them can fail and nothing is lost.' : ''));
	} else { fill($('cap-big'), ['—']); meter('m-cap', 0, 0); txt('cap-note', v.mounted ? 'Free space has not been read yet; the box looks every five minutes.' : 'The data volume is not open.'); }
	// climate
	if (c && c.hot != null) {
		fill($('clim-big'), [String(c.hot), el('small', { text: '°C at the warmest disk' })]); meter('m-temp', (c.hot - 20) * 2.5, c.hot);
		kvs('clim-kv', [['Fan', cap(c.fan || '?') + (c.rpm != null ? ' · ' + commas(c.rpm) + ' rpm' : '')], c.board != null && ['Board', c.board + ' °C'], ['Counts as hot at', '55 °C']]);
	} else { fill($('clim-big'), ['—']); meter('m-temp', 0, 20); kvs('clim-kv', [['Fan', 'no word from its controller']]); }
	// disks (model and age come with the slow part)
	const full = (slow.disks && slow.disks.data.disks) || [];
	fill($('disks'), dl.map((d) => { const f = full.find((x) => x.dev === d.dev) || {};
		return el('li', {}, [el('span', { 'class': 'bayn', text: String(d.bay), 'aria-label': 'Bay ' + d.bay }), el('div', { 'class': 't' }, [el('b', { text: String(f.model || d.dev).replace(/^WDC /, '') }), el('span', { text: (d.temp != null ? d.temp + ' °C · ' : '') + (f.hours != null ? years(f.hours) + ' running' : '') })]), health(d)]); }));
	if (!dl.length) fill($('disks'), [el('li', { 'class': 'empty', text: 'No disks are seen.' })]);
	// network
	const up = (S.ports || []).find((p) => p.up);
	fill($('net-big'), up && up.speed ? [String(up.speed >= 1000 ? up.speed / 1000 : up.speed), el('small', { text: (up.speed >= 1000 ? 'Gb/s' : 'Mb/s') + ' link' })] : ['—']);
	kvs('net-kv', [['Address', S.addr || location.hostname], S.lan && ['Given by', S.lan.mode === 'static' ? 'a fixed setting here' : 'your router']].concat((S.ports || []).map((p, i) => ['Port ' + (i + 1), p.up ? 'connected' : 'no cable']),
		[S.lan && S.lan.bond !== 'none' && ['The two ports', 'work as one, the second a spare'], ['Name on the network', S.name + '.local']]));
	rEvents();
}
function health(d) { return d.v === 'fail' ? state('crit', 'Failed') : d.v === 'watch' ? state('warn', 'Wants watching') : d.v === 'ok' ? state('good', 'Healthy') : state('', 'Not read yet'); }

/* ---------- activity chart: time on x, two series, a table twin, readable by keyboard ---------- */
let cross = -1;
const cx = { x0: 0, x1: 1 };
function rChart() {
	const svg = $('svg'), w = Math.max(280, svg.clientWidth || 600), h = 190, L = 34, R = 58, T = 24, B = 24, now = S.now;
	const pts = samples.filter((p) => p.t >= now - WIN), max = Math.max.apply(null, [0].concat(pts.map((p) => Math.max(p.rx, p.tx))));
	const top = max < 4 ? 5 : max < 20 ? 25 : Math.ceil(max / 25) * 25;
	const x = (t) => L + (w - L - R) * (1 - (now - t) / WIN), y = (v) => T + (h - T - B) * (1 - v / top);
	svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h); svg.textContent = '';
	[0, top / 2, top].forEach((t) => { svg.appendChild(sv('line', { 'class': 'grid-l', x1: L, x2: w - R, y1: y(t), y2: y(t) })); svg.appendChild(sv('text', { x: L - 8, y: y(t) + 4, 'text-anchor': 'end' }, String(t))); });
	svg.appendChild(sv('text', { x: L, y: h - 5 }, '5 min ago')); svg.appendChild(sv('text', { x: w - R, y: h - 5, 'text-anchor': 'end' }, 'now')); svg.appendChild(sv('text', { x: L - 26, y: 11 }, 'MiB/s'));
	const line = (k) => { let d = '', last = 0; pts.forEach((p) => { d += (d && p.t - last <= 12 ? 'L' : 'M') + x(p.t).toFixed(1) + ' ' + y(p[k]).toFixed(1); last = p.t; }); return d; };
	if (pts.length > 1) {
		svg.appendChild(sv('path', { 'class': 'a1', d: line('rx').replace(/M/g, (m, i) => (i ? 'L' : 'M')) + 'L' + x(pts[pts.length - 1].t).toFixed(1) + ' ' + y(0) + 'L' + x(pts[0].t).toFixed(1) + ' ' + y(0) + 'Z' }));
		svg.appendChild(sv('path', { 'class': 'l2', d: line('tx') })); svg.appendChild(sv('path', { 'class': 'l1', d: line('rx') }));
	}
	const lastp = pts[pts.length - 1];
	if (lastp) {
		let e1 = y(lastp.rx), e2 = y(lastp.tx);
		if (Math.abs(e1 - e2) < 15) { if (e1 <= e2) e2 = e1 + 15; else e1 = e2 + 15; }     // two end labels never sit on each other
		[['rx', 'cs1', e1], ['tx', 'cs2', e2]].forEach((s) => { svg.appendChild(sv('circle', { 'class': 'end ' + s[1], cx: x(lastp.t), cy: y(lastp[s[0]]), r: 4.5 })); svg.appendChild(sv('text', { 'class': 'tfill', x: x(lastp.t) + 10, y: s[2] + 4 }, f1(lastp[s[0]]))); });
	}
	const tip = $('tip'), p = cross >= 0 ? pts[Math.min(cross, pts.length - 1)] : null;
	if (p) {
		const sec = now - p.t, whenS = sec < 2 ? 'now' : sec < 60 ? sec + ' s ago' : Math.floor(sec / 60) + ' min ' + (sec % 60 ? sec % 60 + ' s ' : '') + 'ago';
		svg.appendChild(sv('line', { 'class': 'cross', x1: x(p.t), x2: x(p.t), y1: T, y2: h - B }));
		svg.appendChild(sv('circle', { 'class': 'end cs1', cx: x(p.t), cy: y(p.rx), r: 4.5 })); svg.appendChild(sv('circle', { 'class': 'end cs2', cx: x(p.t), cy: y(p.tx), r: 4.5 }));
		tip.hidden = false;
		fill(tip, [el('div', { 'class': 'when', text: whenS }), el('div', { 'class': 'row' }, [el('i', { 'class': 'key' }), el('span', { text: 'Arriving' }), el('b', { text: f1(p.rx) })]), el('div', { 'class': 'row' }, [el('i', { 'class': 'key k2' }), el('span', { text: 'Leaving' }), el('b', { text: f1(p.tx) })])]);
		const px = x(p.t), tw = tip.offsetWidth || 140; tip.style.left = Math.max(0, Math.min(w - tw, px + (px > w / 2 ? -tw - 12 : 12))) + 'px';
		$('hit').setAttribute('aria-valuetext', whenS + ': arriving ' + f1(p.rx) + ', leaving ' + f1(p.tx) + ' MiB/s');
	} else tip.hidden = true;
	txt('chart-sum', lastp ? 'Megabytes per second over five minutes. Now arriving ' + f1(lastp.rx) + ', leaving ' + f1(lastp.tx) + '. Highest ' + f1(max) + '.' : 'No samples yet.');
	cx.x0 = L; cx.x1 = w - R; cx.n = pts.length; cx.pts = pts; cx.now = now;
}
function rTable() {
	if (!$('act-tbl').open) return;
	const pts = cx.pts || [], rows = [];
	for (let i = pts.length - 1, last = Infinity; i >= 0; i--) if (last - pts[i].t >= 30) { last = pts[i].t; const s = cx.now - pts[i].t; rows.push(el('tr', {}, [el('td', { text: s < 2 ? 'now' : s < 60 ? s + ' s ago' : Math.round(s / 60) + ' min ago' }), el('td', { 'class': 'num', text: f1(pts[i].rx) }), el('td', { 'class': 'num', text: f1(pts[i].tx) })])); }
	fill($('tbody'), rows);
}
(function () {
	const hit = $('hit'), set = (i) => { cross = Math.max(0, Math.min((cx.n || 1) - 1, i)); if (S) rChart(); };
	hit.addEventListener('pointermove', (e) => { const r = hit.getBoundingClientRect(), t = cx.now - WIN * (1 - (e.clientX - r.left - cx.x0) / (cx.x1 - cx.x0)); let best = 0; (cx.pts || []).forEach((p, i) => { if (Math.abs(p.t - t) < Math.abs(cx.pts[best].t - t)) best = i; }); set(best); });
	hit.addEventListener('pointerleave', () => { if (D.activeElement !== hit) { cross = -1; if (S) rChart(); } });
	hit.addEventListener('focus', () => { if (cross < 0) set((cx.n || 1) - 1); });
	hit.addEventListener('blur', () => { cross = -1; if (S) rChart(); });
	hit.addEventListener('keydown', (e) => {
		const d = { ArrowLeft: -1, ArrowRight: 1, PageUp: -15, PageDown: 15 }[e.key];
		if (d) { e.preventDefault(); set((cross < 0 ? (cx.n || 1) - 1 : cross) + d); }
		else if (e.key === 'Home') { e.preventDefault(); set(0); } else if (e.key === 'End') { e.preventDefault(); set((cx.n || 1) - 1); }
		else if (e.key === 'Escape') { cross = -1; if (S) rChart(); }
	});
	$('act-tbl').addEventListener('toggle', rTable);
	if (window.ResizeObserver) new ResizeObserver(() => { if (S && page === 'overview') rChart(); }).observe($('chart'));
})();

/* ---------- lately ---------- */
const SVC = { smb: ['Windows and Mac file sharing', 'SMB. What a PC or a Mac opens in its file manager.'], nfs: ['Unix file sharing', 'NFS, for Linux and other Unix machines. Exports are set on the Shares page.'],
	find: ['Seen on the network', 'Lets Windows (WS-Discovery) and Macs (Bonjour) list this box by name.'], ssh: ['Secure shell', 'For its owner, by key only. No password opens it.'], time: ['Clock from the network', 'Keeps the time right (NTP).'] };
function evWords(e) {
	const a = e.a || {}, on = (b) => (b ? 'on' : 'off');
	switch (e.k) {
	case 'claimed': return ['This box was claimed', 'administrator ' + a.admin];
	case 'signin': return ['Signed in', 'to this page'];
	case 'signin_fail': return ['Sign-in failed ' + a.n + ' times in a row', 'the door is slowing down'];
	case 'lock_cleared': return ['Sign-in lock-out cleared', 'by a button on the box'];
	case 'claim_locked': return ['Five wrong setup codes', 'the box made a new code'];
	case 'share_add': return ['Share added', a.name + (a.made ? ' · a new folder was made' : '')];
	case 'share_set': return ['Share changed', a.name];
	case 'share_remove': return ['Share removed', a.name + ' · its folder and files stay'];
	case 'export_add': return ['NFS export added', a.share + ' to ' + a.clients];
	case 'export_remove': return ['NFS export removed', a.share];
	case 'user_add': return ['Person added', a.name];
	case 'user_passwd': return ['Password changed', 'for ' + a.name];
	case 'user_remove': return ['Person removed', a.name];
	case 'group_add': return ['Group added', a.name];
	case 'group_remove': return ['Group removed', a.name];
	case 'service_set': return [(SVC[a.id] || [a.id])[0] + ' switched ' + on(a.on), ''];
	case 'alerts_set': return ['Alerts changed', 'now ' + on(a.on)];
	case 'alert_test': return [a.ok ? 'Test e-mail handed to the mail server' : 'Test e-mail was refused', a.ok ? '' : 'check the server settings'];
	case 'system_set': return ['Name or clock changed', a.name || a.zone || ''];
	case 'net_set': return ['New network settings on trial', a.mode === 'static' ? 'a fixed address' : 'address from the router'];
	case 'net_confirm': case 'net_kept': return ['New network settings kept', ''];
	case 'net_rollback': return ['Network settings taken back', 'nobody confirmed the new ones'];
	case 'cert_renew': return ['A new certificate was made', ''];
	case 'power': return [a.what === 'restart' ? 'Restart asked for' : 'Shutdown asked for', 'from this page'];
	case 'trial_stay': return ['Trial told to stay', 'no automatic return'];
	case 'keeper_passwd': return ['Administrator password changed', ''];
	case 'signout_all': return ['Signed out everywhere', ''];
	case 'disk_watch': return ['Bay ' + bayOf(a.dev) + ' wants watching', (a.pending ? a.pending + ' unreadable' : '') + (a.pending && a.realloc ? ', ' : '') + (a.realloc ? a.realloc + ' moved' : '') + plural((a.pending || 0) + (a.realloc || 0), ' sector', ' sectors')];
	case 'disk_fail': return ['Bay ' + bayOf(a.dev) + ' reports it is failing', 'replace that disk'];
	case 'array_down': return ['The array went down', ''];
	case 'array_degraded': return ['A disk dropped out of the array', 'files are still safe'];
	case 'array_rebuild': return ['The array began to rebuild', ''];
	case 'array_ok': return ['The array is whole again', ''];
	case 'hot': return ['A disk reached 55 °C', 'check the vents']; case 'cool': return ['Temperatures are back to normal', ''];
	case 'space_low': return ['The volume is ' + a.pct + '% full', ''];
	default: return [e.k.replace(/_/g, ' '), ''];
	}
}
function rEvents() {
	const ev = ((slow.events && slow.events.data.events) || []).slice(-6).reverse();
	fill($('events'), ev.length ? ev.map((e) => { const w = evWords(e); return el('li', {}, [el('span', { 'class': 'time', text: when(e.t) }), el('div', { 'class': 't' }, [el('b', { text: w[0] }), w[1] ? el('span', { text: w[1] }) : null])]); }) : [el('li', { 'class': 'empty', text: 'Nothing has happened yet.' })]);
}

/* ---------- storage ---------- */
function rStorage() {
	const A = slow.array && slow.array.data, dl = (slow.disks && slow.disks.data.disks) || [];
	if (!A) return;
	const a = A.array, v = A.vol, n = a ? a.members.length : 0;
	if (a) {
		const bad = a.members.filter((m) => m.state.indexOf('in_sync') < 0), act = { recover: 'Rebuilding', resync: 'Resyncing', check: 'Being checked', repair: 'Being repaired', reshape: 'Reshaping' }[a.action];
		fill($('arr-state'), [state(bad.length || a.degraded ? 'warn' : 'good', act ? act + (a.pct != null ? ', ' + a.pct + '%' : '') : a.degraded ? 'Running on ' + num(a.disks - a.degraded) + ' of ' + num(a.disks) + ' disks' : 'Whole, all ' + num(a.disks) + ' in step')]);
		fill($('arr-big'), [a.level.replace(/^raid/, 'RAID '), el('small', { text: size(a.size_kb) + ' across ' + num(a.disks) + ' disks' })]);
		fill($('members'), a.members.map((m) => { const d = dl.find((x) => x.dev === m.dev) || {}; return el('div', { 'class': m.state.indexOf('in_sync') < 0 ? 'out' : d.v === 'watch' ? 'watch' : '', text: 'Bay ' + (m.bay || '?') }); }));
		const anyW = dl.some((d) => d.v === 'watch');
		fill($('arr-legend'), [el('span', {}, [el('i'), 'in step']), anyW ? el('span', {}, [el('i', { 'class': 'w' }), 'in step, disk wants watching']) : null, bad.length ? el('span', {}, [el('i', { 'class': 'o' }), 'not in step']) : null]);
		kvs('arr-kv', [['If one disk fails', a.level === 'raid5' ? 'nothing is lost; replace it and the array rebuilds' : 'see the level\'s own rules'],
			['Array checks', 'never started by this system on its own' + (a.mismatch ? '; last count of mismatches: ' + a.mismatch : '')],
			['Open', a.ro ? 'read-only: nothing can be written to it' + (S.trial ? ' in this trial' : '') : 'read-write'],
			['File system', v.mounted ? 'mounted at ' + v.path + (v.rw ? '' : ', read-only') : 'not mounted'],
			['Layout', a.chunk_kb + ' KiB chunks, metadata ' + a.meta + (a.bitmap ? ', write-intent bitmap' : ', no write-intent bitmap')]]);
	} else {
		fill($('arr-state'), [state('', 'Not open')]); fill($('arr-big'), ['—']); fill($('members'), []); fill($('arr-legend'), []);
		kvs('arr-kv', [['Why', 'this boot has not assembled the array; the disks are untouched'], ['Array checks', 'never started by this system on its own']]);
	}
	if (v.mounted && v.total_kb) {
		const pct = 100 * v.used_kb / v.total_kb;
		fill($('vol-big'), [pct < 1 ? '<1' : String(Math.round(pct)), el('small', { text: '% used' })]); meter('m-vol', Math.max(pct, 0.6), Math.round(pct));
		kvs('vol-kv', [['Used', size(v.used_kb)], ['Free', size(v.free_kb)], ['Total', size(v.total_kb)]]);
	} else { fill($('vol-big'), ['—']); meter('m-vol', 0, 0); kvs('vol-kv', [['Volume', v.mounted ? 'not measured yet' : 'not open']]); }
	const read = dl.map((d) => d.smart_t).filter(Boolean);
	txt('dt-age', read.length ? 'Health read ' + ago(S.now - Math.min.apply(null, read)) + ', without waking a sleeping disk' : 'Health has not been read yet; the box asks every half hour');
	const open = {}; $('dtable').querySelectorAll('.xbtn[aria-expanded="true"]').forEach((b) => { open[b.getAttribute('aria-controls')] = 1; });
	const rows = [];
	dl.forEach((d) => {
		const id = 'dd' + d.bay, btn = el('button', { 'class': 'xbtn', type: 'button', 'aria-expanded': open[id] ? 'true' : 'false', 'aria-controls': id }, [icon('chev'), el('span', { text: 'Bay ' + d.bay })]);
		const tr = el('tr', {}, [el('td', { 'class': 'first' }, [btn]), el('td', { 'data-l': 'Disk' }, [el('b', { 'class': 'b6', text: d.model || d.dev }), el('span', { 'class': 'muted small nowrap', text: d.serial ? ' ' + d.serial : '' })]),
			el('td', { 'class': 'num', 'data-l': 'Temperature', text: d.temp != null ? d.temp + ' °C' : '?' }), el('td', { 'class': 'num', 'data-l': 'Running', text: years(d.hours) }),
			el('td', { 'class': 'num', 'data-l': 'Moved sectors', text: d.realloc == null ? '?' : String(d.realloc) }), el('td', { 'class': 'num', 'data-l': 'Unreadable', text: d.pending == null ? '?' : String(d.pending) }), el('td', { 'data-l': 'Health' }, [health(d)])]);
		const cells = [['Power-on hours', commas(d.hours)], ['Start/stop count', commas(d.starts)], ['Head load cycles', commas(d.load)], ['Reallocated sectors', commas(d.realloc)], ['Pending sectors', commas(d.pending)], ['Uncorrectable', commas(d.uncorrect)],
			['Interface errors', commas(d.crc)], ['Size', (d.size_b / 1e12).toFixed(1) + ' TB (' + size(d.size_b / 1024) + ' as a file manager counts)'], ['In the array', d.member ? d.member.replace('in_sync', 'in step') : 'not a member'],
			['The drive\'s own verdict', d.passed == null ? 'not read' : d.passed ? 'passed' : 'FAILING'], ['Device', '/dev/' + d.dev]];
		const det = el('tr', { 'class': 'detail', id, hidden: !open[id] }, [el('td', { colspan: '7' }, [el('div', { 'class': 'smart' }, cells.map((c) => el('div', {}, [el('span', { text: c[0] }), el('b', { text: c[1] })])))])]);
		btn.addEventListener('click', () => { const o = btn.getAttribute('aria-expanded') === 'true'; btn.setAttribute('aria-expanded', String(!o)); det.hidden = o; });
		rows.push(tr, det);
	});
	fill($('dtable'), rows.length ? rows : [el('tr', {}, [el('td', { colspan: '7', 'class': 'empty', text: 'No disks are seen.' })])]);
}

/* ---------- shares and NFS exports ---------- */
function whoText(s) {
	const nm = (w) => (w.charAt(0) === '@' ? 'the ' + w.slice(1) + ' group' : w), list = (a) => a.map(nm).join(', ');
	const p = [];
	if (s.guest === 'rw') p.push('Everyone may read and change it');
	else if (s.guest === 'ro') p.push('Everyone may read it');
	if (s.rw.length && s.guest !== 'rw') p.push(list(s.rw) + ' may change it');
	if (s.ro.length && s.guest === 'no') p.push(list(s.ro) + ' may read it');
	return p.length ? p.join('; ') + '.' : 'Nobody can open it yet.';
}
function shareForm(s, U) {
	const names = U.users.map((u) => u.name).concat(U.groups.map((g) => '@' + g.name));
	const guest = select([['no', 'only the people below'], ['ro', 'everyone may read'], ['rw', 'everyone may read and change']], s.guest);
	const sels = names.map((w) => [w, select([['', 'no access'], ['ro', 'may read'], ['rw', 'may change']], s.rw.indexOf(w) >= 0 ? 'rw' : s.ro.indexOf(w) >= 0 ? 'ro' : '')]);
	const tm = check('A Time Machine target for Macs', s.tm);
	const who = el('div', { 'class': 'who' }, [].concat.apply([], sels.map((x) => { x[1].setAttribute('aria-label', 'Access for ' + x[0]); return [el('span', { text: x[0].charAt(0) === '@' ? x[0].slice(1) + ' (group)' : x[0] }), x[1]]; })));
	return { nodes: [field('Without a password', guest), names.length ? el('div', { 'class': 'lab' }, ['People and groups', who]) : el('p', { 'class': 'hint', text: 'No people yet. Add them on the Users page to give single persons access.' }), tm.node],
		read: () => ({ guest: guest.value, rw: sels.filter((x) => x[1].value === 'rw').map((x) => x[0]), ro: sels.filter((x) => x[1].value === 'ro').map((x) => x[0]), tm: tm.box.checked }) };
}
function rShares() {
	const d = slow.shares && slow.shares.data, U = (slow.users && slow.users.data) || { users: [], groups: [] };
	if (!d) return;
	const v = d.volume, canNew = v.mounted && v.rw && v.gate;
	txt('sh-note', !v.mounted ? 'The data volume is not open, so nothing can be offered yet. What is set here is kept for when it is.' : !v.rw ? 'The volume is open read-only' + (S.trial ? ' for this trial' : '') + ': folders that are already there can be shared, to read. New folders and writing need it read-write.' : !v.gate ? 'Sharing folders that exist works now. Making a NEW folder writes to the array and needs the owner\'s read-write token on the box.' : '');
	fill($('sh-list'), d.shares.length ? d.shares.map((s) => {
		const nx = d.exports.filter((e) => e.share === s.name).length;
		const change = el('button', { 'class': 'btn small', type: 'button', text: 'Change' }), rm = el('button', { 'class': 'btn small', type: 'button', text: 'Remove' });
		change.setAttribute('aria-label', 'Change the share ' + s.name); rm.setAttribute('aria-label', 'Remove the share ' + s.name);
		change.addEventListener('click', () => { const f = shareForm(s, U); ask('Change ' + s.name, f.nodes, 'Save', () => act('share_set', Object.assign({ name: s.name }, f.read()), 'Share saved.')); });
		rm.addEventListener('click', () => ask('Stop offering ' + s.name + '?', [el('p', { text: 'The share goes away' + (nx ? ', and its ' + num(nx) + plural(nx, ' NFS export', ' NFS exports') + ' with it' : '') + '. The folder and every file in it stay on the disks, untouched.' })], 'Remove the share', () => act('share_remove', { name: s.name }, 'Share removed. Its folder stays.'), true));
		return el('li', {}, [el('div', {}, [el('div', { 'class': 'nm', text: s.name }), el('div', { 'class': 'ds' }, [el('span', { text: whoText(s) }), d.engine ? el('span', { 'class': 'badge', text: 'SMB' }) : null, nx ? el('span', { 'class': 'badge', text: 'NFS' }) : null, s.tm ? el('span', { 'class': 'badge acc', text: 'Time Machine' }) : null, s.exists ? null : el('span', { 'class': 'badge', text: v.mounted ? 'folder missing' : 'waiting for the volume' })])]), el('div', { 'class': 'ac' }, [change, rm])]);
	}) : [el('li', { 'class': 'empty', text: 'No folder is offered yet.' })]);
	$('sh-add').onclick = () => {
		const opts = d.folders.map((f) => [f, f + ' (already on the volume)']); if (canNew) opts.push(['', 'a new folder…']);
		if (!opts.length) return toast(v.mounted ? 'Every folder on the volume is already shared, and a new one cannot be made while it is read-only.' : 'The data volume is not open.', true);
		const pick = select(opts, opts[0][0]), name = input('text', '', { maxlength: 32, spellcheck: 'false' }), nl = field('Name of the new folder', name, 'Letters, digits, spaces, dots, dashes, underscores.'), f = shareForm({ guest: 'no', rw: [], ro: [], tm: false }, U);
		nl.hidden = pick.value !== ''; pick.addEventListener('change', () => { nl.hidden = pick.value !== ''; });
		ask('Add a share', [field('Folder', pick, 'A share is always a folder directly on the data volume, with the share\'s name.'), nl].concat(f.nodes), 'Add the share', () => act('share_add', Object.assign({ name: pick.value || name.value.trim() }, f.read()), 'Share added.'));
	};
	const sq = { root: 'root becomes nobody', all: 'everyone becomes nobody', none: 'root stays root' };
	const exForm = (e) => { const cl = input('text', e.clients, { 'class': 'mono', spellcheck: 'false', placeholder: '192.0.2.0/24' }), ac = select([['ro', 'may read'], ['rw', 'may read and change']], e.access), s2 = select([['root', 'root on the client becomes nobody (usual)'], ['all', 'every client user becomes nobody'], ['none', 'root on the client stays root (trusting)']], e.squash);
		return { nodes: [field('Machines that may mount it', cl, 'One address, a range like 192.0.2.0/24, or * for any machine that can reach this box.'), field('They', ac), field('Who they are here', s2)], read: () => ({ clients: cl.value.trim(), access: ac.value, squash: s2.value }) }; };
	fill($('ex-list'), d.exports.length ? d.exports.map((e) => {
		const change = el('button', { 'class': 'btn small', type: 'button', text: 'Change', 'aria-label': 'Change the export of ' + e.share + ' to ' + e.clients }), rm = el('button', { 'class': 'btn small', type: 'button', text: 'Remove', 'aria-label': 'Remove the export of ' + e.share + ' to ' + e.clients });
		change.addEventListener('click', () => { const f = exForm(e); ask('Change the export of ' + e.share, f.nodes, 'Save', () => act('export_set', Object.assign({ id: e.id }, f.read()), 'Export saved.')); });
		rm.addEventListener('click', () => ask('Remove this export?', [el('p', { text: e.share + ' will no longer be mountable over NFS from ' + e.clients + '. The share itself and its files stay.' })], 'Remove the export', () => act('export_remove', { id: e.id }, 'Export removed.'), true));
		return el('li', {}, [el('div', {}, [el('div', { 'class': 'nm', text: e.share }), el('div', { 'class': 'ds' }, [el('span', { text: 'to ' + (e.clients === '*' ? 'any machine' : e.clients) + ' · ' + (e.access === 'rw' && v.rw ? 'read and change' : 'read only') + ' · ' + sq[e.squash] })])]), el('div', { 'class': 'ac' }, [change, rm])]);
	}) : [el('li', { 'class': 'empty', text: d.nfs ? 'Nothing is exported over NFS.' : 'Nothing is exported. This image has no NFS server; exports set here wait for one.' })]);
	$('ex-add').onclick = () => {
		if (!d.shares.length) return toast('Add a share first; an export offers a share over NFS.', true);
		const sh = select(d.shares.map((s) => [s.name, s.name]), d.shares[0].name), f = exForm({ clients: '', access: 'ro', squash: 'root' });
		ask('Add an NFS export', [field('Share', sh)].concat(f.nodes), 'Add the export', () => act('export_add', Object.assign({ share: sh.value }, f.read()), 'Export added.'));
	};
}

/* ---------- users, groups, the administrator ---------- */
function twoPass(min) {
	const p1 = input('password', '', { autocomplete: 'new-password' }), p2 = input('password', '', { autocomplete: 'new-password' });
	return { nodes: [el('div', { 'class': 'two' }, [field('Password', p1), field('Once more', p2)]), el('p', { 'class': 'hint', text: num(min).replace(/^./, (c) => c.toUpperCase()) + ' characters or more.' })],
		bad: () => (p1.value.length < min ? 'The password needs ' + min + ' characters or more.' : p1.value !== p2.value ? 'The two passwords are not the same.' : null), value: () => p1.value };
}
function rUsers() {
	const d = slow.users && slow.users.data;
	if (!d) return;
	txt('adm-name', d.admin || '');
	fill($('us-list'), d.users.length ? d.users.map((u) => {
		const gs = d.groups.filter((g) => g.members.indexOf(u.name) >= 0), pw = el('button', { 'class': 'btn small', type: 'button', text: 'Password', 'aria-label': 'Change the password of ' + u.name }), rm = el('button', { 'class': 'btn small', type: 'button', text: 'Remove', 'aria-label': 'Remove ' + u.name });
		pw.addEventListener('click', () => { const t = twoPass(8); ask('A new password for ' + u.name, t.nodes, 'Set the password', () => t.bad() || act('user_passwd', { name: u.name, password: t.value() }, 'Password set.')); });
		rm.addEventListener('click', () => ask('Remove ' + u.name + '?', [el('p', { text: u.name + ' will no longer open any share. Files ' + u.name + ' made stay where they are.' })], 'Remove', () => act('user_remove', { name: u.name }, 'Removed.'), true));
		return el('li', {}, [el('div', {}, [el('div', { 'class': 'nm', text: u.name }), el('div', { 'class': 'ds' }, gs.length ? gs.map((g) => el('span', { 'class': 'badge', text: g.name })) : [el('span', { text: 'in no group' })])]), el('div', { 'class': 'ac' }, [pw, rm])]);
	}) : [el('li', { 'class': 'empty', text: 'Nobody yet. Shares open to everyone need no people.' })]);
	$('us-add').onclick = () => { const n = input('text', '', { maxlength: 31, autocapitalize: 'none', spellcheck: 'false', autocomplete: 'off' }), t = twoPass(8);
		ask('Add a person', [field('Name', n, 'Lower-case letters, digits, dashes, underscores; starts with a letter.')].concat(t.nodes), 'Add', () => t.bad() || act('user_add', { name: n.value.trim(), password: t.value() }, 'Person added.')); };
	const members = (cur) => { const cs = d.users.map((u) => [u.name, check(u.name, cur.indexOf(u.name) >= 0)]); return { node: d.users.length ? el('div', { 'class': 'checks' }, cs.map((c) => c[1].node)) : el('p', { 'class': 'hint', text: 'There are no people to put in it yet.' }), read: () => cs.filter((c) => c[1].box.checked).map((c) => c[0]) }; };
	fill($('gr-list'), d.groups.length ? d.groups.map((g) => {
		const ed = el('button', { 'class': 'btn small', type: 'button', text: 'Members', 'aria-label': 'Change the members of ' + g.name }), rm = el('button', { 'class': 'btn small', type: 'button', text: 'Remove', 'aria-label': 'Remove the group ' + g.name });
		ed.addEventListener('click', () => { const m = members(g.members); ask('Who is in ' + g.name + '?', [m.node], 'Save', () => act('group_set', { name: g.name, members: m.read() }, 'Group saved.')); });
		rm.addEventListener('click', () => ask('Remove the group ' + g.name + '?', [el('p', { text: 'Its people stay; shares that named the group no longer do.' })], 'Remove', () => act('group_remove', { name: g.name }, 'Group removed.'), true));
		return el('li', {}, [el('div', {}, [el('div', { 'class': 'nm', text: g.name }), el('div', { 'class': 'ds' }, [el('span', { text: g.members.length ? g.members.join(', ') : 'empty' })])]), el('div', { 'class': 'ac' }, [ed, rm])]);
	}) : [el('li', { 'class': 'empty', text: 'No groups. A group lets a share name several people at once.' })]);
	$('gr-add').onclick = () => { const n = input('text', '', { maxlength: 31, autocapitalize: 'none', spellcheck: 'false' }), m = members([]);
		ask('Add a group', [field('Name', n, 'Lower-case letters, digits, dashes, underscores.'), el('div', { 'class': 'lab' }, ['Members', m.node])], 'Add', () => act('group_add', { name: n.value.trim(), members: m.read() }, 'Group added.')); };
}
$('adm-pass').addEventListener('click', () => {
	const old = input('password', '', { autocomplete: 'current-password' }), t = twoPass(12);
	ask('Change the administrator\'s password', [field('Current password', old)].concat(t.nodes), 'Change it', async () => {
		if (t.bad()) return t.bad();
		const h = hashNew(t.value()); if (!h) return 'This browser got a test of its own arithmetic wrong, so it must not make a password. Use another browser.';
		const r = await call('keeper_passwd', { old: old.value, hash: h });
		return r && r.ok ? (toast('Password changed.'), null) : (r && r.wait_s ? 'Not right. Wait ' + r.wait_s + ' s before the next try.' : (r && r.msg) || 'The box refused that.');
	});
});
$('adm-out').addEventListener('click', () => ask('Sign out everywhere?', [el('p', { text: 'Every browser signed in to this box, this one included, has to sign in again.' })], 'Sign out everywhere', async () => { const r = await call('signout_all'); if (r && r.ok) { $('dlg').close(); toDoor('Signed out everywhere.'); } return r && r.ok ? null : 'The box refused that.'; }, true));

/* ---------- services ---------- */
function rServices() {
	const d = slow.services && slow.services.data;
	if (!d) return;
	fill($('sv-list'), d.list.map((s) => {
		const w = SVC[s.id] || [s.id, ''], c = el('input', { type: 'checkbox', 'aria-label': w[0] }), lock = s.id === 'ssh' && d.trial && s.enabled;
		c.checked = s.enabled; c.disabled = !s.present || lock;
		c.addEventListener('change', async () => { c.disabled = true; let e; try { e = await act('service_set', { id: s.id, enabled: c.checked }, w[0] + (c.checked ? ' is on.' : ' is off.')); } catch (x) { e = 'The box did not answer.'; } if (e) { toast(e, true); c.checked = !c.checked; c.disabled = false; } poll(true); });
		const st = !s.present ? 'Not in this image' : s.running === true ? 'Running' + (s.rss_kb ? ' · holds ' + size(s.rss_kb) : '') : s.running === false ? (s.enabled ? 'On, not running' : 'Stopped') : s.enabled ? 'On' : 'Off';
		return el('div', { 'class': 'svc' }, [el('div', {}, [el('div', { 'class': 'nm b6', text: w[0] }), el('div', { 'class': 'hint', text: w[1] + (lock ? ' Stays on during a trial: it is how the trial is watched.' : '') })]), el('span', { 'class': 'st', text: st }), el('span', { 'class': 'switch' }, [c, el('i')])]);
	}));
}

/* ---------- alerts ---------- */
const EVS = [['disk', 'A disk reports trouble'], ['raid', 'The array changes state'], ['temp', 'The box runs hot'], ['space', 'Space runs low']];
const evBoxes = EVS.map((e) => { const c = check(e[1], false); $('al-ev').appendChild(c.node); return [e[0], c.box]; });
function rAlerts() {
	const d = slow.alerts && slow.alerts.data;
	if (!d || dirty.alerts) return;
	$('al-on').checked = d.enabled; $('al-to').value = d.to; $('al-from').value = d.from; $('al-host').value = d.host; $('al-port').value = d.port; $('al-tls').value = d.tls; $('al-user').value = d.user; $('al-pct').value = d.space_pct; $('al-pass').value = '';
	evBoxes.forEach((b) => { b[1].checked = d.events.indexOf(b[0]) >= 0; });
	txt('al-h-pass', d.has_pass ? 'A password is stored. Leave this empty to keep it. It is never shown and never sent back to a browser.' : 'Stored on the box in a file only it can read. For Gmail and the like, an app password.');
	txt('al-last', !d.sender ? 'This image has no mail program (msmtp), so nothing can be sent yet; the settings are kept.' : d.last ? 'Last message: ' + (d.last.ok ? 'taken by the mail server' : 'REFUSED by the mail server') + ', ' + when(d.last.t) + '.' : 'No message has been sent yet.');
}
$('al-form').addEventListener('input', () => { dirty.alerts = 1; });
$('al-form').addEventListener('submit', async (e) => {
	e.preventDefault();
	const a = { enabled: $('al-on').checked, tls: $('al-tls').value, events: evBoxes.filter((b) => b[1].checked).map((b) => b[0]) };
	[['to', 'al-to'], ['from', 'al-from'], ['host', 'al-host'], ['user', 'al-user']].forEach((f) => { const v = $(f[1]).value.trim(); if (v || f[0] === 'user') a[f[0]] = v; });
	if ($('al-port').value) a.port = +$('al-port').value; if ($('al-pct').value) a.space_pct = +$('al-pct').value; if ($('al-pass').value) a.password = $('al-pass').value;
	let err; try { err = await act('alerts_set', a, 'Alerts saved.'); } catch (x) { err = x === DENIED ? (toDoor('Signed out. Sign in again to go on.'), '') : 'The box did not answer.'; }
	txt('al-err', err || ''); if (!err) { dirty.alerts = 0; delete slow.alerts; poll(true); }
});
$('al-test').addEventListener('click', async () => { if (dirty.alerts) return txt('al-err', 'Save first, then test what was saved.'); let e; try { e = await act('alerts_test', {}, 'The mail server took the test message.'); } catch (x) { e = 'The box did not answer.'; } txt('al-err', e || ''); if (!e) toast('Sending a test message…'); poll(true); });

/* ---------- front panel ---------- */
const SENT = { name: 'Name', ip1: 'Address, port 1', ip2: 'Address, port 2', fw: 'Version', health: 'Drives', free: 'Free space', used: 'Used, percent', vol: 'Volume', fan: 'Fan', temp: 'Temperatures', usb: 'USB disk', lcd: 'Screen', standby: 'Sleeps after' };
function rPanel() {
	const d = slow.panel && slow.panel.data;
	if (!d) return;
	const ks = Object.keys(d.sent);
	fill($('pn-sent'), ks.length ? ks.map((k) => el('div', {}, [el('span', { text: SENT[k] || k }), el('b', { text: d.sent[k] })])) : [el('div', {}, [el('span', { text: !d.daemon ? 'The panel program is not running.' : d.on ? 'Switched on. The panel program has not sent the fields yet.' : 'The screen is being sent nothing.' })])]);
	txt('pn-age', ks.length ? 'The screen turns its own pages; this page cannot see which one is up.' : 'Switch “Feed the screen” on to show this system\'s numbers on it.');
	$('f-feed').checked = d.on; $('f-on').checked = d.lcd; $('f-bl').value = d.standby;
	txt('pn-note', 'The screen shows WD\'s own pages, fed with this system\'s numbers; its first line is the box\'s name (set under System). Whether “Screen on” means on, or never sleep, to the screen\'s own chip is settled by one look at the glass. Pages of our own, a live mirror here, the lights and “find this box” come once their hardware steps are proven on the bench.');
}
let pnT;
async function panelSet(a) { let e; try { const r = await call('panel_set', a); e = r && r.ok ? null : (r && r.msg) || 'The box refused that.'; } catch (x) { e = 'The box did not answer.'; } txt('pn-saved', e || 'Saved.'); clearTimeout(pnT); pnT = setTimeout(() => txt('pn-saved', ''), 3000); }
$('f-feed').addEventListener('change', (e) => panelSet({ on: e.target.checked }).then(() => poll(true)));
$('f-on').addEventListener('change', (e) => panelSet({ lcd: e.target.checked }));
$('f-bl').addEventListener('change', (e) => panelSet({ standby: e.target.value }));

/* ---------- system ---------- */
function rSystem() {
	const d = slow.system && slow.system.data;
	if (!d) return;
	const n = d.net;
	if (!dirty.sys) { $('sy-name').value = d.name; fill($('sy-zone'), d.zones.map((z) => el('option', { value: z, text: z.replace(/_/g, ' ') }))); $('sy-zone').value = d.zonename; }
	txt('sy-time', 'The box\'s clock reads ' + new Date(d.now * 1000).toUTCString().replace('GMT', 'UTC') + '.');
	if (!dirty.net) { $('net-mode').value = n.mode; $('net-addr').value = n.addr; $('net-mask').value = n.mask; $('net-gw').value = n.gw; $('net-dns').value = n.dns.join(' '); $('net-bond').value = n.bond; $('net-static').hidden = n.mode !== 'static'; }
	fill($('sy-live'), [el('span', { text: 'now ' + (n.live || location.hostname) })]);
	kvs('net-ports', n.ports.map((p, i) => ['Port ' + (i + 1), p.up ? 'connected' + (p.speed ? ', ' + (p.speed >= 1000 ? p.speed / 1000 + ' Gb/s' : p.speed + ' Mb/s') : '') : 'no cable']));
	const c = d.cert;
	kvs('cert-kv', c ? [['Fingerprint (SHA-256) begins', fp4(c.fp)], ['In full', c.fp], ['Made for', c.names.join(', ')], ['Made', when(c.made) + ', good for ' + Math.max(0, Math.round(c.days - (d.now - c.made) / 86400)) + ' days']] : [['Certificate', 'none made yet']]);
	txt('pow-note', d.trial ? 'This is a trial boot from memory. Restart returns the box to WD\'s firmware; nothing was installed. Shut down halts it; the fan stays at full speed until you switch the box off.' : 'Both stop sharing, flush, unmount the volume and stop the array first. After Shut down the fan stays at full speed until you switch the box off at its button.');
	kvs('about-kv', [['System', 'OpenWrt ' + (d.version.openwrt || '?')], ['Kernel', 'Linux ' + d.version.kernel], ['Interface', d.version.ui], ['Up for', dur(d.up)], ['Administrator', d.admin || '?']]);
	const u = d.update || {};
	const SIG = { good: 'good (key ' + (u.key || '?') + ')', bad: 'NOT GOOD: refused', none: 'none: refused' };
	const WHY = { expired: 'the release it found EXPIRED' + (u.expires ? ' on ' + u.expires.replace('T', ' ').replace('Z', ' UTC') : '') + '. Its signature is good, but it no longer vouches that it is the newest: the release address may be stale, or something is holding newer releases back. Ask for a fresh release.',
		clock: 'this box\'s clock is set before the release was built, so its expiry cannot be judged. Set the clock first.', downgrade: 'it is OLDER than what runs (a downgrade is never accepted)',
		badsig: 'its signature is not good, or is by a key this box does not hold', unsigned: 'it carries no signature', board: 'it is for another board', channel: 'it is for another channel' };
	const RES = { newer: 'a newer release is out: ' + (u.latest || '?'), current: 'this is the newest release', verified: 'newer release ' + (u.latest || '?') + ' checked, nothing kept',
		staged: 'release ' + (u.latest || '?') + ' checked and staged in memory (not installed)', refused: 'refused: ' + (WHY[u.why] || u.why || '?'), unreachable: 'the release address did not answer' };
	const stale = u.checked && d.now - u.checked > 30 * 86400;
	kvs('upd-kv', [['Running', (u.running || 'unknown') + (u.serial ? ' (serial ' + u.serial + ', ' + (u.channel || '?') + ')' : '')],
		['Signing keys held', u.keys ? String(u.keys) : 'none: every release would be refused'],
		['Last check', u.checked ? when(u.checked) + (u.from ? ', ' + u.from : '') : 'never'],
		u.checked ? ['Found', RES[u.result] || u.result || '?'] : null,
		u.checked ? ['Signature', SIG[u.sig] || u.sig || '?'] : null,
		u.checked && u.expires && u.result !== 'refused' ? ['Release good until', u.expires.replace('T', ' ').replace('Z', ' UTC')] : null,
		u.successor ? ['Key rotation', 'the release named key ' + u.successor + ' as the next signing key'] : null,
		stale ? ['Note', 'the last check is more than a month old: run “ex4-update check” over ssh'] : null]);
}
$('sy-form').addEventListener('input', () => { dirty.sys = 1; });
$('sy-form').addEventListener('submit', async (e) => { e.preventDefault(); let err; try { err = await act('system_set', { hostname: $('sy-name').value.trim(), zonename: $('sy-zone').value }, 'Saved. A new name wants a new certificate.'); } catch (x) { err = 'The box did not answer.'; } txt('sy-err', err || ''); if (!err) { dirty.sys = 0; poll(true); } });
$('net-form').addEventListener('input', () => { dirty.net = 1; $('net-static').hidden = $('net-mode').value !== 'static'; });
$('net-form').addEventListener('submit', async (e) => {
	e.preventDefault();
	const a = { mode: $('net-mode').value, bond: $('net-bond').value };
	if (a.mode === 'static') { a.addr = $('net-addr').value.trim(); a.mask = $('net-mask').value.trim(); a.gw = $('net-gw').value.trim(); a.dns = $('net-dns').value.split(/[\s,]+/).filter(Boolean); }
	let err; try { err = await act('net_set', a, 'The new settings are on trial.'); } catch (x) { err = 'The box did not answer.'; }
	txt('net-err', err || ''); if (!err) { dirty.net = 0; poll(true); }
});
$('cert-new').addEventListener('click', () => ask('Make a new certificate?', [el('p', { text: 'The box makes a fresh certificate with its current name and restarts its web server. This page will stop for a few seconds, and your browser will warn you once more: compare the fingerprint it shows with the one on this page afterwards.' })], 'Make it', async () => { const e = await act('cert_renew', {}, 'A new certificate is in place.'); if (!e) setTimeout(() => location.reload(), 6000); return e; }));
const power = (m, title, text, label) => ask(title, [el('p', { text })], label, () => act(m, {}, label + ' is under way.'), true);
$('pow-restart').addEventListener('click', () => power('restart', 'Restart the box?', S.trial ? 'This is a trial: a restart goes back to WD\'s firmware. Sharing stops, the volume is unmounted and the array stopped first.' : 'Sharing stops, the volume is unmounted and the array stopped, then the box restarts. It is back in about a minute.', 'Restart'));
$('pow-off').addEventListener('click', () => power('shutdown', 'Shut the box down?', 'Sharing stops, the volume is unmounted and the array stopped, then the system halts. The fan keeps turning at full speed until you switch the box off at its button; to start it again, press that button.', 'Shut down'));
$('bun-make').addEventListener('click', async () => {
	const b = $('bun-make'); b.disabled = true;
	try {
		const r = await call('support_bundle'); if (!r || !r.ok) throw 0;
		for (let i = 0; i < 60; i++) { await new Promise((ok) => setTimeout(ok, 700)); const j = ((await call('status')).jobs || []).find((x) => x.id === r.job); if (j && j.state !== 'run' && j.state !== 'wait') break; }
		const t = await call('bundle_get'); if (!t || !t.ok) throw 0;
		const a = el('a', { href: URL.createObjectURL(new Blob([t.text], { type: 'text/plain' })), download: S.name + '-support-bundle.txt' }); D.body.appendChild(a); a.click(); a.remove();
		toast('Bundle saved by your browser.');
	} catch (x) { toast('The bundle could not be made.', true); }
	b.disabled = false;
});

/* ---------- strips: the trial clock, an address on trial, a box that stopped answering ---------- */
function rStrips() {
	const t = S.trial;
	$('trial').hidden = !t;
	if (t) { fill($('trial-t'), t.stay ? [el('strong', { text: 'Trial boot, staying. ' }), 'Restart, or pull the plug, to go back to WD\'s firmware. Nothing is installed.'] : [el('strong', { text: 'Trial boot. ' }), 'Nothing is installed. This box returns to WD\'s firmware in ', el('strong', { text: mmss(t.left_s) }), '.']); $('stay').hidden = t.stay; }
	$('netp').hidden = S.net_pending == null;
	if (S.net_pending != null) fill($('netp-t'), [el('strong', { text: 'New network settings are on trial. ' }), 'Keep them within ' + mmss(S.net_pending) + ', or the old ones come back by themselves.']);
	txt('mk-name', S.name); txt('mk-addr', S.addr || location.hostname);
}
$('stay').addEventListener('click', async () => { try { const e = await act('trial_stay'); if (e) toast(e, true); poll(true); } catch (x) { } });
$('netp-keep').addEventListener('click', async () => { try { const e = await act('net_confirm'); toast(e || 'Kept.', !!e); poll(true); } catch (x) { } });

/* ---------- the loop: one status poll in flight, slow parts only when their counter moved ---------- */
let timer = null, inflight = false, slowBy = 1;
const RENDER = { overview: rOverview, storage: rStorage, shares: rShares, users: rUsers, services: rServices, alerts: rAlerts, panel: rPanel, system: rSystem, more: () => { } };
function render() { if (!S) return; rStrips(); if (page !== 'overview') D.title = S.name + ' · ' + TITLES[page]; RENDER[page](); }
async function poll(now) {
	clearTimeout(timer);
	if (!inApp || D.hidden) return;
	if (inflight) { if (now) timer = setTimeout(() => poll(true), 150); return; }
	inflight = true;
	const t0 = performance.now();
	try {
		const first = PARTS[page].filter((p) => !slow[p]), res = await rpc([['status']].concat(first.map((p) => [p])));
		const st = res[0]; if (!st) throw new Error('no status');
		S = st; first.forEach((p, i) => { if (res[i + 1]) slow[p] = { rev: st.rev[REVOF[p]], data: res[i + 1] }; });
		if (!samples.length || st.now > samples[samples.length - 1].t) samples.push({ t: st.now, rx: mib(st.net.rx), tx: mib(st.net.tx) });
		while (samples.length && samples[0].t < st.now - WIN - 10) samples.shift();
		const moved = PARTS[page].filter((p) => slow[p] && slow[p].rev !== st.rev[REVOF[p]]).concat(page === 'services' && first.indexOf('services') < 0 ? ['services'] : []);
		if (moved.length) { const r2 = await rpc(moved.map((p) => [p])); moved.forEach((p, i) => { if (r2[i]) slow[p] = { rev: st.rev[REVOF[p]], data: r2[i] }; }); }
		(st.jobs || []).forEach((j) => { if (watched[j.id] && (j.state === 'ok' || j.state === 'fail')) { toast(j.state === 'ok' ? watched[j.id] : 'That did not work: ' + (j.msg || 'the helper failed') + '.', j.state !== 'ok'); delete watched[j.id]; } });
		$('lost').hidden = true; $('dot').className = 'dot'; txt('heard', 'Live');
		render();
		slowBy = performance.now() - t0 > 500 ? Math.min(5, slowBy * 2) : 1;      // a slow box slows the asking, never the reverse
	} catch (e) {
		if (e === DENIED) { inflight = false; return toDoor('Signed out after a while away. Sign in again.'); }
		$('lost').hidden = false; txt('lost-t', 'The box is not answering. Trying again; what you see is the last it said.'); $('dot').className = 'dot stale'; txt('heard', 'Not reached');
		slowBy = Math.min(5, slowBy * 2);
	}
	inflight = false;
	timer = setTimeout(poll, Object.keys(watched).length ? 500 : (page === 'overview' ? 2000 : 5000) * slowBy);      // a job somebody is waiting for is looked at sooner
}
D.addEventListener('visibilitychange', () => { if (!D.hidden) poll(true); else clearTimeout(timer); });   // a hidden tab asks for nothing

/* ---------- pages ---------- */
function route(first) {
	let k = (location.hash || '#overview').slice(1); if (!RENDER[k]) k = 'overview';
	page = k;
	D.querySelectorAll('.view').forEach((v) => { v.hidden = v.id !== 'v-' + k; });
	D.querySelectorAll('.nav a').forEach((a) => { const h = a.getAttribute('href').slice(1); if (h === k || (h === 'more' && ['users', 'services', 'alerts', 'panel', 'system'].indexOf(k) >= 0 && window.matchMedia('(max-width:860px)').matches)) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current'); });
	if (!first) { $('main').focus({ preventScroll: true }); window.scrollTo(0, 0); }
	render(); poll(true);
}
window.addEventListener('hashchange', () => { if (inApp) route(false); });
D.querySelector('.skip').addEventListener('click', (e) => { e.preventDefault(); (inApp ? $('main') : D.querySelector('.door main:not([hidden])')).focus(); });

/* ---------- theme ---------- */
const root = D.documentElement, isDark = () => { const t = root.getAttribute('data-theme'); return t ? t === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches; };
try { const t = localStorage.getItem('ex4-theme'); if (t === 'dark' || t === 'light') root.setAttribute('data-theme', t); } catch (e) { }
const themeLabel = () => txt('theme-l', isDark() ? 'Light' : 'Dark'); themeLabel();
$('theme').addEventListener('click', () => { const t = isDark() ? 'light' : 'dark'; root.setAttribute('data-theme', t); try { localStorage.setItem('ex4-theme', t); } catch (e) { } themeLabel(); });

/* ---------- the two doors ---------- */
const plain = location.protocol === 'http:' && !/^(localhost|127\.0\.0\.1|\[::1\])$/.test(location.hostname);
function show(which) { inApp = which === 'app'; $('app').hidden = !inApp; $('door').hidden = inApp; $('door-in').hidden = which !== 'in'; $('door-setup').hidden = which !== 'setup'; clearTimeout(timer); }
function certFoot(id) { fill($(id), setup && setup.cert_fp ? ['This box\'s certificate begins ', el('span', { 'class': 'fp', text: fp4(setup.cert_fp) }), '. Your browser showed a fingerprint when it warned you; the two should match.'] : []); }
function toDoor(msg) {
	setSid(null); S = null; for (const k in slow) delete slow[k];
	if ($('dlg').open) $('dlg').close();
	show('in'); D.title = (setup ? setup.name : 'ex4') + ' · sign in';
	txt('in-name', setup ? setup.name : 'ex4'); txt('in-host', location.host); txt('in-err', plain ? 'This page was opened without encryption. Open it as https:// to sign in.' : msg || ''); certFoot('in-foot');
	$('in-go').disabled = plain; $('in-pass').value = ''; ($('in-user').value ? $('in-pass') : $('in-user')).focus();
}
let waitT;
function holdOff(btn, errId, s, msg) { clearInterval(waitT); let left = s; btn.disabled = true; const tick = () => { txt(errId, msg + ' Wait ' + left + ' s.'); if (left-- <= 0) { clearInterval(waitT); btn.disabled = false; txt(errId, ''); } }; tick(); waitT = setInterval(tick, 1000); }
$('in-form').addEventListener('submit', async (e) => {
	e.preventDefault();
	const b = $('in-go'); if (b.disabled) return; b.disabled = true;
	try {
		const r = await call('sign_in', { username: $('in-user').value.trim(), password: $('in-pass').value }, Z);
		if (r && r.ok) { setSid(r.sid); $('in-pass').value = ''; b.disabled = false; return enter(); }
		if (r && r.wait_s) holdOff(b, 'in-err', r.wait_s, r.err === 'bad' || r.msg ? 'Name or password not right.' : 'Too many tries.'); else { txt('in-err', (r && r.msg) || 'Name or password not right.'); b.disabled = false; }
	} catch (x) { txt('in-err', 'The box did not answer.'); b.disabled = false; }
});
async function signOut() { try { await rpc([['destroy', {}, 'session']]); } catch (e) { } toDoor('Signed out.'); }
$('signout').addEventListener('click', signOut); $('signout2').addEventListener('click', signOut);
function toSetup() {
	show('setup'); D.title = 'A new box · make it yours';
	txt('su-host', location.host); $('su-name').value = setup.name; txt('su-local', setup.name + '.local'); certFoot('su-foot');
	if (plain) { txt('su-err', 'This page was opened without encryption. Open it as https:// to set a password.'); $('su-go').disabled = true; }
	$('su-code').focus();
}
$('su-name').addEventListener('input', (e) => txt('su-local', (e.target.value || 'ex4') + '.local'));
$('su-form').addEventListener('submit', async (e) => {
	e.preventDefault();
	const b = $('su-go'); if (b.disabled) return;
	const code = $('su-code').value.trim(), name = $('su-name').value.trim(), user = $('su-user').value.trim(), p1 = $('su-p1').value, bad = (id, m) => { $(id).setAttribute('aria-invalid', 'true'); $(id).focus(); txt('su-err', m); };
	['su-code', 'su-name', 'su-user', 'su-p1', 'su-p2'].forEach((i) => $(i).removeAttribute('aria-invalid'));
	if (!/^\d{8}$/.test(code)) return bad('su-code', 'The code is eight digits.');
	if (!/^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$/.test(name)) return bad('su-name', 'The name is lower-case letters, digits and dashes, with no dash at either end.');
	if (!/^[a-z][a-z0-9_-]{0,30}$/.test(user) || user === 'root') return bad('su-user', 'The administrator\'s name is lower-case letters, digits, dashes or underscores, starts with a letter, and is not root.');
	if (p1.length < 12) return bad('su-p1', 'The password needs twelve characters or more.');
	if (p1 !== $('su-p2').value) return bad('su-p2', 'The two passwords are not the same.');
	b.disabled = true; txt('su-err', '');
	try {
		const hash = hashNew(p1);
		if (!hash) { txt('su-err', 'This browser got a test of its own arithmetic wrong, so it must not make a password. Use another browser.'); b.disabled = false; return; }
		const r = await call('setup_claim', { code, username: user, hash, hostname: name }, Z);
		if (r && r.ok) { const s = await call('sign_in', { username: user, password: p1 }, Z); setup.claimed = true; setup.name = name; $('su-p1').value = $('su-p2').value = ''; if (s && s.ok) { setSid(s.sid); return enter(); } $('in-user').value = user; return toDoor('The box is yours. Sign in.'); }
		if (r && r.err === 'wait') holdOff(b, 'su-err', r.wait_s, r.msg || 'Too many wrong codes.'); else { txt('su-err', (r && r.msg) || 'The box refused that.'); b.disabled = false; if (r && r.err === 'bad_code') { $('su-code').setAttribute('aria-invalid', 'true'); $('su-code').focus(); } }
	} catch (x) { txt('su-err', 'The box did not answer.'); b.disabled = false; }
});
function enter(st) {
	show('app'); S = st || null;
	const v = (setup && setup.ver) || {};
	txt('ver', 'OpenWrt ' + (v.openwrt || '') + ' · Linux ' + String(v.kernel || '').split('.').slice(0, 2).join('.') + (setup && setup.trial ? '\nrunning from memory' : ''));
	route(true);
}
(async function boot() {                           // one request: is the box claimed, and is the session this tab holds still good
	let st = null;
	try {
		const body = [{ jsonrpc: '2.0', id: 1, method: 'call', params: [Z, 'ex4', 'setup_state', {}] }, { jsonrpc: '2.0', id: 2, method: 'call', params: [sid, 'ex4', 'status', {}] }];
		const j = await (await fetch('/ubus', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(sid === Z ? body.slice(0, 1) : body), cache: 'no-store', credentials: 'omit' })).json();
		setup = j[0].result && j[0].result[0] === 0 ? j[0].result[1] : null;
		st = j[1] && j[1].result && j[1].result[0] === 0 ? j[1].result[1] : null;
	} catch (e) { setup = null; }
	if (!setup) { show('in'); txt('in-err', 'The box did not answer. Reload this page to try again.'); $('in-go').disabled = true; return; }
	if (!setup.claimed) return toSetup();
	if (st) return enter(st);
	toDoor('');
})();
})();
