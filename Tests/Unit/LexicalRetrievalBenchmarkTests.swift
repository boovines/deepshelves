import CryptoKit
import MemoryContracts
import MemorySearch
import XCTest

@testable import MemoryStore

final class LexicalRetrievalBenchmarkTests: XCTestCase {
    func testFrozenTextAppSiteTimeJudgmentsMeetRecallAndLatencyGate() async throws {
        let fixtureData = try Data(contentsOf: fixtureURL())
        XCTAssertEqual(Self.hex(SHA256.hash(data: fixtureData)), Self.frozenFixtureSHA256)
        let fixture = try JSONDecoder().decode(RetrievalFixture.self, from: fixtureData)
        XCTAssertEqual(fixture.corpus.frameCount, 500)
        XCTAssertEqual(fixture.corpus.queryCount, 100)
        XCTAssertEqual(fixture.corpus.lexicalEvaluationQueryCount, 75)
        XCTAssertEqual(fixture.queries.filter(\.includeInLexicalEvaluation).count, 75)
        XCTAssertTrue(fixture.queries.allSatisfy { $0.judgments.count == 3 })
        for query in fixture.queries {
            XCTAssertTrue(
                query.judgments.dropFirst().allSatisfy {
                    $0.relevance == query.judgments.first?.relevance
                })
        }

        let archive = try ArchiveDatabase.deterministicTestStore()
        let store = ArchiveSearchIndexStore(database: archive)
        for (index, frame) in fixture.frames.enumerated() {
            let expectedFrameID = try XCTUnwrap(UUID(uuidString: frame.id))
            let frameID = try archive.insertSearchFrameFixtureForTesting(
                suffix: index + 10_000,
                frameID: expectedFrameID,
                capturedAt: try Self.date(frame.capturedAt),
                bundleIdentifier: frame.bundleID,
                appName: frame.appName,
                windowTitle: frame.windowTitle,
                host: frame.host,
                path: frame.path
            )
            XCTAssertEqual(frameID, expectedFrameID)
            let accessibility = try Self.span(
                id: index * 2 + 1,
                frameID: frameID,
                source: .accessibility,
                text: frame.accessibilityText
            )
            let ocr = try Self.span(
                id: index * 2 + 2,
                frameID: frameID,
                source: .visionOCR,
                text: frame.ocrText
            )
            _ = try store.publish(
                ArchiveMergedTextSeed(
                    frameID: frameID,
                    approvedSpans: [accessibility, ocr],
                    transcriptSpans: [],
                    producerVersion: "lm038-frozen-v1"
                )
            )
        }
        XCTAssertTrue(try store.integritySnapshot().isConsistent)

        let interval = DateInterval(
            start: try Self.date("2026-08-01T00:00:00.000Z"),
            end: try Self.date("2026-08-31T00:00:00.000Z")
        )
        let policy = try AccessPolicy(
            id: UUID(uuidString: "38000000-0000-0000-0000-000000000001")!,
            name: "LM-038 frozen retrieval",
            allowedInterval: interval,
            allowedBundleIDs: Set(fixture.frames.map(\.bundleID)),
            allowedHosts: Set(fixture.frames.compactMap(\.host)),
            maxResults: 10,
            expiresAt: interval.end.addingTimeInterval(12 * 60 * 60),
            createdByUser: true
        )
        let engine = try LexicalSearchEngine(
            database: archive,
            cursorSigningKey: Data(repeating: 0x38, count: 32),
            now: { try! Self.date("2026-08-15T12:00:00.000Z") }
        )
        let lexicalQueries = fixture.queries.filter(\.includeInLexicalEvaluation)
        var diagnostics: [RetrievalDiagnostic] = []
        var latencies: [Double] = []
        var recallAt1Total = 0.0
        var recallAt5Total = 0.0
        var recallAt10Total = 0.0
        var reciprocalRankTotal = 0.0
        var ndcgAt10Total = 0.0
        var negativeCount = 0
        var correctNegativeCount = 0
        var forbiddenResultCount = 0

        for query in lexicalQueries {
            let relevance = query.judgments[0].relevance
            let grades = Dictionary(uniqueKeysWithValues: relevance.map { ($0.frameID, $0.grade) })
            let request = try SearchRequest(
                query: query.query,
                interval: try query.interval,
                bundleIDs: Set(query.bundleIDs),
                hosts: Set(query.hosts),
                mode: .textOnly,
                pageSize: 10,
                cursor: nil,
                accessPolicy: policy
            )
            var resultIDs: [String] = []
            var queryLatencies: [Double] = []
            for repetition in 0..<3 {
                let start = ContinuousClock.now
                let page = try await engine.search(request)
                let elapsed = start.duration(to: .now)
                let milliseconds =
                    Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
                queryLatencies.append(milliseconds)
                latencies.append(milliseconds)
                if repetition == 0 {
                    resultIDs = page.results.map { $0.frameID.uuidString.lowercased() }
                }
            }
            let relevantIDs = Set(grades.keys)
            let recallAt1 = Self.recall(resultIDs.prefix(1), relevant: relevantIDs)
            let recallAt5 = Self.recall(resultIDs.prefix(5), relevant: relevantIDs)
            let recallAt10 = Self.recall(resultIDs.prefix(10), relevant: relevantIDs)
            let reciprocalRank = Self.reciprocalRank(resultIDs, relevant: relevantIDs)
            let ndcg = Self.ndcg(resultIDs.prefix(10), grades: grades, idealLimit: 10)
            recallAt1Total += recallAt1
            recallAt5Total += recallAt5
            recallAt10Total += recallAt10
            reciprocalRankTotal += reciprocalRank
            ndcgAt10Total += ndcg
            if relevantIDs.isEmpty {
                negativeCount += 1
                if resultIDs.isEmpty { correctNegativeCount += 1 }
            }
            let forbidden = Set(query.forbiddenFrameIDs)
            let leaked = resultIDs.filter(forbidden.contains)
            forbiddenResultCount += leaked.count
            diagnostics.append(
                RetrievalDiagnostic(
                    id: query.id,
                    category: query.category,
                    relevantCount: relevantIDs.count,
                    resultIDs: resultIDs,
                    recallAt5: recallAt5,
                    reciprocalRank: reciprocalRank,
                    medianLatencyMilliseconds: Self.percentile(queryLatencies, 0.5),
                    forbiddenResultCount: leaked.count
                )
            )
        }

        let queryCount = Double(lexicalQueries.count)
        let report = RetrievalReport(
            schemaVersion: 1,
            story: "LM-038",
            fixtureSHA256: Self.frozenFixtureSHA256,
            frameCount: fixture.frames.count,
            totalQueryCount: fixture.queries.count,
            evaluatedQueryCount: lexicalQueries.count,
            excludedVisualQueryCount: fixture.queries.count - lexicalQueries.count,
            independentJudgmentsPerQuery: 3,
            recallAt1: recallAt1Total / queryCount,
            recallAt5: recallAt5Total / queryCount,
            recallAt10: recallAt10Total / queryCount,
            meanReciprocalRank: reciprocalRankTotal / queryCount,
            ndcgAt10: ndcgAt10Total / queryCount,
            noResultPrecision: Double(correctNegativeCount) / Double(negativeCount),
            p50LatencyMilliseconds: Self.percentile(latencies, 0.50),
            p95LatencyMilliseconds: Self.percentile(latencies, 0.95),
            p99LatencyMilliseconds: Self.percentile(latencies, 0.99),
            forbiddenResultCount: forbiddenResultCount,
            labelsEditedAfterFreeze: false,
            diagnostics: diagnostics
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let reportURL =
            ProcessInfo.processInfo.environment["LM038_REPORT_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? fixtureURL().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Results/LM-038/retrieval.json")
        try (encoder.encode(report) + Data("\n".utf8)).write(to: reportURL, options: .atomic)
        XCTAssertGreaterThanOrEqual(report.recallAt5, 0.90)
        XCTAssertLessThan(report.p95LatencyMilliseconds, 300)
        XCTAssertEqual(report.forbiddenResultCount, 0)
        XCTAssertEqual(report.noResultPrecision, 1)
        print(
            String(
                format:
                    "LM038_METRIC frames=%d queries=%d recall_at_5=%.6f p95_ms=%.6f forbidden=%d",
                fixture.frames.count,
                lexicalQueries.count,
                report.recallAt5,
                report.p95LatencyMilliseconds,
                report.forbiddenResultCount
            )
        )
    }

    private static let frozenFixtureSHA256 =
        "640abc4d73f66c9555cb54df277b0963eeae02cd80651f7174d6bba238e02912"

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/LM038/retrieval-judgments.json")
    }

