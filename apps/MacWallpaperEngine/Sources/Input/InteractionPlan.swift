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
        guard let config = interactions.first(where: { $0.event == .pointerDown }),
              let hitZones = config.hitZones else {
            return nil
        }
        let interactionButtons = config.buttons ?? [.left]
        guard interactionButtons.contains(button) else { return nil }
        for hitZone in hitZones {
            let zoneButtons = hitZone.buttons ?? interactionButtons
            guard zoneButtons.contains(button), contains(point: pointer, in: hitZone.rect) else { continue }
            return InteractionHitResult(
                zoneID: hitZone.id,
                action: hitZone.action,
                trigger: hitZone.trigger ?? .tap,
                tailSeconds: resolvedTailSeconds(for: hitZone)
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

    static func diagnosticSummary(
        interactions: [InteractionConfig],
        policy: InteractionPolicy?,
        runtimeInteractive: Bool,
        actionTailDurations: [String: CFTimeInterval] = [:]
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
                lines.append("hitZone: \(zone.detailText)")
                lines.append([
                    "hitProbe: \(zone.id)",
                    "center=\(formatPoint(center))",
                    "accepts=\(acceptedButtons)",
                    "left=\(leftHit?.action ?? "none")",
                    "right=\(rightHit?.action ?? "none")"
                ].joined(separator: " "))
            }
        }
        return lines.joined(separator: "\n")
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
