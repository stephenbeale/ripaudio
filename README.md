# RipAudio

PowerShell script for automated audio CD ripping using cyanrip.

## Overview

This repository contains a PowerShell script for ripping audio CDs to various lossless and lossy formats using cyanrip, with automatic MusicBrainz metadata lookup.

## Features

- **Auto-discovery** of album and artist from disc via MusicBrainz API (no arguments needed)
- **Automated ripping** using cyanrip with MusicBrainz integration
- **4-step processing workflow** with progress tracking (rip, verify, cover art, open)
- **Multiple output formats** (FLAC, MP3, Opus, AAC, WAV, ALAC) with simultaneous encoding
- **Queue mode** for batch ripping multiple discs sequentially
- **CDDB fallback** when MusicBrainz has no match (gnudb.org)
- **Mp3tag fallback** prompts to open Mp3tag for manual tagging when all automated sources fail
- **AccurateRip verification** with per-track reporting
- **Cover art** from 4 sources: Cover Art Archive, MusicBrainz+CAA, iTunes, Deezer
- **Artist/Album organization** with flexible directory structure
- **Path length validation** against Windows MAX_PATH (260 chars)
- **Comprehensive error handling** with recovery guidance
- **Session logging** for debugging and recovery
- **Drive readiness checks** before operations
- **Interactive prompts** for confirmation and conflict resolution
- **Window title management** for tracking concurrent operations
- **Real-time output** from cyanrip (streamed to console during rip, not buffered)
- **Resume interrupted rips** - detects completed tracks and offers to rip only missing ones
- **Automatic disc ejection** after successful rip
- **Console close protection** during rip to prevent accidental closure

## Quick Start

```powershell
# Insert disc and rip — album and artist auto-detected from MusicBrainz
.\rip-audio.ps1

# Override with specific album name
.\rip-audio.ps1 -album "Abbey Road"

# Rip with artist specified
.\rip-audio.ps1 -album "Abbey Road" -artist "The Beatles"

# Rip to MP3 format
.\rip-audio.ps1 -album "Abbey Road" -artist "The Beatles" -format mp3
```

## Requirements

- **Windows OS**
- **cyanrip** installed and available in PATH (install via `winget install cyanrip`)
- **PowerShell 5.1+**

## Installation

1. Install cyanrip:
   ```powershell
   winget install cyanrip
   ```

2. Clone or download this repository

3. Run the script from PowerShell

## Usage

```
.\rip-audio.ps1 [-album <string>] [-artist <string>] [-Drive <string>] [-OutputDrive <string>] [-format <string>] [-Quality <int>] [-RequireMusicBrainz] [-Queue] [-ProcessQueue]
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-album` | No | - | Album name (auto-detected from disc if omitted) |
| `-artist` | No | - | Artist name (affects output directory structure) |
| `-Drive` | No | auto-detect | CD drive letter (auto-detected if only one optical drive present) |
| `-OutputDrive` | No | system drive | Output drive letter (defaults to `$env:SystemDrive`, e.g. `C:`) |
| `-format` | No | flac | Output format(s), comma-separated (flac, mp3, opus, aac, wav, alac) |
| `-Quality` | No | 0 | Bitrate in kbps for lossy formats (32-320, e.g. 320 for mp3) |
| `-RequireMusicBrainz` | No | - | Stop if disc not found in MusicBrainz (no fallback to generic names) |
| `-Queue` | No | - | Add album to rip queue instead of ripping immediately |
| `-ProcessQueue` | No | - | Process all entries in the rip queue sequentially |

### Examples

**Rip a CD with auto-discovery (no arguments needed):**
```powershell
.\rip-audio.ps1
# Queries disc, detects artist/album from MusicBrainz, prompts if multiple releases found
```

**Rip a CD to FLAC (default):**
```powershell
.\rip-audio.ps1 -album "Dark Side of the Moon" -artist "Pink Floyd"
```

