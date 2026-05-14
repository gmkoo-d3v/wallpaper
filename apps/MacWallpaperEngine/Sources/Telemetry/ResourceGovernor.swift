import Foundation

struct PerformancePlan {
    let requestedFps: Int
    let effectiveTargetFps: Int
    let maxFps: Int
    let fallbackFps: Int
    let downgradeFpsLadder: [Int]
    let seriousThermalFps: Int
    let criticalPauses: Bool
    let maxInFlightCommandBuffers: Int
    let cpuTargetPercent: Double
    let cpuDowngradePercent: Double
    let cpuDowngradeWindowSeconds: Int
    let rssTargetMb: Int
    let rssHardMb: Int

    static func make(manifest: WallpaperNativeManifest, requestedFps: Int) -> PerformancePlan {
        let maxFps = max(manifest.runtime.maxFps, 1)
        let fallbackFps = max(min(manifest.runtime.fallbackFps, maxFps), 1)
        let effectiveTargetFps = max(min(requestedFps, maxFps), fallbackFps)
        let seriousThermalFps = manifest.thermalPolicy.serious.contains("15fps") ? 15 : fallbackFps
        let criticalPauses = manifest.thermalPolicy.critical == "pause"

        var ladder = [effectiveTargetFps, fallbackFps]
        for candidate in [120, 60, 30, 15] where candidate < effectiveTargetFps && candidate >= fallbackFps {
            ladder.append(candidate)
        }
        ladder = Array(Set(ladder.map { max(min($0, maxFps), 1) })).sorted(by: >)

        return PerformancePlan(
            requestedFps: requestedFps,
            effectiveTargetFps: effectiveTargetFps,
            maxFps: maxFps,
            fallbackFps: fallbackFps,
            downgradeFpsLadder: ladder,
            seriousThermalFps: max(min(seriousThermalFps, maxFps), 1),
            criticalPauses: criticalPauses,
            maxInFlightCommandBuffers: manifest.runtime.scheduler.maxInFlightCommandBuffers,
            cpuTargetPercent: manifest.layerBudgets.primaryCpuTargetPercent,
            cpuDowngradePercent: manifest.layerBudgets.cpuDowngradePercent,
            cpuDowngradeWindowSeconds: manifest.layerBudgets.cpuDowngradeWindowSeconds,
            rssTargetMb: manifest.layerBudgets.rssTargetMb,
            rssHardMb: manifest.layerBudgets.rssHardMb
        )
    }

    func summary() -> String {
        """
        performance plan OK
        requestedFps: \(requestedFps)
        effectiveTargetFps: \(effectiveTargetFps)
        maxFps: \(maxFps)
        fallbackFps: \(fallbackFps)
        downgradeFpsLadder: \(downgradeFpsLadder.map(String.init).joined(separator: " -> "))
        seriousThermalFps: \(seriousThermalFps)
        criticalThermal: \(criticalPauses ? "pause" : "throttle")
        maxInFlightCommandBuffers: \(maxInFlightCommandBuffers)
        cpuTargetPercent: \(cpuTargetPercent)
        cpuDowngradePercent: \(cpuDowngradePercent)
        cpuDowngradeWindowSeconds: \(cpuDowngradeWindowSeconds)
        rssTargetMb: \(rssTargetMb)
        rssHardMb: \(rssHardMb)
        """
    }
}

final class ResourceGovernor {
    private let plan: PerformancePlan
    private var frameDurations: [TimeInterval] = []
    private var currentFps: Int
    private var lastFrameTime: TimeInterval?

    init(manifest: WallpaperNativeManifest, targetFps: Int) {
        self.plan = PerformancePlan.make(manifest: manifest, requestedFps: targetFps)
        self.currentFps = plan.effectiveTargetFps
    }

    func frameStarted(now: TimeInterval) -> Int {
        if let lastFrameTime {
            let duration = now - lastFrameTime
            frameDurations.append(duration)
            if frameDurations.count > max(currentFps * 3, 60) {
                frameDurations.removeFirst(frameDurations.count - max(currentFps * 3, 60))
            }
            evaluate()
        }
        lastFrameTime = now
        return currentFps
    }

    var p95FrameTime: TimeInterval {
        guard frameDurations.isEmpty == false else { return 0 }
        let sorted = frameDurations.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        return sorted[index]
    }

    var shouldPauseForThermal: Bool {
        plan.criticalPauses && ProcessInfo.processInfo.thermalState == .critical
    }

    private func evaluate() {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical {
            currentFps = min(currentFps, plan.criticalPauses ? 1 : plan.seriousThermalFps)
            return
        }
        if thermal == .serious {
            currentFps = min(currentFps, plan.seriousThermalFps)
            return
        }

        guard frameDurations.count >= max(currentFps * 2, 60) else { return }
        let p95 = p95FrameTime
        let frameBudget = 1.0 / Double(max(currentFps, 1))
        guard p95 > frameBudget * 1.10 else { return }
        guard let currentIndex = plan.downgradeFpsLadder.firstIndex(of: currentFps),
              currentIndex + 1 < plan.downgradeFpsLadder.count else {
            return
        }
        currentFps = plan.downgradeFpsLadder[currentIndex + 1]
    }
}
