import Foundation

final class NativeRuntimeCore {
    let config: EngineConfig
    let manifest: WallpaperNativeManifest
    let assetCatalog: AssetCatalog
    let telemetry = RuntimeTelemetryStore()
    var performancePlan: PerformancePlan {
        performancePlan(displayRefreshFps: nil)
    }
    var renderTargetFps: Int { performancePlan.effectiveTargetFps }
    var renderFpsModeText: String {
        config.matchDisplayRefresh ? "display" : "\(renderTargetFps)"
    }
    var audioOutputEnabled: Bool {
        manifest.runtime.effectiveAudioPolicy == .userControlled && config.audioEnabled
    }
    var audioOutputSummary: String {
        switch manifest.runtime.effectiveAudioPolicy {
        case .muted:
            return "muted"
        case .userControlled:
            return config.audioEnabled ? "enabled-user-opt-in" : "muted-until-user-opt-in"
        case .disabled:
            return "disabled-muted"
        }
    }
    var audioCapabilityStatus: String {
        if manifest.runtime.effectiveAudioPolicy == .disabled {
            return "disabled"
        }
        return audioOutputEnabled ? "enabled" : "muted"
    }
    var selectedPlaybackRate: Float {
        if let playbackRateOverride = config.playbackRateOverride {
            return playbackRateOverride
        }
        switch config.foregroundMode {
        case .automatic:
            if assetCatalog.spineAsset != nil,
               RuntimeCapabilities.nativeSpineCompatibility(runtime: self).isSupported,
               let background = assetCatalog.videoAsset {
                return background.playbackRate
            }
            return assetCatalog.compositeVideoAsset?.playbackRate ?? assetCatalog.videoAsset?.playbackRate ?? 1.0
        case .compositeVideo:
            return assetCatalog.compositeVideoAsset?.playbackRate ?? assetCatalog.videoAsset?.playbackRate ?? 1.0
        case .nativeSpine:
            return assetCatalog.videoAsset?.playbackRate ?? assetCatalog.compositeVideoAsset?.playbackRate ?? 1.0
        }
    }

    init(config: EngineConfig) throws {
        self.config = config
        self.manifest = try ManifestLoader.load(url: config.manifestURL, bundleRoot: config.wallpaperRoot)
        self.assetCatalog = try AssetCatalog(manifest: manifest, bundleRoot: config.wallpaperRoot)
    }

    func validationSummary() -> String {
        let compositeQuality = compositeQualityReport()
        return """
        native runtime validation OK
        manifest: \(config.manifestURL.path)
        runtime: \(manifest.runtime.kind)
        targetFps: \(renderTargetFps)
        fpsMode: \(renderFpsModeText)
        fitMode: \(config.fitMode.rawValue)
        foregroundMode: \(config.foregroundMode.rawValue)
        maxFps: \(manifest.runtime.maxFps)
        fallbackFps: \(manifest.runtime.fallbackFps)
        nativeSpinePoseFps: \(nativeSpinePoseSampleFps(displayRefreshFps: nil))
        nativeSpineIdlePoseFps: \(nativeSpineIdlePoseSampleFps(displayRefreshFps: nil))
        audioPolicy: \(manifest.runtime.effectiveAudioPolicy.rawValue) (output=\(audioOutputSummary), userOptIn=\(config.audioEnabled))
        cpuBudget: target \(manifest.layerBudgets.primaryCpuTargetPercent)% downgrade \(manifest.layerBudgets.cpuDowngradePercent)% / \(manifest.layerBudgets.cpuDowngradeWindowSeconds)s
        rssBudget: target \(manifest.layerBudgets.rssTargetMb)MB hard \(manifest.layerBudgets.rssHardMb)MB
        layers: \(manifest.layers.map { "\($0.id):\($0.type.rawValue)" }.joined(separator: ", "))
        static image: \(assetCatalog.staticImageAssetURL?.path ?? "none")
        video: \(assetCatalog.videoAssetURL?.path ?? "none") @ \(assetCatalog.videoAsset?.playbackRate ?? 0)x
        composite video: \(assetCatalog.compositeVideoAssetURL?.path ?? "none") @ \(assetCatalog.compositeVideoAsset?.playbackRate ?? 0)x
        contentAspect: \(String(format: "%.4f", assetCatalog.contentAspect))
        composite quality: \(compositeQuality.summaryLine)
        native spine geometry: \(nativeSpineGeometryValidationStatus())
        spine json: \(assetCatalog.spineAsset?.json.path ?? "none")
        """
    }

