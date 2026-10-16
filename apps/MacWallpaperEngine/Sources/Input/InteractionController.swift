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
    /// Continuous per-axis quadrant gaze weights (action, weight) for the current frame.
    /// Empty when the bundle declares no pointerMove gaze config — the renderer then keeps
    /// the legacy single-overlay quadrant path byte-identically.
    let gazeWeights: [(action: String, weight: Double)]
    /// True while the active press is a COMMITTED hold: a live press whose gesture phase is
    /// holding and whose zone declares a holdAction (the committed-hold loop state). A
    /// bone-follow binding gates its cursor follow on this flag: below the commit threshold
    /// the press is neutral pending and no follow runs.
    let isHoldingLoop: Bool

    init(
        pointer: CGPoint,
        command: String,
        isPointerDown: Bool,
        pointerSpeed: CGFloat,
        pointerPressDuration: CGFloat,
        pointerDragDistance: CGFloat,
        clickPulse: CGFloat,
        isInputActive: Bool,
        gazeWeights: [(action: String, weight: Double)] = [],
        isHoldingLoop: Bool = false
    ) {
        self.pointer = pointer
        self.command = command
        self.isPointerDown = isPointerDown
        self.pointerSpeed = pointerSpeed
        self.pointerPressDuration = pointerPressDuration
        self.pointerDragDistance = pointerDragDistance
        self.clickPulse = clickPulse
        self.isInputActive = isInputActive
        self.gazeWeights = gazeWeights
        self.isHoldingLoop = isHoldingLoop
    }
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
    /// Smoothed gaze velocity state ([-1,1] per axis) for continuous gaze blending; only
    /// advanced when the pointerMove interaction declares a gaze config.
    private var gazeVelocityState = CGPoint(x: 0, y: 0)
    private var gazeWeightsState: [(action: String, weight: Double)] = []
    private var clickCommandState: String?
    private var clickCommandExpiresAt: CFTimeInterval = 0
    private var clickCommandHeld = false
    private var activeClickTailDuration: CFTimeInterval
    private var pressedHitAction: String?
    private var pressedHitTapAction: String?
    /// Committed-hold loop action for the active press (nil for zones without holdAction).
    /// Crossing holdCommit promotes the press to this action (held, looped) instead of the
    /// base action, and a committed release ends it with the release fade only — the loop
    /// stops on release with no committed-action tail replay.
    private var pressedHitHoldAction: String?
    /// True for the lifetime of a press on a zone that declares a holdAction; cleared on
    /// release or tracking teardown. A live press keeps its pending/committed state through
    /// the snapshot live-press rule (see snapshot); this flag only marks that the active
    /// press lives on a holdAction zone.
    private var pressedHitHoldActionActive = false
    private var pressedHitRubAction: String?
    private var pressedHitTrigger: HitZoneTrigger?
    /// Tap fire timing of the active press's zone: .down fires the tap action at press time
    /// and the release only ends the press (no second fire, no release-tail replay).
    private var pressedHitTapMode: HitZoneTapMode = .up
    /// Last gaze weight vector produced by the gaze blend, kept through press suppression so
    /// the weights restore exactly on release.
    private var lastGazeWeights: [(action: String, weight: Double)] = []
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
        // Gaze suppression gate: the source runs the gaze blend only while the pointer is NOT
        // pressed on a hit zone (isLookingAround stays false while the pointer is on the
        // collider), so a live press on a pointerDown zone must zero the gaze weights. A press
        // that hits nothing leaves the gaze running, and a bundle without a pointerDown
        // interaction has no press owner at all, so its weights stay untouched.
        // The blend still advances every snapshot while suppressed (see advanceSmoothedPointerLocked),
        // so the snapshot only hides the weights during the press; the suppressed vector is kept
        // in lastGazeWeights and the weights are restored on release.
        let gazeSuppressedForPress = pressedButton != nil
            && (plan.hitTest(point: smoothedPointerState, button: pressedButton ?? .left) != nil
                || plan.hitTest(point: pressStartPoint, button: pressedButton ?? .left) != nil)
        // Snapshot hold preview runs at the bare holdStart threshold (pre-existing
        // behavior). The preview never steals the tap decision: with an alive tap window
        // (tapAction present, no explicit 0 commit, positive commit threshold) and the
        // press still pending below the commit threshold, pointer-up re-evaluates the
        // gesture and resolves the release through the tap action (see
        // activateHoldForReleaseLocked); otherwise the preview promotion is final.
        // Preview-gate exception: a zone that declares a holdAction shows NEUTRAL pending
        // below the commit — the holdStart base-action preview promotion is skipped.
        // Source IL (the hold zone): the press itself has no visual; 'act' plays only at
        // click-end (PlayActAnimation at HandleClickEnd 0x275c IL 001c) and the holdAction
        // loop (the hold loop clip) arms only after the commit crossing (Update 007f–0092), so an
        // act-preview during the pending window would be a fiction. Zones WITHOUT holdAction
        // keep the pre-existing snapshot hold-start preview byte-identically; the commit
        // crossing still promotes to the loop via activateDelayedHoldIfNeededLocked below,
        // and pointer-up still re-decides the tap below commit, so the tap decision is
        // untouched. For committed-holdAction zones (no tapAction) the snapshot keeps the
        // existing promotion path (the neutral-pending live rule below handles the pre-commit
        // phase; the loop must still arm at the crossing without an intervening snapshot).
        // The call stays UNCONDITIONAL for holdAction zones: skipping it below the preview
        // window would also skip the commit-crossing arming, which would make the loop depend
        // on a snapshot tick landing between the commit and the next sampling (a probe or a
        // low-cadence frame can miss that window and keep showing stale pending residue);
        // the gate itself lives in the tap-window holdAction branch of
        // activateDelayedHoldIfNeededLocked (neutral below commit, loop arms exactly at the
        // crossing, with or without an intervening snapshot).
        activateDelayedHoldIfNeededLocked(now: now)
        // Generic live-press rule: while a press is live (pressedButton set) on a zone that
        // declares a holdAction, the press must stay INPUT-ACTIVE regardless of any elapsed
        // pending tail — an elapsed default click tail (1.15 s, nil policy) must never blank
        // an elapsed pending/committed press to an idle move snapshot with command nil /
        // pulse 0 while the finger is down. Pulse semantics per phase: a pendingTap press
        // pre-commit previews the base action at pulse 1 — at/after holdStart via the
        // holdStart preview (promoted by activateDelayedHoldIfNeededLocked), before holdStart
        // with the tap-tail preview pulse — and pointer-up still re-decides the tap below the
        // commit threshold, so the preview never steals the tap decision; a .holding press
        // below commit on a bare holdAction zone is the neutral pending state — idle command
        // with inputActive true — because an idle command always draws with a blank pulse, so
        // the pending state is returned directly instead of via the blanking fallthrough; a
        // .holding press at/after commit plays the holdAction loop at pulse 1 (held path).
        // Gated on pressedHitHoldAction != nil so every zone without a holdAction stays
        // byte-identical to the pre-holdAction paths, and on a live press so post-release
        // tap/base tails keep expiring through the normal fallthrough.
        let liveHoldActionPress = pressedButton != nil
            && pressedHitHoldAction != nil
            && (pressGesturePhase == .pendingTap || pressGesturePhase == .holding)
        var liveHoldActionReturn: InteractionSnapshot?
        if liveHoldActionPress {
            // Pre-commit in the live pending window the press lived in: the commit threshold
            // for a press that started pending, or holdStart for a direct-hold press (with the
            // default tap window when both timings were omitted).
            let pendingWindowPress = pressGesturePhase == .pendingTap
                || (pressedHitTapAction != nil && !pressedHitTapBranchDisabled)
            let commitThreshold = pendingWindowPress
                ? pressedHitHoldCommitSeconds
                : max(pressedHitHoldStartSeconds, pressedHitHoldCommitSeconds)
            let preCommitPress = now - pressStartedAt < commitThreshold
            let tapWindowAlive = pressedHitTapAction != nil
                && !pressedHitTapBranchDisabled
                && pressedHitHoldCommitSeconds > 0
            if preCommitPress, pressGesturePhase == .pendingTap, pressedHitTapAction == nil {
                // Live press on a bare holdAction zone below commit (the pointer-down phase):
                // neutral pending press — the base action is never held — returned directly
                // with inputActive true, because an idle command always draws with a blank
                // pulse and the blanking fallthrough must not blank the live press. The holdStart
                // preview above never matches this zone (a bare holdAction zone has no
                // tapAction), so the press is neutral pending — the base action is never held.
                let pressDuration = pointerPressDurationLocked(now: now)
                let dragDistance = pointerDragDistanceLocked()
                liveHoldActionReturn = InteractionSnapshot(
                    pointer: smoothedPointerState,
                    command: moveCommandState,
                    isPointerDown: true,
                    pointerSpeed: pointerSpeed,
                    pointerPressDuration: pressDuration,
                    pointerDragDistance: dragDistance,
                    clickPulse: 0.0,
                    isInputActive: true,
                            gazeWeights: gazeSuppressedForPress ? [] : lastGazeWeights,
                            isHoldingLoop: false
                )
            } else if preCommitPress,
                      pressGesturePhase == .pendingTap,
                      pressedHitTapAction != nil {
                // Live pendingTap press on a holdAction zone (the tap-window pre-commit
                // phase): neutral pending — returned directly with inputActive true, so an
                // elapsed tap tail can never blank the live press to an idle/pulse-0 move
                // snapshot while the finger is down. The preview gate keeps this press
                // un-promoted below the commit (IL: press has no visual; the release action
                // plays at click-end, the loop arms only past holdCommit). The pending press
                // carries no click command of its own, so the pending state owns the state
                // machine here: clear any elapsed tail window (pointer-up owns the tail clock
                // for a holdAction zone — the release decays over the full tap tail from the
                // release) so no stale pending-tail residue can render under the press or
                // bleed into the committed-loop sample after the crossing. Pointer-up
                // re-decides a below-commit release through the tap action (see
                // activateHoldForReleaseLocked), so the neutral pending never steals the tap
                // decision.
                clickCommandState = nil
                clickCommandHeld = false
                clickCommandExpiresAt = 0
                activeClickTailDuration = pressedHitTapTailDuration
                let pressDuration = pointerPressDurationLocked(now: now)
                let dragDistance = pointerDragDistanceLocked()
                liveHoldActionReturn = InteractionSnapshot(
                    pointer: smoothedPointerState,
                    command: moveCommandState,
                    isPointerDown: true,
                    pointerSpeed: pointerSpeed,
                    pointerPressDuration: pressDuration,
                    pointerDragDistance: dragDistance,
                    clickPulse: 0.0,
                    isInputActive: true,
                            gazeWeights: gazeSuppressedForPress ? [] : lastGazeWeights,
                            isHoldingLoop: false
                )
            } else if preCommitPress, pressGesturePhase == .holding, tapWindowAlive {
                // Live press below commit on a tap-window holdAction zone kept promoted by a
                // drag: with the preview gate the promotion never arms the base action, so
                // this is neutral pending too — returned directly with inputActive true (the
                // blanking fallthrough must not blank the live press; same rule as the
                // pendingTap branch above). Pointer-up re-decides below commit.
                let pressDuration = pointerPressDurationLocked(now: now)
                let dragDistance = pointerDragDistanceLocked()
                liveHoldActionReturn = InteractionSnapshot(
                    pointer: smoothedPointerState,
                    command: moveCommandState,
                    isPointerDown: true,
                    pointerSpeed: pointerSpeed,
                    pointerPressDuration: pressDuration,
                    pointerDragDistance: dragDistance,
                    clickPulse: 0.0,
                    isInputActive: true,
                            gazeWeights: gazeSuppressedForPress ? [] : lastGazeWeights,
                            isHoldingLoop: false
                )
            } else if preCommitPress, pressGesturePhase == .holding, pressedHitTapAction == nil {
                // Live .holding press kept promoted below commit on a bare holdAction zone:
                // neutral pending, returned directly with inputActive true (rule comment).
                let pressDuration = pointerPressDurationLocked(now: now)
                let dragDistance = pointerDragDistanceLocked()
                liveHoldActionReturn = InteractionSnapshot(
                    pointer: smoothedPointerState,
                    command: moveCommandState,
                    isPointerDown: true,
                    pointerSpeed: pointerSpeed,
                    pointerPressDuration: pressDuration,
                    pointerDragDistance: dragDistance,
                    clickPulse: 0.0,
                    isInputActive: true,
                            gazeWeights: gazeSuppressedForPress ? [] : lastGazeWeights,
                            isHoldingLoop: false
                )
            }
        }
        if let liveHoldActionReturn {
            return liveHoldActionReturn
        }
        if let pressedHitAction,
           pressedHitTrigger == .hold,
           pressedHitTapAction == nil || pressGesturePhase == .holding || pressGesturePhase == .rubbing {
            if pressGesturePhase == .rubbing {
                clickCommandState = pressedHitRubAction ?? pressedHitAction
                clickCommandHeld = true
                clickCommandExpiresAt = now + releaseFadeDuration
            } else if pressGesturePhase == .holding {
                let crossedCommit = pressedHitHoldAction != nil
                    && pressedHitHoldCommitSeconds > 0
                    && now - pressStartedAt >= pressedHitHoldCommitSeconds
                if crossedCommit {
                    // Promote across holdCommit, and keep the committed loop alive until
                    // release (a held loop re-arms the expiry window on every snapshot).
                    clickCommandState = pressedHitHoldAction
                    clickCommandHeld = true
                    clickCommandExpiresAt = now + releaseFadeDuration
                } else if pressedHitTapAction == nil,
                          pressedHitHoldAction != nil {
                    // Bare holdAction zone below commit with a snapshot in between: keep the
                    // pending window alive (the tail must not start the loop before commit).
                    clickCommandState = nil
                } else {
                    // Pre-commit preview (tap-window zones): the promoted base action — for
                    // zones without holdAction the exact pre-holdAction preview branch. The
                    // live-press rule keeps this preview alive while the press is live, even
                    // past an elapsed tap tail; pointer-up still re-decides below commit.
                    clickCommandState = pressedHitAction
                    clickCommandHeld = true
                    clickCommandExpiresAt = now + releaseFadeDuration
                }
            } else {
                clickCommandState = pressedHitAction
                clickCommandHeld = true
                clickCommandExpiresAt = now + releaseFadeDuration
            }
        }
        let isPointerDown = pressedButton != nil
        // Committed-hold gate for the bone-follow cursor follow: a live press in the holding
        // phase on a trigger=hold zone. Gated on the trigger (not on a declared holdAction) so
        // bare-hold zones (no holdAction declared) arm the bone-follow too; zones that do
        // declare a holdAction are unaffected. Below the commit threshold the press is neutral
        // pending (no follow); the committed hold state is what arms the follow.
        let isHoldingLoop = pressedButton != nil
            && pressedHitTrigger == .hold
            && pressGesturePhase == .holding
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
                isInputActive: inputActive,
                        gazeWeights: gazeSuppressedForPress ? [] : lastGazeWeights,
                        isHoldingLoop: isHoldingLoop
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
            isInputActive: inputActive,
            gazeWeights: gazeSuppressedForPress ? [] : lastGazeWeights,
            isHoldingLoop: isHoldingLoop
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
        pressedHitHoldAction = hitResult?.holdAction
        pressedHitHoldActionActive = hitResult?.holdAction != nil
        pressedHitRubAction = hitResult?.rubAction
        pressedHitTrigger = hitResult?.trigger ?? .tap
        pressedHitTapMode = hitResult?.tapMode ?? .up
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
        // A bare holdAction zone (no tapAction) also closes the tap branch: its release is
        // committed-vs-base, never a tap. holdAction validation guarantees an explicit
        // positive commit, so the branch flag is moot here but kept coherent.
        if hitResult?.holdAction != nil, hitResult?.tapAction == nil {
            pressedHitTapBranchDisabled = true
        }
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
                // Pending press: the tap-tail timer starts at the first snapshot promotion
                // (the live-press block), never at pointer-down, so an undeclared tap tail
                // cannot expire while the press is live before the commit decision.
                pressGesturePhase = .pendingTap
                clickCommandState = nil
                clickCommandHeld = false
                activeClickTailDuration = hitResult.tapTailSeconds
                clickCommandExpiresAt = 0
            } else if trigger == .hold, hitResult.holdAction != nil {
                // Bare holdAction zone (no tapAction): the press starts neutral-pending and
                // the committed loop starts at holdCommit; the base action is never held.
                // Zones without holdAction keep the held-base-action branch below unchanged.
                pressGesturePhase = .holding
                clickCommandState = nil
                clickCommandHeld = false
                activeClickTailDuration = pressedHitTailDuration
                clickCommandExpiresAt = 0
            } else {
                let hitAction = hitResult.action
                clickCommandState = hitAction
                clickCommandHeld = trigger == .hold
                // Down-mode tap zones fire at press time (the original plays its one-shot at
                // HandleClickStart): the press window is the tail window, so the release only
                // ends the press and never re-fires or restarts the tail.
                clickCommandExpiresAt = now + (trigger == .hold
                    ? releaseFadeDuration
                    : (hitResult.tapMode == .down ? pressedHitTailDuration : 0))
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
        pressedHitHoldAction = nil
        pressedHitHoldActionActive = false
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
        pressedHitHoldAction = nil
        pressedHitHoldActionActive = false
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
        pressedHitHoldAction = nil
        pressedHitHoldActionActive = false
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
        // The blend advances on every sample, including while a press suppresses the snapshot
        // output: the source keeps running its gaze blend under the press gate, so the weights
        // are already at the pointer's target when the release restores them.
        if let gaze = plan.pointerMoveGazeConfig(), let actions = plan.pointerMoveActions() {
            gazeWeightsState = plan.gazeWeights(
                point: smoothedPointerState,
                previous: gazeVelocityState,
                elapsedSeconds: elapsed,
                sensitivity: gaze.sensitivity ?? 1,
                returnSpeed: gaze.returnSpeed ?? 10,
                actions: actions
            )
            // Keep the smoothed velocity state from the weights just produced (per-axis:
            // signed horizontal from the left/right weight, vertical from up/down).
            var vx = 0.0
            var vy = 0.0
            for entry in gazeWeightsState {
                switch entry.action {
                case actions["left"]: vx = -entry.weight
                case actions["right"]: vx = entry.weight
                case actions["up"]: vy = -entry.weight
                case actions["down"]: vy = entry.weight
                default: break
                }
            }
            gazeVelocityState = CGPoint(x: CGFloat(vx), y: CGFloat(vy))
            lastGazeWeights = gazeWeightsState
        }
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
        if pressedHitTrigger == .hold,
           pressedHitTapAction == nil,
           pressedHitHoldAction != nil {
            // Bare holdAction zone (no tapAction): the press stays neutral-pending below
            // holdCommit (the base action is never held); the committed loop begins exactly
            // at the commit threshold, on snapshot or drag promotion.
            if pressGesturePhase == .holding, now - pressStartedAt >= pressedHitHoldCommitSeconds {
                promoteToHoldActionLocked(now: now)
            }
            return
        }
        // Tap-window holdAction zones (tapAction + holdAction): the pending press stays
        // NEUTRAL below the commit — the holdStart base-action preview promotion is skipped
        // (see the snapshot preview-gate rationale; IL press has no visual) — and the commit
        // crossing arms the loop exactly at holdCommit, on the snapshot or drag promotion.
        // Zones without holdAction are untouched: the guard below matches them unchanged.
        if pressedHitTrigger == .hold,
           pressedHitTapAction != nil,
           pressedHitHoldAction != nil {
            if pressGesturePhase == .pendingTap, now - pressStartedAt >= pressedHitHoldCommitSeconds {
                promoteToHoldActionLocked(now: now)
            }
            return
        }
        guard pressedHitTrigger == .hold,
              pressedHitTapAction != nil,
              pressGesturePhase == .pendingTap,
              now - pressStartedAt >= pressedHitHoldStartSeconds else {
            return
        }
        activateDelayedHoldLocked(now: now)
    }

    /// Commits a holdAction press: the loop command replaces whatever the press was showing
    /// and is held until release. Only called at/after the holdCommit crossing.
    private func promoteToHoldActionLocked(now: CFTimeInterval) {
        guard let pressedHitHoldAction else { return }
        pressGesturePhase = .holding
        clickCommandState = pressedHitHoldAction
        clickCommandHeld = true
        activeClickTailDuration = pressedHitTailDuration
        clickCommandExpiresAt = now + releaseFadeDuration
    }

    /// Hold promotion at pointer-up: a press still pending is committed at release once
    /// `pressDuration >= holdCommit`; below the commit threshold the release goes through
    /// the tap action. A press already promoted to holding during the press is re-evaluated
    /// here: with an alive tap window (no explicit 0 commit and a positive commit threshold)
    /// a below-commit release is treated as a tap release, so the snapshot hold preview
    /// never steals the tap decision. With commit collapsed to holdStart == 0 (absent or
    /// disabled tap window) every release passes the threshold and stays committed, matching
    /// the pre-existing behavior. A committed holdAction press commits to the loop action
    /// (promoteToHoldActionLocked); a bare holdAction zone below commit falls through
    /// uncommitted so the release replays the base action with the plain hold tail.
    private func activateHoldForReleaseLocked(now: CFTimeInterval) {
        let tapWindowAlive = pressedHitTapAction != nil
            && !pressedHitTapBranchDisabled
            && pressedHitHoldCommitSeconds > 0
        if pressedHitTrigger == .hold,
           pressedHitTapAction == nil,
           pressedHitHoldAction != nil {
            // Bare holdAction zone: commit at release when the press reached holdCommit; a
            // below-commit release stays uncommitted (base-action hold release below) and
            // returns to the pending phase, so the release finalization replays the base
            // action with the plain hold tail instead of treating the press as committed.
            if pressGesturePhase != .rubbing {
                if now - pressStartedAt >= pressedHitHoldCommitSeconds {
                    promoteToHoldActionLocked(now: now)
                }
                // Below commit the press stays in its current phase (never demoted to
                // .pendingTap): the base-action branch of the release finalization below is
                // phase-agnostic and replays the base action with the plain hold tail.
            }
            return
        }
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
        if pressedHitHoldAction != nil, pressGesturePhase != .rubbing {
            // Declared holdAction: at/after the commit threshold the commit goes to the loop
            // action, not the base action (base-action promotion would replay the committed
            // tail). Below the threshold — and for any press released below it, even one a
            // snapshot promoted at holdStart — the press returns to the pending phase so the
            // tap decision stays with pointer-up: a live tap branch emits the tap action, and
            // a bare holdAction zone (no tap branch) replays the base action with the plain
            // hold tail. The holdStart preview never steals the tap decision.
            if now - pressStartedAt >= pressedHitHoldCommitSeconds {
                promoteToHoldActionLocked(now: now)
            } else {
                pressGesturePhase = .pendingTap
            }
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
            if pressedHitTapMode == .down {
                // Down-mode tap zone: the action already fired at press time. The release
                // ends the press only — no second fire and no release-tail replay; the tail
                // clock started at the press, so an in-flight one-shot keeps playing out.
                clickCommandHeld = false
            } else {
                clickCommandState = pressedHitAction
                clickCommandHeld = false
                activeClickTailDuration = pressedHitTailDuration
                clickCommandExpiresAt = max(clickCommandExpiresAt, now + pressedHitTailDuration)
            }
        } else if let pressedHitAction, pressedHitTrigger == .hold {
            // FIX3: pointer-up is the sole owner of the release tail for holdAction presses:
            // the in-press preview window must never extend the expiry computed below.
            if pressedHitHoldAction != nil {
                clickCommandExpiresAt = 0
            }
            let pressDuration = now - pressStartedAt
            let tapWindowAlive = pressedHitTapAction != nil
                && !pressedHitTapBranchDisabled
                && pressedHitHoldCommitSeconds > 0
            // The release commits to the holdAction loop only when the press reaches the
            // effective commit threshold (the tap-decision window the pending press lived
            // in: the declared commit, or the default tap window when the timing pair was
            // omitted). A pre-commit release stays in the branches below (tap, or — for a
            // bare holdAction zone whose short press never reached the window — the base
            // action with the plain hold tail).
            let commitsToHoldAction = pressedHitHoldAction != nil
                && pressGesturePhase != .rubbing
                && pressDuration >= pressedHitHoldCommitSeconds
            if commitsToHoldAction {
                // Committed holdAction release: the loop was playing (or commits at this
                // very release), so release must STOP it — the command falls to the move/idle
                // family with the release fade only, no committed-action tail replay. The
                // The command stays the last loop action, unheld, with the release-fade
                // window starting at the release, so the snapshot right at release shows a
                // decaying pulse; by release + releaseFade it expires to the move/idle
                // command at pulse 0 — expiry never extends to the base/tap tails.
                clickCommandState = pressedHitHoldAction
                clickCommandHeld = false
                activeClickTailDuration = releaseFadeDuration
                clickCommandExpiresAt = now + releaseFadeDuration
            } else {
                let releasedAction: String
                let releasedTail: CFTimeInterval
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
                    if let pressedHitTapAction, tapWindowAlive, pressDuration < pressedHitHoldCommitSeconds {
                        // Tap-versus-hold decision below the commit threshold: an alive tap
                        // branch wins (its tail clock starts at the release, so a pre-commit
                        // tap release decays over the full tap tail from pointer-up). For a
                        // holdAction zone, re-decision rules — demote to pending for a
                        // pre-commit snapshot-promoted preview, or commit past the threshold —
                        // already ran in activateHoldForReleaseLocked before this finalization.
                        releasedAction = pressedHitTapAction
                        releasedTail = pressedHitTapTailDuration
                    } else if pressDuration < pressedHitHoldCommitSeconds,
                              pressedHitTapAction == nil,
                              pressedHitHoldAction != nil {
                        // Pre-commit release of a holdAction press with no tap branch — the bare
                        // holdAction zone, whether the press never saw a snapshot promotion (it
                        // stayed .holding below commit) or a pre-commit snapshot did (the release
                        // re-decision in activateHoldForReleaseLocked returned it to .pendingTap,
                        // so a phase check here would miss it): replays the base action with the
                        // plain hold tail — never max(tap) — with the tail clock starting at the
                        // release.
                        releasedAction = pressedHitAction
                        releasedTail = pressedHitTailDuration
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
        }
        pressedHitAction = nil
        pressedHitTapAction = nil
        pressedHitHoldAction = nil
        pressedHitHoldActionActive = false
        pressedHitRubAction = nil
        finishPressStateLocked(now: now)
    }

    /// Shared press-state teardown for pointer-up.
    private func finishPressStateLocked(now: CFTimeInterval) {
        pressedHitTrigger = nil
        pressedHitTapMode = .up
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
