# MeTube for TOS v2026.08.28-017

Remediation release for the App Center listing review (items V10, S4, S9, V6, T1).

## Fixes

**V10 — architecture mismatch (submission error).** The previous submission
uploaded `metubedownload_aarch64.deb` while declaring `platform=x86_64`, so the
package could not install on the review device. This release was submitted as
the **x86_64** asset whose deb control metadata reads `Architecture: amd64`.

**S4 — port scoping.** Both services now listen on loopback only:

| Service | Before | Now |
|---|---|---|
| `metubedownload.service` | `HOST=0.0.0.0:8081` | `HOST=127.0.0.1:8081` |
| `metube-pot.service` | `[::]:4416` | `bgutil-pot server --host 127.0.0.1` |

External access is unchanged in practice: the TOS nginx site
(`/etc/nginx/conf.d/metube.conf`) proxies `http://127.0.0.1:8081/metube/`, which
is what the desktop entry opens. Users who explicitly want direct LAN access to
`:8081` can set `HOST=0.0.0.0` in `/etc/metube/metube.env` and run
`metube-apply-config`.

**S9 / V6 / T1 — source auditability and CVEs.** New
`/usr/share/doc/metube/SOURCE-AUDIT.md` states, component by component, where
each bundled binary comes from (source URL, version, pinned sha256), which
public CI stage built it, and how to reproduce the build. It also documents the
one prebuilt artifact in the package — the V8 static library linked into
`bgutil-pot` by the standard `v8` Rust crate — including the fact that V8 is
open source, that `V8_FROM_SOURCE=1` is available if a source-compiled V8 is
required, and why the engine is not an untrusted-execution path (localhost-only,
dedicated unprivileged user, systemd sandbox, driven solely by Google's BotGuard
script). `PROVENANCE.md` and `BUILD-INFO` reference it.

## Also in this line (since the reviewed 2026.08.28-015)

- **-016**: bundles quickjs-ng (`qjs`) as the yt-dlp JavaScript runtime, fixing
  `No supported JavaScript runtime` / `No video formats found` on YouTube web
  client (the -011 packaging had dropped deno as "unused").

## Verification

- amd64 and arm64 built in the public CI, `built-from-source: yes`
  (CPython, bgutil-pot, quickjs-ng and all Python deps).
- glibc floor 2.35 asserted; package structure and the presence of
  `SOURCE-AUDIT.md` asserted in the verify stage.
