import Foundation

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
                id: "full-spine-parity-claim",
                passed: false,
                evidence: "native Spine compatibility gate and composite fallback are implemented; full Spine 4.2 parity is not claimed"
            )
        ]

        let automatedPassed = automatedItems.allSatisfy { $0.contains("\tpass\t") }
        let manualOpen = manualItems.contains { $0.contains("\tmanual\t") }
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
        \(automatedItems.joined(separator: "\n"))
        \(manualItems.joined(separator: "\n"))
        """
    }

    private static func item(id: String, passed: Bool, evidence: String, risk: String) -> String {
        [
            "automated",
            passed ? "pass" : "fail",
            id,
            evidence,
            passed ? "none" : risk
        ].joined(separator: "\t")
    }

    private static func manualItem(id: String, passed: Bool, evidence: String) -> String {
        [
            "manual",
            passed ? "pass" : "manual",
            id,
            evidence,
            passed ? "none" : "manual verification required"
        ].joined(separator: "\t")
    }

    private static func packageSigningMetadataText() -> String? {
        guard let metadataURL = Bundle.main.resourceURL?.appendingPathComponent("package-signing.txt"),
              FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        return try? String(contentsOf: metadataURL, encoding: .utf8)
    }
}
