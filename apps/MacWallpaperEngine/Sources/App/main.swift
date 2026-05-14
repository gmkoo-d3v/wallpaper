import AppKit
import Foundation

private enum ApplicationLifetime {
    static var delegate: WallpaperAppDelegate?
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    if arguments.contains("--list-bundles") {
        let projectRoot = try? ProjectPaths.findProjectRoot()
        let bundles = WallpaperBundleCatalog.discoverDefaultBundles(projectRoot: projectRoot)
        guard bundles.isEmpty == false else {
            fputs("No valid wallpaper bundles found.\n", stderr)
            exit(EXIT_FAILURE)
        }

        for bundle in bundles {
            print("\(bundle.id)\t\(bundle.displayName)\t\(bundle.root.path)")
        }
        exit(EXIT_SUCCESS)
    }

    let config = try EngineConfig.parse(arguments)
    let runtime = try NativeRuntimeCore(config: config)

    if config.displayPlanOnly {
        print(DisplayPlanner.summary(runtime: runtime))
        exit(EXIT_SUCCESS)
    }

    if config.performancePlanOnly {
        print(runtime.performanceSummary())
        exit(EXIT_SUCCESS)
    }

    if config.selfTestOnly {
        print(try RuntimeSelfTest.run(runtime: runtime))
        exit(EXIT_SUCCESS)
    }

    if config.validateOnly {
        let summary = runtime.validationSummary()
        print(summary)
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
