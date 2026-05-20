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

        let libraryStatus = try validateBundleListReport(diagnostics: diagnostics, bundles: bundles)
        let installerValidationLibrary = try makeTemporaryInstallerLibrary()
        defer {
            try? FileManager.default.removeItem(at: installerValidationLibrary)
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
                let performanceStatus = try validatePerformancePlan(runtime: runtime)
                let doctorStatus = try validateDoctorReport(runtime: runtime)
                let sourceProvenanceStatus = try RuntimeSourceProvenanceReport.consistencyStatus(runtime: runtime)
                try runtime.requireCompositeQualityIfStrict()
                try runtime.requireNativeSpineGeometryIfSupported()
                let goldenStatus = try validateGoldenIfPresent(runtime: runtime)
                let installerStatus = try validateInstallerRoundTrip(
                    bundle: bundle,
                    libraryDirectory: installerValidationLibrary
                )

                rows.append(row(
                    status: "valid",
                    bundle: bundle,
                    detail: bundle.capabilities.briefText
                        + " / displayModes: selectedOnly+selectedPolicy+allFull"
                        + " / displayRefreshFps: primary120+secondary60"
                        + " / \(interactionStatus)"
                        + " / \(performanceStatus)"
                        + " / \(doctorStatus)"
                        + " / \(sourceProvenanceStatus)"
                        + " / \(libraryStatus)"
                        + " / \(goldenStatus)"
                        + " / \(installerStatus)"
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

    private static func makeTemporaryInstallerLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacWallpaperEngineBundleMatrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func validateInstallerRoundTrip(
        bundle: WallpaperBundleSummary,
        libraryDirectory: URL
    ) throws -> String {
        let installedBundle = try WallpaperBundleInstaller.install(
            sourceRoot: bundle.root,
            libraryDirectory: libraryDirectory
        )
        let libraryPath = libraryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let installedPath = installedBundle.root.standardizedFileURL.resolvingSymlinksInPath().path

        guard installedBundle.id == bundle.id else {
            throw EngineError.invalidArgument(
                "bundle installer changed metadata.id for \(bundle.id): \(installedBundle.id)"
            )
        }
        guard installedPath.hasPrefix(libraryPath + "/") else {
            throw EngineError.invalidArgument(
                "bundle installer wrote outside the requested library for \(bundle.id): \(installedBundle.root.path)"
            )
        }
        guard FileManager.default.fileExists(atPath: installedBundle.manifestURL.path) else {
            throw EngineError.invalidArgument(
                "bundle installer did not copy wallpaper.native.json for \(bundle.id)"
            )
        }

        let discoveredBundles = WallpaperBundleCatalog.discover(in: libraryDirectory)
        guard discoveredBundles.contains(where: {
            $0.id == installedBundle.id
                && $0.root.standardizedFileURL.resolvingSymlinksInPath().path == installedPath
        }) else {
            throw EngineError.invalidArgument(
                "installed bundle is not discoverable from the target library for \(bundle.id)"
            )
        }

        let installedConfig = try EngineConfig.parse([
            "--wallpaper-root", installedBundle.root.path,
            "--manifest", installedBundle.manifestURL.path,
            "--validate-only"
        ])
        let installedRuntime = try NativeRuntimeCore(config: installedConfig)
        _ = installedRuntime.validationSummary()

        return "installer: importable"
    }

    private static func validateBundleListReport(
        diagnostics: [WallpaperBundleDiagnostic],
        bundles: [WallpaperBundleSummary]
    ) throws -> String {
        let report = BundleListReport.make(
            diagnostics: diagnostics,
            includeInvalid: true,
            includeCapabilities: true
        )
        let invalidCount = diagnostics.filter { $0.status == .invalid }.count
        guard report.contains("bundle list"),
              report.contains("validBundles: \(bundles.count)"),
              report.contains("invalidDiagnostics: \(invalidCount)"),
              report.contains("includeInvalid: true"),
              report.contains("includeCapabilities: true"),
              report.contains("columns: status\tid\ttitle\troot\tcapabilities\terror") else {
            throw EngineError.invalidArgument("bundle list report header is invalid")
        }

        for bundle in bundles {
            guard report.contains("valid\t\(bundle.id)\t\(bundle.displayName)\t\(bundle.root.path)\t\(bundle.capabilities.briefText)") else {
                throw EngineError.invalidArgument("bundle list report is missing valid row for \(bundle.id)")
            }
        }

        for diagnostic in diagnostics where diagnostic.status == .invalid {
            guard let errorMessage = diagnostic.errorMessage,
                  report.contains("invalid\t\(diagnostic.id)\t\(diagnostic.displayName)\t\(diagnostic.root.path)\tnone\t\(errorMessage)") else {
                throw EngineError.invalidArgument("bundle list report is missing invalid diagnostic row for \(diagnostic.id)")
            }
        }

        return "libraryReport: listed=\(bundles.count) invalid=\(invalidCount) capabilities"
    }

    private static func validateSimulatedDisplayModes(runtime: NativeRuntimeCore) throws {
        let primaryOnly = DisplayPlanner.simulatedMultiDisplayRenderSummary(
            runtime: runtime,
            displayMode: .primaryOnly
        )
        guard primaryOnly.contains("displayMode: selectedOnly"),
              occurrenceCount("primary:\(runtime.manifest.displayPolicy.primary.rawValue)", in: primaryOnly) == 1,
              occurrenceCount("\tnone\tbackground=none\tforeground=none", in: primaryOnly) == 2 else {
            throw EngineError.invalidArgument(
                "selectedOnly simulated render plan is invalid for \(runtime.config.wallpaperRoot.lastPathComponent)"
            )
        }

        let selectedPolicy = DisplayPlanner.simulatedMultiDisplayRenderSummary(
            runtime: runtime,
            displayMode: .primaryAnimated
        )
        guard selectedPolicy.contains("displayMode: selectedPolicy"),
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
        guard allDisplays.contains("displayMode: allFull"),
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
        let highRefreshFps = min(120, runtime.manifest.runtime.maxFps)
        let standardRefreshFps = min(60, runtime.manifest.runtime.maxFps)
        guard displayRefreshPlan.contains("displayMode: allFull"),
              displayRefreshPlan.contains("fps=\(highRefreshFps)\tfpsMode=display\tdisplayRefresh=120Hz"),
              occurrenceCount("fps=\(standardRefreshFps)\tfpsMode=display\tdisplayRefresh=60Hz", in: displayRefreshPlan) == 2 else {
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
              summary.contains("eventGateProbes:"),
              summary.contains("eventGateTrustedProbes:"),
              summary.contains("pointerMoveNeutralPoint:"),
              summary.contains("pointerMoveDeadZone:"),
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
            pointerSampleFps: nil,
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
            guard missingTrustSummary.contains("desktopMonitor: degraded(desktop-empty-only,pointer-tracking-only-accessibility-missing)"),
                  missingTrustSummary.contains("emptyDesktopMove=eligible"),
                  missingTrustSummary.contains("emptyDesktop=blockedAccessibilityTrust"),
                  missingTrustSummary.contains("eventGateMissingTrustProbes: accessibilityTrusted=false") else {
                throw EngineError.invalidArgument(
                    "interaction diagnostics do not expose missing Accessibility trust for \(runtime.config.wallpaperRoot.lastPathComponent)"
                )
            }
            return "interactionPlan: active(desktop-empty-only+accessibility-gated+pointer-tracking-only-without-trust)"
        }

        return "interactionPlan: active"
    }

    private static func validatePerformancePlan(runtime: NativeRuntimeCore) throws -> String {
        let plan = runtime.performancePlan
        let summary = runtime.performanceSummary()
        guard summary.contains("performance plan OK"),
              summary.contains("exhaustedBudgetFallback: fps downgrade; renderer swap disabled by default"),
              summary.contains("telemetryFields: currentFps, actualFps, p95FrameTimeMs"),
              summary.contains("maxInFlightCommandBuffers: \(plan.maxInFlightCommandBuffers)") else {
            throw EngineError.invalidArgument(
                "performance diagnostics are incomplete for \(runtime.config.wallpaperRoot.lastPathComponent)"
            )
        }

        guard plan.fallbackFps >= 1,
              plan.fallbackFps <= plan.maxFps,
              plan.effectiveTargetFps >= plan.fallbackFps,
              plan.downgradeFpsLadder.first == plan.effectiveTargetFps,
              plan.downgradeFpsLadder.last == plan.fallbackFps,
              (1...3).contains(plan.maxInFlightCommandBuffers),
              plan.cpuTargetPercent > 0,
              plan.cpuDowngradePercent >= plan.cpuTargetPercent,
              plan.cpuDowngradeWindowSeconds > 0,
              plan.rssTargetMb > 0,
              plan.rssHardMb >= plan.rssTargetMb else {
            throw EngineError.invalidArgument(
                "performance budget invariants are invalid for \(runtime.config.wallpaperRoot.lastPathComponent)"
            )
        }

        let displayRuntime = try NativeRuntimeCore(config: runtime.config.replacing(
            matchDisplayRefresh: true,
            clearDuration: true
        ))
        let displayPlan = displayRuntime.performancePlan(displayRefreshFps: 120)
        guard displayPlan.effectiveTargetFps == min(120, runtime.manifest.runtime.maxFps),
              displayPlan.powerSavingFps == displayPlan.fallbackFps,
              displayPlan.downgradeFpsLadder.contains(displayPlan.fallbackFps) else {
            throw EngineError.invalidArgument(
                "display-refresh performance budget is invalid for \(runtime.config.wallpaperRoot.lastPathComponent)"
            )
        }

        return "performancePlan: target=\(plan.effectiveTargetFps) fallback=\(plan.fallbackFps) budgeted"
    }

    private static func validateDoctorReport(runtime: NativeRuntimeCore) throws -> String {
        let report = try RuntimeDoctorReport.make(runtime: runtime, recoveryURL: nil)
        let requiredSections = [
            "wallpaper doctor OK",
            "== bundle-library ==",
            "== validation ==",
            "== runtime-capabilities ==",
            "== source-provenance ==",
            "== render-plan ==",
            "== simulated-render-plan ==",
            "== performance-plan ==",
            "== package-signing ==",
            "== interaction-plan ==",
            "== renderer-recovery =="
        ]
        guard requiredSections.allSatisfy({ report.contains($0) }),
              report.contains("validBundles:"),
              report.contains("includeCapabilities: true"),
              report.contains("click/touch actions require macOS Accessibility trust"),
              report.contains(runtime.config.wallpaperRoot.path),
              report.contains(runtime.config.manifestURL.path) else {
            throw EngineError.invalidArgument(
                "doctor diagnostics are incomplete for \(runtime.config.wallpaperRoot.lastPathComponent)"
            )
        }
        return "doctor: pass"
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
