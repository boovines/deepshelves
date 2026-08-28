import CryptoKit
import Foundation
import MemoryContracts
import XCTest

@testable import MemoryStore

final class ArchiveTimelineQueryTests: XCTestCase {
    func testFrozen24HourFixtureHashIsStable() throws {
        let data = try timelineFixtureData()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "ebdabc6f41d55df2a796b56814f16d78555af015904e1b34883c6ffdccb57d2a")
    }

    func testFrozen24HourFixtureReturnsExactOrderingDurationsTransitionsAndMarkers() async throws {
        let fixture = try loadTimelineFixture()
        let archive = try ArchiveDatabase.deterministicTestStore()
        let store = ArchiveSearchIndexStore(database: archive)
        let start = try decodeDate(fixture.intervalStart)
        let interval = DateInterval(start: start, duration: fixture.durationSeconds)
        _ = try insertTimelineFrame(
            archive: archive,
            store: store,
            suffix: 440,
            capturedAt: start.addingTimeInterval(-60),
            bundleIdentifier: "com.apple.finder",
            applicationName: "Finder",
            windowTitle: "Before the requested day",
            host: nil,
            isTransition: false,
            hasTranscriptMarker: false
        )
        for frame in fixture.frames {
            _ = try insertTimelineFrame(
                archive: archive,
                store: store,
                suffix: frame.suffix,
                capturedAt: start.addingTimeInterval(frame.offsetSeconds),
                bundleIdentifier: frame.bundleIdentifier,
                applicationName: frame.applicationName,
                windowTitle: frame.windowTitle,
                host: frame.host,
                isTransition: frame.isTransition,
                hasTranscriptMarker: frame.hasTranscriptMarker
            )
        }
        for gap in fixture.gaps {
            try await archive.persist(
                recordingGap: RecordingGap(
                    startedAt: start.addingTimeInterval(gap.offsetSeconds),
                    endedAt: start.addingTimeInterval(
                        gap.offsetSeconds + gap.durationSeconds
                    ),
                    reason: try XCTUnwrap(RecordingGapReason(rawValue: gap.reason)),
                    approvedBundleID: gap.approvedBundleID
                )
            )
        }

        let page = try ArchiveTimelineQuery(database: archive).page(
            TimelinePageRequest(
                interval: interval,
                cursor: start,
                zoom: .calendarDay,
                calendarTimeZone: TimeZone(secondsFromGMT: 0)!
            )
        )

        XCTAssertEqual(page.slice.interval, interval)
        XCTAssertEqual(
            page.slice.frames.map(\.frameID),
            fixture.expectedOrderedFrameSuffixes.map(frameID)
        )
        XCTAssertEqual(page.slice.gaps.map { $0.reason.rawValue }, fixture.expectedGapReasons)
        XCTAssertEqual(
            page.slice.gaps.map { $0.endedAt.timeIntervalSince($0.startedAt) },
            fixture.expectedGapDurationsSeconds
        )
        XCTAssertEqual(
            page.slice.applicationTransitions.map {
                [$0.fromBundleID ?? "", $0.toBundleID ?? ""]
            },
            fixture.expectedTransitionBundles
        )
        XCTAssertEqual(page.slice.transcriptMarkers.map(\.frameID), [frameID(442)])
        XCTAssertNil(page.previousCursor)
        XCTAssertNil(page.nextCursor)
    }

    func testCrossBoundaryGapsAreClippedAndTypedWithoutExcludedIdentity() async throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let start = Date(timeIntervalSince1970: 1_794_000_000)
        let interval = DateInterval(start: start, duration: 3_600)
        try await archive.persist(
            recordingGap: RecordingGap(
                startedAt: start.addingTimeInterval(-600),
                endedAt: start.addingTimeInterval(600),
                reason: .sleep,
                approvedBundleID: "com.apple.Safari"
            )
        )
        try await archive.persist(
            recordingGap: RecordingGap(
                startedAt: start.addingTimeInterval(3_000),
                endedAt: start.addingTimeInterval(4_200),
                reason: .excluded,
                approvedBundleID: nil
            )
        )

        let page = try ArchiveTimelineQuery(database: archive).page(
            TimelinePageRequest(
                interval: interval,
                cursor: start,
                zoom: .oneHour,
                calendarTimeZone: TimeZone(secondsFromGMT: 0)!
            )
        )

        XCTAssertEqual(page.slice.gaps.map(\.reason), [.sleep, .excluded])
        XCTAssertEqual(page.slice.gaps.map(\.startedAt), [start, start.addingTimeInterval(3_000)])
        XCTAssertEqual(
            page.slice.gaps.map(\.endedAt),
            [start.addingTimeInterval(600), interval.end]
        )
        XCTAssertEqual(page.slice.gaps.map(\.approvedBundleID), ["com.apple.Safari", nil])
    }

    func testCalendarDayPaginationPreservesSpringAndFallDSTElapsedDurations() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let archive = try ArchiveDatabase.deterministicTestStore()
        let query = ArchiveTimelineQuery(database: archive)

        for (components, expectedHours) in [
            (DateComponents(year: 2026, month: 3, day: 8), 23.0),
            (DateComponents(year: 2026, month: 11, day: 1), 25.0),
        ] {
            let start = try XCTUnwrap(calendar.date(from: components))
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            let page = try query.page(
                TimelinePageRequest(
                    interval: DateInterval(start: start, end: end),
                    cursor: start,
                    zoom: .calendarDay,
                    calendarTimeZone: calendar.timeZone
                )
            )
            XCTAssertEqual(page.slice.interval.duration / 3_600, expectedHours)
            XCTAssertTrue(page.slice.frames.isEmpty)
            XCTAssertTrue(page.slice.gaps.isEmpty)
        }
    }

    func testZoomPaginationNormalizesCursorAndNeverDuplicatesBoundaryFrame() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let store = ArchiveSearchIndexStore(database: archive)
        let start = Date(timeIntervalSince1970: 1_795_000_000)
        let interval = DateInterval(start: start, duration: 24 * 3_600)
        _ = try insertTimelineFrame(
            archive: archive,
            store: store,
            suffix: 451,
            capturedAt: start.addingTimeInterval(6 * 3_600),
            bundleIdentifier: "com.example.boundary",
            applicationName: "Boundary",
            windowTitle: "Boundary frame",
            host: nil,
            isTransition: false,
            hasTranscriptMarker: false
        )

        let query = ArchiveTimelineQuery(database: archive)
        let first = try query.page(
            TimelinePageRequest(
                interval: interval,
                cursor: start.addingTimeInterval(2 * 3_600),
                zoom: .sixHours,
                calendarTimeZone: TimeZone(secondsFromGMT: 0)!
            )
        )
        let secondCursor = try XCTUnwrap(first.nextCursor)
        let second = try query.page(
            TimelinePageRequest(
                interval: interval,
                cursor: secondCursor.start,
                zoom: .sixHours,
                calendarTimeZone: TimeZone(secondsFromGMT: 0)!
            )
        )

        XCTAssertEqual(first.slice.interval, DateInterval(start: start, duration: 6 * 3_600))
        XCTAssertTrue(first.slice.frames.isEmpty)
        XCTAssertEqual(second.slice.interval.start, start.addingTimeInterval(6 * 3_600))
        XCTAssertEqual(second.slice.frames.map(\.frameID), [frameID(451)])
        XCTAssertEqual(
            second.previousCursor?.start, first.slice.interval.end.addingTimeInterval(-1))
    }

    func testSuppressedFrameAndProjectionNeverAppear() throws {
        let archive = try ArchiveDatabase.deterministicTestStore()
        let store = ArchiveSearchIndexStore(database: archive)
        let start = Date(timeIntervalSince1970: 1_796_000_000)
        let frameID = try insertTimelineFrame(
            archive: archive,
            store: store,
            suffix: 461,
            capturedAt: start.addingTimeInterval(60),
            bundleIdentifier: "com.example.suppressed",
            applicationName: "Suppressed",
            windowTitle: "Never project",
            host: "suppressed.example.test",
            isTransition: true,
            hasTranscriptMarker: true
        )
        try archive.setSearchFrameVisibilityForTesting(
            frameID: frameID,
            visualState: "suppressed",
            mergedTextState: "suppressed"
        )

        let page = try ArchiveTimelineQuery(database: archive).page(
            TimelinePageRequest(
                interval: DateInterval(start: start, duration: 3_600),
                cursor: start,
                zoom: .oneHour,
                calendarTimeZone: TimeZone(secondsFromGMT: 0)!
            )
        )

        XCTAssertTrue(page.slice.frames.isEmpty)
        XCTAssertTrue(page.slice.applicationTransitions.isEmpty)
        XCTAssertTrue(page.slice.transcriptMarkers.isEmpty)
    }
}

