# MacWallpaperEngine Native MVP

Native macOS MVP for the Wallpaper Engine-like runtime.

## Current Scope

- AppKit desktop-level wallpaper windows.
- Metal compositor without WebView.
- Native `wallpaper.native.json` v2 preflight.
- AVFoundation video frames via `AVPlayerItemVideoOutput` and `CVMetalTextureCache`.
- PMA texture draw path using Metal blending.
- Spine setup-pose weighted mesh renderer.
- Spine animation slice for bone `rotate`, `translate`, `translatex`,
  `translatey`, `scale`, `shear`, slot `rgba` and `attachment` timelines.
- Bezier/stepped curve sampling for Spine timelines.
- Weighted mesh deform timeline application for rendered mesh attachments.
- Basic Spine bone inherit handling for `noScale`, `noScaleOrReflection`, and
  `onlyTranslation`.
- First-pass IK, transform, path, and asset-used physics constraint evaluation.
- Reusable native Spine mesh buffers when batch structure is stable.
- Pointer movement and click command mapping.
- Basic frame-time governor with late-frame drop and one in-flight command buffer.
- Pass-through mode for desktop click safety.
- Desktop-empty-only interaction gate so app windows do not trigger wallpaper reactions.
- Control panel foreground switch:
  - `Composite`: verified MP4 composite fallback.
  - `Native Spine`: background video plus native Spine mesh/timeline foreground.

## Not Yet Implemented

- Full Spine 4.2 runtime parity.
- Draw order, clipping attachments, events/audio, sequence attachments, and
  non-mesh region attachment paths. The current Imported asset uses mesh/path only.
- Full official physics parity for all Spine options; current native path covers
  this asset's `x`, `y`, and `rotate` physics constraints.
- Runtime-calibrated region/mesh attachment parity for every action.
- Native Spine click/hold continuity still feels cut off after the input tail
  improvement; keep this as a known issue until Swift renderer parity is
  complete, because action continuity depends on correct pose and constraint
  evaluation.
- Calibrated Imported hit zones.
- CPU/RSS telemetry guard.
- Production-grade frame cache and profiler-backed native Spine optimization.
- Exact Finder desktop icon hit-testing without Accessibility trust.

## Renderer Parity Priority

- Treat `~/project/wall-paper/archive/sample_imported_cleanup_2026-05-13/source_package/sample_imported` as the original Unity package source of truth.
- Keep `Composite` as the user-visible fallback while native parity is incomplete.
- Keep `Native WIP` isolated for renderer work until the character no longer tears.
- Complete Swift renderer reproduction before tuning click action duration:
  remaining draw order, clipping, action continuity, and profiler-backed runtime
  parity checks.

## Run

```bash
cd ~/project/wall-paper/apps/MacWallpaperEngine
swift run MacWallpaperEngine --validate-only
swift run MacWallpaperEngine --duration 20 --display-mode primaryAnimated
swift run MacWallpaperEngine --foreground-mode native --fps 60 --fit-mode contain
```

Packaged app:

```bash
~/project/wall-paper/dist/MacWallpaperEngine.app
```
