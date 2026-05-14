import AppKit
import Foundation

enum WallpaperLevel: String {
    case normal
    case desktop
    case desktopMinusOne
    case desktopPlusOne
    case backstop

    var windowLevel: NSWindow.Level {
        if self == .normal {
            return .normal
        }

        let key: CGWindowLevelKey
        switch self {
        case .normal:
            key = .normalWindow
        case .desktop, .desktopMinusOne, .desktopPlusOne:
            key = .desktopWindow
        case .backstop:
            key = .backstopMenu
        }

        var raw = CGWindowLevelForKey(key)
        switch self {
        case .desktopMinusOne:
            raw -= 1
        case .desktopPlusOne:
            raw += 1
        case .normal, .desktop, .backstop:
            break
        }
        return NSWindow.Level(rawValue: Int(raw))
    }
}

enum DisplayMode: String {
    case all
    case primaryAnimated
    case primaryOnly
}

enum RenderFitMode: String {
    case contain
    case fill
}

enum ForegroundRenderMode: String {
    case compositeVideo = "composite"
    case nativeSpine = "native"
}

struct EngineConfig {
    let projectRoot: URL
    let wallpaperRoot: URL
    let manifestURL: URL
    let level: WallpaperLevel
    let displayMode: DisplayMode
    let duration: TimeInterval?
    let renderFps: Int?
    let playbackRateOverride: Float?
    let fitMode: RenderFitMode
    let foregroundMode: ForegroundRenderMode
    let validateOnly: Bool
    let startHidden: Bool
    let interactive: Bool
    let launchControlPanel: Bool
    let launchWallpaper: Bool
    let videoEnabled: Bool
    let metalEnabled: Bool
    let plainWindowStyle: Bool

    func replacing(
        wallpaperRoot: URL? = nil,
        manifestURL: URL? = nil,
        displayMode: DisplayMode? = nil,
        interactive: Bool? = nil,
        renderFps: Int? = nil,
        playbackRateOverride: Float? = nil,
        fitMode: RenderFitMode? = nil,
        foregroundMode: ForegroundRenderMode? = nil,
        startHidden: Bool? = nil,
        duration: TimeInterval? = nil,
        launchControlPanel: Bool? = nil,
        launchWallpaper: Bool? = nil,
        videoEnabled: Bool? = nil,
        metalEnabled: Bool? = nil,
        plainWindowStyle: Bool? = nil
    ) -> EngineConfig {
        EngineConfig(
            projectRoot: projectRoot,
            wallpaperRoot: wallpaperRoot ?? self.wallpaperRoot,
            manifestURL: manifestURL ?? self.manifestURL,
            level: level,
            displayMode: displayMode ?? self.displayMode,
            duration: duration,
            renderFps: renderFps ?? self.renderFps,
            playbackRateOverride: playbackRateOverride ?? self.playbackRateOverride,
            fitMode: fitMode ?? self.fitMode,
            foregroundMode: foregroundMode ?? self.foregroundMode,
            validateOnly: validateOnly,
            startHidden: startHidden ?? self.startHidden,
            interactive: interactive ?? self.interactive,
            launchControlPanel: launchControlPanel ?? self.launchControlPanel,
            launchWallpaper: launchWallpaper ?? self.launchWallpaper,
            videoEnabled: videoEnabled ?? self.videoEnabled,
            metalEnabled: metalEnabled ?? self.metalEnabled,
            plainWindowStyle: plainWindowStyle ?? self.plainWindowStyle
        )
    }

