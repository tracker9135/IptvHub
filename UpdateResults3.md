# IPTV Hub — Full Code Review
**Date:** 2026-05-29  
**Scope:** Backend API controllers, services, server handlers, models, React frontend pages, and API layer.  
**Focus:** New features, meaningful modifications, and improvements.

---

## 1. Summary

The codebase is well-structured with a clean separation between the ASP.NET Core backend and React/TypeScript frontend. The architecture supports multiple server instances, smart failover, full XMLTV/EPG management, transcoding, timeshift, and Xtream Codes emulation. Many scaffolds exist for features that are not yet fully implemented (recording rules, quality profiles, email digest, parental PIN per stream). The areas with the highest return-on-investment for new work are listed first in each section below.

---

## 2. New Features

### 2.1 Source Enable / Disable Toggle
**Area:** `SourcesController` + `Sources.tsx`  
**Gap:** There is no enabled/disabled flag on `IptvSource`. To stop using a source you must fully delete it.  
**Proposed Change:**
- Add `bool IsEnabled` field to `IptvSource` model.
- Filter disabled sources out in `ProviderService.RefreshAsync()`.
- Add a toggle button per source row in `Sources.tsx` (single PATCH call).

**Effort:** Small — model field + one filter line + UI toggle button.

---

### 2.2 Batch Channel Inhibit (Apply Dry-Run Results)
**Area:** `ChannelsController` + `ChannelManager.tsx`  
**Gap:** `POST {serverId}/bulk-inhibit-dry-run` exists and returns the preview, but there is no companion `POST {serverId}/bulk-inhibit` endpoint to actually apply the changes. The UI shows the dry-run result but provides no "Apply" action.  
**Proposed Change:**
- Add `POST {serverId}/bulk-inhibit` that applies the same filter logic as the dry-run without the preview step.
- Wire an "Apply" button in the bulk-inhibit modal in `ChannelManager.tsx`.

**Effort:** Small — copy dry-run handler, remove preview return, perform the write.

---

### 2.3 Watch-History Resume Position
**Area:** `WatchProgress` model + `WatchHistoryController` + `StreamHandler` + `Player.tsx`  
**Gap:** `WatchProgress.DurationWatchedSeconds` stores total cumulative duration but not a resume position offset. The player has no way to resume VOD at the point last left off.  
**Proposed Change:**
- Add `ResumePositionSeconds` to `WatchProgress`.
- Have `StreamHandler` report position periodically via a lightweight heartbeat endpoint (`PATCH /watch-history/{id}/position`).
- In `Player.tsx`, when opening VOD, fetch the resume position and pass it as a `#t=<seconds>` fragment or HLS seek parameter.

**Effort:** Medium — new endpoint, player integration, heartbeat timer.

---

### 2.4 Log Export (Download as File)
**Area:** `LogsController` + `Logs.tsx`  
**Gap:** Logs are displayed in the UI and can be filtered, but there is no way to download the log for a given date as a file.  
**Proposed Change:**
- Add `GET /api/logs/export?date=&minLevel=` endpoint that returns the filtered lines as `text/plain` with a `Content-Disposition: attachment` header.
- Add a "Download" button to the `Logs.tsx` date selector row.

**Effort:** Very small — one endpoint, one button.

---

### 2.5 Backup — Scheduled Auto-Export
**Area:** `BackupController` + `SettingsController` + `HubSettings` + `Settings.tsx`  
**Gap:** Backup is manual only. A restart after a misconfiguration can cause data loss between manual backups.  
**Proposed Change:**
- Add `AutoBackupIntervalHours` and `AutoBackupRetainCount` to `HubSettings`.
- Add a Quartz worker (`AutoBackupWorker`) that calls the same export logic as `BackupController.ExportAsync()` on the configured interval, writing files to `data/backups/`.
- Expose the schedule and "last backup" timestamp in `Settings.tsx`.

**Effort:** Medium — Quartz job, settings fields, UI section.

---

### 2.6 Backup — Include Recording Rules, Skip Markers, EPG Import Profiles
**Area:** `BackupController`  
**Gap:** The backup explicitly excludes recording rules, skip markers, watch history, and EPG import profiles. Recovery from a backup is therefore incomplete.  
**Proposed Change:**
- Extend the `BackupBundle` DTO to include `RecordingRules`, `SkipMarkers`, and `EpgImportProfiles`.
- Add corresponding restore logic.
- Watch history is intentionally excludable (large, personal) — add an optional checkbox in the export UI.

