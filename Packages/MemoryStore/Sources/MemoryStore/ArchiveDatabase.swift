import Foundation
import GRDB

public enum ArchiveDatabaseError: Error, Equatable, Sendable {
    case invalidKeyLength
    case injectedMigrationInterruption
}

public struct ArchiveDatabaseConfigurationSnapshot: Equatable, Sendable {
    public let journalMode: String
    public let foreignKeysEnabled: Bool
    public let tempStore: String
    public let temporaryDirectory: String?
}

struct ArchiveDatabaseInspection: Equatable, Sendable {
    let appliedMigrationIdentifiers: [String]
    let logicalTableNames: [String]
}

struct ArchiveCascadeResult: Equatable, Sendable {
    let mediaChunks: Int
    let frames: Int
    let textSpans: Int
    let artifacts: Int
    let vectorOffsets: Int
    let foreignKeyViolations: Int
}

public final class ArchiveDatabase: @unchecked Sendable {
    public static let v1LogicalTableNames = ArchiveSchemaV1.logicalTableNames

    public let paths: ArchivePaths?
    public let isDeterministicTestStore: Bool
    public let fileStore: ArchiveFileStore?
    public let startupRecoveryReport: ArchiveStartupRecoveryReport

    private let writer: any DatabaseWriter
    private let migrator: DatabaseMigrator

    public init(
        applicationSupportDirectory: URL? = nil,
        encryptionKey: Data? = nil,
        fileManager: FileManager = .default
    ) throws {
        let paths = try ArchivePathProvider.prepare(
            applicationSupportDirectory: applicationSupportDirectory,
            fileManager: fileManager
        )
        let configuration = try Self.configuration(
            encryptionKey: encryptionKey,
            usesWAL: true,
            temporaryDirectory: paths.database
        )
        let pool = try DatabasePool(
            path: paths.databaseFile.path,
            configuration: configuration
        )
        let migrator = ArchiveSchemaV1.migrator()
        try migrator.migrate(pool)
        for databaseFile in Self.databaseFiles(at: paths.databaseFile)
            where fileManager.fileExists(atPath: databaseFile.path)
        {
            try fileManager.setAttributes(
                [.posixPermissions: ArchivePathProvider.filePermissions],
                ofItemAtPath: databaseFile.path
            )
        }
        let fileStore = ArchiveFileStore(paths: paths, fileManager: fileManager)
        let recoveryReport = try ArchiveStartupRecovery.recover(
            paths: paths,
            writer: pool,
            fileManager: fileManager
        )

        self.paths = paths
        isDeterministicTestStore = false
        self.fileStore = fileStore
        startupRecoveryReport = recoveryReport
        writer = pool
        self.migrator = migrator
    }

    private init(
        writer: any DatabaseWriter,
        paths: ArchivePaths?,
        isDeterministicTestStore: Bool,
        migrator: DatabaseMigrator,
        fileStore: ArchiveFileStore?,
        startupRecoveryReport: ArchiveStartupRecoveryReport
    ) {
        self.writer = writer
        self.paths = paths
        self.isDeterministicTestStore = isDeterministicTestStore
        self.migrator = migrator
        self.fileStore = fileStore
        self.startupRecoveryReport = startupRecoveryReport
    }

    public static func deterministicTestStore() throws -> ArchiveDatabase {
        let configuration = try configuration(
            encryptionKey: nil,
            usesWAL: false,
            temporaryDirectory: nil
        )
        let queue = try DatabaseQueue(configuration: configuration)
        let migrator = ArchiveSchemaV1.migrator()
        try migrator.migrate(queue)
        return ArchiveDatabase(
            writer: queue,
            paths: nil,
            isDeterministicTestStore: true,
            migrator: migrator,
            fileStore: nil,
            startupRecoveryReport: .empty
        )
    }

