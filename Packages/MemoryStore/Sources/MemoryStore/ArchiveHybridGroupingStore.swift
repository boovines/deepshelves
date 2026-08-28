import CryptoKit
import Foundation
import GRDB

public enum ArchiveHybridGroupingStoreError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidRecord
    case duplicateRecord
}

public struct ArchiveHybridGroupingRecord: Equatable, Sendable {
    public let frameID: UUID
    public let captureEpochID: UUID
    public let captureReason: String
    public let mediaSHA256: Data?
    public let approvedText: String?

    public init(
        frameID: UUID,
        captureEpochID: UUID,
        captureReason: String,
        mediaSHA256: Data?,
        approvedText: String?
    ) {
        self.frameID = frameID
        self.captureEpochID = captureEpochID
        self.captureReason = captureReason
        self.mediaSHA256 = mediaSHA256
        self.approvedText = approvedText
    }
}

public final class ArchiveHybridGroupingStore: @unchecked Sendable {
    private let archive: ArchiveDatabase

    public init(database: ArchiveDatabase) {
        archive = database
    }

    public func records(frameIDs: [UUID]) throws -> [UUID: ArchiveHybridGroupingRecord] {
        guard !frameIDs.isEmpty, frameIDs.count <= 200, Set(frameIDs).count == frameIDs.count else {
            if frameIDs.isEmpty { return [:] }
            throw ArchiveHybridGroupingStoreError.invalidRequest
        }
        return try archive.atomicRead { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT frames.id, frames.capture_epoch_id, frames.capture_reason,
                           frames.media_sha256,
                           CASE WHEN merged_text_records.state = 'ready'
                                THEN merged_text_records.approved_text ELSE NULL END AS approved_text
                    FROM frames
                    JOIN media_chunks ON media_chunks.id = frames.chunk_id
                    LEFT JOIN merged_text_records ON merged_text_records.frame_id = frames.id
                    WHERE frames.id IN (\(Self.placeholders(frameIDs.count)))
                      AND media_chunks.state = 'ready'
                      AND frames.visual_state <> 'suppressed'
                      AND (frames.text_state = 'ready' OR frames.visual_state = 'ready')
                    ORDER BY frames.id
                    """,
                arguments: StatementArguments(frameIDs.map { $0.uuidString.lowercased() })
            )
            var result: [UUID: ArchiveHybridGroupingRecord] = [:]
            for row in rows {
                let encodedFrameID: String = row["id"]
                let encodedEpochID: String = row["capture_epoch_id"]
                let captureReason: String? = row["capture_reason"]
                let encodedHash: String? = row["media_sha256"]
                guard let frameID = UUID(uuidString: encodedFrameID),
                    let captureEpochID = UUID(uuidString: encodedEpochID),
                    let captureReason
                else {
                    throw ArchiveHybridGroupingStoreError.invalidRecord
                }
                let mediaSHA256 = try encodedHash.map(Self.decodeHash)
                let approvedText: String? = row["approved_text"]
                let record = ArchiveHybridGroupingRecord(
                    frameID: frameID,
                    captureEpochID: captureEpochID,
                    captureReason: captureReason,
                    mediaSHA256: mediaSHA256,
                    approvedText: approvedText
                )
                guard result.updateValue(record, forKey: frameID) == nil else {
                    throw ArchiveHybridGroupingStoreError.duplicateRecord
                }
            }
            return result
        }
    }

    private static func decodeHash(_ value: String) throws -> Data {
        guard value.count == SHA256.Digest.byteCount * 2,
            value.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil
        else {
            throw ArchiveHybridGroupingStoreError.invalidRecord
        }
        var data = Data(capacity: 32)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw ArchiveHybridGroupingStoreError.invalidRecord
            }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}
