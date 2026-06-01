# IPTV Hub — UX Review (June 2026)

Full review across all 13 pages and key components post Sprint 5D. 42 issues identified, organized into 4 sprints.

The main themes found are:

1. **Critical bug** — Health alert banner has a logic error that silently suppresses critical-level snapshot staleness warnings.
2. **Information density** — Multiple dashboard stat cards use cryptic abbreviated codes with no labels and raw second values instead of human-readable durations.
3. **Navigation inconsistencies** — Back buttons and cross-page links are sometimes hardcoded to specific destinations instead of respecting context.
4. **Form & editor UX gaps** — Several multi-section pages lack unsaved-changes warnings, section anchors, and missing per-row feedback.
5. **Debug text leaking** — Internal state values (remote playback state, raw UUIDs) shown as user-visible text instead of being hidden or formatted.

---

## Sprint 6A — Bug Fixes & Critical UX *(Shipped)*
**Goal**: Fix the health alert banner bug and make dashboard stat cards readable.
**Effort**: 0.5 days

| # | Page / Component | Issue | Fix Applied |
|---|-----------------|-------|-------------|
| 6A.1 | `Dashboard.tsx` | **CRITICAL BUG** — Health alert banner uses `isSnapshotWarning \|\| ffmpegWarning \|\| swWarning` as its condition. Because `isSnapshotWarning = !isSnapshotCritical && ...`, a *critical-only* snapshot staleness (no warnings, no ffmpeg, no SW issues) never triggers the banner — the most severe alert is silently suppressed. | Added `isSnapshotCritical` to the banner show condition: `(isSnapshotCritical \|\| isSnapshotWarning \|\| ffmpegWarning \|\| swWarning)` |
| 6A.2 | `Dashboard.tsx` | Health alert threshold text shows raw seconds: `>= 300s`. Non-technical users have no idea what 300s means. | Replaced with `>= 5 min` using `Math.round(SNAPSHOT_CRITICAL_SECONDS / 60)` |
| 6A.3 | `Dashboard.tsx` | "Media Pipelines" stat card shows `T:0 C:0` — opaque abbreviations with no context. Hovering gives no hint what T and C mean. | Changed to `0T · 0C` format with a `title` tooltip on the card: "0 transcode · 0 catchup buffer". `StatCard` now accepts an optional `title` prop applied to the wrapper `div`. |
| 6A.4 | `Dashboard.tsx` | "QoS Profiles" stat card shows `B:1 C:0 H:0` — abbreviations with no labels. | Changed to `1B · 0CS · 0HQ` with tooltip "1 balanced · 0 CPU saver · 0 high quality" |
| 6A.5 | `Dashboard.tsx` | "Snapshot Freshness" stat card shows `300s` — raw seconds. Values > 60s are hard to parse at a glance. | Now shows `5m 0s` format for values ≥ 60s, plain seconds for values < 60s |
| 6A.6 | `Dashboard.tsx` | Server cards show "Last refresh: 10:23:04" — an absolute time that forces mental arithmetic. | Added `timeAgo()` helper; server cards now show "2m ago", "1h ago", etc. Full timestamp remains available as a `title` tooltip. |

---

## Sprint 6B — Dashboard Information Density *(Shipped)*
**Goal**: Make the Scheduler and Cache Snapshot cards easier to read at a glance.
**Effort**: 0.5 days

| # | Page / Component | Issue | Fix Applied |
|---|-----------------|-------|-------------|
| 6B.1 | `Dashboard.tsx` | Scheduler queue mini-card shows `R0 Q0 C0 F0 D0` codes per queue row — looks like engineer debug output. Zero-values add visual noise and teach nothing. | Replaced with natural-language labels: shows coloured "N running" / "N queued" / "idle" / "N failed" — suppresses zero-value counts. Running shows in blue, queued in yellow, failed in red. |
| 6B.2 | `Dashboard.tsx` | Offline Cache Snapshots card shows "EPG summary: 320s old" — raw seconds that force mental math. | Changed to `5m old` for values ≥ 60s, keeping `Xs old` for short durations |
| 6B.3 | `Dashboard.tsx` | `StatCard` component had no `title` prop, so tooltips could not be added by callers. | Added optional `title?: string` prop forwarded to the root `<div>` as HTML `title` attribute |
| 6B.4 | `ChannelManager.tsx` | "Save" column header in channel table is misleading — the action saves a channel to a playlist, not to the server. New users think it persists a config change. | Renamed column header to "Playlist" |

---

## Sprint 6C — Navigation & Player *(Shipped)*
**Goal**: Fix cross-page navigation issues and clean up debug text visible in the Player.
**Effort**: 0.5 days

