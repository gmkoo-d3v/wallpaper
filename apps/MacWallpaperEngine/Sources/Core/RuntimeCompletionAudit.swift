import Foundation

private struct CompletionAuditRow {
    let category: String
    let status: String
    let id: String
    let evidence: String
    let risk: String

    var line: String {
        [category, status, id, evidence, risk].map(Self.safeField).joined(separator: "\t")
    }

    var isPassingAutomatedEvidence: Bool {
        category == "automated" && status == "pass"
    }

    var isOpenManualEvidence: Bool {
        category == "manual" && status == "manual"
    }

    private static func safeField(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

private struct ManualSmokeEvidenceFile: Codable {
    let schemaVersion: String?
    let packagedAppLaunchSmoke: ManualSmokeEvidenceEntry?
    let liveDesktopClickActions: ManualSmokeEvidenceEntry?
    let physicalDisplayHotplugSmoke: ManualSmokeEvidenceEntry?
    let blackFrameFlickerSmoke: ManualSmokeEvidenceEntry?
}

private struct ManualSmokeEvidenceEntry: Codable {
    let passed: Bool
    let evidence: String
    let recordedAt: String?
    let operatorNote: String?
    let protocolText: String?

    var normalizedEvidence: String {
        var parts: [String] = []
        if let recordedAt, recordedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            parts.append("recordedAt=\(recordedAt)")
        }
        parts.append(evidence.trimmingCharacters(in: .whitespacesAndNewlines))
        if let operatorNote, operatorNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            parts.append("note=\(operatorNote)")
        }
        return parts.joined(separator: "; ")
    }
}

enum RuntimeCompletionAudit {
    static let manualSmokeEvidenceSchemaVersion = "mac-wallpaper-manual-smoke.v1"

    private static func isNativeSpinePlayable(_ capabilities: WallpaperBundleCapabilityInfo) -> Bool {
        if capabilities.nativeSpineStatus == "supported" { return true }
        guard capabilities.nativeSpineStatus == "degraded",
              capabilities.nativeSpineDegradations.isEmpty == false else {
            return false
        }
        return capabilities.nativeSpineDegradations.allSatisfy(isPlayableNativeSpineDegradation)
    }

    private static func isPlayableNativeSpineDegradation(_ degradation: String) -> Bool {
        degradation.hasPrefix("physics/") && degradation.hasSuffix(":subset-runtime")
    }

