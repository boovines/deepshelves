import GRDB
import XCTest

@testable import MemoryStore

final class ArchiveMomentSourceStoreTests: XCTestCase {
    func testTrustedTimelineLookupReturnsTheExactCurrentReadyLocator() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let frameID = UUID(uuidString: "43000000-0000-4000-8000-000000000002")!
        let path = try seedReadySource(archive, frameID: frameID)

        let record = try ArchiveMomentSourceStore(database: archive).readySource(frameID: frameID)

        XCTAssertEqual(record.frameID, frameID)
        XCTAssertEqual(record.mediaPath, path)
        XCTAssertEqual(
            record.captureEpochID.uuidString.lowercased(), "43000000-0000-4000-8000-000000000010")
        XCTAssertEqual(record.targetWindowID, 42)
    }

    func testReadySourceRequiresTheExactSearchResultLocatorAndCurrentReadyIdentity() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let frameID = UUID(uuidString: "43000000-0000-4000-8000-000000000001")!
        let path = try seedReadySource(archive, frameID: frameID)
        let store = ArchiveMomentSourceStore(database: archive)

        let record = try store.readySource(frameID: frameID, expectedPath: path)

        XCTAssertEqual(record.frameID, frameID)
        XCTAssertEqual(record.mediaPath, path)
        XCTAssertEqual(record.mediaByteCount, 4)
        XCTAssertEqual(record.mediaHash, Data(repeating: 0xAA, count: 32))
        XCTAssertEqual(record.policyGeneration, 7)

        XCTAssertThrowsError(
            try store.readySource(
                frameID: frameID,
                expectedPath: ArchiveRelativePath(
                    "media/wrong/frames/\(frameID.uuidString.lowercased()).heic")
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveMomentSourceError, .locatorMismatch)
        }

        try archive.atomicWrite { database in
            try database.execute(
                sql:
                    "UPDATE frames SET visual_state = 'suppressed', text_state = 'suppressed' WHERE id = ?",
                arguments: [frameID.uuidString.lowercased()]
            )
        }
        XCTAssertThrowsError(try store.readySource(frameID: frameID, expectedPath: path)) {
            XCTAssertEqual($0 as? ArchiveMomentSourceError, .sourceUnavailable)
        }
    }

    private func seedReadySource(
        _ archive: ArchiveDatabase,
        frameID: UUID
    ) throws -> ArchiveRelativePath {
        let frame = frameID.uuidString.lowercased()
        let epoch = "43000000-0000-4000-8000-000000000010"
        let chunk = "43000000-0000-4000-8000-000000000020"
        let path = try ArchiveRelativePath("media/2026/08/29/\(chunk)/frames/\(frame).heic")
        try archive.atomicWrite { database in
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES (?, ?, 42, ?, '2026-08-29T00:00:00.000Z',
                              '2026-08-29T00:00:01.000Z', 'heicKeyframes', 1, 1,
                              1, 4, ?, 'ready')
                    """,
                arguments: [
                    chunk, epoch, "media/2026/08/29/\(chunk)/manifest.json",
                    String(repeating: "b", count: 64),
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO frames(
                        id, captured_at, monotonic_ns, capture_epoch_id,
                        target_window_id, chunk_id, pts_ms, media_path,
                        media_sha256, media_byte_count, capture_reason,
                        is_transition, text_state, visual_state, schema_version,
                        approved_text, policy_generation
                    ) VALUES (?, '2026-08-29T00:00:00.500Z', 500000000, ?, 42, ?,
                              500, ?, ?, 4, 'visualChange', 0, 'ready', 'ready', 2, '', 7)
                    """,
                arguments: [frame, epoch, chunk, path.rawValue, String(repeating: "aa", count: 32)]
            )
        }
        return path
    }
}