private struct TimelineFixture: Decodable {
    let intervalStart: String
    let durationSeconds: TimeInterval
    let frames: [TimelineFrameFixture]
    let gaps: [TimelineGapFixture]
    let expectedOrderedFrameSuffixes: [Int]
    let expectedGapReasons: [String]
    let expectedGapDurationsSeconds: [TimeInterval]
    let expectedTransitionBundles: [[String]]
}

private struct TimelineFrameFixture: Decodable {
    let suffix: Int
    let offsetSeconds: TimeInterval
    let bundleIdentifier: String
    let applicationName: String
    let windowTitle: String
    let host: String?
    let isTransition: Bool
    let hasTranscriptMarker: Bool
}

private struct TimelineGapFixture: Decodable {
    let offsetSeconds: TimeInterval
    let durationSeconds: TimeInterval
    let reason: String
    let approvedBundleID: String?
}

private func loadTimelineFixture(file: StaticString = #filePath) throws -> TimelineFixture {
    try JSONDecoder().decode(TimelineFixture.self, from: timelineFixtureData(file: file))
}

private func timelineFixtureData(file: StaticString = #filePath) throws -> Data {
    let repositoryRoot = URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(
        contentsOf: repositoryRoot.appending(path: "Fixtures/LM044/timeline-24-hour.json")
    )
}

