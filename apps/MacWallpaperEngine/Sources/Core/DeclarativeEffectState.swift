import Foundation
import simd

struct DeclarativeEffectState {
    let colorMultiplier: SIMD4<Float>
    let textureOffset: SIMD2<Float>
    let fragmentEffectParams: SIMD4<Float>
    let fragmentEffectParams2: SIMD4<Float>

    static let identity = DeclarativeEffectState(
        colorMultiplier: SIMD4<Float>(1, 1, 1, 1),
        textureOffset: SIMD2<Float>(0, 0),
        fragmentEffectParams: SIMD4<Float>(0, 0, 0, 0),
        fragmentEffectParams2: SIMD4<Float>(1, 0, 0, 0)
    )

    static func make(
        plan: DeclarativeBindingPlan,
        snapshot: DeclarativeBindingEvaluationSnapshot
    ) -> DeclarativeEffectState {
        var colorMultiplier = SIMD4<Float>(1, 1, 1, 1)
        var textureOffset = SIMD2<Float>(0, 0)
        var blurRadiusPixels: Double = 0
        var chromaticOffsetPixels: Double = 0
        var vignetteIntensity: Double = 0
        var vignetteRadius: Double = 0.55
        var saturation: Double = 1

        for effect in plan.effectEntries where effect.effectKind == EffectType.colorMatrix.rawValue {
            let brightness = number(
                effect: effect,
                property: "brightness",
                snapshot: snapshot,
                fallback: 0
            )
            let alpha = number(
                effect: effect,
                property: "opacity",
                snapshot: snapshot,
                fallback: number(
                    effect: effect,
                    property: "alpha",
                    snapshot: snapshot,
                    fallback: 1
                )
            )
            let effectSaturation = number(
                effect: effect,
                property: "saturation",
                snapshot: snapshot,
                fallback: 1
            )
            let rgbScale = Float(min(max(1.0 + brightness, 0), 2))
            let alphaScale = Float(min(max(alpha, 0), 1))
            colorMultiplier *= SIMD4<Float>(rgbScale, rgbScale, rgbScale, alphaScale)
            saturation *= min(max(effectSaturation, 0), 2)
        }

        for effect in plan.effectEntries where effect.effectKind == EffectType.scroll.rawValue {
            let offsetX = number(
                effect: effect,
                property: "offsetX",
                snapshot: snapshot,
                fallback: number(effect: effect, property: "x", snapshot: snapshot, fallback: 0)
            )
            let offsetY = number(
                effect: effect,
                property: "offsetY",
                snapshot: snapshot,
                fallback: number(effect: effect, property: "y", snapshot: snapshot, fallback: 0)
            )
            textureOffset += SIMD2<Float>(
                Float(wrapUnit(offsetX)),
                Float(wrapUnit(offsetY))
            )
        }

        for effect in plan.effectEntries where effect.effectKind == EffectType.blur.rawValue {
            let radius = number(
                effect: effect,
                property: "radius",
                snapshot: snapshot,
                fallback: number(effect: effect, property: "amount", snapshot: snapshot, fallback: 0)
            )
            blurRadiusPixels = max(blurRadiusPixels, min(max(radius, 0), 8))
        }

        for effect in plan.effectEntries where effect.effectKind == EffectType.chromaticAberration.rawValue {
            let amount = number(
                effect: effect,
                property: "amount",
                snapshot: snapshot,
                fallback: number(effect: effect, property: "offset", snapshot: snapshot, fallback: 0)
            )
            chromaticOffsetPixels = max(chromaticOffsetPixels, min(max(amount, 0), 8))
        }

        for effect in plan.effectEntries where effect.effectKind == EffectType.vignette.rawValue {
            let intensity = number(
                effect: effect,
                property: "intensity",
                snapshot: snapshot,
                fallback: number(effect: effect, property: "amount", snapshot: snapshot, fallback: 0)
            )
            let radius = number(
                effect: effect,
                property: "radius",
                snapshot: snapshot,
                fallback: 0.55
            )
            vignetteIntensity = max(vignetteIntensity, min(max(intensity, 0), 1))
            vignetteRadius = min(max(radius, 0.05), 0.95)
        }

        return DeclarativeEffectState(
            colorMultiplier: colorMultiplier,
            textureOffset: SIMD2<Float>(
                Float(wrapUnit(Double(textureOffset.x))),
                Float(wrapUnit(Double(textureOffset.y)))
            ),
            fragmentEffectParams: SIMD4<Float>(
                Float(blurRadiusPixels),
                Float(chromaticOffsetPixels),
                Float(vignetteIntensity),
                Float(vignetteRadius)
            ),
            fragmentEffectParams2: SIMD4<Float>(
                Float(min(max(saturation, 0), 2)),
                0,
                0,
                0
            )
        )
    }

    private static func number(
        effect: DeclarativeEffectPlanEntry,
        property: String,
        snapshot: DeclarativeBindingEvaluationSnapshot,
        fallback: Double
    ) -> Double {
        if let dynamic = snapshot.number(effectID: effect.id, property: property) {
            return dynamic
        }
        guard let value = effect.properties[property] else {
            return fallback
        }
        if case .number(let number) = value {
            return number
        }
        return fallback
    }

    private static func wrapUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let wrapped = value.truncatingRemainder(dividingBy: 1)
        return wrapped < 0 ? wrapped + 1 : wrapped
    }
}
