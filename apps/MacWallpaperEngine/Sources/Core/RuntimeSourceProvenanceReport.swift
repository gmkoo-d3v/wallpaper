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
            "consistency: \(consistencyLine(runtime: runtime))",
            sourceDescriptorSection(provenance?.sourceDescriptors, projectRoot: runtime.config.projectRoot),
            section("importedFields", provenance?.importedFields),
            section("calibratedFields", provenance?.calibratedFields),
            section("unsupportedFields", provenance?.unsupportedFields),
            section("notes", provenance?.notes)
        ].joined(separator: "\n")
    }

    static func consistencyStatus(runtime: NativeRuntimeCore) throws -> String {
        let descriptors = runtime.manifest.sourceProvenance?.sourceDescriptors ?? []
        guard descriptors.isEmpty == false else {
            return "sourceProvenance: skipped(no-descriptors)"
        }

        var readableUnityExtractionCount = 0
        var checks = Set<String>()
        var warnings: [String] = []

        for descriptor in descriptors where descriptor.kind == .unityAssetExtractionManifest {
            let descriptorURL = runtime.config.projectRoot
                .appendingPathComponent(descriptor.path)
                .standardizedFileURL
            guard let data = try? Data(contentsOf: descriptorURL) else {
                warnings.append("missing(\(descriptor.path))")
                continue
            }

            let extraction = try JSONDecoder().decode(UnityAssetExtractionDescriptor.self, from: data)
            readableUnityExtractionCount += 1
            try validateSecurityPolicy(extraction.securityPolicy, descriptor: descriptor)
            checks.insert("safety=windows-exe-forbidden")

            let counts = extraction.counts ?? [:]
            if runtime.manifest.assets.video != nil {
                let videoCount = counts["VideoClip"] ?? 0
                guard videoCount > 0 else {
                    throw EngineError.manifest("source provenance contradiction: manifest declares a video asset but \(descriptor.path) reports VideoClip=0")
                }
                checks.insert("video=VideoClip:\(videoCount)")
            }

            if runtime.manifest.assets.spine != nil {
                let textAssetCount = counts["TextAsset"] ?? 0
                let textureCount = counts["Texture2D"] ?? 0
                guard textAssetCount > 0 else {
                    throw EngineError.manifest("source provenance contradiction: manifest declares a Spine asset but \(descriptor.path) reports TextAsset=0")
                }
                guard textureCount > 0 else {
                    throw EngineError.manifest("source provenance contradiction: manifest declares a Spine asset but \(descriptor.path) reports Texture2D=0")
                }
                checks.insert("spine=TextAsset:\(textAssetCount)+Texture2D:\(textureCount)")
            }

            if runtime.manifest.assets.staticImage != nil {
                let imageSourceCount = (counts["Texture2D"] ?? 0) + (counts["Sprite"] ?? 0)
                guard imageSourceCount > 0 else {
                    throw EngineError.manifest("source provenance contradiction: manifest declares a static image asset but \(descriptor.path) reports no Texture2D/Sprite assets")
                }
                checks.insert("staticImage=TextureOrSprite:\(imageSourceCount)")
            }
        }

        guard readableUnityExtractionCount > 0 else {
            if warnings.isEmpty {
                return "sourceProvenance: skipped(no-readable-unity-extraction-descriptor)"
            }
            return "sourceProvenance: warn \(warnings.sorted().joined(separator: "+"))"
        }

        let checkText = checks.isEmpty ? "no-asset-cross-checks" : checks.sorted().joined(separator: " ")
        return "sourceProvenance: pass \(checkText)"
    }

    private static func consistencyLine(runtime: NativeRuntimeCore) -> String {
        do {
            return try consistencyStatus(runtime: runtime)
        } catch {
            return "sourceProvenance: fail \(error.localizedDescription)"
        }
    }

    private static func validateSecurityPolicy(
        _ policy: UnityAssetExtractionSecurityPolicy?,
        descriptor: SourceDescriptor
    ) throws {
        guard policy?.windowsExecutableExecution == "forbidden",
              policy?.windowsExecutableDisassembly == "forbidden" else {
            throw EngineError.manifest("source provenance safety policy must forbid Windows executable execution and disassembly for \(descriptor.path)")
        }
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
            case .unityAssetExtractionManifest:
                return unityAssetExtractionLine(descriptor: descriptor, url: descriptorURL)
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

    private static func unityAssetExtractionLine(descriptor: SourceDescriptor, url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return "\(descriptor.kind.rawValue) path=\(descriptor.path) status=missing"
        }

        do {
            let manifest = try JSONDecoder().decode(UnityAssetExtractionDescriptor.self, from: data)
            let counts = (manifest.counts ?? [:])
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            let security = [
                manifest.securityPolicy?.windowsExecutableExecution.map { "windowsExecutableExecution=\($0)" },
                manifest.securityPolicy?.windowsExecutableDisassembly.map { "windowsExecutableDisassembly=\($0)" },
                manifest.securityPolicy?.inputScope.map { "inputScope=\($0.replacingOccurrences(of: " ", with: "_"))" }
            ]
                .compactMap { $0 }
                .joined(separator: ",")
            let fields = [
                "path=\(descriptor.path)",
                "status=read",
                "converter=\(manifest.converter ?? "unspecified")",
                "counts=\(counts.isEmpty ? "none" : counts)",
                "security=\(security.isEmpty ? "unspecified" : security)"
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

private struct UnityAssetExtractionDescriptor: Decodable {
    let converter: String?
    let securityPolicy: UnityAssetExtractionSecurityPolicy?
    let counts: [String: Int]?

    private enum CodingKeys: String, CodingKey {
        case converter
        case securityPolicy = "security_policy"
        case counts
    }
}

private struct UnityAssetExtractionSecurityPolicy: Decodable {
    let windowsExecutableExecution: String?
    let windowsExecutableDisassembly: String?
    let inputScope: String?

    private enum CodingKeys: String, CodingKey {
        case windowsExecutableExecution = "windows_executable_execution"
        case windowsExecutableDisassembly = "windows_executable_disassembly"
        case inputScope = "input_scope"
    }
}
