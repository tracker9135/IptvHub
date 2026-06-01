# UpdateResults10.md — Extensive EPG Review: Optimizations & New Logic

*Date: 2026-05-31 | Status: Review complete — 16 findings across 4 sprints*

---

## 1. Scope

This review extends the EPG work from UpdateResults9 with a full read-through of:

| File | Purpose |
|---|---|
| `ProviderService.cs` | Scheduled refresh: fetches feeds, merges programmes |
| `XmlTvParser.cs` | Parses XMLTV XML into `EpgProgram` objects |
| `HubDatabase.cs` | LiteDB layer: indexes, query methods |
| `EpgHandler.cs` | Builds XMLTV output, in-memory cache |
| `EpgController.cs` | Management API: download, timeline, drift, mappings |
| `IptvServerHost.cs` | `MergeEpgPrograms`, per-server host state |
| `XtreamHandler.cs` | Xtream API: `get_short_epg`, `get_simple_data_table` |
| `SourceIngestionService.cs` | HTTP fetch, SD auth, SD programme cache |
| `EpgImportManagerService.cs` | Enigma2/EPGImport push pipeline |
| `EpgFeed.cs`, `EpgProgram.cs` | Models |

---

## 2. EPG Data Flow (Current Architecture)

```
Upstream Feeds
  ├─ M3U / Xtream Codes EPG URL (per-source)
  │    └─ SourceIngestionService.FetchXmlTvContentAsync()
  │         └─ XmlTvParser.Parse()
  │              └─→ SourceFetchResult.Epg  ─────────────────┐
  │                                                            │
  ├─ Standalone EpgFeeds (XMLTV URL or Schedules Direct)      │
  │    └─ SourceIngestionService.Fetch{XmlTv|SchedDir}()      │
  │         └─ XmlTvParser.Parse() / SD API                   │
  │              └─ TryMergeEpgProgram()  ────────────────────┤
  │                                                            │
  └─ Manual download (EpgController.DownloadFeed)             │
       └─ XmlTvParser.Parse()                                 │
            └─ IptvServerHost.MergeEpgPrograms()  ────────────┘
                                                              │
                                           HubDatabase.EpgPrograms (LiteDB)
                                                              │
                              ┌───────────────────────────────┤
                              │                               │
                        EpgHandler                     XtreamHandler
                       /iptvhub.xmltv              get_short_epg
                     (5-min cached                 get_simple_data_table
                      XMLTV bytes)
```

Three separate code paths feed into the same `EpgPrograms` LiteDB collection:
- **Full refresh path** (`ProviderService`) — replaces all programmes atomically via `ReplaceAllEpgPrograms`.
- **Manual download path** (`EpgController` → `IptvServerHost.MergeEpgPrograms`) — appends new programmes, never replaces.
- **Source EPG inline** (M3U `url-tvg`, Xtream Codes `/xmltv.php`) — collected alongside channel list; merged into the full-refresh batch.

---

## 3. Bug Findings

### B5 — `TryMergeEpgProgram` (ProviderService) drops episode metadata on update

**Severity: Medium | File: `ProviderService.cs` ~line 478**

The scheduled-refresh merge enrichment fills gaps in `Title`, `Description`, `Category`, `IconUrl`, and `Language` when a lower-priority feed has richer data. It does **not** fill `SubTitle`, `EpisodeNumXmltvNs`, or `EpisodeNumOnScreen`.

```csharp
// Current — only 5 fields enriched on update:
if (string.IsNullOrWhiteSpace(existing.Title) && !string.IsNullOrWhiteSpace(incoming.Title))
    { existing.Title = incoming.Title; changed = true; }
if (string.IsNullOrWhiteSpace(existing.Description) && !string.IsNullOrWhiteSpace(incoming.Description))
    { existing.Description = incoming.Description; changed = true; }
if (string.IsNullOrWhiteSpace(existing.Category) && !string.IsNullOrWhiteSpace(incoming.Category))
    { existing.Category = incoming.Category; changed = true; }
if (string.IsNullOrWhiteSpace(existing.IconUrl) && !string.IsNullOrWhiteSpace(incoming.IconUrl))
    { existing.IconUrl = incoming.IconUrl; changed = true; }
if (string.IsNullOrWhiteSpace(existing.Language) && !string.IsNullOrWhiteSpace(incoming.Language))
    { existing.Language = incoming.Language; changed = true; }
// SubTitle, EpisodeNumXmltvNs, EpisodeNumOnScreen — silently skipped
```

