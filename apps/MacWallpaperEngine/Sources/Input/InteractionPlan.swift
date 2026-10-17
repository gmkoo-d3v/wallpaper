import AppKit
import CoreGraphics
import Foundation

struct InteractionHitResult {
    let zoneID: String
    let action: String
    let tapAction: String?
    /// Committed-hold loop action: once the press crosses holdCommitSeconds this action is
    /// held (looped) until release, and the release falls to move/idle with releaseFade only
    /// (no committed-action tail replay). Validated together with an explicit positive
    /// holdCommitSeconds.
    let holdAction: String?
    let rubAction: String?
    let trigger: HitZoneTrigger
    /// Tap fire timing for tap-triggered zones; .up is the historical release-time behavior.
    let tapMode: HitZoneTapMode
    let tailSeconds: CFTimeInterval
    let tapTailSeconds: CFTimeInterval
    let rubTailSeconds: CFTimeInterval
    let holdStartSeconds: CFTimeInterval
    let holdCommitSeconds: CFTimeInterval
    /// True when the hit zone declared holdCommitSeconds explicitly (any value). The value
    /// semantics collapse nil to holdStart/0, so the controller cannot distinguish an
    /// explicit 0 (no tap window) from absent commit timing without this flag.
    let holdCommitSecondsDeclared: Bool
    /// True when the hit zone declared holdStartSeconds explicitly. With both start and
    /// commit omitted, the controller applies the default short-touch tap window instead of
    /// collapsing the commit to 0.
    let holdStartSecondsDeclared: Bool
    let rubStartSeconds: CFTimeInterval
    let rubStartDistance: CGFloat

    /// True when the zone's effective holdStart value carries an explicit declaration:
    /// declared start, or declared commit (whose value collapses into the effective start
    /// when start is absent). Used for the both-omitted default tap-window rule.
    var holdEffectiveStartDeclared: Bool { holdStartSecondsDeclared || holdCommitSecondsDeclared }
}

struct InteractionHitZoneSummary {
    let id: String
    let action: String
    let tapAction: String?
    let holdAction: String?
    let rubAction: String?
    let trigger: HitZoneTrigger
    let tapMode: HitZoneTapMode
    let declaredTailSeconds: CFTimeInterval
    let tailSeconds: CFTimeInterval
    let declaredTapTailSeconds: CFTimeInterval
    let tapTailSeconds: CFTimeInterval
    let declaredRubTailSeconds: CFTimeInterval
    let rubTailSeconds: CFTimeInterval
    let holdStartSeconds: CFTimeInterval
    let holdCommitSeconds: CFTimeInterval
    let rubStartSeconds: CFTimeInterval
    let rubStartDistance: CGFloat
    let buttons: [PointerButton]
    let rect: [Double]
    let shape: String
    let priority: Int
    /// True geometric center of the zone shape (ellipse center / polygon centroid), when the
    /// zone declares one. The bbox center is unreliable for edge-clipped bounds (the bounds
    /// clip at the 0..1 content edges) and for zones whose bbox center falls inside a
    /// higher-priority overlapping zone; diagnostics that must probe a zone itself use this.
    let geometricCenter: CGPoint?

    var detailText: String {
        let buttonText = buttons.map(\.rawValue).joined(separator: "+")
        let rectText = rect.map { String(format: "%.3f", $0) }.joined(separator: ",")
        let tailText = String(format: "%.2fs", declaredTailSeconds)
        // Appended last so zones without an explicit tapMode keep the exact pre-tapMode
        // byte layout of the hit-zone detail line.
        let tapModeText = trigger == .tap && tapMode == .down ? " tapMode=down" : ""
        let effectiveTail = effectiveTailText(
            label: "effectiveTail",
            declared: declaredTailSeconds,
            effective: tailSeconds
        )
        let tapText = tapAction.map {
            let effectiveTapTail = effectiveTailText(
                label: "effectiveTapTail",
                declared: declaredTapTailSeconds,
                effective: tapTailSeconds
            )
            let holdCommitText = holdCommitSeconds > holdStartSeconds + 0.005
                ? " holdCommit=\(String(format: "%.2fs", holdCommitSeconds))"
                : ""
            let holdActionText = holdAction.map { " holdAction=\($0)" } ?? ""
            return " tapAction=\($0) tapTail=\(String(format: "%.2fs", declaredTapTailSeconds))\(effectiveTapTail) holdStart=\(String(format: "%.2fs", holdStartSeconds))\(holdCommitText)\(holdActionText)"
        } ?? ""
        // Zones without a declared tapAction render with a bare hold-action annotation so
        // the committed-hold loop stays visible; zones without holdAction keep the exact
        // pre-holdAction byte layout.
        let bareHoldActionText = tapAction == nil
            ? (holdAction.map { " holdAction=\($0)" } ?? "")
            : ""
        let rubText = rubAction.map {
            let effectiveRubTail = effectiveTailText(
                label: "effectiveRubTail",
                declared: declaredRubTailSeconds,
                effective: rubTailSeconds
            )
            return " rubAction=\($0) rubTail=\(String(format: "%.2fs", declaredRubTailSeconds))\(effectiveRubTail) rubStart=\(String(format: "%.2fs", rubStartSeconds)) rubDistance=\(String(format: "%.3f", Double(rubStartDistance)))"
        } ?? ""
        return "\(id):\(action) trigger=\(trigger.rawValue)\(tapText)\(bareHoldActionText)\(rubText) buttons=\(buttonText) priority=\(priority) shape=\(shape) bounds=[\(rectText)] tail=\(tailText)\(effectiveTail)\(tapModeText)"
    }

    private func effectiveTailText(label: String, declared: CFTimeInterval, effective: CFTimeInterval) -> String {
        guard abs(declared - effective) >= 0.005 else { return "" }
        return " \(label)=\(String(format: "%.2fs", effective))"
    }
}

struct InteractionDefaultActionSummary {
    let action: String
    let trigger: HitZoneTrigger
    let tailSeconds: CFTimeInterval
    let buttons: [PointerButton]

    var detailText: String {
        let buttonText = buttons.map(\.rawValue).joined(separator: "+")
        let tailText = String(format: "%.2fs", tailSeconds)
        return "\(action) trigger=\(trigger.rawValue) buttons=\(buttonText) tail=\(tailText)"
    }
}

struct PointerMoveInputMask: Equatable {
    let acceptsUnbuttoned: Bool
    let buttons: Set<PointerButton>

    static let none = PointerMoveInputMask(acceptsUnbuttoned: false, buttons: [])
    static let all = PointerMoveInputMask(acceptsUnbuttoned: true, buttons: [.left, .right])

    var acceptsAnyMove: Bool {
        acceptsUnbuttoned || buttons.isEmpty == false
    }

    func accepts(button: PointerButton?) -> Bool {
        guard let button else {
            return acceptsUnbuttoned
        }
        return buttons.contains(button)
    }
}

private final class InteractionDiagnosticClock {
    var time: CFTimeInterval = 0

    func now() -> CFTimeInterval {
        time
    }
}

struct InteractionPlan {
    static let pointerSmoothingReferenceFps: Double = 60
    static let maxPointerSmoothingElapsedSeconds: CFTimeInterval = 1.0 / 30.0

    private let interactions: [InteractionConfig]
    private let pointerSmoothing: CGFloat
    private let idleDeadZone: CGFloat
    private let directionSwitchMargin: CGFloat
    private let defaultClickTailDuration: CFTimeInterval
    private let actionTailDurations: [String: CFTimeInterval]
    private let pointerDownBindings: [DeclarativeBindingPlanEntry]
    private let triggerPlayBindings: [DeclarativeBindingPlanEntry]

