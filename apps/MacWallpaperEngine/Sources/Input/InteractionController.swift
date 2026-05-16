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
    private let plan: InteractionPlan

    init(
        interactions: [InteractionConfig],
        policy: InteractionPolicy?,
        actionTailDurations: [String: CFTimeInterval] = [:]
    ) {
        self.defaultClickTailDuration = policy?.defaultClickTailSeconds ?? 1.15
        self.releaseFadeDuration = policy?.releaseFadeSeconds ?? 0.20
        self.activeClickTailDuration = policy?.defaultClickTailSeconds ?? 1.15
        self.plan = InteractionPlan(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations
        )
    }

    func snapshot() -> InteractionSnapshot {
        lock.lock()
        defer { lock.unlock() }

        advanceSmoothedPointerLocked()
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
                pointer: smoothedPointerState,
                command: clickCommandState,
                clickPulse: min(max(pulse, 0.0), 1.0)
            )
        }

        clickCommandState = nil
        return InteractionSnapshot(
            pointer: smoothedPointerState,
            command: moveCommandState,
            clickPulse: 0.0
        )
    }

    func pointerMoved(to normalizedPoint: CGPoint) {
        let pointer = clamp(normalizedPoint)

        lock.lock()
        pointerState = pointer
        lock.unlock()
    }

    func pointerDown(at normalizedPoint: CGPoint, button: PointerButton = .left) {
        let pointer = clamp(normalizedPoint)
        let hitResult = plan.hitTest(point: pointer, button: button)

        let now = CACurrentMediaTime()
        lock.lock()
        pointerState = pointer
        smoothedPointerState = pointer
        pressStartedAt = now
        pressedButton = button
        pressedHitAction = hitResult?.action
        pressedHitTrigger = hitResult?.trigger ?? .tap
        pressedHitTailDuration = hitResult?.tailSeconds ?? defaultClickTailDuration
        clickCommandState = nil
        clickCommandHeld = false
        clickCommandExpiresAt = 0
        activeClickTailDuration = pressedHitTailDuration
        if let hitResult {
            let trigger = hitResult.trigger
            let hitAction = hitResult.action
            clickCommandState = hitAction
            clickCommandHeld = trigger == .hold
            clickCommandExpiresAt = now + (trigger == .hold ? releaseFadeDuration : pressedHitTailDuration)
            moveCommandState = "idle"
        } else {
            moveCommandState = plan.command(for: pointer, previousCommand: moveCommandState)
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
            activeClickTailDuration = max(pressedHitTailDuration, releaseFadeDuration)
            clickCommandExpiresAt = now + activeClickTailDuration
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
        let now = CACurrentMediaTime()
        pointerState = CGPoint(x: 0.5, y: 0.5)
        smoothedPointerState = CGPoint(x: 0.5, y: 0.5)
        moveCommandState = "idle"
        if clickCommandHeld {
            clickCommandHeld = false
            activeClickTailDuration = releaseFadeDuration
            clickCommandExpiresAt = now + releaseFadeDuration
        } else if clickCommandState == nil || now >= clickCommandExpiresAt {
            clickCommandState = nil
            clickCommandExpiresAt = 0
        }
        pressedHitAction = nil
        pressedHitTrigger = nil
        pressedHitTailDuration = 0
        pressedButton = nil
        lock.unlock()
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        plan.clamp(point)
    }

    private func advanceSmoothedPointerLocked() {
        smoothedPointerState = plan.smooth(current: smoothedPointerState, target: pointerState)
        moveCommandState = plan.command(for: smoothedPointerState, previousCommand: moveCommandState)
    }
}
