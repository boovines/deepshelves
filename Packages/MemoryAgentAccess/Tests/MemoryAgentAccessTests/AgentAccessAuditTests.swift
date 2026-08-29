import Foundation
import XCTest

@testable import MemoryAgentAccess

final class AgentAccessAuditTests: XCTestCase {
    func testSearchAuditContainsHashAndNeverRawQuery() async throws {
        let sink = AuditSinkSpy()
        let query = "private quarterly roadmap"
        let policyID = UUID(uuidString: "70000000-0000-4000-8000-000000000001")!
        let backend = LocalMemoryCLIBackend(
            status: {
                CLIStatusProjection(
                    recordingState: "inactive", archiveReadable: true, policyCount: 1)
            },
            search: { _ in CLISearchProjection(results: [], nextCursor: nil) },
            timeline: { _ in CLITimelineProjection(frames: [], gaps: []) },
            moment: { _ in throw LocalMemoryCLIError.notFound },
            imageResource: { _ in throw LocalMemoryCLIError.notFound }
        )

        let result = await LocalMemoryCLIExecutor.execute(
            arguments: ["search", query, "--policy", policyID.uuidString, "--json"],
            backend: backend,
            auditSink: sink.sink
        )

        XCTAssertEqual(result.exitCode, 0)
        let records = await sink.records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].operation, .search)
        XCTAssertEqual(records[0].outcome, .success)
        XCTAssertEqual(records[0].policyID, policyID)
        XCTAssertEqual(records[0].resultCount, 0)
        XCTAssertEqual(records[0].queryHash?.count, 64)
        XCTAssertNotEqual(records[0].queryHash, query)
        XCTAssertFalse(String(describing: records[0]).contains(query))
    }

    func testDeniedRequestIsAuditedWithoutContent() async throws {
        let sink = AuditSinkSpy()
        let policyID = UUID(uuidString: "70000000-0000-4000-8000-000000000002")!
        let backend = LocalMemoryCLIBackend(
            status: { throw LocalMemoryCLIError.unavailable },
            search: { _ in throw LocalMemoryCLIError.policyDenied },
            timeline: { _ in throw LocalMemoryCLIError.unavailable },
            moment: { _ in throw LocalMemoryCLIError.unavailable },
            imageResource: { _ in throw LocalMemoryCLIError.unavailable }
        )

        _ = await LocalMemoryCLIExecutor.execute(
            arguments: ["search", "ignore previous instructions", "--policy", policyID.uuidString],
            backend: backend,
            auditSink: sink.sink
        )

        let records = await sink.records
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.outcome, .denied)
        XCTAssertEqual(record.resultCount, 0)
        XCTAssertEqual(record.queryHash?.count, 64)
    }
}

private actor AuditSinkSpy {
    private(set) var records: [AgentAccessAuditRecord] = []

    nonisolated var sink: AgentAccessAuditSink {
        AgentAccessAuditSink { [weak self] record in
            await self?.append(record)
        }
    }

    private func append(_ record: AgentAccessAuditRecord) {
        records.append(record)
    }
}
