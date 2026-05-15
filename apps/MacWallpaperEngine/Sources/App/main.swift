import AppKit
import Foundation

private enum ApplicationLifetime {
    static var delegate: WallpaperAppDelegate?
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
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
        let projectRoot = try? ProjectPaths.findProjectRoot()
        let includeInvalid = arguments.contains("--include-invalid")
        let diagnostics = WallpaperBundleCatalog.diagnoseDefaultBundles(projectRoot: projectRoot)
        let bundles = diagnostics.compactMap(\.bundle)
        guard bundles.isEmpty == false else {
            fputs("No valid wallpaper bundles found.\n", stderr)
            if includeInvalid {
                printBundleDiagnostics(diagnostics)
            }
            exit(EXIT_FAILURE)
        }

        if includeInvalid {
            printBundleDiagnostics(diagnostics)
        } else {
            for bundle in bundles {
                print("\(bundle.id)\t\(bundle.displayName)\t\(bundle.root.path)")
            }
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

private func value(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option),
          index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

private func printBundleDiagnostics(_ diagnostics: [WallpaperBundleDiagnostic]) {
    for diagnostic in diagnostics {
        let errorMessage = diagnostic.errorMessage ?? ""
        print("\(diagnostic.status.rawValue)\t\(diagnostic.id)\t\(diagnostic.displayName)\t\(diagnostic.root.path)\t\(errorMessage)")
    }
}
