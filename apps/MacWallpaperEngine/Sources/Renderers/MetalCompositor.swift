import AVFoundation
import Metal
import MetalKit

final class MetalCompositor: NSObject, MTKViewDelegate {
    static let pausedFirstFramePolicy = "draw-static-fallback-before-pausing"
    static let telemetryPublishIntervalSeconds: CFTimeInterval = 0.5

    private static let fallbackClearColor = MTLClearColor(
        red: 0.95,
        green: 0.95,
        blue: 0.965,
        alpha: 1.0
    )

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let normalPipelineState: MTLRenderPipelineState
    private let additivePipelineState: MTLRenderPipelineState
    private let multiplyPipelineState: MTLRenderPipelineState
    private let screenPipelineState: MTLRenderPipelineState
    private let textureLoader: MTKTextureLoader
    private let runtime: NativeRuntimeCore
    private let displayRole: RenderDisplayRole
    private let displayName: String
    private let interaction: InteractionController
    private let interactionHitZones: [InteractionHitZoneSummary]
    private let governor: ResourceGovernor
    private let semaphore: DispatchSemaphore
    private let targetRenderFps: Int
    private let idleCommand: String

    private var videoSource: VideoFrameSource?
    private var deskOcclusionSource: VideoFrameSource?
    private var resourceFallbackVideoSource: VideoFrameSource?
    private var interactionTexture: MTLTexture?
    private var solidOverlayTexture: MTLTexture?
    private var usingCompositeVideo = false
    private var fallbackBackground: MTLTexture?
    private var lastPrimaryVideoTexture: MTLTexture?
    private var lastResourceFallbackVideoTexture: MTLTexture?
    private var lastDeskOcclusionTexture: MTLTexture?
    private var spineRenderer: SpineSetupPoseRenderer?
    private var isPausedByHost = false
    private var isPausedByThermal = false
    private var isUsingResourceFallbackVideo = false
    private var hasSubmittedDrawable = false
    private var idleRenderFps = 1
    private var activeRenderFps = 1
    private var lastTelemetryPublishAt: CFTimeInterval = 0

    init(
        device: MTLDevice,
        runtime: NativeRuntimeCore,
        displayRole: RenderDisplayRole,
        displayName: String,
        displayRefreshFps: Int?,
        interaction: InteractionController
    ) throws {
        let displayPerformancePlan = runtime.performancePlan(displayRefreshFps: displayRefreshFps)
        let displayTargetFps = displayPerformancePlan.effectiveTargetFps
        let displayPoseSampleFps = runtime.nativeSpinePoseSampleFps(displayRefreshFps: displayRefreshFps)
        let displayIdlePoseSampleFps = runtime.nativeSpineIdlePoseSampleFps(displayRefreshFps: displayRefreshFps)
        let nativeSpineCompatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        let foregroundPlan = ForegroundRenderPlan.make(
            runtime: runtime,
            role: displayRole,
            compatibility: nativeSpineCompatibility
        )
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            throw EngineError.renderer("Could not create Metal command queue")
        }
        self.commandQueue = commandQueue
        self.textureLoader = MTKTextureLoader(device: device)
        self.runtime = runtime
        self.displayRole = displayRole
        self.displayName = displayName
        self.interaction = interaction
        self.interactionHitZones = InteractionPlan(
            interactions: runtime.manifest.interactions,
            policy: runtime.manifest.interactionPolicy
        ).hitZoneSummaries()
        self.governor = ResourceGovernor(
            manifest: runtime.manifest,
            targetFps: displayTargetFps,
            videoOnlyFallbackEnabled: foregroundPlan.allowsVideoOnlyResourceFallback
        )
        self.semaphore = DispatchSemaphore(value: displayPerformancePlan.maxInFlightCommandBuffers)
        self.targetRenderFps = displayTargetFps
        self.idleCommand = Self.idleCommand(from: runtime.manifest)
        self.normalPipelineState = try Self.makePipeline(device: device, blendMode: .normal)
        self.additivePipelineState = try Self.makePipeline(device: device, blendMode: .additive)
        self.multiplyPipelineState = try Self.makePipeline(device: device, blendMode: .multiply)
        self.screenPipelineState = try Self.makePipeline(device: device, blendMode: .screen)
        super.init()

