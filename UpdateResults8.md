# EPG Feature Review — Update Results 8

> **Scope**: Full end-to-end review of all EPG-related features across the backend
> (`IptvHub.Service`) and frontend (`IptvHub.Web`). Conducted after the HDHomeRun
> timeline fix to ensure every EPG feature correctly handles the dual-storage scenario
> where programs may be stored under either a local `TvgId` or an external channel ID.
>
> **Session result**: 5 bugs found. 5 bugs fixed. 0 known regressions.

---

## 1. The Dual-Storage Problem (Root Cause)

All fixes in this session trace back to the same root cause.

When an EPG Channel Map is configured (e.g. `LocalTvgId = "hdhr-abc123"` →
`ExternalChannelId = "20372"`), `ProviderService` correctly remaps program channel IDs
**in-place before merging** on every subsequent auto-refresh. However, **programs
downloaded before the map was configured** remain stored in the database under the
external channel ID.

This creates a dual-storage scenario:

| Scenario | ChannelId stored in DB | Trigger |
|---|---|---|
| A — Pre-map programs | External ID (e.g. `"20372"`) | Downloaded before maps were set |
| B — Post-map programs | Local TvgId (e.g. `"hdhr-abc123"`) | Downloaded after maps were set |
| Both | Both IDs may coexist | Partial re-download |

`EpgHandler` (XMLTV output) was already robust to this. Four other endpoints were not.

---

## 2. Fixed Bugs

### Bug 1 — Timeline not showing EPG for mapped channels (Fixed, previous sub-session)

**File**: `src/IptvHub.Service/Api/Controllers/EpgController.cs` → `GetTimelinePrograms`

**Root cause**: Queried programs exclusively by the live channel's local `TvgId`. Programs
stored under the external channel ID (Scenario A) were never returned.

**Fix applied**:
1. Build `externalToLocal` dict from `server.EpgChannelMaps` scoped to channels in the
   current query.
2. Expand the `channelSet` to also include the external channel IDs.
3. Pass the expanded set to `GetEpgProgramsInWindow`.
4. Remap any returned program whose `ChannelId` is an external ID back to the local
   `TvgId`.
5. Deduplicate by `(effectiveChannelId, startUtc)` using a `HashSet` to prevent doubles
   when a program exists under both IDs.

---

### Bug 2 — Drift analysis shows false "missing-coverage" for all mapped channels (Fixed)

**File**: `src/IptvHub.Service/Api/Controllers/EpgController.cs` → `DetectDrift`

**Root cause**: Same as Bug 1. `DetectDrift` passed only the live channel `TvgId` values
to `GetEpgProgramsInWindow`, then filtered `programs.Where(p => p.ChannelId == channel.TvgId)`.
Any channel with maps whose programs were stored under the external ID would always register
as "missing-coverage", even if thousands of programs existed.

The fuzzy-match suggestions in the drift output would then point to the external channel ID
that was already configured — creating a confusing feedback loop.

**Fix applied**: Same `externalToLocal` + `expandedChannelIds` pattern as the timeline fix.
Programs returned with an external `ChannelId` are remapped to the local `TvgId` before gap
and overlap analysis runs.

---

### Bug 3 — Series recording "Always Record" finds no episodes (Fixed)

**File**: `src/IptvHub.Service/Api/Controllers/EpgController.cs` → `ExpandSeriesRecordingRules`

**Root cause**: Queried all programs via `_manager.GetEpgPrograms(serverId).Where(p =>
p.ChannelId == channelId)` where `channelId` is the local `TvgId`. Programs stored under
the external channel ID (Scenario A) were invisible, so the method returned 0 matching
episodes even when the EPG had full coverage.

**Fix applied**: Look up the external channel ID for the recording target channel from
`server.EpgChannelMaps`. Expand the LINQ `Where` predicate to also match
`p.ChannelId == seriesExternalId` (OR condition). This correctly finds episodes in both
storage scenarios without requiring a full database re-download.

---

### Bug 4 — XMLTV channel metadata not updated during scheduled auto-refresh (Fixed)

