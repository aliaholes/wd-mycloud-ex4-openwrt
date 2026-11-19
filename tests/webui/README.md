# Tests of the web interface (all off the box; none touches an EX4, a disk or the network)

```sh
python3 webui/build.py                                   # the page: webui/dist/index.html (refuses over 160 KiB)
python3 tests/webui/sha256crypt.py                       # the reference password hash against the specification + openssl
python3 tests/webui/fakebox.py --claimed &               # a stand-in box on http://127.0.0.1:18490 (keeper / tide and lamp, 12+)
python3 tests/webui/api_test.py --url http://127.0.0.1:18490          # every method, against the stand-in
python3 tests/webui/page_test.py --shots /tmp/shots      # every page in a real browser (needs the playwright module)
bash tests/webui/emu/emu.sh work/ix4-rootfs /tmp/emu1 -- python3 tests/webui/api_test.py --emu    # every method, REAL backend
```

| File | What it is |
|---|---|
| `truth.py` | the sample box: the test unit's numbers (four WD40EFRX in RAID 5, 1.7 GB of 10.8 TB used, bay 4 with one unreadable sector, no scheduled check) with made-up serials, addresses and names; nine scenarios; also writes itself as a tree of `/proc`, `/sys`, `/tmp` files |
| `fakebox.py` | python3 only: serves the page and answers `/ubus` like the box (sessions, the same access lists, a model of every method). Loopback only. `/_test/...` switches scenarios |
| `api_test.py` | ONE list of checks for both backends; `--emu` also reads the files the backend wrote and the commands its helper asked for; `--slow` adds the one-minute claim lock-out |
| `page_test.py` | the page in a browser: claim, every page and form, the sentence in every state, sign-in brake, expiry, budget, keyboard, names, contrast, phone; screenshots |
| `sha256crypt.py` | the `$5$` hash in plain Python: the third, independent implementation beside the page's and rpcd's |
| `emu/emu.sh` | OpenWrt's own ARM `ubusd`, `rpcd`, `uhttpd`, `ucode`, `uci`, `px5g` under qemu-arm on a copy of the image's root, with `webui/FILES` installed, the first-boot script run, and `truth.py`'s tree as the box. Programs the helper would start are stubs that record their arguments and stdin. Needs qemu-arm and the ARM cross gcc (two small preloads: `mkdirstub.c`, `statstub.c`) |

The emulation shows WHAT the backend does and asks for. It cannot show how long anything takes on the box, and it
does not run Samba, NFS, msmtp or smartctl.
