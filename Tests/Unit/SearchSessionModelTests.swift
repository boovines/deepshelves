import Foundation
import MemoryContracts
import MemorySearch
import XCTest

@MainActor
final class SearchSessionModelTests: XCTestCase {
    func testWarmInitialPageIsAvailableWithoutAQueryOrEngineCall() async throws {
        let warmPage = try page([result(id: 101, title: "Warm result", score: 4)])
        let engine = ScriptedSearchEngine(scripts: [:])
        let model = SearchSessionModel(
            engine: engine,
            debounceDuration: .zero,
            initialPage: warmPage,
            requestBuilder: Self.request
        )

        XCTAssertEqual(model.phase, .results(query: "", count: 1))
        XCTAssertEqual(model.results, warmPage.results)
        XCTAssertNil(model.settledQuery)
        XCTAssertEqual(model.settlementCount, 0)
        let invokedQueries = await engine.invokedQueries()
        XCTAssertEqual(invokedQueries, [])
    }

    func testSlowSearchPublishesDebouncingThenLoadingWithoutStaleResults() async throws {
        let oldPage = try page([result(id: 100, title: "Old result", score: 3)])
        let slowPage = try page([result(id: 102, title: "Slow result", score: 5)])
        let engine = ScriptedSearchEngine(
            scripts: ["slow": .success(page: slowPage, delayMilliseconds: 100)]
        )
        let model = SearchSessionModel(
            engine: engine,
            debounceDuration: .milliseconds(20),
            initialPage: oldPage,
            requestBuilder: Self.request
        )

        model.updateQuery(" slow ")
        XCTAssertEqual(model.phase, .debouncing(query: "slow"))
        XCTAssertEqual(model.results, [])
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertEqual(model.phase, .loading(query: "slow"))
        XCTAssertEqual(model.results, [])

        await model.waitForCurrentSearch()
        XCTAssertEqual(model.phase, .results(query: "slow", count: 1))
        XCTAssertEqual(model.results, slowPage.results)
        XCTAssertEqual(model.settledQuery, "slow")
        XCTAssertEqual(model.settlementCount, 1)
    }

    func testRapidTypingCannotPublishLateCancelledResults() async throws {
        let obsoletePage = try page([result(id: 103, title: "Obsolete", score: 9)])
        let finalPage = try page([result(id: 104, title: "Final", score: 7)])
        let engine = ScriptedSearchEngine(
            scripts: [
                "s": .success(page: obsoletePage, delayMilliseconds: 140),
                "safari": .success(page: finalPage, delayMilliseconds: 10),
            ]
        )
        let model = SearchSessionModel(
            engine: engine,
            debounceDuration: .zero,
            requestBuilder: Self.request
        )

        model.updateQuery("s")
        try await Task.sleep(for: .milliseconds(10))
        model.updateQuery("safari")
        await model.waitForCurrentSearch()

        XCTAssertEqual(model.phase, .results(query: "safari", count: 1))
        XCTAssertEqual(model.results, finalPage.results)
        XCTAssertEqual(model.settledQuery, "safari")
        XCTAssertEqual(model.settlementCount, 1)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(model.results, finalPage.results)
        XCTAssertEqual(model.settlementCount, 1)
        let invokedQueries = await engine.invokedQueries()
        XCTAssertEqual(invokedQueries, ["s", "safari"])
    }

    func testFailureSettlesOnceWithContentFreeDiagnostic() async {
        let engine = ScriptedSearchEngine(
            scripts: ["broken": .failure(delayMilliseconds: 5)]
        )
        let model = SearchSessionModel(
            engine: engine,
            debounceDuration: .zero,
            requestBuilder: Self.request
        )

        model.updateQuery("broken")
        await model.waitForCurrentSearch()

        XCTAssertEqual(
            model.phase,
            .failure(query: "broken", diagnosticCode: "LM-SEARCH-QUERY")
        )
        XCTAssertEqual(model.results, [])
        XCTAssertEqual(model.settledQuery, "broken")
        XCTAssertEqual(model.settlementCount, 1)
    }

