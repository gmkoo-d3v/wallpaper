import CoreGraphics
import Foundation
import Metal
import MetalKit

final class SpineSetupPoseRenderer {
    private struct AtlasPage {
        let name: String
        let size: CGSize
        let texture: MTLTexture
    }

    private struct AtlasRegion {
        let name: String
        let pageName: String
        let bounds: CGRect
        let offset: CGPoint
        let originalSize: CGSize
        let rotated: Bool
    }

    private struct Bone {
        let name: String
        let parentIndex: Int?
        let inherit: String
        var x: Double
        var y: Double
        var rotation: Double
        var scaleX: Double
        var scaleY: Double
        var shearX: Double
        var shearY: Double
        var length: Double
    }

    private struct BoneWorld {
        let a: Double
        let b: Double
        let c: Double
        let d: Double
        let tx: Double
        let ty: Double

        func transform(x: Double, y: Double) -> CGPoint {
            CGPoint(
                x: x * a + y * c + tx,
                y: x * b + y * d + ty
            )
        }
    }

    private struct IkPoseConstraint {
        let order: Int
        let boneIndices: [Int]
        let targetIndex: Int
        let bendDirection: Double
        let compress: Bool
        let stretch: Bool
        let uniform: Bool
        let mix: Double
        let softness: Double
    }

    private struct TransformPoseConstraint {
        let order: Int
        let boneIndices: [Int]
        let targetIndex: Int
        let offsetRotation: Double
        let offsetX: Double
        let offsetY: Double
        let offsetScaleX: Double
        let offsetScaleY: Double
        let offsetShearY: Double
        let local: Bool
        let relative: Bool
        let mixRotate: Double
        let mixX: Double
        let mixY: Double
        let mixScaleX: Double
        let mixScaleY: Double
        let mixShearY: Double
    }

    private struct PathPoseConstraint {
        let order: Int
        let boneIndices: [Int]
        let targetSlotName: String
        let positionMode: String
        let spacingMode: String
        let rotateMode: String
        let offsetRotation: Double
        let position: Double
        let spacing: Double
        let mixRotate: Double
        let mixX: Double
        let mixY: Double
    }

    private struct PhysicsPoseConstraint {
        let name: String
        let order: Int
        let boneIndex: Int
        let x: Double
        let y: Double
        let rotate: Double
        let scaleX: Double
        let shearX: Double
        let limit: Double
        let step: Double
        let inertia: Double
        let strength: Double
        let damping: Double
        let massInverse: Double
        let wind: Double
        let gravity: Double
        let mix: Double
    }

    private enum PoseConstraint {
        case ik(IkPoseConstraint)
        case transform(TransformPoseConstraint)
        case path(PathPoseConstraint)
        case physics(PhysicsPoseConstraint)

        var order: Int {
            switch self {
            case .ik(let constraint):
                constraint.order
            case .transform(let constraint):
                constraint.order
            case .path(let constraint):
                constraint.order
            case .physics(let constraint):
                constraint.order
            }
        }
    }

    private struct BonePoseState {
        let parentIndex: Int?
        let inherit: String
        let length: Double
        var x: Double
        var y: Double
        var rotation: Double
        var scaleX: Double
        var scaleY: Double
        var shearX: Double
        var shearY: Double
        var a: Double = 1
        var b: Double = 0
        var c: Double = 0
        var d: Double = 1
        var tx: Double = 0
        var ty: Double = 0

        var world: BoneWorld {
            BoneWorld(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
        }
    }

    private struct Slot {
        let name: String
        let boneName: String?
        var attachment: String?
        var color: SIMD4<Float>
        let darkColor: SIMD4<Float>
        let blendMode: RenderBlendMode
    }

    private struct TimelineFrame {
        let time: Double
        let x: Double
        let y: Double
        let value: Double
        let color: SIMD4<Float>?
        let attachment: String?
        let stepped: Bool
        let curve: [Double]?
    }

    private struct DeformFrame {
        let time: Double
        let offset: Int
        let vertices: [Double]?
        let stepped: Bool
        let curve: [Double]?
    }

    private struct DrawOrderOffset {
        let slotName: String
        let offset: Int
    }

    private struct DrawOrderFrame {
        let time: Double
        let offsets: [DrawOrderOffset]?
    }

    private struct SequenceFrame {
        let time: Double
        let index: Int
        let mode: String
        let delay: Double
    }

    private struct SequenceInfo {
        let count: Int
        let start: Int
        let digits: Int
        let setupIndex: Int
        let pathSuffix: Bool
    }

    private struct EventFrame {
        let time: Double
        let name: String
    }

    private struct SkinAttachmentSource {
        let name: String
        let attachments: [String: Any]
    }

    private struct BoneTimelines {
        var rotate: [TimelineFrame] = []
        var translate: [TimelineFrame] = []
        var translateX: [TimelineFrame] = []
        var translateY: [TimelineFrame] = []
        var scale: [TimelineFrame] = []
        var shear: [TimelineFrame] = []

        var frameTimes: [Double] {
            [rotate, translate, translateX, translateY, scale, shear]
                .flatMap { $0 }
                .map(\.time)
        }

        var maxTime: Double {
            frameTimes.max() ?? 0
        }
    }

    private struct SlotTimelines {
        var rgba: [TimelineFrame] = []
        var rgb: [TimelineFrame] = []
        var alpha: [TimelineFrame] = []
        var attachment: [TimelineFrame] = []

        var frameTimes: [Double] {
            [rgba, rgb, alpha, attachment]
                .flatMap { $0 }
                .map(\.time)
        }

        var discreteTransitionTimes: [Double] {
            attachment.map(\.time)
        }

        var maxTime: Double {
            frameTimes.max() ?? 0
        }
    }

    private struct AttachmentTimelines {
        var deform: [DeformFrame] = []
        var sequence: [SequenceFrame] = []

        var maxTime: Double {
            max(
                deform.map(\.time).max() ?? 0,
                sequence.map(\.time).max() ?? 0
            )
        }
    }

    private struct SpineAnimation {
        let name: String
        let duration: Double
        let boneTimelines: [String: BoneTimelines]
        let slotTimelines: [String: SlotTimelines]
        let attachmentTimelines: [String: [String: AttachmentTimelines]]
        let drawOrder: [DrawOrderFrame]
        let eventFrames: [EventFrame]

        func timelineFrameTimes() -> [Double] {
            var times = boneTimelines.values.flatMap(\.frameTimes)
            times.append(contentsOf: slotTimelines.values.flatMap(\.frameTimes))
            times.append(contentsOf: attachmentTimelines.values.flatMap { slotTimelines in
                slotTimelines.values.flatMap { timelines in
                    timelines.deform.map(\.time) + timelines.sequence.map(\.time)
                }
            })
            times.append(contentsOf: drawOrder.map(\.time))
            times.append(contentsOf: eventFrames.map(\.time))
            return times
        }

        func discreteTransitionTimes() -> [Double] {
            var times = slotTimelines.values.flatMap(\.discreteTransitionTimes)
            times.append(contentsOf: attachmentTimelines.values.flatMap { slotTimelines in
                slotTimelines.values.flatMap { $0.sequence.map(\.time) }
            })
            times.append(contentsOf: drawOrder.map(\.time))
            return times
        }
    }

    private struct Attachment {
        let name: String
        let slotName: String
        let uvs: [Double]
        let triangles: [Int]
        let vertices: [Double]
        let sequence: SequenceInfo?
    }

    private struct PathAttachment {
        let name: String
        let slotName: String
        let vertexCount: Int
        let vertices: [Double]
        let lengths: [Double]
        let closed: Bool
        let constantSpeed: Bool
    }

    private struct ClippingAttachment {
        let name: String
        let slotName: String
        let endSlotName: String
        let vertexCount: Int
        let vertices: [Double]
    }

    private struct PathCurve {
        let x1: Double
        let y1: Double
        let cx1: Double
        let cy1: Double
        let cx2: Double
        let cy2: Double
        let x2: Double
        let y2: Double
        let cumulativeLength: Double
        let samples: [Double]
    }

    private struct PhysicsRuntimeState {
        var needsReset = true
        var remaining = 0.0
        var lastTime = 0.0
        var ux = 0.0
        var uy = 0.0
        var cx = 0.0
        var cy = 0.0
        var tx = 0.0
        var ty = 0.0
        var xOffset = 0.0
        var xVelocity = 0.0
        var yOffset = 0.0
        var yVelocity = 0.0
        var rotateOffset = 0.0
        var rotateVelocity = 0.0
        var scaleOffset = 0.0
        var scaleVelocity = 0.0
    }

    private struct VertexBatch {
        let texture: MTLTexture
        let blendMode: RenderBlendMode
        let vertices: [RenderVertex]
    }

    private struct Batch {
        let texture: MTLTexture
        let blendMode: RenderBlendMode
        let vertexBuffer: MTLBuffer
        let vertexCount: Int
        let capacity: Int
    }

    private struct PoseFrameCacheEntry {
        let key: String
        let vertexBatches: [VertexBatch]
        let byteCount: Int
    }

    struct GeometrySample {
        let actionName: String
        let time: Double
        let status: String
        let batchCount: Int
        let vertexCount: Int
        let blendModes: String
        let uvStatus: String
        let bounds: String
        let fingerprint: String
        let error: String
    }

    struct PoseCacheStats {
        let exactHits: Int
        let frameHits: Int
        let misses: Int
        let stores: Int
        let entries: Int
        let bytes: Int
    }

    struct PoseCacheProbe {
        let firstBuildMs: Double
        let exactHitMs: Double
        let frameHitMs: Double
        let stats: PoseCacheStats
    }

    private let device: MTLDevice
    private let atlas: (pages: [String: AtlasPage], regions: [String: AtlasRegion])
    private let bones: [Bone]
    private let boneIndexByName: [String: Int]
    private let slots: [Slot]
    private let slotIndexByName: [String: Int]
    private let slotSetupByName: [String: Slot]
    private let attachments: [String: [String: Attachment]]
    private let pathAttachments: [String: [String: PathAttachment]]
    private let clippingAttachments: [String: [String: ClippingAttachment]]
    private let animations: [String: SpineAnimation]
    private let poseConstraints: [PoseConstraint]
    private let skeletonBounds: CGRect
    private let placement: SpinePlacement
    private let referenceScale: Double
    private let playbackRate: Double
    private let poseSampleFps: Double
    private let idlePoseSampleFps: Double
    private let lookAnimationNames: Set<String>
    private let lookNeutralPoint: CGPoint
    private let lookDeadZone: CGPoint
    private let physicsIdlePolicy: PhysicsIdlePolicy
    private let loopingAnimationNames: Set<String>
    private let oneShotAnimationNames: Set<String>
    private let declarativePlan: DeclarativeBindingPlan
    private let physicsConstraintsEnabled: Bool
    private let rendererStartedAt: CFTimeInterval
    private let animationTransitionDuration: CFTimeInterval
    private var physicsStates: [String: PhysicsRuntimeState] = [:]
    private var cachedBatches: [Batch]
    private var cachedPoseKey = ""
    private var poseFrameCache: [PoseFrameCacheEntry] = []
    private var poseFrameCacheBytes = 0
    private var poseCacheExactHits = 0
    private var poseCacheFrameHits = 0
    private var poseCacheMisses = 0
    private var poseCacheStores = 0
    private var physicsIdleSleeping = false
    private let idleAnimationName: String
    private var activeAnimationName: String
    private var activeAnimationStartedAt: CFTimeInterval = CACurrentMediaTime()
    private var previousOverlayAnimationName: String?
    private var previousOverlayAnimationStartedAt: CFTimeInterval = CACurrentMediaTime()
    let batchCount: Int
    let triangleVertexCount: Int
    private static let enablePathConstraints = true
    private static let enablePhysicsConstraints = true
    private static let maxPoseFrameCacheEntries = 96
    private static let maxPoseFrameCacheBytes = 32 * 1024 * 1024
    static let maxGeometryDiagnosticSamplesPerAction = 96
    static let timelineSamplingPolicy = "parse-sorted/no-per-sample-sort"

    init(
        spineAsset: SpineAsset,
        device: MTLDevice,
        playbackRate: Float = 1.0,
        poseSampleFps: Int = 60,
        idlePoseSampleFps: Int? = nil,
        lookAnimationNames: Set<String> = [],
        lookNeutralPoint: CGPoint = CGPoint(x: 0.5, y: 0.5),
        lookDeadZone: CGPoint? = nil,
        lookIdleDeadZone: Double = 0.18,
        physicsIdlePolicy: PhysicsIdlePolicy = .dynamic,
        idleAnimationName: String = "idle",
        loopingAnimationNames: Set<String> = ["idle"],
        oneShotAnimationNames: Set<String> = [],
        animationTransitionSeconds: Double = 0.30,
        declarativePlan: DeclarativeBindingPlan = DeclarativeBindingPlan(bindings: [], effects: [])
    ) throws {
        let textureLoader = MTKTextureLoader(device: device)
        let atlas = try Self.parseAtlas(url: spineAsset.atlas, textureLoader: textureLoader)
        let jsonData = try Data(contentsOf: spineAsset.json)
        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw EngineError.asset("Spine JSON root is not an object")
        }

        let skeleton = root["skeleton"] as? [String: Any] ?? [:]
        let bounds = CGRect(
            x: skeleton["x"] as? Double ?? 0,
            y: skeleton["y"] as? Double ?? 0,
            width: skeleton["width"] as? Double ?? 1,
            height: skeleton["height"] as? Double ?? 1
        )
        let referenceScale = Self.number(skeleton["referenceScale"], default: 100)
        self.skeletonBounds = bounds
        self.placement = spineAsset.placement

        let bones = try Self.parseBones(root: root)
        let boneIndexByName = Dictionary(uniqueKeysWithValues: bones.enumerated().map { ($0.element.name, $0.offset) })
        let slots = try Self.parseSlots(root: root)
        let slotIndexByName = Dictionary(uniqueKeysWithValues: slots.enumerated().map { ($0.element.name, $0.offset) })
        let slotSetupByName = Dictionary(uniqueKeysWithValues: slots.map { ($0.name, $0) })
        let poseConstraints = try Self.parsePoseConstraints(root: root, boneIndexByName: boneIndexByName)
        let attachments = try Self.parseAttachments(root: root)
        let pathAttachments = try Self.parsePathAttachments(root: root)
        let clippingAttachments = try Self.parseClippingAttachments(root: root)
        let animations = try Self.parseAnimations(root: root)
        let boneWorld = Self.computeBoneWorld(
            bones,
            constraints: poseConstraints,
            slots: slots,
            pathAttachments: pathAttachments,
            boneIndexByName: boneIndexByName
        )

        let builtBatches = try Self.buildBatches(
            slots: slots,
            attachments: attachments,
            clippingAttachments: clippingAttachments,
            bones: boneWorld,
            boneIndexByName: boneIndexByName,
            atlas: atlas,
            skeletonBounds: bounds,
            placement: spineAsset.placement,
            device: device
        )
        self.device = device
        self.atlas = atlas
        self.bones = bones
        self.boneIndexByName = boneIndexByName
        self.slots = slots
        self.slotIndexByName = slotIndexByName
        self.slotSetupByName = slotSetupByName
        self.attachments = attachments
        self.pathAttachments = pathAttachments
        self.clippingAttachments = clippingAttachments
        self.animations = animations
        self.poseConstraints = poseConstraints
        self.physicsConstraintsEnabled = Self.enablePhysicsConstraints && poseConstraints.contains { constraint in
            if case .physics = constraint {
                return true
            }
            return false
        }
        self.playbackRate = max(0.01, Double(playbackRate))
        let resolvedIdleAnimationName = animations[idleAnimationName] == nil ? "idle" : idleAnimationName
        guard animations[resolvedIdleAnimationName] != nil else {
            throw EngineError.renderer("Missing Spine idle animation: \(idleAnimationName)")
        }
        self.idleAnimationName = resolvedIdleAnimationName
        self.activeAnimationName = resolvedIdleAnimationName
        let clampedPoseSampleFps = max(1, min(poseSampleFps, 240))
        let requestedIdlePoseSampleFps = idlePoseSampleFps ?? clampedPoseSampleFps
        self.poseSampleFps = Double(clampedPoseSampleFps)
        self.idlePoseSampleFps = Double(max(1, min(requestedIdlePoseSampleFps, clampedPoseSampleFps)))
        self.lookAnimationNames = lookAnimationNames
        self.lookNeutralPoint = Self.clampPoint(lookNeutralPoint, minValue: 0, maxValue: 1)
        let fallbackDeadZone = min(max(lookIdleDeadZone, 0), 0.49)
        self.lookDeadZone = Self.clampPoint(
            lookDeadZone ?? CGPoint(x: fallbackDeadZone, y: fallbackDeadZone),
            minValue: 0,
            maxValue: 0.49
        )
        self.physicsIdlePolicy = physicsIdlePolicy
        let resolvedLoopingAnimationNames = loopingAnimationNames.union([resolvedIdleAnimationName])
        self.loopingAnimationNames = resolvedLoopingAnimationNames
        self.oneShotAnimationNames = oneShotAnimationNames.subtracting(resolvedLoopingAnimationNames)
        self.animationTransitionDuration = max(0, min(animationTransitionSeconds, 10))
        self.declarativePlan = declarativePlan
        self.referenceScale = referenceScale
        self.rendererStartedAt = CACurrentMediaTime()
        self.batchCount = builtBatches.count
        self.triangleVertexCount = builtBatches.reduce(0) { $0 + $1.vertexCount }
        self.cachedBatches = builtBatches

        guard triangleVertexCount > 0 else {
            throw EngineError.renderer("Spine setup mesh produced no drawable vertices")
        }
    }

    func draw(
        command: String,
        pointer: CGPoint,
        drawableSize: CGSize,
        contentRect: CGRect,
        encoder: MTLRenderCommandEncoder,
        normalPipelineState: MTLRenderPipelineState,
        additivePipelineState: MTLRenderPipelineState,
        multiplyPipelineState: MTLRenderPipelineState,
        screenPipelineState: MTLRenderPipelineState
    ) {
        _ = drawableSize
        _ = contentRect
        let scale: Float = 1.0
        let drawableBatches = batches(command: command, pointer: pointer)
        let foregroundAspectScale = SIMD2<Float>(1.0, 1.0)

        for batch in drawableBatches {
            var uniforms = RenderUniforms.make(
                scale: scale,
                offset: SIMD2<Float>(0, 0),
                aspectScale: foregroundAspectScale
            )
            switch batch.blendMode {
            case .normal:
                encoder.setRenderPipelineState(normalPipelineState)
            case .additive:
                encoder.setRenderPipelineState(additivePipelineState)
            case .multiply:
                encoder.setRenderPipelineState(multiplyPipelineState)
            case .screen:
                encoder.setRenderPipelineState(screenPipelineState)
            }
            encoder.setVertexBuffer(batch.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 1)
            encoder.setFragmentTexture(batch.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: batch.vertexCount)
        }
    }

    func diagnosticGeometrySamples(actionNames: [String]) -> [GeometrySample] {
        let uniqueActionNames = Array(Set(actionNames.isEmpty ? [idleAnimationName] : actionNames)).sorted()
        let originalPhysicsStates = physicsStates
        defer { physicsStates = originalPhysicsStates }

        var samples: [GeometrySample] = []
        for actionName in uniqueActionNames {
            guard let animation = animations[actionName] else {
                samples.append(GeometrySample(
                    actionName: actionName,
                    time: 0,
                    status: "missing",
                    batchCount: 0,
                    vertexCount: 0,
                    blendModes: "none",
                    uvStatus: "uv=missing-animation",
                    bounds: "bounds=none",
                    fingerprint: "fp=missing-animation",
                    error: "missing-animation"
                ))
                continue
            }

            for time in Self.geometrySampleTimes(animation: animation, poseSampleFps: sampleFps(for: actionName)) {
                samples.append(diagnosticGeometrySample(actionName: actionName, animation: animation, time: time))
            }
            if lookAnimationNames.contains(actionName) {
                samples.append(diagnosticGeometrySample(
                    actionName: "\(actionName)#lookMix=0.00",
                    animation: animation,
                    time: 0,
                    overlayMix: 0
                ))
                samples.append(diagnosticGeometrySample(
                    actionName: "\(actionName)#lookMix=0.50",
                    animation: animation,
                    time: 0,
                    overlayMix: 0.5
                ))
            }
        }
        return samples
    }

    func diagnosticSnapshot(actionName: String, time: Double, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else {
            throw EngineError.invalidArgument("Spine snapshot size must be between 1x1 and 8192x8192")
        }
        guard let animation = animations[actionName] else {
            throw EngineError.renderer("Missing Spine animation for snapshot action: \(actionName)")
        }
        let vertexBatches = try diagnosticVertexBatches(animation: animation, time: time)
        return try Self.snapshotImage(
            vertexBatches: vertexBatches,
            device: device,
            width: width,
            height: height
        )
    }

