param(
    [Parameter(Mandatory=$true)]
    [string]$LogFile,

    [Parameter()]
    [switch]$DryRun
)

# Ensure metaflac (and other external tools) output is read as UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ========== HELPER FUNCTIONS ==========

function Assert-MetaflacInstalled {
    if (Get-Command metaflac -ErrorAction SilentlyContinue) { return }

    # Refresh PATH from registry first
    $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH    = "$machinePath;$userPath"
    if (Get-Command metaflac -ErrorAction SilentlyContinue) { return }

    Write-Host ""
    Write-Host "  metaflac is not installed." -ForegroundColor Yellow
    Write-Host "  It is required to restore tags in FLAC files." -ForegroundColor Yellow
    Write-Host "  It can be installed automatically via winget (Windows Package Manager)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Install now? [Y/N] (auto-Yes in 30s): " -NoNewline -ForegroundColor White

    $key = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 30) {
        if ([Console]::KeyAvailable) { $key = [Console]::ReadKey($true); break }
        Start-Sleep -Milliseconds 200
    }
    $sw.Stop()

    $choice = if ($key) { "$($key.KeyChar)".ToUpper() } else { $null }
    if ($null -eq $choice) { Write-Host "Y (auto)" -ForegroundColor Gray; $choice = "Y" }
    else { Write-Host $choice }

    if ($choice -eq "N") {
        Write-Host ""
        Write-Host "  To install manually, open a terminal and run:" -ForegroundColor White
        Write-Host "    winget install xiph.flac" -ForegroundColor Cyan
        Write-Host ""
        exit 1
    }

    Write-Host "  Installing FLAC tools..." -ForegroundColor Cyan
    & winget install xiph.flac --accept-source-agreements --accept-package-agreements

    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Write-Host "  Install failed (exit $LASTEXITCODE). Run manually:" -ForegroundColor Red
        Write-Host "    winget install xiph.flac" -ForegroundColor Cyan
        exit 1
    }

    $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $userPath    = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH    = "$machinePath;$userPath"

    if (Get-Command metaflac -ErrorAction SilentlyContinue) {
        Write-Host "  metaflac ready." -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Host "  Installed. Please close and reopen this terminal, then run the script again." -ForegroundColor Yellow
        exit 0
    }
}

function Write-Log {
    param([string]$Message)
    if ($script:UndoLogFile) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $entry = "[$timestamp] $Message"
        Add-Content -Path $script:UndoLogFile -Value $entry
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
    Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host ("".PadRight($w)) -NoNewline; Write-Host "$vt" -ForegroundColor DarkGray
    $c = "  "; Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host $c -NoNewline; Write-Host ("I host all my sites on SiteGround - highly".PadRight($w - $c.Length)) -NoNewline -ForegroundColor Gray; Write-Host "$vt" -ForegroundColor DarkGray
    $c = "  "; Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host $c -NoNewline; Write-Host ("recommended if you want to make a site!".PadRight($w - $c.Length)) -NoNewline -ForegroundColor Gray; Write-Host "$vt" -ForegroundColor DarkGray
    $c = "  "; Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host $c -NoNewline; Write-Host (">> https://siteground.com/go/steve (affiliate link)".PadRight($w - $c.Length)) -NoNewline -ForegroundColor Yellow; Write-Host "$vt" -ForegroundColor DarkGray
    $c = "  "; Write-Host "  $vt" -NoNewline -ForegroundColor DarkGray; Write-Host $c -NoNewline; Write-Host ("Click to check it out and support my projects!".PadRight($w - $c.Length)) -NoNewline -ForegroundColor Cyan; Write-Host "$vt" -ForegroundColor DarkGray
    Write-Host "  $bl$hz$br" -ForegroundColor DarkGray
    Write-Host ""
}

# ========== MAIN SCRIPT ==========

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Undo Metadata Changes" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Resolve wildcard in log file path
$resolvedFiles = @(Resolve-Path $LogFile -ErrorAction SilentlyContinue)
if ($resolvedFiles.Count -eq 0) {
    Write-Host "`nError: Log file not found: $LogFile" -ForegroundColor Red
    exit 1
}
if ($resolvedFiles.Count -gt 1) {
    Write-Host "`nMultiple log files match the pattern. Please specify a single file:" -ForegroundColor Yellow
    foreach ($f in $resolvedFiles) {
        Write-Host "  $($f.Path)" -ForegroundColor Gray
    }
    exit 1
}
$LogFile = $resolvedFiles[0].Path