| # | Page / Component | Issue | Fix Applied |
|---|-----------------|-------|-------------|
| 6C.1 | `ChannelManager.tsx` | "Cast" action navigates to `/player` without `contentType`. Skip markers query on the Player page uses `contentType` to filter, so it defaulted to `'Live'` regardless of the actual channel type. | Added `&contentType=Live` to the player navigate call from Channel Manager |
| 6C.2 | `Player.tsx` | Both "Back" links were hardcoded to `/channels?serverId=...&search=...` (Channel Manager). If the user arrived from Search or another page, the back link takes them somewhere unexpected. | Renamed label from "Back to Channel Manager" to simply "Back" — the URL still targets Channel Manager but the label is now honest about not knowing the full history |
| 6C.3 | `Player.tsx` | "Remote state: unsupported" was always shown as visible text below the Cast button. On most desktop browsers `remote` is not available, so every user sees this debug message. | The remote state `<div>` is now conditionally rendered — only shown when `remoteState` is `'connecting'`, `'connected'`, or `'disconnected'`; hidden for `'unsupported'` |
| 6C.4 | `Logs.tsx` | Date selector for log viewing shows bare ISO dates: `2026-06-01`. Users cannot immediately tell which entry is today without counting. | Date options now show relative labels: "2026-06-01 (Today)" and "2026-06-01 (Yesterday)" for the appropriate dates; older dates show the bare date as before |
| 6C.5 | `Jobs.tsx` | "Trace" column in the Scheduler Jobs table renders full UUIDs (e.g. `7a3d1e2f-...`). This occupies significant horizontal space and is rarely needed at a glance. | Trace column now shows only the last 8 hex chars (e.g. `1042325`), with the full UUID in the `title` tooltip on hover |

---

## Sprint 6D — Implemented

### 6D.1 Sources page: source card last-refresh relative time ✅
Added `timeAgo(src.lastRefreshed)` to each source card with full datetime in `title` tooltip. Created shared `src/utils/timeFormat.ts` utility (also imported by Dashboard.tsx replacing the inline `timeAgo` definition).

### 6D.2 Sources page: collapsed action buttons ✅
Kept Test and Edit as primary inline buttons. Moved Toggle, Clone, and Delete into a `⋯` (MoreHorizontal) dropdown per card, with click-outside dismissal via `useEffect`.

### 6D.3 Settings page: unsaved-changes warning ✅
Added `isDirty` computed value comparing all four field states against `settingsQuery.data`. Shows `● Unsaved changes` amber badge next to both Save buttons when dirty.

### 6D.4 Settings page: renamed `handleSaveTmdb` → `handleSaveSettings` ✅
Renamed function definition and both call sites.

### 6D.5 EpgImport page: clarified Dry run vs Preview ✅
Added descriptive `title` tooltips: "Preview — fetch and inspect the EPG file without importing" and "Dry-run — simulate the full import and show what would change, without committing".

### 6D.6 Channel Manager: bulk bar overflow ✅
Added `showAdvancedBulk` toggle button ("Advanced ▾/▴"). Dry run inhibit, Dry run uninhibit, and Apply dry run are now hidden behind this toggle, reducing the primary bar to 4 buttons.

### 6D.7 Search results: VOD/Series contentType param ✅
Navigate for Vod and Series results now includes `&contentType=Vod` or `&contentType=Series` in the Channel Manager URL.

### 6D.8 Login page: color consistency ✅
Inputs: `bg-gray-700 border-gray-600 focus:ring-blue-500` → `bg-gray-900 border-gray-700 focus:ring-brand-500`. Logo circle and submit button: `bg-blue-600 hover:bg-blue-500` → `bg-brand-600 hover:bg-brand-700`. Checkbox: `bg-gray-700 text-blue-500` → `bg-gray-800 text-brand-500`.

### 6D.9 Sidebar: compact language/theme selects ✅
Replaced two stacked select elements (each with label row) with a single flex row of two side-by-side compact selects (`py-1.5` instead of `py-2`). Saves ~50px vertical height.

### 6D.10 Dashboard: channel browser duplicate option ✅
Changed first option from `{channelServerOptions[0]?.config.name}` to `"Auto (first running)"` so the first server no longer appears twice in the dropdown.

### 6D.11 Player: unmute overlay button ✅
Added `isMuted` state (default `true`). Video element uses `muted={isMuted}`. Added a "Tap to unmute" overlay chip (top-right corner, `VolumeX` icon) that dismisses when clicked.

### 6D.12 Jobs: queue ages human-readable ✅
Imported `formatAge` from shared `timeFormat.ts` utility. Both "Oldest wait" and "Oldest run" columns now display `3600s` as `60m`, `7200s` as `2h`, etc.

---

## Summary of Changes Applied This Session

| Sprint | Items Implemented | TypeScript |
|--------|-------------------|-----------|
| 6A | 6 items (banner bug fix, StatCard title prop, 4 human-readable stat values) | ✅ Clean |
| 6B | 4 items (scheduler codes, snapshot card, StatCard prop, column rename) | ✅ Clean |
| 6C | 5 items (contentType nav, back label, remote state text, log dates, trace IDs) | ✅ Clean |
| 6D | 12 items (timeAgo utility, Sources button collapse, Settings dirty warning, EpgImport tooltips, ChannelManager Advanced toggle, Search contentType, Login colors, Sidebar compact selects, Dashboard duplicate option fix, Player unmute chip, Jobs age format) | ✅ Clean |

**Total implemented: 27 items across 10 files**
- `Dashboard.tsx`: 8 changes (banner bug, `timeAgo`, stat card labels/tooltips, scheduler codes, snapshot age, `StatCard` prop)
- `ChannelManager.tsx`: 2 changes (column rename, contentType nav)
- `Player.tsx`: 2 changes (back label, remote state conditional)
- `Logs.tsx`: 1 change (relative date labels)
- `Jobs.tsx`: 1 change (trace ID truncation)
