import AppKit
import Foundation

private enum ApplicationLifetime {
    static var delegate: WallpaperAppDelegate?
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    if arguments.contains("--print-manifest-schema") {
        print(try ManifestSchemaResource.loadText())
        exit(EXIT_SUCCESS)
    }

    if arguments.contains("--input-status") || arguments.contains("--accessibility-status") {
        print(InputDiagnostics.statusText())
        exit(EXIT_SUCCESS)
    }

    if let manualSmokeTemplatePath = value(after: "--write-manual-smoke-template", in: arguments) {
        print(try RuntimeCompletionAudit.writeManualSmokeEvidenceTemplate(
            to: URL(fileURLWithPath: manualSmokeTemplatePath, relativeTo: nil).standardizedFileURL
        ))
        exit(EXIT_SUCCESS)
    }

    if let manualSmokeRecordPath = value(after: "--record-manual-smoke-evidence", in: arguments) {
        print(try RuntimeCompletionAudit.recordManualSmokeEvidence(
            to: URL(fileURLWithPath: manualSmokeRecordPath, relativeTo: nil).standardizedFileURL,
            packagedLaunchPassed: arguments.contains("--confirm-packaged-launch"),
            liveClickActionsPassed: arguments.contains("--confirm-live-click-actions"),
            physicalDisplayHotplugPassed: arguments.contains("--confirm-physical-display-hotplug"),
            blackFrameFlickerPassed: arguments.contains("--confirm-black-frame-flicker")
        ))
        exit(EXIT_SUCCESS)
    }

    if let installBundlePath = value(after: "--install-bundle", in: arguments) {
        let installLibrary = value(after: "--install-library", in: arguments).map {
            URL(fileURLWithPath: $0, relativeTo: nil).standardizedFileURL
        }
        let installedBundle = try WallpaperBundleInstaller.install(
            sourceRoot: URL(fileURLWithPath: installBundlePath, relativeTo: nil),
            libraryDirectory: installLibrary ?? ProjectPaths.userWallpapersDirectory()
        )
        print("""
        installed wallpaper bundle OK
        id: \(installedBundle.id)
        title: \(installedBundle.displayName)
        bundle: \(installedBundle.root.path)
        manifest: \(installedBundle.manifestURL.path)
        """)
        exit(EXIT_SUCCESS)
    }

    if arguments.contains("--list-bundles") {
        let projectRoot = ProjectPaths.findCatalogProjectRoot()
        let includeInvalid = arguments.contains("--include-invalid")
        let includeCapabilities = arguments.contains("--include-capabilities")
        let bundleLibrary = value(after: "--bundle-library", in: arguments).map {
            URL(fileURLWithPath: $0, relativeTo: nil).standardizedFileURL
        }
        let diagnostics = bundleLibrary.map { WallpaperBundleCatalog.diagnose(in: $0) }
            ?? WallpaperBundleCatalog.diagnoseDefaultBundles(projectRoot: projectRoot)
        let bundles = diagnostics.compactMap(\.bundle)
        guard bundles.isEmpty == false else {
            fputs("No valid wallpaper bundles found.\n", stderr)
            if includeInvalid {
                print(BundleListReport.make(
                    diagnostics: diagnostics,
                    includeInvalid: true,
                    includeCapabilities: includeCapabilities
                ))
            }
            exit(EXIT_FAILURE)
        }

        print(BundleListReport.make(
            diagnostics: diagnostics,
            includeInvalid: includeInvalid,
            includeCapabilities: includeCapabilities
        ))
        exit(EXIT_SUCCESS)
    }

    if arguments.contains("--validate-bundles") {
        print(try BundleValidationMatrix.make(
            projectRoot: ProjectPaths.findCatalogProjectRoot(),
            strictCompositeQuality: arguments.contains("--strict-composite-quality"),
            includeInvalid: arguments.contains("--include-invalid"),
            bundleDirectories: value(after: "--bundle-library", in: arguments).map {
                [URL(fileURLWithPath: $0, relativeTo: nil).standardizedFileURL]
            }
        ))
        exit(EXIT_SUCCESS)
    }

    if arguments.contains("--completion-audit") {
        print(try RuntimeCompletionAudit.make(
            projectRoot: ProjectPaths.findCatalogProjectRoot(),
            strictCompositeQuality: arguments.contains("--strict-composite-quality"),
            includeInvalid: arguments.contains("--include-invalid"),
            bundleDirectories: value(after: "--bundle-library", in: arguments).map {
                [URL(fileURLWithPath: $0, relativeTo: nil).standardizedFileURL]
            },
            manualEvidenceURL: value(after: "--manual-smoke-evidence", in: arguments).map {
                URL(fileURLWithPath: $0, relativeTo: nil).standardizedFileURL
            }
        ))
        exit(EXIT_SUCCESS)
    }

    if arguments.contains("--recovery-plan") {
        let recoveryURL = value(after: "--recovery-store", in: arguments).map {
            URL(fileURLWithPath: $0, relativeTo: nil).standardizedFileURL
        } ?? RendererRecoveryStore.defaultRecoveryURL()
        print(RendererRecoveryStore.report(recoveryURL: recoveryURL))
        exit(EXIT_SUCCESS)
    }

    let config = try EngineConfig.parse(arguments)
    let runtime = try NativeRuntimeCore(config: config)

    if config.displayPlanOnly {
        print(DisplayPlanner.headlessSummary(runtime: runtime))
        exit(EXIT_SUCCESS)
    }

    if config.physicalDisplayPlanOnly {
        print(DisplayPlanner.summary(runtime: runtime))
        exit(EXIT_SUCCESS)
    }

