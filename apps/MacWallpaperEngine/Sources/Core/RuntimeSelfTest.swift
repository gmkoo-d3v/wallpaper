import CoreGraphics
import Darwin
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
            highPlan.summary().contains("exhaustedBudgetFallback: fps downgrade; renderer swap disabled by default"),
            "performance plan must document that resource pressure keeps the selected renderer"
        )
        check(highPlan.summary().contains("telemetryFields: currentFps"), "performance plan must document runtime telemetry fields")
        let displayRefreshRuntime = try NativeRuntimeCore(config: runtime.config.replacing(
            renderFps: 60,
            matchDisplayRefresh: true,
            clearDuration: true
        ))
        check(
            displayRefreshRuntime.renderTargetFps(displayRefreshFps: 144) == 144,
            "display-refresh FPS mode must match monitor refresh above 60Hz"
        )
        check(
            displayRefreshRuntime.renderTargetFps(displayRefreshFps: 60) == 60,
            "display-refresh FPS mode must preserve 60Hz displays"
        )
        let displayRefreshPlan = DisplayPlanner.headlessRenderSummary(runtime: displayRefreshRuntime)
        check(
            displayRefreshPlan.contains("fpsMode=display")
                && displayRefreshPlan.contains("displayRefresh=60Hz")
                && displayRefreshPlan.contains("fps=60"),
            "render plan must expose effective display-refresh FPS for diagnostic displays"
        )
        check(
            DisplayPlanner.rebuildPolicy == "debounced-atomic-rollback",
            "display rebuild policy must debounce screen changes and preserve old windows until replacement succeeds"
        )
        check(
            RuntimeLifecyclePolicy.displayRebuildDebounceSeconds > 0
                && RuntimeLifecyclePolicy.displayRebuildDebounceSeconds <= 1,
            "display rebuild debounce must absorb notification bursts without feeling stale"
        )
        check(
            RuntimeLifecyclePolicy.displayRebuildCommitDecision(
                existingWindowCount: 0,
                replacementWindowCount: 0,
                isInitialBuild: true
            ).shouldCommit,
            "initial display build may commit an empty plan so startup can surface control-panel recovery"
        )
        check(
            RuntimeLifecyclePolicy.displayRebuildCommitDecision(
                existingWindowCount: 2,
                replacementWindowCount: 1,
                isInitialBuild: false
            ).shouldCommit,
            "running display rebuild must commit valid non-empty replacement windows"
        )
        let emptyHotPlugRebuild = RuntimeLifecyclePolicy.displayRebuildCommitDecision(
            existingWindowCount: 2,
            replacementWindowCount: 0,
            isInitialBuild: false
        )
        check(
            emptyHotPlugRebuild.shouldCommit == false,
            "running display rebuild must preserve existing windows when hot-plug probing returns zero replacements"
        )
        if case .rollback(let reason) = emptyHotPlugRebuild {
            check(
                reason.contains("preserving 2"),
                "display rebuild rollback reason must keep the preserved-window count observable"
            )
        } else {
            check(false, "empty hot-plug rebuild must produce a rollback decision")
        }
        check(RuntimeLifecyclePolicy.startupFailurePolicy == "control-panel-recovery", "startup host failures must have an explicit recovery policy")
        check(
            RuntimeLifecyclePolicy.rendererFailureRecoveryPolicy == "yield-to-system-wallpaper-after-repeated-renderer-failures",
            "repeated renderer failures must have an explicit safe-mode recovery policy"
        )
        let rendererRecoveryKey = RendererRecoveryKey(
            wallpaperID: manifest.metadata?.id ?? "unknown",
            displayFingerprint: "display:self-test",
            rendererKind: "native",
            failureClass: "host-start"
        )
        let recoveryTracker = RendererRecoveryTracker(storeURL: nil)
        let firstRendererFailure = recoveryTracker.recordFailure(key: rendererRecoveryKey, now: 10)
        let secondRendererFailure = recoveryTracker.recordFailure(key: rendererRecoveryKey, now: 20)
        let thirdRendererFailure = recoveryTracker.recordFailure(key: rendererRecoveryKey, now: 30)
        check(
            firstRendererFailure.shouldYieldToSystemWallpaper == false
                && secondRendererFailure.shouldYieldToSystemWallpaper == false,
            "renderer recovery must allow bounded retries before safe mode"
        )
        check(
            thirdRendererFailure.shouldYieldToSystemWallpaper,
            "renderer recovery must yield to system wallpaper after repeated failures"
        )
        if case .safeMode(let failureCount, let retryAfterSeconds, let reason) = thirdRendererFailure {
            check(
                failureCount == RendererRecoveryPolicy.failureThreshold
                    && retryAfterSeconds == RendererRecoveryPolicy.safeModeCooldownSeconds
                    && reason.contains("SAFE MODE"),
                "renderer recovery safe mode must expose failure count, cooldown, and user-visible reason"
            )
        } else {
            check(false, "third renderer failure must produce safe mode decision")
        }
        check(
            recoveryTracker.decisionBeforeStart(key: rendererRecoveryKey, now: 40)?.shouldYieldToSystemWallpaper == true,
            "safe-mode renderer recovery must block immediate restart loops"
        )
        recoveryTracker.recordSuccess(key: rendererRecoveryKey)
        check(
            recoveryTracker.decisionBeforeStart(key: rendererRecoveryKey, now: 41) == nil,
            "successful renderer start must clear safe-mode quarantine for that wallpaper/display/renderer key"
        )
        let recoveryStoreRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineRecoverySelfTest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: recoveryStoreRoot)
        }
        let recoveryStoreURL = recoveryStoreRoot.appendingPathComponent("renderer-recovery.json")
        let persistedRecoveryTracker = RendererRecoveryTracker(storeURL: recoveryStoreURL)
        _ = persistedRecoveryTracker.recordFailure(key: rendererRecoveryKey, now: 100)
        _ = persistedRecoveryTracker.recordFailure(key: rendererRecoveryKey, now: 110)
        _ = persistedRecoveryTracker.recordFailure(key: rendererRecoveryKey, now: 120)
        let reloadedRecoveryTracker = RendererRecoveryTracker(storeURL: recoveryStoreURL)
        check(
            reloadedRecoveryTracker.decisionBeforeStart(key: rendererRecoveryKey, now: 121)?.shouldYieldToSystemWallpaper == true,
            "renderer safe-mode quarantine must persist across app relaunch"
        )
        let recoveryReport = RendererRecoveryStore.report(recoveryURL: recoveryStoreURL, now: 121)
        check(
            recoveryReport.contains("renderer recovery plan OK")
                && recoveryReport.contains("state\twallpaper\tdisplay\trenderer\tfailureClass\trecentFailures\tretryAfter")
                && recoveryReport.contains("safe-mode\t\(rendererRecoveryKey.wallpaperID)\tdisplay:self-test\tnative\thost-start\t3\t299s"),
            "renderer recovery report must expose persisted safe-mode quarantine state"
        )
        reloadedRecoveryTracker.recordSuccess(key: rendererRecoveryKey)
        let clearedRecoveryTracker = RendererRecoveryTracker(storeURL: recoveryStoreURL)
        check(
            clearedRecoveryTracker.decisionBeforeStart(key: rendererRecoveryKey, now: 122) == nil,
            "renderer safe-mode persistence must clear after a successful renderer start"
        )
        check(
            RendererRecoveryStore.report(recoveryURL: recoveryStoreURL, now: 122).contains("empty\tnone\tnone\tnone\tnone\t0\t0s"),
            "renderer recovery report must expose an empty state after quarantine is cleared"
        )
        check(
            RuntimeLifecyclePolicy.visibilityPausePolicy == "pause-when-occluded-or-fullscreen-obscured",
            "window visibility pause policy must be explicit"
        )
        check(
            RuntimeLifecyclePolicy.desktopItemTrustPolicy == "fail-closed-without-accessibility-trust",
            "desktop item interaction policy must fail closed without Accessibility trust"
        )
        check(
            RuntimeLifecyclePolicy.outsideContentTrackingPolicy == "ignore-same-window-outside-content-without-idle-reset",
            "same-window outside-content moves must not reset gaze; application/monitor exits remain the tracking-stop boundary"
        )
        check(
            RuntimeLifecyclePolicy.blockedDesktopEventTrackingPolicy == "ignore-blocked-desktop-events-without-idle-reset",
            "desktop-empty blocked events must not reset gaze while app-window and desktop-icon input is ignored"
        )
        check(
            RuntimeLifecyclePolicy.defaultDisplayModeForNewBundle == .primaryOnly,
            "new or recovery-selected bundles must default to selected-display-only instead of touching secondary monitors"
        )
        let userDefaultRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineUserDefaultSelfTest-\(UUID().uuidString)", isDirectory: true)
        let bundledDefaultRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineBundledDefaultSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: userDefaultRoot)
            try? FileManager.default.removeItem(at: bundledDefaultRoot)
        }
        let userDefaultBundle = try writeStaticImageBundleFixture(
            root: userDefaultRoot.appendingPathComponent("user_duplicate", isDirectory: true),
            imageSource: runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg"),
            id: "duplicate-default",
            title: "User Duplicate Default"
        )
        _ = try writeStaticImageBundleFixture(
            root: bundledDefaultRoot.appendingPathComponent("bundled_duplicate", isDirectory: true),
            imageSource: runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg"),
            id: "duplicate-default",
            title: "Bundled Duplicate Default"
        )
        let precedenceDiagnostics = WallpaperBundleCatalog.diagnose(in: [userDefaultRoot, bundledDefaultRoot])
        check(
            precedenceDiagnostics.contains {
                $0.status == .valid
                    && $0.bundle?.id == "duplicate-default"
                    && $0.root.standardizedFileURL.resolvingSymlinksInPath().path
                        == userDefaultBundle.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            },
            "bundle catalog precedence must keep user-library bundles valid when a lower-priority bundled sample has the same id"
        )
        check(
            precedenceDiagnostics.contains {
                $0.status == .invalid
                    && $0.root.lastPathComponent == "bundled_duplicate"
                    && ($0.errorMessage?.contains("Duplicate wallpaper bundle id duplicate-default") == true)
            },
            "bundle catalog precedence must mark lower-priority duplicate bundled samples invalid"
        )
        let timedConfig = runtime.config.replacing(
            duration: 42,
            launchControlPanel: false,
            launchWallpaper: false
        )
        let displayChangedConfig = timedConfig.replacing(displayMode: .all)
        check(
            displayChangedConfig.duration == 42,
            "EngineConfig.replacing must preserve duration when changing unrelated settings"
        )
        check(
            displayChangedConfig.launchControlPanel == false && displayChangedConfig.launchWallpaper == false,
            "EngineConfig.replacing must preserve launch flags when changing unrelated settings"
        )
        check(
            timedConfig.replacing(clearDuration: true).duration == nil,
            "EngineConfig.replacing must clear duration only when clearDuration is explicit"
        )
        check(
            ControlPanelWindowController.displayModeLabels == ["Selected Only", "Selected+Policy", "All Full"],
            "control panel display mode labels must make selected-display-only the default"
        )
        check(
            ControlPanelWindowController.displayModeTooltips.count == ControlPanelWindowController.displayModeLabels.count
                && ControlPanelWindowController.displayModeTooltips[0].contains("Only the selected primary display")
                && ControlPanelWindowController.displayModeTooltips[1].contains("secondary displays follow")
                && ControlPanelWindowController.displayModeTooltips[2].contains("All displays render"),
            "control panel display mode tooltips must match segment order and actual display planner behavior"
        )
        check(
            ControlPanelWindowController.fpsLabels == ["30", "60", "Display Hz"],
            "control panel FPS labels must expose only fixed 30/60 plus display refresh matching"
        )
        check(
            ControlPanelWindowController.interactionStatusMaximumLines >= 2
                && ControlPanelWindowController.doctorStatusMaximumLines >= 4
                && ControlPanelWindowController.interactionPermissionButtonTooltip.contains("Accessibility"),
            "control panel must preserve readable doctor/interaction diagnostics and explain permission requests"
        )
        check(
            ControlPanelFailureStatusPolicy.lastErrorAfterNonDegradingSelectionFailure(
                previousRuntimeAvailable: true,
                previousLastError: nil,
                failureDescription: "bad bundle"
            ) == nil,
            "failed bundle selection must not mark a healthy selected runtime as errored"
        )
        check(
            ControlPanelFailureStatusPolicy.lastErrorAfterNonDegradingSelectionFailure(
                previousRuntimeAvailable: true,
                previousLastError: "previous startup failure",
                failureDescription: "bad bundle"
            ) == "previous startup failure",
            "failed bundle selection must preserve a pre-existing runtime error instead of overwriting it"
        )
        check(
            ControlPanelFailureStatusPolicy.lastErrorAfterNonDegradingSelectionFailure(
                previousRuntimeAvailable: false,
                previousLastError: nil,
                failureDescription: "bad bundle"
            ) == "bad bundle",
            "failed bundle selection with no existing runtime must remain visible as the current status error"
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
        if let primaryRole {
            check(
                WallpaperHost.shouldIgnoreMouseEvents(runtime: runtime, role: primaryRole),
                "desktop wallpaper host windows must ignore mouse events so Finder and other desktop targets keep click ownership"
            )
            let plainRuntime = try NativeRuntimeCore(
                config: runtime.config.replacing(plainWindowStyle: true)
            )
            check(
                WallpaperHost.shouldIgnoreMouseEvents(runtime: plainRuntime, role: primaryRole) == false,
                "plain diagnostic host windows must accept mouse events for local direct-delivery debugging"
            )
        }

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
        let primaryOnlySimulatedPlan = DisplayPlanner.simulatedMultiDisplayRenderSummary(
            runtime: runtime,
            displayMode: .primaryOnly
        )
        check(
            occurrenceCount("primary:\(manifest.displayPolicy.primary.rawValue)", in: primaryOnlySimulatedPlan) == 1,
            "selected-only simulated plan must render exactly one primary display"
        )
        check(
            occurrenceCount("\tnone\tbackground=none\tforeground=none", in: primaryOnlySimulatedPlan) == 2,
            "selected-only simulated plan must leave both secondary displays untouched"
        )
        let selectedPolicySimulatedPlan = DisplayPlanner.simulatedMultiDisplayRenderSummary(
            runtime: runtime,
            displayMode: .primaryAnimated
        )
        check(
            occurrenceCount("secondary:\(manifest.displayPolicy.secondary.rawValue)", in: selectedPolicySimulatedPlan) == 2,
            "selected+policy simulated plan must apply manifest secondary policy to both secondary displays"
        )
        check(
            selectedPolicySimulatedPlan.contains("foreground=none(display-policy)")
                && selectedPolicySimulatedPlan.contains("interaction=passive"),
            "selected+policy simulated plan must keep secondary displays video/static-only and passive"
        )
        let allDisplaysSimulatedPlan = DisplayPlanner.simulatedMultiDisplayRenderSummary(
            runtime: runtime,
            displayMode: .all
        )
        check(
            occurrenceCount("secondary:full", in: allDisplaysSimulatedPlan) == 2,
            "all-full simulated plan must render both secondary displays with full foreground policy"
        )
        check(
            occurrenceCount("displayRefresh=60Hz", in: allDisplaysSimulatedPlan) == 2
                && allDisplaysSimulatedPlan.contains("displayRefresh=120Hz"),
            "simulated multi-display plan must preserve per-display refresh diagnostics"
        )

        let validatedBundle = WallpaperBundleCatalog.validateBundle(runtime.config.wallpaperRoot)
        check(validatedBundle != nil, "active wallpaper bundle must pass catalog validation")
        let activeNativeCompatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        let expectedNativeSpineStatus = if runtime.assetCatalog.spineAsset == nil {
            "not-used"
        } else {
            activeNativeCompatibility.isSupported ? "supported" : "unsupported"
        }
        let expectedFallbackStatus = if activeNativeCompatibility.isSupported {
            runtime.assetCatalog.compositeVideoAsset == nil ? "not-needed" : "composite-ready"
        } else {
            runtime.assetCatalog.compositeVideoAsset == nil ? "blocked" : "composite"
        }
        check(
            validatedBundle?.capabilities.nativeSpineStatus == expectedNativeSpineStatus,
            "bundle catalog must expose active bundle native Spine support status"
        )
        check(
            validatedBundle?.capabilities.fallbackStatus == expectedFallbackStatus,
            "bundle catalog must expose active bundle fallback readiness"
        )
        let expectedInteractionRequirement = RuntimeCapabilities
            .bundleInfo(manifest: manifest, bundleRoot: runtime.config.wallpaperRoot)
            .interactionRequirement
        check(
            validatedBundle?.capabilities.interactionRequirement == expectedInteractionRequirement,
            "bundle catalog must expose active bundle desktop interaction permission requirement"
        )
        if let validatedBundle {
            check(
                ControlPanelWindowController
                    .bundlePopupTitle(for: validatedBundle)
                    .contains("/\(expectedInteractionRequirement)/"),
                "control panel bundle popup title must expose interaction permission requirement before selection"
            )
            let bundlePopupTooltip = ControlPanelWindowController.bundlePopupTooltip(for: validatedBundle)
            check(
                bundlePopupTooltip.contains(validatedBundle.id)
                    && bundlePopupTooltip.contains(validatedBundle.root.path)
                    && bundlePopupTooltip.contains(validatedBundle.manifestURL.path)
                    && bundlePopupTooltip.contains(validatedBundle.capabilities.briefText),
                "control panel bundle popup tooltip must expose identity, paths, and capabilities before selection"
            )
        }
        if let compositeVideo = runtime.assetCatalog.compositeVideoAsset,
           let metadata = try? VideoMetadataInspector.inspect(url: compositeVideo.url),
           let effectiveFps = metadata.effectiveFrameRate(playbackRate: compositeVideo.playbackRate),
           effectiveFps + 0.5 < Double(runtime.manifest.runtime.targetFps) {
            check(
                validatedBundle?.capabilities.qualityStatus == "warning",
                "bundle catalog must flag low-FPS composite fallback quality"
            )
            check(
                validatedBundle?.capabilities.qualityWarnings.contains(where: { $0.contains("compositeVideo effectiveFps=") }) == true,
                "bundle catalog quality warning must identify the low-FPS composite asset"
            )
        }
        let compositeQualityReport = runtime.compositeQualityReport()
        check(
            runtime.validationSummary().contains("composite quality: \(compositeQualityReport.summaryLine)"),
            "validation summary must surface composite fallback quality"
        )
        if let compositeVideo = runtime.assetCatalog.compositeVideoAsset,
           let metadata = try? VideoMetadataInspector.inspect(url: compositeVideo.url),
           let effectiveFps = metadata.effectiveFrameRate(playbackRate: compositeVideo.playbackRate),
           effectiveFps + 0.5 >= Double(runtime.manifest.runtime.targetFps),
           effectiveFps + 0.5 < Double(runtime.manifest.runtime.maxFps) {
            check(
                compositeQualityReport.isAcceptable
                    && compositeQualityReport.recommendedExportFps == "display-refresh"
                    && compositeQualityReport.recommendations.contains(where: { $0.contains("below maxFps=\(runtime.manifest.runtime.maxFps)") }),
                "target-FPS composite fallback must remain acceptable while recommending display-refresh regeneration for high-refresh displays"
            )
            check(
                compositeQualityReport.text.contains("recommendations:")
                    && compositeQualityReport.text.contains("below maxFps=\(runtime.manifest.runtime.maxFps)"),
                "composite quality report must expose high-refresh recommendations even when target FPS passes"
            )
            check(
                validatedBundle?.capabilities.qualityRecommendations.contains(where: { $0.contains("below maxFps=\(runtime.manifest.runtime.maxFps)") }) == true,
                "bundle catalog capabilities must surface high-refresh composite fallback recommendations"
            )
        }
        if let compositeVideo = runtime.assetCatalog.compositeVideoAsset,
           let metadata = try? VideoMetadataInspector.inspect(url: compositeVideo.url),
           let effectiveFps = metadata.effectiveFrameRate(playbackRate: compositeVideo.playbackRate),
           effectiveFps + 0.5 >= Double(runtime.manifest.runtime.maxFps) {
            check(
                compositeQualityReport.recommendedExportFps == nil
                    && compositeQualityReport.recommendations.isEmpty,
                "max-FPS composite fallback must not keep stale high-refresh regeneration recommendations"
            )
            if runtime.manifest.metadata?.id == "sample_imported" {
                check(
                    compositeVideo.url.lastPathComponent.contains("120fps"),
                    "Imported sample must ship a 120fps composite fallback for Display Hz / ProMotion fallback playback"
                )
            }
        }
        check(
            CompositeVideoExporter.defaultDuration(runtime: runtime) > 0,
            "composite video export must derive a positive default duration from source assets"
        )
        if runtime.assetCatalog.spineAsset != nil,
           RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime).isSupported {
            let spineGeometryStatus = SpineGeometryDiagnostics.validationStatus(runtime: runtime)
            check(
                runtime.validationSummary().contains("native spine geometry: \(spineGeometryStatus)")
                    && ["required", "skipped(metal-unavailable)"].contains(spineGeometryStatus),
                "validation summary must mark supported native Spine geometry as required when Metal is available or skipped when headless Metal is unavailable"
            )
            try runtime.requireNativeSpineGeometryIfSupported()
        }
        if compositeQualityReport.isAcceptable == false {
            check(
                compositeQualityReport.text.contains("recommendedExportFps: display-refresh"),
                "low-FPS composite quality report must recommend display-refresh export above 60fps"
            )
            let strictRuntime = try NativeRuntimeCore(config: runtime.config.replacing(strictCompositeQuality: true))
            var strictQualityFailed = false
            do {
                try strictRuntime.requireCompositeQualityIfStrict()
            } catch {
                strictQualityFailed = true
            }
            check(
                strictQualityFailed,
                "strict composite quality must fail for low-FPS composite fallback"
            )
        }
        let capabilitySummary = runtime.runtimeCapabilitiesSummary()
        check(
            capabilitySummary.contains("runtime capabilities"),
            "runtime capabilities summary must expose a stable CLI header"
        )
        check(
            capabilitySummary.contains("render\tcontentAspect\tsupported"),
            "runtime capabilities summary must expose the resolved wallpaper content aspect"
        )
        check(
            capabilitySummary.contains("columns: category\tname\tstatus\tdetail"),
            "runtime capabilities summary must expose tabular columns"
        )
        check(
            capabilitySummary.contains("interaction\tpointerMove/lookDirection"),
            "runtime capabilities summary must report pointer movement support"
        )
        let expectedDesktopItemGate = (runtime.manifest.interactionPolicy?.blockDesktopItems ?? true)
            ? "desktopItemGate=requires-accessibility-trust"
            : "desktopItemGate=not-required"
        check(
            capabilitySummary.contains(expectedDesktopItemGate),
            "runtime capabilities summary must disclose the effective desktop item gate"
        )
        let doctorReport = try RuntimeDoctorReport.make(runtime: runtime, recoveryURL: nil)
        let doctorControlPanelSummary = RuntimeDoctorReport.controlPanelSummary(
            runtime: runtime,
            interactionStatus: "INTERACTION BLOCKED / grant macOS Accessibility permission"
        )
        check(
            doctorReport.contains("wallpaper doctor OK")
                && doctorReport.contains("== validation ==")
                && doctorReport.contains("== runtime-capabilities ==")
                && doctorReport.contains("== render-plan ==")
                && doctorReport.contains("== simulated-render-plan ==")
                && doctorReport.contains("== performance-plan ==")
                && doctorReport.contains("== interaction-plan ==")
                && doctorReport.contains("== renderer-recovery =="),
            "runtime doctor report must combine validation, capability, render, performance, interaction, and recovery diagnostics"
        )
        check(
            doctorControlPanelSummary.contains("doctor: OK")
                && doctorControlPanelSummary.contains("quality:")
                && doctorControlPanelSummary.contains("display:")
                && doctorControlPanelSummary.contains("interaction:"),
            "runtime doctor control-panel summary must expose compact preflight status"
        )
        if let compositeVideo = runtime.assetCatalog.compositeVideoAsset {
            check(
                capabilitySummary.contains("asset\tcompositeVideo\t"),
                "runtime capabilities summary must report compositeVideo asset diagnostics"
            )
            check(
                capabilitySummary.contains("effectiveFps="),
                "video capability diagnostics must expose effective playback FPS"
            )
            if let metadata = try? VideoMetadataInspector.inspect(url: compositeVideo.url),
               let effectiveFps = metadata.effectiveFrameRate(playbackRate: compositeVideo.playbackRate),
               effectiveFps + 0.5 < Double(runtime.renderTargetFps) {
                check(
                    capabilitySummary.contains("asset\tcompositeVideo\twarning"),
                    "low-FPS composite fallback must be reported as a runtime capability warning"
                )
            }
        }
        if runtime.assetCatalog.spineAsset == nil {
            check(
                capabilitySummary.contains("spine\tnativeRenderer\tnot-used"),
                "non-Spine active bundles must mark native Spine renderer unused"
            )
        } else {
            check(
                capabilitySummary.contains("spine\tattachments"),
                "Spine active bundles must report Spine attachment compatibility"
            )
            check(
                capabilitySummary.contains("spine\tnativeCompatibilityGate"),
                "Spine active bundles must expose the native Spine compatibility gate"
            )
        }
        let tapActionDurations = try SpineAnimationDiagnostics.tapActionDurations(runtime: runtime)
        let interactionPlan = InteractionPlan(
            interactions: manifest.interactions,
            policy: manifest.interactionPolicy,
            actionTailDurations: tapActionDurations
        )
        let hasLookDirection = manifest.interactions.contains {
            $0.event == .pointerMove && $0.mapping == "lookDirection"
        }
        if hasLookDirection {
            check(
                SpineInteractionAnimationRoles.lookAnimationNames(from: manifest).isSubset(
                    of: Set(manifest.interactions.flatMap { interaction -> [String] in
                        interaction.actions.map { Array($0.values) } ?? []
                    })
                )
                    && SpineInteractionAnimationRoles.lookAnimationNames(from: manifest).contains("idle") == false,
                "native Spine renderer must identify pointerMove look actions separately from idle for pointer-strength blending"
            )
            check(
                interactionPlan.command(for: CGPoint(x: 0.10, y: 0.50), previousCommand: "idle") != "idle",
                "look-direction interaction plan must resolve off-center pointer movement"
            )
            check(
                interactionPlan.command(for: CGPoint(x: 0.50, y: 0.50), previousCommand: "Right") == "idle",
                "look-direction interaction plan must honor idle dead zone"
            )
            check(
                interactionPlan.command(
                    for: SpineInteractionAnimationRoles.lookNeutralPoint(from: manifest),
                    previousCommand: "Right"
                ) == "idle",
                "look-direction interaction plan must honor pointerMove neutralPoint"
            )
            var convergenceClock: CFTimeInterval = 0
            let interactionController = InteractionController(
                interactions: manifest.interactions,
                policy: manifest.interactionPolicy,
                actionTailDurations: tapActionDurations,
                clock: { convergenceClock }
            )
            interactionController.pointerMoved(to: CGPoint(x: 0.10, y: 0.50))
            var smoothedCommand = interactionController.snapshot().command
            for _ in 0..<12 {
                convergenceClock += 1.0 / 60.0
                smoothedCommand = interactionController.snapshot().command
            }
            check(
                smoothedCommand != "idle",
                "interaction controller must continue smoothing toward the latest pointer target between mouse events"
            )
            let smoothingTarget = CGPoint(x: 0.10, y: 0.50)
            func smoothedPointerAfter(samples: Int, step: CFTimeInterval) -> CGPoint {
                var time: CFTimeInterval = 0
                let controller = InteractionController(
                    interactions: manifest.interactions,
                    policy: manifest.interactionPolicy,
                    actionTailDurations: tapActionDurations,
                    clock: { time }
                )
                controller.pointerMoved(to: smoothingTarget)
                var point = CGPoint(x: 0.5, y: 0.5)
                for _ in 0..<samples {
                    time += step
                    point = controller.snapshot().pointer
                }
                return point
            }
            let smoothedAt60Hz = smoothedPointerAfter(samples: 12, step: 1.0 / 60.0)
            let smoothedAt30Hz = smoothedPointerAfter(samples: 6, step: 1.0 / 30.0)
            check(
                abs(smoothedAt60Hz.x - smoothedAt30Hz.x) < 0.002
                    && abs(smoothedAt60Hz.y - smoothedAt30Hz.y) < 0.002,
                "interaction pointer smoothing must be time-based so 30Hz and 60Hz render cadences converge consistently"
            )
            var snapClock: CFTimeInterval = 0
            let snapController = InteractionController(
                interactions: manifest.interactions.filter { $0.event == .pointerMove },
                policy: manifest.interactionPolicy,
                actionTailDurations: tapActionDurations,
                clock: { snapClock }
            )
            snapController.pointerMoved(to: CGPoint(x: 0.10, y: 0.50))
            snapClock += 1.0 / 60.0
            let beforePointerDown = snapController.snapshot().pointer
            snapController.pointerDown(at: CGPoint(x: 0.90, y: 0.50))
            snapClock += 1.0 / 60.0
            let afterPointerDown = snapController.snapshot().pointer
            check(
                afterPointerDown.x > beforePointerDown.x
                    && afterPointerDown.x < 0.90,
                "pointerDown must not snap smoothed look-direction state to the raw click point"
            )
            if let defaultActionSummary = interactionPlan.defaultActionSummary() {
                var resumeClock: CFTimeInterval = 0
                let resumeController = InteractionController(
                    interactions: manifest.interactions,
                    policy: manifest.interactionPolicy,
                    actionTailDurations: tapActionDurations,
                    clock: { resumeClock }
                )
                let gazePoint = CGPoint(x: 0.10, y: 0.42)
                resumeController.pointerMoved(to: gazePoint)
                for _ in 0..<20 {
                    resumeClock += 1.0 / 60.0
                    _ = resumeController.snapshot()
                }
                check(
                    resumeController.snapshot().command == "Left",
                    "interaction controller must establish look-direction state before pointerDown actions"
                )
                let button = defaultActionSummary.buttons.first ?? .left
                resumeController.pointerDown(at: gazePoint, button: button)
                resumeClock += 1.0 / 60.0
                check(
                    resumeController.snapshot().command == defaultActionSummary.action,
                    "interaction controller must show pointerDown action before returning to gaze state"
                )
                resumeController.pointerUp(at: gazePoint, button: button)
                resumeClock += max(defaultActionSummary.tailSeconds, 0.60) + 0.20
                check(
                    resumeController.snapshot().command == "Left",
                    "interaction controller must resume current look-direction after pointerDown action tail expires"
                )
                var outsideReleaseClock: CFTimeInterval = 0
                let outsideReleaseController = InteractionController(
                    interactions: manifest.interactions,
                    policy: manifest.interactionPolicy,
                    actionTailDurations: tapActionDurations,
                    clock: { outsideReleaseClock }
                )
                outsideReleaseController.pointerMoved(to: gazePoint)
                for _ in 0..<20 {
                    outsideReleaseClock += 1.0 / 60.0
                    _ = outsideReleaseController.snapshot()
                }
                check(
                    outsideReleaseController.snapshot().command == "Left",
                    "interaction controller must establish look-direction before a pointerUp outside content"
                )
                outsideReleaseController.pointerDown(at: gazePoint, button: button)
                outsideReleaseClock += 1.0 / 60.0
                check(
                    outsideReleaseController.snapshot().command == defaultActionSummary.action,
                    "interaction controller must show pointerDown action before an outside-content release"
                )
                outsideReleaseController.pointerUp(button: button)
                outsideReleaseClock += max(defaultActionSummary.tailSeconds, 0.60) + 0.20
                check(
                    outsideReleaseController.snapshot().command == "Left",
                    "pointerUp outside content must release click state without recentering look-direction"
                )
            }
            var interruptedClock: CFTimeInterval = 0
            let interruptedController = InteractionController(
                interactions: manifest.interactions,
                policy: manifest.interactionPolicy,
                actionTailDurations: tapActionDurations,
                clock: { interruptedClock }
            )
            interruptedController.pointerMoved(to: CGPoint(x: 0.10, y: 0.42))
            for _ in 0..<20 {
                interruptedClock += 1.0 / 60.0
                _ = interruptedController.snapshot()
            }
            check(
                interruptedController.snapshot().command == "Left",
                "interaction controller must establish look-direction before a desktop-empty eligibility interruption"
            )
            interruptedController.pointerTrackingInterrupted()
            interruptedClock += 1.0 / 60.0
            check(
                interruptedController.snapshot().command == "Left",
                "blocked app-window or desktop-icon events must not reset established look-direction state"
            )
        } else {
            check(
                interactionPlan.command(for: CGPoint(x: 0.10, y: 0.50), previousCommand: "idle") == "idle",
                "bundles without pointerMove lookDirection must stay idle for pointer movement"
            )
        }
        let hitZoneSummaries = interactionPlan.hitZoneSummaries()
        if manifest.metadata?.id == "sample_imported",
           let headHitZone = hitZoneSummaries.first(where: { $0.id == "head" }) {
            check(
                headHitZone.trigger == .hold,
                "Imported head interaction must stay active while the pointer is held for head-rub gestures"
            )
        }
        let interactionSummary = InteractionPlan.diagnosticSummary(
            interactions: manifest.interactions,
            policy: manifest.interactionPolicy,
            runtimeInteractive: runtime.config.interactive,
            actionTailDurations: tapActionDurations,
            fitMode: runtime.config.fitMode,
            contentAspect: CGFloat(runtime.assetCatalog.contentAspect),
            accessibilityTrusted: true
        )
        check(
            interactionSummary.contains("interaction plan OK")
                && interactionSummary.contains("pointerMoveProbes:")
                && interactionSummary.contains("pointerDownButtons:")
                && interactionSummary.contains("desktopMonitor: ready")
                && interactionSummary.contains("eventGateProbes:")
                && interactionSummary.contains("eventGateTrustedProbes:")
                && interactionSummary.contains("outsideContentTracking: ignore-same-window-outside-content-without-idle-reset")
                && interactionSummary.contains("blockedDesktopEventTracking: ignore-blocked-desktop-events-without-idle-reset")
                && interactionSummary.contains("appWindow=blockedApplicationWindow")
                && interactionSummary.contains("desktopItem=blockedDesktopItem")
                && interactionSummary.contains("clickTimeline:")
                && interactionSummary.contains("pointerSmoothingCadence: time-based")
                && interactionSummary.contains("pointerMoveNeutralPoint:")
                && interactionSummary.contains("pointerMoveDeadZone:")
                && interactionSummary.contains("neutral=idle")
                && interactionSummary.contains("coordinateProbes:")
                && interactionSummary.contains("coordinateProbe: view=32:9"),
            "interaction diagnostics must expose move probes, neutral/dead-zone values, click buttons, event-gate decisions, deterministic click timelines, and display-aspect coordinate probes"
        )
        let missingPermissionInteractionSummary = InteractionPlan.diagnosticSummary(
            interactions: manifest.interactions,
            policy: manifest.interactionPolicy,
            runtimeInteractive: runtime.config.interactive,
            actionTailDurations: tapActionDurations,
            fitMode: runtime.config.fitMode,
            contentAspect: CGFloat(runtime.assetCatalog.contentAspect),
            accessibilityTrusted: false
        )
        check(
            missingPermissionInteractionSummary.contains("desktopMonitor: blocked(accessibility-missing)")
                && missingPermissionInteractionSummary.contains("emptyDesktop=blockedAccessibilityTrust")
                && missingPermissionInteractionSummary.contains("eventGateMissingTrustProbes: accessibilityTrusted=false"),
            "interaction diagnostics must explain when desktop-item-safe interaction is blocked by missing Accessibility permission"
        )
        let neutralProbeSummary = InteractionPlan.probeSummary(
            interactions: manifest.interactions,
            policy: manifest.interactionPolicy,
            runtimeInteractive: runtime.config.interactive,
            point: SpineInteractionAnimationRoles.lookNeutralPoint(from: manifest),
            button: .left,
            actionTailDurations: tapActionDurations
        )
        check(
            neutralProbeSummary.contains("interaction probe OK")
                && neutralProbeSummary.contains("moveCommand: idle")
                && neutralProbeSummary.contains("neutralPoint: 0.500,0.420"),
            "interaction probe diagnostics must expose one-coordinate look-direction resolution"
        )
        let bodyProbeSummary = InteractionPlan.probeSummary(
            interactions: manifest.interactions,
            policy: manifest.interactionPolicy,
            runtimeInteractive: runtime.config.interactive,
            point: CGPoint(x: 0.50, y: 0.70),
            button: .left,
            actionTailDurations: tapActionDurations
        )
        check(
            bodyProbeSummary.contains("hit: zone=body action=boll trigger=hold")
                && bodyProbeSummary.contains("downSnapshot: boll/1"),
            "interaction probe diagnostics must expose hit-zone action and click timeline for one coordinate"
        )
        for hitZoneSummary in hitZoneSummaries {
            check(
                capabilitySummary.contains(hitZoneSummary.detailText),
                "runtime capabilities summary must report resolved hit-zone tail for \(hitZoneSummary.id)"
            )
        }
        if let defaultActionSummary = interactionPlan.defaultActionSummary() {
            check(
                capabilitySummary.contains(defaultActionSummary.detailText),
                "runtime capabilities summary must report resolved default pointerDown tail"
            )
        }
        var manifestActionNames = Set<String>()
        for interaction in manifest.interactions {
            interaction.actions?.values.forEach { manifestActionNames.insert($0) }
            interaction.hitZones?.forEach { manifestActionNames.insert($0.action) }
            if let defaultAction = interaction.defaultAction {
                manifestActionNames.insert(defaultAction.action)
            }
        }
        let spineAnimationPlan = try SpineAnimationDiagnostics.make(runtime: runtime)
        check(
            spineAnimationPlan.contains("spine animation plan OK")
                && spineAnimationPlan.contains("columns: kind\tname\tstatus\tduration\ttimelines\tframes\ttypes\tuses"),
            "Spine animation diagnostics must expose a stable CLI header and columns"
        )
        if runtime.assetCatalog.spineAsset != nil {
            let spineGeometryPlan = try SpineGeometryDiagnostics.make(runtime: runtime)
            check(
                spineGeometryPlan.contains("spine geometry plan OK")
                    && spineGeometryPlan.contains("columns: kind\taction\ttime\tstatus\tbatches\tvertices\tblendModes\tuv\tbounds\tfingerprint\terror"),
                "Spine geometry diagnostics must expose a stable CLI header and columns"
            )
            check(
                spineGeometryPlan.contains("invalidGeometrySamples: none"),
                "Spine geometry diagnostics must render every sampled manifest action pose"
            )
            check(
                spineGeometryPlan.contains("samplePolicy: timeline-keyframes+discrete-transitions"),
                "Spine geometry diagnostics must sample timeline keyframes and discrete attachment transitions"
            )
            check(
                spineGeometryPlan.contains("runtime-cadence")
                    && spineGeometryPlan.contains("poseFps=\(runtime.renderTargetFps)"),
                "Spine geometry diagnostics must sample runtime-cadence pose frames at the render target FPS"
            )
            check(
                spineGeometryPlan.contains("fp="),
                "Spine geometry diagnostics must expose deterministic pose fingerprints"
            )
            if hasLookDirection {
                check(
                    spineGeometryPlan.contains("#lookMix=0.50"),
                    "Spine geometry diagnostics must sample partial look-direction pose mixes"
                )
            }
            check(
                spineAnimationPlan.contains("animation\tidle\tavailable"),
                "Spine animation diagnostics must report idle animation availability"
            )
            check(
                spineAnimationPlan.contains("unsupportedActionTimelines: none"),
                "Spine animation diagnostics must prove manifest actions use supported native timeline families"
            )
            for actionName in manifestActionNames.sorted() {
                check(
                    spineAnimationPlan.contains("action\t\(actionName)\tavailable"),
                    "Spine animation diagnostics must link manifest action \(actionName) to an available animation"
                )
                check(
                    spineAnimationPlan.contains("coverage\t\(actionName)\tcompatible"),
                    "Spine animation diagnostics must mark manifest action \(actionName) native timeline coverage compatible"
                )
                check(
                    spineGeometryPlan.contains("geometry\t\(actionName)\t"),
                    "Spine geometry diagnostics must sample manifest action \(actionName)"
                )
            }
        }
        let defaultActionSummary = interactionPlan.defaultActionSummary()
        if hitZoneSummaries.isEmpty == false || defaultActionSummary != nil {
            for hitZone in hitZoneSummaries {
                let center = CGPoint(
                    x: CGFloat((hitZone.rect[0] + hitZone.rect[2]) / 2.0),
                    y: CGFloat((hitZone.rect[1] + hitZone.rect[3]) / 2.0)
                )
                let acceptedButton = hitZone.buttons.first ?? .left
                let hit = interactionPlan.hitTest(point: center, button: acceptedButton)
                check(
                    hit?.zoneID == hitZone.id && hit?.action == hitZone.action && hit?.trigger == hitZone.trigger,
                    "interaction plan must resolve declared pointerDown hit zone \(hitZone.id)"
                )
                if hitZone.trigger == .tap, let animationTail = tapActionDurations[hitZone.action] {
                    check(
                        hit?.tailSeconds ?? 0 >= animationTail,
                        "tap hit-zone \(hitZone.id) tail must cover its Spine animation duration"
                    )
                }
                let clickController = InteractionController(
                    interactions: manifest.interactions,
                    policy: manifest.interactionPolicy,
                    actionTailDurations: tapActionDurations
                )
                clickController.pointerDown(at: center, button: acceptedButton)
                let downSnapshot = clickController.snapshot()
                clickController.pointerTrackingStopped()
                let stoppedSnapshot = clickController.snapshot()
                check(
                    downSnapshot.command == hitZone.action && downSnapshot.clickPulse > 0,
                    "interaction controller must emit click action \(hitZone.action) on pointerDown for hit zone \(hitZone.id)"
                )
                check(
                    stoppedSnapshot.command == hitZone.action && stoppedSnapshot.clickPulse > 0,
                    "interaction controller must preserve click action \(hitZone.action) when desktop tracking stops after pointerDown"
                )
                clickController.pointerUp(at: center, button: acceptedButton)
                let upSnapshot = clickController.snapshot()
                check(
                    upSnapshot.command == hitZone.action && upSnapshot.clickPulse > 0,
                    "interaction controller must keep click action \(hitZone.action) visible after pointerUp for hit zone \(hitZone.id)"
                )
                let rejectedButton: PointerButton? = if hitZone.buttons.contains(.left), hitZone.buttons.contains(.right) == false {
                    .right
                } else if hitZone.buttons.contains(.right), hitZone.buttons.contains(.left) == false {
                    .left
                } else {
                    nil
                }
                if let rejectedButton {
                    check(
                        interactionPlan.hitTest(point: center, button: rejectedButton) == nil,
                        "interaction plan must reject undeclared hit-zone pointer buttons"
                    )
                }
            }
            if let defaultActionSummary {
                let outsideHitZones = CGPoint(x: 0.02, y: 0.02)
                let acceptedButton = defaultActionSummary.buttons.first ?? .left
                let defaultHit = interactionPlan.hitTest(point: outsideHitZones, button: acceptedButton)
                check(
                    defaultHit?.zoneID == "default"
                        && defaultHit?.action == defaultActionSummary.action
                        && defaultHit?.trigger == defaultActionSummary.trigger,
                    "interaction plan must resolve pointerDown default action outside explicit hit zones"
                )
                let defaultController = InteractionController(
                    interactions: manifest.interactions,
                    policy: manifest.interactionPolicy,
                    actionTailDurations: tapActionDurations
                )
                defaultController.pointerDown(at: outsideHitZones, button: acceptedButton)
                let downSnapshot = defaultController.snapshot()
                defaultController.pointerUp(at: outsideHitZones, button: acceptedButton)
                let upSnapshot = defaultController.snapshot()
                check(
                    downSnapshot.command == defaultActionSummary.action && downSnapshot.clickPulse > 0,
                    "interaction controller must emit pointerDown default action \(defaultActionSummary.action)"
                )
                check(
                    upSnapshot.command == defaultActionSummary.action && upSnapshot.clickPulse > 0,
                    "interaction controller must keep pointerDown default action \(defaultActionSummary.action) visible after pointerUp"
                )
            }
        } else {
            check(
                capabilitySummary.contains("interaction\tpointerDown/hitZones\tnot-used"),
                "bundles without pointerDown hit zones must report hit-zone interaction unused"
            )
        }
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
        let parsedInteractionOverlay = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--interaction-debug-overlay",
            "--validate-only"
        ])
        check(
            parsedInteractionOverlay.interactionDebugOverlay,
            "EngineConfig must parse interaction debug overlay diagnostics"
        )
        let parsedSimulatedRenderPlan = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--simulated-render-plan"
        ])
        check(
            parsedSimulatedRenderPlan.simulatedRenderPlanOnly,
            "EngineConfig must parse simulated multi-display render plan diagnostics"
        )
        check(
            EngineConfig.help.contains("--simulated-render-plan"),
            "EngineConfig help must document simulated multi-display render plan diagnostics"
        )
        check(
            EngineConfig.help.contains("--bundle-library"),
            "EngineConfig help must document bundle library diagnostics"
        )
        check(
            EngineConfig.help.contains("--recovery-plan"),
            "EngineConfig help must document renderer recovery diagnostics"
        )
        check(
            EngineConfig.help.contains("--doctor"),
            "EngineConfig help must document combined runtime doctor diagnostics"
        )
        let parsedSpineSnapshot = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--spine-snapshot", "/tmp/native-spine-snapshot.png",
            "--snapshot-action", "act",
            "--snapshot-time", "1.25",
            "--snapshot-size", "640x360"
        ])
        check(
            parsedSpineSnapshot.spineSnapshotURL?.path == "/tmp/native-spine-snapshot.png"
                && parsedSpineSnapshot.spineSnapshotAction == "act"
                && parsedSpineSnapshot.spineSnapshotTime == 1.25
                && parsedSpineSnapshot.spineSnapshotWidth == 640
                && parsedSpineSnapshot.spineSnapshotHeight == 360,
            "EngineConfig must parse native Spine snapshot diagnostics"
        )
        let parsedWallpaperSnapshot = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--wallpaper-snapshot", "/tmp/wallpaper-snapshot.png",
            "--wallpaper-snapshot-reference", "/tmp/reference.png",
            "--snapshot-action", "idle",
            "--snapshot-time", "2.5",
            "--snapshot-size", "320x180"
        ])
        check(
            parsedWallpaperSnapshot.wallpaperSnapshotURL?.path == "/tmp/wallpaper-snapshot.png"
                && parsedWallpaperSnapshot.wallpaperSnapshotReferenceURL?.path == "/tmp/reference.png"
                && parsedWallpaperSnapshot.spineSnapshotAction == "idle"
                && parsedWallpaperSnapshot.spineSnapshotTime == 2.5
                && parsedWallpaperSnapshot.spineSnapshotWidth == 320
                && parsedWallpaperSnapshot.spineSnapshotHeight == 180,
            "EngineConfig must parse full wallpaper snapshot diagnostics"
        )
        let parsedWallpaperGolden = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--wallpaper-golden-check",
            "--wallpaper-golden-file", "/tmp/wallpaper.golden.json"
        ])
        check(
            parsedWallpaperGolden.wallpaperGoldenCheckOnly
                && parsedWallpaperGolden.wallpaperGoldenURL?.path == "/tmp/wallpaper.golden.json",
            "EngineConfig must parse wallpaper golden fixture diagnostics"
        )
        check(
            runtime.config.replacing(interactionDebugOverlay: true, clearDuration: true).interactionDebugOverlay,
            "EngineConfig.replacing must preserve interaction debug overlay overrides"
        )
        let displaySelectionOptions = [DisplaySelectionOption(title: "System Default Primary", selector: nil)]
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
        let autoForegroundPlan = ForegroundRenderPlan.make(
            runtime: autoRuntime,
            role: RenderDisplayRole(kind: .primary, policy: .full),
            compatibility: RuntimeCapabilities.nativeSpineCompatibility(runtime: autoRuntime)
        )
        if autoRuntime.assetCatalog.spineAsset != nil,
           RuntimeCapabilities.nativeSpineCompatibility(runtime: autoRuntime).isSupported {
            check(
                autoPrimaryRenderPath.contains("foreground=nativeSpine(auto)"),
                "auto render plan must prefer native Spine when the bundle supports it"
            )
            check(
                autoForegroundPlan.usesNativeSpine && autoForegroundPlan.foregroundLabel == "nativeSpine(auto)",
                "shared foreground render plan must match auto native render summary"
            )
            check(
                autoForegroundPlan.allowsVideoOnlyResourceFallback == false
                    && autoPrimaryRenderPath.contains("fallback=resourceBudget->fpsOnly"),
                "auto native render plan must keep Spine active under resource pressure"
            )
        } else if autoRuntime.assetCatalog.compositeVideoAsset != nil {
            check(
                autoPrimaryRenderPath.contains("foreground=compositeVideo(auto)"),
                "auto render plan must use composite fallback when native Spine is unavailable"
            )
            check(
                autoForegroundPlan.usesCompositeVideo && autoForegroundPlan.foregroundLabel == "compositeVideo(auto)",
                "shared foreground render plan must match auto composite render summary"
            )
        } else {
            check(
                autoPrimaryRenderPath.contains("foreground=none(no-foreground-asset)"),
                "auto render plan must report no foreground asset when no Spine/composite foreground exists"
            )
            check(
                autoForegroundPlan.usesNativeSpine == false && autoForegroundPlan.usesCompositeVideo == false,
                "shared foreground render plan must not invent a foreground asset"
            )
        }
        let nativeRuntime = try NativeRuntimeCore(
            config: runtime.config.replacing(foregroundMode: .nativeSpine, clearDuration: true)
        )
        let nativePrimaryRenderPath = DisplayPlanner.renderPathSummary(
            runtime: nativeRuntime,
            role: RenderDisplayRole(kind: .primary, policy: .full)
        )
        if nativeRuntime.assetCatalog.spineAsset != nil,
           RuntimeCapabilities.nativeSpineCompatibility(runtime: nativeRuntime).isSupported {
            check(
                nativePrimaryRenderPath.contains("foreground=nativeSpine"),
                "native render plan must schedule Spine foreground on full primary displays"
            )
            check(
                nativePrimaryRenderPath.contains("fallback=resourceBudget->fpsOnly"),
                "native render plan must not silently replace Spine with composite video"
            )
        } else if nativeRuntime.assetCatalog.compositeVideoAsset != nil,
                  RuntimeCapabilities.nativeSpineCompatibility(runtime: nativeRuntime).isSupported == false {
            check(
                nativePrimaryRenderPath.contains("foreground=compositeFallback(native-unsupported)"),
                "native render plan must use composite fallback when requested native Spine is unsupported"
            )
        } else {
            check(
                nativePrimaryRenderPath.contains("foreground=none(no-spine)")
                    || nativePrimaryRenderPath.contains("fallback=blocked(no-compositeVideo)"),
                "native render plan must report missing or blocked native Spine foreground"
            )
        }
        let nativeSecondaryVideoPath = DisplayPlanner.renderPathSummary(
            runtime: nativeRuntime,
            role: RenderDisplayRole(kind: .secondary, policy: .videoOnly)
        )
        check(
            nativeSecondaryVideoPath.contains("foreground=none(display-policy)"),
            "native render plan must keep video-only secondary displays without Spine foreground"
        )
        check(
            DisplayPlanner.headlessRenderSummary(runtime: nativeRuntime).contains("foregroundMode: native"),
            "render plan summary must expose the requested foreground mode"
        )
        let displaySummary = DisplayPlanner.headlessSummary(runtime: nativeRuntime)
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
        let renderSummary = DisplayPlanner.headlessRenderSummary(runtime: nativeRuntime)
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
        let activeLibraryPath = runtime.config.wallpaperRoot.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let defaultLibraryPaths = [
            ProjectPaths.findBundledWallpapersDirectory(),
            ProjectPaths.findUserWallpapersDirectory(),
            runtime.config.projectRoot.appendingPathComponent("wallpapers")
        ]
            .compactMap { $0?.standardizedFileURL.resolvingSymlinksInPath().path }
        check(ProjectPaths.userWallpapersDirectory() != nil, "user wallpaper library directory must be resolvable")
        try checkRuntimeSettingsPersistence(from: runtime, failures: &failures, checks: &checks)
        check(discoveredBundles.isEmpty == false, "default bundle catalog must discover at least one valid bundle")
        check(Set(discoveredIds).count == discoveredIds.count, "default bundle catalog ids must be unique")
        check(
            discoveredNames == discoveredNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            "default bundle catalog must be sorted by display name"
        )
        if defaultLibraryPaths.contains(activeLibraryPath), let activeBundle = validatedBundle {
            check(
                discoveredBundles.contains {
                    $0.id == activeBundle.id
                        || $0.root.standardizedFileURL.resolvingSymlinksInPath().path == activeBundlePath
                },
                "default bundle catalog must include the active wallpaper bundle identity"
            )
        }
        let bundleMatrix = try BundleValidationMatrix.make(
            projectRoot: runtime.config.projectRoot,
            strictCompositeQuality: false,
            includeInvalid: false
        )
        check(
            bundleMatrix.contains("bundle validation matrix OK")
                && bundleMatrix.contains("sample_imported")
                && bundleMatrix.contains("sample_video")
                && bundleMatrix.contains("sample_static")
                && bundleMatrix.contains("displayModes: primaryOnly+selectedPolicy+allFull"),
            "bundle validation matrix must cover native Spine/video, video-only, static-image, and multi-display simulated render plans"
        )
        check(
            occurrenceCount("displayRefreshFps: primary120+secondary60", in: bundleMatrix) == 3,
            "bundle validation matrix must validate display-refresh FPS matching for every bundled renderer family"
        )
        check(
            bundleMatrix.contains("interactionPlan: active(desktop-empty-only+accessibility-gated)")
                && occurrenceCount("interactionPlan: passive(no-interactions)", in: bundleMatrix) >= 2,
            "bundle validation matrix must validate active desktop-gated interactions and passive no-interaction bundles"
        )
        check(
            bundleMatrix.contains("performancePlan: target=60 fallback=30 budgeted")
                && occurrenceCount("performancePlan: target=30 fallback=15 budgeted", in: bundleMatrix) >= 2,
            "bundle validation matrix must validate performance budget plans for native Spine, video-only, and static-image bundles"
        )
        check(
            occurrenceCount("doctor: pass", in: bundleMatrix) == 3,
            "bundle validation matrix must validate the combined runtime doctor report for every bundled renderer family"
        )
        check(
            occurrenceCount("libraryReport: listed=3 invalid=0 capabilities", in: bundleMatrix) == 3,
            "bundle validation matrix must validate the bundle library list report and capability rows"
        )
        check(
            bundleMatrix.contains("golden: pass fixtures: 3")
                && occurrenceCount("golden: pass fixtures: 1", in: bundleMatrix) >= 2,
            "bundle validation matrix must run bundle-local golden fixtures across native Spine, video-only, and static-image samples"
        )
        check(
            occurrenceCount("installer: importable", in: bundleMatrix) == 3,
            "bundle validation matrix must prove every bundled renderer family can be imported into a user library"
        )
        try checkBundleDiagnostics(from: runtime, failures: &failures, checks: &checks)
        try checkBundleInstallerRoundTrip(from: runtime, failures: &failures, checks: &checks)
        try checkVideoOnlyBundle(from: runtime, failures: &failures, checks: &checks)
        try checkStaticImageBundle(from: runtime, failures: &failures, checks: &checks)
        try checkNonSpineInteractiveBundleRejected(from: runtime, failures: &failures, checks: &checks)
        try checkLinkedMeshSpineCompatibilityBundle(from: runtime, failures: &failures, checks: &checks)
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
        check(initial.videoOnlyFallback == false, "resource governor must not silently switch to video fallback by default", failures: &failures, checks: &checks)

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

        let budgetPlan = runtime.performancePlan
        var thermalState = ProcessInfo.ThermalState.nominal
        let thermalGovernor = ResourceGovernor(
            manifest: runtime.manifest,
            targetFps: runtime.renderTargetFps,
            thermalStateProvider: { thermalState }
        )
        thermalState = .serious
        let seriousThermalFps = thermalGovernor.frameStarted(now: 1.0)
        check(
            seriousThermalFps <= budgetPlan.seriousThermalFps,
            "serious thermal state must clamp rendering to the manifest thermal FPS",
            failures: &failures,
            checks: &checks
        )
        thermalState = .critical
        let criticalThermalFps = thermalGovernor.frameStarted(now: 2.0)
        check(
            thermalGovernor.snapshot.pauseForThermal
                && criticalThermalFps <= 1,
            "critical thermal state must expose pause-for-thermal telemetry and reduce rendering to a minimal cadence",
            failures: &failures,
            checks: &checks
        )

        let highCPUGovernor = ResourceGovernor(
            manifest: runtime.manifest,
            targetFps: runtime.renderTargetFps,
            resourceSampler: { now in
                ResourceGovernorSample(
                    timestamp: now,
                    cpuPercent: budgetPlan.cpuDowngradePercent + 5.0,
                    rssMb: max(budgetPlan.rssTargetMb - 1, 1)
                )
            }
        )
        var highCPUFps = runtime.renderTargetFps
        for second in 0...budgetPlan.cpuDowngradeWindowSeconds {
            highCPUFps = highCPUGovernor.frameStarted(now: TimeInterval(second))
        }
        check(
            highCPUFps <= budgetPlan.fallbackFps,
            "sustained CPU budget pressure must downgrade FPS to the manifest fallback ladder",
            failures: &failures,
            checks: &checks
        )

        let softMemoryGovernor = ResourceGovernor(
            manifest: runtime.manifest,
            targetFps: runtime.renderTargetFps,
            videoOnlyFallbackEnabled: true,
            resourceSampler: { now in
                ResourceGovernorSample(
                    timestamp: now,
                    cpuPercent: budgetPlan.cpuTargetPercent,
                    rssMb: budgetPlan.rssTargetMb
                )
            }
        )
        _ = softMemoryGovernor.frameStarted(now: 0)
        _ = softMemoryGovernor.frameStarted(now: 1)
        check(
            softMemoryGovernor.snapshot.currentFps <= budgetPlan.fallbackFps
                && softMemoryGovernor.snapshot.videoOnlyFallback,
            "RSS target pressure must exhaust the FPS ladder before enabling video-only resource fallback",
            failures: &failures,
            checks: &checks
        )

        let hardMemoryGovernor = ResourceGovernor(
            manifest: runtime.manifest,
            targetFps: runtime.renderTargetFps,
            videoOnlyFallbackEnabled: true,
            resourceSampler: { now in
                ResourceGovernorSample(
                    timestamp: now,
                    cpuPercent: budgetPlan.cpuTargetPercent,
                    rssMb: budgetPlan.rssHardMb
                )
            }
        )
        let hardMemoryFps = hardMemoryGovernor.frameStarted(now: 0)
        check(
            hardMemoryGovernor.snapshot.pauseForResourceBudget
                && hardMemoryFps <= budgetPlan.fallbackFps
                && hardMemoryGovernor.snapshot.videoOnlyFallback == false,
            "RSS hard limit must pause for resource budget instead of silently switching renderer",
            failures: &failures,
            checks: &checks
        )

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
        telemetry.recordInteraction(
            displayName: "Self Test Display",
            role: role,
            snapshot: InteractionMonitorTelemetrySnapshot(
                active: true,
                eventTapActive: false,
                localMonitorActive: true,
                globalMonitorCount: 0,
                lastSource: "nsevent",
                lastEvent: "leftDown",
                lastDecision: "delivered",
                lastPoint: "0.500,0.500",
                lastCommand: "act",
                lastClickPulse: 1.0,
                deliveredEvents: 1,
                blockedEvents: 0
            )
        )
        let interactionTelemetrySummary = telemetry.summary()
        check(
            interactionTelemetrySummary.contains("interaction active")
                && interactionTelemetrySummary.contains("last:nsevent/leftDown/delivered")
                && interactionTelemetrySummary.contains("command:act/1.0")
                && interactionTelemetrySummary.contains("delivered:1"),
            "runtime telemetry summary must expose live desktop interaction monitor status and active command",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.inputSources(
                usesPassiveEventMonitoring: true,
                eventTapStarted: true
            ) == DesktopMouseInteractionMonitor.InputSources(
                useEventTap: true,
                useLocalMonitor: false,
                useGlobalMonitors: false
            ),
            "desktop mouse monitor must avoid duplicate global monitors when passive event tap is active",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.inputSources(
                usesPassiveEventMonitoring: true,
                eventTapStarted: false
            ) == DesktopMouseInteractionMonitor.InputSources(
                useEventTap: false,
                useLocalMonitor: false,
                useGlobalMonitors: true
            ),
            "desktop mouse monitor must fall back to global monitors when passive event tap is unavailable",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.inputSources(
                usesPassiveEventMonitoring: false,
                eventTapStarted: false
            ) == DesktopMouseInteractionMonitor.InputSources(
                useEventTap: false,
                useLocalMonitor: true,
                useGlobalMonitors: false
            ),
            "active diagnostic windows must use local mouse monitoring without global duplicate sources",
            failures: &failures,
            checks: &checks
        )
        check(
            interactionTelemetrySummary.contains("\n"),
            "runtime telemetry summary must keep render and interaction diagnostics on separate lines for control-panel readability",
            failures: &failures,
            checks: &checks
        )
        telemetry.recordInteraction(
            displayName: "Self Test Display",
            role: role,
            snapshot: InteractionMonitorTelemetrySnapshot(
                active: true,
                eventTapActive: false,
                localMonitorActive: false,
                globalMonitorCount: 0,
                lastSource: "direct",
                lastEvent: "leftDown",
                lastDecision: "delivered",
                lastPoint: "0.535,0.305",
                lastCommand: "act",
                lastClickPulse: 1.0,
                deliveredEvents: 1,
                blockedEvents: 0
            )
        )
        check(
            telemetry.summary().contains("last:direct/leftDown/delivered"),
            "runtime telemetry summary must distinguish direct NSResponder wallpaper clicks from monitor-delivered clicks",
            failures: &failures,
            checks: &checks
        )
        let duplicatePoint = CGPoint(x: 120, y: 240)
        check(
            DesktopMouseInteractionMonitor.isDuplicateDiscreteEvent(
                label: "leftDown",
                screenPoint: duplicatePoint,
                previousLabel: "leftDown",
                previousPoint: duplicatePoint,
                elapsedSeconds: 0.01,
                maxInterval: 0.05,
                maxDistanceSquared: 9
            ),
            "desktop mouse monitor must suppress duplicate click events from parallel event sources",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.isDuplicateDiscreteEvent(
                label: "leftDown",
                screenPoint: duplicatePoint,
                previousLabel: "leftDown",
                previousPoint: duplicatePoint,
                elapsedSeconds: 0.08,
                maxInterval: 0.05,
                maxDistanceSquared: 9
            ) == false,
            "desktop mouse monitor must allow later clicks with the same button and position",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.isDuplicateDiscreteEvent(
                label: "move",
                screenPoint: duplicatePoint,
                previousLabel: "move",
                previousPoint: duplicatePoint,
                elapsedSeconds: 0.01,
                maxInterval: 0.05,
                maxDistanceSquared: 9
            ) == false,
            "desktop mouse monitor must not apply click deduplication to pointer tracking",
            failures: &failures,
            checks: &checks
        )
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
        let alwaysPolicy = InteractionPolicy(
            mode: .always,
            blockApplicationWindows: false,
            blockDesktopItems: false,
            pointerSmoothing: nil,
            idleDeadZone: nil,
            directionSwitchMargin: nil,
            defaultClickTailSeconds: nil,
            releaseFadeSeconds: nil
        )
        let primaryRole = RenderDisplayRole(kind: .primary, policy: .full)
        let secondaryRole = RenderDisplayRole(kind: .secondary, policy: .full)
        let blockedPermissionStatus = RuntimeLifecyclePolicy.interactionPermissionStatus(
            runtimeInteractive: true,
            displayRole: primaryRole,
            interactionPolicy: interactivePolicy,
            accessibilityTrusted: false
        )
        check(
            blockedPermissionStatus.canRequestAccessibilityPermission
                && blockedPermissionStatus.text.contains("INTERACTION BLOCKED")
                && blockedPermissionStatus.text.contains("Accessibility"),
            "control panel interaction status must explain Accessibility-blocked desktop interaction",
            failures: &failures,
            checks: &checks
        )
        let secondaryPermissionStatus = RuntimeLifecyclePolicy.interactionPermissionStatus(
            runtimeInteractive: true,
            displayRole: secondaryRole,
            interactionPolicy: interactivePolicy,
            accessibilityTrusted: true
        )
        check(
            secondaryPermissionStatus.canRequestAccessibilityPermission == false
                && secondaryPermissionStatus.text.contains("INTERACTION PASSIVE"),
            "control panel interaction status must mark secondary displays passive instead of requesting permission",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldEnableDesktopInteraction(
                isVisible: true,
                displayRole: primaryRole,
                interactionPolicy: interactivePolicy,
                accessibilityTrusted: true
            ),
            "visible primary full wallpaper must enable desktop interaction monitor",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldEnableDesktopInteraction(
                isVisible: true,
                displayRole: primaryRole,
                interactionPolicy: interactivePolicy,
                accessibilityTrusted: false
            ) == false,
            "desktop-empty interaction with desktop item blocking must fail closed without Accessibility trust",
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
        let noDesktopItemBlockPolicy = InteractionPolicy(
            mode: .desktopEmptyOnly,
            blockApplicationWindows: true,
            blockDesktopItems: false,
            pointerSmoothing: nil,
            idleDeadZone: nil,
            directionSwitchMargin: nil,
            defaultClickTailSeconds: nil,
            releaseFadeSeconds: nil
        )
        let readyPermissionStatus = RuntimeLifecyclePolicy.interactionPermissionStatus(
            runtimeInteractive: true,
            displayRole: primaryRole,
            interactionPolicy: noDesktopItemBlockPolicy,
            accessibilityTrusted: false
        )
        check(
            readyPermissionStatus.canRequestAccessibilityPermission == false
                && readyPermissionStatus.text.contains("INTERACTION READY"),
            "control panel interaction status must not request Accessibility when desktop item blocking is disabled",
            failures: &failures,
            checks: &checks
        )
        let deliveredInteractionSnapshot = InteractionMonitorTelemetrySnapshot(
            active: true,
            eventTapActive: true,
            localMonitorActive: false,
            globalMonitorCount: 0,
            lastSource: "cgevent",
            lastEvent: "leftDown",
            lastDecision: "delivered",
            lastPoint: "0.535,0.305",
            lastCommand: "act",
            lastClickPulse: 1,
            deliveredEvents: 1,
            blockedEvents: 0
        )
        let deliveredControlPanelText = RuntimeLifecyclePolicy.interactionControlPanelText(
            permissionStatus: readyPermissionStatus,
            isHostRunning: true,
            monitorSnapshot: deliveredInteractionSnapshot
        )
        check(
            deliveredControlPanelText.contains("active tap:on")
                && deliveredControlPanelText.contains("last:cgevent/leftDown/delivered")
                && deliveredControlPanelText.contains("command:act"),
            "control panel interaction status must surface live monitor delivery state",
            failures: &failures,
            checks: &checks
        )
        let waitingControlPanelText = RuntimeLifecyclePolicy.interactionControlPanelText(
            permissionStatus: readyPermissionStatus,
            isHostRunning: true,
            monitorSnapshot: nil
        )
        check(
            waitingControlPanelText.contains("monitor starting"),
            "control panel interaction status must distinguish ready policy from missing monitor telemetry",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.interactionControlPanelText(
                permissionStatus: blockedPermissionStatus,
                isHostRunning: true,
                monitorSnapshot: deliveredInteractionSnapshot
            ) == blockedPermissionStatus.text,
            "blocked interaction permission status must not be hidden by stale monitor telemetry",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldEnableDesktopInteraction(
                isVisible: true,
                displayRole: primaryRole,
                interactionPolicy: noDesktopItemBlockPolicy,
                accessibilityTrusted: false
            ),
            "desktop-empty interaction may run without Accessibility trust when desktop item blocking is disabled",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldAcceptLocalWallpaperMouseEvents(
                runtimeInteractive: true,
                displayRole: primaryRole,
                interactionPolicy: noDesktopItemBlockPolicy,
                plainWindowStyle: false
            ) == false,
            "desktop wallpaper windows must stay mouse-passive and rely on passive monitors for click delivery",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldAcceptLocalWallpaperMouseEvents(
                runtimeInteractive: true,
                displayRole: primaryRole,
                interactionPolicy: noDesktopItemBlockPolicy,
                plainWindowStyle: true
            ),
            "plain diagnostic wallpaper windows may accept local mouse events for direct delivery debugging",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldAcceptLocalWallpaperMouseEvents(
                runtimeInteractive: true,
                displayRole: primaryRole,
                interactionPolicy: interactivePolicy,
                plainWindowStyle: false
            ) == false,
            "desktop-item blocking bundles must keep wallpaper windows mouse-passive for Finder icon safety",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldRouteDirectWallpaperMouseEvents(
                interactionPolicy: noDesktopItemBlockPolicy
            ),
            "desktop-empty interaction without desktop item blocking may route direct NSResponder clicks in plain diagnostic windows",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldRouteDirectWallpaperMouseEvents(
                interactionPolicy: interactivePolicy
            ) == false,
            "desktop-empty interaction with desktop item blocking must not route direct NSResponder clicks",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldRouteDirectWallpaperMouseEvents(
                interactionPolicy: alwaysPolicy
            ),
            "always interaction mode may route direct NSResponder clicks in plain diagnostic windows",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldAcceptLocalWallpaperMouseEvents(
                runtimeInteractive: true,
                displayRole: secondaryRole,
                interactionPolicy: noDesktopItemBlockPolicy,
                plainWindowStyle: true
            ) == false,
            "secondary wallpaper windows must stay mouse-passive",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldAcceptLocalWallpaperMouseEvents(
                runtimeInteractive: false,
                displayRole: primaryRole,
                interactionPolicy: noDesktopItemBlockPolicy,
                plainWindowStyle: false
            ) == false,
            "pass-through mode must keep wallpaper windows mouse-passive",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.eventKindName(for: .leftMouseDown) == "leftDown"
                && DesktopMouseInteractionMonitor.eventKindName(for: .leftMouseUp) == "leftUp"
                && DesktopMouseInteractionMonitor.eventKindName(for: .rightMouseDown) == "rightDown"
                && DesktopMouseInteractionMonitor.eventKindName(for: .rightMouseUp) == "rightUp"
                && DesktopMouseInteractionMonitor.eventKindName(for: .mouseMoved) == "move",
            "desktop interaction event tap must map global mouse click and move events",
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
        check(
            DesktopInteractionGate.eligibilityDecision(
                policy: interactivePolicy,
                accessibilityTrusted: true,
                coveredByApplicationWindow: false,
                likelyDesktopItem: false
            ) == .eligible,
            "desktop interaction gate must allow empty desktop when trusted",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopInteractionGate.eligibilityDecision(
                policy: interactivePolicy,
                accessibilityTrusted: false,
                coveredByApplicationWindow: false,
                likelyDesktopItem: false
            ) == .blockedAccessibilityTrust,
            "desktop interaction gate must fail closed when desktop item blocking requires missing Accessibility trust",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopInteractionGate.eligibilityDecision(
                policy: interactivePolicy,
                accessibilityTrusted: true,
                coveredByApplicationWindow: true,
                likelyDesktopItem: false
            ) == .blockedApplicationWindow,
            "desktop interaction gate must block pointer tracking over application windows",
            failures: &failures,
            checks: &checks
        )
        let currentPID = ProcessInfo.processInfo.processIdentifier
        check(
            DesktopInteractionGate.shouldIgnoreApplicationWindowForInteraction(
                ownerPID: currentPID,
                windowName: "Mac Wallpaper Engine Diagnostic",
                currentPID: currentPID
            ),
            "desktop interaction gate must ignore the wallpaper host window itself when scanning covering app windows",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopInteractionGate.shouldIgnoreApplicationWindowForInteraction(
                ownerPID: currentPID,
                windowName: "Mac Wallpaper Engine",
                currentPID: currentPID
            ) == false,
            "desktop interaction gate must treat the control panel as a covering app window, not as empty desktop",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopInteractionGate.shouldIgnoreApplicationWindowForInteraction(
                ownerPID: currentPID + 1,
                windowName: "Other App",
                currentPID: currentPID
            ) == false,
            "desktop interaction gate must not ignore other app windows during empty-desktop checks",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopInteractionGate.eligibilityDecision(
                policy: interactivePolicy,
                accessibilityTrusted: true,
                coveredByApplicationWindow: false,
                likelyDesktopItem: true
            ) == .blockedDesktopItem,
            "desktop interaction gate must block pointer tracking over Finder desktop items",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopInteractionGate.eligibilityDecision(
                policy: noDesktopItemBlockPolicy,
                accessibilityTrusted: false,
                coveredByApplicationWindow: false,
                likelyDesktopItem: true
            ) == .eligible,
            "desktop interaction gate must ignore desktop item hits when item blocking is disabled",
            failures: &failures,
            checks: &checks
        )
        let containMapper = InteractionCoordinateMapper(fitMode: .contain, contentAspect: 16.0 / 9.0)
        let ultrawideAspect: CGFloat = 21.0 / 9.0
        check(
            containMapper.mapWindowNormalizedPoint(CGPoint(x: 0.5, y: 0.5), viewAspect: ultrawideAspect) == CGPoint(x: 0.5, y: 0.5),
            "contain interaction mapper must keep content center stable on ultrawide displays",
            failures: &failures,
            checks: &checks
        )
        check(
            containMapper.mapWindowNormalizedPoint(CGPoint(x: 0.05, y: 0.5), viewAspect: ultrawideAspect) == nil,
            "contain interaction mapper must reject clicks outside the visible wallpaper content",
            failures: &failures,
            checks: &checks
        )
        let fillMapper = InteractionCoordinateMapper(fitMode: .fill, contentAspect: 16.0 / 9.0)
        let fillMapped = fillMapper.mapWindowNormalizedPoint(CGPoint(x: 0.5, y: 0.0), viewAspect: ultrawideAspect)
        check(
            fillMapped.map { abs($0.x - 0.5) < 0.001 && $0.y > 0.0 && $0.y < 0.2 } ?? false,
            "fill interaction mapper must translate window points into cropped content coordinates",
            failures: &failures,
            checks: &checks
        )
    }

    private static func checkRuntimeSettingsPersistence(
        from runtime: NativeRuntimeCore,
        failures: inout [String],
        checks: inout Int
    ) throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineSettingsSelfTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let settingsURL = tempDirectory.appendingPathComponent("settings.json")
        let tunedConfig = runtime.config.replacing(
            displayMode: .all,
            primaryDisplaySelector: "displayID:42",
            interactive: false,
            renderFps: 60,
            matchDisplayRefresh: true,
            playbackRateOverride: 1.15,
            fitMode: .fill,
            foregroundMode: .nativeSpine,
            clearDuration: true,
            launchControlPanel: true,
            launchWallpaper: true
        )

        try RuntimeSettingsStore.save(config: tunedConfig, to: settingsURL)
        let loaded = try RuntimeSettingsStore.load(from: settingsURL)
        check(
            loaded.wallpaperRootPath == tunedConfig.wallpaperRoot.standardizedFileURL.path,
            "runtime settings must persist selected wallpaper root",
            failures: &failures,
            checks: &checks
        )
        check(loaded.displayMode == .all, "runtime settings must persist display mode", failures: &failures, checks: &checks)
        check(
            loaded.primaryDisplaySelector == "displayID:42",
            "runtime settings must persist primary display selector",
            failures: &failures,
            checks: &checks
        )
        check(loaded.interactive == false, "runtime settings must persist interaction toggle", failures: &failures, checks: &checks)
        check(loaded.renderFps == 60, "runtime settings must persist fixed FPS fallback", failures: &failures, checks: &checks)
        check(loaded.matchDisplayRefresh == true, "runtime settings must persist display-refresh FPS mode", failures: &failures, checks: &checks)
        check(
            abs((loaded.playbackRateOverride ?? 0) - 1.15) < 0.001,
            "runtime settings must persist playback rate",
            failures: &failures,
            checks: &checks
        )
        check(loaded.fitMode == .fill, "runtime settings must persist fit mode", failures: &failures, checks: &checks)
        check(
            loaded.foregroundMode == .nativeSpine,
            "runtime settings must persist foreground mode",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeSettingsStore.validWallpaperRoot(from: loaded)?.standardizedFileURL.path == tunedConfig.wallpaperRoot.standardizedFileURL.path,
            "runtime settings must only restore a validated wallpaper root",
            failures: &failures,
            checks: &checks
        )

        let environmentKey = RuntimeSettingsStore.environmentSettingsPath
        let previousEnvironmentValue = getenv(environmentKey).map { String(cString: $0) }
        setenv(environmentKey, settingsURL.path, 1)
        defer {
            if let previousEnvironmentValue {
                setenv(environmentKey, previousEnvironmentValue, 1)
            } else {
                unsetenv(environmentKey)
            }
        }

        let parsed = try EngineConfig.parse([])
        check(
            parsed.wallpaperRoot.standardizedFileURL.path == tunedConfig.wallpaperRoot.standardizedFileURL.path,
            "EngineConfig must restore persisted wallpaper root when no explicit root is passed",
            failures: &failures,
            checks: &checks
        )
        check(parsed.displayMode == .all, "EngineConfig must restore persisted display mode", failures: &failures, checks: &checks)
        check(
            parsed.primaryDisplaySelector == "displayID:42",
            "EngineConfig must restore persisted primary display selector",
            failures: &failures,
            checks: &checks
        )
        check(parsed.interactive == false, "EngineConfig must restore persisted interaction toggle", failures: &failures, checks: &checks)
        check(parsed.renderFps == 60, "EngineConfig must restore persisted fixed FPS fallback", failures: &failures, checks: &checks)
        check(parsed.matchDisplayRefresh, "EngineConfig must restore persisted display-refresh FPS mode", failures: &failures, checks: &checks)
        check(
            abs((parsed.playbackRateOverride ?? 0) - 1.15) < 0.001,
            "EngineConfig must restore persisted playback rate",
            failures: &failures,
            checks: &checks
        )
        check(parsed.fitMode == .fill, "EngineConfig must restore persisted fit mode", failures: &failures, checks: &checks)
        check(
            parsed.foregroundMode == .nativeSpine,
            "EngineConfig must restore persisted foreground mode",
            failures: &failures,
            checks: &checks
        )

        let diagnosticParse = try EngineConfig.parse(["--validate-only"])
        check(
            diagnosticParse.displayMode == .primaryOnly,
            "diagnostic validation must ignore persisted display mode",
            failures: &failures,
            checks: &checks
        )
        check(
            diagnosticParse.primaryDisplaySelector == nil,
            "diagnostic validation must ignore persisted primary display selector",
            failures: &failures,
            checks: &checks
        )
        check(
            diagnosticParse.interactive,
            "diagnostic validation must ignore persisted interaction toggle",
            failures: &failures,
            checks: &checks
        )
        check(
            diagnosticParse.renderFps == nil,
            "diagnostic validation must ignore persisted FPS override",
            failures: &failures,
            checks: &checks
        )
        check(
            diagnosticParse.playbackRateOverride == nil,
            "diagnostic validation must ignore persisted playback-rate override",
            failures: &failures,
            checks: &checks
        )
        check(
            diagnosticParse.fitMode == .contain,
            "diagnostic validation must ignore persisted fit mode",
            failures: &failures,
            checks: &checks
        )
        check(
            diagnosticParse.foregroundMode == .automatic,
            "diagnostic validation must ignore persisted foreground mode",
            failures: &failures,
            checks: &checks
        )
        let compositeQualityParse = try EngineConfig.parse(["--composite-quality-plan", "--strict-composite-quality"])
        check(
            compositeQualityParse.compositeQualityPlanOnly,
            "EngineConfig must parse composite quality plan diagnostics",
            failures: &failures,
            checks: &checks
        )
        check(
            compositeQualityParse.strictCompositeQuality,
            "EngineConfig must parse strict composite quality gate",
            failures: &failures,
            checks: &checks
        )
        check(
            compositeQualityParse.foregroundMode == .automatic,
            "composite quality diagnostics must ignore persisted foreground mode",
            failures: &failures,
            checks: &checks
        )
        let interactionPlanParse = try EngineConfig.parse(["--interaction-plan"])
        check(
            interactionPlanParse.interactionPlanOnly,
            "EngineConfig must parse interaction plan diagnostics",
            failures: &failures,
            checks: &checks
        )
        check(
            interactionPlanParse.foregroundMode == .automatic,
            "interaction diagnostics must ignore persisted foreground mode",
            failures: &failures,
            checks: &checks
        )
        let doctorParse = try EngineConfig.parse(["--doctor"])
        check(
            doctorParse.doctorReportOnly,
            "EngineConfig must parse combined runtime doctor diagnostics",
            failures: &failures,
            checks: &checks
        )
        check(
            doctorParse.foregroundMode == .automatic,
            "runtime doctor diagnostics must ignore persisted foreground mode",
            failures: &failures,
            checks: &checks
        )
        let interactionProbeParse = try EngineConfig.parse(["--probe-interaction", "0.5,0.42", "--probe-button", "left"])
        check(
            interactionProbeParse.interactionProbePoint == CGPoint(x: 0.5, y: 0.42)
                && interactionProbeParse.interactionProbeButton == .left,
            "EngineConfig must parse single-point interaction probes",
            failures: &failures,
            checks: &checks
        )
        check(
            interactionProbeParse.foregroundMode == .automatic,
            "interaction probes must ignore persisted foreground mode",
            failures: &failures,
            checks: &checks
        )
        let spineAnimationPlanParse = try EngineConfig.parse(["--spine-animation-plan"])
        check(
            spineAnimationPlanParse.spineAnimationPlanOnly,
            "EngineConfig must parse Spine animation plan diagnostics",
            failures: &failures,
            checks: &checks
        )
        check(
            spineAnimationPlanParse.foregroundMode == .automatic,
            "Spine animation diagnostics must ignore persisted foreground mode",
            failures: &failures,
            checks: &checks
        )

        let overridden = try EngineConfig.parse(["--foreground-mode", "composite", "--fps", "30"])
        check(
            overridden.foregroundMode == .compositeVideo,
            "explicit CLI foreground mode must override persisted settings",
            failures: &failures,
            checks: &checks
        )
        check(
            overridden.renderFps == 30,
            "explicit CLI FPS must override persisted settings",
            failures: &failures,
            checks: &checks
        )
        let displayFpsOverride = try EngineConfig.parse(["--fps", "display"])
        check(
            displayFpsOverride.matchDisplayRefresh && displayFpsOverride.renderFps == nil,
            "EngineConfig must support display-refresh FPS mode",
            failures: &failures,
            checks: &checks
        )
        let legacyHighFpsOverride = try EngineConfig.parse(["--fps", "120"])
        check(
            legacyHighFpsOverride.matchDisplayRefresh && legacyHighFpsOverride.renderFps == nil,
            "EngineConfig must map legacy FPS values above 60 to display-refresh mode",
            failures: &failures,
            checks: &checks
        )
        let highRefreshFpsOverride = try EngineConfig.parse(["--fps", "144"])
        check(
            highRefreshFpsOverride.matchDisplayRefresh && highRefreshFpsOverride.renderFps == nil,
            "EngineConfig must map arbitrary high-refresh FPS values to display-refresh mode",
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

        let activeBundle = try WallpaperBundleCatalog.requireValidBundle(runtime.config.wallpaperRoot)
        let sourceImage = activeBundle.previewURL
            ?? runtime.assetCatalog.staticImageAssetURL
            ?? runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg")
        guard FileManager.default.fileExists(atPath: sourceImage.path) else {
            failures.append("bundle catalog fixtures require active bundle preview or staticImage asset")
            return
        }
        let overlappingHitZoneRoot = fixtureParent.appendingPathComponent("overlapping_hit_zone_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: overlappingHitZoneRoot,
            imageSource: sourceImage,
            id: "overlapping_hit_zone_bundle",
            title: "Overlapping Hit Zone Bundle",
            interactionsJSON: """
            [
              {
                "event": "pointerDown",
                "hitZones": [
                  {
                    "id": "head",
                    "rect": [0.20, 0.20, 0.70, 0.70],
                    "action": "act",
                    "trigger": "tap",
                    "tailSeconds": 0.5,
                    "buttons": ["left"]
                  },
                  {
                    "id": "body",
                    "rect": [0.50, 0.50, 0.90, 0.90],
                    "action": "boll",
                    "trigger": "tap",
                    "tailSeconds": 0.5,
                    "buttons": ["left"]
                  }
                ]
              }
            ]
            """
        )
        let overlappingHitZoneDiagnostic = WallpaperBundleCatalog.diagnoseBundle(overlappingHitZoneRoot)
        check(
            overlappingHitZoneDiagnostic.status == .invalid
                && (overlappingHitZoneDiagnostic.errorMessage?.contains("hitZones head and body overlap") == true),
            "bundle diagnostics must reject ambiguous overlapping pointerDown hit zones before runtime hit-test order can hide them",
            failures: &failures,
            checks: &checks
        )

        let incompleteLookDirectionRoot = fixtureParent.appendingPathComponent("incomplete_look_direction_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: incompleteLookDirectionRoot,
            imageSource: sourceImage,
            id: "incomplete_look_direction_bundle",
            title: "Incomplete Look Direction Bundle",
            interactionsJSON: """
            [
              {
                "event": "pointerMove",
                "mapping": "lookDirection",
                "actions": {
                  "left": "Left",
                  "right": "Right",
                  "idle": "idle"
                }
              }
            ]
            """
        )
        let incompleteLookDirectionDiagnostic = WallpaperBundleCatalog.diagnoseBundle(incompleteLookDirectionRoot)
        check(
            incompleteLookDirectionDiagnostic.status == .invalid
                && (incompleteLookDirectionDiagnostic.errorMessage?.contains("pointerMove lookDirection actions missing required key") == true)
                && (incompleteLookDirectionDiagnostic.errorMessage?.contains("down") == true)
                && (incompleteLookDirectionDiagnostic.errorMessage?.contains("up") == true),
            "bundle diagnostics must reject incomplete lookDirection action maps before missing directions silently fall back to idle",
            failures: &failures,
            checks: &checks
        )

        let unknownLookDirectionRoot = fixtureParent.appendingPathComponent("unknown_look_direction_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: unknownLookDirectionRoot,
            imageSource: sourceImage,
            id: "unknown_look_direction_bundle",
            title: "Unknown Look Direction Bundle",
            interactionsJSON: """
            [
              {
                "event": "pointerMove",
                "mapping": "lookDirection",
                "actions": {
                  "left": "Left",
                  "right": "Right",
                  "up": "Up",
                  "down": "Down",
                  "idle": "idle",
                  "diagonal": "Diagonal"
                }
              }
            ]
            """
        )
        let unknownLookDirectionDiagnostic = WallpaperBundleCatalog.diagnoseBundle(unknownLookDirectionRoot)
        check(
            unknownLookDirectionDiagnostic.status == .invalid
                && (unknownLookDirectionDiagnostic.errorMessage?.contains("pointerMove lookDirection actions contain unsupported key") == true)
                && (unknownLookDirectionDiagnostic.errorMessage?.contains("diagonal") == true),
            "bundle diagnostics must reject unsupported lookDirection action keys before unknown directions are ignored",
            failures: &failures,
            checks: &checks
        )

        let missingPointerMoveMappingRoot = fixtureParent.appendingPathComponent("missing_pointer_move_mapping_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: missingPointerMoveMappingRoot,
            imageSource: sourceImage,
            id: "missing_pointer_move_mapping_bundle",
            title: "Missing Pointer Move Mapping Bundle",
            interactionsJSON: """
            [
              {
                "event": "pointerMove",
                "actions": {
                  "left": "Left",
                  "right": "Right",
                  "up": "Up",
                  "down": "Down",
                  "idle": "idle"
                }
              }
            ]
            """
        )
        let missingPointerMoveMappingDiagnostic = WallpaperBundleCatalog.diagnoseBundle(missingPointerMoveMappingRoot)
        check(
            missingPointerMoveMappingDiagnostic.status == .invalid
                && (missingPointerMoveMappingDiagnostic.errorMessage?.contains("pointerMove interaction requires mapping") == true),
            "bundle diagnostics must reject pointerMove interactions whose mapping is implicit because the native schema only supports explicit lookDirection",
            failures: &failures,
            checks: &checks
        )

        let duplicateHitZoneIDRoot = fixtureParent.appendingPathComponent("duplicate_hit_zone_id_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: duplicateHitZoneIDRoot,
            imageSource: sourceImage,
            id: "duplicate_hit_zone_id_bundle",
            title: "Duplicate Hit Zone ID Bundle",
            interactionsJSON: """
            [
              {
                "event": "pointerDown",
                "hitZones": [
                  {
                    "id": "target",
                    "rect": [0.10, 0.10, 0.30, 0.30],
                    "action": "act",
                    "trigger": "tap",
                    "tailSeconds": 0.5,
                    "buttons": ["left"]
                  },
                  {
                    "id": "target",
                    "rect": [0.70, 0.70, 0.90, 0.90],
                    "action": "boll",
                    "trigger": "tap",
                    "tailSeconds": 0.5,
                    "buttons": ["left"]
                  }
                ]
              }
            ]
            """
        )
        let duplicateHitZoneIDDiagnostic = WallpaperBundleCatalog.diagnoseBundle(duplicateHitZoneIDRoot)
        check(
            duplicateHitZoneIDDiagnostic.status == .invalid
                && (duplicateHitZoneIDDiagnostic.errorMessage?.contains("hitZone ids must be unique") == true)
                && (duplicateHitZoneIDDiagnostic.errorMessage?.contains("target") == true),
            "bundle diagnostics must reject duplicate hit-zone ids before logs and probes become ambiguous",
            failures: &failures,
            checks: &checks
        )

        let invalidInteractiveRoot = fixtureParent.appendingPathComponent("interactive_static_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: invalidInteractiveRoot,
            imageSource: sourceImage,
            id: "interactive_static_bundle",
            title: "Interactive Static Bundle",
            interactionsJSON: """
            [
              {
                "event": "pointerDown",
                "defaultAction": {
                  "action": "act",
                  "trigger": "tap",
                  "tailSeconds": 0.5,
                  "buttons": ["left"]
                }
              }
            ]
            """
        )
        let invalidInteractiveDiagnostic = WallpaperBundleCatalog.diagnoseBundle(invalidInteractiveRoot)
        check(
            invalidInteractiveDiagnostic.status == .invalid
                && (invalidInteractiveDiagnostic.errorMessage?.contains("interactions require a Spine asset") == true),
            "bundle diagnostics must reject non-Spine bundles that declare interaction actions",
            failures: &failures,
            checks: &checks
        )
        checks += 1
        do {
            _ = try BundleValidationMatrix.make(
                projectRoot: nil,
                strictCompositeQuality: false,
                includeInvalid: true,
                bundleDirectories: [invalidInteractiveRoot.deletingLastPathComponent()]
            )
            failures.append("bundle validation matrix must fail invalid-only libraries with diagnostic reasons")
        } catch {
            check(
                error.localizedDescription.contains("interactive_static_bundle")
                    && error.localizedDescription.contains("interactions require a Spine asset"),
                "bundle validation matrix must expose invalid-only library diagnostics",
                failures: &failures,
                checks: &checks
            )
        }
        let looseValidationRoot = fixtureParent.appendingPathComponent("loose_validation_bundle", isDirectory: true)
        let looseValidationManifest = try writeStaticImageBundleFixture(
            root: looseValidationRoot,
            imageSource: sourceImage,
            id: "loose_validation_bundle",
            title: "Loose Validation Bundle"
        )
        var looseValidationJSON = try String(contentsOf: looseValidationManifest)
        looseValidationJSON = looseValidationJSON.replacingOccurrences(
            of: "\"bundleRootOnly\": true",
            with: "\"bundleRootOnly\": false"
        )
        try Data(looseValidationJSON.utf8).write(to: looseValidationManifest, options: .atomic)
        let looseValidationDiagnostic = WallpaperBundleCatalog.diagnoseBundle(looseValidationRoot)
        check(
            looseValidationDiagnostic.status == .invalid
                && (looseValidationDiagnostic.errorMessage?.contains("bundleRootOnly") == true),
            "bundle validation must require bundleRootOnly=true for portable packages",
            failures: &failures,
            checks: &checks
        )

        let permissiveLayerRoot = fixtureParent.appendingPathComponent("permissive_layer_bundle", isDirectory: true)
        let permissiveLayerManifest = try writeStaticImageBundleFixture(
            root: permissiveLayerRoot,
            imageSource: sourceImage,
            id: "permissive_layer_bundle",
            title: "Permissive Layer Bundle"
        )
        var permissiveLayerJSON = try String(contentsOf: permissiveLayerManifest)
        permissiveLayerJSON = permissiveLayerJSON.replacingOccurrences(
            of: "\"rejectUnknownLayerTypes\": true",
            with: "\"rejectUnknownLayerTypes\": false"
        )
        try Data(permissiveLayerJSON.utf8).write(to: permissiveLayerManifest, options: .atomic)
        let permissiveLayerDiagnostic = WallpaperBundleCatalog.diagnoseBundle(permissiveLayerRoot)
        check(
            permissiveLayerDiagnostic.status == .invalid
                && (permissiveLayerDiagnostic.errorMessage?.contains("rejectUnknownLayerTypes") == true),
            "bundle validation must require rejectUnknownLayerTypes=true for deterministic renderer dispatch",
            failures: &failures,
            checks: &checks
        )

        let absoluteAssetPathRoot = fixtureParent.appendingPathComponent("absolute_asset_path_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: absoluteAssetPathRoot,
            imageSource: sourceImage,
            id: "absolute_asset_path_bundle",
            title: "Absolute Asset Path Bundle",
            staticImagePath: sourceImage.path
        )
        let absoluteAssetPathDiagnostic = WallpaperBundleCatalog.diagnoseBundle(absoluteAssetPathRoot)
        check(
            absoluteAssetPathDiagnostic.status == .invalid
                && (absoluteAssetPathDiagnostic.errorMessage?.contains("asset path must be relative") == true),
            "bundle validation must reject absolute manifest asset paths",
            failures: &failures,
            checks: &checks
        )

        let escapingAssetPathRoot = fixtureParent.appendingPathComponent("escaping_asset_path_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: escapingAssetPathRoot,
            imageSource: sourceImage,
            id: "escaping_asset_path_bundle",
            title: "Escaping Asset Path Bundle",
            staticImagePath: "../outside.jpg"
        )
        let escapingAssetPathDiagnostic = WallpaperBundleCatalog.diagnoseBundle(escapingAssetPathRoot)
        check(
            escapingAssetPathDiagnostic.status == .invalid
                && (escapingAssetPathDiagnostic.errorMessage?.contains("asset escapes bundle root") == true),
            "bundle validation must reject manifest asset paths that escape the bundle root",
            failures: &failures,
            checks: &checks
        )

        let internalSymlinkRoot = fixtureParent.appendingPathComponent("internal_symlink_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: internalSymlinkRoot,
            imageSource: sourceImage,
            id: "internal_symlink_bundle",
            title: "Internal Symlink Bundle"
        )
        let internalSymlink = internalSymlinkRoot.appendingPathComponent("assets/symlink.jpg")
        try fileManager.createSymbolicLink(at: internalSymlink, withDestinationURL: sourceImage)
        let internalSymlinkDiagnostic = WallpaperBundleCatalog.diagnoseBundle(internalSymlinkRoot)
        check(
            internalSymlinkDiagnostic.status == .invalid
                && (internalSymlinkDiagnostic.errorMessage?.contains("symlinked entries") == true),
            "bundle validation must reject internal symlink entries before import or packaging",
            failures: &failures,
            checks: &checks
        )

        let symlinkedBundleTarget = fixtureParent.appendingPathComponent("symlink_target_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: symlinkedBundleTarget,
            imageSource: sourceImage,
            id: "symlink_target_bundle",
            title: "Symlink Target Bundle"
        )
        let symlinkedBundleRoot = fixtureParent.appendingPathComponent("symlink_root_bundle", isDirectory: true)
        try fileManager.createSymbolicLink(at: symlinkedBundleRoot, withDestinationURL: symlinkedBundleTarget)
        let symlinkedRootDiagnostic = WallpaperBundleCatalog.diagnoseBundle(symlinkedBundleRoot)
        check(
            symlinkedRootDiagnostic.status == .invalid
                && (symlinkedRootDiagnostic.errorMessage?.contains("symlinked bundle roots") == true),
            "bundle validation must reject symlinked bundle roots before resolving them",
            failures: &failures,
            checks: &checks
        )

        let duplicateBundleRoot = fixtureParent.appendingPathComponent("duplicate_id_bundle", isDirectory: true)
        try writeStaticImageBundleFixture(
            root: duplicateBundleRoot,
            imageSource: sourceImage,
            id: activeBundle.id,
            title: "Duplicate ID Bundle"
        )

        let combinedDiagnostics = WallpaperBundleCatalog.diagnose(in: [
            runtime.config.wallpaperRoot.deletingLastPathComponent(),
            fixtureParent
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
        check(
            combinedDiagnostics.contains {
                $0.status == .invalid
                    && $0.root.standardizedFileURL.resolvingSymlinksInPath().path
                        == duplicateBundleRoot.standardizedFileURL.resolvingSymlinksInPath().path
                    && ($0.errorMessage?.contains("Duplicate wallpaper bundle id \(activeBundle.id)") == true)
            },
            "bundle diagnostics must report duplicate bundle ids instead of silently hiding library entries",
            failures: &failures,
            checks: &checks
        )
        let listReport = BundleListReport.make(
            diagnostics: combinedDiagnostics,
            includeInvalid: true,
            includeCapabilities: true
        )
        check(
            listReport.contains("bundle list")
                && listReport.contains("validBundles:")
                && listReport.contains("invalidDiagnostics:")
                && listReport.contains("columns: status\tid\ttitle\troot\tcapabilities\terror")
                && listReport.contains("quality: ok\tnone")
                && listReport.contains("duplicate_id_bundle")
                && listReport.contains("Duplicate wallpaper bundle id \(activeBundle.id)"),
            "bundle list report must expose counts, stable columns, capabilities, and invalid diagnostic errors",
            failures: &failures,
            checks: &checks
        )
        checks += 1
        do {
            _ = try BundleValidationMatrix.make(
                projectRoot: nil,
                strictCompositeQuality: false,
                includeInvalid: false,
                bundleDirectories: [
                    runtime.config.wallpaperRoot.deletingLastPathComponent(),
                    fixtureParent
                ]
            )
            failures.append("bundle validation matrix must fail mixed valid+invalid libraries before packaging")
        } catch {
            check(
                error.localizedDescription.contains("Duplicate wallpaper bundle id \(activeBundle.id)")
                    && error.localizedDescription.contains("duplicate_id_bundle"),
                "bundle validation matrix must fail mixed libraries when a duplicate id diagnostic exists",
                failures: &failures,
                checks: &checks
            )
        }
    }

    private static func checkBundleInstallerRoundTrip(
        from runtime: NativeRuntimeCore,
        failures: inout [String],
        checks: inout Int
    ) throws {
        let sourceImage = WallpaperBundleCatalog.validateBundle(runtime.config.wallpaperRoot)?.previewURL
            ?? runtime.assetCatalog.staticImageAssetURL
            ?? runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg")
        checks += 1
        guard FileManager.default.fileExists(atPath: sourceImage.path) else {
            failures.append("bundle installer fixture requires active bundle preview or staticImage asset")
            return
        }

        let fileManager = FileManager.default
        let fixtureParent = fileManager.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineInstallerSelfTest-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = fixtureParent.appendingPathComponent("source_bundle", isDirectory: true)
        let libraryRoot = fixtureParent.appendingPathComponent("library", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: fixtureParent)
        }

        _ = try writeStaticImageBundleFixture(
            root: sourceRoot,
            imageSource: sourceImage,
            id: "selftest_install_round_trip",
            title: "Self Test Install Round Trip"
        )
        try Data().write(to: sourceRoot.appendingPathComponent(".DS_Store"), options: .atomic)
        try Data().write(to: sourceRoot.appendingPathComponent("._preview.jpg"), options: .atomic)
        try fileManager.createDirectory(at: sourceRoot.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data().write(to: sourceRoot.appendingPathComponent(".git/config"), options: .atomic)
        try fileManager.createSymbolicLink(
            at: sourceRoot.appendingPathComponent(".git/metadata-link"),
            withDestinationURL: sourceRoot.appendingPathComponent("preview.jpg")
        )
        try fileManager.createDirectory(at: sourceRoot.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
        try Data().write(to: sourceRoot.appendingPathComponent("__MACOSX/._wallpaper.native.json"), options: .atomic)

        let installedBundle = try WallpaperBundleInstaller.install(
            sourceRoot: sourceRoot,
            libraryDirectory: libraryRoot
        )
        check(installedBundle.id == "selftest_install_round_trip", "bundle installer must preserve manifest metadata.id", failures: &failures, checks: &checks)
        check(installedBundle.root.lastPathComponent == "selftest_install_round_trip", "bundle installer must use safe metadata id as destination directory", failures: &failures, checks: &checks)
        check(FileManager.default.fileExists(atPath: installedBundle.manifestURL.path), "bundle installer must copy wallpaper.native.json", failures: &failures, checks: &checks)
        check(
            FileManager.default.fileExists(atPath: installedBundle.root.appendingPathComponent(".DS_Store").path) == false,
            "bundle installer must skip .DS_Store metadata during import",
            failures: &failures,
            checks: &checks
        )
        check(
            FileManager.default.fileExists(atPath: installedBundle.root.appendingPathComponent("._preview.jpg").path) == false
                && FileManager.default.fileExists(atPath: installedBundle.root.appendingPathComponent(".git").path) == false
                && FileManager.default.fileExists(atPath: installedBundle.root.appendingPathComponent("__MACOSX").path) == false,
            "bundle installer must skip development/archive metadata during import",
            failures: &failures,
            checks: &checks
        )

        let discoveredInstalledBundles = WallpaperBundleCatalog.discover(in: libraryRoot)
        check(
            discoveredInstalledBundles.contains { $0.id == installedBundle.id && $0.root.path == installedBundle.root.path },
            "bundle installer import must be discoverable from the target library",
            failures: &failures,
            checks: &checks
        )
        let installedLibraryMatrix = try BundleValidationMatrix.make(
            projectRoot: nil,
            strictCompositeQuality: false,
            includeInvalid: false,
            bundleDirectories: [libraryRoot]
        )
        check(
            installedLibraryMatrix.contains("selftest_install_round_trip"),
            "bundle validation matrix must support a caller-provided wallpaper library",
            failures: &failures,
            checks: &checks
        )

        checks += 1
        do {
            _ = try WallpaperBundleInstaller.install(sourceRoot: sourceRoot, libraryDirectory: libraryRoot)
            failures.append("bundle installer must reject duplicate manifest ids in the target library")
        } catch {
            // Expected: duplicate bundle ids are rejected before copying over an installed bundle.
        }

        let alreadyInstalled = try WallpaperBundleInstaller.install(
            sourceRoot: installedBundle.root,
            libraryDirectory: libraryRoot
        )
        check(
            alreadyInstalled.root.path == installedBundle.root.path,
            "bundle installer must treat already-library-local bundles as already installed",
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
        check(abs(videoOnlyRuntime.assetCatalog.contentAspect - (16.0 / 9.0)) < 0.01, "video-only bundle must derive interaction content aspect from video metadata", failures: &failures, checks: &checks)
        check(videoOnlyRuntime.manifest.layers.count == 1, "video-only bundle must preserve its single video layer", failures: &failures, checks: &checks)
        check(videoOnlyRuntime.validationSummary().contains("spine json: none"), "video-only validation summary must report no Spine asset", failures: &failures, checks: &checks)
        check(videoOnlyRuntime.validationSummary().contains("native spine geometry: not-used"), "video-only validation summary must skip native Spine geometry preflight", failures: &failures, checks: &checks)
        let videoOnlySummary = try WallpaperBundleCatalog.requireValidBundle(fixtureRoot)
        check(videoOnlySummary.capabilities.nativeSpineStatus == "not-used", "video-only bundle catalog must mark native Spine unused", failures: &failures, checks: &checks)
        check(videoOnlySummary.capabilities.interactionRequirement == "none", "video-only bundle catalog must mark interaction permission as unused", failures: &failures, checks: &checks)
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
        let sourceImage = WallpaperBundleCatalog.validateBundle(runtime.config.wallpaperRoot)?.previewURL
            ?? runtime.assetCatalog.staticImageAssetURL
            ?? runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg")
        checks += 1
        guard FileManager.default.fileExists(atPath: sourceImage.path) else {
            failures.append("static image fixture requires active bundle preview or staticImage asset")
            return
        }

        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineStaticSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: fixtureRoot)
        }

        let manifestURL = try writeStaticImageBundleFixture(
            root: fixtureRoot,
            imageSource: sourceImage,
            id: "selftest_static_image",
            title: "Self Test Static Image"
        )
        let fixtureImage = fixtureRoot.appendingPathComponent("assets/poster.jpg")

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
        check(staticRuntime.assetCatalog.contentAspect > 0, "static image bundle must derive interaction content aspect from image metadata", failures: &failures, checks: &checks)
        check(staticRuntime.assetCatalog.videoAsset == nil, "static image bundle must not require a video asset", failures: &failures, checks: &checks)
        check(staticRuntime.assetCatalog.spineAsset == nil, "static image bundle must not require a Spine asset", failures: &failures, checks: &checks)
        check(staticRuntime.manifest.layers.first?.type == .staticImage, "static image bundle must preserve static_image layer type", failures: &failures, checks: &checks)
        check(staticRuntime.validationSummary().contains("static image: \(fixtureImage.path)"), "static image validation summary must report the image asset", failures: &failures, checks: &checks)
        check(staticRuntime.validationSummary().contains("native spine geometry: not-used"), "static image validation summary must skip native Spine geometry preflight", failures: &failures, checks: &checks)
        check(staticRuntime.runtimeCapabilitiesSummary().contains("layer\tstatic_image\tsupported"), "static image capability summary must report static_image support", failures: &failures, checks: &checks)
        check(staticRuntime.runtimeCapabilitiesSummary().contains("interaction\tpolicy\tnot-used\tno declared interactions"), "static image capability summary must not imply desktop interaction monitoring", failures: &failures, checks: &checks)
        let staticRenderPlan = DisplayPlanner.headlessRenderSummary(runtime: staticRuntime)
        check(staticRenderPlan.contains("background=staticImage:poster.jpg"), "static image render plan must use the static image background", failures: &failures, checks: &checks)
        check(staticRenderPlan.contains("interaction=passive(no-interactions)"), "static image render plan must keep interaction disabled when no actions are declared", failures: &failures, checks: &checks)
        let staticSummary = try WallpaperBundleCatalog.requireValidBundle(fixtureRoot)
        check(staticSummary.previewURL?.lastPathComponent == "poster.jpg", "static image bundle catalog preview must fall back to staticImage asset", failures: &failures, checks: &checks)
        check(staticSummary.capabilities.briefText.contains("assets: static"), "static image bundle catalog must expose static capability", failures: &failures, checks: &checks)
    }

    private static func checkNonSpineInteractiveBundleRejected(
        from runtime: NativeRuntimeCore,
        failures: inout [String],
        checks: inout Int
    ) throws {
        let sourceImage = WallpaperBundleCatalog.validateBundle(runtime.config.wallpaperRoot)?.previewURL
            ?? runtime.assetCatalog.staticImageAssetURL
            ?? runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg")
        checks += 1
        guard FileManager.default.fileExists(atPath: sourceImage.path) else {
            failures.append("interactive static fixture requires active bundle preview or staticImage asset")
            return
        }

        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineInteractiveStaticSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: fixtureRoot)
        }

        let manifestURL = try writeStaticImageBundleFixture(
            root: fixtureRoot,
            imageSource: sourceImage,
            id: "selftest_interactive_static_invalid",
            title: "Self Test Interactive Static Invalid",
            interactionsJSON: """
            [
              {
                "event": "pointerDown",
                "defaultAction": {
                  "action": "act",
                  "trigger": "tap",
                  "tailSeconds": 0.5,
                  "buttons": ["left"]
                }
              }
            ]
            """
        )

        checks += 1
        do {
            _ = try NativeRuntimeCore(config: runtime.config.replacing(
                wallpaperRoot: fixtureRoot,
                manifestURL: manifestURL,
                clearDuration: true,
                launchControlPanel: false,
                launchWallpaper: false
            ))
            failures.append("native-metal bundles must reject declared interactions when no Spine asset is present")
        } catch {
            check(
                error.localizedDescription.contains("interactions require a Spine asset"),
                "non-Spine interaction rejection must explain the missing Spine action target",
                failures: &failures,
                checks: &checks
            )
        }
    }

    @discardableResult
    private static func writeStaticImageBundleFixture(
        root: URL,
        imageSource: URL,
        id: String,
        title: String,
        interactionsJSON: String = "[]",
        staticImagePath: String = "assets/poster.jpg"
    ) throws -> URL {
        let fileManager = FileManager.default
        let assetsRoot = root.appendingPathComponent("assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let fixtureImage = assetsRoot.appendingPathComponent("poster.jpg")
        do {
            try fileManager.linkItem(at: imageSource, to: fixtureImage)
        } catch {
            try fileManager.copyItem(at: imageSource, to: fixtureImage)
        }

        let manifestURL = root.appendingPathComponent("wallpaper.native.json")
        let idLiteral = try jsonStringLiteral(id)
        let titleLiteral = try jsonStringLiteral(title)
        let staticImagePathLiteral = try jsonStringLiteral(staticImagePath)
        let manifestJSON = """
        {
          "schemaVersion": "macos-wallpaper-native.v2",
          "metadata": {
            "id": \(idLiteral),
            "title": \(titleLiteral)
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
              "path": \(staticImagePathLiteral)
            }
          },
          "layers": [
            {
              "id": "poster-layer",
              "type": "static_image",
              "asset": "poster"
            }
          ],
          "interactions": \(interactionsJSON),
          "validation": {
            "bundleRootOnly": true,
            "requirePremultipliedAlpha": false,
            "requireSpineVersion": "4.2.x",
            "rejectUnknownLayerTypes": true
          }
        }
        """
        try Data(manifestJSON.utf8).write(to: manifestURL, options: .atomic)
        return manifestURL
    }

    private static func jsonStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw EngineError.manifest("Could not encode fixture JSON string.")
        }
        return text
    }

    private static func checkLinkedMeshSpineCompatibilityBundle(
        from runtime: NativeRuntimeCore,
        failures: inout [String],
        checks: inout Int
    ) throws {
        checks += 1
        guard let sourceVideo = runtime.assetCatalog.compositeVideoAssetURL ?? runtime.assetCatalog.videoAssetURL else {
            failures.append("linkedmesh Spine fixture requires an active video asset")
            return
        }

        checks += 1
        guard let sourceTexture = runtime.assetCatalog.spineAsset?.textures.first else {
            failures.append("linkedmesh Spine fixture requires an active Spine texture")
            return
        }

        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineLinkedMeshSpineSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: fixtureRoot)
        }

        let assetsRoot = fixtureRoot.appendingPathComponent("assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let fixtureVideo = assetsRoot.appendingPathComponent("background.mp4")
        let fixtureTexture = assetsRoot.appendingPathComponent("texture.png")
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
        let atlasText = """
        texture.png
        size: 64,64

        base
        bounds: 0,0,64,64
        offsets: 0,0,64,64

        linked
        bounds: 0,0,64,64
        offsets: 0,0,64,64
        """
        try Data(atlasText.utf8).write(to: fixtureAtlas, options: .atomic)

        let fixtureSpineJSON = assetsRoot.appendingPathComponent("character.json")
        let spineJSON = """
        {
          "skeleton": {
            "spine": "4.2.43",
            "x": -50,
            "y": -50,
            "width": 100,
            "height": 100
          },
          "bones": [
            {
              "name": "root"
            }
          ],
          "slots": [
            {
              "name": "slot",
              "bone": "root",
              "attachment": "linked"
            }
          ],
          "skins": [
            {
              "name": "default",
              "attachments": {
                "slot": {
                  "base": {
                    "type": "mesh",
                    "path": "base",
                    "uvs": [0, 0, 1, 0, 1, 1, 0, 1],
                    "triangles": [0, 1, 2, 2, 3, 0],
                    "vertices": [-50, -50, 50, -50, 50, 50, -50, 50],
                    "hull": 4
                  },
                  "linked": {
                    "type": "linkedmesh",
                    "path": "linked",
                    "parent": "base"
                  }
                }
              }
            }
          ],
          "animations": {
            "idle": {}
          }
        }
        """
        try Data(spineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)

        let manifestURL = fixtureRoot.appendingPathComponent("wallpaper.native.json")
        let manifestJSON = """
        {
          "schemaVersion": "macos-wallpaper-native.v2",
          "metadata": {
            "id": "selftest_linkedmesh_spine",
            "title": "Self Test Linked Mesh Spine"
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
            "maxTextureDimension": 8192,
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
              "id": "linkedMeshCharacter",
              "version": "4.2.43",
              "json": "assets/character.json",
              "atlas": "assets/character.atlas",
              "textures": [
                "assets/texture.png"
              ],
              "premultipliedAlpha": false
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
              "asset": "linkedMeshCharacter",
              "renderingMode": "setup-mesh"
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

        let linkedMeshRuntime = try NativeRuntimeCore(config: runtime.config.replacing(
            wallpaperRoot: fixtureRoot,
            manifestURL: manifestURL,
            displayMode: .primaryAnimated,
            renderFps: 30,
            foregroundMode: .nativeSpine,
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))

        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: linkedMeshRuntime)
        check(compatibility.isSupported, "same-skin linkedmesh fixture must pass native compatibility gate", failures: &failures, checks: &checks)
        check(compatibility.reasonText == "supported", "same-skin linkedmesh compatibility must not report unsupported reasons", failures: &failures, checks: &checks)
        check(
            linkedMeshRuntime.runtimeCapabilitiesSummary().contains("spine\tattachments\tsupported\tused=linkedmesh,mesh"),
            "runtime capabilities must report same-skin linkedmesh attachments as supported",
            failures: &failures,
            checks: &checks
        )
        if SpineGeometryDiagnostics.validationStatus(runtime: linkedMeshRuntime) == "required" {
            try linkedMeshRuntime.requireNativeSpineGeometryIfSupported()
        }
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
        let eventOnlySpineJSON = """
        {
          "skeleton": {
            "spine": "4.2.43"
          },
          "animations": {
            "idle": {
              "events": [
                {
                  "time": 0,
                  "name": "marker"
                }
              ]
            }
          },
          "events": {
            "marker": {}
          }
        }
        """
        try Data(eventOnlySpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)

        let manifestURL = fixtureRoot.appendingPathComponent("wallpaper.native.json")
        let eventOnlyManifestJSON = """
        {
          "schemaVersion": "macos-wallpaper-native.v2",
          "metadata": {
            "id": "selftest_event_only_spine",
            "title": "Self Test Event Only Spine"
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
            "spine": {
              "id": "eventOnlyCharacter",
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
              "asset": "eventOnlyCharacter",
              "renderingMode": "setup-mesh"
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
        try Data(eventOnlyManifestJSON.utf8).write(to: manifestURL, options: .atomic)
        let eventOnlyManifest = try ManifestLoader.load(url: manifestURL, bundleRoot: fixtureRoot)
        let eventOnlyCompatibility = RuntimeCapabilities.nativeSpineCompatibility(
            manifest: eventOnlyManifest,
            bundleRoot: fixtureRoot
        )
        check(
            eventOnlyCompatibility.isSupported,
            "non-visual Spine event timelines must not force composite fallback",
            failures: &failures,
            checks: &checks
        )
        let eventOnlySummary = try WallpaperBundleCatalog.requireValidBundle(fixtureRoot)
        check(
            eventOnlySummary.capabilities.nativeSpineStatus == "supported"
                && eventOnlySummary.capabilities.fallbackStatus == "not-needed",
            "catalog must keep event-only Spine bundles native-supported without requiring a composite fallback",
            failures: &failures,
            checks: &checks
        )
        let eventOnlyRuntime = try NativeRuntimeCore(config: runtime.config.replacing(
            wallpaperRoot: fixtureRoot,
            manifestURL: manifestURL,
            displayMode: .primaryAnimated,
            renderFps: 30,
            foregroundMode: .automatic,
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        check(
            eventOnlyRuntime.runtimeCapabilitiesSummary()
                .contains("spine\teventsAudioSequence\tsupported\tevents=ignored"),
            "capability diagnostics must mark non-visual Spine events as ignored instead of unsupported",
            failures: &failures,
            checks: &checks
        )

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
        check(compatibility.reasonText.contains("audio event playback"), "compatibility gate must report unsupported audio event playback", failures: &failures, checks: &checks)
        check(compatibility.reasonText.contains("sequence attachments"), "compatibility gate must report unsupported sequence attachments", failures: &failures, checks: &checks)
        check(unsupportedRuntime.validationSummary().contains("native spine geometry: skipped(native-unsupported)"), "unsupported native Spine validation summary must skip geometry preflight", failures: &failures, checks: &checks)
        try unsupportedRuntime.requireNativeSpineGeometryIfSupported()
        check(
            unsupportedRuntime.runtimeCapabilitiesSummary().contains("spine\tnativeCompatibilityGate\tunsupported"),
            "unsupported Spine capability summary must mark nativeCompatibilityGate unsupported",
            failures: &failures,
            checks: &checks
        )
        check(
            unsupportedRuntime.runtimeCapabilitiesSummary().contains("spine\tnativeRenderer\tunsupported\tfallback=compositeVideo"),
            "unsupported Spine capability summary must mark nativeRenderer unsupported while naming the composite fallback",
            failures: &failures,
            checks: &checks
        )
        let unsupportedSummary = try WallpaperBundleCatalog.requireValidBundle(fixtureRoot)
        check(unsupportedSummary.capabilities.nativeSpineStatus == "unsupported", "catalog must surface unsupported native Spine status", failures: &failures, checks: &checks)
        check(
            unsupportedSummary.capabilities.nativeSpineSummary.contains("audio event playback")
                && unsupportedSummary.capabilities.briefText.contains("native: unsupported("),
            "catalog capability summaries must explain why native Spine is unsupported",
            failures: &failures,
            checks: &checks
        )
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

    private static func occurrenceCount(_ needle: String, in haystack: String) -> Int {
        guard needle.isEmpty == false else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }
}
