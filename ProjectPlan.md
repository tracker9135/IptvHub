# IPTV Hub — Project Plan & Architecture

**Version:** 1.0.2  
**Target Framework:** .NET 8 (Windows Service) + React 18 (TypeScript)  
**Status:** Planning / Scaffolding

---

## Overview

A self-contained IPTV aggregation hub that:
- Runs as a **Windows Service** (no WPF, no tray, no parent process dependency)
- Manages **multiple IPTV sources** (M3U URLs and Xtream Codes providers)
- Exposes multiple **IPTV server instances** on configurable ports with full Xtream Codes API compatibility
- Provides a **React web frontend** for configuration and monitoring via a management REST API
- Has **zero dependency** on E-Channelizer or any external host process

---

## Solution Structure

```
IPTV_Hub/
├── ProjectPlan.md
├── IptvHub.sln
└── src/
    ├── IptvHub.Service/           ← .NET 8 Windows Service (backend)
    └── IptvHub.Web/               ← React 18 + TypeScript (frontend)
```

---

## Technology Choices

| Concern | Original (Hub.exe) | New Choice | Rationale |
|---|---|---|---|
| Process model | WPF WinExe + tray | .NET 8 Windows Service | No UI dependency, SCM managed, auto-restart |
| HTTP server | EmbedIO | ASP.NET Core / Kestrel | First-class .NET support, middleware ecosystem |
| Database | LiteDB | LiteDB | Embedded NoSQL, zero-config, excellent for this workload |
| Scheduling | Quartz.NET | Quartz.NET | Same proven library, `Quartz.Extensions.Hosting` integration |
| HTTP client | Flurl.Http | Flurl.Http | Fluent API, good timeout/cancellation support |
| Logging | NLog | NLog.Web.AspNetCore | Structured logging, file/console targets |
| IPC | Named pipe to E-Channelizer | None (self-contained) | All config via REST API |
| Configuration | User.cfg + IPC | appsettings.json + LiteDB | Standard .NET config + DB-backed server configs |
| UI | WPF popup (no main window) | React 18 + Vite + Tailwind | Modern web UI, API-driven |
| API docs | None | Swagger / OpenAPI | Developer-friendly, auto-generated |

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Windows Service Host                       │
│                    (IptvHub.Service)                          │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐     │
│  │         Management API  (port 5000)                  │     │
│  │         ASP.NET Core + Swagger                       │     │
│  │  ┌────────────┐ ┌────────────┐ ┌────────────────┐   │     │
│  │  │/api/servers│ │/api/sources│ │/api/status/logs│   │     │
│  │  └────────────┘ └────────────┘ └────────────────┘   │     │
│  │         Serves React frontend static files            │     │
│  └─────────────────────────────────────────────────────┘     │
│                          │                                     │
│                    ServerManager                               │
│                    (singleton)                                 │
│                          │ manages 1..n                       │
│  ┌───────────────────────┼───────────────────┐                │
│  │                       │                   │                │
│  ▼                       ▼                   ▼                │
│ ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │
│ │IptvServerHost│  │IptvServerHost│  │IptvServerHost│         │
│ │  port: 8080  │  │  port: 8081  │  │  port: 8082  │         │
│ │  Kestrel     │  │  Kestrel     │  │  Kestrel     │         │
│ │  M3U/EPG/XC  │  │  M3U/EPG/XC  │  │  M3U/EPG/XC  │         │
│ │  Stream/Image│  │  Stream/Image│  │  Stream/Image│         │
│ │  HubDatabase │  │  HubDatabase │  │  HubDatabase │         │
│ │  (LiteDB)    │  │  (LiteDB)    │  │  (LiteDB)    │         │
│ └──────────────┘  └──────────────┘  └──────────────┘         │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐     │
│  │         Quartz Scheduler                             │     │
│  │         ProviderRefreshJob (per server, on interval) │     │
│  │         Calls → IptvServerHost.RefreshProvidersAsync │     │
│  └─────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────┘

        ▲                          ▲
        │ REST API calls           │ IPTV client requests
        │                          │
 ┌─────────────┐          ┌────────────────────┐
 │ React Web   │          │ IPTV Clients        │
 │ (port 5173  │          │ VLC, TiviMate,      │
 │  dev / 5000 │          │ Perfect Player, etc.│
 │  production)│          └────────────────────┘
 └─────────────┘