private func insertTimelineFrame(
    archive: ArchiveDatabase,
    store: ArchiveSearchIndexStore,
    suffix: Int,
    capturedAt: Date,
    bundleIdentifier: String,
    applicationName: String,
    windowTitle: String,
    host: String?,
    isTransition: Bool,
    hasTranscriptMarker: Bool
) throws -> UUID {
    let frameID = try archive.insertSearchFrameFixtureForTesting(
        suffix: suffix,
        capturedAt: capturedAt,
        bundleIdentifier: bundleIdentifier,
        appName: applicationName,
        windowTitle: windowTitle,
        host: host,
        path: host.map { _ in "/approved" },
        isTransition: isTransition
    )
    let approved = try timelineSpan(
        suffix: suffix * 10,
        frameID: frameID,
        source: .accessibility,
        text: "Approved timeline frame \(suffix)"
    )
    let transcripts =
        try hasTranscriptMarker
        ? [
            timelineSpan(
                suffix: suffix * 10 + 1,
                frameID: frameID,
                source: .transcript,
                text: "Transcript marker"
            )
        ]
        : []
    _ = try store.publish(
        ArchiveMergedTextSeed(
            frameID: frameID,
            approvedSpans: [approved],
            transcriptSpans: transcripts,
            producerVersion: "lm044-fixture-v1"
        )
    )
    return frameID
}

private func timelineSpan(
    suffix: Int,
    frameID: UUID,
    source: TextSource,
    text: String
) throws -> TextSpan {
    try TextSpan(
        id: UUID(uuidString: String(format: "44000000-0000-0000-0000-%012d", suffix))!,
        frameID: frameID,
        source: source,
        text: text,
        bounds: nil,
        confidence: nil,
        languageCode: nil,
        sensitivity: .normal
    )
}

private func frameID(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "35000000-0000-0000-0000-%012d", suffix))!
}

private func decodeDate(_ value: String) throws -> Date {
    try Date(
        value,
        strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
    )
}
