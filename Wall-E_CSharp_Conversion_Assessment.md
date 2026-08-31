# Wall-E — C# Conversion Effort Assessment

## Current Codebase Size

| File | Lines |
|---|---|
| `Wall-E.ps1` | 1,495 |
| `modules/GlobalHotkey.ps1` | 276 |
| `modules/SnapshotLibrary.ps1` | 225 |
| `modules/VideoWallpaper.ps1` | 466 |
| `modules/Wallpaper.ps1` | 484 |
| `modules/WallpaperHelper.ps1` | 112 |
| **PowerShell logic total** | **2,563** |
| `UI/MainWindow.xaml` | 595 |
| `UI/HowToWindow.xaml` | 171 |
| `UI/FullScreenWindow.xaml` | 50 |
| **XAML total** | **~1,300** |
| **Grand total** | **~3,874 lines** |

---

## 1. The XAML Is Almost Entirely Reusable

C# WPF and PowerShell's `XamlReader` use the **exact same XAML dialect**. The dark ComboBox style, the letterbox `Rectangle`s, the crossfade `MediaElement`s — none of it needs to be redesigned or rewritten.

- `MainWindow.xaml`, `FullScreenWindow.xaml`, `HowToWindow.xaml`, and all the ComboBox/CheckBox/etc. `Style`s carry over almost as-is
- Mainly need to add `x:Class` to each root element and wire it to a C# code-behind class
- This is ~1,300 lines that don't need real rewriting, just re-hosting

## 2. Win32 Interop Code Is Nearly a Copy-Paste

All the P/Invoke declarations (`Add-Type -MemberDefinition` blocks) are literally C# syntax already, just embedded inside PowerShell strings.

- `RegisterHotKey`/`UnregisterHotKey` signatures in `GlobalHotkey.ps1` translate to C# `DllImport` almost line-for-line
- `SetParent`/`FindWindow`/`EnumWindows` in `VideoWallpaper.ps1`'s WorkerW trick are the same story
- This is mechanical translation, low risk, but needs careful retesting since Win32 interop bugs are easy to introduce

## 3. State Management Needs Real Rewriting, Not Just Translation

Every function needs re-typing (PowerShell is dynamically typed and forgiving; C# is not) and every `$script:`-scoped variable needs to become a proper class field or property.

- `$script:`-scoped variables become class fields on a `MainWindow` partial class — straightforward but touches almost every function
- PowerShell's `.GetNewClosure()` pattern (used in the crossfade fade-out completion, for example) needs rewriting as proper C# lambda captures or event handlers — same idea, different syntax
- Config persistence (whatever format `$script:Config` currently uses) needs a real serialization approach (`System.Text.Json` is the natural fit)
- This is the bulk of the actual work: mechanical but touches every one of the ~2,500 lines of logic

## 4. The Real Cost Is Testing on Actual Windows, Not Writing Code

None of this can be verified without a real Windows machine, a real desktop, real video files, and real hotkey conflicts to test against.

- The WorkerW embedding trick, the crossfade timing, hotkey registration, aspect-ratio letterboxing — these only reveal bugs when actually run on a real Windows desktop with real videos/monitors
- Can't be run or tested in a sandbox environment — requires Windows, WPF, and a real Win32 desktop
- Realistically this dominates the timeline more than the code-writing itself

---

## Rough Sizing

For a solo developer already comfortable with both PowerShell and C#/WPF:

- **~1–2 weeks focused effort** for a working first pass (mechanical port of ~2,500 lines of logic + XAML re-hosting)
- **Additional, harder-to-bound time** for real-machine testing, since it depends on how many edge cases the WorkerW/hotkey/crossfade logic hits in practice

Not a small task, but not a ground-up rewrite either — most of the *design* (XAML layout, styles, the WorkerW approach, the crossfade approach) stays exactly the same; only the *language* changes.

## Bonus: Directly Addresses the Earlier Resource-Usage Findings

This would fix the biggest item from the resource-usage report — the 100–150MB PowerShell/WPF hosting baseline disappears entirely, since a compiled C# app doesn't need to load the PowerShell scripting engine at all. This is the strongest performance argument for doing the conversion, stronger than any of the individual memory fixes discussed separately (preview `DecodePixelWidth`, lazy video pipelines, opt-in preview toggle).
