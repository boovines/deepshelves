import CryptoKit
import Foundation
import GRDB
import MemoryContracts
import XCTest

@testable import MemoryStore

final class ArchiveDeletionRewriteWorkerTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_777_680_000)

    func testMomentDeletionPublishesRetainedBytesAndRemovesEveryDeletedDerivative() throws {
        let fixture = try RewriteFixture(testCase: self, suffix: 1)
        let chunk = try fixture.seedChunk(suffix: 10, frameCount: 3)
        let deleted = chunk.frames[1]
        let retainedBytes = [chunk.frames[0].bytes, chunk.frames[2].bytes]
        let request = try fixture.requestMoment(deleted.id)

        let result = try fixture.worker().process(tombstoneID: request.id)

        XCTAssertEqual(result.state, .verified)
        XCTAssertEqual(result.deletedFrameCount, 1)
        XCTAssertEqual(result.replacementChunkIDs.count, 1)
        let replacementID = try XCTUnwrap(result.replacementChunkIDs.first)
        let replacementPath = try ArchiveRelativePath(
            "media/2026/08/29/\(replacementID.encoded)/manifest.json"
        )
        let verified = try ArchiveHEICChunkVerifier.verify(
            paths: try XCTUnwrap(fixture.archive.paths),
            manifestRelativePath: replacementPath,
            expectedChunkID: replacementID
        )
        XCTAssertEqual(verified.frames.map(\.id), [chunk.frames[0].id, chunk.frames[2].id])
        XCTAssertEqual(verified.frames.map(\.presentationTimeMilliseconds), [0, 1_000])
        XCTAssertEqual(
            try verified.frames.map { frame in
                try Data(
                    contentsOf: try XCTUnwrap(fixture.archive.paths).root.appending(
                        path: frame.archiveRelativePath,
                        directoryHint: .notDirectory
                    )
                )
            },
            retainedBytes
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleted.thumbnail.path))
        XCTAssertEqual(try fixture.frameCount(deleted.id), 0)
        XCTAssertEqual(try fixture.derivativeCounts(deleted.id), [0, 0, 0, 0])
        XCTAssertEqual(try fixture.ftsCount(deleted.searchText), 0)
        XCTAssertEqual(try fixture.ftsCount(chunk.frames[0].searchText), 1)
        XCTAssertEqual(try fixture.ftsCount(chunk.frames[2].searchText), 1)
        XCTAssertEqual(try fixture.rewriteJobState(request.id), "succeeded")
        XCTAssertEqual(fixture.compactor.modelHashes, [fixture.modelHash])

        let tombstone = try fixture.tombstone(request.id)
        XCTAssertEqual(tombstone.state, .verified)
        XCTAssertEqual(tombstone.replacementChunkIDs, [replacementID])
        XCTAssertEqual(tombstone.verificationHash?.count, 32)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.journalDirectory(request.id).path
            )
        )
    }

    func testRangeDeletesCoveredChunkAndRewritesPartiallyCoveredChunk() throws {
        let fixture = try RewriteFixture(testCase: self, suffix: 2)
        let first = try fixture.seedChunk(suffix: 20, frameCount: 2, timeOffset: 0)
        let second = try fixture.seedChunk(suffix: 30, frameCount: 2, timeOffset: 10)
        let interval = DateInterval(
            start: baseDate.addingTimeInterval(-1),
            end: baseDate.addingTimeInterval(11)
        )
        let request = try fixture.requestRange(interval)

        let result = try fixture.worker().process(tombstoneID: request.id)

        XCTAssertEqual(result.state, .verified)
        XCTAssertEqual(result.deletedFrameCount, 3)
        XCTAssertEqual(result.replacementChunkIDs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.directory.path))
        for frame in first.frames + [second.frames[0]] {
            XCTAssertEqual(try fixture.frameCount(frame.id), 0)
            XCTAssertEqual(try fixture.ftsCount(frame.searchText), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: frame.thumbnail.path))
        }
        XCTAssertEqual(try fixture.frameCount(second.frames[1].id), 1)
        XCTAssertEqual(try fixture.ftsCount(second.frames[1].searchText), 1)
    }

    func testEveryCrashBoundaryRecoversFromDurableJournal() throws {
        let faults: [ArchiveDeletionRewriteFault] = [
            .afterPlan,
            .afterReplacementPublication,
            .duringDatabaseCommit,
            .afterDatabaseCommit,
            .afterVectorCompaction,
            .afterOldDirectoryDisposal,
        ]
        for (offset, fault) in faults.enumerated() {
            let fixture = try RewriteFixture(testCase: self, suffix: 100 + offset)
            let chunk = try fixture.seedChunk(suffix: 200 + offset, frameCount: 3)
            let deleted = chunk.frames[1]
            let request = try fixture.requestMoment(deleted.id)
            XCTAssertThrowsError(
                try fixture.worker().process(tombstoneID: request.id, fault: fault)
            ) { error in
                XCTAssertEqual(
                    error as? ArchiveDeletionRewriteError,
                    .injectedFault(fault),
                    "fault \(fault.rawValue)"
                )
            }

            let recovered = try fixture.worker().recoverPending()

            XCTAssertEqual(recovered.count, 1, "fault \(fault.rawValue)")
            XCTAssertEqual(recovered[0].state, .verified, "fault \(fault.rawValue)")
            XCTAssertEqual(try fixture.frameCount(deleted.id), 0, "fault \(fault.rawValue)")
            XCTAssertEqual(try fixture.ftsCount(deleted.searchText), 0, "fault \(fault.rawValue)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: chunk.directory.path),
                "fault \(fault.rawValue)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.journalDirectory(request.id).path
                ),
                "fault \(fault.rawValue)"
            )
        }
    }

    func testCorruptSourceFailsClosedBeforeReplacementPublication() throws {
        let fixture = try RewriteFixture(testCase: self, suffix: 3)
        let chunk = try fixture.seedChunk(suffix: 40, frameCount: 3)
        let deleted = chunk.frames[1]
        let request = try fixture.requestMoment(deleted.id)
        try Data("tampered".utf8).write(to: chunk.frames[0].source)

        XCTAssertThrowsError(try fixture.worker().process(tombstoneID: request.id))

        XCTAssertEqual(try fixture.frameCount(deleted.id), 1)
        XCTAssertEqual(try fixture.ftsCount(deleted.searchText), 0)
        XCTAssertEqual(try fixture.frameStates(deleted.id), ["suppressed", "suppressed"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.directory.path))
    }
}

