# Tests for the busy-MusicBrainz paths in rip-audio.ps1:
#   - Get-ReleasePickerDetails: one disc ID request for the release picker
#   - Get-ReleaseDiscMedium / Get-ReleaseDiscTitles: this disc's medium and names
# Run: powershell -NoProfile -File tests\Test-MbFallbackLookups.ps1

$ErrorActionPreference = 'Stop'
$script:Pass = 0; $script:Fail = 0
function Assert-Equal($Name, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:Pass++; Write-Host "  PASS $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL $Name - expected '$Expected', got '$Actual'" -ForegroundColor Red }
}

# Load just the functions under test from rip-audio.ps1 (the script itself runs a rip)
$scriptPath = Join-Path $PSScriptRoot '..\rip-audio.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
$wanted = 'Get-ReleasePickerDetails', 'Get-ReleaseDiscMedium', 'Get-ReleaseDiscTitles'
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Write-Log { param($m) }

Write-Host "`nGet-ReleasePickerDetails" -ForegroundColor Cyan
function New-Release($Id, $Discs) {
    [pscustomobject]@{ id = $Id; title = "Album $Id"; 'artist-credit' = @([pscustomobject]@{ name = 'Artist'; joinphrase = '' })
        media = @(foreach ($d in $Discs) { [pscustomobject]@{ position = $d.Pos; 'track-count' = $d.Titles.Count
            discs = @($d.Ids | ForEach-Object { [pscustomobject]@{ id = $_ } }); tracks = @($d.Titles | ForEach-Object { [pscustomobject]@{ title = $_ } }) } }) }
}
$relA = New-Release 'a' @(@{ Pos = 1; Ids = @('DISC1'); Titles = @('One', 'Two') }, @{ Pos = 2; Ids = @('DISC2'); Titles = @('Three', 'Four', 'Five') })
$relB = New-Release 'b' @(@{ Pos = 1; Ids = @('DISC1'); Titles = @('One', 'Two') })

$calls = [System.Collections.ArrayList]::new()
$bulkOk = { param($u, $d) [void]$calls.Add($u); if ($u -like '*discid/*') { [pscustomobject]@{ releases = @($relA, $relB) } } else { throw 'should not be called' } }
$details = Get-ReleasePickerDetails -DiscId 'DISC1' -ReleaseIds @('a', 'b') -Request $bulkOk
Assert-Equal 'one request covers every release' 1 $calls.Count
Assert-Equal 'both releases returned' 'a,b' (($details.Keys | Sort-Object) -join ',')

$calls.Clear()
$bulkPartial = { param($u, $d) [void]$calls.Add($u); if ($u -like '*discid/*') { [pscustomobject]@{ releases = @($relA) } } else { $relB } }
$details = Get-ReleasePickerDetails -DiscId 'DISC1' -ReleaseIds @('a', 'b') -Request $bulkPartial
Assert-Equal 'missing release fetched on its own' 2 $calls.Count
Assert-Equal 'per-release fetch uses one short retry' $true ($calls[1] -like '*release/b*')

$calls.Clear()
$retries = [System.Collections.ArrayList]::new()
$allBusy = { param($u, $d) [void]$calls.Add($u); [void]$retries.Add(($d -join '/')); throw '503' }
$details = Get-ReleasePickerDetails -DiscId 'DISC1' -ReleaseIds @('a', 'b', 'c', 'd') -Request $allBusy *>$null
Assert-Equal 'busy: bulk + first release only, then stops' 2 $calls.Count
Assert-Equal 'busy: retry budgets (bulk 2/4, release 2)' '2/4,2' ($retries -join ',')
Assert-Equal 'busy: no details' 0 $details.Count

Write-Host "`nGet-ReleaseDiscMedium / Get-ReleaseDiscTitles" -ForegroundColor Cyan
Assert-Equal 'disc 2 picks the medium listing its disc ID' 2 (Get-ReleaseDiscMedium -Release $relA -DiscId 'DISC2').position
Assert-Equal 'unknown disc ID falls back to track count' 2 (Get-ReleaseDiscMedium -Release $relA -DiscId 'X' -TrackCount 3).position
Assert-Equal 'no fit on a two-disc release is $null' $true ($null -eq (Get-ReleaseDiscMedium -Release $relA -DiscId 'X' -TrackCount 9))
$titles = Get-ReleaseDiscTitles -Release $relA -DiscId 'DISC2'
Assert-Equal 'titles for disc 2' 'Three|Four|Five' ($titles.Tracks -join '|')
Assert-Equal 'album' 'Album a' $titles.Album

Write-Host "`n$($script:Pass) passed, $($script:Fail) failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $script:Fail
