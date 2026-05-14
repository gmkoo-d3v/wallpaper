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
        guard monitors.isEmpty, policy.mode != .disabled else { return }

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
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        resetEligibilityCache()
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

    private func isEligible(screenPoint: CGPoint, event: NSEvent) -> Bool {
        switch policy.mode {
        case .always:
            return true
        case .disabled:
            return false
        case .desktopEmptyOnly:
            if let cached = cachedEligibility(screenPoint: screenPoint) {
                return cached
            }

            let eligible: Bool
            if policy.blockApplicationWindows,
               DesktopInteractionGate.isCoveredByApplicationWindow(screenPoint: screenPoint) {
                eligible = false
            } else if policy.blockDesktopItems,
                      DesktopInteractionGate.isLikelyDesktopItem(event: event, screenPoint: screenPoint) {
                eligible = false
            } else if policy.blockDesktopItems,
                      DesktopInteractionGate.isLikelyDesktopItem(screenPoint: screenPoint) {
                eligible = false
            } else {
                eligible = true
            }
            cacheEligibility(eligible, screenPoint: screenPoint)
            return eligible
        }
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
