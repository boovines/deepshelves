import GRDB
import MemoryContracts
import XCTest

@testable import MemoryStore

final class ArchiveDeletionRequestStoreTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_777_000_000)

    func testMomentRequestImmediatelyHidesEveryReadProjectionAndQueuesRewrite() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let frameID = try searchableFrame(archive, suffix: 701, offset: 10)
        let store = try ArchiveDeletionRequestStore(database: archive)
        let request = ArchiveDeletionRequest(
            id: uuid(710),
            target: .moment(frameID),
            requestedAt: baseDate.addingTimeInterval(20),
            rewriteJobID: uuid(711),
            auditEventID: uuid(712)
        )

        let operation = try store.request(request)

        XCTAssertEqual(operation.tombstone.requestedFrameIDs, [frameID])
        XCTAssertEqual(operation.tombstone.reason, .userMoment)
        XCTAssertEqual(operation.tombstone.state, .rewriting)
        XCTAssertEqual(operation.state, .queued)
        XCTAssertEqual(operation.completedRewriteCount, 0)
        XCTAssertEqual(operation.totalRewriteCount, 1)
        XCTAssertTrue(try archive.localSearchScope().bundleIdentifiers.isEmpty)
        XCTAssertTrue(try lexicalCandidates(archive).isEmpty)
        XCTAssertTrue(try timelineFrames(archive).isEmpty)
        XCTAssertEqual(try archive.processingJobStateForTesting(id: uuid(711).encoded), "queued")

        let databaseState = try archive.atomicRead { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT frames.text_state, frames.visual_state,
                           merged_text_records.state AS merged_state
                    FROM frames
                    JOIN merged_text_records ON merged_text_records.frame_id = frames.id
                    WHERE frames.id = ?
                    """,
                arguments: [frameID.encoded]
            )
        }
        XCTAssertEqual(databaseState?["text_state"], "suppressed")
        XCTAssertEqual(databaseState?["visual_state"], "suppressed")
        XCTAssertEqual(databaseState?["merged_state"], "suppressed")
        let audit = try contentFreeDeletionAudit(archive)
        XCTAssertEqual(audit.count, 1)
        XCTAssertEqual(audit.action, "deletion_requested")
    }

    func testRangeRequestHidesOnlyHalfOpenIntervalAndIsIdempotent() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let first = try searchableFrame(archive, suffix: 721, offset: 10)
        let second = try searchableFrame(archive, suffix: 722, offset: 20)
        let retained = try searchableFrame(archive, suffix: 723, offset: 30)
        let store = try ArchiveDeletionRequestStore(database: archive)
        let interval = DateInterval(
            start: baseDate.addingTimeInterval(5),
            end: baseDate.addingTimeInterval(30)
        )
        let request = ArchiveDeletionRequest(
            id: uuid(720),
            target: .range(interval),
            requestedAt: baseDate.addingTimeInterval(40),
            rewriteJobID: uuid(724),
            auditEventID: uuid(725)
        )

        let firstResult = try store.request(request)
        let secondResult = try store.request(request)

        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(firstResult.tombstone.requestedFrameIDs, [first, second])
        XCTAssertEqual(firstResult.tombstone.requestedInterval, interval)
        XCTAssertEqual(firstResult.tombstone.reason, .userRange)
        XCTAssertEqual(Set(try lexicalCandidates(archive).map(\.frameID)), [retained])
        XCTAssertEqual(Set(try timelineFrames(archive).map(\.frameID)), [retained])
        XCTAssertEqual(try store.pendingOperations(), [firstResult])
    }

    func testOperationProjectsContentFreePermanentFailureWithoutUnhidingTarget() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let frameID = try searchableFrame(archive, suffix: 731, offset: 10)
        let store = try ArchiveDeletionRequestStore(database: archive)
        let request = ArchiveDeletionRequest(
            id: uuid(730),
            target: .moment(frameID),
            requestedAt: baseDate.addingTimeInterval(20),
            rewriteJobID: uuid(734),
            auditEventID: uuid(735)
        )
        _ = try store.request(request)
        try archive.atomicWrite { database in
            try database.execute(
                sql: """
                    UPDATE processing_jobs
                    SET state = 'permanentFailure', attempts = 3,
                        error_code = 'rewrite_integrity_failed'
                    WHERE id = ?
                    """,
                arguments: [request.rewriteJobID.encoded]
            )
        }

        let operation = try XCTUnwrap(store.operation(id: request.id))

        XCTAssertEqual(operation.state, .failed)
        XCTAssertEqual(operation.failureCode, "rewrite_integrity_failed")
        XCTAssertTrue(try lexicalCandidates(archive).isEmpty)
        XCTAssertTrue(try timelineFrames(archive).isEmpty)
    }

    func testPendingRewriteAndSuppressionResumeAfterDatabaseRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deepshelves-lm047-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 0x47, count: LM008StoreDefaults.keyByteCount)
        let frameID = uuid(740)
        let request = ArchiveDeletionRequest(
            id: uuid(741),
            target: .moment(frameID),
            requestedAt: baseDate.addingTimeInterval(20),
            rewriteJobID: uuid(742),
            auditEventID: uuid(743)
        )

        var archive: ArchiveDatabase? = try ArchiveDatabase(
            applicationSupportDirectory: root,
            encryptionKey: key
        )
        _ = try searchableFrame(
            XCTUnwrap(archive),
            suffix: 740,
            explicitFrameID: frameID,
            offset: 10
        )
        let expected = try ArchiveDeletionRequestStore(database: XCTUnwrap(archive)).request(
            request)
        archive = nil

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: root,
            encryptionKey: key
        )
        let store = try ArchiveDeletionRequestStore(database: reopened)

        XCTAssertEqual(try store.pendingOperations(), [expected])
        XCTAssertTrue(try lexicalCandidates(reopened).isEmpty)
        XCTAssertTrue(try timelineFrames(reopened).isEmpty)
    }

    private func searchableFrame(
        _ archive: ArchiveDatabase,
        suffix: Int,
        explicitFrameID: UUID? = nil,
        offset: TimeInterval
    ) throws -> UUID {
        let frameID = try archive.insertSearchFrameFixtureForTesting(
            suffix: suffix,
            frameID: explicitFrameID,
            capturedAt: baseDate.addingTimeInterval(offset),
            bundleIdentifier: "com.example.deletion",
            appName: "Deletion Fixture",
            windowTitle: "Deletion Fixture Window"
        )
        let span = try TextSpan(
            id: uuid(suffix + 10_000),
            frameID: frameID,
            source: .accessibility,
            text: "searchable deletion fixture \(suffix)",
            bounds: nil,
            confidence: nil,
            languageCode: "en",
            sensitivity: .normal
        )
        try ArchiveSearchIndexStore(database: archive).publish(
            ArchiveMergedTextSeed(
                frameID: frameID,
                approvedSpans: [span],
                transcriptSpans: [],
                producerVersion: "deletion-fixture-v1"
            )
        )
        return frameID
    }

    private func lexicalCandidates(_ archive: ArchiveDatabase) throws
        -> [ArchiveLexicalCandidate]
    {
        try ArchiveSearchIndexStore(database: archive).lexicalCandidates(
            ArchiveLexicalQuery(
                ftsQuery: nil,
                normalizedQuery: "",
                interval: DateInterval(
                    start: baseDate,
                    end: baseDate.addingTimeInterval(60)
                ),
                policyBundleIDs: ["com.example.deletion"],
                policyHosts: [],
                requestedBundleIDs: [],
                requestedHosts: [],
                after: nil,
                limit: 100
            )
        )
    }

    private func timelineFrames(_ archive: ArchiveDatabase) throws -> [TimelineFrameSummary] {
        let interval = DateInterval(
            start: baseDate,
            end: baseDate.addingTimeInterval(60)
        )
        return try ArchiveTimelineQuery(database: archive).page(
            TimelinePageRequest(
                interval: interval,
                cursor: baseDate,
                zoom: .oneHour,
                calendarTimeZone: TimeZone(secondsFromGMT: 0)!
            )
        ).slice.frames
    }

    private func contentFreeDeletionAudit(_ archive: ArchiveDatabase) throws
        -> (count: Int, action: String)
    {
        try archive.atomicRead { database in
            let row = try XCTUnwrap(
                Row.fetchOne(
                    database,
                    sql: """
                        SELECT result_count, action, policy_id, query_hash
                        FROM audit_events
                        WHERE action = 'deletion_requested'
                        """
                )
            )
            XCTAssertNil(row["policy_id"] as String?)
            XCTAssertNil(row["query_hash"] as String?)
            return (row["result_count"], row["action"])
        }
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "47000000-0000-4000-8000-%012d", suffix))!
    }
}

extension UUID {
    fileprivate var encoded: String { uuidString.lowercased() }
}
