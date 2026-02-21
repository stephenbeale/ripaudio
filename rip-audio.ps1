param(
    [Parameter(Mandatory=$true)]
    [string]$album,

    [Parameter()]
    [string]$artist = "",

    [Parameter()]
    [string]$Drive = "D:",

    [Parameter()]
    [string]$OutputDrive = "E:",

    [Parameter()]
    [string]$format = "flac",

    [Parameter()]
    [switch]$RequireMusicBrainz
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

# ========== CONFIGURATION ==========
# Normalize drive letters (add colon if missing)
$driveLetter = if ($Drive -match ':$') { $Drive } else { "${Drive}:" }
$outputDriveLetter = if ($OutputDrive -match ':$') { $OutputDrive } else { "${OutputDrive}:" }

# Validate format parameter
$validFormats = @("flac", "mp3", "opus", "aac", "wav", "alac")
if ($format -notin $validFormats) {
    Write-Host "ERROR: Invalid format '$format'. Valid formats: $($validFormats -join ', ')" -ForegroundColor Red
    exit 1
}

# Build output directory path
# Format: E:\Music\{Artist}\{Album}\ or E:\Music\{Album}\ if no artist
if ($artist) {
    $finalOutputDir = "$outputDriveLetter\Music\$artist\$album"
} else {
    $finalOutputDir = "$outputDriveLetter\Music\$album"
}

# ========== DRIVE CONFIRMATION ==========
# Show which drive will be used and confirm before proceeding
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Ready to rip: $album" -ForegroundColor White
if ($artist) {
    Write-Host "Artist: $artist" -ForegroundColor White
}
Write-Host "Format: $format" -ForegroundColor White
Write-Host "Using drive: $driveLetter" -ForegroundColor Yellow
Write-Host "Output drive: $outputDriveLetter" -ForegroundColor Yellow
Write-Host "Output path: $finalOutputDir" -ForegroundColor Yellow
if ($RequireMusicBrainz) {
    Write-Host "MusicBrainz: REQUIRED" -ForegroundColor Yellow
}
Write-Host "========================================" -ForegroundColor Cyan
$host.UI.RawUI.WindowTitle = "rip-audio - INPUT"
$response = Read-Host "Press Enter to continue, or Ctrl+C to abort"

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
Write-Log "Format: $format"
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

    # Open the relevant directory if it exists
    if (Test-Path $finalOutputDir) {
        Write-Host "`n--- OPENING DIRECTORY ---" -ForegroundColor Cyan
        Write-Host "Opening: $finalOutputDir" -ForegroundColor Yellow
        Start-Process explorer.exe -ArgumentList $finalOutputDir
    }

    Write-Host "`nLog file: $($script:LogFile)" -ForegroundColor Yellow
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "Please complete the remaining steps manually" -ForegroundColor Red
    Write-Host "========================================`n" -ForegroundColor Red
    Enable-ConsoleClose
    exit 1
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Audio CD Ripping Script (cyanrip)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Album: $album" -ForegroundColor White
if ($artist) {
    Write-Host "Artist: $artist" -ForegroundColor White
}
Write-Host "Format: $format" -ForegroundColor White
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
        Write-Log "User chose to continue with existing directory"
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

    if ($RequireMusicBrainz) {
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

# Add -N flag if user chose to skip MusicBrainz
if ($skipMusicBrainz) {
    $cyanripArgs += @("-N")
}

$cmdDisplay = "cyanrip -D `"$albumFolder`" -o $format -d $driveLetter -s 0$(if ($skipMusicBrainz) { ' -N' })"
Write-Host "Working directory: $parentDir" -ForegroundColor Gray
Write-Host "Command: $cmdDisplay" -ForegroundColor Gray
Write-Log "cyanrip working directory: $parentDir"
Write-Log "cyanrip command: $cmdDisplay"

# Execute cyanrip from the parent directory
Push-Location $parentDir
try {
    $cyanripOutput = & cyanrip @cyanripArgs 2>&1
    $cyanripExitCode = $LASTEXITCODE
    # Display output to console
    $cyanripOutput | ForEach-Object { Write-Host $_ }
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

        $validChoice = $false
        while (-not $validChoice) {
            $choice = Read-Host "Enter release number (1-$($releases.Count))"
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $releases.Count) {
                $validChoice = $true
            } else {
                Write-Host "Invalid choice. Please enter a number between 1 and $($releases.Count)" -ForegroundColor Yellow
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
            $cyanripOutput = & cyanrip @cyanripArgs 2>&1
            $cyanripExitCode = $LASTEXITCODE
            $cyanripOutput | ForEach-Object { Write-Host $_ }
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
                $cyanripOutput = & cyanrip @cyanripArgs 2>&1
                $cyanripExitCode = $LASTEXITCODE
                $cyanripOutput | ForEach-Object { Write-Host $_ }
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

            $cyanripArgs += @("-N")
            Push-Location $parentDir
            try {
                $cyanripOutput = & cyanrip @cyanripArgs 2>&1
                $cyanripExitCode = $LASTEXITCODE
                $cyanripOutput | ForEach-Object { Write-Host $_ }
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

# Check if disc not found in MusicBrainz - offer to continue without metadata
if ($cyanripExitCode -ne 0 -and $cyanripOutputText -match "Unable to find release info") {
    Write-Host "`nDisc not found in MusicBrainz database." -ForegroundColor Yellow

    if ($RequireMusicBrainz) {
        Stop-WithError -Step "STEP 1/4: cyanrip" -Message "Disc not found in MusicBrainz and -RequireMusicBrainz is set"
    }

    Write-Host "Track names will be generic (01 - Track 01, etc.)" -ForegroundColor Yellow
    Write-Host ""

    $continueChoice = Read-Host "Continue without metadata? (Y/n)"
    if ($continueChoice -eq "" -or $continueChoice -match "^[Yy]") {
        Write-Host "`nContinuing without MusicBrainz metadata..." -ForegroundColor Green
        Write-Log "User chose to continue without MusicBrainz metadata"
        $skipMusicBrainz = $true

        # Re-run cyanrip with -N flag to skip metadata requirement
        $cyanripArgs += @("-N")
        $cmdDisplay = "cyanrip -D `"$albumFolder`" -o $format -d $driveLetter -s 0 -N"
        Write-Host "Command: $cmdDisplay" -ForegroundColor Gray
        Write-Log "cyanrip command (no metadata): $cmdDisplay"

        Push-Location $parentDir
        try {
            $cyanripOutput = & cyanrip @cyanripArgs 2>&1
            $cyanripExitCode = $LASTEXITCODE
            $cyanripOutput | ForEach-Object { Write-Host $_ }
        } catch {
            Pop-Location
            Stop-WithError -Step "STEP 1/4: cyanrip" -Message "Failed to execute cyanrip: $_"
        }
        Pop-Location

        $cyanripOutputText = $cyanripOutput -join "`n"
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
    # Tracks have generic names (MusicBrainz skipped or returned no useful data) - rename using script params
    Write-Host "`nRenaming tracks with disc details..." -ForegroundColor Yellow

    $namingArtist = if ($artist) { $artist } else { "Unknown Artist" }
    $namingAlbum = $album

    foreach ($track in ($rippedTracks | Sort-Object Name)) {
        # Extract track number from filename
        if ($track.BaseName -match '^(\d{2})') {
            $trackNum = $Matches[1]
            $newName = "$trackNum - $namingArtist - $namingAlbum$($track.Extension)"

            # Sanitize filename (remove invalid characters)
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
        $tagArtist = if ($artist) { $artist } else { "Unknown Artist" }
        $tagAlbum = $album
        $totalTracks = $rippedTracks.Count

        foreach ($track in $rippedTracks) {
            # Extract track number from filename
            $trackNum = 1
            if ($track.BaseName -match '^(\d{2})') {
                $trackNum = [int]$Matches[1]
            }

            # Build track title: use existing title if present, otherwise "Track ##"
            # First check if track already has a meaningful title
            $existingTitle = $null
            try {
                $existingTags = & metaflac --show-tag=TITLE $track.FullName 2>$null
                if ($existingTags -and $existingTags -notmatch "Track\s*\d+") {
                    $existingTitle = ($existingTags -split '=', 2)[1]
                }
            } catch {}

            $trackTitle = if ($existingTitle) { $existingTitle } else { "Track $("{0:D2}" -f $trackNum)" }

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

# ========== STEP 2: VERIFY OUTPUT ==========
Set-CurrentStep -StepNumber 2
Write-Log "STEP 2/4: Verifying output..."
Write-Host "`n[STEP 2/4] Verifying output..." -ForegroundColor Green

# Check for ripped files based on format
$fileExtension = switch ($format) {
    "flac" { "*.flac" }
    "mp3" { "*.mp3" }
    "opus" { "*.opus" }
    "aac" { "*.m4a" }
    "wav" { "*.wav" }
    "alac" { "*.m4a" }
    default { "*.*" }
}

$rippedFiles = Get-ChildItem -Path $finalOutputDir -Filter $fileExtension -Recurse -ErrorAction SilentlyContinue
if ($null -eq $rippedFiles -or $rippedFiles.Count -eq 0) {
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
Write-Host "Format: $format" -ForegroundColor White
Write-Host "Final location: $finalOutputDir" -ForegroundColor White

# Show completed steps
Show-StepsSummary

# File summary
Write-Host "`n--- FILE SUMMARY ---" -ForegroundColor Cyan
Write-Host "  Total tracks: $($rippedFiles.Count)" -ForegroundColor White
Write-Host "  Total size: $totalSizeMB MB" -ForegroundColor White
$coverArtStatus = if ($script:CoverArtDownloaded) { "Yes" } else { "No" }
Write-Host "  Cover art: $coverArtStatus" -ForegroundColor White
Write-Host "  Log file: $($script:LogFile)" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Log "========== RIP SESSION COMPLETE =========="
Write-Log "Final location: $finalOutputDir"
Write-Log "Total tracks: $($rippedFiles.Count)"
Write-Log "Total size: $totalSizeMB MB"

Enable-ConsoleClose
$host.UI.RawUI.WindowTitle = "$windowTitle - DONE"
