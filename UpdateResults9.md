# UpdateResults9 — EPG Data Flow: Feed → Xtream Codes Player (Deep Review)

**Date:** 2025-07  
**Scope:** End-to-end trace of how EPG programme data travels from an external feed URL into a playing IPTV client that connects via the Xtream Codes API.

---

## 1. Executive Summary

IptvHub serves EPG data to Xtream Codes players **indirectly**: the Xtream API itself only returns a channel's `epg_channel_id` field; all actual programme schedule data is served through a separate XMLTV endpoint. Players must be configured to use both the Xtream API (for channel list) and the XMLTV URL (for guide data).

**Four bugs were found** in the current codebase that affect this path:

| # | Location | Severity | Description | Status |
|---|----------|----------|-------------|--------|
| B1 | `IptvServerHost.MergeEpgPrograms` | Medium | `SubTitle`, `EpisodeNumXmltvNs`, `EpisodeNumOnScreen` not copied when merging new programmes | ✅ Fixed |
| B2 | `EpgController` (both download paths) | Medium | EPG response cache not invalidated after manual download — stale XMLTV served for ≤5 min | ✅ Fixed |
| B3 | `M3uHandler` | Low | `#EXTM3U` header lacks `url-tvg`/`x-tvg-url` — players cannot auto-discover EPG URL | ✅ Fixed |
| B4 | `XtreamHandler` | Informational | `get_short_epg` / `get_simple_data_table` actions not implemented — inline EPG popup broken in many players | ✅ Fixed |

**Implementation status (2025-07):** All four bugs listed below have been fixed. See Section 9 for the exact code changes applied.

---

## 2. Architecture Overview

```
External Feed (XMLTV URL / Schedules Direct)
         │
         ▼
  ProviderService.RefreshAsync()          ← scheduled (Quartz) + startup
  EpgController /download[-queued]        ← manual
         │
         │  XmlTvParser.Parse() → List<EpgProgram>
         │  channelMap (ExternalId → LocalTvgId) applied during ingest
         │
         ▼
  HubDatabase.EpgPrograms                 ← LiteDB collection per server
         │
         ├── EpgHandler (XMLTV output)    ← /iptvhub.xmltv, /xmltv.php, /epg.xml[.gz]
         │        └── EpgResponseCache (5-min TTL)
         │
         └── XtreamHandler               ← /player_api.php, /panel_api.php
                  └── get_live_streams → epg_channel_id = c.TvgId (only hook)
                       (get_short_epg / get_simple_data_table → NOT IMPLEMENTED)
```

---

## 3. Stage 1: Feed Download & Parsing

### 3.1 Scheduled Refresh Path (`ProviderService.RefreshAsync`)

**Trigger:** Quartz job `ProviderRefreshJob` → `IptvServerHost.RefreshProvidersAsync` → `ProviderService.RefreshAsync`  
**File:** `Services/ProviderService.cs`

1. For each `EpgFeed` on the server (ordered by Priority desc):
   - **Throttle check:** If `MinDownloadIntervalMinutes` set and not enough time has passed, the feed is skipped (existing DB programmes are kept).
   - **Download:**
     - `XmlTv` type → `FetchXmlTvContentAsync(feed.Url)` (supports `.gz` auto-decompression)
     - `SchedulesDirect` type → `FetchSchedulesDirectAsync()`
   - **Parse:** `XmlTvParser.Parse(xmlContent)` → `List<EpgProgram>`
   - **Channel display name metadata:** `XmlTvParser.ParseChannelDisplayNames()` → upserted into `ManagementDatabase.XmlTvChannelMeta` (used by the EPG channel browser)
   - **Channel ID mapping:** For each `prog`, if `channelMap` contains `prog.ChannelId`, it is rewritten to the local TvgId _in-place_ (`prog.ChannelId = localId`).
   - **Source channel filter:** If the feed is assigned to specific sources (`EpgFeedIds`), programmes whose (mapped) channel is not in any of those sources' TvgId sets are discarded.
   - **Deduplication:** `TryMergeEpgProgram` — (channelId, startUtc) composite key. New entries are appended; existing entries get their empty fields patched from the incoming programme.
