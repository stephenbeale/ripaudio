# Changelog

All notable changes to this project are documented here.

## 2026-08-26 (continued)

### Fixed
- **Every `[Console]::KeyAvailable`/`ReadKey` confirmation prompt across the whole toolkit was broken under redirected console input** (e.g. running non-interactively) - `KeyAvailable` throws `InvalidOperationException` unconditionally in that case. Found by reproducing it live: `undo-metadata.ps1`'s "Apply undo?" prompt crashed outright with a raw stack trace. Audited and fixed all 9 sites across all 4 scripts:
  - **7 guarded polling-loop sites** (`undo-metadata.ps1`, both `rip-audio.ps1` prompts, `audit-metadata.ps1`'s shared `Read-TimedConfirmation` helper, and 3 in `search-metadata.ps1`) were previously re-throwing the same exception on every 200ms poll for the entire configured timeout (up to 30s of console spam) before falling through to their existing, already-safe null-fallback default. Now the exception breaks the loop immediately - each site's own existing timeout-fallback behaviour (auto-Yes or auto-No, whichever that site already used) is unchanged, only the 30-second wall of repeated errors is gone. Verified: loop iterations under redirected input dropped from ~150 to 1, elapsed time from ~30000ms to ~12ms.
  - **2 genuinely unguarded, bare blocking `ReadKey` calls with no timeout at all** - `undo-metadata.ps1`'s "Apply undo? [Y/n]" and `search-metadata.ps1`'s "Apply anyway? [y/N]" (artist-mismatch override). Both now wrap the read in try/catch. `search-metadata.ps1`'s was already safe-by-accident (its `-ne "Y"` check means a failed/empty read already declines) - the fix there is purely cosmetic (no more raw exception text). **`undo-metadata.ps1`'s was a genuine safety bug**: its `-eq "N"` check meant a failed read (empty `KeyChar`) was indistinguishable from someone pressing Y - a redirected console would silently *confirm* an irreversible undo, not decline it. Now fails safe: an unreadable prompt is treated as an explicit decline, matching this repo's existing "never assume consent" posture for destructive actions.

**Testing status:** all 4 scripts parse clean; all diff lines confirmed ASCII-only. Both previously-crashing bare prompts verified in isolation to decline cleanly (no exception, no silent proceed) under redirected input. The guarded-loop fix verified to break in ~12ms instead of spinning for the full timeout. Not yet re-exercised via the actual scripts end-to-end against a real interactive terminal (where none of this ever threw in the first place - the bug only manifests when these scripts are run non-interactively, e.g. by an automation tool rather than a human at a real console).

## 2026-08-26

### Fixed
- **An explicit `-Drive` value was never validated** - live incident: `-Drive G` was passed for a rip, but `G:` isn't an optical drive that exists on the machine. The script sailed straight through the header/log/directory-creation steps as if it were valid, and only cyanrip itself caught the problem a minute later, reporting *"cyanrip could not read the disc TOC -- disc may be dirty, damaged, or the wrong type"* - a message indistinguishable from a genuinely bad disc, when the real problem was a stale/mistyped drive letter. Auto-detect (when `-Drive` is omitted) already checked drives against `Win32_CDROMDrive`; an explicitly-passed `-Drive` skipped that check entirely. Now an explicit `-Drive` is matched against the same WMI drive list: a match prints a confirmation line (`Using optical drive: D: (Name)`), a clear non-match fails immediately with the actual detected drives listed and next-step guidance, and an inconclusive WMI result (zero drives detected at all, which can happen transiently for some external drives) warns but does not block, since that's an absence of evidence rather than evidence the drive is wrong.

### Added
- **Busy-drive detection (hard block) and a ripdisc-style drive listing** - follow-up to the fix above, prompted by running two rips concurrently and nearly pointing a second one at a drive already mid-rip. Every running `cyanrip` process's command line is inspected (`Win32_Process`) to determine which drive letters are currently busy, mirroring the same technique `ripdisc` uses for MakeMKV. A busy drive is now a hard block (`exit 1`), not a warning-and-confirm - matching the request that a busy drive should never be usable, not just flagged. Both the auto-detect path (single drive, multiple-drive picker) and the explicit `-Drive` path check busy state. Drives are also now always listed with their disc's volume label where Windows can read one (`Get-Volume`, e.g. `[DADS_ARMY]`) and a busy/free indicator, with `<--` marking the selected drive - the same shape as ripdisc's `MakeMKV drives:` listing. Caught two real bugs while building this: cyanrip's `-d` (drive) and `-D` (output directory) flags are case-distinct, so command-line matching must use `-cmatch` (a case-insensitive `-match` was matching `-D`'s directory argument instead); and `$Matches` is a single global variable, so a second `-match` performed on `$Matches[1]` itself (to normalize the trailing colon) silently clobbers the capture being read - fixed by copying it to its own variable first.

### Fixed
- **Busy-drive detection was silently skipped when WMI's optical-drive enumeration came back empty.** The explicit `-Drive` path's "no drives detected via WMI" branch warned and proceeded without checking busy state at all - the in-code comment claimed busy detection "can't run here," but that's not actually true: `$busyDriveLetters` is built from running `cyanrip` process command lines, entirely independent of the `Win32_CDROMDrive` list that came back empty. A drive going busy during exactly the window WMI's enumeration is transiently empty would have slipped straight through the hard block added above. Fixed: busy state is now checked on this path too, before falling through to the warn-and-proceed case.

### Added
- **Bounded, best-effort real album/artist lookup in the drive listing, replacing the generic "Audio CD" label.** Audio CDs (CDDA) have no filesystem, so `Get-Volume` always reports the literal string `"Audio CD"` for one, regardless of what's actually on the disc - unlike a DVD/data disc, which has a real ISO9660/UDF volume name. New `Get-QuickDiscIdentity` runs `cyanrip -I` (discovery only, no rip) as a real `Process` with a 5-second hard timeout: on success it shows `[Artist - Album]` in the listing instead of `[Audio CD]`; on timeout, no MusicBrainz match, or any failure, it falls straight back to the existing generic label - never blocks or errors the listing. Only attempted when the label is exactly the generic `"Audio CD"` (a real label is already useful, skip the cost) and the drive isn't busy (never queries a drive mid-rip). Verified against real hardware: a populated drive with no MusicBrainz match resolved in 920ms and correctly fell back to `null`; a deliberately slow dummy process confirmed the timeout fires at the configured bound and the child process is actually killed, not just abandoned.

## 2026-08-17

### Fixed
- **False `Tagged:` success lines** - `rip-audio.ps1` printed `Tagged: <file>` to the console and the log immediately after calling `& metaflac --set-tag=...`, without checking the result. A non-zero exit from an external executable does not raise a terminating error, so the surrounding `try/catch` never fired and tagging failures were reported as successes. Now gated on `$LASTEXITCODE`, with a yellow warning and a `WARNING:` log line on failure — the same pattern already used by the `-Reset` path in `search-metadata.ps1`.
- **Paths with spaces broke the search-metadata.ps1 handoff** - `Start-Process -ArgumentList @(...)` joins its array on spaces before handing the string to the child process, so an unquoted path was split into separate tokens. Launching `search-metadata.ps1` for an album in `C:\Music\Dylan Thomas\Under Milk Wood` bound `-Path` to `C:\Music\Dylan` and then fed `Thomas\Under`, `Milk` and `Wood` to the positional `-Artist`/`-Album` parameters, failing with *A positional parameter cannot be found that accepts argument 'Wood'*. The album then fell through to the Mp3tag manual-tagging prompt. All four affected call sites now wrap their paths in embedded quotes (with a trailing-backslash trim so the closing quote is never escaped): the `search-metadata.ps1` handoff in `rip-audio.ps1`, the same handoff in `audit-metadata.ps1` step 4, and both `explorer.exe` open-directory calls.

## 2026-04-23

### Added
- **"It's ripping time!" walk-away banner** - Coloured banner with cyanrip command summary displayed before cyanrip launches so users know they can step away (PR #117).
- **`Show-QuestionHint` helper** - Prints `[ A few more questions to answer... ]` before every major interactive prompt block (disc discovery, track selection, directory conflict), so users know to stay at the keyboard until the rip starts (PR #120).
- **Pre-rip audio backup and restore** - Before cyanrip launches, backs up all existing non-empty audio files from the output directory to `%TEMP%\ripaudio-backup-XXXX\`; after cyanrip completes, restores any files that cyanrip truncated to 0 bytes on a failed rip. Protects already-ripped tracks from destruction on a damaged-disc retry (PR #122).

### Fixed
- **Silent cyanrip failures (true root cause)** - `$Args` is a reserved PowerShell automatic variable; the `Start-CyanripWithErrorDetection` param `[string[]]$Args` was silently overridden by the (empty) automatic `$args` at call time, so every cyanrip invocation since the streaming rewrite (PR #56, 2026-02-22) launched with zero arguments and exited 0 within seconds without ripping. Renamed the parameter to `$CyanripArgs` and updated all 8 call sites (PR #113).
- **ProcessStartInfo.ArgumentList on .NET Framework 4.8** - The property does not exist on the .NET Framework that backs Windows PowerShell 5.1 (it's a .NET Core / .NET 5+ API), returning `$null` instead of an `IList<string>`. Replaced the `ArgumentList.Add()` loop with a manually quoted `$psi.Arguments` string so the launch path works on both .NET Framework and modern .NET (PR #112).
- **Silent cyanrip failure detection** - Added three guardrails in the cyanrip launch path: (1) post-rip verification that the output directory contains at least one non-empty audio file, with a diagnostic that distinguishes disc-read failure from stale-files scenarios; (2) automatic cleanup of stale audio files when the user chooses *Continue (rip all tracks)* at the no-valid-tracks prompt, so cyanrip does not refuse to overwrite them; (3) Step 2 verification now filters `Length -gt 0` so zero-byte files are not counted as ripped (PR #111).
- **PS 5.1 parse error in `Track $failedTrack:` log line** - PowerShell 5.1 parsed `$failedTrack:` as a drive-qualified variable reference (same syntax as `$env:PATH`), producing a ParserError that prevented the script from loading at all. Wrapped the variable in `${}` so the colon is a literal string character (PR #110).
- **Silent console during working rip** - After PR #113 fixed cyanrip arguments, the console remained completely silent during ripping because `add_OutputDataReceived` scriptblock events in PS 5.1 run in a different scope and cannot access closure variables from the caller. Replaced with `StreamReader.ReadLineAsync()` polling on the main thread (PR #115).
- **Partial rip tolerance** - cyanrip exits non-zero even when some tracks ripped successfully (e.g. on a scratched disc). Now checks for any non-empty audio files before deciding to abort: if at least one track exists, prints a yellow warning and continues to Step 2+ rather than hard-aborting (PR #121).

### Changed
- **cyanrip progress output** - Removed blanket suppression of `progress - XX.XX%` lines (PR #116), then reintroduced selective display: one milestone line per track per 10% bucket (10%, 20%, ..., 100%), suppressing intermediate lines to keep the console readable without going silent (PR #118).
- **Walk-away banner timing** - Banner deferred to skip the 0–9% bucket, avoiding display of nonsensical early ETAs (e.g. "424h 29m") while the disc drive spins up; first milestone shown is 10% (PR #119). Banner then moved back to pre-launch after `Show-QuestionHint` was added in PR #120 to handle the prompt-vs-rip sequencing cleanly.
- **Session documentation** - CLAUDE.md and CHANGELOG.md updated with full writeup of PRs #110–#113 (PR #114).

## 2026-03-23

### Fixed
- **False data error detection** - Regex `rip(ping)? error` matched inside cyanrip's `Ripping errors: 0` summary line, causing every rip to falsely flag the last track as having a data error; fixed with a negative lookahead (PR #106)

## 2026-03-11

### Added
- **MIT License** - Added `LICENSE` (MIT, (c) 2026 Stephen Beale), making the project's terms explicit rather than "provided as-is for personal use" (PR #102)
- **PowerShell Gallery manifest** - Added `RipAudio.psd1` with module metadata, `PowerShellVersion = '5.1'`, `CompatiblePSEditions = @('Desktop', 'Core')`, a `FileList` covering all five scripts and the docs, and a `PrivateData.PSData` block carrying PSGallery tags, `LicenseUri`, `ProjectUri`, and release notes (PR #102)
- **README installation options** - The Installation section now offers *Option A: PowerShell Gallery (recommended)* (`Install-Module RipAudio`) above the existing manual steps, which became *Option B: Manual*; the License section now points at the MIT `LICENSE` file (PR #102)

### Fixed
- **SiteGround affiliate art removed in error** - PR #102 also stripped the six-line SiteGround affiliate block from `Show-CoffeeBadge` in `rip-audio.ps1`, `audit-metadata.ps1`, `search-metadata.ps1`, and `undo-metadata.ps1`. That removal was not intended: the licence/manifest prep and the affiliate art are independent, and the art was meant to stay. Restored in all four scripts (PR #103)

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
