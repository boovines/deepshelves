import Foundation
import MemoryContracts
import XCTest

@testable import MemoryStore

final class ActivityHeatmapProjectionTests: XCTestCase {
    func testSpringForwardIncludesLabeledMissingHourAndMatchesTwentyThreeElapsedHours()
        throws
    {
        let calendar = activityCalendar(timeZoneID: "America/Los_Angeles")
        let day = try XCTUnwrap(
            calendar.dateInterval(
                of: .day,
                for: localDate(
                    year: 2026, month: 3, day: 8, hour: 12, calendar: calendar)))
        XCTAssertEqual(day.duration, 23 * 60 * 60)
        let projection = try ActivityHeatmapProjector.project(
            records: activeRecords(covering: day),
            interval: day,
            calendar: calendar
        )

        let row = try XCTUnwrap(projection.days.first)
        XCTAssertEqual(row.cells.count, 24)
        let missing = try XCTUnwrap(row.cells.first(where: { $0.occurrence == .missing }))
        XCTAssertNil(missing.interval)
        XCTAssertTrue(missing.accessibilityLabel.contains("missing"))
        XCTAssertTrue(missing.hourLabel.contains("2"))
        XCTAssertEqual(row.recordedDuration, 23 * 60 * 60, accuracy: 0.000_001)
        XCTAssertEqual(row.tableRows.reduce(0) { $0 + $1.recordedDuration }, row.recordedDuration)
    }

    func testFallBackLabelsBothRepeatedHoursAndMatchesTwentyFiveElapsedHours() throws {
        let calendar = activityCalendar(timeZoneID: "America/Los_Angeles")
        let day = try XCTUnwrap(
            calendar.dateInterval(
                of: .day,
                for: localDate(
                    year: 2026, month: 11, day: 1, hour: 12, calendar: calendar)))
        XCTAssertEqual(day.duration, 25 * 60 * 60)
        let projection = try ActivityHeatmapProjector.project(
            records: activeRecords(covering: day),
            interval: day,
            calendar: calendar
        )

        let row = try XCTUnwrap(projection.days.first)
        XCTAssertEqual(row.cells.count, 25)
        let repeated = row.cells.filter { cell in
            [.firstOccurrence, .repeatedOccurrence].contains(cell.occurrence)
        }
        XCTAssertEqual(repeated.count, 2)
        XCTAssertTrue(repeated[0].accessibilityLabel.contains("first"))
        XCTAssertTrue(repeated[1].accessibilityLabel.contains("repeated"))
        XCTAssertNotEqual(repeated[0].interval?.start, repeated[1].interval?.start)
        XCTAssertEqual(row.recordedDuration, 25 * 60 * 60, accuracy: 0.000_001)
        XCTAssertEqual(row.tableRows.map(\.id), row.cells.map(\.id))
    }

    func testVisualAndTableMinutesMatchAndCellDrillThroughUsesExactElapsedInterval() throws {
        let calendar = activityCalendar(timeZoneID: "Europe/Paris")
        let start = localDate(year: 2026, month: 8, day: 24, hour: 0, calendar: calendar)
        let week = DateInterval(
            start: start,
            end: try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: start))
        )
        let identity = ApprovedForegroundActivityIdentity(
            bundleID: "app.alpha",
            applicationName: "Alpha"
        )
        let records = try ForegroundActivityDeriver.derive(
            observations: [
                ForegroundActivityObservation(
                    occurredAt: start,
                    activity: .active,
                    identity: identity
                ),
                ForegroundActivityObservation(
                    occurredAt: start.addingTimeInterval(90 * 60),
                    activity: .idle,
                    identity: identity
                ),
            ],
            through: week.end
        )
        let projection = try ActivityHeatmapProjector.project(
            records: records,
            interval: week,
            calendar: calendar
        )

        XCTAssertEqual(projection.days.count, 7)
        XCTAssertEqual(projection.recordedDuration, 90 * 60, accuracy: 0.000_001)
        XCTAssertEqual(
            projection.days.flatMap(\.tableRows).reduce(0) { $0 + $1.recordedDuration },
            projection.recordedDuration,
            accuracy: 0.000_001
        )
        let firstCell = try XCTUnwrap(projection.days.first?.cells.first)
        let drillThrough = try XCTUnwrap(firstCell.timelineInterval)
        XCTAssertEqual(drillThrough.duration, 60 * 60)
        XCTAssertEqual(firstCell.recordedDuration, 60 * 60)
        XCTAssertEqual(firstCell.intensity, 1)
        let secondCell = try XCTUnwrap(projection.days.first?.cells.dropFirst().first)
        XCTAssertEqual(secondCell.recordedDuration, 30 * 60)
        XCTAssertEqual(secondCell.intensity, 0.5, accuracy: 0.000_001)
    }
}

private func activityCalendar(timeZoneID: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(identifier: timeZoneID)!
    return calendar
}

private func localDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    calendar: Calendar
) -> Date {
    calendar.date(
        from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
}

private func activeRecords(covering interval: DateInterval) throws
    -> [DurableForegroundActivityInterval]
{
    try ForegroundActivityDeriver.derive(
        observations: [
            ForegroundActivityObservation(
                occurredAt: interval.start,
                activity: .active,
                identity: ApprovedForegroundActivityIdentity(
                    bundleID: "app.alpha",
                    applicationName: "Alpha"
                )
            )
        ],
        through: interval.end
    )
}
