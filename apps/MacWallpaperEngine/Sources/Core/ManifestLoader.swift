import AVFoundation
import Foundation
import ImageIO

enum ManifestLoader {
    static func load(url: URL, bundleRoot: URL) throws -> WallpaperNativeManifest {
        let manifestURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = bundleRoot.standardizedFileURL.resolvingSymlinksInPath()

        guard manifestURL.path.hasPrefix(root.path + "/") || manifestURL.path == root.path else {
            throw EngineError.manifest("manifest must be inside wallpaper bundle root")
        }

        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(WallpaperNativeManifest.self, from: data)
        try validate(manifest, bundleRoot: root)
        return manifest
    }

    private static func validate(_ manifest: WallpaperNativeManifest, bundleRoot: URL) throws {
        guard manifest.schemaVersion == "macos-wallpaper-native.v2" else {
            throw EngineError.manifest("unsupported schemaVersion \(manifest.schemaVersion)")
        }
        guard manifest.runtime.kind == "native-metal" else {
            throw EngineError.manifest("runtime.kind must be native-metal")
        }
        guard manifest.runtime.targetFps > 0,
              manifest.runtime.fallbackFps > 0,
              manifest.runtime.maxFps >= manifest.runtime.targetFps,
              manifest.runtime.targetFps >= manifest.runtime.fallbackFps else {
            throw EngineError.manifest("runtime FPS values are invalid")
        }
        try validatePerformanceTiers(manifest.runtime.performanceTiers, maxFps: manifest.runtime.maxFps)
        guard (1...3).contains(manifest.runtime.scheduler.maxInFlightCommandBuffers) else {
            throw EngineError.manifest("maxInFlightCommandBuffers must satisfy 1...3")
        }
        guard manifest.runtime.scheduler.lateFramePolicy == "drop", manifest.runtime.scheduler.catchUp == false else {
            throw EngineError.manifest("scheduler must drop late frames and disable catch-up")
        }
        guard manifest.layerBudgets.maxTexturePages > 0 else {
            throw EngineError.manifest("layerBudgets.maxTexturePages must be positive")
        }
        try validateLayerBudgets(manifest.layerBudgets)
        guard manifest.layers.isEmpty == false else {
            throw EngineError.manifest("at least one layer is required")
        }

        if manifest.validation.requirePremultipliedAlpha {
            guard manifest.assets.spine?.premultipliedAlpha != false else {
                throw EngineError.manifest("PMA is required but spine asset disables premultipliedAlpha")
            }
        }

        let layerIds = manifest.layers.map(\.id)
        guard Set(layerIds).count == layerIds.count else {
            throw EngineError.manifest("layer ids must be unique")
        }

        var assetTypeById: [String: LayerType] = [:]
        if let video = manifest.assets.video {
            assetTypeById[video.id] = .video
        }
        if let compositeVideo = manifest.assets.compositeVideo {
            guard assetTypeById[compositeVideo.id] == nil else {
                throw EngineError.manifest("asset ids must be unique")
            }
            assetTypeById[compositeVideo.id] = .video
        }
        if let spine = manifest.assets.spine {
            guard assetTypeById[spine.id] == nil else {
                throw EngineError.manifest("asset ids must be unique")
            }
            assetTypeById[spine.id] = .spine
        }

        for layer in manifest.layers {
            guard let assetType = assetTypeById[layer.asset] else {
                throw EngineError.manifest("layer \(layer.id) references missing asset \(layer.asset)")
            }
            guard assetType == layer.type else {
                throw EngineError.manifest("layer \(layer.id) type \(layer.type.rawValue) does not match asset \(layer.asset)")
            }
            try validateLayerRenderingMode(layer)
        }
        try validateInteractions(manifest.interactions)
        try validateInteractionPolicy(manifest.interactionPolicy)

        if let video = manifest.assets.video {
            try validatePlaybackRate(video.playbackRate, label: video.id)
            let videoURL = try validateRelativePath(video.path, bundleRoot: bundleRoot)
            try validateVideoDimensions(videoURL, maxDimension: manifest.layerBudgets.maxTextureDimension)
        }
        if let compositeVideo = manifest.assets.compositeVideo {
            try validatePlaybackRate(compositeVideo.playbackRate, label: compositeVideo.id)
            let compositeVideoURL = try validateRelativePath(compositeVideo.path, bundleRoot: bundleRoot)
            try validateVideoDimensions(compositeVideoURL, maxDimension: manifest.layerBudgets.maxTextureDimension)
        }
        if let spine = manifest.assets.spine {
            guard spine.version.hasPrefix("4.2") else {
                throw EngineError.manifest("Spine version \(spine.version) is not 4.2.x")
            }
            guard spine.textures.count <= manifest.layerBudgets.maxTexturePages else {
                throw EngineError.manifest("texture page count exceeds layerBudgets.maxTexturePages")
            }
            let spineJSON = try validateRelativePath(spine.json, bundleRoot: bundleRoot)
            _ = try validateRelativePath(spine.atlas, bundleRoot: bundleRoot)
            for texture in spine.textures {
                let textureURL = try validateRelativePath(texture, bundleRoot: bundleRoot)
                try validateTextureDimensions(textureURL, maxDimension: manifest.layerBudgets.maxTextureDimension)
            }
            try validateSpineJSON(
                spineJSON,
                requiredVersion: manifest.validation.requireSpineVersion,
                referencedActions: referencedAnimationActions(in: manifest.interactions)
            )
        }
    }

