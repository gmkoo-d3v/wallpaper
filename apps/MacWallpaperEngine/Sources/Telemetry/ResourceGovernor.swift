import Darwin
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
    private var resourceSamples: [ResourceSample] = []
    private var currentFps: Int
    private var lastFrameTime: TimeInterval?
    private var lastResourceSampleTime: TimeInterval?
    private var pauseForResourceBudget = false

    init(manifest: WallpaperNativeManifest, targetFps: Int) {
        self.plan = PerformancePlan.make(manifest: manifest, requestedFps: targetFps)
        self.currentFps = plan.effectiveTargetFps
    }

    func frameStarted(now: TimeInterval) -> Int {
        sampleResources(now: now)
        if let lastFrameTime {
            let duration = now - lastFrameTime
            frameDurations.append(duration)
            if frameDurations.count > max(currentFps * 3, 60) {
                frameDurations.removeFirst(frameDurations.count - max(currentFps * 3, 60))
            }
        }
        lastFrameTime = now
        evaluate()
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

    var shouldPauseForResourceBudget: Bool {
        pauseForResourceBudget
    }

    private func sampleResources(now: TimeInterval) {
        if let lastResourceSampleTime, now - lastResourceSampleTime < 1.0 {
            return
        }
        lastResourceSampleTime = now
        resourceSamples.append(ProcessResourceSampler.sample(now: now))

        let window = TimeInterval(max(plan.cpuDowngradeWindowSeconds, 1))
        resourceSamples.removeAll { now - $0.timestamp > window }
    }

    private func evaluate() {
        pauseForResourceBudget = false

        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical {
            currentFps = min(currentFps, plan.criticalPauses ? 1 : plan.seriousThermalFps)
            return
        }
        if thermal == .serious {
            currentFps = min(currentFps, plan.seriousThermalFps)
            return
        }

        if let rssMb = resourceSamples.last?.rssMb {
            if rssMb >= plan.rssHardMb {
                pauseForResourceBudget = true
                currentFps = min(currentFps, plan.fallbackFps)
                return
            }
            if rssMb >= plan.rssTargetMb {
                downgradeOneStep()
            }
        }

        if shouldDowngradeForCPU() {
            downgradeOneStep()
        }

        guard frameDurations.count >= max(currentFps * 2, 60) else { return }
        let p95 = p95FrameTime
        let frameBudget = 1.0 / Double(max(currentFps, 1))
        guard p95 > frameBudget * 1.10 else { return }
        downgradeOneStep()
    }

    private func shouldDowngradeForCPU() -> Bool {
        let values = resourceSamples.compactMap(\.cpuPercent)
        guard values.isEmpty == false else { return false }

        let oldest = resourceSamples.first?.timestamp ?? 0
        let newest = resourceSamples.last?.timestamp ?? oldest
        guard newest - oldest >= TimeInterval(max(plan.cpuDowngradeWindowSeconds - 1, 1)) else {
            return false
        }

        let average = values.reduce(0, +) / Double(values.count)
        return average >= plan.cpuDowngradePercent
    }

    private func downgradeOneStep() {
        guard let currentIndex = plan.downgradeFpsLadder.firstIndex(of: currentFps),
              currentIndex + 1 < plan.downgradeFpsLadder.count else {
            return
        }
        currentFps = plan.downgradeFpsLadder[currentIndex + 1]
    }
}

private struct ResourceSample {
    let timestamp: TimeInterval
    let cpuPercent: Double?
    let rssMb: Int?
}

private enum ProcessResourceSampler {
    static func sample(now: TimeInterval) -> ResourceSample {
        ResourceSample(
            timestamp: now,
            cpuPercent: currentCPUPercent(),
            rssMb: currentRSSMb()
        )
    }

    private static func currentRSSMb() -> Int? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return Int(info.resident_size / 1024 / 1024)
    }

    private static func currentCPUPercent() -> Double? {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threadList else { return nil }
        defer {
            let byteCount = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), byteCount)
        }

        var totalPercent = 0.0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let thread = threadList[index]
            let infoResult = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                    thread_info(
                        thread,
                        thread_flavor_t(THREAD_BASIC_INFO),
                        reboundPointer,
                        &count
                    )
                }
            }
            guard infoResult == KERN_SUCCESS else { continue }
            guard info.flags & TH_FLAGS_IDLE == 0 else { continue }
            totalPercent += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
        }

        return totalPercent.isFinite ? max(totalPercent, 0.0) : nil
    }
}
