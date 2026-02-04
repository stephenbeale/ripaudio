param(
    [Parameter()]
    [string]$Path = "",

    [Parameter()]
    [string]$MusicRoot = "C:\Music",

    [Parameter()]
    [switch]$Scan,

    [Parameter()]
    [switch]$EmbedTags,

    [Parameter()]
    [switch]$DownloadArt,

    [Parameter()]
    [switch]$Force
)

# ========== STEP TRACKING ==========
$script:AllSteps = @(
    @{ Number = 1; Name = "Find albums"; Description = "Scan for albums needing metadata" }
    @{ Number = 2; Name = "Query MusicBrainz"; Description = "Look up album metadata" }
    @{ Number = 3; Name = "Apply metadata"; Description = "Update files with metadata" }
)
$script:CompletedSteps = @()
$script:CurrentStep = $null

function Set-CurrentStep {
    param([int]$StepNumber)
    $script:CurrentStep = $script:AllSteps | Where-Object { $_.Number -eq $StepNumber }
}

function Complete-CurrentStep {
    if ($script:CurrentStep) {
        $script:CompletedSteps += $script:CurrentStep
    }
}

function Get-RemainingSteps {
    $completedNumbers = $script:CompletedSteps | ForEach-Object { $_.Number }
    return $script:AllSteps | Where-Object { $_.Number -notin $completedNumbers }
}

function Show-StepsSummary {
    param([switch]$ShowRemaining)

    Write-Host "`n--- STEPS COMPLETED ---" -ForegroundColor Green
    if ($script:CompletedSteps.Count -eq 0) {
        Write-Host "  (none)" -ForegroundColor Gray
    } else {
        foreach ($step in $script:CompletedSteps) {
            Write-Host "  [X] Step $($step.Number)/3: $($step.Name)" -ForegroundColor Green
        }
    }

    if ($ShowRemaining) {
        $remaining = Get-RemainingSteps
        if ($remaining.Count -gt 0) {
            Write-Host "`n--- STEPS REMAINING ---" -ForegroundColor Yellow
            foreach ($step in $remaining) {
                Write-Host "  [ ] Step $($step.Number)/3: $($step.Name) - $($step.Description)" -ForegroundColor Yellow
            }
        }
    }
}

# ========== HELPER FUNCTIONS ==========
function Write-Log {
    param([string]$Message)
    if ($script:LogFile) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $entry = "[$timestamp] $Message"
        Add-Content -Path $script:LogFile -Value $entry
    }
}

function Stop-WithError {
    param([string]$Step, [string]$Message)

    Write-Log "========== ERROR =========="
    Write-Log "Failed at: $Step"
    Write-Log "Message: $Message"

    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "FAILED!" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "`nError at: $Step" -ForegroundColor Red
    Write-Host "Message: $Message" -ForegroundColor Red

    Show-StepsSummary -ShowRemaining

    if ($script:LogFile) {
        Write-Host "`nLog file: $($script:LogFile)" -ForegroundColor Yellow
    }
    Write-Host "`n========================================`n" -ForegroundColor Red
    exit 1
}

