<#
.SYNOPSIS
    Wall-E.ps1 - Browse folders of movie snapshots (and video clips) and set
    them as your desktop wallpaper, navigable with global arrow-key hotkeys.

.DESCRIPTION
    Right  = next image/video in current folder
    Left   = previous image/video in current folder
    Up     = next folder
    Down   = previous folder

    Hotkeys are global (system-wide) via Win32 RegisterHotKey - they fire
    even when this app's window isn't focused, as long as the app is
    running. Because they use bare arrow keys (no modifier), they will also
    intercept arrow key input meant for other apps; use the "Hotkeys
    enabled" checkbox to pause that when you need normal arrow keys
    elsewhere.

    S = toggle Slideshow (timed autoplay, per the interval combo box)
    P = toggle Quick Play (fast stop-motion flip-through, Low/Medium/High)
    Unlike the arrows, S/P only work while this app's window is focused -
    they are ordinary letters typed constantly elsewhere, so they are
    intentionally NOT registered as global hotkeys.

    VIDEO WALLPAPER: any .mp4/.wmv/.avi/.mov/.mkv/.m4v file dropped into a
    snapshot folder alongside images is played as a live wallpaper (via
    modules/VideoWallpaper.ps1's WorkerW embedding) instead of being set as
    a static image. When it finishes it automatically advances to the next
    item in the folder - same as Slideshow's "what's next" logic, including
    Shuffle. Muted by default; toggle audio in the VIDEO WALLPAPER section.

.NOTES
    Run with: powershell.exe -ExecutionPolicy Bypass -File Wall-E.ps1
    (or right-click > Run with PowerShell)
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

function Resolve-AppRoot {
    # Try every source in order; ps2exe-compiled exes are inconsistent
    # about which of these are populated, so we don't rely on just one.
    $candidates = @(
        { $PSScriptRoot },
        { if ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } },
        { if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } },
        { [System.AppDomain]::CurrentDomain.BaseDirectory },
        { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) },
        { (Get-Location).Path }
    )
    foreach ($c in $candidates) {
        try {
            $val = & $c
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                return $val.TrimEnd('\')
            }
        } catch { }
    }
    return $null
}

$root = Resolve-AppRoot
if ([string]::IsNullOrWhiteSpace($root)) {
    throw "Wall-E could not determine its own folder location (all root-path resolution methods returned empty) and cannot start."
}

# ---------------------------------------------------------------------------
# Load modules
# ---------------------------------------------------------------------------
. (Join-Path $root 'modules\Wallpaper.ps1')        # also dot-sources WallpaperHelper.ps1
. (Join-Path $root 'modules\SnapshotLibrary.ps1')
. (Join-Path $root 'modules\GlobalHotkey.ps1')
. (Join-Path $root 'modules\VideoWallpaper.ps1')
. (Join-Path $root 'modules\VideoMarkers.ps1')     # depends on $script:PlayerConfigDir - must load after SnapshotLibrary.ps1

Initialize-Wallpaper | Out-Null

# ---------------------------------------------------------------------------
# Load XAML
# ---------------------------------------------------------------------------
[xml]$xaml = Get-Content -LiteralPath (Join-Path $root 'UI\MainWindow.xaml') -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# App / taskbar icon (assets\icon.ico, sibling of this script/exe)
$iconPath = Join-Path $root 'assets\icon.ico'
if (Test-Path -LiteralPath $iconPath) {
    try {
        $window.Icon = New-Object System.Windows.Media.Imaging.BitmapImage (New-Object Uri($iconPath, [UriKind]::Absolute))
    } catch {
        Write-Warning "Could not load app icon: $($_.Exception.Message)"
    }
}

# Named element lookup
function Get-El { param($Name) $window.FindName($Name) }

# ---------------------------------------------------------------------------
# Full-screen preview window (lazy-loaded on first use, reused after that)
# ---------------------------------------------------------------------------
$script:FullScreenWindow = $null
$script:ImgFullScreen    = $null
$script:FsMediaHost      = $null
$script:HowToWindow      = $null

# ---------------------------------------------------------------------------
# "How to Use" help window (lazy-loaded on first open, reused after that)
# ---------------------------------------------------------------------------
function Show-HowToWindow {
    # Already open? Just bring it forward.
    if ($script:HowToWindow -and $script:HowToWindow.IsVisible) {
        $script:HowToWindow.Activate()
        return
    }

    [xml]$htXaml = Get-Content -LiteralPath (Join-Path $root 'UI\HowToWindow.xaml') -Raw -Encoding UTF8
    $htReader = New-Object System.Xml.XmlNodeReader $htXaml
    $script:HowToWindow = [System.Windows.Markup.XamlReader]::Load($htReader)
    $script:HowToWindow.Owner = $window

    $btnClose = $script:HowToWindow.FindName('BtnCloseHowTo')
    if ($btnClose) { $btnClose.Add_Click({ if ($script:HowToWindow) { $script:HowToWindow.Close() } }) }

    # Esc also closes it.
    $script:HowToWindow.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq 'Escape') { $script:HowToWindow.Close() }
    })
    $script:HowToWindow.Add_Closed({ $script:HowToWindow = $null })

    $script:HowToWindow.Show()
    $script:HowToWindow.Activate()
}

function Initialize-FullScreenWindow {
    if ($script:FullScreenWindow) { return }

    [xml]$fsXaml = Get-Content -LiteralPath (Join-Path $root 'UI\FullScreenWindow.xaml') -Raw -Encoding UTF8
    $fsReader = New-Object System.Xml.XmlNodeReader $fsXaml
    $script:FullScreenWindow = [System.Windows.Markup.XamlReader]::Load($fsReader)
    $script:FullScreenWindow.Owner = $window
    $script:ImgFullScreen = $script:FullScreenWindow.FindName('ImgFullScreen')
    $script:FsMediaHost   = $script:FullScreenWindow.FindName('FsMediaHost')
    $script:MedPreviewFS = $script:FullScreenWindow.FindName('MedPreviewFS')
    $script:PnlVideoUnavailableFS = $script:FullScreenWindow.FindName('PnlVideoUnavailableFS')

    # Loops on its own - mirrors VidPreview's MediaEnded in the main window.
    $script:MedPreviewFS.Add_MediaEnded({
        $script:MedPreviewFS.Position = [TimeSpan]::Zero
        $script:MedPreviewFS.Play()
    })
    # This is a separate playback attempt from both the main-window preview
    # and the desktop wallpaper copy - a failure here doesn't mean either
    # of those is broken too.
    $script:MedPreviewFS.Add_MediaFailed({
        $script:MedPreviewFS.Visibility = 'Collapsed'
        $script:PnlVideoUnavailableFS.Visibility = 'Visible'
    })

    # Click anywhere, or Esc, to exit full screen.
    $script:FullScreenWindow.Add_MouseLeftButtonDown({ Hide-FullScreenPreview })

    # A Maximized window's ActualWidth/ActualHeight are 0 until it's
    # actually shown, so the very first fit calculation has to happen here
    # (fires once real dimensions are known) rather than only inside
    # Show-FullScreenPreview itself. Also re-fires if it's ever shown on a
    # different monitor size than last time.
    $script:FullScreenWindow.Add_SizeChanged({ Apply-FullScreenAspectRatio })

    # Keep the app controllable while full screen has focus. S/P are never
    # global hotkeys, so without this they'd be dead in full screen. The
    # arrows are a fallback: when the global arrow hotkeys are ON the OS
    # intercepts them before WPF, so this branch only fires when they're OFF
    # (no double navigation).
    $script:FullScreenWindow.Add_KeyDown({
        param($sender, $e)
        switch ($e.Key) {
            'Escape' { Hide-FullScreenPreview; $e.Handled = $true }
            'S'      { if ($script:IsPlaying)     { Stop-Play }     else { Start-Play };     $e.Handled = $true }
            'P'      { if ($script:IsQuickPlaying) { Stop-QuickPlay } else { Start-QuickPlay }; $e.Handled = $true }
            'Right'  { Invoke-ManualNav { Go-NextImage };  $e.Handled = $true }
            'Left'   { Invoke-ManualNav { Go-PrevImage };  $e.Handled = $true }
            'Up'     { Invoke-ManualNav { Go-NextFolder }; $e.Handled = $true }
            'Down'   { Invoke-ManualNav { Go-PrevFolder }; $e.Handled = $true }
            'A'      { Cycle-VideoAspectRatio; $e.Handled = $true }
        }
    })
}

function Show-FullScreenPreview {
    Initialize-FullScreenWindow

    # Set directly here rather than relying only on the Sync-* helpers -
    # those only take effect when the window IsVisible, which is still
    # false at this point (we haven't called Show() yet), so relying on
    # them alone left the window blank/black on first open.
    if ($ImgPreview.Source) { $script:ImgFullScreen.Source = $ImgPreview.Source }
    $script:ImgFullScreen.Stretch = $ImgPreview.Stretch
    Sync-FullScreenVideo
    Apply-FullScreenAspectRatio

    $script:FullScreenWindow.Show()
    $script:FullScreenWindow.Activate()
}

function Hide-FullScreenPreview {
    if (-not $script:FullScreenWindow) { return }
    $script:FullScreenWindow.Hide()
    # No point decoding/playing while the window isn't shown - Sync-
    # FullScreenVideo restarts it fresh next time Show-FullScreenPreview runs.
    if ($script:MedPreviewFS) { $script:MedPreviewFS.Stop() }
}

# Keeps the full-screen window's image matched to the main preview - called
# any time the preview updates, so Slideshow/Quick Play/manual navigation
# stay in sync while full screen is already open.
function Sync-FullScreenImage {
    if ($script:FullScreenWindow -and $script:FullScreenWindow.IsVisible -and $ImgPreview.Source) {
        $script:ImgFullScreen.Source = $ImgPreview.Source
    }
    Sync-FullScreenVideo
}

# Mirrors the main window's in-app video preview (VidPreview) into the
# full-screen window whenever it exists, regardless of whether it's
# currently visible - so it's already showing the right thing by the time
# Show-FullScreenPreview calls Show(). Previously this only toggled a
# small "preview muted" note and hid the static image, without ever
# actually playing anything in the newly-vacated space - full screen on a
# video just showed the plain black window background.
function Sync-FullScreenVideo {
    if (-not $script:MedPreviewFS) { return }
    $isVideo = [bool]$script:CurrentIsVideo

    $script:PnlVideoUnavailableFS.Visibility = 'Collapsed'
    if ($script:ImgFullScreen) {
        $script:ImgFullScreen.Visibility = if ($isVideo) { 'Collapsed' } else { 'Visible' }
    }

    if (-not $isVideo) {
        $script:MedPreviewFS.Visibility = 'Collapsed'
        $script:MedPreviewFS.Stop()
        $script:MedPreviewFS.Source = $null
        return
    }

    # A third, independent, always-muted playback of the same file (the
    # main window has its own copy in VidPreview, and the desktop
    # wallpaper has another via Show-VideoWallpaper). This used to reuse
    # VidPreview's already-resolved Source rather than re-deriving the file
    # path - but VidPreview's in-app preview is now click-gated (see
    # Update-PreviewDisplay) and so is frequently empty/unset. Full screen
    # keeps its own always-eager playback regardless of that click state,
    # so it has to resolve the path itself from the current file instead of
    # depending on the small pane.
    if ($script:Folders.Count -eq 0 -or $script:CurImages.Count -eq 0) {
        $script:MedPreviewFS.Visibility = 'Collapsed'
        $script:PnlVideoUnavailableFS.Visibility = 'Visible'
        return
    }
    $imgFile = $script:CurImages[$script:Config.ImageIndex]
    try {
        $script:MedPreviewFS.Stop()
        $script:MedPreviewFS.Source = New-Object System.Uri($imgFile.FullName)
        $script:MedPreviewFS.Visibility = 'Visible'
        $script:MedPreviewFS.Play()
    }
    catch {
        # A failure here is specific to this full-screen copy - the main
        # window preview and the desktop wallpaper are unaffected.
        $script:MedPreviewFS.Visibility = 'Collapsed'
        $script:PnlVideoUnavailableFS.Visibility = 'Visible'
    }
}

$ImgPreview   = Get-El 'ImgPreview'
$PnlVideoBadge = Get-El 'PnlVideoBadge'
$TxtVideoBadgeTitle = Get-El 'TxtVideoBadgeTitle'
$TxtVideoBadgeSub = Get-El 'TxtVideoBadgeSub'
$VidPreview   = Get-El 'VidPreview'
$PreviewControlsPanel = Get-El 'PreviewControlsPanel'
$BtnPlayPause = Get-El 'BtnPlayPause'
$BtnStopPreview = Get-El 'BtnStopPreview'
$MarkerBar    = Get-El 'MarkerBar'
$MarkerTrack  = Get-El 'MarkerTrack'
$MarkerRangeFill = Get-El 'MarkerRangeFill'
$ThumbMarkStart  = Get-El 'ThumbMarkStart'
$ThumbMarkEnd    = Get-El 'ThumbMarkEnd'
$TxtMarkRange    = Get-El 'TxtMarkRange'
$BtnClearMarker  = Get-El 'BtnClearMarker'
$BtnPreviewMarker = Get-El 'BtnPreviewMarker'
$PnlMarkerStartRow = Get-El 'PnlMarkerStartRow'
$TxtMarkStartInput = Get-El 'TxtMarkStartInput'
$PnlMarkerEndRow = Get-El 'PnlMarkerEndRow'
$TxtMarkEndInput = Get-El 'TxtMarkEndInput'
$PnlMarkerEditRow = Get-El 'PnlMarkerEditRow'
$TxtMarkerSelectedLabel = Get-El 'TxtMarkerSelectedLabel'
$BtnSetSelectedHere = Get-El 'BtnSetSelectedHere'
$BtnSelMinus1  = Get-El 'BtnSelMinus1'
$BtnSelMinus01 = Get-El 'BtnSelMinus01'
$BtnSelPlus01  = Get-El 'BtnSelPlus01'
$BtnSelPlus1   = Get-El 'BtnSelPlus1'
$PreviewHost  = Get-El 'PreviewHost'
$PreviewArea  = Get-El 'PreviewArea'
$RootGrid     = Get-El 'RootGrid'
$HeaderGrid   = Get-El 'HeaderGrid'
$PreviewRowDef = Get-El 'PreviewRowDef'

