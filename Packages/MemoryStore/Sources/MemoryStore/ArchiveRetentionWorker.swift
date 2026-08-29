import CryptoKit
import Foundation
import GRDB
import MemoryContracts

public struct ArchiveRetentionPolicy: Equatable, Sendable {
    public static let defaultMaximumAge: TimeInterval = 30 * 24 * 60 * 60
    public static let defaultMaximumArchiveBytes: Int64 = 20_000_000_000
    public static let defaultMinimumAvailableCapacityBytes: Int64 = 1_000_000_000

    public static let `default` = ArchiveRetentionPolicy(
        maximumAge: defaultMaximumAge,
        maximumArchiveBytes: defaultMaximumArchiveBytes,
        minimumAvailableCapacityBytes: defaultMinimumAvailableCapacityBytes
    )

    public let maximumAge: TimeInterval
    public let maximumArchiveBytes: Int64
    public let minimumAvailableCapacityBytes: Int64

    public init(
        maximumAge: TimeInterval,
        maximumArchiveBytes: Int64,
        minimumAvailableCapacityBytes: Int64
    ) {
        self.maximumAge = maximumAge
        self.maximumArchiveBytes = maximumArchiveBytes
        self.minimumAvailableCapacityBytes = minimumAvailableCapacityBytes
    }
}

public enum ArchiveRetentionDeletionReason: String, Equatable, Hashable, Sendable {
    case retention
    case storageCap
    case lowDisk

    fileprivate var tombstoneReason: DeletionReason {
        switch self {
        case .retention: .retention
        case .storageCap, .lowDisk: .storageCap
        }
    }

    fileprivate var auditAction: String {
        switch self {
        case .retention: "retention_deleted"
        case .storageCap: "storage_cap_deleted"
        case .lowDisk: "low_disk_deleted"
        }
    }
}

public enum ArchiveRetentionStopReason: String, Equatable, Sendable {
    case storageCap
    case lowDisk
}

public struct ArchiveRetentionProgress: Equatable, Sendable {
    public let readyChunkCountBefore: Int
    public let readyByteCountBefore: Int64
    public let deletedChunkCount: Int
    public let deletedByteCount: Int64
    public let deletedReasons: [ArchiveRetentionDeletionReason: Int]
    public let readyChunkCountAfter: Int
    public let readyByteCountAfter: Int64
    public let availableCapacityBytesAfter: Int64
    public let captureShouldStop: Bool
    public let stopReason: ArchiveRetentionStopReason?
}

public enum ArchiveRetentionError: Error, Equatable, Sendable {
    case invalidPolicy
    case fileBackedArchiveRequired
    case malformedChunk
    case invalidAvailableCapacity
    case unsafeManagedPath
    case missingChunkDirectory
    case filesystemFailure
}

public final class ArchiveRetentionWorker: @unchecked Sendable {
    private let database: ArchiveDatabase
    private let paths: ArchivePaths
    private let policy: ArchiveRetentionPolicy
    private let fileManager: FileManager
    private let now: () -> Date
    private let availableCapacityBytes: () throws -> Int64
    private let makeIdentifier: () -> UUID

    public init(
        database: ArchiveDatabase,
        policy: ArchiveRetentionPolicy = .default,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        availableCapacityBytes: (() throws -> Int64)? = nil,
        makeIdentifier: @escaping () -> UUID = UUID.init
    ) throws {
        guard policy.maximumAge.isFinite, policy.maximumAge > 0,
            policy.maximumArchiveBytes > 0,
            policy.minimumAvailableCapacityBytes >= 0
        else {
            throw ArchiveRetentionError.invalidPolicy
        }
        guard let paths = database.paths else {
            throw ArchiveRetentionError.fileBackedArchiveRequired
        }
        self.database = database
        self.paths = paths
        self.policy = policy
        self.fileManager = fileManager
        self.now = now
        self.availableCapacityBytes =
            availableCapacityBytes ?? {
                let values = try paths.root.resourceValues(forKeys: [
                    .volumeAvailableCapacityForImportantUsageKey
                ])
                guard let capacity = values.volumeAvailableCapacityForImportantUsage,
                    capacity >= 0
                else {
                    throw ArchiveRetentionError.invalidAvailableCapacity
                }
                return capacity
            }
        self.makeIdentifier = makeIdentifier
    }

