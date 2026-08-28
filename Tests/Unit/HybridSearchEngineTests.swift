import CryptoKit
import Foundation
import MemoryContracts
import XCTest

@testable import MemorySearch
@testable import MemoryStore

final class HybridSearchEngineTests: XCTestCase {
    func testHandComputedRRFBoostDedupGroupingAndStableTieFixture() throws {
        let fixtureURL = repositoryRoot.appending(path: "Fixtures/LM054/fusion-cases.json")
        let data = try Data(contentsOf: fixtureURL)
        XCTAssertEqual(
            Self.hex(SHA256.hash(data: data)),
            "de9b57ce6ccbde66e7f69c063e73b33e704ef924b1a94202398b687210eddb1f"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["reciprocalRankK"] as? Int, 60)

        let ranker = HybridRanker(configuration: HybridFusionConfiguration())
        let a = try result(
            "a", capturedAt: 1_100, title: "Quarterly Review", textRank: 1)
        let b = try result(
            "b", capturedAt: 1_200, title: "Timeline", textRank: 2)
        let c = try result(
            "c", capturedAt: 1_300, title: "Canvas", textRank: 3)
        let visualC = try result(
            "c", capturedAt: 1_300, title: "Canvas", visualRank: 1)
        let visualB = try result(
            "b", capturedAt: 1_200, title: "Timeline", visualRank: 2)
        let d = try result(
            "d", capturedAt: 1_220, title: "Timeline", visualRank: 3)

        let fused = try ranker.fuse(
            query: "Quarterly Review",
            lexical: [a, b, c],
            visual: [visualC, visualB, d],
            allowImageResources: false
        )
        let scores = Dictionary(
            uniqueKeysWithValues: fused.map { (key($0.frameID), $0.fusedScore) })
        XCTAssertEqual(try XCTUnwrap(scores["a"]), 1 / 61.0 + 0.020, accuracy: 1e-15)
        XCTAssertEqual(try XCTUnwrap(scores["b"]), 2 / 62.0, accuracy: 1e-15)
        XCTAssertEqual(try XCTUnwrap(scores["c"]), 1 / 63.0 + 1 / 61.0, accuracy: 1e-15)
        XCTAssertEqual(try XCTUnwrap(scores["d"]), 1 / 63.0, accuracy: 1e-15)
        XCTAssertEqual(fused.first(where: { key($0.frameID) == "b" })?.evidence.count, 2)
        XCTAssertTrue(fused.allSatisfy { $0.thumbnailLocator == nil })
        XCTAssertTrue(
            fused.allSatisfy {
                if case .opaqueResourceID = $0.mediaLocator { return true }
                return false
            })

        let epochB = uuid("epoch-b")
        let metadata: [UUID: HybridGroupingMetadata] = [
            a.frameID: grouping(a, epoch: uuid("epoch-a"), reason: "visualChange"),
            b.frameID: grouping(
                b, epoch: epochB, reason: "visualChange", text: "alpha beta gamma"),
            c.frameID: grouping(c, epoch: uuid("epoch-c"), reason: "visualChange"),
            d.frameID: grouping(
                d, epoch: epochB, reason: "staticHeartbeat", text: "different words"),
        ]
        let grouped = try ranker.group(fused, metadata: metadata)
        XCTAssertEqual(grouped.map { key($0.frameID) }, ["a", "c", "b"])
        print("LM054_HAND_FUSION a,c,b")

        let e = try result("e", capturedAt: 1_400, title: "Editor", textRank: 1)
        let f = try result("f", capturedAt: 1_400, title: "Viewer", visualRank: 1)
        let tie = try ranker.fuse(
            query: "shape",
            lexical: [e],
            visual: [f],
            allowImageResources: true
        )
        XCTAssertEqual(tie.map { key($0.frameID) }, ["e", "f"])
        XCTAssertEqual(tie[0].fusedScore, tie[1].fusedScore, accuracy: 1e-15)

        let permuted = try ranker.fuse(
            query: "Quarterly Review",
            lexical: [c, b, a],
            visual: [d, visualB, visualC],
            allowImageResources: false
        )
        XCTAssertEqual(permuted.map(\.frameID), fused.map(\.frameID))
        XCTAssertEqual(permuted.map(\.fusedScore), fused.map(\.fusedScore))
    }

