# The web interface

One page, served by the box itself, for a WD My Cloud EX4 running this port. It answers the one question a NAS is
asked ("is my stuff all right?") in one sentence, shows the machine as it is, and lets its owner set up shares,
people, groups, NFS exports, services, e-mail alerts, the network and the front screen. Nothing in it can create,
reshape, check or erase the array: no such command exists in it.

**State: built and tested OFF the box. It has never run on an EX4.** What "tested" means is at the end.

```
browser ── HTTPS, one connection ──> uhttpd            one static file, /www-ex4/index.html (118 KB), ETag/304
   │  POST /ubus  (JSON-RPC, a batch per poll)
   ▼
uhttpd-mod-ubus ──> ubusd ──> rpcd ── backend/ex4.uc   the whole backend: an rpcd ucode plugin, object `ex4`
                                        read path : /proc, /sys, small files in RAM. No fork, no disk, 1 s cache
                                        write path: uci (/etc/config/ex4 ...) + one helper at a time, as a job
                                      backend/libexec/ex4-apply   /etc/config/ex4 -> the services' own files; cron `watch`
ex4fan (the one owner of the front micro) ──> /tmp/ex4fan.json ──read──> ex4.uc ──write──> /etc/config/ex4panel
```

## Files

| Here | On the box | What |
|---|---|---|
| `src/` + `build.py` -> `dist/index.html` | `/www-ex4/index.html` | the page: HTML, CSS, JS, icons in ONE file; no framework, no font, no CDN |
| `backend/ex4.uc` | `/usr/share/rpcd/ucode/ex4.uc` | every method the page calls |
| `backend/acl/ex4.json`, `unauthenticated.json` | `/usr/share/rpcd/acl.d/` | who may call what; the second REPLACES rpcd's own file |
| `backend/libexec/ex4-apply` | `/usr/libexec/ex4/ex4-apply` | the helper (ucode): config generation, SMB passwords, the watcher, power |
| `backend/bin/ex4-claim` | `/usr/sbin/ex4-claim` | over ssh: print the setup code; `reset` = back to unclaimed |
| `backend/etc/config/ex4`, `ex4panel` | `/etc/config/` | the interface's own settings; what it asks of the front panel |
| `backend/etc/uci-defaults/95_ex4_webui` | `/etc/uci-defaults/` | first boot: no web login, uhttpd on HTTPS with our certificate, the watcher's cron line |
| `backend/share/zones` | `/usr/share/ex4/zones` | 60 time zones with their POSIX strings (checked against the tz database) |
| `FILES` | | the list above, machine-readable: the overlay builder and the emulation test both install from it |

`python3 webui/build.py` makes `dist/index.html` and REFUSES over 163,840 bytes (uhttpd serves the file as it is: no
compression), or when the source has an inline style, an event-handler attribute or an outside URL. It writes the
sha256 of the one `<style>` and the one `<script>` into the page's Content-Security-Policy.

## The rules

1. **The read path never opens a disk, runs a command or walks a directory tree.** One poll is `ex4 status`: about
   1.1 KB, read from `/proc`, `/sys` and files other programs leave in RAM. Two tabs inside a second share one
   snapshot. A hidden tab asks for nothing; a slow box slows the asking.
2. **A write method only writes `/etc/config` (uci), `/etc/ex4` and `/tmp/ex4`**, then starts the helper as an argv
   array (never a shell), one at a time. The page gets a job id and reads its outcome from the next `status`.
3. **A secret never travels in a command line.** The administrator's password leaves the browser only as a
   sha256crypt hash (computed in the page; rpcd's own `crypt()` checks sign-ins against it). An SMB password goes to
   the helper in a 0600 file under a 0700 folder in RAM and from there to `smbpasswd` on stdin. The mail password
   sits in `/etc/ex4/smtp-pass` (0600) and is never sent back to a browser.
4. **A name is checked against a pattern before use; a path never comes from the browser.** A share's folder is
   always `<volume>/<its name>`.
5. **The one write under the data volume** is `mkdir` of a NEW share's folder, refused unless the volume is mounted
   read-write AND the owner's token `/tmp/ex4-rw-ok` is valid for this boot (v8: checked by CONTENT: a regular root
   file, mode 0600, one line `rw-ok <boot_id of this boot>`; nothing here creates it). Removing a share never
   touches its folder. Shares and exports are written out only while the volume is mounted and the folder exists,
   and are forced read-only on a read-only volume.

## Security