Write-Host "`n  Log file: $LogFile" -ForegroundColor White

# Ensure metaflac is installed
Assert-MetaflacInstalled

# Setup undo log
$logDir = "C:\Music\logs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:UndoLogFile = Join-Path $logDir "undo-metadata_${logTimestamp}.log"

Write-Log "========== UNDO METADATA SESSION STARTED =========="
Write-Log "Source log: $LogFile"
Write-Log "DryRun: $DryRun"

# Window title
$host.UI.RawUI.WindowTitle = "undo-metadata - $LogFile"

# ========== STEP 1: PARSE LOG ==========
Write-Host "`n[STEP 1/4] Parsing log file..." -ForegroundColor Green

$baselines = @()
$renames = @()
$coverArts = @()

$logLines = Get-Content -Path $LogFile -Encoding UTF8
foreach ($line in $logLines) {
    # Strip timestamp prefix: [2026-02-24 12:34:56] UNDO_...
    if ($line -match '^\[[\d\-\s:]+\]\s*(.+)$') {
        $content = $Matches[1]
    } else {
        continue
    }

    if ($content -match '^UNDO_BASELINE\|(.+)$') {
        $parts = $Matches[1] -split '\|'
        $filePath = $parts[0]
        $tags = @{}
        for ($i = 1; $i -lt $parts.Count; $i++) {
            if ($parts[$i] -match '^([^=]+)=(.*)$') {
                $tags[$Matches[1]] = $Matches[2]
            }
        }
        $baselines += @{ FilePath = $filePath; Tags = $tags }
    }
    elseif ($content -match '^UNDO_RENAME\|(.+)\|(.+)$') {
        $renames += @{ NewPath = $Matches[1]; OldPath = $Matches[2] }
    }
    elseif ($content -match '^UNDO_COVER_ART\|(.+)\|(.+)\|(.+)$') {
        $coverArts += @{ FolderPath = $Matches[1]; DownloadedFile = $Matches[2]; HadExistingArt = $Matches[3] }
    }
}

Write-Host "  Found $($baselines.Count) tag baseline(s)" -ForegroundColor White
Write-Host "  Found $($renames.Count) rename(s)" -ForegroundColor White
Write-Host "  Found $($coverArts.Count) cover art change(s)" -ForegroundColor White
Write-Log "Parsed: $($baselines.Count) baselines, $($renames.Count) renames, $($coverArts.Count) cover arts"

if ($baselines.Count -eq 0 -and $renames.Count -eq 0 -and $coverArts.Count -eq 0) {
    Write-Host "`n  No undo data found in log file." -ForegroundColor Yellow
    Write-Host "  This log may predate undo support, or no changes were applied." -ForegroundColor Gray
    Write-Log "No undo data found"
    exit 0
}

# ========== STEP 2: PREVIEW ==========
Write-Host "`n[STEP 2/4] Preview undo operations..." -ForegroundColor Green

if ($renames.Count -gt 0) {
    Write-Host "`n  --- File Renames (will be reversed) ---" -ForegroundColor Cyan
    foreach ($r in $renames) {
        $newName = Split-Path -Leaf $r.NewPath
        $oldName = Split-Path -Leaf $r.OldPath
        Write-Host "    $newName -> $oldName" -ForegroundColor Yellow
    }
}

if ($baselines.Count -gt 0) {
    Write-Host "`n  --- Tags (will be restored to original values) ---" -ForegroundColor Cyan
    # Group by folder for cleaner display
    $folders = $baselines | ForEach-Object { Split-Path -Parent $_.FilePath } | Sort-Object -Unique
    foreach ($folder in $folders) {
        $folderBaselines = @($baselines | Where-Object { (Split-Path -Parent $_.FilePath) -eq $folder })
        $relFolder = Split-Path -Leaf $folder
        $artist = $folderBaselines[0].Tags["ARTIST"]
        $album = $folderBaselines[0].Tags["ALBUM"]
        if ($artist -and $album) {
            Write-Host "    $artist - $album ($($folderBaselines.Count) files)" -ForegroundColor Yellow
        } else {
            Write-Host "    $relFolder ($($folderBaselines.Count) files)" -ForegroundColor Yellow
        }
    }
}

