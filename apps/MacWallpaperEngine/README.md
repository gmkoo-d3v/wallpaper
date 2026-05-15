# MacWallpaperEngine Native Runtime

Native macOS runtime for Wallpaper Engine-like bundle playback.

## Current Scope

- AppKit desktop-level wallpaper windows.
- Metal compositor without WebView.
- Native `wallpaper.native.json` v2 preflight.
- Manifest `metadata.id` and `metadata.title` for stable library identity.
- Bundle discovery from packaged resources, project wallpapers, and the user
  Application Support wallpaper library.
- `--list-bundles --include-invalid --include-capabilities` diagnostics for
  unsupported or malformed wallpaper folders and validated bundle capability
  summaries.
- `--runtime-capabilities` reports the loaded bundle's manifest features,
  supported runtime paths, fallback paths, and explicit unsupported Spine
  feature classes.
- `--render-plan` reports the effective per-display background video,
  foreground renderer, fallback, interaction path, FPS mode, display refresh,
  and planned render FPS before launching windows.
- CLI display/render plan diagnostics use a headless-safe display snapshot so
  validation commands do not trigger AppKit application registration.
- Display/render plans include a macOS display id plus a hashed fallback
  fingerprint and arrangement hash so reconnect or display-order drift can be
  diagnosed.
- `--primary-display` can pin the runtime's primary display using a display id,
  fallback fingerprint, arrangement hash, or display name selector.
- Control panel library diagnostics show invalid wallpaper folders without
  hiding valid bundles.
- Bundle discovery reports duplicate `metadata.id` entries in diagnostics
  instead of silently hiding imported or project-local bundles.
- Control panel bundle library shows selected bundle metadata and preview art
  from `preview.jpg` or a declared `staticImage` asset.
- Control panel bundle library surfaces asset/layer/interaction/native-fallback
  capabilities before the user starts a selected bundle.
- Bundle library and `--list-bundles --include-capabilities` summaries flag
  low-FPS composite fallback quality before the user selects or starts a bundle.
- Control panel render diagnostics show the same per-display background,
  foreground, fallback, interaction, FPS, and display-refresh path exposed by
  `--render-plan`.
- `--interaction-plan` reports pointer movement commands, accepted click
  buttons, hit zones, effective animation-synchronized tail timing, and
  left/right click probes from the same interaction planner used by the
  renderer.
- `--spine-animation-plan` reports Spine animation duration, timeline coverage,
  native timeline compatibility per manifest action, and whether every manifest
  interaction action resolves to a real animation.
- `--spine-animation-plan` also samples native Spine renderer geometry for every
  manifest action, proving that setup/animated poses produce drawable batches
  with finite positions and in-range UVs.
- Control panel display settings expose the same primary display selector used
  by `--primary-display`, preserving configured selectors even when a display is
  temporarily disconnected.
- Control panel bundle, display, interaction, FPS, playback, fit, and foreground
  renderer selections persist under Application Support and are restored on the
  next normal app launch unless an explicit CLI flag overrides them.
- Validation, self-test, capability, display-plan, render-plan, and performance
  diagnostics ignore persisted user settings so package/build checks remain
  reproducible.
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
- Pointer smoothing advances on render snapshots, not only on macOS mouse
  events, so look-direction commands keep converging after the cursor stops.
- Manifest-driven tap/hold action continuity for Spine interaction actions.
- Shared interaction plan for deterministic hit-zone, button, and
  look-direction diagnostics.
- Frame-time, CPU, RSS, and thermal governor with manifest-bounded in-flight command buffers.
- Low Power Mode and battery-power detection clamp rendering to the manifest
  fallback FPS and expose the active policy in runtime telemetry.
- Frame/drop telemetry snapshot for submitted frames, skipped frames, last skip
  reason, actual FPS, and p95 frame time.
- Runtime telemetry is aggregated per display and surfaced in the control panel.
- Resource-budget pressure lowers FPS without silently replacing native Spine
  with composite video, preserving the selected foreground renderer.
- Native Spine compatibility gate falls back to `compositeVideo` when a bundle
  uses Spine feature classes the native renderer does not implement yet.
- Runtime capability diagnostics report video/composite size, duration,
  playback rate, and effective FPS; low-FPS composite fallback is flagged so it
  can be regenerated at the display refresh rate instead of being mistaken for
  a renderer bug.
- FPS policy exposes fixed `30`, fixed `60`, and `Display Hz` refresh matching;
  legacy values above 60 are treated as display-refresh mode instead of fixed
  120fps.
