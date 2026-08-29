import Foundation
import MemoryContracts
import XCTest

@testable import MemoryAgentAccess

final class AgentAccessSettingsTests: XCTestCase {
    func testReviewExplainsEveryBoundBeforeApproval() throws {
        let now = Date(timeIntervalSince1970: 1_777_700_000)
        let proposal = AgentAccessPolicyProposal(
            name: "Research helper",
            historyWindow: .lastSevenDays,
            allowedBundleIDs: ["com.apple.Safari"],
            allowedHosts: ["example.com"],
            allowImageResources: false,
            maxResults: 20,
            sessionDuration: .eightHours
        )

        let review = try proposal.review(now: now)

        XCTAssertTrue(review.explanation.contains("7 days"))
        XCTAssertTrue(review.explanation.contains("com.apple.Safari"))
        XCTAssertTrue(review.explanation.contains("example.com"))
        XCTAssertTrue(review.explanation.contains("Text and metadata only"))
        XCTAssertTrue(review.explanation.contains("20 results"))
        XCTAssertTrue(review.explanation.contains("8 hours"))
        XCTAssertEqual(review.draft.allowedInterval.duration, 7 * 24 * 60 * 60)
        XCTAssertEqual(review.draft.expiresAt, now.addingTimeInterval(8 * 60 * 60))
    }

    func testApprovalRequiresTheExactReviewedScopeAndNeverOffersForever() throws {
        let now = Date(timeIntervalSince1970: 1_777_700_000)
        let review = try AgentAccessPolicyProposal(
            name: "Browser research",
            historyWindow: .lastTwentyFourHours,
            allowedBundleIDs: ["com.apple.Safari"],
            allowedHosts: [],
            allowImageResources: true,
            maxResults: 10,
            sessionDuration: .oneHour
        ).review(now: now)

        XCTAssertEqual(
            AgentAccessSessionDuration.allCases, [.oneHour, .eightHours, .twentyFourHours])
        XCTAssertThrowsError(try review.approve(confirmationToken: "wrong")) {
            XCTAssertEqual($0 as? AgentAccessSettingsError, .reviewMismatch)
        }
        let approved = try review.approve(confirmationToken: review.confirmationToken)
        XCTAssertTrue(approved.createdByUser)
        XCTAssertLessThanOrEqual(approved.expiresAt.timeIntervalSince(now), 24 * 60 * 60)
    }

    func testEmptyAllowlistsExplainThatNoContentWillBeVisible() throws {
        let review = try AgentAccessPolicyProposal(
            name: "Empty",
            historyWindow: .lastTwentyFourHours,
            allowedBundleIDs: [],
            allowedHosts: [],
            allowImageResources: false,
            maxResults: 5,
            sessionDuration: .oneHour
        ).review(now: Date(timeIntervalSince1970: 1_777_700_000))

        XCTAssertTrue(review.explanation.contains("No applications or sites"))
        XCTAssertFalse(review.explanation.localizedCaseInsensitiveContains("unrestricted"))
    }

    func testHelperDiagnosticsEmitsLocalStdioConfiguration() throws {
        let executable = URL(
            fileURLWithPath: "/Applications/Local Memory.app/Contents/MacOS/Local Memory")
        let diagnostics = AgentHelperDiagnostics.inspect(
            applicationExecutableURL: executable,
            isExecutable: { $0 == executable }
        )

        XCTAssertEqual(diagnostics.state, .ready)
        XCTAssertTrue(diagnostics.mcpConfiguration.contains(executable.path))
        XCTAssertTrue(diagnostics.mcpConfiguration.contains("--mcp"))
        XCTAssertFalse(diagnostics.mcpConfiguration.contains("http"))
        XCTAssertFalse(diagnostics.mcpConfiguration.contains("socket"))
    }
}
