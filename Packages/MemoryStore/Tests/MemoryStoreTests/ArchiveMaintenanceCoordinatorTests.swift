import CryptoKit
import Foundation
import GRDB
import MemoryContracts
import XCTest

@testable import MemoryStore

final class ArchiveMaintenanceCoordinatorTests: XCTestCase {
    private let createdAt = Date(timeIntervalSince1970: 1_777_680_000)

    func testExplicitExportContainsOnlySelectedPolicyBoundOriginalEvidence() throws {
        let fixture = try makeFixture()
        let first = try seedChunk(fixture, suffix: 1, frameCount: 2)
        let second = try seedChunk(fixture, suffix: 2, frameCount: 1)
        let coordinator = try ArchiveMaintenanceCoordinator(database: fixture.archive)
        let scope = try ArchiveExportScope(
            selectedFrameIDs: [first.frames[0].id, second.frames[0].id],
            allowedInterval: DateInterval(
                start: createdAt.addingTimeInterval(-60),
                end: createdAt.addingTimeInterval(60)
            ),
            allowedBundleIdentifiers: ["com.example.allowed"],
            allowedHosts: ["example.com"],
            includeOriginalEvidence: true,
            confirmedByUser: true
        )

        let receipt = try coordinator.export(
            scope: scope,
            exportID: stableUUID(62_100),
            createdAt: createdAt
        )

        XCTAssertEqual(receipt.exportedFrameCount, 2)
        XCTAssertEqual(receipt.manifest.entries.map(\.frameID), scope.selectedFrameIDs)
        XCTAssertEqual(Set(receipt.manifest.files.map(\.relativePath)).count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.root.path))
        let manifestData = try Data(
            contentsOf: receipt.root.appendingPathComponent("manifest.json"))
        XCTAssertEqual(
            try JSONDecoder.archiveMaintenance.decode(
                ArchiveExportManifest.self, from: manifestData),
            receipt.manifest
        )
        for file in receipt.manifest.files {
            let data = try Data(contentsOf: receipt.root.appendingPathComponent(file.relativePath))
            XCTAssertEqual(data.count, file.byteCount)
            XCTAssertEqual(Data(SHA256.hash(data: data)).lowercaseHex, file.sha256)
        }
        let exportedTree = try serializedTree(receipt.root)
        XCTAssertTrue(exportedTree.contains(first.frames[0].searchText))
        XCTAssertTrue(exportedTree.contains(second.frames[0].searchText))
        XCTAssertFalse(exportedTree.contains(first.frames[1].searchText))
        XCTAssertFalse(exportedTree.contains(String(data: first.frames[1].bytes, encoding: .utf8)!))
    }

    func testExportFailsClosedForUnconfirmedOutOfPolicyOrCorruptSource() throws {
        let fixture = try makeFixture()
        let chunk = try seedChunk(fixture, suffix: 3, frameCount: 1)
        let coordinator = try ArchiveMaintenanceCoordinator(database: fixture.archive)
        let base = try ArchiveExportScope(
            selectedFrameIDs: [chunk.frames[0].id],
            allowedInterval: DateInterval(
                start: createdAt.addingTimeInterval(-60),
                end: createdAt.addingTimeInterval(60)
            ),
            allowedBundleIdentifiers: ["com.example.allowed"],
            allowedHosts: ["example.com"],
            includeOriginalEvidence: true,
            confirmedByUser: true
        )
        let unconfirmed = try ArchiveExportScope(
            selectedFrameIDs: base.selectedFrameIDs,
            allowedInterval: base.allowedInterval,
            allowedBundleIdentifiers: base.allowedBundleIdentifiers,
            allowedHosts: base.allowedHosts,
            includeOriginalEvidence: true,
            confirmedByUser: false
        )
        XCTAssertThrowsError(
            try coordinator.export(
                scope: unconfirmed, exportID: stableUUID(62_101), createdAt: createdAt)
        ) { XCTAssertEqual($0 as? ArchiveMaintenanceError, .confirmationRequired) }

        let wrongPolicy = try ArchiveExportScope(
            selectedFrameIDs: base.selectedFrameIDs,
            allowedInterval: base.allowedInterval,
            allowedBundleIdentifiers: ["com.example.denied"],
            allowedHosts: base.allowedHosts,
            includeOriginalEvidence: true,
            confirmedByUser: true
        )
        XCTAssertThrowsError(
            try coordinator.export(
                scope: wrongPolicy, exportID: stableUUID(62_102), createdAt: createdAt)
        ) { XCTAssertEqual($0 as? ArchiveMaintenanceError, .policyDenied) }

        try Data("corrupt".utf8).write(to: chunk.frames[0].source)
        XCTAssertThrowsError(
            try coordinator.export(scope: base, exportID: stableUUID(62_103), createdAt: createdAt)
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.paths.exports.path), [])
    }

    func testOriginalEvidenceExportDoesNotRequireAReadyTextDerivative() throws {
        let fixture = try makeFixture()
        let chunk = try seedChunk(fixture, suffix: 5, frameCount: 1)
        try fixture.archive.atomicWrite { database in
            try database.execute(
                sql: "DELETE FROM merged_text_records WHERE frame_id = ?",
                arguments: [chunk.frames[0].id.encoded]
            )
            try database.execute(
                sql: "UPDATE frames SET text_state = 'suppressed' WHERE id = ?",
                arguments: [chunk.frames[0].id.encoded]
            )
        }
        let scope = try ArchiveExportScope(
            selectedFrameIDs: [chunk.frames[0].id],
            allowedInterval: DateInterval(
                start: createdAt.addingTimeInterval(-60),
                end: createdAt.addingTimeInterval(60)
            ),
            allowedBundleIdentifiers: ["com.example.allowed"],
            allowedHosts: ["example.com"],
            includeOriginalEvidence: true,
            confirmedByUser: true
        )

        let receipt = try ArchiveMaintenanceCoordinator(database: fixture.archive).export(
            scope: scope,
            exportID: stableUUID(62_104),
            createdAt: createdAt
        )

        XCTAssertEqual(receipt.exportedFrameCount, 1)
        let metadata = try Data(contentsOf: receipt.root.appendingPathComponent("metadata.jsonl"))
        XCTAssertFalse(metadata.contains(Data(chunk.frames[0].searchText.utf8)))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: receipt.root.appendingPathComponent(
                    try XCTUnwrap(receipt.manifest.entries[0].evidenceRelativePath)
                ).path
            )
        )
    }

    func testIntegrityDetectsCorruptionAndRepairQuarantinesWithoutInventingData() throws {
        let fixture = try makeFixture()
        let chunk = try seedChunk(fixture, suffix: 4, frameCount: 1)
        let coordinator = try ArchiveMaintenanceCoordinator(database: fixture.archive)
        XCTAssertTrue(try coordinator.integrityCheck().passed)

        try Data("corrupt".utf8).write(to: chunk.frames[0].source)
        let failed = try coordinator.integrityCheck()
        XCTAssertFalse(failed.passed)
        XCTAssertEqual(failed.issues.map(\.code), ["ready_chunk_integrity"])

        let repair = try coordinator.repair()

        XCTAssertEqual(repair.recovery.quarantinedCorruptFiles, 1)
        XCTAssertTrue(repair.postRepairIntegrity.passed)
        XCTAssertEqual(try frameState(fixture.archive, chunk.frames[0].id), "suppressed:suppressed")
        XCTAssertEqual(try searchCount(fixture.archive, chunk.frames[0].searchText), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chunk.directory.path))
        XCTAssertEqual(try coordinator.quarantineReview().count, 1)
    }

    func testIntegrityFailsClosedForMalformedReadyChunkRecord() throws {
        let fixture = try makeFixture()
        try fixture.archive.atomicWrite { database in
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES ('malformed', 'malformed', 42,
                              'media/2026/08/29/malformed/manifest.json',
                              '2026-08-29T00:00:00.000Z', '2026-08-29T00:00:01.000Z',
                              'heicKeyframes', 1, 1, 0, 0, NULL, 'ready')
                    """
            )
        }

        let report = try ArchiveMaintenanceCoordinator(database: fixture.archive).integrityCheck()

        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.checkedReadyChunkCount, 1)
        XCTAssertEqual(report.issues.map(\.code), ["ready_chunk_record"])
    }

    func testQuarantineReviewIsContentFreeDeterministicAndRejectsSymlinks() throws {
        let fixture = try makeFixture()
        let coordinator = try ArchiveMaintenanceCoordinator(database: fixture.archive)
        let payload = Data("private-quarantine-content".utf8)
        let item = fixture.paths.quarantine.appendingPathComponent("integrity-fixture.bin")
        try payload.write(to: item)

        let review = try coordinator.quarantineReview()

        XCTAssertEqual(review.count, 1)
        XCTAssertEqual(review[0].reason, "integrity")
        XCTAssertEqual(review[0].byteCount, payload.count)
        XCTAssertEqual(review[0].sha256, Data(SHA256.hash(data: payload)).lowercaseHex)
        XCTAssertFalse(try JSONEncoder.archiveMaintenance.encode(review).contains(payload))

        let outside = fixture.root.appendingPathComponent("outside")
        try payload.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.quarantine.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try coordinator.quarantineReview())
    }

    private func makeFixture() throws -> MaintenanceFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deepshelves-lm062-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: root,
            encryptionKey: Data(repeating: 0x62, count: LM008StoreDefaults.keyByteCount)
        )
        return MaintenanceFixture(
            root: root,
            archive: archive,
            paths: try XCTUnwrap(archive.paths)
        )
    }

    private func seedChunk(
        _ fixture: MaintenanceFixture,
        suffix: Int,
        frameCount: Int
    ) throws -> MaintenanceChunk {
        let chunkID = stableUUID(62_200 + suffix)
        let epochID = stableUUID(62_300 + suffix)
        let relativeDirectory = "media/2026/08/29/\(chunkID.encoded)"
        let directory = fixture.paths.root.appendingPathComponent(relativeDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [HEICKeyframeEntry] = []
        var frames: [MaintenanceFrame] = []
        for index in 0..<frameCount {
            let frameID = stableUUID(62_400 + suffix * 10 + index)
            let bytes = Data("original-evidence-\(suffix)-\(index)".utf8)
            let relativePath = "frames/\(frameID.encoded).heic"
            let source = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: source)
            entries.append(
                try HEICKeyframeEntry(
                    frameID: frameID,
                    presentationTimeMS: Int64(index * 500),
                    relativePath: relativePath,
                    byteCount: Int64(bytes.count),
                    sha256: Data(SHA256.hash(data: bytes))
                )
            )
            frames.append(
                MaintenanceFrame(
                    id: frameID,
                    bytes: bytes,
                    source: source,
                    searchText: "lm062searchsentinel\(suffix)x\(index)"
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
        let manifestData = try ContractJSON.encode(manifest)
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"))
        let totalBytes = entries.reduce(Int64(manifestData.count)) { $0 + $1.byteCount }
        try fixture.archive.atomicWrite { database in
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
                    encode(createdAt.addingTimeInterval(Double(suffix))),
                    encode(createdAt.addingTimeInterval(Double(suffix) + 1)),
                    frameCount,
                    totalBytes,
                    Data(SHA256.hash(data: manifestData)).lowercaseHex,
                ]
            )
            for (index, frame) in frames.enumerated() {
                try database.execute(
                    sql: """
                        INSERT INTO frames(
                            id, captured_at, monotonic_ns, capture_epoch_id,
                            target_window_id, chunk_id, pts_ms, bundle_id, app_name,
                            window_title, browser_family, url_scheme, url_host, url_path,
                            capture_reason, is_transition, text_state, visual_state,
                            schema_version, approved_text, media_path, media_sha256,
                            media_byte_count, policy_generation
                        ) VALUES (?, ?, ?, ?, 42, ?, ?, 'com.example.allowed',
                                  'Allowed App', 'Allowed Window', 'chrome', 'https',
                                  'example.com', '/safe', 'visualChange', 0, 'ready',
                                  'ready', 2, ?, ?, ?, ?, 7)
                        """,
                    arguments: [
                        frame.id.encoded,
                        encode(createdAt.addingTimeInterval(Double(suffix + index))),
                        suffix * 10 + index,
                        epochID.encoded,
                        chunkID.encoded,
                        index * 500,
                        frame.searchText,
                        "\(relativeDirectory)/frames/\(frame.id.encoded).heic",
                        entries[index].sha256.lowercaseHex,
                        entries[index].byteCount,
                    ]
                )
                try database.execute(
                    sql: """
                        INSERT INTO merged_text_records(
                            frame_id, approved_text, transcript_text, window_title,
                            app_name, url_host, url_path, producer_version, state
                        ) VALUES (?, ?, '', 'Allowed Window', 'Allowed App',
                                  'example.com', '/safe', 'lm062-fixture', 'ready')
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
            }
        }
        return MaintenanceChunk(directory: directory, frames: frames)
    }

    private func serializedTree(_ root: URL) throws -> String {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        var bytes = Data()
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                bytes.append(try Data(contentsOf: url))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func frameState(_ archive: ArchiveDatabase, _ frameID: UUID) throws -> String? {
        try archive.atomicRead { database in
            try String.fetchOne(
                database,
                sql: "SELECT text_state || ':' || visual_state FROM frames WHERE id = ?",
                arguments: [frameID.encoded]
            )
        }
    }

    private func searchCount(_ archive: ArchiveDatabase, _ query: String) throws -> Int {
        try archive.atomicRead { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM frame_fts WHERE frame_fts MATCH ?",
                arguments: [query]
            ) ?? 0
        }
    }

    private func stableUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "62000000-0000-4000-8000-%012d", value))!
    }

    private func encode(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
    }
}

private struct MaintenanceFixture {
    let root: URL
    let archive: ArchiveDatabase
    let paths: ArchivePaths
}

private struct MaintenanceChunk {
    let directory: URL
    let frames: [MaintenanceFrame]
}

private struct MaintenanceFrame {
    let id: UUID
    let bytes: Data
    let source: URL
    let searchText: String
}

extension UUID {
    fileprivate var encoded: String { uuidString.lowercased() }
}

extension Data {
    fileprivate var lowercaseHex: String { map { String(format: "%02x", $0) }.joined() }
}
