import Foundation

public enum MemoryCaptureModule: Sendable {
    public static let name = "MemoryCapture"
}

public struct PixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum CaptureGeometry: Sendable {
    public static func encodedSize(
        for bounds: PointRect,
        maximumLongEdge: Int = CaptureConstants.maximumLongEdge
    ) -> PixelSize {
        let longEdge = max(bounds.width, bounds.height)
        guard longEdge > 0 else {
            return PixelSize(width: 2, height: 2)
        }
        let scale = min(1, Double(maximumLongEdge) / longEdge)
        return PixelSize(
            width: evenFloor(bounds.width * scale),
            height: evenFloor(bounds.height * scale)
        )
    }

    private static func evenFloor(_ value: Double) -> Int {
        max(2, Int(value) / 2 * 2)
    }
}

public struct WindowCaptureEpoch: Equatable, Sendable {
    public let id: UUID
    public let targetWindowID: UInt32
    public let processID: Int32
    public let bundleIdentifier: String
    public let approvedBounds: PointRect
    public let policyDecisionID: UUID?
    public let encodedSize: PixelSize
    public let filterAppliedNanoseconds: UInt64

    public init(
        id: UUID,
        targetWindowID: UInt32,
        processID: Int32,
        bundleIdentifier: String = "",
        approvedBounds: PointRect = PointRect(x: 0, y: 0, width: 0, height: 0),
        policyDecisionID: UUID? = nil,
        encodedSize: PixelSize,
        filterAppliedNanoseconds: UInt64
    ) {
        self.id = id
        self.targetWindowID = targetWindowID
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.approvedBounds = approvedBounds
        self.policyDecisionID = policyDecisionID
        self.encodedSize = encodedSize
        self.filterAppliedNanoseconds = filterAppliedNanoseconds
    }
}

public struct FrameCandidate: Equatable, Sendable {
    public let epochID: UUID
    public let targetWindowID: UInt32
    public let focusedWindowID: UInt32?
    public let dimensions: PixelSize
    public let deliveredNanoseconds: UInt64
    public let policyApproved: Bool

    public init(
        epochID: UUID,
        targetWindowID: UInt32,
        focusedWindowID: UInt32?,
        dimensions: PixelSize,
        deliveredNanoseconds: UInt64,
        policyApproved: Bool
    ) {
        self.epochID = epochID
        self.targetWindowID = targetWindowID
        self.focusedWindowID = focusedWindowID
        self.dimensions = dimensions
        self.deliveredNanoseconds = deliveredNanoseconds
        self.policyApproved = policyApproved
    }
}

public enum FrameRejectionReason: String, Equatable, Sendable {
    case epochMismatch
    case beforeFilterApplied
    case targetMismatch
    case focusMismatch
    case policyDenied
    case dimensionMismatch
}

public enum FrameAdmissionDecision: Equatable, Sendable {
    case accepted
    case rejected(FrameRejectionReason)
}

public enum FrameAdmission: Sendable {
    public static func evaluate(
        _ candidate: FrameCandidate,
        against epoch: WindowCaptureEpoch
    ) -> FrameAdmissionDecision {
        guard candidate.epochID == epoch.id else {
            return .rejected(.epochMismatch)
        }
        guard candidate.deliveredNanoseconds >= epoch.filterAppliedNanoseconds else {
            return .rejected(.beforeFilterApplied)
        }
        guard candidate.targetWindowID == epoch.targetWindowID else {
            return .rejected(.targetMismatch)
        }
        guard candidate.focusedWindowID == epoch.targetWindowID else {
            return .rejected(.focusMismatch)
        }
        guard candidate.policyApproved else {
            return .rejected(.policyDenied)
        }
        guard candidate.dimensions == epoch.encodedSize else {
            return .rejected(.dimensionMismatch)
        }
        return .accepted
    }
}

public enum CaptureConstants: Sendable {
    public static let maximumLongEdge = 1_920
    public static let focusPollIntervalNanoseconds: UInt64 = 100_000_000
    public static let receiveIntervalNanoseconds: UInt64 = 500_000_000
    public static let activeAcceptanceIntervalNanoseconds: UInt64 = 1_000_000_000
    public static let indexIntervalNanoseconds: UInt64 = 2_000_000_000
    public static let staticHeartbeatIntervalNanoseconds: UInt64 = 30_000_000_000
    public static let idleSuspendIntervalNanoseconds: UInt64 = 300_000_000_000
    public static let maximumChunkDurationNanoseconds: UInt64 = 30_000_000_000
    public static let writerRolloverIntervalNanoseconds: UInt64 =
        maximumChunkDurationNanoseconds - (2 * receiveIntervalNanoseconds)
    public static let streamQueueDepth = 3
    public static let mediaQueueCapacity = 4
}