**Effort:** Small-medium — model additions, serialize/deserialize, UI checkbox.

---

### 2.7 EPG Handler — Response Caching
**Area:** `EpgHandler.cs`  
**Gap:** The XMLTV document is regenerated from the database on every request. Large deployments with many clients polling `/iptvhub.xmltv` every few minutes will hammer the LiteDB queries repeatedly.  
**Proposed Change:**
- Cache the serialized XMLTV bytes in memory with a configurable TTL (e.g. 5 minutes, matching EPG refresh cadence).
- Invalidate the cache after each successful `ProviderService.RefreshAsync()`.
- Return `ETag` / `Last-Modified` response headers so clients can skip re-download when unchanged.

**Effort:** Small — `MemoryCache<byte[]>` + invalidation hook + headers.

---

### 2.8 Source Cloning
**Area:** `SourcesController` + `Sources.tsx`  
**Gap:** Duplicating a source (e.g. to create a second server with the same Xtream provider) requires re-entering all credentials manually.  
**Proposed Change:**
- Add `POST /api/sources/{id}/clone` that copies the source with a `" (Copy)"` name suffix.
- Add a "Clone" option in the source row action menu.

**Effort:** Very small — single controller action + UI menu item.

---

### 2.9 Server Cloning
**Area:** `ServersController` + `Servers.tsx`  
**Gap:** No way to create a second server that shares the same sources and EPG config as an existing one.  
**Proposed Change:**
- Add `POST /api/servers/{id}/clone` that copies the config, assigns a new port, generates a new `Id`, and does not start it automatically.
- Add a "Clone" option in the server action menu.

**Effort:** Small — controller + UI.

---

### 2.10 Search — Faceted Filtering
**Area:** `SearchController` + `Search.tsx`  
**Gap:** The search page returns mixed results (live channels, VOD, series, EPG) with no way to narrow by kind.  
**Proposed Change:**
- Accept an optional `kind=live|vod|series|epg` query parameter in `SearchController`.
- Add filter chips (`Live`, `VOD`, `Series`, `EPG`) to `Search.tsx` that append the kind parameter.

**Effort:** Small — controller filter + UI chips.

---

### 2.11 Favorites Ordering
**Area:** `FavoritesController` + `ChannelManager.tsx`  
**Gap:** Favorites are stored as an unordered set. Users cannot customise the order in which favorites appear.  
**Proposed Change:**
- Add `SortOrder` (int) to `FavoriteChannel` model.
- Add `PATCH /api/favorites/reorder` endpoint (same pattern as custom playlist reorder).
- Add drag-to-reorder in the favorites filter panel in `ChannelManager.tsx`.

**Effort:** Medium — model, endpoint, drag-handle UI component.

---

### 2.12 Per-Stream Health Badge in Channel Manager
**Area:** `ChannelManager.tsx`  
**Gap:** Channel rows show a name and category but no visual health indicator. The scan result (`LastScanOk`) is available from the API but not displayed in the list.  
**Proposed Change:**
- Add a small colored dot (green/red/grey) to each channel row reflecting `LastScanOk` / not scanned.
- Show `LastScannedAt` tooltip on hover.
- Add a "Health" column that can be toggled on/off.

**Effort:** Very small — UI only, data already returned from `GET {serverId}/channels`.

---

### 2.13 Playlist Merge
**Area:** `CustomPlaylistsController` + `PlaylistManager.tsx`  
**Gap:** Users cannot combine two playlists into one without manually adding entries one by one.  
**Proposed Change:**
- Add `POST /api/custom-playlists/{targetId}/merge-from/{sourceId}` that appends all entries from the source playlist (skipping duplicates).
- Add a "Merge into..." option in the playlist action menu.

**Effort:** Small — controller action + UI menu item.

---

