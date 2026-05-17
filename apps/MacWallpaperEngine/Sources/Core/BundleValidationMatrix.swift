import CoreGraphics
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
        let invalidDiagnostics = diagnostics.filter { $0.status == .invalid }
        guard bundles.isEmpty == false else {
            if invalidDiagnostics.isEmpty == false {
                throw EngineError.invalidArgument(
                    "No valid wallpaper bundles found for validation matrix.\nInvalid diagnostics:\n\(invalidDiagnosticsDetails(invalidDiagnostics))"
                )
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
                try validateDisplayRefreshMode(runtime: runtime)
                let interactionStatus = try validateInteractionDiagnostics(runtime: runtime)
                try runtime.requireCompositeQualityIfStrict()
                try runtime.requireNativeSpineGeometryIfSupported()
                let goldenStatus = try validateGoldenIfPresent(runtime: runtime)

                rows.append(row(
                    status: "valid",
                    bundle: bundle,
                    detail: bundle.capabilities.briefText
                        + " / displayModes: primaryOnly+selectedPolicy+allFull"
                        + " / displayRefreshFps: primary120+secondary60"
                        + " / \(interactionStatus)"
                        + " / \(goldenStatus)"
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
            for diagnostic in invalidDiagnostics {
                rows.append([
                    "invalid",
                    diagnostic.id,
                    diagnostic.displayName,
                    diagnostic.root.path,
                    diagnostic.errorMessage ?? "invalid bundle"
                ].joined(separator: "\t"))
            }
        }

        if invalidDiagnostics.isEmpty == false {
            failures.append("Invalid bundle diagnostics:\n\(invalidDiagnosticsDetails(invalidDiagnostics))")
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

    private static func invalidDiagnosticsDetails(_ diagnostics: [WallpaperBundleDiagnostic]) -> String {
        diagnostics.map {
            "- \($0.id): \($0.errorMessage ?? "invalid bundle") (\($0.root.path))"
        }.joined(separator: "\n")
    }

    private static func validateGoldenIfPresent(runtime: NativeRuntimeCore) throws -> String {
        let goldenURL = runtime.config.wallpaperRoot.appendingPathComponent("golden/wallpaper.golden.json")
        guard FileManager.default.fileExists(atPath: goldenURL.path) else {
            return "golden: none"
        }
        let report = try WallpaperGoldenDiagnostics.make(runtime: runtime, goldenURL: goldenURL)
        let fixtureLine = report
            .split(separator: "\n")
            .first { $0.hasPrefix("fixtures: ") }
            .map(String.init) ?? "fixtures: unknown"
        return "golden: pass \(fixtureLine)"
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

    private static func validateDisplayRefreshMode(runtime: NativeRuntimeCore) throws {
        let displayRuntime = try NativeRuntimeCore(config: runtime.config.replacing(
            matchDisplayRefresh: true,
            clearDuration: true
        ))
        let displayRefreshPlan = DisplayPlanner.simulatedMultiDisplayRenderSummary(
            runtime: displayRuntime,
            displayMode: .all
        )
        guard displayRefreshPlan.contains("displayMode: all"),
              displayRefreshPlan.contains("fps=120\tfpsMode=display\tdisplayRefresh=120Hz"),
              occurrenceCount("fps=60\tfpsMode=display\tdisplayRefresh=60Hz", in: displayRefreshPlan) == 2 else {
            throw EngineError.invalidArgument(
                "display-refresh simulated render plan is invalid for \(runtime.config.wallpaperRoot.lastPathComponent)"
            )
        }
    }

    private static func validateInteractionDiagnostics(runtime: NativeRuntimeCore) throws -> String {
        let actionTailDurations = try SpineAnimationDiagnostics.tapActionDurations(runtime: runtime)
        let summary = InteractionPlan.diagnosticSummary(
            interactions: runtime.manifest.interactions,
            policy: runtime.manifest.interactionPolicy,
            runtimeInteractive: runtime.config.interactive,
            actionTailDurations: actionTailDurations,
            fitMode: runtime.config.fitMode,
            contentAspect: CGFloat(runtime.assetCatalog.contentAspect),
            accessibilityTrusted: true
        )
        guard summary.contains("interaction plan OK"),
              summary.contains("pointerMoveProbes:"),
              summary.contains("pointerDownButtons:"),
              summary.contains("coordinateProbes:"),
              summary.contains("coordinateProbe: view=32:9") else {
            throw EngineError.invalidArgument(
                "interaction diagnostics are incomplete for \(runtime.config.wallpaperRoot.lastPathComponent)"
            )
        }

        let hasInteractions = runtime.manifest.interactions.isEmpty == false
        guard hasInteractions else {
            guard summary.contains("desktopMonitor: passive(no-interactions)"),
                  summary.contains("pointerDownButtons: none") else {
                throw EngineError.invalidArgument(
                    "passive interaction diagnostics are invalid for \(runtime.config.wallpaperRoot.lastPathComponent)"
                )
            }
            return "interactionPlan: passive(no-interactions)"
        }

        let plan = InteractionPlan(
            interactions: runtime.manifest.interactions,
            policy: runtime.manifest.interactionPolicy,
            actionTailDurations: actionTailDurations
        )
        let zones = plan.hitZoneSummaries()
        let defaultAction = plan.defaultActionSummary()
        if zones.isEmpty == false || defaultAction != nil {
            guard summary.contains("clickTimeline:") else {
                throw EngineError.invalidArgument(
                    "pointerDown timeline diagnostics are missing for \(runtime.config.wallpaperRoot.lastPathComponent)"
                )
            }
        }

        for zone in zones {
            guard summary.contains("hitProbe: \(zone.id)"),
                  summary.contains("clickProbe: \(zone.id)"),
                  summary.contains("target=\(zone.id)") else {
                throw EngineError.invalidArgument(
                    "hit-zone diagnostics are incomplete for \(runtime.config.wallpaperRoot.lastPathComponent)#\(zone.id)"
                )
            }
        }

        if defaultAction != nil {
            guard summary.contains("defaultHitProbe:"),
                  summary.contains("defaultClickProbe:"),
                  summary.contains("clickTimeline: default") else {
                throw EngineError.invalidArgument(
                    "default pointerDown diagnostics are incomplete for \(runtime.config.wallpaperRoot.lastPathComponent)"
                )
            }
        }

        let effectivePolicy = runtime.manifest.interactionPolicy ?? InteractionPolicy(
            mode: runtime.config.interactive ? .desktopEmptyOnly : .disabled,
            blockApplicationWindows: true,
            blockDesktopItems: true,
            pointerSmoothing: nil,
            idleDeadZone: nil,
            directionSwitchMargin: nil,
            defaultClickTailSeconds: nil,
            releaseFadeSeconds: nil
        )
        if RuntimeLifecyclePolicy.requiresAccessibilityTrustForDesktopItems(effectivePolicy) {
            let missingTrustSummary = InteractionPlan.diagnosticSummary(
                interactions: runtime.manifest.interactions,
                policy: runtime.manifest.interactionPolicy,
                runtimeInteractive: runtime.config.interactive,
                actionTailDurations: actionTailDurations,
                fitMode: runtime.config.fitMode,
                contentAspect: CGFloat(runtime.assetCatalog.contentAspect),
                accessibilityTrusted: false
            )
            guard missingTrustSummary.contains("desktopMonitor: blocked(accessibility-missing)") else {
                throw EngineError.invalidArgument(
                    "interaction diagnostics do not expose missing Accessibility trust for \(runtime.config.wallpaperRoot.lastPathComponent)"
                )
            }
            return "interactionPlan: active(desktop-empty-only+accessibility-gated)"
        }

        return "interactionPlan: active"
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
