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
    $script:PnlVideoBadgeFS = $script:FullScreenWindow.FindName('PnlVideoBadgeFS')

    # Click anywhere, or Esc, to exit full screen.
    $script:FullScreenWindow.Add_MouseLeftButtonDown({ Hide-FullScreenPreview })

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
            'Right'  { Stop-Play; Stop-QuickPlay; Go-NextImage;  $e.Handled = $true }
            'Left'   { Stop-Play; Stop-QuickPlay; Go-PrevImage;  $e.Handled = $true }
            'Up'     { Stop-Play; Stop-QuickPlay; Go-NextFolder; $e.Handled = $true }
            'Down'   { Stop-Play; Stop-QuickPlay; Go-PrevFolder; $e.Handled = $true }
        }
    })
}

function Show-FullScreenPreview {
    Initialize-FullScreenWindow

    # Set the image directly here rather than via Sync-FullScreenImage -
    # that helper only copies the image when the window IsVisible, which
    # is still false at this point (we haven't called Show() yet), so
    # relying on it here left the window blank/black on first open.
    if ($ImgPreview.Source) { $script:ImgFullScreen.Source = $ImgPreview.Source }
    $script:ImgFullScreen.Stretch = $ImgPreview.Stretch
    Sync-FullScreenVideoBadge

    $script:FullScreenWindow.Show()
    $script:FullScreenWindow.Activate()
}

function Hide-FullScreenPreview {
    if ($script:FullScreenWindow) { $script:FullScreenWindow.Hide() }
}

# Keeps the full-screen window's image matched to the main preview - called
# any time the preview updates, so Slideshow/Quick Play/manual navigation
# stay in sync while full screen is already open.
function Sync-FullScreenImage {
    if ($script:FullScreenWindow -and $script:FullScreenWindow.IsVisible -and $ImgPreview.Source) {
        $script:ImgFullScreen.Source = $ImgPreview.Source
    }
    Sync-FullScreenVideoBadge
}

# Mirrors the "playing as video wallpaper" badge into the full-screen
# window whenever it exists, regardless of whether it's currently visible.
function Sync-FullScreenVideoBadge {
    if (-not $script:PnlVideoBadgeFS) { return }
    $isVideo = [bool]$script:CurrentIsVideo
    $script:PnlVideoBadgeFS.Visibility = if ($isVideo) { 'Visible' } else { 'Collapsed' }
    if ($script:ImgFullScreen) {
        $script:ImgFullScreen.Visibility = if ($isVideo) { 'Collapsed' } else { 'Visible' }
    }
}

$ImgPreview   = Get-El 'ImgPreview'
$PnlVideoBadge = Get-El 'PnlVideoBadge'
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

function Sync-PreviewStretchToConfig {
    foreach ($item in $CmbPreviewStretch.Items) {
        if ($item.Tag -eq $script:Config.PreviewStretch) {
            $CmbPreviewStretch.SelectedItem = $item
            return
        }
    }
    $CmbPreviewStretch.SelectedIndex = 0
}