    init(
        interactions: [InteractionConfig],
        policy: InteractionPolicy?,
        actionTailDurations: [String: CFTimeInterval] = [:],
        declarativePlan: DeclarativeBindingPlan? = nil
    ) {
        self.interactions = interactions
        self.pointerSmoothing = CGFloat(policy?.pointerSmoothing ?? 0.18)
        self.idleDeadZone = CGFloat(policy?.idleDeadZone ?? 0.18)
        self.directionSwitchMargin = CGFloat(policy?.directionSwitchMargin ?? 0.10)
        self.defaultClickTailDuration = policy?.defaultClickTailSeconds ?? 1.15
        self.actionTailDurations = actionTailDurations
        self.pointerDownBindings = (declarativePlan?.bindingEntries ?? []).filter { entry in
            entry.isEnabled
                && entry.runtimeStatus == .runtimeExecutable
                && (entry.source == .pointerDown
                    || entry.source == .pointerPressDuration
                    || entry.source == .pointerDragDistance)
        }
        self.triggerPlayBindings = declarativePlan?.triggerPlayBindings ?? []
    }

    /// Tail duration for an action value. Colon values are random animation pairs, so the
    /// effective tail is the maximum tail over the components that have a known duration.
    private func tailDuration(for action: String) -> CFTimeInterval? {
        if let duration = actionTailDurations[action] {
            return duration
        }
        guard action.contains(":") else { return nil }
        let componentDurations = SpineInteractionAnimationRoles.components(of: action)
            .compactMap { actionTailDurations[$0] }
        return componentDurations.max()
    }

    func smooth(
        current: CGPoint,
        target: CGPoint,
        elapsedSeconds: CFTimeInterval = 1.0 / InteractionPlan.pointerSmoothingReferenceFps
    ) -> CGPoint {
        let clampedTarget = clamp(target)
        guard pointerSmoothing > 0 else {
            return clampedTarget
        }
        let clampedElapsed = min(
            max(elapsedSeconds, 0),
            InteractionPlan.maxPointerSmoothingElapsedSeconds
        )
        let frameEquivalent = clampedElapsed * InteractionPlan.pointerSmoothingReferenceFps
        let alpha = CGFloat(1.0 - pow(1.0 - Double(pointerSmoothing), frameEquivalent))
        return CGPoint(
            x: current.x + (clampedTarget.x - current.x) * alpha,
            y: current.y + (clampedTarget.y - current.y) * alpha
        )
    }

    /// Continuous per-axis quadrant gaze weights for a lookDirection pointerMove interaction.
    /// The pointer offset from neutral is scaled to [-1,1] and multiplied by sensitivity, then
    /// smoothed exponentially toward that target with returnSpeed (time-based, same pattern as
    /// `smooth`). Weights are per-axis quadrant weights (NOT sum-normalized): left/right come
    /// from the x axis, up/down from the y axis, each capped at 1.
    /// The per-axis ClampMagnitude(1) cap is applied to the SENSITIVITY-SCALED target, matching
    /// the source behavior (target = ((viewport − 0.5) × 2) × gazeSensitivity, then
    /// ClampMagnitude(1)): a sensitivity above 1 saturates a quadrant weight before the pointer
    /// reaches the screen edge (1.2 saturates at half the neutral-to-edge distance), and an
    /// absent/nil sensitivity (resolved to 1 by the caller) keeps the edge-normalized mapping.
    func gazeWeights(
        point: CGPoint,
        previous: CGPoint,
        elapsedSeconds: CFTimeInterval,
        sensitivity: Double,
        returnSpeed: Double,
        actions: [String: String]
    ) -> [(action: String, weight: Double)] {
        let pointer = clamp(point)
        let neutral = Self.point(
            interactions.first(where: { $0.event == .pointerMove })?.neutralPoint,
            fallback: CGPoint(x: 0.5, y: 0.5)
        )
        let targetX = min(max(Double((pointer.x - neutral.x) * 2) * sensitivity, -1), 1)
        let targetY = min(max(Double((pointer.y - neutral.y) * 2) * sensitivity, -1), 1)
        // Exponential smoothing toward the target, frame-rate independent. returnSpeed is a RATE
        // in 1/seconds (not a per-frame ratio), so alpha = 1 - exp(-returnSpeed * elapsed): any
        // positive rate converges, and equal wall-clock time converges equally at 30Hz and 60Hz.
        let clampedElapsed = min(
            max(elapsedSeconds, 0),
            InteractionPlan.maxPointerSmoothingElapsedSeconds
        )
        let alpha = 1.0 - exp(-max(returnSpeed, 0) * clampedElapsed)
        let vx = min(max(Double(previous.x) + (targetX - Double(previous.x)) * alpha, -1), 1)
        let vy = min(max(Double(previous.y) + (targetY - Double(previous.y)) * alpha, -1), 1)
        var weights: [(action: String, weight: Double)] = []
        if let action = actions["left"], vx < 0 {
            weights.append((action: action, weight: min(-vx, 1)))
        }
        if let action = actions["right"], vx > 0 {
            weights.append((action: action, weight: min(vx, 1)))
        }
        if let action = actions["up"], vy < 0 {
            weights.append((action: action, weight: min(-vy, 1)))
        }
        if let action = actions["down"], vy > 0 {
            weights.append((action: action, weight: min(vy, 1)))
        }
        return weights
    }

    func command(for point: CGPoint, previousCommand: String = "idle") -> String {
        let pointer = clamp(point)
        guard let config = interactions.first(where: { $0.event == .pointerMove }),
              config.mapping == "lookDirection",
              let actions = config.actions,
              let idleAction = actions["idle"],
              let leftAction = actions["left"],
              let rightAction = actions["right"],
              let upAction = actions["up"],
              let downAction = actions["down"] else {
            return "idle"
        }
        let effectivePreviousCommand = previousCommand == "idle" ? idleAction : previousCommand
        let neutral = Self.point(config.neutralPoint, fallback: CGPoint(x: 0.5, y: 0.5))
        let deadZone = Self.point(config.deadZone, fallback: CGPoint(x: idleDeadZone, y: idleDeadZone))
        let dx = pointer.x - neutral.x
        let dy = pointer.y - neutral.y
        if abs(dx) < deadZone.x, abs(dy) < deadZone.y {
            return idleAction
        }
        if abs(dx) > abs(dy) + directionSwitchMargin {
            return dx < 0 ? leftAction : rightAction
        }
        if abs(dy) > abs(dx) + directionSwitchMargin {
            return dy < 0 ? upAction : downAction
        }
        return effectivePreviousCommand
    }

    /// Gaze config of the lookDirection pointerMove interaction, if declared.
    func pointerMoveGazeConfig() -> PointerMoveGazeConfig? {
        interactions.first(where: {
            $0.event == .pointerMove && $0.mapping == "lookDirection"
        })?.gaze
    }

    /// Action map of the lookDirection pointerMove interaction, if declared.
    func pointerMoveActions() -> [String: String]? {
        interactions.first(where: {
            $0.event == .pointerMove && $0.mapping == "lookDirection"
        })?.actions
    }

    func idleCommand() -> String {
        interactions.first {
            $0.event == .pointerMove && $0.mapping == "lookDirection"
        }?.actions?["idle"] ?? "idle"
    }

    func allowsPointerMove(button: PointerButton?) -> Bool {
        pointerMoveInputMask().accepts(button: button)
    }

    func pointerMoveInputMask() -> PointerMoveInputMask {
        guard let config = interactions.first(where: { $0.event == .pointerMove }) else {
            return .none
        }
        guard let buttons = config.buttons else {
            return .all
        }
        return PointerMoveInputMask(acceptsUnbuttoned: false, buttons: Set(buttons))
    }

    func lookNeutralPoint() -> CGPoint {
        let config = interactions.first(where: { $0.event == .pointerMove })
        return Self.point(config?.neutralPoint, fallback: CGPoint(x: 0.5, y: 0.5))
    }

    func hitTest(point: CGPoint, button: PointerButton) -> InteractionHitResult? {
        // A manifest-declared pointerDown interaction owns hit testing; declarative
        // trigger-play bindings are the fallback for bundles without one.
        if pointerDownConfig() != nil {
            return legacyHitTest(point: point, button: button)
        }
        if let legacyHit = legacyHitTest(point: point, button: button) {
            return legacyHit
        }
        return bindingTriggerHit(button: button)
    }

