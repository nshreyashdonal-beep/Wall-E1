# Wall-E — Proposed Fix: Make In-App Video Preview Opt-In

## The Problem

In `Wall-E.ps1`, `Update-PreviewDisplay` runs this every time a video file is selected/navigated to:

```powershell
$VidPreview.Stop()
$VidPreview.Source = New-Object System.Uri($imgFile.FullName)
$VidPreview.Visibility = 'Visible'
$VidPreview.Play()
```

The code's own comment confirms what this is:

> "A second, independent playback of the same file — separate from (and not frame-synced with) the copy actually playing on the desktop."

So whenever a video is selected, **two full video decode pipelines can run simultaneously and continuously**:

1. The real desktop wallpaper copy (`VideoWallpaper.ps1`)
2. The in-app `VidPreview` — just so you can see it inside the app window

This is different from the crossfade cost discussed earlier. Crossfade's second pipeline only exists for ~700ms during a transition. `VidPreview` runs for the **entire time** a video is selected — a sustained cost, not a brief spike.

## The Proposed Solution

Add a **"Show Preview" toggle**, off by default:

- **Toggle OFF (default):** Don't load or play anything into `VidPreview`/`ImgPreview`. Show a lightweight filler/placeholder instead (e.g. an icon + "Preview hidden" text). Folder name and image/video info text still update normally — only the heavy decode work is skipped.
- **Toggle ON:** Behaves exactly as it does today — loads and plays the current item's in-app preview.

## Why This Helps

- Eliminates a **sustained**, continuously-running decode pipeline for anyone who doesn't need to visually confirm the preview inside the app (since the actual wallpaper is already visible on the desktop behind it).
- No feature is lost — it becomes opt-in rather than always-on.
- Complements (doesn't replace) the earlier `DecodePixelWidth` fix for the image preview, which addresses a different inefficiency (full-resolution decode of a small preview image).

## Where It Would Touch the Code

| File | Change |
|---|---|
| `UI/MainWindow.xaml` | Add a `CheckBox` ("Show Preview", unchecked by default) and a filler `Panel`/`Border` placeholder inside `PreviewHostGrid`, alongside `ImgPreview` / `VidPreview` / `PnlVideoBadge`. |
| `Wall-E.ps1` | In `Update-PreviewDisplay`: check the toggle state first. If off, skip the `BitmapImage`/`VidPreview` loading entirely, update only the text fields, and show the filler panel. Add `Checked`/`Unchecked` event handlers on the toggle to load or tear down the preview on demand. |

## Status

**Not yet implemented** — this file documents the proposed approach only, pending a decision to proceed.
