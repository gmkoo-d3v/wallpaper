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

struct InteractionTelemetryObservation: Equatable {
    let displayName: String
    let roleName: String
    let source: String
    let event: String
    let decision: String
    let point: String
    let command: String
    let clickPulse: Double
}

struct DisplayLifecycleTelemetryEntry {
    let event: String
    let status: String
    let detail: String
}

final class RuntimeTelemetryStore {
    private static let maxLifecycleEntries = 5
    private static let maxInteractionObservations = 120

    private let lock = NSLock()
    private var entriesByDisplay: [String: RuntimeTelemetryEntry] = [:]
    private var interactionEntriesByDisplay: [String: InteractionTelemetryEntry] = [:]
    private var interactionObservations: [InteractionTelemetryObservation] = []
    private var displayLifecycleEntries: [DisplayLifecycleTelemetryEntry] = []

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
        let observation = InteractionTelemetryObservation(
            displayName: displayName,
            roleName: entry.roleName,
            source: snapshot.lastSource,
            event: snapshot.lastEvent,
            decision: snapshot.lastDecision,
            point: snapshot.lastPoint,
            command: snapshot.lastCommand,
            clickPulse: snapshot.lastClickPulse
        )

        lock.lock()
        interactionEntriesByDisplay[displayName] = entry
        interactionObservations.append(observation)
        if interactionObservations.count > Self.maxInteractionObservations {
            interactionObservations.removeFirst(interactionObservations.count - Self.maxInteractionObservations)
        }
        lock.unlock()
    }

    func recordDisplayLifecycle(event: String, status: String, detail: String) {
        let entry = DisplayLifecycleTelemetryEntry(event: event, status: status, detail: detail)

        lock.lock()
        displayLifecycleEntries.append(entry)
        if displayLifecycleEntries.count > Self.maxLifecycleEntries {
            displayLifecycleEntries.removeFirst(displayLifecycleEntries.count - Self.maxLifecycleEntries)
        }
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

    func displayLifecycleSnapshot() -> [DisplayLifecycleTelemetryEntry] {
        lock.lock()
        let entries = displayLifecycleEntries
        lock.unlock()

        return entries
    }

    func interactionSnapshot() -> [InteractionTelemetryEntry] {
        lock.lock()
        let entries = Array(interactionEntriesByDisplay.values)
        lock.unlock()

        return entries.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func interactionObservationSnapshot() -> [InteractionTelemetryObservation] {
        lock.lock()
        let entries = interactionObservations
        lock.unlock()

        return entries
    }

    func summary() -> String {
        let entries = snapshot()
        let interactionEntries = interactionSnapshot()
        let lifecycleEntries = displayLifecycleSnapshot()
        guard entries.isEmpty == false || interactionEntries.isEmpty == false || lifecycleEntries.isEmpty == false else {
            return "No runtime telemetry yet"
        }

        let renderSummary = entries.map { entry in
            let data = entry.snapshot
            let skip = data.lastSkipReason.map { " last=\($0)" } ?? ""
            let power = data.powerSavingActive ? " power-saving" : ""
            let thermalPause = data.pauseForThermal ? " thermal-pause" : ""
            let resourcePause = data.pauseForResourceBudget ? " resource-pause" : ""
            let videoFallback = data.videoOnlyFallback ? " video-only-fallback" : ""
            return "\(entry.displayName) \(entry.roleName): fps \(format(data.actualFps))/\(data.currentFps), p95 \(format(data.p95FrameTimeMs))ms, submitted \(data.submittedFrames), skipped \(data.skippedFrames)\(skip)"
                + power
                + thermalPause
                + resourcePause
                + videoFallback
        }
        let interactionSummary = interactionEntries.map { entry in
            let data = entry.snapshot
            let active = data.active ? "active" : "inactive"
            let tap = data.eventTapActive ? "tap:on" : "tap:off"
            let local = data.localMonitorActive ? "local:on" : "local:off"
            let observed = interactionObservedCommandSummary(displayName: entry.displayName)
            return "\(entry.displayName) \(entry.roleName) interaction \(active) \(tap) \(local) global:\(data.globalMonitorCount) last:\(data.lastSource)/\(data.lastEvent)/\(data.lastDecision) point:\(data.lastPoint) command:\(data.lastCommand)/\(format(data.lastClickPulse)) delivered:\(data.deliveredEvents) blocked:\(data.blockedEvents) observed:\(observed)"
        }
        let lifecycleSummary = lifecycleEntries.map {
            "display lifecycle \($0.event) \($0.status): \($0.detail)"
        }
        return (renderSummary + interactionSummary + lifecycleSummary).joined(separator: "\n")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func interactionObservedCommandSummary(displayName: String) -> String {
        lock.lock()
        let commands = interactionObservations
            .filter { $0.displayName == displayName && $0.decision == "delivered" }
            .map(\.command)
        lock.unlock()

        let unique = commands
            .filter { $0.isEmpty == false && $0 != "unknown" }
            .uniquePreservingOrder()
        return unique.isEmpty ? "none" : unique.joined(separator: "+")
    }

}

private extension Array where Element == String {
    func uniquePreservingOrder() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
