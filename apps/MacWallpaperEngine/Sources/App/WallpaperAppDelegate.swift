import AppKit

enum ControlPanelFailureStatusPolicy {
    static func lastErrorAfterNonDegradingSelectionFailure(
        previousRuntimeAvailable: Bool,
        previousLastError: String?,
        failureDescription: String
    ) -> String? {
        previousRuntimeAvailable ? previousLastError : failureDescription
    }
}

final class WallpaperAppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: NativeRuntimeCore?
    private var host: WallpaperHost?
    private var statusItem: NSStatusItem?
    private var controlPanel: ControlPanelWindowController?
    private var lastError: String?
    private let recoveryTracker = RendererRecoveryTracker()

    init(runtime: NativeRuntimeCore?, startupError: Error? = nil) {
        self.runtime = runtime
        self.lastError = startupError?.localizedDescription
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let runtime else {
            showControlPanel()
            return
        }

        do {
            try applyLaunchAtLoginSetting(runtime.config.launchAtLogin)
            if runtime.config.launchWallpaper {
                try startHost()
            }
            if runtime.config.launchControlPanel {
                showControlPanel()
            }

            if let duration = runtime.config.duration {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    NSApplication.shared.terminate(nil)
                }
            }
        } catch {
            fputs("Wallpaper host failed: \(error.localizedDescription)\n", stderr)
            lastError = error.localizedDescription
            if RuntimeLifecyclePolicy.shouldRecoverStartupFailureInControlPanel(
                launchControlPanel: runtime.config.launchControlPanel
            ) {
                showControlPanel()
            } else {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        host?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlPanel()
        return true
    }

    private func installStatusMenu() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "MWE"

        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "Open Control Panel",
            action: #selector(openControlPanelFromStatusMenu),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let startItem = NSMenuItem(
            title: "Start Wallpaper",
            action: #selector(startFromStatusMenu),
            keyEquivalent: ""
        )
        startItem.target = self
        menu.addItem(startItem)

        let stopItem = NSMenuItem(
            title: "Stop Wallpaper",
            action: #selector(stopFromStatusMenu),
            keyEquivalent: ""
        )
        stopItem.target = self
        menu.addItem(stopItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Mac Wallpaper Engine",
            action: #selector(quitFromStatusMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        self.statusItem = statusItem
    }

    private func startHost() throws {
        guard host == nil else { return }
        guard let runtime else {
            throw EngineError.invalidArgument("Select a valid wallpaper bundle before starting wallpaper.")
        }
        host = try makeStartedHost(for: runtime)
        lastError = nil
        controlPanel?.refresh()
    }

    private func makeStartedHost(for runtime: NativeRuntimeCore) throws -> WallpaperHost {
        let recoveryKey = rendererRecoveryKey(for: runtime)
        if let safeModeDecision = recoveryTracker.decisionBeforeStart(key: recoveryKey) {
            throw EngineError.renderer(safeModeDecision.message)
        }

        let newHost = try WallpaperHost(runtime: runtime)
        do {
            try newHost.start()
        } catch {
            newHost.stop()
            let recoveryDecision = recoveryTracker.recordFailure(key: recoveryKey)
            if recoveryDecision.shouldYieldToSystemWallpaper {
                throw EngineError.renderer(recoveryDecision.message)
            }
            throw error
        }
        recoveryTracker.recordSuccess(key: recoveryKey)
        return newHost
    }

    private func replaceRunningHost(with nextRuntime: NativeRuntimeCore) throws {
        let previousHost = host
        let nextHost = try makeStartedHost(for: nextRuntime)
        runtime = nextRuntime
        host = nextHost
        lastError = nil
        previousHost?.stop()
        controlPanel?.refresh()
    }

    private func stopHost() {
        host?.stop()
        host = nil
        controlPanel?.refresh()
    }

    private func persistSettings(for config: EngineConfig) {
        do {
            try RuntimeSettingsStore.save(config: config)
        } catch {
            fputs("Failed to save runtime settings: \(error.localizedDescription)\n", stderr)
        }
    }

    private func applyLaunchAtLoginSetting(_ enabled: Bool) throws {
        let status = LaunchAtLoginController.status()
        if enabled == false,
           status != .enabled,
           status != .requiresApproval {
            return
        }
        try LaunchAtLoginController.setEnabled(enabled)
    }

    private func restartHost(
        displayMode: DisplayMode,
        primaryDisplaySelector: String?,
        interactive: Bool,
        renderFps: Int,
        matchDisplayRefresh: Bool,
        playbackRate: Float,
        audioEnabled: Bool,
        launchAtLogin: Bool,
        fitMode: RenderFitMode,
        foregroundMode: ForegroundRenderMode,
        interactionDebugOverlay: Bool
    ) {
        guard let currentRuntime = runtime else {
            let error = EngineError.invalidArgument("Select a valid wallpaper bundle before applying settings.")
            lastError = error.localizedDescription
            showError(error)
            controlPanel?.refresh()
            return
        }

        let wasRunning = host != nil
        let previousLastError = lastError
        do {
            let nextConfig = currentRuntime.config.replacing(
                displayMode: displayMode,
                primaryDisplaySelector: primaryDisplaySelector,
                interactive: interactive,
                renderFps: renderFps,
                matchDisplayRefresh: matchDisplayRefresh,
                playbackRateOverride: playbackRate,
                audioEnabled: audioEnabled,
                fitMode: fitMode,
                foregroundMode: foregroundMode,
                interactionDebugOverlay: interactionDebugOverlay,
                startHidden: false,
                clearDuration: true,
                launchAtLogin: launchAtLogin
            )
            let nextRuntime = try NativeRuntimeCore(config: nextConfig)
            try applyLaunchAtLoginSetting(nextRuntime.config.launchAtLogin)
            if wasRunning {
                do {
                    try replaceRunningHost(with: nextRuntime)
                    persistSettings(for: nextRuntime.config)
                } catch let restartError {
                    runtime = currentRuntime
                    lastError = previousLastError
                    showError(EngineError.renderer(
                        "Updated settings failed to start, so the previous wallpaper kept running. "
                            + "Original failure: \(restartError.localizedDescription)"
                    ))
                }
            } else {
                runtime = nextRuntime
                lastError = nil
                persistSettings(for: nextRuntime.config)
            }
        } catch {
            runtime = currentRuntime
            lastError = previousLastError
            showError(error)
        }
        controlPanel?.refresh()
    }

    private func showControlPanel() {
        if controlPanel == nil {
            controlPanel = ControlPanelWindowController(delegate: self)
        }
        controlPanel?.showPanel()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Mac Wallpaper Engine"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func restoreNonDegradingSelectionFailure(
        _ error: Error,
        previousRuntime: NativeRuntimeCore?,
        previousLastError: String?
    ) {
        runtime = previousRuntime
        lastError = ControlPanelFailureStatusPolicy.lastErrorAfterNonDegradingSelectionFailure(
            previousRuntimeAvailable: previousRuntime != nil,
            previousLastError: previousLastError,
            failureDescription: error.localizedDescription
        )
        showError(error)
    }

    @objc private func openControlPanelFromStatusMenu() {
        showControlPanel()
    }

    @objc private func startFromStatusMenu() {
        controlPanelStart()
    }

    @objc private func stopFromStatusMenu() {
        controlPanelStop()
    }

    @objc private func quitFromStatusMenu() {
        NSApplication.shared.terminate(nil)
    }
}

