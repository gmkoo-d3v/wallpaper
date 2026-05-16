import Foundation

struct CompositeFallbackQualityReport {
    let status: String
    let targetFps: Int
    let maxFps: Int
    let recommendedExportFps: String?
    let assetPath: String?
    let fpsText: String
    let effectiveFpsText: String
    let playbackRateText: String
    let sizeText: String
    let durationText: String
    let warnings: [String]

    var isAcceptable: Bool {
        warnings.isEmpty
    }

    var summaryLine: String {
        warnings.isEmpty ? status : "\(status)(\(warnings.count))"
    }

    var text: String {
        var lines = [
            "composite fallback quality",
            "status: \(summaryLine)",
            "targetFps: \(targetFps)",
            "maxFps: \(maxFps)",
            "recommendedExportFps: \(recommendedExportFps ?? "none")",
            "asset: \(assetPath ?? "none")",
            "fps: \(fpsText)",
            "effectiveFps: \(effectiveFpsText)",
            "playbackRate: \(playbackRateText)",
            "size: \(sizeText)",
            "duration: \(durationText)"
        ]
        if warnings.isEmpty {
            lines.append("warnings: none")
        } else {
            lines.append("warnings:")
            lines.append(contentsOf: warnings.map { "- \($0)" })
            lines.append("action: regenerate the composite fallback from native/source animation with --export-composite-video at display refresh rate; do not merely duplicate low-FPS frames")
        }
        return lines.joined(separator: "\n")
    }

    static func make(runtime: NativeRuntimeCore) -> CompositeFallbackQualityReport {
        make(manifest: runtime.manifest, bundleRoot: runtime.config.wallpaperRoot)
    }

    static func make(
        manifest: WallpaperNativeManifest,
        bundleRoot: URL
    ) -> CompositeFallbackQualityReport {
        let targetFps = manifest.runtime.targetFps
        let maxFps = manifest.runtime.maxFps
        let recommended = "display-refresh"

        guard let compositeVideo = manifest.assets.compositeVideo else {
            return CompositeFallbackQualityReport(
                status: "not-used",
                targetFps: targetFps,
                maxFps: maxFps,
                recommendedExportFps: nil,
                assetPath: nil,
                fpsText: "none",
                effectiveFpsText: "none",
                playbackRateText: "none",
                sizeText: "none",
                durationText: "none",
                warnings: []
            )
        }

        let url = bundleRoot
            .standardizedFileURL
            .appendingPathComponent(compositeVideo.path)
            .standardizedFileURL
        let playbackRate = compositeVideo.playbackRate ?? 1

        do {
            let metadata = try VideoMetadataInspector.inspect(url: url)
            let effectiveFps = metadata.effectiveFrameRate(playbackRate: playbackRate)
            let warnings = qualityWarnings(
                effectiveFps: effectiveFps,
                targetFps: targetFps
            )
            return CompositeFallbackQualityReport(
                status: warnings.isEmpty ? "ok" : "warning",
                targetFps: targetFps,
                maxFps: maxFps,
                recommendedExportFps: warnings.isEmpty ? nil : recommended,
                assetPath: compositeVideo.path,
                fpsText: formatNumber(Double(metadata.nominalFrameRate)),
                effectiveFpsText: formatNumber(effectiveFps),
                playbackRateText: "\(formatNumber(Double(playbackRate)))x",
                sizeText: sizeText(metadata.presentationSize),
                durationText: metadata.durationSeconds.map { "\(formatNumber($0))s" } ?? "unknown",
                warnings: warnings
            )
        } catch {
            return CompositeFallbackQualityReport(
                status: "warning",
                targetFps: targetFps,
                maxFps: maxFps,
                recommendedExportFps: recommended,
                assetPath: compositeVideo.path,
                fpsText: "unknown",
                effectiveFpsText: "unknown",
                playbackRateText: "\(formatNumber(Double(playbackRate)))x",
                sizeText: "unknown",
                durationText: "unknown",
                warnings: ["compositeVideo metadata unreadable: \(error.localizedDescription)"]
            )
        }
    }

    private static func qualityWarnings(
        effectiveFps: Double?,
        targetFps: Int
    ) -> [String] {
        guard let effectiveFps else {
            return ["compositeVideo FPS metadata unavailable"]
        }
        guard effectiveFps + 0.5 >= Double(targetFps) else {
            return ["compositeVideo effectiveFps=\(formatNumber(effectiveFps)) below target=\(targetFps)"]
        }
        return []
    }

    private static func sizeText(_ size: CGSize) -> String {
        let width = Int(abs(size.width).rounded())
        let height = Int(abs(size.height).rounded())
        return "\(width)x\(height)"
    }
}

func formatVideoDiagnosticNumber(_ value: Double?) -> String {
    guard let value, value.isFinite else {
        return "unknown"
    }
    let rounded = value.rounded()
    if abs(value - rounded) < 0.005 {
        return "\(Int(rounded))"
    }
    return String(format: "%.2f", value)
}

private func formatNumber(_ value: Double?) -> String {
    formatVideoDiagnosticNumber(value)
}
