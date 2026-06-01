# Code Citations

## License: MIT
https://github.com/garyan2/epg123/blob/8f7aa5ebab5f0bb03cf915a632e59392953581da/src/epg123/sdJson2mxf/mxf2xmltv.cs

```
Now I have a complete picture. Here's a detailed summary of how epg123 handles season/episode data:

---

## How epg123 Formats Season/Episode "s01e01"

### 1. Data Source — `programEntries.cs` (`DetermineEpisodeInfo`)

Episode data comes from the **Schedules Direct JSON API** (`sdProgram.Metadata`), which returns a list of provider maps. epg123 prefers in this order:
- **TheTVDB / TVmaze** (if `config.TheTvdbNumbers` is enabled)
- **Gracenote** (default fallback)

```csharp
mxfProgram.SeasonNumber = provider.SeasonNumber;
mxfProgram.EpisodeNumber = provider.EpisodeNumber;
```

A fallback "production number" is also extracted from the last 4 digits of the SD program ID:
```csharp
mxfProgram.EpisodeNumber = int.Parse(mxfProgram.ProgramId.Substring(10));
```

---

### 2. Episode Title Prefix — `programEntries.cs` (`CompleteEpisodeTitle`)

This is the key formatting function. It builds the `"s01e02 "` prefix string using a **user-configurable format**:

```csharp
var se = config.AlternateSEFormat ? "S{0}:E{1} " : "s{0:D2}e{1:D2} ";
```

| Config | Example output |
|---|---|
| `AlternateSEFormat = false` (default) | `s01e02 Episode Title` |
| `AlternateSEFormat = true` | `S1:E2 Episode Title` |

If there's a season number, it formats both: `string.Format(se, seasonNumber, episodeNumber)`. If there's only an episode number (no season), it falls back to `#42`. 

This prefix is then applied to three places depending on config flags:
- **`PrefixEpisodeTitle`** → prepended to `mxfProgram.EpisodeTitle` (the `<sub-title>` in XMLTV)
- **`PrefixEpisodeDescription`** → prepended to `Description` and `ShortDescription`
- **`AppendEpisodeDesc`** → appended as `Season 1, Episode 2` to `Description`

---

### 3. XMLTV `episode-num` Output — `mxf2xmltv.cs` (`BuildEpisodeNumbers`)

epg123 writes up to 4 `<episode-num>` elements in the XMLTV output:

```xml
<!-- dd_progid — Schedules Direct program ID -->
<episode-num system="dd_progid">EP123456.0001</episode-num>

<!-- xmltv_ns — 0-indexed S/E (S2E5 → "1.4.0/1") -->
<episode-num system="xmltv_ns">1.4.0/1</episode-num>

<!-- original-air-date — for non-episodes or repeats -->
<episode-num system="original-air-date">2024-03-15 20:00:00</episode-num>

<!-- thetvdb.com — when TVDB numbers are enabled -->
<episode-num system="thetvdb.com">series/12345</episode-num>
```

The `xmltv_ns` format is 0-indexed (XMLTV spec): `SeasonNumber - 1` and `EpisodeNumber - 1`. Parts (`mxfScheduleEntry.Part`) are also encoded in the third segment.

---

### 4. Inline S:E in Description — `mxf2xmltv.cs`

When none of the prefix/append options are enabled, it appends `S2:E5` (always the alternate `S1:E2` style, not `s01e02`) directly to the `descriptionExtended` bracket string like `[NEW] S2:E5`:

```csharp
if (!config.PrefixEpisodeTitle && !config.PrefixEpisodeDescription && !config.AppendEpisodeDesc)
{
    if (mxfProgram.SeasonNumber > 0 && mxfProgram.EpisodeNumber > 0)
        descriptionExtended += $" S{mxfProgram.SeasonNumber}:E{mxfProgram.EpisodeNumber}";
    else if (mxfProgram.EpisodeNumber > 0)
        
```

