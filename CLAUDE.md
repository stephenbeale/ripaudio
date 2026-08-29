# RipAudio Project

PowerShell script for automated audio CD ripping using cyanrip.

## Git Workflow

When the user says **"make a workflow"**, execute the full git lifecycle. The workflow is **not complete until the PR is approved and merged**:

1. **Branch** - Create a feature branch from master (`feature/<issue-number>-<description>` or `feature/<description>`)
2. **Commit** - Stage and commit all relevant changes with a conventional commit message
3. **Push** - Push the branch to origin (`git push -u origin <branch>`)
4. **PR** - Create a pull request via `gh pr create` with summary and test plan
5. **Approve PR** - Approve via `gh pr review --approve`, then merge via `gh pr merge --squash --delete-branch`
6. **Return to master** - `git checkout master && git pull`

## Project Structure

```
ripaudio/
    rip-audio.ps1        # Main CD ripping script (cyanrip)
    continue-rip-audio.ps1 # Step-based resume for an interrupted rip-audio.ps1 run
    get-metadata.ps1     # MusicBrainz metadata lookup and CUE file generation
    search-metadata.ps1  # Multi-source metadata search, tag, rename (MB + iTunes + Deezer)
    audit-metadata.ps1   # Scan for missing/incomplete metadata, copy flagged albums to staging
    undo-metadata.ps1    # Reverse changes made by search-metadata.ps1 using UNDO_* log entries
    README.md            # User documentation
    CLAUDE.md            # This file - development notes
    Roadmap.md           # Planned features
```

## Script Architecture

The script follows the same patterns as the ripdisc project:

### Step Tracking
- 4-step workflow: cyanrip rip, verify output, cover art, open directory
- Each step tracked with colored console output
- Summary shown on completion or error

### Console Protection
- Close button disabled during rip to prevent accidental closure
- Re-enabled on completion or error

### Error Handling
- Comprehensive error messages for common issues (no disc, wrong disc type, drive not found)
- Manual recovery steps provided on failure
- Log file location shown for debugging

### Logging
- All sessions logged to `C:\Music\logs\`
- Includes timestamps, file operations, and error details

## cyanrip Integration

cyanrip is a command-line audio CD ripper. Key options used:

| Option | Description |
|--------|-------------|
| `-D <dir>` | Output directory |
| `-o <format>` | Output format (flac, mp3, opus, etc.) |
| `-d <drive>` | CD drive device (e.g., E:) |
| `-s <offset>` | Drive read offset (use 0 for most drives) |

MusicBrainz lookup is automatic - cyanrip will query MusicBrainz for disc metadata including track names, artist, and album info.

## Output Directory Structure

```
{OutputDrive}:\Music\{Artist}\{Album}\    # With artist
{OutputDrive}:\Music\{Album}\             # Without artist (compilations)
```

## Supported Formats

- `flac` - Free Lossless Audio Codec (default)
- `mp3` - MPEG Audio Layer III
- `opus` - Opus Interactive Audio Codec
- `aac` - Advanced Audio Coding (.m4a)
- `wav` - Waveform Audio File Format
- `alac` - Apple Lossless Audio Codec (.m4a)

## Session Notes

### 2026-02-01 - Initial Creation

**Work Completed:**

- Created repository structure mirroring ripdisc
- Implemented `rip-audio.ps1` with:
  - Parameter handling (-album, -artist, -Drive, -OutputDrive, -format)
  - 3-step workflow with progress tracking
  - Colored console output
  - Drive readiness checks
  - Session logging to C:\Music\logs\
  - Automatic disc ejection on success
  - Error handling with recovery guidance
  - Console close button protection

**Technical Notes:**
- Uses cyanrip CLI (installed via winget)
- MusicBrainz lookup is automatic via cyanrip
- Format validation ensures only valid formats are accepted
- Directory structure supports both artist/album and album-only layouts

---

### 2026-02-01 - Bug Fixes

**Work Completed:**

- Added cyanrip drive offset parameter `-s 0` to fix ripping issues
- Updated README.md to reflect correct Drive default (E:)
- Updated CLAUDE.md cyanrip options table with offset parameter

**Technical Notes:**
- cyanrip requires a drive offset to be specified for accurate ripping
- The `-s 0` parameter sets the drive read offset to 0 samples

---

## Future Enhancements

Potential improvements to consider:

- [x] Add `-quality` parameter for lossy format bitrate control
- [x] Support multiple output formats in single rip (`-o flac,mp3`)
- [x] Add AccurateRip verification reporting
- [x] Queue mode for batch ripping (similar to ripdisc)
- [x] Cover art handling (sequential fallback: CAA, MusicBrainz+CAA, iTunes, Deezer)
- [x] CDDB fallback when MusicBrainz has no match

---

### 2026-02-18 - Replace Cover Art Sources with Music APIs

**Work Completed:**

- PR #20 merged: Replaced book-oriented cover art sources (Open Library, Google Books) with proper music album art APIs in both `rip-audio.ps1` and `get-metadata.ps1`
  - New sequential fallback chain:
    1. Cover Art Archive direct lookup (using release ID from cue file)
    2. MusicBrainz search + CAA (search by artist+album, then fetch from CAA)
    3. iTunes Search API (free, no auth required, 600x600 artwork)
    4. Deezer API (free, no auth required, up to 1000x1000 artwork)
- PR #21 merged: Updated Roadmap.md and CLAUDE.md to mark cover art handling as completed

**Testing:**
- Tested against "Seasick Steve - You Can't Teach an Old Dog New Tricks": iTunes and Deezer returned results (CAA had no art for that release)
- Tested against "Howard Shore - The Lord of the Rings: The Two Towers": all 3 sources (CAA, iTunes, Deezer) returned artwork
- Verified actual image download works (117.9 KB JPG from iTunes)

**Next Steps:**
- No immediate action required — all cover art sources are working
- Consider adding `-quality` parameter for lossy format bitrate control (see Future Enhancements)
- CDDB fallback remains a potential future improvement for releases not in MusicBrainz

---

### 2026-02-18 - New search-metadata.ps1 Script

**Work Completed:**

- Created `search-metadata.ps1` - standalone multi-source metadata search, tag, and rename tool
  - 6-step workflow: scan files, search metadata, confirm changes, apply tags, cover art, rename files
  - Searches 3 sources: MusicBrainz, iTunes, Deezer
  - Merges results with priority: MB > Deezer > iTunes for artist/album/date/tracks, Deezer > iTunes for genre, Deezer > iTunes > CAA for artwork
  - Colored side-by-side comparison table (current vs proposed) with rename preview
  - Uses targeted `--remove-tag` instead of `--remove-all-tags` to preserve existing metadata
  - Track count matching to pick best edition from search results
  - Artist/album auto-detection from existing tags or folder structure
  - Follows existing patterns: step tracking, Write-Log, Stop-WithError, colored output, logging to C:\Music\logs\

**Key Design Decisions:**
- Standalone script (not modifying get-metadata.ps1) to keep concerns separate
- `Read-ExistingTags` reads via metaflac per-field rather than --export-tags-to for simpler parsing
- `Search-AllSources` fetches full release details from MB (inc=recordings+artist-credits+release-groups)
- Rename format is `## - Title.ext` (simple, no artist/album in filename since folder provides context)
- Confirmation prompt shown by default, skippable with `-Force`

**Next Steps:**
- No immediate action required — script is functional and merged
- Potential enhancements: add `-Recurse` flag to process subdirectories, add `-DryRun` mode
- Consider adding MusicBrainz release disambiguation (currently picks best edition by track count match)

---

### 2026-02-18 - Session Closure

**Session Verified Clean:**
- PR #22 squash-merged to master (feat(metadata): add search-metadata.ps1)
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master)
- No open PRs

**Stale Remote Branches (no unique commits, safe to delete if desired):**
- `origin/bugfix/fix-cyanrip-path-conversion`
- `origin/docs/musicbrainz-release-selection`
- `origin/feature/3-musicbrainz-not-found-fallback`
- `origin/feature/musicbrainz-not-found-fallback`

These branches have no commits ahead of master and were pruned from local tracking refs. They can be deleted on GitHub via the branch manager if desired.

**Priority for Next Session:**
1. Test `search-metadata.ps1` against real FLAC files in a local music library to validate the 6-step workflow end-to-end
2. Consider adding `-Recurse` flag to process nested album subdirectories
3. Review stale remote branches for cleanup on GitHub

---

### 2026-02-21 - Queue Mode + CDDB Fallback

**Work Completed:**

- Added Queue Mode (`-Queue` and `-ProcessQueue` switches):
  - `-Queue` adds album entries to `C:\Music\rip-queue.json` with file locking (same pattern as ripdisc) for concurrent safety
  - `-ProcessQueue` reads queue, prompts for disc insertion per entry, runs full 4-step workflow, removes completed entries, shows aggregate summary
  - Queue entries store Album, Artist, Format, QueuedAt timestamp
  - ProcessQueue auto-continues through interactive prompts (MB unreachable, directory exists, path length, multiple releases)
  - Re-reads queue between entries to pick up concurrently added items
  - Mutually exclusive params validated at startup

- Added CDDB Fallback when MusicBrainz has no match:
  - `Search-CDDB` function: parses TOC from cyanrip output, computes CDDB disc ID (standard algorithm), queries gnudb.org via HTTP CDDB protocol
  - Two lookup strategies: TOC-based disc ID query (primary), text search by album name (fallback)
  - CDDB track names used for file renaming (`## - Track Title.ext`) and FLAC metadata tagging
  - Inserted between MB failure detection and generic names fallback
  - Shows CDDB results preview (artist, album, first 5 tracks) before proceeding

**Technical Notes:**
- CDDB disc ID computed from LBA offsets + 150-frame lead-in, using standard digit-sum algorithm
- gnudb.org HTTP API: `cddb query` for disc lookup, `cddb read` for full track listing, `cddb album` for text search
- DTITLE and TTITLE fields parsed with multi-line continuation support
- ProcessQueue uses try/catch around main body; Stop-WithError throws instead of exit in queue mode
- Queue file deleted automatically when empty after ProcessQueue completes

---

### 2026-02-21 - AccurateRip Verification Reporting

**Work Completed:**

- Added `Parse-AccurateRipResults` function to parse cyanrip's AccurateRip output:
  - Disc-level status: found, not found, error, mismatch, disabled
  - Finish report: tracks ripped accurately N/M, partially accurately N/M
  - Per-track details: v1/v2 checksums, confidence levels, accurate/not found status
- AccurateRip results displayed after rip completes (green if all verified, yellow if partial)
- AccurateRip status included in FILE SUMMARY block at session end
- AccurateRip results logged to session log file
- Window title appended with "AR PARTIAL" if not all tracks verified
- No new parameters needed - cyanrip enables AR by default

**Technical Notes:**
- cyanrip outputs AR data at three levels: disc-level status line, per-track Accurip v1/v2 lines, and finish report summary
- Parser handles all three levels independently (any subset may be present)
- TrackDetails array captures per-track v1/v2 checksums for potential future detailed reporting
- Roadmap.md updated to mark AccurateRip as completed

---

### 2026-02-21 - Session Closure

**PRs Merged This Session:**
- PR #22 - Created `search-metadata.ps1` (multi-source metadata search, tag, rename: MusicBrainz + iTunes + Deezer)
- PR #25 - Fixed generic track rename fallback (triggers when filenames are generic regardless of `-skipMusicBrainz`)
- PR #26 - Added `-RequireMusicBrainz` switch (stops rip if disc not found in MusicBrainz)
- PR #27 - Added path length validation (checks worst-case output path against Windows MAX_PATH 260 chars)
- PR #29 - Added `-Quality` parameter for lossy format bitrate control (32-320 kbps, passed to cyanrip as `-b`)
- PR #30 - Added multiple output format support (comma-separated `-format "flac,mp3"` for parallel encoding)
- PR #31 - Added AccurateRip verification reporting (`Parse-AccurateRipResults`, coloured summary, log output, window title suffix)

**Session Verified Clean:**
- All PRs squash-merged to master
- Stash list cleared (2 stashes dropped: AccurateRip WIP now committed, older path-length stash superseded)
- All stale local branches deleted: bugfix/fix-cyanrip-path-conversion, docs/musicbrainz-release-selection, feature/3-musicbrainz-not-found-fallback, feature/musicbrainz-not-found-fallback
- Remote tracking refs pruned (9 deleted remote branches cleaned up)
- Working tree: clean
- No unpushed commits
- No open PRs

**Roadmap Status:**
- All planned features are now complete. Roadmap.md contains only the Completed section.
- The "Future Enhancements" section in CLAUDE.md now shows all items checked off.

**Priority for Next Session:**
1. The roadmap is complete — no outstanding development items
2. Consider end-to-end testing of the full rip workflow with a real disc (AccurateRip parsing needs live cyanrip output to validate regex patterns)
3. Consider adding `-Recurse` flag to `search-metadata.ps1` for processing nested subdirectories
4. Stale remote branches on GitHub (noted in 2026-02-18 closure) may still need manual cleanup via the GitHub branch manager if not already done

---

### 2026-02-21 - search-metadata.ps1 -Recurse Flag

**Work Completed:**

- PR #33 merged: Added `-Recurse` switch to `search-metadata.ps1`
  - Refactored per-album processing logic (steps 1-6) into a `Process-AlbumFolder` function with an accompanying `Reset-StepTracking` helper to reset step state between albums
  - In recurse mode, the script discovers all subdirectories under the target path that contain at least one FLAC file, then processes each as an independent album
  - Per-album error handling: failures in one album are caught and logged, processing continues to the next (no single failure aborts the batch)
  - Confirmation prompt auto-forced in recurse mode (equivalent to `-Force`) to avoid interactive prompts stalling a batch run
  - Window title updated with progress indicator (`[N/M] Album - Artist`) during batch processing
  - Batch summary shown on completion: total albums processed, count of successes and failures, list of any failed folders
  - README.md updated with `-Recurse` parameter documentation and usage examples
  - Roadmap.md updated to mark `-Recurse` as completed (all roadmap items now complete)

**Technical Notes:**
- `Reset-StepTracking` clears the module-level `$script:Steps` array and `$script:CurrentStep` counter so each album starts with a fresh step display
- `Process-AlbumFolder` wraps the existing 6-step workflow; the top-level script body calls it once (single mode) or iterates subdirectories (recurse mode)
- Subdirectory discovery uses `Get-ChildItem -Recurse -Directory` filtered to those containing `*.flac` files
- The target folder itself is excluded from recurse discovery (it is not treated as a sub-album)

**Session Verified Clean:**
- PR #33 squash-merged to master
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master)
- No open PRs

**Priority for Next Session:**
1. All roadmap items are complete — no pending development work remains
2. Consider end-to-end testing of `search-metadata.ps1 -Recurse` against a real music library directory tree to validate batch processing, error recovery, and window title progress
3. Consider end-to-end testing of `rip-audio.ps1` with a real disc to validate AccurateRip regex parsing against live cyanrip output
4. Stale remote branches on GitHub (noted in 2026-02-18 closure) may still need manual cleanup via the GitHub branch manager if not already done

---

### 2026-02-21 - Stale Branch Cleanup

**Work Completed:**

- Deleted 4 stale remote branches from GitHub that had been noted since the 2026-02-18 session closure:
  - `origin/bugfix/fix-cyanrip-path-conversion`
  - `origin/docs/musicbrainz-release-selection`
  - `origin/feature/3-musicbrainz-not-found-fallback`
  - `origin/feature/musicbrainz-not-found-fallback`
- Pruned 2 additional stale remote tracking refs that had no corresponding GitHub branches
- Also confirmed that PRs #31 and #32 (AccurateRip verification reporting) were successfully merged to master earlier in this session

**Session Verified Clean:**
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master)
- No open PRs
- Branches: only `master` (local) and `remotes/origin/HEAD -> origin/master`, `remotes/origin/master` (remote)
- Stash list: empty