    func testGroupingRequiresSameContextGapAndDurableSimilarityEvidence() throws {
        let ranker = HybridRanker(configuration: HybridFusionConfiguration())
        let first = try result("g", capturedAt: 1_100, title: "Document", textRank: 1)
        let similar = try result("h", capturedAt: 1_125, title: "Document", textRank: 2)
        let changed = try result("i", capturedAt: 1_126, title: "Document", textRank: 3)
        let late = try result("j", capturedAt: 1_200, title: "Document", textRank: 4)
        let otherWindow = try result("k", capturedAt: 1_110, title: "Other", textRank: 5)
        let fused = try ranker.fuse(
            query: "not exact",
            lexical: [first, similar, changed, late, otherWindow],
            visual: [],
            allowImageResources: true
        )
        let epoch = uuid("group-epoch")
        let metadata = Dictionary(
            uniqueKeysWithValues: [
                (first, "alpha beta gamma delta"),
                (similar, "alpha beta gamma delta epsilon"),
                (changed, "one two three four"),
                (late, "alpha beta gamma delta"),
                (otherWindow, "alpha beta gamma delta"),
            ].map { item in
                (
                    item.0.frameID,
                    grouping(item.0, epoch: epoch, reason: "visualChange", text: item.1)
                )
            }
        )

        let grouped = try ranker.group(fused, metadata: metadata)

        XCTAssertEqual(Set(grouped.map { key($0.frameID) }), Set(["g", "i", "j", "k"]))

        let exactHash = Data(repeating: 0x54, count: 32)
        var exactMetadata = metadata
        exactMetadata[first.frameID] = grouping(
            first, epoch: epoch, reason: "visualChange", hash: exactHash)
        exactMetadata[similar.frameID] = grouping(
            similar, epoch: uuid("different-epoch"), reason: "visualChange", hash: exactHash)
        let exactGrouped = try ranker.group(fused, metadata: exactMetadata)
        XCTAssertFalse(exactGrouped.contains(where: { key($0.frameID) == "h" }))
        XCTAssertEqual(exactGrouped.first.map { key($0.frameID) }, "g")
    }

    func testExactIdentifierTitleApplicationAndURLBoostsAreFixedAndAdditive() throws {
        let ranker = HybridRanker(configuration: HybridFusionConfiguration())
        let frame = try metadataResult(
            suffix: 51,
            title: "Quarterly Review",
            applicationName: "Editor",
            bundleID: "com.example.editor",
            host: "docs.example.com",
            path: "/review"
        )
        let base = 1 / 61.0
        let cases: [(String, Double)] = [
            (frame.frameID.uuidString.lowercased(), 0.025),
            ("quarterly review", 0.020),
            ("editor", 0.015),
            ("com.example.editor", 0.015),
            ("docs.example.com", 0.010),
            ("https://docs.example.com/review", 0.010),
            ("unrelated", 0),
        ]
        for (query, expectedBoost) in cases {
            let fused = try ranker.fuse(
                query: query,
                lexical: [frame],
                visual: [],
                allowImageResources: false
            )
            XCTAssertEqual(fused[0].fusedScore, base + expectedBoost, accuracy: 1e-15)
        }
    }

