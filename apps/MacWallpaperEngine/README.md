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
- `--list-bundles` emits a structured bundle-list report with valid/invalid
  counts and stable columns, so shell tooling and users can inspect the same
  library state.
- `--validate-bundles` runs manifest, capability, render-plan, simulated
  primaryOnly/selected+policy/all-full display planning, composite quality, and
  native Spine geometry preflight over every discovered valid bundle without
  launching wallpaper windows.
- Bundle validation also checks simulated Display Hz mode, proving 120Hz
  primary and 60Hz secondary display FPS planning without depending on the
  current physical monitor layout.
- Bundle validation exercises interaction diagnostics for every discovered
  bundle, proving active desktop-gated hit-zone/click timelines for interactive
  bundles and passive no-interaction behavior for video/static samples.
- Bundle validation checks each manifest performance budget plan, including
  downgrade ladders, power-saving fallback FPS, telemetry fields, and
  display-refresh 120Hz planning.
- Bundle validation also checks the bundle library list report, so discovery
  counts, invalid diagnostics, stable columns, and capability rows stay aligned
  with the control panel library picker and `--list-bundles`.
- Bundle validation imports each discovered valid bundle into a temporary user
  library, re-discovers it, and reloads the installed copy so user import/install
  paths are covered by the same release matrix.
- `--validate-bundles` also runs bundle-local `golden/wallpaper.golden.json`
  fixtures when present, so packaged sample static/video/native-Spine bundles
  prove renderer output instead of only manifest validity.
- `--bundle-library <path>` lets `--list-bundles` and `--validate-bundles`
  target a specific imported bundle library instead of default locations.
- `--runtime-capabilities` reports the loaded bundle's manifest features,
  supported runtime paths, fallback paths, and explicit unsupported Spine
  feature classes.
- Runtime capability diagnostics mark the native Spine renderer itself as
  unsupported when the compatibility gate requires a composite fallback, so
  bundle authors can distinguish "renderer exists" from "this bundle can use
  it".
- `--render-plan` reports the effective per-display background video,
  foreground renderer, fallback, interaction path, FPS mode, display refresh,
  and planned render FPS before launching windows.
- `--simulated-render-plan` reports the same renderer plan against a
  deterministic three-display fixture so selected-only, selected+policy, and
  all-full behavior can be checked without the real monitor layout.
- CLI display/render plan diagnostics use a headless-safe display snapshot so
  validation commands do not trigger AppKit application registration.
- Display/render plans include a macOS display id plus a hashed fallback
  fingerprint and arrangement hash so reconnect or display-order drift can be
  diagnosed.
- `--primary-display` can pin the runtime's primary display using a display id,
  fallback fingerprint, arrangement hash, or display name selector.
- Control panel library diagnostics show invalid wallpaper folders without
  hiding valid bundles.
- Packaged resources include the Imported native Spine/video sample, a minimal
  `sample_video` video-only bundle, and a minimal `sample_static` image-only
  bundle, so discovery, validation, and packaging exercise multiple wallpaper
  renderer families.
- Bundle discovery reports duplicate `metadata.id` entries in diagnostics
  instead of silently hiding imported or project-local bundles.
- Control panel bundle library shows selected bundle metadata and preview art
  from `preview.jpg` or a declared `staticImage` asset.
- Control panel bundle library surfaces asset/layer/interaction permission/native-fallback
  capabilities before the user starts a selected bundle.
- Bundle library and `--list-bundles --include-capabilities` summaries flag
  low-FPS composite fallback quality before the user selects or starts a bundle.
- Control panel render diagnostics show the same per-display background,
  foreground, fallback, interaction, FPS, and display-refresh path exposed by
  `--render-plan`.
- `--interaction-plan` reports pointer movement commands, accepted click
  buttons, hit zones, pointerDown default actions, effective
  animation-synchronized tail timing, and left/right click probes from the same
  interaction planner used by the renderer.
- `--interaction-plan` reports the effective pointerMove neutral point and
  dead-zone used by both the interaction planner and native Spine look blending.
- `--interaction-plan` also reports event-gate decisions for empty desktop,
  missing Accessibility trust, covering application windows, and Finder desktop
  items so blocked live clicks have a matching CLI diagnosis.
- In the current native-metal manifest, declared pointer interactions require a
  Spine asset because interaction actions resolve to native Spine animations;
  video-only and static-image bundles must remain passive.
- `--interaction-plan` also emits deterministic click timelines for tap and
  hold actions, making command hold duration and post-click look-direction
  resume behavior visible without launching desktop windows.
- `--interaction-plan` probes content-to-window coordinate round trips across
  16:9, 21:9, and 32:9 display aspects so contain/fill hit-zone drift can be
  diagnosed without moving real desktop windows.
- `--interaction-debug-overlay` and the control panel debug toggle draw
  pointer/hit-zone diagnostics over the wallpaper so bundle click regions can
  be verified on the live desktop.
