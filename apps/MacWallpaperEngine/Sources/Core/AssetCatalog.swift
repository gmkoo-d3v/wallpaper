import Foundation

struct SpineAsset {
    let json: URL
    let atlas: URL
    let textures: [URL]
    let premultipliedAlpha: Bool
    let placement: SpinePlacement
}

struct VideoAsset {
    let url: URL
    let playbackRate: Float
}

struct StaticImageAsset {
    let url: URL
}

struct SpinePlacement {
    let mode: String
    let pixelsPerUnit: Double
    let cameraX: Double
    let cameraY: Double
    let objectX: Double
    let objectY: Double
    let objectScaleX: Double
    let objectScaleY: Double
    let orthographicSize: Double
    let designAspect: Double
    let clipScale: Double
    let clipOffsetX: Double
    let clipOffsetY: Double

    static func make(_ config: SpinePlacementConfig?) -> SpinePlacement {
        let cameraPosition = config?.cameraPosition ?? []
        let objectPosition = config?.objectPosition ?? []
        let objectScale = config?.objectScale ?? []
        let clipOffset = config?.clipOffset ?? []

        return SpinePlacement(
            mode: config?.mode ?? "skeleton-bounds",
            pixelsPerUnit: max(config?.pixelsPerUnit ?? 100, 0.0001),
            cameraX: cameraPosition.count > 0 ? cameraPosition[0] : 0,
            cameraY: cameraPosition.count > 1 ? cameraPosition[1] : 0,
            objectX: objectPosition.count > 0 ? objectPosition[0] : 0,
            objectY: objectPosition.count > 1 ? objectPosition[1] : 0,
            objectScaleX: objectScale.count > 0 ? objectScale[0] : 1,
            objectScaleY: objectScale.count > 1 ? objectScale[1] : 1,
            orthographicSize: max(config?.orthographicSize ?? 1, 0.0001),
            designAspect: max(config?.designAspect ?? (16.0 / 9.0), 0.0001),
            clipScale: max(config?.clipScale ?? 1, 0.0001),
            clipOffsetX: clipOffset.count > 0 ? clipOffset[0] : 0,
            clipOffsetY: clipOffset.count > 1 ? clipOffset[1] : 0
        )
    }
}

final class AssetCatalog {
    let staticImageAsset: StaticImageAsset?
    let videoAsset: VideoAsset?
    let compositeVideoAsset: VideoAsset?
    var staticImageAssetURL: URL? { staticImageAsset?.url }
    var videoAssetURL: URL? { videoAsset?.url }
    var compositeVideoAssetURL: URL? { compositeVideoAsset?.url }
    let spineAsset: SpineAsset?

    init(manifest: WallpaperNativeManifest, bundleRoot: URL) throws {
        let root = bundleRoot.standardizedFileURL
        self.staticImageAsset = Self.makeStaticImageAsset(manifest.assets.staticImage, root: root)
        self.videoAsset = Self.makeVideoAsset(manifest.assets.video, root: root)
        self.compositeVideoAsset = Self.makeVideoAsset(manifest.assets.compositeVideo, root: root)

        if let spine = manifest.assets.spine {
            self.spineAsset = SpineAsset(
                json: root.appendingPathComponent(spine.json).standardizedFileURL,
                atlas: root.appendingPathComponent(spine.atlas).standardizedFileURL,
                textures: spine.textures.map { root.appendingPathComponent($0).standardizedFileURL },
                premultipliedAlpha: spine.premultipliedAlpha,
                placement: SpinePlacement.make(spine.placement)
            )
        } else {
            self.spineAsset = nil
        }
    }

    private static func makeStaticImageAsset(_ config: StaticImageAssetConfig?, root: URL) -> StaticImageAsset? {
        guard let config else { return nil }
        return StaticImageAsset(url: root.appendingPathComponent(config.path).standardizedFileURL)
    }

    private static func makeVideoAsset(_ config: VideoAssetConfig?, root: URL) -> VideoAsset? {
        guard let config else { return nil }
        return VideoAsset(
            url: root.appendingPathComponent(config.path).standardizedFileURL,
            playbackRate: config.playbackRate ?? 1.0
        )
    }
}
