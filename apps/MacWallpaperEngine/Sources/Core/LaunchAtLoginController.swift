import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: String {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
    case unknown
}

enum LaunchAtLoginController {
    static var isPackagedApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static func status() -> LaunchAtLoginStatus {
        guard isPackagedApp else {
            return .unavailable
        }

        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                return .enabled
            case .notRegistered:
                return .disabled
            case .requiresApproval:
                return .requiresApproval
            case .notFound:
                return .unavailable
            @unknown default:
                return .unknown
            }
        }
        return .unavailable
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isPackagedApp else {
            throw EngineError.invalidArgument("Launch at login requires the packaged .app build.")
        }

        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } else {
            throw EngineError.invalidArgument("Launch at login requires macOS 13 or later.")
        }
    }

    static func controlPanelText(desiredEnabled: Bool) -> String {
        switch status() {
        case .enabled:
            return desiredEnabled ? "LOGIN ITEM ENABLED" : "LOGIN ITEM ENABLED / apply to disable"
        case .disabled:
            return desiredEnabled ? "LOGIN ITEM DISABLED / apply to enable" : "LOGIN ITEM DISABLED"
        case .requiresApproval:
            return "LOGIN ITEM REQUIRES SYSTEM SETTINGS APPROVAL"
        case .unavailable:
            return "LOGIN ITEM UNAVAILABLE / packaged .app required"
        case .unknown:
            return "LOGIN ITEM STATUS UNKNOWN"
        }
    }
}
