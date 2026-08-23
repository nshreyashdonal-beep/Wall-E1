<#
.SYNOPSIS
    GlobalHotkey.ps1 - Registers system-wide hotkeys (RegisterHotKey) so the
    arrow keys work while this app runs in the background, even without
    focus, and routes WM_HOTKEY messages back into WPF callbacks.

.DESCRIPTION
    IMPORTANT TRADE-OFF: because these are bare arrow keys (no Ctrl/Alt
    modifier), registering them makes Left/Right/Up/Down stop reaching
    every OTHER application system-wide while hotkeys are enabled - typing
    in a text box, browsing, gaming, etc. will not receive arrow key input.
    Use the "Hotkeys Enabled" checkbox in the app to toggle this off when
    you need normal arrow key behavior elsewhere.
#>

if (-not ([System.Management.Automation.PSTypeName]'Win32.HotkeyNative').Type) {
    Add-Type -Namespace Win32 -Name HotkeyNative -MemberDefinition @"
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterHotKey(System.IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnregisterHotKey(System.IntPtr hWnd, int id);
"@
}

# Virtual-key codes
$script:VK_LEFT  = 0x25
$script:VK_UP    = 0x26
$script:VK_RIGHT = 0x27
$script:VK_DOWN  = 0x28
$script:VK_W     = 0x57   # master on/off toggle (with Ctrl+Alt)
$script:VK_S     = 0x53   # slideshow toggle (bare key, part of toggleable group)
$script:VK_P     = 0x50   # quick play toggle (bare key, part of toggleable group)

# Modifier flags for RegisterHotKey.
# MOD_NOREPEAT: suppress OS auto-repeat while a key is held, so holding an
# arrow down fires once instead of flooding Next/Previous calls.
$script:MOD_ALT      = 0x1
$script:MOD_CONTROL  = 0x2
$script:MOD_NOREPEAT = 0x4000

# Hotkey IDs (arbitrary, must be unique per registering window)
$script:HOTKEY_ID_LEFT   = 9001
$script:HOTKEY_ID_RIGHT  = 9002
$script:HOTKEY_ID_UP     = 9003
$script:HOTKEY_ID_DOWN   = 9004
$script:HOTKEY_ID_TOGGLE    = 9005   # Ctrl+Alt+W master toggle (always registered while app runs)
$script:HOTKEY_ID_SLIDESHOW = 9006   # bare S slideshow toggle (part of toggleable group, on/off with the arrows)
$script:HOTKEY_ID_QUICKPLAY = 9007   # bare P quick play toggle (part of toggleable group, on/off with the arrows)

$script:HotkeyWindowHandle = [IntPtr]::Zero
$script:HotkeySource       = $null
$script:HotkeyHook         = $null
# Persistent map of hotkey ID -> callback scriptblock. The master toggle lives
# here for the whole app lifetime; the four arrow entries come and go as the
# arrow hotkeys are enabled/disabled. The single WM_HOTKEY hook dispatches
# whatever IDs are currently present.
$script:HotkeyCallbacks    = @{}
$script:ArrowsRegistered   = $false
$script:InfraInitialized   = $false

function Initialize-HotkeyInfrastructure {
    <#
    .SYNOPSIS
        One-time setup: installs the shared WM_HOTKEY message hook on the
        window and registers the always-on Ctrl+Alt+W master toggle. Call
        once, after the window is shown, BEFORE enabling the arrow hotkeys.

    .DESCRIPTION
        The hook and the master toggle deliberately live SEPARATELY from the
        toggleable hotkey group (arrows + S/P): that group gets registered and
        unregistered every time the user (or the master toggle) flips "Hotkeys
        enabled", but the hook and Ctrl+Alt+W must persist the whole time the
        app runs so the user can re-enable the group from anywhere - without
        ever refocusing or reopening the app. Ctrl+Alt+W uses modifiers so it
        never interferes with normal typing and is safe to leave always-on.

    .PARAMETER Window
        The WPF Window object (must already be Show()n / have a handle).

    .PARAMETER OnToggle
        Scriptblock invoked when Ctrl+Alt+W is pressed (toggle the hotkey group).

    .OUTPUTS
        $true on success. $false (app continues, with a warning) if the window
        handle isn't ready or Ctrl+Alt+W is already owned by another app.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Window,
        [Parameter(Mandatory)] [scriptblock]$OnToggle
    )

    # Idempotent: tear down any prior infrastructure first so a second call
    # never stacks hooks or leaks the previous master-toggle registration.
    if ($script:InfraInitialized) {
        Uninitialize-HotkeyInfrastructure
    }

    $helper = New-Object System.Windows.Interop.WindowInteropHelper($Window)
    $script:HotkeyWindowHandle = $helper.Handle

    if ($script:HotkeyWindowHandle -eq [IntPtr]::Zero) {
        Write-Error "Initialize-HotkeyInfrastructure: window handle not available yet - call after the window is shown."
        return $false
    }

    # Fresh callback table (master toggle only; arrows are added later by
    # Register-GlobalArrowHotkeys).
    $script:HotkeyCallbacks = @{}

    # Install the single WM_HOTKEY (0x0312) hook that dispatches whatever
    # hotkey IDs are present in $script:HotkeyCallbacks at fire time.
    $source = [System.Windows.Interop.HwndSource]::FromHwnd($script:HotkeyWindowHandle)
    $hook = [System.Windows.Interop.HwndSourceHook] {
        param($hwnd, $msg, $wParam, $lParam, [ref]$handled)
        if ($msg -eq 0x0312) {
            $id = $wParam.ToInt32()
            if ($script:HotkeyCallbacks.ContainsKey($id)) {
                & $script:HotkeyCallbacks[$id]
                $handled.Value = $true
            }
        }
        return [IntPtr]::Zero
    }
    $source.AddHook($hook)
    $script:HotkeySource    = $source
    $script:HotkeyHook      = $hook
    $script:InfraInitialized = $true

    # Register the master toggle: Ctrl+Alt+W. Modifiers keep it from
    # interfering with plain typing anywhere, so it stays registered for the
    # whole app lifetime regardless of the toggleable group's state.
    $mods = $script:MOD_CONTROL -bor $script:MOD_ALT -bor $script:MOD_NOREPEAT
    if ([Win32.HotkeyNative]::RegisterHotKey($script:HotkeyWindowHandle, $script:HOTKEY_ID_TOGGLE, $mods, $script:VK_W)) {
        $script:HotkeyCallbacks[$script:HOTKEY_ID_TOGGLE] = $OnToggle
    } else {
        Write-Warning "Initialize-HotkeyInfrastructure: could not register the Ctrl+Alt+W master toggle (another app may own it). The hotkey group still works, but must be toggled from the app window."
        return $false
    }

    return $true
}

