import Foundation
import GRDB
import MemoryContracts
import XCTest

@testable import MemoryStore

final class ArchiveRetentionWorkerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_777_680_000)
    private let key = Data(repeating: 0x58, count: LM008StoreDefaults.keyByteCount)

    func testExactThirtyDayBoundaryDeletesOlderChunkAndCascadesEveryDerivative() throws {
        let fixture = try makeArchive()
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let expired = try seedChunk(
            fixture.archive,
            suffix: 1,
            startedAt: cutoff.addingTimeInterval(-2),
            endedAt: cutoff.addingTimeInterval(-1),
            byteCount: 11,
            searchableText: "expiredretentionsentinel"
        )
        let boundary = try seedChunk(
            fixture.archive,
            suffix: 2,
            startedAt: cutoff.addingTimeInterval(-1),
            endedAt: cutoff,
            byteCount: 13,
            searchableText: "boundaryretainedsentinel"
        )
        let worker = try ArchiveRetentionWorker(
            database: fixture.archive,
            policy: ArchiveRetentionPolicy(
                maximumAge: 30 * 24 * 60 * 60,
                maximumArchiveBytes: 1_000,
                minimumAvailableCapacityBytes: 100
            ),
            now: { self.now },
            availableCapacityBytes: { 10_000 }
        )

        let progress = try worker.run()

        XCTAssertEqual(progress.readyChunkCountBefore, 2)
        XCTAssertEqual(progress.readyByteCountBefore, 24)
        XCTAssertEqual(progress.deletedChunkCount, 1)
        XCTAssertEqual(progress.deletedByteCount, 11)
        XCTAssertEqual(progress.readyChunkCountAfter, 1)
        XCTAssertEqual(progress.readyByteCountAfter, 13)
        XCTAssertEqual(progress.deletedReasons, [.retention: 1])
        XCTAssertFalse(progress.captureShouldStop)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expired.thumbnail.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: boundary.directory.path))

        let counts = try fixture.archive.atomicRead { database in
            (
                try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM media_chunks WHERE id = ?",
                    arguments: [expired.chunkID]
                ) ?? -1,
                try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM frames WHERE id = ?",
                    arguments: [expired.frameID]
                ) ?? -1,
                try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM text_spans WHERE frame_id = ?",
                    arguments: [expired.frameID]
                ) ?? -1,
                try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM artifacts WHERE frame_id = ?",
                    arguments: [expired.frameID]
                ) ?? -1,
                try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM vector_offsets WHERE frame_id = ?",
                    arguments: [expired.frameID]
                ) ?? -1,
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM merged_text_records WHERE frame_id = ?",
                    arguments: [expired.frameID]
                ) ?? -1,
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM processing_jobs WHERE parent_id = ?",
                    arguments: [expired.frameID]
                ) ?? -1
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
        XCTAssertEqual(counts.3, 0)
        XCTAssertEqual(counts.4, 0)
        XCTAssertEqual(counts.5, 0)
        XCTAssertEqual(counts.6, 0)
        XCTAssertTrue(try lexicalMatches(fixture.archive, "expiredretentionsentinel").isEmpty)
        XCTAssertEqual(try lexicalMatches(fixture.archive, "boundaryretainedsentinel").count, 1)

        let proof = try fixture.archive.atomicRead { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT deletion_tombstones.encoded_tombstone,
                           deletion_tombstones.state, audit_events.actor,
                           audit_events.action, audit_events.result_count,
                           audit_events.query_hash
                    FROM deletion_tombstones
                    JOIN audit_events ON audit_events.action = 'retention_deleted'
                    """
            )
        }
        let encoded: String = try XCTUnwrap(proof?["encoded_tombstone"])
        let tombstone = try ContractJSON.decode(
            DeletionTombstone.self,
            from: try XCTUnwrap(encoded.data(using: .utf8))
        )
        XCTAssertEqual(tombstone.state, .verified)
        XCTAssertEqual(tombstone.reason, .retention)
        XCTAssertEqual(tombstone.requestedFrameIDs, [UUID(uuidString: expired.frameID)!])
        XCTAssertEqual(tombstone.verificationHash?.count, 32)
        XCTAssertEqual(proof?["state"] as String?, "verified")
        XCTAssertEqual(proof?["actor"] as String?, "system")
        XCTAssertEqual(proof?["action"] as String?, "retention_deleted")
        XCTAssertEqual(proof?["result_count"] as Int?, 1)
        XCTAssertNil(proof?["query_hash"] as String?)
    }

    func testCapDeletesOldestReadyChunksAndProtectsStaging() throws {
        let fixture = try makeArchive()
        let first = try seedChunk(
            fixture.archive,
            suffix: 11,
            startedAt: now.addingTimeInterval(-300),
            endedAt: now.addingTimeInterval(-299),
            byteCount: 8
        )
        let second = try seedChunk(
            fixture.archive,
            suffix: 12,
            startedAt: now.addingTimeInterval(-200),
            endedAt: now.addingTimeInterval(-199),
            byteCount: 7
        )
        let third = try seedChunk(
            fixture.archive,
            suffix: 13,
            startedAt: now.addingTimeInterval(-100),
            endedAt: now.addingTimeInterval(-99),
            byteCount: 6
        )
        let staging = try seedStagingChunk(fixture.archive, suffix: 14, byteCount: 10_000)
        let worker = try ArchiveRetentionWorker(
            database: fixture.archive,
            policy: ArchiveRetentionPolicy(
                maximumAge: 30 * 24 * 60 * 60,
                maximumArchiveBytes: 13,
                minimumAvailableCapacityBytes: 100
            ),
            now: { self.now },
            availableCapacityBytes: { 10_000 }
        )

        let progress = try worker.run()

        XCTAssertEqual(progress.deletedChunkCount, 1)
        XCTAssertEqual(progress.deletedByteCount, 8)
        XCTAssertEqual(progress.deletedReasons, [.storageCap: 1])
        XCTAssertEqual(progress.readyByteCountAfter, 13)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: third.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.directory.path))
        XCTAssertEqual(
            try fixture.archive.mediaChunkStateForTesting(id: staging.chunkID),
            "staging"
        )
    }

    func testLowDiskDeletesOldestReadyChunkUntilCapacityRecovers() throws {
        let fixture = try makeArchive()
        let oldest = try seedChunk(
            fixture.archive,
            suffix: 21,
            startedAt: now.addingTimeInterval(-300),
            endedAt: now.addingTimeInterval(-299),
            byteCount: 8
        )
        let retained = try seedChunk(
            fixture.archive,
            suffix: 22,
            startedAt: now.addingTimeInterval(-200),
            endedAt: now.addingTimeInterval(-199),
            byteCount: 7
        )
        let worker = try ArchiveRetentionWorker(
            database: fixture.archive,
            policy: ArchiveRetentionPolicy(
                maximumAge: 30 * 24 * 60 * 60,
                maximumArchiveBytes: 100,
                minimumAvailableCapacityBytes: 500
            ),
            now: { self.now },
            availableCapacityBytes: {
                FileManager.default.fileExists(atPath: oldest.directory.path) ? 100 : 800
            }
        )

        let progress = try worker.run()

        XCTAssertEqual(progress.deletedReasons, [.lowDisk: 1])
        XCTAssertEqual(progress.availableCapacityBytesAfter, 800)
        XCTAssertFalse(progress.captureShouldStop)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.directory.path))
    }

    func testLowDiskWithOnlyStagingMediaStopsCaptureWithoutDeletingIt() throws {
        let fixture = try makeArchive()
        let staging = try seedStagingChunk(fixture.archive, suffix: 31, byteCount: 10_000)
        let worker = try ArchiveRetentionWorker(
            database: fixture.archive,
            policy: ArchiveRetentionPolicy(
                maximumAge: 30 * 24 * 60 * 60,
                maximumArchiveBytes: 20_000,
                minimumAvailableCapacityBytes: 500
            ),
            now: { self.now },
            availableCapacityBytes: { 100 }
        )

        let progress = try worker.run()

        XCTAssertEqual(progress.deletedChunkCount, 0)
        XCTAssertTrue(progress.captureShouldStop)
        XCTAssertEqual(progress.stopReason, .lowDisk)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.directory.path))
    }

    func testMissingReadyDirectoryFailsClosedAndLeavesNoSearchVisibility() throws {
        let fixture = try makeArchive()
        let missing = try seedChunk(
            fixture.archive,
            suffix: 41,
            startedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-31 * 24 * 60 * 60 + 1),
            byteCount: 8,
            searchableText: "missingretentionsentinel"
        )
        try FileManager.default.removeItem(at: missing.directory)
        let worker = try ArchiveRetentionWorker(
            database: fixture.archive,
            policy: ArchiveRetentionPolicy(
                maximumAge: 30 * 24 * 60 * 60,
                maximumArchiveBytes: 100,
                minimumAvailableCapacityBytes: 100
            ),
            now: { self.now },
            availableCapacityBytes: { 10_000 }
        )

        XCTAssertThrowsError(try worker.run()) { error in
            XCTAssertEqual(error as? ArchiveRetentionError, .missingChunkDirectory)
        }
        XCTAssertTrue(try lexicalMatches(fixture.archive, "missingretentionsentinel").isEmpty)
        XCTAssertEqual(
            try fixture.archive.mediaChunkStateForTesting(id: missing.chunkID),
            "ready"
        )
        let state = try fixture.archive.atomicRead { database in
            try String.fetchOne(
                database,
                sql: "SELECT state FROM deletion_tombstones ORDER BY id LIMIT 1"
            )
        }
        XCTAssertEqual(state, "failed")
    }

    private func makeArchive() throws -> ArchiveFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deepshelves-lm058-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ArchiveFixture(
            archive: try ArchiveDatabase(applicationSupportDirectory: root, encryptionKey: key)
        )
    }

    private func seedChunk(
        _ archive: ArchiveDatabase,
        suffix: Int,
        startedAt: Date,
        endedAt: Date,
        byteCount: Int64,
        searchableText: String? = nil
    ) throws -> ChunkFixture {
        let paths = try XCTUnwrap(archive.paths)
        let chunkID = uuid(suffix).uuidString.lowercased()
        let frameID = uuid(suffix + 1_000).uuidString.lowercased()
        let epochID = uuid(suffix + 2_000).uuidString.lowercased()
        let directory = paths.media.appendingPathComponent(chunkID, isDirectory: true)
        let frameDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(
            at: frameDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: ArchivePathProvider.directoryPermissions]
        )
        let manifest = directory.appendingPathComponent("manifest.json")
        let frame = frameDirectory.appendingPathComponent("\(frameID).heic")
        try Data("manifest-\(suffix)".utf8).write(to: manifest)
        try Data("frame-\(suffix)".utf8).write(to: frame)
        let thumbnail = paths.thumbnails.appendingPathComponent("\(frameID).heic")
        try Data("thumb-\(suffix)".utf8).write(to: thumbnail)
        let relativeManifest = "media/\(chunkID)/manifest.json"
        let relativeFrame = "media/\(chunkID)/frames/\(frameID).heic"
        let relativeThumbnail = "thumbnails/\(frameID).heic"
        let text = searchableText ?? "ready chunk \(suffix)"
        try archive.atomicWrite { database in
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES (?, ?, 42, ?, ?, ?, 'heicKeyframes', 1, 1, 1, ?, ?, 'ready')
                    """,
                arguments: [
                    chunkID, epochID, relativeManifest, encode(startedAt), encode(endedAt),
                    byteCount, String(repeating: "a", count: 64),
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO frames(
                        id, captured_at, monotonic_ns, capture_epoch_id,
                        target_window_id, chunk_id, pts_ms, thumbnail_path,
                        bundle_id, app_name, window_title, capture_reason,
                        is_transition, text_state, visual_state, schema_version,
                        approved_text, media_path, media_sha256, media_byte_count,
                        policy_generation
                    ) VALUES (?, ?, 1, ?, 42, ?, 0, ?, 'com.example.retention',
                              'Retention Fixture', 'Retention Window', 'visualChange', 0,
                              'ready', 'ready', 2, ?, ?, ?, 1, 1)
                    """,
                arguments: [
                    frameID, encode(startedAt), epochID, chunkID, relativeThumbnail, text,
                    relativeFrame, String(repeating: "b", count: 64),
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO text_spans(
                        id, frame_id, source, text, x, y, w, h,
                        confidence, language_code, sensitivity
                    ) VALUES (?, ?, 'accessibility', ?, NULL, NULL, NULL, NULL,
                              NULL, NULL, 'normal')
                    """,
                arguments: [uuid(suffix + 3_000).uuidString.lowercased(), frameID, text]
            )
            try database.execute(
                sql: """
                    INSERT INTO merged_text_records(
                        frame_id, approved_text, transcript_text, window_title,
                        app_name, url_host, url_path, producer_version, state
                    ) VALUES (?, ?, '', 'Retention Window', 'Retention Fixture',
                              NULL, NULL, 'retention-fixture-v1', 'ready')
                    """,
                arguments: [frameID, text]
            )
            try database.execute(
                sql: """
                    INSERT INTO frame_fts(
                        rowid, approved_text, window_title, app_name,
                        url_host, url_path, transcript_text
                    ) SELECT rowid, approved_text, window_title, app_name,
                             url_host, url_path, transcript_text
                      FROM merged_text_records WHERE frame_id = ?
                    """,
                arguments: [frameID]
            )
            try database.execute(
                sql: """
                    INSERT INTO artifacts(
                        id, frame_id, kind, producer_name, producer_version,
                        model_hash, locator_kind, locator_value, content_hash, state
                    ) VALUES (?, ?, 'thumbnail', 'fixture', '1', NULL,
                              'relativePath', ?, 'thumb-hash', 'ready')
                    """,
                arguments: [
                    uuid(suffix + 4_000).uuidString.lowercased(), frameID, relativeThumbnail,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO vector_offsets(
                        frame_id, model_hash, byte_offset, dimension, norm, state
                    ) VALUES (?, 'model-hash', 0, 1, 1, 'ready')
                    """,
                arguments: [frameID]
            )
            try database.execute(
                sql: """
                    INSERT INTO processing_jobs(
                        id, parent_id, kind, priority, state, attempts,
                        next_attempt_at, producer_version, error_code, lease_expires_at
                    ) VALUES (?, ?, 'thumbnail', 1, 'succeeded', 1, NULL,
                              'fixture-v1', NULL, NULL)
                    """,
                arguments: [uuid(suffix + 5_000).uuidString.lowercased(), frameID]
            )
        }
        return ChunkFixture(
            chunkID: chunkID,
            frameID: frameID,
            directory: directory,
            thumbnail: thumbnail
        )
    }

    private func seedStagingChunk(
        _ archive: ArchiveDatabase,
        suffix: Int,
        byteCount: Int64
    ) throws -> ChunkFixture {
        let paths = try XCTUnwrap(archive.paths)
        let chunkID = uuid(suffix).uuidString.lowercased()
        let epochID = uuid(suffix + 2_000).uuidString.lowercased()
        let directory = paths.media.appendingPathComponent(".\(chunkID).partial", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("staging".utf8).write(
            to: directory.appendingPathComponent("manifest.json", isDirectory: false)
        )
        try archive.atomicWrite { database in
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES (?, ?, 42, ?, ?, NULL, 'heicKeyframes', 1, 1, 0, ?, NULL, 'staging')
                    """,
                arguments: [
                    chunkID, epochID, "media/.\(chunkID).partial/manifest.json",
                    encode(now.addingTimeInterval(-10_000)), byteCount,
                ]
            )
        }
        return ChunkFixture(
            chunkID: chunkID,
            frameID: "",
            directory: directory,
            thumbnail: paths.thumbnails
        )
    }

    private func lexicalMatches(_ archive: ArchiveDatabase, _ text: String) throws -> [String] {
        try archive.atomicRead { database in
            try String.fetchAll(
                database,
                sql: "SELECT approved_text FROM frame_fts WHERE frame_fts MATCH ?",
                arguments: [text]
            )
        }
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "58000000-0000-4000-8000-%012d", suffix))!
    }

    private func encode(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
    }
}

private struct ArchiveFixture {
    let archive: ArchiveDatabase
}

private struct ChunkFixture {
    let chunkID: String
    let frameID: String
    let directory: URL
    let thumbnail: URL
}
