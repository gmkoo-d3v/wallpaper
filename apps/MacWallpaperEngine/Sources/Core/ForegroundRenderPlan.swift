import Foundation

struct ForegroundRenderPlan {
    enum Choice {
        case none(String)
        case nativeSpine(auto: Bool)
        case compositeVideo(auto: Bool)
        case compositeFallbackNativeUnsupported
        case blockedNativeUnsupported

        var label: String {
            switch self {
            case .none(let reason):
                return "none(\(reason))"
            case .nativeSpine(let auto):
                return auto ? "nativeSpine(auto)" : "nativeSpine"
            case .compositeVideo(let auto):
                return auto ? "compositeVideo(auto)" : "compositeVideo"
            case .compositeFallbackNativeUnsupported:
                return "compositeFallback(native-unsupported)"
            case .blockedNativeUnsupported:
                return "blocked(native-unsupported)"
            }
        }

        var usesNativeSpine: Bool {
            if case .nativeSpine = self { return true }
            return false
        }

        var usesCompositeVideo: Bool {
            switch self {
            case .compositeVideo, .compositeFallbackNativeUnsupported:
                return true
            case .none, .nativeSpine, .blockedNativeUnsupported:
                return false
            }
        }
    }

    let choice: Choice
    let fallbackLabel: String

    var foregroundLabel: String { choice.label }
    var usesNativeSpine: Bool { choice.usesNativeSpine }
    var usesCompositeVideo: Bool { choice.usesCompositeVideo }
    var allowsVideoOnlyResourceFallback: Bool { false }
    var isBlocked: Bool {
        if case .blockedNativeUnsupported = choice { return true }
        return false
    }
    var isNativeUnsupportedFallback: Bool {
        if case .compositeFallbackNativeUnsupported = choice { return true }
        return false
    }

    static func make(
        runtime: NativeRuntimeCore,
        role: RenderDisplayRole,
        compatibility: NativeSpineCompatibility
    ) -> ForegroundRenderPlan {
        guard role.rendersForeground else {
            return ForegroundRenderPlan(choice: .none("display-policy"), fallbackLabel: "none")
        }

        switch runtime.config.foregroundMode {
        case .automatic:
            if canUseNativeSpine(runtime: runtime, compatibility: compatibility) {
                return ForegroundRenderPlan(
                    choice: .nativeSpine(auto: true),
                    fallbackLabel: resourceFallbackLabel(runtime: runtime)
                )
            }
            if role.prefersCompositeVideo, runtime.assetCatalog.compositeVideoAsset != nil {
                return ForegroundRenderPlan(choice: .compositeVideo(auto: true), fallbackLabel: "auto->compositeVideo")
            }
            return ForegroundRenderPlan(choice: .none("no-foreground-asset"), fallbackLabel: "none")

        case .compositeVideo:
            guard role.prefersCompositeVideo, runtime.assetCatalog.compositeVideoAsset != nil else {
                return ForegroundRenderPlan(choice: .none("no-compositeVideo"), fallbackLabel: "none")
            }
            return ForegroundRenderPlan(choice: .compositeVideo(auto: false), fallbackLabel: "none")

        case .nativeSpine:
            if compatibility.isSupported == false {
                if runtime.assetCatalog.compositeVideoAsset == nil {
                    return ForegroundRenderPlan(
                        choice: .blockedNativeUnsupported,
                        fallbackLabel: "blocked(no-compositeVideo)"
                    )
                }
                return ForegroundRenderPlan(
                    choice: .compositeFallbackNativeUnsupported,
                    fallbackLabel: "nativeCompatibility->compositeVideo"
                )
            }
            guard runtime.assetCatalog.spineAsset != nil else {
                return ForegroundRenderPlan(choice: .none("no-spine"), fallbackLabel: "none")
            }
            return ForegroundRenderPlan(
                choice: .nativeSpine(auto: false),
                fallbackLabel: resourceFallbackLabel(runtime: runtime)
            )
        }
    }

    private static func canUseNativeSpine(
        runtime: NativeRuntimeCore,
        compatibility: NativeSpineCompatibility
    ) -> Bool {
        runtime.assetCatalog.spineAsset != nil && compatibility.isSupported
    }

    private static func resourceFallbackLabel(runtime: NativeRuntimeCore) -> String {
        runtime.assetCatalog.compositeVideoAsset == nil ? "none" : "resourceBudget->fpsOnly"
    }
}
