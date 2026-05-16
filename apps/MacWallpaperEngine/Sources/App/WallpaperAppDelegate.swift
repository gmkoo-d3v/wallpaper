import AppKit

final class WallpaperAppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: NativeRuntimeCore?
    private var host: WallpaperHost?
    private var statusItem: NSStatusItem?
    private var controlPanel: ControlPanelWindowController?
    private var lastError: String?

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
        let host = try WallpaperHost(runtime: runtime)
        try host.start()
        self.host = host
        lastError = nil
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

    private func restartHost(
        displayMode: DisplayMode,
        primaryDisplaySelector: String?,
        interactive: Bool,
        renderFps: Int,
        matchDisplayRefresh: Bool,
        playbackRate: Float,
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
        do {
            let nextConfig = currentRuntime.config.replacing(
                displayMode: displayMode,
                primaryDisplaySelector: primaryDisplaySelector,
                interactive: interactive,
                renderFps: renderFps,
                matchDisplayRefresh: matchDisplayRefresh,
                playbackRateOverride: playbackRate,
                fitMode: fitMode,
                foregroundMode: foregroundMode,
                interactionDebugOverlay: interactionDebugOverlay,
                startHidden: false,
                clearDuration: true
            )
            let nextRuntime = try NativeRuntimeCore(config: nextConfig)
            if wasRunning {
                stopHost()
                runtime = nextRuntime
                do {
                    try startHost()
                    lastError = nil
                    persistSettings(for: nextRuntime.config)
                } catch let restartError {
                    runtime = currentRuntime
                    do {
                        try startHost()
                        lastError = nil
                        showError(EngineError.renderer(
                            "Updated settings failed to start, so the previous wallpaper was restored. "
                                + "Original failure: \(restartError.localizedDescription)"
                        ))
                    } catch let rollbackError {
                        let message = "Updated settings failed to start: \(restartError.localizedDescription). "
                            + "Rollback also failed: \(rollbackError.localizedDescription)"
                        lastError = message
                        showError(EngineError.renderer(message))
                    }
                }
            } else {
                runtime = nextRuntime
                lastError = nil
                persistSettings(for: nextRuntime.config)
            }
        } catch {
            if wasRunning && host != nil {
                lastError = nil
            } else {
                lastError = error.localizedDescription
            }
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
                displayMode: .primaryAnimated,
                primaryDisplaySelector: nil,
                interactive: true,
                renderFps: 60,
                matchDisplayRefresh: false,
                playbackRate: 1.0,
                fitMode: .contain,
                foregroundMode: .automatic,
                interactionDebugOverlay: false,
                wallpaperRoot: nil,
                wallpaperPath: "No wallpaper bundle selected",
                bundleInfoText: "No validated wallpaper bundle is selected.",
                bundlePreviewURL: nil,
                availableBundles: libraryState.bundles,
                displaySelectionOptions: DisplayPlanner.displaySelectionOptions(),
                bundleDiagnosticsText: libraryState.diagnosticsText,
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
        return ControlPanelState(
            isRunning: host != nil,
            displayMode: runtime.config.displayMode,
            primaryDisplaySelector: runtime.config.primaryDisplaySelector,
            interactive: runtime.config.interactive,
            renderFps: runtime.renderTargetFps,
            matchDisplayRefresh: runtime.config.matchDisplayRefresh,
            playbackRate: runtime.selectedPlaybackRate,
            fitMode: runtime.config.fitMode,
            foregroundMode: runtime.config.foregroundMode,
            interactionDebugOverlay: runtime.config.interactionDebugOverlay,
            wallpaperRoot: runtime.config.wallpaperRoot,
            wallpaperPath: runtime.config.wallpaperRoot.path,
            bundleInfoText: bundleInfoText(for: selectedBundle),
            bundlePreviewURL: selectedBundle?.previewURL,
            availableBundles: libraryState.bundles,
            displaySelectionOptions: DisplayPlanner.displaySelectionOptions(),
            bundleDiagnosticsText: libraryState.diagnosticsText,
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
            fitMode: fitMode,
            foregroundMode: foregroundMode,
            interactionDebugOverlay: interactionDebugOverlay
        )
    }

    func controlPanelChooseWallpaperBundle(_ url: URL) {
        let oldRuntime = runtime
        let wasRunning = host != nil
        do {
            let bundleRoot = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: bundleRoot.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw EngineError.invalidArgument("Selected path is not a directory: \(bundleRoot.path)")
            }

            let manifestURL = bundleRoot.appendingPathComponent("wallpaper.native.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                throw EngineError.manifest("Selected folder does not contain wallpaper.native.json: \(bundleRoot.path)")
            }

            let nextConfig = makeConfigForSelectedBundle(bundleRoot: bundleRoot, manifestURL: manifestURL)
            let nextRuntime = try NativeRuntimeCore(config: nextConfig)
            if wasRunning {
                guard let oldRuntime else {
                    throw EngineError.renderer("Internal state error: wallpaper host is running without a runtime.")
                }
                stopHost()
                runtime = nextRuntime
                do {
                    try startHost()
                    lastError = nil
                    persistSettings(for: nextRuntime.config)
                } catch let newBundleError {
                    runtime = oldRuntime
                    do {
                        try startHost()
                        lastError = nil
                        showError(EngineError.renderer(
                            "Selected bundle failed to start, so the previous wallpaper was restored. "
                                + "Selected bundle: \(nextRuntime.config.wallpaperRoot.path). "
                                + "Original failure: \(newBundleError.localizedDescription)"
                        ))
                    } catch let rollbackError {
                        let message = "Selected bundle failed to start: \(newBundleError.localizedDescription). "
                            + "Rollback also failed: \(rollbackError.localizedDescription)"
                        lastError = message
                        showError(EngineError.renderer(message))
                    }
                }
            } else {
                runtime = nextRuntime
                lastError = nil
                persistSettings(for: nextRuntime.config)
            }
        } catch {
            if !wasRunning || host == nil {
                lastError = error.localizedDescription
            } else {
                lastError = nil
            }
            showError(error)
        }
        controlPanel?.refresh()
    }

    func controlPanelImportWallpaperBundle(_ url: URL) {
        do {
            let installedBundle = try WallpaperBundleInstaller.install(sourceRoot: url)
            controlPanelChooseWallpaperBundle(installedBundle.root)
        } catch {
            if host == nil {
                lastError = error.localizedDescription
            }
            showError(error)
            controlPanel?.refresh()
        }
    }

    func controlPanelQuit() {
        NSApplication.shared.terminate(nil)
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
            projectRoot: (try? ProjectPaths.findProjectRoot()) ?? bundleRoot.deletingLastPathComponent(),
            wallpaperRoot: bundleRoot,
            manifestURL: manifestURL,
            level: .desktop,
            displayMode: .primaryAnimated,
            primaryDisplaySelector: nil,
            duration: nil,
            renderFps: 60,
            matchDisplayRefresh: false,
            playbackRateOverride: 1.0,
            fitMode: .contain,
            foregroundMode: .automatic,
            interactionDebugOverlay: false,
            validateOnly: false,
            displayPlanOnly: false,
            renderPlanOnly: false,
            performancePlanOnly: false,
            runtimeCapabilitiesOnly: false,
            interactionPlanOnly: false,
            spineAnimationPlanOnly: false,
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
            strictCompositeQuality: false,
            selfTestOnly: false,
            startHidden: false,
            interactive: true,
            launchControlPanel: true,
            launchWallpaper: true,
            videoEnabled: true,
            metalEnabled: true,
            plainWindowStyle: false
        )
    }

    private func wallpaperBundleLibraryState() -> (bundles: [WallpaperBundleSummary], diagnosticsText: String) {
        let projectRoot = runtime?.config.projectRoot ?? (try? ProjectPaths.findProjectRoot())
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
        return (bundles, WallpaperBundleCatalog.invalidDiagnosticsSummary(for: diagnostics))
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
        let lines = [metadataLine, capabilityLine] + [qualityLine].compactMap { $0 }
        guard let description = bundle.description else {
            return lines.joined(separator: "\n")
        }
        return (lines + [description]).joined(separator: "\n")
    }
}