```

---

## Data Architecture

### Management Database (`data/management.db`)

Stores the configuration managed by the REST API:

| Collection | Model | Description |
|---|---|---|
| `hub_servers` | `HubServerConfig` | Server instance configs (port, bind, users, linked sources) |
| `iptv_sources` | `IptvSource` | Upstream provider configs (M3U URL, XC credentials) |

### Per-Server Database (`data/{server-id}.db`)

One LiteDB per `IptvServerHost`, populated by `ProviderRefreshJob`:

| Collection | Model | Description |
|---|---|---|
| `live_channels` | `LiveChannel` | Live TV streams with metadata |
| `vod_movies` | `VodMovie` | VOD movies with metadata |
| `series` | `TvSeries` | TV series metadata |
| `categories` | `Category` | Live/VOD/series category groups |
| `epg_programs` | `EpgProgram` | EPG/programme guide entries |
| `cached_images` | `CachedImage` | Binary-cached channel logos, covers |

---

## Management API Endpoints

Base URL: `http://localhost:5000/api`

| Method | Route | Description |
|---|---|---|
| `GET` | `/api/servers` | List all server configs |
| `POST` | `/api/servers` | Create a server config |
| `GET` | `/api/servers/{id}` | Get server config |
| `PUT` | `/api/servers/{id}` | Update server config |
| `DELETE` | `/api/servers/{id}` | Delete server config |
| `POST` | `/api/servers/{id}/start` | Start server instance |
| `POST` | `/api/servers/{id}/stop` | Stop server instance |
| `POST` | `/api/servers/{id}/refresh` | Trigger immediate provider refresh |
| `GET` | `/api/servers/{id}/status` | Get server runtime status |
| `GET` | `/api/sources` | List all IPTV sources |
| `POST` | `/api/sources` | Create an IPTV source |
| `GET` | `/api/sources/{id}` | Get IPTV source |
| `PUT` | `/api/sources/{id}` | Update IPTV source |
| `DELETE` | `/api/sources/{id}` | Delete IPTV source |
| `POST` | `/api/sources/{id}/test` | Test source connectivity |
| `GET` | `/api/status` | System-wide status |
| `GET` | `/api/logs` | Recent log entries |

---

## IPTV Server Endpoints (per server instance)

Base URL: `http://{host}:{port}` (e.g., `http://0.0.0.0:8080`)

| Method | Route | Description |
|---|---|---|
| `GET` | `/` | Version / health check |
| `GET` | `/get.php?type=m3u` | M3U playlist (inline) |
| `GET` | `/get.php?type=m3u_plus` | M3U playlist (download) |
| `GET` | `/get.php?type=m3u_gz` | M3U playlist (gzip) |
| `GET` | `/xmltv.php` | XMLTV EPG (inline) |
| `GET` | `/epg.xml` | XMLTV EPG (download) |
| `GET` | `/epg.xml.gz` | XMLTV EPG (gzip) |
| `GET` | `/player_api.php` | Xtream Codes Player API |
| `GET` | `/panel_api.php` | Xtream Codes Panel API |
| `GET` | `/live/{user}/{pass}/{id}` | Live stream redirect/proxy |
| `GET` | `/timeshift/{user}/{pass}/{dur}/{start}/{id}` | Time-shifted stream |
| `GET` | `/vod/{user}/{pass}/{id}` | VOD stream redirect/proxy |
| `GET` | `/image/{type}/{source}` | Proxied image (logo/cover) |

---

## IPTV Source Types

### M3U Source
- URL to an `.m3u` or `.m3u8` playlist file
- Optional XMLTV EPG URL
- Parsed into channels, VOD, series grouped by category
- Refresh interval configurable

### Xtream Codes Source
- Base URL, username, password
- Uses `/player_api.php` to fetch live/VOD/series categories and streams
- Uses `/xmltv.php` or `/epg.xml` for EPG data
- Full XC API compatibility

### Multiple Sources per Server
Each `HubServerConfig` references N source IDs. On refresh, the `ProviderService` fetches all enabled sources and merges their content into the server's LiteDB:
- Categories are merged (deduplicated by name)
- Channels are merged (each keeps its source prefix in the ID to avoid collisions)
- EPG is merged by `tvg-id`

---

## File Layout at Runtime

```
{ServiceDir}\
├── IptvHub.Service.exe
├── appsettings.json
├── NLog.config
└── data\
    ├── management.db          ← server + source configs
    ├── {server-id}.db         ← per-server content DB (LiteDB)
    └── images\                ← image cache
        └── {hash}.cache
```

---

## Project File Structure

