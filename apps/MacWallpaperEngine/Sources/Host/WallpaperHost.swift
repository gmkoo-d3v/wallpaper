import AppKit

final class WallpaperHost: NSObject {
    private static let rendererWarmupBackgroundColor = NSColor(
        calibratedRed: 0.95,
        green: 0.95,
        blue: 0.965,
        alpha: 1.0
    )

    private let runtime: NativeRuntimeCore
    private var windows: [NSWindow] = []
    private var retiringWindows: [NSWindow] = []
    private var pendingDisplayRebuild: DispatchWorkItem?
    private var isRunning = false
    private var lastKnownScreenConfigurationSignature: String?
    private var accessibilityTrustRefreshTimer: Timer?

    init(runtime: NativeRuntimeCore) throws {
        self.runtime = runtime
        super.init()
    }

    func start() throws {
        guard isRunning == false else { return }
        try rebuildWindows()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshInteractionState()
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTrustRefreshTimer = timer
        isRunning = true
    }

    func stop() {
        isRunning = false
        accessibilityTrustRefreshTimer?.invalidate()
        accessibilityTrustRefreshTimer = nil
        pendingDisplayRebuild?.cancel()
        pendingDisplayRebuild = nil
        NotificationCenter.default.removeObserver(self)
        close(windows: windows)
        close(windows: retiringWindows)
        windows.removeAll()
        retiringWindows.removeAll()
    }

    func refreshInteractionState() {
        for window in windows {
            (window.contentView as? WallpaperMetalView)?.refreshInteractionState()
        }
    }

    func runRuntimeInteractionSmoke() {
        for window in windows {
            guard let metalView = window.contentView as? WallpaperMetalView else { continue }
            metalView.runRuntimeInteractionSmoke()
        }
    }

    func runRuntimeDisplayRebuildSmoke() {
        guard isRunning else { return }
        runtime.telemetry.recordDisplayLifecycle(
            event: "display-rebuild-smoke",
            status: "requested",
            detail: "synthetic screen-parameter rebuild requested by runtime smoke"
        )
        screenParametersChanged()
    }

    deinit {
        stop()
    }