**Rip to MP3:**
```powershell
.\rip-audio.ps1 -album "Thriller" -artist "Michael Jackson" -format mp3
```

**Rip to Opus (efficient lossy):**
```powershell
.\rip-audio.ps1 -album "OK Computer" -artist "Radiohead" -format opus
```

**Rip from a different drive:**
```powershell
.\rip-audio.ps1 -album "Kind of Blue" -artist "Miles Davis" -Drive G:
```

**Rip to a different output drive:**
```powershell
.\rip-audio.ps1 -album "Blue Train" -artist "John Coltrane" -OutputDrive F:
```

**Rip compilation/various artists (no artist folder):**
```powershell
.\rip-audio.ps1 -album "Now That's What I Call Music 100"
```

**Rip to MP3 at 320kbps:**
```powershell
.\rip-audio.ps1 -album "Thriller" -artist "Michael Jackson" -format mp3 -Quality 320
```

**Rip to Opus at 128kbps:**
```powershell
.\rip-audio.ps1 -album "OK Computer" -artist "Radiohead" -format opus -Quality 128
```

**Rip to FLAC and MP3 simultaneously:**
```powershell
.\rip-audio.ps1 -album "Rumours" -artist "Fleetwood Mac" -format "flac,mp3"
```

**Rip to FLAC and MP3 at 320kbps simultaneously:**
```powershell
.\rip-audio.ps1 -album "Rumours" -artist "Fleetwood Mac" -format "flac,mp3" -Quality 320
```

**Require MusicBrainz metadata (stop if not found):**
```powershell
.\rip-audio.ps1 -album "Abbey Road" -artist "The Beatles" -RequireMusicBrainz
```

**Rip a double album (one disc at a time):**
```powershell
# With auto-discovery — disc number detected automatically
.\rip-audio.ps1 -Drive G:
# Detects: Led Zeppelin - Mothership Disc 1

# Or override manually:
.\rip-audio.ps1 -album "Mothership Disc 1" -artist "Led Zeppelin" -Drive G:
.\rip-audio.ps1 -album "Mothership Disc 2" -artist "Led Zeppelin" -Drive G:
```

**Queue multiple albums then rip them all:**
```powershell
# Add albums to the queue
.\rip-audio.ps1 -album "Rumours" -artist "Fleetwood Mac" -Queue
.\rip-audio.ps1 -album "Abbey Road" -artist "The Beatles" -Queue
.\rip-audio.ps1 -album "Kind of Blue" -artist "Miles Davis" -Queue

# Process the queue -- prompts to insert each disc
.\rip-audio.ps1 -ProcessQueue
```

**Queue with specific format and quality:**
```powershell
.\rip-audio.ps1 -album "Thriller" -artist "Michael Jackson" -format mp3 -Quality 320 -Queue
```

## Directory Structure

### With Artist

```
E:\Music\Pink Floyd\Dark Side of the Moon\
    01 - Speak to Me.flac
    02 - Breathe.flac
    03 - On the Run.flac
    ...
```

### Without Artist (compilations, etc.)

```
E:\Music\Now That's What I Call Music 100\
    01 - Track Name.flac
    02 - Another Track.flac
    ...
```

## Processing Steps

The script executes a 4-step workflow:

1. **cyanrip Rip** - Rip audio CD using cyanrip with MusicBrainz lookup
2. **Verify Output** - Check that audio files were created successfully
3. **Cover Art** - Download album cover art (CAA > MusicBrainz+CAA > iTunes > Deezer) and embed into FLAC files
4. **Open Directory** - Open output folder for verification

Each step is tracked, and the system shows completion status and provides recovery guidance if errors occur.

## Queue Mode

Queue mode lets you line up multiple albums for sequential ripping. The queue is stored in `C:\Music\rip-queue.json` with file locking for concurrent safety.

