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
        check(RuntimeLifecyclePolicy.startupFailurePolicy == "control-panel-recovery", "startup host failures must have an explicit recovery policy")
        check(
            RuntimeLifecyclePolicy.visibilityPausePolicy == "pause-when-occluded-or-fullscreen-obscured",
            "window visibility pause policy must be explicit"
        )
        check(
            RuntimeLifecyclePolicy.desktopItemTrustPolicy == "fail-closed-without-accessibility-trust",
            "desktop item interaction policy must fail closed without Accessibility trust"
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
            let interactionController = InteractionController(
                interactions: manifest.interactions,
                policy: manifest.interactionPolicy,
                actionTailDurations: tapActionDurations
            )
            interactionController.pointerMoved(to: CGPoint(x: 0.10, y: 0.50))
            var smoothedCommand = interactionController.snapshot().command
            for _ in 0..<12 {
                smoothedCommand = interactionController.snapshot().command
            }
            check(
                smoothedCommand != "idle",
                "interaction controller must continue smoothing toward the latest pointer target between mouse events"
            )
        } else {
            check(
                interactionPlan.command(for: CGPoint(x: 0.10, y: 0.50), previousCommand: "idle") == "idle",
                "bundles without pointerMove lookDirection must stay idle for pointer movement"
            )
        }
        let hitZoneSummaries = interactionPlan.hitZoneSummaries()
        let interactionSummary = InteractionPlan.diagnosticSummary(
            interactions: manifest.interactions,
            policy: manifest.interactionPolicy,
            runtimeInteractive: runtime.config.interactive,
            actionTailDurations: tapActionDurations
        )
        check(
            interactionSummary.contains("interaction plan OK")
                && interactionSummary.contains("pointerMoveProbes:")
                && interactionSummary.contains("pointerDownButtons:"),
            "interaction diagnostics must expose move probes and click buttons"
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
        try checkBundleDiagnostics(from: runtime, failures: &failures, checks: &checks)
        try checkVideoOnlyBundle(from: runtime, failures: &failures, checks: &checks)
        try checkStaticImageBundle(from: runtime, failures: &failures, checks: &checks)
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
                globalMonitorCount: 4,
                lastSource: "nsevent",
                lastEvent: "leftDown",
                lastDecision: "delivered",
                lastPoint: "0.500,0.500",
                deliveredEvents: 1,
                blockedEvents: 0
            )
        )
        let interactionTelemetrySummary = telemetry.summary()
        check(
            interactionTelemetrySummary.contains("interaction active")
                && interactionTelemetrySummary.contains("last:nsevent/leftDown/delivered")
                && interactionTelemetrySummary.contains("delivered:1"),
            "runtime telemetry summary must expose live desktop interaction monitor status",
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
            ),
            "interactive primary wallpaper windows must accept local mouse events so click reactions do not depend only on global monitors",
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
            "desktop-empty interaction without desktop item blocking must route direct NSResponder clicks",
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
            "always interaction mode must route direct NSResponder clicks",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.shouldAcceptLocalWallpaperMouseEvents(
                runtimeInteractive: true,
                displayRole: secondaryRole,
                interactionPolicy: noDesktopItemBlockPolicy,
                plainWindowStyle: false
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
        let sourceImage = runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg")
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
            imageSource: runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg"),
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
        let staticSummary = try WallpaperBundleCatalog.requireValidBundle(fixtureRoot)
        check(staticSummary.previewURL?.lastPathComponent == "poster.jpg", "static image bundle catalog preview must fall back to staticImage asset", failures: &failures, checks: &checks)
        check(staticSummary.capabilities.briefText.contains("assets: static"), "static image bundle catalog must expose static capability", failures: &failures, checks: &checks)
    }

    @discardableResult
    private static func writeStaticImageBundleFixture(
        root: URL,
        imageSource: URL,
        id: String,
        title: String
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
        check(unsupportedRuntime.validationSummary().contains("native spine geometry: skipped(native-unsupported)"), "unsupported native Spine validation summary must skip geometry preflight", failures: &failures, checks: &checks)
        try unsupportedRuntime.requireNativeSpineGeometryIfSupported()
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
