import Foundation
import GRDB

public enum ArchiveMomentSourceError: Error, Equatable, Sendable {
    case sourceUnavailable
    case locatorMismatch
    case malformedRecord
}

public struct ArchiveMomentSourceRecord: Equatable, Sendable {
    public let frameID: UUID
    public let captureEpochID: UUID
    public let targetWindowID: UInt32
    public let policyGeneration: UInt64
    public let mediaPath: ArchiveRelativePath
    public let mediaHash: Data
    public let mediaByteCount: Int
    public let manifestPath: ArchiveRelativePath
    public let manifestHash: Data

    public init(
        frameID: UUID,
        captureEpochID: UUID,
        targetWindowID: UInt32,
        policyGeneration: UInt64,
        mediaPath: ArchiveRelativePath,
        mediaHash: Data,
        mediaByteCount: Int,
        manifestPath: ArchiveRelativePath,
        manifestHash: Data
    ) {
        self.frameID = frameID
        self.captureEpochID = captureEpochID
        self.targetWindowID = targetWindowID
        self.policyGeneration = policyGeneration
        self.mediaPath = mediaPath
        self.mediaHash = mediaHash
        self.mediaByteCount = mediaByteCount
        self.manifestPath = manifestPath
        self.manifestHash = manifestHash
    }
}

public final class ArchiveMomentSourceStore: @unchecked Sendable {
    private let database: ArchiveDatabase

    public init(database: ArchiveDatabase) {
        self.database = database
    }

    public func readySource(
        frameID: UUID,
        expectedPath: ArchiveRelativePath
    ) throws -> ArchiveMomentSourceRecord {
        let row = try database.atomicRead { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT frames.id, frames.capture_epoch_id, frames.target_window_id,
                           frames.policy_generation, frames.media_path,
                           frames.media_sha256, frames.media_byte_count,
                           media_chunks.relative_path AS manifest_path,
                           media_chunks.sha256 AS manifest_sha256
                    FROM frames
                    JOIN media_chunks ON media_chunks.id = frames.chunk_id
                    WHERE frames.id = ?
                      AND frames.schema_version >= 2
                      AND frames.media_path IS NOT NULL
                      AND frames.media_sha256 IS NOT NULL
                      AND frames.media_byte_count > 0
                      AND frames.policy_generation > 0
                      AND media_chunks.state = 'ready'
                      AND media_chunks.sha256 IS NOT NULL
                      AND frames.visual_state <> 'suppressed'
                      AND (frames.text_state = 'ready' OR frames.visual_state = 'ready')
                    """,
                arguments: [frameID.uuidString.lowercased()]
            )
        }
        guard let row else { throw ArchiveMomentSourceError.sourceUnavailable }
        let record = try Self.record(row)
        guard record.mediaPath == expectedPath else {
            throw ArchiveMomentSourceError.locatorMismatch
        }
        return record
    }

    private static func record(_ row: Row) throws -> ArchiveMomentSourceRecord {
        guard let frameID = UUID(uuidString: row["id"] as String),
            let captureEpochID = UUID(uuidString: row["capture_epoch_id"] as String),
            let targetWindow = row["target_window_id"] as Int64?,
            targetWindow >= 0,
            targetWindow <= Int64(UInt32.max),
            let policyGeneration = row["policy_generation"] as Int64?,
            policyGeneration > 0,
            let byteCount = row["media_byte_count"] as Int?,
            byteCount > 0,
            let mediaHash = decodeHash(row["media_sha256"] as String),
            let manifestHash = decodeHash(row["manifest_sha256"] as String)
        else {
            throw ArchiveMomentSourceError.malformedRecord
        }
        do {
            return ArchiveMomentSourceRecord(
                frameID: frameID,
                captureEpochID: captureEpochID,
                targetWindowID: UInt32(targetWindow),
                policyGeneration: UInt64(policyGeneration),
                mediaPath: try ArchiveRelativePath(row["media_path"] as String),
                mediaHash: mediaHash,
                mediaByteCount: byteCount,
                manifestPath: try ArchiveRelativePath(row["manifest_path"] as String),
                manifestHash: manifestHash
            )
        } catch {
            throw ArchiveMomentSourceError.malformedRecord
        }
    }

    private static func decodeHash(_ value: String) -> Data? {
        guard value.count == 64 else { return nil }
        var data = Data()
        data.reserveCapacity(32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
