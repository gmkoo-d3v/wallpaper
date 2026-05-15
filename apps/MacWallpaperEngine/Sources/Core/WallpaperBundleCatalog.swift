import Foundation

struct WallpaperBundleSummary: Equatable {
    let id: String
    let displayName: String
    let author: String?
    let version: String?
    let description: String?
    let previewURL: URL?
    let capabilities: WallpaperBundleCapabilityInfo
    let root: URL
    let manifestURL: URL
}

enum WallpaperBundleDiagnosticStatus: String {
    case valid
    case invalid
}

struct WallpaperBundleDiagnostic {
    let root: URL
    let status: WallpaperBundleDiagnosticStatus
    let bundle: WallpaperBundleSummary?
    let errorMessage: String?

    var id: String {
        bundle?.id ?? root.lastPathComponent
    }

    var displayName: String {
        bundle?.displayName ?? root.lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}

enum WallpaperBundleCatalog {
    static func diagnoseDefaultBundles(projectRoot: URL? = try? ProjectPaths.findProjectRoot()) -> [WallpaperBundleDiagnostic] {
        var directories: [URL] = []
        if let bundledDirectory = ProjectPaths.findBundledWallpapersDirectory() {
            directories.append(bundledDirectory)
        }
        if let userDirectory = ProjectPaths.findUserWallpapersDirectory() {
            directories.append(userDirectory)
        }
        if let projectRoot {
            directories.append(projectRoot.appendingPathComponent("wallpapers"))
        }
        return diagnose(in: directories)
    }

    static func discoverDefaultBundles(projectRoot: URL? = try? ProjectPaths.findProjectRoot()) -> [WallpaperBundleSummary] {
        diagnoseDefaultBundles(projectRoot: projectRoot).compactMap(\.bundle)
    }

    static func discover(in directories: [URL]) -> [WallpaperBundleSummary] {
        diagnose(in: directories).compactMap(\.bundle)
    }

    static func diagnose(in directories: [URL]) -> [WallpaperBundleDiagnostic] {
        var seenPaths = Set<String>()
        var seenIds: [String: WallpaperBundleSummary] = [:]
        var diagnostics: [WallpaperBundleDiagnostic] = []

        for directory in directories {
            for diagnostic in diagnose(in: directory) {
                let key = diagnostic.root.standardizedFileURL.resolvingSymlinksInPath().path
                guard seenPaths.insert(key).inserted else { continue }
                if let bundle = diagnostic.bundle {
                    if let existingBundle = seenIds[bundle.id] {
                        diagnostics.append(WallpaperBundleDiagnostic(
                            root: diagnostic.root,
                            status: .invalid,
                            bundle: nil,
                            errorMessage: "Duplicate wallpaper bundle id \(bundle.id); using \(existingBundle.root.path)"
                        ))
                        continue
                    }
                    seenIds[bundle.id] = bundle
                }
                diagnostics.append(diagnostic)
            }
        }

        return diagnostics.sorted {
            let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return $0.root.path.localizedStandardCompare($1.root.path) == .orderedAscending
        }
    }

    static func discover(in wallpapersDirectory: URL) -> [WallpaperBundleSummary] {
        diagnose(in: wallpapersDirectory).compactMap(\.bundle)
    }

    static func diagnose(in wallpapersDirectory: URL) -> [WallpaperBundleDiagnostic] {
        candidateBundleDirectories(in: wallpapersDirectory)
            .map(diagnoseBundle)
    }

    static func validateBundle(_ url: URL) -> WallpaperBundleSummary? {
        let diagnostic = diagnoseBundle(url)
        if case .invalid = diagnostic.status, let errorMessage = diagnostic.errorMessage {
            fputs("Skipping invalid wallpaper bundle \(url.lastPathComponent): \(errorMessage)\n", stderr)
        }
        return diagnostic.bundle
    }

    static func requireValidBundle(_ url: URL) throws -> WallpaperBundleSummary {
        let root = url.standardizedFileURL
        guard ProjectPaths.directoryExists(root) else {
            throw EngineError.invalidArgument("Wallpaper bundle is not a directory: \(root.path)")
        }
        let manifestURL = root.appendingPathComponent("wallpaper.native.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw EngineError.manifest("Wallpaper bundle does not contain wallpaper.native.json: \(root.path)")
        }

        let manifest = try ManifestLoader.load(url: manifestURL, bundleRoot: root)
        return WallpaperBundleSummary(
            id: metadataValue(manifest.metadata?.id) ?? root.lastPathComponent,
            displayName: metadataValue(manifest.metadata?.title) ?? displayName(for: root),
            author: metadataValue(manifest.metadata?.author),
            version: metadataValue(manifest.metadata?.version),
            description: metadataValue(manifest.metadata?.description),
            previewURL: previewURL(for: manifest, root: root),
            capabilities: RuntimeCapabilities.bundleInfo(manifest: manifest, bundleRoot: root),
            root: root,
            manifestURL: manifestURL
        )
    }

    static func invalidDiagnosticsSummary(for diagnostics: [WallpaperBundleDiagnostic]) -> String {
        let invalidDiagnostics = diagnostics.filter { $0.status == .invalid }
        guard invalidDiagnostics.isEmpty == false else { return "" }

        let shown = invalidDiagnostics.prefix(2).map {
            "\($0.root.lastPathComponent): \($0.errorMessage ?? "invalid bundle")"
        }
        let remaining = invalidDiagnostics.count - shown.count
        let suffix = remaining > 0 ? " (+\(remaining) more)" : ""
        return "Invalid bundles: " + shown.joined(separator: " / ") + suffix
    }

    private static func candidateBundleDirectories(in wallpapersDirectory: URL) -> [URL] {
        let directory = wallpapersDirectory.standardizedFileURL
        guard ProjectPaths.directoryExists(directory),
              let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return children
            .filter(ProjectPaths.directoryExists)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func diagnoseBundle(_ url: URL) -> WallpaperBundleDiagnostic {
        let root = url.standardizedFileURL
        do {
            let bundle = try requireValidBundle(root)
            return WallpaperBundleDiagnostic(root: bundle.root, status: .valid, bundle: bundle, errorMessage: nil)
        } catch {
            return WallpaperBundleDiagnostic(root: root, status: .invalid, bundle: nil, errorMessage: error.localizedDescription)
        }
    }

    private static func displayName(for root: URL) -> String {
        root.lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private static func previewURL(for manifest: WallpaperNativeManifest, root: URL) -> URL? {
        let preview = root.appendingPathComponent("preview.jpg").standardizedFileURL
        if FileManager.default.fileExists(atPath: preview.path) {
            return preview
        }

        guard let staticImagePath = manifest.assets.staticImage?.path else {
            return nil
        }
        let staticImage = root.appendingPathComponent(staticImagePath).standardizedFileURL
        return FileManager.default.fileExists(atPath: staticImage.path) ? staticImage : nil
    }

    private static func metadataValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