    static func make(
        projectRoot: URL?,
        strictCompositeQuality: Bool,
        includeInvalid: Bool,
        bundleDirectories: [URL]? = nil,
        manualEvidenceURL: URL? = nil
    ) throws -> String {
        let manualEvidence = try loadManualEvidence(from: manualEvidenceURL)
        let diagnostics = bundleDirectories.map(WallpaperBundleCatalog.diagnose(in:))
            ?? WallpaperBundleCatalog.diagnoseDefaultBundles(projectRoot: projectRoot)
        let bundles = diagnostics.compactMap(\.bundle)
        let invalidDiagnostics = diagnostics.filter { $0.status == .invalid }
        guard bundles.isEmpty == false else {
            throw EngineError.invalidArgument("No valid wallpaper bundles found for completion audit.")
        }

        let manifestSchema = try ManifestSchemaResource.loadJSON(projectRoot: projectRoot)
        let validationMatrix = try BundleValidationMatrix.make(
            projectRoot: projectRoot,
            strictCompositeQuality: strictCompositeQuality,
            includeInvalid: includeInvalid,
            bundleDirectories: bundleDirectories
        )

        let assetFamilies = Set(bundles.flatMap { $0.capabilities.assetKinds })
        let layerFamilies = Set(bundles.flatMap { $0.capabilities.layerKinds })
        let interactionFamilies = Set(bundles.flatMap { $0.capabilities.interactionKinds })
        let effectFamilies = Set(bundles.flatMap { bundle in
            bundle.capabilities.effectKinds.filter { $0 != "none" }
        })
        let interactiveSpineBundles = bundles.filter {
            isNativeSpinePlayable($0.capabilities)
                && $0.capabilities.interactionKinds.contains("pointerMove")
                && $0.capabilities.interactionKinds.contains("pointerDown")
        }
        let hasVideoOnly = bundles.contains {
            $0.capabilities.assetKinds.contains("video")
                && $0.capabilities.assetKinds.contains("spine") == false
        }
        let hasStatic = bundles.contains { $0.capabilities.assetKinds.contains("static") }
        let hasWhitelistEffectFixture = effectFamilies.isSuperset(of: [
            "blur",
            "chromaticAberration",
            "colorMatrix",
            "scroll"
        ])
        let hasDisplayModes = validationMatrix.contains("displayModes: selectedOnly+selectedPolicy+allFull")
        let hasDisplayRefresh = validationMatrix.contains("displayRefreshFps: primary120+secondary60")
        let hasPerformancePlan = validationMatrix.contains("performancePlan: target=")
        let hasGolden = validationMatrix.contains("golden: pass")
        let hasInstaller = validationMatrix.contains("installer: importable")
        let nativeDefaultFallback = try nativeDefaultFallbackEvidence(bundles: bundles)
        let unsupportedSpineFallback = try unsupportedSpineFallbackEvidence(bundles: bundles)
        let unsupportedSpineFallbackTaxonomy = unsupportedSpineFallbackTaxonomyEvidence(bundles: bundles)
        let wallpaperBundleContract = wallpaperBundleContractEvidence(
            bundles: bundles,
            validationMatrix: validationMatrix
        )
        let genericPlayerContract = genericPlayerContractEvidence(bundles: bundles)
        let declarativeContract = declarativeBindingContractEvidence(
            bundles: bundles,
            manifestSchema: manifestSchema
        )
        let whitelistEffectContract = whitelistEffectContractEvidence(
            bundles: bundles,
            manifestSchema: manifestSchema
        )
        let declarativeSafetyBoundary = declarativeSafetyBoundaryEvidence(manifestSchema: manifestSchema)
        let genericSourceBoundary = try genericRuntimeSourceBoundaryEvidence(
            projectRoot: projectRoot,
            bundles: bundles
        )
        let sourceDerivation = sourceDerivationEvidence(bundles: bundles)
        let packaged = packageRuntimeMetadataText() != nil
        let packagedEvidence = manualEvidence?.packagedAppLaunchSmoke
        let liveClickEvidence = manualEvidence?.liveDesktopClickActions
        let physicalDisplayEvidence = manualEvidence?.physicalDisplayHotplugSmoke
        let blackFrameFlickerEvidence = manualEvidence?.blackFrameFlickerSmoke
        let liveInteractionProtocol = liveClickProtocolText(bundles: interactiveSpineBundles)
        let physicalDisplayProtocol = physicalDisplayHotplugProtocolText()
        let blackFrameFlickerProtocol = currentBlackFrameFlickerProtocolText()

        let automatedItems = [
            item(
                id: "bundle-discovery-library",
                passed: invalidDiagnostics.isEmpty && bundles.isEmpty == false,
                evidence: "validBundles=\(bundles.count) invalidDiagnostics=\(invalidDiagnostics.count)",
                risk: invalidDiagnostics.isEmpty ? "none" : "invalid bundle diagnostics present"
            ),
            item(
                id: "manifest-schema-preflight",
                passed: true,
                evidence: "wallpaper-native-v2 schema loaded; BundleValidationMatrix completed",
                risk: "none"
            ),
            item(
                id: "wallpaper-bundle-contract",
                passed: wallpaperBundleContract.passed,
                evidence: wallpaperBundleContract.evidence,
                risk: "wallpaper-specific placement, hit zones, action names, timing, and neutral points must stay in the manifest/source-adapter bundle contract, not the generic runtime"
            ),
            item(
                id: "generic-player-contract",
                passed: genericPlayerContract.passed,
                evidence: genericPlayerContract.evidence,
                risk: "the runtime must interpret bundle-declared assets, layers, interactions, hit zones, timings, and action names instead of owning wallpaper-specific behavior"
            ),
            item(
                id: "declarative-binding-contract",
                passed: declarativeContract.passed,
                evidence: declarativeContract.evidence,
                risk: "script-like behavior must remain manifest-declared data with safe sources, engine-owned targets, and whitelisted adapters"
            ),
            item(
                id: "whitelist-effect-contract",
                passed: whitelistEffectContract.passed,
                evidence: whitelistEffectContract.evidence,
                risk: "effects must remain engine-owned descriptors without dynamic shader loading or arbitrary code execution"
            ),
            item(
                id: "declarative-safety-boundary",
                passed: declarativeSafetyBoundary.passed,
                evidence: declarativeSafetyBoundary.evidence,
                risk: "declarative script/effect compatibility must not open executable layers, dynamic shaders, command/file/network sources, or non-engine targets"
            ),
            item(
                id: "generic-runtime-source-boundary",
                passed: genericSourceBoundary.passed,
                evidence: genericSourceBoundary.evidence,
                risk: "wallpaper ids, titles, and non-generic action tokens must stay in wallpaper bundles, source adapters, tests, or docs instead of the generic runtime"
            ),
            item(
                id: "renderer-family-coverage",
                passed: assetFamilies.isSuperset(of: ["static", "video", "spine"])
                    && layerFamilies.isSuperset(of: ["static_image", "video", "spine"])
                    && hasVideoOnly
                    && hasStatic
                    && hasWhitelistEffectFixture
                    && interactiveSpineBundles.isEmpty == false,
                evidence: "assets=\(assetFamilies.sorted().joined(separator: "+")) layers=\(layerFamilies.sorted().joined(separator: "+")) effects=\(effectFamilies.sorted().joined(separator: "+")) interactiveSpine=\(interactiveSpineBundles.count)",
                risk: "needs static, video-only, interactive native-Spine, and whitelist effect fixtures"
            ),
            item(
                id: "native-spine-default-fallback",
                passed: nativeDefaultFallback.passed,
                evidence: nativeDefaultFallback.evidence,
                risk: "Native-supported interactive wallpapers must not silently default to the lower-quality composite fallback"
            ),
            item(
                id: "unsupported-spine-composite-fallback",
                passed: unsupportedSpineFallback.passed,
                evidence: unsupportedSpineFallback.evidence,
                risk: "Unsupported Spine features must fail safely through explicit compatibility diagnostics and a declared compositeVideo fallback"
            ),
            item(
                id: "unsupported-spine-fallback-taxonomy",
                passed: unsupportedSpineFallbackTaxonomy.passed,
                evidence: unsupportedSpineFallbackTaxonomy.evidence,
                risk: "Unsupported native-Spine fallback cases must preserve the reason taxonomy so invalid fixture data, nonstandard blend modes, and missing renderer slices are not collapsed into one vague failure"
            ),
            item(
                id: "interaction-compatibility",
                passed: interactionFamilies.contains("pointerMove")
                    && interactionFamilies.contains("pointerDown")
                    && validationMatrix.contains("interactionPlan: active"),
                evidence: "interactions=\(interactionFamilies.sorted().joined(separator: "+")) desktop-empty gate validated",
                risk: "manual desktop click delivery still needs live observation; no macOS Accessibility grant is part of the product path"
            ),
            item(
                id: "multi-display-lifecycle",
                passed: hasDisplayModes && hasDisplayRefresh,
                evidence: "selectedOnly+selectedPolicy+allFull and primary120+secondary60 simulated plans validated",
                risk: "manual hot-plug/physical monitor smoke still required before declaring final product completeness"
            ),
            item(
                id: "performance-budget",
                passed: hasPerformancePlan,
                evidence: "manifest CPU/RSS/FPS performance plan validated for discovered bundles",
                risk: "profiler-backed native Spine optimization remains an ongoing hardening target"
            ),
            item(
                id: "golden-render-fixtures",
                passed: hasGolden,
                evidence: hasGolden ? "bundle-local golden fixtures passed" : "no golden fixture pass found",
                risk: "renderer regressions need bundle-local fixture coverage"
            ),
            item(
                id: "bundle-import-packaging-path",
                passed: hasInstaller,
                evidence: "bundle installer round-trip covered by validation matrix",
                risk: "none"
            )
        ]

        let manualItems = [
            manualItem(
                id: "packaged-app-launch-smoke",
                passed: manualEvidencePassed(packagedEvidence, fallback: packaged),
                evidence: manualEvidenceText(
                    packagedEvidence,
                    fallback: packaged
                        ? "package-runtime metadata present for \(Bundle.main.bundlePath)"
                        : "source/unpackaged run; package script smoke must be checked separately"
                )
            ),
            manualItem(
                id: "live-desktop-click-actions",
                passed: manualEvidencePassed(
                    liveClickEvidence,
                    fallback: false,
                    requiredProtocolText: liveInteractionProtocol
                ),
                evidence: manualEvidenceText(
                    liveClickEvidence,
                    fallback: "no-permission input policy; manual live smoke still required: \(liveInteractionProtocol)",
                    requiredProtocolText: liveInteractionProtocol
                )
            ),
            manualItem(
                id: "physical-display-hotplug-smoke",
                passed: manualEvidencePassed(
                    physicalDisplayEvidence,
                    fallback: false,
                    requiredProtocolText: physicalDisplayProtocol
                ),
                evidence: manualEvidenceText(
                    physicalDisplayEvidence,
                    fallback: "simulated display matrix passed; physical reconnect/hot-plug smoke evidence is not recorded in this CLI run",
                    requiredProtocolText: physicalDisplayProtocol
                )
            ),
            manualItem(
                id: "black-frame-flicker-smoke",
                passed: manualEvidencePassed(
                    blackFrameFlickerEvidence,
                    fallback: false,
                    requiredProtocolText: blackFrameFlickerProtocol
                ),
                evidence: manualEvidenceText(
                    blackFrameFlickerEvidence,
                    fallback: "renderer warmup/rebuild guards are covered by automated tests, but live no-black-frame/no-flicker observation is not recorded",
                    requiredProtocolText: blackFrameFlickerProtocol
                )
            )
        ]
        let protocolItems = [
            protocolItem(
                id: "live-desktop-click-actions-protocol",
                evidence: "launch packaged app; do not grant Accessibility; enable click actions; expected \(liveInteractionProtocol)"
            ),
            protocolItem(
                id: "physical-display-hotplug-smoke-protocol",
                evidence: physicalDisplayProtocol
            ),
            protocolItem(
                id: "black-frame-flicker-smoke-protocol",
                evidence: blackFrameFlickerProtocol
            )
        ]
        let scopeItems = [
            scopeItem(
                id: "full-source-behavior-import",
                evidence: sourceDerivation
            ),
            scopeItem(
                id: "full-spine-4.2-parity",
                evidence: "deferred by current scope; unsupported Spine feature classes are compatibility-gated and require composite fallback"
            )
        ]

        let automatedPassed = automatedItems.allSatisfy(\.isPassingAutomatedEvidence)
        let manualOpen = manualItems.contains(where: \.isOpenManualEvidence)
        let overall = automatedPassed
            ? (manualOpen ? "automated-pass/manual-evidence-open" : "complete-evidence-pass")
            : "incomplete"

        return """
        wallpaper completion audit
        overall: \(overall)
        validBundles: \(bundles.count)
        invalidDiagnostics: \(invalidDiagnostics.count)
        strictCompositeQuality: \(strictCompositeQuality)
        columns: category\tstatus\tid\tevidence\trisk
        \((automatedItems + manualItems + protocolItems + scopeItems).map(\.line).joined(separator: "\n"))
        """
    }

