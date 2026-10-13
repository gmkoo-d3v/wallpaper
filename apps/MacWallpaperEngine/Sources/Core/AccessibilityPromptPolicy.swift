import Foundation
import SystemConfiguration

/// Pure decision surface for *when* the runtime may ask macOS to show the
/// Accessibility permission prompt. The enum never touches the AX API itself;
/// callers pass in the environment facts so the truth table stays unit-testable
/// and headless/CLI one-shot paths can never trigger a prompt.
enum AccessibilityPromptPolicy: String, Codable, Equatable, CaseIterable {
    /// Prompt at most once per process, and only inside a GUI login session.
    /// This is the default for app launches.
    case uiSessionPromptOnce = "ui-session-prompt-once"
    /// Never show the prompt; only read trust state. Used by CLI one-shot
    /// diagnostics, self-test, CI, and headless runs.
    case never = "never"

    static let defaultPolicy: AccessibilityPromptPolicy = .uiSessionPromptOnce

    static let allValuesText: String = AccessibilityPromptPolicy.allCases.map(\.rawValue).joined(separator: " | ")

    static func parse(_ raw: String?) -> AccessibilityPromptPolicy {
        guard let raw else { return .defaultPolicy }
        return AccessibilityPromptPolicy(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .defaultPolicy
    }

    /// Pure truth table: prompt only when the policy allows a GUI-session prompt,
    /// the process is actually attached to a GUI login session, and no prompt has
    /// been requested yet in this process.
    static func shouldPrompt(
        policy: AccessibilityPromptPolicy,
        isGUIMainSession: Bool,
        alreadyPrompted: Bool
    ) -> Bool {
        guard policy == .uiSessionPromptOnce else { return false }
        guard isGUIMainSession else { return false }
        return alreadyPrompted == false
    }

    /// Environment-derived facts for `shouldPrompt`. Reading the console session
    /// owner is a plain SystemConfiguration query; it never calls an AX API.
    static func shouldPromptInCurrentEnvironment(alreadyPrompted: Bool, policy: AccessibilityPromptPolicy) -> Bool {
        shouldPrompt(
            policy: policy,
            isGUIMainSession: CurrentSessionIsGUI.isMainSession,
            alreadyPrompted: alreadyPrompted
        )
    }
}

enum CurrentSessionIsGUI {
    static var isMainSession: Bool {
        consoleUserName() != nil
    }

    private static func consoleUserName() -> String? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String? else {
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed != "loginwindow" else {
            return nil
        }
        return trimmed
    }
}
