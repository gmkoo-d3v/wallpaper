import Foundation

final class NativeRuntimeCore {
    let config: EngineConfig
    let manifest: WallpaperNativeManifest
    let assetCatalog: AssetCatalog
    let telemetry = RuntimeTelemetryStore()
    var performancePlan: PerformancePlan {
        PerformancePlan.make(manifest: manifest, requestedFps: config.renderFps ?? manifest.runtime.targetFps)
    }
    var renderTargetFps: Int { performancePlan.effectiveTargetFps }
    var selectedPlaybackRate: Float {
        if let playbackRateOverride = config.playbackRateOverride {
            return playbackRateOverride
        }
        switch config.foregroundMode {
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
        """
        native runtime validation OK
        manifest: \(config.manifestURL.path)
        runtime: \(manifest.runtime.kind)
        targetFps: \(renderTargetFps)
        fitMode: \(config.fitMode.rawValue)
        foregroundMode: \(config.foregroundMode.rawValue)
        maxFps: \(manifest.runtime.maxFps)
        fallbackFps: \(manifest.runtime.fallbackFps)
        cpuBudget: target \(manifest.layerBudgets.primaryCpuTargetPercent)% downgrade \(manifest.layerBudgets.cpuDowngradePercent)% / \(manifest.layerBudgets.cpuDowngradeWindowSeconds)s
        rssBudget: target \(manifest.layerBudgets.rssTargetMb)MB hard \(manifest.layerBudgets.rssHardMb)MB
        layers: \(manifest.layers.map { "\($0.id):\($0.type.rawValue)" }.joined(separator: ", "))
        static image: \(assetCatalog.staticImageAssetURL?.path ?? "none")
        video: \(assetCatalog.videoAssetURL?.path ?? "none") @ \(assetCatalog.videoAsset?.playbackRate ?? 0)x
        composite video: \(assetCatalog.compositeVideoAssetURL?.path ?? "none") @ \(assetCatalog.compositeVideoAsset?.playbackRate ?? 0)x
        spine json: \(assetCatalog.spineAsset?.json.path ?? "none")
        """
    }

    func performanceSummary() -> String {
        performancePlan.summary()
    }

    func runtimeCapabilitiesSummary() -> String {
        RuntimeCapabilities.summary(runtime: self)
    }
}
