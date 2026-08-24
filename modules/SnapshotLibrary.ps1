<#
.SYNOPSIS
    SnapshotLibrary.ps1 - Scans a root folder of "movie snapshot" folders and
    tracks position (current folder + current image) with persistence.

.DESCRIPTION
    Expected layout:
        <Root>\
          Movie A\
            snap1.jpg
            snap2.jpg
          Movie B\
            snap1.png
            ...

    Up/Down move between folders (alphabetical). Left/Right move between
    images within the current folder (alphabetical).
#>

$script:ImageExtensions = @('.jpg', '.jpeg', '.png', '.bmp', '.webp')
$script:VideoExtensions = @('.mp4', '.wmv', '.avi', '.mov', '.mkv', '.m4v')
$script:MediaExtensions = $script:ImageExtensions + $script:VideoExtensions

$script:PlayerConfigDir     = Join-Path $env:APPDATA 'Wall-E'
$script:PlayerConfigPath    = Join-Path $script:PlayerConfigDir 'config.json'

# Where config lived under the app's old name - read from here as a
# one-time fallback so renaming to Wall-E doesn't reset anyone's saved
# library folder / progress back to defaults.
$script:LegacyPlayerConfigPath = Join-Path (Join-Path $env:APPDATA 'WallpaperPlayer') 'config.json'

function Test-ImageFile {
    param([Parameter(Mandatory)][string]$Path)
    $script:ImageExtensions -contains [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
}

function Test-VideoFile {
    param([Parameter(Mandatory)][string]$Path)
    $script:VideoExtensions -contains [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
}

function Test-MediaFile {
    <#
    .SYNOPSIS
        True for anything Wall-E can show - a still image OR a video that
        can be played as a live wallpaper.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $script:MediaExtensions -contains [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
}

function Get-SnapshotFolders {
    <#
    .SYNOPSIS
        Returns the list of subfolders (movies) under the root, alphabetical,
        skipping any that contain no supported images.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RootPath)

    if (-not (Test-Path -LiteralPath $RootPath)) {
        Write-Error "Get-SnapshotFolders: root path does not exist - $RootPath"
        return @()
    }

    Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            (Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue |
                Where-Object { Test-MediaFile $_.FullName } | Select-Object -First 1) -ne $null
        } |
        Sort-Object Name
}

function Get-ImagesInFolder {
    <#
    .SYNOPSIS
        Returns sorted media FileInfo objects (images AND videos) inside a
        folder, images and videos interleaved alphabetically. Each object
        gets an extra IsVideo boolean property so callers can branch
        without re-checking the extension themselves.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FolderPath)

    Get-ChildItem -LiteralPath $FolderPath -File -ErrorAction SilentlyContinue |
        Where-Object { Test-MediaFile $_.FullName } |
        Sort-Object Name |
        ForEach-Object {
            $_ | Add-Member -MemberType NoteProperty -Name IsVideo -Value (Test-VideoFile $_.FullName) -Force -PassThru
        }
}

