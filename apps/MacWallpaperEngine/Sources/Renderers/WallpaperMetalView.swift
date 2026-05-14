import AppKit
import MetalKit

final class WallpaperMetalView: MTKView {
    private let compositor: MetalCompositor
    private let interaction: InteractionController
    private let interactionPolicy: InteractionPolicy
    private let displayRole: RenderDisplayRole
    private weak var observedWindow: NSWindow?
    private var mouseMonitor: DesktopMouseInteractionMonitor?
    private var pointerPollTimer: Timer?
    private var lastPointerEligibilityCheckAt: CFTimeInterval = 0
    private var lastPointerEligibilityPoint: CGPoint?
    private var lastPointerEligibility = false
    private let pointerPollingInterval: TimeInterval = 1.0 / 30.0
    private let pointerEligibilityCacheInterval: CFTimeInterval = 0.20
    private let pointerEligibilityCacheDistanceSquared: CGFloat = 24 * 24

    init(runtime: NativeRuntimeCore, displayRole: RenderDisplayRole) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EngineError.renderer("Metal device is unavailable")
        }

        self.displayRole = displayRole
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
        pointerPollTimer?.invalidate()
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
        pointerPollTimer?.invalidate()
        pointerPollTimer = nil
        resetPointerEligibilityCache()
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
                    self?.syncPointerPolling()
                },
                onDown: { [weak self] point, button in
                    self?.interaction.pointerDown(at: point, button: button)
                    self?.syncPointerPolling()
                },
                onUp: { [weak self] point, button in
                    self?.interaction.pointerUp(at: point, button: button)
                    self?.syncPointerPolling()
                },
                onExit: { [weak self] in
                    self?.interaction.pointerTrackingStopped()
                    self?.syncPointerPolling()
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
        isPaused = false
        compositor.setPausedByHost(false)
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactionPolicy.mode == .always else { return }
        interaction.pointerMoved(to: normalizedPoint(from: event))
        syncPointerPolling()
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactionPolicy.mode == .always else { return }
        interaction.pointerMoved(to: normalizedPoint(from: event))
        syncPointerPolling()
    }

    override func mouseDown(with event: NSEvent) {
        guard interactionPolicy.mode == .always else { return }
        interaction.pointerDown(at: normalizedPoint(from: event), button: .left)
        syncPointerPolling()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard interactionPolicy.mode == .always else { return }
        interaction.pointerDown(at: normalizedPoint(from: event), button: .right)
        syncPointerPolling()
    }

    override func mouseUp(with event: NSEvent) {
        guard interactionPolicy.mode == .always else { return }
        interaction.pointerUp(at: normalizedPoint(from: event), button: .left)
        syncPointerPolling()
    }

    override func rightMouseUp(with event: NSEvent) {
        guard interactionPolicy.mode == .always else { return }
        interaction.pointerUp(at: normalizedPoint(from: event), button: .right)
        syncPointerPolling()
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

    private func syncPointerPolling() {
        guard interactionPolicy.mode == .desktopEmptyOnly else {
            stopPointerPolling()
            return
        }
        if interaction.needsPointerPolling() {
            startPointerPolling()
        } else {
            stopPointerPolling()
        }
    }

    private func startPointerPolling() {
        guard interactionPolicy.mode == .desktopEmptyOnly, pointerPollTimer == nil else { return }

        let timer = Timer(timeInterval: pointerPollingInterval, repeats: true) { [weak self] _ in
            self?.pollPointerLocation()
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerPollTimer = timer
    }

    private func stopPointerPolling() {
        pointerPollTimer?.invalidate()
        pointerPollTimer = nil
        resetPointerEligibilityCache()
    }

    private func pollPointerLocation() {
        guard let window else { return }
        guard interaction.needsPointerPolling() else {
            stopPointerPolling()
            return
        }
        let screenPoint = NSEvent.mouseLocation
        guard window.frame.contains(screenPoint) else {
            interaction.pointerTrackingStopped()
            stopPointerPolling()
            return
        }
        guard isPointerMoveEligible(screenPoint: screenPoint) else {
            interaction.pointerTrackingStopped()
            stopPointerPolling()
            return
        }
        interaction.pointerMoved(to: normalizedPoint(fromScreen: screenPoint, in: window))
    }

    private func isPointerMoveEligible(screenPoint: CGPoint) -> Bool {
        if let lastPoint = lastPointerEligibilityPoint {
            let now = CACurrentMediaTime()
            let dx = screenPoint.x - lastPoint.x
            let dy = screenPoint.y - lastPoint.y
            if now - lastPointerEligibilityCheckAt < pointerEligibilityCacheInterval,
               (dx * dx) + (dy * dy) < pointerEligibilityCacheDistanceSquared {
                return lastPointerEligibility
            }
        }

        let eligible: Bool
        switch interactionPolicy.mode {
        case .always:
            eligible = true
        case .disabled:
            eligible = false
        case .desktopEmptyOnly:
            if interactionPolicy.blockApplicationWindows,
               DesktopInteractionGate.isCoveredByApplicationWindow(screenPoint: screenPoint) {
                eligible = false
                break
            }
            if interactionPolicy.blockDesktopItems,
               DesktopInteractionGate.isLikelyDesktopItem(screenPoint: screenPoint) {
                eligible = false
                break
            }
            eligible = true
        }

        lastPointerEligibilityCheckAt = CACurrentMediaTime()
        lastPointerEligibilityPoint = screenPoint
        lastPointerEligibility = eligible
        return eligible
    }

    private func resetPointerEligibilityCache() {
        lastPointerEligibilityCheckAt = 0
        lastPointerEligibilityPoint = nil
        lastPointerEligibility = false
    }

    private func normalizedPoint(fromScreen screenPoint: CGPoint, in window: NSWindow) -> CGPoint {
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let local = convert(windowPoint, from: nil)
        guard bounds.width > 0, bounds.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return CGPoint(
            x: min(max(local.x / bounds.width, 0.0), 1.0),
            y: min(max(1.0 - (local.y / bounds.height), 0.0), 1.0)
        )
    }
}