    static func writeManualSmokeEvidenceTemplate(to destination: URL) throws -> String {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let template = ManualSmokeEvidenceFile(
            schemaVersion: manualSmokeEvidenceSchemaVersion,
            packagedAppLaunchSmoke: templatePackagedLaunchEntry(),
            liveDesktopClickActions: templateLiveClickEntry(protocolText: try currentLiveClickProtocolText()),
            physicalDisplayHotplugSmoke: templatePhysicalDisplayEntry(
                protocolText: physicalDisplayHotplugProtocolText()
            ),
            blackFrameFlickerSmoke: templateBlackFrameFlickerEntry(
                protocolText: currentBlackFrameFlickerProtocolText()
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(template).write(to: destination, options: .atomic)
        return """
        manual smoke evidence template OK
        schemaVersion: \(manualSmokeEvidenceSchemaVersion)
        path: \(destination.path)
        next: fill every passed=false field with real smoke results, then run --completion-audit --manual-smoke-evidence \(destination.path)
        """
    }

    static func recordManualSmokeEvidence(
        to destination: URL,
        packagedLaunchPassed: Bool,
        liveClickActionsPassed: Bool,
        physicalDisplayHotplugPassed: Bool,
        blackFrameFlickerPassed: Bool,
        liveClickActionsNote: String? = nil,
        physicalDisplayHotplugEvent: String? = nil,
        physicalDisplayHotplugNote: String? = nil
    ) throws -> String {
        guard packagedLaunchPassed || liveClickActionsPassed || physicalDisplayHotplugPassed || blackFrameFlickerPassed else {
            throw EngineError.invalidArgument(
                "At least one manual smoke confirmation flag is required: --confirm-packaged-launch, --confirm-live-click-actions, --confirm-physical-display-hotplug, or --confirm-black-frame-flicker"
            )
        }
        let normalizedLiveClickActionsNote = liveClickActionsNote?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if liveClickActionsPassed && (normalizedLiveClickActionsNote?.isEmpty ?? true) {
            throw EngineError.invalidArgument(
                "--confirm-live-click-actions requires --live-click-actions-note <observed tap, hold, rub, empty-click, and gaze behavior>"
            )
        }
        let normalizedPhysicalDisplayHotplugNote = physicalDisplayHotplugNote?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if physicalDisplayHotplugPassed && (normalizedPhysicalDisplayHotplugNote?.isEmpty ?? true) {
            throw EngineError.invalidArgument(
                "--confirm-physical-display-hotplug requires --physical-display-hotplug-note <observed display event and restored displays>"
            )
        }
        let normalizedPhysicalDisplayHotplugEvent = try normalizePhysicalDisplayHotplugEvent(
            physicalDisplayHotplugEvent,
            note: normalizedPhysicalDisplayHotplugNote,
            required: physicalDisplayHotplugPassed
        )

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let existing = try loadExistingManualEvidence(from: destination)
        let recordedAt = ISO8601DateFormatter().string(from: Date())
        let liveInteractionProtocol = try currentLiveClickProtocolText()
        let physicalDisplayProtocol = physicalDisplayHotplugProtocolText()
        let blackFrameFlickerProtocol = currentBlackFrameFlickerProtocolText()
        let updated = ManualSmokeEvidenceFile(
            schemaVersion: manualSmokeEvidenceSchemaVersion,
            packagedAppLaunchSmoke: packagedLaunchPassed
                ? passEntry(
                    recordedAt: recordedAt,
                    evidence: "Operator confirmed packaged app launch from Finder or package smoke gate stayed alive without crash."
                )
                : existing?.packagedAppLaunchSmoke ?? templatePackagedLaunchEntry(),
            liveDesktopClickActions: liveClickActionsPassed
                ? passEntry(
                    recordedAt: recordedAt,
                    evidence: "Operator confirmed live click/gaze interactions against the selected wallpaper manifest-declared pointerMove and pointerDown actions. Protocol: \(liveInteractionProtocol)",
                    operatorNote: normalizedLiveClickActionsNote,
                    protocolText: liveInteractionProtocol
                )
                : existing?.liveDesktopClickActions ?? templateLiveClickEntry(protocolText: liveInteractionProtocol),
            physicalDisplayHotplugSmoke: physicalDisplayHotplugPassed
                ? passEntry(
                    recordedAt: recordedAt,
                    evidence: "Operator confirmed physical display smoke: selectedOnly primary-only, selectedPolicy secondary-passive, allFull all-displays, \(normalizedPhysicalDisplayHotplugEvent ?? "wake") restored wallpaper windows on target displays. Protocol: \(physicalDisplayProtocol)",
                    operatorNote: normalizedPhysicalDisplayHotplugNote,
                    protocolText: physicalDisplayProtocol
                )
                : existing?.physicalDisplayHotplugSmoke ?? templatePhysicalDisplayEntry(protocolText: physicalDisplayProtocol),
            blackFrameFlickerSmoke: blackFrameFlickerPassed
                ? passEntry(
                    recordedAt: recordedAt,
                    evidence: "Operator confirmed black-frame/flicker smoke: packaged app start, mode switch, display rebuild or wake produced no black frame, no visible flicker loop, and no crash. Protocol: \(blackFrameFlickerProtocol)",
                    protocolText: blackFrameFlickerProtocol
                )
                : existing?.blackFrameFlickerSmoke ?? templateBlackFrameFlickerEntry(protocolText: blackFrameFlickerProtocol)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: destination, options: .atomic)

        _ = try loadManualEvidence(from: destination)

        let confirmed = [
            packagedLaunchPassed ? "packaged-app-launch-smoke" : nil,
            liveClickActionsPassed ? "live-desktop-click-actions" : nil,
            physicalDisplayHotplugPassed ? "physical-display-hotplug-smoke" : nil,
            blackFrameFlickerPassed ? "black-frame-flicker-smoke" : nil
        ].compactMap { $0 }.joined(separator: ", ")

        return """
        manual smoke evidence record OK
        schemaVersion: \(manualSmokeEvidenceSchemaVersion)
        path: \(destination.path)
        confirmed: \(confirmed)
        next: run --completion-audit --manual-smoke-evidence \(destination.path)
        """
    }

    private static func normalizePhysicalDisplayHotplugEvent(
        _ event: String?,
        note: String?,
        required: Bool
    ) throws -> String? {
        guard required else { return nil }
        let normalized = event?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized, normalized.isEmpty == false else {
            throw EngineError.invalidArgument(
                "--confirm-physical-display-hotplug requires --physical-display-hotplug-event wake|reconnect"
            )
        }
        guard ["wake", "reconnect"].contains(normalized) else {
            throw EngineError.invalidArgument(
                "--physical-display-hotplug-event must be wake or reconnect"
            )
        }
        let foldedNote = note?.lowercased() ?? ""
        guard foldedNote.contains(normalized) else {
            throw EngineError.invalidArgument(
                "--physical-display-hotplug-note must mention the selected \(normalized) event"
            )
        }
        let missingModeTokens = ["selectedonly", "selectedpolicy", "allfull"].filter {
            foldedNote.contains($0) == false
        }
        guard missingModeTokens.isEmpty else {
            throw EngineError.invalidArgument(
                "--physical-display-hotplug-note must mention checked display mode token(s): \(missingModeTokens.joined(separator: ", "))"
            )
        }
        guard foldedNote.contains("restore") || foldedNote.contains("restored") else {
            throw EngineError.invalidArgument(
                "--physical-display-hotplug-note must mention restored wallpaper windows after \(normalized)"
            )
        }
        return normalized
    }

    private static func item(id: String, passed: Bool, evidence: String, risk: String) -> CompletionAuditRow {
        CompletionAuditRow(
            category: "automated",
            status: passed ? "pass" : "fail",
            id: id,
            evidence: evidence,
            risk: passed ? "none" : risk
        )
    }

    private static func manualItem(id: String, passed: Bool, evidence: String) -> CompletionAuditRow {
        CompletionAuditRow(
            category: "manual",
            status: passed ? "pass" : "manual",
            id: id,
            evidence: evidence,
            risk: passed ? "none" : "manual verification required"
        )
    }

    private static func nativeDefaultFallbackEvidence(
        bundles: [WallpaperBundleSummary]
    ) throws -> (passed: Bool, evidence: String) {
        let candidates = bundles.filter {
            isNativeSpinePlayable($0.capabilities)
                && $0.capabilities.assetKinds.contains("spine")
                && $0.capabilities.assetKinds.contains("composite")
        }
        guard candidates.isEmpty == false else {
            return (false, "no supported native-Spine bundle with composite fallback found")
        }

        var failures: [String] = []
        var evidence: [String] = []
        for bundle in candidates {
            let config = try EngineConfig.parse([
                "--wallpaper-root", bundle.root.path,
                "--manifest", bundle.manifestURL.path,
                "--foreground-mode", ForegroundRenderMode.automatic.rawValue,
                "--display-mode", DisplayMode.primaryOnly.cliName,
                "--render-plan"
            ])
            let runtime = try NativeRuntimeCore(config: config)
            let renderSummary = DisplayPlanner.headlessRenderSummary(runtime: runtime)
            let quality = runtime.compositeQualityReport()
            let usesNativeSpine = renderSummary.contains("foreground=nativeSpine(auto)")
            let usesCompositeAsDefault = renderSummary.contains("foreground=compositeVideo(auto)")
                || renderSummary.contains("background=compositeVideo:")
            let fpsFallbackOnly = renderSummary.contains("fallback=resourceBudget->fpsOnly")
                || renderSummary.contains("fallback=none")
            if usesNativeSpine == false || usesCompositeAsDefault || fpsFallbackOnly == false {
                failures.append(
                    "\(bundle.id) auto render path is not native-first: \(oneLine(renderSummary))"
                )
            }
            evidence.append(
                "\(bundle.id)=autoNative:\(usesNativeSpine) compositeDefault:\(usesCompositeAsDefault) fallback:\(fpsFallbackOnly ? "fps-only" : "unexpected") compositeQuality:\(quality.summaryLine)"
            )
        }

        return (
            failures.isEmpty,
            failures.isEmpty ? evidence.joined(separator: "; ") : failures.joined(separator: "; ")
        )
    }

    private static func unsupportedSpineFallbackTaxonomyEvidence(
        bundles: [WallpaperBundleSummary]
    ) -> (passed: Bool, evidence: String) {
        let candidates = bundles.filter {
            $0.capabilities.nativeSpineStatus == "unsupported"
                && $0.capabilities.fallbackStatus == "composite"
                && $0.capabilities.assetKinds.contains("spine")
                && $0.capabilities.assetKinds.contains("composite")
        }
        guard candidates.isEmpty == false else {
            return (false, "no unsupported native-Spine fallback candidate found")
        }

        var evidence: [String] = []
        var allClassified = true
        for bundle in candidates {
            let reasonText = bundle.capabilities.nativeSpineReasons.joined(separator: "; ")
            let classes = unsupportedSpineReasonClasses(reasonText: reasonText)
            let classText = classes.isEmpty ? "unclassified" : classes.sorted().joined(separator: "+")
            if classes.isEmpty {
                allClassified = false
            }
            evidence.append(
                "\(bundle.id)=classes(\(classText)) reasons(\(oneLine(reasonText)))"
            )
        }

        return (
            allClassified,
            evidence.joined(separator: "; ")
        )
    }

    private static func unsupportedSpineReasonClasses(reasonText: String) -> Set<String> {
        var classes = Set<String>()
        if reasonText.contains("unsupported attachment types") {
            classes.insert("attachment-type")
        }
        if reasonText.contains("unsupported blend modes") {
            classes.insert("blend-mode")
        }
        if reasonText.contains("unsupported timeline keys") {
            classes.insert("timeline")
        }
        if reasonText.contains("multi-bone") {
            classes.insert("renderer-slice")
        }
        if reasonText.contains("missing-target")
            || reasonText.contains("missing-target-slot")
            || reasonText.contains("target-slot-without-path-attachment")
            || reasonText.contains("unknown-target")
            || reasonText.contains("unknown-bone") {
            classes.insert("invalid-reference")
        }
        return classes
    }

    private static func unsupportedSpineFallbackEvidence(
        bundles: [WallpaperBundleSummary]
    ) throws -> (passed: Bool, evidence: String) {
        let candidates = bundles.filter {
            $0.capabilities.nativeSpineStatus == "unsupported"
                && $0.capabilities.fallbackStatus == "composite"
                && $0.capabilities.assetKinds.contains("spine")
                && $0.capabilities.assetKinds.contains("composite")
        }
        guard candidates.isEmpty == false else {
            return (false, "no unsupported native-Spine bundle with composite fallback found")
        }

        var failures: [String] = []
        var evidence: [String] = []
        for bundle in candidates {
            let config = try EngineConfig.parse([
                "--wallpaper-root", bundle.root.path,
                "--manifest", bundle.manifestURL.path,
                "--foreground-mode", ForegroundRenderMode.automatic.rawValue,
                "--display-mode", DisplayMode.primaryOnly.cliName,
                "--render-plan"
            ])
            let runtime = try NativeRuntimeCore(config: config)
            let renderSummary = DisplayPlanner.headlessRenderSummary(runtime: runtime)
            let usesCompositeFallback = renderSummary.contains("foreground=compositeVideo(auto)")
                && renderSummary.contains("fallback=auto->compositeVideo")
            let reportsUnsupported = renderSummary.contains("nativeCompatibility: unsupported")
            if usesCompositeFallback == false || reportsUnsupported == false {
                failures.append(
                    "\(bundle.id) unsupported native Spine did not select composite fallback: \(oneLine(renderSummary))"
                )
            }
            evidence.append(
                "\(bundle.id)=nativeUnsupported:true fallback:composite autoComposite:\(usesCompositeFallback) diagnostics:\(reportsUnsupported)"
            )
        }

        return (
            failures.isEmpty,
            failures.isEmpty ? evidence.joined(separator: "; ") : failures.joined(separator: "; ")
        )
    }

    private static func wallpaperBundleContractEvidence(
        bundles: [WallpaperBundleSummary],
        validationMatrix: String
    ) -> (passed: Bool, evidence: String) {
        let bundleSummaries = bundles.map {
            "\($0.id)=source(\($0.capabilities.sourceSummary)); derivation(\($0.capabilities.sourceDerivationSummary))"
        }
        let unknownBundles = bundles.filter {
            $0.capabilities.sourceSummary == "unspecified"
                || $0.capabilities.sourceDerivationSummary.hasPrefix("unknown")
        }
        let partialBundles = bundles.filter {
            $0.capabilities.sourceDerivationSummary.hasPrefix("partial")
        }
        let partialBundlesHaveExplicitBlockers = partialBundles.allSatisfy {
            $0.capabilities.sourceDerivationSummary.contains("blockers=")
        }
        let partialSourceProvenanceChecked = partialBundles.isEmpty
            || validationMatrix.contains("sourceProvenance: pass")
            || validationMatrix.contains("sourceProvenance: warn")
        return (
            unknownBundles.isEmpty && partialBundlesHaveExplicitBlockers && partialSourceProvenanceChecked,
            bundleSummaries.joined(separator: "; ")
        )
    }

    private static func sourceDerivationEvidence(
        bundles: [WallpaperBundleSummary]
    ) -> String {
        let bundleSummaries = bundles.map {
            "\($0.id)=\($0.capabilities.sourceDerivationSummary)"
        }
        return bundleSummaries.joined(separator: "; ")
    }

    private static func genericPlayerContractEvidence(
        bundles: [WallpaperBundleSummary]
    ) -> (passed: Bool, evidence: String) {
        var passed = true
        let bundleSummaries = bundles.map { bundle -> String in
            do {
                let manifest = try ManifestLoader.load(url: bundle.manifestURL, bundleRoot: bundle.root)
                let declaredAssetIds = Set(declaredAssetIDs(manifest))
                let layerRefs = Set(manifest.layers.map(\.asset))
                let missingLayerRefs = layerRefs.subtracting(declaredAssetIds).sorted()
                let bindingTriggeredActions = DeclarativeBindingPlan(manifest: manifest)
                    .triggerPlayBindings
                    .map(\.target.id)
                let actionNames = Set(referencedInteractionActions(in: manifest.interactions) + bindingTriggeredActions)
                    .sorted()
                let interactionText = interactionOwnershipText(manifest)
                var checks: [String] = []
                if manifest.layers.isEmpty {
                    checks.append("no-layers")
                }
                if missingLayerRefs.isEmpty == false {
                    checks.append("missing-layer-assets=\(missingLayerRefs.joined(separator: ","))")
                }
                if manifest.interactions.isEmpty == false, manifest.assets.spine == nil {
                    checks.append("interactive-without-spine")
                }
                if checks.isEmpty == false {
                    passed = false
                }
                let status = checks.isEmpty ? "manifest-owned" : "invalid(\(checks.joined(separator: "+")))"
                return "\(bundle.id)=\(status) assets[\(declaredAssetIds.sorted().joined(separator: "+"))] layers[\(manifest.layers.map { "\($0.id):\($0.type.rawValue)->\($0.asset)" }.joined(separator: ","))] interactions[\(interactionText)] actions[\(actionNames.isEmpty ? "none" : actionNames.joined(separator: "+"))]"
            } catch {
                passed = false
                return "\(bundle.id)=invalid(\(oneLine(String(describing: error))))"
            }
        }
        return (passed, bundleSummaries.joined(separator: "; "))
    }

    private static func declarativeBindingContractEvidence(
        bundles: [WallpaperBundleSummary],
        manifestSchema: [String: Any]
    ) -> (passed: Bool, evidence: String) {
        let schemaOK = schemaHasDefinitions(
            manifestSchema,
            propertyNames: ["bindings"],
            definitionNames: ["declarativeBinding", "bindingAdapter"]
        )
        let bindingKinds = Set(bundles.flatMap(\.capabilities.bindingKinds))
        var hasPointerDownEffectBinding = false
        var hasTriggerPlayBinding = false
        var hasSpringEffectBinding = false
        var hasSpringBoneBinding = false
        var hasSmoothLookAtBoneBinding = false
        let bundleEvidence = bundles.map { bundle in
            let planSummary: String
            do {
                let manifest = try ManifestLoader.load(url: bundle.manifestURL, bundleRoot: bundle.root)
                let plan = DeclarativeBindingPlan(manifest: manifest)
                let entries = plan.bindingEntries.map(\.summary)
                for entry in plan.bindingEntries where entry.runtimeStatus == .runtimeExecutable {
                    if entry.source == .pointerDown,
                       entry.target.kind == .effect,
                       entry.adapter.type == .mapRange {
                        hasPointerDownEffectBinding = true
                    }
                    if entry.source == .pointerDown,
                       entry.target.kind == .spineAnimation,
                       entry.adapter.type == .triggerPlay {
                        hasTriggerPlayBinding = true
                    }
                    if entry.target.kind == .effect,
                       entry.adapter.type == .spring {
                        hasSpringEffectBinding = true
                    }
                    if entry.source == .pointerPosition,
                       entry.target.kind == .spineBone,
                       entry.adapter.type == .spring {
                        hasSpringBoneBinding = true
                    }
                    if entry.source == .pointerPosition,
                       entry.target.kind == .spineBone,
                       entry.adapter.type == .smoothLookAt {
                        hasSmoothLookAtBoneBinding = true
                    }
                }
                planSummary = entries.isEmpty ? "none" : entries.joined(separator: ",")
            } catch {
                planSummary = "invalid(\(oneLine(String(describing: error))))"
            }
            return "\(bundle.id)=bindings(\(bundle.capabilities.bindingKinds.joined(separator: "+"))) entries[\(planSummary)]"
        }.joined(separator: "; ")
        let requiredRuntimeAdapters = [
            hasSmoothLookAtBoneBinding ? "smooth-lookat:ok" : "smooth-lookat:missing",
            hasTriggerPlayBinding ? "trigger-play:ok" : "trigger-play:missing",
            hasPointerDownEffectBinding ? "map-range:pointer-down-effect:ok" : "map-range:pointer-down-effect:missing",
            hasSpringEffectBinding ? "spring:effect:ok" : "spring:effect:missing",
            hasSpringBoneBinding ? "spring:spine-bone:ok" : "spring:spine-bone:missing"
        ].joined(separator: "+")
        return (
            schemaOK
                && hasPointerDownEffectBinding
                && hasTriggerPlayBinding
                && hasSpringEffectBinding
                && hasSpringBoneBinding
                && hasSmoothLookAtBoneBinding,
            "schema=\(schemaOK ? "declared" : "missing") sources=pointer.position+pointer.down+system.time+thermal.state targets=spine.bone+spine.animation+effect adapters=smooth-lookat(runtime-bone-rotation)+trigger-play(runtime-executable)+map-range(runtime-evaluable)+spring(effect-runtime+pointer-spine-runtime,explicit-dynamics-contract) requiredRuntimeAdapters=\(requiredRuntimeAdapters); \(bundleEvidence); discovered=\(bindingKinds.sorted().joined(separator: "+"))"
        )
    }

    private static func whitelistEffectContractEvidence(
        bundles: [WallpaperBundleSummary],
        manifestSchema: [String: Any]
    ) -> (passed: Bool, evidence: String) {
        let schemaOK = schemaHasDefinitions(
            manifestSchema,
            propertyNames: ["effects"],
            definitionNames: ["effect"]
        )
        let effectKinds = Set(bundles.flatMap(\.capabilities.effectKinds))
        let requiredEffects: Set<String> = [
            EffectType.blur.rawValue,
            EffectType.colorMatrix.rawValue,
            EffectType.scroll.rawValue,
            EffectType.chromaticAberration.rawValue
        ]
        var runtimeRenderedEffects = Set<String>()
        var bundleEvidenceParts: [String] = []
        for bundle in bundles {
            let effectSummary: String
            do {
                let manifest = try ManifestLoader.load(url: bundle.manifestURL, bundleRoot: bundle.root)
                let plan = DeclarativeBindingPlan(manifest: manifest)
                for entry in plan.effectEntries where entry.runtimeStatus == .runtimeRendered {
                    runtimeRenderedEffects.insert(entry.effectKind)
                }
                let entries = plan.effectEntries.map(\.summary)
                effectSummary = entries.isEmpty ? "none" : entries.joined(separator: ",")
            } catch {
                effectSummary = "invalid(\(oneLine(String(describing: error))))"
            }
            bundleEvidenceParts.append(
                "\(bundle.id)=effects(\(bundle.capabilities.effectKinds.joined(separator: "+"))) entries[\(effectSummary)]"
            )
        }
        let missingRequiredEffects = requiredEffects.subtracting(runtimeRenderedEffects).sorted()
        let requiredEffectStatus = requiredEffects.sorted().map {
            runtimeRenderedEffects.contains($0) ? "\($0):ok" : "\($0):missing"
        }.joined(separator: "+")
        return (
            schemaOK && missingRequiredEffects.isEmpty,
            "schema=\(schemaOK ? "declared" : "missing") whitelist=blur(runtime-rendered)+colorMatrix(runtime-rendered)+scroll(runtime-rendered)+chromaticAberration(runtime-rendered) requiredWhitelistEffects=\(requiredEffectStatus) dynamicShaderLoading=forbidden arbitraryExecution=forbidden; \(bundleEvidenceParts.joined(separator: "; ")); discovered=\(effectKinds.sorted().joined(separator: "+"))"
        )
    }

    private static func declarativeSafetyBoundaryEvidence(
        manifestSchema: [String: Any]
    ) -> (passed: Bool, evidence: String) {
        let layerTypes = schemaEnumValues(manifestSchema, definitionName: "layer", propertyName: "type")
        let effectTypes = schemaEnumValues(manifestSchema, definitionName: "effect", propertyName: "type")
        let bindingSources = schemaEnumValues(
            manifestSchema,
            definitionName: "declarativeBinding",
            propertyName: "source"
        )
        let bindingAdapters = schemaEnumValues(
            manifestSchema,
            definitionName: "bindingAdapter",
            propertyName: "type"
        )
        let bindingTargetPattern = schemaStringValue(
            manifestSchema,
            definitionName: "declarativeBinding",
            propertyName: "target",
            key: "pattern"
        ) ?? ""

        let expectedLayerTypes: Set<String> = ["static_image", "video", "spine"]
        let expectedEffectTypes: Set<String> = [
            EffectType.blur.rawValue,
            EffectType.colorMatrix.rawValue,
            EffectType.scroll.rawValue,
            EffectType.chromaticAberration.rawValue
        ]
        let expectedBindingSources: Set<String> = [
            BindingSource.pointerPosition.rawValue,
            BindingSource.pointerDown.rawValue,
            BindingSource.systemTime.rawValue,
            BindingSource.thermalState.rawValue
        ]
        let expectedBindingAdapters: Set<String> = [
            BindingAdapterType.smoothLookAt.rawValue,
            BindingAdapterType.triggerPlay.rawValue,
            BindingAdapterType.mapRange.rawValue,
            BindingAdapterType.spring.rawValue
        ]
        let forbiddenLayerTypes: Set<String> = ["script", "web", "html", "executable"]
        let forbiddenEffectTypes: Set<String> = ["shader", "customShader", "metal", "javascript", "lua"]
        let forbiddenBindingSources: Set<String> = ["command", "file", "filesystem", "network", "process"]
        let safeTargetPattern = bindingTargetPattern.contains("spine\\.bone\\.")
            && bindingTargetPattern.contains("spine\\.animation\\.")
            && bindingTargetPattern.contains("effect\\.")
            && bindingTargetPattern.contains("^(")

        let closedDefs = [
            schemaAdditionalPropertiesFalse(manifestSchema, definitionName: "layer"),
            schemaAdditionalPropertiesFalse(manifestSchema, definitionName: "effect"),
            schemaAdditionalPropertiesFalse(manifestSchema, definitionName: "declarativeBinding"),
            schemaAdditionalPropertiesFalse(manifestSchema, definitionName: "bindingAdapter")
        ].allSatisfy { $0 }

        let passed = closedDefs
            && layerTypes == expectedLayerTypes
            && effectTypes == expectedEffectTypes
            && bindingSources == expectedBindingSources
            && bindingAdapters == expectedBindingAdapters
            && forbiddenLayerTypes.isDisjoint(with: layerTypes)
            && forbiddenEffectTypes.isDisjoint(with: effectTypes)
            && forbiddenBindingSources.isDisjoint(with: bindingSources)
            && safeTargetPattern

        return (
            passed,
            "schema=closed layerTypes=\(layerTypes.sorted().joined(separator: "+")) effectTypes=\(effectTypes.sorted().joined(separator: "+")) bindingSources=\(bindingSources.sorted().joined(separator: "+")) bindingAdapters=\(bindingAdapters.sorted().joined(separator: "+")) bindingTargetPattern=\(safeTargetPattern ? "engine-owned" : "unsafe") denied=script-layer+shader-effect+command-file-network-source"
        )
    }

    private static func schemaHasDefinitions(
        _ schema: [String: Any],
        propertyNames: [String],
        definitionNames: [String]
    ) -> Bool {
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let defs = schema["$defs"] as? [String: Any] ?? [:]
        return propertyNames.allSatisfy { properties[$0] != nil }
            && definitionNames.allSatisfy { defs[$0] != nil }
    }

    private static func schemaEnumValues(
        _ schema: [String: Any],
        definitionName: String,
        propertyName: String
    ) -> Set<String> {
        guard let property = schemaProperty(schema, definitionName: definitionName, propertyName: propertyName),
              let values = property["enum"] as? [Any] else {
            return []
        }
        return Set(values.compactMap { $0 as? String })
    }

    private static func schemaStringValue(
        _ schema: [String: Any],
        definitionName: String,
        propertyName: String,
        key: String
    ) -> String? {
        schemaProperty(schema, definitionName: definitionName, propertyName: propertyName)?[key] as? String
    }

    private static func schemaAdditionalPropertiesFalse(
        _ schema: [String: Any],
        definitionName: String
    ) -> Bool {
        guard let definition = schemaDefinition(schema, definitionName: definitionName) else {
            return false
        }
        return (definition["additionalProperties"] as? Bool) == false
    }

    private static func schemaProperty(
        _ schema: [String: Any],
        definitionName: String,
        propertyName: String
    ) -> [String: Any]? {
        guard let definition = schemaDefinition(schema, definitionName: definitionName),
              let properties = definition["properties"] as? [String: Any] else {
            return nil
        }
        return properties[propertyName] as? [String: Any]
    }

    private static func schemaDefinition(
        _ schema: [String: Any],
        definitionName: String
    ) -> [String: Any]? {
        guard let defs = schema["$defs"] as? [String: Any] else {
            return nil
        }
        return defs[definitionName] as? [String: Any]
    }

    private static func genericRuntimeSourceBoundaryEvidence(
        projectRoot: URL?,
        bundles: [WallpaperBundleSummary]
    ) throws -> (passed: Bool, evidence: String) {
        guard let projectRoot else {
            return (true, "source scan skipped: project root unavailable in this runtime context")
        }

        let sourcesRoot = projectRoot.appendingPathComponent("apps/MacWallpaperEngine/Sources", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourcesRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return (true, "source scan skipped: Swift source tree unavailable")
        }

        let tokens = try genericRuntimeBoundaryTokens(bundles: bundles)
        guard tokens.isEmpty == false else {
            return (true, "source scan passed: no bundle-owned tokens require scanning")
        }

        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (false, "source scan failed: unable to enumerate \(sourcesRoot.path)")
        }

        let allowedFiles: Set<String> = [
            "RuntimeSelfTest.swift"
        ]
        var violations: [String] = []
        for case let sourceURL as URL in enumerator {
            guard sourceURL.pathExtension == "swift" else { continue }
            guard allowedFiles.contains(sourceURL.lastPathComponent) == false else { continue }
            guard (try sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }

            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for token in tokens where source.contains(token) {
                let relativePath = sourceURL.path
                    .replacingOccurrences(of: projectRoot.path + "/", with: "")
                violations.append("\(relativePath):\(token)")
            }
        }

        guard violations.isEmpty else {
            return (
                false,
                "source scan failed: \(violations.prefix(8).joined(separator: ","))"
            )
        }
        return (
            true,
            "source scan passed: checked \(tokens.count) bundle-owned token(s) outside tests"
        )
    }

    private static func genericRuntimeBoundaryTokens(
        bundles: [WallpaperBundleSummary]
    ) throws -> [String] {
        let genericInteractionTokens: Set<String> = [
            "idle",
            "left",
            "right",
            "up",
            "down",
            "Left",
            "Right",
            "Up",
            "Down",
            "head",
            "body",
            "default"
        ]
        var tokens = Set<String>()
        for bundle in bundles {
            for token in [bundle.id, bundle.displayName] where token.count >= 4 {
                tokens.insert(token)
            }
            guard let manifest = try? ManifestLoader.load(url: bundle.manifestURL, bundleRoot: bundle.root) else {
                continue
            }
            for interaction in manifest.interactions {
                if let actionValues = interaction.actions?.values {
                    for action in actionValues where action.count >= 4 {
                        if genericInteractionTokens.contains(action) == false {
                            tokens.insert(action)
                        }
                    }
                }
                for zone in interaction.hitZones ?? [] {
                    for token in [zone.id, zone.action, zone.tapAction, zone.rubAction].compactMap({ $0 }) where token.count >= 4 {
                        if genericInteractionTokens.contains(token) == false {
                            tokens.insert(token)
                        }
                    }
                }
                if let defaultAction = interaction.defaultAction?.action,
                   defaultAction.count >= 4,
                   genericInteractionTokens.contains(defaultAction) == false {
                    tokens.insert(defaultAction)
                }
            }
        }
        return tokens.sorted()
    }

    private static func declaredAssetIDs(_ manifest: WallpaperNativeManifest) -> [String] {
        [
            manifest.assets.staticImage?.id,
            manifest.assets.video?.id,
            manifest.assets.compositeVideo?.id,
            manifest.assets.spine?.id
        ].compactMap { $0 }
    }

    private static func referencedInteractionActions(in interactions: [InteractionConfig]) -> Set<String> {
        var actions = Set<String>()
        for interaction in interactions {
            interaction.actions?.values.forEach { actions.insert($0) }
            interaction.hitZones?.forEach {
                actions.insert($0.action)
                if let tapAction = $0.tapAction {
                    actions.insert(tapAction)
                }
                if let rubAction = $0.rubAction {
                    actions.insert(rubAction)
                }
            }
            if let defaultAction = interaction.defaultAction {
                actions.insert(defaultAction.action)
            }
        }
        return actions
    }

    private static func interactionOwnershipText(_ manifest: WallpaperNativeManifest) -> String {
        guard manifest.interactions.isEmpty == false else { return "none" }
        let plan = InteractionPlan(
            interactions: manifest.interactions,
            policy: manifest.interactionPolicy
        )
        let moveText = manifest.interactions
            .filter { $0.event == .pointerMove }
            .map { interaction -> String in
                let actions = interaction.actions?
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ",") ?? "none"
                let neutral = interaction.neutralPoint.map { "neutral=\(formatPoint($0))" } ?? "neutral=default"
                let deadZone = interaction.deadZone.map { "deadZone=\(formatPoint($0))" } ?? "deadZone=policy"
                let buttons = "buttons=\(interaction.buttons?.map(\.rawValue).joined(separator: "+") ?? "any")"
                return "pointerMove{\(actions);\(neutral);\(deadZone);\(buttons)}"
            }
        let clickZones = plan.hitZoneSummaries().map(\.detailText)
        let defaultActions = manifest.interactions
            .filter { $0.event == .pointerDown }
            .compactMap {
                InteractionPlan(
                    interactions: [$0],
                    policy: manifest.interactionPolicy
                ).defaultActionSummary()?.detailText
            }
        let downText = [
            clickZones.isEmpty ? nil : "zones{\(clickZones.joined(separator: ","))}",
            defaultActions.isEmpty ? "default=none" : "default{\(defaultActions.joined(separator: ","))}"
        ].compactMap { $0 }.joined(separator: ";")
        return (moveText + (downText.isEmpty ? [] : ["pointerDown{\(downText)}"])).joined(separator: "|")
    }