        if foregroundPlan.isBlocked {
            throw EngineError.renderer(
                "Native Spine renderer cannot safely play this bundle and no compositeVideo fallback exists: \(nativeSpineCompatibility.reasonText)"
            )
        }
        if foregroundPlan.isNativeUnsupportedFallback {
            fputs(
                "Native Spine renderer unsupported for this bundle; using compositeVideo fallback: \(nativeSpineCompatibility.reasonText)\n",
                stderr
            )
        }

        let selectedVideo: VideoAsset?
        if runtime.config.videoEnabled == false || displayRole.playsVideo == false {
            selectedVideo = nil
        } else if foregroundPlan.usesCompositeVideo, let compositeVideo = runtime.assetCatalog.compositeVideoAsset {
            selectedVideo = compositeVideo
            usingCompositeVideo = true
        } else {
            selectedVideo = runtime.assetCatalog.videoAsset
        }
        idleRenderFps = runtime.idleRenderFps(
            displayRefreshFps: displayRefreshFps,
            videoAsset: selectedVideo,
            playsVideo: selectedVideo != nil,
            rendersNativeForeground: foregroundPlan.usesNativeSpine && displayRole.rendersForeground && usingCompositeVideo == false
        )
        activeRenderFps = runtime.activeRenderFps(
            displayRefreshFps: displayRefreshFps,
            videoAsset: selectedVideo,
            playsVideo: selectedVideo != nil,
            rendersNativeForeground: foregroundPlan.usesNativeSpine && displayRole.rendersForeground && usingCompositeVideo == false
        )

        if let selectedVideo {
            self.videoSource = try VideoFrameSource(
                url: selectedVideo.url,
                device: device,
                playbackRate: runtime.config.playbackRateOverride ?? selectedVideo.playbackRate,
                audioPolicy: runtime.manifest.runtime.effectiveAudioPolicy,
                audioEnabled: runtime.config.audioEnabled
            )
        }
        if runtime.config.videoEnabled,
           foregroundPlan.usesNativeSpine,
           displayRole.rendersForeground,
           let backgroundVideo = runtime.assetCatalog.videoAsset,
           selectedVideo?.url != backgroundVideo.url {
            self.deskOcclusionSource = try VideoFrameSource(
                url: backgroundVideo.url,
                device: device,
                playbackRate: runtime.config.playbackRateOverride ?? backgroundVideo.playbackRate,
                audioPolicy: runtime.manifest.runtime.effectiveAudioPolicy,
                audioEnabled: runtime.config.audioEnabled
            )
        }
        if runtime.config.videoEnabled,
           foregroundPlan.usesNativeSpine,
           foregroundPlan.allowsVideoOnlyResourceFallback,
           displayRole.rendersForeground,
           usingCompositeVideo == false,
           let compositeVideo = runtime.assetCatalog.compositeVideoAsset {
            let fallbackSource = try VideoFrameSource(
                url: compositeVideo.url,
                device: device,
                playbackRate: runtime.config.playbackRateOverride ?? compositeVideo.playbackRate,
                audioPolicy: runtime.manifest.runtime.effectiveAudioPolicy,
                audioEnabled: runtime.config.audioEnabled
            )
            fallbackSource.pause()
            self.resourceFallbackVideoSource = fallbackSource
        }
        self.interactionTexture = Self.makeInteractionTexture(device: device)
        self.solidOverlayTexture = Self.makeSolidOverlayTexture(device: device)

        let fallbackImageURL = runtime.assetCatalog.staticImageAssetURL
            ?? runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg")
        self.fallbackBackground = (try? textureLoader.newTexture(
            URL: fallbackImageURL,
            options: [.SRGB: false]
        )) ?? Self.makeSolidBackgroundTexture(device: device)

