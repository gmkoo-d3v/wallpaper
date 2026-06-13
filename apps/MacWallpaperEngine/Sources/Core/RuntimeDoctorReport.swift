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
            packageRuntimeSummaryLine(),
            "interaction: \(shorten(interactionStatus.replacingOccurrences(of: "\n", with: " / "), limit: 96))"
        ].joined(separator: "\n")
    }

    static func make(
        runtime: NativeRuntimeCore,
        recoveryURL: URL? = RendererRecoveryStore.defaultRecoveryURL()
    ) throws -> String {
        let actionTailDurations = try SpineAnimationDiagnostics.tapActionDurations(runtime: runtime)
        let declarativePlan = DeclarativeBindingPlan(manifest: runtime.manifest)
        let interaction = InteractionPlan.diagnosticSummary(
            interactions: runtime.manifest.interactions,
            policy: runtime.manifest.interactionPolicy,
            runtimeInteractive: runtime.config.interactive,
            actionTailDurations: actionTailDurations,
            declarativePlan: declarativePlan,
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
            section("source-provenance", RuntimeSourceProvenanceReport.make(runtime: runtime)),
            section("render-plan", DisplayPlanner.headlessRenderSummary(runtime: runtime)),
            section("physical-render-plan", DisplayPlanner.renderSummary(runtime: runtime)),
            section("simulated-render-plan", DisplayPlanner.simulatedMultiDisplayRenderSummary(runtime: runtime)),
            section("simulated-render-plan-matrix", simulatedRenderPlanMatrix(runtime: runtime)),
            section("performance-plan", runtime.performanceSummary()),
            section("package-runtime", packageRuntimeReport()),
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

    private static func simulatedRenderPlanMatrix(runtime: NativeRuntimeCore) -> String {
        [
            DisplayPlanner.simulatedMultiDisplayRenderSummary(runtime: runtime, displayMode: .primaryOnly),
            DisplayPlanner.simulatedMultiDisplayRenderSummary(runtime: runtime, displayMode: .primaryAnimated),
            DisplayPlanner.simulatedMultiDisplayRenderSummary(runtime: runtime, displayMode: .all)
        ].joined(separator: "\n\n---\n\n")
    }

    private static func packageRuntimeReport() -> String {
        var lines = [
            "bundleIdentifier: \(Bundle.main.bundleIdentifier ?? "unavailable")",
            "bundlePath: \(Bundle.main.bundleURL.path)",
            "accessibilityAPIUsed: false",
            "signaturePolicy: unsigned-no-certificate"
        ]

        if let metadata = packageRuntimeMetadataText() {
            lines.append("metadata: present")
            lines.append(metadata)
        } else {
            lines.append("metadata: unavailable(source-or-unpackaged-run)")
        }

        lines.append("clickActionNote: \(clickActionNote())")
        return lines.joined(separator: "\n")
    }

    private static func packageRuntimeSummaryLine() -> String {
        guard let metadata = packageRuntimeMetadata() else {
            return "package: source-or-unpackaged / input=permissionless accessibilityAPI=false signature=unsigned"
        }

        let mode = metadata["packageMode"] ?? "unknown"
        let signature = metadata["signaturePolicy"] ?? "unsigned-no-certificate"
        return "package: \(mode) / input=permissionless accessibilityAPI=false signature=\(signature)"
    }

    private static func clickActionNote() -> String {
        "no Accessibility prompt or AX API is used; click/touch actions run with best-effort desktop-item filtering"
    }

    private static func packageRuntimeMetadata() -> [String: String]? {
        guard let metadata = packageRuntimeMetadataText() else { return nil }
        var result: [String: String] = [:]
        for line in metadata.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            result[String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)] =
                String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.isEmpty ? nil : result
    }

    private static func packageRuntimeMetadataText() -> String? {
        guard let metadataURL = Bundle.main.resourceURL?.appendingPathComponent("package-runtime.txt"),
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
