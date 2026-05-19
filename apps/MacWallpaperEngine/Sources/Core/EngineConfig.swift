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

enum DisplayMode: String, Codable {
    case all
    case primaryAnimated
    case primaryOnly

    static func parseCLI(_ raw: String) -> DisplayMode? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "primaryOnly", "selectedOnly":
            return .primaryOnly
        case "primaryAnimated", "selectedPolicy":
            return .primaryAnimated
        case "all", "allFull":
            return .all
        default:
            return nil
        }
    }

    var cliName: String {
        switch self {
        case .primaryOnly:
            return "selectedOnly"
        case .primaryAnimated:
            return "selectedPolicy"
        case .all:
            return "allFull"
        }
    }
}

enum RenderFitMode: String, Codable {
    case contain
    case fill
}

enum ForegroundRenderMode: String, Codable {
    case automatic = "auto"
    case compositeVideo = "composite"
    case nativeSpine = "native"
}

struct EngineConfig {
    let projectRoot: URL
    let wallpaperRoot: URL
    let manifestURL: URL
    let level: WallpaperLevel
    let displayMode: DisplayMode
    let primaryDisplaySelector: String?
    let duration: TimeInterval?
    let renderFps: Int?
    let matchDisplayRefresh: Bool
    let playbackRateOverride: Float?
    let audioEnabled: Bool
    let fitMode: RenderFitMode
    let foregroundMode: ForegroundRenderMode
    let interactionDebugOverlay: Bool
    let validateOnly: Bool
    let displayPlanOnly: Bool
    let physicalDisplayPlanOnly: Bool
    let renderPlanOnly: Bool
    let physicalRenderPlanOnly: Bool
    let simulatedRenderPlanOnly: Bool
    let performancePlanOnly: Bool
    let runtimeCapabilitiesOnly: Bool
    let doctorReportOnly: Bool
    let interactionPlanOnly: Bool
    let interactionProbePoint: CGPoint?
    let interactionProbeButton: PointerButton
    let spineAnimationPlanOnly: Bool
    let spineProfileOnly: Bool
    let spineSnapshotURL: URL?
    let spineSnapshotAction: String
    let spineSnapshotTime: Double
    let spineSnapshotWidth: Int
    let spineSnapshotHeight: Int
    let wallpaperSnapshotURL: URL?
    let wallpaperSnapshotReferenceURL: URL?
    let wallpaperGoldenCheckOnly: Bool
    let wallpaperGoldenURL: URL?
    let compositeQualityPlanOnly: Bool
    let compositeExportURL: URL?
    let compositeExportFps: Int?
    let compositeExportDuration: TimeInterval?
    let strictCompositeQuality: Bool
    let selfTestOnly: Bool
    let startHidden: Bool
    let interactive: Bool
    let launchControlPanel: Bool
    let launchWallpaper: Bool
    let launchAtLogin: Bool
    let videoEnabled: Bool
    let metalEnabled: Bool
    let plainWindowStyle: Bool

