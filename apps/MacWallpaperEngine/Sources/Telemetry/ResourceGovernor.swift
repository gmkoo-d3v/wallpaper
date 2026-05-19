import Darwin
import Foundation
import IOKit.ps

struct PerformancePlan {
    let requestedFps: Int
    let effectiveTargetFps: Int
    let maxFps: Int
    let fallbackFps: Int
    let powerSavingFps: Int
    let downgradeFpsLadder: [Int]
    let seriousThermalFps: Int
    let criticalPauses: Bool
    let maxInFlightCommandBuffers: Int
    let cpuTargetPercent: Double
    let cpuDowngradePercent: Double
    let cpuDowngradeWindowSeconds: Int
    let rssTargetMb: Int
    let rssHardMb: Int

    static func make(
        manifest: WallpaperNativeManifest,
        requestedFps: Int,
        maxFpsOverride: Int? = nil
    ) -> PerformancePlan {
        let maxFps = max(manifest.runtime.maxFps, maxFpsOverride ?? 1, 1)
        let fallbackFps = max(min(manifest.runtime.fallbackFps, maxFps), 1)
        let effectiveTargetFps = max(min(requestedFps, maxFps), fallbackFps)
        let seriousThermalFps = manifest.thermalPolicy.serious.contains("15fps") ? 15 : fallbackFps
        let criticalPauses = manifest.thermalPolicy.critical == "pause"

        var ladder = [effectiveTargetFps, fallbackFps]
        for candidate in [240, 165, 144, 120, 60, 30, 15] where candidate < effectiveTargetFps && candidate >= fallbackFps {
            ladder.append(candidate)
        }
        ladder = Array(Set(ladder.map { max(min($0, maxFps), 1) })).sorted(by: >)

        return PerformancePlan(
            requestedFps: requestedFps,
            effectiveTargetFps: effectiveTargetFps,
            maxFps: maxFps,
            fallbackFps: fallbackFps,
            powerSavingFps: fallbackFps,
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
        powerSavingFps: \(powerSavingFps)
        downgradeFpsLadder: \(downgradeFpsLadder.map(String.init).joined(separator: " -> "))
        seriousThermalFps: \(seriousThermalFps)
        criticalThermal: \(criticalPauses ? "pause" : "throttle")
        exhaustedBudgetFallback: fps downgrade; renderer swap disabled by default
        maxInFlightCommandBuffers: \(maxInFlightCommandBuffers)
        cpuTargetPercent: \(cpuTargetPercent)
        cpuDowngradePercent: \(cpuDowngradePercent)
        cpuDowngradeWindowSeconds: \(cpuDowngradeWindowSeconds)
        rssTargetMb: \(rssTargetMb)
        rssHardMb: \(rssHardMb)
        telemetryFields: currentFps, actualFps, p95FrameTimeMs, submittedFrames, skippedFrames, lastSkipReason, powerSavingActive, pauseForThermal, pauseForResourceBudget, videoOnlyFallback
        """
    }
}

enum FrameSkipReason: String {
    case commandBufferBackpressure
    case drawableUnavailable
    case commandBufferUnavailable
    case encoderUnavailable
}

struct ResourceGovernorSnapshot {
    let currentFps: Int
    let actualFps: Double
    let p95FrameTimeMs: Double
    let submittedFrames: Int
    let skippedFrames: Int
    let lastSkipReason: String?
    let powerSavingActive: Bool
    let pauseForThermal: Bool
    let pauseForResourceBudget: Bool
    let videoOnlyFallback: Bool
}

struct RuntimePowerState: Equatable {
    let lowPowerModeEnabled: Bool
    let onBatteryPower: Bool

    var shouldConservePower: Bool {
        lowPowerModeEnabled || onBatteryPower
    }
}

struct ResourceGovernorSample {
    let timestamp: TimeInterval
    let cpuPercent: Double?
    let rssMb: Int?
}

enum RuntimePowerStateProvider {
    static func current() -> RuntimePowerState {
        RuntimePowerState(
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            onBatteryPower: isOnBatteryPower()
        )
    }

    private static func isOnBatteryPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }

        let stateKey = kIOPSPowerSourceStateKey as String
        let batteryValue = kIOPSBatteryPowerValue as String
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                let state = description[stateKey] as? String else {
                continue
            }
            if state == batteryValue {
                return true
            }
        }
        return false
    }
}

final class ResourceGovernor {
    private let plan: PerformancePlan
    private let videoOnlyFallbackEnabled: Bool
    private let powerStateProvider: () -> RuntimePowerState
    private let thermalStateProvider: () -> ProcessInfo.ThermalState
    private let resourceSampler: (TimeInterval) -> ResourceGovernorSample
    private var frameDurations: [TimeInterval] = []
    private var resourceSamples: [ResourceGovernorSample] = []
    private var currentFps: Int
    private var resourceFpsCap: Int
    private var lastPowerState = RuntimePowerState(lowPowerModeEnabled: false, onBatteryPower: false)
    private var lastFrameTime: TimeInterval?
    private var lastResourceSampleTime: TimeInterval?
    private var pauseForResourceBudget = false
    private var videoOnlyForResourceBudget = false
    private var submittedFrames = 0
    private var skippedFrames = 0
    private var lastSkipReason: FrameSkipReason?

    init(
        manifest: WallpaperNativeManifest,
        targetFps: Int,
        videoOnlyFallbackEnabled: Bool = false,
        powerStateProvider: @escaping () -> RuntimePowerState = RuntimePowerStateProvider.current,
        thermalStateProvider: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
        resourceSampler: @escaping (TimeInterval) -> ResourceGovernorSample = ProcessResourceSampler.sample
    ) {
        self.plan = PerformancePlan.make(manifest: manifest, requestedFps: targetFps)
        self.videoOnlyFallbackEnabled = videoOnlyFallbackEnabled
        self.powerStateProvider = powerStateProvider
        self.thermalStateProvider = thermalStateProvider
        self.resourceSampler = resourceSampler
        self.currentFps = plan.effectiveTargetFps
        self.resourceFpsCap = plan.effectiveTargetFps
    }

    func frameStarted(now: TimeInterval) -> Int {
        lastPowerState = powerStateProvider()
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

    func recordSubmittedFrame() {
        submittedFrames += 1
    }

    func recordSkippedFrame(reason: FrameSkipReason) {
        skippedFrames += 1
        lastSkipReason = reason
    }

    var p95FrameTime: TimeInterval {
        guard frameDurations.isEmpty == false else { return 0 }
        let sorted = frameDurations.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        return sorted[index]
    }

    var shouldPauseForThermal: Bool {
        plan.criticalPauses && thermalStateProvider() == .critical
    }

    var shouldPauseForResourceBudget: Bool {
        pauseForResourceBudget
    }

    var shouldUseVideoOnlyFallback: Bool {
        videoOnlyForResourceBudget
    }

    var snapshot: ResourceGovernorSnapshot {
        ResourceGovernorSnapshot(
            currentFps: currentFps,
            actualFps: actualFps,
            p95FrameTimeMs: p95FrameTime * 1000.0,
            submittedFrames: submittedFrames,
            skippedFrames: skippedFrames,
            lastSkipReason: lastSkipReason?.rawValue,
            powerSavingActive: lastPowerState.shouldConservePower,
            pauseForThermal: shouldPauseForThermal,
            pauseForResourceBudget: shouldPauseForResourceBudget,
            videoOnlyFallback: shouldUseVideoOnlyFallback
        )
    }

    private var actualFps: Double {
        guard frameDurations.isEmpty == false else { return 0 }
        let average = frameDurations.reduce(0, +) / Double(frameDurations.count)
        guard average > 0 else { return 0 }
        return 1.0 / average
    }

    private func sampleResources(now: TimeInterval) {
        if let lastResourceSampleTime, now - lastResourceSampleTime < 1.0 {
            return
        }
        lastResourceSampleTime = now
        resourceSamples.append(resourceSampler(now))

        let window = TimeInterval(max(plan.cpuDowngradeWindowSeconds, 1))
        resourceSamples.removeAll { now - $0.timestamp > window }
    }

    private func evaluate() {
        pauseForResourceBudget = false
        applyCurrentFpsCap()

        let thermal = thermalStateProvider()
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
                currentFps = min(currentFps, plan.fallbackFps)
                return
            }
            if rssMb >= plan.rssTargetMb {
                downgradeOrUseVideoFallback()
                return
            }
        }

        if shouldDowngradeForCPU() {
            downgradeOrUseVideoFallback()
            return
        }

        guard frameDurations.count >= max(currentFps * 2, 60) else { return }
        let p95 = p95FrameTime
        let frameBudget = 1.0 / Double(max(currentFps, 1))
        guard p95 > frameBudget * 1.10 else { return }
        downgradeOrUseVideoFallback()
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

    private func downgradeOneStep() -> Bool {
        guard let currentIndex = plan.downgradeFpsLadder.firstIndex(of: resourceFpsCap),
              currentIndex + 1 < plan.downgradeFpsLadder.count else {
            return false
        }
        resourceFpsCap = plan.downgradeFpsLadder[currentIndex + 1]
        applyCurrentFpsCap()
        return true
    }

    private func downgradeOrUseVideoFallback() {
        guard videoOnlyForResourceBudget == false else { return }
        if downgradeOneStep() == false && videoOnlyFallbackEnabled {
            videoOnlyForResourceBudget = true
        }
    }

    private func applyCurrentFpsCap() {
        let policyCap = lastPowerState.shouldConservePower ? plan.powerSavingFps : plan.effectiveTargetFps
        currentFps = min(resourceFpsCap, policyCap)
    }
}

private enum ProcessResourceSampler {
    static func sample(now: TimeInterval) -> ResourceGovernorSample {
        ResourceGovernorSample(
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
