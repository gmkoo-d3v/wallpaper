import AppKit
import ApplicationServices
import QuartzCore

final class DesktopMouseInteractionMonitor {
    private weak var window: NSWindow?
    private let policy: InteractionPolicy
    private let onMove: (CGPoint) -> Void
    private let onDown: (CGPoint, PointerButton) -> Void
    private let onUp: (CGPoint, PointerButton) -> Void
    private let onExit: () -> Void
    private let currentInteractionSnapshot: () -> InteractionSnapshot?
    private let onTelemetry: (InteractionMonitorTelemetrySnapshot) -> Void
    private var monitors: [Any] = []
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private let moveEventMinInterval: CFTimeInterval = 1.0 / 30.0
    private let discreteEventDuplicateInterval: CFTimeInterval = 0.05
    private let discreteEventDuplicateDistanceSquared: CGFloat = 3 * 3
    private let eligibilityCacheInterval: CFTimeInterval = 0.15
    private let eligibilityCacheDistanceSquared: CGFloat = 24 * 24
    private var lastMoveEventAt: CFTimeInterval = 0
    private var lastDiscreteEventAt: CFTimeInterval = 0
    private var lastDiscreteEventLabel: String?
    private var lastDiscreteEventPoint: CGPoint?
    private var lastEligibilityCheckAt: CFTimeInterval = 0
    private var lastEligibilityPoint: CGPoint?
    private var lastEligibilityDecision: DesktopInteractionGate.EligibilityDecision = .blockedDisabled
    private var isActive = false
    private var lastSource = "none"
    private var lastEvent = "none"
    private var lastDecision = "not-started"
    private var lastPoint = "none"
    private var deliveredEvents = 0
    private var blockedEvents = 0

    private enum EventKind {
        case move
        case down(PointerButton)
        case up(PointerButton)

        var label: String {
            switch self {
            case .move:
                return "move"
            case .down(let button):
                return "\(button.rawValue)Down"
            case .up(let button):
                return "\(button.rawValue)Up"
            }
        }
    }

    struct InputSources: Equatable {
        let useEventTap: Bool
        let useLocalMonitor: Bool
        let useGlobalMonitors: Bool
    }

    init(
        window: NSWindow,
        policy: InteractionPolicy,
        onMove: @escaping (CGPoint) -> Void,
        onDown: @escaping (CGPoint, PointerButton) -> Void,
        onUp: @escaping (CGPoint, PointerButton) -> Void,
        onExit: @escaping () -> Void,
        currentInteractionSnapshot: @escaping () -> InteractionSnapshot? = { nil },
        onTelemetry: @escaping (InteractionMonitorTelemetrySnapshot) -> Void = { _ in }
    ) {
        self.window = window
        self.policy = policy
        self.onMove = onMove
        self.onDown = onDown
        self.onUp = onUp
        self.onExit = onExit
        self.currentInteractionSnapshot = currentInteractionSnapshot
        self.onTelemetry = onTelemetry
    }

    deinit {
        stop()
    }

    func start() {
        guard policy.mode != .disabled else {
            isActive = false
            publishTelemetry(source: "lifecycle", event: "start", decision: "disabled")
            return
        }
        let usesPassiveEventMonitoring = window?.ignoresMouseEvents ?? true
        let eventTapStarted = usesPassiveEventMonitoring ? startEventTap() : false
        let inputSources = Self.inputSources(
            usesPassiveEventMonitoring: usesPassiveEventMonitoring,
            eventTapStarted: eventTapStarted
        )
        isActive = true
        guard localMonitor == nil, monitors.isEmpty else {
            publishTelemetry(
                source: "lifecycle",
                event: "start",
                decision: startDecision(inputSources: inputSources)
            )
            return
        }

        if inputSources.useLocalMonitor {
            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [
                    .mouseMoved,
                    .leftMouseDragged,
                    .rightMouseDragged,
                    .leftMouseDown,
                    .leftMouseUp,
                    .rightMouseDown,
                    .rightMouseUp
                ],
                handler: { [weak self] event in
                    self?.handleLocal(event: event)
                    return event
                }
            )
        }

