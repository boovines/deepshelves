import Foundation
import GRDB
import MemoryContracts

public enum ArchiveEnrichmentJobStoreError: Error, Equatable, Sendable {
    case invalidSeed
    case conflictingSeed
    case invalidLeaseRequest
    case invalidProducerVersions
    case invalidErrorCode
    case staleLease
    case malformedRecord
}

public struct EnrichmentJobSeed: Equatable, Sendable {
    public let id: UUID
    public let parentID: UUID
    public let kind: ProcessingJobKind
    public let priority: Int
    public let producerVersion: String

    public init(
        id: UUID,
        parentID: UUID,
        kind: ProcessingJobKind,
        priority: Int,
        producerVersion: String
    ) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.priority = priority
        self.producerVersion = producerVersion
    }
}

public struct EnrichmentJobLease: Equatable, Sendable {
    public let jobID: UUID
    public let parentID: UUID
    public let kind: ProcessingJobKind
    public let priority: Int
    public let attemptCount: Int
    public let producerVersion: String
    public let expiresAt: Date
}

public struct EnrichmentJobRecord: Equatable, Sendable {
    public let jobID: UUID
    public let parentID: UUID
    public let kind: ProcessingJobKind
    public let priority: Int
    public let state: ProcessingJobState
    public let attemptCount: Int
    public let nextAttemptAt: Date?
    public let producerVersion: String
    public let lastErrorCode: String?
    public let leaseExpiresAt: Date?
}

public struct EnrichmentBacklogCounts: Equatable, Sendable {
    public var queued: Int = 0
    public var leased: Int = 0
    public var retryScheduled: Int = 0
    public var permanentFailures: Int = 0
    public var succeeded: Int = 0

    public init() {}
}

public struct EnrichmentBacklogSnapshot: Equatable, Sendable {
    public let measuredAt: Date
    public let totalPending: Int
    public let ready: Int
    public let leased: Int
    public let retryScheduled: Int
    public let permanentFailures: Int
    public let succeeded: Int
    public let cancelled: Int
    public let byKind: [ProcessingJobKind: EnrichmentBacklogCounts]
}

public final class ArchiveEnrichmentJobStore: @unchecked Sendable {
    private let database: ArchiveDatabase

    public init(database: ArchiveDatabase) throws {
        self.database = database
        guard try database.logicalTableNames().contains("processing_jobs") else {
            throw ArchiveEnrichmentJobStoreError.malformedRecord
        }
    }

    public func enqueue(_ seed: EnrichmentJobSeed) throws {
        guard Self.validPriority(seed.priority), Self.validProducerVersion(seed.producerVersion)
        else {
            throw ArchiveEnrichmentJobStoreError.invalidSeed
        }
        try database.atomicWrite { database in
            try database.execute(
                sql: """
                    INSERT INTO processing_jobs(
                        id, parent_id, kind, priority, state, attempts,
                        next_attempt_at, producer_version, error_code, lease_expires_at
                    ) VALUES (?, ?, ?, ?, 'queued', 0, NULL, ?, NULL, NULL)
                    ON CONFLICT(id) DO NOTHING
                    """,
                arguments: [
                    Self.encode(seed.id),
                    Self.encode(seed.parentID),
                    seed.kind.rawValue,
                    seed.priority,
                    seed.producerVersion,
                ]
            )
            if database.changesCount == 0 {
                guard let existing = try Self.fetchJob(seed.id, from: database),
                    existing.parentID == seed.parentID,
                    existing.kind == seed.kind,
                    existing.priority == seed.priority,
                    existing.producerVersion == seed.producerVersion
                else {
                    throw ArchiveEnrichmentJobStoreError.conflictingSeed
                }
            }
        }
    }

