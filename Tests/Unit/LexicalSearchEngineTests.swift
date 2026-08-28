import MemoryContracts
import MemorySearch
import XCTest

@testable import MemoryStore

final class LexicalSearchEngineTests: XCTestCase {
    func testAccessPolicyAndRequestFiltersApplyBeforeCandidates() async throws {
        let fixture = try SearchEngineFixture()
        let allowed = try fixture.addFrame(
            suffix: 1,
            capturedAt: fixture.date("2026-08-05T12:00:00Z"),
            bundleID: "com.example.editor",
            appName: "Editor",
            host: "docs.example.com",
            text: "policy needle"
        )
        _ = try fixture.addFrame(
            suffix: 2,
            capturedAt: fixture.date("2026-08-05T12:00:00Z"),
            bundleID: "com.example.other",
            appName: "Other",
            host: "docs.example.com",
            text: "policy needle"
        )
        _ = try fixture.addFrame(
            suffix: 3,
            capturedAt: fixture.date("2026-08-05T12:00:00Z"),
            bundleID: "com.example.editor",
            appName: "Editor",
            host: "secret.example.com",
            text: "policy needle"
        )
        _ = try fixture.addFrame(
            suffix: 4,
            capturedAt: fixture.date("2026-08-12T12:00:00Z"),
            bundleID: "com.example.editor",
            appName: "Editor",
            host: "docs.example.com",
            text: "policy needle"
        )
        let policy = try fixture.policy(
            allowedBundleIDs: ["com.example.editor"],
            allowedHosts: ["docs.example.com"]
        )
        let request = try fixture.request(
            query: "needle",
            bundleIDs: ["com.example.editor"],
            hosts: ["docs.example.com"],
            policy: policy
        )

        let page = try await fixture.engine.search(request)

        XCTAssertEqual(page.results.map(\.frameID), [allowed])
        XCTAssertEqual(page.results.first?.foreground.bundleID, "com.example.editor")
        XCTAssertEqual(page.results.first?.browser?.origin.host, "docs.example.com")
    }

    func testWeightedBM25AndExactMetadataBoostsHaveStableOrdering() async throws {
        let fixture = try SearchEngineFixture()
        let title = try fixture.addFrame(
            suffix: 10,
            windowTitle: "Roadmap",
            text: "general planning"
        )
        let focused = try fixture.addFrame(
            suffix: 11,
            windowTitle: "Planning",
            text: "roadmap"
        )
        let policy = try fixture.policy()

        let page = try await fixture.engine.search(
            fixture.request(query: "roadmap", policy: policy)
        )

        XCTAssertEqual(page.results.map(\.frameID), [title, focused])
        XCTAssertGreaterThan(
            try XCTUnwrap(page.results.first?.fusedScore),
            try XCTUnwrap(page.results.last?.fusedScore)
        )
        XCTAssertEqual(page.results.first?.evidence.first?.source, .title)
        XCTAssertEqual(page.results.map(\.textRank), [1, 2])
    }

    func testEvidencePreservesEachMatchedSourceWithoutGeneratedClaims() async throws {
        let fixture = try SearchEngineFixture()
        let frameID = try fixture.addFrame(
            suffix: 20,
            appName: "Evidence App",
            windowTitle: "Title token",
            host: "evidence.example.com",
            path: "/url-token",
            spans: [
                fixture.span(suffix: 201, source: .accessibility, text: "AX token"),
                fixture.span(suffix: 202, source: .visionOCR, text: "OCR token"),
            ],
            transcriptSpans: [
                fixture.span(suffix: 203, source: .transcript, text: "Transcript token")
            ]
        )
        let policy = try fixture.policy(allowedHosts: ["evidence.example.com"])
        let expectations: [(String, SearchEvidenceSource)] = [
            ("AX", .accessibility),
            ("OCR", .visionOCR),
            ("Title", .title),
            ("Evidence", .application),
            ("url", .url),
            ("Transcript", .transcript),
        ]

        for (query, source) in expectations {
            let page = try await fixture.engine.search(
                fixture.request(query: query, policy: policy)
            )
            XCTAssertEqual(page.results.map(\.frameID), [frameID], query)
            let evidence = try XCTUnwrap(
                page.results[0].evidence.first(where: { $0.source == source }),
                query
            )
            XCTAssertNotNil(evidence.matchedText)
            XCTAssertFalse(evidence.matchedText?.contains("summary") == true)
        }
    }