function Register-GlobalArrowHotkeys {
    <#
    .SYNOPSIS
        Registers the toggleable global hotkey group - Left/Right/Up/Down plus
        the bare S (slideshow) and P (quick play) keys - and wires each to a
        scriptblock callback. Requires Initialize-HotkeyInfrastructure to have
        already installed the shared hook.

    .DESCRIPTION
        S and P are registered as BARE global keys (no modifier), deliberately
        sharing the arrows' on/off lifecycle: one "Hotkeys enabled" flip (or
        one Ctrl+Alt+W press) activates or releases the whole group together.
        The trade-off matches the arrows - while the group is on, bare S and P
        won't reach other apps either - which is why Ctrl+Alt+W (always-on)
        exists to release everything at once.

    .PARAMETER OnLeft / OnRight / OnUp / OnDown / OnSlideshow / OnQuickPlay
        Scriptblocks invoked (on the UI thread) when each key fires.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock]$OnLeft,
        [Parameter(Mandatory)] [scriptblock]$OnRight,
        [Parameter(Mandatory)] [scriptblock]$OnUp,
        [Parameter(Mandatory)] [scriptblock]$OnDown,
        [Parameter(Mandatory)] [scriptblock]$OnSlideshow,
        [Parameter(Mandatory)] [scriptblock]$OnQuickPlay
    )

    if (-not $script:InfraInitialized -or $script:HotkeyWindowHandle -eq [IntPtr]::Zero) {
        Write-Error "Register-GlobalArrowHotkeys: hotkey infrastructure not initialized - call Initialize-HotkeyInfrastructure first."
        return $false
    }

    # Guard against stacking if called again while the group is already
    # registered (e.g. the "Hotkeys enabled" checkbox toggled twice).
    if ($script:ArrowsRegistered) {
        Unregister-GlobalArrowHotkeys
    }

    $ok = $true
    $ok = $ok -and [Win32.HotkeyNative]::RegisterHotKey($script:HotkeyWindowHandle, $script:HOTKEY_ID_LEFT,      $script:MOD_NOREPEAT, $script:VK_LEFT)
    $ok = $ok -and [Win32.HotkeyNative]::RegisterHotKey($script:HotkeyWindowHandle, $script:HOTKEY_ID_RIGHT,     $script:MOD_NOREPEAT, $script:VK_RIGHT)
    $ok = $ok -and [Win32.HotkeyNative]::RegisterHotKey($script:HotkeyWindowHandle, $script:HOTKEY_ID_UP,        $script:MOD_NOREPEAT, $script:VK_UP)
    $ok = $ok -and [Win32.HotkeyNative]::RegisterHotKey($script:HotkeyWindowHandle, $script:HOTKEY_ID_DOWN,      $script:MOD_NOREPEAT, $script:VK_DOWN)
    $ok = $ok -and [Win32.HotkeyNative]::RegisterHotKey($script:HotkeyWindowHandle, $script:HOTKEY_ID_SLIDESHOW, $script:MOD_NOREPEAT, $script:VK_S)
    $ok = $ok -and [Win32.HotkeyNative]::RegisterHotKey($script:HotkeyWindowHandle, $script:HOTKEY_ID_QUICKPLAY, $script:MOD_NOREPEAT, $script:VK_P)

    if (-not $ok) {
        Write-Warning "Register-GlobalArrowHotkeys: one or more hotkeys failed to register (likely already claimed by another app). Unregistering any that succeeded."
        Unregister-GlobalArrowHotkeys
        return $false
    }

    $script:HotkeyCallbacks[$script:HOTKEY_ID_LEFT]      = $OnLeft
    $script:HotkeyCallbacks[$script:HOTKEY_ID_RIGHT]     = $OnRight
    $script:HotkeyCallbacks[$script:HOTKEY_ID_UP]        = $OnUp
    $script:HotkeyCallbacks[$script:HOTKEY_ID_DOWN]      = $OnDown
    $script:HotkeyCallbacks[$script:HOTKEY_ID_SLIDESHOW] = $OnSlideshow
    $script:HotkeyCallbacks[$script:HOTKEY_ID_QUICKPLAY] = $OnQuickPlay
    $script:ArrowsRegistered = $true

    return $true
}

