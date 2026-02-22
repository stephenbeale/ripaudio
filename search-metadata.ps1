param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [Parameter()]
    [string]$Artist = "",

    [Parameter()]
    [string]$Album = "",

    [Parameter()]
    [switch]$SkipRename,

    [Parameter()]
    [switch]$SkipCoverArt,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$Recurse,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$EmbedOnly
)

# ========== STEP TRACKING ==========
$script:AllSteps = @(
    @{ Number = 1; Name = "Scan files"; Description = "Read existing tags and identify gaps" }
    @{ Number = 2; Name = "Search metadata"; Description = "Query MusicBrainz, iTunes, Deezer" }
    @{ Number = 3; Name = "Confirm changes"; Description = "Show comparison and get approval" }
    @{ Number = 4; Name = "Apply tags"; Description = "Write metadata to audio files" }
    @{ Number = 5; Name = "Cover art"; Description = "Download album cover art" }
    @{ Number = 6; Name = "Rename files"; Description = "Rename files to standard format" }
)
$script:CompletedSteps = @()
$script:CurrentStep = $null
$script:TotalSteps = 6

function Set-CurrentStep {
    param([int]$StepNumber)
    $script:CurrentStep = $script:AllSteps | Where-Object { $_.Number -eq $StepNumber }
}

function Complete-CurrentStep {
    if ($script:CurrentStep) {
        $script:CompletedSteps += $script:CurrentStep
    }
}

function Get-RemainingSteps {
    $completedNumbers = $script:CompletedSteps | ForEach-Object { $_.Number }
    return $script:AllSteps | Where-Object { $_.Number -notin $completedNumbers }
}

function Show-StepsSummary {
    param([switch]$ShowRemaining)

    Write-Host "`n--- STEPS COMPLETED ---" -ForegroundColor Green
    if ($script:CompletedSteps.Count -eq 0) {
        Write-Host "  (none)" -ForegroundColor Gray
    } else {
        foreach ($step in $script:CompletedSteps) {
            Write-Host "  [X] Step $($step.Number)/$($script:TotalSteps): $($step.Name)" -ForegroundColor Green
        }
    }

    if ($ShowRemaining) {
        $remaining = Get-RemainingSteps
        if ($remaining.Count -gt 0) {
            Write-Host "`n--- STEPS REMAINING ---" -ForegroundColor Yellow
            foreach ($step in $remaining) {
                Write-Host "  [ ] Step $($step.Number)/$($script:TotalSteps): $($step.Name) - $($step.Description)" -ForegroundColor Yellow
            }
        }
    }
}

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

    Show-StepsSummary -ShowRemaining

    if ($script:LogFile) {
        Write-Host "`nLog file: $($script:LogFile)" -ForegroundColor Yellow
    }
    Write-Host "`n========================================`n" -ForegroundColor Red
    exit 1
}

# ========== CORE FUNCTIONS ==========

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

function Search-MusicBrainz {
    param([string]$AlbumName, [string]$ArtistName, [int]$TrackCount)

    $headers = @{
        "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)"
        "Accept" = "application/json"
    }

    $query = "release:`"$AlbumName`""
    if ($ArtistName) {
        $query += " AND artist:`"$ArtistName`""
    }

    Write-Host "    MusicBrainz: searching..." -ForegroundColor Gray
    Write-Log "  MusicBrainz query: $query"

    try {
        $encodedQuery = [System.Web.HttpUtility]::UrlEncode($query)
        $url = "https://musicbrainz.org/ws/2/release?query=$encodedQuery&limit=10&fmt=json"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 15
        Start-Sleep -Milliseconds 1100  # Rate limit

        if ($response.releases -and $response.releases.Count -gt 0) {
            # Prefer release with matching track count
            $bestMatch = $null
            if ($TrackCount -gt 0) {
                foreach ($rel in $response.releases) {
                    if ($rel.media -and $rel.media.Count -gt 0) {
                        $relTrackCount = ($rel.media | ForEach-Object { $_.'track-count' } | Measure-Object -Sum).Sum
                        if ($relTrackCount -eq $TrackCount) {
                            $bestMatch = $rel
                            break
                        }
                    }
                }
            }
            if (-not $bestMatch) {
                $bestMatch = $response.releases[0]
            }

            # Fetch full release details with recordings
            $detailUrl = "https://musicbrainz.org/ws/2/release/$($bestMatch.id)?inc=recordings+artist-credits+release-groups&fmt=json"
            $fullRelease = Invoke-RestMethod -Uri $detailUrl -Headers $headers -TimeoutSec 15
            Start-Sleep -Milliseconds 1100

            $artist = if ($fullRelease.'artist-credit') {
                ($fullRelease.'artist-credit' | ForEach-Object { $_.name }) -join ""
            } else { "" }

            Write-Host "    MusicBrainz: found `"$($fullRelease.title)`" by $artist" -ForegroundColor Green
            Write-Log "  MusicBrainz: found $($fullRelease.title) by $artist (ID: $($fullRelease.id))"
            return $fullRelease
        }
    } catch {
        Write-Host "    MusicBrainz: search failed - $_" -ForegroundColor Yellow
        Write-Log "  MusicBrainz search failed: $_"
    }

    Write-Host "    MusicBrainz: no results" -ForegroundColor Yellow
    return $null
}

function Search-iTunes {
    param([string]$AlbumName, [string]$ArtistName, [int]$TrackCount)

    $query = if ($ArtistName) { "$ArtistName $AlbumName" } else { $AlbumName }
    $encoded = [System.Web.HttpUtility]::UrlEncode($query)

    Write-Host "    iTunes: searching..." -ForegroundColor Gray
    Write-Log "  iTunes query: $query"

    try {
        $url = "https://itunes.apple.com/search?term=$encoded&media=music&entity=album&limit=5"
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 10

        if ($response.results -and $response.results.Count -gt 0) {
            # Prefer album with matching track count
            $bestMatch = $null
            if ($TrackCount -gt 0) {
                foreach ($album in $response.results) {
                    if ($album.trackCount -eq $TrackCount) {
                        $bestMatch = $album
                        break
                    }
                }
            }
            if (-not $bestMatch) {
                $bestMatch = $response.results[0]
            }

            # Get track listing
            $lookupUrl = "https://itunes.apple.com/lookup?id=$($bestMatch.collectionId)&entity=song"
            $trackResponse = Invoke-RestMethod -Uri $lookupUrl -TimeoutSec 10

            $tracks = @()
            if ($trackResponse.results) {
                $tracks = $trackResponse.results | Where-Object { $_.wrapperType -eq "track" } | Sort-Object trackNumber
            }

            $result = @{
                Source = "iTunes"
                Artist = $bestMatch.artistName
                Album = $bestMatch.collectionName
                Date = if ($bestMatch.releaseDate) { ($bestMatch.releaseDate).Substring(0, 4) } else { "" }
                Genre = $bestMatch.primaryGenreName
                TrackCount = $bestMatch.trackCount
                ArtworkUrl = if ($bestMatch.artworkUrl100) { $bestMatch.artworkUrl100 -replace '100x100bb', '600x600bb' } else { "" }
                Tracks = $tracks | ForEach-Object {
                    @{ Number = $_.trackNumber; Title = $_.trackName; Artist = $_.artistName }
                }
            }

            Write-Host "    iTunes: found `"$($result.Album)`" by $($result.Artist)" -ForegroundColor Green
            Write-Log "  iTunes: found $($result.Album) by $($result.Artist)"
            return $result
        }
    } catch {
        Write-Host "    iTunes: search failed - $_" -ForegroundColor Yellow
        Write-Log "  iTunes search failed: $_"
    }

    Write-Host "    iTunes: no results" -ForegroundColor Yellow
    return $null
}

