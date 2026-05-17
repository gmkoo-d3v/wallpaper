import Foundation
import ImageIO

enum ManifestLoader {
    static func load(url: URL, bundleRoot: URL) throws -> WallpaperNativeManifest {
        let requestedManifestURL = url.standardizedFileURL
        let requestedRoot = bundleRoot.standardizedFileURL

        guard requestedManifestURL.path.hasPrefix(requestedRoot.path + "/") || requestedManifestURL.path == requestedRoot.path else {
            throw EngineError.manifest("manifest must be inside wallpaper bundle root")
        }

        let manifestURL = requestedManifestURL.resolvingSymlinksInPath()
        let root = requestedRoot.resolvingSymlinksInPath()
        guard manifestURL.path.hasPrefix(root.path + "/") || manifestURL.path == root.path else {
            throw EngineError.manifest("manifest must stay inside wallpaper bundle root after resolving symlinks")
        }

        let data = try Data(contentsOf: requestedManifestURL)
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(WallpaperNativeManifest.self, from: data)
        try validate(manifest, bundleRoot: root, requestedBundleRoot: requestedRoot)
        return manifest
    }

    private static func validate(
        _ manifest: WallpaperNativeManifest,
        bundleRoot: URL,
        requestedBundleRoot: URL
    ) throws {
        guard manifest.schemaVersion == "macos-wallpaper-native.v2" else {
            throw EngineError.manifest("unsupported schemaVersion \(manifest.schemaVersion)")
        }
        guard manifest.runtime.kind == "native-metal" else {
            throw EngineError.manifest("runtime.kind must be native-metal")
        }
        guard manifest.validation.bundleRootOnly else {
            throw EngineError.manifest("validation.bundleRootOnly must be true")
        }
        guard manifest.validation.rejectUnknownLayerTypes else {
            throw EngineError.manifest("validation.rejectUnknownLayerTypes must be true")
        }
        try WallpaperBundleFilesystemGuard.rejectSymlinkEntries(in: requestedBundleRoot)
        try validateMetadata(manifest.metadata)
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
        if requiresStaticPreview(manifest.displayPolicy), manifest.assets.staticImage == nil {
            let previewURL = bundleRoot.appendingPathComponent("preview.jpg")
            guard FileManager.default.fileExists(atPath: previewURL.path) else {
                throw EngineError.asset("static display policy requires preview.jpg")
            }
            try validateTextureDimensions(previewURL, maxDimension: manifest.layerBudgets.maxTextureDimension)
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
        if let staticImage = manifest.assets.staticImage {
            assetTypeById[staticImage.id] = .staticImage
        }
        if let video = manifest.assets.video {
            guard assetTypeById[video.id] == nil else {
                throw EngineError.manifest("asset ids must be unique")
            }
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

        if let staticImage = manifest.assets.staticImage {
            let imageURL = try validateRelativePath(staticImage.path, bundleRoot: bundleRoot)
            try validateTextureDimensions(imageURL, maxDimension: manifest.layerBudgets.maxTextureDimension)
        }
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
            try validateNativeSpineFallbackReadiness(manifest, bundleRoot: bundleRoot)
        } else if manifest.interactions.isEmpty == false {
            throw EngineError.manifest("interactions require a Spine asset in the native-metal runtime")
        }
    }

    private static func validateNativeSpineFallbackReadiness(
        _ manifest: WallpaperNativeManifest,
        bundleRoot: URL
    ) throws {
        guard manifest.layers.contains(where: { $0.type == .spine }) else { return }
        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(
            manifest: manifest,
            bundleRoot: bundleRoot
        )
        guard compatibility.isSupported || manifest.assets.compositeVideo != nil else {
            throw EngineError.manifest(
                "native Spine renderer cannot safely play this bundle and no compositeVideo fallback exists: \(compatibility.reasonText)"
            )
        }
    }

    private static func validateMetadata(_ metadata: WallpaperMetadata?) throws {
        guard let metadata else { return }
        if let id = metadata.id {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  trimmed.contains("/") == false,
                  trimmed.contains("\\") == false,
                  trimmed != ".",
                  trimmed != ".." else {
                throw EngineError.manifest("metadata.id must be non-empty and must not contain path separators")
            }
        }
        if let title = metadata.title {
            guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw EngineError.manifest("metadata.title must not be empty")
            }
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
        case .staticImage:
            guard layer.renderingMode == nil else {
                throw EngineError.manifest("static image layer \(layer.id) must not define renderingMode")
            }
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

    private static func requiresStaticPreview(_ displayPolicy: DisplayPolicy) -> Bool {
        [
            displayPolicy.primary,
            displayPolicy.secondary,
            displayPolicy.fullscreenObscured,
            displayPolicy.occluded
        ].contains(.static)
    }

    private static func validateInteractions(_ interactions: [InteractionConfig]) throws {
        for interaction in interactions {
            switch interaction.event {
            case .pointerMove:
                guard let mapping = interaction.mapping else {
                    throw EngineError.manifest("pointerMove interaction requires mapping")
                }
                guard mapping == "lookDirection" else {
                    throw EngineError.manifest("unsupported pointerMove mapping: \(mapping)")
                }
                if let neutralPoint = interaction.neutralPoint {
                    try validateInteractionPoint(
                        neutralPoint,
                        label: "pointerMove neutralPoint",
                        min: 0,
                        max: 1,
                        allowZero: true
                    )
                }
                if let deadZone = interaction.deadZone {
                    try validateInteractionPoint(
                        deadZone,
                        label: "pointerMove deadZone",
                        min: 0,
                        max: 0.5,
                        allowZero: true,
                        allowMax: false
                    )
                }
                if let actions = interaction.actions {
                    for (key, action) in actions {
                        guard key.isEmpty == false, action.isEmpty == false else {
                            throw EngineError.manifest("pointerMove actions must not contain empty keys or values")
                        }
                    }
                }
                try validateLookDirectionActions(interaction.actions)
            case .pointerDown:
                if let buttons = interaction.buttons, buttons.isEmpty {
                    throw EngineError.manifest("pointerDown buttons must not be empty")
                }
                let defaultButtons = interaction.buttons ?? [.left]
                let hitZones = interaction.hitZones ?? []
                guard hitZones.isEmpty == false || interaction.defaultAction != nil else {
                    throw EngineError.manifest("pointerDown interaction requires at least one hitZone or defaultAction")
                }
                for hitZone in hitZones {
                    try validateHitZone(hitZone)
                }
                try validateUniqueHitZoneIDs(hitZones)
                try validateHitZoneTopology(hitZones, defaultButtons: defaultButtons)
                if let defaultAction = interaction.defaultAction {
                    try validatePointerDownDefaultAction(defaultAction)
                }
            }
            if let buttons = interaction.buttons, buttons.isEmpty {
                throw EngineError.manifest("\(interaction.event.rawValue) buttons must not be empty")
            }
        }
    }

    private static func validateUniqueHitZoneIDs(_ hitZones: [HitZone]) throws {
        var seen = Set<String>()
        for hitZone in hitZones {
            guard seen.insert(hitZone.id).inserted else {
                throw EngineError.manifest("hitZone ids must be unique within a pointerDown interaction: \(hitZone.id)")
            }
        }
    }

    private static func validateLookDirectionActions(_ actions: [String: String]?) throws {
        let requiredActions: Set<String> = ["left", "right", "up", "down", "idle"]
        let declaredActions = Set(actions?.keys.map { $0 } ?? [])
        let missingActions = requiredActions.subtracting(declaredActions).sorted()
        guard missingActions.isEmpty else {
            throw EngineError.manifest("pointerMove lookDirection actions missing required key(s): \(missingActions.joined(separator: ","))")
        }
        let unsupportedActions = declaredActions.subtracting(requiredActions).sorted()
        guard unsupportedActions.isEmpty else {
            throw EngineError.manifest("pointerMove lookDirection actions contain unsupported key(s): \(unsupportedActions.joined(separator: ","))")
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

    private static func validateHitZoneTopology(
        _ hitZones: [HitZone],
        defaultButtons: [PointerButton]
    ) throws {
        guard hitZones.count > 1 else { return }
        for leftIndex in hitZones.indices {
            let left = hitZones[leftIndex]
            for right in hitZones.dropFirst(leftIndex + 1) {
                let leftButtons = Set(left.buttons ?? defaultButtons)
                let rightButtons = Set(right.buttons ?? defaultButtons)
                let sharedButtons = leftButtons.intersection(rightButtons)
                guard sharedButtons.isEmpty == false else { continue }
                guard hitZoneRectsOverlap(left.rect, right.rect) else { continue }

                let buttonText = sharedButtons
                    .map(\.rawValue)
                    .sorted()
                    .joined(separator: "+")
                throw EngineError.manifest(
                    "hitZones \(left.id) and \(right.id) overlap for button(s) \(buttonText); split the rects because hit-zone priority is not supported"
                )
            }
        }
    }

    private static func hitZoneRectsOverlap(_ left: [Double], _ right: [Double]) -> Bool {
        guard left.count == 4, right.count == 4 else { return false }
        let xOverlap = max(left[0], right[0]) < min(left[2], right[2])
        let yOverlap = max(left[1], right[1]) < min(left[3], right[3])
        return xOverlap && yOverlap
    }

    private static func validatePointerDownDefaultAction(_ action: PointerDownDefaultAction) throws {
        guard action.action.isEmpty == false else {
            throw EngineError.manifest("pointerDown defaultAction action must not be empty")
        }
        if let tailSeconds = action.tailSeconds {
            try validateInteractionDuration(tailSeconds, label: "pointerDown defaultAction tailSeconds")
        }
        if let buttons = action.buttons, buttons.isEmpty {
            throw EngineError.manifest("pointerDown defaultAction buttons must not be empty")
        }
    }

    private static func validateInteractionDuration(_ value: Double, label: String) throws {
        guard value.isFinite, value >= 0, value <= 10 else {
            throw EngineError.manifest("\(label) must satisfy 0 <= value <= 10")
        }
    }

    private static func validateInteractionPoint(
        _ point: InteractionPoint,
        label: String,
        min: Double,
        max: Double,
        allowZero: Bool,
        allowMax: Bool = true
    ) throws {
        let values = [point.x, point.y]
        guard values.allSatisfy(\.isFinite) else {
            throw EngineError.manifest("\(label) must contain finite x/y values")
        }
        let upperBoundIsValid: (Double) -> Bool = allowMax ? { $0 <= max } : { $0 < max }
        if allowZero {
            guard values.allSatisfy({ $0 >= min && upperBoundIsValid($0) }) else {
                let upper = allowMax ? "<=" : "<"
                throw EngineError.manifest("\(label) values must satisfy \(min) <= value \(upper) \(max)")
            }
        } else {
            guard values.allSatisfy({ $0 > min && upperBoundIsValid($0) }) else {
                let upper = allowMax ? "<=" : "<"
                throw EngineError.manifest("\(label) values must satisfy \(min) < value \(upper) \(max)")
            }
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
        let transformedSize = try VideoMetadataInspector.inspect(url: url).presentationSize
        let width = Int(abs(transformedSize.width))
        let height = Int(abs(transformedSize.height))
        guard width <= maxDimension, height <= maxDimension else {
            throw EngineError.asset("video exceeds max dimension \(maxDimension): \(url.path)")
        }
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
            if let defaultAction = interaction.defaultAction {
                actions.insert(defaultAction.action)
            }
        }
        return actions
    }
}
