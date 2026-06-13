import CoreGraphics
import Foundation
import QuartzCore

struct InteractionSnapshot {
    let pointer: CGPoint
    let command: String
    let isPointerDown: Bool
    let clickPulse: CGFloat
    let isInputActive: Bool
}

final class InteractionController {
    private let defaultClickTailDuration: CFTimeInterval
    private let releaseFadeDuration: CFTimeInterval
    private let pointerInputActiveTailSeconds: CFTimeInterval = 0.20
    private let lock = NSLock()
    private var pointerState = CGPoint(x: 0.5, y: 0.5)
    private var smoothedPointerState = CGPoint(x: 0.5, y: 0.5)
    private var lastSmoothSampleAt: CFTimeInterval
    private var pointerInputActiveUntil: CFTimeInterval = 0
    private var moveCommandState: String
    private var clickCommandState: String?
    private var clickCommandExpiresAt: CFTimeInterval = 0
    private var clickCommandHeld = false
    private var activeClickTailDuration: CFTimeInterval
    private var pressedHitAction: String?
    private var pressedHitTapAction: String?
    private var pressedHitTrigger: HitZoneTrigger?
    private var pressedHitTailDuration: CFTimeInterval = 0
    private var pressedHitTapTailDuration: CFTimeInterval = 0
    private var pressedHitHoldStartSeconds: CFTimeInterval = 0
    private var pressedHitHoldActivated = false
    private var pressedButton: PointerButton?
    private var pressStartedAt: CFTimeInterval = 0
    private let plan: InteractionPlan
    private let idleCommand: String
    private let clock: () -> CFTimeInterval

    init(
        interactions: [InteractionConfig],
        policy: InteractionPolicy?,
        actionTailDurations: [String: CFTimeInterval] = [:],
        declarativePlan: DeclarativeBindingPlan? = nil,
        clock: @escaping () -> CFTimeInterval = CACurrentMediaTime
    ) {
        self.defaultClickTailDuration = policy?.defaultClickTailSeconds ?? 1.15
        self.releaseFadeDuration = policy?.releaseFadeSeconds ?? 0.20
        self.activeClickTailDuration = policy?.defaultClickTailSeconds ?? 1.15
        let resolvedPlan = InteractionPlan(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations,
            declarativePlan: declarativePlan
        )
        self.plan = resolvedPlan
        self.idleCommand = resolvedPlan.idleCommand()
        self.moveCommandState = resolvedPlan.idleCommand()
        let neutralPoint = resolvedPlan.lookNeutralPoint()
        self.pointerState = neutralPoint
        self.smoothedPointerState = neutralPoint
        self.clock = clock
        self.lastSmoothSampleAt = clock()
    }

    func snapshot() -> InteractionSnapshot {
        lock.lock()
        defer { lock.unlock() }

        advanceSmoothedPointerLocked()
        let now = clock()
        activateDelayedHoldIfNeededLocked(now: now)
        if let pressedHitAction,
           pressedHitTrigger == .hold,
           pressedHitTapAction == nil || pressedHitHoldActivated {
            clickCommandState = pressedHitAction
            clickCommandHeld = true
            clickCommandExpiresAt = now + releaseFadeDuration
        }
        let isPointerDown = pressedButton != nil
        if let clickCommandState, clickCommandHeld || now < clickCommandExpiresAt {
            let fadeDuration = clickCommandHeld ? releaseFadeDuration : max(activeClickTailDuration, 0.001)
            let pulse = clickCommandHeld ? 1.0 : CGFloat((clickCommandExpiresAt - now) / fadeDuration)
            return InteractionSnapshot(
                pointer: smoothedPointerState,
                command: clickCommandState,
                isPointerDown: isPointerDown,
                clickPulse: min(max(pulse, 0.0), 1.0),
                isInputActive: true
            )
        }

        clickCommandState = nil
        return InteractionSnapshot(
            pointer: smoothedPointerState,
            command: moveCommandState,
            isPointerDown: isPointerDown,
            clickPulse: 0.0,
            isInputActive: isPointerInputActiveLocked(now: now)
        )
    }

