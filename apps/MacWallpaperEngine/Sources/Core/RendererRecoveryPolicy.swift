import Foundation

struct RendererRecoveryKey: Codable, Hashable {
    let wallpaperID: String
    let displayFingerprint: String
    let rendererKind: String
    let failureClass: String
}

struct PersistedRendererRecoveryEntry: Codable, Equatable {
    let key: RendererRecoveryKey
    let failureTimes: [TimeInterval]
    let safeModeUntil: TimeInterval?
}

struct PersistedRendererRecoveryState: Codable, Equatable {
    let schemaVersion: Int
    let entries: [PersistedRendererRecoveryEntry]

    static let currentSchemaVersion = 1

    var sanitized: PersistedRendererRecoveryState {
        PersistedRendererRecoveryState(
            schemaVersion: Self.currentSchemaVersion,
            entries: entries.compactMap { entry in
                let failureTimes = entry.failureTimes
                    .filter(\.isFinite)
                    .sorted()
                guard failureTimes.isEmpty == false || entry.safeModeUntil?.isFinite == true else {
                    return nil
                }
                return PersistedRendererRecoveryEntry(
                    key: entry.key,
                    failureTimes: failureTimes,
                    safeModeUntil: entry.safeModeUntil?.isFinite == true ? entry.safeModeUntil : nil
                )
            }
        )
    }
}

enum RendererRecoveryDecision: Equatable {
    case retry(failureCount: Int, reason: String)
    case safeMode(failureCount: Int, retryAfterSeconds: TimeInterval, reason: String)

    var shouldYieldToSystemWallpaper: Bool {
        switch self {
        case .retry:
            return false
        case .safeMode:
            return true
        }
    }

    var message: String {
        switch self {
        case .retry(_, let reason), .safeMode(_, _, let reason):
            return reason
        }
    }
}

enum RendererRecoveryPolicy {
    static let policyName = "yield-to-system-wallpaper-after-repeated-renderer-failures"
    static let failureThreshold = 3
    static let failureWindowSeconds: TimeInterval = 60
    static let safeModeCooldownSeconds: TimeInterval = 300

    static func decision(
        failureTimes: [TimeInterval],
        now: TimeInterval
    ) -> RendererRecoveryDecision {
        let recentFailures = normalizedRecentFailureTimes(failureTimes, now: now)
        if recentFailures.count >= failureThreshold {
            return .safeMode(
                failureCount: recentFailures.count,
                retryAfterSeconds: safeModeCooldownSeconds,
                reason: "SAFE MODE / repeated renderer failures (\(recentFailures.count) in \(Int(failureWindowSeconds))s); yielding to system wallpaper until the user retries"
            )
        }
        return .retry(
            failureCount: recentFailures.count,
            reason: "renderer failure recorded (\(recentFailures.count)/\(failureThreshold)); retry still allowed"
        )
    }

    static func normalizedRecentFailureTimes(
        _ failureTimes: [TimeInterval],
        now: TimeInterval
    ) -> [TimeInterval] {
        failureTimes
            .filter { $0.isFinite && $0 >= now - failureWindowSeconds && $0 <= now }
            .sorted()
    }
}

enum RendererRecoveryStore {
    static let environmentRecoveryPath = "MAC_WALLPAPER_ENGINE_RECOVERY_PATH"

    static func load() -> PersistedRendererRecoveryState? {
        guard let recoveryURL = defaultRecoveryURL() else { return nil }
        return try? load(from: recoveryURL)
    }

    static func load(from recoveryURL: URL) throws -> PersistedRendererRecoveryState {
        let data = try Data(contentsOf: recoveryURL)
        return try JSONDecoder().decode(PersistedRendererRecoveryState.self, from: data).sanitized
    }

