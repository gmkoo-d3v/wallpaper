import AppKit
import Foundation

private enum ApplicationLifetime {
    static var delegate: WallpaperAppDelegate?
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    let config = try EngineConfig.parse(arguments)
    let runtime = try NativeRuntimeCore(config: config)

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