### 2.14 Parental PIN Per-Stream Verification
**Area:** `StreamHandler` + `HubServerConfig` + `Servers.tsx`  
**Gap:** Parental controls block adult categories at the M3U/Xtream level (categories not listed), but a user who knows the stream URL can bypass the filter. There is no secondary PIN challenge at stream time.  
**Proposed Change:**
- Add a `ParentalPinRequired` flag to `HubUser`.
- In `StreamHandler.HandleLiveAsync()`, if the channel is in an adult category and the flag is set, require a one-time PIN token in the query string (issued by a `POST /api/parental/token` endpoint after PIN verification).

**Effort:** Medium-large — token issuance, TTL store, stream handler check.

---

### 2.15 Admin Change Password Endpoint
**Area:** `SettingsController` + `Settings.tsx`  
**Gap:** The admin password can only be set during first run. There is no way to change it later through the UI.  
**Proposed Change:**
- Add `POST /api/settings/change-password` (requires current password + new password, min 8 chars).
- Update `Settings.tsx` to include a "Change Password" section with current/new/confirm fields.

**Effort:** Small — one endpoint, one UI section.

---

### 2.16 Catch-Up / Timeshift Disk Space Limit
**Area:** `TimeshiftBufferManager` + `HubServerConfig` + `Servers.tsx`  
**Gap:** The timeshift HLS ring buffer writes segments to disk with no disk-space limit. On a busy server with many channels buffered, this can fill the disk silently.  
**Proposed Change:**
- Add `CatchupMaxDiskMb` to `HubServerConfig` (default 0 = unlimited).
- In `TimeshiftBufferManager`, before starting a new buffer, check total `data/catchup/{serverId}/` usage and refuse if over the limit.
- Expose the disk usage per server in `StatusController.GetMediaHealth()`.

**Effort:** Medium — directory size check + enforcement + status exposure.

---

### 2.17 ffmpeg Crash Recovery for Timeshift Buffers
**Area:** `TimeshiftBufferManager`  
**Gap:** If the ffmpeg child process crashes (network drop, codec error), the buffer entry stays in the dictionary with a stale process reference. The next `EnsureBuffer()` call will create a new process, but the old dead entry lingers until the 10-minute idle cleanup.  
**Proposed Change:**
- Subscribe to `Process.Exited` event on each ffmpeg process.
- On unexpected exit (exit code != 0), remove the entry from the dictionary immediately so the next request restarts cleanly.

**Effort:** Very small — event handler + dictionary remove.

---

### 2.18 Health Check Endpoint
**Area:** `Program.cs`  
**Gap:** There is no standard `/health` endpoint. Docker, Kubernetes, and Synology container health checks have no target.  
**Proposed Change:**
- Register `builder.Services.AddHealthChecks()` with a simple "alive" check and optionally a LiteDB-readable check.
- Map to `/health` (public, no auth).

**Effort:** Very small — ~10 lines in Program.cs.

---

### 2.19 Webhook Signing
**Area:** `NotificationService` + `HubServerConfig` + `Servers.tsx`  
**Gap:** Webhooks are posted unsigned. A receiver cannot verify the payload originated from IPTV Hub.  
**Proposed Change:**
- Add `WebhookSigningSecret` to `HubServerConfig`.
- In `NotificationService`, compute `HMAC-SHA256(secret, body)` and include it as a `X-IptvHub-Signature` header.
- Show the secret field in `Servers.tsx` webhook settings with a "Regenerate" button.

**Effort:** Small — HMAC computation + UI field.

---

### 2.20 Recording Rules — Actual Recording Implementation
**Area:** `RecordingRuleSchedulerWorker` + `RecordingRulesController` + `Epg.tsx`  
**Gap:** The entire recording system is a scheduling scaffold. `RecordingRule` model, CRUD endpoints, scheduler worker, and UI hooks all exist but no actual recording (ffmpeg capture, file storage) occurs.  
**Proposed Change:**
- Add `RecordingOutputDirectory` to `HubServerConfig`.
- In `RecordingRuleDispatchJob`, resolve the channel stream URL via `SourceStreamUrlResolver`, then launch an ffmpeg process (`-i <url> -t <duration> -c copy <output.ts>`).
- Track the process PID and output path in a new `ActiveRecording` in-memory list.
- Expose active recordings in `StatusController` and the EPG recording badge in `Epg.tsx`.

**Effort:** Large — ffmpeg launch, process tracking, status exposure, UI badge.

---

## 3. Modifications to Existing Features

