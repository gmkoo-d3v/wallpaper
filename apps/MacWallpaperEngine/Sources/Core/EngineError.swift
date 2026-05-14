import Foundation

enum EngineError: LocalizedError {
    case invalidArgument(String)
    case manifest(String)
    case asset(String)
    case renderer(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message):
            return message
        case .manifest(let message):
            return "Manifest error: \(message)"
        case .asset(let message):
            return "Asset error: \(message)"
        case .renderer(let message):
            return "Renderer error: \(message)"
        case .unsupported(let message):
            return "Unsupported: \(message)"
        }
    }
}
