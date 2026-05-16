import AVFoundation
import CoreGraphics
import Foundation
import Metal
import MetalKit

struct WallpaperSnapshotDiagnostics {
    struct Snapshot {
        let image: CGImage
        let background: String
        let foreground: String
    }

    struct DiffMetrics {
        let dimensionsMatch: Bool
        let generatedSize: String
        let referenceSize: String
        let meanAbsoluteError: Double
        let maxDelta: Int
        let changedPixelRatio: Double

        var summaryLine: String {
            if dimensionsMatch == false {
                return "diff: dimension-mismatch generated=\(generatedSize) reference=\(referenceSize)"
            }
            return "diff: mae=\(WallpaperSnapshotDiagnostics.formatNumber(meanAbsoluteError)) max=\(maxDelta) changedPixels=\(WallpaperSnapshotDiagnostics.formatNumber(changedPixelRatio * 100))%"
        }
    }

    static func writeSnapshot(
        runtime: NativeRuntimeCore,
        destination: URL,
        reference: URL?,
        actionName: String,
        time: Double,
        width: Int,
        height: Int
    ) throws -> String {
        let snapshot = try renderSnapshot(
            runtime: runtime,
            actionName: actionName,
            time: time,
            width: width,
            height: height
        )
        try MetalSnapshotImage.writePNG(snapshot.image, to: destination)

        var lines = [
            "wallpaper snapshot OK",
            "action: \(actionName)",
            "time: \(formatSeconds(time))",
            "size: \(width)x\(height)",
            "fitMode: \(runtime.config.fitMode.rawValue)",
            "background: \(snapshot.background)",
            "foreground: \(snapshot.foreground)",
            "output: \(destination.path)"
        ]
        if let reference {
            lines.append(try diffMetrics(generated: snapshot.image, reference: reference).summaryLine)
        }
        return lines.joined(separator: "\n")
    }

    static func renderSnapshot(
        runtime: NativeRuntimeCore,
        actionName: String,
        time: Double,
        width: Int,
        height: Int
    ) throws -> Snapshot {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else {
            throw EngineError.invalidArgument("Wallpaper snapshot size must be between 1x1 and 8192x8192")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EngineError.renderer("Metal device unavailable for wallpaper snapshot")
        }
        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw EngineError.renderer("Could not create Metal command buffer for wallpaper snapshot")
        }
        let textureLoader = MTKTextureLoader(device: device)
        let renderTexture = try MetalSnapshotImage.makeRenderTexture(device: device, width: width, height: height)
        let normalPipelineState = try MetalCompositor.makePipeline(device: device, blendMode: .normal)
        let multiplyPipelineState = try MetalCompositor.makePipeline(device: device, blendMode: .multiply)
        let role = RenderDisplayRole(kind: .primary, policy: .full)
        let foregroundPlan = ForegroundRenderPlan.make(
            runtime: runtime,
            role: role,
            compatibility: RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        )

