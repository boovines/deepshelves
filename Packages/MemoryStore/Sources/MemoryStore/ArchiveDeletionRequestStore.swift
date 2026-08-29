import Foundation
import GRDB
import MemoryContracts

public enum ArchiveDeletionTarget: Equatable, Sendable {
    case moment(UUID)
    case range(DateInterval)
}

public struct ArchiveDeletionRequest: Equatable, Sendable {
    public let id: UUID
    public let target: ArchiveDeletionTarget
    public let requestedAt: Date
    public let rewriteJobID: UUID
    public let auditEventID: UUID

    public init(
        id: UUID,
        target: ArchiveDeletionTarget,
        requestedAt: Date,
        rewriteJobID: UUID,
        auditEventID: UUID
    ) {
        self.id = id
        self.target = target
        self.requestedAt = requestedAt
        self.rewriteJobID = rewriteJobID
        self.auditEventID = auditEventID
    }
}

public enum ArchiveDeletionOperationState: String, Equatable, Sendable {
    case queued
    case rewriting
    case verifying
    case complete
    case failed
}

public struct ArchiveDeletionOperation: Equatable, Sendable {
    public let tombstone: DeletionTombstone
    public let rewriteJobID: UUID
    public let state: ArchiveDeletionOperationState
    public let completedRewriteCount: Int
    public let totalRewriteCount: Int
    public let failureCode: String?

    public init(
        tombstone: DeletionTombstone,
        rewriteJobID: UUID,
        state: ArchiveDeletionOperationState,
        completedRewriteCount: Int,
        totalRewriteCount: Int,
        failureCode: String?
    ) {
        self.tombstone = tombstone
        self.rewriteJobID = rewriteJobID
        self.state = state
        self.completedRewriteCount = completedRewriteCount
        self.totalRewriteCount = totalRewriteCount
        self.failureCode = failureCode
    }
}

public enum ArchiveDeletionRequestStoreError: Error, Equatable, Sendable {
    case invalidRequest
    case noVisibleFrames
    case conflictingRequest
    case malformedRecord
}

public final class ArchiveDeletionRequestStore: @unchecked Sendable {
    public static let rewriteProducerVersion = "deletion-v1"
    public static let rewritePriority = 1_000

    private let database: ArchiveDatabase

    public init(database: ArchiveDatabase) throws {
        self.database = database
        let required = Set(["deletion_tombstones", "audit_events", "processing_jobs"])
        guard required.isSubset(of: Set(try database.logicalTableNames())) else {
            throw ArchiveDeletionRequestStoreError.malformedRecord
        }
    }

