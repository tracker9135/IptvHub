# IPTV Hub — UX Review (May 30, 2026)

Full review across all 13 pages and key components post Sprint 4. 50 issues identified, organized into 4 sprints.

The main themes found are:

1. **Hard UI bugs** — rendering/styling defects that are wrong right now.
2. **Missing per-feature controls** — data models expose flags/fields the UI has no way to reach.
3. **Channel Manager UX at scale** — no virtualization, no sort, no bulk test.
4. **Player gaps** — works only for Live (streamId-based), limited controls.
5. **Consistency gaps** — `<select>` vs pill tabs; empty-state handling uneven across pages.

---

## Sprint 5A — Bug Fixes
**Goal**: Fix defects that are wrong right now — no new features, safe to ship immediately.
**Estimated effort**: 1–2 days

| # | Page | Issue | Fix |
|---|------|-------|-----|
| A | `Dashboard.tsx` | `RecordingsWidget` uses `bg-surface-800` — not defined in Tailwind; widget renders unstyled | Replace `bg-surface-800` with `bg-gray-900` on [line 552](src/IptvHub.Web/src/pages/Dashboard.tsx#L552) |
| B | `Dashboard.tsx` | StatCard grid declared `2xl:grid-cols-7` but 8 cards are rendered — 8th wraps to orphaned row | Change grid class to `2xl:grid-cols-8` on [line 219](src/IptvHub.Web/src/pages/Dashboard.tsx#L219) |
| C | `Dashboard.tsx` | `kick.isPending` shared mutation disables all stream rows when any single kick fires | Scope disabled state per row: `kick.isPending && kick.variables === s.id` |
| D | `Dashboard.tsx` | Channel browser is toggled open but silently renders nothing when no server is running | Render ChannelBrowser unconditionally (it has its own empty state), or show "No running servers to browse" |
| E | `Search.tsx` | Kind chip click writes `q` + `kind` to URL params but drops `serverId` — shared links lose server context | Include `serverId` in `setParams` call inside the chip click handler |
| F | `Settings.tsx` | Auto-backup interval `0` has no label; users may interpret it as "continuous" rather than "disabled" | Add helper text beneath the input: "Set to 0 to disable auto-backup" |
| G | `EpgImport.tsx` | SFTP password field has no show/hide eye toggle — inconsistent with SMTP and XC password fields elsewhere | Add eye-icon pattern (already used in `Servers.tsx` for smtpPassword) to the sftpPassword field |
| H | `ChannelManager.tsx` | `Cast` icon imported from Lucide but never used | Remove unused import |

---

## Sprint 5B — Channel Manager & Sources UX
**Goal**: Make the two most-used data-browsing pages usable at real-world scale (10k–100k channels, failed sources).
**Estimated effort**: 3–4 days

### 5B.1 Channel list has no virtualization — `ChannelManager.tsx` 🔴
The channel table renders every row in the DOM. Sources with 50,000+ channels produce a DOM of 50k+ `<tr>` elements, causing severe scroll jank and high memory usage. The Logs page already uses `@tanstack/react-virtual` for exactly this purpose.
- **Fix**: Wrap the channel rows in a `useVirtualizer` from `@tanstack/react-virtual` (already installed). Estimate row height at 48px. Mirror the pattern from `Logs.tsx`.

### 5B.2 No column-header sort — `ChannelManager.tsx` 🟠
Channels always appear in source order with no way to reorder by name, health status (dead first), or category.
- **Fix**: Add a `sortKey` / `sortDir` state. Click on "Name", "Category", or "Status" column headers to cycle `asc → desc → none`. Apply sort before the virtualized slice.

### 5B.3 No "Reset all filters" button — `ChannelManager.tsx` 🟠
When category + search + inhibited + favorites filters are all active there is no single "Reset" button. Users must clear each control individually.
- **Fix**: Show a `Reset filters` pill/button whenever any filter is non-default. Clicking it calls `setSearch(''); setCategoryFilter(''); setShowInhibited(false); setShowFavoritesOnly(false)` in one action.

### 5B.4 Test results are lost on navigation — `ChannelManager.tsx` 🟠
`testResults` lives in component memory. Navigating away (e.g., to Player and back) discards all results. Tests are expensive real HTTP requests.
- **Fix**: Persist results in `sessionStorage` under key `testResults-{serverId}` using the existing TTL ref mechanism. Restore on mount.

### 5B.5 `lastRefreshError` never shown — `Sources.tsx` 🟠
`IptvSource.lastRefreshError` is set by the backend but the Sources page only shows a pass/fail badge — the error message itself is never displayed. Users must go to Logs to diagnose failures.
- **Fix**: When `!lastRefreshSucceeded && lastRefreshError`, show a truncated error string inline below the source row (max 2 lines, expandable on click). Reuse the red badge styling already used for errors in `Jobs.tsx`.

### 5B.6 Dashboard QoS filter is a `<select>` beside pill tabs — `Dashboard.tsx` 🟡
The workspace filter is now pill tabs (Sprint 4) but the QoS profile filter immediately beside it is still a `<select>`. They sit in the same filter row, visually inconsistent.
- **Fix**: Replace the `<select>` with pill buttons: All / Balanced / CPU Saver / High Quality. Same `selectedQos` state, same pill CSS as workspace tabs.

### 5B.7 Search is not live — `Search.tsx` 🟡
The search input requires pressing Enter or clicking the Search button. `enabled: q.trim().length >= 2` is already in place.
- **Fix**: Add a `useDebounce(q, 300)` hook; drive `enabled` from the debounced value. Remove the explicit Search button (or keep it as an alias for pressing Enter).

---

## Sprint 5C — Missing Model→UI Controls (Servers & Users)
**Goal**: Expose server/user configuration fields that exist in the data model but have no UI.
**Estimated effort**: 2–3 days

### 5C.1 `HubUser.isEnabled` toggle missing in user list — `Servers.tsx` 🔴
`HubUser` has `isEnabled: boolean`. The user rows in the edit panel expose `maxConnections`, `blockAdultContent`, `parentalPinRequired`, and allowed hours — but there is **no toggle to enable/disable a user account**. A disabled user has no visual indicator.
- **Fix**: Add an enabled/disabled toggle (same `Toggle` component used throughout the form) at the start of each user row. Style disabled rows with reduced opacity `opacity-50` to make the state visible at a glance. Apply to both the existing-user rows and the new-user entry row.

### 5C.2 `HubUser.allowedCategoryIds` has no UI — `Servers.tsx` 🟠
`HubUser.allowedCategoryIds: string[]` is a per-user whitelist of permitted category IDs. It is never surfaced in the UI, so there is no way to restrict a user to a subset of channel categories.
- **Fix**: Below the allowed-hours row for each user, add a tag-input for category IDs. The server's `categories` list (already fetched via `getChannels`) can provide autocomplete suggestions. Store as `string[]`.

### 5C.3 `adultCategoryNames` absent from create-server form — `Servers.tsx` 🟠
`adultCategoryNames` (comma-list of category names treated as adult content) exists in the edit panel but not in the create-server form. A newly created server cannot have this configured without immediately re-opening edit.
- **Fix**: Add an `adultCategoryNames` text input to the create form below the toggle strip, only rendered if the server-level parental controls are relevant (always show it for consistency).

### 5C.4 EPG Feeds and EPG Channel Map sections are not collapsible — `Servers.tsx` 🟡
Sprint 4 made Sources, Users, Notifications, Catchup, and Transcoding collapsible, but EPG Feeds and EPG Channel Map sections (`enableEpg: true`) were skipped. These sections can be very long (dozens of feeds/maps).
- **Fix**: Apply the same `toggleSection` + `ChevronDown/ChevronRight` pattern to `epgFeeds` and `epgChannelMap` sections. Default `epgFeeds` to open; `epgChannelMap` to collapsed unless `channelMaps.length > 0`.

### 5C.5 `enableBrowserPushNotifications` toggle never requests permission — `Servers.tsx` 🟡
Enabling the browser push notification toggle does not call `Notification.requestPermission()`. Without the browser grant, push notifications silently fail.
- **Fix**: In the toggle's `onChange` handler, when value becomes `true`, call `Notification.requestPermission()` and only persist the toggle if the result is `'granted'`. Show a warning banner if the user denies the permission.

### 5C.6 Create-server form cannot pre-assign Sources — `Servers.tsx` 🟡
A newly created server always starts with `sourceIds: []`. Users are forced to open the edit panel immediately after creating. The Sources section from the edit panel can be simplified into the create form.
- **Fix**: Add a multi-select source picker to the create form (a list of checkboxes from the loaded sources). Reuse the existing `sourceIds` field in the `defaultConfig()` object.

---

## Sprint 5D — Player, EPG Timeline & Playlists
**Goal**: Fill the most visible feature gaps in playback, scheduling, and playlist management.
**Estimated effort**: 3–4 days

### 5D.1 Player skip markers hardcoded to `contentType: 'Live'` — `Player.tsx` 🟠
**File:** [Player.tsx](src/IptvHub.Web/src/pages/Player.tsx#L56)  
`getSkipMarkers(serverId, 'Live', String(streamId))` — the content type is hardcoded. If the player is ever extended to VOD/Series, markers for those types will never load.
- **Fix**: Accept a `contentType` search param (default `'Live'`) and pass it through to `getSkipMarkers`.

### 5D.2 No EPG timeline date navigation — `Epg.tsx` 🟠
**File:** [Epg.tsx](src/IptvHub.Web/src/pages/Epg.tsx)  
The EPG timeline shows a fixed time window with no day navigation. Users cannot browse past or future schedules.
- **Fix**: Add "← Yesterday" / "Today" / "Tomorrow →" navigation buttons above the timeline. Drive the timeline offset from a `selectedDate` state (default `today`). Pass the date to the EPG data query.

### 5D.3 Search kind chip drops `serverId` from URL — `Search.tsx` 🟠
_(Also listed as Sprint 5A item E — if 5A ships first this is already resolved. Include here for tracking if sprints are done in parallel.)_

### 5D.4 No search within playlist entries — `PlaylistManager.tsx` 🟡
With 200+ entries in a playlist, there is no way to find a specific channel without scrolling.
- **Fix**: Add a filter `<input>` above the entry list. Filter `entries` in render by the search term against `channelNameMap[entry.channelId]`.

### 5D.5 No bulk-remove from playlist — `PlaylistManager.tsx` 🟡
Entries can only be removed one-at-a-time. There is no multi-select or "Remove all" action.
- **Fix**: Add row checkboxes. When any are checked, show a "Remove selected" button in the playlist toolbar. "Remove all" can be a separate destructive action with a confirmation dialog.

### 5D.6 "Add to Source" success has no navigation link — `PlaylistManager.tsx` 🟡
When a playlist is published as an M3U source, `addedSourceId` is tracked but the success feedback has no link to navigate to that new source in the Sources page.
- **Fix**: Replace the plain success indicator with a `<Link to="/sources">View source →</Link>` banner that appears for 10 seconds after the mutation completes.

### 5D.7 No Picture-in-Picture button — `Player.tsx` 🟡
The Remote Playback API (Cast/AirPlay) is implemented but there is no PiP button.
- **Fix**: Add a `PictureInPicture` icon button that calls `videoRef.current.requestPictureInPicture()`. Conditionally render only when `document.pictureInPictureEnabled` is `true`.

### 5D.8 Logger column shows full .NET qualified names — `Logs.tsx` 🟡
`logger` values like `IptvHub.Service.Services.ProviderService` overflow cells and are hard to scan.
- **Fix**: Display only the last segment (`s.split('.').at(-1)`) in the cell, with the full name in a `title` tooltip. This is a one-line render change.

### 5D.9 Logger filter missing from Logs toolbar — `Logs.tsx` 🟡
The toolbar has date and level filters but no way to filter to a specific logger/class.
- **Fix**: Add a logger `<select>` populated by `[...new Set(entries.map(e => e.logger.split('.').at(-1)))]`. Filtering applies the same pattern as the existing level filter.

### 5D.10 No result count in Search kind chip labels — `Search.tsx` 🟢
Filter chips show "Live", "VOD", "Series", "EPG" with no counts.
- **Fix**: After data loads, append the count in parens: `Live (42)`. If loading, show a `Loader2` spinner inline.

---

## Summary

| Sprint | Theme | Items | Est. Effort |
|--------|-------|-------|-------------|
| Sprint 5A | Bug Fixes | A–H (8 items) | 1–2 days |
| Sprint 5B | Channel Manager & Sources UX | 5B.1–5B.7 (7 items) | 3–4 days |
| Sprint 5C | Missing Model→UI Controls | 5C.1–5C.6 (6 items) | 2–3 days |
| Sprint 5D | Player, EPG Timeline & Playlists | 5D.1–5D.10 (10 items) | 3–4 days |
| **Total** | | **31 prioritised items** | **9–13 days** |

| Severity | Count |
|---|---|
| 🔴 Critical / wrong now | 5 |
| 🟠 High — missing or broken features | 12 |
| 🟡 Medium — UX completeness | 12 |
| 🟢 Polish | 2 |
