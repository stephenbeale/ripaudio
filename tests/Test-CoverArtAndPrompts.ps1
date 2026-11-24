# Tests for rip-audio.ps1:
#   - Get-ArtSearchAlbum / Test-AlbumTitleMatch: cover searches drop " Disc N" and only
#     take a hit whose album name matches (2026-11-24: Neil Diamond got "Acoustic Christmas")
#   - Read-ChoiceWithTimeout: the busy-MusicBrainz C/R/Q prompt picks its default
# Run: powershell -NoProfile -File tests\Test-CoverArtAndPrompts.ps1 [-Live]
# -Live also asks iTunes for The Essential Neil Diamond (network).
param([switch]$Live)

$ErrorActionPreference = 'Stop'
$script:Pass = 0; $script:Fail = 0
function Assert-Equal($Name, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL $Name - expected '$Expected', got '$Actual'" -ForegroundColor Red }
}

$scriptPath = Join-Path $PSScriptRoot '..\rip-audio.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
$wanted = 'Get-ArtSearchAlbum', 'Test-AlbumTitleMatch', 'Read-ChoiceWithTimeout'
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Write-Log { param($m) }

Write-Host "`nGet-ArtSearchAlbum" -ForegroundColor Cyan
Assert-Equal 'Disc 2 suffix dropped' 'The Essential Neil Diamond' (Get-ArtSearchAlbum 'The Essential Neil Diamond Disc 2')
Assert-Equal 'CD 1 suffix dropped' 'Greatest Hits' (Get-ArtSearchAlbum 'Greatest Hits CD 1')
Assert-Equal 'no suffix: unchanged' 'Back to Black' (Get-ArtSearchAlbum 'Back to Black')
Assert-Equal 'a word ending in "disc" is kept' 'Discography' (Get-ArtSearchAlbum 'Discography')

Write-Host "`nTest-AlbumTitleMatch" -ForegroundColor Cyan
Assert-Equal 'the wrong album is refused (real 2026-11-24 hit)' $false (Test-AlbumTitleMatch -Found 'Acoustic Christmas' -Wanted 'The Essential Neil Diamond')
Assert-Equal 'same name matches' $true (Test-AlbumTitleMatch -Found 'The Essential Neil Diamond' -Wanted 'The Essential Neil Diamond')
Assert-Equal 'case and punctuation ignored' $true (Test-AlbumTitleMatch -Found 'Back To Black' -Wanted 'back to black')
Assert-Equal 'edition note in brackets ignored' $true (Test-AlbumTitleMatch -Found 'Back to Black (Deluxe Edition)' -Wanted 'Back to Black')
Assert-Equal 'longer title containing the album' $true (Test-AlbumTitleMatch -Found 'The Essential Neil Diamond - Remastered' -Wanted 'The Essential Neil Diamond')
Assert-Equal 'short names must be equal' $false (Test-AlbumTitleMatch -Found 'Hits of the 80s' -Wanted 'Hits')
Assert-Equal 'empty is never a match' $false (Test-AlbumTitleMatch -Found '' -Wanted 'Album')

Write-Host "`nRead-ChoiceWithTimeout (input redirected: falls back to Read-Host)" -ForegroundColor Cyan
$script:Answer = ''
function Read-Host { param($p) $script:Answer }
Assert-Equal 'Enter takes the default' 'C' (Read-ChoiceWithTimeout -Prompt 'Choice (C/r/q)' -Keys 'C','R','Q' -Default 'C')
$script:Answer = 'r'
Assert-Equal 'a typed answer is returned' 'r' (Read-ChoiceWithTimeout -Prompt 'Choice (C/r/q)' -Keys 'C','R','Q' -Default 'C')
$text = [IO.File]::ReadAllText((Resolve-Path $scriptPath))
Assert-Equal 'both busy prompts use the 30s countdown' 2 ([regex]::Matches($text, 'Read-ChoiceWithTimeout -Prompt "Choice \(C/r/q\)"')).Count
Assert-Equal 'default wait is 30s' $true ($text -match '\[int\]\$Seconds = 30')

if ($Live) {
    Write-Host "`niTunes live: The Essential Neil Diamond Disc 2" -ForegroundColor Cyan
    $q = [uri]::EscapeDataString("Neil Diamond $(Get-ArtSearchAlbum 'The Essential Neil Diamond Disc 2')")
    $r = Invoke-RestMethod "https://itunes.apple.com/search?term=$q&media=music&entity=album&limit=10" -TimeoutSec 10
    $hit = @($r.results) | Where-Object { Test-AlbumTitleMatch -Found $_.collectionName -Wanted 'The Essential Neil Diamond' } | Select-Object -First 1
    Write-Host "    first raw hit: $(@($r.results)[0].collectionName); picked: $($hit.collectionName)" -ForegroundColor Gray
    Assert-Equal 'picked hit is not Acoustic Christmas' $true ($null -eq $hit -or $hit.collectionName -notmatch 'Christmas')
}

Write-Host "`n$($script:Pass) passed, $($script:Fail) failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $script:Fail
