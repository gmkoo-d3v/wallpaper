import Foundation
import Metal

struct SpineGeometryDiagnostics {
    static let poseBudgetPolicy = "p95-pose<=50%-frame-budget-pass;<=100%-warn;>100%-fail"
    private static let poseBudgetSoftLimitFraction = 0.50

    static func make(runtime: NativeRuntimeCore) throws -> String {
        let actionNames = manifestActionNames(runtime.manifest)
        guard let spineAsset = runtime.assetCatalog.spineAsset else {
            return noSpineSummary(actionNames: actionNames)
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            return metalUnavailableSummary(spineAsset: spineAsset, actionNames: actionNames)
        }

        let renderer = try makeRenderer(runtime: runtime, spineAsset: spineAsset, device: device)
        let samples = renderer.diagnosticGeometrySamples(actionNames: actionNames)
        let invalidSamples = samples.filter { $0.status != "renderable" }

        var lines = [
            "spine geometry plan OK",
            "spine: \(spineAsset.json.path)",
            "setupBatches: \(renderer.batchCount)",
            "setupVertices: \(renderer.triangleVertexCount)",
            "actions: \(actionNames.isEmpty ? "none" : actionNames.joined(separator: ","))",
            samplePolicyLine(
                poseSampleFps: runtime.nativeSpinePoseSampleFps(displayRefreshFps: nil),
                idlePoseSampleFps: runtime.nativeSpineIdlePoseSampleFps(displayRefreshFps: nil)
            ),
            "invalidGeometrySamples: \(invalidSamples.isEmpty ? "none" : invalidSamples.map { "\($0.actionName)@\(formatSeconds($0.time)):\($0.status)" }.joined(separator: ","))",
            "columns: kind\taction\ttime\tstatus\tbatches\tvertices\tblendModes\tuv\tbounds\tfingerprint\terror"
        ]

        for sample in samples {
            lines.append([
                "geometry",
                sample.actionName,
                formatSeconds(sample.time),
                sample.status,
                "\(sample.batchCount)",
                "\(sample.vertexCount)",
                sample.blendModes,
                sample.uvStatus,
                sample.bounds,
                sample.fingerprint,
                sample.error
            ].joined(separator: "\t"))
        }

        return lines.joined(separator: "\n")
    }

    static func requireRenderableSamples(runtime: NativeRuntimeCore) throws {
        guard let spineAsset = runtime.assetCatalog.spineAsset else { return }
        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        guard compatibility.isSupported else { return }
        guard let device = MTLCreateSystemDefaultDevice() else {
            fputs("Native Spine geometry preflight skipped: Metal device unavailable in this process.\n", stderr)
            return
        }

        let actionNames = manifestActionNames(runtime.manifest)
        let renderer = try makeRenderer(runtime: runtime, spineAsset: spineAsset, device: device)
        let invalidSamples = renderer
            .diagnosticGeometrySamples(actionNames: actionNames)
            .filter { $0.status != "renderable" }
        guard invalidSamples.isEmpty else {
            let details = invalidSamples
                .map { "\($0.actionName)@\(formatSeconds($0.time)):\($0.status):\($0.error)" }
                .joined(separator: ",")
            throw EngineError.renderer("native Spine geometry preflight failed: \(details)")
        }
    }

