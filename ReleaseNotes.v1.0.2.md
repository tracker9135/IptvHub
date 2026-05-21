# IPTV Hub — Release Notes v1.0.2

**Release date:** 2026-05-21

---

## What's New

### Configuration Backup and Restore

A new **Settings** page has been added to the management UI (sidebar → Settings). It provides a one-click export/import of the entire IPTV Hub configuration:

- **Export** — downloads a portable `iptvhub-backup-<timestamp>.json` file containing all server configurations, source definitions, and channel overrides. Use this to back up your setup before upgrades or to migrate between machines.
- **Restore** — upload a previously exported JSON file to completely replace the current configuration. A confirmation prompt is shown before the overwrite is applied. Running servers are not automatically restarted; restart the service or click **Start** on each server to pick up the restored configuration.

The backup/restore API is also accessible directly:

```
GET  http://localhost:5000/api/backup          → downloads JSON archive
POST http://localhost:5000/api/backup/restore  → restores from JSON body
```

### Push Notifications (SSE toasts + webhooks)

IPTV Hub can now alert you when something goes wrong, without you needing to check the dashboard.

**In-browser toast notifications:**

The management UI subscribes to a Server-Sent Events (SSE) stream at `GET /api/events`. Toast messages appear automatically in the browser when:
- A server refresh completes or fails
- A channel scan finishes with degraded results

Toasts fade out after 5 seconds but can be dismissed manually.

**Webhook notifications (per server):**

Each server can optionally send an HTTP POST to an external URL when notable events occur. Configure in the **Servers** edit dialog:

| Field | Description |
|---|---|
| **Webhook URL** | URL to receive POST notifications (must be `http://` or `https://`) |
| **Notify on refresh failure** | Send a webhook when a scheduled provider refresh fails |
| **Notify on scan degrade threshold** | Send a webhook when a scan pass reports this many or more dead channels (0 = disabled) |

The webhook payload is a JSON object:

```json
{
  "event": "refresh_failed" | "scan_degraded",
  "serverId": "...",
  "serverName": "...",
  "detail": "...",
  "timestamp": "2026-05-21T12:00:00Z"
}
```

### Server-side Catchup Buffer

When **Stream Proxy** is enabled on a server, you can now also enable a **Catchup Buffer** to support time-shift playback without any upstream provider support.

| Setting | Description |
|---|---|
| **Enable Catchup Buffer** | Toggles the ring-buffer recording for all live channels on this server |
| **Buffer duration (minutes)** | How many minutes of history to retain (default 60) |

When active, each live channel is recorded to a local HLS ring buffer using **ffmpeg** (must be on the system `PATH`). Players can then use the standard `/timeshift/` endpoint to seek backward in time within the retained window.

> **Requirements:** `EnableStreamProxy` must be enabled on the server. `ffmpeg` must be installed and available on `PATH`.

> **Note:** The catchup buffer consumes significant disk space and CPU. Size accordingly — roughly 500 MB per channel per hour at typical IPTV bitrates.

### Channel count badges in Sources list

Each source card on the **Sources** page now displays a badge showing the number of live channels currently loaded from that source across all running servers. The count refreshes automatically every 30 seconds.

---

## Bug Fixes

### Channel counts incorrect for Enigma2 and other non-M3U sources

The channel count badge introduced for the Sources list was reporting zero for Enigma2, Xtream Codes, and other non-M3U sources when channels had been loaded by an earlier build. The root cause was that channels loaded before the `SourceId` field was introduced stored only a positional `SourceKey` (e.g. `s0`, `s1`). The endpoint now falls back to a key-based lookup that reconstructs the source mapping from the server's source enumeration order, so counts are reported correctly for all source types.

---

## Upgrade Notes

This is a drop-in upgrade. No database migrations or configuration changes are required.

1. Stop the IPTV Hub service.
2. Replace `IptvHub.Service.exe` and accompanying files, or run the updated installer (`IptvHubSetup-1.0.2.exe`).
3. Start the service. The new Settings page, notifications, and channel count badges are immediately available.

To use the **Catchup Buffer**, enable **Stream Proxy** on the server first, then enable **Catchup Buffer** in the same server edit dialog. Ensure `ffmpeg` is installed (`winget install ffmpeg` or download from [ffmpeg.org](https://ffmpeg.org/download.html)).

---

## Version Reference

| Component | Version |
|---|---|
| IPTV Hub Service (.NET 8) | 1.0.2 |
| Management UI (React) | 1.0.2 |
| Installer | IptvHubSetup-1.0.2.exe |