extension WallpaperAppDelegate: ControlPanelDelegate {
    var controlPanelTelemetryText: String {
        runtime?.telemetry.summary() ?? "No runtime telemetry yet"
    }

    var controlPanelState: ControlPanelState {
        let libraryState = wallpaperBundleLibraryState()

        guard let runtime else {
            return ControlPanelState(
                isRunning: false,
                displayMode: RuntimeLifecyclePolicy.defaultDisplayModeForNewBundle,
                primaryDisplaySelector: nil,
                interactive: true,
                renderFps: 60,
                matchDisplayRefresh: false,
                playbackRate: 1.0,
                audioEnabled: false,
                audioControlEnabled: false,
                audioStatusText: "AUDIO MUTED / no wallpaper bundle selected",
                launchAtLogin: false,
                launchAtLoginControlEnabled: LaunchAtLoginController.status() != .unavailable,
                launchAtLoginStatusText: LaunchAtLoginController.controlPanelText(desiredEnabled: false),
                fitMode: .contain,
                foregroundMode: .automatic,
                interactionDebugOverlay: false,
                interactionStatusText: "INTERACTION OFF / no wallpaper bundle selected",
                canRequestInteractionPermission: false,
                wallpaperRoot: nil,
                wallpaperPath: "No wallpaper bundle selected",
                bundleInfoText: "No validated wallpaper bundle is selected.",
                bundlePreviewURL: nil,
                availableBundles: libraryState.bundles,
                displaySelectionOptions: DisplayPlanner.displaySelectionOptions(),
                bundleDiagnosticsText: libraryState.diagnosticsText,
                doctorText: "No doctor report until a wallpaper bundle is selected.",
                renderPlanText: "No render plan until a wallpaper bundle is selected.",
                telemetryText: "No runtime telemetry yet",
                statusText: lastError.map { "ERROR / \($0)" } ?? "NO BUNDLE SELECTED"
            )
        }

        let status: String
        if let lastError {
            status = "ERROR / \(lastError)"
        } else {
            status = host == nil ? "STOPPED" : "RUNNING"
        }
        let selectedBundle = currentBundleSummary(from: libraryState.bundles, currentRoot: runtime.config.wallpaperRoot)
        let interactionPermission = interactionPermissionStatus(for: runtime)
        if host != nil, interactionPermission.canRequestAccessibilityPermission == false {
            host?.refreshInteractionState()
        }
        let interactionStatusText = RuntimeLifecyclePolicy.interactionControlPanelText(
            permissionStatus: interactionPermission,
            isHostRunning: host != nil,
            monitorSnapshot: primaryInteractionSnapshot(for: runtime)
        )
        return ControlPanelState(
            isRunning: host != nil,
            displayMode: runtime.config.displayMode,
            primaryDisplaySelector: runtime.config.primaryDisplaySelector,
            interactive: runtime.config.interactive,
            renderFps: runtime.renderTargetFps,
            matchDisplayRefresh: runtime.config.matchDisplayRefresh,
            playbackRate: runtime.selectedPlaybackRate,
            audioEnabled: runtime.config.audioEnabled,
            audioControlEnabled: runtime.manifest.runtime.effectiveAudioPolicy == .userControlled,
            audioStatusText: audioStatusText(for: runtime),
            launchAtLogin: runtime.config.launchAtLogin,
            launchAtLoginControlEnabled: LaunchAtLoginController.status() != .unavailable,
            launchAtLoginStatusText: LaunchAtLoginController.controlPanelText(desiredEnabled: runtime.config.launchAtLogin),
            fitMode: runtime.config.fitMode,
            foregroundMode: runtime.config.foregroundMode,
            interactionDebugOverlay: runtime.config.interactionDebugOverlay,
            interactionStatusText: interactionStatusText,
            canRequestInteractionPermission: interactionPermission.canRequestAccessibilityPermission,
            wallpaperRoot: runtime.config.wallpaperRoot,
            wallpaperPath: runtime.config.wallpaperRoot.path,
            bundleInfoText: bundleInfoText(for: selectedBundle),
            bundlePreviewURL: selectedBundle?.previewURL,
            availableBundles: libraryState.bundles,
            displaySelectionOptions: DisplayPlanner.displaySelectionOptions(),
            bundleDiagnosticsText: libraryState.diagnosticsText,
            doctorText: RuntimeDoctorReport.controlPanelSummary(
                runtime: runtime,
                interactionStatus: interactionStatusText
            ),
            renderPlanText: DisplayPlanner.renderSummary(runtime: runtime),
            telemetryText: controlPanelTelemetryText,
            statusText: status
        )
    }