    @discardableResult
    public func request(_ request: ArchiveDeletionRequest) throws -> ArchiveDeletionOperation {
        try Self.validate(request)
        return try database.atomicWrite { database in
            if let existing = try Self.operationRow(id: request.id, database: database) {
                let operation = try Self.operation(from: existing)
                guard Self.matches(request, operation: operation) else {
                    throw ArchiveDeletionRequestStoreError.conflictingRequest
                }
                return operation
            }
            guard try !Self.identifierExists(request.rewriteJobID, database: database),
                try !Self.auditIdentifierExists(request.auditEventID, database: database)
            else {
                throw ArchiveDeletionRequestStoreError.conflictingRequest
            }

            let frames = try Self.targetFrames(request.target, database: database)
            guard !frames.isEmpty else {
                throw ArchiveDeletionRequestStoreError.noVisibleFrames
            }
            let frameIDs = frames.map(\.frameID)
            let chunkCount = Set(frames.map(\.chunkID)).count
            let artifactCount = try Self.affectedArtifactCount(
                frameIDs: frameIDs,
                database: database
            )
            let tombstone = try DeletionTombstone(
                id: request.id,
                requestedInterval: request.target.requestedInterval,
                requestedFrameIDs: Set(frameIDs),
                reason: request.target.reason,
                requestedAt: request.requestedAt,
                completedAt: nil,
                affectedChunkCount: chunkCount,
                affectedArtifactCount: artifactCount,
                replacementChunkIDs: [],
                verificationHash: nil,
                state: .rewriting
            )
            guard
                let encodedTombstone = String(
                    data: try ContractJSON.encode(tombstone),
                    encoding: .utf8
                )
            else {
                throw ArchiveDeletionRequestStoreError.malformedRecord
            }

            try database.execute(
                sql: """
                    INSERT INTO deletion_tombstones(id, encoded_tombstone, state)
                    VALUES (?, ?, 'rewriting')
                    """,
                arguments: [request.id.encoded, encodedTombstone]
            )
            let placeholders = Self.placeholders(frameIDs.count)
            let identifiers = frameIDs.map(\.encoded)
            try ArchiveSearchIndexStore.deleteFTSRows(
                frameIDs: identifiers,
                database: database
            )
            try database.execute(
                sql: """
                    UPDATE frames
                    SET text_state = 'suppressed', visual_state = 'suppressed'
                    WHERE id IN (\(placeholders))
                    """,
                arguments: StatementArguments(identifiers)
            )
            try database.execute(
                sql: """
                    UPDATE merged_text_records
                    SET state = 'suppressed'
                    WHERE frame_id IN (\(placeholders))
                    """,
                arguments: StatementArguments(identifiers)
            )
            try database.execute(
                sql: """
                    UPDATE processing_jobs
                    SET state = 'cancelled', next_attempt_at = NULL,
                        error_code = NULL, lease_expires_at = NULL
                    WHERE parent_id IN (\(placeholders))
                      AND kind NOT IN ('mediaRewrite', 'media-rewrite')
                      AND state NOT IN ('succeeded', 'permanentFailure', 'cancelled')
                    """,
                arguments: StatementArguments(identifiers)
            )
            try database.execute(
                sql: """
                    INSERT INTO processing_jobs(
                        id, parent_id, kind, priority, state, attempts,
                        next_attempt_at, producer_version, error_code, lease_expires_at
                    ) VALUES (?, ?, 'mediaRewrite', ?, 'queued', 0,
                              NULL, ?, NULL, NULL)
                    """,
                arguments: [
                    request.rewriteJobID.encoded,
                    request.id.encoded,
                    Self.rewritePriority,
                    Self.rewriteProducerVersion,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO audit_events(
                        id, occurred_at, actor, action, policy_id, result_count, query_hash
                    ) VALUES (?, ?, 'owner', 'deletion_requested', NULL, ?, NULL)
                    """,
                arguments: [
                    request.auditEventID.encoded,
                    Self.encode(request.requestedAt),
                    frameIDs.count,
                ]
            )
            guard let row = try Self.operationRow(id: request.id, database: database) else {
                throw ArchiveDeletionRequestStoreError.malformedRecord
            }
            return try Self.operation(from: row)
        }
    }

    public func operation(id: UUID) throws -> ArchiveDeletionOperation? {
        try database.atomicRead { database in
            try Self.operationRow(id: id, database: database).map(Self.operation(from:))
        }
    }

    public func pendingOperations() throws -> [ArchiveDeletionOperation] {
        try database.atomicRead { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT deletion_tombstones.encoded_tombstone,
                           deletion_tombstones.state AS tombstone_state,
                           processing_jobs.id AS job_id,
                           processing_jobs.state AS job_state,
                           processing_jobs.error_code
                    FROM deletion_tombstones
                    JOIN processing_jobs
                      ON processing_jobs.parent_id = deletion_tombstones.id
                     AND processing_jobs.kind IN ('mediaRewrite', 'media-rewrite')
                    WHERE deletion_tombstones.state NOT IN ('committed', 'verified')
                    ORDER BY deletion_tombstones.id
                    """
            ).map(Self.operation(from:))
        }
    }

    private static func validate(_ request: ArchiveDeletionRequest) throws {
        guard Set([request.id, request.rewriteJobID, request.auditEventID]).count == 3,
            request.requestedAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw ArchiveDeletionRequestStoreError.invalidRequest
        }
        if case .range(let interval) = request.target {
            guard interval.start < interval.end,
                interval.start.timeIntervalSinceReferenceDate.isFinite,
                interval.end.timeIntervalSinceReferenceDate.isFinite
            else {
                throw ArchiveDeletionRequestStoreError.invalidRequest
            }
        }
    }

    private static func matches(
        _ request: ArchiveDeletionRequest,
        operation: ArchiveDeletionOperation
    ) -> Bool {
        guard operation.tombstone.id == request.id,
            operation.tombstone.requestedAt == request.requestedAt,
            operation.rewriteJobID == request.rewriteJobID
        else {
            return false
        }
        switch request.target {
        case .moment(let frameID):
            return operation.tombstone.reason == .userMoment
                && operation.tombstone.requestedInterval == nil
                && operation.tombstone.requestedFrameIDs == [frameID]
        case .range(let interval):
            return operation.tombstone.reason == .userRange
                && operation.tombstone.requestedInterval == interval
        }
    }

