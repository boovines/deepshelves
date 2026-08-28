import Foundation
import GRDB
import MemoryContracts

extension ArchiveDatabase: RecordingGapPersisting {
    public func persist(recordingGap: RecordingGap) async throws {
        try recordingGap.validate()
        let dateStyle = Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        )
        try atomicWrite { database in
            try database.execute(
                sql: """
                    INSERT INTO activity_intervals(
                        id, started_at, ended_at, bundle_id, app_name, state, gap_reason
                    ) VALUES (?, ?, ?, ?, NULL, 'gap', ?)
                    """,
                arguments: [
                    UUID().uuidString.lowercased(),
                    recordingGap.startedAt.formatted(dateStyle),
                    recordingGap.endedAt.formatted(dateStyle),
                    recordingGap.approvedBundleID,
                    recordingGap.reason.rawValue,
                ]
            )
        }
    }

    public func recordedLifecycleGaps() throws -> [RecordingGap] {
        try atomicRead { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT started_at, ended_at, bundle_id, gap_reason
                    FROM activity_intervals
                    WHERE state = 'gap'
                    ORDER BY started_at, id
                    """
            )
            let dateStyle = Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
            return try rows.map { row in
                let encodedReason: String? = row["gap_reason"]
                let endedAtValue: String? = row["ended_at"]
                guard
                    let encodedReason,
                    let reason = RecordingGapReason(rawValue: encodedReason),
                    let endedAtValue
                else {
                    throw ArchiveDatabaseError.invalidActivityGap
                }
                return try RecordingGap(
                    startedAt: try dateStyle.parse(row["started_at"]),
                    endedAt: try dateStyle.parse(endedAtValue),
                    reason: reason,
                    approvedBundleID: row["bundle_id"]
                )
            }
        }
    }
}
