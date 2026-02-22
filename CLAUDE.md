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
