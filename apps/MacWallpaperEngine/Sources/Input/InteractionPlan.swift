import CoreGraphics
import Foundation

struct InteractionHitResult {
    let zoneID: String
    let action: String
    let trigger: HitZoneTrigger
    let tailSeconds: CFTimeInterval
}

struct InteractionHitZoneSummary {
    let id: String
    let action: String
    let trigger: HitZoneTrigger
    let tailSeconds: CFTimeInterval
    let buttons: [PointerButton]
    let rect: [Double]

    var detailText: String {
        let buttonText = buttons.map(\.rawValue).joined(separator: "+")
        let rectText = rect.map { String(format: "%.3f", $0) }.joined(separator: ",")
        let tailText = String(format: "%.2fs", tailSeconds)
        return "\(id):\(action) trigger=\(trigger.rawValue) buttons=\(buttonText) rect=[\(rectText)] tail=\(tailText)"
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

    func smooth(current: CGPoint, target: CGPoint) -> CGPoint {
        let clampedTarget = clamp(target)
        return CGPoint(
            x: current.x + (clampedTarget.x - current.x) * pointerSmoothing,
            y: current.y + (clampedTarget.y - current.y) * pointerSmoothing
        )
    }

    func command(for point: CGPoint, previousCommand: String = "idle") -> String {
        let pointer = clamp(point)
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
        return previousCommand
    }

    func hitTest(point: CGPoint, button: PointerButton) -> InteractionHitResult? {
        let pointer = clamp(point)
        guard let config = interactions.first(where: { $0.event == .pointerDown }) else {
            return nil
        }
        let interactionButtons = config.buttons ?? [.left]
        guard interactionButtons.contains(button) else { return nil }
        for hitZone in config.hitZones ?? [] {
            let zoneButtons = hitZone.buttons ?? interactionButtons
            guard zoneButtons.contains(button), contains(point: pointer, in: hitZone.rect) else { continue }
            return InteractionHitResult(
                zoneID: hitZone.id,
                action: hitZone.action,
                trigger: hitZone.trigger ?? .tap,
                tailSeconds: resolvedTailSeconds(for: hitZone)
            )
        }
        if let defaultAction = config.defaultAction {
            let defaultButtons = defaultAction.buttons ?? interactionButtons
            guard defaultButtons.contains(button) else { return nil }
            return InteractionHitResult(
                zoneID: "default",
                action: defaultAction.action,
                trigger: defaultAction.trigger ?? .tap,
                tailSeconds: resolvedTailSeconds(for: defaultAction)
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
                trigger: hitZone.trigger ?? .tap,
                tailSeconds: resolvedTailSeconds(for: hitZone),
                buttons: hitZone.buttons ?? interactionButtons,
                rect: hitZone.rect
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
        contentAspect: CGFloat? = nil
    ) -> String {
        let plan = InteractionPlan(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations
        )
        let mode = policy?.mode.rawValue ?? (runtimeInteractive ? "desktop-empty-only(default)" : "disabled(default)")
        let moveConfig = interactions.first { $0.event == .pointerMove }
        let clickConfig = interactions.first { $0.event == .pointerDown }
        let moveMapping = moveConfig?.mapping ?? "none"
        let moveActions = moveConfig?.actions?
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",") ?? "none"
        let clickButtons = (clickConfig?.buttons ?? [.left]).map(\.rawValue).joined(separator: "+")
        let zones = plan.hitZoneSummaries()
        let defaultAction = plan.defaultActionSummary()
        let moveProbeText = [
            "left=\(plan.command(for: CGPoint(x: 0.10, y: 0.50), previousCommand: "idle"))",
            "right=\(plan.command(for: CGPoint(x: 0.90, y: 0.50), previousCommand: "idle"))",
            "up=\(plan.command(for: CGPoint(x: 0.50, y: 0.10), previousCommand: "idle"))",
            "down=\(plan.command(for: CGPoint(x: 0.50, y: 0.90), previousCommand: "idle"))",
            "center=\(plan.command(for: CGPoint(x: 0.50, y: 0.50), previousCommand: "Right"))"
        ].joined(separator: " ")
        var lines = [
            "interaction plan OK",
            "runtimeInteractive: \(runtimeInteractive ? "enabled" : "disabled")",
            "policyMode: \(mode)",
            "blockApplicationWindows: \(policy?.blockApplicationWindows ?? true)",
            "blockDesktopItems: \(policy?.blockDesktopItems ?? true)",
            "pointerSmoothing: \(formatInteractionNumber(Double(policy?.pointerSmoothing ?? 0.18)))",
            "idleDeadZone: \(formatInteractionNumber(Double(policy?.idleDeadZone ?? 0.18)))",
            "directionSwitchMargin: \(formatInteractionNumber(Double(policy?.directionSwitchMargin ?? 0.10)))",
            "defaultClickTailSeconds: \(formatInteractionNumber(policy?.defaultClickTailSeconds ?? 1.15))",
            "releaseFadeSeconds: \(formatInteractionNumber(policy?.releaseFadeSeconds ?? 0.20))",
            "pointerMove: \(moveMapping)",
            "pointerMoveActions: \(moveActions)",
            "pointerMoveProbes: \(moveProbeText)",
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