# The GridLength Row 0 (PreviewRowDef) is reset to whenever a video's exact
# box height isn't known/applicable (images, or a video before its native
# size resolves) - restores the original "fill all leftover space" sizing.
$script:PreviewRowStarLength = $PreviewRowDef.Height

# Sizes PreviewRowDef to hug exactly header-height + $BoxHeight, so
# PreviewArea's own "*" row ends up exactly $BoxHeight tall - i.e. no
# leftover space around the centered PreviewHost inside it. Falls back to
# the original star sizing if the header's height isn't known yet (e.g.
# called before first layout pass).
function Set-PreviewRowHeightForBox {
    param([double]$BoxHeight)

    if (-not $PreviewRowDef -or -not $HeaderGrid -or $HeaderGrid.RowDefinitions.Count -eq 0) { return }

    $headerH = $HeaderGrid.RowDefinitions[0].ActualHeight
    if ($headerH -le 0) { return }

    $PreviewRowDef.Height = New-Object System.Windows.GridLength(($headerH + $BoxHeight), [System.Windows.GridUnitType]::Pixel)
}

# Puts PreviewRowDef back to its original star sizing - used for images
# (which should keep filling all available space, unaffected by this fix)
# and for videos before their native/forced size is known.
function Reset-PreviewRowHeight {
    if (-not $PreviewRowDef) { return }
    $PreviewRowDef.Height = $script:PreviewRowStarLength
}
$PvBarTop     = Get-El 'PvBarTop'
$PvBarBottom  = Get-El 'PvBarBottom'
$PvBarLeft    = Get-El 'PvBarLeft'
$PvBarRight   = Get-El 'PvBarRight'
$ChkVideoAudio = Get-El 'ChkVideoAudio'
$TxtFolder    = Get-El 'TxtFolderName'
$TxtImageInfo = Get-El 'TxtImageInfo'
$BtnUp        = Get-El 'BtnUp'
$BtnDown      = Get-El 'BtnDown'
$BtnLeft      = Get-El 'BtnLeft'
$BtnRight     = Get-El 'BtnRight'
$TxtRootPath  = Get-El 'TxtRootPath'
$BtnBrowse    = Get-El 'BtnBrowse'
$CmbStyle     = Get-El 'CmbStyle'
$CmbVideoAspect = Get-El 'CmbVideoAspect'
$ChkHotkeys   = Get-El 'ChkHotkeys'
$BtnRefresh   = Get-El 'BtnRefresh'
$BtnPlay      = Get-El 'BtnPlay'
$CmbInterval  = Get-El 'CmbInterval'
$ChkShuffle   = Get-El 'ChkShuffle'
$BtnLoopFolder = Get-El 'BtnLoopFolder'
$BtnQuickPlay = Get-El 'BtnQuickPlay'
$RbSpeedLow   = Get-El 'RbSpeedLow'
$RbSpeedMedium = Get-El 'RbSpeedMedium'
$RbSpeedHigh  = Get-El 'RbSpeedHigh'
$CmbPreviewStretch = Get-El 'CmbPreviewStretch'
$BtnFullScreen     = Get-El 'BtnFullScreen'
$BtnHowTo     = Get-El 'BtnHowTo'
$TxtStatus    = Get-El 'TxtStatus'

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:Config      = Get-PlayerConfig
$script:Folders     = @()
$script:CurImages   = @()
$script:IsPlaying   = $false
$script:IsQuickPlaying = $false
$script:CurrentIsVideo = $false

# Which "mode" the overlay CmbPreviewStretch combo is currently showing:
# 'Image' = Fit/Fill/Stretch/Center (scales the in-app preview picture),
# 'Video' = Default/4:3/16:9/etc (forces the video's aspect ratio, kept in
# sync with the CmbVideoAspect combo further down). See Set-PreviewComboMode.
$script:PreviewComboMode = 'Image'
# Guards against CmbPreviewStretch <-> CmbVideoAspect syncing each other
# back and forth when one of them is changed (each change to one pushes
# the same value onto the other - see Sync-ComboSelectionByTag).
$script:SyncingAspectCombos = $false
# Aspect ratio last applied to the in-app video preview's letterbox bars -
# re-applied on PreviewHost resize (window resize/maximize) so the bars
# stay correctly proportioned. 0 = Default/no forced shape.
$script:LastPreviewAspectRatio = 0

# Millisecond ticks for the three Quick Play paces.
$script:QuickPlaySpeeds = @{
    Low    = 1600
    Medium = 900
    High   = 350
}

# Debounces the actual (slow) desktop-wallpaper-set call so that rapid
# navigation (holding/spamming arrow keys or buttons) only ever applies the
# FINAL image once you stop, instead of applying every intermediate image
# one after another as a backlog.
$script:WallpaperApplyTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WallpaperApplyTimer.Interval = [TimeSpan]::FromMilliseconds(180)

# Drives the timed "Slideshow" feature (Change picture every N
# seconds/minutes/hours, per the interval combo box).
$script:PlayTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PlayTimer.Interval = [TimeSpan]::FromMilliseconds(900)

# Drives the "Quick Play" stop-motion feature - flips through images at a
# fixed Low/Medium/High pace, independent of the Slideshow interval combo.
$script:QuickPlayTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:QuickPlayTimer.Interval = [TimeSpan]::FromMilliseconds($script:QuickPlaySpeeds.Medium)

# Drives the in-app preview's own trim-marker enforcement (loop back to
# the marked start once playback reaches the marked end - MediaElement has
# no "reached position X" event of its own) and its playhead indicator.
# See Show-MarkerBar/Hide-MarkerBar and the Tick handler further down.
$script:PreviewMarkerTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PreviewMarkerTimer.Interval = [TimeSpan]::FromMilliseconds(200)

$script:WallpaperApplyTimer.Add_Tick({
    $script:WallpaperApplyTimer.Stop()
    Apply-CurrentWallpaper
})

function Set-Status {
    param([string]$Message, [switch]$IsError)
    $TxtStatus.Text = $Message
    $TxtStatus.Foreground = if ($IsError) { [System.Windows.Media.Brushes]::IndianRed } else { [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0x8C,0x8C,0x94)) }
}

function Sync-StyleComboToConfig {
    foreach ($item in $CmbStyle.Items) {
        if ($item.Content -eq $script:Config.WallpaperStyle) {
            $CmbStyle.SelectedItem = $item
            return
        }
    }
    $CmbStyle.SelectedIndex = 0
}

function Sync-VideoAspectComboToConfig {
    foreach ($item in $CmbVideoAspect.Items) {
        if ($item.Content -eq $script:Config.VideoAspectRatio) {
            $CmbVideoAspect.SelectedItem = $item
            return
        }
    }
    $CmbVideoAspect.SelectedIndex = 0
}

# Reads the current CmbVideoAspect selection and returns the numeric
# width/height ratio to force ("Default" -> 0, meaning "no forced shape").
function Get-SelectedVideoAspectRatio {
    if (-not $CmbVideoAspect.SelectedItem) { return 0 }
    return [double]$CmbVideoAspect.SelectedItem.Tag
}

# CmbPreviewStretch's item set changes depending on whether the current
# item is an image or a video (see Set-PreviewComboMode). Each mode's
# options are defined once here as plain Content/Tag pairs so both the
# combo's "image mode" list and its "video mode" list (cloned from
# CmbVideoAspect - a ComboBoxItem instance can only belong to one combo at
# a time in WPF, so it must be cloned, not shared) can be (re)built from
# the same source of truth.
# NOTE: there used to be a separate hardcoded $script:PreviewStretchDefsImage
# list here, independent of CmbStyle - meaning the overlay preview combo and
# the real "Wallpaper Style" combo could show different option sets and drift
# out of sync with each other for images. Removed: Set-PreviewComboMode's
# Image branch below now clones directly from $CmbStyle.Items instead,
# exactly mirroring how its Video branch already clones from $CmbVideoAspect.

# Replaces $Combo's items with fresh ComboBoxItems built from $Defs
# (an array of @{Content=...; Tag=...}), trying to preserve whichever
# Content was previously selected (falls back to the first item).
function Set-ComboItems {
    param($Combo, [array]$Defs)
    $previousContent = if ($Combo.SelectedItem) { $Combo.SelectedItem.Content } else { $null }
    $Combo.Items.Clear()
    $toSelect = $null
    foreach ($d in $Defs) {
        $cbi = New-Object System.Windows.Controls.ComboBoxItem
        $cbi.Content = $d.Content
        $cbi.Tag = $d.Tag
        $Combo.Items.Add($cbi) | Out-Null
        if ($d.Content -eq $previousContent) { $toSelect = $cbi }
    }
    $Combo.SelectedItem = if ($toSelect) { $toSelect } else { $Combo.Items[0] }
}

# Copies $Source's selected Tag onto whichever item in $Target has a
# matching Tag - used to keep CmbPreviewStretch and CmbVideoAspect
# representing the same underlying aspect-ratio setting while in Video mode.
function Sync-ComboSelectionByTag {
    param($Source, $Target)
    if (-not $Source.SelectedItem) { return }
    $tag = $Source.SelectedItem.Tag
    foreach ($item in $Target.Items) {
        if ($item.Tag -eq $tag) { $Target.SelectedItem = $item; return }
    }
}

# Switches the overlay combo between "Fit/Fill/Stretch/Center" (images) and
# "Default/4:3/16:9/..." (videos, mirroring CmbVideoAspect) - called
# whenever Update-PreviewDisplay switches the current item's type. A no-op
# if already in the requested mode, so it's safe to call on every
# navigation step.
function Set-PreviewComboMode {
    param([Parameter(Mandatory)][ValidateSet('Image', 'Video')][string]$Mode)
    if ($script:PreviewComboMode -eq $Mode) { return }
    $script:PreviewComboMode = $Mode

    # Rebuilding a combo's Items causes a transient auto-selection (e.g.
    # the first item) before we get a chance to restore the real value
    # below - guarding the whole sequence stops that transient selection
    # from being read by CmbPreviewStretch's handler and pushed onto
    # CmbVideoAspect as if it were a real user change.
    $script:SyncingAspectCombos = $true
    try {
        if ($Mode -eq 'Video') {
            $CmbPreviewStretch.ToolTip = "Video aspect ratio (preview) - same setting as the Aspect Ratio combo below"
            $videoDefs = foreach ($item in $CmbVideoAspect.Items) { @{ Content = $item.Content; Tag = $item.Tag } }
            Set-ComboItems -Combo $CmbPreviewStretch -Defs $videoDefs
            # Land on whatever CmbVideoAspect is currently set to, not
            # the first item, so opening on a video doesn't silently
            # reset the aspect ratio you already had selected.
            Sync-ComboSelectionByTag -Source $CmbVideoAspect -Target $CmbPreviewStretch
        } else {
            $CmbPreviewStretch.ToolTip = "Wallpaper style (preview) - same setting as the Wallpaper Style combo above"
            $imageDefs = foreach ($item in $CmbStyle.Items) { @{ Content = $item.Content; Tag = $item.Tag } }
            Set-ComboItems -Combo $CmbPreviewStretch -Defs $imageDefs
            # Land on whatever CmbStyle is currently set to, not the first
            # item, so opening on an image doesn't silently reset the style
            # you already had selected.
            Sync-ComboSelectionByTag -Source $CmbStyle -Target $CmbPreviewStretch
        }
    }
    finally {
        $script:SyncingAspectCombos = $false
    }
}