    func replacing(
        wallpaperRoot: URL? = nil,
        manifestURL: URL? = nil,
        displayMode: DisplayMode? = nil,
        primaryDisplaySelector: String? = nil,
        interactive: Bool? = nil,
        renderFps: Int? = nil,
        matchDisplayRefresh: Bool? = nil,
        playbackRateOverride: Float? = nil,
        audioEnabled: Bool? = nil,
        fitMode: RenderFitMode? = nil,
        foregroundMode: ForegroundRenderMode? = nil,
        interactionDebugOverlay: Bool? = nil,
        startHidden: Bool? = nil,
        duration: TimeInterval? = nil,
        clearDuration: Bool = false,
        launchControlPanel: Bool? = nil,
        launchWallpaper: Bool? = nil,
        launchAtLogin: Bool? = nil,
        videoEnabled: Bool? = nil,
        metalEnabled: Bool? = nil,
        plainWindowStyle: Bool? = nil,
        displayPlanOnly: Bool? = nil,
        physicalDisplayPlanOnly: Bool? = nil,
        renderPlanOnly: Bool? = nil,
        physicalRenderPlanOnly: Bool? = nil,
        simulatedRenderPlanOnly: Bool? = nil,
        performancePlanOnly: Bool? = nil,
        runtimeCapabilitiesOnly: Bool? = nil,
        doctorReportOnly: Bool? = nil,
        interactionPlanOnly: Bool? = nil,
        interactionProbePoint: CGPoint? = nil,
        interactionProbeButton: PointerButton? = nil,
        spineAnimationPlanOnly: Bool? = nil,
        spineProfileOnly: Bool? = nil,
        spineSnapshotURL: URL? = nil,
        spineSnapshotAction: String? = nil,
        spineSnapshotTime: Double? = nil,
        spineSnapshotWidth: Int? = nil,
        spineSnapshotHeight: Int? = nil,
        wallpaperSnapshotURL: URL? = nil,
        wallpaperSnapshotReferenceURL: URL? = nil,
        wallpaperGoldenCheckOnly: Bool? = nil,
        wallpaperGoldenURL: URL? = nil,
        compositeQualityPlanOnly: Bool? = nil,
        compositeExportURL: URL? = nil,
        compositeExportFps: Int? = nil,
        compositeExportDuration: TimeInterval? = nil,
        strictCompositeQuality: Bool? = nil,
        selfTestOnly: Bool? = nil
    ) -> EngineConfig {
        EngineConfig(
            projectRoot: projectRoot,
            wallpaperRoot: wallpaperRoot ?? self.wallpaperRoot,
            manifestURL: manifestURL ?? self.manifestURL,
            level: level,
            displayMode: displayMode ?? self.displayMode,
            primaryDisplaySelector: primaryDisplaySelector ?? self.primaryDisplaySelector,
            duration: clearDuration ? nil : (duration ?? self.duration),
            renderFps: renderFps ?? self.renderFps,
            matchDisplayRefresh: matchDisplayRefresh ?? self.matchDisplayRefresh,
            playbackRateOverride: playbackRateOverride ?? self.playbackRateOverride,
            audioEnabled: audioEnabled ?? self.audioEnabled,
            fitMode: fitMode ?? self.fitMode,
            foregroundMode: foregroundMode ?? self.foregroundMode,
            interactionDebugOverlay: interactionDebugOverlay ?? self.interactionDebugOverlay,
            validateOnly: validateOnly,
            displayPlanOnly: displayPlanOnly ?? self.displayPlanOnly,
            physicalDisplayPlanOnly: physicalDisplayPlanOnly ?? self.physicalDisplayPlanOnly,
            renderPlanOnly: renderPlanOnly ?? self.renderPlanOnly,
            physicalRenderPlanOnly: physicalRenderPlanOnly ?? self.physicalRenderPlanOnly,
            simulatedRenderPlanOnly: simulatedRenderPlanOnly ?? self.simulatedRenderPlanOnly,
            performancePlanOnly: performancePlanOnly ?? self.performancePlanOnly,
            runtimeCapabilitiesOnly: runtimeCapabilitiesOnly ?? self.runtimeCapabilitiesOnly,
            doctorReportOnly: doctorReportOnly ?? self.doctorReportOnly,
            interactionPlanOnly: interactionPlanOnly ?? self.interactionPlanOnly,
            interactionProbePoint: interactionProbePoint ?? self.interactionProbePoint,
            interactionProbeButton: interactionProbeButton ?? self.interactionProbeButton,
            spineAnimationPlanOnly: spineAnimationPlanOnly ?? self.spineAnimationPlanOnly,
            spineProfileOnly: spineProfileOnly ?? self.spineProfileOnly,
            spineSnapshotURL: spineSnapshotURL ?? self.spineSnapshotURL,
            spineSnapshotAction: spineSnapshotAction ?? self.spineSnapshotAction,
            spineSnapshotTime: spineSnapshotTime ?? self.spineSnapshotTime,
            spineSnapshotWidth: spineSnapshotWidth ?? self.spineSnapshotWidth,
            spineSnapshotHeight: spineSnapshotHeight ?? self.spineSnapshotHeight,
            wallpaperSnapshotURL: wallpaperSnapshotURL ?? self.wallpaperSnapshotURL,
            wallpaperSnapshotReferenceURL: wallpaperSnapshotReferenceURL ?? self.wallpaperSnapshotReferenceURL,
            wallpaperGoldenCheckOnly: wallpaperGoldenCheckOnly ?? self.wallpaperGoldenCheckOnly,
            wallpaperGoldenURL: wallpaperGoldenURL ?? self.wallpaperGoldenURL,
            compositeQualityPlanOnly: compositeQualityPlanOnly ?? self.compositeQualityPlanOnly,
            compositeExportURL: compositeExportURL ?? self.compositeExportURL,
            compositeExportFps: compositeExportFps ?? self.compositeExportFps,
            compositeExportDuration: compositeExportDuration ?? self.compositeExportDuration,
            strictCompositeQuality: strictCompositeQuality ?? self.strictCompositeQuality,
            selfTestOnly: selfTestOnly ?? self.selfTestOnly,
            startHidden: startHidden ?? self.startHidden,
            interactive: interactive ?? self.interactive,
            launchControlPanel: launchControlPanel ?? self.launchControlPanel,
            launchWallpaper: launchWallpaper ?? self.launchWallpaper,
            launchAtLogin: launchAtLogin ?? self.launchAtLogin,
            videoEnabled: videoEnabled ?? self.videoEnabled,
            metalEnabled: metalEnabled ?? self.metalEnabled,
            plainWindowStyle: plainWindowStyle ?? self.plainWindowStyle
        )
    }

