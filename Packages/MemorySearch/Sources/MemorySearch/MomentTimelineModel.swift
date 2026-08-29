import Combine
import Foundation
import MemoryContracts

public enum MomentTimelineError: Error, Equatable, Sendable {
    case invalidSource
    case unavailable
}

public enum MomentTimelineZoomLevel: String, CaseIterable, Codable, Equatable, Sendable {
    case calendarDay
    case sixHours
    case oneHour
    case fifteenMinutes
}

public struct MomentTimelinePageRequest: Equatable, Sendable {
    public let cursor: Date
    public let zoom: MomentTimelineZoomLevel

    public init(cursor: Date, zoom: MomentTimelineZoomLevel) {
        self.cursor = cursor
        self.zoom = zoom
    }
}

public struct MomentTimelinePageLoader: Sendable {
    private let operation:
        @Sendable (MomentTimelinePageRequest) async throws
            -> MomentTimelineSourcePage

    public init(
        operation:
            @escaping @Sendable (MomentTimelinePageRequest) async throws
            -> MomentTimelineSourcePage
    ) {
        self.operation = operation
    }

    public func load(_ request: MomentTimelinePageRequest) async throws
        -> MomentTimelineSourcePage
    {
        try await operation(request)
    }
}

public struct MomentTimelineDwell: Sendable {
    private let operation: @Sendable () async throws -> Void

    public init(operation: @escaping @Sendable () async throws -> Void) {
        self.operation = operation
    }

    public func wait() async throws {
        try await operation()
    }

    public static let standard = MomentTimelineDwell {
        try await Task.sleep(for: .milliseconds(120))
    }
}

public struct MomentTimelineSourcePage: Equatable, Sendable {
    public let slice: TimelineSlice
    public let results: [SearchResult]
    public let previousCursor: Date?
    public let nextCursor: Date?

    public init(
        slice: TimelineSlice,
        results: [SearchResult],
        previousCursor: Date?,
        nextCursor: Date?
    ) {
        self.slice = slice
        self.results = results
        self.previousCursor = previousCursor
        self.nextCursor = nextCursor
    }
}

public enum MomentTimelineGapPattern: String, Codable, Equatable, Sendable {
    case userControl
    case inactivity
    case privacy
    case unavailable

    init(reason: RecordingGapReason) {
        switch reason {
        case .paused:
            self = .userControl
        case .idle, .sleep:
            self = .inactivity
        case .excluded, .filterFailed, .protectedSurface:
            self = .privacy
        case .permissionLost, .processStopped, .unresolvedWindow, .ambiguousWindow,
            .minimizedWindow, .unsupportedDisplay, .noWindow, .unknown:
            self = .unavailable
        }
    }
}

public struct MomentTimelineMoment: Equatable, Sendable {
    public let result: SearchResult
    public let normalizedPosition: Double

    public init(result: SearchResult, normalizedPosition: Double) {
        self.result = result
        self.normalizedPosition = normalizedPosition
    }
}

public struct MomentTimelineGapSegment: Equatable, Sendable {
    public let reason: RecordingGapReason
    public let approvedBundleID: String?
    public let normalizedStart: Double
    public let normalizedEnd: Double
    public let pattern: MomentTimelineGapPattern
    public let accessibilityLabel: String

    public init(
        reason: RecordingGapReason,
        approvedBundleID: String?,
        normalizedStart: Double,
        normalizedEnd: Double,
        pattern: MomentTimelineGapPattern,
        accessibilityLabel: String
    ) {
        self.reason = reason
        self.approvedBundleID = approvedBundleID
        self.normalizedStart = normalizedStart
        self.normalizedEnd = normalizedEnd
        self.pattern = pattern
        self.accessibilityLabel = accessibilityLabel
    }
}

public struct MomentTimelineTransitionMarker: Equatable, Sendable {
    public let occurredAt: Date
    public let fromBundleID: String?
    public let toBundleID: String?
    public let normalizedPosition: Double
    public let accessibilityLabel: String

    public init(
        occurredAt: Date,
        fromBundleID: String?,
        toBundleID: String?,
        normalizedPosition: Double,
        accessibilityLabel: String
    ) {
        self.occurredAt = occurredAt
        self.fromBundleID = fromBundleID
        self.toBundleID = toBundleID
        self.normalizedPosition = normalizedPosition
        self.accessibilityLabel = accessibilityLabel
    }
}

