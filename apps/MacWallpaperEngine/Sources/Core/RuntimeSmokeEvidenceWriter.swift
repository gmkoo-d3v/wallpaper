import Foundation

enum RuntimeSmokeEvidenceWriter {
    private struct EvidenceFile: Encodable {
        let schemaVersion: String
        let packagedAppLaunchSmoke: EvidenceEntry
        let liveDesktopClickActions: EvidenceEntry
        let physicalDisplayHotplugSmoke: EvidenceEntry
    }

    private struct EvidenceEntry: Encodable {
        let passed: Bool
        let recordedAt: String
        let evidence: String
        let operatorNote: String?
    }

    static func write(runtime: NativeRuntimeCore, destination: URL) throws -> String {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let recordedAt = ISO8601DateFormatter().string(from: Date())
        let evidence = EvidenceFile(
            schemaVersion: RuntimeCompletionAudit.manualSmokeEvidenceSchemaVersion,
            packagedAppLaunchSmoke: packagedLaunchEntry(runtime: runtime, recordedAt: recordedAt),
            liveDesktopClickActions: liveInteractionEntry(runtime: runtime, recordedAt: recordedAt),
            physicalDisplayHotplugSmoke: physicalDisplayEntry(runtime: runtime, recordedAt: recordedAt)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: destination, options: .atomic)

        return """
        runtime smoke evidence OK
        schemaVersion: \(RuntimeCompletionAudit.manualSmokeEvidenceSchemaVersion)
        path: \(destination.path)
        next: inspect liveDesktopClickActions and physicalDisplayHotplugSmoke, mark passed=true only after the manual checklist is observed, then run --completion-audit --manual-smoke-evidence \(destination.path)
        """
    }

    private static func packagedLaunchEntry(runtime: NativeRuntimeCore, recordedAt: String) -> EvidenceEntry {
        let metadata = packageSigningMetadataText()
        let isPackaged = metadata != nil
        let durationText = runtime.config.duration.map { String(format: "%.2fs", $0) } ?? "manual-exit"
        let packageText = metadata.map { "packageMetadata=\(oneLine($0))" } ?? "packageMetadata=missing"
        let evidence = """
        \(isPackaged ? "packaged" : "source") runtime launch reached graceful termination without crash; appPath=\(Bundle.main.bundlePath); bundle=\(runtime.config.wallpaperRoot.path); duration=\(durationText); displayMode=\(runtime.config.displayMode.cliName); foregroundMode=\(runtime.config.foregroundMode.rawValue); \(packageText)
        """
        return EvidenceEntry(
            passed: isPackaged,
            recordedAt: recordedAt,
            evidence: oneLine(evidence),
            operatorNote: isPackaged
                ? "Auto-generated because the packaged app reached applicationWillTerminate."
                : "Source/unpackaged smoke only. Package the app and rerun before passing packaged-app-launch-smoke."
        )
    }

    private static func liveInteractionEntry(runtime: NativeRuntimeCore, recordedAt: String) -> EvidenceEntry {
        let policy = runtime.manifest.interactionPolicy ?? InteractionPolicy(
            mode: runtime.config.interactive ? .desktopEmptyOnly : .disabled,
            blockApplicationWindows: true,
            blockDesktopItems: true,
            pointerSmoothing: nil,
            pointerSampleFps: nil,
            idleDeadZone: nil,
            directionSwitchMargin: nil,
            defaultClickTailSeconds: nil,
            releaseFadeSeconds: nil
        )
        let primaryRole = RenderDisplayRole(kind: .primary, policy: runtime.manifest.displayPolicy.primary)
        let permission = RuntimeLifecyclePolicy.interactionPermissionStatus(
            runtimeInteractive: runtime.config.interactive,
            displayRole: primaryRole,
            interactionPolicy: policy,
            accessibilityTrusted: DesktopInteractionGate.hasAccessibilityTrust()
        )
        let telemetry = runtime.telemetry.summary()
        let evidence = """
        runtime telemetry captured; accessibilityTrusted=\(DesktopInteractionGate.hasAccessibilityTrust()); permission=\(permission.text); policy=\(policy.mode.rawValue); blockApplicationWindows=\(policy.blockApplicationWindows); blockDesktopItems=\(policy.blockDesktopItems); telemetry=\(telemetry); manual checklist still required: head short tap=boll, head hold/rub>=0.18s=act, body tap=boll, empty click=no-action, left-drag gaze changes direction, app-window/icon blocking verified
        """
        return EvidenceEntry(
            passed: false,
            recordedAt: recordedAt,
            evidence: oneLine(evidence),
            operatorNote: "Auto-generated runtime telemetry only. Set passed=true only after observing head/body/empty/gaze behavior on the trusted packaged app."
        )
    }

    private static func physicalDisplayEntry(runtime: NativeRuntimeCore, recordedAt: String) -> EvidenceEntry {
        let renderPlan = DisplayPlanner.renderSummary(runtime: runtime)
        let lifecycle = runtime.telemetry.displayLifecycleSnapshot()
            .map { "\($0.event)/\($0.status):\($0.detail)" }
            .joined(separator: " | ")
        let evidence = """
        runtime physical display telemetry captured; renderPlan=\(renderPlan); displayLifecycle=\(lifecycle.isEmpty ? "none-recorded" : lifecycle); manual checklist still required: selectedOnly, selectedPolicy, allFull, reconnect or wake, no black frame, no crash
        """
        return EvidenceEntry(
            passed: false,
            recordedAt: recordedAt,
            evidence: oneLine(evidence),
            operatorNote: "Auto-generated runtime telemetry only. Set passed=true only after observing physical display mode and reconnect/wake behavior."
        )
    }

    private static func packageSigningMetadataText() -> String? {
        guard let metadataURL = Bundle.main.resourceURL?.appendingPathComponent("package-signing.txt"),
              FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        return try? String(contentsOf: metadataURL, encoding: .utf8)
    }

    private static func oneLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
