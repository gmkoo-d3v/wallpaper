import Foundation

struct WallpaperNativeManifest: Decodable {
    let schemaVersion: String
    let metadata: WallpaperMetadata?
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

struct WallpaperMetadata: Decodable {
    let id: String?
    let title: String?
    let author: String?
    let version: String?
    let description: String?
}

struct InteractionPolicy: Decodable {
    let mode: InteractionPolicyMode
    let blockApplicationWindows: Bool
    let blockDesktopItems: Bool
    let pointerSmoothing: Double?
    let pointerSampleFps: Double?
    let idleDeadZone: Double?
    let directionSwitchMargin: Double?
    let defaultClickTailSeconds: Double?
    let releaseFadeSeconds: Double?
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
    let audioPolicy: AudioPolicy?
    let performanceTiers: [PerformanceTier]?
    let scheduler: SchedulerConfig

    var effectiveAudioPolicy: AudioPolicy {
        audioPolicy ?? .muted
    }
}

enum AudioPolicy: String, Decodable {
    case muted
    case userControlled
    case disabled

    var runtimeOutputSummary: String {
        switch self {
        case .muted:
            return "muted"
        case .userControlled:
            return "muted-until-user-opt-in"
        case .disabled:
            return "disabled-muted"
        }
    }
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
    let staticImage: StaticImageAssetConfig?
    let video: VideoAssetConfig?
    let compositeVideo: VideoAssetConfig?
    let spine: SpineAssetConfig?
}

struct StaticImageAssetConfig: Decodable {
    let id: String
    let path: String
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
    case staticImage = "static_image"
    case video
    case spine
}

struct InteractionConfig: Decodable {
    let event: InteractionEvent
    let mapping: String?
    let actions: [String: String]?
    let neutralPoint: InteractionPoint?
    let deadZone: InteractionPoint?
    let hitZones: [HitZone]?
    let defaultAction: PointerDownDefaultAction?
    let buttons: [PointerButton]?
}

enum InteractionEvent: String, Decodable {
    case pointerMove
    case pointerDown
}

enum PointerButton: String, Decodable {
    case left
    case right
}

enum HitZoneTrigger: String, Decodable {
    case tap
    case hold
}

struct InteractionPoint: Decodable {
    let x: Double
    let y: Double
}

struct HitZone: Decodable {
    let id: String
    let rect: [Double]
    let action: String
    let tapAction: String?
    let trigger: HitZoneTrigger?
    let tailSeconds: Double?
    let tapTailSeconds: Double?
    let holdStartSeconds: Double?
    let buttons: [PointerButton]?
    let priority: Int?
}

struct PointerDownDefaultAction: Decodable {
    let action: String
    let trigger: HitZoneTrigger?
    let tailSeconds: Double?
    let buttons: [PointerButton]?
}

struct ValidationConfig: Decodable {
    let bundleRootOnly: Bool
    let requirePremultipliedAlpha: Bool
    let requireSpineVersion: String
    let rejectUnknownLayerTypes: Bool
}
