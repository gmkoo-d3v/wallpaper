import CoreGraphics
import Foundation

enum RuntimeSelfTest {
    static func run(runtime: NativeRuntimeCore) throws -> String {
        var failures: [String] = []
        var checks = 0

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if condition() == false {
                failures.append(message)
            }
        }

        let manifest = runtime.manifest
        let plan = runtime.performancePlan

        check(plan.maxFps >= 1, "maxFps must be positive")
        check(plan.fallbackFps >= 1, "fallbackFps must be positive")
        check(plan.fallbackFps <= plan.maxFps, "fallbackFps must not exceed maxFps")
        check(plan.effectiveTargetFps >= plan.fallbackFps, "effectiveTargetFps must not be lower than fallbackFps")
        check(plan.effectiveTargetFps <= plan.maxFps, "effectiveTargetFps must not exceed maxFps")
        check(plan.downgradeFpsLadder.first == plan.effectiveTargetFps, "downgrade ladder must start at effective target FPS")
        check(plan.downgradeFpsLadder.last == plan.fallbackFps, "downgrade ladder must end at fallback FPS")
        check(plan.downgradeFpsLadder == plan.downgradeFpsLadder.sorted(by: >), "downgrade ladder must be descending")
        check(Set(plan.downgradeFpsLadder).count == plan.downgradeFpsLadder.count, "downgrade ladder must not contain duplicates")
        check(plan.maxInFlightCommandBuffers >= 1, "scheduler must allow at least one in-flight command buffer")
        check(plan.maxInFlightCommandBuffers <= 3, "scheduler must cap in-flight command buffers to prevent queue buildup")
        check(plan.cpuTargetPercent > 0, "CPU target percent must be positive")
        check(plan.cpuDowngradePercent >= plan.cpuTargetPercent, "CPU downgrade threshold must not be below target")
        check(plan.rssHardMb >= plan.rssTargetMb, "RSS hard limit must not be below target")

        let lowPlan = PerformancePlan.make(manifest: manifest, requestedFps: 1)
        check(lowPlan.effectiveTargetFps == lowPlan.fallbackFps, "low requested FPS should clamp to fallback FPS")

        let highPlan = PerformancePlan.make(manifest: manifest, requestedFps: manifest.runtime.maxFps * 2)
        check(highPlan.effectiveTargetFps == highPlan.maxFps, "high requested FPS should clamp to max FPS")
        check(
            highPlan.summary().contains("exhaustedBudgetFallback: video-only when available"),
            "performance plan must document exhausted-budget video-only fallback"
        )
        check(highPlan.summary().contains("telemetryFields: currentFps"), "performance plan must document runtime telemetry fields")
        check(DisplayPlanner.rebuildPolicy == "atomic-rollback", "display rebuild policy must preserve old windows until replacement succeeds")
        check(RuntimeLifecyclePolicy.startupFailurePolicy == "control-panel-recovery", "startup host failures must have an explicit recovery policy")
        check(
            RuntimeLifecyclePolicy.visibilityPausePolicy == "pause-when-occluded-or-fullscreen-obscured",
            "window visibility pause policy must be explicit"
        )
        check(
            ControlPanelWindowController.displayModeLabels == ["Primary+Policy", "All Full", "Primary Only"],
            "control panel display mode labels must distinguish secondary policy from primary-only"
        )
        check(
            RuntimeLifecyclePolicy.shouldRecoverStartupFailureInControlPanel(launchControlPanel: true),
            "startup host failures must surface in the control panel when UI is available"
        )
        check(
            RuntimeLifecyclePolicy.shouldRecoverStartupFailureInControlPanel(launchControlPanel: false) == false,
            "wallpaper-only startup failures must not create recovery UI unexpectedly"
        )
        checkVisibilityPolicy(failures: &failures, checks: &checks)

        checkResourceGovernorTelemetry(runtime: runtime, failures: &failures, checks: &checks)

        let primaryRole = DisplayPlanner.role(
            isPrimary: true,
            displayMode: runtime.config.displayMode,
            manifest: manifest
        )
        checkRole(primaryRole, policy: manifest.displayPolicy.primary, kind: "primary", failures: &failures, checks: &checks)

        let secondaryRole = DisplayPlanner.role(
            isPrimary: false,
            displayMode: .primaryAnimated,
            manifest: manifest
        )
        checkRole(secondaryRole, policy: manifest.displayPolicy.secondary, kind: "secondary", failures: &failures, checks: &checks)

        let allSecondaryRole = DisplayPlanner.role(
            isPrimary: false,
            displayMode: .all,
            manifest: manifest
        )
        check(allSecondaryRole?.policy == .full, "displayMode=all must render secondary displays with full policy")
        check(allSecondaryRole?.allowsInteraction == false, "secondary displays must not allow desktop interaction")

        let primaryOnlySecondaryRole = DisplayPlanner.role(
            isPrimary: false,
            displayMode: .primaryOnly,
            manifest: manifest
        )
        check(primaryOnlySecondaryRole == nil, "displayMode=primaryOnly must not create secondary display roles")

