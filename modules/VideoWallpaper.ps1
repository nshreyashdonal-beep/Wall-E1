<#
.SYNOPSIS
    VideoWallpaper.ps1 - Plays a video file as a live desktop wallpaper by
    embedding a borderless WPF window (with two overlapping MediaElements)
    into Windows' hidden "WorkerW" window - the layer that sits directly
    behind the desktop icons. Same trick Wallpaper Engine / Lively use.

.DESCRIPTION
    One hidden window is created once per app session
    (Initialize-VideoWallpaperWindow) and reused for every video from then
    on. It holds TWO MediaElements stacked on top of each other rather than
    one - only one is ever "active" (playing, fully opaque) at a time, but
    keeping a second one around lets Show-VideoWallpaper crossfade smoothly
    into it instead of hard-cutting the Source of a single player, which
    would show a black/flashed frame for a moment. Show-VideoWallpaper
    plays the new video into the currently-inactive MediaElement and fades
    it in while fading the old one out; Hide-VideoWallpaper stops both and
    hides the window again so the normal static desktop wallpaper (set via
    Wallpaper.ps1) shows through underneath.

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

$script:VideoWallpaperWindow    = $null
$script:VideoWallpaperPlayers   = @()     # two MediaElements, index 0 and 1
$script:VideoWallpaperActive    = 0       # which index is currently the visible/audible one
$script:VideoWallpaperGrid      = $null
$script:VideoWallpaperBarTop    = $null
$script:VideoWallpaperBarBottom = $null
$script:VideoWallpaperBarLeft   = $null
$script:VideoWallpaperBarRight  = $null
$script:VideoWallpaperOnEnded   = $null
$script:VideoWallpaperCurrentPath  = $null
$script:VideoWallpaperScreenBounds = $null
$script:VideoWallpaperFadeMs    = 700      # crossfade duration between two videos, ms
$script:VideoWorkerW            = [IntPtr]::Zero

function Get-VWActivePlayer   { $script:VideoWallpaperPlayers[$script:VideoWallpaperActive] }
function Get-VWInactivePlayer { $script:VideoWallpaperPlayers[1 - $script:VideoWallpaperActive] }

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
        <!-- Two overlapping players so Show-VideoWallpaper can crossfade
             between them (play the next video into whichever one is
             currently idle, fade it in while fading the other out) instead
             of hard-swapping a single MediaElement's Source, which shows a
             black/flashed frame for a moment. Only one is "active"
             (opaque + audible) at a time - see $script:VideoWallpaperActive. -->
        <MediaElement x:Name="PlayerA" LoadedBehavior="Manual" UnloadedBehavior="Manual"
                      Stretch="UniformToFill" Opacity="0"
                      HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/>
        <MediaElement x:Name="PlayerB" LoadedBehavior="Manual" UnloadedBehavior="Manual"
                      Stretch="UniformToFill" Opacity="0"
                      HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/>
        <!-- Opaque black masks drawn ON TOP of both players (later = higher
             Z in a Grid). Forcing an aspect ratio by resizing/Stretch-ing
             the MediaElements alone isn't reliable here: MediaElement's
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
    $playerA = $script:VideoWallpaperWindow.FindName('PlayerA')
    $playerB = $script:VideoWallpaperWindow.FindName('PlayerB')
    $script:VideoWallpaperPlayers = @($playerA, $playerB)
    $script:VideoWallpaperActive  = 0
    $script:VideoWallpaperGrid    = $script:VideoWallpaperWindow.FindName('Root')
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

    # Loop, or fire the caller's "advance to next" callback, when a video
    # reaches its end - but only for whichever player is CURRENTLY the
    # active one. During a crossfade the outgoing player is momentarily
    # still "playing" (fading to transparent) and its own MediaEnded isn't
    # relevant anymore since Show-VideoWallpaper already moved on.
    $onEndedHandler = {
        $sender = $this
        if ($sender -ne (Get-VWActivePlayer)) { return }
        if ($script:VideoWallpaperOnEnded) {
            # The caller (Wall-E.ps1) decides what plays next - e.g. jump
            # to the next image/video. Pause (freeze on the final frame)
            # rather than Stop/rewind, so this player has a proper last
            # frame to crossfade FROM instead of jumping back to frame 0
            # or going black while the caller's decision/transition happens.
            $sender.Pause()
            & $script:VideoWallpaperOnEnded
        } else {
            # No caller-supplied "what's next" logic - just loop this video.
            $sender.Position = [TimeSpan]::Zero
            $sender.Play()
        }
    }
    $playerA.Add_MediaEnded($onEndedHandler)
    $playerB.Add_MediaEnded($onEndedHandler)

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
        Forces both MediaElements' displayed shape to a given aspect ratio
        (width/height), the same way VLC's "Aspect Ratio" menu does - NOT
        to be confused with Stretch (Fit/Fill/Stretch/Center), which only
        controls how the source is scaled *within* whatever shape the
        MediaElement currently has.

        Picks the largest rectangle of that ratio that fits inside the
        screen, resizes/centers both players to exactly that rectangle
        (leaving black bars - letterbox/pillarbox - in the rest of the
        window), and stretches the source to fill it exactly. Applied to
        BOTH players identically (not just whichever is active) so that
        crossfading between them never crossfades between two different
        shapes/sizes.

        Pass $null (or 0) for AspectRatio to go back to "Default": both
        players fill the whole screen with Stretch=UniformToFill.
    #>
    param([double]$AspectRatio = 0)

    if (-not $script:VideoWallpaperPlayers -or $script:VideoWallpaperPlayers.Count -eq 0 -or -not $script:VideoWallpaperGrid) { return }

    if ($AspectRatio -le 0) {
        # Default - no forced shape, just cover the whole screen, no bars.
        foreach ($p in $script:VideoWallpaperPlayers) {
            $p.HorizontalAlignment = 'Stretch'
            $p.VerticalAlignment    = 'Stretch'
            $p.Width  = [double]::NaN
            $p.Height = [double]::NaN
            $p.Stretch = [System.Windows.Media.Stretch]::UniformToFill
        }
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

    foreach ($p in $script:VideoWallpaperPlayers) {
        $p.HorizontalAlignment = 'Center'
        $p.VerticalAlignment    = 'Center'
        $p.Width  = $targetW
        $p.Height = $targetH
        # Fill (not Uniform/UniformToFill) so the source is stretched to
        # exactly match the forced shape - mirrors VLC's forced-DAR behavior.
        $p.Stretch = [System.Windows.Media.Stretch]::Fill
    }

    $barTopBottom = [Math]::Max(0, ($screenH - $targetH) / 2)
    $barLeftRight = [Math]::Max(0, ($screenW - $targetW) / 2)
    Set-VideoWallpaperBars -TopBottom $barTopBottom -LeftRight $barLeftRight
}