        if inputSources.useGlobalMonitors {
            addGlobalMoveMonitor()
            addGlobalClickMonitors()
        }
        publishTelemetry(
            source: "lifecycle",
            event: "start",
            decision: startDecision(inputSources: inputSources)
        )
    }

    func stop() {
        stopEventTap()
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        resetEligibilityCache()
        isActive = false
        publishTelemetry(source: "lifecycle", event: "stop", decision: "inactive")
    }

    private func startEventTap() -> Bool {
        guard eventTap == nil, eventTapRunLoopSource == nil else { return true }

        let eventTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp
        ]
        let eventMask = eventTypes.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }

        let opaqueSelf = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<DesktopMouseInteractionMonitor>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                monitor.handleCGEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: opaqueSelf
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopEventTap() {
        if let source = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapRunLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    private func addGlobalMoveMonitor() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged],
            handler: { [weak self] event in
                self?.handle(event: event, kind: .move)
            }
        ) {
            monitors.append(monitor)
        }
    }

    private func addGlobalClickMonitors() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown],
            handler: { [weak self] event in
                self?.handle(event: event, kind: .down(.left))
            }
        ) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp],
            handler: { [weak self] event in
                self?.handle(event: event, kind: .up(.left))
            }
        ) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.rightMouseDown],
            handler: { [weak self] event in
                self?.handle(event: event, kind: .down(.right))
            }
        ) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.rightMouseUp],
            handler: { [weak self] event in
                self?.handle(event: event, kind: .up(.right))
            }
        ) {
            monitors.append(monitor)
        }
    }

    static func inputSources(usesPassiveEventMonitoring: Bool, eventTapStarted: Bool) -> InputSources {
        if usesPassiveEventMonitoring {
            return InputSources(
                useEventTap: eventTapStarted,
                useLocalMonitor: false,
                useGlobalMonitors: eventTapStarted == false
            )
        }
        return InputSources(
            useEventTap: false,
            useLocalMonitor: true,
            useGlobalMonitors: false
        )
    }

    private func startDecision(inputSources: InputSources) -> String {
        if inputSources.useEventTap {
            return "activeEventTap"
        }
        if inputSources.useLocalMonitor {
            return "activeLocalMouse"
        }
        if inputSources.useGlobalMonitors {
            return "globalFallback"
        }
        return "eventTapUnavailable"
    }

    private func handleLocal(event: NSEvent) {
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            handle(event: event, kind: .move)
        case .leftMouseDown:
            handle(event: event, kind: .down(.left))
        case .leftMouseUp:
            handle(event: event, kind: .up(.left))
        case .rightMouseDown:
            handle(event: event, kind: .down(.right))
        case .rightMouseUp:
            handle(event: event, kind: .up(.right))
        default:
            break
        }
    }

    private func handle(event: NSEvent, kind: EventKind) {
        guard let window else { return }
        if case .move = kind {
            let now = CACurrentMediaTime()
            guard now - lastMoveEventAt >= moveEventMinInterval else { return }
            lastMoveEventAt = now
        }

        let screenPoint = NSEvent.mouseLocation
        guard window.frame.contains(screenPoint) else {
            recordBlocked(source: "nsevent", kind: kind, decision: "outsideWindow", point: screenPoint)
            onExit()
            return
        }
        guard shouldAcceptDiscreteEvent(kind: kind, screenPoint: screenPoint) else { return }
        let isMouseUpEvent: Bool
        switch kind {
        case .up:
            isMouseUpEvent = true
        case .move, .down:
            isMouseUpEvent = false
        }
        if !isMouseUpEvent {
            let decision = eligibilityDecision(screenPoint: screenPoint, event: event)
            guard decision == .eligible else {
                recordBlocked(source: "nsevent", kind: kind, decision: decision.rawValue, point: screenPoint)
                onExit()
                return
            }
        }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        guard let contentView = window.contentView else { return }
        let local = contentView.convert(windowPoint, from: nil)
        guard contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }

        let normalized = CGPoint(
            x: min(max(local.x / contentView.bounds.width, 0.0), 1.0),
            y: min(max(1.0 - (local.y / contentView.bounds.height), 0.0), 1.0)
        )
        switch kind {
        case .down(let button):
            onDown(normalized, button)
        case .up(let button):
            onUp(normalized, button)
        case .move:
            onMove(normalized)
        }
        recordDelivered(source: "nsevent", kind: kind, normalized: normalized)
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        default:
            break
        }

        guard let kind = Self.eventKind(for: type), let window else { return }
        if case .move = kind {
            let now = CACurrentMediaTime()
            guard now - lastMoveEventAt >= moveEventMinInterval else { return }
            lastMoveEventAt = now
        }

        let screenPoint = NSEvent.mouseLocation
        guard window.frame.contains(screenPoint) else {
            recordBlocked(source: "cgevent", kind: kind, decision: "outsideWindow", point: screenPoint)
            onExit()
            return
        }
        guard shouldAcceptDiscreteEvent(kind: kind, screenPoint: screenPoint) else { return }

        let isMouseUpEvent: Bool
        switch kind {
        case .up:
            isMouseUpEvent = true
        case .move, .down:
            isMouseUpEvent = false
        }
        if !isMouseUpEvent {
            let decision = eligibilityDecision(screenPoint: screenPoint, event: nil)
            guard decision == .eligible else {
                recordBlocked(source: "cgevent", kind: kind, decision: decision.rawValue, point: screenPoint)
                onExit()
                return
            }
        }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        guard let contentView = window.contentView else { return }
        let local = contentView.convert(windowPoint, from: nil)
        guard contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }

        let normalized = CGPoint(
            x: min(max(local.x / contentView.bounds.width, 0.0), 1.0),
            y: min(max(1.0 - (local.y / contentView.bounds.height), 0.0), 1.0)
        )
        switch kind {
        case .down(let button):
            onDown(normalized, button)
        case .up(let button):
            onUp(normalized, button)
        case .move:
            onMove(normalized)
        }
        recordDelivered(source: "cgevent", kind: kind, normalized: normalized)
        _ = event
    }

    static func eventKindName(for type: CGEventType) -> String? {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            return "move"
        case .leftMouseDown:
            return "leftDown"
        case .leftMouseUp:
            return "leftUp"
        case .rightMouseDown:
            return "rightDown"
        case .rightMouseUp:
            return "rightUp"
        default:
            return nil
        }
    }

    static func isDuplicateDiscreteEvent(
        label: String,
        screenPoint: CGPoint,
        previousLabel: String?,
        previousPoint: CGPoint?,
        elapsedSeconds: CFTimeInterval,
        maxInterval: CFTimeInterval,
        maxDistanceSquared: CGFloat
    ) -> Bool {
        guard label != "move",
              let previousLabel,
              let previousPoint,
              previousLabel == label,
              elapsedSeconds >= 0,
              elapsedSeconds <= maxInterval else {
            return false
        }

        let dx = screenPoint.x - previousPoint.x
        let dy = screenPoint.y - previousPoint.y
        return (dx * dx) + (dy * dy) <= maxDistanceSquared
    }

    private static func eventKind(for type: CGEventType) -> EventKind? {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            return .move
        case .leftMouseDown:
            return .down(.left)
        case .leftMouseUp:
            return .up(.left)
        case .rightMouseDown:
            return .down(.right)
        case .rightMouseUp:
            return .up(.right)
        default:
            return nil
        }
    }

    private func eligibilityDecision(
        screenPoint: CGPoint,
        event: NSEvent?
    ) -> DesktopInteractionGate.EligibilityDecision {
        if let cached = cachedEligibility(screenPoint: screenPoint) {
            return cached
        }

        if policy.mode == .always {
            cacheEligibility(.eligible, screenPoint: screenPoint)
            return .eligible
        }
        if policy.mode == .disabled {
            cacheEligibility(.blockedDisabled, screenPoint: screenPoint)
            return .blockedDisabled
        }

        let accessibilityTrusted = policy.blockDesktopItems == false || DesktopInteractionGate.hasAccessibilityTrust()
        let coveredByApplicationWindow = policy.blockApplicationWindows
            && DesktopInteractionGate.isCoveredByApplicationWindow(screenPoint: screenPoint)
        let likelyDesktopItem = policy.blockDesktopItems
            && accessibilityTrusted
            && (
                event.map { DesktopInteractionGate.isLikelyDesktopItem(event: $0, screenPoint: screenPoint) } ?? false
                    || DesktopInteractionGate.isLikelyDesktopItem(screenPoint: screenPoint)
            )
        let decision = DesktopInteractionGate.eligibilityDecision(
            policy: policy,
            accessibilityTrusted: accessibilityTrusted,
            coveredByApplicationWindow: coveredByApplicationWindow,
            likelyDesktopItem: likelyDesktopItem
        )
        cacheEligibility(decision, screenPoint: screenPoint)
        return decision
    }

    private func shouldAcceptDiscreteEvent(kind: EventKind, screenPoint: CGPoint) -> Bool {
        guard kind.label != "move" else { return true }

        let now = CACurrentMediaTime()
        let duplicate = Self.isDuplicateDiscreteEvent(
            label: kind.label,
            screenPoint: screenPoint,
            previousLabel: lastDiscreteEventLabel,
            previousPoint: lastDiscreteEventPoint,
            elapsedSeconds: now - lastDiscreteEventAt,
            maxInterval: discreteEventDuplicateInterval,
            maxDistanceSquared: discreteEventDuplicateDistanceSquared
        )
        if duplicate {
            return false
        }

        lastDiscreteEventAt = now
        lastDiscreteEventLabel = kind.label
        lastDiscreteEventPoint = screenPoint
        return true
    }

    private func cachedEligibility(screenPoint: CGPoint) -> DesktopInteractionGate.EligibilityDecision? {
        guard let lastEligibilityPoint else { return nil }
        let now = CACurrentMediaTime()
        let dx = screenPoint.x - lastEligibilityPoint.x
        let dy = screenPoint.y - lastEligibilityPoint.y
        guard now - lastEligibilityCheckAt < eligibilityCacheInterval,
              (dx * dx) + (dy * dy) < eligibilityCacheDistanceSquared else {
            return nil
        }
        return lastEligibilityDecision
    }

    private func cacheEligibility(_ decision: DesktopInteractionGate.EligibilityDecision, screenPoint: CGPoint) {
        lastEligibilityCheckAt = CACurrentMediaTime()
        lastEligibilityPoint = screenPoint
        lastEligibilityDecision = decision
    }

    private func resetEligibilityCache() {
        lastEligibilityCheckAt = 0
        lastEligibilityPoint = nil
        lastEligibilityDecision = .blockedDisabled
        lastMoveEventAt = 0
        lastDiscreteEventAt = 0
        lastDiscreteEventLabel = nil
        lastDiscreteEventPoint = nil
    }

    private func recordDelivered(source: String, kind: EventKind, normalized: CGPoint) {
        deliveredEvents += 1
        publishTelemetry(
            source: source,
            event: kind.label,
            decision: "delivered",
            point: formatNormalizedPoint(normalized)
        )
    }

    private func recordBlocked(source: String, kind: EventKind, decision: String, point: CGPoint) {
        blockedEvents += 1
        publishTelemetry(
            source: source,
            event: kind.label,
            decision: decision,
            point: formatScreenPoint(point)
        )
    }

    private func publishTelemetry(
        source: String,
        event: String,
        decision: String,
        point: String? = nil
    ) {
        lastSource = source
        lastEvent = event
        lastDecision = decision
        if let point {
            lastPoint = point
        }
        let interaction = currentInteractionSnapshot()
        onTelemetry(InteractionMonitorTelemetrySnapshot(
            active: isActive,
            eventTapActive: eventTap != nil,
            localMonitorActive: localMonitor != nil,
            globalMonitorCount: monitors.count,
            lastSource: lastSource,
            lastEvent: lastEvent,
            lastDecision: lastDecision,
            lastPoint: lastPoint,
            lastCommand: interaction?.command ?? "unknown",
            lastClickPulse: Double(interaction?.clickPulse ?? 0),
            deliveredEvents: deliveredEvents,
            blockedEvents: blockedEvents
        ))
    }

    private func formatNormalizedPoint(_ point: CGPoint) -> String {
        String(format: "%.3f,%.3f", point.x, point.y)
    }

    private func formatScreenPoint(_ point: CGPoint) -> String {
        "\(Int(point.x.rounded())),\(Int(point.y.rounded()))"
    }
}

