import Foundation
import GRDB
import MemoryContracts

public enum ArchiveDatabaseError: Error, Equatable, Sendable {
    case invalidKeyLength
    case missingCipherVersion
    case cipherIntegrityFailure
    case encryptedArchiveUnavailable
    case invalidPolicyDecisionAudit
    case invalidAgentAccessAudit
    case invalidActivityGap
    case injectedMigrationInterruption
}

enum ArchiveDatabaseFixtureError: Error, Equatable, Sendable {
    case missingFrame(String)
}

public struct ArchivePolicyDecisionRecord: Equatable, Sendable {
    public let id: UUID
    public let decidedAt: Date
    public let bundleIdentifier: String?
    public let host: String?
    public let privateContext: Bool
    public let result: String
    public let matchedRuleID: String?

    /// The V1 audit contract has no title, URL, text, pixel, media, or derived-content fields.
    public var contentFieldCount: Int { 0 }
}

public struct ArchiveDatabaseConfigurationSnapshot: Equatable, Sendable {
    public let journalMode: String
    public let foreignKeysEnabled: Bool
    public let tempStore: String
    public let temporaryDirectory: String?
}

public struct ArchiveLocalSearchScope: Equatable, Sendable {
    public let bundleIdentifiers: Set<String>
    public let hosts: Set<String>
    public let applications: [ArchiveSearchApplication]

    public init(
        bundleIdentifiers: Set<String>,
        hosts: Set<String>,
        applications: [ArchiveSearchApplication] = []
    ) {
        self.bundleIdentifiers = bundleIdentifiers
        self.hosts = hosts
        self.applications = applications
    }
}

public struct ArchiveSearchApplication: Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
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

