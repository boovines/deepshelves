import CryptoKit
import MemoryContracts
import XCTest

@testable import MemoryStore

final class ArchiveDatabaseTests: XCTestCase {
    func testFreshBootstrapCreatesCompleteV2SchemaAndProductionPragmas() throws {
        let fixture = try TemporaryArchiveFixture(name: "fresh")
        defer { fixture.remove() }

        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )

        XCTAssertEqual(archive.paths?.databaseFile.lastPathComponent, "archive.sqlite3")
        XCTAssertEqual(Set(try archive.logicalTableNames()), ArchiveDatabase.v1LogicalTableNames)
        XCTAssertEqual(
            try archive.appliedMigrationIdentifiers(),
            ["v1_archive_schema", "v2_heic_frame_locators", "v3_merged_text_fts"]
        )
        XCTAssertEqual(try archive.archiveMetaValue(forKey: "schema_version"), "3")

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
        XCTAssertTrue(schema.contains("content='merged_text_records'"))
        XCTAssertTrue(schema.contains("transcript_text"))
        XCTAssertTrue(schema.contains("ON DELETE CASCADE"))
        XCTAssertTrue(schema.contains("CREATE TRIGGER frames_v2_locator_insert"))
        XCTAssertTrue(schema.contains("CREATE TRIGGER frames_v2_locator_update"))
    }

    func testVersionZeroArchiveMigratesForwardWithoutLosingReadableData() throws {
        let fixture = try TemporaryArchiveFixture(name: "forward")
        defer { fixture.remove() }
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )
        try ArchiveDatabase.createVersionZeroFixture(
            at: paths.databaseFile,
            encryptionKey: fixture.encryptionKey,
            marker: "version-zero-readable"
        )

        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )

        XCTAssertEqual(
            try archive.versionZeroMarkerForTesting(),
            "version-zero-readable"
        )
        XCTAssertEqual(
            try archive.appliedMigrationIdentifiers(),
            ["v1_archive_schema", "v2_heic_frame_locators", "v3_merged_text_fts"]
        )
        XCTAssertEqual(Set(try archive.logicalTableNames()), ArchiveDatabase.v1LogicalTableNames)
    }

    func testInterruptedMigrationRollsBackAndCanResumeExactlyOnce() throws {
        let fixture = try TemporaryArchiveFixture(name: "interrupted")
        defer { fixture.remove() }
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: fixture.applicationSupport
        )

        XCTAssertThrowsError(
            try ArchiveDatabase.runInterruptedV1Migration(
                at: paths.databaseFile,
                encryptionKey: fixture.encryptionKey
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveDatabaseError, .injectedMigrationInterruption)
        }

        let interrupted = try ArchiveDatabase.inspectDatabase(
            at: paths.databaseFile,
            encryptionKey: fixture.encryptionKey
        )
        XCTAssertEqual(interrupted.appliedMigrationIdentifiers, [])
        XCTAssertTrue(interrupted.logicalTableNames.isEmpty)

        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        XCTAssertEqual(
            try archive.appliedMigrationIdentifiers(),
            ["v1_archive_schema", "v2_heic_frame_locators", "v3_merged_text_fts"]
        )
        XCTAssertEqual(Set(try archive.logicalTableNames()), ArchiveDatabase.v1LogicalTableNames)

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        XCTAssertEqual(
            try reopened.appliedMigrationIdentifiers(),
            ["v1_archive_schema", "v2_heic_frame_locators", "v3_merged_text_fts"]
        )
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
        XCTAssertEqual(try first.archiveMetaValue(forKey: "schema_version"), "3")
        XCTAssertEqual(try second.archiveMetaValue(forKey: "schema_version"), "3")
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

    func testCurrentColumnsMatchPlan10ContractAndRetainV1Fields() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let actual = try archive.currentColumnNamesForTesting()
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
                "media_path", "media_sha256", "media_byte_count", "policy_generation",
            ],
            "text_spans": [
                "id", "frame_id", "source", "text", "x", "y", "w", "h",
                "confidence", "language_code", "sensitivity",
            ],
            "merged_text_records": [
                "frame_id", "approved_text", "transcript_text", "window_title",
                "app_name", "url_host", "url_path", "producer_version", "state",
            ],
            "frame_fts": [
                "approved_text", "window_title", "app_name", "url_host", "url_path",
                "transcript_text",
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

    func testV2MigrationIsAppendOnlyAndRequiresExactCanonicalFrameLocators() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()

        XCTAssertEqual(
            try archive.appliedMigrationIdentifiers(),
            ["v1_archive_schema", "v2_heic_frame_locators", "v3_merged_text_fts"]
        )
        XCTAssertEqual(try archive.archiveMetaValue(forKey: "schema_version"), "3")
        XCTAssertEqual(try archive.archiveMetaValue(forKey: "contract_version"), "2")
        let columns = try archive.frameColumnNamesForTesting()
        XCTAssertTrue(columns.contains("media_path"))
        XCTAssertTrue(columns.contains("media_sha256"))
        XCTAssertTrue(columns.contains("media_byte_count"))
        XCTAssertTrue(columns.contains("policy_generation"))
        XCTAssertNoThrow(try archive.insertLegacyV1FrameForTesting())
        XCTAssertThrowsError(try archive.insertInvalidV2FrameForTesting())
    }

    func testAtomicCoordinatorCommitsVerifiedHEICFramesAndRetryableJobsTogether() throws {
        let fixture = try TemporaryArchiveFixture(name: "v2-atomic")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        let identity = ArchiveCaptureIdentity(
            captureEpochID: UUID(),
            targetWindowID: 42,
            policyGeneration: 7
        )
        let published = try makePublishedHEICFixture(
            archive: archive,
            identity: identity,
            payloads: [Data("first-approved".utf8), Data("second-approved".utf8)]
        )
        let coordinator = try ArchiveAtomicCoordinator(database: archive)

        let result = try coordinator.commit(
            manifestRelativePath: published.manifestPath,
            authorization: ArchiveCaptureAuthorization(identity: identity, isAllowed: true),
            frames: published.frames,
            jobs: published.frames.map {
                ArchiveRetryableJob(
                    id: UUID(),
                    frameID: $0.id,
                    kind: "vision-ocr",
                    priority: 10,
                    producerVersion: "fixture-v1"
                )
            },
            currentIdentity: { identity }
        )

        XCTAssertEqual(result.chunkID, published.manifest.chunkID)
        XCTAssertEqual(result.committedFrameCount, 2)
        XCTAssertEqual(result.queuedJobCount, 2)
        let snapshot = try archive.v2CoordinatorSnapshotForTesting(chunkID: result.chunkID)
        XCTAssertEqual(snapshot.chunkState, "ready")
        XCTAssertEqual(snapshot.frameCount, 2)
        XCTAssertEqual(snapshot.queuedJobCount, 2)
        XCTAssertEqual(snapshot.distinctEpochCount, 1)
        XCTAssertEqual(snapshot.distinctTargetCount, 1)
        XCTAssertEqual(snapshot.distinctPolicyGenerationCount, 1)
        XCTAssertEqual(Set(snapshot.mediaPaths), Set(published.frames.map(\.mediaPath)))
    }

    func testFocusOrPolicyRacePersistsNoRowsAndPublishedDirectoryReconcilesDeterministically()
        throws
    {
        let fixture = try TemporaryArchiveFixture(name: "v2-race")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        let identity = ArchiveCaptureIdentity(
            captureEpochID: UUID(),
            targetWindowID: 42,
            policyGeneration: 9
        )
        let published = try makePublishedHEICFixture(
            archive: archive,
            identity: identity,
            payloads: [Data("must-never-be-searchable".utf8)]
        )
        let coordinator = try ArchiveAtomicCoordinator(database: archive)
        let drifted = ArchiveCaptureIdentity(
            captureEpochID: UUID(),
            targetWindowID: 99,
            policyGeneration: 10
        )

        XCTAssertThrowsError(
            try coordinator.commit(
                manifestRelativePath: published.manifestPath,
                authorization: ArchiveCaptureAuthorization(identity: identity, isAllowed: true),
                frames: published.frames,
                jobs: [],
                currentIdentity: { drifted }
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveAtomicCoordinatorError, .staleCaptureIdentity)
        }
        XCTAssertEqual(try archive.v2ReadyFrameCountForTesting(), 0)

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        XCTAssertEqual(reopened.startupRecoveryReport.quarantinedOrphanFiles, 1)
        XCTAssertEqual(try reopened.v2ReadyFrameCountForTesting(), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(archive.paths).root
                    .appending(path: published.manifestPath.rawValue).deletingLastPathComponent()
                    .path
            )
        )
    }

    func testInjectedTransactionCrashRollsBackAllRowsAndStartupQuarantinesOrphan() throws {
        let fixture = try TemporaryArchiveFixture(name: "v2-rollback")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        let identity = ArchiveCaptureIdentity(
            captureEpochID: UUID(),
            targetWindowID: 42,
            policyGeneration: 3
        )
        let published = try makePublishedHEICFixture(
            archive: archive,
            identity: identity,
            payloads: [Data("rollback-frame".utf8)]
        )
        let coordinator = try ArchiveAtomicCoordinator(database: archive)

        XCTAssertThrowsError(
            try coordinator.commit(
                manifestRelativePath: published.manifestPath,
                authorization: ArchiveCaptureAuthorization(identity: identity, isAllowed: true),
                frames: published.frames,
                jobs: [
                    ArchiveRetryableJob(
                        id: UUID(),
                        frameID: published.frames[0].id,
                        kind: "thumbnail",
                        priority: 4,
                        producerVersion: "fixture-v1"
                    )
                ],
                fault: .duringTransaction,
                currentIdentity: { identity }
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveAtomicCoordinatorError,
                .injectedCrash(.duringTransaction)
            )
        }
        XCTAssertEqual(try archive.v2ReadyFrameCountForTesting(), 0)

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        XCTAssertEqual(reopened.startupRecoveryReport.quarantinedOrphanFiles, 1)
        XCTAssertEqual(try reopened.v2ReadyFrameCountForTesting(), 0)
    }

    func testAfterCommitCrashReopensAsOneCompleteReadyState() throws {
        let fixture = try TemporaryArchiveFixture(name: "v2-after-commit")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        let identity = ArchiveCaptureIdentity(
            captureEpochID: UUID(),
            targetWindowID: 73,
            policyGeneration: 5
        )
        let published = try makePublishedHEICFixture(
            archive: archive,
            identity: identity,
            payloads: [Data("committed-before-crash".utf8)]
        )
        let coordinator = try ArchiveAtomicCoordinator(database: archive)

        XCTAssertThrowsError(
            try coordinator.commit(
                manifestRelativePath: published.manifestPath,
                authorization: ArchiveCaptureAuthorization(identity: identity, isAllowed: true),
                frames: published.frames,
                jobs: [
                    ArchiveRetryableJob(
                        id: UUID(),
                        frameID: published.frames[0].id,
                        kind: "thumbnail",
                        priority: 4,
                        producerVersion: "fixture-v1"
                    )
                ],
                fault: .afterCommit,
                currentIdentity: { identity }
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveAtomicCoordinatorError,
                .injectedCrash(.afterCommit)
            )
        }

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        XCTAssertEqual(reopened.startupRecoveryReport.quarantinedOrphanFiles, 0)
        XCTAssertEqual(reopened.startupRecoveryReport.quarantinedCorruptFiles, 0)
        XCTAssertEqual(try reopened.v2ReadyFrameCountForTesting(), 1)
        let snapshot = try reopened.v2CoordinatorSnapshotForTesting(
            chunkID: published.manifest.chunkID)
        XCTAssertEqual(snapshot.chunkState, "ready")
        XCTAssertEqual(snapshot.queuedJobCount, 1)
    }

    func testDeniedAuthorizationAndAfterVerificationCrashExposeNoRows() throws {
        let fixture = try TemporaryArchiveFixture(name: "v2-before-transaction")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        let identity = ArchiveCaptureIdentity(
            captureEpochID: UUID(),
            targetWindowID: 75,
            policyGeneration: 12
        )
        let published = try makePublishedHEICFixture(
            archive: archive,
            identity: identity,
            payloads: [Data("pre-transaction".utf8)]
        )
        let coordinator = try ArchiveAtomicCoordinator(database: archive)

        XCTAssertThrowsError(
            try coordinator.commit(
                manifestRelativePath: published.manifestPath,
                authorization: ArchiveCaptureAuthorization(identity: identity, isAllowed: false),
                frames: published.frames,
                jobs: [],
                currentIdentity: { identity }
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveAtomicCoordinatorError, .deniedAuthorization)
        }
        XCTAssertThrowsError(
            try coordinator.commit(
                manifestRelativePath: published.manifestPath,
                authorization: ArchiveCaptureAuthorization(identity: identity, isAllowed: true),
                frames: published.frames,
                jobs: [],
                fault: .afterVerification,
                currentIdentity: { identity }
            )
        ) { error in
            XCTAssertEqual(
                error as? ArchiveAtomicCoordinatorError,
                .injectedCrash(.afterVerification)
            )
        }
        XCTAssertEqual(try archive.v2ReadyFrameCountForTesting(), 0)

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        XCTAssertEqual(reopened.startupRecoveryReport.quarantinedOrphanFiles, 1)
        XCTAssertEqual(try reopened.v2ReadyFrameCountForTesting(), 0)
    }

    func testStagingDirectoryCanNeverBecomeAFrameRowAndStartupRemovesIt() throws {
        let fixture = try TemporaryArchiveFixture(name: "v2-staging")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        let identity = ArchiveCaptureIdentity(
            captureEpochID: UUID(),
            targetWindowID: 74,
            policyGeneration: 6
        )
        let published = try makePublishedHEICFixture(
            archive: archive,
            identity: identity,
            payloads: [Data("staging-only".utf8)]
        )
        let finalDirectory = try XCTUnwrap(archive.paths).root
            .appending(path: published.manifestPath.rawValue)
            .deletingLastPathComponent()
        let stagingDirectory = finalDirectory.deletingLastPathComponent().appending(
            path: ".\(finalDirectory.lastPathComponent).partial",
            directoryHint: .isDirectory
        )
        try FileManager.default.moveItem(at: finalDirectory, to: stagingDirectory)
        let stagingPath = try ArchiveRelativePath(
            "media/2026/08/28/.\(finalDirectory.lastPathComponent).partial/manifest.json"
        )
        let coordinator = try ArchiveAtomicCoordinator(database: archive)

        XCTAssertThrowsError(
            try coordinator.commit(
                manifestRelativePath: stagingPath,
                authorization: ArchiveCaptureAuthorization(identity: identity, isAllowed: true),
                frames: published.frames,
                jobs: [],
                currentIdentity: { identity }
            )
        ) { error in
            XCTAssertEqual(error as? ArchiveHEICVerificationError, .invalidManifestPath)
        }
        XCTAssertEqual(try archive.v2ReadyFrameCountForTesting(), 0)

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        XCTAssertEqual(reopened.startupRecoveryReport.removedPartialFiles, 1)
        XCTAssertEqual(reopened.startupRecoveryReport.quarantinedOrphanFiles, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    func testStartupQuarantinesManifestOrFrameMismatchAndSuppressesEveryDependentRow() throws {
        let fixture = try TemporaryArchiveFixture(name: "v2-corrupt")
        defer { fixture.remove() }
        let archive = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        let identity = ArchiveCaptureIdentity(
            captureEpochID: UUID(),
            targetWindowID: 42,
            policyGeneration: 11
        )
        let published = try makePublishedHEICFixture(
            archive: archive,
            identity: identity,
            payloads: [Data("integrity-frame".utf8)]
        )
        let coordinator = try ArchiveAtomicCoordinator(database: archive)
        _ = try coordinator.commit(
            manifestRelativePath: published.manifestPath,
            authorization: ArchiveCaptureAuthorization(identity: identity, isAllowed: true),
            frames: published.frames,
            jobs: [
                ArchiveRetryableJob(
                    id: UUID(),
                    frameID: published.frames[0].id,
                    kind: "vision-ocr",
                    priority: 8,
                    producerVersion: "fixture-v1"
                )
            ],
            currentIdentity: { identity }
        )
        let frameURL = try XCTUnwrap(archive.paths).root.appending(
            path: published.frames[0].mediaPath,
            directoryHint: .notDirectory
        )
        try Data("tampered".utf8).write(to: frameURL)

        let reopened = try ArchiveDatabase(
            applicationSupportDirectory: fixture.applicationSupport,
            encryptionKey: fixture.encryptionKey
        )
        XCTAssertEqual(reopened.startupRecoveryReport.quarantinedCorruptFiles, 1)
        XCTAssertEqual(reopened.startupRecoveryReport.suppressedSearchableFrames, 0)
        XCTAssertEqual(try reopened.v2ReadyFrameCountForTesting(), 0)
        XCTAssertEqual(
            try reopened.processingJobStateForTesting(
                id: try XCTUnwrap(try archive.v2JobIDsForTesting().first)
            ),
            "cancelled"
        )
    }

}

private struct PublishedHEICFixture {
    let manifestPath: ArchiveRelativePath
    let manifest: HEICKeyframeManifest
    let frames: [ArchiveFrameProjection]
}

private func makePublishedHEICFixture(
    archive: ArchiveDatabase,
    identity: ArchiveCaptureIdentity,
    payloads: [Data]
) throws -> PublishedHEICFixture {
    let paths = try XCTUnwrap(archive.paths)
    let chunkID = UUID()
    let relativeDirectory = "media/2026/08/28/\(chunkID.uuidString.lowercased())"
    let directory = paths.root.appending(path: relativeDirectory, directoryHint: .isDirectory)
    let framesDirectory = directory.appending(path: "frames", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: framesDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    var entries: [HEICKeyframeEntry] = []
    var projections: [ArchiveFrameProjection] = []
    for (offset, payload) in payloads.enumerated() {
        let frameID = UUID()
        let relativePath = "frames/\(frameID.uuidString.lowercased()).heic"
        let frameURL = directory.appending(path: relativePath, directoryHint: .notDirectory)
        try payload.write(to: frameURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: frameURL.path
        )
        let entry = try HEICKeyframeEntry(
            frameID: frameID,
            presentationTimeMS: Int64(offset * 500),
            relativePath: relativePath,
            byteCount: Int64(payload.count),
            sha256: Data(SHA256.hash(data: payload))
        )
        entries.append(entry)
        projections.append(
            ArchiveFrameProjection(
                id: frameID,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_000 + Double(offset)),
                monotonicNanoseconds: UInt64(offset + 1) * 500_000_000,
                presentationTimeMilliseconds: entry.presentationTimeMS,
                captureReason: offset == 0 ? "transition" : "visualChange",
                isTransition: offset == 0,
                bundleIdentifier: "com.example.approved",
                applicationName: "Approved",
                windowTitle: "Approved Window",
                mediaPath: "\(relativeDirectory)/\(relativePath)"
            )
        )
    }
    let manifest = try HEICKeyframeManifest(
        chunkID: chunkID,
        captureEpochID: identity.captureEpochID,
        targetWindowID: identity.targetWindowID,
        width: 1280,
        height: 720,
        frames: entries
    )
    let manifestData = try ContractJSON.encode(manifest)
    let manifestURL = directory.appending(path: "manifest.json", directoryHint: .notDirectory)
    try manifestData.write(to: manifestURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: manifestURL.path
    )
    return PublishedHEICFixture(
        manifestPath: try ArchiveRelativePath("\(relativeDirectory)/manifest.json"),
        manifest: manifest,
        frames: projections
    )
}

private struct TemporaryArchiveFixture {
    let root: URL
    let applicationSupport: URL
    let encryptionKey = Data(repeating: 0x17, count: LM008StoreDefaults.keyByteCount)

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
