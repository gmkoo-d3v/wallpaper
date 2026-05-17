import Foundation

struct RendererRecoveryKey: Hashable {
    let wallpaperID: String
    let displayFingerprint: String
    let rendererKind: String
    let failureClass: String
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

final class RendererRecoveryTracker {
    private var failureTimesByKey: [RendererRecoveryKey: [TimeInterval]] = [:]
    private var safeModeUntilByKey: [RendererRecoveryKey: TimeInterval] = [:]

    func decisionBeforeStart(
        key: RendererRecoveryKey,
        now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> RendererRecoveryDecision? {
        guard let safeModeUntil = safeModeUntilByKey[key], safeModeUntil > now else {
            safeModeUntilByKey[key] = nil
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
        return decision
    }

    func recordSuccess(key: RendererRecoveryKey) {
        failureTimesByKey[key] = nil
        safeModeUntilByKey[key] = nil
    }
}