# Applies the selected fit mode (Uniform/UniformToFill/Fill/None) to both
# the in-panel preview and the full-screen window, and persists it.
function Apply-PreviewStretch {
    if (-not $CmbPreviewStretch.SelectedItem) { return }
    $stretch = [System.Windows.Media.Stretch]$CmbPreviewStretch.SelectedItem.Tag
    $ImgPreview.Stretch = $stretch
    if ($script:ImgFullScreen) { $script:ImgFullScreen.Stretch = $stretch }

    $script:Config.PreviewStretch = $CmbPreviewStretch.SelectedItem.Tag
    Save-PlayerConfig -Config $script:Config | Out-Null
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
        # No in-app frame to show - the video only ever plays embedded on
        # the real desktop. Swap in the badge instead of a broken image.
        $ImgPreview.Source = $null
        $ImgPreview.Visibility = 'Collapsed'
        $PnlVideoBadge.Visibility = 'Visible'
        Sync-FullScreenImage
        return
    }

    $PnlVideoBadge.Visibility = 'Collapsed'
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
        # OnEnded fires every time the video loops back to frame 0 - jump
        # to the next item instead of just looping, same "what's next"
        # logic the Slideshow timer uses (respects the Shuffle checkbox).
        $ok = Show-VideoWallpaper -Path $imgFile.FullName -Muted $muted -AspectRatio $aspectRatio -OnEnded {
            Invoke-OnUiThread {
                if ($ChkShuffle.IsChecked) { Go-RandomImage } else { Go-NextImage }
            }
        }
        if ($ok) {
            Set-Status "Playing video wallpaper: $($imgFile.Name) - it'll auto-advance when it finishes."
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
    if (Test-VideoWallpaperActive) { Hide-VideoWallpaper }

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
function Go-NextImage {
    if ($script:CurImages.Count -eq 0) { return }

    if ($script:Config.ImageIndex -ge $script:CurImages.Count - 1) {
        # Last image in this folder - roll into the next folder's first image.
        Go-NextFolder
        return
    }

    $script:Config.ImageIndex++
    Update-PreviewDisplay
    Request-WallpaperApply
}

function Go-PrevImage {
    if ($script:CurImages.Count -eq 0) { return }

    if ($script:Config.ImageIndex -le 0) {
        # First image in this folder - roll into the previous folder's last image.
        Go-PrevFolder -LandOnLast
        return
    }

    $script:Config.ImageIndex--
    Update-PreviewDisplay
    Request-WallpaperApply
}

function Go-NextFolder {
    if ($script:Folders.Count -eq 0) { return }
    $script:Config.FolderIndex = ($script:Config.FolderIndex + 1) % $script:Folders.Count
    $script:Config.ImageIndex = 0
    Load-CurrentFolderImages
    Update-PreviewDisplay
    Request-WallpaperApply
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
    #>
    if ($script:Folders.Count -eq 0) { return }

    $prevFolderIndex = $script:Config.FolderIndex
    $prevImageIndex  = $script:Config.ImageIndex

    $newFolderIndex = Get-Random -Minimum 0 -Maximum $script:Folders.Count
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
    Request-WallpaperApply
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
            -OnRight     { Invoke-OnUiThread { Stop-Play; Stop-QuickPlay; Go-NextImage } } `
            -OnLeft      { Invoke-OnUiThread { Stop-Play; Stop-QuickPlay; Go-PrevImage } } `
            -OnUp        { Invoke-OnUiThread { Stop-Play; Stop-QuickPlay; Go-NextFolder } } `
            -OnDown      { Invoke-OnUiThread { Stop-Play; Stop-QuickPlay; Go-PrevFolder } } `
            -OnSlideshow { Invoke-OnUiThread { if ($script:IsPlaying)      { Stop-Play }      else { Start-Play } } } `
            -OnQuickPlay { Invoke-OnUiThread { if ($script:IsQuickPlaying) { Stop-QuickPlay } else { Start-QuickPlay } } }

    if ($ok) {
        Set-Status "Global hotkeys active: arrows = navigate, S = slideshow, P = quick play. Press Ctrl+Alt+W anywhere to toggle them all."
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
$BtnRight.Add_Click({ Stop-Play; Stop-QuickPlay; Go-NextImage })
$BtnLeft.Add_Click({ Stop-Play; Stop-QuickPlay; Go-PrevImage })
$BtnUp.Add_Click({ Stop-Play; Stop-QuickPlay; Go-NextFolder })
$BtnDown.Add_Click({ Stop-Play; Stop-QuickPlay; Go-PrevFolder })

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

# Keyboard shortcuts: S = toggle Slideshow, P = toggle Quick Play. These
# are deliberately window-focused (WPF KeyDown), NOT global RegisterHotKey
# hotkeys like the arrows - S and P are ordinary letters typed constantly
# in every other app, so hijacking them system-wide would break normal
# typing anywhere while this app is running.
#
# Right/Left/Up/Down are ALSO handled here as a local fallback, same as the
# full-screen preview window already does. When the "Global Hotkey" checkbox
# is ON, the OS-level RegisterHotKey hook in GlobalHotkey.ps1 intercepts bare
# arrow keys before WPF ever sees them, so this branch simply won't fire (no
# double navigation). When the checkbox is OFF, nothing is registered at the
# OS level, so without this fallback the arrows would do nothing at all, even
# while the app window is focused.
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
            Stop-Play; Stop-QuickPlay; Go-NextImage
            $e.Handled = $true
        }
        'Left' {
            Stop-Play; Stop-QuickPlay; Go-PrevImage
            $e.Handled = $true
        }
        'Up' {
            Stop-Play; Stop-QuickPlay; Go-NextFolder
            $e.Handled = $true
        }
        'Down' {
            Stop-Play; Stop-QuickPlay; Go-PrevFolder
            $e.Handled = $true
        }
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
    }
})

$CmbVideoAspect.Add_SelectionChanged({
    # Only matters while a video is actually the current item - re-applying
    # (same path) updates the forced aspect ratio live without restarting
    # playback. See the -NOTES on Show-VideoWallpaper.
    if ($script:CurrentIsVideo -and $script:Folders.Count -gt 0 -and $script:CurImages.Count -gt 0) {
        Apply-CurrentWallpaper
    }
})

$CmbPreviewStretch.Add_SelectionChanged({ Apply-PreviewStretch })

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
    Sync-PreviewStretchToConfig
    Apply-PreviewStretch
    $ChkShuffle.IsChecked = [bool]$script:Config.ShuffleEnabled

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
    Uninitialize-HotkeyInfrastructure
}
