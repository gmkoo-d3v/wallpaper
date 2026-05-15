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
            return "#\(index) \(display.name)\t\(displayGeometry(display))\t\(displayIdentity(display))\t\(roleName)\t\(foreground)\t\(video)\t\(interaction)"
        }

        return """
        display plan OK
        displayMode: \(runtime.config.displayMode.rawValue)
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
        let line = "#0 \(display.name)\t\(displayGeometry(display))\t\(displayIdentity(display))\t\(roleName)\t\(foreground)\t\(video)\t\(interaction)"

        return """
        display plan OK
        displayProbe: skipped(cli-safe)
        displayMode: \(runtime.config.displayMode.rawValue)
        primarySelection: \(primarySelectionSummary(primary: display, runtime: runtime))
        rebuildPolicy: \(rebuildPolicy)
        manifest primary: \(runtime.manifest.displayPolicy.primary.rawValue)
        manifest secondary: \(runtime.manifest.displayPolicy.secondary.rawValue)
        occluded: \(runtime.manifest.displayPolicy.occluded.rawValue)
        fullscreenObscured: \(runtime.manifest.displayPolicy.fullscreenObscured.rawValue)
        \(line)
        """
    }

    static func renderSummary(runtime: NativeRuntimeCore) -> String {
        let displays = currentDisplaySnapshots()
        guard let primary = primaryDisplay(in: displays, runtime: runtime) else {
            return "render plan: no screens detected"
        }

        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        let lines = displays.enumerated().map { index, display in
            let role = role(for: display, primary: primary, runtime: runtime)
            let roleName = role.map { "\($0.kind.label):\($0.policy.rawValue)" } ?? "none"
            let path = role.map { renderPathSummary(runtime: runtime, role: $0) }
                ?? "background=none\tforeground=none\tfallback=none\tinteraction=passive"
            return "#\(index) \(display.name)\t\(displayGeometry(display))\t\(displayIdentity(display))\t\(roleName)\t\(path)"
        }

        return """
        render plan OK
        foregroundMode: \(runtime.config.foregroundMode.rawValue)
        displayMode: \(runtime.config.displayMode.rawValue)
        primarySelection: \(primarySelectionSummary(primary: primary, runtime: runtime))
        nativeCompatibility: \(compatibility.isSupported ? "supported" : "unsupported") \(compatibility.reasonText)
        \(lines.joined(separator: "\n"))
        """
    }

    static func headlessRenderSummary(runtime: NativeRuntimeCore) -> String {
        let display = diagnosticDisplaySnapshot()
        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        let role = role(for: display, primary: display, runtime: runtime)
        let roleName = role.map { "\($0.kind.label):\($0.policy.rawValue)" } ?? "none"
        let path = role.map { renderPathSummary(runtime: runtime, role: $0) }
            ?? "background=none\tforeground=none\tfallback=none\tinteraction=passive"
        let line = "#0 \(display.name)\t\(displayGeometry(display))\t\(displayIdentity(display))\t\(roleName)\t\(path)"

        return """
        render plan OK
        displayProbe: skipped(cli-safe)
        foregroundMode: \(runtime.config.foregroundMode.rawValue)
        displayMode: \(runtime.config.displayMode.rawValue)
        primarySelection: \(primarySelectionSummary(primary: display, runtime: runtime))
        nativeCompatibility: \(compatibility.isSupported ? "supported" : "unsupported") \(compatibility.reasonText)
        \(line)
        """
    }

    static func renderPathSummary(runtime: NativeRuntimeCore, role: RenderDisplayRole) -> String {
        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        let foregroundPlan = ForegroundRenderPlan.make(
            runtime: runtime,
            role: role,
            compatibility: compatibility
        )
        let background = plannedBackground(runtime: runtime, role: role, compatibility: compatibility)
        let interaction = plannedInteraction(runtime: runtime, role: role)
        return "background=\(background)\tforeground=\(foregroundPlan.foregroundLabel)\tfallback=\(foregroundPlan.fallbackLabel)\tinteraction=\(interaction)"
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
        guard runtime.config.interactive else { return "passive(config-disabled)" }
        guard role.allowsInteraction else { return "passive(display-role)" }
        let mode = runtime.manifest.interactionPolicy?.mode ?? .desktopEmptyOnly
        return mode == .disabled ? "passive(policy-disabled)" : mode.rawValue
    }

    private static func assetLabel(_ kind: String, _ url: URL) -> String {
        "\(kind):\(url.lastPathComponent)"
    }

    private static func currentDisplaySnapshots() -> [DisplaySnapshot] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            return []
        }

        return displayIDs.prefix(Int(count)).map { displayID in
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
                vendor: CGDisplayVendorNumber(displayID),
                model: CGDisplayModelNumber(displayID),
                serial: CGDisplaySerialNumber(displayID)
            )
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
            vendor: 0,
            model: 0,
            serial: 0
        )
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
        "\(Int(display.frame.width))x\(Int(display.frame.height))@\(format(display.backingScaleFactor)) origin=\(Int(display.frame.minX)),\(Int(display.frame.minY))"
    }

    private static func displayGeometry(_ screen: NSScreen) -> String {
        "\(Int(screen.frame.width))x\(Int(screen.frame.height))@\(format(screen.backingScaleFactor)) origin=\(Int(screen.frame.minX)),\(Int(screen.frame.minY))"
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
