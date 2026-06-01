# IPTV Hub — UX Review (May 30, 2026)

Full review across all 13 pages and key components. 27 issues identified, organized into 4 sprints.

---

## Sprint 1 — Quick Wins
**Goal**: High-visibility polish with minimal risk. All changes are isolated, no new components needed.
**Estimated effort**: 1–2 days

| # | Page | Issue | Fix |
|---|------|-------|-----|
| A | All | Missing `title` tooltip on icon-only buttons | Add `title=` to all `<button>` with only an icon and no label |
| B | `Sources.tsx` | "Test" button has no loading spinner during test | Wire `isTesting` to show `<Loader size={14} className="animate-spin" />` |
| C | `ChannelManager` | Clearing search requires triple-click or backspacing | Add an `×` clear button inside the search input |
| D | `PlaylistManager` | Rename input doesn't submit on Enter | Add `onKeyDown` handler for Enter key (same pattern as create input) |
| E | `Settings` | Backup passphrase has no show/hide toggle | Add eye icon — pattern already exists for TMDB key on same page |
| F | `Jobs` | Retry buttons have no pending/disabled state | Wire `retryRefreshMut.isPending` / `retryPushMut.isPending` to disable + show spinner |
| G | `Sources` | `maxConcurrentStreams = 0` and `refreshIntervalMinutes = 0` undocumented | Add `text-xs text-gray-500` helper text below each input explaining 0 = unlimited / manual |
| H | `Search` | Kind chip change doesn't update URL params | Add `setParams` call when kind chip is clicked so filtered URLs are shareable |
| I | `Logs` | No "X of Y" count when search is active | Show `Showing {entries.length} of {data?.entries.length}` in subtitle when `search` is non-empty |
| J | `Servers` | Create form validation errors don't highlight the offending field | Add `border-red-500` to `name`, `port`, and `bindAddress` inputs when respective errors are present |

---

## Sprint 2 — Critical Fixes + Feedback Loop
**Goal**: Eliminate silent failures and broken flows that undermine trust in the app.
**Estimated effort**: 2–3 days

### 2.1 Search results don't deep-link — `Search.tsx` 🔴
Clicking any result navigates to the generic `/channels` or `/epg` route. The user lands on the page and has to manually search again.
- **Fix**: Pass `?q=<title>` (and optionally `serverId`) when navigating from a search result so the destination page pre-filters. For EPG results, navigate to `/epg` with the channel pre-selected.

### 2.2 No success feedback after server/source save — `Servers.tsx`, `Sources.tsx` 🔴
`updateMut.onSuccess` closes the panel silently. `Settings.tsx` already has a working `Banner` component.
- **Fix**: Reuse the `Banner` pattern (or a lightweight toast) in Servers and Sources to confirm saves and show mutation errors inline.

### 2.3 ChannelManager test results never expire 🟠
`testResults` state is never cleared. Results linger across server switches — stale pass/fail badges from a different server's stream IDs appear on matching IDs.
- **Fix**: Clear `testResults` in the `useEffect` that responds to `serverId` changes. Add an optional 2-minute TTL using a timestamp map so very old results fade out automatically.

### 2.4 Jobs retry buttons have no loading state — `Jobs.tsx` 🟡
`retryRefreshMut.isPending` / `retryPushMut.isPending` are not wired to the retry button UI. Buttons stay enabled and show no spinner during the operation. _(Also listed as Quick Win F above — if Sprint 1 is done first, this is already resolved.)_

### 2.5 Servers page: start/stop loading indicator not scoped per server — `Servers.tsx` 🟡
`startMut.isPending` and `stopMut.isPending` disable buttons on **all** servers simultaneously when one is toggled. Confusing with multiple servers.
- **Fix**: Track `pendingServerId` in local state alongside the mutation and scope the disabled/spinner state to that single server's row.

---

## Sprint 3 — Discoverability & Safety
**Goal**: Prevent data-entry confusion and make key features visible to first-time users.
**Estimated effort**: 2–3 days

### 3.1 Validation errors don't highlight the offending field — `Servers.tsx` 🔴
`createErrors` is shown in a red block but all four input fields remain visually unchanged.
- **Fix**: Add `border-red-500` conditionally to each input based on which error is present. _(Quick Win J covers the create form; this sprint extends it to the edit form and Sources.)_

### 3.2 Category filter is a `<select>` with no search — `ChannelManager.tsx` 🟠
Scrolling through hundreds of categories to find one is unusable.
- **Fix**: Replace the `<select>` with a type-ahead searchable dropdown — a controlled `<input>` that filters the category list and shows matches in a floating list below.

