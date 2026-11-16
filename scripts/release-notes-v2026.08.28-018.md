# MeTube for TOS v2026.08.28-018

Fixes the aarch64 package being rejected by the store with:

```
config.ini Platform Consistency
Reason: Platform mismatch: the platform bound architecture is aarch64,
but the package resolves to x86_64.
```

## Cause

`config.ini` declares the platform it is built for, and it was hardcoded to
`"platform": "x86_64"`. The aarch64 build therefore shipped a config.ini that
claimed x86_64, which the store correctly flagged.

## Fix

`platform` is now generated from the build target:

| TARGET_ARCH | config.ini `platform` |
|---|---|
| `amd64` | `x86_64` |
| `arm64` | `aarch64` |

The verify stage now asserts that the packaged `config.ini` platform matches
the target architecture, so this cannot regress silently.

## Assets

| Platform | File |
|---|---|
| x86_64 | `metubedownload_x86_64.deb` |
| aarch64 | `metubedownload_aarch64.deb` |

Both are fully source-built (`built-from-source: yes`).

## Fixes carried over from the reviewed 2026.08.28-015

- **-016** — quickjs-ng bundled as the yt-dlp JavaScript runtime (fixes
  `No supported JavaScript runtime` / `No video formats found`).
- **-017** — listeners scoped to loopback (`HOST=127.0.0.1`,
  `bgutil-pot --host 127.0.0.1`); source-audit statement added at
  `/usr/share/doc/metube/SOURCE-AUDIT.md`.
