import Foundation

final class NativeRuntimeCore {
    let config: EngineConfig
    let manifest: WallpaperNativeManifest
    let assetCatalog: AssetCatalog
    var renderTargetFps: Int { config.renderFps ?? manifest.runtime.targetFps }
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
        layers: \(manifest.layers.map { "\($0.id):\($0.type.rawValue)" }.joined(separator: ", "))
        video: \(assetCatalog.videoAssetURL?.path ?? "none") @ \(assetCatalog.videoAsset?.playbackRate ?? 0)x
        composite video: \(assetCatalog.compositeVideoAssetURL?.path ?? "none") @ \(assetCatalog.compositeVideoAsset?.playbackRate ?? 0)x
        spine json: \(assetCatalog.spineAsset?.json.path ?? "none")
        """
    }
}
