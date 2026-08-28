import CryptoKit
import Darwin
import Foundation
import GRDB
import MemoryContracts
import XCTest

@testable import MemoryStore

final class ArchiveVectorStoreTests: XCTestCase {
    func testStageIsInvisibleUntilJobSuccessAndFinalization() throws {
        let fixture = try VectorArchiveFixture()
        defer { fixture.remove() }
        let work = try fixture.makeLeasedFrame()

        let staged = try fixture.store.stage(fixture.request(work))

        XCTAssertEqual(staged.byteOffset, Int64(ArchiveVectorStore.headerByteCount))
        XCTAssertEqual(staged.byteLength, 1_024)
        XCTAssertFalse(staged.reusedExistingStage)
        XCTAssertEqual(staged.float16Norm, 1, accuracy: 0.001)
        XCTAssertThrowsError(try fixture.store.read(frameID: work.frameID, model: fixture.model))

        try fixture.jobs.succeed(work.lease)
        try fixture.store.finalize(work.lease, model: fixture.model)
        let decoded = try fixture.store.read(frameID: work.frameID, model: fixture.model)
        XCTAssertEqual(decoded[0], 0.6, accuracy: 0.001)
        XCTAssertEqual(decoded[1], 0.8, accuracy: 0.001)
        XCTAssertEqual(decoded.count, 512)
        XCTAssertEqual(try fixture.frameVisualState(work.frameID), "ready")
        XCTAssertEqual(try fixture.vectorState(work.frameID), "ready")
        XCTAssertEqual(try fixture.vectorFileSize(), Int64(192 + 1_024))
        XCTAssertEqual(try fixture.vectorFilePermissions(), 0o600)
    }

    func testDuplicatePublicationReusesExactStageWithoutAppending() throws {
        let fixture = try VectorArchiveFixture()
        defer { fixture.remove() }
        let work = try fixture.makeLeasedFrame()
        let request = fixture.request(work)

        let first = try fixture.store.stage(request)
        let second = try fixture.store.stage(request)

        XCTAssertEqual(first.byteOffset, second.byteOffset)
        XCTAssertTrue(second.reusedExistingStage)
        XCTAssertEqual(try fixture.vectorFileSize(), Int64(192 + 1_024))
        let changed = fixture.request(work, values: fixture.alternateVector)
        XCTAssertThrowsError(try fixture.store.stage(changed)) { error in
            XCTAssertEqual(error as? ArchiveVectorStoreError, .conflictingVector)
        }
    }

    func testStaleProjectionCanBeReplacedByCurrentLeasedProducer() throws {
        let fixture = try VectorArchiveFixture()
        defer { fixture.remove() }
        let original = try fixture.makeReadyFrame()
        try fixture.markStale(original.frameID)
        let replacement = try fixture.requeue(original, values: fixture.alternateVector)

        let staged = try fixture.store.stage(fixture.request(replacement))

        XCTAssertEqual(staged.byteOffset, Int64(192 + 1_024))
        try fixture.jobs.succeed(replacement.lease)
        try fixture.store.finalize(replacement.lease, model: fixture.model)
        let decoded = try fixture.store.read(frameID: original.frameID, model: fixture.model)
        XCTAssertEqual(decoded[0], 0.8, accuracy: 0.001)
        XCTAssertEqual(decoded[1], 0.6, accuracy: 0.001)
    }

    func testCrashTailIsTruncatedAndDatabaseStagePromotesAfterSuccess() throws {
        let fixture = try VectorArchiveFixture()
        defer { fixture.remove() }
        let orphan = try fixture.makeLeasedFrame()

        XCTAssertThrowsError(
            try fixture.store.stage(fixture.request(orphan), fault: .afterFileSync)
        )
        XCTAssertEqual(try fixture.vectorFileSize(), Int64(192 + 1_024))
        let repaired = try fixture.store.recover(model: fixture.model)
        XCTAssertEqual(repaired.truncatedTailBytes, 1_024)
        XCTAssertEqual(repaired.repairedByteCount, 192)

        let staged = try fixture.makeLeasedFrame()
        XCTAssertThrowsError(
            try fixture.store.stage(fixture.request(staged), fault: .afterDatabaseStage)
        )
        try fixture.jobs.succeed(staged.lease)
        let promoted = try fixture.store.recover(model: fixture.model)
        XCTAssertEqual(promoted.promotedStages, 1)
        XCTAssertEqual(try fixture.frameVisualState(staged.frameID), "ready")
        XCTAssertEqual(
            try fixture.store.read(frameID: staged.frameID, model: fixture.model)[0],
            0.6,
            accuracy: 0.001
        )
    }