**Impact:** When a higher-priority feed provides only a title and a lower-priority feed provides the full episode number (`S02E03`), the episode metadata is never stored. The XMLTV output and Xtream EPG banner show the programme title only, without series/episode identifiers. Plex, Tivimate, and EPGImport all use episode numbers for series management.

**Fix — add three fields to `TryMergeEpgProgram`:**
```csharp
if (string.IsNullOrWhiteSpace(existing.SubTitle) && !string.IsNullOrWhiteSpace(incoming.SubTitle))
    { existing.SubTitle = incoming.SubTitle; changed = true; }
if (string.IsNullOrWhiteSpace(existing.EpisodeNumXmltvNs) && !string.IsNullOrWhiteSpace(incoming.EpisodeNumXmltvNs))
    { existing.EpisodeNumXmltvNs = incoming.EpisodeNumXmltvNs; changed = true; }
if (string.IsNullOrWhiteSpace(existing.EpisodeNumOnScreen) && !string.IsNullOrWhiteSpace(incoming.EpisodeNumOnScreen))
    { existing.EpisodeNumOnScreen = incoming.EpisodeNumOnScreen; changed = true; }
```

---

### B6 — XMLTV output includes all past programmes with no time-window filter

**Severity: Medium | File: `EpgHandler.cs` ~line 150**

`BuildXmlTv` calls `FindEpgProgramsByChannelIds` with no start/stop filter. Every programme ever stored for the channel set is emitted, including ones that aired days ago.

```csharp
// Current — no time bounds:
var programs = db.FindEpgProgramsByChannelIds(lookupIds);
```

**Impact:**
- For a 14-day feed with 500 channels × 20 shows/day the XMLTV payload is ~140 k entries. After 7 days, half are past. Players parse all of it, but only use the future half.
- After repeated manual downloads (which append, never replace) old programmes accumulate indefinitely. The XMLTV file grows unboundedly until the next full scheduled refresh wipes them.
- 5-minute cached bytes are proportionally larger, increasing memory pressure.

**Fix — add a time window to `BuildXmlTv`:**
```csharp
var fromUtc = DateTime.UtcNow.AddHours(-1);   // include current programme
var toUtc   = DateTime.UtcNow.AddDays(14);    // 14-day look-ahead max
var programs = db.FindEpgProgramsByChannelIdsInWindow(lookupIds, fromUtc, toUtc);
```

`FindEpgProgramsByChannelIdsInWindow` already exists in `HubDatabase` and is used by the timeline and Xtream handlers.

---

### B7 — XMLTV output may include duplicate programmes for dual-storage channels

**Severity: Low | File: `EpgHandler.cs` `BuildXmlTv`**

When channel maps are added after an initial feed download, the database temporarily contains programmes stored under BOTH the external channel ID (from the first download) AND the local TvgId (from subsequent refreshes). `BuildXmlTv` includes both IDs in `lookupIds` and emits all matching programmes without deduplication. A player sees the same time slot listed twice for the same channel.

The dual-storage design is intentional for robustness, but the output path must deduplicate.

**Fix — add dedup by `(channelId, StartUtc)` after remapping:**
```csharp
var seen = new HashSet<(string, DateTime)>();
foreach (var prog in programs)
{
    var localId = externalToLocal.TryGetValue(prog.ChannelId, out var m) ? m : prog.ChannelId;
    if (!seen.Add((localId, prog.StartUtc))) continue;
    // ... emit programme
}
```

---

## 4. Performance Findings

### P1 — `GetEpgChannelIds` full-table scan

**File: `ServerManager.cs` ~line 370**

```csharp
public IReadOnlyList<string> GetEpgChannelIds(string serverId)
{
    // ...
    return host.GetEpgPrograms()          // ← loads ALL EpgPrograms from DB
               .Select(p => p.ChannelId)
               .Distinct()
               .ToList();
}
```

`host.GetEpgPrograms()` calls `_db.EpgPrograms.FindAll().ToList()` — a full table load into memory. For a server with 500 k programmes this instantiates a very large object graph just to get distinct channel IDs. This is called from `EpgController.GetChannelIds` (auto-suggest), `EpgController.SuggestMappings`, `EpgController.DebugEpg`, and `EpgImportManagerService.SuggestMappings`.

**Fix — add a dedicated method to `HubDatabase` that queries only the `ChannelId` field:**
```csharp
// HubDatabase
public IReadOnlyList<string> GetDistinctEpgChannelIds()
    => WithReadLock(() =>
        EpgPrograms.Query()
            .Select(p => p.ChannelId)
            .ToList()
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList());
```