function Unregister-GlobalArrowHotkeys {
    <#
    .SYNOPSIS
        Releases the toggleable hotkey group (arrows + bare S/P), leaving the
        shared hook and the Ctrl+Alt+W master toggle intact. Safe to call even
        if not registered.
    #>
    [CmdletBinding()]
    param()

    $groupIds = @(
        $script:HOTKEY_ID_LEFT, $script:HOTKEY_ID_RIGHT, $script:HOTKEY_ID_UP, $script:HOTKEY_ID_DOWN,
        $script:HOTKEY_ID_SLIDESHOW, $script:HOTKEY_ID_QUICKPLAY
    )

    if ($script:HotkeyWindowHandle -ne [IntPtr]::Zero) {
        foreach ($id in $groupIds) {
            [Win32.HotkeyNative]::UnregisterHotKey($script:HotkeyWindowHandle, $id) | Out-Null
        }
    }

    # Drop the group's callbacks but keep the master toggle entry so Ctrl+Alt+W
    # keeps working while the group is off.
    foreach ($id in $groupIds) {
        if ($script:HotkeyCallbacks.ContainsKey($id)) { $script:HotkeyCallbacks.Remove($id) }
    }

    $script:ArrowsRegistered = $false
}

function Uninitialize-HotkeyInfrastructure {
    <#
    .SYNOPSIS
        Full teardown for app exit: releases the arrow hotkeys, the master
        toggle, and detaches the shared WM_HOTKEY hook. Safe to call anytime.

    .DESCRIPTION
        Detaching the hook matters: without it a stale hook stays attached to
        the HwndSource, and a subsequent init would stack another hook on top,
        causing a single keypress to fire its callback multiple times. Fully
        releasing the hotkeys here also prevents a leftover process from
        holding the keys and blocking the next launch's registration.
    #>
    [CmdletBinding()]
    param()

    Unregister-GlobalArrowHotkeys

    if ($script:HotkeyWindowHandle -ne [IntPtr]::Zero) {
        [Win32.HotkeyNative]::UnregisterHotKey($script:HotkeyWindowHandle, $script:HOTKEY_ID_TOGGLE) | Out-Null
    }

    if ($script:HotkeySource -and $script:HotkeyHook) {
        $script:HotkeySource.RemoveHook($script:HotkeyHook) | Out-Null
    }

    $script:HotkeySource     = $null
    $script:HotkeyHook       = $null
    $script:HotkeyCallbacks  = @{}
    $script:InfraInitialized = $false
}
