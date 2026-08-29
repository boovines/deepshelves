import Combine
import Foundation
import MemoryContracts

public enum TimelineDayNavigationError: Error, Equatable, Sendable {
    case invalidDay
}

public struct TimelineDay: Equatable, Sendable {
    public let components: DateComponents
    public let interval: DateInterval
    public let anchor: Date

    public init(components: DateComponents, interval: DateInterval, anchor: Date) {
        self.components = components
        self.interval = interval
        self.anchor = anchor
    }
}

public struct TimelineDayNavigator: Sendable {
    public let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    public func day(containing date: Date) throws -> TimelineDay {
        guard let interval = calendar.dateInterval(of: .day, for: date) else {
            throw TimelineDayNavigationError.invalidDay
        }
        let components = calendar.dateComponents([.year, .month, .day], from: interval.start)
        return TimelineDay(
            components: components,
            interval: interval,
            anchor: interval.start.addingTimeInterval(interval.duration / 2)
        )
    }

    public func moving(_ day: TimelineDay, byDays offset: Int) throws -> TimelineDay {
        guard let moved = calendar.date(byAdding: .day, value: offset, to: day.anchor) else {
            throw TimelineDayNavigationError.invalidDay
        }
        return try self.day(containing: moved)
    }

    public func restoring(_ components: DateComponents) throws -> TimelineDay {
        var local = DateComponents()
        local.year = components.year
        local.month = components.month
        local.day = components.day
        local.hour = 12
        guard local.year != nil, local.month != nil, local.day != nil,
            let date = calendar.date(from: local)
        else {
            throw TimelineDayNavigationError.invalidDay
        }
        let restored = try day(containing: date)
        guard restored.components.year == local.year,
            restored.components.month == local.month,
            restored.components.day == local.day
        else {
            throw TimelineDayNavigationError.invalidDay
        }
        return restored
    }
}

public struct TimelineTransitionPresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let normalizedPosition: Double?
    public let label: String
    public let isSummary: Bool

    public init(
        id: String,
        normalizedPosition: Double?,
        label: String,
        isSummary: Bool
    ) {
        self.id = id
        self.normalizedPosition = normalizedPosition
        self.label = label
        self.isSummary = isSummary
    }

    public static func project(
        _ transitions: [MomentTimelineTransitionMarker],
        moments: [MomentTimelineMoment] = [],
        zoom: MomentTimelineZoomLevel
    ) -> [TimelineTransitionPresentation] {
        let applicationNames = Dictionary(
            moments.map {
                ($0.result.foreground.bundleID, $0.result.foreground.applicationName)
            },
            uniquingKeysWith: { first, _ in first }
        )
        switch zoom {
        case .oneHour, .fifteenMinutes:
            return transitions.enumerated().map { index, transition in
                TimelineTransitionPresentation(
                    id: "transition-\(index)",
                    normalizedPosition: transition.normalizedPosition,
                    label: transitionLabel(transition, applicationNames: applicationNames),
                    isSummary: false
                )
            }
        case .calendarDay, .sixHours:
            guard !transitions.isEmpty else { return [] }
            let noun = transitions.count == 1 ? "transition" : "transitions"
            return [
                TimelineTransitionPresentation(
                    id: "transition-summary",
                    normalizedPosition: nil,
                    label: "\(transitions.count) application \(noun)",
                    isSummary: true
                )
            ]
        }
    }

    private static func transitionLabel(
        _ transition: MomentTimelineTransitionMarker,
        applicationNames: [String: String]
    ) -> String {
        let source =
            transition.fromBundleID.flatMap { applicationNames[$0] }
            ?? transition.fromBundleID ?? "No approved application"
        let destination =
            transition.toBundleID.flatMap { applicationNames[$0] }
            ?? transition.toBundleID ?? "No approved application"
        return "\(source) to \(destination)"
    }
}

public enum MomentRevisitError: Error, Equatable, Sendable {
    case sourceOutsideAllowedInterval
    case applicationNotApproved
    case hostNotApproved
    case privateContext
    case unsafeURL
    case unavailable
}

public struct MomentRevisitScope: Equatable, Sendable {
    public let allowedInterval: DateInterval
    public let allowedBundleIDs: Set<String>
    public let allowedHosts: Set<String>

    public init(
        allowedInterval: DateInterval,
        allowedBundleIDs: Set<String>,
        allowedHosts: Set<String>
    ) {
        self.allowedInterval = allowedInterval
        self.allowedBundleIDs = allowedBundleIDs
        self.allowedHosts = allowedHosts
    }
}

public enum MomentRevisitRestorationScope: String, Equatable, Sendable {
    case applicationAndApprovedURLOnly
}

public struct MomentRevisitPlan: Equatable, Sendable {
    public let applicationBundleID: String
    public let approvedURL: URL?
    public let restorationScope: MomentRevisitRestorationScope

    /// Deliberately unrepresentable in V1. Revisit never carries captured form or page state.
    public var formState: Never? { nil }

    public init(applicationBundleID: String, approvedURL: URL?) {
        self.applicationBundleID = applicationBundleID
        self.approvedURL = approvedURL
        restorationScope = .applicationAndApprovedURLOnly
    }
}