if ($coverArts.Count -gt 0) {
    Write-Host "`n  --- Cover Art (will be removed if newly downloaded) ---" -ForegroundColor Cyan
    foreach ($c in $coverArts) {
        $artName = Split-Path -Leaf $c.DownloadedFile
        if ($c.HadExistingArt -eq "True") {
            Write-Host "    $artName (was pre-existing, will keep)" -ForegroundColor Gray
        } else {
            Write-Host "    $artName (will be deleted)" -ForegroundColor Yellow
        }
    }
}

# ========== STEP 3: CONFIRM ==========
Write-Host "`n[STEP 3/4] Confirm undo..." -ForegroundColor Green

if ($DryRun) {
    Write-Host "`n  [DRY RUN] No changes will be made." -ForegroundColor Cyan
    Write-Log "[DRY RUN] Preview only, no changes made"
} else {
    Write-Host "`n  Apply undo? [Y/n] " -NoNewline -ForegroundColor White
    $key = [Console]::ReadKey($true)
    Write-Host $key.KeyChar
    if ("$($key.KeyChar)".ToUpper() -eq "N") {
        Write-Host "`n  Cancelled by user." -ForegroundColor Yellow
        Write-Log "User cancelled undo"
        exit 0
    }
    Write-Log "User confirmed undo"
}

# ========== STEP 4: EXECUTE ==========
Write-Host "`n[STEP 4/4] Executing undo..." -ForegroundColor Green

$renameSuccess = 0
$renameFailed = 0
$tagSuccess = 0
$tagFailed = 0
$artRemoved = 0

# 1. Reverse renames FIRST (so BASELINE file paths are valid)
if ($renames.Count -gt 0) {
    Write-Host "`n  Reversing renames..." -ForegroundColor Cyan
    foreach ($r in $renames) {
        if ($DryRun) {
            Write-Host "    [DRY RUN] Would rename $(Split-Path -Leaf $r.NewPath) -> $(Split-Path -Leaf $r.OldPath)" -ForegroundColor Cyan
            $renameSuccess++
            continue
        }
        if (Test-Path $r.NewPath) {
            try {
                $oldName = Split-Path -Leaf $r.OldPath
                Rename-Item -Path $r.NewPath -NewName $oldName -ErrorAction Stop
                Write-Host "    $(Split-Path -Leaf $r.NewPath) -> $oldName" -ForegroundColor Gray
                Write-Log "  Reversed rename: $(Split-Path -Leaf $r.NewPath) -> $oldName"
                $renameSuccess++
            } catch {
                Write-Host "    Failed to rename $(Split-Path -Leaf $r.NewPath): $_" -ForegroundColor Red
                Write-Log "  ERROR reversing rename $(Split-Path -Leaf $r.NewPath): $_"
                $renameFailed++
            }
        } else {
            Write-Host "    File not found: $($r.NewPath)" -ForegroundColor Yellow
            Write-Log "  SKIP: file not found: $($r.NewPath)"
            $renameFailed++
        }
    }
}

