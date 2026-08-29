import Foundation
import MemoryContracts
import XCTest

@testable import MemorySearch

@MainActor
final class TimelineSectionModelTests: XCTestCase {
    func testActivityDrillThroughUsesExactHourCursorAndFocusedZoom() async throws {
        let source = try sourcePage()
        let probe = TimelineRequestProbe(source: source)
        let model = TimelineSectionSessionModel(
            loader: MomentTimelinePageLoader { request in
                await probe.load(request)
            }
        )
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_800_100_000),
            duration: 60 * 60
        )

        await model.focus(interval: interval)

        let requests = await probe.requests()
        XCTAssertEqual(
            requests, [MomentTimelinePageRequest(cursor: interval.start, zoom: .oneHour)])
        XCTAssertEqual(model.zoom, .oneHour)
    }

    func testCalendarNavigationPreservesLocalDaysAcrossDSTAndLocale() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "fr_FR")
        let navigator = TimelineDayNavigator(calendar: calendar)
        let spring = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let springDay = try navigator.day(containing: spring)
        let next = try navigator.moving(springDay, byDays: 1)

        XCTAssertEqual(springDay.interval.duration, 23 * 60 * 60)
        XCTAssertEqual(next.components, DateComponents(year: 2026, month: 3, day: 9))
        XCTAssertEqual(try navigator.restoring(next.components), next)

        calendar.locale = Locale(identifier: "en_US")
        XCTAssertEqual(
            try TimelineDayNavigator(calendar: calendar).restoring(next.components),
            next
        )
    }

    func testFallBackDayUsesTwentyFiveRealHoursWithoutChangingDateIdentity() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let navigator = TimelineDayNavigator(calendar: calendar)
        let fall = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))

        let day = try navigator.day(containing: fall)

        XCTAssertEqual(day.components, DateComponents(year: 2026, month: 11, day: 1))
        XCTAssertEqual(day.interval.duration, 25 * 60 * 60)
        XCTAssertTrue(day.interval.contains(day.anchor))
    }

    func testTransitionPresentationLabelsZoomedInAndSummarizesZoomedOut() throws {
        let source = try sourcePage()
        let projection = try MomentTimelineProjection(source: source)

        let detailed = TimelineTransitionPresentation.project(
            projection.transitions,
            moments: projection.moments,
            zoom: .fifteenMinutes
        )
        let summarized = TimelineTransitionPresentation.project(
            projection.transitions,
            moments: projection.moments,
            zoom: .calendarDay
        )

        XCTAssertEqual(detailed.count, 1)
        XCTAssertEqual(detailed[0].label, "Safari to Notes")
        XCTAssertEqual(summarized.map(\.label), ["1 application transition"])
        XCTAssertTrue(summarized[0].isSummary)
    }

    func testRevisitPlanContainsOnlyApplicationAndApprovedURL() throws {
        let result = try searchResult(
            browser: BrowserContext(
                family: .safari,
                origin: BrowserOrigin(scheme: "https", host: "example.test", path: "/notes"),
                isPrivateContext: false
            )
        )
        let scope = MomentRevisitScope(
            allowedInterval: DateInterval(
                start: result.capturedAt.addingTimeInterval(-1),
                end: result.capturedAt.addingTimeInterval(1)
            ),
            allowedBundleIDs: ["com.apple.Safari"],
            allowedHosts: ["example.test"]
        )

        let plan = try MomentRevisitPlanner.plan(result: result, scope: scope)

        XCTAssertEqual(plan.applicationBundleID, "com.apple.Safari")
        XCTAssertEqual(
            plan.approvedURL?.absoluteString,
            ["https:", "", "example.test", "notes"].joined(separator: "/")
        )
        XCTAssertEqual(plan.restorationScope, .applicationAndApprovedURLOnly)
        XCTAssertNil(plan.formState)
    }

    func testRevisitFailsClosedForPolicyOrUnsafeURL() throws {
        let base = try searchResult(browser: nil)
        let interval = DateInterval(
            start: base.capturedAt.addingTimeInterval(-1),
            end: base.capturedAt.addingTimeInterval(1)
        )
        XCTAssertThrowsError(
            try MomentRevisitPlanner.plan(
                result: base,
                scope: MomentRevisitScope(
                    allowedInterval: interval,
                    allowedBundleIDs: [],
                    allowedHosts: []
                )
            )
        ) { XCTAssertEqual($0 as? MomentRevisitError, .applicationNotApproved) }

        let unsafe = try searchResult(
            browser: BrowserContext(
                family: .other,
                origin: BrowserOrigin(scheme: "javascript", host: "example.test", path: nil),
                isPrivateContext: false
            )
        )
        XCTAssertThrowsError(
            try MomentRevisitPlanner.plan(
                result: unsafe,
                scope: MomentRevisitScope(
                    allowedInterval: interval,
                    allowedBundleIDs: ["com.apple.Safari"],
                    allowedHosts: ["example.test"]
                )
            )
        ) { XCTAssertEqual($0 as? MomentRevisitError, .unsafeURL) }
    }

    private func sourcePage() throws -> MomentTimelineSourcePage {
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let first = try searchResult(capturedAt: start.addingTimeInterval(60), browser: nil)
        let second = try SearchResult(
            frameID: UUID(uuidString: "46000000-0000-4000-8000-000000000002")!,
            capturedAt: start.addingTimeInterval(120),
            foreground: ForegroundContext(
                bundleID: "com.apple.Notes",
                applicationName: "Notes",
                processID: nil,
                windowTitle: "Notes",
                windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            ),
            browser: nil,
            thumbnailLocator: .archiveRelativePath("thumbnails/46-2.heic"),
            mediaLocator: .archiveRelativePath("media/46-2.heic"),
            evidence: [SearchEvidence(source: .application, matchedText: "Notes", score: 0)],
            textRank: nil,
            visualRank: nil,
            fusedScore: 0
        )
        return MomentTimelineSourcePage(
            slice: try TimelineSlice(
                interval: DateInterval(start: start, duration: 900),
                frames: [try summary(first), try summary(second)],
                gaps: [],
                applicationTransitions: [
                    ApplicationTransition(
                        occurredAt: second.capturedAt,
                        fromBundleID: "com.apple.Safari",
                        toBundleID: "com.apple.Notes"
                    )
                ],
                transcriptMarkers: []
            ),
            results: [first, second],
            previousCursor: nil,
            nextCursor: nil
        )
    }

    private func searchResult(
        capturedAt: Date = Date(timeIntervalSince1970: 1_800_100_060),
        browser: BrowserContext?
    ) throws -> SearchResult {
        try SearchResult(
            frameID: UUID(uuidString: "46000000-0000-4000-8000-000000000001")!,
            capturedAt: capturedAt,
            foreground: ForegroundContext(
                bundleID: "com.apple.Safari",
                applicationName: "Safari",
                processID: nil,
                windowTitle: "Research",
                windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            ),
            browser: browser,
            thumbnailLocator: .archiveRelativePath("thumbnails/46-1.heic"),
            mediaLocator: .archiveRelativePath("media/46-1.heic"),
            evidence: [SearchEvidence(source: .application, matchedText: "Safari", score: 0)],
            textRank: nil,
            visualRank: nil,
            fusedScore: 0
        )
    }

    private func summary(_ result: SearchResult) throws -> TimelineFrameSummary {
        try TimelineFrameSummary(
            frameID: result.frameID,
            capturedAt: result.capturedAt,
            foreground: result.foreground,
            browser: result.browser,
            thumbnailLocator: result.thumbnailLocator
        )
    }
}

private actor TimelineRequestProbe {
    private let source: MomentTimelineSourcePage
    private var recordedRequests: [MomentTimelinePageRequest] = []

    init(source: MomentTimelineSourcePage) {
        self.source = source
    }

    func load(_ request: MomentTimelinePageRequest) -> MomentTimelineSourcePage {
        recordedRequests.append(request)
        return source
    }

    func requests() -> [MomentTimelinePageRequest] {
        recordedRequests
    }
}
