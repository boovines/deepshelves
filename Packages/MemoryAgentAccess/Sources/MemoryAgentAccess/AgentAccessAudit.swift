import CryptoKit
import Foundation

public enum AgentAccessAuditOperation: String, Sendable {
    case status
    case search
    case timeline
    case moment
    case imageResource
    case imageIssue
    case imageRead
}

public enum AgentAccessAuditOutcome: String, Sendable {
    case success
    case denied
    case failure
    case cancelled
}

public struct AgentAccessAuditRecord: Equatable, Sendable {
    public let operation: AgentAccessAuditOperation
    public let outcome: AgentAccessAuditOutcome
    public let policyID: UUID?
    public let resultCount: Int
    public let queryHash: String?

    public init(
        operation: AgentAccessAuditOperation,
        outcome: AgentAccessAuditOutcome,
        policyID: UUID?,
        resultCount: Int,
        queryHash: String?
    ) {
        self.operation = operation
        self.outcome = outcome
        self.policyID = policyID
        self.resultCount = max(0, resultCount)
        self.queryHash = queryHash
    }

    public var action: String { "\(operation.rawValue).\(outcome.rawValue)" }
}

public struct AgentAccessAuditSink: Sendable {
    public let record: @Sendable (AgentAccessAuditRecord) async throws -> Void

    public init(record: @escaping @Sendable (AgentAccessAuditRecord) async throws -> Void) {
        self.record = record
    }
}

public enum AgentAccessAuditHasher {
    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
