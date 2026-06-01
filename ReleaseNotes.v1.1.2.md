# IPTV Hub — Release Notes v1.1.2

**Release date:** 2026-06-01

---

## What's New

### Configurable EPG Cache TTL (per server)

The XMLTV EPG response is now cached with a configurable time-to-live instead of a hard-coded interval.

A new **EPG cache (minutes)** field is available in the server edit dialog. The value controls how long the in-memory XMLTV payload is reused before being rebuilt from the database on the next request.

| Value | Behaviour |
|---|---|
| `0` | Cache disabled — every EPG request rebuilds the XML from the database |
| `1`–`N` | Cache held for that many minutes (default **5**) |

A cache hit also returns an `ETag` header so clients that support conditional HTTP (`If-None-Match`) receive a `304 Not Modified` instead of retransmitting the full XML. The `Last-Modified` header is set to the timestamp of the cached build.

### Channel-Scoped EPG Merge

Previously, ingesting a new EPG feed replaced the entire programme table for the server. Any programme data from a different feed that had not been re-downloaded in the same refresh cycle was silently discarded.

EPG programmes are now merged on a **per-channel** basis:

- When a feed download completes, only the channels present in that batch are updated in the database.
- Programmes for all other channels — whether sourced from embedded M3U EPG, Schedules Direct, or a separate XMLTV feed — are left untouched.
- Within the affected channels, incoming entries are deduplicated against existing ones by `(channelId, startUtc)` before writing.
- Stale entries older than 2 hours at the time of the merge are pruned for the updated channels only.

This eliminates the EPG data loss that occurred when two feeds with disjoint channel sets were refreshed at different intervals.

### Schedules Direct Callsign Alias Elimination

When Schedules Direct (SD) EPG programmes are ingested, they are now stored **only** under the numeric station ID (e.g. `10212`) rather than being duplicated under the channel's callsign (e.g. `KABC`). Storing programmes under both identifiers caused doubled entries in the EPG for affected channels.

At query time, a callsign → station ID lookup is built from the SD station metadata already present in the management database. Channels whose `tvg-id` attribute is a callsign are transparently resolved to the correct station ID when the XMLTV feed is generated and when the Xtream API `get_short_epg` / `get_simple_data_table` actions are served. The correct local `tvg-id` is still emitted in the output so player EPG matching continues to work without any changes on the client side.

---

## Bug Fixes

### EPG Programmes from Second Feed Wiped by First Feed Refresh

**Problem:** When a server had two XMLTV EPG feeds assigned, a scheduled refresh that downloaded only one feed (because the other was still within its minimum-interval cooldown) would overwrite the entire programme table with only the newly-downloaded data, discarding all programmes from the feed that was throttled.

**Fix:** Covered by the channel-scoped merge change above. Each feed now merges only its own channels; programmes from feeds that were not downloaded in a given cycle are preserved.

### SD Channels Showing Duplicate EPG Entries

**Problem:** For channels matched via Schedules Direct, each programme was written to the database twice — once keyed by the numeric station ID and once keyed by the callsign alias. The XMLTV output and Xtream short-EPG responses then contained duplicate `<programme>` blocks for every SD-sourced channel.

**Fix:** Covered by the SD callsign alias elimination change above. Ingestion now writes a single record per programme; the callsign resolution happens at read time.

### EPG Cache Not Invalidated After Server Refresh

**Problem:** After a manual or scheduled source refresh completed and new EPG data was written to the database, the in-memory XMLTV cache continued serving the stale pre-refresh XML until the cache TTL expired naturally. Players would see outdated programme data for several minutes after a refresh.

**Fix:** The EPG response cache is explicitly invalidated at the end of each successful server refresh, ensuring the next request rebuilds the XML from the newly-written data.
