import Foundation
import MemoryContracts
import XCTest

@testable import SharedQueryKit

final class SharedQueryServiceTests: XCTestCase {
    func testAppAndHelperUseByteEquivalentOrderedSearchTimelineAndDetailProjections()
        async throws
    {
        let fixture = try makeFixture()
        let appService = makeService(fixture: fixture)
        let helperService = makeService(fixture: fixture)

        let requests: [SharedReadRequest] = [
            .search(fixture.searchRequest),
            .timeline(
                try TimelineQueryRequest(
                    interval: fixture.timeline.interval,
                    bundleIDs: ["com.apple.Safari"],
                    hosts: ["example.com"],
                    maximumFrames: 25,
                    accessPolicy: fixture.searchRequest.accessPolicy
                )
            ),
            .moment(
                try MomentQueryRequest(
                    frameID: fixture.detail.frameID,
                    accessPolicy: fixture.searchRequest.accessPolicy
                )
            ),
        ]

        for request in requests {
            let appBytes = try await appService.canonicalBytes(for: request)
            let helperBytes = try await helperService.canonicalBytes(for: request)
            XCTAssertEqual(appBytes, helperBytes)

            let projection = try ContractJSON.decode(
                SharedReadProjection.self,
                from: appBytes
            )
            try projection.validate()
        }

        let projected = try await appService.execute(.search(fixture.searchRequest))
        guard case .search(let page) = projected else {
            return XCTFail("expected search projection")
        }
        XCTAssertEqual(page.results.map(\.frameID), fixture.searchPage.results.map(\.frameID))
        XCTAssertGreaterThan(page.results[0].fusedScore, page.results[1].fusedScore)
    }

    func testServiceValidatesRequestsAndRejectsMismatchedMomentIdentity() async throws {
        let fixture = try makeFixture()
        let service = makeService(fixture: fixture)
        let otherID = try XCTUnwrap(UUID(uuidString: "31000000-0000-0000-0000-000000000099"))
        let request = try MomentQueryRequest(
            frameID: otherID,
            accessPolicy: fixture.searchRequest.accessPolicy
        )

        do {
            _ = try await service.execute(.moment(request))
            XCTFail("mismatched detail identity must fail closed")
        } catch let error as SharedQueryError {
            XCTAssertEqual(error, .projectionMismatch)
        }
    }
}

private struct SharedFixture: Sendable {
    let searchRequest: SearchRequest
    let searchPage: SearchPage
    let timeline: TimelineSlice
    let detail: SearchResult
}

private func makeFixture() throws -> SharedFixture {
    let request = try ContractJSON.decode(
        SearchRequest.self,
        from: fixtureData("Fixtures/Contracts/v1/search-request.json")
    )
    let sourcePage = try ContractJSON.decode(
        SearchPage.self,
        from: fixtureData("Fixtures/Contracts/v2/search-page.json")
    )
    let first = try XCTUnwrap(sourcePage.results.first)
    let second = try SearchResult(
        frameID: XCTUnwrap(UUID(uuidString: "31000000-0000-0000-0000-000000000002")),
        capturedAt: first.capturedAt.addingTimeInterval(1),
        foreground: first.foreground,
        browser: first.browser,
        thumbnailLocator: first.thumbnailLocator,
        mediaLocator: first.mediaLocator,
        evidence: first.evidence,
        textRank: 2,
        visualRank: 3,
        fusedScore: first.fusedScore / 2
    )
    let page = try SearchPage(
        results: [second, first],
        nextCursor: sourcePage.nextCursor
    )
    let timeline = try ContractJSON.decode(
        TimelineSlice.self,
        from: fixtureData("Fixtures/Contracts/v1/timeline-slice.json")
    )
    return SharedFixture(
        searchRequest: request,
        searchPage: page,
        timeline: timeline,
        detail: first
    )
}

private func makeService(fixture: SharedFixture) -> SharedQueryService {
    SharedQueryService(
        search: { _ in fixture.searchPage },
        timeline: { _ in fixture.timeline },
        moment: { _ in fixture.detail }
    )
}

private func fixtureData(_ path: String, file: StaticString = #filePath) throws -> Data {
    let fileURL = URL(fileURLWithPath: "\(file)")
    let root =
        fileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(contentsOf: root.appending(path: path))
}
