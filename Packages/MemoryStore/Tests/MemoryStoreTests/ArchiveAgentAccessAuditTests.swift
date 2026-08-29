import Foundation
import MemoryContracts
import XCTest

@testable import MemoryStore

final class ArchiveAgentAccessAuditTests: XCTestCase {
    func testAgentAuditPersistsOnlyTypedContentFreeFieldsAndCanBeCleared() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let policyID = UUID(uuidString: "70000000-0000-4000-8000-000000000003")!
        let queryHash = String(repeating: "a", count: 64)
        let policy = try AccessPolicy(
            id: policyID,
            name: "Audited helper",
            allowedInterval: DateInterval(
                start: Date(timeIntervalSince1970: 1_777_600_000),
                end: Date(timeIntervalSince1970: 1_777_700_000)
            ),
            allowedBundleIDs: ["com.example.allowed"],
            allowedHosts: [],
            maxResults: 10,
            expiresAt: Date(timeIntervalSince1970: 1_777_703_600),
            createdByUser: true
        )
        try archive.registerAgentAccessPolicy(policy)

        try archive.appendAgentAccessAudit(
            ArchiveAgentAccessAuditRecord(
                id: UUID(uuidString: "70000000-0000-4000-8000-000000000004")!,
                occurredAt: Date(timeIntervalSince1970: 1_777_700_000),
                actor: .cli,
                action: "search.success",
                policyID: policyID,
                resultCount: 3,
                queryHash: queryHash
            )
        )

        let rows = try archive.agentAccessAudit(limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].actor, .cli)
        XCTAssertEqual(rows[0].action, "search.success")
        XCTAssertEqual(rows[0].policyID, policyID)
        XCTAssertEqual(rows[0].queryHash, queryHash)
        XCTAssertEqual(rows[0].contentFieldCount, 0)

        try archive.clearAgentAccessAudit()
        XCTAssertTrue(try archive.agentAccessAudit(limit: 10).isEmpty)
    }

    func testAgentAuditRejectsUnhashedOrContentBearingValues() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        XCTAssertThrowsError(
            try archive.appendAgentAccessAudit(
                ArchiveAgentAccessAuditRecord(
                    occurredAt: Date(),
                    actor: .mcp,
                    action: "search.success private query",
                    policyID: nil,
                    resultCount: 0,
                    queryHash: "private query"
                )
            )
        )
    }
}