### 3.1 YouTube Fetch — Make Async
**Area:** `SourceIngestionService.FetchYoutubeSource()`  
**Issue:** The YouTube yt-dlp call is synchronous, blocking the calling thread for the duration of the external process.  
**Fix:** Wrap in `Task.Run()` with a configurable timeout (`CancellationTokenSource`) consistent with how other sources handle timeouts.

---

### 3.2 EPG Series Recording — Title Matching Improvement
**Area:** `EpgController.RecordSeries()`  
**Issue:** Series matching uses "Normalized Title" (strip punctuation + numbers). Shows with similar names (e.g. "The Office US" vs "The Office UK") will match each other.  
**Fix:**
- Add a `Channel` filter (tvg-id) to the series recording request — only match programmes on the selected channel's EPG.
- Add a `tvg-id` field to the recording rule so future episodes are also locked to the same channel.

---

### 3.3 CORS — Tighten Origin Validation
**Area:** `Program.cs` CORS policy  
**Issue:** The current policy allows all `http://` and `https://` origins, which is overly permissive.  
**Fix:** Read allowed origins from `AppSettings.ManagementApi.AllowedOrigins` (already exists for trusted proxies) and only allow those explicitly listed origins. Default to same-origin only if list is empty.

---

### 3.4 XtreamHandler — Include Transcode URLs
**Area:** `XtreamHandler.cs`  
**Issue:** Xtream emulation always returns proxy URLs (`/live/{user}/{pass}/{id}.ts`). If transcoding is enabled, clients that support adaptive streams never get the HLS master playlist URL.  
**Fix:** Follow the same logic as `M3uHandler` — if `EnableTranscoding` and ffmpeg is available, emit `/transcode/live/{user}/{pass}/{id}/master.m3u8` as the stream URL in the Xtream response.

---

### 3.5 Channel Scanner — Retry on Transient Results
**Area:** `ChannelScanner.cs`  
**Issue:** HTTP 403 and 5xx are classified as "transient/null" but the probe is only attempted once. A transient upstream error will mark a channel as unknown permanently until the next full scan.  
**Fix:** Add a single retry (1-2 second delay) when the result is `null` (transient), before committing the null result. Configurable via `AppSettings.Scanner`.

---

### 3.6 Transcode Quality Profile — Use Configured Profile
**Area:** `TranscodeSessionManager`  
**Issue:** `HubServerConfig.TranscodeQualityProfile` is stored and returned by the API but the transcode session manager always applies the hardcoded 3-tier ladder regardless of the setting.  
**Fix:** Implement at least two profiles — `"auto"` (current 3-tier) and `"1080p-only"` (single highest-quality variant). Read from `HubServerConfig.TranscodeQualityProfile` when building the ffmpeg filter-complex.

---

### 3.7 SearchIndexService — Add Fuzzy Token Matching
**Area:** `SearchIndexService` + `SearchController`  
**Issue:** Search is exact substring only. Typos or alternate spellings return no results.  
**Fix:** Tokenize the query and score by token overlap (similar to the fuzzy matching already implemented in `EpgImportManagerService.SuggestMappings()`). Re-use the Jaccard tokenizer already in the codebase.

---

### 3.8 StreamHandler — Track Redirect-Mode Watch History
**Area:** `StreamHandler`  
**Issue:** Watch history (`WatchProgress`) is only recorded when the stream is proxied. Redirect-mode streams (the default for most sources) are never tracked. The history page is therefore incomplete for most setups.  
**Fix:** Record a `WatchProgress` entry on redirect too (with `DurationWatchedSeconds = 0`). A subsequent proxy heartbeat (see 2.3) can update the duration if the user switches to proxy mode later.

---

### 3.9 Backup Restore — Merge Option
**Area:** `BackupController.RestoreAsync()`  
**Issue:** Restore always wipes all existing data before importing. A partial restore (e.g. restoring only custom playlists) is not possible.  
**Fix:** Add a `?mode=merge` query parameter. In merge mode, upsert records by ID instead of wiping collections. Add a "Merge" radio option alongside "Replace" in the Settings restore UI.

---

