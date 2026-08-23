<#
.SYNOPSIS
    Wallpaper.ps1 - Desktop wallpaper module for the TV Launcher project.

.DESCRIPTION
    Provides static wallpaper setting, automatic backup/restore of the user's
    original wallpaper, extraction of a still frame from the currently playing
    video (via ffmpeg), and a small on-disk cache/config so state survives
    across launcher restarts.

.NOTES
    Dot-source this file from launcher.ps1 / Player.ps1:
        . "$PSScriptRoot\modules\Wallpaper.ps1"

    Requires: WallpaperHelper.ps1 in the same folder.
    Optional: ffmpeg.exe on PATH (or set $env:LAUNCHER_FFMPEG) for
              Capture-FrameFromVideo. If ffmpeg is not found, that one
              function fails gracefully and everything else still works.
#>

# ---------------------------------------------------------------------------
# Module bootstrap
# ---------------------------------------------------------------------------
$script:WallpaperModuleRoot = $PSScriptRoot
$script:WallpaperCacheDir   = Join-Path $script:WallpaperModuleRoot 'Cache'
$script:WallpaperConfigPath = Join-Path $script:WallpaperCacheDir  'wallpaper.config.json'
$script:WallpaperLogPath    = Join-Path $script:WallpaperCacheDir  'wallpaper.log'
$script:WallpaperCurrentBmp = Join-Path $script:WallpaperCacheDir  'wallpaper.bmp'
$script:WallpaperFramePng   = Join-Path $script:WallpaperCacheDir  'frame_capture.png'
$script:WallpaperBackupPath = Join-Path $script:WallpaperCacheDir  'wallpaper.backup'

# Pull in the low-level Win32/registry helper
$helperPath = Join-Path $script:WallpaperModuleRoot 'WallpaperHelper.ps1'
if (Test-Path -LiteralPath $helperPath) {
    . $helperPath
}
else {
    throw "Wallpaper.ps1: required file WallpaperHelper.ps1 not found next to this module."
}

# ---------------------------------------------------------------------------
# Internal: logging
# ---------------------------------------------------------------------------
function Write-WallpaperLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    try {
        Add-Content -LiteralPath $script:WallpaperLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Logging should never crash the caller.
    }

    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Error   $Message }
        default { Write-Verbose $Message }
    }
}

# ---------------------------------------------------------------------------
# Internal: config persistence
# ---------------------------------------------------------------------------
function Get-WallpaperConfig {
    if (Test-Path -LiteralPath $script:WallpaperConfigPath) {
        try {
            return Get-Content -LiteralPath $script:WallpaperConfigPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-WallpaperLog "Config file corrupt, resetting to defaults. $($_.Exception.Message)" -Level WARN
        }
    }

    return [PSCustomObject]@{
        LastWallpaper   = $null
        LastStyle       = 'Fill'
        BackupWallpaper = $null
        BackupStyle     = $null
    }
}

function Save-WallpaperConfig {
    param(
        [Parameter(Mandatory)]
        $Config
    )

    try {
        $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:WallpaperConfigPath -Encoding UTF8
        return $true
    }
    catch {
        Write-WallpaperLog "Failed to save config: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

# ---------------------------------------------------------------------------
# Public: Initialize-Wallpaper
# ---------------------------------------------------------------------------
function Initialize-Wallpaper {
    <#
    .SYNOPSIS
        Prepares the module: ensures the cache folder exists and loads config.
        Call once at launcher startup.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $script:WallpaperCacheDir)) {
        New-Item -ItemType Directory -Path $script:WallpaperCacheDir -Force | Out-Null
    }

    Write-WallpaperLog "Wallpaper module initialized. Cache: $script:WallpaperCacheDir"
    return Get-WallpaperConfig
}

# ---------------------------------------------------------------------------
# Public: Get-CurrentWallpaper
# ---------------------------------------------------------------------------
function Get-CurrentWallpaper {
    <#
    .SYNOPSIS
        Returns the path of the wallpaper Windows currently has set.
    #>
    [CmdletBinding()]
    param()

    $current = Get-RegistryWallpaperPath
    if (-not $current) {
        Write-WallpaperLog "Could not read current wallpaper from registry." -Level WARN
    }
    return $current
}

