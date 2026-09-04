<#
.SYNOPSIS
    VideoMarkers.ps1 - Per-file "play only this section" trim markers for
    video items (start/end, in seconds).

.DESCRIPTION
    Backed by a single JSON file (VideoMarkers.json) alongside config.json
    (see $script:PlayerConfigDir, defined in SnapshotLibrary.ps1 - that
    module is dot-sourced first in Wall-E.ps1, so it's already set by the
    time this file loads), keyed by each video's full file path. A file
    with no entry here plays its full length, same as before this feature
    existed - Get-VideoMarker returns $null in that case, and every caller
    is expected to fall back to "start at 0 / end at the real duration".

    Markers only affect PLAYBACK (where a video starts, and where it loops/
    hands off to "next" - see the poll timers in Wall-E.ps1 and
    VideoWallpaper.ps1 that enforce the end point). They never touch the
    underlying file.
#>

$script:VideoMarkersPath = Join-Path $script:PlayerConfigDir 'VideoMarkers.json'
$script:VideoMarkers = @{}

function Import-VideoMarkers {
    <#
    .SYNOPSIS
        Loads VideoMarkers.json into $script:VideoMarkers. Safe to call once
        at startup; a missing or corrupt file just leaves the in-memory
        table empty (equivalent to "no markers set for anything").
    #>
    [CmdletBinding()]
    param()

    $script:VideoMarkers = @{}
    if (-not (Test-Path -LiteralPath $script:VideoMarkersPath)) { return }

    try {
        $raw = Get-Content -LiteralPath $script:VideoMarkersPath -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) {
            $start = [double]$prop.Value.Start
            $end   = [double]$prop.Value.End
            if ($end -gt $start) {
                $script:VideoMarkers[$prop.Name] = @{ Start = $start; End = $end }
            }
        }
    }
    catch {
        Write-Warning "Video markers file corrupt, ignoring saved markers: $($_.Exception.Message)"
        $script:VideoMarkers = @{}
    }
}

function Export-VideoMarkers {
    [CmdletBinding()]
    param()

    if (-not (Test-Path -LiteralPath $script:PlayerConfigDir)) {
        New-Item -ItemType Directory -Path $script:PlayerConfigDir -Force | Out-Null
    }

    try {
        # Depth 3 is plenty - this is just path -> {Start, End}.
        $script:VideoMarkers | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:VideoMarkersPath -Encoding UTF8
        return $true
    }
    catch {
        Write-Warning "Failed to save video markers: $($_.Exception.Message)"
        return $false
    }
}

function Get-VideoMarker {
    <#
    .SYNOPSIS
        Returns @{ Start = <seconds>; End = <seconds> } for the given path,
        or $null if no marker is set (i.e. the video should play in full).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ($script:VideoMarkers.ContainsKey($Path)) { return $script:VideoMarkers[$Path] }
    return $null
}

function Set-VideoMarker {
    <#
    .SYNOPSIS
        Persists a start/end trim point (in seconds) for the given video
        path. Clamped so Start is never negative and End never precedes
        Start by less than half a second (a degenerate/zero-length marker
        would just spin the poll timer with nothing to actually play).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][double]$Start,
        [Parameter(Mandatory)][double]$End
    )

    $clampedStart = [Math]::Max(0, $Start)
    $clampedEnd   = [Math]::Max($clampedStart + 0.5, $End)

    $script:VideoMarkers[$Path] = @{ Start = $clampedStart; End = $clampedEnd }
    Export-VideoMarkers | Out-Null
}

function Clear-VideoMarker {
    <#
    .SYNOPSIS
        Removes any saved marker for the given path - it goes back to
        playing in full.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ($script:VideoMarkers.ContainsKey($Path)) {
        $script:VideoMarkers.Remove($Path)
        Export-VideoMarkers | Out-Null
    }
}

Import-VideoMarkers
