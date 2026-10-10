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

private enum PressGesturePhase {
    case inactive
    case pendingTap
    case holding
    case rubbing
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
    private var pressedHitHoldCommitSeconds: CFTimeInterval = 0
    /// True when the press must not release through the tap branch: only an explicitly
    /// declared holdCommitSeconds = 0 declares a no-effect hold zone with no tap window.
    /// Absent commit timing (or a positive commit) keeps the tap-below-commit behavior,
    /// with the commit threshold falling back to holdStart per the hit-result value — and
    /// to the policy default click tail duration when both holdStart and holdCommit are
    /// omitted (the default short-touch tap window).
    /// When true (or when the press started holding directly), the snapshot hold preview
    /// may promote a pending press; an alive tap window keeps snapshot promotion at the
    /// positive commit threshold so the preview never steals the tap decision.
    private var pressedHitTapBranchDisabled = false
    private var pressedHitRubStartSeconds: CFTimeInterval = 0
    private var pressedHitRubStartDistance: CGFloat = 0.035
    private var pressGesturePhase: PressGesturePhase = .inactive
    private var pressedButton: PointerButton?
    private var pressStartedAt: CFTimeInterval = 0
    private var pressStartPoint = CGPoint(x: 0.5, y: 0.5)
    private var pressRubStartPoint = CGPoint(x: 0.5, y: 0.5)
    private var pressRubWindowOpened = false
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
        // Snapshot hold preview runs at the bare holdStart threshold (pre-existing
        // behavior). The preview never steals the tap decision: with an alive tap window
        // (tapAction present, no explicit 0 commit, positive commit threshold) and the
        // press still pending below the commit threshold, pointer-up re-evaluates the
        // gesture and resolves the release through the tap action (see
        // activateHoldForReleaseLocked); otherwise the preview promotion is final.
        activateDelayedHoldIfNeededLocked(now: now)
        if let pressedHitAction,
           pressedHitTrigger == .hold,
           pressedHitTapAction == nil || pressGesturePhase == .holding || pressGesturePhase == .rubbing {
            clickCommandState = pressGesturePhase == .rubbing ? (pressedHitRubAction ?? pressedHitAction) : pressedHitAction
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
        let previousPointer = pointerState
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
        updatePressDisplacementLocked(to: pointer, previousPoint: previousPointer, now: now, countAsDrag: true)
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
        // Commit threshold collapse: an explicitly declared commit wins; an absent commit
        // collapses to holdStart, except that when BOTH the effective start and commit are
        // omitted the zone is a short-touch gesture with the default tap-detection window
        // (the policy's default click tail duration), so an undeclared hold zone's tapAction
        // stays reachable. The threshold also equals the effective holdStart in that case,
        // so the snapshot promotion stays at the bare holdStart semantics (a declared start
        // keeps promoting at its own threshold); with both omitted, preview and commit both
        // happen at the default window.
        // "Both omitted" is about the effective timing values: a declared commit (without a
        // declared start) collapses into the effective start, so the pair is not omitted.
        let defaultsBothOmitted = hitResult?.holdEffectiveStartDeclared == false
        pressedHitHoldCommitSeconds = defaultsBothOmitted
            ? defaultClickTailDuration
            : hitResult?.holdCommitSeconds ?? pressedHitHoldStartSeconds
        if defaultsBothOmitted {
            pressedHitHoldStartSeconds = defaultClickTailDuration
        }
        // Explicit 0 commit disables the tap branch; absent declaration keeps it alive even
        // when the collapsed commit value is 0 (the plan collapses nil to holdStart/0).
        pressedHitTapBranchDisabled = hitResult?.holdCommitSecondsDeclared == true
            && hitResult?.holdCommitSeconds == 0
        pressedHitRubStartSeconds = hitResult?.rubStartSeconds ?? 0
        pressedHitRubStartDistance = hitResult?.rubStartDistance ?? 0.035
        pressGesturePhase = .inactive
        pressRubWindowOpened = pressedHitRubStartSeconds <= 0
        clickCommandState = nil
        clickCommandHeld = false
        clickCommandExpiresAt = 0
        activeClickTailDuration = pressedHitTailDuration
        if let hitResult {
            let trigger = hitResult.trigger
            if trigger == .hold, hitResult.tapAction != nil {
                pressGesturePhase = .pendingTap
                clickCommandState = nil
                clickCommandHeld = false
                activeClickTailDuration = hitResult.tapTailSeconds
                clickCommandExpiresAt = 0
            } else {
                let hitAction = hitResult.action
                clickCommandState = hitAction
                clickCommandHeld = trigger == .hold
                clickCommandExpiresAt = now + (trigger == .hold ? releaseFadeDuration : pressedHitTailDuration)
                pressGesturePhase = trigger == .hold ? .holding : .inactive
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
        guard pressedButton == nil || pressedButton == button else {
            lock.unlock()
            return
        }
        activateHoldForReleaseLocked(now: now)
        finishPointerUpLocked(button: button)
        lock.unlock()
    }

    func pointerUp(button: PointerButton = .left) {
        let now = clock()
        lock.lock()
        guard pressedButton == nil || pressedButton == button else {
            lock.unlock()
            return
        }
        activateHoldForReleaseLocked(now: now)
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
        pressedHitHoldCommitSeconds = 0
        pressedHitTapBranchDisabled = false
        pressedHitRubStartSeconds = 0
        pressedHitRubStartDistance = 0.035
        pressGesturePhase = .inactive
        pressRubWindowOpened = false
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
        pressedHitHoldCommitSeconds = 0
        pressedHitTapBranchDisabled = false
        pressedHitRubStartSeconds = 0
        pressedHitRubStartDistance = 0.035
        pressGesturePhase = .inactive
        pressRubWindowOpened = false
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
        pressedHitHoldCommitSeconds = 0
        pressedHitTapBranchDisabled = false
        pressedHitRubStartSeconds = 0
        pressedHitRubStartDistance = 0.035
        pressGesturePhase = .inactive
        pressRubWindowOpened = false
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
              pressGesturePhase == .pendingTap,
              now - pressStartedAt >= pressedHitHoldStartSeconds else {
            return
        }
        activateDelayedHoldLocked(now: now)
    }

    /// Hold promotion at pointer-up: a press still pending is committed at release once
    /// `pressDuration >= holdCommit`; below the commit threshold the release goes through
    /// the tap action. A press already promoted to holding during the press is re-evaluated
    /// here: with an alive tap window (no explicit 0 commit and a positive commit threshold)
    /// a below-commit release is treated as a tap release, so the snapshot hold preview
    /// never steals the tap decision. With commit collapsed to holdStart == 0 (absent or
    /// disabled tap window) every release passes the threshold and stays committed, matching
    /// the pre-existing behavior.
    private func activateHoldForReleaseLocked(now: CFTimeInterval) {
        let tapWindowAlive = pressedHitTapAction != nil
            && !pressedHitTapBranchDisabled
            && pressedHitHoldCommitSeconds > 0
        guard pressedHitTrigger == .hold,
              pressedHitTapAction != nil,
              pressGesturePhase == .pendingTap || (pressGesturePhase == .holding && tapWindowAlive),
              now - pressStartedAt >= pressedHitHoldStartSeconds else {
            return
        }
        if tapWindowAlive, pressGesturePhase == .holding, now - pressStartedAt < pressedHitHoldCommitSeconds {
            // The snapshot hold preview promoted this press below the commit threshold;
            // a pre-commit release is a tap, not a committed hold.
            pressGesturePhase = .pendingTap
            return
        }
        activateDelayedHoldLocked(now: now)
    }

    private func activateDelayedHoldLocked(now: CFTimeInterval) {
        guard let pressedHitAction,
              pressedHitTrigger == .hold,
              pressedHitTapAction != nil,
              pressGesturePhase == .pendingTap else {
            return
        }
        pressGesturePhase = .holding
        clickCommandState = pressedHitAction
        clickCommandHeld = true
        activeClickTailDuration = pressedHitTailDuration
        clickCommandExpiresAt = now + releaseFadeDuration
    }

    private func updatePressDisplacementLocked(
        to point: CGPoint,
        previousPoint: CGPoint,
        now: CFTimeInterval,
        countAsDrag: Bool
    ) {
        guard pressedButton != nil else { return }
        if pressRubWindowOpened == false {
            guard now - pressStartedAt >= pressedHitRubStartSeconds else {
                return
            }
            pressRubWindowOpened = true
            pressRubStartPoint = pressStartPoint
            pressMaxDisplacement = 0
        }
        guard countAsDrag else {
            return
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
        guard let pressedHitRubAction,
              pressedHitTrigger == .hold,
              pressedHitTapAction != nil,
              pressGesturePhase != .rubbing,
              pressRubWindowOpened,
              pressMaxDisplacement >= pressedHitRubStartDistance else {
            return
        }
        pressGesturePhase = .rubbing
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
            let pressDuration = now - pressStartedAt
            if let pressedHitRubAction, pressGesturePhase == .rubbing {
                releasedAction = pressedHitRubAction
                releasedTail = pressedHitRubTailDuration
            } else {
                // (rub and tap/hold branches share the release finalization below)
                // Tap-versus-hold decision at release (short-touch gesture semantics): the
                // tap window is alive for a live tapAction unless an explicit 0 commit
                // disables it (or an absent commit falls back to holdStart > 0); a release
                // strictly below the commit threshold releases the tap action, everything
                // else — including commit == holdStart == 0, whose threshold every release
                // passes — is the committed hold.
                let tapWindowAlive = pressedHitTapAction != nil
                    && !pressedHitTapBranchDisabled
                    && pressedHitHoldCommitSeconds > 0
                if let pressedHitTapAction, tapWindowAlive, pressDuration < pressedHitHoldCommitSeconds {
                    releasedAction = pressedHitTapAction
                    releasedTail = pressedHitTapTailDuration
                } else {
                    releasedAction = pressedHitAction
                    // For hold zones, committed and pre-commit releases are two branches of one
                    // hold gesture; the release tail must cover the longer of the two payloads so
                    // the committed hold replay is not cut short by the tap branch's shorter tail.
                    releasedTail = max(pressedHitTailDuration, pressedHitTapTailDuration)
                }
            }
            // Release finalization applies to every hold branch outcome (rub, tap, committed
            // hold): the released command plays its tail and the press-held state clears, so
            // a rubbing press is not stuck held after pointer-up.
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
        pressedHitHoldCommitSeconds = 0
        pressedHitTapBranchDisabled = false
        pressedHitRubStartSeconds = 0
        pressedHitRubStartDistance = 0.035
        pressGesturePhase = .inactive
        pressRubWindowOpened = false
        pressedButton = nil
        pressMaxDragDistance = 0
        pressMaxDisplacement = 0
        if plan.allowsPointerMove(button: nil) == false {
            pointerState = plan.lookNeutralPoint()
            moveCommandState = idleCommand
        }
    }
}
