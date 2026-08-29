import Foundation
import GRDB
import XCTest

@testable import MemoryStore

final class ArchiveForensicDeletionVerifierTests: XCTestCase {
    private let frameID = UUID(uuidString: "61000000-0000-4000-8000-000000000061")!
    private let sentinel = Data("lm061forensicsentinel".utf8)
    private let signingKey = Data(repeating: 0x61, count: 32)
    private let scannedAt = Date(timeIntervalSince1970: 1_777_681_000)

    func testCleanEncryptedArchiveProducesVerifiableContentFreeSignedReport() throws {
        let fixture = try makeFixture()
        try Data("benign-media".utf8).write(
            to: fixture.paths.media.appendingPathComponent("benign.bin")
        )
        let verifier = try ArchiveForensicDeletionVerifier(database: fixture.archive)

        let report = try verifier.verify(request())

        XCTAssertTrue(report.passed)
        XCTAssertTrue(report.checkpointAndVacuumCompleted)
        XCTAssertTrue(report.tombstoneIdentityMetadataExcluded)
        XCTAssertEqual(report.deletedIdentityCount, 1)
        XCTAssertEqual(report.sentinelCount, 1)
        XCTAssertEqual(report.signatureAlgorithm, "HMAC-SHA256")
        XCTAssertEqual(report.verificationHash.count, 64)
        XCTAssertEqual(report.signature.count, 64)
        XCTAssertTrue(
            ArchiveForensicDeletionVerifier.verifySignature(
                report,
                signingKey: signingKey
            )
        )
        XCTAssertFalse(try report.canonicalData().contains(sentinel))
        XCTAssertFalse(try report.canonicalData().contains(Data(frameID.encoded.utf8)))
        let walPath = fixture.paths.databaseFile.path + "-wal"
        let walSize = try FileManager.default.attributesOfItem(atPath: walPath)[.size] as? NSNumber
        XCTAssertEqual(walSize?.intValue, 0)
    }

    func testDetectsLogicalPhysicalHelperTemporaryAndProcessResidueBySurface() throws {
        let fixture = try makeFixture()
        try seedLogicalLeak(fixture.archive)
        for root in [
            fixture.paths.media,
            fixture.paths.thumbnails,
            fixture.paths.vectors,
            fixture.paths.logs,
            fixture.paths.exports,
            fixture.paths.quarantine,
        ] {
            try sentinel.write(to: root.appendingPathComponent(UUID().uuidString))
        }
        let codecTemporary = fixture.root.appendingPathComponent(
            "codec-temporary",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: codecTemporary,
            withIntermediateDirectories: true
        )
        try sentinel.write(to: codecTemporary.appendingPathComponent("frame.heic.partial"))
        let verifier = try ArchiveForensicDeletionVerifier(database: fixture.archive)
        let contaminated = request(
            helperProjections: [sentinel],
            codecTemporaryDirectories: [codecTemporary],
            activeProcessNames: ["memory-software-heic"]
        )

        let report = try verifier.verify(contaminated)

        XCTAssertFalse(report.passed)
        for surface in [
            "database.logicalContent",
            "media",
            "thumbnails",
            "vectors",
            "logs",
            "exports",
            "quarantine",
            "helperProjections",
            "codecTemporaryResidue",
            "codecProcesses",
        ] {
            XCTAssertGreaterThan(report.surfaces[surface]?.violationCount ?? 0, 0, surface)
        }
        XCTAssertTrue(
            ArchiveForensicDeletionVerifier.verifySignature(
                report,
                signingKey: signingKey
            )
        )
    }

