import Foundation

struct RuntimeCapabilityRow {
    let category: String
    let name: String
    let status: String
    let detail: String

    var line: String {
        "\(category)\t\(name)\t\(status)\t\(detail)"
    }
}

struct NativeSpineCompatibility {
    let isSupported: Bool
    let reasons: [String]

    var reasonText: String {
        reasons.isEmpty ? "supported" : reasons.joined(separator: "; ")
    }
}

struct WallpaperBundleCapabilityInfo: Equatable {
    let assetKinds: [String]
    let layerKinds: [String]
    let interactionKinds: [String]
    let interactionRequirement: String
    let nativeSpineStatus: String
    let fallbackStatus: String
    let qualityStatus: String
    let qualityWarnings: [String]
    let qualityRecommendations: [String]

    var briefText: String {
        [
            "assets: \(assetKinds.joined(separator: "+"))",
            "layers: \(layerKinds.joined(separator: "+"))",
            "interactions: \(interactionKinds.joined(separator: "+"))",
            "input: \(interactionRequirement)",
            "native: \(nativeSpineStatus)",
            "fallback: \(fallbackStatus)",
            "quality: \(qualitySummary)"
        ].joined(separator: " / ")
    }

    var qualitySummary: String {
        if qualityWarnings.isEmpty == false {
            return "\(qualityStatus)(\(qualityWarnings.count))"
        }
        if qualityRecommendations.isEmpty == false {
            return "\(qualityStatus)+rec(\(qualityRecommendations.count))"
        }
        return qualityStatus
    }
}

enum RuntimeCapabilities {
    static func summary(runtime: NativeRuntimeCore) -> String {
        let rows = makeRows(runtime: runtime)
        let rowText = rows.map(\.line).joined(separator: "\n")

        return """
        runtime capabilities
        bundle: \(runtime.config.wallpaperRoot.path)
        manifest: \(runtime.config.manifestURL.path)
        schemaVersion: \(runtime.manifest.schemaVersion)
        runtime: \(runtime.manifest.runtime.kind)
        columns: category\tname\tstatus\tdetail
        \(rowText)
        """
    }

    static func makeRows(runtime: NativeRuntimeCore) -> [RuntimeCapabilityRow] {
        let manifest = runtime.manifest
        var rows: [RuntimeCapabilityRow] = []

        rows.append(assetRow(name: "staticImage", isPresent: manifest.assets.staticImage != nil, detail: manifest.assets.staticImage?.path))
        rows.append(videoAssetRow(
            name: "video",
            config: manifest.assets.video,
            asset: runtime.assetCatalog.videoAsset,
            targetFps: runtime.renderTargetFps,
            warnWhenBelowTarget: false
        ))
        rows.append(videoAssetRow(
            name: "compositeVideo",
            config: manifest.assets.compositeVideo,
            asset: runtime.assetCatalog.compositeVideoAsset,
            targetFps: runtime.renderTargetFps,
            warnWhenBelowTarget: true
        ))
        rows.append(assetRow(name: "spine", isPresent: manifest.assets.spine != nil, detail: manifest.assets.spine?.json))

        for layer in manifest.layers {
            rows.append(RuntimeCapabilityRow(
                category: "layer",
                name: layer.type.rawValue,
                status: layerStatus(layer),
                detail: "\(layer.id) -> \(layer.asset)\(layer.renderingMode.map { " renderingMode=\($0)" } ?? "")"
            ))
        }

        rows.append(displayRow(name: "primary", policy: manifest.displayPolicy.primary))
        rows.append(displayRow(name: "secondary", policy: manifest.displayPolicy.secondary))
        rows.append(displayRow(name: "fullscreenObscured", policy: manifest.displayPolicy.fullscreenObscured))
        rows.append(displayRow(name: "occluded", policy: manifest.displayPolicy.occluded))

        rows.append(RuntimeCapabilityRow(
            category: "performance",
            name: "frameScheduler",
            status: "supported",
            detail: "target=\(runtime.renderTargetFps) max=\(manifest.runtime.maxFps) fallback=\(manifest.runtime.fallbackFps) inFlight=\(manifest.runtime.scheduler.maxInFlightCommandBuffers)"
        ))
        rows.append(RuntimeCapabilityRow(
            category: "render",
            name: "contentAspect",
            status: "supported",
            detail: formatVideoDiagnosticNumber(runtime.assetCatalog.contentAspect)
        ))
        rows.append(RuntimeCapabilityRow(
            category: "performance",
            name: "resourceFallback",
            status: "fps-only",
            detail: "resource pressure lowers FPS but does not silently replace native Spine with compositeVideo"
        ))

        let actionTailDurations = (try? SpineAnimationDiagnostics.tapActionDurations(runtime: runtime)) ?? [:]
        rows.append(contentsOf: interactionRows(
            manifest.interactions,
            policy: manifest.interactionPolicy,
            actionTailDurations: actionTailDurations
        ))
        rows.append(contentsOf: spineRows(runtime: runtime))

        return rows
    }

