import Foundation
import GRDB
import MemoryContracts

public enum ArchiveForegroundActivityError: Error, Equatable, Sendable {
    case invalidObservation
    case invalidInterval
    case nonPartitioningIntervals
    case invalidStoredInterval
}

public struct ApprovedForegroundActivityIdentity: Equatable, Sendable {
    public let bundleID: String
    public let applicationName: String

    public init(bundleID: String, applicationName: String) {
        self.bundleID = bundleID
        self.applicationName = applicationName
    }
}

public struct ForegroundActivityObservation: Equatable, Sendable {
    public let occurredAt: Date
    public let activity: ActivityState
    public let identity: ApprovedForegroundActivityIdentity?
    public let gapReason: RecordingGapReason?

    public init(
        occurredAt: Date,
        activity: ActivityState,
        identity: ApprovedForegroundActivityIdentity?,
        gapReason: RecordingGapReason? = nil
    ) {
        self.occurredAt = occurredAt
        self.activity = activity
        self.identity = identity
        self.gapReason = gapReason
    }
}

public struct DurableForegroundActivityInterval: Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let bundleID: String?
    public let applicationName: String?
    public let gapReason: RecordingGapReason?

    public var elapsedDuration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public var isActive: Bool { gapReason == nil }

    fileprivate init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        bundleID: String?,
        applicationName: String?,
        gapReason: RecordingGapReason?
    ) throws {
        guard startedAt < endedAt,
            startedAt.timeIntervalSince1970.isFinite,
            endedAt.timeIntervalSince1970.isFinite
        else {
            throw ArchiveForegroundActivityError.invalidInterval
        }
        if let gapReason {
            guard applicationName == nil else {
                throw ArchiveForegroundActivityError.invalidInterval
            }
            _ = try RecordingGap(
                startedAt: startedAt,
                endedAt: endedAt,
                reason: gapReason,
                approvedBundleID: bundleID
            )
        } else {
            guard let bundleID, !bundleID.isEmpty,
                let applicationName, !applicationName.isEmpty
            else {
                throw ArchiveForegroundActivityError.invalidInterval
            }
        }
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.bundleID = bundleID
        self.applicationName = applicationName
        self.gapReason = gapReason
    }

    fileprivate func clipped(to interval: DateInterval) throws -> Self? {
        let start = max(startedAt, interval.start)
        let end = min(endedAt, interval.end)
        guard start < end else { return nil }
        return try Self(
            id: id,
            startedAt: start,
            endedAt: end,
            bundleID: bundleID,
            applicationName: applicationName,
            gapReason: gapReason
        )
    }

    fileprivate func merging(_ next: Self) throws -> Self? {
        guard endedAt == next.startedAt,
            bundleID == next.bundleID,
            applicationName == next.applicationName,
            gapReason == next.gapReason
        else {
            return nil
        }
        return try Self(
            id: id,
            startedAt: startedAt,
            endedAt: next.endedAt,
            bundleID: bundleID,
            applicationName: applicationName,
            gapReason: gapReason
        )
    }
}

public enum ForegroundActivityDeriver {
    public static func derive(
        observations: [ForegroundActivityObservation],
        through end: Date
    ) throws -> [DurableForegroundActivityInterval] {
        guard let first = observations.first,
            first.occurredAt < end,
            end.timeIntervalSince1970.isFinite
        else {
            throw ArchiveForegroundActivityError.invalidObservation
        }
        for (previous, next) in zip(observations, observations.dropFirst())
        where previous.occurredAt >= next.occurredAt {
            throw ArchiveForegroundActivityError.invalidObservation
        }
        guard
            observations.allSatisfy({ observation in
                observation.occurredAt.timeIntervalSince1970.isFinite
                    && observation.occurredAt < end
                    && observation.identity.map {
                        !$0.bundleID.isEmpty && !$0.applicationName.isEmpty
                    } ?? true
            })
        else {
            throw ArchiveForegroundActivityError.invalidObservation
        }

        var result: [DurableForegroundActivityInterval] = []
        for index in observations.indices {
            let observation = observations[index]
            let intervalEnd =
                observations.indices.contains(index + 1)
                ? observations[index + 1].occurredAt : end
            let interval = try interval(for: observation, endedAt: intervalEnd)
            if let last = result.last, let merged = try last.merging(interval) {
                result[result.count - 1] = merged
            } else {
                result.append(interval)
            }
        }
        return result
    }

    private static func interval(
        for observation: ForegroundActivityObservation,
        endedAt: Date
    ) throws -> DurableForegroundActivityInterval {
        if let gapReason = observation.gapReason {
            return try DurableForegroundActivityInterval(
                startedAt: observation.occurredAt,
                endedAt: endedAt,
                bundleID: observation.identity?.bundleID,
                applicationName: nil,
                gapReason: gapReason
            )
        }
        if observation.activity == .idle {
            return try DurableForegroundActivityInterval(
                startedAt: observation.occurredAt,
                endedAt: endedAt,
                bundleID: observation.identity?.bundleID,
                applicationName: nil,
                gapReason: .idle
            )
        }
        guard let identity = observation.identity else {
            return try DurableForegroundActivityInterval(
                startedAt: observation.occurredAt,
                endedAt: endedAt,
                bundleID: nil,
                applicationName: nil,
                gapReason: .unresolvedWindow
            )
        }
        return try DurableForegroundActivityInterval(
            startedAt: observation.occurredAt,
            endedAt: endedAt,
            bundleID: identity.bundleID,
            applicationName: identity.applicationName,
            gapReason: nil
        )
    }
}