# Sizes the four opaque black mask rectangles that sit on top of both video
# players (see the .NOTES on why these exist rather than trusting the
# MediaElements to clip/letterbox themselves).
function Set-VideoWallpaperBars {
    param([double]$TopBottom = 0, [double]$LeftRight = 0)
    if ($script:VideoWallpaperBarTop)    { $script:VideoWallpaperBarTop.Height    = $TopBottom }
    if ($script:VideoWallpaperBarBottom) { $script:VideoWallpaperBarBottom.Height = $TopBottom }
    if ($script:VideoWallpaperBarLeft)   { $script:VideoWallpaperBarLeft.Width    = $LeftRight }
    if ($script:VideoWallpaperBarRight)  { $script:VideoWallpaperBarRight.Width   = $LeftRight }
}

function Start-VideoWallpaperCrossfade {
    <#
    .SYNOPSIS
        Smoothly fades $From out and $To in over $script:VideoWallpaperFadeMs,
        then stops/unloads $From once the fade completes. Flips
        $script:VideoWallpaperActive to $To's index immediately (not when
        the fade finishes) so a MediaEnded firing on $To mid-fade is still
        correctly recognized as "the active player".

        Uses an ease-in/ease-out curve rather than a linear one. A linear
        opacity blend between two DIFFERENT video frames tends to look
        slightly "muddy" or dip in the middle (you're briefly looking at
        two unrelated images at ~50% each) - easing spends less time
        lingering in that mid-blend zone and more time near the start/end
        where one video clearly dominates, which reads as noticeably
        smoother even though the total duration is the same.
    #>
    param(
        [Parameter(Mandatory)]$From,
        [Parameter(Mandatory)]$To
    )

    $duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds($script:VideoWallpaperFadeMs))
    $ease = New-Object System.Windows.Media.Animation.QuadraticEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut

    $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, $duration)
    $fadeOut.EasingFunction = $ease
    $fadeIn  = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, $duration)
    $fadeIn.EasingFunction = $ease

    # Release the outgoing player only once it's fully transparent, so it
    # keeps displaying its frozen last frame for the whole fade rather than
    # cutting away early.
    $fadeOut.add_Completed({
        try { $From.Stop() } catch { }
        try { $From.Source = $null } catch { }
    }.GetNewClosure())

    $newIndex = $script:VideoWallpaperPlayers.IndexOf($To)
    if ($newIndex -ge 0) { $script:VideoWallpaperActive = $newIndex }

    $From.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeOut)
    $To.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)
}

