param(
    [Parameter()]
    [string]$album = "",

    [Parameter()]
    [string]$artist = "",

    [Parameter()]
    [string]$Drive = "",

    [Parameter()]
    [string]$OutputDrive = "",

    [Parameter()]
    [string]$format = "flac",

    [Parameter()]
    [switch]$RequireMusicBrainz,

    [Parameter()]
    [int]$Quality = 0,

    [Parameter()]
    [switch]$Queue,

    [Parameter()]
    [switch]$ProcessQueue
)

# ========== STEP TRACKING ==========
# Define the 4 processing steps
$script:AllSteps = @(
    @{ Number = 1; Name = "cyanrip rip"; Description = "Rip audio CD to audio files" }
    @{ Number = 2; Name = "Verify output"; Description = "Verify ripped files exist" }
    @{ Number = 3; Name = "Cover art"; Description = "Download album cover art" }
    @{ Number = 4; Name = "Open directory"; Description = "Open output folder" }
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

function Get-AlbumSummary {
    if ($artist) {
        return "Album: $album by $artist"
    } else {
        return "Album: $album"
    }
}

function Show-StepsSummary {
    param([switch]$ShowRemaining)

    Write-Host "`n--- STEPS COMPLETED ---" -ForegroundColor Green
    if ($script:CompletedSteps.Count -eq 0) {
        Write-Host "  (none)" -ForegroundColor Gray
    } else {
        foreach ($step in $script:CompletedSteps) {
            Write-Host "  [X] Step $($step.Number)/4: $($step.Name)" -ForegroundColor Green
        }
    }

    if ($ShowRemaining) {
        $remaining = Get-RemainingSteps
        if ($remaining.Count -gt 0) {
            Write-Host "`n--- STEPS REMAINING ---" -ForegroundColor Yellow
            foreach ($step in $remaining) {
                Write-Host "  [ ] Step $($step.Number)/4: $($step.Name) - $($step.Description)" -ForegroundColor Yellow
            }
        }
    }
}

# ========== CLOSE BUTTON PROTECTION ==========
# Disable the console window close button (X) to prevent accidental closure during rip
Add-Type -Name 'ConsoleCloseProtection' -Namespace 'Win32' -MemberDefinition @'
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);
    [DllImport("user32.dll")]
    public static extern bool EnableMenuItem(IntPtr hMenu, uint uIDEnableItem, uint uEnable);
'@

$script:ConsoleWindow = [Win32.ConsoleCloseProtection]::GetConsoleWindow()
$script:ConsoleSystemMenu = [Win32.ConsoleCloseProtection]::GetSystemMenu($script:ConsoleWindow, $false)

function Disable-ConsoleClose {
    # SC_CLOSE = 0xF060, MF_BYCOMMAND = 0x0, MF_GRAYED = 0x1
    [Win32.ConsoleCloseProtection]::EnableMenuItem($script:ConsoleSystemMenu, 0xF060, 0x00000001) | Out-Null
}

function Enable-ConsoleClose {
    # SC_CLOSE = 0xF060, MF_BYCOMMAND = 0x0, MF_ENABLED = 0x0
    [Win32.ConsoleCloseProtection]::EnableMenuItem($script:ConsoleSystemMenu, 0xF060, 0x00000000) | Out-Null
}

# Load System.Web for URL encoding (used in cover art search)
Add-Type -AssemblyName System.Web

# ========== HELPER FUNCTIONS ==========
function Test-TrackIntegrity {
    param([string]$FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    if ($ext -eq ".flac") {
        $metaflac = Get-Command metaflac -ErrorAction SilentlyContinue
        if ($metaflac) {
            & metaflac --test $FilePath 2>$null
            return $LASTEXITCODE -eq 0
        }
    }
    # For non-FLAC or no metaflac: check file size > 10KB
    return (Get-Item $FilePath).Length -gt 10240
}

function Get-DiscTrackCount {
    param([string]$OutputDir, [string]$DriveLetter)
    # Try cue file first (avoids disc query and multiple-release prompts)
    $cueFile = Get-ChildItem -Path $OutputDir -Filter "*.cue" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cueFile) {
        $cueContent = Get-Content -Path $cueFile.FullName -Raw -ErrorAction SilentlyContinue
        if ($cueContent) {
            $trackMatches = [regex]::Matches($cueContent, 'TRACK (\d+) AUDIO')
            if ($trackMatches.Count -gt 0) {
                return $trackMatches.Count
            }
        }
    }
    # Fallback: query disc (may fail if multiple releases)
    $output = & cyanrip -I -d $DriveLetter -s 0 2>&1
    $outputText = $output -join "`n"
    if ($outputText -match 'Disc tracks:\s+(\d+)') {
        return [int]$Matches[1]
    }
    # If multiple releases found, cyanrip doesn't show track count — retry with -R 1
    if ($outputText -match "Multiple releases found") {
        $output2 = & cyanrip -I -d $DriveLetter -s 0 -R 1 2>&1
        $outputText2 = $output2 -join "`n"
        if ($outputText2 -match 'Disc tracks:\s+(\d+)') {
            return [int]$Matches[1]
        }
    }
    return $null
}

function Get-DiscMetadata {
    param([string]$DriveLetter)

    Write-Host "Querying disc in drive $DriveLetter..." -ForegroundColor Yellow

    $outputLines = [System.Collections.ArrayList]::new()
    & cyanrip -I -d $DriveLetter -s 0 2>&1 | ForEach-Object {
        Write-Host $_ -ForegroundColor Gray
        [void]$outputLines.Add([string]$_)
    }
    $output = $outputLines.ToArray()
    $outputText = $output -join "`n"

    $result = @{ Album = $null; Artist = $null; DiscNum = $null; TotalDiscs = $null; ReleaseChoice = $null; DiscId = $null; ReleaseId = $null }

    # Parse disc ID - try multiple formats cyanrip may output
    $discId = $null
    if ($outputText -match 'for DiscID\s+(\S+?):') {
        $discId = $Matches[1]
    } elseif ($outputText -match 'Disc ID:\s*(\S+)') {
        $discId = $Matches[1]
    } elseif ($outputText -match 'DiscID\s*[:\s]\s*(\S+)') {
        $discId = $Matches[1]
    }

    if (-not $discId) {
        Write-Host "Could not determine disc ID" -ForegroundColor Yellow
        return $null
    }
    Write-Host "Disc ID: $discId" -ForegroundColor Gray

    # Check for multiple releases
    $releaseUuid = $null
    if ($outputText -match "Multiple releases found") {
        $releases = @()
        foreach ($line in $output) {
            if ($line -match '^\s*(\d+)\s+\(ID:\s*([a-f0-9-]+)\):\s*(.+)$') {
                $releases += @{ Index = $Matches[1]; UUID = $Matches[2]; Description = $Matches[3].Trim() }
            }
        }
        if ($releases.Count -gt 0) {
            Write-Host "`nMultiple releases found. Select one:" -ForegroundColor Cyan
            foreach ($rel in $releases) {
                Write-Host "  $($rel.Index): $($rel.Description)" -ForegroundColor White
            }
            Write-Host ""

            $validChoice = $false
            while (-not $validChoice) {
                $choice = Read-Host "Enter release number (1-$($releases.Count))"
                if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $releases.Count) {
                    $validChoice = $true
                } else {
                    Write-Host "Invalid choice. Please enter a number between 1 and $($releases.Count)" -ForegroundColor Yellow
                }
            }

            $selectedIdx = [int]$choice - 1
            $result.ReleaseChoice = $choice
            $releaseUuid = $releases[$selectedIdx].UUID
            Write-Host "Selected release $choice" -ForegroundColor Green
        }
    }

    # Query MusicBrainz API for full metadata
    Write-Host "Querying MusicBrainz for release details..." -ForegroundColor Yellow
    $mbHeaders = @{
        "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)"
        "Accept" = "application/json"
    }
    try {
        if ($releaseUuid) {
            $url = "https://musicbrainz.org/ws/2/release/$($releaseUuid)?inc=artist-credits+media+discids&fmt=json"
        } else {
            $url = "https://musicbrainz.org/ws/2/discid/$($discId)?inc=artist-credits+media+discids&fmt=json"
        }
        $response = Invoke-RestMethod -Uri $url -Headers $mbHeaders -TimeoutSec 10

        # discid lookup returns releases array; direct release lookup returns the release object
        $release = if ($response.releases) { $response.releases[0] } else { $response }

        $result.Album = $release.title
        $result.DiscId = $discId
        $result.ReleaseId = $release.id
        if ($release.'artist-credit' -and $release.'artist-credit'.Count -gt 0) {
            $result.Artist = ($release.'artist-credit' | ForEach-Object { $_.name }) -join " / "
        }

        # Disc position for multi-disc albums
        if ($release.media) {
            $result.TotalDiscs = $release.media.Count
            # Find which medium matches our disc ID
            foreach ($medium in $release.media) {
                foreach ($disc in $medium.discs) {
                    if ($disc.id -eq $discId) {
                        $result.DiscNum = $medium.position
                        break
                    }
                }
                if ($result.DiscNum) { break }
            }
            # Fallback: if only 1 medium, it's disc 1
            if (-not $result.DiscNum -and $result.TotalDiscs -eq 1) {
                $result.DiscNum = 1
            }
        }
    } catch {
        Write-Host "MusicBrainz API query failed: $_" -ForegroundColor Yellow
        return $null
    }

    return $result
}

function Test-DriveReady {
    param([string]$Path)

    # Extract the drive letter from the path (e.g., "E:" from "E:\Music\Album")
    $driveLetter = [System.IO.Path]::GetPathRoot($Path)
    if (-not $driveLetter) {
        return @{ Ready = $false; Drive = "Unknown"; Message = "Could not determine drive letter from path: $Path" }
    }

    # Normalize drive letter (remove trailing backslash for display)
    $driveDisplay = $driveLetter.TrimEnd('\')

    # Check if the drive exists and is ready
    try {
        $drive = Get-PSDrive -Name $driveDisplay.TrimEnd(':') -ErrorAction Stop
        if ($drive) {
            # Additional check: try to access the drive root
            if (Test-Path $driveLetter -ErrorAction SilentlyContinue) {
                return @{ Ready = $true; Drive = $driveDisplay; Message = "Drive is ready" }
            } else {
                return @{ Ready = $false; Drive = $driveDisplay; Message = "Destination drive $driveDisplay is not ready - please ensure the drive is connected and mounted" }
            }
        }
    } catch {
        return @{ Ready = $false; Drive = $driveDisplay; Message = "Destination drive $driveDisplay is not ready - please ensure the drive is connected and mounted" }
    }

    return @{ Ready = $false; Drive = $driveDisplay; Message = "Destination drive $driveDisplay is not ready - please ensure the drive is connected and mounted" }
}

function Write-Log {
    param([string]$Message)
    if ($script:LogFile) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $entry = "[$timestamp] $Message"
        Add-Content -Path $script:LogFile -Value $entry
    }
}

function Show-CoffeeBadge {
    $vt = [char]0x2551
    $w  = 60
    $hz = [string]::new([char]0x2550, $w)
    $tl = [char]0x2554
    $tr = [char]0x2557
    $bl = [char]0x255A
    $br = [char]0x255D
    Write-Host ""
    Write-Host "  $tl$hz$tr" -ForegroundColor DarkGray
    Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host ("   ) ) )".PadRight($w)) -NoNewline -ForegroundColor DarkYellow; Write-Host "$vt" -ForegroundColor DarkGray
    $c = "  (_____)  "; Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host $c -NoNewline -ForegroundColor DarkYellow; Write-Host ("Enjoying this app? Consider buying me a coffee!".PadRight($w - $c.Length)) -NoNewline -ForegroundColor White; Write-Host "$vt" -ForegroundColor DarkGray
    Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host ("  |     |".PadRight($w)) -NoNewline -ForegroundColor DarkYellow; Write-Host "$vt" -ForegroundColor DarkGray
    $c = "  |     |  "; Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host $c -NoNewline -ForegroundColor DarkYellow; Write-Host (">> https://buymeacoffee.com/stephenbeale".PadRight($w - $c.Length)) -NoNewline -ForegroundColor Yellow; Write-Host "$vt" -ForegroundColor DarkGray
    $c = "  '-----'"; Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host $c -NoNewline -ForegroundColor DarkYellow; Write-Host ("            ^^^ click here! ^^^".PadRight($w - $c.Length)) -NoNewline -ForegroundColor Cyan; Write-Host "$vt" -ForegroundColor DarkGray
    Write-Host "  $bl$hz$br" -ForegroundColor DarkGray
    Write-Host ""
}