    private func bindingTriggerHit(button: PointerButton) -> InteractionHitResult? {
        guard button == .left,
              let binding = triggerPlayBindings.first else {
            return nil
        }
        let action = binding.target.id
        return InteractionHitResult(
            zoneID: "binding:\(binding.id)",
            action: action,
            tapAction: nil,
            holdAction: nil,
            rubAction: nil,
            trigger: .tap,
            tapMode: .up,
            tailSeconds: tailDuration(for: action) ?? defaultClickTailDuration,
            tapTailSeconds: tailDuration(for: action) ?? defaultClickTailDuration,
            rubTailSeconds: tailDuration(for: action) ?? defaultClickTailDuration,
            holdStartSeconds: 0,
            holdCommitSeconds: 0,
            holdCommitSecondsDeclared: false,
            holdStartSecondsDeclared: false,
            rubStartSeconds: 0,
            rubStartDistance: 0.035
        )
    }

    func hasPointerDownBindingTriggers() -> Bool {
        triggerPlayBindings.isEmpty == false
    }

    func pointerDownBindingSummaries() -> [String] {
        pointerDownBindings.map { binding in
            "\(binding.id):\(binding.source.rawValue)->\(binding.target.summary)"
        }
    }

    private func pointerDownConfig() -> InteractionConfig? {
        interactions.first(where: { $0.event == .pointerDown })
    }

    private func pointerDownButtons(from config: InteractionConfig?) -> [PointerButton] {
        config?.buttons ?? [.left]
    }

    func acceptsPointerDown(button: PointerButton) -> Bool {
        if let config = pointerDownConfig() {
            return pointerDownButtons(from: config).contains(button)
        }
        return button == .left && pointerDownBindings.isEmpty == false
    }

    private func legacyHitTest(point: CGPoint, button: PointerButton) -> InteractionHitResult? {
        let pointer = clamp(point)
        guard let config = pointerDownConfig() else {
            return nil
        }
        let interactionButtons = pointerDownButtons(from: config)
        guard interactionButtons.contains(button) else { return nil }
        let matches = (config.hitZones ?? []).enumerated().compactMap { index, hitZone -> (index: Int, hitZone: HitZone)? in
            let zoneButtons = hitZone.buttons ?? interactionButtons
            guard zoneButtons.contains(button), contains(point: pointer, in: hitZone) else { return nil }
            return (index, hitZone)
        }
        // CIL first-match semantics: the shipped code tests zones in decision
        // order and BREAKS on the first hit, so the winner is the highest-priority
        // zone and, among equal priorities, the FIRST-declared one (stable). Sort
        // by (priority DESC, declaration index ASC) and take the first. Zone area
        // must never override priority — a large low-priority zone must not shadow
        // a small high-priority one.
        let ordered = matches.sorted { left, right in
            let leftPriority = left.hitZone.priority ?? 0
            let rightPriority = right.hitZone.priority ?? 0
            if leftPriority != rightPriority {
                return leftPriority > rightPriority
            }
            return left.index < right.index
        }
        if let selected = ordered.first?.hitZone {
            return InteractionHitResult(
                zoneID: selected.id,
                action: selected.action,
                tapAction: selected.tapAction,
                holdAction: selected.holdAction,
                rubAction: selected.rubAction,
                trigger: selected.trigger ?? .tap,
                tapMode: selected.tapMode ?? .up,
                tailSeconds: resolvedTailSeconds(for: selected),
                tapTailSeconds: resolvedTapTailSeconds(for: selected),
                rubTailSeconds: resolvedRubTailSeconds(for: selected),
                holdStartSeconds: selected.holdStartSeconds ?? 0,
                holdCommitSeconds: selected.holdCommitSeconds ?? selected.holdStartSeconds ?? 0,
                holdCommitSecondsDeclared: selected.holdCommitSeconds != nil,
                holdStartSecondsDeclared: selected.holdStartSeconds != nil,
                rubStartSeconds: selected.rubStartSeconds ?? 0,
                rubStartDistance: CGFloat(selected.rubStartDistance ?? 0.035)
            )
        }
        if let defaultAction = config.defaultAction {
            let defaultButtons = defaultAction.buttons ?? interactionButtons
            guard defaultButtons.contains(button) else { return nil }
            return InteractionHitResult(
                zoneID: "default",
                action: defaultAction.action,
                tapAction: nil,
                holdAction: nil,
                rubAction: nil,
                trigger: defaultAction.trigger ?? .tap,
                tapMode: .up,
                tailSeconds: resolvedTailSeconds(for: defaultAction),
                tapTailSeconds: resolvedTailSeconds(for: defaultAction),
                rubTailSeconds: resolvedTailSeconds(for: defaultAction),
                holdStartSeconds: 0,
                holdCommitSeconds: 0,
                holdCommitSecondsDeclared: false,
                holdStartSecondsDeclared: false,
                rubStartSeconds: 0,
                rubStartDistance: 0.035
            )
        }
        return nil
    }

    func hitZoneSummaries() -> [InteractionHitZoneSummary] {
        guard let config = interactions.first(where: { $0.event == .pointerDown }),
              let hitZones = config.hitZones else {
            return []
        }
        let interactionButtons = config.buttons ?? [.left]
        return hitZones.map { hitZone in
            InteractionHitZoneSummary(
                id: hitZone.id,
                action: hitZone.action,
                tapAction: hitZone.tapAction,
                holdAction: hitZone.holdAction,
                rubAction: hitZone.rubAction,
                trigger: hitZone.trigger ?? .tap,
                tapMode: hitZone.tapMode ?? .up,
                declaredTailSeconds: declaredTailSeconds(for: hitZone),
                tailSeconds: resolvedTailSeconds(for: hitZone),
                declaredTapTailSeconds: declaredTapTailSeconds(for: hitZone),
                tapTailSeconds: resolvedTapTailSeconds(for: hitZone),
                declaredRubTailSeconds: declaredRubTailSeconds(for: hitZone),
                rubTailSeconds: resolvedRubTailSeconds(for: hitZone),
                holdStartSeconds: hitZone.holdStartSeconds ?? 0,
                holdCommitSeconds: hitZone.holdCommitSeconds ?? hitZone.holdStartSeconds ?? 0,
                rubStartSeconds: hitZone.rubStartSeconds ?? 0,
                rubStartDistance: CGFloat(hitZone.rubStartDistance ?? 0.035),
                buttons: hitZone.buttons ?? interactionButtons,
                rect: bounds(of: hitZone),
                shape: shapeName(of: hitZone),
                priority: hitZone.priority ?? 0,
                geometricCenter: geometricCenter(of: hitZone)
            )
        }
    }

    func defaultActionSummary() -> InteractionDefaultActionSummary? {
        guard let config = interactions.first(where: { $0.event == .pointerDown }),
              let defaultAction = config.defaultAction else {
            return nil
        }
        let interactionButtons = config.buttons ?? [.left]
        return InteractionDefaultActionSummary(
            action: defaultAction.action,
            trigger: defaultAction.trigger ?? .tap,
            tailSeconds: resolvedTailSeconds(for: defaultAction),
            buttons: defaultAction.buttons ?? interactionButtons
        )
    }

