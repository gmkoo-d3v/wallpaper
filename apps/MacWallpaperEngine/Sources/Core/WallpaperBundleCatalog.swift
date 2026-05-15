import Foundation

struct WallpaperBundleSummary: Equatable {
    let id: String
    let displayName: String
    let root: URL
    let manifestURL: URL
}

enum WallpaperBundleCatalog {
    static func discoverDefaultBundles(projectRoot: URL? = try? ProjectPaths.findProjectRoot()) -> [WallpaperBundleSummary] {
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
        return discover(in: directories)
    }

    static func discover(in directories: [URL]) -> [WallpaperBundleSummary] {
        var seenPaths = Set<String>()
        var seenIds = Set<String>()
        var bundles: [WallpaperBundleSummary] = []

        for directory in directories {
            for bundle in discover(in: directory) {
                let key = bundle.root.standardizedFileURL.resolvingSymlinksInPath().path
                guard seenPaths.insert(key).inserted else { continue }
                guard seenIds.insert(bundle.id).inserted else { continue }
                bundles.append(bundle)
            }
        }

        return bundles.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    static func discover(in wallpapersDirectory: URL) -> [WallpaperBundleSummary] {
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
            .compactMap(validateBundle)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func validateBundle(_ url: URL) -> WallpaperBundleSummary? {
        do {
            return try requireValidBundle(url)
        } catch {
            fputs("Skipping invalid wallpaper bundle \(url.lastPathComponent): \(error.localizedDescription)\n", stderr)
            return nil
        }
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
            root: root,
            manifestURL: manifestURL
        )
    }

    private static func displayName(for root: URL) -> String {
        root.lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private static func metadataValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
