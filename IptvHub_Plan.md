# IPTV Hub — Feature Roadmap

> Based on codebase analysis of v1.0.2. Features are grouped by implementation effort.  
> Several Tier 1 items already have model fields or structural hooks in place.

---

## Tier 1 — Quick Wins

### 1. Enforce `HubUser.MaxConnections` per user

`HubUser.MaxConnections` exists in the model but `StreamHandler` never checks it.  
Mirrors the `MaxConcurrentStreams` pattern already implemented for sources:
add a `ConcurrentDictionary<string, int>` keyed by username, return **HTTP 429** when the user hits their limit.

**Files:** `Servers/Handlers/StreamHandler.cs`

---

### 2. Active Streams Dashboard widget

In proxy mode, `StreamHandler` holds connections open for the stream's lifetime.  
Track each session in a `ConcurrentBag<StreamSession>` (user, channel name, source, start time, bytes sent).  
Expose via `GET /api/status/streams`. Dashboard shows a live table (auto-refresh every 5 s) with a **Kick** button to abort a session.

**Files:** `Servers/Handlers/StreamHandler.cs`, `Api/Controllers/StatusController.cs`, `IptvHub.Web/src/pages/Dashboard.tsx`

---

### 3. Per-channel overrides (name, logo, group)

New `ChannelOverride` model stored in `ManagementDatabase`:
```
{ ChannelStreamId, ServerConfigId, CustomName?, CustomLogo?, CustomGroup? }
```
Applied at playlist/API generation time in `M3uHandler` and `XtreamHandler`.  
Edit button on each channel row in the channel browser.  
Lets users fix bad M3U metadata without touching the upstream source.

**Files:** `Models/ChannelOverride.cs` *(new)*, `Data/ManagementDatabase.cs`,  
`Servers/Handlers/M3uHandler.cs`, `Servers/Handlers/XtreamHandler.cs`,  
`Api/Controllers/ServersController.cs`, `IptvHub.Web/src/pages/Dashboard.tsx`

---

### 4. Refresh schedule UI

`IptvSource.RefreshIntervalMinutes` exists and `ProviderRefreshJob` reads it, but the UI has no way to view or edit it.  
Expose next-fire time from the Quartz `IScheduler` via a new status endpoint; add interval editing to Sources.tsx.

**Files:** `Api/Controllers/SourcesController.cs`, `Jobs/ProviderRefreshJob.cs`,  
`IptvHub.Web/src/pages/Sources.tsx`

---

### 5. VOD + Series in M3U playlists

`M3uHandler` only emits `LiveChannel`s today.  
Add `?type=vod` and `?type=series` params to `get.php`:

- **VOD** — `group-title` = category name, stream URL `/movie/{user}/{pass}/{id}.mp4`
- **Series** — flatten all episodes; `group-title` = `"{SeriesName} S{N}"`, URL `/series/{user}/{pass}/{episodeId}.ts`

Unlocks non-Xtream players (VLC, Kodi, Infuse) for VOD and series content.

**Files:** `Servers/Handlers/M3uHandler.cs`

---

## Tier 2 — Medium Effort

### 6. EPG auto-matching

After an EPG fetch, fuzzy-match `LiveChannel.TvgId` values to EPG channel IDs using token overlap or normalised edit distance.  
Surface suggestions in the EPG page with a confidence score; user accepts or rejects each mapping.  
New endpoint: `POST /api/epg/suggest-mappings?serverId=...`

**Files:** `Api/Controllers/EpgController.cs`, `IptvHub.Web/src/pages/Epg.tsx`

---

### 7. TMDB metadata enrichment for VOD

M3U-sourced movies and series have no `Plot`, `Cast`, `Rating`, or cover art.  
A new `TmdbService` auto-enriches them as a post-refresh background pass, keying off the title and year.  
Requires a `TmdbApiKey` setting in `appsettings.json` and a Settings page in the UI.

**Files:** `Services/TmdbService.cs` *(new)*, `Configuration/AppSettings.cs`,  
`Services/ProviderService.cs`

---

### 8. Per-user category / channel restrictions

Add `AllowedCategoryIds[]` to `HubUser` (empty list = all categories allowed).  
Filter M3U and Xtream output based on the authenticated user's allowed list.  
Useful for multi-user households (e.g., block certain categories for specific credentials).

**Files:** `Models/HubUser.cs`, `Servers/Handlers/M3uHandler.cs`,  
`Servers/Handlers/XtreamHandler.cs`, `IptvHub.Web/src/pages/Servers.tsx`

---

### 9. Stream analytics

Track per-channel **play count**, **last-played timestamp**, and **error count** in `HubDatabase`.  
`StreamHandler` increments counters on each stream start/failure.  
New endpoint: `GET /api/servers/{id}/analytics?type=top&limit=20`.  
Frontend: "Most Watched" bar chart tab on the Dashboard.

**Files:** `Models/LiveChannel.cs`, `Servers/Handlers/StreamHandler.cs`,  
`Api/Controllers/ServersController.cs`, `IptvHub.Web/src/pages/Dashboard.tsx`

---

## Tier 3 — Higher Effort

### 10. Config backup / restore

`GET /api/backup` — exports the full `ManagementDatabase` (all servers, sources, overrides, EPG feeds, channel maps) as a JSON archive.  
`POST /api/backup/restore` — validates and imports it, enabling migration between machines or Docker volumes.

**Files:** `Api/Controllers/BackupController.cs` *(new)*, `Data/ManagementDatabase.cs`

---

### 11. Push notifications (webhook / SSE)

Notify the admin when a source refresh fails or a channel-scan pass degrades below a threshold.  
Options:
- **Webhook** — POST to a configured URL (Discord, Slack, generic HTTP)
- **SSE** — push events to the admin UI in real time (no polling)

`HubServerConfig` gains `WebhookUrl?` and `NotifyOnRefreshFailure` fields.

**Files:** `Services/NotificationService.cs` *(new)*, `Services/ProviderService.cs`,  
`Models/HubServerConfig.cs`

---

### 12. Server-side time-shift / catchup buffer

`HandleTimeshiftAsync` currently just appends upstream time-shift query params.  
True server-side catchup requires an HLS ring buffer written by an ffmpeg process.  
**High complexity** — adds an ffmpeg dependency; treat as an advanced/opt-in feature gated by a config flag.

**Files:** `Servers/Handlers/StreamHandler.cs`, `Services/TimeshiftBuffer.cs` *(new)*

---

## Notes

| Item | Depends on | Key risk |
|------|-----------|----------|
| 1 (user limits) | — | Coordinate with StreamHandler changes for item 2/9 |
| 2 (active streams) | — | Memory pressure for many concurrent proxied streams |
| 3 (overrides) | — | Cache invalidation when override changes |
| 4 (refresh UI) | — | Quartz API surface differs by version |
| 5 (M3U VOD/series) | — | Low — purely additive to M3uHandler |
| 6 (EPG auto-match) | — | Fuzzy match quality / false positives |
| 7 (TMDB) | Settings page | TMDB rate limits (40 req/10 s free tier) |
| 8 (user restrictions) | — | Auth must be enforced before filtering |
| 9 (analytics) | — | LiteDB write contention at high stream counts |
| 10 (backup) | — | Large databases; consider streaming export |
| 11 (notifications) | — | Webhook security (SSRF risk — validate URLs) |
| 12 (catchup) | ffmpeg | Disk I/O; segment cleanup; upstream compatibility |
