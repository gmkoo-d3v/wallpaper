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