public enum MomentTimelineAccessibilityKind: String, Codable, Equatable, Sendable {
    case moment
    case gap
    case transition
}

public struct MomentTimelineAccessibilityItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: MomentTimelineAccessibilityKind
    public let occurredAt: Date
    public let frameID: UUID?
    public let label: String

    public init(
        id: String,
        kind: MomentTimelineAccessibilityKind,
        occurredAt: Date,
        frameID: UUID?,
        label: String
    ) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.frameID = frameID
        self.label = label
    }
}

public struct MomentTimelineProjection: Equatable, Sendable {
    public let interval: DateInterval
    public let moments: [MomentTimelineMoment]
    public let gaps: [MomentTimelineGapSegment]
    public let transitions: [MomentTimelineTransitionMarker]
    public let accessibilityItems: [MomentTimelineAccessibilityItem]
    public let previousCursor: Date?
    public let nextCursor: Date?

    public init(source: MomentTimelineSourcePage) throws {
        let frameIDs = source.slice.frames.map(\.frameID)
        let resultIDs = source.results.map(\.frameID)
        guard frameIDs.count == Set(frameIDs).count,
            resultIDs.count == Set(resultIDs).count,
            Set(frameIDs) == Set(resultIDs),
            source.slice.interval.duration > 0
        else {
            throw MomentTimelineError.invalidSource
        }
        let resultByID = Dictionary(uniqueKeysWithValues: source.results.map { ($0.frameID, $0) })
        let duration = source.slice.interval.duration
        var projectedMoments: [MomentTimelineMoment] = []
        for frame in source.slice.frames {
            guard let result = resultByID[frame.frameID],
                result.capturedAt == frame.capturedAt,
                result.foreground == frame.foreground,
                result.browser == frame.browser,
                result.thumbnailLocator == frame.thumbnailLocator
            else {
                throw MomentTimelineError.invalidSource
            }
            projectedMoments.append(
                MomentTimelineMoment(
                    result: result,
                    normalizedPosition: Self.normalized(
                        frame.capturedAt,
                        interval: source.slice.interval,
                        duration: duration
                    )
                )
            )
        }
        moments = projectedMoments
        gaps = source.slice.gaps.map { gap in
            MomentTimelineGapSegment(
                reason: gap.reason,
                approvedBundleID: gap.approvedBundleID,
                normalizedStart: Self.normalized(
                    gap.startedAt,
                    interval: source.slice.interval,
                    duration: duration
                ),
                normalizedEnd: Self.normalized(
                    gap.endedAt,
                    interval: source.slice.interval,
                    duration: duration
                ),
                pattern: MomentTimelineGapPattern(reason: gap.reason),
                accessibilityLabel: Self.gapLabel(gap)
            )
        }
        transitions = source.slice.applicationTransitions.map { transition in
            MomentTimelineTransitionMarker(
                occurredAt: transition.occurredAt,
                fromBundleID: transition.fromBundleID,
                toBundleID: transition.toBundleID,
                normalizedPosition: Self.normalized(
                    transition.occurredAt,
                    interval: source.slice.interval,
                    duration: duration
                ),
                accessibilityLabel: Self.transitionLabel(transition)
            )
        }
        interval = source.slice.interval
        previousCursor = source.previousCursor
        nextCursor = source.nextCursor
        accessibilityItems = Self.accessibilityItems(
            moments: projectedMoments,
            gaps: source.slice.gaps,
            transitions: source.slice.applicationTransitions
        )
    }

    public func nearestMoment(to normalizedPosition: Double) -> MomentTimelineMoment? {
        guard normalizedPosition.isFinite else { return moments.first }
        let bounded = min(1, max(0, normalizedPosition))
        return moments.min { lhs, rhs in
            let lhsDistance = abs(lhs.normalizedPosition - bounded)
            let rhsDistance = abs(rhs.normalizedPosition - bounded)
            if abs(lhsDistance - rhsDistance) > 1e-12 { return lhsDistance < rhsDistance }
            if lhs.result.capturedAt != rhs.result.capturedAt {
                return lhs.result.capturedAt < rhs.result.capturedAt
            }
            return lhs.result.frameID.uuidString.lowercased()
                < rhs.result.frameID.uuidString.lowercased()
        }
    }