- **`-Queue`** adds an entry (album, artist, format, quality) to the queue file
- **`-ProcessQueue`** reads the queue and processes each entry one at a time
  - Prompts to insert each disc: `Insert disc for [artist - album], press Enter to continue (S to skip, Q to quit)`
  - Press **S** to skip an entry, **Q** to quit the queue
  - Interactive prompts (MusicBrainz unreachable, existing directory, multiple releases) auto-continue in queue mode
  - Shows aggregate summary at the end (processed, failed, skipped counts)

## Auto-Discovery

When `-album` is omitted, the script automatically detects disc metadata before ripping:

1. Queries the disc with `cyanrip -I` to get the disc ID and metadata
2. Parses Album, Artist, Disc number, and Release ID directly from cyanrip output (no extra API call needed)
3. If multiple MusicBrainz releases match, prompts you to select one
4. For multi-disc albums (e.g. "Mothership"), appends `Disc N` to the album name
5. Displays: `Detected: Led Zeppelin - Mothership Disc 1`
6. If discovery fails (stub, API unreachable, no match), prompts for album name manually

Discovery is skipped when:
- `-album` is provided (user override)
- `-ProcessQueue` mode (album/artist come from queue entry)

## Metadata Fallback Chain

When ripping, the script uses multiple sources to ensure track names and metadata:

1. **MusicBrainz** (via cyanrip) - Primary source, automatic lookup by disc ID
2. **CDDB** (gnudb.org) - Fallback when MusicBrainz has no match; uses TOC-based disc ID lookup, then text search
3. **search-metadata.ps1** - Post-rip metadata search across MusicBrainz, iTunes, and Deezer APIs
4. **Mp3tag prompt** - When all automated sources fail, prompts to open Mp3tag desktop app for manual tagging
5. **Generic names** - Last resort: tracks named `01 - Track 01`, `02 - Track 02`, etc.