- Composite fallback quality diagnostics can emit a regeneration plan and can
  run as a strict validation gate for release/package workflows that require
  fallback FPS to meet the manifest target.
- Packaging validates each source bundle and the copied `.app` resource bundle;
  set `STRICT_COMPOSITE_QUALITY=1` to make package validation reject low-FPS
  composite fallbacks.
- Manifest/package validation rejects unsupported native Spine bundles that do
  not provide a `compositeVideo` fallback.
- Debounced atomic display rebuild policy absorbs hot-plug notification bursts
  and keeps the previous wallpaper windows alive if a rebuild fails partway
  through.
- Window visibility loss from occlusion or fullscreen-obscured states pauses
  rendering when the manifest display policy requests `pause`.
- Desktop interaction monitors are suspended whenever the wallpaper window is
  not visible, and remain disabled for passive secondary displays.
- Display mode labels distinguish `Primary+Policy` from `Primary Only` so
  secondary-display background behavior is not hidden behind an ambiguous
  "primary" label.
- Startup host failures keep the control panel open when UI is available so
  users can choose another bundle instead of watching the app silently exit.
- Pass-through mode for desktop click safety.
- Desktop-empty-only interaction gate so app windows do not trigger wallpaper reactions.
- Desktop icon hit-testing fails closed without Accessibility trust when
  `blockDesktopItems` is enabled, instead of letting wallpaper reactions leak
  over Finder desktop items.
- When desktop-item hit-testing needs Accessibility trust, the runtime requests
  the macOS Accessibility permission prompt and exposes the current trust state
  in capability diagnostics.
- Control panel foreground switch:
  - `Auto`: native Spine when the selected bundle supports it, otherwise the composite fallback.
  - `Composite`: verified MP4 composite fallback.
  - `Native Spine`: background video plus native Spine mesh/timeline foreground.
- Foreground renderer selection is centralized so render diagnostics and the
  Metal compositor use the same native/composite/fallback decision.

## Not Yet Implemented

- Full Spine 4.2 runtime parity.
- Events/audio, sequence attachments, and non-region non-mesh attachment paths.
  The current Imported asset uses mesh/path/region/clipping-compatible paths.
- Full official physics parity for all Spine options; current native path covers
  this asset's `x`, `y`, and `rotate` physics constraints.
- Runtime-calibrated region/mesh attachment parity for every action.
- Calibrated Imported hit zones.
- Production-grade frame cache and profiler-backed native Spine optimization.
- Exact Finder desktop icon hit-testing without disabling interaction when
  Accessibility trust is unavailable.

## Renderer Parity Priority

- Treat `~/project/wall-paper/archive/sample_imported_cleanup_2026-05-13/source_package/sample_imported` as the original Unity package source of truth.
- Keep `Auto` as the default user-visible path: prefer native Spine when the
  selected bundle is compatible, then use `Composite` only when native Spine is
  unsupported for that bundle.
- Keep `Native Spine` isolated from video/composite renderer policy: use the
  original Spine JSON, atlas UVs, placement, timeline, and constraint data as
  the source of truth for image assembly.
- Complete Swift renderer reproduction before tuning click action duration:
  remaining profiler-backed runtime parity checks, calibrated interaction
  curves, and wider wallpaper fixture coverage.

## Run

```bash
cd ~/project/wall-paper/apps/MacWallpaperEngine
swift run MacWallpaperEngine --validate-only
swift run MacWallpaperEngine --runtime-capabilities
swift run MacWallpaperEngine --composite-quality-plan
swift run MacWallpaperEngine --validate-only --strict-composite-quality
swift run MacWallpaperEngine --render-plan --foreground-mode native --display-mode all
swift run MacWallpaperEngine --render-plan --foreground-mode auto --display-mode primaryAnimated
swift run MacWallpaperEngine --render-plan --primary-display fingerprint:<hash>
swift run MacWallpaperEngine --interaction-plan
swift run MacWallpaperEngine --spine-animation-plan
swift run MacWallpaperEngine --list-bundles --include-capabilities
swift run MacWallpaperEngine --duration 20 --display-mode primaryAnimated
swift run MacWallpaperEngine --foreground-mode native --fps 60 --fit-mode contain
swift run MacWallpaperEngine --foreground-mode native --fps display
```

Packaged app:

```bash
~/project/wall-paper/dist/MacWallpaperEngine.app
```
