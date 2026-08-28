import Foundation
import GRDB
import MemoryContracts

public enum TimelineZoomLevel: String, CaseIterable, Equatable, Sendable {
    case calendarDay
    case sixHours
    case oneHour
    case fifteenMinutes

    fileprivate var fixedDuration: TimeInterval? {
        switch self {
        case .calendarDay: nil
        case .sixHours: 6 * 3_600
        case .oneHour: 3_600
        case .fifteenMinutes: 15 * 60
        }
    }
}

public enum ArchiveTimelineQueryError: Error, Equatable, Sendable {
    case invalidInterval
    case cursorOutsideInterval
    case invalidStoredProjection
    case invalidStoredGap
}

public struct TimelinePageCursor: Equatable, Sendable {
    public let start: Date

    public init(start: Date) {
        self.start = start
    }
}

public struct TimelinePageRequest: Equatable, Sendable {
    public let interval: DateInterval
    public let cursor: Date
    public let zoom: TimelineZoomLevel
    public let calendarTimeZone: TimeZone

    public init(
        interval: DateInterval,
        cursor: Date,
        zoom: TimelineZoomLevel,
        calendarTimeZone: TimeZone
    ) throws {
        guard interval.start < interval.end else {
            throw ArchiveTimelineQueryError.invalidInterval
        }
        guard cursor >= interval.start, cursor < interval.end else {
            throw ArchiveTimelineQueryError.cursorOutsideInterval
        }
        self.interval = interval
        self.cursor = cursor
        self.zoom = zoom
        self.calendarTimeZone = calendarTimeZone
    }
}

public struct TimelinePage: Equatable, Sendable {
    public let slice: TimelineSlice
    public let previousCursor: TimelinePageCursor?
    public let nextCursor: TimelinePageCursor?

    public init(
        slice: TimelineSlice,
        previousCursor: TimelinePageCursor?,
        nextCursor: TimelinePageCursor?
    ) {
        self.slice = slice
        self.previousCursor = previousCursor
        self.nextCursor = nextCursor
    }
}

public final class ArchiveTimelineQuery: @unchecked Sendable {
    private let database: ArchiveDatabase

    public init(database: ArchiveDatabase) {
        self.database = database
    }

    public func page(_ request: TimelinePageRequest) throws -> TimelinePage {
        let pageInterval = try Self.pageInterval(for: request)
        let projection = try database.atomicRead { database in
            try Self.readProjection(database: database, interval: pageInterval)
        }
        let frames = projection.frames.map(\.summary)
        let transitions = try Self.transitions(
            frames: projection.frames,
            precedingBundleID: projection.precedingBundleID
        )
        let markers = projection.frames.compactMap { frame in
            frame.hasTranscriptMarker
                ? TranscriptMarker(
                    frameID: frame.summary.frameID, occurredAt: frame.summary.capturedAt)
                : nil
        }
        let slice = try TimelineSlice(
            interval: pageInterval,
            frames: frames,
            gaps: projection.gaps,
            applicationTransitions: transitions,
            transcriptMarkers: markers
        )
        return TimelinePage(
            slice: slice,
            previousCursor: pageInterval.start > request.interval.start
                ? TimelinePageCursor(start: pageInterval.start.addingTimeInterval(-1))
                : nil,
            nextCursor: pageInterval.end < request.interval.end
                ? TimelinePageCursor(start: pageInterval.end)
                : nil
        )
    }

    private static func pageInterval(for request: TimelinePageRequest) throws -> DateInterval {
        let start: Date
        let end: Date
        if let duration = request.zoom.fixedDuration {
            let offset = request.cursor.timeIntervalSince(request.interval.start)
            let pageIndex = floor(offset / duration)
            start = request.interval.start.addingTimeInterval(pageIndex * duration)
            end = min(start.addingTimeInterval(duration), request.interval.end)
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = request.calendarTimeZone
            guard let localDay = calendar.dateInterval(of: .day, for: request.cursor) else {
                throw ArchiveTimelineQueryError.invalidInterval
            }
            start = max(localDay.start, request.interval.start)
            end = min(localDay.end, request.interval.end)
        }
        guard start < end else { throw ArchiveTimelineQueryError.invalidInterval }
        return DateInterval(start: start, end: end)
    }