2. After all feeds processed: `db.ReplaceAllEpgPrograms(allEpg)` — atomic delete+insert inside a LiteDB transaction.

**What `TryMergeEpgProgram` merges on enrichment (existing + incoming):**
- Title, Description, Category, IconUrl, Language ✅
- SubTitle, EpisodeNumXmltvNs, EpisodeNumOnScreen — **NOT merged** (B1 partial; scheduled path adds them on new insert but never patches existing)

### 3.2 Manual Download Path (`EpgController.DownloadFeed` / `QueueDownloadFeed`)

**File:** `Api/Controllers/EpgController.cs`

- Same download + parse logic as 3.1.
- Calls `host.MergeEpgPrograms(feedPrograms, maps)` (additive, not replace).
- **Bug B1:** `IptvServerHost.MergeEpgPrograms` creates new `EpgProgram` instances copying only:
  ```csharp
  new EpgProgram
  {
      ChannelId = channelId,
      StartUtc = program.StartUtc,
      StopUtc = program.StopUtc,
      Title = program.Title,
      Description = program.Description,
      Category = program.Category,
      Language = program.Language,
      IconUrl = program.IconUrl
      // SubTitle missing
      // EpisodeNumXmltvNs missing
      // EpisodeNumOnScreen missing
  }
  ```
  Any programme added via a manual download loses subtitle and episode number fields. These only work when the initial ingest came through the scheduled `ProviderService` path.
- **Bug B2:** Neither `DownloadFeed` nor `QueueDownloadFeed` calls `host.InvalidateEpgCache()` after `MergeEpgPrograms` succeeds. The XMLTV response cache (5-min TTL) is left stale. Players fetching `/iptvhub.xmltv` within 5 minutes of a manual download see the old data.

### 3.3 `XmlTvParser.Parse` Field Mapping

| XMLTV attribute/element | `EpgProgram` field |
|-------------------------|-------------------|
| `@channel` | `ChannelId` |
| `@start` | `StartUtc` (converted to UTC) |
| `@stop` | `StopUtc` (converted to UTC) |
| `<title>` | `Title` |
| `<title @lang>` | `Language` |
| `<sub-title>` | `SubTitle` |
| `<desc>` | `Description` |
| `<category>` | `Category` |
| `<icon @src>` | `IconUrl` |
| `<episode-num system="xmltv_ns">` | `EpisodeNumXmltvNs` |
| `<episode-num system="onscreen">` | `EpisodeNumOnScreen` |

The parser uses DOM for well-formed XML and falls back to streaming `XmlReader` for malformed/huge payloads. Both paths populate all fields listed above.

---

## 4. Stage 2: Database Storage

**File:** `Data/HubDatabase.cs`

- Collection: `epg_programs` (LiteDB)
- Indexes:
  - `EpgPrograms.EnsureIndex(x => x.ChannelId)` — used by all EPG queries
  - `EpgPrograms.EnsureIndex(x => x.StartUtc)` — present but **not used in compound queries**
- Replace operation: `ReplaceAllEpgPrograms` wraps `DeleteAll` + `InsertBulkInChunks` in a LiteDB transaction with `WithWriteLock`.

### 4.1 Query: `FindEpgProgramsByChannelIds`

Used by `EpgHandler` for XMLTV output (full programme set, no time filter):

```csharp
foreach (var channelId in ids)
    results.AddRange(EpgPrograms.Find(p => p.ChannelId == channelId));
```

- Hits the `ChannelId` index. One query per channel.
- **Deduplication uses `StringComparer.Ordinal`** but the caller (`EpgHandler`) passes an `OrdinalIgnoreCase` HashSet. If two IDs differ only by case, both survive dedup in the caller but collide during `Ordinal` dedup inside the database helper. In practice EPG channel IDs are consistent case, so this is theoretical.

### 4.2 Query: `FindEpgProgramsByChannelIdsInWindow`

Used by the IptvHub management API (timeline grid):

```csharp
var channelPrograms = EpgPrograms.Find(p => p.ChannelId == channelId)
    .Where(p => p.StopUtc > fromUtc && p.StartUtc < toUtc);
```

