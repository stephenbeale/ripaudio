# RipAudio Project Roadmap

## Completed

- [x] Add `-Drive` and `-OutputDrive` args to configure input/output drives
- [x] Add `-N` flag to cyanrip for discs not in MusicBrainz (PR #3)
- [x] Cover art handling - sequential fallback: Cover Art Archive, MusicBrainz search + CAA, iTunes, Deezer (PR #20)

## Planned Features

### Optional MusicBrainz Requirement
Add `-RequireMusicBrainz` switch parameter that, when specified, removes the `-N` flag from cyanrip. Default behavior continues without MusicBrainz metadata (current behavior), but users can require it for discs they expect to be in the database.

```powershell
# Default: continues without MusicBrainz (uses -N)
.\rip-audio.ps1 -album "My Album" -Drive E:

# Require MusicBrainz metadata (fails if not found)
.\rip-audio.ps1 -album "My Album" -Drive E: -RequireMusicBrainz
```

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