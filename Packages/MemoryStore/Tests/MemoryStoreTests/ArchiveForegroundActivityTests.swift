import Foundation
import MemoryContracts
import XCTest

@testable import MemoryStore

final class ArchiveForegroundActivityTests: XCTestCase {
    func testSevenDayFixtureReconcilesExactElapsedDurationAndNeverCountsGapsActive()
        throws
    {
        let start = Date(timeIntervalSince1970: 1_778_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let appA = ApprovedForegroundActivityIdentity(
            bundleID: "app.alpha",
            applicationName: "Alpha"
        )
        let appB = ApprovedForegroundActivityIdentity(
            bundleID: "app.beta",
            applicationName: "Beta"
        )
        let observations = [
            ForegroundActivityObservation(occurredAt: start, activity: .active, identity: appA),
            ForegroundActivityObservation(
                occurredAt: start.addingTimeInterval(day),
                activity: .idle,
                identity: appA
            ),
            ForegroundActivityObservation(
                occurredAt: start.addingTimeInterval(2 * day),
                activity: .active,
                identity: appB
            ),
            ForegroundActivityObservation(
                occurredAt: start.addingTimeInterval(3 * day),
                activity: .idle,
                identity: nil,
                gapReason: .excluded
            ),
            ForegroundActivityObservation(
                occurredAt: start.addingTimeInterval(4 * day),
                activity: .recentlyActive,
                identity: appA
            ),
            ForegroundActivityObservation(
                occurredAt: start.addingTimeInterval(5 * day),
                activity: .idle,
                identity: nil,
                gapReason: .sleep
            ),
            ForegroundActivityObservation(
                occurredAt: start.addingTimeInterval(6 * day),
                activity: .active,
                identity: appA
            ),
        ]
        let interval = DateInterval(start: start, end: start.addingTimeInterval(7 * day))

        let derived = try ForegroundActivityDeriver.derive(
            observations: observations,
            through: interval.end
        )
        let archive = try ArchiveDatabase.deterministicTestStore()
        let store = ArchiveForegroundActivityStore(database: archive)
        try store.replace(covering: interval, with: derived)
        let totals = try store.totals(in: interval)

        XCTAssertEqual(totals.elapsedDuration, 7 * day, accuracy: 0.000_001)
        XCTAssertEqual(totals.activeDuration, 4 * day, accuracy: 0.000_001)
        XCTAssertEqual(totals.unrecordedDuration, 3 * day, accuracy: 0.000_001)
        XCTAssertEqual(totals.applicationDurations["app.alpha"], 3 * day)
        XCTAssertEqual(totals.applicationDurations["app.beta"], day)
        XCTAssertEqual(totals.gapDurations[.idle], day)
        XCTAssertEqual(totals.gapDurations[.excluded], day)
        XCTAssertEqual(totals.gapDurations[.sleep], day)
        XCTAssertEqual(
            totals.applicationDurations.values.reduce(0, +) + totals.unrecordedDuration,
            interval.duration,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try archive.recordedLifecycleGaps().map(\.reason),
            [.idle, .excluded, .sleep]
        )
        let idlePage = try ArchiveTimelineQuery(database: archive).page(
            TimelinePageRequest(
                interval: interval,
                cursor: interval.start.addingTimeInterval(day),
                zoom: .oneHour,
                calendarTimeZone: .gmt
            )
        )
        XCTAssertEqual(idlePage.slice.gaps.map(\.reason), [.idle])
    }

    func testMissingApprovedContextBecomesTypedGapAndAdjacentStatesMerge() throws {
        let start = Date(timeIntervalSince1970: 1_778_000_000)
        let app = ApprovedForegroundActivityIdentity(
            bundleID: "app.alpha",
            applicationName: "Alpha"
        )
        let derived = try ForegroundActivityDeriver.derive(
            observations: [
                ForegroundActivityObservation(
                    occurredAt: start,
                    activity: .active,
                    identity: app
                ),
                ForegroundActivityObservation(
                    occurredAt: start.addingTimeInterval(10),
                    activity: .recentlyActive,
                    identity: app
                ),
                ForegroundActivityObservation(
                    occurredAt: start.addingTimeInterval(20),
                    activity: .active,
                    identity: nil
                ),
                ForegroundActivityObservation(
                    occurredAt: start.addingTimeInterval(30),
                    activity: .idle,
                    identity: nil
                ),
            ],
            through: start.addingTimeInterval(40)
        )

        XCTAssertEqual(derived.count, 3)
        XCTAssertEqual(derived[0].elapsedDuration, 20)
        XCTAssertEqual(derived[0].bundleID, app.bundleID)
        XCTAssertEqual(derived[1].gapReason, .unresolvedWindow)
        XCTAssertEqual(derived[2].gapReason, .idle)
        XCTAssertTrue(derived.dropFirst().allSatisfy { !$0.isActive })
    }

    func testReplacementRequiresAnExactNonoverlappingPartitionAndClipsQueries() throws {
        let start = Date(timeIntervalSince1970: 1_778_000_000)
        let end = start.addingTimeInterval(100)
        let identity = ApprovedForegroundActivityIdentity(
            bundleID: "app.alpha",
            applicationName: "Alpha"
        )
        let intervals = try ForegroundActivityDeriver.derive(
            observations: [
                ForegroundActivityObservation(
                    occurredAt: start,
                    activity: .active,
                    identity: identity
                )
            ],
            through: end
        )
        let store = ArchiveForegroundActivityStore(
            database: try ArchiveDatabase.deterministicTestStore()
        )
        try store.replace(covering: DateInterval(start: start, end: end), with: intervals)

        let clipped = try store.intervals(
            in: DateInterval(
                start: start.addingTimeInterval(25),
                end: start.addingTimeInterval(75)
            )
        )
        XCTAssertEqual(clipped.count, 1)
        XCTAssertEqual(clipped[0].elapsedDuration, 50)

        XCTAssertThrowsError(
            try store.replace(
                covering: DateInterval(start: start, end: end.addingTimeInterval(1)),
                with: intervals
            )
        ) { XCTAssertEqual($0 as? ArchiveForegroundActivityError, .nonPartitioningIntervals) }
    }
}
