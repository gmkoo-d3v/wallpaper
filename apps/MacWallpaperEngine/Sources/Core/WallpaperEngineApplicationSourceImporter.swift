import Foundation

private struct WallpaperEngineApplicationProject: Decodable {
    let file: String?
    let title: String?
    let type: String?
    let preview: String?
    let version: Int?
}

enum WallpaperEngineApplicationSourceImporter {
    static func install(
        sourceRoot: URL,
        libraryDirectory: URL
    ) throws -> WallpaperBundleSummary? {
        let root = sourceRoot.standardizedFileURL
        guard ProjectPaths.directoryExists(root),
              let project = try loadApplicationProject(in: root) else {
            return nil
        }

        let adapterBundle = try findNativeAdapterBundle(for: project, excluding: root)
        guard let adapterBundle else {
            throw EngineError.manifest(
                "Wallpaper Engine application import requires a native source adapter for \(project.title ?? root.lastPathComponent). "
                    + "No EXE, DLL, Wine, or arbitrary Unity runtime execution is allowed."
            )
        }

        return try WallpaperBundleInstaller.install(
            sourceRoot: adapterBundle.root,
            libraryDirectory: libraryDirectory
        )
    }

    private static func loadApplicationProject(in root: URL) throws -> WallpaperEngineApplicationProject? {
        let projectURL = root.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: projectURL)
        let project = try JSONDecoder().decode(WallpaperEngineApplicationProject.self, from: data)
        guard project.type == "application" else {
            return nil
        }
        try validateApplicationProject(project, root: root)
        return project
    }

    private static func validateApplicationProject(
        _ project: WallpaperEngineApplicationProject,
        root: URL
    ) throws {
        guard let file = project.file?.trimmingCharacters(in: .whitespacesAndNewlines),
              file.isEmpty == false else {
            throw EngineError.manifest("Wallpaper Engine application project.json must declare a file")
        }
        guard file.hasPrefix("/") == false,
              file.contains("\\") == false,
              file.split(separator: "/").contains("..") == false else {
            throw EngineError.manifest("Wallpaper Engine application file path must be relative and must not escape the project")
        }
        let executableURL = root.appendingPathComponent(file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw EngineError.asset("missing Wallpaper Engine application file: \(executableURL.path)")
        }
    }

    private static func findNativeAdapterBundle(
        for project: WallpaperEngineApplicationProject,
        excluding sourceRoot: URL
    ) throws -> WallpaperBundleSummary? {
        let excludedPath = sourceRoot.resolvingSymlinksInPath().path
        let targetKeys = matchKeys(for: project)
        guard targetKeys.isEmpty == false else { return nil }

        for bundle in WallpaperBundleCatalog.discoverDefaultBundles() {
            let bundlePath = bundle.root.resolvingSymlinksInPath().path
            guard bundlePath != excludedPath else { continue }
            let manifest = try ManifestLoader.load(url: bundle.manifestURL, bundleRoot: bundle.root)
            guard manifest.sourceProvenance?.sourceType == .wallpaperEngineApplication else {
                continue
            }
            let bundleKeys = matchKeys(for: manifest, summary: bundle)
            let requiredMatches = min(targetKeys.count, 2)
            if targetKeys.intersection(bundleKeys).count >= requiredMatches {
                return bundle
            }
        }
        return nil
    }

    private static func matchKeys(for project: WallpaperEngineApplicationProject) -> Set<String> {
        var keys = Set<String>()
        insertKey(project.title, into: &keys)
        insertKey(project.file.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }, into: &keys)
        return keys
    }

    private static func matchKeys(
        for manifest: WallpaperNativeManifest,
        summary: WallpaperBundleSummary
    ) -> Set<String> {
        var keys = Set<String>()
        insertKey(manifest.metadata?.id, into: &keys)
        insertKey(manifest.metadata?.title, into: &keys)
        insertKey(summary.id, into: &keys)
        insertKey(summary.displayName, into: &keys)
        return keys
    }

    private static func insertKey(_ value: String?, into keys: inout Set<String>) {
        guard let key = normalizedKey(value), key.isEmpty == false else { return }
        keys.insert(key)
    }

    private static func normalizedKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        let collapsed = String(scalars)
            .split(separator: "_")
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return collapsed.isEmpty ? nil : collapsed
    }
}