public enum MomentRevisitPlanner {
    public static func plan(
        result: SearchResult,
        scope: MomentRevisitScope
    ) throws -> MomentRevisitPlan {
        guard scope.allowedInterval.contains(result.capturedAt) else {
            throw MomentRevisitError.sourceOutsideAllowedInterval
        }
        guard scope.allowedBundleIDs.contains(result.foreground.bundleID) else {
            throw MomentRevisitError.applicationNotApproved
        }
        guard let browser = result.browser else {
            return MomentRevisitPlan(
                applicationBundleID: result.foreground.bundleID,
                approvedURL: nil
            )
        }
        guard !browser.isPrivateContext else { throw MomentRevisitError.privateContext }
        guard browser.origin.scheme == "https" || browser.origin.scheme == "http" else {
            throw MomentRevisitError.unsafeURL
        }
        guard scope.allowedHosts.contains(browser.origin.host) else {
            throw MomentRevisitError.hostNotApproved
        }
        var components = URLComponents()
        components.scheme = browser.origin.scheme
        components.host = browser.origin.host
        components.path = browser.origin.path ?? ""
        guard components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            let url = components.url
        else {
            throw MomentRevisitError.unsafeURL
        }
        return MomentRevisitPlan(
            applicationBundleID: result.foreground.bundleID,
            approvedURL: url
        )
    }
}

public struct MomentRevisitProvider: Sendable {
    private let operation: @MainActor @Sendable (SearchResult) async throws -> MomentRevisitPlan

    public init(
        operation: @escaping @MainActor @Sendable (SearchResult) async throws -> MomentRevisitPlan
    ) {
        self.operation = operation
    }

    @MainActor
    public func revisit(_ result: SearchResult) async throws -> MomentRevisitPlan {
        try await operation(result)
    }
}

@MainActor
public final class TimelineSectionSessionModel: ObservableObject {
    @Published public private(set) var phase: MomentTimelinePhase = .idle
    @Published public private(set) var day: TimelineDay
    @Published public private(set) var zoom: MomentTimelineZoomLevel = .calendarDay
    @Published public private(set) var selectedResult: SearchResult?
    @Published public private(set) var transitions: [TimelineTransitionPresentation] = []

    private let loader: MomentTimelinePageLoader
    private let navigator: TimelineDayNavigator
    private let now: @Sendable () -> Date
    private var generation = 0

    public init(
        loader: MomentTimelinePageLoader,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.loader = loader
        navigator = TimelineDayNavigator(calendar: calendar)
        self.now = now
        day =
            (try? navigator.day(containing: now()))
            ?? TimelineDay(
                components: DateComponents(year: 1970, month: 1, day: 1),
                interval: DateInterval(
                    start: Date(timeIntervalSince1970: 0),
                    duration: 24 * 60 * 60
                ),
                anchor: Date(timeIntervalSince1970: 12 * 60 * 60)
            )
    }

    public func load(date: Date, preferredFrameID: UUID? = nil) async {
        guard let targetDay = try? navigator.day(containing: date) else {
            phase = .failure(.unavailable)
            return
        }
        await load(day: targetDay, preferredFrameID: preferredFrameID)
    }

    public func moveDay(by offset: Int) async {
        guard let target = try? navigator.moving(day, byDays: offset) else {
            phase = .failure(.unavailable)
            return
        }
        await load(day: target)
    }

    public func jumpToToday() async {
        await load(date: now())
    }

    public func setZoom(_ requested: MomentTimelineZoomLevel) async {
        guard zoom != requested else { return }
        zoom = requested
        await load(day: day, preferredFrameID: selectedResult?.frameID)
    }

    public func select(frameID: UUID) {
        guard case .ready(let projection) = phase,
            let result = projection.moments.first(where: { $0.result.frameID == frameID })?.result
        else { return }
        selectedResult = result
    }

    public func selectAdjacentApplicationTransition(_ direction: MomentDetailStepDirection) {
        guard case .ready(let projection) = phase, !projection.transitions.isEmpty else { return }
        let currentPosition =
            selectedResult.flatMap { selected in
                projection.moments.first(where: { $0.result.frameID == selected.frameID })?
                    .normalizedPosition
            } ?? (direction == .next ? -Double.infinity : Double.infinity)
        let transition: MomentTimelineTransitionMarker?
        switch direction {
        case .next:
            transition = projection.transitions.first {
                $0.normalizedPosition > currentPosition + 1e-12
            }
        case .previous:
            transition = projection.transitions.last {
                $0.normalizedPosition < currentPosition - 1e-12
            }
        }
        guard let transition,
            let target = projection.nearestMoment(to: transition.normalizedPosition)
        else { return }
        selectedResult = target.result
    }

    public func clear() {
        generation += 1
        phase = .idle
        selectedResult = nil
        transitions = []
    }

    private func load(day requestedDay: TimelineDay, preferredFrameID: UUID? = nil) async {
        generation += 1
        let requestGeneration = generation
        day = requestedDay
        phase = .loading(cursor: requestedDay.anchor, zoom: zoom)
        do {
            let source = try await loader.load(
                MomentTimelinePageRequest(cursor: requestedDay.anchor, zoom: zoom)
            )
            try Task.checkCancellation()
            let projection = try MomentTimelineProjection(source: source)
            guard generation == requestGeneration else { return }
            phase = .ready(projection)
            selectedResult =
                preferredFrameID.flatMap { preferred in
                    projection.moments.first(where: { $0.result.frameID == preferred })?.result
                } ?? projection.nearestMoment(to: 0.5)?.result
            transitions = TimelineTransitionPresentation.project(
                projection.transitions,
                moments: projection.moments,
                zoom: zoom
            )
        } catch is CancellationError {
            return
        } catch let error as MomentTimelineError {
            guard generation == requestGeneration else { return }
            phase = .failure(error)
            selectedResult = nil
            transitions = []
        } catch {
            guard generation == requestGeneration else { return }
            phase = .failure(.unavailable)
            selectedResult = nil
            transitions = []
        }
    }
}