    static func profile(runtime: NativeRuntimeCore, iterations: Int = 6) throws -> String {
        let actionNames = manifestActionNames(runtime.manifest)
        guard let spineAsset = runtime.assetCatalog.spineAsset else {
            return [
                "spine profile OK",
                "spine: none",
                "status: not-used",
                "iterations: 0"
            ].joined(separator: "\n")
        }
        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        guard compatibility.isSupported else {
            return [
                "spine profile OK",
                "spine: \(spineAsset.json.path)",
                "status: native-unsupported",
                "reason: \(compatibility.reasonText)",
                "iterations: 0"
            ].joined(separator: "\n")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            return [
                "spine profile OK",
                "spine: \(spineAsset.json.path)",
                "status: metal-unavailable",
                "iterations: 0"
            ].joined(separator: "\n")
        }

        var constructedRenderer: SpineSetupPoseRenderer?
        let initMs = try measureMilliseconds {
            constructedRenderer = try makeRenderer(runtime: runtime, spineAsset: spineAsset, device: device)
        }
        guard let renderer = constructedRenderer else {
            throw EngineError.renderer("Could not create native Spine profiler renderer")
        }

        var latestSamples: [SpineSetupPoseRenderer.GeometrySample] = []
        let warmupMs = measureMilliseconds {
            latestSamples = renderer.diagnosticGeometrySamples(actionNames: actionNames)
        }

        let safeIterations = max(iterations, 1)
        var iterationMs: [Double] = []
        for _ in 0..<safeIterations {
            let elapsed = measureMilliseconds {
                latestSamples = renderer.diagnosticGeometrySamples(actionNames: actionNames)
            }
            iterationMs.append(elapsed)
        }

        let invalidSamples = latestSamples.filter { $0.status != "renderable" }
        let poseSampleFps = runtime.nativeSpinePoseSampleFps(displayRefreshFps: nil)
        let idlePoseSampleFps = runtime.nativeSpineIdlePoseSampleFps(displayRefreshFps: nil)
        let frameBudgetMs = 1000.0 / Double(max(runtime.renderTargetFps, 1))
        let averageMs = iterationMs.reduce(0, +) / Double(iterationMs.count)
        let p95Ms = percentile(iterationMs, fraction: 0.95)
        let maxMs = iterationMs.max() ?? 0
        let samplesPerIteration = max(latestSamples.count, 1)
        let averagePoseMs = averageMs / Double(samplesPerIteration)
        let p95PoseMs = p95Ms / Double(samplesPerIteration)
        let maxPoseMs = maxMs / Double(samplesPerIteration)
        let softLimitMs = frameBudgetMs * poseBudgetSoftLimitFraction
        let poseBudgetStatus = poseBudgetStatus(
            invalidSamples: invalidSamples,
            p95PoseMs: p95PoseMs,
            softLimitMs: softLimitMs,
            frameBudgetMs: frameBudgetMs
        )
        let cacheProbe = renderer.diagnosticPoseCacheProbe(
            command: SpineInteractionAnimationRoles.idleAnimationName(from: runtime.manifest)
        )
        let cacheStats = cacheProbe.stats
        let profileStatus = invalidSamples.isEmpty ? "renderable" : "invalid-samples"

        return [
            "spine profile OK",
            "spine: \(spineAsset.json.path)",
            "status: \(profileStatus)",
            "actions: \(actionNames.isEmpty ? "none" : actionNames.joined(separator: ","))",
            "iterations: \(safeIterations)",
            "samplesPerIteration: \(latestSamples.count)",
            "setupBatches: \(renderer.batchCount)",
            "setupVertices: \(renderer.triangleVertexCount)",
            "timelineSampling: \(SpineSetupPoseRenderer.timelineSamplingPolicy)",
            "poseSampleFps: \(poseSampleFps)",
            "idlePoseSampleFps: \(idlePoseSampleFps)",
            "renderTargetFps: \(runtime.renderTargetFps)",
            "physicsIdlePolicy: \(runtime.manifest.runtime.effectivePhysicsIdlePolicy.rawValue)",
            "initMs: \(formatMilliseconds(initMs))",
            "warmupSampleMs: \(formatMilliseconds(warmupMs))",
            "averageSampleMs: \(formatMilliseconds(averageMs))",
            "p95SampleMs: \(formatMilliseconds(p95Ms))",
            "maxSampleMs: \(formatMilliseconds(maxMs))",
            "targetFrameBudgetMs: \(formatMilliseconds(frameBudgetMs))",
            "averagePoseSampleMs: \(formatMilliseconds(averagePoseMs))",
            "p95PoseSampleMs: \(formatMilliseconds(p95PoseMs))",
            "maxPoseSampleMs: \(formatMilliseconds(maxPoseMs))",
            "poseBudgetSoftLimitMs: \(formatMilliseconds(softLimitMs))",
            "poseBudgetPolicy: \(poseBudgetPolicy)",
            "poseBudgetStatus: \(poseBudgetStatus)",
            "poseCacheProbe: idle",
            "poseCacheFirstBuildMs: \(formatMilliseconds(cacheProbe.firstBuildMs))",
            "poseCacheExactHitMs: \(formatMilliseconds(cacheProbe.exactHitMs))",
            "poseCacheFrameHitMs: \(formatMilliseconds(cacheProbe.frameHitMs))",
            "poseCacheStats: exactHits=\(cacheStats.exactHits) frameHits=\(cacheStats.frameHits) misses=\(cacheStats.misses) stores=\(cacheStats.stores) entries=\(cacheStats.entries) bytes=\(cacheStats.bytes)",
            "invalidGeometrySamples: \(invalidSamples.isEmpty ? "none" : invalidSamples.map { "\($0.actionName)@\(formatSeconds($0.time)):\($0.status)" }.joined(separator: ","))"
        ].joined(separator: "\n")
    }

