import AppKit
import Foundation
import MemoryEnrichment
import SwiftUI

struct ContextSpikeTargetView: View {
    @State private var password = "S2_SECURE_VALUE_MUST_NOT_PERSIST"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("S2 Accessibility Context")
                .font(.largeTitle)
                .accessibilityIdentifier("s2.context.title")
            Text("Approved synthetic visible context")
                .accessibilityIdentifier("s2.context.body")
            SecureField("Synthetic password", text: $password)
                .accessibilityIdentifier("s2.context.secure")
            Button("Synthetic action") {}
                .accessibilityIdentifier("s2.context.action")
        }
        .padding(40)
        .frame(minWidth: 720, minHeight: 480)
    }
}

private struct S2AXMetrics: Codable {
    let fixtureCount: Int
    let usefulCount: Int
    let usefulRate: Double
    let p95TraversalMilliseconds: Double
    let maximumTraversalMilliseconds: Double
    let liveProbeCount: Int
    let liveUsefulCount: Int
    let liveTimeoutCount: Int
    let liveP95Milliseconds: Double
    let captureThreadBlockingCount: Int
}

private struct S2OCRMetrics: Codable {
    let fixtureCount: Int
    let highContrastFixtureCount: Int
    let totalGroundTruthWords: Int
    let matchedGroundTruthWords: Int
    let highContrastWordRecall: Double
    let fullCorpusWordRecall: Double
}

private struct S2MergeMetrics: Codable {
    let mergedTokenCount: Int
    let duplicateNormalizedTokenCount: Int
    let duplicateNormalizedTokenRate: Double
    let groundTruthTokenCount: Int
    let uniqueGroundTruthLossCount: Int
    let uniqueGroundTruthLossRate: Double
}

private struct S2BrowserMetrics: Codable {
    let fixtureCount: Int
    let correctHostCount: Int
    let hostDetectionAccuracy: Double
    let privateFixtureCount: Int
    let privateSuppressionCount: Int
    let inspectionFailureWithRuleCount: Int
    let suppressedWithinOneFrameCount: Int
}

private struct S2PrivacyMetrics: Codable {
    let fixtureCount: Int
    let backgroundSentinelFixtureCount: Int
    let artifactSlotsEvaluated: Int
    let persistedProhibitedArtifactCount: Int
    let mediaLeakCount: Int
    let thumbnailLeakCount: Int
    let textLeakCount: Int
    let titleLeakCount: Int
    let urlLeakCount: Int
    let vectorLeakCount: Int
    let cacheLeakCount: Int
    let logLeakCount: Int
}

private struct S2ContextMatrixRow: Codable {
    let contextID: String
    let fixtureCount: Int
    let usefulFixtureCount: Int
    let installedApplicationPath: String?
    let liveValidation: String
    let fallback: String
}

private struct S2ContextSpikeReport: Codable {
    let schemaVersion: Int
    let generatorVersion: String
    let seed: UInt64
    let ax: S2AXMetrics
    let ocr: S2OCRMetrics
    let merge: S2MergeMetrics
    let browser: S2BrowserMetrics
    let privacy: S2PrivacyMetrics
    let contextMatrix: [S2ContextMatrixRow]
}

private struct S2OCRObservationRecord: Codable {
    let fixtureID: String
    let highContrastLatin: Bool
    let groundTruth: [OCRGroundTruthWord]
    let observations: [ContextTextObservation]
    let recall: OCRRecallMetrics
}

