import Foundation
import GRDB

public enum ArchiveVisualEmbeddingStoreError: Error, Equatable, Sendable {
    case sourceUnavailable
    case ambiguousThumbnail
    case malformedRecord
    case staleSource
    case invalidFailureTransition
}

public struct ArchiveVisualEmbeddingSourceRecord: Equatable, Sendable {
    public let frameID: UUID
    public let captureEpochID: UUID
    public let targetWindowID: UInt32
    public let policyGeneration: UInt64
    public let thumbnailPath: ArchiveRelativePath
    public let thumbnailHash: Data

    public init(
        frameID: UUID,
        captureEpochID: UUID,
        targetWindowID: UInt32,
        policyGeneration: UInt64,
        thumbnailPath: ArchiveRelativePath,
        thumbnailHash: Data
    ) {
        self.frameID = frameID
        self.captureEpochID = captureEpochID
        self.targetWindowID = targetWindowID
        self.policyGeneration = policyGeneration
        self.thumbnailPath = thumbnailPath
        self.thumbnailHash = thumbnailHash
    }
}

public struct ArchiveVisualEmbeddingState: Equatable, Sendable {
    public let frameState: String
    public let artifactStates: [String]
    public let vectorState: String?
}

public final class ArchiveVisualEmbeddingStore: @unchecked Sendable {
    private let database: ArchiveDatabase

    public init(database: ArchiveDatabase) {
        self.database = database
    }

    public func readyThumbnail(frameID: UUID) throws -> ArchiveVisualEmbeddingSourceRecord {
        let records = try database.atomicRead { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT frames.id, frames.capture_epoch_id, frames.target_window_id,
                           frames.policy_generation, frames.thumbnail_path,
                           artifacts.content_hash
                    FROM frames
                    JOIN media_chunks ON media_chunks.id = frames.chunk_id
                    JOIN artifacts ON artifacts.frame_id = frames.id
                    WHERE frames.id = ?
                      AND frames.schema_version >= 2
                      AND frames.visual_state = 'pending'
                      AND frames.policy_generation > 0
                      AND frames.thumbnail_path IS NOT NULL
                      AND media_chunks.state = 'ready'
                      AND artifacts.kind = 'thumbnail'
                      AND artifacts.state = 'ready'
                      AND artifacts.locator_value = frames.thumbnail_path
                    ORDER BY artifacts.id
                    """,
                arguments: [Self.encode(frameID)]
            ).map(Self.sourceRecord)
        }
        guard !records.isEmpty else {
            throw ArchiveVisualEmbeddingStoreError.sourceUnavailable
        }
        guard records.count == 1 else {
            throw ArchiveVisualEmbeddingStoreError.ambiguousThumbnail
        }
        return records[0]
    }

    public func revalidate(_ expected: ArchiveVisualEmbeddingSourceRecord) throws {
        guard try readyThumbnail(frameID: expected.frameID) == expected else {
            throw ArchiveVisualEmbeddingStoreError.staleSource
        }
    }

    public func markPermanentlyFailed(frameID: UUID, producerVersion: String) throws {
        try database.atomicWrite { database in
            let encodedFrameID = Self.encode(frameID)
            let matchingFailure =
                try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*)
                        FROM processing_jobs
                        WHERE parent_id = ?
                          AND kind IN ('visualVector', 'visual-vector')
                          AND producer_version = ?
                          AND state = 'permanentFailure'
                        """,
                    arguments: [encodedFrameID, producerVersion]
                ) ?? 0
            guard matchingFailure == 1 else {
                throw ArchiveVisualEmbeddingStoreError.invalidFailureTransition
            }
            try database.execute(
                sql: """
                    UPDATE frames
                    SET visual_state = 'failed'
                    WHERE id = ? AND visual_state = 'pending'
                    """,
                arguments: [encodedFrameID]
            )
        }
    }

    func stateForTesting(frameID: UUID) throws -> ArchiveVisualEmbeddingState {
        try database.atomicRead { database in
            let identifier = Self.encode(frameID)
            guard
                let frameState = try String.fetchOne(
                    database,
                    sql: "SELECT visual_state FROM frames WHERE id = ?",
                    arguments: [identifier]
                )
            else {
                throw ArchiveVisualEmbeddingStoreError.sourceUnavailable
            }
            return ArchiveVisualEmbeddingState(
                frameState: frameState,
                artifactStates: try String.fetchAll(
                    database,
                    sql: """
                        SELECT state FROM artifacts
                        WHERE frame_id = ? AND kind = 'visualVector'
                        ORDER BY id
                        """,
                    arguments: [identifier]
                ),
                vectorState: try String.fetchOne(
                    database,
                    sql: "SELECT state FROM vector_offsets WHERE frame_id = ?",
                    arguments: [identifier]
                )
            )
        }
    }

    private static func sourceRecord(_ row: Row) throws -> ArchiveVisualEmbeddingSourceRecord {
        let encodedFrameID: String = row["id"]
        let encodedEpochID: String = row["capture_epoch_id"]
        let targetWindowID: Int64 = row["target_window_id"]
        let policyGeneration: Int64 = row["policy_generation"]
        let thumbnailPath: String = row["thumbnail_path"]
        let contentHash: String = row["content_hash"]
        guard let frameID = UUID(uuidString: encodedFrameID),
            let captureEpochID = UUID(uuidString: encodedEpochID),
            let targetWindowID = UInt32(exactly: targetWindowID), targetWindowID > 0,
            let policyGeneration = UInt64(exactly: policyGeneration), policyGeneration > 0,
            let path = try? ArchiveRelativePath(thumbnailPath),
            path.rawValue.hasPrefix("thumbnails/"), path.rawValue.hasSuffix(".heic"),
            let hash = Data(lowercaseHex: contentHash), hash.count == 32
        else {
            throw ArchiveVisualEmbeddingStoreError.malformedRecord
        }
        return ArchiveVisualEmbeddingSourceRecord(
            frameID: frameID,
            captureEpochID: captureEpochID,
            targetWindowID: targetWindowID,
            policyGeneration: policyGeneration,
            thumbnailPath: path,
            thumbnailHash: hash
        )
    }

    private static func encode(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}

extension Data {
    fileprivate init?(lowercaseHex: String) {
        guard lowercaseHex.count.isMultiple(of: 2),
            lowercaseHex.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil
        else { return nil }
        var result = Data(capacity: lowercaseHex.count / 2)
        var index = lowercaseHex.startIndex
        while index < lowercaseHex.endIndex {
            let next = lowercaseHex.index(index, offsetBy: 2)
            guard let byte = UInt8(lowercaseHex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}
