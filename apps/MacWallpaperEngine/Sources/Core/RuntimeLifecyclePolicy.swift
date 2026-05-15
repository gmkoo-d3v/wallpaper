enum RuntimeLifecyclePolicy {
    static let startupFailurePolicy = "control-panel-recovery"

    static func shouldRecoverStartupFailureInControlPanel(launchControlPanel: Bool) -> Bool {
        launchControlPanel
    }
}