    func performanceSummary() -> String {
        performancePlan.summary()
    }

    func performancePlan(displayRefreshFps: Int?) -> PerformancePlan {
        let requestedFps = requestedRenderFps(displayRefreshFps: displayRefreshFps)
        return PerformancePlan.make(
            manifest: manifest,
            requestedFps: requestedFps
        )
    }

    func renderTargetFps(displayRefreshFps: Int?) -> Int {
        performancePlan(displayRefreshFps: displayRefreshFps).effectiveTargetFps
    }

    func nativeSpinePoseSampleFps(displayRefreshFps: Int?) -> Int {
        let renderFps = renderTargetFps(displayRefreshFps: displayRefreshFps)
        let requestedPoseFps = manifest.runtime.nativeSpinePoseFps ?? renderFps
        return max(1, min(requestedPoseFps, renderFps, manifest.runtime.maxFps))
    }

    func nativeSpineIdlePoseSampleFps(displayRefreshFps: Int?) -> Int {
        let activePoseFps = nativeSpinePoseSampleFps(displayRefreshFps: displayRefreshFps)
        let requestedIdlePoseFps = manifest.runtime.nativeSpineIdlePoseFps ?? activePoseFps
        return max(1, min(requestedIdlePoseFps, activePoseFps, manifest.runtime.maxFps))
    }

    func idleRenderFps(
        displayRefreshFps: Int?,
        videoAsset: VideoAsset?,
        playsVideo: Bool,
        rendersNativeForeground: Bool
    ) -> Int {
        let targetFps = renderTargetFps(displayRefreshFps: displayRefreshFps)
        var cadenceCandidates: [Int] = []
        if playsVideo, let effectiveVideoFps = videoAsset?.effectiveFrameRate {
            cadenceCandidates.append(Int(ceil(effectiveVideoFps)))
        }
        if rendersNativeForeground, assetCatalog.spineAsset != nil {
            cadenceCandidates.append(nativeSpineIdlePoseSampleFps(displayRefreshFps: displayRefreshFps))
        }
        guard let requestedIdleFps = cadenceCandidates.max() else {
            return 1
        }
        return max(1, min(requestedIdleFps, targetFps, manifest.runtime.maxFps))
    }

    func activeRenderFps(
        displayRefreshFps: Int?,
        videoAsset: VideoAsset?,
        playsVideo: Bool,
        rendersNativeForeground: Bool
    ) -> Int {
        let targetFps = renderTargetFps(displayRefreshFps: displayRefreshFps)
        var cadenceCandidates: [Int] = []
        if playsVideo, let effectiveVideoFps = videoAsset?.effectiveFrameRate {
            cadenceCandidates.append(Int(ceil(effectiveVideoFps)))
        }
        if rendersNativeForeground, assetCatalog.spineAsset != nil {
            cadenceCandidates.append(nativeSpinePoseSampleFps(displayRefreshFps: displayRefreshFps))
        }
        guard let requestedActiveFps = cadenceCandidates.max() else {
            return targetFps
        }
        return max(1, min(requestedActiveFps, targetFps, manifest.runtime.maxFps))
    }

    private func requestedRenderFps(displayRefreshFps: Int?) -> Int {
        if config.matchDisplayRefresh {
            return max(displayRefreshFps ?? manifest.runtime.targetFps, 1)
        }
        return config.renderFps ?? manifest.runtime.targetFps
    }

    func runtimeCapabilitiesSummary() -> String {
        RuntimeCapabilities.summary(runtime: self)
    }

    func compositeQualityReport() -> CompositeFallbackQualityReport {
        CompositeFallbackQualityReport.make(runtime: self)
    }

    func requireCompositeQualityIfStrict() throws {
        guard config.strictCompositeQuality else { return }
        let report = compositeQualityReport()
        guard report.isAcceptable else {
            throw EngineError.asset(
                "strict composite quality failed: \(report.warnings.joined(separator: "; "))"
            )
        }
    }

    func requireNativeSpineGeometryIfSupported() throws {
        try SpineGeometryDiagnostics.requireRenderableSamples(runtime: self)
    }

    private func nativeSpineGeometryValidationStatus() -> String {
        SpineGeometryDiagnostics.validationStatus(runtime: self)
    }
}