- `--spine-animation-plan` reports Spine animation duration, timeline coverage,
  native timeline compatibility per manifest action, and whether every manifest
  interaction action resolves to a real animation.
- `--spine-animation-plan` also samples native Spine renderer geometry across
  timeline keyframes, discrete attachment/draw-order transitions, runtime
  frame-cadence poses, and partial look-direction pose mixes for every manifest
  action, proving that setup/animated pointer poses produce drawable batches
  with finite positions and in-range UVs.
- Native Spine geometry diagnostics include deterministic pose fingerprints
  derived from blend modes, vertices, UVs, and colors so renderer changes can be
  compared before full image-diff golden fixtures are available.
- `--spine-snapshot` writes a deterministic native Spine foreground PNG on a
  white diagnostic background for action/time/size-specific renderer review.
- `--wallpaper-snapshot` writes a full diagnostic wallpaper PNG using sampled
  video/composite/static background, the selected fit mode, native Spine when
  active, and optional reference PNG diff metrics.
- `--wallpaper-golden-check` loads bundle-local
  `golden/wallpaper.golden.json` fixtures, renders each snapshot through the
  same full wallpaper diagnostic path, and fails when configured pixel
  thresholds are exceeded.
- `--interaction-plan` probes pointer-move commands, hit-zone/default-action
  resolution, and click command hold/tap state for every declared pointerDown
  path.
- Manifest validation rejects same-button overlapping pointerDown hit zones
  because explicit hit-zone priority is not yet part of the bundle schema.
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
  manifest validation, symlink rejection, duplicate-id protection, and self-tested
  library rediscovery.
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
- Same-skin Spine `linkedmesh` attachments resolve to their parent mesh
  geometry for native rendering; missing-parent or external-skin linked meshes
  are blocked by compatibility diagnostics.
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
- Bounded native Spine pose-frame cache for repeated quantized animation frames,
  capped by entry count and memory budget to avoid unbounded RSS growth.
- Pointer movement and click command mapping.
- Pointer smoothing advances on render snapshots, not only on macOS mouse
  events, so look-direction commands keep converging after the cursor stops.
- Pointer smoothing is normalized against a 60Hz reference cadence, so fixed
  30/60 FPS and Display Hz rendering converge at the same real-time speed
  instead of making look-direction response depend on monitor refresh.
- Native Spine look-direction poses are mixed by smoothed pointer distance from
  the idle dead zone, avoiding abrupt full-strength directional pose snaps.
- Manifest-driven tap/hold action continuity for Spine interaction actions.
- Non-visual Spine event timelines are tolerated and ignored by the native
  renderer instead of forcing a composite fallback; audio events and sequence
  attachments remain explicit unsupported feature gates.
- Shared interaction plan for deterministic hit-zone, default-action, button, and
  look-direction diagnostics.
- Interaction hit testing resolves the wallpaper content aspect from Spine
  placement, video metadata, composite video metadata, or static image metadata
  instead of assuming every bundle is 16:9.
- Frame-time, CPU, RSS, and thermal governor with manifest-bounded in-flight command buffers.
- Low Power Mode and battery-power detection clamp rendering to the manifest
  fallback FPS and expose the active policy in runtime telemetry.
- Frame/drop telemetry snapshot for submitted frames, skipped frames, last skip
  reason, actual FPS, and p95 frame time.
- Runtime telemetry is aggregated per display and surfaced in the control panel.
- Desktop interaction telemetry reports whether the mouse monitor is active,
  whether the CGEvent tap is installed, the last delivered or blocked click
  path, the current interaction command/pulse, and delivered/blocked event
  counts for live desktop debugging.
- Desktop-level wallpaper windows remain mouse-passive and drive interactions
  through passive NSEvent/CGEvent monitoring, while plain diagnostic windows can
  still record direct NSResponder delivery for local click debugging.
- Resource-budget pressure lowers FPS without silently replacing native Spine
  with composite video, preserving the selected foreground renderer.
- Runtime self-test injects deterministic CPU/RSS samples into the governor to
  prove sustained CPU downgrade, RSS target fallback, and RSS hard-limit pause
  behavior without relying on the current machine load.
- Native Spine compatibility gate falls back to `compositeVideo` when a bundle
  uses Spine feature classes the native renderer does not implement yet.
- Runtime capability diagnostics report video/composite size, duration,
  playback rate, and effective FPS; low-FPS composite fallback is flagged so it
  can be regenerated at the display refresh rate instead of being mistaken for
  a renderer bug.
- `--validate-only` runs native Spine geometry preflight for supported Spine
  bundles, so package/release validation fails before shipping broken action
  pose assembly or out-of-range UVs.
- FPS policy exposes fixed `30`, fixed `60`, and `Display Hz` refresh matching;
  legacy values above 60 are treated as display-refresh mode instead of fixed
  120fps.
- Composite fallback quality diagnostics can emit a regeneration plan and can
  run as a strict validation gate for release/package workflows that require
  fallback FPS to meet the manifest target.