    private static func targetFrames(
        _ target: ArchiveDeletionTarget,
        database: Database
    ) throws -> [TargetFrame] {
        let predicate: String
        let arguments: StatementArguments
        switch target {
        case .moment(let frameID):
            predicate = "frames.id = ?"
            arguments = [frameID.encoded]
        case .range(let interval):
            predicate = "frames.captured_at >= ? AND frames.captured_at < ?"
            arguments = [encode(interval.start), encode(interval.end)]
        }
        return try Row.fetchAll(
            database,
            sql: """
                SELECT frames.id, frames.chunk_id
                FROM frames
                JOIN media_chunks ON media_chunks.id = frames.chunk_id
                WHERE \(predicate)
                  AND media_chunks.state = 'ready'
                  AND frames.visual_state <> 'suppressed'
                  AND (frames.text_state = 'ready' OR frames.visual_state = 'ready')
                ORDER BY frames.captured_at, frames.id
                """,
            arguments: arguments
        ).map { row in
            guard let frameID = UUID(uuidString: row["id"] as String) else {
                throw ArchiveDeletionRequestStoreError.malformedRecord
            }
            return TargetFrame(frameID: frameID, chunkID: row["chunk_id"])
        }
    }

    private static func affectedArtifactCount(
        frameIDs: [UUID],
        database: Database
    ) throws -> Int {
        let placeholders = placeholders(frameIDs.count)
        let arguments = StatementArguments(frameIDs.map(\.encoded))
        let tables = ["text_spans", "artifacts", "vector_offsets", "merged_text_records"]
        var count = frameIDs.count
        for table in tables {
            count +=
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM \(table) WHERE frame_id IN (\(placeholders))",
                    arguments: arguments
                ) ?? 0
        }
        return count
    }

    private static func operationRow(id: UUID, database: Database) throws -> Row? {
        try Row.fetchOne(
            database,
            sql: """
                SELECT deletion_tombstones.encoded_tombstone,
                       deletion_tombstones.state AS tombstone_state,
                       processing_jobs.id AS job_id,
                       processing_jobs.state AS job_state,
                       processing_jobs.error_code
                FROM deletion_tombstones
                JOIN processing_jobs
                  ON processing_jobs.parent_id = deletion_tombstones.id
                 AND processing_jobs.kind IN ('mediaRewrite', 'media-rewrite')
                WHERE deletion_tombstones.id = ?
                """,
            arguments: [id.encoded]
        )
    }

    private static func operation(from row: Row) throws -> ArchiveDeletionOperation {
        guard let data = (row["encoded_tombstone"] as String).data(using: .utf8),
            let jobID = UUID(uuidString: row["job_id"] as String),
            let jobState = ProcessingJobState(rawValue: row["job_state"] as String)
        else {
            throw ArchiveDeletionRequestStoreError.malformedRecord
        }
        let tombstone: DeletionTombstone
        do {
            tombstone = try ContractJSON.decode(DeletionTombstone.self, from: data)
        } catch {
            throw ArchiveDeletionRequestStoreError.malformedRecord
        }
        guard tombstone.state.rawValue == (row["tombstone_state"] as String) else {
            throw ArchiveDeletionRequestStoreError.malformedRecord
        }
        let state: ArchiveDeletionOperationState
        if tombstone.state == .failed {
            state = .failed
        } else if tombstone.state == .committed || tombstone.state == .verified {
            state = .complete
        } else {
            switch jobState {
            case .queued, .retryableFailure:
                state = .queued
            case .leased:
                state = .rewriting
            case .succeeded:
                state = .verifying
            case .permanentFailure, .cancelled:
                state = .failed
            }
        }
        return ArchiveDeletionOperation(
            tombstone: tombstone,
            rewriteJobID: jobID,
            state: state,
            completedRewriteCount: jobState == .succeeded ? 1 : 0,
            totalRewriteCount: 1,
            failureCode: row["error_code"]
        )
    }

    private static func identifierExists(_ id: UUID, database: Database) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM processing_jobs WHERE id = ?)",
            arguments: [id.encoded]
        ) ?? false
    }

    private static func auditIdentifierExists(_ id: UUID, database: Database) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: "SELECT EXISTS(SELECT 1 FROM audit_events WHERE id = ?)",
            arguments: [id.encoded]
        ) ?? false
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private static func encode(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
    }
}

private struct TargetFrame {
    let frameID: UUID
    let chunkID: String
}

extension ArchiveDeletionTarget {
    fileprivate var requestedInterval: DateInterval? {
        if case .range(let interval) = self { return interval }
        return nil
    }

    fileprivate var reason: DeletionReason {
        switch self {
        case .moment: .userMoment
        case .range: .userRange
        }
    }
}

extension UUID {
    fileprivate var encoded: String { uuidString.lowercased() }
}