- **No default password.** A fresh box has no web login at all (first boot removes every `config login`, root's
  first; rpcd's `session.login` is closed to browsers). Claiming it needs an eight-digit code (v9; six in v8) that exists only on the
  box: `ex4-claim` over ssh (key-only) prints it, and it is offered to the front screen as an alert line
  (`/var/run/ex4panel/alerts.d/00-claim`, shown when the screen is fed). Five wrong codes: a new code and a minute's
  pause. `ex4-claim reset` goes back to unclaimed.
- **The administrator is not root and not a Unix account**: one `config login` in `/etc/config/rpcd` with the access
  group `ex4`. A session can call the methods in `acl/ex4.json` and end itself; it cannot read a file, run a command,
  reach `uci` or grant itself more.
- **Sign-in brake.** After the second failure a lock-out starts and doubles (1 s ... 5 min); inside it nothing is
  checked. v8: a try is counted BEFORE rpcd checks it, and only one check is in flight at a time, so a burst of
  parallel guesses gets "wait" instead of slipping past the lock (the claim's check is synchronous inside rpcd's one
  thread already). It is global (the web server does not say who asks): a hostile device on the LAN can keep it running.
- **Sessions**: rpcd's, 128 bits, 15 idle minutes, kept in `sessionStorage` and sent in the request body. No cookie,
  so no cross-site request can ride one. v8: `signout_all` ends every session whose access list names `ex4` (read
  from rpcd's own session list, not only the ones this rpcd counted), and a password change ends every session but
  the one that made it.
- **NFS.** An export that is writable, open to every host (`*`) and does not squash root is refused (v8).
- **The server** takes 16 requests at once and 32 connections, and drops a client that sends nothing for 15 s (v8;
  OpenWrt's default of 3 requests let three slow clients starve the page).
- **HTTPS** with a certificate the box makes itself (px5g, EC P-256, 825 days, names `<name>` and `<name>.local`);
  port 80 only redirects. A self-made certificate means a browser warning the first time: the page and the sign-in
  door show the fingerprint to compare. No address is in the certificate: this px5g writes address entries in a form
  browsers reject (seen under emulation), so reach the box by name.
- **The page's own policy**: `default-src 'none'`, one hashed script, one hashed style, `connect-src 'self'`. Every
  string from the box enters through `textContent`. The page refuses to run inside a frame.

## Methods (`ubus call ex4 <method>`)

No session: `setup_state` · `setup_claim {code, username, hash, hostname}` · `sign_in {username, password}`.
Read: `status` · `events {since}` · `disks` · `array` · `shares` · `users` · `services` · `alerts` · `system` ·
`panel` · `bundle_get`.
Write: `share_add / share_set / share_remove` · `export_add / export_set / export_remove` (NFS) ·
`user_add / user_passwd / user_remove` · `group_add / group_set / group_remove` · `service_set {id, enabled}` (ids:
smb, nfs, find, ssh, time; ssh cannot be switched off during a trial) · `alerts_set`, `alerts_test` · `system_set
{hostname, zonename}` · `net_set {mode, addr, mask, gw, dns, bond}` + `net_confirm` (a change is tried for 90 s and
taken back unless confirmed) · `keeper_passwd {old, hash}` · `signout_all` · `cert_renew` · `restart`, `shutdown`
(always: stop sharing, sync, unmount, stop the array, then reboot or halt) · `trial_stay` · `support_bundle` ·
`panel_set {on, lcd, standby}`.
A refusal is `{ok: false, err: <code>, msg: <a sentence the page shows>}`.

## What it expects of the rest of the image

| From | What | If it is missing |
|---|---|---|
| `ex4fan` (docs/PANEL.md) | `/tmp/ex4fan.json`: fan, temperatures, per-drive SMART, space, what the screen was given. Reads `/etc/config/ex4panel`: `mode`, `lcd_sleep_mode`, `standby` | the older one-line `/tmp/ex4fan.status` is understood; with neither, the page says there is no word from the fan |
| the image | `samba4-server` or `ksmbd` (their own uci files are written: `/etc/config/samba4`, `/etc/config/ksmbd`), `nfs-kernel-server` (`/etc/exports`), `msmtp` (`/etc/msmtprc`), `smartmontools`, `wsdd2`, `avahi`, `proto-bonding`, cron | a service that is not installed shows as "Not in this image"; its settings are kept |
| the trial overlay | `/etc/ex4/trial` holding `return_min=N`; `/tmp/ex4-stay` | no trial strip; the interface behaves as installed |
| whoever assembles the array | the volume mounted at `/mnt/md1` (`ex4.main.volume`) | "The array is not open."; nothing is shared |

Option names were read from the OpenWrt 25.12 packages feed (`net/samba4/files/samba.init`, `net/ksmbd-tools`,
`net/nfs-kernel-server`, `net/bonding/files/lib/netifd/proto/bonding.sh`), not from memory.

## Not in this version, on purpose

Array verbs (check, replace a disk: they will need a button press on the box), quotas, recycle bin, USB disks,
backups, DLNA, UPS, updates over the network, our own screen pages, the lights. SMB passwords for `ksmbd` are
passed on stdin and are untested against the real `ksmbd.adduser`. Users get new ids from 1000; adopting the ids WD's
firmware gave existing files is an install-time step that is not written yet. Settings live in RAM during a trial.
Sizes are shown the way a file manager counts them (1 TB = 1024 GB), rates in MiB/s.

## Tested, and how (tests/webui/README.md)

| | Proven by |
|---|---|
| The real backend: every method, every refusal, the files it leaves, the commands its helper asks for, no secret in a command line, the address change that takes itself back, the two gates before `mkdir`, the watcher's e-mails | `emu/emu.sh` + `api_test.py --emu`: OpenWrt 25.12.6's own ARM rpcd, uhttpd, ucode, uci and px5g under qemu-arm, with this folder installed from `FILES` and the first-boot script run for real: **269 checks** |
| The page: every page and form, both themes, phone and desk, keyboard, contrast, its own security policy, the budget | `page_test.py` in a real browser against `fakebox.py`: **199 checks**, 30 screenshots |
| The fake is a fair stand-in | the same `api_test.py` list passes on it (207 checks) |
| The real page on the real backend | claim, sign-in (the browser's hash accepted by rpcd's `crypt()`), a share, a service: 12 checks through the emulated uhttpd |

**Not proven, because it needs the box:** time per poll on the ARMv5 core (target: 10 ms of CPU, 100 ms on the wall
while a copy runs), memory the plugin adds to rpcd, the TLS handshake cost, Samba/NFS/msmtp/smartctl actually doing
what the helper asks (they are stubs in the emulation), `/etc/init.d/network reload` with a bond, the code on the
front screen.
