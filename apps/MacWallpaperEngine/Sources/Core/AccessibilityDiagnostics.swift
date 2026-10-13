import Foundation

enum InputDiagnostics {
    static func statusText(promptPolicy: AccessibilityPromptPolicy) -> String {
        let packageRuntimeMetadata = packageRuntimeMetadataText()
        let accessibilityTrusted = DesktopInteractionGate.hasAccessibilityTrust(promptingPolicy: promptPolicy)

        var lines = [
            "input permission diagnostics OK",
            "accessibilityStatus: \(accessibilityTrusted ? "trusted" : "untrusted")",
            "accessibilityPromptSupported: true",
            "accessibilityPromptPolicy: \(promptPolicy.rawValue)",
            "accessibilityAPIUsed: true",
            "inputPolicy: ax-event-tap-when-trusted;global-monitors-when-untrusted",
            "appPath: \(Bundle.main.bundlePath)",
            "executablePath: \(CommandLine.arguments.first ?? "unknown")",
            "bundleIdentifier: \(Bundle.main.bundleIdentifier ?? "unknown")"
        ]
        if let packageRuntimeMetadata {
            lines.append("packageRuntimeMetadata: \(oneLine(packageRuntimeMetadata))")
        } else {
            lines.append("packageRuntimeMetadata: missing")
        }
        return lines.joined(separator: "\n")
    }

    private static func packageRuntimeMetadataText() -> String? {
        guard let metadataURL = Bundle.main.resourceURL?.appendingPathComponent("package-runtime.txt"),
              FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        return try? String(contentsOf: metadataURL, encoding: .utf8)
    }

    private static func oneLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
