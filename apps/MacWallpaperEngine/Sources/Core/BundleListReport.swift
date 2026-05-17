import Foundation

enum BundleListReport {
    static func make(
        diagnostics: [WallpaperBundleDiagnostic],
        includeInvalid: Bool,
        includeCapabilities: Bool
    ) -> String {
        let validCount = diagnostics.filter { $0.status == .valid }.count
        let invalidCount = diagnostics.filter { $0.status == .invalid }.count
        let visibleDiagnostics = diagnostics.filter {
            includeInvalid || $0.status == .valid
        }
        let columns = columns(includeCapabilities: includeCapabilities, includeInvalid: includeInvalid)
        let rows = visibleDiagnostics.map {
            row($0, includeCapabilities: includeCapabilities, includeInvalid: includeInvalid)
        }

        var lines = [
            "bundle list",
            "validBundles: \(validCount)",
            "invalidDiagnostics: \(invalidCount)",
            "includeInvalid: \(includeInvalid)",
            "includeCapabilities: \(includeCapabilities)",
            "columns: \(columns.joined(separator: "\t"))"
        ]
        lines.append(contentsOf: rows.isEmpty ? ["rows: none"] : rows)
        return lines.joined(separator: "\n")
    }

    private static func columns(includeCapabilities: Bool, includeInvalid: Bool) -> [String] {
        var columns = ["status", "id", "title", "root"]
        if includeCapabilities {
            columns.append("capabilities")
        }
        if includeInvalid {
            columns.append("error")
        }
        return columns
    }

    private static func row(
        _ diagnostic: WallpaperBundleDiagnostic,
        includeCapabilities: Bool,
        includeInvalid: Bool
    ) -> String {
        var values = [
            diagnostic.status.rawValue,
            diagnostic.id,
            diagnostic.displayName,
            diagnostic.root.path
        ]
        if includeCapabilities {
            values.append(diagnostic.bundle?.capabilities.briefText ?? "none")
        }
        if includeInvalid {
            values.append(diagnostic.errorMessage ?? "none")
        }
        return values.joined(separator: "\t")
    }
}
