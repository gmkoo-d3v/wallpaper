import simd

struct RenderVertex {
    let position: SIMD2<Float>
    let texCoord: SIMD2<Float>
    let color: SIMD4<Float>
    let darkColor: SIMD4<Float>

    init(
        position: SIMD2<Float>,
        texCoord: SIMD2<Float>,
        color: SIMD4<Float>,
        darkColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
    ) {
        self.position = position
        self.texCoord = texCoord
        self.color = color
        self.darkColor = darkColor
    }
}

struct RenderUniforms {
    let transform: SIMD4<Float>
    let aspectScale: SIMD4<Float>
    let textureTransform: SIMD4<Float>
    let effectParams: SIMD4<Float>

    static func make(
        scale: Float,
        offset: SIMD2<Float>,
        aspectScale: SIMD2<Float>,
        textureOffset: SIMD2<Float> = SIMD2<Float>(0, 0),
        effectParams: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
    ) -> RenderUniforms {
        RenderUniforms(
            transform: SIMD4<Float>(scale, offset.x, offset.y, 0),
            aspectScale: SIMD4<Float>(aspectScale.x, aspectScale.y, 0, 0),
            textureTransform: SIMD4<Float>(textureOffset.x, textureOffset.y, 0, 0),
            effectParams: effectParams
        )
    }
}

enum RenderBlendMode: String, Hashable {
    case normal
    case additive
    case multiply
    case screen

    init?(spineBlend rawValue: String?) {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = ((trimmed?.isEmpty == false ? trimmed : nil) ?? "normal").lowercased()
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
