# MacWallpaperEngine Native Runtime

Native macOS runtime for Wallpaper Engine-like bundle playback.

## Current Scope

- AppKit desktop-level wallpaper windows.
- Metal compositor without WebView.
- Native `wallpaper.native.json` v2 preflight.
- Manifest `metadata.id` and `metadata.title` for stable library identity.
- Bundle discovery from packaged resources, project wallpapers, and the user
  Application Support wallpaper library.
- `--list-bundles --include-invalid` diagnostics for unsupported or malformed
  wallpaper folders.
- `--runtime-capabilities` reports the loaded bundle's manifest features,
  supported runtime paths, fallback paths, and explicit unsupported Spine
  feature classes.
- Control panel library diagnostics show invalid wallpaper folders without
  hiding valid bundles.
- Control panel bundle library shows selected bundle metadata and preview art
  from `preview.jpg` or a declared `staticImage` asset.
- Bundle import into the user Application Support wallpaper library with
  manifest validation and symlink rejection.
- Video-only wallpaper bundles are covered by runtime self-test so the runtime
  does not require a Imported-style Spine layer for every bundle.
- Static image wallpaper bundles can declare a manifest `static_image` layer
  instead of relying on an implicit preview fallback.
- Manifests that use a `static` display policy must include `preview.jpg` so
  static displays have a validated fallback image, unless they declare a
  `staticImage` asset.
- AVFoundation video frames via `AVPlayerItemVideoOutput` and `CVMetalTextureCache`.
- PMA texture draw path using Metal blending.
- Spine setup-pose weighted mesh renderer.
- Spine animation slice for bone `rotate`, `translate`, `translatex`,
  `translatey`, `scale`, `shear`, slot `rgba` and `attachment` timelines.
- Bezier/stepped curve sampling for Spine timelines.
- Spine draw order timeline application.
- Spine clipping attachment CPU triangle clipping.
- Weighted mesh deform timeline application for rendered mesh attachments.
- Basic Spine bone inherit handling for `noScale`, `noScaleOrReflection`, and
  `onlyTranslation`.
- First-pass IK, transform, path, and asset-used physics constraint evaluation.
- Reusable native Spine mesh buffers when batch structure is stable.
- Pointer movement and click command mapping.
- Manifest-driven tap/hold action continuity for Spine interaction actions.
- Frame-time, CPU, RSS, and thermal governor with manifest-bounded in-flight command buffers.
- Low Power Mode and battery-power detection clamp rendering to the manifest
  fallback FPS and expose the active policy in runtime telemetry.
- Frame/drop telemetry snapshot for submitted frames, skipped frames, last skip
  reason, actual FPS, and p95 frame time.
- Runtime telemetry is aggregated per display and surfaced in the control panel.
- Resource-budget fallback from native Spine to composite video when the
  downgrade ladder is exhausted and a composite asset exists.
- Atomic display rebuild policy keeps the previous wallpaper windows alive if
  a hot-plug/display rebuild fails partway through.
- Window visibility loss from occlusion or fullscreen-obscured states pauses
  rendering when the manifest display policy requests `pause`.
- Startup host failures keep the control panel open when UI is available so
  users can choose another bundle instead of watching the app silently exit.
- Pass-through mode for desktop click safety.
- Desktop-empty-only interaction gate so app windows do not trigger wallpaper reactions.
- Control panel foreground switch:
  - `Composite`: verified MP4 composite fallback.
  - `Native Spine`: background video plus native Spine mesh/timeline foreground.

## Not Yet Implemented

- Full Spine 4.2 runtime parity.
- Events/audio, sequence attachments, and non-region non-mesh attachment paths.
  The current Imported asset uses mesh/path/region/clipping-compatible paths.
- Full official physics parity for all Spine options; current native path covers
  this asset's `x`, `y`, and `rotate` physics constraints.
- Runtime-calibrated region/mesh attachment parity for every action.
- Calibrated Imported hit zones.
- Production-grade frame cache and profiler-backed native Spine optimization.
- Exact Finder desktop icon hit-testing without Accessibility trust.

## Renderer Parity Priority

- Treat `~/project/wall-paper/archive/sample_imported_cleanup_2026-05-13/source_package/sample_imported` as the original Unity package source of truth.
- Keep `Composite` as the user-visible fallback while native parity is incomplete.
- Keep `Native Spine` as the renderer parity track until the character no longer tears.
- Complete Swift renderer reproduction before tuning click action duration:
  remaining profiler-backed runtime parity checks and wider wallpaper fixture
  coverage.

## Run

```bash
cd ~/project/wall-paper/apps/MacWallpaperEngine
swift run MacWallpaperEngine --validate-only
swift run MacWallpaperEngine --runtime-capabilities
swift run MacWallpaperEngine --duration 20 --display-mode primaryAnimated
swift run MacWallpaperEngine --foreground-mode native --fps 60 --fit-mode contain
```

Packaged app:

```bash
~/project/wall-paper/dist/MacWallpaperEngine.app
```
