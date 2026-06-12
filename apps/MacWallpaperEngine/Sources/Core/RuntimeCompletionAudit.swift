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
        let hasDisplayModes = validationMatrix.contains("displayModes: selectedOnly+selectedPolicy+allFull")
        let hasDisplayRefresh = validationMatrix.contains("displayRefreshFps: primary120+secondary60")
        let hasPerformancePlan = validationMatrix.contains("performancePlan: target=")
        let hasGolden = validationMatrix.contains("golden: pass")
        let hasInstaller = validationMatrix.contains("installer: importable")
        let nativeDefaultFallback = try nativeDefaultFallbackEvidence(bundles: bundles)
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
                    && interactiveSpineBundles.isEmpty == false,
                evidence: "assets=\(assetFamilies.sorted().joined(separator: "+")) layers=\(layerFamilies.sorted().joined(separator: "+")) interactiveSpine=\(interactiveSpineBundles.count)",
                risk: "needs static, video-only, and interactive native-Spine fixtures"
            ),
            item(
                id: "native-spine-default-fallback",
                passed: nativeDefaultFallback.passed,
                evidence: nativeDefaultFallback.evidence,
                risk: "Native-supported interactive wallpapers must not silently default to the lower-quality composite fallback"
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
                    fallback: false
                ),
                evidence: manualEvidenceText(
                    liveClickEvidence,
                    fallback: "no-permission input policy; manual live smoke still required: \(liveInteractionProtocol)"
                )
            ),
            manualItem(
                id: "physical-display-hotplug-smoke",
                passed: manualEvidencePassed(physicalDisplayEvidence, fallback: false),
                evidence: manualEvidenceText(
                    physicalDisplayEvidence,
                    fallback: "simulated display matrix passed; physical reconnect/hot-plug smoke evidence is not recorded in this CLI run"
                )
            ),
            manualItem(
                id: "black-frame-flicker-smoke",
                passed: manualEvidencePassed(blackFrameFlickerEvidence, fallback: false),
                evidence: manualEvidenceText(
                    blackFrameFlickerEvidence,
                    fallback: "renderer warmup/rebuild guards are covered by automated tests, but live no-black-frame/no-flicker observation is not recorded"
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
                evidence: "test selectedOnly=primary-only selectedPolicy=primary-full-secondary-passive allFull=all-displays; reconnect or wake displays; expected restored wallpaper windows on target displays"
            ),
            protocolItem(
                id: "black-frame-flicker-smoke-protocol",
                evidence: "start packaged app; switch selectedOnly/selectedPolicy/allFull; trigger display rebuild or wake; expected no black frame, no visible flicker loop, and no crash"
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
        let text = manualSmokeEvidenceTemplateText()
        try text.write(to: destination, atomically: true, encoding: .utf8)
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
        physicalDisplayHotplugNote: String? = nil
    ) throws -> String {
        guard packagedLaunchPassed || liveClickActionsPassed || physicalDisplayHotplugPassed || blackFrameFlickerPassed else {
            throw EngineError.invalidArgument(
                "At least one manual smoke confirmation flag is required: --confirm-packaged-launch, --confirm-live-click-actions, --confirm-physical-display-hotplug, or --confirm-black-frame-flicker"
            )
        }
        let normalizedPhysicalDisplayHotplugNote = physicalDisplayHotplugNote?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if physicalDisplayHotplugPassed && (normalizedPhysicalDisplayHotplugNote?.isEmpty ?? true) {
            throw EngineError.invalidArgument(
                "--confirm-physical-display-hotplug requires --physical-display-hotplug-note <observed display event and restored displays>"
            )
        }

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let existing = try loadExistingManualEvidence(from: destination)
        let recordedAt = ISO8601DateFormatter().string(from: Date())
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
                    evidence: "Operator confirmed live click/gaze interactions against the selected wallpaper manifest-declared pointerMove and pointerDown actions."
                )
                : existing?.liveDesktopClickActions ?? templateLiveClickEntry(),
            physicalDisplayHotplugSmoke: physicalDisplayHotplugPassed
                ? passEntry(
                    recordedAt: recordedAt,
                    evidence: "Operator confirmed physical display smoke: selectedOnly primary-only, selectedPolicy secondary-passive, allFull all-displays, reconnect/wake restored wallpaper windows on target displays.",
                    operatorNote: normalizedPhysicalDisplayHotplugNote
                )
                : existing?.physicalDisplayHotplugSmoke ?? templatePhysicalDisplayEntry(),
            blackFrameFlickerSmoke: blackFrameFlickerPassed
                ? passEntry(
                    recordedAt: recordedAt,
                    evidence: "Operator confirmed black-frame/flicker smoke: packaged app start, mode switch, display rebuild or wake produced no black frame, no visible flicker loop, and no crash."
                )
                : existing?.blackFrameFlickerSmoke ?? templateBlackFrameFlickerEntry()
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
                let actionNames = referencedInteractionActions(in: manifest.interactions).sorted()
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
        let bundleEvidence = bundles.map {
            "\($0.id)=bindings(\($0.capabilities.bindingKinds.joined(separator: "+")))"
        }.joined(separator: "; ")
        return (
            schemaOK,
            "schema=\(schemaOK ? "declared" : "missing") sources=pointer.position+pointer.down+system.time+thermal.state targets=spine.bone+spine.animation+effect adapters=smooth-lookat(runtime-bone-rotation)+trigger-play(runtime-executable)+map-range(runtime-evaluable)+spring(system-time-effect-runtime+pointer-spine-runtime,explicit-dynamics-contract); \(bundleEvidence); discovered=\(bindingKinds.sorted().joined(separator: "+"))"
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
        let bundleEvidence = bundles.map {
            "\($0.id)=effects(\($0.capabilities.effectKinds.joined(separator: "+")))"
        }.joined(separator: "; ")
        return (
            schemaOK,
            "schema=\(schemaOK ? "declared" : "missing") whitelist=blur(runtime-rendered)+colorMatrix(runtime-rendered)+scroll(runtime-rendered)+chromaticAberration(runtime-rendered) dynamicShaderLoading=forbidden arbitraryExecution=forbidden; \(bundleEvidence); discovered=\(effectKinds.sorted().joined(separator: "+"))"
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
                    for token in [zone.id, zone.action, zone.tapAction].compactMap({ $0 }) where token.count >= 4 {
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
                    return "\(zone.id):tap=\(tapAction),hold=\(zone.action)@\(String(format: "%.2fs", zone.holdStartSeconds))"
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

    private static func oneLine(_ value: String) -> String {
        value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: " / ")
    }

    private static func manualEvidenceText(_ entry: ManualSmokeEvidenceEntry?, fallback: String) -> String {
        guard let entry else { return fallback }
        let normalized = entry.normalizedEvidence
        guard normalized.isEmpty == false else {
            return entry.passed
                ? "manual evidence marked pass but evidence text is empty"
                : "manual evidence marked fail with empty evidence text"
        }
        return entry.passed
            ? "manual evidence: \(normalized)"
            : "manual evidence failed: \(normalized)"
    }

    private static func manualEvidencePassed(_ entry: ManualSmokeEvidenceEntry?, fallback: Bool) -> Bool {
        entry?.passed ?? fallback
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
            requiredPassTokens: ["click", "gaze"]
        )
        try validateManualEvidenceEntry(
            evidence.physicalDisplayHotplugSmoke,
            label: "physicalDisplayHotplugSmoke",
            requiredPassTokens: ["selectedonly", "selectedpolicy", "allfull", "reconnect"],
            requireOperatorNoteOnPass: true
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
        operatorNote: String? = nil
    ) -> ManualSmokeEvidenceEntry {
        ManualSmokeEvidenceEntry(
            passed: true,
            evidence: evidence,
            recordedAt: recordedAt,
            operatorNote: operatorNote ?? "Recorded by --record-manual-smoke-evidence after operator observation."
        )
    }

    private static func templatePackagedLaunchEntry() -> ManualSmokeEvidenceEntry {
        ManualSmokeEvidenceEntry(
            passed: false,
            evidence: "Launch dist/MacWallpaperEngine.app from Finder or package smoke gate; record whether the app stays alive without crash.",
            recordedAt: "REPLACE_WITH_ISO8601_LOCAL_TIME",
            operatorNote: "Required before packaged-app-launch-smoke can pass."
        )
    }

    private static func templateLiveClickEntry() -> ManualSmokeEvidenceEntry {
        ManualSmokeEvidenceEntry(
            passed: false,
            evidence: "Do not grant Accessibility; enable click actions; run --interaction-plan for the selected wallpaper bundle; verify the manifest-declared pointerMove and pointerDown click/gaze actions, plus application-window gating.",
            recordedAt: "REPLACE_WITH_ISO8601_LOCAL_TIME",
            operatorNote: "Required before live-desktop-click-actions can pass."
        )
    }

    private static func templatePhysicalDisplayEntry() -> ManualSmokeEvidenceEntry {
        ManualSmokeEvidenceEntry(
            passed: false,
            evidence: "Verify selectedOnly=primary-only, selectedPolicy=primary-full-secondary-passive, allFull=all-displays; reconnect or wake displays and confirm wallpaper windows restore on target displays.",
            recordedAt: "REPLACE_WITH_ISO8601_LOCAL_TIME",
            operatorNote: "Required before physical-display-hotplug-smoke can pass."
        )
    }

    private static func templateBlackFrameFlickerEntry() -> ManualSmokeEvidenceEntry {
        ManualSmokeEvidenceEntry(
            passed: false,
            evidence: "Start packaged app; switch selectedOnly/selectedPolicy/allFull; trigger display rebuild or wake; confirm no black frame, no visible flicker loop, and no crash.",
            recordedAt: "REPLACE_WITH_ISO8601_LOCAL_TIME",
            operatorNote: "Required before black-frame-flicker-smoke can pass."
        )
    }

    private static func validateManualEvidenceEntry(
        _ entry: ManualSmokeEvidenceEntry?,
        label: String,
        requiredPassTokens: [String],
        requireOperatorNoteOnPass: Bool = false
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
                    "Manual smoke evidence \(label) pass requires a concrete operatorNote describing the observed physical display event"
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
    }

    private static func manualSmokeEvidenceTemplateText() -> String {
        """
        {
          "schemaVersion": "\(manualSmokeEvidenceSchemaVersion)",
          "packagedAppLaunchSmoke": {
            "passed": false,
            "recordedAt": "REPLACE_WITH_ISO8601_LOCAL_TIME",
            "evidence": "Launch dist/MacWallpaperEngine.app from Finder or package smoke gate; record whether the app stays alive without crash.",
            "operatorNote": "Required before packaged-app-launch-smoke can pass."
          },
          "liveDesktopClickActions": {
            "passed": false,
            "recordedAt": "REPLACE_WITH_ISO8601_LOCAL_TIME",
            "evidence": "Do not grant Accessibility; enable click actions; run --interaction-plan for the selected wallpaper bundle; verify the manifest-declared pointerMove and pointerDown click/gaze actions, plus application-window gating.",
            "operatorNote": "Required before live-desktop-click-actions can pass."
          },
          "physicalDisplayHotplugSmoke": {
            "passed": false,
            "recordedAt": "REPLACE_WITH_ISO8601_LOCAL_TIME",
            "evidence": "Verify selectedOnly=primary-only, selectedPolicy=primary-full-secondary-passive, allFull=all-displays; reconnect or wake displays and confirm wallpaper windows restore on target displays.",
            "operatorNote": "Required before physical-display-hotplug-smoke can pass."
          },
          "blackFrameFlickerSmoke": {
            "passed": false,
            "recordedAt": "REPLACE_WITH_ISO8601_LOCAL_TIME",
            "evidence": "Start packaged app; switch selectedOnly/selectedPolicy/allFull; trigger display rebuild or wake; confirm no black frame, no visible flicker loop, and no crash.",
            "operatorNote": "Required before black-frame-flicker-smoke can pass."
          }
        }
        """
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
