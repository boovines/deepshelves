import Foundation

public enum ActivityHeatmapProjectionError: Error, Equatable, Sendable {
    case invalidInterval
    case invalidActivityRecords
    case calendarFailure
}

public enum ActivityHourOccurrence: String, Equatable, Sendable {
    case standard
    case firstOccurrence
    case repeatedOccurrence
    case missing
}

public struct ActivityHeatmapTableRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let dayLabel: String
    public let hourLabel: String
    public let occurrence: ActivityHourOccurrence
    public let recordedDuration: TimeInterval
    public let unrecordedDuration: TimeInterval
    public let accessibilityLabel: String
}

public struct ActivityHeatmapCell: Identifiable, Equatable, Sendable {
    public let id: String
    public let dayLabel: String
    public let hourLabel: String
    public let localHour: Int
    public let occurrence: ActivityHourOccurrence
    public let interval: DateInterval?
    public let recordedDuration: TimeInterval
    public let unrecordedDuration: TimeInterval
    public let intensity: Double
    public let accessibilityLabel: String

    public var timelineInterval: DateInterval? { interval }

    public var tableRow: ActivityHeatmapTableRow {
        ActivityHeatmapTableRow(
            id: id,
            dayLabel: dayLabel,
            hourLabel: hourLabel,
            occurrence: occurrence,
            recordedDuration: recordedDuration,
            unrecordedDuration: unrecordedDuration,
            accessibilityLabel: accessibilityLabel
        )
    }
}

public struct ActivityHeatmapDay: Identifiable, Equatable, Sendable {
    public let id: String
    public let interval: DateInterval
    public let label: String
    public let cells: [ActivityHeatmapCell]

    public var tableRows: [ActivityHeatmapTableRow] { cells.map(\.tableRow) }
    public var recordedDuration: TimeInterval { cells.reduce(0) { $0 + $1.recordedDuration } }
    public var unrecordedDuration: TimeInterval {
        cells.reduce(0) { $0 + $1.unrecordedDuration }
    }
}

public struct ActivityHeatmapProjection: Equatable, Sendable {
    public let interval: DateInterval
    public let days: [ActivityHeatmapDay]

    public var recordedDuration: TimeInterval { days.reduce(0) { $0 + $1.recordedDuration } }
    public var unrecordedDuration: TimeInterval {
        days.reduce(0) { $0 + $1.unrecordedDuration }
    }
}

public enum ActivityHeatmapProjector {
    public static func project(
        records: [DurableForegroundActivityInterval],
        interval: DateInterval,
        calendar: Calendar
    ) throws -> ActivityHeatmapProjection {
        guard interval.start < interval.end else {
            throw ActivityHeatmapProjectionError.invalidInterval
        }
        let sortedRecords = records.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        for (current, next) in zip(sortedRecords, sortedRecords.dropFirst())
        where current.endedAt > next.startedAt {
            throw ActivityHeatmapProjectionError.invalidActivityRecords
        }

        guard var day = calendar.dateInterval(of: .day, for: interval.start) else {
            throw ActivityHeatmapProjectionError.calendarFailure
        }
        var days: [ActivityHeatmapDay] = []
        while day.start < interval.end {
            if day.end > interval.start {
                days.append(
                    try projectDay(
                        day,
                        selectedInterval: interval,
                        records: sortedRecords,
                        calendar: calendar
                    )
                )
            }
            guard let nextAnchor = calendar.date(byAdding: .day, value: 1, to: day.start),
                let nextDay = calendar.dateInterval(of: .day, for: nextAnchor),
                nextDay.start > day.start
            else {
                throw ActivityHeatmapProjectionError.calendarFailure
            }
            day = nextDay
        }
        return ActivityHeatmapProjection(interval: interval, days: days)
    }

