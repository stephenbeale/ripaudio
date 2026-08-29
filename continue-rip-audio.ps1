param(
    [Parameter()]
    [string]$Album = "",

    [Parameter()]
    [string]$Artist = "",

    # Which step to resume from. Accepts a number (1-4) or a name
    # (rip, verify, coverart, open). Omit it to pick from a menu.
    [Parameter()]
    [Alias("Step")]
    [string]$FromStep = "",

    # Rip step only: skip the automatic missing/invalid-track detection and rip
    # from this track number through the end of the disc, trusting the caller's
    # own knowledge of where a previous attempt broke (e.g. a crash log naming
    # the track) over the script's own file-scan. Tracks before this number are
    # assumed already present and are left untouched.
    [Parameter()]
    [int]$FromTrack = 0,

    [Parameter()]
    [string]$Drive = "",

    [Parameter()]
    [string]$OutputDrive = "",

    [Parameter()]
    [string]$format = "flac",

    [Parameter()]
    [int]$Quality = 0,

    [Parameter()]
    [ValidateRange(0, 3)]
    [int]$ParanoiaLevel = -1,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$Retries = -1,

    # Skip the "press Enter to start" confirmation.
    [Parameter()]
    [switch]$Yes,

    [Parameter()]
    [switch]$Help
)

# ========================================================================
# continue-rip-audio.ps1 - resume an interrupted rip-audio.ps1 run
#
# Mirrors the step-based resume pattern of ripdisc's continue-rip.ps1, with
# one structural difference worth knowing up front: ripdisc's Step 1
# (MakeMKV) genuinely cannot be resumed without the disc, so its continue
# script never touches Step 1 at all - it only ever resumes steps 2-4.
# Here, Step 1 (the cyanrip rip itself) CAN be partially resumed - cyanrip's
# own -l flag rips just a specific list of missing track numbers - so this
# script's "rip" step still needs the disc back in the drive, but it is
# genuinely resumable, unlike ripdisc's equivalent.
#
# Deliberately NOT ported from rip-audio.ps1 (all of this only matters for
# DISCOVERING metadata on a fresh disc read, not for continuing an album
# this script already knows the identity of from its existing output
# folder): multi-release MusicBrainz disambiguation, CDDB/Discogs fallback,
# generic-name fallback, -Queue/-ProcessQueue, -RequireMusicBrainz, busy-
# drive detection (this script does a single-check drive validation, not
# rip-audio.ps1's live-process busy scan), AccurateRip reporting, the
# search-metadata.ps1 handoff, and the Mp3tag fallback prompt. All of these
# are real gaps versus rip-audio.ps1's own inline resume prompt - if any of
# them matter for a given album, use rip-audio.ps1 itself instead.
# ========================================================================

# Ensure cyanrip/metaflac output is decoded as UTF-8 (PS5.1 defaults to system locale)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Load System.Web for URL encoding (used in cover art search)
Add-Type -AssemblyName System.Web

# ========== STEP TRACKING ==========
$script:AllSteps = @(
    @{ Number = 1; Key = "rip";      Name = "cyanrip rip";  Description = "Rip missing/invalid tracks";        Needs = "the disc back in the drive"; Resumable = $true }
    @{ Number = 2; Key = "verify";   Name = "Verify output"; Description = "Verify ripped files exist";         Needs = "audio files in the output folder"; Resumable = $true }
    @{ Number = 3; Key = "coverart"; Name = "Cover art";     Description = "Download and embed album cover art"; Needs = "at least one audio file"; Resumable = $true }
    @{ Number = 4; Key = "open";     Name = "Open directory"; Description = "Open the output folder";           Needs = "the output folder to exist"; Resumable = $true }
)
$script:CompletedSteps = @()
$script:CurrentStep = $null

function Get-Step {
    param([int]$Number)
    return $script:AllSteps | Where-Object { $_.Number -eq $Number }
}

function Get-StepByKey {
    param([string]$Key)
    return $script:AllSteps | Where-Object { $_.Key -eq $Key }
}

function Resolve-StepKey {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    switch -Regex ($Value.Trim()) {
        '^(1|rip|cyanrip)$'                          { return "rip" }
        '^(2|verify|check)$'                         { return "verify" }
        '^(3|coverart|cover|art)$'                   { return "coverart" }
        '^(4|open|openfolder|folder|explorer)$'       { return "open" }
        default                                       { return $null }
    }
}

function Set-CurrentStep {
    param([int]$StepNumber)
    $script:CurrentStep = Get-Step -Number $StepNumber
}

function Complete-CurrentStep {
    if ($script:CurrentStep) {
        $script:CompletedSteps += $script:CurrentStep
        Write-Host ("`n[DONE] Step {0}/4 - {1}" -f $script:CurrentStep.Number, $script:CurrentStep.Name) -ForegroundColor Green
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
            # Sort-Object with a bare property name silently sorts DESCENDING on PS 5.1
            # when the pipeline objects are [hashtable] (as $script:AllSteps entries
            # are) rather than [PSCustomObject] - it doesn't resolve the "property" via
            # the same adapter dot-notation member access uses. A script block
            # comparator reads the value directly and sorts correctly either way.
            # (Same fix ripdisc's continue-rip.ps1 needed for the identical bug.)
            $next = @($remaining | Sort-Object { $_.Number })[0]
            $albumArg = "-Album `"$Album`""
            $artistArg = if ($Artist) { " -Artist `"$Artist`"" } else { "" }
            Write-Host "`n  To pick up from here: .\continue-rip-audio.ps1 $albumArg$artistArg -FromStep $($next.Number)" -ForegroundColor Cyan
        }
    }
}

