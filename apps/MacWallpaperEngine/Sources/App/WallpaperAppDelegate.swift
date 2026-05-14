import AppKit

final class WallpaperAppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: NativeRuntimeCore
    private var host: WallpaperHost?
    private var statusItem: NSStatusItem?
    private var controlPanel: ControlPanelWindowController?
    private var lastError: String?

    init(runtime: NativeRuntimeCore) {
        self.runtime = runtime
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            NSApplication.shared.terminate(nil)
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

    private func restartHost(
        displayMode: DisplayMode,
        interactive: Bool,
        renderFps: Int,
        playbackRate: Float,
        fitMode: RenderFitMode,
        foregroundMode: ForegroundRenderMode
    ) {
        do {
            let wasRunning = host != nil
            stopHost()
            let nextConfig = runtime.config.replacing(
                displayMode: displayMode,
                interactive: interactive,
                renderFps: renderFps,
                playbackRateOverride: playbackRate,
                fitMode: fitMode,
                foregroundMode: foregroundMode,
                startHidden: false,
                duration: nil,
                launchControlPanel: true,
                launchWallpaper: true
            )
            runtime = try NativeRuntimeCore(config: nextConfig)
            if wasRunning {
                try startHost()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
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
    var controlPanelState: ControlPanelState {
        let status: String
        if let lastError {
            status = "ERROR / \(lastError)"
        } else {
            status = host == nil ? "STOPPED" : "RUNNING"
        }
        return ControlPanelState(
            isRunning: host != nil,
            displayMode: runtime.config.displayMode,
            interactive: runtime.config.interactive,
            renderFps: runtime.renderTargetFps,
            playbackRate: runtime.selectedPlaybackRate,
            fitMode: runtime.config.fitMode,
            foregroundMode: runtime.config.foregroundMode,
            wallpaperPath: runtime.config.wallpaperRoot.path,
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
        interactive: Bool,
        renderFps: Int,
        playbackRate: Float,
        fitMode: RenderFitMode,
        foregroundMode: ForegroundRenderMode
    ) {
        restartHost(
            displayMode: displayMode,
            interactive: interactive,
            renderFps: renderFps,
            playbackRate: playbackRate,
            fitMode: fitMode,
            foregroundMode: foregroundMode
        )
    }

    func controlPanelChooseWallpaperBundle(_ url: URL) {
        let oldRuntime = runtime
        let wasRunning = host != nil
        lastError = nil
        do {
            let bundleRoot = url.standardizedFileURL
            let nextConfig = runtime.config.replacing(
                wallpaperRoot: bundleRoot,
                manifestURL: bundleRoot.appendingPathComponent("wallpaper.native.json"),
                startHidden: false,
                duration: nil,
                launchControlPanel: true,
                launchWallpaper: true
            )
            let nextRuntime = try NativeRuntimeCore(config: nextConfig)
            stopHost()
            runtime = nextRuntime
            if wasRunning {
                do {
                    try startHost()
                } catch {
                    runtime = oldRuntime
                    if wasRunning {
                        do {
                            try startHost()
                        } catch {
                            lastError = "New bundle failed: \(nextRuntime.config.wallpaperRoot.path). Rollback also failed: \(error.localizedDescription)"
                            throw error
                        }
                    }
                    throw error
                }
            }
            lastError = nil
        } catch {
            if lastError == nil {
                lastError = error.localizedDescription
            }
            showError(error)
        }
        controlPanel?.refresh()
    }

    func controlPanelQuit() {
        NSApplication.shared.terminate(nil)
    }
}
