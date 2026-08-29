# Changelog

All notable changes to this project are documented here.

## 2026-08-29 (yet again) - cyanrip Silence-Timeout Watchdog

### Added
- **New silence-timeout watchdog in `Start-CyanripWithErrorDetection`, ported identically to both `rip-audio.ps1` and `continue-rip-audio.ps1`.** Live incident: the same physical disc produced a fully silent, apparently-hung terminal *twice* in one session - no progress lines, no error text, nothing - most likely a paranoia-level retry loop stuck on a damaged/dirty sector, deep enough that even the 10%-progress-display threshold was never crossed. The existing consecutive-cdio-error counter (kills after 30 error lines in a row) never fires in this scenario, since it requires cyanrip to actually print recognisable error text - a fully silent stall produces nothing for it to count.
  - Tracks wall-clock time since cyanrip last produced *any* output line (progress, error, anything - including lines suppressed from the console by the existing 10%-milestone collapsing). If 5 minutes pass with zero output and the process hasn't exited on its own, it's killed.
  - Deliberately reuses the existing `Killed` result flag rather than inventing a new code path - a silence-timeout kill is handled by exactly the same "skip this track, re-query the disc fresh, resume on the rest" recovery logic already proven for cdio-error kills and cyanrip crashes, at all 8 `Start-CyanripWithErrorDetection` call sites in `rip-audio.ps1` with zero caller-side changes needed. `continue-rip-audio.ps1`'s own (simpler, non-auto-resuming) handling of a killed/nonzero-exit result also needed no changes.
  - 5-minute threshold chosen as generous enough that a genuinely slow-but-working paranoia-level recovery shouldn't false-trigger, while still bounding the wait instead of leaving the user staring at a silent terminal indefinitely.
  - README.md: new "Silence timeout" paragraph under "Error Handling".

**Testing status:** both files parse-checked clean (PowerShell tokenizer, 0 errors), added lines confirmed ASCII-only. **Not exercised against a real silence timeout firing** - the 5-minute threshold has not been observed catching an actual stall live; the mechanism is reasoned correct against the existing, already-proven `Killed`-handling code it plugs into; verifying it fires correctly on the very disc that motivated it is the natural next test.

## 2026-08-29 (later again) - Three Real Bugs From One Bad Rip

Live incident: a single interrupted Eagles disc-2 rip cascaded through three separate,
previously-undiscovered bugs across three scripts, ending with one real track mistagged
as a completely different song from a different album. Traced end to end and fixed at
each stage.

