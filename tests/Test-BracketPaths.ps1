# Tests for square brackets in artist/album names (2026-11-27, Pure Guitar Moods Disc 1):
# cyanrip printed "Album artist: [unknown]" for a compilation with no album artist. The rip
# went to G:\Music\[unknown]\..., and because PowerShell reads [..] in -Path as a wildcard,
# every Write-Log failed (log file "does not exist") and Push-Location failed.
# Fixes: "[unknown]" becomes Various Artists; path cmdlets use -LiteralPath.
# Run: powershell -NoProfile -File tests\Test-BracketPaths.ps1   (also under pwsh)

$ErrorActionPreference = 'Stop'
$script:Pass = 0; $script:Fail = 0
function Assert-Equal($Name, $Expected, $Actual) {
    if ("$Expected" -ceq "$Actual") { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL $Name - expected '$Expected', got '$Actual'" -ForegroundColor Red }
}
function Import-Functions([string]$Path, [string[]]$Names) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Path), [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $Names }, $true)) {
        . ([scriptblock]::Create($fn.Extent.Text))
        Set-Item -Path "function:script:$($fn.Name)" -Value (Get-Item "function:$($fn.Name)").ScriptBlock
    }
}
$root = Join-Path $PSScriptRoot '..'
Import-Functions (Join-Path $root 'rip-audio.ps1') @('ConvertFrom-CyanripArtist')
$script:CompilationArtist = 'Various'

Write-Host "`nConvertFrom-CyanripArtist" -ForegroundColor Cyan
Assert-Equal 'cyanrip "[unknown]" is a compilation' 'Various' (ConvertFrom-CyanripArtist '[unknown]')
Assert-Equal '"unknown" without brackets too' 'Various' (ConvertFrom-CyanripArtist ' Unknown ')
Assert-Equal 'a real artist is kept, trimmed' 'Mark Knopfler' (ConvertFrom-CyanripArtist ' Mark Knopfler ')
Assert-Equal 'a band with "unknown" in the name is kept' 'Origin Unknown' (ConvertFrom-CyanripArtist 'Origin Unknown')
Assert-Equal 'empty is no artist' $true ($null -eq (ConvertFrom-CyanripArtist ''))

Write-Host "`nNo wildcard -Path calls on file system paths" -ForegroundColor Cyan
$cmdlets = 'Add-Content|Get-Content|Set-Content|Copy-Item|Rename-Item|Remove-Item|Get-ChildItem|Test-Path|Get-Item|Push-Location'
foreach ($f in 'rip-audio.ps1', 'continue-rip-audio.ps1', 'get-metadata.ps1', 'search-metadata.ps1', 'audit-metadata.ps1', 'undo-metadata.ps1') {
    $bad = @(Get-Content -LiteralPath (Join-Path $root $f) | Where-Object {
        $_ -notmatch '^\s*#' -and $_ -match "\b($cmdlets)\s+(-Path\s+)?[\`$(]" -and $_ -notmatch 'Join-Path \$FolderPath "\*"'
    })
    Assert-Equal "$f uses -LiteralPath" 0 $bad.Count
    $bad | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
    # -LiteralPath + -Include is ignored by Windows PowerShell 5.1 with -Recurse (it returned
    # cover art as "stale audio"), and never matches without -Recurse.
    $inc = @(Get-Content -LiteralPath (Join-Path $root $f) | Where-Object { $_ -match '-LiteralPath.*-Include' })
    Assert-Equal "$f has no -LiteralPath with -Include" 0 $inc.Count
}

Write-Host "`nBracket folders work end to end" -ForegroundColor Cyan
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ripaudio-test-" + [guid]::NewGuid().ToString('N'))
$dir = Join-Path $tmp '[unknown]\Pure Guitar Moods [FLAC] Disc 1'
try {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    'x' | Set-Content -LiteralPath (Join-Path $dir '1.01 - Baker Street.flac')
    'x' | Set-Content -LiteralPath (Join-Path $dir 'Front.jpg')
    $log = Join-Path $tmp '[unknown]_Pure Guitar Moods Disc 1.log'
    Add-Content -LiteralPath $log -Value 'line'
    Assert-Equal 'log file with brackets is written' $true (Test-Path -LiteralPath $log)
    $audio = @(Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $_.Extension -in @('.flac', '.mp3') })
    Assert-Equal 'audio listing finds only the flac' 1 $audio.Count
    $art = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.BaseName -in @('Front', 'Cover', 'Folder') })
    Assert-Equal 'cover art is found' 1 $art.Count
    Push-Location -LiteralPath (Split-Path $dir)
    Assert-Equal 'Push-Location into a bracket folder' (Split-Path $dir -Leaf) ((Get-ChildItem -Directory | Select-Object -First 1).Name)
    Pop-Location
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n$script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
