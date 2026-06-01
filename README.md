# IPTV Hub

IPTV Hub is a self-hosted Windows service that aggregates multiple IPTV sources into a single, unified server — complete with a web management UI, EPG guide, recording schedules, search, and transcoding support.

---

## What It Does

IPTV Hub sits between your IPTV providers and your media players (Plex, Emby, Jellyfin, Kodi, VLC, Tivimate, etc.). You point it at your M3U playlists, Xtream Codes providers, or local network tuners, and it presents them all as a single polished IPTV server.

### Core Features

- **Multi-source aggregation** — combine M3U playlists, Xtream Codes (Xtream API), M3U collections (multiple URLs merged), HDHomeRun tuners, and SAT>IP tuners into one channel list.
- **Multiple IPTV servers** — run several independent server instances on different ports from a single installation. Clone a server in one click to create a copy with a new port and ID.
- **Xtream Codes emulation** — each server exposes a fully compatible Xtream Codes API so players that only support Xtream Codes work out of the box.
- **EPG / XMLTV** — download XMLTV feeds from any URL (including gzip-compressed feeds), map channel IDs to your provider's tvg-ids, and serve a merged `iptvhub.xmltv` endpoint. A built-in browser lists 70+ free EPG sources by region.
- **Free M3U source browser** — discover and load 110+ free public playlists from iptv-org directly in the UI.
- **Transcoding** — optional ffmpeg-backed HLS adaptive transcoding with selectable quality profiles (requires ffmpeg on PATH).
- **Timeshift / catch-up** — per-channel HLS ring-buffer so viewers can pause and rewind live TV.
- **Recording rules** — schedule one-time or series recordings by EPG title and channel; rules expand automatically from the EPG guide.
- **Search** — full-text search across live channels, VOD, series, and EPG programmes with fuzzy token matching and kind filters (Live / VOD / Series / EPG).
- **Watch history** — tracks what was played, when, and on which server, including redirect-mode streams.
- **Custom playlists** — curate hand-picked channel lists from any combination of sources.
- **Channel overrides** — rename channels, change logos, reorder, or hide individual channels without touching the source.
- **Parental controls** — PIN-protected category filtering to hide adult content from the M3U and Xtream responses.
- **Backup & restore** — export the full configuration (servers, sources, channel overrides, custom playlists, recording rules, skip markers, EPG import profiles) as an AES-256-GCM encrypted archive; restore as a full replace or a merge.
- **Audit log** — every authentication event, PIN change, and factory reset is recorded with timestamp and IP address.

### Management UI

A React web app served at **http://localhost:5000** lets you:

| Page | What you can do |
|---|---|
| **Dashboard** | See all servers at a glance — status, channel counts, EPG programme counts, recent refresh history |
| **Servers** | Add, edit, clone, start, stop, and delete IPTV server instances |
| **Sources** | Manage M3U, Xtream, HDHomeRun, SAT>IP, and YouTube sources; enable/disable, test, and clone |
| **Channel Manager** | Browse, filter, inhibit, bulk-test, override, and reorder channels per server |
| **EPG** | View the guide grid, manage feeds, map channel IDs, and schedule series recordings |
| **EPG Import** | Generate Plex/Emby/Jellyfin-compatible import files and push them to a remote server via SFTP |
| **Search** | Full-text search across all running servers with kind filtering and fuzzy matching |
| **Playlists** | Create and manage custom playlists of hand-picked channels |
| **Logs** | Browse and download NLog output; filter by level and date |
| **Settings** | App-wide settings, parental PIN, backup export/restore, and factory reset |

---

## Requirements

- **Windows** (runs as a Windows Service or standalone console app)
- **.NET 8 Runtime** (bundled in the installer)
- **ffmpeg** on PATH — optional, required only for transcoding and timeshift

---

## Quick Start

### Install (recommended)

1. Download and run `IptvHubSetup-x.x.x.exe` as Administrator.
2. Open **http://localhost:5000** in a browser.
3. Set an admin password on first run.
4. Go to **Sources → Add Source** and enter your M3U URL or Xtream Codes credentials.
5. Go to **Servers → Add Server**, assign a port (e.g. `8080`), link your sources, and click **Start**.
6. Point your media player at `http://<your-pc>:8080/iptvhub.m3u` for M3U or use the Xtream Codes credentials shown in the server card.

### Run from source

```powershell
# Terminal 1 — backend
cd src\IptvHub.Service
dotnet run

# Terminal 2 — frontend dev server
cd src\IptvHub.Web
npm install
npm run dev
```

Management UI: **http://localhost:5173** · Backend API: **http://localhost:5000/api**

---

## Key Endpoints (per IPTV server)

| Endpoint | Description |
|---|---|
| `GET :<port>/iptvhub.m3u` | M3U playlist |
| `GET :<port>/iptvhub.xmltv` | XMLTV EPG feed (cached, ETag/304 supported) |
| `GET :<port>/iptvhub.xmltv?gz=true` | Gzip-compressed XMLTV |
| `GET :<port>/live/<user>/<pass>/<id>.ts` | Live stream proxy |
| `GET :<port>/transcode/live/<user>/<pass>/<id>/master.m3u8` | HLS adaptive transcode |
| Xtream API | Full Xtream Codes panel and player API |

---

## Architecture

- **Backend:** ASP.NET Core / .NET 8, LiteDB, Quartz.NET, NLog
- **Frontend:** React 18, TypeScript, Vite, Tailwind CSS, TanStack Query
- **Each IPTV server** runs as its own embedded Kestrel instance inside the same process
- **No external database** — all data lives in LiteDB files in the `data/` directory

---

## Version

Current release: **1.1.2**