**File**: `src/IptvHub.Service/Services/ProviderService.cs`

**Root cause**: Manual downloads (via `POST /api/epg/download-queued`) call
`XmlTvParser.ParseChannelDisplayNames` and write the result to the `XmlTvChannelMeta`
LiteDB collection. The scheduled auto-refresh path in `ProviderService` called only
`FetchXmlTvContentAsync` + `XmlTvParser.Parse`, but **never** called
`ParseChannelDisplayNames` — so the metadata cache was only populated on first manual
download and never updated again.

This meant the channel browser in `EpgMapModal` and the fuzzy auto-suggest scores could
show stale display names (or no names at all) after the scheduled refresh replaced the
underlying XMLTV content.

**Fix applied**: After parsing the XMLTV content in `ProviderService.RefreshAsync`, call
`XmlTvParser.ParseChannelDisplayNames` and upsert the results into `_mgmtDb.XmlTvChannelMeta`.
This mirrors exactly what the manual download path already does.

---

### Bug 5 — EpgMapModal doesn't invalidate timeline/drift cache after saving a map (Fixed)

**File**: `src/IptvHub.Web/src/components/EpgMapModal.tsx`

**Root cause**: The `invalidate()` helper called after saving or clearing an EPG channel
map only invalidated `['epg-summary']` and `['servers']`. It did not invalidate the
TanStack Query caches for:
- `['epg-timeline-programs']` — the per-server, per-window program grid
- `['epg-drift']` — the gap/overlap analysis panel

This meant that after a user configured a new mapping in the Channel Manager and returned
to the EPG page, the timeline and drift panels continued showing stale data until the
5-minute `staleTime` expired or the page was reloaded.

**Fix applied**: Added `qc.invalidateQueries({ queryKey: ['epg-timeline-programs'] })` and
`qc.invalidateQueries({ queryKey: ['epg-drift'] })` to the `invalidate()` helper in
`EpgMapModal.tsx`.

---

## 3. Verified Correct — No Changes Needed

### 3.1 XMLTV Output (`EpgHandler.cs`)

**Endpoint**: `GET /iptvhub.xmltv`, `/xmltv.php`, `/xmltv`

The handler was already robust to both storage scenarios:

1. Loads `server.EpgChannelMaps` and builds an `externalToLocal` reverse dict.
2. Queries programs by **both** local TvgIds and external channel IDs.
3. Remaps `prog.ChannelId` to the local TvgId on output so Plex/Emby/Jellyfin always
   sees a stable channel identifier.
4. Applies a 5-minute in-memory cache with `ETag` support (`304 Not Modified`) to avoid
   re-building the XML payload on every Plex EPG poll.

No changes required.

---

### 3.2 Auto-Refresh Channel ID Remapping (`ProviderService.cs`)

When `ProviderService.RefreshAsync` processes an EPG feed, it:

1. Builds `channelMap` from `server.EpgChannelMaps` (external → local).
2. For every parsed program, checks `channelMap.TryGetValue(prog.ChannelId, out var localId)`
   and mutates `prog.ChannelId = localId` before passing to `MergeEpgPrograms`.
3. Applies a `feedChannelFilter` when the live source has `EpgFeedIds` configured — this
   correctly restricts which channels' programs are accepted from each feed, even when the
   feed contains a full national guide.
4. Enforces `MinDownloadIntervalMinutes` throttling; manual downloads via the API bypass
   this guard correctly.

The auto-refresh path itself has always been correct. Scenario A (old data under external
IDs) only arises from programs downloaded before maps were configured.

---

### 3.3 EPG Merge (`IptvServerHost.cs → MergeEpgPrograms`)

`MergeEpgPrograms(programs, channelMap)`:

1. Loads all existing programs from `HubDatabase`.
2. Applies the channel map to existing programs (migrates any external IDs that may remain
   from a partial previous run).
3. Merges incoming programs with the existing set using `(channelId, startUtc)` as the
   deduplication key.
4. Writes the merged result back via `ReplaceAllEpgPrograms` (atomic transaction:
   `DeleteAll` + `InsertBulkInChunks`).