LiteDB does not support `GROUP BY` in LINQ, but projecting a single field is far cheaper than deserialising full `EpgProgram` objects.

---

### P2 — EPG feeds processed sequentially during scheduled refresh

**File: `ProviderService.cs` ~line 158**

```csharp
foreach (var feed in serverConfig.EpgFeeds
    .OrderByDescending(f => f.Priority) ...)
{
    // fetch + parse + merge — one at a time
}
```

Sources are already fetched in parallel via `BoundedConcurrency.SelectAsync`. EPG feeds are not. A server with three XMLTV feeds each requiring 30 s adds 90 s to the refresh cycle. All feeds are independent; their results are merged after the fact.

**Fix — fetch all feeds concurrently then merge in priority order:**
```csharp
var feedFetchResults = await BoundedConcurrency.SelectAsync(
    serverConfig.EpgFeeds
        .OrderByDescending(f => f.Priority)...
        .Select((feed, i) => (feed, i)).ToList(),
    maxConcurrency: 4,
    async (item, token) =>
    {
        // fetch & parse feed, return (index, programs, feed)
    },
    ct);

// merge in priority order
foreach (var r in feedFetchResults.OrderBy(r => r.Index))
    MergeFeedPrograms(r.Programs, r.Feed, ...);
```

---

### P3 — Double XML parse: content parse + display-name parse

**File: `ProviderService.cs` ~lines 202–212 / `EpgController.cs` ~lines 478–480**

```csharp
var xmlContent = await _sourceIngestion.FetchXmlTvContentAsync(feed.Url!, ct, label);
feedPrograms = XmlTvParser.Parse(xmlContent);              // ← DOM parse #1
var displayNames = XmlTvParser.ParseChannelDisplayNames(xmlContent); // ← DOM parse #2
```

`ParseChannelDisplayNames` creates a second `XmlDocument` from the same string. For a 30 MB XMLTV feed this doubles parse time and peak memory. The existing `ParseWithDom` method already walks the DOM — it should simultaneously collect `<channel>` display names in the same pass.

**Fix — add a combined parse method:**
```csharp
public static (List<EpgProgram> Programs, Dictionary<string, List<string>> ChannelDisplayNames)
    ParseWithChannelNames(string xmlContent)
```
Return both results from a single DOM walk, eliminating the second parse.

---

### P4 — `MergeEpgPrograms` (manual download) loads entire EPG table into memory

**File: `IptvServerHost.cs` ~line 175**

```csharp
var all = _db.EpgPrograms.FindAll().ToList();   // entire table
var seen = new HashSet<(string ChannelId, DateTime StartUtc)>(
    all.Select(p => (p.ChannelId, p.StartUtc)));
```

Loading the full EPG table into memory before a manual feed download means a server with 200 k programmes allocates ~60 MB of objects for every manual download operation. The `seen` HashSet is the minimum needed; the full `all` list is needed only because `ReplaceAllEpgPrograms` requires a complete list.

**Optimization — use a DB-side existence check instead:**
Rather than loading the full table to build `seen`, query only the `(ChannelId, StartUtc)` pair for the incoming batch:

```csharp
// Build the dedup set only from the channel IDs present in the incoming batch
var incomingChannels = programs.Select(p => p.ChannelId).ToHashSet(StringComparer.OrdinalIgnoreCase);
var existing = _db.FindEpgProgramsByChannelIds(incomingChannels);
var seen = existing.Select(p => (p.ChannelId, p.StartUtc)).ToHashSet();
```

Then use `db.InsertBulk` for genuinely new programmes instead of a full replace, preserving existing data without a full round-trip.

---

### P5 — Schedules Direct callsign alias doubles programme count

**File: `SourceIngestionService.cs` ~line 1130 (FetchSchedulesDirectAsync)**

For every SD programme, an alias copy is emitted under the channel's callsign:
```csharp
// Emit alias under callsign so tvg-id="KABC" channels match automatically
if (stationCallsigns.TryGetValue(schedule.StationID!, out var callsign) ...)
{
    lineupResults.Add(new EpgProgram { ChannelId = callsign, ... });
}
```

For a 14-day SD feed with 200 stations × 40 shows/day, this generates 2 × 200 × 14 × 40 = **224 000 extra programmes**. The database doubles in size; XMLTV and Xtream queries load twice as many rows.

