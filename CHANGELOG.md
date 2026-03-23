# Changelog

All notable changes to this project are documented here.

## 2026-03-23

### Fixed
- **False data error detection** - Regex `rip(ping)? error` matched inside cyanrip's `Ripping errors: 0` summary line, causing every rip to falsely flag the last track as having a data error; fixed with a negative lookahead (PR #106)

## 2026-03-02

### Added
- **Mp3tag fallback prompt** - When all metadata searching fails (MusicBrainz, CDDB, search-metadata.ps1), prompts to open Mp3tag desktop app pointed at the album folder for manual tagging; auto-detects Mp3tag install location, 30s auto-Yes timeout (PR #91)
- **UTF-8 encoding for rip-audio.ps1** - Added `[Console]::OutputEncoding = UTF8` to fix garbled characters in cyanrip output (PR #88)

### Fixed
- **Disc metadata parsed from cyanrip output** - `Get-DiscMetadata` now extracts Album, Artist, Disc number, Total discs, and Release ID directly from cyanrip's `-I` output instead of making a separate MusicBrainz API call; eliminates redundant network request and avoids API parameter errors (PR #88)
- **Disc ID regex false match** - Regex now requires colon after `DiscID` to avoid matching "DiscID has a matching stub" (which captured "has" as the disc ID); added URL `&id=` parameter fallback for stub cases (PR #88)
- **MusicBrainz stub disc handling** - Discs with incomplete MusicBrainz stubs now correctly fall through to CDDB fallback and generic names with `-N` flag, instead of failing with exit code 1 (PRs #89, #90)
- **MusicBrainz discid API URL** - Removed invalid `releases` and `media` inc parameters from the discid endpoint (releases are returned by default); fixes API errors on discs not parsed from cyanrip output (PRs #88, #90)

## 2026-02-24

### Added
- **Artist mismatch detection** - Compares folder artist vs search result artist after metadata search; auto-skips in batch mode (`-Recurse`), prompts `[y/N]` in interactive mode (PR #79)
- **Undo metadata** - New `undo-metadata.ps1` script reverses tag changes, file renames, and cover art downloads using structured `UNDO_*` entries from `search-metadata.ps1` log files; supports `-DryRun` (PR #80)
- **Structured undo logging** - `search-metadata.ps1` now logs `UNDO_BASELINE`, `UNDO_RENAME`, and `UNDO_COVER_ART` entries before destructive operations (PR #80)

### Fixed
- **Coffee badge border** - Widened box from 53 to 60 chars, fixed URL row that was 52 chars (misaligned border), changed text to "Consider buying me a coffee!" (PR #78)

## 2026-02-23

### Added
- **Buy me a coffee badge** - ASCII art coffee cup with clickable URL in success summaries, drawn via `[char]` casts to stay ASCII-safe for PS 5.1 (PRs #70, #75, #76, #77)
- **Cover art embedding** in `rip-audio.ps1` - Embeds downloaded art into FLAC files via `metaflac --import-picture-from` (PR #68)
- **Drive auto-detection** - `-Drive` and `-OutputDrive` default to auto-detect via `Get-CimInstance Win32_CDROMDrive` (PR #68)

### Fixed
- **Multi-disc detection** - Added `+discids` to MusicBrainz URLs so disc number is populated (PR #68)
- **UTF-8 encoding** - Set `[Console]::OutputEncoding` to UTF8 for metaflac output in `search-metadata.ps1` and `audit-metadata.ps1` (PR #69)
- **PS 5.1 parse errors** - Replaced em dashes in string literals with ASCII-safe alternatives (PR #73)
- **metaflac PATH refresh** - `Assert-MetaflacInstalled` now refreshes PATH from registry before checking (PR #74)
- **Generic album tags** - Falls back to folder name when ALBUM tag is "Unknown disc..." or "Track N" (PR #71)

## 2026-02-22

### Added
- **Auto-discover disc metadata** - `-album` now optional; queries disc via `cyanrip -I`, looks up MusicBrainz for artist/album/disc position (PR #56)
- **Real-time cyanrip output** - Streams stdout/stderr to console during rip via `StreamReader` background threads (PR #56)
- **Resume interrupted rips** - Detects completed tracks, offers Resume/Re-rip/Abort menu (PR #54)
- **Embed-only mode** - `-EmbedOnly` flag for 2-step workflow (scan + cover art) without metadata search (PR #45)
- **Embed cover art into FLAC** - Step 5 of `search-metadata.ps1` now embeds art into FLAC metadata (PR #44)
- **Combined audit + fix pipeline** - `audit-metadata.ps1` runs 4-step pipeline with continue/exit prompts (PR #41)
- **Audit metadata script** - `audit-metadata.ps1` scans for missing tags and cover art, copies to staging (PR #38)
- **Rename confirmation timeout** - Auto-proceeds after 30 seconds with no input (PR #39)
- **Prefix album matching** - Leading-word prefix match for EmbedOnly batch mode, with user prompt on partial matches (PRs #59, #60)

### Fixed
- **Path sanitisation** - Strip illegal Windows chars from album/artist directory names (PR #57)
- **Progress spam filter** - Suppress cyanrip `progress - XX.XX%` lines from console (PR #58)

## 2026-02-21

### Added
- **Recurse flag** - `-Recurse` processes all subdirectories containing FLAC files with per-album error handling and batch summary (PR #33)
- **Dry run flag** - `-DryRun` previews all changes without writing to disk (PR #34)
- **AccurateRip verification** - Parses cyanrip AR output with per-track reporting (PR #31)
- **Multiple output formats** - Comma-separated `-format "flac,mp3"` for parallel encoding (PR #30)
- **Quality parameter** - `-Quality` for lossy format bitrate control (PR #29)
- **Queue mode** - `-Queue` and `-ProcessQueue` for batch ripping with file locking (PR #28)
- **CDDB fallback** - Queries gnudb.org when MusicBrainz has no match (PR #28)
- **Path length validation** - Checks against Windows MAX_PATH before rip (PR #27)
- **RequireMusicBrainz** - `-RequireMusicBrainz` stops rip if disc not in MusicBrainz (PR #26)

## 2026-02-18

### Added
- **search-metadata.ps1** - Multi-source metadata search, tag, and rename script (MusicBrainz + iTunes + Deezer) with 6-step workflow (PR #22)
- **Music API cover art** - Replaced book-oriented sources with iTunes and Deezer APIs in `rip-audio.ps1` and `get-metadata.ps1` (PR #20)

## 2026-02-01

### Added
- **Initial release** - `rip-audio.ps1` with cyanrip integration, 4-step workflow, MusicBrainz lookup, session logging, drive readiness checks, console close protection
- **get-metadata.ps1** - MusicBrainz metadata lookup and CUE file generation
