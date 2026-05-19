import CoreGraphics
import Foundation

enum RuntimeDoctorReport {
    static func controlPanelSummary(runtime: NativeRuntimeCore, interactionStatus: String) -> String {
        let compatibility = RuntimeCapabilities.nativeSpineCompatibility(runtime: runtime)
        let nativeStatus: String
        if compatibility.isSupported == false {
            nativeStatus = "fallback(\(shorten(compatibility.reasonText, limit: 72)))"
        } else if compatibility.degradations.isEmpty == false {
            nativeStatus = "degraded(\(shorten(compatibility.degradationText, limit: 72)))"
        } else {
            nativeStatus = "supported"
        }
        let quality = runtime.compositeQualityReport().summaryLine
        return [
            "doctor: OK / native=\(nativeStatus)",
            "quality: \(quality) / fps=\(runtime.renderTargetFps) max=\(runtime.manifest.runtime.maxFps)",
            "display: \(runtime.config.displayMode.cliName) / foreground=\(runtime.config.foregroundMode.rawValue)",
            packageSigningSummaryLine(),
            "interaction: \(shorten(interactionStatus.replacingOccurrences(of: "\n", with: " / "), limit: 96))"
        ].joined(separator: "\n")
    }

    static func make(
        runtime: NativeRuntimeCore,
        recoveryURL: URL? = RendererRecoveryStore.defaultRecoveryURL()
    ) throws -> String {
        let actionTailDurations = try SpineAnimationDiagnostics.tapActionDurations(runtime: runtime)
        let interaction = InteractionPlan.diagnosticSummary(
            interactions: runtime.manifest.interactions,
            policy: runtime.manifest.interactionPolicy,
            runtimeInteractive: runtime.config.interactive,
            actionTailDurations: actionTailDurations,
            fitMode: runtime.config.fitMode,
            contentAspect: CGFloat(runtime.assetCatalog.contentAspect),
            accessibilityTrusted: DesktopInteractionGate.hasAccessibilityTrust()
        )

        return [
            "wallpaper doctor OK",
            "bundle: \(runtime.config.wallpaperRoot.path)",
            "manifest: \(runtime.config.manifestURL.path)",
            section("bundle-library", bundleLibraryReport(runtime: runtime)),
            section("validation", runtime.validationSummary()),
            section("runtime-capabilities", runtime.runtimeCapabilitiesSummary()),
            section("render-plan", DisplayPlanner.headlessRenderSummary(runtime: runtime)),
            section("simulated-render-plan", DisplayPlanner.simulatedMultiDisplayRenderSummary(runtime: runtime)),
            section("performance-plan", runtime.performanceSummary()),
            section("package-signing", packageSigningReport()),
            section("interaction-plan", interaction),
            section("renderer-recovery", RendererRecoveryStore.report(recoveryURL: recoveryURL))
        ].joined(separator: "\n\n")
    }

    private static func bundleLibraryReport(runtime: NativeRuntimeCore) -> String {
        let diagnostics = WallpaperBundleCatalog.diagnoseDefaultBundles(projectRoot: runtime.config.projectRoot)
        return BundleListReport.make(
            diagnostics: diagnostics,
            includeInvalid: true,
            includeCapabilities: true
        )
    }

    private static func packageSigningReport() -> String {
        var lines = [
            "bundleIdentifier: \(Bundle.main.bundleIdentifier ?? "unavailable")",
            "bundlePath: \(Bundle.main.bundleURL.path)",
            "accessibilityTrust: \(DesktopInteractionGate.hasAccessibilityTrust() ? "trusted" : "missing")"
        ]

        if let metadata = packageSigningMetadataText() {
            lines.append("metadata: present")
            lines.append(metadata)
        } else {
            lines.append("metadata: unavailable(source-or-unpackaged-run)")
        }

        lines.append(
            "clickActionNote: click/touch actions require macOS Accessibility trust; ad-hoc signed rebuilds may need re-adding the current .app"
        )
        return lines.joined(separator: "\n")
    }

    private static func packageSigningSummaryLine() -> String {
        let trust = DesktopInteractionGate.hasAccessibilityTrust() ? "trusted" : "missing"
        guard let metadata = packageSigningMetadata() else {
            return "signing: source-or-unpackaged / accessibility=\(trust)"
        }

        let mode = metadata["codesignMode"] ?? "unknown"
        let action = mode == "adhoc" && trust == "missing" ? " / re-add current app" : ""
        return "signing: \(mode) / accessibility=\(trust)\(action)"
    }

    private static func packageSigningMetadata() -> [String: String]? {
        guard let metadata = packageSigningMetadataText() else { return nil }
        var result: [String: String] = [:]
        for line in metadata.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            result[String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)] =
                String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.isEmpty ? nil : result
    }

    private static func packageSigningMetadataText() -> String? {
        guard let metadataURL = Bundle.main.resourceURL?.appendingPathComponent("package-signing.txt"),
              let metadata = try? String(contentsOf: metadataURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              metadata.isEmpty == false else {
            return nil
        }
        return metadata
    }

    private static func section(_ title: String, _ body: String) -> String {
        """
        == \(title) ==
        \(body)
        """
    }

    private static func shorten(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: max(limit - 1, 1))
        return String(text[..<end]) + "…"
    }
}