    private static func readProjection(
        database: Database,
        interval: DateInterval
    ) throws -> StoredTimelineProjection {
        let frameRows = try Row.fetchAll(
            database,
            sql: """
                SELECT frames.id, frames.captured_at, frames.bundle_id,
                       merged_text_records.app_name, merged_text_records.window_title,
                       frames.window_x, frames.window_y, frames.window_w, frames.window_h,
                       frames.browser_family, frames.url_scheme,
                       merged_text_records.url_host, merged_text_records.url_path,
                       frames.thumbnail_path, frames.is_transition,
                       merged_text_records.transcript_text
                FROM frames
                JOIN media_chunks ON media_chunks.id = frames.chunk_id
                JOIN merged_text_records ON merged_text_records.frame_id = frames.id
                WHERE frames.captured_at >= ? AND frames.captured_at < ?
                  AND frames.visual_state = 'ready'
                  AND frames.text_state = 'ready'
                  AND media_chunks.state = 'ready'
                  AND merged_text_records.state = 'ready'
                  AND frames.bundle_id IS NOT NULL
                  AND merged_text_records.app_name IS NOT NULL
                  AND frames.window_x IS NOT NULL
                  AND frames.window_y IS NOT NULL
                  AND frames.window_w IS NOT NULL
                  AND frames.window_h IS NOT NULL
                ORDER BY frames.captured_at, frames.id
                """,
            arguments: [encode(interval.start), encode(interval.end)]
        )
        let precedingBundleID = try String.fetchOne(
            database,
            sql: """
                SELECT frames.bundle_id
                FROM frames
                JOIN media_chunks ON media_chunks.id = frames.chunk_id
                JOIN merged_text_records ON merged_text_records.frame_id = frames.id
                WHERE frames.captured_at < ?
                  AND frames.visual_state = 'ready'
                  AND frames.text_state = 'ready'
                  AND media_chunks.state = 'ready'
                  AND merged_text_records.state = 'ready'
                  AND frames.bundle_id IS NOT NULL
                  AND merged_text_records.app_name IS NOT NULL
                  AND frames.window_x IS NOT NULL
                  AND frames.window_y IS NOT NULL
                  AND frames.window_w IS NOT NULL
                  AND frames.window_h IS NOT NULL
                ORDER BY frames.captured_at DESC, frames.id DESC
                LIMIT 1
                """,
            arguments: [encode(interval.start)]
        )
        let gapRows = try Row.fetchAll(
            database,
            sql: """
                SELECT started_at, ended_at, bundle_id, gap_reason
                FROM activity_intervals
                WHERE state = 'gap'
                  AND started_at < ?
                  AND ended_at > ?
                ORDER BY started_at, id
                """,
            arguments: [encode(interval.end), encode(interval.start)]
        )
        return StoredTimelineProjection(
            frames: try frameRows.map(projectFrame),
            precedingBundleID: precedingBundleID,
            gaps: try gapRows.map { try projectGap($0, clippedTo: interval) }
        )
    }

    private static func projectFrame(_ row: Row) throws -> StoredTimelineFrame {
        guard let frameID = UUID(uuidString: row["id"] as String),
            let capturedAt = decode(row["captured_at"] as String)
        else {
            throw ArchiveTimelineQueryError.invalidStoredProjection
        }
        let bounds = try NormalizedRect(
            x: row["window_x"],
            y: row["window_y"],
            width: row["window_w"],
            height: row["window_h"]
        )
        let foreground = try ForegroundContext(
            bundleID: row["bundle_id"],
            applicationName: row["app_name"],
            processID: nil,
            windowTitle: row["window_title"],
            windowBounds: bounds
        )
        let host: String? = row["url_host"]
        let browser: BrowserContext?
        if let host {
            guard let family = (row["browser_family"] as String?).flatMap(BrowserFamily.init),
                let scheme: String = row["url_scheme"]
            else {
                throw ArchiveTimelineQueryError.invalidStoredProjection
            }
            browser = try BrowserContext(
                family: family,
                origin: BrowserOrigin(scheme: scheme, host: host, path: row["url_path"]),
                isPrivateContext: false
            )
        } else {
            browser = nil
        }
        let thumbnailPath: String? = row["thumbnail_path"]
        let summary = try TimelineFrameSummary(
            frameID: frameID,
            capturedAt: capturedAt,
            foreground: foreground,
            browser: browser,
            thumbnailLocator: thumbnailPath.map(ContentLocator.archiveRelativePath)
        )
        let transcriptText: String = row["transcript_text"]
        let isTransition: Bool = row["is_transition"]
        return StoredTimelineFrame(
            summary: summary,
            isTransition: isTransition,
            hasTranscriptMarker: !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    private static func projectGap(_ row: Row, clippedTo interval: DateInterval) throws
        -> RecordingGap
    {
        guard let startedAt = decode(row["started_at"] as String),
            let endedAtValue: String = row["ended_at"],
            let endedAt = decode(endedAtValue),
            let encodedReason: String = row["gap_reason"],
            let reason = RecordingGapReason(rawValue: encodedReason)
        else {
            throw ArchiveTimelineQueryError.invalidStoredGap
        }
        let clippedStart = max(startedAt, interval.start)
        let clippedEnd = min(endedAt, interval.end)
        guard clippedStart < clippedEnd else {
            throw ArchiveTimelineQueryError.invalidStoredGap
        }
        return try RecordingGap(
            startedAt: clippedStart,
            endedAt: clippedEnd,
            reason: reason,
            approvedBundleID: row["bundle_id"]
        )
    }

    private static func transitions(
        frames: [StoredTimelineFrame],
        precedingBundleID: String?
    ) throws -> [ApplicationTransition] {
        var previous = precedingBundleID
        var result: [ApplicationTransition] = []
        for frame in frames {
            let bundleID = frame.summary.foreground.bundleID
            if frame.isTransition, previous != bundleID {
                result.append(
                    try ApplicationTransition(
                        occurredAt: frame.summary.capturedAt,
                        fromBundleID: previous,
                        toBundleID: bundleID
                    )
                )
            }
            previous = bundleID
        }
        return result
    }

    private static func encode(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
    }

    private static func decode(_ value: String) -> Date? {
        try? Date(
            value,
            strategy: Date.ISO8601FormatStyle(
                includingFractionalSeconds: true,
                timeZone: .gmt
            )
        )
    }
}

private struct StoredTimelineProjection {
    let frames: [StoredTimelineFrame]
    let precedingBundleID: String?
    let gaps: [RecordingGap]
}

private struct StoredTimelineFrame {
    let summary: TimelineFrameSummary
    let isTransition: Bool
    let hasTranscriptMarker: Bool
}
