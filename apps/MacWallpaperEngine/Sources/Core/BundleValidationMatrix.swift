import Foundation

enum BundleValidationMatrix {
    static func make(
        projectRoot: URL?,
        strictCompositeQuality: Bool,
        includeInvalid: Bool,
        bundleDirectories: [URL]? = nil
    ) throws -> String {
        let diagnostics = bundleDirectories.map(WallpaperBundleCatalog.diagnose(in:))
            ?? WallpaperBundleCatalog.diagnoseDefaultBundles(projectRoot: projectRoot)
        let bundles = diagnostics.compactMap(\.bundle)
        guard bundles.isEmpty == false else {
            if includeInvalid {
                let invalidDiagnostics = diagnostics.filter { $0.status == .invalid }
                if invalidDiagnostics.isEmpty == false {
                    let details = invalidDiagnostics.map {
                        "- \($0.id): \($0.errorMessage ?? "invalid bundle") (\($0.root.path))"
                    }.joined(separator: "\n")
                    throw EngineError.invalidArgument(
                        "No valid wallpaper bundles found for validation matrix.\nInvalid diagnostics:\n\(details)"
                    )
                }
            }
            throw EngineError.invalidArgument("No valid wallpaper bundles found for validation matrix.")
        }

        var rows: [String] = []
        var failures: [String] = []

        for bundle in bundles {
            do {
                let config = try EngineConfig.parse([
                    "--wallpaper-root", bundle.root.path,
                    "--manifest", bundle.manifestURL.path,
                    "--validate-only"
                ] + (strictCompositeQuality ? ["--strict-composite-quality"] : []))
                let runtime = try NativeRuntimeCore(config: config)
                _ = runtime.validationSummary()
                _ = runtime.runtimeCapabilitiesSummary()
                _ = DisplayPlanner.headlessRenderSummary(runtime: runtime)
                try validateSimulatedDisplayModes(runtime: runtime)
                try runtime.requireCompositeQualityIfStrict()
                try runtime.requireNativeSpineGeometryIfSupported()

                rows.append(row(
                    status: "valid",
                    bundle: bundle,
                    detail: bundle.capabilities.briefText
                        + " / displayModes: primaryOnly+selectedPolicy+allFull"
                ))
            } catch {
                failures.append("\(bundle.id): \(error.localizedDescription)")
                rows.append(row(
                    status: "failed",
                    bundle: bundle,
                    detail: error.localizedDescription
                ))
            }
        }

        if includeInvalid {
            for diagnostic in diagnostics where diagnostic.status == .invalid {
                rows.append([
                    "invalid",
                    diagnostic.id,
                    diagnostic.displayName,
                    diagnostic.root.path,
                    diagnostic.errorMessage ?? "invalid bundle"
                ].joined(separator: "\t"))
            }
        }

        if failures.isEmpty == false {
            let details = failures.map { "- \($0)" }.joined(separator: "\n")
            throw EngineError.invalidArgument("Bundle validation matrix failed:\n\(details)")
        }

        return """
        bundle validation matrix OK
        validBundles: \(bundles.count)
        invalidDiagnostics: \(diagnostics.filter { $0.status == .invalid }.count)
        strictCompositeQuality: \(strictCompositeQuality)
        columns: status\tid\ttitle\troot\tdetail
        \(rows.joined(separator: "\n"))
        """
    }

    private static func row(status: String, bundle: WallpaperBundleSummary, detail: String) -> String {
        [
            status,
            bundle.id,
            bundle.displayName,
            bundle.root.path,
            detail
        ].joined(separator: "\t")
    }

    private static func validateSimulatedDisplayModes(runtime: NativeRuntimeCore) throws {
        let primaryOnly = DisplayPlanner.simulatedMultiDisplayRenderSummary(
            runtime: runtime,
            displayMode: .primaryOnly
        )
        guard primaryOnly.contains("displayMode: primaryOnly"),
              occurrenceCount("primary:\(runtime.manifest.displayPolicy.primary.rawValue)", in: primaryOnly) == 1,
              occurrenceCount("\tnone\tbackground=none\tforeground=none", in: primaryOnly) == 2 else {
            throw EngineError.invalidArgument(
                "primaryOnly simulated render plan is invalid for \(runtime.config.wallpaperRoot.lastPathComponent)"
            )
        }

        let selectedPolicy = DisplayPlanner.simulatedMultiDisplayRenderSummary(
            runtime: runtime,
            displayMode: .primaryAnimated
        )
        guard selectedPolicy.contains("displayMode: primaryAnimated"),
              occurrenceCount("secondary:\(runtime.manifest.displayPolicy.secondary.rawValue)", in: selectedPolicy) == 2,
              selectedPolicy.contains("interaction=passive") else {
            throw EngineError.invalidArgument(
                "selected+policy simulated render plan is invalid for \(runtime.config.wallpaperRoot.lastPathComponent)"
            )
        }

        let allDisplays = DisplayPlanner.simulatedMultiDisplayRenderSummary(
            runtime: runtime,
            displayMode: .all
        )
        guard allDisplays.contains("displayMode: all"),
              occurrenceCount("secondary:full", in: allDisplays) == 2,
              allDisplays.contains("displayRefresh=120Hz") else {
            throw EngineError.invalidArgument(
                "all-full simulated render plan is invalid for \(runtime.config.wallpaperRoot.lastPathComponent)"
            )
        }
    }

    private static func occurrenceCount(_ needle: String, in haystack: String) -> Int {
        guard needle.isEmpty == false else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }
}
