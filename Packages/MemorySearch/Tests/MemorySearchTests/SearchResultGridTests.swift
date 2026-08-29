import Foundation
import MemoryContracts
import XCTest

@testable import MemorySearch

@MainActor
final class SearchResultGridTests: XCTestCase {
    func testPaginationAppendsStableUniqueResultsAndUsesTheOpaqueCursor() async throws {
        let first = try result(suffix: 1, score: 3)
        let second = try result(suffix: 2, score: 2)
        let third = try result(suffix: 3, score: 1)
        let engine = PagedGridEngine(
            firstPage: try SearchPage(
                results: [first, second],
                nextCursor: SearchCursor(token: "page-2")
            ),
            secondPage: try SearchPage(results: [second, third], nextCursor: nil)
        )
        let model = SearchSessionModel(
            engine: engine,
            debounceDuration: .zero,
            pageRequestBuilder: Self.request
        )

        model.updateQuery("lamp")
        await model.waitForCurrentSearch()
        XCTAssertEqual(model.results.map(\.frameID), [first.frameID, second.frameID])

        await model.loadNextPage()

        XCTAssertEqual(
            model.results.map(\.frameID),
            [first.frameID, second.frameID, third.frameID]
        )
        XCTAssertNil(model.nextCursor)
        XCTAssertFalse(model.isLoadingNextPage)
        XCTAssertNil(model.paginationFailureDiagnosticCode)
        let cursorTokens = await engine.cursorTokens()
        XCTAssertEqual(cursorTokens, [nil, "page-2"])
    }

    func testProvisionallyHiddenResultCannotReappearFromLaterSearchOrPagination() async throws {
        let hidden = try result(suffix: 40, score: 3)
        let visible = try result(suffix: 41, score: 2)
        let later = try result(suffix: 42, score: 1)
        let engine = PagedGridEngine(
            firstPage: try SearchPage(
                results: [hidden, visible], nextCursor: SearchCursor(token: "page-2")),
            secondPage: try SearchPage(results: [hidden, later], nextCursor: nil)
        )
        let model = SearchSessionModel(
            engine: engine,
            debounceDuration: .zero,
            pageRequestBuilder: Self.request
        )
        model.updateQuery("lamp")
        await model.waitForCurrentSearch()

        model.hideResults(frameIDs: [hidden.frameID])
        model.updateQuery("lamp again")
        await model.waitForCurrentSearch()
        await model.loadNextPage()

        XCTAssertEqual(model.results.map(\.frameID), [visible.frameID, later.frameID])
        XCTAssertFalse(model.results.contains { $0.frameID == hidden.frameID })
    }

    func testAdaptiveProjectionPreservesCardProvenanceAndExplicitStates() throws {
        let result = try result(suffix: 7, score: 4)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        XCTAssertEqual(SearchResultGridProjection.columnCount(availableWidth: 900), 3)
        XCTAssertEqual(SearchResultGridProjection.columnCount(availableWidth: 719), 2)
        XCTAssertEqual(SearchResultGridProjection.columnCount(availableWidth: 519), 1)

        let card = try XCTUnwrap(
            SearchResultGridProjection.cards(
                from: [result],
                calendar: calendar
            ).first
        )
        XCTAssertEqual(card.frameID, result.frameID)
        XCTAssertEqual(card.title, "Lamp result 7")
        XCTAssertEqual(card.applicationName, "Safari")
        XCTAssertEqual(card.host, "example.com")
        XCTAssertEqual(card.evidenceSource, .title)
        XCTAssertEqual(card.evidenceText, "Lamp")
        XCTAssertEqual(card.position, 1)
        XCTAssertEqual(card.resultCount, 1)
        XCTAssertTrue(card.accessibilityLabel.contains("Safari"))
        XCTAssertTrue(card.accessibilityLabel.contains("example.com"))
        XCTAssertTrue(card.accessibilityLabel.contains("result 1 of 1"))

        XCTAssertEqual(
            SearchResultGridProjection.contentState(
                phase: .idle,
                archiveHasSearchableContent: false,
                activeFilterLabels: [],
                indexingBacklog: 0
            ),
            .emptyArchive
        )
        XCTAssertEqual(
            SearchResultGridProjection.contentState(
                phase: .empty(query: "lamp"),
                archiveHasSearchableContent: true,
                activeFilterLabels: ["Safari", "Yesterday"],
                indexingBacklog: 12
            ),
            .noResults(
                query: "lamp",
                activeFilterLabels: ["Safari", "Yesterday"],
                indexingBacklog: 12
            )
        )
        XCTAssertEqual(
            SearchResultGridProjection.accessibilityAnnouncement(
                previousCount: 60,
                currentCount: 100,
                indexingBacklog: 12,
                hasNextPage: true
            ),
            "40 more results loaded, 100 shown. Still indexing 12 moments. More results available."
        )
        XCTAssertEqual(
            SearchResultGridProjection.contentState(
                phase: .results(query: "lamp", count: 4),
                archiveHasSearchableContent: true,
                activeFilterLabels: [],
                indexingBacklog: 7
            ),
            .addingVisualMatches(count: 4, indexingBacklog: 7)
        )
    }

