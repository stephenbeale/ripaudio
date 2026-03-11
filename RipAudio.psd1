@{
    # Module metadata
    RootModule        = ''
    ModuleVersion     = '1.0.0'
    GUID              = 'a3f7c8e1-9d4b-4e5a-b6c2-1f8e3d7a9b0c'
    Author            = 'Stephen Beale'
    CompanyName       = 'Stephen Beale'
    Copyright         = '(c) 2026 Stephen Beale. MIT License.'
    Description       = 'Automated audio CD ripping toolkit using cyanrip with MusicBrainz metadata lookup, AccurateRip verification, cover art from multiple sources, and batch queue support.'

    # Requirements
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    # Scripts exported by this module
    ScriptsToProcess  = @()
    FileList          = @(
        'rip-audio.ps1'
        'search-metadata.ps1'
        'audit-metadata.ps1'
        'undo-metadata.ps1'
        'get-metadata.ps1'
        'LICENSE'
        'README.md'
        'CHANGELOG.md'
    )

    # Private data for PSGallery
    PrivateData = @{
        PSData = @{
            Tags         = @('audio', 'cd', 'ripping', 'flac', 'musicbrainz', 'cyanrip', 'metadata', 'accuraterip', 'cover-art', 'windows')
            LicenseUri   = 'https://github.com/stephenbeale/ripaudio/blob/master/LICENSE'
            ProjectUri   = 'https://github.com/stephenbeale/ripaudio'
            ReleaseNotes = 'Initial PowerShell Gallery release. Automated CD ripping with MusicBrainz lookup, CDDB fallback, cover art from 4 sources, AccurateRip verification, queue mode, and metadata audit/search/undo tools.'
        }
    }
}