        if foregroundPlan.usesNativeSpine,
           usingCompositeVideo == false,
           displayRole.rendersForeground,
           let spineAsset = runtime.assetCatalog.spineAsset {
            self.spineRenderer = try SpineSetupPoseRenderer(
                spineAsset: spineAsset,
                device: device,
                playbackRate: runtime.selectedPlaybackRate,
                poseSampleFps: displayPoseSampleFps,
                idlePoseSampleFps: displayIdlePoseSampleFps,
                lookAnimationNames: SpineInteractionAnimationRoles.lookAnimationNames(from: runtime.manifest),
                lookNeutralPoint: SpineInteractionAnimationRoles.lookNeutralPoint(from: runtime.manifest),
                lookDeadZone: SpineInteractionAnimationRoles.lookDeadZone(
                    from: runtime.manifest,
                    fallback: runtime.manifest.interactionPolicy?.idleDeadZone ?? 0.18
                ),
                lookIdleDeadZone: runtime.manifest.interactionPolicy?.idleDeadZone ?? 0.18,
                physicsIdlePolicy: runtime.manifest.runtime.effectivePhysicsIdlePolicy,
                idleAnimationName: SpineInteractionAnimationRoles.idleAnimationName(from: runtime.manifest),
                loopingAnimationNames: SpineInteractionAnimationRoles.loopingAnimationNames(from: runtime.manifest),
                oneShotAnimationNames: SpineInteractionAnimationRoles.oneShotAnimationNames(from: runtime.manifest),
                audioOutputEnabled: runtime.audioOutputEnabled
            )
            if let spineRenderer {
                print("spine setup mesh OK: batches=\(spineRenderer.batchCount) vertices=\(spineRenderer.triangleVertexCount)")
            }
        }
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

    func needsPausedWarmupDrawable(ifHostPaused paused: Bool) -> Bool {
        paused && hasSubmittedDrawable == false
    }

    func needsVisibleWarmupDrawable() -> Bool {
        hasSubmittedDrawable == false
    }

    func draw(in view: MTKView) {
        let hostPausedBeforeFirstDrawable = isPausedByHost && hasSubmittedDrawable == false
        guard isPausedByHost == false || hostPausedBeforeFirstDrawable else { return }

        let now = CACurrentMediaTime()
        let currentFps = hostPausedBeforeFirstDrawable ? 1 : governor.frameStarted(now: now)
        publishTelemetry(now: now)
        let thermalPaused = hostPausedBeforeFirstDrawable ? false : governor.shouldPauseForThermal
        let resourcePaused = hostPausedBeforeFirstDrawable ? false : governor.shouldPauseForResourceBudget
        let shouldPauseForThermalOrResource = thermalPaused || resourcePaused
        let shouldPause = hostPausedBeforeFirstDrawable || shouldPauseForThermalOrResource
        if hostPausedBeforeFirstDrawable == false {
            if shouldPauseForThermalOrResource != isPausedByThermal {
                isPausedByThermal = shouldPauseForThermalOrResource
                if shouldPauseForThermalOrResource {
                    pauseAllVideoSources()
                } else {
                    resumeActiveVideoSources()
                }
            }
        }
        if shouldPause {
            if view.preferredFramesPerSecond != 1 {
                view.preferredFramesPerSecond = 1
            }
            if hasSubmittedDrawable {
                return
            }
        }

        setResourceFallbackVideoActive(governor.shouldUseVideoOnlyFallback && resourceFallbackVideoSource != nil)

        guard semaphore.wait(timeout: .now()) == .success else {
            governor.recordSkippedFrame(reason: .commandBufferBackpressure)
            publishTelemetry(now: now)
            return
        }
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else {
            semaphore.signal()
            governor.recordSkippedFrame(reason: .drawableUnavailable)
            publishTelemetry(now: now)
            return
        }
        descriptor.colorAttachments[0].clearColor = Self.fallbackClearColor
        descriptor.colorAttachments[0].loadAction = .clear
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            semaphore.signal()
            governor.recordSkippedFrame(reason: .commandBufferUnavailable)
            publishTelemetry(now: now)
            return
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            semaphore.signal()
            governor.recordSkippedFrame(reason: .encoderUnavailable)
            publishTelemetry(now: now)
            return
        }

        commandBuffer.addCompletedHandler { [semaphore] _ in
            semaphore.signal()
        }

        encoder.setRenderPipelineState(normalPipelineState)
        let interactionSnapshot = interaction.snapshot()
        let pacedFps = framePacingFps(resourceFps: currentFps, interaction: interactionSnapshot)
        if shouldPause == false, view.preferredFramesPerSecond != pacedFps {
            view.preferredFramesPerSecond = pacedFps
        }

