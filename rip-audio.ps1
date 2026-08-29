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
    [switch]$ProcessQueue,

    [Parameter()]
    [ValidateRange(0, 3)]
    [int]$ParanoiaLevel = -1,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$Retries = -1,

    # Prints a clickable eBay UK sold-listings search URL for the ripped album at the
    # end of the FILE SUMMARY - not run automatically, since it's a convenience for
    # deciding what a physical disc might be worth, not part of the rip itself.
    [Parameter()]
    [switch]$CheckEbayPrice,

    # Opt-in multi-disc mode: rips into ONE shared album folder (no "Disc N" folder
    # suffix) instead of the default separate-folder-per-disc behaviour, with every
    # track file prefixed "N-" (e.g. "2-01 - Title.flac") so a second/third disc's
    # tracks never collide with an earlier disc's already-ripped ones. Purely opt-in -
    # omitting this leaves every existing single-disc and auto-detected multi-disc
    # (separate "Album Disc N" folders) behaviour completely unchanged. Existing files
    # belonging to OTHER disc numbers in the shared folder are left alone and ignored
    # by the duplicate-file/resume checks - only this disc's own "$DiscNum-NN" files
    # are ever considered.
    [Parameter()]
    [ValidateRange(1, 99)]
    [int]$DiscNum = 0
)

# Ensure cyanrip/metaflac output is decoded as UTF-8 (PS5.1 defaults to system locale)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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
        # Verified live against the installed FLAC 1.5.0: metaflac has no --test option at
        # all (it only edits/reads metadata blocks, it never decodes the audio stream) --
        # "metaflac --test" always printed "unrecognized option" usage text and exited 1,
        # so this check was unconditionally returning $false for every FLAC file regardless
        # of validity. "flac --test" (the decoder, bundled in the same install) is the tool
        # that actually verifies a FLAC file decodes cleanly; confirmed it correctly passes
        # a good file and fails a deliberately truncated one.
        $flacExe = Get-Command flac -ErrorAction SilentlyContinue
        if ($flacExe) {
            & flac --test --totally-silent $FilePath 2>$null
            return $LASTEXITCODE -eq 0
        }
    }
    # For non-FLAC or no flac.exe: check file size > 10KB
    return (Get-Item $FilePath).Length -gt 10240
}