    static func diagnosticSummary(
        interactions: [InteractionConfig],
        policy: InteractionPolicy?,
        runtimeInteractive: Bool,
        actionTailDurations: [String: CFTimeInterval] = [:],
        declarativePlan: DeclarativeBindingPlan? = nil,
        fitMode: RenderFitMode? = nil,
        contentAspect: CGFloat? = nil,
        accessibilityTrusted: Bool? = nil
    ) -> String {
        let plan = InteractionPlan(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations,
            declarativePlan: declarativePlan
        )
        let hasDeclarativePointerInput = declarativePlan?.hasPointerInputBindings == true
        let effectivePolicy = policy ?? InteractionPolicy(
            mode: runtimeInteractive ? .desktopEmptyOnly : .disabled,
            blockApplicationWindows: true,
            blockDesktopItems: true,
            pointerSmoothing: nil,
            pointerSampleFps: nil,
            idleDeadZone: nil,
            directionSwitchMargin: nil,
            defaultClickTailSeconds: nil,
            releaseFadeSeconds: nil
        )
        let mode = policy?.mode.rawValue ?? (runtimeInteractive ? "desktop-empty-only(default)" : "disabled(default)")
        let monitorStatus = desktopMonitorStatus(
            interactions: interactions,
            hasDeclarativePointerInput: hasDeclarativePointerInput,
            policy: effectivePolicy,
            runtimeInteractive: runtimeInteractive,
            accessibilityTrusted: accessibilityTrusted
        )
        let moveConfig = interactions.first { $0.event == .pointerMove }
        let clickConfig = interactions.first { $0.event == .pointerDown }
        let moveMapping = moveConfig?.mapping ?? "none"
        let moveActions = moveConfig?.actions?
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",") ?? "none"
        let moveButtons = moveConfig.map { config in
            (config.buttons ?? []).map(\.rawValue).joined(separator: "+")
        } ?? "none"
        let neutralPoint = Self.point(moveConfig?.neutralPoint, fallback: CGPoint(x: 0.5, y: 0.5))
        let moveDeadZone = Self.point(moveConfig?.deadZone, fallback: CGPoint(x: plan.idleDeadZone, y: plan.idleDeadZone))
        let clickButtons = (clickConfig?.buttons ?? [.left]).map(\.rawValue).joined(separator: "+")
        let zones = plan.hitZoneSummaries()
        let defaultAction = plan.defaultActionSummary()
        let pointerDownBindingSummaries = plan.pointerDownBindingSummaries()
        let pointerDownBindingText = pointerDownBindingSummaries.isEmpty
            ? "none"
            : pointerDownBindingSummaries.joined(separator: "+")
        let idleProbePrevious = moveConfig?.actions?["idle"] ?? "idle"
        let stickyProbePrevious = moveConfig?.actions?["right"] ?? idleProbePrevious
        let moveProbeText = [
            "left=\(plan.command(for: CGPoint(x: 0.10, y: 0.50), previousCommand: idleProbePrevious))",
            "right=\(plan.command(for: CGPoint(x: 0.90, y: 0.50), previousCommand: idleProbePrevious))",
            "up=\(plan.command(for: CGPoint(x: 0.50, y: 0.10), previousCommand: idleProbePrevious))",
            "down=\(plan.command(for: CGPoint(x: 0.50, y: 0.90), previousCommand: idleProbePrevious))",
            "center=\(plan.command(for: CGPoint(x: 0.50, y: 0.50), previousCommand: stickyProbePrevious))",
            "neutral=\(plan.command(for: neutralPoint, previousCommand: stickyProbePrevious))"
        ].joined(separator: " ")
        var lines = [
            "interaction plan OK",
            "runtimeInteractive: \(runtimeInteractive ? "enabled" : "disabled")",
            "policyMode: \(mode)",
            "desktopMonitor: \(monitorStatus)",
            "outsideContentTracking: \(RuntimeLifecyclePolicy.outsideContentTrackingPolicy)",
            "blockedDesktopEventTracking: \(RuntimeLifecyclePolicy.blockedDesktopEventTrackingPolicy)",
            "blockApplicationWindows: \(policy?.blockApplicationWindows ?? true)",
            "blockDesktopItems: \(policy?.blockDesktopItems ?? true)",
            "pointerSmoothing: \(formatInteractionNumber(Double(policy?.pointerSmoothing ?? 0.18)))",
            "pointerSampleFps: \(formatInteractionNumber(policy?.pointerSampleFps ?? 30))",
            "pointerSmoothingCadence: time-based referenceFps=\(formatInteractionNumber(InteractionPlan.pointerSmoothingReferenceFps)) maxDeltaSeconds=\(formatInteractionNumber(InteractionPlan.maxPointerSmoothingElapsedSeconds))",
            "idleDeadZone: \(formatInteractionNumber(Double(policy?.idleDeadZone ?? 0.18)))",
            "pointerMoveNeutralPoint: \(formatPoint(neutralPoint))",
            "pointerMoveDeadZone: \(formatPoint(moveDeadZone))",
            "directionSwitchMargin: \(formatInteractionNumber(Double(policy?.directionSwitchMargin ?? 0.10)))",
            "defaultClickTailSeconds: \(formatInteractionNumber(policy?.defaultClickTailSeconds ?? 1.15))",
            "releaseFadeSeconds: \(formatInteractionNumber(policy?.releaseFadeSeconds ?? 0.20))",
            "pointerMove: \(moveMapping)",
            "pointerMoveButtons: \(moveButtons.isEmpty ? "any" : moveButtons)",
            "pointerMoveActions: \(moveActions)"
        ]
        if let gaze = moveConfig?.gaze {
            lines.append("pointerMoveGaze: sensitivity=\(formatInteractionNumber(gaze.sensitivity ?? 0)),returnSpeed=\(formatInteractionNumber(gaze.returnSpeed ?? 0))")
        }
        lines += [
            "pointerMoveProbes: \(moveProbeText)"
        ] + eventGateProbeLines(
            policy: effectivePolicy,
            accessibilityTrusted: accessibilityTrusted
        ) + inputSourceProbeLines(
            policy: effectivePolicy,
            pointerMoveInputMask: plan.pointerMoveInputMask()
        ) + [
            "pointerDownButtons: \(clickConfig == nil ? "none" : clickButtons)",
            "pointerDownBindings: \(pointerDownBindingText)",
            "defaultAction: \(defaultAction?.detailText ?? "none")",
            "hitZones: \(zones.count)"
        ]

