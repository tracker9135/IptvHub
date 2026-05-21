# IPTV Hub — Release Notes v1.0.1

**Release date:** 2026-05-20

---

## What's New

### EPG Manager page

A dedicated **EPG** page has been added to the management UI (sidebar → EPG). It provides:

- **Ad-hoc feed tester** — paste any XMLTV URL (including `.gz` compressed feeds) to verify connectivity and preview channel and programme counts before associating the feed with a server.
- **Free EPG source picker** — a searchable browser of 70+ curated free XMLTV feeds from [epgshare01.online](https://epgshare01.online) and [mjh.nz](https://mjh.nz), grouped by region. Click a source to fill the tester URL automatically.
- **Per-server EPG configuration** — view the programme count for each running server, manage additional XMLTV feed URLs, and configure `tvg-id` channel ID remapping for providers whose IDs don't match the EPG source.

### Aggregated XMLTV endpoint

A new management API endpoint aggregates EPG data from all running IPTV Hub servers into a single XMLTV feed:

```
GET http://localhost:5000/api/epg/xmltv
GET http://localhost:5000/api/epg/xmltv?gz=true   (gzip-compressed)
```

Channels are de-duplicated by `tvg-id` across servers. This URL can be used directly in external media servers (Plex DVR, Emby, Jellyfin, Kodi) as a unified EPG source.

### Free M3U source browser

When adding or editing a **M3U Playlist** or **M3U Collection** source, a **Browse free sources** button (globe icon) is now available next to the URL field. It opens a searchable browser of 110+ free public playlists from [iptv-org/iptv](https://github.com/iptv-org/iptv), grouped by world region.

- **M3U Playlist:** selecting a country fills the URL field automatically.
- **M3U Collection:** the picker operates in multi-select mode — click entries to add or remove them from the URL list.

---

## Bug Fixes

None in this release.

---

## Upgrade Notes

This is a drop-in upgrade. No database migrations or configuration changes are required.

1. Stop the IPTV Hub service.
2. Replace `IptvHub.Service.exe` and accompanying files, or run the updated installer (`IptvHubSetup-1.0.1.exe`).
3. Start the service. The new EPG page and endpoints are immediately available.

---

## Version Reference

| Component | Version |
|---|---|
| IPTV Hub Service (.NET 8) | 1.0.1 |
| Management UI (React) | 1.0.1 |
| Installer | IptvHubSetup-1.0.1.exe |
