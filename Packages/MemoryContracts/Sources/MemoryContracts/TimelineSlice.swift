import Foundation

public enum RecordingGapReason: String, Codable, Equatable, Sendable {
    case paused
    case idle
    case excluded
    case permissionLost
    case filterFailed
    case sleep
    case processStopped
    case unresolvedWindow
    case ambiguousWindow
    case minimizedWindow
    case unsupportedDisplay
    case protectedSurface
    case noWindow
    case unknown
}

public struct TimelineFrameSummary: Codable, Equatable, Sendable, ContractValidatable {
    public let frameID: UUID
    public let capturedAt: Date
    public let foreground: ForegroundContext
    public let browser: BrowserContext?
    public let thumbnailLocator: ContentLocator?

    public init(
        frameID: UUID,
        capturedAt: Date,
        foreground: ForegroundContext,
        browser: BrowserContext? = nil,
        thumbnailLocator: ContentLocator?
    ) throws {
        self.frameID = frameID
        self.capturedAt = capturedAt
        self.foreground = foreground
        self.browser = browser
        self.thumbnailLocator = thumbnailLocator
        try validate()
    }

    public func validate() throws {
        try foreground.validate()
        try browser?.validate()
        try ContractChecks.require(
            browser?.isPrivateContext != true,
            field: "timelineFrame.browser.isPrivateContext",
            violation: .inconsistent,
            detail: "private browser context cannot appear in timeline frames"
        )
        try thumbnailLocator?.validate()
    }
}

public struct RecordingGap: Codable, Equatable, Sendable, ContractValidatable {
    public let startedAt: Date
    public let endedAt: Date
    public let reason: RecordingGapReason
    public let approvedBundleID: String?

    public init(
        startedAt: Date,
        endedAt: Date,
        reason: RecordingGapReason,
        approvedBundleID: String?
    ) throws {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reason = reason
        self.approvedBundleID = approvedBundleID
        try validate()
    }

    public func validate() throws {
        try ContractChecks.validateInterval(
            DateInterval(start: startedAt, end: endedAt),
            field: "recordingGap.interval"
        )
        if let approvedBundleID {
            try ContractChecks.require(
                !approvedBundleID.isEmpty,
                field: "recordingGap.approvedBundleID",
                violation: .empty,
                detail: "approved bundle identifier cannot be empty"
            )
        }
        let identityForbidden: Set<RecordingGapReason> = [
            .excluded,
            .filterFailed,
            .protectedSurface,
            .unknown,
        ]
        if identityForbidden.contains(reason) {
            try ContractChecks.require(
                approvedBundleID == nil,
                field: "recordingGap.approvedBundleID",
                violation: .inconsistent,
                detail: "excluded, protected, or policy-uncertain gaps contain no identity"
            )
        }
    }
}

public struct ApplicationTransition: Codable, Equatable, Sendable, ContractValidatable {
    public let occurredAt: Date
    public let fromBundleID: String?
    public let toBundleID: String?

    public init(occurredAt: Date, fromBundleID: String?, toBundleID: String?) throws {
        self.occurredAt = occurredAt
        self.fromBundleID = fromBundleID
        self.toBundleID = toBundleID
        try validate()
    }

    public func validate() throws {
        try ContractChecks.require(
            fromBundleID != nil || toBundleID != nil,
            field: "applicationTransition",
            violation: .missingRequiredValue,
            detail: "a transition requires an approved source or destination"
        )
        try ContractChecks.require(
            fromBundleID.map { !$0.isEmpty } ?? true,
            field: "applicationTransition.fromBundleID",
            violation: .empty,
            detail: "bundle identifier cannot be empty"
        )
        try ContractChecks.require(
            toBundleID.map { !$0.isEmpty } ?? true,
            field: "applicationTransition.toBundleID",
            violation: .empty,
            detail: "bundle identifier cannot be empty"
        )
    }
}

public struct TranscriptMarker: Codable, Equatable, Sendable, ContractValidatable {
    public let frameID: UUID
    public let occurredAt: Date

    public init(frameID: UUID, occurredAt: Date) {
        self.frameID = frameID
        self.occurredAt = occurredAt
    }

    public func validate() throws {}
}

public struct TimelineSlice: Codable, Equatable, Sendable, ContractValidatable {
    public let interval: DateInterval
    public let frames: [TimelineFrameSummary]
    public let gaps: [RecordingGap]
    public let applicationTransitions: [ApplicationTransition]
    public let transcriptMarkers: [TranscriptMarker]

    public init(
        interval: DateInterval,
        frames: [TimelineFrameSummary],
        gaps: [RecordingGap],
        applicationTransitions: [ApplicationTransition],
        transcriptMarkers: [TranscriptMarker]
    ) throws {
        self.interval = interval
        self.frames = frames.sorted { $0.capturedAt < $1.capturedAt }
        self.gaps = gaps.sorted { $0.startedAt < $1.startedAt }
        self.applicationTransitions = applicationTransitions.sorted {
            $0.occurredAt < $1.occurredAt
        }
        self.transcriptMarkers = transcriptMarkers.sorted { $0.occurredAt < $1.occurredAt }
        try validate()
    }

    public func validate() throws {
        try ContractChecks.validateInterval(interval, field: "timelineSlice.interval")
        for frame in frames {
            try frame.validate()
            try requireContains(frame.capturedAt, field: "timelineSlice.frames")
        }
        for gap in gaps {
            try gap.validate()
            try ContractChecks.require(
                gap.startedAt >= interval.start && gap.endedAt <= interval.end,
                field: "timelineSlice.gaps",
                violation: .inconsistent,
                detail: "gap exceeds slice interval"
            )
        }
        for pair in zip(gaps, gaps.dropFirst()) {
            try ContractChecks.require(
                pair.0.endedAt <= pair.1.startedAt,
                field: "timelineSlice.gaps",
                violation: .inconsistent,
                detail: "ordered gaps cannot overlap"
            )
        }
        for transition in applicationTransitions {
            try transition.validate()
            try requireContains(
                transition.occurredAt, field: "timelineSlice.applicationTransitions")
        }
        for marker in transcriptMarkers {
            try marker.validate()
            try requireContains(marker.occurredAt, field: "timelineSlice.transcriptMarkers")
        }
        try ContractChecks.require(
            frames == frames.sorted { $0.capturedAt < $1.capturedAt }
                && gaps == gaps.sorted { $0.startedAt < $1.startedAt }
                && applicationTransitions
                    == applicationTransitions.sorted { $0.occurredAt < $1.occurredAt }
                && transcriptMarkers == transcriptMarkers.sorted { $0.occurredAt < $1.occurredAt },
            field: "timelineSlice.ordering",
            violation: .inconsistent,
            detail: "timeline members must be time ordered"
        )
    }

    private func requireContains(_ date: Date, field: String) throws {
        try ContractChecks.require(
            date >= interval.start && date < interval.end,
            field: field,
            violation: .inconsistent,
            detail: "timestamp falls outside half-open slice interval"
        )
    }
}