    fileprivate static func date(_ value: String) throws -> Date {
        try Date(
            value,
            strategy: Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
        )
    }

    private static func span(
        id: Int,
        frameID: UUID,
        source: TextSource,
        text: String
    ) throws -> TextSpan {
        try TextSpan(
            id: UUID(uuidString: String(format: "38000000-0000-0000-0002-%012d", id))!,
            frameID: frameID,
            source: source,
            text: text,
            bounds: nil,
            confidence: source == .visionOCR ? 0.95 : nil,
            languageCode: source == .visionOCR ? "en" : nil,
            sensitivity: .normal
        )
    }

    private static func recall<C: Collection>(_ results: C, relevant: Set<String>) -> Double
    where C.Element == String {
        guard !relevant.isEmpty else { return results.isEmpty ? 1 : 0 }
        return Double(results.filter(relevant.contains).count) / Double(relevant.count)
    }

    private static func reciprocalRank(_ results: [String], relevant: Set<String>) -> Double {
        guard !relevant.isEmpty else { return results.isEmpty ? 1 : 0 }
        guard let index = results.firstIndex(where: relevant.contains) else { return 0 }
        return 1 / Double(index + 1)
    }

    private static func ndcg<S: Sequence>(
        _ results: S,
        grades: [String: Int],
        idealLimit: Int
    ) -> Double where S.Element == String {
        let actual = results.enumerated().reduce(0.0) { total, entry in
            let grade = grades[entry.element, default: 0]
            return total + (pow(2, Double(grade)) - 1) / log2(Double(entry.offset + 2))
        }
        let ideal = grades.values.sorted(by: >).prefix(idealLimit).enumerated().reduce(0.0) {
            total, entry in
            total + (pow(2, Double(entry.element)) - 1) / log2(Double(entry.offset + 2))
        }
        return ideal == 0 ? (actual == 0 ? 1 : 0) : actual / ideal
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * percentile).rounded(.down))
        return sorted[index]
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct RetrievalFixture: Decodable {
    let corpus: RetrievalCorpus
    let frames: [RetrievalFrame]
    let queries: [RetrievalQuery]
}