# ========== USAGE / HELP ==========
function Show-Usage {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " continue-rip-audio.ps1 - resume a failed rip-audio.ps1 run" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "`nPicks up an interrupted album rip at any of its 4 steps." -ForegroundColor White
    Write-Host "Run with -Album only to be walked through the rest." -ForegroundColor White

    Write-Host "`n--- STEPS ---" -ForegroundColor Cyan
    foreach ($step in $script:AllSteps) {
        Write-Host ("  {0} / {1,-10} {2,-14}  {3}" -f $step.Number, $step.Key, $step.Name, $step.Description) -ForegroundColor White
        Write-Host ("      needs {0}" -f $step.Needs) -ForegroundColor Gray
    }

    Write-Host "`n--- PARAMETERS ---" -ForegroundColor Cyan
    Write-Host "  -Album <name>        Album name, matching the original rip-audio.ps1 run (required)" -ForegroundColor White
    Write-Host "  -Artist <name>       Artist name, if the original rip had one" -ForegroundColor White
    Write-Host "  -FromStep <1-4>      Step to resume from (number or name)" -ForegroundColor White
    Write-Host "  -FromTrack <N>       Skip auto-detection and rip from track N through the end," -ForegroundColor White
    Write-Host "                       trusting you over the file scan (e.g. a crash log already" -ForegroundColor White
    Write-Host "                       named the exact failed track). Implies -FromStep rip -" -ForegroundColor White
    Write-Host "                       no need to pass both." -ForegroundColor White
    Write-Host "  -Drive <letter>      CD drive letter (only needed for the rip step)" -ForegroundColor White
    Write-Host "  -OutputDrive <X>     Output drive letter (default: system drive, or prompted)" -ForegroundColor White
    Write-Host "  -format <fmt>        Output format, must match the original rip (default flac)" -ForegroundColor White
    Write-Host "  -Quality <kbps>      Bitrate for lossy formats (32-320)" -ForegroundColor White
    Write-Host "  -ParanoiaLevel <0-3> cyanrip paranoia level" -ForegroundColor White
    Write-Host "  -Retries <1-100>     cyanrip retry count" -ForegroundColor White
    Write-Host "  -Yes                 Skip the confirmation prompt" -ForegroundColor White
    Write-Host "  -Help                Show this text" -ForegroundColor White

    Write-Host "`n--- EXAMPLES ---" -ForegroundColor Cyan
    Write-Host "  .\continue-rip-audio.ps1 -Album `"Welcome to Jamrock`" -Artist `"Damian Marley`"" -ForegroundColor Yellow
    Write-Host "      Interactive - asks which step to resume from" -ForegroundColor Gray
    Write-Host "  .\continue-rip-audio.ps1 -Album `"Destination Anywhere`" -Artist `"Jon Bon Jovi`" -FromStep rip -Drive H" -ForegroundColor Yellow
    Write-Host "      Resume ripping missing/corrupt tracks only (auto-detected)" -ForegroundColor Gray
    Write-Host "  .\continue-rip-audio.ps1 -Album `"Destination Anywhere`" -Artist `"Jon Bon Jovi`" -FromTrack 9 -Drive H" -ForegroundColor Yellow
    Write-Host "      Skip auto-detection - rip track 9 through the end directly (-FromTrack implies -FromStep rip)" -ForegroundColor Gray
    Write-Host "  .\continue-rip-audio.ps1 -Album `"Connected`" -Artist `"Stereo MC's`" -FromStep coverart" -ForegroundColor Yellow
    Write-Host "      Tracks are all there - just fetch and embed cover art" -ForegroundColor Gray
    Write-Host ""
}

if ($Help) {
    Show-Usage
    exit 0
}