    private static func formatPoint(_ point: InteractionPoint) -> String {
        "(\(String(format: "%.2f", point.x)),\(String(format: "%.2f", point.y)))"
    }

    private static func liveClickProtocolText(bundles: [WallpaperBundleSummary]) -> String {
        let interactiveBundles = bundles.filter {
            $0.capabilities.interactionKinds.contains("pointerMove")
                || $0.capabilities.interactionKinds.contains("pointerDown")
        }
        guard interactiveBundles.isEmpty == false else {
            return "no manifest-declared pointer interactions for the discovered bundles"
        }

        let bundleTexts = interactiveBundles.prefix(3).map { bundle -> String in
            guard let manifest = try? ManifestLoader.load(url: bundle.manifestURL, bundleRoot: bundle.root) else {
                return "\(bundle.id): manifest interaction checklist unavailable"
            }
            let plan = InteractionPlan(
                interactions: manifest.interactions,
                policy: manifest.interactionPolicy
            )
            let moveText = manifest.interactions
                .first(where: { $0.event == .pointerMove })?
                .actions?
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",") ?? "none"
            let zoneText = plan.hitZoneSummaries().map { zone in
                if let tapAction = zone.tapAction {
                    let rubText = zone.rubAction.map {
                        ",rub=\($0)@\(String(format: "%.2fs", zone.rubStartSeconds))+distance\(String(format: "%.3f", Double(zone.rubStartDistance)))"
                    } ?? ""
                    return "\(zone.id):tap=\(tapAction),hold=\(zone.action)@\(String(format: "%.2fs", zone.holdStartSeconds))\(rubText)"
                }
                return "\(zone.id):\(zone.trigger.rawValue)=\(zone.action)"
            }.joined(separator: ",")
            let defaultText = plan.defaultActionSummary().map { "default:\($0.trigger.rawValue)=\($0.action)" } ?? "empty=no-action"
            return "\(bundle.id){move:\(moveText); click:\(zoneText.isEmpty ? defaultText : zoneText + "," + defaultText)}"
        }

