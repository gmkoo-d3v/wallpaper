import CoreGraphics
import Foundation

enum RuntimeSmokeEvidenceWriter {
    private struct LiveInteractionExpectation {
        let id: String
        let zoneID: String?
        let action: String?
        let isEmptyClick: Bool

        var label: String {
            if isEmptyClick {
                return "empty-click:no-action"
            }
            if let zoneID, let action {
                return "\(zoneID):\(action)"
            }
            if let action {
                return "default:\(action)"
            }
            return id
        }
    }

    private struct EvidenceFile: Encodable {
        let schemaVersion: String
        let packagedAppLaunchSmoke: EvidenceEntry
        let liveDesktopClickActions: EvidenceEntry
        let physicalDisplayHotplugSmoke: EvidenceEntry
        let blackFrameFlickerSmoke: EvidenceEntry
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
            physicalDisplayHotplugSmoke: physicalDisplayEntry(runtime: runtime, recordedAt: recordedAt),
            blackFrameFlickerSmoke: blackFrameFlickerEntry(runtime: runtime, recordedAt: recordedAt)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: destination, options: .atomic)

        return """
        runtime smoke evidence OK
        schemaVersion: \(RuntimeCompletionAudit.manualSmokeEvidenceSchemaVersion)
        path: \(destination.path)
        next: inspect liveDesktopClickActions, physicalDisplayHotplugSmoke, and blackFrameFlickerSmoke; mark passed=true only after the manual checklist is observed, then run --completion-audit --manual-smoke-evidence \(destination.path)
        """
    }

    private static func packagedLaunchEntry(runtime: NativeRuntimeCore, recordedAt: String) -> EvidenceEntry {
        let metadata = packageRuntimeMetadataText()
        let isPackaged = metadata != nil
        let durationText = runtime.config.duration.map { String(format: "%.2fs", $0) } ?? "manual-exit"
        let packageText = metadata.map { "packageRuntimeMetadata=\(oneLine($0))" } ?? "packageRuntimeMetadata=missing"
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
        let liveProof = liveInteractionProof(runtime: runtime)
        let checklistText = liveProof.checklist.isEmpty ? "no manifest-declared click/gaze checklist" : liveProof.checklist
        let evidence = """
        runtime telemetry captured; inputPolicy=no-permission-best-effort; accessibilityAPIUsed=false; permission=\(permission.text); policy=\(policy.mode.rawValue); blockApplicationWindows=\(policy.blockApplicationWindows); blockDesktopItems=\(policy.blockDesktopItems); manifestChecklist=\(checklistText); \(liveProof.evidence); telemetry=\(telemetry); \(liveProof.passed ? "live checklist satisfied by packaged telemetry for manifest-declared interactions" : "manual checklist still required for manifest-declared interactions and application-window gating")
        """
        return EvidenceEntry(
            passed: liveProof.passed,
            recordedAt: recordedAt,
            evidence: oneLine(evidence),
            operatorNote: liveProof.passed
                ? "Auto-passed because packaged runtime telemetry observed every manifest-declared live click/gaze action."
                : "Auto-generated runtime telemetry only. Set passed=true only after observing the manifest-declared click/gaze checklist on the packaged app. Do not grant Accessibility for this smoke."
        )
    }

    private static func physicalDisplayEntry(runtime: NativeRuntimeCore, recordedAt: String) -> EvidenceEntry {
        let renderPlan = DisplayPlanner.renderSummary(runtime: runtime)
        let modeMatrix = physicalDisplayModeMatrix(runtime: runtime)
        let lifecycle = runtime.telemetry.displayLifecycleSnapshot()
            .map { "\($0.event)/\($0.status):\($0.detail)" }
            .joined(separator: " | ")
        let evidence = """
        runtime physical display telemetry captured; renderPlan=\(renderPlan); physicalDisplayModeMatrix=\(modeMatrix); displayLifecycle=\(lifecycle.isEmpty ? "none-recorded" : lifecycle); manual checklist still required: reconnect or wake and restored wallpaper windows on target displays
        """
        return EvidenceEntry(
            passed: false,
            recordedAt: recordedAt,
            evidence: oneLine(evidence),
            operatorNote: "Auto-generated runtime telemetry only. Set passed=true only after observing physical display mode and reconnect/wake behavior."
        )
    }

    private static func blackFrameFlickerEntry(runtime: NativeRuntimeCore, recordedAt: String) -> EvidenceEntry {
        let modeMatrix = physicalDisplayModeMatrix(runtime: runtime)
        let lifecycle = runtime.telemetry.displayLifecycleSnapshot()
            .map { "\($0.event)/\($0.status):\($0.detail)" }
            .joined(separator: " | ")
        let evidence = """
        runtime black-frame/flicker telemetry captured; foregroundMode=\(runtime.config.foregroundMode.rawValue); displayMode=\(runtime.config.displayMode.cliName); physicalDisplayModeMatrix=\(modeMatrix); displayLifecycle=\(lifecycle.isEmpty ? "none-recorded" : lifecycle); manual checklist still required: visually observe packaged mode switch, display rebuild or wake, no black frame, no visible flicker loop, no crash
        """
        return EvidenceEntry(
            passed: false,
            recordedAt: recordedAt,
            evidence: oneLine(evidence),
            operatorNote: "Auto-generated runtime telemetry only. Set passed=true only after observing black-frame/flicker behavior on the packaged app."
        )
    }

    private static func physicalDisplayModeMatrix(runtime: NativeRuntimeCore) -> String {
        [
            ("selectedOnly", DisplayMode.primaryOnly),
            ("selectedPolicy", DisplayMode.primaryAnimated),
            ("allFull", DisplayMode.all)
        ].map { label, mode in
            "\(label)={\(oneLine(DisplayPlanner.renderSummary(runtime: runtime, displayMode: mode)))}"
        }.joined(separator: " | ")
    }

    private static func liveInteractionProof(runtime: NativeRuntimeCore) -> (passed: Bool, evidence: String, checklist: String) {
        let observations = runtime.telemetry.interactionObservationSnapshot()
        let plan = InteractionPlan(
            interactions: runtime.manifest.interactions,
            policy: runtime.manifest.interactionPolicy,
            actionTailDurations: (try? SpineAnimationDiagnostics.tapActionDurations(runtime: runtime)) ?? [:]
        )

        let clickExpectations = liveClickExpectations(plan: plan)
        let expectedMoveCommands = pointerMoveCommands(manifest: runtime.manifest)
        var satisfiedClickExpectations = Set<String>()
        var satisfiedMoveCommands = Set<String>()

        for observation in observations where observation.decision == "delivered" {
            let point = normalizedPoint(observation.point)
            let command = observation.command
            let event = observation.event
            if expectedMoveCommands.contains(command),
               event == "move" || event == "drag" {
                satisfiedMoveCommands.insert(command)
            }
            guard let point, let button = button(from: event) else { continue }
            let hit = plan.hitTest(point: point, button: button)
            for expectation in clickExpectations {
                if expectation.isEmptyClick {
                    if hit == nil,
                       observation.clickPulse <= 0.05,
                       clickActionCommands(expectations: clickExpectations).contains(command) == false {
                        satisfiedClickExpectations.insert(expectation.id)
                    }
                    continue
                }
                guard observation.clickPulse > 0 else { continue }
                if expectation.zoneID == hit?.zoneID,
                   expectation.action == command {
                    satisfiedClickExpectations.insert(expectation.id)
                }
            }
        }

        let packaged = packageRuntimeMetadataText() != nil
        let clickExpectationsPassed = clickExpectations.allSatisfy { satisfiedClickExpectations.contains($0.id) }
        let moveExpectationsPassed = expectedMoveCommands.isSubset(of: satisfiedMoveCommands)
        let passed = packaged
            && clickExpectationsPassed
            && moveExpectationsPassed
        let expectedLabels = (clickExpectations.map(\.label) + (expectedMoveCommands.isEmpty ? [] : ["gaze:\(expectedMoveCommands.sorted().joined(separator: "/"))"]))
        let missingMoveCommands = expectedMoveCommands.subtracting(satisfiedMoveCommands)
        let missingLabels = clickExpectations
            .filter { satisfiedClickExpectations.contains($0.id) == false }
            .map(\.label)
            + (missingMoveCommands.isEmpty ? [] : ["gaze:\(missingMoveCommands.sorted().joined(separator: "/"))"])
        let evidence = [
            "live telemetry proof:",
            "packaged=\(packaged)",
            "inputPolicy=no-permission-best-effort",
            "expected=\(expectedLabels.joined(separator: ","))",
            "satisfied=\(satisfiedClickExpectations.sorted().joined(separator: ","))",
            "satisfiedGaze=\(satisfiedMoveCommands.sorted().joined(separator: "/"))",
            "missing=\(missingLabels.joined(separator: ","))",
            "gazeComplete=\(moveExpectationsPassed)",
            "observations=\(observations.count)"
        ].joined(separator: " ")
        return (passed, evidence, expectedLabels.joined(separator: ","))
    }

    private static func liveClickExpectations(plan: InteractionPlan) -> [LiveInteractionExpectation] {
        var expectations: [LiveInteractionExpectation] = []
        for zone in plan.hitZoneSummaries() {
            if let tapAction = zone.tapAction {
                expectations.append(LiveInteractionExpectation(
                    id: "zone:\(zone.id):tap:\(tapAction)",
                    zoneID: zone.id,
                    action: tapAction,
                    isEmptyClick: false
                ))
            }
            if let rubAction = zone.rubAction {
                expectations.append(LiveInteractionExpectation(
                    id: "zone:\(zone.id):rub:\(rubAction)",
                    zoneID: zone.id,
                    action: rubAction,
                    isEmptyClick: false
                ))
            }
            expectations.append(LiveInteractionExpectation(
                id: "zone:\(zone.id):action:\(zone.action)",
                zoneID: zone.id,
                action: zone.action,
                isEmptyClick: false
            ))
        }
        if let defaultAction = plan.defaultActionSummary() {
            expectations.append(LiveInteractionExpectation(
                id: "default:\(defaultAction.action)",
                zoneID: "default",
                action: defaultAction.action,
                isEmptyClick: false
            ))
        } else if expectations.isEmpty == false {
            expectations.append(LiveInteractionExpectation(
                id: "empty-click:no-action",
                zoneID: nil,
                action: nil,
                isEmptyClick: true
            ))
        }
        return expectations
    }

    private static func pointerMoveCommands(manifest: WallpaperNativeManifest) -> Set<String> {
        guard let actions = manifest.interactions.first(where: { $0.event == .pointerMove })?.actions else {
            return []
        }
        let idle = actions["idle"] ?? "idle"
        return Set(actions.values.filter { $0 != idle })
    }

    private static func clickActionCommands(expectations: [LiveInteractionExpectation]) -> Set<String> {
        Set(expectations.compactMap(\.action))
    }

    private static func button(from event: String) -> PointerButton? {
        if event.hasPrefix("left") || event == "drag" {
            return .left
        }
        if event.hasPrefix("right") {
            return .right
        }
        return nil
    }

    private static func normalizedPoint(_ text: String) -> CGPoint? {
        let parts = text.split(separator: ",")
        guard parts.count == 2,
              let x = Double(String(parts[0])),
              let y = Double(String(parts[1])),
              x.isFinite,
              y.isFinite,
              x >= 0,
              x <= 1,
              y >= 0,
              y <= 1 else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    private static func packageRuntimeMetadataText() -> String? {
        guard let metadataURL = Bundle.main.resourceURL?.appendingPathComponent("package-runtime.txt"),
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
