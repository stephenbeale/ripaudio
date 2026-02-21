# RipAudio Project Roadmap

## Completed

- [x] Add `-Drive` and `-OutputDrive` args to configure input/output drives
- [x] Add `-N` flag to cyanrip for discs not in MusicBrainz (PR #3)
- [x] Cover art handling - sequential fallback: Cover Art Archive, MusicBrainz search + CAA, iTunes, Deezer (PR #20)
- [x] Multi-source metadata search - `search-metadata.ps1` scans folder, searches MusicBrainz + iTunes + Deezer, applies tags + cover art + renames
- [x] Optional MusicBrainz requirement - `-RequireMusicBrainz` switch stops the rip if disc not found in MusicBrainz

## Planned Features

### ~~Optional MusicBrainz Requirement~~ (Done)
Moved to Completed section.

### Path Length Validation
Check all output paths against Windows MAX_PATH (260 chars) before starting rip. Warn user and offer to abort if path would be too long, allowing them to input a shorter title. Consider all subdirectories and filename patterns.

### Quality Parameter
Add `-Quality` parameter for lossy format bitrate control (mp3, opus, aac).

```powershell
.\rip-audio.ps1 -album "My Album" -format mp3 -Quality 320
```

### Multiple Output Formats
Support ripping to multiple formats in a single pass.

```powershell
.\rip-audio.ps1 -album "My Album" -format "flac,mp3"
```

### AccurateRip Verification
Add AccurateRip verification reporting to confirm rip accuracy.

### Queue Mode
Batch ripping mode similar to ripdisc for processing multiple discs sequentially.

### CDDB Fallback
Fall back to CDDB/freedb when MusicBrainz has no match for disc metadata.