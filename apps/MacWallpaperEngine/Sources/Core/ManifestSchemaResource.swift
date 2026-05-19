import Foundation

enum ManifestSchemaResource {
    static let directoryName = "schemas"
    static let fileName = "wallpaper-native-v2.schema.json"

    static func loadText(projectRoot: URL? = ProjectPaths.findCatalogProjectRoot()) throws -> String {
        for candidate in candidateURLs(projectRoot: projectRoot) {
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            return try String(contentsOf: candidate, encoding: .utf8)
        }
        throw EngineError.asset("Manifest schema resource missing: \(fileName)")
    }

    private static func candidateURLs(projectRoot: URL?) -> [URL] {
        var urls: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(directoryName).appendingPathComponent(fileName))
        }
        if let projectRoot {
            urls.append(
                projectRoot
                    .appendingPathComponent("apps/MacWallpaperEngine/Resources")
                    .appendingPathComponent(directoryName)
                    .appendingPathComponent(fileName)
            )
        }
        return urls
    }
}
