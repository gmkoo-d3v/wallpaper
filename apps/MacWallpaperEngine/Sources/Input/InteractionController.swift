import CoreGraphics
import Foundation
import QuartzCore

struct InteractionSnapshot {
    let pointer: CGPoint
    let command: String
    let isPointerDown: Bool
    let pointerSpeed: CGFloat
    let pointerPressDuration: CGFloat
    let pointerDragDistance: CGFloat
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
    private var lastPointerSpeedSampleAt: CFTimeInterval
    private var lastPointerSpeedSamplePoint = CGPoint(x: 0.5, y: 0.5)
    private var pointerSpeed: CGFloat = 0
    private var pointerInputActiveUntil: CFTimeInterval = 0
    private var moveCommandState: String
    private var clickCommandState: String?
    private var clickCommandExpiresAt: CFTimeInterval = 0
    private var clickCommandHeld = false
    private var activeClickTailDuration: CFTimeInterval
    private var pressedHitAction: String?
    private var pressedHitTapAction: String?
    private var pressedHitRubAction: String?
    private var pressedHitTrigger: HitZoneTrigger?
    private var pressedHitTailDuration: CFTimeInterval = 0
    private var pressedHitTapTailDuration: CFTimeInterval = 0
    private var pressedHitRubTailDuration: CFTimeInterval = 0
    private var pressedHitHoldStartSeconds: CFTimeInterval = 0
    private var pressedHitRubStartSeconds: CFTimeInterval = 0
    private var pressedHitRubStartDistance: CGFloat = 0.035
    private var pressedHitHoldActivated = false
    private var pressedHitRubActivated = false
    private var pressedButton: PointerButton?
    private var pressStartedAt: CFTimeInterval = 0
    private var pressStartPoint = CGPoint(x: 0.5, y: 0.5)
    private var pressRubStartPoint = CGPoint(x: 0.5, y: 0.5)
    private var pressRubWindowActivated = false
    private var pressMaxDragDistance: CGFloat = 0
    private var pressMaxDisplacement: CGFloat = 0
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
        let now = clock()
        self.lastSmoothSampleAt = now
        self.lastPointerSpeedSampleAt = now
        self.lastPointerSpeedSamplePoint = neutralPoint
    }

    func snapshot() -> InteractionSnapshot {
        lock.lock()
        defer { lock.unlock() }

        advanceSmoothedPointerLocked()
        let now = clock()
        activateDelayedHoldIfNeededLocked(now: now)
        activateRubIfNeededLocked(now: now)
        if let pressedHitAction,
           pressedHitTrigger == .hold,
           pressedHitTapAction == nil || pressedHitHoldActivated || pressedHitRubActivated {
            clickCommandState = pressedHitRubActivated ? (pressedHitRubAction ?? pressedHitAction) : pressedHitAction
            clickCommandHeld = true
            clickCommandExpiresAt = now + releaseFadeDuration
        }
        let isPointerDown = pressedButton != nil
        if let clickCommandState, clickCommandHeld || now < clickCommandExpiresAt {
            let fadeDuration = clickCommandHeld ? releaseFadeDuration : max(activeClickTailDuration, 0.001)
            let pulse = clickCommandHeld ? 1.0 : CGFloat((clickCommandExpiresAt - now) / fadeDuration)
            let inputActive = true
            let pressDuration = isPointerDown ? pointerPressDurationLocked(now: now) : 0
            let dragDistance = isPointerDown ? pointerDragDistanceLocked() : 0
            return InteractionSnapshot(
                pointer: smoothedPointerState,
                command: clickCommandState,
                isPointerDown: isPointerDown,
                pointerSpeed: inputActive ? pointerSpeed : 0,
                pointerPressDuration: pressDuration,
                pointerDragDistance: dragDistance,
                clickPulse: min(max(pulse, 0.0), 1.0),
                isInputActive: inputActive
            )
        }

        clickCommandState = nil
        let inputActive = isPointerInputActiveLocked(now: now)
        let pressDuration = isPointerDown ? pointerPressDurationLocked(now: now) : 0
        let dragDistance = isPointerDown ? pointerDragDistanceLocked() : 0
        return InteractionSnapshot(
            pointer: smoothedPointerState,
            command: moveCommandState,
            isPointerDown: isPointerDown,
            pointerSpeed: inputActive ? pointerSpeed : 0,
            pointerPressDuration: pressDuration,
            pointerDragDistance: dragDistance,
            clickPulse: 0.0,
            isInputActive: inputActive
        )
    }

    func pointerMoved(to normalizedPoint: CGPoint) {
        let pointer = clamp(normalizedPoint)

        lock.lock()
        let now = clock()
        if plan.allowsPointerMove(button: nil) {
            updatePointerSpeedLocked(to: pointer, now: now)
            pointerState = pointer
            markPointerInputActiveLocked(now: now)
        } else {
            pointerSpeed = 0
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
            updatePointerSpeedLocked(to: pointer, now: now)
            pointerState = pointer
            markPointerInputActiveLocked(now: now)
        } else {
            pointerSpeed = 0
            pointerState = plan.lookNeutralPoint()
            pointerInputActiveUntil = 0
        }
        updatePressDragDistanceLocked(to: pointer)
        updatePressDisplacementLocked(to: pointer, now: now)
        activateDelayedHoldIfNeededLocked(now: now)
        activateRubIfNeededLocked(now: now)
        lock.unlock()
    }

    func pointerDown(at normalizedPoint: CGPoint, button: PointerButton = .left) {
        let pointer = clamp(normalizedPoint)
        let hitResult = plan.hitTest(point: pointer, button: button)

        let now = clock()
        lock.lock()
        resetPointerSpeedSampleLocked(to: pointer, now: now)
        pointerState = pointer
        markPointerInputActiveLocked(now: now)
        pressStartedAt = now
        pressStartPoint = pointer
        pressRubStartPoint = pointer
        pressMaxDragDistance = 0
        pressMaxDisplacement = 0
        pressedButton = button
        pressedHitAction = hitResult?.action
        pressedHitTapAction = hitResult?.tapAction
        pressedHitRubAction = hitResult?.rubAction
        pressedHitTrigger = hitResult?.trigger ?? .tap
        pressedHitTailDuration = hitResult?.tailSeconds ?? defaultClickTailDuration
        pressedHitTapTailDuration = hitResult?.tapTailSeconds ?? defaultClickTailDuration
        pressedHitRubTailDuration = hitResult?.rubTailSeconds ?? defaultClickTailDuration
        pressedHitHoldStartSeconds = hitResult?.holdStartSeconds ?? 0
        pressedHitRubStartSeconds = hitResult?.rubStartSeconds ?? 0
        pressedHitRubStartDistance = hitResult?.rubStartDistance ?? 0.035
        pressedHitHoldActivated = false
        pressedHitRubActivated = false
        pressRubWindowActivated = pressedHitRubStartSeconds <= 0
        clickCommandState = nil
        clickCommandHeld = false
        clickCommandExpiresAt = 0
        activeClickTailDuration = pressedHitTailDuration
        if let hitResult {
            let trigger = hitResult.trigger
            if trigger == .hold, hitResult.tapAction != nil {
                clickCommandState = nil
                clickCommandHeld = false
                activeClickTailDuration = hitResult.tapTailSeconds
                clickCommandExpiresAt = 0
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
        let now = clock()
        lock.lock()
        resetPointerSpeedSampleLocked(to: pointer, now: now)
        pointerState = pointer
        markPointerInputActiveLocked(now: now)
        updatePressDragDistanceLocked(to: pointer)
        updatePressDisplacementLocked(to: pointer, now: now)
        activateDelayedHoldIfNeededLocked(now: now)
        activateRubIfNeededLocked(now: now)
        finishPointerUpLocked(button: button)
        lock.unlock()
    }

    func pointerUp(button: PointerButton = .left) {
        let now = clock()
        lock.lock()
        activateDelayedHoldIfNeededLocked(now: now)
        activateRubIfNeededLocked(now: now)
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
        pressedHitRubAction = nil
        pressedHitTrigger = nil
        pressedHitTailDuration = 0
        pressedHitTapTailDuration = 0
        pressedHitRubTailDuration = 0
        pressedHitHoldStartSeconds = 0
        pressedHitRubStartSeconds = 0
        pressedHitRubStartDistance = 0.035
        pressedHitHoldActivated = false
        pressedHitRubActivated = false
        pressRubWindowActivated = false
        pressedButton = nil
        pressMaxDragDistance = 0
        pressMaxDisplacement = 0
        pointerSpeed = 0
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
        resetPointerSpeedSampleLocked(to: neutralPoint, now: now)
        pointerInputActiveUntil = 0
        moveCommandState = idleCommand
        clickCommandState = nil
        clickCommandExpiresAt = 0
        clickCommandHeld = false
        pressedHitAction = nil
        pressedHitTapAction = nil
        pressedHitRubAction = nil
        pressedHitTrigger = nil
        pressedHitTailDuration = 0
        pressedHitTapTailDuration = 0
        pressedHitRubTailDuration = 0
        pressedHitHoldStartSeconds = 0
        pressedHitRubStartSeconds = 0
        pressedHitRubStartDistance = 0.035
        pressedHitHoldActivated = false
        pressedHitRubActivated = false
        pressRubWindowActivated = false
        pressedButton = nil
        pressMaxDragDistance = 0
        pressMaxDisplacement = 0
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
        pressedHitRubAction = nil
        pressedHitTrigger = nil
        pressedHitTailDuration = 0
        pressedHitTapTailDuration = 0
        pressedHitRubTailDuration = 0
        pressedHitHoldStartSeconds = 0
        pressedHitRubStartSeconds = 0
        pressedHitRubStartDistance = 0.035
        pressedHitHoldActivated = false
        pressedHitRubActivated = false
        pressRubWindowActivated = false
        pressedButton = nil
        pressMaxDragDistance = 0
        pressMaxDisplacement = 0
        pointerSpeed = 0
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

    private func updatePointerSpeedLocked(to point: CGPoint, now: CFTimeInterval) {
        let elapsed = now - lastPointerSpeedSampleAt
        defer {
            lastPointerSpeedSampleAt = now
            lastPointerSpeedSamplePoint = point
        }
        guard elapsed > 0.000001, elapsed.isFinite else {
            pointerSpeed = 0
            return
        }
        let dx = point.x - lastPointerSpeedSamplePoint.x
        let dy = point.y - lastPointerSpeedSamplePoint.y
        let distance = sqrt(dx * dx + dy * dy)
        pointerSpeed = min(max(distance / CGFloat(elapsed), 0), 10)
    }

    private func resetPointerSpeedSampleLocked(to point: CGPoint, now: CFTimeInterval) {
        lastPointerSpeedSampleAt = now
        lastPointerSpeedSamplePoint = point
        pointerSpeed = 0
    }

    private func pointerPressDurationLocked(now: CFTimeInterval) -> CGFloat {
        guard pressedButton != nil else { return 0 }
        let duration = max(now - pressStartedAt, 0)
        return CGFloat(min(max(duration, 0), 10))
    }

    private func pointerDragDistanceLocked() -> CGFloat {
        min(max(pressMaxDragDistance, 0), 2)
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
              pressedHitRubActivated == false,
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
              pressedHitRubActivated == false,
              pressedHitHoldActivated == false else {
            return
        }
        pressedHitHoldActivated = true
        clickCommandState = pressedHitAction
        clickCommandHeld = true
        activeClickTailDuration = pressedHitTailDuration
        clickCommandExpiresAt = now + releaseFadeDuration
    }

    private func updatePressDisplacementLocked(to point: CGPoint, now: CFTimeInterval) {
        guard pressedButton != nil else { return }
        if pressRubWindowActivated == false {
            guard now - pressStartedAt >= pressedHitRubStartSeconds else {
                return
            }
            pressRubWindowActivated = true
            pressRubStartPoint = pressedHitRubStartSeconds > 0 ? point : pressStartPoint
            pressMaxDisplacement = 0
            if pressedHitRubStartSeconds > 0 {
                return
            }
        }
        let dx = point.x - pressRubStartPoint.x
        let dy = point.y - pressRubStartPoint.y
        pressMaxDisplacement = max(pressMaxDisplacement, sqrt(dx * dx + dy * dy))
    }

    private func updatePressDragDistanceLocked(to point: CGPoint) {
        guard pressedButton != nil else { return }
        let dx = point.x - pressStartPoint.x
        let dy = point.y - pressStartPoint.y
        pressMaxDragDistance = max(pressMaxDragDistance, sqrt(dx * dx + dy * dy))
    }

    private func activateRubIfNeededLocked(now: CFTimeInterval) {
        updatePressDisplacementLocked(to: pointerState, now: now)
        guard let pressedHitRubAction,
              pressedHitTrigger == .hold,
              pressedHitTapAction != nil,
              pressedHitRubActivated == false,
              pressMaxDisplacement >= pressedHitRubStartDistance else {
            return
        }
        pressedHitRubActivated = true
        pressedHitHoldActivated = false
        clickCommandState = pressedHitRubAction
        clickCommandHeld = true
        activeClickTailDuration = pressedHitRubTailDuration
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
            if let pressedHitRubAction, pressedHitRubActivated {
                releasedAction = pressedHitRubAction
                releasedTail = pressedHitRubTailDuration
            } else if let pressedHitTapAction, pressedHitHoldActivated == false {
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
        pressedHitRubAction = nil
        pressedHitTrigger = nil
        pressedHitTailDuration = 0
        pressedHitTapTailDuration = 0
        pressedHitRubTailDuration = 0
        pressedHitHoldStartSeconds = 0
        pressedHitRubStartSeconds = 0
        pressedHitRubStartDistance = 0.035
        pressedHitHoldActivated = false
        pressedHitRubActivated = false
        pressRubWindowActivated = false
        pressedButton = nil
        pressMaxDragDistance = 0
        pressMaxDisplacement = 0
        if plan.allowsPointerMove(button: nil) == false {
            pointerState = plan.lookNeutralPoint()
            moveCommandState = idleCommand
        }
    }
}
