import Foundation
import ImageIO

private struct WallpaperEngineProjectJSON: Decodable {
    let title: String?
    let description: String?
    let type: String
    let file: String
    let preview: String?
    let version: Int?
}

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

        if let adaptedManifest = try loadWallpaperEngineVideoProjectIfNeeded(
            requestedManifestURL: requestedManifestURL,
            requestedBundleRoot: requestedRoot,
            resolvedBundleRoot: root
        ) {
            try validate(adaptedManifest, bundleRoot: root, requestedBundleRoot: requestedRoot)
            return adaptedManifest
        }

        let data = try Data(contentsOf: requestedManifestURL)
        try ManifestSchemaResource.validateManifestData(data)
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(WallpaperNativeManifest.self, from: data)
        try validate(manifest, bundleRoot: root, requestedBundleRoot: requestedRoot)
        return manifest
    }

    static func manifestURL(forBundleRoot root: URL) throws -> URL {
        let bundleRoot = root.standardizedFileURL
        let nativeManifestURL = bundleRoot.appendingPathComponent("wallpaper.native.json")
        if FileManager.default.fileExists(atPath: nativeManifestURL.path) {
            return nativeManifestURL
        }
        if let projectURL = try findWallpaperEngineProjectJSON(in: bundleRoot) {
            return projectURL
        }
        throw EngineError.manifest("Wallpaper bundle does not contain wallpaper.native.json or a Wallpaper Engine video project.json: \(bundleRoot.path)")
    }

    static func wallpaperEnginePreviewURL(forBundleRoot root: URL) -> URL? {
        let bundleRoot = root.standardizedFileURL
        guard let projectURL = try? findWallpaperEngineProjectJSON(in: bundleRoot),
              let data = try? Data(contentsOf: projectURL),
              let project = try? JSONDecoder().decode(WallpaperEngineProjectJSON.self, from: data),
              let preview = project.preview?.trimmingCharacters(in: .whitespacesAndNewlines),
              preview.isEmpty == false,
              let previewURL = try? resolveWallpaperEngineProjectAsset(
                preview,
                projectURL: projectURL,
                requestedBundleRoot: bundleRoot
              ),
              FileManager.default.fileExists(atPath: previewURL.path) else {
            return nil
        }
        return previewURL
    }

    private static func loadWallpaperEngineVideoProjectIfNeeded(
        requestedManifestURL: URL,
        requestedBundleRoot: URL,
        resolvedBundleRoot: URL
    ) throws -> WallpaperNativeManifest? {
        let fileManager = FileManager.default
        let requestedName = requestedManifestURL.lastPathComponent
        let projectURL: URL?

        if requestedName == "project.json" {
            projectURL = requestedManifestURL
        } else if requestedName == "wallpaper.native.json",
                  fileManager.fileExists(atPath: requestedManifestURL.path) == false {
            projectURL = try findWallpaperEngineProjectJSON(in: requestedBundleRoot)
        } else {
            projectURL = nil
        }

        guard let projectURL else { return nil }
        let resolvedProjectURL = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedProjectURL.path.hasPrefix(resolvedBundleRoot.path + "/") || resolvedProjectURL.path == resolvedBundleRoot.path else {
            throw EngineError.manifest("Wallpaper Engine project.json must stay inside wallpaper bundle root after resolving symlinks")
        }

        let data = try Data(contentsOf: projectURL)
        let project = try JSONDecoder().decode(WallpaperEngineProjectJSON.self, from: data)
        return try makeWallpaperEngineVideoManifest(
            project: project,
            projectURL: projectURL,
            requestedBundleRoot: requestedBundleRoot
        )
    }

    private static func makeWallpaperEngineVideoManifest(
        project: WallpaperEngineProjectJSON,
        projectURL: URL,
        requestedBundleRoot: URL
    ) throws -> WallpaperNativeManifest {
        guard project.type == "video" else {
            throw EngineError.manifest("Wallpaper Engine project.json type must be video, got \(project.type)")
        }

        let videoURL = try resolveWallpaperEngineProjectAsset(
            project.file,
            projectURL: projectURL,
            requestedBundleRoot: requestedBundleRoot
        )
        let videoPath = try relativePath(from: requestedBundleRoot, to: videoURL)
        let projectPath = try relativePath(from: requestedBundleRoot, to: projectURL)
        let bundleID = sanitizedBundleID(requestedBundleRoot.lastPathComponent)

        return WallpaperNativeManifest(
            schemaVersion: "macos-wallpaper-native.v2",
            metadata: WallpaperMetadata(
                id: bundleID,
                title: trimmedNonEmpty(project.title),
                author: nil,
                version: project.version.map(String.init),
                description: trimmedNonEmpty(project.description)
            ),
            sourceProvenance: SourceProvenance(
                sourceType: .wallpaperEngineVideo,
                sourceRuntime: "wallpaper-engine",
                projectType: "video",
                sourceDescriptors: [
                    SourceDescriptor(kind: .wallpaperEngineProjectJSON, path: projectPath)
                ],
                sourceAdapter: SourceAdapterContract(
                    id: "wallpaper-engine-video-project-adapter",
                    version: "1",
                    kind: "project-json-video",
                    fieldDerivations: [
                        SourceAdapterFieldDerivation(
                            field: "assets.video.path",
                            mode: .imported,
                            source: "project.json:file",
                            owner: nil,
                            requiredCapability: nil,
                            reason: nil
                        ),
                        SourceAdapterFieldDerivation(
                            field: "metadata.title",
                            mode: .imported,
                            source: "project.json:title",
                            owner: nil,
                            requiredCapability: nil,
                            reason: nil
                        ),
                        SourceAdapterFieldDerivation(
                            field: "metadata.description",
                            mode: .imported,
                            source: "project.json:description",
                            owner: nil,
                            requiredCapability: nil,
                            reason: nil
                        ),
                        SourceAdapterFieldDerivation(
                            field: "layers",
                            mode: .imported,
                            source: "project.json:type",
                            owner: nil,
                            requiredCapability: nil,
                            reason: "A Wallpaper Engine video project maps to one native video layer."
                        ),
                        SourceAdapterFieldDerivation(
                            field: "runtime",
                            mode: .platformPolicy,
                            source: nil,
                            owner: "mac-wallpaper-engine",
                            requiredCapability: nil,
                            reason: "The native runtime owns scheduling, FPS, and audio policy for imported video projects."
                        ),
                        SourceAdapterFieldDerivation(
                            field: "displayPolicy",
                            mode: .platformPolicy,
                            source: nil,
                            owner: "mac-wallpaper-engine",
                            requiredCapability: nil,
                            reason: "Display roles are mapped to the macOS wallpaper host policy."
                        ),
                        SourceAdapterFieldDerivation(
                            field: "thermalPolicy",
                            mode: .platformPolicy,
                            source: nil,
                            owner: "mac-wallpaper-engine",
                            requiredCapability: nil,
                            reason: "Thermal behavior is controlled by the macOS runtime."
                        ),
                        SourceAdapterFieldDerivation(
                            field: "layerBudgets",
                            mode: .platformPolicy,
                            source: nil,
                            owner: "mac-wallpaper-engine",
                            requiredCapability: nil,
                            reason: "Resource budgets are runtime safety limits, not Wallpaper Engine project fields."
                        ),
                        SourceAdapterFieldDerivation(
                            field: "general.properties",
                            mode: .unsupported,
                            source: "project.json:general.properties",
                            owner: "mac-wallpaper-engine",
                            requiredCapability: "declarative-properties",
                            reason: "Generic Wallpaper Engine properties are not executed by the safe video adapter."
                        ),
                        SourceAdapterFieldDerivation(
                            field: "script",
                            mode: .unsupported,
                            source: nil,
                            owner: "mac-wallpaper-engine",
                            requiredCapability: "safe-script-runtime",
                            reason: "Arbitrary Wallpaper Engine scripts are not executed."
                        ),
                        SourceAdapterFieldDerivation(
                            field: "effects",
                            mode: .unsupported,
                            source: nil,
                            owner: "mac-wallpaper-engine",
                            requiredCapability: "effect-whitelist",
                            reason: "Wallpaper Engine shader/effect import is not part of the video adapter."
                        )
                    ],
                    capabilities: ["video-layer", "project-json-import"],
                    limitations: [
                        "Wallpaper Engine script execution is not imported by the video adapter.",
                        "Wallpaper Engine effect/shader settings are not imported by the video adapter."
                    ]
                ),
                importedFields: ["metadata.title", "metadata.description", "assets.video.path", "layers"],
                calibratedFields: nil,
                platformPolicyFields: ["runtime", "displayPolicy", "thermalPolicy", "layerBudgets"],
                unsupportedFields: ["general.properties", "script", "effects"],
                notes: ["Synthesized from Wallpaper Engine project.json because no wallpaper.native.json was present."]
            ),
            runtime: RuntimeConfig(
                kind: "native-metal",
                targetFps: 60,
                maxFps: 120,
                fallbackFps: 30,
                idleRenderFps: nil,
                nativeSpinePoseFps: nil,
                nativeSpineIdlePoseFps: nil,
                nativeSpineTransitionSeconds: nil,
                nativeSpineTransitionPolicy: nil,
                physicsIdlePolicy: nil,
                audioPolicy: .muted,
                performanceTiers: nil,
                scheduler: SchedulerConfig(
                    maxInFlightCommandBuffers: 1,
                    lateFramePolicy: "drop",
                    catchUp: false
                )
            ),
            displayPolicy: DisplayPolicy(
                primary: .full,
                secondary: .full,
                fullscreenObscured: .pause,
                occluded: .pause
            ),
            thermalPolicy: ThermalPolicy(
                nominal: "60fps",
                serious: "30fps",
                critical: "pause"
            ),
            layerBudgets: LayerBudgets(
                maxTexturePages: 1,
                maxTextureDimension: 8192,
                rssTargetMb: 180,
                rssHardMb: 360,
                primaryCpuTargetPercent: 8,
                cpuDowngradePercent: 16,
                cpuDowngradeWindowSeconds: 10
            ),
            interactionPolicy: nil,
            assets: AssetManifest(
                staticImage: nil,
                video: VideoAssetConfig(id: "backgroundVideo", path: videoPath, playbackRate: 1.0),
                compositeVideo: nil,
                spine: nil
            ),
            layers: [
                LayerConfig(
                    id: "background",
                    type: .video,
                    asset: "backgroundVideo",
                    renderingMode: nil,
                    foregroundOcclusion: nil
                )
            ],
            interactions: [],
            bindings: nil,
            effects: nil,
            validation: ValidationConfig(
                bundleRootOnly: true,
                requirePremultipliedAlpha: false,
                requireSpineVersion: "4.2.x",
                rejectUnknownLayerTypes: true
            )
        )
    }

    private static func findWallpaperEngineProjectJSON(in root: URL) throws -> URL? {
        let bundleRoot = root.standardizedFileURL
        let rootProjectURL = bundleRoot.appendingPathComponent("project.json")
        if FileManager.default.fileExists(atPath: rootProjectURL.path) {
            return rootProjectURL
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: bundleRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let projectURLs = children
            .filter(ProjectPaths.directoryExists)
            .map { $0.appendingPathComponent("project.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        guard projectURLs.count <= 1 else {
            throw EngineError.manifest("Wallpaper bundle contains multiple Wallpaper Engine project.json files; select a specific project directory")
        }
        return projectURLs.first
    }

    private static func resolveWallpaperEngineProjectAsset(
        _ path: String,
        projectURL: URL,
        requestedBundleRoot: URL
    ) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw EngineError.manifest("Wallpaper Engine project.json file path must not be empty")
        }
        guard trimmed.hasPrefix("/") == false,
              trimmed.contains("\\") == false,
              trimmed.split(separator: "/").contains("..") == false else {
            throw EngineError.manifest("Wallpaper Engine project.json asset path must be relative and must not escape the project")
        }
        let assetURL = projectURL
            .deletingLastPathComponent()
            .appendingPathComponent(trimmed)
            .standardizedFileURL
        _ = try relativePath(from: requestedBundleRoot, to: assetURL)
        return assetURL
    }

    private static func relativePath(from root: URL, to url: URL) throws -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let urlPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard urlPath.hasPrefix(rootPath + "/") else {
            throw EngineError.manifest("Wallpaper Engine project asset must stay inside wallpaper bundle root")
        }
        return String(urlPath.dropFirst(rootPath.count + 1))
    }

    private static func sanitizedBundleID(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let id = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return id.isEmpty ? "wallpaper_engine_video" : id
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        try validateSourceProvenance(manifest.sourceProvenance)
        guard manifest.runtime.targetFps > 0,
              manifest.runtime.fallbackFps > 0,
              manifest.runtime.maxFps >= manifest.runtime.targetFps,
              manifest.runtime.targetFps >= manifest.runtime.fallbackFps else {
            throw EngineError.manifest("runtime FPS values are invalid")
        }
        if let nativeSpinePoseFps = manifest.runtime.nativeSpinePoseFps {
            guard nativeSpinePoseFps > 0, nativeSpinePoseFps <= manifest.runtime.maxFps else {
                throw EngineError.manifest("runtime.nativeSpinePoseFps must satisfy 1...maxFps")
            }
        }
        if let idleRenderFps = manifest.runtime.idleRenderFps {
            guard idleRenderFps > 0, idleRenderFps <= manifest.runtime.maxFps else {
                throw EngineError.manifest("runtime.idleRenderFps must satisfy 1...maxFps")
            }
        }
        if let nativeSpineIdlePoseFps = manifest.runtime.nativeSpineIdlePoseFps {
            guard nativeSpineIdlePoseFps > 0, nativeSpineIdlePoseFps <= manifest.runtime.maxFps else {
                throw EngineError.manifest("runtime.nativeSpineIdlePoseFps must satisfy 1...maxFps")
            }
        }
        if let nativeSpineTransitionSeconds = manifest.runtime.nativeSpineTransitionSeconds {
            guard nativeSpineTransitionSeconds.isFinite,
                  nativeSpineTransitionSeconds >= 0,
                  nativeSpineTransitionSeconds <= 10 else {
                throw EngineError.manifest("runtime.nativeSpineTransitionSeconds must satisfy 0 <= value <= 10")
            }
        }
        if let policy = manifest.runtime.nativeSpineTransitionPolicy {
            if let defaultSeconds = policy.defaultSeconds {
                try validateInteractionDuration(defaultSeconds, label: "runtime.nativeSpineTransitionPolicy.defaultSeconds")
            }
            if let lookSeconds = policy.lookSeconds {
                try validateInteractionDuration(lookSeconds, label: "runtime.nativeSpineTransitionPolicy.lookSeconds")
            }
            if let actionSeconds = policy.actionSeconds {
                try validateInteractionDuration(actionSeconds, label: "runtime.nativeSpineTransitionPolicy.actionSeconds")
            }
            if let releaseSeconds = policy.releaseSeconds {
                try validateInteractionDuration(releaseSeconds, label: "runtime.nativeSpineTransitionPolicy.releaseSeconds")
            }
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
        try validateEffects(manifest.effects ?? [])
        try validateBindings(
            manifest.bindings ?? [],
            effects: manifest.effects ?? [],
            hasSpine: manifest.assets.spine != nil
        )
        try validateEffectBudgets(
            effects: manifest.effects ?? [],
            bindings: manifest.bindings ?? []
        )

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
            let referenced = referencedAnimationActions(
                in: manifest.interactions,
                bindings: manifest.bindings ?? []
            )
            try validateSpineJSON(
                spineJSON,
                requiredVersion: manifest.validation.requireSpineVersion,
                referencedActions: referenced.actions,
                referencedPairs: referenced.pairs
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

    private static func validateSourceProvenance(_ provenance: SourceProvenance?) throws {
        guard let provenance else { return }
        try validateOptionalNonEmpty(provenance.sourceRuntime, label: "sourceProvenance.sourceRuntime")
        try validateOptionalNonEmpty(provenance.projectType, label: "sourceProvenance.projectType")
        if let sourceDescriptors = provenance.sourceDescriptors {
            guard sourceDescriptors.isEmpty == false else {
                throw EngineError.manifest("sourceProvenance.sourceDescriptors must not be empty")
            }
            for descriptor in sourceDescriptors {
                try validateSourceDescriptor(descriptor)
            }
        }
        try validateStringList(provenance.importedFields, label: "sourceProvenance.importedFields")
        try validateStringList(provenance.calibratedFields, label: "sourceProvenance.calibratedFields")
        try validateStringList(provenance.platformPolicyFields, label: "sourceProvenance.platformPolicyFields")
        try validateStringList(provenance.unsupportedFields, label: "sourceProvenance.unsupportedFields")
        try validateStringList(provenance.notes, label: "sourceProvenance.notes")
    }

    private static func validateSourceDescriptor(_ descriptor: SourceDescriptor) throws {
        let path = descriptor.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty == false else {
            throw EngineError.manifest("sourceProvenance.sourceDescriptors path must not be empty")
        }
        guard path.hasPrefix("/") == false,
              path.contains("\\") == false,
              path.split(separator: "/").contains("..") == false else {
            throw EngineError.manifest("sourceProvenance.sourceDescriptors path must be project-root relative and must not escape the project")
        }
    }

    private static func validateOptionalNonEmpty(_ value: String?, label: String) throws {
        guard let value else { return }
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw EngineError.manifest("\(label) must not be empty")
        }
    }

    private static func validateStringList(_ values: [String]?, label: String) throws {
        guard let values else { return }
        guard values.isEmpty == false else {
            throw EngineError.manifest("\(label) must not be empty when declared")
        }
        for value in values {
            guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw EngineError.manifest("\(label) entries must not be empty")
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
        guard budgets.maxTextureDimension > 0, budgets.maxTextureDimension <= 16384 else {
            throw EngineError.manifest("layerBudgets.maxTextureDimension must satisfy 0 < value <= 16384")
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
        if let foregroundOcclusion = layer.foregroundOcclusion {
            guard layer.type == .video else {
                throw EngineError.manifest("layer \(layer.id) foregroundOcclusion is only supported on video layers")
            }
            try validateNormalizedRect(
                foregroundOcclusion.sourceRect,
                label: "layer \(layer.id) foregroundOcclusion.sourceRect"
            )
            try validateNormalizedRect(
                foregroundOcclusion.destinationRect,
                label: "layer \(layer.id) foregroundOcclusion.destinationRect"
            )
        }
    }

    private static func validateNormalizedRect(_ rect: [Double], label: String) throws {
        guard rect.count == 4, rect.allSatisfy(\.isFinite) else {
            throw EngineError.manifest("\(label) must contain four finite numbers: x, y, width, height")
        }
        let x = rect[0]
        let y = rect[1]
        let width = rect[2]
        let height = rect[3]
        guard x >= 0,
              y >= 0,
              width > 0,
              height > 0,
              x + width <= 1,
              y + height <= 1 else {
            throw EngineError.manifest("\(label) must stay inside normalized 0...1 bounds")
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
            guard pointerSmoothing.isFinite, pointerSmoothing >= 0, pointerSmoothing <= 1 else {
                throw EngineError.manifest("interactionPolicy.pointerSmoothing must satisfy 0 <= value <= 1")
            }
        }
        if let pointerSampleFps = policy.pointerSampleFps {
            guard pointerSampleFps.isFinite, pointerSampleFps >= 15, pointerSampleFps <= 240 else {
                throw EngineError.manifest("interactionPolicy.pointerSampleFps must satisfy 15 <= value <= 240")
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

    private static func validateEffects(_ effects: [EffectConfig]) throws {
        guard effects.count <= 64 else {
            throw EngineError.manifest("effects must contain at most 64 entries")
        }
        var seen = Set<String>()
        for effect in effects {
            try validateDeclarativeIdentifier(effect.id, label: "effect id")
            guard seen.insert(effect.id).inserted else {
                throw EngineError.manifest("effect ids must be unique: \(effect.id)")
            }
            let properties = effect.properties ?? [:]
            guard properties.count <= 64 else {
                throw EngineError.manifest("effect \(effect.id) properties must contain at most 64 entries")
            }
            guard let budget = effect.budget else {
                throw EngineError.manifest("effect \(effect.id) must declare a runtime budget")
            }
            try validateEffectBudget(budget, effectID: effect.id)
            guard let fallback = effect.fallback else {
                throw EngineError.manifest("effect \(effect.id) must declare a fallback policy")
            }
            try validateEffectFallback(fallback, effectID: effect.id)
            for (key, value) in properties {
                try validateDeclarativeIdentifier(key, label: "effect \(effect.id) property")
                guard supportedEffectProperties(effect.type).contains(key) else {
                    throw EngineError.manifest("effect \(effect.id) property \(key) is not supported by \(effect.type.rawValue)")
                }
                try validateEffectPropertyValue(value, label: "effect \(effect.id).\(key)")
                guard case .number = value else {
                    throw EngineError.manifest("effect \(effect.id).\(key) must be a number")
                }
            }
        }
    }

    private static func validateEffectBudget(_ budget: EffectBudgetConfig, effectID: String) throws {
        if let maxPasses = budget.maxPasses {
            guard (0...8).contains(maxPasses) else {
                throw EngineError.manifest("effect \(effectID) budget.maxPasses must satisfy 0...8")
            }
        }
        if let maxAnimatedProperties = budget.maxAnimatedProperties {
            guard (0...16).contains(maxAnimatedProperties) else {
                throw EngineError.manifest("effect \(effectID) budget.maxAnimatedProperties must satisfy 0...16")
            }
        }
    }

    private static func validateEffectFallback(_ fallback: EffectFallbackConfig, effectID: String) throws {
        if let reason = fallback.reason {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, trimmed.count <= 256 else {
                throw EngineError.manifest("effect \(effectID) fallback.reason must be non-empty and at most 256 characters")
            }
        }
    }

    private static func validateEffectBudgets(
        effects: [EffectConfig],
        bindings: [DeclarativeBinding]
    ) throws {
        let effectByID = Dictionary(uniqueKeysWithValues: effects.map { ($0.id, $0) })
        var animatedPropertiesByEffect: [String: Set<String>] = [:]
        for binding in bindings {
            let target = try parseBindingTarget(binding.target, bindingID: binding.id)
            if case .effect(let effectID, let propertyPath) = target {
                animatedPropertiesByEffect[effectID, default: []].insert(propertyPath)
            }
        }

        for (effectID, animatedProperties) in animatedPropertiesByEffect {
            guard let effect = effectByID[effectID] else { continue }
            guard let maxAnimatedProperties = effect.budget?.maxAnimatedProperties else {
                continue
            }
            guard animatedProperties.count <= maxAnimatedProperties else {
                throw EngineError.manifest(
                    "effect \(effectID) animates \(animatedProperties.count) propert\(animatedProperties.count == 1 ? "y" : "ies") but budget.maxAnimatedProperties is \(maxAnimatedProperties)"
                )
            }
        }
    }

    private static func validateBindings(
        _ bindings: [DeclarativeBinding],
        effects: [EffectConfig],
        hasSpine: Bool
    ) throws {
        guard bindings.count <= 128 else {
            throw EngineError.manifest("bindings must contain at most 128 entries")
        }

        let effectByID = Dictionary(uniqueKeysWithValues: effects.map { ($0.id, $0) })
        var seen = Set<String>()
        for binding in bindings {
            try validateDeclarativeIdentifier(binding.id, label: "binding id")
            guard seen.insert(binding.id).inserted else {
                throw EngineError.manifest("binding ids must be unique: \(binding.id)")
            }

            let target = try parseBindingTarget(binding.target, bindingID: binding.id)
            switch target {
            case .spineBone, .spineAnimation:
                guard hasSpine else {
                    throw EngineError.manifest("binding \(binding.id) targets Spine but the manifest has no Spine asset")
                }
            case .effect(let effectID, let propertyPath):
                guard let effect = effectByID[effectID] else {
                    throw EngineError.manifest("binding \(binding.id) targets missing effect id: \(effectID)")
                }
                guard supportedEffectProperties(effect.type).contains(propertyPath) else {
                    throw EngineError.manifest("binding \(binding.id) targets unsupported \(effect.type.rawValue) effect property: \(propertyPath)")
                }
            }

            try validateBindingAdapter(binding.adapter, source: binding.source, target: target, bindingID: binding.id)
        }
    }

    private enum ParsedBindingTarget {
        case spineBone(String)
        case spineAnimation(String)
        case effect(effectID: String, propertyPath: String)
    }

    private static func supportedEffectProperties(_ type: EffectType) -> Set<String> {
        switch type {
        case .blur:
            return ["amount", "radius"]
        case .colorMatrix:
            return ["alpha", "brightness", "opacity", "saturation"]
        case .scroll:
            return ["offsetX", "offsetY", "x", "y"]
        case .chromaticAberration:
            return ["amount", "offset"]
        case .vignette:
            return ["amount", "intensity", "radius"]
        case .pixelate:
            return ["amount", "size"]
        }
    }

    private static func parseBindingTarget(_ target: String, bindingID: String) throws -> ParsedBindingTarget {
        if let suffix = target.removingPrefix("spine.bone.") {
            try validateDeclarativeIdentifier(suffix, label: "binding \(bindingID) spine bone target")
            return .spineBone(suffix)
        }
        if let suffix = target.removingPrefix("spine.animation.") {
            try validateDeclarativeIdentifier(suffix, label: "binding \(bindingID) spine animation target")
            return .spineAnimation(suffix)
        }
        if let suffix = target.removingPrefix("effect.") {
            let parts = suffix.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw EngineError.manifest("binding \(bindingID) effect target must be effect.<id>.<property>")
            }
            try validateDeclarativeIdentifier(parts[0], label: "binding \(bindingID) effect target id")
            try validateDeclarativeIdentifier(parts[1], label: "binding \(bindingID) effect target property")
            return .effect(effectID: parts[0], propertyPath: parts[1])
        }
        throw EngineError.manifest("binding \(bindingID) target must start with spine.bone., spine.animation., or effect.")
    }

    private static func validateBindingAdapter(
        _ adapter: BindingAdapter,
        source: BindingSource,
        target: ParsedBindingTarget,
        bindingID: String
    ) throws {
        if let neutralPoint = adapter.neutralPoint {
            try validateInteractionPoint(
                neutralPoint,
                label: "binding \(bindingID) adapter.neutralPoint",
                min: 0,
                max: 1,
                allowZero: true,
                allowMax: true
            )
        }
        if let deadZone = adapter.deadZone {
            try validateInteractionPoint(
                deadZone,
                label: "binding \(bindingID) adapter.deadZone",
                min: 0,
                max: 0.5,
                allowZero: true,
                allowMax: false
            )
        }
        if let factor = adapter.factor {
            try validateFiniteNumberList(factor, label: "binding \(bindingID) adapter.factor", minCount: 1, maxCount: 4)
        }
        if let inputRange = adapter.inputRange {
            try validateFiniteNumberList(inputRange, label: "binding \(bindingID) adapter.inputRange", minCount: 2, maxCount: 8)
        }
        if let outputRange = adapter.outputRange {
            try validateFiniteNumberList(outputRange, label: "binding \(bindingID) adapter.outputRange", minCount: 2, maxCount: 8)
        }
        try validateSpringOnlyFields(adapter, bindingID: bindingID)

        switch adapter.type {
        case .smoothLookAt:
            guard source == .pointerPosition else {
                throw EngineError.manifest("binding \(bindingID) smooth-lookat adapter requires source pointer.position")
            }
            guard case .spineBone = target else {
                throw EngineError.manifest("binding \(bindingID) smooth-lookat adapter requires a spine.bone target")
            }
            if let factor = adapter.factor, factor.count < 2 {
                throw EngineError.manifest("binding \(bindingID) smooth-lookat adapter.factor must declare both x and y factors")
            }
        case .triggerPlay:
            guard source == .pointerDown else {
                throw EngineError.manifest("binding \(bindingID) trigger-play adapter requires source pointer.down")
            }
            guard case .spineAnimation = target else {
                throw EngineError.manifest("binding \(bindingID) trigger-play adapter requires a spine.animation target")
            }
        case .mapRange:
            guard case .effect = target else {
                throw EngineError.manifest("binding \(bindingID) map-range adapter requires an effect target")
            }
            guard let inputRange = adapter.inputRange,
                  let outputRange = adapter.outputRange,
                  inputRange.count == outputRange.count else {
                throw EngineError.manifest("binding \(bindingID) map-range adapter requires equal-length inputRange and outputRange")
            }
            guard isStrictlyMonotonic(inputRange) else {
                throw EngineError.manifest("binding \(bindingID) map-range adapter.inputRange must be strictly monotonic")
            }
            if adapter.loop == true {
                guard let first = inputRange.first,
                      let last = inputRange.last,
                      last > first else {
                    throw EngineError.manifest("binding \(bindingID) map-range loop requires an ascending inputRange")
                }
            }
        case .spring:
            switch target {
            case .spineBone, .effect:
                break
            case .spineAnimation:
                throw EngineError.manifest("binding \(bindingID) spring adapter cannot target spine.animation")
            }
            try validateSpringContract(adapter, source: source, bindingID: bindingID)
        }
    }

    private static func validateSpringOnlyFields(_ adapter: BindingAdapter, bindingID: String) throws {
        guard adapter.type != .spring else { return }
        let springOnlyFields: [(String, Bool)] = [
            ("integrator", adapter.integrator != nil),
            ("stiffness", adapter.stiffness != nil),
            ("damping", adapter.damping != nil),
            ("mass", adapter.mass != nil),
            ("settleEpsilon", adapter.settleEpsilon != nil),
            ("maxVelocity", adapter.maxVelocity != nil),
            ("fixedStepSeconds", adapter.fixedStepSeconds != nil)
        ]
        if let field = springOnlyFields.first(where: { $0.1 })?.0 {
            throw EngineError.manifest("binding \(bindingID) adapter.\(field) is only supported by spring adapters")
        }
    }

    private static func validateSpringContract(
        _ adapter: BindingAdapter,
        source: BindingSource,
        bindingID: String
    ) throws {
        guard adapter.integrator != nil else {
            throw EngineError.manifest("binding \(bindingID) spring adapter requires adapter.integrator")
        }
        try validateFiniteNumber(
            adapter.stiffness,
            label: "binding \(bindingID) adapter.stiffness",
            min: 0,
            max: 10_000,
            allowMin: false
        )
        try validateFiniteNumber(
            adapter.damping,
            label: "binding \(bindingID) adapter.damping",
            min: 0,
            max: 10_000,
            allowMin: true
        )
        try validateFiniteNumber(
            adapter.mass,
            label: "binding \(bindingID) adapter.mass",
            min: 0,
            max: 100,
            allowMin: false
        )
        try validateFiniteNumber(
            adapter.settleEpsilon,
            label: "binding \(bindingID) adapter.settleEpsilon",
            min: 0,
            max: 1,
            allowMin: false
        )
        try validateFiniteNumber(
            adapter.maxVelocity,
            label: "binding \(bindingID) adapter.maxVelocity",
            min: 0,
            max: 10_000,
            allowMin: false
        )
        try validateFiniteNumber(
            adapter.fixedStepSeconds,
            label: "binding \(bindingID) adapter.fixedStepSeconds",
            min: 0.004,
            max: 0.067,
            allowMin: true
        )
        if adapter.loop == true {
            guard source == .systemTime else {
                throw EngineError.manifest("binding \(bindingID) spring adapter loop requires source system.time")
            }
            guard let inputRange = adapter.inputRange,
                  let outputRange = adapter.outputRange,
                  inputRange.count == outputRange.count else {
                throw EngineError.manifest("binding \(bindingID) spring adapter loop requires equal-length inputRange and outputRange")
            }
            guard isStrictlyMonotonic(inputRange),
                  let first = inputRange.first,
                  let last = inputRange.last,
                  last > first else {
                throw EngineError.manifest("binding \(bindingID) spring adapter loop requires an ascending inputRange")
            }
        } else if adapter.inputRange != nil || adapter.outputRange != nil {
            guard let inputRange = adapter.inputRange,
                  let outputRange = adapter.outputRange,
                  inputRange.count == outputRange.count else {
                throw EngineError.manifest("binding \(bindingID) spring adapter range mapping requires equal-length inputRange and outputRange")
            }
            guard isStrictlyMonotonic(inputRange) else {
                throw EngineError.manifest("binding \(bindingID) spring adapter.inputRange must be strictly monotonic")
            }
        }
    }

    private static func validateDeclarativeIdentifier(_ value: String, label: String) throws {
        guard value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              value.isEmpty == false,
              value.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil else {
            throw EngineError.manifest("\(label) must use only A-Z, a-z, 0-9, underscore, dash, colon, or dot")
        }
    }

    private static func isStrictlyMonotonic(_ values: [Double]) -> Bool {
        guard values.count >= 2 else { return false }
        let increasing = zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
        let decreasing = zip(values, values.dropFirst()).allSatisfy { $0 > $1 }
        return increasing || decreasing
    }

    private static func validateEffectPropertyValue(_ value: EffectPropertyValue, label: String) throws {
        switch value {
        case .string(let text):
            guard text.count <= 256 else {
                throw EngineError.manifest("\(label) string value is too long")
            }
        case .number(let number):
            guard number.isFinite else {
                throw EngineError.manifest("\(label) number value must be finite")
            }
        case .bool:
            break
        case .stringArray(let values):
            guard values.count <= 32 else {
                throw EngineError.manifest("\(label) string array must contain at most 32 entries")
            }
            for text in values {
                guard text.count <= 256 else {
                    throw EngineError.manifest("\(label) string array entry is too long")
                }
            }
        case .numberArray(let values):
            try validateFiniteNumberList(values, label: label, minCount: 0, maxCount: 32)
        }
    }

    private static func validateFiniteNumberList(
        _ values: [Double],
        label: String,
        minCount: Int,
        maxCount: Int
    ) throws {
        guard values.count >= minCount, values.count <= maxCount, values.allSatisfy(\.isFinite) else {
            throw EngineError.manifest("\(label) must contain \(minCount)...\(maxCount) finite number(s)")
        }
    }

    private static func validateFiniteNumber(
        _ value: Double?,
        label: String,
        min: Double,
        max: Double,
        allowMin: Bool
    ) throws {
        guard let value, value.isFinite else {
            throw EngineError.manifest("\(label) must be a finite number")
        }
        let lowerBoundOK = allowMin ? value >= min : value > min
        guard lowerBoundOK, value <= max else {
            let comparator = allowMin ? "<=" : "<"
            throw EngineError.manifest("\(label) must satisfy \(min) \(comparator) value <= \(max)")
        }
    }

    private static func validateHitZone(_ hitZone: HitZone) throws {
        guard hitZone.id.isEmpty == false else {
            throw EngineError.manifest("hitZone id must not be empty")
        }
        guard hitZone.action.isEmpty == false else {
            throw EngineError.manifest("hitZone \(hitZone.id) action must not be empty")
        }
        if let tapAction = hitZone.tapAction, tapAction.isEmpty {
            throw EngineError.manifest("hitZone \(hitZone.id) tapAction must not be empty")
        }
        if let rubAction = hitZone.rubAction, rubAction.isEmpty {
            throw EngineError.manifest("hitZone \(hitZone.id) rubAction must not be empty")
        }
        let hasRect = hitZone.rect != nil
        let hasEllipse = hitZone.ellipse != nil
        guard hasRect != hasEllipse else {
            throw EngineError.manifest("hitZone \(hitZone.id) must define exactly one shape: rect or ellipse")
        }

        if let rect = hitZone.rect {
            guard rect.count == 4, rect.allSatisfy(\.isFinite) else {
                throw EngineError.manifest("hitZone \(hitZone.id) rect must contain four finite numbers")
            }

            let x0 = rect[0]
            let y0 = rect[1]
            let x1 = rect[2]
            let y1 = rect[3]
            guard x0 >= 0, y0 >= 0, x1 <= 1, y1 <= 1, x0 < x1, y0 < y1 else {
                throw EngineError.manifest("hitZone \(hitZone.id) rect must satisfy 0 <= x0 < x1 <= 1 and 0 <= y0 < y1 <= 1")
            }
        }

        if let ellipse = hitZone.ellipse {
            guard ellipse.center.x.isFinite,
                  ellipse.center.y.isFinite,
                  ellipse.radiusX.isFinite,
                  ellipse.radiusY.isFinite else {
                throw EngineError.manifest("hitZone \(hitZone.id) ellipse must contain finite center and radius values")
            }
            guard ellipse.center.x >= 0,
                  ellipse.center.x <= 1,
                  ellipse.center.y >= 0,
                  ellipse.center.y <= 1,
                  ellipse.radiusX > 0,
                  ellipse.radiusY > 0,
                  ellipse.center.x - ellipse.radiusX >= 0,
                  ellipse.center.x + ellipse.radiusX <= 1,
                  ellipse.center.y - ellipse.radiusY >= 0,
                  ellipse.center.y + ellipse.radiusY <= 1 else {
                throw EngineError.manifest("hitZone \(hitZone.id) ellipse must stay inside normalized content bounds")
            }
        }
        if let tailSeconds = hitZone.tailSeconds {
            try validateInteractionDuration(tailSeconds, label: "hitZone \(hitZone.id) tailSeconds")
        }
        if let tapTailSeconds = hitZone.tapTailSeconds {
            try validateInteractionDuration(tapTailSeconds, label: "hitZone \(hitZone.id) tapTailSeconds")
        }
        if let rubTailSeconds = hitZone.rubTailSeconds {
            try validateInteractionDuration(rubTailSeconds, label: "hitZone \(hitZone.id) rubTailSeconds")
        }
        if let holdStartSeconds = hitZone.holdStartSeconds {
            try validateInteractionDuration(holdStartSeconds, label: "hitZone \(hitZone.id) holdStartSeconds")
        }
        if let holdCommitSeconds = hitZone.holdCommitSeconds {
            try validateInteractionDuration(holdCommitSeconds, label: "hitZone \(hitZone.id) holdCommitSeconds")
            let holdStartSeconds = hitZone.holdStartSeconds ?? 0
            guard holdCommitSeconds >= holdStartSeconds else {
                throw EngineError.manifest("hitZone \(hitZone.id) holdCommitSeconds must be >= holdStartSeconds")
            }
        }
        if let rubStartSeconds = hitZone.rubStartSeconds {
            try validateInteractionDuration(rubStartSeconds, label: "hitZone \(hitZone.id) rubStartSeconds")
        }
        if let rubStartDistance = hitZone.rubStartDistance {
            try validateFiniteNumber(
                rubStartDistance,
                label: "hitZone \(hitZone.id) rubStartDistance",
                min: 0,
                max: 1,
                allowMin: false
            )
        }
        if hitZone.tapAction != nil, (hitZone.trigger ?? .tap) != .hold {
            throw EngineError.manifest("hitZone \(hitZone.id) tapAction requires trigger=hold")
        }
        if hitZone.rubAction != nil, (hitZone.trigger ?? .tap) != .hold {
            throw EngineError.manifest("hitZone \(hitZone.id) rubAction requires trigger=hold")
        }
        if let buttons = hitZone.buttons, buttons.isEmpty {
            throw EngineError.manifest("hitZone \(hitZone.id) buttons must not be empty")
        }
        if let priority = hitZone.priority {
            guard abs(priority) <= 1_000 else {
                throw EngineError.manifest("hitZone \(hitZone.id) priority must satisfy -1000 <= priority <= 1000")
            }
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
                guard hitZoneBoundsOverlap(left, right) else { continue }
                let leftPriority = left.priority ?? 0
                let rightPriority = right.priority ?? 0
                guard leftPriority == rightPriority else { continue }

                let buttonText = sharedButtons
                    .map(\.rawValue)
                    .sorted()
                    .joined(separator: "+")
                throw EngineError.manifest(
                    "hitZones \(left.id) and \(right.id) overlap for button(s) \(buttonText) at priority \(leftPriority); split the shapes or assign distinct hit-zone priorities"
                )
            }
        }
    }

    private static func hitZoneBoundsOverlap(_ left: HitZone, _ right: HitZone) -> Bool {
        guard let leftBounds = hitZoneBounds(left),
              let rightBounds = hitZoneBounds(right) else {
            return false
        }
        return hitZoneRectsOverlap(leftBounds, rightBounds)
    }

    private static func hitZoneBounds(_ hitZone: HitZone) -> [Double]? {
        if let rect = hitZone.rect {
            return rect
        }

        guard let ellipse = hitZone.ellipse else {
            return nil
        }
        return [
            ellipse.center.x - ellipse.radiusX,
            ellipse.center.y - ellipse.radiusY,
            ellipse.center.x + ellipse.radiusX,
            ellipse.center.y + ellipse.radiusY
        ]
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
    private static func validateRelativePath(_ path: String, bundleRoot: URL) throws -> URL {
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

    private static func validateSpineJSON(_ url: URL, requiredVersion: String, referencedActions: Set<String>, referencedPairs: [[String]]) throws {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.asset("Spine JSON root is not an object")
        }
        guard let skeleton = root["skeleton"] as? [String: Any],
              let actualVersion = skeleton["spine"] as? String else {
            throw EngineError.asset("Spine JSON missing skeleton.spine")
        }

        guard spineVersionMatches(actual: actualVersion, required: requiredVersion) else {
            throw EngineError.asset("Spine JSON version \(actualVersion) does not match \(requiredVersion)")
        }

        guard let animations = root["animations"] as? [String: Any] else {
            throw EngineError.asset("Spine JSON missing animations")
        }
        for action in referencedActions where animations[action] == nil {
            throw EngineError.asset("interaction references missing Spine animation: \(action)")
        }
        for pair in referencedPairs where pair.allSatisfy { animations[$0] == nil } {
            throw EngineError.asset("interaction references Spine animation pair with no existing component: \(pair.joined(separator: ":"))")
        }
    }

    private static func spineVersionMatches(actual: String, required: String) -> Bool {
        let requiredComponents = required.split(separator: ".", omittingEmptySubsequences: false)
        let actualComponents = actual.split(separator: ".", omittingEmptySubsequences: false)
        for (index, requiredComponent) in requiredComponents.enumerated() {
            if requiredComponent == "x" {
                return true
            }
            guard index < actualComponents.count, actualComponents[index] == requiredComponent else {
                return false
            }
        }
        return true
    }

    private static func referencedAnimationActions(
        in interactions: [InteractionConfig],
        bindings: [DeclarativeBinding]
    ) -> (actions: Set<String>, pairs: [[String]]) {
        var actions = Set<String>()
        var pairs = [[String]]()
        func collect(_ action: String) {
            // Colon values are random pairs: a pair only needs at least one existing component.
            if action.contains(":") {
                // Canonical pair parsing via SpineInteractionAnimationRoles: malformed
                // values like "a:" or ":b" yield the single nonempty component.
                pairs.append(SpineInteractionAnimationRoles.components(of: action))
                return
            }
            actions.insert(action)
        }
        for interaction in interactions {
            interaction.actions?.values.forEach(collect)
            interaction.hitZones?.forEach {
                collect($0.action)
                if let tapAction = $0.tapAction {
                    collect(tapAction)
                }
                if let rubAction = $0.rubAction {
                    collect(rubAction)
                }
            }
            if let defaultAction = interaction.defaultAction {
                collect(defaultAction.action)
            }
        }
        for binding in bindings {
            if let animation = binding.target.removingPrefix("spine.animation.") {
                actions.insert(animation)
            }
        }
        return (actions, pairs)
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