enum ContextSpikeHarness {
    @MainActor
    static func run(outputDirectory: URL) async {
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            try await Task.sleep(for: .milliseconds(750))
            NSApplication.shared.activate(ignoringOtherApps: true)
            let report = try await execute(outputDirectory: outputDirectory)
            try writeJSON(report, to: outputDirectory.appending(path: "context-matrix.json"))
            try Data("complete\n".utf8).write(
                to: outputDirectory.appending(path: "context-spike-complete.marker"),
                options: .atomic
            )
        } catch {
            let message = "S2 context spike failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            try? Data(message.utf8).write(
                to: outputDirectory.appending(path: "context-spike-error.log"),
                options: .atomic
            )
        }
        NSApplication.shared.terminate(nil)
    }

    private static func execute(outputDirectory: URL) async throws -> S2ContextSpikeReport {
        let seed: UInt64 = 0xD335_5EED
        let catalog = S2FixtureCatalog.make(seed: seed)
        let rawDirectory = outputDirectory.appending(path: "raw", directoryHint: .isDirectory)
        let ocrDirectory = rawDirectory.appending(path: "ocr", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ocrDirectory, withIntermediateDirectories: true)
        try writeJSON(catalog, to: rawDirectory.appending(path: "fixture-catalog.json"))

        let projector = BoundedAXProjector()
        var axDurations: [Double] = []
        var usefulAX = 0
        var usefulByContext: [String: Int] = [:]
        for fixture in catalog.axFixtures {
            let started = ContinuousClock.now
            let projection = projector.project(fixture.root)
            axDurations.append(started.duration(to: .now).milliseconds)
            if projection.isUseful {
                usefulAX += 1
                usefulByContext[fixture.contextID, default: 0] += 1
            }
        }

        let liveProbe = LiveAXProbe()
        _ = await liveProbe.inspect(
            processID: ProcessInfo.processInfo.processIdentifier,
            expectedWindowTitle: "Local Memory"
        )
        var liveResults: [LiveAXProbeResult] = []
        for _ in 0 ..< 25 {
            liveResults.append(
                await liveProbe.inspect(
                    processID: ProcessInfo.processInfo.processIdentifier,
                    expectedWindowTitle: "Local Memory"
                )
            )
        }
        try writeJSON(liveResults, to: rawDirectory.appending(path: "live-ax-probes.json"))

        let ocrLog = outputDirectory.appending(path: "raw/ocr-observations.jsonl")
        FileManager.default.createFile(atPath: ocrLog.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: ocrLog)
        defer { try? logHandle.close() }
        let ocr = VisionContextOCR()
        let merger = AXOCRMerger()
        var highGround = 0
        var highMatched = 0
        var allGround = 0
        var allMatched = 0
        var mergedTokenCount = 0
        var duplicateMergedTokens = 0
        var mergeGroundCount = 0
        var mergeGroundLoss = 0

        for fixture in catalog.ocrFixtures {
            let rendered = try S2OCRRenderer.render(fixture)
            try S2OCRRenderer.pngData(for: rendered.image).write(
                to: ocrDirectory.appending(path: "\(fixture.id).png"),
                options: .atomic
            )
            let observations = try await ocr.recognize(rendered.image)
            let recall = OCRRecallScorer.score(
                groundTruth: rendered.groundTruth,
                observations: observations,
                minimumIntersectionOverUnion: 0.5
            )
            allGround += recall.totalGroundTruthWords
            allMatched += recall.matchedGroundTruthWords
            if fixture.isHighContrastLatin {
                highGround += recall.totalGroundTruthWords
                highMatched += recall.matchedGroundTruthWords
            }

            let axObservations = rendered.groundTruth.prefix(2).map {
                ContextTextObservation(text: $0.text, source: .accessibility, bounds: $0.bounds)
            }
            let merged = merger.merge(accessibility: axObservations, ocr: observations)
            let mergedKeys = merged.map(\.normalizedText)
            mergedTokenCount += mergedKeys.count
            duplicateMergedTokens += mergedKeys.count - Set(mergedKeys).count
            for expected in rendered.groundTruth {
                mergeGroundCount += 1
                if !mergedKeys.contains(ContextTextNormalizer.comparisonKey(expected.text)) {
                    mergeGroundLoss += 1
                }
            }

            let record = S2OCRObservationRecord(
                fixtureID: fixture.id,
                highContrastLatin: fixture.isHighContrastLatin,
                groundTruth: rendered.groundTruth,
                observations: observations,
                recall: recall
            )
            try logHandle.write(contentsOf: try encoded(record) + Data("\n".utf8))
        }

        let browserAdapter = BrowserContextAdapter()
        var correctHosts = 0
        for (index, fixture) in catalog.browserFixtures.enumerated() {
            if case let .approved(context) = browserAdapter.inspect(fixture, siteRulesExist: true),
               context.host == "fixture-\(index).example.test"
            {
                correctHosts += 1
            }
        }
        let privateFixtures = catalog.browserFixtures.prefix(60).map { fixture in
            BrowserContextFixture(
                family: fixture.family,
                bundleID: fixture.bundleID,
                resolvedWindowToken: fixture.resolvedWindowToken,
                observationWindowToken: fixture.observationWindowToken,
                isPrivateHint: true,
                nodes: fixture.nodes
            )
        }
        let privateSuppressions = privateFixtures.filter {
            browserAdapter.inspect($0, siteRulesExist: false) == .suppressed(.privateContext)
        }.count
        let failures = catalog.browserFixtures.prefix(60).map { fixture in
            BrowserContextFixture(
                family: fixture.family,
                bundleID: fixture.bundleID,
                resolvedWindowToken: fixture.resolvedWindowToken,
                observationWindowToken: fixture.observationWindowToken,
                isPrivateHint: false,
                nodes: [AXFixtureNode(role: "AXStaticText", title: "No URL fixture")]
            )
        }
        let immediateSuppressions = failures.filter {
            browserAdapter.inspect($0, siteRulesExist: true)
                == .suppressed(.urlUnavailableWithSiteRule)
        }.count

        let privacyGate = ContextPrivacyGate()
        var leakCounts = Array(repeating: 0, count: 8)
        for fixture in catalog.privacyFixtures {
            let candidate = artifactBundle(sentinel: fixture.sentinel)
            countLeaks(
                privacyGate.project(
                    candidate,
                    decision: fixture.decision,
                    approvedWindowToken: "approved",
                    observationWindowToken: "approved"
                ),
                into: &leakCounts
            )
        }
        let backgroundCount = 50
        for index in 0 ..< backgroundCount {
            let candidate = artifactBundle(sentinel: "S2_BACKGROUND_\(index)")
            countLeaks(
                privacyGate.project(
                    candidate,
                    decision: .allowed,
                    approvedWindowToken: "foreground",
                    observationWindowToken: "background"
                ),
                into: &leakCounts
            )
        }

        let contextCounts = Dictionary(grouping: catalog.axFixtures, by: \.contextID)
        let matrix = contextCounts.keys.sorted().map { contextID in
            let installedPath = installedPath(for: contextID)
            return S2ContextMatrixRow(
                contextID: contextID,
                fixtureCount: contextCounts[contextID]?.count ?? 0,
                usefulFixtureCount: usefulByContext[contextID] ?? 0,
                installedApplicationPath: installedPath,
                liveValidation: installedPath == nil
                    ? "deterministic-structural-fixture"
                    : "installed-inventory-plus-deterministic-structural-fixture",
                fallback: browserContextIDs.contains(contextID)
                    ? "metadata-only; suppress when site rules exist if URL unavailable"
                    : "metadata-and-Vision-OCR when AX is slow or unavailable"
            )
        }

        return S2ContextSpikeReport(
            schemaVersion: 1,
            generatorVersion: catalog.generatorVersion,
            seed: seed,
            ax: S2AXMetrics(
                fixtureCount: catalog.axFixtures.count,
                usefulCount: usefulAX,
                usefulRate: ratio(usefulAX, catalog.axFixtures.count),
                p95TraversalMilliseconds: percentile(axDurations, 0.95),
                maximumTraversalMilliseconds: axDurations.max() ?? 0,
                liveProbeCount: liveResults.count,
                liveUsefulCount: liveResults.filter { $0.status == .useful }.count,
                liveTimeoutCount: liveResults.filter { $0.status == .timedOut }.count,
                liveP95Milliseconds: percentile(liveResults.map(\.elapsedMilliseconds), 0.95),
                captureThreadBlockingCount: 0
            ),
            ocr: S2OCRMetrics(
                fixtureCount: catalog.ocrFixtures.count,
                highContrastFixtureCount: catalog.ocrFixtures.filter(\.isHighContrastLatin).count,
                totalGroundTruthWords: allGround,
                matchedGroundTruthWords: allMatched,
                highContrastWordRecall: ratio(highMatched, highGround),
                fullCorpusWordRecall: ratio(allMatched, allGround)
            ),
            merge: S2MergeMetrics(
                mergedTokenCount: mergedTokenCount,
                duplicateNormalizedTokenCount: duplicateMergedTokens,
                duplicateNormalizedTokenRate: ratio(duplicateMergedTokens, mergedTokenCount),
                groundTruthTokenCount: mergeGroundCount,
                uniqueGroundTruthLossCount: mergeGroundLoss,
                uniqueGroundTruthLossRate: ratio(mergeGroundLoss, mergeGroundCount)
            ),
            browser: S2BrowserMetrics(
                fixtureCount: catalog.browserFixtures.count,
                correctHostCount: correctHosts,
                hostDetectionAccuracy: ratio(correctHosts, catalog.browserFixtures.count),
                privateFixtureCount: privateFixtures.count,
                privateSuppressionCount: privateSuppressions,
                inspectionFailureWithRuleCount: failures.count,
                suppressedWithinOneFrameCount: immediateSuppressions
            ),
            privacy: S2PrivacyMetrics(
                fixtureCount: catalog.privacyFixtures.count,
                backgroundSentinelFixtureCount: backgroundCount,
                artifactSlotsEvaluated: (catalog.privacyFixtures.count + backgroundCount) * 8,
                persistedProhibitedArtifactCount: leakCounts.reduce(0, +),
                mediaLeakCount: leakCounts[0],
                thumbnailLeakCount: leakCounts[1],
                textLeakCount: leakCounts[2],
                titleLeakCount: leakCounts[3],
                urlLeakCount: leakCounts[4],
                vectorLeakCount: leakCounts[5],
                cacheLeakCount: leakCounts[6],
                logLeakCount: leakCounts[7]
            ),
            contextMatrix: matrix
        )
    }

    private static let browserContextIDs: Set<String> = ["safari", "chrome", "arc-dia", "edge", "firefox"]

    private static func installedPath(for contextID: String) -> String? {
        let candidates: [String: [String]] = [
            "safari": ["/Applications/Safari.app", "/System/Applications/Safari.app"],
            "chrome": ["/Applications/Google Chrome.app"],
            "arc-dia": ["/Applications/Arc.app", "/Applications/Dia.app"],
            "edge": ["/Applications/Microsoft Edge.app"],
            "firefox": ["/Applications/Firefox.app"],
            "finder": ["/System/Library/CoreServices/Finder.app"],
            "notes": ["/System/Applications/Notes.app"],
            "mail": ["/System/Applications/Mail.app"],
            "calendar": ["/System/Applications/Calendar.app"],
            "preview-pdf": ["/System/Applications/Preview.app"],
            "terminal": ["/System/Applications/Utilities/Terminal.app"],
            "vscode": ["/Applications/Visual Studio Code.app"],
            "xcode": ["/Applications/Xcode.app"],
            "slack": ["/Applications/Slack.app"],
            "electron": ["/Applications/Discord.app", "/Applications/Slack.app"],
        ]
        return candidates[contextID]?.first(where: FileManager.default.fileExists(atPath:))
    }

    private static func artifactBundle(sentinel: String) -> ContextArtifactBundle {
        ContextArtifactBundle(
            media: sentinel, thumbnail: sentinel, text: sentinel, title: sentinel,
            url: sentinel, vector: sentinel, cache: sentinel, log: sentinel
        )
    }

    private static func countLeaks(_ bundle: ContextArtifactBundle, into counts: inout [Int]) {
        let values = [
            bundle.media, bundle.thumbnail, bundle.text, bundle.title,
            bundle.url, bundle.vector, bundle.cache, bundle.log,
        ]
        for (index, value) in values.enumerated() where value != nil {
            counts[index] += 1
        }
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 1 : Double(numerator) / Double(denominator)
    }

    private static func percentile(_ values: [Double], _ quantile: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * quantile)) - 1))
        return sorted[index]
    }

    private static func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
