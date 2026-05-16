import Foundation

enum RuntimeLifecyclePolicy {
    static let startupFailurePolicy = "control-panel-recovery"
    static let visibilityPausePolicy = "pause-when-occluded-or-fullscreen-obscured"
    static let desktopItemTrustPolicy = "fail-closed-without-accessibility-trust"
    static let displayRebuildPolicy = "debounced-atomic-rollback"
    static let displayRebuildDebounceSeconds: TimeInterval = 0.25

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
        interactionPolicy: InteractionPolicy,
        accessibilityTrusted: Bool = true
    ) -> Bool {
        guard isVisible, displayRole.allowsInteraction, interactionPolicy.mode != .disabled else {
            return false
        }
        guard requiresAccessibilityTrustForDesktopItems(interactionPolicy) == false || accessibilityTrusted else {
            return false
        }
        return true
    }

    static func shouldAcceptLocalWallpaperMouseEvents(
        runtimeInteractive: Bool,
        displayRole: RenderDisplayRole,
        interactionPolicy: InteractionPolicy,
        plainWindowStyle: Bool
    ) -> Bool {
        guard plainWindowStyle == false,
              runtimeInteractive,
              displayRole.allowsInteraction,
              interactionPolicy.mode != .disabled else {
            return false
        }
        return true
    }

    static func requiresAccessibilityTrustForDesktopItems(_ interactionPolicy: InteractionPolicy) -> Bool {
        interactionPolicy.mode == .desktopEmptyOnly && interactionPolicy.blockDesktopItems
    }
}