    public func adjacentMoment(
        to frameID: UUID,
        direction: MomentDetailStepDirection
    ) -> MomentTimelineMoment? {
        guard let index = moments.firstIndex(where: { $0.result.frameID == frameID }) else {
            return nil
        }
        let target = direction == .previous ? index - 1 : index + 1
        guard moments.indices.contains(target) else { return nil }
        return moments[target]
    }

    private static func normalized(
        _ date: Date,
        interval: DateInterval,
        duration: TimeInterval
    ) -> Double {
        min(1, max(0, date.timeIntervalSince(interval.start) / duration))
    }

    private static func accessibilityItems(
        moments: [MomentTimelineMoment],
        gaps: [RecordingGap],
        transitions: [ApplicationTransition]
    ) -> [MomentTimelineAccessibilityItem] {
        let momentItems = moments.map { moment in
            MomentTimelineAccessibilityItem(
                id: "moment-\(moment.result.frameID.uuidString.lowercased())",
                kind: .moment,
                occurredAt: moment.result.capturedAt,
                frameID: moment.result.frameID,
                label: "\(timestamp(moment.result.capturedAt)), "
                    + "\(moment.result.foreground.applicationName) moment"
            )
        }
        let gapItems = gaps.enumerated().map { index, gap in
            MomentTimelineAccessibilityItem(
                id: "gap-\(gap.reason.rawValue)-\(index)",
                kind: .gap,
                occurredAt: gap.startedAt,
                frameID: nil,
                label: gapLabel(gap)
            )
        }
        let transitionItems = transitions.enumerated().map { index, transition in
            MomentTimelineAccessibilityItem(
                id: "transition-\(index)",
                kind: .transition,
                occurredAt: transition.occurredAt,
                frameID: nil,
                label: transitionLabel(transition)
            )
        }
        return (momentItems + gapItems + transitionItems).sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return $0.id < $1.id
        }
    }

    private static func gapLabel(_ gap: RecordingGap) -> String {
        let base =
            "\(reasonLabel(gap.reason)) gap, \(timestamp(gap.startedAt)) to "
            + timestamp(gap.endedAt)
        guard let approvedBundleID = gap.approvedBundleID else { return base }
        return "\(base), \(approvedBundleID)"
    }

    private static func transitionLabel(_ transition: ApplicationTransition) -> String {
        let source = transition.fromBundleID ?? "No approved application"
        let destination = transition.toBundleID ?? "No approved application"
        return "\(timestamp(transition.occurredAt)), application transition from \(source) to "
            + destination
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(
                dateSeparator: .dash,
                dateTimeSeparator: .standard,
                timeSeparator: .colon,
                timeZoneSeparator: .colon,
                includingFractionalSeconds: false,
                timeZone: .gmt
            )
        )
    }

    private static func reasonLabel(_ reason: RecordingGapReason) -> String {
        switch reason {
        case .paused: "Paused"
        case .idle: "Idle"
        case .excluded: "Excluded"
        case .permissionLost: "Permission lost"
        case .filterFailed: "Browser protection"
        case .sleep: "Mac asleep"
        case .processStopped: "Local Memory stopped"
        case .unresolvedWindow: "Window unresolved"
        case .ambiguousWindow: "Window ambiguous"
        case .minimizedWindow: "Window minimized"
        case .unsupportedDisplay: "Display unsupported"
        case .protectedSurface: "Protected surface"
        case .noWindow: "No foreground window"
        case .unknown: "Recording unavailable"
        }
    }
}

public enum MomentTimelinePhase: Equatable, Sendable {
    case idle
    case loading(cursor: Date, zoom: MomentTimelineZoomLevel)
    case ready(MomentTimelineProjection)
    case failure(MomentTimelineError)
}

public enum MomentTimelinePreview: Equatable, Sendable {
    case idle
    case loading(frameID: UUID)
    case ready(SearchThumbnailResponse)
    case unavailable(frameID: UUID)
}

@MainActor
public final class MomentTimelineSessionModel: ObservableObject {
    @Published public private(set) var phase: MomentTimelinePhase = .idle
    @Published public private(set) var zoom: MomentTimelineZoomLevel
    @Published public private(set) var scrubbedResult: SearchResult?
    @Published public private(set) var settledResult: SearchResult?
    @Published public private(set) var normalizedPosition = 0.0
    @Published public private(set) var preview: MomentTimelinePreview = .idle