### 3.10 M3U Handler — Working Filter Fallback Logging
**Area:** `M3uHandler`  
**Issue:** When `ServeWorkingChannelsOnly` is enabled but all channels are dead, it silently falls back to serving all channels. This is helpful for resilience but produces unexpected results silently.  
**Fix:** Emit an `X-IptvHub-Filter-Fallback: true` response header when the fallback fires, and log the event at `WARN` level with the server ID and channel count.

---

### 3.11 EpgHandler — Add Conditional GET Support
**Area:** `EpgHandler.cs` (see also 2.7)  
**Issue:** Every XMLTV poll downloads the full document regardless of whether it has changed.  
**Fix:** Once the response cache (2.7) is in place, hash the output and return it as an `ETag`. Respond with `304 Not Modified` when the client sends a matching `If-None-Match` header.

---

### 3.12 ProviderService — Concurrent Source Fetching
**Area:** `ProviderService.RefreshAsync()`  
**Issue:** Sources are fetched sequentially. A slow or unreachable source (e.g. a YouTube source waiting on yt-dlp) blocks all subsequent sources from refreshing.  
**Fix:** Wrap each source fetch in a `Task`, use `Task.WhenAll()` with a semaphore to limit concurrency (default 4 parallel sources). Add a per-source timeout.

---

### 3.13 Channel Counts Endpoint — Cache Results
**Area:** `SourcesController.GetChannelCounts()`  
**Issue:** The endpoint rebuilds a `SourceKey → channel list` map from all running servers on every call. On large deployments this is O(servers × channels).  
**Fix:** Cache the result in `ServerManager` and invalidate after each successful refresh, similar to the search index rebuild.

---

### 3.14 HDR Preservation in Transcoding
**Area:** `TranscodeSessionManager`  
**Issue:** `HubServerConfig.PreserveHdrMetadata` exists as a boolean but the ffmpeg filter-complex does not apply HDR passthrough mapping even when the flag is true.  
**Fix:** When `PreserveHdrMetadata == true`, add `-colorspace bt2020nc -color_trc smpte2084 -color_primaries bt2020 -x265-params "hdr-opt=1:repeat-headers=1"` (or equivalent for h264) and remove the scale filter that drops color space info.

---

### 3.15 Refresh History — Persist Across Restarts
**Area:** `ServerManager`  
**Issue:** Refresh history is stored in a `ConcurrentQueue` in memory and is lost on every restart. The "Refresh History" panel in the UI is always empty after a restart.  
**Fix:** Persist the last N (e.g. 50) refresh history entries to the `ManagementDatabase` on write. Load them on startup.

---

## 4. UI Improvements (Frontend Only)

### 4.1 Dashboard — Scheduler Pressure Actions
**Area:** `Dashboard.tsx`  
**Gap:** The scheduler pressure alert (from `SchedulerPressureAlertWorker`) is surfaced in status but the dashboard has no direct action button.  
**Fix:** When scheduler pressure is detected, show a warning banner with a "Pause Refreshes" button that sets a 30-minute maintenance window on all running servers.

---

### 4.2 Sources — YouTube Format Override
**Area:** `Sources.tsx`  
**Gap:** YouTube sources use yt-dlp with default format selection. There is no UI to set preferred format or quality.  
**Fix:** Add an optional "yt-dlp format string" field to the YouTube source form (e.g. `bestvideo[height<=1080]+bestaudio/best`).

---

### 4.3 Settings — CORS Allowed Origins UI
**Area:** `Settings.tsx`  
**Gap:** CORS allowed origins are only configurable via `appsettings.json`. There is no UI field.  
**Fix:** Add a multi-value text input for `AllowedOrigins` in the Advanced section of `Settings.tsx`, persisted via a new `PUT /api/settings/cors` endpoint.

---

### 4.4 EPG Import — Preview Download
**Area:** `EpgImport.tsx`  
**Gap:** The preview endpoint generates `custom.sources.xml`, `custom.channels.xml`, and `custom.providers.json` but only returns them inline. There is no "Download Preview Files" button.  
**Fix:** Add `Accept: application/octet-stream` and `Content-Disposition: attachment; filename="..."` support to the preview endpoint, and a download button in the profile detail view.

---

### 4.5 Logs — Persist Filter State
**Area:** `Logs.tsx`  
**Gap:** The level filter and date selection reset every time the page is navigated away from.  
**Fix:** Store the selected date and level in `sessionStorage` so they are restored on re-navigation.