**Alternative — resolve callsign at query time rather than at ingest time:**
Store programmes only under the numeric stationID. When building `lookupIds` for XMLTV/Xtream queries, include the callsign → stationID reverse mapping so both IDs resolve to the same programmes. This halves EPG storage with no loss of match capability.

---

## 5. New Logic / Feature Gaps

### F1 — No content rating field on `EpgProgram`

**Severity: Medium | Impact: Tivimate, Plex, DVR recording rules**

Both XMLTV (`<rating system="MPAA"><value>TV-PG</value></rating>`) and Schedules Direct (`contentRating`) provide content advisories. The `EpgProgram` model has no `Rating` property. Players that respect parental controls (Tivimate, Emby) cannot show age ratings in their EPG banners.

**Proposal:**
```csharp
// EpgProgram.cs
/// <summary>Content advisory string, e.g. "TV-PG", "TV-MA", "PG-13".</summary>
public string? Rating { get; set; }
```

Parser additions:
- **XmlTvParser:** `<rating><value>TV-PG</value></rating>` → `prog.Rating = "TV-PG"`
- **SD ingest:** `program.ContentRating?.FirstOrDefault()?.Code` → `Rating`
- **EpgHandler XMLTV output:** emit `<rating system="MPAA"><value>TV-PG</value></rating>`
- **XtreamHandler:** expose in EPG listings JSON (Xtream uses a plain `rating` string field)

---

### F2 — No `IsNew` / `IsPremiere` flag on `EpgProgram`

**Severity: Low-Medium | Impact: DVR scheduling, UI badges**

Schedules Direct exposes `new`, `premiere`, and `live` flags per programme. These are used by:
- **Tivimate** "NEW" badge in the guide grid
- **DVR rule matching** — "only record new episodes" is the most common DVR preference
- **Series recording rules** — `RecordSeries` currently matches by title only; it would benefit from filtering to `IsNew = true`

**Proposal:**
```csharp
// EpgProgram.cs
public bool IsNew { get; set; }
public bool IsPremiere { get; set; }
public bool IsLive { get; set; }
```

SD source: `scheduledProgram.New`, `scheduledProgram.Premiere`, `scheduledProgram.LiveTapeDelay == "Live"`.  
XMLTV: `<premiere>` element.

---

### F3 — No star rating / quality rating on `EpgProgram`

**Severity: Low | Impact: Guide grid quality indicators**

XMLTV `<star-rating>` and SD `qualityRating` / `contentRating[].qualityRating` provide a numeric quality score. Tivimate displays stars in the programme info panel.

**Proposal:**
```csharp
/// <summary>Quality rating normalised to 0–1 (e.g. 0.7 = 3.5/5 stars).</summary>
public float? StarRating { get; set; }
```

---

### F4 — No automatic pruning of past EPG programmes

**Severity: Medium | Impact: DB growth, XMLTV size, query performance**

`ReplaceAllEpgPrograms` keeps the database clean after every scheduled refresh. However:
- Manual downloads via `MergeEpgPrograms` only add; they never prune.
- `ReplaceAllEpgPrograms` itself keeps all programmes from the just-fetched feeds, including those that aired since the last refresh (typically 4–6 h).

Over time (many manual downloads, long refresh intervals) the database accumulates significant past data. For a 14-day feed refreshed every 6 hours, after 7 days there are 3.5 days of expired entries in every batch.

**Proposal — prune in `ReplaceAllEpgPrograms`:**
```csharp
public void ReplaceAllEpgPrograms(IEnumerable<EpgProgram> programs, DateTime? pruneBeforeUtc = null)
{
    var cutoff = pruneBeforeUtc ?? DateTime.UtcNow.AddHours(-2);
    var filtered = programs.Where(p => p.StopUtc >= cutoff);
    // ... existing replace logic with filtered
}
```

**And in `MergeEpgPrograms`:**
```csharp
// After insert, delete programmes whose StopUtc < cutoff:
_db.EpgPrograms.DeleteMany(p => p.StopUtc < DateTime.UtcNow.AddHours(-2));
```

---

### F5 — XMLTV response cache TTL is hardcoded and non-configurable

**File: `EpgHandler.cs` line 17**

```csharp
private static readonly TimeSpan CacheTtl = TimeSpan.FromMinutes(5);
```

5 minutes is a reasonable default but:
- A user refreshing EPG manually wants the XMLTV to update immediately (B2 fix handles explicit invalidation — this is about the TTL for background rebuilds).
- Larger deployments might prefer 15–30 minutes to reduce CPU spent rebuilding multi-MB XMLTV payloads.
- Smaller deployments or testing scenarios might want 0 (no cache).