    func controlPanelStart() {
        do {
            try startHost()
        } catch {
            lastError = error.localizedDescription
            showError(error)
        }
        controlPanel?.refresh()
    }

    func controlPanelStop() {
        stopHost()
    }

    func controlPanelApply(
        displayMode: DisplayMode,
        primaryDisplaySelector: String?,
        interactive: Bool,
        renderFps: Int,
        matchDisplayRefresh: Bool,
        playbackRate: Float,
        audioEnabled: Bool,
        launchAtLogin: Bool,
        fitMode: RenderFitMode,
        foregroundMode: ForegroundRenderMode,
        interactionDebugOverlay: Bool
    ) {
        restartHost(
            displayMode: displayMode,
            primaryDisplaySelector: primaryDisplaySelector,
            interactive: interactive,
            renderFps: renderFps,
            matchDisplayRefresh: matchDisplayRefresh,
            playbackRate: playbackRate,
            audioEnabled: audioEnabled,
            launchAtLogin: launchAtLogin,
            fitMode: fitMode,
            foregroundMode: foregroundMode,
            interactionDebugOverlay: interactionDebugOverlay
        )
    }

    func controlPanelChooseWallpaperBundle(_ url: URL) {
        let oldRuntime = runtime
        let oldLastError = lastError
        let wasRunning = host != nil
        do {
            let selectedBundle = try WallpaperBundleCatalog.requireValidBundle(url)
            let nextConfig = makeConfigForSelectedBundle(
                bundleRoot: selectedBundle.root,
                manifestURL: selectedBundle.manifestURL
            )
            let nextRuntime = try NativeRuntimeCore(config: nextConfig)
            if wasRunning {
                guard let oldRuntime else {
                    throw EngineError.renderer("Internal state error: wallpaper host is running without a runtime.")
                }
                do {
                    try replaceRunningHost(with: nextRuntime)
                    persistSettings(for: nextRuntime.config)
                } catch let newBundleError {
                    runtime = oldRuntime
                    lastError = oldLastError
                    showError(EngineError.renderer(
                        "Selected bundle failed to start, so the previous wallpaper kept running. "
                            + "Selected bundle: \(nextRuntime.config.wallpaperRoot.path). "
                            + "Original failure: \(newBundleError.localizedDescription)"
                    ))
                }
            } else {
                runtime = nextRuntime
                lastError = nil
                persistSettings(for: nextRuntime.config)
            }
        } catch {
            restoreNonDegradingSelectionFailure(
                error,
                previousRuntime: oldRuntime,
                previousLastError: oldLastError
            )
        }
        controlPanel?.refresh()
    }