    func testSignatureRejectsReportMutationWrongKeyAndSymbolicLinkFailsClosed() throws {
        let fixture = try makeFixture()
        let verifier = try ArchiveForensicDeletionVerifier(database: fixture.archive)
        let report = try verifier.verify(request())
        let mutated = ArchiveForensicDeletionReport(
            schemaVersion: report.schemaVersion,
            scannedAt: report.scannedAt,
            passed: false,
            deletedIdentityCount: report.deletedIdentityCount,
            sentinelCount: report.sentinelCount,
            surfaces: report.surfaces,
            checkpointAndVacuumCompleted: report.checkpointAndVacuumCompleted,
            tombstoneIdentityMetadataExcluded: report.tombstoneIdentityMetadataExcluded,
            verificationHash: report.verificationHash,
            signatureAlgorithm: report.signatureAlgorithm,
            signingKeyIdentity: report.signingKeyIdentity,
            signature: report.signature
        )
        XCTAssertFalse(
            ArchiveForensicDeletionVerifier.verifySignature(mutated, signingKey: signingKey)
        )
        XCTAssertFalse(
            ArchiveForensicDeletionVerifier.verifySignature(
                report,
                signingKey: Data(repeating: 0x62, count: 32)
            )
        )

        let outside = fixture.root.appendingPathComponent("outside")
        try sentinel.write(to: outside)
        let link = fixture.paths.logs.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try verifier.verify(request())) { error in
            XCTAssertEqual(
                error as? ArchiveForensicDeletionError,
                .symbolicLinkForbidden
            )
        }
    }

    private func request(
        helperProjections: [Data] = [],
        codecTemporaryDirectories: [URL] = [],
        activeProcessNames: [String] = []
    ) -> ArchiveForensicDeletionRequest {
        ArchiveForensicDeletionRequest(
            deletedFrameIDs: [frameID],
            sentinelValues: [sentinel],
            helperProjections: helperProjections,
            codecTemporaryDirectories: codecTemporaryDirectories,
            activeProcessNames: activeProcessNames,
            prohibitedCodecProcessNames: ["memory-software-heic", "VTEncoderXPCService"],
            signingKey: signingKey,
            scannedAt: scannedAt
        )
    }

    private func makeFixture() throws -> ForensicFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "deepshelves-lm061-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: root,
            encryptionKey: Data(repeating: 0x61, count: LM008StoreDefaults.keyByteCount)
        )
        return ForensicFixture(
            root: root,
            archive: archive,
            paths: try XCTUnwrap(archive.paths)
        )
    }

    private func seedLogicalLeak(_ archive: ArchiveDatabase) throws {
        let chunkID = "61000000-0000-4000-8000-000000000060"
        try archive.atomicWrite { database in
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES (?, 'epoch', 42, ?, '2026-08-29T00:00:00.000Z',
                              '2026-08-29T00:00:01.000Z', 'heicKeyframes', 1, 1,
                              1, 1, ?, 'ready')
                    """,
                arguments: [
                    chunkID,
                    "media/2026/08/29/\(chunkID)/manifest.json",
                    String(repeating: "a", count: 64),
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO frames(
                        id, captured_at, monotonic_ns, capture_epoch_id,
                        target_window_id, chunk_id, pts_ms, bundle_id, app_name,
                        window_title, capture_reason, is_transition, text_state,
                        visual_state, schema_version, approved_text
                    ) VALUES (?, '2026-08-29T00:00:00.000Z', 1, 'epoch', 42, ?, 0,
                              'com.example.leak', 'Leak', 'Leak', 'visualChange', 0,
                              'ready', 'ready', 1, ?)
                    """,
                arguments: [frameID.encoded, chunkID, String(data: sentinel, encoding: .utf8)!]
            )
            try database.execute(
                sql: """
                    INSERT INTO merged_text_records(
                        frame_id, approved_text, transcript_text, window_title,
                        app_name, url_host, url_path, producer_version, state
                    ) VALUES (?, ?, '', 'Leak', 'Leak', NULL, NULL, 'fixture', 'ready')
                    """,
                arguments: [frameID.encoded, String(data: sentinel, encoding: .utf8)!]
            )
        }
    }
}

private struct ForensicFixture {
    let root: URL
    let archive: ArchiveDatabase
    let paths: ArchivePaths
}

extension UUID {
    fileprivate var encoded: String { uuidString.lowercased() }
}