    func testSameQueryDoesNotExecuteOrSettleTwice() async throws {
        let searchPage = try page([result(id: 105, title: "Stable", score: 6)])
        let engine = ScriptedSearchEngine(
            scripts: ["stable": .success(page: searchPage, delayMilliseconds: 0)]
        )
        let model = SearchSessionModel(
            engine: engine,
            debounceDuration: .zero,
            requestBuilder: Self.request
        )

        model.updateQuery("stable")
        await model.waitForCurrentSearch()
        model.updateQuery("stable")
        await model.waitForCurrentSearch()

        XCTAssertEqual(model.results, searchPage.results)
        XCTAssertEqual(model.settlementCount, 1)
        let invokedQueries = await engine.invokedQueries()
        XCTAssertEqual(invokedQueries, ["stable"])
    }

    func testClearingQueryCancelsWorkAndRestoresWarmPage() async throws {
        let warmPage = try page([result(id: 106, title: "Recent", score: 4)])
        let latePage = try page([result(id: 107, title: "Late", score: 8)])
        let engine = ScriptedSearchEngine(
            scripts: ["late": .success(page: latePage, delayMilliseconds: 80)]
        )
        let model = SearchSessionModel(
            engine: engine,
            debounceDuration: .zero,
            initialPage: warmPage,
            requestBuilder: Self.request
        )

        model.updateQuery("late")
        try await Task.sleep(for: .milliseconds(10))
        model.updateQuery("")
        XCTAssertEqual(model.phase, .results(query: "", count: 1))
        XCTAssertEqual(model.results, warmPage.results)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.results, warmPage.results)
        XCTAssertEqual(model.settlementCount, 0)
    }

    nonisolated private static func request(_ query: String) throws -> SearchRequest {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000)
        )
        let policy = try AccessPolicy(
            id: UUID(uuidString: "39000000-0000-0000-0000-000000000001")!,
            name: "LM-039 test session",
            allowedInterval: interval,
            allowedBundleIDs: ["com.example.fixture"],
            allowedHosts: [],
            maxResults: 20,
            expiresAt: interval.end.addingTimeInterval(60),
            createdByUser: true
        )
        return try SearchRequest(
            query: query,
            interval: nil,
            bundleIDs: [],
            hosts: [],
            mode: .textOnly,
            pageSize: 20,
            cursor: nil,
            accessPolicy: policy
        )
    }

    private func page(_ results: [SearchResult]) throws -> SearchPage {
        try SearchPage(results: results, nextCursor: nil)
    }

    private func result(id: Int, title: String, score: Double) throws -> SearchResult {
        try SearchResult(
            frameID: UUID(uuidString: String(format: "39000000-0000-0000-0001-%012d", id))!,
            capturedAt: Date(timeIntervalSince1970: Double(10_000 + id)),
            foreground: ForegroundContext(
                bundleID: "com.example.fixture",
                applicationName: "Fixture App",
                processID: nil,
                windowTitle: title,
                windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            ),
            browser: nil,
            thumbnailLocator: nil,
            mediaLocator: .opaqueResourceID("lm039-\(id)"),
            evidence: [SearchEvidence(source: .title, matchedText: title, score: score)],
            textRank: 1,
            visualRank: nil,
            fusedScore: score
        )
    }
}

private enum ScriptedSearchError: Error {
    case failed
}

private enum ScriptedSearchResponse: Sendable {
    case success(page: SearchPage, delayMilliseconds: Int)
    case failure(delayMilliseconds: Int)

    var delayMilliseconds: Int {
        switch self {
        case .success(_, let delayMilliseconds), .failure(let delayMilliseconds):
            delayMilliseconds
        }
    }
}

private actor ScriptedSearchEngine: SearchEngine {
    private let scripts: [String: ScriptedSearchResponse]
    private var queries: [String] = []

    init(scripts: [String: ScriptedSearchResponse]) {
        self.scripts = scripts
    }

    func search(_ request: SearchRequest) async throws -> SearchPage {
        queries.append(request.query)
        let response = scripts[request.query] ?? .failure(delayMilliseconds: 0)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .milliseconds(response.delayMilliseconds)
            ) {
                continuation.resume()
            }
        }
        switch response {
        case .success(let page, _): return page
        case .failure: throw ScriptedSearchError.failed
        }
    }

    func invokedQueries() -> [String] {
        queries
    }
}