# Resizes PreviewHost itself (not just the content inside it) to hug the
# actual shape of the current video, centered within PreviewArea - so
# there's no leftover space inside the panel to letterbox/pillarbox OR
# crop away. Replaces the old approach of stretching VidPreview to fill a
# fixed-size host and covering the gaps with black bar Rectangles (which,
# on "Default", cropped into the frame instead of showing all of it).
#
# AspectRatio -le 0 ("Default") means "no forced shape" - in that case we
# use the video's own native width/height, read from VidPreview once the
# file has actually opened (NaturalVideoWidth/Height are 0 before then).
# Until that's known, the host just fills the available area normally;
# VidPreview.Add_MediaOpened below re-calls this once the real shape is
# known, correcting it (a brief, unavoidable flash on first open only).
#
# Re-run automatically on PreviewArea resize (window resize/maximize) and
# on MediaOpened, using $script:LastPreviewAspectRatio.
function Apply-PreviewVideoAspectRatio {
    param([double]$AspectRatio = 0)
    $script:LastPreviewAspectRatio = $AspectRatio

    # Bars are no longer used (panel resizing replaces them) - keep them
    # pinned at 0 in case anything still references them.
    $PvBarTop.Height = 0; $PvBarBottom.Height = 0
    $PvBarLeft.Width = 0; $PvBarRight.Width = 0

    if (-not $script:CurrentIsVideo) {
        Reset-PreviewHostSize
        return
    }

    $effectiveRatio = $AspectRatio
    if ($effectiveRatio -le 0 -and $VidPreview.NaturalVideoWidth -gt 0 -and $VidPreview.NaturalVideoHeight -gt 0) {
        $effectiveRatio = $VidPreview.NaturalVideoWidth / $VidPreview.NaturalVideoHeight
    }

    if ($effectiveRatio -le 0) {
        # Native shape not known yet (video hasn't finished opening) -
        # fill the available area for now; corrected shortly via
        # MediaOpened once the real dimensions are available.
        Reset-PreviewHostSize
        $VidPreview.Stretch = [System.Windows.Media.Stretch]::Uniform
        return
    }

    $areaW = $PreviewArea.ActualWidth
    $areaH = $PreviewArea.ActualHeight
    if ($areaW -le 0 -or $areaH -le 0) { return }

    $targetW = $areaW
    $targetH = $targetW / $effectiveRatio
    if ($targetH -gt $areaH) {
        $targetH = $areaH
        $targetW = $targetH * $effectiveRatio
    }

    $PreviewHost.HorizontalAlignment = 'Center'
    $PreviewHost.VerticalAlignment = 'Center'
    $PreviewHost.Width  = $targetW
    $PreviewHost.Height = $targetH
    $VidPreview.Width   = [double]::NaN
    $VidPreview.Height  = [double]::NaN
    $VidPreview.Stretch = [System.Windows.Media.Stretch]::Uniform

    # Shrink the outer row to hug this exact box height (see PreviewRowDef
    # in MainWindow.xaml) - otherwise PreviewArea keeps claiming whatever
    # leftover vertical space the window has, centering this box inside a
    # taller area than it needs and leaving blank space above/below it.
    Set-PreviewRowHeightForBox -BoxHeight $targetH
}

# Puts PreviewHost back to filling the full PreviewArea (its normal
# behavior for images, and for videos before their native size is known).
function Reset-PreviewHostSize {
    $PreviewHost.HorizontalAlignment = 'Stretch'
    $PreviewHost.VerticalAlignment = 'Stretch'
    $PreviewHost.Width  = [double]::NaN
    $PreviewHost.Height = [double]::NaN

    # Images (and videos before their size is known) should keep filling
    # all available space, same as before this fix - only a video with a
    # known box height gets the hugged/exact row sizing above.
    Reset-PreviewRowHeight
}

# Mirrors Apply-PreviewVideoAspectRatio above, but sizes FsMediaHost against
# the full-screen window instead of the main window's PreviewArea. Without
# this, full screen just filled the whole monitor at the video's NATIVE
# shape via Stretch=Uniform - never distorted, but a different crop than
# whatever forced aspect ratio (e.g. 21:9) the main preview and the actual
# desktop wallpaper were using, which is what read as "everything looks
# stretched" going full screen.
#
# On top of sizing FsMediaHost, this also has to set MedPreviewFS's Stretch
# mode to match how the REAL desktop video wallpaper renders (see
# Set-VideoWallpaperAspectRatio in modules/VideoWallpaper.ps1):
#   - Default (no forced ratio): the real wallpaper covers the whole
#     screen with Stretch=UniformToFill (crops the video, no bars).
#     MedPreviewFS/ImgFullScreen were hardcoded to Stretch="Uniform" in
#     XAML, which instead shows the whole frame letterboxed - so on
#     Default the full-screen preview never matched the actual wallpaper.
#   - Forced ratio (e.g. 21:9): the real wallpaper stretches the source to
#     exactly fill the forced-ratio rectangle with Stretch=Fill. FsMedia-
#     Host is already sized to that exact rectangle below, so Fill here
#     produces the same crop the real wallpaper shows.
function Apply-FullScreenAspectRatio {
    if (-not $script:FullScreenWindow -or -not $script:FsMediaHost) { return }

    if (-not $script:CurrentIsVideo) {
        Reset-FullScreenHostSize
        return
    }

    $effectiveRatio = $script:LastPreviewAspectRatio
    if ($effectiveRatio -le 0 -and $VidPreview.NaturalVideoWidth -gt 0 -and $VidPreview.NaturalVideoHeight -gt 0) {
        $effectiveRatio = $VidPreview.NaturalVideoWidth / $VidPreview.NaturalVideoHeight
    }
    if ($effectiveRatio -le 0) {
        Reset-FullScreenHostSize
        return
    }

    $areaW = $script:FullScreenWindow.ActualWidth
    $areaH = $script:FullScreenWindow.ActualHeight
    if ($areaW -le 0 -or $areaH -le 0) { return }

    $targetW = $areaW
    $targetH = $targetW / $effectiveRatio
    if ($targetH -gt $areaH) {
        $targetH = $areaH
        $targetW = $targetH * $effectiveRatio
    }

    $script:FsMediaHost.HorizontalAlignment = 'Center'
    $script:FsMediaHost.VerticalAlignment = 'Center'
    $script:FsMediaHost.Width  = $targetW
    $script:FsMediaHost.Height = $targetH

    # Forced ratio active - FsMediaHost is now sized to exactly that
    # rectangle, so Fill (not Uniform) stretches the source to match the
    # real wallpaper's forced-DAR behavior exactly, same as
    # Set-VideoWallpaperAspectRatio does for the actual desktop wallpaper.
    if ($script:MedPreviewFS) { $script:MedPreviewFS.Stretch = [System.Windows.Media.Stretch]::Fill }
}

# Puts FsMediaHost back to filling the entire full-screen window (images,
# and videos before their native/forced ratio is known) - mirrors Reset-
# PreviewHostSize above.
#
# For videos on "Default" (no forced ratio), MedPreviewFS's Stretch is set
# to UniformToFill here so the full-screen preview crops to cover the
# screen exactly like the real desktop video wallpaper does on Default
# (see Set-VideoWallpaperAspectRatio) - matching the fix in
# Apply-FullScreenAspectRatio above for the forced-ratio case.
function Reset-FullScreenHostSize {
    if (-not $script:FsMediaHost) { return }
    $script:FsMediaHost.HorizontalAlignment = 'Stretch'
    $script:FsMediaHost.VerticalAlignment = 'Stretch'
    $script:FsMediaHost.Width  = [double]::NaN
    $script:FsMediaHost.Height = [double]::NaN

    if ($script:MedPreviewFS -and $script:CurrentIsVideo) {
        $script:MedPreviewFS.Stretch = [System.Windows.Media.Stretch]::UniformToFill
    }
}

# Advances CmbVideoAspect to the next option (Default -> 4:3 -> 16:9 ->
# 16:10 -> 21:9 -> Default...), same as VLC's "A" shortcut. All the logic
# already wired to CmbVideoAspect's SelectionChanged (live desktop
# wallpaper update, in-app preview resize, overlay combo sync) kicks in
# automatically - this just moves the selection.
function Cycle-VideoAspectRatio {
    if ($CmbVideoAspect.Items.Count -eq 0) { return }
    $CmbVideoAspect.SelectedIndex = ($CmbVideoAspect.SelectedIndex + 1) % $CmbVideoAspect.Items.Count
}

function Sync-IntervalComboToConfig {
    foreach ($item in $CmbInterval.Items) {
        if ([int]$item.Tag -eq [int]$script:Config.SlideshowIntervalSeconds) {
            $CmbInterval.SelectedItem = $item
            return
        }
    }
    # Unrecognized/custom value in config - default to 30 seconds.
    $CmbInterval.SelectedIndex = 2
}

function Sync-QuickPlaySpeedToConfig {
    switch ($script:Config.QuickPlaySpeed) {
        'Low'  { $RbSpeedLow.IsChecked = $true }
        'High' { $RbSpeedHigh.IsChecked = $true }
        default { $RbSpeedMedium.IsChecked = $true }
    }
}

# Reads the checked radio button and returns 'Low' / 'Medium' / 'High'.
function Get-SelectedQuickPlaySpeedName {
    if ($RbSpeedLow.IsChecked) { return 'Low' }
    if ($RbSpeedHigh.IsChecked) { return 'High' }
    return 'Medium'
}

# Sync-PreviewStretchToConfig removed - CmbStyle's own WallpaperStyle
# persistence (see Apply-CurrentWallpaper) now covers this; a separate
# PreviewStretch config key was redundant now that the preview combo is
# always just a synced mirror of CmbStyle's selection.# Applies CmbStyle's selected style (as a WPF Stretch value, via its Tag)
# to both the in-panel preview and the full-screen window. Reads from
# CmbStyle - not CmbPreviewStretch - so the overlay combo is purely a
# synced mirror here, exactly like Get-SelectedVideoAspectRatio reads from
# CmbVideoAspect rather than the overlay combo in video mode.
function Apply-PreviewStretch {
    if (-not $CmbStyle.SelectedItem) { return }
    $stretch = [System.Windows.Media.Stretch]$CmbStyle.SelectedItem.Tag
    $ImgPreview.Stretch = $stretch
    if ($script:ImgFullScreen) { $script:ImgFullScreen.Stretch = $stretch }
}

# ---------------------------------------------------------------------------
# Library loading
# ---------------------------------------------------------------------------
function Reload-Library {
    if (-not $script:Config.RootPath -or -not (Test-Path -LiteralPath $script:Config.RootPath)) {
        Set-Status "No valid library folder set. Click Browse to choose your snapshots folder." -IsError
        $script:Folders = @()
        return
    }

    $script:Folders = @(Get-SnapshotFolders -RootPath $script:Config.RootPath)

    if ($script:Folders.Count -eq 0) {
        Set-Status "No subfolders with images or videos found under: $($script:Config.RootPath)" -IsError
        return
    }

    if ($script:Config.FolderIndex -ge $script:Folders.Count) { $script:Config.FolderIndex = 0 }
    if ($script:Config.FolderIndex -lt 0) { $script:Config.FolderIndex = 0 }

    Load-CurrentFolderImages
    Set-Status "Loaded $($script:Folders.Count) folders from $($script:Config.RootPath)"
}

function Load-CurrentFolderImages {
    if ($script:Folders.Count -eq 0) { return }
    $folder = $script:Folders[$script:Config.FolderIndex]
    $script:CurImages = @(Get-ImagesInFolder -FolderPath $folder.FullName)

    if ($script:CurImages.Count -eq 0) {
        Set-Status "Folder '$($folder.Name)' has no supported images or videos." -IsError
        return
    }

    if ($script:Config.ImageIndex -ge $script:CurImages.Count) { $script:Config.ImageIndex = 0 }
    if ($script:Config.ImageIndex -lt 0) { $script:Config.ImageIndex = $script:CurImages.Count - 1 }
}

# ---------------------------------------------------------------------------
# Applying the current image as wallpaper + updating UI
# ---------------------------------------------------------------------------

# FAST: just updates the on-screen preview/text. Safe to call on every
# single navigation step, however rapid.
function Update-PreviewDisplay {
    if ($script:Folders.Count -eq 0 -or $script:CurImages.Count -eq 0) { return }

    $folder = $script:Folders[$script:Config.FolderIndex]
    $imgFile = $script:CurImages[$script:Config.ImageIndex]
    $script:CurrentIsVideo = [bool]$imgFile.IsVideo

    $TxtFolder.Text = $folder.Name
    $TxtImageInfo.Text = "{0}   ({1} / {2})" -f $imgFile.Name, ($script:Config.ImageIndex + 1), $script:CurImages.Count

    if ($script:CurrentIsVideo) {
        $ImgPreview.Source = $null
        $ImgPreview.Visibility = 'Collapsed'
        Set-PreviewComboMode -Mode 'Video'

        # The in-app preview no longer auto-plays on navigation - decoding/
        # playing every video you step past was needlessly expensive. Leave
        # VidPreview empty/stopped and show a filler badge (icon + filename
        # + click-to-play affordance) instead; actual playback only starts
        # from PnlVideoBadge's click handler below. This runs on every
        # navigation step (next/prev/folder, slideshow tick), so the filler
        # always comes back first regardless of whether the previous item
        # was clicked - there's no "stay playing" carve-out for Slideshow/
        # Quick Play. The desktop wallpaper copy (Show-VideoWallpaper) never
        # reads VidPreview, so it keeps auto-playing exactly as before.
        $VidPreview.Stop()
        $VidPreview.Source = $null
        $VidPreview.Visibility = 'Collapsed'
        $PreviewControlsPanel.Visibility = 'Collapsed'
        Show-MarkerBarInactive
        Apply-PreviewVideoAspectRatio -AspectRatio (Get-SelectedVideoAspectRatio)
        $TxtVideoBadgeTitle.Text = $imgFile.Name
        $TxtVideoBadgeSub.Text = "Click to play in-app preview - already playing as your desktop wallpaper"
        $PnlVideoBadge.Visibility = 'Visible'

        Sync-FullScreenImage
        return
    }

    $PnlVideoBadge.Visibility = 'Collapsed'
    $VidPreview.Visibility = 'Collapsed'
    $PreviewControlsPanel.Visibility = 'Collapsed'
    Hide-MarkerBar
    $VidPreview.Stop()
    $VidPreview.Source = $null
    Reset-PreviewHostSize
    Set-PreviewComboMode -Mode 'Image'
    $ImgPreview.Visibility = 'Visible'
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
        $bmp.UriSource = New-Object System.Uri($imgFile.FullName)
        $bmp.EndInit()
        $bmp.Freeze()
        $ImgPreview.Source = $bmp
        Sync-FullScreenImage
    }
    catch {
        Set-Status "Could not load preview: $($_.Exception.Message)" -IsError
    }
}

