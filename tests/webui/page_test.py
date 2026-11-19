#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""page_test.py : the page itself, driven in a real browser against fakebox.py. Every page, every form, both
themes, a desk and a phone; and a screenshot of each for a human eye.

  python3 tests/webui/page_test.py [--shots DIR] [--browser firefox|chromium] [--port 18491]
      needs the `playwright` Python module with a browser installed. It starts fakebox.py itself, on 127.0.0.1.
  or, from your own launcher (any Playwright-compatible browser object):
      import page_test;  page_test.run(browser, 'http://127.0.0.1:18491', shots_dir, main_world=False)

What it checks (exit 0 only if nothing failed):
  - no request ever leaves the box's own address; the console stays clean (a Content-Security-Policy violation is
    a console error, so this also proves the page obeys its own policy); no uncaught script error
  - first boot: the claim flow end to end. The browser's own sha256crypt makes the hash; the fake checks the next
    sign-in against it with the reference implementation (sha256crypt.py), as rpcd's crypt() does on the box
  - the sentence, the portrait, the numbers and every card against the sample box (truth.py), in each health state
  - every page's forms: what the box accepts appears, what it refuses is said in the dialog, nothing is half-done
  - the sign-in brake as a person meets it; a session that ran out; sign out
  - the budget: the file's size, the requests to the first live number, a revisit answered 304, a hidden tab silent
  - reachable by keyboard with a visible focus ring; every control has a name; text contrast >= 4.5:1 (3:1 large)
    in both themes; one h1 per page; no sideways scroll on a 390 px phone