# ========== ACCURATERIP PARSING ==========
function Parse-AccurateRipResults {
    param([string]$Output)

    $result = @{
        DbStatus = "unknown"        # found, not found, error, mismatch, disabled
        TracksVerified = -1          # -1 = not available
        TracksTotal = -1
        TracksPartial = 0
        TrackDetails = @()           # array of per-track results
    }

    # Disc-level status
    if ($Output -match 'AccurateRip:\s+(found|not found|error|mismatch|disabled)') {
        $result.DbStatus = $Matches[1]
    }

    # Finish report summary
    if ($Output -match 'Tracks ripped accurately: (\d+)/(\d+)') {
        $result.TracksVerified = [int]$Matches[1]
        $result.TracksTotal = [int]$Matches[2]
    }
    if ($Output -match 'Tracks ripped partially accurately: (\d+)/(\d+)') {
        $result.TracksPartial = [int]$Matches[1]
    }

    # Per-track details (parse v1/v2 lines)
    $trackNum = 0
    foreach ($line in ($Output -split "`n")) {
        if ($line -match '^\s+Track\s+(\d+)') {
            $trackNum = [int]$Matches[1]
        }
        if ($line -match '^\s{4}Accurip (v1|v2):\s+([0-9A-Fa-f]{8})\s+\(accurately ripped, confidence (\d+)\)') {
            $result.TrackDetails += @{
                Track = $trackNum
                Version = $Matches[1]
                Checksum = $Matches[2]
                Confidence = [int]$Matches[3]
                Status = "accurate"
            }
        }
        elseif ($line -match '^\s{4}Accurip (v1|v2):\s+([0-9A-Fa-f]{8})\s+\(not found') {
            $result.TrackDetails += @{
                Track = $trackNum
                Version = $Matches[1]
                Checksum = $Matches[2]
                Confidence = 0
                Status = "not found"
            }
        }
    }

    return $result
}

# ========== CDDB FALLBACK ==========
function Search-CDDB {
    param(
        [string]$CyanripOutput,
        [string]$AlbumName = "",
        [string]$ArtistName = ""
    )

    $genre = $null
    $matchDiscId = $null
    $numTracks = 0

    # Try 1: TOC-based lookup from cyanrip output
    $trackStarts = @()
    $leadOut = $null

    foreach ($line in ($CyanripOutput -split "`n")) {
        if ($line -match 'Track\s+\d+:\s+start\s+(\d+)') {
            $trackStarts += [int]$Matches[1]
        }
        if ($line -match 'Lead-?out:\s*(\d+)') {
            $leadOut = [int]$Matches[1]
        }
    }

    if ($trackStarts.Count -gt 0 -and $null -ne $leadOut) {
        $numTracks = $trackStarts.Count

        # Compute CDDB disc ID - offsets include 150-frame lead-in
        $cddbOffsets = $trackStarts | ForEach-Object { $_ + 150 }
        $leadOutCddb = $leadOut + 150

        # Sum digits of each track's start second
        $digitSum = 0
        foreach ($offset in $cddbOffsets) {
            $seconds = [math]::Floor($offset / 75)
            while ($seconds -gt 0) {
                $digitSum += $seconds % 10
                $seconds = [math]::Floor($seconds / 10)
            }
        }

        $totalSeconds = [math]::Floor($leadOutCddb / 75) - [math]::Floor($cddbOffsets[0] / 75)
        $discId = (($digitSum % 0xFF) -shl 24) -bor ($totalSeconds -shl 8) -bor $numTracks
        $discIdHex = $discId.ToString("x8")

        # Query gnudb.org
        $offsetsStr = ($cddbOffsets | ForEach-Object { $_.ToString() }) -join "+"
        $totalSecs = [math]::Floor($leadOutCddb / 75)

        $queryUrl = "http://gnudb.gnudb.org/~cddb/cddb.cgi?cmd=cddb+query+$discIdHex+$numTracks+$offsetsStr+$totalSecs&hello=user+host+RipAudio+1.0&proto=6"

        try {
            $queryResponse = Invoke-WebRequest -Uri $queryUrl -TimeoutSec 10 -UseBasicParsing
            $queryText = $queryResponse.Content

            if ($queryText -match '^200\s+(\S+)\s+(\S+)') {
                $genre = $Matches[1]
                $matchDiscId = $Matches[2]
            } elseif ($queryText -match '^21[01]') {
                # Multiple/inexact matches - take first
                $lines = $queryText -split "`n"
                foreach ($qline in $lines[1..($lines.Length-1)]) {
                    if ($qline -match '^\s*(\S+)\s+(\S+)\s+(.+)' -and $qline.Trim() -ne '.') {
                        $genre = $Matches[1]
                        $matchDiscId = $Matches[2]
                        break
                    }
                }
            }
        } catch {}
    }

    # Try 2: Text search fallback (if TOC lookup didn't find anything)
    if (-not $genre -and $AlbumName) {
        $searchTerm = if ($ArtistName) { "$ArtistName $AlbumName" } else { $AlbumName }
        $searchEncoded = [System.Web.HttpUtility]::UrlEncode($searchTerm)
        $albumUrl = "http://gnudb.gnudb.org/~cddb/cddb.cgi?cmd=cddb+album+$searchEncoded&hello=user+host+RipAudio+1.0&proto=6"

        try {
            $albumResponse = Invoke-WebRequest -Uri $albumUrl -TimeoutSec 10 -UseBasicParsing
            $albumText = $albumResponse.Content

            if ($albumText -match '^21[01]') {
                $lines = $albumText -split "`n"
                foreach ($aline in $lines[1..($lines.Length-1)]) {
                    if ($aline -match '^\s*(\S+)\s+(\S+)\s+(.+)' -and $aline.Trim() -ne '.') {
                        $genre = $Matches[1]
                        $matchDiscId = $Matches[2]
                        break
                    }
                }
            }
        } catch {}
    }

    if (-not $genre -or -not $matchDiscId) {
        return $null
    }

    # Read full CDDB entry
    $readUrl = "http://gnudb.gnudb.org/~cddb/cddb.cgi?cmd=cddb+read+$genre+$matchDiscId&hello=user+host+RipAudio+1.0&proto=6"

    try {
        $readResponse = Invoke-WebRequest -Uri $readUrl -TimeoutSec 10 -UseBasicParsing
        $readText = $readResponse.Content
    } catch {
        return $null
    }

    # Parse DTITLE=Artist / Album (may span multiple lines)
    $cddbArtist = ""
    $cddbAlbum = ""
    $dtitleParts = @()
    foreach ($line in ($readText -split "`n")) {
        if ($line -match '^DTITLE=(.*)') {
            $dtitleParts += $Matches[1].Trim()
        }
    }
    $dtitle = $dtitleParts -join ""
    if ($dtitle -match '^(.+?)\s*/\s*(.+)$') {
        $cddbArtist = $Matches[1].Trim()
        $cddbAlbum = $Matches[2].Trim()
    } else {
        $cddbAlbum = $dtitle.Trim()
    }

    # Parse TTITLE0=Track Title (may span multiple lines with same key)
    $trackTitles = @{}
    foreach ($line in ($readText -split "`n")) {
        if ($line -match '^TTITLE(\d+)=(.*)') {
            $trackNum = [int]$Matches[1]
            $title = $Matches[2].Trim()
            if ($trackTitles.ContainsKey($trackNum)) {
                $trackTitles[$trackNum] += $title
            } else {
                $trackTitles[$trackNum] = $title
            }
        }
    }

    # Build ordered track list
    $trackCount = if ($numTracks -gt 0) { $numTracks } else { ($trackTitles.Keys | Measure-Object -Maximum).Maximum + 1 }
    $tracks = @()
    for ($i = 0; $i -lt $trackCount; $i++) {
        if ($trackTitles.ContainsKey($i)) {
            $tracks += $trackTitles[$i]
        } else {
            $tracks += "Track $("{0:D2}" -f ($i + 1))"
        }
    }

    return @{
        Artist = $cddbArtist
        Album = $cddbAlbum
        Tracks = $tracks
    }
}

# ========== QUEUE FUNCTIONS ==========
$script:QueueFilePath = "C:\Music\rip-queue.json"
$script:QueueLockPath = "C:\Music\rip-queue.lock"

