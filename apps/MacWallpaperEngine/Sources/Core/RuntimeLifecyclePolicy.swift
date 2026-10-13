import Foundation

struct DesktopInteractionPermissionStatus {
    let text: String
}

enum WindowWarmupMoment: Equatable {
    case beforeOrderFront
    case afterOrderFront
}

enum DisplayRebuildCommitDecision: Equatable {
    case commit
    case rollback(reason: String)

    var shouldCommit: Bool {
        switch self {
        case .commit:
            return true
        case .rollback:
            return false
        }
    }
}

enum RuntimeLifecyclePolicy {
    static let startupFailurePolicy = "control-panel-recovery"
    static let visibilityPausePolicy = "pause-when-occluded-or-fullscreen-obscured"
    static let desktopItemTrustPolicy = "precise-with-accessibility-trust-best-effort-without"
    static let missingTrustInteractionDegradePolicy = "global-monitors-without-accessibility-trust"
    static let displayRebuildPolicy = "debounced-atomic-rollback"
    static let runningHostReplacementPolicy = "start-replacement-before-retiring-current-host"
    static let rendererFailureRecoveryPolicy = RendererRecoveryPolicy.policyName
    static let outsideContentTrackingPolicy = "ignore-same-window-outside-content-without-idle-reset"
    static let blockedDesktopEventTrackingPolicy = "ignore-blocked-desktop-events-without-idle-reset"
    static let accessibilityPromptPolicy = AccessibilityPromptPolicy.defaultPolicy.rawValue
    static let rendererWarmupFallbackPolicy = "preview-last-frame-or-neutral-background-before-first-pause"
    static let visibleWindowFirstDrawPolicy = "preorder-and-postorder-bounded-visible-draw-retries"
    static let displayRebuildDebounceSeconds: TimeInterval = 0.25
    static let displayReplacementOverlapSeconds: TimeInterval = 0.5
    static let displayReplacementRevealTimeoutSeconds: TimeInterval = 1.0
    static let visibleWindowWarmupRetryCount = 6
    static let visibleWindowWarmupRetryInterval: TimeInterval = 0.05
    static let defaultDisplayModeForNewBundle: DisplayMode = .primaryOnly

    static func shouldRecoverStartupFailureInControlPanel(launchControlPanel: Bool) -> Bool {
        launchControlPanel
    }

    static func displayRebuildCommitDecision(
        existingWindowCount: Int,
        replacementWindowCount: Int,
        isInitialBuild: Bool
    ) -> DisplayRebuildCommitDecision {
        if replacementWindowCount > 0 || isInitialBuild || existingWindowCount == 0 {
            return .commit
        }
        return .rollback(
            reason: "display rebuild produced no replacement windows; preserving \(existingWindowCount) existing wallpaper window(s)"
        )
    }

    static func shouldPauseForWindowVisibility(isVisible: Bool, displayPolicy: DisplayPolicy) -> Bool {
        guard isVisible == false else { return false }
        return displayPolicy.occluded == .pause || displayPolicy.fullscreenObscured == .pause
    }

    static func effectiveRendererVisibility(
        windowIsVisible: Bool,
        occlusionVisible: Bool,
        hasPresentedVisibleWindow: Bool
    ) -> Bool {
        if occlusionVisible {
            return true
        }
        if windowIsVisible == false && hasPresentedVisibleWindow == false {
            return true
        }
        return false
    }

    static func effectiveInteractionMonitorVisibility(
        windowIsVisible: Bool,
        hasPresentedVisibleWindow: Bool,
        startsHidden: Bool
    ) -> Bool {
        if windowIsVisible {
            return true
        }
        return hasPresentedVisibleWindow == false && startsHidden == false
    }

    static func windowWarmupMoments(startHidden: Bool) -> [WindowWarmupMoment] {
        startHidden ? [] : [.beforeOrderFront, .afterOrderFront]
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
        return true
    }

    static func shouldAcceptLocalWallpaperMouseEvents(
        runtimeInteractive: Bool,
        displayRole: RenderDisplayRole,
        interactionPolicy: InteractionPolicy,
        plainWindowStyle: Bool,
        captureDesktopInput: Bool,
        hasDeclaredInteractions: Bool
    ) -> Bool {
        guard runtimeInteractive,
              displayRole.allowsInteraction,
              interactionPolicy.mode != .disabled,
              hasDeclaredInteractions else {
            return false
        }
        if plainWindowStyle {
            return shouldRouteDirectWallpaperMouseEvents(interactionPolicy: interactionPolicy)
        }
        return captureDesktopInput
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

    static func shouldHandleDirectWallpaperMouseEvents(
        interactionPolicy: InteractionPolicy,
        monitorDeliversLocalEvents: Bool
    ) -> Bool {
        guard monitorDeliversLocalEvents == false else {
            return false
        }
        return shouldRouteDirectWallpaperMouseEvents(interactionPolicy: interactionPolicy)
    }

    /// Trust is read for every enabled interaction mode: the listen-only CGEventTap
    /// path needs Accessibility, so diagnostics must know the real trust state even
    /// when desktop-item blocking is off.
    static func requiresAccessibilityTrustForDesktopItems(_ interactionPolicy: InteractionPolicy) -> Bool {
        interactionPolicy.mode != .disabled
    }

    static func interactionPermissionStatus(
        runtimeInteractive: Bool,
        displayRole: RenderDisplayRole,
        interactionPolicy: InteractionPolicy,
        accessibilityTrusted: Bool
    ) -> DesktopInteractionPermissionStatus {
        guard runtimeInteractive else {
            return DesktopInteractionPermissionStatus(text: "OFF / runtime setting")
        }
        guard displayRole.allowsInteraction else {
            return DesktopInteractionPermissionStatus(text: "PASSIVE / secondary display")
        }
        guard interactionPolicy.mode != .disabled else {
            return DesktopInteractionPermissionStatus(text: "OFF / wallpaper policy")
        }
        if interactionPolicy.mode == .desktopEmptyOnly, interactionPolicy.blockDesktopItems {
            _ = accessibilityTrusted
            return DesktopInteractionPermissionStatus(text: "READY / \(interactionPolicy.mode.rawValue) / desktop-gated")
        }
        return DesktopInteractionPermissionStatus(text: "READY / \(interactionPolicy.mode.rawValue)")
    }

    static func interactionControlPanelText(
        permissionStatus: DesktopInteractionPermissionStatus,
        isHostRunning: Bool,
        monitorSnapshot: InteractionMonitorTelemetrySnapshot?
    ) -> String {
        guard permissionStatus.text.hasPrefix("READY")
        else {
            return permissionStatus.text
        }
        guard isHostRunning else {
            return "\(permissionStatus.text) / stopped"
        }
        guard let monitorSnapshot else {
            return "\(permissionStatus.text) / starting"
        }

        let sourceState: String
        if monitorSnapshot.eventTapActive {
            sourceState = "tap"
        } else if monitorSnapshot.localMonitorActive {
            sourceState = "local"
        } else if monitorSnapshot.globalMonitorCount > 0 {
            sourceState = "global:\(monitorSnapshot.globalMonitorCount)"
        } else {
            sourceState = "idle"
        }

        guard monitorSnapshot.active else {
            return "\(permissionStatus.text) / \(sourceState)"
        }
        return "\(permissionStatus.text) / \(sourceState) / cmd \(monitorSnapshot.lastCommand)"
    }
}