The merge is case-sensitive on `channelId` (matching LiteDB's `StringComparer.Ordinal`
index) — consistent across all callers.

---

### 3.4 EPG Suggestion Engine (`EpgController.SuggestMappings`)

`POST /api/epg/suggest-mappings`:

1. Skips channels that are already mapped (`alreadyMapped.Contains(ch.TvgId)`).
2. Skips channels whose TvgId directly matches a stored EPG program `ChannelId` (no map
   needed — they match natively).
3. For Schedules Direct feeds, enriches numeric station IDs with callsign suffixes
   (e.g. `"20372"` → `"20372 KERADT"`) before fuzzy scoring.
4. Uses ATSC channel number (from the live channel) as an authoritative signal: if the
   channel number matches a display-name prefix in an EPG channel list, it's promoted to
   the top suggestion regardless of Jaccard score.
5. Noise tokens (`"sd"`, `"hd"`, `"the"`) are filtered before Jaccard computation to
   prevent spurious matches.

Correctly handles both Scenario A and B since suggestions are computed against the raw
EPG channel ID list from the DB, not against local TvgIds.

---

### 3.5 Feed Channel Browser (`EpgController.GetFeedChannels`)

`GET /api/epg/feed-channels?serverId=...&feedId=...`:

- **Schedules Direct**: Returns stations ordered by channel number (ascending), then
  callsign. Combines `lineup.stations` with `SdStationMetadata` for enriched display.
- **XMLTV**: Prefers non-numeric display names (callsigns, station names) over numeric
  ones. Extracts the channel number from the display-name list (first entry that looks like
  `"13.1"` or `"2"`). Orders by channel number, then display name.

Used by `EpgMapModal`'s channel browser. Correctly reflects live feed data without
depending on the dual-storage scenario.

---

### 3.6 Timeline Virtual Scroll and Polling (`Epg.tsx`)

- **Virtual scroll**: Renders only the visible row range; `visibleStart/visibleEnd` state
  controls which channel rows are rendered.
- **Query snapping**: `fromUtc`/`toUtc` query boundaries are snapped to 30-minute buckets.
  This limits the number of distinct TanStack Query cache entries as the user scrolls
  horizontally, preventing unbounded cache growth.
- **Channel polling**: Polls every 10 s until `timelineChannels.length > 0`.
- **Program polling**: Polls every 15 s until programs appear; after `programCount` goes
  from 0 → > 0 the query is immediately invalidated to trigger a fresh fetch.
- **Auto-scroll**: On page load with today's date selected, the timeline auto-scrolls to
  "now" (current time offset within the viewport).

All correct.

---

### 3.7 Enigma2 Import (`EpgImport.tsx`)

Fully separate from the EPG feed/timeline system. Manages SFTP push profiles to Enigma2
(satellite receiver) devices:

- **Profiles**: Name, SFTP credentials, remote directory, file names for XMLTV/bouquet/
  metadata, auto-push triggers (`autoPushOnChange`, `autoPushOnRefresh`), scheduled
  interval.
- **Channel mappings**: `xmltvChannelId` (from IptvHub's XMLTV output) → Enigma2
  `serviceRef`. Supports CSV import/export with duplicate detection, strict-mode validation,
  and per-row enable/disable.
- **Auto-suggest**: Queries Enigma2 device via the backend to suggest `serviceRef` values
  for each XMLTV channel ID.
- **Dry-run**: Generates preview XML + channel files locally without SFTP push.
- **History panel**: Shows last N push operations with timestamps and result summaries.

No issues found. This feature reads from IptvHub's XMLTV output endpoint (already
correct) and is not affected by the dual-storage scenario.

---

## 4. End-to-End EPG Data Flow

