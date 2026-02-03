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
| `-format` | No | flac | Output format (flac, mp3, opus, aac, wav, alac) |

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
