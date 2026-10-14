import Foundation

struct WallpaperNativeManifest: Decodable {
    let schemaVersion: String
    let metadata: WallpaperMetadata?
    let sourceProvenance: SourceProvenance?
    let runtime: RuntimeConfig
    let displayPolicy: DisplayPolicy
    let thermalPolicy: ThermalPolicy
    let layerBudgets: LayerBudgets
    let interactionPolicy: InteractionPolicy?
    let assets: AssetManifest
    let layers: [LayerConfig]
    let interactions: [InteractionConfig]
    let bindings: [DeclarativeBinding]?
    let effects: [EffectConfig]?
    let validation: ValidationConfig
}

struct WallpaperMetadata: Decodable {
    let id: String?
    let title: String?
    let author: String?
    let version: String?
    let description: String?
}

struct SourceProvenance: Decodable {
    let sourceType: SourceProvenanceType
    let sourceRuntime: String?
    let projectType: String?
    let sourceDescriptors: [SourceDescriptor]?
    let sourceAdapter: SourceAdapterContract?
    let importedFields: [String]?
    let calibratedFields: [String]?
    let platformPolicyFields: [String]?
    let unsupportedFields: [String]?
    let notes: [String]?
}

struct SourceAdapterContract: Decodable {
    let id: String
    let version: String?
    let kind: String
    let fieldDerivations: [SourceAdapterFieldDerivation]?
    let capabilities: [String]?
    let limitations: [String]?
}

struct SourceAdapterFieldDerivation: Decodable {
    let field: String
    let mode: SourceAdapterFieldMode
    let source: String?
    let owner: String?
    let requiredCapability: String?
    let reason: String?
}

enum SourceAdapterFieldMode: String, Decodable, Hashable {
    case imported
    case calibrated
    case platformPolicy = "platform-policy"
    case unsupported
}

struct SourceDescriptor: Decodable {
    let kind: SourceDescriptorKind
    let path: String
}

enum SourceDescriptorKind: String, Decodable {
    case wallpaperEngineProjectJSON = "wallpaper-engine-project-json"
    case unityAssetExtractionManifest = "unity-asset-extraction-manifest"
    case unityManagedScriptIndex = "unity-managed-script-index"
}

enum SourceProvenanceType: String, Decodable {
    case wallpaperEngineApplication = "wallpaper-engine-application"
    case wallpaperEngineVideo = "wallpaper-engine-video"
    case wallpaperEngineScene = "wallpaper-engine-scene"
    case wallpaperEngineWeb = "wallpaper-engine-web"
    case native
    case sample
    case unknown
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
    let idleRenderFps: Int?
    let nativeSpinePoseFps: Int?
    let nativeSpineIdlePoseFps: Int?
    let nativeSpineTransitionSeconds: Double?
    let nativeSpineTransitionPolicy: NativeSpineTransitionPolicyConfig?
    let physicsIdlePolicy: PhysicsIdlePolicy?
    let audioPolicy: AudioPolicy?
    let performanceTiers: [PerformanceTier]?
    let scheduler: SchedulerConfig

    var effectiveAudioPolicy: AudioPolicy {
        audioPolicy ?? .muted
    }

    var effectivePhysicsIdlePolicy: PhysicsIdlePolicy {
        physicsIdlePolicy ?? .dynamic
    }
}

struct NativeSpineTransitionPolicyConfig: Decodable {
    let defaultSeconds: Double?
    let lookSeconds: Double?
    let actionSeconds: Double?
    let releaseSeconds: Double?
}

enum PhysicsIdlePolicy: String, Decodable {
    case dynamic
    case sleepWhenIdle = "sleep-when-idle"
}

enum AudioPolicy: String, Decodable {
    case muted
    case userControlled
    case disabled
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
    let foregroundOcclusion: LayerForegroundOcclusionConfig?
}

enum LayerType: String, Decodable {
    case staticImage = "static_image"
    case video
    case spine
}

struct LayerForegroundOcclusionConfig: Decodable {
    let enabled: Bool?
    let sourceRect: [Double]
    let destinationRect: [Double]
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
    let gaze: PointerMoveGazeConfig?
}

struct PointerMoveGazeConfig: Decodable {
    let sensitivity: Double?
    let returnSpeed: Double?
}

enum InteractionEvent: String, Decodable {
    case pointerMove
    case pointerDown
}

enum PointerButton: String, Decodable, Hashable {
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
    let rect: [Double]?
    let ellipse: HitZoneEllipse?
    let action: String
    let tapAction: String?
    let holdAction: String?
    let rubAction: String?
    let trigger: HitZoneTrigger?
    let tailSeconds: Double?
    let tapTailSeconds: Double?
    let rubTailSeconds: Double?
    let holdStartSeconds: Double?
    let holdCommitSeconds: Double?
    let rubStartSeconds: Double?
    let rubStartDistance: Double?
    let buttons: [PointerButton]?
    let priority: Int?
}

