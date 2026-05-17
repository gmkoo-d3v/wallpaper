import CoreGraphics

enum SpineInteractionAnimationRoles {
    static func lookAnimationNames(from manifest: WallpaperNativeManifest) -> Set<String> {
        var names: Set<String> = []
        for interaction in manifest.interactions where interaction.event == .pointerMove {
            interaction.actions?.forEach { key, action in
                if key != "idle" && action != "idle" {
                    names.insert(action)
                }
            }
        }
        return names
    }

    static func loopingAnimationNames(from manifest: WallpaperNativeManifest) -> Set<String> {
        var names: Set<String> = ["idle"]
        for interaction in manifest.interactions where interaction.event == .pointerDown {
            if (interaction.defaultAction?.trigger ?? .tap) == .hold,
               let action = interaction.defaultAction?.action {
                names.insert(action)
            }
            interaction.hitZones?
                .filter { ($0.trigger ?? .tap) == .hold }
                .forEach { names.insert($0.action) }
        }
        return names
    }

    static func oneShotAnimationNames(from manifest: WallpaperNativeManifest) -> Set<String> {
        var names: Set<String> = []
        for interaction in manifest.interactions where interaction.event == .pointerDown {
            if (interaction.defaultAction?.trigger ?? .tap) == .tap,
               let action = interaction.defaultAction?.action {
                names.insert(action)
            }
            interaction.hitZones?
                .filter { ($0.trigger ?? .tap) == .tap }
                .forEach { names.insert($0.action) }
        }
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
