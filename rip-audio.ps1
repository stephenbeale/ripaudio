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
    [string]$format = "flac"
)

# ========== STEP TRACKING ==========
# Define the 3 processing steps
$script:AllSteps = @(
    @{ Number = 1; Name = "cyanrip rip"; Description = "Rip audio CD to audio files" }
    @{ Number = 2; Name = "Verify output"; Description = "Verify ripped files exist" }
    @{ Number = 3; Name = "Open directory"; Description = "Open output folder" }
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
Write-Log "STEP 1/3: Starting cyanrip..."
Write-Host "[STEP 1/3] Starting cyanrip..." -ForegroundColor Green

# Check if destination drive is ready before attempting to create directories
Write-Host "Checking destination drive..." -ForegroundColor Yellow
$driveCheck = Test-DriveReady -Path $finalOutputDir
if (-not $driveCheck.Ready) {
    Stop-WithError -Step "STEP 1/3: Drive check" -Message $driveCheck.Message
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

$cmdDisplay = "cyanrip -D `"$albumFolder`" -o $format -d $driveLetter -s 0"
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
    Stop-WithError -Step "STEP 1/3: cyanrip" -Message "Failed to execute cyanrip: $_"
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
            Stop-WithError -Step "STEP 1/3: cyanrip" -Message "Failed to execute cyanrip: $_"
        }
        Pop-Location

        $cyanripOutputText = $cyanripOutput -join "`n"
    }
}

# Check if disc not found in MusicBrainz - offer to continue without metadata
if ($cyanripExitCode -ne 0 -and $cyanripOutputText -match "Unable to find release info") {
    Write-Host "`nDisc not found in MusicBrainz database." -ForegroundColor Yellow
    Write-Host "Track names will be generic (01 - Track 01, etc.)" -ForegroundColor Yellow
    Write-Host ""

    $continueChoice = Read-Host "Continue without metadata? (Y/n)"
    if ($continueChoice -eq "" -or $continueChoice -match "^[Yy]") {
        Write-Host "`nContinuing without MusicBrainz metadata..." -ForegroundColor Green
        Write-Log "User chose to continue without MusicBrainz metadata"

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
            Stop-WithError -Step "STEP 1/3: cyanrip" -Message "Failed to execute cyanrip: $_"
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
    Stop-WithError -Step "STEP 1/3: cyanrip" -Message $errorMessage
}

Write-Host "`ncyanrip complete!" -ForegroundColor Green
Write-Log "STEP 1/3: cyanrip complete"
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
Write-Log "STEP 2/3: Verifying output..."
Write-Host "`n[STEP 2/3] Verifying output..." -ForegroundColor Green

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
        Stop-WithError -Step "STEP 2/3: Verify output" -Message "No audio files found in $finalOutputDir"
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
Write-Log "STEP 2/3: Verification complete - $($rippedFiles.Count) file(s)"

# ========== STEP 3: OPEN DIRECTORY ==========
Set-CurrentStep -StepNumber 3
Write-Log "STEP 3/3: Opening directory..."
Write-Host "`n[STEP 3/3] Opening output directory..." -ForegroundColor Green
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
Write-Host "  Log file: $($script:LogFile)" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Log "========== RIP SESSION COMPLETE =========="
Write-Log "Final location: $finalOutputDir"
Write-Log "Total tracks: $($rippedFiles.Count)"
Write-Log "Total size: $totalSizeMB MB"

Enable-ConsoleClose
$host.UI.RawUI.WindowTitle = "$windowTitle - DONE"
