import CryptoKit
import Darwin
import Foundation
import GRDB
import MemoryContracts

public enum ArchiveDeletionRewriteFault: String, Equatable, Sendable {
    case afterPlan
    case afterReplacementPublication
    case duringDatabaseCommit
    case afterDatabaseCommit
    case afterVectorCompaction
    case afterOldDirectoryDisposal
}

public enum ArchiveDeletionRewriteError: Error, Equatable, Sendable {
    case invalidOperation
    case missingJournal
    case missingSource
    case invalidManagedPath
    case replacementIntegrityFailure
    case databaseInvariantFailure
    case filesystemFailure
    case injectedFault(ArchiveDeletionRewriteFault)
}

public struct ArchiveDeletionVectorCompactor: Sendable {
    private let operation: @Sendable (Set<String>) throws -> Void

    public init(operation: @escaping @Sendable (Set<String>) throws -> Void) {
        self.operation = operation
    }

    public func compact(modelHashes: Set<String>) throws {
        guard !modelHashes.isEmpty else { return }
        try operation(modelHashes)
    }
}

public struct ArchiveDeletionRewriteResult: Equatable, Sendable {
    public let tombstoneID: UUID
    public let deletedFrameCount: Int
    public let replacementChunkIDs: Set<UUID>
    public let state: DeletionTombstoneState
}

public final class ArchiveDeletionRewriteWorker: @unchecked Sendable {
    public static let producerVersion = ArchiveDeletionRequestStore.rewriteProducerVersion

    private let database: ArchiveDatabase
    private let paths: ArchivePaths
    private let fileManager: FileManager
    private let vectorCompactor: ArchiveDeletionVectorCompactor
    private let makeIdentifier: () -> UUID
    private let now: () -> Date

    public init(
        database: ArchiveDatabase,
        vectorCompactor: ArchiveDeletionVectorCompactor,
        fileManager: FileManager = .default,
        makeIdentifier: @escaping () -> UUID = UUID.init,
        now: @escaping () -> Date = Date.init
    ) throws {
        guard let paths = database.paths else {
            throw ArchiveDeletionRewriteError.invalidOperation
        }
        self.database = database
        self.paths = paths
        self.vectorCompactor = vectorCompactor
        self.fileManager = fileManager
        self.makeIdentifier = makeIdentifier
        self.now = now
    }

    @discardableResult
    public func process(
        tombstoneID: UUID,
        fault: ArchiveDeletionRewriteFault? = nil
    ) throws -> ArchiveDeletionRewriteResult {
        var tombstone = try loadTombstone(tombstoneID)
        if tombstone.state == .verified {
            return result(tombstone)
        }
        guard tombstone.state == .rewriting || tombstone.state == .committed else {
            throw ArchiveDeletionRewriteError.invalidOperation
        }
        try markJobLeased(tombstoneID)

        let journal: DeletionRewriteJournal
        if let existing = try loadJournal(tombstoneID) {
            journal = existing
        } else {
            guard tombstone.state == .rewriting else {
                throw ArchiveDeletionRewriteError.missingJournal
            }
            journal = try createJournal(tombstone)
            try writeJournal(journal)
            tombstone = try replaceTombstone(
                tombstone,
                state: .rewriting,
                completedAt: nil,
                replacementChunkIDs: Set(journal.chunks.compactMap(\.replacementChunkID)),
                verificationHash: nil
            )
        }
        try inject(.afterPlan, requested: fault)

        if tombstone.state == .rewriting {
            try publishReplacements(journal)
            try inject(.afterReplacementPublication, requested: fault)
            tombstone = try commit(journal, tombstone: tombstone, fault: fault)
            try inject(.afterDatabaseCommit, requested: fault)
        }

        try vectorCompactor.compact(modelHashes: Set(journal.affectedVectorModelHashes))
        try inject(.afterVectorCompaction, requested: fault)
        try disposeDeletedThumbnails(journal)
        try disposeOldDirectories(journal)
        try inject(.afterOldDirectoryDisposal, requested: fault)
        tombstone = try verify(journal, tombstone: tombstone)
        try cleanupJournal(tombstoneID)
        return result(tombstone)
    }