    private static func projectDay(
        _ day: DateInterval,
        selectedInterval: DateInterval,
        records: [DurableForegroundActivityInterval],
        calendar: Calendar
    ) throws -> ActivityHeatmapDay {
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? Locale.current
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let dayLabel = formatter.string(from: day.start)
        let dayID = day.start.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: false, timeZone: .gmt)
        )
        var actualStarts: [Date] = []
        var cursor = day.start
        while cursor < day.end {
            actualStarts.append(cursor)
            cursor = cursor.addingTimeInterval(60 * 60)
        }
        let grouped = Dictionary(grouping: actualStarts) {
            calendar.component(.hour, from: $0)
        }
        let includesWholeDay =
            selectedInterval.start <= day.start && selectedInterval.end >= day.end
        var cells: [ActivityHeatmapCell] = []
        for hour in 0..<24 {
            let starts = grouped[hour, default: []]
            if starts.isEmpty {
                if includesWholeDay {
                    cells.append(missingCell(dayID: dayID, dayLabel: dayLabel, hour: hour))
                }
                continue
            }
            for (index, start) in starts.enumerated() {
                let raw = DateInterval(
                    start: start,
                    end: min(start.addingTimeInterval(60 * 60), day.end)
                )
                let clippedStart = max(raw.start, selectedInterval.start)
                let clippedEnd = min(raw.end, selectedInterval.end)
                guard clippedStart < clippedEnd else { continue }
                let occurrence: ActivityHourOccurrence =
                    if starts.count == 1 {
                        .standard
                    } else if index == 0 {
                        .firstOccurrence
                    } else {
                        .repeatedOccurrence
                    }
                cells.append(
                    try cell(
                        dayID: dayID,
                        dayLabel: dayLabel,
                        hour: hour,
                        occurrence: occurrence,
                        interval: DateInterval(start: clippedStart, end: clippedEnd),
                        records: records
                    )
                )
            }
        }
        return ActivityHeatmapDay(id: dayID, interval: day, label: dayLabel, cells: cells)
    }

    private static func cell(
        dayID: String,
        dayLabel: String,
        hour: Int,
        occurrence: ActivityHourOccurrence,
        interval: DateInterval,
        records: [DurableForegroundActivityInterval]
    ) throws -> ActivityHeatmapCell {
        let active = records.filter(\.isActive).reduce(0.0) { partial, record in
            let start = max(record.startedAt, interval.start)
            let end = min(record.endedAt, interval.end)
            return partial + max(0, end.timeIntervalSince(start))
        }
        guard active <= interval.duration + 0.000_001 else {
            throw ActivityHeatmapProjectionError.invalidActivityRecords
        }
        let recorded = min(active, interval.duration)
        let unrecorded = interval.duration - recorded
        let hourLabel = label(for: hour)
        let occurrenceLabel =
            switch occurrence {
            case .firstOccurrence: "first daylight-saving occurrence"
            case .repeatedOccurrence: "repeated daylight-saving occurrence"
            case .standard: ""
            case .missing: "missing due to daylight saving time"
            }
        let separator = occurrenceLabel.isEmpty ? "" : ", \(occurrenceLabel)"
        let accessibility =
            "\(dayLabel), \(hourLabel)\(separator), \(minutes(recorded)) recorded minutes, \(minutes(unrecorded)) unrecorded minutes"
        return ActivityHeatmapCell(
            id:
                "\(dayID)-\(hour)-\(occurrence.rawValue)-\(Int(interval.start.timeIntervalSince1970))",
            dayLabel: dayLabel,
            hourLabel: hourLabel,
            localHour: hour,
            occurrence: occurrence,
            interval: interval,
            recordedDuration: recorded,
            unrecordedDuration: unrecorded,
            intensity: interval.duration > 0 ? recorded / interval.duration : 0,
            accessibilityLabel: accessibility
        )
    }

    private static func missingCell(
        dayID: String,
        dayLabel: String,
        hour: Int
    ) -> ActivityHeatmapCell {
        let hourLabel = label(for: hour)
        return ActivityHeatmapCell(
            id: "\(dayID)-\(hour)-missing",
            dayLabel: dayLabel,
            hourLabel: hourLabel,
            localHour: hour,
            occurrence: .missing,
            interval: nil,
            recordedDuration: 0,
            unrecordedDuration: 0,
            intensity: 0,
            accessibilityLabel:
                "\(dayLabel), \(hourLabel), missing due to daylight saving time, no elapsed interval"
        )
    }

    private static func label(for hour: Int) -> String {
        switch hour {
        case 0: "12 AM"
        case 1..<12: "\(hour) AM"
        case 12: "12 PM"
        default: "\(hour - 12) PM"
        }
    }

    private static func minutes(_ duration: TimeInterval) -> String {
        String(format: "%.0f", duration / 60)
    }
}