    func testTruncationAndChecksumCorruptionNeverReturnResultsAndRebuild() throws {
        let fixture = try VectorArchiveFixture()
        defer { fixture.remove() }
        let first = try fixture.makeReadyFrame()
        let url = try fixture.vectorURL()
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(192 + 1_023))
        try handle.close()

        XCTAssertThrowsError(try fixture.store.read(frameID: first.frameID, model: fixture.model)) {
            thrown in
            XCTAssertEqual(thrown as? ArchiveVectorStoreError, .truncatedPayload)
        }
        XCTAssertThrowsError(try fixture.store.recover(model: fixture.model))
        try fixture.store.requestCompleteRebuild(model: fixture.model)
        XCTAssertEqual(try fixture.vectorFileSize(), 192)
        XCTAssertEqual(try fixture.frameVisualState(first.frameID), "pending")
        XCTAssertEqual(try XCTUnwrap(try fixture.jobs.job(first.lease.jobID)).state, .queued)

        let corruptionFixture = try VectorArchiveFixture()
        defer { corruptionFixture.remove() }
        let second = try corruptionFixture.makeReadyFrame()
        let descriptor = open(try corruptionFixture.vectorURL().path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var byte: UInt8 = 0x7F
        XCTAssertEqual(pwrite(descriptor, &byte, 1, off_t(192)), 1)
        XCTAssertEqual(fsync(descriptor), 0)
        close(descriptor)
        XCTAssertThrowsError(
            try corruptionFixture.store.read(
                frameID: second.frameID,
                model: corruptionFixture.model
            )
        ) { thrown in
            XCTAssertEqual(thrown as? ArchiveVectorStoreError, .checksumMismatch)
        }
    }

    func testWrongModelAndDuplicateOffsetsFailClosed() throws {
        let fixture = try VectorArchiveFixture()
        defer { fixture.remove() }
        let first = try fixture.makeReadyFrame()
        let second = try fixture.makeReadyFrame(values: fixture.alternateVector)
        let wrongModel = try fixture.model(replacingHashByte: 0x44)

        XCTAssertThrowsError(try fixture.store.read(frameID: first.frameID, model: wrongModel)) {
            thrown in
            XCTAssertEqual(thrown as? ArchiveVectorStoreError, .wrongModel)
        }

        try fixture.database.atomicWrite { database in
            try database.execute(
                sql: "UPDATE vector_offsets SET byte_offset = ? WHERE frame_id = ?",
                arguments: [Int64(192), second.frameID.uuidString.lowercased()]
            )
        }
        XCTAssertThrowsError(try fixture.store.recover(model: fixture.model)) { error in
            XCTAssertEqual(error as? ArchiveVectorStoreError, .duplicateOffset)
        }
    }

    func testCompactionDropsStaleVectorsAndRecoversBothCrashBoundaries() throws {
        let fixture = try VectorArchiveFixture()
        defer { fixture.remove() }
        let first = try fixture.makeReadyFrame()
        let stale = try fixture.makeReadyFrame(values: fixture.alternateVector)
        let last = try fixture.makeReadyFrame(values: fixture.thirdVector)
        try fixture.markStale(stale.frameID)
        XCTAssertEqual(try fixture.vectorFileSize(), Int64(192 + 3 * 1_024))

        XCTAssertThrowsError(
            try fixture.store.compact(model: fixture.model, fault: .afterCompactionSwap)
        )
        XCTAssertEqual(
            try fixture.store.read(frameID: first.frameID, model: fixture.model)[0],
            0.6,
            accuracy: 0.001
        )

        XCTAssertThrowsError(
            try fixture.store.compact(model: fixture.model, fault: .afterCompactionDatabase)
        )
        let recovery = try fixture.store.recover(model: fixture.model)
        XCTAssertTrue(recovery.compactionRecovered)
        XCTAssertEqual(try fixture.vectorFileSize(), Int64(192 + 2 * 1_024))
        XCTAssertEqual(
            try fixture.store.read(frameID: last.frameID, model: fixture.model)[2],
            1,
            accuracy: 0.001
        )
        XCTAssertThrowsError(try fixture.store.read(frameID: stale.frameID, model: fixture.model))
    }