**Proposal — expose as a configurable field on `HubServerConfig`:**
```csharp
// HubServerConfig.cs
/// <summary>Minutes to cache the XMLTV response. 0 disables caching. Default 5.</summary>
public int EpgCacheMinutes { get; set; } = 5;
```

Pass through `config.EpgCacheMinutes` in `EpgHandler.HandleAsync` to replace the hardcoded constant.

---

### F6 — XMLTV gzip route missing `ETag` / conditional GET support

**File: `EpgHandler.cs` `HandleAsync`, `OutputFormat.GZipFile` branch**

The plain XML routes (`/iptvhub.xmltv`, `/xmltv.php`, etc.) already implement `ETag` + `If-None-Match` for conditional GET (304 Not Modified). The gzip route (`/epg.xml.gz`) writes the content but does not set the `ETag` header:

```csharp
case OutputFormat.GZipFile:
    ctx.Response.ContentType = "application/gzip";
    // ← no ETag / conditional GET check
    using (var gz = new GZipStream(...))
        await gz.WriteAsync(xmlBytes);
```

Players that poll `/epg.xml.gz` on a schedule download the full file every time even when EPG data has not changed, wasting bandwidth.

**Fix — apply the same conditional-GET logic before the switch:**
```csharp
if (ctx.Request.Headers.IfNoneMatch.Contains(etag))
{
    ctx.Response.StatusCode = StatusCodes.Status304NotModified;
    return;
}
ctx.Response.Headers.ETag = etag;
ctx.Response.Headers.LastModified = cache.GetGeneratedAt().ToString("R");
```
(move these two lines outside the `cache != null` guard so they apply to all formats including gzip.)

---

### F7 — `RecordSeries` / `RecordSeriesOngoing` cannot filter to new episodes only

**File: `EpgController.cs`**

Series recording rules match by title and channel. When a channel airs a series that has both new episodes and reruns in the EPG window, all matching programmes are scheduled. Most users want to record new episodes only.

**Proposal — add `NewEpisodesOnly` flag to the request model and filter in `ExpandSeriesRecordingRules`:**

```csharp
// EpgRecordSeriesRequest / EpgRecordSeriesOngoingRequest
public bool NewEpisodesOnly { get; set; }

// In ExpandSeriesRecordingRules — add filter:
if (req.NewEpisodesOnly)
    candidates = candidates.Where(p => p.IsNew).ToList();
```

This requires F2 (`IsNew` flag on `EpgProgram`) to be implemented first.

---

### F8 — Timeline API response missing `nowPlaying` field

**File: `EpgController.cs` `GetTimelinePrograms` ~line 155**

```csharp
.Select(t => new
{
    channelId   = t.effectiveChannelId,
    title       = t.p.Title,
    description = t.p.Description,
    category    = t.p.Category,
    iconUrl     = t.p.IconUrl,
    startUtc    = t.p.StartUtc,
    stopUtc     = t.p.StopUtc
    // ← no nowPlaying flag
})
```

The frontend must compute `isNowPlaying` client-side from `startUtc`/`stopUtc` and re-compute it when time advances. Adding a server-computed `nowPlaying` boolean (evaluated at query time) simplifies the frontend and ensures server-clock accuracy.

**Proposal:**
```csharp
var nowUtc = DateTime.UtcNow;
.Select(t => new
{
    // ... existing fields
    nowPlaying  = t.p.StartUtc <= nowUtc && t.p.StopUtc > nowUtc
})
```

---

## 6. All Findings — Master Reference