function Add-ToQueue {
    param(
        [string]$Album,
        [string]$Artist,
        [string]$Format,
        [int]$Bitrate = 0
    )

    $entry = @{
        Album = $Album
        Artist = $Artist
        Format = $Format
        Quality = $Bitrate
        QueuedAt = (Get-Date -Format "o")
    }

    # File locking for concurrent safety (same pattern as ripdisc)
    $retryCount = 0
    $maxRetries = 10
    $lockAcquired = $false

    while (-not $lockAcquired -and $retryCount -lt $maxRetries) {
        try {
            $lockStream = [System.IO.File]::Open($script:QueueLockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $lockAcquired = $true
        } catch {
            $retryCount++
            Start-Sleep -Milliseconds 500
        }
    }

    if (-not $lockAcquired) {
        Write-Host "WARNING: Could not acquire lock file - writing without lock" -ForegroundColor Red
    }

    try {
        if (Test-Path $script:QueueFilePath) {
            $queue = Get-Content $script:QueueFilePath -Raw | ConvertFrom-Json
            if ($queue -isnot [System.Array]) { $queue = @($queue) }
        } else {
            $queue = @()
        }

        $queue += $entry
        $queue | ConvertTo-Json -Depth 10 | Set-Content $script:QueueFilePath -Encoding UTF8

        return $queue.Count
    } finally {
        if ($lockStream) { $lockStream.Close() }
        Remove-Item $script:QueueLockPath -Force -ErrorAction SilentlyContinue
    }
}

function Read-QueueFile {
    if (-not (Test-Path $script:QueueFilePath)) {
        return @()
    }

    $queue = Get-Content $script:QueueFilePath -Raw | ConvertFrom-Json
    if ($null -eq $queue) { return @() }
    if ($queue -isnot [System.Array]) { $queue = @($queue) }
    return $queue
}

function Remove-FromQueue {
    param([object]$Entry)

    $retryCount = 0
    $maxRetries = 10
    $lockAcquired = $false

    while (-not $lockAcquired -and $retryCount -lt $maxRetries) {
        try {
            $lockStream = [System.IO.File]::Open($script:QueueLockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $lockAcquired = $true
        } catch {
            $retryCount++
            Start-Sleep -Milliseconds 500
        }
    }

    if (-not $lockAcquired) {
        Write-Host "WARNING: Could not acquire lock file - removing without lock" -ForegroundColor Red
    }

    try {
        if (Test-Path $script:QueueFilePath) {
            $queue = Get-Content $script:QueueFilePath -Raw | ConvertFrom-Json
            if ($null -eq $queue) { return }
            if ($queue -isnot [System.Array]) { $queue = @($queue) }

            # Remove the matching entry (match by Album + Artist + QueuedAt)
            $queue = @($queue | Where-Object {
                $_.Album -ne $Entry.Album -or $_.Artist -ne $Entry.Artist -or $_.QueuedAt -ne $Entry.QueuedAt
            })

            if ($queue.Count -eq 0) {
                Remove-Item $script:QueueFilePath -Force -ErrorAction SilentlyContinue
            } else {
                $queue | ConvertTo-Json -Depth 10 | Set-Content $script:QueueFilePath -Encoding UTF8
            }
        }
    } finally {
        if ($lockStream) { $lockStream.Close() }
        Remove-Item $script:QueueLockPath -Force -ErrorAction SilentlyContinue
    }
}

# ========== PARAMETER VALIDATION ==========
if ($Queue -and $ProcessQueue) {
    Write-Host "ERROR: -Queue and -ProcessQueue are mutually exclusive" -ForegroundColor Red
    exit 1
}
# Note: -album is now optional — disc metadata will be auto-discovered if not provided

# ========== CONFIGURATION ==========

# Auto-detect CD/optical drive if not specified
if (-not $Drive) {
    $opticalDrives = @(Get-CimInstance Win32_CDROMDrive -ErrorAction SilentlyContinue | Where-Object { $_.Drive })
    if ($opticalDrives.Count -eq 0) {
        Write-Host "ERROR: No optical drive detected. Use -Drive to specify the drive letter." -ForegroundColor Red
        exit 1
    } elseif ($opticalDrives.Count -eq 1) {
        $Drive = $opticalDrives[0].Drive
        Write-Host "Detected optical drive: $Drive ($($opticalDrives[0].Name))" -ForegroundColor Gray
    } else {
        Write-Host "Multiple optical drives detected:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $opticalDrives.Count; $i++) {
            Write-Host "  $($i + 1): $($opticalDrives[$i].Drive) - $($opticalDrives[$i].Name)" -ForegroundColor White
        }
        $driveChoice = $null
        while (-not $driveChoice) {
            $input = Read-Host "Select drive (1-$($opticalDrives.Count))"
            if ($input -match '^\d+$' -and [int]$input -ge 1 -and [int]$input -le $opticalDrives.Count) {
                $Drive = $opticalDrives[[int]$input - 1].Drive
                $driveChoice = $Drive
            } else {
                Write-Host "Invalid selection. Enter a number between 1 and $($opticalDrives.Count)" -ForegroundColor Yellow
            }
        }
    }
}

# Default output drive to system drive if not specified
if (-not $OutputDrive) {
    $OutputDrive = $env:SystemDrive
    Write-Host "Output drive defaulting to: $OutputDrive" -ForegroundColor Gray
}

# Normalize drive letters (add colon if missing)
$driveLetter = if ($Drive -match ':$') { $Drive } else { "${Drive}:" }
$outputDriveLetter = if ($OutputDrive -match ':$') { $OutputDrive } else { "${OutputDrive}:" }

# Validate format parameter (supports comma-separated for multiple formats, e.g. "flac,mp3")
$validFormats = @("flac", "mp3", "opus", "aac", "wav", "alac")
$lossyFormats = @("mp3", "opus", "aac")
$formatList = $format -split ',' | ForEach-Object { $_.Trim() }
$primaryFormat = $formatList[0]

if (-not $ProcessQueue) {
    foreach ($f in $formatList) {
        if ($f -notin $validFormats) {
            Write-Host "ERROR: Invalid format '$f'. Valid formats: $($validFormats -join ', ')" -ForegroundColor Red
            exit 1
        }
    }
}

# Validate quality parameter
if ($Quality -gt 0) {
    $hasLossy = ($formatList | Where-Object { $_ -in $lossyFormats }).Count -gt 0
    if (-not $ProcessQueue -and -not $hasLossy) {
        Write-Host "ERROR: -Quality only applies to lossy formats ($($lossyFormats -join ', ')), not '$format'" -ForegroundColor Red
        exit 1
    }
    if ($Quality -lt 32 -or $Quality -gt 320) {
        Write-Host "ERROR: -Quality must be between 32 and 320 (kbps)" -ForegroundColor Red
        exit 1
    }
}

# ========== QUEUE MODE: ADD TO QUEUE ==========
if ($Queue) {
    foreach ($f in $formatList) {
        if ($f -notin $validFormats) {
            Write-Host "ERROR: Invalid format '$f'. Valid formats: $($validFormats -join ', ')" -ForegroundColor Red
            exit 1
        }
    }

    $queueDir = Split-Path $script:QueueFilePath -Parent
    if (!(Test-Path $queueDir)) { New-Item -ItemType Directory -Path $queueDir -Force | Out-Null }

    $totalJobs = Add-ToQueue -Album $album -Artist $artist -Format $format -Bitrate $Quality

    $queueLabel = if ($artist) { "$artist - $album" } else { $album }
    Write-Host "`n========================================" -ForegroundColor Magenta
    Write-Host "QUEUED!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "  Album:  $album" -ForegroundColor White
    if ($artist) {
        Write-Host "  Artist: $artist" -ForegroundColor White
    }
    $formatDisplay = $format
    if ($Quality -gt 0) { $formatDisplay += " @ ${Quality}kbps" }
    Write-Host "  Format: $formatDisplay" -ForegroundColor White
    Write-Host "  Total jobs in queue: $totalJobs" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Magenta
    $host.UI.RawUI.WindowTitle = "$queueLabel - QUEUED"
    exit 0
}

# ========== PROCESSING LOOP ==========
$script:IsProcessingQueue = $ProcessQueue.IsPresent
$queueStats = @{ Processed = 0; Failed = 0; Skipped = 0 }
$script:CddbResult = $null

do {
    # Reset per-album state
    $script:CompletedSteps = @()
    $script:CurrentStep = $null
    $script:CddbResult = $null
    $script:ReleaseChoice = $null
    $script:ResumeTrackList = $null
    $script:MetadataSource = "MusicBrainz"
    $script:CoverArtSource = ""
    $script:SkipRip = $false
    $itemFailed = $false

    if ($script:IsProcessingQueue) {
        # Re-read queue each iteration to pick up concurrent additions
        $queue = Read-QueueFile
        if ($queue.Count -eq 0) {
            Write-Host "`nQueue is empty!" -ForegroundColor Green
            break
        }

        $currentEntry = $queue[0]
        $entryLabel = if ($currentEntry.Artist) { "$($currentEntry.Artist) - $($currentEntry.Album)" } else { $currentEntry.Album }

        Write-Host "`n========================================" -ForegroundColor Magenta
        Write-Host "QUEUE: $($queue.Count) album(s) remaining" -ForegroundColor Magenta
        Write-Host "Next: $entryLabel" -ForegroundColor White
        Write-Host "========================================" -ForegroundColor Magenta

        $queuePrompt = Read-Host "Insert disc for [$entryLabel], press Enter to continue (S to skip, Q to quit)"
        if ($queuePrompt -match '^[Ss]') {
            Remove-FromQueue -Entry $currentEntry
            $queueStats.Skipped++
            continue
        }
        if ($queuePrompt -match '^[Qq]') {
            break
        }

        # Override variables from queue entry
        $album = $currentEntry.Album
        $artist = $currentEntry.Artist
        $format = if ($currentEntry.Format) { $currentEntry.Format } else { "flac" }
        $Quality = if ($currentEntry.Quality) { [int]$currentEntry.Quality } else { 0 }
        $formatList = $format -split ',' | ForEach-Object { $_.Trim() }
        $primaryFormat = $formatList[0]

        # Validate format from queue entry
        $invalidQueueFormat = $formatList | Where-Object { $_ -notin $validFormats } | Select-Object -First 1
        if ($invalidQueueFormat) {
            Write-Host "ERROR: Invalid format '$invalidQueueFormat' in queue entry for $entryLabel. Skipping." -ForegroundColor Red
            Remove-FromQueue -Entry $currentEntry
            $queueStats.Failed++
            continue
        }
    }

try { # try block wraps main processing - catch handles ProcessQueue failures

# ========== DISC METADATA DISCOVERY ==========
# When -album is not provided and not in ProcessQueue mode, auto-discover from disc
$script:ReleaseChoice = $null
if (-not $album -and -not $script:IsProcessingQueue) {
    $discMeta = Get-DiscMetadata -DriveLetter $driveLetter

    if ($discMeta -and $discMeta.Album) {
        $album = $discMeta.Album

        # For multi-disc albums with >1 disc, append "Disc N"
        if ($discMeta.TotalDiscs -and $discMeta.TotalDiscs -gt 1 -and $discMeta.DiscNum) {
            $album = "$album Disc $($discMeta.DiscNum)"
        }

        if ($discMeta.Artist) {
            $artist = $discMeta.Artist
        }

        if ($discMeta.ReleaseChoice) {
            $script:ReleaseChoice = $discMeta.ReleaseChoice
        }

        # Display detected metadata
        $detectedLabel = if ($artist) { "$artist - $album" } else { $album }
        if ($discMeta.TotalDiscs -and $discMeta.TotalDiscs -gt 1) {
            $detectedLabel += " (Disc $($discMeta.DiscNum) of $($discMeta.TotalDiscs))"
        }
        Write-Host "Detected: $detectedLabel" -ForegroundColor Green
    } else {
        # Discovery failed — prompt user for album name
        Write-Host "`nCould not auto-detect disc metadata." -ForegroundColor Yellow
        Write-Host "Please provide album details manually." -ForegroundColor Yellow
        $album = Read-Host "Album name (required)"
        if (-not $album) {
            Write-Host "ERROR: Album name is required." -ForegroundColor Red
            exit 1
        }
        $artistInput = Read-Host "Artist name (optional, press Enter to skip)"
        if ($artistInput) {
            $artist = $artistInput
        }
    }
}

# Sanitize album and artist for use as directory names.
# Removes: illegal Windows path characters, dots (trailing dots make NTFS silently rename the folder),
# and hyphens. Collapses multiple spaces and trims.
$safeAlbum = (($album  -replace '[\\/:*?"<>|.-]', '') -replace '\s+', ' ').Trim()
$safeArtist = if ($artist) { (($artist -replace '[\\/:*?"<>|.-]', '') -replace '\s+', ' ').Trim() } else { "" }

# Build output directory path
# Format: E:\Music\{Artist}\{Album}\ or E:\Music\{Album}\ if no artist
if ($safeArtist) {
    $finalOutputDir = "$outputDriveLetter\Music\$safeArtist\$safeAlbum"
} else {
    $finalOutputDir = "$outputDriveLetter\Music\$safeAlbum"
}

# ========== PATH LENGTH VALIDATION ==========
# Check worst-case output path against Windows MAX_PATH (260 chars) before starting
$MAX_PATH = 260
$worstCaseFilename = "01 - $(if ($artist) { $artist } else { 'Unknown Artist' }) - $album.$primaryFormat"
# Sanitize the same way the rename logic does
$worstCaseFilename = $worstCaseFilename -replace '[\\/:*?"<>|]', '_'
$worstCasePath = Join-Path $finalOutputDir $worstCaseFilename
$pathLength = $worstCasePath.Length
$WARNING_THRESHOLD = $MAX_PATH - 20

if ($pathLength -ge $MAX_PATH) {
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "PATH TOO LONG" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "`nThe worst-case output path exceeds the Windows MAX_PATH limit ($MAX_PATH chars)." -ForegroundColor Red
    Write-Host "`n  Directory:  $finalOutputDir" -ForegroundColor White
    Write-Host "  Filename:   $worstCaseFilename" -ForegroundColor White
    Write-Host "  Total:      $pathLength chars (limit: $MAX_PATH)" -ForegroundColor Yellow
    Write-Host "`nSuggestions:" -ForegroundColor Cyan
    Write-Host "  - Use a shorter album name with -album" -ForegroundColor White
    Write-Host "  - Use a shorter artist name with -artist" -ForegroundColor White
    Write-Host "  - Change the output drive to one with a shorter base path" -ForegroundColor White
    Write-Host ""

    if ($script:IsProcessingQueue) {
        Write-Host "ProcessQueue mode: auto-continuing despite path length..." -ForegroundColor Yellow
    } else {
        $pathChoice = Read-Host "Continue anyway? (y/N)"
        if ($pathChoice -notmatch "^[Yy]") {
            Write-Host "Aborted by user." -ForegroundColor Yellow
            exit 0
        }
    }
    Write-Host "Continuing despite path length warning..." -ForegroundColor Yellow
} elseif ($pathLength -ge $WARNING_THRESHOLD) {
    Write-Host "`n--- PATH LENGTH WARNING ---" -ForegroundColor Yellow
    Write-Host "The output path is within 20 chars of the Windows MAX_PATH limit." -ForegroundColor Yellow
    Write-Host "  Directory:  $finalOutputDir" -ForegroundColor White
    Write-Host "  Filename:   $worstCaseFilename" -ForegroundColor White
    Write-Host "  Total:      $pathLength chars (limit: $MAX_PATH)" -ForegroundColor White
    Write-Host "  Remaining:  $($MAX_PATH - $pathLength) chars" -ForegroundColor White
    Write-Host ""
}

# ========== DRIVE CONFIRMATION ==========
# Show which drive will be used and confirm before proceeding
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Ready to rip: $album" -ForegroundColor White
if ($artist) {
    Write-Host "Artist: $artist" -ForegroundColor White
}
$bannerFormat = $format
if ($Quality -gt 0) { $bannerFormat += " @ ${Quality}kbps" }
Write-Host "Format: $bannerFormat" -ForegroundColor White
Write-Host "Using drive: $driveLetter" -ForegroundColor Yellow
Write-Host "Output drive: $outputDriveLetter" -ForegroundColor Yellow
Write-Host "Output path: $finalOutputDir" -ForegroundColor Yellow
if ($RequireMusicBrainz) {
    Write-Host "MusicBrainz: REQUIRED" -ForegroundColor Yellow
}
Write-Host "========================================" -ForegroundColor Cyan
if (-not $script:IsProcessingQueue) {
    $host.UI.RawUI.WindowTitle = "rip-audio - INPUT"
    $response = Read-Host "Press Enter to continue, or Ctrl+C to abort"
}

# Disable close button to prevent accidental window closure during rip
Disable-ConsoleClose

# ========== SET WINDOW TITLE ==========
# Set PowerShell window title to help identify concurrent rips
if ($artist) {
    $windowTitle = "$artist - $album"
} else {
    $windowTitle = "$album"
}
$host.UI.RawUI.WindowTitle = $windowTitle

# ========== LOGGING SETUP ==========
$logDir = "C:\Music\logs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
# Sanitize album name for log file (remove invalid filename characters)
$logAlbumName = $album -replace '[\\/:*?"<>|]', '_'
if ($artist) {
    $logArtistName = $artist -replace '[\\/:*?"<>|]', '_'
    $script:LogFile = Join-Path $logDir "${logArtistName}_${logAlbumName}_${logTimestamp}.log"
} else {
    $script:LogFile = Join-Path $logDir "${logAlbumName}_${logTimestamp}.log"
}

Write-Log "========== RIP SESSION STARTED =========="
Write-Log "Album: $album"
if ($artist) {
    Write-Log "Artist: $artist"
}
Write-Log "Format: $bannerFormat"
Write-Log "Drive: $driveLetter"
Write-Log "Output Drive: $outputDriveLetter"
Write-Log "Final Output: $finalOutputDir"
Write-Log "RequireMusicBrainz: $RequireMusicBrainz"
Write-Log "Log file: $($script:LogFile)"

function Stop-WithError {
    param([string]$Step, [string]$Message)

    $host.UI.RawUI.WindowTitle = "$($host.UI.RawUI.WindowTitle) - ERROR"

    # Log the error
    Write-Log "========== ERROR =========="
    Write-Log "Failed at: $Step"
    Write-Log "Message: $Message"
    if ($script:CompletedSteps.Count -gt 0) {
        Write-Log "Completed steps: $(($script:CompletedSteps | ForEach-Object { "Step $($_.Number): $($_.Name)" }) -join ', ')"
    } else {
        Write-Log "Completed steps: (none)"
    }
    $remaining = Get-RemainingSteps
    if ($remaining.Count -gt 0) {
        Write-Log "Remaining steps: $(($remaining | ForEach-Object { "Step $($_.Number): $($_.Name)" }) -join ', ')"
    }
    Write-Log "Log file: $($script:LogFile)"

    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "FAILED!" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red

    # Always show what was being processed
    Write-Host "`nProcessing: $(Get-AlbumSummary)" -ForegroundColor White

    Write-Host "`nError at: $Step" -ForegroundColor Red
    Write-Host "Message: $Message" -ForegroundColor Red

    # Show completed and remaining steps
    Show-StepsSummary -ShowRemaining

    # Show manual steps the user needs to handle
    Write-Host "`n--- MANUAL STEPS NEEDED ---" -ForegroundColor Cyan
    $remaining = Get-RemainingSteps
    foreach ($step in $remaining) {
        switch ($step.Number) {
            1 { Write-Host "  - Re-run cyanrip to rip the disc" -ForegroundColor Yellow }
            2 { Write-Host "  - Verify audio files were created" -ForegroundColor Yellow }
            3 { Write-Host "  - Open output directory to verify files" -ForegroundColor Yellow }
        }
    }

    # Open the relevant directory if it exists (skip in ProcessQueue mode)
    if (-not $script:IsProcessingQueue -and (Test-Path $finalOutputDir)) {
        Write-Host "`n--- OPENING DIRECTORY ---" -ForegroundColor Cyan
        Write-Host "Opening: $finalOutputDir" -ForegroundColor Yellow
        Start-Process explorer.exe -ArgumentList $finalOutputDir
    }

    Write-Host "`nLog file: $($script:LogFile)" -ForegroundColor Yellow
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "Please complete the remaining steps manually" -ForegroundColor Red
    Write-Host "========================================`n" -ForegroundColor Red
    Enable-ConsoleClose

    if ($script:IsProcessingQueue) {
        throw "QUEUE_ITEM_FAILED"
    }
    exit 1
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Audio CD Ripping Script (cyanrip)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Album: $album" -ForegroundColor White
if ($artist) {
    Write-Host "Artist: $artist" -ForegroundColor White
}
Write-Host "Format: $bannerFormat" -ForegroundColor White
Write-Host "Drive: $driveLetter" -ForegroundColor White
Write-Host "Output Drive: $outputDriveLetter" -ForegroundColor White
Write-Host "Final Output: $finalOutputDir" -ForegroundColor White
Write-Host "Log file: $($script:LogFile)" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

# ========== STEP 1: RIP WITH CYANRIP ==========
Set-CurrentStep -StepNumber 1
Write-Log "STEP 1/4: Starting cyanrip..."
Write-Host "[STEP 1/4] Starting cyanrip..." -ForegroundColor Green

# Check if destination drive is ready before attempting to create directories
Write-Host "Checking destination drive..." -ForegroundColor Yellow
$driveCheck = Test-DriveReady -Path $finalOutputDir
if (-not $driveCheck.Ready) {
    Stop-WithError -Step "STEP 1/4: Drive check" -Message $driveCheck.Message
}
Write-Host "Destination drive $($driveCheck.Drive) is ready" -ForegroundColor Green

# Create output directory if it doesn't exist
Write-Host "Creating directory: $finalOutputDir" -ForegroundColor Yellow
if (!(Test-Path $finalOutputDir)) {
    New-Item -ItemType Directory -Path $finalOutputDir -Force | Out-Null
    Write-Host "Directory created successfully" -ForegroundColor Green
} else {
    # Check for existing files
    $existingFiles = Get-ChildItem -Path $finalOutputDir -File -ErrorAction SilentlyContinue
    if ($existingFiles -and $existingFiles.Count -gt 0) {
        Write-Host "`nWARNING: Directory already exists with $($existingFiles.Count) file(s):" -ForegroundColor Yellow
        Write-Host "  $finalOutputDir" -ForegroundColor White
        foreach ($ef in $existingFiles | Select-Object -First 5) {
            Write-Host "  - $($ef.Name)" -ForegroundColor Gray
        }
        if ($existingFiles.Count -gt 5) {
            Write-Host "  ... and $($existingFiles.Count - 5) more" -ForegroundColor Gray
        }

        # Check for existing audio files and attempt resume logic
        $formatExtMap = @{ "flac" = "*.flac"; "mp3" = "*.mp3"; "opus" = "*.opus"; "aac" = "*.m4a"; "wav" = "*.wav"; "alac" = "*.m4a" }
        $existingAudioFiles = @()
        $primaryExt = $formatExtMap[$primaryFormat]
        if ($primaryExt) {
            $existingAudioFiles = @(Get-ChildItem -Path $finalOutputDir -Filter $primaryExt -ErrorAction SilentlyContinue)
        }
        # If no files in primary format, check all audio formats
        if ($existingAudioFiles.Count -eq 0) {
            foreach ($fmt in $formatList) {
                $ext = $formatExtMap[$fmt]
                if ($ext) {
                    $existingAudioFiles = @(Get-ChildItem -Path $finalOutputDir -Filter $ext -ErrorAction SilentlyContinue)
                    if ($existingAudioFiles.Count -gt 0) { break }
                }
            }
        }

        $totalTrackCount = $null
        $script:ResumeTrackList = $null

        if ($existingAudioFiles.Count -gt 0) {
            # Try to determine total track count from cue file or disc
            $totalTrackCount = Get-DiscTrackCount -OutputDir $finalOutputDir -DriveLetter $driveLetter
        }

        if ($totalTrackCount -and $existingAudioFiles.Count -gt 0) {
            # Parse track numbers from existing filenames and validate integrity
            $validTracks = @()
            $invalidTracks = @()
            foreach ($af in $existingAudioFiles) {
                $trackNum = $null
                # Handle both "01 - Title.flac" and "1.01 - Title.flac" (multi-disc) formats
                if ($af.BaseName -match '^(\d+)\.(\d+)\s*-') {
                    # Multi-disc format: disc.track -- use the track part
                    $trackNum = [int]$Matches[2]
                } elseif ($af.BaseName -match '^(\d+)\s*-') {
                    $trackNum = [int]$Matches[1]
                }

                if ($trackNum) {
                    if (Test-TrackIntegrity -FilePath $af.FullName) {
                        $validTracks += $trackNum
                    } else {
                        $invalidTracks += $trackNum
                    }
                }
            }

            $validTracks = $validTracks | Sort-Object -Unique
            $allDiscTracks = 1..$totalTrackCount
            $missingTracks = @($allDiscTracks | Where-Object { $_ -notin $validTracks })

            if ($missingTracks.Count -eq 0) {
                # All tracks already ripped and valid
                Write-Host "`nAll $totalTrackCount tracks already ripped and valid." -ForegroundColor Green
                if ($invalidTracks.Count -gt 0) {
                    Write-Host "  ($($invalidTracks.Count) invalid file(s) will be overwritten)" -ForegroundColor Yellow
                }

                if ($script:IsProcessingQueue) {
                    Write-Host "ProcessQueue mode: all tracks valid, skipping rip." -ForegroundColor Yellow
                    Write-Log "All $totalTrackCount tracks already valid - skipping rip (ProcessQueue)"
                    # Skip straight to step 2 (verify) by jumping past the rip
                    $script:ResumeTrackList = $null
                    $script:SkipRip = $true
                } else {
                    Write-Host "`nSkip rip? (all tracks present)" -ForegroundColor Cyan
                    Write-Host "  [1] Skip (keep existing files)" -ForegroundColor Yellow
                    Write-Host "  [2] Re-rip all tracks from scratch" -ForegroundColor Yellow
                    Write-Host "  [3] Abort" -ForegroundColor Yellow

                    $choice = $null
                    while ($choice -ne '1' -and $choice -ne '2' -and $choice -ne '3') {
                        $choice = Read-Host "Enter 1, 2, or 3"
                        if ($choice -ne '1' -and $choice -ne '2' -and $choice -ne '3') {
                            Write-Host "Invalid choice. Please enter 1, 2, or 3." -ForegroundColor Red
                        }
                    }

                    if ($choice -eq '1') {
                        Write-Host "Skipping rip - using existing files." -ForegroundColor Green
                        Write-Log "All $totalTrackCount tracks valid - user chose to skip rip"
                        $script:SkipRip = $true
                    } elseif ($choice -eq '3') {
                        Write-Host "Aborted by user." -ForegroundColor Yellow
                        Enable-ConsoleClose
                        exit 0
                    } else {
                        Write-Host "Re-ripping all tracks from scratch." -ForegroundColor Yellow
                        Write-Log "User chose to re-rip all tracks"
                    }
                }
            } elseif ($validTracks.Count -eq 0) {
                # No valid tracks -- fall back to simple menu (nothing to resume from)
                Write-Host "`nNo valid tracks found (0/$totalTrackCount)." -ForegroundColor Yellow
                if ($invalidTracks.Count -gt 0) {
                    Write-Host "  $($invalidTracks.Count) file(s) found but failed integrity check." -ForegroundColor Yellow
                }

                if ($script:IsProcessingQueue) {
                    Write-Host "ProcessQueue mode: auto-continuing (full rip)..." -ForegroundColor Yellow
                } else {
                    Write-Host "`nChoose an option:" -ForegroundColor Cyan
                    Write-Host "  [1] Continue (rip all tracks)" -ForegroundColor Yellow
                    Write-Host "  [2] Abort" -ForegroundColor Yellow

                    $choice = $null
                    while ($choice -ne '1' -and $choice -ne '2') {
                        $choice = Read-Host "Enter 1 or 2"
                        if ($choice -ne '1' -and $choice -ne '2') {
                            Write-Host "Invalid choice. Please enter 1 or 2." -ForegroundColor Red
                        }
                    }

                    if ($choice -eq '2') {
                        Write-Host "Aborted by user." -ForegroundColor Yellow
                        Enable-ConsoleClose
                        exit 0
                    }
                }
                Write-Log "No valid tracks found - continuing with full rip"
            } else {
                # Partial rip -- offer resume
                $validList = ($validTracks | ForEach-Object { $_.ToString() }) -join ", "
                $missingList = ($missingTracks | ForEach-Object { $_.ToString() }) -join ", "
                Write-Host "`nValid: $($validTracks.Count)/$totalTrackCount tracks ($validList)" -ForegroundColor Green
                Write-Host "Missing: $($missingTracks.Count) tracks ($missingList)" -ForegroundColor Yellow
                if ($invalidTracks.Count -gt 0) {
                    $invalidList = ($invalidTracks | ForEach-Object { $_.ToString() }) -join ", "
                    Write-Host "Invalid (will re-rip): $($invalidTracks.Count) tracks ($invalidList)" -ForegroundColor Yellow
                    # Add invalid tracks to missing list for re-rip
                    $missingTracks = @($missingTracks + $invalidTracks | Sort-Object -Unique)
                    $missingList = ($missingTracks | ForEach-Object { $_.ToString() }) -join ", "
                }

                if ($script:IsProcessingQueue) {
                    # Auto-resume in ProcessQueue mode
                    Write-Host "ProcessQueue mode: auto-resuming (ripping tracks $missingList)..." -ForegroundColor Yellow
                    $script:ResumeTrackList = ($missingTracks | ForEach-Object { $_.ToString() }) -join ","
                    Write-Log "Auto-resuming: ripping tracks $missingList ($($missingTracks.Count) of $totalTrackCount)"
                } else {
                    Write-Host "`nChoose an option:" -ForegroundColor Cyan
                    Write-Host "  [1] Resume (rip tracks $missingList only)" -ForegroundColor Yellow
                    Write-Host "  [2] Re-rip all tracks from scratch" -ForegroundColor Yellow
                    Write-Host "  [3] Abort" -ForegroundColor Yellow

                    $choice = $null
                    while ($choice -ne '1' -and $choice -ne '2' -and $choice -ne '3') {
                        $choice = Read-Host "Enter 1, 2, or 3"
                        if ($choice -ne '1' -and $choice -ne '2' -and $choice -ne '3') {
                            Write-Host "Invalid choice. Please enter 1, 2, or 3." -ForegroundColor Red
                        }
                    }

                    if ($choice -eq '1') {
                        $script:ResumeTrackList = ($missingTracks | ForEach-Object { $_.ToString() }) -join ","
                        Write-Host "Resuming: will rip tracks $missingList only." -ForegroundColor Green
                        Write-Log "Resuming: ripping tracks $missingList ($($missingTracks.Count) of $totalTrackCount)"
                    } elseif ($choice -eq '3') {
                        Write-Host "Aborted by user." -ForegroundColor Yellow
                        Enable-ConsoleClose
                        exit 0
                    } else {
                        Write-Host "Re-ripping all tracks from scratch." -ForegroundColor Yellow
                        Write-Log "User chose to re-rip all tracks"
                    }
                }
            }
        } else {
            # Could not determine track count -- fall back to original 2-option menu
            if ($script:IsProcessingQueue) {
                Write-Host "ProcessQueue mode: auto-continuing with existing directory..." -ForegroundColor Yellow
            } else {
                Write-Host "`nChoose an option:" -ForegroundColor Cyan
                Write-Host "  [1] Continue (may overwrite existing files)" -ForegroundColor Yellow
                Write-Host "  [2] Abort" -ForegroundColor Yellow

                $choice = $null
                while ($choice -ne '1' -and $choice -ne '2') {
                    $choice = Read-Host "Enter 1 or 2"
                    if ($choice -ne '1' -and $choice -ne '2') {
                        Write-Host "Invalid choice. Please enter 1 or 2." -ForegroundColor Red
                    }
                }

                if ($choice -eq '2') {
                    Write-Host "Aborted by user." -ForegroundColor Yellow
                    Enable-ConsoleClose
                    exit 0
                }
            }
            Write-Log "User chose to continue with existing directory"
        }
    } else {
        Write-Host "Directory already exists (empty)" -ForegroundColor Gray
    }
}

# Build cyanrip command
# cyanrip options:
#   -D <dir>  : Output directory
#   -o <fmt>  : Output format (flac, mp3, opus, etc.)
#   -d <dev>  : CD drive device (e.g., D:)
#   MusicBrainz lookup is automatic

if ($script:SkipRip) {
    Write-Host "`nSkipping rip - all tracks already present." -ForegroundColor Green
    Write-Log "STEP 1/4: Skipped (all tracks already valid)"
    Complete-CurrentStep
} else {
# Test MusicBrainz API connectivity before starting
# Note: The API (musicbrainz.org/ws/2/) is different from the website and requires User-Agent
Write-Host "`nChecking MusicBrainz API connectivity..." -ForegroundColor Yellow
$skipMusicBrainz = $false
$mbHeaders = @{ "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)" }
try {
    # Test the actual API endpoint that cyanrip uses
    $mbTest = Invoke-WebRequest -Uri "https://musicbrainz.org/ws/2/release?query=test&limit=1" -Headers $mbHeaders -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
    Write-Host "MusicBrainz API: OK" -ForegroundColor Green
} catch {
    Write-Host "MusicBrainz API: UNREACHABLE" -ForegroundColor Red
    Write-Host "  (API may be down, rate-limited, or blocked)" -ForegroundColor Gray

    # In ProcessQueue mode, auto-continue without metadata (unless RequireMusicBrainz is set)
    if ($script:IsProcessingQueue -and -not $RequireMusicBrainz) {
        Write-Host "ProcessQueue mode: auto-continuing without MusicBrainz metadata" -ForegroundColor Yellow
        Write-Log "MusicBrainz API unreachable - ProcessQueue auto-continuing without metadata"
        $skipMusicBrainz = $true
        $script:MetadataSource = "Generic"
    } elseif ($RequireMusicBrainz) {
        Write-Host "`n  -RequireMusicBrainz is set, cannot continue without MusicBrainz." -ForegroundColor Red
        Write-Host "  [R] Retry connection" -ForegroundColor White
        Write-Host "  [Q] Quit" -ForegroundColor White
        Write-Host ""

        $resolved = $false
        while (-not $resolved) {
            $mbChoice = Read-Host "Choice (R/q)"
            if ($mbChoice -eq "" -or $mbChoice -match "^[Rr]") {
                Write-Host "Retrying..." -ForegroundColor Yellow
                try {
                    $mbTest = Invoke-WebRequest -Uri "https://musicbrainz.org/ws/2/release?query=test&limit=1" -Headers $mbHeaders -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
                    Write-Host "MusicBrainz API: OK" -ForegroundColor Green
                    $resolved = $true
                } catch {
                    Write-Host "MusicBrainz API: Still unreachable" -ForegroundColor Red
                    Write-Host "  [R] Retry | [Q] Quit" -ForegroundColor White
                }
            } elseif ($mbChoice -match "^[Qq]") {
                Write-Host "Aborted by user." -ForegroundColor Yellow
                Enable-ConsoleClose
                exit 0
            } else {
                Write-Host "Invalid choice. Enter R or Q" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  [R] Retry connection" -ForegroundColor White
        Write-Host "  [C] Continue without metadata (generic track names)" -ForegroundColor White
        Write-Host "  [Q] Quit" -ForegroundColor White
        Write-Host ""

        $resolved = $false
        while (-not $resolved) {
            $mbChoice = Read-Host "Choice (R/c/q)"
            if ($mbChoice -eq "" -or $mbChoice -match "^[Rr]") {
                Write-Host "Retrying..." -ForegroundColor Yellow
                try {
                    $mbTest = Invoke-WebRequest -Uri "https://musicbrainz.org/ws/2/release?query=test&limit=1" -Headers $mbHeaders -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
                    Write-Host "MusicBrainz API: OK" -ForegroundColor Green
                    $resolved = $true
                } catch {
                    Write-Host "MusicBrainz API: Still unreachable" -ForegroundColor Red
                    Write-Host "  [R] Retry | [C] Continue without metadata | [Q] Quit" -ForegroundColor White
                }
            } elseif ($mbChoice -match "^[Cc]") {
                Write-Host "Will continue without MusicBrainz metadata" -ForegroundColor Yellow
                Write-Log "MusicBrainz API unreachable - user chose to continue without metadata"
                $skipMusicBrainz = $true
                $script:MetadataSource = "Generic"
                $resolved = $true
            } elseif ($mbChoice -match "^[Qq]") {
                Write-Host "Aborted by user." -ForegroundColor Yellow
                Enable-ConsoleClose
                exit 0
            } else {
                Write-Host "Invalid choice. Enter R, C, or Q" -ForegroundColor Yellow
            }
        }
    }
}

# Save disc ID to .discid file for future metadata lookups
if ($discMeta -and $discMeta.DiscId) {
    $discIdFile = Join-Path $finalOutputDir ".discid"
    $discIdContent = @(
        "# MusicBrainz Disc ID - do not edit"
        "# Created by rip-audio.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "DISCID=$($discMeta.DiscId)"
    )
    if ($discMeta.ReleaseId) {
        $discIdContent += "RELEASEID=$($discMeta.ReleaseId)"
    }
    $discIdContent | Set-Content -Path $discIdFile -Encoding UTF8
    Write-Host "Saved disc ID: $($discMeta.DiscId)" -ForegroundColor Gray
    Write-Log "Saved .discid file: $($discMeta.DiscId)"
}

Write-Host "`nExecuting cyanrip command..." -ForegroundColor Yellow

# cyanrip's -D option is a naming scheme, not an absolute path
# We need to: 1) cd to parent directory, 2) use album folder name for -D
$parentDir = Split-Path -Parent $finalOutputDir
$albumFolder = Split-Path -Leaf $finalOutputDir

# Build the cyanrip arguments
# Let cyanrip query MusicBrainz for metadata (track names, album art, etc.)
$cyanripArgs = @(
    "-D", $albumFolder,
    "-o", $format,
    "-d", $driveLetter,
    "-s", "0"
)

# Add bitrate flag for lossy formats
$hasLossy = ($formatList | Where-Object { $_ -in $lossyFormats }).Count -gt 0
if ($Quality -gt 0 -and $hasLossy) {
    $cyanripArgs += @("-b", "$Quality")
}

# Add -N flag if user chose to skip MusicBrainz
if ($skipMusicBrainz) {
    $cyanripArgs += @("-N")
}

# Add -R flag if release was pre-selected during discovery
if ($script:ReleaseChoice) {
    $cyanripArgs += @("-R", $script:ReleaseChoice)
}

# Add -l flag for resume mode (rip only missing tracks)
if ($script:ResumeTrackList) {
    $cyanripArgs += @("-l", $script:ResumeTrackList)
}

$qualityFlag = if ($Quality -gt 0 -and $hasLossy) { " -b $Quality" } else { "" }
$releaseFlag = if ($script:ReleaseChoice) { " -R $($script:ReleaseChoice)" } else { "" }
$resumeFlag = if ($script:ResumeTrackList) { " -l $($script:ResumeTrackList)" } else { "" }
$cmdDisplay = "cyanrip -D `"$albumFolder`" -o $format -d $driveLetter -s 0$qualityFlag$(if ($skipMusicBrainz) { ' -N' })$releaseFlag$resumeFlag"
Write-Host "Working directory: $parentDir" -ForegroundColor Gray
Write-Host "Command: $cmdDisplay" -ForegroundColor Gray
Write-Log "cyanrip working directory: $parentDir"
Write-Log "cyanrip command: $cmdDisplay"

# Execute cyanrip from the parent directory (streaming output in real-time)
Push-Location $parentDir
try {
    $outputLines = [System.Collections.ArrayList]::new()
    & cyanrip @cyanripArgs 2>&1 | ForEach-Object {
        $line = [string]$_
        # Show non-progress lines (track completions, errors, metadata) but suppress per-% progress spam
        if ($line -notmatch 'progress - \d+\.\d+%') {
            Write-Host $line
        }
        [void]$outputLines.Add($line)
    }
    $cyanripExitCode = $LASTEXITCODE
    $cyanripOutput = $outputLines.ToArray()
} catch {
    Pop-Location
    Stop-WithError -Step "STEP 1/4: cyanrip" -Message "Failed to execute cyanrip: $_"
}
Pop-Location

$cyanripOutputText = $cyanripOutput -join "`n"

# Check if multiple MusicBrainz releases were found - prompt user to select
if ($cyanripOutputText -match "Multiple releases found" -and $cyanripOutputText -match "Please specify which release") {
    Write-Host "`n" -NoNewline

    # Parse the release options from the output
    $releases = @()
    foreach ($line in $cyanripOutput) {
        if ($line -match '^\s*(\d+)\s+\(ID:.*?\):\s*(.+)$') {
            $releases += @{
                Index = $Matches[1]
                Description = $Matches[2].Trim()
            }
        }
    }

    if ($releases.Count -gt 0) {
        Write-Host "Select a release:" -ForegroundColor Cyan
        foreach ($rel in $releases) {
            Write-Host "  $($rel.Index): $($rel.Description)" -ForegroundColor White
        }
        Write-Host ""

        if ($script:IsProcessingQueue) {
            # Auto-pick first release in ProcessQueue mode
            $choice = "1"
            Write-Host "ProcessQueue mode: auto-selecting release 1" -ForegroundColor Yellow
        } else {
            $validChoice = $false
            while (-not $validChoice) {
                $choice = Read-Host "Enter release number (1-$($releases.Count))"
                if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $releases.Count) {
                    $validChoice = $true
                } else {
                    Write-Host "Invalid choice. Please enter a number between 1 and $($releases.Count)" -ForegroundColor Yellow
                }
            }
        }

        Write-Host "`nUsing release $choice..." -ForegroundColor Green
        Write-Log "User selected release $choice"

        # Re-run cyanrip with -R argument from parent directory
        $cyanripArgs += @("-R", $choice)
        $cmdDisplay = "cyanrip -D `"$albumFolder`" -o $format -d $driveLetter -s 0 -R $choice"
        Write-Host "Command: $cmdDisplay" -ForegroundColor Gray
        Write-Log "cyanrip command (with release): $cmdDisplay"

        Push-Location $parentDir
        try {
            $outputLines = [System.Collections.ArrayList]::new()
            & cyanrip @cyanripArgs 2>&1 | ForEach-Object {
                $line = [string]$_
                if ($line -notmatch 'progress - \d+\.\d+%') {
                    Write-Host $line
                }
                [void]$outputLines.Add($line)
            }
            $cyanripExitCode = $LASTEXITCODE
            $cyanripOutput = $outputLines.ToArray()
        } catch {
            Pop-Location
            Stop-WithError -Step "STEP 1/4: cyanrip" -Message "Failed to execute cyanrip: $_"
        }
        Pop-Location

        $cyanripOutputText = $cyanripOutput -join "`n"
    }
}

# Check if MusicBrainz connection failed - offer retry or continue without
if ($cyanripExitCode -ne 0 -and ($cyanripOutputText -match "MusicBrainz query failed" -or $cyanripOutputText -match "Connection failed")) {
    Write-Host "`nMusicBrainz connection failed." -ForegroundColor Yellow

    if ($RequireMusicBrainz) {
        Stop-WithError -Step "STEP 1/4: cyanrip" -Message "MusicBrainz connection failed and -RequireMusicBrainz is set"
    }

    Write-Host "  [R] Retry connection" -ForegroundColor White
    Write-Host "  [C] Continue without metadata (generic track names)" -ForegroundColor White
    Write-Host "  [Q] Quit" -ForegroundColor White
    Write-Host ""

    $validChoice = $false
    while (-not $validChoice) {
        $retryChoice = Read-Host "Choice (R/c/q)"
        if ($retryChoice -eq "" -or $retryChoice -match "^[Rr]") {
            $validChoice = $true
            Write-Host "`nRetrying MusicBrainz connection..." -ForegroundColor Green
            Write-Log "User chose to retry MusicBrainz connection"

            Push-Location $parentDir
            try {
                $outputLines = [System.Collections.ArrayList]::new()
                & cyanrip @cyanripArgs 2>&1 | ForEach-Object {
                    $line = [string]$_
                    if ($line -notmatch 'progress - \d+\.\d+%') {
                        Write-Host $line
                    }
                    [void]$outputLines.Add($line)
                }
                $cyanripExitCode = $LASTEXITCODE
                $cyanripOutput = $outputLines.ToArray()
            } catch {
                Pop-Location
                Stop-WithError -Step "STEP 1/4: cyanrip" -Message "Failed to execute cyanrip: $_"
            }
            Pop-Location
            $cyanripOutputText = $cyanripOutput -join "`n"

            # If still failing with connection error, loop back
            if ($cyanripExitCode -ne 0 -and ($cyanripOutputText -match "MusicBrainz query failed" -or $cyanripOutputText -match "Connection failed")) {
                $validChoice = $false
                Write-Host "`nConnection still failing." -ForegroundColor Yellow
                Write-Host "  [R] Retry connection" -ForegroundColor White
                Write-Host "  [C] Continue without metadata" -ForegroundColor White
                Write-Host "  [Q] Quit" -ForegroundColor White
                Write-Host ""
            }
        } elseif ($retryChoice -match "^[Cc]") {
            $validChoice = $true
            Write-Host "`nContinuing without MusicBrainz metadata..." -ForegroundColor Green
            Write-Log "User chose to continue without MusicBrainz metadata (connection failed)"
            $skipMusicBrainz = $true
            $script:MetadataSource = "Generic"

            $cyanripArgs += @("-N")
            Push-Location $parentDir
            try {
                $outputLines = [System.Collections.ArrayList]::new()
                & cyanrip @cyanripArgs 2>&1 | ForEach-Object {
                    $line = [string]$_
                    if ($line -notmatch 'progress - \d+\.\d+%') {
                        Write-Host $line
                    }
                    [void]$outputLines.Add($line)
                }
                $cyanripExitCode = $LASTEXITCODE
                $cyanripOutput = $outputLines.ToArray()
            } catch {
                Pop-Location
                Stop-WithError -Step "STEP 1/4: cyanrip" -Message "Failed to execute cyanrip: $_"
            }
            Pop-Location
            $cyanripOutputText = $cyanripOutput -join "`n"
        } elseif ($retryChoice -match "^[Qq]") {
            $validChoice = $true
            Stop-WithError -Step "STEP 1/4: cyanrip" -Message "User cancelled due to MusicBrainz connection failure"
        } else {
            Write-Host "Invalid choice. Enter R, C, or Q" -ForegroundColor Yellow
        }
    }
}

# Check if disc not found in MusicBrainz - try CDDB fallback, then offer generic names
if ($cyanripExitCode -ne 0 -and $cyanripOutputText -match "Unable to find release info") {
    Write-Host "`nDisc not found in MusicBrainz database." -ForegroundColor Yellow

    if ($RequireMusicBrainz) {
        Stop-WithError -Step "STEP 1/4: cyanrip" -Message "Disc not found in MusicBrainz and -RequireMusicBrainz is set"
    }

    # Try CDDB fallback before falling back to generic names
    Write-Host "Searching CDDB (gnudb.org) for disc info..." -ForegroundColor Yellow
    Write-Log "Attempting CDDB fallback lookup..."
    $script:CddbResult = Search-CDDB -CyanripOutput $cyanripOutputText -AlbumName $album -ArtistName $artist

    if ($script:CddbResult) {
        Write-Host "CDDB match found!" -ForegroundColor Green
        Write-Host "  Artist: $($script:CddbResult.Artist)" -ForegroundColor White
        Write-Host "  Album:  $($script:CddbResult.Album)" -ForegroundColor White
        Write-Host "  Tracks: $($script:CddbResult.Tracks.Count)" -ForegroundColor White
        foreach ($i in 0..([math]::Min($script:CddbResult.Tracks.Count, 5) - 1)) {
            Write-Host "    $("{0:D2}" -f ($i+1)). $($script:CddbResult.Tracks[$i])" -ForegroundColor Gray
        }
        if ($script:CddbResult.Tracks.Count -gt 5) {
            Write-Host "    ... and $($script:CddbResult.Tracks.Count - 5) more" -ForegroundColor Gray
        }
        Write-Log "CDDB match: $($script:CddbResult.Artist) - $($script:CddbResult.Album) ($($script:CddbResult.Tracks.Count) tracks)"

        # Continue with -N flag (CDDB names will be applied after rip)
        Write-Host "`nContinuing with CDDB metadata..." -ForegroundColor Green
        $skipMusicBrainz = $true
        $script:MetadataSource = "CDDB"
        $cyanripArgs += @("-N")
        $cmdDisplay = "cyanrip -D `"$albumFolder`" -o $format -d $driveLetter -s 0 -N"
        Write-Host "Command: $cmdDisplay" -ForegroundColor Gray
        Write-Log "cyanrip command (CDDB fallback, no MB): $cmdDisplay"

        Push-Location $parentDir
        try {
            $outputLines = [System.Collections.ArrayList]::new()
            & cyanrip @cyanripArgs 2>&1 | ForEach-Object {
                $line = [string]$_
                if ($line -notmatch 'progress - \d+\.\d+%') {
                    Write-Host $line
                }
                [void]$outputLines.Add($line)
            }
            $cyanripExitCode = $LASTEXITCODE
            $cyanripOutput = $outputLines.ToArray()
        } catch {
            Pop-Location
            Stop-WithError -Step "STEP 1/4: cyanrip" -Message "Failed to execute cyanrip: $_"
        }
        Pop-Location

        $cyanripOutputText = $cyanripOutput -join "`n"
    } else {
        Write-Host "CDDB: No match found" -ForegroundColor Yellow
        Write-Log "CDDB fallback: no match found"
        Write-Host "Track names will be generic (01 - Track 01, etc.)" -ForegroundColor Yellow
        Write-Host ""

        if ($script:IsProcessingQueue) {
            # Auto-continue in ProcessQueue mode
            $continueChoice = "y"
        } else {
            $continueChoice = Read-Host "Continue without metadata? (Y/n)"
        }
        if ($continueChoice -eq "" -or $continueChoice -match "^[Yy]") {
            Write-Host "`nContinuing without MusicBrainz metadata..." -ForegroundColor Green
            Write-Log "User chose to continue without MusicBrainz metadata"
            $skipMusicBrainz = $true
            $script:MetadataSource = "Generic"

            # Re-run cyanrip with -N flag to skip metadata requirement
            $cyanripArgs += @("-N")
            $cmdDisplay = "cyanrip -D `"$albumFolder`" -o $format -d $driveLetter -s 0 -N"
            Write-Host "Command: $cmdDisplay" -ForegroundColor Gray
            Write-Log "cyanrip command (no metadata): $cmdDisplay"

            Push-Location $parentDir
            try {
                $outputLines = [System.Collections.ArrayList]::new()
                & cyanrip @cyanripArgs 2>&1 | ForEach-Object {
                    $line = [string]$_
                    if ($line -notmatch 'progress - \d+\.\d+%') {
                        Write-Host $line
                    }
                    [void]$outputLines.Add($line)
                }
                $cyanripExitCode = $LASTEXITCODE
                $cyanripOutput = $outputLines.ToArray()
            } catch {
                Pop-Location
                Stop-WithError -Step "STEP 1/4: cyanrip" -Message "Failed to execute cyanrip: $_"
            }
            Pop-Location

            $cyanripOutputText = $cyanripOutput -join "`n"
        }
    }
}

# Check if cyanrip succeeded
if ($cyanripExitCode -ne 0) {
    $errorMessage = "cyanrip exited with code $cyanripExitCode"

    # Analyze output for specific errors
    if ($cyanripOutputText -match "no disc" -or $cyanripOutputText -match "no medium" -or $cyanripOutputText -match "drive is empty") {
        $errorMessage = "No disc in drive $driveLetter - please insert an audio CD"
    } elseif ($cyanripOutputText -match "not an audio" -or $cyanripOutputText -match "data disc") {
        $errorMessage = "Disc in $driveLetter is not an audio CD"
    } elseif ($cyanripOutputText -match "drive not found" -or $cyanripOutputText -match "cannot open") {
        $errorMessage = "Could not access drive $driveLetter - verify drive letter is correct"
    }

    Write-Host "`nERROR: $errorMessage" -ForegroundColor Red
    Stop-WithError -Step "STEP 1/4: cyanrip" -Message $errorMessage
}

Write-Host "`ncyanrip complete!" -ForegroundColor Green
Write-Log "STEP 1/4: cyanrip complete"

# Parse AccurateRip results
$arResults = Parse-AccurateRipResults -Output $cyanripOutputText

# Display AR summary
if ($arResults.DbStatus -eq "found") {
    if ($arResults.TracksVerified -ge 0) {
        $arColor = if ($arResults.TracksVerified -eq $arResults.TracksTotal) { "Green" } else { "Yellow" }
        Write-Host "AccurateRip: $($arResults.TracksVerified)/$($arResults.TracksTotal) tracks verified" -ForegroundColor $arColor
        if ($arResults.TracksPartial -gt 0) {
            Write-Host "  ($($arResults.TracksPartial) partially accurate)" -ForegroundColor Yellow
        }
    }
} elseif ($arResults.DbStatus -eq "not found") {
    Write-Host "AccurateRip: disc not in database" -ForegroundColor Yellow
} elseif ($arResults.DbStatus -eq "disabled") {
    # Say nothing - user explicitly disabled it
} elseif ($arResults.DbStatus -ne "unknown") {
    Write-Host "AccurateRip: $($arResults.DbStatus)" -ForegroundColor Yellow
}

# Log AR results
Write-Log "AccurateRip DB status: $($arResults.DbStatus)"
if ($arResults.TracksVerified -ge 0) {
    Write-Log "AccurateRip: $($arResults.TracksVerified)/$($arResults.TracksTotal) tracks verified"
    if ($arResults.TracksPartial -gt 0) {
        Write-Log "AccurateRip: $($arResults.TracksPartial) partially accurate"
    }
}

# Rename tracks if they have generic names (no MusicBrainz metadata)
# Format: "## - Artist - Album" e.g. "01 - John Martyn - Solid Air"
$audioExtensions = @("*.flac", "*.mp3", "*.opus", "*.m4a", "*.wav")
$rippedTracks = @()
foreach ($ext in $audioExtensions) {
    $files = Get-ChildItem -Path $finalOutputDir -Filter $ext -ErrorAction SilentlyContinue
    if ($files -and $files.Count -gt 0) {
        $rippedTracks = $files
        break
    }
}

$hasGenericNames = $false
if ($rippedTracks.Count -gt 0) {
    foreach ($t in $rippedTracks) {
        if ($t.BaseName -match '^\d{2}\s*-\s*Track\s*\d+$' -or $t.BaseName -match '^\d{2}$') {
            $hasGenericNames = $true
            break
        }
    }
}

if ($rippedTracks.Count -gt 0 -and ($skipMusicBrainz -or $hasGenericNames)) {
    if ($script:CddbResult -and $script:CddbResult.Tracks.Count -gt 0) {
        # Use CDDB track names for renaming
        Write-Host "`nRenaming tracks with CDDB metadata..." -ForegroundColor Yellow

        foreach ($track in ($rippedTracks | Sort-Object Name)) {
            if ($track.BaseName -match '^(\d{2})') {
                $trackNum = [int]$Matches[1]
                $trackIdx = $trackNum - 1
                $trackTitle = if ($trackIdx -lt $script:CddbResult.Tracks.Count) { $script:CddbResult.Tracks[$trackIdx] } else { "Track $($Matches[1])" }
                $newName = "$($Matches[1]) - $trackTitle$($track.Extension)"

                # Sanitize filename (remove invalid characters)
                $newName = $newName -replace '[\\/:*?"<>|]', '_'

                $newPath = Join-Path $finalOutputDir $newName

                if ($track.FullName -ne $newPath) {
                    try {
                        Rename-Item -Path $track.FullName -NewName $newName -ErrorAction Stop
                        Write-Host "  Renamed: $($track.Name) -> $newName" -ForegroundColor Gray
                        Write-Log "Renamed (CDDB): $($track.Name) -> $newName"
                    } catch {
                        Write-Host "  Failed to rename: $($track.Name)" -ForegroundColor Yellow
                        Write-Log "WARNING: Failed to rename $($track.Name): $_"
                    }
                }
            }
        }
        Write-Host "Track renaming complete (CDDB)" -ForegroundColor Green
    } else {
        # No CDDB data - rename using script params (generic: ## - Artist - Album)
        Write-Host "`nRenaming tracks with disc details..." -ForegroundColor Yellow

        $namingArtist = if ($artist) { $artist } else { "Unknown Artist" }
        $namingAlbum = $album

        foreach ($track in ($rippedTracks | Sort-Object Name)) {
            if ($track.BaseName -match '^(\d{2})') {
                $trackNum = $Matches[1]
                $newName = "$trackNum - $namingArtist - $namingAlbum$($track.Extension)"

                $newName = $newName -replace '[\\/:*?"<>|]', '_'

                $newPath = Join-Path $finalOutputDir $newName

                if ($track.FullName -ne $newPath) {
                    try {
                        Rename-Item -Path $track.FullName -NewName $newName -ErrorAction Stop
                        Write-Host "  Renamed: $($track.Name) -> $newName" -ForegroundColor Gray
                        Write-Log "Renamed: $($track.Name) -> $newName"
                    } catch {
                        Write-Host "  Failed to rename: $($track.Name)" -ForegroundColor Yellow
                        Write-Log "WARNING: Failed to rename $($track.Name): $_"
                    }
                }
            }
        }
        Write-Host "Track renaming complete" -ForegroundColor Green
    }
}

# Ensure metadata tags are set from input arguments (especially when MusicBrainz unavailable)
# This guarantees ARTIST, ALBUM, ALBUMARTIST, TITLE, TRACKNUMBER are never blank
Write-Host "`nEnsuring metadata tags from disc details..." -ForegroundColor Yellow

# Re-scan for tracks (in case they were renamed)
$rippedTracks = @()
foreach ($ext in $audioExtensions) {
    $files = Get-ChildItem -Path $finalOutputDir -Filter $ext -ErrorAction SilentlyContinue
    if ($files -and $files.Count -gt 0) {
        $rippedTracks = $files | Sort-Object Name
        $detectedFormat = $ext.TrimStart("*.")
        break
    }
}

if ($rippedTracks.Count -gt 0 -and $detectedFormat -eq "flac") {
    # Check if metaflac is available
    $metaflacAvailable = Get-Command metaflac -ErrorAction SilentlyContinue

    if ($metaflacAvailable) {
        # Use CDDB data for tags when available, otherwise fall back to script params
        $tagArtist = if ($script:CddbResult -and $script:CddbResult.Artist) { $script:CddbResult.Artist } elseif ($artist) { $artist } else { "Unknown Artist" }
        $tagAlbum = if ($script:CddbResult -and $script:CddbResult.Album) { $script:CddbResult.Album } else { $album }
        $totalTracks = $rippedTracks.Count

        foreach ($track in $rippedTracks) {
            # Extract track number from filename
            $trackNum = 1
            if ($track.BaseName -match '^(\d{2})') {
                $trackNum = [int]$Matches[1]
            }

            # Build track title: CDDB > existing tag > generic "Track ##"
            $trackIdx = $trackNum - 1
            $trackTitle = $null

            # Try CDDB track name first
            if ($script:CddbResult -and $trackIdx -lt $script:CddbResult.Tracks.Count) {
                $trackTitle = $script:CddbResult.Tracks[$trackIdx]
            }

            # Fall back to existing tag
            if (-not $trackTitle) {
                try {
                    $existingTags = & metaflac --show-tag=TITLE $track.FullName 2>$null
                    if ($existingTags -and $existingTags -notmatch "Track\s*\d+") {
                        $trackTitle = ($existingTags -split '=', 2)[1]
                    }
                } catch {}
            }

            # Fall back to generic name
            if (-not $trackTitle) { $trackTitle = "Track $("{0:D2}" -f $trackNum)" }

            # Set all metadata tags
            try {
                # Remove existing tags we're about to set (to avoid duplicates)
                & metaflac --remove-tag=ARTIST --remove-tag=ALBUM --remove-tag=ALBUMARTIST --remove-tag=TITLE --remove-tag=TRACKNUMBER --remove-tag=TRACKTOTAL $track.FullName 2>$null

                # Set new tags
                & metaflac --set-tag="ARTIST=$tagArtist" --set-tag="ALBUM=$tagAlbum" --set-tag="ALBUMARTIST=$tagArtist" --set-tag="TITLE=$trackTitle" --set-tag="TRACKNUMBER=$trackNum" --set-tag="TRACKTOTAL=$totalTracks" $track.FullName

                Write-Host "  Tagged: $($track.Name)" -ForegroundColor Gray
                Write-Log "Tagged: $($track.Name) [Artist=$tagArtist, Album=$tagAlbum, Title=$trackTitle, Track=$trackNum/$totalTracks]"
            } catch {
                Write-Host "  Failed to tag: $($track.Name)" -ForegroundColor Yellow
                Write-Log "WARNING: Failed to tag $($track.Name): $_"
            }
        }
        Write-Host "Metadata tagging complete" -ForegroundColor Green
    } else {
        Write-Host "  metaflac not found - skipping metadata tagging" -ForegroundColor Yellow
        Write-Log "WARNING: metaflac not available, skipping metadata tagging"
    }
} elseif ($rippedTracks.Count -gt 0) {
    Write-Host "  Metadata tagging only supported for FLAC format" -ForegroundColor Yellow
    Write-Log "Skipping metadata tagging - format is $detectedFormat (only FLAC supported)"
}

Complete-CurrentStep

# Eject disc after successful rip
Write-Host "`nEjecting disc from drive $driveLetter..." -ForegroundColor Yellow
try {
    $driveEject = New-Object -comObject Shell.Application
    $driveEject.Namespace(17).ParseName($driveLetter).InvokeVerb("Eject")
    Write-Host "Disc ejected successfully" -ForegroundColor Green
    Write-Log "Disc ejected from drive $driveLetter"
} catch {
    Write-Host "Could not eject disc automatically" -ForegroundColor Yellow
    Write-Log "WARNING: Could not eject disc: $_"
}

} # end if (-not $script:SkipRip)

# ========== STEP 2: VERIFY OUTPUT ==========
Set-CurrentStep -StepNumber 2
Write-Log "STEP 2/4: Verifying output..."
Write-Host "`n[STEP 2/4] Verifying output..." -ForegroundColor Green

# Check for ripped files based on format(s)
$formatExtMap = @{ "flac" = "*.flac"; "mp3" = "*.mp3"; "opus" = "*.opus"; "aac" = "*.m4a"; "wav" = "*.wav"; "alac" = "*.m4a" }
$rippedFiles = @()
foreach ($f in $formatList) {
    $ext = $formatExtMap[$f]
    if ($ext) {
        $files = Get-ChildItem -Path $finalOutputDir -Filter $ext -Recurse -ErrorAction SilentlyContinue
        if ($files) { $rippedFiles += $files }
    }
}

if ($rippedFiles.Count -eq 0) {
    # Try to find any audio files
    $anyAudioFiles = Get-ChildItem -Path $finalOutputDir -Include "*.flac","*.mp3","*.opus","*.m4a","*.wav" -Recurse -ErrorAction SilentlyContinue
    if ($anyAudioFiles -and $anyAudioFiles.Count -gt 0) {
        Write-Host "Found $($anyAudioFiles.Count) audio file(s) (different format than expected)" -ForegroundColor Yellow
        $rippedFiles = $anyAudioFiles
    } else {
        Stop-WithError -Step "STEP 2/4: Verify output" -Message "No audio files found in $finalOutputDir"
    }
}

Write-Host "Found $($rippedFiles.Count) audio file(s):" -ForegroundColor Green
$totalSize = 0
foreach ($file in $rippedFiles) {
    $sizeMB = [math]::Round($file.Length / 1MB, 2)
    $totalSize += $file.Length
    Write-Host "  - $($file.Name) ($sizeMB MB)" -ForegroundColor Gray
    Write-Log "  Ripped: $($file.Name) ($sizeMB MB)"
}
$totalSizeMB = [math]::Round($totalSize / 1MB, 2)
Write-Host "Total size: $totalSizeMB MB" -ForegroundColor White
Write-Log "Total size: $totalSizeMB MB"

Complete-CurrentStep
Write-Log "STEP 2/4: Verification complete - $($rippedFiles.Count) file(s)"

# ========== STEP 3: COVER ART ==========
Set-CurrentStep -StepNumber 3
Write-Log "STEP 3/4: Downloading cover art..."
Write-Host "`n[STEP 3/4] Downloading cover art..." -ForegroundColor Green

$script:CoverArtDownloaded = $false

# Check if cover art already exists (cyanrip may have downloaded it)
$existingArt = Get-ChildItem -Path $finalOutputDir -Include "Front.*","Cover.*","Folder.*" -ErrorAction SilentlyContinue
if ($existingArt -and $existingArt.Count -gt 0) {
    Write-Host "  Cover art already exists: $($existingArt[0].Name)" -ForegroundColor Green
    Write-Log "Cover art already exists: $($existingArt[0].Name)"
    $script:CoverArtDownloaded = $true
    $script:CoverArtSource = "cyanrip"
} else {
    # Try to get release ID from cue file for Cover Art Archive lookup
    $releaseId = $null
    $cueFile = Get-ChildItem -Path $finalOutputDir -Filter "*.cue" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cueFile) {
        $cueContent = Get-Content -Path $cueFile.FullName -Raw -ErrorAction SilentlyContinue
        if ($cueContent -match 'REM RELEASE_ID "([^"]+)"') {
            $releaseId = $Matches[1]
            Write-Host "  Found Release ID: $releaseId" -ForegroundColor Gray
        }
    }

    $artDownloaded = $false

    # Try Cover Art Archive first (if we have a release ID)
    if ($releaseId) {
        Write-Host "  Trying Cover Art Archive..." -ForegroundColor Gray
        try {
            $caaHeaders = @{ "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)" }
            $caaUrl = "https://coverartarchive.org/release/$releaseId"
            $caaResponse = Invoke-RestMethod -Uri $caaUrl -Headers $caaHeaders -TimeoutSec 10

            if ($caaResponse.images -and $caaResponse.images.Count -gt 0) {
                # Find front cover
                $frontCover = $caaResponse.images | Where-Object { $_.front -eq $true } | Select-Object -First 1
                if (-not $frontCover) {
                    $frontCover = $caaResponse.images[0]
                }

                $imageUrl = $frontCover.image
                $extension = if ($imageUrl -match '\.(\w+)$') { $Matches[1] } else { "jpg" }
                $outputFile = Join-Path $finalOutputDir "Front.$extension"

                Write-Host "  Downloading from Cover Art Archive..." -ForegroundColor Gray
                Invoke-WebRequest -Uri $imageUrl -OutFile $outputFile -Headers $caaHeaders -TimeoutSec 30
                Write-Host "  Downloaded: Front.$extension" -ForegroundColor Green
                Write-Log "Downloaded cover art from Cover Art Archive: Front.$extension"
                $artDownloaded = $true
                $script:CoverArtDownloaded = $true
                $script:CoverArtSource = "Cover Art Archive"
            }
        } catch {
            Write-Host "  Cover Art Archive: not available" -ForegroundColor Yellow
            Write-Log "Cover Art Archive lookup failed: $_"
        }
    }

    # Fallback 1: Search MusicBrainz by artist+album, then use Cover Art Archive
    if (-not $artDownloaded) {
        Write-Host "  Searching MusicBrainz for release..." -ForegroundColor Gray
        try {
            $mbSearchHeaders = @{
                "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)"
                "Accept" = "application/json"
            }
            $mbQuery = if ($artist) { "release:`"$album`" AND artist:`"$artist`"" } else { "release:`"$album`"" }
            $mbEncodedQuery = [System.Web.HttpUtility]::UrlEncode($mbQuery)
            $mbSearchUrl = "https://musicbrainz.org/ws/2/release?query=$mbEncodedQuery&limit=1&fmt=json"
            $mbSearchResponse = Invoke-RestMethod -Uri $mbSearchUrl -Headers $mbSearchHeaders -TimeoutSec 10

            if ($mbSearchResponse.releases -and $mbSearchResponse.releases.Count -gt 0) {
                $mbReleaseId = $mbSearchResponse.releases[0].id
                Write-Host "  Found MusicBrainz release: $mbReleaseId" -ForegroundColor Gray

                Start-Sleep -Milliseconds 1100  # MusicBrainz rate limit

                $caaSearchUrl = "https://coverartarchive.org/release/$mbReleaseId"
                $caaSearchResponse = Invoke-RestMethod -Uri $caaSearchUrl -Headers $mbSearchHeaders -TimeoutSec 10

                if ($caaSearchResponse.images -and $caaSearchResponse.images.Count -gt 0) {
                    $frontCover = $caaSearchResponse.images | Where-Object { $_.front -eq $true } | Select-Object -First 1
                    if (-not $frontCover) { $frontCover = $caaSearchResponse.images[0] }

                    $imageUrl = $frontCover.image
                    $extension = if ($imageUrl -match '\.(\w+)$') { $Matches[1] } else { "jpg" }
                    $outputFile = Join-Path $finalOutputDir "Front.$extension"

                    Invoke-WebRequest -Uri $imageUrl -OutFile $outputFile -Headers $mbSearchHeaders -TimeoutSec 30
                    if ((Test-Path $outputFile) -and (Get-Item $outputFile).Length -gt 1000) {
                        Write-Host "  Downloaded: Front.$extension (from MusicBrainz/CAA search)" -ForegroundColor Green
                        Write-Log "Downloaded cover art from MusicBrainz/CAA search: Front.$extension"
                        $artDownloaded = $true
                        $script:CoverArtDownloaded = $true
                        $script:CoverArtSource = "MusicBrainz/CAA"
                    } else {
                        Remove-Item $outputFile -ErrorAction SilentlyContinue
                    }
                }
            }
        } catch {
            Write-Host "  MusicBrainz/CAA search: not available" -ForegroundColor Yellow
            Write-Log "MusicBrainz/CAA search failed: $_"
        }
    }

    # Fallback 2: iTunes Search API (free, no auth, high-quality artwork)
    if (-not $artDownloaded) {
        Write-Host "  Trying iTunes Search API..." -ForegroundColor Gray
        try {
            $itunesQuery = if ($artist) { "$artist $album" } else { $album }
            $itunesEncoded = [System.Web.HttpUtility]::UrlEncode($itunesQuery)
            $itunesUrl = "https://itunes.apple.com/search?term=$itunesEncoded&media=music&entity=album&limit=1"
            $itunesResponse = Invoke-RestMethod -Uri $itunesUrl -TimeoutSec 10

            if ($itunesResponse.results -and $itunesResponse.results.Count -gt 0) {
                $artworkUrl = $itunesResponse.results[0].artworkUrl100
                if ($artworkUrl) {
                    # Replace 100x100 with 600x600 for higher resolution
                    $artworkUrl = $artworkUrl -replace '100x100bb', '600x600bb'

                    $outputFile = Join-Path $finalOutputDir "Front.jpg"
                    Invoke-WebRequest -Uri $artworkUrl -OutFile $outputFile -TimeoutSec 30

                    if ((Test-Path $outputFile) -and (Get-Item $outputFile).Length -gt 1000) {
                        Write-Host "  Downloaded: Front.jpg (from iTunes)" -ForegroundColor Green
                        Write-Log "Downloaded cover art from iTunes: Front.jpg"
                        $artDownloaded = $true
                        $script:CoverArtDownloaded = $true
                        $script:CoverArtSource = "iTunes"
                    } else {
                        Remove-Item $outputFile -ErrorAction SilentlyContinue
                    }
                }
            }
        } catch {
            Write-Host "  iTunes Search: not available" -ForegroundColor Yellow
            Write-Log "iTunes Search failed: $_"
        }
    }

    # Fallback 3: Deezer API (free, no auth, up to 1000x1000 artwork)
    if (-not $artDownloaded) {
        Write-Host "  Trying Deezer API..." -ForegroundColor Gray
        try {
            $deezerQuery = if ($artist) { "$artist $album" } else { $album }
            $deezerEncoded = [System.Web.HttpUtility]::UrlEncode($deezerQuery)
            $deezerUrl = "https://api.deezer.com/search/album?q=$deezerEncoded"
            $deezerResponse = Invoke-RestMethod -Uri $deezerUrl -TimeoutSec 10

            if ($deezerResponse.data -and $deezerResponse.data.Count -gt 0) {
                # Use cover_big (500x500) or cover_xl (1000x1000) for best quality
                $coverUrl = $deezerResponse.data[0].cover_xl
                if (-not $coverUrl) { $coverUrl = $deezerResponse.data[0].cover_big }
                if (-not $coverUrl) { $coverUrl = $deezerResponse.data[0].cover_medium }

                if ($coverUrl) {
                    $outputFile = Join-Path $finalOutputDir "Front.jpg"
                    Invoke-WebRequest -Uri $coverUrl -OutFile $outputFile -TimeoutSec 30

                    if ((Test-Path $outputFile) -and (Get-Item $outputFile).Length -gt 1000) {
                        Write-Host "  Downloaded: Front.jpg (from Deezer)" -ForegroundColor Green
                        Write-Log "Downloaded cover art from Deezer: Front.jpg"
                        $artDownloaded = $true
                        $script:CoverArtDownloaded = $true
                        $script:CoverArtSource = "Deezer"
                    } else {
                        Remove-Item $outputFile -ErrorAction SilentlyContinue
                    }
                }
            }
        } catch {
            Write-Host "  Deezer: not available" -ForegroundColor Yellow
            Write-Log "Deezer lookup failed: $_"
        }
    }

    if (-not $artDownloaded) {
        Write-Host "  No cover art found from any source (continuing without)" -ForegroundColor Yellow
        Write-Log "No cover art found from any source"
    }
}

# Embed cover art into FLAC files if art is present
$script:CoverArtEmbedded = 0
$artFile = Get-ChildItem -Path $finalOutputDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -in @('Front', 'Cover', 'Folder') } |
    Select-Object -First 1
if ($artFile -and (Get-Command metaflac -ErrorAction SilentlyContinue)) {
    Write-Host "  Embedding cover art into FLAC files..." -ForegroundColor Gray
    $flacFiles = Get-ChildItem -Path $finalOutputDir -Filter "*.flac" -ErrorAction SilentlyContinue
    foreach ($flac in $flacFiles) {
        try {
            $tempArt = Join-Path $env:TEMP "ripaudio_embed_$([System.IO.Path]::GetRandomFileName())"
            Copy-Item -LiteralPath $artFile.FullName -Destination $tempArt -Force
            $embedOut = & metaflac --remove --block-type=PICTURE --dont-use-padding $flac.FullName 2>&1
            $embedOut = & metaflac "--import-picture-from=$tempArt" $flac.FullName 2>&1
            Remove-Item -LiteralPath $tempArt -Force -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -eq 0) {
                $script:CoverArtEmbedded++
            } else {
                Write-Log "  metaflac embed failed for $($flac.Name): $embedOut"
            }
        } catch {
            Write-Log "  Embed error for $($flac.Name): $_"
        }
    }
    if ($script:CoverArtEmbedded -gt 0) {
        Write-Host "  Embedded cover art into $($script:CoverArtEmbedded)/$($flacFiles.Count) file(s)" -ForegroundColor Green
        Write-Log "Embedded cover art into $($script:CoverArtEmbedded)/$($flacFiles.Count) FLAC file(s)"
    } else {
        Write-Host "  Cover art embed failed (metaflac error - run search-metadata.ps1 to embed manually)" -ForegroundColor Yellow
        Write-Log "Cover art embed failed for all tracks"
    }
} elseif ($artFile -and -not (Get-Command metaflac -ErrorAction SilentlyContinue)) {
    Write-Host "  Cover art file exists but metaflac not installed - run search-metadata.ps1 to embed" -ForegroundColor Yellow
    Write-Log "Cover art embed skipped: metaflac not found"
}

Complete-CurrentStep

# ========== STEP 4: OPEN DIRECTORY ==========
Set-CurrentStep -StepNumber 4
Write-Log "STEP 4/4: Opening directory..."
Write-Host "`n[STEP 4/4] Opening output directory..." -ForegroundColor Green
Write-Host "Opening: $finalOutputDir" -ForegroundColor Yellow
Start-Process explorer.exe -ArgumentList $finalOutputDir
Complete-CurrentStep

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "COMPLETE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

# Show summary
Write-Host "`nProcessed: $(Get-AlbumSummary)" -ForegroundColor White
Write-Host "Format: $bannerFormat" -ForegroundColor White
Write-Host "Final location: $finalOutputDir" -ForegroundColor White

# Show completed steps
Show-StepsSummary

# File summary
Write-Host "`n--- FILE SUMMARY ---" -ForegroundColor Cyan
Write-Host "  Total tracks: $($rippedFiles.Count)" -ForegroundColor White
Write-Host "  Total size: $totalSizeMB MB" -ForegroundColor White
$mdColor = switch ($script:MetadataSource) { "MusicBrainz" { "Green" } "CDDB" { "Yellow" } default { "Red" } }
Write-Host "  Metadata: $($script:MetadataSource)" -ForegroundColor $mdColor
$coverArtStatus = if ($script:CoverArtDownloaded) { "Yes ($($script:CoverArtSource))" } else { "No" }
Write-Host "  Cover art: $coverArtStatus" -ForegroundColor White
if ($script:CoverArtDownloaded) {
    $totalFlacCount = (Get-ChildItem -Path $finalOutputDir -Filter "*.flac" -ErrorAction SilentlyContinue).Count
    if ($script:CoverArtEmbedded -gt 0) {
        Write-Host "  Cover art embedded: $($script:CoverArtEmbedded)/$totalFlacCount file(s)" -ForegroundColor $(if ($script:CoverArtEmbedded -ge $totalFlacCount) { "Green" } else { "Yellow" })
    } elseif (Get-Command metaflac -ErrorAction SilentlyContinue) {
        Write-Host "  Cover art embedded: 0/$totalFlacCount file(s) (embed failed)" -ForegroundColor Yellow
    } else {
        Write-Host "  Cover art embedded: not embedded (metaflac not installed)" -ForegroundColor Yellow
    }
}
if ($arResults.DbStatus -eq "found" -and $arResults.TracksVerified -ge 0) {
    Write-Host "  AccurateRip: $($arResults.TracksVerified)/$($arResults.TracksTotal) verified" -ForegroundColor White
} elseif ($arResults.DbStatus -eq "not found") {
    Write-Host "  AccurateRip: disc not in database" -ForegroundColor White
}
Write-Host "  Log file: $($script:LogFile)" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

Show-CoffeeBadge

Write-Log "========== RIP SESSION COMPLETE =========="
Write-Log "Final location: $finalOutputDir"
Write-Log "Total tracks: $($rippedFiles.Count)"
Write-Log "Total size: $totalSizeMB MB"
Write-Log "Metadata source: $($script:MetadataSource)"
if ($script:CoverArtSource) { Write-Log "Cover art source: $($script:CoverArtSource)" }
if ($arResults.TracksVerified -ge 0) {
    Write-Log "AccurateRip: $($arResults.TracksVerified)/$($arResults.TracksTotal) verified"
}

# If MusicBrainz had no match the tracks will be named "Unknown track".
# Offer to run search-metadata.ps1 to identify and tag them before closing.
if (-not $script:IsProcessingQueue) {
    $unknownTracks = $rippedFiles | Where-Object { $_.Name -like "*Unknown track*" }
    if ($unknownTracks.Count -gt 0) {
        Write-Host "`n  Disc not found in MusicBrainz -- $($unknownTracks.Count) track(s) are untagged." -ForegroundColor Yellow
        Write-Host "  Run search-metadata.ps1 now to identify and tag this album? [Y/N] (auto-Yes in 30s): " -NoNewline -ForegroundColor White
        $key = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 30) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                break
            }
            Start-Sleep -Milliseconds 200
        }
        $sw.Stop()
        $choice = if ($key) { "$($key.KeyChar)".ToUpper() } else { $null }
        if ($null -eq $choice) { Write-Host "Y (auto)" -ForegroundColor Gray; $choice = "Y" }
        else { Write-Host $choice }
        if ($choice -ne "N") {
            Write-Host "  Launching search-metadata.ps1..." -ForegroundColor Cyan
            Write-Log "Launching search-metadata.ps1 for untagged disc: $finalOutputDir"
            $searchScript = Join-Path $PSScriptRoot "search-metadata.ps1"
            Start-Process powershell.exe -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", $searchScript,
                "-Path", $finalOutputDir
            ) -Wait -NoNewWindow
        }
    }
}

