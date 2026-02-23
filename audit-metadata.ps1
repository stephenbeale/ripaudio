param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [Parameter()]
    [string]$OutputPath = "C:\Music\needs-update",

    [Parameter()]
    [switch]$ReportOnly
)

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

    if ($script:LogFile) {
        Write-Host "`nLog file: $($script:LogFile)" -ForegroundColor Yellow
    }
    Write-Host "`n========================================`n" -ForegroundColor Red
    exit 1
}

function Read-TimedConfirmation {
    param([string]$Prompt, [int]$TimeoutSeconds = 30)

    Write-Host ""
    Write-Host "  $Prompt " -NoNewline -ForegroundColor White
    $confirm = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            $confirm = $key.KeyChar
            Write-Host $confirm
            break
        }
        Start-Sleep -Milliseconds 200
    }
    $stopwatch.Stop()
    if ($null -eq $confirm) {
        Write-Host "Y (auto)" -ForegroundColor Gray
    }
    if ($confirm -and "$confirm".ToUpper() -eq "N") {
        return $false
    }
    return $true
}

function Read-ExistingTags {
    param([string]$FolderPath)

    $audioFiles = Get-ChildItem -Path $FolderPath -Filter "*.flac" -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $audioFiles -or $audioFiles.Count -eq 0) {
        return $null
    }

    $tracks = @()
    foreach ($file in $audioFiles) {
        $tagData = @{
            File = $file
            FileName = $file.Name
            Artist = ""
            Album = ""
            AlbumArtist = ""
            Title = ""
            TrackNumber = ""
            Date = ""
            Genre = ""
        }

        $metaflacPath = Get-Command metaflac -ErrorAction SilentlyContinue
        if ($metaflacPath) {
            $tagFields = @("ARTIST", "ALBUM", "ALBUMARTIST", "TITLE", "TRACKNUMBER", "DATE", "GENRE")
            foreach ($field in $tagFields) {
                $value = & metaflac --show-tag=$field $file.FullName 2>$null
                if ($value -and $value -match "^$field=(.+)$") {
                    $tagData[$field.Substring(0,1).ToUpper() + $field.Substring(1).ToLower()] = $Matches[1]
                    # Fix casing for multi-word fields
                    if ($field -eq "ALBUMARTIST") { $tagData.AlbumArtist = $Matches[1] }
                    if ($field -eq "TRACKNUMBER") { $tagData.TrackNumber = $Matches[1] }
                }
            }
        }

        $tracks += $tagData
    }

    return $tracks
}

# ========== MAIN SCRIPT ==========

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Audit Audio Metadata" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Validate path
if (-not (Test-Path $Path)) {
    Write-Host "`nError: Path not found: $Path" -ForegroundColor Red
    exit 1
}

# Setup logging
$logDir = "C:\Music\logs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFile = Join-Path $logDir "audit-metadata_${logTimestamp}.log"

Write-Log "========== AUDIT METADATA SESSION STARTED =========="
Write-Log "Path: $Path"
Write-Log "OutputPath: $OutputPath"
Write-Log "ReportOnly: $ReportOnly"

# Window title
$host.UI.RawUI.WindowTitle = "audit-metadata - $Path"

# ========== STEP 1: DISCOVER ALBUM FOLDERS ==========
Write-Host "`n[STEP 1/4] Discovering album folders..." -ForegroundColor Green
Write-Log "STEP 1/4: Discovering album folders"

$allFlacFiles = Get-ChildItem -Path $Path -Filter "*.flac" -Recurse -ErrorAction SilentlyContinue
$albumFolders = @()
if ($allFlacFiles) {
    $albumFolders = $allFlacFiles | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique
}