function Get-AlbumInfo {
    param([string]$AlbumPath)

    $info = @{
        Path = $AlbumPath
        Name = Split-Path -Leaf $AlbumPath
        Artist = ""
        HasCue = $false
        HasLog = $false
        HasArt = $false
        DiscId = ""
        ReleaseId = ""
        AudioFiles = @()
        Format = ""
    }

    # Check parent directory for artist name
    $parentPath = Split-Path -Parent $AlbumPath
    $parentName = Split-Path -Leaf $parentPath
    if ($parentName -ne "Music" -and $parentName -ne (Split-Path -Leaf $MusicRoot)) {
        $info.Artist = $parentName
    }

    # Check for existing metadata files
    $cueFiles = Get-ChildItem -Path $AlbumPath -Filter "*.cue" -ErrorAction SilentlyContinue
    if ($cueFiles) {
        $info.HasCue = $true
        # Try to extract DiscID from cue file
        $cueContent = Get-Content -Path $cueFiles[0].FullName -Raw -ErrorAction SilentlyContinue
        if ($cueContent -match 'REM MUSICBRAINZ_ID "([^"]+)"') {
            $info.DiscId = $Matches[1]
        }
        if ($cueContent -match 'REM RELEASE_ID "([^"]+)"') {
            $info.ReleaseId = $Matches[1]
        }
    }

    $logFiles = Get-ChildItem -Path $AlbumPath -Filter "*.log" -ErrorAction SilentlyContinue
    if ($logFiles) {
        $info.HasLog = $true
    }

    # Check for cover art
    $artFiles = Get-ChildItem -Path $AlbumPath -Include "Front.*","Cover.*","Folder.*" -ErrorAction SilentlyContinue
    if ($artFiles) {
        $info.HasArt = $true
    }

    # Find audio files
    $audioExtensions = @("*.flac", "*.mp3", "*.opus", "*.m4a", "*.wav")
    foreach ($ext in $audioExtensions) {
        $files = Get-ChildItem -Path $AlbumPath -Filter $ext -ErrorAction SilentlyContinue
        if ($files -and $files.Count -gt 0) {
            $info.AudioFiles = $files
            $info.Format = $ext.TrimStart("*.")
            break
        }
    }

    return $info
}

function Test-NeedsMetadata {
    param([hashtable]$AlbumInfo)

    # Needs metadata if no CUE file exists
    if (-not $AlbumInfo.HasCue) {
        return $true
    }

    # Needs metadata if no cover art and DownloadArt is specified
    if ($DownloadArt -and -not $AlbumInfo.HasArt) {
        return $true
    }

    # Force flag means always process
    if ($Force) {
        return $true
    }

    return $false
}

function Search-MusicBrainz {
    param(
        [string]$Album,
        [string]$Artist,
        [string]$DiscId,
        [string]$ReleaseId
    )

    $headers = @{
        "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)"
        "Accept" = "application/json"
    }

    # If we have a release ID, use it directly
    if ($ReleaseId) {
        Write-Host "  Using cached Release ID: $ReleaseId" -ForegroundColor Gray
        try {
            $url = "https://musicbrainz.org/ws/2/release/$($ReleaseId)?inc=recordings+artist-credits+release-groups&fmt=json"
            $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 15
            Start-Sleep -Milliseconds 1100  # Rate limit: 1 request per second
            return $response
        } catch {
            Write-Host "  Failed to fetch by Release ID, falling back to search" -ForegroundColor Yellow
        }
    }

    # If we have a disc ID, try that
    if ($DiscId) {
        Write-Host "  Searching by Disc ID: $DiscId" -ForegroundColor Gray
        try {
            $url = "https://musicbrainz.org/ws/2/discid/$($DiscId)?inc=recordings+artist-credits+release-groups&fmt=json"
            $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 15
            Start-Sleep -Milliseconds 1100
            if ($response.releases -and $response.releases.Count -gt 0) {
                return $response.releases[0]
            }
        } catch {
            Write-Host "  Disc ID not found, falling back to search" -ForegroundColor Yellow
        }
    }

    # Search by album name and artist
    $query = "release:`"$Album`""
    if ($Artist) {
        $query += " AND artist:`"$Artist`""
    }

    Write-Host "  Searching: $query" -ForegroundColor Gray
    try {
        $encodedQuery = [System.Web.HttpUtility]::UrlEncode($query)
        $url = "https://musicbrainz.org/ws/2/release?query=$encodedQuery&limit=5&fmt=json"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 15
        Start-Sleep -Milliseconds 1100

        if ($response.releases -and $response.releases.Count -gt 0) {
            return $response.releases[0]
        }
    } catch {
        Write-Host "  Search failed: $_" -ForegroundColor Red
    }

    return $null
}