function Get-PlayerConfig {
    <#
    .SYNOPSIS
        Loads (or creates default) persisted player state: root path,
        current folder/image indices, wallpaper style, hotkeys-enabled flag,
        slideshow interval, and shuffle preference.
    #>
    [CmdletBinding()]
    param()

    $cfg = $null

    if (Test-Path -LiteralPath $script:PlayerConfigPath) {
        try {
            $cfg = Get-Content -LiteralPath $script:PlayerConfigPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Warning "Player config corrupt, resetting to defaults."
        }
    }
    elseif (Test-Path -LiteralPath $script:LegacyPlayerConfigPath) {
        # First run under the new Wall-E name - carry over settings from
        # the old WallpaperPlayer config instead of starting from scratch.
        try {
            $cfg = Get-Content -LiteralPath $script:LegacyPlayerConfigPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Warning "Legacy player config corrupt, starting fresh."
        }
    }

    if (-not $cfg) {
        $cfg = [PSCustomObject]@{
            RootPath       = $null
            FolderIndex    = 0
            ImageIndex     = 0
            WallpaperStyle = 'Fill'
            HotkeysEnabled = $true
        }
    }

    # Backfill any fields missing from older config files (e.g. upgrading
    # from a version without the slideshow feature) so downstream code can
    # always rely on these properties existing.
    if (-not (Get-Member -InputObject $cfg -Name 'SlideshowIntervalSeconds' -MemberType NoteProperty)) {
        $cfg | Add-Member -MemberType NoteProperty -Name 'SlideshowIntervalSeconds' -Value 30
    }
    if (-not (Get-Member -InputObject $cfg -Name 'ShuffleEnabled' -MemberType NoteProperty)) {
        $cfg | Add-Member -MemberType NoteProperty -Name 'ShuffleEnabled' -Value $false
    }
    if (-not (Get-Member -InputObject $cfg -Name 'QuickPlaySpeed' -MemberType NoteProperty)) {
        $cfg | Add-Member -MemberType NoteProperty -Name 'QuickPlaySpeed' -Value 'Medium'
    }
    if (-not (Get-Member -InputObject $cfg -Name 'PreviewStretch' -MemberType NoteProperty)) {
        $cfg | Add-Member -MemberType NoteProperty -Name 'PreviewStretch' -Value 'Uniform'
    }
    if (-not (Get-Member -InputObject $cfg -Name 'VideoAudioEnabled' -MemberType NoteProperty)) {
        $cfg | Add-Member -MemberType NoteProperty -Name 'VideoAudioEnabled' -Value $false
    }
    if (-not (Get-Member -InputObject $cfg -Name 'VideoAspectRatio' -MemberType NoteProperty)) {
        # 'Default' = no forced shape (full-screen cover). Otherwise one of
        # the CmbVideoAspect Tag values, stored as text, e.g. "1.7777777777777777".
        $cfg | Add-Member -MemberType NoteProperty -Name 'VideoAspectRatio' -Value 'Default'
    }

    return $cfg
}

function Save-PlayerConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    if (-not (Test-Path -LiteralPath $script:PlayerConfigDir)) {
        New-Item -ItemType Directory -Path $script:PlayerConfigDir -Force | Out-Null
    }

    try {
        $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:PlayerConfigPath -Encoding UTF8
        return $true
    }
    catch {
        Write-Warning "Failed to save player config: $($_.Exception.Message)"
        return $false
    }
}

function Convert-ToWallpaperCompatible {
    <#
    .SYNOPSIS
        If the image is already jpg/png/bmp, returns it unchanged. If it's
        webp (not supported by SystemParametersInfo), converts it to PNG
        via ffmpeg into the player's cache folder and returns that path.
        Returns $null if conversion isn't possible.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -in '.jpg', '.jpeg', '.png', '.bmp') {
        return $Path
    }

    # webp (or anything else) - try to convert with ffmpeg
    $ffmpeg = Get-Command 'ffmpeg' -ErrorAction SilentlyContinue
    if (-not $ffmpeg) {
        Write-Warning "Convert-ToWallpaperCompatible: '$ext' needs conversion but ffmpeg was not found on PATH."
        return $null
    }

    if (-not (Test-Path -LiteralPath $script:PlayerConfigDir)) {
        New-Item -ItemType Directory -Path $script:PlayerConfigDir -Force | Out-Null
    }

    $outPath = Join-Path $script:PlayerConfigDir 'converted_snapshot.png'
    if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue }

    try {
        $proc = Start-Process -FilePath $ffmpeg.Source `
                    -ArgumentList @('-y', '-i', $Path, $outPath) `
                    -NoNewWindow -PassThru -Wait `
                    -RedirectStandardError (Join-Path $script:PlayerConfigDir 'ffmpeg_convert_stderr.log')

        if ($proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $outPath)) {
            return $outPath
        }
        Write-Warning "Convert-ToWallpaperCompatible: ffmpeg conversion failed for $Path"
        return $null
    }
    catch {
        Write-Warning "Convert-ToWallpaperCompatible: $($_.Exception.Message)"
        return $null
    }
}
