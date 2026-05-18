import simd

struct RenderVertex {
    let position: SIMD2<Float>
    let texCoord: SIMD2<Float>
    let color: SIMD4<Float>
}

struct RenderUniforms {
    let transform: SIMD4<Float>
    let aspectScale: SIMD4<Float>

    static func make(scale: Float, offset: SIMD2<Float>, aspectScale: SIMD2<Float>) -> RenderUniforms {
        RenderUniforms(
            transform: SIMD4<Float>(scale, offset.x, offset.y, 0),
            aspectScale: SIMD4<Float>(aspectScale.x, aspectScale.y, 0, 0)
        )
    }
}

enum RenderBlendMode: String, Hashable {
    case normal
    case additive
    case multiply
    case screen

    init?(spineBlend rawValue: String?) {
        let normalized = (rawValue ?? "normal").lowercased()
        switch normalized {
        case "normal":
            self = .normal
        case "add", "additive":
            self = .additive
        case "multiply":
            self = .multiply
        case "screen":
            self = .screen
        default:
            return nil
        }
    }
}
