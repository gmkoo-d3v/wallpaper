import Foundation

struct SpineAnimationDiagnostics {
    private struct AnimationSummary {
        let name: String
        var duration: Double
        var timelineCount: Int
        var frameCount: Int
        var timelineTypes: [String: Int]

        var timelineTypeText: String {
            guard timelineTypes.isEmpty == false else { return "none" }
            return timelineTypes
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value {
                        return lhs.key < rhs.key
                    }
                    return lhs.value > rhs.value
                }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
        }

        var unsupportedNativeTimelineTypes: [String] {
            timelineTypes.keys
                .filter { SpineAnimationDiagnostics.supportedNativeTimelineTypes.contains($0) == false }
                .sorted()
        }

        var nativeCoverageStatus: String {
            unsupportedNativeTimelineTypes.isEmpty ? "compatible" : "unsupported"
        }

        var unsupportedNativeTimelineTypeText: String {
            let unsupported = unsupportedNativeTimelineTypes
            return unsupported.isEmpty ? "unsupported=none" : "unsupported=\(unsupported.joined(separator: ","))"
        }
    }

    private struct ActionReference {
        let action: String
        let use: String
    }

    private static let supportedNativeTimelineTypes: Set<String> = [
        "bone.rotate",
        "bone.translate",
        "bone.translatex",
        "bone.translatey",
        "bone.scale",
        "bone.shear",
        "slot.color",
        "slot.rgba",
        "slot.rgb",
        "slot.alpha",
        "slot.attachment",
        "attachment.deform",
        "attachment.sequence",
        "drawOrder",
        "draworder",
        "events",
        "event"
    ]

    static func tapActionDurations(runtime: NativeRuntimeCore) throws -> [String: TimeInterval] {
        let tapActions = Set(runtime.manifest.interactions.flatMap { interaction -> [String] in
            guard interaction.event == .pointerDown else { return [] }
            var actions = (interaction.hitZones ?? []).flatMap { hitZone -> [String] in
                var names: [String] = []
                if (hitZone.trigger ?? .tap) == .tap {
                    names.append(hitZone.action)
                }
                if let tapAction = hitZone.tapAction {
                    names.append(tapAction)
                }
                return names
            }
            if (interaction.defaultAction?.trigger ?? .tap) == .tap,
               let action = interaction.defaultAction?.action {
                actions.append(action)
            }
            return actions
        })
        guard tapActions.isEmpty == false, let spineAsset = runtime.assetCatalog.spineAsset else {
            return [:]
        }

        let summaries = try animationSummaries(from: spineAsset.json)
        let summaryByName = Dictionary(uniqueKeysWithValues: summaries.map { ($0.name, $0) })
        var result: [String: TimeInterval] = [:]
        for action in tapActions.sorted() {
            guard let duration = summaryByName[action]?.duration, duration > 0 else { continue }
            result[action] = duration
        }
        return result
    }

    static func make(runtime: NativeRuntimeCore) throws -> String {
        let actionReferences = manifestActionReferences(runtime.manifest.interactions)
        let actionNames = uniqueSorted(actionReferences.map(\.action))

        guard let spineAsset = runtime.assetCatalog.spineAsset else {
            return noSpineSummary(actionNames: actionNames)
        }

        let summaries = try animationSummaries(from: spineAsset.json)
        let summaryByName = Dictionary(uniqueKeysWithValues: summaries.map { ($0.name, $0) })
        let missingActions = actionNames.filter { summaryByName[$0] == nil }
        let manifestActionText = actionNames.isEmpty ? "none" : actionNames.joined(separator: ",")
        let unsupportedActionTimelineText = unsupportedActionTimelines(
            actionNames: actionNames,
            summaryByName: summaryByName
        )

        var lines = [
            "spine animation plan OK",
            "spine: \(spineAsset.json.path)",
            "animations: \(summaries.count)",
            "manifestActions: \(manifestActionText)",
            "missingManifestActions: \(missingActions.isEmpty ? "none" : missingActions.joined(separator: ","))",
            "unsupportedActionTimelines: \(unsupportedActionTimelineText)",
            "columns: kind\tname\tstatus\tduration\ttimelines\tframes\ttypes\tuses"
        ]

        for actionName in actionNames {
            let uses = actionReferences
                .filter { $0.action == actionName }
                .map(\.use)
                .sorted()
                .joined(separator: ",")
            if let summary = summaryByName[actionName] {
                lines.append([
                    "action",
                    actionName,
                    "available",
                    formatSeconds(summary.duration),
                    "\(summary.timelineCount)",
                    "\(summary.frameCount)",
                    summary.timelineTypeText,
                    uses.isEmpty ? "none" : uses
                ].joined(separator: "\t"))
            } else {
                lines.append([
                    "action",
                    actionName,
                    "missing",
                    "0.000s",
                    "0",
                    "0",
                    "none",
                    uses.isEmpty ? "none" : uses
                ].joined(separator: "\t"))
            }
        }

        for actionName in actionNames {
            let uses = actionReferences
                .filter { $0.action == actionName }
                .map(\.use)
                .sorted()
                .joined(separator: ",")
            if let summary = summaryByName[actionName] {
                lines.append([
                    "coverage",
                    actionName,
                    summary.nativeCoverageStatus,
                    formatSeconds(summary.duration),
                    "\(summary.timelineCount)",
                    "\(summary.frameCount)",
                    summary.unsupportedNativeTimelineTypeText,
                    uses.isEmpty ? "none" : uses
                ].joined(separator: "\t"))
            } else {
                lines.append([
                    "coverage",
                    actionName,
                    "missing",
                    "0.000s",
                    "0",
                    "0",
                    "unsupported=missing-animation",
                    uses.isEmpty ? "none" : uses
                ].joined(separator: "\t"))
            }
        }

        for summary in summaries {
            lines.append([
                "animation",
                summary.name,
                "available",
                formatSeconds(summary.duration),
                "\(summary.timelineCount)",
                "\(summary.frameCount)",
                summary.timelineTypeText,
                "none"
            ].joined(separator: "\t"))
        }

        return lines.joined(separator: "\n")
    }

    private static func noSpineSummary(actionNames: [String]) -> String {
        [
            "spine animation plan OK",
            "spine: none",
            "animations: 0",
            "manifestActions: \(actionNames.isEmpty ? "none" : actionNames.joined(separator: ","))",
            "missingManifestActions: \(actionNames.isEmpty ? "none" : actionNames.joined(separator: ","))",
            "unsupportedActionTimelines: none",
            "columns: kind\tname\tstatus\tduration\ttimelines\tframes\ttypes\tuses"
        ].joined(separator: "\n")
    }

    private static func unsupportedActionTimelines(
        actionNames: [String],
        summaryByName: [String: AnimationSummary]
    ) -> String {
        let unsupported = actionNames.compactMap { actionName -> String? in
            guard let summary = summaryByName[actionName] else { return nil }
            let types = summary.unsupportedNativeTimelineTypes
            guard types.isEmpty == false else { return nil }
            return "\(actionName):\(types.joined(separator: "+"))"
        }
        return unsupported.isEmpty ? "none" : unsupported.joined(separator: ",")
    }

    private static func animationSummaries(from jsonURL: URL) throws -> [AnimationSummary] {
        let data = try Data(contentsOf: jsonURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.asset("Spine JSON root is not an object")
        }
        guard let animations = root["animations"] as? [String: Any] else {
            return []
        }

        return animations.keys.sorted().compactMap { animationName in
            guard let animationMap = animations[animationName] as? [String: Any] else {
                return nil
            }
            return summarize(animationName: animationName, animationMap: animationMap)
        }
    }

    private static func summarize(animationName: String, animationMap: [String: Any]) -> AnimationSummary {
        var summary = AnimationSummary(
            name: animationName,
            duration: maxTime(in: animationMap),
            timelineCount: 0,
            frameCount: 0,
            timelineTypes: [:]
        )

        if let bones = animationMap["bones"] as? [String: Any] {
            for (_, rawTimelineSet) in bones {
                guard let timelineSet = rawTimelineSet as? [String: Any] else { continue }
                for (timelineName, rawTimeline) in timelineSet {
                    addTimeline("bone.\(timelineName)", rawTimeline, to: &summary)
                }
            }
        }

        if let slots = animationMap["slots"] as? [String: Any] {
            for (_, rawTimelineSet) in slots {
                guard let timelineSet = rawTimelineSet as? [String: Any] else { continue }
                for (timelineName, rawTimeline) in timelineSet {
                    addTimeline("slot.\(timelineName)", rawTimeline, to: &summary)
                }
            }
        }

        if let attachmentSkins = animationMap["attachments"] as? [String: Any] {
            for (_, rawSkin) in attachmentSkins {
                guard let skin = rawSkin as? [String: Any] else { continue }
                for (_, rawAttachmentSet) in skin {
                    guard let attachmentSet = rawAttachmentSet as? [String: Any] else { continue }
                    for (_, rawTimelineSet) in attachmentSet {
                        guard let timelineSet = rawTimelineSet as? [String: Any] else { continue }
                        for (timelineName, rawTimeline) in timelineSet {
                            addTimeline("attachment.\(timelineName)", rawTimeline, to: &summary)
                        }
                    }
                }
            }
        }

        for (key, rawValue) in animationMap {
            guard ["bones", "slots", "attachments"].contains(key) == false else { continue }
            let normalizedKey = key == "draworder" ? "drawOrder" : key
            addTimeline(normalizedKey, rawValue, to: &summary)
        }

        return summary
    }

    private static func addTimeline(_ type: String, _ rawTimeline: Any, to summary: inout AnimationSummary) {
        summary.timelineCount += 1
        summary.frameCount += frameCount(in: rawTimeline)
        summary.timelineTypes[type, default: 0] += 1
    }

    private static func manifestActionReferences(_ interactions: [InteractionConfig]) -> [ActionReference] {
        var references: [ActionReference] = []
        for interaction in interactions {
            switch interaction.event {
            case .pointerMove:
                let sortedActions = interaction.actions?.sorted { $0.key < $1.key } ?? []
                for (direction, action) in sortedActions {
                    references.append(ActionReference(action: action, use: "pointerMove.\(direction)"))
                }
            case .pointerDown:
                if let defaultAction = interaction.defaultAction {
                    let trigger = defaultAction.trigger?.rawValue ?? HitZoneTrigger.tap.rawValue
                    references.append(ActionReference(action: defaultAction.action, use: "pointerDown.default.\(trigger)"))
                }
                let sortedZones = (interaction.hitZones ?? []).sorted { $0.id < $1.id }
                for zone in sortedZones {
                    let trigger = zone.trigger?.rawValue ?? HitZoneTrigger.tap.rawValue
                    references.append(ActionReference(action: zone.action, use: "pointerDown.\(zone.id).\(trigger)"))
                    if let tapAction = zone.tapAction {
                        references.append(ActionReference(action: tapAction, use: "pointerDown.\(zone.id).tapAction"))
                    }
                }
            }
        }
        return references
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static func maxTime(in value: Any) -> Double {
        if let map = value as? [String: Any] {
            let ownTime = number(map["time"])
            let childMax = map.values.map(maxTime).max() ?? 0
            return max(ownTime, childMax)
        }
        if let array = value as? [Any] {
            return array.map(maxTime).max() ?? 0
        }
        return 0
    }

    private static func frameCount(in value: Any) -> Int {
        if let frames = value as? [[String: Any]] {
            return frames.count
        }
        if let array = value as? [Any] {
            return array.map(frameCount).reduce(0, +)
        }
        if let map = value as? [String: Any] {
            return map.values.map(frameCount).reduce(0, +)
        }
        return 0
    }

    private static func number(_ value: Any?) -> Double {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return 0
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3fs", value)
    }
}