**Priority for Next Session:**
1. All roadmap items are complete — no pending development work remains
2. Repository is fully clean with no stale branches or open PRs
3. Consider end-to-end testing of `search-metadata.ps1 -Recurse` against a real music library directory tree
4. Consider end-to-end testing of `rip-audio.ps1` with a real disc to validate AccurateRip regex parsing against live cyanrip output

---

### 2026-02-21 - search-metadata.ps1 -DryRun Flag

**Work Completed:**

- PR #34 merged: Added `-DryRun` switch to `search-metadata.ps1`
  - New `[switch]$DryRun` parameter in script param block, passed as `-DryRunMode` to `Process-AlbumFolder`
  - Steps 1 (scan) and 2 (search) run identically — they're read-only operations
  - Step 3 (confirm): Shows `[DRY RUN] No changes will be made.` banner, skips confirmation prompt entirely
  - Step 4 (apply tags): Shows `[DRY RUN] Would tag N file(s)` instead of calling `Set-AudioTags`; still counts files for summary
  - Step 5 (cover art): Shows what would happen (`Would download cover art from <source>` or `Cover art already exists`) without calling `Get-CoverArt`
  - Step 6 (rename): Shows each proposed rename (`current -> new`) without calling `Rename-Item`; counts files that would change
  - Summary banners prefixed with `[DRY RUN]` in both single and recurse modes
  - `DryRun` logged at session start alongside other parameters
  - README.md updated with `-DryRun` in parameter table, usage line, and two examples
  - Roadmap.md updated to mark dry run flag as completed

**Technical Notes:**
- No new functions needed — just conditional guards around existing write operations (`Set-AudioTags`, `Get-CoverArt`, `Rename-Item`)
- `Show-MetadataComparison` still displays the full comparison table in dry run mode (that's the preview)
- In recurse mode, `-DryRunMode:$DryRun` is passed through alongside `-ForceMode:$true` and `-BatchMode`
- Dry run step 6 replicates the rename logic from `Rename-AudioFiles` inline to show proposed renames without calling the function

**Session Verified Clean:**
- PR #34 squash-merged to master
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master)
- No open PRs

**Priority for Next Session:**
1. All roadmap items are complete — no pending development work remains
2. Consider end-to-end testing of `search-metadata.ps1 -DryRun` against a real music library to verify no files are modified
3. Consider end-to-end testing of `search-metadata.ps1 -Recurse -DryRun` to validate batch dry run output
4. Consider end-to-end testing of `rip-audio.ps1` with a real disc to validate AccurateRip regex parsing against live cyanrip output

---

### 2026-02-22 - audit-metadata.ps1 + Rename Confirmation Timeout

**Work Completed:**

- PR #38 merged: Created `audit-metadata.ps1` — standalone script to scan album folders for incomplete metadata
  - 3-step workflow: discover album folders, audit each folder, copy flagged albums (or report)
  - Check 1: Track titles — flags albums with `Unknown track`, `Track N`, or empty titles
  - Check 2: Album-level tags — flags if Artist, Album, Date, or Genre are missing across all tracks
  - Check 3: Cover art — flags if no `Front.*`, `Cover.*`, or `Folder.*` image exists
  - Parameters: `-Path` (root music folder), `-OutputPath` (staging dir, default `C:\Music\needs-update`), `-ReportOnly` (CSV report without copying)
  - Copies flagged albums to staging directory preserving `Artist\Album` folder structure
  - Skips `logs` and `needs-update` directories during discovery
  - `-ReportOnly` writes CSV to `C:\Music\logs\audit-metadata_{timestamp}.csv`
  - Reuses `Write-Log`, `Stop-WithError`, `Read-ExistingTags` functions (copied from search-metadata.ps1)
  - Coloured output: `[OK]` green, `[!!]` yellow for flagged, `[>>]` cyan for copied, `[--]` gray for already-staged
  - README.md updated with audit-metadata section (params, checks, examples)
  - Roadmap.md updated to mark audit metadata as completed

- PR #39 merged: Added 30-second auto-proceed timeout to `search-metadata.ps1` confirmation prompt
  - Replaced `Read-Host "Apply these changes? [Y/n]"` with `[Console]::KeyAvailable` polling loop
  - Polls every 200ms for 30 seconds; shows `(auto-Yes in 30s)` hint
  - If no key pressed within 30s, prints `Y (auto)` and proceeds
  - If user presses N, cancels as before
  - Any other key (or timeout) proceeds with changes
  - Existing behaviour preserved: `-Force` skips prompt entirely, `-DryRun` shows banner
  - Roadmap.md updated to mark rename confirmation timeout as completed

**Technical Notes:**
- `audit-metadata.ps1` uses the same `Read-ExistingTags` function as `search-metadata.ps1` (copied, not shared) — reads ARTIST, ALBUM, TITLE, DATE, GENRE via metaflac per-field
- Cover art check uses `Get-ChildItem -Include "Front.*","Cover.*","Folder.*"` — same pattern as search-metadata.ps1 Step 5
- Staging directory skip uses both `Resolve-Path` (for existing paths) and regex fallback `\\needs-update(\\|$)` (for not-yet-created paths)
- Rename timeout uses `[System.Diagnostics.Stopwatch]` for precise timing, `[Console]::ReadKey($true)` for non-echoing key capture

**Session Verified Clean:**
- PR #38 and #39 squash-merged to master (initially combined as PR #37, then reverted and split into separate PRs per user request)
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master)
- No open PRs

**Priority for Next Session:**
1. Test `audit-metadata.ps1 -ReportOnly` against `C:\Music` to validate discovery and auditing
2. Test `audit-metadata.ps1` (without -ReportOnly) to validate copy-to-staging workflow
3. Test `search-metadata.ps1` single-album mode to validate 30-second auto-proceed timeout
4. Consider end-to-end pipeline: `audit-metadata.ps1 -Path "C:\Music"` then `search-metadata.ps1 -Path "C:\Music\needs-update" -Recurse`

---

### 2026-02-22 - Combined Audit + Fix Pipeline

**Work Completed:**

- PR #41 merged: Extended `audit-metadata.ps1` from a 3-step to a 4-step pipeline
  - Step 1/4: Discover album folders (unchanged)
  - Step 2/4: Audit metadata (unchanged)
  - Step 3/4: Copy flagged albums to staging — now preceded by a continue/exit prompt: `N albums flagged. Copy to staging? [Y/n] (auto-Yes in 30s)`
  - Step 4/4: Search & apply metadata (new) — preceded by prompt: `Search & apply metadata to N flagged albums? [Y/n] (auto-Yes in 30s)`, then invokes `search-metadata.ps1 -Path <staging> -Recurse`
  - Added `Read-TimedConfirmation` helper function — reusable `[Console]::KeyAvailable` + `Stopwatch` polling loop with configurable timeout, returns `$true` to continue or `$false` on N
  - Step 4 runs `search-metadata.ps1` as a subprocess via `Start-Process powershell.exe -NoProfile -ExecutionPolicy Bypass -File` to isolate `exit` calls in the child script
  - Checks `$proc.ExitCode` and reports success/failure in the summary
  - `-ReportOnly` behaviour unchanged — steps 1-2 only, CSV written, no prompts, no copy, no processing
  - Summary updated with metadata processing result line (success or exit code)
  - README.md updated: audit-metadata section now describes the 4-step pipeline with prompt details
  - Roadmap.md updated: added combined audit + fix pipeline as completed item

**Technical Notes:**
- `Read-TimedConfirmation` extracted as a helper (not inline) to avoid repeating the polling loop for both prompts
- `Start-Process` with `-Wait -PassThru -NoNewWindow` keeps console output flowing to the terminal while isolating the subprocess
- `$copyConfirm` and `$processExitCode` variables scoped to the else branch; summary conditionally checks them with `-and $copyConfirm` and `$null -ne $processExitCode`
- When user presses N at the copy prompt, neither copy nor processing occurs; when N at the process prompt, copy completes but processing is skipped

**Session Verified Clean:**
- PR #41 squash-merged to master
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master)
- No open PRs

**Priority for Next Session:**
1. Test full 4-step pipeline: `.\audit-metadata.ps1 -Path "C:\Music"` — let both prompts auto-proceed to validate end-to-end flow
2. Test pressing N at first prompt (should stop after audit results) and N at second prompt (should copy but not process)
3. Test `-ReportOnly` still works as before (no prompts, no copy, no processing)
4. Consider end-to-end testing of `rip-audio.ps1` with a real disc to validate AccurateRip regex parsing against live cyanrip output

---

### 2026-02-22 - Auto-Discover Disc Metadata + Streaming cyanrip Output

**Work Completed:**

- PR #56 merged: `feature/auto-discover-metadata` — auto-discover disc metadata before ripping and stream all cyanrip output in real time
  - New `Get-DiscMetadata` function: runs cyanrip in discovery mode (`-M` flag) before any directory is created, captures stdout/stderr via StreamReader threads, extracts artist, album, release ID, track count, and the `-R <n>` release index flag for multi-release discs
  - `-album` parameter made optional (was previously mandatory) — album name is now populated from MusicBrainz metadata during the discovery phase
  - Directory creation moved after discovery so the output folder name reflects the actual album title from MusicBrainz
  - `-R` flag from discovery automatically passed through to all subsequent cyanrip invocations (single-format, multi-format, resume-mode) so the same release is used throughout
  - All 6 cyanrip invocations (initial rip, resume-mode continuation, plus all format variants of both) converted from `Start-Process -Wait` to real-time streaming via `StreamReader` background threads — live output displayed in the console as cyanrip runs
  - `Get-DiscTrackCount` fixed: now correctly handles multi-release discs by extracting track count from the selected release (the one at index `-R <n>`) rather than always using release index 0
  - README.md updated: `-album` marked as optional, `Get-DiscMetadata` discovery phase documented, `-R` flag passthrough noted, streaming output behaviour noted
  - Roadmap.md updated: auto-discover disc metadata marked as completed

**Technical Notes:**
- Discovery mode uses `cyanrip -M` (metadata-only, no rip) with the drive and offset parameters
- StreamReader threads (`BeginRead`/async pattern not used — two `System.Threading.Thread` objects reading stdout and stderr to thread-safe `System.Collections.Concurrent.ConcurrentQueue[string]`) collect output while the main thread drains and prints the queue
- Artist/album extracted from `Artist: ...` / `Title: ...` lines in cyanrip discovery output; release ID from `Release: ...` line; `-R <n>` from `Selecting release <n>` line
- Track count fix: `Get-DiscTrackCount` now skips forward `$releaseIndex` release blocks (each starting with `Release N:`) before counting tracks in the target block
- If discovery finds no MusicBrainz match, the script falls back to requiring `-album` from the caller (unchanged behaviour)

**PRs Merged This Session:**
- PR #56 - `feat(rip): auto-discover disc metadata + stream cyanrip output`

**Session Verified Clean:**
- Branch `feature/auto-discover-metadata` merged and deleted (local and remote)
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master)
- No open PRs

**Priority for Next Session:**
1. Test full auto-discover workflow with a real disc: run `.\rip-audio.ps1` without `-album` and verify that the folder is created with the MusicBrainz album name, the correct `-R` index is passed through, and track count is accurate
2. Test with a disc that has multiple MusicBrainz releases to validate the `-R` passthrough and track count fix
3. Test resume mode with a real disc to confirm the `-R` flag is preserved in the resumed rip
4. Continue the audit-metadata.ps1 end-to-end pipeline testing noted from the previous session

---

### 2026-02-22 - Windows Path Sanitisation, Progress Spam Filter, and EmbedOnly Prefix Match

**Work Completed:**