    public func logicalTableNames() throws -> [String] {
        try writer.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT name
                    FROM sqlite_schema
                    WHERE type = 'table'
                      AND name IN (\(Self.sqlPlaceholders(count: Self.v1LogicalTableNames.count)))
                    ORDER BY name
                    """,
                arguments: StatementArguments(Self.v1LogicalTableNames.sorted())
            )
        }
    }

    public func appliedMigrationIdentifiers() throws -> [String] {
        try writer.read { database in
            try migrator.appliedMigrations(database)
        }
    }

    public func archiveMetaValue(forKey key: String) throws -> String? {
        try writer.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT value FROM archive_meta WHERE key = ?",
                arguments: [key]
            )
        }
    }

    public func configurationSnapshot() throws -> ArchiveDatabaseConfigurationSnapshot {
        try writer.read { database in
            let journalMode = try String.fetchOne(database, sql: "PRAGMA journal_mode") ?? ""
            let foreignKeys = try Int.fetchOne(database, sql: "PRAGMA foreign_keys") ?? 0
            let tempStoreValue = try Int.fetchOne(database, sql: "PRAGMA temp_store") ?? 0
            let temporaryDirectory = try String.fetchOne(
                database,
                sql: "PRAGMA temp_store_directory"
            )
            return ArchiveDatabaseConfigurationSnapshot(
                journalMode: journalMode.uppercased(),
                foreignKeysEnabled: foreignKeys == 1,
                tempStore: Self.tempStoreName(tempStoreValue),
                temporaryDirectory: temporaryDirectory
            )
        }
    }

    public func schemaSQL() throws -> String {
        try writer.read { database in
            let statements = try String.fetchAll(
                database,
                sql: """
                    SELECT sql
                    FROM sqlite_schema
                    WHERE sql IS NOT NULL
                      AND name NOT LIKE 'sqlite_%'
                      AND name <> 'grdb_migrations'
                    ORDER BY CASE type
                        WHEN 'table' THEN 0
                        WHEN 'index' THEN 1
                        WHEN 'view' THEN 2
                        WHEN 'trigger' THEN 3
                        ELSE 4
                    END, name
                    """
            )
            return statements
                .map { $0.hasSuffix(";") ? $0 : $0 + ";" }
                .joined(separator: "\n\n") + "\n"
        }
    }

    static func createVersionZeroFixture(at databaseURL: URL, marker: String) throws {
        let queue = try DatabaseQueue(
            path: databaseURL.path,
            configuration: try configuration(
                encryptionKey: nil,
                usesWAL: true,
                temporaryDirectory: databaseURL.deletingLastPathComponent()
            )
        )
        try queue.write { database in
            try database.execute(sql: """
                CREATE TABLE version_zero_fixture (
                    marker TEXT NOT NULL PRIMARY KEY
                )
                """)
            try database.execute(
                sql: "INSERT INTO version_zero_fixture(marker) VALUES (?)",
                arguments: [marker]
            )
        }
    }

    func versionZeroMarkerForTesting() throws -> String? {
        try writer.read { database in
            try String.fetchOne(database, sql: "SELECT marker FROM version_zero_fixture")
        }
    }

    static func runInterruptedV1Migration(at databaseURL: URL) throws {
        let queue = try DatabaseQueue(
            path: databaseURL.path,
            configuration: try configuration(
                encryptionKey: nil,
                usesWAL: true,
                temporaryDirectory: databaseURL.deletingLastPathComponent()
            )
        )
        let migrator = ArchiveSchemaV1.migrator {
            throw ArchiveDatabaseError.injectedMigrationInterruption
        }
        try migrator.migrate(queue)
    }

    static func inspectUnencryptedDatabase(at databaseURL: URL) throws -> ArchiveDatabaseInspection {
        let queue = try DatabaseQueue(
            path: databaseURL.path,
            configuration: try configuration(
                encryptionKey: nil,
                usesWAL: true,
                temporaryDirectory: databaseURL.deletingLastPathComponent()
            )
        )
        let migrator = ArchiveSchemaV1.migrator()
        return try queue.read { database in
            let tableNames = try String.fetchAll(
                database,
                sql: """
                    SELECT name
                    FROM sqlite_schema
                    WHERE type = 'table'
                      AND name IN (\(sqlPlaceholders(count: v1LogicalTableNames.count)))
                    ORDER BY name
                    """,
                arguments: StatementArguments(v1LogicalTableNames.sorted())
            )
            return ArchiveDatabaseInspection(
                appliedMigrationIdentifiers: try migrator.appliedMigrations(database),
                logicalTableNames: tableNames
            )
        }
    }

    func exerciseFrameCascadeForTesting() throws -> ArchiveCascadeResult {
        try writer.write { database in
            try database.execute(sql: """
                INSERT INTO media_chunks(
                    id, capture_epoch_id, target_window_id, relative_path,
                    started_at, ended_at, codec, width, height, frame_count,
                    byte_count, sha256, state
                ) VALUES (
                    'chunk-1', 'epoch-1', 42, 'media/2026/01/01/chunk-1.mov',
                    '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:01.000Z',
                    'hevc', 1280, 720, 1, 256, 'hash', 'ready'
                )
                """)
            try database.execute(sql: """
                INSERT INTO frames(
                    id, captured_at, monotonic_ns, capture_epoch_id,
                    target_window_id, chunk_id, pts_ms, capture_reason,
                    is_transition, text_state, visual_state, schema_version
                ) VALUES (
                    'frame-1', '2026-01-01T00:00:00.500Z', 500000000,
                    'epoch-1', 42, 'chunk-1', 500, 'transition',
                    1, 'ready', 'ready', 1
                )
                """)
            try database.execute(sql: """
                INSERT INTO text_spans(
                    id, frame_id, source, text, x, y, w, h,
                    confidence, language_code, sensitivity
                ) VALUES (
                    'span-1', 'frame-1', 'accessibility', 'approved',
                    0.1, 0.1, 0.2, 0.2, 1.0, 'en', 'normal'
                )
                """)
            try database.execute(sql: """
                INSERT INTO artifacts(
                    id, frame_id, kind, producer_name, producer_version,
                    model_hash, locator_kind, locator_value, content_hash, state
                ) VALUES (
                    'artifact-1', 'frame-1', 'thumbnail', 'fixture', '1',
                    NULL, 'relativePath', 'thumbnails/frame-1.heic', 'hash', 'ready'
                )
                """)
            try database.execute(sql: """
                INSERT INTO vector_offsets(
                    frame_id, model_hash, byte_offset, dimension, norm, state
                ) VALUES ('frame-1', 'model-hash', 0, 512, 1.0, 'ready')
                """)
            try database.execute(sql: "DELETE FROM frames WHERE id = 'frame-1'")

            return ArchiveCascadeResult(
                mediaChunks: try Self.count("media_chunks", in: database),
                frames: try Self.count("frames", in: database),
                textSpans: try Self.count("text_spans", in: database),
                artifacts: try Self.count("artifacts", in: database),
                vectorOffsets: try Self.count("vector_offsets", in: database),
                foreignKeyViolations: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM pragma_foreign_key_check"
                ) ?? 0
            )
        }
    }

    func v1ColumnNamesForTesting() throws -> [String: [String]] {
        try writer.read { database in
            var result: [String: [String]] = [:]
            for table in Self.v1LogicalTableNames.sorted() {
                result[table] = try database.columns(in: table).map(\.name)
            }
            return result
        }
    }

    func insertReadyMediaFixtureForTesting(
        chunkID: String,
        frameID: String,
        integrity: ArchiveFileIntegrity
    ) throws {
        try insertMediaFixtureForTesting(
            chunkID: chunkID,
            frameID: frameID,
            relativePath: integrity.relativePath,
            byteCount: integrity.byteCount,
            sha256: integrity.sha256Hex
        )
    }

    func insertMissingReadyMediaFixtureForTesting(
        chunkID: String,
        frameID: String,
        relativePath: ArchiveRelativePath
    ) throws {
        try insertMediaFixtureForTesting(
            chunkID: chunkID,
            frameID: frameID,
            relativePath: relativePath,
            byteCount: 64,
            sha256: String(repeating: "0", count: 64)
        )
    }

    func insertLeasedJobFixtureForTesting(id: String) throws {
        try writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO processing_jobs(
                        id, parent_id, kind, priority, state, attempts,
                        next_attempt_at, producer_version, error_code, lease_expires_at
                    ) VALUES (?, 'independent-parent', 'fixture', 1, 'leased', 1,
                              NULL, '1', NULL, '2099-01-01T00:00:00.000Z')
                    """,
                arguments: [id]
            )
        }
    }

    func searchableFrameCountForTesting() throws -> Int {
        try writer.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM frame_fts WHERE frame_fts MATCH 'searchable'"
            ) ?? 0
        }
    }

    func mediaChunkStateForTesting(id: String) throws -> String? {
        try writer.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT state FROM media_chunks WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func processingJobStateForTesting(id: String) throws -> String? {
        try writer.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT state FROM processing_jobs WHERE id = ?",
                arguments: [id]
            )
        }
    }

    private func insertMediaFixtureForTesting(
        chunkID: String,
        frameID: String,
        relativePath: ArchiveRelativePath,
        byteCount: Int64,
        sha256: String
    ) throws {
        try writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES (?, 'epoch-fixture', 42, ?,
                              '2026-08-28T00:00:00.000Z', '2026-08-28T00:00:01.000Z',
                              'hevcMain', 1280, 720, 1, ?, ?, 'ready')
                    """,
                arguments: [chunkID, relativePath.rawValue, byteCount, sha256]
            )
            try database.execute(
                sql: """
                    INSERT INTO frames(
                        id, captured_at, monotonic_ns, capture_epoch_id,
                        target_window_id, chunk_id, pts_ms, bundle_id, app_name,
                        window_title, capture_reason, is_transition, text_state,
                        visual_state, schema_version, approved_text
                    ) VALUES (?, '2026-08-28T00:00:00.500Z', 500000000,
                              'epoch-fixture', 42, ?, 500, 'com.example.fixture',
                              'Fixture', 'Approved Fixture', 'visualChange', 0,
                              'ready', 'ready', 1, 'searchable approved fixture')
                    """,
                arguments: [frameID, chunkID]
            )
            try database.execute(
                sql: """
                    INSERT INTO frame_fts(
                        rowid, approved_text, window_title, app_name, url_host, url_path
                    )
                    SELECT rowid, approved_text, window_title, app_name, url_host, url_path
                    FROM frames WHERE id = ?
                    """,
                arguments: [frameID]
            )
        }
    }

    private static func configuration(
        encryptionKey: Data?,
        usesWAL: Bool,
        temporaryDirectory: URL?
    ) throws -> Configuration {
        if let encryptionKey,
           encryptionKey.count != LM008StoreDefaults.keyByteCount
        {
            throw ArchiveDatabaseError.invalidKeyLength
        }

        var configuration = Configuration()
        configuration.journalMode = usesWAL ? .wal : .default
        configuration.busyMode = .timeout(
            TimeInterval(LM008StoreDefaults.busyTimeoutMilliseconds) / 1_000
        )
        configuration.maximumReaderCount = LM008StoreDefaults.maximumReaderCount
        configuration.prepareDatabase { database in
            if let encryptionKey {
                try database.usePassphrase(encryptionKey)
            }
            try database.execute(sql: "PRAGMA foreign_keys = ON")
            try database.execute(sql: "PRAGMA secure_delete = ON")
            try database.execute(sql: "PRAGMA temp_store = FILE")
            if let temporaryDirectory {
                let quotedPath = temporaryDirectory.path.replacingOccurrences(
                    of: "'",
                    with: "''"
                )
                try database.execute(
                    sql: "PRAGMA temp_store_directory = '\(quotedPath)'"
                )
            }
            try database.execute(sql: "PRAGMA synchronous = FULL")
        }
        return configuration
    }

    private static func sqlPlaceholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private static func tempStoreName(_ value: Int) -> String {
        switch value {
        case 1: "FILE"
        case 2: "MEMORY"
        default: "DEFAULT"
        }
    }

    private static func count(_ table: String, in database: Database) throws -> Int {
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }

    private static func databaseFiles(at databaseURL: URL) -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
    }
}
