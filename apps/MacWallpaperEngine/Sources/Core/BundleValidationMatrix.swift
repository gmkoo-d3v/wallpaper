import Foundation

enum BundleValidationMatrix {
    static func make(
        projectRoot: URL?,
        strictCompositeQuality: Bool,
        includeInvalid: Bool
    ) throws -> String {
        let diagnostics = WallpaperBundleCatalog.diagnoseDefaultBundles(projectRoot: projectRoot)
        let bundles = diagnostics.compactMap(\.bundle)
        guard bundles.isEmpty == false else {
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
                try runtime.requireCompositeQualityIfStrict()
                try runtime.requireNativeSpineGeometryIfSupported()

                rows.append(row(
                    status: "valid",
                    bundle: bundle,
                    detail: bundle.capabilities.briefText
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
}
