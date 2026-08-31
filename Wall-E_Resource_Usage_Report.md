# Wall-E — Resource Usage Report

**Observed:** Windows PowerShell (Wall-E) — 1.8% CPU, 312.3 MB Memory, 1.1 MB/s Disk, 0 Mbps Network

**Note:** 1.8% CPU is healthy and not a concern. The finding below is specifically about the 312.3 MB memory figure.

---

## 1. PowerShell Itself Is the Biggest Fixed Cost

Task Manager is showing the whole "Windows PowerShell" process, not a lean native binary. Hosting the PowerShell scripting engine plus the full WPF runtime typically costs 100–150 MB baseline before Wall-E's own code does anything — that's inherent to building on `.ps1` + XAML rather than a compiled C# app (which is how Lively is built). This part isn't a bug, it's the platform choice.

- Not fixable without rewriting the app in compiled C#/.NET instead of PowerShell
- This baseline exists even with zero images/videos loaded

---

## 2. Preview Image Is Decoded at Full Resolution, Not Preview Size

I checked the code: the `BitmapImage` that loads the movie-snapshot preview (around line 810 in `Wall-E.ps1`) never sets `DecodePixelWidth`/`DecodePixelHeight`. That means a 4K screenshot gets fully decoded into memory (~33 MB uncompressed for a single 3840×2160 frame) even though it's displayed in a small preview box that's maybe a few hundred pixels wide.

- Real, fixable inefficiency — not an inherent cost
- Setting `DecodePixelWidth` to match the actual preview control size would cut this dramatically
- The same full-res bitmap is reused for the full-screen view too (that part's already efficient — no double decode)

---

## 3. Two Video Decode Pipelines Are Always Live Once a Video Plays

`VideoWallpaper.ps1` keeps two `MediaElement`s around simultaneously so it can crossfade smoothly between clips — by design, not a bug. But that means two Media Foundation decode pipelines can exist in memory at once, even though only one is visible/audible at any moment.

- Intentional trade-off for the smooth crossfade feature that was built
- Could be made lazier (only spin up the second pipeline right before a crossfade, tear it down after) at the cost of some code complexity
- Only matters when a video wallpaper is actually active — the 1.1 MB/s disk read in the observed snapshot suggests something was being read at that moment

---

## Summary

| # | Cause | Type | Fixable? |
|---|-------|------|----------|
| 1 | PowerShell + WPF runtime overhead | Structural (platform choice) | No — would require rewriting in compiled C#/.NET |
| 2 | Full-resolution preview image decode | Code inefficiency | Yes — set `DecodePixelWidth`/`DecodePixelHeight` |
| 3 | Two always-live video decode pipelines | Structural (design trade-off) | Partially — could be made lazier |

**Bottom line:** 312 MB is not a memory leak or broken behavior — it's mostly baseline PowerShell/WPF overhead plus one concrete, addressable inefficiency (full-resolution preview decoding). A comparable native app (e.g. Lively) would likely sit lower mainly because it isn't paying the PowerShell hosting cost.