Enable-ConsoleClose
$host.UI.RawUI.WindowTitle = "$windowTitle - DONE"
if ($arResults.DbStatus -eq "found" -and $arResults.TracksVerified -ge 0 -and $arResults.TracksVerified -lt $arResults.TracksTotal) {
    $host.UI.RawUI.WindowTitle += " - AR PARTIAL"
}

} catch {
    # Handle ProcessQueue item failures (thrown by Stop-WithError)
    if ($script:IsProcessingQueue -and $_.Exception.Message -eq "QUEUE_ITEM_FAILED") {
        $itemFailed = $true
    } else {
        throw
    }
}

# ========== QUEUE ENTRY CLEANUP ==========
if ($script:IsProcessingQueue) {
    if ($itemFailed) {
        $queueStats.Failed++
    } else {
        $queueStats.Processed++
    }
    Remove-FromQueue -Entry $currentEntry

    $queueTotal = $queueStats.Processed + $queueStats.Failed + $queueStats.Skipped
    Write-Host "`n--- Queue progress: $($queueStats.Processed) processed, $($queueStats.Skipped) skipped, $($queueStats.Failed) failed ($queueTotal total) ---" -ForegroundColor Magenta
}

} while ($script:IsProcessingQueue)

# ========== QUEUE AGGREGATE SUMMARY ==========
if ($script:IsProcessingQueue) {
    $queueTotal = $queueStats.Processed + $queueStats.Failed + $queueStats.Skipped
    Write-Host "`n========================================" -ForegroundColor Magenta
    Write-Host "QUEUE COMPLETE!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Magenta
    Write-Host "  Albums processed: $($queueStats.Processed)" -ForegroundColor White
    Write-Host "  Albums skipped:   $($queueStats.Skipped)" -ForegroundColor White
    Write-Host "  Albums failed:    $($queueStats.Failed)" -ForegroundColor White
    Write-Host "  Total:            $queueTotal" -ForegroundColor White
    Write-Host "========================================`n" -ForegroundColor Magenta

    # Delete queue file if empty
    $remainingQueue = Read-QueueFile
    if ($remainingQueue.Count -eq 0 -and (Test-Path $script:QueueFilePath)) {
        Remove-Item $script:QueueFilePath -Force -ErrorAction SilentlyContinue
    }

    Enable-ConsoleClose
}
