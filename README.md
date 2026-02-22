# RipAudio

PowerShell script for automated audio CD ripping using cyanrip.

## Overview

This repository contains a PowerShell script for ripping audio CDs to various lossless and lossy formats using cyanrip, with automatic MusicBrainz metadata lookup.

## Features

- **Automated ripping** using cyanrip with MusicBrainz integration
- **3-step processing workflow** with progress tracking
- **Multiple output formats** (FLAC, MP3, Opus, AAC, WAV, ALAC)
- **Artist/Album organization** with flexible directory structure
- **Comprehensive error handling** with recovery guidance
- **Session logging** for debugging and recovery
- **Drive readiness checks** before operations
- **Interactive prompts** for confirmation and conflict resolution
- **Window title management** for tracking concurrent operations
- **Automatic disc ejection** after successful rip

## Quick Start

```powershell
# Rip an album (will use MusicBrainz for metadata)
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
.\rip-audio.ps1 -album <string> [-artist <string>] [-Drive <string>] [-OutputDrive <string>] [-format <string>]
```

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-album` | Yes | - | Album name |
| `-artist` | No | - | Artist name (affects output directory structure) |
| `-Drive` | No | E: | CD drive letter |
| `-OutputDrive` | No | E: | Output drive letter |
| `-format` | No | flac | Output format(s), comma-separated (flac, mp3, opus, aac, wav, alac) |
| `-Quality` | No | 0 | Bitrate in kbps for lossy formats (32-320, e.g. 320 for mp3) |
| `-RequireMusicBrainz` | No | - | Stop if disc not found in MusicBrainz (no fallback to generic names) |

### Examples

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

The script executes a 3-step workflow:

1. **cyanrip Rip** - Rip audio CD using cyanrip with MusicBrainz lookup
2. **Verify Output** - Check that audio files were created successfully
3. **Open Directory** - Open output folder for verification

Each step is tracked, and the system shows completion status and provides recovery guidance if errors occur.

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

### 6-Step Workflow

1. **Scan files** - Read existing tags via metaflac, identify gaps
2. **Search metadata** - Query MusicBrainz, iTunes, Deezer; merge best results
3. **Confirm changes** - Show side-by-side comparison, user approves or declines
4. **Apply tags** - Write ARTIST, ALBUM, TITLE, TRACKNUMBER, DATE, GENRE via metaflac
5. **Cover art** - Download best artwork (Deezer 1000x1000 > iTunes 600x600 > CAA) and embed into FLAC files
6. **Rename files** - Rename to `## - Title.flac` format

### Metadata Source Priority

- **Artist/Album/Date/Tracks**: MusicBrainz > Deezer > iTunes
- **Genre**: Deezer > iTunes
- **Cover art**: Deezer (1000x1000) > iTunes (600x600) > Cover Art Archive
- **Track titles**: MusicBrainz > Deezer

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