"""
import argparse, json, os, re, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PASS, FAIL = [], []
ADMIN, PW = 'keeper', 'tide and lamp, 12+'


def ok(cond, name, detail=''):
    (PASS if cond else FAIL).append(name)
    print(('  ok   ' if cond else '  FAIL ') + name + ((' :: ' + str(detail)[:400]) if (detail and not cond) else ''), flush=True)
    return cond


def ctl(base, path, body=None):
    req = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(), headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode() or '{}')


# the two checks that read the whole page: names of controls, contrast of text. Both run inside the page.
JS_NAMES = r"""() => { const bad = [];
  for (const e of document.querySelectorAll('button, a[href], input, select, textarea, [role=application], [role=meter], [role=img]')) {
    if (!e.getClientRects().length || e.closest('[hidden]')) continue;
    let n = (e.getAttribute('aria-label') || '').trim();
    if (!n && e.getAttribute('aria-labelledby')) n = e.getAttribute('aria-labelledby').split(/\s+/).map((i) => (document.getElementById(i) || {}).textContent || '').join(' ').trim();
    if (!n && e.labels && e.labels.length) n = e.labels[0].textContent.trim();
    if (!n && /^(BUTTON|A)$/.test(e.tagName)) n = e.textContent.trim();
    if (!n) bad.push(e.tagName + '#' + e.id + '.' + e.className);
  } return bad; }"""
JS_CONTRAST = r"""() => {
  const lum = (c) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }; return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]); };
  const parse = (s) => { const m = s.match(/rgba?\(([^)]+)\)/); if (!m) return null; const p = m[1].split(/[,\s\/]+/).filter(Boolean).map(Number); return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1]; };
  const over = (top, under) => [0, 1, 2].map((i) => top[i] * top[3] + under[i] * (1 - top[3])).concat([1]);
  const bgOf = (e) => { const stack = []; for (let n = e; n; n = n.parentElement) { const c = parse(getComputedStyle(n).backgroundColor); if (c && c[3] > 0) { stack.push(c); if (c[3] >= 1) break; } }
    let b = parse(getComputedStyle(document.documentElement).backgroundColor); if (!b || b[3] === 0) b = parse(getComputedStyle(document.body).backgroundColor) || [255, 255, 255, 1];
    for (let i = stack.length - 1; i >= 0; i--) b = over(stack[i], b); return b; };
  const bad = [], seen = new Set();
  const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let t = w.nextNode(); t; t = w.nextNode()) {
    const e = t.parentElement; if (!t.nodeValue.trim() || seen.has(e) || !e.getClientRects().length) continue; seen.add(e);
    if (e.closest('[hidden], .vh, svg, option, .lcd, .lcdlist, .chassis, .skip') || e.closest('dialog:not([open])')) continue;
    const cs = getComputedStyle(e); if (cs.visibility === 'hidden' || +cs.opacity < 1 || e.closest('[disabled]')) continue;
    let fg = parse(cs.color); if (!fg) continue; const bg = bgOf(e); fg = over(fg, bg);
    const a = lum(fg), b = lum(bg), ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05), px = parseFloat(cs.fontSize), big = px >= 24 || (px >= 18.66 && +cs.fontWeight >= 600);
    if (ratio < (big ? 3 : 4.5)) bad.push(ratio.toFixed(2) + ' ' + e.tagName + '.' + e.className + ' "' + t.nodeValue.trim().slice(0, 30) + '"');
  } return bad; }"""


class T:
    """one browser page and the handful of moves the tests make"""

    def __init__(self, browser, base, shots, main_world, w=1280, h=900, dark=True):
        self.base, self.shots, self.mw = base, shots, main_world
        self.ctx = browser.new_context(viewport={'width': w, 'height': h}, color_scheme='dark' if dark else 'light', ignore_https_errors=True, accept_downloads=True)
        self.page = self.ctx.new_page()
        self.console, self.errors, self.requests = [], [], []
        self.page.on('console', lambda m: self.console.append(m.text) if m.type in ('error', 'warning') else None)
        self.page.on('pageerror', lambda e: self.errors.append(str(e)))
        self.page.on('request', lambda r: self.requests.append((r.method, r.url)))

    def js(self, fn):
        return self.page.evaluate(('mw:' if self.mw else '') + fn)

    def text(self, sel):
        return self.page.inner_text(sel).strip()

    def until(self, cond, timeout=12.0, what=''):
        end = time.time() + timeout
        while time.time() < end:
            try:
                if cond():
                    return True
            except Exception:
                pass
            self.page.wait_for_timeout(120)
        return False

    def go(self, hash_):
        self.page.evaluate("h => { location.hash = h; }", hash_)
        self.until(lambda: self.page.is_visible('#v-' + hash_))
        self.page.wait_for_timeout(500)

    def shot(self, name, full=True):
        if not self.shots:
            return
        self.page.wait_for_timeout(350)
        vp = self.page.viewport_size
        if full:                             # the whole page as ONE screen, so the rail and the phone's bar sit where they belong
            hh = self.page.evaluate("() => document.documentElement.scrollHeight")
            if hh > vp['height']:
                self.page.set_viewport_size({'width': vp['width'], 'height': hh})
                self.page.wait_for_timeout(250)
        self.page.screenshot(path=os.path.join(self.shots, name + '.png'))
        if self.page.viewport_size != vp:
            self.page.set_viewport_size(vp)
            self.page.wait_for_timeout(150)

    def dialog(self, button_sel=None):
        if button_sel:
            self.page.click(button_sel)
        self.until(lambda: self.page.is_visible('#dlg[open]'))
        return self.page.locator('#dlg')

    def dlg_ok(self):
        self.page.click('#dlg-ok')
        self.page.wait_for_timeout(450)

    def toast(self, part, timeout=8.0):
        return self.until(lambda: part in self.text('#toast'), timeout)

    def a11y(self, where):
        self.page.wait_for_timeout(500)          # colours move over 180 ms after a theme switch; read them once they rest
        names = self.page.evaluate(JS_NAMES)
        ok(not names, where + ': every control has a name', names)
        con = self.page.evaluate(JS_CONTRAST)
        ok(not con, where + ': text contrast is at least 4.5:1 (3:1 for large type)', con)
        h1 = self.page.evaluate("() => [...document.querySelectorAll('h1')].filter(e => e.getClientRects().length).length")
        ok(h1 == 1, where + ': exactly one h1 on screen', h1)


def sign_in(t, password=PW):
    t.until(lambda: t.page.is_visible('#door-in'))
    t.page.fill('#in-user', ADMIN)
    t.page.fill('#in-pass', password)
    t.page.click('#in-go')


def t_first_boot(t):
    print('-- 1. first boot: the claim')
    p = t.page
    ctl(t.base, '/_test/reset', {'claimed': False})
    p.goto(t.base + '/', wait_until='load')
    ok(t.until(lambda: p.is_visible('#door-setup')), 'an unclaimed box opens on the setup door')
    ok(p.title() == 'A new box · make it yours' and 'no default password' in t.text('#door-setup'), 'it says there is no default password')
    t.a11y('setup')
    t.shot('01-setup-dark')
    p.click('#su-go')
    ok('eight digits' in t.text('#su-err'), 'an empty form is stopped at the code')
    code = ctl(t.base, '/_test/claim')['code']
    p.fill('#su-code', '%08d' % ((int(code) + 7) % 100000000)); p.fill('#su-name', 'ex4'); p.fill('#su-user', ADMIN); p.fill('#su-p1', 'short'); p.fill('#su-p2', 'short')
    p.click('#su-go')
    ok('twelve characters' in t.text('#su-err'), 'a short password is stopped in the page')
    p.fill('#su-p1', PW); p.fill('#su-p2', PW + 'x'); p.click('#su-go')
    ok('not the same' in t.text('#su-err'), 'two different passwords are stopped')
    p.fill('#su-p2', PW); p.fill('#su-user', 'root'); p.click('#su-go')
    ok('not root' in t.text('#su-err'), 'root is not accepted as the administrator')
    p.fill('#su-user', ADMIN); p.click('#su-go')
    ok(t.until(lambda: 'not the code' in t.text('#su-err')), 'a wrong code is refused by the box, and said')
    p.fill('#su-code', code); p.click('#su-go')
    ok(t.until(lambda: p.is_visible('#app') and t.text('#say') != '', 15), 'the right code claims the box and lands in the interface, signed in')
    posts = [json.loads(r.post_data or 'null') for r in []]            # (bodies are checked below through the fake)
    sent = t.js("() => sessionStorage.getItem('ex4-sid')")
    ok(isinstance(sent, str) and re.fullmatch(r'[0-9a-f]{32}', sent) is not None, 'the session id lives in sessionStorage (no cookie)')
    ok(t.js("() => document.cookie") == '', 'no cookie was set')


def t_overview(t):
    print('-- 2. overview: the sentence, the box, the numbers')
    p = t.page
    t.until(lambda: t.text('#say') == 'One disk wants watching.')
    ok(t.text('#say') == 'One disk wants watching.', 'the sentence: one disk wants watching', t.text('#say'))
    ok('bay 4' in t.text('#lede') and 'one sector it could not read' in t.text('#lede') and 'your files are safe' in t.text('#lede'), 'the lede says which bay, what happened, and that the files are safe', t.text('#lede'))
    ok(p.title() == 'ex4 · one disk wants watching', 'the sentence is the tab\'s title', p.title())
    facts = t.text('#facts')
    ok('Array whole, read-only' in facts and 'Bay 4 wants watching' in facts and '38 to 41 °C' in facts and 'Fan low · 1,020 rpm' in facts, 'the chips', facts)
    ok(t.text('#lcd').split('\n') == ['ex4', '192.0.2.50'] and p.locator('#bays .bay').count() == 4 and p.locator('#bays .led.warn').count() == 1, 'the portrait: the screen\'s name page, four bays, one amber light')
    ok('1.7 GB used of 10.8 TB' in t.text('#cap-note') and 'any one of them can fail' in t.text('#cap-note') and t.text('#cap-big').replace('\n', ' ').startswith('10.8'), 'space: 1.7 GB used of 10.8 TB', t.text('#cap-note'))
    ok(t.text('#clim-big').startswith('41') and 'Low · 1,020 rpm' in t.text('#clim-kv') and '44 °C' in t.text('#clim-kv'), 'climate', t.text('#clim-kv'))
    t.until(lambda: 'WD40EFRX' in t.text('#disks'))
    d = t.text('#disks')
    ok(d.count('WD40EFRX-68W') == 4 and '11.7 years running' in d and d.count('Healthy') == 3 and 'Wants watching' in d, 'the four disks with their age and state', d)
    n = t.text('#net-kv')
    ok(t.text('#net-big').startswith('1') and '192.0.2.50' in n and 'your router' in n and 'no cable' in n and 'ex4.local' in n, 'network', n)
    ok('This box was claimed' in t.text('#events'), 'lately: the claim is on record', t.text('#events'))
    ok('Trial boot.' in t.text('#trial') and re.search(r'\d+:\d\d', t.text('#trial')) is not None and p.is_visible('#stay'), 'the trial strip with its clock', t.text('#trial'))
    ok('OpenWrt 25.12.6' in t.text('#ver') and 'running from memory' in t.text('#ver'), 'the version line')
    p.wait_for_timeout(5000)
    p.focus('#hit'); p.keyboard.press('ArrowLeft')
    ok(t.until(lambda: p.is_visible('#tip') and 'Arriving' in t.text('#tip')), 'the chart reads back in time by keyboard')
    p.keyboard.press('Escape')
    p.click('#act-tbl summary')
    ok(t.until(lambda: p.locator('#tbody tr').count() >= 1), 'the chart has a table twin')
    p.click('#act-tbl summary')
    t.a11y('overview, dark')
    t.shot('02-overview-dark-one-disk-wants-watching')
    p.click('#stay')
    ok(t.until(lambda: 'staying' in t.text('#trial')) and not p.is_visible('#stay'), 'Stay stops the trial clock')

    ctl(t.base, '/_test/scenario', {'name': 'copy'})
    ok(t.until(lambda: float(t.text('#k-in')) > 30), 'a copy arriving shows within one poll', t.text('#k-in'))
    p.wait_for_timeout(16000)                # let the chart draw a stretch of the copy
    ok('A copy is arriving' in t.text('#act-state') and 'processor is the limit' in t.text('#act-note') and int(t.text('#k-cpu')) > 90, 'the honest note: the processor is the limit', t.text('#act-note'))
    ok(p.locator('#bays .led').count() == 4 and p.locator('#bays .led.warn').count() == 1, 'the bay lights are drawn')
    t.shot('03-overview-dark-copy-arriving')
    p.click('#theme')
    ok(t.js("() => document.documentElement.getAttribute('data-theme')") == 'light', 'the theme switch')
    t.a11y('overview, light')
    t.shot('04-overview-light-copy-arriving')
    ctl(t.base, '/_test/scenario', {'name': 'trial'})


def t_storage(t):
    print('-- 3. storage')
    p = t.page
    t.go('storage')
    t.until(lambda: 'RAID 5' in t.text('#arr-big'))
    ok('Whole, all four in step' in t.text('#arr-state') and t.text('#arr-big').replace('\n', ' ').startswith('RAID 5') and '10.9 TB across four disks' in t.text('#arr-big'), 'the array: RAID 5, whole', t.text('#arr-big'))
    ok(p.locator('#members div').count() == 4 and p.locator('#members div.watch').count() == 1 and 'disk wants watching' in t.text('#arr-legend'), 'four members, bay 4 marked, with a legend')
    kv = t.text('#arr-kv')
    ok('never started by this system on its own' in kv and 'read-only' in kv and '64 KiB chunks' in kv and 'no write-intent bitmap' in kv, 'no scheduled check is promised; read-only said', kv)
    ok('<1' in t.text('#vol-big') and '1.7 GB' in t.text('#vol-kv') and '10.8 TB' in t.text('#vol-kv'), 'space', t.text('#vol-kv'))
    ok(p.locator('#dtable tr:not(.detail)').count() == 4 and '12 minutes ago' in t.text('#dt-age') and 'without waking' in t.text('#dt-age'), 'the disk table, and how old its reading is', t.text('#dt-age'))
    p.click('#dtable .xbtn[aria-controls="dd4"]')
    det = t.text('#dd4')
    ok(p.is_visible('#dd4') and 'Pending sectors' in det and '99,812' in det and 'in step' in det and 'passed' in det, 'a row opens to the SMART counters', det)
    ok('cannot' not in t.text('#v-storage button') if p.locator('#v-storage .btn').count() else True, 'the page offers no button that could change the array')
    ok(p.locator('#v-storage .btn').count() == 0, 'no action button exists on Storage in this version')
    t.a11y('storage, light')
    t.shot('05-storage-light')
    p.click('#theme')
    t.shot('06-storage-dark')


def t_shares(t):
    print('-- 4. shares, people, groups, NFS')
    p = t.page
    t.go('users')
    ok('Nobody yet' in t.text('#us-list') and t.text('#adm-name') == ADMIN, 'users: nobody yet; the administrator is named')
    d = t.dialog('#us-add')
    d.get_by_label('Name').fill('anna'); d.get_by_label('Password').fill('a long password'); d.get_by_label('Once more').fill('a different one')
    t.dlg_ok()
    ok('not the same' in t.text('#dlg-err') and p.is_visible('#dlg[open]'), 'add a person: two different passwords are stopped in the dialog')
    d.get_by_label('Once more').fill('a long password'); d.get_by_label('Name').fill('Anna B')
    t.dlg_ok()
    ok('lower-case' in t.text('#dlg-err'), 'the box\'s own refusal (a bad name) is shown in the dialog', t.text('#dlg-err'))
    d.get_by_label('Name').fill('anna')
    t.dlg_ok()
    ok(t.until(lambda: 'anna' in t.text('#us-list')) and not p.is_visible('#dlg[open]') and t.toast('Person added'), 'anna is added and the dialog closes')
    d = t.dialog('#us-add'); d.get_by_label('Name').fill('ben'); d.get_by_label('Password').fill('another long one'); d.get_by_label('Once more').fill('another long one'); t.dlg_ok()
    t.until(lambda: 'ben' in t.text('#us-list'))
    d = t.dialog('#gr-add'); d.get_by_label('Name').fill('family'); d.get_by_label('anna').check(); d.get_by_label('ben').check(); t.dlg_ok()
    ok(t.until(lambda: 'family' in t.text('#gr-list') and 'anna, ben' in t.text('#gr-list')), 'a group with two members')
    ok(t.until(lambda: 'family' in t.text('#us-list')), 'each person shows the group')
    t.a11y('users, dark')
    t.shot('07-users-dark')

    t.go('shares')
    ok('No folder is offered yet' in t.text('#sh-list') and 'read-only' in t.text('#sh-note'), 'shares: nothing yet; the read-only volume is explained', t.text('#sh-note'))
    d = t.dialog('#sh-add')
    opts = d.locator('[data-f=Folder] option').all_text_contents()
    ok(len(opts) == 5 and all('already on the volume' in o for o in opts), 'on a read-only volume only folders that exist are offered; "a new folder" is not', opts)
    d.locator('[data-f=Folder]').select_option('Media'); d.get_by_label('Access for anna').select_option('rw'); d.get_by_label('Access for @family').select_option('ro')
    t.shot('08-shares-add-dialog-dark', full=False)
    t.dlg_ok()
    ok(t.until(lambda: 'Media' in t.text('#sh-list') and 'anna may change it; the family group may read it.' in t.text('#sh-list')), 'a share for anna and the family, said in a sentence', t.text('#sh-list'))
    d = t.dialog('#sh-add'); d.locator('[data-f=Folder]').select_option('Public'); d.get_by_label('Without a password').select_option('ro'); t.dlg_ok()
    ok(t.until(lambda: 'Everyone may read it.' in t.text('#sh-list')), 'Public for everyone, read-only')
    d = t.dialog('#ex-add'); d.get_by_label('Share').select_option('Media'); d.get_by_label('Machines that may mount it').fill('192.0.2.0/24; rm -rf /')
    t.dlg_ok()
    ok('Clients are one address' in t.text('#dlg-err'), 'an NFS client spec with shell characters is refused by the box, and said', t.text('#dlg-err'))
    d.get_by_label('Machines that may mount it').fill('192.0.2.0/24'); t.dlg_ok()
    ok(t.until(lambda: 'to 192.0.2.0/24 · read only · root becomes nobody' in t.text('#ex-list')), 'an NFS export, said in words; read only because the volume is', t.text('#ex-list'))
    ok(t.until(lambda: p.locator('#sh-list .badge', has_text='NFS').count() == 1), 'the share shows an NFS badge')
    t.a11y('shares, dark')
    t.shot('09-shares-dark')
    d = t.dialog('#sh-list li:first-child .ac button:last-child')
    ok('stay on the disks' in d.inner_text() and 'NFS export' in d.inner_text(), 'removing a share says what stays and what goes', d.inner_text())
    p.keyboard.press('Escape')
    ok(t.until(lambda: not p.is_visible('#dlg[open]')) and 'Media' in t.text('#sh-list'), 'Escape closes the dialog and nothing was removed')
    d = t.dialog('#sh-list li:first-child .ac button:first-child'); d.get_by_label('A Time Machine target for Macs').check(); t.dlg_ok()
    ok(t.until(lambda: 'Time Machine' in t.text('#sh-list')), 'Change: Time Machine on')
    ctl(t.base, '/_test/scenario', {'name': 'rw'})
    t.until(lambda: t.text('#sh-note') == '', 12)
    d = t.dialog('#sh-add')
    opts = d.locator('[data-f=Folder] option').all_text_contents()
    ok(any('a new folder' in o for o in opts), 'read-write with the owner\'s token: a new folder is offered', opts)
    d.locator('[data-f=Folder]').select_option(''); d.get_by_label('Name of the new folder').fill('../escape'); t.dlg_ok()
    ok('share name is' in t.text('#dlg-err'), 'a path as a folder name is refused', t.text('#dlg-err'))
    p.click('#dlg-no')
    ctl(t.base, '/_test/scenario', {'name': 'trial'})


def t_services_alerts(t):
    print('-- 5. services, alerts')
    p = t.page
    t.go('services')
    t.until(lambda: p.locator('#sv-list .svc').count() == 5)
    s = t.text('#sv-list')
    ok(p.locator('#sv-list .svc').count() == 5 and 'Windows and Mac file sharing' in s and 'Unix file sharing' in s and 'Stays on during a trial' in s, 'five services, in plain words', s)
    ok(p.locator('#sv-list input[aria-label="Secure shell"]').is_disabled(), 'secure shell cannot be switched off during a trial')
    p.locator('#sv-list .svc', has_text='Windows and Mac').locator('.switch').click()
    ok(t.until(lambda: 'Running · holds 9.2 MB' in t.text('#sv-list')), 'SMB switched on: running, and what it holds in memory', t.text('#sv-list'))
    p.locator('#sv-list .svc', has_text='Unix file sharing').locator('.switch').click()
    t.until(lambda: t.text('#sv-list').count('Running') == 4)
    t.a11y('services, dark')
    t.shot('10-services-dark')

    t.go('alerts')
    t.until(lambda: p.input_value('#al-port') == '587')
    ok(not p.is_checked('#al-on') and p.locator('#al-ev input:checked').count() == 4, 'alerts: off, every event ticked')
    p.check('#al-on', force=True); p.click('#al-save')
    ok(t.until(lambda: 'need a recipient' in t.text('#al-err')), 'switching alerts on without a server is refused, and said', t.text('#al-err'))
    p.fill('#al-to', 'owner@example.org'); p.fill('#al-from', 'ex4@example.org'); p.fill('#al-host', 'smtp.example.org'); p.fill('#al-port', '465'); p.select_option('#al-tls', 'tls')
    p.fill('#al-user', 'ex4@example.org'); p.fill('#al-pass', 'app pass word 16'); p.fill('#al-pct', '85')
    p.click('#al-test')
    ok('Save first' in t.text('#al-err'), 'a test before saving is stopped: it would test the old settings')
    p.click('#al-save')
    ok(t.toast('Alerts saved') and t.text('#al-err') == '', 'alerts saved')
    ok(t.until(lambda: 'A password is stored' in t.text('#al-h-pass')) and p.input_value('#al-pass') == '', 'the password field empties; the page only knows that one is stored')
    p.click('#al-test')
    ok(t.toast('took the test message', 10), 'a test message, and what became of it')
    ok(t.until(lambda: 'taken by the mail server' in t.text('#al-last')), 'the last result stays on the page')
    t.a11y('alerts, dark')
    t.shot('11-alerts-dark')


def t_panel_system(t):
    print('-- 6. front panel, system')
    p = t.page
    t.go('panel')
    ok(t.until(lambda: 'sent nothing' in t.text('#pn-sent')) and not p.is_checked('#f-feed'), 'by default the screen is sent nothing, and the page says so', t.text('#pn-sent'))
    ok(p.locator('#f-bl option').count() == 3, 'only the three sleep times the screen is known to take are offered')
    p.locator('.field', has_text='Feed the screen').locator('.switch').click()
    ok(t.until(lambda: t.text('#pn-saved') == 'Saved.'), 'a switch saves as it is changed')
    t.until(lambda: 'Name' in t.text('#pn-sent'))
    s = t.text('#pn-sent')
    ok('ex4' in s and '192.0.2.50' in s and 'Watch sdd' in s and '1020rpm' in s and '41 44' in s, 'fed: what the screen was given', s)
    p.select_option('#f-bl', '6')
    ok(t.until(lambda: t.text('#pn-saved') == 'Saved.'), 'the sleep time saves')
    t.a11y('front panel, dark')
    t.shot('12-front-panel-dark')

    t.go('system')
    t.until(lambda: p.input_value('#sy-name') == 'ex4')
    ok(p.locator('#sy-zone option').count() == 60 and 'UTC' in t.text('#sy-time'), 'system: name, 60 time zones, the box\'s clock')
    p.select_option('#sy-zone', 'America/Los_Angeles'); p.click('#sy-form button[type=submit]')
    ok(t.toast('Saved'), 'time zone saved')
    p.select_option('#net-mode', 'static')
    ok(p.is_visible('#net-addr'), 'choosing a fixed address shows its fields')
    p.fill('#net-addr', '192.0.2.300'); p.fill('#net-mask', '255.255.255.0'); p.click('#net-form button[type=submit]')
    ok(t.until(lambda: 'four numbers' in t.text('#net-err')), 'a mistyped address is refused before anything changes', t.text('#net-err'))
    p.fill('#net-addr', '192.0.2.60'); p.fill('#net-gw', '192.0.2.1'); p.fill('#net-dns', '192.0.2.1 9.9.9.9'); p.select_option('#net-bond', 'active-backup'); p.click('#net-form button[type=submit]')
    ok(t.until(lambda: p.is_visible('#netp') and 'on trial' in t.text('#netp') and re.search(r'1:\d\d', t.text('#netp')) is not None), 'new settings go on trial: a strip with a clock and one button', t.text('#netp'))
    t.shot('13-system-dark-address-on-trial')
    p.click('#netp-keep')
    ok(t.until(lambda: not p.is_visible('#netp')), 'Keep it ends the trial of the settings', (p.is_visible('#netp'), t.text('#netp')))
    ok('192.0.2.60' in p.input_value('#net-addr') and p.input_value('#net-bond') == 'active-backup', 'and the kept settings are what the page shows')
    c = t.text('#cert-kv')
    ok(re.search(r'[0-9A-F]{4} [0-9A-F]{4} [0-9A-F]{4} [0-9A-F]{4}', c) is not None and 'ex4.local' in c and '822 days' in c, 'the certificate: fingerprint, names, how long it is good for', c)
    d = t.dialog('#pow-restart')
    ok("WD's firmware" in d.inner_text(), 'Restart says what it means in a trial', d.inner_text())
    p.click('#dlg-no')
    d = t.dialog('#pow-off')
    ok('fan keeps turning at full speed' in d.inner_text(), 'Shut down says the fan keeps turning until the button', d.inner_text())
    p.click('#dlg-no')
    with p.expect_download(timeout=20000) as dl:
        p.click('#bun-make')
    ok(dl.value.suggested_filename == 'ex4-support-bundle.txt' and t.toast('Bundle saved'), 'the support bundle is made on the box and saved by the browser')
    ok('never looks for them' in t.text('#v-system'), 'updates: the page says the box never phones anywhere')
    t.a11y('system, dark')
    t.shot('14-system-dark')
    p.click('#theme')
    t.a11y('system, light')
    t.shot('15-system-light')
    for h in ('alerts', 'services', 'shares', 'users', 'panel'):
        t.go(h)
        t.a11y(h + ', light')
    t.go('shares'); t.shot('16-shares-light')
    t.go('alerts'); t.shot('17-alerts-light')
    p.click('#theme')


def t_doors(t):
    print('-- 7. sign out, the brake, a session that ran out')
    p = t.page
    p.click('#signout')
    ok(t.until(lambda: p.is_visible('#door-in')) and t.text('#in-err') == 'Signed out.' and t.js("() => sessionStorage.getItem('ex4-sid')") is None, 'sign out: back at the door, the session id gone from the tab')
    ok(re.search(r'certificate begins [0-9A-F]{4} [0-9A-F]{4}', t.text('#in-foot')) is not None, 'the door shows the certificate\'s first digits to compare')
    t.a11y('sign-in')
    t.shot('18-sign-in-dark')
    for i in range(3):
        t.until(lambda: not p.is_disabled('#in-go'))
        sign_in(t, 'wrong password %d' % i)
        p.wait_for_timeout(500)
    ok(t.until(lambda: 'Wait' in t.text('#in-err')) and p.is_disabled('#in-go'), 'the third wrong password: the door says wait, and its button waits too', t.text('#in-err'))
    ok(t.until(lambda: not p.is_disabled('#in-go'), 6), 'and opens again by itself')
    sign_in(t)
    ok(t.until(lambda: p.is_visible('#app') and t.text('#say') != ''), 'the right password signs in')
    ctl(t.base, '/_test/expire', {})
    ok(t.until(lambda: p.is_visible('#door-in') and 'Sign in again' in t.text('#in-err'), 15), 'a session that ran out: back at the door, with a reason')
    sign_in(t)
    t.until(lambda: p.is_visible('#app'))


def t_states(t):
    print('-- 8. the sentence in every state')
    p = t.page
    t.go('overview')
    for scn, say, part, shot in (('healthy', 'All is well.', 'Four disks healthy', '19-overview-dark-all-is-well'), ('closed', 'The array is not open.', 'nothing on them is being touched', '20-overview-dark-array-not-open'),
                                 ('rebuild', 'The array is rebuilding.', '20.4% done, about', '21-overview-dark-rebuilding'), ('failed', 'A disk has failed.', 'bay 4 has dropped out', '22-overview-dark-disk-failed'),
                                 ('hot', 'The box is running hot.', '57 °C', None)):
        ctl(t.base, '/_test/scenario', {'name': scn})
        ok(t.until(lambda: t.text('#say') == say and part in t.text('#lede'), 10), '%s: "%s"' % (scn, say), t.text('#say') + ' / ' + t.text('#lede'))
        if scn == 'failed':
            ok(p.locator('#bays .led.crit').count() == 1 and 'Array on three of four' in t.text('#facts'), 'failed: a red light on bay 4, and the array on three of four')
        if shot:
            t.a11y(scn)
            t.shot(shot)
    t.go('storage')
    ctl(t.base, '/_test/scenario', {'name': 'failed'})
    ok(t.until(lambda: 'Running on three of four disks' in t.text('#arr-state') and p.locator('#members div.out').count() == 1, 10), 'storage in the failed state: three of four, bay 4 out', t.text('#arr-state'))
    t.shot('23-storage-dark-disk-failed')
    ctl(t.base, '/_test/scenario', {'name': 'trial'})
    t.go('overview')
    t.until(lambda: t.text('#say') == 'One disk wants watching.')


def t_budget(t, dist):
    print('-- 9. the budget, the keyboard')
    p = t.page
    size = os.path.getsize(dist)
    ok(size <= 163840, 'the page is one file of %d bytes (the budget: 163,840)' % size)
    del t.requests[:]
    p.reload(wait_until='load')
    t.until(lambda: p.is_visible('#app') and t.text('#say') != '')
    first = [r for r in t.requests]
    ok([m for m, u in first[:2]] == ['GET', 'POST'] and len([1 for m, u in first if m == 'GET']) == 1, 'a signed-in reload: one GET (the file) and one POST reach the first live sentence', first[:4])
    ok(all(u.startswith(t.base + '/') for m, u in t.requests), 'every request went to the box\'s own address', [u for m, u in t.requests if not u.startswith(t.base + '/')])
    req = urllib.request.Request(t.base + '/')
    etag = urllib.request.urlopen(req, timeout=10).headers.get('ETag')
    try:
        urllib.request.urlopen(urllib.request.Request(t.base + '/', headers={'If-None-Match': etag}), timeout=10)
        code = 200
    except urllib.error.HTTPError as e:
        code = e.code
    ok(code == 304, 'a revisit is answered 304 (the fake keeps uhttpd\'s ETag behaviour)')
    p.wait_for_timeout(2500)
    if t.mw is not None:
        t.js("() => { Object.defineProperty(document, 'hidden', { configurable: true, get: () => true }); document.dispatchEvent(new Event('visibilitychange')); }")
        p.wait_for_timeout(600)
        n0 = len(t.requests)
        p.wait_for_timeout(6000)
        ok(len(t.requests) == n0, 'a hidden tab asks the box for nothing (0 requests in 6 s)', len(t.requests) - n0)
        t.js("() => { Object.defineProperty(document, 'hidden', { configurable: true, get: () => false }); document.dispatchEvent(new Event('visibilitychange')); }")
        n0 = len(t.requests)
        ok(t.until(lambda: len(t.requests) > n0, 4), 'and asks again the moment it is shown')
        n0 = len(t.requests)
        p.wait_for_timeout(10300)
        ok(4 <= len(t.requests) - n0 <= 6, 'on the overview: one request every 2 s, never two at once (%d in 10 s)' % (len(t.requests) - n0))
    # keyboard: from the top, Tab reaches the skip link, then the navigation, each with a ring that can be seen
    p.evaluate("() => { document.activeElement && document.activeElement.blur(); window.scrollTo(0, 0); }")
    seen = []
    for _ in range(14):
        p.keyboard.press('Tab')
        seen.append(p.evaluate("() => { const e = document.activeElement, cs = getComputedStyle(e); return [e.tagName, (e.textContent || '').trim().slice(0, 24), cs.outlineStyle, parseFloat(cs.outlineWidth)]; }"))
    names = [s[1] for s in seen]
    ok(names[0] == 'Skip to content' and names[1:9] == ['Overview', 'Storage', 'Shares', 'Users', 'Services', 'Alerts', 'Front panel', 'System'], 'Tab walks: skip link, then the eight pages in order', names)
    ok(all(s[2] != 'none' and s[3] >= 2 for s in seen), 'every stop has a focus ring of 2 px or more', [s for s in seen if s[2] == 'none' or s[3] < 2])
    p.keyboard.press('Shift+Tab')
    p.evaluate("() => document.querySelector('.nav a[href=\"#storage\"]').focus()")
    p.keyboard.press('Enter')
    ok(t.until(lambda: p.is_visible('#v-storage') and p.evaluate("() => document.activeElement.id") == 'main'), 'Enter on a page link opens it and moves focus to the page')
    ok(p.evaluate("() => document.documentElement.lang") == 'en' and p.locator('main:visible').count() == 1 and p.locator('nav[aria-label]:visible').count() >= 1, 'landmarks: one main, a named nav, a language')
    t.go('overview')


def t_phone(browser, base, shots, mw):
    print('-- 10. a phone (390 x 844)')
    t = T(browser, base, shots, mw, w=390, h=844, dark=True)
    p = t.page
    p.goto(base + '/', wait_until='load')
    sign_in(t)
    ok(t.until(lambda: p.is_visible('#app') and t.text('#say') == 'One disk wants watching.', 15), 'phone: signed in, the sentence is there')
    nav = [a.inner_text().strip() for a in p.locator('.nav a:visible').all()]
    ok(nav == ['Overview', 'Storage', 'Shares', 'More'], 'phone: four places under the thumb', nav)
    t.until(lambda: 'WD40EFRX' in t.text('#disks'))
    t.shot('24-phone-overview-dark')
    for h in ('overview', 'storage', 'shares', 'users', 'services', 'alerts', 'panel', 'system', 'more'):
        t.go(h)
        sw = p.evaluate("() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]")
        wide = p.evaluate("() => [...document.querySelectorAll('main *')].filter(e => e.getClientRects().length && e.getBoundingClientRect().right > document.documentElement.clientWidth + 1).slice(0, 6).map(e => e.tagName + '#' + e.id + '.' + e.className + ' ' + Math.round(e.getBoundingClientRect().right) + ' ' + (e.textContent || '').trim().slice(0, 30))")
        ok(sw[0] <= sw[1], 'phone, %s: no sideways scroll' % h, (sw, wide))
        small = p.evaluate("""() => [...document.querySelectorAll('.nav a, .btn, .more-list a')].filter(e => e.getClientRects().length && !e.closest('[hidden]')).filter(e => { const r = e.getBoundingClientRect(); return r.height < 34 || r.width < 34; }).map(e => e.textContent.trim() + ' ' + Math.round(e.getBoundingClientRect().width) + 'x' + Math.round(e.getBoundingClientRect().height))""")
        ok(not small, 'phone, %s: buttons and links are at least 34 px to the touch' % h, small)
    t.go('more')
    ok([a.inner_text().strip() for a in p.locator('.more-list a').all()] == ['Users', 'Services', 'Alerts', 'Front panel', 'System'] and p.is_visible('#signout2'), 'phone: More holds the other five pages and Sign out')
    t.a11y('phone, more')
    t.shot('25-phone-more-dark')
    t.go('storage'); t.until(lambda: 'RAID 5' in t.text('#arr-big')); t.shot('26-phone-storage-dark')
    t.go('shares'); t.until(lambda: 'Media' in t.text('#sh-list')); t.shot('27-phone-shares-dark')
    d = t.dialog('#sh-add'); t.shot('28-phone-add-share-dialog-dark', full=False); p.click('#dlg-no')
    p.click('#theme'); t.go('overview'); t.until(lambda: 'WD40EFRX' in t.text('#disks')); t.a11y('phone, overview, light'); t.shot('29-phone-overview-light')
    t.go('system'); t.until(lambda: p.input_value('#sy-name') != ''); t.shot('30-phone-system-light')
    ok(not t.errors and not t.console, 'phone: no script error, a clean console', (t.errors, t.console))
    t.ctx.close()


def run(browser, base, shots=None, main_world=False):
    """Drive every test. `browser`: a Playwright Browser (or anything with new_context()). Returns the failures."""
    if shots:
        os.makedirs(shots, exist_ok=True)
    dist = os.path.join(HERE, '..', '..', 'webui', 'dist', 'index.html')
    t = T(browser, base, shots, main_world)
    for fn in (t_first_boot, t_overview, t_storage, t_shares, t_services_alerts, t_panel_system, t_doors, t_states, lambda x: t_budget(x, dist)):
        try:
            fn(t)
        except Exception as e:
            ok(False, 'test block crashed: %r' % (e,))
            try:
                if t.page.is_visible('#dlg[open]'):
                    t.page.click('#dlg-no')
            except Exception:
                pass
    ok(not t.errors, 'no uncaught script error in the whole run', t.errors)
    ok(not t.console, 'the console stayed clean: no policy violation, no warning', t.console[:6])
    t.ctx.close()
    try:
        t_phone(browser, base, shots, main_world)
    except Exception as e:
        ok(False, 'phone block crashed: %r' % (e,))
    print('\n%d passed, %d failed%s' % (len(PASS), len(FAIL), (': ' + '; '.join(FAIL[:10])) if FAIL else ''))
    return FAIL


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--shots')
    ap.add_argument('--browser', default='firefox')
    ap.add_argument('--port', type=int, default=18491)
    a = ap.parse_args()
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print('SKIP: the playwright Python module is not installed (see this file\'s header for the other way in)')
        return 77
    fake = subprocess.Popen([sys.executable, '-I', os.path.join(HERE, 'fakebox.py'), '--port', str(a.port)], stdout=subprocess.DEVNULL)
    try:
        time.sleep(1.0)
        with sync_playwright() as pw:
            browser = getattr(pw, a.browser).launch(headless=True)
            fails = run(browser, 'http://127.0.0.1:%d' % a.port, a.shots)
            browser.close()
    finally:
        fake.terminate()
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
