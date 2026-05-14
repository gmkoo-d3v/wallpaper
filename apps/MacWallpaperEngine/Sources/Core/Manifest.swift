import Foundation

struct WallpaperNativeManifest: Decodable {
    let schemaVersion: String
    let runtime: RuntimeConfig
    let displayPolicy: DisplayPolicy
    let thermalPolicy: ThermalPolicy
    let layerBudgets: LayerBudgets
    let interactionPolicy: InteractionPolicy?
    let assets: AssetManifest
    let layers: [LayerConfig]
    let interactions: [InteractionConfig]
    let validation: ValidationConfig
}

struct InteractionPolicy: Decodable {
    let mode: InteractionPolicyMode
    let blockApplicationWindows: Bool
    let blockDesktopItems: Bool
}

enum InteractionPolicyMode: String, Decodable {
    case desktopEmptyOnly = "desktop-empty-only"
    case always
    case disabled
}

struct RuntimeConfig: Decodable {
    let kind: String
    let targetFps: Int
    let maxFps: Int
    let fallbackFps: Int
    let performanceTiers: [PerformanceTier]?
    let scheduler: SchedulerConfig
}

struct PerformanceTier: Decodable {
    let id: String
    let targetFps: Int
    let requiresDisplayRefreshHz: Int?
    let optIn: Bool?
    let requiresStableStandardTier: Bool?
    let `default`: Bool?
}

struct SchedulerConfig: Decodable {
    let maxInFlightCommandBuffers: Int
    let lateFramePolicy: String
    let catchUp: Bool
}

struct DisplayPolicy: Decodable {
    let primary: DisplayRolePolicy
    let secondary: DisplayRolePolicy
    let fullscreenObscured: DisplayRolePolicy
    let occluded: DisplayRolePolicy
}

enum DisplayRolePolicy: String, Decodable {
    case full
    case videoOnly = "video-only"
    case `static`
    case pause
}

struct ThermalPolicy: Decodable {
    let nominal: String
    let serious: String
    let critical: String
}

struct LayerBudgets: Decodable {
    let maxTexturePages: Int
    let maxTextureDimension: Int
    let rssTargetMb: Int
    let rssHardMb: Int
    let primaryCpuTargetPercent: Double
    let cpuDowngradePercent: Double
    let cpuDowngradeWindowSeconds: Int
}

struct AssetManifest: Decodable {
    let video: VideoAssetConfig?
    let compositeVideo: VideoAssetConfig?
    let spine: SpineAssetConfig?
}

struct VideoAssetConfig: Decodable {
    let id: String
    let path: String
    let playbackRate: Float?
}

struct SpineAssetConfig: Decodable {
    let id: String
    let version: String
    let json: String
    let atlas: String
    let textures: [String]
    let premultipliedAlpha: Bool
    let placement: SpinePlacementConfig?
}

struct SpinePlacementConfig: Decodable {
    let mode: String?
    let pixelsPerUnit: Double?
    let cameraPosition: [Double]?
    let objectPosition: [Double]?
    let objectScale: [Double]?
    let orthographicSize: Double?
    let designAspect: Double?
    let clipScale: Double?
    let clipOffset: [Double]?
}

struct LayerConfig: Decodable {
    let id: String
    let type: LayerType
    let asset: String
    let renderingMode: String?
}

enum LayerType: String, Decodable {
    case video
    case spine
}

struct InteractionConfig: Decodable {
    let event: InteractionEvent
    let mapping: String?
    let actions: [String: String]?
    let hitZones: [HitZone]?
}

enum InteractionEvent: String, Decodable {
    case pointerMove
    case pointerDown
}

struct HitZone: Decodable {
    let id: String
    let rect: [Double]
    let action: String
}

struct ValidationConfig: Decodable {
    let bundleRootOnly: Bool
    let requirePremultipliedAlpha: Bool
    let requireSpineVersion: String
    let rejectUnknownLayerTypes: Bool
}