function Show-VideoWallpaper {
    <#
    .SYNOPSIS
        Plays the given video, embedded behind the desktop icons, replacing
        whatever static wallpaper is currently showing (which stays set
        underneath and reappears the moment Hide-VideoWallpaper is called).
        If another video is already playing, crossfades smoothly into the
        new one instead of cutting/flashing to black.

    .PARAMETER AspectRatio
        Forces the video's display aspect ratio (width/height), the same
        way VLC's Aspect Ratio menu does - e.g. 1.7777778 for 16:9, 1.3333
        for 4:3. Pass 0 (the default) for "Default": no forced shape, video
        covers the full screen (cropped as needed).

    .PARAMETER OnEnded
        Scriptblock invoked every time the video finishes playing (after
        it's already been paused on its final frame) - e.g. "jump to the
        next image/video in the library". Runs on the UI dispatcher thread.

    .NOTES
        Calling this again with the SAME path that's already playing (e.g.
        because the user just changed the aspect-ratio dropdown) does NOT
        reset playback - only aspect ratio/Muted are updated live, so the
        video keeps playing from wherever it currently is instead of
        jumping back to frame 0 or restarting a crossfade.
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

    $activePlayer = Get-VWActivePlayer

    $alreadyPlayingThis = $script:VideoWallpaperCurrentPath -and
        ($script:VideoWallpaperCurrentPath -eq $resolvedPath) -and
        (Test-VideoWallpaperActive)

    if ($alreadyPlayingThis) {
        $activePlayer.IsMuted = $Muted
        return $true
    }

    $wasAlreadyShowing = Test-VideoWallpaperActive
    $inactivePlayer = Get-VWInactivePlayer

    $inactivePlayer.Stop()
    $inactivePlayer.IsMuted = $Muted
    $inactivePlayer.Source  = New-Object System.Uri($resolvedPath)
    $inactivePlayer.Opacity = 0
    $script:VideoWallpaperWindow.Show()
    $inactivePlayer.Play()
    $script:VideoWallpaperCurrentPath = $resolvedPath

    if ($wasAlreadyShowing) {
        # Something's already on screen (another video mid-crossfade or
        # naturally ending) - fade smoothly between the two instead of
        # cutting straight to the new one.
        Start-VideoWallpaperCrossfade -From $activePlayer -To $inactivePlayer
    } else {
        # First video since the window was last hidden - nothing to
        # crossfade FROM, so just show it immediately.
        $inactivePlayer.Opacity = 1
        $script:VideoWallpaperActive = $script:VideoWallpaperPlayers.IndexOf($inactivePlayer)
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
    foreach ($p in $script:VideoWallpaperPlayers) {
        # Cancel any in-flight crossfade animation so it doesn't fire its
        # Completed callback (touching a player mid-teardown) later.
        try { $p.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null) } catch { }
        try { $p.Stop() } catch { }
        try { $p.Source = $null } catch { }
        $p.Opacity = 0
    }
    $script:VideoWallpaperActive = 0
    $script:VideoWallpaperWindow.Hide()
}

function Test-VideoWallpaperActive {
    [bool]($script:VideoWallpaperWindow -and $script:VideoWallpaperWindow.IsVisible)
}

function Set-VideoWallpaperMuted {
    param([Parameter(Mandatory)][bool]$Muted)
    $active = Get-VWActivePlayer
    if ($active) { $active.IsMuted = $Muted }
}

function Restart-VideoWallpaper {
    <#
    .SYNOPSIS
        Replays the currently-active video from the beginning in place -
        used by the caller's OnEnded callback when the video should just
        loop forever rather than advance to the next item (e.g. Slideshow
        is off and this video is the "permanent" wallpaper, the same way a
        static image just stays put unchanged).
    #>
    $active = Get-VWActivePlayer
    if (-not $active) { return }
    $active.Position = [TimeSpan]::Zero
    $active.Play()
}

function Uninitialize-VideoWallpaperInfrastructure {
    <#
    .SYNOPSIS
        Call on app shutdown - stops playback and closes the hidden window
        so nothing is left running (or holding the video file open) after
        Wall-E exits.
    #>
    foreach ($p in $script:VideoWallpaperPlayers) {
        try { $p.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null) } catch { }
        try { $p.Stop() } catch { }
    }
    if ($script:VideoWallpaperWindow) { try { $script:VideoWallpaperWindow.Close() } catch { } }
    $script:VideoWallpaperCurrentPath = $null
    $script:VideoWallpaperWindow  = $null
    $script:VideoWallpaperPlayers = @()
    $script:VideoWallpaperActive  = 0
}
