# MeTube Download 2026.08.28-010

MeTube Download is a web-based video downloader powered by yt-dlp: paste a link in your browser to download from YouTube, Bilibili and a thousand more sites — batch queueing, automatic audio extraction, free choice of quality and output format, and channel subscriptions.

This build is packaged for the **TerraMaster TOS 7 App Center** (x86_64):

- **Self-contained**: bundles a private CPython 3.13 runtime, all Python dependencies, a Deno runtime and the bgutil PO Token provider — no system Python or pip required.
- **Hardened**: runs as a dedicated unprivileged `metube` user inside a systemd sandbox (read-only system paths, no capabilities).
- **Your download directory, your choice**: no default download path is preset. Type any absolute path into the web UI *Download Folder* field (grant the `metube` user access in your NAS sharing settings first) — it is remembered across restarts. Alternatively set `DOWNLOAD_DIR` in `/etc/metube/metube.env` and run `metube-apply-config`.
- Downloads stay blocked with a clear message until you explicitly choose a directory.

## Install

```bash
dpkg -i metube_2026.08.28-010_amd64.deb
```

Then open the TOS desktop → App Center → **MeTube Download**, or browse to `https://<NAS-IP>/metube/`.

## Verification

- MD5: `ed281b54712668ad6ce423bf83e2520b`
- SHA-256: `60fdc90f79581f937f5ceb34bd08468a75ebd23cb2a5de2b5a3aef6483f27758`
- Tested end-to-end on TerraMaster TOS 7: App Center integration, download gate, UI-chosen sticky download directory (survives restarts and page reloads), real downloads to NAS shared folders.

## Legal

Respect the copyright laws of your region and download only content you are entitled to. This packaging is maintained by Moechz; MeTube itself is open-source software (AGPL-3.0) by its respective authors.
