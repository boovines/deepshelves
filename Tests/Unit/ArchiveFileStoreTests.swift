@testable import MemoryStore
import CryptoKit
import XCTest

final class ArchiveFileStoreTests: XCTestCase {
    func testRelativePathsFailClosedOnTraversalAbsoluteAndUnmanagedRoots() throws {
        let invalidPaths = [
            "",
            "/media/chunk.mov",
            "~/media/chunk.mov",
            "media/../chunk.mov",
            "media//chunk.mov",
            "media/./chunk.mov",
            "media\\chunk.mov",
            "media/chunk.mov\0escape",
            "media/chunk.mov.partial",
            "database/archive.sqlite3",
            "quarantine/manual.mov",
        ]

        for path in invalidPaths {
            XCTAssertThrowsError(try ArchiveRelativePath(path), path)
        }

        XCTAssertEqual(
            try ArchiveRelativePath("media/2026/08/28/chunk.mov").rawValue,
            "media/2026/08/28/chunk.mov"
        )
        XCTAssertEqual(
            try ArchiveRelativePath("vectors/mobileclip-s0/model.f16").rawValue,
            "vectors/mobileclip-s0/model.f16"
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ArchiveRelativePath.self,
                from: Data("\"../decoded-escape.mov\"".utf8)
            )
        )
    }

    func testWriterRejectsSymlinkParentWithoutTouchingExternalTarget() throws {
        let fixture = try LM018ArchiveFixture(name: "symlink")
        defer { fixture.remove() }
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let external = fixture.root.appending(path: "external", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let linkedParent = paths.media.appending(path: "linked", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: external)
        let store = ArchiveFileStore(paths: paths)
        let path = try ArchiveRelativePath("media/linked/escape.mov")

        XCTAssertThrowsError(try store.write(Data("must stay local".utf8), to: path)) { error in
            guard case .symbolicLinkForbidden = error as? ArchiveFileStoreError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appending(path: "escape.mov").path))
    }

    func testAtomicWriterFsyncsHashesAndCreatesOwnerOnlyFinal() throws {
        let fixture = try LM018ArchiveFixture(name: "atomic")
        defer { fixture.remove() }
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let store = ArchiveFileStore(paths: paths)
        let path = try ArchiveRelativePath("media/2026/08/28/atomic.mov")
        let payload = Data("approved foreground fixture".utf8)
        var committedIntegrity: ArchiveFileIntegrity?

        let integrity = try store.write(payload, to: path) { committedIntegrity = $0 }

        XCTAssertEqual(committedIntegrity, integrity)
        XCTAssertEqual(integrity.relativePath, path)
        XCTAssertEqual(integrity.byteCount, Int64(payload.count))
        XCTAssertEqual(integrity.sha256, Data(SHA256.hash(data: payload)))
        XCTAssertEqual(try Data(contentsOf: store.url(for: path)), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.partialURL(for: path).path))
        assertPermissions(store.url(for: path), equal: 0o600)
        assertPermissions(store.url(for: path).deletingLastPathComponent(), equal: 0o700)
    }

    func testCrashBeforeRenameLeavesOnlyPartialWhichStartupRemoves() throws {
        let fixture = try LM018ArchiveFixture(name: "before-rename")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let store = try XCTUnwrap(archive.fileStore)
        let path = try ArchiveRelativePath("media/2026/08/28/before.mov")

        XCTAssertThrowsError(
            try store.write(Data("partial".utf8), to: path, fault: .beforeRename)
        ) { error in
            XCTAssertEqual(error as? ArchiveFileStoreError, .injectedFault(.beforeRename))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.partialURL(for: path).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: path).path))

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )

        XCTAssertEqual(reopened.startupRecoveryReport.removedPartialFiles, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.partialURL(for: path).path))
        XCTAssertEqual(try reopened.searchableFrameCountForTesting(), 0)
    }

    func testCrashAfterRenameBeforeCommitQuarantinesOrphanFinal() throws {
        let fixture = try LM018ArchiveFixture(name: "after-rename")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let store = try XCTUnwrap(archive.fileStore)
        let path = try ArchiveRelativePath("media/2026/08/28/orphan.mov")

        XCTAssertThrowsError(
            try store.write(Data("ready but uncommitted".utf8), to: path, fault: .afterRenameBeforeCommit)
        ) { error in
            XCTAssertEqual(
                error as? ArchiveFileStoreError,
                .injectedFault(.afterRenameBeforeCommit)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: path).path))

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )

        XCTAssertEqual(reopened.startupRecoveryReport.quarantinedOrphanFiles, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: path).path))
        XCTAssertEqual(try regularFileCount(in: try XCTUnwrap(reopened.paths).quarantine), 1)
        XCTAssertEqual(try reopened.searchableFrameCountForTesting(), 0)
    }

    func testValidCommittedFileRemainsReadyAndSearchableAcrossStartup() throws {
        let fixture = try LM018ArchiveFixture(name: "valid")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let store = try XCTUnwrap(archive.fileStore)
        let path = try ArchiveRelativePath("media/2026/08/28/valid.mov")

        _ = try store.write(Data("valid ready media".utf8), to: path) { integrity in
            try archive.insertReadyMediaFixtureForTesting(
                chunkID: "valid-chunk",
                frameID: "valid-frame",
                integrity: integrity
            )
        }
        XCTAssertEqual(try archive.searchableFrameCountForTesting(), 1)

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )

        XCTAssertEqual(reopened.startupRecoveryReport.quarantinedCorruptFiles, 0)
        XCTAssertEqual(reopened.startupRecoveryReport.quarantinedOrphanFiles, 0)
        XCTAssertEqual(try reopened.mediaChunkStateForTesting(id: "valid-chunk"), "ready")
        XCTAssertEqual(try reopened.searchableFrameCountForTesting(), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: path).path))
    }

    func testHashMismatchQuarantinesFinalAndSuppressesSearchProjection() throws {
        let fixture = try LM018ArchiveFixture(name: "hash-mismatch")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let store = try XCTUnwrap(archive.fileStore)
        let path = try ArchiveRelativePath("media/2026/08/28/corrupt.mov")

        _ = try store.write(Data("original".utf8), to: path) { integrity in
            try archive.insertReadyMediaFixtureForTesting(
                chunkID: "corrupt-chunk",
                frameID: "corrupt-frame",
                integrity: integrity
            )
        }
        try Data("tampered".utf8).write(to: store.url(for: path))

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )

        XCTAssertEqual(reopened.startupRecoveryReport.quarantinedCorruptFiles, 1)
        XCTAssertEqual(try reopened.mediaChunkStateForTesting(id: "corrupt-chunk"), "quarantined")
        XCTAssertEqual(try reopened.searchableFrameCountForTesting(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: path).path))
        XCTAssertEqual(try regularFileCount(in: try XCTUnwrap(reopened.paths).quarantine), 1)
    }

    func testMissingReadyFileAndInterruptedLeaseRecoverFailClosed() throws {
        let fixture = try LM018ArchiveFixture(name: "missing")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let missingPath = try ArchiveRelativePath("media/2026/08/28/missing.mov")
        try archive.insertMissingReadyMediaFixtureForTesting(
            chunkID: "missing-chunk",
            frameID: "missing-frame",
            relativePath: missingPath
        )
        try archive.insertLeasedJobFixtureForTesting(id: "interrupted-job")

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )

        XCTAssertEqual(reopened.startupRecoveryReport.missingReadyFiles, 1)
        XCTAssertEqual(reopened.startupRecoveryReport.requeuedLeasedJobs, 1)
        XCTAssertEqual(try reopened.mediaChunkStateForTesting(id: "missing-chunk"), "quarantined")
        XCTAssertEqual(try reopened.processingJobStateForTesting(id: "interrupted-job"), "queued")
        XCTAssertEqual(try reopened.searchableFrameCountForTesting(), 0)
    }

    func testReopenRepairsOwnerOnlyPermissionsRecursively() throws {
        let fixture = try LM018ArchiveFixture(name: "permissions")
        defer { fixture.remove() }
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )
        let nested = paths.exports.appending(path: "fixture/report.json")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: nested)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.deletingLastPathComponent().path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nested.path)

        _ = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )

        assertPermissions(nested.deletingLastPathComponent(), equal: 0o700)
        assertPermissions(nested, equal: 0o600)
    }

    private func assertPermissions(
        _ url: URL,
        equal expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, expected, file: file, line: line)
        } catch {
            XCTFail("Unable to inspect permissions for \(url.path): \(error)", file: file, line: line)
        }
    }

    private func regularFileCount(in root: URL) throws -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return 0
        }
        return try enumerator.reduce(into: 0) { count, value in
            guard let url = value as? URL else { return }
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                count += 1
            }
        }
    }
}

private struct LM018ArchiveFixture {
    let root: URL
    let applicationSupport: URL

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "lm018-\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        applicationSupport = root.appending(
            path: "Application Support",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
