# MeTube Download for TOS (deb packaging)

Packages [MeTube](https://github.com/alexta69/metube) (a web download UI for yt-dlp: playlists / subscriptions / quality selection) as a **deb** for **TOS** (TerraMaster Debian-based NAS, amd64 / arm64).

**Highlights**: the deb ships a complete self-contained runtime (CPython 3.13 + all Python dependencies + Deno + the YouTube PO Token service). It does **not** depend on the NAS system Python — after `apt install` it just works.

- Requirements & acceptance: [PROJECT_REQUIREMENTS.md](PROJECT_REQUIREMENTS.md)
- Technical design & handover: [PROJECT_HANDOVER_DOCS.md](PROJECT_HANDOVER_DOCS.md)

---

## Build

On macOS (Apple Silicon / Intel) or Linux:

```bash
./build.sh        # one-shot build → out/metube_<version>_<arch>.deb
./build.sh info   # show current version/arch configuration
```

The build runs in 5 stages (`fetch` → `ui` → `deps` → `stage` → `deb`), each safely re-runnable; downloads are cached under `build/downloads/`.

Common variants:

```bash
# ARM-based NAS
sed -i '' 's/TARGET_ARCH=amd64/TARGET_ARCH=arm64/' config.env   # on Linux drop the ''
./build.sh

# Upgrading to a new upstream release: only change METUBE_VERSION in config.env
```

**Mirror acceleration** (optional, for networks with poor GitHub/PyPI/npm reachability):

```bash
export NPM_CONFIG_REGISTRY=https://registry.npmmirror.com
export UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
./build.sh
```

## Installing on TOS

```bash
cat out/metube_*_amd64.deb | ssh user@nas "cat > /tmp/metube.deb"   # scp/sftp may be blocked on TOS; an ssh pipe is the most reliable
ssh user@nas
apt install -y /tmp/metube.deb     # pulls in aria2 automatically and starts the services
```

Then open **http://<NAS-IP>:8081** in a browser.

> 💡 **TOS quirk**: the day-to-day account (e.g. `apple`) is itself uid 0 — **do not use sudo** (sudo actually drops you to a restricted uid 9999 and breaks the dpkg lock). On standard Debian/Ubuntu, use sudo as usual. TOS ships ffmpeg already; on other systems install it with `sudo apt install ffmpeg` if missing.

## Configuration

The single config file is **`/etc/metube/metube.env`** (never overwritten on upgrade). Common keys:

| Variable | Default | Notes |
|---|---|---|
| `PORT` | `8081` | Web port |
| `HOST` | `0.0.0.0` | Listen address (use `127.0.0.1` for localhost-only) |
| `DOWNLOAD_DIR` | empty | Download directory (server-level config): any absolute path; when empty you can set it directly in the web UI (Option 2 below) |
| `STATE_DIR` | `/var/lib/metube/state` | Queue/state persistence |
| `OUTPUT_TEMPLATE` | `%(title)s.%(ext)s` | Output filename template |
| `YTDL_OPTIONS` | `{}` | Advanced yt-dlp options (JSON; wrap in single quotes) |

After editing, run `sudo systemctl restart metubedownload` (the main unit has been named `metubedownload.service` since `-010`).

**Custom download directory** (fully up to you — any absolute path; no volume names or directory layouts are assumed):

### Option 1: configure via the command line (server-level)

```bash
# 1. Edit the config and set DOWNLOAD_DIR to any absolute path (the directory does not need to exist yet):
vi /etc/metube/metube.env
#    DOWNLOAD_DIR=/any/path/you/like/metube

# 2. Apply with one command (creates the directory, grants the metube user access,
#    applies the sandbox write whitelist, restarts the service):
metube-apply-config        # on TOS do NOT use sudo; on standard Debian use sudo
```

### Option 2: set it in the web UI (no command line; recommended for daily use)

While `DOWNLOAD_DIR` is empty, simply type an **absolute path** into the **Download Folder** box in the web UI (the path of a shared folder as shown in your NAS file manager) and download:

- Prerequisite: grant the **metube** user read/write permission on that folder in TOS *Shared Folders / User Permissions* first
- Requirements: the path must already exist, be writable by the metube user, and be outside system locations (/etc, /usr, /home, …)
- The path is **remembered** (stored in the app's own writable state area and pre-filled after page reloads); subsequent downloads need no input
- A relative path still means "a subfolder of the base directory" (upstream semantics); both options can be mixed
- Precedence: the server-level `DOWNLOAD_DIR` (Option 1) wins; a path chosen in the UI is restored automatically after restarts
- Paths under `/home` are currently blocked by the sandbox; all other regular paths are fine

**Download-directory gate (important)**: this package ships **no default download path**; `DOWNLOAD_DIR` is empty by default. Until you configure either option, download requests are rejected with `Set a download folder before downloading.` — files always land in a location you explicitly chose, never in some unexpected system directory.

> 💡 To let family members watch videos over SMB, point the path at a shared folder on your NAS — use whatever path your device's file manager actually shows (volume layouts differ per device; this package makes no assumptions).

## Service management

```bash
systemctl status metubedownload metube-pot  # status (main unit named metubedownload since -010; metube-pot is the YouTube PO Token service)
journalctl -u metubedownload -f             # follow logs
sudo systemctl restart metubedownload       # restart
```

Autostart on boot is enabled by default; a crashed main process is restarted within 5 seconds.

## Updating yt-dlp (first thing to try when YouTube breaks)

yt-dlp moves fast; after a YouTube change old versions fail to extract. Dependency updates are **distributed with new deb releases** (the App Center policy forbids runtime online installs, so the former `metube-update-ytdlp` tool was removed): install a new deb via App Center/dpkg and restart — user data and configuration are fully preserved.

## Privacy policy

The app collects and uploads no data. See the full policy inside the package (`privacy-policy.html`) or at `https://<NAS-IP>/metube/privacy-policy.html`.

## Upgrade / uninstall

```bash
# Upgrade (newly built deb)
sudo apt install ./metube_<new-version>_amd64.deb   # config preserved, services restarted automatically

# Uninstall (keeps config and downloaded files)
sudo apt remove metube

# Full cleanup (also removes /var/lib/metube data and the metube user)
sudo apt purge metube
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Page won't open | `systemctl status metubedownload`; `journalctl -u metubedownload -n 50`; change `PORT` on conflicts |
| Downloads fail to extract | Install a newer deb (yt-dlp ships with the package; no built-in online updater since -010) |
| YouTube asks for login/token | Check `systemctl status metube-pot`; if still failing, install a newer deb |
| YouTube completely unreachable (timeout/HTTP 000) | The NAS network must reach YouTube; with a proxy, add `YTDL_OPTIONS='{"proxy": "http://192.168.x.x:7890"}'` to `/etc/metube/metube.env` and restart |
| "merging ... but ffmpeg is not installed" | TOS ffmpeg can be **file-level broken** (`dpkg -l` says installed but `/usr/bin/ffmpeg` is missing). Fix and restart: `apt install -y --reinstall ffmpeg libavdevice58 libavcodec58 libavfilter7 libavformat58 libavutil56 libpostproc55 libswresample3 libswscale5 && systemctl restart metubedownload` (no sudo on TOS; **the service must be restarted afterwards** — an old process caches the ffmpeg-unavailable state) |
| UI-chosen directory rejected | The folder must exist and be writable by metube: grant access in TOS sharing permissions, or `chown -R metube:metube <dir>` (no sudo on TOS) |
| Files writable/deletable by group members | `sudo systemctl edit metubedownload`, add `[Service]` + `UMask=0000` |
| PO Token service logs | `journalctl -u metube-pot -n 50` |

## On-disk layout (quick reference)

```
/opt/metube/                          self-contained stack (app + ui + vendor + python + bin)
/usr/bin/metube                       launcher wrapper (dependency updates ship with new debs)
/usr/bin/metube-apply-config          apply download-directory config
/etc/metube/metube.env                configuration (bootstrap-once; never touched on upgrade)
/etc/systemd/system/metubedownload.service   main service (+ metube-pot.service)
/etc/systemd/system/metubedownload.service.d/99-download-dirs.conf   sandbox whitelist (generated)
/usr/local/metubedownload/            TOS App Center metadata (config.ini, metubedownload.lang, icon, init.d/, webui.bz2, privacy-policy.html)
/var/lib/metube/state/                queue/history/sticky download dir (user data — survives upgrades)
```