function Get-CoverArt {
    param(
        [string]$ReleaseId,
        [string]$OutputPath
    )

    $headers = @{
        "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)"
    }

    try {
        # Query Cover Art Archive
        $url = "https://coverartarchive.org/release/$ReleaseId"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 15

        if ($response.images -and $response.images.Count -gt 0) {
            # Find front cover
            $frontCover = $response.images | Where-Object { $_.front -eq $true } | Select-Object -First 1
            if (-not $frontCover) {
                $frontCover = $response.images[0]
            }

            # Download the image
            $imageUrl = $frontCover.image
            $extension = if ($imageUrl -match '\.(\w+)$') { $Matches[1] } else { "jpg" }
            $outputFile = Join-Path $OutputPath "Front.$extension"

            Invoke-WebRequest -Uri $imageUrl -OutFile $outputFile -Headers $headers -TimeoutSec 30
            return $outputFile
        }
    } catch {
        Write-Host "  Cover art not available: $_" -ForegroundColor Yellow
    }

    return $null
}

function Write-CueFile {
    param(
        [string]$OutputPath,
        [string]$AlbumName,
        [object]$MbRelease,
        [System.IO.FileInfo[]]$AudioFiles
    )

    $cueContent = @()

    # Header
    $artist = if ($MbRelease.'artist-credit') {
        ($MbRelease.'artist-credit' | ForEach-Object { $_.name }) -join ", "
    } else { "" }

    $cueContent += "REM Generated by get-metadata.ps1"
    $cueContent += "REM DATE `"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`""

    if ($MbRelease.id) {
        $cueContent += "REM RELEASE_ID `"$($MbRelease.id)`""
    }
    if ($MbRelease.barcode) {
        $cueContent += "REM BARCODE `"$($MbRelease.barcode)`""
    }
    if ($MbRelease.date) {
        $cueContent += "REM RELEASE_DATE `"$($MbRelease.date)`""
    }
    if ($MbRelease.country) {
        $cueContent += "REM COUNTRY `"$($MbRelease.country)`""
    }

    $cueContent += "PERFORMER `"$artist`""
    $cueContent += "TITLE `"$AlbumName`""

    # Tracks
    $trackNum = 1
    $tracks = if ($MbRelease.media -and $MbRelease.media[0].tracks) {
        $MbRelease.media[0].tracks
    } else { @() }

    foreach ($audioFile in ($AudioFiles | Sort-Object Name)) {
        $cueContent += "FILE `"$($audioFile.Name)`" WAVE"
        $cueContent += "  TRACK $('{0:D2}' -f $trackNum) AUDIO"

        # Try to get track title from MusicBrainz
        if ($trackNum -le $tracks.Count) {
            $mbTrack = $tracks[$trackNum - 1]
            $trackTitle = $mbTrack.title
            $trackArtist = if ($mbTrack.'artist-credit') {
                ($mbTrack.'artist-credit' | ForEach-Object { $_.name }) -join ", "
            } else { $artist }
        } else {
            $trackTitle = "Track $trackNum"
            $trackArtist = $artist
        }

        $cueContent += "    TITLE `"$trackTitle`""
        $cueContent += "    PERFORMER `"$trackArtist`""
        $cueContent += "    INDEX 01 00:00:00"

        $trackNum++
    }

    $cueFile = Join-Path $OutputPath "$AlbumName.cue"
    $cueContent | Set-Content -Path $cueFile -Encoding UTF8
    return $cueFile
}

