import Foundation

public enum DeletionReason: String, Codable, Equatable, Sendable {
    case userMoment
    case userRange
    case forgetRecent
    case retention
    case storageCap
    case fullReset
}

public enum DeletionTombstoneState: String, Codable, Equatable, Sendable {
    case planned
    case rewriting
    case committed
    case verified
    case failed
}

public struct DeletionTombstone: Equatable, Sendable, ContractValidatable {
    public let id: UUID
    public let requestedInterval: DateInterval?
    public let requestedFrameIDs: Set<UUID>
    public let reason: DeletionReason
    public let requestedAt: Date
    public let completedAt: Date?
    public let affectedChunkCount: Int
    public let affectedArtifactCount: Int
    public let replacementChunkIDs: Set<UUID>
    public let verificationHash: Data?
    public let state: DeletionTombstoneState

    public init(
        id: UUID,
        requestedInterval: DateInterval?,
        requestedFrameIDs: Set<UUID>,
        reason: DeletionReason,
        requestedAt: Date,
        completedAt: Date?,
        affectedChunkCount: Int,
        affectedArtifactCount: Int,
        replacementChunkIDs: Set<UUID>,
        verificationHash: Data?,
        state: DeletionTombstoneState
    ) throws {
        self.id = id
        self.requestedInterval = requestedInterval
        self.requestedFrameIDs = requestedFrameIDs
        self.reason = reason
        self.requestedAt = requestedAt
        self.completedAt = completedAt
        self.affectedChunkCount = affectedChunkCount
        self.affectedArtifactCount = affectedArtifactCount
        self.replacementChunkIDs = replacementChunkIDs
        self.verificationHash = verificationHash
        self.state = state
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            requestedInterval != nil || !requestedFrameIDs.isEmpty,
            field: "deletionTombstone.request",
            violation: .missingRequiredValue,
            detail: "deletion requires an interval or frame identities"
        )
        if let requestedInterval {
            try ContractChecks.validateInterval(
                requestedInterval, field: "deletionTombstone.requestedInterval")
        }
        try ContractChecks.require(
            affectedChunkCount >= 0 && affectedArtifactCount >= 0,
            field: "deletionTombstone.counts",
            violation: .outOfRange,
            detail: "affected counts cannot be negative"
        )
        if let completedAt {
            try ContractChecks.require(
                completedAt >= requestedAt,
                field: "deletionTombstone.completedAt",
                violation: .invalidInterval,
                detail: "completion cannot precede the request"
            )
        }
        if state == .committed || state == .verified {
            try ContractChecks.require(
                completedAt != nil,
                field: "deletionTombstone.completedAt",
                violation: .missingRequiredValue,
                detail: "committed deletion requires completion time"
            )
        }
        if state == .verified {
            try ContractChecks.require(
                verificationHash?.count == 32,
                field: "deletionTombstone.verificationHash",
                violation: .missingRequiredValue,
                detail: "verified deletion requires a SHA-256 proof"
            )
        } else if let verificationHash {
            try ContractChecks.require(
                verificationHash.count == 32,
                field: "deletionTombstone.verificationHash",
                violation: .outOfRange,
                detail: "verification hash must contain 32 bytes"
            )
        }
    }
}

extension DeletionTombstone: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case requestedInterval
        case requestedFrameIDs
        case reason
        case requestedAt
        case completedAt
        case affectedChunkCount
        case affectedArtifactCount
        case replacementChunkIDs
        case verificationHash
        case state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        requestedInterval = try container.decodeIfPresent(
            DateInterval.self, forKey: .requestedInterval)
        let frameIDs = try container.decode([UUID].self, forKey: .requestedFrameIDs)
        let replacementIDs = try container.decode([UUID].self, forKey: .replacementChunkIDs)
        guard Set(frameIDs).count == frameIDs.count,
            Set(replacementIDs).count == replacementIDs.count
        else {
            throw ContractValidationError(
                field: "deletionTombstone.identifiers",
                violation: .duplicateValue,
                detail: "serialized identifier sets cannot contain duplicates"
            )
        }
        requestedFrameIDs = Set(frameIDs)
        reason = try container.decode(DeletionReason.self, forKey: .reason)
        requestedAt = try container.decode(Date.self, forKey: .requestedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        affectedChunkCount = try container.decode(Int.self, forKey: .affectedChunkCount)
        affectedArtifactCount = try container.decode(Int.self, forKey: .affectedArtifactCount)
        replacementChunkIDs = Set(replacementIDs)
        verificationHash = try container.decodeIfPresent(Data.self, forKey: .verificationHash)
        state = try container.decode(DeletionTombstoneState.self, forKey: .state)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(requestedInterval, forKey: .requestedInterval)
        try container.encode(
            requestedFrameIDs.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() },
            forKey: .requestedFrameIDs
        )
        try container.encode(reason, forKey: .reason)
        try container.encode(requestedAt, forKey: .requestedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(affectedChunkCount, forKey: .affectedChunkCount)
        try container.encode(affectedArtifactCount, forKey: .affectedArtifactCount)
        try container.encode(
            replacementChunkIDs.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() },
            forKey: .replacementChunkIDs
        )
        try container.encodeIfPresent(verificationHash, forKey: .verificationHash)
        try container.encode(state, forKey: .state)
    }
}
