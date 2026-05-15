enum RuntimeLifecyclePolicy {
    static let startupFailurePolicy = "control-panel-recovery"
    static let visibilityPausePolicy = "pause-when-occluded-or-fullscreen-obscured"

    static func shouldRecoverStartupFailureInControlPanel(launchControlPanel: Bool) -> Bool {
        launchControlPanel
    }

    static func shouldPauseForWindowVisibility(isVisible: Bool, displayPolicy: DisplayPolicy) -> Bool {
        guard isVisible == false else { return false }
        return displayPolicy.occluded == .pause || displayPolicy.fullscreenObscured == .pause
    }

    static func shouldEnableDesktopInteraction(
        isVisible: Bool,
        displayRole: RenderDisplayRole,
        interactionPolicy: InteractionPolicy
    ) -> Bool {
        isVisible && displayRole.allowsInteraction && interactionPolicy.mode != .disabled
    }
}