    static func save(_ state: PersistedRendererRecoveryState, to recoveryURL: URL) throws {
        let directory = recoveryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state.sanitized)
        try data.write(to: recoveryURL, options: .atomic)
    }

    static func defaultRecoveryURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment[environmentRecoveryPath]?.trimmingCharacters(in: .whitespacesAndNewlines),
           override.isEmpty == false {
            return URL(fileURLWithPath: override, relativeTo: nil).standardizedFileURL
        }
        return ProjectPaths.applicationSupportDirectory()?.appendingPathComponent("renderer-recovery.json")
    }

    static func report(recoveryURL: URL? = defaultRecoveryURL(), now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> String {
        let state: PersistedRendererRecoveryState
        let storeText: String
        if let recoveryURL {
            storeText = recoveryURL.path
            state = (try? load(from: recoveryURL)) ?? PersistedRendererRecoveryState(
                schemaVersion: PersistedRendererRecoveryState.currentSchemaVersion,
                entries: []
            )
        } else {
            storeText = "none"
            state = PersistedRendererRecoveryState(
                schemaVersion: PersistedRendererRecoveryState.currentSchemaVersion,
                entries: []
            )
        }

        var lines = [
            "renderer recovery plan OK",
            "store: \(storeText)",
            "policy: \(RendererRecoveryPolicy.policyName)",
            "threshold: \(RendererRecoveryPolicy.failureThreshold) failures / \(formatRecoverySeconds(RendererRecoveryPolicy.failureWindowSeconds))",
            "safeModeCooldown: \(formatRecoverySeconds(RendererRecoveryPolicy.safeModeCooldownSeconds))",
            "entries: \(state.entries.count)",
            "columns: state\twallpaper\tdisplay\trenderer\tfailureClass\trecentFailures\tretryAfter"
        ]

        if state.entries.isEmpty {
            lines.append("empty\tnone\tnone\tnone\tnone\t0\t0s")
            return lines.joined(separator: "\n")
        }

        for entry in sortedEntries(state.entries) {
            let recentFailures = RendererRecoveryPolicy.normalizedRecentFailureTimes(entry.failureTimes, now: now)
            let retryAfter = max((entry.safeModeUntil ?? 0) - now, 0)
            let stateText: String
            if retryAfter > 0 {
                stateText = "safe-mode"
            } else if recentFailures.isEmpty {
                stateText = "expired"
            } else {
                stateText = "tracking"
            }
            lines.append([
                stateText,
                entry.key.wallpaperID,
                entry.key.displayFingerprint,
                entry.key.rendererKind,
                entry.key.failureClass,
                "\(recentFailures.count)",
                formatRecoverySeconds(retryAfter)
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    private static func sortedEntries(_ entries: [PersistedRendererRecoveryEntry]) -> [PersistedRendererRecoveryEntry] {
        entries.sorted {
            [
                $0.key.wallpaperID,
                $0.key.displayFingerprint,
                $0.key.rendererKind,
                $0.key.failureClass
            ].joined(separator: "\u{1F}")
                < [
                    $1.key.wallpaperID,
                    $1.key.displayFingerprint,
                    $1.key.rendererKind,
                    $1.key.failureClass
                ].joined(separator: "\u{1F}")
        }
    }
}

final class RendererRecoveryTracker {
    private var failureTimesByKey: [RendererRecoveryKey: [TimeInterval]] = [:]
    private var safeModeUntilByKey: [RendererRecoveryKey: TimeInterval] = [:]
    private let storeURL: URL?

    init(storeURL: URL? = RendererRecoveryStore.defaultRecoveryURL()) {
        self.storeURL = storeURL
        guard let storeURL,
              let state = try? RendererRecoveryStore.load(from: storeURL) else {
            return
        }
        for entry in state.entries {
            failureTimesByKey[entry.key] = entry.failureTimes
            safeModeUntilByKey[entry.key] = entry.safeModeUntil
        }
    }

    func decisionBeforeStart(
        key: RendererRecoveryKey,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> RendererRecoveryDecision? {
        guard let safeModeUntil = safeModeUntilByKey[key] else { return nil }
        guard safeModeUntil > now else {
            safeModeUntilByKey[key] = nil
            persist()
            return nil
        }
        let retryAfter = safeModeUntil - now
        let failureCount = RendererRecoveryPolicy
            .normalizedRecentFailureTimes(failureTimesByKey[key] ?? [], now: now)
            .count
        return .safeMode(
            failureCount: max(failureCount, RendererRecoveryPolicy.failureThreshold),
            retryAfterSeconds: retryAfter,
            reason: "SAFE MODE / renderer is quarantined for \(Int(ceil(retryAfter)))s; yielding to system wallpaper"
        )
    }

    func recordFailure(
        key: RendererRecoveryKey,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> RendererRecoveryDecision {
        let recentFailures = RendererRecoveryPolicy.normalizedRecentFailureTimes(
            (failureTimesByKey[key] ?? []) + [now],
            now: now
        )
        failureTimesByKey[key] = recentFailures
        let decision = RendererRecoveryPolicy.decision(failureTimes: recentFailures, now: now)
        if case .safeMode = decision {
            safeModeUntilByKey[key] = now + RendererRecoveryPolicy.safeModeCooldownSeconds
        }
        persist()
        return decision
    }

    func recordSuccess(key: RendererRecoveryKey) {
        failureTimesByKey[key] = nil
        safeModeUntilByKey[key] = nil
        persist()
    }

    private func persist() {
        guard let storeURL else { return }
        do {
            try RendererRecoveryStore.save(persistedState, to: storeURL)
        } catch {
            fputs("Failed to save renderer recovery state: \(error.localizedDescription)\n", stderr)
        }
    }

    private var persistedState: PersistedRendererRecoveryState {
        let keys = Set(failureTimesByKey.keys).union(safeModeUntilByKey.keys)
        let entries = keys
            .sorted {
                [
                    $0.wallpaperID,
                    $0.displayFingerprint,
                    $0.rendererKind,
                    $0.failureClass
                ].joined(separator: "\u{1F}")
                    < [
                        $1.wallpaperID,
                        $1.displayFingerprint,
                        $1.rendererKind,
                        $1.failureClass
                    ].joined(separator: "\u{1F}")
            }
            .compactMap { key -> PersistedRendererRecoveryEntry? in
                let failureTimes = failureTimesByKey[key] ?? []
                let safeModeUntil = safeModeUntilByKey[key]
                guard failureTimes.isEmpty == false || safeModeUntil != nil else { return nil }
                return PersistedRendererRecoveryEntry(
                    key: key,
                    failureTimes: failureTimes,
                    safeModeUntil: safeModeUntil
                )
            }
        return PersistedRendererRecoveryState(
            schemaVersion: PersistedRendererRecoveryState.currentSchemaVersion,
            entries: entries
        )
    }
}

private func formatRecoverySeconds(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite else { return "unknown" }
    return "\(Int(ceil(max(seconds, 0))))s"
}