enum DesktopInteractionGate {
    enum EligibilityDecision: String {
        case eligible
        case blockedDisabled
        case blockedAccessibilityTrust
        case blockedApplicationWindow
        case blockedDesktopItem
    }

    static func eligibilityDecision(
        policy: InteractionPolicy,
        accessibilityTrusted: Bool,
        coveredByApplicationWindow: Bool,
        likelyDesktopItem: Bool
    ) -> EligibilityDecision {
        switch policy.mode {
        case .disabled:
            return .blockedDisabled
        case .always:
            return .eligible
        case .desktopEmptyOnly:
            if policy.blockDesktopItems && accessibilityTrusted == false {
                return .blockedAccessibilityTrust
            }
            if policy.blockApplicationWindows && coveredByApplicationWindow {
                return .blockedApplicationWindow
            }
            if policy.blockDesktopItems && likelyDesktopItem {
                return .blockedDesktopItem
            }
            return .eligible
        }
    }

    static func hasAccessibilityTrust() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityTrustPrompt() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    static func isCoveredByApplicationWindow(screenPoint: CGPoint) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return true
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t ?? -1
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            let windowName = window[kCGWindowName as String] as? String ?? ""
            if shouldIgnoreApplicationWindowForInteraction(
                ownerPID: ownerPID,
                windowName: windowName,
                currentPID: currentPID
            ) {
                continue
            }

