import CoreGraphics
import Foundation

/// Resolves a declarative wallpaper-snapshot input (`--wallpaper-snapshot
/// --snapshot-pointer[...]`) through the SAME pointer→hit-zone→command resolution the live
/// path runs (InteractionPlan + InteractionController), so snapshot PNGs render the pose the
/// gimmick would show for that input instead of a fixed `--snapshot-action` name.
/// The controller replay (replaySnapshotInput) owns the command/gaze/hold resolution; this
/// type only maps the resulting InteractionSnapshot to the renderer draw parameters and
/// exposes the resolution as diagnostic text.
enum SnapshotInteractionResolver {
    struct Resolution {
        let command: String
        let pointer: CGPoint
        let gazeWeights: [(action: String, weight: Double)]
        let holdActive: Bool
        let pressActive: Bool
        let hitSummary: String

        /// One-line summary for the snapshot output: the resolved command plus the hit-zone
        /// the pointer landed on (or "none"), so the PNG's pose is attributable to a zone.
        var summary: String {
            "resolved: command=\(command) hit=\(hitSummary) hold=\(holdActive ? "loop" : "off") gaze=\(gazeWeights.isEmpty ? "none" : gazeWeights.map { "\($0.action)@\(String(format: "%.2f", $0.weight))" }.joined(separator: "+"))"
        }
    }

    static func resolve(
        runtime: NativeRuntimeCore,
        inputState: SnapshotInputState,
        time: Double,
        actionTailDurations: [String: CFTimeInterval]
    ) throws -> Resolution {
        let bindingInput = try inputState.evaluationInput(systemTimeSeconds: time, context: "wallpaper snapshot")
        let clockValue = time
        let controller = InteractionController(
            interactions: runtime.manifest.interactions,
            policy: runtime.manifest.interactionPolicy,
            actionTailDurations: actionTailDurations,
            declarativePlan: DeclarativeBindingPlan(manifest: runtime.manifest),
            clock: { clockValue }
        )
        let snapshot = controller.replaySnapshotInput(
            pointer: bindingInput.pointerPosition,
            pointerDown: bindingInput.pointerDown,
            pressDurationSeconds: Double(bindingInput.pointerPressDurationSeconds),
            dragDistance: Double(bindingInput.pointerDragDistance),
            now: time
        )
        let plan = InteractionPlan(
            interactions: runtime.manifest.interactions,
            policy: runtime.manifest.interactionPolicy,
            actionTailDurations: actionTailDurations,
            declarativePlan: DeclarativeBindingPlan(manifest: runtime.manifest)
        )
        let hit = plan.hitTest(point: plan.clamp(bindingInput.pointerPosition), button: .left)
        // A declared holdActive overrides the replayed press state (the bone-follow gate),
        // keeping the pre-existing --snapshot-hold semantics for declarative bindings.
        let holdActive = inputState.holdActive ?? snapshot.isHoldingLoop
        return Resolution(
            command: snapshot.command,
            pointer: CGPoint(x: snapshot.pointer.x, y: snapshot.pointer.y),
            gazeWeights: snapshot.gazeWeights,
            holdActive: holdActive,
            pressActive: bindingInput.pointerDown,
            hitSummary: hit.map { "zone=\($0.zoneID) action=\($0.action) trigger=\($0.trigger.rawValue)" } ?? "none"
        )
    }
}