    public func run() throws -> ArchiveRetentionProgress {
        let runDate = now()
        guard runDate.timeIntervalSinceReferenceDate.isFinite else {
            throw ArchiveRetentionError.invalidPolicy
        }
        let initial = try readyChunks()
        let initialBytes = try Self.totalBytes(initial)
        var deletedChunkCount = 0
        var deletedByteCount: Int64 = 0
        var deletedReasons: [ArchiveRetentionDeletionReason: Int] = [:]

        let cutoff = runDate.addingTimeInterval(-policy.maximumAge)
        for candidate in initial where candidate.endedAt < cutoff {
            try delete(candidate, reason: .retention, at: runDate)
            deletedChunkCount += 1
            deletedByteCount = try Self.adding(deletedByteCount, candidate.byteCount)
            deletedReasons[.retention, default: 0] += 1
        }

        var remaining = try readyChunks()
        var remainingBytes = try Self.totalBytes(remaining)
        while remainingBytes > policy.maximumArchiveBytes, let oldest = remaining.first {
            try delete(oldest, reason: .storageCap, at: runDate)
            deletedChunkCount += 1
            deletedByteCount = try Self.adding(deletedByteCount, oldest.byteCount)
            deletedReasons[.storageCap, default: 0] += 1
            remaining.removeFirst()
            remainingBytes -= oldest.byteCount
        }

        var capacity = try checkedAvailableCapacity()
        while capacity < policy.minimumAvailableCapacityBytes, let oldest = remaining.first {
            try delete(oldest, reason: .lowDisk, at: runDate)
            deletedChunkCount += 1
            deletedByteCount = try Self.adding(deletedByteCount, oldest.byteCount)
            deletedReasons[.lowDisk, default: 0] += 1
            remaining.removeFirst()
            remainingBytes -= oldest.byteCount
            capacity = try checkedAvailableCapacity()
        }

        let final = try readyChunks()
        let finalBytes = try Self.totalBytes(final)
        capacity = try checkedAvailableCapacity()
        let stopReason: ArchiveRetentionStopReason?
        if capacity < policy.minimumAvailableCapacityBytes {
            stopReason = .lowDisk
        } else if finalBytes > policy.maximumArchiveBytes {
            stopReason = .storageCap
        } else {
            stopReason = nil
        }
        return ArchiveRetentionProgress(
            readyChunkCountBefore: initial.count,
            readyByteCountBefore: initialBytes,
            deletedChunkCount: deletedChunkCount,
            deletedByteCount: deletedByteCount,
            deletedReasons: deletedReasons,
            readyChunkCountAfter: final.count,
            readyByteCountAfter: finalBytes,
            availableCapacityBytesAfter: capacity,
            captureShouldStop: stopReason != nil,
            stopReason: stopReason
        )
    }