        let baseVideoTexture: MTLTexture?
        if shouldPause {
            baseVideoTexture = lastResourceFallbackVideoTexture ?? lastPrimaryVideoTexture
        } else if isUsingResourceFallbackVideo {
            let freshTexture = resourceFallbackVideoSource?.copyTextureForCurrentTime()
            if let freshTexture {
                lastResourceFallbackVideoTexture = freshTexture
            }
            baseVideoTexture = freshTexture ?? lastResourceFallbackVideoTexture
        } else {
            let freshTexture = videoSource?.copyTextureForCurrentTime()
            if let freshTexture {
                lastPrimaryVideoTexture = freshTexture
            }
            baseVideoTexture = freshTexture ?? lastPrimaryVideoTexture
        }
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

        if shouldPause == false, isUsingResourceFallbackVideo == false {
            drawDeskOcclusion(baseVideoTexture: usingCompositeVideo ? nil : baseVideoTexture, drawableSize: view.drawableSize, encoder: encoder)
        }
        if shouldPause == false, isUsingResourceFallbackVideo == false, displayRole.rendersForeground, let spineRenderer {
            spineRenderer.draw(
                command: interactionSnapshot.command,
                pointer: interactionSnapshot.pointer,
                drawableSize: view.drawableSize,
                contentRect: foregroundContentRect,
                encoder: encoder,
                normalPipelineState: normalPipelineState,
                additivePipelineState: additivePipelineState,
                multiplyPipelineState: multiplyPipelineState,
                screenPipelineState: screenPipelineState
            )
        }
        drawInteractionOverlay(
            interactionSnapshot,
            contentRect: foregroundContentRect,
            drawableSize: view.drawableSize,
            encoder: encoder
        )

