#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""build.py : webui/src/{index.html,app.css,app.js,symbols.html} -> webui/dist/index.html, the ONE file the box serves.

  python3 webui/build.py [--out FILE] [--check]

What it does, and nothing else (python3 standard library only; touches no device, no network):
  - puts the style sheet, the icon symbols and the script into the page;
  - fills in the 64 SHA-256 round constants, computed here with whole-number arithmetic (never typed by hand);
  - drops comment-only lines and leading white space (the source stays readable, the box serves less);
  - computes the sha256 of the one <style> and the one <script> and writes them into the page's
    Content-Security-Policy, so nothing else can run or style the page: no inline handler, no eval, no other script;
  - REFUSES when the result is over the budget: 163,840 bytes (160 KiB), uncompressed, because uhttpd serves the file as it
    is; or when the source breaks one of the page's own rules (an inline style attribute, an event-handler attribute,
    a URL that would leave the box).
--check builds in memory and says whether dist/index.html is that build.
"""
import argparse, base64, hashlib, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUDGET = 163840


def die(msg):
    sys.exit('build: REFUSED: ' + msg)


def icbrt(n):
    x = 1 << ((n.bit_length() + 2) // 3)
    while True:
        y = (2 * x + n // (x * x)) // 3
        if y >= x:
            return x
        x = y


def sha256_k():
    primes, n = [], 2
    while len(primes) < 64:
        if all(n % p for p in primes):
            primes.append(n)
        n += 1
    k = [icbrt(p << 96) & 0xffffffff for p in primes]
    assert k[0] == 0x428a2f98 and k[63] == 0xc67178f2, 'round constants'
    return ', '.join('0x%08x' % v for v in k)


def lean_js(s):
    out = []
    for line in s.split('\n'):
        t = line.strip()
        if not t or t.startswith('//') or (t.startswith('/*') and t.endswith('*/')):
            continue
        out.append(t)
    return '\n'.join(out)


def lean_css(s):
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    return '\n'.join(t.strip() for t in s.split('\n') if t.strip())


def lean_html(s):
    out = []
    for line in s.split('\n'):
        t = line.strip()
        if not t or (t.startswith('<!--') and t.endswith('-->')):
            continue
        out.append(t)
    return '\n'.join(out) + '\n'


def build():
    rd = lambda n: open(os.path.join(HERE, 'src', n), encoding='utf-8').read()
    html, css, js, sym = rd('index.html'), rd('app.css'), rd('app.js'), rd('symbols.html')
    if js.count('@SHA256_K@') != 1:
        die('app.js must hold the marker for the round constants exactly once')
    js = lean_js(js.replace('@SHA256_K@', sha256_k()))
    css = lean_css(css)
    for what, text in (('index.html', html), ('symbols.html', sym)):
        if re.search(r'\sstyle\s*=', text):
            die(what + ' has an inline style attribute (the policy forbids them; use a class)')
        if re.search(r'\son[a-z]+\s*=', text):
            die(what + ' has an event-handler attribute (the policy forbids them)')
    for what, text in (('app.js', js), ('app.css', css), ('index.html', html)):
        for m in re.finditer(r'(?:https?:)?//[A-Za-z0-9.-]+\.[a-z]{2,}', text):
            if 'www.w3.org' not in m.group(0):           # the SVG name space string, never fetched
                die(what + ' names an outside address: ' + m.group(0))
    if '</script' in js.lower() or '</style' in css.lower():
        die('a closing tag inside the script or the style sheet')
    h = lambda b: "sha256-" + base64.b64encode(hashlib.sha256(b.encode('utf-8')).digest()).decode('ascii')
    page = lean_html(html.replace('@SYMBOLS@', sym.strip()))
    for mark in ('@CSS@', '@JS@', '@SCRIPT_HASH@', '@STYLE_HASH@'):
        if page.count(mark) != 1:
            die('index.html must hold %s exactly once' % mark)
    page = page.replace('@SCRIPT_HASH@', h(js)).replace('@STYLE_HASH@', h(css)).replace('@CSS@', css).replace('@JS@', js)
    raw = page.encode('utf-8')
    if len(raw) > BUDGET:
        die('the page is %d bytes; the budget is %d' % (len(raw), BUDGET))
    return raw


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(HERE, 'dist', 'index.html'))
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()
    raw = build()
    if a.check:
        same = os.path.exists(a.out) and open(a.out, 'rb').read() == raw
        print('dist is %s' % ('this build' if same else 'NOT this build'))
        return 0 if same else 1
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, 'wb') as f:
        f.write(raw)
    print('wrote %s: %d bytes (%.1f%% of the %d-byte budget), sha256 %s, md5 %s' % (a.out, len(raw), 100.0 * len(raw) / BUDGET, BUDGET, hashlib.sha256(raw).hexdigest(), hashlib.md5(raw).hexdigest()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
