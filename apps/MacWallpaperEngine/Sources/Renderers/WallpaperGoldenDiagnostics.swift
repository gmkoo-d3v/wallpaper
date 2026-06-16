import Foundation

struct WallpaperGoldenDiagnostics {
    private struct GoldenManifest: Decodable {
        let version: Int
        let fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        let id: String
        let action: String
        let time: Double
        let size: String
        let reference: String
        let input: SnapshotInputState?
        let thresholds: Thresholds?
    }

    private struct Thresholds: Decodable {
        let maxMeanAbsoluteError: Double?
        let maxDelta: Int?
        let maxChangedPixelRatio: Double?

        static let exact = Thresholds(
            maxMeanAbsoluteError: 0,
            maxDelta: 0,
            maxChangedPixelRatio: 0
        )

        private init(
            maxMeanAbsoluteError: Double?,
            maxDelta: Int?,
            maxChangedPixelRatio: Double?
        ) {
            self.maxMeanAbsoluteError = maxMeanAbsoluteError
            self.maxDelta = maxDelta
            self.maxChangedPixelRatio = maxChangedPixelRatio
        }
    }

    private struct FixtureResult {
        let fixture: Fixture
        let width: Int
        let height: Int
        let referenceURL: URL
        let metrics: WallpaperSnapshotDiagnostics.DiffMetrics
        let passed: Bool

        var line: String {
            [
                "golden",
                fixture.id,
                fixture.action,
                WallpaperGoldenDiagnostics.formatSeconds(fixture.time),
                "\(width)x\(height)",
                WallpaperGoldenDiagnostics.formatNumber(metrics.meanAbsoluteError),
                metrics.maxDelta == Int.max ? "inf" : "\(metrics.maxDelta)",
                WallpaperGoldenDiagnostics.formatNumber(metrics.changedPixelRatio * 100) + "%",
                passed ? "pass" : "fail",
                fixture.input?.summary ?? "default",
                referenceURL.path
            ].joined(separator: "\t")
        }
    }

    static func make(runtime: NativeRuntimeCore, goldenURL: URL?) throws -> String {
        let manifestURL = goldenURL
            ?? runtime.config.wallpaperRoot.appendingPathComponent("golden/wallpaper.golden.json")
        let manifest = try loadManifest(from: manifestURL)
        guard manifest.version == 1 else {
            throw EngineError.manifest("Unsupported wallpaper golden manifest version: \(manifest.version)")
        }
        guard manifest.fixtures.isEmpty == false else {
            throw EngineError.manifest("Wallpaper golden manifest must contain at least one fixture: \(manifestURL.path)")
        }

        var results: [FixtureResult] = []
        var failures: [String] = []
        for fixture in manifest.fixtures {
            do {
                let result = try renderFixture(fixture, runtime: runtime)
                results.append(result)
                if result.passed == false {
                    failures.append(result.fixture.id)
                }
            } catch {
                failures.append(fixture.id)
                throw EngineError.renderer(
                    "wallpaper golden fixture failed: \(fixture.id)\n\(error.localizedDescription)"
                )
            }
        }

        var lines = [
            failures.isEmpty ? "wallpaper golden check OK" : "wallpaper golden check FAILED",
            "manifest: \(manifestURL.path)",
            "fixtures: \(results.count)",
            "columns: type\tid\taction\ttime\tsize\tmae\tmax\tchangedPixels\tstatus\tinput\treference"
        ]
        lines.append(contentsOf: results.map(\.line))
        let report = lines.joined(separator: "\n")
        if failures.isEmpty == false {
            throw EngineError.renderer(report)
        }
        return report
    }

    private static func loadManifest(from url: URL) throws -> GoldenManifest {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(GoldenManifest.self, from: data)
        } catch let error as DecodingError {
            throw EngineError.manifest("Invalid wallpaper golden manifest \(url.path): \(error)")
        } catch {
            throw EngineError.asset("Could not read wallpaper golden manifest \(url.path): \(error.localizedDescription)")
        }
    }

    private static func renderFixture(
        _ fixture: Fixture,
        runtime: NativeRuntimeCore
    ) throws -> FixtureResult {
        let id = fixture.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.isEmpty == false else {
            throw EngineError.manifest("Golden fixture id cannot be empty")
        }
        let action = fixture.action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard action.isEmpty == false else {
            throw EngineError.manifest("Golden fixture action cannot be empty: \(id)")
        }
        guard fixture.time.isFinite, fixture.time >= 0 else {
            throw EngineError.manifest("Golden fixture time must be finite and non-negative: \(id)")
        }
        let size = try parsePixelSize(fixture.size, fixtureID: id)
        let referenceURL = try resolveBundleRelativePath(fixture.reference, runtime: runtime)
        let inputState = fixture.input ?? SnapshotInputState()

        let snapshot = try WallpaperSnapshotDiagnostics.renderSnapshot(
            runtime: runtime,
            actionName: action,
            time: fixture.time,
            width: size.width,
            height: size.height,
            inputState: inputState
        )
        let metrics = try WallpaperSnapshotDiagnostics.diffMetrics(
            generated: snapshot.image,
            reference: referenceURL
        )
        let thresholds = fixture.thresholds ?? .exact
        let passed = metrics.dimensionsMatch
            && metrics.meanAbsoluteError <= (thresholds.maxMeanAbsoluteError ?? 0)
            && metrics.maxDelta <= (thresholds.maxDelta ?? 0)
            && metrics.changedPixelRatio <= (thresholds.maxChangedPixelRatio ?? 0)

        return FixtureResult(
            fixture: fixture,
            width: size.width,
            height: size.height,
            referenceURL: referenceURL,
            metrics: metrics,
            passed: passed
        )
    }

    private static func parsePixelSize(_ value: String, fixtureID: String) throws -> (width: Int, height: Int) {
        let parts = value.components(separatedBy: CharacterSet(charactersIn: "xX"))
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width > 0,
              height > 0,
              width <= 8192,
              height <= 8192 else {
            throw EngineError.manifest("Invalid golden fixture size for \(fixtureID): \(value)")
        }
        return (width, height)
    }

    private static func resolveBundleRelativePath(_ path: String, runtime: NativeRuntimeCore) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw EngineError.manifest("Golden fixture reference cannot be empty")
        }
        guard trimmed.hasPrefix("/") == false else {
            throw EngineError.manifest("Golden fixture reference must be bundle-relative: \(trimmed)")
        }

        let root = runtime.config.wallpaperRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = runtime.config.wallpaperRoot
            .appendingPathComponent(trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = root.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw EngineError.manifest("Golden fixture reference escapes wallpaper bundle: \(trimmed)")
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw EngineError.asset("Golden fixture reference is missing: \(candidate.path)")
        }
        return candidate
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.3fs", value)
    }

    private static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return "inf" }
        return String(format: "%.4f", value)
    }
}
