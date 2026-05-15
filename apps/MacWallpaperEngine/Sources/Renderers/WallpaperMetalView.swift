import AppKit
import MetalKit

final class WallpaperMetalView: MTKView {
    private let compositor: MetalCompositor
    private let interaction: InteractionController
    private let interactionPolicy: InteractionPolicy
    private let displayPolicy: DisplayPolicy
    private let displayRole: RenderDisplayRole
    private weak var observedWindow: NSWindow?
    private var mouseMonitor: DesktopMouseInteractionMonitor?

    init(runtime: NativeRuntimeCore, displayRole: RenderDisplayRole, displayName: String) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EngineError.renderer("Metal device is unavailable")
        }

        self.displayRole = displayRole
        self.displayPolicy = runtime.manifest.displayPolicy
        let manifestInteractionPolicy = runtime.manifest.interactionPolicy ?? InteractionPolicy(
            mode: runtime.config.interactive ? .desktopEmptyOnly : .disabled,
            blockApplicationWindows: true,
            blockDesktopItems: true,
            pointerSmoothing: nil,
            idleDeadZone: nil,
            directionSwitchMargin: nil,
            defaultClickTailSeconds: nil,
            releaseFadeSeconds: nil
        )
        self.interactionPolicy = runtime.config.interactive && displayRole.allowsInteraction ? manifestInteractionPolicy : InteractionPolicy(
            mode: .disabled,
            blockApplicationWindows: true,
            blockDesktopItems: true,
            pointerSmoothing: nil,
            idleDeadZone: nil,
            directionSwitchMargin: nil,
            defaultClickTailSeconds: nil,
            releaseFadeSeconds: nil
        )
        self.interaction = InteractionController(interactions: runtime.manifest.interactions, policy: manifestInteractionPolicy)
        self.compositor = try MetalCompositor(
            device: device,
            runtime: runtime,
            displayRole: displayRole,
            displayName: displayName,
            interaction: interaction
        )

        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        autoResizeDrawable = false
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = runtime.renderTargetFps
        clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.025, alpha: 1.0)
        delegate = compositor

        wantsLayer = true
        window?.acceptsMouseMovedEvents = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    deinit {
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: observedWindow
            )
        }
        mouseMonitor?.stop()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()

        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: observedWindow
            )
        }
        observedWindow = window
        mouseMonitor?.stop()
        mouseMonitor = nil
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowOcclusionChanged),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
            mouseMonitor = DesktopMouseInteractionMonitor(
                window: window,
                policy: interactionPolicy,
                onMove: { [weak self] point in
                    self?.interaction.pointerMoved(to: point)
                },
                onDown: { [weak self] point, button in
                    self?.interaction.pointerDown(at: point, button: button)
                },
                onUp: { [weak self] point, button in
                    self?.interaction.pointerUp(at: point, button: button)
                },
                onExit: { [weak self] in
                    self?.interaction.pointerTrackingStopped()
                }
            )
            mouseMonitor?.start()
        }

        window?.makeFirstResponder(self)
        updatePauseStateFromOcclusion()
    }

    private func updateDrawableSize() {
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        layer?.contentsScale = backingScale
        let width = max(bounds.width * backingScale, 1)
        let height = max(bounds.height * backingScale, 1)
        drawableSize = CGSize(width: width, height: height)
    }

    @objc private func windowOcclusionChanged(_ notification: Notification) {
        updatePauseStateFromOcclusion()
    }

    private func updatePauseStateFromOcclusion() {
        let isVisible = window?.occlusionState.contains(.visible) ?? true
        let shouldPause = RuntimeLifecyclePolicy.shouldPauseForWindowVisibility(
            isVisible: isVisible,
            displayPolicy: displayPolicy
        )
        isPaused = shouldPause
        compositor.setPausedByHost(shouldPause)
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactionPolicy.mode == .always else { return }
        interaction.pointerMoved(to: normalizedPoint(from: event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactionPolicy.mode == .always else { return }
        interaction.pointerMoved(to: normalizedPoint(from: event))
    }

    override func mouseDown(with event: NSEvent) {
        guard interactionPolicy.mode == .always else { return }
        interaction.pointerDown(at: normalizedPoint(from: event), button: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard interactionPolicy.mode == .always else { return }
        interaction.pointerDown(at: normalizedPoint(from: event), button: .right)
    }

    override func mouseUp(with event: NSEvent) {
        guard interactionPolicy.mode == .always else { return }
        interaction.pointerUp(at: normalizedPoint(from: event), button: .left)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard interactionPolicy.mode == .always else { return }
        interaction.pointerUp(at: normalizedPoint(from: event), button: .right)
    }

    private func normalizedPoint(from event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return CGPoint(
            x: local.x / bounds.width,
            y: 1.0 - (local.y / bounds.height)
        )
    }
}
