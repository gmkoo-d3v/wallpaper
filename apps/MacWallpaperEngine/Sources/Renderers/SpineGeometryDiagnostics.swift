import Foundation
import Metal

struct SpineGeometryDiagnostics {
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
            samplePolicyLine(poseSampleFps: runtime.renderTargetFps),
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
            poseSampleFps: runtime.renderTargetFps,
            lookAnimationNames: SpineInteractionAnimationRoles.lookAnimationNames(from: runtime.manifest),
            lookIdleDeadZone: runtime.manifest.interactionPolicy?.idleDeadZone ?? 0.18,
            loopingAnimationNames: SpineInteractionAnimationRoles.loopingAnimationNames(from: runtime.manifest),
            oneShotAnimationNames: SpineInteractionAnimationRoles.oneShotAnimationNames(from: runtime.manifest)
        )
    }

    private static func noSpineSummary(actionNames: [String]) -> String {
        [
            "spine geometry plan OK",
            "spine: none",
            "setupBatches: 0",
            "setupVertices: 0",
            "actions: \(actionNames.isEmpty ? "none" : actionNames.joined(separator: ","))",
            samplePolicyLine(poseSampleFps: nil),
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
            samplePolicyLine(poseSampleFps: nil),
            "invalidGeometrySamples: metal-unavailable",
            "columns: kind\taction\ttime\tstatus\tbatches\tvertices\tblendModes\tuv\tbounds\tfingerprint\terror"
        ].joined(separator: "\n")
    }

    private static func manifestActionNames(_ manifest: WallpaperNativeManifest) -> [String] {
        var names = Set<String>()
        for interaction in manifest.interactions {
            interaction.actions?.values.forEach { names.insert($0) }
            interaction.hitZones?.forEach { names.insert($0.action) }
            if let defaultAction = interaction.defaultAction {
                names.insert(defaultAction.action)
            }
        }
        if names.isEmpty {
            names.insert("idle")
        }
        return Array(names).sorted()
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3fs", value)
    }

    private static func samplePolicyLine(poseSampleFps: Int?) -> String {
        let fpsText = poseSampleFps.map { " poseFps=\($0)" } ?? ""
        return "samplePolicy: timeline-keyframes+discrete-transitions+runtime-cadence+look-mix\(fpsText) maxPerAction=\(SpineSetupPoseRenderer.maxGeometryDiagnosticSamplesPerAction)"
    }
}
