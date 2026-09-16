# MeTube Download 2026.08.28-010

MeTube Download is a web-based video downloader powered by yt-dlp: paste a link in your browser to download from YouTube, Bilibili and a thousand more sites — batch queueing, automatic audio extraction, free choice of quality and output format, and channel subscriptions.

This build is packaged for the **TerraMaster TOS 7 App Center** (x86_64):

- **Self-contained**: bundles a private CPython 3.13 runtime, all Python dependencies, a Deno runtime and the bgutil PO Token provider — no system Python or pip required.
- **Hardened**: runs as a dedicated unprivileged `metube` user inside a systemd sandbox (read-only system paths, no capabilities).
- **Your download directory, your choice**: no default download path is preset. Type any absolute path into the web UI *Download Folder* field (grant the `metube` user access in your NAS sharing settings first) — it is remembered across restarts. Alternatively set `DOWNLOAD_DIR` in `/etc/metube/metube.env` and run `metube-apply-config`.
- Downloads stay blocked with a clear message until you explicitly choose a directory.
- **Privacy policy**: no data collection; a bilingual (EN/中文) privacy policy ships with the app and is reachable from a visible *Privacy Policy* link in the web UI footer, both via the App Center entry and direct access.

## Install

```bash
dpkg -i metube_2026.08.28-010_amd64.deb
```

Then open the TOS desktop → App Center → **MeTube Download**, or browse to `https://<NAS-IP>/metube/`.

## Verification

- MD5: `db5eba18f8c0d91a29662c5a91ac3074`
- SHA-256: `fe4288523de9546bc82fed74199d36e515cea1317240740f726e68ee0427fa16`
- Tested end-to-end on TerraMaster TOS 7: App Center integration, download gate, UI-chosen sticky download directory (survives restarts and page reloads), real downloads to NAS shared folders, in-app privacy policy link.

## Legal

Respect the copyright laws of your region and download only content you are entitled to. This packaging is maintained by Moechz; MeTube itself is open-source software (AGPL-3.0) by its respective authors.