    static func validationStatus(runtime: NativeRuntimeCore) -> String {
        guard runtime.assetCatalog.spineAsset != nil else { return "not-used" }
        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        guard compatibility.isSupported else { return "skipped(native-unsupported)" }
        guard MTLCreateSystemDefaultDevice() != nil else { return "skipped(metal-unavailable)" }
        return "required"
    }

    static func writeSnapshot(
        runtime: NativeRuntimeCore,
        destination: URL,
        actionName: String,
        time: Double,
        width: Int,
        height: Int
    ) throws -> String {
        guard let spineAsset = runtime.assetCatalog.spineAsset else {
            throw EngineError.renderer("Selected bundle has no native Spine asset")
        }
        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        guard compatibility.isSupported else {
            throw EngineError.renderer("Selected bundle is not native-Spine compatible: \(compatibility.reasonText)")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EngineError.renderer("Metal device unavailable for Spine snapshot")
        }

        let renderer = try makeRenderer(runtime: runtime, spineAsset: spineAsset, device: device)
        let image = try renderer.diagnosticSnapshot(
            actionName: actionName,
            time: time,
            width: width,
            height: height
        )
        try MetalSnapshotImage.writePNG(image, to: destination)
        return """
        spine snapshot OK
        action: \(actionName)
        time: \(formatSeconds(time))
        size: \(width)x\(height)
        output: \(destination.path)
        background: white
        """
    }

    private static func makeRenderer(
        runtime: NativeRuntimeCore,
        spineAsset: SpineAsset,
        device: MTLDevice
    ) throws -> SpineSetupPoseRenderer {
        try SpineSetupPoseRenderer(
            spineAsset: spineAsset,
            device: device,
            playbackRate: runtime.selectedPlaybackRate,
            poseSampleFps: runtime.nativeSpinePoseSampleFps(displayRefreshFps: nil),
            idlePoseSampleFps: runtime.nativeSpineIdlePoseSampleFps(displayRefreshFps: nil),
            lookAnimationNames: SpineInteractionAnimationRoles.lookAnimationNames(from: runtime.manifest),
            lookNeutralPoint: SpineInteractionAnimationRoles.lookNeutralPoint(from: runtime.manifest),
            lookDeadZone: SpineInteractionAnimationRoles.lookDeadZone(
                from: runtime.manifest,
                fallback: runtime.manifest.interactionPolicy?.idleDeadZone ?? 0.18
            ),
            lookIdleDeadZone: runtime.manifest.interactionPolicy?.idleDeadZone ?? 0.18,
            physicsIdlePolicy: runtime.manifest.runtime.effectivePhysicsIdlePolicy,
            idleAnimationName: SpineInteractionAnimationRoles.idleAnimationName(from: runtime.manifest),
            loopingAnimationNames: SpineInteractionAnimationRoles.loopingAnimationNames(from: runtime.manifest),
            oneShotAnimationNames: SpineInteractionAnimationRoles.oneShotAnimationNames(from: runtime.manifest),
            declarativePlan: DeclarativeBindingPlan(manifest: runtime.manifest)
        )
    }