public struct RefreshLeaseToken: Equatable, Sendable {
    fileprivate let id: UUID
}

public struct RefreshLeaseState: Sendable {
    private var active: (token: RefreshLeaseToken, startedNanoseconds: UInt64)?

    public init() {}

    public mutating func begin(
        nowNanoseconds: UInt64,
        cooldownNanoseconds: UInt64
    ) -> RefreshLeaseToken? {
        if let active,
           nowNanoseconds >= active.startedNanoseconds,
           nowNanoseconds - active.startedNanoseconds < cooldownNanoseconds
        {
            return nil
        }
        let token = RefreshLeaseToken(id: UUID())
        active = (token, nowNanoseconds)
        return token
    }

    public mutating func complete(_ token: RefreshLeaseToken) {
        guard active?.token == token else {
            return
        }
        active = nil
    }
}

public enum FrameAcceptanceReason: String, Equatable, Sendable {
    case firstEpochFrame
    case visualChange
    case staticHeartbeat
}

public enum FrameAcceptanceRejection: String, Equatable, Sendable {
    case activeRateLimit
    case staticDuplicate
    case idleSuspended
}

public enum FrameAcceptanceDecision: Equatable, Sendable {
    case accepted(index: Bool, reason: FrameAcceptanceReason)
    case rejected(FrameAcceptanceRejection)
}

public struct FrameAcceptanceGate: Sendable {
    private var epochID: UUID?
    private var lastAcceptedNanoseconds: UInt64?
    private var lastIndexedNanoseconds: UInt64?
    private var lastSignature: UInt64?

    public init() {}

    public mutating func evaluate(
        epochID candidateEpochID: UUID,
        timestampNanoseconds: UInt64,
        signature: UInt64,
        lastActivityNanoseconds: UInt64
    ) -> FrameAcceptanceDecision {
        if epochID != candidateEpochID {
            epochID = candidateEpochID
            lastAcceptedNanoseconds = timestampNanoseconds
            lastIndexedNanoseconds = timestampNanoseconds
            lastSignature = signature
            return .accepted(index: true, reason: .firstEpochFrame)
        }

        if elapsed(from: lastActivityNanoseconds, to: timestampNanoseconds)
            >= CaptureConstants.idleSuspendIntervalNanoseconds
        {
            return .rejected(.idleSuspended)
        }

        let sinceAccepted = elapsed(from: lastAcceptedNanoseconds ?? 0, to: timestampNanoseconds)
        if signature != lastSignature {
            guard sinceAccepted >= CaptureConstants.activeAcceptanceIntervalNanoseconds else {
                return .rejected(.activeRateLimit)
            }
            return accept(timestampNanoseconds: timestampNanoseconds, signature: signature, reason: .visualChange)
        }

        guard sinceAccepted >= CaptureConstants.staticHeartbeatIntervalNanoseconds else {
            return .rejected(.staticDuplicate)
        }
        return accept(timestampNanoseconds: timestampNanoseconds, signature: signature, reason: .staticHeartbeat)
    }

    private mutating func accept(
        timestampNanoseconds: UInt64,
        signature: UInt64,
        reason: FrameAcceptanceReason
    ) -> FrameAcceptanceDecision {
        lastAcceptedNanoseconds = timestampNanoseconds
        lastSignature = signature
        let shouldIndex = elapsed(from: lastIndexedNanoseconds ?? 0, to: timestampNanoseconds)
            >= CaptureConstants.indexIntervalNanoseconds
        if shouldIndex {
            lastIndexedNanoseconds = timestampNanoseconds
        }
        return .accepted(index: shouldIndex, reason: reason)
    }

    private func elapsed(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }
}

public enum MediaChunkBoundaryReason: String, Equatable, Sendable {
    case epochChanged
    case targetChanged
    case dimensionsChanged
    case durationReached
}

public enum MediaAppendDecision: Equatable, Sendable {
    case appendAllowed
    case closeBeforeAppend(MediaChunkBoundaryReason)
}

public struct MediaChunkScope: Equatable, Sendable {
    public let epochID: UUID
    public let targetWindowID: UInt32
    public let dimensions: PixelSize
    public let startedNanoseconds: UInt64

    public init(
        epochID: UUID,
        targetWindowID: UInt32,
        dimensions: PixelSize,
        startedNanoseconds: UInt64
    ) {
        self.epochID = epochID
        self.targetWindowID = targetWindowID
        self.dimensions = dimensions
        self.startedNanoseconds = startedNanoseconds
    }

