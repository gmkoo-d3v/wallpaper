import AVFoundation
import Metal
import MetalKit

final class MetalCompositor: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let normalPipelineState: MTLRenderPipelineState
    private let multiplyPipelineState: MTLRenderPipelineState
    private let textureLoader: MTKTextureLoader
    private let runtime: NativeRuntimeCore
    private let displayRole: RenderDisplayRole
    private let interaction: InteractionController
    private let governor: ResourceGovernor
    private let semaphore: DispatchSemaphore

    private var videoSource: VideoFrameSource?
    private var deskOcclusionSource: VideoFrameSource?
    private var resourceFallbackVideoSource: VideoFrameSource?
    private var interactionTexture: MTLTexture?
    private var usingCompositeVideo = false
    private var fallbackBackground: MTLTexture?
    private var spineRenderer: SpineSetupPoseRenderer?
    private var isPausedByHost = false
    private var isPausedByThermal = false
    private var isUsingResourceFallbackVideo = false

    init(
        device: MTLDevice,
        runtime: NativeRuntimeCore,
        displayRole: RenderDisplayRole,
        interaction: InteractionController
    ) throws {
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            throw EngineError.renderer("Could not create Metal command queue")
        }
        self.commandQueue = commandQueue
        self.textureLoader = MTKTextureLoader(device: device)
        self.runtime = runtime
        self.displayRole = displayRole
        self.interaction = interaction
        self.governor = ResourceGovernor(manifest: runtime.manifest, targetFps: runtime.renderTargetFps)
        self.semaphore = DispatchSemaphore(value: runtime.performancePlan.maxInFlightCommandBuffers)
        self.normalPipelineState = try Self.makePipeline(device: device, blendMode: .normal)
        self.multiplyPipelineState = try Self.makePipeline(device: device, blendMode: .multiply)
        super.init()

        let selectedVideo: VideoAsset?
        let shouldUseCompositeVideo = runtime.config.foregroundMode == .compositeVideo
            && displayRole.prefersCompositeVideo
            && runtime.assetCatalog.compositeVideoAsset != nil
        if runtime.config.videoEnabled == false || displayRole.playsVideo == false {
            selectedVideo = nil
        } else if shouldUseCompositeVideo, let compositeVideo = runtime.assetCatalog.compositeVideoAsset {
            selectedVideo = compositeVideo
            usingCompositeVideo = true
        } else {
            selectedVideo = runtime.assetCatalog.videoAsset
        }

        if let selectedVideo {
            self.videoSource = try VideoFrameSource(
                url: selectedVideo.url,
                device: device,
                playbackRate: runtime.config.playbackRateOverride ?? selectedVideo.playbackRate
            )
        }
        if runtime.config.videoEnabled,
           runtime.config.foregroundMode == .nativeSpine,
           displayRole.rendersForeground,
           let backgroundVideo = runtime.assetCatalog.videoAsset,
           selectedVideo?.url != backgroundVideo.url {
            self.deskOcclusionSource = try VideoFrameSource(
                url: backgroundVideo.url,
                device: device,
                playbackRate: runtime.config.playbackRateOverride ?? backgroundVideo.playbackRate
            )
        }
        if runtime.config.videoEnabled,
           runtime.config.foregroundMode == .nativeSpine,
           displayRole.rendersForeground,
           usingCompositeVideo == false,
           let compositeVideo = runtime.assetCatalog.compositeVideoAsset {
            let fallbackSource = try VideoFrameSource(
                url: compositeVideo.url,
                device: device,
                playbackRate: runtime.config.playbackRateOverride ?? compositeVideo.playbackRate
            )
            fallbackSource.pause()
            self.resourceFallbackVideoSource = fallbackSource
        }
        self.interactionTexture = Self.makeInteractionTexture(device: device)

        let fallbackImageURL = runtime.assetCatalog.staticImageAssetURL
            ?? runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg")
        self.fallbackBackground = try? textureLoader.newTexture(
            URL: fallbackImageURL,
            options: [.SRGB: false]
        )

        if runtime.config.foregroundMode == .nativeSpine,
           usingCompositeVideo == false,
           displayRole.rendersForeground,
           let spineAsset = runtime.assetCatalog.spineAsset {
            self.spineRenderer = try SpineSetupPoseRenderer(
                spineAsset: spineAsset,
                device: device,
                playbackRate: runtime.selectedPlaybackRate,
                poseSampleFps: runtime.renderTargetFps,
                loopingAnimationNames: Self.loopingAnimationNames(from: runtime.manifest),
                oneShotAnimationNames: Self.oneShotAnimationNames(from: runtime.manifest)
            )
            if let spineRenderer {
                print("spine setup mesh OK: batches=\(spineRenderer.batchCount) vertices=\(spineRenderer.triangleVertexCount)")
            }
        }
    }

    private static func loopingAnimationNames(from manifest: WallpaperNativeManifest) -> Set<String> {
        var names: Set<String> = ["idle"]
        for interaction in manifest.interactions where interaction.event == .pointerDown {
            interaction.hitZones?
                .filter { ($0.trigger ?? .tap) == .hold }
                .forEach { names.insert($0.action) }
        }
        return names
    }

    private static func oneShotAnimationNames(from manifest: WallpaperNativeManifest) -> Set<String> {
        var names: Set<String> = []
        for interaction in manifest.interactions where interaction.event == .pointerDown {
            interaction.hitZones?
                .filter { ($0.trigger ?? .tap) == .tap }
                .forEach { names.insert($0.action) }
        }
        return names
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func setPausedByHost(_ paused: Bool) {
        isPausedByHost = paused
        if paused {
            pauseAllVideoSources()
        } else {
            resumeActiveVideoSources()
        }
    }

    func draw(in view: MTKView) {
        guard isPausedByHost == false else { return }

        let now = CACurrentMediaTime()
        let currentFps = governor.frameStarted(now: now)
        let thermalPaused = governor.shouldPauseForThermal
        let resourcePaused = governor.shouldPauseForResourceBudget
        let shouldPause = thermalPaused || resourcePaused
        if shouldPause != isPausedByThermal {
            isPausedByThermal = shouldPause
            if shouldPause {
                pauseAllVideoSources()
            } else {
                resumeActiveVideoSources()
            }
        }
        if shouldPause {
            if view.preferredFramesPerSecond != 1 {
                view.preferredFramesPerSecond = 1
            }
            return
        }

        if view.preferredFramesPerSecond != currentFps {
            view.preferredFramesPerSecond = max(currentFps, 1)
        }

        setResourceFallbackVideoActive(governor.shouldUseVideoOnlyFallback && resourceFallbackVideoSource != nil)

        guard semaphore.wait(timeout: .now()) == .success else {
            governor.recordSkippedFrame(reason: .commandBufferBackpressure)
            return
        }
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else {
            semaphore.signal()
            governor.recordSkippedFrame(reason: .drawableUnavailable)
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            semaphore.signal()
            governor.recordSkippedFrame(reason: .commandBufferUnavailable)
            return
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            semaphore.signal()
            governor.recordSkippedFrame(reason: .encoderUnavailable)
            return
        }

        commandBuffer.addCompletedHandler { [semaphore] _ in
            semaphore.signal()
        }

        encoder.setRenderPipelineState(normalPipelineState)
        let interactionSnapshot = interaction.snapshot()

        let baseVideoTexture = isUsingResourceFallbackVideo
            ? resourceFallbackVideoSource?.copyTextureForCurrentTime()
            : videoSource?.copyTextureForCurrentTime()
        let foregroundContentRect: CGRect
        if let videoTexture = baseVideoTexture {
            drawVideo(texture: videoTexture, drawableSize: view.drawableSize, interaction: interactionSnapshot, encoder: encoder)
            foregroundContentRect = videoContentRect(texture: videoTexture, drawableSize: view.drawableSize)
        } else if let fallbackBackground {
            foregroundContentRect = videoContentRect(texture: fallbackBackground, drawableSize: view.drawableSize)
            draw(texture: fallbackBackground, rect: foregroundContentRect, encoder: encoder)
        } else {
            foregroundContentRect = CGRect(x: -1, y: -1, width: 2, height: 2)
        }

        if isUsingResourceFallbackVideo == false {
            drawDeskOcclusion(baseVideoTexture: usingCompositeVideo ? nil : baseVideoTexture, drawableSize: view.drawableSize, encoder: encoder)
        }
        if isUsingResourceFallbackVideo == false, displayRole.rendersForeground, let spineRenderer {
            spineRenderer.draw(
                command: interactionSnapshot.command,
                pointer: interactionSnapshot.pointer,
                drawableSize: view.drawableSize,
                contentRect: foregroundContentRect,
                encoder: encoder,
                normalPipelineState: normalPipelineState,
                multiplyPipelineState: multiplyPipelineState
            )
        }
        drawInteractionOverlay(interactionSnapshot, drawableSize: view.drawableSize, encoder: encoder)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        governor.recordSubmittedFrame()
        commandBuffer.commit()
    }

    private func setResourceFallbackVideoActive(_ active: Bool) {
        guard active != isUsingResourceFallbackVideo else { return }
        isUsingResourceFallbackVideo = active
        resumeActiveVideoSources()
    }

    private func pauseAllVideoSources() {
        videoSource?.pause()
        deskOcclusionSource?.pause()
        resourceFallbackVideoSource?.pause()
    }

    private func resumeActiveVideoSources() {
        guard isPausedByHost == false, isPausedByThermal == false else {
            pauseAllVideoSources()
            return
        }

        if isUsingResourceFallbackVideo {
            videoSource?.pause()
            deskOcclusionSource?.pause()
            resourceFallbackVideoSource?.play()
        } else {
            resourceFallbackVideoSource?.pause()
            videoSource?.play()
            deskOcclusionSource?.play()
        }
    }

    private func draw(
        texture: MTLTexture,
        rect: CGRect,
        color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        encoder: MTLRenderCommandEncoder
    ) {
        draw(
            texture: texture,
            rect: rect,
            texRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            color: color,
            encoder: encoder
        )
    }

    private func draw(
        texture: MTLTexture,
        rect: CGRect,
        texRect: CGRect,
        color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        encoder: MTLRenderCommandEncoder
    ) {
        let x0 = Float(rect.minX)
        let y0 = Float(rect.minY)
        let x1 = Float(rect.maxX)
        let y1 = Float(rect.maxY)
        let u0 = Float(texRect.minX)
        let v0 = Float(texRect.minY)
        let u1 = Float(texRect.maxX)
        let v1 = Float(texRect.maxY)
        let vertices = [
            RenderVertex(position: SIMD2<Float>(x0, y0), texCoord: SIMD2<Float>(u0, v1), color: color),
            RenderVertex(position: SIMD2<Float>(x1, y0), texCoord: SIMD2<Float>(u1, v1), color: color),
            RenderVertex(position: SIMD2<Float>(x0, y1), texCoord: SIMD2<Float>(u0, v0), color: color),
            RenderVertex(position: SIMD2<Float>(x1, y1), texCoord: SIMD2<Float>(u1, v0), color: color)
        ]
        var uniforms = RenderUniforms.make(
            scale: 1,
            offset: SIMD2<Float>(0, 0),
            aspectScale: SIMD2<Float>(1, 1)
        )
        encoder.setVertexBytes(vertices, length: MemoryLayout<RenderVertex>.stride * vertices.count, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
    }

    private func drawVideo(
        texture: MTLTexture,
        drawableSize: CGSize,
        interaction: InteractionSnapshot,
        encoder: MTLRenderCommandEncoder
    ) {
        switch runtime.config.fitMode {
        case .fill:
            let rect = videoContentRect(texture: texture, drawableSize: drawableSize)
            draw(texture: texture, rect: interactiveVideoRect(rect, interaction: interaction), encoder: encoder)
        case .contain:
            let fillRect = aspectFillRect(texture: texture, drawableSize: drawableSize)
            draw(texture: texture, rect: fillRect, color: SIMD4<Float>(0.72, 0.72, 0.72, 1.0), encoder: encoder)
            let fitRect = videoContentRect(texture: texture, drawableSize: drawableSize)
            draw(texture: texture, rect: interactiveVideoRect(fitRect, interaction: interaction), encoder: encoder)
        }
    }

    private func videoContentRect(texture: MTLTexture, drawableSize: CGSize) -> CGRect {
        switch runtime.config.fitMode {
        case .fill:
            return aspectFillRect(texture: texture, drawableSize: drawableSize)
        case .contain:
            return aspectFitRect(texture: texture, drawableSize: drawableSize)
        }
    }

    private func aspectFillRect(texture: MTLTexture, drawableSize: CGSize) -> CGRect {
        let textureAspect = CGFloat(texture.width) / CGFloat(max(texture.height, 1))
        let viewAspect = drawableSize.width / max(drawableSize.height, 1)

        if textureAspect > viewAspect {
            let width = 2.0 * (textureAspect / viewAspect)
            return CGRect(x: -width / 2.0, y: -1.0, width: width, height: 2.0)
        } else {
            let height = 2.0 * (viewAspect / textureAspect)
            return CGRect(x: -1.0, y: -height / 2.0, width: 2.0, height: height)
        }
    }

    private func aspectFitRect(texture: MTLTexture, drawableSize: CGSize) -> CGRect {
        let textureAspect = CGFloat(texture.width) / CGFloat(max(texture.height, 1))
        let viewAspect = drawableSize.width / max(drawableSize.height, 1)

        if textureAspect > viewAspect {
            let height = 2.0 * (viewAspect / textureAspect)
            return CGRect(x: -1.0, y: -height / 2.0, width: 2.0, height: height)
        } else {
            let width = 2.0 * (textureAspect / viewAspect)
            return CGRect(x: -width / 2.0, y: -1.0, width: width, height: 2.0)
        }
    }

    private func interactiveVideoRect(_ rect: CGRect, interaction: InteractionSnapshot) -> CGRect {
        _ = interaction
        return rect
    }

    private func drawDeskOcclusion(
        baseVideoTexture: MTLTexture?,
        drawableSize: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        guard displayRole.rendersForeground, usingCompositeVideo == false else { return }
        guard let texture = baseVideoTexture ?? deskOcclusionSource?.copyTextureForCurrentTime() else { return }

        let fullRect: CGRect
        switch runtime.config.fitMode {
        case .fill:
            fullRect = aspectFillRect(texture: texture, drawableSize: drawableSize)
        case .contain:
            fullRect = aspectFitRect(texture: texture, drawableSize: drawableSize)
        }

        let topFromTexture: CGFloat = 0.805
        let height = fullRect.height * (1.0 - topFromTexture)
        guard height > 0 else { return }
        let rect = CGRect(x: fullRect.minX, y: fullRect.minY, width: fullRect.width, height: height)
        let texRect = CGRect(x: 0, y: topFromTexture, width: 1, height: 1.0 - topFromTexture)
        draw(texture: texture, rect: rect, texRect: texRect, encoder: encoder)
    }

    private func drawInteractionOverlay(
        _ interaction: InteractionSnapshot,
        drawableSize: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        _ = interaction
        _ = drawableSize
        _ = encoder
    }

    private static func makeInteractionTexture(device: MTLDevice) -> MTLTexture? {
        let size = 96
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let center = CGFloat(size - 1) / 2.0
        for y in 0..<size {
            for x in 0..<size {
                let dx = (CGFloat(x) - center) / center
                let dy = (CGFloat(y) - center) / center
                let distance = min(sqrt(dx * dx + dy * dy), 1.0)
                let falloff = pow(1.0 - distance, 2.4)
                let alpha = UInt8(max(0, min(255, Int(falloff * 255))))
                let offset = (y * size + x) * 4
                pixels[offset] = alpha
                pixels[offset + 1] = alpha
                pixels[offset + 2] = alpha
                pixels[offset + 3] = alpha
            }
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: size * 4
        )
        return texture
    }

    private static func makePipeline(device: MTLDevice, blendMode: RenderBlendMode) throws -> MTLRenderPipelineState {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }

        let cacheKey = PipelineCacheKey(deviceID: device.registryID, blendMode: blendMode)
        if let cached = pipelineStates[cacheKey] {
            return cached
        }

        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "wallpaper_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "wallpaper_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        switch blendMode {
        case .normal:
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        case .multiply:
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        }
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelineStates[cacheKey] = state
        return state
    }

    private struct PipelineCacheKey: Hashable {
        let deviceID: UInt64
        let blendMode: RenderBlendMode
    }

    private static let pipelineLock = NSLock()
    private static var pipelineStates: [PipelineCacheKey: MTLRenderPipelineState] = [:]

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex {
        float2 position;
        float2 texCoord;
        float4 color;
    };

    struct RasterData {
        float4 position [[position]];
        float2 texCoord;
        float4 color;
    };

    struct Uniforms {
        float4 transform;
        float4 aspectScale;
    };

    vertex RasterData wallpaper_vertex(
        uint vertexID [[vertex_id]],
        const device Vertex *vertices [[buffer(0)]],
        constant Uniforms &uniforms [[buffer(1)]]
    ) {
        RasterData out;
        float2 position = vertices[vertexID].position * uniforms.transform.x;
        position *= uniforms.aspectScale.xy;
        position += uniforms.transform.yz;
        out.position = float4(position, 0.0, 1.0);
        out.texCoord = vertices[vertexID].texCoord;
        out.color = vertices[vertexID].color;
        return out;
    }

    fragment float4 wallpaper_fragment(
        RasterData in [[stage_in]],
        texture2d<float> colorTexture [[texture(0)]]
    ) {
        constexpr sampler textureSampler(
            mag_filter::linear,
            min_filter::linear,
            mip_filter::linear,
            address::clamp_to_edge
        );
        float4 sample = colorTexture.sample(textureSampler, in.texCoord);
        return sample * in.color;
    }
    """
}