    private let loader: MomentTimelinePageLoader
    private let thumbnailRepository: SearchThumbnailRepository?
    private let dwell: MomentTimelineDwell
    private var loadGeneration = 0
    private var scrubGeneration = 0
    private var previewTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?

    public init(
        loader: MomentTimelinePageLoader,
        thumbnailRepository: SearchThumbnailRepository? = nil,
        zoom: MomentTimelineZoomLevel = .calendarDay,
        dwell: MomentTimelineDwell = .standard
    ) {
        self.loader = loader
        self.thumbnailRepository = thumbnailRepository
        self.zoom = zoom
        self.dwell = dwell
    }

    public func load(around result: SearchResult) async {
        loadGeneration += 1
        let generation = loadGeneration
        cancelScrub()
        phase = .loading(cursor: result.capturedAt, zoom: zoom)
        do {
            let source = try await loader.load(
                MomentTimelinePageRequest(cursor: result.capturedAt, zoom: zoom)
            )
            try Task.checkCancellation()
            let projection = try MomentTimelineProjection(source: source)
            guard loadGeneration == generation,
                let selected = projection.moments.first(where: {
                    $0.result.frameID == result.frameID
                })
            else {
                if loadGeneration == generation { phase = .failure(.invalidSource) }
                return
            }
            phase = .ready(projection)
            scrubbedResult = selected.result
            settledResult = selected.result
            normalizedPosition = selected.normalizedPosition
            preview = .idle
        } catch is CancellationError {
            return
        } catch let error as MomentTimelineError {
            guard loadGeneration == generation else { return }
            phase = .failure(error)
        } catch {
            guard loadGeneration == generation else { return }
            phase = .failure(.unavailable)
        }
    }

    public func scrub(to requestedPosition: Double) {
        guard case .ready(let projection) = phase,
            let target = projection.nearestMoment(to: requestedPosition)
        else {
            return
        }
        cancelScrub()
        scrubGeneration += 1
        let generation = scrubGeneration
        scrubbedResult = target.result
        normalizedPosition = target.normalizedPosition
        preview = .loading(frameID: target.result.frameID)

        if let thumbnailRepository {
            previewTask = Task { [weak self] in
                do {
                    let response = try await thumbnailRepository.thumbnail(for: target.result)
                    try Task.checkCancellation()
                    guard let self, self.scrubGeneration == generation else { return }
                    self.preview =
                        response.map(MomentTimelinePreview.ready)
                        ?? .unavailable(frameID: target.result.frameID)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, self.scrubGeneration == generation else { return }
                    self.preview = .unavailable(frameID: target.result.frameID)
                }
            }
        } else {
            preview = .unavailable(frameID: target.result.frameID)
        }

        let dwell = dwell
        dwellTask = Task { [weak self] in
            do {
                try await dwell.wait()
                try Task.checkCancellation()
                guard let self, self.scrubGeneration == generation else { return }
                self.settledResult = target.result
            } catch {
                return
            }
        }
    }

    public func step(_ direction: MomentDetailStepDirection) {
        guard case .ready(let projection) = phase,
            let current = scrubbedResult ?? settledResult,
            let adjacent = projection.adjacentMoment(to: current.frameID, direction: direction)
        else {
            return
        }
        scrub(to: adjacent.normalizedPosition)
    }

    public func setZoom(_ requestedZoom: MomentTimelineZoomLevel) async {
        guard zoom != requestedZoom else { return }
        let anchor = settledResult ?? scrubbedResult
        zoom = requestedZoom
        guard let anchor else { return }
        await load(around: anchor)
    }

    public func waitForPreview() async {
        await previewTask?.value
    }

    public func waitForDwell() async {
        await dwellTask?.value
    }

    public func clear() {
        loadGeneration += 1
        cancelScrub()
        phase = .idle
        scrubbedResult = nil
        settledResult = nil
        normalizedPosition = 0
        preview = .idle
    }

    private func cancelScrub() {
        scrubGeneration += 1
        previewTask?.cancel()
        dwellTask?.cancel()
        previewTask = nil
        dwellTask = nil
    }
}