    func testSignedHybridPaginationRecomputesComponentsWithoutSkipOrDuplicate() async throws {
        let lexicalResults = try (1...25).map { index in
            try result(index, textRank: index, componentScore: Double(100 - index))
        }
        let visualResults = try (1...25).map { index in
            try result(index, visualRank: index, componentScore: Double(100 - index))
        }
        let lexical = PageSearchEngine(
            page: try SearchPage(results: lexicalResults, nextCursor: nil))
        let visual = PageSearchEngine(page: try SearchPage(results: visualResults, nextCursor: nil))
        let engine = try HybridSearchEngine(
            lexical: lexical,
            visual: visual,
            cursorSigningKey: Data(repeating: 0x54, count: 32),
            now: { Date(timeIntervalSince1970: 1_500) }
        )
        let policy = try policy(maxResults: 20)
        var cursor: SearchCursor?
        var returned: [UUID] = []
        repeat {
            let page = try await engine.search(
                request(query: "ranked", pageSize: 7, cursor: cursor, policy: policy))
            returned.append(contentsOf: page.results.map(\.frameID))
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(returned, (1...20).map(id))
        XCTAssertEqual(Set(returned).count, 20)
        print("LM054_HYBRID_PAGINATION 20")
        let lexicalRequests = await lexical.requests
        let visualRequests = await visual.requests
        XCTAssertEqual(lexicalRequests.count, 3)
        XCTAssertEqual(visualRequests.count, 3)
        XCTAssertTrue(lexicalRequests.allSatisfy { $0.mode == .textOnly && $0.cursor == nil })
        XCTAssertTrue(visualRequests.allSatisfy { $0.mode == .visualOnly && $0.cursor == nil })
        XCTAssertTrue((lexicalRequests + visualRequests).allSatisfy { $0.pageSize == 20 })

        let first = try await engine.search(
            request(query: "ranked", pageSize: 7, cursor: nil, policy: policy))
        let validCursor = try XCTUnwrap(first.nextCursor)
        await assertHybridError(
            try await engine.search(
                request(query: "changed", pageSize: 7, cursor: validCursor, policy: policy)),
            expected: .cursorQueryMismatch
        )
        let smallerPage = try await engine.search(
            request(query: "ranked", pageSize: 3, cursor: validCursor, policy: policy))
        XCTAssertEqual(smallerPage.results.map(\.frameID), (8...10).map(id))
        await assertHybridError(
            try await engine.search(
                request(
                    query: "ranked",
                    pageSize: 7,
                    cursor: validCursor,
                    policy: self.policy(maxResults: 19)
                )),
            expected: .cursorQueryMismatch
        )
        let changedLast = validCursor.token.last == "a" ? "b" : "a"
        let tampered = try SearchCursor(token: String(validCursor.token.dropLast()) + changedLast)
        await assertHybridError(
            try await engine.search(
                request(query: "ranked", pageSize: 7, cursor: tampered, policy: policy)),
            expected: .invalidCursor
        )
        let otherKey = try HybridSearchEngine(
            lexical: lexical,
            visual: visual,
            cursorSigningKey: Data(repeating: 0x55, count: 32),
            now: { Date(timeIntervalSince1970: 1_500) }
        )
        await assertHybridError(
            try await otherKey.search(
                request(query: "ranked", pageSize: 7, cursor: validCursor, policy: policy)),
            expected: .invalidCursor
        )
    }

    func testMissingGroupingMetadataRevalidatesAndDropsSuppressedCandidate() async throws {
        let allowed = try result(61, textRank: 1)
        let suppressed = try result(62, textRank: 2)
        let component = PageSearchEngine(
            page: try SearchPage(results: [allowed, suppressed], nextCursor: nil))
        let allowedMetadata = grouping(
            allowed, epoch: uuid("allowed"), reason: "visualChange")
        let provider = HybridGroupingMetadataProvider { frameIDs in
            XCTAssertEqual(Set(frameIDs), Set([allowed.frameID, suppressed.frameID]))
            return [allowed.frameID: allowedMetadata]
        }
        let engine = try HybridSearchEngine(
            lexical: component,
            visual: nil,
            cursorSigningKey: Data(repeating: 0x54, count: 32),
            groupingProvider: provider,
            now: { Date(timeIntervalSince1970: 1_500) }
        )

        let page = try await engine.search(
            request(query: "allowed", pageSize: 10, cursor: nil, policy: policy()))

        XCTAssertEqual(page.results.map(\.frameID), [allowed.frameID])
    }

    func testModelUnavailableFallsBackToLexicalButIntegrityFailurePropagates() async throws {
        let lexicalResult = try result(70, textRank: 1)
        let lexical = PageSearchEngine(
            page: try SearchPage(results: [lexicalResult], nextCursor: nil))
        let unavailable = PageSearchEngine(
            page: try SearchPage(results: [], nextCursor: nil),
            failure: .modelUnavailable
        )
        let engine = try HybridSearchEngine(
            lexical: lexical,
            visual: unavailable,
            cursorSigningKey: Data(repeating: 0x54, count: 32),
            now: { Date(timeIntervalSince1970: 1_500) }
        )

        let page = try await engine.search(
            request(query: "fallback", pageSize: 10, cursor: nil, policy: policy()))
        XCTAssertEqual(page.results.map(\.frameID), [lexicalResult.frameID])

        let corrupt = PageSearchEngine(
            page: try SearchPage(results: [], nextCursor: nil),
            failure: .corruptProjection
        )
        let corruptEngine = try HybridSearchEngine(
            lexical: lexical,
            visual: corrupt,
            cursorSigningKey: Data(repeating: 0x54, count: 32),
            now: { Date(timeIntervalSince1970: 1_500) }
        )
        do {
            _ = try await corruptEngine.search(
                request(query: "corrupt", pageSize: 10, cursor: nil, policy: policy()))
            XCTFail("integrity failures must not degrade silently")
        } catch PageSearchFailure.corruptProjection {
        }
    }

    func testArchiveGroupingStoreReturnsOnlyCurrentReadyEvidence() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let ready = try archive.insertSearchFrameFixtureForTesting(suffix: 81)
        let suppressed = try archive.insertSearchFrameFixtureForTesting(suffix: 82)
        let epoch = uuid("archive-epoch")
        try archive.atomicWrite { database in
            for frameID in [ready, suppressed] {
                try database.execute(
                    sql: """
                        UPDATE frames
                        SET capture_epoch_id = ?, media_sha256 = ?, media_path = ?,
                            media_byte_count = 64, policy_generation = 7, schema_version = 2
                        WHERE id = ?
                        """,
                    arguments: [
                        epoch.uuidString.lowercased(), String(repeating: "a", count: 64),
                        "media/fixture/frames/\(frameID.uuidString.lowercased()).heic",
                        frameID.uuidString.lowercased(),
                    ]
                )
            }
            try database.execute(
                sql: "UPDATE frames SET visual_state = 'suppressed' WHERE id = ?",
                arguments: [suppressed.uuidString.lowercased()]
            )
        }
        let store = ArchiveHybridGroupingStore(database: archive)

        let records = try store.records(frameIDs: [ready, suppressed])

        XCTAssertEqual(Set(records.keys), [ready])
        XCTAssertEqual(records[ready]?.captureEpochID, epoch)
        XCTAssertEqual(records[ready]?.mediaSHA256, Data(repeating: 0xaa, count: 32))

    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func grouping(
        _ result: SearchResult,
        epoch: UUID,
        reason: String,
        hash: Data? = nil,
        text: String? = nil
    ) -> HybridGroupingMetadata {
        HybridGroupingMetadata(
            frameID: result.frameID,
            captureEpochID: epoch,
            captureReason: reason,
            mediaSHA256: hash,
            approvedText: text
        )
    }

    private func result(
        _ key: String,
        capturedAt: TimeInterval,
        title: String,
        textRank: Int? = nil,
        visualRank: Int? = nil
    ) throws -> SearchResult {
        try result(
            id(key),
            capturedAt: capturedAt,
            title: title,
            textRank: textRank,
            visualRank: visualRank,
            componentScore: Double(100 - (textRank ?? visualRank ?? 1))
        )
    }

    private func metadataResult(
        suffix: Int,
        title: String,
        applicationName: String,
        bundleID: String,
        host: String,
        path: String
    ) throws -> SearchResult {
        let frameID = id(suffix)
        return try SearchResult(
            frameID: frameID,
            capturedAt: Date(timeIntervalSince1970: 1_100),
            foreground: ForegroundContext(
                bundleID: bundleID,
                applicationName: applicationName,
                processID: nil,
                windowTitle: title,
                windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            ),
            browser: BrowserContext(
                family: .chrome,
                origin: BrowserOrigin(scheme: "https", host: host, path: path),
                isPrivateContext: false
            ),
            thumbnailLocator: nil,
            mediaLocator: .opaqueResourceID("lm054-metadata-\(suffix)"),
            evidence: [SearchEvidence(source: .title, matchedText: title, score: 1)],
            textRank: 1,
            visualRank: nil,
            fusedScore: 1
        )
    }

    private func result(
        _ suffix: Int,
        textRank: Int? = nil,
        visualRank: Int? = nil,
        componentScore: Double? = nil
    ) throws -> SearchResult {
        try result(
            id(suffix),
            capturedAt: TimeInterval(1_100 + suffix),
            title: "Frame \(suffix)",
            textRank: textRank,
            visualRank: visualRank,
            componentScore: componentScore ?? Double(100 - (textRank ?? visualRank ?? 1))
        )
    }

    private func result(
        _ frameID: UUID,
        capturedAt: TimeInterval,
        title: String,
        textRank: Int?,
        visualRank: Int?,
        componentScore: Double
    ) throws -> SearchResult {
        let source: SearchEvidenceSource = visualRank == nil ? .title : .visual
        return try SearchResult(
            frameID: frameID,
            capturedAt: Date(timeIntervalSince1970: capturedAt),
            foreground: ForegroundContext(
                bundleID: "com.example.editor",
                applicationName: "Editor",
                processID: nil,
                windowTitle: title,
                windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            ),
            browser: nil,
            thumbnailLocator: .archiveRelativePath(
                "thumbnails/\(frameID.uuidString.lowercased()).heic"),
            mediaLocator: .archiveRelativePath(
                "media/\(frameID.uuidString.lowercased()).heic"),
            evidence: [
                SearchEvidence(
                    source: source,
                    matchedText: source == .visual ? nil : title,
                    score: componentScore
                )
            ],
            textRank: textRank,
            visualRank: visualRank,
            fusedScore: componentScore
        )
    }

    private func policy(maxResults: Int = 100, allowImageResources: Bool = false) throws
        -> AccessPolicy
    {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        return try AccessPolicy(
            id: UUID(uuidString: "54000000-0000-0000-0000-000000000001")!,
            name: "LM-054 hybrid test",
            allowedInterval: interval,
            allowedBundleIDs: ["com.example.editor"],
            allowedHosts: [],
            allowImageResources: allowImageResources,
            maxResults: maxResults,
            expiresAt: Date(timeIntervalSince1970: 2_060),
            createdByUser: true
        )
    }

    private func request(
        query: String,
        pageSize: Int,
        cursor: SearchCursor?,
        policy: AccessPolicy
    ) throws -> SearchRequest {
        try SearchRequest(
            query: query,
            interval: nil,
            bundleIDs: [],
            hosts: [],
            mode: .hybrid,
            pageSize: pageSize,
            cursor: cursor,
            accessPolicy: policy
        )
    }

    private func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "54000000-0000-0000-0001-%012d", suffix))!
    }

    private func id(_ key: String) -> UUID {
        let scalar = Int(
            key.unicodeScalars.first!.value - Character("a").unicodeScalars.first!.value)
        return id(scalar + 1)
    }

    private func key(_ id: UUID) -> String {
        let suffix = Int(id.uuidString.suffix(12))!
        return String(
            UnicodeScalar(Character("a").unicodeScalars.first!.value + UInt32(suffix - 1))!)
    }

    private func uuid(_ seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class HybridSearchSettlementTests: XCTestCase {
    func testHybridSearchPublishesNoLexicalInterimAndSettlesExactlyOnce() async throws {
        let lexicalResult = try Self.makeResult(91, textRank: 1)
        let visualResult = try Self.makeResult(92, visualRank: 1)
        let lexical = PageSearchEngine(
            page: try SearchPage(results: [lexicalResult], nextCursor: nil))
        let visual = PageSearchEngine(
            page: try SearchPage(results: [visualResult], nextCursor: nil),
            delay: .milliseconds(100)
        )
        let engine = try HybridSearchEngine(
            lexical: lexical,
            visual: visual,
            cursorSigningKey: Data(repeating: 0x54, count: 32),
            now: { Date(timeIntervalSince1970: 1_500) }
        )
        let policy = try Self.makePolicy()
        let model = SearchSessionModel(
            engine: engine,
            debounceDuration: .zero,
            requestBuilder: { query in
                try SearchRequest(
                    query: query,
                    interval: nil,
                    bundleIDs: [],
                    hosts: [],
                    mode: .hybrid,
                    pageSize: 20,
                    cursor: nil,
                    accessPolicy: policy
                )
            }
        )

        model.updateQuery("hybrid")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.phase, SearchSessionPhase.loading(query: "hybrid"))
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.settlementCount, 0)

        await model.waitForCurrentSearch()

        XCTAssertEqual(model.phase, SearchSessionPhase.results(query: "hybrid", count: 2))
        XCTAssertEqual(
            Set(model.results.map { $0.frameID }),
            Set([lexicalResult.frameID, visualResult.frameID]))
        XCTAssertEqual(model.settlementCount, 1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.settlementCount, 1)
    }

    nonisolated private static func makePolicy() throws -> AccessPolicy {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        return try AccessPolicy(
            id: UUID(uuidString: "54000000-0000-0000-0000-000000000091")!,
            name: "LM-054 settlement",
            allowedInterval: interval,
            allowedBundleIDs: ["com.example.editor"],
            allowedHosts: [],
            maxResults: 20,
            expiresAt: Date(timeIntervalSince1970: 2_060),
            createdByUser: true
        )
    }

    nonisolated private static func makeResult(
        _ suffix: Int,
        textRank: Int? = nil,
        visualRank: Int? = nil
    ) throws -> SearchResult {
        let id = UUID(uuidString: String(format: "54000000-0000-0000-0002-%012d", suffix))!
        let source: SearchEvidenceSource = visualRank == nil ? .title : .visual
        return try SearchResult(
            frameID: id,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(1_100 + suffix)),
            foreground: ForegroundContext(
                bundleID: "com.example.editor",
                applicationName: "Editor",
                processID: nil,
                windowTitle: "Settlement \(suffix)",
                windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            ),
            browser: nil,
            thumbnailLocator: nil,
            mediaLocator: .opaqueResourceID("lm054-\(suffix)"),
            evidence: [
                SearchEvidence(
                    source: source,
                    matchedText: source == .visual ? nil : "Settlement \(suffix)",
                    score: 1
                )
            ],
            textRank: textRank,
            visualRank: visualRank,
            fusedScore: 1
        )
    }
}

private enum PageSearchFailure: Error, Sendable {
    case modelUnavailable
    case corruptProjection
}

private actor PageSearchEngine: SearchEngine {
    let page: SearchPage
    let delay: Duration
    let failure: PageSearchFailure?
    private(set) var requests: [SearchRequest] = []

    init(
        page: SearchPage,
        delay: Duration = .zero,
        failure: PageSearchFailure? = nil
    ) {
        self.page = page
        self.delay = delay
        self.failure = failure
    }

    func search(_ request: SearchRequest) async throws -> SearchPage {
        requests.append(request)
        if delay > .zero { try await Task.sleep(for: delay) }
        switch failure {
        case .modelUnavailable: throw VisualSearchError.modelUnavailable
        case .corruptProjection: throw PageSearchFailure.corruptProjection
        case nil: return page
        }
    }
}

private func assertHybridError<T>(
    _ expression: @autoclosure () async throws -> T,
    expected: HybridSearchError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as HybridSearchError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
