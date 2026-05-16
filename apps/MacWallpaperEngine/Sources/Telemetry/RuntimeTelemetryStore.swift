import Foundation

struct RuntimeTelemetryEntry {
    let displayName: String
    let roleName: String
    let snapshot: ResourceGovernorSnapshot
}

struct InteractionMonitorTelemetrySnapshot: Equatable {
    let active: Bool
    let eventTapActive: Bool
    let localMonitorActive: Bool
    let globalMonitorCount: Int
    let lastSource: String
    let lastEvent: String
    let lastDecision: String
    let lastPoint: String
    let lastCommand: String
    let lastClickPulse: Double
    let deliveredEvents: Int
    let blockedEvents: Int
}

struct InteractionTelemetryEntry {
    let displayName: String
    let roleName: String
    let snapshot: InteractionMonitorTelemetrySnapshot
}

final class RuntimeTelemetryStore {
    private let lock = NSLock()
    private var entriesByDisplay: [String: RuntimeTelemetryEntry] = [:]
    private var interactionEntriesByDisplay: [String: InteractionTelemetryEntry] = [:]

    func record(displayName: String, role: RenderDisplayRole, snapshot: ResourceGovernorSnapshot) {
        let entry = RuntimeTelemetryEntry(
            displayName: displayName,
            roleName: "\(role.kind.label):\(role.policy.rawValue)",
            snapshot: snapshot
        )

        lock.lock()
        entriesByDisplay[displayName] = entry
        lock.unlock()
    }

    func recordInteraction(
        displayName: String,
        role: RenderDisplayRole,
        snapshot: InteractionMonitorTelemetrySnapshot
    ) {
        let entry = InteractionTelemetryEntry(
            displayName: displayName,
            roleName: "\(role.kind.label):\(role.policy.rawValue)",
            snapshot: snapshot
        )

        lock.lock()
        interactionEntriesByDisplay[displayName] = entry
        lock.unlock()
    }

    func snapshot() -> [RuntimeTelemetryEntry] {
        lock.lock()
        let entries = Array(entriesByDisplay.values)
        lock.unlock()

        return entries.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func interactionSnapshot() -> [InteractionTelemetryEntry] {
        lock.lock()
        let entries = Array(interactionEntriesByDisplay.values)
        lock.unlock()

        return entries.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func summary() -> String {
        let entries = snapshot()
        let interactionEntries = interactionSnapshot()
        guard entries.isEmpty == false || interactionEntries.isEmpty == false else {
            return "No runtime telemetry yet"
        }

        let renderSummary = entries.map { entry in
            let data = entry.snapshot
            let skip = data.lastSkipReason.map { " last=\($0)" } ?? ""
            let power = data.powerSavingActive ? " power-saving" : ""
            let videoFallback = data.videoOnlyFallback ? " video-only-fallback" : ""
            return "\(entry.displayName) \(entry.roleName): fps \(format(data.actualFps))/\(data.currentFps), p95 \(format(data.p95FrameTimeMs))ms, submitted \(data.submittedFrames), skipped \(data.skippedFrames)\(skip)"
                + power
                + videoFallback
        }
        let interactionSummary = interactionEntries.map { entry in
            let data = entry.snapshot
            let active = data.active ? "active" : "inactive"
            let tap = data.eventTapActive ? "tap:on" : "tap:off"
            let local = data.localMonitorActive ? "local:on" : "local:off"
            return "\(entry.displayName) \(entry.roleName) interaction \(active) \(tap) \(local) global:\(data.globalMonitorCount) last:\(data.lastSource)/\(data.lastEvent)/\(data.lastDecision) point:\(data.lastPoint) command:\(data.lastCommand)/\(format(data.lastClickPulse)) delivered:\(data.deliveredEvents) blocked:\(data.blockedEvents)"
        }
        return (renderSummary + interactionSummary).joined(separator: " | ")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