struct HitZoneEllipse: Decodable {
    let center: InteractionPoint
    let radiusX: Double
    let radiusY: Double
}

struct PointerDownDefaultAction: Decodable {
    let action: String
    let trigger: HitZoneTrigger?
    let tailSeconds: Double?
    let buttons: [PointerButton]?
}

struct DeclarativeBinding: Decodable {
    let id: String
    let source: BindingSource
    let target: String
    let adapter: BindingAdapter
    let enabled: Bool?
}

enum BindingSource: String, Decodable {
    case pointerPosition = "pointer.position"
    case pointerX = "pointer.x"
    case pointerY = "pointer.y"
    case pointerDown = "pointer.down"
    case pointerSpeed = "pointer.speed"
    case pointerPressDuration = "pointer.pressDuration"
    case pointerDragDistance = "pointer.dragDistance"
    case systemTime = "system.time"
    case thermalState = "thermal.state"
}

struct BindingAdapter: Decodable {
    let type: BindingAdapterType
    let neutralPoint: InteractionPoint?
    let deadZone: InteractionPoint?
    let interpolation: BindingInterpolation?
    let factor: [Double]?
    let inputRange: [Double]?
    let outputRange: [Double]?
    let loop: Bool?
    let integrator: BindingSpringIntegrator?
    let stiffness: Double?
    let damping: Double?
    let mass: Double?
    let settleEpsilon: Double?
    let maxVelocity: Double?
    let fixedStepSeconds: Double?

    init(
        type: BindingAdapterType,
        neutralPoint: InteractionPoint?,
        deadZone: InteractionPoint?,
        interpolation: BindingInterpolation?,
        factor: [Double]?,
        inputRange: [Double]?,
        outputRange: [Double]?,
        loop: Bool?,
        integrator: BindingSpringIntegrator? = nil,
        stiffness: Double? = nil,
        damping: Double? = nil,
        mass: Double? = nil,
        settleEpsilon: Double? = nil,
        maxVelocity: Double? = nil,
        fixedStepSeconds: Double? = nil
    ) {
        self.type = type
        self.neutralPoint = neutralPoint
        self.deadZone = deadZone
        self.interpolation = interpolation
        self.factor = factor
        self.inputRange = inputRange
        self.outputRange = outputRange
        self.loop = loop
        self.integrator = integrator
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
        self.settleEpsilon = settleEpsilon
        self.maxVelocity = maxVelocity
        self.fixedStepSeconds = fixedStepSeconds
    }
}

enum BindingAdapterType: String, Decodable {
    case smoothLookAt = "smooth-lookat"
    case triggerPlay = "trigger-play"
    case mapRange = "map-range"
    case spring
}

enum BindingInterpolation: String, Decodable {
    case linear
    case smoothStep = "smooth-step"
    case spring
}

enum BindingSpringIntegrator: String, Decodable {
    case semiImplicitEuler = "semi-implicit-euler"
}

struct EffectConfig: Decodable {
    let id: String
    let type: EffectType
    let budget: EffectBudgetConfig?
    let fallback: EffectFallbackConfig?
    let properties: [String: EffectPropertyValue]?

    init(
        id: String,
        type: EffectType,
        budget: EffectBudgetConfig? = nil,
        fallback: EffectFallbackConfig? = nil,
        properties: [String: EffectPropertyValue]?
    ) {
        self.id = id
        self.type = type
        self.budget = budget
        self.fallback = fallback
        self.properties = properties
    }
}

enum EffectType: String, Decodable {
    case blur
    case colorMatrix
    case scroll
    case chromaticAberration
    case vignette
    case pixelate
}

struct EffectBudgetConfig: Decodable {
    let costClass: EffectBudgetCostClass
    let maxPasses: Int?
    let maxAnimatedProperties: Int?
}

enum EffectBudgetCostClass: String, Decodable {
    case free
    case low
    case medium
    case high
}

struct EffectFallbackConfig: Decodable {
    let policy: EffectFallbackPolicy
    let reason: String?
}

enum EffectFallbackPolicy: String, Decodable {
    case disable
    case staticValue = "static-value"
    case reduceQuality = "reduce-quality"
}

enum EffectPropertyValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case stringArray([String])
    case numberArray([Double])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let number = try? container.decode(Double.self) {
            self = .number(number)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let numbers = try? container.decode([Double].self) {
            self = .numberArray(numbers)
            return
        }
        if let strings = try? container.decode([String].self) {
            self = .stringArray(strings)
            return
        }
        throw DecodingError.typeMismatch(
            EffectPropertyValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Effect property values must be string, number, bool, string array, or number array"
            )
        )
    }
}

struct ValidationConfig: Decodable {
    let bundleRootOnly: Bool
    let requirePremultipliedAlpha: Bool
    let requireSpineVersion: String
    let rejectUnknownLayerTypes: Bool
}