        let validatedBundle = WallpaperBundleCatalog.validateBundle(runtime.config.wallpaperRoot)
        check(validatedBundle != nil, "active wallpaper bundle must pass catalog validation")
        check(
            validatedBundle?.capabilities.nativeSpineStatus == "supported",
            "bundle catalog must expose native Spine support status"
        )
        check(
            validatedBundle?.capabilities.briefText.contains("fallback: composite-ready") == true,
            "bundle catalog must expose composite fallback readiness"
        )
        let capabilitySummary = runtime.runtimeCapabilitiesSummary()
        check(
            capabilitySummary.contains("runtime capabilities"),
            "runtime capabilities summary must expose a stable CLI header"
        )
        check(
            capabilitySummary.contains("columns: category\tname\tstatus\tdetail"),
            "runtime capabilities summary must expose tabular columns"
        )
        check(
            capabilitySummary.contains("interaction\tpointerMove/lookDirection"),
            "runtime capabilities summary must report pointer movement support"
        )
        check(
            capabilitySummary.contains("head:act trigger=tap buttons=left"),
            "runtime capabilities summary must expose pointerDown hit-zone actions and buttons"
        )
        check(
            capabilitySummary.contains("spine\tattachments"),
            "runtime capabilities summary must report Spine attachment compatibility"
        )
        check(
            capabilitySummary.contains("spine\tnativeCompatibilityGate"),
            "runtime capabilities summary must expose the native Spine compatibility gate"
        )
        check(
            RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime).isSupported,
            "active bundle must pass native Spine compatibility gate"
        )
        let interactionPlan = InteractionPlan(
            interactions: manifest.interactions,
            policy: manifest.interactionPolicy
        )
        check(
            interactionPlan.command(for: CGPoint(x: 0.10, y: 0.50), previousCommand: "idle") == "Left",
            "interaction plan must resolve left pointer movement"
        )
        check(
            interactionPlan.command(for: CGPoint(x: 0.50, y: 0.50), previousCommand: "Right") == "idle",
            "interaction plan must honor idle dead zone"
        )
        let headHit = interactionPlan.hitTest(point: CGPoint(x: 0.50, y: 0.30), button: .left)
        check(
            headHit?.zoneID == "head" && headHit?.action == "act" && headHit?.trigger == .tap,
            "interaction plan must resolve Imported head left-click tap action"
        )
        let bodyHit = interactionPlan.hitTest(point: CGPoint(x: 0.50, y: 0.70), button: .left)
        check(
            bodyHit?.zoneID == "body" && bodyHit?.action == "boll" && bodyHit?.trigger == .hold,
            "interaction plan must resolve Imported body left-click hold action"
        )
        check(
            interactionPlan.hitTest(point: CGPoint(x: 0.50, y: 0.30), button: .right) == nil,
            "interaction plan must reject right-click when the manifest declares left-click hit zones"
        )
        let syntheticDisplay = DisplayIdentityDescriptor(
            name: "LG ULTRAFINE",
            displayID: 42,
            fingerprint: "abc123",
            arrangement: "arr789"
        )
        check(
            DisplayPlanner.primarySelectorMatches("displayID:42", descriptor: syntheticDisplay),
            "primary display selector must match explicit displayID"
        )
        check(
            DisplayPlanner.primarySelectorMatches("42", descriptor: syntheticDisplay),
            "primary display selector must match raw displayID"
        )
        check(
            DisplayPlanner.primarySelectorMatches("fingerprint:abc123", descriptor: syntheticDisplay),
            "primary display selector must match explicit fallback fingerprint"
        )
        check(
            DisplayPlanner.primarySelectorMatches("arrangement:arr789", descriptor: syntheticDisplay),
            "primary display selector must match explicit arrangement hash"
        )
        check(
            DisplayPlanner.primarySelectorMatches("name:lg ultrafine", descriptor: syntheticDisplay),
            "primary display selector must match explicit display name"
        )
        check(
            DisplayPlanner.primarySelectorMatches("displayID:7", descriptor: syntheticDisplay) == false,
            "primary display selector must reject non-matching displayID"
        )
        let parsedPrimaryOverride = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--primary-display", "fingerprint:abc123",
            "--validate-only"
        ])
        check(
            parsedPrimaryOverride.primaryDisplaySelector == "fingerprint:abc123",
            "EngineConfig must parse --primary-display selector"
        )
        let parsedDefaultForeground = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--validate-only"
        ])
        check(
            parsedDefaultForeground.foregroundMode == .automatic,
            "EngineConfig must default foreground mode to auto"
        )
        let displaySelectionOptions = DisplayPlanner.displaySelectionOptions()
        check(
            displaySelectionOptions.first?.selector == nil,
            "display selection options must start with AppKit default primary"
        )
        check(
            displaySelectionOptions.isEmpty == false,
            "display selection options must be available for the control panel"
        )
        let autoRuntime = try NativeRuntimeCore(
            config: runtime.config.replacing(foregroundMode: .automatic, clearDuration: true)
        )
        let autoPrimaryRenderPath = DisplayPlanner.renderPathSummary(
            runtime: autoRuntime,
            role: RenderDisplayRole(kind: .primary, policy: .full)
        )
        check(
            autoPrimaryRenderPath.contains("foreground=nativeSpine(auto)"),
            "auto render plan must prefer native Spine when the bundle supports it"
        )
        let autoForegroundPlan = ForegroundRenderPlan.make(
            runtime: autoRuntime,
            role: RenderDisplayRole(kind: .primary, policy: .full),
            compatibility: RuntimeCapabilities.nativeSpineCompatibility(runtime: autoRuntime)
        )
        check(
            autoForegroundPlan.usesNativeSpine && autoForegroundPlan.foregroundLabel == "nativeSpine(auto)",
            "shared foreground render plan must match auto native render summary"
        )
        let nativeRuntime = try NativeRuntimeCore(
            config: runtime.config.replacing(foregroundMode: .nativeSpine, clearDuration: true)
        )
        let nativePrimaryRenderPath = DisplayPlanner.renderPathSummary(
            runtime: nativeRuntime,
            role: RenderDisplayRole(kind: .primary, policy: .full)
        )
        check(
            nativePrimaryRenderPath.contains("foreground=nativeSpine"),
            "native render plan must schedule Spine foreground on full primary displays"
        )
        let nativeSecondaryVideoPath = DisplayPlanner.renderPathSummary(
            runtime: nativeRuntime,
            role: RenderDisplayRole(kind: .secondary, policy: .videoOnly)
        )
        check(
            nativeSecondaryVideoPath.contains("foreground=none(display-policy)"),
            "native render plan must keep video-only secondary displays without Spine foreground"
        )
        check(
            DisplayPlanner.renderSummary(runtime: nativeRuntime).contains("foregroundMode: native"),
            "render plan summary must expose the requested foreground mode"
        )
        let displaySummary = DisplayPlanner.summary(runtime: nativeRuntime)
        if displaySummary.contains("no screens detected") == false {
            check(
                displaySummary.contains("identity=displayID:"),
                "display plan summary must expose a display identity field"
            )
            check(
                displaySummary.contains("fingerprint="),
                "display plan summary must expose a fallback display fingerprint"
            )
            check(
                displaySummary.contains("arrangement="),
                "display plan summary must expose a display arrangement fingerprint"
            )
        }
        let renderSummary = DisplayPlanner.renderSummary(runtime: nativeRuntime)
        if renderSummary.contains("no screens detected") == false {
            check(
                renderSummary.contains("identity=displayID:"),
                "render plan summary must expose a display identity field"
            )
            check(
                renderSummary.contains("fingerprint="),
                "render plan summary must expose a fallback display fingerprint"
            )
            check(
                renderSummary.contains("arrangement="),
                "render plan summary must expose a display arrangement fingerprint"
            )
        }
        if let metadata = manifest.metadata {
            if let id = metadata.id {
                check(validatedBundle?.id == id, "bundle catalog id must prefer manifest metadata.id")
            }
            if let title = metadata.title {
                check(validatedBundle?.displayName == title, "bundle catalog displayName must prefer manifest metadata.title")
            }
        }
        check(validatedBundle?.previewURL != nil, "bundle catalog must expose a preview URL when preview.jpg exists")

        let discoveredBundles = WallpaperBundleCatalog.discoverDefaultBundles(projectRoot: runtime.config.projectRoot)
        let discoveredIds = discoveredBundles.map(\.id)
        let discoveredNames = discoveredBundles.map(\.displayName)
        let activeBundlePath = runtime.config.wallpaperRoot.standardizedFileURL.resolvingSymlinksInPath().path
        check(ProjectPaths.userWallpapersDirectory() != nil, "user wallpaper library directory must be resolvable")
        check(discoveredBundles.isEmpty == false, "default bundle catalog must discover at least one valid bundle")
        check(Set(discoveredIds).count == discoveredIds.count, "default bundle catalog ids must be unique")
        check(
            discoveredNames == discoveredNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            "default bundle catalog must be sorted by display name"
        )
        check(
            discoveredBundles.contains {
                $0.root.standardizedFileURL.resolvingSymlinksInPath().path == activeBundlePath
            },
            "default bundle catalog must include the active wallpaper bundle"
        )
        try checkBundleDiagnostics(from: runtime, failures: &failures, checks: &checks)
        try checkVideoOnlyBundle(from: runtime, failures: &failures, checks: &checks)
        try checkStaticImageBundle(from: runtime, failures: &failures, checks: &checks)
        try checkUnsupportedSpineCompatibilityBundle(from: runtime, failures: &failures, checks: &checks)

        if failures.isEmpty == false {
            let details = failures.map { "- \($0)" }.joined(separator: "\n")
            throw EngineError.invalidArgument("Runtime self-test failed:\n\(details)")
        }

        return """
        runtime self-test OK
        checks: \(checks)
        manifest: \(runtime.config.manifestURL.path)
        bundle: \(runtime.config.wallpaperRoot.path)
        """
    }

    private static func checkResourceGovernorTelemetry(
        runtime: NativeRuntimeCore,
        failures: inout [String],
        checks: inout Int
    ) {
        let governor = ResourceGovernor(manifest: runtime.manifest, targetFps: runtime.renderTargetFps)
        let initial = governor.snapshot
        check(initial.currentFps == runtime.renderTargetFps, "resource governor snapshot must expose current FPS", failures: &failures, checks: &checks)
        check(initial.submittedFrames == 0, "resource governor snapshot must start with zero submitted frames", failures: &failures, checks: &checks)
        check(initial.skippedFrames == 0, "resource governor snapshot must start with zero skipped frames", failures: &failures, checks: &checks)
        check(initial.powerSavingActive == false, "resource governor snapshot must expose inactive power policy by default", failures: &failures, checks: &checks)

        var powerState = RuntimePowerState(lowPowerModeEnabled: true, onBatteryPower: false)
        let powerGovernor = ResourceGovernor(
            manifest: runtime.manifest,
            targetFps: runtime.renderTargetFps,
            powerStateProvider: { powerState }
        )
        let lowPowerFps = powerGovernor.frameStarted(now: 1.0)
        check(lowPowerFps == runtime.performancePlan.powerSavingFps, "low power mode must clamp rendering to power-saving FPS", failures: &failures, checks: &checks)
        check(powerGovernor.snapshot.powerSavingActive, "power-saving telemetry must activate for Low Power Mode", failures: &failures, checks: &checks)
        let lowPowerSnapshot = powerGovernor.snapshot
        powerState = RuntimePowerState(lowPowerModeEnabled: false, onBatteryPower: true)
        let batteryFps = powerGovernor.frameStarted(now: 1.5)
        check(batteryFps == runtime.performancePlan.powerSavingFps, "battery power must clamp rendering to power-saving FPS", failures: &failures, checks: &checks)
        powerState = RuntimePowerState(lowPowerModeEnabled: false, onBatteryPower: false)
        let recoveredFps = powerGovernor.frameStarted(now: 2.0)
        check(recoveredFps == runtime.renderTargetFps, "power-saving FPS clamp must recover when power state clears", failures: &failures, checks: &checks)

        governor.recordSkippedFrame(reason: .commandBufferBackpressure)
        governor.recordSubmittedFrame()
        let updated = governor.snapshot
        check(updated.skippedFrames == 1, "resource governor must count skipped frames", failures: &failures, checks: &checks)
        check(updated.lastSkipReason == FrameSkipReason.commandBufferBackpressure.rawValue, "resource governor must preserve last skip reason", failures: &failures, checks: &checks)
        check(updated.submittedFrames == 1, "resource governor must count submitted frames", failures: &failures, checks: &checks)

        let telemetry = RuntimeTelemetryStore()
        check(telemetry.summary() == "No runtime telemetry yet", "runtime telemetry store must report empty state", failures: &failures, checks: &checks)
        let role = RenderDisplayRole(kind: .primary, policy: runtime.manifest.displayPolicy.primary)
        telemetry.record(displayName: "Self Test Display", role: role, snapshot: updated)
        let summary = telemetry.summary()
        check(summary.contains("Self Test Display primary:"), "runtime telemetry summary must include display role", failures: &failures, checks: &checks)
        check(summary.contains("submitted 1"), "runtime telemetry summary must include submitted frame count", failures: &failures, checks: &checks)
        check(summary.contains("skipped 1"), "runtime telemetry summary must include skipped frame count", failures: &failures, checks: &checks)
        telemetry.record(displayName: "Self Test Display", role: role, snapshot: lowPowerSnapshot)
        check(telemetry.summary().contains("power-saving"), "runtime telemetry summary must label active power-saving policy", failures: &failures, checks: &checks)
        telemetry.record(displayName: "Self Test Display", role: role, snapshot: powerGovernor.snapshot)
        check(telemetry.summary().contains("power-saving") == false, "runtime telemetry summary must clear power-saving label after recovery", failures: &failures, checks: &checks)
    }

    private static func checkVisibilityPolicy(failures: inout [String], checks: inout Int) {
        let visiblePolicy = DisplayPolicy(
            primary: .full,
            secondary: .videoOnly,
            fullscreenObscured: .pause,
            occluded: .pause
        )
        check(
            RuntimeLifecyclePolicy.shouldPauseForWindowVisibility(isVisible: true, displayPolicy: visiblePolicy) == false,
            "visible wallpaper windows must not pause for visibility policy",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldPauseForWindowVisibility(isVisible: false, displayPolicy: visiblePolicy),
            "invisible wallpaper windows must pause when occlusion or fullscreen policy pauses",
            failures: &failures,
            checks: &checks
        )

        let fullscreenOnlyPolicy = DisplayPolicy(
            primary: .full,
            secondary: .videoOnly,
            fullscreenObscured: .pause,
            occluded: .full
        )
        check(
            RuntimeLifecyclePolicy.shouldPauseForWindowVisibility(isVisible: false, displayPolicy: fullscreenOnlyPolicy),
            "fullscreen-obscured pause policy must be honored even when generic occlusion is renderable",
            failures: &failures,
            checks: &checks
        )

        let renderThroughPolicy = DisplayPolicy(
            primary: .full,
            secondary: .videoOnly,
            fullscreenObscured: .full,
            occluded: .videoOnly
        )
        check(
            RuntimeLifecyclePolicy.shouldPauseForWindowVisibility(isVisible: false, displayPolicy: renderThroughPolicy) == false,
            "non-pause visibility policies must keep renderable windows active",
            failures: &failures,
            checks: &checks
        )

        let interactivePolicy = InteractionPolicy(
            mode: .desktopEmptyOnly,
            blockApplicationWindows: true,
            blockDesktopItems: true,
            pointerSmoothing: nil,
            idleDeadZone: nil,
            directionSwitchMargin: nil,
            defaultClickTailSeconds: nil,
            releaseFadeSeconds: nil
        )
        let disabledPolicy = InteractionPolicy(
            mode: .disabled,
            blockApplicationWindows: true,
            blockDesktopItems: true,
            pointerSmoothing: nil,
            idleDeadZone: nil,
            directionSwitchMargin: nil,
            defaultClickTailSeconds: nil,
            releaseFadeSeconds: nil
        )
        let primaryRole = RenderDisplayRole(kind: .primary, policy: .full)
        let secondaryRole = RenderDisplayRole(kind: .secondary, policy: .full)
        check(
            RuntimeLifecyclePolicy.shouldEnableDesktopInteraction(
                isVisible: true,
                displayRole: primaryRole,
                interactionPolicy: interactivePolicy
            ),
            "visible primary full wallpaper must enable desktop interaction monitor",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldEnableDesktopInteraction(
                isVisible: false,
                displayRole: primaryRole,
                interactionPolicy: interactivePolicy
            ) == false,
            "invisible wallpaper must suspend desktop interaction monitor",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldEnableDesktopInteraction(
                isVisible: true,
                displayRole: secondaryRole,
                interactionPolicy: interactivePolicy
            ) == false,
            "secondary wallpaper displays must not enable desktop interaction monitor",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldEnableDesktopInteraction(
                isVisible: true,
                displayRole: primaryRole,
                interactionPolicy: disabledPolicy
            ) == false,
            "disabled interaction policy must not enable desktop interaction monitor",
            failures: &failures,
            checks: &checks
        )
    }

    private static func checkBundleDiagnostics(
        from runtime: NativeRuntimeCore,
        failures: inout [String],
        checks: inout Int
    ) throws {
        let fileManager = FileManager.default
        let fixtureParent = fileManager.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineCatalogSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: fixtureParent)
        }

        let invalidBundleRoot = fixtureParent.appendingPathComponent("missing_manifest_bundle", isDirectory: true)
        try fileManager.createDirectory(at: invalidBundleRoot, withIntermediateDirectories: true)

        let diagnostics = WallpaperBundleCatalog.diagnose(in: fixtureParent)
        check(diagnostics.count == 1, "bundle diagnostics must report candidate folders", failures: &failures, checks: &checks)
        check(diagnostics.first?.status == .invalid, "bundle diagnostics must mark missing-manifest folders invalid", failures: &failures, checks: &checks)
        check(
            diagnostics.first?.errorMessage?.contains("wallpaper.native.json") == true,
            "bundle diagnostics must preserve invalid bundle reason",
            failures: &failures,
            checks: &checks
        )
        let invalidSummary = WallpaperBundleCatalog.invalidDiagnosticsSummary(for: diagnostics)
        check(
            invalidSummary.contains("Invalid bundles: missing_manifest_bundle"),
            "bundle diagnostics summary must name invalid folders for UI recovery",
            failures: &failures,
            checks: &checks
        )
        check(
            WallpaperBundleCatalog.discover(in: fixtureParent).isEmpty,
            "bundle discovery must exclude invalid diagnostics",
            failures: &failures,
            checks: &checks
        )

        let combinedDiagnostics = WallpaperBundleCatalog.diagnose(in: [
            fixtureParent,
            runtime.config.wallpaperRoot.deletingLastPathComponent()
        ])
        let activePath = runtime.config.wallpaperRoot.standardizedFileURL.resolvingSymlinksInPath().path
        check(
            combinedDiagnostics.contains {
                $0.status == .valid
                    && $0.root.standardizedFileURL.resolvingSymlinksInPath().path == activePath
            },
            "bundle diagnostics must include valid bundles alongside invalid ones",
            failures: &failures,
            checks: &checks
        )
    }

    private static func checkVideoOnlyBundle(
        from runtime: NativeRuntimeCore,
        failures: inout [String],
        checks: inout Int
    ) throws {
        checks += 1
        guard let sourceVideo = runtime.assetCatalog.compositeVideoAssetURL ?? runtime.assetCatalog.videoAssetURL else {
            failures.append("video-only fixture requires an active video or composite video asset")
            return
        }

        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: fixtureRoot)
        }

        let assetsRoot = fixtureRoot.appendingPathComponent("assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let fixtureVideo = assetsRoot.appendingPathComponent("background.mp4")
        do {
            try fileManager.linkItem(at: sourceVideo, to: fixtureVideo)
        } catch {
            try fileManager.copyItem(at: sourceVideo, to: fixtureVideo)
        }
        let sourcePreview = runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg")
        let fixturePreview = fixtureRoot.appendingPathComponent("preview.jpg")
        if fileManager.fileExists(atPath: sourcePreview.path) {
            do {
                try fileManager.linkItem(at: sourcePreview, to: fixturePreview)
            } catch {
                try fileManager.copyItem(at: sourcePreview, to: fixturePreview)
            }
        }

        let manifestURL = fixtureRoot.appendingPathComponent("wallpaper.native.json")
        let manifestJSON = """
        {
          "schemaVersion": "macos-wallpaper-native.v2",
          "metadata": {
            "id": "selftest_video_only",
            "title": "Self Test Video Only"
          },
          "runtime": {
            "kind": "native-metal",
            "targetFps": 30,
            "maxFps": 60,
            "fallbackFps": 15,
            "scheduler": {
              "maxInFlightCommandBuffers": 1,
              "lateFramePolicy": "drop",
              "catchUp": false
            }
          },
          "displayPolicy": {
            "primary": "full",
            "secondary": "static",
            "fullscreenObscured": "pause",
            "occluded": "pause"
          },
          "thermalPolicy": {
            "nominal": "30fps",
            "serious": "15fps-or-video-only",
            "critical": "pause"
          },
          "layerBudgets": {
            "maxTexturePages": 1,
            "maxTextureDimension": 4096,
            "rssTargetMb": 250,
            "rssHardMb": 500,
            "primaryCpuTargetPercent": 10,
            "cpuDowngradePercent": 20,
            "cpuDowngradeWindowSeconds": 10
          },
          "assets": {
            "video": {
              "id": "backgroundVideo",
              "path": "assets/background.mp4",
              "playbackRate": 1.0
            }
          },
          "layers": [
            {
              "id": "background",
              "type": "video",
              "asset": "backgroundVideo"
            }
          ],
          "interactions": [],
          "validation": {
            "bundleRootOnly": true,
            "requirePremultipliedAlpha": false,
            "requireSpineVersion": "4.2.x",
            "rejectUnknownLayerTypes": true
          }
        }
        """
        try Data(manifestJSON.utf8).write(to: manifestURL, options: .atomic)

        let videoOnlyRuntime = try NativeRuntimeCore(config: runtime.config.replacing(
            wallpaperRoot: fixtureRoot,
            manifestURL: manifestURL,
            displayMode: .primaryAnimated,
            renderFps: 30,
            foregroundMode: .compositeVideo,
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))

        check(videoOnlyRuntime.assetCatalog.spineAsset == nil, "video-only bundle must not require a Spine asset", failures: &failures, checks: &checks)
        check(videoOnlyRuntime.manifest.layers.count == 1, "video-only bundle must preserve its single video layer", failures: &failures, checks: &checks)
        check(videoOnlyRuntime.validationSummary().contains("spine json: none"), "video-only validation summary must report no Spine asset", failures: &failures, checks: &checks)
        let videoOnlySummary = try WallpaperBundleCatalog.requireValidBundle(fixtureRoot)
        check(videoOnlySummary.capabilities.nativeSpineStatus == "not-used", "video-only bundle catalog must mark native Spine unused", failures: &failures, checks: &checks)
        check(videoOnlyRuntime.runtimeCapabilitiesSummary().contains("spine\tnativeRenderer\tnot-used"), "video-only capability summary must mark Spine renderer unused", failures: &failures, checks: &checks)
        check(
            DisplayPlanner.role(isPrimary: false, displayMode: .primaryAnimated, manifest: videoOnlyRuntime.manifest)?.policy == .static,
            "video-only bundle must support static secondary display policy",
            failures: &failures,
            checks: &checks
        )

        try fileManager.removeItem(at: fixturePreview)
        checks += 1
        do {
            _ = try NativeRuntimeCore(config: videoOnlyRuntime.config)
            failures.append("static display policy must reject bundles without preview.jpg")
        } catch {
            // Expected: static secondary displays need a validated preview image.
        }
    }

    private static func checkStaticImageBundle(
        from runtime: NativeRuntimeCore,
        failures: inout [String],
        checks: inout Int
    ) throws {
        let sourceImage = runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg")
        checks += 1
        guard FileManager.default.fileExists(atPath: sourceImage.path) else {
            failures.append("static image fixture requires active bundle preview.jpg")
            return
        }

        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineStaticSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: fixtureRoot)
        }

        let assetsRoot = fixtureRoot.appendingPathComponent("assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let fixtureImage = assetsRoot.appendingPathComponent("poster.jpg")
        do {
            try fileManager.linkItem(at: sourceImage, to: fixtureImage)
        } catch {
            try fileManager.copyItem(at: sourceImage, to: fixtureImage)
        }

        let manifestURL = fixtureRoot.appendingPathComponent("wallpaper.native.json")
        let manifestJSON = """
        {
          "schemaVersion": "macos-wallpaper-native.v2",
          "metadata": {
            "id": "selftest_static_image",
            "title": "Self Test Static Image"
          },
          "runtime": {
            "kind": "native-metal",
            "targetFps": 30,
            "maxFps": 60,
            "fallbackFps": 15,
            "scheduler": {
              "maxInFlightCommandBuffers": 1,
              "lateFramePolicy": "drop",
              "catchUp": false
            }
          },
          "displayPolicy": {
            "primary": "full",
            "secondary": "static",
            "fullscreenObscured": "pause",
            "occluded": "pause"
          },
          "thermalPolicy": {
            "nominal": "30fps",
            "serious": "15fps-or-static",
            "critical": "pause"
          },
          "layerBudgets": {
            "maxTexturePages": 1,
            "maxTextureDimension": 4096,
            "rssTargetMb": 128,
            "rssHardMb": 256,
            "primaryCpuTargetPercent": 5,
            "cpuDowngradePercent": 10,
            "cpuDowngradeWindowSeconds": 10
          },
          "assets": {
            "staticImage": {
              "id": "poster",
              "path": "assets/poster.jpg"
            }
          },
          "layers": [
            {
              "id": "poster-layer",
              "type": "static_image",
              "asset": "poster"
            }
          ],
          "interactions": [],
          "validation": {
            "bundleRootOnly": true,
            "requirePremultipliedAlpha": false,
            "requireSpineVersion": "4.2.x",
            "rejectUnknownLayerTypes": true
          }
        }
        """
        try Data(manifestJSON.utf8).write(to: manifestURL, options: .atomic)

        let staticRuntime = try NativeRuntimeCore(config: runtime.config.replacing(
            wallpaperRoot: fixtureRoot,
            manifestURL: manifestURL,
            displayMode: .primaryAnimated,
            renderFps: 30,
            foregroundMode: .compositeVideo,
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))

        check(staticRuntime.assetCatalog.staticImageAssetURL != nil, "static image bundle must load staticImage asset", failures: &failures, checks: &checks)
        check(staticRuntime.assetCatalog.videoAsset == nil, "static image bundle must not require a video asset", failures: &failures, checks: &checks)
        check(staticRuntime.assetCatalog.spineAsset == nil, "static image bundle must not require a Spine asset", failures: &failures, checks: &checks)
        check(staticRuntime.manifest.layers.first?.type == .staticImage, "static image bundle must preserve static_image layer type", failures: &failures, checks: &checks)
        check(staticRuntime.validationSummary().contains("static image: \(fixtureImage.path)"), "static image validation summary must report the image asset", failures: &failures, checks: &checks)
        check(staticRuntime.runtimeCapabilitiesSummary().contains("layer\tstatic_image\tsupported"), "static image capability summary must report static_image support", failures: &failures, checks: &checks)
        let staticSummary = try WallpaperBundleCatalog.requireValidBundle(fixtureRoot)
        check(staticSummary.previewURL?.lastPathComponent == "poster.jpg", "static image bundle catalog preview must fall back to staticImage asset", failures: &failures, checks: &checks)
        check(staticSummary.capabilities.briefText.contains("assets: static"), "static image bundle catalog must expose static capability", failures: &failures, checks: &checks)
    }

    private static func checkUnsupportedSpineCompatibilityBundle(
        from runtime: NativeRuntimeCore,
        failures: inout [String],
        checks: inout Int
    ) throws {
        checks += 1
        guard let sourceVideo = runtime.assetCatalog.compositeVideoAssetURL ?? runtime.assetCatalog.videoAssetURL else {
            failures.append("unsupported Spine compatibility fixture requires an active video asset")
            return
        }

        let sourceTexture = runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg")
        checks += 1
        guard FileManager.default.fileExists(atPath: sourceTexture.path) else {
            failures.append("unsupported Spine compatibility fixture requires active bundle preview.jpg")
            return
        }

        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineUnsupportedSpineSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: fixtureRoot)
        }

        let assetsRoot = fixtureRoot.appendingPathComponent("assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let fixtureVideo = assetsRoot.appendingPathComponent("background.mp4")
        let fixtureTexture = assetsRoot.appendingPathComponent("texture.jpg")
        do {
            try fileManager.linkItem(at: sourceVideo, to: fixtureVideo)
        } catch {
            try fileManager.copyItem(at: sourceVideo, to: fixtureVideo)
        }
        do {
            try fileManager.linkItem(at: sourceTexture, to: fixtureTexture)
        } catch {
            try fileManager.copyItem(at: sourceTexture, to: fixtureTexture)
        }

        let fixtureAtlas = assetsRoot.appendingPathComponent("character.atlas")
        try Data("texture.jpg\nsize: 64,64\n".utf8).write(to: fixtureAtlas, options: .atomic)

        let fixtureSpineJSON = assetsRoot.appendingPathComponent("character.json")
        let spineJSON = """
        {
          "skeleton": {
            "spine": "4.2.43"
          },
          "skins": [
            {
              "name": "default",
              "attachments": {
                "face": {
                  "animated-sequence": {
                    "type": "sequence"
                  }
                }
              }
            }
          ],
          "events": {
            "voice": {
              "audio": "voice.wav"
            }
          },
          "animations": {
            "idle": {},
            "touch": {
              "events": [
                {
                  "time": 0,
                  "name": "voice"
                }
              ]
            }
          }
        }
        """
        try Data(spineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)

        let manifestURL = fixtureRoot.appendingPathComponent("wallpaper.native.json")
        let manifestJSON = """
        {
          "schemaVersion": "macos-wallpaper-native.v2",
          "metadata": {
            "id": "selftest_unsupported_spine",
            "title": "Self Test Unsupported Spine"
          },
          "runtime": {
            "kind": "native-metal",
            "targetFps": 30,
            "maxFps": 60,
            "fallbackFps": 15,
            "scheduler": {
              "maxInFlightCommandBuffers": 1,
              "lateFramePolicy": "drop",
              "catchUp": false
            }
          },
          "displayPolicy": {
            "primary": "full",
            "secondary": "video-only",
            "fullscreenObscured": "pause",
            "occluded": "pause"
          },
          "thermalPolicy": {
            "nominal": "30fps",
            "serious": "15fps-or-video-only",
            "critical": "pause"
          },
          "layerBudgets": {
            "maxTexturePages": 1,
            "maxTextureDimension": 4096,
            "rssTargetMb": 250,
            "rssHardMb": 500,
            "primaryCpuTargetPercent": 10,
            "cpuDowngradePercent": 20,
            "cpuDowngradeWindowSeconds": 10
          },
          "assets": {
            "video": {
              "id": "backgroundVideo",
              "path": "assets/background.mp4",
              "playbackRate": 1.0
            },
            "compositeVideo": {
              "id": "compositeVideo",
              "path": "assets/background.mp4",
              "playbackRate": 1.0
            },
            "spine": {
              "id": "unsupportedCharacter",
              "version": "4.2.43",
              "json": "assets/character.json",
              "atlas": "assets/character.atlas",
              "textures": [
                "assets/texture.jpg"
              ],
              "premultipliedAlpha": true
            }
          },
          "layers": [
            {
              "id": "background",
              "type": "video",
              "asset": "backgroundVideo"
            },
            {
              "id": "character",
              "type": "spine",
              "asset": "unsupportedCharacter",
              "renderingMode": "setup-mesh"
            }
          ],
          "interactions": [
            {
              "event": "pointerDown",
              "hitZones": [
                {
                  "id": "head",
                  "rect": [0.25, 0.25, 0.75, 0.75],
                  "action": "touch"
                }
              ]
            }
          ],
          "validation": {
            "bundleRootOnly": true,
            "requirePremultipliedAlpha": false,
            "requireSpineVersion": "4.2.x",
            "rejectUnknownLayerTypes": true
          }
        }
        """
        try Data(manifestJSON.utf8).write(to: manifestURL, options: .atomic)

        let unsupportedRuntime = try NativeRuntimeCore(config: runtime.config.replacing(
            wallpaperRoot: fixtureRoot,
            manifestURL: manifestURL,
            displayMode: .primaryAnimated,
            renderFps: 30,
            foregroundMode: .nativeSpine,
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))

        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: unsupportedRuntime)
        check(compatibility.isSupported == false, "unsupported Spine fixture must fail native compatibility gate", failures: &failures, checks: &checks)
        check(compatibility.reasonText.contains("unsupported attachment types"), "compatibility gate must report unsupported attachment types", failures: &failures, checks: &checks)
        check(compatibility.reasonText.contains("events/audio/sequence"), "compatibility gate must report events/audio/sequence limits", failures: &failures, checks: &checks)
        check(
            unsupportedRuntime.runtimeCapabilitiesSummary().contains("spine\tnativeCompatibilityGate\tunsupported"),
            "unsupported Spine capability summary must mark nativeCompatibilityGate unsupported",
            failures: &failures,
            checks: &checks
        )
        let unsupportedSummary = try WallpaperBundleCatalog.requireValidBundle(fixtureRoot)
        check(unsupportedSummary.capabilities.nativeSpineStatus == "unsupported", "catalog must surface unsupported native Spine status", failures: &failures, checks: &checks)
        check(unsupportedSummary.capabilities.fallbackStatus == "composite", "catalog must surface composite fallback for unsupported native Spine", failures: &failures, checks: &checks)
        let unsupportedAutoRuntime = try NativeRuntimeCore(config: unsupportedRuntime.config.replacing(
            foregroundMode: .automatic,
            clearDuration: true
        ))
        let unsupportedAutoPlan = ForegroundRenderPlan.make(
            runtime: unsupportedAutoRuntime,
            role: RenderDisplayRole(kind: .primary, policy: .full),
            compatibility: RuntimeCapabilities.nativeSpineCompatibility(runtime: unsupportedAutoRuntime)
        )
        check(
            unsupportedAutoPlan.usesCompositeVideo
                && unsupportedAutoPlan.foregroundLabel == "compositeVideo(auto)"
                && unsupportedAutoPlan.fallbackLabel == "auto->compositeVideo",
            "auto foreground render plan must fall back to composite for unsupported native Spine bundles",
            failures: &failures,
            checks: &checks
        )

        let noFallbackManifestJSON = manifestJSON.replacingOccurrences(of: """
            "compositeVideo": {
              "id": "compositeVideo",
              "path": "assets/background.mp4",
              "playbackRate": 1.0
            },

        """, with: "")
        try Data(noFallbackManifestJSON.utf8).write(to: manifestURL, options: .atomic)
        do {
            _ = try NativeRuntimeCore(config: unsupportedRuntime.config)
            failures.append("unsupported native Spine bundle without composite fallback must fail manifest validation")
        } catch {
            check(
                error.localizedDescription.contains("no compositeVideo fallback exists"),
                "unsupported native Spine validation must explain missing composite fallback",
                failures: &failures,
                checks: &checks
            )
        }
    }

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        failures: inout [String],
        checks: inout Int
    ) {
        checks += 1
        if condition() == false {
            failures.append(message)
        }
    }

    private static func checkRole(
        _ role: RenderDisplayRole?,
        policy: DisplayRolePolicy,
        kind: String,
        failures: inout [String],
        checks: inout Int
    ) {
        checks += 1
        if policy == .pause {
            if role != nil {
                failures.append("\(kind) pause policy must not create a renderable role")
            }
            return
        }

        guard let role else {
            failures.append("\(kind) non-pause policy must create a renderable role")
            return
        }

        checks += 1
        if role.policy != policy {
            failures.append("\(kind) role policy must match manifest policy")
        }

        checks += 1
        if role.isRenderable == false {
            failures.append("\(kind) role must be renderable for non-pause policy")
        }

        checks += 1
        if role.playsVideo != (policy == .full || policy == .videoOnly) {
            failures.append("\(kind) video playback flag must match display policy")
        }

        checks += 1
        if role.rendersForeground != (policy == .full) {
            failures.append("\(kind) foreground flag must match display policy")
        }
    }
}
