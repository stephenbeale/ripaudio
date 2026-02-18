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
    README.md            # User documentation
    CLAUDE.md            # This file - development notes
    Roadmap.md           # Planned features
```

## Script Architecture

The script follows the same patterns as the ripdisc project:

### Step Tracking
- 3-step workflow: cyanrip rip, verify output, open directory
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

- [ ] Add `-quality` parameter for lossy format bitrate control
- [ ] Support multiple output formats in single rip (`-o flac,mp3`)
- [ ] Add AccurateRip verification reporting
- [ ] Queue mode for batch ripping (similar to ripdisc)
- [x] Cover art handling (sequential fallback: CAA, MusicBrainz+CAA, iTunes, Deezer)
- [ ] CDDB fallback when MusicBrainz has no match

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