    static func parse(_ arguments: [String]) throws -> EngineConfig {
        var wallpaperRoot: URL?
        var manifestURL: URL?
        var level = WallpaperLevel.desktop
        var displayMode = DisplayMode.primaryOnly
        var primaryDisplaySelector: String?
        var duration: TimeInterval?
        var renderFps: Int?
        var matchDisplayRefresh = false
        var playbackRateOverride: Float?
        var audioEnabled = false
        var fitMode = RenderFitMode.contain
        var foregroundMode = ForegroundRenderMode.automatic
        var interactionDebugOverlay = false
        var explicitWallpaperRoot = false
        var explicitManifestURL = false
        var explicitDisplayMode = false
        var explicitPrimaryDisplaySelector = false
        var explicitInteractive = false
        var explicitRenderFps = false
        var explicitPlaybackRateOverride = false
        var explicitAudioEnabled = false
        var explicitFitMode = false
        var explicitForegroundMode = false
        var explicitLaunchAtLogin = false
        var validateOnly = false
        var displayPlanOnly = false
        var physicalDisplayPlanOnly = false
        var renderPlanOnly = false
        var physicalRenderPlanOnly = false
        var simulatedRenderPlanOnly = false
        var performancePlanOnly = false
        var runtimeCapabilitiesOnly = false
        var doctorReportOnly = false
        var interactionPlanOnly = false
        var interactionProbePoint: CGPoint?
        var interactionProbeButton = PointerButton.left
        var spineAnimationPlanOnly = false
        var spineProfileOnly = false
        var spineSnapshotURL: URL?
        var spineSnapshotAction = "idle"
        var spineSnapshotTime = 0.0
        var spineSnapshotWidth = 1280
        var spineSnapshotHeight = 720
        var wallpaperSnapshotURL: URL?
        var wallpaperSnapshotReferenceURL: URL?
        var wallpaperGoldenCheckOnly = false
        var wallpaperGoldenURL: URL?
        var compositeQualityPlanOnly = false
        var compositeExportURL: URL?
        var compositeExportFps: Int?
        var compositeExportDuration: TimeInterval?
        var strictCompositeQuality = false
        var selfTestOnly = false
        var startHidden = false
        var interactive = true
        var launchControlPanel = true
        var launchWallpaper = true
        var launchAtLogin = false
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
                explicitWallpaperRoot = true
            case "--manifest":
                index += 1
                manifestURL = try valueURL(arguments, index, option: argument)
                explicitManifestURL = true
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
                guard let parsed = DisplayMode.parseCLI(raw) else {
                    throw EngineError.invalidArgument("Unknown --display-mode: \(raw)")
                }
                displayMode = parsed
                explicitDisplayMode = true
            case "--primary-display":
                index += 1
                let raw = try value(arguments, index, option: argument)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else {
                    throw EngineError.invalidArgument("--primary-display cannot be empty")
                }
                primaryDisplaySelector = trimmed
                explicitPrimaryDisplaySelector = true
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
                let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["display", "refresh", "native", "auto"].contains(normalized) {
                    renderFps = nil
                    matchDisplayRefresh = true
                } else if let parsed = Int(normalized), [30, 60].contains(parsed) {
                    renderFps = parsed
                    matchDisplayRefresh = false
                } else if let parsed = Int(normalized), parsed > 60 {
                    renderFps = nil
                    matchDisplayRefresh = true
                } else {
                    throw EngineError.invalidArgument("Invalid --fps: \(raw). Supported values: 30, 60, display")
                }
                explicitRenderFps = true
            case "--playback-rate":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = Float(raw), parsed.isFinite, parsed > 0, parsed <= 4 else {
                    throw EngineError.invalidArgument("Invalid --playback-rate: \(raw)")
                }
                playbackRateOverride = parsed
                explicitPlaybackRateOverride = true
            case "--audio":
                audioEnabled = true
                explicitAudioEnabled = true
            case "--mute", "--no-audio":
                audioEnabled = false
                explicitAudioEnabled = true
            case "--fit-mode":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = RenderFitMode(rawValue: raw) else {
                    throw EngineError.invalidArgument("Unknown --fit-mode: \(raw)")
                }
                fitMode = parsed
                explicitFitMode = true
            case "--foreground-mode":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = ForegroundRenderMode(rawValue: raw) else {
                    throw EngineError.invalidArgument("Unknown --foreground-mode: \(raw)")
                }
                foregroundMode = parsed
                explicitForegroundMode = true
            case "--interaction-debug-overlay":
                interactionDebugOverlay = true
            case "--validate-only":
                validateOnly = true
            case "--display-plan":
                displayPlanOnly = true
            case "--physical-display-plan":
                physicalDisplayPlanOnly = true
            case "--render-plan":
                renderPlanOnly = true
            case "--physical-render-plan":
                physicalRenderPlanOnly = true
            case "--simulated-render-plan":
                simulatedRenderPlanOnly = true
            case "--performance-plan":
                performancePlanOnly = true
            case "--runtime-capabilities":
                runtimeCapabilitiesOnly = true
            case "--doctor":
                doctorReportOnly = true
            case "--interaction-plan":
                interactionPlanOnly = true
            case "--probe-interaction":
                index += 1
                interactionProbePoint = try parseNormalizedPoint(try value(arguments, index, option: argument), option: argument)
            case "--probe-button":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = PointerButton(rawValue: raw) else {
                    throw EngineError.invalidArgument("Unknown --probe-button: \(raw). Supported values: left, right")
                }
                interactionProbeButton = parsed
            case "--spine-animation-plan":
                spineAnimationPlanOnly = true
            case "--spine-profile":
                spineProfileOnly = true
            case "--spine-snapshot":
                index += 1
                spineSnapshotURL = try valueURL(arguments, index, option: argument)
            case "--wallpaper-snapshot":
                index += 1
                wallpaperSnapshotURL = try valueURL(arguments, index, option: argument)
            case "--wallpaper-snapshot-reference":
                index += 1
                wallpaperSnapshotReferenceURL = try valueURL(arguments, index, option: argument)
            case "--wallpaper-golden-check":
                wallpaperGoldenCheckOnly = true
            case "--wallpaper-golden-file":
                index += 1
                wallpaperGoldenURL = try valueURL(arguments, index, option: argument)
            case "--snapshot-action":
                index += 1
                let raw = try value(arguments, index, option: argument)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else {
                    throw EngineError.invalidArgument("--snapshot-action cannot be empty")
                }
                spineSnapshotAction = trimmed
            case "--spine-snapshot-action":
                index += 1
                let raw = try value(arguments, index, option: argument)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else {
                    throw EngineError.invalidArgument("--spine-snapshot-action cannot be empty")
                }
                spineSnapshotAction = trimmed
            case "--snapshot-time":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = Double(raw), parsed.isFinite, parsed >= 0 else {
                    throw EngineError.invalidArgument("Invalid --snapshot-time: \(raw)")
                }
                spineSnapshotTime = parsed
            case "--spine-snapshot-time":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = Double(raw), parsed.isFinite, parsed >= 0 else {
                    throw EngineError.invalidArgument("Invalid --spine-snapshot-time: \(raw)")
                }
                spineSnapshotTime = parsed
            case "--snapshot-size":
                index += 1
                let raw = try value(arguments, index, option: argument)
                let parsedSize = try parsePixelSize(raw, option: argument)
                spineSnapshotWidth = parsedSize.width
                spineSnapshotHeight = parsedSize.height
            case "--spine-snapshot-size":
                index += 1
                let raw = try value(arguments, index, option: argument)
                let parsedSize = try parsePixelSize(raw, option: argument)
                spineSnapshotWidth = parsedSize.width
                spineSnapshotHeight = parsedSize.height
            case "--composite-quality-plan":
                compositeQualityPlanOnly = true
            case "--export-composite-video":
                index += 1
                compositeExportURL = try valueURL(arguments, index, option: argument)
            case "--export-composite-fps":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = Int(raw), parsed >= 1, parsed <= 240 else {
                    throw EngineError.invalidArgument("Invalid --export-composite-fps: \(raw). Expected 1...240")
                }
                compositeExportFps = parsed
            case "--export-composite-duration":
                index += 1
                let raw = try value(arguments, index, option: argument)
                guard let parsed = TimeInterval(raw), parsed.isFinite, parsed > 0, parsed <= 600 else {
                    throw EngineError.invalidArgument("Invalid --export-composite-duration: \(raw). Expected seconds in 0...600, excluding 0")
                }
                compositeExportDuration = parsed
            case "--strict-composite-quality":
                strictCompositeQuality = true
            case "--self-test":
                selfTestOnly = true
            case "--hidden":
                startHidden = true
            case "--pass-through":
                interactive = false
                explicitInteractive = true
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
            case "--launch-at-login":
                launchAtLogin = true
                explicitLaunchAtLogin = true
            case "--no-launch-at-login":
                launchAtLogin = false
                explicitLaunchAtLogin = true
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

        let ignoresPersistedSettings = validateOnly
            || displayPlanOnly
            || physicalDisplayPlanOnly
            || renderPlanOnly
            || physicalRenderPlanOnly
            || simulatedRenderPlanOnly
            || performancePlanOnly
            || runtimeCapabilitiesOnly
            || doctorReportOnly
            || interactionPlanOnly
            || interactionProbePoint != nil
            || spineAnimationPlanOnly
            || spineProfileOnly
            || spineSnapshotURL != nil
            || wallpaperSnapshotURL != nil
            || wallpaperGoldenCheckOnly
            || compositeQualityPlanOnly
            || compositeExportURL != nil
            || selfTestOnly
        let persistedSettings = ignoresPersistedSettings ? nil : RuntimeSettingsStore.load()
        if let persistedSettings {
            if !explicitDisplayMode, let persisted = persistedSettings.displayMode {
                displayMode = persisted
            }
            if !explicitPrimaryDisplaySelector {
                primaryDisplaySelector = persistedSettings.primaryDisplaySelector
            }
            if !explicitInteractive, let persisted = persistedSettings.interactive {
                interactive = persisted
            }
            if !explicitRenderFps, let persisted = persistedSettings.renderFps {
                renderFps = persisted
            }
            if !explicitRenderFps, let persisted = persistedSettings.matchDisplayRefresh {
                matchDisplayRefresh = persisted
            }
            if !explicitPlaybackRateOverride {
                playbackRateOverride = persistedSettings.playbackRateOverride
            }
            if !explicitAudioEnabled, let persisted = persistedSettings.audioEnabled {
                audioEnabled = persisted
            }
            if !explicitFitMode, let persisted = persistedSettings.fitMode {
                fitMode = persisted
            }
            if !explicitForegroundMode, let persisted = persistedSettings.foregroundMode {
                foregroundMode = persisted
            }
            if !explicitLaunchAtLogin, let persisted = persistedSettings.launchAtLogin {
                launchAtLogin = persisted
            }
        }

        let detectedRoot = try? ProjectPaths.findProjectRoot()
        let bundledWallpaperRoot = ProjectPaths.findBundledWallpaperRoot()
        let userWallpaperRoot = ProjectPaths.findUserWallpaperRoot()
        let catalogProjectRoot = ProjectPaths.findCatalogProjectRoot(detectedProjectRoot: detectedRoot)
        let resolvedWallpaperRoot: URL
        if let wallpaperRoot {
            resolvedWallpaperRoot = wallpaperRoot.standardizedFileURL
        } else if let manifestURL {
            resolvedWallpaperRoot = manifestURL.deletingLastPathComponent().standardizedFileURL
        } else if !explicitWallpaperRoot,
                  !explicitManifestURL,
                  let persistedRoot = RuntimeSettingsStore.validWallpaperRoot(from: persistedSettings) {
            resolvedWallpaperRoot = persistedRoot
        } else if let userWallpaperRoot {
            resolvedWallpaperRoot = userWallpaperRoot
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
            projectRoot: catalogProjectRoot ?? resolvedWallpaperRoot,
            wallpaperRoot: resolvedWallpaperRoot,
            manifestURL: resolvedManifest,
            level: level,
            displayMode: displayMode,
            primaryDisplaySelector: primaryDisplaySelector,
            duration: duration,
            renderFps: renderFps,
            matchDisplayRefresh: matchDisplayRefresh,
            playbackRateOverride: playbackRateOverride,
            audioEnabled: audioEnabled,
            fitMode: fitMode,
            foregroundMode: foregroundMode,
            interactionDebugOverlay: interactionDebugOverlay,
            validateOnly: validateOnly,
            displayPlanOnly: displayPlanOnly,
            physicalDisplayPlanOnly: physicalDisplayPlanOnly,
            renderPlanOnly: renderPlanOnly,
            physicalRenderPlanOnly: physicalRenderPlanOnly,
            simulatedRenderPlanOnly: simulatedRenderPlanOnly,
            performancePlanOnly: performancePlanOnly,
            runtimeCapabilitiesOnly: runtimeCapabilitiesOnly,
            doctorReportOnly: doctorReportOnly,
            interactionPlanOnly: interactionPlanOnly,
            interactionProbePoint: interactionProbePoint,
            interactionProbeButton: interactionProbeButton,
            spineAnimationPlanOnly: spineAnimationPlanOnly,
            spineProfileOnly: spineProfileOnly,
            spineSnapshotURL: spineSnapshotURL,
            spineSnapshotAction: spineSnapshotAction,
            spineSnapshotTime: spineSnapshotTime,
            spineSnapshotWidth: spineSnapshotWidth,
            spineSnapshotHeight: spineSnapshotHeight,
            wallpaperSnapshotURL: wallpaperSnapshotURL,
            wallpaperSnapshotReferenceURL: wallpaperSnapshotReferenceURL,
            wallpaperGoldenCheckOnly: wallpaperGoldenCheckOnly,
            wallpaperGoldenURL: wallpaperGoldenURL,
            compositeQualityPlanOnly: compositeQualityPlanOnly,
            compositeExportURL: compositeExportURL,
            compositeExportFps: compositeExportFps,
            compositeExportDuration: compositeExportDuration,
            strictCompositeQuality: strictCompositeQuality,
            selfTestOnly: selfTestOnly,
            startHidden: startHidden,
            interactive: interactive,
            launchControlPanel: launchControlPanel,
            launchWallpaper: launchWallpaper,
            launchAtLogin: launchAtLogin,
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

    private static func parsePixelSize(_ value: String, option: String) throws -> (width: Int, height: Int) {
        let separators = CharacterSet(charactersIn: "xX")
        let parts = value.components(separatedBy: separators)
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width > 0,
              height > 0,
              width <= 8192,
              height <= 8192 else {
            throw EngineError.invalidArgument("Invalid \(option): \(value). Expected WIDTHxHEIGHT up to 8192x8192")
        }
        return (width, height)
    }

    private static func parseNormalizedPoint(_ value: String, option: String) throws -> CGPoint {
        let separators = CharacterSet(charactersIn: ",:")
        let parts = value.components(separatedBy: separators)
        guard parts.count == 2,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              x.isFinite,
              y.isFinite,
              x >= 0,
              x <= 1,
              y >= 0,
              y <= 1 else {
            throw EngineError.invalidArgument("Invalid \(option): \(value). Expected normalized x,y in 0...1")
        }
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    static let help = """
    MacWallpaperEngine native runtime

    Options:
      --wallpaper-root <path>   Wallpaper bundle root. Defaults to the first valid bundle under wallpapers/.
      --manifest <path>         Native manifest path. Defaults to wallpaper.native.json under root.
      --display-mode <mode>     selectedOnly | selectedPolicy | allFull. Legacy aliases: primaryOnly | primaryAnimated | all. Default selectedOnly touches only the selected display.
      --primary-display <sel>   Treat a matching display as primary. Accepts displayID:<id>, fingerprint:<hash>, arrangement:<hash>, name:<name>, or raw id/hash/name.
      --level <level>           normal | desktop | desktopMinusOne | desktopPlusOne | backstop. Default: desktop.
      --duration <seconds>      Auto-quit after a short smoke run.
      --fps <value>             Render FPS: 30 | 60 | display. Values above 60 map to display refresh.
      --playback-rate <value>   Video playback rate override. Defaults to manifest asset rate.
      --audio                   Enable sound only for wallpapers whose manifest uses audioPolicy=userControlled.
      --mute, --no-audio        Keep wallpaper audio muted. Default and always enforced for muted/disabled manifests.
      --fit-mode <mode>         contain | fill. Default: contain.
      --foreground-mode <mode>  auto | composite | native. Default: auto.
      --interaction-debug-overlay
                              Draw pointer and pointerDown hit-zone diagnostics over the wallpaper.
      --list-bundles           Print validated wallpaper bundles and exit.
      --include-invalid        With --list-bundles, include invalid bundle diagnostics.
      --include-capabilities   With --list-bundles, include asset/layer/native fallback capability summary.
      --validate-bundles       Validate every discovered bundle through manifest, capability, render-plan, and native preflight gates.
      --bundle-library <path>  With --list-bundles/--validate-bundles, scan this library instead of default locations.
      --install-bundle <path>   Validate and copy a bundle into the user wallpaper library, then exit.
      --install-library <path>  Destination library for --install-bundle. Defaults to Application Support.
      --print-manifest-schema   Print the wallpaper.native.json JSON Schema for bundle authoring, then exit.
      --completion-audit       Print objective-level automated evidence and remaining manual completion evidence.
      --manual-smoke-evidence <json>
                              With --completion-audit, read user-recorded packaged launch, live click, and physical display smoke evidence.
      --write-manual-smoke-template <json>
                              Write a fill-in JSON template for the manual smoke evidence file, then exit.
      --recovery-plan          Print persisted renderer safe-mode recovery/quarantine state, then exit.
      --recovery-store <path>  Recovery state file for --recovery-plan. Defaults to Application Support.
      --display-plan           Print current monitor role/policy mapping and exit.
      --physical-display-plan  Print actual CoreGraphics display role/policy mapping and exit.
      --render-plan            Print effective per-display background/foreground renderer path and exit.
      --physical-render-plan   Print actual CoreGraphics display render path and exit.
      --simulated-render-plan  Print the same renderer path over a deterministic three-display fixture and exit.
      --performance-plan       Print manifest performance budget mapping and exit.
      --runtime-capabilities   Print manifest feature support and fallback mapping, then exit.
      --doctor                 Print bundle library, validation, capability, display, performance, interaction, and recovery preflight report, then exit.
      --interaction-plan       Print pointer move/click mapping and hit-zone probes, then exit.
      --probe-interaction <x,y>
                              Probe one normalized content coordinate through move, hit-zone, and click timeline mapping, then exit.
      --probe-button <button>  Button for --probe-interaction: left | right. Default: left.
      --spine-animation-plan   Print Spine animation durations, native geometry samples, and manifest action links, then exit.
      --spine-profile          Print native Spine geometry profiler, frame-budget, and pose-cache metrics, then exit.
      --spine-snapshot <png>   Render a native Spine diagnostic PNG on a white background, then exit.
      --wallpaper-snapshot <png>
                              Render a full diagnostic wallpaper PNG, then exit.
      --wallpaper-snapshot-reference <png>
                              With --wallpaper-snapshot, print pixel diff metrics against a reference PNG.
      --wallpaper-golden-check
                              Render every bundle golden fixture and fail if any pixel threshold is exceeded.
      --wallpaper-golden-file <json>
                              Override the bundle golden manifest. Defaults to golden/wallpaper.golden.json.
      --snapshot-action <name> Action to render for snapshot diagnostics. Default: idle.
      --snapshot-time <seconds>
                              Pose/video time for snapshot diagnostics. Default: 0.
      --snapshot-size <WxH>    Pixel size for snapshot diagnostics. Default: 1280x720.
      --spine-snapshot-action <name>
                              Backward-compatible alias for --snapshot-action.
      --spine-snapshot-time <seconds>
                              Backward-compatible alias for --snapshot-time.
      --spine-snapshot-size <WxH>
                              Backward-compatible alias for --snapshot-size.
      --composite-quality-plan Print composite fallback FPS/quality and regeneration target, then exit.
      --export-composite-video <mp4>
                              Render a native/source composite MP4 fallback, then exit.
      --export-composite-fps <n>
                              FPS for --export-composite-video. Default: manifest targetFps.
      --export-composite-duration <seconds>
                              Duration for --export-composite-video. Default: source video duration.
      --strict-composite-quality
                              Fail validation/quality-plan when composite fallback FPS is below target.
      --self-test              Run built-in policy/runtime self checks and exit.
      --validate-only           Validate manifest and assets without opening windows.
      --hidden                  Build host but keep windows hidden.
      --pass-through            Ignore mouse events and let desktop clicks pass through.
      --no-control-panel        Do not show the native control panel.
      --control-panel-only      Show only the control panel; do not start wallpaper windows.
      --wallpaper-only          Start wallpaper windows without the control panel.
      --no-wallpaper            Do not start wallpaper windows.
      --launch-at-login         Register the packaged app as a macOS login item.
      --no-launch-at-login      Unregister the packaged app login item. Default.
      --no-video                Disable video decoding and draw static fallback only.
      --no-metal                Use a plain NSView instead of MTKView for windowing diagnostics.
      --plain-window-style      Use titled normal app windows for windowing diagnostics.
    """
}

enum ProjectPaths {
    static let applicationSupportDirectoryName = "MacWallpaperEngine"

    static func findBundledWallpapersDirectory() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let directory = resourceURL.appendingPathComponent("wallpapers")
        return directoryExists(directory) ? directory : nil
    }

    static func findBundledWallpaperRoot() -> URL? {
        guard let directory = findBundledWallpapersDirectory() else { return nil }
        return findDefaultWallpaperRoot(in: directory)
    }

    static func userWallpapersDirectory() -> URL? {
        applicationSupportDirectory()?
            .appendingPathComponent("wallpapers", isDirectory: true)
    }

    static func applicationSupportDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    static func findUserWallpapersDirectory() -> URL? {
        guard let directory = userWallpapersDirectory(), directoryExists(directory) else { return nil }
        return directory
    }

    static func findUserWallpaperRoot() -> URL? {
        guard let directory = findUserWallpapersDirectory() else { return nil }
        return findDefaultWallpaperRoot(in: directory)
    }

    static func findCatalogProjectRoot(detectedProjectRoot: URL? = try? findProjectRoot()) -> URL? {
        if let bundledDirectory = findBundledWallpapersDirectory() {
            return bundledDirectory.deletingLastPathComponent()
        }
        return detectedProjectRoot
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
        WallpaperBundleCatalog.discover(in: wallpapersDirectory).first?.root
    }

    static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