    static func parse(_ arguments: [String]) throws -> EngineConfig {
        var wallpaperRoot: URL?
        var manifestURL: URL?
        var level = WallpaperLevel.desktop
        var displayMode = DisplayMode.primaryAnimated
        var duration: TimeInterval?
        var renderFps: Int?
        var playbackRateOverride: Float?
        var fitMode = RenderFitMode.contain
        var foregroundMode = ForegroundRenderMode.compositeVideo
        var validateOnly = false
        var startHidden = false
        var interactive = true
        var launchControlPanel = true
        var launchWallpaper = true
        var videoEnabled = true
        var metalEnabled = true
        var plainWindowStyle = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--wallpaper-root":
                index += 1
                wallpaperRoot = try valueURL(arguments, index, option: argument)
            case "--manifest":
                index += 1
                manifestURL = try valueURL(arguments, index, option: argument)
            case "--level":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = WallpaperLevel(rawValue: raw) else {
                    throw EngineError.invalidArgument("Unknown --level: \(raw)")
                }
                level = parsed
            case "--display-mode":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = DisplayMode(rawValue: raw) else {
                    throw EngineError.invalidArgument("Unknown --display-mode: \(raw)")
                }
                displayMode = parsed
            case "--duration":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = TimeInterval(raw) else {
                    throw EngineError.invalidArgument("Invalid --duration: \(raw)")
                }
                duration = parsed
            case "--fps":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = Int(raw), [30, 60, 120].contains(parsed) else {
                    throw EngineError.invalidArgument("Invalid --fps: \(raw). Supported values: 30, 60, 120")
                }
                renderFps = parsed
            case "--playback-rate":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = Float(raw), parsed.isFinite, parsed > 0, parsed <= 4 else {
                    throw EngineError.invalidArgument("Invalid --playback-rate: \(raw)")
                }
                playbackRateOverride = parsed
            case "--fit-mode":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = RenderFitMode(rawValue: raw) else {
                    throw EngineError.invalidArgument("Unknown --fit-mode: \(raw)")
                }
                fitMode = parsed
            case "--foreground-mode":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = ForegroundRenderMode(rawValue: raw) else {
                    throw EngineError.invalidArgument("Unknown --foreground-mode: \(raw)")
                }
                foregroundMode = parsed
            case "--validate-only":
                validateOnly = true
            case "--hidden":
                startHidden = true
            case "--pass-through":
                interactive = false
            case "--no-control-panel":
                launchControlPanel = false
            case "--control-panel-only":
                launchControlPanel = true
                launchWallpaper = false
            case "--wallpaper-only":
                launchControlPanel = false
                launchWallpaper = true
            case "--no-wallpaper":
                launchWallpaper = false
            case "--no-video":
                videoEnabled = false
            case "--no-metal":
                metalEnabled = false
            case "--plain-window-style":
                plainWindowStyle = true
            case "--help", "-h":
                print(Self.help)
                exit(EXIT_SUCCESS)
            default:
                throw EngineError.invalidArgument("Unknown argument: \(argument)")
            }
            index += 1
        }

        let detectedRoot = try? ProjectPaths.findProjectRoot()
        let bundledWallpaperRoot = ProjectPaths.findBundledWallpaperRoot()
        let resolvedWallpaperRoot: URL
        if let wallpaperRoot {
            resolvedWallpaperRoot = wallpaperRoot.standardizedFileURL
        } else if let manifestURL {
            resolvedWallpaperRoot = manifestURL.deletingLastPathComponent().standardizedFileURL
        } else if let bundledWallpaperRoot {
            resolvedWallpaperRoot = bundledWallpaperRoot
        } else if let detectedRoot {
            guard let defaultWallpaperRoot = ProjectPaths.findDefaultWallpaperRoot(
                in: detectedRoot.appendingPathComponent("wallpapers")
            ) else {
                throw EngineError.invalidArgument("Could not find a wallpaper bundle under \(detectedRoot.appendingPathComponent("wallpapers").path)")
            }
            resolvedWallpaperRoot = defaultWallpaperRoot
        } else {
            throw EngineError.invalidArgument("Could not find default wallpaper root; pass --wallpaper-root or --manifest")
        }

        let resolvedManifest = (manifestURL ?? resolvedWallpaperRoot.appendingPathComponent("wallpaper.native.json"))
            .standardizedFileURL

        return EngineConfig(
            projectRoot: detectedRoot ?? bundledWallpaperRoot?.deletingLastPathComponent().deletingLastPathComponent() ?? resolvedWallpaperRoot,
            wallpaperRoot: resolvedWallpaperRoot,
            manifestURL: resolvedManifest,
            level: level,
            displayMode: displayMode,
            duration: duration,
            renderFps: renderFps,
            playbackRateOverride: playbackRateOverride,
            fitMode: fitMode,
            foregroundMode: foregroundMode,
            validateOnly: validateOnly,
            startHidden: startHidden,
            interactive: interactive,
            launchControlPanel: launchControlPanel,
            launchWallpaper: launchWallpaper,
            videoEnabled: videoEnabled,
            metalEnabled: metalEnabled,
            plainWindowStyle: plainWindowStyle
        )
    }

    private static func value(_ arguments: [String], _ index: Int, option: String) throws -> String {
        guard index < arguments.count else {
            throw EngineError.invalidArgument("Missing value for \(option)")
        }
        return arguments[index]
    }

    private static func valueURL(_ arguments: [String], _ index: Int, option: String) throws -> URL {
        URL(fileURLWithPath: try value(arguments, index, option: option), relativeTo: nil).standardizedFileURL
    }

    static let help = """
    MacWallpaperEngine native MVP

    Options:
      --wallpaper-root <path>   Wallpaper bundle root. Defaults to the first valid bundle under wallpapers/.
      --manifest <path>         Native manifest path. Defaults to wallpaper.native.json under root.
      --display-mode <mode>     all | primaryAnimated | primaryOnly. Default: primaryAnimated.
      --level <level>           normal | desktop | desktopMinusOne | desktopPlusOne | backstop. Default: desktop.
      --duration <seconds>      Auto-quit after a short smoke run.
      --fps <value>             Render FPS: 30 | 60 | 120. Defaults to manifest targetFps.
      --playback-rate <value>   Video playback rate override. Defaults to manifest asset rate.
      --fit-mode <mode>         contain | fill. Default: contain.
      --foreground-mode <mode>  composite | native. Default: composite.
      --validate-only           Validate manifest and assets without opening windows.
      --hidden                  Build host but keep windows hidden.
      --pass-through            Ignore mouse events and let desktop clicks pass through.
      --no-control-panel        Do not show the native control panel.
      --control-panel-only      Show only the control panel; do not start wallpaper windows.
      --wallpaper-only          Start wallpaper windows without the control panel.
      --no-wallpaper            Do not start wallpaper windows.
      --no-video                Disable video decoding and draw static fallback only.
      --no-metal                Use a plain NSView instead of MTKView for windowing diagnostics.
      --plain-window-style      Use titled normal app windows for windowing diagnostics.
    """
}

