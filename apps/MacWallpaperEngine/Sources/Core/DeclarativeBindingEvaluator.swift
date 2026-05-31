import CoreGraphics
import Foundation

struct DeclarativeBindingEvaluationInput {
    let pointerPosition: CGPoint
    let pointerDown: Bool
    let systemTimeSeconds: Double
    let thermalStateLevel: Double

    init(
        pointerPosition: CGPoint = CGPoint(x: 0.5, y: 0.5),
        pointerDown: Bool = false,
        systemTimeSeconds: Double = 0,
        thermalStateLevel: Double = 0
    ) {
        self.pointerPosition = pointerPosition
        self.pointerDown = pointerDown
        self.systemTimeSeconds = systemTimeSeconds
        self.thermalStateLevel = thermalStateLevel
    }
}

struct DeclarativeBindingEvaluationSnapshot {
    let effectProperties: [String: [String: Double]]
    let spineBoneRotationOffsets: [String: Double]

    func number(effectID: String, property: String) -> Double? {
        effectProperties[effectID]?[property]
    }
}

struct DeclarativeBindingEvaluationState {
    fileprivate var springStates: [String: DeclarativeBindingSpringState] = [:]
}

private struct DeclarativeBindingSpringState {
    var value: Double
    var velocity: Double
    var lastTimeSeconds: Double
}

enum DeclarativeBindingEvaluator {
    private static let maxSpringCatchUpSeconds = 0.25

    static func evaluate(
        plan: DeclarativeBindingPlan,
        input: DeclarativeBindingEvaluationInput
    ) -> DeclarativeBindingEvaluationSnapshot {
        var effectProperties: [String: [String: Double]] = [:]
        var spineBoneRotationOffsets: [String: Double] = [:]
        for binding in plan.mapRangeEffectBindings {
            guard let property = binding.target.propertyPath,
                  let sourceValue = numericSourceValue(for: binding.source, input: input),
                  let mapped = mapRange(sourceValue, adapter: binding.adapter) else {
                continue
            }
            effectProperties[binding.target.id, default: [:]][property] = mapped
        }
        for binding in plan.smoothLookAtBoneBindings {
            let offset = smoothLookAtRotationOffset(binding: binding, pointer: input.pointerPosition)
            spineBoneRotationOffsets[binding.target.id, default: 0] += offset
        }
        return DeclarativeBindingEvaluationSnapshot(
            effectProperties: effectProperties,
            spineBoneRotationOffsets: spineBoneRotationOffsets
        )
    }

    static func evaluate(
        plan: DeclarativeBindingPlan,
        input: DeclarativeBindingEvaluationInput,
        state: inout DeclarativeBindingEvaluationState
    ) -> DeclarativeBindingEvaluationSnapshot {
        let baseSnapshot = evaluate(plan: plan, input: input)
        var effectProperties = baseSnapshot.effectProperties

        for binding in plan.springEffectBindings {
            guard let property = binding.target.propertyPath,
                  let sourceValue = numericSourceValue(for: binding.source, input: input),
                  let target = springTargetValue(sourceValue, adapter: binding.adapter) else {
                continue
            }
            let value = advanceSpring(
                bindingID: binding.id,
                target: target,
                timeSeconds: input.systemTimeSeconds,
                adapter: binding.adapter,
                state: &state
            )
            effectProperties[binding.target.id, default: [:]][property] = value
        }

        return DeclarativeBindingEvaluationSnapshot(
            effectProperties: effectProperties,
            spineBoneRotationOffsets: baseSnapshot.spineBoneRotationOffsets
        )
    }

    private static func smoothLookAtRotationOffset(
        binding: DeclarativeBindingPlanEntry,
        pointer: CGPoint
    ) -> Double {
        let deadZone = binding.adapter.deadZone.map {
            CGPoint(x: $0.x, y: $0.y)
        } ?? CGPoint(x: 0, y: 0)
        let neutralPoint = binding.adapter.neutralPoint.map {
            CGPoint(x: $0.x, y: $0.y)
        } ?? CGPoint(x: 0.5, y: 0.5)
        let dx = Double(pointer.x - neutralPoint.x)
        let dy = Double(pointer.y - neutralPoint.y)
        let activeX = abs(dx) <= Double(deadZone.x) ? 0 : dx
        let activeY = abs(dy) <= Double(deadZone.y) ? 0 : dy
        let xFactor = binding.adapter.factor?.first ?? 0
        let yFactor = binding.adapter.factor?.dropFirst().first ?? 0
        return activeX * xFactor + activeY * yFactor
    }

