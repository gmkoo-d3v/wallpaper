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
            section("importedFields", provenance?.importedFields),
            section("calibratedFields", provenance?.calibratedFields),
            section("unsupportedFields", provenance?.unsupportedFields),
            section("notes", provenance?.notes)
        ].joined(separator: "\n")
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