    @objc private func screenParametersChanged() {
        guard isRunning else { return }
        pendingDisplayRebuild?.cancel()
        runtime.telemetry.recordDisplayLifecycle(
            event: "display-rebuild",
            status: "scheduled",
            detail: "screen parameters changed; debounce=\(RuntimeLifecyclePolicy.displayRebuildDebounceSeconds)s"
        )
        let work = DispatchWorkItem { [weak self] in
            self?.performDisplayRebuild()
        }
        pendingDisplayRebuild = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + RuntimeLifecyclePolicy.displayRebuildDebounceSeconds,
            execute: work
        )
    }

    private func performDisplayRebuild() {
        pendingDisplayRebuild = nil
        guard isRunning else { return }
        let currentSignature = Self.screenConfigurationSignature(NSScreen.screens)
        guard currentSignature != lastKnownScreenConfigurationSignature else {
            runtime.telemetry.recordDisplayLifecycle(
                event: "display-rebuild",
                status: "skipped",
                detail: "screen configuration unchanged; ignoring spurious screen-parameter notification (e.g. an unrelated window minimizing/restoring) to avoid an unnecessary window/renderer rebuild"
            )
            return
        }
        do {
            try rebuildWindows()
        } catch {
            runtime.telemetry.recordDisplayLifecycle(
                event: "display-rebuild",
                status: "failed",
                detail: error.localizedDescription
            )
            fputs("Display rebuild failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func screenConfigurationSignature(_ screens: [NSScreen]) -> String {
        screens.map { screen in
            let frame = screen.frame
            return "\(screen.displayID ?? 0):\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height)):\(screen.backingScaleFactor)"
        }.joined(separator: "|")
    }

    private func rebuildWindows() throws {
        let isInitialBuild = isRunning == false
        let replacementWindows = try makeReplacementWindows()
        try replaceWindows(with: replacementWindows, isInitialBuild: isInitialBuild)
        lastKnownScreenConfigurationSignature = Self.screenConfigurationSignature(NSScreen.screens)
    }

    private func makeReplacementWindows() throws -> [NSWindow] {
        var replacementWindows: [NSWindow] = []
        do {
            let screens = NSScreen.screens
            guard let primary = DisplayPlanner.primaryScreen(in: screens, runtime: runtime) else { return [] }

            for screen in screens {
                guard let role = DisplayPlanner.role(for: screen, primary: primary, runtime: runtime) else { continue }
                let window = try makeWindow(for: screen, role: role)
                replacementWindows.append(window)
            }
            return replacementWindows
        } catch {
            close(windows: replacementWindows)
            throw error
        }
    }

    private func replaceWindows(with replacementWindows: [NSWindow], isInitialBuild: Bool) throws {
        switch RuntimeLifecyclePolicy.displayRebuildCommitDecision(
            existingWindowCount: windows.count,
            replacementWindowCount: replacementWindows.count,
            isInitialBuild: isInitialBuild
        ) {
        case .commit:
            break
        case .rollback(let reason):
            close(windows: replacementWindows)
            runtime.telemetry.recordDisplayLifecycle(
                event: isInitialBuild ? "initial-build" : "display-rebuild",
                status: "rollback",
                detail: reason
            )
            throw EngineError.renderer(reason)
        }

        let oldWindows = windows
        windows = replacementWindows
        let shouldRevealAfterFirstDraw = oldWindows.isEmpty == false
        show(windows: replacementWindows, initiallyTransparent: shouldRevealAfterFirstDraw)
        if shouldRevealAfterFirstDraw {
            revealReplacementWindowsWhenReady(
                replacementWindows,
                thenRetire: oldWindows,
                startedAt: CACurrentMediaTime()
            )
        } else {
            retire(windows: oldWindows)
        }
        runtime.telemetry.recordDisplayLifecycle(
            event: isInitialBuild ? "initial-build" : "display-rebuild",
            status: "committed",
            detail: "windows=\(replacementWindows.count) retired=\(oldWindows.count)"
        )
        if isInitialBuild == false, runtime.config.runtimeInteractionSmoke {
            scheduleInteractionSmokeAfterDisplayRebuild()
        }
    }

    private func scheduleInteractionSmokeAfterDisplayRebuild() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.isRunning else { return }
            self.runRuntimeInteractionSmoke()
        }
    }

    private func close(windows targetWindows: [NSWindow]) {
        for window in targetWindows {
            window.orderOut(nil)
            window.close()
        }
    }

    private func retire(windows targetWindows: [NSWindow]) {
        guard targetWindows.isEmpty == false else { return }
        retiringWindows.append(contentsOf: targetWindows)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + RuntimeLifecyclePolicy.displayReplacementOverlapSeconds
        ) { [weak self] in
            self?.close(windows: targetWindows)
            self?.retiringWindows.removeAll { retiringWindow in
                targetWindows.contains { $0 === retiringWindow }
            }
        }
    }

    private func revealReplacementWindowsWhenReady(
        _ replacementWindows: [NSWindow],
        thenRetire oldWindows: [NSWindow],
        startedAt: CFTimeInterval
    ) {
        if replacementWindowsReady(replacementWindows)
            || CACurrentMediaTime() - startedAt >= RuntimeLifecyclePolicy.displayReplacementRevealTimeoutSeconds {
            for window in replacementWindows {
                window.alphaValue = 1
            }
            retire(windows: oldWindows)
            return
        }

        for window in replacementWindows {
            (window.contentView as? WallpaperMetalView)?.warmUpVisibleFrame()
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + RuntimeLifecyclePolicy.visibleWindowWarmupRetryInterval
        ) { [weak self] in
            self?.revealReplacementWindowsWhenReady(
                replacementWindows,
                thenRetire: oldWindows,
                startedAt: startedAt
            )
        }
    }

    private func replacementWindowsReady(_ targetWindows: [NSWindow]) -> Bool {
        targetWindows.allSatisfy { window in
            guard let metalView = window.contentView as? WallpaperMetalView else {
                return true
            }
            return metalView.hasSubmittedVisibleFrame()
        }
    }

    private func show(windows targetWindows: [NSWindow], initiallyTransparent: Bool = false) {
        for window in targetWindows {
            let warmupMoments = RuntimeLifecyclePolicy.windowWarmupMoments(startHidden: runtime.config.startHidden)
            let metalView = window.contentView as? WallpaperMetalView
            window.alphaValue = initiallyTransparent ? 0 : 1
            if warmupMoments.contains(.beforeOrderFront) {
                metalView?.warmUpVisibleFrame()
            }
            if runtime.config.startHidden {
                window.orderOut(nil)
            } else if runtime.config.plainWindowStyle {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
            if warmupMoments.contains(.afterOrderFront) {
                metalView?.warmUpVisibleFrame()
            }
        }
    }

    private func makeWindow(for screen: NSScreen, role: RenderDisplayRole) throws -> NSWindow {
        do {
            let view: NSView = if runtime.config.metalEnabled {
                try WallpaperMetalView(
                    runtime: runtime,
                    displayRole: role,
                    displayName: screen.localizedName,
                    displayRefreshFps: screen.maximumFramesPerSecond
                )
            } else {
                PlainWallpaperView()
            }
            view.frame = CGRect(origin: .zero, size: screen.frame.size)
            view.autoresizingMask = [.width, .height]

            let styleMask: NSWindow.StyleMask = runtime.config.plainWindowStyle
                ? [.titled, .closable, .miniaturizable, .resizable]
                : [.borderless]

            let contentRect = runtime.config.plainWindowStyle
                ? CGRect(x: screen.frame.midX - 400, y: screen.frame.midY - 225, width: 800, height: 450)
                : screen.frame

            let window: NSWindow
            if runtime.config.plainWindowStyle {
                window = NSWindow(
                    contentRect: contentRect,
                    styleMask: styleMask,
                    backing: .buffered,
                    defer: false
                )
            } else {
                window = NSWindow(
                    contentRect: contentRect,
                    styleMask: styleMask,
                    backing: .buffered,
                    defer: false,
                    screen: screen
                )
            }
            window.title = "Mac Wallpaper Engine Diagnostic"
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.frame = window.contentView?.bounds ?? CGRect(origin: .zero, size: contentRect.size)
            window.level = runtime.config.plainWindowStyle ? .normal : runtime.config.level.windowLevel
            window.backgroundColor = Self.rendererWarmupBackgroundColor
            window.isOpaque = true
            window.hasShadow = runtime.config.plainWindowStyle
            window.animationBehavior = .none
            window.ignoresMouseEvents = Self.shouldIgnoreMouseEvents(runtime: runtime, role: role)
            if runtime.config.plainWindowStyle == false {
                window.collectionBehavior = [
                    .canJoinAllSpaces,
                    .stationary,
                    .ignoresCycle,
                    .fullScreenAuxiliary
                ]
            }
            if runtime.config.plainWindowStyle == false {
                window.setFrame(screen.frame, display: true)
                view.frame = window.contentView?.bounds ?? CGRect(origin: .zero, size: screen.frame.size)
            }

            return window
        } catch {
            throw EngineError.renderer("display \(screen.localizedName) renderer failed: \(error.localizedDescription)")
        }
    }

    static func shouldIgnoreMouseEvents(runtime: NativeRuntimeCore, role: RenderDisplayRole) -> Bool {
        guard runtime.config.plainWindowStyle == false else { return false }
        let manifestInteractionPolicy = runtime.manifest.interactionPolicy ?? InteractionPolicy(
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
        let declarativePlan = DeclarativeBindingPlan(manifest: runtime.manifest)
        let hasDeclaredInteractions = runtime.manifest.interactions.isEmpty == false
            || declarativePlan.hasPointerInputBindings
        let acceptsLocalMouseEvents = RuntimeLifecyclePolicy.shouldAcceptLocalWallpaperMouseEvents(
            runtimeInteractive: runtime.config.interactive,
            displayRole: role,
            interactionPolicy: manifestInteractionPolicy,
            plainWindowStyle: runtime.config.plainWindowStyle,
            captureDesktopInput: runtime.config.captureDesktopInput,
            hasDeclaredInteractions: hasDeclaredInteractions
        )
        return acceptsLocalMouseEvents == false
    }

}

enum DisplayPlanner {
    static let rebuildPolicy = RuntimeLifecyclePolicy.displayRebuildPolicy

    static func displaySelectionOptions() -> [DisplaySelectionOption] {
        var options = [
            DisplaySelectionOption(title: "System Default Primary", selector: nil)
        ]

        for display in currentDisplaySnapshots() {
            let descriptor = displayDescriptor(for: display)
            let selector = descriptor.displayID.map { "displayID:\($0)" } ?? "fingerprint:\(descriptor.fingerprint)"
            options.append(DisplaySelectionOption(
                title: "\(display.name) / \(descriptor.shortSummary)",
                selector: selector
            ))
        }

        return options
    }

    static func primaryScreen(in screens: [NSScreen], runtime: NativeRuntimeCore) -> NSScreen? {
        guard let first = screens.first else { return nil }
        guard let selector = runtime.config.primaryDisplaySelector?.trimmingCharacters(in: .whitespacesAndNewlines),
              selector.isEmpty == false else {
            return first
        }
        return screens.first { primarySelectorMatches(selector, descriptor: displayDescriptor(for: $0)) } ?? first
    }

    static func primarySelectorMatches(_ selector: String, descriptor: DisplayIdentityDescriptor) -> Bool {
        let normalized = selector.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.isEmpty == false else { return false }

        let displayID = descriptor.displayID.map(String.init)
        let candidatePairs: [(prefix: String, value: String?)] = [
            ("displayid:", displayID),
            ("id:", displayID),
            ("fingerprint:", descriptor.fingerprint),
            ("arrangement:", descriptor.arrangement),
            ("name:", descriptor.name.lowercased())
        ]

        for pair in candidatePairs where normalized.hasPrefix(pair.prefix) {
            let value = String(normalized.dropFirst(pair.prefix.count))
            return pair.value?.lowercased() == value
        }

        return displayID == normalized
            || descriptor.fingerprint.lowercased() == normalized
            || descriptor.arrangement.lowercased() == normalized
            || descriptor.name.lowercased() == normalized
    }

    static func role(for screen: NSScreen, primary: NSScreen, runtime: NativeRuntimeCore) -> RenderDisplayRole? {
        role(isPrimary: screen === primary, displayMode: runtime.config.displayMode, manifest: runtime.manifest)
    }

    static func role(
        isPrimary: Bool,
        displayMode: DisplayMode,
        manifest: WallpaperNativeManifest
    ) -> RenderDisplayRole? {
        if isPrimary {
            let role = RenderDisplayRole(kind: .primary, policy: manifest.displayPolicy.primary)
            return role.isRenderable ? role : nil
        }

        let policy: DisplayRolePolicy
        switch displayMode {
        case .all:
            policy = .full
        case .primaryAnimated:
            policy = manifest.displayPolicy.secondary
        case .primaryOnly:
            return nil
        }
        let role = RenderDisplayRole(kind: .secondary, policy: policy)
        return role.isRenderable ? role : nil
    }

    static func summary(runtime: NativeRuntimeCore) -> String {
        let displays = currentDisplaySnapshots()
        guard let primary = primaryDisplay(in: displays, runtime: runtime) else {
            return "display plan: no screens detected"
        }

        let lines = displays.enumerated().map { index, display in
            let role = role(for: display, primary: primary, runtime: runtime)
            let roleName = role.map { "\($0.kind.label):\($0.policy.rawValue)" } ?? "none"
            let foreground = role?.rendersForeground == true ? "foreground" : "no-foreground"
            let video = role?.playsVideo == true ? "video" : "static"
            let interaction = role?.allowsInteraction == true ? "interactive" : "passive"
            let fps = plannedFps(runtime: runtime, role: role, displayRefreshFps: display.maximumFramesPerSecond)
            return "#\(index) \(display.name)\t\(displayGeometry(display))\t\(displayIdentity(display))\t\(roleName)\t\(foreground)\t\(video)\t\(interaction)\t\(fps)"
        }

        return """
        display plan OK
        displayProbe: physical(coregraphics)
        displayCount: \(displays.count)
        displayMode: \(runtime.config.displayMode.cliName)
        primarySelection: \(primarySelectionSummary(primary: primary, runtime: runtime))
        rebuildPolicy: \(rebuildPolicy)
        manifest primary: \(runtime.manifest.displayPolicy.primary.rawValue)
        manifest secondary: \(runtime.manifest.displayPolicy.secondary.rawValue)
        occluded: \(runtime.manifest.displayPolicy.occluded.rawValue)
        fullscreenObscured: \(runtime.manifest.displayPolicy.fullscreenObscured.rawValue)
        \(lines.joined(separator: "\n"))
        """
    }

    static func headlessSummary(runtime: NativeRuntimeCore) -> String {
        let display = diagnosticDisplaySnapshot()
        let role = role(for: display, primary: display, runtime: runtime)
        let roleName = role.map { "\($0.kind.label):\($0.policy.rawValue)" } ?? "none"
        let foreground = role?.rendersForeground == true ? "foreground" : "no-foreground"
        let video = role?.playsVideo == true ? "video" : "static"
        let interaction = role?.allowsInteraction == true ? "interactive" : "passive"
        let fps = plannedFps(runtime: runtime, role: role, displayRefreshFps: display.maximumFramesPerSecond)
        let line = "#0 \(display.name)\t\(displayGeometry(display))\t\(displayIdentity(display))\t\(roleName)\t\(foreground)\t\(video)\t\(interaction)\t\(fps)"

        return """
        display plan OK
        displayProbe: skipped(cli-safe)
        displayMode: \(runtime.config.displayMode.cliName)
        primarySelection: \(primarySelectionSummary(primary: display, runtime: runtime))
        rebuildPolicy: \(rebuildPolicy)
        manifest primary: \(runtime.manifest.displayPolicy.primary.rawValue)
        manifest secondary: \(runtime.manifest.displayPolicy.secondary.rawValue)
        occluded: \(runtime.manifest.displayPolicy.occluded.rawValue)
        fullscreenObscured: \(runtime.manifest.displayPolicy.fullscreenObscured.rawValue)
        \(line)
        """
    }

    static func renderSummary(runtime: NativeRuntimeCore, displayMode: DisplayMode? = nil) -> String {
        let displays = currentDisplaySnapshots()
        guard let primary = primaryDisplay(in: displays, runtime: runtime) else {
            return "render plan: no screens detected"
        }

        let effectiveDisplayMode = displayMode ?? runtime.config.displayMode
        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        let lines = displays.enumerated().map { index, display in
            let role = role(
                isPrimary: display.displayID == primary.displayID,
                displayMode: effectiveDisplayMode,
                manifest: runtime.manifest
            )
            let roleName = role.map { "\($0.kind.label):\($0.policy.rawValue)" } ?? "none"
            let path = role.map {
                renderPathSummary(runtime: runtime, role: $0, displayRefreshFps: display.maximumFramesPerSecond)
            } ?? "background=none\tforeground=none\tfallback=none\tinteraction=passive\t\(plannedFps(runtime: runtime, role: nil, displayRefreshFps: display.maximumFramesPerSecond))"
            return "#\(index) \(display.name)\t\(displayGeometry(display))\t\(displayIdentity(display))\t\(roleName)\t\(path)"
        }

        return """
        render plan OK
        displayProbe: physical(coregraphics)
        displayCount: \(displays.count)
        foregroundMode: \(runtime.config.foregroundMode.rawValue)
        displayMode: \(effectiveDisplayMode.cliName)
        primarySelection: \(primarySelectionSummary(primary: primary, runtime: runtime))
        nativeCompatibility: \(compatibility.statusText) \(compatibility.detailText)
        \(lines.joined(separator: "\n"))
        """
    }

    static func headlessRenderSummary(runtime: NativeRuntimeCore) -> String {
        let display = diagnosticDisplaySnapshot()
        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        let role = role(for: display, primary: display, runtime: runtime)
        let roleName = role.map { "\($0.kind.label):\($0.policy.rawValue)" } ?? "none"
        let path = role.map {
            renderPathSummary(runtime: runtime, role: $0, displayRefreshFps: display.maximumFramesPerSecond)
        } ?? "background=none\tforeground=none\tfallback=none\tinteraction=passive\t\(plannedFps(runtime: runtime, role: nil, displayRefreshFps: display.maximumFramesPerSecond))"
        let line = "#0 \(display.name)\t\(displayGeometry(display))\t\(displayIdentity(display))\t\(roleName)\t\(path)"

        return """
        render plan OK
        displayProbe: skipped(cli-safe)
        foregroundMode: \(runtime.config.foregroundMode.rawValue)
        displayMode: \(runtime.config.displayMode.cliName)
        primarySelection: \(primarySelectionSummary(primary: display, runtime: runtime))
        nativeCompatibility: \(compatibility.statusText) \(compatibility.detailText)
        \(line)
        """
    }

    static func simulatedMultiDisplayRenderSummary(
        runtime: NativeRuntimeCore,
        displayMode: DisplayMode? = nil
    ) -> String {
        let displays = simulatedMultiDisplaySnapshots()
        guard let primary = primaryDisplay(in: displays, runtime: runtime) else {
            return "render plan: no simulated screens detected"
        }

        let effectiveDisplayMode = displayMode ?? runtime.config.displayMode
        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        let lines = displays.enumerated().map { index, display in
            let role = role(
                isPrimary: display.displayID == primary.displayID,
                displayMode: effectiveDisplayMode,
                manifest: runtime.manifest
            )
            let roleName = role.map { "\($0.kind.label):\($0.policy.rawValue)" } ?? "none"
            let path = role.map {
                renderPathSummary(runtime: runtime, role: $0, displayRefreshFps: display.maximumFramesPerSecond)
            } ?? "background=none\tforeground=none\tfallback=none\tinteraction=passive\t\(plannedFps(runtime: runtime, role: nil, displayRefreshFps: display.maximumFramesPerSecond))"
            return "#\(index) \(display.name)\t\(displayGeometry(display))\t\(displayIdentity(display))\t\(roleName)\t\(path)"
        }

        return """
        render plan OK
        displayProbe: simulated(cli-safe)
        foregroundMode: \(runtime.config.foregroundMode.rawValue)
        displayMode: \(effectiveDisplayMode.cliName)
        primarySelection: \(primarySelectionSummary(primary: primary, runtime: runtime))
        nativeCompatibility: \(compatibility.statusText) \(compatibility.detailText)
        \(lines.joined(separator: "\n"))
        """
    }

    static func renderPathSummary(
        runtime: NativeRuntimeCore,
        role: RenderDisplayRole,
        displayRefreshFps: Int? = nil
    ) -> String {
        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        let foregroundPlan = ForegroundRenderPlan.make(
            runtime: runtime,
            role: role,
            compatibility: compatibility
        )
        let background = plannedBackground(runtime: runtime, role: role, compatibility: compatibility)
        let interaction = plannedInteraction(runtime: runtime, role: role)
        let fps = plannedFps(runtime: runtime, role: role, displayRefreshFps: displayRefreshFps)
        return "background=\(background)\tforeground=\(foregroundPlan.foregroundLabel)\tfallback=\(foregroundPlan.fallbackLabel)\tinteraction=\(interaction)\t\(fps)"
    }

    private static func plannedBackground(
        runtime: NativeRuntimeCore,
        role: RenderDisplayRole,
        compatibility: NativeSpineCompatibility
    ) -> String {
        let foregroundPlan = ForegroundRenderPlan.make(
            runtime: runtime,
            role: role,
            compatibility: compatibility
        )
        if runtime.config.videoEnabled, role.playsVideo {
            if foregroundPlan.usesCompositeVideo,
               let compositeVideo = runtime.assetCatalog.compositeVideoAsset {
                return assetLabel("compositeVideo", compositeVideo.url)
            }

            if let video = runtime.assetCatalog.videoAsset {
                return assetLabel("video", video.url)
            }
        }

        if let staticImage = runtime.assetCatalog.staticImageAssetURL {
            return assetLabel("staticImage", staticImage)
        }

        let preview = runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg")
        if FileManager.default.fileExists(atPath: preview.path) {
            return assetLabel("preview", preview)
        }

        return "none(no-asset)"
    }

    private static func plannedInteraction(runtime: NativeRuntimeCore, role: RenderDisplayRole) -> String {
        let declarativePlan = DeclarativeBindingPlan(manifest: runtime.manifest)
        guard runtime.manifest.interactions.isEmpty == false || declarativePlan.hasPointerInputBindings else {
            return "passive(no-interactions)"
        }
        guard runtime.config.interactive else { return "passive(config-disabled)" }
        guard role.allowsInteraction else { return "passive(display-role)" }
        let policy = runtime.manifest.interactionPolicy ?? InteractionPolicy(
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
        guard policy.mode != .disabled else { return "passive(policy-disabled)" }
        return policy.mode.rawValue
    }

    private static func assetLabel(_ kind: String, _ url: URL) -> String {
        "\(kind):\(url.lastPathComponent)"
    }

    private static func plannedFps(
        runtime: NativeRuntimeCore,
        role: RenderDisplayRole?,
        displayRefreshFps: Int?
    ) -> String {
        let mode = runtime.config.matchDisplayRefresh ? "display" : "fixed"
        let refresh = displayRefreshLabel(displayRefreshFps)
        guard role?.isRenderable == true else {
            return "fps=none\tfpsMode=\(mode)\tdisplayRefresh=\(refresh)"
        }

        let effectiveFps = runtime.renderTargetFps(displayRefreshFps: displayRefreshFps)
        return "fps=\(effectiveFps)\tfpsMode=\(mode)\tdisplayRefresh=\(refresh)"
    }

    private static func displayRefreshLabel(_ fps: Int?) -> String {
        fps.map { "\($0)Hz" } ?? "unknown"
    }

    private static func currentDisplaySnapshots() -> [DisplaySnapshot] {
        var displayIDs = coreGraphicsDisplayIDs(online: false)
        if displayIDs.isEmpty {
            displayIDs = coreGraphicsDisplayIDs(online: true)
        }
        if displayIDs.isEmpty && Bundle.main.bundleURL.pathExtension == "app" {
            _ = NSApplication.shared
            displayIDs = coreGraphicsDisplayIDs(online: false)
            if displayIDs.isEmpty {
                displayIDs = coreGraphicsDisplayIDs(online: true)
            }
        }
        if displayIDs.isEmpty {
            displayIDs = screenDisplayIDs()
        }

        return displayIDs.map { displayID in
            let frame = CGDisplayBounds(displayID)
            let pixelWidth = CGDisplayPixelsWide(displayID)
            let pixelHeight = CGDisplayPixelsHigh(displayID)
            let scaleX = frame.width > 0 ? CGFloat(pixelWidth) / frame.width : 1
            let scaleY = frame.height > 0 ? CGFloat(pixelHeight) / frame.height : 1
            let scale = max(1, min(scaleX, scaleY))
            return DisplaySnapshot(
                name: "Display \(displayID)",
                displayID: displayID,
                frame: frame,
                backingScaleFactor: scale,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                maximumFramesPerSecond: displayRefreshFps(for: displayID),
                vendor: CGDisplayVendorNumber(displayID),
                model: CGDisplayModelNumber(displayID),
                serial: CGDisplaySerialNumber(displayID)
            )
        }
    }

    private static func coreGraphicsDisplayIDs(online: Bool) -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        let result = online
            ? CGGetOnlineDisplayList(0, nil, &count)
            : CGGetActiveDisplayList(0, nil, &count)
        guard result == .success, count > 0 else { return [] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let displayResult = online
            ? CGGetOnlineDisplayList(count, &displayIDs, &count)
            : CGGetActiveDisplayList(count, &displayIDs, &count)
        guard displayResult == .success else { return [] }
        return Array(displayIDs.prefix(Int(count)))
    }

    private static func screenDisplayIDs() -> [CGDirectDisplayID] {
        NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) }
        }
    }

    private static func diagnosticDisplaySnapshot() -> DisplaySnapshot {
        DisplaySnapshot(
            name: "Diagnostic Primary Display",
            displayID: 0,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            backingScaleFactor: 1,
            pixelWidth: 1920,
            pixelHeight: 1080,
            maximumFramesPerSecond: 60,
            vendor: 0,
            model: 0,
            serial: 0
        )
    }

    private static func simulatedMultiDisplaySnapshots() -> [DisplaySnapshot] {
        [
            DisplaySnapshot(
                name: "Simulated MacBook Primary",
                displayID: 90_001,
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                backingScaleFactor: 2,
                pixelWidth: 3456,
                pixelHeight: 2234,
                maximumFramesPerSecond: 120,
                vendor: 0,
                model: 1,
                serial: 1
            ),
            DisplaySnapshot(
                name: "Simulated AOC Left",
                displayID: 90_002,
                frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
                backingScaleFactor: 1,
                pixelWidth: 2560,
                pixelHeight: 1440,
                maximumFramesPerSecond: 60,
                vendor: 0,
                model: 2,
                serial: 2
            ),
            DisplaySnapshot(
                name: "Simulated LG Right",
                displayID: 90_003,
                frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440),
                backingScaleFactor: 1,
                pixelWidth: 2560,
                pixelHeight: 1440,
                maximumFramesPerSecond: 60,
                vendor: 0,
                model: 3,
                serial: 3
            )
        ]
    }

    private static func primaryDisplay(in displays: [DisplaySnapshot], runtime: NativeRuntimeCore) -> DisplaySnapshot? {
        guard let first = displays.first else { return nil }
        guard let selector = runtime.config.primaryDisplaySelector?.trimmingCharacters(in: .whitespacesAndNewlines),
              selector.isEmpty == false else {
            return first
        }
        return displays.first { primarySelectorMatches(selector, descriptor: displayDescriptor(for: $0)) } ?? first
    }

    private static func role(
        for display: DisplaySnapshot,
        primary: DisplaySnapshot,
        runtime: NativeRuntimeCore
    ) -> RenderDisplayRole? {
        role(isPrimary: display.displayID == primary.displayID, displayMode: runtime.config.displayMode, manifest: runtime.manifest)
    }

    private static func displayGeometry(_ display: DisplaySnapshot) -> String {
        "\(Int(display.frame.width))x\(Int(display.frame.height))@\(format(display.backingScaleFactor)) refresh=\(displayRefreshLabel(display.maximumFramesPerSecond)) origin=\(Int(display.frame.minX)),\(Int(display.frame.minY))"
    }

    private static func displayGeometry(_ screen: NSScreen) -> String {
        "\(Int(screen.frame.width))x\(Int(screen.frame.height))@\(format(screen.backingScaleFactor)) refresh=\(screen.maximumFramesPerSecond)Hz origin=\(Int(screen.frame.minX)),\(Int(screen.frame.minY))"
    }

    private static func displayIdentity(_ display: DisplaySnapshot) -> String {
        displayDescriptor(for: display).summary
    }

    private static func displayIdentity(_ screen: NSScreen) -> String {
        displayDescriptor(for: screen).summary
    }

    private static func primarySelectionSummary(primary: DisplaySnapshot, runtime: NativeRuntimeCore) -> String {
        let descriptor = displayDescriptor(for: primary)
        guard let selector = runtime.config.primaryDisplaySelector?.trimmingCharacters(in: .whitespacesAndNewlines),
              selector.isEmpty == false else {
            return "coregraphics-default \(descriptor.shortSummary)"
        }

        let status = primarySelectorMatches(selector, descriptor: descriptor) ? "matched" : "unmatched-fallback"
        return "\(status) selector=\(selector) effective=\(descriptor.shortSummary)"
    }

    private static func primarySelectionSummary(primary: NSScreen, runtime: NativeRuntimeCore) -> String {
        let descriptor = displayDescriptor(for: primary)
        guard let selector = runtime.config.primaryDisplaySelector?.trimmingCharacters(in: .whitespacesAndNewlines),
              selector.isEmpty == false else {
            return "appkit-default \(descriptor.shortSummary)"
        }

        let status = primarySelectorMatches(selector, descriptor: descriptor) ? "matched" : "unmatched-fallback"
        return "\(status) selector=\(selector) effective=\(descriptor.shortSummary)"
    }

    private static func displayDescriptor(for screen: NSScreen) -> DisplayIdentityDescriptor {
        let displayID = screen.displayID
        return DisplayIdentityDescriptor(
            name: screen.localizedName,
            displayID: displayID.map { UInt32($0) },
            fingerprint: fallbackFingerprint(for: screen, displayID: displayID),
            arrangement: arrangementFingerprint(for: screen)
        )
    }

    private static func displayDescriptor(for display: DisplaySnapshot) -> DisplayIdentityDescriptor {
        DisplayIdentityDescriptor(
            name: display.name,
            displayID: UInt32(display.displayID),
            fingerprint: fallbackFingerprint(for: display),
            arrangement: arrangementFingerprint(for: display)
        )
    }

    private static func fallbackFingerprint(for display: DisplaySnapshot) -> String {
        let source = [
            display.name,
            "vendor:\(display.vendor)",
            "model:\(display.model)",
            "serial:\(display.serial)",
            "pixels:\(display.pixelWidth)x\(display.pixelHeight)",
            "scale:\(format(display.backingScaleFactor))",
            "source:coregraphics"
        ].joined(separator: "|")
        return stableHash(source)
    }

    private static func fallbackFingerprint(for screen: NSScreen, displayID: CGDirectDisplayID?) -> String {
        let pixelWidth = displayID.map { CGDisplayPixelsWide($0) } ?? Int(screen.frame.width * screen.backingScaleFactor)
        let pixelHeight = displayID.map { CGDisplayPixelsHigh($0) } ?? Int(screen.frame.height * screen.backingScaleFactor)
        let vendor = displayID.map { CGDisplayVendorNumber($0) } ?? 0
        let model = displayID.map { CGDisplayModelNumber($0) } ?? 0
        let serial = displayID.map { CGDisplaySerialNumber($0) } ?? 0
        let colorSpace = screen.colorSpace?.localizedName ?? "unknown"
        let source = [
            screen.localizedName,
            "vendor:\(vendor)",
            "model:\(model)",
            "serial:\(serial)",
            "pixels:\(pixelWidth)x\(pixelHeight)",
            "scale:\(format(screen.backingScaleFactor))",
            "fps:\(screen.maximumFramesPerSecond)",
            "color:\(colorSpace)"
        ].joined(separator: "|")
        return stableHash(source)
    }

    private static func arrangementFingerprint(for display: DisplaySnapshot) -> String {
        let source = [
            "origin:\(Int(display.frame.minX)),\(Int(display.frame.minY))",
            "points:\(Int(display.frame.width))x\(Int(display.frame.height))",
            "scale:\(format(display.backingScaleFactor))"
        ].joined(separator: "|")
        return stableHash(source)
    }

    private static func arrangementFingerprint(for screen: NSScreen) -> String {
        let source = [
            "origin:\(Int(screen.frame.minX)),\(Int(screen.frame.minY))",
            "points:\(Int(screen.frame.width))x\(Int(screen.frame.height))",
            "scale:\(format(screen.backingScaleFactor))"
        ].joined(separator: "|")
        return stableHash(source)
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func displayRefreshFps(for displayID: CGDirectDisplayID) -> Int? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        let refreshRate = mode.refreshRate
        guard refreshRate.isFinite, refreshRate > 0 else { return nil }
        return max(1, Int(refreshRate.rounded()))
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }
}

