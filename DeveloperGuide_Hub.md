# IPTV Hub — Developer Guide

**Version:** 1.1.0  
**Target Framework:** .NET 8 (net8.0-windows)  
**Language:** C# 12 (implicit usings, nullable enabled)  
**Frontend:** React 18 + TypeScript (Vite 5)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Project Structure](#2-project-structure)
3. [Architecture](#3-architecture)
4. [Backend — IptvHub.Service](#4-backend--iptvhubservice)
5. [Management API](#5-management-api)
6. [IPTV Server Endpoints](#6-iptv-server-endpoints)
7. [Request Handlers](#7-request-handlers)
8. [Parsers](#8-parsers)
9. [Frontend — IptvHub.Web](#9-frontend--iptvhubweb)
10. [Data Models](#10-data-models)
11. [Key Dependencies](#11-key-dependencies)
12. [Build & Run](#12-build--run)
13. [Logging](#13-logging)

---

## 1. Overview

IPTV Hub is a self-hosted Windows service that aggregates multiple upstream IPTV sources — M3U playlists, M3U collections, Xtream Codes servers, Plex Media Server, Enigma2 receivers, and YouTube streams — and re-serves them as one or more locally-hosted IPTV servers.

For a consolidated endpoint reference (management + player-facing APIs), see **[IptvHub_API.md](IptvHub_API.md)**.

Two processes cooperate:

| Process | Technology | Role |
|---|---|---|
| **IptvHub.Service** | .NET 8 ASP.NET Core | Management API + background IPTV server host |
| **IptvHub.Web** (dev) | React + Vite (TypeScript) | Browser-based management UI |

In production the frontend is compiled (`npm run build`) and served as static files from the backend's `wwwroot/`. In development, Vite proxies `/api` calls to `http://localhost:5000`.

---

## 2. Project Structure

```
IptvHub.sln
src/
  IptvHub.Service/                  # .NET 8 backend
    Program.cs                      # DI setup, Kestrel config, middleware
    appsettings.json                # NLog + IptvHub settings
    IptvHub.Service.csproj
    Configuration/
      AppSettings.cs                # Strongly-typed config classes
    Data/
      ManagementDatabase.cs         # LiteDB: servers + sources (shared singleton)
      HubDatabase.cs                # LiteDB: per-server content (channels/VOD/EPG/images)
    Models/
      HubServerConfig.cs            # Server configuration document
      IptvSource.cs                 # IPTV source document (all types)
      LiveChannel.cs                # Live channel record
      VodMovie.cs                   # VOD movie record
      TvSeries.cs                   # TV series record
      Category.cs                   # Category record
      EpgProgram.cs                 # EPG programme record
      CachedImage.cs                # Cached image bytes record
      HubUser.cs                    # Per-server user credential
    Api/Controllers/
      StatusController.cs           # GET /api/status
      ServersController.cs          # CRUD /api/servers + start/stop/refresh
      SourcesController.cs          # CRUD /api/sources + test
      EpgController.cs              # GET /api/epg, POST /api/epg/test, GET /api/epg/xmltv
      LogsController.cs             # GET /api/logs
    Servers/
      ServerManager.cs              # Lifecycle manager for all IptvServerHost instances
      IptvServerHost.cs             # Per-server Kestrel host + route registration
      Handlers/
        AuthHelper.cs               # User credential validation
        M3uHandler.cs               # /get.php
        EpgHandler.cs               # /xmltv.php, /epg.xml, /epg.xml.gz
        XtreamHandler.cs            # /player_api.php, /panel_api.php
        StreamHandler.cs            # /live/, /timeshift/, /movie/, /series/
        ImageHandler.cs             # /image/{type}/{source}
    Services/
      ProviderService.cs            # Fetch upstream sources -> populate HubDatabase
      ImageService.cs               # Image download + caching
      ChannelScanner.cs             # Optional link-scan (live/dead check per channel)
      PlexClient.cs                 # Plex Media Server API client
    Parsers/
      M3uParser.cs                  # Parses .m3u / .m3u8 files
      XmlTvParser.cs                # Parses XMLTV EPG files
      Enigma2Parser.cs              # Parses Enigma2 bouquet data
      YoutubeHelper.cs              # Resolves YouTube stream URLs
    Jobs/
      ProviderRefreshJob.cs         # Quartz IJob: scheduled provider refresh
    wwwroot/                        # Production React build (served as static files)

  IptvHub.Web/                      # React + TypeScript frontend
    package.json
    vite.config.ts                  # Proxy: /api -> http://localhost:5000
    src/
      App.tsx                       # React Router routes
      main.tsx                      # Entry point
      api/
        client.ts                   # Axios instance + all API call functions
        types.ts                    # TypeScript interfaces
      components/
        Layout.tsx                  # Shell with sidebar
        Sidebar.tsx                 # Nav: Dashboard, Servers, Sources, EPG, Logs
        StatusBadge.tsx             # Running/Refreshing/Stopped badge
      pages/
        Dashboard.tsx               # Status overview, auto-refresh every 5s
        Servers.tsx                 # Server CRUD, start/stop/refresh
        Sources.tsx                 # Source CRUD + test + Free M3U browser
        Epg.tsx                     # EPG Manager (feed tester + per-server EPG config)
        Logs.tsx                    # Log viewer

installer/
  IptvHub.iss                       # Inno Setup installer script
  build-installer.ps1               # Publishes backend + builds installer
```

---

## 3. Architecture

```
+------------------------------------------------------------------+
|                   IptvHub.Service (port 5000)                    |
|                                                                  |
|  ASP.NET Core (Kestrel)                                          |
|    +- Static files (wwwroot/)  <-- React SPA (production)        |
|    +- /api/status              StatusController                  |
|    +- /api/servers             ServersController                 |
|    +- /api/sources             SourcesController                 |
|    +- /api/epg                 EpgController                     |
|    +- /api/logs                LogsController                    |
|                                                                  |
|  ServerManager owns 0..n IptvServerHost instances                |
|                                                                  |
|  +-----------------------------------------------------------+   |
|  |  IptvServerHost (port N)                                  |   |
|  |  Kestrel (WebApplication.CreateSlimBuilder)               |   |
|  |    +- GET /get.php          M3uHandler                    |   |
|  |    +- GET /xmltv.php        EpgHandler                    |   |
|  |    +- GET /player_api.php   XtreamHandler                 |   |
|  |    +- GET /panel_api.php    XtreamHandler                 |   |
|  |    +- GET /live/...         StreamHandler                 |   |
|  |    +- GET /movie/...        StreamHandler                 |   |
|  |    +- GET /image/...        ImageHandler                  |   |
|  |  HubDatabase (LiteDB) <-- ProviderService                 |   |
|  +-----------------------------------------------------------+   |
|    (one host per server, each on its own port)                   |
|                                                                  |
|  ManagementDatabase (LiteDB)  -- servers + sources              |
|  ProviderService              -- upstream fetch + parse          |
|  ImageService                 -- image download + cache          |
|  Quartz Scheduler             -- ProviderRefreshJob per server   |
+------------------------------------------------------------------+

+------------------------------------------+
|  IptvHub.Web (Vite dev server port 5173)  |
|  React + TypeScript + Tailwind CSS        |---- /api/* ---------->
+------------------------------------------+     (proxy in dev)
```

Key design points:

- The **management API** (port 5000) and each **IPTV server** (port N) are separate Kestrel instances. `IptvServerHost` calls `WebApplication.CreateSlimBuilder()` to spin up a minimal second Kestrel on the user-configured port.
- **`ServerManager`** is a DI singleton owning all `IptvServerHost` instances in a `Dictionary<string, IptvServerHost>` protected by a `SemaphoreSlim(1)`.
- **`ManagementDatabase`** stores server configs and source definitions (one shared file). **`HubDatabase`** stores per-server content (one file per server ID).
- **`ProviderService`** fetches from upstream sources and writes atomically to `HubDatabase` using LiteDB transactions.
- **Quartz** schedules one `ProviderRefreshJob` per running server. The job is DI-resolved and decorated with `[DisallowConcurrentExecution]`.

---

## 4. Backend — IptvHub.Service

### Entry Point & DI Setup

`Program.cs` uses top-level statements:

```csharp
var builder = WebApplication.CreateBuilder(args);

builder.Host.UseWindowsService(options => { options.ServiceName = "IptvHub"; });
builder.Logging.ClearProviders();
builder.Host.UseNLog();

builder.Services.Configure<AppSettings>(builder.Configuration.GetSection("IptvHub"));
builder.Services.AddSingleton<ManagementDatabase>(_ => new ManagementDatabase(managementDbPath));
builder.Services.AddSingleton<ServerManager>();
builder.Services.AddSingleton<ProviderService>();
builder.Services.AddSingleton<ImageService>();
builder.Services.AddHostedService<ServerManagerWorker>(); // starts enabled servers on boot

builder.Services.AddQuartz(q => q.UseInMemoryStore());
builder.Services.AddQuartzHostedService(...);
builder.Services.AddControllers()...;
builder.WebHost.UseUrls(settings.ManagementApi.Host); // default: http://localhost:5000

var app = builder.Build();
app.UseStaticFiles();          // serves React SPA from wwwroot/
app.MapControllers();
app.MapFallbackToFile("index.html"); // SPA fallback routing
await app.RunAsync();
```

### Configuration

`appsettings.json` IptvHub section maps to `AppSettings`:

```csharp
public class AppSettings
{
    public ManagementApiSettings ManagementApi { get; set; }
    // Host (default: http://localhost:5000), EnableSwagger, AllowedOrigins
    public DataSettings Data { get; set; }
    // DataDirectory (default: "data"), ImageCacheDirectory (default: "data/images")
}
```

### Management Database

`ManagementDatabase` wraps `{DataDirectory}/management.db`.

| Collection | Type | Description |
|---|---|---|
| `hub_servers` | `HubServerConfig` | Server configs |
| `iptv_sources` | `IptvSource` | Source definitions |

Both collections have unique indexes on `Id`.

### Server Database (HubDatabase)

`HubDatabase` wraps `{DataDirectory}/{serverId}.db` — one per `IptvServerHost`.

| Collection | Type | Key indexes |
|---|---|---|
| `live_channels` | `LiveChannel` | `StreamId` (unique), `CategoryId`, `TvgId` |
| `vod_movies` | `VodMovie` | `StreamId` (unique), `CategoryId` |
| `series` | `TvSeries` | `SeriesId` (unique), `CategoryId` |
| `categories` | `Category` | `Id`, `Type` |
| `epg_programs` | `EpgProgram` | `ChannelId`, `StartUtc` |
| `cached_images` | `CachedImage` | `SourceUrl` (unique) |

`ReplaceAll*` methods use LiteDB `BeginTrans/Commit/Rollback` for atomic bulk updates.

### ServerManager

DI singleton. Key methods:

| Method | Description |
|---|---|
| `StartAllEnabledAsync(ct)` | Called at startup; starts every server where `IsEnabled=true` |
| `StartServerAsync(id, ct)` | Creates `IptvServerHost`, starts it, registers Quartz job |
| `StopServerAsync(id, ct)` | Stops host, removes Quartz job |
| `RefreshServerAsync(id, ct)` | Delegates to `host.RefreshProvidersAsync()` |
| `GetStatus(id)` | Returns runtime status snapshot for management API |
| `GetRunningHosts()` | Returns all currently listening hosts |
| `IsRunning(id)` | Quick boolean check |

### IptvServerHost

Per-server state + Kestrel + HubDatabase.

| Member | Description |
|---|---|
| `IsListening` | `true` once Kestrel has started |
| `IsLoading` | `true` during a provider refresh |
| `LastRefreshed` | UTC timestamp of last successful refresh |
| `LastError` | Last error string, or `null` |
| `StartAsync(ct)` | Opens DB, builds `WebApplication`, maps routes, starts Kestrel, fires initial refresh |
| `StopAsync(ct)` | Calls `app.StopAsync()` |
| `RefreshProvidersAsync(ct)` | Acquires `_refreshLock`, calls `ProviderService.RefreshAsync()` |
| `GetLiveChannels()` | Snapshot for aggregated EPG |
| `GetEpgPrograms()` | Snapshot for aggregated EPG |
| `UpdateChannelScanStatus(results)` | Writes link-scan results back to LiteDB |

### ProviderService

Stateless singleton. `RefreshAsync(serverConfig, allSources, db, ct)`:

1. Filters to sources linked by `SourceIds` and `IsEnabled=true`.
2. Dispatches by `SourceType`:
   - **M3u** — download + `M3uParser` + optional XMLTV fetch + `XmlTvParser`
   - **M3uCollection** — iterates `CollectionUrls`, each treated as M3u
   - **XtreamCodes** — `player_api.php` calls for categories, live, VOD, series, EPG
   - **Plex** — `PlexClient` for movie/TV libraries
   - **Enigma2** — `Enigma2Parser` for bouquet channel lists
   - **YouTube** — `YoutubeHelper` for stream URL resolution
3. Allocates non-overlapping global numeric IDs per source to avoid collisions.
4. Writes all data atomically to `HubDatabase`.
5. Returns `true` if at least one source succeeded; `false` if all failed (existing data preserved).

### ImageService

Fetches image bytes from upstream (30 s timeout via Flurl.Http) and stores them in `HubDatabase.CachedImages`. Subsequent requests serve cached bytes.

### ProviderRefreshJob (Quartz)

```csharp
[DisallowConcurrentExecution]
public sealed class ProviderRefreshJob : IJob
{
    public async Task Execute(IJobExecutionContext context)
    {
        var serverId = context.JobDetail.JobDataMap.GetString("serverId");
        await _serverManager.RefreshServerAsync(serverId, context.CancellationToken);
    }
}
```

One job per running server. Trigger interval from `HubServerConfig.RefreshIntervalMinutes`. Fires immediately on start (`StartNow()`).

### ChannelScanner

Optional post-refresh scan that tests each live channel URL and marks `LastScanOk=true/false`. Triggered when `HubServerConfig.EnableLinkScan=true`. Results written via `IptvServerHost.UpdateChannelScanStatus()`.

---

## 5. Management API

All routes prefixed `/api/`. Runs on `http://localhost:5000` by default. Swagger UI available at `/swagger` when `EnableSwagger=true`.

### StatusController — `GET /api/status`

Returns system-wide summary: version, serverTime, totalServers, runningServers, totalSources, and runtime status per running host.

### ServersController — `/api/servers`

| Method | Route | Description |
|---|---|---|
| `GET` | `/api/servers` | All server configs + runtime status |
| `GET` | `/api/servers/{id}` | Single server config + status |
| `POST` | `/api/servers` | Create (auto-assigns `Id`) |
| `PUT` | `/api/servers/{id}` | Update; stops + restarts if running |
| `DELETE` | `/api/servers/{id}` | Stop + delete |
| `POST` | `/api/servers/{id}/start` | Start a stopped server |
| `POST` | `/api/servers/{id}/stop` | Stop a running server |
| `POST` | `/api/servers/{id}/refresh` | Force immediate provider refresh |

### SourcesController — `/api/sources`

| Method | Route | Description |
|---|---|---|
| `GET` | `/api/sources` | All sources |
| `GET` | `/api/sources/{id}` | Single source |
| `POST` | `/api/sources` | Create |
| `PUT` | `/api/sources/{id}` | Update; triggers refresh on affected running servers |
| `DELETE` | `/api/sources/{id}` | Delete |
| `POST` | `/api/sources/{id}/test` | Test connectivity |

### EpgController — `/api/epg`

| Method | Route | Description |
|---|---|---|
| `GET` | `/api/epg` | EPG config + programme counts per server |
| `POST` | `/api/epg/test` | Fetch XMLTV URL; returns `{ programCount, channelCount }` or `{ error }` |
| `GET` | `/api/epg/xmltv` | Aggregated XMLTV across all running servers. `?gz=true` for gzip |

The aggregated XMLTV endpoint de-duplicates channels by `tvg-id` across all running servers and collects matching programme entries. Intended for external EPG consumers (Plex, Emby, Jellyfin).

### LogsController — `GET /api/logs`

Query params: `date` (yyyy-MM-dd, defaults to today), `lines` (default 500), `minLevel`. Opens the daily log file with `FileShare.ReadWrite | FileShare.Delete`. Parses log entries via compiled regex; collapses multi-line stack traces onto parent entries.

---

## 6. IPTV Server Endpoints

Each `IptvServerHost` exposes these routes on its own port:

| Method | Route | Description |
|---|---|---|
| `GET` | `/` | Version info JSON |
| `GET` | `/test` | Ping |
| `GET` | `/get.php` | M3U playlist (`type`: m3u / m3u_plus / m3u_gz) |
| `GET` | `/xmltv.php` | XMLTV EPG inline |
| `GET` | `/epg.xml` | XMLTV EPG file download |
| `GET` | `/epg.xml.gz` | XMLTV EPG gzip download |
| `GET` | `/player_api.php` | Xtream Codes player API (if `EnableXtreamApi`) |
| `GET` | `/panel_api.php` | Xtream Codes panel API (if `EnableXtreamApi`) |
| `GET/HEAD` | `/live/{username}/{password}/{filename}` | Live stream |
| `GET/HEAD` | `/timeshift/{username}/{password}/{duration}/{start}/{filename}` | Timeshift |
| `GET/HEAD` | `/movie/{username}/{password}/{filename}` | VOD stream |
| `GET/HEAD` | `/series/{username}/{password}/{filename}` | Series stream |
| `GET` | `/image/{type}/{source}` | Image proxy |

HEAD variants are registered separately for player pre-flight compatibility.

---

## 7. Request Handlers

All handlers are **static classes** called from `IptvServerHost` route delegates.

### AuthHelper
`ValidateUser(config, username, password)` checks credentials against `HubServerConfig.Users`. Empty user list = open server (all credentials accepted).

### M3uHandler
Queries `LiveChannels` ordered by category; emits `#EXTM3U` / `#EXTINF` lines. Stream URLs: `/live/{username}/{password}/{streamId}.ts`. Supports OutputFormat: Browser, TextFile, GZipFile.

### EpgHandler
Queries `LiveChannels` (non-empty `TvgId`) and `EpgPrograms` (matching channel IDs). Serializes to XMLTV using `XmlWriter` with UTF-8 (no BOM). Returns 404 if `EnableEpg=false`.

### XtreamHandler
Implements the Xtream Codes protocol. Dispatches on `action` query parameter:

| `action` | Returns |
|---|---|
| *(none / auth)* | `{ user_info, server_info }` |
| `get_live_categories` | Category array |
| `get_vod_categories` | Category array |
| `get_series_categories` | Category array |
| `get_live_streams` | Live stream array |
| `get_vod_streams` | VOD stream array |
| `get_series` | Series array |
| `get_vod_info` | Single VOD info |
| `get_series_info` | Series + seasons + episodes |

JSON uses `JsonNamingPolicy.SnakeCaseLower`. Panel API returns combined user info + all categories + all stream lists.

### StreamHandler
Resolves `filename` to a `StreamId`, looks up the upstream URL in `HubDatabase`, then either:
- **Redirect** (default): HTTP 302 to upstream URL.
- **Proxy** (`EnableStreamProxy=true`): relays stream bytes to client.

### ImageHandler
Checks `CachedImages` by `SourceUrl`. On miss, fetches from upstream (30 s timeout) and stores in LiteDB. Returns cached bytes with correct `Content-Type`.

---

## 8. Parsers

| Class | Input | Output |
|---|---|---|
| `M3uParser` | M3U/M3U8 text | `List<LiveChannel>` |
| `XmlTvParser` | XMLTV XML text | `List<EpgProgram>` |
| `Enigma2Parser` | Enigma2 bouquet HTTP response | `List<LiveChannel>` |
| `YoutubeHelper` | YouTube URL | Resolved direct stream URL |

---

## 9. Frontend — IptvHub.Web

**Tech stack:** React 18, TypeScript, Vite 5, Tailwind CSS, @tanstack/react-query v5, axios, lucide-react.

### Key files

| File | Purpose |
|---|---|
| `vite.config.ts` | Dev proxy: `/api` -> `http://localhost:5000` |
| `src/api/client.ts` | Axios instance (`baseURL: '/api'`) + typed API functions |
| `src/api/types.ts` | TypeScript interfaces |
| `src/App.tsx` | Routes: `/dashboard`, `/servers`, `/sources`, `/epg`, `/logs` |
| `src/components/Sidebar.tsx` | Nav: Dashboard, Servers, Sources, EPG, Logs |
| `src/pages/Dashboard.tsx` | Status overview; polls `GET /api/status` every 5 s |
| `src/pages/Servers.tsx` | Server CRUD + start/stop/refresh |
| `src/pages/Sources.tsx` | Source CRUD + inline test + Free M3U browser (iptv-org) |
| `src/pages/Epg.tsx` | EPG Manager: ad-hoc tester + per-server config + free EPG picker |
| `src/pages/Logs.tsx` | Log viewer with level filter and date picker |

### API client pattern
```typescript
const api = axios.create({ baseURL: '/api', headers: { 'Content-Type': 'application/json' } })

export const getSources = (): Promise<IptvSource[]> => api.get('/sources').then(r => r.data)
export const createSource = (s: Partial<IptvSource>): Promise<IptvSource> =>
  api.post('/sources', s).then(r => r.data)
```

React Query manages all server state:
```typescript
const { data } = useQuery({ queryKey: ['sources'], queryFn: getSources })
```
Mutations use `useMutation` with `queryClient.invalidateQueries` on success.

### Free M3U browser (Sources page)
`FREE_M3U_SOURCES` — ~110 compile-time entries across 7 regions pointing to `raw.githubusercontent.com/iptv-org/iptv/master/streams/{code}.m3u`. `FreeM3uPicker` is a searchable, grouped panel. For **M3u** sources it single-selects and closes; for **M3uCollection** it multi-selects (toggle, stays open).

### Free EPG picker (EPG page)
`FREE_EPG_SOURCES` — 70+ curated XMLTV feed URLs (epgshare01.online, mjh.nz). `FreeEpgPicker` passes the selected URL to the ad-hoc tester or the per-server EPG feed editor.

---

## 10. Data Models

### HubServerConfig (key fields)

```csharp
string Id, Name, BindAddress
int Port, RefreshIntervalMinutes
bool IsEnabled, EnableEpg, EnableXtreamApi, EnableStreamProxy, EnableLinkScan, ServeWorkingChannelsOnly
List<string> SourceIds
List<HubUser> Users
List<EpgFeed> EpgFeeds
List<EpgChannelMap> EpgChannelMaps
```

### IptvSource (key fields)

```csharp
string Id, Name
SourceType Type  // M3u | M3uCollection | XtreamCodes | Plex | Enigma2 | YouTube
bool IsEnabled
int RefreshIntervalMinutes
// M3u:       M3uUrl, EpgUrl
// Collection: List<string> CollectionUrls
// Xtream:    XtreamBaseUrl, XtreamUsername, XtreamPassword
// Plex:      PlexUrl, PlexToken, List<string> PlexLibraryIds
// Enigma2:   Enigma2Url, Enigma2Username, Enigma2Password, Enigma2StreamPort, List<string> Enigma2BouquetIds
```

---

## 11. Key Dependencies

### Backend

| Package | Version | Purpose |
|---|---|---|
| `Microsoft.Extensions.Hosting.WindowsServices` | 8.0.0 | Windows Service hosting |
| `Swashbuckle.AspNetCore` | 6.6.2 | Swagger UI |
| `LiteDB` | 5.0.21 | Embedded NoSQL document database |
| `Quartz` | 3.8.1 | Job scheduling |
| `Quartz.Extensions.Hosting` | 3.8.1 | Quartz + IHostedService |
| `Flurl.Http` | 4.0.2 | Upstream source HTTP fetching |
| `NLog` | 5.3.4 | Structured logging |
| `NLog.Web.AspNetCore` | 5.3.14 | NLog + ASP.NET Core integration |

### Frontend

| Package | Purpose |
|---|---|
| `react` / `react-dom` 18 | UI framework |
| `typescript` 5.x | Type safety |
| `vite` 5.4.21 | Build tool and dev server |
| `@tanstack/react-query` 5.55.0 | Server state management |
| `axios` | HTTP client |
| `react-router-dom` 6.x | Client-side routing |
| `tailwindcss` 3.x | Utility CSS |
| `lucide-react` | Icon set |

---

## 12. Build & Run

### Development

```powershell
# Terminal 1 — Backend
cd src\IptvHub.Service
dotnet run
# Management API: http://localhost:5000
# Swagger UI:     http://localhost:5000/swagger

# Terminal 2 — Frontend
cd src\IptvHub.Web
npm install
npm run dev
# UI: http://localhost:5173
```

### Production publish

```powershell
# Build frontend into backend wwwroot
cd src\IptvHub.Web
npm run build
# Output: src/IptvHub.Service/wwwroot/

# Publish self-contained backend
cd src\IptvHub.Service
dotnet publish -c Release -r win-x64 --self-contained true -o C:\IptvHub
```

### Windows Service

```powershell
sc.exe create "IptvHub" binPath= "C:\IptvHub\IptvHub.Service.exe" start= auto DisplayName= "IPTV Hub"
sc.exe description "IptvHub" "Self-hosted IPTV aggregation service"
sc.exe start "IptvHub"
```

### Installer

`installer/build-installer.ps1` runs `dotnet publish` then compiles `IptvHub.iss` with Inno Setup to produce a standard Windows installer.

---

## 13. Logging

---

## 14. Threading Model

The runtime mixes async coordination and lock-based data protection by service. Keep this map up to date when adding concurrency-sensitive code.

| Service / Component | Primitive | Protected Scope | Notes |
|---|---|---|---|
| `ServerManager` | `SemaphoreSlim(1,1)` | Host lifecycle mutations (`start/stop/refresh`) | Single mutation lane for `_hosts` dictionary and per-server host transitions. |
| `HubDatabase` | `ReaderWriterLockSlim` | LiteDB read/write critical sections for per-server content | Bulk replace operations run under write lock; stream/read paths use read lock. |
| `StreamHandler` | `ConcurrentDictionary` + CAS (`TryUpdate`) | Active source/user/session counters and session registries | Per-user/source limits and active-session snapshots are lock-free and contention-safe. |
| `ManagementSessionStore` | `ConcurrentDictionary` + background cleanup worker | Session token lifecycle and expiration cleanup | Sliding-expiry updates use compare-and-swap; cleanup loop is cancellation-aware. |
| `SseService` | `ConcurrentDictionary` | Subscriber registry | Subscription/unsubscription is idempotent and keyed by client id. |

Concurrency guardrails:

- Do not mutate shared collections outside their owning primitive.
- Prefer bounded background loops with `CancellationToken` propagation.
- For new external I/O loops, use `ExternalIoPolicy` and keep retry behavior idempotency-aware.

NLog is configured in `appsettings.json` under the `NLog` key.

| Target | Pattern | Notes |
|---|---|---|
| `logfile` | `logs/iptvhub-{shortdate}.log` | Daily rotation, 14 files retained |
| `logconsole` | Colored console | Dev-time only |

Rules:
- `Microsoft.*` and `System.*` — max level `Warn` (suppress ASP.NET Core verbosity).
- All other loggers — min level `Debug`, written to both targets.

To change log verbosity: edit the `minLevel` on the `*` rule in `appsettings.json` and restart.

Each class:
```csharp
private static readonly Logger Log = LogManager.GetCurrentClassLogger();
```
