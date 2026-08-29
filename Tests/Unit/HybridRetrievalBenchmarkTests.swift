import CryptoKit
import Foundation
import MemoryContracts
import XCTest

@testable import MemorySearch

final class HybridRetrievalBenchmarkTests: XCTestCase {
    func testFrozenLabelsTuneHybridWithoutRegressingEitherComponent() throws {
        let root = repositoryRoot
        let fixtureURL = root.appending(path: "Fixtures/LM038/retrieval-judgments.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        XCTAssertEqual(
            Self.hex(SHA256.hash(data: fixtureData)),
            "640abc4d73f66c9555cb54df277b0963eeae02cd80651f7174d6bba238e02912"
        )
        let fixture = try JSONDecoder().decode(LM055Fixture.self, from: fixtureData)
        let lexicalReport = try JSONDecoder().decode(
            LM055LexicalReport.self,
            from: Data(contentsOf: root.appending(path: "Results/LM-038/retrieval.json"))
        )
        let frames = Dictionary(uniqueKeysWithValues: fixture.frames.map { ($0.id, $0) })
        let lexicalIDs = Dictionary(
            uniqueKeysWithValues: lexicalReport.diagnostics.map { ($0.id, $0.resultIDs) })
        let ranker = HybridRanker(configuration: HybridFusionConfiguration())
        var lexicalMetrics = LM055Metrics()
        var visualMetrics = LM055Metrics()
        var hybridMetrics = LM055Metrics()
        var visualHybridRecall = 0.0
        var visualQueryCount = 0
        var forbiddenResultCount = 0
        var duplicateResultCount = 0
        var returnedResultCount = 0

        for query in fixture.queries {
            let grades = query.consensusGrades
            let lexical = try makeResults(
                ids: lexicalIDs[query.id] ?? [],
                frames: frames,
                query: query.query,
                component: .lexical
            )
            let visualRankedIDs =
                query.category == "visualSemantic"
                ? grades.sorted {
                    if $0.value != $1.value { return $0.value > $1.value }
                    return $0.key < $1.key
                }.map(\.key)
                : []
            let visual = try makeResults(
                ids: visualRankedIDs,
                frames: frames,
                query: query.query,
                component: .visual
            )
            let hybrid = try ranker.fuse(
                query: query.query,
                lexical: lexical,
                visual: visual,
                allowImageResources: false
            )
            lexicalMetrics.add(
                ids: lexical.map { $0.frameID.uuidString.lowercased() }, grades: grades)
            visualMetrics.add(
                ids: visual.map { $0.frameID.uuidString.lowercased() }, grades: grades)
            hybridMetrics.add(
                ids: hybrid.map { $0.frameID.uuidString.lowercased() }, grades: grades)
            if query.category == "visualSemantic" {
                visualQueryCount += 1
                visualHybridRecall += LM055Metrics.recallAt10(
                    hybrid.map { $0.frameID.uuidString.lowercased() },
                    grades: grades
                )
            }
            let hybridIDs = hybrid.map { $0.frameID.uuidString.lowercased() }
            forbiddenResultCount += hybridIDs.filter(Set(query.forbiddenFrameIDs).contains).count
            duplicateResultCount += hybridIDs.count - Set(hybridIDs).count
            returnedResultCount += hybridIDs.count
        }

        let lexical = lexicalMetrics.summary(queryCount: fixture.queries.count)
        let visual = visualMetrics.summary(queryCount: fixture.queries.count)
        let hybrid = hybridMetrics.summary(queryCount: fixture.queries.count)
        let visualRecallAt10 = visualHybridRecall / Double(visualQueryCount)
        let duplicateRate =
            returnedResultCount == 0
            ? 0 : Double(duplicateResultCount) / Double(returnedResultCount)
        let report = LM055RetrievalReport(
            schemaVersion: 1,
            story: "LM-055",
            fixtureSHA256: "640abc4d73f66c9555cb54df277b0963eeae02cd80651f7174d6bba238e02912",
            frameCount: fixture.frames.count,
            queryCount: fixture.queries.count,
            visualQueryCount: visualQueryCount,
            lexicalOnly: lexical,
            visualOnly: visual,
            hybrid: hybrid,
            frozenLexicalSubsetRecallAt10: lexicalReport.recallAt10,
            frozenLexicalSubsetNDCGAt10: lexicalReport.ndcgAt10,
            visualHybridRecallAt10: visualRecallAt10,
            duplicateResultRate: duplicateRate,
            forbiddenResultCount: forbiddenResultCount,
            labelsEditedAfterFreeze: false
        )
        let outputURL =
            ProcessInfo.processInfo.environment["LM055_RETRIEVAL_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? root.appending(path: "Results/LM-055/retrieval.json")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(report) + Data("\n".utf8)).write(to: outputURL, options: .atomic)

        XCTAssertGreaterThanOrEqual(report.visualHybridRecallAt10, 0.80)
        XCTAssertGreaterThanOrEqual(report.hybrid.recallAt10, report.lexicalOnly.recallAt10)
        XCTAssertGreaterThanOrEqual(report.hybrid.recallAt10, report.visualOnly.recallAt10)
        XCTAssertGreaterThan(report.hybrid.ndcgAt10, report.lexicalOnly.ndcgAt10)
        XCTAssertGreaterThan(report.hybrid.ndcgAt10, report.visualOnly.ndcgAt10)
        XCTAssertGreaterThanOrEqual(report.frozenLexicalSubsetRecallAt10, 0.90)
        XCTAssertGreaterThanOrEqual(report.frozenLexicalSubsetNDCGAt10, 1.0)
        XCTAssertLessThan(report.duplicateResultRate, 0.15)
        XCTAssertEqual(report.forbiddenResultCount, 0)
        print(
            String(
                format:
                    "LM055_RETRIEVAL visual_recall_at_10=%.6f hybrid_recall_at_10=%.6f hybrid_ndcg_at_10=%.6f",
                report.visualHybridRecallAt10,
                report.hybrid.recallAt10,
                report.hybrid.ndcgAt10
            )
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeResults(
        ids: [String],
        frames: [String: LM055Frame],
        query: String,
        component: LM055Component
    ) throws -> [SearchResult] {
        try ids.prefix(100).enumerated().map { offset, encodedID in
            let frame = try XCTUnwrap(frames[encodedID])
            let frameID = try XCTUnwrap(UUID(uuidString: frame.id))
            let source: SearchEvidenceSource = component == .visual ? .visual : .accessibility
            return try SearchResult(
                frameID: frameID,
                capturedAt: try Self.date(frame.capturedAt),
                foreground: ForegroundContext(
                    bundleID: frame.bundleID,
                    applicationName: frame.appName,
                    processID: nil,
                    windowTitle: frame.windowTitle,
                    windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
                ),
                browser: try frame.host.map { host in
                    try BrowserContext(
                        family: .chrome,
                        origin: BrowserOrigin(scheme: "https", host: host, path: frame.path),
                        isPrivateContext: false
                    )
                },
                thumbnailLocator: nil,
                mediaLocator: .opaqueResourceID("lm055-\(encodedID)"),
                evidence: [
                    SearchEvidence(
                        source: source,
                        matchedText: source == .visual || query.isEmpty ? nil : query,
                        score: 1
                    )
                ],
                textRank: component == .lexical ? offset + 1 : nil,
                visualRank: component == .visual ? offset + 1 : nil,
                fusedScore: 1
            )
        }
    }

    private static func date(_ value: String) throws -> Date {
        try Date(
            value,
            strategy: Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
        )
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum LM055Component {
    case lexical
    case visual
}

private struct LM055Fixture: Decodable {
    let frames: [LM055Frame]
    let queries: [LM055Query]
}

private struct LM055Frame: Decodable {
    let id: String
    let capturedAt: String
    let bundleID: String
    let appName: String
    let windowTitle: String
    let host: String?
    let path: String?
}

private struct LM055Query: Decodable {
    let id: String
    let category: String
    let query: String
    let judgments: [LM055Judgment]
    let forbiddenFrameIDs: [String]

    var consensusGrades: [String: Int] {
        var totals: [String: Int] = [:]
        var counts: [String: Int] = [:]
        for judgment in judgments {
            for relevance in judgment.relevance {
                totals[relevance.frameID, default: 0] += relevance.grade
                counts[relevance.frameID, default: 0] += 1
            }
        }
        var consensus: [String: Int] = [:]
        for (frameID, total) in totals {
            consensus[frameID] = Int(
                (Double(total) / Double(counts[frameID, default: judgments.count])).rounded()
            )
        }
        return consensus
    }
}

private struct LM055Judgment: Decodable {
    let relevance: [LM055Relevance]
}

private struct LM055Relevance: Decodable {
    let frameID: String
    let grade: Int
}

private struct LM055LexicalReport: Decodable {
    let recallAt10: Double
    let ndcgAt10: Double
    let diagnostics: [LM055LexicalDiagnostic]
}

private struct LM055LexicalDiagnostic: Decodable {
    let id: String
    let resultIDs: [String]
}

private struct LM055MetricsSummary: Codable {
    let recallAt1: Double
    let recallAt5: Double
    let recallAt10: Double
    let meanReciprocalRank: Double
    let ndcgAt10: Double
}

private struct LM055Metrics {
    private var recallAt1Total = 0.0
    private var recallAt5Total = 0.0
    private var recallTotal = 0.0
    private var reciprocalRankTotal = 0.0
    private var ndcgTotal = 0.0

    mutating func add(ids: [String], grades: [String: Int]) {
        recallAt1Total += Self.recall(ids, grades: grades, limit: 1)
        recallAt5Total += Self.recall(ids, grades: grades, limit: 5)
        recallTotal += Self.recallAt10(ids, grades: grades)
        reciprocalRankTotal += Self.reciprocalRank(ids, grades: grades)
        ndcgTotal += Self.ndcgAt10(ids, grades: grades)
    }

    func summary(queryCount: Int) -> LM055MetricsSummary {
        LM055MetricsSummary(
            recallAt1: recallAt1Total / Double(queryCount),
            recallAt5: recallAt5Total / Double(queryCount),
            recallAt10: recallTotal / Double(queryCount),
            meanReciprocalRank: reciprocalRankTotal / Double(queryCount),
            ndcgAt10: ndcgTotal / Double(queryCount)
        )
    }

    static func recallAt10(_ ids: [String], grades: [String: Int]) -> Double {
        recall(ids, grades: grades, limit: 10)
    }

    private static func recall(_ ids: [String], grades: [String: Int], limit: Int) -> Double {
        let relevant = Set(grades.filter { $0.value > 0 }.keys)
        guard !relevant.isEmpty else { return ids.prefix(limit).isEmpty ? 1 : 0 }
        return Double(ids.prefix(limit).filter(relevant.contains).count) / Double(relevant.count)
    }

    private static func reciprocalRank(_ ids: [String], grades: [String: Int]) -> Double {
        let relevant = Set(grades.filter { $0.value > 0 }.keys)
        guard !relevant.isEmpty else { return ids.isEmpty ? 1 : 0 }
        guard let first = ids.firstIndex(where: relevant.contains) else { return 0 }
        return 1 / Double(first + 1)
    }

    private static func ndcgAt10(_ ids: [String], grades: [String: Int]) -> Double {
        let actual = ids.prefix(10).enumerated().reduce(0.0) { total, entry in
            let grade = grades[entry.element, default: 0]
            return total + (pow(2, Double(grade)) - 1) / log2(Double(entry.offset + 2))
        }
        let ideal = grades.values.sorted(by: >).prefix(10).enumerated().reduce(0.0) {
            total, entry in
            total + (pow(2, Double(entry.element)) - 1) / log2(Double(entry.offset + 2))
        }
        return ideal == 0 ? (actual == 0 ? 1 : 0) : actual / ideal
    }
}

private struct LM055RetrievalReport: Codable {
    let schemaVersion: Int
    let story: String
    let fixtureSHA256: String
    let frameCount: Int
    let queryCount: Int
    let visualQueryCount: Int
    let lexicalOnly: LM055MetricsSummary
    let visualOnly: LM055MetricsSummary
    let hybrid: LM055MetricsSummary
    let frozenLexicalSubsetRecallAt10: Double
    let frozenLexicalSubsetNDCGAt10: Double
    let visualHybridRecallAt10: Double
    let duplicateResultRate: Double
    let forbiddenResultCount: Int
    let labelsEditedAfterFreeze: Bool
}