    private static func noSpineSummary(actionNames: [String]) -> String {
        [
            "spine geometry plan OK",
            "spine: none",
            "setupBatches: 0",
            "setupVertices: 0",
            "actions: \(actionNames.isEmpty ? "none" : actionNames.joined(separator: ","))",
            samplePolicyLine(poseSampleFps: nil, idlePoseSampleFps: nil),
            "invalidGeometrySamples: none",
            "columns: kind\taction\ttime\tstatus\tbatches\tvertices\tblendModes\tuv\tbounds\tfingerprint\terror"
        ].joined(separator: "\n")
    }

    private static func metalUnavailableSummary(spineAsset: SpineAsset, actionNames: [String]) -> String {
        [
            "spine geometry plan OK",
            "spine: \(spineAsset.json.path)",
            "setupBatches: 0",
            "setupVertices: 0",
            "actions: \(actionNames.isEmpty ? "none" : actionNames.joined(separator: ","))",
            samplePolicyLine(poseSampleFps: nil, idlePoseSampleFps: nil),
            "invalidGeometrySamples: metal-unavailable",
            "columns: kind\taction\ttime\tstatus\tbatches\tvertices\tblendModes\tuv\tbounds\tfingerprint\terror"
        ].joined(separator: "\n")
    }

    private static func manifestActionNames(_ manifest: WallpaperNativeManifest) -> [String] {
        var names = Set<String>()
        for interaction in manifest.interactions {
            interaction.actions?.values.forEach { names.insert($0) }
            interaction.hitZones?.forEach {
                names.insert($0.action)
                if let tapAction = $0.tapAction {
                    names.insert(tapAction)
                }
            }
            if let defaultAction = interaction.defaultAction {
                names.insert(defaultAction.action)
            }
        }
        if names.isEmpty {
            names.insert(SpineInteractionAnimationRoles.idleAnimationName(from: manifest))
        }
        return Array(names).sorted()
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3fs", value)
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func measureMilliseconds(_ work: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try work()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000.0
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double {
        guard values.isEmpty == false else { return 0 }
        let sorted = values.sorted()
        let clamped = min(max(fraction, 0), 1)
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * clamped))
        return sorted[index]
    }

    private static func poseBudgetStatus(
        invalidSamples: [SpineSetupPoseRenderer.GeometrySample],
        p95PoseMs: Double,
        softLimitMs: Double,
        frameBudgetMs: Double
    ) -> String {
        guard invalidSamples.isEmpty else { return "fail(invalid-geometry)" }
        if p95PoseMs <= softLimitMs {
            return "pass"
        }
        if p95PoseMs <= frameBudgetMs {
            return "warn"
        }
        return "fail"
    }

    private static func samplePolicyLine(poseSampleFps: Int?, idlePoseSampleFps: Int?) -> String {
        let fpsText = poseSampleFps.map { " poseFps=\($0)" } ?? ""
        let idleFpsText = idlePoseSampleFps.map { " idlePoseFps=\($0)" } ?? ""
        return "samplePolicy: timeline-keyframes+discrete-transitions+runtime-cadence+look-mix\(fpsText)\(idleFpsText) maxPerAction=\(SpineSetupPoseRenderer.maxGeometryDiagnosticSamplesPerAction)"
    }
}
