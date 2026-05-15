enum SpineInteractionAnimationRoles {
    static func loopingAnimationNames(from manifest: WallpaperNativeManifest) -> Set<String> {
        var names: Set<String> = ["idle"]
        for interaction in manifest.interactions where interaction.event == .pointerDown {
            interaction.hitZones?
                .filter { ($0.trigger ?? .tap) == .hold }
                .forEach { names.insert($0.action) }
        }
        return names
    }

    static func oneShotAnimationNames(from manifest: WallpaperNativeManifest) -> Set<String> {
        var names: Set<String> = []
        for interaction in manifest.interactions where interaction.event == .pointerDown {
            interaction.hitZones?
                .filter { ($0.trigger ?? .tap) == .tap }
                .forEach { names.insert($0.action) }
        }
        return names
    }
}