function Set-AudioTags {
    param(
        [string]$FilePath,
        [string]$Format,
        [int]$TrackNumber,
        [int]$TotalTracks,
        [string]$Title,
        [string]$Artist,
        [string]$Album,
        [string]$AlbumArtist,
        [string]$Date,
        [string]$ReleaseId
    )

    # Use metaflac for FLAC files
    if ($Format -eq "flac") {
        $metaflacPath = Get-Command metaflac -ErrorAction SilentlyContinue
        if (-not $metaflacPath) {
            return $false
        }

        # Remove existing tags and add new ones
        $tags = @(
            "--remove-all-tags",
            "--set-tag=TITLE=$Title",
            "--set-tag=ARTIST=$Artist",
            "--set-tag=ALBUM=$Album",
            "--set-tag=ALBUMARTIST=$AlbumArtist",
            "--set-tag=TRACKNUMBER=$TrackNumber",
            "--set-tag=TRACKTOTAL=$TotalTracks"
        )

        if ($Date) {
            $tags += "--set-tag=DATE=$Date"
        }
        if ($ReleaseId) {
            $tags += "--set-tag=MUSICBRAINZ_ALBUMID=$ReleaseId"
        }

        & metaflac @tags $FilePath 2>$null
        return $LASTEXITCODE -eq 0
    }

    # For other formats, we'd need ffmpeg or format-specific tools
    # For now, just return false to indicate tags weren't set
    return $false
}

# ========== MAIN SCRIPT ==========