    func encodeDiagnosticPose(
        actionName: String,
        time: Double,
        encoder: MTLRenderCommandEncoder,
        normalPipelineState: MTLRenderPipelineState,
        additivePipelineState: MTLRenderPipelineState,
        multiplyPipelineState: MTLRenderPipelineState,
        screenPipelineState: MTLRenderPipelineState
    ) throws {
        guard let animation = animations[actionName] else {
            throw EngineError.renderer("Missing Spine animation for snapshot action: \(actionName)")
        }
        let vertexBatches = try diagnosticVertexBatches(animation: animation, time: time)
        try Self.encodeVertexBatches(
            vertexBatches,
            device: device,
            encoder: encoder,
            normalPipelineState: normalPipelineState,
            additivePipelineState: additivePipelineState,
            multiplyPipelineState: multiplyPipelineState,
            screenPipelineState: screenPipelineState
        )
    }

    private func batches(command: String, pointer: CGPoint, now: CFTimeInterval = CACurrentMediaTime()) -> [Batch] {
        let animationName = resolvedAnimationName(command: command, now: now)
        guard let activeAnimation = animations[animationName] ?? animations[idleAnimationName] else {
            return cachedBatches
        }
        let activeAnimationTime = time(in: activeAnimation, now: now)
        let idleAnimation = animations[idleAnimationName]
        let idleAnimationTime = idleAnimation.map { loopedTime(in: $0, startedAt: rendererStartedAt, now: now) } ?? 0
        let transitionMix = animationTransitionMix(now: now)
        let activeOverlayAnimation = activeAnimation.name == idleAnimationName ? nil : activeAnimation
        let activeOverlayMix = activeOverlayAnimation == nil ? 0 : transitionMix
        let previousOverlayAnimation = previousOverlayAnimationName.flatMap { animations[$0] }
        let previousOverlayTime = previousOverlayAnimation.map {
            time(in: $0, startedAt: previousOverlayAnimationStartedAt, now: now)
        } ?? 0
        let previousOverlayMix = previousOverlayAnimation == nil ? 0 : (1.0 - transitionMix)
        if transitionMix >= 1.0 {
            previousOverlayAnimationName = nil
        }
        let physicsTime = max(0, now - rendererStartedAt) * playbackRate
        let sleepPhysicsForIdle = shouldSleepPhysicsForIdle(
            animationName: activeAnimation.name,
            pointer: pointer,
            transitionMix: transitionMix,
            previousOverlayAnimation: previousOverlayAnimation
        )
        if sleepPhysicsForIdle != physicsIdleSleeping {
            resetPhysicsStates(at: sleepPhysicsForIdle ? 0 : physicsTime)
            physicsIdleSleeping = sleepPhysicsForIdle
        }
        let posePhysicsTime = physicsConstraintsEnabled && sleepPhysicsForIdle == false ? physicsTime : 0
        let bindingSnapshot = DeclarativeBindingEvaluator.evaluate(
            plan: declarativePlan,
            input: DeclarativeBindingEvaluationInput(pointerPosition: pointer)
        )
        let canUsePoseFrameCache = physicsConstraintsEnabled == false || sleepPhysicsForIdle
        let sampleFps = previousOverlayAnimation == nil ? sampleFps(for: animationName) : poseSampleFps
        let lookMix = lookAnimationNames.contains(activeAnimation.name) ? pointerLookMix(pointer) : 1.0
        let quantizedFrame = Int((activeAnimationTime * sampleFps).rounded())
        let quantizedIdleFrame = Int((idleAnimationTime * sampleFps).rounded())
        let quantizedPreviousFrame = Int((previousOverlayTime * sampleFps).rounded())
        let quantizedPhysicsFrame = Int((posePhysicsTime * sampleFps).rounded())
        let quantizedTransition = Int((transitionMix * sampleFps).rounded())
        let quantizedLookMix = Int((lookMix * sampleFps).rounded())
        let bindingKey = Self.bindingPoseCacheKey(bindingSnapshot.spineBoneRotationOffsets, sampleFps: sampleFps)
        let cacheKey = "\(activeAnimation.name):\(quantizedFrame):idle:\(idleAnimationName):\(quantizedIdleFrame):previous:\(previousOverlayAnimation?.name ?? "none"):\(quantizedPreviousFrame):mix:\(quantizedTransition):look:\(quantizedLookMix):physics:\(quantizedPhysicsFrame):bindings:\(bindingKey)"
        if cacheKey == cachedPoseKey {
            poseCacheExactHits += 1
            return cachedBatches
        }

        do {
            if canUsePoseFrameCache, let cachedVertexBatches = cachedVertexBatches(for: cacheKey) {
                poseCacheFrameHits += 1
                cachedBatches = try Self.updateBatches(
                    from: cachedVertexBatches,
                    previous: cachedBatches,
                    device: device
                )
                cachedPoseKey = cacheKey
                return cachedBatches
            }

            poseCacheMisses += 1
            let pose = evaluate(
                baseAnimation: idleAnimation,
                baseTime: idleAnimationTime,
                previousOverlayAnimation: previousOverlayAnimation,
                previousOverlayTime: previousOverlayTime,
                previousOverlayMix: previousOverlayMix,
                overlayAnimation: activeOverlayAnimation,
                overlayTime: activeAnimationTime,
                overlayMix: activeOverlayMix * lookMix,
                physicsTime: posePhysicsTime,
                boneRotationOffsets: bindingSnapshot.spineBoneRotationOffsets
            )
            let vertexBatches = try Self.buildVertexBatches(
                slots: pose.slots,
                attachments: attachments,
                clippingAttachments: clippingAttachments,
                bones: pose.boneWorld,
                deforms: pose.deforms,
                sequenceIndices: pose.sequenceIndices,
                boneIndexByName: boneIndexByName,
                atlas: atlas,
                skeletonBounds: skeletonBounds,
                placement: placement
            )
            cachedBatches = try Self.updateBatches(
                from: vertexBatches,
                previous: cachedBatches,
                device: device
            )
            cachedPoseKey = cacheKey
            if canUsePoseFrameCache {
                storeVertexBatches(vertexBatches, for: cacheKey)
            }
        } catch {
            fputs("Spine animation pose failed: \(error.localizedDescription)\n", stderr)
        }
        return cachedBatches
    }

    private func shouldSleepPhysicsForIdle(
        animationName: String,
        pointer: CGPoint,
        transitionMix: Double,
        previousOverlayAnimation: SpineAnimation?
    ) -> Bool {
        guard physicsConstraintsEnabled,
              physicsIdlePolicy == .sleepWhenIdle,
              animationName == idleAnimationName,
              previousOverlayAnimation == nil,
              transitionMix >= 1.0 else {
            return false
        }
        let dx = abs(Double(pointer.x - lookNeutralPoint.x))
        let dy = abs(Double(pointer.y - lookNeutralPoint.y))
        return dx <= Double(lookDeadZone.x) && dy <= Double(lookDeadZone.y)
    }

    private func resetPhysicsStates(at time: Double) {
        guard physicsStates.isEmpty == false else { return }
        physicsStates = Dictionary(uniqueKeysWithValues: physicsStates.keys.map { key in
            var state = PhysicsRuntimeState()
            state.lastTime = time
            return (key, state)
        })
    }

    private func pointerLookMix(_ pointer: CGPoint) -> Double {
        let dx = abs(Double(pointer.x - lookNeutralPoint.x))
        let dy = abs(Double(pointer.y - lookNeutralPoint.y))
        let xEdgeDistance = max(Double(lookNeutralPoint.x), 1.0 - Double(lookNeutralPoint.x))
        let yEdgeDistance = max(Double(lookNeutralPoint.y), 1.0 - Double(lookNeutralPoint.y))
        let xMix = (dx - Double(lookDeadZone.x)) / max(0.001, xEdgeDistance - Double(lookDeadZone.x))
        let yMix = (dy - Double(lookDeadZone.y)) / max(0.001, yEdgeDistance - Double(lookDeadZone.y))
        return min(max(max(xMix, yMix), 0), 1)
    }

    private static func bindingPoseCacheKey(_ offsets: [String: Double], sampleFps: Double) -> String {
        guard offsets.isEmpty == false else { return "none" }
        let quantizer = max(sampleFps, 1)
        return offsets.keys.sorted().map { key in
            let value = offsets[key] ?? 0
            return "\(key)=\(Int((value * quantizer).rounded()))"
        }.joined(separator: ",")
    }