    func testFortyVectorPermutationCompactsToCanonicalFrameOrder() throws {
        let fixture = try VectorArchiveFixture()
        defer { fixture.remove() }
        var retained: [VectorArchiveWork] = []
        for index in 0..<40 {
            let values = fixture.vector(seed: index + 1)
            let work = try fixture.makeReadyFrame(values: values)
            if index.isMultiple(of: 3) {
                try fixture.markStale(work.frameID)
            } else {
                retained.append(work)
            }
        }

        let report = try fixture.store.compact(model: fixture.model)

        XCTAssertEqual(report.retainedVectors, retained.count)
        XCTAssertEqual(report.removedVectors, 14)
        XCTAssertEqual(
            report.compactedByteCount,
            Int64(192 + retained.count * 1_024)
        )
        for work in retained.shuffled() {
            let decoded = try fixture.store.read(frameID: work.frameID, model: fixture.model)
            XCTAssertEqual(decoded.count, 512)
            XCTAssertEqual(
                sqrt(decoded.reduce(0.0) { $0 + Double($1) * Double($1) }),
                1,
                accuracy: 0.002
            )
        }
    }
}

private struct VectorArchiveWork {
    let frameID: UUID
    let epochID: UUID
    let lease: EnrichmentJobLease
    let sourceHash: Data
    let values: [Float]
}

