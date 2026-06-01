# Deep Code Review: Frontend (IptvHub.Web)

Date: 2026-05-28
Scope: Full review of src/IptvHub.Web/src — API layer, React components, pages, utilities, auth, build config.

---

## Findings (ordered by severity)

### 1. High: Cleartext credentials embedded in stream URLs sent to the browser

- **File:** [src/IptvHub.Web/src/utils/streaming.ts](src/IptvHub.Web/src/utils/streaming.ts#L18)
- **Also:** [src/IptvHub.Web/src/pages/Servers.tsx](src/IptvHub.Web/src/pages/Servers.tsx#L91)
- **Evidence:**
  ```ts
  return `http://${host}:${config.port}/live/${user.username}/${user.password}/${streamId}.ts`
  // and
  const auth = user ? `username=${encodeURIComponent(user.username)}&password=${encodeURIComponent(user.password)}&` : ''
  ```
- **Why this matters:** The full server-user password is embedded in cleartext URLs that appear in the browser address bar, are stored in browser history, logged by reverse proxies, and visible to anyone with access to DevTools or shared links. Any Xtream-compatible player URL (`get.php?username=…&password=…`) also leaks credentials in query strings. This is the most direct credential-exposure risk in the codebase.
- **Recommendation:** Use a short-lived signed token or a server-issued play token that the backend exchanges for the real credentials, keeping the password out of the URL entirely. At minimum, the playlist URL builder should route through the `/api/channels/{serverId}/{streamId}/play.m3u` proxy endpoint (which is already implemented) and never construct bare credential URLs client-side.

---

### 2. High: `i18n` initialised with `escapeValue: false` — XSS risk if server-sourced strings reach translation keys

- **File:** [src/IptvHub.Web/src/i18n.ts](src/IptvHub.Web/src/i18n.ts#L16)
- **Evidence:**
  ```ts
  interpolation: {
    escapeValue: false   // React already escapes — BUT only for JSX paths
  }
  ```
- **Why this matters:** `react-i18next` sets `escapeValue: false` by default because React JSX auto-escapes. However, if any translated string is passed to a non-JSX context (e.g., `document.title = t(...)`, `placeholder={t(...)}` rendered via `innerHTML`, or a third-party component that sets `innerHTML`), the raw value is emitted without HTML entity encoding. The locale files are currently static, but if they ever come from the API or are user-configurable (e.g., per-server labels), this becomes an injection vector. The setting also lulls developers into thinking escaping is globally handled.
- **Recommendation:** Either keep `escapeValue: false` only with a documented policy that translated strings must never be used in `innerHTML` contexts, or enable it and use the `<Trans>` component with `{/* interpolation */}` for JSX. Add a lint rule (`no-dangerously-set-inner-html`) as a safety net.

---

### 3. High: `window.confirm` used for destructive-action guard — blocked in embedded and some mobile contexts

- **File:** [src/IptvHub.Web/src/pages/Servers.tsx](src/IptvHub.Web/src/pages/Servers.tsx#L175)
- **Also:** [src/IptvHub.Web/src/pages/Settings.tsx](src/IptvHub.Web/src/pages/Settings.tsx#L512), [src/IptvHub.Web/src/pages/EpgImport.tsx](src/IptvHub.Web/src/pages/EpgImport.tsx#L675)
- **Evidence:**
  ```ts
  if (isEditDirty && !window.confirm('Discard unsaved server changes?')) { return }
  if (!window.confirm('This will permanently erase all app data and sign you out. Continue?')) return
  ```
- **Why this matters:** `window.confirm` is suppressed silently (returns `true`) when the app is embedded in an iframe, opened as a PWA in some browsers, or running under certain automation tools. For factory reset — a fully destructive, irreversible action — a silent `true` could trigger unintended data loss. The Settings page already has a typed-confirmation `ConfirmDialog` component for other flows; factory reset bypasses it.
- **Recommendation:** Replace all `window.confirm` calls with the existing `ConfirmDialog` component. For factory reset specifically, use `requireText="FACTORY RESET"` to force explicit typed confirmation.

---

### 4. High: `getSources`, `getSourceChannelCounts`, `getLogs`, `getLogDates`, and several other API calls have no `AbortSignal`

- **File:** [src/IptvHub.Web/src/api/client.ts](src/IptvHub.Web/src/api/client.ts)
- **Evidence:**
  ```ts
  export const getSources = (): Promise<IptvSource[]> =>
    api.get('/sources').then(r => r.data)                // no signal
  export const getLogs = (date?, minLevel?): Promise<LogsResponse> =>
    api.get('/logs', { params: { ... } }).then(r => r.data)  // no signal
  export const getSourceChannelCounts = (): Promise<Record<string, number>> =>
    api.get('/sources/channel-counts').then(r => r.data) // no signal
  ```
- **Why this matters:** React Query passes `{ signal }` from the query function context. Without forwarding it, in-flight requests from unmounted components or superseded queries continue running and — when they resolve — attempt to update stale state. Combined with polling intervals this generates unnecessary network traffic and can produce race conditions on fast navigation.
- **Recommendation:** Add `options?: RequestOptions` parameter and forward `signal` to all remaining GET calls: `getSources`, `getSourceChannelCounts`, `getLogs`, `getLogDates`, `getSettings`, `getCustomPlaylistCategories`, `discoverSchedulesDirectLineups`.

---

### 5. Medium: Setup-mode password validation is weak — only checks length ≥ 12, not the "number and symbol" requirement shown in the error message

- **File:** [src/IptvHub.Web/src/pages/Login.tsx](src/IptvHub.Web/src/pages/Login.tsx#L57)
- **Evidence:**
  ```ts
  if (password.length < 12) {
    setError('Password must be at least 12 characters and include a number and symbol.')
    return
  }
  ```
- **Why this matters:** The UI error message tells users they need a number and symbol, but the actual check only tests length. A 12-character all-lowercase password is accepted. This is misleading and weakens security posture.
- **Recommendation:** Add `/\d/` and `/[^A-Za-z0-9]/` tests before submitting, or remove the number/symbol claim from the error message if the backend enforces no such rule.

---

### 6. Medium: `verifyParentalPin` swallows all errors and returns `false`, masking transport failures as "incorrect PIN"

- **File:** [src/IptvHub.Web/src/api/client.ts](src/IptvHub.Web/src/api/client.ts#L450)
- **Evidence:**
  ```ts
  export const verifyParentalPin = (pin: string): Promise<true | false | null> =>
    api.post('/settings/verify-pin', { pin })
      .then(r => r.status === 204 ? null : true)
      .catch(() => false as false)
  ```
- **Why this matters:** Any network error, 500, or timeout silently returns `false` — the same value as "wrong PIN". If the server is briefly unavailable, users are told their PIN is wrong rather than that there was a connectivity issue. Depending on how this is consumed, a user could be incorrectly locked out of a parental-control bypass.
- **Recommendation:** Only catch `AxiosError` with status 401/403 and return `false`; rethrow other errors so the caller can display a connection error.

---

### 7. Medium: `AuthContext` auth-refresh does not cancel in-flight requests when a newer refresh supersedes them

- **File:** [src/IptvHub.Web/src/context/AuthContext.tsx](src/IptvHub.Web/src/context/AuthContext.tsx)
- **Evidence:**
  ```ts
  const refreshInternal = useCallback((background = false) => {
    const refreshId = ++refreshSeq.current
    // ...
    getAuthState()
      .then(s => { setState(s); ... })
      .catch(() => { setConnectionError(true) })
  }, [])
  ```
- **Why this matters:** `refreshSeq` is incremented to track the latest refresh, but there is no abort of the previous in-flight request. An older request resolving after a newer one can overwrite a freshly-set auth state (e.g., set `isAuthenticated: false` after a successful re-login). The polling interval is 60 seconds but navigation events also trigger `refreshInternal`, making overlaps possible.
- **Recommendation:** Hold an `AbortController` ref, abort the previous request before starting a new one, and pass the signal to `getAuthState`.

---

### 8. Medium: `concurrency.ts` has a hoisting bug — `completed` is declared after the `runners` array that closes over it

- **File:** [src/IptvHub.Web/src/utils/concurrency.ts](src/IptvHub.Web/src/utils/concurrency.ts#L11)
- **Evidence:**
  ```ts
  const runners = Array.from({ length: ... }, async () => {
    while (...) {
      ...
      } finally {
        completed += 1   // ← closes over `completed` before it is declared
      }
    }
  })
  let completed = 0      // ← declared here, after runners is created
  await Promise.all(runners)
  ```
- **Why this matters:** JavaScript hoists `let` declarations but they are in the temporal dead zone (TDZ) until the declaration is reached. The async runner closures capture the variable reference, which is fine at runtime because they only execute after `let completed = 0` is reached (since the runners are async and `await` hands control back). However, this is fragile and will confuse static analyzers — TypeScript's `noUnusedLocals` and ESLint's `no-use-before-define` may not catch it because the reference is inside an async callback.
- **Recommendation:** Move `let completed = 0` before `const runners` for clarity and correctness.

---

### 9. Medium: `downloadEpgFeed` result type allows `success: false` but the client does not check it after the endpoint now returns 502

- **File:** [src/IptvHub.Web/src/pages/Servers.tsx](src/IptvHub.Web/src/pages/Servers.tsx) / [src/IptvHub.Web/src/api/client.ts](src/IptvHub.Web/src/api/client.ts#L340)
- **Evidence:**
  ```ts
  // EpgDownloadResult has success?: boolean
  // Servers.tsx checks for the result:
  setFeedDownloadResult(prev => ({ ...prev, [feedId]: { ok: true, msg: `...` } }))
  // In catch:
  setFeedDownloadResult(prev => ({ ...prev, [feedId]: { ok: false, msg: err.message } }))
  ```
- **Why this matters:** Now that `DownloadFeed` returns 502 on failure (from the prior fix), axios will throw for non-2xx responses, which the `catch` block handles correctly. But the `EpgDownloadResult` type still has `success?: boolean` and `error?: string`, and any code that called the old 200-with-`success:false` pattern would silently show "ok: true" while the feed actually failed. Verify no component inspects `result.success` without also catching the axios error.
- **Recommendation:** Audit all call sites of `downloadEpgFeed` for `if (result.success === false)` guards that are now dead code, and remove them. Optionally narrow the type to remove `success` and `error` from the happy-path type.

---

### 10. Medium: `EpgTimeline` fires a new program-fetch query on every scroll event via unbounded `fromMinute/toMinute` key changes

- **File:** [src/IptvHub.Web/src/pages/Epg.tsx](src/IptvHub.Web/src/pages/Epg.tsx)
- **Evidence:**
  ```ts
  const fromMinute = Math.max(0, Math.floor((scrollLeft - bufferPx) / pxPerMinute))
  const toMinute   = Math.min(dayMinutes, Math.ceil((scrollLeft + viewWidth + bufferPx) / pxPerMinute))
  // ...
  queryKey: ['epg-timeline-programs', serverId, day, fromMinute, toMinute, visibleIds.join('|')]
  ```
- **Why this matters:** `fromMinute` and `toMinute` change on every pixel of scroll. Each unique key combination triggers a new React Query entry. Scrolling across the full day creates 1440 distinct cache entries and fires hundreds of requests. The `staleTime` is not set on this query (defaults to 10s from QueryClient), so returning to a previously-viewed window still re-fetches within 10 seconds.
- **Recommendation:** Snap `fromMinute`/`toMinute` to a coarser grid (e.g., round to nearest 30 minutes) before using as query keys. Add `staleTime: 5 * 60 * 1000` (5 min) to the programs query since EPG data rarely changes mid-session. Use `keepPreviousData: true` to prevent the grid from blanking while the next window loads.

---

### 11. Medium: `RouteErrorBoundary` "Retry page" resets `error` to `null` but does not remount the child — the same render-crashing component will crash again immediately

- **File:** [src/IptvHub.Web/src/components/RouteErrorBoundary.tsx](src/IptvHub.Web/src/components/RouteErrorBoundary.tsx)
- **Evidence:**
  ```tsx
  <button onClick={() => this.setState({ error: null })}>Retry page</button>
  ```
- **Why this matters:** Clearing the error state causes React to re-render the same child tree. If the error is caused by a permanent condition (missing required prop, null dereference on always-null data), it will throw again on the same render, immediately replacing the retry button with the error UI again. The user gets stuck in a loop with no escape.
- **Recommendation:** Use a `key` on the error boundary child that increments on retry, or navigate to the same route via `useNavigate` to force a clean remount. Optionally add an "Go to Dashboard" fallback link that always works.

---

### 12. Medium: `window.confirm` in `Servers.tsx` is called inside a `useMutation` `onMutate` callback which runs synchronously — any modal-based replacement needs care

- **File:** [src/IptvHub.Web/src/pages/Servers.tsx](src/IptvHub.Web/src/pages/Servers.tsx#L430)
- **Evidence:**
  ```ts
  if (editId && isEditDirty && !window.confirm('Discard unsaved server changes?')) {
  ```
  This runs inside a click handler before a navigation/tab switch, gating whether to close the edit panel. It is in several places in the same component.
- **Why this matters:** Separate from item #3 — this specific instance is inside an imperative click handler, making replacement with an async `ConfirmDialog` require a state machine (open dialog → wait for result → proceed or cancel). Without that, the handler must return early and open a dialog, then the confirmation callback completes the original action. The current structure doesn't support this.
- **Recommendation:** Refactor the "close edit" flow to a two-step pattern: first call sets `pendingNavigation` state, renders `ConfirmDialog`, and the confirm callback completes the navigation. This is the same pattern already used for the delete flow in this component.

---

### 13. Medium: `localStorage` reads on module load (in `i18n.ts`) are outside any try/catch — throws in private browsing mode on some browsers

- **File:** [src/IptvHub.Web/src/i18n.ts](src/IptvHub.Web/src/i18n.ts#L6)
- **Evidence:**
  ```ts
  const savedLocale = localStorage.getItem('iptvhub_locale') ?? 'en'
  ```
- **Why this matters:** Firefox private mode and certain iOS WebViews throw a `SecurityError` on `localStorage` access at the top-level module scope (before any error boundary is mounted). This crashes the entire app on init.
- **Recommendation:** Wrap in a try/catch with a fallback: `const savedLocale = (() => { try { return localStorage.getItem('iptvhub_locale') ?? 'en' } catch { return 'en' } })()`

---

### 14. Medium: `getServerAnalytics` interpolates query param directly in URL string instead of using axios `params` — breaks if `limit` contains special characters

- **File:** [src/IptvHub.Web/src/api/client.ts](src/IptvHub.Web/src/api/client.ts)
- **Evidence:**
  ```ts
  export const getServerAnalytics = (serverId: string, limit = 20): Promise<ChannelAnalytic[]> =>
    api.get(`/servers/${serverId}/analytics?limit=${limit}`).then(r => r.data)
  ```
- **Why this matters:** `serverId` is interpolated directly into the URL path without `encodeURIComponent`. If a server ID ever contains `/`, `?`, `#`, or `%`, it will corrupt the URL. The same issue affects `suggestEpgMappings`:
  ```ts
  api.post(`/epg/suggest-mappings?serverId=${serverId}`)
  ```
- **Recommendation:** Use axios `params` option: `api.get(apiRoutes.serverAnalytics(serverId), { params: { limit } })`, and add the route to `apiRoutes`.

---

### 15. Low: `document.execCommand('copy')` is deprecated and will eventually be removed

- **File:** [src/IptvHub.Web/src/utils/clipboard.ts](src/IptvHub.Web/src/utils/clipboard.ts)
- **Evidence:**
  ```ts
  document.execCommand('copy')
  ```
- **Why this matters:** `execCommand` is deprecated in all major browser vendors. It is used as a fallback when `navigator.clipboard` is unavailable (plain HTTP). Since IptvHub runs over HTTP in LAN configurations, this fallback is frequently used.
- **Recommendation:** The current fallback is fine for now, but add a comment noting the deprecation and that a future migration path is to require HTTPS or use the Clipboard API with user permission prompts.

---

### 16. Low: `AdHocTester` in `Epg.tsx` does not clear the previous test result when the EPG feed type changes

- **File:** [src/IptvHub.Web/src/pages/Epg.tsx](src/IptvHub.Web/src/pages/Epg.tsx)
- **Evidence:** `AdHocTester` is a self-contained component. If a user tests a URL, sees a result, then edits the URL, the old result remains visible until they retest. The `onChange` handler calls `setResult(null)` which is correct, but the test button's `onClick` calls `setResult(null)` and immediately fires the mutation — leaving a brief flash of the old result while the new one loads.
- **Recommendation:** Minor UX issue. Setting `result` to `null` before the mutation fires (which already happens) is correct. Ensure the result is not shown during `testMut.isPending` (currently it is cleared on the button click but could briefly show if `setResult(null)` and mutation state update race). Acceptable as-is but worth noting.

---

### 17. Low: `Player.tsx` — remote playback state is polled every 2 seconds via `setInterval` instead of using the `RemotePlayback` API's event listeners

- **File:** [src/IptvHub.Web/src/pages/Player.tsx](src/IptvHub.Web/src/pages/Player.tsx)
- **Evidence:**
  ```ts
  useEffect(() => {
    const id = window.setInterval(() => {
      const state = (videoRef.current as ...)?.remote?.state
      setRemoteState(state ?? 'unsupported')
    }, 2000)
    return () => window.clearInterval(id)
  }, [])
  ```
- **Why this matters:** The `RemotePlayback` API exposes `connecting`, `connect`, and `disconnect` events. Polling every 2 seconds creates unnecessary re-renders and misses rapid state transitions between poll cycles.
- **Recommendation:** Use `remote.addEventListener('connecting', ...)`, `remote.addEventListener('connect', ...)`, and `remote.addEventListener('disconnect', ...)` event listeners instead of `setInterval`.

---

### 18. Low: EPG timeline program elements are `<div>` with `onClick` but no keyboard role or `tabIndex` — not reachable via keyboard

- **File:** [src/IptvHub.Web/src/pages/Epg.tsx](src/IptvHub.Web/src/pages/Epg.tsx)
- **Why this matters:** EPG program cells are clickable divs in a virtualised canvas-style grid. They have no `role="button"`, `tabIndex`, or `onKeyDown` handler, making them completely inaccessible to keyboard-only users. This violates WCAG 2.1 SC 2.1.1 (Keyboard Accessible).
- **Recommendation:** Add `role="button" tabIndex={0} onKeyDown={e => { if (e.key === 'Enter' || e.key === ' ') handleClick() }}` to program cells, or migrate to native `<button>` elements.

---

### 19. Low: `ConfirmDialog` has both `confirmText` and `confirmLabel` props with overlapping defaults — the rendered label uses `confirmLabel || confirmText`, creating confusion

- **File:** [src/IptvHub.Web/src/components/ConfirmDialog.tsx](src/IptvHub.Web/src/components/ConfirmDialog.tsx#L8)
- **Evidence:**
  ```ts
  confirmText?: string   // default 'Confirm'
  confirmLabel?: string  // default 'Confirm'
  // ...
  {confirmLabel || confirmText}
  ```
- **Why this matters:** Two props do the same thing. Callers that set only `confirmText` are silently overridden by the `confirmLabel` default. This is dead code in practice and a maintenance trap.
- **Recommendation:** Remove `confirmText` and keep only `confirmLabel`.

---

### 20. Low: `vite.config.ts` PWA `workbox.runtimeCaching` caches all `/api/` responses with `NetworkFirst` and a 3-second timeout — cached 502 and 4xx error responses can be served offline

- **File:** [src/IptvHub.Web/vite.config.ts](src/IptvHub.Web/vite.config.ts)
- **Evidence:**
  ```ts
  urlPattern: ({ url }) => url.pathname.startsWith('/api/'),
  handler: 'NetworkFirst',
  options: {
    cacheName: 'api-runtime-cache',
    networkTimeoutSeconds: 3,
  ```
- **Why this matters:** Workbox's `NetworkFirst` handler caches responses regardless of HTTP status code by default. A 502 or 500 response from the EPG download or server start endpoint can be cached and then served to subsequent requests, causing persistent errors that persist even after the backend is fixed.
- **Recommendation:** Add a `cacheableResponse` plugin to the workbox config to only cache 200 responses:
  ```ts
  plugins: [{ CacheableResponsePlugin: { statuses: [200] } }]
  ```

---

### 21. Low: `Dashboard.tsx` runs 10+ concurrent polling queries all at the same base interval — causes thundering-herd on page load

- **File:** [src/IptvHub.Web/src/pages/Dashboard.tsx](src/IptvHub.Web/src/pages/Dashboard.tsx)
- **Evidence:** `status`, `servers`, `sources`, `sourceChannelCounts`, `activeStreams`, `deviceSessions`, `mediaActivity`, `mediaCapabilities`, `pwaCacheHealth`, `backendCacheHealth`, and up to N `recordingRules`/`skipMarkers`/`watchHistory` queries all initialize simultaneously on mount.
- **Why this matters:** On first load, all queries fire at the same time with no staggering. With 12+ concurrent queries, this creates a burst of 12+ simultaneous API calls. React Query's default `staleTime: 10_000` means they all refetch together every 10 seconds too.
- **Recommendation:** Increase `staleTime` for lower-urgency data (source counts, media capabilities, cache health) so they don't refetch every 10 seconds. The current code partially addresses this with per-query `staleTime` overrides — verify consistency.

---

## Strengths Observed

- **Good:** `ModalFrame` implements correct focus trap with Escape-key close and focus restoration on unmount.
- **Good:** `useAdaptivePollingInterval` backs off exponentially when the tab is hidden — reduces unnecessary background traffic.
- **Good:** `runWithConcurrency` provides a bounded-concurrency primitive used for bulk channel operations.
- **Good:** Axios cancel token checking (`axios.isCancel(err)`) is consistently applied in offline-fallback handlers.
- **Good:** `RouteErrorBoundary` prevents a single page crash from taking down the whole app.
- **Good:** `ConfirmDialog` with `requireText` is used correctly for the `SchedulesDirect` lineup deletion and server deletion flows.
- **Good:** Log viewer uses `@tanstack/react-virtual` for virtualisation — handles thousands of entries without DOM bloat.
- **Good:** Lazy-loaded routes with `Suspense` reduce initial bundle parse time.
- **Good:** Auth polling respects tab visibility via `visibilitychange` events.
- **Good:** Backup passphrase is validated for minimum length before sending.

---

## Suggested Next Implementation Batch

1. Replace `buildStreamUrl` with a token-based or proxy endpoint — remove credential URLs from the browser entirely (finding #1).
2. Replace all `window.confirm` calls with `ConfirmDialog`, especially factory reset (findings #3, #12).
3. Add `AbortSignal` forwarding to the remaining ~8 API functions that lack it (finding #4).
4. Fix setup-mode password validation to match the error message it shows (finding #5).
5. Add workbox `CacheableResponsePlugin { statuses: [200] }` to prevent caching error responses (finding #20).
6. Snap EPG timeline query keys to 30-minute buckets and add `staleTime` to the programs query (finding #10).
