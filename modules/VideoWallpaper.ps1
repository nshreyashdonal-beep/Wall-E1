<#
.SYNOPSIS
    VideoWallpaper.ps1 - Plays a video file as a live desktop wallpaper by
    embedding a borderless WPF window (with a MediaElement) into Windows'
    hidden "WorkerW" window - the layer that sits directly behind the
    desktop icons. Same trick Wallpaper Engine / Lively use.

.DESCRIPTION
    One hidden window + player is created once per app session
    (Initialize-VideoWallpaperWindow) and reused for every video from then
    on - Show-VideoWallpaper just swaps the Source and un-hides it,
    Hide-VideoWallpaper stops it and hides it again so the normal static
    desktop wallpaper (set via Wallpaper.ps1) shows through underneath.

    Loaded by Wall-E.ps1 alongside the other modules/*.ps1 files.
#>

Add-Type -AssemblyName System.Windows.Forms

if (-not ([System.Management.Automation.PSTypeName]'Win32.VideoWallpaperNative').Type) {
    Add-Type -Namespace Win32 -Name VideoWallpaperNative -MemberDefinition @"
        [DllImport("user32.dll")]
        public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll")]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
            uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);

        [DllImport("user32.dll")]
        public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
"@
}

$script:VideoWallpaperWindow   = $null
$script:VideoWallpaperPlayer   = $null
$script:VideoWallpaperGrid     = $null
$script:VideoWallpaperBarTop    = $null
$script:VideoWallpaperBarBottom = $null
$script:VideoWallpaperBarLeft   = $null
$script:VideoWallpaperBarRight  = $null
$script:VideoWallpaperOnEnded  = $null
$script:VideoWallpaperCurrentPath = $null
$script:VideoWallpaperScreenBounds = $null
$script:VideoWorkerW           = [IntPtr]::Zero

function Get-VideoWorkerWHandle {
    # Ask Progman (the desktop's core window) to spawn a WorkerW behind the
    # icons - undocumented but stable since Vista. Then find the SIBLING
    # WorkerW (next to the one holding SHELLDLL_DefView/the icons) - that's
    # the one that sits just behind the icons, which is what we draw into.
    $progman = [Win32.VideoWallpaperNative]::FindWindow("Progman", $null)
    $result = [IntPtr]::Zero
    [Win32.VideoWallpaperNative]::SendMessageTimeout($progman, 0x052C, [IntPtr]::Zero, [IntPtr]::Zero, 0x0, 1000, [ref]$result) | Out-Null

    $script:VideoWorkerW = [IntPtr]::Zero
    $enumProc = {
        param($hwnd, $lparam)
        $shellView = [Win32.VideoWallpaperNative]::FindWindowEx($hwnd, [IntPtr]::Zero, "SHELLDLL_DefView", $null)
        if ($shellView -ne [IntPtr]::Zero) {
            $script:VideoWorkerW = [Win32.VideoWallpaperNative]::FindWindowEx([IntPtr]::Zero, $hwnd, "WorkerW", $null)
        }
        return $true
    }
    [Win32.VideoWallpaperNative]::EnumWindows($enumProc, [IntPtr]::Zero) | Out-Null
    return $script:VideoWorkerW
}

function Initialize-VideoWallpaperWindow {
    <#
    .SYNOPSIS
        Creates and embeds the hidden video-wallpaper window, once. Safe to
        call repeatedly - later calls are no-ops. Returns $true if it
        managed to embed behind the desktop icons, $false if the WorkerW
        trick failed (video will simply not be shown rather than popping up
        as a normal window).
    #>
    if ($script:VideoWallpaperWindow) { return $true }

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False"
        Topmost="False" Background="Black">
    <Grid x:Name="Root" Background="Black">
        <MediaElement x:Name="Player" LoadedBehavior="Manual" UnloadedBehavior="Manual"
                      Stretch="UniformToFill"
                      HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/>
        <!-- Opaque black masks drawn ON TOP of the video (later = higher
             Z in a Grid). Forcing an aspect ratio by resizing/Stretch-ing
             the MediaElement alone isn't reliable here: MediaElement's
             video surface (especially with hardware/DXVA decoding) is
             known to sometimes ignore its own WPF layout bounds when
             hosted in an unusual reparented window like this WorkerW
             embed, and just paints across the whole native window
             regardless of Width/Height/Stretch. These masks guarantee
             the letterbox/pillarbox bars show correctly no matter what
             the video surface itself decides to do underneath. Sized to
             0 (invisible) unless a forced aspect ratio is active. -->
        <Rectangle x:Name="BarTop"    Fill="Black" Height="0" VerticalAlignment="Top"    HorizontalAlignment="Stretch"/>
        <Rectangle x:Name="BarBottom" Fill="Black" Height="0" VerticalAlignment="Bottom" HorizontalAlignment="Stretch"/>
        <Rectangle x:Name="BarLeft"   Fill="Black" Width="0"  HorizontalAlignment="Left"  VerticalAlignment="Stretch"/>
        <Rectangle x:Name="BarRight"  Fill="Black" Width="0"  HorizontalAlignment="Right" VerticalAlignment="Stretch"/>
    </Grid>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $script:VideoWallpaperWindow = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:VideoWallpaperPlayer = $script:VideoWallpaperWindow.FindName('Player')
    $script:VideoWallpaperGrid   = $script:VideoWallpaperWindow.FindName('Root')
    $script:VideoWallpaperBarTop    = $script:VideoWallpaperWindow.FindName('BarTop')
    $script:VideoWallpaperBarBottom = $script:VideoWallpaperWindow.FindName('BarBottom')
    $script:VideoWallpaperBarLeft   = $script:VideoWallpaperWindow.FindName('BarLeft')
    $script:VideoWallpaperBarRight  = $script:VideoWallpaperWindow.FindName('BarRight')

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $script:VideoWallpaperScreenBounds = $screen
    $script:VideoWallpaperWindow.Left   = 0
    $script:VideoWallpaperWindow.Top    = 0
    $script:VideoWallpaperWindow.Width  = $screen.Width
    $script:VideoWallpaperWindow.Height = $screen.Height

    # Loop, and fire the caller's "advance to next" callback on every loop
    # boundary (the caller decides whether that means "restart" or "move on
    # to the next image/video" - see Show-VideoWallpaper).
    $script:VideoWallpaperPlayer.Add_MediaEnded({
        $script:VideoWallpaperPlayer.Position = [TimeSpan]::Zero
        if ($script:VideoWallpaperOnEnded) {
            & $script:VideoWallpaperOnEnded
        } else {
            $script:VideoWallpaperPlayer.Play()
        }
    })

    $embedded = $false
    $script:VideoWallpaperWindow.Add_SourceInitialized({
        $helper  = New-Object System.Windows.Interop.WindowInteropHelper($script:VideoWallpaperWindow)
        $hwnd    = $helper.Handle
        $workerw = Get-VideoWorkerWHandle
        if ($workerw -ne [IntPtr]::Zero) {
            [Win32.VideoWallpaperNative]::SetParent($hwnd, $workerw) | Out-Null
            [Win32.VideoWallpaperNative]::MoveWindow($hwnd, 0, 0, $screen.Width, $screen.Height, $true) | Out-Null
        } else {
            Write-Warning "Video wallpaper: could not locate WorkerW - videos will not play as a live wallpaper on this system."
        }
    })

    # Show once so the HWND is created (fires SourceInitialized/embedding
    # above), then hide - Show-VideoWallpaper un-hides it on demand.
    $script:VideoWallpaperWindow.Show()
    $script:VideoWallpaperWindow.Hide()
    return $true
}

function Set-VideoWallpaperAspectRatio {
    <#
    .SYNOPSIS
        Forces the MediaElement's displayed shape to a given aspect ratio
        (width/height), the same way VLC's "Aspect Ratio" menu does - NOT
        to be confused with Stretch (Fit/Fill/Stretch/Center), which only
        controls how the source is scaled *within* whatever shape the
        MediaElement currently has.

        Picks the largest rectangle of that ratio that fits inside the
        screen, resizes/centers the MediaElement to exactly that rectangle
        (leaving black bars - letterbox/pillarbox - in the rest of the
        window), and stretches the source to fill it exactly.

        Pass $null (or 0) for AspectRatio to go back to "Default": the
        MediaElement fills the whole screen with Stretch=UniformToFill.
    #>
    param([double]$AspectRatio = 0)

    if (-not $script:VideoWallpaperPlayer -or -not $script:VideoWallpaperGrid) { return }

    if ($AspectRatio -le 0) {
        # Default - no forced shape, just cover the whole screen, no bars.
        $script:VideoWallpaperPlayer.HorizontalAlignment = 'Stretch'
        $script:VideoWallpaperPlayer.VerticalAlignment    = 'Stretch'
        $script:VideoWallpaperPlayer.Width  = [double]::NaN
        $script:VideoWallpaperPlayer.Height = [double]::NaN
        $script:VideoWallpaperPlayer.Stretch = [System.Windows.Media.Stretch]::UniformToFill
        Set-VideoWallpaperBars -TopBottom 0 -LeftRight 0
        return
    }

    $bounds = $script:VideoWallpaperScreenBounds
    if (-not $bounds) { $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds }
    $screenW = [double]$bounds.Width
    $screenH = [double]$bounds.Height

    # Largest rectangle with the target ratio that still fits inside the
    # screen bounds (classic letterbox/pillarbox fit math).
    $targetW = $screenW
    $targetH = $targetW / $AspectRatio
    if ($targetH -gt $screenH) {
        $targetH = $screenH
        $targetW = $targetH * $AspectRatio
    }

    $script:VideoWallpaperPlayer.HorizontalAlignment = 'Center'
    $script:VideoWallpaperPlayer.VerticalAlignment    = 'Center'
    $script:VideoWallpaperPlayer.Width  = $targetW
    $script:VideoWallpaperPlayer.Height = $targetH
    # Fill (not Uniform/UniformToFill) so the source is stretched to
    # exactly match the forced shape - mirrors VLC's forced-DAR behavior.
    $script:VideoWallpaperPlayer.Stretch = [System.Windows.Media.Stretch]::Fill

    $barTopBottom = [Math]::Max(0, ($screenH - $targetH) / 2)
    $barLeftRight = [Math]::Max(0, ($screenW - $targetW) / 2)
    Set-VideoWallpaperBars -TopBottom $barTopBottom -LeftRight $barLeftRight
}

# Sizes the four opaque black mask rectangles that sit on top of the video
# (see the .NOTES on why these exist rather than trusting the MediaElement
# to clip/letterbox itself).
function Set-VideoWallpaperBars {
    param([double]$TopBottom = 0, [double]$LeftRight = 0)
    if ($script:VideoWallpaperBarTop)    { $script:VideoWallpaperBarTop.Height    = $TopBottom }
    if ($script:VideoWallpaperBarBottom) { $script:VideoWallpaperBarBottom.Height = $TopBottom }
    if ($script:VideoWallpaperBarLeft)   { $script:VideoWallpaperBarLeft.Width    = $LeftRight }
    if ($script:VideoWallpaperBarRight)  { $script:VideoWallpaperBarRight.Width   = $LeftRight }
}

function Show-VideoWallpaper {
    <#
    .SYNOPSIS
        Plays the given video, embedded behind the desktop icons, replacing
        whatever static wallpaper is currently showing (which stays set
        underneath and reappears the moment Hide-VideoWallpaper is called).

    .PARAMETER AspectRatio
        Forces the video's display aspect ratio (width/height), the same
        way VLC's Aspect Ratio menu does - e.g. 1.7777778 for 16:9, 1.3333
        for 4:3. Pass 0 (the default) for "Default": no forced shape, video
        covers the full screen (cropped as needed).

    .PARAMETER OnEnded
        Scriptblock invoked every time the video finishes playing (after
        it's already been looped back to frame 0) - e.g. "jump to the next
        image/video in the library". Runs on the UI dispatcher thread.

    .NOTES
        Calling this again with the SAME path that's already playing (e.g.
        because the user just changed the aspect-ratio dropdown) does NOT
        reset playback - only aspect ratio/Muted are updated live, so the
        video keeps playing from wherever it currently is instead of
        jumping back to frame 0.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [bool]$Muted = $true,
        [double]$AspectRatio = 0,
        [scriptblock]$OnEnded = $null
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    Initialize-VideoWallpaperWindow | Out-Null

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $script:VideoWallpaperOnEnded = $OnEnded
    Set-VideoWallpaperAspectRatio -AspectRatio $AspectRatio
    $script:VideoWallpaperPlayer.IsMuted = $Muted

    $alreadyPlayingThis = $script:VideoWallpaperCurrentPath -and
        ($script:VideoWallpaperCurrentPath -eq $resolvedPath) -and
        (Test-VideoWallpaperActive)

    if (-not $alreadyPlayingThis) {
        $script:VideoWallpaperPlayer.Stop()
        $script:VideoWallpaperPlayer.Source = New-Object System.Uri($resolvedPath)
        $script:VideoWallpaperCurrentPath = $resolvedPath
        $script:VideoWallpaperWindow.Show()
        $script:VideoWallpaperPlayer.Play()
    }

    return $true
}

function Hide-VideoWallpaper {
    <#
    .SYNOPSIS
        Stops and hides the video wallpaper window (a no-op if it isn't
        currently showing). The static wallpaper set via Set-Wallpaper
        reappears immediately - nothing else needs to change.
    #>
    if (-not $script:VideoWallpaperWindow) { return }
    $script:VideoWallpaperOnEnded = $null
    $script:VideoWallpaperCurrentPath = $null
    $script:VideoWallpaperPlayer.Stop()
    $script:VideoWallpaperPlayer.Source = $null
    $script:VideoWallpaperWindow.Hide()
}

function Test-VideoWallpaperActive {
    [bool]($script:VideoWallpaperWindow -and $script:VideoWallpaperWindow.IsVisible)
}

function Set-VideoWallpaperMuted {
    param([Parameter(Mandatory)][bool]$Muted)
    if ($script:VideoWallpaperPlayer) { $script:VideoWallpaperPlayer.IsMuted = $Muted }
}

function Uninitialize-VideoWallpaperInfrastructure {
    <#
    .SYNOPSIS
        Call on app shutdown - stops playback and closes the hidden window
        so nothing is left running (or holding the video file open) after
        Wall-E exits.
    #>
    if ($script:VideoWallpaperPlayer) { try { $script:VideoWallpaperPlayer.Stop() } catch { } }
    if ($script:VideoWallpaperWindow) { try { $script:VideoWallpaperWindow.Close() } catch { } }
    $script:VideoWallpaperCurrentPath = $null
    $script:VideoWallpaperWindow = $null
    $script:VideoWallpaperPlayer = $null
}
