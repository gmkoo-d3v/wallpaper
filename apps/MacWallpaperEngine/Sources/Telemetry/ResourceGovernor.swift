import Foundation

final class ResourceGovernor {
    private let manifest: WallpaperNativeManifest
    private var frameDurations: [TimeInterval] = []
    private var currentFps: Int
    private var lastFrameTime: TimeInterval?
    private var lastUpgradeTime = Date()

    init(manifest: WallpaperNativeManifest, targetFps: Int) {
        self.manifest = manifest
        self.currentFps = targetFps
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
        ProcessInfo.processInfo.thermalState == .critical
    }

    private func evaluate() {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical {
            currentFps = min(currentFps, 1)
            return
        }
        if thermal == .serious {
            currentFps = min(currentFps, 15)
            return
        }

        let p95 = p95FrameTime
        if currentFps >= 120, p95 > 1.0 / 120.0 {
            currentFps = 60
            lastUpgradeTime = Date()
        } else if currentFps >= 60, p95 > 1.0 / 60.0 {
            currentFps = 30
            lastUpgradeTime = Date()
        } else if currentFps >= 30, p95 > 1.0 / 30.0 {
            currentFps = 15
            lastUpgradeTime = Date()
        }
    }
}
