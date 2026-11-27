# Tests for Get-SiblingDiscTitles (2026-11-27, Pure Guitar Moods): MusicBrainz had the
# 4-disc release but only Disc 1's disc ID, so Discs 2-4 were "not found" and a name search
# tagged Disc 2 with a different album. Disc N now takes medium N of the release a sibling
# folder's .discid names, only when every track length matches.
# Run: powershell -NoProfile -File tests\Test-SiblingDisc.ps1   (also under pwsh)

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
Import-Functions (Join-Path $PSScriptRoot '..\rip-audio.ps1') @('Get-SiblingDiscTitles', 'ConvertFrom-CyanripArtist')
$script:CompilationArtist = 'Various'
$script:Logged = @()
function Write-Log($m) { $script:Logged += $m }

$rid = '59ebd7f1-f3e7-42f7-9bbd-7b8d99b4f4e3'
function New-Medium($pos, [string[]]$titles, [int[]]$secs) {
    $t = for ($i = 0; $i -lt $titles.Count; $i++) { [pscustomobject]@{ title = $titles[$i]; length = $secs[$i] * 1000 } }
    [pscustomobject]@{ position = $pos; tracks = @($t) }
}
$release = [pscustomobject]@{
    title = 'Pure Guitar Moods'
    'artist-credit' = @([pscustomobject]@{ name = '[unknown]'; joinphrase = '' })
    media = @(
        (New-Medium 1 @('Baker Street', 'Being With You', 'Bette Davis Eyes') @(200, 210, 220)),
        (New-Medium 2 @('I Got You Babe', 'I Just Called to Say I Love You', 'I Want to Know What Love Is') @(179, 257, 263)),
        (New-Medium 3 @('Maneater', 'Moonlighting', 'Nobody Does It Better') @(179, 257, 263))
    )
}
$script:Requests = @()
$req = { param($u) $script:Requests += $u; $release }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ripaudio-sib-" + [guid]::NewGuid().ToString('N'))
try {
    $d1 = Join-Path $tmp 'Pure Guitar Moods Disc 1'
    $d2 = Join-Path $tmp 'Pure Guitar Moods Disc 2'
    New-Item -ItemType Directory -Path $d1, $d2 -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $d1 '.discid') -Value @('# MusicBrainz Disc ID - do not edit', 'DISCID=kTPn', "RELEASEID=$rid")
    1..3 | ForEach-Object { 'x' | Set-Content -LiteralPath (Join-Path $d2 ("{0:D2} - Unknown track.flac" -f $_)) }
    $files = @(Get-ChildItem -LiteralPath $d2 -Filter *.flac)
    $lengths = @{ '01' = 179; '02' = 257; '03' = 264 }   # 1 s off on track 3: within tolerance
    $secs = { param($p) $lengths[(Split-Path $p -Leaf).Substring(0, 2)] }

    Write-Host "`nMatch" -ForegroundColor Cyan
    $r = Get-SiblingDiscTitles -OutputDir $d2 -Files $files -Request $req -GetSeconds $secs
    Assert-Equal 'disc number from the folder name' 2 $r.DiscNumber
    Assert-Equal 'titles from medium 2, not medium 1 or 3' 'I Got You Babe|I Just Called to Say I Love You|I Want to Know What Love Is' ($r.Tracks -join '|')
    Assert-Equal 'album' 'Pure Guitar Moods' $r.Album
    Assert-Equal '[unknown] credit becomes Various' 'Various' $r.Artist
    Assert-Equal 'release id' $rid $r.ReleaseId
    Assert-Equal 'one request, for the sibling release' 1 $script:Requests.Count

    Write-Host "`nNo match" -ForegroundColor Cyan
    $lengths['02'] = 240
    Assert-Equal 'a track 17 s off: not used' $true ($null -eq (Get-SiblingDiscTitles -OutputDir $d2 -Files $files -Request $req -GetSeconds $secs))
    $lengths['02'] = 257
    Assert-Equal 'unreadable length: not used' $true ($null -eq (Get-SiblingDiscTitles -OutputDir $d2 -Files $files -Request $req -GetSeconds { param($p) $null }))
    Assert-Equal 'wrong track count: not used' $true ($null -eq (Get-SiblingDiscTitles -OutputDir $d2 -Files @($files[0], $files[1]) -Request $req -GetSeconds $secs))
    Assert-Equal 'disc 4 not in the release: not used' $true ($null -eq (Get-SiblingDiscTitles -OutputDir $d2 -DiscNumber 4 -Files $files -Request $req -GetSeconds $secs))
    $solo = Join-Path $tmp 'Some Album'
    New-Item -ItemType Directory -Path $solo | Out-Null
    Assert-Equal 'folder without "Disc N": not used' $true ($null -eq (Get-SiblingDiscTitles -OutputDir $solo -Files $files -Request $req -GetSeconds $secs))
    $other = Join-Path $tmp 'Other Moods Disc 2'
    New-Item -ItemType Directory -Path $other | Out-Null
    Assert-Equal 'a different album''s Disc 1 is not a sibling' $true ($null -eq (Get-SiblingDiscTitles -OutputDir $other -Files $files -Request $req -GetSeconds $secs))
    Remove-Item -LiteralPath (Join-Path $d1 '.discid')
    $script:Requests = @()
    Assert-Equal 'sibling without RELEASEID: not used, no request' 'True 0' "$($null -eq (Get-SiblingDiscTitles -OutputDir $d2 -Files $files -Request $req -GetSeconds $secs)) $($script:Requests.Count)"

    Write-Host "`nBrackets in the folder name" -ForegroundColor Cyan
    $b1 = Join-Path $tmp 'Moods [FLAC] Disc 1'; $b2 = Join-Path $tmp 'Moods [FLAC] Disc 2'
    New-Item -ItemType Directory -Path $b1, $b2 -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $b1 '.discid') -Value "RELEASEID=$rid"
    1..3 | ForEach-Object { 'x' | Set-Content -LiteralPath (Join-Path $b2 ("{0:D2} - Unknown track.flac" -f $_)) }
    $bf = @(Get-ChildItem -LiteralPath $b2 -Filter *.flac)
    Assert-Equal 'bracketed album name still finds its Disc 1' 'I Got You Babe' (Get-SiblingDiscTitles -OutputDir $b2 -Files $bf -Request $req -GetSeconds $secs).Tracks[0]
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nGet-MusicBrainzAttachUrl" -ForegroundColor Cyan
Import-Functions (Join-Path $PSScriptRoot '..\rip-audio.ps1') @('Get-MusicBrainzAttachUrl')
# Disc 2 of Pure Guitar Moods: real cyanrip log values (DiscID and LSNs); the URL was
# recomputes to the same disc ID.
$lsn = @(0, 13492, 32810, 52576, 72021, 87782, 103789, 122742, 139051, 159557)
$log = @('cyanrip 0.9.3 (063d848)', 'DiscID:         SsOYIJMr_uFO1VRQS90fpPiMUA8-', 'Tracks:')
for ($i = 0; $i -lt 10; $i++) {
    $end = if ($i -lt 9) { $lsn[$i + 1] - 1 } else { 175074 }
    $log += "    Pregap LSN:  none", "    Start LSN:   $($lsn[$i])", "    End LSN:     $end"
}
Assert-Equal 'Disc 2 link' 'https://musicbrainz.org/cdtoc/attach?id=SsOYIJMr_uFO1VRQS90fpPiMUA8-&tracks=10&toc=1+10+175225+150+13642+32960+52726+72171+87932+103939+122892+139201+159707' (Get-MusicBrainzAttachUrl -LogLines $log)
$bad = $log -replace 'End LSN:     175074', 'End LSN:     175000'
Assert-Equal 'a TOC that does not give the disc ID: no link' $true ($null -eq (Get-MusicBrainzAttachUrl -LogLines $bad))
Assert-Equal 'no DiscID line: no link' $true ($null -eq (Get-MusicBrainzAttachUrl -LogLines ($log | Where-Object { $_ -notmatch '^DiscID' })))

Write-Host "`n$script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