# SLOW: converts (if needed) and actually sets the Windows desktop
# wallpaper - or, for a video file, starts it playing embedded behind the
# desktop icons. This is the expensive part, so it's only ever called via
# the debounced Request-WallpaperApply below (except for one-off cases
# like style changes / initial load).
function Apply-CurrentWallpaper {
    if ($script:Folders.Count -eq 0 -or $script:CurImages.Count -eq 0) { return }

    $imgFile = $script:CurImages[$script:Config.ImageIndex]

    if ($imgFile.IsVideo) {
        $muted = -not [bool]$ChkVideoAudio.IsChecked
        # Videos are no longer controlled by the image "Wallpaper Style"
        # (Fit/Fill/Stretch/etc.) combo - they get their own forced
        # aspect-ratio combo instead (like VLC's Aspect Ratio menu).
        $aspectLabel = if ($CmbVideoAspect.SelectedItem) { $CmbVideoAspect.SelectedItem.Content } else { 'Default' }
        $aspectRatio = Get-SelectedVideoAspectRatio
        # A saved trim marker (see VideoMarkers.ps1) makes this video play
        # only its marked section - Show-VideoWallpaper starts there and
        # treats reaching the end point exactly like true EOF (loop the
        # section when Slideshow is off, hand off to "next" when it's on -
        # same OnEnded below either way). No marker for this file -> play
        # in full, same as before this feature existed.
        $marker = Get-VideoMarker -Path $imgFile.FullName
        $markerStart = if ($marker) { $marker.Start } else { 0 }
        $markerEnd   = if ($marker) { $marker.End } else { 0 }
        # OnEnded fires every time the video reaches its end. If Slideshow
        # is running, jump to the next item - same "what's next" logic the
        # Slideshow timer uses (respects the Shuffle checkbox). If
        # Slideshow is OFF, this video is effectively the "permanent"
        # wallpaper (the same way a static image just stays put when
        # Slideshow is off) - so just loop it instead of advancing.
        $ok = Show-VideoWallpaper -Path $imgFile.FullName -Muted $muted -AspectRatio $aspectRatio -MarkerStart $markerStart -MarkerEnd $markerEnd -OnEnded {
            Invoke-OnUiThread {
                if (-not $script:IsPlaying) {
                    Restart-VideoWallpaper
                    return
                }
                # -Immediate: skip the ~180ms debounce so the next item
                # appears right away - paired with VideoWallpaper.ps1's
                # MediaEnded handler now Stop()ping instead of replaying
                # from frame 0, this closes the gap where a sliver of the
                # just-finished video used to play again before the next
                # image/video showed up.
                if ($ChkShuffle.IsChecked) { Go-RandomImage -Immediate } else { Go-NextImage -Immediate }
                # The Slideshow timer keeps ticking on its original
                # schedule the whole time the video was playing (its tick
                # handler just no-ops while a video is current - see
                # $script:PlayTimer.Add_Tick above). Restart it here so the
                # item we just landed on gets a full, fresh interval of its
                # own instead of possibly being cut short by a tick that
                # was already due to fire moments after the video ended.
                $script:PlayTimer.Stop()
                $script:PlayTimer.Start()
            }
        }
        if ($ok) {
            $whenDone = if ($script:IsPlaying) { "it'll auto-advance when it finishes" } else { "it'll loop when it finishes" }
            Set-Status "Playing video wallpaper: $($imgFile.Name) - $whenDone."
        } else {
            Set-Status "Could not play video wallpaper for $($imgFile.Name)" -IsError
        }
        $script:Config.VideoAspectRatio = $aspectLabel
        Save-PlayerConfig -Config $script:Config | Out-Null
        return
    }

    # Current item is a still image - make sure any video wallpaper that
    # was previously showing is stopped so it doesn't keep covering the
    # static wallpaper we're about to set underneath it.
    if (Test-VideoWallpaperActive) {
        Hide-VideoWallpaper
        # Hide-VideoWallpaper Close()s the hidden window/players, but that
        # only makes them garbage - it doesn't force a GC pass, and even a
        # GC pass wouldn't make Task Manager's number move on its own (see
        # Invoke-MemoryTrim's notes). Do it here, once, right at the
        # video->image transition, rather than on every navigation step.
        Invoke-MemoryTrim
    }

    $wallpaperPath = Convert-ToWallpaperCompatible -Path $imgFile.FullName
    if (-not $wallpaperPath) {
        Set-Status "Could not set wallpaper - unsupported format and no ffmpeg available." -IsError
        return
    }

    $style = if ($CmbStyle.SelectedItem) { $CmbStyle.SelectedItem.Content } else { 'Fill' }
    $ok = Set-Wallpaper -Path $wallpaperPath -Style $style -SkipBackup
    if ($ok) {
        Set-Status "Wallpaper set: $($imgFile.Name)"
    } else {
        Set-Status "Failed to set wallpaper for $($imgFile.Name)" -IsError
    }

    $script:Config.WallpaperStyle = $style
    Save-PlayerConfig -Config $script:Config | Out-Null
}

# Coalesces rapid navigation: restarts a short timer on every call, so the
# actual wallpaper-set only fires once, ~300ms after the LAST navigation
# step - not once per step. This is what stops the wallpaper from still
# cycling through a backlog after you've already let go of the arrow key.
function Request-WallpaperApply {
    $script:WallpaperApplyTimer.Stop()
    $script:WallpaperApplyTimer.Start()
}

# Immediate, non-debounced update+apply - used for cases like initial load
# or a manual style change where there's no rapid-fire concern.
function Show-CurrentImage {
    Update-PreviewDisplay
    Apply-CurrentWallpaper
}

# ---------------------------------------------------------------------------
# Navigation
# ---------------------------------------------------------------------------
function Update-LoopFolderButtonVisual {
    <#
    .SYNOPSIS
        Styles BtnLoopFolder to reflect $script:Config.LoopFolderEnabled -
        PrimaryButton (accent/yellow, same color as TxtFolderName) when on,
        plain NavButton when off. Call after any change to the setting,
        including at startup once the saved config is loaded.
    #>
    $BtnLoopFolder.Style = if ($script:Config.LoopFolderEnabled) {
        $window.FindResource('PrimaryButton')
    } else {
        $window.FindResource('NavButton')
    }
}

function Go-NextImage {
    param(
        # Skips the ~180ms debounce and applies the wallpaper right away.
        # Used when advancing off the back of a video that just finished
        # playing (see the OnEnded callback in Apply-CurrentWallpaper) -
        # there's no rapid-fire keypress concern there, and waiting out
        # the debounce let the just-finished video's frozen last frame
        # sit on screen for a beat before the next item appeared.
        [switch]$Immediate
    )
    if ($script:CurImages.Count -eq 0) { return }

    if ($script:Config.ImageIndex -ge $script:CurImages.Count - 1) {
        if ($script:Config.LoopFolderEnabled) {
            # Loop Folder is on - wrap back to this SAME folder's first
            # image instead of rolling into the next folder.
            $script:Config.ImageIndex = 0
            Update-PreviewDisplay
            if ($Immediate) { Apply-CurrentWallpaper } else { Request-WallpaperApply }
            return
        }
        # Last image in this folder - roll into the next folder's first image.
        Go-NextFolder -Immediate:$Immediate
        return
    }

    $script:Config.ImageIndex++
    Update-PreviewDisplay
    if ($Immediate) { Apply-CurrentWallpaper } else { Request-WallpaperApply }
}

function Go-PrevImage {
    if ($script:CurImages.Count -eq 0) { return }

    if ($script:Config.ImageIndex -le 0) {
        if ($script:Config.LoopFolderEnabled) {
            # Loop Folder is on - wrap back to this SAME folder's last
            # image instead of rolling into the previous folder.
            $script:Config.ImageIndex = $script:CurImages.Count - 1
            Update-PreviewDisplay
            Request-WallpaperApply
            return
        }
        # First image in this folder - roll into the previous folder's last image.
        Go-PrevFolder -LandOnLast
        return
    }

    $script:Config.ImageIndex--
    Update-PreviewDisplay
    Request-WallpaperApply
}

function Go-NextFolder {
    param([switch]$Immediate)
    if ($script:Folders.Count -eq 0) { return }
    $script:Config.FolderIndex = ($script:Config.FolderIndex + 1) % $script:Folders.Count
    $script:Config.ImageIndex = 0
    Load-CurrentFolderImages
    Update-PreviewDisplay
    if ($Immediate) { Apply-CurrentWallpaper } else { Request-WallpaperApply }
}

function Go-PrevFolder {
    param([switch]$LandOnLast)

    if ($script:Folders.Count -eq 0) { return }
    $script:Config.FolderIndex = ($script:Config.FolderIndex - 1 + $script:Folders.Count) % $script:Folders.Count

    if ($LandOnLast) {
        Load-CurrentFolderImages
        $script:Config.ImageIndex = if ($script:CurImages.Count -gt 0) { $script:CurImages.Count - 1 } else { 0 }
    } else {
        $script:Config.ImageIndex = 0
        Load-CurrentFolderImages
    }

    Update-PreviewDisplay
    Request-WallpaperApply
}

function Go-RandomImage {
    <#
    .SYNOPSIS
        Jumps to a random image, possibly in a different folder - used when
        "Shuffle the picture order" is enabled during slideshow playback.
        When Loop Folder is also on, stays within the CURRENT folder -
        only the image index is randomized, same as Shuffle's usual
        "avoid repeating the same one twice in a row" behavior.
    #>
    param(
        # See Go-NextImage's -Immediate for why the video-ended path needs this.
        [switch]$Immediate
    )
    if ($script:Folders.Count -eq 0) { return }

    $prevFolderIndex = $script:Config.FolderIndex
    $prevImageIndex  = $script:Config.ImageIndex

    if ($script:Config.LoopFolderEnabled) {
        $newFolderIndex = $prevFolderIndex
    } else {
        $newFolderIndex = Get-Random -Minimum 0 -Maximum $script:Folders.Count
    }
    $script:Config.FolderIndex = $newFolderIndex
    Load-CurrentFolderImages

    if ($script:CurImages.Count -eq 0) { return }

    $newImageIndex = Get-Random -Minimum 0 -Maximum $script:CurImages.Count

    # Avoid landing on the exact same image twice in a row when there's
    # more than one image to choose from.
    if ($newFolderIndex -eq $prevFolderIndex -and $newImageIndex -eq $prevImageIndex -and $script:CurImages.Count -gt 1) {
        $newImageIndex = ($newImageIndex + 1) % $script:CurImages.Count
    }

    $script:Config.ImageIndex = $newImageIndex
    Update-PreviewDisplay
    if ($Immediate) { Apply-CurrentWallpaper } else { Request-WallpaperApply }
}

# All UI-affecting calls from the global hotkey hook must run on the UI
# thread's dispatcher; the hook already fires on the window's own message
# pump so a direct call is fine, but we wrap in Dispatcher.Invoke for safety.
function Invoke-OnUiThread {
    param([scriptblock]$Action)
    $window.Dispatcher.Invoke($Action)
}

# ---------------------------------------------------------------------------
# Slideshow autoplay
# ---------------------------------------------------------------------------
$script:PlayTimer.Add_Tick({
    # Videos advance themselves once they finish playing (see the OnEnded
    # handler in Apply-CurrentWallpaper), so while a video is the current
    # item the Slideshow timer must NOT also try to advance - otherwise a
    # multi-minute video gets cut off as soon as a single Slideshow
    # interval elapses, instead of playing to its full length.
    if ($script:CurrentIsVideo) { return }
    if ($ChkShuffle.IsChecked) { Go-RandomImage } else { Go-NextImage }
})

function Start-Play {
    if ($script:CurImages.Count -eq 0) { return }
    Stop-QuickPlay   # the two autoplay modes are mutually exclusive

    $seconds = if ($CmbInterval.SelectedItem) { [int]$CmbInterval.SelectedItem.Tag } else { 30 }
    $script:PlayTimer.Interval = [TimeSpan]::FromSeconds($seconds)

    $script:IsPlaying = $true
    $BtnPlay.Content = "⏸ Stop Slideshow (S)"
    $script:PlayTimer.Start()

    $mode = if ($ChkShuffle.IsChecked) { "shuffled" } else { "in order" }
    Set-Status "Slideshow running ($mode, every $($CmbInterval.SelectedItem.Content)) - click Stop to pause."
}

function Stop-Play {
    if (-not $script:IsPlaying) { return }
    $script:IsPlaying = $false
    $script:PlayTimer.Stop()
    $BtnPlay.Content = "▶ Start Slideshow (S)"
}

# Applies a live interval change immediately if the slideshow is currently
# running, so you don't have to stop/start it to see the new timing take
# effect.
function Update-PlayIntervalIfRunning {
    if (-not $script:IsPlaying) { return }
    $seconds = if ($CmbInterval.SelectedItem) { [int]$CmbInterval.SelectedItem.Tag } else { 30 }
    $script:PlayTimer.Interval = [TimeSpan]::FromSeconds($seconds)
}