        encoder.endEncoding()
        commandBuffer.present(drawable)
        governor.recordSubmittedFrame()
        hasSubmittedDrawable = true
        if hostPausedBeforeFirstDrawable {
            view.isPaused = true
        }
        publishTelemetry(now: now)
        commandBuffer.commit()
    }

    private func publishTelemetry(now: CFTimeInterval, force: Bool = false) {
        guard force || now - lastTelemetryPublishAt >= Self.telemetryPublishIntervalSeconds else {
            return
        }
        lastTelemetryPublishAt = now
        runtime.telemetry.record(displayName: displayName, role: displayRole, snapshot: governor.snapshot)
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
        let freshOcclusionTexture = deskOcclusionSource?.copyTextureForCurrentTime()
        if let freshOcclusionTexture {
            lastDeskOcclusionTexture = freshOcclusionTexture
        }
        guard let texture = baseVideoTexture ?? freshOcclusionTexture ?? lastDeskOcclusionTexture else { return }

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
        contentRect: CGRect,
        drawableSize: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        guard runtime.config.interactionDebugOverlay,
              displayRole.allowsInteraction,
              let solidOverlayTexture else {
            return
        }

        for (index, hitZone) in interactionHitZones.enumerated() {
            guard let rect = overlayRect(for: hitZone.rect, contentRect: contentRect) else { continue }
            let isActive = interaction.command == hitZone.action
            let palette = overlayPalette(index: index, active: isActive, pulse: interaction.clickPulse)
            draw(texture: solidOverlayTexture, rect: rect, color: palette.fill, encoder: encoder)
            drawBorder(texture: solidOverlayTexture, rect: rect, drawableSize: drawableSize, color: palette.border, encoder: encoder)
        }

        guard let interactionTexture else { return }
        let dotSize = max(min(drawableSize.width, drawableSize.height) > 0 ? 58.0 : 0.0, 1.0)
        let dotWidth = dotSize / max(drawableSize.width, 1.0) * 2.0
        let dotHeight = dotSize / max(drawableSize.height, 1.0) * 2.0
        let center = overlayPoint(interaction.pointer, contentRect: contentRect)
        let pulseAlpha = Float(0.38 + min(max(interaction.clickPulse, 0), 1) * 0.42)
        let pointerColor = premultipliedColor(red: 0.10, green: 0.41, blue: 0.83, alpha: pulseAlpha)
        let pointerRect = CGRect(
            x: center.x - dotWidth / 2.0,
            y: center.y - dotHeight / 2.0,
            width: dotWidth,
            height: dotHeight
        )
        draw(texture: interactionTexture, rect: pointerRect, color: pointerColor, encoder: encoder)
    }

    private func drawBorder(
        texture: MTLTexture,
        rect: CGRect,
        drawableSize: CGSize,
        color: SIMD4<Float>,
        encoder: MTLRenderCommandEncoder
    ) {
        let thicknessX = 2.0 / max(drawableSize.width, 1.0) * 2.0
        let thicknessY = 2.0 / max(drawableSize.height, 1.0) * 2.0
        let top = CGRect(x: rect.minX, y: rect.maxY - thicknessY, width: rect.width, height: thicknessY)
        let bottom = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: thicknessY)
        let left = CGRect(x: rect.minX, y: rect.minY, width: thicknessX, height: rect.height)
        let right = CGRect(x: rect.maxX - thicknessX, y: rect.minY, width: thicknessX, height: rect.height)
        for edge in [top, bottom, left, right] {
            draw(texture: texture, rect: edge, color: color, encoder: encoder)
        }
    }

    private func overlayRect(for normalizedRect: [Double], contentRect: CGRect) -> CGRect? {
        guard normalizedRect.count == 4 else { return nil }
        let x0 = contentRect.minX + CGFloat(normalizedRect[0]) * contentRect.width
        let x1 = contentRect.minX + CGFloat(normalizedRect[2]) * contentRect.width
        let yTop = contentRect.maxY - CGFloat(normalizedRect[1]) * contentRect.height
        let yBottom = contentRect.maxY - CGFloat(normalizedRect[3]) * contentRect.height
        guard x1 > x0, yTop > yBottom else { return nil }
        return CGRect(x: x0, y: yBottom, width: x1 - x0, height: yTop - yBottom)
    }

    private func overlayPoint(_ point: CGPoint, contentRect: CGRect) -> CGPoint {
        CGPoint(
            x: contentRect.minX + point.x * contentRect.width,
            y: contentRect.maxY - point.y * contentRect.height
        )
    }

    private func overlayPalette(index: Int, active: Bool, pulse: CGFloat) -> (fill: SIMD4<Float>, border: SIMD4<Float>) {
        let base: (red: Float, green: Float, blue: Float) = index.isMultiple(of: 2)
            ? (0.10, 0.41, 0.83)
            : (0.96, 0.62, 0.04)
        let activeBoost = Float(active ? min(max(pulse, 0), 1) * 0.18 + 0.18 : 0)
        let fillAlpha = Float(active ? 0.30 : 0.14) + activeBoost
        let borderAlpha = Float(active ? 0.88 : 0.52)
        return (
            fill: premultipliedColor(red: base.red, green: base.green, blue: base.blue, alpha: fillAlpha),
            border: premultipliedColor(red: base.red, green: base.green, blue: base.blue, alpha: borderAlpha)
        )
    }

    private func premultipliedColor(red: Float, green: Float, blue: Float, alpha: Float) -> SIMD4<Float> {
        SIMD4<Float>(red * alpha, green * alpha, blue * alpha, alpha)
    }

    private func framePacingFps(resourceFps: Int, interaction: InteractionSnapshot) -> Int {
        let interactionActive = interaction.clickPulse > 0 || interaction.command != idleCommand
        let requestedFps = interactionActive ? activeRenderFps : idleRenderFps
        return max(1, min(resourceFps, requestedFps))
    }

    private static func idleCommand(from manifest: WallpaperNativeManifest) -> String {
        SpineInteractionAnimationRoles.idleAnimationName(from: manifest)
    }

    private static func makeSolidOverlayTexture(device: MTLDevice) -> MTLTexture? {
        makeSolidTexture(device: device, pixel: [255, 255, 255, 255])
    }

    private static func makeSolidBackgroundTexture(device: MTLDevice) -> MTLTexture? {
        makeSolidTexture(device: device, pixel: [242, 242, 246, 255])
    }

    private static func makeSolidTexture(device: MTLDevice, pixel: [UInt8]) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: pixel,
            bytesPerRow: 4
        )
        return texture
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

    static func makePipeline(device: MTLDevice, blendMode: RenderBlendMode) throws -> MTLRenderPipelineState {
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
        case .additive:
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        case .multiply:
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        case .screen:
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceColor
        }
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = blendMode == .additive ? .one : .oneMinusSourceAlpha
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