    static func nativeSpineCompatibility(runtime: NativeRuntimeCore) -> NativeSpineCompatibility {
        nativeSpineCompatibility(manifest: runtime.manifest, bundleRoot: runtime.config.wallpaperRoot)
    }

    static func nativeSpineCompatibility(
        manifest: WallpaperNativeManifest,
        bundleRoot: URL
    ) -> NativeSpineCompatibility {
        guard let spine = manifest.assets.spine else {
            return NativeSpineCompatibility(isSupported: true, reasons: [])
        }

        let spineJSON = bundleRoot.appendingPathComponent(spine.json).standardizedFileURL
        let scan = SpineFeatureScan.scan(url: spineJSON)
        var reasons: [String] = []
        if scan.unsupportedAttachmentTypes.isEmpty == false {
            reasons.append("unsupported attachment types: \(scan.unsupportedAttachmentTypes.listOrNone)")
        }
        if scan.unsupportedLinkedMeshReferences.isEmpty == false {
            reasons.append("unsupported linkedmesh references: \(scan.unsupportedLinkedMeshReferences.listOrNone)")
        }
        if scan.unsupportedTimelineKeys.isEmpty == false {
            reasons.append("unsupported timeline keys: \(scan.unsupportedTimelineKeys.listOrNone)")
        }
        if scan.hasAudioData {
            reasons.append("audio event playback is not implemented")
        }
        if scan.hasSequenceData {
            reasons.append("sequence attachments are not implemented")
        }

        return NativeSpineCompatibility(isSupported: reasons.isEmpty, reasons: reasons)
    }

    static func bundleInfo(
        manifest: WallpaperNativeManifest,
        bundleRoot: URL
    ) -> WallpaperBundleCapabilityInfo {
        var assetKinds: [String] = []
        if manifest.assets.staticImage != nil { assetKinds.append("static") }
        if manifest.assets.video != nil { assetKinds.append("video") }
        if manifest.assets.compositeVideo != nil { assetKinds.append("composite") }
        if manifest.assets.spine != nil { assetKinds.append("spine") }
        if assetKinds.isEmpty { assetKinds.append("none") }

        let layerKinds = manifest.layers.map(\.type.rawValue).uniquePreservingOrder
        let interactionKinds = interactionKinds(for: manifest.interactions)
        let compatibility = nativeSpineCompatibility(manifest: manifest, bundleRoot: bundleRoot)
        let nativeSpineStatus: String
        if manifest.assets.spine == nil {
            nativeSpineStatus = "not-used"
        } else {
            nativeSpineStatus = compatibility.isSupported ? "supported" : "unsupported"
        }

        let fallbackStatus: String
        if compatibility.isSupported {
            fallbackStatus = manifest.assets.compositeVideo == nil ? "not-needed" : "composite-ready"
        } else {
            fallbackStatus = manifest.assets.compositeVideo == nil ? "blocked" : "composite"
        }
        let qualityReport = CompositeFallbackQualityReport.make(
            manifest: manifest,
            bundleRoot: bundleRoot
        )
        let qualityWarnings = qualityReport.warnings
        let qualityStatus = qualityWarnings.isEmpty ? "ok" : "warning"

        return WallpaperBundleCapabilityInfo(
            assetKinds: assetKinds,
            layerKinds: layerKinds.isEmpty ? ["none"] : layerKinds,
            interactionKinds: interactionKinds,
            interactionRequirement: interactionRequirement(for: manifest.interactions, policy: manifest.interactionPolicy),
            nativeSpineStatus: nativeSpineStatus,
            fallbackStatus: fallbackStatus,
            qualityStatus: qualityStatus,
            qualityWarnings: qualityWarnings,
            qualityRecommendations: qualityReport.recommendations
        )
    }

