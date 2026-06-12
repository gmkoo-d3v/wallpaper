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

private func nativeSpineDegradationText(_ degradations: [String]) -> String {
    guard degradations.isEmpty == false else { return "none" }
    return "degraded constraint usages: \(Set(degradations).compactListOrNone)"
}

struct NativeSpineCompatibility {
    let isSupported: Bool
    let reasons: [String]
    let degradations: [String]

    var reasonText: String {
        reasons.isEmpty ? "supported" : reasons.joined(separator: "; ")
    }

    var degradationText: String {
        nativeSpineDegradationText(degradations)
    }

    var statusText: String {
        if isSupported == false { return "unsupported" }
        if degradations.isEmpty == false { return "degraded" }
        return "supported"
    }

    var detailText: String {
        if isSupported == false { return reasonText }
        if degradations.isEmpty == false { return degradationText }
        return "supported"
    }
}

struct WallpaperBundleCapabilityInfo: Equatable {
    let sourceSummary: String
    let sourceDerivationSummary: String
    let assetKinds: [String]
    let layerKinds: [String]
    let interactionKinds: [String]
    let interactionRequirement: String
    let bindingKinds: [String]
    let effectKinds: [String]
    let nativeSpineStatus: String
    let nativeSpineReasons: [String]
    let nativeSpineDegradations: [String]
    let fallbackStatus: String
    let qualityStatus: String
    let qualityWarnings: [String]
    let qualityRecommendations: [String]

    var briefText: String {
        [
            "source: \(sourceSummary)",
            "derivation: \(sourceDerivationSummary)",
            "assets: \(assetKinds.joined(separator: "+"))",
            "layers: \(layerKinds.joined(separator: "+"))",
            "interactions: \(interactionKinds.joined(separator: "+"))",
            "bindings: \(bindingKinds.joined(separator: "+"))",
            "effects: \(effectKinds.joined(separator: "+"))",
            "input: \(interactionRequirement)",
            "native: \(nativeSpineSummary)",
            "fallback: \(fallbackStatus)",
            "quality: \(qualitySummary)"
        ].joined(separator: " / ")
    }

    var nativeSpineSummary: String {
        if nativeSpineStatus == "unsupported", nativeSpineReasons.isEmpty == false {
            return "\(nativeSpineStatus)(\(nativeSpineReasons.joined(separator: "; ")))"
        }
        if nativeSpineStatus == "degraded", nativeSpineDegradations.isEmpty == false {
            return "\(nativeSpineStatus)(\(nativeSpineDegradationText(nativeSpineDegradations)))"
        }
        return nativeSpineStatus
    }

