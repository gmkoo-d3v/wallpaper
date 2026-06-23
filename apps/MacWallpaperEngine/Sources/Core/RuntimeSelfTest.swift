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
        let featureScanCacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineFeatureScanCacheSelfTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: featureScanCacheRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: featureScanCacheRoot)
        }
        let featureScanCacheSpine = featureScanCacheRoot.appendingPathComponent("cache-probe.json")
        let featureScanCacheSpineJSON = """
        {
          "skeleton": { "spine": "4.2.43" },
          "bones": [
            { "name": "root" }
          ],
          "slots": [
            { "name": "slot", "bone": "root", "attachment": "region" }
          ],
          "skins": [
            {
              "name": "default",
              "attachments": {
                "slot": {
                  "region": {
                    "type": "region",
                    "path": "region",
                    "width": 1,
                    "height": 1
                  }
                }
              }
            }
          ],
          "animations": { "idle": {} }
        }
        """
        try Data(featureScanCacheSpineJSON.utf8).write(to: featureScanCacheSpine, options: .atomic)
        let featureScanCacheDiagnostics = try RuntimeCapabilities.spineFeatureScanCacheDiagnostics(
            url: featureScanCacheSpine
        ) {
            let mutated = featureScanCacheSpineJSON.replacingOccurrences(
                of: "{ \"name\": \"slot\", \"bone\": \"root\", \"attachment\": \"region\" }",
                with: "{ \"name\": \"slot\", \"bone\": \"root\", \"attachment\": \"region\", \"blend\": \"multiply\" }"
            ) + "\n "
            try Data(mutated.utf8).write(to: featureScanCacheSpine, options: .atomic)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 4_102_444_800)],
                ofItemAtPath: featureScanCacheSpine.path
            )
        }
        check(
            featureScanCacheDiagnostics.beforeEntries == 0
                && featureScanCacheDiagnostics.firstMisses == 1
                && featureScanCacheDiagnostics.firstStores == 1
                && featureScanCacheDiagnostics.secondHits == 1
                && featureScanCacheDiagnostics.secondMisses == 1
                && featureScanCacheDiagnostics.secondStores == 1
                && featureScanCacheDiagnostics.invalidatedAfterMutation
                && featureScanCacheDiagnostics.secondEvictions == 0,
            "Spine feature scan cache must miss/store once, hit on the same file metadata, and invalidate after file metadata changes"
        )

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
            displayRefreshRuntime.renderTargetFps(displayRefreshFps: 144) == manifest.runtime.maxFps,
            "display-refresh FPS mode must honor the wallpaper manifest maxFps on high-refresh displays"
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
            RuntimeLifecyclePolicy.displayReplacementOverlapSeconds > 0
                && RuntimeLifecyclePolicy.displayReplacementOverlapSeconds <= 0.5,
            "display replacement overlap must keep the old wallpaper visible briefly while replacement windows warm up"
        )
        check(
            RuntimeLifecyclePolicy.displayReplacementOverlapSeconds >= 0.2,
            "display replacement overlap must leave enough time for replacement Metal views to submit a first drawable"
        )
        check(
            RuntimeLifecyclePolicy.displayReplacementRevealTimeoutSeconds >= RuntimeLifecyclePolicy.displayReplacementOverlapSeconds
                && RuntimeLifecyclePolicy.displayReplacementRevealTimeoutSeconds <= 2,
            "display replacement reveal timeout must keep old wallpaper visible while replacement Metal views submit their first drawable"
        )
        check(
            RuntimeLifecyclePolicy.visibleWindowWarmupRetryCount >= 3
                && RuntimeLifecyclePolicy.visibleWindowWarmupRetryCount <= 12,
            "visible window warmup must retry enough times for slow Metal drawable creation without looping indefinitely"
        )
        check(
            RuntimeLifecyclePolicy.visibleWindowWarmupRetryInterval > 0
                && RuntimeLifecyclePolicy.visibleWindowWarmupRetryInterval <= 0.1,
            "visible window warmup retry interval must stay short enough to avoid visible black-screen gaps"
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
            RuntimeLifecyclePolicy.runningHostReplacementPolicy == "start-replacement-before-retiring-current-host",
            "running host replacement must start the new wallpaper before retiring the current host to avoid black-screen gaps"
        )
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
            RuntimeLifecyclePolicy.desktopItemTrustPolicy == "no-permission-best-effort-desktop-items",
            "desktop item interaction policy must avoid mandatory Accessibility trust"
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
            RuntimeLifecyclePolicy.accessibilityPromptPolicy == "never-request-accessibility",
            "wallpaper startup and control panel refresh must not trigger macOS Accessibility prompts"
        )
        check(
            DesktopInteractionGate.accessibilityTrustCheckPolicy == "check-without-prompt",
            "startup Accessibility trust checks must use no-prompt probes"
        )
        let accessibilityStatusText = InputDiagnostics.statusText()
        check(
            accessibilityStatusText.contains("input permission diagnostics OK")
                && accessibilityStatusText.contains("accessibilityStatus:")
                && accessibilityStatusText.contains("accessibilityPromptSupported: false")
                && accessibilityStatusText.contains("inputPolicy: no-permission-best-effort")
                && accessibilityStatusText.contains("appPath:"),
            "input diagnostics must expose current trust state without prompting"
        )
        check(
            DesktopMouseInteractionMonitor.canStartEventTapWithoutPrompt(
                usesPassiveEventMonitoring: true,
                accessibilityTrusted: false
            ) == false,
            "passive wallpaper input must not create a CGEvent tap before Accessibility trust is already granted"
        )
        check(
            DesktopMouseInteractionMonitor.canStartEventTapWithoutPrompt(
                usesPassiveEventMonitoring: true,
                accessibilityTrusted: true
            ),
            "passive wallpaper input may use a CGEvent tap only if Accessibility trust already exists"
        )
        check(
            DesktopMouseInteractionMonitor.canStartEventTapWithoutPrompt(
                usesPassiveEventMonitoring: false,
                accessibilityTrusted: true
            ) == false,
            "plain diagnostic windows must use local NSResponder mouse delivery instead of a CGEvent tap"
        )
        check(
            RuntimeLifecyclePolicy.rendererWarmupFallbackPolicy == "preview-last-frame-or-neutral-background-before-first-pause",
            "renderer warmup must avoid transient black frames while the first video frame is unavailable or the first pause arrives early"
        )
        check(
            RuntimeLifecyclePolicy.visibleWindowFirstDrawPolicy == "preorder-and-postorder-bounded-visible-draw-retries",
            "wallpaper windows must attempt first draw before and after ordering front"
        )
        check(
            RuntimeLifecyclePolicy.windowWarmupMoments(startHidden: false) == [.beforeOrderFront, .afterOrderFront]
                && RuntimeLifecyclePolicy.windowWarmupMoments(startHidden: true).isEmpty,
            "visible wallpaper windows must warm up before orderFront and retry afterward while hidden smoke runs stay hidden"
        )
        check(
            MetalCompositor.pausedFirstFramePolicy == "draw-static-fallback-before-pausing",
            "renderer must submit a fallback drawable before pause/resource paths can leave a new window black"
        )
        check(
            MetalCompositor.telemetryPublishIntervalSeconds >= 0.25
                && MetalCompositor.telemetryPublishIntervalSeconds <= 1.0,
            "renderer telemetry must be throttled so p95/resource snapshots do not run at frame rate"
        )
        check(
            VideoFrameSource.pixelBufferOutputPolicy == "bgra-metal-iosurface-suppressed-player-rendering",
            "video frame source must request Metal/IOSurface pixel buffers and suppress redundant AVPlayer rendering"
        )
        check(
            RenderBlendMode(spineBlend: " Additive ") == .additive
                && RenderBlendMode(spineBlend: "") == .normal
                && RenderBlendMode(spineBlend: "hard-light") == nil,
            "Spine blend mode parsing must normalize supported values while rejecting unsupported values"
        )
        check(
            SpineSetupPoseRenderer.timelineSamplingPolicy == "parse-sorted/no-per-sample-sort",
            "native Spine renderer must sort timeline frames once during parse instead of sorting every sampled pose"
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
            ControlPanelWindowController.pageLabels == ["Run", "Controls", "Library", "Diagnostics"],
            "control panel must split runtime, controls, library, and diagnostics into compact in-app pages"
        )
        check(
            ControlPanelWindowController.initialWindowSize.width <= 640
                && ControlPanelWindowController.initialWindowSize.height <= 320,
            "control panel must keep the main window compact after moving verbose state into in-app pages and tooltips"
        )
        check(
            ControlPanelWindowController.foregroundModeLabels == ["Auto Native", "Fallback Video", "Force Native"]
                && ControlPanelWindowController.foregroundModeTooltips.count == ControlPanelWindowController.foregroundModeLabels.count
                && ControlPanelWindowController.foregroundModeTooltips[0].contains("Native Spine")
                && ControlPanelWindowController.foregroundModeTooltips[1].contains("lower-fidelity composite video fallback"),
            "control panel foreground labels must make composite a fallback path, not the normal playback mode"
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
            ControlPanelWindowController.interactionStatusMaximumLines == 1
                && ControlPanelWindowController.doctorStatusMaximumLines >= 5,
            "control panel must keep main interaction status compact while preserving detailed doctor diagnostics"
        )
        check(
            ControlPanelWindowController.compactInteractionStatus(
                "READY / desktop-empty-only / global:2 / cmd act"
            ) == "READY / global:2 / act",
            "control panel main page must hide policy plumbing while preserving actionable live interaction state"
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
            primaryOnlySimulatedPlan.contains("displayMode: selectedOnly")
                && occurrenceCount("primary:\(manifest.displayPolicy.primary.rawValue)", in: primaryOnlySimulatedPlan) == 1,
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
            selectedPolicySimulatedPlan.contains("displayMode: selectedPolicy")
                && occurrenceCount("secondary:\(manifest.displayPolicy.secondary.rawValue)", in: selectedPolicySimulatedPlan) == 2,
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
            allDisplaysSimulatedPlan.contains("displayMode: allFull")
                && occurrenceCount("secondary:full", in: allDisplaysSimulatedPlan) == 2,
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
        } else if activeNativeCompatibility.isSupported == false {
            "unsupported"
        } else if activeNativeCompatibility.degradations.isEmpty == false {
            "degraded"
        } else {
            "supported"
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
        if activeNativeCompatibility.degradations.isEmpty == false {
            check(
                validatedBundle?.capabilities.nativeSpineSummary.contains("degraded constraint usages") == true,
                "bundle catalog must expose degraded native Spine reasons when native support remains available"
            )
        }
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
            check(
                ControlPanelWindowController
                    .bundlePopupTitle(for: validatedBundle)
                    .contains("/\(validatedBundle.capabilities.sourceDerivationBadge)]"),
                "control panel bundle popup title must expose source derivation status before selection"
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
        check(
            runtime.validationSummary().contains("nativeSpineTransitionPolicy: default=")
                && runtime.validationSummary().contains(" action=")
                && runtime.validationSummary().contains(" release="),
            "validation summary must expose role-based native Spine transition policy"
        )
        if let compositeVideo = runtime.assetCatalog.compositeVideoAsset,
           let backgroundVideo = runtime.assetCatalog.videoAsset,
           let compositeMetadata = try? VideoMetadataInspector.inspect(url: compositeVideo.url),
           let backgroundMetadata = try? VideoMetadataInspector.inspect(url: backgroundVideo.url) {
            let compositeWidth = abs(compositeMetadata.presentationSize.width)
            let compositeHeight = abs(compositeMetadata.presentationSize.height)
            let backgroundWidth = abs(backgroundMetadata.presentationSize.width)
            let backgroundHeight = abs(backgroundMetadata.presentationSize.height)
            if compositeWidth < backgroundWidth || compositeHeight < backgroundHeight {
                check(
                    compositeQualityReport.status == "degraded"
                        && compositeQualityReport.isAcceptable
                        && compositeQualityReport.recommendations.contains(where: { $0.contains("below backgroundVideo size=") }),
                    "lower-resolution composite fallback must be acceptable only as a degraded fallback recommendation"
                )
                check(
                    validatedBundle?.capabilities.qualityStatus == "degraded"
                        && validatedBundle?.capabilities.qualityRecommendations.contains(where: { $0.contains("below backgroundVideo size=") }) == true,
                    "bundle catalog capabilities must surface lower-resolution composite fallback degradation"
                )
            }
        }
        let effectiveAudioPolicy = runtime.manifest.runtime.effectiveAudioPolicy
        check(
            runtime.validationSummary().contains(
                "audioPolicy: \(effectiveAudioPolicy.rawValue) (output=\(runtime.audioOutputSummary), userOptIn=\(runtime.config.audioEnabled))"
            ),
            "validation summary must surface the effective runtime audio policy and user opt-in state"
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
                compositeQualityReport.recommendations.contains(where: { $0.contains("below maxFps=") }) == false,
                "max-FPS composite fallback must not keep stale high-refresh regeneration recommendations"
            )
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
        let expectedPrimaryIdleRenderFps = runtime.idleRenderFps(
            displayRefreshFps: nil,
            videoAsset: runtime.assetCatalog.videoAsset,
            playsVideo: runtime.assetCatalog.videoAsset != nil,
            rendersNativeForeground: runtime.assetCatalog.spineAsset != nil
                && RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime).isSupported
        )
        let expectedPrimaryActiveRenderFps = runtime.activeRenderFps(
            displayRefreshFps: nil,
            videoAsset: runtime.assetCatalog.videoAsset,
            playsVideo: runtime.assetCatalog.videoAsset != nil,
            rendersNativeForeground: runtime.assetCatalog.spineAsset != nil
                && RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime).isSupported
        )
        check(
            expectedPrimaryIdleRenderFps <= runtime.renderTargetFps
                && capabilitySummary.contains("idleRenderFps=\(expectedPrimaryIdleRenderFps)"),
            "runtime capabilities summary must expose idle frame pacing derived from source media and native Spine idle cadence"
        )
        check(
            capabilitySummary.contains("physicsIdlePolicy=\(runtime.manifest.runtime.effectivePhysicsIdlePolicy.rawValue)"),
            "runtime capabilities summary must expose manifest-owned native Spine physics idle policy"
        )
        if let declaredIdleRenderFps = runtime.manifest.runtime.idleRenderFps {
            check(
                expectedPrimaryIdleRenderFps <= declaredIdleRenderFps,
                "manifest runtime.idleRenderFps must cap idle rendering so high-resolution animated backgrounds do not force active cadence while idle"
            )
        }
        check(
            expectedPrimaryActiveRenderFps <= runtime.renderTargetFps
                && expectedPrimaryActiveRenderFps >= expectedPrimaryIdleRenderFps
                && capabilitySummary.contains("activeRenderFps=\(expectedPrimaryActiveRenderFps)"),
            "runtime capabilities summary must expose active frame pacing derived from source media and native Spine pose cadence"
        )
        if let videoAsset = runtime.assetCatalog.videoAsset,
           let effectiveVideoFps = videoAsset.effectiveFrameRate,
           effectiveVideoFps < Double(runtime.renderTargetFps),
           runtime.assetCatalog.spineAsset != nil {
            check(
                expectedPrimaryIdleRenderFps <= Int(ceil(effectiveVideoFps)),
                "native Spine idle frame pacing must not exceed lower-FPS source media when no interaction is active"
            )
            check(
                expectedPrimaryActiveRenderFps <= max(
                    Int(ceil(effectiveVideoFps)),
                    runtime.nativeSpinePoseSampleFps(displayRefreshFps: nil)
                ),
                "native Spine active frame pacing must not exceed source media or declared pose cadence"
            )
        }
        check(
            capabilitySummary.contains(
                "audio\tpolicy\t\(runtime.audioCapabilityStatus)\tpolicy=\(effectiveAudioPolicy.rawValue) userOptIn=\(runtime.config.audioEnabled) output=\(runtime.audioOutputSummary)"
            ),
            "runtime capabilities summary must expose effective audio output policy and user opt-in state"
        )
        check(
            capabilitySummary.contains("columns: category\tname\tstatus\tdetail"),
            "runtime capabilities summary must expose tabular columns"
        )
        check(
            capabilitySummary.contains("displayMode\tselectedOnly\tsupported\tprimary=full(video+foreground) secondary=none secondary-passive")
                && capabilitySummary.contains("displayMode\tselectedPolicy\tsupported\tprimary=full(video+foreground) secondary=video-only(background) secondary-passive")
                && capabilitySummary.contains("displayMode\tallFull\tsupported\tprimary=full(video+foreground) secondary=full(video+foreground) secondary-passive"),
            "runtime capabilities summary must expose selectedOnly, selectedPolicy, and allFull display-mode overrides"
        )
        check(
            capabilitySummary.contains("interaction\tpointerMove/lookDirection"),
            "runtime capabilities summary must report pointer movement support"
        )
        check(
            capabilitySummary.contains("binding\tdeclarative\tdeclared\t1 binding(s) enabled=1 status=runtime-executable=1 adapters=smooth-lookat targets=spine.bone ids=faceTrackerBone71"),
            "runtime capabilities summary must expose manifest-declared declarative bindings as generic runtime objects"
        )
        check(
            capabilitySummary.contains("entries=faceTrackerBone71:pointer.position->spine.bone.bone71 via smooth-lookat runtime-executable"),
            "runtime capabilities summary must expose per-binding runtime status so generic bindings do not hide hard-coded behavior"
        )
        check(
            capabilitySummary.contains("effect\twhitelist\tnot-used\tno manifest-declared effects"),
            "runtime capabilities summary must expose whitelist effect namespace even when the active bundle declares none"
        )
        let expectedDesktopItemGate = (runtime.manifest.interactionPolicy?.blockDesktopItems ?? true)
            ? "desktopItemGate=best-effort"
            : "desktopItemGate=not-required"
        check(
            capabilitySummary.contains(expectedDesktopItemGate),
            "runtime capabilities summary must disclose the effective desktop item gate"
        )
        check(
            capabilitySummary.contains("source\tderivation\tpartial\tpartial imported=13 calibrated=12 platformPolicy=4 unsupported=1 blockers=manual-calibration+unsupported-source-behavior"),
            "runtime capabilities summary must expose whether source behavior is fully derived or still manually calibrated"
        )
        check(
            capabilitySummary.contains("layer\tvideo\tsupported\tbackground -> backgroundVideo foregroundOcclusion=source[0,0.805,1,0.195]->dest[0,0,1,0.195]"),
            "runtime capabilities summary must expose bundle-owned foreground occlusion crop instead of hiding it in renderer code"
        )
        if runtime.manifest.interactions.isEmpty == false,
           runtime.manifest.interactionPolicy?.blockDesktopItems ?? true {
            check(
                RuntimeCapabilities.desktopItemGate(
                    policy: runtime.manifest.interactionPolicy,
                    accessibilityTrusted: false
                ) == "best-effort(current=no-permission,no-ax-api)"
                    && RuntimeCapabilities.desktopItemGate(
                        policy: runtime.manifest.interactionPolicy,
                        accessibilityTrusted: true
                    ) == "best-effort(current=no-permission,no-ax-api)",
                "runtime capabilities must expose no-permission desktop-item mode without AX API"
            )
        }
        let doctorReport = try RuntimeDoctorReport.make(runtime: runtime, recoveryURL: nil)
        let doctorControlPanelSummary = RuntimeDoctorReport.controlPanelSummary(
            runtime: runtime,
            interactionStatus: "READY / desktop-empty-only / no-permission"
        )
        let doctorHasSourceProvenanceStatus = doctorReport.contains("consistency: sourceProvenance: pass")
            || doctorReport.contains("consistency: sourceProvenance: warn")
        check(
            doctorReport.contains("wallpaper doctor OK")
                && doctorReport.contains("== bundle-library ==")
                && doctorReport.contains("validBundles:")
                && doctorReport.contains("includeCapabilities: true")
                && doctorReport.contains("== validation ==")
                && doctorReport.contains("== runtime-capabilities ==")
                && doctorReport.contains("== source-provenance ==")
                && doctorHasSourceProvenanceStatus
                && doctorReport.contains("== render-plan ==")
                && doctorReport.contains("== physical-render-plan ==")
                && doctorReport.contains("== simulated-render-plan ==")
                && doctorReport.contains("== simulated-render-plan-matrix ==")
                && doctorReport.contains("displayMode: selectedOnly")
                && doctorReport.contains("displayMode: selectedPolicy")
                && doctorReport.contains("displayMode: allFull")
                && doctorReport.contains("== performance-plan ==")
                && doctorReport.contains("== package-runtime ==")
                && doctorReport.contains("clickActionNote:")
                && doctorReport.contains("== interaction-plan ==")
                && doctorReport.contains("== renderer-recovery =="),
            "runtime doctor report must combine bundle library, validation, capability, render-mode matrix, performance, package runtime, interaction, and recovery diagnostics"
        )
        let sourceProvenanceReport = RuntimeSourceProvenanceReport.make(runtime: runtime)
        let sourceProvenanceStatusOK = sourceProvenanceReport.contains("consistency: sourceProvenance: pass")
            || sourceProvenanceReport.contains("consistency: sourceProvenance: warn")
        let sourceArchiveDescriptorStatusOK = sourceProvenanceReport.contains("wallpaper-engine-project-json")
            && sourceProvenanceReport.contains("unity-asset-extraction-manifest")
        let sourceManagedScriptStatusOK = (
            sourceProvenanceReport.contains("behaviorScripts=Assembly-CSharp:4")
                && sourceProvenanceReport.contains("interactionOwner=SpineFaceTracker")
                && sourceProvenanceReport.contains("calibratedBlockers=Assembly-CSharp.SpineFaceTracker=12")
        ) || (
            sourceProvenanceReport.contains("scripts=Assembly-CSharp=4")
                && sourceProvenanceReport.contains("interactionCandidates=SpineFaceTracker")
                && sourceProvenanceReport.contains("serializedFields=Assembly-CSharp.SpineFaceTracker=15")
                && sourceProvenanceReport.contains("blockedFieldOwners=Assembly-CSharp.SpineFaceTracker=12")
        )
        let sourceAdapterEvidenceOK = sourceProvenanceReport.contains("sourceAdapter=unity-metadata-source-adapter kind=metadata-only-unity-wallpaper-engine-application fields=imported:13+calibrated:12+platform-policy:4+unsupported:1")
            || (
                sourceProvenanceReport.contains("id=unity-metadata-source-adapter")
                    && sourceProvenanceReport.contains("kind=metadata-only-unity-wallpaper-engine-application")
                    && sourceProvenanceReport.contains("imported=13")
                    && sourceProvenanceReport.contains("calibrated=12")
                    && sourceProvenanceReport.contains("platform-policy=4")
                    && sourceProvenanceReport.contains("unsupported=1")
            )
        check(
            sourceProvenanceReport.contains("source provenance OK")
                && sourceProvenanceReport.contains("boundary: runtime=generic-player manifest=bundle-contract importer=source-adapter")
                && sourceProvenanceStatusOK
                && sourceProvenanceReport.contains("derivation: sourceDerivation: partial imported=13 calibrated=12 platformPolicy=4 unsupported=1 blockers=manual-calibration+unsupported-source-behavior")
                && sourceProvenanceReport.contains("sourceAdapter:")
                && sourceAdapterEvidenceOK
                && sourceManagedScriptStatusOK
                && sourceProvenanceReport.contains("sourceDescriptors:")
                && sourceArchiveDescriptorStatusOK
                && sourceProvenanceReport.contains("unity-managed-script-index")
                && sourceProvenanceReport.contains("converter=unitypy-monoscript-index-v1")
                && sourceProvenanceReport.contains("interactionCandidates=SpineFaceTracker")
                && sourceProvenanceReport.contains("serializedFields=Assembly-CSharp.SpineFaceTracker=15")
                && sourceProvenanceReport.contains("blockedFields=12")
                && sourceProvenanceReport.contains("blockedFieldOwners=Assembly-CSharp.SpineFaceTracker=12")
                && sourceProvenanceReport.contains("requiredCapabilities=unity-managed-method-behavior-import")
                && sourceProvenanceReport.contains("methodBodyStatus=not-read")
                && sourceProvenanceReport.contains("methodBodyRead=forbidden")
                && sourceProvenanceReport.contains("windowsExecutableExecution=forbidden")
                && sourceProvenanceReport.contains("importedFields:")
                && sourceProvenanceReport.contains("calibratedFields:")
                && sourceProvenanceReport.contains("platformPolicyFields:")
                && sourceProvenanceReport.contains("unsupportedFields:"),
            "source provenance report must expose descriptor consistency plus imported, calibrated, and unsupported fields so wallpaper-specific data stays out of runtime code"
        )
        let sourceAdapterAudit = try RuntimeSourceProvenanceReport.makeLibraryReport(
            projectRoot: runtime.config.projectRoot,
            includeInvalid: false
        )
        let sourceAdapterAuditRows = sourceAdapterAudit
            .split(separator: "\n")
            .filter { $0.hasPrefix("valid\t") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count >= 6 }
        let sourceAdapterContractRows = sourceAdapterAuditRows.filter { row in
            let adapterColumn = row[3]
            return adapterColumn.hasPrefix("sourceAdapter=")
                && adapterColumn != "sourceAdapter=none"
                && adapterColumn.contains(" kind=")
                && adapterColumn.contains(" fields=")
        }
        let sourceDerivedRows = sourceAdapterAuditRows.filter { row in
            row[3] == "sourceAdapter=none"
                && row[4].contains("sourceDerivation: source-derived")
        }
        let sourceAdapterRowsConsistent = sourceAdapterAuditRows.allSatisfy { row in
            row[5].hasPrefix("sourceProvenance: pass")
                || row[5].hasPrefix("sourceProvenance: warn")
                || row[5] == "sourceProvenance: skipped(no-descriptors)"
        }
        check(
            sourceAdapterAudit.contains("source adapter audit OK")
                && sourceAdapterAudit.contains("validBundles: 9")
                && sourceAdapterAudit.contains("columns: status\tid\tsource\tadapter\tderivation\tconsistency")
                && sourceAdapterContractRows.isEmpty == false
                && sourceDerivedRows.isEmpty == false
                && sourceAdapterRowsConsistent,
            "source adapter audit must cover the whole wallpaper library so adapter-owned fields do not remain a single-bundle diagnostic"
        )
        check(
            doctorControlPanelSummary.contains("doctor: OK")
                && doctorControlPanelSummary.contains("quality:")
                && doctorControlPanelSummary.contains("display:")
                && doctorControlPanelSummary.contains("package:")
                && doctorControlPanelSummary.contains("accessibilityAPI=false")
                && doctorControlPanelSummary.contains("interaction:"),
            "runtime doctor control-panel summary must expose compact preflight, package, and interaction status"
        )
        if let packageRuntimeURL = Bundle.main.resourceURL?.appendingPathComponent("package-runtime.txt"),
           FileManager.default.fileExists(atPath: packageRuntimeURL.path) {
            check(
                doctorControlPanelSummary.contains("package: local-manual-start")
                    && doctorControlPanelSummary.contains("signature=unsigned-no-certificate")
                    && doctorControlPanelSummary.contains("input=permissionless"),
                "packaged local builds must surface unsigned manual-start input mode in the control-panel doctor summary"
            )
        }
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
        let noPointerSmoothingPolicy = InteractionPolicy(
            mode: manifest.interactionPolicy?.mode ?? .desktopEmptyOnly,
            blockApplicationWindows: manifest.interactionPolicy?.blockApplicationWindows ?? true,
            blockDesktopItems: manifest.interactionPolicy?.blockDesktopItems ?? true,
            pointerSmoothing: 0,
            pointerSampleFps: manifest.interactionPolicy?.pointerSampleFps,
            idleDeadZone: manifest.interactionPolicy?.idleDeadZone,
            directionSwitchMargin: manifest.interactionPolicy?.directionSwitchMargin,
            defaultClickTailSeconds: manifest.interactionPolicy?.defaultClickTailSeconds,
            releaseFadeSeconds: manifest.interactionPolicy?.releaseFadeSeconds
        )
        let noPointerSmoothingPlan = InteractionPlan(
            interactions: manifest.interactions,
            policy: noPointerSmoothingPolicy,
            actionTailDurations: tapActionDurations
        )
        let unsmoothedTarget = CGPoint(x: 0.91, y: 0.17)
        check(
            noPointerSmoothingPlan.smooth(
                current: CGPoint(x: 0.20, y: 0.80),
                target: unsmoothedTarget
            ) == unsmoothedTarget,
            "interaction pointerSmoothing=0 must disable smoothing and apply target coordinates immediately"
        )
        let customLookInteractions = [
            InteractionConfig(
                event: .pointerMove,
                mapping: "lookDirection",
                actions: [
                    "left": "lookWest",
                    "right": "lookEast",
                    "up": "lookNorth",
                    "down": "lookSouth",
                    "idle": "lookCenter"
                ],
                neutralPoint: nil,
                deadZone: nil,
                hitZones: nil,
                defaultAction: nil,
                buttons: nil
            )
        ]
        let customLookPlan = InteractionPlan(
            interactions: customLookInteractions,
            policy: nil
        )
        check(
            customLookPlan.command(for: CGPoint(x: 0.10, y: 0.50), previousCommand: "lookCenter") == "lookWest"
                && customLookPlan.command(for: CGPoint(x: 0.90, y: 0.50), previousCommand: "lookCenter") == "lookEast"
                && customLookPlan.command(for: CGPoint(x: 0.50, y: 0.10), previousCommand: "lookCenter") == "lookNorth"
                && customLookPlan.command(for: CGPoint(x: 0.50, y: 0.90), previousCommand: "lookCenter") == "lookSouth"
                && customLookPlan.command(for: CGPoint(x: 0.50, y: 0.50), previousCommand: "lookEast") == "lookCenter",
            "look-direction interaction plan must use manifest action names instead of hard-coded animation names"
        )
        var customLookClock: CFTimeInterval = 0
        let customLookController = InteractionController(
            interactions: customLookInteractions,
            policy: InteractionPolicy(
                mode: .desktopEmptyOnly,
                blockApplicationWindows: true,
                blockDesktopItems: true,
                pointerSmoothing: 0,
                pointerSampleFps: 60,
                idleDeadZone: 0.12,
                directionSwitchMargin: 0.04,
                defaultClickTailSeconds: 1.15,
                releaseFadeSeconds: 0.20
            ),
            clock: { customLookClock }
        )
        let initialCustomLookSnapshot = customLookController.snapshot()
        check(
            initialCustomLookSnapshot.command == "lookCenter"
                && initialCustomLookSnapshot.isInputActive == false,
            "interaction controller initial state must use the manifest-declared idle action without active input pacing"
        )
        customLookController.pointerMoved(to: CGPoint(x: 0.90, y: 0.50))
        customLookClock += 1.0 / InteractionPlan.pointerSmoothingReferenceFps
        let movedCustomLookSnapshot = customLookController.snapshot()
        check(
            movedCustomLookSnapshot.command == "lookEast"
                && movedCustomLookSnapshot.isInputActive,
            "interaction controller must resolve custom manifest look actions during pointer movement and mark input pacing active"
        )
        customLookClock += 0.25
        let settledCustomLookSnapshot = customLookController.snapshot()
        check(
            settledCustomLookSnapshot.command == "lookEast"
                && settledCustomLookSnapshot.isInputActive == false,
            "stable off-center gaze must keep its manifest command without forcing active render cadence forever"
        )
        customLookController.resetPointerTracking()
        check(
            customLookController.snapshot().command == "lookCenter",
            "interaction controller reset must return to the manifest-declared idle action"
        )
        let triggerPlayBindingPlan = DeclarativeBindingPlan(
            bindings: [
                DeclarativeBinding(
                    id: "tapWave",
                    source: .pointerDown,
                    target: "spine.animation.wave",
                    adapter: BindingAdapter(
                        type: .triggerPlay,
                        neutralPoint: nil,
                        deadZone: nil,
                        interpolation: nil,
                        factor: nil,
                        inputRange: nil,
                        outputRange: nil,
                        loop: nil
                    ),
                    enabled: nil
                )
            ],
            effects: []
        )
        let bindingPlanHit = InteractionPlan(
            interactions: [],
            policy: nil,
            actionTailDurations: ["wave": 0.42],
            declarativePlan: triggerPlayBindingPlan
        ).hitTest(point: CGPoint(x: 0.40, y: 0.40), button: .left)
        check(
            triggerPlayBindingPlan.bindingEntries.first?.runtimeStatus == .runtimeExecutable
                && triggerPlayBindingPlan.hasPointerInputBindings
                && bindingPlanHit?.zoneID == "binding:tapWave"
                && bindingPlanHit?.action == "wave"
                && abs((bindingPlanHit?.tailSeconds ?? 0) - 0.42) < 0.001,
            "pointer.down trigger-play bindings must objectize into executable pointerDown actions without hard-coded hit zones"
        )
        var triggerPlayClock: CFTimeInterval = 0
        let triggerPlayController = InteractionController(
            interactions: [],
            policy: InteractionPolicy(
                mode: .desktopEmptyOnly,
                blockApplicationWindows: true,
                blockDesktopItems: true,
                pointerSmoothing: 0,
                pointerSampleFps: 60,
                idleDeadZone: 0.12,
                directionSwitchMargin: 0.04,
                defaultClickTailSeconds: 1.15,
                releaseFadeSeconds: 0.20
            ),
            actionTailDurations: ["wave": 0.42],
            declarativePlan: triggerPlayBindingPlan,
            clock: { triggerPlayClock }
        )
        triggerPlayController.pointerDown(at: CGPoint(x: 0.25, y: 0.25), button: .left)
        let triggerPlayDown = triggerPlayController.snapshot()
        triggerPlayController.pointerUp(at: CGPoint(x: 0.25, y: 0.25), button: .left)
        let triggerPlayUp = triggerPlayController.snapshot()
        triggerPlayClock += 0.53
        let triggerPlayExpired = triggerPlayController.snapshot()
        check(
            triggerPlayDown.command == "wave"
                && triggerPlayUp.command == "wave"
                && triggerPlayExpired.command == "idle",
            "interaction controller must execute trigger-play declarative bindings through the same click command path as manifest hit zones"
        )
        let colorMatrixEffectPlan = DeclarativeBindingPlan(
            bindings: [
                DeclarativeBinding(
                    id: "pressBrightness",
                    source: .pointerDown,
                    target: "effect.tone.brightness",
                    adapter: BindingAdapter(
                        type: .mapRange,
                        neutralPoint: nil,
                        deadZone: nil,
                        interpolation: .linear,
                        factor: nil,
                        inputRange: [0, 1],
                        outputRange: [0, 0.25],
                        loop: nil
                    ),
                    enabled: nil
                )
            ],
            effects: [
                EffectConfig(
                    id: "tone",
                    type: .colorMatrix,
                    properties: [
                        "opacity": .number(0.5),
                        "saturation": .number(0.4)
                    ]
                )
            ]
        )
        let colorMatrixSnapshot = DeclarativeBindingEvaluator.evaluate(
            plan: colorMatrixEffectPlan,
            input: DeclarativeBindingEvaluationInput(pointerDown: true)
        )
        let colorMatrixState = DeclarativeEffectState.make(
            plan: colorMatrixEffectPlan,
            snapshot: colorMatrixSnapshot
        )
        check(
            abs(Double(colorMatrixState.colorMultiplier.x) - 1.25) < 0.001
                && abs(Double(colorMatrixState.colorMultiplier.y) - 1.25) < 0.001
                && abs(Double(colorMatrixState.colorMultiplier.z) - 1.25) < 0.001
                && abs(Double(colorMatrixState.colorMultiplier.w) - 0.5) < 0.001
                && abs(Double(colorMatrixState.fragmentEffectParams2.x) - 0.4) < 0.001,
            "colorMatrix whitelist effects must convert evaluated bindings and static saturation into renderer-owned color parameters"
        )
        check(
            colorMatrixEffectPlan.effectEntries.first?.runtimeStatus == .runtimeRendered,
            "whitelist effect plan entries must report runtime-rendered status when the renderer owns the implementation"
        )
        let pointerSpeedEffectPlan = DeclarativeBindingPlan(
            bindings: [
                DeclarativeBinding(
                    id: "moveOpacity",
                    source: .pointerSpeed,
                    target: "effect.tone.opacity",
                    adapter: BindingAdapter(
                        type: .mapRange,
                        neutralPoint: nil,
                        deadZone: nil,
                        interpolation: .smoothStep,
                        factor: nil,
                        inputRange: [0, 1, 10],
                        outputRange: [1.0, 0.85, 0.65],
                        loop: nil
                    ),
                    enabled: nil
                ),
                DeclarativeBinding(
                    id: "speedSaturation",
                    source: .pointerSpeed,
                    target: "effect.tone.saturation",
                    adapter: BindingAdapter(
                        type: .mapRange,
                        neutralPoint: nil,
                        deadZone: nil,
                        interpolation: .smoothStep,
                        factor: nil,
                        inputRange: [0, 1, 10],
                        outputRange: [1.0, 0.9, 0.75],
                        loop: nil
                    ),
                    enabled: nil
                )
            ],
            effects: [
                EffectConfig(
                    id: "tone",
                    type: .colorMatrix,
                    properties: [
                        "brightness": .number(0.0),
                        "opacity": .number(1.0)
                    ]
                )
            ]
        )
        let pointerSpeedSnapshot = DeclarativeBindingEvaluator.evaluate(
            plan: pointerSpeedEffectPlan,
            input: DeclarativeBindingEvaluationInput(pointerSpeed: 5.5)
        )
        let pointerSpeedState = DeclarativeEffectState.make(
            plan: pointerSpeedEffectPlan,
            snapshot: pointerSpeedSnapshot
        )
        check(
            abs(Double(pointerSpeedState.colorMultiplier.w) - 0.75) < 0.001
                && abs(Double(pointerSpeedState.fragmentEffectParams2.x) - 0.825) < 0.001,
            "pointer.speed bindings must evaluate normalized movement speed into safe colorMatrix effect properties without wallpaper-specific code"
        )
        let pointerPressDurationEffectPlan = DeclarativeBindingPlan(
            bindings: [
                DeclarativeBinding(
                    id: "holdBlurRadius",
                    source: .pointerPressDuration,
                    target: "effect.holdBlur.radius",
                    adapter: BindingAdapter(
                        type: .mapRange,
                        neutralPoint: nil,
                        deadZone: nil,
                        interpolation: .linear,
                        factor: nil,
                        inputRange: [0, 2],
                        outputRange: [0, 4],
                        loop: nil
                    ),
                    enabled: nil
                )
            ],
            effects: [
                EffectConfig(
                    id: "holdBlur",
                    type: .blur,
                    properties: [
                        "radius": .number(0.0)
                    ]
                )
            ]
        )
        let pointerPressDurationSnapshot = DeclarativeBindingEvaluator.evaluate(
            plan: pointerPressDurationEffectPlan,
            input: DeclarativeBindingEvaluationInput(pointerPressDurationSeconds: 1.25)
        )
        let pointerPressDurationState = DeclarativeEffectState.make(
            plan: pointerPressDurationEffectPlan,
            snapshot: pointerPressDurationSnapshot
        )
        check(
            abs(Double(pointerPressDurationState.fragmentEffectParams.x) - 2.5) < 0.001,
            "pointer.pressDuration bindings must evaluate held-click duration into safe effect properties without wallpaper-specific code"
        )
        let pointerDragDistanceEffectPlan = DeclarativeBindingPlan(
            bindings: [
                DeclarativeBinding(
                    id: "dragShadeIntensity",
                    source: .pointerDragDistance,
                    target: "effect.dragShade.intensity",
                    adapter: BindingAdapter(
                        type: .mapRange,
                        neutralPoint: nil,
                        deadZone: nil,
                        interpolation: .linear,
                        factor: nil,
                        inputRange: [0, 0.2],
                        outputRange: [0, 0.65],
                        loop: nil
                    ),
                    enabled: nil
                )
            ],
            effects: [
                EffectConfig(
                    id: "dragShade",
                    type: .vignette,
                    properties: [
                        "intensity": .number(0.0),
                        "radius": .number(0.55)
                    ]
                )
            ]
        )
        let pointerDragDistanceSnapshot = DeclarativeBindingEvaluator.evaluate(
            plan: pointerDragDistanceEffectPlan,
            input: DeclarativeBindingEvaluationInput(pointerDragDistance: 0.10)
        )
        let pointerDragDistanceState = DeclarativeEffectState.make(
            plan: pointerDragDistanceEffectPlan,
            snapshot: pointerDragDistanceSnapshot
        )
        check(
            abs(Double(pointerDragDistanceState.fragmentEffectParams.z) - 0.325) < 0.001,
            "pointer.dragDistance bindings must evaluate held-drag displacement into safe effect properties without wallpaper-specific code"
        )
        let pointerAxisEffectPlan = DeclarativeBindingPlan(
            bindings: [
                DeclarativeBinding(
                    id: "cursorPanY",
                    source: .pointerX,
                    target: "effect.cursorPan.offsetY",
                    adapter: BindingAdapter(
                        type: .mapRange,
                        neutralPoint: nil,
                        deadZone: nil,
                        interpolation: .linear,
                        factor: nil,
                        inputRange: [0, 1],
                        outputRange: [-0.05, 0.05],
                        loop: nil
                    ),
                    enabled: nil
                ),
                DeclarativeBinding(
                    id: "cursorShadeRadius",
                    source: .pointerY,
                    target: "effect.dragShade.radius",
                    adapter: BindingAdapter(
                        type: .mapRange,
                        neutralPoint: nil,
                        deadZone: nil,
                        interpolation: .linear,
                        factor: nil,
                        inputRange: [0, 1],
                        outputRange: [0.45, 0.7],
                        loop: nil
                    ),
                    enabled: nil
                )
            ],
            effects: [
                EffectConfig(
                    id: "cursorPan",
                    type: .scroll,
                    properties: [
                        "offsetY": .number(0.0)
                    ]
                ),
                EffectConfig(
                    id: "dragShade",
                    type: .vignette,
                    properties: [
                        "intensity": .number(0.0),
                        "radius": .number(0.55)
                    ]
                )
            ]
        )
        let pointerAxisSnapshot = DeclarativeBindingEvaluator.evaluate(
            plan: pointerAxisEffectPlan,
            input: DeclarativeBindingEvaluationInput(pointerPosition: CGPoint(x: 0.8, y: 0.2))
        )
        let pointerAxisState = DeclarativeEffectState.make(
            plan: pointerAxisEffectPlan,
            snapshot: pointerAxisSnapshot
        )
        check(
            abs(Double(pointerAxisState.textureOffset.y) - 0.03) < 0.001
                && abs(Double(pointerAxisState.fragmentEffectParams.w) - 0.5) < 0.001,
            "pointer.x and pointer.y bindings must expose clamped scalar pointer axes to safe effect properties without arbitrary scripts"
        )
        let scrollEffectPlan = DeclarativeBindingPlan(
            bindings: [
                DeclarativeBinding(
                    id: "pressPan",
                    source: .pointerDown,
                    target: "effect.pan.offsetX",
                    adapter: BindingAdapter(
                        type: .mapRange,
                        neutralPoint: nil,
                        deadZone: nil,
                        interpolation: .linear,
                        factor: nil,
                        inputRange: [0, 1],
                        outputRange: [0, 0.75],
                        loop: nil
                    ),
                    enabled: nil
                )
            ],
            effects: [
                EffectConfig(
                    id: "pan",
                    type: .scroll,
                    properties: [
                        "offsetY": .number(-0.10)
                    ]
                )
            ]
        )
        let scrollSnapshot = DeclarativeBindingEvaluator.evaluate(
            plan: scrollEffectPlan,
            input: DeclarativeBindingEvaluationInput(pointerDown: true)
        )
        let scrollState = DeclarativeEffectState.make(
            plan: scrollEffectPlan,
            snapshot: scrollSnapshot
        )
        check(
            abs(Double(scrollState.textureOffset.x) - 0.75) < 0.001
                && abs(Double(scrollState.textureOffset.y) - 0.90) < 0.001,
            "scroll whitelist effects must convert evaluated bindings into wrapped renderer texture offsets"
        )
        let timeLoopEffectPlan = DeclarativeBindingPlan(
            bindings: [
                DeclarativeBinding(
                    id: "timePanLoop",
                    source: .systemTime,
                    target: "effect.loopPan.offsetX",
                    adapter: BindingAdapter(
                        type: .mapRange,
                        neutralPoint: nil,
                        deadZone: nil,
                        interpolation: .linear,
                        factor: nil,
                        inputRange: [0, 2],
                        outputRange: [0, 1],
                        loop: true
                    ),
                    enabled: nil
                )
            ],
            effects: [
                EffectConfig(
                    id: "loopPan",
                    type: .scroll,
                    properties: [:]
                )
            ]
        )
        let timeLoopSnapshot = DeclarativeBindingEvaluator.evaluate(
            plan: timeLoopEffectPlan,
            input: DeclarativeBindingEvaluationInput(systemTimeSeconds: 2.5)
        )
        let timeLoopState = DeclarativeEffectState.make(
            plan: timeLoopEffectPlan,
            snapshot: timeLoopSnapshot
        )
        check(
            abs(Double(timeLoopState.textureOffset.x) - 0.25) < 0.001,
            "map-range loop adapters must wrap system.time into the declared input range for safe time-based effects"
        )
        let fragmentEffectPlan = DeclarativeBindingPlan(
            bindings: [
                DeclarativeBinding(
                    id: "thermalBlur",
                    source: .thermalState,
                    target: "effect.soft.radius",
                    adapter: BindingAdapter(
                        type: .mapRange,
                        neutralPoint: nil,
                        deadZone: nil,
                        interpolation: .linear,
                        factor: nil,
                        inputRange: [0, 1],
                        outputRange: [0, 6],
                        loop: nil
                    ),
                    enabled: nil
                )
            ],
            effects: [
                EffectConfig(
                    id: "soft",
                    type: .blur,
                    properties: [:]
                ),
                EffectConfig(
                    id: "split",
                    type: .chromaticAberration,
                    properties: [
                        "amount": .number(2.5)
                    ]
                ),
                EffectConfig(
                    id: "edge",
                    type: .vignette,
                    properties: [
                        "intensity": .number(0.4),
                        "radius": .number(0.6)
                    ]
                )
            ]
        )
        let fragmentEffectSnapshot = DeclarativeBindingEvaluator.evaluate(
            plan: fragmentEffectPlan,
            input: DeclarativeBindingEvaluationInput(thermalStateLevel: 0.5)
        )
        let fragmentEffectState = DeclarativeEffectState.make(
            plan: fragmentEffectPlan,
            snapshot: fragmentEffectSnapshot
        )
        check(
            abs(Double(fragmentEffectState.fragmentEffectParams.x) - 3.0) < 0.001
                && abs(Double(fragmentEffectState.fragmentEffectParams.y) - 2.5) < 0.001
                && abs(Double(fragmentEffectState.fragmentEffectParams.z) - 0.4) < 0.001
                && abs(Double(fragmentEffectState.fragmentEffectParams.w) - 0.6) < 0.001,
            "blur, chromaticAberration, and vignette whitelist effects must convert bindings into renderer-owned fragment parameters"
        )
        let smoothLookAtPlan = DeclarativeBindingPlan(
            bindings: [
                DeclarativeBinding(
                    id: "lookHead",
                    source: .pointerPosition,
                    target: "spine.bone.head",
                    adapter: BindingAdapter(
                        type: .smoothLookAt,
                        neutralPoint: InteractionPoint(x: 0.40, y: 0.60),
                        deadZone: InteractionPoint(x: 0.03, y: 0.03),
                        interpolation: .linear,
                        factor: [30, -12],
                        inputRange: nil,
                        outputRange: nil,
                        loop: nil
                    ),
                    enabled: nil
                )
            ],
            effects: []
        )
        let smoothLookAtCenter = DeclarativeBindingEvaluator.evaluate(
            plan: smoothLookAtPlan,
            input: DeclarativeBindingEvaluationInput(pointerPosition: CGPoint(x: 0.40, y: 0.60))
        )
        let smoothLookAtEdge = DeclarativeBindingEvaluator.evaluate(
            plan: smoothLookAtPlan,
            input: DeclarativeBindingEvaluationInput(pointerPosition: CGPoint(x: 1.0, y: 0.0))
        )
        check(
            smoothLookAtPlan.bindingEntries.first?.runtimeStatus == .runtimeExecutable
                && (smoothLookAtCenter.spineBoneRotationOffsets["head"] ?? -1) == 0
                && abs((smoothLookAtEdge.spineBoneRotationOffsets["head"] ?? 0) - 25.2) < 0.001,
            "smooth-lookat bindings must evaluate pointer.position into manifest-targeted Spine bone rotation offsets using adapter-declared neutralPoint"
        )
        let declaredSpringPlan = DeclarativeBindingPlan(
            bindings: [
                DeclarativeBinding(
                    id: "springHead",
                    source: .pointerPosition,
                    target: "spine.bone.head",
                    adapter: BindingAdapter(
                        type: .spring,
                        neutralPoint: nil,
                        deadZone: nil,
                        interpolation: nil,
                        factor: [12],
                        inputRange: nil,
                        outputRange: nil,
                        loop: nil,
                        integrator: .semiImplicitEuler,
                        stiffness: 120,
                        damping: 14,
                        mass: 1,
                        settleEpsilon: 0.001,
                        maxVelocity: 90,
                        fixedStepSeconds: 0.0166666667
                    ),
                    enabled: nil
                )
            ],
            effects: []
        )
        var pointerSpringState = DeclarativeBindingEvaluationState()
        let declaredSpringSnapshot = DeclarativeBindingEvaluator.evaluate(
            plan: declaredSpringPlan,
            input: DeclarativeBindingEvaluationInput(
                pointerPosition: CGPoint(x: 0.5, y: 0.5),
                systemTimeSeconds: 0
            ),
            state: &pointerSpringState
        )
        let settledSpringSnapshot = DeclarativeBindingEvaluator.evaluate(
            plan: declaredSpringPlan,
            input: DeclarativeBindingEvaluationInput(
                pointerPosition: CGPoint(x: 1.0, y: 0.0),
                systemTimeSeconds: 0.1
            ),
            state: &pointerSpringState
        )
        check(
            declaredSpringPlan.bindingEntries.first?.runtimeStatus == .runtimeExecutable
                && declaredSpringPlan.hasPointerInputBindings
                && abs(declaredSpringSnapshot.spineBoneRotationOffsets["head"] ?? -1) < 0.001
                && (settledSpringSnapshot.spineBoneRotationOffsets["head"] ?? 0) > 0
                && (settledSpringSnapshot.spineBoneRotationOffsets["head"] ?? 0) <= 6.0
                && settledSpringSnapshot.effectProperties.isEmpty,
            "pointer-to-Spine spring bindings must run only as manifest-declared Spine bone rotation offsets with deterministic spring state"
        )
        let effectSpringPlan = DeclarativeBindingPlan(
            bindings: [
                DeclarativeBinding(
                    id: "timeSpringBlur",
                    source: .systemTime,
                    target: "effect.softSpring.radius",
                    adapter: BindingAdapter(
                        type: .spring,
                        neutralPoint: nil,
                        deadZone: nil,
                        interpolation: .linear,
                        factor: nil,
                        inputRange: [0, 0.1],
                        outputRange: [0, 6],
                        loop: nil,
                        integrator: .semiImplicitEuler,
                        stiffness: 120,
                        damping: 10,
                        mass: 1,
                        settleEpsilon: 0.001,
                        maxVelocity: 2,
                        fixedStepSeconds: 0.05
                    ),
                    enabled: nil
                )
            ],
            effects: [
                EffectConfig(
                    id: "softSpring",
                    type: .blur,
                    properties: [:]
                )
            ]
        )
        var effectSpringState = DeclarativeBindingEvaluationState()
        let effectSpringStart = DeclarativeBindingEvaluator.evaluate(
            plan: effectSpringPlan,
            input: DeclarativeBindingEvaluationInput(systemTimeSeconds: 0),
            state: &effectSpringState
        )
        let effectSpringFirst = DeclarativeBindingEvaluator.evaluate(
            plan: effectSpringPlan,
            input: DeclarativeBindingEvaluationInput(systemTimeSeconds: 1.0),
            state: &effectSpringState
        )
        let effectSpringSecond = DeclarativeBindingEvaluator.evaluate(
            plan: effectSpringPlan,
            input: DeclarativeBindingEvaluationInput(systemTimeSeconds: 1.25),
            state: &effectSpringState
        )
        let effectSpringRendered = DeclarativeEffectState.make(
            plan: effectSpringPlan,
            snapshot: effectSpringSecond
        )
        let springStartRadius = effectSpringStart.number(effectID: "softSpring", property: "radius") ?? -1
        let springFirstRadius = effectSpringFirst.number(effectID: "softSpring", property: "radius") ?? -1
        let springSecondRadius = effectSpringSecond.number(effectID: "softSpring", property: "radius") ?? -1
        check(
            effectSpringPlan.bindingEntries.first?.runtimeStatus == .runtimeExecutable
                && effectSpringPlan.hasPointerInputBindings == false
                && abs(springStartRadius) < 0.001
                && springFirstRadius > springStartRadius
                && springSecondRadius > springFirstRadius
                && springFirstRadius <= 0.501
                && springSecondRadius <= 1.001
                && abs(Double(effectSpringRendered.fragmentEffectParams.x) - springSecondRadius) < 0.001,
            "system.time effect spring bindings must run through a deterministic bounded spring evaluator without enabling pointer monitoring"
        )
        let hasLookDirection = manifest.interactions.contains {
            $0.event == .pointerMove && $0.mapping == "lookDirection"
        }
        let lookMoveButton = manifest.interactions.first {
            $0.event == .pointerMove && $0.mapping == "lookDirection"
        }?.buttons?.first
        func sendLookMove(_ controller: InteractionController, to point: CGPoint) {
            if let lookMoveButton {
                controller.pointerDragged(to: point, button: lookMoveButton)
            } else {
                controller.pointerMoved(to: point)
            }
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
            sendLookMove(interactionController, to: CGPoint(x: 0.10, y: 0.50))
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
                sendLookMove(controller, to: smoothingTarget)
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
            sendLookMove(snapController, to: CGPoint(x: 0.10, y: 0.50))
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
                sendLookMove(resumeController, to: gazePoint)
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
                sendLookMove(outsideReleaseController, to: gazePoint)
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
            sendLookMove(interruptedController, to: CGPoint(x: 0.10, y: 0.42))
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
            var stoppedClock: CFTimeInterval = 0
            let stoppedController = InteractionController(
                interactions: manifest.interactions,
                policy: manifest.interactionPolicy,
                actionTailDurations: tapActionDurations,
                clock: { stoppedClock }
            )
            sendLookMove(stoppedController, to: CGPoint(x: 0.10, y: 0.42))
            for _ in 0..<20 {
                stoppedClock += 1.0 / 60.0
                _ = stoppedController.snapshot()
            }
            check(
                stoppedController.snapshot().command == "Left",
                "interaction controller must establish look-direction before pointer tracking stops"
            )
            stoppedController.pointerTrackingStopped()
            stoppedClock += 1.0 / 60.0
            check(
                stoppedController.snapshot().command == "Left",
                "pointer tracking stop must preserve the last look-direction instead of snapping to idle"
            )
            stoppedController.resetPointerTracking()
            check(
                stoppedController.snapshot().command == "idle",
                "explicit interaction reset must recenter look-direction when the wallpaper disables interaction"
            )
        } else {
            check(
                interactionPlan.command(for: CGPoint(x: 0.10, y: 0.50), previousCommand: "idle") == "idle",
                "bundles without pointerMove lookDirection must stay idle for pointer movement"
            )
        }
        let hitZoneSummaries = interactionPlan.hitZoneSummaries()
        if hasLookDirection, let lookMoveButton {
            var hoverClock: CFTimeInterval = 0
            let hoverController = InteractionController(
                interactions: manifest.interactions,
                policy: manifest.interactionPolicy,
                actionTailDurations: tapActionDurations,
                clock: { hoverClock }
            )
            let lookNeutral = SpineInteractionAnimationRoles.lookNeutralPoint(from: manifest)
            let hoverProbe = CGPoint(
                x: lookNeutral.x > 0.5 ? 0.10 : 0.90,
                y: lookNeutral.y
            )
            hoverController.pointerMoved(to: hoverProbe)
            for _ in 0..<20 {
                hoverClock += 1.0 / 60.0
                _ = hoverController.snapshot()
            }
            check(
                hoverController.snapshot().command == "idle",
                "button-gated look-direction must ignore hover movement until the declared \(lookMoveButton.rawValue)-button drag"
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
                && interactionSummary.contains("eventGatePreciseItemProbes:")
                && interactionSummary.contains("inputSourceProbes:")
                && interactionSummary.contains("moveEvents=leftDrag")
                && interactionSummary.contains("passiveMissingTrust=globalMove")
                && interactionSummary.contains("passiveTrustedEventTap=eventTap")
                && interactionSummary.contains("passiveTrustedFallback=globalMove+globalClick")
                && interactionSummary.contains("outsideContentTracking: ignore-same-window-outside-content-without-idle-reset")
                && interactionSummary.contains("blockedDesktopEventTracking: ignore-blocked-desktop-events-without-idle-reset")
                && interactionSummary.contains("appWindow=blockedApplicationWindow")
                && interactionSummary.contains("desktopItem=blockedDesktopItem")
                && interactionSummary.contains("clickTimeline:")
                && interactionSummary.contains("gestureProbe:")
                && interactionSummary.contains("tapUp@0.016=")
                && interactionSummary.contains("rubDrag@distance")
                && interactionSummary.contains("pointerSmoothingCadence: time-based")
                && interactionSummary.contains("pointerSampleFps:")
                && interactionSummary.contains("pointerMoveButtons:")
                && interactionSummary.contains("pointerMoveNeutralPoint:")
                && interactionSummary.contains("pointerMoveDeadZone:")
                && interactionSummary.contains("neutral=idle")
                && interactionSummary.contains("coordinateProbes:")
                && interactionSummary.contains("coordinateProbe: view=32:9"),
            "interaction diagnostics must expose move probes, neutral/dead-zone values, click buttons, event-gate/input-source decisions, deterministic click timelines, and display-aspect coordinate probes"
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
            missingPermissionInteractionSummary.contains("desktopMonitor: ready(desktop-empty-only,no-permission-best-effort)")
                && missingPermissionInteractionSummary.contains("emptyDesktopMove=eligible")
                && missingPermissionInteractionSummary.contains("emptyDesktop=eligible")
                && missingPermissionInteractionSummary.contains("eventGateNoPermissionProbes: desktopItemPrecision=best-effort"),
            "interaction diagnostics must explain no-permission best-effort click interaction"
        )
        let neutralProbeSummary = InteractionPlan.probeSummary(
            interactions: manifest.interactions,
            policy: manifest.interactionPolicy,
            runtimeInteractive: runtime.config.interactive,
            point: SpineInteractionAnimationRoles.lookNeutralPoint(from: manifest),
            button: .left,
            actionTailDurations: tapActionDurations
        )
        let lookNeutralPoint = SpineInteractionAnimationRoles.lookNeutralPoint(from: manifest)
        let neutralPointText = String(
            format: "neutralPoint: %.3f,%.3f",
            Double(lookNeutralPoint.x),
            Double(lookNeutralPoint.y)
        )
        check(
            neutralProbeSummary.contains("interaction probe OK")
                && neutralProbeSummary.contains("moveCommand: idle")
                && neutralProbeSummary.contains(neutralPointText),
            "interaction probe diagnostics must expose one-coordinate look-direction resolution"
        )
        for hitZoneSummary in hitZoneSummaries {
            check(
                capabilitySummary.contains(hitZoneSummary.detailText),
                "runtime capabilities summary must report resolved hit-zone tail for \(hitZoneSummary.id)"
            )
        }
        if let probeHitZone = hitZoneSummaries.first {
            let probePoint = CGPoint(
                x: CGFloat((probeHitZone.rect[0] + probeHitZone.rect[2]) / 2.0),
                y: CGFloat((probeHitZone.rect[1] + probeHitZone.rect[3]) / 2.0)
            )
            let probeButton = probeHitZone.buttons.first ?? .left
            let probeInitialAction = probeHitZone.tapAction ?? probeHitZone.action
            let probeDefersShortTouch = probeHitZone.trigger == .hold && probeHitZone.tapAction != nil
            let probeDownExpectation = probeDefersShortTouch
                ? "downSnapshot: \(interactionPlan.idleCommand())/0"
                : "downSnapshot: \(probeInitialAction)/1"
            let probeUpExpectation = "upSnapshot: \(probeInitialAction)/1"
            let hitZoneProbeSummary = InteractionPlan.probeSummary(
                interactions: manifest.interactions,
                policy: manifest.interactionPolicy,
                runtimeInteractive: runtime.config.interactive,
                point: probePoint,
                button: probeButton,
                actionTailDurations: tapActionDurations
            )
            check(
                hitZoneProbeSummary.contains("hit: zone=\(probeHitZone.id) action=\(probeHitZone.action) trigger=\(probeHitZone.trigger.rawValue)")
                    && hitZoneProbeSummary.contains(probeDownExpectation)
                    && hitZoneProbeSummary.contains(probeUpExpectation),
                "interaction probe diagnostics must expose the manifest-declared hit-zone action and click timeline"
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
            interaction.hitZones?.forEach {
                manifestActionNames.insert($0.action)
                if let tapAction = $0.tapAction {
                    manifestActionNames.insert(tapAction)
                }
                if let rubAction = $0.rubAction {
                    manifestActionNames.insert(rubAction)
                }
            }
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
                    && spineGeometryPlan.contains("columns: kind\taction\ttime\tstatus\tbatches\tvertices\tblendModes\tuv\tbounds\tfingerprint\tcolors\terror"),
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
                    && spineGeometryPlan.contains("poseFps=\(runtime.nativeSpinePoseSampleFps(displayRefreshFps: nil))"),
                "Spine geometry diagnostics must sample runtime-cadence pose frames at the native Spine pose FPS"
            )
            check(
                spineGeometryPlan.contains("idlePoseFps=\(runtime.nativeSpineIdlePoseSampleFps(displayRefreshFps: nil))"),
                "Spine geometry diagnostics must expose the native Spine idle pose FPS"
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
            let spineProfile = try SpineGeometryDiagnostics.profile(runtime: runtime, iterations: 1)
            check(
                spineProfile.contains("spine profile OK")
                    && spineProfile.contains("averagePoseSampleMs:")
                    && spineProfile.contains("p95PoseSampleMs:")
                    && spineProfile.contains("poseBudgetSoftLimitMs:")
                    && spineProfile.contains("poseBudgetPolicy: \(SpineGeometryDiagnostics.poseBudgetPolicy)")
                    && spineProfile.contains("poseSampleFps:")
                    && spineProfile.contains("idlePoseSampleFps:")
                    && spineProfile.contains("renderTargetFps:")
                    && spineProfile.contains("physicsIdlePolicy:")
                    && spineProfile.contains("poseBudgetStatus:"),
                "Spine profile diagnostics must expose per-pose frame-budget metrics"
            )
            check(
                spineProfile.contains("poseCacheProbe: idle")
                    && spineProfile.contains("poseCacheExactHitMs:")
                    && spineProfile.contains("poseCacheFrameHitMs:")
                    && spineProfile.contains("poseCacheStats: exactHits=")
                    && spineProfile.contains("frameHits=")
                    && spineProfile.contains("misses=")
                    && spineProfile.contains("stores="),
                "Spine profile diagnostics must expose runtime pose-cache hit and miss metrics"
            )
            if runtime.manifest.runtime.effectivePhysicsIdlePolicy == .sleepWhenIdle {
                check(
                    spineProfile.contains("frameHits=1")
                        && spineProfile.contains("stores=2")
                        && spineProfile.contains("entries=2"),
                    "sleep-when-idle physics policy must make idle native Spine poses eligible for frame-cache reuse"
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
                if hitZone.rubAction != nil,
                   hitZone.rubTailSeconds > hitZone.declaredRubTailSeconds + 0.005 {
                    let declaredRubTail = String(format: "%.2fs", hitZone.declaredRubTailSeconds)
                    let effectiveRubTail = String(format: "%.2fs", hitZone.rubTailSeconds)
                    check(
                        capabilitySummary.contains("rubTail=\(declaredRubTail) effectiveRubTail=\(effectiveRubTail)"),
                        "runtime capabilities must distinguish declared rubTail \(declaredRubTail) from effective rubTail \(effectiveRubTail) for hit zone \(hitZone.id)"
                    )
                }
                if runtime.manifest.metadata?.id == "sample_imported", hitZone.id == "head" {
                    check(
                        hitZone.tapAction == "boll"
                            && hitZone.action == "eye"
                            && hitZone.rubAction == "act"
                            && hitZone.trigger == .hold
                            && hitZone.holdStartSeconds >= 0.03
                            && hitZone.holdStartSeconds <= 0.10
                            && hitZone.holdCommitSeconds >= 0.12
                            && hitZone.holdCommitSeconds <= 0.35,
                        "Imported head interaction must map short head click to boll, quick stationary hold preview to eye, committed long press to eye, and held rub to act without using gaze direction semantics"
                    )
                }
                let clickController = InteractionController(
                    interactions: manifest.interactions,
                    policy: manifest.interactionPolicy,
                    actionTailDurations: tapActionDurations
                )
                clickController.pointerDown(at: center, button: acceptedButton)
                let downSnapshot = clickController.snapshot()
                let shortTouchAction = hitZone.tapAction ?? hitZone.action
                let defersShortTouchUntilRelease = hitZone.trigger == .hold && hitZone.tapAction != nil
                let pendingTouchAction = defersShortTouchUntilRelease ? interactionPlan.idleCommand() : shortTouchAction
                let pendingTouchPulseIsValid = defersShortTouchUntilRelease
                    ? downSnapshot.clickPulse == 0
                    : downSnapshot.clickPulse > 0
                check(
                    downSnapshot.command == pendingTouchAction && pendingTouchPulseIsValid,
                    "interaction controller must defer short-touch action \(shortTouchAction) until pointerUp when hit zone \(hitZone.id) also has hold/rub semantics"
                )
                clickController.pointerUp(at: center, button: acceptedButton)
                let upSnapshot = clickController.snapshot()
                check(
                    upSnapshot.command == shortTouchAction && upSnapshot.clickPulse > 0,
                    "interaction controller must keep initial click action \(shortTouchAction) visible after pointerUp for hit zone \(hitZone.id)"
                )
                if hasLookDirection {
                    let lookNeutral = SpineInteractionAnimationRoles.lookNeutralPoint(from: manifest)
                    let lookProbe = CGPoint(
                        x: lookNeutral.x > 0.5 ? 0.10 : 0.90,
                        y: lookNeutral.y
                    )
                    let expectedLookAction = interactionPlan.command(
                        for: lookProbe,
                        previousCommand: interactionPlan.idleCommand()
                    )
                    if expectedLookAction != interactionPlan.idleCommand() {
                        var smokeClock: CFTimeInterval = 0
                        let tailMaskController = InteractionController(
                            interactions: manifest.interactions,
                            policy: manifest.interactionPolicy,
                            actionTailDurations: tapActionDurations,
                            clock: { smokeClock }
                        )
                        tailMaskController.pointerDown(at: center, button: acceptedButton)
                        smokeClock += 0.016
                        tailMaskController.pointerUp(at: center, button: acceptedButton)
                        sendLookMove(tailMaskController, to: lookProbe)
                        for _ in 0..<20 {
                            smokeClock += 1.0 / 60.0
                            _ = tailMaskController.snapshot()
                        }
                        check(
                            tailMaskController.snapshot().command != expectedLookAction,
                            "click tail must be treated as stateful enough to mask an immediate independent gaze smoke for hit zone \(hitZone.id)"
                        )
                        tailMaskController.resetPointerTracking()
                        sendLookMove(tailMaskController, to: lookProbe)
                        for _ in 0..<20 {
                            smokeClock += 1.0 / 60.0
                            _ = tailMaskController.snapshot()
                        }
                        check(
                            tailMaskController.snapshot().command == expectedLookAction,
                            "runtime smoke must clear click tail state before independent gaze smoke for hit zone \(hitZone.id)"
                        )
                    }
                }
                if defersShortTouchUntilRelease, hitZone.holdCommitSeconds > hitZone.holdStartSeconds + 0.02 {
                    var boundaryClock: CFTimeInterval = 0
                    let preCommitReleaseController = InteractionController(
                        interactions: manifest.interactions,
                        policy: manifest.interactionPolicy,
                        actionTailDurations: tapActionDurations,
                        clock: { boundaryClock }
                    )
                    preCommitReleaseController.pointerDown(at: center, button: acceptedButton)
                    boundaryClock = max(hitZone.holdStartSeconds + 0.01, hitZone.holdCommitSeconds - 0.01)
                    check(
                        preCommitReleaseController.snapshot().command == hitZone.action,
                        "interaction controller must show hold preview action \(hitZone.action) after holdStartSeconds before hold commit for hit zone \(hitZone.id)"
                    )
                    preCommitReleaseController.pointerUp(at: center, button: acceptedButton)
                    check(
                        preCommitReleaseController.snapshot().command == shortTouchAction,
                        "interaction controller must still resolve pre-commit release to short-touch action \(shortTouchAction) for hit zone \(hitZone.id)"
                    )
                }
                let stoppedController = InteractionController(
                    interactions: manifest.interactions,
                    policy: manifest.interactionPolicy,
                    actionTailDurations: tapActionDurations
                )
                stoppedController.pointerDown(at: center, button: acceptedButton)
                stoppedController.pointerTrackingStopped()
                let stoppedSnapshot = stoppedController.snapshot()
                check(
                    stoppedSnapshot.command == pendingTouchAction,
                    "interaction controller must preserve pending click state when desktop tracking stops after pointerDown for hit zone \(hitZone.id)"
                )
                if hitZone.tapAction != nil {
                    var gestureClock: CFTimeInterval = 0
                    let holdController = InteractionController(
                        interactions: manifest.interactions,
                        policy: manifest.interactionPolicy,
                        actionTailDurations: tapActionDurations,
                        clock: { gestureClock }
                    )
                    holdController.pointerDown(at: center, button: acceptedButton)
                    let jitterAmplitude = max(min(hitZone.rubStartDistance * 0.40, 0.012), 0.0005)
                    let jitterRight = CGPoint(x: min(center.x + jitterAmplitude, 1.0), y: center.y)
                    let jitterLeft = CGPoint(x: max(center.x - jitterAmplitude, 0.0), y: center.y)
                    for jitterPoint in [jitterRight, jitterLeft, center, jitterRight, jitterLeft] {
                        holdController.pointerDragged(to: jitterPoint, button: acceptedButton)
                    }
                    let jitterSnapshot = holdController.snapshot()
                    check(
                        jitterSnapshot.command == interactionPlan.idleCommand(),
                        "interaction controller must keep hold/rub hit zone \(hitZone.id) pending for small pointer jitter before hold/rub thresholds"
                    )
                    gestureClock += max(hitZone.holdStartSeconds + 0.05, 0.10)
                    check(
                        holdController.snapshot().command == hitZone.action,
                        "interaction controller must promote hit zone \(hitZone.id) from tapAction to hold action \(hitZone.action) after holdStartSeconds without letting accumulated jitter become rub"
                    )
                    let holdReleaseController = InteractionController(
                        interactions: manifest.interactions,
                        policy: manifest.interactionPolicy,
                        actionTailDurations: tapActionDurations,
                        clock: { gestureClock }
                    )
                    gestureClock = 0
                    holdReleaseController.pointerDown(at: center, button: acceptedButton)
                    gestureClock += max(hitZone.holdCommitSeconds + 0.05, 0.10)
                    holdReleaseController.pointerUp(at: center, button: acceptedButton)
                    check(
                        holdReleaseController.snapshot().command == hitZone.action,
                        "interaction controller must resolve committed long stationary press to hold action \(hitZone.action) during pointerUp even when no held snapshot was sampled for hit zone \(hitZone.id)"
                    )
                    if let rubAction = hitZone.rubAction {
                        gestureClock = 0
                        let rubController = InteractionController(
                            interactions: manifest.interactions,
                            policy: manifest.interactionPolicy,
                            actionTailDurations: tapActionDurations,
                            clock: { gestureClock }
                        )
                        let rubDelta = hitZone.rubStartDistance + 0.02
                        let rubPoint = CGPoint(
                            x: center.x + rubDelta <= 1.0 ? center.x + rubDelta : max(center.x - rubDelta, 0.0),
                            y: center.y
                        )
                        let rubPoint2 = CGPoint(
                            x: rubPoint.x + rubDelta <= 1.0 ? rubPoint.x + rubDelta : max(rubPoint.x - rubDelta, 0.0),
                            y: center.y
                        )
                        rubController.pointerDown(at: center, button: acceptedButton)
                        rubController.pointerDragged(to: rubPoint, button: acceptedButton)
                        if hitZone.rubStartSeconds > 0 {
                            check(
                                rubController.snapshot().command == interactionPlan.idleCommand(),
                                "interaction controller must not promote hit zone \(hitZone.id) to rubAction \(rubAction) before rubStartSeconds"
                            )
                            gestureClock += max(hitZone.rubStartSeconds + 0.05, 0.10)
                            _ = rubController.snapshot()
                            rubController.pointerDragged(to: rubPoint2, button: acceptedButton)
                        }
                        check(
                            rubController.snapshot().command == rubAction,
                            "interaction controller must promote hit zone \(hitZone.id) to rubAction \(rubAction) only after rubStartSeconds and pointer displacement exceeds rubStartDistance"
                        )
                        let singlePostWindowDragController = InteractionController(
                            interactions: manifest.interactions,
                            policy: manifest.interactionPolicy,
                            actionTailDurations: tapActionDurations,
                            clock: { gestureClock }
                        )
                        gestureClock = 0
                        singlePostWindowDragController.pointerDown(at: center, button: acceptedButton)
                        gestureClock += max(hitZone.rubStartSeconds + 0.05, 0.10)
                        singlePostWindowDragController.pointerDragged(to: rubPoint, button: acceptedButton)
                        check(
                            singlePostWindowDragController.snapshot().command == rubAction,
                            "interaction controller must promote hit zone \(hitZone.id) to rubAction \(rubAction) on a single qualifying pointerDragged event after rubStartSeconds"
                        )
                        let preWindowDragThenStillController = InteractionController(
                            interactions: manifest.interactions,
                            policy: manifest.interactionPolicy,
                            actionTailDurations: tapActionDurations,
                            clock: { gestureClock }
                        )
                        gestureClock = 0
                        preWindowDragThenStillController.pointerDown(at: center, button: acceptedButton)
                        preWindowDragThenStillController.pointerDragged(to: rubPoint, button: acceptedButton)
                        gestureClock += max(hitZone.holdStartSeconds + 0.05, hitZone.rubStartSeconds + 0.05, 0.10)
                        check(
                            preWindowDragThenStillController.snapshot().command == hitZone.action,
                            "interaction controller must not promote pre-rubStart drag to rubAction \(rubAction) without a post-window pointerDragged event"
                        )
                        let preWindowDragThenSmallPostWindowDragController = InteractionController(
                            interactions: manifest.interactions,
                            policy: manifest.interactionPolicy,
                            actionTailDurations: tapActionDurations,
                            clock: { gestureClock }
                        )
                        let smallRubDelta = max(min(hitZone.rubStartDistance * 0.25, 0.01), 0.001)
                        let smallPostWindowRubPoint = CGPoint(
                            x: rubPoint.x + smallRubDelta <= 1.0 ? rubPoint.x + smallRubDelta : max(rubPoint.x - smallRubDelta, 0.0),
                            y: center.y
                        )
                        gestureClock = 0
                        preWindowDragThenSmallPostWindowDragController.pointerDown(at: center, button: acceptedButton)
                        preWindowDragThenSmallPostWindowDragController.pointerDragged(to: rubPoint, button: acceptedButton)
                        gestureClock += max(hitZone.rubStartSeconds + 0.05, 0.10)
                        preWindowDragThenSmallPostWindowDragController.pointerDragged(to: smallPostWindowRubPoint, button: acceptedButton)
                        check(
                            preWindowDragThenSmallPostWindowDragController.snapshot().command == rubAction,
                            "interaction controller must preserve pre-rubStart displacement when a post-window pointerDragged event confirms hit zone \(hitZone.id) rub intent"
                        )
                        let holdThenRubController = InteractionController(
                            interactions: manifest.interactions,
                            policy: manifest.interactionPolicy,
                            actionTailDurations: tapActionDurations,
                            clock: { gestureClock }
                        )
                        gestureClock = 0
                        holdThenRubController.pointerDown(at: center, button: acceptedButton)
                        gestureClock += max(hitZone.holdStartSeconds + 0.05, 0.10)
                        check(
                            holdThenRubController.snapshot().command == hitZone.action,
                            "interaction controller must first resolve stationary left-click hold \(hitZone.id) to hold action \(hitZone.action)"
                        )
                        holdThenRubController.pointerDragged(to: rubPoint, button: acceptedButton)
                        check(
                            holdThenRubController.snapshot().command == rubAction,
                            "interaction controller must still promote held hit zone \(hitZone.id) to rubAction \(rubAction) after hold action has started"
                        )
                        let rubReleaseController = InteractionController(
                            interactions: manifest.interactions,
                            policy: manifest.interactionPolicy,
                            actionTailDurations: tapActionDurations,
                            clock: { gestureClock }
                        )
                        gestureClock = 0
                        rubReleaseController.pointerDown(at: center, button: acceptedButton)
                        rubReleaseController.pointerUp(at: rubPoint, button: acceptedButton)
                        let earlyRubReleaseAction = hitZone.rubStartSeconds > 0 ? (hitZone.tapAction ?? hitZone.action) : rubAction
                        check(
                            rubReleaseController.snapshot().command == earlyRubReleaseAction,
                            "interaction controller must not resolve pre-rubStart drag release for hit zone \(hitZone.id) to rubAction \(rubAction)"
                        )
                        let releaseOnlyRubController = InteractionController(
                            interactions: manifest.interactions,
                            policy: manifest.interactionPolicy,
                            actionTailDurations: tapActionDurations,
                            clock: { gestureClock }
                        )
                        gestureClock = 0
                        releaseOnlyRubController.pointerDown(at: center, button: acceptedButton)
                        let releaseOnlySampleTime = max(hitZone.rubStartSeconds + 0.05, 0.10)
                        gestureClock += releaseOnlySampleTime
                        releaseOnlyRubController.pointerUp(at: rubPoint, button: acceptedButton)
                        let releaseOnlyExpectedAction = releaseOnlySampleTime >= hitZone.holdCommitSeconds
                            ? hitZone.action
                            : (hitZone.tapAction ?? hitZone.action)
                        check(
                            releaseOnlyRubController.snapshot().command == releaseOnlyExpectedAction,
                            "interaction controller must not treat pointerUp position drift as held rub for hit zone \(hitZone.id)"
                        )
                        let longReleaseOnlyRubController = InteractionController(
                            interactions: manifest.interactions,
                            policy: manifest.interactionPolicy,
                            actionTailDurations: tapActionDurations,
                            clock: { gestureClock }
                        )
                        gestureClock = 0
                        longReleaseOnlyRubController.pointerDown(at: center, button: acceptedButton)
                        gestureClock += max(hitZone.holdCommitSeconds + 0.05, hitZone.rubStartSeconds + 0.05, 0.10)
                        longReleaseOnlyRubController.pointerUp(at: rubPoint, button: acceptedButton)
                        check(
                            longReleaseOnlyRubController.snapshot().command == hitZone.action,
                            "interaction controller must resolve long press with pointerUp drift to hold action \(hitZone.action), not rubAction \(rubAction), for hit zone \(hitZone.id)"
                        )
                    }
                }
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
        let parsedSelectedOnlyDisplayMode = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--display-mode", "selectedOnly",
            "--validate-only"
        ])
        let parsedSelectedPolicyDisplayMode = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--display-mode", "selectedPolicy",
            "--validate-only"
        ])
        let parsedAllFullDisplayMode = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--display-mode", "allFull",
            "--validate-only"
        ])
        check(
            parsedSelectedOnlyDisplayMode.displayMode == .primaryOnly
                && parsedSelectedPolicyDisplayMode.displayMode == .primaryAnimated
                && parsedAllFullDisplayMode.displayMode == .all,
            "EngineConfig must parse user-facing display mode aliases"
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
        let parsedRuntimeDisplayRebuildSmoke = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--run-runtime-display-rebuild-smoke",
            "--validate-only"
        ])
        check(
            parsedRuntimeDisplayRebuildSmoke.runtimeDisplayRebuildSmoke,
            "EngineConfig must parse runtime display rebuild smoke diagnostics"
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
            EngineConfig.help.contains("--print-manifest-schema"),
            "EngineConfig help must document wallpaper manifest schema export"
        )
        check(
            EngineConfig.help.contains("--source-provenance"),
            "EngineConfig help must document source provenance diagnostics"
        )
        check(
            EngineConfig.help.contains("--source-adapter-audit"),
            "EngineConfig help must document library-wide source adapter diagnostics"
        )
        let manifestSchemaText = try ManifestSchemaResource.loadText(projectRoot: runtime.config.projectRoot)
        let manifestSchemaJSON = try JSONSerialization.jsonObject(
            with: Data(manifestSchemaText.utf8),
            options: []
        ) as? [String: Any]
        check(
            manifestSchemaJSON?["title"] as? String == "Mac Wallpaper Engine Native Manifest v2"
                && manifestSchemaText.contains("\"macos-wallpaper-native.v2\"")
                && manifestSchemaText.contains("\"sourceProvenance\"")
                && manifestSchemaText.contains("\"sourceDescriptors\"")
                && manifestSchemaText.contains("\"sourceAdapter\"")
                && manifestSchemaText.contains("\"fieldDerivations\"")
                && manifestSchemaText.contains("\"unity-managed-script-index\"")
                && manifestSchemaText.contains("\"platformPolicyFields\"")
                && manifestSchemaText.contains("\"pointerSampleFps\"")
                && manifestSchemaText.contains("\"nativeSpineTransitionSeconds\"")
                && manifestSchemaText.contains("\"nativeSpineTransitionPolicy\"")
                && manifestSchemaText.contains("\"actionSeconds\"")
                && manifestSchemaText.contains("\"releaseSeconds\"")
                && manifestSchemaText.contains("\"physicsIdlePolicy\"")
                && manifestSchemaText.contains("\"tapAction\"")
                && manifestSchemaText.contains("\"rubAction\"")
                && manifestSchemaText.contains("\"rubStartSeconds\"")
                && manifestSchemaText.contains("\"semi-implicit-euler\"")
                && manifestSchemaText.contains("\"stiffness\""),
            "manifest schema resource must be valid JSON and cover current v2 provenance and interaction fields"
        )
        check(
            manifestSchemaJSON != nil,
            "manifest schema resource must decode into a JSON object before supported-subset validation"
        )
        let transitionPolicy = SpineSetupPoseRenderer.AnimationTransitionPolicy(
            defaultSeconds: 0.30,
            lookSeconds: 0.30,
            actionSeconds: 0.05,
            releaseSeconds: 0.15
        )
        check(
            abs(transitionPolicy.duration(
                from: "idle",
                to: "Left",
                idleAnimationName: "idle",
                lookAnimationNames: ["Left", "Right", "Up", "Down"]
            ) - 0.30) < 0.001,
            "native Spine transition policy must keep look-direction animations smooth"
        )
        check(
            abs(transitionPolicy.duration(
                from: "idle",
                to: "boll",
                idleAnimationName: "idle",
                lookAnimationNames: ["Left", "Right", "Up", "Down"]
            ) - 0.05) < 0.001,
            "native Spine transition policy must make tap/hold/rub actions visually responsive"
        )
        check(
            abs(transitionPolicy.duration(
                from: "eye",
                to: "idle",
                idleAnimationName: "idle",
                lookAnimationNames: ["Left", "Right", "Up", "Down"]
            ) - 0.15) < 0.001,
            "native Spine transition policy must use release timing when an action returns to idle"
        )
        if let manifestSchemaJSON {
            try ManifestSchemaResource.validateSupportedSchemaSubset(manifestSchemaJSON)
        }
        do {
            try ManifestSchemaResource.validateSupportedSchemaSubset([
                "type": "object",
                "dependentRequired": [
                    "bindings": ["effects"]
                ]
            ])
            failures.append("manifest schema subset guard must reject unsupported JSON Schema keywords before they can be silently ignored")
        } catch {
            check(
                error.localizedDescription.contains("Unsupported schema keyword dependentRequired"),
                "manifest schema subset guard must reject unsupported JSON Schema keywords before they can be silently ignored"
            )
        }
        let schemaCheckedBundles = WallpaperBundleCatalog.discover(
            in: runtime.config.projectRoot.appendingPathComponent("wallpapers")
        )
        for bundle in schemaCheckedBundles {
            try ManifestSchemaResource.validateManifest(
                at: bundle.manifestURL,
                projectRoot: runtime.config.projectRoot
            )
        }
        try assertGenericRuntimeSourceBoundary(
            projectRoot: runtime.config.projectRoot,
            discoveredBundles: schemaCheckedBundles,
            failures: &failures,
            checks: &checks
        )
        check(
            schemaCheckedBundles.isEmpty == false,
            "manifest schema self-test must validate at least one bundled wallpaper manifest"
        )
        check(
            EngineConfig.help.contains("--recovery-plan"),
            "EngineConfig help must document renderer recovery diagnostics"
        )
        check(
            EngineConfig.help.contains("--doctor"),
            "EngineConfig help must document combined runtime doctor diagnostics"
        )
        check(
            EngineConfig.help.contains("--physical-display-plan")
                && EngineConfig.help.contains("--physical-render-plan"),
            "EngineConfig help must document physical CoreGraphics display diagnostics"
        )
        check(
            EngineConfig.help.contains("--input-status")
                && EngineConfig.help.contains("--request-accessibility") == false,
            "EngineConfig help must document no-prompt input diagnostics and omit Accessibility request flow"
        )
        check(
            EngineConfig.help.contains("--completion-audit")
                && EngineConfig.help.contains("--manual-smoke-evidence"),
            "EngineConfig help must document objective-level completion audit diagnostics and manual smoke evidence ingestion"
        )
        check(
            EngineConfig.help.contains("--write-manual-smoke-template"),
            "EngineConfig help must document manual smoke evidence template generation"
        )
        check(
            EngineConfig.help.contains("--record-manual-smoke-evidence")
                && EngineConfig.help.contains("--confirm-live-click-actions")
                && EngineConfig.help.contains("--live-click-actions-note")
                && EngineConfig.help.contains("--confirm-physical-display-hotplug")
                && EngineConfig.help.contains("--physical-display-hotplug-event")
                && EngineConfig.help.contains("--physical-display-hotplug-note")
                && EngineConfig.help.contains("--confirm-black-frame-flicker"),
            "EngineConfig help must document manual smoke evidence recording"
        )
        check(
            EngineConfig.help.contains("--write-runtime-smoke-evidence")
                && EngineConfig.help.contains("--run-runtime-interaction-smoke")
                && EngineConfig.help.contains("--run-runtime-display-rebuild-smoke"),
            "EngineConfig help must document runtime smoke telemetry, interaction, and display-rebuild evidence generation"
        )
        check(
            EngineConfig.help.contains("--spine-profile"),
            "EngineConfig help must document native Spine profile diagnostics"
        )
        check(
            EngineConfig.help.contains("--snapshot-pointer")
                && EngineConfig.help.contains("--snapshot-pointer-down")
                && EngineConfig.help.contains("--snapshot-pointer-press-duration")
                && EngineConfig.help.contains("--snapshot-pointer-drag-distance"),
            "EngineConfig help must document wallpaper snapshot declarative input diagnostics"
        )
        let snapshotActionForParse = manifestActionNames.sorted().first ?? "idle"
        let parsedSpineSnapshot = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--spine-snapshot", "/tmp/native-spine-snapshot.png",
            "--snapshot-action", snapshotActionForParse,
            "--snapshot-time", "1.25",
            "--snapshot-size", "640x360"
        ])
        check(
            parsedSpineSnapshot.spineSnapshotURL?.path == "/tmp/native-spine-snapshot.png"
                && parsedSpineSnapshot.spineSnapshotAction == snapshotActionForParse
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
        let parsedWallpaperSnapshotInput = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--wallpaper-snapshot", "/tmp/wallpaper-snapshot-input.png",
            "--snapshot-pointer", "0.8,0.2",
            "--snapshot-pointer-down",
            "--snapshot-pointer-speed", "5.5",
            "--snapshot-pointer-press-duration", "1.25",
            "--snapshot-pointer-drag-distance", "0.1",
            "--snapshot-thermal-state", "2"
        ])
        let parsedSnapshotInput = try parsedWallpaperSnapshotInput.snapshotInput.evaluationInput(
            systemTimeSeconds: 2.5,
            context: "self-test"
        )
        check(
            parsedSnapshotInput.pointerPosition == CGPoint(x: 0.8, y: 0.2)
                && parsedSnapshotInput.pointerDown
                && abs(parsedSnapshotInput.pointerSpeed - 5.5) < 0.001
                && abs(parsedSnapshotInput.pointerPressDurationSeconds - 1.25) < 0.001
                && abs(parsedSnapshotInput.pointerDragDistance - 0.1) < 0.001
                && abs(parsedSnapshotInput.thermalStateLevel - 2) < 0.001,
            "EngineConfig must parse wallpaper snapshot declarative pointer input overrides"
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
        let parsedSpineProfile = try EngineConfig.parse([
            "--wallpaper-root", runtime.config.wallpaperRoot.path,
            "--spine-profile"
        ])
        check(
            parsedSpineProfile.spineProfileOnly,
            "EngineConfig must parse native Spine profile diagnostics"
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
        let physicalDisplaySummary = DisplayPlanner.summary(runtime: nativeRuntime)
        if physicalDisplaySummary.contains("no screens detected") == false {
            check(
                physicalDisplaySummary.contains("displayProbe: physical(coregraphics)")
                    && physicalDisplaySummary.contains("displayCount:")
                    && physicalDisplaySummary.contains("identity=displayID:"),
                "physical display plan summary must expose actual CoreGraphics display count and identities"
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
        let physicalRenderSummary = DisplayPlanner.renderSummary(runtime: nativeRuntime)
        if physicalRenderSummary.contains("no screens detected") == false {
            check(
                physicalRenderSummary.contains("displayProbe: physical(coregraphics)")
                    && physicalRenderSummary.contains("displayCount:")
                    && physicalRenderSummary.contains("background=")
                    && physicalRenderSummary.contains("foreground="),
                "physical render plan summary must expose actual CoreGraphics display render paths"
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
        let activeBundleID = runtime.manifest.metadata?.id ?? runtime.config.wallpaperRoot.lastPathComponent
        check(
            bundleMatrix.contains("bundle validation matrix OK")
                && bundleMatrix.contains(activeBundleID)
                && bundleMatrix.contains("sample_video")
                && bundleMatrix.contains("sample_static")
                && bundleMatrix.contains("sample_effect")
                && bundleMatrix.contains("sample_binding_click")
                && bundleMatrix.contains("sample_spring_effect")
                && bundleMatrix.contains("sample_spring_spine")
                && bundleMatrix.contains("sample_trigger_play_spine")
                && bundleMatrix.contains("sample_spine_fallback")
                && bundleMatrix.contains("displayModes: selectedOnly+selectedPolicy+allFull"),
            "bundle validation matrix must cover native Spine/video, video-only, static-image, effect fixture, pointer-down binding fixture, pointer spring effect fixture, pointer spring Spine fixture, trigger-play Spine binding fixture, unsupported Spine fallback fixture, and multi-display simulated render plans"
        )
        check(
            occurrenceCount("displayRefreshFps: primary120+secondary60", in: bundleMatrix) == 9,
            "bundle validation matrix must validate display-refresh FPS matching for every bundled renderer family"
        )
        check(
            bundleMatrix.contains("interactionPlan: active(desktop-empty-only+no-permission-best-effort)")
                && occurrenceCount("interactionPlan: passive(no-interactions)", in: bundleMatrix) >= 3,
            "bundle validation matrix must validate active no-permission desktop interactions and passive no-interaction bundles"
        )
        check(
            bundleMatrix.contains("performancePlan: target=60 fallback=30 budgeted")
                && occurrenceCount("performancePlan: target=30 fallback=15 budgeted", in: bundleMatrix) >= 5,
            "bundle validation matrix must validate performance budget plans for native Spine, video-only, static-image, effect fixture, pointer-down binding fixture, pointer spring effect fixture, and unsupported Spine fallback bundles"
        )
        check(
            occurrenceCount("doctor: pass", in: bundleMatrix) == 9,
            "bundle validation matrix must validate the combined runtime doctor report for every bundled renderer family"
        )
        check(
            occurrenceCount("libraryReport: listed=9 invalid=0 capabilities", in: bundleMatrix) == 9,
            "bundle validation matrix must validate the bundle library list report and capability rows"
        )
        let bundleMatrixHasSourceProvenanceStatus = bundleMatrix.contains("sourceProvenance: pass")
            || bundleMatrix.contains("sourceProvenance: warn")
        check(
            bundleMatrix.contains("source: wallpaper-engine-application runtime=Unity project=application descriptors=3 imported=13 calibrated=12 platformPolicy=4 unsupported=1")
                && bundleMatrixHasSourceProvenanceStatus
                && bundleMatrix.contains("sourceDerivation: partial imported=13 calibrated=12 platformPolicy=4 unsupported=1 blockers=manual-calibration+unsupported-source-behavior")
                && bundleMatrix.contains("source: sample runtime=native project=test-fixture descriptors=0 imported=4 calibrated=0 platformPolicy=0 unsupported=0")
                && bundleMatrix.contains("source: sample runtime=native project=test-fixture descriptors=0 imported=5 calibrated=0 platformPolicy=0 unsupported=0")
                && bundleMatrix.contains("source: sample runtime=native project=test-fixture descriptors=0 imported=3 calibrated=0 platformPolicy=0 unsupported=0")
                && occurrenceCount("source: sample runtime=native project=test-fixture descriptors=0 imported=2 calibrated=0 platformPolicy=0 unsupported=0", in: bundleMatrix) >= 2,
            "bundle validation matrix must expose source provenance so bundle-specific settings stay outside the generic runtime"
        )
        check(
            bundleMatrix.contains("effects: scroll+colorMatrix+blur+chromaticAberration+vignette+pixelate"),
            "bundle validation matrix must expose the sample effect fixture capability rows"
        )
        check(
            bundleMatrix.contains("sample_binding_click")
                && bundleMatrix.contains("input: desktop-empty-best-effort")
                && bundleMatrix.contains("bindings: map-range")
                && bundleMatrix.contains("pointerDownBindings=pressBrightness:pointer.down->effect.tone.brightness")
                && bundleMatrix.contains("dragShadeIntensity:pointer.dragDistance->effect.dragShade.intensity"),
            "bundle validation matrix must treat pointer.down and pointer.dragDistance declarative effect bindings as active desktop input without requiring hit-zone animations"
        )
        check(
            bundleMatrix.contains("sample_spring_effect")
                && bundleMatrix.contains("interactions: pointerMove")
                && bundleMatrix.contains("bindings: spring")
                && bundleMatrix.contains("effects: blur")
                && bundleMatrix.contains("input: desktop-empty-best-effort"),
            "bundle validation matrix must expose pointer.position spring bindings to whitelist effects as manifest-owned runtime input"
        )
        check(
            bundleMatrix.contains("sample_spring_spine")
                && bundleMatrix.contains("interactions: pointerMove")
                && bundleMatrix.contains("bindings: spring")
                && bundleMatrix.contains("native: supported")
                && bundleMatrix.contains("input: desktop-empty-best-effort"),
            "bundle validation matrix must expose pointer.position spring bindings to Spine bones as manifest-owned runtime input"
        )
        check(
            bundleMatrix.contains("sample_trigger_play_spine")
                && bundleMatrix.contains("bindings: trigger-play")
                && bundleMatrix.contains("native: supported")
                && bundleMatrix.contains("pointerDownBindings=tapPulse:pointer.down->spine.animation.pulse"),
            "bundle validation matrix must expose pointer.down trigger-play bindings to Spine animations as manifest-owned runtime input"
        )
        check(
            bundleMatrix.contains("golden: pass fixtures: 8")
                && occurrenceCount("golden: pass fixtures: 1", in: bundleMatrix) >= 3,
            "bundle validation matrix must run bundle-local golden fixtures across native Spine, video-only, static-image, and effect samples"
        )
        check(
            occurrenceCount("installer: importable", in: bundleMatrix) == 9,
            "bundle validation matrix must prove every bundled renderer family can be imported into a user library"
        )
        let completionAudit = try RuntimeCompletionAudit.make(
            projectRoot: runtime.config.projectRoot,
            strictCompositeQuality: true,
            includeInvalid: true,
            bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")]
        )
        check(
            completionAudit.contains("wallpaper completion audit")
                && completionAudit.contains("overall: automated-pass/manual-evidence-open")
                && completionAudit.contains("automated\tpass\tbundle-discovery-library")
                && completionAudit.contains("automated\tpass\twallpaper-bundle-contract")
                && completionAudit.contains("automated\tpass\tsource-adapter-library-audit")
                && completionAudit.contains("adapterContracts=")
                && completionAudit.contains("sourceDerived=")
                && completionAudit.contains("automated\tpass\tgeneric-player-contract")
                && completionAudit.contains("automated\tpass\tdeclarative-binding-contract")
                && completionAudit.contains("sources=pointer.position+pointer.x+pointer.y+pointer.down+pointer.speed+pointer.pressDuration+pointer.dragDistance+system.time+thermal.state")
                && completionAudit.contains("sample_binding_click=bindings(map-range)")
                && completionAudit.contains("pressBrightness:pointer.down->effect.tone.brightness via map-range runtime-executable")
                && completionAudit.contains("moveOpacity:pointer.speed->effect.tone.opacity via map-range runtime-executable")
                && completionAudit.contains("speedSaturation:pointer.speed->effect.tone.saturation via map-range runtime-executable")
                && completionAudit.contains("cursorPanY:pointer.x->effect.cursorPan.offsetY via map-range runtime-executable")
                && completionAudit.contains("holdBlurRadius:pointer.pressDuration->effect.holdBlur.radius via map-range runtime-executable")
                && completionAudit.contains("dragShadeIntensity:pointer.dragDistance->effect.dragShade.intensity via map-range runtime-executable")
                && completionAudit.contains("cursorShadeRadius:pointer.y->effect.dragShade.radius via map-range runtime-executable")
                && completionAudit.contains("sample_spring_effect=bindings(spring)")
                && completionAudit.contains("pointerSpringBlur:pointer.position->effect.softBlur.radius via spring runtime-executable")
                && completionAudit.contains("sample_spring_spine=bindings(spring)")
                && completionAudit.contains("pointerSpringRoot:pointer.position->spine.bone.root via spring runtime-executable")
                && completionAudit.contains("requiredRuntimeAdapters=smooth-lookat:ok+trigger-play:ok+map-range:pointer-down-effect:ok+map-range:pointer-speed-effect:ok+map-range:pointer-press-duration-effect:ok+map-range:pointer-drag-distance-effect:ok+spring:effect:ok+spring:spine-bone:ok")
                && completionAudit.contains("sample_trigger_play_spine=bindings(trigger-play)")
                && completionAudit.contains("tapPulse:pointer.down->spine.animation.pulse via trigger-play runtime-executable")
                && completionAudit.contains("discovered=map-range+none+smooth-lookat+spring+trigger-play")
                && completionAudit.contains("spring(effect-runtime+pointer-spine-runtime,explicit-dynamics-contract)")
                && completionAudit.contains("sample_trigger_play_spine=manifest-owned")
                && completionAudit.contains("actions[pulse]")
                && completionAudit.contains("automated\tpass\twhitelist-effect-contract")
                && completionAudit.contains("blur(runtime-rendered)+colorMatrix(runtime-rendered)+scroll(runtime-rendered)+chromaticAberration(runtime-rendered)+vignette(runtime-rendered)+pixelate(runtime-rendered)")
                && completionAudit.contains("requiredWhitelistEffects=blur:ok+chromaticAberration:ok+colorMatrix:ok+pixelate:ok+scroll:ok+vignette:ok")
                && completionAudit.contains("effectContracts=budget+fallback")
                && completionAudit.contains("sample_effect=effects(scroll+colorMatrix+blur+chromaticAberration+vignette+pixelate)")
                && completionAudit.contains("loopPan:scroll properties=1 runtime-rendered")
                && completionAudit.contains("tone:colorMatrix properties=3 runtime-rendered")
                && completionAudit.contains("softBlur:blur properties=1 runtime-rendered")
                && completionAudit.contains("split:chromaticAberration properties=1 runtime-rendered")
                && completionAudit.contains("edgeShade:vignette properties=2 runtime-rendered")
                && completionAudit.contains("pixelGrid:pixelate properties=1 runtime-rendered")
                && completionAudit.contains("dynamicShaderLoading=forbidden")
                && completionAudit.contains("automated\tpass\tdeclarative-safety-boundary")
                && completionAudit.contains("layerTypes=spine+static_image+video")
                && completionAudit.contains("effectTypes=blur+chromaticAberration+colorMatrix+pixelate+scroll+vignette")
                && completionAudit.contains("bindingSources=pointer.down+pointer.dragDistance+pointer.position+pointer.pressDuration+pointer.speed+pointer.x+pointer.y+system.time+thermal.state")
                && completionAudit.contains("bindingAdapters=map-range+smooth-lookat+spring+trigger-play")
                && completionAudit.contains("bindingTargetPattern=engine-owned")
                && completionAudit.contains("denied=script-layer+shader-effect+command-file-network-source")
                && completionAudit.contains("automated\tpass\tgeneric-runtime-source-boundary")
                && (completionAudit.contains("source scan passed") || completionAudit.contains("source scan skipped"))
                && completionAudit.contains("sample_imported=manifest-owned")
                && completionAudit.contains("interactions[pointerMove{")
                && completionAudit.contains("sample_imported=source(wallpaper-engine-application runtime=Unity project=application descriptors=3 imported=13 calibrated=12 platformPolicy=4 unsupported=1); derivation(partial imported=13 calibrated=12 platformPolicy=4 unsupported=1")
                && completionAudit.contains("automated\tpass\trenderer-family-coverage")
                && completionAudit.contains("effects=blur+chromaticAberration+colorMatrix+pixelate+scroll+vignette")
                && completionAudit.contains("automated\tpass\tnative-spine-default-fallback")
                && completionAudit.contains("autoNative:true compositeDefault:false")
                && completionAudit.contains("automated\tpass\tunsupported-spine-composite-fallback")
                && completionAudit.contains("sample_spine_fallback=nativeUnsupported:true fallback:composite autoComposite:true diagnostics:true")
                && completionAudit.contains("automated\tpass\tunsupported-spine-fallback-taxonomy")
                && completionAudit.contains("sample_spine_fallback=classes(attachment-type+blend-mode+invalid-reference+renderer-slice)")
                && completionAudit.contains("unsupported attachment types: sequence")
                && completionAudit.contains("unsupported blend modes: hard-light")
                && completionAudit.contains("automated\tpass\tmulti-display-lifecycle")
                && completionAudit.contains("automated\tpass\tperformance-budget")
                && completionAudit.contains("manual\tmanual\tlive-desktop-click-actions")
                && completionAudit.contains("manual\tmanual\tphysical-display-hotplug-smoke")
                && completionAudit.contains("manual\tmanual\tblack-frame-flicker-smoke")
                && completionAudit.contains("protocol\tmanual\tlive-desktop-click-actions-protocol")
                && completionAudit.contains("manifest-declared pointerMove/pointerDown")
                && completionAudit.contains("sample_imported{move:")
                && completionAudit.contains("protocol\tmanual\tphysical-display-hotplug-smoke-protocol")
                && completionAudit.contains("selectedOnly=primary-only")
                && completionAudit.contains("protocol\tmanual\tblack-frame-flicker-smoke-protocol")
                && completionAudit.contains("scope\tdeferred\tfull-source-behavior-import")
                && completionAudit.contains("scope\tdeferred\tfull-spine-4.2-parity"),
            "completion audit must summarize objective-level automated evidence and exact manual smoke protocols without falsely claiming full manual/product completion"
        )
        let manualSmokeEvidenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineManualSmoke-\(UUID().uuidString).json")
        let currentLiveClickProtocol = try RuntimeCompletionAudit.currentLiveClickProtocolText(
            projectRoot: runtime.config.projectRoot,
            bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")]
        )
        let liveClickObservationNote = "self-test observed tap hold rub empty click and gaze behavior"
        let currentLiveClickProtocolJSON = currentLiveClickProtocol
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let currentLiveClickProtocolEncodedJSON = currentLiveClickProtocolJSON
            .replacingOccurrences(of: "/", with: "\\/")
        let currentPhysicalDisplayProtocol = RuntimeCompletionAudit.physicalDisplayHotplugProtocolText()
        let currentPhysicalDisplayProtocolJSON = currentPhysicalDisplayProtocol
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let currentPhysicalDisplayProtocolEncodedJSON = currentPhysicalDisplayProtocolJSON
            .replacingOccurrences(of: "/", with: "\\/")
        let currentBlackFrameFlickerProtocol = RuntimeCompletionAudit.currentBlackFrameFlickerProtocolText()
        let currentBlackFrameFlickerProtocolJSON = currentBlackFrameFlickerProtocol
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let currentBlackFrameFlickerProtocolEncodedJSON = currentBlackFrameFlickerProtocolJSON
            .replacingOccurrences(of: "/", with: "\\/")
        let manualSmokeEvidence = """
        {
          "schemaVersion": "mac-wallpaper-manual-smoke.v1",
          "packagedAppLaunchSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "packaged app launched from Finder or package smoke gate without crash"
          },
          "liveDesktopClickActions": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "Operator confirmed live click/gaze interactions against the selected wallpaper manifest-declared pointerMove and pointerDown actions. Protocol: \(currentLiveClickProtocolJSON)",
            "operatorNote": "\(liveClickObservationNote)",
            "protocolText": "\(currentLiveClickProtocolJSON)"
          },
          "physicalDisplayHotplugSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "selectedOnly primary-only, selectedPolicy secondary-passive, allFull all-displays, reconnect restored wallpaper windows on target displays. Protocol: \(currentPhysicalDisplayProtocolJSON)",
            "operatorNote": "self-test observed reconnect event restored external secondary target displays; Displays have separate Spaces enabled",
            "protocolText": "\(currentPhysicalDisplayProtocolJSON)"
          },
          "blackFrameFlickerSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "packaged app start, mode switch, display rebuild produced no black frame, no visible flicker loop, and no crash. Protocol: \(currentBlackFrameFlickerProtocolJSON)",
            "protocolText": "\(currentBlackFrameFlickerProtocolJSON)"
          }
        }
        """
        try manualSmokeEvidence.write(to: manualSmokeEvidenceURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: manualSmokeEvidenceURL)
        }
        let completionAuditWithManualEvidence = try RuntimeCompletionAudit.make(
            projectRoot: runtime.config.projectRoot,
            strictCompositeQuality: true,
            includeInvalid: true,
            bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")],
            manualEvidenceURL: manualSmokeEvidenceURL
        )
        check(
            completionAuditWithManualEvidence.contains("overall: complete-evidence-pass")
                && completionAuditWithManualEvidence.contains("automated\tpass\twallpaper-bundle-contract")
                && completionAuditWithManualEvidence.contains("manual\tpass\tpackaged-app-launch-smoke")
                && completionAuditWithManualEvidence.contains("manual\tpass\tlive-desktop-click-actions")
                && completionAuditWithManualEvidence.contains("manual\tpass\tphysical-display-hotplug-smoke")
                && completionAuditWithManualEvidence.contains("manual\tpass\tblack-frame-flicker-smoke")
                && completionAuditWithManualEvidence.contains("manual evidence: recordedAt=self-test"),
            "completion audit must accept explicit user-recorded manual smoke evidence before claiming complete evidence pass"
        )
        let staleLiveClickEvidenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineStaleLiveClickSmoke-\(UUID().uuidString).json")
        let staleLiveClickEvidence = """
        {
          "schemaVersion": "mac-wallpaper-manual-smoke.v1",
          "packagedAppLaunchSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "packaged app launched from Finder or package smoke gate without crash"
          },
          "liveDesktopClickActions": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "Operator confirmed live click/gaze interactions against an older selected wallpaper manifest-declared pointerMove and pointerDown action set.",
            "operatorNote": "\(liveClickObservationNote)",
            "protocolText": "verify manifest-declared pointerMove/pointerDown behavior: old-protocol"
          },
          "physicalDisplayHotplugSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "selectedOnly primary-only, selectedPolicy secondary-passive, allFull all-displays, reconnect restored wallpaper windows on target displays",
            "operatorNote": "self-test observed reconnect event restored external secondary target displays; Displays have separate Spaces enabled"
          },
          "blackFrameFlickerSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "packaged app start, mode switch, display rebuild produced no black frame, no visible flicker loop, and no crash"
          }
        }
        """
        try staleLiveClickEvidence.write(to: staleLiveClickEvidenceURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: staleLiveClickEvidenceURL)
        }
        let completionAuditWithStaleLiveClickEvidence = try RuntimeCompletionAudit.make(
            projectRoot: runtime.config.projectRoot,
            strictCompositeQuality: true,
            includeInvalid: true,
            bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")],
            manualEvidenceURL: staleLiveClickEvidenceURL
        )
        check(
            completionAuditWithStaleLiveClickEvidence.contains("overall: automated-pass/manual-evidence-open")
                && completionAuditWithStaleLiveClickEvidence.contains("manual\tmanual\tlive-desktop-click-actions")
                && completionAuditWithStaleLiveClickEvidence.contains("manual evidence stale:"),
            "completion audit must reopen live click evidence when the recorded interaction protocol no longer matches the current manifest"
        )
        let wakePhysicalHotplugEvidenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineWakePhysicalSmoke-\(UUID().uuidString).json")
        let wakePhysicalHotplugEvidence = """
        {
          "schemaVersion": "mac-wallpaper-manual-smoke.v1",
          "physicalDisplayHotplugSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "selectedOnly primary-only, selectedPolicy secondary-passive, allFull all-displays, wake restored wallpaper windows on target displays. Protocol: \(currentPhysicalDisplayProtocolJSON)",
            "operatorNote": "self-test observed display wake restored external secondary target displays; Displays have separate Spaces enabled",
            "protocolText": "\(currentPhysicalDisplayProtocolJSON)"
          }
        }
        """
        try wakePhysicalHotplugEvidence.write(
            to: wakePhysicalHotplugEvidenceURL,
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? FileManager.default.removeItem(at: wakePhysicalHotplugEvidenceURL)
        }
        let completionAuditWithWakeManualEvidence = try RuntimeCompletionAudit.make(
            projectRoot: runtime.config.projectRoot,
            strictCompositeQuality: true,
            includeInvalid: true,
            bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")],
            manualEvidenceURL: wakePhysicalHotplugEvidenceURL
        )
        check(
            completionAuditWithWakeManualEvidence.contains("manual\tpass\tphysical-display-hotplug-smoke")
                && completionAuditWithWakeManualEvidence.contains("wake restored wallpaper windows"),
            "completion audit must accept wake restoration as a physical display lifecycle pass alternative to reconnect"
        )
        let stalePhysicalHotplugEvidenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineStalePhysicalSmoke-\(UUID().uuidString).json")
        let stalePhysicalHotplugEvidence = """
        {
          "schemaVersion": "mac-wallpaper-manual-smoke.v1",
          "packagedAppLaunchSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "packaged app launched from Finder or package smoke gate without crash"
          },
          "liveDesktopClickActions": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "Operator confirmed live click/gaze interactions against the selected wallpaper manifest-declared pointerMove and pointerDown actions. Protocol: \(currentLiveClickProtocolJSON)",
            "operatorNote": "\(liveClickObservationNote)",
            "protocolText": "\(currentLiveClickProtocolJSON)"
          },
          "physicalDisplayHotplugSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "selectedOnly primary-only, selectedPolicy secondary-passive, allFull all-displays, reconnect restored wallpaper windows on target displays",
            "operatorNote": "self-test observed reconnect event restored external secondary target displays; Displays have separate Spaces enabled",
            "protocolText": "old-physical-display-protocol"
          },
          "blackFrameFlickerSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "packaged app start, mode switch, display rebuild produced no black frame, no visible flicker loop, and no crash"
          }
        }
        """
        try stalePhysicalHotplugEvidence.write(
            to: stalePhysicalHotplugEvidenceURL,
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? FileManager.default.removeItem(at: stalePhysicalHotplugEvidenceURL)
        }
        let completionAuditWithStalePhysicalEvidence = try RuntimeCompletionAudit.make(
            projectRoot: runtime.config.projectRoot,
            strictCompositeQuality: true,
            includeInvalid: true,
            bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")],
            manualEvidenceURL: stalePhysicalHotplugEvidenceURL
        )
        check(
            completionAuditWithStalePhysicalEvidence.contains("overall: automated-pass/manual-evidence-open")
                && completionAuditWithStalePhysicalEvidence.contains("manual\tmanual\tphysical-display-hotplug-smoke")
                && completionAuditWithStalePhysicalEvidence.contains("manual evidence stale:"),
            "completion audit must reopen physical display evidence when the recorded display protocol no longer matches the current contract"
        )
        let staleBlackFrameFlickerEvidenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineStaleBlackFrameSmoke-\(UUID().uuidString).json")
        let staleBlackFrameFlickerEvidence = """
        {
          "schemaVersion": "mac-wallpaper-manual-smoke.v1",
          "packagedAppLaunchSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "packaged app launched from Finder or package smoke gate without crash"
          },
          "liveDesktopClickActions": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "Operator confirmed live click/gaze interactions against the selected wallpaper manifest-declared pointerMove and pointerDown actions. Protocol: \(currentLiveClickProtocolJSON)",
            "operatorNote": "\(liveClickObservationNote)",
            "protocolText": "\(currentLiveClickProtocolJSON)"
          },
          "physicalDisplayHotplugSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "selectedOnly primary-only, selectedPolicy secondary-passive, allFull all-displays, reconnect restored wallpaper windows on target displays. Protocol: \(currentPhysicalDisplayProtocolJSON)",
            "operatorNote": "self-test observed reconnect event restored external secondary target displays; Displays have separate Spaces enabled",
            "protocolText": "\(currentPhysicalDisplayProtocolJSON)"
          },
          "blackFrameFlickerSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "packaged app start, mode switch, display rebuild produced no black frame, no visible flicker loop, and no crash",
            "protocolText": "old-black-frame-flicker-protocol"
          }
        }
        """
        try staleBlackFrameFlickerEvidence.write(
            to: staleBlackFrameFlickerEvidenceURL,
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? FileManager.default.removeItem(at: staleBlackFrameFlickerEvidenceURL)
        }
        let completionAuditWithStaleBlackFrameEvidence = try RuntimeCompletionAudit.make(
            projectRoot: runtime.config.projectRoot,
            strictCompositeQuality: true,
            includeInvalid: true,
            bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")],
            manualEvidenceURL: staleBlackFrameFlickerEvidenceURL
        )
        check(
            completionAuditWithStaleBlackFrameEvidence.contains("overall: automated-pass/manual-evidence-open")
                && completionAuditWithStaleBlackFrameEvidence.contains("manual\tmanual\tblack-frame-flicker-smoke")
                && completionAuditWithStaleBlackFrameEvidence.contains("manual evidence stale:"),
            "completion audit must reopen black-frame/flicker evidence when the recorded display-rebuild protocol no longer matches the current contract"
        )
        let packageOnlySmokeEvidenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEnginePackageOnlySmoke-\(UUID().uuidString).json")
        let packageOnlySmokeEvidence = """
        {
          "schemaVersion": "mac-wallpaper-manual-smoke.v1",
          "packagedAppLaunchSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "package smoke gate launched dist/MacWallpaperEngine.app without crash for 2s"
          },
          "liveDesktopClickActions": {
            "passed": false,
            "recordedAt": "REPLACE_WITH_ISO8601_LOCAL_TIME",
            "evidence": "Do not grant Accessibility; enable click actions; run --interaction-plan for the selected wallpaper bundle; verify the manifest-declared pointerMove and pointerDown click/gaze actions, plus application-window gating."
          },
          "physicalDisplayHotplugSmoke": {
            "passed": false,
            "recordedAt": "REPLACE_WITH_ISO8601_LOCAL_TIME",
            "evidence": "Verify selectedOnly=primary-only, selectedPolicy=primary-full-secondary-passive, allFull=all-displays on multiple physical displays; reconnect or wake displays; record whether macOS Displays have separate Spaces is enabled or disabled; confirm wallpaper windows restore on target displays."
          },
          "blackFrameFlickerSmoke": {
            "passed": false,
            "recordedAt": "REPLACE_WITH_ISO8601_LOCAL_TIME",
            "evidence": "Start packaged app; switch selectedOnly/selectedPolicy/allFull; trigger display rebuild or wake; confirm no black frame, no visible flicker loop, and no crash."
          }
        }
        """
        try packageOnlySmokeEvidence.write(to: packageOnlySmokeEvidenceURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: packageOnlySmokeEvidenceURL)
        }
        let completionAuditWithPackageEvidence = try RuntimeCompletionAudit.make(
            projectRoot: runtime.config.projectRoot,
            strictCompositeQuality: true,
            includeInvalid: true,
            bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")],
            manualEvidenceURL: packageOnlySmokeEvidenceURL
        )
        check(
            completionAuditWithPackageEvidence.contains("overall: automated-pass/manual-evidence-open")
                && completionAuditWithPackageEvidence.contains("automated\tpass\twallpaper-bundle-contract")
                && completionAuditWithPackageEvidence.contains("manual\tpass\tpackaged-app-launch-smoke")
                && completionAuditWithPackageEvidence.contains("manual\tmanual\tlive-desktop-click-actions")
                && completionAuditWithPackageEvidence.contains("manual\tmanual\tphysical-display-hotplug-smoke")
                && completionAuditWithPackageEvidence.contains("manual\tmanual\tblack-frame-flicker-smoke"),
            "completion audit must allow package-script launch evidence without falsely closing live click or physical hot-plug evidence"
        )
        var rejectedLiveClickWithoutNote = false
        do {
            _ = try RuntimeCompletionAudit.recordManualSmokeEvidence(
                to: packageOnlySmokeEvidenceURL,
                packagedLaunchPassed: false,
                liveClickActionsPassed: true,
                physicalDisplayHotplugPassed: false,
                blackFrameFlickerPassed: false
            )
        } catch {
            rejectedLiveClickWithoutNote = String(describing: error)
                .contains("--live-click-actions-note")
        }
        check(
            rejectedLiveClickWithoutNote,
            "manual smoke recorder must reject live click/gaze pass without a concrete operator note"
        )
        var rejectedPhysicalHotplugWithoutNote = false
        do {
            _ = try RuntimeCompletionAudit.recordManualSmokeEvidence(
                to: packageOnlySmokeEvidenceURL,
                packagedLaunchPassed: false,
                liveClickActionsPassed: false,
                physicalDisplayHotplugPassed: true,
                blackFrameFlickerPassed: false
            )
        } catch {
            rejectedPhysicalHotplugWithoutNote = String(describing: error)
                .contains("--physical-display-hotplug-note")
        }
        check(
            rejectedPhysicalHotplugWithoutNote,
            "manual smoke recorder must reject physical display hotplug pass without a concrete operator note"
        )
        var rejectedPhysicalHotplugWithoutEvent = false
        do {
            _ = try RuntimeCompletionAudit.recordManualSmokeEvidence(
                to: packageOnlySmokeEvidenceURL,
                packagedLaunchPassed: false,
                liveClickActionsPassed: false,
                physicalDisplayHotplugPassed: true,
                blackFrameFlickerPassed: false,
                physicalDisplayHotplugNote: "self-test wake restored selectedOnly selectedPolicy allFull display windows"
            )
        } catch {
            rejectedPhysicalHotplugWithoutEvent = String(describing: error)
                .contains("--physical-display-hotplug-event")
        }
        check(
            rejectedPhysicalHotplugWithoutEvent,
            "manual smoke recorder must reject physical display hotplug pass without an explicit wake/reconnect event"
        )
        var rejectedPhysicalHotplugEventNoteMismatch = false
        do {
            _ = try RuntimeCompletionAudit.recordManualSmokeEvidence(
                to: packageOnlySmokeEvidenceURL,
                packagedLaunchPassed: false,
                liveClickActionsPassed: false,
                physicalDisplayHotplugPassed: true,
                blackFrameFlickerPassed: false,
                physicalDisplayHotplugEvent: "wake",
                physicalDisplayHotplugNote: "self-test reconnect restored selectedOnly selectedPolicy allFull display windows"
            )
        } catch {
            rejectedPhysicalHotplugEventNoteMismatch = String(describing: error)
                .contains("must mention the selected wake event")
        }
        check(
            rejectedPhysicalHotplugEventNoteMismatch,
            "manual smoke recorder must reject physical display hotplug notes that do not mention the selected lifecycle event"
        )
        var rejectedPhysicalHotplugUnderspecifiedNote = false
        do {
            _ = try RuntimeCompletionAudit.recordManualSmokeEvidence(
                to: packageOnlySmokeEvidenceURL,
                packagedLaunchPassed: false,
                liveClickActionsPassed: false,
                physicalDisplayHotplugPassed: true,
                blackFrameFlickerPassed: false,
                physicalDisplayHotplugEvent: "wake",
                physicalDisplayHotplugNote: "self-test wake restored display windows"
            )
        } catch {
            rejectedPhysicalHotplugUnderspecifiedNote = String(describing: error)
                .contains("checked display mode token")
        }
        check(
            rejectedPhysicalHotplugUnderspecifiedNote,
            "manual smoke recorder must reject physical display hotplug notes that omit selectedOnly/selectedPolicy/allFull observations"
        )
        var rejectedPhysicalHotplugSingleDisplayNote = false
        do {
            _ = try RuntimeCompletionAudit.recordManualSmokeEvidence(
                to: packageOnlySmokeEvidenceURL,
                packagedLaunchPassed: false,
                liveClickActionsPassed: false,
                physicalDisplayHotplugPassed: true,
                blackFrameFlickerPassed: false,
                physicalDisplayHotplugEvent: "wake",
                physicalDisplayHotplugNote: "self-test wake restored selectedOnly selectedPolicy allFull on built-in display windows"
            )
        } catch {
            rejectedPhysicalHotplugSingleDisplayNote = String(describing: error)
                .contains("multiple physical displays")
        }
        check(
            rejectedPhysicalHotplugSingleDisplayNote,
            "manual smoke recorder must reject physical display hotplug notes that do not mention multiple physical displays"
        )
        var rejectedPhysicalHotplugWithoutSpacesSetting = false
        do {
            _ = try RuntimeCompletionAudit.recordManualSmokeEvidence(
                to: packageOnlySmokeEvidenceURL,
                packagedLaunchPassed: false,
                liveClickActionsPassed: false,
                physicalDisplayHotplugPassed: true,
                blackFrameFlickerPassed: false,
                physicalDisplayHotplugEvent: "wake",
                physicalDisplayHotplugNote: "self-test wake restored selectedOnly selectedPolicy allFull on external secondary display windows"
            )
        } catch {
            rejectedPhysicalHotplugWithoutSpacesSetting = String(describing: error)
                .contains("separate Spaces")
        }
        check(
            rejectedPhysicalHotplugWithoutSpacesSetting,
            "manual smoke recorder must reject physical display hotplug notes that omit the Displays have separate Spaces setting"
        )
        let koreanPhysicalHotplugEvidenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineKoreanPhysicalSmoke-\(UUID().uuidString).json")
        let koreanPhysicalHotplugRecordReport = try RuntimeCompletionAudit.recordManualSmokeEvidence(
            to: koreanPhysicalHotplugEvidenceURL,
            packagedLaunchPassed: false,
            liveClickActionsPassed: false,
            physicalDisplayHotplugPassed: true,
            blackFrameFlickerPassed: false,
            physicalDisplayHotplugEvent: "reconnect",
            physicalDisplayHotplugNote: "재연결 후 AOC LG 외부 보조 디스플레이에서 selectedOnly selectedPolicy allFull wallpaper windows 복원 확인; Displays have separate Spaces enabled"
        )
        defer {
            try? FileManager.default.removeItem(at: koreanPhysicalHotplugEvidenceURL)
        }
        let completionAuditWithKoreanPhysicalHotplugEvidence = try RuntimeCompletionAudit.make(
            projectRoot: runtime.config.projectRoot,
            strictCompositeQuality: true,
            includeInvalid: true,
            bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")],
            manualEvidenceURL: koreanPhysicalHotplugEvidenceURL
        )
        check(
            koreanPhysicalHotplugRecordReport.contains("physical-display-hotplug-smoke")
                && completionAuditWithKoreanPhysicalHotplugEvidence.contains("manual\tpass\tphysical-display-hotplug-smoke")
                && completionAuditWithKoreanPhysicalHotplugEvidence.contains("note=재연결 후 AOC LG 외부 보조 디스플레이에서 selectedOnly selectedPolicy allFull wallpaper windows 복원 확인; Displays have separate Spaces enabled"),
            "manual smoke recorder must accept Korean physical display reconnect/restored wording while preserving selectedOnly/selectedPolicy/allFull evidence tokens"
        )
        let genericPhysicalHotplugEvidenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineGenericPhysicalSmoke-\(UUID().uuidString).json")
        let genericPhysicalHotplugEvidence = """
        {
          "schemaVersion": "mac-wallpaper-manual-smoke.v1",
          "physicalDisplayHotplugSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "selectedOnly primary-only, selectedPolicy secondary-passive, allFull all-displays, reconnect restored wallpaper windows on target displays",
            "operatorNote": "Recorded by --record-manual-smoke-evidence after operator observation."
          }
        }
        """
        try genericPhysicalHotplugEvidence.write(
            to: genericPhysicalHotplugEvidenceURL,
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? FileManager.default.removeItem(at: genericPhysicalHotplugEvidenceURL)
        }
        var rejectedGenericPhysicalHotplugNote = false
        do {
            _ = try RuntimeCompletionAudit.make(
                projectRoot: runtime.config.projectRoot,
                strictCompositeQuality: true,
                includeInvalid: true,
                bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")],
                manualEvidenceURL: genericPhysicalHotplugEvidenceURL
            )
        } catch {
            rejectedGenericPhysicalHotplugNote = String(describing: error)
                .contains("concrete operatorNote")
        }
        check(
            rejectedGenericPhysicalHotplugNote,
            "completion audit must reject generic physical display hotplug notes from older recorder output"
        )
        let partialPhysicalHotplugEvidenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEnginePartialPhysicalSmoke-\(UUID().uuidString).json")
        let partialPhysicalHotplugEvidence = """
        {
          "schemaVersion": "mac-wallpaper-manual-smoke.v1",
          "physicalDisplayHotplugSmoke": {
            "passed": true,
            "recordedAt": "self-test",
            "evidence": "Operator observed selectedOnly, selectedPolicy, and allFull, but reconnect restoration was not explicitly observed yet.",
            "operatorNote": "Partial physical-display evidence only."
          }
        }
        """
        try partialPhysicalHotplugEvidence.write(
            to: partialPhysicalHotplugEvidenceURL,
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? FileManager.default.removeItem(at: partialPhysicalHotplugEvidenceURL)
        }
        var rejectedPartialPhysicalHotplugEvidence = false
        do {
            _ = try RuntimeCompletionAudit.make(
                projectRoot: runtime.config.projectRoot,
                strictCompositeQuality: true,
                includeInvalid: true,
                bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")],
                manualEvidenceURL: partialPhysicalHotplugEvidenceURL
            )
        } catch {
            rejectedPartialPhysicalHotplugEvidence = String(describing: error)
                .contains("incomplete-evidence marker")
        }
        check(
            rejectedPartialPhysicalHotplugEvidence,
            "completion audit must reject physical display hotplug pass evidence that still says partial or not observed"
        )
        let manualRecordReport = try RuntimeCompletionAudit.recordManualSmokeEvidence(
            to: packageOnlySmokeEvidenceURL,
            packagedLaunchPassed: false,
            liveClickActionsPassed: true,
            physicalDisplayHotplugPassed: true,
            blackFrameFlickerPassed: true,
            liveClickActionsNote: liveClickObservationNote,
            physicalDisplayHotplugEvent: "reconnect",
            physicalDisplayHotplugNote: "self-test reconnect restored selectedOnly selectedPolicy allFull on external secondary display windows; Displays have separate Spaces enabled"
        )
        let completionAuditWithRecordedManualEvidence = try RuntimeCompletionAudit.make(
            projectRoot: runtime.config.projectRoot,
            strictCompositeQuality: true,
            includeInvalid: true,
            bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")],
            manualEvidenceURL: packageOnlySmokeEvidenceURL
        )
        check(
            manualRecordReport.contains("manual smoke evidence record OK")
                && manualRecordReport.contains("live-desktop-click-actions")
                && manualRecordReport.contains("physical-display-hotplug-smoke")
                && manualRecordReport.contains("black-frame-flicker-smoke")
                && completionAuditWithRecordedManualEvidence.contains("overall: complete-evidence-pass")
                && completionAuditWithRecordedManualEvidence.contains("automated\tpass\twallpaper-bundle-contract")
                && completionAuditWithRecordedManualEvidence.contains("manual\tpass\tpackaged-app-launch-smoke")
                && completionAuditWithRecordedManualEvidence.contains("manual\tpass\tlive-desktop-click-actions")
                && completionAuditWithRecordedManualEvidence.contains("manual\tpass\tphysical-display-hotplug-smoke")
                && completionAuditWithRecordedManualEvidence.contains("manual\tpass\tblack-frame-flicker-smoke")
                && completionAuditWithRecordedManualEvidence.contains("note=self-test reconnect restored selectedOnly selectedPolicy allFull on external secondary display windows; Displays have separate Spaces enabled"),
            "manual smoke recorder must merge operator-confirmed live click and physical display evidence without losing package launch evidence"
        )
        let manualSmokeTemplateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineManualSmokeTemplate-\(UUID().uuidString).json")
        let templateWriteReport = try RuntimeCompletionAudit.writeManualSmokeEvidenceTemplate(to: manualSmokeTemplateURL)
        defer {
            try? FileManager.default.removeItem(at: manualSmokeTemplateURL)
        }
        let manualSmokeTemplate = try String(contentsOf: manualSmokeTemplateURL, encoding: .utf8)
        check(
            templateWriteReport.contains("manual smoke evidence template OK")
                && manualSmokeTemplate.contains("\"schemaVersion\" : \"mac-wallpaper-manual-smoke.v1\"")
                && manualSmokeTemplate.contains("\"packagedAppLaunchSmoke\"")
                && manualSmokeTemplate.contains("\"liveDesktopClickActions\"")
                && manualSmokeTemplate.contains("\"physicalDisplayHotplugSmoke\"")
                && manualSmokeTemplate.contains("\"blackFrameFlickerSmoke\"")
                && manualSmokeTemplate.contains(currentLiveClickProtocolEncodedJSON)
                && manualSmokeTemplate.contains(currentPhysicalDisplayProtocolEncodedJSON)
                && manualSmokeTemplate.contains(currentBlackFrameFlickerProtocolEncodedJSON)
                && manualSmokeTemplate.contains("REPLACE_WITH_CURRENT_") == false
                && manualSmokeTemplate.contains("\"passed\" : false"),
            "completion audit must provide a fill-in manual smoke evidence template with current protocolText before requiring live evidence ingestion"
        )
        let completionAuditWithUnfilledTemplate = try RuntimeCompletionAudit.make(
            projectRoot: runtime.config.projectRoot,
            strictCompositeQuality: true,
            includeInvalid: true,
            bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")],
            manualEvidenceURL: manualSmokeTemplateURL
        )
        check(
            completionAuditWithUnfilledTemplate.contains("overall: automated-pass/manual-evidence-open")
                && completionAuditWithUnfilledTemplate.contains("automated\tpass\twallpaper-bundle-contract")
                && completionAuditWithUnfilledTemplate.contains("manual\tmanual\tpackaged-app-launch-smoke")
                && completionAuditWithUnfilledTemplate.contains("manual evidence failed:"),
            "unfilled manual smoke templates must not close audit evidence or be overridden by fallback pass conditions"
        )
        let runtimeSmokeEvidenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineRuntimeSmoke-\(UUID().uuidString).json")
        let runtimeSmokeReport = try RuntimeSmokeEvidenceWriter.write(
            runtime: runtime,
            destination: runtimeSmokeEvidenceURL
        )
        defer {
            try? FileManager.default.removeItem(at: runtimeSmokeEvidenceURL)
        }
        let runtimeSmokeEvidence = try String(contentsOf: runtimeSmokeEvidenceURL, encoding: .utf8)
        check(
            runtimeSmokeReport.contains("runtime smoke evidence OK")
                && runtimeSmokeEvidence.contains("\"schemaVersion\" : \"mac-wallpaper-manual-smoke.v1\"")
                && runtimeSmokeEvidence.contains("\"liveDesktopClickActions\"")
                && runtimeSmokeEvidence.contains("\"blackFrameFlickerSmoke\"")
                && runtimeSmokeEvidence.contains(currentLiveClickProtocolEncodedJSON)
                && runtimeSmokeEvidence.contains(currentPhysicalDisplayProtocolEncodedJSON)
                && runtimeSmokeEvidence.contains(currentBlackFrameFlickerProtocolEncodedJSON)
                && runtimeSmokeEvidence.contains("expected no black frame")
                && runtimeSmokeEvidence.contains("runtime telemetry captured")
                && runtimeSmokeEvidence.contains("live telemetry proof:")
                && runtimeSmokeEvidence.contains("expected=")
                && runtimeSmokeEvidence.contains("manifestChecklist=")
                && runtimeSmokeEvidence.contains("runtime physical display telemetry captured")
                && runtimeSmokeEvidence.contains("physicalDisplayModeMatrix=")
                && runtimeSmokeEvidence.contains("selectedOnly={render plan OK")
                && runtimeSmokeEvidence.contains("selectedPolicy={render plan OK")
                && runtimeSmokeEvidence.contains("allFull={render plan OK")
                && runtimeSmokeEvidence.contains("flicker telemetry captured"),
            "runtime smoke evidence writer must generate a completion-audit-compatible evidence JSON with telemetry context"
        )
        let completionAuditWithRuntimeSmoke = try RuntimeCompletionAudit.make(
            projectRoot: runtime.config.projectRoot,
            strictCompositeQuality: true,
            includeInvalid: true,
            bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")],
            manualEvidenceURL: runtimeSmokeEvidenceURL
        )
        check(
            completionAuditWithRuntimeSmoke.contains("overall: automated-pass/manual-evidence-open")
                && completionAuditWithRuntimeSmoke.contains("automated\tpass\twallpaper-bundle-contract")
                && completionAuditWithRuntimeSmoke.contains("manual\tmanual\tlive-desktop-click-actions")
                && completionAuditWithRuntimeSmoke.contains("manual\tmanual\tphysical-display-hotplug-smoke")
                && completionAuditWithRuntimeSmoke.contains("manual\tmanual\tblack-frame-flicker-smoke")
                && completionAuditWithRuntimeSmoke.contains("runtime telemetry captured")
                && completionAuditWithRuntimeSmoke.contains("runtime physical display telemetry captured")
                && completionAuditWithRuntimeSmoke.contains("runtime black-frame/flicker telemetry captured"),
            "runtime smoke evidence must enrich manual-open rows without falsely closing live click or physical hot-plug evidence"
        )
        let invalidManualSmokeEvidenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineInvalidManualSmoke-\(UUID().uuidString).json")
        let invalidManualSmokeEvidence = """
        {
          "schemaVersion": "mac-wallpaper-manual-smoke.v1",
          "packagedAppLaunchSmoke": {
            "passed": true,
            "recordedAt": "REPLACE_WITH_ISO8601_LOCAL_TIME",
            "evidence": "Launch dist/MacWallpaperEngine.app from Finder or package smoke gate; record whether the app stays alive without crash."
          }
        }
        """
        try invalidManualSmokeEvidence.write(to: invalidManualSmokeEvidenceURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: invalidManualSmokeEvidenceURL)
        }
        do {
            _ = try RuntimeCompletionAudit.make(
                projectRoot: runtime.config.projectRoot,
                strictCompositeQuality: true,
                includeInvalid: true,
                bundleDirectories: [runtime.config.projectRoot.appendingPathComponent("wallpapers")],
                manualEvidenceURL: invalidManualSmokeEvidenceURL
            )
            check(false, "passed=true manual smoke evidence with template placeholders must be rejected")
        } catch {
            check(
                error.localizedDescription.contains("template placeholders"),
                "passed=true manual smoke evidence rejection must explain remaining template placeholders"
            )
        }
        try checkBundleDiagnostics(from: runtime, failures: &failures, checks: &checks)
        try checkBundleInstallerRoundTrip(from: runtime, failures: &failures, checks: &checks)
        try checkVideoOnlyBundle(from: runtime, failures: &failures, checks: &checks)
        try checkStaticImageBundle(from: runtime, failures: &failures, checks: &checks)
        try checkNonSpineInteractiveBundleRejected(from: runtime, failures: &failures, checks: &checks)
        try checkLinkedMeshSpineCompatibilityBundle(from: runtime, failures: &failures, checks: &checks)
        try checkClippingSpineGeometryBundle(from: runtime, failures: &failures, checks: &checks)
        try checkPathConstraintSpineGeometryBundle(from: runtime, failures: &failures, checks: &checks)
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
            hardMemoryGovernor.snapshot.pauseForResourceBudget == false
                && hardMemoryFps <= budgetPlan.fallbackFps
                && hardMemoryGovernor.snapshot.videoOnlyFallback == false,
            "RSS hard limit must keep drawing at fallback FPS instead of freezing the wallpaper",
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
        telemetry.recordDisplayLifecycle(
            event: "display-rebuild",
            status: "committed",
            detail: "windows=3 retired=2"
        )
        check(
            telemetry.summary().contains("display lifecycle display-rebuild committed: windows=3 retired=2"),
            "runtime telemetry summary must expose display lifecycle rebuild results for control-panel diagnostics",
            failures: &failures,
            checks: &checks
        )
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
                && interactionTelemetrySummary.contains("delivered:1")
                && interactionTelemetrySummary.contains("observed:act"),
            "runtime telemetry summary must expose live desktop interaction monitor status and active command",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.inputSources(
                usesPassiveEventMonitoring: true,
                eventTapStarted: true,
                accessibilityTrusted: true
            ) == DesktopMouseInteractionMonitor.InputSources(
                useEventTap: true,
                useLocalMonitor: false,
                useGlobalMoveMonitor: false,
                useGlobalClickMonitors: false
            ),
            "desktop mouse monitor must avoid duplicate global monitors when passive event tap is active",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.inputSources(
                usesPassiveEventMonitoring: true,
                eventTapStarted: false,
                accessibilityTrusted: true
            ) == DesktopMouseInteractionMonitor.InputSources(
                useEventTap: false,
                useLocalMonitor: false,
                useGlobalMoveMonitor: true,
                useGlobalClickMonitors: true
            ),
            "desktop mouse monitor may fall back to permissionless global monitors",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.inputSources(
                usesPassiveEventMonitoring: true,
                eventTapStarted: false,
                accessibilityTrusted: false
            ) == DesktopMouseInteractionMonitor.InputSources(
                useEventTap: false,
                useLocalMonitor: false,
                useGlobalMoveMonitor: true,
                useGlobalClickMonitors: true
            ),
            "desktop mouse monitor may attach permissionless global move and click monitoring without Accessibility trust",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.shouldRestartForAccessibilityTrustChange(
                isActive: true,
                previousAccessibilityTrusted: false,
                currentAccessibilityTrusted: true
            ),
            "desktop mouse monitor must restart input sources when Accessibility trust is granted after pointer-only startup",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.shouldRestartForAccessibilityTrustChange(
                isActive: true,
                previousAccessibilityTrusted: true,
                currentAccessibilityTrusted: false
            ),
            "desktop mouse monitor must restart input sources when Accessibility trust is revoked",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.shouldRestartForAccessibilityTrustChange(
                isActive: false,
                previousAccessibilityTrusted: false,
                currentAccessibilityTrusted: true
            ) == false,
            "inactive desktop mouse monitor must start normally instead of restarting on first permission refresh",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.inputSources(
                usesPassiveEventMonitoring: false,
                eventTapStarted: false,
                accessibilityTrusted: false
            ) == DesktopMouseInteractionMonitor.InputSources(
                useEventTap: false,
                useLocalMonitor: true,
                useGlobalMoveMonitor: false,
                useGlobalClickMonitors: false
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
        check(
            RuntimeLifecyclePolicy.effectiveRendererVisibility(
                windowIsVisible: false,
                occlusionVisible: false,
                hasPresentedVisibleWindow: false
            ),
            "pre-show wallpaper windows must stay renderable long enough to warm up before first orderFront",
            failures: &failures,
            checks: &checks
        )
        check(
            RuntimeLifecyclePolicy.effectiveRendererVisibility(
                windowIsVisible: false,
                occlusionVisible: false,
                hasPresentedVisibleWindow: true
            ) == false,
            "previously visible wallpaper windows may pause when later hidden or fully occluded",
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
            pointerSampleFps: nil,
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
            pointerSampleFps: nil,
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
            pointerSampleFps: nil,
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
            blockedPermissionStatus.text.contains("READY")
                && blockedPermissionStatus.text.contains("desktop-gated")
                && blockedPermissionStatus.text.count < 90,
            "control panel interaction status must expose desktop-gated click/touch mode without showing internal permission wording",
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
            secondaryPermissionStatus.text.contains("PASSIVE"),
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
            ),
            "desktop-empty interaction with desktop item blocking must keep hover tracking active without Accessibility trust",
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
            pointerSampleFps: nil,
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
            readyPermissionStatus.text.contains("READY"),
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
            deliveredControlPanelText.contains("READY")
                && deliveredControlPanelText.contains("tap")
                && deliveredControlPanelText.contains("cmd act")
                && deliveredControlPanelText.count < 80,
            "control panel interaction status must surface compact live monitor delivery state",
            failures: &failures,
            checks: &checks
        )
        let waitingControlPanelText = RuntimeLifecyclePolicy.interactionControlPanelText(
            permissionStatus: readyPermissionStatus,
            isHostRunning: true,
            monitorSnapshot: nil
        )
        check(
            waitingControlPanelText.contains("starting"),
            "control panel interaction status must distinguish ready policy from missing monitor telemetry",
            failures: &failures,
            checks: &checks
        )
        let degradedControlPanelText = RuntimeLifecyclePolicy.interactionControlPanelText(
            permissionStatus: blockedPermissionStatus,
            isHostRunning: true,
            monitorSnapshot: deliveredInteractionSnapshot
        )
        check(
            degradedControlPanelText.contains("READY")
                && degradedControlPanelText.contains("tap")
                && degradedControlPanelText.contains("cmd act")
                && degradedControlPanelText.count < 90,
            "no-permission interaction status must remain visible while surfacing live hover monitor telemetry",
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
        let hoverMoveMask = PointerMoveInputMask.all
        let dragOnlyMoveMask = PointerMoveInputMask(acceptsUnbuttoned: false, buttons: [.left])
        check(
            DesktopMouseInteractionMonitor.globalMoveEventMask(pointerMoveInputMask: hoverMoveMask).contains(.mouseMoved)
                && DesktopMouseInteractionMonitor.globalMoveEventMask(pointerMoveInputMask: hoverMoveMask).contains(.leftMouseDragged)
                && DesktopMouseInteractionMonitor.globalMoveEventMask(pointerMoveInputMask: dragOnlyMoveMask).contains(.mouseMoved) == false
                && DesktopMouseInteractionMonitor.globalMoveEventMask(pointerMoveInputMask: dragOnlyMoveMask).contains(.leftMouseDragged),
            "desktop interaction monitor must derive hover vs drag move sources from manifest pointerMove buttons",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopMouseInteractionMonitor.inputSources(
                usesPassiveEventMonitoring: true,
                eventTapStarted: false,
                accessibilityTrusted: true,
                pointerMoveInputMask: .none
            ).useGlobalMoveMonitor == false
                && DesktopMouseInteractionMonitor.inputSources(
                    usesPassiveEventMonitoring: true,
                    eventTapStarted: false,
                    accessibilityTrusted: true,
                    pointerMoveInputMask: dragOnlyMoveMask
                ).useGlobalMoveMonitor,
            "desktop interaction monitor must avoid unneeded global move monitors when a bundle declares no pointerMove",
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
            "desktop interaction gate must allow empty desktop",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopInteractionGate.eligibilityDecision(
                policy: interactivePolicy,
                accessibilityTrusted: false,
                coveredByApplicationWindow: false,
                likelyDesktopItem: false
            ) == .eligible,
            "desktop interaction gate must allow no-permission empty desktop clicks",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopInteractionGate.pointerMoveEligibilityDecision(
                policy: interactivePolicy,
                accessibilityTrusted: false,
                coveredByApplicationWindow: false,
                likelyDesktopItem: false
            ) == .eligible,
            "desktop pointer move gate may keep hover tracking active without Accessibility trust",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopInteractionGate.pointerMoveEligibilityDecision(
                policy: interactivePolicy,
                accessibilityTrusted: false,
                coveredByApplicationWindow: true,
                likelyDesktopItem: false
            ) == .blockedApplicationWindow,
            "desktop pointer move gate must still block hover tracking over application windows without Accessibility trust",
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
                windowNumber: 1001,
                windowName: "Mac Wallpaper Engine Diagnostic",
                currentPID: currentPID,
                ignoredWindowNumbers: []
            ),
            "desktop interaction gate must ignore the wallpaper host window itself when scanning covering app windows",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopInteractionGate.shouldIgnoreApplicationWindowForInteraction(
                ownerPID: currentPID,
                windowNumber: 1002,
                windowName: "Mac Wallpaper Engine",
                currentPID: currentPID,
                ignoredWindowNumbers: [1001]
            ) == false,
            "desktop interaction gate must treat the control panel as a covering app window, not as empty desktop",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopInteractionGate.shouldIgnoreApplicationWindowForInteraction(
                ownerPID: currentPID + 1,
                windowNumber: 1003,
                windowName: "Other App",
                currentPID: currentPID,
                ignoredWindowNumbers: [1001]
            ) == false,
            "desktop interaction gate must not ignore other app windows during empty-desktop checks",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopInteractionGate.shouldIgnoreApplicationWindowForInteraction(
                ownerPID: currentPID,
                windowNumber: 4242,
                windowName: "",
                currentPID: currentPID,
                ignoredWindowNumbers: [4242]
            ),
            "desktop interaction gate must ignore the active wallpaper window by window number even when the window server omits its name",
            failures: &failures,
            checks: &checks
        )
        check(
            DesktopInteractionGate.shouldIgnoreApplicationWindowForInteraction(
                ownerPID: currentPID,
                windowNumber: 4243,
                windowName: "",
                currentPID: currentPID,
                ignoredWindowNumbers: [4242]
            ) == false,
            "desktop interaction gate must not ignore same-process windows that are not the active wallpaper window",
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
            audioEnabled: true,
            fitMode: .fill,
            foregroundMode: .nativeSpine,
            clearDuration: true,
            launchControlPanel: true,
            launchWallpaper: true,
            launchAtLogin: true
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
        check(loaded.audioEnabled == false, "runtime settings must not persist audio opt-in; player is visual-only", failures: &failures, checks: &checks)
        check(loaded.fitMode == .fill, "runtime settings must persist fit mode", failures: &failures, checks: &checks)
        check(
            loaded.foregroundMode == .nativeSpine,
            "runtime settings must persist foreground mode",
            failures: &failures,
            checks: &checks
        )
        check(
            loaded.launchAtLogin == false,
            "runtime settings must not persist automatic launch; player is manual-start only",
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
        check(parsed.audioEnabled == false, "EngineConfig must ignore persisted audio opt-in; player is visual-only", failures: &failures, checks: &checks)
        check(parsed.fitMode == .fill, "EngineConfig must restore persisted fit mode", failures: &failures, checks: &checks)
        check(
            parsed.foregroundMode == .nativeSpine,
            "EngineConfig must restore persisted foreground mode",
            failures: &failures,
            checks: &checks
        )
        check(
            parsed.launchAtLogin == false,
            "EngineConfig must ignore persisted automatic launch; player is manual-start only",
            failures: &failures,
            checks: &checks
        )

        let compositeConfig = runtime.config.replacing(foregroundMode: .compositeVideo, clearDuration: true)
        try RuntimeSettingsStore.save(config: compositeConfig, to: settingsURL)
        let loadedComposite = try RuntimeSettingsStore.load(from: settingsURL)
        let parsedCompositePersistence = try EngineConfig.parse([])
        check(
            loadedComposite.foregroundMode == .automatic
                && parsedCompositePersistence.foregroundMode == .automatic,
            "persisted composite foreground mode must recover to auto so degraded fallback video cannot become the next launch default",
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
            diagnosticParse.audioEnabled == false,
            "diagnostic validation must keep audio disabled",
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
        check(
            diagnosticParse.launchAtLogin == false,
            "diagnostic validation must ignore persisted launch-at-login setting",
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
        let sourceProvenanceParse = try EngineConfig.parse(["--source-provenance"])
        check(
            sourceProvenanceParse.sourceProvenanceReportOnly,
            "EngineConfig must parse source provenance diagnostics",
            failures: &failures,
            checks: &checks
        )
        check(
            sourceProvenanceParse.foregroundMode == .automatic,
            "source provenance diagnostics must ignore persisted foreground mode",
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
        let spineProfileParse = try EngineConfig.parse(["--spine-profile"])
        check(
            spineProfileParse.spineProfileOnly,
            "EngineConfig must parse native Spine profile diagnostics",
            failures: &failures,
            checks: &checks
        )
        check(
            spineProfileParse.foregroundMode == .automatic,
            "Spine profile diagnostics must ignore persisted foreground mode",
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
        do {
            _ = try EngineConfig.parse(["--audio"])
            failures.append("EngineConfig must reject audio because the player is visual-only")
        } catch {
            checks += 1
        }
        let mutedOverride = try EngineConfig.parse(["--mute"])
        check(
            mutedOverride.audioEnabled == false,
            "EngineConfig must accept explicit mute as the visual-only default",
            failures: &failures,
            checks: &checks
        )
        do {
            _ = try EngineConfig.parse(["--launch-at-login"])
            failures.append("EngineConfig must reject launch-at-login because the player is manual-start only")
        } catch {
            checks += 1
        }
        let launchAtLoginDisabledOverride = try EngineConfig.parse(["--no-launch-at-login"])
        check(
            launchAtLoginDisabledOverride.launchAtLogin == false,
            "EngineConfig must accept explicit no-launch-at-login as manual-start mode",
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
        let invalidControlPanelSummary = WallpaperBundleCatalog.controlPanelLibrarySummary(for: diagnostics)
        check(
            invalidControlPanelSummary.contains("Library: 0 valid / 1 invalid")
                && invalidControlPanelSummary.contains("Invalid bundles: missing_manifest_bundle"),
            "control panel library summary must show counts and invalid reasons",
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
        let validControlPanelSummary = WallpaperBundleCatalog.controlPanelLibrarySummary(for: [
            WallpaperBundleDiagnostic(
                root: activeBundle.root,
                status: .valid,
                bundle: activeBundle,
                errorMessage: nil
            )
        ])
        check(
            validControlPanelSummary == "Library: 1 valid / 0 invalid",
            "control panel library summary must stay visible when every bundle is valid",
            failures: &failures,
            checks: &checks
        )
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
                && (overlappingHitZoneDiagnostic.errorMessage?.contains("hitZones head and body overlap") == true)
                && (overlappingHitZoneDiagnostic.errorMessage?.contains("assign distinct hit-zone priorities") == true),
            "bundle diagnostics must reject ambiguous same-priority overlapping pointerDown hit zones before runtime hit-test order can hide them",
            failures: &failures,
            checks: &checks
        )
        let prioritizedOverlapPlan = InteractionPlan(
            interactions: [
                InteractionConfig(
                    event: .pointerDown,
                    mapping: nil,
                    actions: nil,
                    neutralPoint: nil,
                    deadZone: nil,
                    hitZones: [
                        HitZone(
                            id: "body",
                            rect: [0.20, 0.20, 0.90, 0.90],
                            ellipse: nil,
                            action: "boll",
                            tapAction: nil,
                            rubAction: nil,
                            trigger: .tap,
                            tailSeconds: 0.5,
                            tapTailSeconds: nil,
                            rubTailSeconds: nil,
                            holdStartSeconds: nil,
                            holdCommitSeconds: nil,
                            rubStartSeconds: nil,
                            rubStartDistance: nil,
                            buttons: [.left],
                            priority: 0
                        ),
                        HitZone(
                            id: "head",
                            rect: [0.35, 0.20, 0.65, 0.55],
                            ellipse: nil,
                            action: "act",
                            tapAction: nil,
                            rubAction: nil,
                            trigger: .hold,
                            tailSeconds: 1.15,
                            tapTailSeconds: nil,
                            rubTailSeconds: nil,
                            holdStartSeconds: nil,
                            holdCommitSeconds: nil,
                            rubStartSeconds: nil,
                            rubStartDistance: nil,
                            buttons: [.left],
                            priority: 10
                        )
                    ],
                    defaultAction: nil,
                    buttons: [.left]
                )
            ],
            policy: nil
        )
        check(
            prioritizedOverlapPlan.hitTest(point: CGPoint(x: 0.50, y: 0.35), button: .left)?.zoneID == "head",
            "interaction hit testing must resolve overlapping hit zones by explicit higher priority for generic bundles",
            failures: &failures,
            checks: &checks
        )
        check(
            prioritizedOverlapPlan.hitTest(point: CGPoint(x: 0.50, y: 0.75), button: .left)?.zoneID == "body",
            "interaction hit testing must still resolve the lower-priority zone outside the priority overlap",
            failures: &failures,
            checks: &checks
        )

        let noPointerSmoothingRoot = fixtureParent.appendingPathComponent("no_pointer_smoothing_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: noPointerSmoothingRoot,
            imageSource: sourceImage,
            id: "no_pointer_smoothing_bundle",
            title: "No Pointer Smoothing Bundle",
            interactionPolicyJSON: """
            {
              "mode": "desktop-empty-only",
              "blockApplicationWindows": true,
              "blockDesktopItems": false,
              "pointerSmoothing": 0
            }
            """
        )
        let noPointerSmoothingDiagnostic = WallpaperBundleCatalog.diagnoseBundle(noPointerSmoothingRoot)
        check(
            noPointerSmoothingDiagnostic.status == .valid,
            "bundle diagnostics must accept pointerSmoothing=0 as an explicit immediate-response interaction policy",
            failures: &failures,
            checks: &checks
        )

        let declarativeContractRoot = fixtureParent.appendingPathComponent("declarative_contract_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: declarativeContractRoot,
            imageSource: sourceImage,
            id: "declarative_contract_bundle",
            title: "Declarative Contract Bundle",
            manifestExtraJSON: """
          "effects": [
            {
              "id": "softBlur",
              "type": "blur",
              "budget": {
                "costClass": "medium",
                "maxPasses": 1,
                "maxAnimatedProperties": 1
              },
              "fallback": {
                "policy": "disable",
                "reason": "Disable fixture blur if effect budget is exceeded."
              },
              "properties": {
                "radius": 0
              }
            }
          ],
          "bindings": [
            {
              "id": "thermalBlur",
              "source": "thermal.state",
              "target": "effect.softBlur.radius",
              "adapter": {
                "type": "map-range",
                "inputRange": [0, 1],
                "outputRange": [0, 6],
                "interpolation": "linear"
              }
            }
          ],
"""
        )
        let declarativeContractDiagnostic = WallpaperBundleCatalog.diagnoseBundle(declarativeContractRoot)
        check(
            declarativeContractDiagnostic.status == .valid,
            "bundle diagnostics must accept safe declarative bindings to whitelisted effects",
            failures: &failures,
            checks: &checks
        )
        let declarativeContractManifest = try ManifestLoader.load(
            url: declarativeContractRoot.appendingPathComponent("wallpaper.native.json"),
            bundleRoot: declarativeContractRoot
        )
        let declarativePlan = DeclarativeBindingPlan(manifest: declarativeContractManifest)
        let declarativeSnapshot = DeclarativeBindingEvaluator.evaluate(
            plan: declarativePlan,
            input: DeclarativeBindingEvaluationInput(thermalStateLevel: 0.5)
        )
        check(
            declarativePlan.bindingEntries.map(\.summary) == [
                "thermalBlur:thermal.state->effect.softBlur.radius via map-range runtime-executable"
            ]
                && declarativePlan.effectEntries.map(\.summary) == [
                    "softBlur:blur properties=1 runtime-rendered"
                ],
            "declarative bindings and whitelist effects must be objectized into a runtime plan before renderer-specific execution",
            failures: &failures,
            checks: &checks
        )
        check(
            abs((declarativeSnapshot.number(effectID: "softBlur", property: "radius") ?? -1) - 3.0) < 0.001,
            "map-range declarative bindings must evaluate safe numeric sources into whitelist effect property snapshots",
            failures: &failures,
            checks: &checks
        )

        let timeLoopBindingRoot = fixtureParent.appendingPathComponent("time_loop_binding_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: timeLoopBindingRoot,
            imageSource: sourceImage,
            id: "time_loop_binding_bundle",
            title: "Time Loop Binding Bundle",
            manifestExtraJSON: """
          "effects": [
            {
              "id": "loopPan",
              "type": "scroll",
              "budget": {
                "costClass": "low",
                "maxPasses": 1,
                "maxAnimatedProperties": 1
              },
              "fallback": {
                "policy": "static-value",
                "reason": "Freeze fixture scroll offset if effect budget is exceeded."
              }
            }
          ],
          "bindings": [
            {
              "id": "timePanLoop",
              "source": "system.time",
              "target": "effect.loopPan.offsetX",
              "adapter": {
                "type": "map-range",
                "inputRange": [0, 2],
                "outputRange": [0, 1],
                "interpolation": "linear",
                "loop": true
              }
            }
          ],
"""
        )
        let timeLoopBindingDiagnostic = WallpaperBundleCatalog.diagnoseBundle(timeLoopBindingRoot)
        let timeLoopManifest = try ManifestLoader.load(
            url: timeLoopBindingRoot.appendingPathComponent("wallpaper.native.json"),
            bundleRoot: timeLoopBindingRoot
        )
        let timeLoopPlan = DeclarativeBindingPlan(manifest: timeLoopManifest)
        let timeLoopSnapshot = DeclarativeBindingEvaluator.evaluate(
            plan: timeLoopPlan,
            input: DeclarativeBindingEvaluationInput(systemTimeSeconds: 2.5)
        )
        check(
            timeLoopBindingDiagnostic.status == .valid
                && abs((timeLoopSnapshot.number(effectID: "loopPan", property: "offsetX") ?? -1) - 0.25) < 0.001,
            "bundle diagnostics must accept looped system.time map-range bindings and evaluate them through the manifest-declared adapter",
            failures: &failures,
            checks: &checks
        )

        let springContractRoot = fixtureParent.appendingPathComponent("spring_contract_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: springContractRoot,
            imageSource: sourceImage,
            id: "spring_contract_bundle",
            title: "Spring Contract Bundle",
            manifestExtraJSON: """
          "effects": [
            {
              "id": "softBlur",
              "type": "blur",
              "budget": {
                "costClass": "medium",
                "maxPasses": 1,
                "maxAnimatedProperties": 1
              },
              "fallback": {
                "policy": "disable",
                "reason": "Disable fixture blur if effect budget is exceeded."
              }
            }
          ],
          "bindings": [
            {
              "id": "springPointerBlur",
              "source": "pointer.position",
              "target": "effect.softBlur.radius",
              "adapter": {
                "type": "spring",
                "integrator": "semi-implicit-euler",
                "stiffness": 80,
                "damping": 16,
                "mass": 1,
                "settleEpsilon": 0.001,
                "maxVelocity": 120,
                "fixedStepSeconds": 0.0166666667,
                "factor": [1]
              }
            }
          ],
"""
        )
        let springContractDiagnostic = WallpaperBundleCatalog.diagnoseBundle(springContractRoot)
        let springContractManifest = try ManifestLoader.load(
            url: springContractRoot.appendingPathComponent("wallpaper.native.json"),
            bundleRoot: springContractRoot
        )
        let springContractPlan = DeclarativeBindingPlan(manifest: springContractManifest)
        var springContractState = DeclarativeBindingEvaluationState()
        let springContractStart = DeclarativeBindingEvaluator.evaluate(
            plan: springContractPlan,
            input: DeclarativeBindingEvaluationInput(
                pointerPosition: CGPoint(x: 0.0, y: 0.5),
                systemTimeSeconds: 0
            ),
            state: &springContractState
        )
        let springContractFirst = DeclarativeBindingEvaluator.evaluate(
            plan: springContractPlan,
            input: DeclarativeBindingEvaluationInput(
                pointerPosition: CGPoint(x: 1.0, y: 0.5),
                systemTimeSeconds: 0.1
            ),
            state: &springContractState
        )
        let springContractRendered = DeclarativeEffectState.make(
            plan: springContractPlan,
            snapshot: springContractFirst
        )
        let springContractStartRadius = springContractStart.number(effectID: "softBlur", property: "radius") ?? -1
        let springContractFirstRadius = springContractFirst.number(effectID: "softBlur", property: "radius") ?? -1
        let springContractRuntime = try NativeRuntimeCore(config: runtime.config.replacing(
            wallpaperRoot: springContractRoot,
            manifestURL: springContractRoot.appendingPathComponent("wallpaper.native.json"),
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        check(
            springContractDiagnostic.status == .valid
                && springContractPlan.bindingEntries.first?.runtimeStatus == .runtimeExecutable
                && springContractPlan.hasPointerInputBindings
                && abs(springContractStartRadius) < 0.001
                && springContractFirstRadius > springContractStartRadius
                && springContractFirstRadius <= 1.0
                && abs(Double(springContractRendered.fragmentEffectParams.x) - springContractFirstRadius) < 0.001,
            "pointer-driven effect spring bindings must run through deterministic whitelist-effect state instead of remaining declared-only",
            failures: &failures,
            checks: &checks
        )
        check(
            springContractRuntime.runtimeCapabilitiesSummary().contains(
                "entries=springPointerBlur:pointer.position->effect.softBlur.radius via spring runtime-executable"
            ),
            "runtime capabilities must name runtime-executable pointer effect spring bindings per entry so manifest-driven effects stay visible",
            failures: &failures,
            checks: &checks
        )

        let invalidSpringContractRoot = fixtureParent.appendingPathComponent("invalid_spring_contract_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: invalidSpringContractRoot,
            imageSource: sourceImage,
            id: "invalid_spring_contract_bundle",
            title: "Invalid Spring Contract Bundle",
            manifestExtraJSON: """
          "effects": [
            {
              "id": "softBlur",
              "type": "blur",
              "budget": {
                "costClass": "medium",
                "maxPasses": 1,
                "maxAnimatedProperties": 1
              },
              "fallback": {
                "policy": "disable",
                "reason": "Disable fixture blur if effect budget is exceeded."
              }
            }
          ],
          "bindings": [
            {
              "id": "missingIntegrator",
              "source": "thermal.state",
              "target": "effect.softBlur.radius",
              "adapter": {
                "type": "spring",
                "stiffness": 80,
                "damping": 16,
                "mass": 1,
                "settleEpsilon": 0.001,
                "maxVelocity": 120,
                "fixedStepSeconds": 0.0166666667
              }
            }
          ],
"""
        )
        let invalidSpringContractDiagnostic = WallpaperBundleCatalog.diagnoseBundle(invalidSpringContractRoot)
        check(
            invalidSpringContractDiagnostic.status == .invalid
                && (invalidSpringContractDiagnostic.errorMessage?.contains("Schema required property integrator missing") == true),
            "bundle diagnostics must reject spring bindings that omit explicit spring dynamics during schema preflight before runtime support exists",
            failures: &failures,
            checks: &checks
        )

        let invalidSpringLoopSourceRoot = fixtureParent.appendingPathComponent("invalid_spring_loop_source_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: invalidSpringLoopSourceRoot,
            imageSource: sourceImage,
            id: "invalid_spring_loop_source_bundle",
            title: "Invalid Spring Loop Source Bundle",
            manifestExtraJSON: """
          "effects": [
            {
              "id": "loopBlur",
              "type": "blur",
              "budget": {
                "costClass": "medium",
                "maxPasses": 1,
                "maxAnimatedProperties": 1
              },
              "fallback": {
                "policy": "disable",
                "reason": "Disable fixture blur if effect budget is exceeded."
              }
            }
          ],
          "bindings": [
            {
              "id": "badSpringLoopSource",
              "source": "pointer.down",
              "target": "effect.loopBlur.radius",
              "adapter": {
                "type": "spring",
                "integrator": "semi-implicit-euler",
                "stiffness": 80,
                "damping": 16,
                "mass": 1,
                "settleEpsilon": 0.001,
                "maxVelocity": 120,
                "fixedStepSeconds": 0.0166666667,
                "inputRange": [0, 1],
                "outputRange": [0, 6],
                "loop": true
              }
            }
          ],
"""
        )
        let invalidSpringLoopSourceDiagnostic = WallpaperBundleCatalog.diagnoseBundle(invalidSpringLoopSourceRoot)
        check(
            invalidSpringLoopSourceDiagnostic.status == .invalid
                && (invalidSpringLoopSourceDiagnostic.errorMessage?.contains("spring adapter loop requires source system.time") == true),
            "bundle diagnostics must reject looped spring bindings unless the source is system.time",
            failures: &failures,
            checks: &checks
        )

        let nonSpringContractFieldRoot = fixtureParent.appendingPathComponent("non_spring_contract_field_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: nonSpringContractFieldRoot,
            imageSource: sourceImage,
            id: "non_spring_contract_field_bundle",
            title: "Non Spring Contract Field Bundle",
            manifestExtraJSON: """
          "effects": [
            {
              "id": "softBlur",
              "type": "blur",
              "budget": {
                "costClass": "medium",
                "maxPasses": 1,
                "maxAnimatedProperties": 1
              },
              "fallback": {
                "policy": "disable",
                "reason": "Disable fixture blur if effect budget is exceeded."
              }
            }
          ],
          "bindings": [
            {
              "id": "mapRangeWithSpringField",
              "source": "thermal.state",
              "target": "effect.softBlur.radius",
              "adapter": {
                "type": "map-range",
                "inputRange": [0, 1],
                "outputRange": [0, 6],
                "stiffness": 80
              }
            }
          ],
"""
        )
        let nonSpringContractFieldDiagnostic = WallpaperBundleCatalog.diagnoseBundle(nonSpringContractFieldRoot)
        check(
            nonSpringContractFieldDiagnostic.status == .invalid
                && (nonSpringContractFieldDiagnostic.errorMessage?.contains("Schema not failed") == true),
            "bundle diagnostics must keep spring dynamics fields schema-scoped to spring adapters",
            failures: &failures,
            checks: &checks
        )

        let unsafeBindingRoot = fixtureParent.appendingPathComponent("unsafe_binding_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: unsafeBindingRoot,
            imageSource: sourceImage,
            id: "unsafe_binding_bundle",
            title: "Unsafe Binding Bundle",
            manifestExtraJSON: """
          "bindings": [
            {
              "id": "unsafeExec",
              "source": "pointer.down",
              "target": "exec.command.open",
              "adapter": {
                "type": "trigger-play"
              }
            }
          ],
"""
        )
        let unsafeBindingDiagnostic = WallpaperBundleCatalog.diagnoseBundle(unsafeBindingRoot)
        check(
            unsafeBindingDiagnostic.status == .invalid
                && (unsafeBindingDiagnostic.errorMessage?.contains("Schema pattern mismatch") == true),
            "bundle diagnostics must reject unsafe declarative binding target prefixes before runtime execution",
            failures: &failures,
            checks: &checks
        )

        let missingEffectBindingRoot = fixtureParent.appendingPathComponent("missing_effect_binding_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: missingEffectBindingRoot,
            imageSource: sourceImage,
            id: "missing_effect_binding_bundle",
            title: "Missing Effect Binding Bundle",
            manifestExtraJSON: """
          "bindings": [
            {
              "id": "missingEffect",
              "source": "system.time",
              "target": "effect.missing.opacity",
              "adapter": {
                "type": "map-range",
                "inputRange": [0, 1],
                "outputRange": [0, 1]
              }
            }
          ],
"""
        )
        let missingEffectBindingDiagnostic = WallpaperBundleCatalog.diagnoseBundle(missingEffectBindingRoot)
        check(
            missingEffectBindingDiagnostic.status == .invalid
                && (missingEffectBindingDiagnostic.errorMessage?.contains("targets missing effect id") == true),
            "bundle diagnostics must reject declarative bindings that target undeclared effects",
            failures: &failures,
            checks: &checks
        )

        let unsupportedEffectPropertyRoot = fixtureParent.appendingPathComponent("unsupported_effect_property_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: unsupportedEffectPropertyRoot,
            imageSource: sourceImage,
            id: "unsupported_effect_property_bundle",
            title: "Unsupported Effect Property Bundle",
            manifestExtraJSON: """
          "effects": [
            {
              "id": "softBlur",
              "type": "blur",
              "budget": {
                "costClass": "medium",
                "maxPasses": 1,
                "maxAnimatedProperties": 1
              },
              "fallback": {
                "policy": "disable",
                "reason": "Disable fixture blur if effect budget is exceeded."
              }
            }
          ],
          "bindings": [
            {
              "id": "badBlurProperty",
              "source": "thermal.state",
              "target": "effect.softBlur.opacity",
              "adapter": {
                "type": "map-range",
                "inputRange": [0, 1],
                "outputRange": [0, 1]
              }
            }
          ],
"""
        )
        let unsupportedEffectPropertyDiagnostic = WallpaperBundleCatalog.diagnoseBundle(unsupportedEffectPropertyRoot)
        check(
            unsupportedEffectPropertyDiagnostic.status == .invalid
                && (unsupportedEffectPropertyDiagnostic.errorMessage?.contains("targets unsupported blur effect property: opacity") == true),
            "bundle diagnostics must reject bindings to unsupported properties for a declared whitelist effect type",
            failures: &failures,
            checks: &checks
        )

        let unsupportedStaticEffectPropertyRoot = fixtureParent.appendingPathComponent("unsupported_static_effect_property_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: unsupportedStaticEffectPropertyRoot,
            imageSource: sourceImage,
            id: "unsupported_static_effect_property_bundle",
            title: "Unsupported Static Effect Property Bundle",
            manifestExtraJSON: """
          "effects": [
            {
              "id": "tone",
              "type": "colorMatrix",
              "budget": {
                "costClass": "low",
                "maxPasses": 1,
                "maxAnimatedProperties": 0
              },
              "fallback": {
                "policy": "static-value",
                "reason": "Keep fixture color values if effect budget is exceeded."
              },
              "properties": {
                "radius": 1
              }
            }
          ],
"""
        )
        let unsupportedStaticEffectPropertyDiagnostic = WallpaperBundleCatalog.diagnoseBundle(unsupportedStaticEffectPropertyRoot)
        check(
            unsupportedStaticEffectPropertyDiagnostic.status == .invalid
                && (unsupportedStaticEffectPropertyDiagnostic.errorMessage?.contains("effect tone property radius is not supported by colorMatrix") == true),
            "bundle diagnostics must reject static properties outside each whitelist effect type contract",
            failures: &failures,
            checks: &checks
        )

        let effectBudgetOverflowRoot = fixtureParent.appendingPathComponent("effect_budget_overflow_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: effectBudgetOverflowRoot,
            imageSource: sourceImage,
            id: "effect_budget_overflow_bundle",
            title: "Effect Budget Overflow Bundle",
            manifestExtraJSON: """
          "effects": [
            {
              "id": "tone",
              "type": "colorMatrix",
              "budget": {
                "costClass": "low",
                "maxPasses": 1,
                "maxAnimatedProperties": 1
              },
              "fallback": {
                "policy": "static-value",
                "reason": "Keep fixture color values if too many animated properties are requested."
              },
              "properties": {
                "brightness": 0,
                "opacity": 1
              }
            }
          ],
          "bindings": [
            {
              "id": "brightness",
              "source": "pointer.down",
              "target": "effect.tone.brightness",
              "adapter": {
                "type": "map-range",
                "inputRange": [0, 1],
                "outputRange": [0, 1]
              }
            },
            {
              "id": "opacity",
              "source": "pointer.speed",
              "target": "effect.tone.opacity",
              "adapter": {
                "type": "map-range",
                "inputRange": [0, 1],
                "outputRange": [1, 0.5]
              }
            }
          ],
"""
        )
        let effectBudgetOverflowDiagnostic = WallpaperBundleCatalog.diagnoseBundle(effectBudgetOverflowRoot)
        check(
            effectBudgetOverflowDiagnostic.status == .invalid
                && (effectBudgetOverflowDiagnostic.errorMessage?.contains("effect tone animates 2 properties but budget.maxAnimatedProperties is 1") == true),
            "bundle diagnostics must reject whitelist effects whose animated property count exceeds the declared effect budget",
            failures: &failures,
            checks: &checks
        )

        let unsafeShaderEffectRoot = fixtureParent.appendingPathComponent("unsafe_shader_effect_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: unsafeShaderEffectRoot,
            imageSource: sourceImage,
            id: "unsafe_shader_effect_bundle",
            title: "Unsafe Shader Effect Bundle",
            manifestExtraJSON: """
          "effects": [
            {
              "id": "dynamicShader",
              "type": "shader",
              "budget": {
                "costClass": "high",
                "maxPasses": 1,
                "maxAnimatedProperties": 0
              },
              "fallback": {
                "policy": "disable",
                "reason": "Dynamic shader fixtures must be rejected before fallback is used."
              },
              "properties": {
                "source": "kernel.metal"
              }
            }
          ],
"""
        )
        let unsafeShaderEffectDiagnostic = WallpaperBundleCatalog.diagnoseBundle(unsafeShaderEffectRoot)
        check(
            unsafeShaderEffectDiagnostic.status == .invalid
                && (unsafeShaderEffectDiagnostic.errorMessage?.contains("Schema enum mismatch at $.effects[0].type") == true),
            "bundle diagnostics must reject dynamic shader effect types before renderer dispatch",
            failures: &failures,
            checks: &checks
        )

        let invalidLoopRangeRoot = fixtureParent.appendingPathComponent("invalid_loop_range_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: invalidLoopRangeRoot,
            imageSource: sourceImage,
            id: "invalid_loop_range_bundle",
            title: "Invalid Loop Range Bundle",
            manifestExtraJSON: """
          "effects": [
            {
              "id": "loopPan",
              "type": "scroll",
              "budget": {
                "costClass": "low",
                "maxPasses": 1,
                "maxAnimatedProperties": 1
              },
              "fallback": {
                "policy": "static-value",
                "reason": "Freeze fixture scroll offset if effect budget is exceeded."
              }
            }
          ],
          "bindings": [
            {
              "id": "badLoop",
              "source": "system.time",
              "target": "effect.loopPan.offsetX",
              "adapter": {
                "type": "map-range",
                "inputRange": [2, 0],
                "outputRange": [0, 1],
                "loop": true
              }
            }
          ],
"""
        )
        let invalidLoopRangeDiagnostic = WallpaperBundleCatalog.diagnoseBundle(invalidLoopRangeRoot)
        check(
            invalidLoopRangeDiagnostic.status == .invalid
                && (invalidLoopRangeDiagnostic.errorMessage?.contains("map-range loop requires an ascending inputRange") == true),
            "bundle diagnostics must reject looped map-range bindings whose input range cannot define a forward cycle",
            failures: &failures,
            checks: &checks
        )

        let unknownManifestPropertyRoot = fixtureParent.appendingPathComponent("unknown_manifest_property_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: unknownManifestPropertyRoot,
            imageSource: sourceImage,
            id: "unknown_manifest_property_bundle",
            title: "Unknown Manifest Property Bundle",
            manifestExtraJSON: """
          "typoRuntime": true,
"""
        )
        let unknownManifestPropertyDiagnostic = WallpaperBundleCatalog.diagnoseBundle(unknownManifestPropertyRoot)
        check(
            unknownManifestPropertyDiagnostic.status == .invalid
                && (unknownManifestPropertyDiagnostic.errorMessage?.contains("Schema unknown property typoRuntime") == true),
            "bundle diagnostics must reject unknown manifest properties before Decodable can silently ignore authoring typos",
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

        let emptyLookDirectionActionRoot = fixtureParent.appendingPathComponent("empty_look_direction_action_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: emptyLookDirectionActionRoot,
            imageSource: sourceImage,
            id: "empty_look_direction_action_bundle",
            title: "Empty Look Direction Action Bundle",
            interactionsJSON: """
            [
              {
                "event": "pointerMove",
                "mapping": "lookDirection",
                "actions": {
                  "left": "Left",
                  "right": "",
                  "up": "Up",
                  "down": "Down",
                  "idle": "idle"
                }
              }
            ]
            """
        )
        let emptyLookDirectionActionDiagnostic = WallpaperBundleCatalog.diagnoseBundle(emptyLookDirectionActionRoot)
        check(
            emptyLookDirectionActionDiagnostic.status == .invalid
                && (emptyLookDirectionActionDiagnostic.errorMessage?.contains("Schema minLength failed at $.interactions[0].actions.right") == true),
            "bundle diagnostics must apply schema-valued additionalProperties so empty pointerMove action values fail during schema preflight",
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
                && (
                    missingPointerMoveMappingDiagnostic.errorMessage?.contains("pointerMove interaction requires mapping") == true
                    || missingPointerMoveMappingDiagnostic.errorMessage?.contains("Schema required property mapping missing") == true
                ),
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

        let ambiguousHitZoneShapeRoot = fixtureParent.appendingPathComponent("ambiguous_hit_zone_shape_bundle", isDirectory: true)
        _ = try writeStaticImageBundleFixture(
            root: ambiguousHitZoneShapeRoot,
            imageSource: sourceImage,
            id: "ambiguous_hit_zone_shape_bundle",
            title: "Ambiguous Hit Zone Shape Bundle",
            interactionsJSON: """
            [
              {
                "event": "pointerDown",
                "hitZones": [
                  {
                    "id": "target",
                    "rect": [0.10, 0.10, 0.30, 0.30],
                    "ellipse": {
                      "center": [0.20, 0.20],
                      "radii": [0.10, 0.10]
                    },
                    "action": "act",
                    "trigger": "tap",
                    "tailSeconds": 0.5,
                    "buttons": ["left"]
                  }
                ]
              }
            ]
            """
        )
        let ambiguousHitZoneShapeDiagnostic = WallpaperBundleCatalog.diagnoseBundle(ambiguousHitZoneShapeRoot)
        check(
            ambiguousHitZoneShapeDiagnostic.status == .invalid
                && (ambiguousHitZoneShapeDiagnostic.errorMessage?.contains("Schema oneOf failed") == true),
            "bundle diagnostics must reject hit zones that define both rect and ellipse shapes during schema preflight",
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

        let unsafeScriptLayerRoot = fixtureParent.appendingPathComponent("unsafe_script_layer_bundle", isDirectory: true)
        let unsafeScriptLayerManifest = try writeStaticImageBundleFixture(
            root: unsafeScriptLayerRoot,
            imageSource: sourceImage,
            id: "unsafe_script_layer_bundle",
            title: "Unsafe Script Layer Bundle"
        )
        var unsafeScriptLayerJSON = try String(contentsOf: unsafeScriptLayerManifest)
        unsafeScriptLayerJSON = unsafeScriptLayerJSON.replacingOccurrences(
            of: "\"type\": \"static_image\"",
            with: "\"type\": \"script\""
        )
        try Data(unsafeScriptLayerJSON.utf8).write(to: unsafeScriptLayerManifest, options: .atomic)
        let unsafeScriptLayerDiagnostic = WallpaperBundleCatalog.diagnoseBundle(unsafeScriptLayerRoot)
        check(
            unsafeScriptLayerDiagnostic.status == .invalid
                && (unsafeScriptLayerDiagnostic.errorMessage?.contains("Schema enum mismatch at $.layers[0].type") == true),
            "bundle diagnostics must reject executable script layer types before renderer dispatch",
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
                && (
                    absoluteAssetPathDiagnostic.errorMessage?.contains("asset path must be relative") == true
                    || absoluteAssetPathDiagnostic.errorMessage?.contains("Schema not failed at $.assets.staticImage.path") == true
                ),
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
                && (
                    escapingAssetPathDiagnostic.errorMessage?.contains("asset escapes bundle root") == true
                    || escapingAssetPathDiagnostic.errorMessage?.contains("Schema not failed at $.assets.staticImage.path") == true
                ),
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
        interactionPolicyJSON: String? = nil,
        manifestExtraJSON: String = "",
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
        let interactionPolicyBlock = interactionPolicyJSON.map { policyJSON in
            """
          "interactionPolicy": \(policyJSON),
"""
        } ?? ""
        let manifestJSON = """
        {
          "schemaVersion": "macos-wallpaper-native.v2",
          \(manifestExtraJSON)\
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
          \(interactionPolicyBlock)\
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

        linked0
        bounds: 0,0,64,64
        offsets: 0,0,64,64

        linked1
        bounds: 0,0,64,64
        offsets: 0,0,64,64

        front
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
              "attachment": "linked",
              "blend": "additive",
              "dark": "222222ff"
            },
            {
              "name": "overlay",
              "bone": "root",
              "attachment": "front"
            },
            {
              "name": "standalone-sequence",
              "bone": "root",
              "attachment": "spark"
            },
            {
              "name": "markers",
              "bone": "root",
              "blend": "screen"
            }
          ],
          "skins": [
            {
              "name": "alternate",
              "attachments": {
                "slot": {
                  "base": {
                    "path": "base",
                    "sequence": {
                      "count": 2,
                      "start": 0,
                      "digits": 1,
                      "setupIndex": 0
                    },
                    "uvs": [0, 0, 1, 0, 1, 1, 0, 1],
                    "triangles": [0, 1, 2, 2, 3, 0],
                    "vertices": [-50, -50, 50, -50, 50, 50, -50, 50],
                    "color": "00ff0080",
                    "hull": 4
                  }
                }
              }
            },
            {
              "name": "default",
              "attachments": {
                "slot": {
                  "linked": {
                    "type": "linkedmesh",
                    "path": "linked",
                    "skin": "alternate",
                    "parent": "base",
                    "color": "ffffff80"
                  },
                  "untinted-linked": {
                    "type": "linkedmesh",
                    "path": "linked",
                    "skin": "alternate",
                    "parent": "base"
                  }
                },
                "overlay": {
                  "front": {
                    "type": "mesh",
                    "path": "front",
                    "uvs": [0, 0, 1, 0, 1, 1, 0, 1],
                    "triangles": [0, 1, 2, 2, 3, 0],
                    "vertices": [-20, -20, 40, -20, 40, 40, -20, 40],
                    "hull": 4
                  }
                },
                "standalone-sequence": {
                  "spark": {
                    "type": "sequence",
                    "path": "linked",
                    "sequence": {
                      "count": 2,
                      "start": 0,
                      "digits": 1,
                      "setupIndex": 0
                    },
                    "x": -24,
                    "y": 24,
                    "width": 24,
                    "height": 24,
                    "color": "ffffffbf"
                  }
                },
                "markers": {
                  "tap-point": {
                    "type": "point",
                    "x": 4,
                    "y": 5,
                    "rotation": 10
                  },
                  "tap-bounds": {
                    "type": "boundingbox",
                    "vertexCount": 4,
                    "vertices": [-8, -8, 8, -8, 8, 8, -8, 8]
                  }
                }
              }
            }
          ],
          "animations": {
            "idle": {
              "slots": {
                "slot": {
                  "color": [
                    {
                      "time": 0,
                      "color": "ffffffff"
                    },
                    {
                      "time": 0.05,
                      "color": "ffffffff"
                    }
                  ],
                  "rgb": [
                    {
                      "time": 0,
                      "color": "ffffff"
                    },
                    {
                      "time": 0.05,
                      "color": "ffffff"
                    }
                  ],
                  "alpha": [
                    {
                      "time": 0,
                      "value": 1
                    },
                    {
                      "time": 0.05,
                      "value": 1
                    }
                  ],
                  "rgba2": [
                    {
                      "time": 0.02,
                      "light": "ff8080bf",
                      "dark": "111111ff",
                      "curve": [
                        0.0275, 0.95, 0.0425, 0.55,
                        0.0275, 0.50, 0.0425, 0.95,
                        0.0275, 0.50, 0.0425, 0.65,
                        0.0275, 1.00, 0.0425, 1.00,
                        0.0275, 0.07, 0.0425, 0.19,
                        0.0275, 0.18, 0.0425, 0.08,
                        0.0275, 0.07, 0.0425, 0.18
                      ]
                    },
                    {
                      "time": 0.05,
                      "light": "80ffe07f",
                      "dark": "333333ff"
                    }
                  ]
                }
              },
              "attachments": {
                "default": {
                  "slot": {
                    "linked": {
                      "sequence": [
                        {
                          "time": 0,
                          "mode": "loop",
                          "index": 0,
                          "delay": 0.1
                        }
                      ]
                    }
                  },
                  "standalone-sequence": {
                    "spark": {
                      "sequence": [
                        {
                          "time": 0,
                          "mode": "loop",
                          "index": 0,
                          "delay": 0.1
                        }
                      ]
                    }
                  }
                }
              }
            },
            "rgba2SharedCurve": {
              "slots": {
                "slot": {
                  "rgba2": [
                    {
                      "time": 0.02,
                      "light": "ff8080bf",
                      "dark": "111111ff",
                      "curve": [
                        0.0275, 0.95, 0.0425, 0.55,
                        0.0275, 0.95, 0.0425, 0.55,
                        0.0275, 0.95, 0.0425, 0.55,
                        0.0275, 0.95, 0.0425, 0.55,
                        0.0275, 0.95, 0.0425, 0.55,
                        0.0275, 0.95, 0.0425, 0.55,
                        0.0275, 0.95, 0.0425, 0.55
                      ]
                    },
                    {
                      "time": 0.05,
                      "light": "80ffe07f",
                      "dark": "333333ff"
                    }
                  ]
                }
              }
            },
            "rgbCurve": {
              "slots": {
                "slot": {
                  "rgb": [
                    {
                      "time": 0.02,
                      "color": "ff8080",
                      "curve": [
                        0.0275, 0.95, 0.0425, 0.55,
                        0.0275, 0.50, 0.0425, 0.95,
                        0.0275, 0.50, 0.0425, 0.65
                      ]
                    },
                    {
                      "time": 0.05,
                      "color": "80ffe0"
                    }
                  ]
                }
              }
            },
            "rgbSharedCurve": {
              "slots": {
                "slot": {
                  "rgb": [
                    {
                      "time": 0.02,
                      "color": "ff8080",
                      "curve": [
                        0.0275, 0.95, 0.0425, 0.55,
                        0.0275, 0.95, 0.0425, 0.55,
                        0.0275, 0.95, 0.0425, 0.55
                      ]
                    },
                    {
                      "time": 0.05,
                      "color": "80ffe0"
                    }
                  ]
                }
              }
            },
            "rgb2only": {
              "slots": {
                "slot": {
                  "rgb2": [
                    {
                      "time": 0,
                      "light": "ffffff",
                      "dark": "222222ff"
                    },
                    {
                      "time": 0.05,
                      "light": "80ffe0",
                      "dark": "333333ff"
                    }
                  ]
                }
              }
            },
            "legacyTwoColor": {
              "slots": {
                "slot": {
                  "twoColor": [
                    {
                      "time": 0,
                      "light": "ffffffff",
                      "dark": "222222ff"
                    },
                    {
                      "time": 0.05,
                      "light": "ffe0e0bf",
                      "dark": "111111ff"
                    }
                  ]
                }
              }
            },
            "drawOrderSwap": {
              "drawOrder": [
                {
                  "time": 0,
                  "offsets": [
                    {
                      "slot": "slot",
                      "offset": 1
                    }
                  ]
                }
              ]
            },
            "attachmentTintOff": {
              "slots": {
                "slot": {
                  "attachment": [
                    {
                      "time": 0,
                      "name": "untinted-linked"
                    }
                  ]
                }
              }
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
          "interactions": [
            {
              "event": "pointerMove",
              "mapping": "lookDirection",
              "actions": {
                "idle": "idle",
                "left": "rgba2SharedCurve",
                "right": "rgbCurve",
                "up": "rgbSharedCurve",
                "down": "drawOrderSwap"
              }
            },
            {
              "event": "pointerDown",
              "hitZones": [
                {
                  "id": "legacy-two-color",
                  "rect": [0.0, 0.0, 1.0, 1.0],
                  "action": "legacyTwoColor",
                  "trigger": "tap",
                  "buttons": ["left"]
                }
              ],
              "defaultAction": {
                "action": "attachmentTintOff",
                "trigger": "tap",
                "buttons": ["left"]
              }
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
        check(compatibility.isSupported, "external-skin linkedmesh fixture must pass native compatibility gate", failures: &failures, checks: &checks)
        check(compatibility.reasonText == "supported", "external-skin linkedmesh compatibility must not report unsupported reasons", failures: &failures, checks: &checks)
        let linkedMeshCapabilitiesSummary = linkedMeshRuntime.runtimeCapabilitiesSummary()
        check(
            linkedMeshCapabilitiesSummary
                .contains("spine\tattachments\tsupported\trenderable=linkedmesh,mesh,sequence ignoredNonVisual=boundingbox,point")
                && linkedMeshCapabilitiesSummary.contains("attachment/slot/linked:static-tint"),
            "runtime capabilities must report renderable Spine attachments, standalone sequence support, ignored non-visual point/boundingbox attachments, and static attachment tint support (\(linkedMeshCapabilitiesSummary))",
            failures: &failures,
            checks: &checks
        )
        check(
            linkedMeshRuntime.runtimeCapabilitiesSummary()
                .contains("spine\teventsAudioSequence\tsupported\tevents=none audio=none sequence=playback"),
            "runtime capabilities must support Spine sequence timelines instead of forcing composite fallback",
            failures: &failures,
            checks: &checks
        )
        check(
            linkedMeshRuntime.runtimeCapabilitiesSummary()
                .contains("spine\ttimelines\tsupported\tused=attachments.sequence,drawOrder,slots.alpha,slots.attachment,slots.color,slots.rgb,slots.rgb2,slots.rgba2,slots.twoColor"),
            "runtime capabilities must report drawOrder, attachment swaps, legacy slot color plus rgb/alpha, Spine 4.2 rgb2/rgba2, and legacy twoColor timelines as supported",
            failures: &failures,
            checks: &checks
        )
        check(
            linkedMeshRuntime.runtimeCapabilitiesSummary()
                .contains("spine\tblendModes\tsupported")
                && linkedMeshRuntime.runtimeCapabilitiesSummary().contains("additive")
                && linkedMeshRuntime.runtimeCapabilitiesSummary().contains("normal")
                && linkedMeshRuntime.runtimeCapabilitiesSummary().contains("screen")
                && linkedMeshRuntime.runtimeCapabilitiesSummary().contains("unsupported=none"),
            "runtime capabilities must report normal, additive, and screen Spine blend modes as native-supported",
            failures: &failures,
            checks: &checks
        )
        check(
            linkedMeshRuntime.runtimeCapabilitiesSummary()
                .contains("spine\tslotFeatures\tsupported\tsupported=slot/slot:static-two-color-tint unsupported=none"),
            "runtime capabilities must report static Spine two-color tint as native-supported on a renderable fixture",
            failures: &failures,
            checks: &checks
        )
        let linkedMeshAnimationPlan = try SpineAnimationDiagnostics.make(runtime: linkedMeshRuntime)
        check(
            linkedMeshAnimationPlan.contains("unsupportedActionTimelines: none")
                && linkedMeshAnimationPlan.contains("animation\tidle\tavailable")
                && linkedMeshAnimationPlan.contains("slot.alpha=1")
                && linkedMeshAnimationPlan.contains("slot.color=1")
                && linkedMeshAnimationPlan.contains("slot.rgb=1")
                && linkedMeshAnimationPlan.contains("slot.rgba2=1")
                && linkedMeshAnimationPlan.contains("slot.rgb2=1")
                && linkedMeshAnimationPlan.contains("slot.twoColor=1")
                && linkedMeshAnimationPlan.contains("attachment.sequence=2")
                && linkedMeshAnimationPlan.contains("drawOrder=1"),
            "Spine animation diagnostics must align with native runtime support for drawOrder, slot color/rgb/alpha/rgb2/rgba2/twoColor, and sequence timelines",
            failures: &failures,
            checks: &checks
        )
        if SpineGeometryDiagnostics.validationStatus(runtime: linkedMeshRuntime) == "required" {
            try linkedMeshRuntime.requireNativeSpineGeometryIfSupported()
            let linkedMeshGeometryPlan = try SpineGeometryDiagnostics.make(runtime: linkedMeshRuntime)
            let setupFingerprint = geometryFingerprint(in: linkedMeshGeometryPlan, action: "idle", time: "0.000s")
            let firstTwoColorFingerprint = geometryFingerprint(in: linkedMeshGeometryPlan, action: "idle", time: "0.020s")
            let curveTwoColorFingerprint = geometryFingerprint(in: linkedMeshGeometryPlan, action: "idle", time: "0.025s")
            let sharedTwoColorFingerprint = geometryFingerprint(in: linkedMeshGeometryPlan, action: "rgba2SharedCurve", time: "0.025s")
            let rgbPerChannelFingerprint = geometryFingerprint(in: linkedMeshGeometryPlan, action: "rgbCurve", time: "0.025s")
            let rgbSharedFingerprint = geometryFingerprint(in: linkedMeshGeometryPlan, action: "rgbSharedCurve", time: "0.025s")
            let drawOrderFingerprint = geometryFingerprint(in: linkedMeshGeometryPlan, action: "drawOrderSwap", time: "0.000s")
            let attachmentTintOffFingerprint = geometryFingerprint(in: linkedMeshGeometryPlan, action: "attachmentTintOff", time: "0.000s")
            let setupVertexCount = geometryColumn(in: linkedMeshGeometryPlan, action: "idle", time: "0.000s", column: 5)
            let drawOrderVertexCount = geometryColumn(in: linkedMeshGeometryPlan, action: "drawOrderSwap", time: "0.000s", column: 5)
            let attachmentTintOffVertexCount = geometryColumn(in: linkedMeshGeometryPlan, action: "attachmentTintOff", time: "0.000s", column: 5)
            let setupColors = geometryColumn(in: linkedMeshGeometryPlan, action: "idle", time: "0.000s", column: 10)
            let attachmentTintOffColors = geometryColumn(in: linkedMeshGeometryPlan, action: "attachmentTintOff", time: "0.000s", column: 10)
            check(
                setupFingerprint != nil
                    && firstTwoColorFingerprint != nil
                    && curveTwoColorFingerprint != nil
                    && setupFingerprint != firstTwoColorFingerprint,
                "Spine rgba2 timelines must preserve setup tint before the first keyframe and change geometry at the first keyframe",
                failures: &failures,
                checks: &checks
            )
            check(
                sharedTwoColorFingerprint != nil
                    && curveTwoColorFingerprint != sharedTwoColorFingerprint,
                "Spine rgba2 per-channel Bezier curves must not collapse to the first channel curve for light and dark tint channels",
                failures: &failures,
                checks: &checks
            )
            check(
                rgbPerChannelFingerprint != nil
                    && rgbSharedFingerprint != nil
                    && rgbPerChannelFingerprint != rgbSharedFingerprint,
                "Spine rgb per-channel Bezier curves must use three-channel curve entries instead of falling back to a shared channel curve",
                failures: &failures,
                checks: &checks
            )
            check(
                drawOrderFingerprint != nil
                    && setupFingerprint != drawOrderFingerprint,
                "Spine drawOrder timelines must change the native geometry fingerprint instead of being scanner-only support",
                failures: &failures,
                checks: &checks
            )
            check(
                setupVertexCount != nil
                    && setupVertexCount == drawOrderVertexCount,
                "Spine drawOrder timelines must reorder existing geometry without adding or dropping vertices",
                failures: &failures,
                checks: &checks
            )
            check(
                attachmentTintOffFingerprint != nil
                    && setupFingerprint != attachmentTintOffFingerprint,
                "Spine static attachment color tint must affect native geometry color instead of being parsed-only metadata",
                failures: &failures,
                checks: &checks
            )
            check(
                setupVertexCount != nil
                    && setupVertexCount == attachmentTintOffVertexCount,
                "Spine static attachment color tint must recolor existing geometry without adding or dropping vertices",
                failures: &failures,
                checks: &checks
            )
            check(
                setupColors == "light:0.502,0.502,0.502,0.502;dark:0.133,0.133,0.133,0.000",
                "Spine static attachment alpha tint must premultiply light color while keeping two-color dark RGB unpremultiplied (actual \(setupColors ?? "nil"))",
                failures: &failures,
                checks: &checks
            )
            check(
                attachmentTintOffColors == "light:1.000,1.000,1.000,1.000;dark:0.133,0.133,0.133,0.000",
                "Spine linkedmesh without an own color must default to white instead of inheriting parent mesh tint (actual \(attachmentTintOffColors ?? "nil"))",
                failures: &failures,
                checks: &checks
            )
        }

        let legacySkinSpineJSON = """
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
              "attachment": "base"
            }
          ],
          "skins": {
            "default": {
              "slot": {
                "base": {
                  "type": "mesh",
                  "path": "base",
                  "uvs": [0, 0, 1, 0, 1, 1, 0, 1],
                  "triangles": [0, 1, 2, 2, 3, 0],
                  "vertices": [-50, -50, 50, -50, 50, 50, -50, 50],
                  "hull": 4
                }
              }
            }
          },
          "animations": {
            "idle": {}
          }
        }
        """
        try Data(legacySkinSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let legacySkinManifestJSON = manifestJSON.replacingOccurrences(of: """
          "interactions": [
            {
              "event": "pointerMove",
              "mapping": "lookDirection",
              "actions": {
                "idle": "idle",
                "left": "rgba2SharedCurve",
                "right": "rgbCurve",
                "up": "rgbSharedCurve",
                "down": "drawOrderSwap"
              }
            },
            {
              "event": "pointerDown",
              "hitZones": [
                {
                  "id": "legacy-two-color",
                  "rect": [0.0, 0.0, 1.0, 1.0],
                  "action": "legacyTwoColor",
                  "trigger": "tap",
                  "buttons": ["left"]
                }
              ],
              "defaultAction": {
                "action": "attachmentTintOff",
                "trigger": "tap",
                "buttons": ["left"]
              }
            }
          ],
        """, with: """
          "interactions": [],
        """)
        try Data(legacySkinManifestJSON.utf8).write(to: manifestURL, options: .atomic)
        let legacySkinRuntime = try NativeRuntimeCore(config: linkedMeshRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let legacySkinCompatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: legacySkinRuntime)
        check(
            legacySkinCompatibility.isSupported,
            "legacy object-form Spine skins must pass native compatibility gate",
            failures: &failures,
            checks: &checks
        )
        check(
            legacySkinRuntime.runtimeCapabilitiesSummary().contains("spine\tattachments\tsupported\trenderable=mesh ignoredNonVisual=none"),
            "runtime capabilities must scan legacy object-form Spine skins",
            failures: &failures,
            checks: &checks
        )
        if SpineGeometryDiagnostics.validationStatus(runtime: legacySkinRuntime) == "required" {
            try legacySkinRuntime.requireNativeSpineGeometryIfSupported()
        }

        let implicitMeshSpineJSON = """
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
              "attachment": "implicit-mesh"
            }
          ],
          "skins": [
            {
              "name": "default",
              "attachments": {
                "slot": {
                  "implicit-mesh": {
                    "path": "base",
                    "uvs": [0, 0, 1, 0, 1, 1, 0, 1],
                    "triangles": [0, 1, 2, 2, 3, 0],
                    "vertices": [-50, -50, 50, -50, 50, 50, -50, 50],
                    "hull": 4
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
        try Data(implicitMeshSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let implicitMeshRuntime = try NativeRuntimeCore(config: legacySkinRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let implicitMeshCompatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: implicitMeshRuntime)
        check(
            implicitMeshCompatibility.isSupported,
            "untyped Spine mesh attachments with triangles/uvs must pass native compatibility gate",
            failures: &failures,
            checks: &checks
        )
        check(
            implicitMeshRuntime.runtimeCapabilitiesSummary().contains("spine\tattachments\tsupported\trenderable=mesh ignoredNonVisual=none"),
            "runtime capabilities must infer untyped Spine attachments with triangles/uvs as mesh",
            failures: &failures,
            checks: &checks
        )
        if SpineGeometryDiagnostics.validationStatus(runtime: implicitMeshRuntime) == "required" {
            try implicitMeshRuntime.requireNativeSpineGeometryIfSupported()
            let implicitMeshGeometryPlan = try SpineGeometryDiagnostics.make(runtime: implicitMeshRuntime)
            check(
                geometryColumn(in: implicitMeshGeometryPlan, action: "idle", time: "0.000s", column: 5) == "6",
                "Spine renderer must draw direct untyped mesh attachments instead of treating them as regions",
                failures: &failures,
                checks: &checks
            )
        }
    }

    private static func checkClippingSpineGeometryBundle(
        from runtime: NativeRuntimeCore,
        failures: inout [String],
        checks: inout Int
    ) throws {
        checks += 1
        guard let sourceVideo = runtime.assetCatalog.compositeVideoAssetURL ?? runtime.assetCatalog.videoAssetURL else {
            failures.append("clipping Spine fixture requires an active video asset")
            return
        }

        checks += 1
        guard let sourceTexture = runtime.assetCatalog.spineAsset?.textures.first else {
            failures.append("clipping Spine fixture requires an active Spine texture")
            return
        }

        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineClippingSpineSelfTest-\(UUID().uuidString)", isDirectory: true)
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

        full-quad
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
              "name": "clipper",
              "bone": "root"
            },
            {
              "name": "weightedClipper",
              "bone": "root"
            },
            {
              "name": "target",
              "bone": "root",
              "attachment": "full-quad"
            }
          ],
          "skins": [
            {
              "name": "default",
              "attachments": {
                "clipper": {
                  "mask": {
                    "type": "clipping",
                    "end": "target",
                    "vertexCount": 4,
                    "vertices": [-25, -25, 25, -25, 25, 25, -25, 25]
                  }
                },
                "weightedClipper": {
                  "weighted-mask": {
                    "type": "clipping",
                    "end": "target",
                    "vertexCount": 4,
                    "vertices": [1, 0, -25, -25, 1, 1, 0, 25, -25, 1, 1, 0, 25, 25, 1, 1, 0, -25, 25, 1]
                  }
                },
                "target": {
                  "full-quad": {
                    "type": "mesh",
                    "path": "full-quad",
                    "uvs": [0, 0, 1, 0, 1, 1, 0, 1],
                    "triangles": [0, 1, 2, 2, 3, 0],
                    "vertices": [-50, -50, 50, -50, 50, 50, -50, 50],
                    "hull": 4
                  }
                }
              }
            }
          ],
          "animations": {
            "unclipped": {},
            "clipped": {
              "slots": {
                "clipper": {
                  "attachment": [
                    {
                      "time": 0,
                      "name": "mask"
                    }
                  ]
                }
              }
            },
            "deformedClipped": {
              "slots": {
                "clipper": {
                  "attachment": [
                    {
                      "time": 0,
                      "name": "mask"
                    }
                  ]
                }
              },
              "attachments": {
                "default": {
                  "clipper": {
                    "mask": {
                      "deform": [
                        {
                          "time": 0,
                          "vertices": [10, 10, -10, 10, -10, -10, 10, -10]
                        }
                      ]
                    }
                  }
                }
              }
            },
            "topLevelDeformedClipped": {
              "slots": {
                "clipper": {
                  "attachment": [
                    {
                      "time": 0,
                      "name": "mask"
                    }
                  ]
                }
              },
              "deform": {
                "default": {
                  "clipper": {
                    "mask": [
                      {
                        "time": 0,
                        "vertices": [12, 12, -12, 12, -12, -12, 12, -12]
                      }
                    ]
                  }
                }
              }
            },
            "weightedDeformedClipped": {
              "slots": {
                "weightedClipper": {
                  "attachment": [
                    {
                      "time": 0,
                      "name": "weighted-mask"
                    }
                  ]
                }
              },
              "attachments": {
                "default": {
                  "weightedClipper": {
                    "weighted-mask": {
                      "deform": [
                        {
                          "time": 0,
                          "vertices": [10, 10, -10, 10, -10, -10, 10, -10]
                        }
                      ]
                    }
                  }
                }
              }
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
            "id": "selftest_clipping_spine",
            "title": "Self Test Clipping Spine"
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
              "id": "clippingCharacter",
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
              "asset": "clippingCharacter",
              "renderingMode": "setup-mesh"
            }
          ],
          "interactions": [
            {
              "event": "pointerMove",
              "mapping": "lookDirection",
              "actions": {
                "idle": "unclipped",
                "left": "clipped",
                "right": "topLevelDeformedClipped",
                "up": "deformedClipped",
                "down": "weightedDeformedClipped"
              }
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

        let clippingRuntime = try NativeRuntimeCore(config: runtime.config.replacing(
            wallpaperRoot: fixtureRoot,
            manifestURL: manifestURL,
            displayMode: .primaryAnimated,
            renderFps: 30,
            foregroundMode: .nativeSpine,
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))

        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: clippingRuntime)
        check(
            compatibility.isSupported,
            "Spine clipping fixture must pass native compatibility gate",
            failures: &failures,
            checks: &checks
        )
        check(
            clippingRuntime.runtimeCapabilitiesSummary()
                .contains("spine\tattachments\tsupported\trenderable=clipping,mesh ignoredNonVisual=none"),
            "runtime capabilities must report Spine clipping attachments as native-supported",
            failures: &failures,
            checks: &checks
        )
        if SpineGeometryDiagnostics.validationStatus(runtime: clippingRuntime) == "required" {
            try clippingRuntime.requireNativeSpineGeometryIfSupported()
            let clippingGeometryPlan = try SpineGeometryDiagnostics.make(runtime: clippingRuntime)
            let unclippedFingerprint = geometryFingerprint(in: clippingGeometryPlan, action: "unclipped", time: "0.000s")
            let clippedFingerprint = geometryFingerprint(in: clippingGeometryPlan, action: "clipped", time: "0.000s")
            let deformedClippedFingerprint = geometryFingerprint(in: clippingGeometryPlan, action: "deformedClipped", time: "0.000s")
            let topLevelDeformedClippedFingerprint = geometryFingerprint(in: clippingGeometryPlan, action: "topLevelDeformedClipped", time: "0.000s")
            let weightedDeformedClippedFingerprint = geometryFingerprint(in: clippingGeometryPlan, action: "weightedDeformedClipped", time: "0.000s")
            let unclippedBounds = geometryColumn(in: clippingGeometryPlan, action: "unclipped", time: "0.000s", column: 8)
            let clippedBounds = geometryColumn(in: clippingGeometryPlan, action: "clipped", time: "0.000s", column: 8)
            let deformedClippedBounds = geometryColumn(in: clippingGeometryPlan, action: "deformedClipped", time: "0.000s", column: 8)
            let topLevelDeformedClippedBounds = geometryColumn(in: clippingGeometryPlan, action: "topLevelDeformedClipped", time: "0.000s", column: 8)
            let weightedDeformedClippedBounds = geometryColumn(in: clippingGeometryPlan, action: "weightedDeformedClipped", time: "0.000s", column: 8)
            check(
                unclippedFingerprint != nil
                    && clippedFingerprint != nil
                    && unclippedFingerprint != clippedFingerprint
                    && unclippedBounds != nil
                    && clippedBounds != nil
                    && unclippedBounds != clippedBounds,
                "Spine clipping diagnostics must prove clipped geometry differs from the same mesh rendered without clipping",
                failures: &failures,
                checks: &checks
            )
            check(
                clippedFingerprint != nil
                    && deformedClippedFingerprint != nil
                    && clippedFingerprint != deformedClippedFingerprint
                    && clippedBounds != nil
                    && deformedClippedBounds != nil
                    && clippedBounds != deformedClippedBounds,
                "Spine clipping deform timelines must change clipping polygon geometry instead of being scanner-only support (clipped=\(clippedFingerprint ?? "nil") \(clippedBounds ?? "nil") deformed=\(deformedClippedFingerprint ?? "nil") \(deformedClippedBounds ?? "nil"))",
                failures: &failures,
                checks: &checks
            )
            check(
                clippedFingerprint != nil
                    && topLevelDeformedClippedFingerprint != nil
                    && clippedFingerprint != topLevelDeformedClippedFingerprint
                    && clippedBounds != nil
                    && topLevelDeformedClippedBounds != nil
                    && clippedBounds != topLevelDeformedClippedBounds,
                "Spine top-level deform timelines must change clipping polygon geometry instead of only supporting attachments.deform wrapper syntax (clipped=\(clippedFingerprint ?? "nil") \(clippedBounds ?? "nil") topLevel=\(topLevelDeformedClippedFingerprint ?? "nil") \(topLevelDeformedClippedBounds ?? "nil"))",
                failures: &failures,
                checks: &checks
            )
            check(
                clippedFingerprint != nil
                    && weightedDeformedClippedFingerprint != nil
                    && clippedFingerprint != weightedDeformedClippedFingerprint
                    && clippedBounds != nil
                    && weightedDeformedClippedBounds != nil
                    && clippedBounds != weightedDeformedClippedBounds,
                "Spine weighted clipping deform timelines must change clipping polygon geometry instead of relying on unweighted-only coverage (clipped=\(clippedFingerprint ?? "nil") \(clippedBounds ?? "nil") weighted=\(weightedDeformedClippedFingerprint ?? "nil") \(weightedDeformedClippedBounds ?? "nil"))",
                failures: &failures,
                checks: &checks
            )
        }
    }

    private static func checkPathConstraintSpineGeometryBundle(
        from runtime: NativeRuntimeCore,
        failures: inout [String],
        checks: inout Int
    ) throws {
        checks += 1
        guard let sourceVideo = runtime.assetCatalog.compositeVideoAssetURL ?? runtime.assetCatalog.videoAssetURL else {
            failures.append("path-constraint Spine fixture requires an active video asset")
            return
        }

        checks += 1
        guard let sourceTexture = runtime.assetCatalog.spineAsset?.textures.first else {
            failures.append("path-constraint Spine fixture requires an active Spine texture")
            return
        }

        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MacWallpaperEnginePathConstraintSpineSelfTest-\(UUID().uuidString)", isDirectory: true)
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

        quad
        bounds: 0,0,64,64
        offsets: 0,0,64,64
        """
        try Data(atlasText.utf8).write(to: fixtureAtlas, options: .atomic)

        let legacyPathConstraintBlock = """
          "path": [
            {
              "name": "supported-proportional-path",
              "bones": ["follower"],
              "target": "path-slot",
              "positionMode": "percent",
              "spacingMode": "proportional",
              "rotateMode": "chainscale",
              "position": 0.15,
              "spacing": 0.60,
              "mixRotate": 0.7,
              "mixX": 0.6,
              "mixY": 0.6
            }
          ],
        """
        let officialPathConstraintBlock = """
          "path": [
            {
              "name": "supported-proportional-path",
              "bones": ["follower"],
              "target": "path-slot",
              "positionMode": "percent",
              "spacingMode": "proportional",
              "rotateMode": "chainscale",
              "position": 0.15,
              "spacing": 0.60,
              "rotateMix": 0.7,
              "translateMix": 0.6
            }
          ],
        """
        let animatedPathConstraintBlock = """
          "path": [
            {
              "name": "supported-proportional-path",
              "bones": ["follower"],
              "target": "path-slot",
              "positionMode": "percent",
              "spacingMode": "proportional",
              "rotateMode": "chainscale",
              "position": 0.15,
              "spacing": 0.60,
              "rotateMix": 0,
              "translateMix": 0
            }
          ],
        """
        let animatedPathPositionSpacingConstraintBlock = """
          "path": [
            {
              "name": "supported-proportional-path",
              "bones": ["follower"],
              "target": "path-slot",
              "positionMode": "percent",
              "spacingMode": "proportional",
              "rotateMode": "chainscale",
              "position": 0.05,
              "spacing": 0.25,
              "rotateMix": 0.7,
              "translateMix": 0.6
            }
          ],
        """
        let spineTemplate = """
        {
          "skeleton": {
            "spine": "4.2.43",
            "x": -100,
            "y": -100,
            "width": 200,
            "height": 200
          },
          "bones": [
            {
              "name": "root"
            },
            {
              "name": "follower",
              "parent": "root",
              "x": -70,
              "y": -70,
              "length": 44
            }
          ],
          "slots": [
            {
              "name": "path-slot",
              "bone": "root",
              "attachment": "motion-path"
            },
            {
              "name": "follower-slot",
              "bone": "follower",
              "attachment": "quad"
            }
          ],
        __PATH_CONSTRAINT_BLOCK__
          "skins": [
            {
              "name": "default",
              "attachments": {
                "path-slot": {
                  "motion-path": {
                    "type": "path",
                    "closed": true,
                    "constantSpeed": true,
                    "vertexCount": 4,
                    "vertices": [-60, 0, -20, 80, 20, 80, 60, 0],
                    "lengths": [140]
                  }
                },
                "follower-slot": {
                  "quad": {
                    "type": "region",
                    "path": "quad",
                    "x": 22,
                    "y": 0,
                    "width": 24,
                    "height": 24
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
        let fixtureSpineJSON = assetsRoot.appendingPathComponent("character.json")
        let manifestURL = fixtureRoot.appendingPathComponent("wallpaper.native.json")
        let manifestJSON = """
        {
          "schemaVersion": "macos-wallpaper-native.v2",
          "metadata": {
            "id": "selftest_path_constraint_spine",
            "title": "Self Test Path Constraint Spine"
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
              "id": "pathConstraintCharacter",
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
              "asset": "pathConstraintCharacter",
              "renderingMode": "setup-mesh"
            }
          ],
          "interactions": [
            {
              "event": "pointerDown",
              "hitZones": [
                {
                  "id": "path-action",
                  "rect": [0.25, 0.25, 0.75, 0.75],
                  "action": "idle"
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

        let noConstraintSpineJSON = spineTemplate.replacingOccurrences(
            of: "__PATH_CONSTRAINT_BLOCK__",
            with: ""
        )
        try Data(noConstraintSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let noConstraintRuntime = try NativeRuntimeCore(config: runtime.config.replacing(
            wallpaperRoot: fixtureRoot,
            manifestURL: manifestURL,
            displayMode: .primaryAnimated,
            renderFps: 30,
            foregroundMode: .nativeSpine,
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let noConstraintGeometryRequired = SpineGeometryDiagnostics.validationStatus(runtime: noConstraintRuntime) == "required"
        let noConstraintFingerprint: String?
        let noConstraintBounds: String?
        if noConstraintGeometryRequired {
            try noConstraintRuntime.requireNativeSpineGeometryIfSupported()
            let noConstraintGeometryPlan = try SpineGeometryDiagnostics.make(runtime: noConstraintRuntime)
            noConstraintFingerprint = geometryFingerprint(in: noConstraintGeometryPlan, action: "idle", time: "0.000s")
            noConstraintBounds = geometryColumn(in: noConstraintGeometryPlan, action: "idle", time: "0.000s", column: 8)
        } else {
            noConstraintFingerprint = nil
            noConstraintBounds = nil
        }

        let legacyPathConstraintSpineJSON = spineTemplate.replacingOccurrences(
            of: "__PATH_CONSTRAINT_BLOCK__",
            with: legacyPathConstraintBlock
        )
        try Data(legacyPathConstraintSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let legacyPathConstraintRuntime = try NativeRuntimeCore(config: noConstraintRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let legacyPathConstraintFingerprint: String?
        if noConstraintGeometryRequired {
            try legacyPathConstraintRuntime.requireNativeSpineGeometryIfSupported()
            let legacyPathConstraintGeometryPlan = try SpineGeometryDiagnostics.make(runtime: legacyPathConstraintRuntime)
            legacyPathConstraintFingerprint = geometryFingerprint(
                in: legacyPathConstraintGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
        } else {
            legacyPathConstraintFingerprint = nil
        }

        let officialPathConstraintSpineJSON = spineTemplate.replacingOccurrences(
            of: "__PATH_CONSTRAINT_BLOCK__",
            with: officialPathConstraintBlock
        )
        try Data(officialPathConstraintSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let pathConstraintRuntime = try NativeRuntimeCore(config: noConstraintRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))

        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: pathConstraintRuntime)
        check(
            compatibility.isSupported,
            "official Spine proportional path constraint mix aliases must pass native compatibility gate",
            failures: &failures,
            checks: &checks
        )
        check(
            pathConstraintRuntime.runtimeCapabilitiesSummary().contains("spine\tconstraints\tsupported")
                && pathConstraintRuntime.runtimeCapabilitiesSummary().contains("used=path")
                && pathConstraintRuntime.runtimeCapabilitiesSummary().contains("spacingMode=proportional") == false,
            "capability diagnostics must report official Spine proportional path constraint mix aliases as renderer-supported",
            failures: &failures,
            checks: &checks
        )

        if noConstraintGeometryRequired && SpineGeometryDiagnostics.validationStatus(runtime: pathConstraintRuntime) == "required" {
            try pathConstraintRuntime.requireNativeSpineGeometryIfSupported()
            let pathConstraintGeometryPlan = try SpineGeometryDiagnostics.make(runtime: pathConstraintRuntime)
            let pathConstraintFingerprint = geometryFingerprint(in: pathConstraintGeometryPlan, action: "idle", time: "0.000s")
            let pathConstraintBounds = geometryColumn(in: pathConstraintGeometryPlan, action: "idle", time: "0.000s", column: 8)
            check(
                noConstraintFingerprint != nil
                    && pathConstraintFingerprint != nil
                    && noConstraintFingerprint != pathConstraintFingerprint,
                "official Spine proportional path constraint mix aliases must change native geometry instead of being scanner-only support",
                failures: &failures,
                checks: &checks
            )
            check(
                legacyPathConstraintFingerprint != nil
                    && pathConstraintFingerprint != nil
                    && legacyPathConstraintFingerprint == pathConstraintFingerprint,
                "official Spine path constraint mix aliases must render the same geometry as legacy runtime mix fields",
                failures: &failures,
                checks: &checks
            )
            check(
                noConstraintBounds != nil
                    && pathConstraintBounds != nil
                    && noConstraintBounds != pathConstraintBounds,
                "official Spine proportional path constraint mix aliases must move visible geometry bounds",
                failures: &failures,
                checks: &checks
            )

            let animatedPathConstraintSpineJSON = spineTemplate
                .replacingOccurrences(
                    of: "__PATH_CONSTRAINT_BLOCK__",
                    with: animatedPathConstraintBlock
                )
                .replacingOccurrences(
                    of: "\"idle\": {}",
                    with: """
                    "idle": {
                      "path": {
                        "supported-proportional-path": {
                          "rotateMix": [
                            { "time": 0, "value": 0 },
                            { "time": 0.05, "value": 0.7 }
                          ],
                          "translateMix": [
                            { "time": 0, "value": 0 },
                            { "time": 0.05, "value": 0.6 }
                          ]
                        }
                      }
                    }
                    """
                )
            try Data(animatedPathConstraintSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
            let animatedPathConstraintRuntime = try NativeRuntimeCore(config: noConstraintRuntime.config.replacing(
                clearDuration: true,
                launchControlPanel: false,
                launchWallpaper: false
            ))
            let animatedPathConstraintCompatibility = RuntimeCapabilities.nativeSpineCompatibility(
                runtime: animatedPathConstraintRuntime
            )
            check(
                animatedPathConstraintCompatibility.isSupported,
                "Spine path constraint mix timelines must pass native compatibility gate",
                failures: &failures,
                checks: &checks
            )
            let animatedPathConstraintAnimationPlan = try SpineAnimationDiagnostics.make(
                runtime: animatedPathConstraintRuntime
            )
            check(
                animatedPathConstraintAnimationPlan.contains("unsupportedActionTimelines: none")
                    && animatedPathConstraintAnimationPlan.contains("coverage\tidle\tcompatible"),
                "Spine animation diagnostics must mark path constraint mix timelines compatible for manifest actions",
                failures: &failures,
                checks: &checks
            )
            check(
                animatedPathConstraintAnimationPlan.contains("path.rotateMix=1")
                    && animatedPathConstraintAnimationPlan.contains("path.translateMix=1"),
                "Spine animation diagnostics must summarize path constraint mix timeline types instead of top-level path as unsupported",
                failures: &failures,
                checks: &checks
            )
            try animatedPathConstraintRuntime.requireNativeSpineGeometryIfSupported()
            let animatedPathConstraintGeometryPlan = try SpineGeometryDiagnostics.make(runtime: animatedPathConstraintRuntime)
            let animatedPathStartFingerprint = geometryFingerprint(
                in: animatedPathConstraintGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
            let animatedPathMixedFingerprint = geometryFingerprint(
                in: animatedPathConstraintGeometryPlan,
                action: "idle",
                time: "0.050s"
            )
            check(
                animatedPathStartFingerprint != nil
                    && noConstraintFingerprint != nil
                    && animatedPathStartFingerprint == noConstraintFingerprint,
                "Spine path constraint mix timelines must preserve setup geometry before the animated mix turns on",
                failures: &failures,
                checks: &checks
            )
            check(
                animatedPathMixedFingerprint != nil
                    && pathConstraintFingerprint != nil
                    && animatedPathMixedFingerprint == pathConstraintFingerprint,
                "Spine path constraint mix timelines must render the same geometry as equivalent setup mix values",
                failures: &failures,
                checks: &checks
            )

            let animatedPathPositionSpacingSpineJSON = spineTemplate
                .replacingOccurrences(
                    of: "__PATH_CONSTRAINT_BLOCK__",
                    with: animatedPathPositionSpacingConstraintBlock
                )
                .replacingOccurrences(
                    of: "\"idle\": {}",
                    with: """
                    "idle": {
                      "path": {
                        "supported-proportional-path": {
                          "position": [
                            { "time": 0, "value": 0.05 },
                            { "time": 0.05, "value": 0.15 }
                          ],
                          "spacing": [
                            { "time": 0, "value": 0.25 },
                            { "time": 0.05, "value": 0.60 }
                          ]
                        }
                      }
                    }
                    """
                )
            try Data(animatedPathPositionSpacingSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
            let animatedPathPositionSpacingRuntime = try NativeRuntimeCore(config: noConstraintRuntime.config.replacing(
                clearDuration: true,
                launchControlPanel: false,
                launchWallpaper: false
            ))
            let animatedPathPositionSpacingCompatibility = RuntimeCapabilities.nativeSpineCompatibility(
                runtime: animatedPathPositionSpacingRuntime
            )
            check(
                animatedPathPositionSpacingCompatibility.isSupported,
                "Spine path position and spacing timelines must pass native compatibility gate",
                failures: &failures,
                checks: &checks
            )
            let animatedPathPositionSpacingAnimationPlan = try SpineAnimationDiagnostics.make(
                runtime: animatedPathPositionSpacingRuntime
            )
            check(
                animatedPathPositionSpacingAnimationPlan.contains("unsupportedActionTimelines: none")
                    && animatedPathPositionSpacingAnimationPlan.contains("coverage\tidle\tcompatible"),
                "Spine animation diagnostics must mark path position and spacing timelines compatible for manifest actions",
                failures: &failures,
                checks: &checks
            )
            check(
                animatedPathPositionSpacingAnimationPlan.contains("path.position=1")
                    && animatedPathPositionSpacingAnimationPlan.contains("path.spacing=1"),
                "Spine animation diagnostics must summarize path position and spacing timeline types",
                failures: &failures,
                checks: &checks
            )
            try animatedPathPositionSpacingRuntime.requireNativeSpineGeometryIfSupported()
            let animatedPathPositionSpacingGeometryPlan = try SpineGeometryDiagnostics.make(runtime: animatedPathPositionSpacingRuntime)
            let animatedPathPositionSpacingStartFingerprint = geometryFingerprint(
                in: animatedPathPositionSpacingGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
            let animatedPathPositionSpacingMixedFingerprint = geometryFingerprint(
                in: animatedPathPositionSpacingGeometryPlan,
                action: "idle",
                time: "0.050s"
            )
            check(
                animatedPathPositionSpacingStartFingerprint != nil
                    && animatedPathPositionSpacingMixedFingerprint != nil
                    && animatedPathPositionSpacingStartFingerprint != animatedPathPositionSpacingMixedFingerprint,
                "Spine path position and spacing timelines must change native geometry at the keyed time",
                failures: &failures,
                checks: &checks
            )
            check(
                animatedPathPositionSpacingMixedFingerprint != nil
                    && pathConstraintFingerprint != nil
                    && animatedPathPositionSpacingMixedFingerprint == pathConstraintFingerprint,
                "Spine path position and spacing timelines must render the same geometry as equivalent setup position and spacing",
                failures: &failures,
                checks: &checks
            )
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
        let fixtureAtlasText = """
        texture.png
        size: 64,64

        ik-quad
        bounds: 0,0,64,64
        offsets: 0,0,64,64
        """
        try Data(fixtureAtlasText.utf8).write(to: fixtureAtlas, options: .atomic)

        let fixtureSpineJSON = assetsRoot.appendingPathComponent("character.json")
        let eventOnlySpineJSON = """
        {
          "skeleton": {
            "spine": "4.2.43"
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
              "attachment": "ik-quad"
            }
          ],
          "skins": [
            {
              "name": "default",
              "attachments": {
                "slot": {
                  "ik-quad": {
                    "type": "mesh",
                    "path": "ik-quad",
                    "uvs": [0, 0, 1, 0, 1, 1, 0, 1],
                    "triangles": [0, 1, 2, 2, 3, 0],
                    "vertices": [-8, -8, 8, -8, 8, 8, -8, 8],
                    "hull": 4
                  }
                }
              }
            }
          ],
          "animations": {
            "idle": {
              "events": [
                {
                  "time": 0.629,
                  "name": "marker2"
                }
              ],
              "event": [
                {
                  "time": 0.421,
                  "name": "marker"
                }
              ]
            }
          },
          "events": {
            "marker": { "int": 7, "float": 0.25, "string": "rub-start" },
            "marker2": { "string": "rub-end" }
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
                "assets/texture.png"
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
            eventOnlyRuntime.manifest.runtime.effectiveAudioPolicy == .muted,
            "runtime audio policy must default to muted when the manifest omits audioPolicy",
            failures: &failures,
            checks: &checks
        )
        let eventOnlyAnimationPlan = try SpineAnimationDiagnostics.make(runtime: eventOnlyRuntime)
        check(
            eventOnlyAnimationPlan.contains("unsupportedActionTimelines: none")
                && eventOnlyAnimationPlan.contains("animation\tidle\tavailable\t0.629s")
                && eventOnlyAnimationPlan.contains("event=1")
                && eventOnlyAnimationPlan.contains("events=1"),
            "Spine animation diagnostics must report singular and plural event timelines as compatible timelines",
            failures: &failures,
            checks: &checks
        )
        if SpineGeometryDiagnostics.validationStatus(runtime: eventOnlyRuntime) == "required" {
            try eventOnlyRuntime.requireNativeSpineGeometryIfSupported()
            let eventOnlyGeometryPlan = try SpineGeometryDiagnostics.make(runtime: eventOnlyRuntime)
            check(
                geometryFingerprint(in: eventOnlyGeometryPlan, action: "idle", time: "0.421s") != nil
                    && geometryFingerprint(in: eventOnlyGeometryPlan, action: "idle", time: "0.629s") != nil,
                "Spine renderer must include singular and plural event timeline times in native geometry samples",
                failures: &failures,
                checks: &checks
            )
        }
        let userControlledManifestURL = fixtureRoot.appendingPathComponent("user-controlled.native.json")
        let userControlledManifestJSON = eventOnlyManifestJSON.replacingOccurrences(
            of: "\"fallbackFps\": 15,",
            with: "\"fallbackFps\": 15,\n    \"audioPolicy\": \"userControlled\","
        )
        try Data(userControlledManifestJSON.utf8).write(to: userControlledManifestURL, options: .atomic)
        let userControlledMutedRuntime = try NativeRuntimeCore(config: runtime.config.replacing(
            wallpaperRoot: fixtureRoot,
            manifestURL: userControlledManifestURL,
            audioEnabled: false,
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        check(
            userControlledMutedRuntime.audioOutputEnabled == false
                && userControlledMutedRuntime.audioOutputSummary == "disabled-visual-player",
            "userControlled audio policy must remain disabled in the visual-only player",
            failures: &failures,
            checks: &checks
        )
        let userControlledEnabledRuntime = try NativeRuntimeCore(config: runtime.config.replacing(
            wallpaperRoot: fixtureRoot,
            manifestURL: userControlledManifestURL,
            audioEnabled: true,
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        check(
            userControlledEnabledRuntime.audioOutputEnabled == false
                && userControlledEnabledRuntime.audioCapabilityStatus == "muted"
                && userControlledEnabledRuntime.runtimeCapabilitiesSummary().contains("audio\tpolicy\tmuted\tpolicy=userControlled userOptIn=false output=disabled-visual-player"),
            "userControlled audio policy must stay disabled even when old settings request audio",
            failures: &failures,
            checks: &checks
        )
        let manifestMutedWithOptInRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            audioEnabled: true,
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        check(
            manifestMutedWithOptInRuntime.audioOutputEnabled == false
                && manifestMutedWithOptInRuntime.audioOutputSummary == "muted",
            "manifest muted audio policy must remain silent even if old settings request audio",
            failures: &failures,
            checks: &checks
        )
        check(
            eventOnlyRuntime.runtimeCapabilitiesSummary()
                .contains("spine\teventsAudioSequence\tsupported\tevents=ignored(non-visual) audio=none sequence=none payloads=float,int,string"),
            "capability diagnostics must mark non-visual Spine events and payload values as ignored instead of unsupported",
            failures: &failures,
            checks: &checks
        )
        let audioEventSpineJSON = eventOnlySpineJSON.replacingOccurrences(
            of: "\"marker\": { \"int\": 7, \"float\": 0.25, \"string\": \"rub-start\" }",
            with: "\"marker\": { \"int\": 7, \"float\": 0.25, \"string\": \"rub-start\", \"audio\": \"voice.wav\", \"volume\": 0.5, \"balance\": -0.25 }"
        )
        try Data(audioEventSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let audioEventCompatibility = RuntimeCapabilities.nativeSpineCompatibility(
            manifest: eventOnlyManifest,
            bundleRoot: fixtureRoot
        )
        check(
            audioEventCompatibility.isSupported,
            "Spine audio event timelines must not force composite fallback when visual native rendering is supported",
            failures: &failures,
            checks: &checks
        )
        let audioEventRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        check(
            audioEventRuntime.runtimeCapabilitiesSummary()
                .contains("spine\teventsAudioSequence\tsupported\tevents=ignored(non-visual) audio=ignored(non-visual) sequence=none payloads=audio,balance,float,int,string,volume"),
            "capability diagnostics must expose Spine audio events as ignored non-visual data",
            failures: &failures,
            checks: &checks
        )
        let playablePhysicsDegradation = NativeSpineDegradationReason.physicsSubsetRuntime(name: "hair")
        let nonPhysicsDegradation = NativeSpineDegradationReason(rawValue: "path/hair:subset-runtime")
        let malformedPhysicsDegradation = NativeSpineDegradationReason(rawValue: "physics/:subset-runtime")
        check(
            NativeSpinePlayability.isPlayable(
                status: "degraded",
                degradationReasons: [playablePhysicsDegradation]
            ),
            "native Spine playability must allow only typed physics subset degraded runtimes",
            failures: &failures,
            checks: &checks
        )
        check(
            NativeSpinePlayability.isPlayable(
                status: "degraded",
                degradationReasons: [playablePhysicsDegradation, nonPhysicsDegradation]
            ) == false,
            "native Spine playability must reject mixed degraded reasons even when one physics subset reason is present",
            failures: &failures,
            checks: &checks
        )
        check(
            NativeSpinePlayability.isPlayable(
                status: "degraded",
                degradationReasons: [malformedPhysicsDegradation]
            ) == false,
            "native Spine playability must reject malformed physics degraded reasons",
            failures: &failures,
            checks: &checks
        )
        let physicsConstraintSpineJSON = """
        {
          "skeleton": {
            "spine": "4.2.43"
          },
          "bones": [
            { "name": "root" },
            { "name": "hair", "parent": "root", "length": 80 }
          ],
          "slots": [
            { "name": "hair", "bone": "hair", "attachment": "ik-quad" }
          ],
          "physics": [
            {
              "name": "hair",
              "bone": "hair",
              "x": 5.0,
              "y": 5.0,
              "rotate": 0.8,
              "wind": 1000,
              "gravity": 1000,
              "limit": 100000,
              "inertia": 0.5,
              "strength": 100,
              "damping": 1
            }
          ],
          "skins": [
            {
              "name": "default",
              "attachments": {
                "hair": {
                  "ik-quad": {
                    "type": "region",
                    "path": "ik-quad",
                    "x": 80,
                    "y": 0,
                    "width": 16,
                    "height": 16
                  }
                }
              }
            }
          ],
          "events": {
            "tick": {}
          },
          "animations": {
            "idle": {
              "events": [
                { "time": 0.5, "name": "tick" }
              ]
            }
          }
        }
        """
        try Data(physicsConstraintSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let physicsCompatibility = RuntimeCapabilities.nativeSpineCompatibility(
            manifest: eventOnlyManifest,
            bundleRoot: fixtureRoot
        )
        check(
            physicsCompatibility.isSupported,
            "native physics constraints must not force composite fallback for otherwise supported native Spine bundles",
            failures: &failures,
            checks: &checks
        )
        let physicsRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        check(
            physicsRuntime.runtimeCapabilitiesSummary().contains("spine\tconstraints\tdegraded")
                && physicsRuntime.runtimeCapabilitiesSummary().contains("spine\tnativeCompatibilityGate\tdegraded")
                && physicsRuntime.runtimeCapabilitiesSummary().contains("used=physics")
                && physicsRuntime.runtimeCapabilitiesSummary().contains("physics/hair:subset-runtime")
                && physicsRuntime.runtimeCapabilitiesSummary().contains("runtime-disabled") == false,
            "capability diagnostics must report native Spine physics constraints as a degraded subset runtime, not full parity",
            failures: &failures,
            checks: &checks
        )
        let physicsSummary = try WallpaperBundleCatalog.requireValidBundle(fixtureRoot)
        check(
            physicsSummary.capabilities.nativeSpineStatus == "degraded"
                && physicsSummary.capabilities.nativeSpineSummary.contains("physics/hair:subset-runtime")
                && physicsSummary.capabilities.fallbackStatus == "not-needed",
            "bundle catalog must mark native Spine physics bundles degraded without forcing composite fallback",
            failures: &failures,
            checks: &checks
        )
        try physicsRuntime.requireNativeSpineGeometryIfSupported()
        let physicsGeometryPlan = try SpineGeometryDiagnostics.make(runtime: physicsRuntime)
        let physicsStartFingerprint = geometryFingerprint(
            in: physicsGeometryPlan,
            action: "idle",
            time: "0.000s"
        )
        let physicsMovingFingerprint = geometryFingerprint(
            in: physicsGeometryPlan,
            action: "idle",
            time: "0.500s"
        )
        check(
            physicsStartFingerprint != nil
                && physicsMovingFingerprint != nil
                && physicsStartFingerprint != physicsMovingFingerprint,
            "degraded Spine physics subset runtime must still produce visible native geometry changes",
            failures: &failures,
            checks: &checks
        )
        let noPhysicsConstraintSpineJSON = physicsConstraintSpineJSON.replacingOccurrences(
            of: """
              "physics": [
                {
                  "name": "hair",
                  "bone": "hair",
                  "x": 5.0,
                  "y": 5.0,
                  "rotate": 0.8,
                  "wind": 1000,
                  "gravity": 1000,
                  "limit": 100000,
                  "inertia": 0.5,
                  "strength": 100,
                  "damping": 1
                }
              ],
            """,
            with: """
              "physics": [],
            """
        )
        try Data(noPhysicsConstraintSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let noPhysicsRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let noPhysicsGeometryPlan = try SpineGeometryDiagnostics.make(runtime: noPhysicsRuntime)
        let noPhysicsStartFingerprint = geometryFingerprint(
            in: noPhysicsGeometryPlan,
            action: "idle",
            time: "0.000s"
        )
        let noPhysicsMovingFingerprint = geometryFingerprint(
            in: noPhysicsGeometryPlan,
            action: "idle",
            time: "0.500s"
        )
        check(
            noPhysicsStartFingerprint != nil
                && noPhysicsMovingFingerprint != nil
                && noPhysicsStartFingerprint == noPhysicsMovingFingerprint,
            "physics fixture geometry must remain static across the same event-only timeline when physics constraints are stripped",
            failures: &failures,
            checks: &checks
        )
        check(
            physicsStartFingerprint != nil
                && noPhysicsStartFingerprint != nil
                && physicsStartFingerprint == noPhysicsStartFingerprint,
            "physics and stripped-physics fixtures must share the same setup-pose geometry before physics integration diverges",
            failures: &failures,
            checks: &checks
        )
        check(
            physicsMovingFingerprint != nil
                && noPhysicsMovingFingerprint != nil
                && physicsMovingFingerprint != noPhysicsMovingFingerprint,
            "physics-enabled geometry must diverge from the stripped-physics event-only baseline at the same timestamp",
            failures: &failures,
            checks: &checks
        )
        let invalidPhysicsCases: [(json: String, expectedReason: String)] = [
            (
                """
                {
                  "skeleton": { "spine": "4.2.43" },
                  "bones": [
                    { "name": "root" },
                    { "name": "hair", "parent": "root" }
                  ],
                  "physics": [
                    { "bone": "hair" }
                  ],
                  "animations": { "idle": {} }
                }
                """,
                "physics/unnamed:missing-name-or-bone"
            ),
            (
                """
                {
                  "skeleton": { "spine": "4.2.43" },
                  "bones": [
                    { "name": "root" },
                    { "name": "hair", "parent": "root" }
                  ],
                  "physics": [
                    { "name": "ghost-hair", "bone": "ghost" }
                  ],
                  "animations": { "idle": {} }
                }
                """,
                "physics/ghost-hair:unknown-bone=ghost"
            ),
            (
                """
                {
                  "skeleton": { "spine": "4.2.43" },
                  "bones": [
                    { "name": "root" },
                    { "name": "hair", "parent": "root" }
                  ],
                  "physics": [
                    { "name": "hair", "bone": "hair" },
                    { "name": "ghost-hair", "bone": "ghost" }
                  ],
                  "animations": { "idle": {} }
                }
                """,
                "physics/ghost-hair:unknown-bone=ghost"
            ),
            (
                """
                {
                  "skeleton": { "spine": "4.2.43" },
                  "bones": [
                    { "name": "root" },
                    { "name": "hair", "parent": "root" }
                  ],
                  "physics": {
                    "name": "invalid-shape"
                  },
                  "animations": { "idle": {} }
                }
                """,
                "physics:invalid-shape"
            ),
            (
                """
                {
                  "skeleton": { "spine": "4.2.43" },
                  "bones": [
                    { "name": "root" },
                    { "name": "hair", "parent": "root" }
                  ],
                  "physics": [
                    { "name": "hair", "bone": "hair", "damping": "nan" }
                  ],
                  "animations": { "idle": {} }
                }
                """,
                "physics/hair:invalid-number=damping"
            ),
            (
                """
                {
                  "skeleton": { "spine": "4.2.43" },
                  "bones": [
                    { "name": "root" },
                    { "name": "hair", "parent": "root" }
                  ],
                  "physics": [
                    { "name": "hair", "bone": "hair", "damping": -0.5 }
                  ],
                  "animations": { "idle": {} }
                }
                """,
                "physics/hair:invalid-range=damping"
            )
        ]
        for invalidPhysicsCase in invalidPhysicsCases {
            try Data(invalidPhysicsCase.json.utf8).write(to: fixtureSpineJSON, options: .atomic)
            let invalidPhysicsCompatibility = RuntimeCapabilities.nativeSpineCompatibility(
                manifest: eventOnlyManifest,
                bundleRoot: fixtureRoot
            )
            check(
                invalidPhysicsCompatibility.isSupported == false
                    && invalidPhysicsCompatibility.reasonText.contains(invalidPhysicsCase.expectedReason),
                "invalid Spine physics constraints must fail native compatibility with a specific diagnostic: \(invalidPhysicsCase.expectedReason)",
                failures: &failures,
                checks: &checks
            )
        }
        let twoBoneIkSpineTemplate = """
        {
          "skeleton": {
            "spine": "4.2.43",
            "x": -10,
            "y": -10,
            "width": 160,
            "height": 120
          },
          "bones": [
            { "name": "root" },
            { "name": "target", "parent": "root", "x": 120, "y": 70 },
            { "name": "upper", "parent": "root", "length": 100 },
            { "name": "lower", "parent": "upper", "x": 100, "length": 80 }
          ],
          "slots": [
            { "name": "arm", "bone": "lower", "attachment": "ik-quad" }
          ],
          "ik": [
            {
              "name": "supported-two-bone-ik",
              "bones": ["upper", "lower"],
              "target": "target"__BEND_POSITIVE__
            }
          ],
          "skins": [
            {
              "name": "default",
              "attachments": {
                "arm": {
                  "ik-quad": {
                    "type": "region",
                    "path": "ik-quad",
                    "x": 40,
                    "y": 0,
                    "width": 16,
                    "height": 16
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
        let twoBoneIkSpineJSON = twoBoneIkSpineTemplate.replacingOccurrences(
            of: "__BEND_POSITIVE__",
            with: ""
        )
        try Data(twoBoneIkSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let twoBoneIkCompatibility = RuntimeCapabilities.nativeSpineCompatibility(
            manifest: eventOnlyManifest,
            bundleRoot: fixtureRoot
        )
        check(
            twoBoneIkCompatibility.isSupported,
            "2-bone Spine IK constraints must be native-supported by the compatibility gate",
            failures: &failures,
            checks: &checks
        )
        let twoBoneIkRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        try twoBoneIkRuntime.requireNativeSpineGeometryIfSupported()
        check(
            twoBoneIkRuntime.runtimeCapabilitiesSummary().contains("spine\tconstraints\tsupported")
                && twoBoneIkRuntime.runtimeCapabilitiesSummary().contains("used=ik")
                && twoBoneIkRuntime.runtimeCapabilitiesSummary().contains("supported-two-bone-ik:multi-bone") == false,
            "capability diagnostics must report 2-bone Spine IK as supported instead of unsupported multi-bone IK",
            failures: &failures,
            checks: &checks
        )
        let twoBoneIkGeometryRequired = SpineGeometryDiagnostics.validationStatus(runtime: twoBoneIkRuntime) == "required"
        var twoBoneIkPositiveFingerprint: String?
        if twoBoneIkGeometryRequired {
            let twoBoneIkGeometryPlan = try SpineGeometryDiagnostics.make(runtime: twoBoneIkRuntime)
            twoBoneIkPositiveFingerprint = geometryFingerprint(
                in: twoBoneIkGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
        }
        let twoBoneIkNegativeSpineJSON = twoBoneIkSpineTemplate.replacingOccurrences(
            of: "__BEND_POSITIVE__",
            with: ",\n              \"bendPositive\": false"
        )
        try Data(twoBoneIkNegativeSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let twoBoneIkNegativeRuntime = try NativeRuntimeCore(config: twoBoneIkRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        var twoBoneIkNegativeFingerprint: String?
        if twoBoneIkGeometryRequired {
            try twoBoneIkNegativeRuntime.requireNativeSpineGeometryIfSupported()
            let twoBoneIkNegativeGeometryPlan = try SpineGeometryDiagnostics.make(runtime: twoBoneIkNegativeRuntime)
            twoBoneIkNegativeFingerprint = geometryFingerprint(
                in: twoBoneIkNegativeGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
            check(
                twoBoneIkPositiveFingerprint != nil
                    && twoBoneIkNegativeFingerprint != nil
                    && twoBoneIkPositiveFingerprint != twoBoneIkNegativeFingerprint,
                "2-bone Spine IK bendPositive setup values must produce distinct native geometry",
                failures: &failures,
                checks: &checks
            )
        }
        let animatedTwoBoneIkSpineJSON = twoBoneIkSpineJSON.replacingOccurrences(
            of: """
          "animations": {
            "idle": {}
          }
        }
        """,
            with: """
          "animations": {
            "idle": {
              "ik": {
                "supported-two-bone-ik": {
                  "bendPositive": [
                    { "time": 0, "bendPositive": true },
                    { "time": 0.05, "bendPositive": false }
                  ]
                }
              }
            }
          }
        }
        """
        )
        try Data(animatedTwoBoneIkSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let animatedTwoBoneIkRuntime = try NativeRuntimeCore(config: twoBoneIkRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let animatedTwoBoneIkCompatibility = RuntimeCapabilities.nativeSpineCompatibility(
            runtime: animatedTwoBoneIkRuntime
        )
        check(
            animatedTwoBoneIkCompatibility.isSupported,
            "Spine IK bendPositive timelines must pass native compatibility gate",
            failures: &failures,
            checks: &checks
        )
        let animatedTwoBoneIkAnimationPlan = try SpineAnimationDiagnostics.make(
            runtime: animatedTwoBoneIkRuntime
        )
        check(
            animatedTwoBoneIkAnimationPlan.contains("unsupportedActionTimelines: none")
                && animatedTwoBoneIkAnimationPlan.contains("ik.bendPositive=1"),
            "Spine animation diagnostics must mark IK bendPositive timelines compatible and summarize them",
            failures: &failures,
            checks: &checks
        )
        if twoBoneIkGeometryRequired {
            try animatedTwoBoneIkRuntime.requireNativeSpineGeometryIfSupported()
            let animatedTwoBoneIkGeometryPlan = try SpineGeometryDiagnostics.make(runtime: animatedTwoBoneIkRuntime)
            let animatedTwoBoneIkStartFingerprint = geometryFingerprint(
                in: animatedTwoBoneIkGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
            let animatedTwoBoneIkFlippedFingerprint = geometryFingerprint(
                in: animatedTwoBoneIkGeometryPlan,
                action: "idle",
                time: "0.050s"
            )
            check(
                animatedTwoBoneIkStartFingerprint != nil
                    && animatedTwoBoneIkStartFingerprint == twoBoneIkPositiveFingerprint,
                "Spine IK bendPositive timelines must preserve setup geometry before the keyed flip",
                failures: &failures,
                checks: &checks
            )
            check(
                animatedTwoBoneIkFlippedFingerprint != nil
                    && animatedTwoBoneIkFlippedFingerprint == twoBoneIkNegativeFingerprint,
                "Spine IK bendPositive timelines must render the same geometry as equivalent false setup value",
                failures: &failures,
                checks: &checks
            )
        }
        let animatedSingleBoneIkStretchSpineJSON = """
        {
          "skeleton": {
            "spine": "4.2.43",
            "x": -10,
            "y": -10,
            "width": 160,
            "height": 80
          },
          "bones": [
            { "name": "root" },
            { "name": "target", "parent": "root", "x": 130, "y": 0 },
            { "name": "arm", "parent": "root", "length": 50 }
          ],
          "slots": [
            { "name": "arm", "bone": "arm", "attachment": "ik-quad" }
          ],
          "ik": [
            {
              "name": "supported-single-bone-ik",
              "bones": ["arm"],
              "target": "target",
              "mix": 1,
              "stretch": false
            }
          ],
          "skins": [
            {
              "name": "default",
              "attachments": {
                "arm": {
                  "ik-quad": {
                    "type": "region",
                    "path": "ik-quad",
                    "x": 50,
                    "y": 0,
                    "width": 16,
                    "height": 16
                  }
                }
              }
            }
          ],
          "animations": {
            "idle": {
              "ik": {
                "supported-single-bone-ik": {
                  "stretch": [
                    { "time": 0, "stretch": false },
                    { "time": 0.05, "stretch": true }
                  ]
                }
              }
            }
          }
        }
        """
        try Data(animatedSingleBoneIkStretchSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let animatedSingleBoneIkRuntime = try NativeRuntimeCore(config: twoBoneIkRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let animatedSingleBoneIkCompatibility = RuntimeCapabilities.nativeSpineCompatibility(
            runtime: animatedSingleBoneIkRuntime
        )
        check(
            animatedSingleBoneIkCompatibility.isSupported
                && animatedSingleBoneIkRuntime.runtimeCapabilitiesSummary().contains("ik.stretch"),
            "Spine IK stretch timelines must pass scanner compatibility instead of forcing composite fallback",
            failures: &failures,
            checks: &checks
        )
        let animatedSingleBoneIkAnimationPlan = try SpineAnimationDiagnostics.make(
            runtime: animatedSingleBoneIkRuntime
        )
        check(
            animatedSingleBoneIkAnimationPlan.contains("unsupportedActionTimelines: none")
                && animatedSingleBoneIkAnimationPlan.contains("ik.stretch=1"),
            "Spine animation diagnostics must mark IK stretch timelines compatible and summarize them",
            failures: &failures,
            checks: &checks
        )
        if twoBoneIkGeometryRequired {
            try animatedSingleBoneIkRuntime.requireNativeSpineGeometryIfSupported()
            let animatedSingleBoneIkGeometryPlan = try SpineGeometryDiagnostics.make(runtime: animatedSingleBoneIkRuntime)
            let stretchOffFingerprint = geometryFingerprint(
                in: animatedSingleBoneIkGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
            let stretchOnFingerprint = geometryFingerprint(
                in: animatedSingleBoneIkGeometryPlan,
                action: "idle",
                time: "0.050s"
            )
            check(
                stretchOffFingerprint != nil
                    && stretchOnFingerprint != nil
                    && stretchOffFingerprint != stretchOnFingerprint,
                "Spine IK stretch timelines must change native geometry when keyed on",
                failures: &failures,
                checks: &checks
            )
        }
        let animatedSingleBoneIkCompressSpineJSON = animatedSingleBoneIkStretchSpineJSON
            .replacingOccurrences(of: "\"x\": 130", with: "\"x\": 20")
            .replacingOccurrences(of: "\"stretch\": false", with: "\"compress\": false")
            .replacingOccurrences(of: "\"stretch\": [", with: "\"compress\": [")
            .replacingOccurrences(of: "\"stretch\": true", with: "\"compress\": true")
        try Data(animatedSingleBoneIkCompressSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let animatedSingleBoneCompressRuntime = try NativeRuntimeCore(config: twoBoneIkRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let animatedSingleBoneCompressAnimationPlan = try SpineAnimationDiagnostics.make(
            runtime: animatedSingleBoneCompressRuntime
        )
        check(
            RuntimeCapabilities.nativeSpineCompatibility(runtime: animatedSingleBoneCompressRuntime).isSupported
                && animatedSingleBoneCompressRuntime.runtimeCapabilitiesSummary().contains("ik.compress")
                && animatedSingleBoneCompressAnimationPlan.contains("unsupportedActionTimelines: none")
                && animatedSingleBoneCompressAnimationPlan.contains("ik.compress=1"),
            "Spine IK compress timelines must pass scanner and animation diagnostics",
            failures: &failures,
            checks: &checks
        )
        if twoBoneIkGeometryRequired {
            try animatedSingleBoneCompressRuntime.requireNativeSpineGeometryIfSupported()
            let animatedSingleBoneCompressGeometryPlan = try SpineGeometryDiagnostics.make(runtime: animatedSingleBoneCompressRuntime)
            let compressOffFingerprint = geometryFingerprint(
                in: animatedSingleBoneCompressGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
            let compressOnFingerprint = geometryFingerprint(
                in: animatedSingleBoneCompressGeometryPlan,
                action: "idle",
                time: "0.050s"
            )
            check(
                compressOffFingerprint != nil
                    && compressOnFingerprint != nil
                    && compressOffFingerprint != compressOnFingerprint,
                "Spine IK compress timelines must change native geometry when keyed on",
                failures: &failures,
                checks: &checks
            )
        }
        let localRelativeTransformTemplate = """
        {
          "skeleton": {
            "spine": "4.2.43",
            "x": -20,
            "y": -20,
            "width": 180,
            "height": 140
          },
          "bones": [
            { "name": "root" },
            { "name": "target", "parent": "root", "x": 64, "y": 32, "rotation": 15, "scaleX": 1.2, "scaleY": 0.9 },
            { "name": "localBone", "parent": "root", "x": 8, "y": 8 },
            { "name": "relativeBone", "parent": "root", "x": 24, "y": 12 }
          ],
          "slots": [
            { "name": "local-arm", "bone": "localBone", "attachment": "ik-quad" },
            { "name": "relative-arm", "bone": "relativeBone", "attachment": "ik-quad" }
          ],
        __TRANSFORM_CONSTRAINT_BLOCK__
          "skins": [
            {
              "name": "default",
              "attachments": {
                "local-arm": {
                  "ik-quad": {
                    "type": "region",
                    "path": "ik-quad",
                    "x": 24,
                    "y": 0,
                    "width": 16,
                    "height": 16
                  }
                },
                "relative-arm": {
                  "ik-quad": {
                    "type": "region",
                    "path": "ik-quad",
                    "x": 32,
                    "y": 0,
                    "width": 16,
                    "height": 16
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
        let legacyLocalRelativeTransformBlock = """
          "transform": [
            {
              "name": "supported-local-transform",
              "bones": ["localBone"],
              "target": "target",
              "local": true,
              "x": 8,
              "y": 4,
              "rotation": 10,
              "scaleX": 0.1,
              "scaleY": 0.1,
              "shearY": 4,
              "mixRotate": 0.75,
              "mixX": 0.5,
              "mixY": 0.5,
              "mixScaleX": 0.5,
              "mixScaleY": 0.5,
              "mixShearY": 0.5
            },
            {
              "name": "supported-relative-transform",
              "bones": ["relativeBone"],
              "target": "target",
              "relative": true,
              "x": 2,
              "y": 1,
              "rotation": 5,
              "shearY": 2,
              "mixRotate": 0.5,
              "mixX": 0.25,
              "mixY": 0.25,
              "mixShearY": 0.25
            }
          ],
        """
        let officialLocalRelativeTransformBlock = """
          "transform": [
            {
              "name": "supported-local-transform",
              "bones": ["localBone"],
              "target": "target",
              "local": true,
              "x": 8,
              "y": 4,
              "rotation": 10,
              "scaleX": 0.1,
              "scaleY": 0.1,
              "shearY": 4,
              "rotateMix": 0.75,
              "translateMix": 0.5,
              "scaleMix": 0.5,
              "shearMix": 0.5
            },
            {
              "name": "supported-relative-transform",
              "bones": ["relativeBone"],
              "target": "target",
              "relative": true,
              "x": 2,
              "y": 1,
              "rotation": 5,
              "shearY": 2,
              "rotateMix": 0.5,
              "translateMix": 0.25,
              "shearMix": 0.25
            }
          ],
        """
        let noTransformSpineJSON = localRelativeTransformTemplate.replacingOccurrences(
            of: "__TRANSFORM_CONSTRAINT_BLOCK__",
            with: ""
        )
        try Data(noTransformSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let noTransformRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let transformGeometryRequired = SpineGeometryDiagnostics.validationStatus(runtime: noTransformRuntime) == "required"
        let noTransformFingerprint: String?
        if transformGeometryRequired {
            try noTransformRuntime.requireNativeSpineGeometryIfSupported()
            let noTransformGeometryPlan = try SpineGeometryDiagnostics.make(runtime: noTransformRuntime)
            noTransformFingerprint = geometryFingerprint(in: noTransformGeometryPlan, action: "idle", time: "0.000s")
        } else {
            noTransformFingerprint = nil
        }

        let legacyLocalRelativeTransformSpineJSON = localRelativeTransformTemplate.replacingOccurrences(
            of: "__TRANSFORM_CONSTRAINT_BLOCK__",
            with: legacyLocalRelativeTransformBlock
        )
        try Data(legacyLocalRelativeTransformSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let legacyLocalRelativeTransformRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let legacyLocalRelativeTransformFingerprint: String?
        if transformGeometryRequired {
            try legacyLocalRelativeTransformRuntime.requireNativeSpineGeometryIfSupported()
            let legacyGeometryPlan = try SpineGeometryDiagnostics.make(runtime: legacyLocalRelativeTransformRuntime)
            legacyLocalRelativeTransformFingerprint = geometryFingerprint(in: legacyGeometryPlan, action: "idle", time: "0.000s")
        } else {
            legacyLocalRelativeTransformFingerprint = nil
        }

        let officialLocalRelativeTransformSpineJSON = localRelativeTransformTemplate.replacingOccurrences(
            of: "__TRANSFORM_CONSTRAINT_BLOCK__",
            with: officialLocalRelativeTransformBlock
        )
        try Data(officialLocalRelativeTransformSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let officialLocalRelativeTransformCompatibility = RuntimeCapabilities.nativeSpineCompatibility(
            manifest: eventOnlyManifest,
            bundleRoot: fixtureRoot
        )
        check(
            officialLocalRelativeTransformCompatibility.isSupported,
            "official Spine transform constraint mix aliases must be native-supported by the compatibility gate",
            failures: &failures,
            checks: &checks
        )
        let officialLocalRelativeTransformRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        try officialLocalRelativeTransformRuntime.requireNativeSpineGeometryIfSupported()
        check(
            officialLocalRelativeTransformRuntime.runtimeCapabilitiesSummary().contains("spine\tconstraints\tsupported")
                && officialLocalRelativeTransformRuntime.runtimeCapabilitiesSummary().contains("used=transform")
                && officialLocalRelativeTransformRuntime.runtimeCapabilitiesSummary().contains("transform/supported-local-transform:local") == false
                && officialLocalRelativeTransformRuntime.runtimeCapabilitiesSummary().contains("transform/supported-relative-transform:relative") == false,
            "capability diagnostics must report official Spine transform constraint mix aliases as renderer-supported",
            failures: &failures,
            checks: &checks
        )
        if transformGeometryRequired && SpineGeometryDiagnostics.validationStatus(runtime: officialLocalRelativeTransformRuntime) == "required" {
            let officialGeometryPlan = try SpineGeometryDiagnostics.make(runtime: officialLocalRelativeTransformRuntime)
            let officialLocalRelativeTransformFingerprint = geometryFingerprint(
                in: officialGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
            check(
                noTransformFingerprint != nil
                    && officialLocalRelativeTransformFingerprint != nil
                    && noTransformFingerprint != officialLocalRelativeTransformFingerprint,
                "official Spine transform constraint mix aliases must change native geometry instead of only changing diagnostics",
                failures: &failures,
                checks: &checks
            )
            check(
                legacyLocalRelativeTransformFingerprint != nil
                    && officialLocalRelativeTransformFingerprint != nil
                    && legacyLocalRelativeTransformFingerprint == officialLocalRelativeTransformFingerprint,
                "official Spine transform constraint mix aliases must render the same geometry as legacy runtime mix fields",
                failures: &failures,
                checks: &checks
            )
        }

        let boneTranslateAxisTemplate = """
        {
          "skeleton": {
            "spine": "4.2.43",
            "x": -20,
            "y": -20,
            "width": 120,
            "height": 80
          },
          "bones": [
            { "name": "root" },
            { "name": "axisBone", "parent": "root", "x": 8, "y": 8 },
            { "name": "shapeBone", "parent": "root", "x": 48, "y": 8 }
          ],
          "slots": [
            { "name": "axis-slot", "bone": "axisBone", "attachment": "ik-quad" },
            { "name": "shape-slot", "bone": "shapeBone", "attachment": "ik-quad" }
          ],
          "skins": [
            {
              "name": "default",
              "attachments": {
                "axis-slot": {
                  "ik-quad": {
                    "type": "region",
                    "path": "ik-quad",
                    "x": 24,
                    "y": 0,
                    "width": 16,
                    "height": 16
                  }
                },
                "shape-slot": {
                  "ik-quad": {
                    "type": "region",
                    "path": "ik-quad",
                    "x": 24,
                    "y": 0,
                    "width": 16,
                    "height": 16
                  }
                }
              }
            }
          ],
          "animations": {
            "idle": __ANIMATION_BLOCK__
          }
        }
        """
        let baseBoneTranslateAxisSpineJSON = boneTranslateAxisTemplate.replacingOccurrences(
            of: "__ANIMATION_BLOCK__",
            with: "{}"
        )
        try Data(baseBoneTranslateAxisSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let baseBoneTranslateAxisRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let boneTranslateAxisGeometryRequired = SpineGeometryDiagnostics.validationStatus(runtime: baseBoneTranslateAxisRuntime) == "required"
        var baseBoneTranslateAxisFingerprint: String?
        if boneTranslateAxisGeometryRequired {
            try baseBoneTranslateAxisRuntime.requireNativeSpineGeometryIfSupported()
            let baseBoneTranslateAxisGeometryPlan = try SpineGeometryDiagnostics.make(runtime: baseBoneTranslateAxisRuntime)
            baseBoneTranslateAxisFingerprint = geometryFingerprint(
                in: baseBoneTranslateAxisGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
        }

        let lowercaseBoneTranslateAxisBlock = """
        {
              "bones": {
                "axisBone": {
                  "translatex": [
                    { "time": 0, "value": 18 }
                  ],
                  "translatey": [
                    { "time": 0, "value": 12 }
                  ]
                }
              }
            }
        """
        let lowercaseBoneTranslateAxisSpineJSON = boneTranslateAxisTemplate.replacingOccurrences(
            of: "__ANIMATION_BLOCK__",
            with: lowercaseBoneTranslateAxisBlock
        )
        try Data(lowercaseBoneTranslateAxisSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let lowercaseBoneTranslateAxisRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        var lowercaseBoneTranslateAxisFingerprint: String?
        if boneTranslateAxisGeometryRequired {
            try lowercaseBoneTranslateAxisRuntime.requireNativeSpineGeometryIfSupported()
            let lowercaseBoneTranslateAxisGeometryPlan = try SpineGeometryDiagnostics.make(runtime: lowercaseBoneTranslateAxisRuntime)
            lowercaseBoneTranslateAxisFingerprint = geometryFingerprint(
                in: lowercaseBoneTranslateAxisGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
        }

        let camelCaseBoneTranslateAxisBlock = """
        {
              "bones": {
                "axisBone": {
                  "translateX": [
                    { "time": 0, "value": 18 }
                  ],
                  "translateY": [
                    { "time": 0, "value": 12 }
                  ]
                }
              }
            }
        """
        let camelCaseBoneTranslateAxisSpineJSON = boneTranslateAxisTemplate.replacingOccurrences(
            of: "__ANIMATION_BLOCK__",
            with: camelCaseBoneTranslateAxisBlock
        )
        try Data(camelCaseBoneTranslateAxisSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let camelCaseBoneTranslateAxisCompatibility = RuntimeCapabilities.nativeSpineCompatibility(
            manifest: eventOnlyManifest,
            bundleRoot: fixtureRoot
        )
        check(
            camelCaseBoneTranslateAxisCompatibility.isSupported,
            "Spine bone translateX/translateY timeline aliases must pass native compatibility gate",
            failures: &failures,
            checks: &checks
        )
        let camelCaseBoneTranslateAxisRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let camelCaseBoneTranslateAxisAnimationPlan = try SpineAnimationDiagnostics.make(
            runtime: camelCaseBoneTranslateAxisRuntime
        )
        check(
            camelCaseBoneTranslateAxisAnimationPlan.contains("unsupportedActionTimelines: none")
                && camelCaseBoneTranslateAxisAnimationPlan.contains("bone.translateX=1")
                && camelCaseBoneTranslateAxisAnimationPlan.contains("bone.translateY=1"),
            "Spine animation diagnostics must summarize bone translateX/translateY timeline aliases as compatible",
            failures: &failures,
            checks: &checks
        )
        if boneTranslateAxisGeometryRequired {
            try camelCaseBoneTranslateAxisRuntime.requireNativeSpineGeometryIfSupported()
            let camelCaseBoneTranslateAxisGeometryPlan = try SpineGeometryDiagnostics.make(runtime: camelCaseBoneTranslateAxisRuntime)
            let camelCaseBoneTranslateAxisFingerprint = geometryFingerprint(
                in: camelCaseBoneTranslateAxisGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
            check(
                baseBoneTranslateAxisFingerprint != nil
                    && camelCaseBoneTranslateAxisFingerprint != nil
                    && baseBoneTranslateAxisFingerprint != camelCaseBoneTranslateAxisFingerprint,
                "Spine bone translateX/translateY aliases must change native geometry instead of only changing diagnostics",
                failures: &failures,
                checks: &checks
            )
            check(
                lowercaseBoneTranslateAxisFingerprint != nil
                    && camelCaseBoneTranslateAxisFingerprint != nil
                    && lowercaseBoneTranslateAxisFingerprint == camelCaseBoneTranslateAxisFingerprint,
                "Spine bone translateX/translateY aliases must render the same geometry as lowercase translatex/translatey timelines",
                failures: &failures,
                checks: &checks
            )
        }

        let baseBoneScaleShearAxisSpineJSON = boneTranslateAxisTemplate.replacingOccurrences(
            of: "__ANIMATION_BLOCK__",
            with: "{}"
        )
        try Data(baseBoneScaleShearAxisSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let baseBoneScaleShearAxisRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let boneScaleShearAxisGeometryRequired = SpineGeometryDiagnostics.validationStatus(runtime: baseBoneScaleShearAxisRuntime) == "required"
        var baseBoneScaleShearAxisFingerprint: String?
        if boneScaleShearAxisGeometryRequired {
            try baseBoneScaleShearAxisRuntime.requireNativeSpineGeometryIfSupported()
            let baseBoneScaleShearAxisGeometryPlan = try SpineGeometryDiagnostics.make(runtime: baseBoneScaleShearAxisRuntime)
            baseBoneScaleShearAxisFingerprint = geometryFingerprint(
                in: baseBoneScaleShearAxisGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
        }

        let lowercaseBoneScaleShearAxisBlock = """
        {
              "bones": {
                "shapeBone": {
                  "scalex": [
                    { "time": 0, "value": 1.25 }
                  ],
                  "scaley": [
                    { "time": 0, "value": 0.75 }
                  ],
                  "shearx": [
                    { "time": 0, "value": 9 }
                  ],
                  "sheary": [
                    { "time": 0, "value": -6 }
                  ]
                }
              }
            }
        """
        let lowercaseBoneScaleShearAxisSpineJSON = boneTranslateAxisTemplate.replacingOccurrences(
            of: "__ANIMATION_BLOCK__",
            with: lowercaseBoneScaleShearAxisBlock
        )
        try Data(lowercaseBoneScaleShearAxisSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let lowercaseBoneScaleShearAxisRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        var lowercaseBoneScaleShearAxisFingerprint: String?
        if boneScaleShearAxisGeometryRequired {
            try lowercaseBoneScaleShearAxisRuntime.requireNativeSpineGeometryIfSupported()
            let lowercaseBoneScaleShearAxisGeometryPlan = try SpineGeometryDiagnostics.make(runtime: lowercaseBoneScaleShearAxisRuntime)
            lowercaseBoneScaleShearAxisFingerprint = geometryFingerprint(
                in: lowercaseBoneScaleShearAxisGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
        }

        let camelCaseBoneScaleShearAxisBlock = """
        {
              "bones": {
                "shapeBone": {
                  "scaleX": [
                    { "time": 0, "value": 1.25 }
                  ],
                  "scaleY": [
                    { "time": 0, "value": 0.75 }
                  ],
                  "shearX": [
                    { "time": 0, "value": 9 }
                  ],
                  "shearY": [
                    { "time": 0, "value": -6 }
                  ]
                }
              }
            }
        """
        let camelCaseBoneScaleShearAxisSpineJSON = boneTranslateAxisTemplate.replacingOccurrences(
            of: "__ANIMATION_BLOCK__",
            with: camelCaseBoneScaleShearAxisBlock
        )
        try Data(camelCaseBoneScaleShearAxisSpineJSON.utf8).write(to: fixtureSpineJSON, options: .atomic)
        let camelCaseBoneScaleShearAxisCompatibility = RuntimeCapabilities.nativeSpineCompatibility(
            manifest: eventOnlyManifest,
            bundleRoot: fixtureRoot
        )
        check(
            camelCaseBoneScaleShearAxisCompatibility.isSupported,
            "Spine bone scaleX/scaleY/shearX/shearY timeline aliases must pass native compatibility gate",
            failures: &failures,
            checks: &checks
        )
        let camelCaseBoneScaleShearAxisRuntime = try NativeRuntimeCore(config: eventOnlyRuntime.config.replacing(
            clearDuration: true,
            launchControlPanel: false,
            launchWallpaper: false
        ))
        let camelCaseBoneScaleShearAxisAnimationPlan = try SpineAnimationDiagnostics.make(
            runtime: camelCaseBoneScaleShearAxisRuntime
        )
        check(
            camelCaseBoneScaleShearAxisAnimationPlan.contains("unsupportedActionTimelines: none")
                && camelCaseBoneScaleShearAxisAnimationPlan.contains("bone.scaleX=1")
                && camelCaseBoneScaleShearAxisAnimationPlan.contains("bone.scaleY=1")
                && camelCaseBoneScaleShearAxisAnimationPlan.contains("bone.shearX=1")
                && camelCaseBoneScaleShearAxisAnimationPlan.contains("bone.shearY=1"),
            "Spine animation diagnostics must summarize bone scale/shear axis timeline aliases as compatible",
            failures: &failures,
            checks: &checks
        )
        if boneScaleShearAxisGeometryRequired {
            try camelCaseBoneScaleShearAxisRuntime.requireNativeSpineGeometryIfSupported()
            let camelCaseBoneScaleShearAxisGeometryPlan = try SpineGeometryDiagnostics.make(runtime: camelCaseBoneScaleShearAxisRuntime)
            let camelCaseBoneScaleShearAxisFingerprint = geometryFingerprint(
                in: camelCaseBoneScaleShearAxisGeometryPlan,
                action: "idle",
                time: "0.000s"
            )
            check(
                baseBoneScaleShearAxisFingerprint != nil
                    && camelCaseBoneScaleShearAxisFingerprint != nil
                    && baseBoneScaleShearAxisFingerprint != camelCaseBoneScaleShearAxisFingerprint,
                "Spine bone scale/shear axis aliases must change native geometry instead of only changing diagnostics",
                failures: &failures,
                checks: &checks
            )
            check(
                lowercaseBoneScaleShearAxisFingerprint != nil
                    && camelCaseBoneScaleShearAxisFingerprint != nil
                    && lowercaseBoneScaleShearAxisFingerprint == camelCaseBoneScaleShearAxisFingerprint,
                "Spine bone scale/shear axis aliases must render the same geometry as lowercase scalex/scaley/shearx/sheary timelines",
                failures: &failures,
                checks: &checks
            )
        }

        let spineJSON = """
        {
          "skeleton": {
            "spine": "4.2.43"
          },
          "bones": [
            { "name": "root" },
            { "name": "target", "parent": "root" },
            { "name": "mid", "parent": "root" },
            { "name": "child", "parent": "mid" }
          ],
          "slots": [
            {
              "name": "face",
              "bone": "root",
              "attachment": "animated-sequence",
              "blend": "hard-light",
              "dark": "222222ff"
            },
            {
              "name": "alternate-path-slot",
              "bone": "root",
              "attachment": "motion-path"
            }
          ],
          "ik": [
            {
              "name": "unsupported-multi-bone-ik",
              "bones": ["root", "mid", "child"],
              "target": "target"
            }
          ],
          "transform": [
            {
              "name": "unsupported-local-transform",
              "bones": ["child"],
              "target": "target",
              "local": true
            },
            {
              "name": "missing-transform-target",
              "bones": ["child"]
            }
          ],
          "path": [
            {
              "name": "missing-path-target",
              "bones": ["child"]
            },
            {
              "name": "non-path-target",
              "bones": ["child"],
              "target": "face"
            },
            {
              "name": "alternate-skin-path-target",
              "bones": ["child"],
              "target": "alternate-path-slot"
            }
          ],
          "skins": [
            {
              "name": "alternate",
              "attachments": {
                "alternate-path-slot": {
                  "motion-path": {
                    "type": "path",
                    "vertexCount": 4,
                    "vertices": [-25, 0, -10, 20, 10, 20, 25, 0],
                    "lengths": [60],
                    "closed": false
                  }
                }
              }
            },
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
                "assets/texture.png"
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
        check(compatibility.reasonText.contains("sequence(face/animated-sequence:missing-region-geometry-or-sequence-metadata)"), "compatibility gate must distinguish malformed standalone sequence attachments from renderable standalone sequence attachments", failures: &failures, checks: &checks)
        check(compatibility.reasonText.contains("unsupported constraint usages"), "compatibility gate must report unsupported constraint usages", failures: &failures, checks: &checks)
        check(compatibility.reasonText.contains("unsupported slot features") == false, "static Spine two-color tint must not force unsupported native compatibility", failures: &failures, checks: &checks)
        check(compatibility.reasonText.contains("unsupported blend modes"), "compatibility gate must report unsupported Spine blend modes", failures: &failures, checks: &checks)
        check(compatibility.reasonText.contains("audio event playback") == false, "audio event playback must not force composite fallback when native visual rendering is otherwise compatible", failures: &failures, checks: &checks)
        check(
            unsupportedRuntime.runtimeCapabilitiesSummary().contains("audio=ignored(non-visual)"),
            "capability diagnostics must report Spine audio events as ignored separately from visual compatibility",
            failures: &failures,
            checks: &checks
        )
        check(
            unsupportedRuntime.runtimeCapabilitiesSummary().contains("sequence=unsupported-attachment"),
            "capability diagnostics must distinguish unsupported sequence attachment types from tolerated sequence metadata",
            failures: &failures,
            checks: &checks
        )
        check(
            unsupportedRuntime.runtimeCapabilitiesSummary().contains("unsupported=sequence(face/animated-sequence:missing-region-geometry-or-sequence-metadata)"),
            "capability diagnostics must keep malformed standalone sequence attachment fallback separate from supported sequence metadata",
            failures: &failures,
            checks: &checks
        )
        check(
            unsupportedRuntime.runtimeCapabilitiesSummary().contains("spine\tconstraints\tunsupported")
                && unsupportedRuntime.runtimeCapabilitiesSummary().contains("ik/unsupported-multi-bone-ik:multi-bone")
                && unsupportedRuntime.runtimeCapabilitiesSummary().contains("transform/missing-transform-target:missing-target")
                && unsupportedRuntime.runtimeCapabilitiesSummary().contains("path/missing-path-target:missing-target-slot")
                && unsupportedRuntime.runtimeCapabilitiesSummary().contains("path/non-path-target:target-slot-without-path-attachment=face")
                && unsupportedRuntime.runtimeCapabilitiesSummary().contains("path/alternate-skin-path-target:target-slot-without-path-attachment=alternate-path-slot"),
            "capability diagnostics must expose unsupported native Spine constraint usages, missing constraint targets, non-path target slots, and path targets that only exist outside the selected skin",
            failures: &failures,
            checks: &checks
        )
        check(
            unsupportedRuntime.runtimeCapabilitiesSummary().contains("spine\tblendModes\tunsupported")
                && unsupportedRuntime.runtimeCapabilitiesSummary().contains("hard-light"),
            "capability diagnostics must expose unsupported native Spine blend modes",
            failures: &failures,
            checks: &checks
        )
        check(
            unsupportedRuntime.runtimeCapabilitiesSummary().contains("spine\tslotFeatures\tsupported")
                && unsupportedRuntime.runtimeCapabilitiesSummary().contains("slot/face:static-two-color-tint")
                && unsupportedRuntime.runtimeCapabilitiesSummary().contains("unsupported=none"),
            "capability diagnostics must report static Spine two-color tint as renderer-supported",
            failures: &failures,
            checks: &checks
        )
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
            unsupportedSummary.capabilities.nativeSpineSummary.contains("unsupported attachment types")
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

    private static func geometryFingerprint(in plan: String, action: String, time: String) -> String? {
        geometryColumn(in: plan, action: action, time: time, column: 9)
    }

    private static func geometryColumn(in plan: String, action: String, time: String, column: Int) -> String? {
        for line in plan.split(separator: "\n", omittingEmptySubsequences: false) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard column >= 0,
                  columns.count > column,
                  columns[0] == "geometry",
                  columns[1] == action,
                  columns[2] == time else {
                continue
            }
            return String(columns[column])
        }
        return nil
    }

    private static func assertGenericRuntimeSourceBoundary(
        projectRoot: URL?,
        discoveredBundles: [WallpaperBundleSummary],
        failures: inout [String],
        checks: inout Int
    ) throws {
        checks += 1
        guard let projectRoot else { return }

        let sourcesRoot = projectRoot.appendingPathComponent("apps/MacWallpaperEngine/Sources", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourcesRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let tokens = Set(discoveredBundles.flatMap { bundle -> [String] in
            [bundle.id, bundle.displayName].filter { $0.count >= 4 }
        })
        guard tokens.isEmpty == false else { return }

        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var violations: [String] = []
        for case let sourceURL as URL in enumerator {
            guard sourceURL.pathExtension == "swift" else { continue }
            guard sourceURL.lastPathComponent != "RuntimeSelfTest.swift" else { continue }
            guard (try sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }

            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for token in tokens.sorted() where source.contains(token) {
                let relativePath = sourceURL.path
                    .replacingOccurrences(of: projectRoot.path + "/", with: "")
                violations.append("\(relativePath):\(token)")
            }
        }

        guard violations.isEmpty else {
            failures.append(
                "generic runtime sources must not hard-code bundled wallpaper ids or titles: \(violations.prefix(6).joined(separator: ", "))"
            )
            return
        }
    }
}
