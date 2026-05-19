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
    let recommendations: [String]

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
        if recommendations.isEmpty {
            lines.append("recommendations: none")
        } else {
            lines.append("recommendations:")
            lines.append(contentsOf: recommendations.map { "- \($0)" })
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
                warnings: [],
                recommendations: []
            )
        }

        let url = bundleRoot
            .standardizedFileURL
            .appendingPathComponent(compositeVideo.path)
            .standardizedFileURL
        let playbackRate = compositeVideo.playbackRate ?? 1

        do {
            let metadata = try VideoMetadataInspector.inspect(url: url)
            let referenceVideoMetadata = referenceVideoMetadata(
                manifest: manifest,
                bundleRoot: bundleRoot,
                compositeURL: url
            )
            let effectiveFps = metadata.effectiveFrameRate(playbackRate: playbackRate)
            let warnings = qualityWarnings(
                effectiveFps: effectiveFps,
                targetFps: targetFps
            )
            let recommendations = qualityRecommendations(
                effectiveFps: effectiveFps,
                targetFps: targetFps,
                maxFps: maxFps,
                compositeSize: metadata.presentationSize,
                referenceVideoSize: referenceVideoMetadata?.presentationSize
            )
            return CompositeFallbackQualityReport(
                status: qualityStatus(warnings: warnings, recommendations: recommendations),
                targetFps: targetFps,
                maxFps: maxFps,
                recommendedExportFps: warnings.isEmpty && recommendations.isEmpty ? nil : recommended,
                assetPath: compositeVideo.path,
                fpsText: formatNumber(Double(metadata.nominalFrameRate)),
                effectiveFpsText: formatNumber(effectiveFps),
                playbackRateText: "\(formatNumber(Double(playbackRate)))x",
                sizeText: sizeText(metadata.presentationSize),
                durationText: metadata.durationSeconds.map { "\(formatNumber($0))s" } ?? "unknown",
                warnings: warnings,
                recommendations: recommendations
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
                warnings: ["compositeVideo metadata unreadable: \(error.localizedDescription)"],
                recommendations: []
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

    private static func qualityRecommendations(
        effectiveFps: Double?,
        targetFps: Int,
        maxFps: Int,
        compositeSize: CGSize,
        referenceVideoSize: CGSize?
    ) -> [String] {
        var recommendations: [String] = []
        if maxFps > targetFps,
           let effectiveFps,
           effectiveFps + 0.5 < Double(maxFps) {
            recommendations.append(
                "compositeVideo effectiveFps=\(formatNumber(effectiveFps)) below maxFps=\(maxFps); regenerate at display-refresh if Composite fallback will be used on high-refresh displays"
            )
        }
        recommendations.append(contentsOf: resolutionRecommendations(
            compositeSize: compositeSize,
            referenceVideoSize: referenceVideoSize
        ))
        return recommendations
    }

    private static func resolutionRecommendations(
        compositeSize: CGSize,
        referenceVideoSize: CGSize?
    ) -> [String] {
        guard let referenceVideoSize else { return [] }
        let compositeWidth = Int(abs(compositeSize.width).rounded())
        let compositeHeight = Int(abs(compositeSize.height).rounded())
        let referenceWidth = Int(abs(referenceVideoSize.width).rounded())
        let referenceHeight = Int(abs(referenceVideoSize.height).rounded())
        guard compositeWidth > 0,
              compositeHeight > 0,
              referenceWidth > 0,
              referenceHeight > 0,
              (compositeWidth < referenceWidth || compositeHeight < referenceHeight) else {
            return []
        }
        return [
            "compositeVideo size=\(compositeWidth)x\(compositeHeight) below backgroundVideo size=\(referenceWidth)x\(referenceHeight); keep Native Spine as the default path and regenerate the fallback at source/display resolution only if fallback visual quality must match"
        ]
    }

    private static func referenceVideoMetadata(
        manifest: WallpaperNativeManifest,
        bundleRoot: URL,
        compositeURL: URL
    ) -> VideoMetadata? {
        guard let video = manifest.assets.video else { return nil }
        let url = bundleRoot
            .standardizedFileURL
            .appendingPathComponent(video.path)
            .standardizedFileURL
        guard url.path != compositeURL.path else { return nil }
        return try? VideoMetadataInspector.inspect(url: url)
    }

    private static func qualityStatus(warnings: [String], recommendations: [String]) -> String {
        if warnings.isEmpty == false {
            return "warning"
        }
        if recommendations.isEmpty == false {
            return "degraded"
        }
        return "ok"
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
