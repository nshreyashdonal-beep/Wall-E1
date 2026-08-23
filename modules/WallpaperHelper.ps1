<#
.SYNOPSIS
    WallpaperHelper.ps1 - Low-level Win32 interop for setting the desktop wallpaper.

.DESCRIPTION
    Wraps SystemParametersInfo (user32.dll) and the registry keys that control
    wallpaper style (Fill/Fit/Stretch/Center/Span/Tile). Loaded by Wallpaper.ps1;
    not intended to be dot-sourced directly by end users.
#>

# ---------------------------------------------------------------------------
# Win32 P/Invoke definition (only added once per session)
# ---------------------------------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'Win32.Wallpaper').Type) {
    Add-Type -Namespace Win32 -Name Wallpaper -MemberDefinition @"
        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
"@
}

# SPI_SETDESKWALLPAPER = 0x0014 (20)
$script:SPI_SETDESKWALLPAPER = 0x0014
$script:SPIF_UPDATEINIFILE   = 0x01
$script:SPIF_SENDCHANGE      = 0x02

# Registry style codes: WallpaperStyle / TileWallpaper
# Style   -> WallpaperStyle : TileWallpaper
$script:WallpaperStyleMap = @{
    Center  = @{ WallpaperStyle = '0'; TileWallpaper = '0' }
    Tile    = @{ WallpaperStyle = '0'; TileWallpaper = '1' }
    Stretch = @{ WallpaperStyle = '2'; TileWallpaper = '0' }
    Fit     = @{ WallpaperStyle = '6'; TileWallpaper = '0' }
    Fill    = @{ WallpaperStyle = '10'; TileWallpaper = '0' }
    Span    = @{ WallpaperStyle = '22'; TileWallpaper = '0' }  # Win8+, multi-monitor
}

function Set-WallpaperRegistryStyle {
    <#
    .SYNOPSIS
        Writes the WallpaperStyle/TileWallpaper values that control how the
        image is scaled. Must be called BEFORE SystemParametersInfo for the
        style to take effect immediately.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Center','Tile','Stretch','Fit','Fill','Span')]
        [string]$Style
    )

    $regPath = 'HKCU:\Control Panel\Desktop'
    $values  = $script:WallpaperStyleMap[$Style]

    try {
        Set-ItemProperty -Path $regPath -Name WallpaperStyle -Value $values.WallpaperStyle -ErrorAction Stop
        Set-ItemProperty -Path $regPath -Name TileWallpaper  -Value $values.TileWallpaper  -ErrorAction Stop
        return $true
    }
    catch {
        Write-Error "Set-WallpaperRegistryStyle: failed to write registry values - $($_.Exception.Message)"
        return $false
    }
}

function Invoke-SystemParametersInfoWallpaper {
    <#
    .SYNOPSIS
        Calls the actual Win32 SystemParametersInfo to apply the wallpaper.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "Invoke-SystemParametersInfoWallpaper: file not found - $Path"
        return $false
    }

    # SystemParametersInfo only reliably supports BMP/JPG/PNG on modern Windows.
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath

    $result = [Win32.Wallpaper]::SystemParametersInfo(
        $script:SPI_SETDESKWALLPAPER,
        0,
        $resolved,
        ($script:SPIF_UPDATEINIFILE -bor $script:SPIF_SENDCHANGE)
    )

    if ($result -eq 0) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Error "Invoke-SystemParametersInfoWallpaper: SystemParametersInfo failed (Win32 error $err)"
        return $false
    }

    return $true
}

function Get-RegistryWallpaperPath {
    <#
    .SYNOPSIS
        Reads the currently configured wallpaper path from the registry.
        This is more reliable than re-deriving it, since Windows itself
        rewrites this value (and may convert the image internally to
        %APPDATA%\Microsoft\Windows\Themes\TranscodedWallpaper).
    #>
    try {
        (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -ErrorAction Stop).Wallpaper
    }
    catch {
        $null
    }
}
