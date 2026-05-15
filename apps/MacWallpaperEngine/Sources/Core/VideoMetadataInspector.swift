import AVFoundation
import Foundation

struct VideoMetadata {
    let presentationSize: CGSize
    let nominalFrameRate: Float
    let durationSeconds: Double?

    func effectiveFrameRate(playbackRate: Float) -> Double? {
        guard nominalFrameRate.isFinite, nominalFrameRate > 0 else {
            return nil
        }
        return Double(nominalFrameRate) * Double(playbackRate)
    }
}

enum VideoMetadataInspector {
    static func inspect(url: URL, timeoutSeconds: Double = 10) throws -> VideoMetadata {
        let semaphore = DispatchSemaphore(value: 0)
        let box = VideoMetadataResultBox()

        Task {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw EngineError.asset("video asset has no video track: \(url.path)")
                }

                let naturalSize = try await track.load(.naturalSize)
                let preferredTransform = try await track.load(.preferredTransform)
                let nominalFrameRate = try await track.load(.nominalFrameRate)
                let duration = try await asset.load(.duration)
                let durationSeconds = Self.durationSeconds(duration)

                box.set(.success(VideoMetadata(
                    presentationSize: naturalSize.applying(preferredTransform),
                    nominalFrameRate: nominalFrameRate,
                    durationSeconds: durationSeconds
                )))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeoutSeconds) == .success else {
            throw EngineError.asset("timed out while reading video metadata: \(url.path)")
        }
        guard let result = box.get() else {
            throw EngineError.asset("could not read video metadata: \(url.path)")
        }
        return try result.get()
    }

    private static func durationSeconds(_ duration: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : nil
    }
}

private final class VideoMetadataResultBox {
    private let lock = NSLock()
    private var result: Result<VideoMetadata, Error>?

    func set(_ result: Result<VideoMetadata, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() -> Result<VideoMetadata, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