    private static func assetRow(name: String, isPresent: Bool, detail: String?) -> RuntimeCapabilityRow {
        RuntimeCapabilityRow(
            category: "asset",
            name: name,
            status: isPresent ? "supported" : "not-used",
            detail: detail ?? "none"
        )
    }

    private static func videoAssetRow(
        name: String,
        config: VideoAssetConfig?,
        asset: VideoAsset?,
        targetFps: Int,
        warnWhenBelowTarget: Bool
    ) -> RuntimeCapabilityRow {
        guard let config, let asset else {
            return assetRow(name: name, isPresent: false, detail: nil)
        }

        do {
            let metadata = try VideoMetadataInspector.inspect(url: asset.url)
            let effectiveFps = metadata.effectiveFrameRate(playbackRate: asset.playbackRate)
            let belowTarget = warnWhenBelowTarget
                && (effectiveFps ?? 0) + 0.5 < Double(targetFps)
            let status = belowTarget ? "warning" : "supported"
            let warning = belowTarget
                ? " below target=\(targetFps); regenerate display-refresh fallback for smooth composite playback"
                : ""
            return RuntimeCapabilityRow(
                category: "asset",
                name: name,
                status: status,
                detail: "\(config.path) \(videoMetadataDetail(metadata, playbackRate: asset.playbackRate, effectiveFps: effectiveFps))\(warning)"
            )
        } catch {
            return RuntimeCapabilityRow(
                category: "asset",
                name: name,
                status: "warning",
                detail: "\(config.path) metadata=unreadable(\(error.localizedDescription))"
            )
        }
    }

    private static func videoMetadataDetail(
        _ metadata: VideoMetadata,
        playbackRate: Float,
        effectiveFps: Double?
    ) -> String {
        let width = Int(abs(metadata.presentationSize.width).rounded())
        let height = Int(abs(metadata.presentationSize.height).rounded())
        let duration = metadata.durationSeconds.map { "\(formatVideoDiagnosticNumber($0))s" } ?? "unknown"
        return "fps=\(formatVideoDiagnosticNumber(Double(metadata.nominalFrameRate))) effectiveFps=\(formatVideoDiagnosticNumber(effectiveFps)) playbackRate=\(formatVideoDiagnosticNumber(Double(playbackRate)))x size=\(width)x\(height) duration=\(duration)"
    }

    private static func layerStatus(_ layer: LayerConfig) -> String {
        switch layer.type {
        case .staticImage, .video:
            return "supported"
        case .spine:
            return (layer.renderingMode ?? "setup-mesh") == "setup-mesh" ? "supported" : "unsupported"
        }
    }

    private static func displayRow(name: String, policy: DisplayRolePolicy) -> RuntimeCapabilityRow {
        let status: String
        let detail: String
        switch policy {
        case .full:
            status = "supported"
            detail = "video plus foreground when available"
        case .videoOnly:
            status = "supported"
            detail = "background/video path only"
        case .static:
            status = "supported"
            detail = "validated preview/static image fallback"
        case .pause:
            status = "supported"
            detail = "rendering paused"
        }

        return RuntimeCapabilityRow(category: "display", name: name, status: status, detail: detail)
    }

