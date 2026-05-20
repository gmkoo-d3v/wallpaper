import Foundation

enum RuntimeSourceProvenanceReport {
    static func make(runtime: NativeRuntimeCore) -> String {
        let manifest = runtime.manifest
        let provenance = manifest.sourceProvenance
        let sourceType = provenance?.sourceType.rawValue ?? "unspecified"
        let sourceRuntime = provenance?.sourceRuntime ?? "unspecified"
        let projectType = provenance?.projectType ?? "unspecified"

        return [
            "source provenance OK",
            "bundle: \(runtime.config.wallpaperRoot.path)",
            "manifest: \(runtime.config.manifestURL.path)",
            "sourceType: \(sourceType)",
            "sourceRuntime: \(sourceRuntime)",
            "projectType: \(projectType)",
            "boundary: runtime=generic-player manifest=bundle-contract importer=source-adapter",
            "policy: wallpaper-specific placement, hit zones, action names, timing, and neutral points must stay in the manifest or importer output.",
            sourceDescriptorSection(provenance?.sourceDescriptors, projectRoot: runtime.config.projectRoot),
            section("importedFields", provenance?.importedFields),
            section("calibratedFields", provenance?.calibratedFields),
            section("unsupportedFields", provenance?.unsupportedFields),
            section("notes", provenance?.notes)
        ].joined(separator: "\n")
    }

    private static func sourceDescriptorSection(_ descriptors: [SourceDescriptor]?, projectRoot: URL) -> String {
        guard let descriptors, descriptors.isEmpty == false else {
            return "sourceDescriptors: none"
        }

        let lines = descriptors.map { descriptor -> String in
            let descriptorURL = projectRoot.appendingPathComponent(descriptor.path).standardizedFileURL
            switch descriptor.kind {
            case .wallpaperEngineProjectJSON:
                return wallpaperEngineProjectLine(descriptor: descriptor, url: descriptorURL)
            }
        }
        return "sourceDescriptors:\n" + lines.map { "  - \($0)" }.joined(separator: "\n")
    }

    private static func wallpaperEngineProjectLine(descriptor: SourceDescriptor, url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return "\(descriptor.kind.rawValue) path=\(descriptor.path) status=missing"
        }

        do {
            let project = try JSONDecoder().decode(WallpaperEngineProjectDescriptor.self, from: data)
            let fields = [
                "path=\(descriptor.path)",
                "status=read",
                "type=\(project.type ?? "unspecified")",
                "title=\(project.title ?? "unspecified")",
                "file=\(project.file ?? "unspecified")",
                "preview=\(project.preview ?? "unspecified")",
                "version=\(project.version.map(String.init) ?? "unspecified")"
            ]
            return "\(descriptor.kind.rawValue) " + fields.joined(separator: " ")
        } catch {
            return "\(descriptor.kind.rawValue) path=\(descriptor.path) status=unreadable(\(error.localizedDescription))"
        }
    }

    private static func section(_ name: String, _ values: [String]?) -> String {
        guard let values, values.isEmpty == false else {
            return "\(name): none"
        }

        let itemText = values
            .sorted()
            .map { "  - \($0)" }
            .joined(separator: "\n")
        return "\(name):\n\(itemText)"
    }
}

private struct WallpaperEngineProjectDescriptor: Decodable {
    let file: String?
    let preview: String?
    let title: String?
    let type: String?
    let version: Int?
}