private final class VectorArchiveFixture {
    let root: URL
    let database: ArchiveDatabase
    let jobs: ArchiveEnrichmentJobStore
    let store: ArchiveVectorStore
    let model: ArchiveVectorModelIdentity
    private let now = Date(timeIntervalSince1970: 1_777_900_000)
    private let targetWindowID: UInt32 = 42
    private let policyGeneration: UInt64 = 7
    private var frameSequence = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "lm051-vector-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        database = try ArchiveDatabase(
            applicationSupportDirectory: root,
            encryptionKey: Data(repeating: 0x51, count: 32)
        )
        jobs = try ArchiveEnrichmentJobStore(database: database)
        store = try ArchiveVectorStore(database: database)
        model = try ArchiveVectorModelIdentity(
            modelHash: Data(repeating: 0x11, count: 32),
            jobVersion: "mobileclip-s0-coreml-3e0a7bf+image-v1",
            producerName: "mobileclip-s0",
            producerSemanticVersion: "1.0.0+coreml.3e0a7bf.image-v1",
            preprocessingVersion: "srgb-aspectfill-bgra256-v1",
            dimension: 512
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    var primaryVector: [Float] {
        [0.6, 0.8] + [Float](repeating: 0, count: 510)
    }

    var alternateVector: [Float] {
        [0.8, 0.6] + [Float](repeating: 0, count: 510)
    }

    var thirdVector: [Float] {
        [0, 0, 1] + [Float](repeating: 0, count: 509)
    }

    func vector(seed: Int) -> [Float] {
        var values = [Float](repeating: 0, count: 512)
        values[seed % 512] = 1
        return values
    }

    func model(replacingHashByte byte: UInt8) throws -> ArchiveVectorModelIdentity {
        try ArchiveVectorModelIdentity(
            modelHash: Data(repeating: byte, count: 32),
            jobVersion: model.jobVersion,
            producerName: model.producerName,
            producerSemanticVersion: model.producerSemanticVersion,
            preprocessingVersion: model.preprocessingVersion,
            dimension: model.dimension
        )
    }

    func makeLeasedFrame(values: [Float]? = nil) throws -> VectorArchiveWork {
        frameSequence += 1
        let frameID = UUID()
        let epochID = UUID()
        let sourceHash = Data(SHA256.hash(data: Data("thumb-\(frameSequence)".utf8)))
        try seedFrame(frameID: frameID, epochID: epochID, sourceHash: sourceHash)
        let jobID = UUID()
        try jobs.enqueue(
            EnrichmentJobSeed(
                id: jobID,
                parentID: frameID,
                kind: .visualVector,
                priority: 500,
                producerVersion: model.jobVersion
            )
        )
        let lease = try XCTUnwrap(
            try jobs.leaseNext(
                now: now.addingTimeInterval(Double(frameSequence)),
                leaseDuration: 120,
                minimumPriority: 0,
                producerVersions: [.visualVector: model.jobVersion]
            )
        )
        XCTAssertEqual(lease.jobID, jobID)
        return VectorArchiveWork(
            frameID: frameID,
            epochID: epochID,
            lease: lease,
            sourceHash: sourceHash,
            values: values ?? primaryVector
        )
    }

    func makeReadyFrame(values: [Float]? = nil) throws -> VectorArchiveWork {
        let work = try makeLeasedFrame(values: values)
        _ = try store.stage(request(work))
        try jobs.succeed(work.lease)
        try store.finalize(work.lease, model: model)
        return work
    }

    func request(
        _ work: VectorArchiveWork,
        values: [Float]? = nil
    ) -> ArchiveVectorAppendRequest {
        ArchiveVectorAppendRequest(
            lease: work.lease,
            captureEpochID: work.epochID,
            targetWindowID: targetWindowID,
            policyGeneration: policyGeneration,
            sourceHash: work.sourceHash,
            model: model,
            values: values ?? work.values
        )
    }

    func markStale(_ frameID: UUID) throws {
        try database.atomicWrite { database in
            let id = frameID.uuidString.lowercased()
            try database.execute(
                sql: "UPDATE vector_offsets SET state = 'stale' WHERE frame_id = ?",
                arguments: [id]
            )
            try database.execute(
                sql:
                    "UPDATE artifacts SET state = 'stale' WHERE frame_id = ? AND kind = 'visualVector'",
                arguments: [id]
            )
            try database.execute(
                sql: "UPDATE frames SET visual_state = 'pending' WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func requeue(_ work: VectorArchiveWork, values: [Float]) throws -> VectorArchiveWork {
        try database.atomicWrite { database in
            try database.execute(
                sql:
                    "UPDATE processing_jobs SET state = 'queued', attempts = 0, next_attempt_at = NULL, error_code = NULL, lease_expires_at = NULL WHERE id = ?",
                arguments: [work.lease.jobID.uuidString.lowercased()]
            )
        }
        let lease = try XCTUnwrap(
            try jobs.leaseNext(
                now: now.addingTimeInterval(Double(frameSequence + 100)),
                leaseDuration: 120,
                minimumPriority: 0,
                producerVersions: [.visualVector: model.jobVersion]
            )
        )
        return VectorArchiveWork(
            frameID: work.frameID,
            epochID: work.epochID,
            lease: lease,
            sourceHash: work.sourceHash,
            values: values
        )
    }

    func frameVisualState(_ frameID: UUID) throws -> String? {
        try database.atomicRead { database in
            try String.fetchOne(
                database,
                sql: "SELECT visual_state FROM frames WHERE id = ?",
                arguments: [frameID.uuidString.lowercased()]
            )
        }
    }

    func vectorState(_ frameID: UUID) throws -> String? {
        try database.atomicRead { database in
            try String.fetchOne(
                database,
                sql: "SELECT state FROM vector_offsets WHERE frame_id = ?",
                arguments: [frameID.uuidString.lowercased()]
            )
        }
    }

    func vectorURL() throws -> URL {
        try XCTUnwrap(database.fileStore).url(for: model.relativePath)
    }

    func vectorFileSize() throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: vectorURL().path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).int64Value
    }

    func vectorFilePermissions() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: vectorURL().path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func seedFrame(frameID: UUID, epochID: UUID, sourceHash: Data) throws {
        let frame = frameID.uuidString.lowercased()
        let epoch = epochID.uuidString.lowercased()
        let chunk = UUID().uuidString.lowercased()
        let mediaPath = "media/2026/08/29/\(chunk)/frames/\(frame).heic"
        let thumbnailPath = "thumbnails/2026/08/29/\(frame).heic"
        try database.atomicWrite { database in
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES (?, ?, ?, ?, '2026-08-29T00:00:00.000Z',
                              '2026-08-29T00:00:01.000Z', 'heicKeyframes', 256, 256,
                              1, 128, ?, 'ready')
                    """,
                arguments: [
                    chunk, epoch, targetWindowID,
                    "media/2026/08/29/\(chunk)/manifest.json",
                    String(repeating: "b", count: 64),
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO frames(
                        id, captured_at, monotonic_ns, capture_epoch_id,
                        target_window_id, chunk_id, pts_ms, media_path,
                        media_sha256, media_byte_count, thumbnail_path,
                        capture_reason, is_transition, text_state, visual_state,
                        schema_version, approved_text, policy_generation
                    ) VALUES (?, '2026-08-29T00:00:00.500Z', ?, ?, ?, ?, 500, ?, ?,
                              128, ?, 'visualChange', 0, 'ready', 'pending', 2, '', ?)
                    """,
                arguments: [
                    frame, frameSequence * 1_000_000, epoch, targetWindowID, chunk,
                    mediaPath, String(repeating: "c", count: 64), thumbnailPath,
                    policyGeneration,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO artifacts(
                        id, frame_id, kind, producer_name, producer_version,
                        model_hash, locator_kind, locator_value, content_hash, state
                    ) VALUES (?, ?, 'thumbnail', 'thumbnail', '1.0.0', NULL,
                              'relativeFileOffset', ?, ?, 'ready')
                    """,
                arguments: [UUID().uuidString.lowercased(), frame, thumbnailPath, hex(sourceHash)]
            )
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