    private static func validatePlaybackRate(_ playbackRate: Float?, label: String) throws {
        guard let playbackRate else { return }
        guard playbackRate.isFinite, playbackRate > 0.0, playbackRate <= 4.0 else {
            throw EngineError.manifest("video asset \(label) playbackRate must satisfy 0 < playbackRate <= 4")
        }
    }

    private static func validatePerformanceTiers(_ tiers: [PerformanceTier]?, maxFps: Int) throws {
        guard let tiers else { return }
        var ids = Set<String>()
        for tier in tiers {
            guard tier.id.isEmpty == false, ids.insert(tier.id).inserted else {
                throw EngineError.manifest("performanceTier ids must be unique and non-empty")
            }
            guard tier.targetFps > 0, tier.targetFps <= maxFps else {
                throw EngineError.manifest("performanceTier \(tier.id) targetFps must satisfy 0 < targetFps <= maxFps")
            }
            if let refresh = tier.requiresDisplayRefreshHz {
                guard refresh > 0 else {
                    throw EngineError.manifest("performanceTier \(tier.id) requiresDisplayRefreshHz must be positive")
                }
            }
        }
    }

    private static func validateLayerBudgets(_ budgets: LayerBudgets) throws {
        guard budgets.maxTextureDimension > 0 else {
            throw EngineError.manifest("layerBudgets.maxTextureDimension must be positive")
        }
        guard budgets.rssTargetMb > 0, budgets.rssHardMb >= budgets.rssTargetMb else {
            throw EngineError.manifest("layerBudgets RSS values must satisfy 0 < rssTargetMb <= rssHardMb")
        }
        guard budgets.primaryCpuTargetPercent > 0,
              budgets.cpuDowngradePercent >= budgets.primaryCpuTargetPercent,
              budgets.cpuDowngradeWindowSeconds > 0 else {
            throw EngineError.manifest("layerBudgets CPU values must satisfy target > 0, downgrade >= target, window > 0")
        }
    }

    private static func validateLayerRenderingMode(_ layer: LayerConfig) throws {
        switch layer.type {
        case .video:
            guard layer.renderingMode == nil else {
                throw EngineError.manifest("video layer \(layer.id) must not define renderingMode")
            }
        case .spine:
            guard (layer.renderingMode ?? "setup-mesh") == "setup-mesh" else {
                throw EngineError.manifest("spine layer \(layer.id) renderingMode must be setup-mesh")
            }
        }
    }

    private static func validateInteractions(_ interactions: [InteractionConfig]) throws {
        for interaction in interactions {
            switch interaction.event {
            case .pointerMove:
                if let mapping = interaction.mapping {
                    guard mapping == "lookDirection" else {
                        throw EngineError.manifest("unsupported pointerMove mapping: \(mapping)")
                    }
                }
                if let actions = interaction.actions {
                    for (key, action) in actions {
                        guard key.isEmpty == false, action.isEmpty == false else {
                            throw EngineError.manifest("pointerMove actions must not contain empty keys or values")
                        }
                    }
                }
            case .pointerDown:
                guard let hitZones = interaction.hitZones, hitZones.isEmpty == false else {
                    throw EngineError.manifest("pointerDown interaction requires at least one hitZone")
                }
                for hitZone in hitZones {
                    try validateHitZone(hitZone)
                }
            }
            if let buttons = interaction.buttons, buttons.isEmpty {
                throw EngineError.manifest("\(interaction.event.rawValue) buttons must not be empty")
            }
        }
    }

    private static func validateInteractionPolicy(_ policy: InteractionPolicy?) throws {
        guard let policy else { return }
        if let pointerSmoothing = policy.pointerSmoothing {
            guard pointerSmoothing.isFinite, pointerSmoothing > 0, pointerSmoothing <= 1 else {
                throw EngineError.manifest("interactionPolicy.pointerSmoothing must satisfy 0 < value <= 1")
            }
        }
        if let idleDeadZone = policy.idleDeadZone {
            guard idleDeadZone.isFinite, idleDeadZone >= 0, idleDeadZone < 0.5 else {
                throw EngineError.manifest("interactionPolicy.idleDeadZone must satisfy 0 <= value < 0.5")
            }
        }
        if let directionSwitchMargin = policy.directionSwitchMargin {
            guard directionSwitchMargin.isFinite, directionSwitchMargin >= 0, directionSwitchMargin < 0.5 else {
                throw EngineError.manifest("interactionPolicy.directionSwitchMargin must satisfy 0 <= value < 0.5")
            }
        }
        if let defaultClickTailSeconds = policy.defaultClickTailSeconds {
            try validateInteractionDuration(defaultClickTailSeconds, label: "interactionPolicy.defaultClickTailSeconds")
        }
        if let releaseFadeSeconds = policy.releaseFadeSeconds {
            try validateInteractionDuration(releaseFadeSeconds, label: "interactionPolicy.releaseFadeSeconds")
        }
    }