    @discardableResult
    public func synchronizeProducerVersions(
        _ producerVersions: [ProcessingJobKind: String]
    ) throws -> Int {
        guard Self.validProducerVersions(producerVersions) else {
            throw ArchiveEnrichmentJobStoreError.invalidProducerVersions
        }
        return try database.atomicWrite { database in
            var invalidated = 0
            for kind in producerVersions.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let version = producerVersions[kind] else { continue }
                let aliases = Self.aliases(for: kind)
                let placeholders = aliases.map { _ in "?" }.joined(separator: ", ")
                if kind == .visualVector {
                    try Self.invalidateVisualProjections(
                        aliases: aliases,
                        placeholders: placeholders,
                        replacementVersion: version,
                        database: database
                    )
                }
                var arguments: [DatabaseValueConvertible?] = [
                    kind.rawValue,
                    version,
                ]
                arguments.append(contentsOf: aliases)
                arguments.append(version)
                try database.execute(
                    sql: """
                        UPDATE processing_jobs
                        SET kind = ?, producer_version = ?, state = 'queued', attempts = 0,
                            next_attempt_at = NULL, error_code = NULL, lease_expires_at = NULL
                        WHERE kind IN (\(placeholders))
                          AND producer_version <> ?
                          AND state <> 'cancelled'
                        """,
                    arguments: StatementArguments(arguments)
                )
                invalidated += database.changesCount
                if aliases.count > 1 {
                    try database.execute(
                        sql: """
                            UPDATE processing_jobs
                            SET kind = ?
                            WHERE kind IN (\(placeholders))
                              AND producer_version = ?
                            """,
                        arguments: StatementArguments(
                            [kind.rawValue] + aliases + [version]
                        )
                    )
                }
            }
            return invalidated
        }
    }

    public func leaseNext(
        now: Date,
        leaseDuration: TimeInterval,
        minimumPriority: Int,
        producerVersions: [ProcessingJobKind: String]
    ) throws -> EnrichmentJobLease? {
        guard leaseDuration > 0, leaseDuration <= 600,
            Self.validPriority(minimumPriority),
            Self.validProducerVersions(producerVersions)
        else {
            throw ArchiveEnrichmentJobStoreError.invalidLeaseRequest
        }
        return try database.atomicWrite { database in
            try Self.recoverExpiredLeases(now: now, in: database)
            let encodedNow = Self.encode(now)
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, parent_id, kind, priority, state, attempts,
                           next_attempt_at, producer_version, error_code, lease_expires_at
                    FROM processing_jobs
                    WHERE priority >= ?
                      AND attempts < ?
                      AND (
                        state = 'queued'
                        OR (state = 'retryableFailure' AND next_attempt_at <= ?)
                      )
                    ORDER BY priority DESC, id ASC
                    """,
                arguments: [
                    minimumPriority,
                    ProcessingJob.maximumAutomaticAttempts,
                    encodedNow,
                ]
            )
            for row in rows {
                let record = try Self.record(from: row)
                guard producerVersions[record.kind] == record.producerVersion else {
                    continue
                }
                let attemptCount = record.attemptCount + 1
                let expiresAt = now.addingTimeInterval(leaseDuration)
                try database.execute(
                    sql: """
                        UPDATE processing_jobs
                        SET state = 'leased', attempts = ?, next_attempt_at = NULL,
                            error_code = NULL, lease_expires_at = ?
                        WHERE id = ?
                          AND state IN ('queued', 'retryableFailure')
                          AND attempts = ?
                        """,
                    arguments: [
                        attemptCount,
                        Self.encode(expiresAt),
                        Self.encode(record.jobID),
                        record.attemptCount,
                    ]
                )
                guard database.changesCount == 1 else { continue }
                return EnrichmentJobLease(
                    jobID: record.jobID,
                    parentID: record.parentID,
                    kind: record.kind,
                    priority: record.priority,
                    attemptCount: attemptCount,
                    producerVersion: record.producerVersion,
                    expiresAt: expiresAt
                )
            }
            return nil
        }
    }

    public func succeed(_ lease: EnrichmentJobLease) throws {
        try transition(
            lease,
            sql: """
                UPDATE processing_jobs
                SET state = 'succeeded', next_attempt_at = NULL,
                    error_code = NULL, lease_expires_at = NULL
                WHERE id = ? AND state = 'leased' AND attempts = ?
                  AND producer_version = ? AND lease_expires_at = ?
                """
        )
    }

    @discardableResult
    public func fail(
        _ lease: EnrichmentJobLease,
        errorCode: String,
        retryAt: Date
    ) throws -> ProcessingJobState {
        guard Self.validErrorCode(errorCode) else {
            throw ArchiveEnrichmentJobStoreError.invalidErrorCode
        }
        let state: ProcessingJobState =
            lease.attemptCount < ProcessingJob.maximumAutomaticAttempts
            ? .retryableFailure
            : .permanentFailure
        try database.atomicWrite { database in
            let nextAttempt: String? =
                state == .retryableFailure ? Self.encode(retryAt) : nil
            try database.execute(
                sql: """
                    UPDATE processing_jobs
                    SET state = ?, next_attempt_at = ?, error_code = ?,
                        lease_expires_at = NULL
                    WHERE id = ? AND state = 'leased' AND attempts = ?
                      AND producer_version = ? AND lease_expires_at = ?
                    """,
                arguments: [
                    state.rawValue,
                    nextAttempt,
                    errorCode,
                    Self.encode(lease.jobID),
                    lease.attemptCount,
                    lease.producerVersion,
                    Self.encode(lease.expiresAt),
                ]
            )
            guard database.changesCount == 1 else {
                throw ArchiveEnrichmentJobStoreError.staleLease
            }
        }
        return state
    }

    public func cancel(_ lease: EnrichmentJobLease) throws {
        try transition(
            lease,
            sql: """
                UPDATE processing_jobs
                SET state = 'cancelled', next_attempt_at = NULL,
                    error_code = 'cancelled', lease_expires_at = NULL
                WHERE id = ? AND state = 'leased' AND attempts = ?
                  AND producer_version = ? AND lease_expires_at = ?
                """
        )
    }

    public func job(_ id: UUID) throws -> EnrichmentJobRecord? {
        try database.atomicRead { database in
            try Self.fetchJob(id, from: database)
        }
    }

    public func backlog(now: Date) throws -> EnrichmentBacklogSnapshot {
        try database.atomicWrite { database in
            try Self.recoverExpiredLeases(now: now, in: database)
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, parent_id, kind, priority, state, attempts,
                           next_attempt_at, producer_version, error_code, lease_expires_at
                    FROM processing_jobs
                    ORDER BY kind, priority DESC, id
                    """
            )
            var ready = 0
            var leased = 0
            var retryScheduled = 0
            var permanentFailures = 0
            var succeeded = 0
            var cancelled = 0
            var byKind: [ProcessingJobKind: EnrichmentBacklogCounts] = [:]
            for row in rows {
                let record = try Self.record(from: row)
                var counts = byKind[record.kind] ?? EnrichmentBacklogCounts()
                switch record.state {
                case .queued:
                    ready += 1
                    counts.queued += 1
                case .leased:
                    leased += 1
                    counts.leased += 1
                case .retryableFailure:
                    if let next = record.nextAttemptAt, next <= now {
                        ready += 1
                        counts.queued += 1
                    } else {
                        retryScheduled += 1
                        counts.retryScheduled += 1
                    }
                case .permanentFailure:
                    permanentFailures += 1
                    counts.permanentFailures += 1
                case .succeeded:
                    succeeded += 1
                    counts.succeeded += 1
                case .cancelled:
                    cancelled += 1
                }
                byKind[record.kind] = counts
            }
            return EnrichmentBacklogSnapshot(
                measuredAt: now,
                totalPending: ready + leased + retryScheduled,
                ready: ready,
                leased: leased,
                retryScheduled: retryScheduled,
                permanentFailures: permanentFailures,
                succeeded: succeeded,
                cancelled: cancelled,
                byKind: byKind
            )
        }
    }

    private func transition(_ lease: EnrichmentJobLease, sql: String) throws {
        try database.atomicWrite { database in
            try database.execute(
                sql: sql,
                arguments: [
                    Self.encode(lease.jobID),
                    lease.attemptCount,
                    lease.producerVersion,
                    Self.encode(lease.expiresAt),
                ]
            )
            guard database.changesCount == 1 else {
                throw ArchiveEnrichmentJobStoreError.staleLease
            }
        }
    }

    private static func recoverExpiredLeases(now: Date, in database: Database) throws {
        let encodedNow = encode(now)
        try database.execute(
            sql: """
                UPDATE processing_jobs
                SET state = 'permanentFailure', next_attempt_at = NULL,
                    error_code = 'lease_expired', lease_expires_at = NULL
                WHERE state = 'leased' AND lease_expires_at <= ? AND attempts >= ?
                """,
            arguments: [encodedNow, ProcessingJob.maximumAutomaticAttempts]
        )
        try database.execute(
            sql: """
                UPDATE processing_jobs
                SET state = 'retryableFailure', next_attempt_at = ?,
                    error_code = 'lease_expired', lease_expires_at = NULL
                WHERE state = 'leased' AND lease_expires_at <= ? AND attempts < ?
                """,
            arguments: [encodedNow, encodedNow, ProcessingJob.maximumAutomaticAttempts]
        )
    }

    private static func fetchJob(_ id: UUID, from database: Database) throws
        -> EnrichmentJobRecord?
    {
        guard
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, parent_id, kind, priority, state, attempts,
                           next_attempt_at, producer_version, error_code, lease_expires_at
                    FROM processing_jobs WHERE id = ?
                    """,
                arguments: [encode(id)]
            )
        else { return nil }
        return try record(from: row)
    }

    private static func record(from row: Row) throws -> EnrichmentJobRecord {
        let encodedID: String = row["id"]
        let encodedParentID: String = row["parent_id"]
        let encodedKind: String = row["kind"]
        let encodedState: String = row["state"]
        let priority: Int = row["priority"]
        let attempts: Int = row["attempts"]
        let producerVersion: String = row["producer_version"]
        let nextAttempt: String? = row["next_attempt_at"]
        let leaseExpiry: String? = row["lease_expires_at"]
        guard let id = UUID(uuidString: encodedID),
            let parentID = UUID(uuidString: encodedParentID),
            let kind = kind(encodedKind),
            let state = ProcessingJobState(rawValue: encodedState),
            validPriority(priority),
            (0...ProcessingJob.maximumAutomaticAttempts).contains(attempts),
            validProducerVersion(producerVersion)
        else {
            throw ArchiveEnrichmentJobStoreError.malformedRecord
        }
        return EnrichmentJobRecord(
            jobID: id,
            parentID: parentID,
            kind: kind,
            priority: priority,
            state: state,
            attemptCount: attempts,
            nextAttemptAt: try decodeOptional(nextAttempt),
            producerVersion: producerVersion,
            lastErrorCode: row["error_code"],
            leaseExpiresAt: try decodeOptional(leaseExpiry)
        )
    }

    private static func kind(_ encoded: String) -> ProcessingJobKind? {
        ProcessingJobKind(rawValue: encoded)
            ?? ProcessingJobKind.allCasesByAlias[encoded]
    }

    private static func aliases(for kind: ProcessingJobKind) -> [String] {
        switch kind {
        case .accessibilityText: [kind.rawValue, "accessibility-text"]
        case .visionOCR: [kind.rawValue, "vision-ocr"]
        case .thumbnail: [kind.rawValue]
        case .visualVector: [kind.rawValue, "visual-vector"]
        case .transcription: [kind.rawValue]
        case .mediaRewrite: [kind.rawValue, "media-rewrite"]
        case .vectorCompaction: [kind.rawValue, "vector-compaction"]
        }
    }

    private static func invalidateVisualProjections(
        aliases: [String],
        placeholders: String,
        replacementVersion: String,
        database: Database
    ) throws {
        let invalidatedParentsSQL = """
            SELECT parent_id FROM processing_jobs
            WHERE kind IN (\(placeholders))
              AND producer_version <> ?
              AND state <> 'cancelled'
            """
        let arguments = StatementArguments(aliases + [replacementVersion])
        try database.execute(
            sql: """
                UPDATE artifacts
                SET state = 'stale'
                WHERE kind = 'visualVector'
                  AND state NOT IN ('deleted', 'stale')
                  AND frame_id IN (\(invalidatedParentsSQL))
                """,
            arguments: arguments
        )
        try database.execute(
            sql: """
                UPDATE vector_offsets
                SET state = 'stale'
                WHERE state <> 'stale'
                  AND frame_id IN (\(invalidatedParentsSQL))
                """,
            arguments: arguments
        )
        try database.execute(
            sql: """
                UPDATE frames
                SET visual_state = 'pending'
                WHERE visual_state <> 'suppressed'
                  AND id IN (\(invalidatedParentsSQL))
                """,
            arguments: arguments
        )
    }

    private static func validPriority(_ value: Int) -> Bool {
        (0...1_000).contains(value)
    }

    private static func validProducerVersions(
        _ versions: [ProcessingJobKind: String]
    ) -> Bool {
        !versions.isEmpty && versions.values.allSatisfy(validProducerVersion)
    }

    private static func validProducerVersion(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$",
            options: .regularExpression
        ) != nil
    }

    private static func validErrorCode(_ value: String) -> Bool {
        value.range(
            of: "^[a-z0-9][a-z0-9_.:-]{0,127}$",
            options: .regularExpression
        ) != nil
    }

    private static func encode(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private static func encode(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
    }

    private static func decodeOptional(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        do {
            return try Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            ).parse(value)
        } catch {
            throw ArchiveEnrichmentJobStoreError.malformedRecord
        }
    }
}

extension ProcessingJobKind {
    fileprivate static let allCasesByAlias: [String: ProcessingJobKind] = [
        "accessibility-text": .accessibilityText,
        "vision-ocr": .visionOCR,
        "visual-vector": .visualVector,
        "media-rewrite": .mediaRewrite,
        "vector-compaction": .vectorCompaction,
    ]
}
