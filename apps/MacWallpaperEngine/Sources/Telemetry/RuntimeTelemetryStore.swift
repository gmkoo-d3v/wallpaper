import Foundation

struct RuntimeTelemetryEntry {
    let displayName: String
    let roleName: String
    let snapshot: ResourceGovernorSnapshot
}

final class RuntimeTelemetryStore {
    private let lock = NSLock()
    private var entriesByDisplay: [String: RuntimeTelemetryEntry] = [:]

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

    func snapshot() -> [RuntimeTelemetryEntry] {
        lock.lock()
        let entries = Array(entriesByDisplay.values)
        lock.unlock()

        return entries.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func summary() -> String {
        let entries = snapshot()
        guard entries.isEmpty == false else {
            return "No runtime telemetry yet"
        }

        return entries.map { entry in
            let data = entry.snapshot
            let skip = data.lastSkipReason.map { " last=\($0)" } ?? ""
            let power = data.powerSavingActive ? " power-saving" : ""
            return "\(entry.displayName) \(entry.roleName): fps \(format(data.actualFps))/\(data.currentFps), p95 \(format(data.p95FrameTimeMs))ms, submitted \(data.submittedFrames), skipped \(data.skippedFrames)\(skip)"
                + power
        }
        .joined(separator: " | ")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
