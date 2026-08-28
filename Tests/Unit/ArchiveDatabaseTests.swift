@testable import MemoryStore
import XCTest

final class ArchiveDatabaseTests: XCTestCase {
    func testFreshBootstrapCreatesCompleteV1SchemaAndProductionPragmas() throws {
        let fixture = try TemporaryArchiveFixture(name: "fresh")
        defer { fixture.remove() }

        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )

        XCTAssertEqual(archive.paths?.databaseFile.lastPathComponent, "archive.sqlite3")
        XCTAssertEqual(Set(try archive.logicalTableNames()), ArchiveDatabase.v1LogicalTableNames)
        XCTAssertEqual(try archive.appliedMigrationIdentifiers(), ["v1_archive_schema"])
        XCTAssertEqual(try archive.archiveMetaValue(forKey: "schema_version"), "1")

        let configuration = try archive.configurationSnapshot()
        XCTAssertEqual(configuration.journalMode, "WAL")
        XCTAssertTrue(configuration.foreignKeysEnabled)
        XCTAssertEqual(configuration.tempStore, "FILE")
        XCTAssertEqual(configuration.temporaryDirectory, archive.paths?.database.path)

        let databaseFile = try XCTUnwrap(archive.paths?.databaseFile)
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseFile.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(
            permissions.intValue & 0o777,
            ArchivePathProvider.filePermissions
        )