    if config.renderPlanOnly || config.physicalRenderPlanOnly || config.simulatedRenderPlanOnly {
        if config.simulatedRenderPlanOnly {
            print(DisplayPlanner.simulatedMultiDisplayRenderSummary(runtime: runtime))
        } else if config.physicalRenderPlanOnly {
            print(DisplayPlanner.renderSummary(runtime: runtime))
        } else {
            print(DisplayPlanner.headlessRenderSummary(runtime: runtime))
        }
        exit(EXIT_SUCCESS)
    }

    if config.performancePlanOnly {
        print(runtime.performanceSummary())
        exit(EXIT_SUCCESS)
    }

    if config.runtimeCapabilitiesOnly {
        print(runtime.runtimeCapabilitiesSummary())
        exit(EXIT_SUCCESS)
    }

    if config.sourceProvenanceReportOnly {
        print(RuntimeSourceProvenanceReport.make(runtime: runtime))
        exit(EXIT_SUCCESS)
    }

    if config.doctorReportOnly {
        print(try RuntimeDoctorReport.make(runtime: runtime))
        exit(EXIT_SUCCESS)
    }

    if config.interactionPlanOnly {
        let actionTailDurations = try SpineAnimationDiagnostics.tapActionDurations(runtime: runtime)
        print(InteractionPlan.diagnosticSummary(
            interactions: runtime.manifest.interactions,
            policy: runtime.manifest.interactionPolicy,
            runtimeInteractive: runtime.config.interactive,
            actionTailDurations: actionTailDurations,
            fitMode: runtime.config.fitMode,
            contentAspect: CGFloat(runtime.assetCatalog.contentAspect),
            accessibilityTrusted: DesktopInteractionGate.hasAccessibilityTrust()
        ))
        exit(EXIT_SUCCESS)
    }

    if let interactionProbePoint = config.interactionProbePoint {
        let actionTailDurations = try SpineAnimationDiagnostics.tapActionDurations(runtime: runtime)
        print(InteractionPlan.probeSummary(
            interactions: runtime.manifest.interactions,
            policy: runtime.manifest.interactionPolicy,
            runtimeInteractive: runtime.config.interactive,
            point: interactionProbePoint,
            button: config.interactionProbeButton,
            actionTailDurations: actionTailDurations
        ))
        exit(EXIT_SUCCESS)
    }

    if config.spineAnimationPlanOnly {
        print(try SpineAnimationDiagnostics.make(runtime: runtime))
        print(try SpineGeometryDiagnostics.make(runtime: runtime))
        exit(EXIT_SUCCESS)
    }

    if config.spineProfileOnly {
        print(try SpineGeometryDiagnostics.profile(runtime: runtime))
        exit(EXIT_SUCCESS)
    }

    if let spineSnapshotURL = config.spineSnapshotURL {
        print(try SpineGeometryDiagnostics.writeSnapshot(
            runtime: runtime,
            destination: spineSnapshotURL,
            actionName: config.spineSnapshotAction,
            time: config.spineSnapshotTime,
            width: config.spineSnapshotWidth,
            height: config.spineSnapshotHeight
        ))
        exit(EXIT_SUCCESS)
    }

    if let wallpaperSnapshotURL = config.wallpaperSnapshotURL {
        print(try WallpaperSnapshotDiagnostics.writeSnapshot(
            runtime: runtime,
            destination: wallpaperSnapshotURL,
            reference: config.wallpaperSnapshotReferenceURL,
            actionName: config.spineSnapshotAction,
            time: config.spineSnapshotTime,
            width: config.spineSnapshotWidth,
            height: config.spineSnapshotHeight
        ))
        exit(EXIT_SUCCESS)
    }

    if config.wallpaperGoldenCheckOnly {
        print(try WallpaperGoldenDiagnostics.make(
            runtime: runtime,
            goldenURL: config.wallpaperGoldenURL
        ))
        exit(EXIT_SUCCESS)
    }

    if config.compositeQualityPlanOnly {
        let report = runtime.compositeQualityReport()
        print(report.text)
        if config.strictCompositeQuality, report.isAcceptable == false {
            exit(EXIT_FAILURE)
        }
        exit(EXIT_SUCCESS)
    }

    if let compositeExportURL = config.compositeExportURL {
        let fps = config.compositeExportFps ?? runtime.manifest.runtime.targetFps
        let duration = config.compositeExportDuration ?? CompositeVideoExporter.defaultDuration(runtime: runtime)
        print(try CompositeVideoExporter.export(
            runtime: runtime,
            options: CompositeVideoExporter.Options(
                destination: compositeExportURL,
                fps: fps,
                duration: duration,
                width: config.spineSnapshotWidth,
                height: config.spineSnapshotHeight,
                actionName: config.spineSnapshotAction
            )
        ))
        exit(EXIT_SUCCESS)
    }

    if config.selfTestOnly {
        print(try RuntimeSelfTest.run(runtime: runtime))
        exit(EXIT_SUCCESS)
    }

    if config.validateOnly {
        let summary = runtime.validationSummary()
        print(summary)
        try runtime.requireCompositeQualityIfStrict()
        try runtime.requireNativeSpineGeometryIfSupported()
        exit(EXIT_SUCCESS)
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.regular)

    ApplicationLifetime.delegate = WallpaperAppDelegate(runtime: runtime)
    application.delegate = ApplicationLifetime.delegate
    application.run()
} catch {
    fputs("MacWallpaperEngine failed: \(error.localizedDescription)\n", stderr)

    if arguments.isEmpty || arguments.contains("--control-panel-only") {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)

        ApplicationLifetime.delegate = WallpaperAppDelegate(runtime: nil, startupError: error)
        application.delegate = ApplicationLifetime.delegate
        application.run()
        exit(EXIT_SUCCESS)
    }

    exit(EXIT_FAILURE)
}

private func value(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option),
          index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}