    private static func clampPoint(_ point: CGPoint, minValue: CGFloat, maxValue: CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(point.x, minValue), maxValue),
            y: min(max(point.y, minValue), maxValue)
        )
    }

    private func cachedVertexBatches(for key: String) -> [VertexBatch]? {
        guard let index = poseFrameCache.firstIndex(where: { $0.key == key }) else {
            return nil
        }
        let entry = poseFrameCache.remove(at: index)
        poseFrameCache.append(entry)
        return entry.vertexBatches
    }

    private func storeVertexBatches(_ vertexBatches: [VertexBatch], for key: String) {
        let byteCount = Self.vertexBatchByteCount(vertexBatches)
        guard byteCount > 0, byteCount <= Self.maxPoseFrameCacheBytes else { return }

        if let existingIndex = poseFrameCache.firstIndex(where: { $0.key == key }) {
            let existing = poseFrameCache.remove(at: existingIndex)
            poseFrameCacheBytes -= existing.byteCount
        }

        poseFrameCache.append(PoseFrameCacheEntry(
            key: key,
            vertexBatches: vertexBatches,
            byteCount: byteCount
        ))
        poseFrameCacheBytes += byteCount
        poseCacheStores += 1

        while poseFrameCache.count > Self.maxPoseFrameCacheEntries
            || poseFrameCacheBytes > Self.maxPoseFrameCacheBytes {
            let removed = poseFrameCache.removeFirst()
            poseFrameCacheBytes -= removed.byteCount
        }
    }

    func diagnosticPoseCacheProbe(command: String, pointer: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> PoseCacheProbe {
        resetPoseCacheStats()
        let baseNow = max(CACurrentMediaTime(), rendererStartedAt) + 1.0
        let firstBuildMs = Self.measureMilliseconds {
            _ = batches(command: command, pointer: pointer, now: baseNow)
        }
        let exactHitMs = Self.measureMilliseconds {
            _ = batches(command: command, pointer: pointer, now: baseNow)
        }
        _ = batches(command: command, pointer: pointer, now: baseNow + (1.0 / sampleFps(for: command)))
        let frameHitMs = Self.measureMilliseconds {
            _ = batches(command: command, pointer: pointer, now: baseNow)
        }
        return PoseCacheProbe(
            firstBuildMs: firstBuildMs,
            exactHitMs: exactHitMs,
            frameHitMs: frameHitMs,
            stats: poseCacheStats()
        )
    }

    private func resetPoseCacheStats() {
        poseCacheExactHits = 0
        poseCacheFrameHits = 0
        poseCacheMisses = 0
        poseCacheStores = 0
    }

    private func sampleFps(for animationName: String) -> Double {
        animationName == idleAnimationName ? idlePoseSampleFps : poseSampleFps
    }

    private func poseCacheStats() -> PoseCacheStats {
        PoseCacheStats(
            exactHits: poseCacheExactHits,
            frameHits: poseCacheFrameHits,
            misses: poseCacheMisses,
            stores: poseCacheStores,
            entries: poseFrameCache.count,
            bytes: poseFrameCacheBytes
        )
    }

    private static func measureMilliseconds(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000.0
    }

    private func diagnosticGeometrySample(
        actionName: String,
        animation: SpineAnimation,
        time: Double,
        overlayMix: Double? = nil
    ) -> GeometrySample {
        do {
            let vertexBatches = try diagnosticVertexBatches(
                animation: animation,
                time: time,
                overlayMix: overlayMix
            )
            return Self.geometrySample(
                actionName: actionName,
                time: time,
                vertexBatches: vertexBatches,
                error: "none"
            )
        } catch {
            return GeometrySample(
                actionName: actionName,
                time: time,
                status: "error",
                batchCount: 0,
                vertexCount: 0,
                blendModes: "none",
                uvStatus: "uv=error",
                bounds: "bounds=none",
                fingerprint: "fp=error",
                error: Self.sanitize(error.localizedDescription)
            )
        }
    }

    private func diagnosticVertexBatches(
        animation: SpineAnimation,
        time: Double,
        overlayMix: Double? = nil
    ) throws -> [VertexBatch] {
        let overlayAnimation = animation.name == idleAnimationName ? nil : animation
        let effectiveOverlayMix = overlayAnimation == nil ? 0 : min(max(overlayMix ?? 1, 0), 1)
        let pose = evaluate(
            baseAnimation: animations[idleAnimationName],
            baseTime: time,
            previousOverlayAnimation: nil,
            previousOverlayTime: 0,
            previousOverlayMix: 0,
            overlayAnimation: overlayAnimation,
            overlayTime: time,
            overlayMix: effectiveOverlayMix,
            physicsTime: time
        )
        return try Self.buildVertexBatches(
            slots: pose.slots,
            attachments: attachments,
            clippingAttachments: clippingAttachments,
            bones: pose.boneWorld,
            deforms: pose.deforms,
            sequenceIndices: pose.sequenceIndices,
            boneIndexByName: boneIndexByName,
            atlas: atlas,
            skeletonBounds: skeletonBounds,
            placement: placement
        )
    }

    private func resolvedAnimationName(command: String, now: CFTimeInterval) -> String {
        let requested = animations[command] == nil ? idleAnimationName : command
        let current = animations[activeAnimationName]

        if oneShotAnimationNames.contains(activeAnimationName),
           let current,
           (now - activeAnimationStartedAt) * playbackRate < max(current.duration, 0.1),
           requested == idleAnimationName {
            return activeAnimationName
        }

        if requested != activeAnimationName {
            previousOverlayAnimationName = activeAnimationName == idleAnimationName ? nil : activeAnimationName
            previousOverlayAnimationStartedAt = activeAnimationStartedAt
            activeAnimationName = requested
            activeAnimationStartedAt = now
        }
        return activeAnimationName
    }

    private func animationTransitionMix(now: CFTimeInterval) -> Double {
        guard animationTransitionDuration > 0 else { return 1 }
        let elapsed = max(0, now - activeAnimationStartedAt)
        let linear = min(max(elapsed / animationTransitionDuration, 0), 1)
        return linear * linear * (3 - (2 * linear))
    }

    private func loopedTime(in animation: SpineAnimation, startedAt: CFTimeInterval, now: CFTimeInterval) -> Double {
        let elapsed = max(0, now - startedAt) * playbackRate
        guard animation.duration > 0 else { return 0 }
        return elapsed.truncatingRemainder(dividingBy: animation.duration)
    }

    private func time(in animation: SpineAnimation, now: CFTimeInterval) -> Double {
        time(in: animation, startedAt: activeAnimationStartedAt, now: now)
    }

    private func time(in animation: SpineAnimation, startedAt: CFTimeInterval, now: CFTimeInterval) -> Double {
        let elapsed = max(0, now - startedAt) * playbackRate
        if animation.duration <= 0 {
            return 0
        }
        if loopingAnimationNames.contains(animation.name) {
            return elapsed.truncatingRemainder(dividingBy: animation.duration)
        }
        return min(elapsed, animation.duration)
    }

    private func evaluate(
        baseAnimation: SpineAnimation?,
        baseTime: Double,
        previousOverlayAnimation: SpineAnimation?,
        previousOverlayTime: Double,
        previousOverlayMix: Double,
        overlayAnimation: SpineAnimation?,
        overlayTime: Double,
        overlayMix: Double,
        physicsTime: Double,
        boneRotationOffsets: [String: Double] = [:]
    ) -> (boneWorld: [BoneWorld], slots: [Slot], deforms: [String: [String: [Double]]], sequenceIndices: [String: [String: Int]]) {
        var posedBones = bones
        var posedSlots = slots
        var deforms: [String: [String: [Double]]] = [:]
        var sequenceIndices: [String: [String: Int]] = [:]

        if let baseAnimation {
            apply(animation: baseAnimation, time: baseTime, alpha: 1, to: &posedBones, slots: &posedSlots, deforms: &deforms, sequenceIndices: &sequenceIndices)
        }
        if let previousOverlayAnimation, previousOverlayMix > 0 {
            apply(
                animation: previousOverlayAnimation,
                time: previousOverlayTime,
                alpha: previousOverlayMix,
                to: &posedBones,
                slots: &posedSlots,
                deforms: &deforms,
                sequenceIndices: &sequenceIndices
            )
        }
        if let overlayAnimation, overlayMix > 0 {
            apply(animation: overlayAnimation, time: overlayTime, alpha: overlayMix, to: &posedBones, slots: &posedSlots, deforms: &deforms, sequenceIndices: &sequenceIndices)
        }
        applyDrawOrder(
            baseAnimation: baseAnimation,
            baseTime: baseTime,
            previousOverlayAnimation: previousOverlayAnimation,
            previousOverlayTime: previousOverlayTime,
            previousOverlayMix: previousOverlayMix,
            overlayAnimation: overlayAnimation,
            overlayTime: overlayTime,
            overlayMix: overlayMix,
            slots: &posedSlots
        )
        applyDeclarativeBoneRotationOffsets(boneRotationOffsets, to: &posedBones)

        return (Self.computeBoneWorld(
            posedBones,
            constraints: poseConstraints,
            slots: posedSlots,
            pathAttachments: pathAttachments,
            deforms: deforms,
            boneIndexByName: boneIndexByName,
            physicsStateByName: &physicsStates,
            skeletonTime: physicsTime,
            enablePhysicsConstraints: physicsConstraintsEnabled,
            referenceScale: referenceScale
        ), posedSlots, deforms, sequenceIndices)
    }

    private func applyDeclarativeBoneRotationOffsets(
        _ offsets: [String: Double],
        to posedBones: inout [Bone]
    ) {
        guard offsets.isEmpty == false else { return }
        for (boneName, offset) in offsets {
            guard let index = boneIndexByName[boneName],
                  offset.isFinite else {
                continue
            }
            posedBones[index].rotation += offset
        }
    }

    private func apply(
        animation: SpineAnimation,
        time: Double,
        alpha: Double,
        to posedBones: inout [Bone],
        slots posedSlots: inout [Slot],
        deforms: inout [String: [String: [Double]]],
        sequenceIndices: inout [String: [String: Int]]
    ) {
        let mix = min(max(alpha, 0), 1)
        guard mix > 0 else { return }

        for (boneName, timelines) in animation.boneTimelines {
            guard let index = boneIndexByName[boneName] else { continue }
            let setup = bones[index]

            if timelines.rotate.isEmpty == false {
                let target = setup.rotation + sampleValue(timelines.rotate, time: time, defaultValue: 0)
                posedBones[index].rotation = blend(posedBones[index].rotation, target, mix)
            }
            if timelines.translate.isEmpty == false {
                let sampled = sampleXY(timelines.translate, time: time, defaultX: 0, defaultY: 0)
                posedBones[index].x = blend(posedBones[index].x, setup.x + sampled.x, mix)
                posedBones[index].y = blend(posedBones[index].y, setup.y + sampled.y, mix)
            }
            if timelines.translateX.isEmpty == false {
                let target = setup.x + sampleValue(timelines.translateX, time: time, defaultValue: 0)
                posedBones[index].x = blend(posedBones[index].x, target, mix)
            }
            if timelines.translateY.isEmpty == false {
                let target = setup.y + sampleValue(timelines.translateY, time: time, defaultValue: 0)
                posedBones[index].y = blend(posedBones[index].y, target, mix)
            }
            if timelines.scale.isEmpty == false {
                let sampled = sampleXY(timelines.scale, time: time, defaultX: 1, defaultY: 1)
                posedBones[index].scaleX = blend(posedBones[index].scaleX, setup.scaleX * sampled.x, mix)
                posedBones[index].scaleY = blend(posedBones[index].scaleY, setup.scaleY * sampled.y, mix)
            }
            if timelines.shear.isEmpty == false {
                let sampled = sampleXY(timelines.shear, time: time, defaultX: 0, defaultY: 0)
                posedBones[index].shearX = blend(posedBones[index].shearX, setup.shearX + sampled.x, mix)
                posedBones[index].shearY = blend(posedBones[index].shearY, setup.shearY + sampled.y, mix)
            }
        }

        for slotIndex in posedSlots.indices {
            let slotName = posedSlots[slotIndex].name
            guard let timelines = animation.slotTimelines[slotName] else { continue }
            let setupSlot = slotSetupByName[slotName] ?? posedSlots[slotIndex]
            if let color = sampleColor(timelines.rgba, time: time, defaultColor: setupSlot.color) {
                posedSlots[slotIndex].color = blend(posedSlots[slotIndex].color, color, Float(mix))
            }
            if let rgb = sampleRGBColor(timelines.rgb, time: time, defaultColor: setupSlot.color) {
                let color = replacingRGB(of: posedSlots[slotIndex].color, with: rgb)
                posedSlots[slotIndex].color = blend(posedSlots[slotIndex].color, color, Float(mix))
            }
            if let alpha = sampleAlpha(timelines.alpha, time: time, defaultAlpha: setupSlot.color.w) {
                let color = replacingAlpha(of: posedSlots[slotIndex].color, with: alpha)
                posedSlots[slotIndex].color = blend(posedSlots[slotIndex].color, color, Float(mix))
            }
            if timelines.attachment.isEmpty == false, mix >= 0.5 {
                posedSlots[slotIndex].attachment = sampleAttachment(timelines.attachment, time: time, defaultAttachment: setupSlot.attachment)
            }
        }

        for (slotName, attachmentMap) in animation.attachmentTimelines {
            for (attachmentName, timelines) in attachmentMap {
                guard let attachment = attachments[slotName]?[attachmentName] else {
                    continue
                }
                if timelines.deform.isEmpty == false {
                    let length = Self.deformLength(attachment: attachment)
                    let deform = sampleDeform(timelines.deform, time: time, length: length)
                    if deform.isEmpty == false {
                        let current = deforms[slotName]?[attachmentName] ?? [Double](repeating: 0, count: deform.count)
                        deforms[slotName, default: [:]][attachmentName] = blend(current, deform, mix)
                    }
                }
                if let sequence = attachment.sequence,
                   timelines.sequence.isEmpty == false,
                   mix >= 0.5 {
                    sequenceIndices[slotName, default: [:]][attachmentName] = sampleSequenceIndex(
                        timelines.sequence,
                        time: time,
                        sequence: sequence
                    )
                }
            }
        }
    }

    private func applyDrawOrder(
        baseAnimation: SpineAnimation?,
        baseTime: Double,
        previousOverlayAnimation: SpineAnimation?,
        previousOverlayTime: Double,
        previousOverlayMix: Double,
        overlayAnimation: SpineAnimation?,
        overlayTime: Double,
        overlayMix: Double,
        slots posedSlots: inout [Slot]
    ) {
        if let baseAnimation,
           let frame = sampleDrawOrder(baseAnimation.drawOrder, time: baseTime) {
            applyDrawOrder(frame, slots: &posedSlots)
        }
        if let previousOverlayAnimation,
           previousOverlayMix >= 0.5,
           let frame = sampleDrawOrder(previousOverlayAnimation.drawOrder, time: previousOverlayTime) {
            applyDrawOrder(frame, slots: &posedSlots)
        }
        if let overlayAnimation,
           overlayMix >= 0.5,
           let frame = sampleDrawOrder(overlayAnimation.drawOrder, time: overlayTime) {
            applyDrawOrder(frame, slots: &posedSlots)
        }
    }

    private func sampleDrawOrder(_ frames: [DrawOrderFrame], time: Double) -> DrawOrderFrame? {
        guard frames.isEmpty == false else { return nil }
        var selected: DrawOrderFrame?
        for frame in frames {
            if frame.time <= time {
                selected = frame
            } else {
                break
            }
        }
        return selected
    }

    private func applyDrawOrder(_ frame: DrawOrderFrame, slots posedSlots: inout [Slot]) {
        let currentByName = Dictionary(uniqueKeysWithValues: posedSlots.map { ($0.name, $0) })
        guard let offsets = frame.offsets else {
            posedSlots = slots.map { currentByName[$0.name] ?? $0 }
            return
        }

        var orderedSlots = [Slot?](repeating: nil, count: slots.count)
        var unchangedSetupIndices: [Int] = []
        var setupIndex = 0

        let sortedOffsets = offsets.sorted {
            (slotIndexByName[$0.slotName] ?? Int.max) < (slotIndexByName[$1.slotName] ?? Int.max)
        }
        for offset in sortedOffsets {
            guard let slotIndex = slotIndexByName[offset.slotName] else { continue }
            while setupIndex < slotIndex {
                unchangedSetupIndices.append(setupIndex)
                setupIndex += 1
            }

            guard setupIndex < slots.count else { continue }
            let targetIndex = setupIndex + offset.offset
            guard targetIndex >= 0, targetIndex < orderedSlots.count else { continue }
            let slotName = slots[setupIndex].name
            orderedSlots[targetIndex] = currentByName[slotName] ?? slots[setupIndex]
            setupIndex += 1
        }

        while setupIndex < slots.count {
            unchangedSetupIndices.append(setupIndex)
            setupIndex += 1
        }

        var unchangedCursor = unchangedSetupIndices.count - 1
        for index in stride(from: orderedSlots.count - 1, through: 0, by: -1) where orderedSlots[index] == nil {
            guard unchangedCursor >= 0 else { return }
            let unchangedSetupIndex = unchangedSetupIndices[unchangedCursor]
            let slotName = slots[unchangedSetupIndex].name
            orderedSlots[index] = currentByName[slotName] ?? slots[unchangedSetupIndex]
            unchangedCursor -= 1
        }

        let compacted = orderedSlots.compactMap { $0 }
        if compacted.count == slots.count {
            posedSlots = compacted
        }
    }

    private func blend(_ from: Double, _ to: Double, _ mix: Double) -> Double {
        from + ((to - from) * mix)
    }

    private func blend(_ from: SIMD4<Float>, _ to: SIMD4<Float>, _ mix: Float) -> SIMD4<Float> {
        from + ((to - from) * mix)
    }

    private func replacingRGB(of color: SIMD4<Float>, with rgb: SIMD3<Float>) -> SIMD4<Float> {
        let alpha = color.w
        return SIMD4<Float>(rgb.x * alpha, rgb.y * alpha, rgb.z * alpha, alpha)
    }

    private func replacingAlpha(of color: SIMD4<Float>, with alpha: Float) -> SIMD4<Float> {
        let rgb = unpremultipliedRGB(color)
        return SIMD4<Float>(rgb.x * alpha, rgb.y * alpha, rgb.z * alpha, alpha)
    }

    private func unpremultipliedRGB(_ color: SIMD4<Float>) -> SIMD3<Float> {
        guard color.w > 0.00001 else {
            return SIMD3<Float>(0, 0, 0)
        }
        return SIMD3<Float>(color.x / color.w, color.y / color.w, color.z / color.w)
    }

    private func blend(_ from: [Double], _ to: [Double], _ mix: Double) -> [Double] {
        let count = max(from.count, to.count)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let start = index < from.count ? from[index] : 0
            let target = index < to.count ? to[index] : 0
            return blend(start, target, mix)
        }
    }

    private static func parseAnimations(root: [String: Any]) throws -> [String: SpineAnimation] {
        guard let rawAnimations = root["animations"] as? [String: Any] else {
            return [:]
        }

        var result: [String: SpineAnimation] = [:]
        for (animationName, rawAnimation) in rawAnimations {
            guard let animationMap = rawAnimation as? [String: Any] else { continue }
            var duration = 0.0
            var boneTimelines: [String: BoneTimelines] = [:]
            var slotTimelines: [String: SlotTimelines] = [:]
            var attachmentTimelines: [String: [String: AttachmentTimelines]] = [:]
            var drawOrder: [DrawOrderFrame] = []

            if let rawBones = animationMap["bones"] as? [String: Any] {
                for (boneName, rawTimelineSet) in rawBones {
                    guard let timelineSet = rawTimelineSet as? [String: Any] else { continue }
                    var timelines = BoneTimelines()
                    if let raw = timelineSet["rotate"] {
                        timelines.rotate = parseFrames(raw, defaultX: 0, defaultY: 0, defaultValue: 0)
                    }
                    if let raw = timelineSet["translate"] {
                        timelines.translate = parseFrames(raw, defaultX: 0, defaultY: 0, defaultValue: 0)
                    }
                    if let raw = timelineSet["translatex"] {
                        timelines.translateX = parseFrames(raw, defaultX: 0, defaultY: 0, defaultValue: 0)
                    }
                    if let raw = timelineSet["translatey"] {
                        timelines.translateY = parseFrames(raw, defaultX: 0, defaultY: 0, defaultValue: 0)
                    }
                    if let raw = timelineSet["scale"] {
                        timelines.scale = parseFrames(raw, defaultX: 1, defaultY: 1, defaultValue: 1)
                    }
                    if let raw = timelineSet["shear"] {
                        timelines.shear = parseFrames(raw, defaultX: 0, defaultY: 0, defaultValue: 0)
                    }
                    duration = max(duration, timelines.maxTime)
                    boneTimelines[boneName] = timelines
                }
            }

            if let rawSlots = animationMap["slots"] as? [String: Any] {
                for (slotName, rawTimelineSet) in rawSlots {
                    guard let timelineSet = rawTimelineSet as? [String: Any] else { continue }
                    var timelines = SlotTimelines()
                    if let raw = timelineSet["rgba"] {
                        timelines.rgba = parseColorFrames(raw)
                    }
                    if let raw = timelineSet["color"], timelines.rgba.isEmpty {
                        timelines.rgba = parseColorFrames(raw)
                    }
                    if let raw = timelineSet["rgb"] {
                        timelines.rgb = parseRGBColorFrames(raw)
                    }
                    if let raw = timelineSet["alpha"] {
                        timelines.alpha = parseAlphaFrames(raw)
                    }
                    if let raw = timelineSet["attachment"] {
                        timelines.attachment = parseAttachmentFrames(raw)
                    }
                    duration = max(duration, timelines.maxTime)
                    slotTimelines[slotName] = timelines
                }
            }

            if let rawAttachmentSkins = animationMap["attachments"] as? [String: Any] {
                for (_, rawSkin) in rawAttachmentSkins {
                    guard let skinMap = rawSkin as? [String: Any] else { continue }
                    for (slotName, rawAttachmentSet) in skinMap {
                        guard let attachmentSet = rawAttachmentSet as? [String: Any] else { continue }
                        for (attachmentName, rawTimelineSet) in attachmentSet {
                            guard let timelineSet = rawTimelineSet as? [String: Any] else { continue }
                            var timelines = AttachmentTimelines()
                            if let raw = timelineSet["deform"] {
                                timelines.deform = parseDeformFrames(raw)
                            }
                            if let raw = timelineSet["sequence"] {
                                timelines.sequence = parseSequenceFrames(raw)
                            }
                            duration = max(duration, timelines.maxTime)
                            attachmentTimelines[slotName, default: [:]][attachmentName] = timelines
                        }
                    }
                }
            }

            if let raw = animationMap["drawOrder"] ?? animationMap["draworder"] {
                drawOrder = parseDrawOrderFrames(raw)
                duration = max(duration, drawOrder.map(\.time).max() ?? 0)
            }
            let eventFrames = parseEventFrames(animationMap["events"])
            duration = max(duration, eventFrames.map(\.time).max() ?? 0)

            result[animationName] = SpineAnimation(
                name: animationName,
                duration: duration,
                boneTimelines: boneTimelines,
                slotTimelines: slotTimelines,
                attachmentTimelines: attachmentTimelines,
                drawOrder: drawOrder,
                eventFrames: eventFrames
            )
        }

        return result
    }

    private static func parseDrawOrderFrames(_ raw: Any) -> [DrawOrderFrame] {
        guard let frames = raw as? [[String: Any]] else { return [] }
        return frames.map { frame in
            let offsets: [DrawOrderOffset]?
            if let rawOffsets = frame["offsets"] as? [[String: Any]] {
                offsets = rawOffsets.compactMap { rawOffset in
                    guard let slotName = rawOffset["slot"] as? String else { return nil }
                    return DrawOrderOffset(
                        slotName: slotName,
                        offset: Int(number(rawOffset["offset"], default: 0))
                    )
                }
            } else {
                offsets = nil
            }

            return DrawOrderFrame(
                time: number(frame["time"], default: 0),
                offsets: offsets
            )
        }
        .sorted { $0.time < $1.time }
    }

    private static func parseEventFrames(_ raw: Any?) -> [EventFrame] {
        guard let frames = raw as? [[String: Any]] else { return [] }
        return frames.compactMap { frame in
            guard let name = frame["name"] as? String else { return nil }
            return EventFrame(
                time: number(frame["time"], default: 0),
                name: name
            )
        }
        .sorted { $0.time < $1.time }
    }

    private static func parseFrames(
        _ raw: Any,
        defaultX: Double,
        defaultY: Double,
        defaultValue: Double
    ) -> [TimelineFrame] {
        guard let frames = raw as? [[String: Any]] else { return [] }
        return frames.map { frame in
            TimelineFrame(
                time: number(frame["time"], default: 0),
                x: number(frame["x"], default: defaultX),
                y: number(frame["y"], default: defaultY),
                value: number(frame["value"], default: defaultValue),
                color: nil,
                attachment: nil,
                stepped: isStepped(frame["curve"]),
                curve: parseCurve(frame["curve"])
            )
        }
        .sorted { $0.time < $1.time }
    }

    private static func parseColorFrames(_ raw: Any) -> [TimelineFrame] {
        guard let frames = raw as? [[String: Any]] else { return [] }
        return frames.map { frame in
            TimelineFrame(
                time: number(frame["time"], default: 0),
                x: 0,
                y: 0,
                value: 0,
                color: parseColor(frame["color"] as? String),
                attachment: nil,
                stepped: isStepped(frame["curve"]),
                curve: parseCurve(frame["curve"])
            )
        }
        .sorted { $0.time < $1.time }
    }

    private static func parseRGBColorFrames(_ raw: Any) -> [TimelineFrame] {
        guard let frames = raw as? [[String: Any]] else { return [] }
        return frames.map { frame in
            TimelineFrame(
                time: number(frame["time"], default: 0),
                x: 0,
                y: 0,
                value: 0,
                color: parseRGBColor(frame["color"] as? String),
                attachment: nil,
                stepped: isStepped(frame["curve"]),
                curve: parseCurve(frame["curve"])
            )
        }
        .sorted { $0.time < $1.time }
    }

    private static func parseAlphaFrames(_ raw: Any) -> [TimelineFrame] {
        guard let frames = raw as? [[String: Any]] else { return [] }
        return frames.map { frame in
            TimelineFrame(
                time: number(frame["time"], default: 0),
                x: 0,
                y: 0,
                value: min(max(number(frame["value"] ?? frame["alpha"], default: 1), 0), 1),
                color: nil,
                attachment: nil,
                stepped: isStepped(frame["curve"]),
                curve: parseCurve(frame["curve"])
            )
        }
        .sorted { $0.time < $1.time }
    }

    private static func parseAttachmentFrames(_ raw: Any) -> [TimelineFrame] {
        guard let frames = raw as? [[String: Any]] else { return [] }
        return frames.map { frame in
            TimelineFrame(
                time: number(frame["time"], default: 0),
                x: 0,
                y: 0,
                value: 0,
                color: nil,
                attachment: frame["name"] as? String,
                stepped: true,
                curve: nil
            )
        }
        .sorted { $0.time < $1.time }
    }

    private static func parseDeformFrames(_ raw: Any) -> [DeformFrame] {
        guard let frames = raw as? [[String: Any]] else { return [] }
        return frames.map { frame in
            DeformFrame(
                time: number(frame["time"], default: 0),
                offset: Int(number(frame["offset"], default: 0)),
                vertices: frame["vertices"] as? [Double],
                stepped: isStepped(frame["curve"]),
                curve: parseCurve(frame["curve"])
            )
        }
        .sorted { $0.time < $1.time }
    }

    private static func parseSequenceFrames(_ raw: Any) -> [SequenceFrame] {
        guard let frames = raw as? [[String: Any]] else { return [] }
        return frames.map { frame in
            SequenceFrame(
                time: number(frame["time"], default: 0),
                index: Int(number(frame["index"], default: 0)),
                mode: frame["mode"] as? String ?? "hold",
                delay: number(frame["delay"], default: 0)
            )
        }
        .sorted { $0.time < $1.time }
    }

    private func sampleValue(_ frames: [TimelineFrame], time: Double, defaultValue: Double) -> Double {
        sample(frames, time: time, defaultFrame: TimelineFrame(
            time: 0,
            x: 0,
            y: 0,
            value: defaultValue,
            color: nil,
            attachment: nil,
            stepped: true,
            curve: nil
        )).value
    }

    private func sampleXY(_ frames: [TimelineFrame], time: Double, defaultX: Double, defaultY: Double) -> (x: Double, y: Double) {
        let sampled = sample(frames, time: time, defaultFrame: TimelineFrame(
            time: 0,
            x: defaultX,
            y: defaultY,
            value: 0,
            color: nil,
            attachment: nil,
            stepped: true,
            curve: nil
        ))
        return (sampled.x, sampled.y)
    }

    private func sampleColor(_ frames: [TimelineFrame], time: Double, defaultColor: SIMD4<Float>) -> SIMD4<Float>? {
        guard frames.isEmpty == false else { return nil }
        let sampled = sample(frames, time: time, defaultFrame: TimelineFrame(
            time: 0,
            x: 0,
            y: 0,
            value: 0,
            color: defaultColor,
            attachment: nil,
            stepped: true,
            curve: nil
        ))
        return sampled.color
    }

    private func sampleRGBColor(_ frames: [TimelineFrame], time: Double, defaultColor: SIMD4<Float>) -> SIMD3<Float>? {
        guard frames.isEmpty == false else { return nil }
        let sampled = sample(frames, time: time, defaultFrame: TimelineFrame(
            time: 0,
            x: 0,
            y: 0,
            value: 0,
            color: SIMD4<Float>(unpremultipliedRGB(defaultColor), 1),
            attachment: nil,
            stepped: true,
            curve: nil
        ))
        guard let color = sampled.color else { return nil }
        return SIMD3<Float>(color.x, color.y, color.z)
    }

    private func sampleAlpha(_ frames: [TimelineFrame], time: Double, defaultAlpha: Float) -> Float? {
        guard frames.isEmpty == false else { return nil }
        let sampled = sample(frames, time: time, defaultFrame: TimelineFrame(
            time: 0,
            x: 0,
            y: 0,
            value: Double(defaultAlpha),
            color: nil,
            attachment: nil,
            stepped: true,
            curve: nil
        ))
        return Float(min(max(sampled.value, 0), 1))
    }

    private func sampleAttachment(_ frames: [TimelineFrame], time: Double, defaultAttachment: String?) -> String? {
        guard frames.isEmpty == false else { return defaultAttachment }
        let sampled = sample(frames, time: time, defaultFrame: TimelineFrame(
            time: 0,
            x: 0,
            y: 0,
            value: 0,
            color: nil,
            attachment: defaultAttachment,
            stepped: true,
            curve: nil
        ))
        return sampled.attachment
    }

    private func sampleSequenceIndex(_ frames: [SequenceFrame], time: Double, sequence: SequenceInfo) -> Int {
        guard sequence.count > 0, frames.isEmpty == false else {
            return sequence.setupIndex
        }
        let frame = frames.last { time >= $0.time } ?? frames[0]
        let baseIndex = min(max(frame.index, 0), sequence.count - 1)
        let delay = max(frame.delay, 0)
        let step = delay > 0 ? max(Int((time - frame.time) / delay), 0) : 0
        let rawMode = frame.mode.lowercased().replacingOccurrences(of: "_", with: "")

        switch rawMode {
        case "setup":
            return sequence.setupIndex
        case "once":
            return min(baseIndex + step, sequence.count - 1)
        case "loop":
            return positiveModulo(baseIndex + step, sequence.count)
        case "pingpong", "pingpongonce":
            return pingPongIndex(baseIndex + step, count: sequence.count)
        case "oncereverse":
            return max(baseIndex - step, 0)
        case "loopreverse":
            return positiveModulo(baseIndex - step, sequence.count)
        case "pingpongreverse", "pingpongoncereverse":
            return pingPongIndex(baseIndex - step, count: sequence.count)
        default:
            return baseIndex
        }
    }

    private func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        guard modulus > 0 else { return 0 }
        let result = value % modulus
        return result >= 0 ? result : result + modulus
    }

    private func pingPongIndex(_ value: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = (count - 1) * 2
        let modulo = positiveModulo(value, period)
        return modulo < count ? modulo : period - modulo
    }

    private func sampleDeform(_ frames: [DeformFrame], time: Double, length: Int) -> [Double] {
        guard length > 0, frames.isEmpty == false else { return [] }
        guard time > frames[0].time else {
            return deformVector(frames[0], length: length)
        }

        for index in 0..<(frames.count - 1) {
            let current = frames[index]
            let next = frames[index + 1]
            if time <= next.time {
                if current.stepped || next.time <= current.time {
                    return deformVector(current, length: length)
                }
                let linearRatio = min(max((time - current.time) / (next.time - current.time), 0), 1)
                let ratio = interpolateCurveValue(
                    time: time,
                    fromTime: current.time,
                    toTime: next.time,
                    fromValue: 0,
                    toValue: 1,
                    curve: current.curve,
                    valueIndex: 0,
                    fallbackRatio: linearRatio
                )
                let from = deformVector(current, length: length)
                let to = deformVector(next, length: length)
                return zip(from, to).map { $0 + (($1 - $0) * ratio) }
            }
        }

        return deformVector(frames.last, length: length)
    }

    private func deformVector(_ frame: DeformFrame?, length: Int) -> [Double] {
        guard length > 0 else { return [] }
        var output = [Double](repeating: 0, count: length)
        guard let frame, let vertices = frame.vertices else {
            return output
        }
        let start = min(max(frame.offset, 0), length)
        let count = min(vertices.count, length - start)
        guard count > 0 else { return output }
        for index in 0..<count {
            output[start + index] = vertices[index]
        }
        return output
    }

    private func sample(_ frames: [TimelineFrame], time: Double, defaultFrame: TimelineFrame) -> TimelineFrame {
        guard frames.isEmpty == false else { return defaultFrame }
        guard time > frames[0].time else { return frames[0] }

        for index in 0..<(frames.count - 1) {
            let current = frames[index]
            let next = frames[index + 1]
            if time <= next.time {
                if current.stepped || next.time <= current.time {
                    return current
                }
                let ratio = min(max((time - current.time) / (next.time - current.time), 0), 1)
                return TimelineFrame(
                    time: time,
                    x: interpolateCurveValue(
                        time: time,
                        fromTime: current.time,
                        toTime: next.time,
                        fromValue: current.x,
                        toValue: next.x,
                        curve: current.curve,
                        valueIndex: 0,
                        fallbackRatio: ratio
                    ),
                    y: interpolateCurveValue(
                        time: time,
                        fromTime: current.time,
                        toTime: next.time,
                        fromValue: current.y,
                        toValue: next.y,
                        curve: current.curve,
                        valueIndex: 1,
                        fallbackRatio: ratio
                    ),
                    value: interpolateCurveValue(
                        time: time,
                        fromTime: current.time,
                        toTime: next.time,
                        fromValue: current.value,
                        toValue: next.value,
                        curve: current.curve,
                        valueIndex: 0,
                        fallbackRatio: ratio
                    ),
                    color: interpolateColor(current.color, next.color, ratio: ratio),
                    attachment: current.attachment,
                    stepped: current.stepped,
                    curve: nil
                )
            }
        }

        return frames.last ?? defaultFrame
    }

    private func interpolateColor(_ start: SIMD4<Float>?, _ end: SIMD4<Float>?, ratio: Double) -> SIMD4<Float>? {
        guard let start else { return end }
        guard let end else { return start }
        let t = Float(ratio)
        return start + ((end - start) * t)
    }

    private static func isStepped(_ raw: Any?) -> Bool {
        (raw as? String)?.lowercased() == "stepped"
    }

    private static func parseCurve(_ raw: Any?) -> [Double]? {
        guard let values = raw as? [Double], values.count >= 4 else {
            return nil
        }
        return values
    }

    private func interpolateCurveValue(
        time: Double,
        fromTime: Double,
        toTime: Double,
        fromValue: Double,
        toValue: Double,
        curve: [Double]?,
        valueIndex: Int,
        fallbackRatio: Double
    ) -> Double {
        guard let curve, curve.count >= 4, toTime > fromTime else {
            return fromValue + (toValue - fromValue) * fallbackRatio
        }

        let offset = valueIndex * 4
        guard offset + 3 < curve.count else {
            return fromValue + (toValue - fromValue) * fallbackRatio
        }

        let controlTime1 = curve[offset]
        let controlValue1 = curve[offset + 1]
        let controlTime2 = curve[offset + 2]
        let controlValue2 = curve[offset + 3]
        let t = solveCubicParameter(
            x: time,
            x0: fromTime,
            x1: controlTime1,
            x2: controlTime2,
            x3: toTime,
            initial: fallbackRatio
        )
        return cubicInterpolate(
            t: t,
            p0: fromValue,
            p1: controlValue1,
            p2: controlValue2,
            p3: toValue
        )
    }

    private func solveCubicParameter(
        x: Double,
        x0: Double,
        x1: Double,
        x2: Double,
        x3: Double,
        initial: Double
    ) -> Double {
        var t = min(max(initial, 0), 1)
        for _ in 0..<8 {
            let current = cubicInterpolate(t: t, p0: x0, p1: x1, p2: x2, p3: x3)
            let derivative = cubicDerivative(t: t, p0: x0, p1: x1, p2: x2, p3: x3)
            guard abs(derivative) > 0.000001 else { break }
            let next = t - ((current - x) / derivative)
            guard next >= 0, next <= 1 else { break }
            t = next
            if abs(current - x) < 0.0001 {
                return t
            }
        }

        var low = 0.0
        var high = 1.0
        for _ in 0..<12 {
            t = (low + high) * 0.5
            let current = cubicInterpolate(t: t, p0: x0, p1: x1, p2: x2, p3: x3)
            if current < x {
                low = t
            } else {
                high = t
            }
        }
        return min(max((low + high) * 0.5, 0), 1)
    }

    private func cubicInterpolate(t: Double, p0: Double, p1: Double, p2: Double, p3: Double) -> Double {
        let u = 1 - t
        return (u * u * u * p0) + (3 * u * u * t * p1) + (3 * u * t * t * p2) + (t * t * t * p3)
    }

    private func cubicDerivative(t: Double, p0: Double, p1: Double, p2: Double, p3: Double) -> Double {
        let u = 1 - t
        return (3 * u * u * (p1 - p0)) + (6 * u * t * (p2 - p1)) + (3 * t * t * (p3 - p2))
    }

    private static func number(_ raw: Any?, default defaultValue: Double) -> Double {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String, let parsed = Double(value) { return parsed }
        return defaultValue
    }

    private static func optionalNumber(_ raw: Any?) -> Double? {
        guard raw != nil else { return nil }
        return number(raw, default: 0)
    }

    private static func parseAtlas(
        url: URL,
        textureLoader: MTKTextureLoader
    ) throws -> (pages: [String: AtlasPage], regions: [String: AtlasRegion]) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let baseURL = url.deletingLastPathComponent()

        var pages: [String: AtlasPage] = [:]
        var regions: [String: AtlasRegion] = [:]
        var currentPageName: String?
        var currentPageSize = CGSize(width: 1, height: 1)
        var currentRegionName: String?
        var currentBounds = CGRect.zero
        var currentOffset = CGPoint.zero
        var currentOriginalSize = CGSize.zero
        var currentRotated = false

        func flushRegion() {
            guard let pageName = currentPageName, let regionName = currentRegionName else { return }
            let originalSize: CGSize
            if currentOriginalSize == .zero {
                originalSize = currentBounds.size
            } else {
                originalSize = currentOriginalSize
            }
            regions[regionName] = AtlasRegion(
                name: regionName,
                pageName: pageName,
                bounds: currentBounds,
                offset: currentOffset,
                originalSize: originalSize,
                rotated: currentRotated
            )
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                flushRegion()
                currentRegionName = nil
                currentRotated = false
                currentBounds = .zero
                currentOffset = .zero
                currentOriginalSize = .zero
                continue
            }

            if line.hasSuffix(".png") {
                flushRegion()
                currentRegionName = nil
                currentRotated = false
                currentBounds = .zero
                currentOffset = .zero
                currentOriginalSize = .zero
                currentPageName = line
                currentPageSize = CGSize(width: 1, height: 1)
                continue
            }

            guard let pageName = currentPageName else { continue }

            if line.hasPrefix("size:") {
                let values = parseCSVNumbers(String(line.dropFirst("size:".count)))
                if values.count == 2 {
                    currentPageSize = CGSize(width: values[0], height: values[1])
                    let textureURL = baseURL.appendingPathComponent(pageName)
                    let texture = try textureLoader.newTexture(URL: textureURL, options: [.SRGB: false])
                    pages[pageName] = AtlasPage(name: pageName, size: currentPageSize, texture: texture)
                }
                continue
            }

            if line.hasPrefix("bounds:") {
                let values = parseCSVNumbers(String(line.dropFirst("bounds:".count)))
                if values.count == 4 {
                    currentBounds = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                }
                continue
            }

            if line.hasPrefix("offsets:") {
                let values = parseCSVNumbers(String(line.dropFirst("offsets:".count)))
                if values.count == 4 {
                    currentOffset = CGPoint(x: values[0], y: values[1])
                    currentOriginalSize = CGSize(width: values[2], height: values[3])
                }
                continue
            }

            if line.hasPrefix("rotate:") {
                currentRotated = line.lowercased().contains("90") || line.lowercased().contains("true")
                continue
            }

            if line.contains(":") {
                continue
            }

            flushRegion()
            currentRegionName = line
            currentRotated = false
            currentBounds = .zero
            currentOffset = .zero
            currentOriginalSize = .zero
        }

        flushRegion()
        return (pages, regions)
    }

    private static func parseCSVNumbers(_ text: String) -> [Double] {
        text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func parseBones(root: [String: Any]) throws -> [Bone] {
        guard let rawBones = root["bones"] as? [[String: Any]] else {
            throw EngineError.asset("Spine JSON missing bones")
        }

        var indexByName: [String: Int] = [:]
        var bones: [Bone] = []

        for raw in rawBones {
            guard let name = raw["name"] as? String else {
                throw EngineError.asset("Spine bone missing name")
            }
            let parentName = raw["parent"] as? String
            let parentIndex: Int?
            if let parentName {
                guard let parsedParentIndex = indexByName[parentName] else {
                    throw EngineError.asset("Spine bone \(name) references unknown parent \(parentName)")
                }
                parentIndex = parsedParentIndex
            } else {
                parentIndex = nil
            }
            let bone = Bone(
                name: name,
                parentIndex: parentIndex,
                inherit: raw["inherit"] as? String ?? "normal",
                x: raw["x"] as? Double ?? 0,
                y: raw["y"] as? Double ?? 0,
                rotation: raw["rotation"] as? Double ?? 0,
                scaleX: raw["scaleX"] as? Double ?? 1,
                scaleY: raw["scaleY"] as? Double ?? 1,
                shearX: raw["shearX"] as? Double ?? 0,
                shearY: raw["shearY"] as? Double ?? 0,
                length: raw["length"] as? Double ?? 0
            )
            indexByName[name] = bones.count
            bones.append(bone)
        }

        return bones
    }

    private static func parsePoseConstraints(
        root: [String: Any],
        boneIndexByName: [String: Int]
    ) throws -> [PoseConstraint] {
        var result: [PoseConstraint] = []

        if let rawIkConstraints = root["ik"] as? [[String: Any]] {
            for raw in rawIkConstraints {
                guard let boneNames = raw["bones"] as? [String],
                      let targetName = raw["target"] as? String,
                      let targetIndex = boneIndexByName[targetName] else {
                    continue
                }
                let boneIndices = boneNames.compactMap { boneIndexByName[$0] }
                guard boneIndices.count == boneNames.count else {
                    throw EngineError.asset("Spine IK constraint references an unknown bone")
                }
                result.append(.ik(IkPoseConstraint(
                    order: Int(number(raw["order"], default: 0)),
                    boneIndices: boneIndices,
                    targetIndex: targetIndex,
                    bendDirection: (raw["bendPositive"] as? Bool ?? true) ? 1 : -1,
                    compress: raw["compress"] as? Bool ?? false,
                    stretch: raw["stretch"] as? Bool ?? false,
                    uniform: raw["uniform"] as? Bool ?? false,
                    mix: number(raw["mix"], default: 1),
                    softness: number(raw["softness"], default: 0)
                )))
            }
        }

        if let rawTransformConstraints = root["transform"] as? [[String: Any]] {
            for raw in rawTransformConstraints {
                let usesLocal = raw["local"] as? Bool ?? false
                let usesRelative = raw["relative"] as? Bool ?? false
                guard let boneNames = raw["bones"] as? [String],
                      let targetName = raw["target"] as? String,
                      let targetIndex = boneIndexByName[targetName] else {
                    continue
                }
                let boneIndices = boneNames.compactMap { boneIndexByName[$0] }
                guard boneIndices.count == boneNames.count else {
                    throw EngineError.asset("Spine transform constraint references an unknown bone")
                }

                let mixX = number(raw["mixX"], default: 1)
                let mixScaleX = number(raw["mixScaleX"], default: 1)
                result.append(.transform(TransformPoseConstraint(
                    order: Int(number(raw["order"], default: 0)),
                    boneIndices: boneIndices,
                    targetIndex: targetIndex,
                    offsetRotation: number(raw["rotation"], default: 0),
                    offsetX: number(raw["x"], default: 0),
                    offsetY: number(raw["y"], default: 0),
                    offsetScaleX: number(raw["scaleX"], default: 0),
                    offsetScaleY: number(raw["scaleY"], default: 0),
                    offsetShearY: number(raw["shearY"], default: 0),
                    local: usesLocal,
                    relative: usesRelative,
                    mixRotate: number(raw["mixRotate"], default: 1),
                    mixX: mixX,
                    mixY: number(raw["mixY"], default: mixX),
                    mixScaleX: mixScaleX,
                    mixScaleY: number(raw["mixScaleY"], default: mixScaleX),
                    mixShearY: number(raw["mixShearY"], default: 1)
                )))
            }
        }

        if let rawPathConstraints = root["path"] as? [[String: Any]] {
            for raw in rawPathConstraints {
                guard let boneNames = raw["bones"] as? [String],
                      let targetSlotName = raw["target"] as? String else {
                    continue
                }
                let boneIndices = boneNames.compactMap { boneIndexByName[$0] }
                guard boneIndices.count == boneNames.count else {
                    throw EngineError.asset("Spine path constraint references an unknown bone")
                }
                result.append(.path(PathPoseConstraint(
                    order: Int(number(raw["order"], default: 0)),
                    boneIndices: boneIndices,
                    targetSlotName: targetSlotName,
                    positionMode: raw["positionMode"] as? String ?? "percent",
                    spacingMode: raw["spacingMode"] as? String ?? "length",
                    rotateMode: raw["rotateMode"] as? String ?? "tangent",
                    offsetRotation: number(raw["rotation"], default: 0),
                    position: number(raw["position"], default: 0),
                    spacing: number(raw["spacing"], default: 0),
                    mixRotate: number(raw["mixRotate"], default: 1),
                    mixX: number(raw["mixX"], default: 1),
                    mixY: number(raw["mixY"], default: number(raw["mixX"], default: 1))
                )))
            }
        }

        if let rawPhysicsConstraints = root["physics"] as? [[String: Any]] {
            for raw in rawPhysicsConstraints {
                guard let name = raw["name"] as? String,
                      let boneName = raw["bone"] as? String,
                      let boneIndex = boneIndexByName[boneName] else {
                    continue
                }
                let fps = max(number(raw["fps"], default: 60), 1)
                let mass = max(number(raw["mass"], default: 1), 0.0001)
                result.append(.physics(PhysicsPoseConstraint(
                    name: name,
                    order: Int(number(raw["order"], default: 0)),
                    boneIndex: boneIndex,
                    x: number(raw["x"], default: 0),
                    y: number(raw["y"], default: 0),
                    rotate: number(raw["rotate"], default: 0),
                    scaleX: number(raw["scaleX"], default: 0),
                    shearX: number(raw["shearX"], default: 0),
                    limit: number(raw["limit"], default: 5000),
                    step: 1.0 / fps,
                    inertia: number(raw["inertia"], default: 1),
                    strength: number(raw["strength"], default: 100),
                    damping: number(raw["damping"], default: 1),
                    massInverse: 1.0 / mass,
                    wind: number(raw["wind"], default: 0),
                    gravity: number(raw["gravity"], default: 0),
                    mix: number(raw["mix"], default: 1)
                )))
            }
        }

        return result.sorted { $0.order < $1.order }
    }

    private static func computeBoneWorld(
        _ bones: [Bone],
        constraints: [PoseConstraint] = [],
        slots: [Slot] = [],
        pathAttachments: [String: [String: PathAttachment]] = [:],
        deforms: [String: [String: [Double]]] = [:],
        boneIndexByName: [String: Int] = [:]
    ) -> [BoneWorld] {
        var ignoredPhysicsState: [String: PhysicsRuntimeState] = [:]
        return computeBoneWorld(
            bones,
            constraints: constraints,
            slots: slots,
            pathAttachments: pathAttachments,
            deforms: deforms,
            boneIndexByName: boneIndexByName,
            physicsStateByName: &ignoredPhysicsState,
            skeletonTime: nil,
            enablePhysicsConstraints: false,
            referenceScale: 100
        )
    }

    private static func computeBoneWorld(
        _ bones: [Bone],
        constraints: [PoseConstraint],
        slots: [Slot],
        pathAttachments: [String: [String: PathAttachment]],
        deforms: [String: [String: [Double]]],
        boneIndexByName: [String: Int],
        physicsStateByName: inout [String: PhysicsRuntimeState],
        skeletonTime: Double?,
        enablePhysicsConstraints: Bool,
        referenceScale: Double
    ) -> [BoneWorld] {
        var states = bones.map { bone in
            BonePoseState(
                parentIndex: bone.parentIndex,
                inherit: bone.inherit,
                length: bone.length,
                x: bone.x,
                y: bone.y,
                rotation: bone.rotation,
                scaleX: bone.scaleX,
                scaleY: bone.scaleY,
                shearX: bone.shearX,
                shearY: bone.shearY
            )
        }

        updateAllBoneWorlds(&states)

        for constraint in constraints {
            switch constraint {
            case .ik(let ikConstraint):
                applyIkConstraint(ikConstraint, to: &states)
            case .transform(let transformConstraint):
                applyTransformConstraint(transformConstraint, to: &states)
            case .path(let pathConstraint):
                guard enablePathConstraints else { break }
                applyPathConstraint(
                    pathConstraint,
                    to: &states,
                    slots: slots,
                    pathAttachments: pathAttachments,
                    deforms: deforms,
                    boneIndexByName: boneIndexByName
                )
            case .physics(let physicsConstraint):
                guard enablePhysicsConstraints else { break }
                if let skeletonTime {
                    applyPhysicsConstraint(
                        physicsConstraint,
                        to: &states,
                        stateByName: &physicsStateByName,
                        skeletonTime: skeletonTime,
                        referenceScale: referenceScale
                    )
                }
            }
            updateAllBoneWorlds(&states)
        }

        return states.map(\.world)
    }

    private static func updateAllBoneWorlds(_ states: inout [BonePoseState]) {
        for index in states.indices {
            updateBoneWorld(index: index, states: &states)
        }
    }

    private static func updateBoneWorld(index: Int, states: inout [BonePoseState]) {
        let state = states[index]
        let local = localWorldTransform(
            rotation: state.rotation,
            scaleX: state.scaleX,
            scaleY: state.scaleY,
            shearX: state.shearX,
            shearY: state.shearY,
            x: state.x,
            y: state.y
        )

        let world: BoneWorld
        if let parentIndex = state.parentIndex, parentIndex < states.count {
            let parent = states[parentIndex].world
            let translated = CGPoint(
                x: parent.a * local.tx + parent.c * local.ty + parent.tx,
                y: parent.b * local.tx + parent.d * local.ty + parent.ty
            )

            switch state.inherit {
            case "onlyTranslation":
                world = BoneWorld(
                    a: local.a,
                    b: local.b,
                    c: local.c,
                    d: local.d,
                    tx: translated.x,
                    ty: translated.y
                )
            case "noScale", "noScaleOrReflection":
                world = noScaleWorldTransform(
                    parent: parent,
                    rotation: state.rotation,
                    scaleX: state.scaleX,
                    scaleY: state.scaleY,
                    shearX: state.shearX,
                    shearY: state.shearY,
                    preserveReflection: state.inherit == "noScale",
                    tx: translated.x,
                    ty: translated.y
                )
            default:
                world = BoneWorld(
                    a: parent.a * local.a + parent.c * local.b,
                    b: parent.b * local.a + parent.d * local.b,
                    c: parent.a * local.c + parent.c * local.d,
                    d: parent.b * local.c + parent.d * local.d,
                    tx: translated.x,
                    ty: translated.y
                )
            }
        } else {
            world = local
        }

        states[index].a = world.a
        states[index].b = world.b
        states[index].c = world.c
        states[index].d = world.d
        states[index].tx = world.tx
        states[index].ty = world.ty
    }

    private static func applyIkConstraint(_ constraint: IkPoseConstraint, to states: inout [BonePoseState]) {
        if constraint.boneIndices.count == 2 {
            applyTwoBoneIkConstraint(constraint, to: &states)
            return
        }
        guard constraint.mix != 0,
              constraint.boneIndices.count == 1,
              let boneIndex = constraint.boneIndices.first,
              boneIndex < states.count,
              constraint.targetIndex < states.count,
              let parentIndex = states[boneIndex].parentIndex,
              parentIndex < states.count else {
            return
        }

        var bone = states[boneIndex]
        let parent = states[parentIndex]
        let target = states[constraint.targetIndex]
        var rotationIK = -bone.shearX - bone.rotation
        var targetX = 0.0
        var targetY = 0.0

        if bone.inherit == "onlyTranslation" {
            targetX = target.tx - bone.tx
            targetY = target.ty - bone.ty
        } else {
            let determinant = parent.a * parent.d - parent.c * parent.b
            guard abs(determinant) > 0.0001 else { return }
            let dx = target.tx - parent.tx
            let dy = target.ty - parent.ty
            targetX = (dx * parent.d - dy * parent.c) / determinant - bone.x
            targetY = (dy * parent.a - dx * parent.b) / determinant - bone.y
        }

        rotationIK += atan2(targetY, targetX) * 180.0 / .pi
        if bone.scaleX < 0 {
            rotationIK += 180
        }
        rotationIK = normalizeDegrees(rotationIK)

        var scaleX = bone.scaleX
        var scaleY = bone.scaleY
        if constraint.compress || constraint.stretch {
            let baseLength = bone.length * scaleX
            if abs(baseLength) > 0.0001 {
                if bone.inherit == "noScale" || bone.inherit == "noScaleOrReflection" {
                    targetX = target.tx - bone.tx
                    targetY = target.ty - bone.ty
                }
                let distanceSquared = targetX * targetX + targetY * targetY
                let lengthSquared = baseLength * baseLength
                if (constraint.compress && distanceSquared < lengthSquared) ||
                    (constraint.stretch && distanceSquared > lengthSquared) {
                    let scale = (sqrt(distanceSquared) / baseLength - 1) * constraint.mix + 1
                    scaleX *= scale
                    if constraint.uniform {
                        scaleY *= scale
                    }
                }
            }
        }

        bone.rotation += rotationIK * constraint.mix
        bone.scaleX = scaleX
        bone.scaleY = scaleY
        states[boneIndex] = bone
    }

    private static func applyTwoBoneIkConstraint(_ constraint: IkPoseConstraint, to states: inout [BonePoseState]) {
        guard constraint.mix != 0,
              constraint.boneIndices.count == 2,
              let parentIndex = constraint.boneIndices.first,
              let childIndex = constraint.boneIndices.last,
              parentIndex < states.count,
              childIndex < states.count,
              constraint.targetIndex < states.count,
              states[childIndex].parentIndex == parentIndex else {
            return
        }

        let target = states[constraint.targetIndex]
        let targetLocal: CGPoint
        if let grandParentIndex = states[parentIndex].parentIndex, grandParentIndex < states.count {
            let grandParent = states[grandParentIndex]
            let determinant = grandParent.a * grandParent.d - grandParent.c * grandParent.b
            guard abs(determinant) > 0.0001 else { return }
            let dx = target.tx - grandParent.tx
            let dy = target.ty - grandParent.ty
            targetLocal = CGPoint(
                x: (dx * grandParent.d - dy * grandParent.c) / determinant,
                y: (dy * grandParent.a - dx * grandParent.b) / determinant
            )
        } else {
            targetLocal = CGPoint(x: target.tx, y: target.ty)
        }

        var parent = states[parentIndex]
        let child = states[childIndex]
        let toTargetX = targetLocal.x - parent.x
        let toTargetY = targetLocal.y - parent.y
        let targetDistance = sqrt(toTargetX * toTargetX + toTargetY * toTargetY)
        guard targetDistance > 0.0001 else { return }

        let childOffsetLength = sqrt(child.x * child.x + child.y * child.y)
        let firstLength = max(childOffsetLength, abs(parent.length * parent.scaleX), 0.0001)
        let secondLength = max(abs(child.length * child.scaleX), 0.0001)
        let cosSecond = min(max(
            (targetDistance * targetDistance - firstLength * firstLength - secondLength * secondLength) /
                (2 * firstLength * secondLength),
            -1
        ), 1)
        let secondAngle = acos(cosSecond) * (constraint.bendDirection >= 0 ? 1 : -1)
        let firstAngle = atan2(toTargetY, toTargetX) -
            atan2(secondLength * sin(secondAngle), firstLength + secondLength * cos(secondAngle))
        let childSetupAngle = atan2(child.y, child.x) * 180.0 / .pi
        let desiredParentRotation = firstAngle * 180.0 / .pi - childSetupAngle - parent.shearX
        parent.rotation += normalizeDegrees(desiredParentRotation - parent.rotation) * constraint.mix
        states[parentIndex] = parent
        updateBoneWorld(index: parentIndex, states: &states)
        updateBoneWorld(index: childIndex, states: &states)

        let updatedParent = states[parentIndex]
        var updatedChild = states[childIndex]
        let childTargetX = target.tx - updatedChild.tx
        let childTargetY = target.ty - updatedChild.ty
        guard abs(childTargetX) > 0.0001 || abs(childTargetY) > 0.0001 else { return }
        let desiredChildWorldRotation = atan2(childTargetY, childTargetX) * 180.0 / .pi
        let parentWorldRotation = atan2(updatedParent.b, updatedParent.a) * 180.0 / .pi
        let desiredChildRotation = desiredChildWorldRotation - parentWorldRotation - updatedChild.shearX
        updatedChild.rotation += normalizeDegrees(desiredChildRotation - updatedChild.rotation) * constraint.mix
        states[childIndex] = updatedChild
    }

    private static func applyTransformConstraint(_ constraint: TransformPoseConstraint, to states: inout [BonePoseState]) {
        guard constraint.targetIndex < states.count,
              constraint.mixRotate != 0 || constraint.mixX != 0 || constraint.mixY != 0 ||
              constraint.mixScaleX != 0 || constraint.mixScaleY != 0 || constraint.mixShearY != 0 else {
            return
        }

        if constraint.local {
            if constraint.relative {
                applyRelativeLocalTransformConstraint(constraint, to: &states)
            } else {
                applyAbsoluteLocalTransformConstraint(constraint, to: &states)
            }
            return
        }

        if constraint.relative {
            applyRelativeWorldTransformConstraint(constraint, to: &states)
            return
        }

        applyAbsoluteWorldTransformConstraint(constraint, to: &states)
    }

    private static func applyAbsoluteWorldTransformConstraint(
        _ constraint: TransformPoseConstraint,
        to states: inout [BonePoseState]
    ) {
        let target = states[constraint.targetIndex]
        let targetDeterminant = target.a * target.d - target.c * target.b
        let reflectRadians = targetDeterminant > 0 ? (.pi / 180.0) : (-.pi / 180.0)
        let offsetRotation = constraint.offsetRotation * reflectRadians
        let offsetShearY = constraint.offsetShearY * reflectRadians

        for boneIndex in constraint.boneIndices where boneIndex < states.count {
            if constraint.mixRotate != 0 {
                let angle = normalizeRadians(
                    atan2(target.b, target.a) -
                    atan2(states[boneIndex].b, states[boneIndex].a) +
                    offsetRotation
                ) * constraint.mixRotate
                rotateWorld(index: boneIndex, radians: angle, states: &states)
            }

            if constraint.mixX != 0 || constraint.mixY != 0 {
                let targetPoint = localToWorld(
                    x: constraint.offsetX,
                    y: constraint.offsetY,
                    state: target
                )
                states[boneIndex].tx += (targetPoint.x - states[boneIndex].tx) * constraint.mixX
                states[boneIndex].ty += (targetPoint.y - states[boneIndex].ty) * constraint.mixY
            }

            if constraint.mixScaleX != 0 {
                let currentScale = sqrt(states[boneIndex].a * states[boneIndex].a + states[boneIndex].b * states[boneIndex].b)
                if currentScale != 0 {
                    let targetScale = sqrt(target.a * target.a + target.b * target.b)
                    let factor = (currentScale + (targetScale - currentScale + constraint.offsetScaleX) * constraint.mixScaleX) / currentScale
                    states[boneIndex].a *= factor
                    states[boneIndex].b *= factor
                }
            }

            if constraint.mixScaleY != 0 {
                let currentScale = sqrt(states[boneIndex].c * states[boneIndex].c + states[boneIndex].d * states[boneIndex].d)
                if currentScale != 0 {
                    let targetScale = sqrt(target.c * target.c + target.d * target.d)
                    let factor = (currentScale + (targetScale - currentScale + constraint.offsetScaleY) * constraint.mixScaleY) / currentScale
                    states[boneIndex].c *= factor
                    states[boneIndex].d *= factor
                }
            }

            if constraint.mixShearY > 0 {
                let yAxisAngle = atan2(states[boneIndex].d, states[boneIndex].c)
                let delta = normalizeRadians(
                    atan2(target.d, target.c) -
                    atan2(target.b, target.a) -
                    (yAxisAngle - atan2(states[boneIndex].b, states[boneIndex].a))
                )
                let mixedAngle = yAxisAngle + (delta + offsetShearY) * constraint.mixShearY
                let scale = sqrt(states[boneIndex].c * states[boneIndex].c + states[boneIndex].d * states[boneIndex].d)
                states[boneIndex].c = cos(mixedAngle) * scale
                states[boneIndex].d = sin(mixedAngle) * scale
            }

            updateAppliedTransform(index: boneIndex, states: &states)
            updateAllBoneWorlds(&states)
        }
    }

    private static func applyRelativeWorldTransformConstraint(
        _ constraint: TransformPoseConstraint,
        to states: inout [BonePoseState]
    ) {
        let target = states[constraint.targetIndex]
        let targetDeterminant = target.a * target.d - target.c * target.b
        let reflectRadians = targetDeterminant > 0 ? (.pi / 180.0) : (-.pi / 180.0)
        let offsetRotation = constraint.offsetRotation * reflectRadians
        let offsetShearY = constraint.offsetShearY * reflectRadians

        for boneIndex in constraint.boneIndices where boneIndex < states.count {
            if constraint.mixRotate != 0 {
                let angle = (atan2(target.b, target.a) + offsetRotation) * constraint.mixRotate
                rotateWorld(index: boneIndex, radians: angle, states: &states)
            }

            if constraint.mixX != 0 || constraint.mixY != 0 {
                let targetPoint = localToWorld(
                    x: constraint.offsetX,
                    y: constraint.offsetY,
                    state: target
                )
                states[boneIndex].tx += targetPoint.x * constraint.mixX
                states[boneIndex].ty += targetPoint.y * constraint.mixY
            }

            if constraint.mixScaleX != 0 {
                let currentScale = sqrt(states[boneIndex].a * states[boneIndex].a + states[boneIndex].b * states[boneIndex].b)
                if currentScale != 0 {
                    let targetScale = sqrt(target.a * target.a + target.b * target.b)
                    let factor = ((targetScale - 1 + constraint.offsetScaleX) * constraint.mixScaleX + 1) / currentScale
                    states[boneIndex].a *= factor
                    states[boneIndex].b *= factor
                }
            }

            if constraint.mixScaleY != 0 {
                let currentScale = sqrt(states[boneIndex].c * states[boneIndex].c + states[boneIndex].d * states[boneIndex].d)
                if currentScale != 0 {
                    let targetScale = sqrt(target.c * target.c + target.d * target.d)
                    let factor = ((targetScale - 1 + constraint.offsetScaleY) * constraint.mixScaleY + 1) / currentScale
                    states[boneIndex].c *= factor
                    states[boneIndex].d *= factor
                }
            }

            if constraint.mixShearY > 0 {
                let yAxisAngle = atan2(states[boneIndex].d, states[boneIndex].c)
                let targetShearDelta = normalizeRadians(atan2(target.d, target.c) - atan2(target.b, target.a))
                let mixedAngle = yAxisAngle + (targetShearDelta + offsetShearY) * constraint.mixShearY
                let scale = sqrt(states[boneIndex].c * states[boneIndex].c + states[boneIndex].d * states[boneIndex].d)
                states[boneIndex].c = cos(mixedAngle) * scale
                states[boneIndex].d = sin(mixedAngle) * scale
            }

            updateAppliedTransform(index: boneIndex, states: &states)
            updateAllBoneWorlds(&states)
        }
    }

    private static func applyAbsoluteLocalTransformConstraint(
        _ constraint: TransformPoseConstraint,
        to states: inout [BonePoseState]
    ) {
        let target = states[constraint.targetIndex]
        for boneIndex in constraint.boneIndices where boneIndex < states.count {
            var bone = states[boneIndex]
            if constraint.mixRotate != 0 {
                bone.rotation += normalizeDegrees(
                    target.rotation - bone.rotation + constraint.offsetRotation
                ) * constraint.mixRotate
            }
            if constraint.mixX != 0 {
                bone.x += (target.x - bone.x + constraint.offsetX) * constraint.mixX
            }
            if constraint.mixY != 0 {
                bone.y += (target.y - bone.y + constraint.offsetY) * constraint.mixY
            }
            if constraint.mixScaleX != 0 {
                bone.scaleX += (target.scaleX - bone.scaleX + constraint.offsetScaleX) * constraint.mixScaleX
            }
            if constraint.mixScaleY != 0 {
                bone.scaleY += (target.scaleY - bone.scaleY + constraint.offsetScaleY) * constraint.mixScaleY
            }
            if constraint.mixShearY != 0 {
                bone.shearY += (target.shearY - bone.shearY + constraint.offsetShearY) * constraint.mixShearY
            }
            states[boneIndex] = bone
            updateAllBoneWorlds(&states)
        }
    }

    private static func applyRelativeLocalTransformConstraint(
        _ constraint: TransformPoseConstraint,
        to states: inout [BonePoseState]
    ) {
        let target = states[constraint.targetIndex]
        for boneIndex in constraint.boneIndices where boneIndex < states.count {
            var bone = states[boneIndex]
            if constraint.mixRotate != 0 {
                bone.rotation += (target.rotation + constraint.offsetRotation) * constraint.mixRotate
            }
            if constraint.mixX != 0 {
                bone.x += (target.x + constraint.offsetX) * constraint.mixX
            }
            if constraint.mixY != 0 {
                bone.y += (target.y + constraint.offsetY) * constraint.mixY
            }
            if constraint.mixScaleX != 0 {
                bone.scaleX += (target.scaleX - 1 + constraint.offsetScaleX) * constraint.mixScaleX
            }
            if constraint.mixScaleY != 0 {
                bone.scaleY += (target.scaleY - 1 + constraint.offsetScaleY) * constraint.mixScaleY
            }
            if constraint.mixShearY != 0 {
                bone.shearY += (target.shearY + constraint.offsetShearY) * constraint.mixShearY
            }
            states[boneIndex] = bone
            updateAllBoneWorlds(&states)
        }
    }

    private static func applyPathConstraint(
        _ constraint: PathPoseConstraint,
        to states: inout [BonePoseState],
        slots: [Slot],
        pathAttachments: [String: [String: PathAttachment]],
        deforms: [String: [String: [Double]]],
        boneIndexByName: [String: Int]
    ) {
        guard constraint.mixRotate != 0 || constraint.mixX != 0 || constraint.mixY != 0,
              constraint.boneIndices.isEmpty == false,
              let targetSlot = slots.first(where: { $0.name == constraint.targetSlotName }),
              let attachmentName = targetSlot.attachment,
              let path = pathAttachments[targetSlot.name]?[attachmentName] else {
            return
        }

        let targetBoneState: BonePoseState?
        if let boneName = targetSlot.boneName, let boneIndex = boneIndexByName[boneName], boneIndex < states.count {
            targetBoneState = states[boneIndex]
        } else {
            targetBoneState = nil
        }

        let curves = pathCurves(
            attachment: path,
            states: states,
            slotBone: targetBoneState,
            deform: deforms[targetSlot.name]?[attachmentName] ?? []
        )
        guard curves.isEmpty == false, let pathLength = curves.last?.cumulativeLength, pathLength > 0 else {
            return
        }

        let rotateMode = constraint.rotateMode.lowercased()
        let spacingMode = constraint.spacingMode.lowercased()
        let positionMode = constraint.positionMode.lowercased()
        let tangents = rotateMode == "tangent"
        let scalesAlongPath = rotateMode == "chainscale"
        let boneCount = constraint.boneIndices.count
        let spacesCount = tangents ? boneCount : boneCount + 1
        var spaces = [Double](repeating: 0, count: spacesCount)
        var lengths = [Double](repeating: 0, count: boneCount)

        switch spacingMode {
        case "percent":
            for index in 0..<(spacesCount - 1) {
                if scalesAlongPath {
                    lengths[index] = currentBoneLength(states[constraint.boneIndices[index]])
                }
                spaces[index + 1] = constraint.spacing
            }
        case "proportional":
            var sum = 0.0
            for index in 0..<(spacesCount - 1) {
                let bone = states[constraint.boneIndices[index]]
                let setupLength = bone.length
                if abs(setupLength) < 0.00001 {
                    if scalesAlongPath {
                        lengths[index] = 0
                    }
                    spaces[index + 1] = constraint.spacing
                } else {
                    let currentLength = currentBoneLength(bone)
                    if scalesAlongPath {
                        lengths[index] = currentLength
                    }
                    spaces[index + 1] = currentLength
                    sum += currentLength
                }
            }
            if sum > 0 {
                let scale = Double(spacesCount) / sum * constraint.spacing
                for index in 1..<spacesCount {
                    spaces[index] *= scale
                }
            }
        default:
            let lengthSpacing = spacingMode == "length"
            for index in 0..<(spacesCount - 1) {
                let bone = states[constraint.boneIndices[index]]
                let setupLength = bone.length
                if abs(setupLength) < 0.00001 {
                    if scalesAlongPath {
                        lengths[index] = 0
                    }
                    spaces[index + 1] = constraint.spacing
                } else {
                    let currentLength = currentBoneLength(bone)
                    if scalesAlongPath {
                        lengths[index] = currentLength
                    }
                    let requested = lengthSpacing ? setupLength + constraint.spacing : constraint.spacing
                    spaces[index + 1] = requested * currentLength / setupLength
                }
            }
        }

        let positions = pathPositions(
            curves: curves,
            pathLength: pathLength,
            closed: path.closed,
            position: positionMode == "percent" ? constraint.position * pathLength : constraint.position,
            spaces: spaces,
            spacingMode: spacingMode
        )
        guard positions.count >= spacesCount * 3 else {
            return
        }

        var boneX = positions[0]
        var boneY = positions[1]
        var offsetRotation = constraint.offsetRotation * .pi / 180.0
        let tip = constraint.offsetRotation == 0 && rotateMode == "chain"
        if constraint.offsetRotation != 0, let targetBoneState {
            let determinant = targetBoneState.a * targetBoneState.d - targetBoneState.c * targetBoneState.b
            offsetRotation *= determinant >= 0 ? 1 : -1
        }

        for index in 0..<boneCount {
            let boneIndex = constraint.boneIndices[index]
            guard boneIndex < states.count else { continue }
            let positionIndex = 3 + (index * 3)
            guard positionIndex + 1 < positions.count else { continue }

            states[boneIndex].tx += (boneX - states[boneIndex].tx) * constraint.mixX
            states[boneIndex].ty += (boneY - states[boneIndex].ty) * constraint.mixY

            let nextX = positions[positionIndex]
            let nextY = positions[positionIndex + 1]
            let dx = nextX - boneX
            let dy = nextY - boneY

            if scalesAlongPath {
                let length = lengths[index]
                if abs(length) > 0.00001 {
                    let scale = (sqrt(dx * dx + dy * dy) / length - 1) * constraint.mixRotate + 1
                    states[boneIndex].a *= scale
                    states[boneIndex].b *= scale
                }
            }

            boneX = nextX
            boneY = nextY

            if constraint.mixRotate > 0 {
                let tangentIndex = positionIndex + 2
                let radians: Double
                if tangents {
                    radians = positions[max(positionIndex - 1, 0)]
                } else if index + 1 < spaces.count, spaces[index + 1] == 0, tangentIndex < positions.count {
                    radians = positions[tangentIndex]
                } else {
                    radians = atan2(dy, dx)
                }

                var rotation = radians - atan2(states[boneIndex].b, states[boneIndex].a)
                if tip {
                    let cosValue = cos(rotation)
                    let sinValue = sin(rotation)
                    let length = states[boneIndex].length
                    boneX += (length * (cosValue * states[boneIndex].a - sinValue * states[boneIndex].b) - dx) * constraint.mixRotate
                    boneY += (length * (sinValue * states[boneIndex].a + cosValue * states[boneIndex].b) - dy) * constraint.mixRotate
                } else {
                    rotation += offsetRotation
                }

                rotateWorld(index: boneIndex, radians: normalizeRadians(rotation) * constraint.mixRotate, states: &states)
            }

            updateAppliedTransform(index: boneIndex, states: &states)
        }
    }

    private static func applyPhysicsConstraint(
        _ constraint: PhysicsPoseConstraint,
        to states: inout [BonePoseState],
        stateByName: inout [String: PhysicsRuntimeState],
        skeletonTime: Double,
        referenceScale: Double
    ) {
        guard constraint.boneIndex < states.count, constraint.mix != 0 else { return }

        let hasX = constraint.x > 0
        let hasY = constraint.y > 0
        let hasRotation = constraint.rotate > 0 || constraint.shearX > 0
        let hasScale = constraint.scaleX > 0
        guard hasX || hasY || hasRotation || hasScale else { return }

        var runtime = stateByName[constraint.name] ?? PhysicsRuntimeState()
        if stateByName[constraint.name] == nil {
            runtime.lastTime = skeletonTime
        }

        let step = max(constraint.step, 1.0 / 240.0)
        let delta = min(max(skeletonTime - runtime.lastTime, 0), 0.25)
        runtime.remaining = min(runtime.remaining + delta, 0.5)
        runtime.lastTime = skeletonTime

        let boneIndex = constraint.boneIndex
        let boneX = states[boneIndex].tx
        let boneY = states[boneIndex].ty

        if runtime.needsReset {
            runtime.needsReset = false
            runtime.ux = boneX
            runtime.uy = boneY
        } else {
            var remaining = runtime.remaining
            let inertia = constraint.inertia
            var dampingFactor = -1.0
            var limitX = constraint.limit * delta
            let limitY = limitX
            limitX *= 1

            if hasX || hasY {
                if hasX {
                    let offset = (runtime.ux - boneX) * inertia
                    runtime.xOffset += max(-limitX, min(limitX, offset))
                    runtime.ux = boneX
                }
                if hasY {
                    let offset = (runtime.uy - boneY) * inertia
                    runtime.yOffset += max(-limitY, min(limitY, offset))
                    runtime.uy = boneY
                }
                if remaining >= step {
                    dampingFactor = pow(constraint.damping, 60 * step)
                    let massStep = constraint.massInverse * step
                    let strength = constraint.strength
                    let wind = constraint.wind * referenceScale
                    let gravity = constraint.gravity * referenceScale
                    repeat {
                        if hasX {
                            runtime.xVelocity += (wind - runtime.xOffset * strength) * massStep
                            runtime.xOffset += runtime.xVelocity * step
                            runtime.xVelocity *= dampingFactor
                        }
                        if hasY {
                            runtime.yVelocity -= (gravity + runtime.yOffset * strength) * massStep
                            runtime.yOffset += runtime.yVelocity * step
                            runtime.yVelocity *= dampingFactor
                        }
                        remaining -= step
                    } while remaining >= step
                }
                if hasX {
                    states[boneIndex].tx += runtime.xOffset * constraint.mix * constraint.x
                }
                if hasY {
                    states[boneIndex].ty += runtime.yOffset * constraint.mix * constraint.y
                }
            }

            if hasRotation || hasScale {
                let current = states[boneIndex]
                let axisAngle = atan2(current.b, current.a)
                var dx = max(-limitX, min(limitX, runtime.cx - current.tx))
                var dy = max(-limitY, min(limitY, runtime.cy - current.ty))
                if delta == 0 {
                    dx = 0
                    dy = 0
                }

                var axisCos = cos(axisAngle)
                var axisSin = sin(axisAngle)
                let mixedRotation = (constraint.rotate + constraint.shearX) * constraint.mix
                if hasRotation {
                    let targetAngle = atan2(dy + runtime.ty, dx + runtime.tx)
                    let rotationDelta = targetAngle - axisAngle - runtime.rotateOffset * mixedRotation
                    runtime.rotateOffset += normalizeRadians(rotationDelta) * inertia
                    let updatedAngle = runtime.rotateOffset * mixedRotation + axisAngle
                    axisCos = cos(updatedAngle)
                    axisSin = sin(updatedAngle)
                }

                if hasScale {
                    let scaledLength = current.length * sqrt(current.a * current.a + current.b * current.b)
                    if scaledLength > 0 {
                        runtime.scaleOffset += (dx * axisCos + dy * axisSin) * inertia / scaledLength
                    }
                }

                remaining = runtime.remaining
                if remaining >= step {
                    if dampingFactor < 0 {
                        dampingFactor = pow(constraint.damping, 60 * step)
                    }
                    let massStep = constraint.massInverse * step
                    let strength = constraint.strength
                    let wind = constraint.wind
                    let gravity = constraint.gravity
                    let lengthFactor = states[boneIndex].length / max(referenceScale, 0.0001)
                    repeat {
                        remaining -= step
                        if hasScale {
                            runtime.scaleVelocity += (wind * axisCos - gravity * axisSin - runtime.scaleOffset * strength) * massStep
                            runtime.scaleOffset += runtime.scaleVelocity * step
                            runtime.scaleVelocity *= dampingFactor
                        }
                        if hasRotation {
                            runtime.rotateVelocity -= ((wind * axisSin + gravity * axisCos) * lengthFactor + runtime.rotateOffset * strength) * massStep
                            runtime.rotateOffset += runtime.rotateVelocity * step
                            runtime.rotateVelocity *= dampingFactor
                            if remaining >= step {
                                let updatedAngle = runtime.rotateOffset * mixedRotation + axisAngle
                                axisCos = cos(updatedAngle)
                                axisSin = sin(updatedAngle)
                            }
                        }
                    } while remaining >= step
                }
            }

            runtime.remaining = remaining
        }

        runtime.cx = states[boneIndex].tx
        runtime.cy = states[boneIndex].ty

        if hasRotation {
            let influence = constraint.rotate > 0 ? constraint.rotate : constraint.shearX
            rotateWorld(index: boneIndex, radians: runtime.rotateOffset * constraint.mix * influence, states: &states)
        }
        if hasScale {
            let scale = 1 + runtime.scaleOffset * constraint.mix * constraint.scaleX
            states[boneIndex].a *= scale
            states[boneIndex].b *= scale
        }

        runtime.tx = states[boneIndex].length * states[boneIndex].a
        runtime.ty = states[boneIndex].length * states[boneIndex].b
        updateAppliedTransform(index: boneIndex, states: &states)
        stateByName[constraint.name] = runtime
    }

    private static func currentBoneLength(_ bone: BonePoseState) -> Double {
        let x = bone.length * bone.a
        let y = bone.length * bone.b
        return sqrt(x * x + y * y)
    }

    private static func pathCurves(
        attachment: PathAttachment,
        states: [BonePoseState],
        slotBone: BonePoseState?,
        deform: [Double]
    ) -> [PathCurve] {
        let worldValuesLength = attachment.vertexCount * 2
        guard worldValuesLength >= 8 else { return [] }
        let allValues = allPathWorldValues(attachment: attachment, states: states, slotBone: slotBone, deform: deform)
        guard allValues.count >= worldValuesLength else { return [] }

        let curveCount: Int
        let worldValues: [Double]
        if attachment.closed {
            curveCount = max(0, worldValuesLength / 6)
            var values = sliceWorldValues(allValues, start: 2, count: max(0, worldValuesLength - 2))
            values.append(contentsOf: sliceWorldValues(allValues, start: 0, count: 2))
            if values.count >= 2 {
                values.append(values[0])
                values.append(values[1])
            }
            worldValues = values
        } else {
            curveCount = max(0, worldValuesLength / 6 - 1)
            worldValues = sliceWorldValues(allValues, start: 2, count: max(0, worldValuesLength - 4))
        }

        guard curveCount > 0, worldValues.count >= curveCount * 6 + 2 else {
            return []
        }

        var result: [PathCurve] = []
        result.reserveCapacity(curveCount)
        var cumulativeLength = 0.0
        for index in 0..<curveCount {
            let base = index * 6
            let x1 = worldValues[base]
            let y1 = worldValues[base + 1]
            let cx1 = worldValues[base + 2]
            let cy1 = worldValues[base + 3]
            let cx2 = worldValues[base + 4]
            let cy2 = worldValues[base + 5]
            let x2 = worldValues[base + 6]
            let y2 = worldValues[base + 7]
            let samples = cubicLengthSamples(
                x1: x1,
                y1: y1,
                cx1: cx1,
                cy1: cy1,
                cx2: cx2,
                cy2: cy2,
                x2: x2,
                y2: y2
            )
            cumulativeLength += samples.last ?? 0
            result.append(PathCurve(
                x1: x1,
                y1: y1,
                cx1: cx1,
                cy1: cy1,
                cx2: cx2,
                cy2: cy2,
                x2: x2,
                y2: y2,
                cumulativeLength: cumulativeLength,
                samples: samples
            ))
        }
        return result
    }

    private static func pathPositions(
        curves: [PathCurve],
        pathLength: Double,
        closed: Bool,
        position: Double,
        spaces: [Double],
        spacingMode: String
    ) -> [Double] {
        let multiplier: Double
        switch spacingMode {
        case "percent":
            multiplier = pathLength
        case "proportional":
            multiplier = pathLength / Double(max(spaces.count, 1))
        default:
            multiplier = 1
        }

        var output = [Double](repeating: 0, count: spaces.count * 3)
        var cursor = position
        for index in spaces.indices {
            cursor += spaces[index] * multiplier
            let sampled: (x: Double, y: Double, angle: Double)

            if closed {
                var wrapped = cursor.truncatingRemainder(dividingBy: pathLength)
                if wrapped < 0 {
                    wrapped += pathLength
                }
                sampled = samplePath(curves: curves, distance: wrapped)
            } else if cursor < 0, let first = curves.first {
                let angle = atan2(first.cy1 - first.y1, first.cx1 - first.x1)
                sampled = (
                    first.x1 + cursor * cos(angle),
                    first.y1 + cursor * sin(angle),
                    angle
                )
            } else if cursor > pathLength, let last = curves.last {
                let angle = atan2(last.y2 - last.cy2, last.x2 - last.cx2)
                let overshoot = cursor - pathLength
                sampled = (
                    last.x2 + overshoot * cos(angle),
                    last.y2 + overshoot * sin(angle),
                    angle
                )
            } else {
                sampled = samplePath(curves: curves, distance: cursor)
            }

            let outputIndex = index * 3
            output[outputIndex] = sampled.x
            output[outputIndex + 1] = sampled.y
            output[outputIndex + 2] = sampled.angle
        }
        return output
    }

    private static func samplePath(curves: [PathCurve], distance: Double) -> (x: Double, y: Double, angle: Double) {
        guard let first = curves.first else {
            return (0, 0, 0)
        }
        let lastLength = curves.last?.cumulativeLength ?? first.cumulativeLength
        let clampedDistance = max(0, min(distance, lastLength))
        var previousCumulative = 0.0
        for (curveIndex, curve) in curves.enumerated() {
            if clampedDistance <= curve.cumulativeLength || curveIndex == curves.count - 1 {
                let localDistance = max(0, clampedDistance - previousCumulative)
                let t = cubicParameter(for: localDistance, samples: curve.samples)
                let point = cubicPoint(
                    t: t,
                    x1: curve.x1,
                    y1: curve.y1,
                    cx1: curve.cx1,
                    cy1: curve.cy1,
                    cx2: curve.cx2,
                    cy2: curve.cy2,
                    x2: curve.x2,
                    y2: curve.y2
                )
                let tangent = cubicTangent(
                    t: t,
                    x1: curve.x1,
                    y1: curve.y1,
                    cx1: curve.cx1,
                    cy1: curve.cy1,
                    cx2: curve.cx2,
                    cy2: curve.cy2,
                    x2: curve.x2,
                    y2: curve.y2
                )
                return (point.x, point.y, atan2(tangent.y, tangent.x))
            }
            previousCumulative = curve.cumulativeLength
        }
        return (first.x1, first.y1, atan2(first.cy1 - first.y1, first.cx1 - first.x1))
    }

    private static func cubicParameter(for distance: Double, samples: [Double]) -> Double {
        guard samples.isEmpty == false else { return 0 }
        let steps = samples.count
        var previous = 0.0
        for index in samples.indices {
            let current = samples[index]
            if distance <= current || index == samples.count - 1 {
                let segmentLength = current - previous
                let ratio = segmentLength > 0 ? (distance - previous) / segmentLength : 0
                return (Double(index) + max(0, min(ratio, 1))) / Double(steps)
            }
            previous = current
        }
        return 1
    }

    private static func cubicLengthSamples(
        x1: Double,
        y1: Double,
        cx1: Double,
        cy1: Double,
        cx2: Double,
        cy2: Double,
        x2: Double,
        y2: Double
    ) -> [Double] {
        let steps = 20
        var samples: [Double] = []
        samples.reserveCapacity(steps)
        var previous = CGPoint(x: x1, y: y1)
        var cumulative = 0.0
        for step in 1...steps {
            let point = cubicPoint(
                t: Double(step) / Double(steps),
                x1: x1,
                y1: y1,
                cx1: cx1,
                cy1: cy1,
                cx2: cx2,
                cy2: cy2,
                x2: x2,
                y2: y2
            )
            let dx = point.x - previous.x
            let dy = point.y - previous.y
            cumulative += sqrt(dx * dx + dy * dy)
            samples.append(cumulative)
            previous = point
        }
        return samples
    }

    private static func cubicPoint(
        t: Double,
        x1: Double,
        y1: Double,
        cx1: Double,
        cy1: Double,
        cx2: Double,
        cy2: Double,
        x2: Double,
        y2: Double
    ) -> CGPoint {
        let u = 1 - t
        let uu = u * u
        let tt = t * t
        let uuu = uu * u
        let ttt = tt * t
        let x = x1 * uuu + 3 * cx1 * uu * t + 3 * cx2 * u * tt + x2 * ttt
        let y = y1 * uuu + 3 * cy1 * uu * t + 3 * cy2 * u * tt + y2 * ttt
        return CGPoint(x: x, y: y)
    }

    private static func cubicTangent(
        t: Double,
        x1: Double,
        y1: Double,
        cx1: Double,
        cy1: Double,
        cx2: Double,
        cy2: Double,
        x2: Double,
        y2: Double
    ) -> CGPoint {
        let u = 1 - t
        let x = 3 * u * u * (cx1 - x1) + 6 * u * t * (cx2 - cx1) + 3 * t * t * (x2 - cx2)
        let y = 3 * u * u * (cy1 - y1) + 6 * u * t * (cy2 - cy1) + 3 * t * t * (y2 - cy2)
        return CGPoint(x: x, y: y)
    }

    private static func allPathWorldValues(
        attachment: PathAttachment,
        states: [BonePoseState],
        slotBone: BonePoseState?,
        deform: [Double]
    ) -> [Double] {
        let vertexCount = attachment.vertexCount
        if attachment.vertices.count == vertexCount * 2 {
            var output: [Double] = []
            output.reserveCapacity(vertexCount * 2)
            for index in stride(from: 0, to: attachment.vertices.count, by: 2) {
                let localX = attachment.vertices[index] + deformValue(deform, at: index)
                let localY = attachment.vertices[index + 1] + deformValue(deform, at: index + 1)
                if let slotBone {
                    let point = localToWorld(x: localX, y: localY, state: slotBone)
                    output.append(point.x)
                    output.append(point.y)
                } else {
                    output.append(localX)
                    output.append(localY)
                }
            }
            return output
        }

        var output: [Double] = []
        output.reserveCapacity(vertexCount * 2)
        var index = 0
        var deformIndex = 0
        for _ in 0..<vertexCount {
            guard index < attachment.vertices.count else { break }
            let influenceCount = Int(attachment.vertices[index])
            index += 1

            var x = 0.0
            var y = 0.0
            for _ in 0..<influenceCount {
                guard index + 3 < attachment.vertices.count else { break }
                let boneIndex = Int(attachment.vertices[index])
                let localX = attachment.vertices[index + 1] + deformValue(deform, at: deformIndex)
                let localY = attachment.vertices[index + 2] + deformValue(deform, at: deformIndex + 1)
                let weight = attachment.vertices[index + 3]
                index += 4
                deformIndex += 2

                guard boneIndex >= 0, boneIndex < states.count else { continue }
                let point = localToWorld(x: localX, y: localY, state: states[boneIndex])
                x += point.x * weight
                y += point.y * weight
            }
            output.append(x)
            output.append(y)
        }
        return output.count == vertexCount * 2 ? output : []
    }

    private static func sliceWorldValues(_ values: [Double], start: Int, count: Int) -> [Double] {
        guard count > 0, values.isEmpty == false else { return [] }
        let lower = min(max(start, 0), values.count)
        let upper = min(lower + count, values.count)
        return Array(values[lower..<upper])
    }

    private static func localToWorld(x: Double, y: Double, state: BonePoseState) -> CGPoint {
        CGPoint(
            x: x * state.a + y * state.c + state.tx,
            y: x * state.b + y * state.d + state.ty
        )
    }

    private static func rotateWorld(index: Int, radians: Double, states: inout [BonePoseState]) {
        let current = states[index]
        let cosValue = cos(radians)
        let sinValue = sin(radians)
        states[index].a = cosValue * current.a - sinValue * current.b
        states[index].b = sinValue * current.a + cosValue * current.b
        states[index].c = cosValue * current.c - sinValue * current.d
        states[index].d = sinValue * current.c + cosValue * current.d
    }

    private static func updateAppliedTransform(index: Int, states: inout [BonePoseState]) {
        guard index < states.count else { return }
        var state = states[index]

        let localA: Double
        let localB: Double
        let localC: Double
        let localD: Double

        if let parentIndex = state.parentIndex, parentIndex < states.count {
            let parent = states[parentIndex]
            let determinant = parent.a * parent.d - parent.c * parent.b
            guard abs(determinant) > 0.0001 else { return }
            let dx = state.tx - parent.tx
            let dy = state.ty - parent.ty
            state.x = (dx * parent.d - dy * parent.c) / determinant
            state.y = (dy * parent.a - dx * parent.b) / determinant

            if state.inherit == "onlyTranslation" {
                localA = state.a
                localB = state.b
                localC = state.c
                localD = state.d
            } else {
                localA = (state.a * parent.d - state.b * parent.c) / determinant
                localB = (state.b * parent.a - state.a * parent.b) / determinant
                localC = (state.c * parent.d - state.d * parent.c) / determinant
                localD = (state.d * parent.a - state.c * parent.b) / determinant
            }
        } else {
            state.x = state.tx
            state.y = state.ty
            localA = state.a
            localB = state.b
            localC = state.c
            localD = state.d
        }

        state.shearX = 0
        state.scaleX = sqrt(localA * localA + localB * localB)
        if state.scaleX > 0.0001 {
            let determinant = localA * localD - localC * localB
            state.scaleY = determinant / state.scaleX
            state.shearY = -atan2(localA * localC + localB * localD, determinant) * 180.0 / .pi
            state.rotation = atan2(localB, localA) * 180.0 / .pi
        } else {
            state.scaleX = 0
            state.scaleY = sqrt(localC * localC + localD * localD)
            state.shearY = 0
            state.rotation = 90.0 - atan2(localD, localC) * 180.0 / .pi
        }

        states[index] = state
    }

    private static func normalizeRadians(_ value: Double) -> Double {
        var result = value
        while result > .pi {
            result -= .pi * 2
        }
        while result < -.pi {
            result += .pi * 2
        }
        return result
    }

    private static func normalizeDegrees(_ value: Double) -> Double {
        var result = value
        while result > 180 {
            result -= 360
        }
        while result < -180 {
            result += 360
        }
        return result
    }

    private static func localWorldTransform(
        rotation: Double,
        scaleX: Double,
        scaleY: Double,
        shearX: Double,
        shearY: Double,
        x: Double,
        y: Double
    ) -> BoneWorld {
        let xAxis = (rotation + shearX) * .pi / 180.0
        let yAxis = (rotation + 90.0 + shearY) * .pi / 180.0
        return BoneWorld(
            a: cos(xAxis) * scaleX,
            b: sin(xAxis) * scaleX,
            c: cos(yAxis) * scaleY,
            d: sin(yAxis) * scaleY,
            tx: x,
            ty: y
        )
    }

    private static func noScaleWorldTransform(
        parent: BoneWorld,
        rotation: Double,
        scaleX: Double,
        scaleY: Double,
        shearX: Double,
        shearY: Double,
        preserveReflection: Bool,
        tx: Double,
        ty: Double
    ) -> BoneWorld {
        let rotationRadians = rotation * .pi / 180.0
        let rotationCos = cos(rotationRadians)
        let rotationSin = sin(rotationRadians)

        let pa = parent.a
        let pb = parent.c
        let pc = parent.b
        let pd = parent.d

        var za = pa * rotationCos + pb * rotationSin
        var zc = pc * rotationCos + pd * rotationSin
        let axisLength = sqrt(za * za + zc * zc)
        if axisLength > 0.00001 {
            za /= axisLength
            zc /= axisLength
        }

        var reflectionScale = sqrt(za * za + zc * zc)
        if preserveReflection, (pa * pd - pb * pc) < 0 {
            reflectionScale = -reflectionScale
        }

        let rotatedAxis = (.pi / 2.0) + atan2(zc, za)
        let zb = cos(rotatedAxis) * reflectionScale
        let zd = sin(rotatedAxis) * reflectionScale

        let shearXRad = shearX * .pi / 180.0
        let shearYRad = (90.0 + shearY) * .pi / 180.0
        let la = cos(shearXRad) * scaleX
        let lb = cos(shearYRad) * scaleY
        let lc = sin(shearXRad) * scaleX
        let ld = sin(shearYRad) * scaleY

        let officialA = za * la + zb * lc
        let officialB = za * lb + zb * ld
        let officialC = zc * la + zd * lc
        let officialD = zc * lb + zd * ld

        return BoneWorld(
            a: officialA,
            b: officialC,
            c: officialB,
            d: officialD,
            tx: tx,
            ty: ty
        )
    }

    private static func parseSlots(root: [String: Any]) throws -> [Slot] {
        guard let rawSlots = root["slots"] as? [[String: Any]] else {
            throw EngineError.asset("Spine JSON missing slots")
        }
        var slots: [Slot] = []
        for raw in rawSlots {
            guard let name = raw["name"] as? String else { continue }
            if raw["bone"] == nil {
                fputs("Spine slot \(name) has no bone; unweighted attachments will use local coordinates\n", stderr)
            }
            let rawBlend = raw["blend"] as? String
            guard let blendMode = RenderBlendMode(spineBlend: rawBlend) else {
                throw EngineError.asset("Spine slot \(name) uses unsupported blend mode: \(rawBlend ?? "unknown")")
            }
            slots.append(Slot(
                name: name,
                boneName: raw["bone"] as? String,
                attachment: raw["attachment"] as? String,
                color: parseColor(raw["color"] as? String),
                darkColor: parseDarkColor(raw["dark"] as? String),
                blendMode: blendMode
            ))
        }
        return slots
    }

    private static func selectedSkinAttachmentSource(root: [String: Any]) throws -> SkinAttachmentSource {
        let sources = skinAttachmentSources(root: root)
        guard sources.isEmpty == false else {
            throw EngineError.asset("Spine JSON missing skin attachments")
        }
        return sources.first { $0.name == "default" } ?? sources[0]
    }

    private static func skinAttachmentSources(root: [String: Any]) -> [SkinAttachmentSource] {
        if let skins = root["skins"] as? [[String: Any]] {
            return skins.compactMap { skin in
                guard let attachments = skin["attachments"] as? [String: Any] else { return nil }
                return SkinAttachmentSource(
                    name: skin["name"] as? String ?? "default",
                    attachments: attachments
                )
            }
        }

        if let skins = root["skins"] as? [String: Any] {
            return skins.compactMap { skinName, rawSkin in
                guard let skin = rawSkin as? [String: Any] else { return nil }
                let attachments = skin["attachments"] as? [String: Any] ?? skin
                return SkinAttachmentSource(name: skinName, attachments: attachments)
            }
            .sorted { lhs, rhs in
                if lhs.name == "default" { return true }
                if rhs.name == "default" { return false }
                return lhs.name < rhs.name
            }
        }

        return []
    }

    private static func parseAttachments(root: [String: Any]) throws -> [String: [String: Attachment]] {
        let skin = try selectedSkinAttachmentSource(root: root)
        var allSkinParentAttachments: [String: [String: [String: Attachment]]] = [:]
        for source in skinAttachmentSources(root: root) {
            allSkinParentAttachments[source.name] = try parseDirectRenderableAttachments(from: source)
        }
        var bySlot = allSkinParentAttachments[skin.name] ?? [:]
        var pendingLinkedMeshes: [(slotName: String, attachmentName: String, raw: [String: Any])] = []
        for (slotName, slotValue) in skin.attachments {
            guard let slotAttachments = slotValue as? [String: Any] else { continue }
            for (attachmentName, attachmentValue) in slotAttachments {
                guard let raw = attachmentValue as? [String: Any] else { continue }
                let type = (raw["type"] as? String ?? "region").lowercased()
                if type == "linkedmesh" {
                    pendingLinkedMeshes.append((slotName: slotName, attachmentName: attachmentName, raw: raw))
                }
            }
        }

        while pendingLinkedMeshes.isEmpty == false {
            var remaining: [(slotName: String, attachmentName: String, raw: [String: Any])] = []
            var resolvedAtLeastOne = false
            for linkedMesh in pendingLinkedMeshes {
                let referencedSkin = (linkedMesh.raw["skin"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? skin.name
                guard let parentName = linkedMesh.raw["parent"] as? String,
                      parentName.isEmpty == false else {
                    throw EngineError.asset(
                        "Spine linkedmesh attachment \(linkedMesh.slotName)/\(linkedMesh.attachmentName) missing parent"
                    )
                }
                let parent = referencedSkin == skin.name
                    ? bySlot[linkedMesh.slotName]?[parentName]
                    : allSkinParentAttachments[referencedSkin]?[linkedMesh.slotName]?[parentName]
                guard let parent else {
                    remaining.append(linkedMesh)
                    continue
                }
                let atlasRegionName = linkedMesh.raw["path"] as? String ?? parent.name
                bySlot[linkedMesh.slotName, default: [:]][linkedMesh.attachmentName] = Attachment(
                    name: atlasRegionName,
                    slotName: linkedMesh.slotName,
                    uvs: parent.uvs,
                    triangles: parent.triangles,
                    vertices: parent.vertices,
                    sequence: parseSequenceInfo(linkedMesh.raw["sequence"]) ?? parent.sequence
                )
                resolvedAtLeastOne = true
            }
            guard resolvedAtLeastOne else {
                let unresolved = pendingLinkedMeshes
                    .map { "\($0.slotName)/\($0.attachmentName)" }
                    .sorted()
                    .joined(separator: ",")
                throw EngineError.asset("Spine linkedmesh attachment(s) missing parent mesh: \(unresolved)")
            }
            pendingLinkedMeshes = remaining
        }
        return bySlot
    }

    private static func parseDirectRenderableAttachments(from skin: SkinAttachmentSource) throws -> [String: [String: Attachment]] {
        var bySlot: [String: [String: Attachment]] = [:]
        for (slotName, slotValue) in skin.attachments {
            guard let slotAttachments = slotValue as? [String: Any] else { continue }
            for (attachmentName, attachmentValue) in slotAttachments {
                guard let raw = attachmentValue as? [String: Any] else { continue }
                let type = (raw["type"] as? String ?? "region").lowercased()
                let atlasRegionName = raw["path"] as? String ?? attachmentName
                if type == "region" {
                    bySlot[slotName, default: [:]][attachmentName] = makeRegionAttachment(
                        name: atlasRegionName,
                        slotName: slotName,
                        raw: raw
                    )
                    continue
                }
                guard type == "mesh" else {
                    continue
                }
                guard let uvs = raw["uvs"] as? [Double],
                      let triangles = raw["triangles"] as? [Int],
                      let vertices = raw["vertices"] as? [Double] else {
                    throw EngineError.asset("Spine mesh attachment \(slotName)/\(attachmentName) missing uvs, triangles, or vertices")
                }
                bySlot[slotName, default: [:]][attachmentName] = Attachment(
                    name: atlasRegionName,
                    slotName: slotName,
                    uvs: uvs,
                    triangles: triangles,
                    vertices: vertices,
                    sequence: parseSequenceInfo(raw["sequence"])
                )
            }
        }
        return bySlot
    }

    private static func makeRegionAttachment(name: String, slotName: String, raw: [String: Any]) -> Attachment {
        let width = number(raw["width"], default: 0)
        let height = number(raw["height"], default: 0)
        let x = number(raw["x"], default: 0)
        let y = number(raw["y"], default: 0)
        let scaleX = number(raw["scaleX"], default: 1)
        let scaleY = number(raw["scaleY"], default: 1)
        let rotation = number(raw["rotation"], default: 0) * .pi / 180.0
        let cosValue = cos(rotation)
        let sinValue = sin(rotation)

        let halfWidth = width / 2.0
        let halfHeight = height / 2.0
        let corners = [
            CGPoint(x: -halfWidth, y: -halfHeight),
            CGPoint(x: -halfWidth, y: halfHeight),
            CGPoint(x: halfWidth, y: halfHeight),
            CGPoint(x: halfWidth, y: -halfHeight)
        ]

        let vertices = corners.flatMap { corner in
            let localX = corner.x * scaleX
            let localY = corner.y * scaleY
            return [
                x + (localX * cosValue) - (localY * sinValue),
                y + (localX * sinValue) + (localY * cosValue)
            ]
        }

        return Attachment(
            name: name,
            slotName: slotName,
            uvs: [0, 1, 0, 0, 1, 0, 1, 1],
            triangles: [0, 1, 2, 2, 3, 0],
            vertices: vertices,
            sequence: parseSequenceInfo(raw["sequence"])
        )
    }

    private static func parseSequenceInfo(_ raw: Any?) -> SequenceInfo? {
        guard let map = raw as? [String: Any] else { return nil }
        let count = Int(number(map["count"], default: 0))
        guard count > 0 else { return nil }
        let setupIndex = Int(number(map["setup"] ?? map["setupIndex"], default: 0))
        return SequenceInfo(
            count: count,
            start: Int(number(map["start"], default: 0)),
            digits: max(Int(number(map["digits"], default: 0)), 0),
            setupIndex: min(max(setupIndex, 0), count - 1),
            pathSuffix: map["pathSuffix"] as? Bool ?? true
        )
    }

    private static func attachmentAtlasRegionName(_ attachment: Attachment, sequenceIndex: Int?) -> String {
        guard let sequence = attachment.sequence,
              sequence.pathSuffix else {
            return attachment.name
        }
        let index = min(max(sequenceIndex ?? sequence.setupIndex, 0), sequence.count - 1)
        let frameNumber = sequence.start + index
        let suffix: String
        if sequence.digits > 0 {
            suffix = String(format: "%0\(sequence.digits)d", frameNumber)
        } else {
            suffix = "\(frameNumber)"
        }
        return "\(attachment.name)\(suffix)"
    }

    private static func parsePathAttachments(root: [String: Any]) throws -> [String: [String: PathAttachment]] {
        let skin = try selectedSkinAttachmentSource(root: root)
        var bySlot: [String: [String: PathAttachment]] = [:]
        for (slotName, slotValue) in skin.attachments {
            guard let slotAttachments = slotValue as? [String: Any] else { continue }
            for (attachmentName, attachmentValue) in slotAttachments {
                guard let raw = attachmentValue as? [String: Any] else { continue }
                let type = raw["type"] as? String ?? "region"
                guard type == "path" else {
                    continue
                }
                guard let vertices = raw["vertices"] as? [Double] else {
                    throw EngineError.asset("Spine path attachment \(slotName)/\(attachmentName) missing vertices")
                }
                let path = PathAttachment(
                    name: attachmentName,
                    slotName: slotName,
                    vertexCount: Int(number(raw["vertexCount"], default: 0)),
                    vertices: vertices,
                    lengths: raw["lengths"] as? [Double] ?? [],
                    closed: raw["closed"] as? Bool ?? false,
                    constantSpeed: raw["constantSpeed"] as? Bool ?? true
                )
                bySlot[slotName, default: [:]][attachmentName] = path
            }
        }
        return bySlot
    }

    private static func parseClippingAttachments(root: [String: Any]) throws -> [String: [String: ClippingAttachment]] {
        let skin = try selectedSkinAttachmentSource(root: root)
        var bySlot: [String: [String: ClippingAttachment]] = [:]
        for (slotName, slotValue) in skin.attachments {
            guard let slotAttachments = slotValue as? [String: Any] else { continue }
            for (attachmentName, attachmentValue) in slotAttachments {
                guard let raw = attachmentValue as? [String: Any] else { continue }
                let type = raw["type"] as? String ?? "region"
                guard type == "clipping" else {
                    continue
                }
                guard let vertices = raw["vertices"] as? [Double] else {
                    throw EngineError.asset("Spine clipping attachment \(slotName)/\(attachmentName) missing vertices")
                }
                guard let endSlotName = raw["end"] as? String, endSlotName.isEmpty == false else {
                    throw EngineError.asset("Spine clipping attachment \(slotName)/\(attachmentName) missing end slot")
                }
                let rawVertexCount = Int(number(raw["vertexCount"], default: 0))
                let vertexCount = rawVertexCount > 0 ? rawVertexCount : vertices.count / 2
                let clipping = ClippingAttachment(
                    name: attachmentName,
                    slotName: slotName,
                    endSlotName: endSlotName,
                    vertexCount: vertexCount,
                    vertices: vertices
                )
                bySlot[slotName, default: [:]][attachmentName] = clipping
            }
        }
        return bySlot
    }

    private static func buildBatches(
        slots: [Slot],
        attachments: [String: [String: Attachment]],
        clippingAttachments: [String: [String: ClippingAttachment]],
        bones: [BoneWorld],
        deforms: [String: [String: [Double]]] = [:],
        sequenceIndices: [String: [String: Int]] = [:],
        boneIndexByName: [String: Int],
        atlas: (pages: [String: AtlasPage], regions: [String: AtlasRegion]),
        skeletonBounds: CGRect,
        placement: SpinePlacement,
        device: MTLDevice
    ) throws -> [Batch] {
        let vertexBatches = try buildVertexBatches(
            slots: slots,
            attachments: attachments,
            clippingAttachments: clippingAttachments,
            bones: bones,
            deforms: deforms,
            sequenceIndices: sequenceIndices,
            boneIndexByName: boneIndexByName,
            atlas: atlas,
            skeletonBounds: skeletonBounds,
            placement: placement
        )
        return try makeBatches(from: vertexBatches, device: device)
    }

    private static func buildVertexBatches(
        slots: [Slot],
        attachments: [String: [String: Attachment]],
        clippingAttachments: [String: [String: ClippingAttachment]],
        bones: [BoneWorld],
        deforms: [String: [String: [Double]]] = [:],
        sequenceIndices: [String: [String: Int]] = [:],
        boneIndexByName: [String: Int],
        atlas: (pages: [String: AtlasPage], regions: [String: AtlasRegion]),
        skeletonBounds: CGRect,
        placement: SpinePlacement
    ) throws -> [VertexBatch] {
        var orderedBatches: [(pageName: String, blendMode: RenderBlendMode, texture: MTLTexture, vertices: [RenderVertex])] = []
        var activeClipPolygons: [[SIMD2<Float>]] = []
        var activeClipEndSlotName: String?

        for slot in slots {
            guard let attachmentName = slot.attachment else {
                if slot.name == activeClipEndSlotName {
                    activeClipPolygons.removeAll()
                    activeClipEndSlotName = nil
                }
                continue
            }

            let slotBone: BoneWorld?
            if let boneName = slot.boneName {
                guard let boneIndex = boneIndexByName[boneName] else {
                    throw EngineError.asset("Spine slot \(slot.name) references unknown bone \(boneName)")
                }
                slotBone = bones[boneIndex]
            } else {
                slotBone = nil
            }

            if let clipping = clippingAttachments[slot.name]?[attachmentName] {
                let worldVertices = clippingWorldVertices(
                    attachment: clipping,
                    bones: bones,
                    slotBone: slotBone
                )
                guard worldVertices.count == clipping.vertexCount, worldVertices.count >= 3 else {
                    throw EngineError.asset("Spine clipping attachment \(clipping.slotName)/\(clipping.name) produced invalid polygon")
                }
                let clipPolygon = worldVertices.map {
                    project(point: $0, skeletonBounds: skeletonBounds, placement: placement)
                }
                activeClipPolygons = clippingPolygons(from: clipPolygon)
                activeClipEndSlotName = clipping.endSlotName
                if slot.name == activeClipEndSlotName {
                    activeClipPolygons.removeAll()
                    activeClipEndSlotName = nil
                }
                continue
            }

            guard let attachment = attachments[slot.name]?[attachmentName] else {
                if slot.name == activeClipEndSlotName {
                    activeClipPolygons.removeAll()
                    activeClipEndSlotName = nil
                }
                continue
            }
            let atlasRegionName = Self.attachmentAtlasRegionName(
                attachment,
                sequenceIndex: sequenceIndices[slot.name]?[attachmentName]
            )
            guard let region = atlas.regions[atlasRegionName] ?? atlas.regions[attachment.name] else {
                throw EngineError.asset("Spine attachment \(attachment.slotName)/\(atlasRegionName) missing atlas region")
            }
            guard let page = atlas.pages[region.pageName] else {
                throw EngineError.asset("Spine atlas region \(region.name) references missing page \(region.pageName)")
            }

            let worldVertices = meshWorldVertices(
                attachment: attachment,
                bones: bones,
                slotBone: slotBone,
                deform: deforms[slot.name]?[attachmentName] ?? []
            )
            guard worldVertices.count == attachment.uvs.count / 2 else {
                throw EngineError.asset("Spine attachment \(attachment.slotName)/\(attachment.name) vertex count does not match UV count")
            }

            var expanded: [RenderVertex] = []
            expanded.reserveCapacity(attachment.triangles.count)
            for triangleStart in stride(from: 0, to: attachment.triangles.count, by: 3) {
                guard triangleStart + 2 < attachment.triangles.count else {
                    throw EngineError.asset("Spine attachment \(attachment.slotName)/\(attachment.name) has incomplete triangle data")
                }
                let triangle = try (0..<3).map { vertexOffset in
                    let triangleIndex = attachment.triangles[triangleStart + vertexOffset]
                    guard triangleIndex >= 0, triangleIndex < worldVertices.count else {
                        throw EngineError.asset("Spine attachment \(attachment.slotName)/\(attachment.name) triangle index \(triangleIndex) is out of bounds")
                    }
                    let position = project(point: worldVertices[triangleIndex], skeletonBounds: skeletonBounds, placement: placement)
                    let uvIndex = triangleIndex * 2
                    let localU = attachment.uvs[uvIndex]
                    let localV = attachment.uvs[uvIndex + 1]
                    let texCoord = atlasTexCoord(localU: localU, localV: localV, region: region, page: page)
                    return RenderVertex(
                        position: position,
                        texCoord: texCoord,
                        color: slot.color,
                        darkColor: slot.darkColor
                    )
                }
                appendTriangle(triangle, clippingPolygons: activeClipPolygons, into: &expanded)
            }

            let shouldEndActiveClip = slot.name == activeClipEndSlotName
            guard expanded.isEmpty == false else {
                if shouldEndActiveClip {
                    activeClipPolygons.removeAll()
                    activeClipEndSlotName = nil
                }
                continue
            }
            if let lastIndex = orderedBatches.indices.last,
               orderedBatches[lastIndex].pageName == region.pageName,
               orderedBatches[lastIndex].blendMode == slot.blendMode {
                orderedBatches[lastIndex].vertices.append(contentsOf: expanded)
            } else {
                orderedBatches.append((region.pageName, slot.blendMode, page.texture, expanded))
            }

            if shouldEndActiveClip {
                activeClipPolygons.removeAll()
                activeClipEndSlotName = nil
            }
        }

        return orderedBatches
            .filter { $0.vertices.isEmpty == false }
            .map { VertexBatch(texture: $0.texture, blendMode: $0.blendMode, vertices: $0.vertices) }
    }

    private static func appendTriangle(
        _ triangle: [RenderVertex],
        clippingPolygons: [[SIMD2<Float>]],
        into expanded: inout [RenderVertex]
    ) {
        guard clippingPolygons.isEmpty == false else {
            expanded.append(contentsOf: triangle)
            return
        }

        for clipPolygon in clippingPolygons {
            let clipped = clipPolygonVertices(triangle, to: clipPolygon)
            guard clipped.count >= 3 else { continue }
            for index in 1..<(clipped.count - 1) {
                expanded.append(clipped[0])
                expanded.append(clipped[index])
                expanded.append(clipped[index + 1])
            }
        }
    }

    private static func clippingPolygons(from polygon: [SIMD2<Float>]) -> [[SIMD2<Float>]] {
        let cleaned = polygon.filter { point in
            point.x.isFinite && point.y.isFinite
        }
        guard cleaned.count >= 3 else { return [] }
        if isConvexPolygon(cleaned) {
            return [cleaned]
        }
        let triangles = triangulatePolygon(cleaned)
        return triangles.isEmpty ? [cleaned] : triangles
    }

    private static func isConvexPolygon(_ polygon: [SIMD2<Float>]) -> Bool {
        guard polygon.count > 3 else { return true }
        let orientation = signedArea(polygon) >= 0 ? Float(1) : Float(-1)
        for index in polygon.indices {
            let previous = polygon[(index + polygon.count - 1) % polygon.count]
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            if orientation * cross(current - previous, next - current) < -0.0001 {
                return false
            }
        }
        return true
    }

    private static func triangulatePolygon(_ polygon: [SIMD2<Float>]) -> [[SIMD2<Float>]] {
        guard polygon.count >= 3 else { return [] }
        let orientation = signedArea(polygon) >= 0 ? Float(1) : Float(-1)
        var remaining = Array(polygon.indices)
        var triangles: [[SIMD2<Float>]] = []
        var guardCounter = 0

        while remaining.count > 3, guardCounter < polygon.count * polygon.count {
            guardCounter += 1
            var removedEar = false
            for remainingIndex in remaining.indices {
                let previousIndex = remaining[(remainingIndex + remaining.count - 1) % remaining.count]
                let currentIndex = remaining[remainingIndex]
                let nextIndex = remaining[(remainingIndex + 1) % remaining.count]
                let previous = polygon[previousIndex]
                let current = polygon[currentIndex]
                let next = polygon[nextIndex]
                let turn = orientation * cross(current - previous, next - current)
                guard turn > 0.0001 else { continue }

                let containsPoint = remaining.contains { candidateIndex in
                    guard candidateIndex != previousIndex,
                          candidateIndex != currentIndex,
                          candidateIndex != nextIndex else {
                        return false
                    }
                    return pointInTriangle(polygon[candidateIndex], previous, current, next)
                }
                guard containsPoint == false else { continue }

                triangles.append([previous, current, next])
                remaining.remove(at: remainingIndex)
                removedEar = true
                break
            }
            if removedEar == false {
                return []
            }
        }

        if remaining.count == 3 {
            triangles.append(remaining.map { polygon[$0] })
        }
        return triangles
    }

    private static func clipPolygonVertices(
        _ subject: [RenderVertex],
        to clipPolygon: [SIMD2<Float>]
    ) -> [RenderVertex] {
        guard subject.count >= 3, clipPolygon.count >= 3 else { return [] }
        let orientation = signedArea(clipPolygon) >= 0 ? Float(1) : Float(-1)
        var output = subject

        for index in clipPolygon.indices {
            let edgeStart = clipPolygon[index]
            let edgeEnd = clipPolygon[(index + 1) % clipPolygon.count]
            let input = output
            output.removeAll(keepingCapacity: true)
            guard let lastInput = input.last else { break }
            var previous = lastInput
            var previousInside = isInside(previous.position, edgeStart: edgeStart, edgeEnd: edgeEnd, orientation: orientation)

            for current in input {
                let currentInside = isInside(current.position, edgeStart: edgeStart, edgeEnd: edgeEnd, orientation: orientation)
                if currentInside {
                    if previousInside == false {
                        output.append(intersection(previous, current, edgeStart: edgeStart, edgeEnd: edgeEnd))
                    }
                    output.append(current)
                } else if previousInside {
                    output.append(intersection(previous, current, edgeStart: edgeStart, edgeEnd: edgeEnd))
                }
                previous = current
                previousInside = currentInside
            }
        }
        return output
    }

    private static func isInside(
        _ point: SIMD2<Float>,
        edgeStart: SIMD2<Float>,
        edgeEnd: SIMD2<Float>,
        orientation: Float
    ) -> Bool {
        orientation * cross(edgeEnd - edgeStart, point - edgeStart) >= -0.0001
    }

    private static func intersection(
        _ first: RenderVertex,
        _ second: RenderVertex,
        edgeStart: SIMD2<Float>,
        edgeEnd: SIMD2<Float>
    ) -> RenderVertex {
        let ray = second.position - first.position
        let edge = edgeEnd - edgeStart
        let denominator = cross(ray, edge)
        guard abs(denominator) > 0.000001 else {
            return second
        }
        let unclamped = cross(edgeStart - first.position, edge) / denominator
        let t = min(max(unclamped, 0), 1)
        return interpolate(first, second, t: t)
    }

    private static func interpolate(_ first: RenderVertex, _ second: RenderVertex, t: Float) -> RenderVertex {
        RenderVertex(
            position: first.position + ((second.position - first.position) * t),
            texCoord: first.texCoord + ((second.texCoord - first.texCoord) * t),
            color: first.color + ((second.color - first.color) * t),
            darkColor: first.darkColor + ((second.darkColor - first.darkColor) * t)
        )
    }

    private static func pointInTriangle(
        _ point: SIMD2<Float>,
        _ first: SIMD2<Float>,
        _ second: SIMD2<Float>,
        _ third: SIMD2<Float>
    ) -> Bool {
        let area1 = cross(second - first, point - first)
        let area2 = cross(third - second, point - second)
        let area3 = cross(first - third, point - third)
        let hasNegative = area1 < -0.0001 || area2 < -0.0001 || area3 < -0.0001
        let hasPositive = area1 > 0.0001 || area2 > 0.0001 || area3 > 0.0001
        return !(hasNegative && hasPositive)
    }

    private static func signedArea(_ polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count >= 3 else { return 0 }
        var sum: Float = 0
        for index in polygon.indices {
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            sum += (current.x * next.y) - (next.x * current.y)
        }
        return sum * 0.5
    }

    private static func cross(_ first: SIMD2<Float>, _ second: SIMD2<Float>) -> Float {
        (first.x * second.y) - (first.y * second.x)
    }

    private static func geometrySample(
        actionName: String,
        time: Double,
        vertexBatches: [VertexBatch],
        error: String
    ) -> GeometrySample {
        let vertices = vertexBatches.flatMap(\.vertices)
        let blendModes = Array(Set(vertexBatches.map(\.blendMode.rawValue))).sorted()
        let finite = vertices.allSatisfy { vertex in
            vertex.position.x.isFinite
                && vertex.position.y.isFinite
                && vertex.texCoord.x.isFinite
                && vertex.texCoord.y.isFinite
                && vertex.color.x.isFinite
                && vertex.color.y.isFinite
                && vertex.color.z.isFinite
                && vertex.color.w.isFinite
                && vertex.darkColor.x.isFinite
                && vertex.darkColor.y.isFinite
                && vertex.darkColor.z.isFinite
                && vertex.darkColor.w.isFinite
        }
        let uvInRange = vertices.allSatisfy { vertex in
            vertex.texCoord.x >= -0.0001
                && vertex.texCoord.x <= 1.0001
                && vertex.texCoord.y >= -0.0001
                && vertex.texCoord.y <= 1.0001
        }
        let status = vertices.isEmpty == false && finite && uvInRange ? "renderable" : "invalid"
        let uvStatus: String
        if vertices.isEmpty {
            uvStatus = "uv=no-vertices"
        } else if finite == false {
            uvStatus = "uv=non-finite"
        } else if uvInRange == false {
            uvStatus = "uv=out-of-range"
        } else {
            uvStatus = "uv=ok"
        }

        return GeometrySample(
            actionName: actionName,
            time: time,
            status: status,
            batchCount: vertexBatches.count,
            vertexCount: vertices.count,
            blendModes: blendModes.isEmpty ? "none" : blendModes.joined(separator: "+"),
            uvStatus: uvStatus,
            bounds: boundsText(vertices),
            fingerprint: geometryFingerprint(vertexBatches),
            error: error
        )
    }

    private static func geometryFingerprint(_ vertexBatches: [VertexBatch]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        hashString("spine-geometry-v1", into: &hash)
        hashInt(vertexBatches.count, into: &hash)
        for batch in vertexBatches {
            hashString(batch.blendMode.rawValue, into: &hash)
            hashInt(batch.vertices.count, into: &hash)
            for vertex in batch.vertices {
                hashFloat(vertex.position.x, into: &hash)
                hashFloat(vertex.position.y, into: &hash)
                hashFloat(vertex.texCoord.x, into: &hash)
                hashFloat(vertex.texCoord.y, into: &hash)
                hashFloat(vertex.color.x, into: &hash)
                hashFloat(vertex.color.y, into: &hash)
                hashFloat(vertex.color.z, into: &hash)
                hashFloat(vertex.color.w, into: &hash)
                hashFloat(vertex.darkColor.x, into: &hash)
                hashFloat(vertex.darkColor.y, into: &hash)
                hashFloat(vertex.darkColor.z, into: &hash)
                hashFloat(vertex.darkColor.w, into: &hash)
            }
        }
        return "fp=\(String(format: "%016llx", hash))"
    }

    private static func hashString(_ value: String, into hash: inout UInt64) {
        for byte in value.utf8 {
            hashByte(byte, into: &hash)
        }
        hashByte(0xff, into: &hash)
    }

    private static func hashInt(_ value: Int, into hash: inout UInt64) {
        hashString(String(value), into: &hash)
    }

    private static func hashFloat(_ value: Float, into hash: inout UInt64) {
        let quantized = Int((Double(value) * 10_000).rounded())
        hashInt(quantized, into: &hash)
    }

    private static func hashByte(_ byte: UInt8, into hash: inout UInt64) {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }

    private static func snapshotImage(
        vertexBatches: [VertexBatch],
        device: MTLDevice,
        width: Int,
        height: Int
    ) throws -> CGImage {
        let renderTexture = try MetalSnapshotImage.makeRenderTexture(device: device, width: width, height: height)
        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw EngineError.renderer("Could not create Metal command buffer for Spine snapshot")
        }
        let normalPipelineState = try MetalCompositor.makePipeline(device: device, blendMode: .normal)
        let additivePipelineState = try MetalCompositor.makePipeline(device: device, blendMode: .additive)
        let multiplyPipelineState = try MetalCompositor.makePipeline(device: device, blendMode: .multiply)
        let screenPipelineState = try MetalCompositor.makePipeline(device: device, blendMode: .screen)

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = renderTexture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)
        passDescriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            throw EngineError.renderer("Could not create Metal render encoder for Spine snapshot")
        }

        try encodeVertexBatches(
            vertexBatches,
            device: device,
            encoder: encoder,
            normalPipelineState: normalPipelineState,
            additivePipelineState: additivePipelineState,
            multiplyPipelineState: multiplyPipelineState,
            screenPipelineState: screenPipelineState
        )
        encoder.endEncoding()
        return try MetalSnapshotImage.readImage(texture: renderTexture, device: device, commandBuffer: commandBuffer)
    }

    private static func encodeVertexBatches(
        _ vertexBatches: [VertexBatch],
        device: MTLDevice,
        encoder: MTLRenderCommandEncoder,
        normalPipelineState: MTLRenderPipelineState,
        additivePipelineState: MTLRenderPipelineState,
        multiplyPipelineState: MTLRenderPipelineState,
        screenPipelineState: MTLRenderPipelineState
    ) throws {
        var uniforms = RenderUniforms.make(
            scale: 1,
            offset: SIMD2<Float>(0, 0),
            aspectScale: SIMD2<Float>(1, 1)
        )
        for batch in vertexBatches where batch.vertices.isEmpty == false {
            switch batch.blendMode {
            case .normal:
                encoder.setRenderPipelineState(normalPipelineState)
            case .additive:
                encoder.setRenderPipelineState(additivePipelineState)
            case .multiply:
                encoder.setRenderPipelineState(multiplyPipelineState)
            case .screen:
                encoder.setRenderPipelineState(screenPipelineState)
            }
            guard let vertexBuffer = device.makeBuffer(
                bytes: batch.vertices,
                length: MemoryLayout<RenderVertex>.stride * batch.vertices.count
            ) else {
                throw EngineError.renderer("Could not allocate Spine snapshot vertex buffer")
            }
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 1)
            encoder.setFragmentTexture(batch.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: batch.vertices.count)
        }
    }

    private static func geometrySampleTimes(animation: SpineAnimation, poseSampleFps: Double) -> [Double] {
        guard animation.duration.isFinite, animation.duration > 0 else { return [0] }
        let duration = animation.duration
        let transitionEpsilon = 0.001
        let fps = max(poseSampleFps, 1)
        let frameCount = Int((duration * fps).rounded(.down))
        let maxCadenceCandidates = maxGeometryDiagnosticSamplesPerAction * 4
        let frameStride = max(1, frameCount / maxCadenceCandidates)
        var candidates = [0, duration * 0.5, duration]
        candidates.append(contentsOf: animation.timelineFrameTimes())
        candidates.append(contentsOf: animation.discreteTransitionTimes().map {
            min(max($0 + transitionEpsilon, 0), duration)
        })
        if frameCount > 0 {
            var frame = 1
            while frame <= frameCount {
                candidates.append(min(Double(frame) / fps, duration))
                frame += frameStride
            }
        }

        var result: [Double] = []
        for candidate in candidates {
            let clamped = min(max(candidate, 0), duration)
            let rounded = (clamped * 1000).rounded() / 1000
            if result.contains(where: { abs($0 - rounded) < 0.0005 }) == false {
                result.append(rounded)
            }
        }
        result.sort()
        return cappedSampleTimes(result, limit: maxGeometryDiagnosticSamplesPerAction)
    }

    private static func cappedSampleTimes(_ times: [Double], limit: Int) -> [Double] {
        guard times.count > limit, limit >= 3 else { return times }
        let lastIndex = times.count - 1
        var selected: [Double] = []
        selected.reserveCapacity(limit)
        for offset in 0..<limit {
            let ratio = Double(offset) / Double(limit - 1)
            let index = Int((ratio * Double(lastIndex)).rounded())
            let value = times[min(max(index, 0), lastIndex)]
            if selected.contains(where: { abs($0 - value) < 0.0005 }) == false {
                selected.append(value)
            }
        }
        if selected.contains(where: { abs($0 - times[0]) < 0.0005 }) == false {
            selected.insert(times[0], at: 0)
        }
        if let last = times.last,
           selected.contains(where: { abs($0 - last) < 0.0005 }) == false {
            selected.append(last)
        }
        selected.sort()
        return selected
    }

    private static func boundsText(_ vertices: [RenderVertex]) -> String {
        guard let first = vertices.first else { return "bounds=none" }
        var minX = first.position.x
        var maxX = first.position.x
        var minY = first.position.y
        var maxY = first.position.y
        for vertex in vertices.dropFirst() {
            minX = min(minX, vertex.position.x)
            maxX = max(maxX, vertex.position.x)
            minY = min(minY, vertex.position.y)
            maxY = max(maxY, vertex.position.y)
        }
        return "bounds=x:\(format(minX))...\(format(maxX)),y:\(format(minY))...\(format(maxY))"
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.3f", value)
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func makeBatches(from vertexBatches: [VertexBatch], device: MTLDevice) throws -> [Batch] {
        var result: [Batch] = []
        result.reserveCapacity(vertexBatches.count)
        for batch in vertexBatches {
            guard let buffer = device.makeBuffer(
                bytes: batch.vertices,
                length: MemoryLayout<RenderVertex>.stride * batch.vertices.count,
                options: [.storageModeShared]
            ) else {
                throw EngineError.renderer("Could not allocate Spine mesh vertex buffer")
            }
            result.append(Batch(
                texture: batch.texture,
                blendMode: batch.blendMode,
                vertexBuffer: buffer,
                vertexCount: batch.vertices.count,
                capacity: batch.vertices.count
            ))
        }
        return result
    }

    private static func updateBatches(
        from vertexBatches: [VertexBatch],
        previous: [Batch],
        device: MTLDevice
    ) throws -> [Batch] {
        guard vertexBatches.count == previous.count else {
            return try makeBatches(from: vertexBatches, device: device)
        }

        var result: [Batch] = []
        result.reserveCapacity(vertexBatches.count)
        let stride = MemoryLayout<RenderVertex>.stride

        for index in vertexBatches.indices {
            let source = vertexBatches[index]
            let old = previous[index]

            guard old.capacity >= source.vertices.count else {
                let rebuilt = try makeBatches(from: Array(vertexBatches[index...]), device: device)
                result.append(contentsOf: rebuilt)
                return result
            }

            source.vertices.withUnsafeBytes { rawBuffer in
                if let baseAddress = rawBuffer.baseAddress {
                    old.vertexBuffer.contents().copyMemory(
                        from: baseAddress,
                        byteCount: stride * source.vertices.count
                    )
                }
            }
            result.append(Batch(
                texture: source.texture,
                blendMode: source.blendMode,
                vertexBuffer: old.vertexBuffer,
                vertexCount: source.vertices.count,
                capacity: old.capacity
            ))
        }

        return result
    }

    private static func vertexBatchByteCount(_ vertexBatches: [VertexBatch]) -> Int {
        let stride = MemoryLayout<RenderVertex>.stride
        return vertexBatches.reduce(0) { total, batch in
            total + (batch.vertices.count * stride)
        }
    }

    private static func meshWorldVertices(
        attachment: Attachment,
        bones: [BoneWorld],
        slotBone: BoneWorld?,
        deform: [Double]
    ) -> [CGPoint] {
        let vertexCount = attachment.uvs.count / 2
        if attachment.vertices.count == vertexCount * 2 {
            return stride(from: 0, to: attachment.vertices.count, by: 2).map {
                let localX = attachment.vertices[$0] + deformValue(deform, at: $0)
                let localY = attachment.vertices[$0 + 1] + deformValue(deform, at: $0 + 1)
                if let slotBone {
                    return slotBone.transform(x: localX, y: localY)
                }
                return CGPoint(x: localX, y: localY)
            }
        }

        var output: [CGPoint] = []
        output.reserveCapacity(vertexCount)
        var index = 0
        var deformIndex = 0
        for _ in 0..<vertexCount {
            guard index < attachment.vertices.count else { break }
            let influenceCount = Int(attachment.vertices[index])
            index += 1

            var x = 0.0
            var y = 0.0
            for _ in 0..<influenceCount {
                guard index + 3 < attachment.vertices.count else { break }
                let boneIndex = Int(attachment.vertices[index])
                let localX = attachment.vertices[index + 1] + deformValue(deform, at: deformIndex)
                let localY = attachment.vertices[index + 2] + deformValue(deform, at: deformIndex + 1)
                let weight = attachment.vertices[index + 3]
                index += 4
                deformIndex += 2

                guard boneIndex < bones.count else { continue }
                let transformed = bones[boneIndex].transform(x: localX, y: localY)
                x += transformed.x * weight
                y += transformed.y * weight
            }
            output.append(CGPoint(x: x, y: y))
        }
        guard output.count == vertexCount, index == attachment.vertices.count else {
            return []
        }
        return output
    }

    private static func clippingWorldVertices(
        attachment: ClippingAttachment,
        bones: [BoneWorld],
        slotBone: BoneWorld?
    ) -> [CGPoint] {
        let vertexCount = attachment.vertexCount
        guard vertexCount > 0 else { return [] }
        if attachment.vertices.count == vertexCount * 2 {
            return stride(from: 0, to: attachment.vertices.count, by: 2).map {
                let localX = attachment.vertices[$0]
                let localY = attachment.vertices[$0 + 1]
                if let slotBone {
                    return slotBone.transform(x: localX, y: localY)
                }
                return CGPoint(x: localX, y: localY)
            }
        }

        var output: [CGPoint] = []
        output.reserveCapacity(vertexCount)
        var index = 0
        for _ in 0..<vertexCount {
            guard index < attachment.vertices.count else { break }
            let influenceCount = Int(attachment.vertices[index])
            index += 1

            var x = 0.0
            var y = 0.0
            for _ in 0..<influenceCount {
                guard index + 3 < attachment.vertices.count else { break }
                let boneIndex = Int(attachment.vertices[index])
                let localX = attachment.vertices[index + 1]
                let localY = attachment.vertices[index + 2]
                let weight = attachment.vertices[index + 3]
                index += 4

                guard boneIndex >= 0, boneIndex < bones.count else { continue }
                let transformed = bones[boneIndex].transform(x: localX, y: localY)
                x += transformed.x * weight
                y += transformed.y * weight
            }
            output.append(CGPoint(x: x, y: y))
        }
        guard output.count == vertexCount, index == attachment.vertices.count else {
            return []
        }
        return output
    }

    private static func deformLength(attachment: Attachment) -> Int {
        let vertexCount = attachment.uvs.count / 2
        if attachment.vertices.count == vertexCount * 2 {
            return attachment.vertices.count
        }

        var index = 0
        var length = 0
        for _ in 0..<vertexCount {
            guard index < attachment.vertices.count else { break }
            let influenceCount = Int(attachment.vertices[index])
            index += 1 + (influenceCount * 4)
            length += influenceCount * 2
        }
        return length
    }

    private static func deformValue(_ deform: [Double], at index: Int) -> Double {
        guard index >= 0, index < deform.count else { return 0 }
        return deform[index]
    }

    private static func project(point: CGPoint, skeletonBounds: CGRect, placement: SpinePlacement) -> SIMD2<Float> {
        let projectedX: Double
        let projectedY: Double

        if placement.mode == "unity-orthographic" {
            let worldX = placement.objectX + (point.x / placement.pixelsPerUnit) * placement.objectScaleX
            let worldY = placement.objectY + (point.y / placement.pixelsPerUnit) * placement.objectScaleY
            let halfWidth = placement.orthographicSize * placement.designAspect
            projectedX = (worldX - placement.cameraX) / halfWidth
            projectedY = (worldY - placement.cameraY) / placement.orthographicSize
        } else {
            let projected = projectSkeletonBoundsPoint(point, skeletonBounds: skeletonBounds)
            projectedX = projected.x
            projectedY = projected.y
        }

        return SIMD2<Float>(
            Float((projectedX * placement.clipScale) + placement.clipOffsetX),
            Float((projectedY * placement.clipScale) + placement.clipOffsetY)
        )
    }

    private static func projectSkeletonBoundsPoint(_ point: CGPoint, skeletonBounds: CGRect) -> CGPoint {
        let width = max(skeletonBounds.width, 0.0001)
        let height = max(skeletonBounds.height, 0.0001)
        let scale = 2.0 / max(width, height)
        return CGPoint(
            x: (point.x - skeletonBounds.midX) * scale,
            y: (point.y - skeletonBounds.midY) * scale
        )
    }

    private static func atlasTexCoord(
        localU: Double,
        localV: Double,
        region: AtlasRegion,
        page: AtlasPage
    ) -> SIMD2<Float> {
        let x: Double
        let y: Double

        if region.rotated {
            let originalWidth = max(region.originalSize.width, region.bounds.width)
            let originalHeight = max(region.originalSize.height, region.bounds.height)
            let baseX = region.bounds.minX - (originalHeight - region.offset.y - region.bounds.height)
            let baseY = region.bounds.minY - (originalWidth - region.offset.x - region.bounds.width)
            x = baseX + localV * originalHeight
            y = baseY + (1.0 - localU) * originalWidth
        } else {
            let originalWidth = max(region.originalSize.width, region.bounds.width)
            let originalHeight = max(region.originalSize.height, region.bounds.height)
            let baseX = region.bounds.minX - region.offset.x
            let baseY = region.bounds.minY - (originalHeight - region.offset.y - region.bounds.height)
            x = baseX + localU * originalWidth
            y = baseY + localV * originalHeight
        }

        return SIMD2<Float>(
            Float(x / max(page.size.width, 1)),
            Float(y / max(page.size.height, 1))
        )
    }

    private static func parseColor(_ raw: String?) -> SIMD4<Float> {
        guard let raw, raw.count == 8, let value = UInt32(raw, radix: 16) else {
            return SIMD4<Float>(1, 1, 1, 1)
        }
        let red = Float((value >> 24) & 0xff) / 255.0
        let green = Float((value >> 16) & 0xff) / 255.0
        let blue = Float((value >> 8) & 0xff) / 255.0
        let alpha = Float(value & 0xff) / 255.0
        return SIMD4<Float>(red * alpha, green * alpha, blue * alpha, alpha)
    }

    private static func parseRGBColor(_ raw: String?) -> SIMD4<Float> {
        guard let raw, raw.count == 6, let value = UInt32(raw, radix: 16) else {
            return SIMD4<Float>(1, 1, 1, 1)
        }
        let red = Float((value >> 16) & 0xff) / 255.0
        let green = Float((value >> 8) & 0xff) / 255.0
        let blue = Float(value & 0xff) / 255.0
        return SIMD4<Float>(red, green, blue, 1)
    }

    private static func parseDarkColor(_ raw: String?) -> SIMD4<Float> {
        guard let raw else {
            return SIMD4<Float>(0, 0, 0, 0)
        }
        let rgbText: String
        if raw.count == 8 {
            rgbText = String(raw.prefix(6))
        } else if raw.count == 6 {
            rgbText = raw
        } else {
            return SIMD4<Float>(0, 0, 0, 0)
        }
        guard let value = UInt32(rgbText, radix: 16) else {
            return SIMD4<Float>(0, 0, 0, 0)
        }
        let red = Float((value >> 16) & 0xff) / 255.0
        let green = Float((value >> 8) & 0xff) / 255.0
        let blue = Float(value & 0xff) / 255.0
        return SIMD4<Float>(red, green, blue, 0)
    }
}