| ID | Category | Sev | Sprint | File(s) | Description | Status |
|---|---|---|---|---|---|---|
| B5 | Bug | Med | 1 | `ProviderService.cs` | `TryMergeEpgProgram` drops SubTitle + episode numbers | **Done** |
| B6 | Bug | Med | 1 | `EpgHandler.cs` | XMLTV output has no time-window filter (past programmes accumulate) | **Done** |
| B7 | Bug | Low | 1 | `EpgHandler.cs` | Duplicate programmes in XMLTV for dual-storage channels | **Done** |
| F8 | Feature | Low | 1 | `EpgController.cs` | Timeline API missing `nowPlaying` field | **Done** |
| F6 | Feature | Low | 1 | `EpgHandler.cs` | XMLTV gzip route missing ETag / conditional GET | **N/A — all routes pass `_epgCache`; 304 check already applies to gzip** |
| P1 | Perf | High | 2 | `ServerManager.cs`, `HubDatabase.cs` | `GetEpgChannelIds` full table load just for distinct IDs | **Done** |
| P2 | Perf | High | 2 | `ProviderService.cs` | EPG feeds fetched sequentially, not in parallel | **Done** |
| P3 | Perf | Med | 2 | `ProviderService.cs`, `EpgController.cs` | XMLTV parsed twice per download (content + display names) | **Done** |
| F4 | Feature | Med | 2 | `HubDatabase.cs`, `IptvServerHost.cs` | No automatic past-programme pruning | **Done** |
| F1 | Feature | Med | 3 | `EpgProgram.cs`, parsers, handlers | No content rating field (TV-PG / TV-MA) | **Done** |
| F2 | Feature | Med | 3 | `EpgProgram.cs`, parsers | No IsNew / IsPremiere / IsLive flags | **Done** |
| F3 | Feature | Low | 3 | `EpgProgram.cs`, parsers | No star rating field | **Done** |
| F7 | Feature | Low | 3 | `EpgController.cs` | Series recording cannot filter to new episodes only (needs F2) | **Done** |
| F5 | Feature | Low | 4 | `EpgHandler.cs`, `HubServerConfig` | XMLTV cache TTL hardcoded (non-configurable) | **Done** |
| P5 | Perf | Med | 4 | `SourceIngestionService.cs` | SD callsign alias doubles programme count in DB | **Done** |
| P4 | Perf | Med | 4 | `IptvServerHost.cs` | Manual merge loads entire EPG table into RAM | **Done** |

---

## 7. Sprint Plan

---

### Sprint 1 — Correctness Fixes *(no model changes, low risk)*

**Goal:** Eliminate data loss and output errors with purely additive, minimal-scope changes.  
**Estimated effort:** ~1 h total  
**Files touched:** `ProviderService.cs`, `EpgHandler.cs`, `EpgController.cs`

| # | ID | Task | Effort | Files |
|---|---|---|---|---|
| 1 | B5 | Add `SubTitle`, `EpisodeNumXmltvNs`, `EpisodeNumOnScreen` to `TryMergeEpgProgram` | 6 lines | `ProviderService.cs` |
| 2 | B6 | Change `FindEpgProgramsByChannelIds` → `FindEpgProgramsByChannelIdsInWindow(fromUtc=-1h, toUtc=+14d)` in `BuildXmlTv` | 2 lines | `EpgHandler.cs` |
| 3 | B7 | Add `(localId, StartUtc)` HashSet dedup to `BuildXmlTv` programme loop | 8 lines | `EpgHandler.cs` |
| 4 | F8 | Add `nowPlaying = startUtc <= nowUtc && stopUtc > nowUtc` to timeline response projection | 1 line | `EpgController.cs` |
| 5 | F6 | Move `ETag` + `If-None-Match` 304 check outside the format switch so the gzip route benefits | 4 lines | `EpgHandler.cs` |

**Acceptance criteria:**
- XMLTV output does not contain entries with `stop` in the past (beyond 1 h grace).
- No duplicate `<programme>` elements for any channel in the XMLTV output.
- Episode numbers appear in XMLTV when the lower-priority feed has them and the higher-priority feed does not.
- `GET /epg.xml.gz` returns `304 Not Modified` with a matching `If-None-Match` header.
- `GET /api/epg/timeline` includes a `nowPlaying` field on each programme.

---

### Sprint 2 — Performance Fixes *(no model changes, medium risk)*

**Goal:** Reduce memory pressure and refresh time for large deployments.  
**Estimated effort:** ~3 h total  
**Files touched:** `HubDatabase.cs`, `ServerManager.cs`, `ProviderService.cs`, `SourceIngestionService.cs`, `XmlTvParser.cs`, `IptvServerHost.cs`

| # | ID | Task | Effort | Files |
|---|---|---|---|---|
| 1 | P1 | Add `GetDistinctEpgChannelIds()` to `HubDatabase` using field-projection query; update `ServerManager.GetEpgChannelIds` and all 4 call sites | ~30 min | `HubDatabase.cs`, `ServerManager.cs` |
| 2 | P2 | Wrap EPG feed loop in `BoundedConcurrency.SelectAsync` (max 4); merge results in priority order after all fetch tasks complete | ~45 min | `ProviderService.cs` |
| 3 | P3 | Add `XmlTvParser.ParseWithChannelNames()` returning `(List<EpgProgram>, Dictionary<string,List<string>>)` from a single DOM walk; replace both call sites | ~60 min | `XmlTvParser.cs`, `ProviderService.cs`, `EpgController.cs` |
| 4 | F4 | Add optional `pruneBeforeUtc` parameter to `ReplaceAllEpgPrograms`; add `DeleteMany(p => p.StopUtc < cutoff)` after merge in `MergeEpgPrograms` | ~30 min | `HubDatabase.cs`, `IptvServerHost.cs` |

