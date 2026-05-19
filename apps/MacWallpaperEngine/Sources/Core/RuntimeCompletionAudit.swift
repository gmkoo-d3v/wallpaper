import Foundation

private struct CompletionAuditRow {
    let category: String
    let status: String
    let id: String
    let evidence: String
    let risk: String

    var line: String {
        [category, status, id, evidence, risk].joined(separator: "\t")
    }

    var isPassingAutomatedEvidence: Bool {
        category == "automated" && status == "pass"
    }

    var isOpenManualEvidence: Bool {
        category == "manual" && status == "manual"
    }
}

enum RuntimeCompletionAudit {
    static func make(
        projectRoot: URL?,
        strictCompositeQuality: Bool,
        includeInvalid: Bool,
        bundleDirectories: [URL]? = nil
    ) throws -> String {
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
                passed: packaged,
                evidence: packaged
                    ? "package-signing metadata present for \(Bundle.main.bundlePath)"
                    : "source/unpackaged run; package script smoke must be checked separately"
            ),
            manualItem(
                id: "live-desktop-click-actions",
                passed: accessibilityTrusted && interactiveSpineBundles.isEmpty == false,
                evidence: accessibilityTrusted
                    ? "Accessibility trusted; run live head tap/head hold/body hold smoke"
                    : "Accessibility trust missing; click actions are blocked by design until the current app is trusted"
            ),
            manualItem(
                id: "physical-display-hotplug-smoke",
                passed: false,
                evidence: "simulated display matrix passed; physical reconnect/hot-plug smoke evidence is not recorded in this CLI run"
            )
        ]
        let protocolItems = [
            protocolItem(
                id: "live-desktop-click-actions-protocol",
                evidence: "launch packaged app; grant Accessibility to current app binary; enable click actions; expected head short tap=boll head hold-or-rub>=0.18s=act body hold=boll empty click=no-action left-drag gaze=Left/Right/Up/Down"
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
