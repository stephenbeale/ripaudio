# Tests for local staging (2026-11-27): the PC was turned off mid-rip and every FLAC on the
# USB output drive was 0 bytes, so nothing could be resumed. cyanrip now writes to a local
# staging folder and each finished track is saved (copied, flushed) to the output at once.
# Also the resume scan's note telling empty files (stopped rip) from damaged ones.
# Run: powershell -NoProfile -File tests\Test-Staging.ps1   (also under pwsh)

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
$rip = Join-Path $PSScriptRoot '..\rip-audio.ps1'
Import-Functions $rip @('Get-RipStagingRoot', 'Get-AudioFileTrackNumber', 'Save-FileDurably', 'Move-StagedTrack', 'Move-AllStagedFiles', 'Get-InvalidTrackNote')
$script:AudioExtensions = @(".flac", ".mp3", ".opus", ".m4a", ".wav", ".aac")
# Stand-in for the flac decoder check: a "good" track is any file over 100 bytes.
function Test-TrackIntegrity { param([string]$FilePath) (Get-Item -LiteralPath $FilePath).Length -gt 100 }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ripaudio-staging-test-" + [guid]::NewGuid().ToString('N'))
function New-File([string]$Path, [int]$Size) {
    $d = Split-Path -Parent $Path; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, [byte[]]::new($Size))
}
try {
    Write-Host "`nStaging root" -ForegroundColor Cyan
    $a = Get-RipStagingRoot -FinalOutputDir 'G:\Music\The Chieftains\The Long Black Veil' -BaseDir 'C:\stage'
    $b = Get-RipStagingRoot -FinalOutputDir 'g:\music\the chieftains\the long black veil\' -BaseDir 'C:\stage'
    $c = Get-RipStagingRoot -FinalOutputDir 'G:\Music\Other\Album' -BaseDir 'C:\stage'
    Assert-Equal 'same folder (case, trailing slash) gives the same staging root' $a $b
    Assert-Equal 'another album gets its own root' $true ($a -ne $c)
    Assert-Equal 'root sits under the base folder' $true ($a.StartsWith('C:\stage\'))

    Write-Host "`nTrack numbers from file names" -ForegroundColor Cyan
    Assert-Equal '"08 - Dunmore Lassies.flac"' 8 (Get-AudioFileTrackNumber -Name '08 - Dunmore Lassies.flac')
    Assert-Equal '"1.05 - X.flac" (multi-disc)' 5 (Get-AudioFileTrackNumber -Name '1.05 - X.flac')
    Assert-Equal 'other disc ignored under -DiscNum' '' (Get-AudioFileTrackNumber -Name '2.05 - X.flac' -DiscNum 1)
    Assert-Equal 'bare name ignored under -DiscNum' '' (Get-AudioFileTrackNumber -Name '05 - X.flac' -DiscNum 1)
    Assert-Equal 'cover art has no number' '' (Get-AudioFileTrackNumber -Name 'Cover.jpg')

    Write-Host "`nSave one finished track" -ForegroundColor Cyan
    $stage = Join-Path $tmp 'stage'; $final = Join-Path $tmp 'final'
    $album = 'The Long Black Veil'
    New-File (Join-Path $stage "$album\01 - Mo Ghile Mear.flac") 500
    New-File (Join-Path $stage "$album\02 - The Long Black Veil.flac") 300
    # Leftovers in the output from the stopped run: an empty file for track 1 under an
    # older title, and a good unrelated track 3 that must stay.
    New-File (Join-Path $final "$album\01 - Mo Ghile Mear (Our Hero).flac") 0
    New-File (Join-Path $final "$album\03 - The Foggy Dew.flac") 400
    $saved = @(Move-StagedTrack -StagingRoot $stage -FinalRoot $final -TrackNum 1)
    Assert-Equal 'track 1 saved' "$album\01 - Mo Ghile Mear.flac" ($saved -join ',')
    Assert-Equal 'track 1 now in the output, full size' 500 (Get-Item -LiteralPath (Join-Path $final "$album\01 - Mo Ghile Mear.flac")).Length
    Assert-Equal 'track 1 removed from staging' $false (Test-Path -LiteralPath (Join-Path $stage "$album\01 - Mo Ghile Mear.flac"))
    Assert-Equal 'empty old track 1 removed' $false (Test-Path -LiteralPath (Join-Path $final "$album\01 - Mo Ghile Mear (Our Hero).flac"))
    Assert-Equal 'good track 3 untouched' 400 (Get-Item -LiteralPath (Join-Path $final "$album\03 - The Foggy Dew.flac")).Length
    Assert-Equal 'track 2 still waiting in staging' $true (Test-Path -LiteralPath (Join-Path $stage "$album\02 - The Long Black Veil.flac"))
    Assert-Equal 'no .partial left behind' 0 @(Get-ChildItem -LiteralPath $final -Recurse -Filter '*.partial').Count

    Write-Host "`nA track that fails the check stays in staging" -ForegroundColor Cyan
    New-File (Join-Path $stage "$album\04 - Half.flac") 50
    $saved = @(Move-StagedTrack -StagingRoot $stage -FinalRoot $final -TrackNum 4)
    Assert-Equal 'nothing saved' 0 $saved.Count
    Assert-Equal 'still in staging' $true (Test-Path -LiteralPath (Join-Path $stage "$album\04 - Half.flac"))
    Remove-Item -LiteralPath (Join-Path $stage "$album\04 - Half.flac")

    Write-Host "`nReplaces an existing same-name file" -ForegroundColor Cyan
    New-File (Join-Path $final "$album\02 - The Long Black Veil.flac") 0
    [void](Move-StagedTrack -StagingRoot $stage -FinalRoot $final -TrackNum 2)
    Assert-Equal 'empty same-name file replaced' 300 (Get-Item -LiteralPath (Join-Path $final "$album\02 - The Long Black Veil.flac")).Length

    Write-Host "`nEnd-of-run sweep" -ForegroundColor Cyan
    New-File (Join-Path $stage "$album\$album.cue") 120
    New-File (Join-Path $stage "$album\$album.log") 130
    $n = Move-AllStagedFiles -StagingRoot $stage -FinalRoot $final
    Assert-Equal 'cue and log moved' 2 $n
    Assert-Equal 'cue in the output' $true (Test-Path -LiteralPath (Join-Path $final "$album\$album.cue"))
    Assert-Equal 'staging root removed' $false (Test-Path -LiteralPath $stage)
    Assert-Equal 'sweep of a missing root is a no-op' 0 (Move-AllStagedFiles -StagingRoot $stage -FinalRoot $final)

    Write-Host "`nNote for rejected files" -ForegroundColor Cyan
    $note = @(Get-InvalidTrackNote -EmptyCount 9 -BrokenCount 0)
    Assert-Equal 'only the empty line' 1 $note.Count
    Assert-Equal 'says empty, 0 bytes, stopped' $true ($note[0] -match '9 file\(s\) are empty \(0 bytes\).*stopped')
    $note = @(Get-InvalidTrackNote -EmptyCount 2 -BrokenCount 1)
    Assert-Equal 'both lines' 2 $note.Count
    Assert-Equal 'damaged line' $true ($note[1] -match '1 file\(s\) are there but fail the FLAC check')
    Assert-Equal 'nothing rejected: no lines' 0 @(Get-InvalidTrackNote -EmptyCount 0 -BrokenCount 0).Count
    Write-Host "`nContinue command after a failure" -ForegroundColor Cyan
    Import-Functions $rip @('Get-ContinueRipAudioArgs', 'Format-ContinueRipAudioCommand')
    $ca = Get-ContinueRipAudioArgs -SafeAlbum 'The Long Black Veil' -SafeArtist 'The Chieftains' -FromStep 1 -DriveLetter 'D:' -OutputDriveLetter 'G:' -Format 'flac'
    Assert-Equal 'keys in order' 'Album,Artist,FromStep,Drive,OutputDrive,format' (@($ca.Keys) -join ',')
    Assert-Equal 'command line' ".\continue-rip-audio.ps1 -Album 'The Long Black Veil' -Artist 'The Chieftains' -FromStep 1 -Drive D: -OutputDrive G: -format flac" (Format-ContinueRipAudioCommand -ScriptPath 'C:\x\continue-rip-audio.ps1' -ArgList $ca)
    $ca = Get-ContinueRipAudioArgs -SafeAlbum "Rock'n Roll" -FromStep 3 -DriveLetter 'D:\' -OutputDriveLetter 'F:' -Quality 320 -ParanoiaLevel 1 -Retries 5
    Assert-Equal 'no artist, extras kept, trailing slash dropped' 'Album,FromStep,Drive,OutputDrive,format,Quality,ParanoiaLevel,Retries|D:' "$(@($ca.Keys) -join ',')|$($ca.Drive)"
    Assert-Equal 'apostrophe quoted' $true ((Format-ContinueRipAudioCommand -ScriptPath 'c.ps1' -ArgList $ca) -match "-Album 'Rock''n Roll'")
    Assert-Equal 'no album: no command' '' (Get-ContinueRipAudioArgs -SafeAlbum '')
    # The splat must only use parameters continue-rip-audio.ps1 has.
    $contAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path (Join-Path $PSScriptRoot '..\continue-rip-audio.ps1')), [ref]$null, [ref]$null)
    $contParams = @($contAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $missing = @($ca.Keys + 'Artist' | Where-Object { $_ -notin $contParams })
    Assert-Equal 'every key is a continue-rip-audio.ps1 parameter' '' ($missing -join ',')

    Write-Host "`ncontinue-rip-audio.ps1 has the same staging helpers" -ForegroundColor Cyan
    $ripAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $rip), [ref]$null, [ref]$null)
    foreach ($name in 'Get-RipStagingRoot', 'Get-AudioFileTrackNumber', 'Save-FileDurably', 'Move-StagedTrack', 'Move-AllStagedFiles') {
        $r = $ripAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
        $c = $contAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
        Assert-Equal "$name identical" $true ($c -and ($r.Extent.Text -replace '\r', '') -ceq ($c.Extent.Text -replace '\r', ''))
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n$script:Pass passed, $script:Fail failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