# Filter out logs folder and the output staging directory
$normalizedOutputPath = if ($OutputPath) { (Resolve-Path $OutputPath -ErrorAction SilentlyContinue).Path } else { $null }
$albumFolders = $albumFolders | Where-Object {
    $folder = $_
    # Skip logs folder
    if ($folder -match '\\logs(\\|$)') { return $false }
    # Skip the staging output directory
    if ($normalizedOutputPath -and $folder.StartsWith($normalizedOutputPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    # Skip needs-update folder even if OutputPath doesn't resolve yet
    if ($folder -match '\\needs-update(\\|$)') { return $false }
    return $true
}

if ($albumFolders.Count -eq 0) {
    Stop-WithError -Step "STEP 1/4: Discover albums" -Message "No FLAC files found under: $Path"
}

Write-Host "  Found $($albumFolders.Count) album folder(s)" -ForegroundColor White
Write-Log "Found $($albumFolders.Count) album folders"

foreach ($folder in $albumFolders) {
    $relPath = $folder.Substring($Path.Length).TrimStart('\', '/')
    if (-not $relPath) { $relPath = "." }
    $flacCount = (Get-ChildItem -Path $folder -Filter "*.flac" -ErrorAction SilentlyContinue).Count
    Write-Host "    $relPath ($flacCount files)" -ForegroundColor Gray
}

# ========== STEP 2: AUDIT EACH FOLDER ==========
Write-Host "`n[STEP 2/4] Auditing metadata..." -ForegroundColor Green
Write-Log "STEP 2/4: Auditing metadata"

$auditResults = @()
$folderNum = 0

foreach ($folder in $albumFolders) {
    $folderNum++
    $relPath = $folder.Substring($Path.Length).TrimStart('\', '/')
    if (-not $relPath) { $relPath = "." }

    $host.UI.RawUI.WindowTitle = "audit-metadata [$folderNum/$($albumFolders.Count)] $relPath"

    $tracks = Read-ExistingTags -FolderPath $folder
    if (-not $tracks -or $tracks.Count -eq 0) { continue }

    $issues = @()

    # Check 1: Track titles - flag if any track has generic/empty title
    $genericTitleCount = 0
    foreach ($track in $tracks) {
        if (-not $track.Title -or $track.Title -eq "" -or $track.Title -match '^Unknown track$' -or $track.Title -match '^Track \d+$') {
            $genericTitleCount++
        }
    }
    if ($genericTitleCount -gt 0) {
        $issues += "Missing track titles ($genericTitleCount/$($tracks.Count))"
    }

    # Check 2: Album-level tags - flag if Artist, Album, Date, or Genre are empty across all tracks
    $hasArtist = ($tracks | Where-Object { $_.Artist -and $_.Artist -ne "" }).Count -gt 0
    $hasAlbum = ($tracks | Where-Object { $_.Album -and $_.Album -ne "" }).Count -gt 0
    $hasDate = ($tracks | Where-Object { $_.Date -and $_.Date -ne "" }).Count -gt 0
    $hasGenre = ($tracks | Where-Object { $_.Genre -and $_.Genre -ne "" }).Count -gt 0

    if (-not $hasArtist) { $issues += "Missing artist" }
    if (-not $hasAlbum) { $issues += "Missing album" }
    if (-not $hasDate) { $issues += "Missing date" }
    if (-not $hasGenre) { $issues += "Missing genre" }

    # Check 3: Cover art - flag if no Front.*, Cover.*, or Folder.* exists
    $coverArt = Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -in @('Front', 'Cover', 'Folder') }
    if (-not $coverArt -or $coverArt.Count -eq 0) {
        $issues += "No cover art"
    }

    $needsUpdate = $issues.Count -gt 0

    $result = @{
        Path = $folder
        RelPath = $relPath
        TrackCount = $tracks.Count
        Issues = $issues
        NeedsUpdate = $needsUpdate
    }
    $auditResults += $result

    # Display per-album status
    if ($needsUpdate) {
        Write-Host "  [!!] $relPath ($($tracks.Count) tracks)" -ForegroundColor Yellow
        foreach ($issue in $issues) {
            Write-Host "       - $issue" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [OK] $relPath ($($tracks.Count) tracks)" -ForegroundColor Green
    }

    Write-Log "${relPath}: $(if ($needsUpdate) { 'FLAGGED' } else { 'OK' }) - $($issues -join ', ')"
}

# ========== STEP 3: COPY OR REPORT ==========
$flaggedResults = $auditResults | Where-Object { $_.NeedsUpdate }
$okCount = ($auditResults | Where-Object { -not $_.NeedsUpdate }).Count

if ($ReportOnly) {
    Write-Host "`n[STEP 3/4] Report (no copies)" -ForegroundColor Green
    Write-Log "STEP 3/4: Report only mode"

    # Write CSV report
    $csvPath = Join-Path $logDir "audit-metadata_${logTimestamp}.csv"
    $csvLines = @("Path,RelPath,TrackCount,Issues,NeedsUpdate")
    foreach ($r in $auditResults) {
        $issueStr = ($r.Issues -join "; ") -replace ',', ';'
        $csvLines += "`"$($r.Path)`",`"$($r.RelPath)`",$($r.TrackCount),`"$issueStr`",$($r.NeedsUpdate)"
    }
    $csvLines | Out-File -FilePath $csvPath -Encoding UTF8
    Write-Host "  CSV report: $csvPath" -ForegroundColor White
    Write-Log "CSV report written to $csvPath"
} else {
    if ($flaggedResults.Count -eq 0) {
        Write-Host "`n[STEP 3/4] No albums need updating - nothing to copy" -ForegroundColor Green
        Write-Log "STEP 3/4: No albums flagged - nothing to copy"
    } else {
        # Prompt before copying
        $copyConfirm = Read-TimedConfirmation -Prompt "$($flaggedResults.Count) albums flagged. Copy to staging? [Y/n] (auto-Yes in 30s)"
        Write-Log "Copy prompt: $(if ($copyConfirm) { 'Yes' } else { 'No' })"

        if (-not $copyConfirm) {
            Write-Host "`n  Stopped by user after audit." -ForegroundColor Yellow
            Write-Log "User declined copy - stopping after audit"
        } else {
            Write-Host "`n[STEP 3/4] Copying flagged albums to staging..." -ForegroundColor Green
            Write-Log "STEP 3/4: Copying flagged albums"

            if (!(Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

            $copiedCount = 0
            foreach ($r in $flaggedResults) {
                # Preserve Artist\Album structure
                $destPath = Join-Path $OutputPath $r.RelPath

                try {
                    if (Test-Path $destPath) {
                        Write-Host "  [--] $($r.RelPath) (already in staging)" -ForegroundColor Gray
                        Write-Log "Skipped copy (already exists): $($r.RelPath)"
                    } else {
                        $destParent = Split-Path -Parent $destPath
                        if (!(Test-Path $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
                        Copy-Item -Path $r.Path -Destination $destPath -Recurse -ErrorAction Stop
                        Write-Host "  [>>] $($r.RelPath)" -ForegroundColor Cyan
                        Write-Log "Copied: $($r.RelPath) -> $destPath"
                        $copiedCount++
                    }
                } catch {
                    Write-Host "  [!!] Failed to copy $($r.RelPath): $_" -ForegroundColor Red
                    Write-Log "ERROR copying $($r.RelPath): $_"
                }
            }

            Write-Host "`n  Copied $copiedCount album(s) to $OutputPath" -ForegroundColor White
            Write-Log "Copied $copiedCount albums to $OutputPath"

            # ========== STEP 4: PROCESS FLAGGED ALBUMS ==========
            $processConfirm = Read-TimedConfirmation -Prompt "Search & apply metadata to $($flaggedResults.Count) flagged albums? [Y/n] (auto-Yes in 30s)"
            Write-Log "Process prompt: $(if ($processConfirm) { 'Yes' } else { 'No' })"

            $processExitCode = $null
            if (-not $processConfirm) {
                Write-Host "`n  Stopped by user after copy." -ForegroundColor Yellow
                Write-Log "User declined processing - stopping after copy"
            } else {
                Write-Host "`n[STEP 4/4] Processing flagged albums with search-metadata..." -ForegroundColor Green
                Write-Log "STEP 4/4: Processing flagged albums"

                $searchScript = Join-Path $PSScriptRoot "search-metadata.ps1"
                if (-not (Test-Path $searchScript)) {
                    Write-Host "  ERROR: search-metadata.ps1 not found at $searchScript" -ForegroundColor Red
                    Write-Log "ERROR: search-metadata.ps1 not found at $searchScript"
                    $processExitCode = 1
                } else {
                    Write-Host "  Running: search-metadata.ps1 -Path `"$OutputPath`" -Recurse" -ForegroundColor Gray
                    Write-Log "Running: $searchScript -Path `"$OutputPath`" -Recurse"

                    $proc = Start-Process powershell.exe -ArgumentList @(
                        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $searchScript,
                        "-Path", $OutputPath, "-Recurse"
                    ) -Wait -PassThru -NoNewWindow

                    $processExitCode = $proc.ExitCode
                    Write-Log "search-metadata.ps1 exited with code $processExitCode"

                    if ($processExitCode -eq 0) {
                        Write-Host "`n  search-metadata completed successfully" -ForegroundColor Green
                    } else {
                        Write-Host "`n  search-metadata exited with code $processExitCode" -ForegroundColor Yellow
                    }
                }
            }
        }
    }
}

# ========== SUMMARY ==========
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "AUDIT COMPLETE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`n--- SUMMARY ---" -ForegroundColor Cyan
Write-Host "  Albums scanned: $($auditResults.Count)" -ForegroundColor White
Write-Host "  OK: $okCount" -ForegroundColor Green
Write-Host "  Flagged: $($flaggedResults.Count)" -ForegroundColor $(if ($flaggedResults.Count -gt 0) { "Yellow" } else { "Green" })
if (-not $ReportOnly -and $flaggedResults.Count -gt 0 -and $copyConfirm) {
    Write-Host "  Copied to: $OutputPath" -ForegroundColor White
}
if ($null -ne $processExitCode) {
    $processColor = if ($processExitCode -eq 0) { "Green" } else { "Yellow" }
    $processStatus = if ($processExitCode -eq 0) { "Success" } else { "Exited with code $processExitCode" }
    Write-Host "  Metadata processing: $processStatus" -ForegroundColor $processColor
}
Write-Host "  Log file: $($script:LogFile)" -ForegroundColor White

if ($flaggedResults.Count -gt 0) {
    Write-Host "`n--- FLAGGED ALBUMS ---" -ForegroundColor Yellow
    foreach ($r in $flaggedResults) {
        Write-Host "  $($r.RelPath)" -ForegroundColor Yellow
        foreach ($issue in $r.Issues) {
            Write-Host "    - $issue" -ForegroundColor Yellow
        }
    }
}

Write-Host "`n========================================`n" -ForegroundColor Cyan

$host.UI.RawUI.WindowTitle = "audit-metadata - DONE ($($flaggedResults.Count) flagged / $($auditResults.Count) scanned)"

Write-Log "========== AUDIT COMPLETE =========="
Write-Log "Scanned: $($auditResults.Count), OK: $okCount, Flagged: $($flaggedResults.Count)"