function Invoke-ManualNav {
    <#
    .SYNOPSIS
        Wraps a manual "jump to a specific image/video" action - arrow key,
        nav button, global hotkey, or full-screen-view arrow key - so it
        composes correctly with Slideshow.

        Previously every manual-nav call site did "Stop-Play; ...; Go-X",
        so tapping an arrow key while Slideshow was running killed the
        slideshow entirely instead of just skipping ahead. The user
        pressing an arrow is overriding what's showing RIGHT NOW, not
        asking to exit auto-advance - so Slideshow now keeps running: it
        just gets a fresh full interval starting from the item the user
        jumped to, instead of a stale tick (timed from the previous item)
        firing moments later.

        Quick Play (a separate, faster autoplay mode) is still stopped by
        a manual jump - the two don't make sense to run at the same time.
    #>
    param([Parameter(Mandatory)][scriptblock]$NavAction)
    Stop-QuickPlay
    & $NavAction
    if ($script:IsPlaying) {
        $script:PlayTimer.Stop()
        $script:PlayTimer.Start()
    }
}

# ---------------------------------------------------------------------------
# Quick Play (stop-motion style flip-through at a fixed Low/Medium/High pace)
# ---------------------------------------------------------------------------
$script:QuickPlayTimer.Add_Tick({ Go-NextImage })

function Start-QuickPlay {
    if ($script:CurImages.Count -eq 0) { return }
    Stop-Play   # the two autoplay modes are mutually exclusive

    $speedName = Get-SelectedQuickPlaySpeedName
    $script:QuickPlayTimer.Interval = [TimeSpan]::FromMilliseconds($script:QuickPlaySpeeds[$speedName])

    $script:IsQuickPlaying = $true
    $BtnQuickPlay.Content = "⏸ Stop (P)"
    $script:QuickPlayTimer.Start()
    Set-Status "Quick-playing snapshots ($($speedName.ToLower())-paced) - click Stop to pause."
}

function Stop-QuickPlay {
    if (-not $script:IsQuickPlaying) { return }
    $script:IsQuickPlaying = $false
    $script:QuickPlayTimer.Stop()
    $BtnQuickPlay.Content = "▶ Play (P)"
}

# Applies a live pace change immediately if Quick Play is currently running,
# so switching Low/Medium/High mid-play takes effect without a stop/start.
function Update-QuickPlaySpeedIfRunning {
    if (-not $script:IsQuickPlaying) { return }
    $speedName = Get-SelectedQuickPlaySpeedName
    $script:QuickPlayTimer.Interval = [TimeSpan]::FromMilliseconds($script:QuickPlaySpeeds[$speedName])
}