    private static func interactionRows(
        _ interactions: [InteractionConfig],
        policy: InteractionPolicy?,
        actionTailDurations: [String: CFTimeInterval]
    ) -> [RuntimeCapabilityRow] {
        var rows: [RuntimeCapabilityRow] = []
        let hasInteractions = interactions.isEmpty == false
        let policyMode = policy?.mode.rawValue ?? "desktop-empty-only(default)"
        rows.append(RuntimeCapabilityRow(
            category: "interaction",
            name: "policy",
            status: hasInteractions && policy?.mode != .disabled ? "supported" : "not-used",
            detail: hasInteractions
                ? "mode=\(policyMode) blockAppWindows=\(policy?.blockApplicationWindows ?? true) blockDesktopItems=\(policy?.blockDesktopItems ?? true) desktopItemGate=\(desktopItemGate(policy: policy))"
                : "no declared interactions"
        ))

        let pointerMove = interactions.filter { $0.event == .pointerMove }
        let pointerDown = interactions.filter { $0.event == .pointerDown }

        rows.append(RuntimeCapabilityRow(
            category: "interaction",
            name: "pointerMove/lookDirection",
            status: pointerMove.isEmpty ? "not-used" : "supported",
            detail: pointerMove.isEmpty ? "none" : "\(pointerMove.count) mapping(s)"
        ))

        let hitZoneCount = pointerDown.reduce(0) { $0 + ($1.hitZones?.count ?? 0) }
        let hitZoneSummaries = InteractionPlan(
            interactions: interactions,
            policy: policy,
            actionTailDurations: actionTailDurations
        ).hitZoneSummaries()
        let defaultActionSummaries = pointerDown.compactMap {
            InteractionPlan(
                interactions: [$0],
                policy: policy,
                actionTailDurations: actionTailDurations
            ).defaultActionSummary()
        }
        let buttons = Set(hitZoneSummaries.flatMap { $0.buttons.map(\.rawValue) }).sorted().joined(separator: ",")
        let defaultButtons = Set(defaultActionSummaries.flatMap { $0.buttons.map(\.rawValue) }).sorted().joined(separator: ",")
        let hitZoneDetails = hitZoneSummaries.map(\.detailText).joined(separator: "; ")
        let defaultActionDetails = defaultActionSummaries.map(\.detailText).joined(separator: "; ")
        let hasPointerDown = hitZoneCount > 0 || defaultActionSummaries.isEmpty == false
        rows.append(RuntimeCapabilityRow(
            category: "interaction",
            name: "pointerDown/hitZones",
            status: hasPointerDown ? "supported" : "not-used",
            detail: hasPointerDown == false
                ? "none"
                : "\(hitZoneCount) zone(s) buttons=\(buttons.isEmpty ? "left(default)" : buttons) \(hitZoneDetails) default=\(defaultActionDetails.isEmpty ? "none" : defaultActionDetails) defaultButtons=\(defaultButtons.isEmpty ? "left(default)" : defaultButtons)"
        ))

        return rows
    }

    private static func interactionKinds(for interactions: [InteractionConfig]) -> [String] {
        var kinds: [String] = []
        if interactions.contains(where: { $0.event == .pointerMove }) {
            kinds.append("pointerMove")
        }
        if interactions.contains(where: { $0.event == .pointerDown }) {
            kinds.append("pointerDown")
        }
        return kinds.isEmpty ? ["none"] : kinds
    }

    private static func interactionRequirement(
        for interactions: [InteractionConfig],
        policy: InteractionPolicy?
    ) -> String {
        guard interactions.isEmpty == false else { return "none" }
        let mode = policy?.mode ?? .desktopEmptyOnly
        switch mode {
        case .disabled:
            return "disabled"
        case .always:
            return "always"
        case .desktopEmptyOnly:
            let blocksDesktopItems = policy?.blockDesktopItems ?? true
            return blocksDesktopItems ? "accessibility-required" : "desktop-empty"
        }
    }

    private static func desktopItemGate(policy: InteractionPolicy?) -> String {
        let mode = policy?.mode ?? .desktopEmptyOnly
        let blocksDesktopItems = policy?.blockDesktopItems ?? true
        let effectivePolicy = InteractionPolicy(
            mode: mode,
            blockApplicationWindows: policy?.blockApplicationWindows ?? true,
            blockDesktopItems: blocksDesktopItems,
            pointerSmoothing: nil,
            idleDeadZone: nil,
            directionSwitchMargin: nil,
            defaultClickTailSeconds: nil,
            releaseFadeSeconds: nil
        )
        guard RuntimeLifecyclePolicy.requiresAccessibilityTrustForDesktopItems(effectivePolicy) else {
            return "not-required"
        }
        return DesktopInteractionGate.hasAccessibilityTrust()
            ? "requires-accessibility-trust(current=trusted)"
            : "requires-accessibility-trust(current=missing)"
    }