- `--export-composite-video` renders a native/source composite MP4 fallback at
  a chosen FPS, duration, and snapshot size so low-FPS fallback debt can be
  regenerated instead of hand-authored.
- Packaging validates each source bundle and the copied `.app` resource bundle;
  set `STRICT_COMPOSITE_QUALITY=1` or `true` to make package validation reject
  low-FPS composite fallbacks.
- Packaging prints composite fallback quality warnings even when strict mode is
  disabled, so release builds do not hide low-FPS fallback debt.
- `PACKAGE_VALIDATE_ONLY=1` runs the same source-bundle package validation
  without replacing the existing `dist/MacWallpaperEngine.app`.
- Strict packaging prints the composite quality report before failing, so the
  rejected bundle includes an actionable regeneration target in the build log.
- Manifest/package validation rejects unsupported native Spine bundles that do
  not provide a `compositeVideo` fallback.
- Debounced atomic display rebuild policy absorbs hot-plug notification bursts
  and keeps the previous wallpaper windows alive if a rebuild fails partway
  through.
- A transient zero-window rebuild result during a running host is treated as a
  rollback condition, so monitor reconnect churn cannot replace a live wallpaper
  set with an empty one.
- Window visibility loss from occlusion or fullscreen-obscured states pauses
  rendering when the manifest display policy requests `pause`.
- Desktop interaction monitors are suspended whenever the wallpaper window is
  not visible, and remain disabled for passive secondary displays.
- Display mode defaults to `Selected Only`; `Selected+Policy` must be chosen
  explicitly before secondary displays receive the manifest secondary
  background policy.
- Startup host failures keep the control panel open when UI is available so
  users can choose another bundle instead of watching the app silently exit.
- Pass-through mode for desktop click safety.
- Desktop-empty-only interaction gate so app windows do not trigger wallpaper reactions.
- The interaction gate ignores the wallpaper host window itself but still treats
  the control panel and other same-process UI windows as covering application
  windows, so UI clicks do not leak into the wallpaper.
- Desktop interaction eligibility is centralized and self-tested for application
  window, desktop item, disabled mode, and missing Accessibility trust cases.
- Desktop icon hit-testing fails closed without Accessibility trust when
  `blockDesktopItems` is enabled, instead of letting wallpaper reactions leak
  over Finder desktop items.
- The bundled Imported sample keeps `blockDesktopItems=true` so Finder desktop
  icons remain protected; click reaction requires macOS Accessibility trust,
  app-window blocking remains enabled, desktop wallpaper windows stay
  mouse-passive, passive monitors provide click delivery, and passive secondary
  windows stay mouse-passive.
- `desktop-empty-only` bundles that do not block Finder desktop items route
  direct NSResponder mouse events only in plain diagnostic windows; desktop
  wallpaper windows preserve pass-through click ownership.
- Passive wallpaper click delivery deduplicates near-simultaneous event-tap and
  global-monitor clicks while leaving pointer tracking at the 30Hz move cap.
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
- Audio event playback, sequence attachments, and non-region non-mesh attachment paths.
  The current Imported asset uses mesh/path/region/clipping-compatible paths.
- Full official physics parity for all Spine options; current native path covers
  this asset's `x`, `y`, and `rotate` physics constraints.
- Visual hit-zone editor for authoring new bundles.
- Profiler-backed native Spine optimization beyond the bounded pose-frame cache.
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
swift run MacWallpaperEngine --export-composite-video /tmp/imported-composite-60fps.mp4 --export-composite-fps 60 --snapshot-size 1280x720
swift run MacWallpaperEngine --validate-only --strict-composite-quality
swift run MacWallpaperEngine --render-plan --foreground-mode native --display-mode all
swift run MacWallpaperEngine --render-plan --foreground-mode auto --display-mode primaryAnimated
swift run MacWallpaperEngine --render-plan --primary-display fingerprint:<hash>
swift run MacWallpaperEngine --simulated-render-plan --display-mode primaryOnly
swift run MacWallpaperEngine --simulated-render-plan --display-mode primaryAnimated
swift run MacWallpaperEngine --simulated-render-plan --display-mode all
swift run MacWallpaperEngine --validate-bundles
swift run MacWallpaperEngine --validate-bundles --bundle-library /path/to/wallpapers
swift run MacWallpaperEngine --interaction-plan
swift run MacWallpaperEngine --foreground-mode native --interaction-debug-overlay
swift run MacWallpaperEngine --spine-animation-plan
swift run MacWallpaperEngine --wallpaper-golden-check
swift run MacWallpaperEngine --list-bundles --include-capabilities
swift run MacWallpaperEngine --list-bundles --bundle-library /path/to/wallpapers --include-capabilities
swift run MacWallpaperEngine --duration 20 --display-mode primaryAnimated
swift run MacWallpaperEngine --foreground-mode native --fps 60 --fit-mode contain
swift run MacWallpaperEngine --foreground-mode native --fps display
```

Packaged app:

```bash
~/project/wall-paper/dist/MacWallpaperEngine.app
```