# Load System.Web for URL encoding
Add-Type -AssemblyName System.Web

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Get Metadata for Ripped Albums" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Validate parameters
if (-not $Path -and -not $Scan) {
    Write-Host "`nUsage:" -ForegroundColor Yellow
    Write-Host "  get-metadata.ps1 -Path <album-folder>    # Process single album" -ForegroundColor White
    Write-Host "  get-metadata.ps1 -Scan                   # Scan for albums without metadata" -ForegroundColor White
    Write-Host "`nOptions:" -ForegroundColor Yellow
    Write-Host "  -MusicRoot <path>   Music library root (default: C:\Music)" -ForegroundColor White
    Write-Host "  -EmbedTags          Embed metadata in audio files" -ForegroundColor White
    Write-Host "  -DownloadArt        Download cover art from Cover Art Archive" -ForegroundColor White
    Write-Host "  -Force              Process even if metadata exists" -ForegroundColor White
    Write-Host "`nExamples:" -ForegroundColor Yellow
    Write-Host "  get-metadata.ps1 -Path 'C:\Music\Tracy Chapman\Tracy Chapman'" -ForegroundColor Gray
    Write-Host "  get-metadata.ps1 -Scan -DownloadArt" -ForegroundColor Gray
    Write-Host "  get-metadata.ps1 -Scan -EmbedTags -Force" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# Setup logging
$logDir = "C:\Music\logs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFile = Join-Path $logDir "get-metadata_${logTimestamp}.log"

Write-Log "========== GET METADATA SESSION STARTED =========="
Write-Log "Music root: $MusicRoot"
Write-Log "Path: $Path"
Write-Log "Scan mode: $Scan"
Write-Log "Embed tags: $EmbedTags"
Write-Log "Download art: $DownloadArt"
Write-Log "Force: $Force"

# ========== STEP 1: FIND ALBUMS ==========
Set-CurrentStep -StepNumber 1
Write-Host "`n[STEP 1/3] Finding albums..." -ForegroundColor Green
Write-Log "STEP 1/3: Finding albums..."

$albumsToProcess = @()

if ($Path) {
    # Process single album
    if (-not (Test-Path $Path)) {
        Stop-WithError -Step "STEP 1/3: Find albums" -Message "Path not found: $Path"
    }

    $albumInfo = Get-AlbumInfo -AlbumPath $Path
    if ($albumInfo.AudioFiles.Count -eq 0) {
        Stop-WithError -Step "STEP 1/3: Find albums" -Message "No audio files found in: $Path"
    }

    if (Test-NeedsMetadata -AlbumInfo $albumInfo) {
        $albumsToProcess += $albumInfo
    } else {
        Write-Host "  Album already has metadata (use -Force to reprocess)" -ForegroundColor Yellow
    }
} else {
    # Scan for albums
    Write-Host "  Scanning: $MusicRoot" -ForegroundColor Gray

    if (-not (Test-Path $MusicRoot)) {
        Stop-WithError -Step "STEP 1/3: Find albums" -Message "Music root not found: $MusicRoot"
    }

    # Find all directories containing audio files
    $audioExtensions = @("*.flac", "*.mp3", "*.opus", "*.m4a", "*.wav")
    $allAudioFiles = @()
    foreach ($ext in $audioExtensions) {
        $files = Get-ChildItem -Path $MusicRoot -Filter $ext -Recurse -ErrorAction SilentlyContinue
        $allAudioFiles += $files
    }

    # Get unique album directories
    $albumDirs = $allAudioFiles | ForEach-Object { Split-Path -Parent $_.FullName } | Sort-Object -Unique

    Write-Host "  Found $($albumDirs.Count) album folder(s)" -ForegroundColor Gray

    foreach ($dir in $albumDirs) {
        $albumInfo = Get-AlbumInfo -AlbumPath $dir
        if (Test-NeedsMetadata -AlbumInfo $albumInfo) {
            $albumsToProcess += $albumInfo
        }
    }
}

if ($albumsToProcess.Count -eq 0) {
    Write-Host "`nNo albums need metadata processing." -ForegroundColor Yellow
    Write-Host "Use -Force to reprocess albums with existing metadata." -ForegroundColor Gray
    Write-Log "No albums need processing"
    exit 0
}

Write-Host "  Albums to process: $($albumsToProcess.Count)" -ForegroundColor Green
foreach ($album in $albumsToProcess) {
    $displayName = if ($album.Artist) { "$($album.Artist) - $($album.Name)" } else { $album.Name }
    Write-Host "    - $displayName" -ForegroundColor White
    Write-Log "  Found: $displayName"
}

Complete-CurrentStep
Write-Log "STEP 1/3: Complete - $($albumsToProcess.Count) album(s) to process"

# ========== STEP 2: QUERY MUSICBRAINZ ==========
Set-CurrentStep -StepNumber 2
Write-Host "`n[STEP 2/3] Querying MusicBrainz..." -ForegroundColor Green
Write-Log "STEP 2/3: Querying MusicBrainz..."

# Test API connectivity first
Write-Host "  Checking MusicBrainz API..." -ForegroundColor Gray
$mbHeaders = @{ "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)" }
try {
    $mbTest = Invoke-WebRequest -Uri "https://musicbrainz.org/ws/2/release?query=test&limit=1" -Headers $mbHeaders -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
    Write-Host "  MusicBrainz API: OK" -ForegroundColor Green
} catch {
    Stop-WithError -Step "STEP 2/3: MusicBrainz" -Message "Cannot connect to MusicBrainz API: $_"
}

$metadataResults = @()

foreach ($album in $albumsToProcess) {
    $displayName = if ($album.Artist) { "$($album.Artist) - $($album.Name)" } else { $album.Name }
    Write-Host "`n  Processing: $displayName" -ForegroundColor Cyan
    Write-Log "Processing: $displayName"

    $mbResult = Search-MusicBrainz -Album $album.Name -Artist $album.Artist -DiscId $album.DiscId -ReleaseId $album.ReleaseId

    if ($mbResult) {
        $resultArtist = if ($mbResult.'artist-credit') {
            ($mbResult.'artist-credit' | ForEach-Object { $_.name }) -join ", "
        } else { "Unknown" }

        Write-Host "  Found: $($mbResult.title) by $resultArtist" -ForegroundColor Green
        Write-Log "  Found: $($mbResult.title) by $resultArtist (ID: $($mbResult.id))"

        $metadataResults += @{
            Album = $album
            MbRelease = $mbResult
        }
    } else {
        Write-Host "  Not found in MusicBrainz" -ForegroundColor Yellow
        Write-Log "  Not found in MusicBrainz"
    }
}

if ($metadataResults.Count -eq 0) {
    Write-Host "`nNo metadata found for any albums." -ForegroundColor Yellow
    Write-Log "No metadata found"
    Show-StepsSummary -ShowRemaining
    exit 0
}

Complete-CurrentStep
Write-Log "STEP 2/3: Complete - $($metadataResults.Count) album(s) found"

# ========== STEP 3: APPLY METADATA ==========
Set-CurrentStep -StepNumber 3
Write-Host "`n[STEP 3/3] Applying metadata..." -ForegroundColor Green
Write-Log "STEP 3/3: Applying metadata..."

$successCount = 0
$artCount = 0
$tagCount = 0

foreach ($result in $metadataResults) {
    $album = $result.Album
    $mbRelease = $result.MbRelease
    $displayName = if ($album.Artist) { "$($album.Artist) - $($album.Name)" } else { $album.Name }

    Write-Host "`n  Applying: $displayName" -ForegroundColor Cyan

    # Write CUE file
    try {
        $cueFile = Write-CueFile -OutputPath $album.Path -AlbumName $album.Name -MbRelease $mbRelease -AudioFiles $album.AudioFiles
        Write-Host "    Created: $(Split-Path -Leaf $cueFile)" -ForegroundColor Green
        Write-Log "  Created CUE file: $cueFile"
        $successCount++
    } catch {
        Write-Host "    Failed to create CUE file: $_" -ForegroundColor Red
        Write-Log "  ERROR creating CUE file: $_"
    }

    # Download cover art if requested
    if ($DownloadArt -and $mbRelease.id) {
        Write-Host "    Downloading cover art..." -ForegroundColor Gray
        $artFile = Get-CoverArt -ReleaseId $mbRelease.id -OutputPath $album.Path
        if ($artFile) {
            Write-Host "    Downloaded: $(Split-Path -Leaf $artFile)" -ForegroundColor Green
            Write-Log "  Downloaded cover art: $artFile"
            $artCount++
        }
    }

    # Embed tags if requested
    if ($EmbedTags -and $album.Format -eq "flac") {
        Write-Host "    Embedding tags in audio files..." -ForegroundColor Gray

        $artist = if ($mbRelease.'artist-credit') {
            ($mbRelease.'artist-credit' | ForEach-Object { $_.name }) -join ", "
        } else { "" }

        $tracks = if ($mbRelease.media -and $mbRelease.media[0].tracks) {
            $mbRelease.media[0].tracks
        } else { @() }

        $trackNum = 1
        foreach ($audioFile in ($album.AudioFiles | Sort-Object Name)) {
            $trackTitle = if ($trackNum -le $tracks.Count) { $tracks[$trackNum - 1].title } else { "Track $trackNum" }

            $tagged = Set-AudioTags -FilePath $audioFile.FullName -Format $album.Format `
                -TrackNumber $trackNum -TotalTracks $album.AudioFiles.Count `
                -Title $trackTitle -Artist $artist `
                -Album $album.Name -AlbumArtist $artist `
                -Date $mbRelease.date -ReleaseId $mbRelease.id

            if ($tagged) {
                $tagCount++
            }
            $trackNum++
        }

        if ($tagCount -gt 0) {
            Write-Host "    Tagged $tagCount file(s)" -ForegroundColor Green
            Write-Log "  Tagged $tagCount audio files"
        }
    }
}

Complete-CurrentStep
Write-Log "STEP 3/3: Complete"

# ========== SUMMARY ==========
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "COMPLETE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`n--- SUMMARY ---" -ForegroundColor Cyan
Write-Host "  Albums processed: $($albumsToProcess.Count)" -ForegroundColor White
Write-Host "  Metadata applied: $successCount" -ForegroundColor White
if ($DownloadArt) {
    Write-Host "  Cover art downloaded: $artCount" -ForegroundColor White
}
if ($EmbedTags) {
    Write-Host "  Files tagged: $tagCount" -ForegroundColor White
}
Write-Host "  Log file: $($script:LogFile)" -ForegroundColor White

Show-StepsSummary

Write-Host "`n========================================`n" -ForegroundColor Cyan

Write-Log "========== SESSION COMPLETE =========="
Write-Log "Albums processed: $($albumsToProcess.Count)"
Write-Log "Metadata applied: $successCount"
Write-Log "Cover art downloaded: $artCount"
Write-Log "Files tagged: $tagCount"
