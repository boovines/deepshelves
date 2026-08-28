import CryptoKit
import GRDB
import MemoryContracts
import MemorySearch
import XCTest

@testable import MemoryStore

final class VisualSearchEngineTests: XCTestCase {
    func testFrozenVisualJudgmentsMeetRecallAt10ThroughFullEngine() async throws {
        let fixtureURL = repositoryRoot.appending(path: "Fixtures/LM038/retrieval-judgments.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        XCTAssertEqual(
            Data(SHA256.hash(data: fixtureData)).map { String(format: "%02x", $0) }.joined(),
            "640abc4d73f66c9555cb54df277b0963eeae02cd80651f7174d6bba238e02912"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        let records = try XCTUnwrap(object["queries"] as? [[String: Any]])
            .filter { $0["category"] as? String == "visualSemantic" }
            .sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        XCTAssertEqual(records.count, 25)

        let fixture = try VisualSearchFixture(makeEngine: false)
        defer { fixture.remove() }
        var queryVectors: [String: [Float]] = [:]
        var relevantByQuery: [String: Set<UUID>] = [:]
        for (index, record) in records.enumerated() {
            let query = try XCTUnwrap(record["query"] as? String)
            let judgments = try XCTUnwrap(record["judgments"] as? [[String: Any]])
            let relevance = try XCTUnwrap(judgments.first?["relevance"] as? [[String: Any]])
            let relevant = Set(
                try relevance.map { item in
                    let encoded = try XCTUnwrap(item["frameID"] as? String)
                    return try XCTUnwrap(UUID(uuidString: encoded))
                })
            XCTAssertFalse(relevant.isEmpty)
            let vector = fixture.unit(index)
            queryVectors[query] = vector
            relevantByQuery[query] = relevant
            for (offset, frameID) in relevant.enumerated() {
                _ = try fixture.addFrame(
                    suffix: 1_000 + index * 10 + offset,
                    frameID: frameID,
                    vector: vector
                )
            }
        }
        let frozenQueryVectors = queryVectors
        let embedder = try VisualQueryEmbeddingProvider(
            modelHash: fixture.model.modelHash,
            dimension: fixture.model.dimension
        ) { query in
            guard let vector = frozenQueryVectors[query] else {
                throw VisualSearchError.invalidEmbedding
            }
            return vector
        }
        let engine = try fixture.makeEngine(embedder: embedder)
        let policy = try fixture.policy()
        var hits = 0
        for record in records {
            let query = try XCTUnwrap(record["query"] as? String)
            let page = try await engine.search(fixture.request(query: query, policy: policy))
            let returned = Set(page.results.prefix(10).map(\.frameID))
            if !returned.isDisjoint(with: try XCTUnwrap(relevantByQuery[query])) {
                hits += 1
            }
            let forbidden = Set(
                try (record["forbiddenFrameIDs"] as? [String] ?? []).map {
                    try XCTUnwrap(UUID(uuidString: $0))
                })
            XCTAssertTrue(returned.isDisjoint(with: forbidden))
        }
        let recallAt10 = Double(hits) / Double(records.count)
        print("LM053_VISUAL_RECALL_AT_10 \(recallAt10)")
        XCTAssertGreaterThanOrEqual(recallAt10, 0.75)
    }

    func testVisualOnlySearchRanksAndLabelsSourceEvidence() async throws {
        let fixture = try VisualSearchFixture()
        defer { fixture.remove() }
        let best = try fixture.addFrame(suffix: 1, vector: fixture.unit(0))
        let second = try fixture.addFrame(
            suffix: 2, vector: fixture.normalized([0.8, 0.6]))
        _ = try fixture.addFrame(suffix: 3, vector: fixture.unit(1))

        let page = try await fixture.engine.search(
            fixture.request(policy: fixture.policy(allowImageResources: true)))

        XCTAssertEqual(page.results.map(\.frameID), [best, second, fixture.id(3)])
        XCTAssertEqual(page.results.map(\.visualRank), [1, 2, 3])
        XCTAssertTrue(page.results.allSatisfy { $0.textRank == nil })
        XCTAssertTrue(
            page.results.allSatisfy { result in
                result.evidence == [
                    SearchEvidence(
                        source: .visual,
                        matchedText: nil,
                        score: result.fusedScore
                    )
                ]
            })
        guard case .archiveRelativePath = page.results[0].mediaLocator else {
            return XCTFail("explicitly authorized local UI search should receive archive locators")
        }
        XCTAssertNotNil(page.results[0].thumbnailLocator)
    }

    func testPolicyAndRequestFiltersApplyBeforeVisualProjection() async throws {
        let fixture = try VisualSearchFixture()
        defer { fixture.remove() }
        let allowed = try fixture.addFrame(
            suffix: 10,
            capturedAt: fixture.date("2026-08-05T10:00:00.000Z"),
            bundleID: "com.example.editor",
            host: "docs.example.com",
            vector: fixture.unit(0)
        )
        _ = try fixture.addFrame(
            suffix: 11,
            capturedAt: fixture.date("2026-08-05T10:00:00.000Z"),
            bundleID: "com.example.secret",
            host: "docs.example.com",
            vector: fixture.unit(0)
        )
        _ = try fixture.addFrame(
            suffix: 12,
            capturedAt: fixture.date("2026-08-05T10:00:00.000Z"),
            bundleID: "com.example.editor",
            host: "secret.example.com",
            vector: fixture.unit(0)
        )
        _ = try fixture.addFrame(
            suffix: 13,
            capturedAt: fixture.date("2026-08-20T10:00:00.000Z"),
            bundleID: "com.example.editor",
            host: "docs.example.com",
            vector: fixture.unit(0)
        )
        let policy = try fixture.policy(
            allowedBundleIDs: ["com.example.editor"],
            allowedHosts: ["docs.example.com"]
        )
        let request = try fixture.request(
            interval: DateInterval(
                start: fixture.date("2026-08-05T00:00:00.000Z"),
                end: fixture.date("2026-08-06T00:00:00.000Z")
            ),
            bundleIDs: ["com.example.editor"],
            hosts: ["docs.example.com"],
            policy: policy
        )

        let page = try await fixture.engine.search(request)

        XCTAssertEqual(page.results.map(\.frameID), [allowed])
        XCTAssertEqual(page.results[0].foreground.bundleID, "com.example.editor")
        XCTAssertEqual(page.results[0].browser?.origin.host, "docs.example.com")
    }

    func testHostPolicyAllowsNonBrowserButRequestedHostNarrowsToBrowser() async throws {
        let fixture = try VisualSearchFixture()
        defer { fixture.remove() }
        let desktop = try fixture.addFrame(suffix: 20, host: nil, vector: fixture.unit(0))
        let browser = try fixture.addFrame(
            suffix: 21, host: "docs.example.com", vector: fixture.unit(0))
        _ = try fixture.addFrame(
            suffix: 22, host: "blocked.example.com", vector: fixture.unit(0))
        let policy = try fixture.policy(allowedHosts: ["docs.example.com"])

        let policyPage = try await fixture.engine.search(fixture.request(policy: policy))
        XCTAssertEqual(Set(policyPage.results.map(\.frameID)), Set([desktop, browser]))

        let requestedPage = try await fixture.engine.search(
            fixture.request(hosts: ["docs.example.com"], policy: policy))
        XCTAssertEqual(requestedPage.results.map(\.frameID), [browser])
    }

    func testProjectionRevalidatesSuppressionAfterEmbedding() async throws {
        let fixture = try VisualSearchFixture(makeEngine: false)
        defer { fixture.remove() }
        let frameID = try fixture.addFrame(suffix: 30, vector: fixture.unit(0))
        let embedder = try VisualQueryEmbeddingProvider(
            modelHash: fixture.model.modelHash,
            dimension: fixture.model.dimension
        ) { [fixture] _ in
            try fixture.suppress(frameID)
            return fixture.unit(0)
        }
        let engine = try fixture.makeEngine(embedder: embedder)

        let page = try await engine.search(fixture.request(policy: fixture.policy()))

        XCTAssertTrue(page.results.isEmpty)
    }

    func testImageResourcesAreRedactedUnlessPolicyExplicitlyAllowsThem() async throws {
        let fixture = try VisualSearchFixture()
        defer { fixture.remove() }
        _ = try fixture.addFrame(suffix: 40, vector: fixture.unit(0))

        let page = try await fixture.engine.search(
            fixture.request(policy: fixture.policy(allowImageResources: false)))

        XCTAssertNil(page.results[0].thumbnailLocator)
        guard case .opaqueResourceID(let identifier) = page.results[0].mediaLocator else {
            return XCTFail("policy without image access must not disclose an archive path")
        }
        XCTAssertTrue(identifier.hasPrefix("visual-redacted-"))
    }

    func testMalformedForegroundProjectionFailsClosed() async throws {
        let fixture = try VisualSearchFixture()
        defer { fixture.remove() }
        let frameID = try fixture.addFrame(suffix: 45, vector: fixture.unit(0))
        try fixture.removeWindowBounds(frameID)

        do {
            _ = try await fixture.engine.search(
                fixture.request(policy: fixture.policy()))
            XCTFail("malformed canonical foreground context must not produce a result")
        } catch {
            XCTAssertEqual(error as? ArchiveVisualSearchStoreError, .invalidProjection)
        }
    }

    func testEmptyScopeExpiryCancellationAndInvalidEmbeddingFailClosed() async throws {
        let probe = EmbeddingProbe(vector: [1] + [Float](repeating: 0, count: 511))
        let fixture = try VisualSearchFixture(makeEngine: false)
        defer { fixture.remove() }
        _ = try fixture.addFrame(suffix: 50, vector: fixture.unit(0))
        let embedder = try VisualQueryEmbeddingProvider(
            modelHash: fixture.model.modelHash,
            dimension: fixture.model.dimension
        ) { query in
            try await probe.embed(query)
        }
        let engine = try fixture.makeEngine(embedder: embedder)
        let empty = try await engine.search(
            fixture.request(policy: fixture.policy(allowedBundleIDs: [])))
        XCTAssertTrue(empty.results.isEmpty)
        let countAfterEmpty = await probe.count
        XCTAssertEqual(countAfterEmpty, 0)

        let expiredEngine = try fixture.makeEngine(
            embedder: embedder,
            now: { fixture.date("2026-08-11T00:00:00.000Z") }
        )
        await assertVisualError(
            try await expiredEngine.search(fixture.request(policy: fixture.policy())),
            expected: .expiredAccessPolicy
        )
        let countAfterExpiry = await probe.count
        XCTAssertEqual(countAfterExpiry, 0)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.search(fixture.request(policy: fixture.policy()))
        }
        do {
            _ = try await task.value
            XCTFail("cancelled visual request must fail")
        } catch is CancellationError {
        }

        let invalidEmbedder = try VisualQueryEmbeddingProvider(
            modelHash: fixture.model.modelHash,
            dimension: fixture.model.dimension
        ) { _ in [Float](repeating: 0, count: 512) }
        let invalidEngine = try fixture.makeEngine(embedder: invalidEmbedder)
        await assertVisualError(
            try await invalidEngine.search(fixture.request(policy: fixture.policy())),
            expected: .invalidEmbedding
        )
    }

