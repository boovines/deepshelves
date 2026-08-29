import Foundation
import MemoryContracts
import XCTest

@testable import MemorySearch

@MainActor
final class MomentTimelineModelTests: XCTestCase {
    func testRailProjectionPreservesExactGeometryAndPrivacySafeGapPatterns() throws {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_800_000_000),
            duration: 3_600
        )
        let first = try result(suffix: 1, capturedAt: interval.start.addingTimeInterval(600))
        let second = try result(suffix: 2, capturedAt: interval.start.addingTimeInterval(3_000))
        let excluded = try RecordingGap(
            startedAt: interval.start.addingTimeInterval(1_200),
            endedAt: interval.start.addingTimeInterval(1_800),
            reason: .excluded,
            approvedBundleID: nil
        )
        let paused = try RecordingGap(
            startedAt: interval.start.addingTimeInterval(2_400),
            endedAt: interval.start.addingTimeInterval(2_700),
            reason: .paused,
            approvedBundleID: "com.apple.Safari"
        )
        let transition = try ApplicationTransition(
            occurredAt: interval.start.addingTimeInterval(2_100),
            fromBundleID: "com.apple.Safari",
            toBundleID: "com.apple.Notes"
        )
        let slice = try TimelineSlice(
            interval: interval,
            frames: [try summary(first), try summary(second)],
            gaps: [excluded, paused],
            applicationTransitions: [transition],
            transcriptMarkers: []
        )

        let projection = try MomentTimelineProjection(
            source: MomentTimelineSourcePage(
                slice: slice,
                results: [first, second],
                previousCursor: nil,
                nextCursor: nil
            )
        )

        XCTAssertEqual(projection.moments.map(\.normalizedPosition), [1.0 / 6.0, 5.0 / 6.0])
        XCTAssertEqual(projection.applicationSegments.count, 1)
        XCTAssertEqual(projection.applicationSegments[0].applicationName, "Safari")
        XCTAssertEqual(projection.applicationSegments[0].normalizedStart, 0)
        XCTAssertEqual(projection.applicationSegments[0].normalizedEnd, 1)
        XCTAssertEqual(projection.gaps.map(\.pattern), [.privacy, .userControl])
        XCTAssertEqual(projection.gaps.map(\.normalizedStart), [1.0 / 3.0, 2.0 / 3.0])
        XCTAssertEqual(projection.gaps.map(\.normalizedEnd), [0.5, 0.75])
        XCTAssertFalse(projection.gaps[0].accessibilityLabel.contains("com.apple"))
        XCTAssertTrue(projection.gaps[0].accessibilityLabel.contains("Excluded"))
        XCTAssertEqual(projection.transitions.map(\.normalizedPosition), [7.0 / 12.0])
        XCTAssertTrue(projection.transitions[0].accessibilityLabel.contains("com.apple.Notes"))
        XCTAssertEqual(
            projection.accessibilityItems.map(\.kind),
            [.moment, .gap, .transition, .gap, .moment]
        )
        XCTAssertEqual(
            projection.accessibilityItems.compactMap(\.frameID),
            [first.frameID, second.frameID]
        )
    }

    func testApplicationSegmentsMergeConsecutiveAppsAndZoomControlsHaveRealBounds() throws {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_800_005_000),
            duration: 100
        )
        let safari1 = try result(suffix: 21, capturedAt: interval.start.addingTimeInterval(10))
        let safari2 = try result(suffix: 22, capturedAt: interval.start.addingTimeInterval(40))
        let notes = try SearchResult(
            frameID: UUID(uuidString: "45000000-0000-4000-8000-000000000023")!,
            capturedAt: interval.start.addingTimeInterval(90),
            foreground: ForegroundContext(
                bundleID: "com.apple.Notes",
                applicationName: "Notes",
                processID: nil,
                windowTitle: "Note",
                windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            ),
            browser: nil,
            thumbnailLocator: .archiveRelativePath("thumbnails/notes.heic"),
            mediaLocator: .archiveRelativePath("media/notes.heic"),
            evidence: [SearchEvidence(source: .application, matchedText: "Notes", score: 0)],
            textRank: nil,
            visualRank: nil,
            fusedScore: 0
        )
        let projection = try MomentTimelineProjection(
            source: try sourcePage(interval: interval, results: [safari1, safari2, notes])
        )

        XCTAssertEqual(projection.applicationSegments.map(\.applicationName), ["Safari", "Notes"])
        XCTAssertEqual(projection.applicationSegments[0].normalizedStart, 0)
        XCTAssertEqual(projection.applicationSegments[0].normalizedEnd, 0.65)
        XCTAssertEqual(projection.applicationSegments[1].normalizedStart, 0.65)
        XCTAssertEqual(projection.applicationSegments[1].normalizedEnd, 1)
        XCTAssertNil(MomentTimelineZoomLevel.calendarDay.adjacent(towardDetail: false))
        XCTAssertEqual(
            MomentTimelineZoomLevel.calendarDay.adjacent(towardDetail: true),
            .sixHours
        )
        XCTAssertEqual(
            MomentTimelineZoomLevel.oneHour.adjacent(towardDetail: true),
            .fifteenMinutes
        )
        XCTAssertNil(MomentTimelineZoomLevel.fifteenMinutes.adjacent(towardDetail: true))
    }

    func testPointerAndKeyboardSelectionUseStableNearestMomentAndStopAtBoundaries() throws {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_800_010_000),
            duration: 100
        )
        let first = try result(suffix: 3, capturedAt: interval.start.addingTimeInterval(20))
        let second = try result(suffix: 4, capturedAt: interval.start.addingTimeInterval(60))
        let third = try result(suffix: 5, capturedAt: interval.start.addingTimeInterval(90))
        let projection = try MomentTimelineProjection(
            source: MomentTimelineSourcePage(
                slice: TimelineSlice(
                    interval: interval,
                    frames: try [summary(first), summary(second), summary(third)],
                    gaps: [],
                    applicationTransitions: [],
                    transcriptMarkers: []
                ),
                results: [first, second, third],
                previousCursor: nil,
                nextCursor: nil
            )
        )

        XCTAssertEqual(projection.nearestMoment(to: -4)?.result.frameID, first.frameID)
        XCTAssertEqual(projection.nearestMoment(to: 0.4)?.result.frameID, first.frameID)
        XCTAssertEqual(projection.nearestMoment(to: 0.41)?.result.frameID, second.frameID)
        XCTAssertEqual(projection.nearestMoment(to: 9)?.result.frameID, third.frameID)
        XCTAssertEqual(
            projection.adjacentMoment(to: second.frameID, direction: .previous)?.result.frameID,
            first.frameID
        )
        XCTAssertEqual(
            projection.adjacentMoment(to: second.frameID, direction: .next)?.result.frameID,
            third.frameID
        )
        XCTAssertNil(projection.adjacentMoment(to: first.frameID, direction: .previous))
        XCTAssertNil(projection.adjacentMoment(to: third.frameID, direction: .next))
    }

    func testScrubPublishesLowResolutionTargetBeforeDwellPromotesFullFrame() async throws {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_800_020_000),
            duration: 100
        )
        let first = try result(suffix: 6, capturedAt: interval.start.addingTimeInterval(10))
        let second = try result(suffix: 7, capturedAt: interval.start.addingTimeInterval(80))
        let page = try sourcePage(interval: interval, results: [first, second])
        let thumbnailGate = TimelineGate()
        let dwellGate = TimelineGate()
        let thumbnailProbe = TimelineThumbnailProbe(gate: thumbnailGate)
        let thumbnails = SearchThumbnailRepository(
            capacityBytes: 64,
            loader: SearchThumbnailLoader { result in
                try await thumbnailProbe.load(result)
            }
        )
        let model = MomentTimelineSessionModel(
            loader: MomentTimelinePageLoader { _ in page },
            thumbnailRepository: thumbnails,
            dwell: MomentTimelineDwell { await dwellGate.wait() }
        )
        await model.load(around: first)

        model.scrub(to: 0.9)

        XCTAssertEqual(model.scrubbedResult?.frameID, second.frameID)
        XCTAssertEqual(model.preview, .loading(frameID: second.frameID))
        XCTAssertEqual(model.settledResult?.frameID, first.frameID)
        await thumbnailProbe.waitUntilRequested()
        let requestedFrameIDs = await thumbnailProbe.requestedFrameIDs()
        XCTAssertEqual(requestedFrameIDs, [second.frameID])

        await thumbnailGate.open()
        await model.waitForPreview()
        guard case .ready(let response) = model.preview else {
            return XCTFail("the exact scrub target thumbnail must publish")
        }
        XCTAssertEqual(response.identity.frameID, second.frameID)
        XCTAssertEqual(model.settledResult?.frameID, first.frameID)

        await dwellGate.open()
        await model.waitForDwell()
        XCTAssertEqual(model.settledResult?.frameID, second.frameID)
    }

    func testRapidScrubRejectsStaleThumbnailAndFullFrameCompletions() async throws {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_800_030_000),
            duration: 100
        )
        let first = try result(suffix: 8, capturedAt: interval.start.addingTimeInterval(10))
        let second = try result(suffix: 9, capturedAt: interval.start.addingTimeInterval(50))
        let third = try result(suffix: 10, capturedAt: interval.start.addingTimeInterval(90))
        let thumbnailGate = TimelineGate()
        let dwellGate = TimelineGate()
        let thumbnailProbe = TimelineThumbnailProbe(gate: thumbnailGate)
        let page = try sourcePage(interval: interval, results: [first, second, third])
        let model = MomentTimelineSessionModel(
            loader: MomentTimelinePageLoader { _ in page },
            thumbnailRepository: SearchThumbnailRepository(
                capacityBytes: 64,
                loader: SearchThumbnailLoader { result in
                    try await thumbnailProbe.load(result)
                }
            ),
            dwell: MomentTimelineDwell { await dwellGate.wait() }
        )
        await model.load(around: first)

        model.scrub(to: 0.5)
        model.scrub(to: 0.9)
        await thumbnailProbe.waitUntilRequested()
        await thumbnailGate.open()
        await dwellGate.open()
        await model.waitForPreview()
        await model.waitForDwell()

        XCTAssertEqual(model.scrubbedResult?.frameID, third.frameID)
        guard case .ready(let response) = model.preview else {
            return XCTFail("only the latest thumbnail may publish")
        }
        XCTAssertEqual(response.identity.frameID, third.frameID)
        XCTAssertEqual(model.settledResult?.frameID, third.frameID)
    }

    func testZoomLevelsReloadAroundTheExactSettledFrame() async throws {
        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_800_040_000),
            duration: 3_600
        )
        let result = try result(suffix: 11, capturedAt: interval.start.addingTimeInterval(900))
        let page = try sourcePage(interval: interval, results: [result])
        let probe = TimelinePageLoaderProbe(page: page)
        let model = MomentTimelineSessionModel(
            loader: MomentTimelinePageLoader { request in
                await probe.load(request)
            }
        )
        await model.load(around: result)

        for zoom in MomentTimelineZoomLevel.allCases.dropFirst() {
            await model.setZoom(zoom)
            XCTAssertEqual(model.zoom, zoom)
            guard case .ready = model.phase else {
                return XCTFail("every declared zoom must reload a ready exact-source page")
            }
        }

        let requests = await probe.requests()
        XCTAssertEqual(requests.map(\.zoom), MomentTimelineZoomLevel.allCases)
        XCTAssertTrue(requests.allSatisfy { $0.cursor == result.capturedAt })
    }

    func testCachedScrubThumbnailRevalidatesBeforeReturningPixels() async throws {
        let result = try result(
            suffix: 12,
            capturedAt: Date(timeIntervalSince1970: 1_800_050_000)
        )
        let integrity = TimelineThumbnailIntegrityProbe()
        let repository = SearchThumbnailRepository(
            capacityBytes: 64,
            validator: SearchThumbnailValidator { result in
                try await integrity.validate(result)
            },
            loader: SearchThumbnailLoader { _ in
                try SearchThumbnailRaster(width: 1, height: 1, rgba8: [4, 5, 6, 255])
            }
        )
        _ = try await repository.thumbnail(for: result)
        await integrity.markUnavailable()

        do {
            _ = try await repository.thumbnail(for: result)
            XCTFail("cached scrub pixels must not survive current-source rejection")
        } catch {
            XCTAssertEqual(error as? SearchThumbnailError, .unavailable)
        }
    }

    private func result(suffix: Int, capturedAt: Date) throws -> SearchResult {
        try SearchResult(
            frameID: UUID(uuidString: String(format: "45000000-0000-4000-8000-%012d", suffix))!,
            capturedAt: capturedAt,
            foreground: ForegroundContext(
                bundleID: "com.apple.Safari",
                applicationName: "Safari",
                processID: nil,
                windowTitle: "Timeline \(suffix)",
                windowBounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            ),
            browser: nil,
            thumbnailLocator: .archiveRelativePath("thumbnails/timeline-\(suffix).heic"),
            mediaLocator: .archiveRelativePath("media/timeline-\(suffix).heic"),
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

    private func sourcePage(
        interval: DateInterval,
        results: [SearchResult]
    ) throws -> MomentTimelineSourcePage {
        MomentTimelineSourcePage(
            slice: try TimelineSlice(
                interval: interval,
                frames: try results.map(summary),
                gaps: [],
                applicationTransitions: [],
                transcriptMarkers: []
            ),
            results: results,
            previousCursor: nil,
            nextCursor: nil
        )
    }
}

private actor TimelineGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private actor TimelineThumbnailProbe {
    private let gate: TimelineGate
    private var frameIDs: [UUID] = []
    private var requestContinuations: [CheckedContinuation<Void, Never>] = []

    init(gate: TimelineGate) {
        self.gate = gate
    }

    func load(_ result: SearchResult) async throws -> SearchThumbnailRaster {
        frameIDs.append(result.frameID)
        let waiting = requestContinuations
        requestContinuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
        await gate.wait()
        try Task.checkCancellation()
        return try SearchThumbnailRaster(width: 1, height: 1, rgba8: [1, 2, 3, 255])
    }

    func requestedFrameIDs() -> [UUID] { frameIDs }

    func waitUntilRequested() async {
        guard frameIDs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            requestContinuations.append(continuation)
        }
    }
}

private actor TimelinePageLoaderProbe {
    private let page: MomentTimelineSourcePage
    private var recordedRequests: [MomentTimelinePageRequest] = []

    init(page: MomentTimelineSourcePage) {
        self.page = page
    }

    func load(_ request: MomentTimelinePageRequest) -> MomentTimelineSourcePage {
        recordedRequests.append(request)
        return page
    }

    func requests() -> [MomentTimelinePageRequest] { recordedRequests }
}

private actor TimelineThumbnailIntegrityProbe {
    private var unavailable = false

    func markUnavailable() { unavailable = true }

    func validate(_ result: SearchResult) throws {
        if unavailable { throw SearchThumbnailError.unavailable }
    }
}
