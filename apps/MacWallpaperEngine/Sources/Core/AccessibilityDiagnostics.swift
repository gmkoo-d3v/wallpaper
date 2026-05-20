import Foundation

enum AccessibilityDiagnostics {
    static func statusText(requestPrompt: Bool = false) -> String {
        let beforeTrusted = DesktopInteractionGate.hasAccessibilityTrust()
        let shouldRequestPrompt = requestPrompt && RuntimeLifecyclePolicy.shouldOpenAccessibilityPermissionRequest(
            accessibilityTrusted: beforeTrusted
        )
        let promptResult = shouldRequestPrompt ? DesktopInteractionGate.requestAccessibilityTrustPrompt() : nil
        let settingsOpened = shouldRequestPrompt ? DesktopInteractionGate.openAccessibilitySettings() : nil
        let afterTrusted = DesktopInteractionGate.hasAccessibilityTrust()
        let packageMetadata = packageSigningMetadataText()

        var lines = [
            "accessibility diagnostics OK",
            "accessibilityStatus: \(afterTrusted ? "trusted" : "missing")",
            "accessibilityStatusBeforePrompt: \(beforeTrusted ? "trusted" : "missing")",
            "appPath: \(Bundle.main.bundlePath)",
            "executablePath: \(CommandLine.arguments.first ?? "unknown")",
            "bundleIdentifier: \(Bundle.main.bundleIdentifier ?? "unknown")"
        ]
        if let promptResult {
            lines.append("promptRequested: true")
            lines.append("promptReturnedTrusted: \(promptResult)")
        } else {
            lines.append("promptRequested: false")
            if requestPrompt, beforeTrusted {
                lines.append("promptSkipped: already-trusted")
            }
        }
        if let settingsOpened {
            lines.append("settingsOpened: \(settingsOpened)")
        }
        if let packageMetadata {
            lines.append("packageMetadata: \(oneLine(packageMetadata))")
        } else {
            lines.append("packageMetadata: missing")
        }
        lines.append("next: if accessibilityStatus is missing, add this exact app in System Settings > Privacy & Security > Accessibility, then rerun --accessibility-status")
        return lines.joined(separator: "\n")
    }

    private static func packageSigningMetadataText() -> String? {
        guard let metadataURL = Bundle.main.resourceURL?.appendingPathComponent("package-signing.txt"),
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