### Fixed
- **`rip-audio.ps1`'s default resume-detection trusted a `.cue` file that a crashed rip
  had corrupted, and declared a 15-tracks-missing album COMPLETE.** A `continue-rip-audio.ps1`
  resume attempt died after 1 track (see below), leaving a `.cue` file behind that only
  reflected the 1 track actually written. The next `rip-audio.ps1` run's resume-detection
  read that `.cue` first (the default, cue-before-live-query shortcut), took its track
  count as gospel, and reported "All 1 tracks already ripped and valid" - marking the
  album finished with 15 of 16 real tracks silently missing.
  - This exact failure class (a crash corrupting a `.cue`'s reported track count) was
    already identified and fixed once today, at two other `Get-DiscTrackCount` call
    sites (PR #145's crash-recovery path, and this session's own `-DiscNum` resume
    path) - but not at this one, the *default* path every ordinary re-run goes through.
  - Fixed by making this call site always pass `-Fresh` (live disc query) instead of
    conditionally. The live query costs a few seconds and needs no interactive input
    even on a multi-release disc; it cannot be corrupted by an earlier failed attempt
    the way a leftover `.cue` file can.
- **`continue-rip-audio.ps1` had no MusicBrainz failure handling at all, so a single MB
  hiccup could kill an entire multi-track resume.** Its cyanrip invocation carried no
  `-N` flag and no connectivity check - cyanrip's own internal MusicBrainz query ran
  unconditionally, and when it hit a `503 Server Unavailable` (this session's ongoing MB
  reliability issue, see the Backlog item in Roadmap.md), cyanrip aborted the whole
  process. A `-FromTrack 1` resume asking for all 16 tracks got exactly 1 before dying.
  - Added a quick, single-attempt, non-interactive MusicBrainz reachability check before
    the cyanrip invocation (unlike `rip-audio.ps1`, this script never prompts to
    retry/skip - a resume should just get on with it). An unreachable API adds `-N` to
    the cyanrip command instead of leaving the query to fail mid-rip and take the whole
    attempt down with it.
- **`search-metadata.ps1` counted every `.flac` file in a folder as a real track, with no
  integrity check**, so leftover corrupt/truncated files from an earlier interrupted rip
  inflated the local track count used for metadata matching. In the incident: 1 genuinely
  valid track plus ~8 corrupt leftovers were counted as "9 FLAC file(s)", and searching
  for a 9-track match against real releases produced nonsense (a 4-track Discogs edition
  explicitly flagged as a different edition, a 25-track Deezer merge, wrong-artist iTunes
  hits) - which is how the one real track ended up retitled "Take It Easy", a song from a
  different disc of the same box set entirely.
  - New `Test-TrackIntegrity` function (same check `rip-audio.ps1`/`continue-rip-audio.ps1`
    already use) now filters `Read-ExistingTags`'s file list before anything downstream
    sees it - corrupt files are reported and skipped, not counted.

**Not fixed in this pass (deliberately out of scope):** the underlying MusicBrainz 503
reliability issue itself (tracked in Roadmap.md's Backlog section, not a client-side bug);
cleanup of already-corrupted folders from before this fix (each one needs to be checked
and likely re-ripped by hand, not auto-repaired); the original cyanrip hang that started
this whole chain (separate issue, discussed but not fixed by user's own choice).

**Testing status:** all three files parse-checked clean (PowerShell tokenizer, 0 errors),
added lines confirmed ASCII-only. None of the three fixes has been exercised against a
real repeat of its triggering scenario - each is reasoned correct against the specific
failure sequence observed in this incident's own pasted transcripts, not independently
reproduced from scratch.

## 2026-08-29 (later still) - Opt-In Shared-Folder Multi-Disc Mode

### Added
- **New `-DiscNum` parameter (1-99)** - opt-in mode to rip a multi-disc set into ONE shared album folder instead of the existing default of a separate "Disc N" folder per disc. Direct user request, live incident: ripping a 2-CD "Eagles - The Complete Greatest Hits" set, MusicBrainz's disc-number detection failed (503 mid-lookup) and the user had to hand-type "The Complete Greatest Hits CD 1" as the album name just to avoid an accidental-overwrite collision on disc 2 - not the folder layout they actually wanted.
  - When `-DiscNum` is passed, the existing auto-detected "Disc N" folder-suffix append is skipped entirely - both discs share the same `-album`/`-artist` output folder.
  - Every track filename gets a disc-number prefix (`NN - Title.ext` -> `N.NN - Title.ext`, e.g. `2.01 - Hotel California.flac`), applied in a new pass right after cyanrip's own rip/rename/tag/eject sequence completes (not interleaved with it), so disc 2's own track 1 never collides with disc 1's already-ripped `1.01 - ...` file.
  - The "directory already exists" check, the resume/missing-track detection, and the stale-file cleanup before a fresh rip are all now disc-aware: under `-DiscNum`, a file belonging to a *different* disc number (or a bare, un-prefixed leftover) is recognised and left alone rather than counted toward the current disc's valid/missing tracks or deleted as stale. Reuses the disc.track (`N.NN`) filename pattern the resume-detection regex already recognised defensively, rather than inventing a second naming convention.
  - Track-count lookup passes the existing `-Fresh` flag (from the earlier crash-recovery fix) whenever `-DiscNum` is set, since a `.cue` file already sitting in the shared folder could belong to a different disc than the one currently in the drive - a live disc query is the only reliable source of truth there.
  - Cover art is unaffected by design - the existing "already exists, skip re-downloading" check in Step 3 means only the first disc actually fetches it; later discs in the same set reuse it.
  - Purely opt-in: omitting `-DiscNum` leaves every existing single-disc and auto-detected multi-disc (separate "Album Disc N" folders) behaviour completely unchanged.
  - README.md: new "Multi-Disc Albums" section, `-DiscNum` parameter row, updated usage synopsis, and a new example.

**Known gaps, documented rather than silently left:**
- `search-metadata.ps1`'s existing multi-disc matching logic still assumes one folder = one disc when comparing local track count against a MusicBrainz medium - it does not yet understand a `-DiscNum`-merged shared folder and should not be run against one yet.
- The end-of-run "these tracks look untagged" prompt's generic-filename detection (`^\d{2} - .+ - .+\.flac$`) doesn't recognise the new `N.NN - ` prefix pattern, so a still-generically-named multi-disc rip may be under-flagged there. The `Unknown track`/`Unknown disc` substring check in the same condition is unaffected and still catches those.

**Testing status:** verified by PowerShell tokenizer parse-check only; added lines confirmed ASCII-only. Not exercised against a real two-disc rip end-to-end - the disc-prefix rename, the disc-aware resume/stale-file filtering, and the `-Fresh` track-count bypass are each individually reasoned to be correct against the existing code they modify, but the full disc-1-then-disc-2 sequence has not been run against real hardware.

## 2026-08-29 (continued)

### Changed
- **MusicBrainz connectivity retries now back off automatically instead of re-hitting the API instantly.** Live pattern this session: the pre-rip connectivity check failed repeatedly with `503 Server Unavailable` across multiple separate rip attempts, and hitting `[R]` Retry sent the exact same request again with no gap - a shared public service returning a transient error (rate limiting or a brief outage) often needs a moment, so an instant re-hit just resends into the same window.
  - Both pre-flight connectivity-check retry loops (`-RequireMusicBrainz` and the normal `[R]/[C]/[Q]` path) now wait before each successive retry: 5s, then 10s, then 15s, capped at 15s. Resets each time the check is entered fresh (a new album/rip).
  - Each retry attempt number is now included in the log line (`MusicBrainz connectivity retry N failed: ...`), so a genuinely sustained outage across many rips is easier to spot after the fact than before, when every failure logged identically.
  - Does not touch the *other*, separate MusicBrainz-retry path (cyanrip itself reporting `MusicBrainz query failed`/`Connection failed` mid-rip, further down in the script) - that path re-invokes cyanrip on retry, a much heavier operation than a lightweight connectivity probe, and wasn't the one hit in the observed failures.

**Testing status:** verified by PowerShell tokenizer parse-check only; added lines confirmed ASCII-only. Not exercised against a real, live MusicBrainz outage - the backoff timing itself has not been observed resolving a real 503 faster than instant retries would have. This does not "fix" MusicBrainz being down; it only stops the client from hammering it while it is.

### Fixed
- **`continue-rip-audio.ps1`'s `-FromTrack <N>` now implies `-FromStep rip`, so it no longer has to be passed alongside a redundant step it already determines.** Prompted directly by user feedback on the `-FromTrack` feature shipped in PR #143: "the from step is a bit confusing, isnt it?" - and it was. `-FromTrack` only ever applies to the rip step (that's why the existing "will be ignored" warning fires when `-FromStep` resolves to anything else), yet every invocation still had to spell out `-FromStep rip -FromTrack 9`, restating something the flag already unambiguously implied.
  - When `-FromTrack` is given and `-FromStep` is omitted, `-FromStep` now defaults to `rip` (with a one-line console note saying so) before step resolution runs. Without this default, omitting `-FromStep` dropped into the interactive step-picker menu rather than just doing the one thing `-FromTrack` asked for.
  - **Explicit still beats implied:** if `-FromStep` *is* passed and resolves to something other than `rip`, behaviour is unchanged - the "will be ignored" warning already shipped in PR #143 still fires, and the chosen step is still honoured. Only the omitted case gains the new default.
  - The no-`-FromTrack` case is untouched: an omitted `-FromStep` with no `-FromTrack` still opens the interactive step picker as before.
  - In-script help text/parameter list, one `Show-Usage` example, and README.md's `-FromTrack` description and usage example all updated to show `-FromTrack 9` on its own rather than `-FromStep rip -FromTrack 9`.

**Testing status:** `Parser::ParseFile` reports 0 errors. The new implication logic plus `Resolve-StepKey` were extracted into a standalone test script and run across 3 cases: `-FromTrack 9` with no `-FromStep` defaults to and resolves `rip`; `-FromTrack 0` with no `-FromStep` leaves `-FromStep` empty (interactive step-picker path preserved); `-FromTrack 9 -FromStep coverart` still resolves `coverart`, explicit winning over implied. All three correct. **Not done:** no real disc run - the same disclosed gap PR #143 already carries, since `continue-rip-audio.ps1` has still never been exercised against a real interrupted rip at any step.

## 2026-08-29

### Changed
- **`rip-audio.ps1` now asks which drive to rip to, and validates it up front, instead of silently defaulting to the system drive.** Previously an omitted `-OutputDrive` printed `Output drive defaulting to: C:` and moved on with no check at all - the first time an unready or disconnected output drive was noticed was deep inside Step 1, *after* the whole disc metadata discovery / multiple-release / MusicBrainz flow had already run and several other interactive questions had already been answered. The drive selection and its readiness check now both happen before any of that.
  - When `-OutputDrive` is omitted in normal interactive use, the script prompts (`Output drive (Enter for default: C:)`) via the existing `Show-QuestionHint`/`Read-Host` pattern used by the script's other prompts. Pressing Enter keeps the previous system-drive default, so the old behaviour is still one keystroke away.
  - **The chosen drive is validated regardless of where it came from** - explicitly passed via `-OutputDrive`, typed at the new prompt, or defaulted. Reuses the existing `Test-DriveReady` helper (the same check Step 1 already runs against the full album path) against the bare drive root, so there's no second, divergent notion of "ready".
  - **Mode-aware failure handling:** interactive mode loops on a not-ready drive, re-prompting for a different one (Ctrl+C to abort) rather than dying. `-Queue`/`-ProcessQueue` fail fast with `exit 1` instead, since the output drive is shared across an entire queue run - continuing would only produce the same failure once per disc.
  - **The prompt itself is skipped in `-Queue`/`-ProcessQueue`**, which keep the old silent system-drive default. `-Queue` only records metadata and doesn't write a rip yet, and `-ProcessQueue` is an unattended batch run - this matches how the script's other interactive prompts are already suppressed in those modes.
  - Prints `Output drive: X: - ready` once resolved, replacing the old silent-default line.
  - README.md's `-OutputDrive` parameter row updated to describe the prompt, the Enter-for-default behaviour, the queue-mode exception, and the readiness validation.

**Testing status:** **verified by PowerShell tokenizer parse-check only.** No disc was ripped, no live rip was run, and a real drive-not-ready condition was never reproduced - so the new prompt, the interactive re-prompt loop, and the `-Queue`/`-ProcessQueue` `exit 1` path have not been exercised against actual hardware. The underlying `Test-DriveReady` helper this relies on is pre-existing and already used elsewhere in Step 1, but its use at this new call site is not yet proven live.

### Fixed
- **`Test-TrackIntegrity` called a metaflac option that does not exist, so every FLAC file was classified as corrupt.** The FLAC branch of the check ran `metaflac --test`, but `metaflac` has no `--test` option at all - it only reads and edits metadata blocks and has no audio-stream decode/verify capability. Verified live against the installed FLAC 1.5.0 (winget `Xiph.FLAC`): the command prints ``unrecognized option `--test` `` plus usage text and exits 1 **unconditionally**, for every file, valid or not. `Test-TrackIntegrity` therefore returned `$false` for every FLAC file it was ever asked about.
  - **Real incident that surfaced it, this session:** a rip of "Welcome to Jamrock" by Damian Marley completed cleanly - cyanrip itself reported `Ripping errors: 0`, all 15 tracks written at correct sizes (24-36 MB each) with correct MusicBrainz track titles, and the files play fine - but the post-rip check ran `Test-TrackIntegrity` over them, got `$false` 15 times, concluded "0 valid tracks", and hard-failed the run with `cyanrip produced 15 corrupt/zero-byte file(s) and nothing valid`. Nothing was actually wrong with the rip.
  - **Blast radius was every integrity decision in the script**, not just that one message: the same function gates existing-directory resume-detection (so a fully-ripped album could never be recognised as already done), the post-cyanrip corrupt/valid classification (PR #141), and the Step 2 verify gate. All three were being fed a constant `$false`.
  - **Fix:** the FLAC branch now runs `flac --test --totally-silent <file>` - the actual FLAC decoder's stream-verification flag, shipped in the same install - and probes for `flac` via `Get-Command` instead of `metaflac`. The non-FLAC / tool-missing fallback (file size > 10 KB) is unchanged.
  - `README.md` (resume feature, flaky-drive recovery) and `Roadmap.md` updated where they documented the old `metaflac --test` check. The 2026-08-29 Added entry below still refers to `metaflac --test` as historical record of what was believed true when PR #141 was written; this entry supersedes it.

**Testing status:** **the CLI behaviour is live-verified against the real installed binaries and real files; the integrated script path is not.** Confirmed the old command fails unconditionally (`unrecognized option`, exit 1) against a real, valid, playable FLAC file. Confirmed `flac --test` passes that same file (exit 0), and - importantly - still **fails** a deliberately truncated copy of it (exit 1, `FLAC__STREAM_DECODER_ERROR_STATUS_LOST_SYNC`), so the replacement genuinely detects corruption rather than always passing. Confirmed `--totally-silent` suppresses the copyright banner, progress output and `ok`/error text while preserving the exit code, which this function needs since it runs silently in a loop over every track. The fixed function was then extracted from the real file and run against all 15 real Damian Marley FLACs on disk (`F:\Music\Damian Marley\Welcome to Jamrock`) - all 15 correctly return `$true`. `Parser::ParseFile` reports 0 errors. **Not done:** no full `rip-audio.ps1` run against a real disc, so the fix has not been observed propagating through existing-directory resume-detection or the Step 2 verify gate in situ.

- **A cyanrip crash now triggers auto-resume, and the resume pass no longer trusts a track count the failed run reported itself.** Prompted by a real incident this session: a rip of "Destination Anywhere" by Jon Bon Jovi died with exit code `-1073741819` (`0xC0000005`, a Windows access violation - a genuine process crash, not an error exit) after track 8, and the 8-track partial was silently accepted as final via the "Partial rip accepted" path.
  - **The resume loop was gated entirely on `$result.Killed`**, a flag set only when the script's own watchdog deliberately kills cyanrip after 30+ consecutive `cdio error` lines. A native crash never sets it, so the existing skip-the-bad-track-and-continue logic never engaged at all. New `Test-CyanripCrashExit` helper (`$ExitCode -le -1000000` - native Windows structured-exception exit codes are always huge negative Int32 values, while normal cyanrip exits are small); the loop condition is now `while ($result.Killed -or (Test-CyanripCrashExit $result.ExitCode))`.
  - **The resume pass determined "how many tracks in total" by regex-parsing `Disc tracks: N` out of the crashed run's own output** - trusting a number that can be corrupted by the very flaky USB/drive connection that caused the failure. This file already documents that exact failure mode elsewhere ("a flaky USB connection dropping mid-TOC-read can make cyanrip see far fewer tracks than the disc actually has, e.g. 2 instead of 13"). In the real incident the disc has roughly 12-14 tracks (confirmed against the actual release, and against tracks 1-8 already retagged on disk with real song titles), but the run self-reported a plausible-looking total of **9** - so even a correctly-triggered resume would have concluded "no more tracks to rip".
  - `Get-DiscTrackCount` gained a `-Fresh` switch that skips its cue-file shortcut (a cue written during the failed rip can carry the same corrupted count) and goes straight to a live `cyanrip -I` disc query. The resume loop now uses `Get-DiscTrackCount -Fresh`, falling back to the old self-reported-output parsing only if the live query returns nothing (e.g. drive transiently not responding).
  - Complements PR #141, which catches a flaky-connection rip *after the fact*; this makes the recovery path actually fire and use a trustworthy total. No overlap in the code either PR touches.

**Testing status:** **verified by `Parser::ParseFile` (0 errors), plus the `Test-CyanripCrashExit` classification logic unit-tested in isolation against 5 cases** (access violation `-1073741819`, clean exit `0`, normal error exit `1`, generic `-1`, stack overflow `-1073741571`) - all classified correctly. **NOT hardware-validated:** no crashed or flaky rip was reproduced end-to-end through the actual resume loop; the real incident that prompted the fix already happened and cannot be safely re-triggered on demand. The next real crash-type exit is the first live exercise of this path.

- **An explicit `-Drive` now lists every detected optical drive, not just the one it matched.** Running e.g. `-Drive G` printed only `Using optical drive:` followed by the single matched drive, so a machine with several optical drives (D:, G:, H:) gave no indication the others existed - no way to notice at a glance that the intended drive was a different one. Every other drive-listing path in the script already showed the full list with a `<--` marker on the selection: the auto-detect multi-drive picker, and both explicit-`-Drive` *error* paths (busy drive, drive not found) sitting directly either side of this branch in the same `if`/`elseif` chain. This success branch was simply the one that never got that treatment when it was written.
  - The branch now loops over `$opticalDrives` calling `Write-DriveListLine` for each, marking the matched letter with `-Selected`, exactly as its two sibling error branches already do. Header changed from `Using optical drive:` (Gray) to `Optical drives detected:` (Cyan) to match those siblings.
  - Restores the convention recorded for PR #130 - every drive-listing path shows letter, model, disc label, busy/free state and a selection marker, matching the shape of sibling project `ripdisc`'s listing.
  - Behaviour change is display-only: no drive selection, validation, busy-check or exit-code logic is touched.

**Testing status:** **verified by `Parser::ParseFile` (0 errors) only.** This repo has no test suite. Not exercised against real hardware - the listing was not re-run on this machine's actual three-drive setup (D:, G:, H:), so the rendered multi-drive output for the explicit-`-Drive` success path has not been observed live.

- **`rip-audio.ps1`'s MusicBrainz connectivity check now surfaces the real exception instead of guessing.** All three `catch` blocks in the `Checking MusicBrainz API connectivity...` section discarded `$_` entirely and printed only a generic `(API may be down, rate-limited, or blocked)` hint, with nothing written to the session log either - so a timeout, a TLS handshake failure, a proxy/firewall block, and a genuine HTTP 503 rate-limit were all indistinguishable from each other, both on screen and after the fact in the log. Each now prints `Reason: <exception message>` and writes a matching `Write-Log` line.
  - Covers the initial connectivity probe, the `-RequireMusicBrainz` retry loop (`[R]`/`[Q]`), and the normal retry loop (`[R]`/`[C]`/`[Q]`).
  - Diagnostics only - no control flow, prompt wording, or fallback behaviour (CDDB, generic track names) changes. The existing generic hint line is kept and the real reason is added beneath it.
  - **Note:** the first two of these three `catch` blocks were inadvertently included in the output-drive commit above (PR #138) without being described in its commit message or changelog entry; this entry documents all three together, and PR #139 carries the remaining one.

**Testing status:** **verified by `Parser::ParseFile` (0 errors) only.** This repo has no test suite. The failure path was reproduced manually beforehand to confirm the old `catch` blocks yielded no diagnostic information, but a real MusicBrainz outage/timeout/TLS failure was not forced against the new code, so the exact rendered `Reason:` text has not been observed live.

### Added
- **`rip-audio.ps1` now catches rips a flaky drive/USB connection silently corrupted, instead of reporting `COMPLETE!` regardless.** Prompted by two real interrupted rips pasted by the user this session - a Damian Marley disc whose TOC was misread as 2 tracks instead of 13 (with the second of those also corrupt), and a Jon Bon Jovi disc that failed mid-track-1 - both of which slipped past the existing zero-byte guard and produced a clean-looking summary that didn't reflect what was actually on disk.
  - **Detected track count is now shown before ripping starts** (`Tracks detected: N` in the "Ready to rip" confirmation banner), read from cyanrip's own disc TOC and independent of whether MusicBrainz/CDDB identified the album. A count of 2 or fewer is flagged so a user who knows the album can catch a garbled TOC read (the disconnect-during-discovery failure shape) before walking away, instead of only discovering it after the whole pipeline has already run.
  - **Post-rip validation now checks file integrity, not just size.** The Step 1 post-cyanrip check and Step 2's verify-output check both previously accepted any nonzero-size file as "ripped" - a mid-write disconnect can leave a nonzero-size file that still isn't valid audio (fails `metaflac --test`). Both now reuse the same `Test-TrackIntegrity` check the resume-detection path already trusted, closing the gap that let a corrupt track sail through renaming and tagging into a false "COMPLETE!".
  - **A corrupt track is now flagged even when cyanrip's own exit code is 0** - a dropped USB connection doesn't always make cyanrip itself report failure, so this check runs unconditionally after the rip rather than only inside the existing non-zero-exit-code warning branch.
  - **The completion banner now reads `COMPLETE WITH WARNINGS` instead of `COMPLETE!`** whenever any track was corrupt, skipped, or marked a data error - previously the banner was unconditionally green regardless of what the FILE SUMMARY below it reported. New `Corrupt/zero-byte` line added to the FILE SUMMARY and the session log, matching the existing `Skipped`/`Data errors` lines.
  - Fixed a latent reset bug found while wiring the banner gate: `$script:SkippedTracks` and `$script:DataErrorTracks` were never reset when a queue item hit the "all tracks already valid, skip rip" path, so a `-ProcessQueue` run could carry one album's stale warning counts into the next, clean album's summary.
  - The "nothing usable ripped" error message no longer tells the user to manually delete the output folder - it now points back at the existing resume feature (see README "Resuming Interrupted Rips"), which already cleans up corrupt/zero-byte files itself on re-run.
  - README.md: new "Recovering from a Flaky Drive/USB Connection" section under "Resuming Interrupted Rips".

**Testing status:** **verified by PowerShell tokenizer parse-check only.** No disc was ripped and no real USB disconnect was reproduced against this code - the track-count banner, the integrity-based post-rip/verify checks, the exit-code-independent corrupt warning, and the `COMPLETE WITH WARNINGS` gating have not been exercised live. The failure shapes this targets are real (taken directly from the user's pasted output), but the fix itself is unvalidated against a live repeat of either.

### Added (2)
- **New `continue-rip-audio.ps1` script - a dedicated, step-based way to resume an interrupted `rip-audio.ps1` run**, mirroring the `ripdisc` project's `continue-rip.ps1` pattern. Requested directly by the user as a follow-up to the flaky-drive/USB work above.
  - Four steps, same numbering as `rip-audio.ps1`'s own tracker: `1`/`rip`, `2`/`verify`, `3`/`coverart`, `4`/`open`. `-FromStep` picks where to start (number or name); omit it for an interactive menu.
  - **Unlike `ripdisc`'s continue script, this one's rip step can genuinely be resumed** - cyanrip's `-l` flag rips just the missing/invalid track numbers - but it still needs the disc back in the drive, since `ripdisc`'s Step 1 (MakeMKV) and this project's Step 1 (cyanrip) aren't equivalent: only `ripdisc`'s is fully disc-independent once past Step 1.
  - Per-step prerequisite checks (e.g. asking for `coverart` with no audio files yet suggests `rip` instead) and a retry-hint suggestion on failure (`.\continue-rip-audio.ps1 -Album ... -FromStep N`), same shape as `ripdisc`'s equivalents.
  - Reuses `rip-audio.ps1`'s helpers largely verbatim to minimize drift: `Test-TrackIntegrity`, `Get-DiscTrackCount`, `Test-DriveReady`, `Start-CyanripWithErrorDetection`, the full cover-art source chain (Cover Art Archive -> MusicBrainz/CAA -> iTunes -> Deezer), and the output-drive prompt-then-validate pattern from earlier in this same date's entries.
  - **Deliberately not ported** - documented in the script header and README, not a silent gap: multi-release MusicBrainz disambiguation, CDDB/Discogs fallback, generic-name fallback, `-Queue`/`-ProcessQueue`, `-RequireMusicBrainz`, AccurateRip reporting, the `search-metadata.ps1` handoff, the Mp3tag fallback prompt, and `rip-audio.ps1`'s live busy-drive process scan (this script does a single-check drive validation instead). None of these matter for continuing an album whose identity this script already knows from its existing output folder.
  - README.md: new `continue-rip-audio.ps1` section with usage examples and the same scope caveats.

**Testing status:** **verified by PowerShell tokenizer parse-check only**, plus a manual ASCII-only check on the new file. **Not exercised against a real disc or a real interrupted rip at any step.** The ported functions have prior live validation from their original use in `rip-audio.ps1`, but this script's own control flow around them - the resume-track-list computation, step-skip logic, prerequisite checks - is unvalidated. One bug was caught and fixed before commit: `Complete-CurrentStep` was being called twice for Step 1 on the "all tracks already valid" path, which would have double-listed step 1 in the completion summary.

- **`continue-rip-audio.ps1` gained an explicit `-FromTrack <N>` override on its rip step, and its two drifted helper functions were re-synced with `rip-audio.ps1`.** The script's own header comment states these helpers must be "kept in sync"; the branch was cut before three fixes landed on master the same day, so both had gone stale before the script ever merged.
  - **`-FromTrack <N>` bypasses the automatic missing/invalid-track file scan entirely** and rips track `N` through the disc's actual last track via cyanrip's `-l` flag (the same mechanism auto-detection already used), trusting the caller's own knowledge of where a previous attempt broke over re-deriving it from files on disk. Motivating case, pasted by the user: a rip of "Destination Anywhere" by Jon Bon Jovi that crashed at track 9, leaving 8 good tracks plus stray files behind - where the crash message had already named the exact failed track, so re-scanning to rediscover it is both slower and less trustworthy than just being told.
  - **The total track count is always re-queried live from the disc (`-Fresh`), never read from a cached cue file** - specifically because the same flaky connection that caused the original failure can also have corrupted that cue file's own track count. Same reasoning as the `-Fresh` switch added to `rip-audio.ps1` above.
  - **A mismatch against what's on disk warns but never blocks.** If the tracks expected at `1..N-1` aren't found (or fail their integrity check), a warning names the missing ones and the rip proceeds anyway - `-FromTrack` is an explicit instruction and wins either way. The warning exists so a mistyped track number surfaces before a long rip rather than after it. Ignored with a note when `-FromStep` resolves to anything other than `rip`.
  - **`Test-TrackIntegrity` carried the exact `metaflac --test` bug fixed in `rip-audio.ps1` above** - a nonexistent metaflac option that always printed `unrecognized option` and exited 1 regardless of file validity, so every FLAC would have been classified corrupt. It went uncaught here only because this script has never been run against a real interrupted rip. Now calls `flac --test --totally-silent`, matching the fix on `rip-audio.ps1` exactly.
  - **`Get-DiscTrackCount` gained the same `-Fresh` switch** added to `rip-audio.ps1`'s copy above, required by `-FromTrack`.
  - **Deliberately not ported:** `rip-audio.ps1`'s `Test-CyanripCrashExit` helper and its broadened resume `while` loop. Those restructure this script's single-shot `Start-CyanripWithErrorDetection` invocation and are out of scope here - flagged as a follow-up rather than silently skipped, so this script still won't auto-resume a native cyanrip crash the way `rip-audio.ps1` now does.
  - README.md: two new `-FromTrack` usage examples and a parameter description covering the scan-bypass, the live track-count re-query, and the warn-don't-block behaviour.

**Testing status:** `Parser::ParseFile` reports 0 errors; whole file confirmed ASCII-only with no BOM. The fixed `Test-TrackIntegrity` was extracted from the real file and run against all 15 real FLACs at `F:\Music\Damian Marley\Welcome to Jamrock` - the same album used to find and validate the `rip-audio.ps1` fix above - all 15 correctly return `$true`. The `-FromTrack` track-list arithmetic was unit-tested in isolation across the range and its edges. **One real bug was caught that way and fixed:** PowerShell ranges descend, so `1..0` yields `@(1, 0)` rather than an empty set - `-FromTrack 1` (a valid rip-the-whole-disc invocation) would have "expected" tracks 1 and 0, printed `tracks 1-0 are assumed already present`, and warned about both. Now guarded on `-gt 1` with a distinct message for the whole-disc case. **NOT done:** no real disc, no real interrupted rip, and no live `cyanrip -I` query has been exercised end-to-end through this script's actual control flow - the same gap already disclosed for the script as a whole above. This neither introduces that gap nor closes it.

- **New `-CheckEbayPrice` switch on `rip-audio.ps1`** - prints a clickable eBay UK sold-listings search URL for the ripped album in the FILE SUMMARY, so you can check what the physical disc might be worth. Direct user request, with the exact filter combination they already use manually supplied as an example URL.
  - New `Get-EbaySoldListingsUrl` helper builds `https://www.ebay.co.uk/sch/i.html` with `_nkw=<artist> <album> CD album` (URL-encoded), `_sacat=0`, `_from=R40`, `LH_BIN=1` (Buy It Now only), `LH_ItemCondition=4` (Very Good or better), `LH_PrefLoc=1` (UK only), `rt=nc`, `LH_Sold=1` (sold listings only) - matching the user-supplied example query string exactly.
  - Off by default - purely a convenience for deciding what to do with a physical disc after ripping it, not part of the rip pipeline itself.
  - README.md: new parameter row and usage example.

**Testing status:** verified by PowerShell tokenizer parse-check (0 errors) and a manual ASCII-only check on the diff. The built URL was not opened in a browser this session to confirm it renders eBay's intended filtered search - only the string construction itself was checked against the user's example.

## 2026-08-26 (once more)

### Added
- **`rip-audio.ps1`'s Mp3tag fallback now automatically opens Mp3tag's own "Discogs Artist + Album" Tag Source dialog**, pre-filled from the loaded tags, instead of leaving the user to click through the menu themselves - matches the user's own stated habitual workflow (select all, Tag Sources, Discogs Artist + Album). Stops deliberately at the pre-filled "Search by" dialog rather than auto-clicking "Next >", so the artist/album can be reviewed/corrected before the actual Discogs query goes out.
  - Mp3tag has **no command-line switch for this** - confirmed by grepping the full command-line changelog history of the actually-installed version (3.32), which only ever covers loading files/folders on startup, never triggering a Tag Source. Driven via `System.Windows.Automation` (find the Mp3tag window, since it's single-instance and can hand off to a different PID than the one just launched) + `SendKeys` (select all, open the menu via its Alt+S mnemonic, navigate down to the target item, select).
  - New `Invoke-Mp3tagDiscogsLookup` function, called immediately after the existing `Start-Process $mp3tagPath` launch. Fully best-effort: every failure path (assemblies won't load, window never appears, foreground can't be acquired) logs and returns without throwing, so a failure here can only fall back to the pre-existing "Mp3tag opens, user drives it manually" behaviour - it can never break or block the rest of the script.
  - `SetForegroundWindow` from a background process is sometimes blocked by Windows' anti-focus-stealing protection (reproduced live during testing) - worked around with the standard `AttachThreadInput` technique.
  - **Documented fragility, not hidden risk**: Mp3tag's Tag Sources menu isn't exposed via standard Windows accessibility APIs (confirmed live - no `MenuBar` control, and no UIA-visible popup even while genuinely open), so the target item can only be reached by *position* in the menu (4 presses of Down from the top = the 5th item = "Discogs Artist + Album" on this installation's current Tag Sources configuration), not by name. Reordering, adding, or removing a Tag Source above it in Mp3tag's own settings will silently move this and make the automation open the wrong search - there's no way to detect that mismatch programmatically. Documented directly in the code comment next to the position constant.

**Testing status:** parses clean, all added lines ASCII-only. **Verified end-to-end against the real, installed Mp3tag (v3.32)** - not simulated: launched cold (no pre-existing window) against a real ripped folder, confirmed the window is found (~0.5s), foreground is acquired, and the automation lands correctly on the pre-filled "Discogs Artist + Album" search dialog with the right Artist/Album values, exactly matching the manual workflow it replaces. Tested against two different real folders. The one thing not exercised: clicking past "Next >" into actual live search results (deliberately out of scope - that step is left for the user).

## 2026-08-26 (yet again)

### Added
- **Discogs as a 4th metadata source in `search-metadata.ps1`**, preferred over the existing MusicBrainz > Deezer > iTunes chain when it returns a track count that actually matches the local files. Requires a free `DISCOGS_TOKEN` environment variable (Personal Access Token from discogs.com/settings/developers) — silently skipped and falls back to the existing behaviour unchanged when unset, so nothing breaks for anyone who doesn't set one up.
  - New `Search-Discogs` function: queries `/database/search` (artist + release title), prefers CD-format candidates when the initial result set includes non-CD editions (Discogs commonly returns cassette/vinyl/box-set entries alongside CD ones for the same title), then fetches full release details for up to 3 candidates specifically to check track count — Discogs's search response doesn't expose track count directly, unlike the other three sources.
  - **Track-count verification is deliberate, not incidental**: a Discogs match whose track count doesn't equal the local rip's is demoted below MusicBrainz rather than trusted, on the theory that a title/artist match with the wrong count usually means a different (often partial) edition matched — the exact failure mode that mismatched a "Part 2 only" release to a complete work earlier this same session via Deezer. Discogs is still surfaced in the confirmation screen's "Sources found" list either way, for visibility.
  - Wired into `Search-AllSources`'s merge logic for every field (artist, album, date, genre, track count, track titles, artwork), and into `Show-MetadataComparison`'s source summary.
  - README updated: setup instructions, workflow steps, and all source-list mentions (including `-EmbedOnly`'s artwork-only search path, which already called `Search-AllSources` and so picks this up for free).

**Testing status:** parses clean, all added lines ASCII-only. Validated against the **real, live Discogs API** (unauthenticated works too, just at a lower rate limit — sufficient for testing): searched "How to Dismantle an Atomic Bomb" by U2, correctly filtered 5 results down to 3 CD-format candidates (the other 2 were cassette editions), found the exact 11-track match with real song titles ("Vertigo", "Miracle Drug", etc.), genre, year, and artwork URL. Separately verified the mismatch-handling path: forcing an impossible track count (99) correctly exhausted all 3 candidate fetches and fell back to the first examined release rather than erroring. Not yet tested with a real `DISCOGS_TOKEN` set (none was available this session) or through the actual interactive `search-metadata.ps1` confirmation flow end-to-end - the underlying search/merge logic is verified against live data, the surrounding script wiring is not yet exercised for real.

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
