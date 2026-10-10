import CoreGraphics

enum SpineInteractionAnimationRoles {
    /// Colon values are random animation pairs ("a:b"). Each component inherits the
    /// field's role, so role sets must index components rather than the raw string.
    /// Canonical malformed-pair handling: "a:" yields ["a"], ":b" yields ["b"], and a
    /// colon-only value (":") yields the raw action so it never resolves to a component.
    static func components(of action: String) -> [String] {
        let parts = action
            .split(separator: ":")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
        if parts.count > 1 {
            return parts
        }
        if parts.count == 1 {
            return action.contains(":") ? [parts[0]] : [action]
        }
        return [action]
    }

    static func idleAnimationName(from manifest: WallpaperNativeManifest) -> String {
        for interaction in manifest.interactions where interaction.event == .pointerMove {
            if let idle = interaction.actions?["idle"], idle.isEmpty == false {
                return idle
            }
        }
        return "idle"
    }

    static func lookAnimationNames(from manifest: WallpaperNativeManifest) -> Set<String> {
        var names: Set<String> = []
        let idleAnimationName = idleAnimationName(from: manifest)
        for interaction in manifest.interactions where interaction.event == .pointerMove {
            interaction.actions?.forEach { key, action in
                if key != "idle" && action != idleAnimationName {
                    components(of: action).forEach { names.insert($0) }
                }
            }
        }
        return names
    }

    static func loopingAnimationNames(from manifest: WallpaperNativeManifest) -> Set<String> {
        var names: Set<String> = [idleAnimationName(from: manifest)]
        for interaction in manifest.interactions where interaction.event == .pointerDown {
            if (interaction.defaultAction?.trigger ?? .tap) == .hold,
               let action = interaction.defaultAction?.action {
                components(of: action).forEach { names.insert($0) }
            }
            interaction.hitZones?
                .filter { ($0.trigger ?? .tap) == .hold }
                .forEach { hitZone in
                    components(of: hitZone.action).forEach { names.insert($0) }
                }
        }
        return names
    }

    static func oneShotAnimationNames(from manifest: WallpaperNativeManifest) -> Set<String> {
        var names: Set<String> = []
        for interaction in manifest.interactions where interaction.event == .pointerDown {
            if (interaction.defaultAction?.trigger ?? .tap) == .tap,
               let action = interaction.defaultAction?.action {
                components(of: action).forEach { names.insert($0) }
            }
            interaction.hitZones?
                .filter { ($0.trigger ?? .tap) == .tap }
                .forEach { hitZone in
                    components(of: hitZone.action).forEach { names.insert($0) }
                }
            interaction.hitZones?
                .compactMap(\.tapAction)
                .forEach { tapAction in components(of: tapAction).forEach { names.insert($0) } }
            interaction.hitZones?
                .compactMap(\.rubAction)
                .forEach { rubAction in components(of: rubAction).forEach { names.insert($0) } }
        }
        DeclarativeBindingPlan(manifest: manifest).triggerPlayBindings
            .forEach { names.insert($0.target.id) }
        return names
    }

    static func lookNeutralPoint(from manifest: WallpaperNativeManifest) -> CGPoint {
        for interaction in manifest.interactions where interaction.event == .pointerMove {
            if let neutralPoint = interaction.neutralPoint {
                return CGPoint(x: neutralPoint.x, y: neutralPoint.y)
            }
        }
        return CGPoint(x: 0.5, y: 0.5)
    }

    static func lookDeadZone(from manifest: WallpaperNativeManifest, fallback: Double) -> CGPoint {
        for interaction in manifest.interactions where interaction.event == .pointerMove {
            if let deadZone = interaction.deadZone {
                return CGPoint(x: deadZone.x, y: deadZone.y)
            }
        }
        let clampedFallback = min(max(fallback, 0), 0.49)
        return CGPoint(x: clampedFallback, y: clampedFallback)
    }
}