If a disc is not found in MusicBrainz, the script will:
- Search CDDB by disc ID (computed from the disc's table of contents)
- If that fails, search CDDB by album name
- Show a preview of the CDDB results (artist, album, first 5 tracks) before proceeding
- Run `search-metadata.ps1` for additional API-based search
- If tracks still have generic names, prompt to open Mp3tag (auto-detected from Program Files, 30s auto-Yes timeout)
- Use `-RequireMusicBrainz` to stop instead of falling back

## Cover Art Sources

Cover art is downloaded using a sequential fallback chain:

1. **Cover Art Archive** - Direct lookup using release ID from the MusicBrainz cue file
2. **MusicBrainz + CAA** - Search MusicBrainz by artist/album, then fetch from Cover Art Archive
3. **iTunes Search API** - 600x600 artwork
4. **Deezer API** - Up to 1000x1000 artwork

Downloaded art is saved as `Front.jpg` in the album folder and embedded into FLAC files via metaflac.

## AccurateRip Verification

After ripping, the script parses cyanrip's AccurateRip output and reports:

- **Disc-level status**: found, not found, error, mismatch, or disabled
- **Per-track results**: v1/v2 checksums and confidence levels
- **Summary**: "N/M tracks ripped accurately" and "N/M tracks ripped partially accurately"

Results are displayed in green (all verified) or yellow (partial), logged to the session log, and appended to the window title (`- AR PARTIAL` if not all tracks verified).

## Resuming Interrupted Rips

If a rip crashes or is cancelled mid-way, just re-run the **same command** with the disc still in the drive. The script automatically detects the partial work and offers to pick up where it left off — no extra flags needed.

```powershell
# Original rip command (ran, then crashed after track 3)
.\rip-audio.ps1

# Re-run — script detects tracks 1–3 exist, offers to resume from track 4
.\rip-audio.ps1
```

```powershell
# Works the same way when album/artist were specified
.\rip-audio.ps1 -album "Abbey Road" -artist "The Beatles"

# Re-run after a crash
.\rip-audio.ps1 -album "Abbey Road" -artist "The Beatles"
```

**What happens on re-run:**

1. The script checks existing audio files in the output folder against the disc's total track count (from the `.cue` file or `cyanrip -I`)
2. Each existing track is validated (FLAC: `metaflac --test`, others: file size > 10KB)
3. A summary shows which tracks are valid and which are missing:

```
Valid: 3/12 tracks (1, 2, 3)
Missing: 9 tracks (4, 5, 6, 7, 8, 9, 10, 11, 12)

  [1] Resume (rip tracks 4,5,6,7,8,9,10,11,12 only)
  [2] Re-rip all tracks from scratch
  [3] Abort
```

**Menu options:**
- **Resume** — rip only the missing/invalid tracks (passes `-l` to cyanrip)
- **Re-rip** — discard existing files and rip all tracks from scratch
- **Abort** — cancel without changing anything

**Edge cases:**
- **All tracks valid** — offers to skip the rip entirely or re-rip
- **No valid tracks** — falls back to the standard Continue/Abort menu
- **Can't determine track count** (no cue file, disc query fails) — falls back to Continue/Abort
- **Queue mode** — auto-resumes when missing tracks are detected

## MusicBrainz Release Selection

When multiple MusicBrainz releases match a disc, the script prompts you to select the correct one:

```
Select a release:
  1: Tracy Chapman (XE) (1988-04-08)
  2: Tracy Chapman (US) (1988-04-05)
  3: Tracy Chapman (US) (1988)
  4: Tracy Chapman (US) (1988-04-05)
  5: Tracy Chapman (ZA) (1999)

Enter release number (1-5): _
```

This ensures proper track names, album art, and metadata for your specific release (region, pressing date, etc.).

**Double albums:** For multi-disc sets, auto-discovery detects the disc position and appends `Disc N` to the album name automatically (e.g. "Mothership Disc 1", "Mothership Disc 2"). If providing `-album` manually, use different values for each disc to create separate output folders. In queue mode, release 1 is auto-selected.

## Logging

Session logs are saved to `C:\Music\logs\{artist}_{album}_{timestamp}.log`

Logs include:
- All processing steps
- File operations
- Error messages
- Recovery information

## Error Handling

If an error occurs:
- Window title shows `-ERROR` suffix
- Completed steps are displayed in green
- Remaining steps are listed with manual instructions
- Relevant directory is opened for inspection
- Log file location is provided

## Supported Formats

| Format | Extension | Description |
|--------|-----------|-------------|
| `flac` | .flac | Lossless compression (default) |
| `mp3` | .mp3 | Lossy, widely compatible |
| `opus` | .opus | Efficient lossy, good quality/size ratio |
| `aac` | .m4a | Lossy, Apple-compatible |
| `wav` | .wav | Uncompressed lossless |
| `alac` | .m4a | Apple Lossless |

## cyanrip

This script uses [cyanrip](https://github.com/cyanreg/cyanrip), a feature-rich audio CD ripper with:

- Automatic MusicBrainz metadata lookup
- AccurateRip verification
- CDDB support
- Multiple output format support
- Paranoia-based secure ripping

### Key cyanrip Options Used

- `-D` : Output directory
- `-o` : Output format(s)
- `-d` : Drive specification
- `-s` : Drive read offset (default: 0)
- `-b` : Bitrate for lossy formats (kbps)
- `-R` : Release selection index (for multiple MusicBrainz matches)
- `-l` : Track list to rip (comma-separated, used for resume)
- `-I` : Print disc info without ripping (used to detect track count)

## search-metadata.ps1

Standalone script that scans a folder of audio files, searches 3 metadata sources (MusicBrainz, iTunes, Deezer), shows a comparison for confirmation, then applies tags, downloads cover art, and renames files.

### Usage

```
.\search-metadata.ps1 -Path <folder> [-Artist <string>] [-Album <string>] [-SkipRename] [-SkipCoverArt] [-Force] [-Recurse] [-DryRun] [-EmbedOnly]
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Path` | Yes | - | Folder containing audio files (or parent folder with `-Recurse`) |
| `-Artist` | No | - | Artist name hint (auto-detected from tags/folder; ignored with `-Recurse`) |
| `-Album` | No | - | Album name hint (auto-detected from tags/folder; ignored with `-Recurse`) |
| `-SkipRename` | No | - | Don't rename files |
| `-SkipCoverArt` | No | - | Don't download cover art |
| `-Force` | No | - | Skip confirmation prompt (implied with `-Recurse`) |
| `-Recurse` | No | - | Process all subdirectories containing FLAC files |
| `-DryRun` | No | - | Preview all changes without writing to disk |
| `-EmbedOnly` | No | - | Only embed cover art into FLAC files (skip metadata search, tagging, renaming) |

### Examples

```powershell
# Search and apply metadata to a folder
.\search-metadata.ps1 -Path "C:\Music\Unknown Album"

# With artist/album hints
.\search-metadata.ps1 -Path "C:\Music\rip" -Artist "Pink Floyd" -Album "The Wall"

# Skip rename, auto-confirm
.\search-metadata.ps1 -Path "C:\Music\rip" -SkipRename -Force

# Tags only, no artwork or renaming
.\search-metadata.ps1 -Path "C:\Music\rip" -SkipRename -SkipCoverArt

# Process all album folders under a directory
.\search-metadata.ps1 -Path "C:\Music" -Recurse

# Recurse with no renaming
.\search-metadata.ps1 -Path "C:\Music\Pink Floyd" -Recurse -SkipRename

# Preview what would change without writing anything
.\search-metadata.ps1 -Path "C:\Music\Unknown Album" -DryRun

# Dry run across all album folders
.\search-metadata.ps1 -Path "C:\Music" -Recurse -DryRun

# Embed existing cover art into FLAC files (skip metadata search/tagging/renaming)
.\search-metadata.ps1 -Path "C:\Music\Tracy Chapman\Tracy Chapman" -EmbedOnly

# Embed art across entire library
.\search-metadata.ps1 -Path "C:\Music" -Recurse -EmbedOnly

# Dry run — see what would be embedded
.\search-metadata.ps1 -Path "C:\Music\Tracy Chapman\Tracy Chapman" -EmbedOnly -DryRun
```

### 6-Step Workflow (default)

1. **Scan files** - Read existing tags via metaflac, identify gaps
2. **Search metadata** - Query MusicBrainz, iTunes, Deezer; merge best results
3. **Confirm changes** - Show side-by-side comparison, user approves or declines (auto-Yes in 30s)
4. **Apply tags** - Write ARTIST, ALBUM, TITLE, TRACKNUMBER, DATE, GENRE via metaflac
5. **Cover art** - Download best artwork (Deezer 1000x1000 > iTunes 600x600 > CAA) and embed into FLAC files
6. **Rename files** - Rename to `## - Title.flac` format

### 2-Step Workflow (`-EmbedOnly`)

1. **Scan files** - Read existing tags, identify FLAC files
2. **Cover art** - Find existing art on disk, or search online and prompt to confirm, then embed into all FLACs

With `-EmbedOnly`, if no art exists on disk the script searches MusicBrainz/iTunes/Deezer for artwork. Matching results auto-proceed; mismatches prompt for confirmation (default No). In batch/recurse mode, mismatches are auto-skipped.

### Metadata Source Priority

- **Artist/Album/Date/Tracks**: MusicBrainz > Deezer > iTunes
- **Genre**: Deezer > iTunes
- **Cover art**: Deezer (1000x1000) > iTunes (600x600) > Cover Art Archive
- **Track titles**: MusicBrainz > Deezer

### Artist Mismatch Detection

When search results return a different artist than expected (e.g. searching for a Cher album but iTunes returns Rolling Stones), the script detects the mismatch using fuzzy matching:

- **Batch mode** (`-Recurse`): auto-skips the album (safe default, never applies wrong artist's metadata)
- **Interactive mode**: shows a `WARNING: Artist mismatch` message and prompts `Apply anyway? [y/N]` (default No)
- **No folder artist**: check is skipped (can't compare if the expected artist is unknown)

### Undo Support

All destructive operations are logged with structured `UNDO_*` entries in the session log file, enabling reversal via `undo-metadata.ps1`:

- **UNDO_BASELINE** - original tag values before overwriting (per file)
- **UNDO_RENAME** - original filename before renaming
- **UNDO_COVER_ART** - downloaded cover art file path and whether art pre-existed

## undo-metadata.ps1

Reverses changes made by `search-metadata.ps1` using the structured undo data in its log file.

### Usage

```
.\undo-metadata.ps1 -LogFile <path> [-DryRun]
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-LogFile` | Yes | - | Path to the search-metadata log file (supports wildcards) |
| `-DryRun` | No | - | Preview what would be undone without making changes |

### 4-Step Workflow

1. **Parse log** - scan for `UNDO_BASELINE`, `UNDO_RENAME`, `UNDO_COVER_ART` entries
2. **Preview** - show what will be undone (renames reversed, tags restored, cover art removed)
3. **Confirm** - `Apply undo? [Y/n]` prompt
4. **Execute** - reverse renames first (restore original filenames), then restore original tags, then remove newly downloaded cover art

### Examples

```powershell
# Preview what would be undone (dry run)
.\undo-metadata.ps1 -LogFile "C:\Music\logs\search-metadata_20260224_*.log" -DryRun

# Execute undo
.\undo-metadata.ps1 -LogFile "C:\Music\logs\search-metadata_20260224_143052.log"
```

## audit-metadata.ps1

Scans album folders for missing or incomplete metadata, copies flagged albums to a staging directory, and optionally processes them with `search-metadata.ps1` — all in a single pipeline with continue/exit checkpoints between stages.

### Usage

```
.\audit-metadata.ps1 -Path <folder> [-OutputPath <folder>] [-ReportOnly]
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Path` | Yes | - | Root music folder to scan (e.g. `C:\Music`) |
| `-OutputPath` | No | `C:\Music\needs-update` | Staging directory for flagged albums |
| `-ReportOnly` | No | - | Print report and write CSV log without copying or processing |

### 4-Step Pipeline

1. **Discover album folders** — find all directories containing FLAC files
2. **Audit metadata** — check each album for missing tags and cover art
3. **Copy flagged albums to staging** — prompted: `N albums flagged. Copy to staging? [Y/n]` (auto-Yes in 30s)
4. **Search & apply metadata** — prompted: `Search & apply metadata to N flagged albums? [Y/n]` (auto-Yes in 30s), then runs `search-metadata.ps1 -Path <staging> -Recurse`

Prompts auto-proceed after 30 seconds with no input. Press `N` at any prompt to stop the pipeline at that point.

With `-ReportOnly`: only steps 1-2 run, a CSV is written, no prompts or processing.

### Checks Performed

1. **Track titles** — flags albums with `Unknown track`, `Track N`, or empty titles
2. **Album-level tags** — flags if Artist, Album, Date, or Genre are missing across all tracks
3. **Cover art** — flags if no `Front.*`, `Cover.*`, or `Folder.*` image exists

### Examples

```powershell
# Report only — see what needs attention without copying or processing
.\audit-metadata.ps1 -Path "C:\Music" -ReportOnly

# Full pipeline — audit, copy, then search & apply metadata
.\audit-metadata.ps1 -Path "C:\Music"

# Copy to a custom staging directory
.\audit-metadata.ps1 -Path "C:\Music" -OutputPath "D:\staging"
```

## Related Projects

- [ripdisc](https://github.com/stephenbeale/ripdisc) - DVD/Blu-ray ripping toolkit using MakeMKV and HandBrake

## Contributing

Contributions are welcome! Please follow the existing code style and patterns.

## License

This project is provided as-is for personal use.

## Notes

- This tool is designed for backing up legally owned physical media
- Ensure you have the legal right to rip any disc you process
- cyanrip must be properly installed and available in PATH
