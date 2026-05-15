import AppKit

final class WallpaperHost: NSObject {
    private let runtime: NativeRuntimeCore
    private var windows: [NSWindow] = []

    init(runtime: NativeRuntimeCore) throws {
        self.runtime = runtime
        super.init()
    }

    func start() throws {
        try rebuildWindows()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        close(windows: windows)
        windows.removeAll()
    }

    @objc private func screenParametersChanged() {
        do {
            try rebuildWindows()
        } catch {
            fputs("Display rebuild failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func rebuildWindows() throws {
        let replacementWindows = try makeReplacementWindows()
        replaceWindows(with: replacementWindows)
    }

    private func makeReplacementWindows() throws -> [NSWindow] {
        var replacementWindows: [NSWindow] = []
        do {
            let screens = NSScreen.screens
            guard let primary = screens.first else { return [] }

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

    private func replaceWindows(with replacementWindows: [NSWindow]) {
        let oldWindows = windows
        windows = replacementWindows
        close(windows: oldWindows)
        show(windows: replacementWindows)
    }

    private func close(windows targetWindows: [NSWindow]) {
        for window in targetWindows {
            window.orderOut(nil)
            window.close()
        }
    }

    private func show(windows targetWindows: [NSWindow]) {
        for window in targetWindows {
            if runtime.config.startHidden {
                window.orderOut(nil)
            } else if runtime.config.plainWindowStyle {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
        }
    }

    private func makeWindow(for screen: NSScreen, role: RenderDisplayRole) throws -> NSWindow {
        do {
            let view: NSView = if runtime.config.metalEnabled {
                try WallpaperMetalView(runtime: runtime, displayRole: role, displayName: screen.localizedName)
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
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = runtime.config.plainWindowStyle
            window.animationBehavior = .none
            window.ignoresMouseEvents = runtime.config.plainWindowStyle == false
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

}

enum DisplayPlanner {
    static let rebuildPolicy = "atomic-rollback"

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
        let screens = NSScreen.screens
        guard let primary = screens.first else {
            return "display plan: no screens detected"
        }

        let lines = screens.enumerated().map { index, screen in
            let role = role(for: screen, primary: primary, runtime: runtime)
            let roleName = role.map { "\($0.kind.label):\($0.policy.rawValue)" } ?? "none"
            let foreground = role?.rendersForeground == true ? "foreground" : "no-foreground"
            let video = role?.playsVideo == true ? "video" : "static"
            let interaction = role?.allowsInteraction == true ? "interactive" : "passive"
            return "#\(index) \(screen.localizedName)\t\(displayGeometry(screen))\t\(displayIdentity(screen))\t\(roleName)\t\(foreground)\t\(video)\t\(interaction)"
        }

        return """
        display plan OK
        displayMode: \(runtime.config.displayMode.rawValue)
        rebuildPolicy: \(rebuildPolicy)
        manifest primary: \(runtime.manifest.displayPolicy.primary.rawValue)
        manifest secondary: \(runtime.manifest.displayPolicy.secondary.rawValue)
        occluded: \(runtime.manifest.displayPolicy.occluded.rawValue)
        fullscreenObscured: \(runtime.manifest.displayPolicy.fullscreenObscured.rawValue)
        \(lines.joined(separator: "\n"))
        """
    }

    static func renderSummary(runtime: NativeRuntimeCore) -> String {
        let screens = NSScreen.screens
        guard let primary = screens.first else {
            return "render plan: no screens detected"
        }

        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        let lines = screens.enumerated().map { index, screen in
            let role = role(for: screen, primary: primary, runtime: runtime)
            let roleName = role.map { "\($0.kind.label):\($0.policy.rawValue)" } ?? "none"
            let path = role.map { renderPathSummary(runtime: runtime, role: $0) }
                ?? "background=none\tforeground=none\tfallback=none\tinteraction=passive"
            return "#\(index) \(screen.localizedName)\t\(displayGeometry(screen))\t\(displayIdentity(screen))\t\(roleName)\t\(path)"
        }

        return """
        render plan OK
        foregroundMode: \(runtime.config.foregroundMode.rawValue)
        displayMode: \(runtime.config.displayMode.rawValue)
        nativeCompatibility: \(compatibility.isSupported ? "supported" : "unsupported") \(compatibility.reasonText)
        \(lines.joined(separator: "\n"))
        """
    }

    static func renderPathSummary(runtime: NativeRuntimeCore, role: RenderDisplayRole) -> String {
        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        let background = plannedBackground(runtime: runtime, role: role, compatibility: compatibility)
        let foreground = plannedForeground(runtime: runtime, role: role, compatibility: compatibility)
        let fallback = plannedFallback(runtime: runtime, role: role, compatibility: compatibility)
        let interaction = plannedInteraction(runtime: runtime, role: role)
        return "background=\(background)\tforeground=\(foreground)\tfallback=\(fallback)\tinteraction=\(interaction)"
    }

    private static func plannedBackground(
        runtime: NativeRuntimeCore,
        role: RenderDisplayRole,
        compatibility: NativeSpineCompatibility
    ) -> String {
        if runtime.config.videoEnabled, role.playsVideo {
            if shouldUseCompositeVideo(runtime: runtime, role: role, compatibility: compatibility),
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

    private static func plannedForeground(
        runtime: NativeRuntimeCore,
        role: RenderDisplayRole,
        compatibility: NativeSpineCompatibility
    ) -> String {
        guard role.rendersForeground else { return "none(display-policy)" }

        switch runtime.config.foregroundMode {
        case .compositeVideo:
            guard shouldUseCompositeVideo(runtime: runtime, role: role, compatibility: compatibility) else {
                return "none(no-compositeVideo)"
            }
            return "compositeVideo"
        case .nativeSpine:
            if compatibility.isSupported == false {
                return runtime.assetCatalog.compositeVideoAsset == nil
                    ? "blocked(native-unsupported)"
                    : "compositeFallback(native-unsupported)"
            }
            return runtime.assetCatalog.spineAsset == nil ? "none(no-spine)" : "nativeSpine"
        }
    }

    private static func plannedFallback(
        runtime: NativeRuntimeCore,
        role: RenderDisplayRole,
        compatibility: NativeSpineCompatibility
    ) -> String {
        guard runtime.config.foregroundMode == .nativeSpine, role.rendersForeground else {
            return "none"
        }

        if compatibility.isSupported == false {
            return runtime.assetCatalog.compositeVideoAsset == nil
                ? "blocked(no-compositeVideo)"
                : "nativeCompatibility->compositeVideo"
        }

        return runtime.assetCatalog.compositeVideoAsset == nil
            ? "none"
            : "resourceBudget->compositeVideo"
    }

    private static func plannedInteraction(runtime: NativeRuntimeCore, role: RenderDisplayRole) -> String {
        guard runtime.config.interactive else { return "passive(config-disabled)" }
        guard role.allowsInteraction else { return "passive(display-role)" }
        let mode = runtime.manifest.interactionPolicy?.mode ?? .desktopEmptyOnly
        return mode == .disabled ? "passive(policy-disabled)" : mode.rawValue
    }

    private static func shouldUseCompositeVideo(
        runtime: NativeRuntimeCore,
        role: RenderDisplayRole,
        compatibility: NativeSpineCompatibility
    ) -> Bool {
        (runtime.config.foregroundMode == .compositeVideo || shouldFallbackNativeSpineToComposite(
            runtime: runtime,
            role: role,
            compatibility: compatibility
        ))
            && role.prefersCompositeVideo
            && runtime.assetCatalog.compositeVideoAsset != nil
    }

    private static func shouldFallbackNativeSpineToComposite(
        runtime: NativeRuntimeCore,
        role: RenderDisplayRole,
        compatibility: NativeSpineCompatibility
    ) -> Bool {
        runtime.config.foregroundMode == .nativeSpine
            && role.rendersForeground
            && compatibility.isSupported == false
            && runtime.assetCatalog.compositeVideoAsset != nil
    }

    private static func assetLabel(_ kind: String, _ url: URL) -> String {
        "\(kind):\(url.lastPathComponent)"
    }

    private static func displayGeometry(_ screen: NSScreen) -> String {
        "\(Int(screen.frame.width))x\(Int(screen.frame.height))@\(format(screen.backingScaleFactor)) origin=\(Int(screen.frame.minX)),\(Int(screen.frame.minY))"
    }

    private static func displayIdentity(_ screen: NSScreen) -> String {
        let displayID = screen.displayID
        let stableIdentity = displayID.map { "displayID:\($0)" } ?? "displayID:unknown"
        return "identity=\(stableIdentity) fingerprint=\(fallbackFingerprint(for: screen, displayID: displayID)) arrangement=\(arrangementFingerprint(for: screen))"
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

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
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
        layer?.backgroundColor = NSColor.black.cgColor
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
