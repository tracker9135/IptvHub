# IPTV Hub — Operational Specification

**Product:** IPTV Hub  
**Version:** 1.1.0  
**Assembly:** `IptvHub.Service.exe`  
**Target Framework:** .NET 8 (net8.0, ASP.NET Core)

---

## Table of Contents

1. [Process Model](#1-process-model)
2. [Startup Sequence](#2-startup-sequence)
3. [Server Lifecycle](#3-server-lifecycle)
4. [HTTP Servers](#4-http-servers)
5. [Management API Reference](#5-management-api-reference)
6. [IPTV Server Endpoint Reference](#6-iptv-server-endpoint-reference)
7. [Xtream Codes API Specification](#7-xtream-codes-api-specification)
8. [Stream Subsystem](#8-stream-subsystem)
9. [Image Subsystem](#9-image-subsystem)
10. [EPG Subsystem](#10-epg-subsystem)
11. [M3U Subsystem](#11-m3u-subsystem)
12. [Provider Refresh Subsystem](#12-provider-refresh-subsystem)
13. [Data Layer (LiteDB)](#13-data-layer-litedb)
14. [Configuration Reference](#14-configuration-reference)
15. [Threading Model](#15-threading-model)
16. [Shutdown Sequence](#16-shutdown-sequence)
17. [Logging](#17-logging)
18. [Error Handling](#18-error-handling)
19. [Runtime File Layout](#19-runtime-file-layout)

---

## 1. Process Model

IPTV Hub runs as a **single Windows process** — either as a Windows Service or a standalone console application (determined by `UseWindowsService()`).

```
IptvHub.Service.exe
  |
  +-- ASP.NET Core (Kestrel, port 5000)     <-- Management API + React SPA
  |     +- /api/status
  |     +- /api/servers
  |     +- /api/sources
  |     +- /api/epg
  |     +- /api/logs
  |     +- /                (React SPA fallback)
  |
  +-- ServerManager
        manages 0..n IptvServerHost instances
        |
        +-- IptvServerHost [port N]          <-- IPTV server A
        |     Kestrel (WebApplication.CreateSlimBuilder)
        |     HubDatabase (LiteDB)
        |
        +-- IptvServerHost [port M]          <-- IPTV server B
              ...
```

- There is **no IPC** between processes. All coordination is in-process via DI singletons.
- Each `IptvServerHost` runs its own embedded Kestrel instance on a user-configured port.
- All Kestrel instances share the same process and thread pool.

---

## 2. Startup Sequence

```
Program.cs [top-level]
  +- WebApplication.CreateBuilder(args)
  +- builder.Host.UseWindowsService()         -- Windows Service support
  +- builder.Host.UseNLog()                   -- NLog integration
  +- Configure DI:
  |    AppSettings, ManagementDatabase, ServerManager,
  |    ProviderService, ImageService, ServerManagerWorker,
  |    Quartz (in-memory store + hosted service),
  |    Controllers, Swagger, CORS
  +- builder.WebHost.UseUrls("http://localhost:5000")
  +- app = builder.Build()
  +- app.UseStaticFiles()                     -- React SPA from wwwroot/
  +- app.MapControllers()
  +- app.MapFallbackToFile("index.html")
  +- await app.RunAsync()
       |
       +- ServerManagerWorker.StartAsync()
            +- ServerManager.StartAllEnabledAsync(ct)
                 for each HubServerConfig where IsEnabled=true:
                   +- IptvServerHost.StartAsync(ct)
                   |    +- Open HubDatabase (LiteDB)
                   |    +- WebApplication.CreateSlimBuilder()
                   |    +- MapRoutes(app)
                   |    +- app.StartAsync(ct)
                   |    +- RefreshProvidersAsync() [fire-and-forget]
                   +- Schedule ProviderRefreshJob in Quartz
```

The initial `RefreshProvidersAsync()` is fire-and-forget. The server accepts connections immediately; data is populated asynchronously. If the refresh fails, the server still listens but serves empty content.

---

## 3. Server Lifecycle

Each `IptvServerHost` has the following runtime state:

```
Created
  |
  v
StartAsync(ct) called
  |
  +- IsLoading = true (during initial refresh)
  +- IsListening = true (Kestrel accepting connections)
  |
  v
RUNNING
  |  (Quartz fires ProviderRefreshJob every RefreshIntervalMinutes)
  |
  +- RefreshProvidersAsync():
  |    IsLoading = true
  |    ProviderService.RefreshAsync() -> HubDatabase updated atomically
  |    IsLoading = false
  |    LastRefreshed = UtcNow
  |
StopAsync(ct) called
  |
  v
STOPPED
  (app.StopAsync, IsListening = false)
```

State properties exposed by `IptvServerHost`:

| Property | Type | Meaning |
|---|---|---|
| `IsListening` | `bool` | Kestrel is accepting connections |
| `IsLoading` | `bool` | Provider refresh in progress |
| `LastRefreshed` | `DateTime?` | Last successful refresh UTC timestamp |
| `LastError` | `string?` | Last error message, or `null` |

`RefreshProvidersAsync` uses a `SemaphoreSlim(1)` lock. Concurrent refresh requests return `false` immediately (the running refresh continues).

---

## 4. HTTP Servers

### Management API (port 5000)

Built with `WebApplication.CreateBuilder()`. Full ASP.NET Core middleware pipeline:

```
Request
  +- CORS middleware (AllowedOrigins from appsettings.json)
  +- Static file middleware (serves React SPA from wwwroot/)
  +- Routing
  +- Controller dispatch (/api/*)
  +- SPA fallback (MapFallbackToFile("index.html"))
```

No authentication is applied to the management API. It is intended for local network or localhost access only. Place behind a reverse proxy with authentication if you need to expose it publicly.

### IPTV Server (port N)

Built with `WebApplication.CreateSlimBuilder()` — minimal footprint, no extra middleware. Route handlers are registered directly via `app.MapGet()` / `app.MapMethods()`.

```
Request
  +- Route matching
  +- Handler delegate (AuthHelper.ValidateUser for XC/M3U routes)
  +- Static handler class (M3uHandler, EpgHandler, XtreamHandler, StreamHandler, ImageHandler)
  +- Response written
```

Auth is per-handler, not middleware. Unauthenticated requests to protected endpoints return `403 Forbidden`. If the server's user list is empty, all credentials are accepted (open server).

---

## 5. Management API Reference

Base URL: `http://localhost:5000` (configurable).

### GET /api/status

No parameters. Returns:

```json
{
  "service": "IptvHub",
  "version": "1.1.0",
  "serverTime": "2026-05-20T10:00:00Z",
  "totalServers": 2,
  "runningServers": 1,
  "totalSources": 4,
  "servers": [
    {
      "id": "8b780036-304b-401e-90f4-76c220a2c80c",
      "name": "MyServer",
      "isListening": true,
      "isLoading": false,
      "lastRefreshed": "2026-05-20T09:55:00Z",
      "lastError": null
    }
  ]
}
```

### GET /api/servers

Returns `[ { config: HubServerConfig, status: ServerStatus } ]` for all servers.

### GET /api/servers/{id}

Returns `{ config, status }` for one server. 404 if not found.

### POST /api/servers

Body: `HubServerConfig` (without `Id` — assigned automatically). Returns `201 Created`.

### PUT /api/servers/{id}

Body: `HubServerConfig`. If server is running, it is stopped and restarted. Returns `200 OK`.

### DELETE /api/servers/{id}

Stops if running, then deletes. Returns `204 No Content`.

### POST /api/servers/{id}/start

Starts a stopped server. Returns `409 Conflict` if already running. Returns current status on `200 OK`.

### POST /api/servers/{id}/stop

Stops a running server. Returns `200 OK`.

### POST /api/servers/{id}/refresh

Triggers immediate provider refresh. Returns `200 OK`.

---

### GET /api/sources

Returns `IptvSource[]`.

### GET /api/sources/{id}

Returns single `IptvSource`. 404 if not found.

### POST /api/sources

Body: `IptvSource` (without `Id`). Returns `201 Created`.

### PUT /api/sources/{id}

Updates source. Triggers async refresh on all running servers that include this source in their `SourceIds`. Returns `200 OK`.

### DELETE /api/sources/{id}

Deletes source. Returns `204 No Content`.

### POST /api/sources/{id}/test

Tests connectivity. Response:

```json
{ "success": true, "channelCount": 1250 }
// or
{ "success": false, "error": "Connection refused" }
```

---

### GET /api/epg

Returns per-server EPG summary:

```json
[
  {
    "serverId": "...",
    "serverName": "MyServer",
    "isRunning": true,
    "programCount": 4820,
    "epgFeeds": [ ... ],
    "epgChannelMaps": [ ... ]
  }
]
```

### POST /api/epg/test

Body: `{ "url": "https://..." }`. Fetches the XMLTV URL (supports `.gz`). Returns:

```json
{ "programCount": 14200, "channelCount": 380 }
// or
{ "error": "Failed to fetch: timeout" }
```

### GET /api/epg/xmltv

Returns an aggregated XMLTV EPG feed from all running servers. Channel de-duplication by `tvg-id`. Parameters:

| Param | Type | Description |
|---|---|---|
| `gz` | `bool` | If `true`, return gzip-compressed output |

Response: `Content-Type: application/xml` (or `application/gzip` if `gz=true`).

This endpoint is intended for external media servers (Plex, Emby, Jellyfin, Kodi) to subscribe to as a single EPG source.

---

### GET /api/logs

Query parameters:

| Param | Default | Description |
|---|---|---|
| `date` | today | Log date in `yyyy-MM-dd` |
| `lines` | 500 | Maximum log entries to return |
| `minLevel` | *(none)* | Filter: DEBUG / INFO / WARN / ERROR / FATAL |

Returns:

```json
{
  "date": "2026-05-20",
  "entries": [
    { "timestamp": "2026-05-20 09:55:00.000", "level": "INFO", "logger": "ProviderService", "message": "..." }
  ]
}
```

---

## 6. IPTV Server Endpoint Reference

All routes relative to `http://{host}:{port}/`. Authentication (when user list is non-empty) uses `username` and `password` query parameters.

| Method | Route | Description |
|---|---|---|
| `GET` | `/` | `{ service, server, version }` |
| `GET` | `/test` | `"OK"` |
| `GET` | `/get.php` | M3U playlist |
| `HEAD` | `/get.php` | Content-Type pre-flight |
| `GET` | `/xmltv.php` | XMLTV EPG (inline) |
| `GET` | `/epg.xml` | XMLTV EPG (file download) |
| `GET` | `/epg.xml.gz` | XMLTV EPG (gzip file download) |
| `GET` | `/player_api.php` | Xtream Codes player API |
| `GET` | `/panel_api.php` | Xtream Codes panel API |
| `GET/HEAD` | `/live/{u}/{p}/{filename}` | Live stream |
| `GET/HEAD` | `/timeshift/{u}/{p}/{duration}/{start}/{filename}` | Timeshift |
| `GET/HEAD` | `/movie/{u}/{p}/{filename}` | VOD stream |
| `GET/HEAD` | `/series/{u}/{p}/{filename}` | Series episode stream |
| `GET` | `/image/{type}/{source}` | Image proxy |

### /get.php parameters

| Param | Values | Description |
|---|---|---|
| `username` | string | Auth username (ignored if no users configured) |
| `password` | string | Auth password |
| `type` | `m3u`, `m3u_plus`, `m3u_gz` | Output format |

`m3u` and `m3u_plus` both return `audio/x-mpegurl` content. `m3u_gz` returns a gzip-compressed attachment.

### M3U line format

```
#EXTM3U
#EXTINF:-1 tvg-id="ChannelId" tvg-name="Channel Name" tvg-logo="http://host:port/image/stream/logo" group-title="Group",Channel Name
http://host:port/live/username/password/12345.ts
```

---

## 7. Xtream Codes API Specification

### Authentication

All XC requests must include `username` and `password` query parameters. Authentication is validated against `HubServerConfig.Users` by `AuthHelper.ValidateUser()`. Returns `403` on failure.

### GET /player_api.php

Dispatches on the `action` query parameter:

| `action` | Returns |
|---|---|
| *(none)* | `{ user_info, server_info }` |
| `get_live_categories` | `[{ category_id, category_name, parent_id }]` |
| `get_vod_categories` | same |
| `get_series_categories` | same |
| `get_live_streams` | `[{ num, name, stream_id, stream_icon, epg_channel_id, ... }]` |
| `get_vod_streams` | `[{ num, name, stream_id, stream_icon, ... }]` |
| `get_series` | `[{ series_id, name, cover, category_id, ... }]` |
| `get_vod_info` | `{ info: {...}, movie_data: {...} }` |
| `get_series_info` | `{ info: {...}, seasons: { "1": [...] }, episodes: { "1": [...] } }` |

Optional `category_id` param on list actions filters to that category.

`ServeWorkingChannelsOnly=true` on the server config filters live streams to those with `LastScanOk=true`.

### GET /panel_api.php

Returns a combined panel response including user_info and all categories and stream lists. Used by panel-based IPTV clients.

### user_info object

```json
{
  "username": "user",
  "password": "pass",
  "status": "Active",
  "exp_date": null,
  "is_trial": "0",
  "active_cons": "0",
  "created_at": "...",
  "max_connections": "0",
  "allowed_output_formats": ["ts"]
}
```

### server_info object

```json
{
  "url": "http://host",
  "port": "8080",
  "https_port": "443",
  "server_protocol": "http",
  "rtmp_port": "1935",
  "timezone": "UTC",
  "timestamp_now": 1716199200,
  "time_now": "2026-05-20 10:00:00"
}
```

### JSON naming

All XC JSON responses use snake_case (`JsonNamingPolicy.SnakeCaseLower`).

---

## 8. Stream Subsystem

### Live stream flow

```
GET /live/{username}/{password}/{filename}
  +- AuthHelper.ValidateUser()
  +- Extract streamId from filename (strip extension)
  +- HubDatabase.LiveChannels.FindOne(c => c.StreamId == streamId)
  +- if EnableStreamProxy:
  |    Download upstream stream bytes, relay to client (pipe)
  +- else:
       HTTP 302 redirect to channel.Url (upstream URL)
```

### Timeshift flow

```
GET /timeshift/{username}/{password}/{duration}/{start}/{filename}
  +- AuthHelper.ValidateUser()
  +- Resolve upstream archive URL
  +- HTTP 302 redirect to archive URL with start/duration appended
```

### VOD / Series flow

Same as live stream, but resolves from `VodMovies` or `Series` collections. Redirect to `VodMovie.StreamUrl` or episode URL.

### HEAD requests

All stream routes have a corresponding HEAD handler that returns `200 OK` with `Content-Type: video/mp2t`. This allows media players to pre-flight before requesting the actual stream.

---

## 9. Image Subsystem

Route: `GET /image/{type}/{source}`

| `type` | Description |
|---|---|
| `stream` | Live channel logo |
| `vod` | VOD movie cover/backdrop |
| `series` | TV series cover/backdrop |

### Flow

```
GET /image/{type}/{source}
  +- HubDatabase.CachedImages.FindOne(i => i.SourceUrl == source)
  +- if found: write cached bytes to response with Content-Type
  +- if not found:
       +- Fetch from source URL (Flurl.Http, 30 s timeout)
       +- Store in CachedImages
       +- Write bytes to response
```

Cache is permanent (no expiry). Images are keyed by `SourceUrl`.

---

## 10. EPG Subsystem

### Per-server EPG (IPTV server endpoints)

Routes: `/xmltv.php`, `/epg.xml`, `/epg.xml.gz`

Returns 404 if `HubServerConfig.EnableEpg = false`.

```
EpgHandler.HandleAsync(ctx, config, db, format)
  +- Query LiveChannels where TvgId != null/empty
  +- Build channelIdSet (HashSet<string>)
  +- Query EpgPrograms where ChannelId in channelIdSet
  +- Build XMLTV XML using XmlWriter (UTF-8, no BOM, no indenting)
  |    <tv generator-info-name="IptvHub">
  |      <channel id="..."><display-name>...</display-name><icon src="..."/></channel>
  |      ...
  |      <programme channel="..." start="YYYYMMDDHHmmss +0000" stop="...">
  |        <title>...</title>
  |        <desc>...</desc>
  |      </programme>
  |      ...
  |    </tv>
  +- OutputFormat:
       Browser  -> Content-Type: application/xml (inline)
       TextFile -> attachment; filename="epg.xml"
       GZipFile -> application/gzip; attachment; filename="epg.xml.gz"
```

### Aggregated EPG (management API)

Route: `GET /api/epg/xmltv`

```
EpgController.GetXmlTv(gz)
  +- ServerManager.GetRunningHosts()
  +- Collect LiveChannels from all hosts, de-dup by TvgId
  +- Collect EpgPrograms from all hosts, filtered to declared channel IDs
  +- BuildAggregatedXmlTv(channels, programs) -> byte[]
  +- if gz=true: GZipStream compress
  +- return file result
```

### EPG data source

EPG data is populated during provider refresh by `ProviderService`:

| Source type | EPG origin |
|---|---|
| M3u | Optional `EpgUrl` field — fetched separately, parsed by `XmlTvParser` |
| M3uCollection | Optional `EpgUrl` on each URL entry |
| XtreamCodes | Provider's built-in `xmltv.php` endpoint |
| Plex | N/A |
| Enigma2 | N/A |
| YouTube | N/A |

Channel matching: `EpgProgram.ChannelId` must match `LiveChannel.TvgId` (case-insensitive).

---

## 11. M3U Subsystem

Route: `GET /get.php`

```
M3uHandler.HandleAsync(ctx, config, db, settings)
  +- AuthHelper.ValidateUser()
  +- Query LiveChannels ordered by CategoryId, then StreamId
  +- if ServeWorkingChannelsOnly: filter to LastScanOk = true
  +- Write #EXTM3U header
  +- For each channel:
  |    Write #EXTINF:-1 tvg-id="..." tvg-name="..." tvg-logo="..." group-title="...",DisplayName
  |    Write http://{host}:{port}/live/{username}/{password}/{streamId}.ts
  +- OutputFormat:
       m3u     -> Content-Type: audio/x-mpegurl (inline)
       m3u_plus -> Content-Type: audio/x-mpegurl (attachment)
       m3u_gz  -> Content-Type: application/gzip (compressed attachment)
```

Stream URL format: `/live/{username}/{password}/{streamId}.ts` — the `.ts` extension is a convention for IPTV player compatibility.

---

## 12. Provider Refresh Subsystem

### Trigger points

| Trigger | Description |
|---|---|
| Server start | Fire-and-forget initial refresh in `IptvServerHost.StartAsync()` |
| Quartz schedule | `ProviderRefreshJob` fires every `RefreshIntervalMinutes` |
| API call | `POST /api/servers/{id}/refresh` |
| Source update | `PUT /api/sources/{id}` triggers refresh on affected servers |

### Refresh flow

```
ServerManager.RefreshServerAsync(serverId, ct)
  +- host.RefreshProvidersAsync(ct)
       +- _refreshLock.WaitAsync(0)  <- returns false if already running
       +- IsLoading = true
       +- ProviderService.RefreshAsync(config, allSources, db, ct)
       |    +- Filter to linked + enabled sources
       |    +- For each source (in order):
       |         M3u        -> FetchM3uSourceAsync()
       |         Collection -> loop FetchM3uSourceAsync() per URL
       |         XtreamCodes -> FetchXtreamSourceAsync()
       |         Plex       -> PlexClient.*
       |         Enigma2    -> Enigma2Parser.*
       |         YouTube    -> YoutubeHelper.*
       |    +- db.ReplaceAllLiveChannels(channels)  [transaction]
       |    +- db.ReplaceAllVodMovies(movies)       [transaction]
       |    +- db.ReplaceAllSeries(series)          [transaction]
       |    +- db.ReplaceAllCategories(categories)  [transaction]
       |    +- db.ReplaceAllEpgPrograms(epg)        [transaction]
       |    +- return anySuccess
       +- LastRefreshed = UtcNow
       +- IsLoading = false
       +- _refreshLock.Release()
```

If `ProviderService.RefreshAsync()` returns `false` (all sources failed), `LastError` is set and existing database content is preserved (no overwrite on failure).

### Quartz job registration

```csharp
IJobDetail job = JobBuilder.Create<ProviderRefreshJob>()
    .WithIdentity("refresh-{serverId}")
    .UsingJobData("serverId", serverId)
    .Build();

ITrigger trigger = TriggerBuilder.Create()
    .WithSimpleSchedule(s => s
        .WithIntervalInMinutes(config.RefreshIntervalMinutes)
        .RepeatForever())
    .StartNow()
    .Build();
```

`[DisallowConcurrentExecution]` prevents overlapping executions of the same job. The Quartz scheduler is in-memory (RAM store) — schedules are not persisted across restarts.

---

## 13. Data Layer (LiteDB)

### Management database: `data/management.db`

Shared singleton. One instance for the whole service.

| Collection | Document type | Unique index |
|---|---|---|
| `hub_servers` | `HubServerConfig` | `Id` |
| `iptv_sources` | `IptvSource` | `Id` |

### Server database: `data/{serverId}.db`

One per server, owned by `IptvServerHost`.

| Collection | Document type | Unique index | Other indexes |
|---|---|---|---|
| `live_channels` | `LiveChannel` | `StreamId` | `CategoryId`, `TvgId` |
| `vod_movies` | `VodMovie` | `StreamId` | `CategoryId` |
| `series` | `TvSeries` | `SeriesId` | `CategoryId` |
| `categories` | `Category` | — | `Id`, `Type` |
| `epg_programs` | `EpgProgram` | — | `ChannelId`, `StartUtc` |
| `cached_images` | `CachedImage` | `SourceUrl` | — |

### Atomic bulk replacement

`ReplaceAll*` methods follow this pattern:

```csharp
_db.BeginTrans();
try
{
    Collection.DeleteAll();
    Collection.InsertBulk(newItems);
    _db.Commit();
}
catch
{
    _db.Rollback();
    throw;
}
```

This ensures that a failed refresh never leaves the database in a partial state.

---

## 14. Configuration Reference

File: `appsettings.json` (alongside the executable)

```json
{
  "IptvHub": {
    "ManagementApi": {
      "Host": "http://localhost:5000",
      "EnableSwagger": true,
      "AllowedOrigins": [ "http://localhost:5173" ]
    },
    "Data": {
      "DataDirectory": "data",
      "ImageCacheDirectory": "data/images"
    }
  },
  "NLog": { ... }
}
```

| Key | Default | Description |
|---|---|---|
| `ManagementApi.Host` | `http://localhost:5000` | Kestrel bind URL for management API |
| `ManagementApi.EnableSwagger` | `true` | Enable Swagger UI at `/swagger` |
| `ManagementApi.AllowedOrigins` | `["http://localhost:5173"]` | CORS allowed origins |
| `Data.DataDirectory` | `data` | Relative path for LiteDB files |
| `Data.ImageCacheDirectory` | `data/images` | Relative path for image cache |

All paths are relative to the executable directory (`AppContext.BaseDirectory`).

In production (Windows Service), set `ManagementApi.EnableSwagger` to `false` and `ManagementApi.AllowedOrigins` to `["http://localhost:5000"]` (or omit CORS entirely if access is local only).

---

## 15. Threading Model

| Thread / pool | Description |
|---|---|
| **ASP.NET Core thread pool** | Handles management API requests (port 5000) |
| **IPTV Kestrel thread pool** | One pool shared across all IptvServerHost instances (port N) |
| **Quartz thread pool** | Executes `ProviderRefreshJob.Execute()` asynchronously |
| **ServerManagerWorker** | `IHostedService`; calls `StartAllEnabledAsync()` on `StartAsync()` and `StopAllAsync()` on `StopAsync()` |

**Key concurrency controls:**

| Control | Protects |
|---|---|
| `SemaphoreSlim(1)` in `ServerManager` | `_hosts` dictionary mutations (start/stop) |
| `SemaphoreSlim(1)` in `IptvServerHost` (`_refreshLock`) | Concurrent refresh calls — only one refresh runs at a time per server |
| `[DisallowConcurrentExecution]` on `ProviderRefreshJob` | Quartz will not start a second execution while one is already running |

`ProviderService.RefreshAsync()` is called from async contexts (Quartz job, API handler) and is fully `async`/`await` throughout.

---

## 16. Shutdown Sequence

```
app.RunAsync() receives cancellation (SIGTERM or sc.exe stop)
  +- IHostedService.StopAsync() called on all hosted services
  +- ServerManagerWorker.StopAsync()
       +- ServerManager.StopAllAsync(ct)
            for each IptvServerHost:
              +- host.StopAsync(ct)       <- app.StopAsync()
              +- host.DisposeAsync()      <- _db.Dispose(), _refreshLock.Dispose()
            _hosts.Clear()
  +- Quartz scheduler shuts down (WaitForJobsToComplete = false)
  +- NLog flushes pending async log entries
  +- Process exits
```

In-flight HTTP requests are given up to the ASP.NET Core shutdown timeout (default 5 seconds for the management API). IPTV Kestrel instances stop accepting new connections immediately; in-flight stream proxies may be interrupted.

---

## 17. Logging

**NLog** is configured in `appsettings.json` under the `NLog` key with `autoReload: true`.

### Targets

| Target | Output | Notes |
|---|---|---|
| `logfile` | `logs/iptvhub-{shortdate}.log` | Async, daily rotation, 14 files retained |
| `logconsole` | Colored console | Useful for dev; suppressed when running as Windows Service |

### Log layout (file)

```
{longdate} [{level:uppercase}] {logger} — {message} {exception:format=tostring}
```

Example:
```
2026-05-20 09:55:01.2345 [INFO] ProviderService — Refreshed 1250 live channels for server 'MyServer'
```

### Log rules

| Logger pattern | Max level | Min level | Targets |
|---|---|---|---|
| `Microsoft.*` | `Warn` | — | logfile, logconsole |
| `System.*` | `Warn` | — | logfile, logconsole |
| `*` | — | `Debug` | logfile, logconsole |

To increase verbosity: change `minLevel` from `Debug` to `Trace` for the `*` rule. To reduce noise: change to `Info` or `Warn`.

---

## 18. Error Handling

| Scenario | Behaviour |
|---|---|
| Provider fetch fails (network error, bad URL) | Logged as `Warn`; existing DB content preserved; `LastError` set; refresh returns `false` |
| All sources fail | `LastError` set; server keeps serving stale content |
| One source in a collection fails | Other sources still processed; partial success counts as `anySuccess = true` |
| Quartz job throws | Logged as `Error`; Quartz re-fires on the next trigger interval |
| Kestrel port already in use | `StartAsync()` throws; logged as `Error`; `IsListening` stays `false`; management API shows error |
| Image fetch times out | Logged as `Warn`; `503` returned to image requests until next successful fetch |
| LiteDB transaction fails | `Rollback()` called; existing data preserved; exception re-thrown and logged |

---

## 19. Runtime File Layout

```
IptvHub.Service.exe          <- main executable
appsettings.json             <- configuration
wwwroot/                     <- React SPA (production build)
  index.html
  assets/
    index-*.js
    index-*.css

data/
  management.db              <- server configs + source definitions
  {serverId}.db              <- per-server content (one per server)
  images/                    <- image cache (if using file-based caching)

logs/
  iptvhub-2026-05-20.log     <- today's log
  iptvhub-2026-05-19.log
  ...                        <- up to 14 daily log files
```

Paths are relative to `AppContext.BaseDirectory` (the directory containing `IptvHub.Service.exe`). The `data/` and `data/images/` directories are created automatically at startup if they do not exist.