        let schema = try archive.schemaSQL()
        XCTAssertTrue(schema.contains("CREATE VIRTUAL TABLE frame_fts USING fts5"))
        XCTAssertTrue(schema.contains("content='frames'"))
        XCTAssertTrue(schema.contains("ON DELETE CASCADE"))
        XCTAssertFalse(schema.localizedCaseInsensitiveContains("CREATE TRIGGER"))
    }

    func testVersionZeroArchiveMigratesForwardWithoutLosingReadableData() throws {
        let fixture = try TemporaryArchiveFixture(name: "forward")
        defer { fixture.remove() }
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )
        try ArchiveDatabase.createVersionZeroFixture(
            at: paths.databaseFile,
            marker: "version-zero-readable"
        )

        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )

        XCTAssertEqual(
            try archive.versionZeroMarkerForTesting(),
            "version-zero-readable"
        )
        XCTAssertEqual(try archive.appliedMigrationIdentifiers(), ["v1_archive_schema"])
        XCTAssertEqual(Set(try archive.logicalTableNames()), ArchiveDatabase.v1LogicalTableNames)
    }

    func testInterruptedMigrationRollsBackAndCanResumeExactlyOnce() throws {
        let fixture = try TemporaryArchiveFixture(name: "interrupted")
        defer { fixture.remove() }
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )

        XCTAssertThrowsError(
            try ArchiveDatabase.runInterruptedV1Migration(at: paths.databaseFile)
        ) { error in
            XCTAssertEqual(error as? ArchiveDatabaseError, .injectedMigrationInterruption)
        }

        let interrupted = try ArchiveDatabase.inspectUnencryptedDatabase(at: paths.databaseFile)
        XCTAssertEqual(interrupted.appliedMigrationIdentifiers, [])
        XCTAssertTrue(interrupted.logicalTableNames.isEmpty)

        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )
        XCTAssertEqual(try archive.appliedMigrationIdentifiers(), ["v1_archive_schema"])
        XCTAssertEqual(Set(try archive.logicalTableNames()), ArchiveDatabase.v1LogicalTableNames)

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport
        )
        XCTAssertEqual(try reopened.appliedMigrationIdentifiers(), ["v1_archive_schema"])
    }

    func testFrameDependentRowsCascadeAndForeignKeysRemainClean() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()

        let cascade = try archive.exerciseFrameCascadeForTesting()

        XCTAssertEqual(cascade.mediaChunks, 1)
        XCTAssertEqual(cascade.frames, 0)
        XCTAssertEqual(cascade.textSpans, 0)
        XCTAssertEqual(cascade.artifacts, 0)
        XCTAssertEqual(cascade.vectorOffsets, 0)
        XCTAssertEqual(cascade.foreignKeyViolations, 0)
    }

    func testDeterministicTestStoresHaveIdenticalSchemaAndSeedMetadata() throws {
        let first = try ArchiveDatabase.deterministicTestStore()
        let second = try ArchiveDatabase.deterministicTestStore()

        XCTAssertTrue(first.isDeterministicTestStore)
        XCTAssertTrue(second.isDeterministicTestStore)
        XCTAssertNil(first.paths)
        XCTAssertNil(second.paths)
        XCTAssertEqual(try first.schemaSQL(), try second.schemaSQL())
        XCTAssertEqual(try first.archiveMetaValue(forKey: "schema_version"), "1")
        XCTAssertEqual(try second.archiveMetaValue(forKey: "schema_version"), "1")
        XCTAssertTrue(try first.configurationSnapshot().foreignKeysEnabled)
    }

    func testArchiveKeyLengthFailsClosedBeforeOpeningDatabase() throws {
        let fixture = try TemporaryArchiveFixture(name: "key-length")
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try ArchiveDatabase(
                applicationSupportDirectory: fixture.applicationSupport,
                encryptionKey: Data(repeating: 0x17, count: 31)
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveDatabaseError, .invalidKeyLength)
        }
    }

    func testV1ColumnsMatchPlan10Contract() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let actual = try archive.v1ColumnNamesForTesting()
        let expected: [String: Set<String>] = [
            "archive_meta": ["key", "value"],
            "media_chunks": [
                "id", "capture_epoch_id", "target_window_id", "relative_path",
                "started_at", "ended_at", "codec", "width", "height",
                "frame_count", "byte_count", "sha256", "state",
            ],
            "frames": [
                "id", "captured_at", "monotonic_ns", "capture_epoch_id",
                "target_window_id", "chunk_id", "pts_ms", "thumbnail_path",
                "bundle_id", "app_name", "window_title", "window_x", "window_y",
                "window_w", "window_h", "browser_family", "url_scheme",
                "url_host", "url_path", "capture_reason", "is_transition",
                "text_state", "visual_state", "schema_version", "approved_text",
            ],
            "text_spans": [
                "id", "frame_id", "source", "text", "x", "y", "w", "h",
                "confidence", "language_code", "sensitivity",
            ],
            "frame_fts": [
                "approved_text", "window_title", "app_name", "url_host", "url_path",
            ],
            "artifacts": [
                "id", "frame_id", "kind", "producer_name", "producer_version",
                "model_hash", "locator_kind", "locator_value", "content_hash", "state",
            ],
            "vector_offsets": [
                "frame_id", "model_hash", "byte_offset", "dimension", "norm", "state",
            ],
            "activity_intervals": [
                "id", "started_at", "ended_at", "bundle_id", "app_name", "state",
                "gap_reason",
            ],
            "processing_jobs": [
                "id", "parent_id", "kind", "priority", "state", "attempts",
                "next_attempt_at", "producer_version", "error_code", "lease_expires_at",
            ],
            "policy_decisions": [
                "id", "decided_at", "bundle_id", "host", "private_context", "result",
                "matched_rule_id",
            ],
            "access_policies": [
                "id", "encoded_policy", "expires_at", "created_by_user",
            ],
            "deletion_tombstones": ["id", "encoded_tombstone", "state"],
            "audit_events": [
                "id", "occurred_at", "actor", "action", "policy_id", "result_count",
                "query_hash",
            ],
        ]

        XCTAssertEqual(Set(actual.keys), ArchiveDatabase.v1LogicalTableNames)
        for (table, columns) in expected {
            XCTAssertEqual(Set(actual[table] ?? []), columns, "columns for \(table)")
        }
    }

}

private struct TemporaryArchiveFixture {
    let root: URL
    let applicationSupport: URL

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "lm017-\(name)-\(UUID().uuidString)",
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