    func testSharedRouterPreservesLexicalFallbackAndSelectsVisualMode() async throws {
        let lexical = RecordingSearchEngine(marker: "lexical")
        let visual = RecordingSearchEngine(marker: "visual")
        let router = LocalSearchEngine(lexical: lexical, visual: visual)
        let fixture = try VisualSearchFixture(makeEngine: false)
        defer { fixture.remove() }
        let policy = try fixture.policy()

        _ = try await router.search(fixture.request(mode: .textOnly, policy: policy))
        _ = try await router.search(fixture.request(mode: .hybrid, policy: policy))
        _ = try await router.search(fixture.request(mode: .visualOnly, policy: policy))

        let lexicalModes = await lexical.modes
        let visualModes = await visual.modes
        XCTAssertEqual(lexicalModes, [.textOnly, .hybrid])
        XCTAssertEqual(visualModes, [.visualOnly])
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private actor EmbeddingProbe {
    private(set) var count = 0
    let vector: [Float]

    init(vector: [Float]) { self.vector = vector }

    func embed(_ query: String) throws -> [Float] {
        count += 1
        return vector
    }
}

private actor RecordingSearchEngine: SearchEngine {
    let marker: String
    private(set) var modes: [SearchMode] = []

    init(marker: String) { self.marker = marker }

    func search(_ request: SearchRequest) async throws -> SearchPage {
        modes.append(request.mode)
        return try SearchPage(results: [], nextCursor: nil)
    }
}

private final class VisualSearchFixture: @unchecked Sendable {
    let root: URL
    let database: ArchiveDatabase
    let jobs: ArchiveEnrichmentJobStore
    let vectors: ArchiveVectorStore
    let model: ArchiveVectorModelIdentity
    private(set) var engine: VisualSearchEngine!
    private let now = VisualSearchFixture.parse("2026-08-05T12:00:00.000Z")
    private var sequence = 0

    init(makeEngine: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "lm053-visual-\(UUID().uuidString)", directoryHint: .isDirectory)
        database = try ArchiveDatabase(
            applicationSupportDirectory: root,
            encryptionKey: Data(repeating: 0x53, count: 32)
        )
        jobs = try ArchiveEnrichmentJobStore(database: database)
        vectors = try ArchiveVectorStore(database: database)
        model = try ArchiveVectorModelIdentity(
            modelHash: Data(repeating: 0x53, count: 32),
            jobVersion: "lm053-image-v1",
            producerName: "lm053-visual",
            producerSemanticVersion: "1.0.0+image-v1",
            preprocessingVersion: "lm053-raster-v1",
            dimension: 512
        )
        if makeEngine {
            engine = try self.makeEngine()
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func makeEngine(
        embedder: VisualQueryEmbeddingProvider? = nil,
        now: (@Sendable () -> Date)? = nil
    ) throws -> VisualSearchEngine {
        let provider =
            try embedder
            ?? VisualQueryEmbeddingProvider(
                modelHash: model.modelHash,
                dimension: model.dimension,
                operation: { [self] _ in unit(0) }
            )
        return try VisualSearchEngine(
            database: database,
            model: model,
            embedder: provider,
            now: now ?? { [self] in self.now }
        )
    }

    func addFrame(
        suffix: Int,
        frameID: UUID? = nil,
        capturedAt: Date? = nil,
        bundleID: String = "com.example.editor",
        appName: String = "Editor",
        host: String? = nil,
        vector: [Float]
    ) throws -> UUID {
        sequence += 1
        let frameID = frameID ?? id(suffix)
        let epochID = UUID()
        let chunkID = UUID()
        let thumbnailHash = Data(repeating: UInt8(truncatingIfNeeded: suffix), count: 32)
        let frame = frameID.uuidString.lowercased()
        let chunk = chunkID.uuidString.lowercased()
        let epoch = epochID.uuidString.lowercased()
        let mediaPath = "media/2026/08/05/\(chunk)/frames/\(frame).heic"
        let thumbnailPath = "thumbnails/2026/08/05/\(frame).heic"
        let browserValues: [DatabaseValueConvertible?]
        if let host {
            browserValues = ["chrome", "https", host, "/fixture"]
        } else {
            browserValues = [nil, nil, nil, nil]
        }
        try database.atomicWrite { database in
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES (?, ?, 42, ?, '2026-08-05T00:00:00.000Z',
                              '2026-08-05T00:00:01.000Z', 'heicKeyframes', 256, 256,
                              1, 128, ?, 'ready')
                    """,
                arguments: [
                    chunk, epoch, "media/2026/08/05/\(chunk)/manifest.json",
                    String(repeating: "b", count: 64),
                ]
            )
            var arguments: [DatabaseValueConvertible?] = [
                frame,
                Self.encode(capturedAt ?? now),
                sequence * 1_000_000,
                epoch,
                chunk,
                mediaPath,
                String(repeating: "c", count: 64),
                thumbnailPath,
                bundleID,
                appName,
                "Visual Fixture \(suffix)",
            ]
            arguments.append(contentsOf: browserValues)
            try database.execute(
                sql: """
                    INSERT INTO frames(
                        id, captured_at, monotonic_ns, capture_epoch_id,
                        target_window_id, chunk_id, pts_ms, media_path,
                        media_sha256, media_byte_count, thumbnail_path,
                        bundle_id, app_name, window_title,
                        window_x, window_y, window_w, window_h,
                        browser_family, url_scheme, url_host, url_path,
                        capture_reason, is_transition, text_state, visual_state,
                        schema_version, approved_text, policy_generation
                    ) VALUES (?, ?, ?, ?, 42, ?, 500, ?, ?, 128, ?, ?, ?, ?,
                              0.1, 0.1, 0.8, 0.8, ?, ?, ?, ?, 'visualChange', 0,
                              'pending', 'pending', 2, '', 7)
                    """,
                arguments: StatementArguments(arguments)
            )
            try database.execute(
                sql: """
                    INSERT INTO artifacts(
                        id, frame_id, kind, producer_name, producer_version,
                        model_hash, locator_kind, locator_value, content_hash, state
                    ) VALUES (?, ?, 'thumbnail', 'thumbnail', '1.0.0', NULL,
                              'relativeFileOffset', ?, ?, 'ready')
                    """,
                arguments: [
                    UUID().uuidString.lowercased(), frame, thumbnailPath,
                    thumbnailHash.map { String(format: "%02x", $0) }.joined(),
                ]
            )
        }
        let jobID = UUID()
        try jobs.enqueue(
            EnrichmentJobSeed(
                id: jobID,
                parentID: frameID,
                kind: .visualVector,
                priority: 500,
                producerVersion: model.jobVersion
            ))
        let lease = try XCTUnwrap(
            try jobs.leaseNext(
                now: now.addingTimeInterval(Double(sequence)),
                leaseDuration: 120,
                minimumPriority: 0,
                producerVersions: [.visualVector: model.jobVersion]
            ))
        _ = try vectors.stage(
            ArchiveVectorAppendRequest(
                lease: lease,
                captureEpochID: epochID,
                targetWindowID: 42,
                policyGeneration: 7,
                sourceHash: thumbnailHash,
                model: model,
                values: vector
            ))
        try jobs.succeed(lease)
        try vectors.finalize(lease, model: model)
        return frameID
    }

    func suppress(_ frameID: UUID) throws {
        try database.atomicWrite { database in
            try database.execute(
                sql: "UPDATE frames SET visual_state = 'suppressed' WHERE id = ?",
                arguments: [frameID.uuidString.lowercased()]
            )
        }
    }

    func removeWindowBounds(_ frameID: UUID) throws {
        try database.atomicWrite { database in
            try database.execute(
                sql: "UPDATE frames SET window_x = NULL WHERE id = ?",
                arguments: [frameID.uuidString.lowercased()]
            )
        }
    }

    func policy(
        allowedBundleIDs: Set<String> = ["com.example.editor"],
        allowedHosts: Set<String> = [],
        allowImageResources: Bool = true
    ) throws -> AccessPolicy {
        let interval = DateInterval(
            start: date("2026-08-01T00:00:00.000Z"),
            end: date("2026-08-10T00:00:00.000Z")
        )
        return try AccessPolicy(
            id: UUID(),
            name: "LM-053 policy",
            allowedInterval: interval,
            allowedBundleIDs: allowedBundleIDs,
            allowedHosts: allowedHosts,
            allowImageResources: allowImageResources,
            maxResults: 100,
            expiresAt: interval.end.addingTimeInterval(12 * 60 * 60),
            createdByUser: true
        )
    }

    func request(
        query: String = "visual fixture",
        interval: DateInterval? = nil,
        bundleIDs: Set<String> = [],
        hosts: Set<String> = [],
        mode: SearchMode = .visualOnly,
        policy: AccessPolicy
    ) throws -> SearchRequest {
        try SearchRequest(
            query: query,
            interval: interval,
            bundleIDs: bundleIDs,
            hosts: hosts,
            mode: mode,
            pageSize: 10,
            cursor: nil,
            accessPolicy: policy
        )
    }

    func unit(_ index: Int) -> [Float] {
        var result = [Float](repeating: 0, count: 512)
        result[index] = 1
        return result
    }

    func normalized(_ prefix: [Float]) -> [Float] {
        prefix + [Float](repeating: 0, count: 512 - prefix.count)
    }

    func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "53000000-0000-0000-0000-%012d", suffix))!
    }

    func date(_ value: String) -> Date { Self.parse(value) }

    private static func parse(_ value: String) -> Date {
        try! Date(
            value,
            strategy: Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
        )
    }

    private static func encode(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
    }
}

private func assertVisualError<T>(
    _ expression: @autoclosure () async throws -> T,
    expected: VisualSearchError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as VisualSearchError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
