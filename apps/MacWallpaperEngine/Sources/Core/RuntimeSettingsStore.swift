import Foundation

struct PersistedEngineSettings: Codable, Equatable {
    let schemaVersion: Int
    let wallpaperRootPath: String?
    let displayMode: DisplayMode?
    let primaryDisplaySelector: String?
    let interactive: Bool?
    let renderFps: Int?
    let matchDisplayRefresh: Bool?
    let playbackRateOverride: Float?
    let fitMode: RenderFitMode?
    let foregroundMode: ForegroundRenderMode?

    static let currentSchemaVersion = 1

    static func capture(from config: EngineConfig) -> PersistedEngineSettings {
        PersistedEngineSettings(
            schemaVersion: currentSchemaVersion,
            wallpaperRootPath: config.wallpaperRoot.standardizedFileURL.path,
            displayMode: config.displayMode,
            primaryDisplaySelector: config.primaryDisplaySelector,
            interactive: config.interactive,
            renderFps: config.renderFps,
            matchDisplayRefresh: config.matchDisplayRefresh,
            playbackRateOverride: config.playbackRateOverride,
            fitMode: config.fitMode,
            foregroundMode: config.foregroundMode
        )
    }

    var sanitized: PersistedEngineSettings {
        PersistedEngineSettings(
            schemaVersion: schemaVersion == Self.currentSchemaVersion ? schemaVersion : Self.currentSchemaVersion,
            wallpaperRootPath: wallpaperRootPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            displayMode: displayMode,
            primaryDisplaySelector: primaryDisplaySelector?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            interactive: interactive,
            renderFps: renderFps.flatMap { [30, 60].contains($0) ? $0 : nil },
            matchDisplayRefresh: matchDisplayRefresh ?? (renderFps.map { $0 > 60 } ?? false),
            playbackRateOverride: playbackRateOverride.flatMap { $0.isFinite && $0 > 0 && $0 <= 4 ? $0 : nil },
            fitMode: fitMode,
            foregroundMode: foregroundMode
        )
    }
}

enum RuntimeSettingsStore {
    static let environmentSettingsPath = "MAC_WALLPAPER_ENGINE_SETTINGS_PATH"

    static func load() -> PersistedEngineSettings? {
        guard let settingsURL = defaultSettingsURL() else { return nil }
        return try? load(from: settingsURL)
    }

    static func load(from settingsURL: URL) throws -> PersistedEngineSettings {
        let data = try Data(contentsOf: settingsURL)
        return try JSONDecoder().decode(PersistedEngineSettings.self, from: data).sanitized
    }

    static func save(config: EngineConfig) throws {
        guard let settingsURL = defaultSettingsURL() else { return }
        try save(config: config, to: settingsURL)
    }

    static func save(config: EngineConfig, to settingsURL: URL) throws {
        try save(PersistedEngineSettings.capture(from: config), to: settingsURL)
    }

    static func save(_ settings: PersistedEngineSettings, to settingsURL: URL) throws {
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }

    static func validWallpaperRoot(from settings: PersistedEngineSettings?) -> URL? {
        guard let path = settings?.wallpaperRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.isEmpty == false else {
            return nil
        }
        let root = URL(fileURLWithPath: path, relativeTo: nil).standardizedFileURL
        return WallpaperBundleCatalog.validateBundle(root)?.root
    }

    static func defaultSettingsURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment[environmentSettingsPath]?.trimmingCharacters(in: .whitespacesAndNewlines),
           override.isEmpty == false {
            return URL(fileURLWithPath: override, relativeTo: nil).standardizedFileURL
        }
        return ProjectPaths.applicationSupportDirectory()?.appendingPathComponent("settings.json")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