        if zones.isEmpty {
            lines.append("hitZoneDetails: none")
        } else {
            for zone in zones {
                let center = CGPoint(
                    x: CGFloat((zone.rect[0] + zone.rect[2]) / 2.0),
                    y: CGFloat((zone.rect[1] + zone.rect[3]) / 2.0)
                )
                let leftHit = plan.hitTest(point: center, button: .left)
                let rightHit = plan.hitTest(point: center, button: .right)
                let acceptedButtons = zone.buttons.map(\.rawValue).joined(separator: "+")
                let probeController = InteractionController(
                    interactions: interactions,
                    policy: policy,
                    actionTailDurations: actionTailDurations,
                    declarativePlan: declarativePlan
                )
                let probeButton = zone.buttons.first ?? .left
                probeController.pointerDown(at: center, button: probeButton)
                let downSnapshot = probeController.snapshot()
                probeController.pointerUp(at: center, button: probeButton)
                let upSnapshot = probeController.snapshot()
                lines.append("hitZone: \(zone.detailText)")
                lines.append([
                    "hitProbe: \(zone.id)",
                    "center=\(formatPoint(center))",
                    "accepts=\(acceptedButtons)",
                    "left=\(leftHit?.action ?? "none")",
                    "right=\(rightHit?.action ?? "none")"
                ].joined(separator: " "))
                lines.append([
                    "clickProbe: \(zone.id)",
                    "button=\(probeButton.rawValue)",
                    "down=\(downSnapshot.command)",
                    "downPulse=\(formatInteractionNumber(Double(downSnapshot.clickPulse)))",
                    "up=\(upSnapshot.command)",
                    "upPulse=\(formatInteractionNumber(Double(upSnapshot.clickPulse)))"
                ].joined(separator: " "))
                lines.append(Self.clickTimelineText(
                    label: zone.id,
                    point: center,
                    button: probeButton,
                    trigger: zone.trigger,
                    tapMode: zone.tapMode,
                    tailSeconds: zone.tailSeconds,
                    holdStartSeconds: zone.holdStartSeconds,
                    holdCommitSeconds: zone.holdCommitSeconds,
                    interactions: interactions,
                    policy: policy,
                    actionTailDurations: actionTailDurations,
                    declarativePlan: declarativePlan
                ))
                if zone.tapAction != nil || zone.rubAction != nil || zone.holdAction != nil {
                    lines.append(Self.gestureProbeText(
                        zone: zone,
                        point: center,
                        button: probeButton,
                        interactions: interactions,
                        policy: policy,
                        actionTailDurations: actionTailDurations,
                        declarativePlan: declarativePlan
                    ))
                }
            }
        }
        if let defaultAction {
            let probeController = InteractionController(
                interactions: interactions,
                policy: policy,
                actionTailDurations: actionTailDurations,
                declarativePlan: declarativePlan
            )
            let probeButton = defaultAction.buttons.first ?? .left
            let probePoint = CGPoint(x: 0.02, y: 0.02)
            let hit = plan.hitTest(point: probePoint, button: probeButton)
            probeController.pointerDown(at: probePoint, button: probeButton)
            let downSnapshot = probeController.snapshot()
            probeController.pointerUp(at: probePoint, button: probeButton)
            let upSnapshot = probeController.snapshot()
            lines.append([
                "defaultHitProbe:",
                "point=\(formatPoint(probePoint))",
                "button=\(probeButton.rawValue)",
                "hit=\(hit?.action ?? "none")"
            ].joined(separator: " "))
            lines.append([
                "defaultClickProbe:",
                "button=\(probeButton.rawValue)",
                "down=\(downSnapshot.command)",
                "downPulse=\(formatInteractionNumber(Double(downSnapshot.clickPulse)))",
                "up=\(upSnapshot.command)",
                "upPulse=\(formatInteractionNumber(Double(upSnapshot.clickPulse)))"
            ].joined(separator: " "))
            lines.append(Self.clickTimelineText(
                label: "default",
                point: probePoint,
                button: probeButton,
                trigger: defaultAction.trigger,
                tailSeconds: defaultAction.tailSeconds,
                holdStartSeconds: 0,
                holdCommitSeconds: 0,
                interactions: interactions,
                policy: policy,
                actionTailDurations: actionTailDurations,
                declarativePlan: declarativePlan
            ))
        }
        if let fitMode, let contentAspect {
            lines.append(contentsOf: Self.coordinateProbeLines(
                plan: plan,
                zones: zones,
                defaultAction: defaultAction,
                fitMode: fitMode,
                contentAspect: contentAspect
            ))
        }
        return lines.joined(separator: "\n")
    }

    static func probeSummary(
        interactions: [InteractionConfig],
        policy: InteractionPolicy?,
        runtimeInteractive: Bool,
        point: CGPoint,
        button: PointerButton,
        actionTailDurations: [String: CFTimeInterval] = [:],
        declarativePlan: DeclarativeBindingPlan? = nil
    ) -> String {
        let plan = InteractionPlan(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations,
            declarativePlan: declarativePlan
        )
        let clampedPoint = plan.clamp(point)
        let moveConfig = interactions.first { $0.event == .pointerMove }
        let neutralPoint = Self.point(moveConfig?.neutralPoint, fallback: CGPoint(x: 0.5, y: 0.5))
        let moveDeadZone = Self.point(moveConfig?.deadZone, fallback: CGPoint(x: plan.idleDeadZone, y: plan.idleDeadZone))
        let idleProbePrevious = moveConfig?.actions?["idle"] ?? "idle"
        let stickyProbePrevious = moveConfig?.actions?["right"] ?? idleProbePrevious
        let moveCommand = plan.command(for: clampedPoint, previousCommand: idleProbePrevious)
        let stickyCommand = plan.command(for: clampedPoint, previousCommand: stickyProbePrevious)
        let hit = plan.hitTest(point: clampedPoint, button: button)

        let clock = InteractionDiagnosticClock()
        let controller = InteractionController(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations,
            declarativePlan: declarativePlan,
            clock: clock.now
        )
        controller.pointerMoved(to: clampedPoint)
        var steadyMove = controller.snapshot()
        for _ in 0..<20 {
            clock.time += 1.0 / InteractionPlan.pointerSmoothingReferenceFps
            steadyMove = controller.snapshot()
        }
        controller.pointerDown(at: clampedPoint, button: button)
        let down = controller.snapshot()
        controller.pointerUp(at: clampedPoint, button: button)
        let up = controller.snapshot()
        let tailSeconds = max(hit?.tailSeconds ?? 0.20, 0.20)
        clock.time += tailSeconds + 0.10
        let expired = controller.snapshot()

        return [
            "interaction probe OK",
            "runtimeInteractive: \(runtimeInteractive ? "enabled" : "disabled")",
            "input: \(formatPoint(point))",
            "clamped: \(formatPoint(clampedPoint))",
            "button: \(button.rawValue)",
            "neutralPoint: \(formatPoint(neutralPoint))",
            "deadZone: \(formatPoint(moveDeadZone))",
            "moveCommand: \(moveCommand)",
            "stickyCommandFromRight: \(stickyCommand)",
            "hit: \(hit.map(hitText) ?? "none")",
            "steadyMoveAfter20Frames: \(snapshotText(steadyMove))",
            "downSnapshot: \(snapshotText(down))",
            "upSnapshot: \(snapshotText(up))",
            "expiredSnapshot: \(snapshotText(expired))"
        ].joined(separator: "\n")
    }

    private static func desktopMonitorStatus(
        interactions: [InteractionConfig],
        hasDeclarativePointerInput: Bool,
        policy: InteractionPolicy,
        runtimeInteractive: Bool,
        accessibilityTrusted: Bool?
    ) -> String {
        guard runtimeInteractive else { return "disabled(runtime-settings)" }
        guard interactions.isEmpty == false || hasDeclarativePointerInput else {
            return "passive(no-interactions)"
        }
        guard policy.mode != .disabled else { return "disabled(policy)" }
        let trusted = accessibilityTrusted ?? DesktopInteractionGate.hasAccessibilityTrust()
        if policy.mode == .desktopEmptyOnly, policy.blockDesktopItems {
            return trusted
                ? "ready(\(policy.mode.rawValue),event-tap+precise-desktop-items)"
                : "ready(\(policy.mode.rawValue),global-monitors-best-effort)"
        }
        return trusted
            ? "ready(\(policy.mode.rawValue),event-tap)"
            : "ready(\(policy.mode.rawValue),global-monitors)"
    }

    private static func eventGateProbeLines(
        policy: InteractionPolicy,
        accessibilityTrusted: Bool?
    ) -> [String] {
        let trusted = accessibilityTrusted ?? DesktopInteractionGate.hasAccessibilityTrust()
        return [
            eventGateProbeText(label: "eventGateProbes", policy: policy, accessibilityTrusted: trusted),
            eventGateProbeText(label: "eventGatePreciseItemProbes", policy: policy, accessibilityTrusted: true),
            eventGateProbeText(label: "eventGateNoPermissionProbes", policy: policy, accessibilityTrusted: false)
        ]
    }

    private static func eventGateProbeText(
        label: String,
        policy: InteractionPolicy,
        accessibilityTrusted: Bool
    ) -> String {
        [
            "\(label):",
            "desktopItemPrecision=\(accessibilityTrusted ? "precise" : "best-effort")",
            "emptyDesktopMove=\(DesktopInteractionGate.pointerMoveEligibilityDecision(policy: policy, accessibilityTrusted: accessibilityTrusted, coveredByApplicationWindow: false, likelyDesktopItem: false).rawValue)",
            "emptyDesktop=\(DesktopInteractionGate.eligibilityDecision(policy: policy, accessibilityTrusted: accessibilityTrusted, coveredByApplicationWindow: false, likelyDesktopItem: false).rawValue)",
            "appWindow=\(DesktopInteractionGate.eligibilityDecision(policy: policy, accessibilityTrusted: accessibilityTrusted, coveredByApplicationWindow: true, likelyDesktopItem: false).rawValue)",
            "desktopItem=\(DesktopInteractionGate.eligibilityDecision(policy: policy, accessibilityTrusted: accessibilityTrusted, coveredByApplicationWindow: false, likelyDesktopItem: true).rawValue)"
        ].joined(separator: " ")
    }

    private static func inputSourceProbeLines(
        policy: InteractionPolicy,
        pointerMoveInputMask: PointerMoveInputMask
    ) -> [String] {
        let passiveTrustedEventTap = formatInputSources(DesktopMouseInteractionMonitor.inputSources(
            usesPassiveEventMonitoring: true,
            eventTapStarted: true,
            accessibilityTrusted: true,
            pointerMoveInputMask: pointerMoveInputMask
        ))
        let passiveTrustedFallback = formatInputSources(DesktopMouseInteractionMonitor.inputSources(
            usesPassiveEventMonitoring: true,
            eventTapStarted: false,
            accessibilityTrusted: true,
            pointerMoveInputMask: pointerMoveInputMask
        ))
        let passiveMissingTrust = formatInputSources(DesktopMouseInteractionMonitor.inputSources(
            usesPassiveEventMonitoring: true,
            eventTapStarted: false,
            accessibilityTrusted: false,
            pointerMoveInputMask: pointerMoveInputMask
        ))
        let plainWindow = formatInputSources(DesktopMouseInteractionMonitor.inputSources(
            usesPassiveEventMonitoring: false,
            eventTapStarted: false,
            accessibilityTrusted: false,
            pointerMoveInputMask: pointerMoveInputMask
        ))
        let moveEvents = formatEventMask(
            DesktopMouseInteractionMonitor.globalMoveEventMask(pointerMoveInputMask: pointerMoveInputMask)
        )
        return [
            [
                "inputSourceProbes:",
                "policy=\(policy.mode.rawValue)",
                "moveEvents=\(moveEvents)",
                "passiveTrustedEventTap=\(passiveTrustedEventTap)",
                "passiveTrustedFallback=\(passiveTrustedFallback)",
                "passiveMissingTrust=\(passiveMissingTrust)",
                "plainWindow=\(plainWindow)"
            ].joined(separator: " ")
        ]
    }

    private static func formatEventMask(_ mask: NSEvent.EventTypeMask) -> String {
        var labels: [String] = []
        if mask.contains(.mouseMoved) {
            labels.append("hover")
        }
        if mask.contains(.leftMouseDragged) {
            labels.append("leftDrag")
        }
        if mask.contains(.rightMouseDragged) {
            labels.append("rightDrag")
        }
        return labels.isEmpty ? "none" : labels.joined(separator: "+")
    }

    private static func formatInputSources(_ sources: DesktopMouseInteractionMonitor.InputSources) -> String {
        var labels: [String] = []
        if sources.useEventTap {
            labels.append("eventTap")
        }
        if sources.useLocalMonitor {
            labels.append("local")
        }
        if sources.useGlobalMoveMonitor {
            labels.append("globalMove")
        }
        if sources.useGlobalClickMonitors {
            labels.append("globalClick")
        }
        return labels.isEmpty ? "none" : labels.joined(separator: "+")
    }

    private static func clickTimelineText(
        label: String,
        point: CGPoint,
        button: PointerButton,
        trigger: HitZoneTrigger,
        tapMode: HitZoneTapMode = .up,
        tailSeconds: CFTimeInterval,
        holdStartSeconds: CFTimeInterval,
        holdCommitSeconds: CFTimeInterval,
        interactions: [InteractionConfig],
        policy: InteractionPolicy?,
        actionTailDurations: [String: CFTimeInterval],
        declarativePlan: DeclarativeBindingPlan?
    ) -> String {
        let clock = InteractionDiagnosticClock()
        let controller = InteractionController(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations,
            declarativePlan: declarativePlan,
            clock: clock.now
        )
        let safeTail = max(tailSeconds, 0.001)
        controller.pointerDown(at: point, button: button)
        let down = controller.snapshot()

        switch trigger {
        case .tap:
            clock.time = 0.016
            controller.pointerUp(at: point, button: button)
            let up = controller.snapshot()
            clock.time = safeTail / 2.0
            let mid = controller.snapshot()
            clock.time = safeTail + 0.10
            let expired = controller.snapshot()
            return [
                "clickTimeline: \(label)",
                "button=\(button.rawValue)",
                "trigger=\(trigger.rawValue)",
                "down@0.000=\(snapshotText(down))",
                "up@0.016=\(snapshotText(up))",
                "mid@\(formatInteractionNumber(safeTail / 2.0))=\(snapshotText(mid))",
                "expired@\(formatInteractionNumber(safeTail + 0.10))=\(snapshotText(expired))"
            ].joined(separator: " ")
        case .hold:
            let preHoldSampleTime = max(0.016, min(max(holdStartSeconds - 0.05, 0.016), holdStartSeconds))
            clock.time = preHoldSampleTime
            let preHeld = controller.snapshot()
            let holdSampleTime = max(0.10, holdStartSeconds + 0.05)
            clock.time = holdSampleTime
            let held = controller.snapshot()
            if holdCommitSeconds > holdStartSeconds + 0.005 {
                let preCommitTime = max(holdStartSeconds + 0.01, min(holdCommitSeconds - 0.01, holdCommitSeconds))
                clock.time = preCommitTime
                let preCommit = controller.snapshot()
                controller.pointerUp(at: point, button: button)
                let preCommitUp = controller.snapshot()
                return [
                    "clickTimeline: \(label)",
                    "button=\(button.rawValue)",
                    "trigger=\(trigger.rawValue)",
                    "down@0.000=\(snapshotText(down))",
                    "preHold@\(formatInteractionNumber(preHoldSampleTime))=\(snapshotText(preHeld))",
                    "held@\(formatInteractionNumber(holdSampleTime))=\(snapshotText(held))",
                    "preCommit@\(formatInteractionNumber(preCommitTime))=\(snapshotText(preCommit))",
                    "preCommitUp@\(formatInteractionNumber(preCommitTime))=\(snapshotText(preCommitUp))"
                ].joined(separator: " ")
            }
            controller.pointerUp(at: point, button: button)
            let up = controller.snapshot()
            clock.time = holdSampleTime + (safeTail / 2.0)
            let fade = controller.snapshot()
            clock.time = holdSampleTime + safeTail + 0.10
            let expired = controller.snapshot()
            return [
                "clickTimeline: \(label)",
                "button=\(button.rawValue)",
                "trigger=\(trigger.rawValue)",
                "down@0.000=\(snapshotText(down))",
                "preHold@\(formatInteractionNumber(preHoldSampleTime))=\(snapshotText(preHeld))",
                "held@\(formatInteractionNumber(holdSampleTime))=\(snapshotText(held))",
                "up@\(formatInteractionNumber(holdSampleTime))=\(snapshotText(up))",
                "fade@\(formatInteractionNumber(holdSampleTime + (safeTail / 2.0)))=\(snapshotText(fade))",
                "expired@\(formatInteractionNumber(holdSampleTime + safeTail + 0.10))=\(snapshotText(expired))"
            ].joined(separator: " ")
        }
    }

    private static func gestureProbeText(
        zone: InteractionHitZoneSummary,
        point: CGPoint,
        button: PointerButton,
        interactions: [InteractionConfig],
        policy: InteractionPolicy?,
        actionTailDurations: [String: CFTimeInterval],
        declarativePlan: DeclarativeBindingPlan?
    ) -> String {
        let tapClock = InteractionDiagnosticClock()
        let tapController = InteractionController(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations,
            declarativePlan: declarativePlan,
            clock: tapClock.now
        )
        tapController.pointerDown(at: point, button: button)
        let tapDown = tapController.snapshot()
        // A positive commit threshold makes the probe release a pre-commit tap release: the
        // tap sample uses the commit-relative window, not a bare 16 ms touch, so zones with a
        // short commit still show the tap branch.
        let tapReleaseTime = zone.holdCommitSeconds > 0 ? min(0.016, zone.holdCommitSeconds * 0.25) : 0.016
        tapClock.time = tapReleaseTime
        tapController.pointerUp(at: point, button: button)
        let tapUp = tapController.snapshot()

        let holdClock = InteractionDiagnosticClock()
        let holdController = InteractionController(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations,
            declarativePlan: declarativePlan,
            clock: holdClock.now
        )
        holdController.pointerDown(at: point, button: button)
        let preHoldSampleTime = max(0.016, min(max(zone.holdStartSeconds - 0.05, 0.016), zone.holdStartSeconds))
        holdClock.time = preHoldSampleTime
        let preHold = holdController.snapshot()
        let holdSampleTime = max(0.10, zone.holdStartSeconds + 0.05)
        holdClock.time = holdSampleTime
        let held = holdController.snapshot()
        // For holdAction zones the shared hold press stays HELD through the committed probe
        // below: an early pointerUp would end the gesture, and the committed sample would
        // then read a finished press's tap tail instead of the live commit crossing (the
        // loop arms at holdCommit only while the press is live). Zones without holdAction
        // release here exactly as before, keeping their output byte-identical.
        var deferredHoldUp: InteractionSnapshot?
        if zone.holdAction == nil {
            holdController.pointerUp(at: point, button: button)
            deferredHoldUp = holdController.snapshot()
        }

        // Committed-hold probe (holdAction zones only, so the output for zones without
        // holdAction stays byte-identical): after the commit crossing the loop action is
        // held at pulse 1, and releasing stops the loop with the release fade only — the
        // command falls to the move/idle family with no committed-action tail replay.
        var committedHoldParts: [String] = []
        let releaseFade = policy?.releaseFadeSeconds ?? 0.20
        if let holdAction = zone.holdAction {
            // The press is still live: the first sample at/after the commit threshold arms
            // the loop through the controller's commit-crossing promotion (snapshot cadence,
            // never a release-replay shortcut).
            let committedHoldTime = max(zone.holdCommitSeconds + 0.05, holdSampleTime + 0.05)
            holdClock.time = committedHoldTime
            let committedHeld = holdController.snapshot()
            // Crossing cadence: hold one frame past the promotion so the committed sample
            // shows the loop held at pulse 1 (a snapshot exactly on the promotion tick still
            // carries the held-frame semantics), then release into the fade window.
            holdClock.time = committedHoldTime + 1.0 / 60.0
            _ = holdController.snapshot()
            holdClock.time = committedHoldTime + 0.01
            holdController.pointerUp(at: point, button: button)
            let committedUp = holdController.snapshot()
            holdClock.time = committedHoldTime + 0.01 + releaseFade + 0.05
            let committedExpired = holdController.snapshot()
            // The held hold press was consumed by the committed probe; the expired committed
            // snapshot doubles as the holdUp sample for holdAction zones.
            deferredHoldUp = committedExpired
            committedHoldParts = [
                "holdAction=\(holdAction)@commit\(formatInteractionNumber(zone.holdCommitSeconds))s",
                "committedHold@\(formatInteractionNumber(committedHoldTime))=\(snapshotText(committedHeld))",
                "committedUp@\(formatInteractionNumber(committedHoldTime + 0.01))=\(snapshotText(committedUp))",
                "committedExpired@\(formatInteractionNumber(committedHoldTime + 0.01 + releaseFade + 0.05))=\(snapshotText(committedExpired))"
            ]
        }

        let rubDelta = max(zone.rubStartDistance + 0.02, 0.02)
        let rubPoint = CGPoint(
            x: point.x + rubDelta <= 1.0 ? point.x + rubDelta : max(point.x - rubDelta, 0.0),
            y: point.y
        )
        let rubPoint2 = CGPoint(
            x: rubPoint.x + rubDelta <= 1.0 ? rubPoint.x + rubDelta : max(rubPoint.x - rubDelta, 0.0),
            y: point.y
        )
        let rubClock = InteractionDiagnosticClock()
        let rubController = InteractionController(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations,
            declarativePlan: declarativePlan,
            clock: rubClock.now
        )
        rubController.pointerDown(at: point, button: button)
        rubController.pointerDragged(to: rubPoint, button: button)
        let preRub = rubController.snapshot()
        if zone.rubStartSeconds > 0 {
            rubClock.time = max(zone.rubStartSeconds + 0.05, 0.10)
            _ = rubController.snapshot()
            rubController.pointerDragged(to: rubPoint2, button: button)
        }
        let rubDragged = rubController.snapshot()
        rubController.pointerUp(at: zone.rubStartSeconds > 0 ? rubPoint2 : rubPoint, button: button)
        let rubUp = rubController.snapshot()

        var probeParts = [
            "gestureProbe: \(zone.id)",
            "button=\(button.rawValue)",
            "tap=\(zone.tapAction ?? "none")",
            "hold=\(zone.action)@\(formatInteractionNumber(zone.holdStartSeconds))s",
            "holdCommit=\(formatInteractionNumber(zone.holdCommitSeconds))s",
            "rub=\(zone.rubAction ?? "none")@\(formatInteractionNumber(zone.rubStartSeconds))s+distance\(formatInteractionNumber(Double(zone.rubStartDistance)))",
            "tapDown@0.000=\(snapshotText(tapDown))",
            "tapUp@\(formatInteractionNumber(tapReleaseTime))=\(snapshotText(tapUp))",
            "preHold@\(formatInteractionNumber(preHoldSampleTime))=\(snapshotText(preHold))",
            "held@\(formatInteractionNumber(holdSampleTime))=\(snapshotText(held))",
            "holdUp@\(formatInteractionNumber(holdSampleTime))=\(deferredHoldUp.map(snapshotText) ?? "held")",
            "preRub@distance\(formatInteractionNumber(Double(rubDelta)))=\(snapshotText(preRub))",
            "rubDrag@distance\(formatInteractionNumber(Double(rubDelta)))=\(snapshotText(rubDragged))",
            "rubUp=\(snapshotText(rubUp))"
        ]
        probeParts.append(contentsOf: committedHoldParts)
        return probeParts.joined(separator: " ")
    }

    private static func coordinateProbeLines(
        plan: InteractionPlan,
        zones: [InteractionHitZoneSummary],
        defaultAction: InteractionDefaultActionSummary?,
        fitMode: RenderFitMode,
        contentAspect: CGFloat
    ) -> [String] {
        guard contentAspect.isFinite, contentAspect > 0 else { return [] }
        let mapper = InteractionCoordinateMapper(fitMode: fitMode, contentAspect: contentAspect)
        let views: [(name: String, aspect: CGFloat)] = [
            ("16:9", 16.0 / 9.0),
            ("21:9", 21.0 / 9.0),
            ("32:9", 32.0 / 9.0)
        ]
        var lines = [
            "coordinateProbes: fit=\(fitMode.rawValue) contentAspect=\(formatInteractionNumber(Double(contentAspect)))"
        ]

        for view in views {
            for zone in zones {
                let contentPoint = CGPoint(
                    x: CGFloat((zone.rect[0] + zone.rect[2]) / 2.0),
                    y: CGFloat((zone.rect[1] + zone.rect[3]) / 2.0)
                )
                lines.append(coordinateProbeLine(
                    label: zone.id,
                    contentPoint: contentPoint,
                    button: zone.buttons.first ?? .left,
                    view: view,
                    mapper: mapper,
                    plan: plan
                ))
            }
            if let defaultAction {
                lines.append(coordinateProbeLine(
                    label: "default",
                    contentPoint: CGPoint(x: 0.02, y: 0.02),
                    button: defaultAction.buttons.first ?? .left,
                    view: view,
                    mapper: mapper,
                    plan: plan
                ))
            }
            lines.append(outsideContentProbeLine(view: view, mapper: mapper))
        }
        return lines
    }

    private static func coordinateProbeLine(
        label: String,
        contentPoint: CGPoint,
        button: PointerButton,
        view: (name: String, aspect: CGFloat),
        mapper: InteractionCoordinateMapper,
        plan: InteractionPlan
    ) -> String {
        let windowPoint = mapper.windowNormalizedPoint(forContentPoint: contentPoint, viewAspect: view.aspect)
        let remapped = mapper.mapWindowNormalizedPoint(windowPoint, viewAspect: view.aspect)
        let hit = remapped.flatMap { plan.hitTest(point: $0, button: button) }
        return [
            "coordinateProbe:",
            "view=\(view.name)",
            "aspect=\(formatInteractionNumber(Double(view.aspect)))",
            "target=\(label)",
            "content=\(formatPoint(contentPoint))",
            "window=\(formatPoint(windowPoint))",
            "remap=\(remapped.map(formatPoint) ?? "outside")",
            "hit=\(hit?.action ?? "none")"
        ].joined(separator: " ")
    }

    private static func outsideContentProbeLine(
        view: (name: String, aspect: CGFloat),
        mapper: InteractionCoordinateMapper
    ) -> String {
        let probe = CGPoint(x: 0.02, y: 0.50)
        let remapped = mapper.mapWindowNormalizedPoint(probe, viewAspect: view.aspect)
        return [
            "coordinateProbe:",
            "view=\(view.name)",
            "outsideContentWindow=\(formatPoint(probe))",
            "remap=\(remapped.map(formatPoint) ?? "outside")"
        ].joined(separator: " ")
    }

    private static func snapshotText(_ snapshot: InteractionSnapshot) -> String {
        "\(snapshot.command)/\(formatInteractionNumber(Double(snapshot.clickPulse)))"
    }

    private static func hitText(_ hit: InteractionHitResult) -> String {
        let tapText = hit.tapAction.map {
            " tapAction=\($0) tapTail=\(formatInteractionNumber(hit.tapTailSeconds)) holdStart=\(formatInteractionNumber(hit.holdStartSeconds)) holdCommit=\(formatInteractionNumber(hit.holdCommitSeconds))"
        } ?? ""
        let rubText = hit.rubAction.map {
            " rubAction=\($0) rubTail=\(formatInteractionNumber(hit.rubTailSeconds)) rubStart=\(formatInteractionNumber(hit.rubStartSeconds)) rubDistance=\(formatInteractionNumber(Double(hit.rubStartDistance)))"
        } ?? ""
        // Appended after the tap/rub annotations so zones without holdAction stay
        // byte-identical.
        let holdActionText = hit.holdAction.map { " holdAction=\($0)" } ?? ""
        // Appended last so tap zones without an explicit down mode stay byte-identical.
        let tapModeText = hit.trigger == .tap && hit.tapMode == .down ? " tapMode=down" : ""
        return "zone=\(hit.zoneID) action=\(hit.action) trigger=\(hit.trigger.rawValue)\(tapText)\(holdActionText)\(rubText)\(tapModeText) tail=\(formatInteractionNumber(hit.tailSeconds))"
    }

    func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0.0), 1.0),
            y: min(max(point.y, 0.0), 1.0)
        )
    }

    private func contains(point: CGPoint, in hitZone: HitZone) -> Bool {
        if let ellipse = hitZone.ellipse {
            let dx = (Double(point.x) - ellipse.center.x) / ellipse.radiusX
            let dy = (Double(point.y) - ellipse.center.y) / ellipse.radiusY
            return dx * dx + dy * dy <= 1
        }

        // Even-odd (crossing-number) point-in-polygon test on normalized vertices.
        if let polygon = hitZone.polygon, polygon.count >= 3 {
            let px = Double(point.x)
            let py = Double(point.y)
            var inside = false
            var index = polygon.startIndex
            var next = polygon.index(after: polygon.startIndex)
            while next < polygon.endIndex {
                let a = polygon[index]
                let b = polygon[next]
                if (a.y > py) != (b.y > py),
                   px < (b.x - a.x) * (py - a.y) / (b.y - a.y) + a.x {
                    inside.toggle()
                }
                index = next
                next = polygon.index(after: next)
            }
            let last = polygon[polygon.index(before: polygon.endIndex)]
            let first = polygon[polygon.startIndex]
            if (last.y > py) != (first.y > py),
               px < (first.x - last.x) * (py - last.y) / (first.y - last.y) + last.x {
                inside.toggle()
            }
            return inside
        }

        guard let rect = hitZone.rect, rect.count == 4 else { return false }
        return Double(point.x) >= rect[0]
            && Double(point.x) <= rect[2]
            && Double(point.y) >= rect[1]
            && Double(point.y) <= rect[3]
    }

    /// The zone shape's true center: the ellipse center, or the polygon vertex centroid.
    /// Nil for rect-only zones.
    private func geometricCenter(of hitZone: HitZone) -> CGPoint? {
        if let ellipse = hitZone.ellipse {
            return CGPoint(x: ellipse.center.x, y: ellipse.center.y)
        }
        if let polygon = hitZone.polygon, polygon.count >= 3 {
            return CGPoint(
                x: polygon.map(\.x).reduce(0, +) / Double(polygon.count),
                y: polygon.map(\.y).reduce(0, +) / Double(polygon.count)
            )
        }
        return nil
    }

    private func bounds(of hitZone: HitZone) -> [Double] {        if let ellipse = hitZone.ellipse {
            return [
                max(0, ellipse.center.x - ellipse.radiusX),
                max(0, ellipse.center.y - ellipse.radiusY),
                min(1, ellipse.center.x + ellipse.radiusX),
                min(1, ellipse.center.y + ellipse.radiusY)
            ]
        }
        if let polygon = hitZone.polygon, polygon.count >= 3 {
            return [
                polygon.map(\.x).min() ?? 0,
                polygon.map(\.y).min() ?? 0,
                polygon.map(\.x).max() ?? 0,
                polygon.map(\.y).max() ?? 0
            ]
        }
        return hitZone.rect ?? [0, 0, 0, 0]
    }

    private func shapeName(of hitZone: HitZone) -> String {
        if hitZone.ellipse != nil { return "ellipse" }
        if hitZone.polygon != nil { return "polygon" }
        return "rect"
    }

    private func resolvedTailSeconds(for hitZone: HitZone) -> CFTimeInterval {
        let declaredTail = declaredTailSeconds(for: hitZone)
        guard (hitZone.trigger ?? .tap) == .tap,
              let animationTail = tailDuration(for: hitZone.action),
              animationTail.isFinite,
              animationTail > 0 else {
            return declaredTail
        }
        return max(declaredTail, animationTail)
    }

    /// Effective tap tail: the animation-duration floor over the tap action's tail, for
    /// single actions (direct duration lookup) and colon pairs (the component max lives
    /// inside tailDuration) alike — a single tapAction whose animation runs longer than its
    /// declared tap tail must not get cut short.
    private func resolvedTapTailSeconds(for hitZone: HitZone) -> CFTimeInterval {
        let declaredTail = declaredTapTailSeconds(for: hitZone)
        guard let tapAction = hitZone.tapAction,
              let animationTail = tailDuration(for: tapAction),
              animationTail.isFinite,
              animationTail > 0 else {
            return declaredTail
        }
        return max(declaredTail, animationTail)
    }

    private func resolvedRubTailSeconds(for hitZone: HitZone) -> CFTimeInterval {
        let declaredTail = declaredRubTailSeconds(for: hitZone)
        guard let rubAction = hitZone.rubAction,
              let animationTail = tailDuration(for: rubAction),
              animationTail.isFinite,
              animationTail > 0 else {
            return declaredTail
        }
        return max(declaredTail, animationTail)
    }

    private func declaredTailSeconds(for hitZone: HitZone) -> CFTimeInterval {
        hitZone.tailSeconds ?? defaultClickTailDuration
    }

    private func declaredTapTailSeconds(for hitZone: HitZone) -> CFTimeInterval {
        hitZone.tapTailSeconds ?? defaultClickTailDuration
    }

    private func declaredRubTailSeconds(for hitZone: HitZone) -> CFTimeInterval {
        hitZone.rubTailSeconds ?? defaultClickTailDuration
    }

    private func resolvedTailSeconds(for defaultAction: PointerDownDefaultAction) -> CFTimeInterval {
        let declaredTail = defaultAction.tailSeconds ?? defaultClickTailDuration
        guard (defaultAction.trigger ?? .tap) == .tap,
              let animationTail = tailDuration(for: defaultAction.action),
              animationTail.isFinite,
              animationTail > 0 else {
            return declaredTail
        }
        return max(declaredTail, animationTail)
    }

    private static func point(_ point: InteractionPoint?, fallback: CGPoint) -> CGPoint {
        guard let point else { return fallback }
        return CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
    }
}

private func formatInteractionNumber(_ value: Double) -> String {
    let rounded = value.rounded()
    if abs(value - rounded) < 0.005 {
        return "\(Int(rounded))"
    }
    return String(format: "%.3f", value)
}

private func formatPoint(_ point: CGPoint) -> String {
    "\(formatInteractionNumber(Double(point.x))),\(formatInteractionNumber(Double(point.y)))"
}
