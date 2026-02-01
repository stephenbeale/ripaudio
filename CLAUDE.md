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
    rip-audio.ps1      # Main PowerShell script
    README.md          # User documentation
    CLAUDE.md          # This file - development notes
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
- [ ] Cover art handling options
- [ ] CDDB fallback when MusicBrainz has no match
