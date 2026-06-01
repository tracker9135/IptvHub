# IPTV Hub — Release Notes v1.1.1

**Release date:** 2026-05-29

---

## What's New

### HDHomeRun Source Type

IPTV Hub now supports HDHomeRun network tuner devices as a native source type.

- Select **HDHomeRun** when adding or editing a source
- Enter the device base URL (e.g. `http://192.168.1.100`)
- Channels are fetched from the device's `/lineup.json` endpoint
- Channel names are automatically prefixed with the guide number (e.g. `05.1 WEWS-HD`, `10.2 MeTV`) and zero-padded so they sort correctly
- Use the **Test** button in the Sources page to verify connectivity before saving

### SAT>IP Source Type

SAT>IP network tuner devices (Octopus Net, HDHomeRun ATSC3, Telestar, etc.) are now supported as a native source type.

- Select **SAT>IP** when adding or editing a source
- Enter the device base URL (e.g. `http://192.168.1.101`)
- IPTV Hub attempts to auto-detect the channel list by probing well-known paths (`/channellist.m3u`, `/playlist.m3u`, `/channels.m3u`, etc.), or you can specify a custom **Channel List Path**
- Device description is read from `/desc.xml` (UPnP) — the friendly name and SAT>IP capabilities are shown in the test result
- RTSP stream URLs are automatically rewritten to HTTP for compatibility

---

## Bug Fixes

### EPG Programs Cleared on Every Server Refresh

**Problem:** When all EPG feeds had a `MinDownloadIntervalMinutes` cooldown active, the scheduled refresh loop skipped every feed but still called `ReplaceAllEpgPrograms([])`, wiping all previously-downloaded programme data. The EPG guide showed 0 programmes after every automatic refresh cycle.

**Fix:** The EPG replace operation is now conditional. If all configured feeds were throttled (none actually fetched this cycle), the existing programme data in the database is preserved. A log entry notes that feeds were throttled and data was retained.

### Manual EPG Feed Download Blocked by Min Interval

**Problem:** Clicking the **Download** button on an EPG feed in the Server card was rejected with a "Minimum download interval not reached" error if the feed had been downloaded within its cooldown window.

**Fix:** The minimum interval throttle now applies only to automatic scheduled refreshes. Manual downloads via the UI always proceed immediately (a concurrent-transfer guard is still enforced to prevent duplicate simultaneous downloads).

### EPG Timeline Empty on Page Load

**Problem:** When the EPG page was opened while the server's startup refresh was still in progress, the channel list and programme grid loaded empty results and cached them. The guide would remain blank until the cache expired (30 seconds for channels, 5 minutes for programmes), even after data became available.

**Fix:**
- The channels query now polls every 10 seconds until at least one channel appears, then stops polling
- The programmes query polls every 15 seconds until data appears, then stops
- When the server's `programCount` transitions from 0 → any positive value, the cached empty programme results are immediately invalidated and re-fetched

---

## Improvements

### Channel Number Prefix on HDHomeRun Channels

HDHomeRun channel names are now prefixed with their OTA guide number (e.g. `05.1 WEWS-HD`). The major channel number is zero-padded to two digits so that channels sort correctly in alphabetical/lexicographic order across the channel list and EPG guide.

