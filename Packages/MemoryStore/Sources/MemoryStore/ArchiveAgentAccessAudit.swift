import Foundation

public enum ArchiveAgentAccessAuditActor: String, Codable, Equatable, Sendable {
    case cli = "local-memory-cli"
    case mcp = "local-memory-mcp"
}

public struct ArchiveAgentAccessAuditRecord: Equatable, Sendable {
    public let id: UUID
    public let occurredAt: Date
    public let actor: ArchiveAgentAccessAuditActor
    public let action: String
    public let policyID: UUID?
    public let resultCount: Int
    public let queryHash: String?

    public init(
        id: UUID = UUID(),
        occurredAt: Date,
        actor: ArchiveAgentAccessAuditActor,
        action: String,
        policyID: UUID?,
        resultCount: Int,
        queryHash: String?
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.actor = actor
        self.action = action
        self.policyID = policyID
        self.resultCount = resultCount
        self.queryHash = queryHash
    }

    public var contentFieldCount: Int { 0 }
}