**Acceptance criteria:**
- `GetEpgChannelIds` does not instantiate `EpgProgram` objects; verified by profiling or log timing.
- A server with 3 EPG feeds completes all three downloads concurrently; total refresh time ≤ slowest single feed + overhead.
- `ProviderService` makes exactly one `Parse()` call and one `ParseChannelDisplayNames()` equivalent per feed, not two separate DOM parses.
- After a `MergeEpgPrograms` call, no entries with `StopUtc < UtcNow - 2h` remain in the database.

---

### Sprint 3 — Data Model Enrichment *(additive model fields, schema version bump)*

**Goal:** Add content rating, new/premiere/live flags, and star rating to `EpgProgram`; wire through all layers.  
**Estimated effort:** ~6 h total  
**Files touched:** `EpgProgram.cs`, `XmlTvParser.cs`, `SourceIngestionService.cs`, `EpgHandler.cs`, `XtreamHandler.cs`, `EpgController.cs`, `HubDatabase.cs`

| # | ID | Task | Effort | Files |
|---|---|---|---|---|
| 1 | F1 | Add `string? Rating` to `EpgProgram`; parse `<rating><value>` in XmlTvParser; read SD `contentRating[0].code`; emit `<rating>` in EpgHandler XMLTV; expose in Xtream EPG listings | ~2 h | `EpgProgram.cs`, `XmlTvParser.cs`, `SourceIngestionService.cs`, `EpgHandler.cs`, `XtreamHandler.cs` |
| 2 | F2 | Add `bool IsNew`, `bool IsPremiere`, `bool IsLive` to `EpgProgram`; parse XMLTV `<premiere>` / `<live>`; read SD `scheduledProgram.New`, `.Premiere`, `.LiveTapeDelay`; emit `<new>` / `<premiere>` / `<live>` in XMLTV output | ~2 h | `EpgProgram.cs`, `XmlTvParser.cs`, `SourceIngestionService.cs`, `EpgHandler.cs` |
| 3 | F3 | Add `float? StarRating` to `EpgProgram` (0–1 normalised); parse XMLTV `<star-rating>`; read SD `qualityRating`; emit `<star-rating>` in XMLTV output | ~1 h | `EpgProgram.cs`, `XmlTvParser.cs`, `SourceIngestionService.cs`, `EpgHandler.cs` |
| 4 | F7 | Add `bool NewEpisodesOnly` to `EpgRecordSeriesRequest` and `EpgRecordSeriesOngoingRequest`; filter candidates in `ExpandSeriesRecordingRules` by `p.IsNew` when flag is true | ~1 h | `EpgController.cs` |

**Migration note:** LiteDB is schema-flexible; new fields default to `null`/`false` on existing rows automatically. No explicit migration required. Bump `CurrentSchemaVersion` in `HubDatabase` to document the change.

**Acceptance criteria:**
- XMLTV output for a SD feed includes `<rating system="MPAA"><value>TV-PG</value></rating>` on programmes where SD provides a rating.
- XMLTV output includes `<new/>` on new episodes from both SD and XMLTV sources.
- Xtream `get_short_epg` and `get_simple_data_table` responses include a `rating` field.
- `POST /api/epg/record-series` with `newEpisodesOnly: true` only schedules recordings for `IsNew == true` programmes.
- `StarRating` serialised correctly (0–1 float); `<star-rating><value>3.5/5</value></star-rating>` round-trips through parse → store → emit.

---

### Sprint 4 — Configuration & Deep Optimizations *(medium risk, careful testing)*

**Goal:** Make the cache configurable, eliminate SD programme doubling, and make manual merges memory-efficient.  
**Estimated effort:** ~4 h total  
**Files touched:** `HubServerConfig.cs`, `EpgHandler.cs`, `SourceIngestionService.cs`, `IptvServerHost.cs`, `HubDatabase.cs`

