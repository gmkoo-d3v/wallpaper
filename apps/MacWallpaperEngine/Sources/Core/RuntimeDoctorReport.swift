import CoreGraphics
import Foundation

enum RuntimeDoctorReport {
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
            section("validation", runtime.validationSummary()),
            section("runtime-capabilities", runtime.runtimeCapabilitiesSummary()),
            section("render-plan", DisplayPlanner.headlessRenderSummary(runtime: runtime)),
            section("simulated-render-plan", DisplayPlanner.simulatedMultiDisplayRenderSummary(runtime: runtime)),
            section("performance-plan", runtime.performanceSummary()),
            section("interaction-plan", interaction),
            section("renderer-recovery", RendererRecoveryStore.report(recoveryURL: recoveryURL))
        ].joined(separator: "\n\n")
    }

    private static func section(_ title: String, _ body: String) -> String {
        """
        == \(title) ==
        \(body)
        """
    }
}
