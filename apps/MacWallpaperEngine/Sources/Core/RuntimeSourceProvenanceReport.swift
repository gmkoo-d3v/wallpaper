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
            sourceAdapterSection(provenance?.sourceAdapter),
            sourceDescriptorSection(provenance?.sourceDescriptors, projectRoot: runtime.config.projectRoot),
            section("importedFields", provenance?.importedFields),
            section("calibratedFields", provenance?.calibratedFields),
            section("platformPolicyFields", provenance?.platformPolicyFields),
            section("unsupportedFields", provenance?.unsupportedFields),
            section("notes", provenance?.notes)
        ].joined(separator: "\n")
    }

    static func makeLibraryReport(
        projectRoot: URL?,
        includeInvalid: Bool,
        bundleDirectories: [URL]? = nil
    ) throws -> String {
        let diagnostics = bundleDirectories.map(WallpaperBundleCatalog.diagnose(in:))
            ?? WallpaperBundleCatalog.diagnoseDefaultBundles(projectRoot: projectRoot)
        let bundles = diagnostics.compactMap(\.bundle)
        let invalidDiagnostics = diagnostics.filter { $0.status == .invalid }
        guard bundles.isEmpty == false else {
            if invalidDiagnostics.isEmpty == false {
                throw EngineError.invalidArgument(
                    "No valid wallpaper bundles found for source adapter audit.\nInvalid diagnostics:\n"
                        + invalidDiagnosticsDetails(invalidDiagnostics)
                )
            }
            throw EngineError.invalidArgument("No valid wallpaper bundles found for source adapter audit.")
        }

        var rows: [String] = []
        var failures: [String] = []

        for bundle in bundles {
            do {
                let config = try EngineConfig.parse([
                    "--wallpaper-root", bundle.root.path,
                    "--manifest", bundle.manifestURL.path,
                    "--validate-only"
                ])
                let runtime = try NativeRuntimeCore(config: config)
                let provenance = runtime.manifest.sourceProvenance
                rows.append([
                    "valid",
                    bundle.id,
                    sourceSummary(provenance),
                    try sourceAdapterStatus(provenance: provenance),
                    derivationStatus(provenance: provenance),
                    try consistencyStatus(runtime: runtime)
                ].joined(separator: "\t"))
            } catch {
                failures.append("\(bundle.id): \(error.localizedDescription)")
                rows.append([
                    "failed",
                    bundle.id,
                    "source=unknown",
                    "sourceAdapter=fail",
                    "sourceDerivation=unknown",
                    error.localizedDescription
                ].joined(separator: "\t"))
            }
        }

        if includeInvalid {
            for diagnostic in invalidDiagnostics {
                rows.append([
                    "invalid",
                    diagnostic.id,
                    "source=unknown",
                    "sourceAdapter=invalid-bundle",
                    "sourceDerivation=unknown",
                    diagnostic.errorMessage ?? "invalid bundle"
                ].joined(separator: "\t"))
            }
        }

        if invalidDiagnostics.isEmpty == false {
            failures.append("Invalid bundle diagnostics:\n\(invalidDiagnosticsDetails(invalidDiagnostics))")
        }

        if failures.isEmpty == false {
            let details = failures.map { "- \($0)" }.joined(separator: "\n")
            throw EngineError.invalidArgument("Source adapter audit failed:\n\(details)")
        }

        return """
        source adapter audit OK
        validBundles: \(bundles.count)
        invalidDiagnostics: \(invalidDiagnostics.count)
        columns: status\tid\tsource\tadapter\tderivation\tconsistency
        \(rows.joined(separator: "\n"))
        """
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

        if let sourceAdapterCheck = try validateSourceAdapterContract(runtime.manifest.sourceProvenance) {
            checks.insert(sourceAdapterCheck)
        }

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

            let serializedFieldCounts = serializedFieldCounts(scriptIndex.serializedBehaviourFields)
            if serializedFieldCounts.isEmpty == false {
                checks.insert("serializedFields=\(serializedFieldCounts)")
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

    private static func validateSourceAdapterContract(_ provenance: SourceProvenance?) throws -> String? {
        guard let adapter = provenance?.sourceAdapter else {
            return nil
        }

        let derivations = adapter.fieldDerivations ?? []
        guard derivations.isEmpty == false else {
            throw EngineError.manifest("source adapter \(adapter.id) must declare fieldDerivations")
        }

        var seenFields = Set<String>()
        for derivation in derivations {
            guard derivation.field.isEmpty == false else {
                throw EngineError.manifest("source adapter \(adapter.id) fieldDerivations must not contain empty field names")
            }
            guard seenFields.insert(derivation.field).inserted else {
                throw EngineError.manifest("source adapter \(adapter.id) declares duplicate field derivation: \(derivation.field)")
            }
            switch derivation.mode {
            case .calibrated, .unsupported:
                guard derivation.owner?.isEmpty == false,
                      derivation.requiredCapability?.isEmpty == false else {
                    throw EngineError.manifest("source adapter \(adapter.id) \(derivation.mode.rawValue) field \(derivation.field) requires owner and requiredCapability")
                }
            case .imported, .platformPolicy:
                break
            }
        }

        try validateDerivationMode(
            adapter: adapter,
            mode: .imported,
            legacyFields: provenance?.importedFields ?? []
        )
        try validateDerivationMode(
            adapter: adapter,
            mode: .calibrated,
            legacyFields: provenance?.calibratedFields ?? []
        )
        try validateDerivationMode(
            adapter: adapter,
            mode: .platformPolicy,
            legacyFields: provenance?.platformPolicyFields ?? []
        )
        try validateDerivationMode(
            adapter: adapter,
            mode: .unsupported,
            legacyFields: provenance?.unsupportedFields ?? []
        )

        let counts = Dictionary(grouping: derivations, by: \.mode)
            .mapValues(\.count)
        let countText = [
            "imported:\(counts[.imported] ?? 0)",
            "calibrated:\(counts[.calibrated] ?? 0)",
            "platform-policy:\(counts[.platformPolicy] ?? 0)",
            "unsupported:\(counts[.unsupported] ?? 0)"
        ].joined(separator: "+")
        return "sourceAdapter=\(adapter.id) kind=\(adapter.kind) fields=\(countText)"
    }

    private static func sourceAdapterStatus(provenance: SourceProvenance?) throws -> String {
        guard let adapter = provenance?.sourceAdapter else {
            return "sourceAdapter=none"
        }
        return try validateSourceAdapterContract(provenance)
            ?? "sourceAdapter=\(adapter.id) kind=\(adapter.kind) fields=none"
    }

    private static func sourceSummary(_ provenance: SourceProvenance?) -> String {
        guard let provenance else {
            return "source=unknown runtime=unspecified project=unspecified"
        }
        let sourceRuntime = provenance.sourceRuntime ?? "unspecified"
        let projectType = provenance.projectType ?? "unspecified"
        let descriptorCount = provenance.sourceDescriptors?.count ?? 0
        return [
            "source=\(provenance.sourceType.rawValue)",
            "runtime=\(sourceRuntime)",
            "project=\(projectType)",
            "descriptors=\(descriptorCount)"
        ].joined(separator: " ")
    }

    private static func invalidDiagnosticsDetails(_ diagnostics: [WallpaperBundleDiagnostic]) -> String {
        diagnostics.map {
            "- \($0.id): \($0.errorMessage ?? "invalid bundle") (\($0.root.path))"
        }.joined(separator: "\n")
    }

    private static func validateDerivationMode(
        adapter: SourceAdapterContract,
        mode: SourceAdapterFieldMode,
        legacyFields: [String]
    ) throws {
        let derivationFields = Set((adapter.fieldDerivations ?? [])
            .filter { $0.mode == mode }
            .map(\.field))
        let expectedFields = Set(legacyFields)
        guard derivationFields == expectedFields else {
            let missing = expectedFields.subtracting(derivationFields).sorted()
            let extra = derivationFields.subtracting(expectedFields).sorted()
            throw EngineError.manifest(
                "source adapter \(adapter.id) \(mode.rawValue) derivations do not match sourceProvenance lists"
                    + " missing=[\(missing.joined(separator: ","))] extra=[\(extra.joined(separator: ","))]"
            )
        }
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

    private static func sourceAdapterSection(_ adapter: SourceAdapterContract?) -> String {
        guard let adapter else {
            return "sourceAdapter: none"
        }

        let derivations = adapter.fieldDerivations ?? []
        let counts = Dictionary(grouping: derivations, by: \.mode)
            .mapValues(\.count)
        let capabilities = adapter.capabilities?.sorted().joined(separator: ",") ?? "none"
        let limitations = adapter.limitations?.sorted().joined(separator: ",") ?? "none"
        let countText = [
            "imported=\(counts[.imported] ?? 0)",
            "calibrated=\(counts[.calibrated] ?? 0)",
            "platform-policy=\(counts[.platformPolicy] ?? 0)",
            "unsupported=\(counts[.unsupported] ?? 0)"
        ].joined(separator: " ")
        return [
            "sourceAdapter:",
            "  - id=\(adapter.id) version=\(adapter.version ?? "unspecified") kind=\(adapter.kind) \(countText)",
            "  - capabilities=\(capabilities)",
            "  - limitations=\(limitations)"
        ].joined(separator: "\n")
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
            let serializedFields = serializedFieldCounts(index.serializedBehaviourFields)
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
                "serializedFields=\(serializedFields.isEmpty ? "none" : serializedFields)",
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

    private static func serializedFieldCounts(_ records: [UnitySerializedBehaviourFields]?) -> String {
        Dictionary(
            grouping: records ?? [],
            by: { "\($0.assembly ?? "unknown").\($0.className ?? "unknown")" }
        )
            .mapValues { groupedRecords in
                groupedRecords.reduce(0) { $0 + ($1.fields?.count ?? 0) }
            }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
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
    let serializedBehaviourFields: [UnitySerializedBehaviourFields]?
    let blockedFields: [UnityBlockedSourceField]?

    private enum CodingKeys: String, CodingKey {
        case converter
        case securityPolicy = "security_policy"
        case methodBodyStatus = "method_body_status"
        case assemblyScripts = "assembly_scripts"
        case interactionCandidates = "interaction_candidates"
        case serializedBehaviourFields = "serialized_behaviour_fields"
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

private struct UnitySerializedBehaviourFields: Decodable {
    let source: String?
    let pathID: Int?
    let assembly: String?
    let className: String?
    let gameObjectPathID: Int?
    let gameObjectName: String?
    let fieldNameEvidence: String?
    let fields: [UnitySerializedBehaviourField]?
    let limitations: [String]?
}

private struct UnitySerializedBehaviourField: Decodable {
    let name: String
    let kind: String
    let value: UnitySerializedValue?
    let fileID: Int?
    let pathID: Int?
    let rawOffset: Int?
}

private enum UnitySerializedValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let number = try? container.decode(Double.self) {
            self = .number(number)
            return
        }
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        throw DecodingError.typeMismatch(
            UnitySerializedValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported Unity serialized value type"
            )
        )
    }
}

private struct UnityBlockedSourceField: Decodable {
    let field: String
    let owner: String
    let requiredCapability: String
    let reason: String?
}
