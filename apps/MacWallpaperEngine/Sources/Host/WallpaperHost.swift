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
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }

    @objc private func screenParametersChanged() {
        do {
            try rebuildWindows()
        } catch {
            fputs("Display rebuild failed: \(error.localizedDescription)\n", stderr)
            stop()
        }
    }

    private func rebuildWindows() throws {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()

        let screens = NSScreen.screens
        guard let primary = screens.first else { return }

        for screen in screens {
            guard let role = displayRole(for: screen, primary: primary) else { continue }
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

                if runtime.config.startHidden {
                    window.orderOut(nil)
                } else if runtime.config.plainWindowStyle {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    window.orderFrontRegardless()
                }
                windows.append(window)
            } catch {
                throw EngineError.renderer("display \(screen.localizedName) renderer failed: \(error.localizedDescription)")
            }
        }
    }

    private func displayRole(for screen: NSScreen, primary: NSScreen) -> RenderDisplayRole? {
        let isPrimary = screen === primary
        switch runtime.config.displayMode {
        case .all:
            return isPrimary ? .primaryFull : .secondaryFull
        case .primaryAnimated, .primaryOnly:
            return isPrimary ? .primaryFull : nil
        }
    }
}

enum RenderDisplayRole {
    case primaryFull
    case secondaryFull

    var rendersForeground: Bool {
        switch self {
        case .primaryFull, .secondaryFull:
            return true
        }
    }

    var prefersCompositeVideo: Bool {
        switch self {
        case .primaryFull, .secondaryFull:
            return true
        }
    }

    var allowsInteraction: Bool {
        switch self {
        case .primaryFull:
            return true
        case .secondaryFull:
            return false
        }
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