| # | ID | Task | Effort | Files |
|---|---|---|---|---|
| 1 | F5 | Add `int EpgCacheMinutes { get; set; } = 5` to `HubServerConfig`; thread it through `IptvServerHost` → `EpgHandler.HandleAsync` replacing the hardcoded constant | ~30 min | `HubServerConfig.cs`, `IptvServerHost.cs`, `EpgHandler.cs` |
| 2 | P5 | Remove callsign alias programme duplication from `FetchSchedulesDirectAsync`; instead extend `BuildEpgLookupIds` (in `XtreamHandler`) and the lookup-set builders in `EpgHandler` and `EpgController` to also include `stationID → callsign` reverse mapping at query time | ~2 h | `SourceIngestionService.cs`, `XtreamHandler.cs`, `EpgHandler.cs`, `EpgController.cs` |
| 3 | P4 | Refactor `MergeEpgPrograms` to load only programmes for the incoming channels (`FindEpgProgramsByChannelIds(incomingChannels)`) instead of the full table; use `InsertBulk` for new entries rather than a full replace | ~45 min | `IptvServerHost.cs`, `HubDatabase.cs` |

**Notes for P5 (SD callsign aliasing):**
This is the highest-risk change. The current approach stores duplicate rows to guarantee XMLTV/Xtream matches work correctly for all channel naming conventions (numeric stationID vs. callsign tvg-id). Moving this resolution to query time requires:
1. Persisting the stationID → callsign mapping durably (already done in `SdStationMetadata`).
2. Updating every lookup-set builder (`BuildEpgLookupIds`, `EpgHandler.BuildXmlTv`, `EpgController.GetTimelinePrograms`, `EpgController.DetectDrift`) to expand lookups with the callsign equivalent.
3. Verifying that channels using callsign tvg-ids still show EPG in all player paths.

Recommend implementing P5 last and behind a feature flag initially.

**Acceptance criteria:**
- `EpgCacheMinutes = 0` on a server config disables caching; every XMLTV request rebuilds live.
- `EpgCacheMinutes = 15` on a server config causes the cache to hold for 15 minutes.
- SD feed with 200 stations stores ≤ 200 unique channel IDs in `EpgPrograms` (not 400).
- Channels using either stationID or callsign tvg-id still display EPG correctly in XMLTV and Xtream endpoints.
- `MergeEpgPrograms` for a 5 k programme feed does not load the full EPG table into RAM; peak allocation scales with the incoming batch size, not total programme count.

---

## 8. Data Flow — After All Sprints Applied

```
XMLTV Output (EpgHandler.BuildXmlTv):
  ┌─ lookup programmes: fromUtc=-1h, toUtc=+14d      (S1:B6)
  ├─ remap externalId → localId
  ├─ deduplicate by (localId, StartUtc)               (S1:B7)
  └─ emit: title, sub-title, desc, category,
           episode-num (xmltv_ns + onscreen),
           icon, rating, new/premiere/live, star-rating (S3:F1-F3)

Scheduled Refresh (ProviderService):
  ┌─ fetch all feeds concurrently (bounded 4)         (S2:P2)
  ├─ parse: content + display names in one pass       (S2:P3)
  ├─ merge in priority order:
  │    fill Title, Desc, Category, IconUrl, Language,
  │    SubTitle, EpisodeNumXmltvNs, EpisodeNumOnScreen (S1:B5)
  └─ replace: prune past programmes (stopUtc < -2h)   (S2:F4)

Xtream EPG:
  ┌─ get_short_epg: now → +3d, limit N               (done)
  ├─ get_simple_data_table: today → +7d               (done)
  └─ listings: base64 title/desc, timestamps,
               now_playing, rating                     (S3:F1)

Timeline API:
  └─ nowPlaying field added to every programme        (S1:F8)

Cache:
  └─ TTL driven by HubServerConfig.EpgCacheMinutes    (S4:F5)
     gzip route honours ETag / 304                    (S1:F6)
```

---

## 9. Notes on LiteDB Compound Index Limitation

(Carried forward from UpdateResults9.)

LiteDB does not support compound indexes (channelId + startUtc). `FindEpgProgramsByChannelIdsInWindow` therefore:
1. Uses the `ChannelId` index to retrieve all rows for the channel.
2. Filters `StopUtc > fromUtc && StartUtc < toUtc` in-memory via LINQ `.Where()`.

The `StartUtc` index exists but is never used because LiteDB cannot apply both indexes in one query. For servers with >500 k total programmes across many channels, the per-channel query is still fast because the channel index is selective (typically 100–5000 rows per channel). The real risk is the **XMLTV path** (B6) which queries all channels without a time filter — fixing B6 converts the no-time-window `FindEpgProgramsByChannelIds` call to the windowed variant and eliminates the worst-case load.
