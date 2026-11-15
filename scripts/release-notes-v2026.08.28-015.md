# MeTube Download 2026.08.28-015

**Changes since 2026.08.28-014:**

- **CI source-build fixed**: the recurring bgutil-pot SIGSEGV is root-caused
  to the Ubuntu 22.04 default gcc-11 linker mislinking the embedded V8 130
  static archive (clang-14/lld-14 equally affected, proven by controlled
  experiments). The public workflow now links bgutil-pot with gcc-12 inside
  the 22.04 container — smoke-tested at build time, with a glibc symbol
  ceiling assertion — while keeping the glibc 2.35 floor for the TOS 7 base.
  This unblocks fully source-built, V6-auditable release builds.


**Changes since 2026.08.28-012:**

- **New-tab launch**: `open_path=true` — clicking the desktop icon now opens
  `https://<NAS>/metube/` in a new browser tab (like qBittorrent), instead of an
  embedded iframe window inside the TOS desktop.
- **Correct authorship**: the App Center "developer" (`auth` in the language
  file, all 23 locales) now names the upstream author **alexta69**
  (github.com/alexta69/metube). This packaging project (Moechz) remains the
  publisher/maintainer, not the author.
- **Help & Official links** now point to the TerraMaster forum thread
  (terra-master.com, viewtopic t=10595) instead of this repository.


MeTube Download is a web-based video downloader powered by yt-dlp: paste a link in your browser to download from YouTube, Bilibili and a thousand more sites — batch queueing, automatic audio extraction, free choice of quality and output format, and channel subscriptions.

This build is packaged for the **TerraMaster TOS 7 App Center** (x86_64 / aarch64):

- **Every binary built from source in public CI** (V6 remediation): the bundled CPython interpreter is compiled from the official python.org source tarball (sha256 pinned in `config.env`), the PO Token server from its Rust sources, and all Python dependencies from sdists — by this repository's public GitHub Actions workflow. Each package embeds `/opt/metube/BUILD-INFO` and `/usr/share/doc/metube/PROVENANCE.md` documenting the exact origin and build path of every component, so the release is independently auditable and reproducible.
- **Deno removed** (it was never used at runtime): the package shrinks from 112MB to ~54MB.
- **Self-contained**: no system Python or pip required; hardened systemd sandbox, dedicated unprivileged `metube` user.
- **Your download directory, your choice**: no default download path is preset. Type any absolute path into the web UI *Download Folder* field (grant the `metube` user access in your NAS sharing settings first) — it is remembered across restarts. Alternatively set `DOWNLOAD_DIR` in `/etc/metube/metube.env` and run `metube-apply-config`.
- Downloads stay blocked with a clear message until you explicitly choose a directory.
- **Privacy policy**: no data collection; a bilingual (EN/中文) privacy policy ships with the app and is reachable from a visible *Privacy Policy* link in the web UI footer, both via the App Center entry and direct access.

## Install

```bash
dpkg -i metubedownload_<platform>.deb
```

Then open the TOS desktop → App Center → **MeTube Download**, or browse to `https://<NAS-IP>/metube/`.

## Verification

- x86_64 md5: `TBD-md5` (metubedownload_x86_64.deb == metube_2026.08.28-015_amd64.deb)
- x86_64 sha256: `TBD-sha256`
- Built entirely by [the public build workflow](https://github.com/Moechz/metube/actions/workflows/build.yml); see the run linked in each package's `BUILD-INFO`.
- Tested end-to-end on TerraMaster TOS 7: App Center integration, download gate, UI-chosen sticky download directory (survives restarts and page reloads), real downloads to NAS shared folders, in-app privacy policy link, upgrade from -010 preserving all user data and configuration.

## Legal

Respect the copyright laws of your region and download only content you are entitled to. This packaging is maintained by Moechz; MeTube itself is open-source software (AGPL-3.0) by its respective authors.
