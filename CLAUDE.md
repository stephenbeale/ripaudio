# RipAudio Project

PowerShell script for automated audio CD ripping using cyanrip.

## Git Workflow

When the user says **"make a workflow"**, execute the full git lifecycle. The workflow is **not complete until the PR is approved and merged**:

1. **Branch** - Create a feature branch from main (`feature/<issue-number>-<description>` or `feature/<description>`)
2. **Commit** - Stage and commit all relevant changes with a conventional commit message
3. **Push** - Push the branch to origin (`git push -u origin <branch>`)
4. **PR** - Create a pull request via `gh pr create` with summary and test plan
5. **Approve PR** - Approve via `gh pr review --approve`, then merge via `gh pr merge --squash --delete-branch`
6. **Return to main** - `git checkout main && git pull`

## Project Structure

```
ripaudio/
    rip-audio.ps1        # Main CD ripping script (cyanrip)
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
