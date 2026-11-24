# Tests for single-digit track numbers (2026-11-24, Dire Straits - Brothers in Arms):
# cyanrip names files "1 - Unknown track.flac" (no leading zero) on discs with 9 or fewer
# tracks. rip-audio.ps1 only read two-digit numbers, so every file was tagged track 1/9,
# and search-metadata.ps1 then sorted by that tag and gave each title to the wrong file.
# Run: powershell -NoProfile -File tests\Test-TrackNumbers.ps1

$ErrorActionPreference = 'Stop'
$script:Pass = 0; $script:Fail = 0
function Assert-Equal($Name, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL $Name - expected '$Expected', got '$Actual'" -ForegroundColor Red }
}
function Import-Functions([string]$Path, [string[]]$Names) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Path), [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $Names }, $true)) {
        . ([scriptblock]::Create($fn.Extent.Text))
        Set-Item -Path "function:script:$($fn.Name)" -Value (Get-Item "function:$($fn.Name)").ScriptBlock
    }
}
function Write-Log { param($m) }
$rip = Join-Path $PSScriptRoot '..\rip-audio.ps1'
$search = Join-Path $PSScriptRoot '..\search-metadata.ps1'
Import-Functions $rip @('Test-GenericTrackName')
Import-Functions $search @('Get-TrackOrder')

Write-Host "`nTest-GenericTrackName (rip-audio.ps1)" -ForegroundColor Cyan
Assert-Equal 'single-digit cyanrip -N name is generic' $true (Test-GenericTrackName '1 - Unknown track')
Assert-Equal 'two-digit name still generic' $true (Test-GenericTrackName '01 - Unknown track')
Assert-Equal 'bare single digit is generic' $true (Test-GenericTrackName '7')
Assert-Equal 'a real title is not generic' $false (Test-GenericTrackName '1 - So Far Away')

Write-Host "`nTrack number patterns in rip-audio.ps1" -ForegroundColor Cyan
$text = [IO.File]::ReadAllText((Resolve-Path $rip))
Assert-Equal 'no two-digit-only track parse left' 0 ([regex]::Matches($text, "BaseName -match '\^\(\\d\{2\}\)'")).Count
$pattern = '^(\d{1,2})(?=\s*-\s|$)'
Assert-Equal 'pattern reads 1 from "1 - Unknown track"' '1' $(if ('1 - Unknown track' -match $pattern) { $Matches[1] })
Assert-Equal 'pattern reads 12 from "12 - Title"' '12' $(if ('12 - Title' -match $pattern) { $Matches[1] })
Assert-Equal 'multi-disc "2-01 - Title" is not read as track 2' $false ('2-01 - Title' -match $pattern)
Assert-Equal 'new names are zero-padded' $true ($text.Contains('"{0:D2} - {1}{2}" -f [int]$Matches[1], $trackTitle, $track.Extension'))

Write-Host "`nGet-TrackOrder (search-metadata.ps1)" -ForegroundColor Cyan
# The real case: files 1..9 all tagged TRACKNUMBER=1, listed in a shuffled order
$shuffled = @(7, 6, 9, 8, 5, 2, 1, 4, 3 | ForEach-Object { @{ FileName = "$_ - Unknown track.flac"; TrackNumber = '1' } })
Assert-Equal 'repeated tags: file name order' '1,2,3,4,5,6,7,8,9' ((Get-TrackOrder -Tracks $shuffled | ForEach-Object { $_.FileName.Split(' ')[0] }) -join ',')
$tagged = @(@{ FileName = 'b.flac'; TrackNumber = '2/3' }, @{ FileName = 'c.flac'; TrackNumber = '3/3' }, @{ FileName = 'a.flac'; TrackNumber = '1/3' })
Assert-Equal 'unique tags: tag order' 'a.flac,b.flac,c.flac' ((Get-TrackOrder -Tracks $tagged | ForEach-Object { $_.FileName }) -join ',')
$mixed = @(@{ FileName = '10 - x.flac'; TrackNumber = '' }, @{ FileName = '2 - y.flac'; TrackNumber = '' }, @{ FileName = '1 - z.flac'; TrackNumber = '' })
Assert-Equal 'no tags: numeric file name order (2 before 10)' '1 - z.flac,2 - y.flac,10 - x.flac' ((Get-TrackOrder -Tracks $mixed | ForEach-Object { $_.FileName }) -join ',')
$partial = @(@{ FileName = '02 - b.flac'; TrackNumber = '2' }, @{ FileName = '01 - a.flac'; TrackNumber = '' })
Assert-Equal 'some tags missing: file name order' '01 - a.flac,02 - b.flac' ((Get-TrackOrder -Tracks $partial | ForEach-Object { $_.FileName }) -join ',')

Write-Host "`n$($script:Pass) passed, $($script:Fail) failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $script:Fail
