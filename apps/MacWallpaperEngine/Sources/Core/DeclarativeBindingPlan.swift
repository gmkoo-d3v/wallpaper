import Foundation

struct DeclarativeBindingPlan {
    let bindingEntries: [DeclarativeBindingPlanEntry]
    let effectEntries: [DeclarativeEffectPlanEntry]

    init(manifest: WallpaperNativeManifest) {
        self.effectEntries = (manifest.effects ?? []).map(DeclarativeEffectPlanEntry.init(effect:))
        self.bindingEntries = (manifest.bindings ?? []).map(DeclarativeBindingPlanEntry.init(binding:))
    }

    var bindingKinds: [String] {
        bindingEntries.map(\.adapterKind).uniquePreservingOrder.emptyFallback("none")
    }

    var effectKinds: [String] {
        effectEntries.map(\.effectKind).uniquePreservingOrder.emptyFallback("none")
    }

    var bindingStatusSummary: String {
        statusSummary(bindingEntries.map(\.runtimeStatus.rawValue))
    }

    var effectStatusSummary: String {
        statusSummary(effectEntries.map(\.runtimeStatus.rawValue))
    }

    var hasPointerInputBindings: Bool {
        bindingEntries.contains { entry in
            entry.runtimeStatus == .runtimeExecutable
                && entry.source.isPointerInputSource
        }
    }

    var triggerPlayBindings: [DeclarativeBindingPlanEntry] {
        bindingEntries.filter { entry in
            entry.isEnabled
                && entry.source == .pointerDown
                && entry.target.kind == .spineAnimation
                && entry.adapterKind == BindingAdapterType.triggerPlay.rawValue
        }
    }

    var mapRangeEffectBindings: [DeclarativeBindingPlanEntry] {
        bindingEntries.filter { entry in
            entry.isEnabled
                && entry.target.kind == .effect
                && entry.adapterKind == BindingAdapterType.mapRange.rawValue
        }
    }

    var springEffectBindings: [DeclarativeBindingPlanEntry] {
        bindingEntries.filter { entry in
            entry.isEnabled
                && entry.target.kind == .effect
                && entry.adapterKind == BindingAdapterType.spring.rawValue
        }
    }

    var springBoneBindings: [DeclarativeBindingPlanEntry] {
        bindingEntries.filter { entry in
            entry.isEnabled
                && entry.source == .pointerPosition
                && entry.target.kind == .spineBone
                && entry.adapterKind == BindingAdapterType.spring.rawValue
        }
    }

    var smoothLookAtBoneBindings: [DeclarativeBindingPlanEntry] {
        bindingEntries.filter { entry in
            entry.isEnabled
                && entry.source == .pointerPosition
                && entry.target.kind == .spineBone
                && entry.adapterKind == BindingAdapterType.smoothLookAt.rawValue
                && entry.adapter.factor?.isEmpty == false
        }
    }

    init(bindings: [DeclarativeBinding], effects: [EffectConfig]) {
        self.effectEntries = effects.map(DeclarativeEffectPlanEntry.init(effect:))
        self.bindingEntries = bindings.map(DeclarativeBindingPlanEntry.init(binding:))
    }

    private func statusSummary(_ statuses: [String]) -> String {
        let counts = Dictionary(grouping: statuses, by: { $0 }).mapValues(\.count)
        return counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: ",")
    }
}

extension BindingSource {
    var isPointerInputSource: Bool {
        switch self {
        case .pointerPosition, .pointerX, .pointerY, .pointerDown, .pointerSpeed, .pointerPressDuration, .pointerDragDistance:
            return true
        case .systemTime, .thermalState:
            return false
        }
    }
}

struct DeclarativeBindingPlanEntry {
    let id: String
    let source: BindingSource
    let target: DeclarativeBindingTarget
    let adapter: BindingAdapter
    let adapterKind: String
    let isEnabled: Bool
    let runtimeStatus: DeclarativePlanRuntimeStatus

