import CoreGraphics
import Foundation

struct SnapshotInputPoint: Decodable, Equatable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

struct SnapshotInputState: Decodable, Equatable {
    let pointerPosition: SnapshotInputPoint?
    let pointerDown: Bool?
    let pointerSpeed: Double?
    let pointerPressDurationSeconds: Double?
    let pointerDragDistance: Double?
    let thermalStateLevel: Double?
    /// Committed-hold state of the interaction snapshot (InteractionSnapshot.isHoldingLoop):
    /// bone-follow bindings follow the cursor only while this is true.
    let holdActive: Bool?
    /// True when at least one `--snapshot-pointer[...]` interaction flag was declared.
    /// Golden fixtures pass a bare pointer position as a declarative BINDING input only;
    /// the hit-zone resolution path must not activate for them.
    var declaresPointerInteraction: Bool { declaresPointerInteractionFlag ?? false }
    private let declaresPointerInteractionFlag: Bool?

    init(
        pointerPosition: SnapshotInputPoint? = nil,
        pointerDown: Bool? = nil,
        pointerSpeed: Double? = nil,
        pointerPressDurationSeconds: Double? = nil,
        pointerDragDistance: Double? = nil,
        thermalStateLevel: Double? = nil,
        holdActive: Bool? = nil,
        declaresPointerInteraction: Bool = false
    ) {
        self.pointerPosition = pointerPosition
        self.pointerDown = pointerDown
        self.pointerSpeed = pointerSpeed
        self.pointerPressDurationSeconds = pointerPressDurationSeconds
        self.pointerDragDistance = pointerDragDistance
        self.thermalStateLevel = thermalStateLevel
        self.holdActive = holdActive
        self.declaresPointerInteractionFlag = declaresPointerInteraction
    }

    func replacing(
        pointerPosition: SnapshotInputPoint? = nil,
        pointerDown: Bool? = nil,
        pointerSpeed: Double? = nil,
        pointerPressDurationSeconds: Double? = nil,
        pointerDragDistance: Double? = nil,
        thermalStateLevel: Double? = nil,
        holdActive: Bool? = nil
    ) -> SnapshotInputState {
        SnapshotInputState(
            pointerPosition: pointerPosition ?? self.pointerPosition,
            pointerDown: pointerDown ?? self.pointerDown,
            pointerSpeed: pointerSpeed ?? self.pointerSpeed,
            pointerPressDurationSeconds: pointerPressDurationSeconds ?? self.pointerPressDurationSeconds,
            pointerDragDistance: pointerDragDistance ?? self.pointerDragDistance,
            thermalStateLevel: thermalStateLevel ?? self.thermalStateLevel,
            holdActive: holdActive ?? self.holdActive,
            declaresPointerInteraction: true
        )
    }

    func evaluationInput(systemTimeSeconds: Double, context: String) throws -> DeclarativeBindingEvaluationInput {
        guard systemTimeSeconds.isFinite, systemTimeSeconds >= 0 else {
            throw EngineError.invalidArgument("\(context) system time must be finite and non-negative")
        }
        let pointer = try validatedPointerPosition(context: context)
        let speed = try validatedNonNegative(pointerSpeed, max: 10, label: "pointerSpeed", context: context)
        let pressDuration = try validatedNonNegative(
            pointerPressDurationSeconds,
            max: 10,
            label: "pointerPressDurationSeconds",
            context: context
        )
        let dragDistance = try validatedNonNegative(
            pointerDragDistance,
            max: 2,
            label: "pointerDragDistance",
            context: context
        )
        let thermal = try validatedNonNegative(thermalStateLevel, max: 3, label: "thermalStateLevel", context: context)
        return DeclarativeBindingEvaluationInput(
            pointerPosition: pointer,
            pointerDown: pointerDown ?? false,
            pointerSpeed: speed,
            pointerPressDurationSeconds: pressDuration,
            pointerDragDistance: dragDistance,
            systemTimeSeconds: systemTimeSeconds,
            thermalStateLevel: thermal,
            holdActive: holdActive ?? false
        )
    }

    var summary: String {
        var parts: [String] = []
        if let pointerPosition {
            parts.append(String(format: "pointer=%.3f,%.3f", pointerPosition.x, pointerPosition.y))
        }
        if let pointerDown {
            parts.append("down=\(pointerDown)")
        }
        if let pointerSpeed {
            parts.append(String(format: "speed=%.3f", pointerSpeed))
        }
        if let pointerPressDurationSeconds {
            parts.append(String(format: "press=%.3f", pointerPressDurationSeconds))
        }
        if let pointerDragDistance {
            parts.append(String(format: "drag=%.3f", pointerDragDistance))
        }
        if let thermalStateLevel {
            parts.append(String(format: "thermal=%.3f", thermalStateLevel))
        }
        if let holdActive {
            parts.append("hold=\(holdActive)")
        }
        return parts.isEmpty ? "default" : parts.joined(separator: ",")
    }

    private func validatedPointerPosition(context: String) throws -> CGPoint {
        guard let pointerPosition else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        guard pointerPosition.x.isFinite,
              pointerPosition.y.isFinite,
              pointerPosition.x >= 0,
              pointerPosition.x <= 1,
              pointerPosition.y >= 0,
              pointerPosition.y <= 1 else {
            throw EngineError.invalidArgument("\(context) pointerPosition must be normalized x/y in 0...1")
        }
        return CGPoint(x: pointerPosition.x, y: pointerPosition.y)
    }

    private func validatedNonNegative(
        _ value: Double?,
        max maxValue: Double,
        label: String,
        context: String
    ) throws -> Double {
        guard let value else { return 0 }
        guard value.isFinite, value >= 0, value <= maxValue else {
            throw EngineError.invalidArgument("\(context) \(label) must be finite and within 0...\(maxValue)")
        }
        return value
    }
}
