import Foundation
import MemoryContracts
import XCTest

@testable import MemorySearch

@MainActor
final class SearchFilterSessionTests: XCTestCase {
    func testCommittedParserFiltersAreVisibleAndReachTheSearchRequest() async throws {
        let engine = FilterRequestRecordingEngine()
        let search = SearchSessionModel(
            engine: engine,
            debounceDuration: .zero,
            requestBuilder: Self.request
        )
        let filters = SearchFilterSessionModel(
            searchModel: search,
            parserContext: try parserContext(),
            catalog: SearchFilterCatalog(
                applications: [
                    SearchApplicationDescriptor(
                        bundleID: "com.apple.Safari",
                        displayName: "Safari"
                    )
                ],
                hosts: ["example.com"]
            )
        )

        filters.updateQueryText("yellow lamp yesterday app:Safari site:example.com")
        filters.commitQuery()
        await search.waitForCurrentSearch()

        XCTAssertEqual(filters.queryText, "yellow lamp")
        XCTAssertEqual(
            filters.tokens.map(\.label),
            ["Yesterday", "Safari", "example.com"]
        )
        let requests = await engine.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.query, "yellow lamp")
        XCTAssertEqual(request.bundleIDs, ["com.apple.Safari"])
        XCTAssertEqual(request.hosts, ["example.com"])
        XCTAssertEqual(
            request.interval,
            DateInterval(
                start: try makeDate("2026-08-28T00:00:00Z"),
                end: try makeDate("2026-08-29T00:00:00Z")
            )
        )
    }

    func testRemovingAVisibleFilterRemovesItFromTheNextRequest() async throws {
        let engine = FilterRequestRecordingEngine()
        let search = SearchSessionModel(
            engine: engine,
            debounceDuration: .zero,
            requestBuilder: Self.request
        )
        let filters = SearchFilterSessionModel(
            searchModel: search,
            parserContext: try parserContext(),
            catalog: SearchFilterCatalog(
                applications: [
                    SearchApplicationDescriptor(
                        bundleID: "com.apple.Safari",
                        displayName: "Safari"
                    )
                ],
                hosts: ["example.com"]
            )
        )
        filters.updateQueryText("lamp app:Safari site:example.com")
        filters.commitQuery()
        await search.waitForCurrentSearch()

        filters.removeFilter(id: "site:example.com")
        await search.waitForCurrentSearch()

        XCTAssertEqual(filters.tokens.map(\.label), ["Safari"])
        XCTAssertEqual(filters.hosts, [])
        XCTAssertEqual(filters.applicationBundleIDs, ["com.apple.Safari"])
        let requests = await engine.requests()
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.query, "lamp")
        XCTAssertEqual(request.hosts, [])
        XCTAssertEqual(request.bundleIDs, ["com.apple.Safari"])
    }

    func testAutocompleteReturnsOnlyApprovedMetadataForTheTypedFilterKind() throws {
        let search = SearchSessionModel(
            engine: FilterRequestRecordingEngine(),
            debounceDuration: .zero,
            requestBuilder: Self.request
        )
        let filters = SearchFilterSessionModel(
            searchModel: search,
            parserContext: try parserContext(),
            catalog: SearchFilterCatalog(
                applications: [
                    SearchApplicationDescriptor(
                        bundleID: "com.apple.Safari",
                        displayName: "Safari"
                    ),
                    SearchApplicationDescriptor(
                        bundleID: "com.apple.Notes",
                        displayName: "Notes"
                    ),
                ],
                hosts: ["example.com", "notes.example.com"]
            )
        )

        XCTAssertEqual(
            filters.autocompleteSuggestions(for: "lamp app:sa"),
            [
                SearchAutocompleteSuggestion(
                    kind: .application,
                    label: "Safari",
                    canonicalValue: "com.apple.Safari"
                )
            ]
        )
        XCTAssertEqual(
            filters.autocompleteSuggestions(for: "site:notes."),
            [
                SearchAutocompleteSuggestion(
                    kind: .site,
                    label: "notes.example.com",
                    canonicalValue: "notes.example.com"
                )
            ]
        )
        XCTAssertEqual(filters.autocompleteSuggestions(for: "app:password-manager"), [])
    }

    func testParserApplicationsExcludeAmbiguousNamesButKeepPickerOptions() throws {
        let catalog = SearchFilterCatalog(
            applications: [
                SearchApplicationDescriptor(
                    bundleID: "com.example.First",
                    displayName: "Notes"
                ),
                SearchApplicationDescriptor(
                    bundleID: "com.example.Second",
                    displayName: "notes"
                ),
                SearchApplicationDescriptor(
                    bundleID: "com.apple.Safari",
                    displayName: "Safari"
                ),
            ],
            hosts: []
        )

        XCTAssertEqual(catalog.applications.count, 3)
        XCTAssertEqual(
            catalog.parserApplications(locale: Locale(identifier: "en_US")),
            [
                SearchApplicationDescriptor(
                    bundleID: "com.apple.Safari",
                    displayName: "Safari"
                )
            ]
        )
        XCTAssertNoThrow(
            try QueryParserContext(
                referenceDate: makeDate("2026-08-29T12:00:00Z"),
                calendar: Calendar(identifier: .gregorian),
                applications: catalog.parserApplications(locale: Locale(identifier: "en_US"))
            )
        )
    }

    func testPickerAndDateControlsCreateVisibleRequestBackedTokens() async throws {
        let engine = FilterRequestRecordingEngine()
        let search = SearchSessionModel(
            engine: engine,
            debounceDuration: .zero,
            requestBuilder: Self.request
        )
        let filters = SearchFilterSessionModel(
            searchModel: search,
            parserContext: try parserContext(),
            catalog: SearchFilterCatalog(
                applications: [
                    SearchApplicationDescriptor(
                        bundleID: "com.apple.Safari",
                        displayName: "Safari"
                    )
                ],
                hosts: ["example.com"]
            )
        )
        filters.updateQueryText("lamp app:sa")

        filters.applySuggestion(
            SearchAutocompleteSuggestion(
                kind: .application,
                label: "Safari",
                canonicalValue: "com.apple.Safari"
            )
        )
        filters.applySuggestion(
            SearchAutocompleteSuggestion(
                kind: .site,
                label: "example.com",
                canonicalValue: "example.com"
            )
        )
        let interval = DateInterval(
            start: try makeDate("2026-08-28T00:00:00Z"),
            end: try makeDate("2026-08-29T00:00:00Z")
        )
        filters.setDateInterval(interval)
        await search.waitForCurrentSearch()

        XCTAssertEqual(filters.queryText, "lamp")
        XCTAssertEqual(filters.tokens.map(\.kind), [.application, .site, .time])
        XCTAssertTrue(filters.tokens.allSatisfy { !$0.label.isEmpty })
        let requests = await engine.requests()
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.query, "lamp")
        XCTAssertEqual(request.bundleIDs, ["com.apple.Safari"])
        XCTAssertEqual(request.hosts, ["example.com"])
        XCTAssertEqual(request.interval, interval)
    }

    func testQueryExamplesUseCapabilitiesWithoutArchiveContent() throws {
        let search = SearchSessionModel(
            engine: FilterRequestRecordingEngine(),
            debounceDuration: .zero,
            requestBuilder: Self.request
        )
        let filters = SearchFilterSessionModel(
            searchModel: search,
            parserContext: try parserContext(),
            catalog: SearchFilterCatalog(
                applications: [
                    SearchApplicationDescriptor(
                        bundleID: "com.apple.Safari",
                        displayName: "Safari"
                    )
                ],
                hosts: ["example.com"]
            )
        )

        XCTAssertEqual(
            filters.queryExamples,
            [
                "yellow lamp yesterday",
                "invoice app:Safari",
                "roadmap site:example.com",
            ]
        )
        XCTAssertFalse(filters.queryExamples.joined().contains("private window title"))
    }

    func testFilterSnapshotRoundTripsOnlyApprovedVisibleRequestState() async throws {
        let firstEngine = FilterRequestRecordingEngine()
        let firstSearch = SearchSessionModel(
            engine: firstEngine,
            debounceDuration: .zero,
            requestBuilder: Self.request
        )
        let first = SearchFilterSessionModel(
            searchModel: firstSearch,
            parserContext: try parserContext(),
            catalog: approvedCatalog()
        )
        first.updateQueryText("lamp")
        first.applySuggestion(
            SearchAutocompleteSuggestion(
                kind: .application,
                label: "Safari",
                canonicalValue: "com.apple.Safari"
            )
        )
        first.applySuggestion(
            SearchAutocompleteSuggestion(
                kind: .site,
                label: "example.com",
                canonicalValue: "example.com"
            )
        )
        first.setDateInterval(
            DateInterval(
                start: try makeDate("2026-08-28T00:00:00Z"),
                end: try makeDate("2026-08-29T00:00:00Z")
            )
        )

        let encoded = try JSONEncoder().encode(first.snapshot)
        let decoded = try JSONDecoder().decode(SearchFilterSnapshot.self, from: encoded)
        let secondEngine = FilterRequestRecordingEngine()
        let secondSearch = SearchSessionModel(
            engine: secondEngine,
            debounceDuration: .zero,
            requestBuilder: Self.request
        )
        let second = SearchFilterSessionModel(
            searchModel: secondSearch,
            parserContext: try parserContext(),
            catalog: approvedCatalog()
        )

        XCTAssertTrue(second.restore(decoded))
        await secondSearch.waitForCurrentSearch()

        XCTAssertEqual(second.snapshot, first.snapshot)
        XCTAssertEqual(second.tokens.map(\.label), first.tokens.map(\.label))
        let restoredRequests = await secondEngine.requests()
        let restoredRequest = try XCTUnwrap(restoredRequests.last)
        XCTAssertEqual(restoredRequest.query, "lamp")
        XCTAssertEqual(restoredRequest.bundleIDs, ["com.apple.Safari"])
        XCTAssertEqual(restoredRequest.hosts, ["example.com"])

        let unapproved = SearchFilterSnapshot(
            queryText: "lamp",
            tokens: [
                SearchQueryToken(
                    kind: .site,
                    label: "secret.invalid",
                    canonicalValue: "secret.invalid"
                )
            ],
            applicationBundleIDs: [],
            hosts: ["secret.invalid"],
            interval: nil
        )
        XCTAssertFalse(second.restore(unapproved))
        XCTAssertEqual(second.snapshot, first.snapshot)
    }

    nonisolated private static func request(_ input: SearchSessionInput) throws -> SearchRequest {
        let allowed = DateInterval(
            start: Date(timeIntervalSince1970: 1_785_542_400),
            end: Date(timeIntervalSince1970: 1_788_134_400)
        )
        let policy = try AccessPolicy(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            name: "LM-040 filter session",
            allowedInterval: allowed,
            allowedBundleIDs: ["com.apple.Safari"],
            allowedHosts: ["example.com"],
            maxResults: 20,
            expiresAt: allowed.end.addingTimeInterval(60),
            createdByUser: true
        )
        return try SearchRequest(
            query: input.query,
            interval: input.interval,
            bundleIDs: input.bundleIDs,
            hosts: input.hosts,
            mode: .textOnly,
            pageSize: 20,
            cursor: nil,
            accessPolicy: policy
        )
    }

    private func parserContext() throws -> QueryParserContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return try QueryParserContext(
            referenceDate: makeDate("2026-08-29T12:00:00Z"),
            calendar: calendar,
            applications: [
                SearchApplicationDescriptor(
                    bundleID: "com.apple.Safari",
                    displayName: "Safari"
                )
            ]
        )
    }

    private func approvedCatalog() -> SearchFilterCatalog {
        SearchFilterCatalog(
            applications: [
                SearchApplicationDescriptor(
                    bundleID: "com.apple.Safari",
                    displayName: "Safari"
                )
            ],
            hosts: ["example.com"]
        )
    }

    private func makeDate(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}

private actor FilterRequestRecordingEngine: SearchEngine {
    private var recorded: [SearchRequest] = []

    func search(_ request: SearchRequest) async throws -> SearchPage {
        recorded.append(request)
        return try SearchPage(results: [], nextCursor: nil)
    }

    func requests() -> [SearchRequest] {
        recorded
    }
}
