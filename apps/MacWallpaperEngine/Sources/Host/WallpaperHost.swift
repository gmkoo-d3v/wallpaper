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
                try WallpaperMetalView(runtime: runtime, displayRole: role)
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
            return "#\(index) \(screen.localizedName)\t\(Int(screen.frame.width))x\(Int(screen.frame.height))\t\(roleName)\t\(foreground)\t\(video)\t\(interaction)"
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
