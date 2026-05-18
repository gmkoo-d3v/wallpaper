import AppKit
import MetalKit

final class WallpaperMetalView: MTKView {
    private static let warmupLayerBackground = CGColor(
        red: 0.95,
        green: 0.95,
        blue: 0.965,
        alpha: 1.0
    )

    private let compositor: MetalCompositor
    private let interaction: InteractionController
    private let interactionPolicy: InteractionPolicy
    private let displayPolicy: DisplayPolicy
    private let displayRole: RenderDisplayRole
    private let interactionCoordinateMapper: InteractionCoordinateMapper
    private let runtime: NativeRuntimeCore
    private let displayName: String
    private weak var observedWindow: NSWindow?
    private var mouseMonitor: DesktopMouseInteractionMonitor?
    private var hasPresentedVisibleWindow = false
    private var directDeliveredEvents = 0
    private var directBlockedEvents = 0

    init(
        runtime: NativeRuntimeCore,
        displayRole: RenderDisplayRole,
        displayName: String,
        displayRefreshFps: Int?
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EngineError.renderer("Metal device is unavailable")
        }

        self.displayRole = displayRole
        self.runtime = runtime
        self.displayName = displayName
        self.displayPolicy = runtime.manifest.displayPolicy
        self.interactionCoordinateMapper = InteractionCoordinateMapper(
            fitMode: runtime.config.fitMode,
            contentAspect: CGFloat(runtime.assetCatalog.contentAspect)
        )
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
        let hasDeclaredInteractions = runtime.manifest.interactions.isEmpty == false
        let shouldEnableInteraction = runtime.config.interactive
            && displayRole.allowsInteraction
            && hasDeclaredInteractions
        self.interactionPolicy = shouldEnableInteraction ? manifestInteractionPolicy : InteractionPolicy(
            mode: .disabled,
            blockApplicationWindows: true,
            blockDesktopItems: true,
            pointerSmoothing: nil,
            pointerSampleFps: nil,
            idleDeadZone: nil,
            directionSwitchMargin: nil,
            defaultClickTailSeconds: nil,
            releaseFadeSeconds: nil
        )
        let actionTailDurations = (try? SpineAnimationDiagnostics.tapActionDurations(runtime: runtime)) ?? [:]
        self.interaction = InteractionController(
            interactions: runtime.manifest.interactions,
            policy: manifestInteractionPolicy,
            actionTailDurations: actionTailDurations
        )
        self.compositor = try MetalCompositor(
            device: device,
            runtime: runtime,
            displayRole: displayRole,
            displayName: displayName,
            displayRefreshFps: displayRefreshFps,
            interaction: interaction
        )

        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        autoResizeDrawable = false
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = runtime.renderTargetFps(displayRefreshFps: displayRefreshFps)
        clearColor = MTLClearColor(red: 0.95, green: 0.95, blue: 0.965, alpha: 1.0)
        delegate = compositor

        wantsLayer = true
        layer?.backgroundColor = Self.warmupLayerBackground
        layer?.isOpaque = true
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

    func refreshInteractionState() {
        updatePauseStateFromOcclusion()
    }