# ========== HELPER FUNCTIONS (ported from rip-audio.ps1 - keep in sync) ==========
function Test-TrackIntegrity {
    param([string]$FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    if ($ext -eq ".flac") {
        # Synced with rip-audio.ps1's fix (PR #147): metaflac has no --test option at all
        # (it only edits/reads metadata, it never decodes the audio stream) - "metaflac
        # --test" always printed "unrecognized option" and exited 1 regardless of file
        # validity. "flac --test" (the decoder, bundled in the same install) is the tool
        # that actually verifies a FLAC file decodes cleanly.
        $flacExe = Get-Command flac -ErrorAction SilentlyContinue
        if ($flacExe) {
            & flac --test --totally-silent $FilePath 2>$null
            return $LASTEXITCODE -eq 0
        }
    }
    return (Get-Item $FilePath).Length -gt 10240
}

function Get-DiscTrackCount {
    param([string]$OutputDir, [string]$DriveLetter, [switch]$Fresh)
    # Synced with rip-audio.ps1's -Fresh switch (PR #145): skips the cue-file shortcut
    # and queries the disc live. A cue file written during an attempt that later crashed
    # or dropped connection can carry a track count corrupted by that same failure, so
    # callers recovering from one (e.g. -FromTrack below) should not trust it.
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
    # -N (skip MusicBrainz) is deliberate - this function only ever needs the disc's own
    # TOC track count, never metadata, so it shouldn't depend on MusicBrainz being
    # reachable. Synced with the same fix in rip-audio.ps1's copy of this function.
    $output = & cyanrip -I -d $DriveLetter -s 0 -N 2>&1
    $outputText = $output -join "`n"
    if ($outputText -match 'Disc tracks:\s+(\d+)') {
        return [int]$Matches[1]
    }
    if ($outputText -match "Multiple releases found") {
        $output2 = & cyanrip -I -d $DriveLetter -s 0 -R 1 -N 2>&1
        $outputText2 = $output2 -join "`n"
        if ($outputText2 -match 'Disc tracks:\s+(\d+)') {
            return [int]$Matches[1]
        }
    }
    return $null
}

function Test-DriveReady {
    param([string]$Path)
    $driveLetter = [System.IO.Path]::GetPathRoot($Path)
    if (-not $driveLetter) {
        return @{ Ready = $false; Drive = "Unknown"; Message = "Could not determine drive letter from path: $Path" }
    }
    $driveDisplay = $driveLetter.TrimEnd('\')
    try {
        $drive = Get-PSDrive -Name $driveDisplay.TrimEnd(':') -ErrorAction Stop
        if ($drive) {
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
        Add-Content -Path $script:LogFile -Value "[$timestamp] $Message"
    }
}

function Show-QuestionHint {
    Write-Host ""
    Write-Host "[ A few more questions to answer... ]" -ForegroundColor Yellow
}

function Write-Timestamp {
    param([string]$Label)
    $ts = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
    Write-Host "  [$ts] $Label" -ForegroundColor DarkGray
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

# ========== CLOSE BUTTON PROTECTION ==========
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
function Disable-ConsoleClose { [Win32.ConsoleCloseProtection]::EnableMenuItem($script:ConsoleSystemMenu, 0xF060, 0x00000001) | Out-Null }
function Enable-ConsoleClose { [Win32.ConsoleCloseProtection]::EnableMenuItem($script:ConsoleSystemMenu, 0xF060, 0x00000000) | Out-Null }

# ========== VALIDATE ALBUM ==========
if (-not $Album) {
    Write-Host "`nERROR: -Album is required." -ForegroundColor Red
    Write-Host "Run with -Help for usage, or supply the same -Album (and -Artist, if any) used for the original rip-audio.ps1 run." -ForegroundColor Yellow
    exit 1
}

# ========== RESOLVE STEP ==========
# -FromTrack only ever applies to the rip step, so it implies -FromStep rip when
# -FromStep is left unspecified - otherwise every -FromTrack invocation would need
# to redundantly spell out both, and omitting -FromStep would drop into the
# interactive step-picker menu instead of just doing the one thing -FromTrack asked for.
if ($FromTrack -gt 0 -and [string]::IsNullOrWhiteSpace($FromStep)) {
    $FromStep = "rip"
    Write-Host "`n-FromTrack $FromTrack given with no -FromStep - defaulting to -FromStep rip." -ForegroundColor Gray
}

$stepKey = Resolve-StepKey $FromStep
if ([string]::IsNullOrWhiteSpace($FromStep)) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host " CONTINUE RIP AUDIO - resume an interrupted rip" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Run with -Help to see all parameters and examples." -ForegroundColor Gray
    Write-Host "`n--- WHICH STEP ---" -ForegroundColor Cyan
    foreach ($step in $script:AllSteps) {
        Write-Host ("  [{0}] {1,-14} {2}" -f $step.Number, $step.Name, $step.Description) -ForegroundColor White
        Write-Host ("      needs {0}" -f $step.Needs) -ForegroundColor Gray
    }
    Write-Host "`nEverything from the chosen step onwards will run." -ForegroundColor Gray
    while (-not $stepKey) {
        $answer = Read-Host "`nContinue from step [1]"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = "1" }
        $stepKey = Resolve-StepKey $answer
        if (-not $stepKey) {
            Write-Host "Please enter 1, 2, 3 or 4 (or rip / verify / coverart / open)." -ForegroundColor Red
        }
    }
} elseif (-not $stepKey) {
    Write-Host "`n'$FromStep' is not a step this script recognises. Run with -Help to see valid values." -ForegroundColor Red
    exit 1
}

$startStep = Get-StepByKey -Key $stepKey
$StartFromStepNumber = $startStep.Number

if ($FromTrack -gt 0 -and $StartFromStepNumber -ne 1) {
    Write-Host "`nNote: -FromTrack $FromTrack only applies to the rip step, but starting at step $StartFromStepNumber ($($startStep.Name)) - it will be ignored." -ForegroundColor Yellow
}

# Mark steps before the starting point as "skipped/assumed complete"
for ($i = 1; $i -lt $StartFromStepNumber; $i++) {
    $script:CompletedSteps += Get-Step -Number $i
}

# ========== BUILD PATHS (mirrors rip-audio.ps1's own path construction) ==========
$safeAlbum = (($Album -replace '[\u2013\u2014]', '-') -replace '[\\/:*?"<>|.-]', '') -replace '\s+', ' '
$safeAlbum = $safeAlbum.Trim()
$safeArtist = if ($Artist) { ((($Artist -replace '[\u2013\u2014]', '-') -replace '[\\/:*?"<>|.-]', '') -replace '\s+', ' ').Trim() } else { "" }

# ========== OUTPUT DRIVE (same prompt-then-validate pattern as rip-audio.ps1) ==========
if (-not $OutputDrive) {
    $defaultOutputDrive = $env:SystemDrive
    Show-QuestionHint
    $outputDriveInput = Read-Host "Output drive (Enter for default: $defaultOutputDrive)"
    $OutputDrive = if ($outputDriveInput) { $outputDriveInput.Trim() } else { $defaultOutputDrive }
}
$outputDriveLetter = if ($OutputDrive -match ':$') { $OutputDrive } else { "${OutputDrive}:" }
$outputDriveCheck = Test-DriveReady -Path "$outputDriveLetter\"
while (-not $outputDriveCheck.Ready) {
    Write-Host "ERROR: $($outputDriveCheck.Message)" -ForegroundColor Red
    Show-QuestionHint
    $outputDriveInput = Read-Host "Enter a different output drive (or Ctrl+C to abort)"
    if (-not $outputDriveInput) { continue }
    $candidate = $outputDriveInput.Trim()
    $outputDriveLetter = if ($candidate -match ':$') { $candidate } else { "${candidate}:" }
    $outputDriveCheck = Test-DriveReady -Path "$outputDriveLetter\"
}

if ($safeArtist) {
    $finalOutputDir = "$outputDriveLetter\Music\$safeArtist\$safeAlbum"
} else {
    $finalOutputDir = "$outputDriveLetter\Music\$safeAlbum"
}

# ========== LOGGING SETUP ==========
$logDir = "C:\Music\logs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$safeAlbumForLog = $Album -replace '[\\/:*?"<>|]', '_'
$safeArtistForLog = if ($Artist) { $Artist -replace '[\\/:*?"<>|]', '_' } else { "" }
$logNamePrefix = if ($safeArtistForLog) { "${safeArtistForLog}_${safeAlbumForLog}" } else { $safeAlbumForLog }
$script:LogFile = Join-Path $logDir "${logNamePrefix}_continue_${logTimestamp}.log"

Write-Log "========== CONTINUE SESSION STARTED =========="
Write-Log "Album: $Album"
if ($Artist) { Write-Log "Artist: $Artist" }
Write-Log "Continue from: Step $StartFromStepNumber ($stepKey)"
Write-Log "Output drive: $outputDriveLetter"
Write-Log "Final output: $finalOutputDir"
Write-Log "Log file: $($script:LogFile)"

function Get-AlbumSummary {
    if ($Artist) { return "Album: $Album by $Artist" } else { return "Album: $Album" }
}

function Stop-WithError {
    param([string]$Step, [string]$Message)
    $host.UI.RawUI.WindowTitle = "$($host.UI.RawUI.WindowTitle) - ERROR"
    Write-Log "========== ERROR =========="
    Write-Log "Failed at: $Step"
    Write-Log "Message: $Message"

    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "FAILED!" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "`nProcessing: $(Get-AlbumSummary)" -ForegroundColor White
    Write-Host "`nError at: $Step" -ForegroundColor Red
    Write-Host "Message: $Message" -ForegroundColor Red

    Show-StepsSummary -ShowRemaining

    if (Test-Path $finalOutputDir) {
        Write-Host "`n--- OPENING DIRECTORY ---" -ForegroundColor Cyan
        Write-Host "Opening: $finalOutputDir" -ForegroundColor Yellow
        Start-Process explorer.exe -ArgumentList "`"$($finalOutputDir.TrimEnd('\'))`""
    }

    Write-Host "`nLog file: $($script:LogFile)" -ForegroundColor White
    Write-Host "========================================`n" -ForegroundColor Red
    Enable-ConsoleClose
    exit 1
}

# ========== WINDOW TITLE ==========
$windowTitle = if ($Artist) { "$Artist - $Album" } else { "$Album" }
$windowTitle += " - CONTINUE"
$host.UI.RawUI.WindowTitle = $windowTitle

# ========== PREREQUISITE CHECKS ==========
# Writes a clear "cannot start here" message and, where possible, points at a
# more sensible step instead. Returns $false so the caller can offer another step.
function Write-PrerequisiteFailure {
    param([int]$StepNumber, [string]$Message, [string[]]$Hints = @())
    $step = Get-Step -Number $StepNumber
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host " CANNOT START AT STEP $StepNumber - $($step.Name)" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host " $Message" -ForegroundColor Red
    Write-Host " This step needs $($step.Needs)." -ForegroundColor Yellow
    foreach ($hint in $Hints) { Write-Host " $hint" -ForegroundColor Cyan }
    Write-Host "========================================" -ForegroundColor Red
    return $false
}

$formatList = $format -split ',' | ForEach-Object { $_.Trim() }
$formatExtMap = @{ "flac" = "*.flac"; "mp3" = "*.mp3"; "opus" = "*.opus"; "aac" = "*.m4a"; "wav" = "*.wav"; "alac" = "*.m4a" }

function Get-ExistingAudioFiles {
    $files = @()
    foreach ($fmt in $formatList) {
        $ext = $formatExtMap[$fmt]
        if ($ext) {
            $found = @(Get-ChildItem -Path $finalOutputDir -Filter $ext -ErrorAction SilentlyContinue)
            if ($found.Count -gt 0) { $files += $found }
        }
    }
    if ($files.Count -eq 0) {
        $files = @(Get-ChildItem -Path $finalOutputDir -Include "*.flac","*.mp3","*.opus","*.m4a","*.wav","*.aac" -Recurse -ErrorAction SilentlyContinue)
    }
    return $files
}

function Test-StepPrerequisites {
    param([int]$StepNumber)

    if ($StepNumber -eq 1) {
        if (-not (Test-Path $finalOutputDir)) {
            Write-Host "Output folder does not exist yet: $finalOutputDir" -ForegroundColor Yellow
            Write-Host "Will be created; treating this as ripping from scratch." -ForegroundColor Yellow
            return $true
        }
        Write-Host "OK - output folder exists: $finalOutputDir" -ForegroundColor Green
        return $true
    }

    if ($StepNumber -eq 2 -or $StepNumber -eq 3) {
        $hints = @()
        if (!(Test-Path $finalOutputDir)) {
            return (Write-PrerequisiteFailure -StepNumber $StepNumber -Message "The output folder does not exist: $finalOutputDir" -Hints @("Did you mean step 1 (rip)?"))
        }
        $existing = Get-ExistingAudioFiles
        if ($existing.Count -eq 0) {
            return (Write-PrerequisiteFailure -StepNumber $StepNumber -Message "No audio files in: $finalOutputDir" -Hints @("Did you mean step 1 (rip)?"))
        }
        Write-Host "OK - found $($existing.Count) audio file(s):" -ForegroundColor Green
        foreach ($f in $existing) {
            Write-Host "  - $($f.Name) ($([math]::Round($f.Length / 1MB, 2)) MB)" -ForegroundColor Gray
        }
        return $true
    }

    if ($StepNumber -eq 4) {
        if (!(Test-Path $finalOutputDir)) {
            return (Write-PrerequisiteFailure -StepNumber $StepNumber -Message "The output folder does not exist: $finalOutputDir")
        }
        Write-Host "OK - output folder exists: $finalOutputDir" -ForegroundColor Green
        return $true
    }

    return $false
}

# ========== CONFIRMATION ==========
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " CONTINUE RIP AUDIO" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host (" Album         : {0}" -f $Album) -ForegroundColor White
if ($Artist) { Write-Host (" Artist        : {0}" -f $Artist) -ForegroundColor White }
Write-Host (" Output path   : {0}" -f $finalOutputDir) -ForegroundColor White
Write-Host (" Output drive  : {0}" -f $outputDriveLetter) -ForegroundColor White
Write-Host ""

$validStart = $false
while (-not $validStart) {
    Write-Host ("--- Starting at step {0}: {1} ---" -f $StartFromStepNumber, $startStep.Name) -ForegroundColor Cyan
    $validStart = Test-StepPrerequisites -StepNumber $StartFromStepNumber
    if (-not $validStart) {
        Show-QuestionHint
        $answer = Read-Host "Try a different step (1-4), or Ctrl+C to abort"
        $newKey = Resolve-StepKey $answer
        if (-not $newKey) {
            Write-Host "Please enter 1, 2, 3 or 4 (or rip / verify / coverart / open)." -ForegroundColor Red
            continue
        }
        $script:CompletedSteps = @()
        $startStep = Get-StepByKey -Key $newKey
        $StartFromStepNumber = $startStep.Number
        for ($i = 1; $i -lt $StartFromStepNumber; $i++) { $script:CompletedSteps += Get-Step -Number $i }
    }
}
Write-Host "========================================" -ForegroundColor Cyan

if (-not $Yes) {
    $host.UI.RawUI.WindowTitle = "$windowTitle - INPUT"
    Show-QuestionHint
    Read-Host "Press Enter to continue, or Ctrl+C to abort" | Out-Null
    $host.UI.RawUI.WindowTitle = $windowTitle
}

Disable-ConsoleClose

# ========== STEP 1: RIP ==========
if ($StartFromStepNumber -le 1) {
    Set-CurrentStep -StepNumber 1
    Write-Log "STEP 1/4: Starting cyanrip resume..."
    Write-Host "`n[STEP 1/4] Resuming cyanrip rip..." -ForegroundColor Green
    Write-Timestamp "Step 1 started"

    # ========== DRIVE SELECTION ==========
    # Simplified relative to rip-audio.ps1's own drive discovery - no live busy-drive
    # scan (which reads running cyanrip process command lines). If two rips are run
    # concurrently against the same drive here, that collision is not detected.
    if (-not $Drive) {
        $opticalDrives = @(Get-CimInstance Win32_CDROMDrive -ErrorAction SilentlyContinue | Where-Object { $_.Drive })
        if ($opticalDrives.Count -eq 0) {
            Stop-WithError -Step "STEP 1/4: cyanrip" -Message "No optical drive detected. Use -Drive to specify the drive letter."
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
                    Write-Host "Invalid selection." -ForegroundColor Yellow
                }
            }
        }
    }
    $driveLetter = if ($Drive -match ':$') { $Drive } else { "${Drive}:" }

    # Destination drive readiness (re-checked here since time may have passed since
    # the earlier prompt, and this is the step that actually writes files).
    if (!(Test-Path $finalOutputDir)) { New-Item -ItemType Directory -Path $finalOutputDir -Force | Out-Null }
    $driveCheck = Test-DriveReady -Path $finalOutputDir
    if (-not $driveCheck.Ready) {
        Stop-WithError -Step "STEP 1/4: cyanrip" -Message $driveCheck.Message
    }

    # ========== DETERMINE WHAT'S MISSING ==========
    $existingAudioFiles = Get-ExistingAudioFiles
    $script:ResumeTrackList = $null
    $skipCyanripInvocation = $false
    if ($FromTrack -gt 0) {
        # -FromTrack: trust the caller's own knowledge of where a previous attempt broke
        # over the automatic missing/invalid-track scan below - e.g. rip-audio.ps1's own
        # "cyanrip crashed ... after track N" message already names the exact track, and
        # a crash or dropped connection can be the same failure that corrupted the cue
        # file/disc read the automatic scan would otherwise rely on. Tracks before this
        # number are assumed already present and are left untouched.
        Write-Host "Continuing from track $FromTrack as requested (-FromTrack) - re-querying the disc for its real total..." -ForegroundColor Yellow
        $totalTrackCount = Get-DiscTrackCount -OutputDir $finalOutputDir -DriveLetter $driveLetter -Fresh
        if (-not $totalTrackCount) {
            Stop-WithError -Step "STEP 1/4: cyanrip" -Message "Could not determine the disc's total track count (no cue file, and a live disc query returned nothing) - can't build a resume list from -FromTrack $FromTrack. Check the disc/drive and try again, or omit -FromTrack to fall back to file-based detection."
        }
        if ($FromTrack -gt $totalTrackCount) {
            Stop-WithError -Step "STEP 1/4: cyanrip" -Message "-FromTrack $FromTrack is past the disc's own track count ($totalTrackCount)."
        }
        $remainingTracks = @($FromTrack..$totalTrackCount)
        $script:ResumeTrackList = ($remainingTracks | ForEach-Object { $_.ToString() }) -join ","
        if ($FromTrack -gt 1) {
            Write-Host "Will rip tracks $FromTrack-$totalTrackCount ($($remainingTracks.Count) track(s)); tracks 1-$($FromTrack - 1) are assumed already present and will be left untouched." -ForegroundColor Yellow
        } else {
            Write-Host "Will rip tracks 1-$totalTrackCount ($($remainingTracks.Count) track(s)) - the whole disc, since -FromTrack 1 leaves no preceding tracks to keep." -ForegroundColor Yellow
        }
        Write-Log "FromTrack override: ripping tracks $($script:ResumeTrackList) of $totalTrackCount (bypassed auto-detection)"

        # Heads-up only, not a block: -FromTrack is an explicit instruction and wins
        # either way, but flag a mismatch against what's actually on disk so a wrong
        # track number is caught before a long rip runs rather than after.
        # Guarded on -gt 1 because PowerShell ranges descend: "1..0" yields @(1,0), not
        # an empty set, so -FromTrack 1 would otherwise "expect" tracks 1 and 0 and warn
        # about both on what is a perfectly valid rip-the-whole-disc invocation.
        $precedingExpected = if ($FromTrack -gt 1) { @(1..($FromTrack - 1)) } else { @() }
        if ($precedingExpected.Count -gt 0) {
            $precedingFound = @()
            foreach ($af in $existingAudioFiles) {
                $trackNum = $null
                if ($af.BaseName -match '^(\d+)\.(\d+)\s*-') { $trackNum = [int]$Matches[2] }
                elseif ($af.BaseName -match '^(\d+)\s*-') { $trackNum = [int]$Matches[1] }
                if ($trackNum -and (Test-TrackIntegrity -FilePath $af.FullName)) { $precedingFound += $trackNum }
            }
            $precedingMissing = @($precedingExpected | Where-Object { $_ -notin $precedingFound })
            if ($precedingMissing.Count -gt 0) {
                $precedingMissingList = ($precedingMissing | ForEach-Object { $_.ToString() }) -join ","
                Write-Host "WARNING: -FromTrack $FromTrack assumes tracks 1-$($FromTrack - 1) are already valid, but track(s) $precedingMissingList were not found (or failed integrity check) in $finalOutputDir. Continuing anyway since -FromTrack was explicit - double-check the final track count once ripping finishes." -ForegroundColor Red
                Write-Log "FromTrack warning: expected preceding track(s) $precedingMissingList not found/valid in $finalOutputDir"
            }
        }
    } elseif ($existingAudioFiles.Count -gt 0) {
        Write-Host "Checking existing tracks against the disc..." -ForegroundColor Yellow
        $totalTrackCount = Get-DiscTrackCount -OutputDir $finalOutputDir -DriveLetter $driveLetter
        if ($totalTrackCount) {
            $validTracks = @()
            $invalidTracks = @()
            foreach ($af in $existingAudioFiles) {
                $trackNum = $null
                if ($af.BaseName -match '^(\d+)\.(\d+)\s*-') { $trackNum = [int]$Matches[2] }
                elseif ($af.BaseName -match '^(\d+)\s*-') { $trackNum = [int]$Matches[1] }
                if ($trackNum) {
                    if (Test-TrackIntegrity -FilePath $af.FullName) { $validTracks += $trackNum } else { $invalidTracks += $trackNum }
                }
            }
            $validTracks = $validTracks | Sort-Object -Unique
            $missingTracks = @((1..$totalTrackCount) | Where-Object { $_ -notin $validTracks })
            if ($invalidTracks.Count -gt 0) { $missingTracks = @($missingTracks + $invalidTracks | Sort-Object -Unique) }

            if ($missingTracks.Count -eq 0) {
                Write-Host "All $totalTrackCount tracks already valid - nothing to rip." -ForegroundColor Green
                Write-Log "All $totalTrackCount tracks already valid - skipping cyanrip"
                $skipCyanripInvocation = $true
            } else {
                $missingList = ($missingTracks | ForEach-Object { $_.ToString() }) -join ","
                Write-Host "Valid: $($validTracks.Count)/$totalTrackCount tracks. Missing/invalid: $missingList" -ForegroundColor Yellow
                Write-Log "Resuming: ripping tracks $missingList of $totalTrackCount"
                $script:ResumeTrackList = $missingList

                # Remove stale invalid files so cyanrip (which never overwrites an
                # existing file) can write fresh copies for them.
                foreach ($af in $existingAudioFiles) {
                    $trackNum = $null
                    if ($af.BaseName -match '^(\d+)\.(\d+)\s*-') { $trackNum = [int]$Matches[2] }
                    elseif ($af.BaseName -match '^(\d+)\s*-') { $trackNum = [int]$Matches[1] }
                    if ($trackNum -and ($trackNum -in $invalidTracks)) {
                        Remove-Item -LiteralPath $af.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        } else {
            Write-Host "Could not determine total track count from the disc - will re-rip only tracks cyanrip doesn't already have." -ForegroundColor Yellow
            Write-Log "Track count undetermined - falling back to a plain cyanrip invocation (no -l)"
            # No -l flag: cyanrip skips files it won't overwrite, so already-valid
            # tracks are left alone. Corrupt/zero-byte ones must still be cleared
            # first or cyanrip silently leaves them as-is.
            foreach ($af in $existingAudioFiles) {
                if (-not (Test-TrackIntegrity -FilePath $af.FullName)) {
                    Remove-Item -LiteralPath $af.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } else {
        Write-Host "No existing audio files - ripping from scratch." -ForegroundColor Yellow
    }

    if (-not $skipCyanripInvocation) {
        # ========== MUSICBRAINZ REACHABILITY CHECK ==========
        # Quick, single-attempt, non-interactive - unlike rip-audio.ps1, this script never
        # prompts the user to retry/skip, since a resume should just get on with it. A
        # failed probe skips MusicBrainz for this rip (-N) rather than letting cyanrip's
        # OWN internal MusicBrainz query kill the entire multi-track resume the moment it
        # hits that query. Real incident: a -FromTrack resume of a 16-track disc died after
        # track 1 when cyanrip's internal MB query hit a 503 mid-rip - 15 tracks' worth of a
        # single cyanrip invocation were lost for a lookup this script doesn't strictly need
        # anyway (the album's identity is already fixed from -Album/-Artist, unlike
        # rip-audio.ps1's initial rip where MusicBrainz is how the identity is discovered).
        Write-Host "`nChecking MusicBrainz API connectivity..." -ForegroundColor Yellow
        $skipMusicBrainzForRip = $false
        try {
            Invoke-WebRequest -Uri "https://musicbrainz.org/ws/2/release?query=test&limit=1" -Headers @{ "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)" } -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop | Out-Null
            Write-Host "MusicBrainz API: OK" -ForegroundColor Green
        } catch {
            Write-Host "MusicBrainz API: UNREACHABLE - skipping for this rip (generic track names)." -ForegroundColor Yellow
            Write-Host "  Reason: $($_.Exception.Message)" -ForegroundColor DarkGray
            Write-Log "MusicBrainz connectivity check failed - skipping for this rip: $($_.Exception.Message)"
            $skipMusicBrainzForRip = $true
        }

        # ========== BUILD AND RUN CYANRIP ==========
        $cyanripArgs = @("-D", $safeAlbum, "-o", $format, "-d", $driveLetter, "-s", "0")
        if ($ParanoiaLevel -ge 0) { $cyanripArgs += @("-P", "$ParanoiaLevel") }
        if ($Retries -ge 1) { $cyanripArgs += @("-r", "$Retries") }
        $lossyFormats = @("mp3", "opus", "aac")
        $hasLossy = ($formatList | Where-Object { $_ -in $lossyFormats }).Count -gt 0
        if ($Quality -gt 0 -and $hasLossy) { $cyanripArgs += @("-b", "$Quality") }
        if ($script:ResumeTrackList) { $cyanripArgs += @("-l", $script:ResumeTrackList) }
        if ($skipMusicBrainzForRip) { $cyanripArgs += @("-N") }

        $parentDir = Split-Path -Parent $finalOutputDir
        $cmdDisplay = "cyanrip -D `"$safeAlbum`" -o $format -d $driveLetter -s 0$(if ($script:ResumeTrackList) { " -l $($script:ResumeTrackList)" })$(if ($skipMusicBrainzForRip) { " -N" })"
        Write-Host "Working directory: $parentDir" -ForegroundColor Gray
        Write-Host "Command: $cmdDisplay" -ForegroundColor Gray
        Write-Log "cyanrip command: $cmdDisplay"

        # Start-CyanripWithErrorDetection - ported verbatim from rip-audio.ps1; keep
        # in sync with that copy if the streaming/error-detection logic changes there.
        function Start-CyanripWithErrorDetection {
            param([string[]]$CyanripArgs, [string]$WorkDir)

            $cyanripPath = (Get-Command cyanrip -ErrorAction Stop).Source
            $psi = [System.Diagnostics.ProcessStartInfo]::new($cyanripPath)
            $quotedArgs = @()
            foreach ($a in $CyanripArgs) {
                if ([string]::IsNullOrEmpty($a)) { $quotedArgs += '""' }
                elseif ($a -match '[\s"]') { $quotedArgs += '"' + ($a -replace '"', '\"') + '"' }
                else { $quotedArgs += $a }
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
            [void]$proc.Start()

            $outputLines = [System.Collections.ArrayList]::new()
            $consecutiveCdioErrors = 0
            $lastCompletedTrack = 0
            $killedDueToErrors = $false
            $cdioErrorThreshold = 30
            # Watchdog for the case the cdio-error counter can't catch: cyanrip going
            # completely silent (no progress, no errors, nothing) - kept in sync with the
            # identical watchdog in rip-audio.ps1's own copy of this function.
            $silenceTimeoutMinutes = 5
            $lastActivityTime = Get-Date

            $stdoutTask = $proc.StandardOutput.ReadLineAsync()
            $stderrTask = $proc.StandardError.ReadLineAsync()
            $stdoutEof = $false
            $stderrEof = $false
            $progressTrack = -1
            $progressBucket = -1

            while (-not ($proc.HasExited -and $stdoutEof -and $stderrEof)) {
                $anyRead = $false
                foreach ($taskRef in @('stdout', 'stderr')) {
                    if ($taskRef -eq 'stdout') {
                        if ($stdoutEof) { continue }
                        $task = $stdoutTask; $reader = $proc.StandardOutput
                    } else {
                        if ($stderrEof) { continue }
                        $task = $stderrTask; $reader = $proc.StandardError
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

                    $suppress = $false
                    if ($line -match 'track\s+(\d+).*progress\s*-\s*(\d+)\.\d+%') {
                        $trackNum = [int]$Matches[1]; $pct = [int]$Matches[2]
                        $bucket = [Math]::Floor($pct / 10) * 10
                        if ($trackNum -ne $progressTrack) { $progressTrack = $trackNum; $progressBucket = -1 }
                        if ($bucket -lt 10 -or $bucket -le $progressBucket) { $suppress = $true } else { $progressBucket = $bucket }
                    }
                    if (-not $suppress) { Write-Host $line }

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
                        Write-Host "`n*** CDIO ERROR: Track $($lastCompletedTrack + 1) is unreadable -- skipping ***" -ForegroundColor Red
                        $killedDueToErrors = $true
                        try { $proc.Kill() } catch {}
                        break
                    }
                    $nextTask = $reader.ReadLineAsync()
                    if ($taskRef -eq 'stdout') { $stdoutTask = $nextTask } else { $stderrTask = $nextTask }
                }
                if ($killedDueToErrors) { break }
                if (-not $anyRead) {
                    if (-not $proc.HasExited -and ((Get-Date) - $lastActivityTime).TotalMinutes -ge $silenceTimeoutMinutes) {
                        Write-Host "`n*** SILENCE TIMEOUT: no cyanrip output for $silenceTimeoutMinutes minute(s) -- likely stuck on track $($lastCompletedTrack + 1) -- killing ***" -ForegroundColor Red
                        Write-Log "Silence timeout: no cyanrip output for $silenceTimeoutMinutes minute(s) after track $lastCompletedTrack -- killing cyanrip"
                        $killedDueToErrors = $true
                        try { $proc.Kill() } catch {}
                        break
                    }
                    Start-Sleep -Milliseconds 50
                }
            }

            return @{ ExitCode = $proc.ExitCode; Output = $outputLines.ToArray(); Killed = $killedDueToErrors; LastCompletedTrack = $lastCompletedTrack }
        }

        Push-Location $parentDir
        try {
            $result = Start-CyanripWithErrorDetection -CyanripArgs $cyanripArgs -WorkDir $parentDir
        } finally {
            Pop-Location
        }

        # Post-rip validity check - same Test-TrackIntegrity-based approach as
        # rip-audio.ps1 (not just size), so a corrupt-but-nonzero file from a
        # dropped connection is caught here instead of the summary claiming success.
        $postRipAudio = Get-ExistingAudioFiles
        $postRipValid = @($postRipAudio | Where-Object { $_.Length -gt 0 -and (Test-TrackIntegrity -FilePath $_.FullName) })
        if ($postRipValid.Count -eq 0) {
            Stop-WithError -Step "STEP 1/4: cyanrip" -Message "cyanrip produced no usable audio this attempt (exit code $($result.ExitCode)). If the drive dropped mid-rip, reconnect it and re-run this same command."
        }
        if ($result.ExitCode -ne 0) {
            Write-Host "`nWARNING: cyanrip exited with code $($result.ExitCode), but $($postRipValid.Count) valid track(s) exist. Re-run this command again to try for the rest." -ForegroundColor Yellow
            Write-Log "Partial rip: exit=$($result.ExitCode), $($postRipValid.Count) valid file(s)"
        }
        Write-Host "`ncyanrip complete!" -ForegroundColor Green
    }

    Write-Timestamp "Step 1 complete"
    Write-Log "STEP 1/4: complete"
    Complete-CurrentStep
}

# ========== STEP 2: VERIFY ==========
if ($StartFromStepNumber -le 2) {
    Set-CurrentStep -StepNumber 2
    Write-Log "STEP 2/4: Verifying output..."
    Write-Host "`n[STEP 2/4] Verifying output..." -ForegroundColor Green
    Write-Timestamp "Step 2 started"

    $rippedFiles = @(Get-ExistingAudioFiles | Where-Object { $_.Length -gt 0 -and (Test-TrackIntegrity -FilePath $_.FullName) })
    if ($rippedFiles.Count -eq 0) {
        Stop-WithError -Step "STEP 2/4: Verify output" -Message "No valid audio files found in $finalOutputDir"
    }
    Write-Host "Found $($rippedFiles.Count) valid audio file(s):" -ForegroundColor Green
    $totalSize = 0
    foreach ($file in $rippedFiles) {
        $sizeMB = [math]::Round($file.Length / 1MB, 2)
        $totalSize += $file.Length
        Write-Host "  - $($file.Name) ($sizeMB MB)" -ForegroundColor Gray
    }
    $totalSizeMB = [math]::Round($totalSize / 1MB, 2)
    Write-Host "Total size: $totalSizeMB MB" -ForegroundColor White
    Write-Log "STEP 2/4: Verification complete - $($rippedFiles.Count) file(s)"

    Write-Timestamp "Step 2 complete"
    Complete-CurrentStep
}

# ========== STEP 3: COVER ART ==========
# Ported near-verbatim from rip-audio.ps1's Step 3 - keep the two in sync if the
# cover art source chain (Cover Art Archive -> MusicBrainz+CAA -> iTunes -> Deezer)
# changes there.
if ($StartFromStepNumber -le 3) {
    Set-CurrentStep -StepNumber 3
    Write-Log "STEP 3/4: Downloading cover art..."
    Write-Host "`n[STEP 3/4] Downloading cover art..." -ForegroundColor Green
    Write-Timestamp "Step 3 started"

    $script:CoverArtDownloaded = $false
    $existingArt = Get-ChildItem -Path $finalOutputDir -Include "Front.*","Cover.*","Folder.*" -ErrorAction SilentlyContinue
    if ($existingArt -and $existingArt.Count -gt 0) {
        Write-Host "  Cover art already exists: $($existingArt[0].Name)" -ForegroundColor Green
        $script:CoverArtDownloaded = $true
        $script:CoverArtSource = "existing"
    } else {
        $releaseId = $null
        $cueFile = Get-ChildItem -Path $finalOutputDir -Filter "*.cue" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cueFile) {
            $cueContent = Get-Content -Path $cueFile.FullName -Raw -ErrorAction SilentlyContinue
            if ($cueContent -match 'REM RELEASE_ID "([^"]+)"') { $releaseId = $Matches[1] }
        }
        $artDownloaded = $false

        if ($releaseId) {
            Write-Host "  Trying Cover Art Archive..." -ForegroundColor Gray
            try {
                $caaHeaders = @{ "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)" }
                $caaResponse = Invoke-RestMethod -Uri "https://coverartarchive.org/release/$releaseId" -Headers $caaHeaders -TimeoutSec 10
                if ($caaResponse.images -and $caaResponse.images.Count -gt 0) {
                    $frontCover = $caaResponse.images | Where-Object { $_.front -eq $true } | Select-Object -First 1
                    if (-not $frontCover) { $frontCover = $caaResponse.images[0] }
                    $extension = if ($frontCover.image -match '\.(\w+)$') { $Matches[1] } else { "jpg" }
                    $outputFile = Join-Path $finalOutputDir "Front.$extension"
                    Invoke-WebRequest -Uri $frontCover.image -OutFile $outputFile -Headers $caaHeaders -TimeoutSec 30
                    Write-Host "  Downloaded: Front.$extension (Cover Art Archive)" -ForegroundColor Green
                    $artDownloaded = $true; $script:CoverArtDownloaded = $true; $script:CoverArtSource = "Cover Art Archive"
                }
            } catch { Write-Host "  Cover Art Archive: not available" -ForegroundColor Yellow }
        }

        if (-not $artDownloaded) {
            Write-Host "  Searching MusicBrainz for release..." -ForegroundColor Gray
            try {
                $mbSearchHeaders = @{ "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)"; "Accept" = "application/json" }
                $mbQuery = if ($Artist) { "release:`"$Album`" AND artist:`"$Artist`"" } else { "release:`"$Album`"" }
                $mbSearchUrl = "https://musicbrainz.org/ws/2/release?query=$([System.Web.HttpUtility]::UrlEncode($mbQuery))&limit=1&fmt=json"
                $mbSearchResponse = Invoke-RestMethod -Uri $mbSearchUrl -Headers $mbSearchHeaders -TimeoutSec 10
                if ($mbSearchResponse.releases -and $mbSearchResponse.releases.Count -gt 0) {
                    Start-Sleep -Milliseconds 1100
                    $caaSearchResponse = Invoke-RestMethod -Uri "https://coverartarchive.org/release/$($mbSearchResponse.releases[0].id)" -Headers $mbSearchHeaders -TimeoutSec 10
                    if ($caaSearchResponse.images -and $caaSearchResponse.images.Count -gt 0) {
                        $frontCover = $caaSearchResponse.images | Where-Object { $_.front -eq $true } | Select-Object -First 1
                        if (-not $frontCover) { $frontCover = $caaSearchResponse.images[0] }
                        $extension = if ($frontCover.image -match '\.(\w+)$') { $Matches[1] } else { "jpg" }
                        $outputFile = Join-Path $finalOutputDir "Front.$extension"
                        Invoke-WebRequest -Uri $frontCover.image -OutFile $outputFile -Headers $mbSearchHeaders -TimeoutSec 30
                        if ((Test-Path $outputFile) -and (Get-Item $outputFile).Length -gt 1000) {
                            Write-Host "  Downloaded: Front.$extension (MusicBrainz/CAA search)" -ForegroundColor Green
                            $artDownloaded = $true; $script:CoverArtDownloaded = $true; $script:CoverArtSource = "MusicBrainz/CAA"
                        } else { Remove-Item $outputFile -ErrorAction SilentlyContinue }
                    }
                }
            } catch { Write-Host "  MusicBrainz/CAA search: not available" -ForegroundColor Yellow }
        }

        if (-not $artDownloaded) {
            Write-Host "  Trying iTunes Search API..." -ForegroundColor Gray
            try {
                $itunesQuery = if ($Artist) { "$Artist $Album" } else { $Album }
                $itunesUrl = "https://itunes.apple.com/search?term=$([System.Web.HttpUtility]::UrlEncode($itunesQuery))&media=music&entity=album&limit=1"
                $itunesResponse = Invoke-RestMethod -Uri $itunesUrl -TimeoutSec 10
                if ($itunesResponse.results -and $itunesResponse.results.Count -gt 0 -and $itunesResponse.results[0].artworkUrl100) {
                    $artworkUrl = $itunesResponse.results[0].artworkUrl100 -replace '100x100bb', '600x600bb'
                    $outputFile = Join-Path $finalOutputDir "Front.jpg"
                    Invoke-WebRequest -Uri $artworkUrl -OutFile $outputFile -TimeoutSec 30
                    if ((Test-Path $outputFile) -and (Get-Item $outputFile).Length -gt 1000) {
                        Write-Host "  Downloaded: Front.jpg (iTunes)" -ForegroundColor Green
                        $artDownloaded = $true; $script:CoverArtDownloaded = $true; $script:CoverArtSource = "iTunes"
                    } else { Remove-Item $outputFile -ErrorAction SilentlyContinue }
                }
            } catch { Write-Host "  iTunes Search: not available" -ForegroundColor Yellow }
        }

        if (-not $artDownloaded) {
            Write-Host "  Trying Deezer API..." -ForegroundColor Gray
            try {
                $deezerQuery = if ($Artist) { "$Artist $Album" } else { $Album }
                $deezerUrl = "https://api.deezer.com/search/album?q=$([System.Web.HttpUtility]::UrlEncode($deezerQuery))"
                $deezerResponse = Invoke-RestMethod -Uri $deezerUrl -TimeoutSec 10
                if ($deezerResponse.data -and $deezerResponse.data.Count -gt 0) {
                    $coverUrl = $deezerResponse.data[0].cover_xl
                    if (-not $coverUrl) { $coverUrl = $deezerResponse.data[0].cover_big }
                    if (-not $coverUrl) { $coverUrl = $deezerResponse.data[0].cover_medium }
                    if ($coverUrl) {
                        $outputFile = Join-Path $finalOutputDir "Front.jpg"
                        Invoke-WebRequest -Uri $coverUrl -OutFile $outputFile -TimeoutSec 30
                        if ((Test-Path $outputFile) -and (Get-Item $outputFile).Length -gt 1000) {
                            Write-Host "  Downloaded: Front.jpg (Deezer)" -ForegroundColor Green
                            $artDownloaded = $true; $script:CoverArtDownloaded = $true; $script:CoverArtSource = "Deezer"
                        } else { Remove-Item $outputFile -ErrorAction SilentlyContinue }
                    }
                }
            } catch { Write-Host "  Deezer: not available" -ForegroundColor Yellow }
        }

        if (-not $artDownloaded) { Write-Host "  No cover art found from any source (continuing without)" -ForegroundColor Yellow }
    }

    $script:CoverArtEmbedded = 0
    $artFile = Get-ChildItem -Path $finalOutputDir -File -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -in @('Front', 'Cover', 'Folder') } | Select-Object -First 1
    if ($artFile -and (Get-Command metaflac -ErrorAction SilentlyContinue)) {
        Write-Host "  Embedding cover art into FLAC files..." -ForegroundColor Gray
        $flacFiles = Get-ChildItem -Path $finalOutputDir -Filter "*.flac" -ErrorAction SilentlyContinue
        foreach ($flac in $flacFiles) {
            try {
                $tempArt = Join-Path $env:TEMP "ripaudio_embed_$([System.IO.Path]::GetRandomFileName())"
                Copy-Item -LiteralPath $artFile.FullName -Destination $tempArt -Force
                & metaflac --remove --block-type=PICTURE --dont-use-padding $flac.FullName 2>&1 | Out-Null
                & metaflac "--import-picture-from=$tempArt" $flac.FullName 2>&1 | Out-Null
                Remove-Item -LiteralPath $tempArt -Force -ErrorAction SilentlyContinue
                if ($LASTEXITCODE -eq 0) { $script:CoverArtEmbedded++ }
            } catch { Write-Log "  Embed error for $($flac.Name): $_" }
        }
        if ($script:CoverArtEmbedded -gt 0) {
            Write-Host "  Embedded cover art into $($script:CoverArtEmbedded)/$($flacFiles.Count) file(s)" -ForegroundColor Green
        } else {
            Write-Host "  Cover art embed failed (metaflac error - run search-metadata.ps1 to embed manually)" -ForegroundColor Yellow
        }
    }

    Write-Timestamp "Step 3 complete"
    Complete-CurrentStep
}

# ========== STEP 4: OPEN DIRECTORY ==========
if ($StartFromStepNumber -le 4) {
    Set-CurrentStep -StepNumber 4
    Write-Log "STEP 4/4: Opening directory..."
    Write-Host "`n[STEP 4/4] Opening output directory..." -ForegroundColor Green
    Write-Timestamp "Step 4 started"
    Write-Host "Opening: $finalOutputDir" -ForegroundColor Yellow
    Start-Process explorer.exe -ArgumentList "`"$($finalOutputDir.TrimEnd('\'))`""
    Write-Timestamp "Step 4 complete"
    Complete-CurrentStep
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "COMPLETE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nProcessed: $(Get-AlbumSummary)" -ForegroundColor White
Write-Host "Final location: $finalOutputDir" -ForegroundColor White
Show-StepsSummary
Write-Host "`nLog file: $($script:LogFile)" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

Show-CoffeeBadge

Write-Log "========== CONTINUE SESSION COMPLETE =========="
Enable-ConsoleClose