    var sourceDerivationBadge: String {
        if sourceDerivationSummary.hasPrefix("partial") {
            return "partial-source"
        }
        if sourceDerivationSummary.hasPrefix("source-derived") {
            return "source-derived"
        }
        return "source-unknown"
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
        let declarativePlan = DeclarativeBindingPlan(manifest: manifest)
        var rows: [RuntimeCapabilityRow] = []

        rows.append(assetRow(name: "staticImage", isPresent: manifest.assets.staticImage != nil, detail: manifest.assets.staticImage?.path))
        rows.append(sourceProvenanceRow(manifest.sourceProvenance))
        rows.append(sourceDerivationRow(manifest.sourceProvenance))
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
                detail: layerDetail(layer)
            ))
        }

        rows.append(displayRow(name: "primary", policy: manifest.displayPolicy.primary))
        rows.append(displayRow(name: "secondary", policy: manifest.displayPolicy.secondary))
        rows.append(displayRow(name: "fullscreenObscured", policy: manifest.displayPolicy.fullscreenObscured))
        rows.append(displayRow(name: "occluded", policy: manifest.displayPolicy.occluded))
        rows.append(contentsOf: displayModeRows(runtime: runtime))

        rows.append(RuntimeCapabilityRow(
            category: "performance",
            name: "frameScheduler",
            status: "supported",
            detail: "target=\(runtime.renderTargetFps) activeRenderFps=\(primaryActiveRenderFps(runtime: runtime)) idleRenderFps=\(primaryIdleRenderFps(runtime: runtime)) nativeSpinePoseFps=\(runtime.nativeSpinePoseSampleFps(displayRefreshFps: nil)) nativeSpineIdlePoseFps=\(runtime.nativeSpineIdlePoseSampleFps(displayRefreshFps: nil)) physicsIdlePolicy=\(manifest.runtime.effectivePhysicsIdlePolicy.rawValue) max=\(manifest.runtime.maxFps) fallback=\(manifest.runtime.fallbackFps) inFlight=\(manifest.runtime.scheduler.maxInFlightCommandBuffers)"
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
        rows.append(audioPolicyRow(runtime))

        let actionTailDurations = (try? SpineAnimationDiagnostics.tapActionDurations(runtime: runtime)) ?? [:]
        rows.append(contentsOf: interactionRows(
            manifest.interactions,
            policy: manifest.interactionPolicy,
            actionTailDurations: actionTailDurations
        ))
        rows.append(contentsOf: declarativeBindingRows(declarativePlan))
        rows.append(contentsOf: effectRows(declarativePlan))
        rows.append(contentsOf: spineRows(runtime: runtime))

        return rows
    }

    private static func audioPolicyRow(_ runtime: NativeRuntimeCore) -> RuntimeCapabilityRow {
        let policy = runtime.manifest.runtime.effectiveAudioPolicy
        return RuntimeCapabilityRow(
            category: "audio",
            name: "policy",
            status: runtime.audioCapabilityStatus,
            detail: "policy=\(policy.rawValue) userOptIn=\(runtime.config.audioEnabled) output=\(runtime.audioOutputSummary)"
        )
    }

    private static func primaryIdleRenderFps(runtime: NativeRuntimeCore) -> Int {
        let role = RenderDisplayRole(kind: .primary, policy: runtime.manifest.displayPolicy.primary)
        let compatibility = nativeSpineCompatibility(runtime: runtime)
        let foregroundPlan = ForegroundRenderPlan.make(
            runtime: runtime,
            role: role,
            compatibility: compatibility
        )
        let selectedVideo: VideoAsset? = if role.playsVideo == false {
            nil
        } else if foregroundPlan.usesCompositeVideo {
            runtime.assetCatalog.compositeVideoAsset
        } else {
            runtime.assetCatalog.videoAsset
        }
        return runtime.idleRenderFps(
            displayRefreshFps: nil,
            videoAsset: selectedVideo,
            playsVideo: selectedVideo != nil,
            rendersNativeForeground: foregroundPlan.usesNativeSpine && role.rendersForeground
        )
    }

    private static func primaryActiveRenderFps(runtime: NativeRuntimeCore) -> Int {
        let role = RenderDisplayRole(kind: .primary, policy: runtime.manifest.displayPolicy.primary)
        let compatibility = nativeSpineCompatibility(runtime: runtime)
        let foregroundPlan = ForegroundRenderPlan.make(
            runtime: runtime,
            role: role,
            compatibility: compatibility
        )
        let selectedVideo: VideoAsset? = if role.playsVideo == false {
            nil
        } else if foregroundPlan.usesCompositeVideo {
            runtime.assetCatalog.compositeVideoAsset
        } else {
            runtime.assetCatalog.videoAsset
        }
        return runtime.activeRenderFps(
            displayRefreshFps: nil,
            videoAsset: selectedVideo,
            playsVideo: selectedVideo != nil,
            rendersNativeForeground: foregroundPlan.usesNativeSpine && role.rendersForeground
        )
    }

    static func nativeSpineCompatibility(runtime: NativeRuntimeCore) -> NativeSpineCompatibility {
        runtime.nativeSpineCompatibility
    }

    static func nativeSpineCompatibility(
        manifest: WallpaperNativeManifest,
        bundleRoot: URL
    ) -> NativeSpineCompatibility {
        guard let spine = manifest.assets.spine else {
            return NativeSpineCompatibility(isSupported: true, reasons: [], degradations: [])
        }

        let spineJSON = bundleRoot.appendingPathComponent(spine.json).standardizedFileURL
        let scan = SpineFeatureScan.scan(url: spineJSON)
        var reasons: [String] = []
        var degradations: [String] = []
        if scan.unsupportedAttachmentTypes.isEmpty == false {
            reasons.append("unsupported attachment types: \(scan.unsupportedAttachmentTypes.listOrNone)")
        }
        if scan.unsupportedLinkedMeshReferences.isEmpty == false {
            reasons.append("unsupported linkedmesh references: \(scan.unsupportedLinkedMeshReferences.listOrNone)")
        }
        if scan.unsupportedTimelineKeys.isEmpty == false {
            reasons.append("unsupported timeline keys: \(scan.unsupportedTimelineKeys.listOrNone)")
        }
        if scan.unsupportedConstraintUsages.isEmpty == false {
            reasons.append("unsupported constraint usages: \(scan.unsupportedConstraintUsages.listOrNone)")
        }
        if scan.unsupportedSlotFeatures.isEmpty == false {
            reasons.append("unsupported slot features: \(scan.unsupportedSlotFeatures.listOrNone)")
        }
        if scan.unsupportedBlendModes.isEmpty == false {
            reasons.append("unsupported blend modes: \(scan.unsupportedBlendModes.listOrNone)")
        }
        if scan.degradedConstraintUsages.isEmpty == false {
            degradations.append(contentsOf: scan.degradedConstraintUsages.sorted())
        }
        return NativeSpineCompatibility(
            isSupported: reasons.isEmpty,
            reasons: reasons,
            degradations: degradations
        )
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
        let declarativePlan = DeclarativeBindingPlan(manifest: manifest)
        let bindingKinds = declarativePlan.bindingKinds
        let effectKinds = declarativePlan.effectKinds
        let compatibility = nativeSpineCompatibility(manifest: manifest, bundleRoot: bundleRoot)
        let nativeSpineStatus: String
        if manifest.assets.spine == nil {
            nativeSpineStatus = "not-used"
        } else {
            nativeSpineStatus = compatibility.statusText
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
        let qualityStatus = qualityReport.status == "not-used" ? "ok" : qualityReport.status

        return WallpaperBundleCapabilityInfo(
            sourceSummary: sourceProvenanceSummary(manifest.sourceProvenance),
            sourceDerivationSummary: sourceDerivationSummary(manifest.sourceProvenance),
            assetKinds: assetKinds,
            layerKinds: layerKinds.isEmpty ? ["none"] : layerKinds,
            interactionKinds: interactionKinds,
            interactionRequirement: interactionRequirement(for: manifest.interactions, policy: manifest.interactionPolicy),
            bindingKinds: bindingKinds,
            effectKinds: effectKinds,
            nativeSpineStatus: nativeSpineStatus,
            nativeSpineReasons: compatibility.reasons,
            nativeSpineDegradations: compatibility.degradations,
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

    private static func sourceProvenanceRow(_ provenance: SourceProvenance?) -> RuntimeCapabilityRow {
        RuntimeCapabilityRow(
            category: "source",
            name: "provenance",
            status: provenance == nil ? "unspecified" : "declared",
            detail: sourceProvenanceSummary(provenance)
        )
    }

    private static func sourceDerivationRow(_ provenance: SourceProvenance?) -> RuntimeCapabilityRow {
        let summary = sourceDerivationSummary(provenance)
        let status: String
        if summary.hasPrefix("partial") {
            status = "partial"
        } else if summary.hasPrefix("source-derived") {
            status = "source-derived"
        } else {
            status = "unknown"
        }
        return RuntimeCapabilityRow(
            category: "source",
            name: "derivation",
            status: status,
            detail: summary
        )
    }

    private static func sourceProvenanceSummary(_ provenance: SourceProvenance?) -> String {
        guard let provenance else { return "unspecified" }
        let imported = provenance.importedFields?.count ?? 0
        let calibrated = provenance.calibratedFields?.count ?? 0
        let platformPolicy = provenance.platformPolicyFields?.count ?? 0
        let unsupported = provenance.unsupportedFields?.count ?? 0
        let descriptors = provenance.sourceDescriptors?.count ?? 0
        let runtime = provenance.sourceRuntime.map { " runtime=\($0)" } ?? ""
        let projectType = provenance.projectType.map { " project=\($0)" } ?? ""
        return "\(provenance.sourceType.rawValue)\(runtime)\(projectType) descriptors=\(descriptors) imported=\(imported) calibrated=\(calibrated) platformPolicy=\(platformPolicy) unsupported=\(unsupported)"
    }

    private static func sourceDerivationSummary(_ provenance: SourceProvenance?) -> String {
        RuntimeSourceProvenanceReport.derivationStatus(provenance: provenance)
            .replacingOccurrences(of: "sourceDerivation: ", with: "")
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

    private static func layerDetail(_ layer: LayerConfig) -> String {
        var parts = ["\(layer.id) -> \(layer.asset)"]
        if let renderingMode = layer.renderingMode {
            parts.append("renderingMode=\(renderingMode)")
        }
        if let occlusion = layer.foregroundOcclusion, occlusion.enabled != false {
            let source = occlusion.sourceRect.map(formatNormalizedRectNumber).joined(separator: ",")
            let destination = occlusion.destinationRect.map(formatNormalizedRectNumber).joined(separator: ",")
            parts.append("foregroundOcclusion=source[\(source)]->dest[\(destination)]")
        }
        return parts.joined(separator: " ")
    }

    private static func formatNormalizedRectNumber(_ value: Double) -> String {
        let rounded = String(format: "%.3f", value)
        return rounded
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
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

    private static func displayModeRows(runtime: NativeRuntimeCore) -> [RuntimeCapabilityRow] {
        [DisplayMode.primaryOnly, .primaryAnimated, .all].map { mode in
            let primaryRole = DisplayPlanner.role(
                isPrimary: true,
                displayMode: mode,
                manifest: runtime.manifest
            )
            let secondaryRole = DisplayPlanner.role(
                isPrimary: false,
                displayMode: mode,
                manifest: runtime.manifest
            )
            let primary = primaryRole.map { displayModePolicyLabel($0.policy) } ?? "none"
            let secondary = secondaryRole.map { displayModePolicyLabel($0.policy) } ?? "none"
            let interaction = secondaryRole?.allowsInteraction == true ? "secondary-interactive" : "secondary-passive"
            return RuntimeCapabilityRow(
                category: "displayMode",
                name: mode.cliName,
                status: primaryRole == nil && secondaryRole == nil ? "not-used" : "supported",
                detail: "primary=\(primary) secondary=\(secondary) \(interaction)"
            )
        }
    }

    private static func displayModePolicyLabel(_ policy: DisplayRolePolicy) -> String {
        switch policy {
        case .full:
            return "full(video+foreground)"
        case .videoOnly:
            return "video-only(background)"
        case .static:
            return "static(preview)"
        case .pause:
            return "pause"
        }
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

    private static func declarativeBindingRows(_ plan: DeclarativeBindingPlan) -> [RuntimeCapabilityRow] {
        guard plan.bindingEntries.isEmpty == false else {
            return [
                RuntimeCapabilityRow(
                    category: "binding",
                    name: "declarative",
                    status: "not-used",
                    detail: "no manifest-declared bindings"
                )
            ]
        }

        let enabledCount = plan.bindingEntries.filter(\.isEnabled).count
        let ids = plan.bindingEntries.map(\.id).joined(separator: ",")
        let adapters = plan.bindingEntries.map(\.adapterKind).uniquePreservingOrder.joined(separator: ",")
        let targets = plan.bindingEntries.map { $0.target.kind.rawValue }.uniquePreservingOrder.joined(separator: ",")
        let entries = plan.bindingEntries
            .map { entry in
                "\(entry.id):\(entry.source.rawValue)->\(entry.target.summary) via \(entry.adapterKind) \(entry.runtimeStatus.rawValue)"
            }
            .joined(separator: ";")
        return [
            RuntimeCapabilityRow(
                category: "binding",
                name: "declarative",
                status: "declared",
                detail: "\(plan.bindingEntries.count) binding(s) enabled=\(enabledCount) status=\(plan.bindingStatusSummary) adapters=\(adapters) targets=\(targets) ids=\(ids) entries=\(entries)"
            )
        ]
    }

    private static func effectRows(_ plan: DeclarativeBindingPlan) -> [RuntimeCapabilityRow] {
        guard plan.effectEntries.isEmpty == false else {
            return [
                RuntimeCapabilityRow(
                    category: "effect",
                    name: "whitelist",
                    status: "not-used",
                    detail: "no manifest-declared effects"
                )
            ]
        }

        return plan.effectEntries.map { effect in
            RuntimeCapabilityRow(
                category: "effect",
                name: effect.id,
                status: effect.runtimeStatus.rawValue,
                detail: "type=\(effect.effectKind) properties=\(effect.propertyCount) status=\(effect.runtimeStatus.rawValue)"
            )
        }
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
            return blocksDesktopItems ? "desktop-empty-best-effort" : "desktop-empty"
        }
    }

    private static func desktopItemGate(policy: InteractionPolicy?) -> String {
        desktopItemGate(
            policy: policy,
            accessibilityTrusted: DesktopInteractionGate.hasAccessibilityTrust()
        )
    }

    static func desktopItemGate(
        policy: InteractionPolicy?,
        accessibilityTrusted: Bool
    ) -> String {
        let mode = policy?.mode ?? .desktopEmptyOnly
        let blocksDesktopItems = policy?.blockDesktopItems ?? true
        guard mode == .desktopEmptyOnly, blocksDesktopItems else { return "not-required" }
        _ = accessibilityTrusted
        return "best-effort(current=no-permission,no-ax-api)"
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
        let hasUnsupportedSequenceAttachment = scan.attachmentTypes.contains("sequence")
        if hasUnsupportedSequenceAttachment {
            eventFeatureStatus = "unsupported"
        } else if scan.hasEventData || scan.hasAudioData || scan.hasSequenceData {
            eventFeatureStatus = "supported"
        } else {
            eventFeatureStatus = "not-used"
        }
        let sequenceDetail: String
        if hasUnsupportedSequenceAttachment {
            sequenceDetail = "sequence=unsupported-attachment"
        } else if scan.timelineKeys.contains("attachments.sequence") {
            sequenceDetail = "sequence=playback"
        } else if scan.hasSequenceData {
            sequenceDetail = "sequence=setup-frame"
        } else {
            sequenceDetail = "sequence=none"
        }
        let eventFeatureDetail = [
            scan.hasEventData ? "events=ignored(non-visual)" : "events=none",
            scan.hasAudioData ? "audio=ignored(non-visual)" : "audio=none",
            sequenceDetail,
            "payloads=\(scan.eventPayloadKeys.listOrNone)"
        ].joined(separator: " ")

        let nativeRendererStatus: String
        let nativeRendererDetail: String
        if compatibility.isSupported {
            nativeRendererStatus = "supported"
            let placementDetail = spine.placement.mode == "skeleton-bounds"
                ? "skeleton-bounds(contain-fit)"
                : spine.placement.mode
            nativeRendererDetail = "Spine 4.2 setup/mesh renderer, placement=\(placementDetail), pma=\(spine.premultipliedAlpha)"
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
                status: compatibility.statusText,
                detail: compatibility.detailText
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
                detail: "renderable=\(scan.renderableAttachmentTypes.listOrNone) ignoredNonVisual=\(scan.ignoredNonVisualAttachmentTypes.listOrNone) unsupported=\(scan.unsupportedAttachmentTypes.listOrNone) linkedmeshIssues=\(scan.unsupportedLinkedMeshReferences.listOrNone)"
            ),
            RuntimeCapabilityRow(
                category: "spine",
                name: "timelines",
                status: timelineStatus,
                detail: "used=\(scan.timelineKeys.listOrNone) unsupported=\(scan.unsupportedTimelineKeys.listOrNone)"
            ),
            RuntimeCapabilityRow(
                category: "spine",
                name: "blendModes",
                status: scan.unsupportedBlendModes.isEmpty ? "supported" : "unsupported",
                detail: "used=\(scan.blendModes.listOrNone) unsupported=\(scan.unsupportedBlendModes.listOrNone)"
            ),
            RuntimeCapabilityRow(
                category: "spine",
                name: "slotFeatures",
                status: scan.unsupportedSlotFeatures.isEmpty ? "supported" : "unsupported",
                detail: "supported=\(scan.supportedSlotFeatures.listOrNone) unsupported=\(scan.unsupportedSlotFeatures.listOrNone)"
            ),
            constraintCapabilityRow(scan),
            RuntimeCapabilityRow(
                category: "spine",
                name: "eventsAudioSequence",
                status: eventFeatureStatus,
                detail: eventFeatureDetail
            )
        ]
    }

    private static func constraintCapabilityRow(_ scan: SpineFeatureScan) -> RuntimeCapabilityRow {
        if scan.constraintKeys.isEmpty {
            return RuntimeCapabilityRow(
                category: "spine",
                name: "constraints",
                status: "not-used",
                detail: "none"
            )
        }

        let unsupported = scan.unsupportedConstraintUsages
        let degraded = scan.degradedConstraintUsages
        let status: String
        let detail: String
        if unsupported.isEmpty == false {
            status = "unsupported"
            detail = "used=\(scan.constraintKeys.listOrNone) unsupported=\(unsupported.listOrNone)"
        } else if degraded.isEmpty == false {
            status = "degraded"
            detail = "used=\(scan.constraintKeys.listOrNone) degraded=\(degraded.compactListOrNone)"
        } else {
            status = "supported"
            detail = "used=\(scan.constraintKeys.listOrNone)"
        }
        return RuntimeCapabilityRow(
            category: "spine",
            name: "constraints",
            status: status,
            detail: detail
        )
    }
}

private struct SpineFeatureScan {
    private struct SkinAttachmentSource {
        let name: String
        let attachments: [String: Any]
    }

    private struct ScanCacheKey: Hashable {
        let path: String
        let fileSize: Int
        let modificationTime: TimeInterval
    }

    var attachmentTypes: Set<String> = []
    var timelineKeys: Set<String> = []
    var constraintKeys: Set<String> = []
    var blendModes: Set<String> = []
    var supportedSlotFeatures: Set<String> = []
    var unsupportedSlotFeatures: Set<String> = []
    var unsupportedConstraintUsages: Set<String> = []
    var degradedConstraintUsages: Set<String> = []
    var unsupportedLinkedMeshReferences: Set<String> = []
    var hasEventData = false
    var hasAudioData = false
    var hasSequenceData = false
    var eventPayloadKeys: Set<String> = []

    private static let renderableAttachmentTypes: Set<String> = ["region", "mesh", "linkedmesh", "path", "clipping"]
    private static let nonVisualAttachmentTypes: Set<String> = ["point", "boundingbox"]
    private static let structuralKeyTraversalLeafKeys: Set<String> = ["vertices", "triangles", "uvs", "edges", "hull"]
    private static let scanCacheLimit = 64
    private static let scanCacheLock = NSLock()
    private static var scanCache: [ScanCacheKey: SpineFeatureScan] = [:]
    private static var scanCacheOrder: [ScanCacheKey] = []

    var renderableAttachmentTypes: Set<String> {
        attachmentTypes.intersection(Self.renderableAttachmentTypes)
    }

    var ignoredNonVisualAttachmentTypes: Set<String> {
        attachmentTypes.intersection(Self.nonVisualAttachmentTypes)
    }

    var unsupportedAttachmentTypes: Set<String> {
        attachmentTypes.subtracting(Self.renderableAttachmentTypes.union(Self.nonVisualAttachmentTypes))
    }

    var unsupportedTimelineKeys: Set<String> {
        timelineKeys.subtracting([
            "bones.rotate",
            "bones.translate",
            "bones.translateX",
            "bones.translateY",
            "bones.translatex",
            "bones.translatey",
            "bones.scale",
            "bones.scaleX",
            "bones.scaleY",
            "bones.scalex",
            "bones.scaley",
            "bones.shear",
            "bones.shearX",
            "bones.shearY",
            "bones.shearx",
            "bones.sheary",
            "slots.color",
            "slots.rgba",
            "slots.rgb",
            "slots.alpha",
            "slots.rgba2",
            "slots.rgb2",
            "slots.twoColor",
            "slots.attachment",
            "attachments.deform",
            "attachments.sequence",
            "ik.bendPositive",
            "ik.compress",
            "ik.mix",
            "ik.stretch",
            "transform.mixRotate",
            "transform.mixX",
            "transform.mixY",
            "transform.mixScaleX",
            "transform.mixScaleY",
            "transform.mixShearY",
            "transform.rotateMix",
            "transform.translateMix",
            "transform.scaleMix",
            "transform.shearMix",
            "path.mixRotate",
            "path.mixX",
            "path.mixY",
            "path.position",
            "path.rotateMix",
            "path.spacing",
            "path.translateMix",
            "drawOrder",
            "draworder",
            "events",
            "event"
        ])
    }

    var unsupportedBlendModes: Set<String> {
        Set(blendModes.filter { RenderBlendMode(spineBlend: $0) == nil })
    }

    static func scan(url: URL) -> SpineFeatureScan {
        let cacheKey = scanCacheKey(url: url)
        if let cacheKey {
            scanCacheLock.lock()
            let cached = scanCache[cacheKey]
            scanCacheLock.unlock()
            if let cached {
                return cached
            }
        }

        let scan = scanUncached(url: url)
        if let cacheKey {
            scanCacheLock.lock()
            if scanCache[cacheKey] == nil {
                scanCacheOrder.append(cacheKey)
            }
            scanCache[cacheKey] = scan
            while scanCache.count > scanCacheLimit, scanCacheOrder.isEmpty == false {
                let overflowKey = scanCacheOrder.removeFirst()
                scanCache.removeValue(forKey: overflowKey)
            }
            scanCacheLock.unlock()
        }
        return scan
    }

    private static func scanCacheKey(url: URL) -> ScanCacheKey? {
        let standardizedURL = url.standardizedFileURL
        guard let values = try? standardizedURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey
        ]),
              let modificationDate = values.contentModificationDate,
              let fileSize = values.fileSize else {
            return nil
        }
        return ScanCacheKey(
            path: standardizedURL.path,
            fileSize: fileSize,
            modificationTime: modificationDate.timeIntervalSince1970
        )
    }

    private static func scanUncached(url: URL) -> SpineFeatureScan {
        guard let data = try? Data(contentsOf: url),
              let rootObject = try? JSONSerialization.jsonObject(with: data),
              let root = rootObject as? [String: Any] else {
            return SpineFeatureScan()
        }

        var scan = SpineFeatureScan()
        scan.collectAttachmentTypes(root: root)
        scan.collectSlotBlendModes(root: root)
        scan.collectSlotFeatures(root: root)
        scan.collectAnimationTimelines(root: root)
        scan.collectConstraintKeys(root: root)
        let structuralKeys = containedKeys(rootObject, keys: ["events", "event", "audio", "sequence"])
        scan.hasEventData = structuralKeys.contains("events") || structuralKeys.contains("event")
        scan.hasAudioData = structuralKeys.contains("audio")
        scan.hasSequenceData = structuralKeys.contains("sequence")
            || scan.attachmentTypes.contains("sequence")
        scan.collectEventPayloadKeys(root: root)
        return scan
    }

    private mutating func collectSlotBlendModes(root: [String: Any]) {
        guard let slots = root["slots"] as? [[String: Any]] else { return }
        for slot in slots {
            let trimmedBlend = (slot["blend"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawBlend: String
            if let trimmedBlend, trimmedBlend.isEmpty == false {
                rawBlend = trimmedBlend
            } else {
                rawBlend = "normal"
            }
            blendModes.insert(rawBlend.lowercased())
        }
    }

    private mutating func collectSlotFeatures(root: [String: Any]) {
        guard let slots = root["slots"] as? [[String: Any]] else { return }
        for slot in slots {
            let name = slot["name"] as? String ?? "unnamed"
            if slot["dark"] != nil {
                supportedSlotFeatures.insert("slot/\(name):static-two-color-tint")
            }
        }
    }

    private mutating func collectAttachmentTypes(root: [String: Any]) {
        let skins = skinAttachmentSources(root: root)
        var skinsByName: [String: SkinAttachmentSource] = [:]
        for skin in skins {
            skinsByName[skin.name] = skin
        }
        for skin in skins {
            let skinName = skin.name
            let attachmentsBySlot = skin.attachments
            for (slotName, rawSlotAttachments) in attachmentsBySlot {
                guard let slotAttachments = rawSlotAttachments as? [String: Any] else { continue }
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
                    guard let parentName = attachment["parent"] as? String,
                          parentName.isEmpty == false else {
                        unsupportedLinkedMeshReferences.insert("\(skinName)/\(slotName)/\(attachmentName):missing-parent")
                        continue
                    }
                    let parentSkinName = (attachment["skin"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? skinName
                    guard let parentSkin = skinsByName[parentSkinName],
                          let parentSlotAttachments = parentSkin.attachments[slotName] as? [String: Any] else {
                        unsupportedLinkedMeshReferences.insert("\(skinName)/\(slotName)/\(attachmentName):missing-parent-skin=\(parentSkinName)")
                        continue
                    }
                    if parentSlotAttachments[parentName] == nil {
                        unsupportedLinkedMeshReferences.insert("\(skinName)/\(slotName)/\(attachmentName):missing-parent=\(parentSkinName)/\(parentName)")
                    }
                }
            }
        }
    }

    private func skinAttachmentSources(root: [String: Any]) -> [SkinAttachmentSource] {
        if let skins = root["skins"] as? [[String: Any]] {
            return skins.compactMap { skin in
                guard let attachments = skin["attachments"] as? [String: Any] else { return nil }
                return SkinAttachmentSource(
                    name: skin["name"] as? String ?? "default",
                    attachments: attachments
                )
            }
        }

        if let skins = root["skins"] as? [String: Any] {
            return skins.compactMap { skinName, rawSkin in
                guard let skin = rawSkin as? [String: Any] else { return nil }
                let attachments = skin["attachments"] as? [String: Any] ?? skin
                return SkinAttachmentSource(name: skinName, attachments: attachments)
            }
            .sorted { lhs, rhs in
                if lhs.name == "default" { return true }
                if rhs.name == "default" { return false }
                return lhs.name < rhs.name
            }
        }

        return []
    }

    private mutating func collectAnimationTimelines(root: [String: Any]) {
        guard let animations = root["animations"] as? [String: Any] else { return }
        for rawAnimation in animations.values {
            guard let animation = rawAnimation as? [String: Any] else { continue }
            collectBoneTimelineKeys(animation["bones"])
            collectConstraintTimelineKeys(animation["ik"], prefix: "ik")
            collectConstraintTimelineKeys(animation["transform"], prefix: "transform")
            collectConstraintTimelineKeys(animation["path"], prefix: "path")
            collectSlotTimelineKeys(animation["slots"])
            collectAttachmentTimelineKeys(animation["attachments"])
            collectTopLevelDeformTimelineKeys(animation["deform"])
            if animation["drawOrder"] != nil {
                timelineKeys.insert("drawOrder")
            }
            if animation["draworder"] != nil {
                timelineKeys.insert("draworder")
            }
            for key in animation.keys where !["bones", "ik", "transform", "path", "slots", "attachments", "deform", "drawOrder", "draworder"].contains(key) {
                timelineKeys.insert(key)
            }
        }
    }

    private mutating func collectEventPayloadKeys(root: [String: Any]) {
        if let eventDefinitions = root["events"] as? [String: Any] {
            for rawEvent in eventDefinitions.values {
                collectEventPayloadKeys(from: rawEvent)
            }
        }
        guard let animations = root["animations"] as? [String: Any] else { return }
        for rawAnimation in animations.values {
            guard let animation = rawAnimation as? [String: Any] else { continue }
            collectEventPayloadKeys(from: animation["events"])
            collectEventPayloadKeys(from: animation["event"])
        }
    }

    private mutating func collectEventPayloadKeys(from raw: Any?) {
        if let frames = raw as? [[String: Any]] {
            for frame in frames {
                collectEventPayloadKeys(from: frame)
            }
            return
        }
        guard let event = raw as? [String: Any] else { return }
        for key in ["int", "float", "string", "audio", "volume", "balance"] where event[key] != nil {
            eventPayloadKeys.insert(key)
        }
    }

    private mutating func collectConstraintTimelineKeys(_ raw: Any?, prefix: String) {
        guard let raw else { return }
        guard let constraints = raw as? [String: Any] else {
            timelineKeys.insert(prefix)
            return
        }
        for rawTimelineSet in constraints.values {
            guard let timelineSet = rawTimelineSet as? [String: Any] else {
                timelineKeys.insert(prefix)
                continue
            }
            for key in timelineSet.keys {
                timelineKeys.insert("\(prefix).\(key)")
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

    private mutating func collectTopLevelDeformTimelineKeys(_ raw: Any?) {
        guard let skins = raw as? [String: Any] else { return }
        for rawSlots in skins.values {
            guard let slots = rawSlots as? [String: Any] else { continue }
            for rawAttachments in slots.values {
                guard let attachments = rawAttachments as? [String: Any] else { continue }
                for rawTimeline in attachments.values {
                    if rawTimeline is [[String: Any]] {
                        timelineKeys.insert("attachments.deform")
                    } else if let timelineSet = rawTimeline as? [String: Any],
                              timelineSet["deform"] != nil {
                        timelineKeys.insert("attachments.deform")
                    }
                }
            }
        }
    }

    private mutating func collectConstraintKeys(root: [String: Any]) {
        let boneNames = boneNameSet(root: root)
        let slotNames = slotNameSet(root: root)

        if let constraints = root["ik"] as? [[String: Any]] {
            constraintKeys.insert("ik")
            for constraint in constraints {
                let name = namedConstraint(constraint)
                let constraintBoneNames = constraint["bones"] as? [String] ?? []
                let boneCount = constraintBoneNames.count
                if boneCount < 1 {
                    unsupportedConstraintUsages.insert("ik/\(name):missing-bones")
                } else if boneCount > 2 {
                    unsupportedConstraintUsages.insert("ik/\(name):multi-bone")
                }
                for boneName in constraintBoneNames where boneNames.contains(boneName) == false {
                    unsupportedConstraintUsages.insert("ik/\(name):unknown-bone=\(boneName)")
                }
                let targetName = (constraint["target"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if targetName.isEmpty {
                    unsupportedConstraintUsages.insert("ik/\(name):missing-target")
                } else if boneNames.contains(targetName) == false {
                    unsupportedConstraintUsages.insert("ik/\(name):unknown-target=\(targetName)")
                }
            }
        }

        if let constraints = root["transform"] as? [[String: Any]] {
            constraintKeys.insert("transform")
            for constraint in constraints {
                let name = namedConstraint(constraint)
                let constraintBoneNames = constraint["bones"] as? [String] ?? []
                if constraintBoneNames.isEmpty {
                    unsupportedConstraintUsages.insert("transform/\(name):missing-bones")
                }
                for boneName in constraintBoneNames where boneNames.contains(boneName) == false {
                    unsupportedConstraintUsages.insert("transform/\(name):unknown-bone=\(boneName)")
                }
                let targetName = (constraint["target"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if targetName.isEmpty {
                    unsupportedConstraintUsages.insert("transform/\(name):missing-target")
                } else if boneNames.contains(targetName) == false {
                    unsupportedConstraintUsages.insert("transform/\(name):unknown-target=\(targetName)")
                }
            }
        }

        if let constraints = root["path"] as? [[String: Any]] {
            constraintKeys.insert("path")
            let supportedPositionModes: Set<String> = ["fixed", "percent"]
            let supportedSpacingModes: Set<String> = ["fixed", "length", "percent", "proportional"]
            let supportedRotateModes: Set<String> = ["tangent", "chain", "chainscale"]
            for constraint in constraints {
                let name = namedConstraint(constraint)
                let constraintBoneNames = constraint["bones"] as? [String] ?? []
                if constraintBoneNames.isEmpty {
                    unsupportedConstraintUsages.insert("path/\(name):missing-bones")
                }
                for boneName in constraintBoneNames where boneNames.contains(boneName) == false {
                    unsupportedConstraintUsages.insert("path/\(name):unknown-bone=\(boneName)")
                }
                let targetSlotName = (constraint["target"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if targetSlotName.isEmpty {
                    unsupportedConstraintUsages.insert("path/\(name):missing-target-slot")
                } else if slotNames.contains(targetSlotName) == false {
                    unsupportedConstraintUsages.insert("path/\(name):unknown-target-slot=\(targetSlotName)")
                } else if hasPathAttachment(slotName: targetSlotName, root: root) == false {
                    unsupportedConstraintUsages.insert("path/\(name):target-slot-without-path-attachment=\(targetSlotName)")
                }
                let positionMode = normalizedMode(constraint["positionMode"], default: "percent")
                let spacingMode = normalizedMode(constraint["spacingMode"], default: "length")
                let rotateMode = normalizedMode(constraint["rotateMode"], default: "tangent")
                if supportedPositionModes.contains(positionMode) == false {
                    unsupportedConstraintUsages.insert("path/\(name):positionMode=\(positionMode)")
                }
                if supportedSpacingModes.contains(spacingMode) == false {
                    unsupportedConstraintUsages.insert("path/\(name):spacingMode=\(spacingMode)")
                }
                if supportedRotateModes.contains(rotateMode) == false {
                    unsupportedConstraintUsages.insert("path/\(name):rotateMode=\(rotateMode)")
                }
            }
        }

        if let constraints = root["physics"] as? [[String: Any]] {
            constraintKeys.insert("physics")
            for constraint in constraints {
                let name = namedConstraint(constraint)
                let rawName = (constraint["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let boneName = (constraint["bone"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if rawName.isEmpty || boneName.isEmpty {
                    unsupportedConstraintUsages.insert("physics/\(name):missing-name-or-bone")
                } else if boneNames.contains(boneName) == false {
                    unsupportedConstraintUsages.insert("physics/\(name):unknown-bone=\(boneName)")
                } else {
                    // Valid physics constraints are parsed and applied by the renderer, but only as a bounded subset.
                    degradedConstraintUsages.insert("physics/\(name):subset-runtime")
                }
            }
        } else if root["physics"] != nil {
            constraintKeys.insert("physics")
            unsupportedConstraintUsages.insert("physics:invalid-shape")
        }
    }

    private func boneNameSet(root: [String: Any]) -> Set<String> {
        guard let bones = root["bones"] as? [[String: Any]] else { return [] }
        return Set(bones.compactMap { bone in
            let name = (bone["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        })
    }

    private func slotNameSet(root: [String: Any]) -> Set<String> {
        guard let slots = root["slots"] as? [[String: Any]] else { return [] }
        return Set(slots.compactMap { slot in
            let name = (slot["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        })
    }

    private func hasPathAttachment(slotName: String, root: [String: Any]) -> Bool {
        let sources = skinAttachmentSources(root: root)
        guard let selectedSkin = sources.first(where: { $0.name == "default" }) ?? sources.first,
              let slotAttachments = selectedSkin.attachments[slotName] as? [String: Any] else {
            return false
        }
        return slotAttachments.values.contains { rawAttachment in
            guard let attachment = rawAttachment as? [String: Any] else { return false }
            return (attachment["type"] as? String)?.lowercased() == "path"
        }
    }

    private func namedConstraint(_ constraint: [String: Any]) -> String {
        let name = constraint["name"] as? String ?? "unnamed"
        return name.isEmpty ? "unnamed" : name
    }

    private func normalizedMode(_ value: Any?, default defaultValue: String) -> String {
        guard let value = value as? String, value.isEmpty == false else {
            return defaultValue
        }
        return value.lowercased()
    }

    private static func containedKeys(_ value: Any, keys: Set<String>) -> Set<String> {
        guard keys.isEmpty == false else { return [] }
        var found = Set<String>()
        collectContainedKeys(value, keys: keys, found: &found)
        return found
    }

    private static func collectContainedKeys(_ value: Any, keys: Set<String>, found: inout Set<String>) {
        guard found.count < keys.count else { return }

        if let dictionary = value as? NSDictionary {
            for rawKey in dictionary.keyEnumerator() {
                guard found.count < keys.count else { return }
                if let key = rawKey as? String, keys.contains(key) {
                    found.insert(key)
                }
                guard found.count < keys.count else { return }
                if let key = rawKey as? String, structuralKeyTraversalLeafKeys.contains(key) {
                    continue
                }
                if let child = dictionary.object(forKey: rawKey) {
                    collectContainedKeys(child, keys: keys, found: &found)
                }
            }
        } else if let array = value as? NSArray {
            for child in array {
                collectContainedKeys(child, keys: keys, found: &found)
                if found.count == keys.count {
                    return
                }
            }
        } else if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if keys.contains(key) {
                    found.insert(key)
                }
                if structuralKeyTraversalLeafKeys.contains(key) {
                    continue
                }
                collectContainedKeys(child, keys: keys, found: &found)
                if found.count == keys.count {
                    return
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectContainedKeys(child, keys: keys, found: &found)
                if found.count == keys.count {
                    return
                }
            }
        }
    }
}

private extension Set where Element == String {
    var listOrNone: String {
        isEmpty ? "none" : sorted().joined(separator: ",")
    }

    var compactListOrNone: String {
        guard isEmpty == false else { return "none" }
        let sortedValues = sorted()
        let maxVisibleItems = 8
        if sortedValues.count <= maxVisibleItems {
            return sortedValues.joined(separator: ",")
        }
        return sortedValues.prefix(maxVisibleItems).joined(separator: ",")
            + ",...(+\(sortedValues.count - maxVisibleItems) more)"
    }
}

private extension Array where Element == String {
    var compactListOrNone: String {
        guard isEmpty == false else { return "none" }
        let maxVisibleItems = 8
        if count <= maxVisibleItems {
            return joined(separator: "; ")
        }
        return prefix(maxVisibleItems).joined(separator: "; ")
            + "; ...(+\(count - maxVisibleItems) more)"
    }

    var uniquePreservingOrder: [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
