import Foundation

enum WallpaperBundleFilesystemGuard {
    static func rejectSymlinkEntries(in root: URL) throws {
        let fileManager = FileManager.default
        let root = root.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
        if rootValues.isSymbolicLink == true {
            throw EngineError.manifest("Wallpaper bundle rejects symlinked bundle roots: \(root.path)")
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            throw EngineError.invalidArgument("Could not enumerate wallpaper bundle: \(root.path)")
        }

        for case let url as URL in enumerator {
            if url.lastPathComponent == ".DS_Store" { continue }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw EngineError.manifest("Wallpaper bundle rejects symlinked entries: \(url.path)")
            }
        }
    }
}
