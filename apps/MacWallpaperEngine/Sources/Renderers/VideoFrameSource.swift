import AVFoundation
import CoreVideo
import Metal

final class VideoFrameSource: NSObject {
    static let pixelBufferOutputPolicy = "bgra-metal-iosurface-suppressed-player-rendering"

    private let player: AVPlayer
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private let playbackRate: Float
    private let lock = NSLock()
    private var textureCache: CVMetalTextureCache?
    private var lastTexture: CVMetalTexture?
    private var frameCounter = 0
    private var isLooping = false
    private var shouldPlay = false

    init(
        url: URL,
        device: MTLDevice,
        playbackRate: Float = 1.0
    ) throws {
        self.playbackRate = playbackRate
        let asset = AVURLAsset(url: url)
        self.item = AVPlayerItem(asset: asset)
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        self.output = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBufferAttributes)
        self.output.suppressesPlayerRendering = true
        item.add(output)
        self.player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw EngineError.renderer("Could not create CVMetalTextureCache")
        }
        self.textureCache = cache
        super.init()
        mutePlayerAudio()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(loopVideo),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        play()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pause()
    }

    func play() {
        lock.lock()
        let needsStart = shouldPlay == false
        shouldPlay = true
        lock.unlock()

        if needsStart {
            player.rate = playbackRate
        }
    }

    func pause() {
        lock.lock()
        let needsPause = shouldPlay
        shouldPlay = false
        lock.unlock()

        if needsPause {
            player.pause()
        }
    }

    func copyTextureForCurrentTime() -> MTLTexture? {
        copyTextureForCurrentTimeReportingFreshness().texture
    }

    func copyTextureForCurrentTimeReportingFreshness() -> (texture: MTLTexture?, isNewFrame: Bool) {
        lock.lock()
        defer { lock.unlock() }

        let hostTime = CACurrentMediaTime()
        guard item.status == .readyToPlay else {
            return (lastTexture.flatMap(CVMetalTextureGetTexture), false)
        }

        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else {
            return (lastTexture.flatMap(CVMetalTextureGetTexture), false)
        }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
              let textureCache else {
            return (lastTexture.flatMap(CVMetalTextureGetTexture), false)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else {
            return (lastTexture.flatMap(CVMetalTextureGetTexture), false)
        }
        lastTexture = cvTexture
        frameCounter += 1
        if frameCounter % 120 == 0 {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        return (CVMetalTextureGetTexture(cvTexture), true)
    }

    @objc private func loopVideo() {
        lock.lock()
        if isLooping {
            lock.unlock()
            return
        }
        isLooping = true
        lock.unlock()

        // Do not flush the texture cache here: the render loop may still have
        // GPU work in flight against the last-produced texture (command buffers
        // are submitted asynchronously), and flushing right at the loop boundary
        // raced with that in-flight read and produced a visible flash. The
        // periodic flush in copyTextureForCurrentTimeReportingFreshness already
        // reclaims cache resources on its own cadence, independent of looping.
        item.seek(to: .zero) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.isLooping = false
            let shouldResume = self.shouldPlay
            self.lock.unlock()
            if shouldResume {
                self.player.rate = self.playbackRate
            }
        }
    }

    private func mutePlayerAudio() {
        player.isMuted = true
        player.volume = 0
    }
}
