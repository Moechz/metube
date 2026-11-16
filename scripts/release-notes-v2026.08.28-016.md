# MeTube for TOS v2026.08.28-016

Bundles **quickjs-ng** as the yt-dlp JavaScript runtime, fixing YouTube
downloads that failed with:

```
[youtube] No supported JavaScript runtime could be found ...
[youtube] Only images are available for download ...
ERROR: [youtube] ...: No video formats found!
```

## Why

yt-dlp's web player client must solve YouTube's `n`/`sig` signature
challenges in JavaScript. Since the -011 packaging dropped deno as
"unused", the package shipped no JS engine, so web-client formats were
silently missing and many videos failed.

## What changed

- **quickjs-ng v0.17.0 (`qjs`)** is now bundled at `/opt/metube/bin/qjs`
  and built from source by the public CI (CMake, ~1 min, single-file C —
  no V8, no `gcc-12` workaround needed).
- The `/usr/bin/metube` launcher defaults `YTDL_OPTIONS` to
  `{"js_runtimes": {"quickjs": {}}}`. Idempotent: a user-set
  `js_runtimes` is never overridden, and invalid JSON is passed through.
- Provenance: `BUILD-INFO` / `PROVENANCE.md` record the quickjs origin,
  version and pinned source sha256.

## Verification

- amd64 and arm64, **fully source-built** in the public CI
  (`built-from-source: yes`, `origin: srcbuild` for CPython, bgutil-pot
  and quickjs).
- glibc floor 2.35 (TOS 7 base) asserted at build time.
- Pre-release check on a real TOS device: `qjs` solved the n/sig
  challenges and the web client returned a complete format list
  (https formats present, no SABR-only skips).

## Upgrading

Install over the previous version (`apt install` / App Center manual
install). Existing configuration in `/etc/metube/metube.env` is never
touched; the default JS runtime is injected by the launcher unless you
set `js_runtimes` yourself.