    public func evaluate(_ candidate: FrameCandidate) -> MediaAppendDecision {
        guard candidate.epochID == epochID else {
            return .closeBeforeAppend(.epochChanged)
        }
        guard candidate.targetWindowID == targetWindowID else {
            return .closeBeforeAppend(.targetChanged)
        }
        guard candidate.dimensions == dimensions else {
            return .closeBeforeAppend(.dimensionsChanged)
        }
        let duration = candidate.deliveredNanoseconds >= startedNanoseconds
            ? candidate.deliveredNanoseconds - startedNanoseconds
            : 0
        guard duration <= CaptureConstants.maximumChunkDurationNanoseconds else {
            return .closeBeforeAppend(.durationReached)
        }
        return .appendAllowed
    }
}

public struct PointRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct FocusedWindowDescriptor: Equatable, Sendable {
    public let processID: Int32
    public let bounds: PointRect
    public let title: String?
    public let isMinimized: Bool

    public init(processID: Int32, bounds: PointRect, title: String?, isMinimized: Bool) {
        self.processID = processID
        self.bounds = bounds
        self.title = title
        self.isMinimized = isMinimized
    }
}

public struct ShareableWindowDescriptor: Equatable, Sendable {
    public let windowID: UInt32
    public let processID: Int32
    public let bounds: PointRect
    public let title: String?
    public let isOnScreen: Bool
    public let isNormalContent: Bool
    public let intersectsMainDisplay: Bool

    public init(
        windowID: UInt32,
        processID: Int32,
        bounds: PointRect,
        title: String?,
        isOnScreen: Bool,
        isNormalContent: Bool,
        intersectsMainDisplay: Bool
    ) {
        self.windowID = windowID
        self.processID = processID
        self.bounds = bounds
        self.title = title
        self.isOnScreen = isOnScreen
        self.isNormalContent = isNormalContent
        self.intersectsMainDisplay = intersectsMainDisplay
    }
}

public enum CaptureGapReason: String, Equatable, Sendable {
    case unresolvedWindow
    case ambiguousWindow
    case minimizedWindow
    case unsupportedDisplay
    case protectedSurface
    case noWindow
}

public enum WindowResolution: Equatable, Sendable {
    case approved(ShareableWindowDescriptor)
    case gap(CaptureGapReason)
}

public enum WindowResolver: Sendable {
    public static func resolve(
        focused: FocusedWindowDescriptor,
        candidates: [ShareableWindowDescriptor]
    ) -> WindowResolution {
        guard !candidates.isEmpty else {
            return .gap(.noWindow)
        }
        guard !focused.isMinimized else {
            return .gap(.minimizedWindow)
        }

        let ownedGeometryMatches = candidates.filter {
            $0.processID == focused.processID && geometryMatches($0.bounds, focused.bounds)
        }
        guard !ownedGeometryMatches.isEmpty else {
            return .gap(.unresolvedWindow)
        }
        guard ownedGeometryMatches.contains(where: \ .intersectsMainDisplay) else {
            return .gap(.unsupportedDisplay)
        }
        guard ownedGeometryMatches.contains(where: {
            $0.isNormalContent && $0.bounds.width > 0 && $0.bounds.height > 0
        }) else {
            return .gap(.protectedSurface)
        }

        let matches = ownedGeometryMatches.filter {
            $0.isOnScreen && $0.isNormalContent && $0.intersectsMainDisplay
                && $0.bounds.width > 0 && $0.bounds.height > 0
        }
        if matches.count == 1, let match = matches.first {
            return .approved(match)
        }
        guard matches.count > 1 else {
            return .gap(.unresolvedWindow)
        }

        let focusedTitle = normalizedTitle(focused.title)
        let titleMatches = matches.filter { normalizedTitle($0.title) == focusedTitle }
        guard !focusedTitle.isEmpty, titleMatches.count == 1, let match = titleMatches.first else {
            return .gap(.ambiguousWindow)
        }
        return .approved(match)
    }

    private static func geometryMatches(_ lhs: PointRect, _ rhs: PointRect) -> Bool {
        let edgeDeltasMatch = abs(lhs.x - rhs.x) <= 4
            && abs(lhs.y - rhs.y) <= 4
            && abs((lhs.x + lhs.width) - (rhs.x + rhs.width)) <= 4
            && abs((lhs.y + lhs.height) - (rhs.y + rhs.height)) <= 4
        return edgeDeltasMatch || intersectionOverUnion(lhs, rhs) >= 0.90
    }

    private static func intersectionOverUnion(_ lhs: PointRect, _ rhs: PointRect) -> Double {
        let width = max(0, min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x))
        let height = max(0, min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y))
        let intersection = width * height
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }

    private static func normalizedTitle(_ title: String?) -> String {
        (title ?? "")
            .split(whereSeparator: \ .isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}