    private func readyChunks() throws -> [RetentionCandidate] {
        try database.atomicRead { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, relative_path, started_at, ended_at, byte_count
                    FROM media_chunks
                    WHERE state = 'ready'
                    ORDER BY started_at, id
                    """
            ).map { row in
                guard let chunkID = UUID(uuidString: row["id"] as String),
                    let startedAt = Self.decode(row["started_at"] as String),
                    let encodedEnd: String = row["ended_at"],
                    let endedAt = Self.decode(encodedEnd),
                    startedAt < endedAt,
                    let byteCount = Int64.fromDatabaseValue(row["byte_count"]),
                    byteCount >= 0
                else {
                    throw ArchiveRetentionError.malformedChunk
                }
                return RetentionCandidate(
                    id: chunkID,
                    relativeManifestPath: row["relative_path"],
                    startedAt: startedAt,
                    endedAt: endedAt,
                    byteCount: byteCount
                )
            }
        }
    }

    private func delete(
        _ candidate: RetentionCandidate,
        reason: ArchiveRetentionDeletionReason,
        at requestedAt: Date
    ) throws {
        let context = try beginDeletion(candidate, reason: reason, requestedAt: requestedAt)
        let sourceDirectory: URL
        let quarantineDirectory: URL
        do {
            sourceDirectory = try validatedChunkDirectory(candidate.relativeManifestPath)
            quarantineDirectory = try quarantineURL(tombstoneID: context.tombstoneID)
            guard fileManager.fileExists(atPath: sourceDirectory.path) else {
                throw ArchiveRetentionError.missingChunkDirectory
            }
            try ArchivePathProvider.rejectSymbolicLink(
                at: sourceDirectory,
                fileManager: fileManager
            )
            try ArchivePathProvider.createOwnerOnlyDirectory(
                at: quarantineDirectory.deletingLastPathComponent(),
                beneath: paths.root,
                fileManager: fileManager
            )
            try fileManager.moveItem(at: sourceDirectory, to: quarantineDirectory)
        } catch let error as ArchiveRetentionError {
            try markFailed(context.tombstoneID)
            throw error
        } catch {
            try markFailed(context.tombstoneID)
            throw ArchiveRetentionError.filesystemFailure
        }

        do {
            try commitDatabaseDeletion(context, reason: reason, completedAt: requestedAt)
            for thumbnail in context.thumbnailRelativePaths {
                let thumbnailURL = try validatedThumbnailURL(thumbnail)
                if fileManager.fileExists(atPath: thumbnailURL.path) {
                    try ArchivePathProvider.rejectSymbolicLink(
                        at: thumbnailURL,
                        fileManager: fileManager
                    )
                    try fileManager.removeItem(at: thumbnailURL)
                }
            }
            try fileManager.removeItem(at: quarantineDirectory)
            try verifyDeletion(context, reason: reason, completedAt: requestedAt)
        } catch let error as ArchiveRetentionError {
            throw error
        } catch {
            throw ArchiveRetentionError.filesystemFailure
        }
    }

    private func beginDeletion(
        _ candidate: RetentionCandidate,
        reason: ArchiveRetentionDeletionReason,
        requestedAt: Date
    ) throws -> DeletionContext {
        try database.atomicWrite { database in
            guard
                try String.fetchOne(
                    database,
                    sql: "SELECT state FROM media_chunks WHERE id = ?",
                    arguments: [candidate.id.encoded]
                ) == "ready"
            else {
                throw ArchiveRetentionError.malformedChunk
            }
            let frameRows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, thumbnail_path
                    FROM frames
                    WHERE chunk_id = ?
                    ORDER BY captured_at, id
                    """,
                arguments: [candidate.id.encoded]
            )
            let frameIDs: [UUID] = try frameRows.map { row in
                guard let identifier = UUID(uuidString: row["id"] as String) else {
                    throw ArchiveRetentionError.malformedChunk
                }
                return identifier
            }
            let encodedFrameIDs = frameIDs.map(\.encoded)
            let thumbnailPaths: [String] = frameRows.compactMap { row in
                row["thumbnail_path"] as String?
            }
            let affectedArtifactCount = try Self.affectedArtifactCount(
                frameIDs: encodedFrameIDs,
                database: database
            )
            let tombstoneID = makeIdentifier()
            let tombstone = try DeletionTombstone(
                id: tombstoneID,
                requestedInterval: DateInterval(
                    start: candidate.startedAt,
                    end: candidate.endedAt
                ),
                requestedFrameIDs: Set(frameIDs),
                reason: reason.tombstoneReason,
                requestedAt: requestedAt,
                completedAt: nil,
                affectedChunkCount: 1,
                affectedArtifactCount: affectedArtifactCount,
                replacementChunkIDs: [],
                verificationHash: nil,
                state: .rewriting
            )
            try Self.store(tombstone, database: database)
            if !encodedFrameIDs.isEmpty {
                let placeholders = Self.placeholders(encodedFrameIDs.count)
                let arguments = StatementArguments(encodedFrameIDs)
                try ArchiveSearchIndexStore.deleteFTSRows(
                    frameIDs: encodedFrameIDs,
                    database: database
                )
                try database.execute(
                    sql: """
                        UPDATE frames
                        SET text_state = 'suppressed', visual_state = 'suppressed'
                        WHERE id IN (\(placeholders))
                        """,
                    arguments: arguments
                )
                try database.execute(
                    sql: """
                        UPDATE merged_text_records
                        SET state = 'suppressed'
                        WHERE frame_id IN (\(placeholders))
                        """,
                    arguments: arguments
                )
            }
            return DeletionContext(
                tombstoneID: tombstoneID,
                chunkID: candidate.id,
                frameIDs: frameIDs,
                thumbnailRelativePaths: thumbnailPaths,
                affectedArtifactCount: affectedArtifactCount,
                byteCount: candidate.byteCount,
                requestedInterval: DateInterval(
                    start: candidate.startedAt,
                    end: candidate.endedAt
                )
            )
        }
    }

    private func commitDatabaseDeletion(
        _ context: DeletionContext,
        reason: ArchiveRetentionDeletionReason,
        completedAt: Date
    ) throws {
        try database.atomicWrite { database in
            let frameIDs = context.frameIDs.map(\.encoded)
            if !frameIDs.isEmpty {
                let placeholders = Self.placeholders(frameIDs.count)
                try database.execute(
                    sql: "DELETE FROM processing_jobs WHERE parent_id IN (\(placeholders))",
                    arguments: StatementArguments(frameIDs)
                )
            }
            try database.execute(
                sql: "DELETE FROM processing_jobs WHERE parent_id = ?",
                arguments: [context.chunkID.encoded]
            )
            try database.execute(
                sql: "DELETE FROM media_chunks WHERE id = ?",
                arguments: [context.chunkID.encoded]
            )
            let committed = try DeletionTombstone(
                id: context.tombstoneID,
                requestedInterval: context.requestedInterval,
                requestedFrameIDs: Set(context.frameIDs),
                reason: reason.tombstoneReason,
                requestedAt: completedAt,
                completedAt: completedAt,
                affectedChunkCount: 1,
                affectedArtifactCount: context.affectedArtifactCount,
                replacementChunkIDs: [],
                verificationHash: nil,
                state: .committed
            )
            try Self.replace(committed, database: database)
            try database.execute(
                sql: """
                    INSERT INTO audit_events(
                        id, occurred_at, actor, action, policy_id, result_count, query_hash
                    ) VALUES (?, ?, 'system', ?, NULL, ?, NULL)
                    """,
                arguments: [
                    makeIdentifier().encoded,
                    Self.encode(completedAt),
                    reason.auditAction,
                    context.frameIDs.count,
                ]
            )
        }
    }

    private func verifyDeletion(
        _ context: DeletionContext,
        reason: ArchiveRetentionDeletionReason,
        completedAt: Date
    ) throws {
        var proofBytes = Data(context.tombstoneID.encoded.utf8)
        proofBytes.append(contentsOf: context.chunkID.encoded.utf8)
        proofBytes.append(contentsOf: reason.rawValue.utf8)
        for frameID in context.frameIDs.sorted(by: { $0.encoded < $1.encoded }) {
            proofBytes.append(contentsOf: frameID.encoded.utf8)
        }
        proofBytes.append(contentsOf: String(context.byteCount).utf8)
        let verified = try DeletionTombstone(
            id: context.tombstoneID,
            requestedInterval: context.requestedInterval,
            requestedFrameIDs: Set(context.frameIDs),
            reason: reason.tombstoneReason,
            requestedAt: completedAt,
            completedAt: completedAt,
            affectedChunkCount: 1,
            affectedArtifactCount: context.affectedArtifactCount,
            replacementChunkIDs: [],
            verificationHash: Data(SHA256.hash(data: proofBytes)),
            state: .verified
        )
        try database.atomicWrite { database in
            guard
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM media_chunks WHERE id = ?",
                    arguments: [context.chunkID.encoded]
                ) == 0
            else {
                throw ArchiveRetentionError.malformedChunk
            }
            try Self.replace(verified, database: database)
        }
    }

    private func markFailed(_ tombstoneID: UUID) throws {
        try database.atomicWrite { database in
            guard
                let encoded = try String.fetchOne(
                    database,
                    sql: "SELECT encoded_tombstone FROM deletion_tombstones WHERE id = ?",
                    arguments: [tombstoneID.encoded]
                ),
                let data = encoded.data(using: .utf8),
                let existing = try? ContractJSON.decode(DeletionTombstone.self, from: data)
            else {
                return
            }
            let failed = try DeletionTombstone(
                id: existing.id,
                requestedInterval: existing.requestedInterval,
                requestedFrameIDs: existing.requestedFrameIDs,
                reason: existing.reason,
                requestedAt: existing.requestedAt,
                completedAt: nil,
                affectedChunkCount: existing.affectedChunkCount,
                affectedArtifactCount: existing.affectedArtifactCount,
                replacementChunkIDs: existing.replacementChunkIDs,
                verificationHash: nil,
                state: .failed
            )
            try Self.replace(failed, database: database)
        }
    }

    private func validatedChunkDirectory(_ relativeManifestPath: String) throws -> URL {
        let relative = try ArchiveRelativePath(relativeManifestPath)
        guard relative.rawValue.hasPrefix("media/"),
            relative.rawValue.hasSuffix("/manifest.json")
        else {
            throw ArchiveRetentionError.unsafeManagedPath
        }
        let manifest = paths.root.appending(
            path: relative.rawValue,
            directoryHint: .notDirectory
        )
        let directory = manifest.deletingLastPathComponent().standardizedFileURL
        guard directory.path.hasPrefix(paths.media.standardizedFileURL.path + "/") else {
            throw ArchiveRetentionError.unsafeManagedPath
        }
        return directory
    }

    private func validatedThumbnailURL(_ relativePath: String) throws -> URL {
        let relative = try ArchiveRelativePath(relativePath)
        guard relative.rawValue.hasPrefix("thumbnails/") else {
            throw ArchiveRetentionError.unsafeManagedPath
        }
        let url = paths.root.appending(
            path: relative.rawValue,
            directoryHint: .notDirectory
        ).standardizedFileURL
        guard url.path.hasPrefix(paths.thumbnails.standardizedFileURL.path + "/") else {
            throw ArchiveRetentionError.unsafeManagedPath
        }
        return url
    }

    private func quarantineURL(tombstoneID: UUID) throws -> URL {
        let parent = paths.quarantine.appendingPathComponent("retention", isDirectory: true)
        let destination = parent.appendingPathComponent(tombstoneID.encoded, isDirectory: true)
        guard
            destination.standardizedFileURL.path.hasPrefix(
                paths.quarantine.standardizedFileURL.path + "/"
            )
        else {
            throw ArchiveRetentionError.unsafeManagedPath
        }
        return destination
    }

    private func checkedAvailableCapacity() throws -> Int64 {
        let capacity = try availableCapacityBytes()
        guard capacity >= 0 else {
            throw ArchiveRetentionError.invalidAvailableCapacity
        }
        return capacity
    }

    private static func affectedArtifactCount(
        frameIDs: [String],
        database: Database
    ) throws -> Int {
        guard !frameIDs.isEmpty else { return 0 }
        let arguments = StatementArguments(frameIDs)
        let placeholders = placeholders(frameIDs.count)
        let tables = ["text_spans", "artifacts", "vector_offsets", "merged_text_records"]
        var total = frameIDs.count
        for table in tables {
            total +=
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM \(table) WHERE frame_id IN (\(placeholders))",
                    arguments: arguments
                ) ?? 0
        }
        return total
    }

    private static func store(_ tombstone: DeletionTombstone, database: Database) throws {
        guard
            let encoded = String(
                data: try ContractJSON.encode(tombstone),
                encoding: .utf8
            )
        else {
            throw ArchiveRetentionError.malformedChunk
        }
        try database.execute(
            sql: """
                INSERT INTO deletion_tombstones(id, encoded_tombstone, state)
                VALUES (?, ?, ?)
                """,
            arguments: [tombstone.id.encoded, encoded, tombstone.state.rawValue]
        )
    }

    private static func replace(_ tombstone: DeletionTombstone, database: Database) throws {
        guard
            let encoded = String(
                data: try ContractJSON.encode(tombstone),
                encoding: .utf8
            )
        else {
            throw ArchiveRetentionError.malformedChunk
        }
        try database.execute(
            sql: """
                UPDATE deletion_tombstones
                SET encoded_tombstone = ?, state = ?
                WHERE id = ?
                """,
            arguments: [encoded, tombstone.state.rawValue, tombstone.id.encoded]
        )
    }

    private static func totalBytes(_ candidates: [RetentionCandidate]) throws -> Int64 {
        try candidates.reduce(0) { try adding($0, $1.byteCount) }
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw ArchiveRetentionError.malformedChunk }
        return sum
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
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
}

private struct RetentionCandidate {
    let id: UUID
    let relativeManifestPath: String
    let startedAt: Date
    let endedAt: Date
    let byteCount: Int64
}

private struct DeletionContext {
    let tombstoneID: UUID
    let chunkID: UUID
    let frameIDs: [UUID]
    let thumbnailRelativePaths: [String]
    let affectedArtifactCount: Int
    let byteCount: Int64
    let requestedInterval: DateInterval
}

extension UUID {
    fileprivate var encoded: String { uuidString.lowercased() }
}
