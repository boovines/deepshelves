import Foundation

public enum ProcessingJobKind: String, Codable, Equatable, Sendable {
    case accessibilityText
    case visionOCR
    case thumbnail
    case visualVector
    case transcription
    case mediaRewrite
    case vectorCompaction
}

public enum ProcessingJobState: String, Codable, Equatable, Sendable {
    case queued
    case leased
    case succeeded
    case retryableFailure
    case permanentFailure
    case cancelled
}

public struct ProcessingJob: Codable, Equatable, Sendable, ContractValidatable {
    public static let maximumAutomaticAttempts = 3

    public let id: UUID
    public let parentID: UUID
    public let kind: ProcessingJobKind
    public let priority: Int
    public let state: ProcessingJobState
    public let attemptCount: Int
    public let nextAttemptAt: Date?
    public let producer: ProducerVersion
    public let lastErrorCode: String?
    public let leaseExpiresAt: Date?

    public init(
        id: UUID,
        parentID: UUID,
        kind: ProcessingJobKind,
        priority: Int,
        state: ProcessingJobState,
        attemptCount: Int,
        nextAttemptAt: Date?,
        producer: ProducerVersion,
        lastErrorCode: String?,
        leaseExpiresAt: Date?
    ) throws {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.priority = priority
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.producer = producer
        self.lastErrorCode = lastErrorCode
        self.leaseExpiresAt = leaseExpiresAt
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            (0...1_000).contains(priority),
            field: "processingJob.priority",
            violation: .outOfRange,
            detail: "priority must be between zero and 1000"
        )
        try ContractChecks.require(
            (0...Self.maximumAutomaticAttempts).contains(attemptCount),
            field: "processingJob.attemptCount",
            violation: .outOfRange,
            detail: "automatic work may be attempted at most three times"
        )
        try producer.validate()
        if let lastErrorCode {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-.:")
            try ContractChecks.require(
                !lastErrorCode.isEmpty && lastErrorCode.count <= 128
                    && lastErrorCode.unicodeScalars.allSatisfy(allowed.contains),
                field: "processingJob.lastErrorCode",
                violation: .outOfRange,
                detail: "error code must be bounded and content-free"
            )
        }
        if state == .leased {
            try ContractChecks.require(
                leaseExpiresAt != nil,
                field: "processingJob.leaseExpiresAt",
                violation: .missingRequiredValue,
                detail: "leased work requires durable lease expiry"
            )
        } else {
            try ContractChecks.require(
                leaseExpiresAt == nil,
                field: "processingJob.leaseExpiresAt",
                violation: .inconsistent,
                detail: "only leased work may retain a lease"
            )
        }
        if state == .retryableFailure {
            try ContractChecks.require(
                nextAttemptAt != nil && lastErrorCode != nil
                    && attemptCount < Self.maximumAutomaticAttempts,
                field: "processingJob.retry",
                violation: .inconsistent,
                detail: "retryable failure requires error, schedule, and remaining attempt"
            )
        }
        if state == .permanentFailure {
            try ContractChecks.require(
                lastErrorCode != nil,
                field: "processingJob.lastErrorCode",
                violation: .missingRequiredValue,
                detail: "permanent failure requires a content-free error code"
            )
        }
    }
}
