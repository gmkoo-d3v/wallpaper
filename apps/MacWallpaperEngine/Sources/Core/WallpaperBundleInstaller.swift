import Foundation

enum WallpaperBundleInstaller {
    static func install(
        sourceRoot: URL,
        libraryDirectory: URL? = ProjectPaths.userWallpapersDirectory()
    ) throws -> WallpaperBundleSummary {
        guard let resolvedLibraryDirectory = libraryDirectory else {
            throw EngineError.invalidArgument("Could not resolve the user wallpaper library directory.")
        }

        let requestedSourceRoot = sourceRoot.standardizedFileURL
        try WallpaperBundleFilesystemGuard.rejectSymlinkEntries(in: requestedSourceRoot)

        let resolvedSourceRoot = requestedSourceRoot.resolvingSymlinksInPath()
        let sourceBundle = try WallpaperBundleCatalog.requireValidBundle(requestedSourceRoot)

        let libraryDirectory = resolvedLibraryDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)

        if resolvedSourceRoot.path.hasPrefix(libraryDirectory.resolvingSymlinksInPath().path + "/") {
            return sourceBundle
        }

        if let conflictingBundle = WallpaperBundleCatalog.discover(in: libraryDirectory)
            .first(where: { $0.id == sourceBundle.id }) {
            throw EngineError.invalidArgument(
                "Wallpaper bundle is already installed as \(conflictingBundle.displayName): \(conflictingBundle.root.path)"
            )
        }

        let destination = libraryDirectory.appendingPathComponent(
            safeDirectoryName(for: sourceBundle.id),
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            throw EngineError.invalidArgument("Wallpaper library destination already exists: \(destination.path)")
        }

        do {
            try copyBundle(from: requestedSourceRoot, to: destination)
            return try WallpaperBundleCatalog.requireValidBundle(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func copyBundle(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            throw EngineError.invalidArgument("Could not enumerate wallpaper bundle: \(source.path)")
        }

        for case let sourceURL as URL in enumerator {
            if sourceURL.lastPathComponent == ".DS_Store" { continue }
            let relativePath = try relativePath(for: sourceURL, under: source)
            let destinationURL = destination.appendingPathComponent(relativePath)
            let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])

            if values.isDirectory == true {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
        }
    }

    private static func relativePath(for url: URL, under root: URL) throws -> String {
        let rootPaths = [
            root.standardizedFileURL.path,
            root.standardizedFileURL.resolvingSymlinksInPath().path
        ]
        let urlPaths = [
            url.standardizedFileURL.path,
            url.standardizedFileURL.resolvingSymlinksInPath().path
        ]

        for rootPath in rootPaths {
            for urlPath in urlPaths where urlPath.hasPrefix(rootPath + "/") {
                return String(urlPath.dropFirst(rootPath.count + 1))
            }
        }

        throw EngineError.invalidArgument("Could not derive bundle-relative path for \(url.path) under \(root.path)")
    }

    private static func safeDirectoryName(for bundleId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let name = String(bundleId.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return trimmed.isEmpty ? "wallpaper-bundle" : trimmed
    }
}
