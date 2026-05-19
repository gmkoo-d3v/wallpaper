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

        _ = try ManifestSchemaResource.loadJSON(projectRoot: projectRoot)
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
            $0.capabilities.nativeSpineStatus == "supported"
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
        let packaged = packageSigningMetadataText() != nil
        let accessibilityTrusted = DesktopInteractionGate.hasAccessibilityTrust()
        let packagedEvidence = manualEvidence?.packagedAppLaunchSmoke
        let liveClickEvidence = manualEvidence?.liveDesktopClickActions
        let physicalDisplayEvidence = manualEvidence?.physicalDisplayHotplugSmoke

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
                id: "interaction-compatibility",
                passed: interactionFamilies.contains("pointerMove")
                    && interactionFamilies.contains("pointerDown")
                    && validationMatrix.contains("interactionPlan: active"),
                evidence: "interactions=\(interactionFamilies.sorted().joined(separator: "+")) desktop-empty gate validated",
                risk: "manual desktop click delivery still depends on macOS Accessibility trust"
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
                        ? "package-signing metadata present for \(Bundle.main.bundlePath)"
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
                    fallback: accessibilityTrusted
                        ? "Accessibility trusted; manual live smoke still required: head short tap, head hold/rub, body tap, empty click, left-drag gaze"
                        : "Accessibility trust missing; click actions are blocked by design until the current app is trusted"
                )
            ),
            manualItem(
                id: "physical-display-hotplug-smoke",
                passed: manualEvidencePassed(physicalDisplayEvidence, fallback: false),
                evidence: manualEvidenceText(
                    physicalDisplayEvidence,
                    fallback: "simulated display matrix passed; physical reconnect/hot-plug smoke evidence is not recorded in this CLI run"
                )
            )
        ]
        let protocolItems = [
            protocolItem(
                id: "live-desktop-click-actions-protocol",
                evidence: "launch packaged app; grant Accessibility to current app binary; enable click actions; expected head short tap=boll head hold-or-rub>=0.18s=act body tap=boll empty click=no-action left-drag gaze=Left/Right/Up/Down"
            ),
            protocolItem(
                id: "physical-display-hotplug-smoke-protocol",
                evidence: "test selectedOnly=primary-only selectedPolicy=primary-full-secondary-passive allFull=all-displays; reconnect or wake displays; expected no black frame no crash and restored wallpaper windows on target displays"
            )
        ]
        let scopeItems = [
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
        physicalDisplayHotplugPassed: Bool
    ) throws -> String {
        guard packagedLaunchPassed || liveClickActionsPassed || physicalDisplayHotplugPassed else {
            throw EngineError.invalidArgument(
                "At least one manual smoke confirmation flag is required: --confirm-packaged-launch, --confirm-live-click-actions, or --confirm-physical-display-hotplug"
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
                    evidence: "Operator confirmed live click actions: head short tap=boll, head hold/rub>=0.18s=act, body tap=boll, empty click=no-action, left-drag gaze changed direction."
                )
                : existing?.liveDesktopClickActions ?? templateLiveClickEntry(),
            physicalDisplayHotplugSmoke: physicalDisplayHotplugPassed
                ? passEntry(
                    recordedAt: recordedAt,
                    evidence: "Operator confirmed physical display smoke: selectedOnly primary-only, selectedPolicy secondary-passive, allFull all-displays, reconnect/wake produced no black frame and no crash."
                )
                : existing?.physicalDisplayHotplugSmoke ?? templatePhysicalDisplayEntry()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: destination, options: .atomic)

        _ = try loadManualEvidence(from: destination)

        let confirmed = [
            packagedLaunchPassed ? "packaged-app-launch-smoke" : nil,
            liveClickActionsPassed ? "live-desktop-click-actions" : nil,
            physicalDisplayHotplugPassed ? "physical-display-hotplug-smoke" : nil
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
            requiredPassTokens: ["head", "body", "empty", "gaze"]
        )
        try validateManualEvidenceEntry(
            evidence.physicalDisplayHotplugSmoke,
            label: "physicalDisplayHotplugSmoke",
            requiredPassTokens: ["selectedonly", "selectedpolicy", "allfull", "reconnect", "black", "crash"]
        )
        return evidence
    }

    private static func loadExistingManualEvidence(from url: URL) throws -> ManualSmokeEvidenceFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try loadManualEvidence(from: url)
    }

    private static func passEntry(recordedAt: String, evidence: String) -> ManualSmokeEvidenceEntry {
        ManualSmokeEvidenceEntry(
            passed: true,
            evidence: evidence,
            recordedAt: recordedAt,
            operatorNote: "Recorded by --record-manual-smoke-evidence after operator observation."
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
            evidence: "Grant Accessibility to the current app; enable click actions; verify head short tap=boll, head hold/rub>=0.18s=act, body tap=boll, empty click=no action, left-drag gaze changes direction.",
            recordedAt: "REPLACE_WITH_ISO8601_LOCAL_TIME",
            operatorNote: "Required before live-desktop-click-actions can pass."
        )
    }

    private static func templatePhysicalDisplayEntry() -> ManualSmokeEvidenceEntry {
        ManualSmokeEvidenceEntry(
            passed: false,
            evidence: "Verify selectedOnly=primary-only, selectedPolicy=primary-full-secondary-passive, allFull=all-displays; reconnect or wake displays and confirm no black frame and no crash.",
            recordedAt: "REPLACE_WITH_ISO8601_LOCAL_TIME",
            operatorNote: "Required before physical-display-hotplug-smoke can pass."
        )
    }

    private static func validateManualEvidenceEntry(
        _ entry: ManualSmokeEvidenceEntry?,
        label: String,
        requiredPassTokens: [String]
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
            "evidence": "Grant Accessibility to the current app; enable click actions; verify head short tap=boll, head hold/rub>=0.18s=act, body tap=boll, empty click=no action, left-drag gaze changes direction.",
            "operatorNote": "Required before live-desktop-click-actions can pass."
          },
          "physicalDisplayHotplugSmoke": {
            "passed": false,
            "recordedAt": "REPLACE_WITH_ISO8601_LOCAL_TIME",
            "evidence": "Verify selectedOnly=primary-only, selectedPolicy=primary-full-secondary-passive, allFull=all-displays; reconnect or wake displays and confirm no black frame and no crash.",
            "operatorNote": "Required before physical-display-hotplug-smoke can pass."
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

    private static func packageSigningMetadataText() -> String? {
        guard let metadataURL = Bundle.main.resourceURL?.appendingPathComponent("package-signing.txt"),
              FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        return try? String(contentsOf: metadataURL, encoding: .utf8)
    }
}