- The `ChannelId` index narrows the candidate set; the time-window filter runs **in-memory (LINQ)** after the index lookup.
- The separate `StartUtc` index is not used here because LiteDB does not support compound index queries. For channels with dense EPG (thousands of programmes), this loads all programmes for the channel then filters, which is inefficient for large guide data.

---

## 5. Stage 3: Serving to the Xtream Codes Player

### 5.1 The Xtream Codes API (`player_api.php`, `panel_api.php`)

**File:** `Servers/Handlers/XtreamHandler.cs`

The handler routes on the `action` query parameter:

| `action` value | Implemented | Notes |
|----------------|-------------|-------|
| `get_live_categories` | ✅ | Returns category list |
| `get_vod_categories` | ✅ | |
| `get_series_categories` | ✅ | |
| `get_live_streams` | ✅ | Returns `epg_channel_id` field |
| `get_vod_streams` | ✅ | |
| `get_series` | ✅ | |
| `get_vod_info` | ✅ | |
| `get_series_info` | ✅ | |
| `get_short_epg` | ❌ | Falls to default → returns only user_info + server_info |
| `get_simple_data_table` | ❌ | Falls to default → returns only user_info + server_info |
| _(any other)_ | — | Default: user_info + server_info |

**Bug B4:** `get_short_epg` and `get_simple_data_table` are the standard Xtream Codes endpoints for:
- `get_short_epg` — "What's on now / next" for a given `stream_id` (used by players for the channel info banner)
- `get_simple_data_table` — Full EPG schedule for a given `stream_id` (used by players' built-in EPG grid)

When players call these endpoints they receive a response shaped like a login reply, not EPG data. The player's built-in guide and now/next banner show nothing.

**The only EPG hook in `get_live_streams`:**

```csharp
epg_channel_id = c.TvgId,
```

This tells the player which XMLTV channel ID corresponds to this stream. The player uses this to correlate data it fetches from a separately configured XMLTV EPG URL.

### 5.2 Xtream Codes Live Stream URL Format

```
GET /live/{username}/{password}/{streamId}.ts
```

The `streamId` is the integer `LiveChannel.StreamId` — a provider-assigned ID, not the TvgId.

### 5.3 How Players Actually Get EPG Data

For a player using Xtream Codes to display guide data, the complete sequence is:

1. Player calls `GET /player_api.php?action=&username=…&password=…` → receives user_info + server_info
2. Player calls `GET /player_api.php?action=get_live_streams` → receives channel list including `epg_channel_id` per channel
3. Player is separately configured with the EPG URL (e.g. `http://host:port/iptvhub.xmltv`)
4. Player fetches XMLTV from that URL → gets `<channel id="…">` + `<programme channel="…">` elements
5. Player matches `epg_channel_id` from step 2 to `<channel id>` from step 4
6. Programme data is displayed

**This means EPG display in an Xtream Codes player requires two separate configurations: the Xtream API URL and the XMLTV EPG URL.**

---

## 6. Stage 4: XMLTV Output (`EpgHandler`)

**File:** `Servers/Handlers/EpgHandler.cs`  
**Routes:** `GET /iptvhub.xmltv`, `/xmltv.php`, `/xmltv.xmltv`, `/epg.xml`, `/epg.xml.gz`

### 6.1 Channel ID Resolution (Dual-Storage Handling)

`BuildXmlTv` constructs an `externalToLocal` dictionary that covers both storage scenarios:

```
Scenario A: Programme stored under external channel ID (before maps were configured)
  externalToLocal[extId] = localTvgId

Scenario B: Programme stored under local TvgId (ProviderService rewrote ChannelId during ingest)
  externalToLocal[localTvgId] = localTvgId
```

The union of all keys becomes `lookupIds` which is passed to `FindEpgProgramsByChannelIds`. Each returned programme's `ChannelId` is re-tagged to the local TvgId before being written into `<programme channel="…">`, so the output always uses the same IDs as the M3U `tvg-id` attributes.

### 6.2 Response Cache

```csharp
private static readonly TimeSpan CacheTtl = TimeSpan.FromMinutes(5);
private readonly Handlers.EpgResponseCache _epgCache = new();
```

- Cache is per `IptvServerHost` instance.
- Supports ETag + `If-None-Match` conditional GET → 304 Not Modified.
- **Invalidated:** After every successful full provider refresh (`ServerManager` line 262).
- **NOT invalidated:** After a manual EPG download via `EpgController` — **Bug B2**.

### 6.3 Output Formats

| Route | Format | Content-Type |
|-------|--------|-------------|
| `/iptvhub.xmltv` | Browser (inline) | `application/xml` |
| `/xmltv.php` | Browser (inline) | `application/xml` |
| `/xmltv.xmltv` | Browser (inline) | `application/xml` |
| `/epg.xml` | Download | `application/xml` + Content-Disposition |
| `/epg.xml.gz` | GZip download | `application/gzip` + Content-Disposition |

---

## 7. Stage 5: M3U Playlist and EPG URL Discovery

**File:** `Servers/Handlers/M3uHandler.cs`  
**Route:** `GET /get.php`

The M3U header line:
```
#EXTM3U
```

Each channel entry:
```
#EXTINF:-1 tvg-id="BBC One" tvg-name="BBC One" tvg-logo="…" group-title="Entertainment",BBC One
http://host:port/live/user/pass/1001.ts
```

**Bug B3:** The `#EXTM3U` line does not include `url-tvg` or `x-tvg-url`. Many IPTV players (Tivimate, IPTV Smarters, GSE Smart IPTV) can auto-discover the EPG URL from this attribute. Without it, users must manually enter the XMLTV URL in the player.

The correct format would be:
```
#EXTM3U url-tvg="http://host:port/iptvhub.xmltv" x-tvg-url="http://host:port/iptvhub.xmltv"
```

The `tvg-id` field (`c.TvgId`) in each `#EXTINF` line must exactly match the `id` attribute of the corresponding `<channel>` element in the XMLTV output. The EpgHandler ensures this by re-tagging programme entries to local TvgIds before XML emission.

---

## 8. Complete End-to-End Data Flow Diagram

```
[XMLTV Feed URL / SchedulesDirect API]
           │
           │ HTTP GET (+ gz decompression if needed)
           ▼
    SourceIngestionService
           │
           │ XmlTvParser.Parse() → List<EpgProgram>
           │   EpgProgram { ChannelId, StartUtc, StopUtc,
           │                Title, SubTitle, Description,
           │                Category, Language, IconUrl,
           │                EpisodeNumXmltvNs, EpisodeNumOnScreen }
           │
           │ Channel map: ExternalChannelId → LocalTvgId (rewrite prog.ChannelId)
           │ Source channel filter (if feed tied to specific sources)
           │
           ├─[Scheduled]──► TryMergeEpgProgram → allEpg
           │                  └─► db.ReplaceAllEpgPrograms(allEpg)  ← atomic
           │                              │
           │                  host.InvalidateEpgCache() ✅
           │
           └─[Manual]─────► IptvServerHost.MergeEpgPrograms(programs, maps)
                              (additive merge, NOT replace)
                              ⚠ Drops SubTitle, EpisodeNum fields (Bug B1)
                              ⚠ Does NOT call InvalidateEpgCache() (Bug B2)
                              └─► db.ReplaceAllEpgPrograms(merged)

LiteDB: epg_programs collection
  Index: ChannelId (used for all lookups)
  Index: StartUtc  (present, unused in time-window queries)
           │
           │
   ┌───────┴────────────────────────────────────────┐
   │                                                │
   ▼                                                ▼
EpgHandler (/iptvhub.xmltv etc.)         XtreamHandler (/player_api.php)
   │                                                │
   │ BuildXmlTv():                                  │ get_live_streams:
   │  externalToLocal dict                          │  epg_channel_id = c.TvgId ← only EPG hook
   │  FindEpgProgramsByChannelIds()                 │
   │  re-tag programme.channel → localTvgId         │ get_short_epg → ❌ not implemented (Bug B4)
   │  EpgResponseCache (5-min TTL)                  │ get_simple_data_table → ❌ not implemented (Bug B4)
   │                                                │
   ▼                                                ▼
XMLTV response to player                 Xtream API response to player
   │                                                │
   └──────────────────────────────────────────────-─┘
                           │
              Player correlates:
              Xtream epg_channel_id == XMLTV <channel id>
              → displays programme schedule
```

---

## 9. Bug Details & Fixes (All Implemented)

### Bug B1 — `MergeEpgPrograms` drops episode/subtitle fields ✅ Fixed

**File:** `src/IptvHub.Service/Servers/IptvServerHost.cs`  
**Impact:** Subtitle and episode number data missing from XMLTV output for any programme added via manual EPG download.

**Change applied:** Added the missing fields to the `new EpgProgram { … }` initializer:
```csharp
all.Add(new EpgProgram
{
    ChannelId = channelId,
    StartUtc = program.StartUtc,
    StopUtc = program.StopUtc,
    Title = program.Title,
    SubTitle = program.SubTitle,              // ← added
    Description = program.Description,
    Category = program.Category,
    Language = program.Language,
    IconUrl = program.IconUrl,
    EpisodeNumXmltvNs = program.EpisodeNumXmltvNs,   // ← added
    EpisodeNumOnScreen = program.EpisodeNumOnScreen   // ← added
});
```

### Bug B2 — Manual EPG download doesn't invalidate XMLTV cache ✅ Fixed

**Files:** `src/IptvHub.Service/Api/Controllers/EpgController.cs` — both `DownloadFeed` (sync) and `QueueDownloadFeed` (async Task.Run)  
**Impact:** After clicking "Download" for a feed in the UI, the player still receives stale XMLTV for up to 5 minutes.

**Change applied:** Added `host.InvalidateEpgCache()` immediately after `MergeEpgPrograms` succeeds in both endpoints:
```csharp
var (added, total) = host.MergeEpgPrograms(feedPrograms, maps);
host.InvalidateEpgCache();   // ← added
var stopUtc = DateTime.UtcNow;
```

### Bug B3 — M3U missing EPG URL header ✅ Fixed

**File:** `src/IptvHub.Service/Servers/Handlers/M3uHandler.cs`  
**Impact:** Players cannot auto-discover the EPG URL; users must manually configure it.

**Change applied:** The live channel `#EXTM3U` line now carries EPG URL hints. VOD and series paths retain a plain `#EXTM3U`:
```csharp
// Live channel path:
var epgUrl = $"{baseUrl}/iptvhub.xmltv";
sb.AppendLine($"#EXTM3U url-tvg=\"{epgUrl}\" x-tvg-url=\"{epgUrl}\"");

// VOD / Series paths:
sb.AppendLine("#EXTM3U");
```
Players that understand `url-tvg` (Tivimate, GSE Smart IPTV, IPTV Smarters) will auto-configure the EPG guide URL without any manual setup.

### Bug B4 — Xtream Codes `get_short_epg` / `get_simple_data_table` not implemented ✅ Fixed

**File:** `src/IptvHub.Service/Servers/Handlers/XtreamHandler.cs`  
**Impact:** Players using Xtream API-native EPG (now/next banner, in-app guide) show empty/no data even when guide is configured.

**Change applied:** Added `using System.Text;` and two new switch arms in `HandlePlayerApiAsync`:
```csharp
"get_short_epg" => GetShortEpg(db, config, q["stream_id"].ToString(), q["limit"].ToString()),
"get_simple_data_table" => GetSimpleDataTable(db, config, q["stream_id"].ToString()),
```

Four supporting private static methods were added:

- **`GetShortEpg`** — Looks up the channel by integer `stream_id` → `TvgId`, queries `FindEpgProgramsByChannelIdsInWindow(now, now+3d)`, takes the first `limit` entries (default 4). Used for the "Now / Next" player banner.
- **`GetSimpleDataTable`** — Same lookup, queries `FindEpgProgramsByChannelIdsInWindow(today, today+7d)` for the full guide grid.
- **`BuildEpgLookupIds`** — Builds a `HashSet<string>` containing both `localTvgId` and any mapped `ExternalChannelId` from `config.EpgChannelMaps`, covering the dual-storage scenario.
- **`FormatEpgListings`** — Serializes each `EpgProgram` to the Xtream Codes EPG JSON format. Per the API spec, `title` and `description` are base64-encoded UTF-8. Timestamps are Unix epoch strings. `now_playing` is `"1"` for the currently-airing programme:

```json
{
  "epg_listings": [
    {
      "id": "42",
      "epg_id": "BBC One",
      "title": "TmV3cyBhdCBUZW4=",
      "lang": "en",
      "start": "2025-07-01 21:00:00",
      "end": "2025-07-01 22:00:00",
      "description": "6K+V5LiA...",
      "channel_id": "BBC One",
      "start_timestamp": "1751403600",
      "stop_timestamp": "1751407200",
      "now_playing": "1",
      "has_archive": "0"
    }
  ]
}

---

## 10. Performance Observations

| Concern | Finding |
|---------|---------|
| XMLTV build on cache miss | Loads ALL programmes for ALL mapped channels, then writes full XML. For large guides (100k+ entries) this can take seconds. The 5-min cache mitigates this for most players. |
| `FindEpgProgramsByChannelIdsInWindow` time filter | Applied in-memory after LiteDB index lookup. The `StartUtc` index exists but LiteDB cannot use it in a compound expression with `ChannelId`. For dense channels this degrades with guide size. |
| `ReplaceAllEpgPrograms` | Atomically deletes + reinserts the entire collection every refresh. Fast for typical guide sizes (<500k entries) but grows with multi-feed setups. |
| Manual merge (`MergeEpgPrograms`) | Loads the entire `EpgPrograms` collection into memory, dedupes in a `HashSet`, then replaces. For large guides this is a significant memory spike. |

---

## 11. Summary Table

| Layer | File | Key Mechanism | Gap / Bug |
|-------|------|---------------|-----------|
| Feed download | `ProviderService.cs` | `FetchXmlTvContentAsync` + throttle + source filter | None found |
| XMLTV parse | `XmlTvParser.cs` | DOM + streaming fallback, all fields captured | None found |
| Channel ID mapping | `ProviderService.cs` | `channelMap` dict during ingest | None found |
| Database storage | `HubDatabase.cs` | LiteDB, indexed on `ChannelId` + `StartUtc` | `StartUtc` index unused in window queries |
| Manual merge | `IptvServerHost.cs` | Additive merge with dedup | **B1**: drops SubTitle/EpisodeNum; **B2**: no cache invalidation |
| XMLTV output | `EpgHandler.cs` | `externalToLocal` dual-storage handling, 5-min cache | None found |
| Xtream channel list | `XtreamHandler.cs` | `epg_channel_id = c.TvgId` | **B4** ✅ Fixed — `get_short_epg` + `get_simple_data_table` implemented |
| M3U playlist | `M3uHandler.cs` | `tvg-id = c.TvgId` per channel | **B3** ✅ Fixed — `url-tvg` added to live `#EXTM3U` header |
| EPG cache invalidation | `ServerManager.cs` | After full refresh only | **B2** ✅ Fixed — cache also invalidated after manual download |

---

## 12. Implementation Status

All four bugs identified in the initial review have been implemented in the codebase.

| Bug | File(s) changed | Lines added | Status |
|-----|----------------|-------------|--------|
| B1 — missing EPG fields in manual merge | `IptvServerHost.cs` | +3 | ✅ Done |
| B2 — stale XMLTV cache after manual download | `EpgController.cs` (×2) | +2 | ✅ Done |
| B3 — no url-tvg in M3U header | `M3uHandler.cs` | +5 | ✅ Done |
| B4 — get_short_epg / get_simple_data_table | `XtreamHandler.cs` | +80 | ✅ Done |

All changes compile without errors or warnings.

**Remaining open item (performance, future work):** The `StartUtc` LiteDB index is unused in time-window queries because LiteDB does not support compound index expressions. For large multi-feed guide data (>500 k entries) this may cause slow window lookups. A dedicated "now/next" projection table or an upgrade to a compound-capable database engine would address this.