enum ProjectPaths {
    static func findBundledWallpaperRoot() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        return findDefaultWallpaperRoot(in: resourceURL.appendingPathComponent("wallpapers"))
    }

    static func findProjectRoot() throws -> URL {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL

        for _ in 0..<8 {
            let packageMarker = current.appendingPathComponent("apps/MacWallpaperEngine/Package.swift")
            let wallpaperMarker = current.appendingPathComponent("wallpapers")
            if FileManager.default.fileExists(atPath: packageMarker.path),
               directoryExists(wallpaperMarker) {
                return current
            }
            current.deleteLastPathComponent()
        }

        throw EngineError.invalidArgument("Could not find project root from current directory")
    }

    static func findDefaultWallpaperRoot(in wallpapersDirectory: URL) -> URL? {
        let directory = wallpapersDirectory.standardizedFileURL
        let preferred = directory.appendingPathComponent("sample_imported")
        if isWallpaperBundle(preferred) {
            return preferred
        }

        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return children
            .filter(isWallpaperBundle)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first
    }

    private static func isWallpaperBundle(_ url: URL) -> Bool {
        guard directoryExists(url) else { return false }
        let manifestURL = url.appendingPathComponent("wallpaper.native.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return false }
        return (try? ManifestLoader.load(url: manifestURL, bundleRoot: url)) != nil
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
