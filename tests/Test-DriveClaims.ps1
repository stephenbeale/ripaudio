# Tests for drive claims (2026-11-27): a rip that had just picked a drive did not show it
# as busy until cyanrip started (after prompts, lookup and countdown), so a second rip
# started straight after picked the same drive. The drive is now claimed when picked.
# Run: powershell -NoProfile -File tests\Test-DriveClaims.ps1   (also under pwsh)

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
Import-Functions $rip @('Get-ProcessStartStamp', 'Get-DriveClaims', 'Set-DriveClaim', 'Remove-DriveClaim')

$dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ripaudio-claims-" + [guid]::NewGuid().ToString('N'))
try {
    Write-Host "`nSet / read / remove" -ForegroundColor Cyan
    Set-DriveClaim -DriveLetter 'f:' -Dir $dir
    Assert-Equal 'claim file is named by the upper-case letter' $true (Test-Path -LiteralPath (Join-Path $dir 'F.claim'))
    Assert-Equal 'own claim is not "busy" for this process' 0 (Get-DriveClaims -Dir $dir).Count
    $other = Get-DriveClaims -Dir $dir -Self 0
    Assert-Equal 'another process sees F: as claimed' 'F:' (@($other.Keys) -join ',')
    Assert-Equal 'claim shows "ripaudio" and no album yet' 'ripaudio|' "$($other['F:'].Tool)|$($other['F:'].Album)"
    Set-DriveClaim -DriveLetter 'F:' -Album 'Various - Pure Guitar Moods Disc 4' -Dir $dir
    Assert-Equal 'album added once known' 'Various - Pure Guitar Moods Disc 4' (Get-DriveClaims -Dir $dir -Self 0)['F:'].Album
    Remove-DriveClaim -DriveLetter 'F:' -Dir $dir
    Assert-Equal 'removed by its owner' $false (Test-Path -LiteralPath (Join-Path $dir 'F.claim'))

    Write-Host "`nOther owners and stale claims" -ForegroundColor Cyan
    Set-Content -LiteralPath (Join-Path $dir 'D.claim') -Value @('Pid=4242', 'ProcessStart=2026-11-27T08:00:00', 'Claimed=08:00', 'Tool=ripaudio', 'Album=')
    $live = { param($id) if ($id -eq 4242) { '2026-11-27T08:00:00' } }
    Assert-Equal 'live claim from another window is busy' 'D:' (@((Get-DriveClaims -Dir $dir -GetStamp $live).Keys) -join ',')
    Remove-DriveClaim -DriveLetter 'D:' -Dir $dir
    Assert-Equal 'not removed by a process that does not own it' $true (Test-Path -LiteralPath (Join-Path $dir 'D.claim'))
    $reused = { param($id) '2026-11-27T09:30:00' }
    Assert-Equal 'process id reused by another program: stale, ignored' 0 (Get-DriveClaims -Dir $dir -GetStamp $reused).Count
    Assert-Equal 'stale claim file deleted' $false (Test-Path -LiteralPath (Join-Path $dir 'D.claim'))
    Set-Content -LiteralPath (Join-Path $dir 'G.claim') -Value @('Pid=4243', 'ProcessStart=x')
    Assert-Equal 'owner gone: stale' 0 (Get-DriveClaims -Dir $dir -GetStamp { param($id) $null }).Count
    Set-Content -LiteralPath (Join-Path $dir 'H.claim') -Value 'garbage'
    Assert-Equal 'unreadable claim ignored' 0 (Get-DriveClaims -Dir $dir).Count
    Assert-Equal 'no claim folder: nothing claimed' 0 (Get-DriveClaims -Dir (Join-Path $dir 'missing')).Count
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nScript wiring" -ForegroundColor Cyan
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $rip), [ref]$null, [ref]$null)
$top = $ast.EndBlock.Statements
$tryStmt = $top | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] -and $_.Finally -and $_.Finally.Extent.Text -match 'Remove-DriveClaim' } | Select-Object -First 1
Assert-Equal 'a top-level try/finally releases the claim' $true ($null -ne $tryStmt)
Assert-Equal 'that try/finally is the last statement (covers every exit)' $true ($top[-1] -eq $tryStmt)
$claimIdx = [array]::IndexOf(@($top), ($top | Where-Object { $_.Extent.Text -match 'Set-DriveClaim -DriveLetter \$driveLetter' } | Select-Object -First 1))
Assert-Equal 'claim is made right before that try' $true ($claimIdx -ge 0 -and $top[$claimIdx + 1] -eq $tryStmt)
$text = Get-Content -LiteralPath $rip -Raw
Assert-Equal 'claimed drives are added to the busy list' $true ($text -match 'foreach \(\$claimed in \$script:DriveClaims\.Keys\)')

Write-Host "`n$script:Pass passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
