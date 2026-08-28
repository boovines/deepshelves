import Foundation
import MemoryContracts

public protocol CaptureLifecycleClock: Sendable {
    var nowNanoseconds: UInt64 { get }
}

public struct SystemCaptureLifecycleClock: CaptureLifecycleClock {
    public init() {}

    public var nowNanoseconds: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

public enum CaptureLifecycleCause: Equatable, Sendable {
    case ready
    case paused
    case idle
    case sleep
    case sessionLocked
    case permissionLost
    case lowDisk
    case filterFailed
    case databaseFailure
    case processStopped
    case targetUnavailable(CaptureGapReason)

    public var timelineGapReason: RecordingGapReason? {
        switch self {
        case .ready: nil
        case .paused: .paused
        case .idle: .idle
        case .sleep, .sessionLocked: .sleep
        case .permissionLost: .permissionLost
        case .lowDisk, .databaseFailure, .processStopped: .processStopped
        case .filterFailed: .filterFailed
        case .targetUnavailable(let reason): reason.recordingGapReason
        }
    }

    public var runtimeStatus: LocalMemoryRuntimeStatus {
        switch self {
        case .ready: .recording
        case .paused: .paused
        case .idle: .idle
        case .sleep, .sessionLocked: .sleeping
        case .permissionLost: .permissionRequired
        case .lowDisk: .diskFull
        case .filterFailed, .databaseFailure, .processStopped: .stopped
        case .targetUnavailable: .targetUnavailable
        }
    }

    public var visibleDetail: String {
        switch self {
        case .ready: "Capturing the approved foreground window"
        case .paused: "Paused by you"
        case .idle: "Paused after five minutes without activity"
        case .sleep: "Paused while this Mac is asleep"
        case .sessionLocked: "Paused while this Mac is locked"
        case .permissionLost: "Screen Recording permission is required"
        case .lowDisk: "Stopped because available storage is too low"
        case .filterFailed: "Stopped because foreground-window protection failed"
        case .databaseFailure: "Stopped because the local archive is unavailable"
        case .processStopped: "Stopped safely; capture will reconcile before resuming"
        case .targetUnavailable(let reason): reason.visibleDetail
        }
    }
}

public struct CaptureLifecycleInputs: Equatable, Sendable {
    public let recordingEnabled: Bool
    public let permissionGranted: Bool
    public let activity: ActivityState
    public let suspension: ActivitySuspension?
    public let targetResolution: WindowResolution
    public let storageAvailable: Bool
    public let filterHealthy: Bool
    public let databaseHealthy: Bool
    public let processRunning: Bool

    public init(
        recordingEnabled: Bool,
        permissionGranted: Bool,
        activity: ActivityState,
        suspension: ActivitySuspension?,
        targetResolution: WindowResolution,
        storageAvailable: Bool,
        filterHealthy: Bool,
        databaseHealthy: Bool,
        processRunning: Bool
    ) {
        self.recordingEnabled = recordingEnabled
        self.permissionGranted = permissionGranted
        self.activity = activity
        self.suspension = suspension
        self.targetResolution = targetResolution
        self.storageAvailable = storageAvailable
        self.filterHealthy = filterHealthy
        self.databaseHealthy = databaseHealthy
        self.processRunning = processRunning
    }

    public init(
        recordingEnabled: Bool,
        permission: ScreenRecordingPermission,
        activitySnapshot: ActivitySnapshot,
        targetResolution: WindowResolution,
        screenCaptureState: ScreenCaptureLifecycleState,
        storageAvailable: Bool,
        databaseHealthy: Bool,
        processRunning: Bool
    ) {
        let reconciledTarget: WindowResolution
        if case .running(let windowID, _) = screenCaptureState,
            case .approved(let target) = targetResolution,
            target.windowID != windowID
        {
            reconciledTarget = .gap(.unresolvedWindow)
        } else {
            reconciledTarget = targetResolution
        }
        let filterHealthy: Bool
        switch screenCaptureState {
        case .failed, .refreshUnavailable:
            filterHealthy = false
        case .stoppedNoEligibleTarget, .permissionDenied, .running:
            filterHealthy = true
        }
        self.init(
            recordingEnabled: recordingEnabled,
            permissionGranted: permission == .granted && screenCaptureState != .permissionDenied,
            activity: activitySnapshot.activity,
            suspension: activitySnapshot.suspension,
            targetResolution: reconciledTarget,
            storageAvailable: storageAvailable,
            filterHealthy: filterHealthy,
            databaseHealthy: databaseHealthy,
            processRunning: processRunning
        )
    }

    public static let failClosed = CaptureLifecycleInputs(
        recordingEnabled: false,
        permissionGranted: false,
        activity: .idle,
        suspension: nil,
        targetResolution: .gap(.noWindow),
        storageAvailable: false,
        filterHealthy: false,
        databaseHealthy: false,
        processRunning: false
    )

    public func replacing(
        recordingEnabled: Bool? = nil,
        permissionGranted: Bool? = nil,
        activity: ActivityState? = nil,
        suspension: ActivitySuspension? = nil,
        targetResolution: WindowResolution? = nil,
        storageAvailable: Bool? = nil,
        filterHealthy: Bool? = nil,
        databaseHealthy: Bool? = nil,
        processRunning: Bool? = nil
    ) -> CaptureLifecycleInputs {
        CaptureLifecycleInputs(
            recordingEnabled: recordingEnabled ?? self.recordingEnabled,
            permissionGranted: permissionGranted ?? self.permissionGranted,
            activity: activity ?? self.activity,
            suspension: suspension ?? self.suspension,
            targetResolution: targetResolution ?? self.targetResolution,
            storageAvailable: storageAvailable ?? self.storageAvailable,
            filterHealthy: filterHealthy ?? self.filterHealthy,
            databaseHealthy: databaseHealthy ?? self.databaseHealthy,
            processRunning: processRunning ?? self.processRunning
        )
    }
}

public struct CaptureLifecycleSnapshot: Equatable, Sendable {
    public static let privacyModeLabel = "Foreground window only"