private struct RetrievalCorpus: Decodable {
    let frameCount: Int
    let queryCount: Int
    let lexicalEvaluationQueryCount: Int
}

private struct RetrievalFrame: Decodable {
    let id: String
    let capturedAt: String
    let bundleID: String
    let appName: String
    let windowTitle: String
    let host: String?
    let path: String?
    let accessibilityText: String
    let ocrText: String
}

private struct RetrievalQuery: Decodable {
    let id: String
    let category: String
    let includeInLexicalEvaluation: Bool
    let query: String
    let intervalStart: String?
    let intervalEnd: String?
    let bundleIDs: [String]
    let hosts: [String]
    let judgments: [RetrievalJudgment]
    let forbiddenFrameIDs: [String]

    var interval: DateInterval? {
        get throws {
            guard let intervalStart, let intervalEnd else { return nil }
            return try DateInterval(
                start: LexicalRetrievalBenchmarkTests.date(intervalStart),
                end: LexicalRetrievalBenchmarkTests.date(intervalEnd)
            )
        }
    }
}

private struct RetrievalJudgment: Decodable {
    let assessor: String
    let relevance: [RetrievalRelevance]
}

private struct RetrievalRelevance: Codable, Equatable {
    let frameID: String
    let grade: Int
}

private struct RetrievalDiagnostic: Codable {
    let id: String
    let category: String
    let relevantCount: Int
    let resultIDs: [String]
    let recallAt5: Double
    let reciprocalRank: Double
    let medianLatencyMilliseconds: Double
    let forbiddenResultCount: Int
}

private struct RetrievalReport: Codable {
    let schemaVersion: Int
    let story: String
    let fixtureSHA256: String
    let frameCount: Int
    let totalQueryCount: Int
    let evaluatedQueryCount: Int
    let excludedVisualQueryCount: Int
    let independentJudgmentsPerQuery: Int
    let recallAt1: Double
    let recallAt5: Double
    let recallAt10: Double
    let meanReciprocalRank: Double
    let ndcgAt10: Double
    let noResultPrecision: Double
    let p50LatencyMilliseconds: Double
    let p95LatencyMilliseconds: Double
    let p99LatencyMilliseconds: Double
    let forbiddenResultCount: Int
    let labelsEditedAfterFreeze: Bool
    let diagnostics: [RetrievalDiagnostic]
}