private struct DisplaySnapshot {
    let name: String
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let backingScaleFactor: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int
    let maximumFramesPerSecond: Int?
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
}

struct DisplaySelectionOption {
    let title: String
    let selector: String?
}

struct DisplayIdentityDescriptor {
    let name: String
    let displayID: UInt32?
    let fingerprint: String
    let arrangement: String

    var summary: String {
        "identity=\(identityLabel) fingerprint=\(fingerprint) arrangement=\(arrangement)"
    }

    var shortSummary: String {
        "\(identityLabel) fingerprint=\(fingerprint)"
    }

    private var identityLabel: String {
        displayID.map { "displayID:\($0)" } ?? "displayID:unknown"
    }
}

struct RenderDisplayRole {
    enum Kind {
        case primary
        case secondary

        var label: String {
            switch self {
            case .primary:
                return "primary"
            case .secondary:
                return "secondary"
            }
        }
    }

    let kind: Kind
    let policy: DisplayRolePolicy

    var rendersForeground: Bool {
        policy == .full
    }

    var playsVideo: Bool {
        policy == .full || policy == .videoOnly
    }

    var prefersCompositeVideo: Bool {
        policy == .full
    }

    var allowsInteraction: Bool {
        kind == .primary && policy == .full
    }

    var isRenderable: Bool {
        policy != .pause
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let value = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(value.uint32Value)
    }
}

final class PlainWallpaperView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.965, alpha: 1.0).cgColor
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