        let suffix = interactiveBundles.count > bundleTexts.count
            ? "; +\(interactiveBundles.count - bundleTexts.count) more bundle(s)"
            : ""
        return "verify manifest-declared pointerMove/pointerDown behavior: \(bundleTexts.joined(separator: "; "))\(suffix)"
    }

    static func currentLiveClickProtocolText(
        projectRoot: URL? = ProjectPaths.findCatalogProjectRoot(),
        bundleDirectories: [URL]? = nil
    ) throws -> String {
        let diagnostics = bundleDirectories.map(WallpaperBundleCatalog.diagnose(in:))
            ?? WallpaperBundleCatalog.diagnoseDefaultBundles(projectRoot: projectRoot)
        let bundles = diagnostics.compactMap(\.bundle)
        let interactiveSpineBundles = bundles.filter {
            isNativeSpinePlayable($0.capabilities)
                && $0.capabilities.interactionKinds.contains("pointerMove")
                && $0.capabilities.interactionKinds.contains("pointerDown")
        }
        return liveClickProtocolText(bundles: interactiveSpineBundles)
    }

    static func physicalDisplayHotplugProtocolText() -> String {
        "test selectedOnly=primary-only selectedPolicy=primary-full-secondary-passive allFull=all-displays; reconnect or wake displays; expected restored wallpaper windows on target displays"
    }

    static func currentBlackFrameFlickerProtocolText() -> String {
        "start packaged app; switch selectedOnly/selectedPolicy/allFull; trigger display rebuild or wake; expected no black frame, no visible flicker loop, and no crash"
    }

    private static func oneLine(_ value: String) -> String {
        value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: " / ")
    }

    private static func manualEvidenceText(
        _ entry: ManualSmokeEvidenceEntry?,
        fallback: String,
        requiredProtocolText: String? = nil
    ) -> String {
        guard let entry else { return fallback }
        let normalized = entry.normalizedEvidence
        guard normalized.isEmpty == false else {
            return entry.passed
                ? "manual evidence marked pass but evidence text is empty"
                : "manual evidence marked fail with empty evidence text"
        }
        if entry.passed,
           let requiredProtocolText,
           manualEvidenceProtocolMatches(entry, requiredProtocolText: requiredProtocolText) == false {
            let recordedProtocol = entry.protocolText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let recordedText = (recordedProtocol?.isEmpty == false)
                ? recordedProtocol!
                : "missing"
            return "manual evidence stale: expected protocol '\(requiredProtocolText)' but recorded '\(recordedText)'; \(normalized)"
        }
        return entry.passed
            ? "manual evidence: \(normalized)"
            : "manual evidence failed: \(normalized)"
    }

    private static func manualEvidencePassed(
        _ entry: ManualSmokeEvidenceEntry?,
        fallback: Bool,
        requiredProtocolText: String? = nil
    ) -> Bool {
        guard let entry else { return fallback }
        guard entry.passed else { return false }
        guard let requiredProtocolText else { return true }
        return manualEvidenceProtocolMatches(entry, requiredProtocolText: requiredProtocolText)
    }

    private static func manualEvidenceProtocolMatches(
        _ entry: ManualSmokeEvidenceEntry,
        requiredProtocolText: String
    ) -> Bool {
        if entry.protocolText == requiredProtocolText { return true }
        return entry.normalizedEvidence.contains(requiredProtocolText)
    }

    private static func loadManualEvidence(from url: URL?) throws -> ManualSmokeEvidenceFile? {
        guard let url else { return nil }
        let data = try Data(contentsOf: url)
        let evidence = try JSONDecoder().decode(ManualSmokeEvidenceFile.self, from: data)
        guard evidence.schemaVersion == manualSmokeEvidenceSchemaVersion else {
            throw EngineError.invalidArgument(
                "Manual smoke evidence schemaVersion must be \(manualSmokeEvidenceSchemaVersion)"
            )
        }
        try validateManualEvidenceEntry(
            evidence.packagedAppLaunchSmoke,
            label: "packagedAppLaunchSmoke",
            requiredPassTokens: ["launch", "crash"]
        )
        try validateManualEvidenceEntry(
            evidence.liveDesktopClickActions,
            label: "liveDesktopClickActions",
            requiredPassTokens: ["click", "gaze", "tap", "hold", "rub", "empty"],
            requireOperatorNoteOnPass: true,
            operatorNoteSubject: "live click/gaze tap, hold, rub, empty-click, and gaze observations"
        )
        try validateManualEvidenceEntry(
            evidence.physicalDisplayHotplugSmoke,
            label: "physicalDisplayHotplugSmoke",
            requiredPassTokens: ["selectedonly", "selectedpolicy", "allfull"],
            requiredAnyPassTokens: ["reconnect", "wake"],
            requireOperatorNoteOnPass: true,
            operatorNoteSubject: "the observed physical display event"
        )
        try validateManualEvidenceEntry(
            evidence.blackFrameFlickerSmoke,
            label: "blackFrameFlickerSmoke",
            requiredPassTokens: ["black", "flicker", "crash"]
        )
        return evidence
    }

    private static func loadExistingManualEvidence(from url: URL) throws -> ManualSmokeEvidenceFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try loadManualEvidence(from: url)
    }

    private static func passEntry(
        recordedAt: String,
        evidence: String,
        operatorNote: String? = nil,
        protocolText: String? = nil
    ) -> ManualSmokeEvidenceEntry {
        ManualSmokeEvidenceEntry(
            passed: true,
            evidence: evidence,
            recordedAt: recordedAt,
            operatorNote: operatorNote ?? "Recorded by --record-manual-smoke-evidence after operator observation.",
            protocolText: protocolText
        )
    }

    private static func templatePackagedLaunchEntry() -> ManualSmokeEvidenceEntry {
        ManualSmokeEvidenceEntry(
            passed: false,
            evidence: "Launch dist/MacWallpaperEngine.app from Finder or package smoke gate; record whether the app stays alive without crash.",
            recordedAt: "REPLACE_WITH_ISO8601_LOCAL_TIME",
            operatorNote: "Required before packaged-app-launch-smoke can pass.",
            protocolText: nil
        )
    }

    private static func templateLiveClickEntry(protocolText: String? = nil) -> ManualSmokeEvidenceEntry {
        ManualSmokeEvidenceEntry(
            passed: false,
            evidence: "Do not grant Accessibility; enable click actions; run --interaction-plan for the selected wallpaper bundle; verify the manifest-declared pointerMove and pointerDown click/gaze actions, plus application-window gating.",
            recordedAt: "REPLACE_WITH_ISO8601_LOCAL_TIME",
            operatorNote: "Required before live-desktop-click-actions can pass: describe observed tap, hold, rub, empty-click, and gaze behavior.",
            protocolText: protocolText
        )
    }

    private static func templatePhysicalDisplayEntry(protocolText: String? = nil) -> ManualSmokeEvidenceEntry {
        ManualSmokeEvidenceEntry(
            passed: false,
            evidence: "Verify selectedOnly=primary-only, selectedPolicy=primary-full-secondary-passive, allFull=all-displays; reconnect or wake displays and confirm wallpaper windows restore on target displays.",
            recordedAt: "REPLACE_WITH_ISO8601_LOCAL_TIME",
            operatorNote: "Required before physical-display-hotplug-smoke can pass.",
            protocolText: protocolText
        )
    }

    private static func templateBlackFrameFlickerEntry(protocolText: String? = nil) -> ManualSmokeEvidenceEntry {
        ManualSmokeEvidenceEntry(
            passed: false,
            evidence: "Start packaged app; switch selectedOnly/selectedPolicy/allFull; trigger display rebuild or wake; confirm no black frame, no visible flicker loop, and no crash.",
            recordedAt: "REPLACE_WITH_ISO8601_LOCAL_TIME",
            operatorNote: "Required before black-frame-flicker-smoke can pass.",
            protocolText: protocolText
        )
    }

    private static func validateManualEvidenceEntry(
        _ entry: ManualSmokeEvidenceEntry?,
        label: String,
        requiredPassTokens: [String],
        requiredAnyPassTokens: [String] = [],
        requireOperatorNoteOnPass: Bool = false,
        operatorNoteSubject: String = "the observed smoke"
    ) throws {
        guard let entry else { return }
        let normalizedEvidence = entry.normalizedEvidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entry.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw EngineError.invalidArgument("Manual smoke evidence \(label).evidence must not be empty")
        }
        guard entry.passed else { return }
        guard normalizedEvidence.contains("REPLACE_WITH_") == false else {
            throw EngineError.invalidArgument("Manual smoke evidence \(label) cannot pass while template placeholders remain")
        }
        if requireOperatorNoteOnPass {
            let note = entry.operatorNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let genericRecorderNote = "Recorded by --record-manual-smoke-evidence after operator observation."
            guard note.isEmpty == false,
                  note.contains("REPLACE_WITH_") == false,
                  note != genericRecorderNote else {
                throw EngineError.invalidArgument(
                    "Manual smoke evidence \(label) pass requires a concrete operatorNote describing \(operatorNoteSubject)"
                )
            }
            let incompleteMarkers = [
                "auto-generated",
                "manual checklist still required",
                "partial",
                "not observed",
                "not explicitly observed",
                "required before"
            ]
            let foldedNote = note.lowercased()
            let foldedFullEvidence = normalizedEvidence.lowercased()
            if let marker = incompleteMarkers.first(where: {
                foldedNote.contains($0) || foldedFullEvidence.contains($0)
            }) {
                throw EngineError.invalidArgument(
                    "Manual smoke evidence \(label) pass still contains incomplete-evidence marker: \(marker)"
                )
            }
        }
        let foldedEvidence = normalizedEvidence.lowercased()
        let missingTokens = requiredPassTokens.filter { foldedEvidence.contains($0) == false }
        guard missingTokens.isEmpty else {
            throw EngineError.invalidArgument(
                "Manual smoke evidence \(label) pass evidence is missing checklist token(s): \(missingTokens.joined(separator: ", "))"
            )
        }
        if requiredAnyPassTokens.isEmpty == false,
           requiredAnyPassTokens.contains(where: { foldedEvidence.contains($0) }) == false {
            throw EngineError.invalidArgument(
                "Manual smoke evidence \(label) pass evidence must mention at least one lifecycle token: \(requiredAnyPassTokens.joined(separator: " or "))"
            )
        }
    }

    private static func protocolItem(id: String, evidence: String) -> CompletionAuditRow {
        CompletionAuditRow(
            category: "protocol",
            status: "manual",
            id: id,
            evidence: evidence,
            risk: "manual evidence protocol"
        )
    }

    private static func scopeItem(id: String, evidence: String) -> CompletionAuditRow {
        CompletionAuditRow(
            category: "scope",
            status: "deferred",
            id: id,
            evidence: evidence,
            risk: "not part of current completion claim"
        )
    }

    private static func packageRuntimeMetadataText() -> String? {
        guard let metadataURL = Bundle.main.resourceURL?.appendingPathComponent("package-runtime.txt"),
              FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        return try? String(contentsOf: metadataURL, encoding: .utf8)
    }
}