# ---------------------------------------------------------------------------
# Public: Backup-Wallpaper
# ---------------------------------------------------------------------------
function Backup-Wallpaper {
    <#
    .SYNOPSIS
        Saves the user's current wallpaper (path + style) so it can be
        restored later. Safe to call multiple times; only backs up once
        per "session" unless -Force is used.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    $config = Get-WallpaperConfig

    if ($config.BackupWallpaper -and -not $Force) {
        Write-WallpaperLog "Backup already exists, skipping (use -Force to overwrite)."
        return $true
    }

    $currentPath = Get-CurrentWallpaper
    $currentStyle = try {
        (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -ErrorAction Stop).WallpaperStyle
    } catch { '10' } # default Fill

    if (-not $currentPath) {
        Write-WallpaperLog "Nothing to back up: no current wallpaper detected." -Level WARN
        return $false
    }

    try {
        if (Test-Path -LiteralPath $currentPath) {
            Copy-Item -LiteralPath $currentPath -Destination $script:WallpaperBackupPath -Force
        }

        $config.BackupWallpaper = $currentPath
        $config.BackupStyle     = $currentStyle
        Save-WallpaperConfig -Config $config | Out-Null

        Write-WallpaperLog "Backed up wallpaper: $currentPath (style $currentStyle)"
        return $true
    }
    catch {
        Write-WallpaperLog "Backup-Wallpaper failed: $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

# ---------------------------------------------------------------------------
# Public: Restore-Wallpaper
# ---------------------------------------------------------------------------
function Restore-Wallpaper {
    <#
    .SYNOPSIS
        Restores the wallpaper saved by Backup-Wallpaper. Call this when
        the player exits.
    #>
    [CmdletBinding()]
    param()

    $config = Get-WallpaperConfig

    if (-not $config.BackupWallpaper) {
        Write-WallpaperLog "No backup recorded, nothing to restore." -Level WARN
        return $false
    }

    # Prefer the original path if it still exists; fall back to our cached copy.
    $target = if (Test-Path -LiteralPath $config.BackupWallpaper) {
        $config.BackupWallpaper
    } elseif (Test-Path -LiteralPath $script:WallpaperBackupPath) {
        $script:WallpaperBackupPath
    } else {
        $null
    }

    if (-not $target) {
        Write-WallpaperLog "Backup file missing on disk, cannot restore." -Level ERROR
        return $false
    }

    $styleName = ($script:WallpaperStyleMap.Keys | Where-Object {
        $script:WallpaperStyleMap[$_].WallpaperStyle -eq $config.BackupStyle
    } | Select-Object -First 1)
    if (-not $styleName) { $styleName = 'Fill' }

    $ok = Set-Wallpaper -Path $target -Style $styleName -SkipBackup
    if ($ok) {
        Write-WallpaperLog "Restored original wallpaper: $target"
    }
    return $ok
}

# ---------------------------------------------------------------------------
# Public: Set-Wallpaper
# ---------------------------------------------------------------------------
function Set-Wallpaper {
    <#
    .SYNOPSIS
        Sets the desktop wallpaper to the given image.

    .PARAMETER Path
        Path to a JPG, PNG, or BMP image. Other formats should be converted
        first (e.g. via ffmpeg for WebP).

    .PARAMETER Style
        One of Center, Tile, Stretch, Fit, Fill, Span. Defaults to Fill.

    .PARAMETER SkipBackup
        Internal switch used by Restore-Wallpaper to avoid backing up the
        backup itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateSet('Center','Tile','Stretch','Fit','Fill','Span')]
        [string]$Style = 'Fill',

        [switch]$SkipBackup
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-WallpaperLog "Set-Wallpaper: file does not exist - $Path" -Level ERROR
        return $false
    }

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -notin '.bmp', '.jpg', '.jpeg', '.png') {
        Write-WallpaperLog "Set-Wallpaper: unsupported format '$ext'. Convert to jpg/png/bmp first." -Level ERROR
        return $false
    }

    if (-not $SkipBackup) {
        Backup-Wallpaper | Out-Null
    }

    $styleOk = Set-WallpaperRegistryStyle -Style $Style
    $setOk   = Invoke-SystemParametersInfoWallpaper -Path $Path

    if ($styleOk -and $setOk) {
        $config = Get-WallpaperConfig
        $config.LastWallpaper = $Path
        $config.LastStyle     = $Style
        Save-WallpaperConfig -Config $config | Out-Null

        Write-WallpaperLog "Wallpaper set: $Path (style: $Style)"
        return $true
    }

    Write-WallpaperLog "Set-Wallpaper failed for $Path" -Level ERROR
    return $false
}