- PR #57 merged: `fix(rip): sanitize album/artist for directory names`
  - Album and artist names from MusicBrainz can contain characters illegal in Windows file paths (e.g. `?`, `*`, `:`, `"`, `<`, `>`, `|`, `\`, `/`)
  - Added `Sanitize-PathComponent` function to `rip-audio.ps1` that strips these characters before constructing the output directory path
  - Prevents `New-Item` from failing with an "illegal path character" error when MusicBrainz returns titles containing `?` or similar characters

- PR #58 merged: `fix(rip): filter cyanrip progress spam from console output`
  - cyanrip emits `progress - XX.XX%` lines at high frequency during ripping; these filled the console with noise
  - Added a filter in the StreamReader output loop: lines matching `^progress\s*-\s*[\d.]+%` are suppressed from console display
  - Lines are still captured internally (they are needed to detect rip completion); they are simply not printed to the terminal
  - Ripping progress is no longer drowned out by percentage spam in the streaming output

- PR #59 merged: `fix(metadata): match album by leading-word prefix in EmbedOnly batch mode`
  - `search-metadata.ps1` `-Recurse` (EmbedOnly) batch mode was failing to match albums whose MusicBrainz title differed by a long subtitle suffix
  - Example: local folder `The Best Of-Once in a Lifetime` should match MusicBrainz result `The Best of Talking Heads`
  - Added leading-word prefix matching: if the candidate album title starts with the same two or more words as the local album name (case-insensitive), it is accepted as a prefix match
  - Prefix match threshold is 2 leading words (a single-word prefix is too ambiguous to be reliable)

- PR #60 merged: `fix(metadata): prefix-only matches now always prompt user, even in batch mode`
  - Prefix matches (from PR #59) are inherently less certain than strong substring matches
  - Changed behaviour: prefix-only matches always show a `Partial match:` label and a `[y/N]` prompt requiring explicit user confirmation, even when running with `-Recurse` (which normally auto-proceeds on good matches)
  - Strong substring matches (where the local name is fully contained in the candidate title) continue to auto-proceed in batch mode as before
  - This gives users visibility and control over partial matches without slowing down batch processing for high-confidence matches

**Technical Notes:**
- `Sanitize-PathComponent` uses a simple `-replace` with `[\\/:*?"<>|]` character class; applied to both artist and album before joining the output path
- Progress spam filter uses `$line -match '^progress\s*-\s*[\d.]+%'` check in the queue-drain loop; suppressed lines are not written to the log file either
- Prefix match logic in `search-metadata.ps1`: splits both strings on whitespace, zips leading words, compares case-insensitively; prefix match flag is set separately from the strong-match flag
- Prompt-on-prefix-match guard: `if ($isPrefixMatch -and -not $isStrongMatch)` wraps the auto-proceed path and diverts to the `[y/N]` prompt instead

**PRs Merged This Session:**
- PR #57 - `fix(rip): sanitize album/artist for directory names`
- PR #58 - `fix(rip): filter cyanrip progress spam from console output`
- PR #59 - `fix(metadata): match album by leading-word prefix in EmbedOnly batch mode`
- PR #60 - `fix(metadata): prefix-only matches now always prompt user in batch mode`

**Session Verified Clean:**
- All 4 PRs squash-merged to master
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master)
- No open PRs
- Branches: only `master` local; all feature branches deleted locally and remotely
- Stash list: empty

**Priority for Next Session:**
1. Test PR #57 fix: rip a disc whose MusicBrainz title contains `?` or other illegal Windows path characters and confirm the output directory is created successfully
2. Test PR #58 fix: confirm the console no longer shows `progress - XX.XX%` noise during a real rip while still completing normally
3. Test PR #59/#60 fix: run `search-metadata.ps1 -Recurse` against a folder where an album name is a partial prefix of the MusicBrainz result and confirm the `Partial match:` prompt appears and requires `y` to proceed
4. Continue end-to-end testing of the full rip workflow with a real disc (AccurateRip regex validation)

---

### 2026-02-23 - Multi-disc, Drive Auto-detect, Cover Art Embedding, Encoding Fixes, Coffee Badge

**PRs Merged:**

- PR #68 - fix(rip): multi-disc detection, drive auto-detect, cover art embedding
  - Added `+discids` to MusicBrainz URLs in `Get-DiscMetadata` so `medium.discs` array is populated (fixes blank disc number on multi-disc albums)
  - Added more disc ID regex patterns to handle "Disc ID: X" format from cyanrip on network failure
  - `-Drive` and `-OutputDrive` now default to `""` — auto-detects optical drive via `Get-CimInstance Win32_CDROMDrive`, defaults output to `$env:SystemDrive`
  - After cover art download in Step 3, now embeds into all FLAC files using `metaflac`; tracks `$script:CoverArtEmbedded` count; shows "Cover art embedded: N/M file(s)" in FILE SUMMARY
  - `Roadmap.md`: added Planned section with offline/internet-independent operation item

- PR #69 - fix(metadata): decode metaflac output as UTF-8 to fix smart quotes/accents
  - Added `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` after param block in `search-metadata.ps1` and `audit-metadata.ps1`
  - Fixes garbled characters like `ÔÇÖ` when FLAC tags contain smart quotes/accented characters

- PR #70 - feat: add buy me a coffee nudge to all success summaries
  - Added two-line coffee nudge at end of success summaries in all three scripts

- PR #71 - fix(metadata): skip generic album tags, use folder name instead
  - When ALBUM tag matches "Unknown disc ...", "Unknown track", or "Track N", fall back to folder name for metadata search

- PR #72 - docs: add resume examples and fix drive parameter defaults in README
  - Updated Resuming Interrupted Rips section with concrete re-run examples
  - Fixed `-Drive` and `-OutputDrive` defaults in parameters table (was D:/E:, now auto-detect/system drive)

- PR #73 - fix: replace em dashes in string literals to fix PS5.1 parse error
  - Em dash (—) in `Write-Host` string literals caused parse error: UTF-8 byte 0x94 decoded as closing `"` in Win-1252
  - Fixed in `rip-audio.ps1` (x2) and `search-metadata.ps1` (x1)

- PR #74 - fix: refresh PATH before metaflac install check
  - `Assert-MetaflacInstalled` now refreshes `$env:PATH` from registry before deciding metaflac is missing
  - Fixes repeated install prompts when metaflac is installed but the session predates its PATH entry

- PR #75 - feat: add ASCII coffee art badge to success summaries
  - Replaced plain text coffee message with `Show-CoffeeBadge` function in all three scripts
  - Box drawn via `[char]` casts (Unicode double-line box chars built at runtime, source stays ASCII-safe)
  - Steam/cup in DarkYellow, text in White, URL in Yellow, border in DarkGray

- PR #76 - feat: add arrows and click here to coffee badge
  - Added `>>` before URL, replaced blank cup-bottom row with `>>> click here! <<<` in Cyan

- PR #77 - feat: blank line + up-arrow style in coffee badge
  - Added blank cup-body row between text and URL for visual separation
  - Changed `>>> <<<` to `^^^ ^^^` for the click here arrows

**Session Verified Clean:**
- All 10 PRs (#68-#77) squash-merged to master
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master)
- No open PRs
- Stale remote branches `feature/coffee-badge-arrows` and `feature/coffee-badge-spacing` pruned

**Technical Notes:**
- PowerShell 5.1 reads .ps1 files without UTF-8 BOM as Windows-1252. The last byte of some UTF-8 multibyte chars (e.g. 0x94 from em dash — or box-drawing chars like ╔) decodes as `"` in Win-1252, breaking string parsing. Fix: use ASCII in string literals, or build Unicode chars at runtime via `[char]` casts.
- `[Console]::OutputEncoding` must be set to UTF8 for `metaflac` output to decode correctly — set after param block in both `search-metadata.ps1` and `audit-metadata.ps1`.
- `Assert-MetaflacInstalled` must refresh PATH from registry before calling `Get-Command metaflac`, otherwise already-installed tools are not found in new sessions.
- Cover art embedding uses `metaflac --import-picture-from=3||||<path>` (type 3 = Front Cover) applied to all FLAC files after download.

**Priority for Next Session:**
1. All roadmap items are complete — no pending development work remains
2. Consider end-to-end testing: rip a real disc and confirm auto-detect of drive, correct disc number on multi-disc albums, cover art embedded into FLAC files, and coffee badge displayed in summary
3. Consider end-to-end testing of `search-metadata.ps1` with accented/smart-quote tags to verify UTF-8 encoding fix
4. Offline/internet-independent operation (noted in Roadmap.md Planned section) is a future stretch goal

---

### 2026-02-24 - Coffee Badge Fix, Artist Mismatch Detection, Undo Metadata

**PRs Merged:**

- PR #78 - fix: widen coffee badge and update text
  - Widened box from 53 to 60 chars to fit new text
  - Changed "Buy me a coffee!" to "Consider buying me a coffee!"
  - Fixed URL row that was 52 chars instead of 53 (all rows now exactly 60 chars)
  - Updated in all 3 scripts: `search-metadata.ps1`, `audit-metadata.ps1`, `rip-audio.ps1`

- PR #79 - feat(metadata): add artist mismatch detection
  - Added `Test-ArtistMismatch` function using fuzzy contains-match (`-like "*...*"`)
  - Inserted mismatch check after Step 2 search results, before Step 3 confirmation
  - Batch mode (`-Recurse`): auto-skips on mismatch (safe default)
  - Interactive mode: prompts `Apply anyway? [y/N]` with default No
  - Skips check when no folder artist is known (can't compare)
  - Prevents wrong artist metadata being applied (e.g. Cher album matched to Rolling Stones)

- PR #80 - feat: add undo metadata feature
  - Added structured undo logging to `search-metadata.ps1`:
    - `UNDO_BASELINE|<filepath>|TITLE=...|ARTIST=...|...` before Step 4 tag application
    - `UNDO_RENAME|<new_path>|<old_path>` before each file rename
    - `UNDO_COVER_ART|<folder>|<file>|<had_existing>` before cover art download
  - Created `undo-metadata.ps1` with 4-step workflow:
    1. Parse log file for `UNDO_*` entries
    2. Preview what will be reversed
    3. Confirm with `Apply undo? [Y/n]`
    4. Execute: reverse renames first, then restore tags, then remove newly downloaded cover art
  - Supports `-DryRun` for preview without changes
  - Supports wildcard log file paths (auto-resolves, rejects ambiguous matches)
  - Updated README.md with artist mismatch detection docs and undo-metadata.ps1 usage section
  - Updated Roadmap.md to mark both features as completed
  - Updated CLAUDE.md project structure to include `undo-metadata.ps1`

**Technical Notes:**
- Pipe characters (`|`) in tag values are escaped to `_` in UNDO_BASELINE entries to avoid corrupting the `|`-delimited log format
- TRACKTOTAL and MUSICBRAINZ_ALBUMID are read directly via `metaflac --show-tag` for baseline logging since they're not stored in the `$existingTracks` hashtable from `Read-ExistingTags`
- Undo execution order is critical: renames must be reversed FIRST so that the original file paths referenced in BASELINE entries are valid when tags are restored
- Cover art is only deleted if `HadExistingArt` was False (newly downloaded); pre-existing art is preserved

**Session Verified Clean:**
- All 3 PRs (#78-#80) squash-merged to master
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master)
- No open PRs

**Priority for Next Session:**
1. Test `undo-metadata.ps1` end-to-end: run `search-metadata.ps1` on a test album, verify UNDO_* entries in log, then run undo and confirm tags/filenames are restored
2. Test artist mismatch detection: run `search-metadata.ps1 -Recurse` on a folder where album name matches wrong artist, verify auto-skip in batch mode
3. Test artist mismatch in interactive mode: verify `[y/N]` prompt appears and default is No
4. Note: only logs created after PR #80 will contain UNDO_* data; older logs will report "No undo data found"
5. Offline/internet-independent operation remains the only planned roadmap item

---

### 2026-02-24 - Duration Validation, Array Fix, Folder Retry, Multi-Disc, Reset Switch

**PRs Merged:**

- PR #81 - docs: add 2026-02-24 session notes and create CHANGELOG.md
  - Session notes added to CLAUDE.md for PRs #78-#80
  - CHANGELOG.md created to document feature history

- PR #82 - fix: align coffee badge border and retry search with disc suffix stripped
  - Coffee badge border width alignment fixes
  - When tag-based searches return artist mismatch, now retries with disc suffix (e.g. "Disc 1") stripped from album name

- PR #83 - fix(metadata): validate MusicBrainz candidates by track duration
  - When multiple MusicBrainz releases match the same artist/album/track count, compare local FLAC file durations against MusicBrainz recording lengths to select the correct release
  - Reads track lengths from FLAC files using `metaflac --show-tag=LENGTH` (length stored in samples at 44100 Hz sample rate)
  - Fetches recording durations from MusicBrainz (in milliseconds) for each candidate release
  - Picks the release whose total duration is closest to the local files' total duration
  - Falls back to first candidate if no duration data is available

- PR #84 - fix(metadata): handle metaflac array output and add folder-name retry
  - Fixed "Cannot index into a null array" crash when `metaflac --show-tag` returns multiple lines for a single field (e.g. multiple ARTIST values)
  - Now takes only the first line when the result is an array
  - Added folder-name retry: when all tag-based album searches fail with an artist mismatch, falls back to the raw folder directory name as the search term
  - Catches cases where FLAC tags have different spelling than the folder name that a human would recognise

- PR #85 - fix(metadata): multi-disc matching, track-number sort, disc-aware duration validation
  - Sort FLAC files by TRACKNUMBER tag (via `metaflac --show-tag=TRACKNUMBER`) instead of alphabetically — fixes wrong ordering for filenames like `(1),(10),(2)` due to lexicographic sort
  - Match multi-disc releases where an individual medium has the same track count as the local folder (not just total tracks across all media)
  - Extract disc number from folder name using patterns like "Disc 1", "CD 2", "Disk 3" to select the correct medium from a multi-disc MusicBrainz release
  - Duration validation uses durations from the matched medium only, not from all tracks across the release

- PR #86 - feat(metadata): add -Reset switch to clear tags and rename to generic format
  - New `-Reset` switch in `search-metadata.ps1`: strips all metadata tags and renames files to `NN - Artist - Album.ext` generic format
  - Reads current ARTIST and ALBUM tags before stripping (used for rename)
  - Uses `metaflac --remove-all-tags` to strip all tags from each FLAC file
  - Rename format: `01 - Artist - Album.flac`, `02 - Artist - Album.flac`, etc.
  - Supports `-DryRun` (preview what would happen without making changes)
  - Supports `-Force` (skip confirmation prompt)
  - Undo is possible via `undo-metadata.ps1` since UNDO_BASELINE and UNDO_RENAME entries are written to the log before changes are applied
  - Useful as a starting point before running `search-metadata.ps1` normally to re-apply correct metadata from scratch

**Technical Notes:**
- Duration matching (PR #83): FLAC length stored in samples; converted to ms via `$samples / 44100 * 1000`. MusicBrainz returns durations in ms. Total duration delta used for candidate scoring.
- Metaflac array guard (PR #84): `$val = @(metaflac --show-tag=FIELD file.flac)[0]` — wrapping in `@()` and indexing `[0]` ensures a single string is returned even if metaflac emits multiple lines.
- Track-number sort (PR #85): reads `TRACKNUMBER` tag per file, casts to `[int]`, sorts ascending. Falls back to alphabetical sort if no TRACKNUMBER tags present.
- Multi-disc detection (PR #85): MusicBrainz release `media` array iterated; first medium whose `track-count` matches local file count is selected. Disc number extracted from folder name via regex `(?:disc|disk|cd)\s*(\d+)` (case-insensitive).
- Reset mode (PR #86): executes before the normal search-metadata workflow. After reset, script exits rather than continuing into the metadata search pipeline.

**Session Verified Clean:**
- All 6 PRs (#81-#86) squash-merged to master
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master)
- No open PRs
- Branches: only `master` local; all feature branches deleted locally and remotely
- Stash list: empty

**Priority for Next Session:**
1. Test PR #83 duration validation: find an album with multiple MusicBrainz candidates (same artist/album/track count) and confirm the correct edition is selected by duration
2. Test PR #84 folder-name retry: process a folder where FLAC tags have different artist spelling than folder name, confirm fallback triggers
3. Test PR #85 multi-disc matching: run `search-metadata.ps1` on a folder for one disc of a multi-disc set (e.g. "CD 1"), confirm the correct medium is selected
4. Test PR #85 track-number sort: verify files with numerically out-of-order filenames (e.g. `10 - ...`, `2 - ...`) are processed in correct track order
5. Test PR #86 `-Reset` followed by normal `search-metadata.ps1` run: confirm reset produces clean generic filenames, then confirm re-tagging applies correct metadata
6. Offline/internet-independent operation remains the only planned roadmap item

---

### 2026-02-28 - Metadata Source and Cover Art Source Tracking

**PRs Merged:**

- PR #87 - feat(rip): add metadata source and cover art source tracking
  - Added `$script:MetadataSource` tracking variable set at all decision points in `rip-audio.ps1`: MusicBrainz (default), CDDB (when MusicBrainz returns no match), Generic (no external lookup)
  - Added `$script:CoverArtSource` tracking variable set at each cover art download point: cyanrip (art bundled by cyanrip), Cover Art Archive (direct lookup), MusicBrainz CAA (search + CAA fallback), iTunes (iTunes Search API), Deezer (Deezer API)
  - Both variables displayed in the FILE SUMMARY block with colour coding: MusicBrainz = green, CDDB = yellow, Generic = red; cover art source shown inline: "Yes (iTunes)" instead of just "Yes"
  - Both variables logged to the session log file
  - Roadmap.md: offline/internet-independent operation item marked as completed — the ROADMAP IS NOW FULLY COMPLETE (no remaining planned items)

**Technical Notes:**
- `$script:MetadataSource` initialised to `"MusicBrainz"` and overwritten whenever the code path diverges (e.g. CDDB lookup succeeds, or generic names are used)
- `$script:CoverArtSource` initialised to `""` and set at each cover art download branch before the download is attempted; remains `""` if no cover art is downloaded
- Colour coding in FILE SUMMARY uses `switch` on the variable value — no new helper function needed
- Cover art display in FILE SUMMARY conditionally appends `" ($script:CoverArtSource)"` when a source is set

**Roadmap Status:**
- Roadmap.md is now fully complete — all planned items are in the Completed section; no Planned or In Progress items remain

**Session Verified Clean:**
- PR #87 squash-merged to master; feature branch deleted
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master)
- No open PRs

**Priority for Next Session:**
1. The ROADMAP IS FULLY COMPLETE — no outstanding development items remain
2. End-to-end test: rip a disc that falls back to CDDB and confirm "Metadata: CDDB" appears in yellow in the FILE SUMMARY
3. End-to-end test: rip a disc with no MusicBrainz/CDDB match and confirm "Metadata: Generic" appears in red in the FILE SUMMARY
4. End-to-end test: rip a disc and confirm cover art source (e.g. "Cover art: Yes (iTunes)") appears correctly in FILE SUMMARY

---

### 2026-03-02 - Disc Metadata Parsing Rewrite, Stub Disc Handling, Mp3tag Fallback

**PRs Merged:**

- PR #88 - fix(rip): parse disc metadata from cyanrip output, fix disc ID regex and MB API URL
  - Rewrote `Get-DiscMetadata` to parse album/artist/disc info directly from cyanrip output instead of making separate MusicBrainz API calls post-rip
  - Fixed disc ID regex that was incorrectly matching "has" from the phrase "DiscID has a matching stub" — regex now anchors to the disc ID pattern properly
  - Fixed MusicBrainz API URL (incorrect endpoint was being called)
  - Added `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` to `rip-audio.ps1` so cyanrip UTF-8 output is captured correctly by PowerShell

- PR #89 - fix(rip): handle MusicBrainz stub discs (superseded by PR #90)
  - Attempted to retry MusicBrainz lookup with `-a`/`-t` flags when a stub disc is detected
  - This approach was found to be broken and was removed in PR #90

- PR #90 - fix(rip): remove broken stub retry and fix discid API URL
  - Removed the broken stub-disc retry logic added in PR #89
  - MusicBrainz stub discs now correctly fall through to CDDB fallback then generic names — the normal fallback chain handles this correctly
  - Fixed the discid API URL: removed invalid `inc` parameters that were causing API errors

- PR #91 - feat(rip): prompt to open Mp3tag when metadata search fails
  - Added Mp3tag fallback prompt shown when all metadata sources fail (MusicBrainz + CDDB both return no match)
  - Auto-detects Mp3tag install via standard registry/path locations
  - 30-second timeout on the prompt — auto-continues without opening Mp3tag if no response
  - Allows the user to manually tag files immediately after a failed rip rather than having to find the folder separately

- PR #92 - docs: update README and CHANGELOG for PRs #88-#91
  - README updated to document the new disc metadata parsing behaviour and Mp3tag fallback prompt
  - CHANGELOG updated with entries for PRs #88-#91

**Technical Notes:**
- `Get-DiscMetadata` rewrite: cyanrip prints disc metadata (album, artist, disc title, release date, track count) to stdout during its lookup phase; parsing this output directly is more reliable than making a second MusicBrainz API call and avoids rate-limiting concerns
- Stub disc detection: cyanrip outputs "DiscID has a matching stub" when MusicBrainz knows the disc ID but has no full release entry; the old regex accidentally matched "has" in this string — the fix anchors on the disc ID hex pattern
- discid API URL fix: the `inc` parameter is not valid for the discid lookup endpoint; removing it resolved 400 errors when looking up disc IDs directly
- Mp3tag auto-detect: checks `$env:ProgramFiles`, `${env:ProgramFiles(x86)}`, and `$env:LOCALAPPDATA` for `Mp3tag\Mp3tag.exe`; opens the ripped folder directly in Mp3tag if found
- UTF-8 encoding: `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` added early in `rip-audio.ps1` ensures cyanrip output containing non-ASCII characters (accented artist/album names) is captured correctly

**Session Verified Clean:**
- All 5 PRs (#88-#92) squash-merged to master; all feature branches deleted locally and remotely
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master)
- No open PRs
- Stash list: empty (one obsolete stash from mid-session was dropped during session closure)
- Remote branches remaining (orphaned, never deleted): docs/session-updates, feature/offline-summary — these predate this session and have no commits ahead of master

**Priority for Next Session:**
1. The ROADMAP IS FULLY COMPLETE — no outstanding development items remain
2. Clean up orphaned remote branches: `git push origin --delete docs/session-updates feature/offline-summary`
3. End-to-end test: rip a disc that triggers the Mp3tag prompt (disc not in MusicBrainz or CDDB) and confirm the prompt appears, auto-detects Mp3tag, and opens the folder
4. End-to-end test: rip a disc that returns a MusicBrainz stub and confirm it falls through to CDDB then generic names correctly
5. Earlier test suggestions (PRs #83-#87) still stand as useful validation exercises

---

### 2026-03-23 - False Data Error Fix (PR #106)

**PR #106 merged: `fix/false-data-error-detection`**
- Bug: the regex `rip(ping)? error` (used to detect cyanrip data errors mid-rip) matched inside cyanrip's own `Ripping errors: 0` summary line printed at the end of every track
- Effect: every rip flagged the last track as having a data error, even on a perfectly clean disc
- Fix: added a negative lookahead so the regex only matches if the line does not contain `Ripping errors: 0` (or similar "N errors" patterns that indicate a clean summary line)

**Session Verified Clean:**
- PR #106 squash-merged to master; feature branch deleted
- Working tree: clean, no uncommitted changes
- No open PRs

**Priority for Next Session:**
1. End-to-end test: verify no false data error is reported on a clean rip after PR #106
2. PSGallery publish still pending — get API key from powershellgallery.com and run `Publish-Module`

---

### 2026-04-23 - Silent Cyanrip Failure Root Cause (PRs #110, #111, #112, #113)

**Symptom reported by user:**
- `rip-audio.ps1` failed to even parse with `Variable reference is not valid. ':' was not followed by a valid variable name character` at line 1728
- After parse fix, cyanrip "completed" in 2-30 seconds but produced zero audio files, no console output between `Executing cyanrip command...` and `cyanrip complete!`
- Affected every rip on every disc/drive combination, with or without multi-release selection

**PR #110 merged: `fix/failed-track-variable-parse-error`**
- Bug: `Write-Log "Track $failedTrack: unreadable ..."` at line 1728 — PowerShell 5.1 parser treats `$failedTrack:` as a drive-qualified variable reference (same syntax as `$env:PATH`), causing an unconditional ParserError before the script can run at all
- Fix: wrap variable in `${}` so the colon is a literal string character — `${failedTrack}:`

**PR #111 merged: `fix/cyanrip-silent-failure-detection`** (symptom-level guardrails)
- Three related issues where cyanrip appeared to succeed but wrote no audio:
  1. Added post-cyanrip verification: if the output dir contains zero non-empty audio files after cyanrip "complete", fail loudly with a diagnostic that distinguishes disc-read failure (TOC errors) from stale-files scenario
  2. When user chooses *Continue (rip all tracks)* at the no-valid-tracks prompt, delete pre-existing stale audio files before re-running cyanrip — cyanrip will not overwrite existing files, so leaving them produced a silent 0-byte failure on the next rip
  3. Step 2 verification now filters `Length -gt 0` — zero-byte files are no longer counted as "ripped"
- These guardrails correctly surfaced the silent failure but did not address its cause. Kept in place because they still defend against future silent-failure classes (e.g. stale 0-byte files from an interrupted rip).

**PR #112 merged: `fix/cyanrip-argumentlist-ps51-incompatibility`** (secondary bug, kept)
- `ProcessStartInfo.ArgumentList` is a **.NET Core / .NET 5+ API**. On Windows PowerShell 5.1 (backed by .NET Framework 4.8), the property returns `$null`, not an `IList<string>`.
- In `Start-CyanripWithErrorDetection`, the launch loop `foreach ($a in $Args) { $psi.ArgumentList.Add($a) }` called `.Add()` on the null collection. The error was silently absorbed so even if the arg array had been visible, it would never have been applied to the process.
- Fix: build a quoted argument string and assign to `$psi.Arguments` directly. Manual quoting: wrap in double quotes if the value contains whitespace or quotes, escape embedded quotes with `\"`, otherwise pass through verbatim. Works on both .NET Framework 4.x and .NET Core/.NET 5+.
- This is a real compatibility fix on its own, but it did not fix the rip in isolation because the outer parameter binding (see PR #113) was discarding the arg array one layer earlier.

**PR #113 merged: `fix/cyanrip-args-reserved-variable`** (TRUE root cause)
- `$Args` is a **reserved PowerShell automatic variable**. Declaring a function parameter named `$Args` is silently overridden by the (empty) automatic `$args` at call time, so the caller's array is *discarded at parameter binding*. The body of `Start-CyanripWithErrorDetection` saw an empty `$Args` on every invocation.
- Result: every cyanrip call since PR #56 (2026-02-22, real-time streaming rewrite) launched with zero arguments. cyanrip printed its internal usage and exited 0 within a couple of seconds, producing the classic silent failure.
- Fix: rename the parameter from `$Args` to `$CyanripArgs`, update all 8 call sites (`Start-CyanripWithErrorDetection -CyanripArgs $cyanripArgs -WorkDir $parentDir`).
- Reproduction in isolation:
  ```
  function Test-Args { param([string[]]$Args); "count=$($Args.Count)" }
  Test-Args -Args @('a','b','c')        # count=0 (silently wrong)

  function Test-CA { param([string[]]$CyanripArgs); "count=$($CyanripArgs.Count)" }
  Test-CA -CyanripArgs @('a','b','c')   # count=3 (correct)
  ```

**Why three PRs were needed to get to the root cause:**
- The symptom (silent 2-second exit, no output) is consistent with several failure classes: bad args, empty args, binary crash, stdin block, stream redirection hang. Working outward from symptom to cause:
  - PR #111 made the silent failure visible in the right place (post-cyanrip verification) rather than collapsing into a confusing Step 2 "No audio files found" much later
  - PR #112 correctly identified that `ArgumentList` is null on .NET Framework 4.8. Smoke-testing the replacement with `cmd.exe` worked, confirming the new arg path was sound — but the rip still failed on retry, ruling out the "wrong args reaching the process" theory as the primary cause
  - PR #113 found the layer above: PowerShell's reserved-variable collision was discarding the args *before* they reached the ProcessStartInfo at all

**Technical Notes:**
- PowerShell reserved automatic variables that should NEVER be used as param names: `$Args`, `$Error`, `$Host`, `$Home`, `$Input`, `$PSBoundParameters`, `$PSCommandPath`, `$PSCmdlet`, `$PSCulture`, `$PSDebugContext`, `$PSHome`, `$PSItem`, `$PSScriptRoot`, `$PSUICulture`, `$PSVersionTable`, `$This`, `$True`, `$False`, `$Null`, `$Matches`, `$MyInvocation`. A function parameter named after any of these is silently discarded.
- `ProcessStartInfo.ArgumentList` availability: .NET Core 2.1+, .NET 5+. Not in any .NET Framework version (including 4.8 and 4.8.1). Use `$psi.Arguments` (string) with manual quoting on PS 5.1.
- The replacement argument-quoting logic handles the common cyanrip arg set correctly: `-D "Reload with space" -o flac -d E: -s 0 -R 1`

**Session Verified Clean:**
- All 4 PRs (#110, #111, #112, #113) squash-merged to master
- Working tree: docs-only modifications (CLAUDE.md, CHANGELOG.md)
- No unpushed code commits (master is at 6e585e0)
- No open PRs

**Priority for Next Session:**
1. **End-to-end smoke test** — re-run `.\rip-audio.ps1 -Drive E: -OutputDrive C:` on the Tom Jones / Dusty Springfield discs. With `$CyanripArgs` now wired up, cyanrip should actually stream real output to the console and produce real FLAC files. This is the user-facing validation that the three-PR chain is complete.
2. Confirm the multi-release selection path (`-R N` arg passthrough) works end-to-end with the new parameter name.
3. PSGallery publish still pending — get API key from powershellgallery.com and run `Publish-Module`.
4. **Follow-up (cosmetic):** `rip-audio.ps1:2416` prints `Tagged: X` after a `& metaflac` call without checking `$LASTEXITCODE`, so tagging failures still produce misleading "Tagged:" lines. Not harmful but confusing in logs.
5. **Audit other scripts** (`search-metadata.ps1`, `audit-metadata.ps1`, `get-metadata.ps1`, `undo-metadata.ps1`) for similar reserved-variable parameter bugs — grep for `param(` followed by reserved names.

---

### 2026-04-23 (pt 2) - Console Output, UX Polish, and Disc Backup/Restore (PRs #115-#122)

Continuation of the same session. Root cause (`$CyanripArgs` rename) was fixed in PR #113; these PRs addressed the console being silent during a working rip, added UX improvements, and hardened the script against disc-read failures destroying already-ripped tracks.

**PRs Merged:**

- **PR #115** — fix(rip): stream cyanrip output live via `StreamReader.ReadLineAsync()` polling
  - After PR #113, cyanrip was ripping correctly but the console was completely silent throughout
  - Root cause: `$proc.add_OutputDataReceived({...})` scriptblock events in PowerShell 5.1 run in a different scope from the caller and cannot access closure variables (e.g. a `$outLines` queue declared in the outer function); lines were silently dropped
  - Fix: replaced event-based output with a polling loop calling `StreamReader.ReadLineAsync()` and checking `Task.IsCompleted` on the main thread — no cross-scope closure needed
  - `StreamReader` polling is the reliable pattern for PS 5.1; `add_OutputDataReceived` scriptblock events are not.

- **PR #116** — feat(rip): always-verbose cyanrip output (removed `progress - XX.XX%` suppression)
  - Removed the filter added in PR #58 that was suppressing cyanrip progress lines
  - Rationale: with the streaming rewrite now working, users need to see something; progress % lines are better than a silent console

- **PR #117** — feat(rip): "It's ripping time!" walk-away banner before cyanrip launch
  - Added a coloured walk-away banner (`It's ripping time!`, cyanrip command summary) displayed immediately before cyanrip launches
  - Signals to the user they can step away from the keyboard

- **PR #118** — feat(rip): collapse cyanrip progress ticker to one line per 10% bucket per track
  - Reintroduced selective suppression: each `progress - XX.XX%` line is compared to the last-printed bucket; only printed when the percentage crosses a 10% threshold (0%, 10%, 20%, ..., 100%)
  - Result: one milestone line per track per 10% rather than hundreds of lines or complete silence
  - Undoes the over-correction in PR #116

- **PR #119** — fix(rip): defer walk-away banner and skip bogus 0% ETA
  - Moved the walk-away banner to trigger on the first `Ripping and encoding track N` line inside the streaming loop, not at launch, because early ETAs before the drive spins up can be nonsensical (e.g. "424h 29m")
  - Skipped the 0–9% bucket so the first milestone shown is 10%

- **PR #120** — feat(rip): `Show-QuestionHint` helper + banner back to pre-launch
  - Added `Show-QuestionHint` function that prints `[ A few more questions to answer... ]` before every major interactive prompt block (disc discovery, track selection, directory conflict), so users know they need to answer before the rip starts
  - Moved the walk-away banner back to pre-cyanrip launch (PR #119 had moved it too conservatively); the ETA problem is solved by the 0% skip in PR #119 instead

- **PR #121** — fix(rip): tolerate partial rips (non-zero exit code + some good tracks)
  - cyanrip exits non-zero even when some tracks ripped successfully (e.g. on a scratched disc where one track is unreadable)
  - Previous behaviour: hard-abort on any non-zero exit code, losing the good tracks
  - New behaviour: if any non-empty audio files exist post-cyanrip, print a yellow `WARNING: cyanrip exited N — partial rip` message and continue to Step 2+ (verify, tag, cover art) rather than aborting
  - Full abort only if zero audio files were produced

- **PR #122** — fix(rip): back up existing audio before cyanrip, restore any truncated files on failure
  - Before cyanrip launches, backs up all existing non-empty audio files from the output directory to a temp folder (`%TEMP%\ripaudio-backup-XXXX\`)
  - After cyanrip completes, checks whether any previously-backed-up files are now 0 bytes (cyanrip can truncate existing files when it hits a TOC read failure)
  - Any truncated files are restored from the backup; files cyanrip ripped successfully are left as-is
  - Protects already-ripped tracks on a damaged multi-rip session from being destroyed by a subsequent failed cyanrip invocation

**Three Durable Lessons from This Session:**

1. **PowerShell reserved automatic variables** — never use `$Args`, `$Error`, `$Host`, `$Input`, `$Matches`, `$MyInvocation`, `$PSBoundParameters`, `$PSCmdlet`, `$This`, `$True`, `$False`, `$Null` (and others) as function parameter names. PowerShell silently overrides the parameter binding with the (usually empty) automatic variable. PR #113 spent three iterations of debugging to uncover this.

2. **`ProcessStartInfo.ArgumentList` is not on .NET Framework** — only .NET Core 2.1+ / .NET 5+. On PS 5.1 the property is `$null` and `.Add()` silently fails under a try/catch. Use `$psi.Arguments = <quoted string>` instead.

3. **PowerShell 5.1 async event scriptblocks cannot see the caller's closure variables** — `$proc.add_OutputDataReceived({...})` registered from PS 5.1 runs in a different scope; it cannot access a `$queue` or any variable declared in the outer function. Use `StreamReader.ReadLineAsync()` and poll `Task.IsCompleted` from the main thread instead.

**Hardware Note:**
- The Alanis Morissette "Jagged Little Pill" disc tested during this session has an unreadable TOC regardless of script settings. This is a hardware reality (damaged disc), not a script bug. The disc needs cleaning or is unrippable.

**Known Follow-up Items:**
- Cosmetic: `rip-audio.ps1:2416` prints `Tagged: X` after `& metaflac` without checking `$LASTEXITCODE` — misleading log lines on metaflac failure.
- PSGallery publish still pending.
- Audit `search-metadata.ps1`, `audit-metadata.ps1`, `get-metadata.ps1`, `undo-metadata.ps1` for the same `$Args` reserved-variable bug and `.add_*Received` async event scope bug.

**Session Verified Clean:**
- All 13 PRs (#110–#122) squash-merged to master
- Working tree: clean, no uncommitted changes
- No unpushed commits (master is up to date with origin/master at `bf29db9`)
- No open PRs

---

### 2026-08-17 - Dylan Thomas Handoff Failure: Start-Process Quoting, metaflac Exit Code (PRs #124, #125)

**Trigger:**
User ripped a Dylan Thomas album to `C:\Music\Dylan Thomas\Under Milk Wood`. The automatic handoff from `rip-audio.ps1` to `search-metadata.ps1` died with:
```
search-metadata.ps1 : A positional parameter cannot be found that accepts argument 'Wood'.
```
The album fell through to the Mp3tag manual-tagging prompt instead of being tagged automatically.

**PR #124 — `fix/start-process-path-quoting`: root cause of the reported bug**

`Start-Process -ArgumentList @(...)` joins its array elements on spaces into a single command-line string and does **not** quote them. `"-Path", "C:\Music\Dylan Thomas\Under Milk Wood"` therefore reached the child process as `-Path C:\Music\Dylan Thomas\Under Milk Wood` — unquoted. `search-metadata.ps1` bound `$Path` to `C:\Music\Dylan`, then bound its positional `$Artist`/`$Album` params to `Thomas\Under` and `Milk`, leaving `Wood` with no positional slot to bind to.

Four call sites carry the same defect class, all fixed by wrapping the path in embedded quotes via `` "`"$($var.TrimEnd('\'))`""``:
- `rip-audio.ps1` ~line 3008 — the `search-metadata.ps1` handoff (the reported failure)
- `audit-metadata.ps1` ~line 418 — the same handoff in the step 4 audit + fix pipeline
- `rip-audio.ps1` ~line 1232 — `Start-Process explorer.exe` in `Stop-WithError`
- `rip-audio.ps1` ~line 2917 — `Start-Process explorer.exe` in step 4

`TrimEnd('\')` is load-bearing: a trailing backslash immediately before a closing quote is parsed as an escaped quote on a Windows command line, which would reintroduce exactly the splitting the fix removes.

Verified by reproducing the exact failure against a stub script carrying `search-metadata.ps1`'s param block with the old unquoted pattern (`A positional parameter cannot be found that accepts argument 'Wood'`), then confirming the new quoted pattern binds correctly: `Path=[C:\Music\Dylan Thomas\Under Milk Wood]`, `Artist=[]`, `Album=[]`.

**PR #125 — `fix/metaflac-exit-code-check`, stacked on #124: closes a follow-up item carried since 2026-04-23**

`rip-audio.ps1` ~line 2579 printed `Tagged: <file>` to console and log immediately after `& metaflac --set-tag=...` without checking the result. A non-zero exit from an external exe does not raise a terminating error in PowerShell, so the surrounding try/catch never fired and tagging failures were logged as successes. Now gated on `$LASTEXITCODE -eq 0`, with a yellow console warning and a `WARNING:` log line on the else branch — a direct port of the pattern already used at `search-metadata.ps1:1319-1320`.

Demonstrated the underlying semantics directly: `& cmd.exe /c "exit 3"` inside a try/catch threw no exception and left `$LASTEXITCODE = 3` — proof the old catch block could never have seen a metaflac failure.

**Proactive sibling-repo find:** the same `Start-Process -ArgumentList` quoting defect was found in `ripdisc` (rip-disc.ps1:931, continue-rip.ps1:646) and fixed there today as PR #112. See ripdisc's CLAUDE.md for details.

**Follow-up items formally closed this session (portfolio review, not new fixes):**
- **`$Args` reserved-variable parameter bug** — audited `search-metadata.ps1`, `audit-metadata.ps1`, `get-metadata.ps1`, and `undo-metadata.ps1`; none declares a `param()` using `$Args` or any other reserved automatic variable name. Clean. This item should stop being re-listed.
- **`.add_*Received` async-event scope bug** — only `rip-audio.ps1` spawns subprocesses with output capture, and it was already fixed by the `StreamReader.ReadLineAsync()` rewrite in PR #115 (2026-04-23). Clean. This item should stop being re-listed.

**Validation status — nothing is hardware-validated:**
All three fixes (quoting in #124, exit-code check in #125) were verified by parse checks, stub-script reproduction, and direct demonstration of PowerShell semantics. No disc was ripped, no real metaflac failure was forced, no `explorer.exe` was launched against a spaced path. The next real rip exercises all three at once.

**The Dylan Thomas album itself is still untagged on disk.** The code is fixed but that album was never re-processed. Next session should run:
```powershell
.\search-metadata.ps1 -Path "C:\Music\Dylan Thomas\Under Milk Wood"
```

**Pre-existing conflicting branches — left alone, need a decision:**
- `feature/shareable` (1 ahead / 23 behind origin/master) — adds MIT license, a PSGallery manifest, removes SiteGround affiliate art
- `fix/restore-siteground-art` (1 ahead / 22 behind origin/master) — restores that same SiteGround affiliate art
- Each holds one unique commit and they make opposite changes to the same content, so neither can be deleted without losing work. Needs a direction decision from the user plus a rebase of whichever branch is kept. Note: the PSGallery manifest in `feature/shareable` overlaps with the long-pending PSGallery publish item below — resolving the branch may resolve that item too.

**Process note — self-approval:**
`gh pr review --approve` cannot succeed on this repo; GitHub rejects self-approval because the user authors all PRs under the same account. Confirmed again this session. Sign-off was recorded as a PR comment instead, and both PRs were merged with zero formal approvals — this is expected, not an error.

**Files changed:** `rip-audio.ps1`, `audit-metadata.ps1`, `CHANGELOG.md` (PRs #124, #125)

**Session Verified Clean:**
- Both PRs (#124, #125) squash-merged to master, feature branches deleted locally and remotely
- Working tree: clean, no uncommitted changes
- No unpushed commits
- No open PRs
- No stash entries
- `feature/shareable` and `fix/restore-siteground-art` remain as pre-existing conflicting local/remote branches (see above) — not touched this session, not stale (each has a unique unmerged commit)

**Priority for Next Session:**
1. Run `.\search-metadata.ps1 -Path "C:\Music\Dylan Thomas\Under Milk Wood"` to actually tag the album that triggered this session.
2. Live end-to-end validation: rip a disc to a spaced-path album folder and confirm the `search-metadata.ps1` handoff now runs automatically instead of falling through to Mp3tag.
3. Force a real metaflac failure (or otherwise get one to occur) and confirm the yellow console warning and `WARNING:` log line both appear.

---

### 2026-08-26 - Explicit-Drive Validation, Busy-Drive Hard Block, Stale-Branch Cleanup, and Quick Disc Identity (PRs #127-#132)

**Trigger:** `-Drive G` was passed for a rip, but `G:` is not an optical drive on this machine. With no validation on the explicit-drive path, the bad letter sailed through header/log/directory setup and was only caught a minute later by cyanrip itself, with a message indistinguishable from real disc damage: `cyanrip could not read the disc TOC -- disc may be dirty, damaged, or the wrong type`.

**PR #127 (`93e6151`) - `fix/validate-explicit-drive-param`:**
- Root cause: validation only ran on the auto-detect path (`-Drive` omitted); an explicitly-passed value was never checked against reality.
- Fix: an explicit `-Drive` is now matched against the same `Win32_CDROMDrive` WMI list the auto-detect path already used (hoisted so both paths share one lookup). Three outcomes: a match prints a confirmation line; a clear non-match (other real drives detected, just not this letter) fails immediately with the detected list and next-step guidance; zero drives detected at all only warns and proceeds - absence of evidence isn't evidence the requested drive is wrong, so that case deliberately isn't blocked (transient WMI misses happen on some external/USB drives).
- Accepts both `-Drive D` and `-Drive D:`.
- This repo has no test suite (unlike sibling `ripdisc`); verified via `Parser::ParseFile` (0 errors) and an ASCII-only check on added lines only (this repo doesn't use ripdisc's UTF-8 BOM convention).

**PR #128 (`3d6214f`) - `docs/master-branch-references`:**
- `CLAUDE.md`'s Git Workflow section said `main` in two places; this repo's actual default branch is `master` (`git symbolic-ref refs/remotes/origin/HEAD` -> `refs/remotes/origin/master`). Both references corrected. Docs-only.

**PR #129 (`394bdf7`) - `docs/changelog-license-psgallery`:**
- Investigated resolving two long-diverged branches, `feature/shareable` (MIT licence, PSGallery manifest, removes SiteGround affiliate art) vs `fix/restore-siteground-art` (restores that art) - opposite changes to the same content, seemingly still pending.
- Turned out both were **already merged back in March** (`d7eea9c`/PR #102 added the licence/manifest/art-removal, `a885e17`/PR #103 restored the art) and are the current state of `master` - verified directly: `LICENSE` present (MIT), `RipAudio.psd1` present, README Option A/B and licence line present, SiteGround art present in all four scripts. The two diverged branches were just pre-squash originals, superseded rather than pending.
- The one real gap: `CHANGELOG.md` never recorded any of it (jumps straight from 2026-03-02 to 2026-03-23). Added the missing `## 2026-03-11` section in correct chronological position.
- `feature/shareable` and `fix/restore-siteground-art` deleted, local and remote - the long-standing "pre-existing conflicting branches, needs a decision" item from the 2026-08-17 entry above is now resolved (there was no real conflict left to resolve).

**PR #130 (`41d9479`) - `feature/busy-drive-detection-and-listing`:**
- Motivation: running two rips concurrently and nearly pointing a second one at a drive already mid-rip. #127 stopped a *nonexistent* drive from reaching cyanrip's misleading TOC error; this stops a *real but occupied* one from doing the same.
- **Busy-drive detection as a hard block** (not a warn-and-confirm - deliberately tightened during the session, since a prompt can be clicked past): inspects every running `cyanrip` process's command line via `Win32_Process` to determine which drive letters are in use, the same technique `ripdisc` uses for MakeMKV. Covered on all three selection paths: auto-detect single drive (error + exit), auto-detect multi-drive picker (rejects and re-prompts, no exit - other drives may be free), explicit `-Drive` (error + full listing + exit).
- **Ripdisc-style drive listing:** every drive-listing path now shows letter, model, disc volume label where readable, busy/free state, and a `<--` selection marker - matching the shape of ripdisc's `MakeMKV drives:` listing.
- **Two real bugs found and fixed while building this**, not just noted:
  1. cyanrip's `-d` (drive) and `-D` (output directory) flags are case-distinct; a case-insensitive `-match '-d\s+(\S+)'` was matching `-D`'s *output directory* argument instead, producing garbage drive letters. Fixed with `-cmatch`.
  2. `$Matches` is a single global variable - a second inline `-match` against `$Matches[1]` itself (to strip a trailing colon) silently clobbered the very capture just read. Fixed by copying to `$rawDriveArg` before the second match.
- Verified against real live machine state: correctly identified `H:` as busy (genuine in-progress cyanrip process) and `D:` as free with disc label `DADS_ARMY`, correct WMI model names for both. All four branch outcomes also verified against fixture data via an extracted copy of the decision logic. Deliberately **not** run end-to-end through `rip-audio.ps1` itself - a real rip was in progress on `H:` at the time and a live end-to-end run was judged too risky.

**PR #131 (`0ea2fde`) - `fix/busy-check-empty-wmi-gap`:**
- Closed a gap flagged during review of #130: the explicit-`-Drive` branch reached when WMI enumerates **zero** optical drives at all skipped the busy-check entirely, on the mistaken premise (stated in the old code comment) that busy detection "can't run" there since there's no WMI drive entry to check a process command line's drive letter against. That premise was wrong - `$busyDriveLetters` is built entirely from `Win32_Process` cyanrip command lines, independent of the `Win32_CDROMDrive` list.
- Impact: WMI's optical-drive enumeration returning empty is a real, transient condition (why that branch exists at all); a drive going busy during exactly that window would have slipped past #130's hard block and collided with an in-progress rip on the same hardware - the precise failure #130 set out to prevent.
- Fix: new `elseif ($busyDriveLetters -contains $explicitDriveLetter)` branch inserted between "not a recognised optical drive" and "warn and proceed"; hard-blocks (`exit 1`) with the same message shape as #130's busy block (minus drive model/listing, since there's no WMI entry to render). Falls through to warn-and-proceed only when confirmed not busy. Stale comment replaced with accurate reasoning.
- Not hardware-validated: reproducing this path requires WMI enumeration to be empty *while* a cyanrip rip holds the requested drive - a live rip was in progress throughout, so this exact combination wasn't exercised for real.

**PR #132 (`bb40fa7`) - `feature/quick-disc-identity-lookup`:**
- Follow-up to the drive listing in #130/#131: audio CDs have no filesystem, so `Get-Volume` always reports the generic literal `"Audio CD"` regardless of what's actually on the disc (unlike a DVD's real volume label), leaving the new listing showing `[Audio CD]` for every audio disc - no help distinguishing them.
- New `Get-QuickDiscIdentity`: runs `cyanrip -I` (discovery only, no rip) as a real `System.Diagnostics.Process` (not the `&` operator, specifically so it can be killed) with a 5-second hard timeout. Async output reads (`ReadToEndAsync`) are started *before* `WaitForExit`, not after - otherwise a chatty child can deadlock on a full pipe buffer with nothing draining it. On success, parses `Album:`/`Album artist:` and returns `"Artist - Album"` (or just the album); on timeout it kills the process and returns `$null`; any other failure also returns `$null`.
- `Write-DriveListLine` only calls the lookup when the label is exactly the generic `"Audio CD"` (a real DVD label is already useful - skip the cost) and only when the drive is **not** busy (never query a drive mid-rip). A `$null` result falls straight back to the pre-change `Audio CD` display.
- Verified against real hardware: run against `D:` (confirmed non-busy) completed in 920ms and correctly returned `$null` for a disc with no MusicBrainz match - a genuine miss, not a mock. Timeout-and-kill path separately verified in isolation against a deliberately slow dummy process (30s sleep, 2s timeout): fired at the configured bound (~2045ms), `HasExited` confirmed `$true` after `Kill()` - the child is actually terminated, not just abandoned. All testing deliberately kept off the live `H:` rip and its drive/output paths.
- Risk assessed as low and strictly additive: every failure mode (no cyanrip on PATH, timeout, no match, unparseable output, any exception) returns `$null` and restores the exact pre-change listing output; the busy-drive guard means an in-progress rip is never queried.

**Process note - self-approval (recurring, expected):** `gh pr review --approve` cannot succeed on this repo for the same reason noted in the 2026-08-17 entry - GitHub rejects self-approval since the user authors all PRs under the same account. All six PRs this session were merged with zero formal approvals; expected, not an error.

**Files changed across this arc:** `rip-audio.ps1`, `CLAUDE.md` (PR #128), `CHANGELOG.md` (all six PRs, progressively)

**Live rip state at session close (informational, not touched):** two `cyanrip` processes were running concurrently throughout much of this session's later PRs and remained running at close: `H:` ripping "Gold Disc 1" by John Denver (started 18:30, the rip referenced throughout #130-#132's testing notes as the reason live end-to-end validation was avoided), and a second, separate rip started later on `D:` for "Gold Disc 2" by John Denver (started 18:55). Neither was interacted with. See session handoff for current status - check both before assuming either has finished.

**UNRESOLVED - needs a human decision, carried from earlier tonight, NOT part of PRs #127-#132:**
`search-metadata.ps1 -Path "C:\Music\Dylan Thomas\Under Milk Wood"` (the exact command flagged as pending in the 2026-08-17 entry above) was run for real earlier this session and applied **wrong** metadata. The only source that returned a match (Deezer) matched a "Part 2 only" release to a folder containing the whole work. Files were renamed (`Parts 1 & 2.flac` -> `01 - Part 1.flac`, `Part 3.flac` -> `02 - Part 2.flac`, titles now misdescribe the audio), ARTIST narrowed from "Richard Burton / Dylan Thomas" to just "Dylan Thomas" (lost the narrator), DATE changed 1998->1954, GENRE dropped. Root cause: the 30-second confirmation prompt is broken under redirected stdin - `[Console]::KeyAvailable` throws repeatedly, then falls through to auto-yes on timeout - so this was never actually confirmed by a human; it silently auto-applied. This is a **new, undocumented defect** in `search-metadata.ps1`'s confirmation prompt, separate from anything fixed in PRs #127-#132, and has not yet been triaged into a PR. The user has been given options (undo via `undo-metadata.ps1 -LogFile "C:\Music\logs\search-metadata_20260826_155636.log"`, keep art but fix manually, leave it, or fix the prompt bug) and has **not yet decided**. Do not undo or otherwise resolve this without explicit user direction - real data is sitting wrong on disk right now.

**Session Verified Clean:**
- All six PRs (#127-#132) merged to `master`, feature branches deleted locally and remotely
- Two additional stale branches (`feature/shareable`, `fix/restore-siteground-art`) resolved and deleted via #129
- Working tree clean, no uncommitted changes, no unpushed commits, no open PRs, no stash entries
- `CHANGELOG.md` has entries for all six PRs, written progressively through the session

**Priority for Next Session:**
1. **Dylan Thomas metadata decision (see UNRESOLVED above) - top priority, real data at risk.** Get a decision from the user before touching `C:\Music\Dylan Thomas\Under Milk Wood` further.
2. Fix the actual root cause behind the Dylan Thomas incident: `[Console]::KeyAvailable`-based confirmation prompt throws under redirected stdin and silently falls through to auto-yes. This is a correctness bug independent of whatever the user decides about the Dylan Thomas data itself, and will silently auto-apply the next mismatch too if left unfixed.
3. Live end-to-end validation of #130/#131/#132 was avoided throughout because `H:` (and later `D:`) had real rips in progress all session - once both are free, exercise busy-drive blocking and the quick-identity lookup against a real concurrent-rip attempt.
4. Everything carried from the 2026-08-17 entry not superseded above: force a real metaflac failure to confirm the warning path fires; confirm the `search-metadata.ps1` handoff now runs automatically after a spaced-path rip.
4. Decide the fate of `feature/shareable` vs `fix/restore-siteground-art` — pick a direction, rebase, merge or close.
5. PSGallery publish still pending — get API key from powershellgallery.com and run `Publish-Module`. (May be partly resolved by the `feature/shareable` decision above.)

---

### 2026-08-26 (pt 2) - Discogs Metadata Source and Mp3tag Automation (PRs #135, #136)

**Context carried in:** PR #134 (`fix/redirected-console-input-prompts`, commit `7c38191`) landed between the previous entry and this one, closing priority #2 from the entry above — all 9 confirmation-prompt sites across the 4 scripts now handle `[Console]::KeyAvailable` throwing under redirected stdin instead of spinning for the full timeout or (in `undo-metadata.ps1`'s case) silently treating an unreadable prompt as consent. It has a full `CHANGELOG.md` entry but, unlike #127-#132, was not given its own `CLAUDE.md` session-notes entry before this one — noting that gap here rather than backfilling it retroactively. The Dylan Thomas `Under Milk Wood` mis-tag from the entry above is **still unresolved** — that's a data decision, not a code bug, and #134 fixed the root cause without touching the already-wrong files on disk. Nothing in this entry's two PRs touches that either; see Priority for Next Session below.

**Motivation for both PRs (unprompted by a bug this time — a direct user request):** "I find I often use Discogs as a tag source... if there is any way to incorporate that... even after the fact." Two separate asks bundled into that one sentence: use Discogs as an automated source in `search-metadata.ps1` (#135), and when automation fails entirely, make the existing Mp3tag manual fallback also kick off the user's own habitual Discogs lookup instead of leaving them to click through the menu themselves (#136).

**PR #135 (`80d17b7`) - `feature/discogs-metadata-source`:**
- New `Search-Discogs` function added to `search-metadata.ps1` as a 4th metadata source alongside MusicBrainz, iTunes, and Deezer: queries Discogs's `/database/search` by artist + release title.
- **CD-format preference:** Discogs commonly returns cassette, vinyl, and box-set editions alongside CD ones for the same title/artist search — this whole toolkit rips CDs, so non-CD-format candidates are deprioritised when CD-format ones are present in the result set.
- **Track-count verification, not just format filtering:** Discogs's search endpoint doesn't expose track count directly (unlike the other three sources), so up to 3 candidates get a follow-up `/releases/{id}` detail fetch specifically to check it. This is the deliberate safety mechanism, directly motivated by the still-open Dylan Thomas incident from the entry above: a Discogs match is only trusted/preferred over the existing MusicBrainz > Deezer > iTunes chain when its track count actually equals the local rip's file count. A mismatch demotes it below MusicBrainz rather than being trusted outright — that's exactly the failure pattern (title/artist matched, track count silently didn't) that mismatched a "Part 2 only" Deezer release to the complete Dylan Thomas recording earlier in the same overall session. Discogs still appears in `Show-MetadataComparison`'s "Sources found" list either way, for visibility, even when demoted.
- **Requires a free `DISCOGS_TOKEN` environment variable** (Personal Access Token from discogs.com/settings/developers). When unset, `Search-Discogs` is silently skipped and every other script behaves exactly as before — fully backward compatible, no error, no warning. The user was walked through the token-generation steps this session but **explicit confirmation that the command to actually set it was run was never given** — see UNRESOLVED below, this was re-verified directly at session close and the token is confirmed not set.
- Wired into `Search-AllSources`'s merge priority for every field (artist, album, date, genre, track count, track titles, artwork) and into `Show-MetadataComparison`'s source list. `-EmbedOnly` mode picks it up for free since it already calls `Search-AllSources` — no separate wiring needed.
- **Validated against the real, live Discogs API** — unauthenticated (no token was available this session to test with the real header, but the API also works unauthenticated, just at a lower rate limit, which was sufficient for testing): searched "How to Dismantle an Atomic Bomb" by U2, correctly filtered 5 raw results down to 3 CD-format candidates (2 cassette editions correctly excluded), and found the exact 11-track match with real song titles ("Vertigo", "Miracle Drug", etc.), genre, year, and artwork. Separately verified the mismatch-fallback path by forcing an impossible track count (99) — correctly exhausted all 3 candidate fetches and fell back cleanly rather than erroring or false-matching.
- **Not yet exercised:** with a real `DISCOGS_TOKEN` set (none was available), or through the actual interactive `search-metadata.ps1` confirmation flow end-to-end against a real folder. The underlying search/filter/merge logic is verified against live data; the surrounding script wiring is not yet run for real.
- README.md updated: setup instructions, workflow steps, and all "4 sources" mentions. CHANGELOG.md entry added.

**PR #136 (`1cf489b`) - `feature/mp3tag-discogs-automation`:**
- Extends `rip-audio.ps1`'s existing "everything else failed, open Mp3tag for manual tagging" fallback to also auto-trigger the user's own stated habitual manual workflow: select all tracks, open the Tag Sources menu, choose "Discogs Artist + Album".
- **Investigated first, not assumed:** confirmed via grepping the actual installed Mp3tag version's (3.32) full command-line changelog history (back to 2012) that there is genuinely no CLI switch for triggering a Tag Source — command-line support only ever covers loading files/folders on startup. GUI automation was the only option.
- New `Invoke-Mp3tagDiscogsLookup`, called immediately after the existing `Start-Process $mp3tagPath` launch, uses real `System.Windows.Automation` (UI Automation) + `SendKeys` to drive the actual GUI:
  1. Finds the Mp3tag window by polling window title (not by the just-launched PID) — Mp3tag is single-instance and can hand off to a different, pre-existing process than the one `Start-Process` just spawned; confirmed live that this handoff actually happens.
  2. Works around Windows' anti-focus-stealing protection blocking `SetForegroundWindow` from a background process — reproduced live during testing, worked around with the standard `AttachThreadInput` technique.
  3. Sends Ctrl+A (select all loaded tracks), Alt+S (open Tag Sources menu via its keyboard mnemonic), then 4x Down + Enter to reach "Discogs Artist + Album" — the 5th item in the menu, its position confirmed by taking real screenshots of the actual live menu on this installation, not guessed or inferred from documentation.
  4. Deliberately stops at the resulting pre-filled "Search by" dialog (Artist/Album pulled from the loaded tags) rather than auto-clicking "Next >" — the user specifically wants to review/correct the album name before the real Discogs query goes out, matching their stated manual habit exactly.
- **Fully best-effort, never blocking:** every failure path (assemblies won't load, window doesn't appear within 15s, foreground can't be acquired) logs via `Write-Log` and returns without throwing. A failure here can only ever fall back to exactly the pre-existing "Mp3tag opens, user drives it manually" behaviour — this can add convenience but can never break or block the existing fallback.
- **Explicitly documented fragility, not a hidden gap:** the menu item can only be found by position (`$mp3tagDiscogsMenuPosition = 4`), not by name, because Mp3tag's Tag Sources menu is not exposed via standard Windows accessibility APIs at all — confirmed live via multiple failed UIA detection attempts (no `MenuBar` control type found, no UIA-visible popup even while the menu was genuinely open on screen at the time). If the user ever reorders, adds, or removes a Tag Source above this one in Mp3tag's own settings, the automation will silently open the wrong search with no way to detect the mismatch programmatically. Called out directly in a code comment next to the position constant, not buried.
- **Verified end-to-end against the real, actually-installed Mp3tag (v3.32), twice, from a genuine cold start each time** (no pre-existing window) — against two different real ripped folders (John Denver "Gold Disc 1" and "Gold Disc 2", the same two live rips referenced as in-progress at the close of the #127-#132 entry above, by which point both had finished). Both runs correctly landed on the pre-filled Discogs Artist+Album search dialog with the right Artist/Album values, in ~0.5s window-detection time each. Done by extracting the real function logic into a standalone test script matching the actual call site exactly — not a simulation of the logic. Deliberately not exercised: clicking past "Next >" into live search results (that's the intended human-review stopping point by design, not a gap).
- **Follow-ups suggested during merge review, not acted on this session** — carrying forward as low-priority polish, not urgent: making the menu position configurable rather than hardcoded; adding a post-Enter sanity check on the resulting dialog title/contents to catch a wrong-position landing if the menu is ever reordered; running a real end-to-end pass through the actual integrated call site inside `rip-audio.ps1` itself (the verification above used an extracted standalone test script matching the call site, not the live integrated path).
- README.md and CHANGELOG.md updated.

**Process note - self-approval (recurring, expected):** both PRs merged with zero formal approvals, same as every PR this session and the one before it — `gh pr review --approve` cannot succeed on this repo since GitHub rejects self-approval and the user authors all PRs under the same account.

**Files changed across this arc:** `search-metadata.ps1` (#135), `rip-audio.ps1` (#136), `README.md` (both), `CHANGELOG.md` (both)

**UNRESOLVED - needs a decision/action next time:** `DISCOGS_TOKEN` is **not set** on this machine — checked directly at session close via `[Environment]::GetEnvironmentVariable("DISCOGS_TOKEN","User")` (and also `"Machine"` scope and the current process's `$env:DISCOGS_TOKEN`): all three came back unset. The user was walked through generating a token at discogs.com/settings/developers during the session, but there is no record here of the corresponding `setx`/profile-edit command actually having been run. **Without it, PR #135's entire Discogs integration silently does nothing on every real run** — `Search-Discogs` just returns nothing and the script behaves exactly as it did before #135, with no error or warning to say why. This is the top open item for next session: either confirm the token was set outside this session's visibility, or walk through setting it again.

**Session Verified Clean:**
- Both PRs (#135, #136) merged to `master`, feature branches deleted locally and remotely (confirmed via `git branch -a` — only `master` and its remote-tracking ref remain)
- Working tree clean, no uncommitted changes, no unpushed commits, no open PRs, no stash entries
- No stray `Mp3tag` or `cyanrip` processes running (both live rips referenced in the #127-#132 entry above have since finished)
- `CHANGELOG.md` has full entries for both PRs (plus #134's fix, merged in between)

**Priority for Next Session:**
1. **Resolve the `DISCOGS_TOKEN` gap (see UNRESOLVED above)** — confirm or set it; otherwise #135 is dead code in practice.
2. **Dylan Thomas metadata decision — still carried forward, unresolved, real data at risk.** See the #127-#132 entry above for full detail (`undo-metadata.ps1 -LogFile "C:\Music\logs\search-metadata_20260826_155636.log"` is the prepared undo path). #134 fixed the root-cause prompt bug but did not touch the already-wrong files on disk. Do not resolve without explicit user direction.
3. Run `search-metadata.ps1` for real (ideally with `DISCOGS_TOKEN` set) against a live folder to exercise #135's full interactive confirmation flow end-to-end — validated so far against the live API directly and via the mismatch-fallback path, not through the actual script's prompts.
4. Run a real end-to-end pass of #136 through the actual integrated call site in `rip-audio.ps1` (a real failed-automation rip that falls through to the Mp3tag fallback), rather than the extracted standalone test script used for verification this session.
5. Consider the merge-review follow-ups noted under #136: configurable menu position, post-Enter sanity check on the landed dialog.
6. PSGallery publish still pending — get API key from powershellgallery.com and run `Publish-Module`. (Note: the #127-#132 entry's priority list also carried forward a "decide the fate of `feature/shareable` vs `fix/restore-siteground-art`" item, but that was already resolved by PR #129 within that same entry and both branches are confirmed gone via `git branch -a` — that item was stale leftover text in that entry's own list, not a real open task.)

---

### 2026-08-29 - Output Drive Prompt and Readiness Validation (PR #138)

**Trigger:** user reported `rip-audio.ps1` silently defaulting the output drive to
`C:` with no confirmation or readiness check, only surfacing a bad/disconnected
output drive deep into Step 1 — after disc discovery, multiple-release selection,
and MusicBrainz lookup had already been answered.

**PR #138 (`a08a361`) - `feature/output-drive-prompt-and-validation`:**
- When `-OutputDrive` isn't passed, the script now prompts interactively (Enter
  accepts the system-drive default) instead of silently defaulting.
- The resulting drive (from the arg, the prompt, or the default) is validated via
  the existing `Test-DriveReady` helper *before* proceeding into disc metadata
  discovery, not after. An unready drive triggers a re-prompt loop until a valid
  one is given (or Ctrl+C).
- `-Queue` and `-ProcessQueue` keep the old silent system-drive default — both are
  unattended/batch paths, and output drive is resolved once for the whole run, so
  prompting there would be pure friction with no per-item benefit.
- README.md's `-OutputDrive` parameter row updated to match.

**Testing status:** verified by PowerShell tokenizer parse-check only. No disc was
ripped; the interactive prompt, the re-prompt loop, and the `-Queue`/`-ProcessQueue`
`exit 1` path have not been exercised against real hardware or a real not-ready drive.

**Also discovered (not part of this PR):** a stray uncommitted change surfaced in
the working tree mid-workflow — MusicBrainz connectivity-retry logging around line
1786, unrelated to the output-drive work. It was not authored by this session; a
separate concurrent Claude Code session on this machine picked it up independently
and branched, committed, pushed, and opened **PR #139**
(`fix/musicbrainz-connectivity-diagnostics`). That session merged it itself before
this entry was committed — merge commit `0fec912`, feature branch deleted. Not
evaluated by this session; noted here only because it briefly showed up as loose
working-tree state during this session's own git workflow.

**Process note - self-approval (recurring, expected):** `gh pr review --approve`
rejected as usual; sign-off posted as a PR comment instead, then squash-merged.

**Session Verified Clean:**
- PR #138 squash-merged to master, feature branch deleted locally and remotely
- PR #139 (separate concurrent session's work) also merged, `0fec912` — both are
  on master as of this entry
- Working tree clean, no uncommitted changes, no unpushed commits, no open PRs

**Priority for Next Session:**
1. Live end-to-end validation of PR #138: run `rip-audio.ps1` with no `-OutputDrive`
   arg and confirm the prompt appears, and separately test against a genuinely
   not-ready/disconnected drive letter to confirm the re-prompt loop and the
   `-Queue`/`-ProcessQueue exit 1` path both behave as designed.
2. Live validation of PR #139's diagnostics (a different session's work, noted here
   for continuity): force a real MusicBrainz connectivity failure and confirm the
   `Reason:` text renders and logs as intended — not yet observed live per that PR.
3. Everything still carried forward and unresolved from 2026-08-26: the
   `DISCOGS_TOKEN` gap (PR #135 is dead code without it), and the Dylan Thomas
   `Under Milk Wood` metadata decision (real data still sitting wrong on disk;
   do not resolve without explicit user direction).

---

### 2026-08-29 (pt 3) - Session Close: MusicBrainz Diagnostics Verified, DISCOGS_TOKEN Set, Dylan Thomas Deferred

**PR #139 live-verified (closes priority #2 above):** the `Reason:` line added by
PR #139's exception-surfacing fix was confirmed live against a real DNS failure
(a non-resolving subdomain) — it renders as expected. `git-manager` also found
this fix's original premise was partly wrong: 2 of the 3 catch-block fixes had
already been swept, undocumented, into PR #138 (the output-drive validation
work). Rather than rewriting history, this was documented via the `CHANGELOG.md`
note under the 2026-08-29 Fixed section (see the "Note:" line there) — no
further CLAUDE.md rewrite needed on top of that.

**`DISCOGS_TOKEN` gap closed (closes priority #3's first item, and the
UNRESOLVED item from 2026-08-26 pt 2):** set as a durable **user-level**
environment variable via `setx` (persists across sessions/reboots, unlike the
process-scope `$env:` check that came back empty in every prior check). PR
#135's Discogs metadata source — merged since PR #135 but silently a no-op
without this — is now live. Not yet exercised through a real interactive
`search-metadata.ps1` run with the token actually set; that's still open, see
below.

**Dylan Thomas `Under Milk Wood` — explicit decision this session: leave as
is, decide later.** This was raised again this session; the user was given the
same three options as before (restore-and-fix, abandon-and-re-rip, leave-as-is)
and **explicitly chose leave-as-is / decide later** — this is an active choice
made this session, not just the same unresolved item going stale since
2026-08-26. The mis-tagged files remain in the Windows Recycle Bin under wrong
filenames/tags; the prepared undo path
(`undo-metadata.ps1 -LogFile "C:\Music\logs\search-metadata_20260826_155636.log"`)
is unchanged and still available whenever the user does want to act. Do not
reopen this as urgent without the user raising it again.

**Observed at close, not part of this thread's own work — PR #141 already on
`master`:** `fix(rip): catch rips corrupted by a flaky drive/USB connection`
(commit `2f5b995`) — TOC track-count sanity check shown pre-rip, and post-rip
integrity checks (`Test-TrackIntegrity`) now also gate the Step 1/Step 2
"COMPLETE!" result, not just file size. `CHANGELOG.md`'s 2026-08-29 Added
section attributes it to "two real interrupted rips pasted by the user this
session" — i.e. it's part of the same overall user session via a different
concurrent thread, same as PR #138/#139 above. Not evaluated here; flagging
for continuity same as prior entries have done for each other's concurrent
work. No CLAUDE.md session-notes entry exists for it yet beyond this note.

**Session Verified Clean:**
- `master` clean, no uncommitted changes, no unpushed commits, no open PRs
  (`gh pr list --state open` empty)
- Local branches: only `master`, matching `origin/master`
- Commit history at close: `...a08a361` (#138) → `0fec912` (#139) →
  `3c2ce93` (docs) → `2f5b995` (#141)

**Priority for Next Session:**
1. Live end-to-end validation of PR #138's output-drive prompt/readiness loop
   against real hardware — still not exercised (carried forward, unchanged).
2. Run `search-metadata.ps1` for real with `DISCOGS_TOKEN` now set, against a
   live folder, to exercise PR #135's full interactive confirmation flow
   end-to-end.
3. PR #141 (flaky drive/USB corruption detection) has no live-hardware
   validation recorded anywhere yet — confirm `Tracks detected: N` banner and
   the `Test-TrackIntegrity` post-rip gate against a real interrupted rip.
4. Dylan Thomas data stays exactly as is until the user raises it again — see
   above, do not treat as urgent.
5. PSGallery publish still pending — get API key from powershellgallery.com
   and run `Publish-Module`.

---

### 2026-08-29 (later) - continue-rip-audio.ps1: Dedicated Resume Script

**Trigger:** user asked for a dedicated resume script "a bit like `continue-rip.ps1`
in `/ripdisc`" - a follow-up to the same-day flaky-USB session (PR #141/#142).
Confirmed the design approach with the user first (dedicated script vs. a
`-FromStep` flag on `rip-audio.ps1` itself) - dedicated script was chosen, for
parity with `ripdisc`'s pattern, despite the known double-maintenance cost that
pattern has repeatedly caused in `ripdisc`'s own session history.

**New file: `continue-rip-audio.ps1`** - step-based resume (`1`/`rip`, `2`/`verify`,
`3`/`coverart`, `4`/`open`), `-FromStep`, per-step prerequisite checks, a
retry-hint suggestion on failure, close-button protection, and the coffee badge -
same shape as `ripdisc`'s `continue-rip.ps1`.

**Structural difference from `ripdisc`'s version, called out directly in the
script's own header comment:** `ripdisc`'s Step 1 (MakeMKV) genuinely cannot be
resumed without the disc, so its continue script never touches Step 1 at all.
Here, Step 1 (cyanrip) *can* be partially resumed - cyanrip's own `-l` flag rips
just a list of missing track numbers - so this script's "rip" step is marked
`Resumable = $true` and still needs the disc back in the drive, unlike
`ripdisc`'s equivalent which needs no disc at all.

**What got ported (largely verbatim, to minimize divergence risk):**
`Test-TrackIntegrity`, `Get-DiscTrackCount`, `Test-DriveReady`, `Write-Log`,
`Show-QuestionHint`, `Write-Timestamp`, `Show-CoffeeBadge`,
`Start-CyanripWithErrorDetection`, the close-button-protection block, and the
full Step 2 (verify) / Step 3 (cover art, all 4 sources) / Step 4 (open) bodies
from `rip-audio.ps1`. The output-drive prompt-then-validate pattern from PR #138
is reused as-is.

**Deliberately NOT ported** (documented in the script header and README, not a
silent gap): multi-release MusicBrainz disambiguation, CDDB/Discogs fallback,
generic-name fallback, `-Queue`/`-ProcessQueue`, `-RequireMusicBrainz`,
AccurateRip reporting, the `search-metadata.ps1` handoff, the Mp3tag fallback
prompt, and `rip-audio.ps1`'s live busy-drive process scan (this script's drive
selection is a plain "which drive" prompt with a single readiness check). All of
these only matter for discovering metadata on a fresh disc read, not for
continuing an album this script already knows the identity of from its existing
output folder. Also not handled: `rip-audio.ps1`'s duplicate-version-suffix
naming (`Album (Limited Edition)`) - if the original rip landed in a suffixed
folder, this script's plain `-Album`/`-Artist` path won't find it.

**Bug caught and fixed before commit:** the first draft called
`Complete-CurrentStep` twice for Step 1 in the "all tracks already valid, nothing
to rip" path - once inside that branch, once more in Step 1's unconditional tail
- which would have double-added step 1 to `$script:CompletedSteps` and printed
it twice in the steps summary. Fixed by replacing the early call with a plain
`$skipCyanripInvocation` flag read by the tail's cyanrip-invocation guard, so
`Complete-CurrentStep` fires exactly once per step on every path.

**Files changed:** `continue-rip-audio.ps1` (new), `README.md` (new
`continue-rip-audio.ps1` section), `CLAUDE.md` (project structure list, this
entry), `CHANGELOG.md`.

**Testing status:** verified by `PSParser::Tokenize` (0 errors) and a manual
ASCII-only check on the new file - same as this session's other changes. **Not
exercised against a real disc or a real interrupted rip at any step.** The ported
functions (`Test-TrackIntegrity`, `Get-DiscTrackCount`,
`Start-CyanripWithErrorDetection`, the cover art chain) have prior live
validation from their original use in `rip-audio.ps1`, but their behavior in
this new script's control flow - the resume-track-list computation, the
step-skip logic, the prerequisite checks - is unvalidated.

**Session Verified Clean:** working tree change staged for commit via the
project's standard git-manager workflow (branch, PR, sign-off comment in place
of self-approval, squash-merge) - not yet merged as of writing this entry.

**Priority for Next Session:**
1. Live end-to-end test of `continue-rip-audio.ps1`: interrupt a real rip
   (or reuse one of this session's own interrupted discs), then run
   `-FromStep rip` and confirm it resumes only the missing tracks.
2. Test `-FromStep coverart`/`-FromStep verify`/`-FromStep open` against an
   already-fully-ripped album to confirm the prerequisite checks and step-skip
   logic behave as designed.
3. Consider whether the duplicate-version-suffix gap (noted above) is worth
   closing, if it turns out to matter in practice.
4. Everything carried from the prior entry (output-drive prompt validation,
   PR #135 Discogs flow, PR #141's flaky-drive detection) still stands - none
   of it touched by this addition.

**Addendum (added before PR #143 merged, same day):** the script picked up an
explicit `-FromTrack <N>` override on its rip step, and its two "kept in sync"
helpers were re-synced with `rip-audio.ps1` after PRs #145/#147 landed on master
while this branch was open. `-FromTrack` skips the automatic missing-track file
scan and rips track N to the disc's real last track, re-querying the track count
live (`-Fresh`) rather than trusting a cue file the same flaky connection may have
corrupted; a mismatch against what's on disk warns but never blocks. Critically,
this script's `Test-TrackIntegrity` carried the **exact same `metaflac --test`
bug** fixed on master in PR #147 - a nonexistent option that classified every
FLAC as corrupt - and would have shipped broken had the branch merged as
originally written; it went uncaught here precisely because of the "not exercised
against a real interrupted rip" gap noted above. A second bug was caught during
validation: PowerShell ranges descend, so `1..0` yields `@(1, 0)`, meaning
`-FromTrack 1` would have warned about "missing" tracks 1 and 0 on a valid
whole-disc invocation. `Test-CyanripCrashExit` and master's broadened resume loop
were deliberately **not** ported - so this script still won't auto-resume a native
cyanrip crash the way `rip-audio.ps1` now does. That remains the top follow-up,
alongside the live-disc testing already listed above.

---

### 2026-08-29 (pt 4) - Session Close: PRs #144/#145/#147 (Drive List, Crash Resume, FLAC Test Fix); PR #143 Open

**PR #144 merged (`f2e9177`) - `fix(rip): show all optical drives when -Drive is
passed explicitly`:** user-reported bug with a real repro command in the PR body.
An explicit `-Drive` printed only the single matched drive, unlike its sibling
error-path branches in the same if/elseif chain (busy drive, drive not found) and
unlike ripdisc's convention (established for PR #130) of always showing the full
detected-drive list with a `<--`/`-Selected` marker. Now loops over
`$opticalDrives` via `Write-DriveListLine` for every branch alike. Display-only,
no selection/validation logic touched. **Not hardware-validated** - the user has
not yet re-run their repro command to confirm all 3 of their real drives (D:, G:,
H:) now list correctly.

**PR #145 merged (`856553f`) - `fix(rip): auto-resume cyanrip crashes and
re-query track count fresh`:** two-part fix for a real incident this session - a
cyanrip crash (Windows access violation, exit `-1073741819`) on "Destination
Anywhere" by Jon Bon Jovi after track 8, silently accepted as a finished 8-track
rip.
1. New `Test-CyanripCrashExit` helper (`$ExitCode -le -1000000`) widens the
   resume-loop trigger, which previously fired only on `$result.Killed` (the
   script's own deliberate watchdog-kill after repeated cdio errors) - a native
   process crash never set that flag, so the existing skip-bad-track-and-resume
   logic was unreachable for this whole failure class.
2. The resume loop now calls `Get-DiscTrackCount -Fresh` to re-query the disc
   live via `cyanrip -I` instead of trusting the crashed run's own
   self-reported "Disc tracks: N" line, which can itself be corrupted by the
   same flaky connection that caused the crash (in the real incident: disc has
   ~12-14 tracks, crashed run self-reported a plausible-looking 9).

   Related, **not acted on**: PR #141 (landed from a separate concurrent session
   this session, already checked for conflicts - none found) has its own pre-rip
   `$discMeta.TrackCount` that overlaps in spirit with this fresh-query fix but
   isn't cross-checked against it - flagged as a possible follow-up, not done.

   **Not hardware-validated** - no real crash was reproduced end-to-end through
   the fixed resume loop; verified only by unit-testing `Test-CyanripCrashExit`
   in isolation across 5 exit codes and by parser/parse-check.

**PR #147 merged (`68d09d3`) - `fix(rip): use flac --test, not the nonexistent
metaflac --test`:** root-caused why a clean, verified-good rip ("Welcome to
Jamrock" by Damian Marley, all 15 tracks, cyanrip itself reported "Ripping
errors: 0", user confirmed files play fine) hard-failed with "15 corrupt/zero-byte
file(s)". `Test-TrackIntegrity`'s FLAC branch called `metaflac --test`, which is
not a real metaflac option (metaflac only edits/reads metadata, never decodes
audio) - verified live against the installed FLAC 1.5.0 that it always prints
"unrecognized option" and exits 1, for every file, valid or not, so the function
returned `$false` unconditionally. Fixed to call `flac --test --totally-silent`
instead, probing for `flac` via `Get-Command` rather than `metaflac` - verified
live that it passes real good files and correctly fails a deliberately truncated
test file. Also fixed two stale `metaflac --test` doc references in README.md and
Roadmap.md. Deliberately did **not** correct a third stale mention still sitting
in CHANGELOG.md's existing 2026-08-29 entry for PR #141 (~line 44) - left in
place as historical record per convention, with the new CHANGELOG entry noted as
superseding it.

The user was offered the chance to re-run the Damian Marley album through the
now-fixed script to let it complete Steps 2-4 (verify/cover art/open), and
**explicitly chose to leave the album as-is** - files are already correct and
playable on disk at `F:\Music\Damian Marley\Welcome to Jamrock`; only the
script's own bookkeeping/completion steps never ran. This was an active,
informed choice this session, not an oversight.

**Also merged this session, not evaluated as part of this close-out's own
work:** PR #146 (`68c257d`) - `feat(rip): add -CheckEbayPrice switch for eBay UK
sold-listings URL`, an opt-in convenience switch (off by default) that prints a
clickable eBay UK sold-listings search URL in the FILE SUMMARY via a new
`Get-EbaySoldListingsUrl` helper. Noted here for continuity only.

**PR #143 open (`feature/continue-rip-audio`, opened 2026-08-29 07:40) - NOT
touched or resolved this session:** adds a 979-line step-based resume script
(`continue-rip-audio.ps1`) for interrupted rips. Conceptually overlaps with what
#145 and #147 just changed (crash/resume handling, track-count trustworthiness)
and may need a rebase or reconsideration before merge. It is the only open PR on
the repo right now - left open and unresolved deliberately, per instruction, but
flagged here so it stays visible.

**Session Verified Clean:**
- `master` at `68d09d3`, up to date with `origin/master`, working tree clean
- No uncommitted changes, no unpushed commits, no stashes
- Local branches: `master` (current) and `feature/continue-rip-audio` (tracks
  `origin/feature/continue-rip-audio`, backing PR #143 - intentionally left
  alone, do not delete)
- `gh pr list --state open`: only #143

**Priority for Next Session:**
1. Hardware-validate PR #144: re-run the user's repro command with an explicit
   `-Drive` and confirm all 3 real drives (D:, G:, H:) list with the selected
   one marked.
2. Hardware-validate PR #145: reproduce (or wait for) a real cyanrip crash and
   confirm `Test-CyanripCrashExit` triggers the resume loop and
   `Get-DiscTrackCount -Fresh` returns an accurate live count.
3. Decide what to do with PR #143 - review it for overlap/conflict with #145's
   and #147's just-landed changes before merging, rebasing, or closing it.
4. Consider the flagged-not-done follow-up: cross-check PR #141's pre-rip
   `$discMeta.TrackCount` against PR #145's `-Fresh` re-query fix.
5. Carried forward unchanged from earlier this session (pt 3): live validation
   of PR #138's output-drive prompt against real hardware; exercise
   `DISCOGS_TOKEN` (now set) through a real interactive `search-metadata.ps1`
   run; Dylan Thomas `Under Milk Wood` stays exactly as is until the user raises
   it again; PSGallery publish still pending.

---

### 2026-08-29 (later) - MusicBrainz Retry Backoff

**Trigger:** live pattern this session - the pre-rip MusicBrainz connectivity
check failed with `503 Server Unavailable` across several separate rip
attempts, and each `[R]` Retry sent the exact same request again instantly.
User: "ps api still failing".

**Change:** both pre-flight connectivity-check retry loops now back off before
each successive retry - 5s, 10s, then 15s (capped) - instead of re-hitting the
API with no gap. Each attempt is numbered in the log line, so a genuinely
sustained outage across multiple rips is now visible after the fact instead of
every failure looking identical in the log.

**Deliberately scoped narrowly:** only the two connectivity-*check* retry
loops (`-RequireMusicBrainz` path and the normal `[R]/[C]/[Q]` path) got the
backoff. The separate, heavier retry loop further down - where cyanrip itself
reports `MusicBrainz query failed`/`Connection failed` mid-rip and retry
re-invokes cyanrip entirely - was not touched, since it wasn't the path hit in
the observed failures and re-running cyanrip is a much bigger operation to
add an automatic delay in front of without more thought.

**What this does NOT do:** it does not make MusicBrainz come back up. If
today's repeated 503s are a genuine sustained outage or a rate limit tied to
this machine/User-Agent, backing off the client's own retry timing won't fix
that - it only stops the client from hammering an already-struggling service
while waiting it out. See the backlog item raised alongside this fix for the
question of whether the repeated failures are worth investigating further.

**Files changed:** `rip-audio.ps1`, `README.md`, `CHANGELOG.md`, `CLAUDE.md`
(this entry)

**Testing status:** parse-checked only (PowerShell tokenizer, 0 errors),
added lines confirmed ASCII-only. Not exercised against a real, live
MusicBrainz outage - the backoff timing has not been observed actually
resolving a real 503 faster than instant retries would have.

**Process note:** this PR/commit was pushed directly via `gh`/`git` from this
session rather than through the `git-manager` subagent - the subagent hit the
account's monthly spend limit mid-task on the immediately preceding ripdisc
PR and failed before committing. The same branch/commit/PR/sign-off-comment/
squash-merge workflow was followed manually to keep parity with how every
other change this session was shipped.

**Priority for Next Session:**
1. Watch whether MusicBrainz 503s keep recurring across future sessions - if
   so, this is worth escalating past a client-side timing tweak (see the
   backlog item).
2. Consider whether the heavier cyanrip-mid-rip retry loop (deliberately not
   touched here) would benefit from the same backoff treatment if it turns
   out to hit the same rate-limit/outage pattern in practice.
3. `git-manager`/subagent spend-limit exhaustion is itself worth noting for
   whoever plans future sessions' agent usage - it stopped one task cleanly
   (nothing lost, staged changes were recovered and committed manually) but
   is a real constraint hit mid-session, not a one-off.

---

### 2026-08-29 (later still) - Opt-In Shared-Folder Multi-Disc Mode

**Trigger:** live incident, direct follow-up to the MusicBrainz backoff work.
Ripping a 2-CD "Eagles - The Complete Greatest Hits" set, MusicBrainz's
multi-release disambiguation worked (`(2 CDs)` releases correctly listed and
selected) but the follow-up detail query hit a 503, so disc-number
auto-detection never got the chance to run. The user had to hand-type "The
Complete Greatest Hits CD 1" as the album name purely to avoid disc 2
colliding with disc 1's track filenames - not the folder layout they
actually wanted ("i didnt want to name it cd 1 here but saw no other
choice").

**Design confirmed with the user before building:** two options were
presented - a new opt-in `-DiscNum` parameter (shared folder only when
explicitly requested, every existing single-disc and auto-detected
multi-disc behaviour unchanged), or replacing the default multi-disc
behaviour entirely. User chose the opt-in parameter, explicitly because it
doesn't risk breaking `search-metadata.ps1`'s existing one-folder-per-disc
assumption for anyone not using the new flag.

**Implementation - `-DiscNum <1-99>`:**
- Skips the existing "Disc N" folder-suffix auto-append entirely when passed
  - both discs share one `-album`/`-artist` folder.
- New prefix-rename pass, inserted **after** cyanrip's entire rip/title-
  rename/tag/eject sequence completes (not interleaved with it, to avoid any
  risk of the existing title-rename/tagging logic misreading a
  disc-prefixed filename mid-process): every bare `NN - Title.ext` file
  becomes `$DiscNum.NN - Title.ext`. Multi-format rips (`-format flac,mp3`)
  are handled - the rename pass isn't extension-filtered.
- **Two latent correctness bugs found and fixed while wiring this in, both
  in code that predates this session:**
  1. The resume-detection track-parsing loop already had a currently-dead
     regex branch for `N.NN - Title` filenames (`# Handle both "01 - Title.flac"
     and "1.01 - Title.flac" (multi-disc) formats`) that extracted the track
     number but silently ignored *which disc* the file belonged to - so
     disc 1's `1.05` would have satisfied disc 2's "is track 5 present?"
     check. Fixed by also capturing and filtering on the disc-number capture
     group under `-DiscNum`.
  2. The "no valid tracks, remove stale files before a fresh rip" cleanup
     used an unfiltered `Get-ChildItem -Include *.flac,...` over the whole
     folder - under a shared multi-disc folder this would have deleted an
     *earlier, already-ripped disc's* tracks the moment a later disc's rip
     found nothing of its own yet. Fixed to only ever touch bare-named files
     or this disc's own `$DiscNum.NN` files.
- Track-count lookup passes the already-existing `-Fresh` switch (added
  earlier today by a concurrent session's PR #145, for a different reason -
  crash recovery) whenever `-DiscNum` is set: a `.cue` file sitting in the
  shared folder could belong to a different disc than whichever one is
  physically in the drive right now, so the cue-file shortcut is bypassed
  and a live query is used instead. Lucky, well-timed prior work - no new
  function needed for this part.
- Cover art needed no special handling: the pre-existing "already have art,
  skip re-downloading" check in Step 3 already means only the first disc in
  a set actually fetches it.
- The "directory already exists" warning wording is softened under
  `-DiscNum` (`Shared multi-disc folder already has N file(s) from previous
  disc(s)` instead of `WARNING: Directory already exists`) - expected state,
  not a conflict to alarm about.

**Known gaps, documented rather than silently left (both in README and
Roadmap.md's Backlog section now):**
1. `search-metadata.ps1`'s existing multi-disc matching (PR #85, matches
   local track count against one MusicBrainz medium) does not understand a
   `-DiscNum`-merged shared folder yet - don't run it against one.
2. The end-of-run "these tracks look untagged" prompt's generic-filename
   regex (`^\d{2} - .+ - .+\.flac$`) doesn't recognise the new `N.NN - `
   prefix, so it may under-flag a still-generic multi-disc rip. The
   `Unknown track`/`Unknown disc` substring check alongside it is
   unaffected.

**Files changed:** `rip-audio.ps1`, `README.md` (new "Multi-Disc Albums"
section + parameter row + examples), `CHANGELOG.md`, `Roadmap.md` (new
backlog item for gap #1 above), `CLAUDE.md` (this entry)

**Testing status:** parse-checked only (PowerShell tokenizer, 0 errors),
added lines confirmed ASCII-only. **Not exercised against a real two-disc
rip end-to-end.** Each piece (the prefix rename, the disc-aware resume/
stale-file filtering, the `-Fresh` bypass) is individually reasoned correct
against the existing code it modifies, but the full disc-1-then-disc-2
sequence - including the actual "Eagles - The Complete Greatest Hits" rip
that prompted this - has not been run against real hardware yet.

**Process note:** pushed directly via `gh`/`git` from this session, same as
the MusicBrainz backoff entry immediately above - `git-manager` subagent
capacity was still constrained at the time this was built.

**Priority for Next Session:**
1. Live end-to-end test: actually run the two `-DiscNum` commands against
   the real Eagles 2-CD set (or any other multi-disc album on hand) and
   confirm both discs' tracks land correctly prefixed in one folder, with no
   collision, no false "stale file" deletion of disc 1's tracks, and correct
   per-disc track counts.
2. Teach `search-metadata.ps1` to handle a `-DiscNum`-merged shared folder
   (split local files by the `N.NN - ` prefix, match/tag each disc's group
   against its own MusicBrainz medium) - tracked in Roadmap.md's Backlog
   section now, not yet started.
3. Consider whether the generic-filename detection regex noted above is
   worth widening to also recognise the `N.NN - ` prefix, once real
   multi-disc rips have been run to see whether it actually matters in
   practice.

---

### 2026-08-29 (later again) - Three Real Bugs From One Bad Rip

**Trigger:** the Eagles disc-2 rip (mentioned in the entry above as
untested) hit real trouble the same day it was built. Traced the full
transcript end to end at the user's request ("why is so much wrong here?")
and found three separate, previously-undiscovered bugs, each masking the
next:

1. cyanrip hung (separate issue, discussed with the user, left unfixed by
   their choice - see prior conversation, not repeated here).
2. `continue-rip-audio.ps1 -FromTrack 1` was used to resume after the hang.
   It had no MusicBrainz failure handling at all - cyanrip's own internal MB
   query ran unconditionally, hit the day's ongoing 503, and killed the
   entire 16-track resume after writing just 1 file.
3. The crashed attempt left a 1-track `.cue` file behind. The next plain
   `rip-audio.ps1` re-run's *default* resume-detection path trusted that
   `.cue` (the cue-before-live-query shortcut), concluded the album only has
   1 track, and declared it COMPLETE - 15 of 16 real tracks silently
   missing. This is the same failure class PR #145 and this session's own
   `-DiscNum` work already fixed at two *other* call sites - just not this
   one, the one every ordinary re-run actually goes through.
4. That false completion, plus ~8 corrupt leftover files from the hang/
   crash, fed `search-metadata.ps1`, which counted all 9 raw `.flac` files
   with no integrity check, searched for a "9-track" match against real
   releases, and mistagged the one real track as "Take It Easy" - a song
   from a *different disc* of the same box set.

**All three code-level bugs (2-4) fixed, user confirmed wants all three:**
- `rip-audio.ps1`: the default `Get-DiscTrackCount` resume-detection call
  now always passes `-Fresh` (unconditional, not just under `-DiscNum`) -
  closes the `.cue`-trust bug at its last remaining call site.
- `continue-rip-audio.ps1`: new quick, single-attempt, non-interactive
  MusicBrainz reachability check before the cyanrip invocation - adds `-N`
  on failure instead of letting cyanrip's internal query take the whole
  resume down with it. Deliberately not interactive (no retry/skip prompt
  like `rip-audio.ps1` has) - a resume script should just get on with it.
- `search-metadata.ps1`: new `Test-TrackIntegrity` function (same check the
  other two scripts already use) now filters `Read-ExistingTags`'s file
  list before anything downstream sees it, so corrupt leftover files are
  reported and skipped rather than counted as real tracks.

**Deliberately not fixed:** the MusicBrainz 503 issue itself (tracked
separately in Roadmap.md's Backlog, not a client-side bug); the original
cyanrip hang (user's explicit choice, see prior turn); cleanup of any
already-corrupted folders from before this fix landed - those need manual
inspection, not an automated repair.

**Files changed:** `rip-audio.ps1`, `continue-rip-audio.ps1`,
`search-metadata.ps1`, `CHANGELOG.md`, `CLAUDE.md` (this entry)

**Testing status:** all three files parse-checked clean, added lines
ASCII-only. **None of the three fixes has been exercised against a real
repeat of its triggering scenario** - each is reasoned correct against the
specific failure sequence observed in this incident's own pasted
transcripts, not independently reproduced from scratch. The actual Eagles
disc-2 folder is still in a corrupted state on disk and has not been
cleaned up or re-ripped.

**Process note:** pushed directly via `gh`/`git` from this session, same as
the last several changes - `git-manager` subagent capacity was still
constrained.

**Priority for Next Session:**
1. Clean up `F:\Music\Eagles\The Complete Greatest Hits CD 2` (wrong
   metadata, one mistagged track, ~8 corrupt leftovers, 15 tracks missing)
   and re-rip it properly now that all three fixes are in place.
2. Live end-to-end validation: deliberately interrupt a rip, let a `.cue`
   file end up stale, and confirm the `-Fresh` fix actually catches it
   rather than repeating this exact incident.
3. Live-validate `continue-rip-audio.ps1`'s new MB check against a real
   resume while MusicBrainz is actually unreachable (today's ongoing 503s
   make this easy to test for real, unfortunately).
4. Live-validate `search-metadata.ps1` against a folder with real corrupt
   leftover files and confirm the skip message and reduced track count
   both show correctly.
5. Everything carried from the multi-disc entry above still stands.

---

### 2026-08-29 (yet again) - cyanrip Silence-Timeout Watchdog

**Trigger:** the same physical Eagles disc-2 disc produced a fully silent,
apparently-hung terminal *twice* in one session - no progress, no error
text, nothing. User asked if it "should be verbose" (yes, it should), then
confirmed via `busy-drive` detection that the process was genuinely still
running, not crashed - just silent. User opted in to a watchdog fix at that
point, having declined it the first time this came up earlier the same day.

**Change:** new 5-minute silence-timeout watchdog in
`Start-CyanripWithErrorDetection`, ported identically to both
`rip-audio.ps1` and `continue-rip-audio.ps1`'s copies of the function.
Tracks wall-clock time since cyanrip last produced *any* output (including
lines suppressed from the console); kills the process if 5 minutes pass
with nothing. Deliberately reuses the existing `Killed` result flag rather
than a new code path, so it plugs directly into the already-proven
skip-track/re-query-fresh/resume recovery logic at all 8 call sites in
`rip-audio.ps1` with zero caller-side changes.

**Why the existing cdio-error counter didn't catch this:** that counter
(kills after 30 consecutive error lines) requires cyanrip to actually print
recognisable error text. A stall deep in a paranoia-level retry loop, below
even the 10%-progress-display threshold, can produce nothing at all for
minutes at a time - no error, no progress, nothing to count.

**Files changed:** `rip-audio.ps1`, `continue-rip-audio.ps1`,
`README.md` (new "Silence timeout" paragraph), `CHANGELOG.md`, `CLAUDE.md`
(this entry)

**Testing status:** both files parse-checked clean, added lines ASCII-only.
**Not exercised against a real silence timeout firing** - the mechanism
plugs into already-proven recovery code, but the 5-minute trigger itself
has not been observed catching an actual stall live yet.

**Priority for Next Session:**
1. Watch for the watchdog actually firing on a real stall (this exact disc
   is the obvious candidate) and confirm the skip/resume behaves as
   designed, not just as reasoned.
2. Consider whether 5 minutes is the right threshold once there's a real
   data point - too short risks killing a genuinely slow-but-working
   paranoia recovery; too long just delays the same outcome.
3. Everything carried from the three-bugs entry above still stands,
   including that the Eagles disc-2 folder itself is still not cleaned up.
