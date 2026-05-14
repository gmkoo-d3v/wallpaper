import CoreGraphics
import Foundation
import QuartzCore

struct InteractionSnapshot {
    let pointer: CGPoint
    let command: String
    let clickPulse: CGFloat
}

final class InteractionController {
    private let defaultClickTailDuration: CFTimeInterval
    private let releaseFadeDuration: CFTimeInterval
    private let pointerSmoothing: CGFloat
    private let idleDeadZone: CGFloat
    private let directionSwitchMargin: CGFloat
    private let lock = NSLock()
    private var pointerState = CGPoint(x: 0.5, y: 0.5)
    private var smoothedPointerState = CGPoint(x: 0.5, y: 0.5)
    private var moveCommandState = "idle"
    private var clickCommandState: String?
    private var clickCommandExpiresAt: CFTimeInterval = 0
    private var clickCommandHeld = false
    private var activeClickTailDuration: CFTimeInterval
    private var pressedHitAction: String?
    private var pressedHitTrigger: HitZoneTrigger?
    private var pressedHitTailDuration: CFTimeInterval = 0
    private var pressedButton: PointerButton?
    private var pressStartedAt: CFTimeInterval = 0
    private let interactions: [InteractionConfig]

    init(interactions: [InteractionConfig], policy: InteractionPolicy?) {
        self.interactions = interactions
        self.defaultClickTailDuration = policy?.defaultClickTailSeconds ?? 1.15
        self.releaseFadeDuration = policy?.releaseFadeSeconds ?? 0.20
        self.pointerSmoothing = CGFloat(policy?.pointerSmoothing ?? 0.18)
        self.idleDeadZone = CGFloat(policy?.idleDeadZone ?? 0.18)
        self.directionSwitchMargin = CGFloat(policy?.directionSwitchMargin ?? 0.10)
        self.activeClickTailDuration = policy?.defaultClickTailSeconds ?? 1.15
    }

    func snapshot() -> InteractionSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        if let pressedHitAction, pressedHitTrigger == .hold {
            clickCommandState = pressedHitAction
            clickCommandHeld = true
            clickCommandExpiresAt = now + releaseFadeDuration
        }
        if let clickCommandState, clickCommandHeld || now < clickCommandExpiresAt {
            let fadeDuration = clickCommandHeld ? releaseFadeDuration : max(activeClickTailDuration, 0.001)
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
            command: moveCommandState,
            clickPulse: 0.0
        )
    }

    func pointerMoved(to normalizedPoint: CGPoint) {
        let pointer = clamp(normalizedPoint)

        lock.lock()
        let smoothedPointer = smooth(current: smoothedPointerState, target: pointer)
        pointerState = pointer
        smoothedPointerState = smoothedPointer
        moveCommandState = command(for: smoothedPointer)
        lock.unlock()
    }

    func pointerDown(at normalizedPoint: CGPoint, button: PointerButton = .left) {
        let pointer = clamp(normalizedPoint)
        let hitZone = hitZone(at: pointer, button: button)

        let now = CACurrentMediaTime()
        lock.lock()
        pointerState = pointer
        smoothedPointerState = pointer
        pressStartedAt = now
        pressedButton = button
        pressedHitAction = hitZone?.action
        pressedHitTrigger = hitZone?.trigger ?? .tap
        pressedHitTailDuration = hitZone?.tailSeconds ?? defaultClickTailDuration
        clickCommandState = nil
        clickCommandHeld = false
        clickCommandExpiresAt = 0
        activeClickTailDuration = pressedHitTailDuration
        if let hitAction = hitZone?.action {
            let trigger = hitZone?.trigger ?? .tap
            clickCommandState = hitAction
            clickCommandHeld = trigger == .hold
            clickCommandExpiresAt = now + (trigger == .hold ? releaseFadeDuration : pressedHitTailDuration)
            moveCommandState = "idle"
        } else {
            moveCommandState = command(for: pointer)
        }
        lock.unlock()
    }

    func pointerUp(at normalizedPoint: CGPoint, button: PointerButton = .left) {
        _ = button
        let pointer = clamp(normalizedPoint)
        let now = CACurrentMediaTime()
        lock.lock()
        pointerState = pointer
        guard pressedButton == nil || pressedButton == button else {
            lock.unlock()
            return
        }
        if let pressedHitAction, pressedHitTrigger == .tap {
            clickCommandState = pressedHitAction
            clickCommandHeld = false
            activeClickTailDuration = pressedHitTailDuration
            clickCommandExpiresAt = max(clickCommandExpiresAt, now + pressedHitTailDuration)
        } else if let pressedHitAction, pressedHitTrigger == .hold {
            clickCommandState = pressedHitAction
            clickCommandHeld = false
            activeClickTailDuration = releaseFadeDuration
            clickCommandExpiresAt = now + releaseFadeDuration
        }
        pressedHitAction = nil
        pressedHitTrigger = nil
        pressedHitTailDuration = 0
        pressedButton = nil
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
            activeClickTailDuration = releaseFadeDuration
            clickCommandExpiresAt = CACurrentMediaTime() + releaseFadeDuration
        } else {
            clickCommandState = nil
            clickCommandExpiresAt = 0
        }
        pressedHitAction = nil
        pressedHitTrigger = nil
        pressedHitTailDuration = 0
        pressedButton = nil
        lock.unlock()
    }

    private func hitZone(at pointer: CGPoint, button: PointerButton) -> HitZone? {
        guard let config = interactions.first(where: { $0.event == .pointerDown }),
              let hitZones = config.hitZones else {
            return nil
        }
        let interactionButtons = config.buttons ?? [.left]
        guard interactionButtons.contains(button) else { return nil }
        for hitZone in hitZones {
            let zoneButtons = hitZone.buttons ?? interactionButtons
            guard zoneButtons.contains(button) else { continue }
            guard hitZone.rect.count == 4 else { continue }
            let x0 = hitZone.rect[0]
            let y0 = hitZone.rect[1]
            let x1 = hitZone.rect[2]
            let y1 = hitZone.rect[3]
            if Double(pointer.x) >= x0,
               Double(pointer.x) <= x1,
               Double(pointer.y) >= y0,
               Double(pointer.y) <= y1 {
                return hitZone
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