            if ["Finder", "Dock", "SystemUIServer"].contains(ownerName) {
                continue
            }

            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.01 else { continue }

            guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                continue
            }
            guard bounds.width > 32, bounds.height > 32 else { continue }

            if contains(bounds: bounds, appKitPoint: screenPoint) {
                return true
            }
        }

        return false
    }

    static func shouldIgnoreApplicationWindowForInteraction(
        ownerPID: pid_t,
        windowName: String,
        currentPID: pid_t
    ) -> Bool {
        guard ownerPID == currentPID else { return false }
        return windowName == "Mac Wallpaper Engine Diagnostic"
    }

    static func isLikelyDesktopItem(event: NSEvent, screenPoint: CGPoint) -> Bool {
        if event.windowNumber <= 0 {
            return false
        }

        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(event.windowNumber)) as? [[String: Any]],
              let windowInfo = info.first else {
            return false
        }

        let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? ""
        guard ownerName == "Finder" else {
            return false
        }

        guard AXIsProcessTrusted() else {
            return false
        }

        return accessibilityElementLooksInteractive(at: screenPoint, conservativeOnError: true)
    }

    static func isLikelyDesktopItem(screenPoint: CGPoint) -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }

        return accessibilityElementLooksInteractive(at: screenPoint, conservativeOnError: false)
    }

    private static func accessibilityElementLooksInteractive(at screenPoint: CGPoint, conservativeOnError: Bool) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var rawElement: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(screenPoint.x),
            Float(screenPoint.y),
            &rawElement
        )
        guard error == .success, let element = rawElement else {
            return conservativeOnError
        }

        var rawRole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole)
        let role = rawRole as? String ?? ""

        let interactiveRoles: Set<String> = [
            kAXButtonRole as String,
            kAXImageRole as String,
            kAXStaticTextRole as String,
            "AXIcon"
        ]
        return interactiveRoles.contains(role)
    }

    private static func contains(bounds: CGRect, appKitPoint: CGPoint) -> Bool {
        if bounds.contains(appKitPoint) {
            return true
        }

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }) else {
            return false
        }
        let flipped = CGPoint(
            x: appKitPoint.x,
            y: screen.frame.maxY - (appKitPoint.y - screen.frame.minY)
        )
        return bounds.contains(flipped)
    }
}