    public let cause: CaptureLifecycleCause
    public let runtimeStatus: LocalMemoryRuntimeStatus
    public let captureAllowed: Bool
    public let activeTargetWindowID: UInt32?
    public let timelineGapReason: RecordingGapReason?
    public let visibleDetail: String
    public let generation: UInt64
    public let projectionLatencyNanoseconds: UInt64

    public var privacyModeLabel: String { Self.privacyModeLabel }

    public var menuProjection: RuntimeMenuProjection {
        let base = runtimeStatus.menuProjection
        return RuntimeMenuProjection(
            statusLabel: base.statusLabel,
            statusSymbol: base.statusSymbol,
            primaryActionLabel: base.primaryActionLabel,
            detailLabel: visibleDetail
        )
    }
}

public actor CaptureLifecycleCoordinator {
    public static let uiBudgetNanoseconds: UInt64 = 250_000_000

    private struct OpenGap: Sendable {
        let reason: RecordingGapReason
        let startedAt: Date
    }

    private let clock: any CaptureLifecycleClock
    private let gapSink: (any RecordingGapPersisting)?
    private var generation: UInt64 = 0
    private var openGap: OpenGap?
    private var snapshot: CaptureLifecycleSnapshot?

    public init(
        clock: any CaptureLifecycleClock = SystemCaptureLifecycleClock(),
        gapSink: (any RecordingGapPersisting)? = nil
    ) {
        self.clock = clock
        self.gapSink = gapSink
    }

    public func currentSnapshot() -> CaptureLifecycleSnapshot? {
        snapshot
    }

    public func restoreOpenGap(reason: RecordingGapReason, startedAt: Date) {
        guard openGap == nil else { return }
        openGap = OpenGap(reason: reason, startedAt: startedAt)
    }

    @discardableResult
    public func reconcile(
        _ inputs: CaptureLifecycleInputs,
        observedAt: Date,
        observedAtNanoseconds: UInt64
    ) async throws -> CaptureLifecycleSnapshot {
        let cause = Self.resolve(inputs)
        let gapReason = cause.timelineGapReason
        if openGap?.reason != gapReason {
            if let openGap, observedAt > openGap.startedAt {
                try await gapSink?.persist(
                    recordingGap: RecordingGap(
                        startedAt: openGap.startedAt,
                        endedAt: observedAt,
                        reason: openGap.reason,
                        approvedBundleID: nil
                    )
                )
            }
            openGap = gapReason.map { OpenGap(reason: $0, startedAt: observedAt) }
        }

        generation &+= 1
        let activeTargetWindowID: UInt32?
        if cause == .ready, case .approved(let target) = inputs.targetResolution {
            activeTargetWindowID = target.windowID
        } else {
            activeTargetWindowID = nil
        }
        let now = clock.nowNanoseconds
        let updated = CaptureLifecycleSnapshot(
            cause: cause,
            runtimeStatus: cause.runtimeStatus,
            captureAllowed: cause == .ready && activeTargetWindowID != nil,
            activeTargetWindowID: activeTargetWindowID,
            timelineGapReason: gapReason,
            visibleDetail: cause.visibleDetail,
            generation: generation,
            projectionLatencyNanoseconds: now >= observedAtNanoseconds
                ? now - observedAtNanoseconds
                : 0
        )
        snapshot = updated
        return updated
    }

    private static func resolve(_ inputs: CaptureLifecycleInputs) -> CaptureLifecycleCause {
        guard inputs.processRunning else { return .processStopped }
        guard inputs.recordingEnabled else { return .paused }
        guard inputs.databaseHealthy else { return .databaseFailure }
        guard inputs.storageAvailable else { return .lowDisk }
        guard inputs.permissionGranted else { return .permissionLost }
        if let suspension = inputs.suspension {
            return suspension == .sleep ? .sleep : .sessionLocked
        }
        guard inputs.activity != .idle else { return .idle }
        guard inputs.filterHealthy else { return .filterFailed }
        switch inputs.targetResolution {
        case .approved:
            return .ready
        case .gap(let reason):
            return .targetUnavailable(reason)
        }
    }
}

extension CaptureGapReason {
    fileprivate var recordingGapReason: RecordingGapReason {
        switch self {
        case .unresolvedWindow: .unresolvedWindow
        case .ambiguousWindow: .ambiguousWindow
        case .minimizedWindow: .minimizedWindow
        case .unsupportedDisplay: .unsupportedDisplay
        case .protectedSurface: .protectedSurface
        case .noWindow: .noWindow
        }
    }

    fileprivate var visibleDetail: String {
        switch self {
        case .unresolvedWindow: "Waiting for the foreground window to resolve"
        case .ambiguousWindow: "Paused because the foreground window is ambiguous"
        case .minimizedWindow: "Paused because the foreground window is minimized"
        case .unsupportedDisplay:
            "Paused because the foreground window is on an unsupported display"
        case .protectedSurface: "Paused because the foreground surface is protected"
        case .noWindow: "Waiting for an eligible foreground window"
        }
    }
}
