# update/: signed releases, the box's `ex4-update`, and the CVE watch

The whole story is in [docs/UPDATES.md](../docs/UPDATES.md). The files:

| File | Runs on | What |
|---|---|---|
| `mkrelease.py` | the build box | `release`: bundle + OpenWrt tree -> RELEASE (v9: with `not-after`, and an optional `successor` key), RELEASE.sig, payload tar, CycloneDX SBOM · `sbom` · `ident` (the image's `/etc/ex4-release`) |
| `usignpy.py` | any host | verifies usign/signify ed25519 signatures in plain Python (RFC 8032 vectors in `selftest`); cannot sign |
| `box/ex4-update` | the EX4 (`/usr/sbin/ex4-update`, in the image since v9) | `check` / `verify` / `stage` into RAM / `status` / `keys`; refuses an expired release, plain http (without `--insecure-http`), adopts a vouched-for successor key; `install` refuses (not built) |
| `cvewatch.py` + `osv-map.json` | any host | signed SBOM -> OSV.dev (name, ecosystem, version only) -> what needs a rebuild; v9: the same findings twice = no new finding (the dedupe ledger) |
| `keys/ex4-release.pub` | in the image | the release key (usign key number `cd0c35ab50a98c3c`); its private half is never in this repository |
| `FILES` | the image build | what goes into the image, and where |

Tests: `tests/update/run.sh` (the box half under qemu-arm on the image's own binaries), `tests/update/watch-fixture.py`.