```
┌─────────────────┐
│  XMLTV / SD URL │
└────────┬────────┘
         │ Scheduled: ProviderService.RefreshAsync (Quartz job)
         │ Manual:    POST /api/epg/download-queued (202 Accepted, async)
         ▼
  XmlTvParser.Parse / FetchSchedulesDirectAsync
         │
         │ channelMap applied: externalId → localTvgId (if mapped)
         │ feedChannelFilter applied (if source has EpgFeedIds)
         ▼
  IptvServerHost.MergeEpgPrograms
         │ Dedup by (channelId, startUtc)
         │ Atomic write: DeleteAll + InsertBulkInChunks
         ▼
  HubDatabase.EpgPrograms (LiteDB, per-server)
         │
   ┌─────┴──────────────────────────────────────────┐
   │                                                │
   ▼                                                ▼
GET /api/epg/timeline                    GET /iptvhub.xmltv
  externalToLocal applied                 externalToLocal applied
  query expanded to ext IDs               query expanded to ext IDs
  dedup by (localId, startUtc)            output ChannelId = localTvgId
         │                                                │
   Epg.tsx timeline grid                   Plex / Emby / Jellyfin
         │                                (5-min ETag cache)
         │
   ┌─────┴──────────────────────────┐
   │                                │
   ▼                                ▼
GET /api/epg/drift               ExpandSeriesRecordingRules
  externalToLocal applied          externalId resolved from maps
  expanded channelIds              WHERE ChannelId IN (local, ext)
  remapped before analysis         creates RecordingRule entries
```

---

## 5. Summary Table

| Feature | Status | Notes |
|---|---|---|
| XMLTV feed download (manual) | ✅ Correct | Async queued, status polling in UI |
| XMLTV feed download (scheduled) | ✅ Fixed (#4) | Now also persists channel metadata |
| SD (Schedules Direct) feed | ✅ Correct | Auto-refresh correct |
| Channel ID remapping on ingest | ✅ Correct | `ProviderService` remaps in-place before merge |
| EPG merge (dedup + atomic write) | ✅ Correct | `MergeEpgPrograms` applies map to existing data |
| Timeline grid programs | ✅ Fixed (#1) | Extended to query by external IDs, remaps results |
| Timeline virtual scroll + snapping | ✅ Correct | 30-min bucket snapping, correct polling |
| XMLTV output (`/iptvhub.xmltv`) | ✅ Correct | Both storage scenarios handled; ETag cache |
| EPG channel mapping (EpgMapModal) | ✅ Fixed (#5) | Now invalidates timeline + drift cache on save |
| Feed channel browser | ✅ Correct | SD ordered by number; XMLTV by number then name |
| Auto-suggest mappings | ✅ Correct | ATSC precedence, noise filtering, Jaccard scoring |
| Drift analysis | ✅ Fixed (#2) | Extended to query by external IDs before analysis |
| Series recording (one-time) | ✅ Fixed (#3) | Queries by both local and external channel IDs |
| Series recording (always record) | ✅ Fixed (#3) | Same fix; creates recurring `RecordingRule` entries |
| Enigma2 import (EpgImport) | ✅ Correct | Independent of dual-storage scenario |
| XMLTV channel metadata cache | ✅ Fixed (#4) | Updated on every auto-refresh, not just manual |

---

## 6. Recommendations

### 6.1 Re-download feeds after configuring channel maps

The system now handles both storage scenarios transparently for all features.
However, for best performance (the expanded-channel-ID queries touch more rows),
it is recommended to trigger a manual EPG download after configuring or changing
channel maps. This ensures all programs are stored under the local `TvgId`,
eliminating the Scenario A overhead.

**Steps**: EPG Manager → server card → Download button for each feed.

### 6.2 Consider a background normalization job

A future enhancement could be a background job (or a triggered task after map changes)
that re-normalizes existing programs: for each EPG channel map, find programs stored
under the external channel ID and update them to the local TvgId in a single bulk
transaction. This would fully eliminate Scenario A without requiring a re-download.

### 6.3 `EpgMapModal` does not invalidate after bulk server EPG config save

When the EPG Manager page saves the full server EPG config (feeds + maps) via
`PUT /servers/{id}/epg-config`, the `ServerEpgCard` component invalidates
`['epg-summary']` and `['servers']` but not `['epg-timeline-programs']` or `['epg-drift']`.
This is lower priority (the full config save is less common than single-map saves in
`EpgMapModal`) but could be added for consistency.
