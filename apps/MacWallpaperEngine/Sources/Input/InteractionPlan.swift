import CoreGraphics
import Foundation

struct InteractionHitResult {
    let zoneID: String
    let action: String
    let tapAction: String?
    let trigger: HitZoneTrigger
    let tailSeconds: CFTimeInterval
    let tapTailSeconds: CFTimeInterval
    let holdStartSeconds: CFTimeInterval
}

struct InteractionHitZoneSummary {
    let id: String
    let action: String
    let tapAction: String?
    let trigger: HitZoneTrigger
    let tailSeconds: CFTimeInterval
    let tapTailSeconds: CFTimeInterval
    let holdStartSeconds: CFTimeInterval
    let buttons: [PointerButton]
    let rect: [Double]
    let priority: Int

    var detailText: String {
        let buttonText = buttons.map(\.rawValue).joined(separator: "+")
        let rectText = rect.map { String(format: "%.3f", $0) }.joined(separator: ",")
        let tailText = String(format: "%.2fs", tailSeconds)
        let tapText = tapAction.map {
            " tapAction=\($0) tapTail=\(String(format: "%.2fs", tapTailSeconds)) holdStart=\(String(format: "%.2fs", holdStartSeconds))"
        } ?? ""
        return "\(id):\(action) trigger=\(trigger.rawValue)\(tapText) buttons=\(buttonText) priority=\(priority) rect=[\(rectText)] tail=\(tailText)"
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

    init(
        interactions: [InteractionConfig],
        policy: InteractionPolicy?,
        actionTailDurations: [String: CFTimeInterval] = [:]
    ) {
        self.interactions = interactions
        self.pointerSmoothing = CGFloat(policy?.pointerSmoothing ?? 0.18)
        self.idleDeadZone = CGFloat(policy?.idleDeadZone ?? 0.18)
        self.directionSwitchMargin = CGFloat(policy?.directionSwitchMargin ?? 0.10)
        self.defaultClickTailDuration = policy?.defaultClickTailSeconds ?? 1.15
        self.actionTailDurations = actionTailDurations
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

    func command(for point: CGPoint, previousCommand: String = "idle") -> String {
        let pointer = clamp(point)
        guard let config = interactions.first(where: { $0.event == .pointerMove }),
              config.mapping == "lookDirection",
              let actions = config.actions else {
            return "idle"
        }
        let neutral = Self.point(config.neutralPoint, fallback: CGPoint(x: 0.5, y: 0.5))
        let deadZone = Self.point(config.deadZone, fallback: CGPoint(x: idleDeadZone, y: idleDeadZone))
        let dx = pointer.x - neutral.x
        let dy = pointer.y - neutral.y
        if abs(dx) < deadZone.x, abs(dy) < deadZone.y {
            return actions["idle"] ?? "idle"
        }
        if abs(dx) > abs(dy) + directionSwitchMargin {
            return dx < 0 ? (actions["left"] ?? "Left") : (actions["right"] ?? "Right")
        }
        if abs(dy) > abs(dx) + directionSwitchMargin {
            return dy < 0 ? (actions["up"] ?? "Up") : (actions["down"] ?? "Down")
        }
        return previousCommand
    }

    func allowsPointerMove(button: PointerButton?) -> Bool {
        guard let config = interactions.first(where: { $0.event == .pointerMove }) else {
            return false
        }
        guard let buttons = config.buttons else {
            return true
        }
        guard let button else {
            return false
        }
        return buttons.contains(button)
    }

    func lookNeutralPoint() -> CGPoint {
        let config = interactions.first(where: { $0.event == .pointerMove })
        return Self.point(config?.neutralPoint, fallback: CGPoint(x: 0.5, y: 0.5))
    }

    func hitTest(point: CGPoint, button: PointerButton) -> InteractionHitResult? {
        let pointer = clamp(point)
        guard let config = interactions.first(where: { $0.event == .pointerDown }) else {
            return nil
        }
        let interactionButtons = config.buttons ?? [.left]
        guard interactionButtons.contains(button) else { return nil }
        let matches = (config.hitZones ?? []).enumerated().compactMap { index, hitZone -> (index: Int, hitZone: HitZone)? in
            let zoneButtons = hitZone.buttons ?? interactionButtons
            guard zoneButtons.contains(button), contains(point: pointer, in: hitZone.rect) else { return nil }
            return (index, hitZone)
        }
        if let selected = matches.max(by: { left, right in
            let leftPriority = left.hitZone.priority ?? 0
            let rightPriority = right.hitZone.priority ?? 0
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            let leftArea = area(of: left.hitZone.rect)
            let rightArea = area(of: right.hitZone.rect)
            if leftArea != rightArea {
                return leftArea > rightArea
            }
            return left.index > right.index
        })?.hitZone {
            return InteractionHitResult(
                zoneID: selected.id,
                action: selected.action,
                tapAction: selected.tapAction,
                trigger: selected.trigger ?? .tap,
                tailSeconds: resolvedTailSeconds(for: selected),
                tapTailSeconds: resolvedTapTailSeconds(for: selected),
                holdStartSeconds: selected.holdStartSeconds ?? 0
            )
        }
        if let defaultAction = config.defaultAction {
            let defaultButtons = defaultAction.buttons ?? interactionButtons
            guard defaultButtons.contains(button) else { return nil }
            return InteractionHitResult(
                zoneID: "default",
                action: defaultAction.action,
                tapAction: nil,
                trigger: defaultAction.trigger ?? .tap,
                tailSeconds: resolvedTailSeconds(for: defaultAction),
                tapTailSeconds: resolvedTailSeconds(for: defaultAction),
                holdStartSeconds: 0
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
                trigger: hitZone.trigger ?? .tap,
                tailSeconds: resolvedTailSeconds(for: hitZone),
                tapTailSeconds: resolvedTapTailSeconds(for: hitZone),
                holdStartSeconds: hitZone.holdStartSeconds ?? 0,
                buttons: hitZone.buttons ?? interactionButtons,
                rect: hitZone.rect,
                priority: hitZone.priority ?? 0
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
        fitMode: RenderFitMode? = nil,
        contentAspect: CGFloat? = nil,
        accessibilityTrusted: Bool? = nil
    ) -> String {
        let plan = InteractionPlan(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations
        )
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
        let moveProbeText = [
            "left=\(plan.command(for: CGPoint(x: 0.10, y: 0.50), previousCommand: "idle"))",
            "right=\(plan.command(for: CGPoint(x: 0.90, y: 0.50), previousCommand: "idle"))",
            "up=\(plan.command(for: CGPoint(x: 0.50, y: 0.10), previousCommand: "idle"))",
            "down=\(plan.command(for: CGPoint(x: 0.50, y: 0.90), previousCommand: "idle"))",
            "center=\(plan.command(for: CGPoint(x: 0.50, y: 0.50), previousCommand: "Right"))",
            "neutral=\(plan.command(for: neutralPoint, previousCommand: "Right"))"
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
            "pointerMoveActions: \(moveActions)",
            "pointerMoveProbes: \(moveProbeText)"
        ] + eventGateProbeLines(
            policy: effectivePolicy,
            accessibilityTrusted: accessibilityTrusted
        ) + inputSourceProbeLines(
            policy: effectivePolicy
        ) + [
            "pointerDownButtons: \(clickConfig == nil ? "none" : clickButtons)",
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
                    actionTailDurations: actionTailDurations
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
                    tailSeconds: zone.tailSeconds,
                    interactions: interactions,
                    policy: policy,
                    actionTailDurations: actionTailDurations
                ))
            }
        }
        if let defaultAction {
            let probeController = InteractionController(
                interactions: interactions,
                policy: policy,
                actionTailDurations: actionTailDurations
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
                interactions: interactions,
                policy: policy,
                actionTailDurations: actionTailDurations
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
        actionTailDurations: [String: CFTimeInterval] = [:]
    ) -> String {
        let plan = InteractionPlan(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations
        )
        let clampedPoint = plan.clamp(point)
        let moveConfig = interactions.first { $0.event == .pointerMove }
        let neutralPoint = Self.point(moveConfig?.neutralPoint, fallback: CGPoint(x: 0.5, y: 0.5))
        let moveDeadZone = Self.point(moveConfig?.deadZone, fallback: CGPoint(x: plan.idleDeadZone, y: plan.idleDeadZone))
        let moveCommand = plan.command(for: clampedPoint, previousCommand: "idle")
        let stickyCommand = plan.command(for: clampedPoint, previousCommand: "Right")
        let hit = plan.hitTest(point: clampedPoint, button: button)

        let clock = InteractionDiagnosticClock()
        let controller = InteractionController(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations,
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
        policy: InteractionPolicy,
        runtimeInteractive: Bool,
        accessibilityTrusted: Bool?
    ) -> String {
        guard runtimeInteractive else { return "disabled(runtime-settings)" }
        guard interactions.isEmpty == false else { return "passive(no-interactions)" }
        guard policy.mode != .disabled else { return "disabled(policy)" }
        guard RuntimeLifecyclePolicy.requiresAccessibilityTrustForDesktopItems(policy) else {
            return "ready(\(policy.mode.rawValue))"
        }

        let trusted = accessibilityTrusted ?? DesktopInteractionGate.hasAccessibilityTrust()
        return trusted
            ? "ready(\(policy.mode.rawValue),accessibility-trusted)"
            : "degraded(\(policy.mode.rawValue),pointer-tracking-only-accessibility-missing)"
    }

    private static func eventGateProbeLines(
        policy: InteractionPolicy,
        accessibilityTrusted: Bool?
    ) -> [String] {
        let trusted = accessibilityTrusted ?? DesktopInteractionGate.hasAccessibilityTrust()
        return [
            eventGateProbeText(label: "eventGateProbes", policy: policy, accessibilityTrusted: trusted),
            eventGateProbeText(label: "eventGateTrustedProbes", policy: policy, accessibilityTrusted: true),
            eventGateProbeText(label: "eventGateMissingTrustProbes", policy: policy, accessibilityTrusted: false)
        ]
    }

    private static func eventGateProbeText(
        label: String,
        policy: InteractionPolicy,
        accessibilityTrusted: Bool
    ) -> String {
        [
            "\(label):",
            "accessibilityTrusted=\(accessibilityTrusted)",
            "emptyDesktopMove=\(DesktopInteractionGate.pointerMoveEligibilityDecision(policy: policy, accessibilityTrusted: accessibilityTrusted, coveredByApplicationWindow: false, likelyDesktopItem: false).rawValue)",
            "emptyDesktop=\(DesktopInteractionGate.eligibilityDecision(policy: policy, accessibilityTrusted: accessibilityTrusted, coveredByApplicationWindow: false, likelyDesktopItem: false).rawValue)",
            "appWindow=\(DesktopInteractionGate.eligibilityDecision(policy: policy, accessibilityTrusted: accessibilityTrusted, coveredByApplicationWindow: true, likelyDesktopItem: false).rawValue)",
            "desktopItem=\(DesktopInteractionGate.eligibilityDecision(policy: policy, accessibilityTrusted: accessibilityTrusted, coveredByApplicationWindow: false, likelyDesktopItem: true).rawValue)"
        ].joined(separator: " ")
    }

    private static func inputSourceProbeLines(policy: InteractionPolicy) -> [String] {
        let passiveTrustedEventTap = formatInputSources(DesktopMouseInteractionMonitor.inputSources(
            usesPassiveEventMonitoring: true,
            eventTapStarted: true,
            accessibilityTrusted: true
        ))
        let passiveTrustedFallback = formatInputSources(DesktopMouseInteractionMonitor.inputSources(
            usesPassiveEventMonitoring: true,
            eventTapStarted: false,
            accessibilityTrusted: true
        ))
        let passiveMissingTrust = formatInputSources(DesktopMouseInteractionMonitor.inputSources(
            usesPassiveEventMonitoring: true,
            eventTapStarted: false,
            accessibilityTrusted: false
        ))
        let plainWindow = formatInputSources(DesktopMouseInteractionMonitor.inputSources(
            usesPassiveEventMonitoring: false,
            eventTapStarted: false,
            accessibilityTrusted: false
        ))
        return [
            [
                "inputSourceProbes:",
                "policy=\(policy.mode.rawValue)",
                "passiveTrustedEventTap=\(passiveTrustedEventTap)",
                "passiveTrustedFallback=\(passiveTrustedFallback)",
                "passiveMissingTrust=\(passiveMissingTrust)",
                "plainWindow=\(plainWindow)"
            ].joined(separator: " ")
        ]
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
        tailSeconds: CFTimeInterval,
        interactions: [InteractionConfig],
        policy: InteractionPolicy?,
        actionTailDurations: [String: CFTimeInterval]
    ) -> String {
        let clock = InteractionDiagnosticClock()
        let controller = InteractionController(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations,
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
            let holdSampleTime = max(0.10, safeTail / 2.0)
            clock.time = holdSampleTime
            let held = controller.snapshot()
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
                "held@\(formatInteractionNumber(holdSampleTime))=\(snapshotText(held))",
                "up@\(formatInteractionNumber(holdSampleTime))=\(snapshotText(up))",
                "fade@\(formatInteractionNumber(holdSampleTime + (safeTail / 2.0)))=\(snapshotText(fade))",
                "expired@\(formatInteractionNumber(holdSampleTime + safeTail + 0.10))=\(snapshotText(expired))"
            ].joined(separator: " ")
        }
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
            " tapAction=\($0) tapTail=\(formatInteractionNumber(hit.tapTailSeconds)) holdStart=\(formatInteractionNumber(hit.holdStartSeconds))"
        } ?? ""
        return "zone=\(hit.zoneID) action=\(hit.action) trigger=\(hit.trigger.rawValue)\(tapText) tail=\(formatInteractionNumber(hit.tailSeconds))"
    }

    func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0.0), 1.0),
            y: min(max(point.y, 0.0), 1.0)
        )
    }

    private func contains(point: CGPoint, in rect: [Double]) -> Bool {
        guard rect.count == 4 else { return false }
        return Double(point.x) >= rect[0]
            && Double(point.x) <= rect[2]
            && Double(point.y) >= rect[1]
            && Double(point.y) <= rect[3]
    }

    private func area(of rect: [Double]) -> Double {
        guard rect.count == 4 else { return .greatestFiniteMagnitude }
        return max(0, rect[2] - rect[0]) * max(0, rect[3] - rect[1])
    }

    private func resolvedTailSeconds(for hitZone: HitZone) -> CFTimeInterval {
        let declaredTail = hitZone.tailSeconds ?? defaultClickTailDuration
        guard (hitZone.trigger ?? .tap) == .tap,
              let animationTail = actionTailDurations[hitZone.action],
              animationTail.isFinite,
              animationTail > 0 else {
            return declaredTail
        }
        return max(declaredTail, animationTail)
    }

    private func resolvedTapTailSeconds(for hitZone: HitZone) -> CFTimeInterval {
        let declaredTail = hitZone.tapTailSeconds ?? defaultClickTailDuration
        guard let tapAction = hitZone.tapAction,
              let animationTail = actionTailDurations[tapAction],
              animationTail.isFinite,
              animationTail > 0 else {
            return declaredTail
        }
        return max(declaredTail, animationTail)
    }

    private func resolvedTailSeconds(for defaultAction: PointerDownDefaultAction) -> CFTimeInterval {
        let declaredTail = defaultAction.tailSeconds ?? defaultClickTailDuration
        guard (defaultAction.trigger ?? .tap) == .tap,
              let animationTail = actionTailDurations[defaultAction.action],
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
