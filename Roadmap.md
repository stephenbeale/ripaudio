# RipAudio Project Roadmap

## Completed

- [x] Add `-Drive` and `-OutputDrive` args to configure input/output drives
- [x] Add `-N` flag to cyanrip for discs not in MusicBrainz (PR #3)
- [x] Cover art handling - sequential fallback: Cover Art Archive, MusicBrainz search + CAA, iTunes, Deezer (PR #20)
- [x] Multi-source metadata search - `search-metadata.ps1` scans folder, searches MusicBrainz + iTunes + Deezer, applies tags + cover art + renames
- [x] Optional MusicBrainz requirement - `-RequireMusicBrainz` switch stops the rip if disc not found in MusicBrainz
- [x] Path length validation - checks worst-case output path against Windows MAX_PATH (260 chars) before rip starts, with breakdown and confirmation prompt
- [x] Queue mode - `-Queue` adds albums to `C:\Music\rip-queue.json`, `-ProcessQueue` processes them sequentially with file locking for concurrency
- [x] CDDB fallback - when MusicBrainz has no match, queries gnudb.org (CDDB protocol) for track names via TOC-based disc ID lookup, with text search fallback
- [x] Quality parameter - `-Quality` for lossy format bitrate control (mp3, opus, aac), passed to cyanrip as `-b`
- [x] Multiple output formats - comma-separated `-format "flac,mp3"` for parallel encoding in a single pass

## Planned Features

### ~~Optional MusicBrainz Requirement~~ (Done)
Moved to Completed section.

### ~~Path Length Validation~~ (Done)
Moved to Completed section.

### ~~Quality Parameter~~ (Done)
Moved to Completed section.

### ~~Multiple Output Formats~~ (Done)
Moved to Completed section.

### AccurateRip Verification
Add AccurateRip verification reporting to confirm rip accuracy.

### ~~Queue Mode~~ (Done)
Moved to Completed section.

### ~~CDDB Fallback~~ (Done)
Moved to Completed section.