### 3.3 Password / secret fields have no show/hide toggle 🟠
`xcPassword`, `plexToken`, `jellyfinApiKey`, `smtpPassword` (in server edit), and `backupPassphrase` (Settings) are plain `type="password"` with no eye icon. The toggle pattern already exists for TMDB key and parental PIN in `Settings.tsx`.
- **Fix**: Extract a `<PasswordInput>` wrapper component with an integrated eye toggle; apply to all secret fields across Sources, Servers, and Settings.

### 3.4 Empty states missing across multiple pages 🟠
- **Dashboard**: no guidance when no servers exist — render a call-to-action card directing the user to add a server
- **PlaylistManager**: completely blank body when no playlists exist — add an empty state with a "Create your first playlist" prompt
- **ChannelManager**: no message when the selected server has 0 channels — add "No channels found. Try refreshing the server." with a Refresh button

### 3.5 Channel count badge missing when inhibited channels are hidden — `ChannelManager.tsx` 🟠
The header count doesn't reflect the active filter state.
- **Fix**: Add `Showing {visibleChannels.length} of {allChannels.length}` near the filter controls whenever the counts differ.

### 3.6 `Sources.tsx` — zero values have no explanation 🟠
`refreshIntervalMinutes = 0` means manual-only. `maxConcurrentStreams = 0` means unlimited. Both are silent. _(Also in Quick Win G — Sprint 1 covers the helper text; this sprint can add `placeholder` text and tooltip as a secondary reinforcement.)_

---

## Sprint 4 — Structure & Polish
**Goal**: Improve information architecture and navigation for power users managing complex setups.
**Estimated effort**: 3–4 days

### 4.1 Server edit form is one unbroken scroll — `Servers.tsx` 🟡
The edit panel for a complex server covers ~60 form fields across Sources, Users, Transcoding, Notifications, and EPG sections with only horizontal rules as dividers.
- **Fix**: Introduce collapsible section headers (chevron toggle) for Sources, Users, Transcoding, and Notifications. Users is the most important — open by default if users exist.

### 4.2 "Add User" dual-path behavior is undocumented — `Servers.tsx` 🟡
The form auto-adds a pending user row on Save if both fields are filled — but there's also an explicit "Add" button. The dual path creates confusion about when the user was actually added.
- **Fix**: Remove the auto-add-on-save shortcut and add a helper note under the user input row: _"Fill credentials and press Add before saving."_

### 4.3 Search kind chips don't preserve state in URL — `Search.tsx` 🟡
Switching the kind chip (Live / VOD / Series / EPG) is not reflected in the URL. Bookmarks and shared links always land on "All." _(Quick Win H covers adding `setParams` to the chip click handler.)_

### 4.4 Logs: no filtered vs total count — `Logs.tsx` 🟡
When a text search is active the subtitle only shows the filtered count, with no indication of how many entries were hidden.
- **Fix**: Change subtitle to `Showing {entries.length} of {data?.entries.length} entries` when `search` is non-empty. _(Duplicate of Quick Win I — resolved in Sprint 1.)_

### 4.5 Dashboard workspace filter: dropdown → pill tabs 🟡
With 2–5 workspaces, pill-style tab buttons are faster to scan and click than a `<select>`.
- **Fix**: Replace the `<select>` with a flex row of pill buttons (one per workspace + "All") using the same `selectedWorkspace` state.

### 4.6 Player: no link back to originating channel 🟡
After launching the Player modal there's no way to navigate back to the channel's context in the Channel Manager or Dashboard.
- **Fix**: Show a small "View in Channel Manager →" link in the player header/footer that navigates to `/channels?serverId=X&search=<channelName>`.

---

## Summary

| Sprint | Theme | Items | Est. Effort |
|--------|-------|-------|-------------|
| Sprint 1 | Quick Wins | A–J (10 items) | 1–2 days |
| Sprint 2 | Critical Fixes + Feedback | 2.1–2.5 (5 items) | 2–3 days |
| Sprint 3 | Discoverability & Safety | 3.1–3.6 (6 items) | 2–3 days |
| Sprint 4 | Structure & Polish | 4.1–4.6 (6 items) | 3–4 days |
| **Total** | | **27 items** | **8–12 days** |

| Severity | Count |
|---|---|
| 🔴 Critical | 3 |
| 🟠 High | 6 |
| 🟡 Medium | 8 |
| 🟢 Quick wins | 10 |
