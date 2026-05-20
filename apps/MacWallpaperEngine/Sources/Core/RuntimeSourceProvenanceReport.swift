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
            "derivation: \(derivationStatus(runtime: runtime))",
            sourceDescriptorSection(provenance?.sourceDescriptors, projectRoot: runtime.config.projectRoot),
            section("importedFields", provenance?.importedFields),
            section("calibratedFields", provenance?.calibratedFields),
            section("platformPolicyFields", provenance?.platformPolicyFields),
            section("unsupportedFields", provenance?.unsupportedFields),
            section("notes", provenance?.notes)
        ].joined(separator: "\n")
    }

    static func derivationStatus(runtime: NativeRuntimeCore) -> String {
        derivationStatus(provenance: runtime.manifest.sourceProvenance)
    }

    static func derivationStatus(provenance: SourceProvenance?) -> String {
        guard let provenance else {
            return "sourceDerivation: unknown(no-source-provenance)"
        }

        let importedCount = provenance.importedFields?.count ?? 0
        let calibratedCount = provenance.calibratedFields?.count ?? 0
        let platformPolicyCount = provenance.platformPolicyFields?.count ?? 0
        let unsupportedCount = provenance.unsupportedFields?.count ?? 0
        if calibratedCount == 0, unsupportedCount == 0 {
            return "sourceDerivation: source-derived imported=\(importedCount) calibrated=0 platformPolicy=\(platformPolicyCount) unsupported=0"
        }

        var blockers: [String] = []
        if calibratedCount > 0 {
            blockers.append("manual-calibration")
        }
        if unsupportedCount > 0 {
            blockers.append("unsupported-source-behavior")
        }

        return [
            "sourceDerivation: partial",
            "imported=\(importedCount)",
            "calibrated=\(calibratedCount)",
            "platformPolicy=\(platformPolicyCount)",
            "unsupported=\(unsupportedCount)",
            "blockers=\(blockers.joined(separator: "+"))"
        ].joined(separator: " ")
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

        for descriptor in descriptors where descriptor.kind == .unityManagedScriptIndex {
            let descriptorURL = runtime.config.projectRoot
                .appendingPathComponent(descriptor.path)
                .standardizedFileURL
            guard let data = try? Data(contentsOf: descriptorURL) else {
                warnings.append("missing(\(descriptor.path))")
                continue
            }

            let scriptIndex = try JSONDecoder().decode(UnityManagedScriptIndexDescriptor.self, from: data)
            try validateManagedScriptIndex(scriptIndex, descriptor: descriptor)
            checks.insert("managedScripts=metadata-only")

            let assemblyCounts = Dictionary(grouping: scriptIndex.assemblyScripts ?? [], by: \.assembly)
                .mapValues(\.count)
            if let assemblyCSharpCount = assemblyCounts["Assembly-CSharp"] {
                checks.insert("behaviorScripts=Assembly-CSharp:\(assemblyCSharpCount)")
            }

            if runtime.manifest.interactions.isEmpty == false {
                guard let candidate = scriptIndex.interactionCandidates?.first else {
                    throw EngineError.manifest("source provenance contradiction: manifest declares interactions but \(descriptor.path) has no interaction owner candidates")
                }
                checks.insert("interactionOwner=\(candidate.className)")
            }

            let calibratedFields = Set(runtime.manifest.sourceProvenance?.calibratedFields ?? [])
            if calibratedFields.isEmpty == false {
                let blockedFields = scriptIndex.blockedFields ?? []
                let blockedFieldNames = Set(blockedFields.map(\.field))
                let missingFields = calibratedFields.subtracting(blockedFieldNames)
                guard missingFields.isEmpty else {
                    throw EngineError.manifest(
                        "source provenance contradiction: calibrated field(s) lack source-adapter blocker ownership in \(descriptor.path): "
                            + missingFields.sorted().joined(separator: ",")
                    )
                }

                let ownerCounts = Dictionary(grouping: blockedFields.filter { calibratedFields.contains($0.field) }, by: \.owner)
                    .mapValues(\.count)
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ",")
                checks.insert("calibratedBlockers=\(ownerCounts)")
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

    private static func validateManagedScriptIndex(
        _ index: UnityManagedScriptIndexDescriptor,
        descriptor: SourceDescriptor
    ) throws {
        guard index.securityPolicy?.windowsExecutableExecution == "forbidden",
              index.securityPolicy?.windowsExecutableDisassembly == "forbidden",
              index.securityPolicy?.methodBodyRead == "forbidden",
              index.methodBodyStatus == "not-read" else {
            throw EngineError.manifest("source provenance safety policy must keep Unity managed script method bodies unread for \(descriptor.path)")
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
            case .unityManagedScriptIndex:
                return unityManagedScriptIndexLine(descriptor: descriptor, url: descriptorURL)
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

    private static func unityManagedScriptIndexLine(descriptor: SourceDescriptor, url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return "\(descriptor.kind.rawValue) path=\(descriptor.path) status=missing"
        }

        do {
            let index = try JSONDecoder().decode(UnityManagedScriptIndexDescriptor.self, from: data)
            let scripts = index.assemblyScripts ?? []
            let assemblyCounts = Dictionary(grouping: scripts, by: \.assembly)
                .mapValues(\.count)
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            let candidates = (index.interactionCandidates ?? [])
                .map(\.className)
                .sorted()
                .joined(separator: ",")
            let blockedFields = index.blockedFields ?? []
            let blockedFieldOwners = Dictionary(grouping: blockedFields, by: \.owner)
                .mapValues(\.count)
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ",")
            let requiredCapabilities = Set(blockedFields.map(\.requiredCapability))
                .sorted()
                .joined(separator: ",")
            let security = [
                index.securityPolicy?.windowsExecutableExecution.map { "windowsExecutableExecution=\($0)" },
                index.securityPolicy?.windowsExecutableDisassembly.map { "windowsExecutableDisassembly=\($0)" },
                index.securityPolicy?.methodBodyRead.map { "methodBodyRead=\($0)" },
                index.securityPolicy?.inputScope.map { "inputScope=\($0.replacingOccurrences(of: " ", with: "_"))" }
            ]
                .compactMap { $0 }
                .joined(separator: ",")
            let fields = [
                "path=\(descriptor.path)",
                "status=read",
                "converter=\(index.converter ?? "unspecified")",
                "scripts=\(assemblyCounts.isEmpty ? "none" : assemblyCounts)",
                "interactionCandidates=\(candidates.isEmpty ? "none" : candidates)",
                "blockedFields=\(blockedFields.count)",
                "blockedFieldOwners=\(blockedFieldOwners.isEmpty ? "none" : blockedFieldOwners)",
                "requiredCapabilities=\(requiredCapabilities.isEmpty ? "none" : requiredCapabilities)",
                "methodBodyStatus=\(index.methodBodyStatus ?? "unspecified")",
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

private struct UnityManagedScriptIndexDescriptor: Decodable {
    let converter: String?
    let securityPolicy: UnityManagedScriptIndexSecurityPolicy?
    let methodBodyStatus: String?
    let assemblyScripts: [UnityManagedScriptRecord]?
    let interactionCandidates: [UnityInteractionCandidate]?
    let blockedFields: [UnityBlockedSourceField]?

    private enum CodingKeys: String, CodingKey {
        case converter
        case securityPolicy = "security_policy"
        case methodBodyStatus = "method_body_status"
        case assemblyScripts = "assembly_scripts"
        case interactionCandidates = "interaction_candidates"
        case blockedFields = "blocked_fields"
    }
}

private struct UnityManagedScriptIndexSecurityPolicy: Decodable {
    let windowsExecutableExecution: String?
    let windowsExecutableDisassembly: String?
    let methodBodyRead: String?
    let inputScope: String?

    private enum CodingKeys: String, CodingKey {
        case windowsExecutableExecution = "windows_executable_execution"
        case windowsExecutableDisassembly = "windows_executable_disassembly"
        case methodBodyRead = "method_body_read"
        case inputScope = "input_scope"
    }
}

private struct UnityManagedScriptRecord: Decodable {
    let assembly: String
    let className: String
    let namespace: String?
    let source: String?
    let pathID: Int?
}

private struct UnityInteractionCandidate: Decodable {
    let assembly: String?
    let className: String
    let reason: String?
}

private struct UnityBlockedSourceField: Decodable {
    let field: String
    let owner: String
    let requiredCapability: String
    let reason: String?
}