    public func recoverPending() throws -> [ArchiveDeletionRewriteResult] {
        let identifiers = try database.atomicRead { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT deletion_tombstones.id
                    FROM deletion_tombstones
                    JOIN processing_jobs
                      ON processing_jobs.parent_id = deletion_tombstones.id
                     AND processing_jobs.kind IN ('mediaRewrite', 'media-rewrite')
                    WHERE deletion_tombstones.state IN ('rewriting', 'committed')
                    ORDER BY deletion_tombstones.id
                    """
            )
        }
        return try identifiers.map { encoded in
            guard let identifier = UUID(uuidString: encoded) else {
                throw ArchiveDeletionRewriteError.invalidOperation
            }
            return try process(tombstoneID: identifier)
        }
    }

    private func createJournal(_ tombstone: DeletionTombstone) throws
        -> DeletionRewriteJournal
    {
        let deleted = tombstone.requestedFrameIDs.sorted(by: Self.uuidOrder)
        guard !deleted.isEmpty else {
            throw ArchiveDeletionRewriteError.invalidOperation
        }
        return try database.atomicRead { database in
            let placeholders = Self.placeholders(deleted.count)
            let arguments = StatementArguments(deleted.map(\.encoded))
            let found =
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM frames WHERE id IN (\(placeholders))",
                    arguments: arguments
                ) ?? 0
            guard found == deleted.count else {
                throw ArchiveDeletionRewriteError.databaseInvariantFailure
            }
            let chunkIDs = try String.fetchAll(
                database,
                sql: """
                    SELECT DISTINCT chunk_id
                    FROM frames
                    WHERE id IN (\(placeholders))
                    ORDER BY chunk_id
                    """,
                arguments: arguments
            )
            var plans: [DeletionChunkPlan] = []
            for encodedChunkID in chunkIDs {
                guard let chunkID = UUID(uuidString: encodedChunkID),
                    let row = try Row.fetchOne(
                        database,
                        sql: """
                            SELECT relative_path
                            FROM media_chunks
                            WHERE id = ? AND state = 'ready' AND codec = 'heicKeyframes'
                            """,
                        arguments: [encodedChunkID]
                    )
                else {
                    throw ArchiveDeletionRewriteError.databaseInvariantFailure
                }
                let allFrames = try String.fetchAll(
                    database,
                    sql: "SELECT id FROM frames WHERE chunk_id = ? ORDER BY pts_ms, id",
                    arguments: [encodedChunkID]
                ).compactMap(UUID.init(uuidString:))
                let deletedInChunk = allFrames.filter(tombstone.requestedFrameIDs.contains)
                let retained = allFrames.filter { !tombstone.requestedFrameIDs.contains($0) }
                guard !deletedInChunk.isEmpty,
                    deletedInChunk.count + retained.count == allFrames.count
                else {
                    throw ArchiveDeletionRewriteError.databaseInvariantFailure
                }
                let replacementID = retained.isEmpty ? nil : makeIdentifier()
                let originalPath: String = row["relative_path"]
                let replacementPath = try replacementID.map {
                    try Self.replacementManifestPath(
                        original: originalPath,
                        oldChunkID: chunkID,
                        replacementChunkID: $0
                    )
                }
                plans.append(
                    DeletionChunkPlan(
                        originalChunkID: chunkID,
                        originalManifestPath: originalPath,
                        replacementChunkID: replacementID,
                        replacementManifestPath: replacementPath,
                        deletedFrameIDs: deletedInChunk,
                        retainedFrameIDs: retained
                    )
                )
            }
            let thumbnailPaths = try String.fetchAll(
                database,
                sql: """
                    SELECT thumbnail_path
                    FROM frames
                    WHERE id IN (\(placeholders)) AND thumbnail_path IS NOT NULL
                    ORDER BY id
                    """,
                arguments: arguments
            )
            let ftsRowIDs = try Int64.fetchAll(
                database,
                sql: """
                    SELECT rowid
                    FROM merged_text_records
                    WHERE frame_id IN (\(placeholders))
                    ORDER BY rowid
                    """,
                arguments: arguments
            )
            let modelHashes = try String.fetchAll(
                database,
                sql: """
                    SELECT DISTINCT model_hash
                    FROM vector_offsets
                    WHERE frame_id IN (\(placeholders))
                    ORDER BY model_hash
                    """,
                arguments: arguments
            )
            return DeletionRewriteJournal(
                tombstoneID: tombstone.id,
                requestedAt: tombstone.requestedAt,
                deletedFrameIDs: deleted,
                deletedFTSRowIDs: ftsRowIDs,
                deletedThumbnailPaths: thumbnailPaths,
                affectedVectorModelHashes: modelHashes,
                chunks: plans
            )
        }
    }

    private func publishReplacements(_ journal: DeletionRewriteJournal) throws {
        for plan in journal.chunks where plan.replacementChunkID != nil {
            guard let replacementID = plan.replacementChunkID,
                let replacementPath = plan.replacementManifestPath
            else {
                throw ArchiveDeletionRewriteError.invalidOperation
            }
            let destination = try chunkDirectory(replacementPath, expectedChunkID: replacementID)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try verifiedReplacement(plan)
                continue
            }
            let sourcePath = try ArchiveRelativePath(plan.originalManifestPath)
            let source = try ArchiveHEICChunkVerifier.verify(
                paths: paths,
                manifestRelativePath: sourcePath,
                expectedChunkID: plan.originalChunkID,
                fileManager: fileManager
            )
            let retained = source.frames.filter { plan.retainedFrameIDs.contains($0.id) }
            guard retained.count == plan.retainedFrameIDs.count,
                Set(retained.map(\.id)) == Set(plan.retainedFrameIDs),
                let firstPTS = retained.first?.presentationTimeMilliseconds
            else {
                throw ArchiveDeletionRewriteError.replacementIntegrityFailure
            }
            let staging = destination.deletingLastPathComponent().appendingPathComponent(
                ".\(destination.lastPathComponent).partial",
                isDirectory: true
            )
            guard !fileManager.fileExists(atPath: staging.path) else {
                try fileManager.removeItem(at: staging)
                return try publishReplacements(journal)
            }
            try ArchivePathProvider.createOwnerOnlyDirectory(
                at: staging.appendingPathComponent("frames", isDirectory: true),
                beneath: paths.root,
                fileManager: fileManager
            )
            var entries: [HEICKeyframeEntry] = []
            for frame in retained {
                let sourceURL = paths.root.appending(
                    path: frame.archiveRelativePath,
                    directoryHint: .notDirectory
                )
                let bytes = try Data(contentsOf: sourceURL)
                guard Int64(bytes.count) == frame.byteCount,
                    Data(SHA256.hash(data: bytes)) == frame.sha256
                else {
                    throw ArchiveDeletionRewriteError.replacementIntegrityFailure
                }
                let relativePath = "frames/\(frame.id.encoded).heic"
                let destinationURL = staging.appending(
                    path: relativePath,
                    directoryHint: .notDirectory
                )
                try writeOwnerOnly(bytes, to: destinationURL)
                entries.append(
                    try HEICKeyframeEntry(
                        frameID: frame.id,
                        presentationTimeMS: frame.presentationTimeMilliseconds - firstPTS,
                        relativePath: relativePath,
                        byteCount: frame.byteCount,
                        sha256: frame.sha256
                    )
                )
            }
            let manifest = try HEICKeyframeManifest(
                chunkID: replacementID,
                captureEpochID: source.manifest.captureEpochID,
                targetWindowID: source.manifest.targetWindowID,
                width: source.manifest.width,
                height: source.manifest.height,
                frames: entries
            )
            try writeOwnerOnly(
                try ContractJSON.encode(manifest),
                to: staging.appendingPathComponent("manifest.json", isDirectory: false)
            )
            let status = staging.path.withCString { sourcePath in
                destination.path.withCString { destinationPath in
                    Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                }
            }
            guard status == 0 else {
                throw ArchiveDeletionRewriteError.filesystemFailure
            }
            try synchronizeDirectory(destination.deletingLastPathComponent())
            _ = try verifiedReplacement(plan)
        }
    }

    private func commit(
        _ journal: DeletionRewriteJournal,
        tombstone: DeletionTombstone,
        fault: ArchiveDeletionRewriteFault?
    ) throws -> DeletionTombstone {
        let replacements = try Dictionary(
            uniqueKeysWithValues: journal.chunks.compactMap {
                plan -> (UUID, ArchiveVerifiedHEICChunk)? in
                guard let replacementID = plan.replacementChunkID else { return nil }
                return (replacementID, try verifiedReplacement(plan))
            }
        )
        return try database.atomicWrite { database in
            for plan in journal.chunks {
                if let replacementID = plan.replacementChunkID,
                    let replacement = replacements[replacementID],
                    let replacementPath = plan.replacementManifestPath
                {
                    guard
                        let old = try Row.fetchOne(
                            database,
                            sql: """
                                SELECT capture_epoch_id, target_window_id
                                FROM media_chunks WHERE id = ? AND state = 'ready'
                                """,
                            arguments: [plan.originalChunkID.encoded]
                        )
                    else {
                        throw ArchiveDeletionRewriteError.databaseInvariantFailure
                    }
                    let retainedIDs = plan.retainedFrameIDs.map(\.encoded)
                    let placeholders = Self.placeholders(retainedIDs.count)
                    guard
                        let bounds = try Row.fetchOne(
                            database,
                            sql: """
                                SELECT MIN(captured_at) AS started_at,
                                       MAX(captured_at) AS ended_at
                                FROM frames WHERE id IN (\(placeholders))
                                """,
                            arguments: StatementArguments(retainedIDs)
                        ), let startedAt: String = bounds["started_at"],
                        let encodedLastFrame: String = bounds["ended_at"],
                        let lastFrame = Self.decode(encodedLastFrame)
                    else {
                        throw ArchiveDeletionRewriteError.databaseInvariantFailure
                    }
                    let endedAt = Self.encode(lastFrame.addingTimeInterval(0.001))
                    try database.execute(
                        sql: """
                            INSERT INTO media_chunks(
                                id, capture_epoch_id, target_window_id, relative_path,
                                started_at, ended_at, codec, width, height, frame_count,
                                byte_count, sha256, state
                            ) VALUES (?, ?, ?, ?, ?, ?, 'heicKeyframes', ?, ?, ?, ?, ?, 'ready')
                            """,
                        arguments: [
                            replacementID.encoded,
                            old["capture_epoch_id"] as String,
                            old["target_window_id"] as Int64,
                            replacementPath,
                            startedAt,
                            endedAt,
                            replacement.manifest.width,
                            replacement.manifest.height,
                            replacement.frames.count,
                            replacement.totalByteCount,
                            replacement.manifestSHA256.lowercaseHex,
                        ]
                    )
                    for frame in replacement.frames {
                        try database.execute(
                            sql: """
                                UPDATE frames
                                SET chunk_id = ?, pts_ms = ?, media_path = ?,
                                    media_sha256 = ?, media_byte_count = ?
                                WHERE id = ?
                                """,
                            arguments: [
                                replacementID.encoded,
                                frame.presentationTimeMilliseconds,
                                frame.archiveRelativePath,
                                frame.sha256.lowercaseHex,
                                frame.byteCount,
                                frame.id.encoded,
                            ]
                        )
                        guard database.changesCount == 1 else {
                            throw ArchiveDeletionRewriteError.databaseInvariantFailure
                        }
                    }
                }
            }
            let deletedIDs = journal.deletedFrameIDs.map(\.encoded)
            let deletedPlaceholders = Self.placeholders(deletedIDs.count)
            try database.execute(
                sql: "DELETE FROM processing_jobs WHERE parent_id IN (\(deletedPlaceholders))",
                arguments: StatementArguments(deletedIDs)
            )
            for plan in journal.chunks {
                try database.execute(
                    sql: "DELETE FROM media_chunks WHERE id = ?",
                    arguments: [plan.originalChunkID.encoded]
                )
            }
            if fault == .duringDatabaseCommit {
                throw ArchiveDeletionRewriteError.injectedFault(.duringDatabaseCommit)
            }
            let completedAt = now()
            let committed = try Self.updated(
                tombstone,
                state: .committed,
                completedAt: completedAt,
                replacementChunkIDs: Set(journal.chunks.compactMap(\.replacementChunkID)),
                verificationHash: nil
            )
            try Self.persist(committed, database: database)
            try database.execute(
                sql: """
                    UPDATE processing_jobs
                    SET state = 'succeeded', next_attempt_at = NULL,
                        error_code = NULL, lease_expires_at = NULL
                    WHERE parent_id = ? AND kind IN ('mediaRewrite', 'media-rewrite')
                    """,
                arguments: [tombstone.id.encoded]
            )
            try database.execute(
                sql: """
                    INSERT INTO audit_events(
                        id, occurred_at, actor, action, policy_id, result_count, query_hash
                    ) VALUES (?, ?, 'system', 'deletion_committed', NULL, ?, NULL)
                    """,
                arguments: [makeIdentifier().encoded, Self.encode(completedAt), deletedIDs.count]
            )
            return committed
        }
    }

    private func verify(
        _ journal: DeletionRewriteJournal,
        tombstone: DeletionTombstone
    ) throws -> DeletionTombstone {
        for plan in journal.chunks {
            let old = try chunkDirectory(
                plan.originalManifestPath,
                expectedChunkID: plan.originalChunkID
            )
            guard !fileManager.fileExists(atPath: old.path) else {
                throw ArchiveDeletionRewriteError.replacementIntegrityFailure
            }
            if plan.replacementChunkID != nil {
                let replacement = try verifiedReplacement(plan)
                guard Set(replacement.frames.map(\.id)) == Set(plan.retainedFrameIDs),
                    Set(replacement.frames.map(\.id)).isDisjoint(with: plan.deletedFrameIDs)
                else {
                    throw ArchiveDeletionRewriteError.replacementIntegrityFailure
                }
            }
        }
        let deletedIDs = journal.deletedFrameIDs.map(\.encoded)
        let placeholders = Self.placeholders(deletedIDs.count)
        try database.atomicRead { database in
            for table in [
                "frames", "text_spans", "artifacts", "vector_offsets", "merged_text_records",
            ] {
                let column = table == "frames" ? "id" : "frame_id"
                guard
                    try Int.fetchOne(
                        database,
                        sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) IN (\(placeholders))",
                        arguments: StatementArguments(deletedIDs)
                    ) == 0
                else {
                    throw ArchiveDeletionRewriteError.databaseInvariantFailure
                }
            }
            if !journal.deletedFTSRowIDs.isEmpty {
                let ftsPlaceholders = Self.placeholders(journal.deletedFTSRowIDs.count)
                guard
                    try Int.fetchOne(
                        database,
                        sql:
                            "SELECT COUNT(*) FROM frame_fts_docsize WHERE id IN (\(ftsPlaceholders))",
                        arguments: StatementArguments(journal.deletedFTSRowIDs)
                    ) == 0
                else {
                    throw ArchiveDeletionRewriteError.databaseInvariantFailure
                }
            }
        }
        for relativePath in journal.deletedThumbnailPaths {
            let url = try managedURL(relativePath, expectedRoot: paths.thumbnails)
            guard !fileManager.fileExists(atPath: url.path) else {
                throw ArchiveDeletionRewriteError.replacementIntegrityFailure
            }
        }
        let proof = Data(SHA256.hash(data: try Self.encodeJournal(journal)))
        return try replaceTombstone(
            tombstone,
            state: .verified,
            completedAt: tombstone.completedAt ?? now(),
            replacementChunkIDs: tombstone.replacementChunkIDs,
            verificationHash: proof
        )
    }

    private func disposeDeletedThumbnails(_ journal: DeletionRewriteJournal) throws {
        for relativePath in journal.deletedThumbnailPaths {
            let url = try managedURL(relativePath, expectedRoot: paths.thumbnails)
            if fileManager.fileExists(atPath: url.path) {
                try ArchivePathProvider.rejectSymbolicLink(at: url, fileManager: fileManager)
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func disposeOldDirectories(_ journal: DeletionRewriteJournal) throws {
        let retiredRoot = journalDirectory(journal.tombstoneID).appendingPathComponent(
            "retired",
            isDirectory: true
        )
        try ArchivePathProvider.createOwnerOnlyDirectory(
            at: retiredRoot,
            beneath: paths.root,
            fileManager: fileManager
        )
        for plan in journal.chunks {
            let source = try chunkDirectory(
                plan.originalManifestPath,
                expectedChunkID: plan.originalChunkID
            )
            let retired = retiredRoot.appendingPathComponent(
                plan.originalChunkID.encoded,
                isDirectory: true
            )
            if fileManager.fileExists(atPath: source.path) {
                try ArchivePathProvider.rejectSymbolicLink(at: source, fileManager: fileManager)
                guard !fileManager.fileExists(atPath: retired.path) else {
                    throw ArchiveDeletionRewriteError.filesystemFailure
                }
                try fileManager.moveItem(at: source, to: retired)
            }
            if fileManager.fileExists(atPath: retired.path) {
                try fileManager.removeItem(at: retired)
            }
        }
        try synchronizeDirectory(retiredRoot)
    }

    private func verifiedReplacement(_ plan: DeletionChunkPlan) throws
        -> ArchiveVerifiedHEICChunk
    {
        guard let replacementID = plan.replacementChunkID,
            let replacementPath = plan.replacementManifestPath
        else {
            throw ArchiveDeletionRewriteError.invalidOperation
        }
        do {
            return try ArchiveHEICChunkVerifier.verify(
                paths: paths,
                manifestRelativePath: try ArchiveRelativePath(replacementPath),
                expectedChunkID: replacementID,
                fileManager: fileManager
            )
        } catch {
            throw ArchiveDeletionRewriteError.replacementIntegrityFailure
        }
    }

    private func loadTombstone(_ id: UUID) throws -> DeletionTombstone {
        try database.atomicRead { database in
            guard
                let encoded = try String.fetchOne(
                    database,
                    sql: "SELECT encoded_tombstone FROM deletion_tombstones WHERE id = ?",
                    arguments: [id.encoded]
                ), let data = encoded.data(using: .utf8),
                let tombstone = try? ContractJSON.decode(DeletionTombstone.self, from: data)
            else {
                throw ArchiveDeletionRewriteError.invalidOperation
            }
            return tombstone
        }
    }

    private func replaceTombstone(
        _ tombstone: DeletionTombstone,
        state: DeletionTombstoneState,
        completedAt: Date?,
        replacementChunkIDs: Set<UUID>,
        verificationHash: Data?
    ) throws -> DeletionTombstone {
        let updated = try Self.updated(
            tombstone,
            state: state,
            completedAt: completedAt,
            replacementChunkIDs: replacementChunkIDs,
            verificationHash: verificationHash
        )
        try database.atomicWrite { database in
            try Self.persist(updated, database: database)
        }
        return updated
    }

    private static func updated(
        _ tombstone: DeletionTombstone,
        state: DeletionTombstoneState,
        completedAt: Date?,
        replacementChunkIDs: Set<UUID>,
        verificationHash: Data?
    ) throws -> DeletionTombstone {
        try DeletionTombstone(
            id: tombstone.id,
            requestedInterval: tombstone.requestedInterval,
            requestedFrameIDs: tombstone.requestedFrameIDs,
            reason: tombstone.reason,
            requestedAt: tombstone.requestedAt,
            completedAt: completedAt,
            affectedChunkCount: tombstone.affectedChunkCount,
            affectedArtifactCount: tombstone.affectedArtifactCount,
            replacementChunkIDs: replacementChunkIDs,
            verificationHash: verificationHash,
            state: state
        )
    }

    private static func persist(_ tombstone: DeletionTombstone, database: Database) throws {
        guard
            let encoded = String(
                data: try ContractJSON.encode(tombstone),
                encoding: .utf8
            )
        else {
            throw ArchiveDeletionRewriteError.invalidOperation
        }
        try database.execute(
            sql: """
                UPDATE deletion_tombstones
                SET encoded_tombstone = ?, state = ?
                WHERE id = ?
                """,
            arguments: [encoded, tombstone.state.rawValue, tombstone.id.encoded]
        )
        guard database.changesCount == 1 else {
            throw ArchiveDeletionRewriteError.invalidOperation
        }
    }

    private func markJobLeased(_ tombstoneID: UUID) throws {
        try database.atomicWrite { database in
            try database.execute(
                sql: """
                    UPDATE processing_jobs
                    SET state = 'leased', attempts = MIN(attempts + 1, 3),
                        lease_expires_at = ?, next_attempt_at = NULL, error_code = NULL
                    WHERE parent_id = ?
                      AND kind IN ('mediaRewrite', 'media-rewrite')
                      AND state NOT IN ('succeeded', 'permanentFailure', 'cancelled')
                    """,
                arguments: [Self.encode(now().addingTimeInterval(120)), tombstoneID.encoded]
            )
        }
    }

    private func writeJournal(_ journal: DeletionRewriteJournal) throws {
        let directory = journalDirectory(journal.tombstoneID)
        try ArchivePathProvider.createOwnerOnlyDirectory(
            at: directory,
            beneath: paths.root,
            fileManager: fileManager
        )
        let destination = journalURL(journal.tombstoneID)
        let partial = directory.appendingPathComponent(".journal.json.partial")
        let bytes = try Self.encodeJournal(journal)
        try bytes.write(to: partial, options: Data.WritingOptions.withoutOverwriting)
        try fileManager.setAttributes(
            [.posixPermissions: ArchivePathProvider.filePermissions],
            ofItemAtPath: partial.path
        )
        let handle = try FileHandle(forWritingTo: partial)
        try handle.synchronize()
        try handle.close()
        try fileManager.moveItem(at: partial, to: destination)
        try synchronizeDirectory(directory)
    }

    private func loadJournal(_ tombstoneID: UUID) throws -> DeletionRewriteJournal? {
        let url = journalURL(tombstoneID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let journal = try Self.decodeJournal(Data(contentsOf: url))
            guard journal.tombstoneID == tombstoneID else {
                throw ArchiveDeletionRewriteError.missingJournal
            }
            return journal
        } catch let error as ArchiveDeletionRewriteError {
            throw error
        } catch {
            throw ArchiveDeletionRewriteError.missingJournal
        }
    }

    private func cleanupJournal(_ tombstoneID: UUID) throws {
        let directory = journalDirectory(tombstoneID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    private func journalDirectory(_ tombstoneID: UUID) -> URL {
        paths.quarantine
            .appendingPathComponent("deletion", isDirectory: true)
            .appendingPathComponent(tombstoneID.encoded, isDirectory: true)
    }

    private func journalURL(_ tombstoneID: UUID) -> URL {
        journalDirectory(tombstoneID).appendingPathComponent(
            "journal.json",
            isDirectory: false
        )
    }

    private func chunkDirectory(_ manifestPath: String, expectedChunkID: UUID) throws -> URL {
        let relative = try ArchiveRelativePath(manifestPath)
        guard relative.rawValue.hasSuffix("/\(expectedChunkID.encoded)/manifest.json") else {
            throw ArchiveDeletionRewriteError.invalidManagedPath
        }
        let directory = paths.root.appending(
            path: relative.rawValue,
            directoryHint: .notDirectory
        ).deletingLastPathComponent().standardizedFileURL
        guard directory.path.hasPrefix(paths.media.standardizedFileURL.path + "/") else {
            throw ArchiveDeletionRewriteError.invalidManagedPath
        }
        return directory
    }

    private func managedURL(_ relativePath: String, expectedRoot: URL) throws -> URL {
        let relative = try ArchiveRelativePath(relativePath)
        let url = paths.root.appending(
            path: relative.rawValue,
            directoryHint: .notDirectory
        ).standardizedFileURL
        guard url.path.hasPrefix(expectedRoot.standardizedFileURL.path + "/") else {
            throw ArchiveDeletionRewriteError.invalidManagedPath
        }
        return url
    }

    private func writeOwnerOnly(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        try fileManager.setAttributes(
            [.posixPermissions: ArchivePathProvider.filePermissions],
            ofItemAtPath: url.path
        )
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ArchiveDeletionRewriteError.filesystemFailure }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ArchiveDeletionRewriteError.filesystemFailure
        }
    }

    private func inject(
        _ point: ArchiveDeletionRewriteFault,
        requested: ArchiveDeletionRewriteFault?
    ) throws {
        if requested == point {
            throw ArchiveDeletionRewriteError.injectedFault(point)
        }
    }

    private func result(_ tombstone: DeletionTombstone) -> ArchiveDeletionRewriteResult {
        ArchiveDeletionRewriteResult(
            tombstoneID: tombstone.id,
            deletedFrameCount: tombstone.requestedFrameIDs.count,
            replacementChunkIDs: tombstone.replacementChunkIDs,
            state: tombstone.state
        )
    }

    private static func replacementManifestPath(
        original: String,
        oldChunkID: UUID,
        replacementChunkID: UUID
    ) throws -> String {
        let suffix = "/\(oldChunkID.encoded)/manifest.json"
        guard original.hasPrefix("media/"), original.hasSuffix(suffix) else {
            throw ArchiveDeletionRewriteError.invalidManagedPath
        }
        return String(original.dropLast(suffix.count))
            + "/\(replacementChunkID.encoded)/manifest.json"
    }

    private static func relativePath(_ url: URL, root: URL) throws -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else {
            throw ArchiveDeletionRewriteError.invalidManagedPath
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private static func encodeJournal(_ journal: DeletionRewriteJournal) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(journal)
    }

    private static func decodeJournal(_ data: Data) throws -> DeletionRewriteJournal {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(DeletionRewriteJournal.self, from: data)
    }

    private static func encode(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
    }

    private static func decode(_ value: String) -> Date? {
        try? Date(
            value,
            strategy: Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
        )
    }

    private static func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.encoded < rhs.encoded
    }
}

private struct DeletionRewriteJournal: Codable, Equatable, Sendable {
    let tombstoneID: UUID
    let requestedAt: Date
    let deletedFrameIDs: [UUID]
    let deletedFTSRowIDs: [Int64]
    let deletedThumbnailPaths: [String]
    let affectedVectorModelHashes: [String]
    let chunks: [DeletionChunkPlan]
}

private struct DeletionChunkPlan: Codable, Equatable, Sendable {
    let originalChunkID: UUID
    let originalManifestPath: String
    let replacementChunkID: UUID?
    let replacementManifestPath: String?
    let deletedFrameIDs: [UUID]
    let retainedFrameIDs: [UUID]
}

extension UUID {
    fileprivate var encoded: String { uuidString.lowercased() }
}

extension Data {
    fileprivate var lowercaseHex: String { map { String(format: "%02x", $0) }.joined() }
}