    func testTenThousandCardProjectionIsDeterministicWithoutClaimingRuntimePerformance() throws {
        var results: [SearchResult] = []
        results.reserveCapacity(10_000)
        for suffix in 1...10_000 {
            results.append(try result(suffix: suffix, score: Double(10_001 - suffix)))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let cards = SearchResultGridProjection.cards(from: results, calendar: calendar)

        XCTAssertEqual(cards.count, 10_000)
        XCTAssertEqual(cards.first?.frameID, results.first?.frameID)
        XCTAssertEqual(cards.first?.position, 1)
        XCTAssertEqual(cards.last?.frameID, results.last?.frameID)
        XCTAssertEqual(cards.last?.position, 10_000)
        XCTAssertTrue(cards.allSatisfy { $0.resultCount == 10_000 })
    }

    func testEveryContractEvidenceSourceRendersWithoutInventingASummary() throws {
        let fixtures: [(SearchEvidence, String, String?)] = [
            (
                SearchEvidence(source: .accessibility, matchedText: "Save changes", score: 7),
                "Accessibility text", "Save changes"
            ),
            (
                SearchEvidence(source: .visionOCR, matchedText: "Quarterly report", score: 6),
                "On-screen text", "Quarterly report"
            ),
            (
                SearchEvidence(source: .application, matchedText: "Safari", score: 5),
                "Application", "Safari"
            ),
            (
                SearchEvidence(source: .title, matchedText: "Project Atlas", score: 4),
                "Window title", "Project Atlas"
            ),
            (
                SearchEvidence(source: .url, matchedText: "example.com/atlas", score: 3),
                "Page address", "example.com/atlas"
            ),
            (
                SearchEvidence(source: .transcript, matchedText: "review the launch", score: 2),
                "Transcript", "review the launch"
            ),
            (SearchEvidence(source: .visual, matchedText: nil, score: 1), "Visual similarity", nil),
        ]
        let results = try fixtures.enumerated().map { index, fixture in
            try result(suffix: index + 100, score: fixture.0.score, evidence: [fixture.0])
        }

        let cards = SearchResultGridProjection.cards(from: results)

        XCTAssertEqual(cards.count, fixtures.count)
        for (card, fixture) in zip(cards, fixtures) {
            XCTAssertEqual(card.evidence.count, 1)
            XCTAssertEqual(card.evidence[0].sourceLabel, fixture.1)
            XCTAssertEqual(card.evidence[0].matchedText, fixture.2)
            XCTAssertNil(card.summaryText)
            XCTAssertNil(card.componentDebug)
        }
    }

    func testEvidenceDisclosureIsSecondaryExactAndNeverInventsASummary() throws {
        let evidence = [
            SearchEvidence(source: .accessibility, matchedText: "Save changes", score: 4),
            SearchEvidence(source: .visionOCR, matchedText: "Quarterly report", score: 3),
        ]

        let disclosure = SearchEvidenceDisclosureProjection(evidence: evidence)

        XCTAssertEqual(disclosure.summary, "Matched using accessibility text")
        XCTAssertEqual(
            disclosure.lines.map(\.sourceLabel), ["Accessibility text", "On-screen text"])
        XCTAssertEqual(disclosure.lines.map(\.matchedText), ["Save changes", "Quarterly report"])
        XCTAssertEqual(disclosure.accessibilityLabel, "Source details, 2 validated evidence items")
        XCTAssertFalse(disclosure.summary.contains("Save changes"))
        XCTAssertEqual(
            SearchEvidenceDisclosureProjection(evidence: []).summary,
            "Source details unavailable"
        )
    }

    func testComponentDebugProjectionExistsOnlyBehindDiagnosticsFlag() throws {
        let result = try result(suffix: 200, score: 0.03125)

        let normal = try XCTUnwrap(
            SearchResultGridProjection.cards(from: [result], diagnosticsEnabled: false).first
        )
        let diagnostic = try XCTUnwrap(
            SearchResultGridProjection.cards(from: [result], diagnosticsEnabled: true).first
        )

        XCTAssertNil(normal.componentDebug)
        XCTAssertEqual(diagnostic.componentDebug?.textRank, result.textRank)
        XCTAssertEqual(diagnostic.componentDebug?.visualRank, result.visualRank)
        XCTAssertEqual(diagnostic.componentDebug?.fusedScore, result.fusedScore)
        XCTAssertEqual(
            diagnostic.componentDebug?.displayText,
            "Text rank 200 · Fused score 0.031250"
        )
    }

    func testThumbnailRepositoryCachesExactIdentityAndRejectsStaleCompletion() async throws {
        let oldResult = try result(suffix: 9, score: 2, thumbnailName: "old")
        let newResult = try result(suffix: 9, score: 2, thumbnailName: "new")
        let probe = ThumbnailLoaderProbe()
        let repository = SearchThumbnailRepository(
            capacityBytes: 32,
            loader: SearchThumbnailLoader { result in
                try await probe.load(result)
            }
        )

        async let oldResponse = repository.thumbnail(for: oldResult)
        try await Task.sleep(for: .milliseconds(2))
        async let newResponse = repository.thumbnail(for: newResult)
        let (oldValue, newValue) = try await (oldResponse, newResponse)

        XCTAssertNil(oldValue)
        XCTAssertEqual(newValue?.identity.frameID, newResult.frameID)
        XCTAssertEqual(newValue?.identity.locatorValue, "thumbnails/new.heic")
        XCTAssertEqual(newValue?.raster.rgba8, [0, 255, 0, 255])

        let cached = try await repository.thumbnail(for: newResult)
        XCTAssertEqual(cached, newValue)
        let loadCount = await probe.loadCount()
        let cachedCount = await repository.cachedCount()
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(cachedCount, 1)
    }

    nonisolated private static func request(
        _ input: SearchSessionInput,
        _ cursor: SearchCursor?
    ) throws -> SearchRequest {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_785_542_400),
            end: Date(timeIntervalSince1970: 1_788_134_400)
        )
        let policy = try AccessPolicy(
            id: UUID(uuidString: "41000000-0000-0000-0000-000000000001")!,
            name: "LM-041 grid",
            allowedInterval: interval,
            allowedBundleIDs: ["com.apple.Safari"],
            allowedHosts: ["example.com"],
            maxResults: 20,
            expiresAt: interval.end.addingTimeInterval(60),
            createdByUser: true
        )
        return try SearchRequest(
            query: input.query,
            interval: input.interval,
            bundleIDs: input.bundleIDs,
            hosts: input.hosts,
            mode: .textOnly,
            pageSize: 2,
            cursor: cursor,
            accessPolicy: policy
        )
    }

    private func result(
        suffix: Int,
        score: Double,
        thumbnailName: String? = nil,
        evidence: [SearchEvidence]? = nil
    ) throws -> SearchResult {
        try SearchResult(
            frameID: UUID(uuidString: String(format: "41000000-0000-4000-8000-%012d", suffix))!,
            capturedAt: Date(timeIntervalSince1970: 1_788_000_000 - Double(suffix)),
            foreground: ForegroundContext(
                bundleID: "com.apple.Safari",
                applicationName: "Safari",
                processID: nil,
                windowTitle: "Lamp result \(suffix)",
                windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            ),
            browser: BrowserContext(
                family: .safari,
                origin: BrowserOrigin(scheme: "https", host: "example.com", path: nil),
                isPrivateContext: false
            ),
            thumbnailLocator: .archiveRelativePath(
                "thumbnails/\(thumbnailName ?? "lamp-\(suffix)").heic"
            ),
            mediaLocator: .opaqueResourceID("lamp-\(suffix)"),
            evidence: evidence
                ?? [SearchEvidence(source: .title, matchedText: "Lamp", score: score)],
            textRank: suffix,
            visualRank: nil,
            fusedScore: score
        )
    }
}

