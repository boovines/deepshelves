import Foundation
import MemoryAgentAccess
import MemoryStore

enum SignedAgentAuditComposition {
    static func makeSink(
        database: ArchiveDatabase?,
        actor: ArchiveAgentAccessAuditActor
    ) -> AgentAccessAuditSink? {
        guard let database else { return nil }
        return AgentAccessAuditSink { record in
            try database.appendAgentAccessAudit(
                ArchiveAgentAccessAuditRecord(
                    occurredAt: Date(),
                    actor: actor,
                    action: record.action,
                    policyID: record.policyID,
                    resultCount: record.resultCount,
                    queryHash: record.queryHash
                )
            )
        }
    }
}
