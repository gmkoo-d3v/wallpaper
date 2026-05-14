import CoreGraphics
import Foundation
import QuartzCore

struct InteractionSnapshot {
    let pointer: CGPoint
    let command: String
    let clickPulse: CGFloat
}

final class InteractionController {
    private let clickTailDuration: CFTimeInterval = 1.15
    private let releaseFadeDuration: CFTimeInterval = 0.20
    private let pointerSmoothing: CGFloat = 0.18
    private let idleDeadZone: CGFloat = 0.18
    private let directionSwitchMargin: CGFloat = 0.10
    private let lock = NSLock()
    private var pointerState = CGPoint(x: 0.5, y: 0.5)
    private var smoothedPointerState = CGPoint(x: 0.5, y: 0.5)
    private var moveCommandState = "idle"
    private var clickCommandState: String?
    private var clickCommandExpiresAt: CFTimeInterval = 0
    private var clickCommandHeld = false
    private var pressedHitAction: String?
    private var pressStartedAt: CFTimeInterval = 0
    private var lookTrackingHeld = false
    private let interactions: [InteractionConfig]

    init(interactions: [InteractionConfig]) {
        self.interactions = interactions
    }

    func snapshot() -> InteractionSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        if pressedHitAction == "boll" {
            clickCommandState = "boll"
            clickCommandHeld = true
            clickCommandExpiresAt = now + releaseFadeDuration
        }
        if let clickCommandState, clickCommandHeld || now < clickCommandExpiresAt {
            let fadeDuration = clickCommandState == "boll" ? releaseFadeDuration : clickTailDuration
            let pulse = clickCommandHeld ? 1.0 : CGFloat((clickCommandExpiresAt - now) / fadeDuration)
            return InteractionSnapshot(
                pointer: pointerState,
                command: clickCommandState,
                clickPulse: min(max(pulse, 0.0), 1.0)
            )
        }

        clickCommandState = nil
        return InteractionSnapshot(
            pointer: pointerState,
            command: lookTrackingHeld ? moveCommandState : "idle",
            clickPulse: 0.0
        )
    }

    func pointerMoved(to normalizedPoint: CGPoint) {
        let pointer = clamp(normalizedPoint)

        lock.lock()
        let smoothedPointer = smooth(current: smoothedPointerState, target: pointer)
        pointerState = pointer
        smoothedPointerState = smoothedPointer
        if lookTrackingHeld {
            moveCommandState = command(for: smoothedPointer)
        }
        lock.unlock()
    }

    func pointerDown(at normalizedPoint: CGPoint) {
        let pointer = clamp(normalizedPoint)
        let hitAction = hitAction(at: pointer)

        let now = CACurrentMediaTime()
        lock.lock()
        pointerState = pointer
        smoothedPointerState = pointer
        pressStartedAt = now
        pressedHitAction = hitAction
        clickCommandState = nil
        clickCommandHeld = false
        clickCommandExpiresAt = 0
        if let hitAction {
            clickCommandState = hitAction
            clickCommandHeld = hitAction == "boll"
            clickCommandExpiresAt = now + (hitAction == "boll" ? releaseFadeDuration : clickTailDuration)
            lookTrackingHeld = false
            moveCommandState = "idle"
        } else {
            lookTrackingHeld = true
            moveCommandState = command(for: pointer)
        }
        lock.unlock()
    }

    func pointerUp(at normalizedPoint: CGPoint) {
        let pointer = clamp(normalizedPoint)
        let now = CACurrentMediaTime()
        lock.lock()
        pointerState = pointer
        if pressedHitAction == "act" {
            clickCommandState = "act"
            clickCommandHeld = false
            clickCommandExpiresAt = max(clickCommandExpiresAt, now + clickTailDuration)
        } else if pressedHitAction == "boll" || clickCommandState == "boll" {
            clickCommandState = "boll"
            clickCommandHeld = false
            clickCommandExpiresAt = now + releaseFadeDuration
        }
        pressedHitAction = nil
        lookTrackingHeld = false
        moveCommandState = "idle"
        lock.unlock()
    }

    func pointerTrackingStopped() {
        lock.lock()
        pointerState = CGPoint(x: 0.5, y: 0.5)
        smoothedPointerState = CGPoint(x: 0.5, y: 0.5)
        moveCommandState = "idle"
        if clickCommandHeld {
            clickCommandHeld = false
            clickCommandExpiresAt = CACurrentMediaTime() + releaseFadeDuration
        } else {
            clickCommandState = nil
            clickCommandExpiresAt = 0
        }
        pressedHitAction = nil
        lookTrackingHeld = false
        lock.unlock()
    }

    func needsPointerPolling() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lookTrackingHeld
    }

    private func hitAction(at pointer: CGPoint) -> String? {
        guard let config = interactions.first(where: { $0.event == .pointerDown }),
              let hitZones = config.hitZones else {
            return nil
        }
        for hitZone in hitZones {
            guard hitZone.rect.count == 4 else { continue }
            let x0 = hitZone.rect[0]
            let y0 = hitZone.rect[1]
            let x1 = hitZone.rect[2]
            let y1 = hitZone.rect[3]
            if Double(pointer.x) >= x0,
               Double(pointer.x) <= x1,
               Double(pointer.y) >= y0,
               Double(pointer.y) <= y1 {
                return hitZone.action
            }
        }
        return nil
    }

    private func command(for pointer: CGPoint) -> String {
        guard let config = interactions.first(where: { $0.event == .pointerMove }),
              config.mapping == "lookDirection",
              let actions = config.actions else {
            return "idle"
        }
        let dx = pointer.x - 0.5
        let dy = pointer.y - 0.5
        if abs(dx) < idleDeadZone, abs(dy) < idleDeadZone {
            return actions["idle"] ?? "idle"
        }
        if abs(dx) > abs(dy) + directionSwitchMargin {
            return dx < 0 ? (actions["left"] ?? "Left") : (actions["right"] ?? "Right")
        }
        if abs(dy) > abs(dx) + directionSwitchMargin {
            return dy < 0 ? (actions["up"] ?? "Up") : (actions["down"] ?? "Down")
        }
        return moveCommandState
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0.0), 1.0),
            y: min(max(point.y, 0.0), 1.0)
        )
    }

    private func smooth(current: CGPoint, target: CGPoint) -> CGPoint {
        CGPoint(
            x: current.x + (target.x - current.x) * pointerSmoothing,
            y: current.y + (target.y - current.y) * pointerSmoothing
        )
    }
}