private final class RewriteFixture {
    let archive: ArchiveDatabase
    let compactor = VectorCompactorSpy()
    let modelHash = String(repeating: "5a", count: 32)
    private let baseDate = Date(timeIntervalSince1970: 1_777_680_000)
    private let identifiers: IdentifierSequence

    init(testCase: XCTestCase, suffix: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deepshelves-lm060-\(suffix)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        archive = try ArchiveDatabase(
            applicationSupportDirectory: root,
            encryptionKey: Data(repeating: 0x60, count: LM008StoreDefaults.keyByteCount)
        )
        identifiers = IdentifierSequence(base: 60_000 + suffix * 100)
    }

    func worker() throws -> ArchiveDeletionRewriteWorker {
        try ArchiveDeletionRewriteWorker(
            database: archive,
            vectorCompactor: ArchiveDeletionVectorCompactor { [compactor] hashes in
                compactor.record(hashes)
            },
            makeIdentifier: { [identifiers] in identifiers.next() },
            now: { Date(timeIntervalSince1970: 1_777_680_500) }
        )
    }

    func seedChunk(
        suffix: Int,
        frameCount: Int,
        timeOffset: TimeInterval = 0
    ) throws -> RewriteChunk {
        let paths = try XCTUnwrap(archive.paths)
        let chunkID = stableUUID(10_000 + suffix)
        let epochID = stableUUID(20_000 + suffix)
        let relativeDirectory = "media/2026/08/29/\(chunkID.encoded)"
        let directory = paths.root.appending(
            path: relativeDirectory,
            directoryHint: .isDirectory
        )
        let frameDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(
            at: frameDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: ArchivePathProvider.directoryPermissions]
        )
        var entries: [HEICKeyframeEntry] = []
        var frames: [RewriteFrame] = []
        for index in 0..<frameCount {
            let frameID = stableUUID(30_000 + suffix * 10 + index)
            let bytes = Data("independent-heic-\(suffix)-\(index)".utf8)
            let relativePath = "frames/\(frameID.encoded).heic"
            let source = directory.appending(
                path: relativePath,
                directoryHint: .notDirectory
            )
            try bytes.write(to: source)
            let entry = try HEICKeyframeEntry(
                frameID: frameID,
                presentationTimeMS: Int64(index * 500),
                relativePath: relativePath,
                byteCount: Int64(bytes.count),
                sha256: Data(SHA256.hash(data: bytes))
            )
            entries.append(entry)
            let thumbnail = paths.thumbnails.appendingPathComponent(
                "\(frameID.encoded).heic",
                isDirectory: false
            )
            try Data("thumbnail-\(suffix)-\(index)".utf8).write(to: thumbnail)
            frames.append(
                RewriteFrame(
                    id: frameID,
                    bytes: bytes,
                    source: source,
                    thumbnail: thumbnail,
                    searchText: "deletionsentinel\(suffix)x\(index)",
                    capturedAt: baseDate.addingTimeInterval(timeOffset + Double(index))
                )
            )
        }
        let manifest = try HEICKeyframeManifest(
            chunkID: chunkID,
            captureEpochID: epochID,
            targetWindowID: 42,
            width: 1280,
            height: 720,
            frames: entries
        )
        let manifestBytes = try ContractJSON.encode(manifest)
        try manifestBytes.write(
            to: directory.appendingPathComponent("manifest.json", isDirectory: false)
        )
        let totalBytes = entries.reduce(Int64(manifestBytes.count)) { $0 + $1.byteCount }
        try archive.atomicWrite { database in
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES (?, ?, 42, ?, ?, ?, 'heicKeyframes', 1280, 720,
                              ?, ?, ?, 'ready')
                    """,
                arguments: [
                    chunkID.encoded,
                    epochID.encoded,
                    "\(relativeDirectory)/manifest.json",
                    encode(frames.first!.capturedAt),
                    encode(frames.last!.capturedAt.addingTimeInterval(0.001)),
                    frameCount,
                    totalBytes,
                    Data(SHA256.hash(data: manifestBytes)).lowercaseHex,
                ]
            )
            for (index, frame) in frames.enumerated() {
                let thumbnailRelative = "thumbnails/\(frame.id.encoded).heic"
                try database.execute(
                    sql: """
                        INSERT INTO frames(
                            id, captured_at, monotonic_ns, capture_epoch_id,
                            target_window_id, chunk_id, pts_ms, thumbnail_path,
                            bundle_id, app_name, window_title, capture_reason,
                            is_transition, text_state, visual_state, schema_version,
                            approved_text, media_path, media_sha256, media_byte_count,
                            policy_generation
                        ) VALUES (?, ?, ?, ?, 42, ?, ?, ?, 'com.example.rewrite',
                                  'Rewrite Fixture', 'Rewrite Window', 'visualChange', 0,
                                  'ready', 'ready', 2, ?, ?, ?, ?, 7)
                        """,
                    arguments: [
                        frame.id.encoded,
                        encode(frame.capturedAt),
                        index + 1,
                        epochID.encoded,
                        chunkID.encoded,
                        index * 500,
                        thumbnailRelative,
                        frame.searchText,
                        "\(relativeDirectory)/frames/\(frame.id.encoded).heic",
                        entries[index].sha256.lowercaseHex,
                        entries[index].byteCount,
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
                    arguments: [
                        stableUUID(40_000 + suffix * 10 + index).encoded, frame.id.encoded,
                        frame.searchText,
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO merged_text_records(
                            frame_id, approved_text, transcript_text, window_title,
                            app_name, url_host, url_path, producer_version, state
                        ) VALUES (?, ?, '', 'Rewrite Window', 'Rewrite Fixture',
                                  NULL, NULL, 'rewrite-fixture-v1', 'ready')
                        """,
                    arguments: [frame.id.encoded, frame.searchText]
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
                    arguments: [frame.id.encoded]
                )
                try database.execute(
                    sql: """
                        INSERT INTO artifacts(
                            id, frame_id, kind, producer_name, producer_version,
                            model_hash, locator_kind, locator_value, content_hash, state
                        ) VALUES (?, ?, 'thumbnail', 'fixture', '1', NULL,
                                  'relativePath', ?, 'thumbnail-hash', 'ready')
                        """,
                    arguments: [
                        stableUUID(50_000 + suffix * 10 + index).encoded, frame.id.encoded,
                        thumbnailRelative,
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO artifacts(
                            id, frame_id, kind, producer_name, producer_version,
                            model_hash, locator_kind, locator_value, content_hash, state
                        ) VALUES (?, ?, 'visualVector', 'fixture', '1', ?,
                                  'relativeFileOffset', ?, ?, 'ready')
                        """,
                    arguments: [
                        stableUUID(60_000 + suffix * 10 + index).encoded,
                        frame.id.encoded,
                        modelHash,
                        "vectors/mobileclip-s0/\(modelHash).f16#\(192 + index * 2):2",
                        String(repeating: "c", count: 64),
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO vector_offsets(
                            frame_id, model_hash, byte_offset, dimension, norm, state
                        ) VALUES (?, ?, ?, 1, 1, 'ready')
                        """,
                    arguments: [frame.id.encoded, modelHash, 192 + index * 2]
                )
            }
        }
        return RewriteChunk(id: chunkID, directory: directory, frames: frames)
    }

    func requestMoment(_ frameID: UUID) throws -> ArchiveDeletionRequest {
        let request = ArchiveDeletionRequest(
            id: identifiers.next(),
            target: .moment(frameID),
            requestedAt: baseDate.addingTimeInterval(100),
            rewriteJobID: identifiers.next(),
            auditEventID: identifiers.next()
        )
        _ = try ArchiveDeletionRequestStore(database: archive).request(request)
        return request
    }

    func requestRange(_ interval: DateInterval) throws -> ArchiveDeletionRequest {
        let request = ArchiveDeletionRequest(
            id: identifiers.next(),
            target: .range(interval),
            requestedAt: baseDate.addingTimeInterval(100),
            rewriteJobID: identifiers.next(),
            auditEventID: identifiers.next()
        )
        _ = try ArchiveDeletionRequestStore(database: archive).request(request)
        return request
    }

    func frameCount(_ frameID: UUID) throws -> Int {
        try archive.atomicRead { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM frames WHERE id = ?",
                arguments: [frameID.encoded]
            ) ?? -1
        }
    }

    func derivativeCounts(_ frameID: UUID) throws -> [Int] {
        try archive.atomicRead { database in
            try ["text_spans", "artifacts", "vector_offsets", "merged_text_records"].map {
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM \($0) WHERE frame_id = ?",
                    arguments: [frameID.encoded]
                ) ?? -1
            }
        }
    }

    func ftsCount(_ text: String) throws -> Int {
        try archive.atomicRead { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM frame_fts WHERE frame_fts MATCH ?",
                arguments: [text]
            ) ?? -1
        }
    }

    func frameStates(_ frameID: UUID) throws -> [String] {
        try archive.atomicRead { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: "SELECT text_state, visual_state FROM frames WHERE id = ?",
                    arguments: [frameID.encoded]
                )
            else { return [] }
            return [row["text_state"], row["visual_state"]]
        }
    }

    func rewriteJobState(_ tombstoneID: UUID) throws -> String? {
        try archive.atomicRead { database in
            try String.fetchOne(
                database,
                sql: """
                    SELECT state FROM processing_jobs
                    WHERE parent_id = ? AND kind IN ('mediaRewrite', 'media-rewrite')
                    """,
                arguments: [tombstoneID.encoded]
            )
        }
    }

    func tombstone(_ id: UUID) throws -> DeletionTombstone {
        try archive.atomicRead { database in
            let encoded = try XCTUnwrap(
                String.fetchOne(
                    database,
                    sql: "SELECT encoded_tombstone FROM deletion_tombstones WHERE id = ?",
                    arguments: [id.encoded]
                )
            )
            return try ContractJSON.decode(
                DeletionTombstone.self,
                from: try XCTUnwrap(encoded.data(using: .utf8))
            )
        }
    }

    func journalDirectory(_ id: UUID) -> URL {
        archive.paths!.quarantine
            .appendingPathComponent("deletion", isDirectory: true)
            .appendingPathComponent(id.encoded, isDirectory: true)
    }

    private func stableUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "60000000-0000-4000-8000-%012d", value))!
    }

    private func encode(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
    }
}

private struct RewriteChunk {
    let id: UUID
    let directory: URL
    let frames: [RewriteFrame]
}

private struct RewriteFrame {
    let id: UUID
    let bytes: Data
    let source: URL
    let thumbnail: URL
    let searchText: String
    let capturedAt: Date
}

private final class VectorCompactorSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Set<String> = []

    var modelHashes: Set<String> {
        lock.withLock { recorded }
    }

    func record(_ hashes: Set<String>) {
        lock.withLock { recorded.formUnion(hashes) }
    }
}

private final class IdentifierSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue: Int

    init(base: Int) {
        nextValue = base
    }

    func next() -> UUID {
        lock.withLock {
            defer { nextValue += 1 }
            return UUID(
                uuidString: String(format: "61000000-0000-4000-8000-%012d", nextValue)
            )!
        }
    }
}

extension UUID {
    fileprivate var encoded: String { uuidString.lowercased() }
}

extension Data {
    fileprivate var lowercaseHex: String { map { String(format: "%02x", $0) }.joined() }
}