    func warmUpVisibleFrame() {
        updateDrawableSize()
        guard compositor.needsVisibleWarmupDrawable() else { return }
        isPaused = false
        draw()
        if compositor.needsVisibleWarmupDrawable() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                self.updateDrawableSize()
                self.isPaused = false
                self.draw()
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        interactionPolicy.mode != .disabled
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = Self.warmupLayerBackground
        layer?.isOpaque = true
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
                    guard let self else { return }
                    guard let contentPoint = self.interactionContentPoint(fromWindowNormalized: point) else {
                        return
                    }
                    self.interaction.pointerMoved(to: contentPoint)
                },
                onDown: { [weak self] point, button in
                    guard let self,
                          let contentPoint = self.interactionContentPoint(fromWindowNormalized: point) else {
                        return
                    }
                    self.interaction.pointerDown(at: contentPoint, button: button)
                },
                onUp: { [weak self] point, button in
                    guard let self else { return }
                    if let contentPoint = self.interactionContentPoint(fromWindowNormalized: point) {
                        self.interaction.pointerUp(at: contentPoint, button: button)
                    } else {
                        self.interaction.pointerUp(button: button)
                    }
                },
                onExit: { [weak self] in
                    self?.interaction.pointerTrackingStopped()
                },
                onInterrupted: { [weak self] in
                    self?.interaction.pointerTrackingInterrupted()
                },
                currentInteractionSnapshot: { [weak self] in
                    self?.interaction.snapshot()
                },
                onTelemetry: { [weak self] snapshot in
                    guard let self else { return }
                    self.runtime.telemetry.recordInteraction(
                        displayName: self.displayName,
                        role: self.displayRole,
                        snapshot: snapshot
                    )
                }
            )
            window.acceptsMouseMovedEvents = true
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
        let windowIsVisible = window?.isVisible ?? true
        let occlusionVisible = window?.occlusionState.contains(.visible) ?? true
        let isVisible = RuntimeLifecyclePolicy.effectiveRendererVisibility(
            windowIsVisible: windowIsVisible,
            occlusionVisible: occlusionVisible,
            hasPresentedVisibleWindow: hasPresentedVisibleWindow
        )
        if windowIsVisible && occlusionVisible {
            hasPresentedVisibleWindow = true
        }
        let shouldPause = RuntimeLifecyclePolicy.shouldPauseForWindowVisibility(
            isVisible: isVisible,
            displayPolicy: displayPolicy
        )
        let accessibilityTrusted = accessibilityTrustForInteraction()
        let shouldEnableInteraction = RuntimeLifecyclePolicy.shouldEnableDesktopInteraction(
            isVisible: isVisible,
            displayRole: displayRole,
            interactionPolicy: interactionPolicy,
            accessibilityTrusted: accessibilityTrusted
        )
        let needsPausedWarmupDrawable = compositor.needsPausedWarmupDrawable(ifHostPaused: shouldPause)
        isPaused = shouldPause && needsPausedWarmupDrawable == false
        compositor.setPausedByHost(shouldPause)
        setMouseMonitorActive(shouldEnableInteraction)
    }

    private func accessibilityTrustForInteraction() -> Bool {
        guard RuntimeLifecyclePolicy.requiresAccessibilityTrustForDesktopItems(interactionPolicy) else {
            return true
        }
        return DesktopInteractionGate.hasAccessibilityTrust()
    }

    private func setMouseMonitorActive(_ active: Bool) {
        if active {
            mouseMonitor?.start()
        } else {
            mouseMonitor?.stop()
            interaction.resetPointerTracking()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard shouldHandleDirectMouseEvents else { return }
        guard let point = interactionContentPoint(from: event) else {
            recordDirectInteraction(event: "move", decision: "outsideContentIgnored", point: nil, delivered: false)
            return
        }
        interaction.pointerMoved(to: point)
        recordDirectInteraction(event: "move", decision: "delivered", point: point, delivered: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard shouldHandleDirectMouseEvents else { return }
        guard let point = interactionContentPoint(from: event) else {
            recordDirectInteraction(event: "drag", decision: "outsideContentIgnored", point: nil, delivered: false)
            return
        }
        interaction.pointerMoved(to: point)
        recordDirectInteraction(event: "drag", decision: "delivered", point: point, delivered: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard shouldHandleDirectMouseEvents else { return }
        guard let point = interactionContentPoint(from: event) else {
            recordDirectInteraction(event: "leftDown", decision: "outsideContent", point: nil, delivered: false)
            return
        }
        interaction.pointerDown(at: point, button: .left)
        recordDirectInteraction(event: "leftDown", decision: "delivered", point: point, delivered: true)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard shouldHandleDirectMouseEvents else { return }
        guard let point = interactionContentPoint(from: event) else {
            recordDirectInteraction(event: "rightDown", decision: "outsideContent", point: nil, delivered: false)
            return
        }
        interaction.pointerDown(at: point, button: .right)
        recordDirectInteraction(event: "rightDown", decision: "delivered", point: point, delivered: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard shouldHandleDirectMouseEvents else { return }
        let point = interactionContentPoint(from: event) ?? CGPoint(x: 0.5, y: 0.5)
        interaction.pointerUp(at: point, button: .left)
        recordDirectInteraction(event: "leftUp", decision: "delivered", point: point, delivered: true)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard shouldHandleDirectMouseEvents else { return }
        let point = interactionContentPoint(from: event) ?? CGPoint(x: 0.5, y: 0.5)
        interaction.pointerUp(at: point, button: .right)
        recordDirectInteraction(event: "rightUp", decision: "delivered", point: point, delivered: true)
    }

    private var shouldHandleDirectMouseEvents: Bool {
        RuntimeLifecyclePolicy.shouldRouteDirectWallpaperMouseEvents(
            interactionPolicy: interactionPolicy
        )
    }

    private func interactionContentPoint(from event: NSEvent) -> CGPoint? {
        interactionContentPoint(fromWindowNormalized: normalizedPoint(from: event))
    }

    private func interactionContentPoint(fromWindowNormalized point: CGPoint) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return interactionCoordinateMapper.mapWindowNormalizedPoint(
            point,
            viewAspect: bounds.width / bounds.height
        )
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

    private func recordDirectInteraction(
        event: String,
        decision: String,
        point: CGPoint?,
        delivered: Bool
    ) {
        if delivered {
            directDeliveredEvents += 1
        } else {
            directBlockedEvents += 1
        }
        let interactionSnapshot = interaction.snapshot()
        runtime.telemetry.recordInteraction(
            displayName: displayName,
            role: displayRole,
            snapshot: InteractionMonitorTelemetrySnapshot(
                active: interactionPolicy.mode != .disabled,
                eventTapActive: false,
                localMonitorActive: false,
                globalMonitorCount: 0,
                lastSource: "direct",
                lastEvent: event,
                lastDecision: decision,
                lastPoint: point.map(Self.formatNormalizedPoint) ?? "none",
                lastCommand: interactionSnapshot.command,
                lastClickPulse: Double(interactionSnapshot.clickPulse),
                deliveredEvents: directDeliveredEvents,
                blockedEvents: directBlockedEvents
            )
        )
    }

    private static func formatNormalizedPoint(_ point: CGPoint) -> String {
        String(format: "%.3f,%.3f", point.x, point.y)
    }
}
