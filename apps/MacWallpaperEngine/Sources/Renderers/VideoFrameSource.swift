import AVFoundation
import CoreVideo
import Metal

final class VideoFrameSource: NSObject {
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private let playbackRate: Float
    private let audioPolicy: AudioPolicy
    private let audioEnabled: Bool
    private let lock = NSLock()
    private var textureCache: CVMetalTextureCache?
    private var lastTexture: CVMetalTexture?
    private var frameCounter = 0
    private var isLooping = false
    private var shouldPlay = false

    init(
        url: URL,
        device: MTLDevice,
        playbackRate: Float = 1.0,
        audioPolicy: AudioPolicy = .muted,
        audioEnabled: Bool = false
    ) throws {
        self.playbackRate = playbackRate
        self.audioPolicy = audioPolicy
        self.audioEnabled = audioEnabled
        let asset = AVURLAsset(url: url)
        self.item = AVPlayerItem(asset: asset)
        self.output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        item.add(output)
        self.player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw EngineError.renderer("Could not create CVMetalTextureCache")
        }
        self.textureCache = cache
        super.init()
        configureAudioPolicy()

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
        lock.lock()
        defer { lock.unlock() }

        let hostTime = CACurrentMediaTime()
        guard item.status == .readyToPlay else {
            return lastTexture.flatMap(CVMetalTextureGetTexture)
        }

        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else {
            return lastTexture.flatMap(CVMetalTextureGetTexture)
        }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
              let textureCache else {
            return lastTexture.flatMap(CVMetalTextureGetTexture)
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
            return lastTexture.flatMap(CVMetalTextureGetTexture)
        }
        lastTexture = cvTexture
        frameCounter += 1
        if frameCounter % 120 == 0 {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        return CVMetalTextureGetTexture(cvTexture)
    }

    @objc private func loopVideo() {
        lock.lock()
        if isLooping {
            lock.unlock()
            return
        }
        isLooping = true
        let cache = textureCache
        lock.unlock()

        if let cache {
            CVMetalTextureCacheFlush(cache, 0)
        }
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

    private func configureAudioPolicy() {
        switch audioPolicy {
        case .muted, .disabled:
            player.isMuted = true
            player.volume = 0
        case .userControlled:
            player.isMuted = audioEnabled == false
            player.volume = audioEnabled ? 1.0 : 0
        }
    }
}
