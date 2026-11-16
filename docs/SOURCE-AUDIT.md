# Source-level audit statement

Package: MeTube Download (`metubedownload`, deb package `metube`)
Maintainer: Moechz

This document answers the source-auditability questions raised in the listing
review (items S9, V6, T1, S4). It lists every native binary shipped in the
package, states where its source comes from, how it was built, and how the
result can be independently reproduced.

## 1. How this package is built

All release packages are built by the **public** GitHub Actions workflow
`.github/workflows/build.yml` in <https://github.com/Moechz/metube>, in an
`ubuntu:22.04` container (glibc 2.35 floor, the TOS 7 base). The workflow:

1. builds CPython from the official python.org source tarball;
2. builds the PO Token provider from its Rust source (cargo);
3. builds quickjs-ng from its C source (cmake);
4. builds every Python dependency from sdist (no wheels);
5. assembles the deb and publishes it as a release asset.

The exact commit, run URL, source hashes and component versions used for a
given package are recorded **inside the package** in
`/opt/metube/BUILD-INFO` and `/usr/share/doc/metube/PROVENANCE.md`. Rerunning
the same public workflow at the recorded commit reproduces the build.

## 2. Bundled binaries and their provenance

| Path in package | Component | Version | Source | Built by |
|---|---|---|---|---|
| `/opt/metube/python/bin/python3`, `libpython3.13.so` | CPython | 3.13.15 | python.org official source tarball (`Python-3.13.15.tgz`, sha256 `c28d9d21…` pinned in `config.env`) | this repo's public CI, stage `python-src` |
| `/opt/metube/bin/bgutil-pot` | bgutil-ytdlp-pot-provider-rs | v0.8.1 | github.com/jim60105/bgutil-ytdlp-pot-provider-rs (commit `185796c3…`) | this repo's public CI, stage `bgutil-src` (`cargo build --release --locked --features ffi`) |
| `/opt/metube/bin/qjs` | quickjs-ng | v0.17.0 | github.com/quickjs-ng/quickjs (source sha256 `559bc4c4…` pinned in `config.env`) | this repo's public CI, stage `quickjs-src` (cmake, target `qjs_exe`) |
| `/opt/metube/vendor/**` | 33 Python packages, versions locked by the upstream `uv.lock` | see `uv.lock` | PyPI **sdists** | this repo's public CI, stage `deps` (`uv pip install --no-binary=:all:`) |
| `/opt/metube/ui` | web UI (JavaScript, not native) | 2026.08.28 | upstream ui/ sources + downstream patches | this repo's public CI (pnpm / ng build) |

Python dependencies (all built from sdist in CI, no prebuilt wheels):
aiohappyeyeballs 2.7.1, aiohttp 3.14.3, aiosignal 1.4.0, anyio 4.14.2,
attrs 26.1.0, bidict 0.23.1, brotli 1.2.0, certifi 2026.7.22, cffi 2.1.1,
charset-normalizer 3.5.1, curl_cffi 0.15.0, frozenlist 1.8.0, h11 0.16.0,
idna 3.18, markdown-it-py 4.2.0, mdurl 0.1.2, multidict 6.7.1, mutagen 1.48.1,
propcache 0.5.2, pycparser 3.0, pycryptodomex 3.23.0, pygments 2.20.0,
python-engineio 4.13.5, python-socketio 5.16.4, requests 2.34.2, rich 15.0.0,
simple-websocket 1.1.0, urllib3 2.7.0, watchfiles 1.2.0, websockets 17.0.1,
wsproto 1.3.2, yarl 1.24.5, yt-dlp 2026.8.19, yt-dlp-ejs 0.8.0.

## 3. The embedded V8 inside `bgutil-pot` (item S9 / V6)

`bgutil-pot` is the YouTube PO Token provider. It executes Google's *BotGuard*
virtual machine in a JavaScript engine; the Rust crate it uses (`v8`, version
`130.0.7`) links a **prebuilt static V8 library** published by the rust-v8
project and downloaded at build time by the crate's `build.rs`.