    func pointerMoved(to normalizedPoint: CGPoint) {
        let pointer = clamp(normalizedPoint)

        lock.lock()
        if plan.allowsPointerMove(button: nil) {
            pointerState = pointer
            markPointerInputActiveLocked(now: clock())
        } else {
            pointerState = plan.lookNeutralPoint()
            moveCommandState = idleCommand
            pointerInputActiveUntil = 0
        }
        lock.unlock()
    }

    func pointerDragged(to normalizedPoint: CGPoint, button: PointerButton = .left) {
        let pointer = clamp(normalizedPoint)

        lock.lock()
        let now = clock()
        if plan.allowsPointerMove(button: button) {
            pointerState = pointer
            markPointerInputActiveLocked(now: now)
        } else {
            pointerState = plan.lookNeutralPoint()
            pointerInputActiveUntil = 0
        }
        activateDelayedHoldLocked(now: now)
        lock.unlock()
    }

    func pointerDown(at normalizedPoint: CGPoint, button: PointerButton = .left) {
        let pointer = clamp(normalizedPoint)
        let hitResult = plan.hitTest(point: pointer, button: button)

        let now = clock()
        lock.lock()
        pointerState = pointer
        markPointerInputActiveLocked(now: now)
        pressStartedAt = now
        pressedButton = button
        pressedHitAction = hitResult?.action
        pressedHitTapAction = hitResult?.tapAction
        pressedHitTrigger = hitResult?.trigger ?? .tap
        pressedHitTailDuration = hitResult?.tailSeconds ?? defaultClickTailDuration
        pressedHitTapTailDuration = hitResult?.tapTailSeconds ?? defaultClickTailDuration
        pressedHitHoldStartSeconds = hitResult?.holdStartSeconds ?? 0
        pressedHitHoldActivated = false
        clickCommandState = nil
        clickCommandHeld = false
        clickCommandExpiresAt = 0
        activeClickTailDuration = pressedHitTailDuration
        if let hitResult {
            let trigger = hitResult.trigger
            if trigger == .hold, let tapAction = hitResult.tapAction {
                clickCommandState = tapAction
                clickCommandHeld = true
                activeClickTailDuration = hitResult.tapTailSeconds
                clickCommandExpiresAt = now + releaseFadeDuration
            } else {
                let hitAction = hitResult.action
                clickCommandState = hitAction
                clickCommandHeld = trigger == .hold
                clickCommandExpiresAt = now + (trigger == .hold ? releaseFadeDuration : pressedHitTailDuration)
                pressedHitHoldActivated = trigger == .hold
            }
        } else {
            moveCommandState = plan.command(for: pointer, previousCommand: moveCommandState)
        }
        lock.unlock()
    }

    func pointerUp(at normalizedPoint: CGPoint, button: PointerButton = .left) {
        let pointer = clamp(normalizedPoint)
        lock.lock()
        pointerState = pointer
        markPointerInputActiveLocked(now: clock())
        finishPointerUpLocked(button: button)
        lock.unlock()
    }

    func pointerUp(button: PointerButton = .left) {
        lock.lock()
        finishPointerUpLocked(button: button)
        lock.unlock()
    }

    func pointerTrackingStopped() {
        lock.lock()
        let now = clock()
        if clickCommandHeld {
            clickCommandHeld = false
            activeClickTailDuration = releaseFadeDuration
            clickCommandExpiresAt = now + releaseFadeDuration
        } else if clickCommandState == nil || now >= clickCommandExpiresAt {
            clickCommandState = nil
            clickCommandExpiresAt = 0
        }
        pressedHitAction = nil
        pressedHitTapAction = nil
        pressedHitTrigger = nil
        pressedHitTailDuration = 0
        pressedHitTapTailDuration = 0
        pressedHitHoldStartSeconds = 0
        pressedHitHoldActivated = false
        pressedButton = nil
        pointerInputActiveUntil = now
        lock.unlock()
    }

    func resetPointerTracking() {
        lock.lock()
        let now = clock()
        let neutralPoint = plan.lookNeutralPoint()
        pointerState = neutralPoint
        smoothedPointerState = neutralPoint
        lastSmoothSampleAt = now
        pointerInputActiveUntil = 0
        moveCommandState = idleCommand
        clickCommandState = nil
        clickCommandExpiresAt = 0
        clickCommandHeld = false
        pressedHitAction = nil
        pressedHitTapAction = nil
        pressedHitTrigger = nil
        pressedHitTailDuration = 0
        pressedHitTapTailDuration = 0
        pressedHitHoldStartSeconds = 0
        pressedHitHoldActivated = false
        pressedButton = nil
        pointerInputActiveUntil = now
        lock.unlock()
    }