        let background = try backgroundTexture(
            runtime: runtime,
            foregroundPlan: foregroundPlan,
            device: device,
            textureLoader: textureLoader,
            time: time
        )

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = renderTexture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)
        passDescriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            throw EngineError.renderer("Could not create Metal render encoder for wallpaper snapshot")
        }

        if let backgroundTexture = background.texture {
            drawVideo(
                texture: backgroundTexture,
                fitMode: runtime.config.fitMode,
                drawableSize: CGSize(width: width, height: height),
                encoder: encoder,
                normalPipelineState: normalPipelineState
            )
        }

        var foreground = "none"
        if foregroundPlan.usesNativeSpine,
           let spineAsset = runtime.assetCatalog.spineAsset,
           background.usesCompositeVideo == false {
            let renderer = try SpineSetupPoseRenderer(
                spineAsset: spineAsset,
                device: device,
                playbackRate: runtime.selectedPlaybackRate,
                poseSampleFps: runtime.renderTargetFps,
                lookAnimationNames: SpineInteractionAnimationRoles.lookAnimationNames(from: runtime.manifest),
                lookIdleDeadZone: runtime.manifest.interactionPolicy?.idleDeadZone ?? 0.18,
                loopingAnimationNames: SpineInteractionAnimationRoles.loopingAnimationNames(from: runtime.manifest),
                oneShotAnimationNames: SpineInteractionAnimationRoles.oneShotAnimationNames(from: runtime.manifest)
            )
            try renderer.encodeDiagnosticPose(
                actionName: actionName,
                time: time,
                encoder: encoder,
                normalPipelineState: normalPipelineState,
                multiplyPipelineState: multiplyPipelineState
            )
            foreground = "nativeSpine"
        } else if foregroundPlan.usesCompositeVideo || background.usesCompositeVideo {
            foreground = "compositeVideo"
        } else if foregroundPlan.isBlocked {
            foreground = "blocked"
        }

        encoder.endEncoding()
        let image = try MetalSnapshotImage.readImage(
            texture: renderTexture,
            device: device,
            commandBuffer: commandBuffer
        )
        return Snapshot(image: image, background: background.label, foreground: foreground)
    }

    static func diffMetrics(generated: CGImage, reference: URL) throws -> DiffMetrics {
        let referenceImage = try MetalSnapshotImage.loadImage(from: reference)
        let generatedSize = "\(generated.width)x\(generated.height)"
        let referenceSize = "\(referenceImage.width)x\(referenceImage.height)"
        guard generated.width == referenceImage.width, generated.height == referenceImage.height else {
            return DiffMetrics(
                dimensionsMatch: false,
                generatedSize: generatedSize,
                referenceSize: referenceSize,
                meanAbsoluteError: .infinity,
                maxDelta: Int.max,
                changedPixelRatio: 1
            )
        }
        let generatedPixels = try MetalSnapshotImage.bgraPixels(generated)
        let referencePixels = try MetalSnapshotImage.bgraPixels(referenceImage)
        var totalDelta = 0
        var maxDelta = 0
        var changedPixels = 0
        let pixelCount = generated.width * generated.height
        for pixel in 0..<pixelCount {
            var pixelChanged = false
            for channel in 0..<4 {
                let index = pixel * 4 + channel
                let delta = abs(Int(generatedPixels[index]) - Int(referencePixels[index]))
                totalDelta += delta
                maxDelta = max(maxDelta, delta)
                if delta != 0 {
                    pixelChanged = true
                }
            }
            if pixelChanged {
                changedPixels += 1
            }
        }
        let mae = Double(totalDelta) / Double(max(pixelCount * 4, 1))
        let changedRatio = Double(changedPixels) / Double(max(pixelCount, 1))
        return DiffMetrics(
            dimensionsMatch: true,
            generatedSize: generatedSize,
            referenceSize: referenceSize,
            meanAbsoluteError: mae,
            maxDelta: maxDelta,
            changedPixelRatio: changedRatio
        )
    }

    private static func backgroundTexture(
        runtime: NativeRuntimeCore,
        foregroundPlan: ForegroundRenderPlan,
        device: MTLDevice,
        textureLoader: MTKTextureLoader,
        time: Double
    ) throws -> (texture: MTLTexture?, label: String, usesCompositeVideo: Bool) {
        if runtime.config.videoEnabled == false {
            return try fallbackTexture(runtime: runtime, textureLoader: textureLoader)
        }
        if (foregroundPlan.usesCompositeVideo || foregroundPlan.isNativeUnsupportedFallback),
           let compositeVideo = runtime.assetCatalog.compositeVideoAsset {
            let image = try videoFrame(url: compositeVideo.url, time: time, playbackRate: runtime.config.playbackRateOverride ?? compositeVideo.playbackRate)
            let texture = try textureLoader.newTexture(cgImage: image, options: [.SRGB: false])
            return (texture, "compositeVideo:\(compositeVideo.url.lastPathComponent)", true)
        }
        if let video = runtime.assetCatalog.videoAsset {
            let image = try videoFrame(url: video.url, time: time, playbackRate: runtime.config.playbackRateOverride ?? video.playbackRate)
            let texture = try textureLoader.newTexture(cgImage: image, options: [.SRGB: false])
            return (texture, "video:\(video.url.lastPathComponent)", false)
        }
        return try fallbackTexture(runtime: runtime, textureLoader: textureLoader)
    }

    private static func fallbackTexture(
        runtime: NativeRuntimeCore,
        textureLoader: MTKTextureLoader
    ) throws -> (texture: MTLTexture?, label: String, usesCompositeVideo: Bool) {
        let fallbackURL = runtime.assetCatalog.staticImageAssetURL
            ?? runtime.config.wallpaperRoot.appendingPathComponent("preview.jpg")
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else {
            return (nil, "white", false)
        }
        let texture = try textureLoader.newTexture(URL: fallbackURL, options: [.SRGB: false])
        return (texture, "static:\(fallbackURL.lastPathComponent)", false)
    }

    private static func videoFrame(url: URL, time: Double, playbackRate: Float) throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let duration = try VideoMetadataInspector.inspect(url: url).durationSeconds ?? .nan
        var sampleTime = max(0, time * Double(playbackRate))
        if duration.isFinite, duration > 0 {
            sampleTime = sampleTime.truncatingRemainder(dividingBy: duration)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try generator.copyCGImage(
            at: CMTime(seconds: sampleTime, preferredTimescale: 600),
            actualTime: nil
        )
    }

    private static func drawVideo(
        texture: MTLTexture,
        fitMode: RenderFitMode,
        drawableSize: CGSize,
        encoder: MTLRenderCommandEncoder,
        normalPipelineState: MTLRenderPipelineState
    ) {
        encoder.setRenderPipelineState(normalPipelineState)
        switch fitMode {
        case .fill:
            draw(texture: texture, rect: aspectFillRect(texture: texture, drawableSize: drawableSize), encoder: encoder)
        case .contain:
            draw(
                texture: texture,
                rect: aspectFillRect(texture: texture, drawableSize: drawableSize),
                color: SIMD4<Float>(0.72, 0.72, 0.72, 1),
                encoder: encoder
            )
            draw(texture: texture, rect: aspectFitRect(texture: texture, drawableSize: drawableSize), encoder: encoder)
        }
    }

    private static func draw(
        texture: MTLTexture,
        rect: CGRect,
        color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        encoder: MTLRenderCommandEncoder
    ) {
        let vertices = [
            RenderVertex(position: SIMD2<Float>(Float(rect.minX), Float(rect.minY)), texCoord: SIMD2<Float>(0, 1), color: color),
            RenderVertex(position: SIMD2<Float>(Float(rect.maxX), Float(rect.minY)), texCoord: SIMD2<Float>(1, 1), color: color),
            RenderVertex(position: SIMD2<Float>(Float(rect.minX), Float(rect.maxY)), texCoord: SIMD2<Float>(0, 0), color: color),
            RenderVertex(position: SIMD2<Float>(Float(rect.maxX), Float(rect.maxY)), texCoord: SIMD2<Float>(1, 0), color: color)
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

    private static func aspectFillRect(texture: MTLTexture, drawableSize: CGSize) -> CGRect {
        let textureAspect = CGFloat(texture.width) / CGFloat(max(texture.height, 1))
        let viewAspect = drawableSize.width / max(drawableSize.height, 1)
        if textureAspect > viewAspect {
            let width = 2.0 * (textureAspect / viewAspect)
            return CGRect(x: -width / 2.0, y: -1.0, width: width, height: 2.0)
        }
        let height = 2.0 * (viewAspect / textureAspect)
        return CGRect(x: -1.0, y: -height / 2.0, width: 2.0, height: height)
    }

    private static func aspectFitRect(texture: MTLTexture, drawableSize: CGSize) -> CGRect {
        let textureAspect = CGFloat(texture.width) / CGFloat(max(texture.height, 1))
        let viewAspect = drawableSize.width / max(drawableSize.height, 1)
        if textureAspect > viewAspect {
            let height = 2.0 * (viewAspect / textureAspect)
            return CGRect(x: -1.0, y: -height / 2.0, width: 2.0, height: height)
        }
        let width = 2.0 * (textureAspect / viewAspect)
        return CGRect(x: -width / 2.0, y: -1.0, width: width, height: 2.0)
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3fs", value)
    }

    private static func formatNumber(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