    private static func numericSourceValue(
        for source: BindingSource,
        input: DeclarativeBindingEvaluationInput
    ) -> Double? {
        switch source {
        case .pointerPosition:
            return Double(input.pointerPosition.x)
        case .pointerDown:
            return input.pointerDown ? 1 : 0
        case .systemTime:
            return input.systemTimeSeconds
        case .thermalState:
            return input.thermalStateLevel
        }
    }

    private static func mapRange(_ sourceValue: Double, adapter: BindingAdapter) -> Double? {
        guard let inputRange = adapter.inputRange,
              let outputRange = adapter.outputRange,
              inputRange.count == outputRange.count,
              inputRange.count >= 2 else {
            return nil
        }
        let scaledValue = sourceValue * (adapter.factor?.first ?? 1.0)
        let rangedValue = adapter.loop == true ? loopedValue(scaledValue, inputRange: inputRange) : scaledValue
        for index in 0..<(inputRange.count - 1) {
            let start = inputRange[index]
            let end = inputRange[index + 1]
            let lower = min(start, end)
            let upper = max(start, end)
            guard rangedValue >= lower, rangedValue <= upper else { continue }
            let denominator = end - start
            let rawT = denominator == 0 ? 0 : (rangedValue - start) / denominator
            let t = interpolationValue(rawT, interpolation: adapter.interpolation)
            return outputRange[index] + (outputRange[index + 1] - outputRange[index]) * t
        }

        let nearestIndex = inputRange.indices.min {
            abs(inputRange[$0] - rangedValue) < abs(inputRange[$1] - rangedValue)
        } ?? 0
        return outputRange[nearestIndex]
    }

    private static func springTargetValue(_ sourceValue: Double, adapter: BindingAdapter) -> Double? {
        if adapter.inputRange != nil || adapter.outputRange != nil {
            return mapRange(sourceValue, adapter: adapter)
        }
        return sourceValue * (adapter.factor?.first ?? 1.0)
    }

    private static func advanceSpring(
        bindingID: String,
        target: Double,
        timeSeconds: Double,
        adapter: BindingAdapter,
        state: inout DeclarativeBindingEvaluationState
    ) -> Double {
        guard target.isFinite, timeSeconds.isFinite else {
            return state.springStates[bindingID]?.value ?? 0
        }
        guard var spring = state.springStates[bindingID] else {
            state.springStates[bindingID] = DeclarativeBindingSpringState(
                value: target,
                velocity: 0,
                lastTimeSeconds: timeSeconds
            )
            return target
        }

        let step = min(max(adapter.fixedStepSeconds ?? (1.0 / 60.0), 0.004), 0.067)
        let elapsed = min(max(timeSeconds - spring.lastTimeSeconds, 0), maxSpringCatchUpSeconds)
        var remaining = elapsed
        while remaining > 0.000001 {
            let dt = min(step, remaining)
            integrateSpring(&spring, target: target, dt: dt, adapter: adapter)
            remaining -= dt
        }
        spring.lastTimeSeconds = timeSeconds
        state.springStates[bindingID] = spring
        return spring.value
    }

    private static func integrateSpring(
        _ state: inout DeclarativeBindingSpringState,
        target: Double,
        dt: Double,
        adapter: BindingAdapter
    ) {
        let stiffness = max(adapter.stiffness ?? 100, 0.0001)
        let damping = max(adapter.damping ?? 10, 0)
        let mass = max(adapter.mass ?? 1, 0.0001)
        let maxVelocity = max(adapter.maxVelocity ?? 10_000, 0.0001)
        let displacement = target - state.value
        let acceleration = (stiffness * displacement - damping * state.velocity) / mass
        state.velocity = min(max(state.velocity + acceleration * dt, -maxVelocity), maxVelocity)
        state.value += state.velocity * dt

        let epsilon = max(adapter.settleEpsilon ?? 0.0001, 0.000001)
        if abs(target - state.value) <= epsilon, abs(state.velocity) <= epsilon {
            state.value = target
            state.velocity = 0
        }
    }

    private static func loopedValue(_ value: Double, inputRange: [Double]) -> Double {
        guard let start = inputRange.first,
              let end = inputRange.last,
              start.isFinite,
              end.isFinite,
              value.isFinite,
              end > start else {
            return value
        }
        let span = end - start
        let shifted = (value - start).truncatingRemainder(dividingBy: span)
        return start + (shifted < 0 ? shifted + span : shifted)
    }

    private static func interpolationValue(
        _ value: Double,
        interpolation: BindingInterpolation?
    ) -> Double {
        let t = min(max(value, 0), 1)
        switch interpolation ?? .linear {
        case .linear:
            return t
        case .smoothStep:
            return t * t * (3 - 2 * t)
        case .spring:
            return t
        }
    }
}
