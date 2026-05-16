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
}