---

### 4.6 Search — Keyboard Navigation
**Area:** `Search.tsx`  
**Gap:** The search results list has no keyboard navigation. Pressing arrow keys after typing a query does not move focus to results.  
**Fix:** Add `onKeyDown` handling on the input that moves focus to the first result on `ArrowDown`. Results should support `Enter` to open.

---

### 4.7 Channel Manager — Bulk Test
**Area:** `ChannelManager.tsx`  
**Gap:** Channels can be tested individually but there is no "Test Selected" bulk action.  
**Fix:** Add a "Test Selected" button to the bulk-action toolbar that fires `POST {serverId}/{streamId}/test` for each selected channel concurrently (bounded concurrency, same as bulk inhibit dry-run pattern).

---

## 5. Security Hardening

| # | Item | File | Fix |
|---|------|------|-----|
| S1 | No rate-limiting on `/api/auth/login` | `AuthController` | Apply `LoginRateLimiter` (already registered) to the login endpoint |
| S2 | Factory reset has no CSRF protection beyond exact string | `SettingsController` | Require a fresh short-lived token issued by a `/api/settings/reset-token` endpoint |
| S3 | Metrics endpoint public by default | `StatusController` | Default `MetricsAuthRequired = true` in `AppSettings`; document how to opt-out |
| S4 | Webhook payloads are unsigned | `NotificationService` | See item 2.19 — HMAC-SHA256 signing |
| S5 | No audit log for sensitive operations | `SettingsController` | Write PIN change, password change, backup restore, factory reset events to an `AuthAuditEvent` (model already exists) |
| S6 | CORS overly permissive | `Program.cs` | See item 3.3 — restrict to configured origins |

---

## 6. Technical Debt

| # | Item | Location | Note |
|---|------|----------|------|
| T1 | YouTube fetch is synchronous | `SourceIngestionService.FetchYoutubeSource()` | Blocks thread pool — see item 3.1 |
| T2 | Page components too large (1400–1800 lines) | `Epg.tsx`, `Servers.tsx` | Split into sub-components; no functional change needed |
| T3 | Recording rules never execute | `RecordingRuleSchedulerWorker` | Scaffold only — see item 2.20 |
| T4 | Refresh history lost on restart | `ServerManager` | In-memory queue — see item 3.15 |
| T5 | XMLTV regenerated on every EPG poll | `EpgHandler` | No cache — see item 2.7 |
| T6 | No `/health` endpoint | `Program.cs` | Standard health probe missing — see item 2.18 |
| T7 | Transcode quality profile field unused | `TranscodeSessionManager` | Config exists, code ignores it — see item 3.6 |
| T8 | HDR preservation flag unused | `TranscodeSessionManager` | Config exists, code ignores it — see item 3.14 |
| T9 | Sources fetched sequentially | `ProviderService.RefreshAsync()` | See item 3.12 |
| T10 | EpgChannelMap reverse-build on every M3U/EPG request | `EpgHandler`, `M3uHandler` | Rebuild once per refresh and cache |

---

## 7. Sprint Plan

---

### Sprint 1 — Quick Wins & Stability (1–2 days)

High-value, very small or small items. Each can be shipped independently with minimal risk.

| # | Item | Area | Effort |
|---|------|------|--------|
| 2.18 | Add `/health` endpoint | `Program.cs` | Very small |
| 2.17 | ffmpeg crash recovery for timeshift | `TimeshiftBufferManager` | Very small |
| 2.4 | Log export download button | `LogsController` + `Logs.tsx` | Very small |
| 2.12 | Health badge in Channel Manager | `ChannelManager.tsx` | Very small |
| 2.8 | Source cloning | `SourcesController` + `Sources.tsx` | Very small |
| 2.2 | Batch channel inhibit — apply endpoint | `ChannelsController` + `ChannelManager.tsx` | Small |
| 3.1 | YouTube fetch — make async | `SourceIngestionService` | Small |
| 3.3 / S6 | CORS — tighten origin validation | `Program.cs` | Small |
| S1 | Rate-limiting on login endpoint | `AuthController` | Small |

---

### Sprint 2 — Source & Server Management (2–3 days)

Fills gaps in the Sources and Servers pages; all backend-first with small UI companions.