function Search-Deezer {
    param([string]$AlbumName, [string]$ArtistName, [int]$TrackCount)

    $query = if ($ArtistName) { "$ArtistName $AlbumName" } else { $AlbumName }
    $encoded = [System.Web.HttpUtility]::UrlEncode($query)

    Write-Host "    Deezer: searching..." -ForegroundColor Gray
    Write-Log "  Deezer query: $query"

    try {
        $url = "https://api.deezer.com/search/album?q=$encoded"
        $response = Invoke-RestMethod -Uri $url -TimeoutSec 10

        if ($response.data -and $response.data.Count -gt 0) {
            # Prefer album with matching track count
            $bestMatch = $null
            if ($TrackCount -gt 0) {
                foreach ($album in $response.data) {
                    if ($album.nb_tracks -eq $TrackCount) {
                        $bestMatch = $album
                        break
                    }
                }
            }
            if (-not $bestMatch) {
                $bestMatch = $response.data[0]
            }

            # Get track listing from album endpoint
            $albumUrl = "https://api.deezer.com/album/$($bestMatch.id)"
            $albumDetail = Invoke-RestMethod -Uri $albumUrl -TimeoutSec 10

            $tracks = @()
            if ($albumDetail.tracks -and $albumDetail.tracks.data) {
                $trackNum = 1
                $tracks = $albumDetail.tracks.data | ForEach-Object {
                    @{ Number = $trackNum; Title = $_.title; Artist = $_.artist.name }
                    $trackNum++
                }
            }

            $coverUrl = $bestMatch.cover_xl
            if (-not $coverUrl) { $coverUrl = $bestMatch.cover_big }
            if (-not $coverUrl) { $coverUrl = $bestMatch.cover_medium }

            $result = @{
                Source = "Deezer"
                Artist = $bestMatch.artist.name
                Album = $bestMatch.title
                Date = if ($albumDetail.release_date) { ($albumDetail.release_date).Substring(0, 4) } else { "" }
                Genre = if ($albumDetail.genres -and $albumDetail.genres.data -and $albumDetail.genres.data.Count -gt 0) { $albumDetail.genres.data[0].name } else { "" }
                TrackCount = $bestMatch.nb_tracks
                ArtworkUrl = $coverUrl
                Tracks = $tracks
            }

            Write-Host "    Deezer: found `"$($result.Album)`" by $($result.Artist)" -ForegroundColor Green
            Write-Log "  Deezer: found $($result.Album) by $($result.Artist)"
            return $result
        }
    } catch {
        Write-Host "    Deezer: search failed - $_" -ForegroundColor Yellow
        Write-Log "  Deezer search failed: $_"
    }

    Write-Host "    Deezer: no results" -ForegroundColor Yellow
    return $null
}

function Search-AllSources {
    param([string]$AlbumName, [string]$ArtistName, [int]$TrackCount)

    $mbResult = Search-MusicBrainz -AlbumName $AlbumName -ArtistName $ArtistName -TrackCount $TrackCount
    $itunesResult = Search-iTunes -AlbumName $AlbumName -ArtistName $ArtistName -TrackCount $TrackCount
    $deezerResult = Search-Deezer -AlbumName $AlbumName -ArtistName $ArtistName -TrackCount $TrackCount

    if (-not $mbResult -and -not $itunesResult -and -not $deezerResult) {
        return $null
    }

    # Extract MusicBrainz data into normalized form
    $mbNorm = $null
    if ($mbResult) {
        $mbArtist = if ($mbResult.'artist-credit') {
            ($mbResult.'artist-credit' | ForEach-Object { $_.name }) -join ""
        } else { "" }

        $mbTracks = @()
        if ($mbResult.media -and $mbResult.media[0].tracks) {
            $num = 1
            foreach ($t in $mbResult.media[0].tracks) {
                $tArtist = if ($t.'artist-credit') {
                    ($t.'artist-credit' | ForEach-Object { $_.name }) -join ""
                } else { $mbArtist }
                $mbTracks += @{ Number = $num; Title = $t.title; Artist = $tArtist }
                $num++
            }
        }

        $mbNorm = @{
            Source = "MusicBrainz"
            Artist = $mbArtist
            Album = $mbResult.title
            Date = if ($mbResult.date) { $mbResult.date.Substring(0, [Math]::Min(4, $mbResult.date.Length)) } else { "" }
            Genre = ""  # MusicBrainz doesn't return genre in release endpoint
            TrackCount = if ($mbResult.media) { ($mbResult.media | ForEach-Object { $_.'track-count' } | Measure-Object -Sum).Sum } else { 0 }
            ReleaseId = $mbResult.id
            Tracks = $mbTracks
        }
    }

    # Merge: Artist/Album/Date/Tracks from MB > Deezer > iTunes
    #         Genre from Deezer > iTunes
    #         Cover art: Deezer > iTunes > CAA
    $merged = @{
        Artist = ""
        Album = ""
        AlbumArtist = ""
        Date = ""
        Genre = ""
        TrackCount = 0
        ReleaseId = ""
        Tracks = @()
        ArtworkUrl = ""
        ArtworkSource = ""
        Sources = @{
            MusicBrainz = $mbNorm
            iTunes = $itunesResult
            Deezer = $deezerResult
        }
    }

    # Artist (MB > Deezer > iTunes)
    if ($mbNorm -and $mbNorm.Artist) { $merged.Artist = $mbNorm.Artist }
    elseif ($deezerResult -and $deezerResult.Artist) { $merged.Artist = $deezerResult.Artist }
    elseif ($itunesResult -and $itunesResult.Artist) { $merged.Artist = $itunesResult.Artist }
    $merged.AlbumArtist = $merged.Artist

    # Album (MB > Deezer > iTunes)
    if ($mbNorm -and $mbNorm.Album) { $merged.Album = $mbNorm.Album }
    elseif ($deezerResult -and $deezerResult.Album) { $merged.Album = $deezerResult.Album }
    elseif ($itunesResult -and $itunesResult.Album) { $merged.Album = $itunesResult.Album }

    # Date (MB > Deezer > iTunes)
    if ($mbNorm -and $mbNorm.Date) { $merged.Date = $mbNorm.Date }
    elseif ($deezerResult -and $deezerResult.Date) { $merged.Date = $deezerResult.Date }
    elseif ($itunesResult -and $itunesResult.Date) { $merged.Date = $itunesResult.Date }

    # Genre (Deezer > iTunes)
    if ($deezerResult -and $deezerResult.Genre) { $merged.Genre = $deezerResult.Genre }
    elseif ($itunesResult -and $itunesResult.Genre) { $merged.Genre = $itunesResult.Genre }

    # Track count
    if ($mbNorm -and $mbNorm.TrackCount -gt 0) { $merged.TrackCount = $mbNorm.TrackCount }
    elseif ($deezerResult -and $deezerResult.TrackCount -gt 0) { $merged.TrackCount = $deezerResult.TrackCount }
    elseif ($itunesResult -and $itunesResult.TrackCount -gt 0) { $merged.TrackCount = $itunesResult.TrackCount }

    # Release ID (MusicBrainz only)
    if ($mbNorm -and $mbNorm.ReleaseId) { $merged.ReleaseId = $mbNorm.ReleaseId }

    # Track titles (MB > Deezer; iTunes doesn't reliably provide track names)
    if ($mbNorm -and $mbNorm.Tracks.Count -gt 0) { $merged.Tracks = $mbNorm.Tracks }
    elseif ($deezerResult -and $deezerResult.Tracks.Count -gt 0) { $merged.Tracks = $deezerResult.Tracks }
    elseif ($itunesResult -and $itunesResult.Tracks.Count -gt 0) { $merged.Tracks = $itunesResult.Tracks }

    # Artwork (Deezer 1000x1000 > iTunes 600x600 > CAA)
    if ($deezerResult -and $deezerResult.ArtworkUrl) {
        $merged.ArtworkUrl = $deezerResult.ArtworkUrl
        $merged.ArtworkSource = "Deezer"
    } elseif ($itunesResult -and $itunesResult.ArtworkUrl) {
        $merged.ArtworkUrl = $itunesResult.ArtworkUrl
        $merged.ArtworkSource = "iTunes"
    } elseif ($mbNorm -and $mbNorm.ReleaseId) {
        $merged.ArtworkUrl = "CAA:$($mbNorm.ReleaseId)"
        $merged.ArtworkSource = "Cover Art Archive"
    }

    return $merged
}

function Show-MetadataComparison {
    param([array]$ExistingTracks, [hashtable]$Proposed)

    # Album-level comparison
    $currentArtist = ($ExistingTracks | Where-Object { $_.Artist } | Select-Object -First 1).Artist
    $currentAlbum = ($ExistingTracks | Where-Object { $_.Album } | Select-Object -First 1).Album
    $currentDate = ($ExistingTracks | Where-Object { $_.Date } | Select-Object -First 1).Date
    $currentGenre = ($ExistingTracks | Where-Object { $_.Genre } | Select-Object -First 1).Genre

    Write-Host "`n  --- Album Metadata ---" -ForegroundColor Cyan
    Write-Host ("  {0,-15} {1,-35} {2,-35}" -f "Field", "Current", "Proposed") -ForegroundColor White
    Write-Host ("  {0,-15} {1,-35} {2,-35}" -f "-----", "-------", "--------") -ForegroundColor Gray

    $fields = @(
        @{ Name = "Artist"; Current = $currentArtist; New = $Proposed.Artist }
        @{ Name = "Album"; Current = $currentAlbum; New = $Proposed.Album }
        @{ Name = "Date"; Current = $currentDate; New = $Proposed.Date }
        @{ Name = "Genre"; Current = $currentGenre; New = $Proposed.Genre }
    )

    foreach ($field in $fields) {
        $cur = if ($field.Current) { $field.Current } else { "(empty)" }
        $new = if ($field.New) { $field.New } else { "(empty)" }
        $color = if ($cur -ne $new -and $field.New) { "Yellow" } else { "Gray" }
        Write-Host ("  {0,-15} {1,-35} {2,-35}" -f $field.Name, $cur, $new) -ForegroundColor $color
    }

    # Track-level comparison
    Write-Host "`n  --- Track Listing ---" -ForegroundColor Cyan
    Write-Host ("  {0,-4} {1,-35} {2,-35}" -f "#", "Current Title", "Proposed Title") -ForegroundColor White
    Write-Host ("  {0,-4} {1,-35} {2,-35}" -f "--", "-------------", "--------------") -ForegroundColor Gray

    for ($i = 0; $i -lt $ExistingTracks.Count; $i++) {
        $existing = $ExistingTracks[$i]
        $curTitle = if ($existing.Title) { $existing.Title } else { "(empty)" }

        $newTitle = "(empty)"
        if ($Proposed.Tracks -and $i -lt $Proposed.Tracks.Count) {
            $newTitle = $Proposed.Tracks[$i].Title
        }

        $num = '{0:D2}' -f ($i + 1)
        $isGeneric = $curTitle -match '^Track \d+$' -or $curTitle -eq "(empty)"
        $color = if ($isGeneric -and $newTitle -ne "(empty)") { "Yellow" } elseif ($curTitle -ne $newTitle -and $newTitle -ne "(empty)") { "Yellow" } else { "Gray" }
        Write-Host ("  {0,-4} {1,-35} {2,-35}" -f $num, $curTitle, $newTitle) -ForegroundColor $color
    }

    # Rename preview
    if (-not $SkipRename) {
        Write-Host "`n  --- Rename Preview ---" -ForegroundColor Cyan
        Write-Host ("  {0,-40} {1,-40}" -f "Current Filename", "New Filename") -ForegroundColor White
        Write-Host ("  {0,-40} {1,-40}" -f "----------------", "------------") -ForegroundColor Gray

        for ($i = 0; $i -lt $ExistingTracks.Count; $i++) {
            $existing = $ExistingTracks[$i]
            $currentName = $existing.FileName

            $trackTitle = if ($Proposed.Tracks -and $i -lt $Proposed.Tracks.Count) { $Proposed.Tracks[$i].Title } else { $existing.Title }
            if (-not $trackTitle) { $trackTitle = "Track $($i + 1)" }

            $num = '{0:D2}' -f ($i + 1)
            $sanitizedTitle = $trackTitle -replace '[\\/:*?"<>|]', '_'
            $ext = $existing.File.Extension
            $newName = "$num - $sanitizedTitle$ext"

            $color = if ($currentName -ne $newName) { "Yellow" } else { "Gray" }
            Write-Host ("  {0,-40} {1,-40}" -f $currentName, $newName) -ForegroundColor $color
        }
    }

    # Artwork info
    if (-not $SkipCoverArt -and $Proposed.ArtworkUrl) {
        Write-Host "`n  Cover art: $($Proposed.ArtworkSource)" -ForegroundColor Cyan
    }

    # Source summary
    $sourceList = @()
    if ($Proposed.Sources.MusicBrainz) { $sourceList += "MusicBrainz" }
    if ($Proposed.Sources.iTunes) { $sourceList += "iTunes" }
    if ($Proposed.Sources.Deezer) { $sourceList += "Deezer" }
    Write-Host "`n  Sources found: $($sourceList -join ', ')" -ForegroundColor Gray
}

function Set-AudioTags {
    param(
        [string]$FilePath,
        [int]$TrackNumber,
        [int]$TotalTracks,
        [string]$Title,
        [string]$Artist,
        [string]$Album,
        [string]$AlbumArtist,
        [string]$Date,
        [string]$Genre,
        [string]$ReleaseId
    )

    $metaflacPath = Get-Command metaflac -ErrorAction SilentlyContinue
    if (-not $metaflacPath) {
        return $false
    }

    # Use targeted --remove-tag, not --remove-all-tags, to preserve other metadata
    $removeArgs = @(
        "--remove-tag=ARTIST",
        "--remove-tag=ALBUM",
        "--remove-tag=ALBUMARTIST",
        "--remove-tag=TITLE",
        "--remove-tag=TRACKNUMBER",
        "--remove-tag=TRACKTOTAL",
        "--remove-tag=DATE",
        "--remove-tag=GENRE",
        "--remove-tag=MUSICBRAINZ_ALBUMID"
    )
    & metaflac @removeArgs $FilePath 2>$null

    $setArgs = @(
        "--set-tag=TITLE=$Title",
        "--set-tag=ARTIST=$Artist",
        "--set-tag=ALBUM=$Album",
        "--set-tag=ALBUMARTIST=$AlbumArtist",
        "--set-tag=TRACKNUMBER=$TrackNumber",
        "--set-tag=TRACKTOTAL=$TotalTracks"
    )

    if ($Date) { $setArgs += "--set-tag=DATE=$Date" }
    if ($Genre) { $setArgs += "--set-tag=GENRE=$Genre" }
    if ($ReleaseId) { $setArgs += "--set-tag=MUSICBRAINZ_ALBUMID=$ReleaseId" }

    & metaflac @setArgs $FilePath 2>$null
    return $LASTEXITCODE -eq 0
}

function Set-CoverArt {
    param([string]$FilePath, [string]$ImagePath)

    $metaflacPath = Get-Command metaflac -ErrorAction SilentlyContinue
    if (-not $metaflacPath) { return $false }

    # metaflac --import-picture-from= fails on Windows when the path contains spaces.
    # Copy to a temp path (no spaces) before importing, then clean up.
    $ext = [System.IO.Path]::GetExtension($ImagePath)
    $tempImg = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "ripaudio_cover$ext")
    Copy-Item $ImagePath $tempImg -Force

    # Remove existing pictures first, then import
    # Use just the filename -- type defaults to 3 (Front Cover), MIME auto-detected
    # Avoids specification format (TYPE|MIME|DESC|WxH|FILE) which mis-parses Windows backslash paths
    & metaflac --remove --block-type=PICTURE $FilePath 2>$null
    & metaflac "--import-picture-from=$tempImg" $FilePath 2>$null
    $exitCode = $LASTEXITCODE

    Remove-Item $tempImg -ErrorAction SilentlyContinue
    return $exitCode -eq 0
}

function Get-CoverArt {
    param(
        [string]$ArtworkUrl,
        [string]$ArtworkSource,
        [string]$OutputPath,
        [string]$ReleaseId
    )

    $headers = @{
        "User-Agent" = "RipAudio/1.0 (https://github.com/stephenbeale/ripaudio)"
    }

    # Deezer or iTunes direct URL
    if ($ArtworkUrl -and $ArtworkUrl -notlike "CAA:*") {
        try {
            $outputFile = Join-Path $OutputPath "Front.jpg"
            Invoke-WebRequest -Uri $ArtworkUrl -OutFile $outputFile -Headers $headers -TimeoutSec 30

            if ((Test-Path $outputFile) -and (Get-Item $outputFile).Length -gt 1000) {
                Write-Host "    Downloaded: Front.jpg (from $ArtworkSource)" -ForegroundColor Green
                Write-Log "  Downloaded cover art from $ArtworkSource"
                return $outputFile
            }
            Remove-Item $outputFile -ErrorAction SilentlyContinue
        } catch {
            Write-Host "    $ArtworkSource artwork failed: $_" -ForegroundColor Yellow
        }
    }

    # CAA fallback
    if ($ReleaseId) {
        try {
            $url = "https://coverartarchive.org/release/$ReleaseId"
            $response = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 15

            if ($response.images -and $response.images.Count -gt 0) {
                $frontCover = $response.images | Where-Object { $_.front -eq $true } | Select-Object -First 1
                if (-not $frontCover) { $frontCover = $response.images[0] }

                $imageUrl = $frontCover.image
                $extension = if ($imageUrl -match '\.(\w+)$') { $Matches[1] } else { "jpg" }
                $outputFile = Join-Path $OutputPath "Front.$extension"

                Invoke-WebRequest -Uri $imageUrl -OutFile $outputFile -Headers $headers -TimeoutSec 30
                if ((Test-Path $outputFile) -and (Get-Item $outputFile).Length -gt 1000) {
                    Write-Host "    Downloaded: Front.$extension (from Cover Art Archive)" -ForegroundColor Green
                    Write-Log "  Downloaded cover art from Cover Art Archive"
                    return $outputFile
                }
                Remove-Item $outputFile -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Host "    Cover Art Archive: not available" -ForegroundColor Yellow
        }
    }

    Write-Host "    No cover art found" -ForegroundColor Yellow
    return $null
}

function Rename-AudioFiles {
    param([array]$ExistingTracks, [hashtable]$Proposed)

    $renamedCount = 0

    for ($i = 0; $i -lt $ExistingTracks.Count; $i++) {
        $track = $ExistingTracks[$i]
        $file = $track.File

        $trackTitle = if ($Proposed.Tracks -and $i -lt $Proposed.Tracks.Count) { $Proposed.Tracks[$i].Title } else { $track.Title }
        if (-not $trackTitle) { $trackTitle = "Track $($i + 1)" }

        $num = '{0:D2}' -f ($i + 1)
        $sanitizedTitle = $trackTitle -replace '[\\/:*?"<>|]', '_'
        $ext = $file.Extension
        $newName = "$num - $sanitizedTitle$ext"

        if ($file.Name -ne $newName) {
            $newPath = Join-Path $file.DirectoryName $newName
            try {
                Rename-Item -Path $file.FullName -NewName $newName -ErrorAction Stop
                Write-Host "    $($file.Name) -> $newName" -ForegroundColor Gray
                Write-Log "  Renamed: $($file.Name) -> $newName"
                $renamedCount++
            } catch {
                Write-Host "    Failed to rename $($file.Name): $_" -ForegroundColor Red
                Write-Log "  ERROR renaming $($file.Name): $_"
            }
        }
    }

    return $renamedCount
}

# ========== PER-ALBUM PROCESSING FUNCTION ==========

function Reset-StepTracking {
    $script:CompletedSteps = @()
    $script:CurrentStep = $null
}

function Process-AlbumFolder {
    param(
        [string]$FolderPath,
        [string]$ArtistHint,
        [string]$AlbumHint,
        [switch]$ForceMode,
        [switch]$SkipRenameMode,
        [switch]$SkipCoverArtMode,
        [switch]$BatchMode,
        [switch]$DryRunMode,
        [switch]$EmbedOnlyMode
    )

    # Reset step tracking for each album
    Reset-StepTracking

    $albumResult = @{
        Path = $FolderPath
        Artist = ""
        Album = ""
        Status = "failed"  # default, updated on success
        TagCount = 0
        RenameCount = 0
        EmbedCount = 0
        Error = ""
    }

    # Override step tracking for EmbedOnly mode, or restore defaults
    if ($EmbedOnlyMode) {
        $script:AllSteps = @(
            @{ Number = 1; Name = "Scan files"; Description = "Read existing tags and identify files" }
            @{ Number = 2; Name = "Cover art"; Description = "Find or download cover art and embed into FLAC files" }
        )
        $script:TotalSteps = 2
    } else {
        $script:AllSteps = @(
            @{ Number = 1; Name = "Scan files"; Description = "Read existing tags and identify gaps" }
            @{ Number = 2; Name = "Search metadata"; Description = "Query MusicBrainz, iTunes, Deezer" }
            @{ Number = 3; Name = "Confirm changes"; Description = "Show comparison and get approval" }
            @{ Number = 4; Name = "Apply tags"; Description = "Write metadata to audio files" }
            @{ Number = 5; Name = "Cover art"; Description = "Download album cover art" }
            @{ Number = 6; Name = "Rename files"; Description = "Rename files to standard format" }
        )
        $script:TotalSteps = 6
    }

    $folderArtist = $ArtistHint
    $folderAlbum = $AlbumHint

    # ========== STEP 1: SCAN FILES ==========
    Set-CurrentStep -StepNumber 1
    Write-Host "`n[STEP 1/$script:TotalSteps] Scanning files..." -ForegroundColor Green
    Write-Log "STEP 1/$($script:TotalSteps): Scanning files in $FolderPath"

    $existingTracks = Read-ExistingTags -FolderPath $FolderPath

    if (-not $existingTracks -or $existingTracks.Count -eq 0) {
        $msg = "No FLAC files found in: $FolderPath"
        if ($BatchMode) {
            Write-Host "  ERROR: $msg" -ForegroundColor Red
            Write-Log "  ERROR: $msg"
            $albumResult.Error = $msg
            return $albumResult
        }
        Stop-WithError -Step "STEP 1/$($script:TotalSteps): Scan files" -Message $msg
    }

    Write-Host "  Found $($existingTracks.Count) FLAC file(s)" -ForegroundColor White

    # Infer artist/album from tags or folder structure if not provided
    if (-not $folderArtist) {
        $tagArtist = ($existingTracks | Where-Object { $_.Artist -and $_.Artist -ne "" } | Select-Object -First 1).Artist
        if ($tagArtist) {
            $folderArtist = $tagArtist
            Write-Host "  Artist (from tags): $folderArtist" -ForegroundColor Gray
        } else {
            # Try parent folder name
            $parentPath = Split-Path -Parent $FolderPath
            $parentName = Split-Path -Leaf $parentPath
            if ($parentName -ne "Music" -and $parentName -ne "logs") {
                $folderArtist = $parentName
                Write-Host "  Artist (from folder): $folderArtist" -ForegroundColor Gray
            }
        }
    }

    if (-not $folderAlbum) {
        $tagAlbum = ($existingTracks | Where-Object { $_.Album -and $_.Album -ne "" } | Select-Object -First 1).Album
        if ($tagAlbum) {
            $folderAlbum = $tagAlbum
            Write-Host "  Album (from tags): $folderAlbum" -ForegroundColor Gray
        } else {
            $folderAlbum = Split-Path -Leaf $FolderPath
            Write-Host "  Album (from folder): $folderAlbum" -ForegroundColor Gray
        }
    }

    if (-not $EmbedOnlyMode) {
        Write-Host "  Searching for: `"$folderAlbum`"" -ForegroundColor White
        if ($folderArtist) { Write-Host "  by: `"$folderArtist`"" -ForegroundColor White }
    }

    # Check for gaps (skip display in EmbedOnly mode since we're not touching tags)
    $gapCount = 0
    foreach ($track in $existingTracks) {
        if (-not $track.Title -or $track.Title -match '^Track \d+$') { $gapCount++ }
    }
    if ($gapCount -gt 0 -and -not $EmbedOnlyMode) {
        Write-Host "  Tracks with missing/generic titles: $gapCount" -ForegroundColor Yellow
    }

    Write-Log "  Artist: $folderArtist, Album: $folderAlbum, Tracks: $($existingTracks.Count), Gaps: $gapCount"

    Complete-CurrentStep

    # ========== EMBED ONLY MODE ==========
    if ($EmbedOnlyMode) {
        Set-CurrentStep -StepNumber 2
        Write-Host "`n[STEP 2/$script:TotalSteps] Cover art..." -ForegroundColor Green
        Write-Log "STEP 2/$($script:TotalSteps): Cover art (embed only)"

        # Check for existing art files
        $existingArt = Get-ChildItem -Path $FolderPath -Include "Front.*","Cover.*","Folder.*" -ErrorAction SilentlyContinue
        $imageFile = $null

        if ($existingArt) {
            $imageFile = $existingArt[0].FullName
            Write-Host "    Found: $($existingArt[0].Name)" -ForegroundColor Gray
            Write-Log "  Found existing art: $($existingArt[0].Name)"
        } else {
            # No art on disk -- search metadata sources for artwork URL, then download
            Write-Host "    No cover art on disk, searching online..." -ForegroundColor Yellow
            Write-Log "  No cover art on disk, searching online"

            $merged = Search-AllSources -AlbumName $folderAlbum -ArtistName $folderArtist -TrackCount $existingTracks.Count

            # Check if search result matches -- auto-proceed on match, prompt on mismatch
            $artworkValid = $false
            if ($merged -and $merged.ArtworkUrl) {
                $foundArtist = $merged.Artist
                $foundAlbum = $merged.Album

                # Case-insensitive partial match on both artist and album
                $artistOk = (-not $folderArtist) -or (-not $foundArtist) -or
                    ($foundArtist -like "*$folderArtist*") -or ($folderArtist -like "*$foundArtist*")
                $albumOk = (-not $folderAlbum) -or (-not $foundAlbum) -or
                    ($foundAlbum -like "*$folderAlbum*") -or ($folderAlbum -like "*$foundAlbum*")

                # Leading-word prefix overlap: handles folder names where punctuation splits a
                # longer title (e.g. "The Best Of-Once in a Lifetime" vs "The Best of Talking Heads").
                # Treated as a soft match — always prompts, even in batch mode.
                $prefixOnlyMatch = $false
                if (-not $albumOk -and $folderAlbum -and $foundAlbum) {
                    $folderWords = ($folderAlbum -replace '[^a-zA-Z0-9\s]', ' ' -split '\s+').Where({ $_ }) |
                        ForEach-Object { $_.ToLower() }
                    $foundWords  = ($foundAlbum  -replace '[^a-zA-Z0-9\s]', ' ' -split '\s+').Where({ $_ }) |
                        ForEach-Object { $_.ToLower() }
                    $prefixMatch = 0
                    $minLen = [Math]::Min($folderWords.Count, $foundWords.Count)
                    for ($i = 0; $i -lt $minLen; $i++) {
                        if ($folderWords[$i] -eq $foundWords[$i]) { $prefixMatch++ } else { break }
                    }
                    if ($prefixMatch -ge 2) {
                        $albumOk = $true
                        $prefixOnlyMatch = $true
                    }
                }

                if ($artistOk -and $albumOk -and -not $prefixOnlyMatch) {
                    # Strong match -- auto-proceed
                    Write-Host "    Matched: `"$foundAlbum`" by `"$foundArtist`" ($($merged.ArtworkSource))" -ForegroundColor Green
                    Write-Log "  Matched: `"$foundAlbum`" by `"$foundArtist`" ($($merged.ArtworkSource))"
                    $artworkValid = $true
                } else {
                    # Soft match (prefix only) or mismatch -- always prompt
                    if ($artistOk -and $prefixOnlyMatch) {
                        Write-Host "    Partial match: `"$foundAlbum`" by `"$foundArtist`" ($($merged.ArtworkSource))" -ForegroundColor Yellow
                    } else {
                        Write-Host "    No exact match. Best result: `"$foundAlbum`" by `"$foundArtist`" ($($merged.ArtworkSource))" -ForegroundColor Yellow
                    }
                    if ($BatchMode -and -not ($artistOk -and $prefixOnlyMatch)) {
                        Write-Host "    Skipping -- cannot confirm in batch mode" -ForegroundColor Yellow
                        Write-Log "  No match: expected `"$folderAlbum`" by `"$folderArtist`", got `"$foundAlbum`" by `"$foundArtist`" -- auto-skipped (batch)"
                    } elseif ($DryRunMode) {
                        Write-Host "    [DRY RUN] Would prompt to confirm" -ForegroundColor Cyan
                    } else {
                        # Show the artwork URL so the user can preview before deciding
                        $previewUrl = $merged.ArtworkUrl
                        if ($previewUrl -like "CAA:*") {
                            $previewUrl = "https://coverartarchive.org/release/$($previewUrl.Substring(4))"
                        }
                        Write-Host "    Artwork: $previewUrl" -ForegroundColor Gray
                        $artworkDecided = $false
                        while (-not $artworkDecided) {
                            Write-Host "    [Y]es / [N]o / [O]pen in browser / [C]ustom URL (auto-No in 30s): " -NoNewline -ForegroundColor White
                            $artKey = $null
                            $sw = [System.Diagnostics.Stopwatch]::StartNew()
                            while ($sw.Elapsed.TotalSeconds -lt 30) {
                                if ([Console]::KeyAvailable) {
                                    $artKey = [Console]::ReadKey($true)
                                    break
                                }
                                Start-Sleep -Milliseconds 200
                            }
                            $sw.Stop()
                            $artConfirm = if ($artKey) { "$($artKey.KeyChar)".ToUpper() } else { $null }
                            if ($null -eq $artConfirm) {
                                Write-Host "N (auto)" -ForegroundColor Gray
                                Write-Host "    Skipped" -ForegroundColor Yellow
                                Write-Log "  No match: `"$foundAlbum`" by `"$foundArtist`" -- auto-skipped (timeout)"
                                $artworkDecided = $true
                            } elseif ($artConfirm -eq "Y") {
                                Write-Host "Y" -ForegroundColor Green
                                $artworkValid = $true
                                Write-Log "  User approved artwork: `"$foundAlbum`" by `"$foundArtist`""
                                $artworkDecided = $true
                            } elseif ($artConfirm -eq "O") {
                                Write-Host "O" -ForegroundColor Cyan
                                Write-Host "    Opening in browser..." -ForegroundColor Cyan
                                Start-Process $previewUrl
                            } elseif ($artConfirm -eq "C") {
                                Write-Host "C"
                                $customUrl = Read-Host "    Enter custom artwork URL"
                                if ($customUrl -and $customUrl.Trim()) {
                                    $merged.ArtworkUrl = $customUrl.Trim()
                                    $merged.ArtworkSource = "custom"
                                    $artworkValid = $true
                                    Write-Log "  User provided custom artwork URL: $($customUrl.Trim())"
                                } else {
                                    Write-Host "    No URL entered, skipping" -ForegroundColor Yellow
                                    Write-Log "  User provided no custom URL -- skipped"
                                }
                                $artworkDecided = $true
                            } else {
                                Write-Host "N" -ForegroundColor Yellow
                                Write-Host "    Skipped" -ForegroundColor Yellow
                                Write-Log "  No match: `"$foundAlbum`" by `"$foundArtist`" -- user skipped"
                                $artworkDecided = $true
                            }
                        }
                    }
                }
            }

            if ($artworkValid) {
                if ($DryRunMode) {
                    Write-Host "    [DRY RUN] Would download cover art from $($merged.ArtworkSource)" -ForegroundColor Cyan
                    Write-Log "  [DRY RUN] Would download cover art from $($merged.ArtworkSource)"
                } else {
                    $artFile = Get-CoverArt -ArtworkUrl $merged.ArtworkUrl -ArtworkSource $merged.ArtworkSource `
                        -OutputPath $FolderPath -ReleaseId $merged.ReleaseId
                    if ($artFile) { $imageFile = $artFile }
                }
            } else {
                Write-Host "    No cover art found from any source" -ForegroundColor Yellow
                Write-Log "  No cover art found from any source"
            }
        }

        # Embed into FLAC files
        if ($DryRunMode) {
            if ($imageFile -or ($existingArt)) {
                if ($imageFile) { $artName = Split-Path -Leaf $imageFile } else { $artName = $existingArt[0].Name }
                Write-Host "    [DRY RUN] Would embed $artName in $($existingTracks.Count) file(s)" -ForegroundColor Cyan
                Write-Log "  [DRY RUN] Would embed cover art in $($existingTracks.Count) files"
                $albumResult.EmbedCount = $existingTracks.Count
            } else {
                Write-Host "    [DRY RUN] No cover art available to embed" -ForegroundColor Cyan
                Write-Log "  [DRY RUN] No cover art available"
            }
        } elseif ($imageFile) {
            $embedCount = 0
            foreach ($track in $existingTracks) {
                if (Set-CoverArt -FilePath $track.File.FullName -ImagePath $imageFile) {
                    $embedCount++
                }
            }
            Write-Host "    Embedded cover art in $embedCount/$($existingTracks.Count) file(s)" -ForegroundColor Green
            Write-Log "  Embedded cover art in $embedCount files"
            $albumResult.EmbedCount = $embedCount
        } else {
            Write-Host "    No cover art available to embed" -ForegroundColor Yellow
            Write-Log "  No cover art available to embed"
        }

        Complete-CurrentStep

        $albumResult.Artist = $folderArtist
        $albumResult.Album = $folderAlbum
        if ($albumResult.EmbedCount -gt 0) {
            $albumResult.Status = "success"
        } else {
            $albumResult.Status = "skipped"
        }

        return $albumResult
    }

    # ========== STEP 2: SEARCH METADATA ==========
    Set-CurrentStep -StepNumber 2
    Write-Host "`n[STEP 2/$script:TotalSteps] Searching metadata sources..." -ForegroundColor Green
    Write-Log "STEP 2/$($script:TotalSteps): Searching metadata sources"

    $merged = Search-AllSources -AlbumName $folderAlbum -ArtistName $folderArtist -TrackCount $existingTracks.Count

    if (-not $merged) {
        $msg = "No results found from any source for `"$folderAlbum`" by `"$folderArtist`""
        if ($BatchMode) {
            Write-Host "  ERROR: $msg" -ForegroundColor Red
            Write-Log "  ERROR: $msg"
            $albumResult.Error = $msg
            $albumResult.Artist = $folderArtist
            $albumResult.Album = $folderAlbum
            return $albumResult
        }
        Stop-WithError -Step "STEP 2/$($script:TotalSteps): Search metadata" -Message $msg
    }

    Write-Host "`n  Merged result: `"$($merged.Album)`" by $($merged.Artist)" -ForegroundColor Green
    if ($merged.Date) { Write-Host "  Year: $($merged.Date)" -ForegroundColor Gray }
    if ($merged.Genre) { Write-Host "  Genre: $($merged.Genre)" -ForegroundColor Gray }
    Write-Host "  Tracks: $($merged.Tracks.Count)" -ForegroundColor Gray

    Complete-CurrentStep

    # ========== STEP 3: CONFIRM CHANGES ==========
    Set-CurrentStep -StepNumber 3
    Write-Host "`n[STEP 3/$script:TotalSteps] Review proposed changes..." -ForegroundColor Green
    Write-Log "STEP 3/$($script:TotalSteps): Showing comparison"

    Show-MetadataComparison -ExistingTracks $existingTracks -Proposed $merged

    if ($DryRunMode) {
        Write-Host "`n  [DRY RUN] No changes will be made." -ForegroundColor Cyan
    } elseif (-not $ForceMode) {
        Write-Host ""
        Write-Host "  Apply these changes? [Y/n] (auto-Yes in 30s) " -NoNewline -ForegroundColor White
        $confirm = $null
        $timeout = 30
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($stopwatch.Elapsed.TotalSeconds -lt $timeout) {
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
            Write-Host "`n  Cancelled by user." -ForegroundColor Yellow
            Write-Log "User cancelled"
            $albumResult.Artist = $merged.Artist
            $albumResult.Album = $merged.Album
            $albumResult.Status = "skipped"
            return $albumResult
        }
    }

    Complete-CurrentStep

    # ========== STEP 4: APPLY TAGS ==========
    Set-CurrentStep -StepNumber 4

    $tagCount = 0
    if ($DryRunMode) {
        Write-Host "`n[STEP 4/$script:TotalSteps] Applying tags (dry run)..." -ForegroundColor Green
        Write-Log "STEP 4/$($script:TotalSteps): Applying tags (dry run)"
        $tagCount = $existingTracks.Count
        Write-Host "  [DRY RUN] Would tag $tagCount file(s)" -ForegroundColor Cyan
        Write-Log "  [DRY RUN] Would tag $tagCount files"
    } else {
        Write-Host "`n[STEP 4/$script:TotalSteps] Applying tags..." -ForegroundColor Green
        Write-Log "STEP 4/$($script:TotalSteps): Applying tags"

        for ($i = 0; $i -lt $existingTracks.Count; $i++) {
            $track = $existingTracks[$i]
            $trackTitle = if ($merged.Tracks -and $i -lt $merged.Tracks.Count) { $merged.Tracks[$i].Title } else { $track.Title }
            if (-not $trackTitle) { $trackTitle = "Track $($i + 1)" }

            $trackArtist = $merged.Artist
            if ($merged.Tracks -and $i -lt $merged.Tracks.Count -and $merged.Tracks[$i].Artist) {
                $trackArtist = $merged.Tracks[$i].Artist
            }

            $tagged = Set-AudioTags -FilePath $track.File.FullName `
                -TrackNumber ($i + 1) -TotalTracks $existingTracks.Count `
                -Title $trackTitle -Artist $trackArtist `
                -Album $merged.Album -AlbumArtist $merged.Artist `
                -Date $merged.Date -Genre $merged.Genre `
                -ReleaseId $merged.ReleaseId

            if ($tagged) {
                $tagCount++
            }
        }

        Write-Host "  Tagged $tagCount/$($existingTracks.Count) file(s)" -ForegroundColor Green
        Write-Log "  Tagged $tagCount files"
    }

    Complete-CurrentStep

    # ========== STEP 5: COVER ART ==========
    Set-CurrentStep -StepNumber 5

    if ($SkipCoverArtMode) {
        Write-Host "`n[STEP 5/$script:TotalSteps] Cover art (skipped)" -ForegroundColor Yellow
        Write-Log "STEP 5/$($script:TotalSteps): Cover art skipped"
    } elseif ($DryRunMode) {
        Write-Host "`n[STEP 5/$script:TotalSteps] Cover art (dry run)..." -ForegroundColor Green
        Write-Log "STEP 5/$($script:TotalSteps): Cover art (dry run)"

        $existingArt = Get-ChildItem -Path $FolderPath -Include "Front.*","Cover.*","Folder.*" -ErrorAction SilentlyContinue
        if ($existingArt) {
            Write-Host "  [DRY RUN] Cover art already exists: $($existingArt[0].Name)" -ForegroundColor Cyan
            Write-Log "  [DRY RUN] Cover art already exists"
            Write-Host "  [DRY RUN] Would embed cover art in $($existingTracks.Count) file(s)" -ForegroundColor Cyan
            Write-Log "  [DRY RUN] Would embed cover art in $($existingTracks.Count) files"
        } elseif ($merged.ArtworkUrl) {
            Write-Host "  [DRY RUN] Would download cover art from $($merged.ArtworkSource)" -ForegroundColor Cyan
            Write-Log "  [DRY RUN] Would download cover art from $($merged.ArtworkSource)"
            Write-Host "  [DRY RUN] Would embed cover art in $($existingTracks.Count) file(s)" -ForegroundColor Cyan
            Write-Log "  [DRY RUN] Would embed cover art in $($existingTracks.Count) files"
        } else {
            Write-Host "  [DRY RUN] No cover art available" -ForegroundColor Cyan
            Write-Log "  [DRY RUN] No cover art available"
        }
    } else {
        Write-Host "`n[STEP 5/$script:TotalSteps] Downloading cover art..." -ForegroundColor Green
        Write-Log "STEP 5/$($script:TotalSteps): Downloading cover art"

        # Check if art already exists
        $existingArt = Get-ChildItem -Path $FolderPath -Include "Front.*","Cover.*","Folder.*" -ErrorAction SilentlyContinue
        if ($existingArt -and -not $ForceMode) {
            Write-Host "    Cover art already exists: $($existingArt[0].Name)" -ForegroundColor Gray
            Write-Log "  Cover art already exists"
        } else {
            $artFile = Get-CoverArt -ArtworkUrl $merged.ArtworkUrl -ArtworkSource $merged.ArtworkSource `
                -OutputPath $FolderPath -ReleaseId $merged.ReleaseId
            if (-not $artFile) {
                Write-Log "  No cover art downloaded"
            }
        }

        # Embed cover art into FLAC files
        $imageFile = $artFile
        if (-not $imageFile) {
            $existingArt = Get-ChildItem -Path $FolderPath -Include "Front.*","Cover.*","Folder.*" -ErrorAction SilentlyContinue
            if ($existingArt) { $imageFile = $existingArt[0].FullName }
        }
        if ($imageFile) {
            $embedCount = 0
            foreach ($track in $existingTracks) {
                if (Set-CoverArt -FilePath $track.File.FullName -ImagePath $imageFile) {
                    $embedCount++
                }
            }
            Write-Host "    Embedded cover art in $embedCount/$($existingTracks.Count) file(s)" -ForegroundColor Green
            Write-Log "  Embedded cover art in $embedCount files"
        }
    }

    Complete-CurrentStep

    # ========== STEP 6: RENAME FILES ==========
    Set-CurrentStep -StepNumber 6

    $renamedCount = 0
    if ($SkipRenameMode) {
        Write-Host "`n[STEP 6/$script:TotalSteps] Rename files (skipped)" -ForegroundColor Yellow
        Write-Log "STEP 6/$($script:TotalSteps): Rename skipped"
    } elseif ($DryRunMode) {
        Write-Host "`n[STEP 6/$script:TotalSteps] Rename files (dry run)..." -ForegroundColor Green
        Write-Log "STEP 6/$($script:TotalSteps): Rename files (dry run)"

        for ($i = 0; $i -lt $existingTracks.Count; $i++) {
            $track = $existingTracks[$i]
            $file = $track.File

            $trackTitle = if ($merged.Tracks -and $i -lt $merged.Tracks.Count) { $merged.Tracks[$i].Title } else { $track.Title }
            if (-not $trackTitle) { $trackTitle = "Track $($i + 1)" }

            $num = '{0:D2}' -f ($i + 1)
            $sanitizedTitle = $trackTitle -replace '[\\/:*?"<>|]', '_'
            $ext = $file.Extension
            $newName = "$num - $sanitizedTitle$ext"

            if ($file.Name -ne $newName) {
                Write-Host "    $($file.Name) -> $newName" -ForegroundColor Cyan
                $renamedCount++
            }
        }

        if ($renamedCount -gt 0) {
            Write-Host "  [DRY RUN] Would rename $renamedCount file(s)" -ForegroundColor Cyan
        } else {
            Write-Host "  [DRY RUN] No files would need renaming" -ForegroundColor Cyan
        }
        Write-Log "  [DRY RUN] Would rename $renamedCount files"
    } else {
        Write-Host "`n[STEP 6/$script:TotalSteps] Renaming files..." -ForegroundColor Green
        Write-Log "STEP 6/$($script:TotalSteps): Renaming files"

        $renamedCount = Rename-AudioFiles -ExistingTracks $existingTracks -Proposed $merged

        if ($renamedCount -gt 0) {
            Write-Host "  Renamed $renamedCount file(s)" -ForegroundColor Green
        } else {
            Write-Host "  No files needed renaming" -ForegroundColor Gray
        }
        Write-Log "  Renamed $renamedCount files"
    }

    Complete-CurrentStep

    $albumResult.Artist = $merged.Artist
    $albumResult.Album = $merged.Album
    $albumResult.Status = "success"
    $albumResult.TagCount = $tagCount
    $albumResult.RenameCount = $renamedCount

    return $albumResult
}

# ========== MAIN SCRIPT ==========

# Load System.Web for URL encoding
Add-Type -AssemblyName System.Web

if ($EmbedOnly) {
    $bannerText = "Embed Cover Art"
} else {
    $bannerText = "Search & Apply Audio Metadata"
}
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host $bannerText -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Validate path
if (-not (Test-Path $Path)) {
    Write-Host "`nError: Path not found: $Path" -ForegroundColor Red
    exit 1
}

# Warn if -Artist or -Album used with -Recurse (each folder infers its own)
if ($Recurse -and ($Artist -or $Album)) {
    Write-Host "`nWarning: -Artist and -Album hints are ignored in -Recurse mode (each folder infers its own)" -ForegroundColor Yellow
}

# Setup logging
$logDir = "C:\Music\logs"
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFile = Join-Path $logDir "search-metadata_${logTimestamp}.log"

Write-Log "========== SEARCH METADATA SESSION STARTED =========="
Write-Log "Path: $Path"
Write-Log "Artist hint: $Artist"
Write-Log "Album hint: $Album"
Write-Log "SkipRename: $SkipRename"
Write-Log "SkipCoverArt: $SkipCoverArt"
Write-Log "Force: $Force"
Write-Log "Recurse: $Recurse"
Write-Log "DryRun: $DryRun"
Write-Log "EmbedOnly: $EmbedOnly"

# Window title
$host.UI.RawUI.WindowTitle = "search-metadata - $Path"

if ($Recurse) {
    # ========== RECURSE MODE ==========
    Write-Host "`nRecurse mode: scanning for album folders under $Path" -ForegroundColor Cyan
    Write-Log "Recurse mode: scanning for album folders"

    # Find all directories containing at least one FLAC file
    $albumFolders = @()
    $allFlacFiles = Get-ChildItem -Path $Path -Filter "*.flac" -Recurse -ErrorAction SilentlyContinue
    if ($allFlacFiles) {
        $albumFolders = $allFlacFiles | ForEach-Object { $_.DirectoryName } | Sort-Object -Unique
    }

    if ($albumFolders.Count -eq 0) {
        Write-Host "`nNo FLAC files found under: $Path" -ForegroundColor Red
        Write-Log "No FLAC files found under $Path"
        exit 1
    }

    Write-Host "  Found $($albumFolders.Count) album folder(s):" -ForegroundColor White
    foreach ($folder in $albumFolders) {
        $relPath = $folder.Substring($Path.Length).TrimStart('\', '/')
        if (-not $relPath) { $relPath = "." }
        $flacCount = (Get-ChildItem -Path $folder -Filter "*.flac" -ErrorAction SilentlyContinue).Count
        Write-Host "    $relPath ($flacCount files)" -ForegroundColor Gray
    }
    Write-Log "Found $($albumFolders.Count) album folders"

    # Process each folder
    $batchResults = @()
    $albumNum = 0

    foreach ($folder in $albumFolders) {
        $albumNum++
        $relPath = $folder.Substring($Path.Length).TrimStart('\', '/')
        if (-not $relPath) { $relPath = "." }

        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "Album $albumNum/$($albumFolders.Count): $relPath" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Log "========== Album $albumNum/$($albumFolders.Count): $relPath =========="

        $host.UI.RawUI.WindowTitle = "search-metadata [$albumNum/$($albumFolders.Count)] $relPath"

        try {
            $result = Process-AlbumFolder -FolderPath $folder `
                -ForceMode:$true -SkipRenameMode:$SkipRename -SkipCoverArtMode:$SkipCoverArt `
                -BatchMode -DryRunMode:$DryRun -EmbedOnlyMode:$EmbedOnly

            $batchResults += $result

            if ($result.Status -eq "success") {
                Write-Host "`n  Done: $($result.Artist) - $($result.Album)" -ForegroundColor Green
            } elseif ($result.Status -eq "skipped") {
                Write-Host "`n  Skipped: $relPath" -ForegroundColor Yellow
            } else {
                Write-Host "`n  Failed: $relPath - $($result.Error)" -ForegroundColor Red
            }
        } catch {
            Write-Host "`n  Failed: $relPath - $_" -ForegroundColor Red
            Write-Log "  ERROR processing $relPath`: $_"
            $batchResults += @{
                Path = $folder
                Artist = ""
                Album = $relPath
                Status = "failed"
                TagCount = 0
                RenameCount = 0
                EmbedCount = 0
                Error = "$_"
            }
        }
    }

    # ========== BATCH SUMMARY ==========
    $successCount = @($batchResults | Where-Object { $_.Status -eq "success" }).Count
    $failedCount = @($batchResults | Where-Object { $_.Status -eq "failed" }).Count
    $skippedCount = @($batchResults | Where-Object { $_.Status -eq "skipped" }).Count
    $totalTagged = ($batchResults | ForEach-Object { $_.TagCount } | Measure-Object -Sum).Sum
    $totalRenamed = ($batchResults | ForEach-Object { $_.RenameCount } | Measure-Object -Sum).Sum
    $totalEmbedded = ($batchResults | ForEach-Object { $_.EmbedCount } | Measure-Object -Sum).Sum

    $dryRunLabel = if ($DryRun) { "[DRY RUN] " } else { "" }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "${dryRunLabel}BATCH COMPLETE!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan

    Write-Host "`n--- ${dryRunLabel}BATCH SUMMARY ---" -ForegroundColor Cyan
    Write-Host "  Albums processed: $($albumFolders.Count)" -ForegroundColor White
    if ($EmbedOnly) {
        Write-Host "  Embedded: $successCount" -ForegroundColor Green
    } else {
        Write-Host "  Successful: $successCount" -ForegroundColor Green
    }
    if ($failedCount -gt 0) {
        Write-Host "  Failed: $failedCount" -ForegroundColor Red
    }
    if ($skippedCount -gt 0) {
        Write-Host "  Skipped: $skippedCount" -ForegroundColor Yellow
    }
    if ($EmbedOnly) {
        Write-Host "  Total files embedded: $totalEmbedded" -ForegroundColor White
    } else {
        Write-Host "  Total files tagged: $totalTagged" -ForegroundColor White
        if (-not $SkipRename) {
            Write-Host "  Total files renamed: $totalRenamed" -ForegroundColor White
        }
    }

    # Per-album breakdown
    if ($batchResults.Count -gt 1) {
        Write-Host "`n--- PER-ALBUM RESULTS ---" -ForegroundColor Cyan
        foreach ($r in $batchResults) {
            $relPath = $r.Path.Substring($Path.Length).TrimStart('\', '/')
            if (-not $relPath) { $relPath = "." }
            $statusColor = switch ($r.Status) { "success" { "Green" } "skipped" { "Yellow" } default { "Red" } }
            $statusIcon = switch ($r.Status) { "success" { "[OK]" } "skipped" { "[--]" } default { "[!!]" } }
            $label = if ($r.Artist -and $r.Album) { "$($r.Artist) - $($r.Album)" } else { $relPath }
            Write-Host "  $statusIcon $label" -ForegroundColor $statusColor
            if ($r.Error) {
                Write-Host "       $($r.Error)" -ForegroundColor Red
            }
        }
    }

    Write-Host "`n  Log file: $($script:LogFile)" -ForegroundColor White
    Write-Host "`n========================================`n" -ForegroundColor Cyan

    $host.UI.RawUI.WindowTitle = "search-metadata - BATCH DONE ($successCount/$($albumFolders.Count))"

    Write-Log "========== BATCH COMPLETE =========="
    Write-Log "Albums: $($albumFolders.Count), Success: $successCount, Failed: $failedCount, Skipped: $skippedCount"
    if ($EmbedOnly) {
        Write-Log "Total embedded: $totalEmbedded"
    } else {
        Write-Log "Total tagged: $totalTagged, Total renamed: $totalRenamed"
    }

} else {
    # ========== SINGLE FOLDER MODE ==========
    $result = Process-AlbumFolder -FolderPath $Path `
        -ArtistHint $Artist -AlbumHint $Album `
        -ForceMode:$Force -SkipRenameMode:$SkipRename -SkipCoverArtMode:$SkipCoverArt `
        -DryRunMode:$DryRun -EmbedOnlyMode:$EmbedOnly

    # ========== SUMMARY ==========
    $dryRunLabel = if ($DryRun) { "[DRY RUN] " } else { "" }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "${dryRunLabel}COMPLETE!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan

    Write-Host "`n--- ${dryRunLabel}SUMMARY ---" -ForegroundColor Cyan
    Write-Host "  Album: $($result.Album)" -ForegroundColor White
    Write-Host "  Artist: $($result.Artist)" -ForegroundColor White
    if ($EmbedOnly) {
        Write-Host "  Files embedded: $($result.EmbedCount)" -ForegroundColor White
    } else {
        Write-Host "  Files tagged: $($result.TagCount)" -ForegroundColor White
        if (-not $SkipRename) {
            Write-Host "  Files renamed: $($result.RenameCount)" -ForegroundColor White
        }
    }
    Write-Host "  Path: $Path" -ForegroundColor White
    Write-Host "  Log file: $($script:LogFile)" -ForegroundColor White

    Show-StepsSummary

    Write-Host "`n========================================`n" -ForegroundColor Cyan

    $host.UI.RawUI.WindowTitle = "search-metadata - DONE"

    Write-Log "========== SESSION COMPLETE =========="
    Write-Log "Album: $($result.Album) by $($result.Artist)"
    if ($EmbedOnly) {
        Write-Log "Files embedded: $($result.EmbedCount)"
    } else {
        Write-Log "Files tagged: $($result.TagCount)"
        if (-not $SkipRename) { Write-Log "Files renamed: $($result.RenameCount)" }
    }

    # Open the folder in Explorer
    Invoke-Item $Path
}
