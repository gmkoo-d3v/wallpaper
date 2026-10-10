import Foundation

enum WallpaperBundleInstaller {
    static func install(
        sourceRoot: URL,
        libraryDirectory: URL? = ProjectPaths.userWallpapersDirectory(),
        overwrite: Bool = false
    ) throws -> WallpaperBundleSummary {
        guard let resolvedLibraryDirectory = libraryDirectory else {
            throw EngineError.invalidArgument("Could not resolve the user wallpaper library directory.")
        }

        let requestedSourceRoot = sourceRoot.standardizedFileURL
        try WallpaperBundleFilesystemGuard.rejectSymlinkEntries(in: requestedSourceRoot)

        let resolvedSourceRoot = requestedSourceRoot.resolvingSymlinksInPath()
        let sourceBundle: WallpaperBundleSummary
        do {
            sourceBundle = try WallpaperBundleCatalog.requireValidBundle(requestedSourceRoot)
        } catch {
            if let importedBundle = try WallpaperEngineApplicationSourceImporter.install(
                sourceRoot: requestedSourceRoot,
                libraryDirectory: resolvedLibraryDirectory
            ) {
                return importedBundle
            }
            throw error
        }

        let libraryDirectory = resolvedLibraryDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)

        if resolvedSourceRoot.path.hasPrefix(libraryDirectory.resolvingSymlinksInPath().path + "/") {
            return sourceBundle
        }

        let destination = libraryDirectory.appendingPathComponent(
            safeDirectoryName(for: sourceBundle.id),
            isDirectory: true
        )

        if overwrite {
            try removeExistingLibraryEntry(
                matchingId: sourceBundle.id,
                in: libraryDirectory,
                destination: destination
            )
        } else if let conflictingBundle = WallpaperBundleCatalog.discover(in: libraryDirectory)
            .first(where: { $0.id == sourceBundle.id }) {
            throw EngineError.invalidArgument(
                "Wallpaper bundle is already installed as \(conflictingBundle.displayName): \(conflictingBundle.root.path)"
            )
        }

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
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

    // Overwrite removal rules, enforced as a strict two-pass sequence so the
    // preflight is genuinely "before any removal":
    // Pass 1 (preflight, zero mutations): scan every library diagnosis completely.
    //   Detection rule: a VALID entry with a DIFFERENT id whose root occupies the
    //   computed destination under a conservative case-insensitive name compare
    //   throws immediately and deletes nothing, because safeDirectoryName is not
    //   injective and a folder may hold a foreign bundle. Blocking an install on a
    //   case-variant name is safe even on case-sensitive volumes.
    //   The same pass collects removal targets without deleting: entries whose
    //   diagnosed id matches the incoming id (valid or invalid) and an INVALID
    //   entry located at the destination under exact standardized path equality.
    // Pass 2: delete only the collected targets. Removal uses exact standardized
    //   path equality (or id match), NEVER the case-insensitive detection compare,
    //   so a case-variant directory on a case-sensitive volume is never deleted.
    //   Deletion failures propagate: a surviving same-id entry would create a
    //   duplicate-id library, so overwrite must fail loudly instead of continuing.
    private static func removeExistingLibraryEntry(
        matchingId bundleId: String,
        in libraryDirectory: URL,
        destination: URL
    ) throws {
        let destinationPath = destination.standardizedFileURL.path

        var removalTargets: [URL] = []
        var collectedPaths = Set<String>()

        for diagnostic in WallpaperBundleCatalog.diagnose(in: libraryDirectory) {
            let child = diagnostic.root.standardizedFileURL
            guard isDirectChild(of: libraryDirectory, child: child) else {
                continue
            }

            if let bundle = diagnostic.bundle,
               bundle.id != bundleId,
               caseInsensitiveNameMatchesDestination(bundle.root.standardizedFileURL, destinationPath: destinationPath) {
                throw EngineError.invalidArgument(
                    "Wallpaper library already contains a different bundle at \(destination.path): \(bundle.id)"
                )
            }

            guard diagnostic.id == bundleId || exactPathMatchesDestination(child, destinationPath: destinationPath) else {
                continue
            }
            guard collectedPaths.insert(child.path).inserted else {
                continue
            }
            removalTargets.append(child)
        }

        if FileManager.default.fileExists(atPath: destinationPath),
           collectedPaths.insert(destinationPath).inserted,
           isDirectChild(of: libraryDirectory, child: destination) {
            removalTargets.append(destination)
        }

        for target in removalTargets {
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                throw EngineError.invalidArgument(
                    "Could not remove existing wallpaper library entry for overwrite: \(target.path) (\(error.localizedDescription))"
                )
            }
        }
    }

    // Detection rule only: same location under a case-insensitive final-component
    // compare. May block an install; must never be used to authorize a deletion.
    private static func caseInsensitiveNameMatchesDestination(_ child: URL, destinationPath: String) -> Bool {
        let childPath = child.standardizedFileURL.path
        if childPath == destinationPath {
            return true
        }
        let libraryPath = String(destinationPath[..<destinationPath.lastIndex(of: "/")!])
        guard childPath.hasPrefix(libraryPath + "/") else {
            return false
        }
        return String(childPath.dropFirst(libraryPath.count + 1))
            .caseInsensitiveCompare(String(destinationPath.dropFirst(libraryPath.count + 1))) == .orderedSame
    }

    // Deletion rule only: exact standardized path equality. On case-sensitive
    // volumes a case-variant directory is a different path and is never removed.
    private static func exactPathMatchesDestination(_ child: URL, destinationPath: String) -> Bool {
        child.standardizedFileURL.path == destinationPath
    }

    private static func isDirectChild(of libraryDirectory: URL, child: URL) -> Bool {
        let libraryPath = libraryDirectory.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        guard childPath.hasPrefix(libraryPath + "/") else {
            return false
        }
        return childPath.dropFirst(libraryPath.count + 1).contains("/") == false
    }

    private static func copyBundle(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            throw EngineError.invalidArgument("Could not enumerate wallpaper bundle: \(source.path)")
        }

        for case let sourceURL as URL in enumerator {
            if WallpaperBundleFilesystemGuard.shouldSkipMetadataEntry(sourceURL) {
                if (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
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