    func pointerTrackingInterrupted() {
        lock.lock()
        let now = clock()
        if clickCommandHeld {
            clickCommandHeld = false
            activeClickTailDuration = releaseFadeDuration
            clickCommandExpiresAt = now + releaseFadeDuration
        } else if clickCommandState == nil || now >= clickCommandExpiresAt {
            clickCommandState = nil
            clickCommandExpiresAt = 0
        }
        pressedHitAction = nil
        pressedHitTapAction = nil
        pressedHitTrigger = nil
        pressedHitTailDuration = 0
        pressedHitTapTailDuration = 0
        pressedHitHoldStartSeconds = 0
        pressedHitHoldActivated = false
        pressedButton = nil
        lock.unlock()
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        plan.clamp(point)
    }

    private func advanceSmoothedPointerLocked() {
        let now = clock()
        let elapsed = now - lastSmoothSampleAt
        lastSmoothSampleAt = now
        smoothedPointerState = plan.smooth(
            current: smoothedPointerState,
            target: pointerState,
            elapsedSeconds: elapsed
        )
        moveCommandState = plan.command(for: smoothedPointerState, previousCommand: moveCommandState)
    }

    private func markPointerInputActiveLocked(now: CFTimeInterval) {
        pointerInputActiveUntil = now + pointerInputActiveTailSeconds
    }

    private func isPointerInputActiveLocked(now: CFTimeInterval) -> Bool {
        if now < pointerInputActiveUntil {
            return true
        }
        return abs(pointerState.x - smoothedPointerState.x) > 0.001
            || abs(pointerState.y - smoothedPointerState.y) > 0.001
    }

    private func activateDelayedHoldIfNeededLocked(now: CFTimeInterval) {
        guard pressedHitTrigger == .hold,
              pressedHitTapAction != nil,
              pressedHitHoldActivated == false,
              now - pressStartedAt >= pressedHitHoldStartSeconds else {
            return
        }
        activateDelayedHoldLocked(now: now)
    }

    private func activateDelayedHoldLocked(now: CFTimeInterval) {
        guard let pressedHitAction,
              pressedHitTrigger == .hold,
              pressedHitTapAction != nil,
              pressedHitHoldActivated == false else {
            return
        }
        pressedHitHoldActivated = true
        clickCommandState = pressedHitAction
        clickCommandHeld = true
        activeClickTailDuration = pressedHitTailDuration
        clickCommandExpiresAt = now + releaseFadeDuration
    }

    private func finishPointerUpLocked(button: PointerButton) {
        let now = clock()
        guard pressedButton == nil || pressedButton == button else {
            return
        }
        if let pressedHitAction, pressedHitTrigger == .tap {
            clickCommandState = pressedHitAction
            clickCommandHeld = false
            activeClickTailDuration = pressedHitTailDuration
            clickCommandExpiresAt = max(clickCommandExpiresAt, now + pressedHitTailDuration)
        } else if let pressedHitAction, pressedHitTrigger == .hold {
            let releasedAction: String
            let releasedTail: CFTimeInterval
            if let pressedHitTapAction, pressedHitHoldActivated == false {
                releasedAction = pressedHitTapAction
                releasedTail = pressedHitTapTailDuration
            } else {
                releasedAction = pressedHitAction
                releasedTail = pressedHitTailDuration
            }
            clickCommandState = releasedAction
            clickCommandHeld = false
            activeClickTailDuration = max(releasedTail, releaseFadeDuration)
            clickCommandExpiresAt = now + activeClickTailDuration
        }
        pressedHitAction = nil
        pressedHitTapAction = nil
        pressedHitTrigger = nil
        pressedHitTailDuration = 0
        pressedHitTapTailDuration = 0
        pressedHitHoldStartSeconds = 0
        pressedHitHoldActivated = false
        pressedButton = nil
        if plan.allowsPointerMove(button: nil) == false {
            pointerState = plan.lookNeutralPoint()
            moveCommandState = idleCommand
        }
    }
}