* V8 is **open source** (BSD-3, part of the Chromium project,
  <https://chromium.googlesource.com/v8/v8>). The static library is a compiled
  form of that public source, not a proprietary or obfuscated blob.
* The build is not hidden: `cargo build` fetches the artifact by its published
  hash from <https://github.com/denoland/rusty_v8> releases and the whole step
  runs in the public CI referenced above.
* It is the standard, intended way to embed V8 in a Rust program; no
  alternative source-only path exists that keeps the provider functional.

If a fully source-compiled V8 is required, the crate supports
`V8_FROM_SOURCE=1`, which builds V8 from the Chromium source tree in CI (build
time in the order of 1–2 hours). We are prepared to switch to that mode if the
review requires it.

### Why it is not an untrusted-execution risk

`bgutil-pot` runs Google's BotGuard VM, whose script is fetched from
`youtube.com` over HTTPS — the same script a browser would execute. It is not
an interpreter exposed to arbitrary input:

* the service is bound to **localhost only** (see §5) and is not reachable from
  the network;
* it runs as the dedicated unprivileged user `metube` under a systemd sandbox
  (`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
  `PrivateDevices`, `RestrictNamespaces`, empty `CapabilityBoundingSet`,
  `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`);
* no user-supplied JavaScript is ever passed to it.

## 4. Vulnerability posture (item T1)

The scan reports known CVEs in packaged components. We do not have the itemised
list from the review, so the following is stated from the pinned versions:

* **V8 13.0.245** (inside `bgutil-pot`) is the oldest component and the most
  likely source of V8 CVEs. Upstream `bgutil-ytdlp-pot-provider-rs` v0.8.1 is
  the latest release and still pins this V8 line, so no newer upstream version
  removes them. Mitigation is as in §3: the engine is driven exclusively by
  Google's own BotGuard script, in a localhost-only, unprivileged, sandboxed
  service with no attacker-controlled input path. We will rebuild V8 from
  source (or move to a provider with a newer engine) if the reviewer requires
  the CVEs to be cleared rather than mitigated.
* **CPython 3.13.15** is a current release built from the python.org tarball;
  security fixes are picked up by bumping `PBS_PYTHON` in `config.env`.
* **Python dependencies** come from the upstream `uv.lock`; `curl_cffi 0.15.0`,
  `aiohttp 3.14.3`, `cryptography`-free stack etc. are current releases for
  this application. Dependency bumps are shipped as new package revisions
  (the app never installs anything at runtime — the launcher deliberately
  ignores yt-dlp's self-update request; see `/usr/bin/metube`).

The review device's vulnerability scan result is reproducible by running a
scanner over the release asset; the component list in §2 tells which upstream
project each finding belongs to.

## 5. Port scoping (item S4)

The package is a native deb, not a container; the equivalent of "port
mappings" are the listening sockets of its two systemd services. Both are now
scoped to the loopback interface only:

| Service | Listener | Scope |
|---|---|---|
| `metubedownload.service` | `HOST=127.0.0.1`, `PORT=8081` | loopback only; the TOS nginx (`/etc/nginx/conf.d/metube.conf`) proxies `http://127.0.0.1:8081/metube/` to it, and the desktop entry opens that nginx URL |
| `metube-pot.service` | `bgutil-pot server --host 127.0.0.1` (port 4416) | loopback only; used solely by yt-dlp running in the same host |

No other port is opened by the application. Users who want to reach the web UI
directly on the LAN can set `HOST=0.0.0.0` in `/etc/metube/metube.env` and run
`metube-apply-config`; this is off by default.

## 6. Reproducing the audit

```
git clone https://github.com/Moechz/metube
cd metube && cat config.env        # pinned versions and source hashes
# inspect .github/workflows/build.yml (the exact build recipe)
# compare /opt/metube/BUILD-INFO inside the package with the CI run URL it names
```

Every release asset is published with a `.sha256` checksum next to it.
