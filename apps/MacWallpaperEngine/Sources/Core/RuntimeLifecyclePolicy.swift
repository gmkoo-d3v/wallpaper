import Foundation

struct DesktopInteractionPermissionStatus {
    let text: String
    let canRequestAccessibilityPermission: Bool
}

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
        guard plainWindowStyle,
              runtimeInteractive,
              displayRole.allowsInteraction,
              interactionPolicy.mode != .disabled else {
            return false
        }
        return shouldRouteDirectWallpaperMouseEvents(interactionPolicy: interactionPolicy)
    }

    static func shouldRouteDirectWallpaperMouseEvents(
        interactionPolicy: InteractionPolicy
    ) -> Bool {
        switch interactionPolicy.mode {
        case .always:
            return true
        case .desktopEmptyOnly:
            return interactionPolicy.blockDesktopItems == false
        case .disabled:
            return false
        }
    }

    static func requiresAccessibilityTrustForDesktopItems(_ interactionPolicy: InteractionPolicy) -> Bool {
        interactionPolicy.mode == .desktopEmptyOnly && interactionPolicy.blockDesktopItems
    }

    static func interactionPermissionStatus(
        runtimeInteractive: Bool,
        displayRole: RenderDisplayRole,
        interactionPolicy: InteractionPolicy,
        accessibilityTrusted: Bool
    ) -> DesktopInteractionPermissionStatus {
        guard runtimeInteractive else {
            return DesktopInteractionPermissionStatus(
                text: "INTERACTION OFF / disabled in runtime settings",
                canRequestAccessibilityPermission: false
            )
        }
        guard displayRole.allowsInteraction else {
            return DesktopInteractionPermissionStatus(
                text: "INTERACTION PASSIVE / selected display role does not receive desktop input",
                canRequestAccessibilityPermission: false
            )
        }
        guard interactionPolicy.mode != .disabled else {
            return DesktopInteractionPermissionStatus(
                text: "INTERACTION OFF / disabled by wallpaper policy",
                canRequestAccessibilityPermission: false
            )
        }
        guard requiresAccessibilityTrustForDesktopItems(interactionPolicy) else {
            return DesktopInteractionPermissionStatus(
                text: "INTERACTION READY / \(interactionPolicy.mode.rawValue)",
                canRequestAccessibilityPermission: false
            )
        }
        guard accessibilityTrusted else {
            return DesktopInteractionPermissionStatus(
                text: "INTERACTION BLOCKED / grant macOS Accessibility permission for desktop icon-safe mode",
                canRequestAccessibilityPermission: true
            )
        }
        return DesktopInteractionPermissionStatus(
            text: "INTERACTION READY / Accessibility trusted",
            canRequestAccessibilityPermission: false
        )
    }
}