private actor ThumbnailLoaderProbe {
    private var count = 0

    func load(_ result: SearchResult) async throws -> SearchThumbnailRaster {
        count += 1
        guard case .archiveRelativePath(let path)? = result.thumbnailLocator else {
            throw SearchThumbnailError.unavailable
        }
        if path.contains("old") {
            try await Task.sleep(for: .milliseconds(30))
            return try SearchThumbnailRaster(width: 1, height: 1, rgba8: [255, 0, 0, 255])
        }
        try await Task.sleep(for: .milliseconds(1))
        return try SearchThumbnailRaster(width: 1, height: 1, rgba8: [0, 255, 0, 255])
    }

    func loadCount() -> Int { count }
}

private actor PagedGridEngine: SearchEngine {
    private let firstPage: SearchPage
    private let secondPage: SearchPage
    private var recordedCursorTokens: [String?] = []

    init(firstPage: SearchPage, secondPage: SearchPage) {
        self.firstPage = firstPage
        self.secondPage = secondPage
    }

    func search(_ request: SearchRequest) async throws -> SearchPage {
        recordedCursorTokens.append(request.cursor?.token)
        return request.cursor == nil ? firstPage : secondPage
    }

    func cursorTokens() -> [String?] {
        recordedCursorTokens
    }
}