function Get-DiscTrackCount {
    param([string]$OutputDir, [string]$DriveLetter, [switch]$Fresh)
    # Try cue file first (avoids disc query and multiple-release prompts) -- unless
    # -Fresh is given, which skips straight to a live disc query. A cue file written
    # during a rip that later crashed can still carry a track count corrupted by the
    # same flaky connection that caused the crash, so callers recovering from a crash
    # should not trust it.
    $cueFile = if (-not $Fresh) { Get-ChildItem -Path $OutputDir -Filter "*.cue" -ErrorAction SilentlyContinue | Select-Object -First 1 }
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

    $result = @{ Album = $null; Artist = $null; DiscNum = $null; TotalDiscs = $null; ReleaseChoice = $null; DiscId = $null; ReleaseId = $null; TrackCount = $null }

    # Capture the disc's raw TOC track count independently of everything else below -
    # this comes straight from cyanrip's own disc read, not from MusicBrainz/CDDB, so
    # it's available even when metadata lookup fails entirely or the disc ID can't be
    # parsed. A flaky USB connection dropping mid-TOC-read can make cyanrip see far
    # fewer tracks than the disc actually has (e.g. 2 instead of 13); surfacing this
    # number to the caller lets the pre-rip banner show it so a user who knows the
    # album can catch an implausible count before walking away from an unattended rip.
    if ($outputText -match 'Disc tracks:\s+(\d+)') {
        $result.TrackCount = [int]$Matches[1]
    }

    # Parse disc ID - try multiple formats cyanrip may output
    # Note: must require colon after DiscID to avoid matching "DiscID has a matching stub"
    $discId = $null
    if ($outputText -match 'for DiscID\s+(\S+?):') {
        $discId = $Matches[1]
    } elseif ($outputText -match 'DiscID:\s+(\S+)') {
        $discId = $Matches[1]
    } elseif ($outputText -match 'Disc ID:\s+(\S+)') {
        $discId = $Matches[1]
    } elseif ($outputText -match '[&?]id=([A-Za-z0-9_.~-]+)') {
        # Fallback: extract from MusicBrainz URL parameter (e.g. stub message)
        $discId = $Matches[1]
    }

    if (-not $discId) {
        Write-Host "Could not determine disc ID" -ForegroundColor Yellow
        # Still return $result (not $null) rather than discarding it - a garbled/partial
        # disc query (the exact scenario a mid-TOC-read USB disconnect produces) may still
        # have yielded a usable TrackCount above even with no disc ID. Callers already
        # check truthy fields individually (e.g. "$discMeta -and $discMeta.Album"), so a
        # mostly-empty result here is equivalent to the old $null for their purposes.
        return $result
    }
    Write-Host "Disc ID: $discId" -ForegroundColor Gray
    $result.DiscId = $discId

    # Try to parse metadata directly from cyanrip output first.
    # cyanrip prints Album:, Album artist:, Disc number:, etc. when MusicBrainz lookup succeeds.
    # This avoids a redundant MusicBrainz API call and works even when the API would fail.
    if ($outputText -match '(?m)^Album:\s+(.+)$') {
        $result.Album = $Matches[1].Trim()
    }
    if ($outputText -match '(?m)^Album artist:\s+(.+)$') {
        $result.Artist = $Matches[1].Trim()
    }
    if ($outputText -match '(?m)^Release ID:\s+(\S+)') {
        $result.ReleaseId = $Matches[1]
    }
    if ($outputText -match '(?m)^Disc number:\s+(\d+)') {
        $result.DiscNum = [int]$Matches[1]
    }
    if ($outputText -match '(?m)^Total discs:\s+(\d+)') {
        $result.TotalDiscs = [int]$Matches[1]
    }

    # If cyanrip already found the album, we're done - no API call needed
    if ($result.Album) {
        Write-Host "Parsed metadata from disc query" -ForegroundColor Green
        return $result
    }

    # Check for multiple releases (user selection needed before API call)
    $releaseUuid = $null
    if ($outputText -match "Multiple releases found") {
        $releases = @()
        foreach ($line in $output) {
            if ($line -match '^\s*(\d+)\s+\(ID:\s*([a-f0-9-]+)\):\s*(.+)$') {
                $releases += @{ Index = $Matches[1]; UUID = $Matches[2]; Description = $Matches[3].Trim() }
            }
        }
        if ($releases.Count -gt 0) {
            # Fetch track info for each release to help differentiate versions
            $trackHeaders = @{
                "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)"
                "Accept" = "application/json"
            }
            Write-Host "Fetching track details for each release..." -ForegroundColor Gray
            foreach ($rel in $releases) {
                try {
                    if ($releases.IndexOf($rel) -gt 0) { Start-Sleep -Seconds 1 }
                    $trackUrl = "https://musicbrainz.org/ws/2/release/$($rel.UUID)?inc=media+recordings&fmt=json"
                    $trackResp = Invoke-RestMethod -Uri $trackUrl -Headers $trackHeaders -TimeoutSec 10
                    if ($trackResp.media -and $trackResp.media.Count -gt 0) {
                        $medium = $trackResp.media[0]
                        $rel.TrackCount = $medium.'track-count'
                        if ($medium.tracks -and $medium.tracks.Count -gt 0) {
                            $rel.FirstTrack = $medium.tracks[0].title
                            $rel.LastTrack = $medium.tracks[-1].title
                        }
                    }
                } catch {
                    # Continue without track info if API call fails
                }
            }

            Show-QuestionHint
            Write-Host "Multiple releases found. Select one:" -ForegroundColor Cyan
            foreach ($rel in $releases) {
                $info = "  $($rel.Index): $($rel.Description)"
                if ($rel.TrackCount) {
                    $info += " | $($rel.TrackCount) tracks"
                    if ($rel.FirstTrack -and $rel.LastTrack) {
                        $info += " (Track 1: $($rel.FirstTrack) ... Last track: $($rel.LastTrack))"
                    }
                }
                Write-Host $info -ForegroundColor White
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

    # Fallback: Query MusicBrainz API for metadata (only when cyanrip output
    # didn't contain Album/Artist, e.g. multiple releases requiring selection)
    Write-Host "Querying MusicBrainz for release details..." -ForegroundColor Yellow
    $mbHeaders = @{
        "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)"
        "Accept" = "application/json"
    }
    try {
        if ($releaseUuid) {
            $url = "https://musicbrainz.org/ws/2/release/$($releaseUuid)?inc=artist-credits+media+discids&fmt=json"
        } else {
            # discid endpoint returns releases by default; only artist-credits is needed as inc
            $url = "https://musicbrainz.org/ws/2/discid/$($discId)?inc=artist-credits&fmt=json"
        }
        $response = Invoke-RestMethod -Uri $url -Headers $mbHeaders -TimeoutSec 10

        # discid lookup returns releases array; direct release lookup returns the release object
        $release = if ($response.releases) { $response.releases[0] } else { $response }

        $result.Album = $release.title
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

# Shown before any interactive prompt so the user knows input is still
# needed and does not walk away thinking the script has stalled. Called
# once per prompt block (outside retry-on-bad-input loops so it does
# not spam).
function Show-QuestionHint {
    Write-Host ""
    Write-Host "[ A few more questions to answer... ]" -ForegroundColor Yellow
}

function Write-Timestamp {
    param([string]$Label)
    $ts = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
    Write-Host "  [$ts] $Label" -ForegroundColor DarkGray
}

# Builds an eBay UK sold-listings search URL for the ripped album, so a -CheckEbayPrice
# rip can print a link the user clicks to see what copies of the physical disc have
# actually sold for. Buy It Now only, "Very Good" condition or better (LH_ItemCondition=4),
# UK sellers/location only (LH_PrefLoc=1), sold listings only (LH_Sold=1) - matches the
# exact filter combination the user already uses manually on ebay.co.uk.
function Get-EbaySoldListingsUrl {
    param([string]$Artist, [string]$Album)
    $query = if ($Artist) { "$Artist $Album CD album" } else { "$Album CD album" }
    $encodedQuery = [System.Web.HttpUtility]::UrlEncode($query)
    return "https://www.ebay.co.uk/sch/i.html?_nkw=$encodedQuery&_sacat=0&_from=R40&LH_BIN=1&LH_ItemCondition=4&LH_PrefLoc=1&rt=nc&LH_Sold=1"
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
    Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host ("".PadRight($w)) -NoNewline; Write-Host "$vt" -ForegroundColor DarkGray
    $c = "   .----.  "; Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host $c -NoNewline -ForegroundColor DarkCyan; Write-Host ("I host all my sites on SiteGround - highly".PadRight($w - $c.Length)) -NoNewline -ForegroundColor Gray; Write-Host "$vt" -ForegroundColor DarkGray
    $c = "   |    |  "; Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host $c -NoNewline -ForegroundColor DarkCyan; Write-Host ("recommended if you want to make a site!".PadRight($w - $c.Length)) -NoNewline -ForegroundColor Gray; Write-Host "$vt" -ForegroundColor DarkGray
    $c = "   '----'"; Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host $c -NoNewline -ForegroundColor DarkCyan; Write-Host ("".PadRight($w - $c.Length)) -NoNewline; Write-Host "$vt" -ForegroundColor DarkGray
    $c = "   _/  \_  "; Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host $c -NoNewline -ForegroundColor DarkCyan; Write-Host (">> https://siteground.com/go/steve (affiliate)".PadRight($w - $c.Length)) -NoNewline -ForegroundColor Yellow; Write-Host "$vt" -ForegroundColor DarkGray
    $c = "  /______\ "; Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host $c -NoNewline -ForegroundColor DarkCyan; Write-Host ("Click to check it out and support my projects!".PadRight($w - $c.Length)) -NoNewline -ForegroundColor Cyan; Write-Host "$vt" -ForegroundColor DarkGray
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

# ========== DATA ERROR DETECTION ==========
function Parse-TrackDataErrors {
    param([string]$Output)

    $errorTracks = @()
    $currentTrack = 0

    foreach ($line in ($Output -split "`n")) {
        # Track header line (e.g. "Track  3" or "Track 03")
        if ($line -match '^\s*Track\s+(\d+)') {
            $currentTrack = [int]$Matches[1]
        }

        # Detect data/read error indicators on track lines
        # cyanrip reports errors like: "error", "read error", "SCSI error", "skip", "dropped"
        # Exclude "Ripping errors: 0" — cyanrip prints this for every track even when there are no errors
        if ($currentTrack -gt 0 -and $line -notmatch 'Ripping errors:\s*0' -and $line -match '(read error|SCSI error|data error|cdio error|rip(ping)? error|I/O error|dropped|skipped sector|unrecoverable error)') {
            if ($errorTracks -notcontains $currentTrack) {
                $errorTracks += $currentTrack
            }
        }

        # Also detect error counts in track completion lines (e.g. "errors: 5")
        if ($currentTrack -gt 0 -and $line -match 'errors?:\s*(\d+)' -and [int]$Matches[1] -gt 0) {
            if ($errorTracks -notcontains $currentTrack) {
                $errorTracks += $currentTrack
            }
        }
    }

    return $errorTracks | Sort-Object
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

# ========== DRIVE DISCOVERY ==========
# Query optical drives and busy state once - used for auto-detect, explicit -Drive
# validation, and the drive listing shown either way (mirrors ripdisc's MakeMKV drive list:
# drive letter, model, disc label, busy state, and an arrow on the selected drive).
$opticalDrives = @(Get-CimInstance Win32_CDROMDrive -ErrorAction SilentlyContinue | Where-Object { $_.Drive })

# Which drive letters are currently busy with another cyanrip rip, read from the real
# running process command lines rather than trusted from the user - this is what makes a
# hard block possible instead of just a warning the user could click past.
$busyDriveLetters = @()
foreach ($proc in (Get-Process -Name "cyanrip" -ErrorAction SilentlyContinue)) {
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue).CommandLine
        # -cmatch: cyanrip's -d (drive) and -D (output directory) flags are case-distinct;
        # a case-insensitive match here would find -D's directory argument instead.
        if ($cmdLine -cmatch '-d\s+(\S+)') {
            # Capture into its own variable before checking it further - $Matches is a single
            # global variable, and a second -match inline (e.g. on this same capture) would
            # silently overwrite it and discard what was just captured.
            $rawDriveArg = $Matches[1]
            $busyDriveLetters += if ($rawDriveArg -match ':$') { $rawDriveArg } else { "${rawDriveArg}:" }
        }
    } catch {
        # Best-effort - an unreadable command line just means this process isn't counted as busy
    }
}

# Disc label (volume label) for a drive, if a disc is present and Windows can read one -
# shown in the listing the same way ripdisc shows the disc name in brackets per drive.
# Audio CDs (CDDA) have no filesystem at all, so Windows always reports the generic
# "Audio CD" here regardless of what's actually on the disc - there is no real per-disc
# label to read, unlike a DVD/data disc's ISO9660/UDF volume name. Get-QuickDiscIdentity
# below is what tries to do better than that specific generic case.
function Get-RipAudioDiscLabel {
    param([string]$DriveLetter)
    try {
        $vol = Get-Volume -DriveLetter ($DriveLetter.TrimEnd(':')) -ErrorAction Stop
        if ($vol.FileSystemLabel) { return $vol.FileSystemLabel }
    } catch { }
    return $null
}

# Bounded, silent MusicBrainz-backed disc identification for the generic "Audio CD" case -
# runs `cyanrip -I` (discovery only, no rip) as a real Process rather than the `&` operator
# so it can be killed on timeout. Async output reads are started before WaitForExit, not
# after, so a chatty child can't deadlock on a full pipe buffer while nothing is draining it.
# Returns "Artist - Album", "Album" alone, or $null on timeout/failure/no match - callers
# fall back to the existing generic label on $null, so a slow or unreachable MusicBrainz
# never blocks drive discovery, just skips the enhancement.
function Get-QuickDiscIdentity {
    param([string]$DriveLetter, [int]$TimeoutSeconds = 5)
    $cyanripCmd = Get-Command cyanrip -ErrorAction SilentlyContinue
    if (-not $cyanripCmd) { return $null }
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($cyanripCmd.Source)
        $psi.Arguments = "-I -d $DriveLetter -s 0"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            return $null
        }
        $combined = "$($stdoutTask.Result)`n$($stderrTask.Result)"
        $album = $null
        $artist = $null
        if ($combined -match '(?m)^Album:\s+(.+)$') { $album = $Matches[1].Trim() }
        if ($combined -match '(?m)^Album artist:\s+(.+)$') { $artist = $Matches[1].Trim() }
        if ($album -and $artist) { return "$artist - $album" }
        if ($album) { return $album }
        return $null
    } catch {
        return $null
    }
}

# Formats one drive listing line: letter, model, disc label if any, busy/free state.
# $Selected marks the drive with an arrow, matching ripdisc's "<--" convention.
function Write-DriveListLine {
    param($DriveInfo, [bool]$Selected = $false)
    $discLabel = Get-RipAudioDiscLabel -DriveLetter $DriveInfo.Drive
    $isBusy = $busyDriveLetters -contains $DriveInfo.Drive
    if ($discLabel -eq 'Audio CD' -and -not $isBusy) {
        # Only worth the lookup cost on the uninformative generic label - a real label
        # (e.g. a DVD's volume name) is already useful, and a busy drive shouldn't be
        # queried at all (it's mid-rip; don't risk contending with that read).
        $quickIdentity = Get-QuickDiscIdentity -DriveLetter $DriveInfo.Drive
        if ($quickIdentity) { $discLabel = $quickIdentity }
    }
    $labelText = if ($discLabel) { " [$discLabel]" } else { "" }
    $busyText = if ($isBusy) { " (BUSY - rip in progress)" } else { "" }
    $marker = if ($Selected) { " <--" } else { "" }
    $color = if ($isBusy) { "DarkRed" } else { "White" }
    Write-Host "  $($DriveInfo.Drive) - $($DriveInfo.Name)$labelText$busyText$marker" -ForegroundColor $color
}

if (-not $Drive) {
    # Auto-detect CD/optical drive
    if ($opticalDrives.Count -eq 0) {
        Write-Host "ERROR: No optical drive detected. Use -Drive to specify the drive letter." -ForegroundColor Red
        exit 1
    } elseif ($opticalDrives.Count -eq 1) {
        $onlyDrive = $opticalDrives[0]
        if ($busyDriveLetters -contains $onlyDrive.Drive) {
            Write-Host "ERROR: $($onlyDrive.Drive) ($($onlyDrive.Name)) is busy - another cyanrip rip is already using it." -ForegroundColor Red
            Write-Host "Wait for that rip to finish, or free up the drive before retrying." -ForegroundColor Yellow
            exit 1
        }
        $Drive = $onlyDrive.Drive
        Write-Host "Detected optical drive:" -ForegroundColor Gray
        Write-DriveListLine -DriveInfo $onlyDrive -Selected $true
    } else {
        Write-Host "Multiple optical drives detected:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $opticalDrives.Count; $i++) {
            Write-Host -NoNewline "  $($i + 1): " -ForegroundColor White
            Write-DriveListLine -DriveInfo $opticalDrives[$i]
        }
        $driveChoice = $null
        while (-not $driveChoice) {
            $input = Read-Host "Select drive (1-$($opticalDrives.Count))"
            if ($input -match '^\d+$' -and [int]$input -ge 1 -and [int]$input -le $opticalDrives.Count) {
                $candidate = $opticalDrives[[int]$input - 1]
                if ($busyDriveLetters -contains $candidate.Drive) {
                    Write-Host "$($candidate.Drive) is busy - another cyanrip rip is already using it. Choose a different drive." -ForegroundColor Red
                    continue
                }
                $Drive = $candidate.Drive
                $driveChoice = $Drive
            } else {
                Write-Host "Invalid selection. Enter a number between 1 and $($opticalDrives.Count)" -ForegroundColor Yellow
            }
        }
    }
} else {
    # -Drive was passed explicitly - validate it against the drives Windows actually sees,
    # and against which drives are currently busy with another cyanrip rip, rather than
    # trusting it blindly. Without this: a stale/mistyped drive letter sails straight through
    # to cyanrip's misleading "disc may be damaged" error, and a busy drive collides with
    # another rip already using the same physical hardware.
    $explicitDriveLetter = if ($Drive -match ':$') { $Drive } else { "${Drive}:" }
    $matchedDrive = $opticalDrives | Where-Object { $_.Drive -eq $explicitDriveLetter } | Select-Object -First 1

    if ($matchedDrive -and ($busyDriveLetters -contains $explicitDriveLetter)) {
        Write-Host "ERROR: $explicitDriveLetter ($($matchedDrive.Name)) is busy - another cyanrip rip is already using it." -ForegroundColor Red
        Write-Host "Optical drives right now:" -ForegroundColor Yellow
        foreach ($d in $opticalDrives) { Write-DriveListLine -DriveInfo $d -Selected ($d.Drive -eq $explicitDriveLetter) }
        Write-Host "Wait for that rip to finish, or re-run with a different -Drive." -ForegroundColor Yellow
        exit 1
    } elseif ($matchedDrive) {
        # Show every detected drive, not just the matched one - matches the shape of the
        # busy/not-found error paths right below (and ripdisc's own drive listing), so an
        # explicit -Drive doesn't hide other drives the user might have meant instead.
        Write-Host "Optical drives detected:" -ForegroundColor Cyan
        foreach ($d in $opticalDrives) { Write-DriveListLine -DriveInfo $d -Selected ($d.Drive -eq $explicitDriveLetter) }
    } elseif ($opticalDrives.Count -gt 0) {
        # WMI saw at least one real optical drive, just not this one - a reliable signal
        # that the requested letter is wrong, so fail fast with the actual options instead
        # of letting cyanrip produce a misleading "disc may be damaged" error a minute later.
        Write-Host "ERROR: $explicitDriveLetter is not a recognised optical drive on this machine." -ForegroundColor Red
        Write-Host "Optical drives actually detected:" -ForegroundColor Yellow
        foreach ($d in $opticalDrives) { Write-DriveListLine -DriveInfo $d }
        Write-Host "Re-run with one of the drive letters above, or omit -Drive to auto-detect / choose interactively." -ForegroundColor Yellow
        exit 1
    } elseif ($busyDriveLetters -contains $explicitDriveLetter) {
        # WMI's Win32_CDROMDrive enumeration returned nothing at all (can happen transiently
        # for some external/USB drives), so there's no drive model/label to show - but busy
        # detection doesn't depend on that list at all (it reads running cyanrip process
        # command lines directly), so it can and does still hard-block here.
        Write-Host "ERROR: $explicitDriveLetter is busy - another cyanrip rip is already using it." -ForegroundColor Red
        Write-Host "Wait for that rip to finish, or re-run with a different -Drive." -ForegroundColor Yellow
        exit 1
    } else {
        # No positive evidence the requested drive is wrong (WMI just didn't enumerate any
        # optical drives right now) and it's confirmed not busy - warn rather than block.
        Write-Host "WARNING: No optical drives detected via WMI right now - continuing with -Drive $explicitDriveLetter as given. If this fails, double-check the drive letter." -ForegroundColor Yellow
    }
}

# Normalize -Drive (add colon if missing)
$driveLetter = if ($Drive -match ':$') { $Drive } else { "${Drive}:" }

# ========== OUTPUT DRIVE SELECTION ==========
# Ask which drive to write ripped albums to when -OutputDrive wasn't passed, then
# validate it's actually ready before proceeding - previously this silently defaulted
# to the system drive with no check until deep into Step 1, after the entire disc
# metadata discovery / multiple-release / MusicBrainz flow had already run, so a bad
# or disconnected output drive only surfaced after several other questions were answered.
# Skipped in -Queue (just queues metadata, doesn't touch a drive yet) and -ProcessQueue
# (unattended batch run) - both keep the old silent system-drive default, matching how
# other interactive prompts are skipped in those modes elsewhere in this script.
$outputDrivePromptable = -not $Queue -and -not $ProcessQueue

if (-not $OutputDrive) {
    if ($outputDrivePromptable) {
        $defaultOutputDrive = $env:SystemDrive
        Show-QuestionHint
        $outputDriveInput = Read-Host "Output drive (Enter for default: $defaultOutputDrive)"
        $OutputDrive = if ($outputDriveInput) { $outputDriveInput.Trim() } else { $defaultOutputDrive }
    } else {
        $OutputDrive = $env:SystemDrive
        Write-Host "Output drive defaulting to: $OutputDrive" -ForegroundColor Gray
    }
}

# Normalize and validate before proceeding - an -OutputDrive passed explicitly, entered
# interactively above, or defaulted is checked here rather than trusted blindly. Reuses
# Test-DriveReady (the same check Step 1 already runs against the full album path) against
# the bare drive root.
$outputDriveLetter = if ($OutputDrive -match ':$') { $OutputDrive } else { "${OutputDrive}:" }
$outputDriveCheck = Test-DriveReady -Path "$outputDriveLetter\"
while (-not $outputDriveCheck.Ready) {
    Write-Host "ERROR: $($outputDriveCheck.Message)" -ForegroundColor Red
    if (-not $outputDrivePromptable) {
        exit 1
    }
    Show-QuestionHint
    $outputDriveInput = Read-Host "Enter a different output drive (or Ctrl+C to abort)"
    if (-not $outputDriveInput) { continue }
    $candidate = $outputDriveInput.Trim()
    $outputDriveLetter = if ($candidate -match ':$') { $candidate } else { "${candidate}:" }
    $outputDriveCheck = Test-DriveReady -Path "$outputDriveLetter\"
}
$OutputDrive = $outputDriveLetter
Write-Host "Output drive: $outputDriveLetter - ready" -ForegroundColor Green

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
    # Reset here (not just before use at their point of computation) so the SkipRip
    # branch - which skips straight past cyanrip and never reaches those checks - still
    # starts each album with empty arrays in -ProcessQueue's multi-album loop, rather
    # than the new "COMPLETE WITH WARNINGS" banner gate below reading a previous
    # album's stale corrupt/skipped/data-error counts against a clean album.
    $script:CorruptTracks = @()
    $script:SkippedTracks = @()
    $script:DataErrorTracks = @()
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
    Write-Timestamp "Disc metadata discovery started"
    $discMeta = Get-DiscMetadata -DriveLetter $driveLetter

    if ($discMeta -and $discMeta.Album) {
        $album = $discMeta.Album

        # For multi-disc albums with >1 disc, append "Disc N" - unless the user
        # explicitly passed -DiscNum, which opts into the shared-folder mode below
        # instead (one folder for the whole set, disc-prefixed track filenames).
        if ($DiscNum -eq 0 -and $discMeta.TotalDiscs -and $discMeta.TotalDiscs -gt 1 -and $discMeta.DiscNum) {
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
        Write-Timestamp "Disc metadata discovery complete"
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
# First normalize Unicode dashes (en-dash, em-dash) to ASCII hyphen so cyanrip
# and PowerShell produce the same directory name. Then remove illegal Windows path
# characters, dots (trailing dots make NTFS silently rename the folder), and hyphens.
# Collapses multiple spaces and trims.
$safeAlbum = (($album -replace '[\u2013\u2014]', '-') -replace '[\\/:*?"<>|.-]', '') -replace '\s+', ' '
$safeAlbum = $safeAlbum.Trim()
$safeArtist = if ($artist) { ((($artist -replace '[\u2013\u2014]', '-') -replace '[\\/:*?"<>|.-]', '') -replace '\s+', ' ').Trim() } else { "" }

# Build output directory path
# Format: E:\Music\{Artist}\{Album}\ or E:\Music\{Album}\ if no artist
if ($safeArtist) {
    $finalOutputDir = "$outputDriveLetter\Music\$safeArtist\$safeAlbum"
} else {
    $finalOutputDir = "$outputDriveLetter\Music\$safeAlbum"
}

# ========== DUPLICATE VERSION CHECK ==========
# If output directory already exists with audio files, offer to add a version suffix
# (e.g. "Limited Edition", "Import", "Remaster") to create a separate folder.
# Skipped entirely under -DiscNum: the shared multi-disc folder already containing an
# earlier disc's (disc-prefixed) tracks is the expected, intended state, not a
# different-edition conflict to prompt about.
if ($DiscNum -eq 0 -and (Test-Path $finalOutputDir) -and -not $script:IsProcessingQueue) {
    $formatExtMap = @{ "flac" = "*.flac"; "mp3" = "*.mp3"; "opus" = "*.opus"; "aac" = "*.m4a"; "wav" = "*.wav"; "alac" = "*.m4a" }
    $hasAudioFiles = $false
    foreach ($fmt in $formatList) {
        $ext = $formatExtMap[$fmt]
        if ($ext -and (Get-ChildItem -Path $finalOutputDir -Filter $ext -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            $hasAudioFiles = $true
            break
        }
    }

    if ($hasAudioFiles) {
        Show-QuestionHint
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host "ALBUM FOLDER ALREADY EXISTS" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host "`n  $finalOutputDir" -ForegroundColor White
        Write-Host "`nIs this a different version of the same album?" -ForegroundColor Cyan
        Write-Host "  [1] Yes - add a version suffix (e.g. Limited Edition, Import, Remaster)" -ForegroundColor Yellow
        Write-Host "  [2] No  - continue (resume/overwrite options will follow)" -ForegroundColor Yellow

        $versionChoice = $null
        while ($versionChoice -ne '1' -and $versionChoice -ne '2') {
            $versionChoice = Read-Host "Enter 1 or 2"
            if ($versionChoice -ne '1' -and $versionChoice -ne '2') {
                Write-Host "Invalid choice. Please enter 1 or 2." -ForegroundColor Red
            }
        }

        if ($versionChoice -eq '1') {
            $suffix = $null
            while (-not $suffix) {
                $suffix = (Read-Host "Enter version suffix (e.g. Limited Edition, Import, Remaster, Japanese Edition)").Trim()
                if (-not $suffix) {
                    Write-Host "Suffix cannot be empty. Please enter a version name." -ForegroundColor Red
                }
            }
            # Sanitize the suffix the same way as album/artist names
            $safeSuffix = (($suffix -replace '[\u2013\u2014]', '-') -replace '[\\/:*?"<>|.-]', '') -replace '\s+', ' '
            $safeSuffix = $safeSuffix.Trim()

            # Rebuild output directory with suffix appended to album name
            $safeAlbum = "$safeAlbum ($safeSuffix)"
            if ($safeArtist) {
                $finalOutputDir = "$outputDriveLetter\Music\$safeArtist\$safeAlbum"
            } else {
                $finalOutputDir = "$outputDriveLetter\Music\$safeAlbum"
            }
            Write-Host "`nNew output directory:" -ForegroundColor Green
            Write-Host "  $finalOutputDir" -ForegroundColor White
            Write-Log "Version suffix applied: '$suffix' -> output dir: $finalOutputDir"
        }
    }
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
if ($discMeta -and $discMeta.TrackCount) {
    # Surfaced here specifically so a disc query garbled by a mid-read USB disconnect
    # (which can make cyanrip see far fewer tracks than the disc actually has) is
    # visible before an unattended rip starts, not just discovered after the fact in
    # the finished output. A low count doesn't hard-block - some real EPs/singles are
    # genuinely short - it's flagged so a human who knows the album can catch it.
    $trackCountColor = if ($discMeta.TrackCount -le 2) { "Red" } else { "Yellow" }
    Write-Host "Tracks detected: $($discMeta.TrackCount)$(if ($discMeta.TrackCount -le 2) { ' -- unusually low; if this album has more tracks, the disc read may be incomplete (check the drive connection and retry before continuing)' })" -ForegroundColor $trackCountColor
}
if ($RequireMusicBrainz) {
    Write-Host "MusicBrainz: REQUIRED" -ForegroundColor Yellow
}
Write-Host "========================================" -ForegroundColor Cyan
if (-not $script:IsProcessingQueue) {
    $host.UI.RawUI.WindowTitle = "rip-audio - INPUT"
    Show-QuestionHint
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

Write-Timestamp "Session started"
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

    # Use yellow for non-critical failures (rip succeeded, later step failed)
    $ripCompleted = $script:CompletedSteps | Where-Object { $_.Number -eq 1 }
    $bannerColor = if ($ripCompleted) { "Yellow" } else { "Red" }

    Write-Host "`n========================================" -ForegroundColor $bannerColor
    Write-Host "FAILED!" -ForegroundColor $bannerColor
    Write-Host "========================================" -ForegroundColor $bannerColor

    # Always show what was being processed
    Write-Host "`nProcessing: $(Get-AlbumSummary)" -ForegroundColor White

    Write-Host "`nError at: $Step" -ForegroundColor $bannerColor
    Write-Host "Message: $Message" -ForegroundColor $bannerColor

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
        Start-Process explorer.exe -ArgumentList "`"$($finalOutputDir.TrimEnd('\'))`""
    }

    Write-Host "`nLog file: $($script:LogFile)" -ForegroundColor Yellow
    Write-Host "`n========================================" -ForegroundColor $bannerColor
    Write-Host "Please complete the remaining steps manually" -ForegroundColor $bannerColor
    Write-Host "========================================`n" -ForegroundColor $bannerColor
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
if ($ParanoiaLevel -ge 0) {
    Write-Host "Paranoia level: $ParanoiaLevel (cyanrip default: 3)" -ForegroundColor White
}
if ($Retries -ge 1) {
    Write-Host "Max retries: $Retries (cyanrip default: 10)" -ForegroundColor White
}
Write-Host "Log file: $($script:LogFile)" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

# ========== STEP 1: RIP WITH CYANRIP ==========
Set-CurrentStep -StepNumber 1
Write-Log "STEP 1/4: Starting cyanrip..."
Write-Host "[STEP 1/4] Starting cyanrip..." -ForegroundColor Green
Write-Timestamp "Step 1 started"

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
        if ($DiscNum -gt 0) {
            # Expected, not a warning: this is the shared multi-disc folder already
            # containing an earlier disc's tracks.
            Write-Host "`nShared multi-disc folder already has $($existingFiles.Count) file(s) from previous disc(s):" -ForegroundColor Cyan
        } else {
            Write-Host "`nWARNING: Directory already exists with $($existingFiles.Count) file(s):" -ForegroundColor Yellow
        }
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
            # Always live-query rather than trust a .cue file for this decision - always
            # -Fresh, not conditional. A .cue file in the output folder can misreport the
            # disc's real track count in more ways than just the -DiscNum case this was
            # originally scoped to: PR #145 already fixed one crash-recovery call site for
            # exactly this reason ("a cue file written during a rip that later crashed can
            # carry a track count corrupted by the same flaky connection that caused the
            # crash"), and a real incident confirmed this DEFAULT call site has the same
            # exposure - a crashed continue-rip-audio.ps1 attempt left a 1-track .cue behind
            # for a disc that actually has 16, and this resume-detection trusted it, declaring
            # "All 1 tracks already ripped and valid" and marking a 15-tracks-missing album
            # COMPLETE. A live disc query is cheap (a few seconds, no interactive prompt even
            # on a multi-release disc - see Get-DiscTrackCount's own -R 1 retry) and is the
            # only source of truth that can't be corrupted by an earlier failed attempt.
            $totalTrackCount = Get-DiscTrackCount -OutputDir $finalOutputDir -DriveLetter $driveLetter -Fresh
        }

        if ($totalTrackCount -and $existingAudioFiles.Count -gt 0) {
            # Parse track numbers from existing filenames and validate integrity
            $validTracks = @()
            $invalidTracks = @()
            foreach ($af in $existingAudioFiles) {
                $trackNum = $null
                $fileDiscNum = $null
                # Handle both "01 - Title.flac" and "1.01 - Title.flac" (multi-disc) formats
                if ($af.BaseName -match '^(\d+)\.(\d+)\s*-') {
                    # Multi-disc format: disc.track -- use the track part
                    $fileDiscNum = [int]$Matches[1]
                    $trackNum = [int]$Matches[2]
                } elseif ($af.BaseName -match '^(\d+)\s*-') {
                    $trackNum = [int]$Matches[1]
                }

                # Under -DiscNum (shared multi-disc folder), a bare-named file or a
                # different disc's "M.NN" file belongs to another disc (or predates
                # -DiscNum use on this folder) and must not count toward THIS disc's
                # valid/missing tracks - otherwise disc 1's "1.05" would silently satisfy
                # disc 2's "track 5" requirement.
                if ($DiscNum -gt 0 -and $fileDiscNum -ne $DiscNum) {
                    continue
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
                    Show-QuestionHint
                    Write-Host "Skip rip? (all tracks present)" -ForegroundColor Cyan
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
                    Show-QuestionHint
                    Write-Host "Choose an option:" -ForegroundColor Cyan
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
                # Remove the stale/invalid audio files so cyanrip can rip fresh.
                # cyanrip will not overwrite existing files, so leaving them
                # behind produces a silent failure with 0-byte outputs.
                # Under -DiscNum (shared multi-disc folder), this must NOT touch another
                # disc's already-ripped, disc-prefixed tracks sitting in the same folder -
                # only bare-named or THIS disc's own "$DiscNum.NN" files are stale here.
                $staleAudio = Get-ChildItem -Path $finalOutputDir -Include "*.flac","*.mp3","*.opus","*.m4a","*.wav","*.aac" -Recurse -File -ErrorAction SilentlyContinue
                if ($DiscNum -gt 0) {
                    $staleAudio = @($staleAudio | Where-Object {
                        if ($_.BaseName -match '^(\d+)\.(\d+)\s*-') { [int]$Matches[1] -eq $DiscNum }
                        else { $true }  # bare-named file, e.g. from before -DiscNum was used on this folder
                    })
                }
                if ($staleAudio -and $staleAudio.Count -gt 0) {
                    Write-Host "Removing $($staleAudio.Count) stale audio file(s) before fresh rip..." -ForegroundColor Yellow
                    foreach ($stale in $staleAudio) {
                        try {
                            Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction Stop
                        } catch {
                            Write-Host "  Failed to remove $($stale.Name): $_" -ForegroundColor Red
                        }
                    }
                    Write-Log "Removed $($staleAudio.Count) stale audio file(s) before fresh rip"
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
                    Show-QuestionHint
                    Write-Host "Choose an option:" -ForegroundColor Cyan
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
                Show-QuestionHint
                Write-Host "Choose an option:" -ForegroundColor Cyan
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
    Write-Timestamp "Step 1 skipped (all tracks present)"
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
    Write-Host "  Reason: $($_.Exception.Message)" -ForegroundColor DarkGray
    Write-Log "MusicBrainz connectivity check failed: $($_.Exception.Message)"

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
        $mbRetryCount = 0
        while (-not $resolved) {
            $mbChoice = Read-Host "Choice (R/q)"
            if ($mbChoice -eq "" -or $mbChoice -match "^[Rr]") {
                $mbRetryCount++
                # A 503 from a shared public service often needs a moment, not an instant
                # re-hit - hitting Enter/R repeatedly with no gap just resends the same
                # request into the same rate limit/outage window. Backs off a little more
                # on each successive retry (capped at 15s) rather than a flat delay, so a
                # brief blip clears fast but a real outage doesn't get hammered.
                $mbBackoffSeconds = [Math]::Min(5 * $mbRetryCount, 15)
                Write-Host "Waiting ${mbBackoffSeconds}s before retrying (attempt $mbRetryCount) - avoids hammering a possibly rate-limited or still-recovering API..." -ForegroundColor DarkGray
                Start-Sleep -Seconds $mbBackoffSeconds
                Write-Host "Retrying..." -ForegroundColor Yellow
                try {
                    $mbTest = Invoke-WebRequest -Uri "https://musicbrainz.org/ws/2/release?query=test&limit=1" -Headers $mbHeaders -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
                    Write-Host "MusicBrainz API: OK" -ForegroundColor Green
                    $resolved = $true
                } catch {
                    Write-Host "MusicBrainz API: Still unreachable" -ForegroundColor Red
                    Write-Host "  Reason: $($_.Exception.Message)" -ForegroundColor DarkGray
                    Write-Log "MusicBrainz connectivity retry $mbRetryCount failed: $($_.Exception.Message)"
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
        $mbRetryCount = 0
        while (-not $resolved) {
            $mbChoice = Read-Host "Choice (R/c/q)"
            if ($mbChoice -eq "" -or $mbChoice -match "^[Rr]") {
                $mbRetryCount++
                # Same reasoning as the -RequireMusicBrainz retry loop above: back off a
                # little more on each successive retry (capped at 15s) instead of an
                # instant re-hit, so a brief blip clears fast without hammering a real
                # outage or rate limit.
                $mbBackoffSeconds = [Math]::Min(5 * $mbRetryCount, 15)
                Write-Host "Waiting ${mbBackoffSeconds}s before retrying (attempt $mbRetryCount) - avoids hammering a possibly rate-limited or still-recovering API..." -ForegroundColor DarkGray
                Start-Sleep -Seconds $mbBackoffSeconds
                Write-Host "Retrying..." -ForegroundColor Yellow
                try {
                    $mbTest = Invoke-WebRequest -Uri "https://musicbrainz.org/ws/2/release?query=test&limit=1" -Headers $mbHeaders -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
                    Write-Host "MusicBrainz API: OK" -ForegroundColor Green
                    $resolved = $true
                } catch {
                    Write-Host "MusicBrainz API: Still unreachable" -ForegroundColor Red
                    Write-Host "  Reason: $($_.Exception.Message)" -ForegroundColor DarkGray
                    Write-Log "MusicBrainz connectivity retry $mbRetryCount failed: $($_.Exception.Message)"
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

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  It's ripping time! No more inputs needed." -ForegroundColor Cyan
Write-Host "  Make a coffee and come back later." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Executing cyanrip command..." -ForegroundColor Yellow

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

# Add paranoia level flag (cyanrip default is 3; lower values skip bad sectors faster)
if ($ParanoiaLevel -ge 0) {
    $cyanripArgs += @("-P", "$ParanoiaLevel")
}

# Add retries flag (cyanrip default is 10; lower values give up on unreadable frames sooner)
if ($Retries -ge 1) {
    $cyanripArgs += @("-r", "$Retries")
}

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

$paranoiaFlag = if ($ParanoiaLevel -ge 0) { " -P $ParanoiaLevel" } else { "" }
$retriesFlag = if ($Retries -ge 1) { " -r $Retries" } else { "" }
$qualityFlag = if ($Quality -gt 0 -and $hasLossy) { " -b $Quality" } else { "" }
$releaseFlag = if ($script:ReleaseChoice) { " -R $($script:ReleaseChoice)" } else { "" }
$resumeFlag = if ($script:ResumeTrackList) { " -l $($script:ResumeTrackList)" } else { "" }
$cmdDisplay = "cyanrip -D `"$albumFolder`" -o $format -d $driveLetter -s 0$paranoiaFlag$retriesFlag$qualityFlag$(if ($skipMusicBrainz) { ' -N' })$releaseFlag$resumeFlag"
Write-Host "Working directory: $parentDir" -ForegroundColor Gray
Write-Host "Command: $cmdDisplay" -ForegroundColor Gray
Write-Log "cyanrip working directory: $parentDir"
Write-Log "cyanrip command: $cmdDisplay"

# Execute cyanrip from the parent directory with cdio error detection.
# If cyanrip hits repeated cdio errors (unreadable sectors), kill it and
# auto-resume skipping the failed track rather than freezing indefinitely.
$cdioErrorThreshold = 30  # consecutive cdio error lines before killing
# Separate watchdog for the case the cdio-error counter can't catch: cyanrip going
# completely silent (no progress lines, no errors, nothing) while working - or stuck -
# deep in a paranoia-level retry loop below the 10% progress-display threshold on a
# damaged/dirty sector. Confirmed live: the same disc twice produced a fully silent,
# apparently-hung terminal with no error text at all to trigger the counter above.
$silenceTimeoutMinutes = 5  # minutes with zero output before treating cyanrip as stuck
$script:SkippedTracks = @()

# A native crash (Windows structured-exception exit codes, e.g. -1073741819 /
# 0xC0000005 access violation) always shows up as a huge negative Int32 -- normal
# cyanrip exits are small (0, 1, a handful of others). Distinguished from the
# cdio-error watchdog kill above: that's cyanrip *reporting* trouble on a track
# and being killed deliberately; this is cyanrip itself dying unexpectedly,
# typically from the same flaky USB/drive connection dropping mid-read. Both
# cases warrant the same auto-resume treatment below.
function Test-CyanripCrashExit {
    param([long]$ExitCode)
    return $ExitCode -le -1000000
}

function Start-CyanripWithErrorDetection {
    param(
        [string[]]$CyanripArgs,
        [string]$WorkDir
    )

    $cyanripPath = (Get-Command cyanrip -ErrorAction Stop).Source
    $psi = [System.Diagnostics.ProcessStartInfo]::new($cyanripPath)
    # ProcessStartInfo.ArgumentList is a .NET Core / .NET 5+ API and is NULL
    # on PowerShell 5.1 (.NET Framework 4.x). Calling .Add() on the null
    # collection silently fails inside a try/catch and the process launches
    # with zero arguments -- cyanrip then exits 0 without doing anything.
    # Build a quoted argument string and set $psi.Arguments instead (works
    # on both .NET Framework and .NET Core).
    #
    # The parameter is deliberately NOT named $Args -- $Args is a reserved
    # PowerShell automatic variable, and a function parameter with that name
    # is silently overridden by the (empty) automatic $args, so the caller's
    # argument array never reaches the body of the function.
    $quotedArgs = @()
    foreach ($a in $CyanripArgs) {
        if ([string]::IsNullOrEmpty($a)) {
            $quotedArgs += '""'
        } elseif ($a -match '[\s"]') {
            $quotedArgs += '"' + ($a -replace '"', '\"') + '"'
        } else {
            $quotedArgs += $a
        }
    }
    $psi.Arguments = $quotedArgs -join ' '
    $psi.WorkingDirectory = $WorkDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi

    # Use Task-based async reads instead of OutputDataReceived events.
    # In PowerShell 5.1 the scriptblock registered via .add_OutputDataReceived
    # runs in a different scope and cannot see the local ConcurrentQueue, so
    # lines are silently dropped and the rip appears to hang with no console
    # output. StreamReader.ReadLineAsync() returns a Task we can poll directly
    # on the main thread, which sidesteps the scope problem.
    [void]$proc.Start()

    $outputLines = [System.Collections.ArrayList]::new()
    $consecutiveCdioErrors = 0
    $lastCompletedTrack = 0
    $killedDueToErrors = $false
    $killedForSilence = $false
    # Reset every time ANY output line is read (progress, error, anything) - tracks
    # wall-clock time since cyanrip last said something, independent of the cdio-error
    # counter above, which only advances on lines matching specific error text and
    # never fires if cyanrip goes fully silent instead of erroring.
    $lastActivityTime = Get-Date

    $stdoutTask = $proc.StandardOutput.ReadLineAsync()
    $stderrTask = $proc.StandardError.ReadLineAsync()
    $stdoutEof = $false
    $stderrEof = $false

    # Progress milestone tracking: cyanrip emits a progress line per sector
    # (hundreds per second). Only surface the first time each track crosses
    # a 10% boundary so the console stays informative without being spammy.
    $progressTrack = -1
    $progressBucket = -1

    while (-not ($proc.HasExited -and $stdoutEof -and $stderrEof)) {
        $anyRead = $false

        foreach ($taskRef in @('stdout', 'stderr')) {
            if ($taskRef -eq 'stdout') {
                if ($stdoutEof) { continue }
                $task = $stdoutTask
                $reader = $proc.StandardOutput
            } else {
                if ($stderrEof) { continue }
                $task = $stderrTask
                $reader = $proc.StandardError
            }

            if (-not $task.IsCompleted) { continue }

            $line = $task.Result
            if ($null -eq $line) {
                if ($taskRef -eq 'stdout') { $stdoutEof = $true } else { $stderrEof = $true }
                continue
            }

            $anyRead = $true
            $lastActivityTime = Get-Date
            [void]$outputLines.Add($line)

            # Collapse cyanrip's per-sector progress ticker down to one line
            # per 10% milestone per track. Suppress the 0-9% bucket -- at
            # ~0.01% cyanrip has no sample history so its ETA is nonsense
            # (e.g. "424h 29m"). First milestone shown is 10%.
            $suppress = $false
            if ($line -match 'track\s+(\d+).*progress\s*-\s*(\d+)\.\d+%') {
                $trackNum = [int]$Matches[1]
                $pct = [int]$Matches[2]
                $bucket = [Math]::Floor($pct / 10) * 10
                if ($trackNum -ne $progressTrack) {
                    $progressTrack = $trackNum
                    $progressBucket = -1
                }
                if ($bucket -lt 10 -or $bucket -le $progressBucket) {
                    $suppress = $true
                } else {
                    $progressBucket = $bucket
                }
            }
            if (-not $suppress) {
                Write-Host $line
            }

            if ($line -match 'Track\s+(\d+)\s+ripped and encoded successfully') {
                $lastCompletedTrack = [int]$Matches[1]
                $consecutiveCdioErrors = 0
            }

            if ($line -match 'cdio error|Unknown, unrecoverable error reading data') {
                $consecutiveCdioErrors++
            } elseif ($line -match '\S' -and $line -notmatch 'cdio error|Unknown, unrecoverable error') {
                $consecutiveCdioErrors = 0
            }

            if ($consecutiveCdioErrors -ge $cdioErrorThreshold) {
                $failedTrack = $lastCompletedTrack + 1
                Write-Host "`n*** CDIO ERROR: Track $failedTrack is unreadable -- skipping ***" -ForegroundColor Red
                Write-Log "Track ${failedTrack}: unreadable (cdio error threshold exceeded) -- killing cyanrip"
                $killedDueToErrors = $true
                try { $proc.Kill() } catch {}
                break
            }

            # Start the next read on this stream
            $nextTask = $reader.ReadLineAsync()
            if ($taskRef -eq 'stdout') { $stdoutTask = $nextTask } else { $stderrTask = $nextTask }
        }

        if ($killedDueToErrors) { break }

        if (-not $anyRead) {
            if (-not $proc.HasExited -and ((Get-Date) - $lastActivityTime).TotalMinutes -ge $silenceTimeoutMinutes) {
                $failedTrack = $lastCompletedTrack + 1
                Write-Host "`n*** SILENCE TIMEOUT: no cyanrip output for $silenceTimeoutMinutes minute(s) -- likely stuck on track $failedTrack -- killing ***" -ForegroundColor Red
                Write-Log "Silence timeout: no cyanrip output for $silenceTimeoutMinutes minute(s) after track $lastCompletedTrack -- killing cyanrip (likely stuck on track $failedTrack)"
                $killedDueToErrors = $true
                $killedForSilence = $true
                try { $proc.Kill() } catch {}
                break
            }
            Start-Sleep -Milliseconds 50
        }
    }

    return @{
        ExitCode = $proc.ExitCode
        Output = $outputLines.ToArray()
        Killed = $killedDueToErrors
        KilledForSilence = $killedForSilence
        LastCompletedTrack = $lastCompletedTrack
    }
}

# Back up any non-empty audio files already in the output directory. If
# cyanrip fails to read the TOC on a damaged disc it opens (and thereby
# truncates) output files BEFORE it fails, which destroys any existing
# good tracks from a prior successful rip. Backing them up lets us
# restore on failure so the user does not lose work.
$script:PreRipBackupDir = $null
$preRipAudio = @(Get-ChildItem -Path $finalOutputDir -Include "*.flac","*.mp3","*.opus","*.m4a","*.wav","*.aac" -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 })
if ($preRipAudio.Count -gt 0) {
    $script:PreRipBackupDir = Join-Path $env:TEMP ("ripaudio-backup-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    try {
        New-Item -ItemType Directory -Path $script:PreRipBackupDir -Force | Out-Null
        foreach ($f in $preRipAudio) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $script:PreRipBackupDir $f.Name) -Force
        }
        Write-Log "Backed up $($preRipAudio.Count) existing non-empty audio file(s) to $script:PreRipBackupDir"
    } catch {
        Write-Host "Could not back up existing audio files: $_" -ForegroundColor Yellow
        Write-Log "Backup failed: $_"
        $script:PreRipBackupDir = $null
    }
}

Push-Location $parentDir
try {
    $result = Start-CyanripWithErrorDetection -CyanripArgs $cyanripArgs -WorkDir $parentDir

    # If killed due to cdio errors, or cyanrip crashed outright (native exit code -
    # both usually mean the same underlying flaky USB/drive connection - skip the
    # failed track and resume remaining tracks.
    while ($result.Killed -or (Test-CyanripCrashExit $result.ExitCode)) {
        $failedTrack = $result.LastCompletedTrack + 1
        $script:SkippedTracks += $failedTrack
        $wasCrash = -not $result.Killed

        # Total track count: re-query the disc fresh rather than trusting "Disc tracks: N"
        # from this same run's own output. On a crash in particular, that number can itself
        # be wrong - a flaky connection dropping mid-TOC-read can make cyanrip see far fewer
        # tracks than the disc actually has (its own discovery output has documented this,
        # e.g. "2 instead of 13"), which is exactly the kind of corruption that can also cause
        # the crash. Trusting the crashed run's self-reported total risks concluding "no more
        # tracks to rip" when the real disc has several more left.
        if ($wasCrash) {
            Write-Host "`ncyanrip crashed (exit $($result.ExitCode)) after track $($result.LastCompletedTrack) -- re-querying the disc for an accurate track count before deciding what's left..." -ForegroundColor Yellow
            Write-Log "cyanrip crashed with exit $($result.ExitCode) after track $($result.LastCompletedTrack) -- re-querying disc fresh"
        }
        $totalFromOutput = Get-DiscTrackCount -OutputDir $finalOutputDir -DriveLetter $driveLetter -Fresh
        if (-not $totalFromOutput) {
            # Fall back to whatever this run itself reported, if a fresh live query failed
            # (e.g. drive transiently not responding) rather than giving up immediately.
            $allOutput = $result.Output -join "`n"
            if ($allOutput -match 'Disc tracks:\s+(\d+)') {
                $totalFromOutput = [int]$Matches[1]
            }
        }

        if (-not $totalFromOutput) {
            Write-Host "Cannot determine total tracks -- unable to auto-resume" -ForegroundColor Red
            break
        }

        # Build list of remaining tracks (after the failed one)
        $remainingTracks = @()
        for ($t = $failedTrack + 1; $t -le $totalFromOutput; $t++) {
            $remainingTracks += $t
        }

        if ($remainingTracks.Count -eq 0) {
            Write-Host "No more tracks to rip after skipping track $failedTrack" -ForegroundColor Yellow
            break
        }

        $trackList = $remainingTracks -join ","
        Write-Host "`nResuming rip from track $($remainingTracks[0]) (skipped: $($script:SkippedTracks -join ', '))..." -ForegroundColor Cyan
        Write-Log "Resuming: ripping tracks $trackList (skipped: $($script:SkippedTracks -join ', '))"

        # Build resume args with -l flag for remaining tracks
        $resumeArgs = @(
            "-D", $albumFolder,
            "-o", $format,
            "-d", $driveLetter,
            "-s", "0",
            "-l", $trackList
        )
        if ($ParanoiaLevel -ge 0) { $resumeArgs += @("-P", "$ParanoiaLevel") }
        if ($Retries -ge 1) { $resumeArgs += @("-r", "$Retries") }
        if ($Quality -gt 0 -and $hasLossy) { $resumeArgs += @("-b", "$Quality") }
        if ($skipMusicBrainz) { $resumeArgs += @("-N") }
        if ($script:ReleaseChoice) { $resumeArgs += @("-R", $script:ReleaseChoice) }

        $result = Start-CyanripWithErrorDetection -CyanripArgs $resumeArgs -WorkDir $parentDir
    }

    $cyanripExitCode = $result.ExitCode
    $cyanripOutput = $result.Output

    # Show summary of skipped tracks
    if ($script:SkippedTracks.Count -gt 0) {
        Write-Host "`nWARNING: $($script:SkippedTracks.Count) track(s) skipped due to disc damage: $($script:SkippedTracks -join ', ')" -ForegroundColor Yellow
        Write-Log "Tracks skipped due to cdio errors: $($script:SkippedTracks -join ', ')"
    }
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
        if ($line -match '^\s*(\d+)\s+\(ID:\s*([a-f0-9-]+)\):\s*(.+)$') {
            $releases += @{
                Index = $Matches[1]
                UUID = $Matches[2]
                Description = $Matches[3].Trim()
            }
        }
    }

    if ($releases.Count -gt 0) {
        # Fetch track info for each release to help differentiate versions
        $trackHeaders = @{
            "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)"
            "Accept" = "application/json"
        }
        Write-Host "Fetching track details for each release..." -ForegroundColor Gray
        foreach ($rel in $releases) {
            try {
                if ($releases.IndexOf($rel) -gt 0) { Start-Sleep -Seconds 1 }
                $trackUrl = "https://musicbrainz.org/ws/2/release/$($rel.UUID)?inc=media+recordings&fmt=json"
                $trackResp = Invoke-RestMethod -Uri $trackUrl -Headers $trackHeaders -TimeoutSec 10
                if ($trackResp.media -and $trackResp.media.Count -gt 0) {
                    $medium = $trackResp.media[0]
                    $rel.TrackCount = $medium.'track-count'
                    if ($medium.tracks -and $medium.tracks.Count -gt 0) {
                        $rel.FirstTrack = $medium.tracks[0].title
                        $rel.LastTrack = $medium.tracks[-1].title
                    }
                }
            } catch {
                # Continue without track info if API call fails
            }
        }

        Write-Host "Select a release:" -ForegroundColor Cyan
        foreach ($rel in $releases) {
            $info = "  $($rel.Index): $($rel.Description)"
            if ($rel.TrackCount) {
                $info += " | $($rel.TrackCount) tracks"
                if ($rel.FirstTrack -and $rel.LastTrack) {
                    $info += " (Track 1: $($rel.FirstTrack) ... Last track: $($rel.LastTrack))"
                }
            }
            Write-Host $info -ForegroundColor White
        }
        Write-Host ""

        if ($script:IsProcessingQueue) {
            # Auto-pick first release in ProcessQueue mode
            $choice = "1"
            Write-Host "ProcessQueue mode: auto-selecting release 1" -ForegroundColor Yellow
        } else {
            Show-QuestionHint
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
            $result = Start-CyanripWithErrorDetection -CyanripArgs $cyanripArgs -WorkDir $parentDir
            $cyanripExitCode = $result.ExitCode
            $cyanripOutput = $result.Output
            if ($result.Killed) {
                $script:SkippedTracks += ($result.LastCompletedTrack + 1)
            }
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
                $result = Start-CyanripWithErrorDetection -CyanripArgs $cyanripArgs -WorkDir $parentDir
                $cyanripExitCode = $result.ExitCode
                $cyanripOutput = $result.Output
                if ($result.Killed) { $script:SkippedTracks += ($result.LastCompletedTrack + 1) }
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
                $result = Start-CyanripWithErrorDetection -CyanripArgs $cyanripArgs -WorkDir $parentDir
                $cyanripExitCode = $result.ExitCode
                $cyanripOutput = $result.Output
                if ($result.Killed) { $script:SkippedTracks += ($result.LastCompletedTrack + 1) }
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

# Check if disc not found in MusicBrainz (or only a stub) - try CDDB fallback, then offer generic names
if ($cyanripExitCode -ne 0 -and ($cyanripOutputText -match "Unable to find release info" -or $cyanripOutputText -match "DiscID has a matching stub")) {
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
            $result = Start-CyanripWithErrorDetection -CyanripArgs $cyanripArgs -WorkDir $parentDir
            $cyanripExitCode = $result.ExitCode
            $cyanripOutput = $result.Output
            if ($result.Killed) { $script:SkippedTracks += ($result.LastCompletedTrack + 1) }
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
                $result = Start-CyanripWithErrorDetection -CyanripArgs $cyanripArgs -WorkDir $parentDir
                $cyanripExitCode = $result.ExitCode
                $cyanripOutput = $result.Output
                if ($result.Killed) { $script:SkippedTracks += ($result.LastCompletedTrack + 1) }
            } catch {
                Pop-Location
                Stop-WithError -Step "STEP 1/4: cyanrip" -Message "Failed to execute cyanrip: $_"
            }
            Pop-Location

            $cyanripOutputText = $cyanripOutput -join "`n"
        }
    }
}

# Check post-rip state. A non-zero exit code alone is not enough to abort:
# cyanrip often exits 1 when resume is requested on an unreadable TOC even
# after it successfully ripped most of the disc on the first pass. Prefer
# "did any audio actually land on disk" over the exit code -- if we have
# at least one non-empty audio file we proceed with the partial rip and
# only warn. We hard-abort only when nothing was ripped at all.
$postRipAudio = Get-ChildItem -Path $finalOutputDir -Include "*.flac","*.mp3","*.opus","*.m4a","*.wav","*.aac" -Recurse -File -ErrorAction SilentlyContinue
$postRipNonEmpty = @($postRipAudio | Where-Object { $_.Length -gt 0 })
# Size alone isn't enough either -- a mid-write USB disconnect can leave a file with
# nonzero size that still isn't valid audio (e.g. FLAC__METADATA_CHAIN_STATUS_NOT_A_
# FLAC_FILE on a truncated container). Reuse the same Test-TrackIntegrity check the
# resume-detection path already trusts, so a corrupt-but-nonzero track is caught here
# instead of sailing through renaming/tagging into a "COMPLETE!" summary that doesn't
# reflect what's actually on disk.
$script:CorruptTracks = @()
$postRipValid = @($postRipNonEmpty | Where-Object { Test-TrackIntegrity -FilePath $_.FullName })
$postRipCorrupt = @($postRipNonEmpty | Where-Object { $_.FullName -notin @($postRipValid | ForEach-Object { $_.FullName }) })

# Restore any pre-rip audio files that cyanrip destroyed (truncated to 0
# bytes) before failing. For each backed-up file, if the corresponding
# file in the output directory is missing or 0 bytes, copy the backup
# back. Tracks cyanrip successfully re-ripped are left alone.
if ($script:PreRipBackupDir -and (Test-Path $script:PreRipBackupDir)) {
    $restored = 0
    foreach ($bk in Get-ChildItem -Path $script:PreRipBackupDir -File) {
        $target = Join-Path $finalOutputDir $bk.Name
        $currentSize = if (Test-Path $target) { (Get-Item -LiteralPath $target).Length } else { -1 }
        if ($currentSize -le 0) {
            try {
                Copy-Item -LiteralPath $bk.FullName -Destination $target -Force
                $restored++
            } catch {
                Write-Log "Failed to restore $($bk.Name) from backup: $_"
            }
        }
    }
    if ($restored -gt 0) {
        Write-Host "Restored $restored existing audio file(s) that were destroyed by the failed rip attempt." -ForegroundColor Yellow
        Write-Log "Restored $restored audio file(s) from pre-rip backup"
        # Refresh the post-rip state now that files have been restored
        $postRipAudio = Get-ChildItem -Path $finalOutputDir -Include "*.flac","*.mp3","*.opus","*.m4a","*.wav","*.aac" -Recurse -File -ErrorAction SilentlyContinue
        $postRipNonEmpty = @($postRipAudio | Where-Object { $_.Length -gt 0 })
        $postRipValid = @($postRipNonEmpty | Where-Object { Test-TrackIntegrity -FilePath $_.FullName })
        $postRipCorrupt = @($postRipNonEmpty | Where-Object { $_.FullName -notin @($postRipValid | ForEach-Object { $_.FullName }) })
    }
    try { Remove-Item -LiteralPath $script:PreRipBackupDir -Recurse -Force -ErrorAction Stop } catch { Write-Log "Could not remove backup dir $($script:PreRipBackupDir): $_" }
    $script:PreRipBackupDir = $null
}

if ($postRipValid.Count -eq 0) {
    # Nothing usable ripped -- fail hard with the best diagnostic we can muster
    $silentFailureMessage = if ($cyanripOutputText -match "no disc" -or $cyanripOutputText -match "no medium" -or $cyanripOutputText -match "drive is empty") {
        "No disc in drive $driveLetter - please insert an audio CD"
    } elseif ($cyanripOutputText -match "not an audio" -or $cyanripOutputText -match "data disc") {
        "Disc in $driveLetter is not an audio CD"
    } elseif ($cyanripOutputText -match "drive not found" -or $cyanripOutputText -match "cannot open") {
        "Could not access drive $driveLetter - verify drive letter is correct"
    } elseif ($cyanripOutputText -match 'could not read TOC|Invalid number of tracks|Could not determine disc ID') {
        "cyanrip could not read the disc TOC -- disc may be dirty, damaged, or the wrong type. Try cleaning the disc, trying another drive, or checking the USB connection."
    } elseif ($postRipAudio.Count -gt 0) {
        # No manual deletion needed - re-running this same command with the disc back
        # in the drive hits the existing-directory resume path (see README "Resuming
        # Interrupted Rips"), which detects these corrupt/zero-byte files via the same
        # Test-TrackIntegrity check, treats them as missing, and cleans them up itself.
        "cyanrip produced $($postRipAudio.Count) corrupt/zero-byte file(s) and nothing valid - likely a dropped drive connection mid-rip. Re-run this same command with the disc still in the drive; the script will detect the failed attempt and offer to clean up and retry."
    } elseif ($cyanripExitCode -ne 0) {
        "cyanrip exited with code $cyanripExitCode and produced no audio files. Check the cyanrip output above for errors."
    } else {
        "cyanrip exited with code 0 but produced no audio files in $finalOutputDir -- the rip silently failed. Check the cyanrip output above for errors."
    }
    Write-Host "`nERROR: $silentFailureMessage" -ForegroundColor Red
    Write-Log "Silent cyanrip failure: $silentFailureMessage"
    Stop-WithError -Step "STEP 1/4: cyanrip" -Message $silentFailureMessage
} else {
    if ($cyanripExitCode -ne 0) {
        # Partial rip -- some audio landed on disk but cyanrip reported a
        # non-zero exit (typically from the resume pass hitting an unreadable
        # sector). Warn the user but keep what we have and continue to the
        # rest of the pipeline; they'd rather have 13/17 tracks than nothing.
        Write-Host "`nWARNING: cyanrip exited with code $cyanripExitCode but $($postRipValid.Count) track(s) were ripped successfully." -ForegroundColor Yellow
        Write-Host "Continuing with partial rip -- damaged tracks (if any) will be missing from the output." -ForegroundColor Yellow
        Write-Log "Partial rip accepted: exit=$cyanripExitCode, $($postRipValid.Count) valid audio file(s) in $finalOutputDir"
    }
    if ($postRipCorrupt.Count -gt 0) {
        # Deliberately checked independently of the exit-code branch above - cyanrip
        # can exit 0 while still leaving a corrupt/zero-byte track behind (a USB
        # disconnect doesn't always make cyanrip itself report failure), so this must
        # not be conditional on a non-zero exit code or it silently slips through into
        # a "COMPLETE!" summary that doesn't reflect what's actually on disk.
        $corruptNames = ($postRipCorrupt | ForEach-Object { $_.Name }) -join ", "
        Write-Host "`nWARNING: $($postRipCorrupt.Count) file(s) are corrupt or zero-byte and will NOT be usable: $corruptNames" -ForegroundColor Red
        Write-Host "This usually means the drive connection dropped partway through that track. Re-run this same command with the disc still in the drive to resume just the affected track(s)." -ForegroundColor Yellow
        Write-Log "Corrupt/zero-byte post-rip file(s): $corruptNames"
        $script:CorruptTracks = $postRipCorrupt.Name
    }
}

Write-Host "`ncyanrip complete!" -ForegroundColor Green
Write-Timestamp "Step 1 complete"
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

# ========== DATA ERROR HANDLING ==========
# Parse cyanrip output for per-track data errors and prompt user to retry or skip
$script:DataErrorTracks = @()
$dataErrorTracks = Parse-TrackDataErrors -Output $cyanripOutputText

if ($dataErrorTracks.Count -gt 0) {
    Write-Host "`nDATA ERRORS DETECTED on $($dataErrorTracks.Count) track(s): $($dataErrorTracks -join ', ')" -ForegroundColor Red
    Write-Log "Data errors detected on tracks: $($dataErrorTracks -join ', ')"

    foreach ($errorTrack in $dataErrorTracks) {
        $trackPadded = "{0:D2}" -f $errorTrack

        if ($script:IsProcessingQueue) {
            # Auto-skip in ProcessQueue mode
            Write-Host "  Track ${trackPadded}: DATA ERROR -- auto-skipping (queue mode)" -ForegroundColor Yellow
            Write-Log "Track ${trackPadded}: data error, auto-skipped (queue mode)"
            $script:DataErrorTracks += $errorTrack
        } else {
            Show-QuestionHint
            $resolved = $false
            while (-not $resolved) {
                Write-Host ""
                Write-Host "  Track $trackPadded has data errors." -ForegroundColor Yellow
                Write-Host "    [R] Retry -- eject disc, clean/reinsert, re-rip this track" -ForegroundColor White
                Write-Host "    [S] Skip  -- mark as _DATA_ERROR and continue to next track" -ForegroundColor White
                Write-Host ""
                $errChoice = Read-Host "  Choice (R/s)"

                if ($errChoice -eq "" -or $errChoice -match "^[Rr]") {
                    # Eject disc for cleaning
                    Write-Host "  Ejecting disc for cleaning..." -ForegroundColor Yellow
                    try {
                        $driveEject = New-Object -comObject Shell.Application
                        $driveEject.Namespace(17).ParseName($driveLetter).InvokeVerb("Eject")
                    } catch {}

                    Read-Host "  Clean the disc and reinsert it, then press Enter to retry"

                    # Wait for drive to become ready
                    Write-Host "  Waiting for disc..." -ForegroundColor Gray
                    $driveReady = $false
                    for ($w = 0; $w -lt 30; $w++) {
                        Start-Sleep -Seconds 1
                        if (Test-Path $driveLetter) {
                            $driveReady = $true
                            break
                        }
                    }
                    if (-not $driveReady) {
                        Write-Host "  Drive not ready after 30 seconds." -ForegroundColor Yellow
                        continue
                    }

                    # Re-rip just this track using -l flag
                    Write-Host "  Re-ripping track $trackPadded..." -ForegroundColor Cyan
                    $retryArgs = @(
                        "-D", $albumFolder,
                        "-o", $format,
                        "-d", $driveLetter,
                        "-s", "0",
                        "-l", "$errorTrack"
                    )
                    if ($Quality -gt 0 -and $hasLossy) { $retryArgs += @("-b", "$Quality") }
                    if ($skipMusicBrainz) { $retryArgs += @("-N") }
                    if ($script:ReleaseChoice) { $retryArgs += @("-R", $script:ReleaseChoice) }

                    Write-Log "Retrying track ${trackPadded}: cyanrip -l $errorTrack"

                    Push-Location $parentDir
                    try {
                        $retryResult = Start-CyanripWithErrorDetection -CyanripArgs $retryArgs -WorkDir $parentDir
                        $retryExitCode = $retryResult.ExitCode
                        $retryOutput = $retryResult.Output -join "`n"
                        if ($retryResult.Killed) {
                            Write-Host "  Track $trackPadded still unreadable -- skipping" -ForegroundColor Yellow
                        }
                    } catch {
                        Pop-Location
                        Write-Host "  Retry failed: $_" -ForegroundColor Red
                        continue
                    }
                    Pop-Location

                    # Check if retry had errors too
                    $retryErrors = Parse-TrackDataErrors -Output $retryOutput
                    if ($retryExitCode -eq 0 -and $retryErrors.Count -eq 0) {
                        Write-Host "  Track $trackPadded re-ripped successfully!" -ForegroundColor Green
                        Write-Log "Track ${trackPadded}: retry successful"
                        $resolved = $true
                    } else {
                        Write-Host "  Track $trackPadded still has errors after retry." -ForegroundColor Yellow
                        # Loop back to prompt again
                    }
                } elseif ($errChoice -match "^[Ss]") {
                    Write-Host "  Track ${trackPadded}: marked for _DATA_ERROR suffix" -ForegroundColor Yellow
                    Write-Log "Track ${trackPadded}: data error, user chose to skip"
                    $script:DataErrorTracks += $errorTrack
                    $resolved = $true
                } else {
                    Write-Host "  Invalid choice. Enter R or S" -ForegroundColor Yellow
                }
            }
        }
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

# Rename data error tracks with _DATA_ERROR suffix
if ($script:DataErrorTracks.Count -gt 0) {
    Write-Host "`nApplying _DATA_ERROR suffix to skipped tracks..." -ForegroundColor Yellow
    # Re-scan for current files
    $currentFiles = @()
    foreach ($ext in $audioExtensions) {
        $f = Get-ChildItem -Path $finalOutputDir -Filter $ext -ErrorAction SilentlyContinue
        if ($f) { $currentFiles += $f }
    }

    foreach ($errTrackNum in $script:DataErrorTracks) {
        $trackPadded = "{0:D2}" -f $errTrackNum
        $matchingFile = $currentFiles | Where-Object { $_.BaseName -match "^$trackPadded(\s|-)" } | Select-Object -First 1
        if ($matchingFile) {
            $newName = "$($matchingFile.BaseName)_DATA_ERROR$($matchingFile.Extension)"
            try {
                Rename-Item -Path $matchingFile.FullName -NewName $newName -ErrorAction Stop
                Write-Host "  $($matchingFile.Name) -> $newName" -ForegroundColor Yellow
                Write-Log "Data error rename: $($matchingFile.Name) -> $newName"
            } catch {
                Write-Host "  Failed to rename: $($matchingFile.Name)" -ForegroundColor Red
                Write-Log "WARNING: Failed to rename data error track $($matchingFile.Name): $_"
            }
        }
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

                # metaflac is an external exe: a non-zero exit does not throw, so the
                # catch below never sees it. Check $LASTEXITCODE or we report success
                # on a failed tag. Same pattern as search-metadata.ps1 (-Reset path).
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  Tagged: $($track.Name)" -ForegroundColor Gray
                    Write-Log "Tagged: $($track.Name) [Artist=$tagArtist, Album=$tagAlbum, Title=$trackTitle, Track=$trackNum/$totalTracks]"
                } else {
                    Write-Host "  Failed to tag: $($track.Name) (metaflac exit $LASTEXITCODE)" -ForegroundColor Yellow
                    Write-Log "WARNING: Failed to tag $($track.Name): metaflac exited $LASTEXITCODE"
                }
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

# ========== MULTI-DISC PREFIX RENAME (-DiscNum) ==========
# Prepend this disc's number to every freshly-ripped track filename ("NN - Title.ext"
# -> "$DiscNum.NN - Title.ext") so it can share the album folder with other discs
# without colliding - cyanrip always numbers a disc's own tracks starting at 1, so
# disc 2's "01 - Title.flac" would otherwise silently overwrite (or fail to write
# alongside) disc 1's own "01 - Title.flac". Only bare "NN - Title.ext" files are
# touched - anything already prefixed "N.NN - Title.ext" (this disc's own files from
# an earlier partial run, or another disc's files already renamed) is left alone.
if ($DiscNum -gt 0) {
    $filesToPrefix = Get-ChildItem -Path $finalOutputDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^\d+\s*-' -and $_.BaseName -notmatch '^\d+\.\d+\s*-' }
    if ($filesToPrefix.Count -gt 0) {
        Write-Host "`nPrefixing $($filesToPrefix.Count) track file(s) with disc number $DiscNum..." -ForegroundColor Yellow
        foreach ($f in $filesToPrefix) {
            $newName = "$DiscNum.$($f.Name)"
            try {
                Rename-Item -LiteralPath $f.FullName -NewName $newName -ErrorAction Stop
                Write-Log "Renamed for multi-disc: $($f.Name) -> $newName"
            } catch {
                Write-Host "  Failed to rename $($f.Name): $_" -ForegroundColor Red
                Write-Log "WARNING: Failed to rename $($f.Name) for multi-disc: $_"
            }
        }
        Write-Host "Done." -ForegroundColor Green
    }
}

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
Write-Timestamp "Step 2 started"

# Check for ripped files based on format(s). Zero-byte and corrupt files are treated
# as not ripped -- both indicate a silent cyanrip failure (most often a dropped drive
# connection mid-write) where the output file was created but never validly written.
# Test-TrackIntegrity (the same check the resume-detection and Step 1 post-rip checks
# use) catches a truncated-but-nonzero file that a size-only check would miss.
$formatExtMap = @{ "flac" = "*.flac"; "mp3" = "*.mp3"; "opus" = "*.opus"; "aac" = "*.m4a"; "wav" = "*.wav"; "alac" = "*.m4a" }
$rippedFiles = @()
foreach ($f in $formatList) {
    $ext = $formatExtMap[$f]
    if ($ext) {
        $files = Get-ChildItem -Path $finalOutputDir -Filter $ext -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 -and (Test-TrackIntegrity -FilePath $_.FullName) }
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
        # cyanrip may have created a differently-named directory (e.g. Unicode dash truncation).
        # Look for sibling directories that share the same name prefix and contain audio files.
        $parentDir = Split-Path -Parent $finalOutputDir
        $albumLeaf = Split-Path -Leaf $finalOutputDir
        # Use first 10 chars as prefix to find cyanrip's actual output
        $prefixLen = [Math]::Min(10, $albumLeaf.Length)
        $prefix = $albumLeaf.Substring(0, $prefixLen)
        $siblingDirs = Get-ChildItem -Path $parentDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $albumLeaf -and $_.Name.StartsWith($prefix) }
        $foundInSibling = $false
        foreach ($dir in $siblingDirs) {
            $siblingAudio = Get-ChildItem -Path $dir.FullName -Include "*.flac","*.mp3","*.opus","*.m4a","*.wav" -Recurse -ErrorAction SilentlyContinue
            if ($siblingAudio -and $siblingAudio.Count -gt 0) {
                Write-Host "Found audio files in '$($dir.Name)' instead of '$albumLeaf' (cyanrip directory name mismatch)" -ForegroundColor Yellow
                Write-Host "Moving files to expected directory..." -ForegroundColor Yellow
                # Move contents from cyanrip's directory to the expected directory
                Get-ChildItem -Path $dir.FullName | Move-Item -Destination $finalOutputDir -Force
                Remove-Item -Path $dir.FullName -Force -ErrorAction SilentlyContinue
                $rippedFiles = Get-ChildItem -Path $finalOutputDir -Include "*.flac","*.mp3","*.opus","*.m4a","*.wav" -Recurse -ErrorAction SilentlyContinue
                $foundInSibling = $true
                break
            }
        }
        if (-not $foundInSibling) {
            Stop-WithError -Step "STEP 2/4: Verify output" -Message "No audio files found in $finalOutputDir"
        }
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
Write-Timestamp "Step 2 complete"
Write-Log "STEP 2/4: Verification complete - $($rippedFiles.Count) file(s)"

# ========== STEP 3: COVER ART ==========
Set-CurrentStep -StepNumber 3
Write-Log "STEP 3/4: Downloading cover art..."
Write-Host "`n[STEP 3/4] Downloading cover art..." -ForegroundColor Green
Write-Timestamp "Step 3 started"

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

Write-Timestamp "Step 3 complete"
Complete-CurrentStep

# ========== STEP 4: OPEN DIRECTORY ==========
Set-CurrentStep -StepNumber 4
Write-Log "STEP 4/4: Opening directory..."
Write-Host "`n[STEP 4/4] Opening output directory..." -ForegroundColor Green
Write-Timestamp "Step 4 started"
Write-Host "Opening: $finalOutputDir" -ForegroundColor Yellow
Start-Process explorer.exe -ArgumentList "`"$($finalOutputDir.TrimEnd('\'))`""
Write-Timestamp "Step 4 complete"
Complete-CurrentStep

# A clean exit code and a finished pipeline don't mean the rip is actually complete -
# corrupt/zero-byte tracks (caught in Step 1) or skipped/data-error tracks (caught
# during ripping) can both leave real gaps in the output. Reflect that in the banner
# itself rather than only in the FILE SUMMARY further down, so a walk-away rip that
# hit trouble doesn't read as an unqualified success at a glance.
$hasIncompleteTracks = $script:CorruptTracks.Count -gt 0 -or $script:SkippedTracks.Count -gt 0 -or $script:DataErrorTracks.Count -gt 0
Write-Host "`n========================================" -ForegroundColor Cyan
if ($hasIncompleteTracks) {
    Write-Host "COMPLETE WITH WARNINGS - see FILE SUMMARY below" -ForegroundColor Yellow
} else {
    Write-Host "COMPLETE!" -ForegroundColor Green
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Timestamp "Session complete"

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
if ($script:SkippedTracks.Count -gt 0) {
    Write-Host "  Skipped (unreadable): $($script:SkippedTracks.Count) track(s) (tracks $($script:SkippedTracks -join ', '))" -ForegroundColor Red
}
if ($script:DataErrorTracks.Count -gt 0) {
    Write-Host "  Data errors: $($script:DataErrorTracks.Count) track(s) marked _DATA_ERROR (tracks $($script:DataErrorTracks -join ', '))" -ForegroundColor Red
}
if ($script:CorruptTracks.Count -gt 0) {
    Write-Host "  Corrupt/zero-byte (not usable): $($script:CorruptTracks.Count) file(s) ($($script:CorruptTracks -join ', ')) - re-run this command with the disc still in the drive to resume" -ForegroundColor Red
}
Write-Host "  Log file: $($script:LogFile)" -ForegroundColor White
if ($CheckEbayPrice) {
    $ebayUrl = Get-EbaySoldListingsUrl -Artist $artist -Album $album
    Write-Host "  eBay sold prices (UK, BIN, Very Good+): $ebayUrl" -ForegroundColor White
    Write-Log "eBay sold-listings URL: $ebayUrl"
}
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
if ($script:SkippedTracks.Count -gt 0) {
    Write-Log "Skipped (unreadable): $($script:SkippedTracks.Count) track(s) (tracks $($script:SkippedTracks -join ', '))"
}
if ($script:DataErrorTracks.Count -gt 0) {
    Write-Log "Data errors: $($script:DataErrorTracks.Count) track(s) marked _DATA_ERROR (tracks $($script:DataErrorTracks -join ', '))"
}
if ($script:CorruptTracks.Count -gt 0) {
    Write-Log "Corrupt/zero-byte (not usable): $($script:CorruptTracks.Count) file(s) ($($script:CorruptTracks -join ', '))"
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
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    break
                }
            } catch [System.InvalidOperationException] {
                # Console input is redirected (e.g. running non-interactively) -
                # KeyAvailable throws every time in that case. Stop polling immediately
                # rather than re-throwing on every 200ms tick until the timeout naturally
                # elapses; the existing null-$key fallback below already auto-Yeses.
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
            # Quote paths: Start-Process joins -ArgumentList on spaces, so an
            # unquoted path with spaces is split into positional parameters.
            Start-Process powershell.exe -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", "`"$($searchScript.TrimEnd('\'))`"",
                "-Path", "`"$($finalOutputDir.TrimEnd('\'))`""
            ) -Wait -NoNewWindow
        }
    }

    # Drives Mp3tag's own UI to open its "Discogs Artist + Album" Tag Source dialog,
    # pre-filled from the loaded tags, then stops - deliberately does not click "Next >",
    # since the user wants to review/adjust the artist/album before the actual query goes
    # out. Mp3tag has no CLI switch for this (confirmed against the installed version's
    # full command-line changelog history - it only ever covers loading files on startup),
    # so this drives the real GUI via UI Automation + SendKeys instead.
    #
    # Best-effort throughout: any failure here just logs and returns, leaving Mp3tag open
    # for the user to drive manually - exactly the pre-existing behaviour if this function
    # didn't exist at all, so it can only add convenience, never break the fallback.
    #
    # FRAGILE BY NATURE, not oversight: Mp3tag's Tag Sources menu is not exposed via
    # standard Windows accessibility APIs (confirmed live - no MenuBar control, no
    # UIA-visible popup even while genuinely open), so the target item can only be reached
    # by position (4x Down from the top of the menu = 5th item = "Discogs Artist + Album"),
    # not by name. That position was verified against this machine's real, currently
    # installed Mp3tag and its currently configured Tag Sources list - reordering,
    # removing, or adding a Tag Source above it in Tools > Options > Tag Sources will move
    # it, and this will then land on the wrong item. There's no way to detect that
    # mismatch programmatically; if the automation seems to open the wrong search, this is
    # almost certainly why - recheck the position in the live menu and update
    # $mp3tagDiscogsMenuPosition below.
    function Invoke-Mp3tagDiscogsLookup {
        param([int]$TimeoutSeconds = 15)

        $mp3tagDiscogsMenuPosition = 4  # number of Down presses from the top of Tag Sources

        try {
            Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
            Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        } catch {
            Write-Log "  Mp3tag automation: could not load UI Automation assemblies - skipping ($_)"
            return
        }

        if (-not ("Win32Mp3tagAuto" -as [type])) {
            Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Mp3tagAuto {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
}
"@
        }

        try {
            # Mp3tag is single-instance: launching it can hand the file off to an existing
            # window under a completely different process ID than Start-Process returned,
            # or take a moment to appear either way. Poll for any top-level window whose
            # title starts with "Mp3tag" rather than trusting a specific launched PID.
            $uiaRoot = [System.Windows.Automation.AutomationElement]::RootElement
            $mp3tagWindow = $null
            $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($waitSw.Elapsed.TotalSeconds -lt $TimeoutSeconds -and -not $mp3tagWindow) {
                $windowCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)
                $topWindows = $uiaRoot.FindAll([System.Windows.Automation.TreeScope]::Children, $windowCondition)
                foreach ($w in $topWindows) {
                    if ($w.Current.Name -like "Mp3tag*") { $mp3tagWindow = $w; break }
                }
                if (-not $mp3tagWindow) { Start-Sleep -Milliseconds 300 }
            }
            $waitSw.Stop()

            if (-not $mp3tagWindow) {
                Write-Log "  Mp3tag automation: window did not appear within ${TimeoutSeconds}s - skipping"
                return
            }

            $hwnd = [IntPtr]$mp3tagWindow.Current.NativeWindowHandle

            # SetForegroundWindow alone is sometimes blocked by Windows' anti-focus-stealing
            # protection when called from a background process (confirmed live - it failed
            # outright on one attempt). AttachThreadInput to the currently-foreground
            # thread first is the standard documented workaround.
            $fgWnd = [Win32Mp3tagAuto]::GetForegroundWindow()
            $fgThread = [Win32Mp3tagAuto]::GetWindowThreadProcessId($fgWnd, [ref]0)
            $curThread = [Win32Mp3tagAuto]::GetCurrentThreadId()
            [Win32Mp3tagAuto]::AttachThreadInput($curThread, $fgThread, $true) | Out-Null
            [Win32Mp3tagAuto]::ShowWindow($hwnd, 9) | Out-Null  # SW_RESTORE, in case minimized
            [Win32Mp3tagAuto]::SetForegroundWindow($hwnd) | Out-Null
            [Win32Mp3tagAuto]::AttachThreadInput($curThread, $fgThread, $false) | Out-Null
            Start-Sleep -Milliseconds 500

            if ([Win32Mp3tagAuto]::GetForegroundWindow() -ne $hwnd) {
                Write-Log "  Mp3tag automation: could not bring window to foreground - skipping"
                return
            }

            # Select all tracks, open the Tag Sources menu via its Alt+S mnemonic, move down
            # to the target item, select it. Lands on Mp3tag's own "Search by" dialog,
            # pre-filled with Artist/Album from the loaded tags - stops there deliberately.
            [System.Windows.Forms.SendKeys]::SendWait("^a")
            Start-Sleep -Milliseconds 300
            [System.Windows.Forms.SendKeys]::SendWait("%s")
            Start-Sleep -Milliseconds 500
            [System.Windows.Forms.SendKeys]::SendWait(("{DOWN}" * $mp3tagDiscogsMenuPosition))
            Start-Sleep -Milliseconds 200
            [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")

            Write-Log "  Mp3tag automation: opened Discogs Artist + Album search dialog"
        } catch {
            Write-Log "  Mp3tag automation failed (non-fatal, Mp3tag left open for manual use): $_"
        }
    }

    # After search-metadata.ps1 (or if it was skipped), check if tracks are still untagged.
    # If so, offer to open Mp3tag for manual tagging.
    $stillUntagged = Get-ChildItem -Path $finalOutputDir -Filter "*.flac" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Unknown track|Unknown disc' -or $_.Name -match '^\d{2} - .+ - .+\.flac$' }
    if ($stillUntagged.Count -gt 0) {
        $mp3tagPath = "${env:ProgramFiles}\Mp3tag\Mp3tag.exe"
        if (-not (Test-Path $mp3tagPath)) {
            $mp3tagPath = "${env:ProgramFiles(x86)}\Mp3tag\Mp3tag.exe"
        }
        if (Test-Path $mp3tagPath) {
            Write-Host "`n  Tracks still need metadata. Open Mp3tag to tag manually? [Y/n] (auto-Yes in 30s): " -NoNewline -ForegroundColor Yellow
            $mp3Key = $null
            $mp3Sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($mp3Sw.Elapsed.TotalSeconds -lt 30) {
                try {
                    if ([Console]::KeyAvailable) {
                        $mp3Key = [Console]::ReadKey($true)
                        break
                    }
                } catch [System.InvalidOperationException] {
                    # Redirected console input - stop polling immediately instead of
                    # re-throwing every 200ms; existing null-$mp3Key fallback auto-Yeses.
                    break
                }
                Start-Sleep -Milliseconds 200
            }
            $mp3Sw.Stop()
            $mp3Choice = if ($mp3Key) { "$($mp3Key.KeyChar)".ToUpper() } else { $null }
            if ($null -eq $mp3Choice) { Write-Host "Y (auto)" -ForegroundColor Gray; $mp3Choice = "Y" }
            else { Write-Host $mp3Choice }
            if ($mp3Choice -ne "N") {
                Write-Host "  Opening Mp3tag..." -ForegroundColor Cyan
                Write-Log "Opening Mp3tag for manual tagging: $finalOutputDir"
                Start-Process $mp3tagPath -ArgumentList "/fp:`"$finalOutputDir`""
                Write-Host "  Opening Discogs Artist + Album search..." -ForegroundColor Cyan
                Invoke-Mp3tagDiscogsLookup
            }
        } else {
            Write-Host "`n  Tracks still need metadata. Consider opening Mp3tag to tag manually." -ForegroundColor Yellow
            Write-Host "  Mp3tag not found at default location." -ForegroundColor Gray
        }
    }
}

Enable-ConsoleClose
$host.UI.RawUI.WindowTitle = "$windowTitle - DONE"
if ($arResults.DbStatus -eq "found" -and $arResults.TracksVerified -ge 0 -and $arResults.TracksVerified -lt $arResults.TracksTotal) {
    $host.UI.RawUI.WindowTitle += " - AR PARTIAL"
}
if ($script:DataErrorTracks.Count -gt 0) {
    $host.UI.RawUI.WindowTitle += " - DATA ERRORS"
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