public struct ForegroundActivityTotals: Equatable, Sendable {
    public let interval: DateInterval
    public let applicationDurations: [String: TimeInterval]
    public let applicationNames: [String: String]
    public let gapDurations: [RecordingGapReason: TimeInterval]

    public var elapsedDuration: TimeInterval { interval.duration }
    public var activeDuration: TimeInterval { applicationDurations.values.reduce(0, +) }
    public var unrecordedDuration: TimeInterval { max(0, elapsedDuration - activeDuration) }
}

public final class ArchiveForegroundActivityStore: @unchecked Sendable {
    private let database: ArchiveDatabase

    public init(database: ArchiveDatabase) {
        self.database = database
    }

    public func replace(
        covering interval: DateInterval,
        with records: [DurableForegroundActivityInterval]
    ) throws {
        try Self.validatePartition(records, covering: interval)
        let style = Self.dateStyle
        try database.atomicWrite { database in
            try database.execute(
                sql: """
                    DELETE FROM activity_intervals
                    WHERE started_at < ? AND ended_at > ?
                    """,
                arguments: [interval.end.formatted(style), interval.start.formatted(style)]
            )
            for record in records {
                try database.execute(
                    sql: """
                        INSERT INTO activity_intervals(
                            id, started_at, ended_at, bundle_id, app_name, state, gap_reason
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        record.id.uuidString.lowercased(),
                        record.startedAt.formatted(style),
                        record.endedAt.formatted(style),
                        record.bundleID,
                        record.applicationName,
                        record.isActive ? "active" : "gap",
                        record.gapReason?.rawValue,
                    ]
                )
            }
        }
    }

    public func intervals(in interval: DateInterval) throws
        -> [DurableForegroundActivityInterval]
    {
        guard interval.start < interval.end else {
            throw ArchiveForegroundActivityError.invalidInterval
        }
        let stored = try database.atomicRead { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, started_at, ended_at, bundle_id, app_name, state, gap_reason
                    FROM activity_intervals
                    WHERE state IN ('active', 'gap')
                      AND started_at < ? AND ended_at > ?
                    ORDER BY started_at, id
                    """,
                arguments: [
                    interval.end.formatted(Self.dateStyle),
                    interval.start.formatted(Self.dateStyle),
                ]
            ).map(Self.project)
        }
        return try stored.compactMap { try $0.clipped(to: interval) }
    }

    public func totals(in interval: DateInterval) throws -> ForegroundActivityTotals {
        let records = try intervals(in: interval)
        var applications: [String: TimeInterval] = [:]
        var names: [String: String] = [:]
        var gaps: [RecordingGapReason: TimeInterval] = [:]
        var cursor = interval.start
        for record in records {
            guard record.startedAt >= cursor else {
                throw ArchiveForegroundActivityError.invalidStoredInterval
            }
            if record.startedAt > cursor {
                gaps[.unknown, default: 0] += record.startedAt.timeIntervalSince(cursor)
            }
            if record.isActive, let bundleID = record.bundleID,
                let applicationName = record.applicationName
            {
                applications[bundleID, default: 0] += record.elapsedDuration
                names[bundleID] = applicationName
            } else if let reason = record.gapReason {
                gaps[reason, default: 0] += record.elapsedDuration
            }
            cursor = record.endedAt
        }
        if cursor < interval.end {
            gaps[.unknown, default: 0] += interval.end.timeIntervalSince(cursor)
        }
        return ForegroundActivityTotals(
            interval: interval,
            applicationDurations: applications,
            applicationNames: names,
            gapDurations: gaps
        )
    }

    private static func validatePartition(
        _ records: [DurableForegroundActivityInterval],
        covering interval: DateInterval
    ) throws {
        guard interval.start < interval.end,
            let first = records.first,
            let last = records.last,
            first.startedAt == interval.start,
            last.endedAt == interval.end
        else {
            throw ArchiveForegroundActivityError.nonPartitioningIntervals
        }
        for (current, next) in zip(records, records.dropFirst())
        where current.endedAt != next.startedAt {
            throw ArchiveForegroundActivityError.nonPartitioningIntervals
        }
    }

    private static func project(_ row: Row) throws -> DurableForegroundActivityInterval {
        let encodedID: String = row["id"]
        let encodedStart: String = row["started_at"]
        let encodedEnd: String? = row["ended_at"]
        let state: String = row["state"]
        let encodedGap: String? = row["gap_reason"]
        guard let id = UUID(uuidString: encodedID),
            let encodedEnd,
            let start = try? dateStyle.parse(encodedStart),
            let end = try? dateStyle.parse(encodedEnd),
            state == "active" || state == "gap",
            (state == "active") == (encodedGap == nil)
        else {
            throw ArchiveForegroundActivityError.invalidStoredInterval
        }
        return try DurableForegroundActivityInterval(
            id: id,
            startedAt: start,
            endedAt: end,
            bundleID: row["bundle_id"],
            applicationName: row["app_name"],
            gapReason: try encodedGap.map { value in
                guard let reason = RecordingGapReason(rawValue: value) else {
                    throw ArchiveForegroundActivityError.invalidStoredInterval
                }
                return reason
            }
        )
    }

    private static let dateStyle = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )
}
