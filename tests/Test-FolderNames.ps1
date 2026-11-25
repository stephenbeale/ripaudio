# Tests for album/artist folder names (2026-11-25, J.Lo - "J to tha L<U+2010>O! The Remixes"):
# MusicBrainz's title had a Unicode hyphen (U+2010). cyanrip gets its arguments in the ANSI
# code page, so it ripped into "J to tha L-O! The Remixes" while rip-audio.ps1 checked the
# U+2010 folder, found it empty and stopped with "cyanrip exited with code 0 but produced no
# audio files". The safe name must already be what cyanrip will see.
# Run: powershell -NoProfile -File tests\Test-FolderNames.ps1   (also under pwsh)

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
Import-Functions $rip @('ConvertTo-SafeFolderName')

function Test-IsAnsiSafe([string]$s) {
    $enc = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
    return ($enc.GetString($enc.GetBytes($s)) -ceq $s)
}

Write-Host "`nConvertTo-SafeFolderName" -ForegroundColor Cyan
$jlo = "J to tha L$([char]0x2010)O! The Remixes"
Assert-Equal 'the J.Lo title: U+2010 hyphen goes, like the ASCII one' 'J to tha LO! The Remixes' (ConvertTo-SafeFolderName $jlo)
Assert-Equal 'the J.Lo title is unchanged by the ANSI round trip (cyanrip sees the same name)' $true (Test-IsAnsiSafe (ConvertTo-SafeFolderName $jlo))
Assert-Equal 'non-breaking hyphen U+2011' 'AB' (ConvertTo-SafeFolderName "A$([char]0x2011)B")
Assert-Equal 'en dash (the old fix still holds)' 'Live  Tour' ((ConvertTo-SafeFolderName "Live $([char]0x2013) Tour") -replace ' ', '  ')
Assert-Equal 'em dash' 'AB' (ConvertTo-SafeFolderName "A$([char]0x2014)B")
Assert-Equal 'minus sign U+2212' 'AB' (ConvertTo-SafeFolderName "A$([char]0x2212)B")
Assert-Equal 'accents kept (they are in the code page)' "Beyonc$([char]0xE9)" (ConvertTo-SafeFolderName "Beyonc$([char]0xE9)")
Assert-Equal 'curly apostrophe result is what cyanrip sees' $true (Test-IsAnsiSafe (ConvertTo-SafeFolderName "Rock $([char]0x2019)n$([char]0x2019) Roll"))
Assert-Equal 'characters outside the code page are dropped, not passed on' 'Album' (ConvertTo-SafeFolderName "Album $([char]0x65E5)$([char]0x672C)")
Assert-Equal 'dots and illegal characters removed' 'REM Out of Time' (ConvertTo-SafeFolderName 'R.E.M: Out of Time?')
Assert-Equal 'spaces collapsed and trimmed' 'A B' (ConvertTo-SafeFolderName '  A    B  ')
Assert-Equal 'empty stays empty' '' (ConvertTo-SafeFolderName '')
Assert-Equal 'null stays empty' '' (ConvertTo-SafeFolderName $null)

Write-Host "`nrip-audio.ps1 uses it everywhere" -ForegroundColor Cyan
$text = [IO.File]::ReadAllText((Resolve-Path $rip))
Assert-Equal 'no inline copy of the old sanitiser left' 0 ([regex]::Matches($text, '\[\\u2013\\u2014\]')).Count
Assert-Equal 'album uses it' $true ($text.Contains('$safeAlbum = ConvertTo-SafeFolderName $album'))
Assert-Equal 'artist uses it' $true ($text.Contains('$safeArtist = ConvertTo-SafeFolderName $artist'))
Assert-Equal 'version suffix uses it' $true ($text.Contains('$safeSuffix = ConvertTo-SafeFolderName $suffix'))

Write-Host "`n$($script:Pass) passed, $($script:Fail) failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