# ---------------------------------------------------------------------------
# Hotkey enable/disable
# ---------------------------------------------------------------------------
function Enable-Hotkeys {
    $ok = Register-GlobalArrowHotkeys `
            -OnRight     { Invoke-OnUiThread { Invoke-ManualNav { Go-NextImage } } } `
            -OnLeft      { Invoke-OnUiThread { Invoke-ManualNav { Go-PrevImage } } } `
            -OnUp        { Invoke-OnUiThread { Invoke-ManualNav { Go-NextFolder } } } `
            -OnDown      { Invoke-OnUiThread { Invoke-ManualNav { Go-PrevFolder } } } `
            -OnSlideshow { Invoke-OnUiThread { if ($script:IsPlaying)      { Stop-Play }      else { Start-Play } } } `
            -OnQuickPlay { Invoke-OnUiThread { if ($script:IsQuickPlaying) { Stop-QuickPlay } else { Start-QuickPlay } } } `
            -OnAspect    { Invoke-OnUiThread { Cycle-VideoAspectRatio } }

    if ($ok) {
        Set-Status "Global hotkeys active: arrows = navigate, S = slideshow, P = quick play, A = aspect ratio. Press Ctrl+Alt+W anywhere to toggle them all."
        $script:Config.HotkeysEnabled = $true
    } else {
        Set-Status "Could not register global hotkeys (another app may own them)." -IsError
        $ChkHotkeys.IsChecked = $false
        $script:Config.HotkeysEnabled = $false
    }
    Save-PlayerConfig -Config $script:Config | Out-Null
}

function Disable-Hotkeys {
    Unregister-GlobalArrowHotkeys
    Set-Status "Global hotkeys paused - arrows and S/P work normally in other apps again. Press Ctrl+Alt+W anywhere to re-enable."
    $script:Config.HotkeysEnabled = $false
    Save-PlayerConfig -Config $script:Config | Out-Null
}

# ---------------------------------------------------------------------------
# Event wiring
# ---------------------------------------------------------------------------
$BtnRight.Add_Click({ Invoke-ManualNav { Go-NextImage } })
$BtnLeft.Add_Click({ Invoke-ManualNav { Go-PrevImage } })
$BtnUp.Add_Click({ Invoke-ManualNav { Go-NextFolder } })
$BtnDown.Add_Click({ Invoke-ManualNav { Go-PrevFolder } })

$BtnPlay.Add_Click({
    if ($script:IsPlaying) { Stop-Play } else { Start-Play }
})

$BtnQuickPlay.Add_Click({
    if ($script:IsQuickPlaying) { Stop-QuickPlay } else { Start-QuickPlay }
})

foreach ($rb in @($RbSpeedLow, $RbSpeedMedium, $RbSpeedHigh)) {
    $rb.Add_Checked({
        $script:Config.QuickPlaySpeed = Get-SelectedQuickPlaySpeedName
        Save-PlayerConfig -Config $script:Config | Out-Null
        Update-QuickPlaySpeedIfRunning
    })
}

# Keyboard shortcuts, window-focused (WPF PreviewKeyDown) version of every
# key in the toggleable global hotkey group: arrows, S (slideshow), P (quick
# play), and A (aspect ratio). This local copy is what makes each key work
# while the app window has focus EVEN IF "Hotkeys enabled" is OFF - S, P, and
# A are ordinary letters typed constantly in every other app, so they're only
# ever hijacked system-wide when the checkbox is explicitly turned on.
#
# When the "Global Hotkey" checkbox IS on, the OS-level RegisterHotKey hook in
# GlobalHotkey.ps1 intercepts all of these bare keys (arrows, S, P, A) before
# WPF ever sees them, so this branch simply won't fire for them (no double
# navigation / double toggling). When the checkbox is off, nothing is
# registered at the OS level, so without this local fallback none of these
# keys would do anything at all, even while the app window is focused.
#
# IMPORTANT: this is wired to PreviewKeyDown (tunneling), not KeyDown
# (bubbling). WPF's ComboBox/Button/CheckBox controls consume arrow keys
# themselves (dropdown navigation, focus movement) and mark the event
# Handled before it ever bubbles up to the window - so if any of those
# controls happens to have keyboard focus, a window-level KeyDown handler
# never sees the arrow press at all. PreviewKeyDown runs top-down, before
# any child control gets a chance to swallow it, so arrows work regardless
# of which control currently has focus.
$window.Add_PreviewKeyDown({
    param($sender, $e)

    # Let normal typing/editing happen in any focused text box - e.g. the
    # trim marker's numeric time entry, or the library folder path.
    # Without this, Left/Right/S/P/A below hijack keystrokes meant for the
    # box (image navigation instead of moving the cursor, "A" never
    # actually being typed, etc.) since PreviewKeyDown tunnels down from
    # the Window BEFORE the box's own KeyDown/TextInput ever sees it -
    # marking it Handled here stops it from reaching the box at all.
    # Checked two ways since OriginalSource can occasionally point at an
    # internal template part rather than the TextBox itself.
    if ($e.OriginalSource -is [System.Windows.Controls.TextBox] -or
        [System.Windows.Input.Keyboard]::FocusedElement -is [System.Windows.Controls.TextBox]) {
        return
    }

    # Exception: if a ComboBox's dropdown is actually open, let Up/Down
    # behave normally (move the highlighted item) instead of hijacking it
    # for image navigation - otherwise the dropdown becomes unusable.
    if (($e.Key -eq 'Up' -or $e.Key -eq 'Down') -and
        $e.OriginalSource -is [System.Windows.Controls.ComboBox] -and
        $e.OriginalSource.IsDropDownOpen) {
        return
    }

    switch ($e.Key) {
        'S' {
            if ($script:IsPlaying) { Stop-Play } else { Start-Play }
            $e.Handled = $true
        }
        'P' {
            if ($script:IsQuickPlaying) { Stop-QuickPlay } else { Start-QuickPlay }
            $e.Handled = $true
        }
        'Right' {
            Invoke-ManualNav { Go-NextImage }
            $e.Handled = $true
        }
        'Left' {
            Invoke-ManualNav { Go-PrevImage }
            $e.Handled = $true
        }
        'Up' {
            Invoke-ManualNav { Go-NextFolder }
            $e.Handled = $true
        }
        'Down' {
            Invoke-ManualNav { Go-PrevFolder }
            $e.Handled = $true
        }
        'A' {
            Cycle-VideoAspectRatio
            $e.Handled = $true
        }
    }
})

# Whenever a text box in the app gains focus, temporarily release the
# global bare-key hotkey group (Left/Right/Up/Down/S/P/A - registered
# with NO modifier, see GlobalHotkey.ps1) so those keys behave normally
# while typing/editing. This is a different problem from the
# PreviewKeyDown guard above: RegisterHotKey intercepts these keys at the
# OS level, system-wide, BEFORE they ever reach WPF's own input/routing
# system at all - so if "Hotkeys enabled (global)" is checked, no
# WPF-side guard can help; the only fix is releasing the OS-level
# registration itself while a box has focus, then restoring it once
# focus leaves (only if the checkbox is still checked - the user may
# have unchecked it while a box had focus).
$window.Add_GotKeyboardFocus({
    param($sender, $e)
    if ($e.NewFocus -is [System.Windows.Controls.TextBox] -and $ChkHotkeys.IsChecked) {
        Unregister-GlobalArrowHotkeys
    }
})
$window.Add_LostKeyboardFocus({
    param($sender, $e)
    if ($e.OldFocus -is [System.Windows.Controls.TextBox] -and $ChkHotkeys.IsChecked -and
        -not ($e.NewFocus -is [System.Windows.Controls.TextBox])) {
        Enable-Hotkeys
    }
})

$BtnBrowse.Add_Click({
    Add-Type -AssemblyName System.Windows.Forms
    Stop-Play

    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Choose the folder that contains your movie snapshot subfolders"
    if ($script:Config.RootPath) { $dlg.SelectedPath = $script:Config.RootPath }

    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:Config.RootPath = $dlg.SelectedPath
        $script:Config.FolderIndex = 0
        $script:Config.ImageIndex = 0
        Save-PlayerConfig -Config $script:Config | Out-Null
        $TxtRootPath.Text = $script:Config.RootPath
        Reload-Library
        Show-CurrentImage
    }
})

$BtnRefresh.Add_Click({
    Stop-Play
    Stop-QuickPlay
    Reload-Library
    Show-CurrentImage
})

$CmbStyle.Add_SelectionChanged({
    if ($script:Folders.Count -gt 0 -and $script:CurImages.Count -gt 0) {
        Show-CurrentImage
        Apply-PreviewStretch
    }
    # Keep the overlay combo (when it's currently showing wallpaper-style
    # options) reflecting the same choice - but not if THIS change is
    # itself the result of that combo syncing back here (see the guard's
    # other use below), which would otherwise ping-pong the two forever.
    if (-not $script:SyncingAspectCombos -and $script:PreviewComboMode -ne 'Video') {
        $script:SyncingAspectCombos = $true
        try { Sync-ComboSelectionByTag -Source $CmbStyle -Target $CmbPreviewStretch }
        finally { $script:SyncingAspectCombos = $false }
    }
})

$CmbVideoAspect.Add_SelectionChanged({
    # Only matters while a video is actually the current item - re-applying
    # (same path) updates the forced aspect ratio live without restarting
    # playback. See the -NOTES on Show-VideoWallpaper.
    if ($script:CurrentIsVideo -and $script:Folders.Count -gt 0 -and $script:CurImages.Count -gt 0) {
        Apply-CurrentWallpaper
        Apply-PreviewVideoAspectRatio -AspectRatio (Get-SelectedVideoAspectRatio)
        Apply-FullScreenAspectRatio
    }
    # Keep the overlay combo (when it's currently showing aspect-ratio
    # options) reflecting the same choice - but not if THIS change is
    # itself the result of that combo syncing back here (see the guard's
    # other use below), which would otherwise ping-pong the two forever.
    if (-not $script:SyncingAspectCombos -and $script:PreviewComboMode -eq 'Video') {
        $script:SyncingAspectCombos = $true
        try { Sync-ComboSelectionByTag -Source $CmbVideoAspect -Target $CmbPreviewStretch }
        finally { $script:SyncingAspectCombos = $false }
    }
})

$CmbPreviewStretch.Add_SelectionChanged({
    # A rebuild in Set-PreviewComboMode is in progress - its own logic
    # handles restoring the correct selection; this event is just noise
    # from that rebuild (e.g. Set-ComboItems' transient auto-selection).
    if ($script:SyncingAspectCombos) { return }

    # This combo is always just a synced mirror of whichever real control
    # matches its current mode - CmbVideoAspect for videos, CmbStyle for
    # images (see Set-PreviewComboMode). That real control's own
    # SelectionChanged (above) does the actual applying; pushing the
    # choice there and stopping is what keeps both directions consistent
    # instead of this combo also independently applying anything itself.
    $script:SyncingAspectCombos = $true
    try {
        if ($script:PreviewComboMode -eq 'Video') {
            Sync-ComboSelectionByTag -Source $CmbPreviewStretch -Target $CmbVideoAspect
        } else {
            Sync-ComboSelectionByTag -Source $CmbPreviewStretch -Target $CmbStyle
        }
    }
    finally { $script:SyncingAspectCombos = $false }
})

# Keep the video preview panel's size correctly proportioned as the
# window (and therefore the available preview area) is resized or
# maximized. Watches PreviewArea (the stable outer container), NOT
# PreviewHost - PreviewHost's own size is now the OUTPUT of
# Apply-PreviewVideoAspectRatio, so watching it as the trigger would
# fire this handler every time it sets that size, looping forever.
$PreviewArea.Add_SizeChanged({
    if ($script:CurrentIsVideo -and $VidPreview.Visibility -eq 'Visible') {
        Apply-PreviewVideoAspectRatio -AspectRatio $script:LastPreviewAspectRatio
    }
})

# ---------------------------------------------------------------------------
# Video trim markers (drag-handle timeline under the in-app preview)
# ---------------------------------------------------------------------------
# Lets a video play only a marked in/out section instead of its full
# length - persisted per-file via modules/VideoMarkers.ps1. State below
# tracks only the CURRENTLY LOADED video in VidPreview; it's reset every
# time Show-MarkerBar/Hide-MarkerBar run (i.e. on every navigation step -
# see Update-PreviewDisplay).
$script:MarkerPath            = $null   # full path MarkerBar is currently showing
$script:MarkerDurationSeconds = 0
$script:MarkerStartSeconds    = 0
$script:MarkerEndSeconds      = 0
$script:MarkerHasTrim         = $false  # $false = no saved marker - i.e. "full video"
$script:MarkerHandleWidth     = 14
$script:MarkerDraggingStart   = $false  # true while ThumbMarkStart is mid-drag
$script:MarkerDraggingEnd     = $false  # true while ThumbMarkEnd is mid-drag

# Which handle the shared "Set Here"/nudge controls (BtnSetSelectedHere,
# BtnSelMinus1/etc.) currently act on - 'Start' or 'End'. Changes the
# moment either handle is clicked or dragged (see each Thumb's
# DragStarted) - see Update-MarkerSelectionVisual for how this reflects
# in the UI (handle color, the "Editing: START/END" label).
$script:MarkerSelectedSide = 'Start'

# The user's own explicit play/pause choice for the in-app preview (see
# BtnPlayPause). Separate from the temporary Pause() calls the marker
# handles make while scrubbing - those don't touch this, and check it on
# release so a drag never overrides a preview you'd deliberately paused.
$script:VidPreviewPaused = $false

function Format-MarkerTime {
    param([double]$Seconds)
    $ts = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    '{0}:{1:D2}' -f [int]$ts.TotalMinutes, $ts.Seconds
}

function Parse-MarkerTime {
    <#
    .SYNOPSIS
        Inverse of Format-MarkerTime, for the numeric entry boxes - accepts
        "m:ss" (e.g. "1:32"), "ss" / "ss.s" (bare seconds), returns $null
        for anything that doesn't parse so the caller can leave the field
        untouched rather than accepting garbage.
    #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if ($t -match '^(\d+):(\d{1,2}(\.\d+)?)$') {
        return ([double]$Matches[1] * 60) + [double]$Matches[2]
    }
    if ($t -match '^\d+(\.\d+)?$') {
        return [double]$t
    }
    return $null
}

function Get-SnappedMarkerTime {
    <#
    .SYNOPSIS
        Light "magnetic" snapping for drag-positioned marker times - snaps
        to the very start/end of the video when dragged close to it, and
        to the nearest whole second otherwise, so you can land on a clean
        cut point without needing pixel-perfect mouse control. Both
        thresholds are in SECONDS (not pixels), so they behave the same
        regardless of how wide the track happens to be on screen.
    #>
    param([double]$Seconds, [double]$Duration)
    $edgeThreshold  = 0.35
    $wholeThreshold = 0.15
    if ($Seconds -le $edgeThreshold) { return 0 }
    if (($Duration - $Seconds) -le $edgeThreshold) { return $Duration }
    $nearestWhole = [Math]::Round($Seconds)
    if ([Math]::Abs($Seconds - $nearestWhole) -le $wholeThreshold) { return [double]$nearestWhole }
    return $Seconds
}

function Get-MarkerTrackUsableWidth {
    # The draggable range for a handle's CENTER is the track's width minus
    # one handle width (so a handle's own bounding box never runs past
    # either edge of the track) - standard range-slider math. Falls back to
    # the bar's last known width until the first layout pass actually
    # measures MarkerTrack (ActualWidth is 0 before that).
    $w = $MarkerTrack.ActualWidth - $script:MarkerHandleWidth
    if ($w -lt 1) { return 1 }
    return $w
}

function Update-MarkerHandlePositions {
    <#
    .SYNOPSIS
        Repositions ThumbMarkStart/ThumbMarkEnd/MarkerRangeFill (and the
        range label + numeric entry boxes) from the current
        $script:MarkerStartSeconds/EndSeconds/DurationSeconds. Call after a
        drag, a nudge/"Set Here"/typed value, a fresh video load, Reset, or
        a track resize - this is the single place that keeps every piece
        of the trimmer UI in sync with those three values.
    #>
    if ($script:MarkerDurationSeconds -le 0) { return }
    $usable = Get-MarkerTrackUsableWidth
    $startX = ($script:MarkerStartSeconds / $script:MarkerDurationSeconds) * $usable
    $endX   = ($script:MarkerEndSeconds   / $script:MarkerDurationSeconds) * $usable

    [System.Windows.Controls.Canvas]::SetLeft($ThumbMarkStart, $startX)
    [System.Windows.Controls.Canvas]::SetLeft($ThumbMarkEnd, $endX)
    [System.Windows.Controls.Canvas]::SetLeft($MarkerRangeFill, $startX + ($script:MarkerHandleWidth / 2))
    $MarkerRangeFill.Width = [Math]::Max(0, $endX - $startX)

    $TxtMarkStartInput.Text = Format-MarkerTime $script:MarkerStartSeconds
    $TxtMarkEndInput.Text   = Format-MarkerTime $script:MarkerEndSeconds

    $TxtMarkRange.Text = if ($script:MarkerHasTrim) {
        $selDuration = $script:MarkerEndSeconds - $script:MarkerStartSeconds
        "Marked: $(Format-MarkerTime $script:MarkerStartSeconds) - $(Format-MarkerTime $script:MarkerEndSeconds) ($(Format-MarkerTime $selDuration) long)"
    } else {
        "Full video ($(Format-MarkerTime $script:MarkerDurationSeconds))"
    }
    $BtnClearMarker.Visibility = if ($script:MarkerHasTrim) { 'Visible' } else { 'Collapsed' }
}

function Update-MarkerSelectionVisual {
    <#
    .SYNOPSIS
        Reflects $script:MarkerSelectedSide in the UI: both handles start
        out accent/yellow; the selected one (the one nudge/Set-Here
        currently act on) turns red via its Tag (see the TemplateBinding
        in MainWindow.xaml), the other stays yellow. The "Editing:
        START/END" label updates to match. Call whenever selection
        changes (each Thumb's DragStarted) or the marker bar is
        (re)activated for a new video.
    #>
    $accent = $window.FindResource('AccentBrush')
    $selected = $window.FindResource('MarkerSelectedBrush')
    if ($script:MarkerSelectedSide -eq 'End') {
        $ThumbMarkStart.Tag = $accent
        $ThumbMarkEnd.Tag = $selected
        $TxtMarkerSelectedLabel.Text = 'Editing: END'
    } else {
        $ThumbMarkStart.Tag = $selected
        $ThumbMarkEnd.Tag = $accent
        $TxtMarkerSelectedLabel.Text = 'Editing: START'
    }
}

function Show-MarkerBar {
    <#
    .SYNOPSIS
        Called once VidPreview has actually opened a video (real duration
        known - see its MediaOpened handler). Loads any saved marker for
        this file (or defaults to the full length), positions the handles,
        seeks playback to the marked start, and switches the bar (already
        visible - see Show-MarkerBarInactive) from its disabled placeholder
        state into a fully interactive one.
    #>
    if (-not $script:CurrentIsVideo -or $script:Folders.Count -eq 0 -or $script:CurImages.Count -eq 0) { return }
    if (-not $VidPreview.NaturalDuration.HasTimeSpan) { return }

    $imgFile = $script:CurImages[$script:Config.ImageIndex]
    $script:MarkerPath = $imgFile.FullName
    $script:MarkerDurationSeconds = $VidPreview.NaturalDuration.TimeSpan.TotalSeconds

    $marker = Get-VideoMarker -Path $script:MarkerPath
    if ($marker) {
        $script:MarkerHasTrim = $true
        $script:MarkerStartSeconds = [Math]::Min($marker.Start, $script:MarkerDurationSeconds)
        $script:MarkerEndSeconds   = [Math]::Min($marker.End,   $script:MarkerDurationSeconds)
        if ($script:MarkerStartSeconds -gt 0) {
            $VidPreview.Position = [TimeSpan]::FromSeconds($script:MarkerStartSeconds)
        }
    } else {
        $script:MarkerHasTrim = $false
        $script:MarkerStartSeconds = 0
        $script:MarkerEndSeconds   = $script:MarkerDurationSeconds
    }

    $ThumbMarkStart.Visibility = 'Visible'
    $ThumbMarkEnd.Visibility = 'Visible'
    $MarkerRangeFill.Visibility = 'Visible'
    $BtnPreviewMarker.Visibility = 'Visible'
    $PnlMarkerStartRow.Visibility = 'Visible'
    $PnlMarkerEndRow.Visibility = 'Visible'
    $PnlMarkerEditRow.Visibility = 'Visible'
    $MarkerBar.IsEnabled = $true
    $MarkerBar.Opacity = 1

    $script:MarkerSelectedSide = 'Start'
    Update-MarkerSelectionVisual
    Update-MarkerHandlePositions
    $MarkerBar.Visibility = 'Visible'
}

function Show-MarkerBarInactive {
    <#
    .SYNOPSIS
        Shows the marker bar for the current video item WITHOUT real
        interactivity - real duration (needed to accurately position/drag
        the handles) is only known once VidPreview actually opens the file
        (see Show-MarkerBar, called from MediaOpened, which turns this
        same bar interactive). Called for every video item as soon as it
        becomes current (see Update-PreviewDisplay) and again whenever
        playback stops/fails, so the bar's layout space and last-known
        marker are always visible - only the drag handles/Reset button
        turn on, once you actually press Play.
    #>
    if (-not $script:CurrentIsVideo -or $script:Folders.Count -eq 0 -or $script:CurImages.Count -eq 0) {
        Hide-MarkerBar
        return
    }

    $imgFile = $script:CurImages[$script:Config.ImageIndex]
    $script:MarkerPath = $imgFile.FullName
    $script:MarkerDurationSeconds = 0
    $script:MarkerHasTrim = $false

    $marker = Get-VideoMarker -Path $script:MarkerPath
    $TxtMarkRange.Text = if ($marker) {
        "Marked: $(Format-MarkerTime $marker.Start) - $(Format-MarkerTime $marker.End) - click play to adjust"
    } else {
        "Click play to preview and set markers"
    }

    $ThumbMarkStart.Visibility = 'Collapsed'
    $ThumbMarkEnd.Visibility = 'Collapsed'
    $MarkerRangeFill.Visibility = 'Collapsed'
    $BtnClearMarker.Visibility = 'Collapsed'
    $BtnPreviewMarker.Visibility = 'Collapsed'
    $PnlMarkerStartRow.Visibility = 'Collapsed'
    $PnlMarkerEndRow.Visibility = 'Collapsed'
    $PnlMarkerEditRow.Visibility = 'Collapsed'
    $MarkerBar.IsEnabled = $false
    $MarkerBar.Opacity = 0.6
    $MarkerBar.Visibility = 'Visible'
}

function Hide-MarkerBar {
    <#
    .SYNOPSIS
        Fully hides the bar - only for when the current item ISN'T a video
        at all (see Update-PreviewDisplay's image branch). Every video-
        related state change (stop, fail, navigate to another video before
        pressing Play) uses Show-MarkerBarInactive instead, which keeps the
        bar visible - see its own notes.
    #>
    $MarkerBar.Visibility = 'Collapsed'
    $script:MarkerPath = $null
    $script:MarkerDurationSeconds = 0
}

function Save-CurrentMarker {
    <#
    .SYNOPSIS
        Persists the in-progress drag result via Set-VideoMarker, and - if
        this file happens to be the one currently playing as the desktop
        wallpaper too - asks it to re-apply live, picking up the new in/out
        points without restarting the video from scratch (see the
        "$alreadyPlayingThis" branch near the top of Show-VideoWallpaper).
    #>
    if (-not $script:MarkerPath) { return }
    Set-VideoMarker -Path $script:MarkerPath -Start $script:MarkerStartSeconds -End $script:MarkerEndSeconds
    $script:MarkerHasTrim = $true
    Update-MarkerHandlePositions

    if ($script:VideoWallpaperCurrentPath -eq $script:MarkerPath) {
        Request-WallpaperApply
    }
}

function Sync-PreviewFrameToPosition {
    <#
    .SYNOPSIS
        Seeks VidPreview to a position and makes sure the new frame
        actually repaints. WPF's MediaElement has a long-standing quirk:
        while paused, setting Position updates the player internally but
        does NOT redraw the visible frame - the picture just sits frozen
        on whatever was showing before. Briefly calling Play() forces a
        real repaint at the new position; -KeepPaused re-pauses right
        after (used while a marker handle is still being dragged, so
        scrubbing always freezes on each new frame rather than resuming
        playback mid-drag); otherwise it re-pauses only if
        $script:VidPreviewPaused - the user's own explicit pause - is set,
        so a drag/nudge/typed value never secretly resumes a preview you
        paused on purpose, and never leaves one running that shouldn't be.

    .DESCRIPTION
        Two things this works around, both easy to hit while trimming:

        1. Seeking to the video's EXACT real duration and calling Play()
           lands right on EOF, which fires a genuine MediaEnded - and that
           handler jumps playback back to the marked start. Since the end
           marker's default (unmarked) value IS the real duration, almost
           any nudge/drag/typed-entry that lands back at "the end" would
           immediately, invisibly get overridden by that jump - looking
           exactly like "the end controls don't do anything". Clamping the
           seek target a hair inside the real duration avoids ever
           actually reaching true EOF here.

        2. Play() and Pause() both act on MediaElement's underlying
           pipeline ASYNCHRONOUSLY - calling them back-to-back in the same
           synchronous line doesn't reliably give the pipeline time to
           actually decode/render a frame before Pause() cuts it off, so
           the "force a repaint" trick can silently fail to show anything
           new. Deferring the Pause() to a Background-priority dispatcher
           callback instead lets the just-started Play() settle first.
    #>
    param([double]$Seconds, [switch]$KeepPaused)
    $target = [Math]::Max(0, $Seconds)
    if ($script:MarkerDurationSeconds -gt 0.1) {
        $target = [Math]::Min($target, $script:MarkerDurationSeconds - 0.05)
    }
    $VidPreview.Position = [TimeSpan]::FromSeconds($target)
    $VidPreview.Play()
    if ($KeepPaused -or $script:VidPreviewPaused) {
        $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ $VidPreview.Pause() }) | Out-Null
    }
}

function Nudge-MarkerStart {
    <#
    .SYNOPSIS
        Fine-adjusts the start point by a fixed amount (the +/-1s / +/-0.1s
        buttons) - same clamp (can't cross the end point, min 1s gap),
        same live-seek-and-save as dragging the handle itself.
    #>
    param([double]$Delta)
    if ($script:MarkerDurationSeconds -le 0) { return }
    $newStart = $script:MarkerStartSeconds + $Delta
    $newStart = [Math]::Min($newStart, $script:MarkerEndSeconds - 1)
    $script:MarkerStartSeconds = [Math]::Max(0, $newStart)
    Update-MarkerHandlePositions
    Sync-PreviewFrameToPosition -Seconds $script:MarkerStartSeconds
    Save-CurrentMarker
}

function Nudge-MarkerEnd {
    <#
    .SYNOPSIS
        Fine-adjusts the end point by a fixed amount - mirrors Nudge-MarkerStart.
    #>
    param([double]$Delta)
    if ($script:MarkerDurationSeconds -le 0) { return }
    $newEnd = $script:MarkerEndSeconds + $Delta
    $newEnd = [Math]::Max($newEnd, $script:MarkerStartSeconds + 1)
    $script:MarkerEndSeconds = [Math]::Min($script:MarkerDurationSeconds, $newEnd)
    Update-MarkerHandlePositions
    Sync-PreviewFrameToPosition -Seconds $script:MarkerEndSeconds
    Save-CurrentMarker
}

# Fires once the in-app preview has actually opened the file and knows
# its real dimensions. On "Default" (AspectRatio -le 0) this is what lets
# the panel snap from "filling the available area" to the video's true
# native shape - see Apply-PreviewVideoAspectRatio's notes on the brief
# flash this corrects. Also the point at which real duration is known, so
# this is where the marker bar/handles get (re)built - see Show-MarkerBar.
$VidPreview.Add_MediaOpened({
    if ($script:CurrentIsVideo) {
        Apply-PreviewVideoAspectRatio -AspectRatio $script:LastPreviewAspectRatio
        Show-MarkerBar
    }
})

# The in-app preview has no OnEnded concept of its own (it doesn't drive
# Slideshow/advancing - the desktop copy via Show-VideoWallpaper does) -
# it just always loops whatever the current video is. Marked (trimmed)
# videos loop from the marked start instead of true frame 0 - and
# normally never reach here at all, since $script:PreviewMarkerTimer's
# poll already loops them at the marked END before true EOF fires this;
# this remains as a fallback for the untrimmed/no-marker case (where
# MarkerEndSeconds is exactly the real duration).
$VidPreview.Add_MediaEnded({
    $VidPreview.Position = [TimeSpan]::FromSeconds($script:MarkerStartSeconds)
    $VidPreview.Play()
})

# Opening the file for in-app preview failed (codec issue, etc.) - this is
# a separate playback attempt from the desktop copy, so it may well still
# be playing fine on the desktop even though the preview couldn't open it.
# Reuses PnlVideoBadge (the same "click to play" filler shown pre-click),
# just swapped to an explanatory message instead of the filename/affordance.
$VidPreview.Add_MediaFailed({
    $VidPreview.Visibility = 'Collapsed'
    $PreviewControlsPanel.Visibility = 'Collapsed'
    Show-MarkerBarInactive
    $TxtVideoBadgeTitle.Text = "PLAYING AS VIDEO WALLPAPER"
    $TxtVideoBadgeSub.Text = "Check your desktop - couldn't load an in-app preview for this file"
    $PnlVideoBadge.Visibility = 'Visible'
})

# Enforces the marked end point for the in-app preview (MediaElement has
# no "reached position X" event of its own - see the identical reasoning
# on VideoWallpaper.ps1's own poll timer). No-ops whenever the bar isn't
# showing. Skips entirely while a handle is being dragged - otherwise
# dragging the end handle backward past the live playback position would
# fight the user's own drag by snapping it back to the start on every tick.
$script:PreviewMarkerTimer.Add_Tick({
    if ($MarkerBar.Visibility -ne 'Visible' -or $script:MarkerDurationSeconds -le 0) { return }
    if (-not $script:MarkerDraggingStart -and -not $script:MarkerDraggingEnd) {
        if ($script:MarkerHasTrim -and $VidPreview.Position.TotalSeconds -ge $script:MarkerEndSeconds) {
            $VidPreview.Position = [TimeSpan]::FromSeconds($script:MarkerStartSeconds)
        }
    }
})
$script:PreviewMarkerTimer.Start()

# Dragging the start handle. $script:MarkerStartSeconds (not the handle's
# on-screen Canvas.Left) is the single source of truth - each DragDelta
# accumulates e.HorizontalChange straight onto it (converted to seconds)
# and Update-MarkerHandlePositions derives the pixel position fresh from
# that afterwards. Earlier this read the position back via
# Canvas.GetLeft() first and accumulated onto THAT instead, which could
# drift out of sync with the real value by a pixel or two on rapid
# DragDelta ticks and show up as the handle jittering while dragging -
# going through $script:MarkerStartSeconds directly avoids that
# read-back entirely. Also pauses playback for the duration of the drag
# and seeks live to the exact frame under the handle (see
# ThumbMarkStart's DragStarted/DragCompleted below) so the video actually
# shows what you're marking as you move it, not just after you let go.
# Clamped so it can never cross the end handle (leaves at least 1 real
# second between them - a shorter "section" isn't worth marking).
$ThumbMarkStart.Add_DragStarted({
    if ($script:MarkerDurationSeconds -le 0) { return }
    $script:MarkerDraggingStart = $true
    $script:MarkerSelectedSide = 'Start'
    Update-MarkerSelectionVisual
    $VidPreview.Pause()
})
$ThumbMarkStart.Add_DragDelta({
    param($eventSender, $e)
    if ($script:MarkerDurationSeconds -le 0) { return }
    $usable = Get-MarkerTrackUsableWidth
    $secondsPerPixel = $script:MarkerDurationSeconds / $usable
    $newStart = $script:MarkerStartSeconds + ($e.HorizontalChange * $secondsPerPixel)
    $newStart = [Math]::Min($newStart, $script:MarkerEndSeconds - 1)
    $newStart = [Math]::Max(0, $newStart)
    $script:MarkerStartSeconds = Get-SnappedMarkerTime -Seconds $newStart -Duration $script:MarkerDurationSeconds
    Update-MarkerHandlePositions
    # -KeepPaused: stay frozen on each frame as you drag rather than
    # resuming playback mid-drag (DragCompleted below decides what
    # happens once you let go).
    Sync-PreviewFrameToPosition -Seconds $script:MarkerStartSeconds -KeepPaused
})
$ThumbMarkStart.Add_DragCompleted({
    if ($script:MarkerDurationSeconds -le 0) { return }
    $script:MarkerDraggingStart = $false
    # Show the START frame you just set. If the preview wasn't paused
    # before this drag, resume playing from there; if it was, stay
    # paused right on that frame - either way it shows the point you
    # just marked, not wherever it happened to be before you started.
    Sync-PreviewFrameToPosition -Seconds $script:MarkerStartSeconds
    Save-CurrentMarker
})

# Dragging the end handle - same pattern as the start handle, mirrored.
# Seeks live to the marked END frame while dragging (rather than the
# start) so you can see exactly where the clip will cut off.
$ThumbMarkEnd.Add_DragStarted({
    if ($script:MarkerDurationSeconds -le 0) { return }
    $script:MarkerDraggingEnd = $true
    $script:MarkerSelectedSide = 'End'
    Update-MarkerSelectionVisual
    $VidPreview.Pause()
})
$ThumbMarkEnd.Add_DragDelta({
    param($eventSender, $e)
    if ($script:MarkerDurationSeconds -le 0) { return }
    $usable = Get-MarkerTrackUsableWidth
    $secondsPerPixel = $script:MarkerDurationSeconds / $usable
    $newEnd = $script:MarkerEndSeconds + ($e.HorizontalChange * $secondsPerPixel)
    $newEnd = [Math]::Max($newEnd, $script:MarkerStartSeconds + 1)
    $newEnd = [Math]::Min($script:MarkerDurationSeconds, $newEnd)
    $script:MarkerEndSeconds = Get-SnappedMarkerTime -Seconds $newEnd -Duration $script:MarkerDurationSeconds
    Update-MarkerHandlePositions
    Sync-PreviewFrameToPosition -Seconds $script:MarkerEndSeconds -KeepPaused
})
$ThumbMarkEnd.Add_DragCompleted({
    if ($script:MarkerDurationSeconds -le 0) { return }
    $script:MarkerDraggingEnd = $false
    if ($script:VidPreviewPaused) {
        # Stay paused right on the END frame you just set - that's the
        # point you were adjusting, so that's what should be on screen.
        Sync-PreviewFrameToPosition -Seconds $script:MarkerEndSeconds
    } else {
        # Preview is actively running - resume from the marked START so
        # releasing shows the whole marked section play through, instead
        # of starting right at its own tail end.
        Sync-PreviewFrameToPosition -Seconds $script:MarkerStartSeconds
    }
    Save-CurrentMarker
})

# Click anywhere on the empty track to move the playhead there WITHOUT
# touching either marker - just for scrubbing to a moment you want to
# look at. Thumb captures/handles its own MouseLeftButtonDown for
# dragging (and marks the event Handled), so a click that actually lands
# on a handle never reaches this - only clicks on the open track do.
$MarkerTrack.Add_MouseLeftButtonDown({
    param($eventSender, $e)
    if ($script:MarkerDurationSeconds -le 0) { return }
    $usable = Get-MarkerTrackUsableWidth
    $clickX = $e.GetPosition($MarkerTrack).X - ($script:MarkerHandleWidth / 2)
    $frac = [Math]::Max(0, [Math]::Min(1, $clickX / $usable))
    Sync-PreviewFrameToPosition -Seconds ($frac * $script:MarkerDurationSeconds)
})

# Track resized (e.g. window resized) - handles are positioned in pixels,
# so they need recalculating against the new width; the underlying
# start/end seconds themselves don't change.
$MarkerTrack.Add_SizeChanged({ Update-MarkerHandlePositions })

# Drops the saved marker for this file entirely - goes back to playing in
# full, same as a video that was never marked.
$BtnClearMarker.Add_Click({
    if (-not $script:MarkerPath) { return }
    Clear-VideoMarker -Path $script:MarkerPath
    $script:MarkerHasTrim = $false
    $script:MarkerStartSeconds = 0
    $script:MarkerEndSeconds = $script:MarkerDurationSeconds
    Update-MarkerHandlePositions
    Sync-PreviewFrameToPosition -Seconds 0

    if ($script:VideoWallpaperCurrentPath -eq $script:MarkerPath) {
        Request-WallpaperApply
    }
})

# Loops just the marked section on repeat - lets you check what the
# wallpaper will actually show without dragging anything. Works even for
# an unmarked (full-length) video - it just plays normally, since there's
# no section to loop yet. The existing poll timer above already loops
# within $script:MarkerStartSeconds/EndSeconds once $script:MarkerHasTrim
# is true (true immediately after any edit below, since every one of them
# calls Save-CurrentMarker) - this button doesn't need its own separate
# loop logic, it just needs to start playback at the right spot.
$BtnPreviewMarker.Add_Click({
    if ($script:MarkerDurationSeconds -le 0) { return }
    $script:VidPreviewPaused = $false
    $BtnPlayPause.Content = "⏸"
    $BtnPlayPause.ToolTip = "Pause preview"
    Sync-PreviewFrameToPosition -Seconds $script:MarkerStartSeconds
})

# "Set Here" - use wherever the preview is CURRENTLY sitting (paused or
# playing) as whichever point is currently selected (see
# $script:MarkerSelectedSide / Update-MarkerSelectionVisual - set by
# clicking or dragging either handle), instead of dragging a handle to
# it. Pair with click-to-seek/Play-Pause above to land on the exact frame
# you want first, then press this to mark it - much more precise than
# dragging on a short track for a long video.
$BtnSetSelectedHere.Add_Click({
    if ($script:MarkerDurationSeconds -le 0) { return }
    $pos = $VidPreview.Position.TotalSeconds
    if ($script:MarkerSelectedSide -eq 'End') {
        $script:MarkerEndSeconds = [Math]::Min($script:MarkerDurationSeconds, [Math]::Max($pos, $script:MarkerStartSeconds + 1))
    } else {
        $script:MarkerStartSeconds = [Math]::Max(0, [Math]::Min($pos, $script:MarkerEndSeconds - 1))
    }
    Update-MarkerHandlePositions
    Save-CurrentMarker
})

# Nudge buttons - fine correction after a rough drag, without needing
# pixel-perfect mouse control. Act on whichever handle is currently
# selected - see Nudge-MarkerStart/Nudge-MarkerEnd and
# $script:MarkerSelectedSide.
$BtnSelMinus1.Add_Click({ if ($script:MarkerSelectedSide -eq 'End') { Nudge-MarkerEnd -Delta -1 } else { Nudge-MarkerStart -Delta -1 } })
$BtnSelMinus01.Add_Click({ if ($script:MarkerSelectedSide -eq 'End') { Nudge-MarkerEnd -Delta -0.1 } else { Nudge-MarkerStart -Delta -0.1 } })
$BtnSelPlus01.Add_Click({ if ($script:MarkerSelectedSide -eq 'End') { Nudge-MarkerEnd -Delta 0.1 } else { Nudge-MarkerStart -Delta 0.1 } })
$BtnSelPlus1.Add_Click({ if ($script:MarkerSelectedSide -eq 'End') { Nudge-MarkerEnd -Delta 1 } else { Nudge-MarkerStart -Delta 1 } })

# Numeric time entry - type an exact time and press Enter to apply it.
# An unparsable value (see Parse-MarkerTime) just reverts the box back to
# the last valid value instead of accepting garbage.
$TxtMarkStartInput.Add_KeyDown({
    param($eventSender, $e)
    # WPF's Key enum member for this key is Enter (not the WinForms-style
    # "Return") - using the typed enum reference here instead of a bare
    # string avoids any ambiguity/coercion issue with that name.
    if ($e.Key -ne [System.Windows.Input.Key]::Enter -or $script:MarkerDurationSeconds -le 0) { return }
    $val = Parse-MarkerTime -Text $TxtMarkStartInput.Text
    if ($null -eq $val) { $TxtMarkStartInput.Text = Format-MarkerTime $script:MarkerStartSeconds; return }
    $script:MarkerStartSeconds = [Math]::Max(0, [Math]::Min($val, $script:MarkerEndSeconds - 1))
    $script:MarkerSelectedSide = 'Start'
    Update-MarkerSelectionVisual
    Update-MarkerHandlePositions
    Sync-PreviewFrameToPosition -Seconds $script:MarkerStartSeconds
    Save-CurrentMarker
})
$TxtMarkEndInput.Add_KeyDown({
    param($eventSender, $e)
    if ($e.Key -ne [System.Windows.Input.Key]::Enter -or $script:MarkerDurationSeconds -le 0) { return }
    $val = Parse-MarkerTime -Text $TxtMarkEndInput.Text
    if ($null -eq $val) { $TxtMarkEndInput.Text = Format-MarkerTime $script:MarkerEndSeconds; return }
    $script:MarkerEndSeconds = [Math]::Min($script:MarkerDurationSeconds, [Math]::Max($val, $script:MarkerStartSeconds + 1))
    $script:MarkerSelectedSide = 'End'
    Update-MarkerSelectionVisual
    Update-MarkerHandlePositions
    Sync-PreviewFrameToPosition -Seconds $script:MarkerEndSeconds
    Save-CurrentMarker
})

# Play/Pause toggle for the in-app preview. $script:VidPreviewPaused is
# the user's own explicit choice - separate from the temporary Pause()
# calls the marker handles above make while scrubbing (those don't touch
# this flag or the button's icon, and check it on release so a drag never
# overrides a preview you'd deliberately paused first).
$BtnPlayPause.Add_Click({
    if ($script:VidPreviewPaused) {
        $VidPreview.Play()
        $script:VidPreviewPaused = $false
        $BtnPlayPause.Content = "⏸"
        $BtnPlayPause.ToolTip = "Pause preview"
    } else {
        $VidPreview.Pause()
        $script:VidPreviewPaused = $true
        $BtnPlayPause.Content = "▶"
        $BtnPlayPause.ToolTip = "Resume preview"
    }
})


# on every navigation step (see Update-PreviewDisplay). Only relevant while
# PnlVideoBadge is showing the "click to play" filler for the CURRENT item -
# $script:CurrentIsVideo already guards against stray clicks landing here
# for an image, and Update-PreviewDisplay re-shows this filler (re-arming
# the click requirement) on every subsequent navigation step, so there's no
# way to "pre-click" an item you haven't navigated to yet.
$PnlVideoBadge.Add_MouseLeftButtonDown({
    if (-not $script:CurrentIsVideo) { return }
    if ($script:Folders.Count -eq 0 -or $script:CurImages.Count -eq 0) { return }
    $imgFile = $script:CurImages[$script:Config.ImageIndex]

    try {
        $VidPreview.Stop()
        $VidPreview.Source = New-Object System.Uri($imgFile.FullName)
        $VidPreview.Visibility = 'Visible'
        $PnlVideoBadge.Visibility = 'Collapsed'
        $VidPreview.Play()
        $script:VidPreviewPaused = $false
        $BtnPlayPause.Content = "⏸"
        $BtnPlayPause.ToolTip = "Pause preview"
        $PreviewControlsPanel.Visibility = 'Visible'
        Apply-PreviewVideoAspectRatio -AspectRatio (Get-SelectedVideoAspectRatio)
    }
    catch {
        # Couldn't open it for in-app preview (codec issue, etc.) - the
        # desktop copy (Show-VideoWallpaper) is unaffected by this and may
        # still play fine; fall back to the badge's failure message. (The
        # async case - Play() accepts but the file then fails to actually
        # open - is instead caught by Add_MediaFailed above.)
        $VidPreview.Visibility = 'Collapsed'
        $PreviewControlsPanel.Visibility = 'Collapsed'
        Show-MarkerBarInactive
        $TxtVideoBadgeTitle.Text = "PLAYING AS VIDEO WALLPAPER"
        $TxtVideoBadgeSub.Text = "Check your desktop - couldn't load an in-app preview for this file"
        $PnlVideoBadge.Visibility = 'Visible'
    }
})

# Lets you end the in-app preview on demand instead of only ever having it
# replaced by the next navigation step's filler (see Update-PreviewDisplay).
# Re-arms the same "click to play" badge PnlVideoBadge already shows before
# a first click, and - same as the video->image branch of
# Apply-CurrentWallpaper - trims the working set afterwards, since stopping
# playback here frees a real MediaElement/Media Foundation resource just
# like closing the desktop video wallpaper does (see Invoke-MemoryTrim).
$BtnStopPreview.Add_Click({
    $VidPreview.Stop()
    $VidPreview.Source = $null
    $VidPreview.Visibility = 'Collapsed'
    $PreviewControlsPanel.Visibility = 'Collapsed'
    Show-MarkerBarInactive

    if ($script:CurrentIsVideo -and $script:Folders.Count -gt 0 -and $script:CurImages.Count -gt 0) {
        $imgFile = $script:CurImages[$script:Config.ImageIndex]
        $TxtVideoBadgeTitle.Text = $imgFile.Name
        $TxtVideoBadgeSub.Text = "Click to play in-app preview - already playing as your desktop wallpaper"
    }
    $PnlVideoBadge.Visibility = 'Visible'

    Invoke-MemoryTrim
})

$BtnFullScreen.Add_Click({ Show-FullScreenPreview })

$BtnHowTo.Add_Click({ Show-HowToWindow })

$CmbInterval.Add_SelectionChanged({
    if ($CmbInterval.SelectedItem) {
        $script:Config.SlideshowIntervalSeconds = [int]$CmbInterval.SelectedItem.Tag
        Save-PlayerConfig -Config $script:Config | Out-Null
        Update-PlayIntervalIfRunning
    }
})

$ChkShuffle.Add_Checked({
    $script:Config.ShuffleEnabled = $true
    Save-PlayerConfig -Config $script:Config | Out-Null
})
$ChkShuffle.Add_Unchecked({
    $script:Config.ShuffleEnabled = $false
    Save-PlayerConfig -Config $script:Config | Out-Null
})

$BtnLoopFolder.Add_Click({
    $script:Config.LoopFolderEnabled = -not [bool]$script:Config.LoopFolderEnabled
    Save-PlayerConfig -Config $script:Config | Out-Null
    Update-LoopFolderButtonVisual
})

$ChkHotkeys.Add_Checked({ Enable-Hotkeys })
$ChkHotkeys.Add_Unchecked({ Disable-Hotkeys })

$ChkVideoAudio.Add_Checked({
    $script:Config.VideoAudioEnabled = $true
    Save-PlayerConfig -Config $script:Config | Out-Null
    Set-VideoWallpaperMuted -Muted $false
})
$ChkVideoAudio.Add_Unchecked({
    $script:Config.VideoAudioEnabled = $false
    Save-PlayerConfig -Config $script:Config | Out-Null
    Set-VideoWallpaperMuted -Muted $true
})

$window.Add_Closing({
    $script:PlayTimer.Stop()
    $script:QuickPlayTimer.Stop()
    $script:WallpaperApplyTimer.Stop()
    $script:PreviewMarkerTimer.Stop()
    try { $VidPreview.Stop() } catch { }
    try { if ($script:MedPreviewFS) { $script:MedPreviewFS.Stop() } } catch { }
    Uninitialize-HotkeyInfrastructure
    Uninitialize-VideoWallpaperInfrastructure
    if ($script:FullScreenWindow) { $script:FullScreenWindow.Close() }
    if ($script:HowToWindow) { $script:HowToWindow.Close() }
    Save-PlayerConfig -Config $script:Config | Out-Null
})

$window.Add_Loaded({
    $TxtRootPath.Text = if ($script:Config.RootPath) { $script:Config.RootPath } else { '(not set)' }
    Sync-StyleComboToConfig
    Sync-VideoAspectComboToConfig

    # Slideshow interval always starts at 30s on launch, regardless of
    # whatever was saved last session (same policy as Hotkeys/Video Audio
    # below) - force it back to the default before syncing the combo box
    # so the UI and the timer agree.
    $script:Config.SlideshowIntervalSeconds = 30
    Sync-IntervalComboToConfig

    Sync-QuickPlaySpeedToConfig
    Apply-PreviewStretch
    $ChkShuffle.IsChecked = [bool]$script:Config.ShuffleEnabled
    Update-LoopFolderButtonVisual

    # Global Hotkey and Video Audio always start OFF/unchecked on launch,
    # regardless of what was saved last session - these are deliberately
    # NOT restored from config (unlike Shuffle/Style/etc.), so the
    # user has to opt back in each run instead of it silently re-enabling.
    $ChkHotkeys.IsChecked = $false
    $ChkVideoAudio.IsChecked = $false
    $script:Config.HotkeysEnabled = $false
    $script:Config.VideoAudioEnabled = $false
    Set-VideoWallpaperMuted -Muted $true
    Save-PlayerConfig -Config $script:Config | Out-Null

    Reload-Library
    Show-CurrentImage

    # Stand up the shared hotkey hook + the always-on Ctrl+Alt+W master
    # toggle. The toggle flips the checkbox, which reuses the existing
    # Enable/Disable-Hotkeys event path - so the arrow hotkeys can be
    # switched on/off from anywhere, even while the app sits unfocused in
    # the background. (Arrow hotkeys themselves stay OFF at launch per the
    # policy above - only the Ctrl+Alt+W hook itself is always registered.)
    $infraOk = Initialize-HotkeyInfrastructure -Window $window -OnToggle {
        Invoke-OnUiThread { $ChkHotkeys.IsChecked = -not $ChkHotkeys.IsChecked }
    }
    if (-not $infraOk) {
        Set-Status "Ctrl+Alt+W master toggle unavailable (another app may own it). The checkbox still works." -IsError
    }

    # Auto-start the slideshow at the configured/default interval (30s) as
    # soon as the app opens, instead of requiring a manual click/press of S.
    Start-Play
})

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
# try/finally ensures the global hotkeys always get released, even if the
# script errors out or the console window is force-closed rather than the
# app window being closed normally - otherwise a leftover process can keep
# holding Left/Right/Up/Down and block the next launch from registering
# them ("one or more hotkeys failed to register").
try {
    $window.ShowDialog() | Out-Null
}
finally {
    $script:PlayTimer.Stop()
    $script:QuickPlayTimer.Stop()
    $script:WallpaperApplyTimer.Stop()
    $script:PreviewMarkerTimer.Stop()
    Uninitialize-HotkeyInfrastructure
}