    private static func validateHitZone(_ hitZone: HitZone) throws {
        guard hitZone.id.isEmpty == false else {
            throw EngineError.manifest("hitZone id must not be empty")
        }
        guard hitZone.action.isEmpty == false else {
            throw EngineError.manifest("hitZone \(hitZone.id) action must not be empty")
        }
        guard hitZone.rect.count == 4, hitZone.rect.allSatisfy(\.isFinite) else {
            throw EngineError.manifest("hitZone \(hitZone.id) rect must contain four finite numbers")
        }

        let x0 = hitZone.rect[0]
        let y0 = hitZone.rect[1]
        let x1 = hitZone.rect[2]
        let y1 = hitZone.rect[3]
        guard x0 >= 0, y0 >= 0, x1 <= 1, y1 <= 1, x0 < x1, y0 < y1 else {
            throw EngineError.manifest("hitZone \(hitZone.id) rect must satisfy 0 <= x0 < x1 <= 1 and 0 <= y0 < y1 <= 1")
        }
        if let tailSeconds = hitZone.tailSeconds {
            try validateInteractionDuration(tailSeconds, label: "hitZone \(hitZone.id) tailSeconds")
        }
        if let buttons = hitZone.buttons, buttons.isEmpty {
            throw EngineError.manifest("hitZone \(hitZone.id) buttons must not be empty")
        }
    }

    private static func validateInteractionDuration(_ value: Double, label: String) throws {
        guard value.isFinite, value >= 0, value <= 10 else {
            throw EngineError.manifest("\(label) must satisfy 0 <= value <= 10")
        }
    }

    @discardableResult
    private static func validateRelativePath(_ path: String?, bundleRoot: URL) throws -> URL {
        guard let path else { return bundleRoot }
        guard path.hasPrefix("/") == false else {
            throw EngineError.manifest("asset path must be relative: \(path)")
        }
        let root = bundleRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else {
            throw EngineError.manifest("asset escapes bundle root: \(path)")
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw EngineError.asset("missing asset: \(resolved.path)")
        }
        return resolved
    }

    private static func validateTextureDimensions(_ url: URL, maxDimension: Int) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw EngineError.asset("could not read texture dimensions: \(url.path)")
        }
        guard width <= maxDimension, height <= maxDimension else {
            throw EngineError.asset("texture exceeds max dimension \(maxDimension): \(url.path)")
        }
    }

    private static func validateVideoDimensions(_ url: URL, maxDimension: Int) throws {
        let transformedSize = try loadVideoPresentationSize(url)
        let width = Int(abs(transformedSize.width))
        let height = Int(abs(transformedSize.height))
        guard width <= maxDimension, height <= maxDimension else {
            throw EngineError.asset("video exceeds max dimension \(maxDimension): \(url.path)")
        }
    }

    private static func loadVideoPresentationSize(_ url: URL) throws -> CGSize {
        final class MetadataResultBox {
            private let lock = NSLock()
            private var result: Result<CGSize, Error>?

            func set(_ result: Result<CGSize, Error>) {
                lock.lock()
                self.result = result
                lock.unlock()
            }

            func get() -> Result<CGSize, Error>? {
                lock.lock()
                defer { lock.unlock() }
                return result
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = MetadataResultBox()

        Task {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw EngineError.asset("video asset has no video track: \(url.path)")
                }
                let naturalSize = try await track.load(.naturalSize)
                let preferredTransform = try await track.load(.preferredTransform)
                box.set(.success(naturalSize.applying(preferredTransform)))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 10) == .success else {
            throw EngineError.asset("timed out while reading video dimensions: \(url.path)")
        }
        guard let result = box.get() else {
            throw EngineError.asset("could not read video dimensions: \(url.path)")
        }
        return try result.get()
    }

    private static func validateSpineJSON(_ url: URL, requiredVersion: String, referencedActions: Set<String>) throws {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.asset("Spine JSON root is not an object")
        }
        guard let skeleton = root["skeleton"] as? [String: Any],
              let actualVersion = skeleton["spine"] as? String else {
            throw EngineError.asset("Spine JSON missing skeleton.spine")
        }

        let requiredPrefix = requiredVersion.replacingOccurrences(of: "x", with: "")
        guard actualVersion.hasPrefix(requiredPrefix) else {
            throw EngineError.asset("Spine JSON version \(actualVersion) does not match \(requiredVersion)")
        }

        guard let animations = root["animations"] as? [String: Any] else {
            throw EngineError.asset("Spine JSON missing animations")
        }
        for action in referencedActions where animations[action] == nil {
            throw EngineError.asset("interaction references missing Spine animation: \(action)")
        }
    }

    private static func referencedAnimationActions(in interactions: [InteractionConfig]) -> Set<String> {
        var actions = Set<String>()
        for interaction in interactions {
            interaction.actions?.values.forEach { actions.insert($0) }
            interaction.hitZones?.forEach { actions.insert($0.action) }
        }
        return actions
    }
}