| # | Item | Area | Effort |
|---|------|------|--------|
| 2.1 | Source enable/disable toggle | `IptvSource` + `Sources.tsx` | Small |
| 2.9 | Server cloning | `ServersController` + `Servers.tsx` | Small |
| 2.15 | Admin change password | `SettingsController` + `Settings.tsx` | Small |
| 3.15 | Persist refresh history across restarts | `ServerManager` | Small |
| 3.8 | Track redirect-mode watch history | `StreamHandler` | Small |
| 3.5 | Channel scanner retry on transient results | `ChannelScanner` | Small |
| 3.4 | XtreamHandler — include transcode URLs | `XtreamHandler` | Small |
| 3.13 | Cache channel-counts endpoint | `SourcesController` + `ServerManager` | Small |

---

### Sprint 3 — EPG & Backup Hardening (2–3 days)

Improves EPG performance, backup completeness, and search quality.

| # | Item | Area | Effort |
|---|------|------|--------|
| 2.7 | EPG handler response cache + ETag / 304 | `EpgHandler` | Small |
| 3.11 | EPG handler — conditional GET (304) | `EpgHandler` | Small |
| 2.6 | Backup — include recording rules, skip markers, EPG import profiles | `BackupController` | Small-medium |
| 3.9 | Backup restore — merge option | `BackupController` + `Settings.tsx` | Small-medium |
| 3.2 | EPG series recording — channel-scoped title matching | `EpgController` | Small |
| 3.7 | Search — fuzzy token matching | `SearchIndexService` | Small-medium |
| 2.10 | Search — faceted kind filtering | `SearchController` + `Search.tsx` | Small |
| S5 | Audit log for sensitive operations | `SettingsController` | Small |

---

### Sprint 4 — User Experience & Streaming (3–4 days)

Medium-effort items that complete partially-built features and improve day-to-day usability.

| # | Item | Area | Effort |
|---|------|------|--------|
| 2.13 | Playlist merge | `CustomPlaylistsController` + `PlaylistManager.tsx` | Small |
| 2.11 | Favorites ordering | `FavoritesController` + `ChannelManager.tsx` | Medium |
| 2.3 | Watch history resume position | `WatchProgress` + `Player.tsx` | Medium |
| 2.16 | Catchup disk space limit | `TimeshiftBufferManager` + `Servers.tsx` | Medium |
| 3.6 | Transcode quality profile — use configured value | `TranscodeSessionManager` | Medium |
| 3.12 | Concurrent source fetching in ProviderService | `ProviderService` | Medium |
| 4.7 | Channel Manager — bulk test selected | `ChannelManager.tsx` | Small |
| 4.5 | Logs — persist filter state in sessionStorage | `Logs.tsx` | Very small |
| 4.6 | Search — keyboard navigation | `Search.tsx` | Small |

---

### Sprint 5 — Auto-Backup, Notifications & Security (3–4 days)

Scheduled automation, webhook hardening, and the remaining security items.

| # | Item | Area | Effort |
|---|------|------|--------|
| 2.5 | Scheduled auto-backup with retention | `HubSettings` + Quartz worker + `Settings.tsx` | Medium |
| 2.19 / S4 | Webhook HMAC-SHA256 signing | `NotificationService` + `Servers.tsx` | Small |
| S2 | Factory reset — short-lived token CSRF protection | `SettingsController` | Small |
| S3 | Metrics endpoint — auth required by default | `StatusController` + `AppSettings` | Small |
| 4.4 | EPG Import — preview file download | `EpgImportController` + `EpgImport.tsx` | Small |
| 4.2 | Sources — YouTube format override field | `Sources.tsx` | Small |
| 4.3 | Settings — CORS allowed origins UI | `Settings.tsx` | Small |

---

### Sprint 6 — Advanced Streaming & DVR (5+ days)

Larger, higher-risk features. Tackle once earlier sprints are stable.

| # | Item | Area | Effort |
|---|------|------|--------|
| 3.14 | HDR preservation in transcoding | `TranscodeSessionManager` | Medium |
| 2.14 | Per-stream parental PIN challenge | `StreamHandler` + `HubUser` | Medium-large |
| 2.20 | Recording rules — actual recording via ffmpeg | `RecordingRuleSchedulerWorker` + `StatusController` | Large |