    private static func spineRows(runtime: NativeRuntimeCore) -> [RuntimeCapabilityRow] {
        guard let spine = runtime.assetCatalog.spineAsset else {
            return [
                RuntimeCapabilityRow(
                    category: "spine",
                    name: "nativeRenderer",
                    status: "not-used",
                    detail: "bundle has no Spine asset"
                )
            ]
        }

        let compatibility = nativeSpineCompatibility(runtime: runtime)
        let scan = SpineFeatureScan.scan(url: spine.json)
        let attachmentStatus = scan.unsupportedAttachmentTypes.isEmpty && scan.unsupportedLinkedMeshReferences.isEmpty
            ? "supported"
            : "unsupported"
        let timelineStatus = scan.unsupportedTimelineKeys.isEmpty ? "supported" : "unsupported"
        let eventFeatureStatus: String
        if scan.hasAudioData || scan.hasSequenceData {
            eventFeatureStatus = "unsupported"
        } else if scan.hasEventData {
            eventFeatureStatus = "supported"
        } else {
            eventFeatureStatus = "not-used"
        }
        let eventFeatureDetail = [
            scan.hasEventData ? "events=ignored(non-visual)" : "events=none",
            scan.hasAudioData ? "audio=unsupported" : "audio=none",
            scan.hasSequenceData ? "sequence=unsupported" : "sequence=none"
        ].joined(separator: " ")

        let nativeRendererStatus: String
        let nativeRendererDetail: String
        if compatibility.isSupported {
            nativeRendererStatus = "supported"
            nativeRendererDetail = "Spine 4.2 setup/mesh renderer, placement=\(spine.placement.mode), pma=\(spine.premultipliedAlpha)"
        } else {
            nativeRendererStatus = "unsupported"
            let fallback = runtime.assetCatalog.compositeVideoAsset == nil
                ? "fallback=blocked(no-compositeVideo)"
                : "fallback=compositeVideo"
            nativeRendererDetail = "\(fallback); \(compatibility.reasonText)"
        }

        return [
            RuntimeCapabilityRow(
                category: "spine",
                name: "nativeCompatibilityGate",
                status: compatibility.isSupported ? "supported" : "unsupported",
                detail: compatibility.reasonText
            ),
            RuntimeCapabilityRow(
                category: "spine",
                name: "nativeRenderer",
                status: nativeRendererStatus,
                detail: nativeRendererDetail
            ),
            RuntimeCapabilityRow(
                category: "spine",
                name: "attachments",
                status: attachmentStatus,
                detail: "used=\(scan.attachmentTypes.listOrNone) unsupported=\(scan.unsupportedAttachmentTypes.listOrNone) linkedmeshIssues=\(scan.unsupportedLinkedMeshReferences.listOrNone)"
            ),
            RuntimeCapabilityRow(
                category: "spine",
                name: "timelines",
                status: timelineStatus,
                detail: "used=\(scan.timelineKeys.listOrNone) unsupported=\(scan.unsupportedTimelineKeys.listOrNone)"
            ),
            RuntimeCapabilityRow(
                category: "spine",
                name: "constraints",
                status: scan.constraintKeys.isEmpty ? "not-used" : "fallback",
                detail: scan.constraintKeys.isEmpty ? "none" : "pose/first-pass support for \(scan.constraintKeys.listOrNone)"
            ),
            RuntimeCapabilityRow(
                category: "spine",
                name: "eventsAudioSequence",
                status: eventFeatureStatus,
                detail: eventFeatureDetail
            )
        ]
    }
}

private struct SpineFeatureScan {
    var attachmentTypes: Set<String> = []
    var timelineKeys: Set<String> = []
    var constraintKeys: Set<String> = []
    var unsupportedLinkedMeshReferences: Set<String> = []
    var hasEventData = false
    var hasAudioData = false
    var hasSequenceData = false

    var unsupportedAttachmentTypes: Set<String> {
        attachmentTypes.subtracting(["region", "mesh", "linkedmesh", "path", "clipping"])
    }

    var unsupportedTimelineKeys: Set<String> {
        timelineKeys.subtracting([
            "bones.rotate",
            "bones.translate",
            "bones.translatex",
            "bones.translatey",
            "bones.scale",
            "bones.shear",
            "slots.rgba",
            "slots.attachment",
            "attachments.deform",
            "drawOrder",
            "draworder",
            "events",
            "event"
        ])
    }

    static func scan(url: URL) -> SpineFeatureScan {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SpineFeatureScan()
        }