struct ArchiveV2CoordinatorSnapshot: Equatable, Sendable {
    let chunkState: String?
    let frameCount: Int
    let queuedJobCount: Int
    let distinctEpochCount: Int
    let distinctTargetCount: Int
    let distinctPolicyGenerationCount: Int
    let mediaPaths: [String]
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
        encryptionKey: Data,
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
        let pool: DatabasePool
        let migrator = ArchiveSchemaV1.migrator()
        do {
            pool = try DatabasePool(
                path: paths.databaseFile.path,
                configuration: configuration
            )
            try migrator.migrate(pool)
            try Self.verifyCipher(in: pool)
        } catch let error as ArchiveDatabaseError {
            throw error
        } catch is DatabaseError {
            throw ArchiveDatabaseError.encryptedArchiveUnavailable
        }
        for databaseFile in Self.databaseFiles(at: paths.databaseFile)
        where fileManager.fileExists(atPath: databaseFile.path) {
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
            encryptionKey: Data(repeating: 0xD5, count: LM008StoreDefaults.keyByteCount),
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

    public func localSearchScope() throws -> ArchiveLocalSearchScope {
        try writer.read { database in
            let bundleIdentifiers = try String.fetchAll(
                database,
                sql: """
                    SELECT DISTINCT frames.bundle_id
                    FROM frames
                    JOIN media_chunks ON media_chunks.id = frames.chunk_id
                    WHERE media_chunks.state = 'ready'
                      AND frames.bundle_id IS NOT NULL
                      AND frames.visual_state <> 'suppressed'
                      AND (frames.text_state = 'ready' OR frames.visual_state = 'ready')
                    ORDER BY frames.bundle_id
                    """
            )
            let hosts = try String.fetchAll(
                database,
                sql: """
                    SELECT DISTINCT frames.url_host
                    FROM frames
                    JOIN media_chunks ON media_chunks.id = frames.chunk_id
                    WHERE media_chunks.state = 'ready'
                      AND frames.url_host IS NOT NULL
                      AND frames.visual_state <> 'suppressed'
                      AND (frames.text_state = 'ready' OR frames.visual_state = 'ready')
                    ORDER BY frames.url_host
                    """
            )
            let applications = try Row.fetchAll(
                database,
                sql: """
                    SELECT frames.bundle_id,
                           MIN(frames.app_name COLLATE NOCASE) AS app_name
                    FROM frames
                    JOIN media_chunks ON media_chunks.id = frames.chunk_id
                    WHERE media_chunks.state = 'ready'
                      AND frames.bundle_id IS NOT NULL
                      AND frames.app_name IS NOT NULL
                      AND frames.visual_state <> 'suppressed'
                      AND (frames.text_state = 'ready' OR frames.visual_state = 'ready')
                    GROUP BY frames.bundle_id
                    ORDER BY app_name COLLATE NOCASE, frames.bundle_id
                    """
            ).map { row in
                ArchiveSearchApplication(
                    bundleIdentifier: row["bundle_id"],
                    displayName: row["app_name"]
                )
            }
            return ArchiveLocalSearchScope(
                bundleIdentifiers: Set(bundleIdentifiers),
                hosts: Set(hosts),
                applications: applications
            )
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

    public func recordPolicyDecision(
        id: UUID,
        decidedAt: Date,
        bundleIdentifier: String?,
        host: String?,
        privateContext: Bool,
        result: String,
        matchedRuleID: String?
    ) throws {
        guard result == "allowed" || result == "denied",
            Self.isSafeAuditBundleIdentifier(bundleIdentifier),
            Self.isSafeAuditHost(host),
            Self.isSafeAuditRuleIdentifier(matchedRuleID)
        else {
            throw ArchiveDatabaseError.invalidPolicyDecisionAudit
        }
        let timestamp = decidedAt.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
        try writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO policy_decisions(
                        id, decided_at, bundle_id, host,
                        private_context, result, matched_rule_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id.uuidString.lowercased(),
                    timestamp,
                    bundleIdentifier,
                    host,
                    privateContext ? 1 : 0,
                    result,
                    matchedRuleID,
                ]
            )
        }
    }

    public func policyDecisionRecords() throws -> [ArchivePolicyDecisionRecord] {
        try writer.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, decided_at, bundle_id, host,
                           private_context, result, matched_rule_id
                    FROM policy_decisions
                    ORDER BY decided_at, id
                    """
            )
            let dateStyle = Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
            return try rows.map { row in
                let encodedID: String = row["id"]
                let encodedDate: String = row["decided_at"]
                guard let id = UUID(uuidString: encodedID) else {
                    throw ArchiveDatabaseError.invalidPolicyDecisionAudit
                }
                let decidedAt: Date
                do {
                    decidedAt = try dateStyle.parse(encodedDate)
                } catch {
                    throw ArchiveDatabaseError.invalidPolicyDecisionAudit
                }
                return ArchivePolicyDecisionRecord(
                    id: id,
                    decidedAt: decidedAt,
                    bundleIdentifier: row["bundle_id"],
                    host: row["host"],
                    privateContext: (row["private_context"] as Int) == 1,
                    result: row["result"],
                    matchedRuleID: row["matched_rule_id"]
                )
            }
        }
    }

    public func appendAgentAccessAudit(_ record: ArchiveAgentAccessAuditRecord) throws {
        guard record.occurredAt.timeIntervalSince1970.isFinite,
            record.resultCount >= 0,
            Self.isSafeAgentAccessAction(record.action),
            Self.isSafeQueryHash(record.queryHash)
        else {
            throw ArchiveDatabaseError.invalidAgentAccessAudit
        }
        let timestamp = record.occurredAt.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
        try writer.write { database in
            let policyID = record.policyID?.uuidString.lowercased()
            let persistedPolicyID: String? =
                if let policyID,
                    try Bool.fetchOne(
                        database,
                        sql: "SELECT EXISTS(SELECT 1 FROM access_policies WHERE id = ?)",
                        arguments: [policyID]
                    ) == true
                {
                    policyID
                } else {
                    nil
                }
            try database.execute(
                sql: """
                    INSERT INTO audit_events(
                        id, occurred_at, actor, action, policy_id, result_count, query_hash
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id.uuidString.lowercased(),
                    timestamp,
                    record.actor.rawValue,
                    record.action,
                    persistedPolicyID,
                    record.resultCount,
                    record.queryHash,
                ]
            )
        }
    }

    public func registerAgentAccessPolicy(_ policy: AccessPolicy) throws {
        try policy.validate()
        let encoded = String(decoding: try ContractJSON.encode(policy), as: UTF8.self)
        let expiresAt = policy.expiresAt.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
        try writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO access_policies(id, encoded_policy, expires_at, created_by_user)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        encoded_policy = excluded.encoded_policy,
                        expires_at = excluded.expires_at,
                        created_by_user = excluded.created_by_user
                    """,
                arguments: [
                    policy.id.uuidString.lowercased(),
                    encoded,
                    expiresAt,
                    policy.createdByUser ? 1 : 0,
                ]
            )
        }
    }

    public func agentAccessAudit(limit: Int = 100) throws -> [ArchiveAgentAccessAuditRecord] {
        guard (1...500).contains(limit) else {
            throw ArchiveDatabaseError.invalidAgentAccessAudit
        }
        return try writer.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, occurred_at, actor, action, policy_id, result_count, query_hash
                    FROM audit_events
                    WHERE actor IN (?, ?)
                    ORDER BY occurred_at DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [
                    ArchiveAgentAccessAuditActor.cli.rawValue,
                    ArchiveAgentAccessAuditActor.mcp.rawValue,
                    limit,
                ]
            )
            let style = Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
            return try rows.map { row in
                let encodedID: String = row["id"]
                let encodedDate: String = row["occurred_at"]
                let encodedActor: String = row["actor"]
                let action: String = row["action"]
                let policyValue: String? = row["policy_id"]
                let queryHash: String? = row["query_hash"]
                let policyID: UUID?
                if let policyValue {
                    guard let parsed = UUID(uuidString: policyValue) else {
                        throw ArchiveDatabaseError.invalidAgentAccessAudit
                    }
                    policyID = parsed
                } else {
                    policyID = nil
                }
                guard let id = UUID(uuidString: encodedID),
                    let occurredAt = try? style.parse(encodedDate),
                    let actor = ArchiveAgentAccessAuditActor(rawValue: encodedActor),
                    Self.isSafeAgentAccessAction(action),
                    Self.isSafeQueryHash(queryHash)
                else {
                    throw ArchiveDatabaseError.invalidAgentAccessAudit
                }
                return ArchiveAgentAccessAuditRecord(
                    id: id,
                    occurredAt: occurredAt,
                    actor: actor,
                    action: action,
                    policyID: policyID,
                    resultCount: row["result_count"],
                    queryHash: queryHash
                )
            }
        }
    }

    public func clearAgentAccessAudit() throws {
        try writer.write { database in
            try database.execute(
                sql: "DELETE FROM audit_events WHERE actor IN (?, ?)",
                arguments: [
                    ArchiveAgentAccessAuditActor.cli.rawValue,
                    ArchiveAgentAccessAuditActor.mcp.rawValue,
                ]
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

    public func cipherVersion() throws -> String {
        try writer.read { database in
            guard let version = try String.fetchOne(database, sql: "PRAGMA cipher_version"),
                !version.isEmpty
            else {
                throw ArchiveDatabaseError.missingCipherVersion
            }
            return version
        }
    }

    public func cipherIntegrityCheck() throws -> Bool {
        try writer.read { database in
            let rows = try String.fetchAll(database, sql: "PRAGMA cipher_integrity_check")
            return rows.isEmpty || rows.allSatisfy { $0.lowercased() == "ok" }
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
            return
                statements
                .map { $0.hasSuffix(";") ? $0 : $0 + ";" }
                .joined(separator: "\n\n") + "\n"
        }
    }

    static func createVersionZeroFixture(
        at databaseURL: URL,
        encryptionKey: Data,
        marker: String
    ) throws {
        let queue = try DatabaseQueue(
            path: databaseURL.path,
            configuration: try configuration(
                encryptionKey: encryptionKey,
                usesWAL: true,
                temporaryDirectory: databaseURL.deletingLastPathComponent()
            )
        )
        try queue.write { database in
            try database.execute(
                sql: """
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

    static func runInterruptedV1Migration(
        at databaseURL: URL,
        encryptionKey: Data
    ) throws {
        let queue = try DatabaseQueue(
            path: databaseURL.path,
            configuration: try configuration(
                encryptionKey: encryptionKey,
                usesWAL: true,
                temporaryDirectory: databaseURL.deletingLastPathComponent()
            )
        )
        let migrator = ArchiveSchemaV1.migrator {
            throw ArchiveDatabaseError.injectedMigrationInterruption
        }
        try migrator.migrate(queue)
    }

    static func inspectDatabase(
        at databaseURL: URL,
        encryptionKey: Data
    ) throws -> ArchiveDatabaseInspection {
        let queue = try DatabaseQueue(
            path: databaseURL.path,
            configuration: try configuration(
                encryptionKey: encryptionKey,
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
            try database.execute(
                sql: """
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
            try database.execute(
                sql: """
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
            try database.execute(
                sql: """
                    INSERT INTO text_spans(
                        id, frame_id, source, text, x, y, w, h,
                        confidence, language_code, sensitivity
                    ) VALUES (
                        'span-1', 'frame-1', 'accessibility', 'approved',
                        0.1, 0.1, 0.2, 0.2, 1.0, 'en', 'normal'
                    )
                    """)
            try database.execute(
                sql: """
                    INSERT INTO artifacts(
                        id, frame_id, kind, producer_name, producer_version,
                        model_hash, locator_kind, locator_value, content_hash, state
                    ) VALUES (
                        'artifact-1', 'frame-1', 'thumbnail', 'fixture', '1',
                        NULL, 'relativePath', 'thumbnails/frame-1.heic', 'hash', 'ready'
                    )
                    """)
            try database.execute(
                sql: """
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

    func currentColumnNamesForTesting() throws -> [String: [String]] {
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

    func insertSearchFrameFixtureForTesting(
        suffix: Int,
        frameID explicitFrameID: UUID? = nil,
        capturedAt: Date = Date(timeIntervalSince1970: 1_777_000_000),
        bundleIdentifier: String = "com.example.fixture",
        appName: String = "Fixture App",
        windowTitle: String = "Fixture Window",
        host: String? = nil,
        path: String? = nil,
        isTransition: Bool = false
    ) throws -> UUID {
        let frameID =
            explicitFrameID ?? UUID(
                uuidString: String(format: "35000000-0000-0000-0000-%012d", suffix)
            )!
        let chunkID = "search-chunk-\(suffix)"
        try writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES (?, 'search-epoch', 42, ?,
                              '2026-08-28T00:00:00.000Z', '2026-08-28T00:00:01.000Z',
                              'heicKeyframes', 1280, 720, 1, 64, ?, 'ready')
                    """,
                arguments: [
                    chunkID,
                    "media/2026/08/28/\(chunkID)/manifest.json",
                    String(repeating: "a", count: 64),
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO frames(
                        id, captured_at, monotonic_ns, capture_epoch_id,
                        target_window_id, chunk_id, pts_ms, bundle_id, app_name,
                        window_title, window_x, window_y, window_w, window_h,
                        browser_family, url_scheme, url_host, url_path,
                        capture_reason, is_transition, text_state,
                        visual_state, schema_version, approved_text
                    ) VALUES (?, ?, 500000000,
                              'search-epoch', 42, ?, 500, ?, ?, ?,
                              0, 0, 1, 1, ?, ?, ?, ?,
                              'visualChange', ?, 'pending', 'ready', 1, '')
                    """,
                arguments: [
                    frameID.uuidString.lowercased(),
                    Self.encodeSearchFixtureDate(capturedAt),
                    chunkID,
                    bundleIdentifier,
                    appName,
                    windowTitle,
                    host == nil ? nil : "chrome",
                    host == nil ? nil : "https",
                    host,
                    path,
                    isTransition ? 1 : 0,
                ]
            )
        }
        return frameID
    }

    func searchableFrameCountForTesting() throws -> Int {
        try writer.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM frame_fts WHERE frame_fts MATCH 'searchable'"
            ) ?? 0
        }
    }

    func setSearchFrameVisibilityForTesting(
        frameID: UUID,
        visualState: String = "ready",
        chunkState: String = "ready",
        mergedTextState: String = "ready"
    ) throws {
        try writer.write { database in
            let frameID = frameID.uuidString.lowercased()
            guard
                let chunkID = try String.fetchOne(
                    database,
                    sql: "SELECT chunk_id FROM frames WHERE id = ?",
                    arguments: [frameID]
                )
            else {
                throw ArchiveDatabaseFixtureError.missingFrame(frameID)
            }
            try database.execute(
                sql: "UPDATE frames SET visual_state = ? WHERE id = ?",
                arguments: [visualState, frameID]
            )
            try database.execute(
                sql: "UPDATE media_chunks SET state = ? WHERE id = ?",
                arguments: [chunkState, chunkID]
            )
            try database.execute(
                sql: "UPDATE merged_text_records SET state = ? WHERE frame_id = ?",
                arguments: [mergedTextState, frameID]
            )
        }
    }

    private static func encodeSearchFixtureDate(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
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

    func atomicWrite<T>(_ updates: (Database) throws -> T) throws -> T {
        try writer.write(updates)
    }

    func atomicRead<T>(_ read: (Database) throws -> T) throws -> T {
        try writer.read(read)
    }

    public func checkpointAndVacuumForForensicDeletion() throws {
        _ = try writer.writeWithoutTransaction { database in
            try database.checkpoint(.truncate)
        }
        try writer.vacuum()
        _ = try writer.writeWithoutTransaction { database in
            try database.checkpoint(.truncate)
        }
    }

    public func repairArchive() throws -> ArchiveStartupRecoveryReport {
        guard let paths else { throw ArchiveDatabaseError.encryptedArchiveUnavailable }
        return try ArchiveStartupRecovery.recover(
            paths: paths,
            writer: writer,
            fileManager: .default
        )
    }

    func frameColumnNamesForTesting() throws -> Set<String> {
        try writer.read { database in
            Set(try database.columns(in: "frames").map(\.name))
        }
    }

    func insertLegacyV1FrameForTesting() throws {
        try writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES ('legacy-v1-chunk', 'legacy-v1-epoch', 1,
                              'media/2026/08/28/legacy-v1.mov',
                              '2026-08-28T00:00:00.000Z', '2026-08-28T00:00:01.000Z',
                              'hevcMain', 320, 180, 1, 1, ?, 'ready')
                    """,
                arguments: [String(repeating: "0", count: 64)]
            )
            try database.execute(
                sql: """
                    INSERT INTO frames(
                        id, captured_at, monotonic_ns, capture_epoch_id,
                        target_window_id, chunk_id, pts_ms, capture_reason,
                        is_transition, text_state, visual_state, schema_version
                    ) VALUES ('legacy-v1-frame', '2026-08-28T00:00:00.000Z', 0,
                              'legacy-v1-epoch', 1, 'legacy-v1-chunk', 0,
                              'transition', 1, 'pending', 'pending', 1)
                    """
            )
        }
    }

    func insertInvalidV2FrameForTesting() throws {
        try writer.write { database in
            try database.execute(
                sql: """
                    INSERT INTO media_chunks(
                        id, capture_epoch_id, target_window_id, relative_path,
                        started_at, ended_at, codec, width, height, frame_count,
                        byte_count, sha256, state
                    ) VALUES ('invalid-v2-chunk', 'invalid-v2-epoch', 2,
                              'media/2026/08/28/invalid-v2/manifest.json',
                              '2026-08-28T00:00:00.000Z', '2026-08-28T00:00:01.000Z',
                              'heicKeyframes', 320, 180, 1, 1, ?, 'ready')
                    """,
                arguments: [String(repeating: "0", count: 64)]
            )
            try database.execute(
                sql: """
                    INSERT INTO frames(
                        id, captured_at, monotonic_ns, capture_epoch_id,
                        target_window_id, chunk_id, pts_ms, capture_reason,
                        is_transition, text_state, visual_state, schema_version,
                        policy_generation
                    ) VALUES ('invalid-v2-frame', '2026-08-28T00:00:00.000Z', 0,
                              'invalid-v2-epoch', 2, 'invalid-v2-chunk', 0,
                              'transition', 1, 'pending', 'pending', 2, 1)
                    """
            )
        }
    }

    func v2ReadyFrameCountForTesting() throws -> Int {
        try writer.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*)
                    FROM frames
                    JOIN media_chunks ON media_chunks.id = frames.chunk_id
                    WHERE frames.schema_version >= 2
                      AND media_chunks.state = 'ready'
                    """
            ) ?? 0
        }
    }

    func v2JobIDsForTesting() throws -> [String] {
        try writer.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT id FROM processing_jobs ORDER BY id"
            )
        }
    }

    func v2CoordinatorSnapshotForTesting(chunkID: UUID) throws -> ArchiveV2CoordinatorSnapshot {
        try writer.read { database in
            let encodedChunkID = chunkID.uuidString.lowercased()
            return ArchiveV2CoordinatorSnapshot(
                chunkState: try String.fetchOne(
                    database,
                    sql: "SELECT state FROM media_chunks WHERE id = ?",
                    arguments: [encodedChunkID]
                ),
                frameCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM frames WHERE chunk_id = ?",
                    arguments: [encodedChunkID]
                ) ?? 0,
                queuedJobCount: try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM processing_jobs
                        WHERE state = 'queued'
                          AND parent_id IN (SELECT id FROM frames WHERE chunk_id = ?)
                        """,
                    arguments: [encodedChunkID]
                ) ?? 0,
                distinctEpochCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(DISTINCT capture_epoch_id) FROM frames WHERE chunk_id = ?",
                    arguments: [encodedChunkID]
                ) ?? 0,
                distinctTargetCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(DISTINCT target_window_id) FROM frames WHERE chunk_id = ?",
                    arguments: [encodedChunkID]
                ) ?? 0,
                distinctPolicyGenerationCount: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(DISTINCT policy_generation) FROM frames WHERE chunk_id = ?",
                    arguments: [encodedChunkID]
                ) ?? 0,
                mediaPaths: try String.fetchAll(
                    database,
                    sql: "SELECT media_path FROM frames WHERE chunk_id = ? ORDER BY pts_ms, id",
                    arguments: [encodedChunkID]
                )
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
                    INSERT INTO merged_text_records(
                        frame_id, approved_text, transcript_text, window_title,
                        app_name, url_host, url_path, producer_version, state
                    )
                    SELECT id, approved_text, '', window_title,
                           app_name, url_host, url_path, 'fixture-v1', 'ready'
                    FROM frames WHERE id = ?
                    """,
                arguments: [frameID]
            )
            try database.execute(
                sql: """
                    INSERT INTO frame_fts(
                        rowid, approved_text, window_title, app_name,
                        url_host, url_path, transcript_text
                    )
                    SELECT rowid, approved_text, window_title, app_name,
                           url_host, url_path, transcript_text
                    FROM merged_text_records WHERE frame_id = ?
                    """,
                arguments: [frameID]
            )
        }
    }

    private static func configuration(
        encryptionKey: Data,
        usesWAL: Bool,
        temporaryDirectory: URL?
    ) throws -> Configuration {
        if encryptionKey.count != LM008StoreDefaults.keyByteCount {
            throw ArchiveDatabaseError.invalidKeyLength
        }

        var configuration = Configuration()
        configuration.journalMode = usesWAL ? .wal : .default
        configuration.busyMode = .timeout(
            TimeInterval(LM008StoreDefaults.busyTimeoutMilliseconds) / 1_000
        )
        configuration.maximumReaderCount = LM008StoreDefaults.maximumReaderCount
        configuration.prepareDatabase { database in
            try database.usePassphrase(encryptionKey)
            guard
                let cipherVersion = try String.fetchOne(
                    database,
                    sql: "PRAGMA cipher_version"
                ), !cipherVersion.isEmpty
            else {
                throw ArchiveDatabaseError.missingCipherVersion
            }
            try database.execute(sql: "PRAGMA cipher_memory_security = ON")
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

    private static func verifyCipher(in writer: any DatabaseWriter) throws {
        try writer.read { database in
            guard let version = try String.fetchOne(database, sql: "PRAGMA cipher_version"),
                !version.isEmpty
            else {
                throw ArchiveDatabaseError.missingCipherVersion
            }
            let rows = try String.fetchAll(database, sql: "PRAGMA cipher_integrity_check")
            guard rows.isEmpty || rows.allSatisfy({ $0.lowercased() == "ok" }) else {
                throw ArchiveDatabaseError.cipherIntegrityFailure
            }
        }
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

    private static func isSafeAuditBundleIdentifier(_ value: String?) -> Bool {
        guard let value else { return true }
        return isSafeAuditScalar(value, permittedPunctuation: ".-")
    }

    private static func isSafeAuditHost(_ value: String?) -> Bool {
        guard let value else { return true }
        return value == value.lowercased(with: Locale(identifier: "en_US_POSIX"))
            && isSafeAuditScalar(value, permittedPunctuation: ".-")
    }

    private static func isSafeAuditRuleIdentifier(_ value: String?) -> Bool {
        guard let value else { return true }
        return isSafeAuditScalar(value, permittedPunctuation: ".:_-")
    }

    private static func isSafeAuditScalar(
        _ value: String,
        permittedPunctuation: String
    ) -> Bool {
        guard !value.isEmpty, value.count <= 255 else { return false }
        let punctuation = Set(permittedPunctuation.unicodeScalars)
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isAlphabetic
                || scalar.properties.numericType != nil
                || punctuation.contains(scalar)
        }
    }

    private static func isSafeAgentAccessAction(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let operations: Set<Substring> = [
            "status", "search", "timeline", "moment", "imageResource", "imageIssue",
            "imageRead",
        ]
        let outcomes: Set<Substring> = ["success", "denied", "failure", "cancelled"]
        return operations.contains(parts[0]) && outcomes.contains(parts[1])
    }

    private static func isSafeQueryHash(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.count == 64
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
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
