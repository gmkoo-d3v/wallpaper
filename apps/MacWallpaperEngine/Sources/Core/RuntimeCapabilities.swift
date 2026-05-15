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
        rows.append(assetRow(name: "video", isPresent: manifest.assets.video != nil, detail: manifest.assets.video?.path))
        rows.append(assetRow(name: "compositeVideo", isPresent: manifest.assets.compositeVideo != nil, detail: manifest.assets.compositeVideo?.path))
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
            category: "performance",
            name: "resourceFallback",
            status: manifest.assets.compositeVideo == nil ? "fallback" : "supported",
            detail: manifest.assets.compositeVideo == nil ? "no compositeVideo asset; downgrade falls back to lower FPS/static policy" : "compositeVideo available for exhausted native budget"
        ))

        rows.append(contentsOf: interactionRows(manifest.interactions, policy: manifest.interactionPolicy))
        rows.append(contentsOf: spineRows(runtime: runtime))

        return rows
    }

    private static func assetRow(name: String, isPresent: Bool, detail: String?) -> RuntimeCapabilityRow {
        RuntimeCapabilityRow(
            category: "asset",
            name: name,
            status: isPresent ? "supported" : "not-used",
            detail: detail ?? "none"
        )
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
        policy: InteractionPolicy?
    ) -> [RuntimeCapabilityRow] {
        var rows: [RuntimeCapabilityRow] = []
        let policyMode = policy?.mode.rawValue ?? "desktop-empty-only(default)"
        rows.append(RuntimeCapabilityRow(
            category: "interaction",
            name: "policy",
            status: policy?.mode == .disabled ? "not-used" : "supported",
            detail: "mode=\(policyMode) blockAppWindows=\(policy?.blockApplicationWindows ?? true) blockDesktopItems=\(policy?.blockDesktopItems ?? true)"
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
        let buttons = Set(pointerDown.flatMap { $0.buttons ?? [.left] }.map(\.rawValue)).sorted().joined(separator: ",")
        rows.append(RuntimeCapabilityRow(
            category: "interaction",
            name: "pointerDown/hitZones",
            status: hitZoneCount == 0 ? "not-used" : "supported",
            detail: hitZoneCount == 0 ? "none" : "\(hitZoneCount) zone(s) buttons=\(buttons.isEmpty ? "left(default)" : buttons)"
        ))

        return rows
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

        let scan = SpineFeatureScan.scan(url: spine.json)
        let attachmentStatus = scan.unsupportedAttachmentTypes.isEmpty ? "supported" : "unsupported"
        let timelineStatus = scan.unsupportedTimelineKeys.isEmpty ? "supported" : "unsupported"

        return [
            RuntimeCapabilityRow(
                category: "spine",
                name: "nativeRenderer",
                status: "supported",
                detail: "Spine 4.2 setup/mesh renderer, placement=\(spine.placement.mode), pma=\(spine.premultipliedAlpha)"
            ),
            RuntimeCapabilityRow(
                category: "spine",
                name: "attachments",
                status: attachmentStatus,
                detail: "used=\(scan.attachmentTypes.listOrNone) unsupported=\(scan.unsupportedAttachmentTypes.listOrNone)"
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
                status: scan.hasEventsOrAudioOrSequence ? "unsupported" : "not-used",
                detail: scan.hasEventsOrAudioOrSequence ? "events/audio/sequence data detected" : "none"
            )
        ]
    }
}

private struct SpineFeatureScan {
    var attachmentTypes: Set<String> = []
    var timelineKeys: Set<String> = []
    var constraintKeys: Set<String> = []
    var hasEventsOrAudioOrSequence = false

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
            "draworder"
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
        scan.hasEventsOrAudioOrSequence = containsAnyKey(root, keys: ["events", "event", "audio", "sequence"])
        return scan
    }

    private mutating func collectAttachmentTypes(root: [String: Any]) {
        guard let skins = root["skins"] as? [[String: Any]] else { return }
        for skin in skins {
            guard let attachmentsBySlot = skin["attachments"] as? [String: Any] else { continue }
            for rawSlotAttachments in attachmentsBySlot.values {
                guard let slotAttachments = rawSlotAttachments as? [String: Any] else { continue }
                for rawAttachment in slotAttachments.values {
                    guard let attachment = rawAttachment as? [String: Any] else { continue }
                    if let type = attachment["type"] as? String {
                        attachmentTypes.insert(type.lowercased())
                    } else if attachment["triangles"] != nil || attachment["uvs"] != nil {
                        attachmentTypes.insert("mesh")
                    } else {
                        attachmentTypes.insert("region")
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