        var scan = SpineFeatureScan()
        scan.collectAttachmentTypes(root: root)
        scan.collectAnimationTimelines(root: root)
        scan.collectConstraintKeys(root: root)
        scan.hasEventData = containsAnyKey(root, keys: ["events", "event"])
        scan.hasAudioData = containsAnyKey(root, keys: ["audio"])
        scan.hasSequenceData = containsAnyKey(root, keys: ["sequence"])
            || scan.attachmentTypes.contains("sequence")
        return scan
    }

    private mutating func collectAttachmentTypes(root: [String: Any]) {
        guard let skins = root["skins"] as? [[String: Any]] else { return }
        for skin in skins {
            let skinName = skin["name"] as? String ?? "default"
            guard let attachmentsBySlot = skin["attachments"] as? [String: Any] else { continue }
            for (slotName, rawSlotAttachments) in attachmentsBySlot {
                guard let slotAttachments = rawSlotAttachments as? [String: Any] else { continue }
                let attachmentNames = Set(slotAttachments.keys)
                for (attachmentName, rawAttachment) in slotAttachments {
                    guard let attachment = rawAttachment as? [String: Any] else { continue }
                    let type: String
                    if let rawType = attachment["type"] as? String {
                        type = rawType.lowercased()
                        attachmentTypes.insert(type)
                    } else if attachment["triangles"] != nil || attachment["uvs"] != nil {
                        type = "mesh"
                        attachmentTypes.insert("mesh")
                    } else {
                        type = "region"
                        attachmentTypes.insert("region")
                    }
                    guard type == "linkedmesh" else { continue }
                    if let referencedSkin = attachment["skin"] as? String,
                       referencedSkin.isEmpty == false,
                       referencedSkin != skinName {
                        unsupportedLinkedMeshReferences.insert("\(skinName)/\(slotName)/\(attachmentName):external-skin=\(referencedSkin)")
                    }
                    guard let parentName = attachment["parent"] as? String,
                          parentName.isEmpty == false else {
                        unsupportedLinkedMeshReferences.insert("\(skinName)/\(slotName)/\(attachmentName):missing-parent")
                        continue
                    }
                    if attachmentNames.contains(parentName) == false {
                        unsupportedLinkedMeshReferences.insert("\(skinName)/\(slotName)/\(attachmentName):missing-parent=\(parentName)")
                    }
                }
            }
        }
    }

    private mutating func collectAnimationTimelines(root: [String: Any]) {
        guard let animations = root["animations"] as? [String: Any] else { return }
        for rawAnimation in animations.values {
            guard let animation = rawAnimation as? [String: Any] else { continue }
            collectBoneTimelineKeys(animation["bones"])
            collectSlotTimelineKeys(animation["slots"])
            collectAttachmentTimelineKeys(animation["attachments"])
            if animation["drawOrder"] != nil {
                timelineKeys.insert("drawOrder")
            }
            if animation["draworder"] != nil {
                timelineKeys.insert("draworder")
            }
            for key in animation.keys where !["bones", "slots", "attachments", "drawOrder", "draworder"].contains(key) {
                timelineKeys.insert(key)
            }
        }
    }

    private mutating func collectBoneTimelineKeys(_ raw: Any?) {
        guard let bones = raw as? [String: Any] else { return }
        for rawTimelineSet in bones.values {
            guard let timelineSet = rawTimelineSet as? [String: Any] else { continue }
            for key in timelineSet.keys {
                timelineKeys.insert("bones.\(key)")
            }
        }
    }

    private mutating func collectSlotTimelineKeys(_ raw: Any?) {
        guard let slots = raw as? [String: Any] else { return }
        for rawTimelineSet in slots.values {
            guard let timelineSet = rawTimelineSet as? [String: Any] else { continue }
            for key in timelineSet.keys {
                timelineKeys.insert("slots.\(key)")
            }
        }
    }

    private mutating func collectAttachmentTimelineKeys(_ raw: Any?) {
        guard let skins = raw as? [String: Any] else { return }
        for rawSlots in skins.values {
            guard let slots = rawSlots as? [String: Any] else { continue }
            for rawAttachments in slots.values {
                guard let attachments = rawAttachments as? [String: Any] else { continue }
                for rawTimelineSet in attachments.values {
                    guard let timelineSet = rawTimelineSet as? [String: Any] else { continue }
                    for key in timelineSet.keys {
                        timelineKeys.insert("attachments.\(key)")
                    }
                }
            }
        }
    }

    private mutating func collectConstraintKeys(root: [String: Any]) {
        for key in ["ik", "transform", "path", "physics"] where root[key] != nil {
            constraintKeys.insert(key)
        }
    }

    private static func containsAnyKey(_ value: Any, keys: Set<String>) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if keys.contains(key) {
                    return true
                }
                if containsAnyKey(child, keys: keys) {
                    return true
                }
            }
        } else if let array = value as? [Any] {
            for child in array where containsAnyKey(child, keys: keys) {
                return true
            }
        }
        return false
    }
}

private extension Set where Element == String {
    var listOrNone: String {
        isEmpty ? "none" : sorted().joined(separator: ",")
    }
}

private extension Array where Element == String {
    var uniquePreservingOrder: [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