# 2. Restore tags from baselines
if ($baselines.Count -gt 0) {
    Write-Host "`n  Restoring tags..." -ForegroundColor Cyan
    foreach ($b in $baselines) {
        $filePath = $b.FilePath
        if ($DryRun) {
            Write-Host "    [DRY RUN] Would restore tags for $(Split-Path -Leaf $filePath)" -ForegroundColor Cyan
            $tagSuccess++
            continue
        }
        if (-not (Test-Path $filePath)) {
            Write-Host "    File not found: $filePath" -ForegroundColor Yellow
            Write-Log "  SKIP: file not found: $filePath"
            $tagFailed++
            continue
        }

        try {
            # Remove current tags
            $removeArgs = @(
                "--remove-tag=TITLE",
                "--remove-tag=ARTIST",
                "--remove-tag=ALBUM",
                "--remove-tag=ALBUMARTIST",
                "--remove-tag=TRACKNUMBER",
                "--remove-tag=TRACKTOTAL",
                "--remove-tag=DATE",
                "--remove-tag=GENRE",
                "--remove-tag=MUSICBRAINZ_ALBUMID"
            )
            & metaflac @removeArgs $filePath 2>$null

            # Restore original tags (only set non-empty values)
            $setArgs = @()
            foreach ($tagName in @("TITLE", "ARTIST", "ALBUM", "ALBUMARTIST", "TRACKNUMBER", "TRACKTOTAL", "DATE", "GENRE", "MUSICBRAINZ_ALBUMID")) {
                $tagValue = $b.Tags[$tagName]
                if ($tagValue) {
                    $setArgs += "--set-tag=$tagName=$tagValue"
                }
            }
            if ($setArgs.Count -gt 0) {
                & metaflac @setArgs $filePath 2>$null
            }

            Write-Host "    Restored: $(Split-Path -Leaf $filePath)" -ForegroundColor Gray
            Write-Log "  Restored tags: $(Split-Path -Leaf $filePath)"
            $tagSuccess++
        } catch {
            Write-Host "    Failed to restore tags for $(Split-Path -Leaf $filePath): $_" -ForegroundColor Red
            Write-Log "  ERROR restoring tags: $(Split-Path -Leaf $filePath): $_"
            $tagFailed++
        }
    }
}

# 3. Remove downloaded cover art (only if it was newly downloaded, not pre-existing)
if ($coverArts.Count -gt 0) {
    Write-Host "`n  Removing downloaded cover art..." -ForegroundColor Cyan
    foreach ($c in $coverArts) {
        if ($c.HadExistingArt -eq "True") {
            Write-Host "    Skipping $($c.DownloadedFile) (was pre-existing)" -ForegroundColor Gray
            continue
        }
        if ($DryRun) {
            Write-Host "    [DRY RUN] Would delete $(Split-Path -Leaf $c.DownloadedFile)" -ForegroundColor Cyan
            $artRemoved++
            continue
        }
        if (Test-Path $c.DownloadedFile) {
            try {
                Remove-Item -Path $c.DownloadedFile -Force -ErrorAction Stop
                Write-Host "    Deleted: $(Split-Path -Leaf $c.DownloadedFile)" -ForegroundColor Gray
                Write-Log "  Deleted cover art: $($c.DownloadedFile)"
                $artRemoved++
            } catch {
                Write-Host "    Failed to delete $($c.DownloadedFile): $_" -ForegroundColor Red
                Write-Log "  ERROR deleting cover art: $($c.DownloadedFile): $_"
            }
        } else {
            Write-Host "    File not found: $($c.DownloadedFile)" -ForegroundColor Yellow
        }
    }
}

# ========== SUMMARY ==========
$dryRunLabel = if ($DryRun) { "[DRY RUN] " } else { "" }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "${dryRunLabel}UNDO COMPLETE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`n--- ${dryRunLabel}SUMMARY ---" -ForegroundColor Cyan
if ($renames.Count -gt 0) {
    Write-Host "  Renames reversed: $renameSuccess/$($renames.Count)" -ForegroundColor White
    if ($renameFailed -gt 0) {
        Write-Host "  Rename failures: $renameFailed" -ForegroundColor Red
    }
}
if ($baselines.Count -gt 0) {
    Write-Host "  Tags restored: $tagSuccess/$($baselines.Count)" -ForegroundColor White
    if ($tagFailed -gt 0) {
        Write-Host "  Tag failures: $tagFailed" -ForegroundColor Red
    }
}
if ($coverArts.Count -gt 0) {
    Write-Host "  Cover art removed: $artRemoved" -ForegroundColor White
}
Write-Host "  Source log: $LogFile" -ForegroundColor White
Write-Host "  Undo log: $($script:UndoLogFile)" -ForegroundColor White

Write-Host "`n========================================`n" -ForegroundColor Cyan

Show-CoffeeBadge

$host.UI.RawUI.WindowTitle = "undo-metadata - DONE"

Write-Log "========== UNDO SESSION COMPLETE =========="
Write-Log "Renames reversed: $renameSuccess/$($renames.Count)"
Write-Log "Tags restored: $tagSuccess/$($baselines.Count)"
Write-Log "Cover art removed: $artRemoved"