# ---------------------------------------------------------------------------
# Public: Capture-FrameFromVideo
# ---------------------------------------------------------------------------
function Capture-FrameFromVideo {
    <#
    .SYNOPSIS
        Extracts a single frame from a video file using ffmpeg and returns
        the path to the resulting PNG. Intended to be piped into Set-Wallpaper.

    .PARAMETER VideoPath
        Path to the currently playing movie file.

    .PARAMETER TimestampSeconds
        Where in the video to grab the frame from. Defaults to 60s in, so
        you skip black intro frames; capped to the video's actual duration
        by ffmpeg itself if it's shorter.

    .PARAMETER FfmpegPath
        Override path to ffmpeg.exe. Defaults to $env:LAUNCHER_FFMPEG or
        'ffmpeg' on PATH.

    .EXAMPLE
        $frame = Capture-FrameFromVideo -VideoPath $currentMovie -TimestampSeconds 120
        if ($frame) { Set-Wallpaper -Path $frame -Style Fill }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VideoPath,

        [int]$TimestampSeconds = 60,

        [string]$FfmpegPath = $(if ($env:LAUNCHER_FFMPEG) { $env:LAUNCHER_FFMPEG } else { 'ffmpeg' })
    )

    if (-not (Test-Path -LiteralPath $VideoPath)) {
        Write-WallpaperLog "Capture-FrameFromVideo: video not found - $VideoPath" -Level ERROR
        return $null
    }

    $ffmpegCmd = Get-Command $FfmpegPath -ErrorAction SilentlyContinue
    if (-not $ffmpegCmd) {
        Write-WallpaperLog "Capture-FrameFromVideo: ffmpeg not found ('$FfmpegPath'). Set `$env:LAUNCHER_FFMPEG or add it to PATH." -Level ERROR
        return $null
    }

    if (-not (Test-Path -LiteralPath $script:WallpaperCacheDir)) {
        New-Item -ItemType Directory -Path $script:WallpaperCacheDir -Force | Out-Null
    }

    if (Test-Path -LiteralPath $script:WallpaperFramePng) {
        Remove-Item -LiteralPath $script:WallpaperFramePng -Force -ErrorAction SilentlyContinue
    }

    $ts = [TimeSpan]::FromSeconds($TimestampSeconds).ToString('hh\:mm\:ss')

    $ffArgs = @(
        '-y'
        '-ss', $ts
        '-i', $VideoPath
        '-frames:v', '1'
        '-q:v', '2'
        $script:WallpaperFramePng
    )

    try {
        $proc = Start-Process -FilePath $ffmpegCmd.Source -ArgumentList $ffArgs `
                    -NoNewWindow -PassThru -Wait `
                    -RedirectStandardError (Join-Path $script:WallpaperCacheDir 'ffmpeg_stderr.log')

        if ($proc.ExitCode -ne 0) {
            Write-WallpaperLog "ffmpeg exited with code $($proc.ExitCode) capturing frame from $VideoPath" -Level ERROR
            return $null
        }

        if (-not (Test-Path -LiteralPath $script:WallpaperFramePng)) {
            Write-WallpaperLog "ffmpeg reported success but output frame is missing." -Level ERROR
            return $null
        }

        Write-WallpaperLog "Captured frame from '$VideoPath' at ${ts} -> $script:WallpaperFramePng"
        return $script:WallpaperFramePng
    }
    catch {
        Write-WallpaperLog "Capture-FrameFromVideo failed: $($_.Exception.Message)" -Level ERROR
        return $null
    }
}

# ---------------------------------------------------------------------------
# Public: Clear-WallpaperCache
# ---------------------------------------------------------------------------
function Clear-WallpaperCache {
    <#
    .SYNOPSIS
        Deletes cached frame captures and temp files. Keeps the backup and
        config by default so a restore is still possible.

    .PARAMETER IncludeBackup
        Also remove the saved backup wallpaper and config (full reset).
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeBackup
    )

    $targets = @($script:WallpaperFramePng, $script:WallpaperCurrentBmp)
    if ($IncludeBackup) {
        $targets += @($script:WallpaperBackupPath, $script:WallpaperConfigPath)
    }

    foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t) {
            Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue
        }
    }

    Write-WallpaperLog "Wallpaper cache cleared. (IncludeBackup: $IncludeBackup)"
}

# ---------------------------------------------------------------------------
# High-level convenience wrapper for launcher integration
# ---------------------------------------------------------------------------
function Set-MovieFrameWallpaper {
    <#
    .SYNOPSIS
        One-shot helper: backs up current wallpaper, grabs a frame from the
        playing movie, and sets it. Meant to be called right after playback
        starts in Player.ps1.

    .EXAMPLE
        Set-MovieFrameWallpaper -VideoPath $movie.FullPath -Style Fill
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VideoPath,

        [ValidateSet('Center','Tile','Stretch','Fit','Fill','Span')]
        [string]$Style = 'Fill',

        [int]$TimestampSeconds = 60
    )

    Backup-Wallpaper | Out-Null

    $frame = Capture-FrameFromVideo -VideoPath $VideoPath -TimestampSeconds $TimestampSeconds
    if (-not $frame) {
        Write-WallpaperLog "Set-MovieFrameWallpaper: frame capture failed, wallpaper left unchanged." -Level WARN
        return $false
    }

    return Set-Wallpaper -Path $frame -Style $Style -SkipBackup
}