```
src/IptvHub.Service/
├── IptvHub.Service.csproj
├── Program.cs                          ← Host builder, DI, Windows Service
├── appsettings.json
├── NLog.config
│
├── Configuration/
│   └── AppSettings.cs                  ← Strongly-typed config models
│
├── Models/
│   ├── IptvSource.cs                   ← Source definition
│   ├── HubServerConfig.cs              ← Server instance config
│   ├── HubUser.cs                      ← Per-server access credential
│   ├── LiveChannel.cs                  ← Live channel domain model
│   ├── VodMovie.cs                     ← VOD movie domain model
│   ├── TvSeries.cs                     ← TV series domain model
│   ├── Category.cs                     ← Category domain model
│   └── EpgProgram.cs                   ← EPG programme entry
│
├── Data/
│   ├── ManagementDatabase.cs           ← Management LiteDB (servers, sources)
│   └── HubDatabase.cs                  ← Per-server content LiteDB
│
├── Parsers/
│   ├── M3uParser.cs                    ← Parse upstream M3U playlists
│   └── XmlTvParser.cs                  ← Parse upstream XMLTV EPG
│
├── Services/
│   ├── ProviderService.cs              ← Fetch + parse upstream sources
│   ├── M3uService.cs                   ← Generate M3U output
│   ├── EpgService.cs                   ← Generate XMLTV output
│   ├── XtreamService.cs                ← Build XC API responses
│   ├── StreamService.cs                ← Resolve stream URLs
│   └── ImageService.cs                 ← Image proxy / cache
│
├── Jobs/
│   └── ProviderRefreshJob.cs           ← Quartz IJob for scheduled refresh
│
├── Servers/
│   ├── IptvServerHost.cs               ← Per-server ASP.NET Core + Kestrel
│   └── ServerManager.cs                ← Lifecycle management of all servers
│
└── Api/
    └── Controllers/
        ├── ServersController.cs         ← CRUD + lifecycle for server configs
        ├── SourcesController.cs         ← CRUD for IPTV sources
        └── StatusController.cs          ← System status + logs

src/IptvHub.Web/
├── package.json
├── vite.config.ts
├── tsconfig.json
├── tailwind.config.js
├── index.html
└── src/
    ├── main.tsx
    ├── App.tsx
    ├── index.css
    ├── api/
    │   ├── client.ts                    ← Axios base client
    │   └── types.ts                     ← Shared TypeScript types
    ├── pages/
    │   ├── Dashboard.tsx                ← Overview + server status cards
    │   ├── Servers.tsx                  ← Server management
    │   ├── Sources.tsx                  ← IPTV source management
    │   └── Logs.tsx                     ← Log viewer
    └── components/
        ├── Layout.tsx                   ← Shell with sidebar
        ├── Sidebar.tsx                  ← Navigation sidebar
        ├── StatusBadge.tsx              ← Server status indicator
        ├── ServerCard.tsx               ← Server status card
        ├── ServerFormModal.tsx          ← Create/edit server modal
        ├── SourceCard.tsx               ← Source status card
        └── SourceFormModal.tsx          ← Create/edit source modal
```

---

## Implementation Phases

### Phase 1 — Backend Service Core ✅ (scaffold)
- Windows Service host setup
- Configuration + LiteDB management database
- Domain models
- `ServerManager` + `IptvServerHost` skeleton

### Phase 2 — Provider Refresh Pipeline
- M3U parser
- Xtream Codes source fetcher
- XMLTV parser
- `ProviderService` merge logic
- Quartz `ProviderRefreshJob`

### Phase 3 — IPTV Endpoints
- M3U playlist generation
- XMLTV EPG generation
- Xtream Codes Player API + Panel API
- Stream redirect / proxy
- Image proxy / cache

### Phase 4 — Management API
- `ServersController` with start/stop/refresh actions
- `SourcesController` with connectivity test
- `StatusController` with logs

### Phase 5 — React Frontend
- Vite + React + TypeScript + Tailwind scaffold
- API client with TanStack Query
- Dashboard, Servers, Sources, Logs pages

### Phase 6 — Production Hardening
- Windows Service installer / NSSM config
- NLog file targets + rolling
- Startup auto-load of all enabled servers
- Error recovery (provider fetch failures keep existing DB data)
- HTTPS support for management API

---

## Key Design Decisions

1. **Separate Kestrel per server** — Each `IptvServerHost` runs its own `WebApplication` on its configured port. This mirrors the original exactly and avoids port-based routing complexity.

2. **Management API on fixed port** — Port 5000 by default, configurable in `appsettings.json`. Serves the React app in production.

3. **LiteDB as single data store** — One management DB for config, one content DB per server. Embedded, no external DB process.

4. **Quartz for scheduling** — Single scheduler at service level, one `ProviderRefreshJob` per `IptvServerHost` with configurable interval.

5. **Graceful shutdown** — `ServerManager` implements `IHostedService`; on `StopAsync`, all `IptvServerHost` instances are stopped in parallel.

6. **Source merging** — Multiple sources are merged by the `ProviderService`. Category names deduplicated; channel stream IDs prefixed with `{sourceIndex}_` to avoid collisions across sources.

7. **Authentication** — IPTV endpoints validate `username`/`password` against `HubUser` entries in the server config. Management API is local-only (no auth by default; optional JWT in Phase 6).
