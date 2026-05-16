import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

enum CompositeVideoExporter {
    struct Options {
        let destination: URL
        let fps: Int
        let duration: TimeInterval
        let width: Int
        let height: Int
        let actionName: String
    }

    static func defaultDuration(runtime: NativeRuntimeCore) -> TimeInterval {
        for asset in [runtime.assetCatalog.videoAsset, runtime.assetCatalog.compositeVideoAsset].compactMap({ $0 }) {
            if let duration = try? VideoMetadataInspector.inspect(url: asset.url).durationSeconds,
               duration.isFinite,
               duration > 0 {
                return duration
            }
        }
        return 10
    }

    static func export(runtime: NativeRuntimeCore, options: Options) throws -> String {
        try validate(options: options)

        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        if runtime.assetCatalog.spineAsset != nil && compatibility.isSupported == false {
            throw EngineError.unsupported(
                "Cannot export native/source composite video because native Spine is unsupported: \(compatibility.reasonText)"
            )
        }

        let destination = options.destination.standardizedFileURL
        if FileManager.default.fileExists(atPath: destination.path) {
            throw EngineError.invalidArgument("Composite export destination already exists: \(destination.path)")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: options.width,
            AVVideoHeightKey: options.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate(width: options.width, height: options.height, fps: options.fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: options.width,
                kCVPixelBufferHeightKey as String: options.height
            ]
        )

        guard writer.canAdd(input) else {
            throw EngineError.renderer("Composite export writer cannot add video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? EngineError.renderer("Composite export writer failed to start")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(Int(ceil(options.duration * Double(options.fps))), 1)
        let timescale = CMTimeScale(options.fps)
        let renderer = try WallpaperSnapshotDiagnostics.Renderer(
            runtime: runtime,
            width: options.width,
            height: options.height
        )
        for frameIndex in 0..<frameCount {
            while input.isReadyForMoreMediaData == false {
                Thread.sleep(forTimeInterval: 0.001)
            }

            let frameTime = TimeInterval(frameIndex) / TimeInterval(options.fps)
            let snapshot = try renderer.render(
                actionName: options.actionName,
                time: frameTime
            )
            guard let pixelBufferPool = adaptor.pixelBufferPool else {
                throw EngineError.renderer("Composite export pixel buffer pool unavailable")
            }
            let pixelBuffer = try makePixelBuffer(
                image: snapshot.image,
                pool: pixelBufferPool,
                width: options.width,
                height: options.height
            )
            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: timescale)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? EngineError.renderer("Composite export failed at frame \(frameIndex)")
            }
        }

        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: timescale))
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()
        if writer.status != .completed {
            throw writer.error ?? EngineError.renderer("Composite export failed with status \(writer.status.rawValue)")
        }

        return [
            "composite video export OK",
            "output: \(destination.path)",
            "fps: \(options.fps)",
            "duration: \(formatVideoDiagnosticNumber(options.duration))s",
            "frames: \(frameCount)",
            "size: \(options.width)x\(options.height)",
            "action: \(options.actionName)"
        ].joined(separator: "\n")
    }

    private static func validate(options: Options) throws {
        guard options.fps >= 1, options.fps <= 240 else {
            throw EngineError.invalidArgument("Composite export FPS must be between 1 and 240")
        }
        guard options.duration.isFinite, options.duration > 0, options.duration <= 600 else {
            throw EngineError.invalidArgument("Composite export duration must be between 0 and 600 seconds")
        }
        guard options.width > 0,
              options.height > 0,
              options.width <= 8192,
              options.height <= 8192 else {
            throw EngineError.invalidArgument("Composite export size must be between 1x1 and 8192x8192")
        }
        let pathExtension = options.destination.pathExtension.lowercased()
        guard pathExtension == "mp4" || pathExtension == "m4v" else {
            throw EngineError.invalidArgument("Composite export destination must end in .mp4 or .m4v")
        }
    }

    private static func makePixelBuffer(
        image: CGImage,
        pool: CVPixelBufferPool,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw EngineError.renderer("Composite export could not allocate pixel buffer")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw EngineError.renderer("Composite export pixel buffer has no base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw EngineError.renderer("Composite export could not create pixel buffer context")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    private static func bitRate(width: Int, height: Int, fps: Int) -> Int {
        max(width * height * max(fps, 1) * 4, 2_000_000)
    }
}
