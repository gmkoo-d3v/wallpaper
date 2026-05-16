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
    private var monitors: [Any] = []
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private let moveEventMinInterval: CFTimeInterval = 1.0 / 30.0
    private let eligibilityCacheInterval: CFTimeInterval = 0.15
    private let eligibilityCacheDistanceSquared: CGFloat = 24 * 24
    private var lastMoveEventAt: CFTimeInterval = 0
    private var lastEligibilityCheckAt: CFTimeInterval = 0
    private var lastEligibilityPoint: CGPoint?
    private var lastEligibility = false

    private enum EventKind {
        case move
        case down(PointerButton)
        case up(PointerButton)
    }

    init(
        window: NSWindow,
        policy: InteractionPolicy,
        onMove: @escaping (CGPoint) -> Void,
        onDown: @escaping (CGPoint, PointerButton) -> Void,
        onUp: @escaping (CGPoint, PointerButton) -> Void,
        onExit: @escaping () -> Void
    ) {
        self.window = window
        self.policy = policy
        self.onMove = onMove
        self.onDown = onDown
        self.onUp = onUp
        self.onExit = onExit
    }

    deinit {
        stop()
    }

    func start() {
        guard policy.mode != .disabled else { return }
        _ = startEventTap()
        guard localMonitor == nil, monitors.isEmpty else { return }

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

        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged],
            handler: { [weak self] event in
                self?.handle(event: event, kind: .move)
            }
        ) {
            monitors.append(monitor)
        }
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
            onExit()
            return
        }
        let isMouseUpEvent: Bool
        switch kind {
        case .up:
            isMouseUpEvent = true
        case .move, .down:
            isMouseUpEvent = false
        }
        if !isMouseUpEvent {
            guard isEligible(screenPoint: screenPoint, event: event) else {
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
            onExit()
            return
        }

        let isMouseUpEvent: Bool
        switch kind {
        case .up:
            isMouseUpEvent = true
        case .move, .down:
            isMouseUpEvent = false
        }
        if !isMouseUpEvent {
            guard isEligible(screenPoint: screenPoint, event: nil) else {
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

    private func isEligible(screenPoint: CGPoint, event: NSEvent?) -> Bool {
        if let cached = cachedEligibility(screenPoint: screenPoint) {
            return cached
        }

        if policy.mode == .always {
            cacheEligibility(true, screenPoint: screenPoint)
            return true
        }
        if policy.mode == .disabled {
            cacheEligibility(false, screenPoint: screenPoint)
            return false
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
        let eligible = decision == .eligible
        cacheEligibility(eligible, screenPoint: screenPoint)
        return eligible
    }

    private func cachedEligibility(screenPoint: CGPoint) -> Bool? {
        guard let lastEligibilityPoint else { return nil }
        let now = CACurrentMediaTime()
        let dx = screenPoint.x - lastEligibilityPoint.x
        let dy = screenPoint.y - lastEligibilityPoint.y
        guard now - lastEligibilityCheckAt < eligibilityCacheInterval,
              (dx * dx) + (dy * dy) < eligibilityCacheDistanceSquared else {
            return nil
        }
        return lastEligibility
    }

    private func cacheEligibility(_ eligible: Bool, screenPoint: CGPoint) {
        lastEligibilityCheckAt = CACurrentMediaTime()
        lastEligibilityPoint = screenPoint
        lastEligibility = eligible
    }

    private func resetEligibilityCache() {
        lastEligibilityCheckAt = 0
        lastEligibilityPoint = nil
        lastEligibility = false
        lastMoveEventAt = 0
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
            if ownerPID == currentPID {
                continue
            }

            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
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