    func testKeysetPaginationReturnsEveryEqualScoreExactlyOnceInStableUUIDOrder() async throws {
        let fixture = try SearchEngineFixture()
        var expected: [UUID] = []
        for suffix in 30..<80 {
            expected.append(
                try fixture.addFrame(
                    suffix: suffix,
                    capturedAt: fixture.date("2026-08-05T12:00:00Z"),
                    windowTitle: "Equal",
                    text: "stable pagination"
                )
            )
        }
        expected.sort { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        let policy = try fixture.policy(maxResults: 100)
        var cursor: SearchCursor?
        var actual: [UUID] = []

        repeat {
            let request = try fixture.request(
                query: "stable",
                pageSize: 7,
                cursor: cursor,
                policy: policy
            )
            let page = try await fixture.engine.search(request)
            actual.append(contentsOf: page.results.map(\.frameID))
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(Set(actual).count, expected.count)
    }

    func testCursorRejectsTamperDifferentQueryAndDifferentSigningKey() async throws {
        let fixture = try SearchEngineFixture()
        for suffix in 90..<93 {
            _ = try fixture.addFrame(suffix: suffix, text: "cursor evidence")
        }
        let policy = try fixture.policy()
        let first = try await fixture.engine.search(
            fixture.request(query: "cursor", pageSize: 1, policy: policy)
        )
        let cursor = try XCTUnwrap(first.nextCursor)
        let changedLast = cursor.token.last == "A" ? "B" : "A"
        let tampered = try SearchCursor(token: String(cursor.token.dropLast()) + changedLast)

        await assertThrowsErrorAsync(
            try await fixture.engine.search(
                fixture.request(query: "cursor", pageSize: 1, cursor: tampered, policy: policy)
            ),
            expected: .invalidCursor
        )
        await assertThrowsErrorAsync(
            try await fixture.engine.search(
                fixture.request(query: "different", pageSize: 1, cursor: cursor, policy: policy)
            ),
            expected: .cursorQueryMismatch
        )
        let otherEngine = try LexicalSearchEngine(
            database: fixture.archive,
            cursorSigningKey: Data(repeating: 0x77, count: 32),
            now: { fixture.date("2026-08-05T12:00:00Z") }
        )
        await assertThrowsErrorAsync(
            try await otherEngine.search(
                fixture.request(query: "cursor", pageSize: 1, cursor: cursor, policy: policy)
            ),
            expected: .invalidCursor
        )
    }

    func testPolicyMaximumResultsCapsTheCompletePaginationChain() async throws {
        let fixture = try SearchEngineFixture()
        for suffix in 94..<104 {
            _ = try fixture.addFrame(suffix: suffix, text: "bounded evidence")
        }
        let policy = try fixture.policy(maxResults: 5)
        var cursor: SearchCursor?
        var collected: [UUID] = []

        repeat {
            let page = try await fixture.engine.search(
                fixture.request(
                    query: "bounded",
                    pageSize: 2,
                    cursor: cursor,
                    policy: policy
                )
            )
            collected.append(contentsOf: page.results.map(\.frameID))
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(collected.count, 5)
        XCTAssertEqual(Set(collected).count, 5)
    }

    func testExpiredVisualOnlyEmptyAllowlistAndCancelledRequestsFailClosed() async throws {
        let fixture = try SearchEngineFixture()
        _ = try fixture.addFrame(suffix: 100, text: "private sentinel")
        let emptyPolicy = try fixture.policy(allowedBundleIDs: [], allowedHosts: [])
        let empty = try await fixture.engine.search(
            fixture.request(query: "sentinel", policy: emptyPolicy)
        )
        XCTAssertTrue(empty.results.isEmpty)

        let policy = try fixture.policy()
        await assertThrowsErrorAsync(
            try await fixture.engine.search(
                fixture.request(query: "sentinel", mode: .visualOnly, policy: policy)
            ),
            expected: .visualSearchUnavailable
        )

        let expiredPolicy = try fixture.policy(
            intervalEnd: fixture.date("2026-08-04T00:00:00Z"),
            expiresAt: fixture.date("2026-08-04T12:00:00Z")
        )
        await assertThrowsErrorAsync(
            try await fixture.engine.search(
                fixture.request(query: "sentinel", policy: expiredPolicy)
            ),
            expected: .expiredAccessPolicy
        )

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.engine.search(
                fixture.request(query: "sentinel", policy: policy)
            )
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testFTSSyntaxLikeInputIsQuotedAsLiteralAndCannotBroadenResults() async throws {
        let fixture = try SearchEngineFixture()
        _ = try fixture.addFrame(suffix: 110, text: "needle public")
        _ = try fixture.addFrame(suffix: 111, text: "private sentinel")
        let policy = try fixture.policy()

        let page = try await fixture.engine.search(
            fixture.request(query: "needle OR private*", policy: policy)
        )

        XCTAssertTrue(page.results.isEmpty)
    }
}

private final class SearchEngineFixture: @unchecked Sendable {
    let archive: ArchiveDatabase
    let store: ArchiveSearchIndexStore
    let engine: LexicalSearchEngine

    init() throws {
        archive = try ArchiveDatabase.deterministicTestStore()
        store = ArchiveSearchIndexStore(database: archive)
        engine = try LexicalSearchEngine(
            database: archive,
            cursorSigningKey: Data(repeating: 0x35, count: 32),
            now: { Self.parseDate("2026-08-05T12:00:00Z") }
        )
    }

    func addFrame(
        suffix: Int,
        capturedAt: Date? = nil,
        bundleID: String = "com.example.editor",
        appName: String = "Editor",
        windowTitle: String = "Fixture Window",
        host: String? = nil,
        path: String? = nil,
        text: String? = nil,
        spans: [TextSpan]? = nil,
        transcriptSpans: [TextSpan] = []
    ) throws -> UUID {
        let frameID = try archive.insertSearchFrameFixtureForTesting(
            suffix: suffix,
            capturedAt: capturedAt ?? date("2026-08-05T12:00:00Z"),
            bundleIdentifier: bundleID,
            appName: appName,
            windowTitle: windowTitle,
            host: host,
            path: path
        )
        let approvedSpans =
            try spans ?? [
                span(
                    suffix: suffix * 1_000,
                    frameID: frameID,
                    source: .accessibility,
                    text: text ?? "fixture evidence"
                )
            ]
        let reboundTranscripts = try transcriptSpans.map {
            try TextSpan(
                id: $0.id,
                frameID: frameID,
                source: $0.source,
                text: $0.text,
                bounds: $0.bounds,
                confidence: $0.confidence,
                languageCode: $0.languageCode,
                sensitivity: $0.sensitivity
            )
        }
        let reboundApproved = try approvedSpans.map {
            try TextSpan(
                id: $0.id,
                frameID: frameID,
                source: $0.source,
                text: $0.text,
                bounds: $0.bounds,
                confidence: $0.confidence,
                languageCode: $0.languageCode,
                sensitivity: $0.sensitivity
            )
        }
        try store.publish(
            ArchiveMergedTextSeed(
                frameID: frameID,
                approvedSpans: reboundApproved,
                transcriptSpans: reboundTranscripts,
                producerVersion: "search-fixture-v1"
            )
        )
        return frameID
    }

    func span(
        suffix: Int,
        frameID: UUID = UUID(uuidString: "37000000-0000-0000-0000-000000000000")!,
        source: TextSource,
        text: String
    ) throws -> TextSpan {
        try TextSpan(
            id: UUID(uuidString: String(format: "37000000-0000-0000-0000-%012d", suffix))!,
            frameID: frameID,
            source: source,
            text: text,
            bounds: nil,
            confidence: source == .visionOCR ? 0.9 : nil,
            languageCode: source == .visionOCR ? "en" : nil,
            sensitivity: .normal
        )
    }

    func policy(
        allowedBundleIDs: Set<String> = ["com.example.editor"],
        allowedHosts: Set<String> = [],
        intervalEnd: Date? = nil,
        expiresAt: Date? = nil,
        maxResults: Int = 100
    ) throws -> AccessPolicy {
        let end = intervalEnd ?? date("2026-08-10T00:00:00Z")
        return try AccessPolicy(
            id: UUID(uuidString: "37000000-0000-0000-0000-000000000001")!,
            name: "Search fixture",
            allowedInterval: DateInterval(
                start: date("2026-08-01T00:00:00Z"),
                end: end
            ),
            allowedBundleIDs: allowedBundleIDs,
            allowedHosts: allowedHosts,
            maxResults: maxResults,
            expiresAt: expiresAt ?? end.addingTimeInterval(12 * 60 * 60),
            createdByUser: true
        )
    }

    func request(
        query: String,
        interval: DateInterval? = nil,
        bundleIDs: Set<String> = [],
        hosts: Set<String> = [],
        mode: SearchMode = .textOnly,
        pageSize: Int = 100,
        cursor: SearchCursor? = nil,
        policy: AccessPolicy
    ) throws -> SearchRequest {
        try SearchRequest(
            query: query,
            interval: interval,
            bundleIDs: bundleIDs,
            hosts: hosts,
            mode: mode,
            pageSize: pageSize,
            cursor: cursor,
            accessPolicy: policy
        )
    }

    func date(_ value: String) -> Date {
        Self.parseDate(value)
    }

    private static func parseDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    expected: LexicalSearchError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as LexicalSearchError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
