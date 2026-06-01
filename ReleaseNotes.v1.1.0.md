# IPTV Hub — Release Notes v1.1.0

**Release date:** 2026-05-27

---

## What's New

### Search and Source Expansion

This release expands content discovery and provider compatibility:

- Added management API search endpoint `GET /api/search` and web UI search page (`/search`) with sidebar omnibox integration.
- Added **Jellyfin/Emby** source support (API key validation, library discovery/selection, VOD/series ingest flow aligned with Plex path).

### EPG Timeline and Import Improvements

EPG tooling has been significantly expanded:

- Added timeline APIs:
  - `GET /api/epg/timeline/channels`
  - `GET /api/epg/timeline`
- Added timeline UI with horizontal time axis and viewport-based lazy loading.
- Added EPG import CSV validation endpoint:
  - `POST /api/epg-import/profiles/{id}/mappings/validate`
- Added preview-first CSV validation/import UX with strict duplicate handling and downloadable error CSV.
- Added Schedules Direct lineup discovery:
  - `POST /api/epg/schedules-direct/lineups`
- Added shared lineup picker integration and required EPG feed `type` handling in editors.

### Dashboard and Playback Operations

Operational workflows and observability were expanded across Dashboard and Player:

- Added Dashboard operational management cards and controls for:
  - recording rules (create/list/toggle/trigger/delete)
  - skip markers (create/list/delete, presets, overlap protection)
  - EPG drift overview with filtering/sorting controls
  - device session grouping, filtering, sorting, and collapse behavior
- Added Dashboard QoS profile filtering for server cards.
- Added `/player` sender route and remote playback handoff actions.
- Added Player marker shortcuts (`S` to skip current marker, `N` to jump next marker) and persisted auto-skip option.

### Adaptive Live Transcoding and Catchup Enhancements

Transcoding and media pipeline behavior are now more robust:

- Added ffmpeg-backed adaptive live HLS route wiring.
- Added M3U master playlist emission when transcoding is enabled, plus fallback to standard `/live` paths when ffmpeg capabilities are unavailable.
- Added transcode QoS controls in server configuration (acceleration, segment/playlist sizing, HDR handling, session caps).
- Added global and per-server transcode session caps with explicit 429/503 outcomes under pressure.

### Security and Runtime Hardening

Multiple production hardening changes are included:

- First-run setup can now be completed only from localhost until admin configuration exists.
- Session cookie hardening restored to `SameSite=Strict`.
- `/api/status` unauthenticated access restricted to loopback; remote requests require valid session.
- Added centralized sensitive-value redaction for URL-bearing logs and applied to source ingestion/log pipelines.
- Added provider refresh timeout protection in host lifecycle to prevent indefinite loading states.
- Reduced `ServerManager` lock contention during refresh/startup paths.

### Notifications and Scheduler Signals

Alerting and diagnostics were improved:

- Added scheduler pressure SSE events:
  - `scheduler_pressure`
  - `scheduler_pressure_resolved`
- Added app shell toast/native notification handling for scheduler pressure events.
- Added notification digest correlation IDs and queued/sent/failed lifecycle logging for SMTP observability.

### Packaging, CI, and Test Coverage

Release engineering and quality gates were strengthened:

- Added release workflow for tag-triggered GitHub Releases and image publishing/signing.
- Added runtime variant support (`Dockerfile.media`, `Dockerfile.alpine`) with CI validation paths.
- Added Playwright smoke coverage and CI execution path for smoke tests.
- Added broad frontend component/unit coverage ratchet with explicit CI thresholds, including Dashboard/Jobs/Servers transition coverage.

---

## Bug Fixes

- Fixed stale source lifecycle behavior where removed/disabled sources could leave stale channel catalogs served by servers.
- Fixed EPG import editor selection stability so selected profile state no longer disappears during transient query states.
- Fixed source-count consistency across Dashboard/Servers cards by aligning both pages to shared assigned-source counting logic.
- Improved refresh execution resilience with timeout and error-state propagation to avoid stuck loading indicators.

---

## Upgrade Notes

This is a drop-in upgrade for standard deployments.

1. Stop the IPTV Hub service/container.
2. Replace binaries or install with `IptvHubSetup-1.1.0.exe`.
3. Start IPTV Hub and verify:
   - Management UI: `http://localhost:5000`
   - Streaming server port mappings match your configured server ports (default compose in this repo maps streaming to `8070`).

Notes:

- If your deployment used unauthenticated remote health probing against `/api/status`, update probes to authenticate or run health checks from loopback context.
- If upgrading Docker deployments, ensure your selected runtime Dockerfile variant matches your expected feature set (`Dockerfile.media` includes media tooling dependencies).

---

## Version Reference

| Component | Version |
|---|---|
| IPTV Hub Service (.NET 8) | 1.1.0 |
| Management UI (React) | 1.1.0 |
| Installer | IptvHubSetup-1.1.0.exe |
