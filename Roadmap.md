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
- [x] Resume interrupted rips - detects completed tracks via cue file/disc query, validates integrity (flac --test / file size), offers 3-option menu (Resume/Re-rip/Abort), passes `-l` to cyanrip for selective track ripping
- [x] Auto-discover disc metadata - `-album` now optional; queries disc ID via `cyanrip -I`, looks up MusicBrainz API for artist/album/disc position, handles multi-disc albums (appends "Disc N"), prompts on failure
- [x] Real-time cyanrip output - streams cyanrip stdout/stderr to console during rip instead of buffering until completion
- [x] Artist mismatch detection - compares folder artist vs search result artist; auto-skips in batch mode, prompts [y/N] in interactive mode
- [x] Undo metadata - `undo-metadata.ps1` reverses tag changes, renames, and cover art downloads using structured UNDO_* log entries from search-metadata.ps1

- [x] Offline/internet-independent operation - tracks metadata source (MusicBrainz/CDDB/Generic) and cover art source in FILE SUMMARY and log; prompts user to continue without metadata when offline; completes rip with generic names rather than aborting

## Backlog / Investigate

- [ ] **MusicBrainz 503 reliability (opened 2026-08-29)** - the pre-rip connectivity check hit `503 Server Unavailable` repeatedly across multiple separate `rip-audio.ps1` runs in one day: a Stereo MC's rip earlier in the session, and a Jon Bon Jovi "Destination Anywhere" rip attempted twice (most recently ~10:04). Every occurrence required a manual retry or continuing without metadata. PR #148 (merged) added client-side backoff (5s/10s/15s) and per-attempt logging to the two pre-flight connectivity-check retry loops, so failures are now visible with attempt numbers - but that's a client-side mitigation only; it cannot fix MusicBrainz itself being down or rate-limited. Still open:
  - [ ] Determine whether the repeated 503s reflect a genuine sustained MusicBrainz outage that day, a rate limit specific to this machine/User-Agent (`RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)`), or something else - not yet diagnosed.
  - [ ] If this keeps recurring across future sessions, consider a more resilient metadata strategy: a longer-lived local cache of previously-successful disc lookups, checking MusicBrainz's own status page before assuming a client-side issue, or defaulting more readily to the existing CDDB fallback instead of making the user wait through the MusicBrainz retry loop each time.
  - [ ] The separate, heavier mid-rip MusicBrainz retry loop (where cyanrip itself reports a connection failure and retry re-invokes cyanrip) was deliberately left untouched by PR #148. If it turns out to hit the same rate-limit/outage pattern in practice, it may need the same backoff treatment.
  - [ ] Recurred again same day (~12:03): a Jon Bon Jovi "Destination Anywhere CD 2" rip still hit `503 Server Unavailable` after PR #148's backoff shipped - confirms this is not a timing-only issue the client side can fix; backoff mitigates hammering, it does not resolve the outage.

- [ ] **`search-metadata.ps1` doesn't understand `-DiscNum`-merged multi-disc folders (opened 2026-08-29)** - `rip-audio.ps1`'s new `-DiscNum` opt-in mode (see CHANGELOG "Opt-In Shared-Folder Multi-Disc Mode") rips a whole multi-disc set into one shared folder with disc-prefixed track filenames (`1.01 - Title.flac`, `2.01 - Title.flac`). `search-metadata.ps1`'s existing multi-disc matching logic (from an earlier session, PR #85) assumes one folder = one disc when comparing local track count against a single MusicBrainz medium - it has not been updated to recognise a merged shared folder, and running it against one today would likely mismatch or fail to match any medium at all (combined track count won't equal any single disc's). Needs: detect the `N.NN - ` filename prefix, split local files by disc number, and match/tag each group against its own medium.