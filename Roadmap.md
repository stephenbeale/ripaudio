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
- [x] AccurateRip verification reporting - parses cyanrip AR output (disc status, per-track v1/v2 checksums, confidence levels), displays in banner/summary, logs results
- [x] Recurse flag for search-metadata.ps1 - `-Recurse` processes all subdirectories containing FLAC files, with per-album error handling and batch summary
- [x] Dry run flag for search-metadata.ps1 - `-DryRun` previews all tag, cover art, and rename changes without writing to disk
- [x] Audit metadata script - `audit-metadata.ps1` scans album folders for missing/generic tags and cover art, copies flagged albums to staging directory
- [x] Rename confirmation timeout - search-metadata.ps1 confirmation prompt auto-proceeds after 30 seconds with no input
- [x] Combined audit + fix pipeline - audit-metadata.ps1 now runs a 4-step pipeline (discover, audit, copy, process) with continue/exit prompts between stages
- [x] Embed cover art into FLAC files - search-metadata.ps1 Step 5 now embeds downloaded/existing cover art into FLAC metadata using metaflac --import-picture-from
- [x] Embed-only mode - `-EmbedOnly` flag runs a reduced 2-step workflow (scan + cover art) to embed existing or downloaded artwork without metadata search, tagging, or renaming
- [x] Resume interrupted rips - detects completed tracks via cue file/disc query, validates integrity (metaflac --test / file size), offers 3-option menu (Resume/Re-rip/Abort), passes `-l` to cyanrip for selective track ripping
- [x] Auto-discover disc metadata - `-album` now optional; queries disc ID via `cyanrip -I`, looks up MusicBrainz API for artist/album/disc position, handles multi-disc albums (appends "Disc N"), prompts on failure
- [x] Real-time cyanrip output - streams cyanrip stdout/stderr to console during rip instead of buffering until completion

## Planned

- [ ] Offline/internet-independent operation - if MusicBrainz or internet is unavailable during disc query or cover art download, prompt user to continue without metadata, note the issues in the summary, and complete the rip with generic names rather than aborting