    func controlPanelImportWallpaperBundle(_ url: URL) {
        let oldRuntime = runtime
        let oldLastError = lastError
        do {
            let installedBundle = try WallpaperBundleInstaller.install(sourceRoot: url)
            controlPanelChooseWallpaperBundle(installedBundle.root)
        } catch {
            restoreNonDegradingSelectionFailure(
                error,
                previousRuntime: oldRuntime,
                previousLastError: oldLastError
            )
            controlPanel?.refresh()
        }
    }

    func controlPanelRequestInteractionPermission() {
        _ = DesktopInteractionGate.requestAccessibilityTrustPrompt()
        _ = DesktopInteractionGate.openAccessibilitySettings()
        host?.refreshInteractionState()
        for delay in RuntimeLifecyclePolicy.accessibilityPermissionRefreshDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.host?.refreshInteractionState()
                self?.controlPanel?.refresh()
            }
        }
        controlPanel?.refresh()
    }

    func controlPanelQuit() {
        NSApplication.shared.terminate(nil)
    }

    private func interactionPermissionStatus(for runtime: NativeRuntimeCore) -> DesktopInteractionPermissionStatus {
        let primaryRole = RenderDisplayRole(kind: .primary, policy: runtime.manifest.displayPolicy.primary)
        return RuntimeLifecyclePolicy.interactionPermissionStatus(
            runtimeInteractive: runtime.config.interactive,
            displayRole: primaryRole,
            interactionPolicy: effectiveInteractionPolicy(for: runtime),
            accessibilityTrusted: DesktopInteractionGate.hasAccessibilityTrust()
        )
    }

    private func effectiveInteractionPolicy(for runtime: NativeRuntimeCore) -> InteractionPolicy {
        runtime.manifest.interactionPolicy ?? InteractionPolicy(
            mode: runtime.config.interactive ? .desktopEmptyOnly : .disabled,
            blockApplicationWindows: true,
            blockDesktopItems: true,
            pointerSmoothing: nil,
            pointerSampleFps: nil,
            idleDeadZone: nil,
            directionSwitchMargin: nil,
            defaultClickTailSeconds: nil,
            releaseFadeSeconds: nil
        )
    }

    private func audioStatusText(for runtime: NativeRuntimeCore) -> String {
        switch runtime.manifest.runtime.effectiveAudioPolicy {
        case .muted:
            return "AUDIO MUTED / manifest policy=muted"
        case .disabled:
            return "AUDIO DISABLED / manifest policy=disabled"
        case .userControlled:
            return runtime.config.audioEnabled
                ? "AUDIO ENABLED / user opt-in"
                : "AUDIO MUTED / waiting for user opt-in"
        }
    }

    private func primaryInteractionSnapshot(for runtime: NativeRuntimeCore) -> InteractionMonitorTelemetrySnapshot? {
        runtime.telemetry.interactionSnapshot()
            .first { $0.roleName.hasPrefix("primary:") }?
            .snapshot
    }

    private func rendererRecoveryKey(for runtime: NativeRuntimeCore) -> RendererRecoveryKey {
        RendererRecoveryKey(
            wallpaperID: runtime.manifest.metadata?.id ?? runtime.config.wallpaperRoot.lastPathComponent,
            displayFingerprint: runtime.config.primaryDisplaySelector ?? "system-primary",
            rendererKind: runtime.config.foregroundMode.rawValue,
            failureClass: "host-start"
        )
    }

    private func makeConfigForSelectedBundle(bundleRoot: URL, manifestURL: URL) -> EngineConfig {
        if let runtime {
            return runtime.config.replacing(
                wallpaperRoot: bundleRoot,
                manifestURL: manifestURL,
                startHidden: false,
                clearDuration: true
            )
        }

        return EngineConfig(
            projectRoot: ProjectPaths.findCatalogProjectRoot() ?? bundleRoot.deletingLastPathComponent(),
            wallpaperRoot: bundleRoot,
            manifestURL: manifestURL,
            level: .desktop,
            displayMode: RuntimeLifecyclePolicy.defaultDisplayModeForNewBundle,
            primaryDisplaySelector: nil,
            duration: nil,
            renderFps: 60,
            matchDisplayRefresh: false,
            playbackRateOverride: 1.0,
            audioEnabled: false,
            fitMode: .contain,
            foregroundMode: .automatic,
            interactionDebugOverlay: false,
            validateOnly: false,
            displayPlanOnly: false,
            physicalDisplayPlanOnly: false,
            renderPlanOnly: false,
            physicalRenderPlanOnly: false,
            simulatedRenderPlanOnly: false,
            performancePlanOnly: false,
            runtimeCapabilitiesOnly: false,
            doctorReportOnly: false,
            interactionPlanOnly: false,
            interactionProbePoint: nil,
            interactionProbeButton: .left,
            spineAnimationPlanOnly: false,
            spineProfileOnly: false,
            spineSnapshotURL: nil,
            spineSnapshotAction: "idle",
            spineSnapshotTime: 0,
            spineSnapshotWidth: 1280,
            spineSnapshotHeight: 720,
            wallpaperSnapshotURL: nil,
            wallpaperSnapshotReferenceURL: nil,
            wallpaperGoldenCheckOnly: false,
            wallpaperGoldenURL: nil,
            compositeQualityPlanOnly: false,
            compositeExportURL: nil,
            compositeExportFps: nil,
            compositeExportDuration: nil,
            strictCompositeQuality: false,
            selfTestOnly: false,
            startHidden: false,
            interactive: true,
            launchControlPanel: true,
            launchWallpaper: true,
            launchAtLogin: false,
            videoEnabled: true,
            metalEnabled: true,
            plainWindowStyle: false
        )
    }

    private func wallpaperBundleLibraryState() -> (bundles: [WallpaperBundleSummary], diagnosticsText: String) {
        let projectRoot = runtime?.config.projectRoot ?? ProjectPaths.findCatalogProjectRoot()
        var diagnostics = WallpaperBundleCatalog.diagnoseDefaultBundles(projectRoot: projectRoot)

        if let currentRoot = runtime?.config.wallpaperRoot {
            let currentPath = currentRoot.standardizedFileURL.resolvingSymlinksInPath().path
            let isAlreadyListed = diagnostics.contains {
                $0.root.standardizedFileURL.resolvingSymlinksInPath().path == currentPath
            }
            if !isAlreadyListed {
                diagnostics.append(WallpaperBundleCatalog.diagnoseBundle(currentRoot))
            }
        }

        diagnostics.sort {
            let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return $0.root.path.localizedStandardCompare($1.root.path) == .orderedAscending
        }

        let bundles = diagnostics.compactMap(\.bundle)
        return (bundles, WallpaperBundleCatalog.controlPanelLibrarySummary(for: diagnostics))
    }

    private func currentBundleSummary(from bundles: [WallpaperBundleSummary], currentRoot: URL) -> WallpaperBundleSummary? {
        let currentPath = currentRoot.standardizedFileURL.resolvingSymlinksInPath().path
        if let listedBundle = bundles.first(where: {
            $0.root.standardizedFileURL.resolvingSymlinksInPath().path == currentPath
        }) {
            return listedBundle
        }

        return WallpaperBundleCatalog.validateBundle(currentRoot)
    }

    private func bundleInfoText(for bundle: WallpaperBundleSummary?) -> String {
        guard let bundle else {
            return "No validated wallpaper bundle is selected."
        }

        var fields = ["id: \(bundle.id)"]
        if let author = bundle.author {
            fields.append("author: \(author)")
        }
        if let version = bundle.version {
            fields.append("version: \(version)")
        }

        let metadataLine = fields.joined(separator: " / ")
        let capabilityLine = "capabilities: \(bundle.capabilities.briefText)"
        let qualityLine = bundle.capabilities.qualityWarnings.isEmpty
            ? nil
            : "quality warnings: \(bundle.capabilities.qualityWarnings.joined(separator: " / "))"
        let recommendationLine = bundle.capabilities.qualityRecommendations.isEmpty
            ? nil
            : "quality recommendations: \(bundle.capabilities.qualityRecommendations.joined(separator: " / "))"
        let lines = [metadataLine, capabilityLine] + [qualityLine, recommendationLine].compactMap { $0 }
        guard let description = bundle.description else {
            return lines.joined(separator: "\n")
        }
        return (lines + [description]).joined(separator: "\n")
    }
}