    init(binding: DeclarativeBinding) {
        self.id = binding.id
        self.source = binding.source
        self.target = DeclarativeBindingTarget(rawValue: binding.target)
        self.adapter = binding.adapter
        self.adapterKind = binding.adapter.type.rawValue
        self.isEnabled = binding.enabled != false
        if binding.enabled == false {
            self.runtimeStatus = .disabled
        } else if binding.source == .pointerDown,
                  self.target.kind == .spineAnimation,
                  binding.adapter.type == .triggerPlay {
            self.runtimeStatus = .runtimeExecutable
        } else if self.target.kind == .effect,
                  binding.adapter.type == .mapRange {
            self.runtimeStatus = .runtimeExecutable
        } else if self.target.kind == .effect,
                  binding.adapter.type == .spring {
            self.runtimeStatus = .runtimeExecutable
        } else if binding.source == .pointerPosition,
                  self.target.kind == .spineBone,
                  binding.adapter.type == .spring {
            self.runtimeStatus = .runtimeExecutable
        } else if binding.source == .pointerPosition,
                  self.target.kind == .spineBone,
                  binding.adapter.type == .smoothLookAt,
                  binding.adapter.factor?.isEmpty == false {
            self.runtimeStatus = .runtimeExecutable
        } else {
            self.runtimeStatus = .declaredOnly
        }
    }

    var summary: String {
        "\(id):\(source.rawValue)->\(target.summary) via \(adapterKind) \(runtimeStatus.rawValue)"
    }
}

struct DeclarativeEffectPlanEntry {
    let id: String
    let effectKind: String
    let properties: [String: EffectPropertyValue]
    let propertyCount: Int
    let runtimeStatus: DeclarativePlanRuntimeStatus

    init(effect: EffectConfig) {
        self.id = effect.id
        self.effectKind = effect.type.rawValue
        self.properties = effect.properties ?? [:]
        self.propertyCount = properties.count
        self.runtimeStatus = .runtimeRendered
    }

    var summary: String {
        "\(id):\(effectKind) properties=\(propertyCount) \(runtimeStatus.rawValue)"
    }
}

struct DeclarativeBindingTarget {
    let rawValue: String
    let kind: DeclarativeBindingTargetKind
    let id: String
    let propertyPath: String?

    init(rawValue: String) {
        self.rawValue = rawValue
        if let suffix = rawValue.removingPrefix("spine.bone.") {
            self.kind = .spineBone
            self.id = suffix
            self.propertyPath = nil
        } else if let suffix = rawValue.removingPrefix("spine.animation.") {
            self.kind = .spineAnimation
            self.id = suffix
            self.propertyPath = nil
        } else if let suffix = rawValue.removingPrefix("effect.") {
            let parts = suffix.split(separator: ".", maxSplits: 1).map(String.init)
            self.kind = .effect
            self.id = parts.first ?? suffix
            self.propertyPath = parts.count > 1 ? parts[1] : nil
        } else {
            self.kind = .unknown
            self.id = rawValue
            self.propertyPath = nil
        }
    }

    var summary: String {
        switch kind {
        case .spineBone, .spineAnimation:
            return "\(kind.rawValue).\(id)"
        case .effect:
            return "effect.\(id).\(propertyPath ?? "?")"
        case .unknown:
            return rawValue
        }
    }
}

enum DeclarativeBindingTargetKind: String {
    case spineBone = "spine.bone"
    case spineAnimation = "spine.animation"
    case effect
    case unknown
}

enum DeclarativePlanRuntimeStatus: String {
    case declaredOnly = "declared-only"
    case runtimeExecutable = "runtime-executable"
    case runtimeRendered = "runtime-rendered"
    case disabled
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

private extension Array where Element == String {
    var uniquePreservingOrder: [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }

    func emptyFallback(_ fallback: String) -> [String] {
        isEmpty ? [fallback] : self
    }
}
